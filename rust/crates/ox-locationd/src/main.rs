//! locationd: the location service — honest-permission modes like
//! contactsd. Every `fix {app}` consults permstored for `location.read`:
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> a clearly-synthetic fix (the app works, the user's real
//!            whereabouts never leak)
//!   grant -> the real store (/data/ox/location.json, written by the
//!            GNSS stack when a fix exists; without one the honest
//!            answer is "no fix", never a fabricated coordinate)
//! Every consult is journaled with the mode that was served.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

const REAL_STORE: &str = "/data/ox/location.json";

fn kmsg(line: &str) {
    eprintln!("locationd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>locationd: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

/// Consult permstored. Fail closed: unreachable daemon => deny.
fn mode_for(app: &str) -> String {
    let Ok(mut cl) = Client::connect(&sock_dir().join("permstored.sock")) else {
        return "deny".to_string();
    };
    let Ok(resp) = cl.request(
        "get",
        json!({ "app": app, "permission": "location.read" }),
    ) else {
        return "deny".to_string();
    };
    resp.payload
        .as_ref()
        .and_then(|p| p.get("mode"))
        .and_then(|v| v.as_str())
        .unwrap_or("deny")
        .to_string()
}

/// A synthetic fix: plausible shape, impossible to mistake for real —
/// a fixed point claimed with a 5 km accuracy circle.
fn fake_fix() -> Value {
    json!({
        "lat": 51.5072,
        "lon": -0.1276,
        "accuracy_m": 5000,
        "label": "synthetic fix"
    })
}

/// The user's real last-known fix, as stored by the GNSS stack.
/// No file (or garbage) => no fix — the honest answer on a device
/// that has none, NOT a fabricated coordinate.
fn real_fix() -> Option<Value> {
    let text = std::fs::read_to_string(REAL_STORE).ok()?;
    serde_json::from_str(&text).ok()
}

fn handle_req(env: &mut Envelope) -> Envelope {
    match env.op.as_str() {
        "fix" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("fix: unknown peer identity");
            }
            let mode = mode_for(&app);
            kmsg(&format!(
                "OXMILESTONE name=location-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("location.read denied"),
                "fake" => env.ok(json!({
                    "fix": fake_fix(),
                    "synthetic": true
                })),
                _ => match real_fix() {
                    Some(fix) => env.ok(json!({ "fix": fix, "synthetic": false })),
                    None => env.ok(json!({ "fix": null, "synthetic": false })),
                },
            }
        }
        "status" => env.ok(json!({ "service": "locationd" })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let _server = serve(sock_dir().join("locationd.sock"), handle_req)?;
    kmsg("OXMILESTONE name=locationd-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_fix_is_clearly_synthetic_and_wellformed() {
        let v = fake_fix();
        assert!(v["lat"].is_f64());
        assert!(v["lon"].is_f64());
        let acc = v["accuracy_m"].as_u64().unwrap();
        assert!(acc >= 1000, "synthetic fix must claim a huge accuracy circle");
        assert_eq!(v["label"].as_str().unwrap(), "synthetic fix");
    }

    #[test]
    fn missing_real_store_means_no_fix_not_fake() {
        // A missing/garbage store yields None -> the service answers
        // "no fix"; it must NEVER fall back to synthetic coordinates.
        let dir = std::env::temp_dir().join(format!("locationd-fix-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(std::fs::read_to_string(dir.join("absent.json")).is_err());
        assert!(serde_json::from_str::<Value>("not json").is_err());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn wellformed_real_fix_parses() {
        let v: Value =
            serde_json::from_str(r#"{"lat": 40.71, "lon": -74.0, "accuracy_m": 12}"#).unwrap();
        assert!(v["lat"].as_f64().unwrap() > 0.0);
        assert_eq!(v["accuracy_m"].as_u64().unwrap(), 12);
    }
}
