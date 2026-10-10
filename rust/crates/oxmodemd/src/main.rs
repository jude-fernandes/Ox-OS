//! oxmodemd: Phase-2 modem daemon. Owns the radio chardev — the "modem
//! slot" — and the AT command engine, and exposes it over ox-ipc.
//!
//! The modem is the OS's main egress channel, so this daemon journals
//! every radio command to the kernel log (visible egress) and refuses
//! interactive/traffic commands (dial, SMS send) until their features
//! are built. On the virtual target the transport is the virtio-serial
//! port named `oxmodem.0` piped to a host-side AT emulator; on hardware
//! the same engine talks to a real modem over usbserial/QMI transports.
use ox_ipc::{serve, Client, Envelope};
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How long one AT exchange may take before we call it dead.
pub const AT_TIMEOUT: Duration = Duration::from_secs(5);

fn kmsg(line: &str) {
    // stderr + kernel ring, same dual-channel rule as the other daemons;
    // the kernel ring also mirrors to the console so gates see milestones.
    eprintln!("oxmodemd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>oxmodemd: {}", line);
    }
}

/// Locate the modem transport. Explicit override first, then the
/// virtio-serial port by name (devtmpfs creates /dev/vportXpY natively,
/// so no udev dependency here).
pub fn find_port() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("OX_MODEM_PORT") {
        if !p.is_empty() {
            return Some(PathBuf::from(p));
        }
    }
    let entries = std::fs::read_dir("/sys/class/virtio-ports").ok()?;
    for e in entries.flatten() {
        let name_path = e.path().join("name");
        let Ok(name) = std::fs::read_to_string(&name_path) else {
            continue;
        };
        if name.trim() == "oxmodem.0" {
            let dev = e.file_name();
            let p = PathBuf::from("/dev").join(dev);
            if p.exists() {
                return Some(p);
            }
        }
    }
    None
}

/// V.250 final result codes — the only lines that end a command.
pub fn is_final(line: &str) -> bool {
    line == "OK"
        || line == "ERROR"
        || line.starts_with("+CME ERROR")
        || line.starts_with("+CMS ERROR")
}

/// Unsolicited result codes that can arrive between commands (or mid-
/// response on real hardware). Deliberately an explicit allowlist: a
/// `+Cxxx:` prefix alone is NOT enough — "+CPIN: READY" is a response,
/// not a URC. The set grows with the features that can emit URCs (SMS
/// delivery adds +CMT etc.).
pub fn is_urc(line: &str) -> bool {
    line == "RING" || line == "POWERED DOWN" || line == "RDY"
        || line.starts_with("+CMT: ")
        || line.starts_with("+CMTI: ")
}

/// Parse "+CSQ: <rssi>,<ber>" — rssi 99 means unknown.
pub fn parse_csq(line: &str) -> Option<(u32, u32)> {
    let rest = line.strip_prefix("+CSQ:")?.trim();
    let mut it = rest.split(',');
    let rssi = it.next()?.trim().parse().ok()?;
    let ber = it.next()?.trim().parse().ok()?;
    Some((rssi, ber))
}

/// 3GPP TS 27.007: dBm = -113 + 2*rssi for 0..=31.
pub fn csq_to_dbm(rssi: u32) -> Option<i32> {
    if rssi <= 31 {
        Some(-113 + 2 * rssi as i32)
    } else {
        None // 99 = not known or not detectable
    }
}

/// Command gate (egress policy): well-formed AT only, bounded length,
/// and the interactive/traffic set is refused until those features are
/// built — the daemon must never half-support a radio transaction.
pub fn command_allowed(cmd: &str) -> Result<(), String> {
    if !cmd.starts_with("AT") {
        return Err("command must start with AT".into());
    }
    if cmd.len() > 64 || cmd.chars().any(|c| c.is_control()) {
        return Err("command too long or contains control characters".into());
    }
    let denied = ["ATD", "ATA", "AT+CMGS", "AT+CMGW", "AT+CHLD", "AT+CKPD"];
    for d in denied {
        if cmd.starts_with(d) {
            return Err(format!("{d}: interactive/traffic commands not supported by this build"));
        }
    }
    Ok(())
}

/// A line is an interactive CMGS-style prompt when it ends with ">".
pub fn is_prompt(line: &str) -> bool {
    line.trim_end().ends_with('>')
}

/// Parse a `+CMTI: "SM",<idx>` store notification into the index.
pub fn parse_cmti(line: &str) -> Option<u64> {
    let rest = line.strip_prefix("+CMTI:")?.trim();
    rest.rsplit(',').next()?.trim().parse().ok()
}

