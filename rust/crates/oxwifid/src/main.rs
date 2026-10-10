//! oxwifid: the Wi-Fi service — talks to wpa_supplicant's UNIX
//! control interface and serves scan/status/join over Ox IPC with
//! the charter's honest permission modes (permstored `wifi.scan` for
//! reads, `wifi.join` for credentials):
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> plausible SYNTHETIC data / a join the radio never sees
//!            (the PSK never leaves the app; scan results are
//!            location data)
//!   grant -> the real scan/status, and a REAL association for join
//! There are NO factory credentials: wpa_supplicant boots with an
//! empty network list; every join goes through the permission-
//! checked connect op. Every consult is journaled with the mode
//! served; the PSK is never journaled.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::io::Write as _;
use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn kmsg(line: &str) {
    eprintln!("oxwifid: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>oxwifid: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

fn permstored_sock() -> PathBuf {
    sock_dir().join("permstored.sock")
}

/// Consult permstored. Fail closed: unreachable daemon => deny.
fn mode_for(app: &str, permission: &str) -> String {
    let Ok(mut cl) = Client::connect(&permstored_sock()) else {
        return "deny".to_string();
    };
    match cl.request("get", json!({ "app": app, "permission": permission })) {
        Ok(resp) => resp
            .payload
            .as_ref()
            .and_then(|p| p.get("mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("deny")
            .to_string(),
        Err(_) => "deny".to_string(),
    }
}

/// Minimal wpa_ctrl client: UNIX DATAGRAM to the control socket,
/// requests framed as u32 length (native order) + command text,
/// unsolicited event lines skipped. Good enough for scan/status.
pub struct WpaCtrl {
    sock: UnixDatagram,
}

impl WpaCtrl {
    /// Attach to the ctrl interface of `iface` (e.g. wlan0) under
    /// `dir` (wpa_supplicant's ctrl_interface dir, /run/wpa_ctrl).
    /// The LOCAL socket name must be unique per attach: the connect op
    /// and the association watcher race here (the watcher ticks while
    /// a granted join is in flight), and a shared name meant the
    /// rebind UNLINKED the other socket's address — wpa_supplicant's
    /// replies then landed on the wrong datagram socket and the starved
    /// side timed out with EAGAIN.
    pub fn attach(iface: &str, dir: &str) -> std::io::Result<Self> {
        static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let local = format!(
            "{dir}/oxwifid-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        let _ = std::fs::remove_file(&local);
        let sock = UnixDatagram::bind(&local)?;
        sock.connect(format!("{dir}/{iface}"))?;
        sock.set_read_timeout(Some(Duration::from_secs(3)))?;
        Ok(WpaCtrl { sock })
    }

    fn request(&self, cmd: &str) -> std::io::Result<String> {
        // The UNIX ctrl transport is UNFRAMED: the whole datagram is
        // the command, the whole reply datagram is the text (replies
        // carry no length prefix — a prefixed command is answered with
        // UNKNOWN COMMAND).
        // Transient-busy retry: wpa_supplicant can leave a command
        // unanswered for longer than the 3s recv timeout while it sets
        // its other interface up — AND while the boot selftest wave
        // (ox-btair's HCI dumps, fake-providers) floods the console
        // under TCG; a granted join lands right in that storm and
        // measured >15s of silence. Re-send on timeout only — commands
        // are stateless datagrams; the worst case of a late-but-
        // eventual first reply is one unselected network block in the
        // runtime config (never persisted).
        let mut last: Option<std::io::Error> = None;
        for _ in 0..30 {
            match self.request_once(cmd) {
                Ok(text) => return Ok(text),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    last = Some(e);
                    std::thread::sleep(Duration::from_millis(400));
                }
                Err(e) => return Err(e),
            }
        }
        Err(last.unwrap_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "wpa_ctrl: no reply")
        }))
    }

    fn request_once(&self, cmd: &str) -> std::io::Result<String> {
        self.sock.send(cmd.as_bytes())?;
        let mut buf = [0u8; 8192];
        // unsolicited event notifications ("<3>...") may arrive first:
        // skip up to a bounded number of them
        for _ in 0..8 {
            let n = self.sock.recv(&mut buf)?;
            let text = String::from_utf8_lossy(&buf[..n]).into_owned();
            if text.starts_with('<') {
                continue; // unsolicited event
            }
            return Ok(text.trim_end_matches('\n').to_string());
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::WouldBlock,
            "only event messages received",
        ))
    }

    /// STATUS as a key=value map (wpa_state, ssid, ...).
    pub fn status(&self) -> std::io::Result<std::collections::BTreeMap<String, String>> {
        let text = self.request("STATUS")?;
        Ok(text
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect())
    }

    /// Trigger a scan and return parsed results:
    /// (ssid, signal_dbm, secured) — newest scan first line wins.
    /// Trigger a scan and return parsed results:
    /// (ssid, signal_dbm, secured). A SCAN can fail-busy or lag, so
    /// poll SCAN_RESULTS and re-trigger until networks appear.
    pub fn scan(&self) -> std::io::Result<(Vec<(String, i32, bool)>, String)> {
        let _ = self.request("SCAN"); // FAIL-BUSY = one already running
        std::thread::sleep(Duration::from_millis(2500));
        let mut raw = String::new();
        for _ in 0..5 {
            let text = self.request("SCAN_RESULTS")?;
            let nets = parse_scan_results(&text);
            if !nets.is_empty() {
                return Ok((nets, text));
            }
            raw = text;
            let _ = self.request("SCAN");
            std::thread::sleep(Duration::from_millis(2500));
        }
        Ok((parse_scan_results(&raw), raw))
    }

    /// Provision and select a network (ADD_NETWORK + SET_NETWORK
    /// ssid/psk + SELECT_NETWORK). Returns when wpa_supplicant
    /// accepted every command; association itself is reported by
    /// STATUS, which the caller can poll.
    pub fn provision(&self, ssid: &str, psk: &str, freq: Option<&str>) -> std::io::Result<()> {
        let id = self.request("ADD_NETWORK")?.trim().to_string();
        for cmd in provision_cmds(&id, ssid, psk, freq) {
            let reply = self.request(&cmd)?;
            if reply.trim() != "OK" {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    format!("{cmd} -> {reply}"),
                ));
            }
        }
        Ok(())
    }

    /// STATUS wpa_state, for the bounded association wait.
    pub fn wpa_state(&self) -> std::io::Result<String> {
        Ok(self
            .status()?
            .get("wpa_state")
            .cloned()
            .unwrap_or_default())
    }
}

