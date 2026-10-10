//! powerd: Phase-2 power daemon (battery mandate). Owns the suspend path:
//! arms the RTC wakealarm, writes `mem` to /sys/power/state (the write
//! blocks until resume), accounts every cycle, and enforces budget rules.
//!
//! Policy on top: **idle doze** — oxcom reports user activity (throttled),
//! and when the machine has been idle longer than `OX_IDLE_TIMEOUT_SECS`
//! with no wake locks held, powerd auto-suspends; the RTC wakes it into a
//! short maintenance window, after which it returns to sleep if still idle.
//! Clients can hold **wake locks** to keep the machine awake (e.g. an
//! in-progress payment).
use ox_ipc::{serve, Envelope};
use serde_json::json;
use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Minimum wall time between suspend cycles (anti-thrash budget).
pub const MIN_INTERVAL: Duration = Duration::from_secs(5);
/// Max suspend length a single request may ask for.
pub const MAX_SUSPEND_SECS: u64 = 3600;

fn kmsg(line: &str) {
    // stderr + kernel ring, same dual-channel rule as the other daemons
    eprintln!("powerd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>powerd: {}", line);
    }
}

fn tms() -> f64 {
    std::fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|s| s.split(' ').next().and_then(|v| v.parse().ok()))
        .unwrap_or(0.0)
}

#[derive(Debug, Default)]
pub struct PowerState {
    pub suspends: u64,
    pub refusals: u64,
    pub last_resume: Option<Instant>,
    pub last_activity: Option<Instant>,
    /// Held wake locks: id -> acquired_at.
    pub wake_locks: HashMap<String, Instant>,
}

/// Pure decision for the idle policy (unit-tested without any hardware).
pub fn should_autosuspend(
    state: &PowerState,
    idle: Duration,
    timeout: Duration,
) -> Result<(), &'static str> {
    if timeout.is_zero() {
        return Err("autosuspend disabled");
    }
    if !state.wake_locks.is_empty() {
        return Err("wake locks held");
    }
    if idle < timeout {
        return Err("not idle long enough");
    }
    if let Some(last) = state.last_resume {
        if last.elapsed() < MIN_INTERVAL {
            return Err("anti-thrash window");
        }
    }
    Ok(())
}

/// Budget precheck (bounds + anti-thrash); counts a refusal on failure.
pub fn precheck(state: &mut PowerState, seconds: u64) -> Result<(), String> {
    if seconds == 0 || seconds > MAX_SUSPEND_SECS {
        state.refusals += 1;
        return Err(format!("seconds out of range 1..={MAX_SUSPEND_SECS}"));
    }
    if let Some(last) = state.last_resume {
        if last.elapsed() < MIN_INTERVAL {
            state.refusals += 1;
            return Err("budget: suspend requested too soon after resume".into());
        }
    }
    Ok(())
}

/// Budget check + RTC programming + the suspend syscall itself.
pub fn suspend(state: &mut PowerState, seconds: u64, reason: &str) -> Result<(), String> {
    precheck(state, seconds)?;
    // Arm the wakealarm from the RTC'S OWN clock (since_epoch): the
    // system clock can still be 1970 when the drill races rtc0's
    // hctosys clock-set during boot, and an epoch computed from
    // SystemTime would land in 1970 — the machine would never wake.
    // The horizon is clamped to >=30s: the suspend transition itself
    // takes seconds under TCG, and an alarm that expires DURING the
    // freeze is swallowed — the machine never wakes.
    let base = std::fs::read_to_string("/sys/class/rtc/rtc0/since_epoch")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0)
        });
    let epoch = base + seconds.max(30);
    std::fs::write("/sys/class/rtc/rtc0/wakealarm", epoch.to_string())
        .map_err(|e| format!("wakealarm: {e}"))?;
    kmsg(&format!(
        "OXMILESTONE name=pm-suspend-request reason={} secs={} epoch={}",
        reason, seconds, epoch
    ));
    std::fs::write("/sys/power/state", "mem").map_err(|e| format!("suspend: {e}"))?;
    // resumed
    state.suspends += 1;
    state.last_resume = Some(Instant::now());
    kmsg(&format!(
        "OXMILESTONE name=pm-resumed n={} tms={}",
        state.suspends,
        tms()
    ));
    Ok(())
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("powerd.sock")
}

