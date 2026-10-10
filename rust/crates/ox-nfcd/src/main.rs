//! ox-nfcd: the NFC daemon — owns the virtual NFC reader on the
//! virtio-serial port named "oxnfc.0", parses checksummed tag frames
//! ($TGC,<uid>,<base64 text>*XX — NMEA framing, XOR checksum), and
//! serves the LAST tag read through the honest permission modes
//! (permstored `nfc.read`, fail-closed):
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> a clearly SYNTHETIC tag (apps work, real tag payloads
//!            never leave the daemon)
//!   grant -> the real last tag (synthetic:false)
//! The tag is also persisted atomically to /data/ox/nfc-last.json
//! (the driver store, written regardless of app permissions — the
//! permission layer lives on the IPC surface, same split as
//! camerad/modemd). On a reader-less boot the daemon stays up
//! serving IPC (same no-flap rule as oxmodemd/gnssd). Every consult
//! is journaled with the mode served; the honest no-tag leg is
//! journaled once from the reader's idle frames.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const TAG_STORE: &str = "/data/ox/nfc-last.json";
const PORT_NAME: &str = "oxnfc.0";

fn kmsg(line: &str) {
    // stderr + kernel ring, same dual-channel rule as the other daemons;
    // the kernel ring also mirrors to the console so gates see milestones.
    eprintln!("ox-nfcd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-nfcd: {}", line);
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

/// Locate the reader. Explicit override first, then the virtio-serial
/// port by name (devtmpfs creates /dev/vportXpY natively).
pub fn find_port() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("OX_NFC_PORT") {
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
        if name.trim() == PORT_NAME {
            let p = PathBuf::from("/dev").join(e.file_name());
            if p.exists() {
                return Some(p);
            }
        }
    }
    None
}

/// Frame checksum: XOR of every byte between '$' and '*', compared to
/// the two hex digits after '*'. A frame without a valid checksum is
/// noise and must never become a tag.
pub fn frame_checksum_ok(line: &str) -> bool {
    let line = line.trim();
    let Some(star) = line.rfind('*') else {
        return false;
    };
    let Some(body) = line.strip_prefix('$') else {
        return false;
    };
    if star < 1 || star + 3 != line.len() {
        return false;
    }
    let Ok(want) = u8::from_str_radix(&line[star + 1..], 16) else {
        return false;
    };
    let got = body[..star - 1].bytes().fold(0u8, |a, b| a ^ b);
    got == want
}

/// Standard-alphabet base64 decode (padding required). Hand-rolled to
/// keep the crate free of extra dependencies.
pub fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            // padding contributes zero bits; the tail is truncated below
            b'=' => Some(0),
            _ => None,
        }
    }
    let s = s.trim();
    if s.is_empty() || s.len() % 4 != 0 {
        return None;
    }
    let pad = s.ends_with("==");
    let one_pad = !pad && s.ends_with('=');
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut acc = 0u32;
        for &c in chunk {
            acc = (acc << 6) | val(c)?;
        }
        out.push((acc >> 16) as u8);
        out.push((acc >> 8) as u8);
        out.push(acc as u8);
    }
    let len = out.len() - if pad {
        2
    } else if one_pad {
        1
    } else {
        0
    };
    out.truncate(len);
    Some(out)
}

/// A parsed tag frame: `$TGC,<uid>,<b64>*XX` -> (uid, text).
/// The uid must be hex (the reader reports it as the tag's UID), the
/// text must be printable ASCII once decoded.
#[derive(Clone, Debug, PartialEq)]
pub struct Tag {
    pub uid: String,
    pub text: String,
}

pub fn valid_uid(uid: &str) -> bool {
    (4..=20).contains(&uid.len()) && uid.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn parse_tag_frame(line: &str) -> Option<Tag> {
    let line = line.trim();
    if !line.starts_with("$TGC,") {
        return None;
    }
    if !frame_checksum_ok(line) {
        return None;
    }
    let body = &line[1..line.rfind('*')?];
    let f: Vec<&str> = body.split(',').collect();
    if f.len() != 3 {
        return None;
    }
    let uid = f[1].to_string();
    if !valid_uid(&uid) {
        return None;
    }
    let text = String::from_utf8(b64_decode(f[2])?).ok()?;
    if text.is_empty() || !text.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return None;
    }
    Some(Tag { uid, text })
}