/// The wpa_ctrl commands that join one WPA2-PSK network: values are
/// quoted ASCII (validated — no quotes/control chars inside).
pub fn provision_cmds(id: &str, ssid: &str, psk: &str, freq: Option<&str>) -> Vec<String> {
    // With ap_scan=2 the driver associates DIRECTLY on the given
    // frequency (no scan-first): hwsim marks a scanning radio as
    // unreachable for unicast, so skipping the scan makes the auth
    // exchange deterministic. Callers that have no frequency omit it.
    let mut cmds = vec![
        format!("SET_NETWORK {id} ssid \"{ssid}\""),
        format!("SET_NETWORK {id} psk \"{psk}\""),
    ];
    if let Some(f) = freq {
        cmds.push(format!("SET_NETWORK {id} frequency {f}"));
    }
    cmds.push(format!("SELECT_NETWORK {id}"));
    cmds
}

/// Join parameters this build accepts: printable-ASCII ssid
/// (1..=32) and psk (8..=64 — WPA2 passphrase bounds). No quotes,
/// no control characters (they would break the wpa_ctrl quoting).
pub fn valid_join(ssid: &str, psk: &str) -> Result<(), String> {
    if ssid.is_empty() || ssid.len() > 32 {
        return Err("ssid must be 1..=32 bytes".into());
    }
    if psk.len() < 8 || psk.len() > 64 {
        return Err("psk must be 8..=64 bytes (WPA2 passphrase)".into());
    }
    for (what, s) in [("ssid", ssid), ("psk", psk)] {
        if !s.bytes().all(|b| (0x20..0x7f).contains(&b)) || s.contains('"') {
            return Err(format!("{what} must be printable ASCII without quotes"));
        }
    }
    Ok(())
}