fn idle_timeout() -> Duration {
    Duration::from_secs(
        std::env::var("OX_IDLE_TIMEOUT_SECS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(60),
    )
}

fn handle(state: &mut PowerState, req: &Envelope) -> Envelope {
    let null = serde_json::Value::Null;
    let payload = req.payload.as_ref().unwrap_or(&null);
    match req.op.as_str() {
        "status" => req.ok(json!({
            "service": "powerd",
            "suspends": state.suspends,
            "refusals": state.refusals,
            "wake_locks": state.wake_locks.keys().cloned().collect::<Vec<_>>(),
            "idle_timeout_s": idle_timeout().as_secs(),
        })),
        "activity" => {
            state.last_activity = Some(Instant::now());
            kmsg("OXMILESTONE name=pm-activity");
            req.ok(json!({ "noted": true }))
        }
        "wake-lock" => {
            let id = payload.get("id").and_then(|v| v.as_str()).unwrap_or("");
            if id.is_empty() {
                return req.err("id: missing");
            }
            if payload.get("release").and_then(|v| v.as_bool()).unwrap_or(false) {
                state.wake_locks.remove(id);
                kmsg(&format!("OXMILESTONE name=wake-lock-release id={id}"));
            } else {
                state.wake_locks.insert(id.to_string(), Instant::now());
                kmsg(&format!("OXMILESTONE name=wake-lock-acquire id={id}"));
            }
            req.ok(json!({ "held": state.wake_locks.len() }))
        }
        "suspend" => {
            let secs = payload.get("seconds").and_then(|v| v.as_u64()).unwrap_or(0);
            match suspend(state, secs, "manual") {
                Ok(()) => req.ok(json!({ "suspended": secs, "n": state.suspends })),
                Err(e) => req.err(&e),
            }
        }
        _ => req.err("unknown op"),
    }
}

/// Idle doze loop: auto-suspend when idle past the timeout with no locks.
fn start_idle_policy(state: Arc<Mutex<PowerState>>) {
    std::thread::spawn(move || {
        let timeout = idle_timeout();
        loop {
            std::thread::sleep(Duration::from_secs(2));
            let mut s = state.lock().unwrap();
            let idle = s
                .last_activity
                .map(|a| a.elapsed())
                .unwrap_or_else(|| {
                    // No activity report yet (compositor not up): idle since boot.
                    eprintln!("powerd: no activity source yet — idle clock from boot");
                    Duration::from_secs(u64::MAX)
                });
            if should_autosuspend(&s, idle, timeout).is_ok() {
                kmsg(&format!(
                    "OXMILESTONE name=pm-autosuspend idle_s={} locks={}",
                    idle.as_secs(),
                    s.wake_locks.len()
                ));
                let _ = suspend(&mut s, 8, "idle");
            }
        }
    });
}

fn main() -> std::io::Result<()> {
    let sock = socket_path();
    let state = Arc::new(Mutex::new(PowerState::default()));

    // `--no-pm` (cmdline ox.pm_drill=off, set by gates): deterministic
    // boots — no suspend drill, no idle doze. The PM behavior stays
    // gated by the dedicated PM gates, which boot without the flag.
    let pm_disabled = std::env::args().any(|a| a == "--no-pm");

    // Boot self-test (guest-only): one supervised cycle through the real
    // suspend path. The idle policy starts only after it — otherwise the
    // idle clock (empty until first input) would fire a doze cycle at t=2s
    // and the selftest would die in the anti-thrash window.
    if pm_disabled {
        kmsg("OXMILESTONE name=pm-drill-skipped reason=ox.pm_drill=off");
    } else if std::env::var_os("OX_PM_SELFTEST").is_some() {
        let st = Arc::clone(&state);
        std::thread::spawn(move || {
            // 30s (was 6s): the suspend must not race oxcom's initial
            // DRM claim. On this virtual target a modeset that overlaps
            // (or follows) the first suspend wedges in-kernel — the
            // display is lost for the boot no matter what userspace
            // does. Chunk-63's green runs were boots where oxcom's
            // ~1s claim beat the +6s suspend; the 6s window made the
            // gate a boot-order lottery, not a service assertion.
            // Real hardware has no boot suspend; +30s just gives the
            // claim a fair margin everywhere.
            std::thread::sleep(Duration::from_secs(30));
            kmsg("OXMILESTONE name=pm-selftest-begin");
            {
                let mut s = st.lock().unwrap();
                if let Err(e) = suspend(&mut s, 8, "selftest") {
                    kmsg(&format!("pm-selftest failed: {e}"));
                }
            }
            kmsg("OXMILESTONE name=pm-idle-policy-start");
            start_idle_policy(st);
        });
    } else {
        start_idle_policy(Arc::clone(&state));
    }

    eprintln!("powerd: serving on {}", sock.display());
    let handle_state = Arc::clone(&state);
    let _handle = serve(&sock, move |req| {
        handle(&mut handle_state.lock().unwrap(), req)
    })?;
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_policy_respects_timeout_locks_and_budget() {
        let mut st = PowerState::default();
        // disabled
        assert_eq!(
            should_autosuspend(&st, Duration::from_secs(999), Duration::ZERO),
            Err("autosuspend disabled")
        );
        // not idle enough
        assert_eq!(
            should_autosuspend(&st, Duration::from_secs(10), Duration::from_secs(60)),
            Err("not idle long enough")
        );
        // idle enough -> ok
        assert!(should_autosuspend(&st, Duration::from_secs(61), Duration::from_secs(60)).is_ok());
        // wake lock blocks it
        st.wake_locks.insert("txn".into(), Instant::now());
        assert_eq!(
            should_autosuspend(&st, Duration::from_secs(999), Duration::from_secs(60)),
            Err("wake locks held")
        );
        st.wake_locks.clear();
        // anti-thrash window after a resume
        st.last_resume = Some(Instant::now());
        assert_eq!(
            should_autosuspend(&st, Duration::from_secs(999), Duration::from_secs(60)),
            Err("anti-thrash window")
        );
    }

    #[test]
    fn budget_rejects_bad_requests() {
        let mut st = PowerState::default();
        assert!(precheck(&mut st, 0).is_err());
        assert_eq!(st.refusals, 1);
        assert!(precheck(&mut st, MAX_SUSPEND_SECS + 1).is_err());
        assert!(precheck(&mut st, 8).is_ok());
        st.last_resume = Some(Instant::now());
        assert!(precheck(&mut st, 8).is_err());
    }

    #[test]
    fn ops_drive_state_machine() {
        let req = |op: &str, v: serde_json::Value| Envelope::request(op, 1, v);
        let mut st = PowerState::default();
        let r = handle(&mut st, &req("status", json!(null)));
        assert_eq!(r.payload.unwrap()["suspends"], 0);
        let r = handle(&mut st, &req("suspend", json!({ "seconds": 0 })));
        assert!(r.error.is_some());
        assert_eq!(st.refusals, 1);
        // wake locks come and go
        handle(&mut st, &req("wake-lock", json!({ "id": "txn" })));
        assert_eq!(st.wake_locks.len(), 1);
        let r = handle(&mut st, &req("wake-lock", json!({ "id": "txn", "release": true })));
        assert_eq!(r.payload.unwrap()["held"], 0);
        // activity is noted
        assert!(handle(&mut st, &req("activity", json!(null))).payload.is_some());
        assert!(handle(&mut st, &req("bogus", json!(null))).error.is_some());
    }
}

