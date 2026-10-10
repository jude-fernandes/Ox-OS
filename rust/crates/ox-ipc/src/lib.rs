use serde::{Deserialize, Serialize};
use std::cell::Cell;
use std::io::{self, Read, Write};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_FRAME: u32 = 1 << 20;

thread_local! {
    /// The kernel-verified peer pid of the connection served by THIS
    /// thread (SO_PEERCRED at accept). 0 when unknown. Handlers run on
    /// the connection thread, so `conn_peer_pid()` identifies the
    /// client PROCESS — spoofable self-reported pids are not trusted.
    static CONN_PEER_PID: Cell<u32> = const { Cell::new(0) };
}

/// The peer pid of the connection this thread is serving.
pub fn conn_peer_pid() -> u32 {
    CONN_PEER_PID.with(|c| c.get())
}

/// The kernel-verified peer process NAME (the pid's current /proc comm).
/// This is the identity every permission consult must use: a client can
/// claim any `app` in its payload, but it cannot spoof its comm. Empty
/// when unknown (tests, or a peer that vanished before the read — the
/// consult then fails closed downstream).
pub fn peer_comm() -> String {
    let pid = conn_peer_pid();
    if pid == 0 {
        return String::new();
    }
    std::fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

/// Kernel-verified peer credentials for a Unix socket.
fn peer_pid_of(stream: &UnixStream) -> Option<u32> {
    #[cfg(target_os = "linux")]
    {
        let fd = stream.as_raw_fd();
        let mut cred: libc::ucred = libc::ucred { pid: 0, uid: 0, gid: 0 };
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                &mut cred as *mut libc::ucred as *mut libc::c_void,
                &mut len,
            )
        };
        if rc == 0 { Some(cred.pid as u32) } else { None }
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Envelope {
    pub v: u16,
    pub op: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Volatile overwrite: the compiler may not elide the stores, so a
/// secret buffer reads back all-zero even before the allocator reuses
/// the page. Best-effort — realloc copies made underneath serde are
/// out of reach.
pub fn zeroize_bytes(buf: &mut [u8]) {
    for b in buf.iter_mut() {
        unsafe { std::ptr::write_volatile(b, 0) };
    }
}

/// Zeroize an owned String in place: bytes become NULs (still valid
/// UTF-8, length preserved), so the string stays safe to read or drop.
pub fn zeroize_string(s: &mut String) {
    zeroize_bytes(unsafe { s.as_bytes_mut() });
}

/// Zeroize every string inside a JSON value, in place (arrays and
/// objects recursed; object KEYS untouched — secrets ride values).
pub fn scrub_value(v: &mut serde_json::Value) {
    match v {
        serde_json::Value::String(s) => zeroize_string(s),
        serde_json::Value::Array(a) => a.iter_mut().for_each(scrub_value),
        serde_json::Value::Object(m) => m.values_mut().for_each(scrub_value),
        _ => {}
    }
}

impl Envelope {
    pub fn request(op: &str, id: u64, payload: serde_json::Value) -> Self {
        Envelope { v: PROTOCOL_VERSION, op: op.into(), id: Some(id), payload: Some(payload), error: None }
    }

    pub fn ok(&self, payload: serde_json::Value) -> Self {
        Envelope { v: PROTOCOL_VERSION, op: self.op.clone(), id: self.id, payload: Some(payload), error: None }
    }

    pub fn err(&self, msg: &str) -> Self {
        Envelope { v: PROTOCOL_VERSION, op: self.op.clone(), id: self.id, payload: None, error: Some(msg.into()) }
    }

    /// Volatile-zero the payload strings. Secrets ride the payload;
    /// op/id/error carry no secret material.
    pub fn scrub(&mut self) {
        if let Some(p) = self.payload.as_mut() {
            scrub_value(p);
        }
    }

    /// Returns the PLAINTEXT frame; the caller must zeroize it after
    /// writing (send_envelope does).
    pub fn encode(&self) -> io::Result<Vec<u8>> {
        let mut body = serde_json::to_vec(self)?;
        let len = body.len() as u32;
        if len > MAX_FRAME {
            zeroize_bytes(&mut body);
            return Err(io::Error::new(io::ErrorKind::InvalidData, "frame exceeds MAX_FRAME"));
        }
        let mut out = Vec::with_capacity(4 + body.len());
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&body);
        zeroize_bytes(&mut body);
        Ok(out)
    }

    pub fn decode(buf: &[u8]) -> io::Result<Self> {
        serde_json::from_slice(buf)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}

pub struct FrameReader<R: Read> {
    inner: R,
}

impl<R: Read> FrameReader<R> {
    pub fn new(inner: R) -> Self {
        FrameReader { inner }
    }

    pub fn next_frame(&mut self) -> io::Result<Option<Envelope>> {
        let mut lenbuf = [0u8; 4];
        match self.inner.read_exact(&mut lenbuf) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(e) => return Err(e),
        }
        let len = u32::from_le_bytes(lenbuf);
        if len == 0 || len > MAX_FRAME {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bad frame length"));
        }
        let mut body = vec![0u8; len as usize];
        if let Err(e) = self.inner.read_exact(&mut body) {
            zeroize_bytes(&mut body);
            return Err(e);
        }
        let parsed = Envelope::decode(&body);
        // the raw frame carried any secrets in plaintext
        zeroize_bytes(&mut body);
        parsed.map(Some)
    }
}

pub fn send_envelope(stream: &mut UnixStream, env: &Envelope) -> io::Result<()> {
    let mut frame = env.encode()?;
    let r = stream.write_all(&frame);
    zeroize_bytes(&mut frame);
    r?;
    stream.flush()
}

pub fn recv_envelope(stream: &mut UnixStream) -> io::Result<Option<Envelope>> {
    FrameReader::new(stream.try_clone()?).next_frame()
}

pub struct Client {
    stream: UnixStream,
    next_id: u64,
}

impl Client {
    pub fn connect<P: AsRef<Path>>(path: P) -> io::Result<Self> {
        Ok(Client { stream: UnixStream::connect(path)?, next_id: 1 })
    }

    pub fn request(&mut self, op: &str, payload: serde_json::Value) -> io::Result<Envelope> {
        let id = self.next_id;
        self.next_id += 1;
        let mut req = Envelope::request(op, id, payload);
        let sent = send_envelope(&mut self.stream, &req);
        // the client's copy of the secret payload dies here; the
        // daemon scrubs its own on the other side of the wire
        req.scrub();
        sent?;
        recv_envelope(&mut self.stream)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "server closed"))
    }
}