/// A remembered network. The credential is stored ONLY when a
/// wifi.join-granted association actually completed — the store is
/// the durable form of the user's consent to use that radio.
#[derive(Clone, Debug, PartialEq)]
pub struct Remembered {
    pub ssid: String,
    pub psk: String,
    /// channel frequency (MHz) the user's join used — ap_scan=2
    /// associates directly on it; None for caller-chosen
    pub freq: Option<String>,
}

pub const CREDS_STORE: &str = "/data/ox/wifi-credentials.json";
const CREDS_CAP: usize = 8;

pub fn load_creds_at(path: &str) -> Vec<Remembered> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| {
            v.as_array().map(|a| {
                a.iter()
                    .filter_map(|e| {
                        Some(Remembered {
                            ssid: e["ssid"].as_str()?.to_string(),
                            psk: e["psk"].as_str()?.to_string(),
                            freq: e["freq"].as_str().map(String::from),
                        })
                    })
                    .collect()
            })
        })
        .unwrap_or_default()
}

fn save_creds_at(path: &str, creds: &[Remembered]) {
    let arr: Vec<Value> = creds
        .iter()
        .map(|c| json!({ "ssid": c.ssid, "psk": c.psk, "freq": c.freq }))
        .collect();
    let tmp = format!("{path}.tmp");
    if std::fs::write(&tmp, serde_json::to_string(&arr).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Store (or refresh) a credential, most-recent last, deduped by
/// ssid, capped (oldest dropped).
pub fn remember_at(path: &str, ssid: &str, psk: &str, freq: Option<&str>) {
    let mut creds = load_creds_at(path);
    creds.retain(|c| c.ssid != ssid);
    creds.push(Remembered {
        ssid: ssid.to_string(),
        psk: psk.to_string(),
        freq: freq.map(String::from),
    });
    while creds.len() > CREDS_CAP {
        creds.remove(0);
    }
    save_creds_at(path, &creds);
}

/// Drop a remembered network; true if it was stored.
pub fn forget_at(path: &str, ssid: &str) -> bool {
    let mut creds = load_creds_at(path);
    let before = creds.len();
    creds.retain(|c| c.ssid != ssid);
    if creds.len() != before {
        save_creds_at(path, &creds);
        true
    } else {
        false
    }
}

/// Parse wpa_supplicant SCAN_RESULTS text (TAB-separated fields, a
/// header line first): (ssid, signal_dbm, secured). Hidden-SSID lines
/// are dropped.
pub fn parse_scan_results(text: &str) -> Vec<(String, i32, bool)> {
    text.lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 5 {
                return None;
            }
            let ssid = f[4].trim().to_string();
            if ssid.is_empty() {
                return None;
            }
            let signal: i32 = f[2].trim().parse().ok()?;
            let secured = f[3].contains("WPA") || f[3].contains("WEP");
            Some((ssid, signal, secured))
        })
        .collect()
}

/// Synthetic scan results: plausible shape, obviously not real
/// networks (Fake- prefix, +1-555 style marker in the name).
fn fake_networks() -> Value {
    json!([
        {"ssid": "Fake-Net-55501", "signal_dbm": -40, "secured": true},
        {"ssid": "Fake-Net-55502", "signal_dbm": -55, "secured": true},
        {"ssid": "Fake-Net-55503", "signal_dbm": -70, "secured": false}
    ])
}

/// Shared between the connect op and the association watcher: the
/// credential of the most recent provisioned join. The watcher
/// persists it when the association ACTUALLY completes — the in-op
/// wait can time out under TCG while the association lands later,
/// and persistence must follow reality, not the RPC deadline.
#[derive(Default)]
struct Shared {
    pending: Mutex<Option<Remembered>>,
}

