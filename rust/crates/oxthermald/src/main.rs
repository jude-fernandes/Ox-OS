//! thermald: Phase-2 thermal daemon. Reads one or more temperature
//! sources (milli-°C integers: /sys/class/thermal/thermal_zone*/temp
//! on hardware; any readable file on the virtual target, where QEMU
//! has no thermal zones) and enforces the thermal policy:
//!   warn    — sustained elevated temperature (log, notify)
//!   hot     — throttle tier (on hardware: clamp CPU via cpufreq)
//!   critical — emergency tier (on hardware: orderly power-off path)
//! Transitions are hysteresis-gated (a tier is left only when the
//! temperature drops HYST_OFF m°C below its entry threshold) and
//! upward transitions are journaled once, so gates can match them.
use ox_ipc::{serve, Envelope};
use serde_json::json;
use std::io::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const POLL_INTERVAL: Duration = Duration::from_secs(1);
/// A tier is left only when the temperature falls this far below its
/// entry threshold (anti-flapping).
pub const HYST_OFF_MC: i64 = 10_000;

fn kmsg(line: &str) {
    eprintln!("thermald: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>thermald: {}", line);
    }
}

/// Read a temperature source: a single integer, milli-°C.
pub fn read_temp_mc(path: &str) -> Option<i64> {
    let text = std::fs::read_to_string(path).ok()?;
    text.trim().parse().ok()
}

/// Thermal tier for a temperature: 0 normal, 1 warn, 2 hot, 3 critical.
pub fn tier_for(temp_mc: i64, warn: i64, hot: i64, critical: i64) -> u8 {
    if temp_mc >= critical {
        3
    } else if temp_mc >= hot {
        2
    } else if temp_mc >= warn {
        1
    } else {
        0
    }
}

/// Hysteresis: with the machine currently in `state`, decide the new
/// state for `temp`. Upward transitions use the entry thresholds
/// directly; a tier is LEFT only once the temperature is HYST_OFF_MC
/// below that tier's threshold (so a hovering temperature does not
/// flap the policy).
pub fn hysteresis(temp_mc: i64, state: u8, warn: i64, hot: i64, critical: i64) -> u8 {
    let target = tier_for(temp_mc, warn, hot, critical);
    if target >= state {
        return target;
    }
    // Cooling down: require the temperature to fall HYST_OFF below the
    // threshold of the tier we are currently in before stepping down.
    let tier_floor = match state {
        3 => critical,
        2 => hot,
        1 => warn,
        _ => return 0,
    };
    if temp_mc <= tier_floor - HYST_OFF_MC {
        state - 1
    } else {
        state
    }
}

#[derive(Default)]
pub struct Counters {
    pub warn: AtomicU64,
    pub hot: AtomicU64,
    pub critical: AtomicU64,
}