pub struct ServerHandle {
    pub shutdown: Arc<AtomicBool>,
    join: Option<thread::JoinHandle<io::Result<()>>>,
}

impl ServerHandle {
    pub fn stop(mut self) -> io::Result<()> {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(wake_path_hint());
        if let Some(j) = self.join.take() {
            j.join().map_err(|_| io::Error::other("server thread panicked"))??;
        }
        Ok(())
    }
}

fn wake_path_hint() -> &'static str {
    "/dev/null"
}

pub fn serve<P, F>(path: P, handler: F) -> io::Result<ServerHandle>
where
    P: AsRef<Path>,
    F: Fn(&mut Envelope) -> Envelope + Send + Clone + 'static,
{
    serve_with_disconnect(path, handler, || {})
}

/// Like `serve`, and calls `on_disconnect` on the connection thread
/// when a client goes away (clean exit or crash) — the hook compositors
/// use to reap the client's windows.
pub fn serve_with_disconnect<P, F, G>(
    path: P,
    handler: F,
    on_disconnect: G,
) -> io::Result<ServerHandle>
where
    P: AsRef<Path>,
    F: Fn(&mut Envelope) -> Envelope + Send + Clone + 'static,
    G: Fn() + Send + Clone + 'static,
{
    let path = path.as_ref().to_path_buf();
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let listener = unix_listener_bind(&path)?;
    listener.set_nonblocking(true)?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let sd = Arc::clone(&shutdown);
    let path2 = path.clone();
    let join = thread::spawn(move || -> io::Result<()> {
        while !sd.load(Ordering::SeqCst) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let h = handler.clone();
                    let gone = on_disconnect.clone();
                    thread::spawn(move || {
                        let mut s = stream;
                        // stamp the kernel-verified peer pid for this
                        // connection's thread before any handler runs
                        CONN_PEER_PID.with(|c| c.set(peer_pid_of(&s).unwrap_or(0)));
                        while let Ok(Some(mut req)) = recv_envelope(&mut s) {
                            let mut resp = h(&mut req);
                            // the daemon-side wire copies die here: the
                            // request's secret payload after the handler,
                            // the response's after it goes on the wire
                            req.scrub();
                            if send_envelope(&mut s, &resp).is_err() {
                                break;
                            }
                            resp.scrub();
                        }
                        // client disconnected: clean up its per-connection state
                        gone();
                    });
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(e) => return Err(e),
            }
        }
        let _ = std::fs::remove_file(&path2);
        Ok(())
    });
    Ok(ServerHandle { shutdown, join: Some(join) })
}

