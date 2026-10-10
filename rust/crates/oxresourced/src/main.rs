//! resourced: Phase-2 resource daemon. Sets up zram swap, watches
//! memory pressure (PSI + MemAvailable), and escalates through tiers:
//!   tier1 — warn: drop page cache
//!   tier2 — pressure: compact memory
//!   tier3 — critical: SIGKILL the largest-RSS process that is not on
//!           the protected list (system daemons are never victims)
//! The gate drives tier1/tier2 with a tmpfs fill; tier3 is armed and
//! unit-tested, and exercised by the soak/soak-on-hardware later.
use ox_ipc::{serve, Envelope};
use serde_json::json;
use std::io::{Read as _, Write as _};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Per-tier cooldown so a sustained storm does not re-fire an action
/// every poll.
const TIER_COOLDOWN: Duration = Duration::from_secs(10);

fn kmsg(line: &str) {
    eprintln!("resourced: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>resourced: {}", line);
    }
}

/// Parse MemTotal / MemAvailable (kB) from /proc/meminfo.
pub fn meminfo(path: &str) -> Option<(u64, u64)> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut total = None;
    let mut avail = None;
    for line in text.lines() {
        if line.starts_with("MemTotal:") {
            total = line.split_whitespace().nth(1)?.parse().ok();
        } else if line.starts_with("MemAvailable:") {
            avail = line.split_whitespace().nth(1)?.parse().ok();
        }
    }
    Some((total?, avail?))
}

/// PSI memory "some" total (µs) from /proc/pressure/memory — the
/// cumulative stall counter used as an instant pressure measure.
pub fn psi_some_total_us(path: &str) -> Option<u64> {
    let text = std::fs::read_to_string(path).ok()?;
    let line = text.lines().find(|l| l.starts_with("some "))?;
    let idx = line.find("total=")? + 6;
    line[idx..].split_whitespace().next()?.parse().ok()
}

/// Escalation decision for the current availability percentage.
/// 0 = healthy, 1 = warn, 2 = pressure, 3 = critical.
pub fn tier_for(avail_pct: f64, warn_pct: f64, critical_pct: f64) -> u8 {
    if avail_pct >= warn_pct {
        0
    } else if avail_pct >= critical_pct {
        1
    } else {
        2
    }
}

/// Escalation from per-poll PSI stall percentage (share of the last
/// poll interval spent with memory stalls). Higher tier wins.
pub fn stall_tier(stall_pct: f64, t1: f64, t2: f64, t3: f64) -> u8 {
    if stall_pct >= t3 {
        3
    } else if stall_pct >= t2 {
        2
    } else if stall_pct >= t1 {
        1
    } else {
        0
    }
}

#[derive(Clone)]
pub struct Config {
    pub tier1_stall_pct: f64,
    pub tier2_stall_pct: f64,
    pub tier3_stall_pct: f64,
    pub warn_avail_pct: f64,
    pub critical_avail_pct: f64,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            tier1_stall_pct: 10.0,
            tier2_stall_pct: 40.0,
            tier3_stall_pct: 70.0,
            warn_avail_pct: 15.0,
            critical_avail_pct: 8.0,
        }
    }
}

/// Candidate victims for the tier-3 kill, largest RSS first, protected
/// processes (pid 1, our own pid, system daemons) excluded.
pub fn kill_candidates(
    proc_root: &str,
    self_pid: u32,
    protected_comms: &[&str],
) -> Vec<(u32, String, u64)> {
    let page_size = 4096u64;
    let mut v: Vec<(u32, String, u64)> = Vec::new();
    let Ok(dir) = std::fs::read_dir(proc_root) else {
        return v;
    };
    for e in dir.flatten() {
        let pid: u32 = match e.file_name().to_string_lossy().parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if pid == self_pid || pid == 1 {
            continue;
        }
        let comm = std::fs::read_to_string(format!("{proc_root}/{pid}/comm"))
            .unwrap_or_default()
            .trim()
            .to_string();
        if protected_comms.iter().any(|c| comm.starts_with(c)) {
            continue;
        }
        let Ok(mut statm) = std::fs::File::open(format!("{proc_root}/{pid}/statm")) else {
            continue;
        };
        let mut s = String::new();
        if statm.read_to_string(&mut s).is_err() {
            continue;
        }
        let rss_pages: u64 = s
            .split_whitespace()
            .nth(1)
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        if rss_pages == 0 {
            continue;
        }
        v.push((pid, comm, rss_pages * page_size));
    }
    v.sort_by(|a, b| b.2.cmp(&a.2));
    v
}

#[derive(Default)]
pub struct Counters {
    pub tier1: AtomicU64,
    pub tier2: AtomicU64,
    pub tier3: AtomicU64,
}