/// Idle frame: `$TGN,*XX` — the reader says no tag is in range.
pub fn is_no_tag_frame(line: &str) -> bool {
    let line = line.trim();
    line.starts_with("$TGN,") && frame_checksum_ok(line)
}

impl Tag {
    pub fn to_json(&self) -> Value {
        json!({
            "uid": self.uid,
            "text": self.text,
            "source": "nfc",
        })
    }

    /// Clearly synthetic tag for fake mode.
    pub fn synthetic() -> Value {
        json!({
            "uid": "04:FA:KE:00:00:01",
            "text": "synthetic tag payload (no nfc.read grant)",
            "synthetic": true,
        })
    }
}

fn persist_tag(tag: &Tag) {
    let dir = PathBuf::from("/data/ox");
    if std::fs::create_dir_all(&dir).is_err() {
        kmsg("persist: cannot create /data/ox");
        return;
    }
    let tmp = dir.join(".nfc-last.json.tmp");
    let text = tag.to_json().to_string();
    match std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, TAG_STORE)) {
        Ok(()) => kmsg("nfc-tag-persisted"),
        Err(e) => kmsg(&format!("persist failed: {e}")),
    }
}

struct Shared {
    last: Mutex<Option<Tag>>,
    frames: AtomicU64,
    bad: AtomicU64,
    notag_journaled: AtomicBool,
}

impl Shared {
    fn new() -> Self {
        Self {
            last: Mutex::new(None),
            frames: AtomicU64::new(0),
            bad: AtomicU64::new(0),
            notag_journaled: AtomicBool::new(false),
        }
    }
}

