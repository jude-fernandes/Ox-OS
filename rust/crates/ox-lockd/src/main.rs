//! lockd: the lock-secret owner. The lock screen (ox-shell) sends
//! `verify {pin}`; Settings sends `enroll {current,new}`. Keeping the
//! secret out of UI processes means the lockscreen is replaceable and
//! the store has exactly one writer. Store format v1:
//! `v1:<salt_hex>:<hash_hex>` — 16-byte urandom salt, 4096 rounds of
//! iterated SHA-256 (via ox-pay-proto, RFC-vector-tested). First boot
//! enrolls the DEV default (1234) as a hash; a corrupted record
//! re-enrolls fail-safe.
use ox_ipc::{scrub_value, serve, Envelope};
use serde_json::{json, Value};
use std::io::{Read as _, Write as _};
use std::path::PathBuf;

use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

const PIN_ROUNDS: u32 = 4096;
const PIN_PATH: &str = "/data/ox/lock.pin";
/// Optional duress PIN: unlocks the device but is FLAGGED so the shell
/// can trigger covert actions (alert / decoy / panic wipe — later
/// chunks). Absent file = no duress PIN enrolled.
const DURESS_PATH: &str = "/data/ox/lock.duress.pin";
/// Persisted lockout state (chunk 56): an attacker must not be able
/// to clear the backoff by power-cycling the device.
const THROTTLE_PATH: &str = "/data/ox/lock.throttle";
const THROTTLE_KEY_PATH: &str = "/data/ox/lock.throttle.key";
const PIN_MIN_LEN: usize = 4;
const PIN_MAX_LEN: usize = 8;
/// DEV ONLY default, enrolled as a salted hash on first boot. Never
/// stored in plaintext anywhere.
const DEV_DEFAULT_PIN: &str = "1234";
/// DEV ONLY duress PIN (hashed at first boot; production = user-chosen
/// via enroll-duress).
const DEV_DURESS: &str = "9999";

fn kmsg(line: &str) {
    eprintln!("lockd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>lockd: {}", line);
    }
}

fn sock_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("lockd.sock")
}

