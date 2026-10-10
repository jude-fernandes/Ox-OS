//! User-activity reporting for the power policy: keys.rs and pointer.rs
//! stamp a monotonic "last input" clock here, and a reporter thread feeds
//! powerd at most once per interval. Idle auto-suspend (doze) is powerd's
//! decision; oxcom is just the activity sensor.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Milliseconds since boot of the last input event (keyboard or pointer).
static LAST_INPUT_MS: AtomicU64 = AtomicU64::new(0);
static REPORTER_STARTED: OnceLock<()> = OnceLock::new();

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Record user input (called from input hot paths — lock-free).
pub fn mark_activity() {
    LAST_INPUT_MS.store(now_ms(), Ordering::Relaxed);
    ensure_reporter();
}

fn ensure_reporter() -> () {
    if REPORTER_STARTED.set(()).is_ok() {
        std::thread::spawn(report_loop);
    }
}

/// Notify powerd when the activity timestamp advanced since our last
/// report — at most one IPC call per second no matter how fast the user
/// types or moves.
fn report_loop() {
    // Start at 0 so the FIRST activity after the reporter exists is reported;
    // initializing from the current value would swallow exactly that one.
    let mut last_reported: u64 = 0;
    loop {
        std::thread::sleep(Duration::from_secs(1));
        let cur = LAST_INPUT_MS.load(Ordering::Relaxed);
        if cur == 0 || cur == last_reported {
            continue;
        }
        last_reported = cur;
        notify_powerd();
    }
}

fn notify_powerd() {
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("/run/ox/sockets"))
        .join("powerd.sock");
    // best-effort: powerd may be absent (host tests, minimal builds)
    match ox_ipc::Client::connect(&sock) {
        Ok(mut cl) => match cl.request("activity", serde_json::json!(null)) {
            Ok(_) => eprintln!("oxcom: activity reported"),
            Err(e) => eprintln!("oxcom: activity request failed: {e}"),
        },
        Err(e) => eprintln!("oxcom: powerd connect failed ({e}): {}", sock.display()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mark_activity_advances_clock() {
        mark_activity();
        assert!(LAST_INPUT_MS.load(Ordering::Relaxed) > 0);
        let a = LAST_INPUT_MS.load(Ordering::Relaxed);
        std::thread::sleep(std::time::Duration::from_millis(5));
        mark_activity();
        assert!(LAST_INPUT_MS.load(Ordering::Relaxed) >= a);
    }

    #[test]
    fn reporter_starts_only_once() {
        mark_activity();
        mark_activity();
        mark_activity();
        // ensure_reporter is idempotent via OnceLock; nothing to assert
        // beyond "no panic", but touch the lock to prove it initializes.
        assert!(REPORTER_STARTED.get().is_some());
    }
}