/// Parse a `+CMGR: "REC UNREAD","+1555...","...` header — the sender
/// is the second quoted field.
pub fn parse_cmgr_from(header: &str) -> Option<String> {
    let rest = header.strip_prefix("+CMGR:")?.trim();
    let mut quotes = rest.split('"');
    quotes.next()?;
    quotes.next()?; // status: "REC UNREAD" / "REC READ"
    quotes.next()?; // separator
    Some(quotes.next()?.to_string())
}

/// Parse `+CLCC: <idx>,<dir>,<state>,...,"<number>",<type>` into
/// (number, incoming) — state 4 is the incoming/ringing state of a
/// mobile-terminated call (0 = active).
pub fn parse_clcc(line: &str) -> Option<(String, bool)> {
    let rest = line.strip_prefix("+CLCC: ")?.trim();
    let q1 = rest.find('"')?;
    let q2 = rest[q1 + 1..].find('"')? + q1 + 1;
    let number = rest[q1 + 1..q2].to_string();
    let fields: Vec<&str> = rest[..q1].split(',').collect();
    let state = fields.get(2)?.trim();
    Some((number, state == "4"))
}

/// SMS records kept by the daemon (sent messages; received later).
/// synthetic=true means the policy layer served the send and the radio
/// never saw it (fake mode).
#[derive(Clone)]
pub struct SmsRec {
    pub id: u64,
    pub to: String,
    pub text: String,
    pub synthetic: bool,
}

/// The permstored permission guarding SMS send (the Messaging app's
/// manifest binds this; dialing is guarded by telephony.dial).
pub const PERM_SMS: &str = "telephony.sms";

/// Messages received from the network (+CMTI store notification ->
/// AT+CMGR read), kept by the daemon and served over sms-list
/// (permission-checked for apps; un-attributed system callers see the
/// full store).
#[derive(Clone)]
pub struct RecvRec {
    pub id: u64,
    pub from: String,
    pub text: String,
}

pub struct AtEngine {
    port: File,
    rx: Receiver<String>,
    pub urcs: Vec<String>,
}

impl AtEngine {
    pub fn open(path: &PathBuf) -> io::Result<Self> {
        let port = OpenOptions::new().read(true).write(true).open(path)?;
        let rx = spawn_reader(port.try_clone()?);
        Ok(AtEngine { port, rx, urcs: Vec::new() })
    }

    /// Two-phase exchange (CMGS-style): send the command, wait for the
    /// `>` prompt, then the body terminated by Ctrl-Z, then the final
    /// code. Anything else until the final is returned as lines.
    pub fn command_with_body(
        &mut self,
        cmd: &str,
        body: &str,
    ) -> Result<Vec<String>, String> {
        while self.rx.try_recv().is_ok() {}
        let wire = format!("{}\r", cmd);
        self.port.write_all(wire.as_bytes()).map_err(|e| e.to_string())?;
        self.port.flush().map_err(|e| e.to_string())?;
        // Phase 1: wait for the prompt (or a final code = refusal).
        let deadline = Instant::now() + AT_TIMEOUT;
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err("timeout waiting for prompt".into());
            }
            match self.rx.recv_timeout(deadline - now) {
                Ok(line) => {
                    let l = line.trim().to_string();
                    if l.is_empty() {
                        continue;
                    }
                    if is_prompt(&l) {
                        break;
                    }
                    if is_final(&l) {
                        return Err(format!("refused: {l}"));
                    }
                }
                Err(_) => return Err("timeout waiting for prompt".into()),
            }
        }
        // Phase 2: body terminated by Ctrl-Z (0x1a), then final code.
        let mut wb = body.as_bytes().to_vec();
        wb.push(0x1a);
        self.port.write_all(&wb).map_err(|e| e.to_string())?;
        self.port.flush().map_err(|e| e.to_string())?;
        self.collect_final()
    }

    /// Collect response lines until the final result code (post-body).
    fn collect_final(&mut self) -> Result<Vec<String>, String> {
        let deadline = Instant::now() + AT_TIMEOUT;
        let mut lines = Vec::new();
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Err("timeout waiting for final result code".into());
            }
            match self.rx.recv_timeout(deadline - now) {
                Ok(line) => {
                    let l = line.trim().to_string();
                    if l.is_empty() {
                        continue;
                    }
                    if is_final(&l) {
                        let ok = l == "OK";
                        if !ok {
                            lines.push(l);
                        }
                        return Ok(lines);
                    }
                    if is_urc(&l) {
                        self.urcs.push(l);
                        continue;
                    }
                    lines.push(l);
                }
                Err(RecvTimeoutError::Timeout) => {
                    return Err("timeout waiting for final result code".into())
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Err("modem reader stopped".into())
                }
            }
        }
    }

    /// Write one command and collect response lines until the final
    /// result code. URCs seen along the way are parked, never returned
    /// as response data.
    pub fn command(&mut self, cmd: &str) -> Result<Vec<String>, String> {
        while self.rx.try_recv().is_ok() {} // drain stale bytes
        let wire = format!("{}\r", cmd);
        self.port.write_all(wire.as_bytes()).map_err(|e| e.to_string())?;
        self.port.flush().map_err(|e| e.to_string())?;
        self.collect_final()
    }

    /// Classify raw lines when NO command is in flight: URCs are
    /// parked for the inbox poller, everything else is returned
    /// (nothing is silently discarded). The command paths classify
    /// mid-command lines themselves; without this drain an idle-time
    /// +CMTI would sit in the channel until the next command's stale
    /// flush threw it away.
    pub fn park_idle(&mut self) -> Vec<String> {
        let mut passthrough = Vec::new();
        while let Ok(line) = self.rx.try_recv() {
            let l = line.trim().to_string();
            if l.is_empty() {
                continue;
            }
            if is_urc(&l) {
                self.urcs.push(l);
                continue;
            }
            passthrough.push(l);
        }
        passthrough
    }
}