/// Best-effort memory hygiene: overwrite a secret buffer with volatile
/// zeroes so the compiler cannot elide the write. Transport-level
/// copies (envelopes, frames, payload clones) are covered by
/// ox-ipc's scrub on drop; the calls below cover lockd's own buffers.
fn zeroize(buf: &mut [u8]) {
    for b in buf.iter_mut() {
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// Iterated salted hash: stretching makes offline brute force cost
/// real time per guess. Every scratch buffer that carries the raw PIN
/// is zeroized before it goes out of scope.
fn hash_pin(salt: &[u8], pin: &str) -> [u8; 32] {
    let mut scratch = [salt, pin.as_bytes()].concat();
    let mut h = ox_pay_proto::sha256::sha256(&scratch);
    zeroize(&mut scratch);
    for _ in 1..PIN_ROUNDS {
        let mut buf = h.to_vec();
        buf.extend_from_slice(pin.as_bytes());
        h = ox_pay_proto::sha256::sha256(&buf);
        zeroize(&mut buf);
    }
    h
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

struct PinVerifier {
    salt: Vec<u8>,
    hash: [u8; 32],
}

impl Drop for PinVerifier {
    /// Rotating the PIN or wiping the device must not leave the old
    /// salt+hash sitting in freed memory: zeroize both before dealloc.
    fn drop(&mut self) {
        zeroize(&mut self.salt);
        zeroize(&mut self.hash);
    }
}

impl PinVerifier {
    fn verify(&self, pin: &str) -> bool {
        hash_pin(&self.salt, pin) == self.hash
    }

    fn verify_duress(&self, pin: &str) -> bool {
        PinVerifier::load_at(DURESS_PATH)
            .map(|d| d.verify(pin))
            .unwrap_or(false)
    }

    /// Enroll `pin` atomically (temp + rename) at `path`. Returns the
    /// new verifier only if the store write succeeded.
    fn enroll_at(path: &str, pin: &str) -> Option<Self> {
        let mut salt = vec![0u8; 16];
        std::fs::File::open("/dev/urandom")
            .ok()?
            .read_exact(&mut salt)
            .ok()?;
        let v = PinVerifier {
            hash: hash_pin(&salt, pin),
            salt,
        };
        let tmp = format!("{path}.tmp");
        std::fs::write(
            &tmp,
            format!("v1:{}:{}\n", hex_encode(&v.salt), hex_encode(&v.hash)),
        )
        .ok()?;
        std::fs::rename(&tmp, path).ok()?;
        Some(v)
    }

    fn enroll(pin: &str) -> Option<Self> {
        Self::enroll_at(PIN_PATH, pin)
    }

    /// Parse a stored verifier; None if missing/corrupt.
    fn load_at(path: &str) -> Option<Self> {
        let s = std::fs::read_to_string(path).ok()?;
        let parts: Vec<&str> = s.trim().split(':').collect();
        if parts.len() != 3 || parts[0] != "v1" {
            return None;
        }
        let salt = hex_decode(parts[1]).filter(|b| b.len() == 16)?;
        let mut hash = [0u8; 32];
        hash.copy_from_slice(&hex_decode(parts[2]).filter(|b| b.len() == 32)?);
        Some(PinVerifier { salt, hash })
    }

    /// Load the stored verifier, or enroll the DEV default on first
    /// boot (fresh data partition). A corrupted record re-enrolls.
    fn load() -> Self {
        if let Ok(s) = std::fs::read_to_string(PIN_PATH) {
            let parts: Vec<&str> = s.trim().split(':').collect();
            let salt = if parts.len() == 3 && parts[0] == "v1" {
                hex_decode(parts[1]).filter(|b| b.len() == 16)
            } else {
                None
            };
            let hash = if parts.len() == 3 && parts[0] == "v1" {
                hex_decode(parts[2])
                    .filter(|b| b.len() == 32)
                    .map(|b| {
                        let mut a = [0u8; 32];
                        a.copy_from_slice(&b);
                        a
                    })
            } else {
                None
            };
            if let (Some(salt), Some(hash)) = (salt, hash) {
                return PinVerifier { salt, hash };
            }
            kmsg("pin store unreadable — re-enrolling DEV default");
        }
        match PinVerifier::enroll(DEV_DEFAULT_PIN) {
            Some(v) => {
                kmsg("DEV ONLY: default PIN 1234 enrolled as salted hash v1 (development phase)");
                v
            }
            None => {
                kmsg("FATAL: cannot enroll PIN (urandom/write failed)");
                std::process::exit(1);
            }
        }
    }
}

fn valid_new_pin(pin: &str) -> bool {
    (PIN_MIN_LEN..=PIN_MAX_LEN).contains(&pin.len())
        && pin.chars().all(|c| c.is_ascii_digit())
}

/// Consecutive-wrong-attempt state for throttling. Wall-clock
/// (SystemTime) so the record persists across reboots: power-cycling
/// the device must not clear an attacker's backoff.
#[derive(Default)]
struct Throttle {
    consecutive: u64,
    delay_until: Option<SystemTime>,
}

impl Throttle {
    /// Exponential backoff on consecutive wrong attempts: 1s, 2s, 4s…
    /// capped at 60s. A successful verify resets it (the OWNER is never
    /// punished for a typo beyond the immediate wait).
    fn delay_for(consecutive: u64) -> Duration {
        let shift = consecutive.saturating_sub(1).min(6) as u32;
        let secs = 1u64.checked_shl(shift).unwrap_or(64);
        Duration::from_secs(secs.min(60))
    }

    fn wait_if_due(&self) -> Option<Duration> {
        let now = SystemTime::now();
        self.delay_until
            .and_then(|t| t.duration_since(now).ok())
            .filter(|r| !r.is_zero())
    }

    fn record_failure(&mut self) -> Duration {
        self.consecutive = self.consecutive.saturating_add(1);
        let d = Self::delay_for(self.consecutive);
        self.delay_until = Some(SystemTime::now() + d);
        d
    }

    fn record_success(&mut self) {
        self.consecutive = 0;
        self.delay_until = None;
    }

    /// HMAC key for the persisted record: per-install, created from
    /// urandom on first persist, stored next to the record (the
    /// threat is a locked-device power cycle, not an offline mount).
    fn load_key_at(key_path: &str) -> [u8; 32] {
        if let Ok(k) = std::fs::read(key_path) {
            if k.len() == 32 {
                let mut a = [0u8; 32];
                a.copy_from_slice(&k);
                return a;
            }
        }
        let mut k = [0u8; 32];
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut k);
        }
        let tmp = format!("{}.tmp", key_path);
        let _ = std::fs::write(&tmp, k);
        let _ = std::fs::rename(&tmp, key_path);
        k
    }

    /// Atomically persist the current state, HMAC-tagged.
    fn persist_at(&self, path: &str, key_path: &str) {
        let key = Self::load_key_at(key_path);
        let delay_ms = self
            .delay_until
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let mut nonce = [0u8; 8];
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut nonce);
        }
        let nonce_hex = hex_encode(&nonce);
        let body = format!(
            "v1:{}:{}:{}", self.consecutive, delay_ms, nonce_hex
        );
        let mac = hex_encode(&ox_pay_proto::hmac::hmac_sha256(&key, body.as_bytes()));
        let tmp = format!("{}.tmp", path);
        if std::fs::write(&tmp, format!("{}:{}", body, mac)).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }

    /// Restore a persisted record. None = fresh state (absent file
    /// or tampered record — the owner is never punished for tampering
    /// they cannot have caused from a locked device).
    fn load_at(path: &str, key_path: &str) -> Option<Throttle> {
        let key = Self::load_key_at(key_path);
        let raw = match std::fs::read_to_string(path) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("load_at: read failed: {}", e);
                return None;
            }
        };
        let raw = raw.trim();
        let last = match raw.rfind(':') {
            Some(i) => i,
            None => {
                eprintln!("load_at: no colon in {:?}", raw);
                return None;
            }
        };
        let body = raw.get(..last)?;
        let mac_hex = raw.get(last + 1..)?;
        let expect = hex_encode(&ox_pay_proto::hmac::hmac_sha256(&key, body.as_bytes()));
        if expect != mac_hex {
            eprintln!("load_at: mac mismatch expect={} got={} body={}", expect, mac_hex, body);
            return None;
        }
        let parts: Vec<&str> = body.split(':').collect();
        if parts.len() != 4 || parts[0] != "v1" {
            return None;
        }
        let consecutive = parts[1].parse().ok()?;
        let delay_ms: u128 = parts[2].parse().ok()?;
        let delay_until = if delay_ms > 0 {
            Some(std::time::UNIX_EPOCH + Duration::from_millis(delay_ms as u64))
        } else {
            None
        };
        Some(Throttle { consecutive, delay_until })
    }

    fn persist(&self) {
        self.persist_at(THROTTLE_PATH, THROTTLE_KEY_PATH);
    }

    fn load() -> Option<Throttle> {
        Throttle::load_at(THROTTLE_PATH, THROTTLE_KEY_PATH)
    }
}