fn handle_req(env: &mut Envelope, sh: Arc<Shared>) -> Envelope {
    // Chunk 68: the consult identity is the KERNEL-verified peer comm
    // for every op below — never the payload's `app` claim.
    let app = ox_ipc::peer_comm();
    match env.op.as_str() {
        "scan" => {
            if app.is_empty() {
                return env.err("scan: unknown peer identity");
            }
            let mode = mode_for(&app, "wifi.scan");
            kmsg(&format!("OXMILESTONE name=wifi-consult app={app} op=scan mode={mode}"));
            match mode.as_str() {
                "deny" => env.err("wifi.scan denied"),
                "fake" => env.ok(json!({ "networks": fake_networks(), "synthetic": true })),
                _ => {
                    let mut ctrl = match WpaCtrl::attach("wlan0", "/run/wpa_ctrl") {
                        Ok(c) => c,
                        Err(e) => return env.err(&format!("scan: wpa_ctrl: {e}")),
                    };
                    match ctrl.scan() {
                        Ok((nets, raw)) => {
                            if nets.is_empty() {
                                // raw text in the reply: field diagnostics
                                env.ok(json!({
                                    "networks": [], "synthetic": false,
                                    "raw": raw.chars().take(400).collect::<String>()
                                }))
                            } else {
                                let list: Vec<Value> = nets
                                    .iter()
                                    .map(|(ssid, sig, sec)| {
                                        json!({"ssid": ssid, "signal_dbm": sig, "secured": sec})
                                    })
                                    .collect();
                                env.ok(json!({ "networks": list, "synthetic": false }))
                            }
                        }
                        Err(e) => env.err(&format!("scan: {e}")),
                    }
                }
            }
        }
        "status" => {
            if app.is_empty() {
                return env.err("status: missing app");
            }
            let mode = mode_for(&app, "wifi.scan");
            kmsg(&format!("OXMILESTONE name=wifi-consult app={app} op=status mode={mode}"));
            match mode.as_str() {
                "deny" => env.err("wifi.scan denied"),
                "fake" => env.ok(json!({
                    "state": "COMPLETED", "ssid": "Fake-Net-55501", "synthetic": true
                })),
                _ => {
                    let ctrl = match WpaCtrl::attach("wlan0", "/run/wpa_ctrl") {
                        Ok(c) => c,
                        Err(e) => return env.err(&format!("status: wpa_ctrl: {e}")),
                    };
                    match ctrl.status() {
                        Ok(map) => env.ok(json!({
                            "state": map.get("wpa_state").cloned().unwrap_or_default(),
                            "ssid": map.get("ssid").cloned().unwrap_or_default(),
                            "synthetic": false
                        })),
                        Err(e) => env.err(&format!("status: {e}")),
                    }
                }
            }
        }
        "status-internal" => {
            // the daemon's own liveness probe (no permission needed)
            env.ok(json!({ "service": "oxwifid" }))
        }
        // join a network: the credential surface (the radio never
        // sees a PSK in deny or fake mode — joining is egress)
        "connect" => {
            let get = |k: &str| {
                env.payload
                    .as_ref()
                    .and_then(|p| p.get(k))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            };
            let (ssid, mut psk) = (get("ssid"), get("psk"));
            let freq = get("freq");
            if app.is_empty() {
                return env.err("connect: unknown peer identity");
            }
            if !freq.is_empty() && (!freq.bytes().all(|b| b.is_ascii_digit()) || freq.len() > 4) {
                return env.err("connect: freq must be digits (MHz)");
            }
            let mode = mode_for(&app, "wifi.join");
            kmsg(&format!(
                "OXMILESTONE name=wifi-consult app={app} op=join mode={mode}"
            ));
            if mode == "deny" {
                return env.err("wifi.join denied");
            }
            if let Err(reason) = valid_join(&ssid, &psk) {
                return env.err(&reason);
            }
            if mode == "fake" {
                // the join UX works; the radio never sees the PSK
                kmsg(&format!(
                    "OXMILESTONE name=wifi-join-synthetic ssid={ssid}"
                ));
                return env.ok(json!({ "joined": true, "synthetic": true, "ssid": ssid }));
            }
            // The ctrl socket is wpa_supplicant's, and a granted join
            // can land while the daemon is still creating its client
            // interface (boot-order race — the autojoin path below
            // waits for exactly this). Bounded wait, then fail
            // honestly; the policy consult already happened above, so
            // this covers only the transient, never a refusal.
            let ctrl = {
                let deadline = std::time::Instant::now() + Duration::from_secs(20);
                loop {
                    match WpaCtrl::attach("wlan0", "/run/wpa_ctrl") {
                        Ok(c) => break c,
                        Err(e) => {
                            if std::time::Instant::now() >= deadline {
                                return env.err(&format!("connect: wpa_ctrl: {e}"));
                            }
                            std::thread::sleep(Duration::from_millis(250));
                        }
                    }
                }
            };
            let freq_opt = if freq.is_empty() { None } else { Some(freq.as_str()) };
            if let Err(e) = ctrl.provision(&ssid, &psk, freq_opt) {
                return env.err(&format!("connect: provision: {e}"));
            }
            // persistence rides the watcher: from here on, whenever the
            // association COMPLETES, the pending credential is stored
            *sh.pending.lock().unwrap() = Some(Remembered {
                ssid: ssid.clone(),
                psk: psk.clone(),
                freq: freq_opt.map(String::from),
            });
            // the local PSK copy dies here (the pending store keeps the
            // credential the watcher needs; the wire copy inside the
            // request envelope is scrubbed on drop by ox-ipc)
            ox_ipc::zeroize_string(&mut psk);
            // bounded response wait (TCG association can take longer
            // than this; the watcher + the selftest's own poll cover it)
            let deadline = std::time::Instant::now() + Duration::from_secs(45);
            loop {
                match ctrl.wpa_state() {
                    Ok(s) if s == "COMPLETED" => {
                        return env.ok(json!({
                            "joined": true, "synthetic": false,
                            "state": "COMPLETED", "ssid": ssid
                        }));
                    }
                    _ => {}
                }
                if std::time::Instant::now() >= deadline {
                    kmsg(&format!(
                        "OXMILESTONE name=wifi-join-timeout ssid={ssid}"
                    ));
                    return env.err("join timed out (association still pending)");
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        // the SYSTEM surface: forget a remembered network (root oxctl
        // acting for the user — same trust level as the dialog tap)
        "forget" => {
            let ssid = env
                .payload
                .as_ref()
                .and_then(|p| p.get("ssid"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if ssid.is_empty() {
                return env.err("forget: missing ssid");
            }
            let removed = forget_at(CREDS_STORE, &ssid);
            kmsg(&format!(
                "OXMILESTONE name=wifi-forgot ssid={ssid} removed={removed}"
            ));
            env.ok(json!({ "ssid": ssid, "removed": removed }))
        }
        _ => env.err("unknown op (scan|status|connect|forget)"),
    }
}

fn main() -> std::io::Result<()> {
    let sh = Arc::new(Shared::default());
    // Remembered-network autojoin: replay the user's earlier consent.
    // The credential was stored only because a wifi.join-GRANTED
    // association completed; provisioning it again at boot is the
    // driver using that consent, journaled as remembered=true. If the
    // join fails the daemon stays honestly disconnected (no retry
    // storm, no permission prompt from the driver layer).
    std::thread::spawn(|| {
        for _ in 0..120 {
            if PathBuf::from("/run/wpa_ctrl/wlan0").exists() {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        for _ in 0..60 {
            // /data (and the store with it) may still be mounting
            let creds = load_creds_at(CREDS_STORE);
            if let Some(Remembered { ssid, psk, freq }) = creds.last() {
                let afreq = freq.as_deref();
                kmsg(&format!(
                    "OXMILESTONE name=wifi-autojoin-start ssid={ssid} remembered=true"
                ));
                let mut joined = Err(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "autojoin: no attempt succeeded",
                ));
                // Boot-time autojoin faces a moving target: the ctrl
                // socket, the interface, and wpa_supplicant's own config
                // each become ready at their own guest-time (observed:
                // attach ENOENT at t=176; SET_NETWORK refused mid-init at
                // t=246). Retry the whole provision+wait cycle — each
                // attempt re-attaches, re-provisions a FRESH network
                // block, and gives the association 300s.
                for attempt in 1..=3 {
                    // The ctrl interface can appear long after the store
                    // mounts under load (2026-10-01 solo: creds found at
                    // t=176 but the socket wait had run FIRST and
                    // exhausted, so attach hit ENOENT). Wait for it HERE,
                    // immediately before the attach, with real patience.
                    for _ in 0..300 {
                        if PathBuf::from("/run/wpa_ctrl/wlan0").exists() {
                            break;
                        }
                        std::thread::sleep(Duration::from_secs(1));
                    }
                    joined = WpaCtrl::attach("wlan0", "/run/wpa_ctrl")
                        .and_then(|c| {
                            c.provision(&ssid, &psk, afreq)?;
                            // 300s (chunk 63b): under sweep load a
                            // boot-time association measured 93
                            // guest-seconds and the EAPOL handshake
                            // completed just AFTER the old 90s deadline —
                            // the join was progressing, the daemon simply
                            // gave up first. Boot-time autojoin has no
                            // user waiting on it; 300s is honest
                            // patience, not a retry storm.
                            let deadline =
                                std::time::Instant::now() + Duration::from_secs(300);
                            loop {
                                if c.wpa_state()?.as_str() == "COMPLETED" {
                                    return Ok(());
                                }
                                if std::time::Instant::now() >= deadline {
                                    return Err(std::io::Error::new(
                                        std::io::ErrorKind::TimedOut,
                                        "autojoin association timeout",
                                    ));
                                }
                                std::thread::sleep(Duration::from_secs(1));
                            }
                        });
                    if joined.is_ok() {
                        break;
                    }
                    if attempt < 3 {
                        kmsg(&format!(
                            "wifi-autojoin-retry attempt={attempt} reason={}",
                            joined.as_ref().err().map(|e| e.to_string()).unwrap_or_default()
                        ));
                        std::thread::sleep(Duration::from_secs(10));
                    }
                }
                match joined {
                    Ok(()) => kmsg(&format!(
                        "OXMILESTONE name=wifi-autojoined ssid={ssid} remembered=true"
                    )),
                    Err(e) => kmsg(&format!(
                        "OXMILESTONE name=wifi-autojoin-failed ssid={ssid} reason={e}"
                    )),
                }
                return;
            }
            std::thread::sleep(Duration::from_secs(5));
        }
    });

    // Association watcher: poll the radio state and, when a pending
    // join lands, persist the credential + journal the completion —
    // even if the RPC already timed out. Persistence follows reality.
    {
        let sh = Arc::clone(&sh);
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(2));
            let pending = sh.pending.lock().unwrap().take();
            let Some(rem) = pending else { continue };
            let completed = WpaCtrl::attach("wlan0", "/run/wpa_ctrl")
                .and_then(|c| c.wpa_state())
                .map(|s| s == "COMPLETED")
                .unwrap_or(false);
            if completed {
                remember_at(CREDS_STORE, &rem.ssid, &rem.psk, rem.freq.as_deref());
                kmsg(&format!(
                    "OXMILESTONE name=wifi-joined ssid={} synthetic=false",
                    rem.ssid
                ));
                kmsg(&format!(
                    "OXMILESTONE name=wifi-credential-stored ssid={}",
                    rem.ssid
                ));
            } else {
                // still pending: put it back for the next tick
                *sh.pending.lock().unwrap() = Some(rem);
            }
        });
    }

    let hsh = Arc::clone(&sh);
    let _server = serve(sock_dir().join("oxwifid.sock"), move |env: &mut Envelope| {
        handle_req(env, Arc::clone(&hsh))
    })?;
    kmsg("OXMILESTONE name=oxwifid-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_networks_are_clearly_synthetic_and_wellformed() {
        let v = fake_networks();
        let arr = v.as_array().unwrap();
        assert!(!arr.is_empty());
        for n in arr {
            assert!(n["ssid"].as_str().unwrap().starts_with("Fake-Net-"));
            let sig = n["signal_dbm"].as_i64().unwrap();
            assert!(-100 <= sig && sig <= 0);
            assert!(n["secured"].is_boolean());
        }
    }

    #[test]
    fn status_parse_splits_key_value_lines() {
        let text = "bssid=aa:bb\nwpa_state=COMPLETED\nssid=ox-virt-ap\n";
        let map: std::collections::BTreeMap<String, String> = text
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        assert_eq!(map["wpa_state"], "COMPLETED");
        assert_eq!(map["ssid"], "ox-virt-ap");
    }

    #[test]
    fn scan_results_parse_extracts_ssid_signal_secured() {
        let text = "bssid / frequency / signal level / flags / ssid\n\
                    aa:bb:cc	2437	-40	[WPA2-PSK-CCMP]	ox-virt-ap\n\
                    dd:ee:ff	2412	-66	[]	opennet\n\
                    00:00:00	2437	-70	[WPA2-PSK-CCMP]	\n";
        let lines = text.lines().skip(1);
        let mut out = Vec::new();
        for l in lines {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() < 5 {
                continue;
            }
            let ssid = f[4].trim().to_string();
            if ssid.is_empty() {
                continue;
            }
            out.push((ssid, f[2].trim().parse::<i32>().unwrap(), f[3].contains("WPA")));
        }
        assert_eq!(out.len(), 2, "hidden-SSID line dropped");
        assert_eq!(out[0].0, "ox-virt-ap");
        assert!(out[0].2, "WPA2 flags mean secured");
        assert!(!out[1].2);
    }

    #[test]
    fn join_validation_bounds_and_quoting() {
        assert!(valid_join("ox-virt-ap", "oxdevpass1").is_ok());
        assert!(valid_join("", "oxdevpass1").is_err(), "empty ssid");
        assert!(valid_join(&"x".repeat(33), "oxdevpass1").is_err(), "ssid too long");
        assert!(valid_join("net", "short").is_err(), "psk below WPA2 minimum");
        assert!(valid_join("net", &"x".repeat(65)).is_err(), "psk too long");
        assert!(valid_join("net\"x", "oxdevpass1").is_err(), "quote in ssid");
        assert!(valid_join("net", "pass\"1234").is_err(), "quote in psk");
        assert!(valid_join("net", "pass\u{7f}1234").is_err(), "control char in psk");
    }

    #[test]
    fn provisioning_commands_quote_and_select() {
        let cmds = provision_cmds("3", "ox-virt-ap", "oxdevpass1", Some("2437"));
        assert_eq!(
            cmds,
            vec![
                "SET_NETWORK 3 ssid \"ox-virt-ap\"",
                "SET_NETWORK 3 psk \"oxdevpass1\"",
                "SET_NETWORK 3 frequency 2437",
                "SELECT_NETWORK 3",
            ]
        );
        // no freq = the pre-ap_scan=2 shape (skip the frequency line)
        assert_eq!(provision_cmds("3", "s", "p", None).len(), 3);
    }

    #[test]
    fn credential_store_roundtrips_dedupes_and_caps() {
        let path = std::env::temp_dir().join("oxwifid-creds-test.json");
        let _ = std::fs::remove_file(&path);
        let p = path.to_str().unwrap();
        assert!(load_creds_at(p).is_empty(), "missing store is empty");
        assert!(!forget_at(p, "ox-virt-ap"), "forget of nothing is false");
        remember_at(p, "net-a", "passw0rd1", Some("2437"));
        remember_at(p, "net-b", "passw0rd2", None);
        // re-remembering moves the ssid to the end (most recent)
        remember_at(p, "net-a", "passw0rd3", None);
        let creds = load_creds_at(p);
        assert_eq!(creds.len(), 2);
        assert_eq!(creds.last().unwrap().ssid, "net-a");
        assert_eq!(creds.last().unwrap().psk, "passw0rd3");
        assert!(forget_at(p, "net-b"));
        assert!(load_creds_at(p).len() == 1);
        assert!(!forget_at(p, "net-b"), "second forget is false");
        // cap: oldest dropped beyond 8
        for i in 0..12 {
            remember_at(p, &format!("net-{i}"), "passw0rd4", None);
        }
        let creds = load_creds_at(p);
        assert_eq!(creds.len(), 8, "capped");
        assert!(creds.iter().all(|c| c.ssid != "net-a"), "oldest dropped");
        let _ = std::fs::remove_file(&path);
    }
}