fn spawn_reader(mut port: File) -> Receiver<String> {
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        let mut buf = [0u8; 512];
        let mut pending: Vec<u8> = Vec::new();
        loop {
            match port.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    pending.extend_from_slice(&buf[..n]);
                    while let Some(pos) = pending.iter().position(|&b| b == b'\n') {
                        let line: Vec<u8> = pending.drain(..=pos).collect();
                        let mut s = String::from_utf8_lossy(&line).to_string();
                        if s.ends_with('\n') {
                            s.pop();
                        }
                        if s.ends_with('\r') {
                            s.pop();
                        }
                        let _ = tx.send(s);
                    }
                    // Modem prompts (CMGS "> ") have NO trailing newline;
                    // emit them as a line when seen verbatim.
                    if pending == b"> " {
                        pending.clear();
                        let _ = tx.send("> ".to_string());
                    }
                }
                Err(_) => break,
            }
        }
    });
    rx
}

/// This build sends E.164 numbers only (+ followed by <=19 digits).
pub fn valid_number(s: &str) -> bool {
    s.len() >= 2
        && s.len() <= 20
        && s.starts_with('+')
        && s[1..].bytes().all(|b| b.is_ascii_digit())
}

/// SMS text for this build: printable ASCII, 1..=160 bytes.
pub fn valid_text(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 160
        && s.bytes().all(|b| (0x20..0x7f).contains(&b))
}

#[derive(Default, Clone)]
pub struct ModemState {
    pub transport: String,
    pub manufacturer: String,
    pub model: String,
    pub sim: String,
    pub csq: String,
    pub signal_dbm: Option<i32>,
    pub registration: String,
    pub commands: u64,
    pub errors: u64,
    pub last_error: String,
    pub sent: Vec<SmsRec>,
    pub call: Option<Call>,
    pub received: Vec<RecvRec>,
    pub recv_next: u64,
}

/// The current voice call (at most one — this build has no call
/// waiting). synthetic=true means the dial/answer was served by the
/// policy layer and never touched the radio. incoming=true marks a
/// mobile-terminated call (the network called us); ringing=true means
/// it has not been answered yet.
#[derive(Clone)]
pub struct Call {
    pub number: String,
    pub synthetic: bool,
    pub incoming: bool,
    pub ringing: bool,
}

impl ModemState {
    pub fn snapshot(&self) -> serde_json::Value {
        json!({
            "transport": self.transport,
            "manufacturer": self.manufacturer,
            "model": self.model,
            "sim": self.sim,
            "csq": self.csq,
            "signal_dbm": self.signal_dbm,
            "registration": self.registration,
            "commands": self.commands,
            "errors": self.errors,
            "last_error": self.last_error,
            "sms_sent": self.sent.iter()
                .map(|s| json!({
                    "id": s.id, "to": s.to, "text": s.text,
                    "synthetic": s.synthetic,
                }))
                .collect::<Vec<_>>(),
            "call": self.call.as_ref().map(|c| json!({
                "number": c.number, "synthetic": c.synthetic,
                "incoming": c.incoming, "ringing": c.ringing,
            })),
            "sms_received": self.received.iter()
                .map(|r| json!({
                    "id": r.id, "from": r.from, "text": r.text,
                }))
                .collect::<Vec<_>>(),
        })
    }
}

/// Consult permstored for an app's mode on a permission. Fail closed:
/// unreachable daemon => deny.
fn mode_for(app: &str, permission: &str) -> String {
    let Ok(mut cl) = Client::connect("/run/ox/sockets/permstored.sock") else {
        return "deny".to_string();
    };
    let Ok(resp) = cl.request("get", json!({ "app": app, "permission": permission }))
    else {
        return "deny".to_string();
    };
    resp.payload
        .as_ref()
        .and_then(|p| p.get("mode"))
        .and_then(|v| v.as_str())
        .unwrap_or("deny")
        .to_string()
}