fn handle_req(
    v: &Arc<Mutex<PinVerifier>>,
    throttle: &Arc<Mutex<Throttle>>,
    env: &mut Envelope,
) -> Envelope {
    match env.op.as_str() {
        "verify" => {
            let pin = env
                .payload
                .as_ref()
                .and_then(|p| p.get("pin"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            {
                let t = throttle.lock().unwrap();
                if let Some(remaining) = t.wait_if_due() {
                    kmsg(&format!(
                        "pin-verify-throttled remaining_ms={}",
                        remaining.as_millis()
                    ));
                    return env.ok(json!({
                        "ok": false,
                        "throttled": true,
                        "retry_after_ms": remaining.as_millis() as u64
                    }));
                }
            }
            let (ok, duress) = {
                let v = v.lock().unwrap();
                let matched = v.verify_duress(pin);
                if matched {
                    // Duress PIN: unlocks, but FLAGGED (panic/alert
                    // hook in the shell). It must differ from the real
                    // PIN, so it can never fall through to ok=true
                    // silently.
                    kmsg("OXMILESTONE name=pin-verify-duress");
                    (true, true)
                } else {
                    (v.verify(pin), false)
                }
            };
            let mut t = throttle.lock().unwrap();
            if ok {
                if duress {
                    kmsg("OXMILESTONE name=pin-verify-duress");
                }
                if t.consecutive > 0 {
                    kmsg("OXMILESTONE name=pin-verify-success-after-failures");
                }
                t.record_success();
                t.persist();
            } else {
                let d = t.record_failure();
                t.persist();
                kmsg(&format!(
                    "pin-verify-denied throttle-next-ms={}",
                    d.as_millis()
                ));
            }
            env.ok(json!({ "ok": ok, "throttled": false, "duress": duress }))
        }
        "enroll" => {
            let mut payload = env.payload.clone().unwrap_or(Value::Null);
            enum Enroll {
                WrongCurrent,
                InvalidNew,
                StoreFailed,
                Rotated { old_rejected: bool, new_accepted: bool, nv: PinVerifier },
            }
            let verdict = {
                let current = payload.get("current").and_then(|v| v.as_str()).unwrap_or("");
                let new = payload.get("new").and_then(|v| v.as_str()).unwrap_or("");
                if !v.lock().unwrap().verify(current) {
                    kmsg("pin-enroll-refused reason=wrong-current");
                    Enroll::WrongCurrent
                } else if !valid_new_pin(new) {
                    kmsg("pin-enroll-refused reason=invalid-new");
                    Enroll::InvalidNew
                } else {
                    match PinVerifier::enroll(new) {
                        None => {
                            kmsg("pin-enroll-refused reason=store-write-failed");
                            Enroll::StoreFailed
                        }
                        Some(nv) => {
                            // Self-verify the rotation before acknowledging it.
                            Enroll::Rotated {
                                old_rejected: !nv.verify(current),
                                new_accepted: nv.verify(new),
                                nv,
                            }
                        }
                    }
                }
            };
            // every path through the arm funnels here: the wire copies
            // of both PINs die inside the cloned payload
            scrub_value(&mut payload);
            match verdict {
                Enroll::WrongCurrent => env.err("wrong current PIN"),
                Enroll::InvalidNew => env.err("invalid new PIN (4-8 digits)"),
                Enroll::StoreFailed => env.err("store write failed"),
                Enroll::Rotated { old_rejected, new_accepted, nv } => {
                    kmsg(&format!(
                        "OXMILESTONE name=pin-changed old-rejected={old_rejected} new-accepted={new_accepted}"
                    ));
                    if old_rejected && new_accepted {
                        *v.lock().unwrap() = nv;
                        env.ok(json!({ "changed": true }))
                    } else {
                        kmsg("pin-enroll-refused reason=self-verify-failed");
                        env.err("self-verify failed")
                    }
                }
            }
        }
        "panic-wipe" => {
            // Triggered by the shell after a DURESS unlock (the caller
            // authenticated with the duress PIN). Destroys all user
            // secrets under /data/ox; a reboot then re-seeds a factory
            // device. Best-effort file removal, fully journaled.
            let targets = [
                PIN_PATH,
                DURESS_PATH,
                THROTTLE_PATH,
                THROTTLE_KEY_PATH,
                "/data/ox/permstore.json",
                "/data/ox/contacts.json",
            ];
            let mut removed = 0;
            for t in targets {
                if std::fs::remove_file(t).is_ok() {
                    removed += 1;
                }
            }
            let apps_gone =
                std::fs::remove_dir_all("/data/ox/apps").is_ok();
            let _ = std::fs::File::open("/dev/urandom"); // barrier
            if let Err(e) = std::fs::File::create("/data/ox/.wiped") {
                kmsg(&format!("panic-wipe marker failed: {e}"));
            }
            // The wipe must extend to RAM: swap the live verifier for
            // an unusable zeroed one — the Drop on the old verifier
            // zeroizes its salt+hash, and the running daemon stops
            // authenticating the old PIN (it previously kept doing so
            // until reboot). The duress verifier is disk-loaded per
            // call, so removing the file already disables it; the
            // throttle resets to factory behavior.
            {
                let dead = std::mem::replace(
                    &mut *v.lock().unwrap(),
                    PinVerifier {
                        salt: vec![0u8; 16],
                        hash: [0u8; 32],
                    },
                );
                drop(dead);
                *throttle.lock().unwrap() = Throttle {
                    consecutive: 0,
                    delay_until: None,
                };
            }
            kmsg(&format!(
                "OXMILESTONE name=panic-wipe-executed files={removed} apps={apps_gone}"
            ));
            env.ok(json!({ "wiped": true, "files": removed }))
        }
        "status" => env.ok(json!({ "service": "lockd" })),
        "enroll-duress" => {
            // Covert PIN: verifies like the real one but is FLAGGED so
            // the shell can trigger covert actions (alert / decoy /
            // panic wipe — later chunks). Enrolled only by the current
            // PIN, must differ from it.
            let mut payload = env.payload.clone().unwrap_or(Value::Null);
            enum Duress {
                WrongCurrent,
                InvalidDuress,
                SameAsCurrent,
                StoreFailed,
                Enrolled { self_verified: bool },
            }
            let verdict = {
                let current = payload.get("current").and_then(|v| v.as_str()).unwrap_or("");
                let duress = payload.get("duress").and_then(|v| v.as_str()).unwrap_or("");
                if !v.lock().unwrap().verify(current) {
                    kmsg("duress-enroll-refused reason=wrong-current");
                    Duress::WrongCurrent
                } else if !valid_new_pin(duress) {
                    kmsg("duress-enroll-refused reason=invalid-duress");
                    Duress::InvalidDuress
                } else if v.lock().unwrap().verify(duress) {
                    kmsg("duress-enroll-refused reason=same-as-current");
                    Duress::SameAsCurrent
                } else {
                    match PinVerifier::enroll_at(DURESS_PATH, duress) {
                        None => {
                            kmsg("duress-enroll-refused reason=store-write-failed");
                            Duress::StoreFailed
                        }
                        Some(dv) => Duress::Enrolled { self_verified: dv.verify(duress) },
                    }
                }
            };
            // same funnel as enroll: both wire PIN copies die here on
            // every path
            scrub_value(&mut payload);
            match verdict {
                Duress::WrongCurrent => env.err("wrong current PIN"),
                Duress::InvalidDuress => env.err("invalid duress PIN (4-8 digits)"),
                Duress::SameAsCurrent => env.err("duress PIN must differ from the current PIN"),
                Duress::StoreFailed => env.err("store write failed"),
                Duress::Enrolled { self_verified } => {
                    kmsg(&format!(
                        "OXMILESTONE name=duress-enrolled self-verified={self_verified}"
                    ));
                    if self_verified {
                        env.ok(json!({ "enrolled": true }))
                    } else {
                        env.err("self-verify failed")
                    }
                }
            }
        }
        "selftest-scrub" => {
            // Runtime proof for the lockd-selftest service: a decoy
            // secret that rode the real wire must read back all-zero
            // after the scrub path runs on it, observed in THIS guest
            // binary. Returns a boolean about lockd's own scrub of a
            // caller-supplied value — it leaks nothing.
            let mut p = env.payload.clone().unwrap_or(Value::Null);
            let rode = p
                .get("decoy")
                .and_then(|v| v.as_str())
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            scrub_value(&mut p);
            let clean = match p.get("decoy") {
                Some(Value::String(s)) => !s.is_empty() && s.bytes().all(|b| b == 0),
                _ => false,
            };
            if rode && clean {
                kmsg("OXMILESTONE name=ipc-scrub bytes-zeroed=true");
                env.ok(json!({ "clean": true }))
            } else {
                kmsg(&format!("OXMILESTONE name=ipc-scrub-failed rode={rode} clean={clean}"));
                env.err("scrub verification failed")
            }
        }
        "status" => env.ok(json!({ "service": "lockd" })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let v = Arc::new(Mutex::new(PinVerifier::load()));
    // DEV ONLY: enroll a duress PIN (hashed) on first boot so the
    // covert-unlock path is exercisable. Production: user-chosen
    // duress PIN via enroll-duress (the op already exists).
    if PinVerifier::load_at(DURESS_PATH).is_none() {
        match PinVerifier::enroll_at(DURESS_PATH, DEV_DURESS) {
            Some(dv) if dv.verify(DEV_DURESS) => {
                kmsg("DEV ONLY: duress PIN enrolled as salted hash v1 (development phase)")
            }
            _ => kmsg("duress enroll failed (dev default)"),
        }
    }
    let (throttle_state, restored) = match Throttle::load() {
        Some(t) => {
            kmsg(&format!(
                "OXMILESTONE name=throttle-restored consecutive={}",
                t.consecutive
            ));
            (t, true)
        }
        None => {
            kmsg("OXMILESTONE name=throttle-fresh");
            (Throttle::default(), false)
        }
    };
    let _ = restored;
    let throttle = Arc::new(Mutex::new(throttle_state));
    let hv = Arc::clone(&v);
    let ht = Arc::clone(&throttle);
    let _server = serve(sock_path(), move |env| handle_req(&hv, &ht, env))?;
    kmsg("OXMILESTONE name=lockd-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_verifier_accepts_only_the_enrolled_pin() {
        let v = PinVerifier {
            salt: vec![7u8; 16],
            hash: hash_pin(&[7u8; 16], "1234"),
        };
        assert!(v.verify("1234"));
        assert!(!v.verify("4321"));
        assert!(!v.verify(""));
        let v2 = PinVerifier {
            salt: vec![9u8; 16],
            hash: hash_pin(&[9u8; 16], "1234"),
        };
        assert_ne!(v.hash, v2.hash, "salt diversity must change the digest");
    }

    #[test]
    fn zeroize_overwrites_the_whole_buffer() {
        let mut buf = vec![0xA5u8; 64];
        zeroize(&mut buf);
        assert!(buf.iter().all(|&b| b == 0), "secret bytes must be gone");
        // and on the empty edge case it must not panic
        let mut empty: Vec<u8> = Vec::new();
        zeroize(&mut empty);
    }

    #[test]
    fn zeroed_placeholder_verifier_never_authenticates() {
        // what panic-wipe swaps in: no PIN may ever verify against it
        let dead = PinVerifier {
            salt: vec![0u8; 16],
            hash: [0u8; 32],
        };
        for pin in ["", "1234", "9999", "0000"] {
            assert!(!dead.verify(pin), "wiped verifier accepted {pin}");
        }
    }

    #[test]
    fn verifier_record_roundtrips_through_the_store_format() {
        let salt = vec![0xabu8; 16];
        let hash = hash_pin(&salt, "9999");
        let s = format!("v1:{}:{}", hex_encode(&salt), hex_encode(&hash));
        // parse it back the way load() does
        let parts: Vec<&str> = s.split(':').collect();
        assert_eq!(parts[0], "v1");
        let salt2 = hex_decode(parts[1]).unwrap();
        let mut hash2 = [0u8; 32];
        hash2.copy_from_slice(&hex_decode(parts[2]).unwrap());
        let parsed = PinVerifier {
            salt: salt2,
            hash: hash2,
        };
        assert!(parsed.verify("9999"));
        assert!(!parsed.verify("1234"));
    }

    #[test]
    fn throttle_escalates_and_resets() {
        let mut t = Throttle {
            consecutive: 0,
            delay_until: None,
        };
        assert_eq!(t.wait_if_due(), None, "no delay before any failure");
        let d1 = t.record_failure();
        assert_eq!(d1, Duration::from_secs(1));
        let d2 = t.record_failure();
        assert_eq!(d2, Duration::from_secs(2));
        let d3 = t.record_failure();
        assert_eq!(d3, Duration::from_secs(4));
        // 10 consecutive failures: capped at 60s
        for _ in 0..7 {
            let d = t.record_failure();
            assert!(d <= Duration::from_secs(60));
        }
        assert!(t.record_failure() <= Duration::from_secs(60));
        // success resets everything
        t.record_success();
        assert_eq!(t.consecutive, 0);
        assert_eq!(t.wait_if_due(), None);
        // a failure after reset starts over at 1s
        assert_eq!(t.record_failure(), Duration::from_secs(1));
    }

    #[test]
    fn throttle_delay_window_is_respected() {
        let mut t = Throttle {
            consecutive: 0,
            delay_until: None,
        };
        t.record_failure();
        // immediately after a failure there IS a delay due
        assert!(t.wait_if_due().is_some());
    }

    #[test]
    fn new_pins_must_be_four_to_eight_digits() {
        assert!(valid_new_pin("1234"));
        assert!(valid_new_pin("12345678"));
        assert!(!valid_new_pin("123")); // too short
        assert!(!valid_new_pin("123456789")); // too long
        assert!(!valid_new_pin("12a4")); // not digits
        assert!(!valid_new_pin("")); // empty
    }

    #[test]
    fn throttle_persists_roundtrip_and_detects_tamper() {
        let dir = std::env::temp_dir().join("oxlockd-t56");
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("t").to_str().unwrap().to_string();
        let k = dir.join("k").to_str().unwrap().to_string();
        let t = Throttle {
            consecutive: 5,
            delay_until: Some(SystemTime::now() + Duration::from_secs(30)),
        };
        t.persist_at(&f, &k);
        let t2 = Throttle::load_at(&f, &k).expect("record must restore");
        assert_eq!(t2.consecutive, 5);
        assert!(t2.wait_if_due().is_some(), "delay must survive a reboot");
        // tamper with the counter: the MAC must reject it
        let raw = std::fs::read_to_string(&f).unwrap();
        let forged = raw.replacen("v1:5:", "v1:0:", 1);
        std::fs::write(&f, forged).unwrap();
        assert!(
            Throttle::load_at(&f, &k).is_none(),
            "forged record must be rejected"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn throttle_escalation_survives_a_reboot() {
        let dir = std::env::temp_dir().join("oxlockd-t56b");
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("t").to_str().unwrap().to_string();
        let k = dir.join("k").to_str().unwrap().to_string();
        let mut t = Throttle::default();
        t.record_failure();
        t.record_failure();
        t.record_failure();
        t.persist_at(&f, &k);
        // reboot: a fresh Throttle restored from disk must know the
        // count and keep escalating (4th failure = 8s)
        let mut t2 = Throttle::load_at(&f, &k).expect("must restore");
        assert_eq!(t2.consecutive, 3);
        assert_eq!(t2.record_failure(), Duration::from_secs(8));
        t2.record_success();
        t2.persist_at(&f, &k);
        let t3 = Throttle::load_at(&f, &k).unwrap();
        assert_eq!(t3.consecutive, 0, "owner success must persist too");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn hash_is_stretched_over_many_rounds() {
        let single = ox_pay_proto::sha256::sha256(b"abcdef1234");
        let stretched = hash_pin(b"abcdef", "1234");
        assert_ne!(&single[..], &stretched[..]);
    }
}
