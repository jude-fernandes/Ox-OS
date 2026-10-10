//! ox-gnssd: the GNSS receiver daemon — owns the virtual GNSS receiver
//! on the virtio-serial port named "oxgnss.0", parses its NMEA stream,
//! and publishes the latest fix as the device's last-known location at
//! /data/ox/location.json — the real store ox-locationd serves in
//! grant mode. Policy does NOT live here: apps get a fix only through
//! locationd's permstored-gated `fix` (deny/fake/grant). gnssd is the
//! driver layer; locationd is the policy layer. On a receiver-less
//! boot the daemon stays up serving IPC and honestly reporting no fix
//! (same no-flap rule as oxmodemd).

use ox_ipc::{serve, Envelope};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const FIX_STORE: &str = "/data/ox/location.json";
const PORT_NAME: &str = "oxgnss.0";

fn kmsg(line: &str) {
    // stderr + kernel ring, same dual-channel rule as the other daemons;
    // the kernel ring also mirrors to the console so gates see milestones.
    eprintln!("ox-gnssd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-gnssd: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

/// Locate the receiver. Explicit override first, then the virtio-serial
/// port by name (devtmpfs creates /dev/vportXpY natively, so no udev
/// dependency here).
pub fn find_port() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("OX_GNSS_PORT") {
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

/// NMEA checksum: XOR of every byte between '$' and '*', compared to
/// the two hex digits after '*'. A receiver line without a valid
/// checksum is noise and must never become a fix.
pub fn nmea_checksum_ok(line: &str) -> bool {
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

/// NMEA ddmm.mmmm (lat) / dddmm.mmmm (lon) + hemisphere -> signed
/// degrees. Degrees are all digits except the last two before the dot.
pub fn dm_to_deg(s: &str, hemi: char) -> Option<f64> {
    if s.is_empty() {
        return None;
    }
    let dot = s.find('.')?;
    if dot < 3 {
        return None;
    }
    let deg: f64 = s[..dot - 2].parse().ok()?;
    let min: f64 = s[dot - 2..].parse().ok()?;
    let sign = match hemi {
        'N' | 'E' => 1.0,
        'S' | 'W' => -1.0,
        _ => return None,
    };
    Some(sign * (deg + min / 60.0))
}

/// GGA fix information: the fix-quality authority. On a no-fix frame
/// the coordinate fields are empty and quality is 0.
#[derive(Clone, Debug, PartialEq)]
pub struct Gga {
    pub utc: String,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub quality: u32,
    pub sats: Option<u32>,
    pub hdop: Option<f64>,
    pub alt_m: Option<f64>,
}

pub fn parse_gga(line: &str) -> Option<Gga> {
    let line = line.trim();
    if !line.starts_with('$') || !line[3..6].eq_ignore_ascii_case("GGA") {
        return None;
    }
    if !nmea_checksum_ok(line) {
        return None;
    }
    let body = &line[1..line.rfind('*')?];
    let f: Vec<&str> = body.split(',').collect();
    // $GxGGA,time,lat,NS,lon,EW,quality,sats,hdop,alt,M,...
    if f.len() < 10 {
        return None;
    }
    let quality = f[6].parse().unwrap_or(0);
    let (lat, lon) = if quality == 0 {
        (None, None)
    } else {
        let (Some(ns), Some(ew)) = (f[3].chars().next(), f[5].chars().next()) else {
            return None;
        };
        match (dm_to_deg(f[2], ns), dm_to_deg(f[4], ew)) {
            (Some(a), Some(b)) => (Some(a), Some(b)),
            _ => (None, None),
        }
    };
    Some(Gga {
        utc: f[1].to_string(),
        lat,
        lon,
        quality,
        sats: f[7].parse().ok(),
        hdop: f[8].parse().ok(),
        alt_m: f[9].parse().ok(),
    })
}

/// RMC recommended-minimum sentence: secondary fix source (status A =
/// valid). Parsed for tests and future speed/course use.
#[derive(Clone, Debug, PartialEq)]
pub struct Rmc {
    pub utc: String,
    pub valid: bool,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub speed_knots: Option<f64>,
    pub date: String,
}

pub fn parse_rmc(line: &str) -> Option<Rmc> {
    let line = line.trim();
    if !line.starts_with('$') || !line[3..6].eq_ignore_ascii_case("RMC") {
        return None;
    }
    if !nmea_checksum_ok(line) {
        return None;
    }
    let body = &line[1..line.rfind('*')?];
    let f: Vec<&str> = body.split(',').collect();
    // $GxRMC,time,status,lat,NS,lon,EW,speed,course,date,...
    if f.len() < 10 {
        return None;
    }
    let valid = f[2] == "A";
    let (lat, lon) = if valid {
        let (Some(ns), Some(ew)) = (f[4].chars().next(), f[6].chars().next()) else {
            return None;
        };
        match (dm_to_deg(f[3], ns), dm_to_deg(f[5], ew)) {
            (Some(a), Some(b)) => (Some(a), Some(b)),
            _ => (None, None),
        }
    } else {
        (None, None)
    };
    Some(Rmc {
        utc: f[1].to_string(),
        valid,
        lat,
        lon,
        speed_knots: f[7].parse().ok(),
        date: f[9].to_string(),
    })
}

/// The device's last-known fix.
#[derive(Clone, Debug, PartialEq)]
pub struct Fix {
    pub lat: f64,
    pub lon: f64,
    pub alt_m: f64,
    pub quality: u32,
    pub sats: u32,
    pub hdop: f64,
    pub utc: String,
}

impl Fix {
    pub fn to_json(&self) -> Value {
        json!({
            "lat": self.lat,
            "lon": self.lon,
            "alt_m": self.alt_m,
            // rough horizontal accuracy from HDOP (GNSS rule of thumb:
            // 1 HDOP point ≈ 5 m of error)
            "accuracy_m": (self.hdop * 5.0).round() as i64,
            "sats": self.sats,
            "hdop": self.hdop,
            "utc": self.utc,
            "source": "gnss",
        })
    }
}

fn persist_fix(fix: &Fix) {
    let dir = PathBuf::from("/data/ox");
    if std::fs::create_dir_all(&dir).is_err() {
        kmsg("persist: cannot create /data/ox");
        return;
    }
    let tmp = dir.join(".location.json.tmp");
    let text = fix.to_json().to_string();
    match std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, FIX_STORE)) {
        Ok(()) => kmsg("gnss-fix-persisted"),
        Err(e) => kmsg(&format!("persist failed: {e}")),
    }
}

struct Shared {
    last: Mutex<Option<Fix>>,
    ok: AtomicU64,
    bad: AtomicU64,
    fixes: AtomicU64,
    nofix_journaled: AtomicBool,
}

impl Shared {
    fn new() -> Self {
        Self {
            last: Mutex::new(None),
            ok: AtomicU64::new(0),
            bad: AtomicU64::new(0),
            fixes: AtomicU64::new(0),
            nofix_journaled: AtomicBool::new(false),
        }
    }
}

/// Reader loop: blocks on the receiver port, feeds every line through
/// checksum + parse, journals the honest no-fix leg, and on the first
/// fix journals + persists it (re-persist only when the fix moved).
/// The port never becoming a fix is fine — the daemon stays up.
fn read_loop(port: PathBuf, sh: Arc<Shared>) {
    let mut last_persisted: Option<(f64, f64)> = None;
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
                Ok(0) => break, // receiver closed the stream
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
            if !nmea_checksum_ok(line) {
                sh.bad.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            sh.ok.fetch_add(1, Ordering::Relaxed);
            let Some(g) = parse_gga(line) else { continue };
            if g.quality == 0 {
                // journal once: the receiver is up and honestly says
                // there is no fix yet — the state the store must reflect
                if !sh.nofix_journaled.swap(true, Ordering::Relaxed) {
                    kmsg("OXMILESTONE name=gnss-no-fix");
                }
                continue;
            }
            let (Some(lat), Some(lon)) = (g.lat, g.lon) else {
                continue;
            };
            let fix = Fix {
                lat,
                lon,
                alt_m: g.alt_m.unwrap_or(0.0),
                quality: g.quality,
                sats: g.sats.unwrap_or(0),
                hdop: g.hdop.unwrap_or(99.9),
                utc: g.utc.clone(),
            };
            sh.fixes.fetch_add(1, Ordering::Relaxed);
            let first = {
                let mut last = sh.last.lock().unwrap();
                let first = last.is_none();
                *last = Some(fix.clone());
                first
            };
            if first {
                kmsg(&format!(
                    "OXMILESTONE name=gnss-fix lat={:.5} lon={:.5} sats={} alt={:.1} quality={}",
                    fix.lat, fix.lon, fix.sats, fix.alt_m, fix.quality
                ));
            }
            let moved = match last_persisted {
                Some((pla, plo)) => (pla - lat).abs() > 1e-5 || (plo - lon).abs() > 1e-5,
                None => true,
            };
            if moved {
                persist_fix(&fix);
                last_persisted = Some((lat, lon));
            }
        }
        kmsg("receiver stream closed; reopening in 2s");
        thread::sleep(Duration::from_secs(2));
    }
}

fn handle_req(env: &mut Envelope, sh: &Shared) -> Envelope {
    match env.op.as_str() {
        // driver-level read: no permission check here ON PURPOSE —
        // policy is locationd's job (permstored deny/fake/grant). This
        // op exists for gates and diagnostics.
        "fix" => {
            let last = sh.last.lock().unwrap();
            match &*last {
                Some(f) => env.ok(json!({ "fix": f.to_json(), "synthetic": false })),
                None => env.ok(json!({ "fix": null, "synthetic": false })),
            }
        }
        "status" => env.ok(json!({
            "service": "gnssd",
            "sentences_ok": sh.ok.load(Ordering::Relaxed),
            "sentences_bad": sh.bad.load(Ordering::Relaxed),
            "fixes_seen": sh.fixes.load(Ordering::Relaxed),
            "last_fix": sh.last.lock().unwrap().as_ref().map(|f| f.to_json()),
        })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let sh = Arc::new(Shared::new());
    match find_port() {
        Some(p) => {
            kmsg(&format!(
                "OXMILESTONE name=gnssd-ready transport={}",
                p.display()
            ));
            let sh2 = sh.clone();
            thread::spawn(move || read_loop(p, sh2));
        }
        None => {
            // no receiver on this boot: stay up, serve "no fix"
            kmsg("OXMILESTONE name=gnssd-ready-noport");
        }
    }
    let sh3 = sh.clone();
    let _server = serve(sock_dir().join("gnssd.sock"), move |env: &mut Envelope| {
        handle_req(env, &sh3)
    })?;
    loop {
        thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Independent checksum builder for tests (same XOR rule).
    fn cs(body: &str) -> String {
        format!("{:02X}", body.bytes().fold(0u8, |a, b| a ^ b))
    }

    fn wrap(body: &str) -> String {
        format!("${body}*{}", cs(body).to_uppercase())
    }

    const NOFIX_BODY: &str = "GPGGA,120000.00,,,,,0,00,99.99,,,,,";
    const FIX_BODY: &str =
        "GPGGA,120001.00,3746.4960,N,12225.1650,W,1,09,0.9,16.1,M,-25.4,M,,";
    const RMC_BODY: &str =
        "GPRMC,120001.00,A,3746.4960,N,12225.1650,W,0.05,122.4,090926,,,A";

    #[test]
    fn checksum_accepts_valid_and_rejects_tamper() {
        let good = wrap(NOFIX_BODY);
        assert!(nmea_checksum_ok(&good));
        assert!(parse_gga(&good).is_some());
        // flip a payload char: checksum must fail and parse must refuse
        let bad = format!("{}4{}", &good[..14], &good[15..]);
        assert_ne!(bad, good);
        assert!(!nmea_checksum_ok(&bad));
        assert!(parse_gga(&bad).is_none());
        // corrupted checksum digits
        let mut worse = wrap(FIX_BODY);
        worse.replace_range(worse.len() - 1.., if worse.ends_with('F') { "0" } else { "F" });
        assert!(!nmea_checksum_ok(&worse));
        // no star at all
        assert!(!nmea_checksum_ok("$GPGGA,120000.00,0"));
        // not a $ sentence
        assert!(!nmea_checksum_ok("GPGGA,120000.00"));
    }

    #[test]
    fn dm_to_deg_converts_signed_coordinates() {
        let lat = dm_to_deg("3746.4960", 'N').unwrap();
        let lon = dm_to_deg("12225.1650", 'W').unwrap();
        assert!((lat - 37.774933).abs() < 1e-5, "lat {lat}");
        assert!((lon + 122.419417).abs() < 1e-5, "lon {lon}");
        assert!((dm_to_deg("5123.4500", 'S').unwrap() + 51.390833).abs() < 1e-5);
        assert_eq!(dm_to_deg("", 'N'), None);
        assert_eq!(dm_to_deg("3746.4960", 'X'), None);
    }

    #[test]
    fn gga_nofix_has_quality_zero_and_no_coordinates() {
        let g = parse_gga(&wrap(NOFIX_BODY)).unwrap();
        assert_eq!(g.quality, 0);
        assert_eq!(g.lat, None);
        assert_eq!(g.lon, None);
    }

    #[test]
    fn gga_fix_parses_signed_coordinates_and_stats() {
        let g = parse_gga(&wrap(FIX_BODY)).unwrap();
        assert_eq!(g.quality, 1);
        let lat = g.lat.unwrap();
        let lon = g.lon.unwrap();
        assert!((lat - 37.774933).abs() < 1e-5);
        assert!((lon + 122.419417).abs() < 1e-5);
        assert_eq!(g.sats, Some(9));
        assert_eq!(g.alt_m, Some(16.1));
        assert_eq!(g.hdop, Some(0.9));
    }

    #[test]
    fn rmc_valid_frame_parses() {
        let r = parse_rmc(&wrap(RMC_BODY)).unwrap();
        assert!(r.valid);
        let lat = r.lat.unwrap();
        let lon = r.lon.unwrap();
        assert!((lat - 37.774933).abs() < 1e-5);
        assert!((lon + 122.419417).abs() < 1e-5);
        assert_eq!(r.speed_knots, Some(0.05));
        assert_eq!(r.date, "090926");
        // void frame: no coordinates
        let void_body = "GPRMC,120002.00,V,,,,,,,090926,,,N";
        let r = parse_rmc(&wrap(void_body)).unwrap();
        assert!(!r.valid);
        assert_eq!(r.lat, None);
    }

    #[test]
    fn fix_json_is_the_real_store_shape() {
        let f = Fix {
            lat: 37.774933,
            lon: -122.419417,
            alt_m: 16.1,
            quality: 1,
            sats: 9,
            hdop: 0.9,
            utc: "120001.00".into(),
        };
        let v = f.to_json();
        assert!((v["lat"].as_f64().unwrap() - 37.774933).abs() < 1e-9);
        assert_eq!(v["source"], "gnss");
        assert_eq!(v["accuracy_m"], 5); // hdop 0.9 * 5 -> 5
        assert!(v["sats"].as_u64().unwrap() >= 4, "a fix needs >=4 sats");
    }

    #[test]
    fn non_gga_sentences_are_not_fixes() {
        assert!(parse_gga(&wrap(RMC_BODY)).is_none());
        assert!(parse_rmc(&wrap(FIX_BODY)).is_none());
        // garbage that claims to be GGA but has no checksum
        assert!(parse_gga("$GPGGA,120001.00,3746.4960,N").is_none());
    }
}