/// SMS send (two-phase CMGS), journaled like every other egress.
pub fn send_sms(
    engine: &mut AtEngine,
    state: &mut ModemState,
    to: &str,
    text: &str,
) -> Result<SmsRec, String> {
    if !valid_number(to) {
        return Err("to must be E.164 (+ followed by digits, <=20 chars)".into());
    }
    if !valid_text(text) {
        return Err("text must be printable ASCII, 1..=160 bytes".into());
    }
    state.commands += 1;
    kmsg(&format!("sms-send to {to} (egress journal)"));
    // The virtual-serial transport can drop a frame under load (the
    // emulator then never issues the CMGS prompt and the 5s engine
    // timeout errors) — retry the whole exchange once per failure, up
    // to three attempts, before reporting the radio as unreachable.
    let mut last: Option<String> = None;
    let lines = {
        let mut out = None;
        for attempt in 0..3 {
            let res = engine
                .command("AT+CMGF=1")
                .and_then(|_| {
                    engine.command_with_body(&format!("AT+CMGS=\"{to}\""), text)
                });
            match res {
                Ok(l) => {
                    out = Some(l);
                    break;
                }
                Err(e) => {
                    state.errors += 1;
                    kmsg(&format!(
                        "sms-send attempt {} failed: {e}",
                        attempt + 1
                    ));
                    last = Some(e);
                }
            }
        }
        match out {
            Some(l) => l,
            None => {
                return Err(last.unwrap_or_else(|| "sms-send: unreachable".into()));
            }
        }
    };
    let id = lines
        .iter()
        .find_map(|l| l.strip_prefix("+CMGS: ")?.trim().parse::<u64>().ok())
        .unwrap_or(0);
    let rec = SmsRec {
        id,
        to: to.to_string(),
        text: text.to_string(),
        synthetic: false,
    };
    state.sent.push(rec.clone());
    Ok(rec)
}

fn ask(engine: &mut AtEngine, state: &mut ModemState, cmd: &str) -> Vec<String> {
    state.commands += 1;
    kmsg(&format!("at-command {cmd} (egress journal)"));
    match engine.command(cmd) {
        Ok(lines) => lines,
        Err(e) => {
            state.errors += 1;
            state.last_error = e.clone();
            kmsg(&format!("at-command {cmd} failed: {e}"));
            Vec::new()
        }
    }
}

/// Best-effort identity/status poll; every field tolerated missing.
pub fn refresh(engine: &mut AtEngine, state: &mut ModemState) {
    if let Some(m) = ask(engine, state, "AT+GMI").pop() {
        state.manufacturer = m;
    }
    if let Some(m) = ask(engine, state, "AT+GMM").pop() {
        state.model = m;
    }
    for l in ask(engine, state, "AT+CPIN?") {
        if let Some(s) = l.strip_prefix("+CPIN: ") {
            state.sim = s.to_string();
        }
    }
    for l in ask(engine, state, "AT+CSQ") {
        if let Some((rssi, ber)) = parse_csq(&l) {
            state.csq = format!("{rssi},{ber}");
            state.signal_dbm = csq_to_dbm(rssi);
        }
    }
    for l in ask(engine, state, "AT+CREG?") {
        if l.starts_with("+CREG: ") {
            state.registration = l["+CREG: ".len()..].to_string();
        }
    }
}