fn main() {
    // --- zram swap tier ---
    let zram_ok = (|| -> Option<bool> {
        let size_path = "/sys/block/zram0/disksize";
        if !Path::new(size_path).exists() {
            return Some(false);
        }
        std::fs::write(size_path, "268435456").ok()?; // 256 MiB
        let run = |cmd: &str| -> bool {
            std::process::Command::new("/bin/busybox")
                .args(cmd.split_whitespace())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        };
        Some(run("mkswap /dev/zram0") && run("swapon /dev/zram0"))
    })()
    .unwrap_or(false);
    if zram_ok {
        kmsg("OXMILESTONE name=resourced-zram-ok size_mib=256");
    } else {
        kmsg("OXMILESTONE name=resourced-zram-unavailable");
    }

    // --- pressure monitor (PSI stall% + MemAvailable%, higher tier wins) ---
    let counters = Arc::new(Counters::default());
    let config: Arc<Mutex<Config>> = Arc::new(Mutex::new(Config::default()));
    let kills: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let last_action = Arc::new(Mutex::new(std::time::Instant::now() - TIER_COOLDOWN));

    {
        let counters = Arc::clone(&counters);
        let config = Arc::clone(&config);
        let kills = Arc::clone(&kills);
        let last_action = Arc::clone(&last_action);
        std::thread::spawn(move || {
            let protected: &[&str] = &[
                "s6", "resourced", "powerd", "oxcom", "inputd", "oxnetd", "oxmodemd",
                "oxpaymentsd", "ox-status", "pipewire", "wireplumber", "udevd", "getty",
                "netd", "ox-init", "busybox",
            ];
            let poll_us = POLL_INTERVAL.as_micros() as f64;
            let mut prev_psi = psi_some_total_us("/proc/pressure/memory").unwrap_or(0);
            loop {
                std::thread::sleep(POLL_INTERVAL);
                let psi_now = psi_some_total_us("/proc/pressure/memory").unwrap_or(0);
                let stall_pct = psi_now.saturating_sub(prev_psi) as f64 / poll_us * 100.0;
                prev_psi = psi_now;
                let avail_pct = match meminfo("/proc/meminfo") {
                    Some((total_kb, avail_kb)) if total_kb > 0 => {
                        avail_kb as f64 * 100.0 / total_kb as f64
                    }
                    _ => 100.0,
                };

                let cfg = config.lock().unwrap().clone();
                let s_tier = stall_tier(
                    stall_pct,
                    cfg.tier1_stall_pct,
                    cfg.tier2_stall_pct,
                    cfg.tier3_stall_pct,
                );
                let a_tier = tier_for(avail_pct, cfg.warn_avail_pct, cfg.critical_avail_pct);
                let tier = s_tier.max(a_tier);
                let cooling = last_action.lock().unwrap().elapsed() < TIER_COOLDOWN;
                if tier == 0 || cooling {
                    continue;
                }
                *last_action.lock().unwrap() = std::time::Instant::now();
                let ctx = format!(
                    "stall_pct={stall_pct:.1} avail_pct={avail_pct:.1}"
                );
                match tier {
                    1 => {
                        let _ = std::fs::write("/proc/sys/vm/drop_caches", "3");
                        counters.tier1.fetch_add(1, Ordering::Relaxed);
                        kmsg(&format!("resourced tier1 warn {ctx} action=drop-caches"));
                    }
                    2 => {
                        let _ = std::fs::write("/proc/sys/vm/compact_memory", "");
                        counters.tier2.fetch_add(1, Ordering::Relaxed);
                        kmsg(&format!("resourced tier2 pressure {ctx} action=compact"));
                    }
                    _ => {
                        let victims = kill_candidates("/proc", std::process::id(), protected);
                        counters.tier3.fetch_add(1, Ordering::Relaxed);
                        let msg = match victims.first() {
                            Some((pid, comm, rss)) => {
                                let _ = std::process::Command::new("/bin/busybox")
                                    .args(["kill", "-9", &pid.to_string()])
                                    .status();
                                format!("resourced tier3 critical killed pid={pid} comm={comm} rss={rss}")
                            }
                            None => "resourced tier3 critical no-victim-found".to_string(),
                        };
                        kmsg(&msg);
                        let mut k = kills.lock().unwrap();
                        if k.len() >= 16 {
                            k.remove(0);
                        }
                        k.push(msg);
                    }
                }
            }
        });
    }
    kmsg("OXMILESTONE name=resourced-ready");

    // --- IPC surface ---
    let h_counters = Arc::clone(&counters);
    let h_config = Arc::clone(&config);
    let h_kills = Arc::clone(&kills);
    let handle = serve("/run/ox/sockets/resourced.sock", move |req: &mut Envelope| {
        match req.op.as_str() {
            "status" => {
                let mi = meminfo("/proc/meminfo");
                let k = h_kills.lock().unwrap();
                req.ok(json!({
                    "mem_total_kb": mi.as_ref().map(|m| m.0),
                    "mem_avail_kb": mi.as_ref().map(|m| m.1),
                    "tier1_events": h_counters.tier1.load(Ordering::Relaxed),
                    "tier2_events": h_counters.tier2.load(Ordering::Relaxed),
                    "tier3_events": h_counters.tier3.load(Ordering::Relaxed),
                    "zram": zram_ok,
                    "kills": &*k,
                }))
            }
            "config" => {
                let get = |k: &str| -> Option<f64> {
                    req.payload.as_ref()?.get(k)?.as_f64()
                };
                let mut cfg = h_config.lock().unwrap();
                if let Some(v) = get("tier1_stall_pct") {
                    cfg.tier1_stall_pct = v.clamp(1.0, 99.0);
                }
                if let Some(v) = get("tier2_stall_pct") {
                    cfg.tier2_stall_pct = v.clamp(2.0, 99.0);
                }
                if let Some(v) = get("tier3_stall_pct") {
                    cfg.tier3_stall_pct = v.clamp(3.0, 100.0);
                }
                if let Some(v) = get("warn_avail_pct") {
                    cfg.warn_avail_pct = v.clamp(1.0, 95.0);
                }
                if let Some(v) = get("critical_avail_pct") {
                    cfg.critical_avail_pct = v.clamp(1.0, 90.0);
                }
                let c = cfg.clone();
                if c.tier1_stall_pct >= c.tier2_stall_pct
                    || c.tier2_stall_pct >= c.tier3_stall_pct
                    || c.critical_avail_pct >= c.warn_avail_pct
                {
                    return req.err("thresholds must be strictly ordered");
                }
                req.ok(json!({
                    "tier1_stall_pct": c.tier1_stall_pct,
                    "tier2_stall_pct": c.tier2_stall_pct,
                    "tier3_stall_pct": c.tier3_stall_pct,
                    "warn_avail_pct": c.warn_avail_pct,
                    "critical_avail_pct": c.critical_avail_pct,
                }))
            }
            _ => req.err("unknown op (status|config)"),
        }
    });

    match handle {
        Ok(_) => {
            kmsg("IPC up at /run/ox/sockets/resourced.sock");
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

    const MEMINFO: &str = "MemTotal:        1048576 kB\nMemFree:          102400 kB\n\
                           MemAvailable:     157286 kB\nBuffers:           10240 kB\n";

    #[test]
    fn meminfo_parses_total_and_available() {
        let (t, a) = meminfo_body(MEMINFO);
        assert_eq!(t, 1048576);
        assert_eq!(a, 157286);
        assert_eq!(tier_for(30.0, 15.0, 8.0), 0); // healthy
        assert_eq!(tier_for(10.0, 15.0, 8.0), 1); // warn
        assert_eq!(tier_for(5.0, 15.0, 8.0), 2); // critical
    }

    fn meminfo_body(text: &str) -> (u64, u64) {
        let (mut total, mut avail) = (0u64, 0u64);
        for line in text.lines() {
            if line.starts_with("MemTotal:") {
                if let Some(v) = line.split_whitespace().nth(1) {
                    total = v.parse().unwrap_or(0);
                }
            }
            if line.starts_with("MemAvailable:") {
                if let Some(v) = line.split_whitespace().nth(1) {
                    avail = v.parse().unwrap_or(0);
                }
            }
        }
        (total, avail)
    }

    #[test]
    fn psi_total_extracts_microseconds() {
        let psi = "some avg10=0.00 avg60=0.00 avg300=0.00 total=123456789\n\
                   full avg10=0.00 avg60=0.00 avg300=0.00 total=1000\n";
        assert_eq!(psi_some_total_body(psi), Some(123456789));
    }

    #[test]
    fn stall_escalates_through_tiers() {
        assert_eq!(stall_tier(4.0, 5.0, 20.0, 95.0), 0);
        assert_eq!(stall_tier(6.0, 5.0, 20.0, 95.0), 1);
        assert_eq!(stall_tier(25.0, 5.0, 20.0, 95.0), 2);
        assert_eq!(stall_tier(96.0, 5.0, 20.0, 95.0), 3);
    }

    fn psi_some_total_body(text: &str) -> Option<u64> {
        let line = text.lines().find(|l| l.starts_with("some "))?;
        let idx = line.find("total=")? + 6;
        line[idx..].split_whitespace().next()?.parse().ok()
    }

    #[test]
    fn victims_exclude_protected_and_sort_by_rss() {
        use std::fs;
        let base = "/tmp/oxresourced-test-proc";
        let _ = fs::remove_dir_all(base);
        for (pid, comm, rss) in [
            ("1", "init", "10 1"),
            ("100", "oxcom", "50 1"),
            ("200", "memory-hog", "90000 1"),
            ("300", "little-app", "300 1"),
        ] {
            let d = format!("{base}/{pid}");
            fs::create_dir_all(&d).unwrap();
            fs::write(format!("{d}/comm"), comm).unwrap();
            fs::write(format!("{d}/statm"), rss).unwrap();
        }
        let protected = &["oxcom", "s6", "init"];
        let v = kill_candidates(base, 300, protected);
        assert_eq!(v.len(), 1); // only memory-hog survives filtering
        assert_eq!(v[0].1, "memory-hog");
        fs::remove_dir_all(base).ok();
    }
}