/// Reader loop: blocks on the reader port, feeds every line through
/// checksum + parse, journals the honest no-tag leg from the reader's
/// idle frames, and on each tag read journals + persists + publishes
/// it. A reader-less boot is fine — the daemon stays up.
fn read_loop(port: PathBuf, sh: Arc<Shared>) {
    loop {
        let file = match std::fs::File::open(&port) {
            Ok(f) => f,
            Err(e) => {
                kmsg(&format!("port open failed: {e}; retry in 2s"));
                thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        let mut r = BufReader::new(file);
        let mut line = String::new();
        loop {
            line.clear();
            match r.read_line(&mut line) {
                Ok(0) => break, // reader closed the stream
                Ok(_) => {}
                Err(e) => {
                    kmsg(&format!("port read error: {e}"));
                    break;
                }
            }
            let line = line.trim_end();
            if line.is_empty() {
                continue;
            }
            if is_no_tag_frame(line) {
                if !sh.notag_journaled.swap(true, Ordering::Relaxed) {
                    kmsg("OXMILESTONE name=nfc-no-tag");
                }
                continue;
            }
            let Some(tag) = parse_tag_frame(line) else {
                sh.bad.fetch_add(1, Ordering::Relaxed);
                continue;
            };
            sh.frames.fetch_add(1, Ordering::Relaxed);
            kmsg(&format!(
                "OXMILESTONE name=nfc-tag-read uid={} text={}",
                tag.uid, tag.text
            ));
            persist_tag(&tag);
            let mut last = sh.last.lock().unwrap();
            *last = Some(tag);
        }
    }
}

fn handle_req(env: &mut Envelope, sh: Arc<Shared>) -> Envelope {
    match env.op.as_str() {
        "last" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("last: unknown peer identity");
            }
            let mode = mode_for(&app, "nfc.read");
            kmsg(&format!(
                "OXMILESTONE name=nfc-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("nfc.read denied"),
                "fake" => env.ok(json!({
                    "tag": Tag::synthetic(),
                    "synthetic": true,
                    "count": sh.frames.load(Ordering::Relaxed),
                })),
                _ => {
                    let last = sh.last.lock().unwrap();
                    match &*last {
                        Some(t) => env.ok(json!({
                            "tag": t.to_json(),
                            "synthetic": false,
                            "count": sh.frames.load(Ordering::Relaxed),
                        })),
                        None => env.ok(json!({
                            "tag": Value::Null,
                            "synthetic": false,
                            "count": sh.frames.load(Ordering::Relaxed),
                        })),
                    }
                }
            }
        }
        "status" => {
            // liveness probe (no permission needed): no payload leaves
            env.ok(json!({
                "service": "ox-nfcd",
                "frames": sh.frames.load(Ordering::Relaxed),
                "bad_frames": sh.bad.load(Ordering::Relaxed),
            }))
        }
        _ => env.err("unknown op (last|status)"),
    }
}

fn main() {
    let sh = Arc::new(Shared::new());

    // Bring the transport up in the background so the IPC surface
    // exists even on boots without the reader slot attached.
    {
        let sh = Arc::clone(&sh);
        thread::spawn(move || loop {
            if let Some(p) = find_port() {
                kmsg(&format!(
                    "OXMILESTONE name=nfcd-ready transport={}",
                    p.display()
                ));
                read_loop(p, Arc::clone(&sh));
                kmsg("reader stream closed; reattaching in 2s");
            }
            thread::sleep(Duration::from_secs(2));
        });
    }

    let hsh = Arc::clone(&sh);
    let handle = serve(sock_dir().join("nfcd.sock"), move |env: &mut Envelope| {
        handle_req(env, Arc::clone(&hsh))
    });

    match handle {
        Ok(_h) => {
            kmsg("IPC up at nfcd.sock");
            loop {
                thread::sleep(Duration::from_secs(3600));
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

    fn frame(body: &str) -> String {
        let sum = body.bytes().fold(0u8, |a, b| a ^ b);
        format!("${body}*{sum:02X}")
    }

    #[test]
    fn checksum_accepts_valid_and_refuses_corrupt() {
        let f = frame("TGC,04a2b3c4d5e6,SGk=");
        assert!(frame_checksum_ok(&f));
        assert!(!frame_checksum_ok(&format!("$TGC,04a2b3c4d5e6,SGk=*00")));
        assert!(!frame_checksum_ok("TGC,04a2b3c4d5e6,SGk=*41"));
        assert!(!frame_checksum_ok("$TGC,04a2b3c4d5e6,SGk="));
        assert!(!frame_checksum_ok(""));
    }

    #[test]
    fn b64_decode_roundtrip_and_edges() {
        assert!(b64_decode("").is_none(), "empty payload refused");
        assert_eq!(b64_decode("SGk="), Some(b"Hi".to_vec()));
        assert_eq!(
            b64_decode("Ym9hcmQgYXQgZ2F0ZSBmb3VyIHdpdGggY29kZSBWRi0yMzgx"),
            Some(b"board at gate four with code VF-2381".to_vec())
        );
        assert_eq!(b64_decode("A"), None, "bad length");
        assert_eq!(b64_decode("AB@D"), None, "bad alphabet");
    }

    #[test]
    fn tag_frames_parse_and_reject() {
        let good = frame("TGC,04a2b3c4d5e6,SGk=");
        let t = parse_tag_frame(&good).expect("valid frame must parse");
        assert_eq!(t.uid, "04a2b3c4d5e6");
        assert_eq!(t.text, "Hi");
        // corrupt checksum never becomes a tag
        assert!(parse_tag_frame("$TGC,04a2b3c4d5e6,SGk=*00").is_none());
        // non-hex uid refused
        let bad_uid = frame("TGC,not-hex-uid,SGk=");
        assert!(parse_tag_frame(&bad_uid).is_none());
        // wrong field count refused
        let bad_fields = frame("TGC,04a2b3c4d5e6");
        assert!(parse_tag_frame(&bad_fields).is_none());
        // idle frame is not a tag
        assert!(is_no_tag_frame(&frame("TGN,")));
        assert!(!is_no_tag_frame(&good));
    }
}