fn main() {
    let state = Arc::new(Mutex::new(ModemState {
        transport: "missing".into(),
        ..Default::default()
    }));
    let engine: Arc<Mutex<Option<AtEngine>>> = Arc::new(Mutex::new(None));

    // Bring the transport up in the background so the IPC surface exists
    // even on boots without the modem slot attached.
    {
        let engine = Arc::clone(&engine);
        let state = Arc::clone(&state);
        std::thread::spawn(move || loop {
            let mut cur = engine.lock().unwrap();
            if cur.is_some() {
                return;
            }
            if let Some(p) = find_port() {
                match AtEngine::open(&p) {
                    Ok(mut e) => {
                        let display = p.display().to_string();
                        {
                            let st = &mut *state.lock().unwrap();
                            st.transport = display.clone();
                            refresh(&mut e, st);
                        }
                        *cur = Some(e);
                        kmsg(&format!(
                            "OXMILESTONE name=oxmodemd-up transport={display}"
                        ));
                    }
                    Err(err) => {
                        // e.g. port not host-connected yet (ENXIO): back
                        // off instead of spamming the kernel log.
                        kmsg(&format!("transport open failed ({err}); retrying in 2s"));
                        std::thread::sleep(Duration::from_secs(2));
                    }
                }
            } else {
                kmsg("OXMILESTONE name=oxmodemd-up-noport (modem slot absent)");
                return; // stay up for IPC; a reboot (or hotplug build) retries
            }
            drop(cur);
        });
    }

    // Inbound SMS poller: park_idle classifies idle-time lines (+CMTI
    // is a URC), and each store notification is read (AT+CMGF, CMGR),
    // recorded in the daemon inbox, and deleted from the store (CMGD).
    // All radio I/O holds the engine lock; lock order engine -> state
    // everywhere (same as the IPC arms).
    {
        let engine = Arc::clone(&engine);
        let state = Arc::clone(&state);
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(100));
            let mut e = engine.lock().unwrap();
            let Some(eng) = e.as_mut() else { continue };
            for line in eng.park_idle() {
                kmsg(&format!("idle line parked over: {line}"));
            }
            let urcs = std::mem::take(&mut eng.urcs);
            for urc in urcs {
                if let Some(idx) = parse_cmti(&urc) {
                    kmsg(&format!("sms-recv: store notification idx={idx}"));
                    if eng.command("AT+CMGF=1").is_err() {
                        kmsg(&format!("sms-recv: CMGF failed; skipping idx={idx}"));
                        continue;
                    }
                    let lines = match eng.command(&format!("AT+CMGR={idx}")) {
                        Ok(l) => l,
                        Err(err) => {
                            kmsg(&format!("sms-recv: CMGR {idx} failed: {err}"));
                            continue;
                        }
                    };
                    let mut parsed = None;
                    let mut it = lines.iter();
                    while let Some(l) = it.next() {
                        if l.starts_with("+CMGR: ") {
                            parsed = parse_cmgr_from(l).zip(it.next().cloned());
                            break;
                        }
                    }
                    let Some((from, text)) = parsed else {
                        kmsg(&format!("sms-recv: CMGR {idx} unparseable; deleting"));
                        let _ = eng.command(&format!("AT+CMGD={idx}"));
                        continue;
                    };
                    let _ = eng.command(&format!("AT+CMGD={idx}"));
                    let mut st = state.lock().unwrap();
                    st.recv_next += 1;
                    let rec = RecvRec {
                        id: st.recv_next,
                        from: from.clone(),
                        text: text.clone(),
                    };
                    st.received.push(rec);
                    kmsg(&format!(
                        "OXMILESTONE name=modem-sms-received from={from} text={text}"
                    ));
                } else if urc.trim() == "RING" {
                    // Mobile-terminated call: RING carries no caller, so
                    // ask the radio (CLCC). Ringing repeats every couple
                    // of seconds — record only the first.
                    let already = {
                        let st = state.lock().unwrap();
                        st.call.as_ref().map(|c| c.incoming).unwrap_or(false)
                    };
                    if already {
                        continue;
                    }
                    let Ok(lines) = eng.command("AT+CLCC") else {
                        kmsg("mt-call: CLCC failed while ringing");
                        continue;
                    };
                    let Some((from, incoming)) = lines.iter().find_map(|l| parse_clcc(l))
                    else {
                        kmsg("mt-call: CLCC unparseable while ringing");
                        continue;
                    };
                    let mut st = state.lock().unwrap();
                    st.call = Some(Call {
                        number: from.clone(),
                        synthetic: false,
                        incoming,
                        ringing: true,
                    });
                    kmsg(&format!("OXMILESTONE name=modem-ring from={from}"));
                }
            }
        });
    }

    let handler_engine = Arc::clone(&engine);
    let handler_state = Arc::clone(&state);
    let handle = serve("/run/ox/sockets/oxmodemd.sock", move |req: &mut Envelope| {
        let op = req.op.as_str();
        match op {
            "status" => req.ok(handler_state.lock().unwrap().snapshot()),
            "refresh" => {
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                refresh(engine, &mut st);
                req.ok(st.snapshot())
            }
            "cmd" => {
                let cmd = req
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("command"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if let Err(reason) = command_allowed(&cmd) {
                    return req.err(&reason);
                }
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                let lines = ask(engine, &mut st, &cmd);
                req.ok(json!({ "lines": lines }))
            }
            "sms-send" => {
                let get = |k: &str| {
                    req.payload
                        .as_ref()
                        .and_then(|p| p.get(k))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string()
                };
                let (to, text) = (get("to"), get("text"));
                // Chunk 68: the sender identity is the KERNEL-verified
                // peer comm — every caller consults permstored
                // (telephony.sms: deny/fake/grant, fail closed). The old
                // "no app field = system surface = grant" rule was the
                // loophole (any app could omit the claim).
                let app = ox_ipc::peer_comm();
                if app.is_empty() {
                    return req.err("sms-send: unknown peer identity");
                }
                let mode = {
                    let m = mode_for(&app, PERM_SMS);
                    kmsg(&format!(
                        "OXMILESTONE name=modem-consult app={app} mode={m} op=sms-send"
                    ));
                    m
                };
                if mode == "deny" {
                    return req.err("telephony.sms denied");
                }
                if !valid_number(&to) {
                    return req.err("to must be E.164 (+ followed by digits, <=20 chars)");
                }
                if !valid_text(&text) {
                    return req.err("text must be printable ASCII, 1..=160 bytes");
                }
                if mode == "fake" {
                    // the messaging UI works; the radio never sees the text
                    let mut st = handler_state.lock().unwrap();
                    let id = st.sent.iter().map(|r| r.id).max().unwrap_or(0) + 1;
                    let rec = SmsRec {
                        id,
                        to: to.clone(),
                        text: text.clone(),
                        synthetic: true,
                    };
                    st.sent.push(rec);
                    kmsg(&format!("OXMILESTONE name=modem-sms to={to} synthetic=true"));
                    return req.ok(json!({
                        "id": id, "to": to, "text": text, "synthetic": true
                    }));
                }
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                match send_sms(engine, &mut st, &to, &text) {
                    Ok(rec) => {
                        kmsg(&format!(
                            "OXMILESTONE name=modem-sms to={to} synthetic=false"
                        ));
                        req.ok(json!({
                            "id": rec.id, "to": rec.to, "text": rec.text,
                            "synthetic": false
                        }))
                    }
                    Err(reason) => req.err(&reason),
                }
            }
            "sms-list" => {
                // The inbox is private: chunk 68 — the reader identity is
                // the KERNEL-verified peer comm. APP callers consult
                // permstored (deny refused, fake = clearly synthetic
                // entries). The OS's own store writer (messagesd) polls
                // this as a SYSTEM path — identity-resolved, no store
                // consult: it writes the inbox, it is not a reader app.
                // (Phase-5 sweep catch: consulting the writer denied it
                // every poll and the real store starved.) Unknown
                // identity still fails closed.
                let app = ox_ipc::peer_comm();
                if app.is_empty() {
                    return req.err("sms-list: unknown peer identity");
                }
                let mut fake_mode = false;
                if app == "ox-messagesd" {
                    kmsg(
                        "OXMILESTONE name=modem-consult app=ox-messagesd mode=system op=sms-list",
                    );
                } else {
                    let mode = mode_for(&app, PERM_SMS);
                    kmsg(&format!(
                        "OXMILESTONE name=modem-consult app={app} mode={mode} op=sms-list"
                    ));
                    if mode == "deny" {
                        return req.err("telephony.sms denied");
                    }
                    fake_mode = mode == "fake";
                }
                let st = handler_state.lock().unwrap();
                let mut snap = st.snapshot();
                if fake_mode {
                    snap["sms_received"] = json!([{
                        "id": 0,
                        "from": "+00000000000",
                        "text": "synthetic inbox entry (no telephony.sms grant)",
                    }]);
                }
                req.ok(snap)
            }
            // voice calls: the permission-checked surface (the raw "cmd"
            // op refuses ATD by design — dialing only happens here)
            "dial" => {
                let get = |k: &str| {
                    req.payload
                        .as_ref()
                        .and_then(|p| p.get(k))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string()
                };
                let number = get("number");
                // Chunk 68: kernel-verified peer comm, not the payload claim.
                let app = ox_ipc::peer_comm();
                if app.is_empty() {
                    return req.err("dial: unknown peer identity");
                }
                let mode = mode_for(&app, "telephony.dial");
                kmsg(&format!(
                    "OXMILESTONE name=modem-consult app={app} mode={mode} op=dial"
                ));
                if mode == "deny" {
                    return req.err("telephony.dial denied");
                }
                if !valid_number(&number) {
                    return req.err("number must be E.164 (+ followed by digits, <=20 chars)");
                }
                {
                    let st = handler_state.lock().unwrap();
                    if st.call.is_some() {
                        return req.err("call already in progress");
                    }
                }
                if mode == "fake" {
                    // the call UI works; the radio never sees the number
                    handler_state.lock().unwrap().call =
                        Some(Call {
                            number: number.clone(),
                            synthetic: true,
                            incoming: false,
                            ringing: false,
                        });
                    kmsg(&format!(
                        "OXMILESTONE name=modem-dial number={number} synthetic=true"
                    ));
                    return req.ok(json!({ "number": number, "synthetic": true }));
                }
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                st.commands += 1;
                kmsg(&format!("modem-dial to {number} (egress journal)"));
                // collect_final consumes the final OK — success is an
                // Ok result with NO error final in the lines
                match engine.command(&format!("ATD{number};")) {
                    Ok(lines) if !lines.iter().any(|l| is_final(l)) => {
                        st.call = Some(Call {
                            number: number.clone(),
                            synthetic: false,
                            incoming: false,
                            ringing: false,
                        });
                        kmsg(&format!(
                            "OXMILESTONE name=modem-dial number={number} synthetic=false"
                        ));
                        req.ok(json!({ "number": number, "synthetic": false }))
                    }
                    Ok(_) => {
                        st.errors += 1;
                        req.err("dial rejected by modem")
                    }
                    Err(e2) => {
                        st.errors += 1;
                        req.err(&format!("dial failed: {e2}"))
                    }
                }
            }
            "hangup" => {
                // Chunk 68: kernel-verified peer comm, not the payload claim.
                let app = ox_ipc::peer_comm();
                if app.is_empty() {
                    return req.err("hangup: unknown peer identity");
                }
                let mode = mode_for(&app, "telephony.dial");
                if mode == "deny" {
                    return req.err("telephony.dial denied");
                }
                let synthetic = {
                    let st = handler_state.lock().unwrap();
                    match &st.call {
                        Some(c) => c.synthetic,
                        None => return req.err("no call in progress"),
                    }
                };
                if synthetic || mode == "fake" {
                    handler_state.lock().unwrap().call = None;
                    kmsg("OXMILESTONE name=modem-hangup synthetic=true");
                    return req.ok(json!({ "ended": true, "synthetic": true }));
                }
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                st.commands += 1;
                kmsg("modem-hangup (egress journal)");
                match engine.command("ATH") {
                    Ok(lines) if !lines.iter().any(|l| is_final(l)) => {
                        st.call = None;
                        kmsg("OXMILESTONE name=modem-hangup synthetic=false");
                        req.ok(json!({ "ended": true, "synthetic": false }))
                    }
                    Ok(_) => {
                        st.errors += 1;
                        req.err("hangup rejected by modem")
                    }
                    Err(e2) => {
                        st.errors += 1;
                        req.err(&format!("hangup failed: {e2}"))
                    }
                }
            }
            // answering a mobile-terminated call: same policy surface as
            // dial (the raw "cmd" op refuses ATA too — call setup of
            // either direction only happens behind the policy)
            "answer" => {
                // Chunk 68: kernel-verified peer comm, not the payload claim.
                let app = ox_ipc::peer_comm();
                if app.is_empty() {
                    return req.err("answer: unknown peer identity");
                }
                let mode = mode_for(&app, "telephony.dial");
                kmsg(&format!(
                    "OXMILESTONE name=modem-consult app={app} mode={mode} op=answer"
                ));
                if mode == "deny" {
                    return req.err("telephony.dial denied");
                }
                let ringing = {
                    let st = handler_state.lock().unwrap();
                    st.call.as_ref().map(|c| c.ringing).unwrap_or(false)
                };
                if !ringing {
                    return req.err("no incoming call");
                }
                if mode == "fake" {
                    // the call UI connects; the radio keeps ringing
                    let mut st = handler_state.lock().unwrap();
                    if let Some(c) = st.call.as_mut() {
                        c.ringing = false;
                        c.synthetic = true;
                        let number = c.number.clone();
                        kmsg(&format!(
                            "OXMILESTONE name=modem-answer number={number} synthetic=true"
                        ));
                        return req.ok(json!({ "number": number, "synthetic": true }));
                    }
                    unreachable!("ringing checked above");
                }
                let mut e = handler_engine.lock().unwrap();
                let Some(engine) = e.as_mut() else {
                    return req.err("modem transport not present");
                };
                let mut st = handler_state.lock().unwrap();
                st.commands += 1;
                kmsg("modem-answer (egress journal)");
                match engine.command("ATA") {
                    Ok(lines) if !lines.iter().any(|l| is_final(l)) => {
                        if let Some(c) = st.call.as_mut() {
                            c.ringing = false;
                            let number = c.number.clone();
                            kmsg(&format!(
                                "OXMILESTONE name=modem-answer number={number} synthetic=false"
                            ));
                            req.ok(json!({ "number": number, "synthetic": false }))
                        } else {
                            req.err("incoming call vanished")
                        }
                    }
                    Ok(_) => {
                        st.errors += 1;
                        req.err("answer rejected by modem")
                    }
                    Err(e2) => {
                        st.errors += 1;
                        req.err(&format!("answer failed: {e2}"))
                    }
                }
            }
            "callstatus" => {
                let st = handler_state.lock().unwrap();
                req.ok(json!({
                    "call": st.call.as_ref().map(|c| json!({
                        "number": c.number, "synthetic": c.synthetic,
                        "incoming": c.incoming, "ringing": c.ringing,
                    })),
                }))
            }
            _ => req.err("unknown op (status|refresh|cmd|sms-send|sms-list|dial|hangup|answer|callstatus)"),
        }
    });

    match handle {
        Ok(_h) => {
            kmsg("IPC up at /run/ox/sockets/oxmodemd.sock");
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        }
        Err(e) => {
            kmsg(&format!("FATAL: cannot serve IPC: {e}"));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn final_codes_end_commands() {
        assert!(is_final("OK"));
        assert!(is_final("ERROR"));
        assert!(is_final("+CME ERROR: SIM PIN required"));
        assert!(!is_final("+CPIN: READY"));
        assert!(!is_final("+CSQ: 24,0"));
    }

    #[test]
    fn responses_are_not_urcs() {
        assert!(!is_urc("+CPIN: READY"));
        assert!(!is_urc("+CSQ: 24,0"));
        assert!(is_urc("RING"));
        assert!(is_urc("+CMTI: \"SM\",3"));
    }

    #[test]
    fn cmti_and_cmgr_parsing() {
        assert_eq!(parse_cmti("+CMTI: \"SM\",1"), Some(1));
        assert_eq!(parse_cmti("+CMTI: \"SM\",17"), Some(17));
        assert_eq!(parse_cmti("+CMTI: \"ME\",0"), Some(0));
        assert_eq!(parse_cmti("+CSQ: 24,0"), None);
        assert_eq!(parse_cmti("+CMTI: \"SM\""), None);
        assert_eq!(
            parse_cmgr_from(
                "+CMGR: \"REC UNREAD\",\"+15550002\",,\"26/09/10,12:00:00+08\""
            ),
            Some("+15550002".to_string())
        );
        assert_eq!(
            parse_cmgr_from("+CMGR: \"REC READ\",\"+15550002\""),
            Some("+15550002".to_string())
        );
        assert_eq!(parse_cmgr_from("+CSQ: 24,0"), None);
        assert_eq!(parse_cmgr_from("+CMGR: \"REC UNREAD\""), None);
    }

    #[test]
    fn clcc_parsing_distinguishes_mt_from_mo() {
        // mobile-terminated, ringing (state 4)
        assert_eq!(
            parse_clcc("+CLCC: 1,1,4,0,0,\"+15550003\",129"),
            Some(("+15550003".to_string(), true))
        );
        // mobile-terminated, answered (state 0)
        assert_eq!(
            parse_clcc("+CLCC: 1,1,0,0,0,\"+15550003\",129"),
            Some(("+15550003".to_string(), false))
        );
        // mobile-originated active call
        assert_eq!(
            parse_clcc("+CLCC: 1,0,0,0,0,\"+15550001\",129"),
            Some(("+15550001".to_string(), false))
        );
        assert_eq!(parse_clcc("+CSQ: 24,0"), None);
        assert_eq!(parse_clcc("+CLCC: 1,1,4"), None); // no number
    }

    #[test]
    fn csq_parsing_and_dbm() {
        assert_eq!(parse_csq("+CSQ: 24,0"), Some((24, 0)));
        assert_eq!(parse_csq("+CSQ: 99,99"), Some((99, 99)));
        assert_eq!(csq_to_dbm(24), Some(-65)); // -113 + 2*24
        assert_eq!(csq_to_dbm(99), None);
        assert_eq!(csq_to_dbm(0), Some(-113));
    }

    #[test]
    fn egress_gate_refuses_traffic_and_garbage() {
        assert!(command_allowed("AT+CSQ").is_ok());
        assert!(command_allowed("AT+CPIN?").is_ok());
        assert!(command_allowed("help").is_err());
        assert!(command_allowed("AT+CMGS=\"+1555\"").is_err());
        assert!(command_allowed("ATD+1555;").is_err());
        assert!(command_allowed("AT").is_ok());
    }

    #[test]
    fn dialing_only_through_the_dial_op() {
        // the raw cmd gate must keep refusing call SETUP: dialing goes
        // through the permission-checked dial op. (Raw ATH is harmless
        // — without a call the modem ignores it — so it stays allowed.)
        assert!(command_allowed("ATD15550001;").is_err());
        assert!(command_allowed("ATD+15550001;").is_err());
        assert!(command_allowed("ATH").is_ok());
        assert!(valid_number("+15550001"));
        assert!(!valid_number("15550001"), "this build is E.164 only");
    }

    #[test]
    fn prompts_numbers_and_text() {
        assert!(is_prompt("> "));
        assert!(is_prompt(">"));
        assert!(!is_prompt("+CMGS: 1"));
        assert!(valid_number("+15550001"));
        assert!(!valid_number("15550001")); // this build: E.164 only
        assert!(!valid_number("+1555000a"));
        assert!(valid_text("ox-sms-test"));
        assert!(!valid_text(""));
        assert!(!valid_text("no\x01control"));
        assert!(!valid_text(&"x".repeat(161)));
    }
}