fn unix_listener_bind(path: &Path) -> io::Result<std::os::unix::net::UnixListener> {
    let l = std::os::unix::net::UnixListener::bind(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(l)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn all_zero(v: &serde_json::Value) -> bool {
        v.as_str().map(|s| !s.is_empty() && s.bytes().all(|b| b == 0)).unwrap_or(true)
    }

    #[test]
    fn scrub_value_zeroes_strings_and_keeps_structure() {
        let mut v = json!({"pin": "1234", "nest": { "psk": "hunter2" }, "arr": ["abc"], "n": 5});
        scrub_value(&mut v);
        let obj = v.as_object().unwrap();
        // zeroed in place: length preserved, all bytes NUL
        assert_eq!(obj["pin"].as_str().unwrap(), "\0\0\0\0");
        assert_eq!(obj["nest"]["psk"].as_str().unwrap().len(), 7);
        assert!(all_zero(&obj["nest"]["psk"]));
        assert_eq!(obj["arr"][0].as_str().unwrap().len(), 3);
        assert!(all_zero(&obj["arr"][0]));
        // scalars untouched
        assert_eq!(obj["n"].as_u64(), Some(5));
    }

    #[test]
    fn scrub_value_scalar_is_a_noop() {
        let mut v = json!([null, 42, true, "s3cret"]);
        scrub_value(&mut v);
        assert_eq!(v[1].as_u64(), Some(42));
        assert_eq!(v[2].as_bool(), Some(true));
        assert!(all_zero(&v[3]));
    }

    #[test]
    fn envelope_scrub_zeroes_payload_strings() {
        let mut e = Envelope::request("verify", 1, json!({"pin": "1234"}));
        e.scrub();
        assert_eq!(e.payload.as_ref().unwrap()["pin"].as_str().unwrap(), "\0\0\0\0");
    }

    #[test]
    fn wire_roundtrip_delivers_secret_then_scrub_zeroes_it() {
        // over a real socket pair: the frame path must deliver the
        // secret intact (function) and the scrub must zero it in place
        // (hygiene) — the same pair of guarantees the daemons rely on
        let (mut a, mut b) = UnixStream::pair().unwrap();
        send_envelope(&mut a, &Envelope::request("verify", 1, json!({"pin": "1234"}))).unwrap();
        let mut got = recv_envelope(&mut b).unwrap().unwrap();
        assert_eq!(got.op, "verify");
        assert_eq!(got.payload.as_ref().unwrap()["pin"].as_str().unwrap(), "1234");
        got.scrub();
        assert_eq!(got.payload.as_ref().unwrap()["pin"].as_str().unwrap(), "\0\0\0\0");
    }

    #[test]
    fn zeroize_string_keeps_length_and_utf8() {
        let mut s = String::from("héllo-wörld");
        let len = s.len();
        zeroize_string(&mut s);
        assert_eq!(s.len(), len);
        assert!(s.bytes().all(|b| b == 0));
    }
}