fn main() {
    let source = Arc::new(std::env::var("OX_THERMAL_SRC").unwrap_or_default());

    let counters = Arc::new(Counters::default());
    let config: Arc<Mutex<(i64, i64, i64)>> = Arc::new(Mutex::new((60_000, 75_000, 95_000)));
    let state: Arc<Mutex<u8>> = Arc::new(Mutex::new(0));

    {
        let counters = Arc::clone(&counters);
        let config = Arc::clone(&config);
        let state = Arc::clone(&state);
        let source_mon = Arc::clone(&source);
        std::thread::spawn(move || {
            loop {
                std::thread::sleep(POLL_INTERVAL);
                let temp = match read_temp_mc(&source_mon) {
                    Some(t) => t,
                    None => continue, // source absent or unreadable this tick
                };
                let (warn, hot, critical) = *config.lock().unwrap();
                let mut st = state.lock().unwrap();
                let new = hysteresis(temp, *st, warn, hot, critical);
                if new == *st {
                    continue;
                }
                if new > *st {
                    let milestone = match new {
                        1 => {
                            counters.warn.fetch_add(1, Ordering::Relaxed);
                            "thermald-warn"
                        }
                        2 => {
                            counters.hot.fetch_add(1, Ordering::Relaxed);
                            "thermald-hot"
                        }
                        _ => {
                            counters.critical.fetch_add(1, Ordering::Relaxed);
                            "thermald-critical"
                        }
                    };
                    kmsg(&format!(
                        "OXMILESTONE name={milestone} temp_mc={temp} action={}",
                        if new == 2 { "throttle" } else if new == 3 { "emergency" } else { "notify" }
                    ));
                } else {
                    kmsg(&format!("thermald cooled temp_mc={temp} state={new}"));
                }
                *st = new;
            }
        });
    }
    kmsg("OXMILESTONE name=thermald-ready");

    let h_counters = Arc::clone(&counters);
    let h_config = Arc::clone(&config);
    let h_state = Arc::clone(&state);
    let source_ipc = Arc::clone(&source);
    let handle = serve("/run/ox/sockets/thermald.sock", move |req: &mut Envelope| {
        match req.op.as_str() {
            "status" => {
                let temp = read_temp_mc(&source_ipc);
                let (w, h, c) = *h_config.lock().unwrap();
                req.ok(json!({
                    "source": source_ipc.as_str(),
                    "temp_mc": temp,
                    "state": *h_state.lock().unwrap(),
                    "warn_mc": w,
                    "hot_mc": h,
                    "critical_mc": c,
                    "warn_events": h_counters.warn.load(Ordering::Relaxed),
                    "hot_events": h_counters.hot.load(Ordering::Relaxed),
                    "critical_events": h_counters.critical.load(Ordering::Relaxed),
                }))
            }
            "config" => {
                let get = |k: &str| -> Option<i64> {
                    req.payload.as_ref()?.get(k)?.as_i64()
                };
                let mut cfg = h_config.lock().unwrap();
                if let Some(v) = get("warn_mc") {
                    cfg.0 = v;
                }
                if let Some(v) = get("hot_mc") {
                    cfg.1 = v;
                }
                if let Some(v) = get("critical_mc") {
                    cfg.2 = v;
                }
                let (w, h, c) = *cfg;
                if !(w < h && h < c) {
                    return req.err("thresholds must be strictly ordered warn < hot < critical");
                }
                req.ok(json!({ "warn_mc": w, "hot_mc": h, "critical_mc": c }))
            }
            _ => req.err("unknown op (status|config)"),
        }
    });

    match handle {
        Ok(_) => {
            kmsg("IPC up at /run/ox/sockets/thermald.sock");
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
    fn tiers_escalate_and_have_hysteresis() {
        // thresholds 60/75/95 (°C)
        assert_eq!(tier_for(59_000, 60_000, 75_000, 95_000), 0);
        assert_eq!(tier_for(60_000, 60_000, 75_000, 95_000), 1);
        assert_eq!(tier_for(75_000, 60_000, 75_000, 95_000), 2);
        assert_eq!(tier_for(95_000, 60_000, 75_000, 95_000), 3);

        // in warn state: hovering at 55 m°C below warn does NOT step down
        assert_eq!(hysteresis(55_000, 1, 60_000, 75_000, 95_000), 1);
        // falling 10° below warn leaves the tier
        assert_eq!(hysteresis(50_000, 1, 60_000, 75_000, 95_000), 0);
        // rising from normal straight to hot is allowed
        assert_eq!(hysteresis(80_000, 0, 60_000, 75_000, 95_000), 2);
        // in critical: only leaves when 10° below critical
        assert_eq!(hysteresis(90_000, 3, 60_000, 75_000, 95_000), 3);
        assert_eq!(hysteresis(85_000, 3, 60_000, 75_000, 95_000), 2);
    }

    #[test]
    fn temp_source_parsing() {
        // write/read round trip through a temp file
        let p = "/tmp/oxthermald-test-temp";
        std::fs::write(p, "65000\n").unwrap();
        assert_eq!(read_temp_mc(p), Some(65000));
        std::fs::write(p, "junk").unwrap();
        assert_eq!(read_temp_mc(p), None);
        std::fs::remove_file(p).ok();
    }
}
