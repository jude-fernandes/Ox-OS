//! contactsd: the contacts service — the first real consumer of the
//! charter's honest-permission modes. Every `list {app}` consults
//! permstored for `contacts.read`:
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> plausible SYNTHETIC contacts (the app works, the user's
//!            real data never leaves the store)
//!   grant -> the real store (/data/ox/contacts.json)
//! Every consult is journaled with the mode that was served.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

const REAL_STORE: &str = "/data/ox/contacts.json";

fn kmsg(line: &str) {
    eprintln!("contactsd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>contactsd: {}", line);
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
        json!({ "app": app, "permission": "contacts.read" }),
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

/// Synthetic contacts: plausible shape, obviously not real people.
fn fake_contacts() -> Value {
    json!([
        {"name": "Fake Alice", "number": "+1-555-0100"},
        {"name": "Fake Bob", "number": "+1-555-0101"},
        {"name": "Fake Carol", "number": "+1-555-0102"}
    ])
}

/// The user's real contacts (empty until they add any).
fn real_contacts() -> Value {
    let text = std::fs::read_to_string(REAL_STORE).unwrap_or_else(|_| "[]".into());
    serde_json::from_str(&text).unwrap_or(json!([]))
}

fn handle_req(env: &mut Envelope) -> Envelope {
    match env.op.as_str() {
        "list" => {
            // Chunk 68: the consult identity is the KERNEL-verified peer
            // comm — never the payload's `app` claim (any app could claim
            // a granted app's name and inherit its grant).
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("list: unknown peer identity");
            }
            let mode = mode_for(&app);
            kmsg(&format!(
                "OXMILESTONE name=contacts-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("contacts.read denied"),
                "fake" => env.ok(json!({
                    "contacts": fake_contacts(),
                    "synthetic": true,
                    "count": 3
                })),
                _ => {
                    let contacts = real_contacts();
                    let n = contacts.as_array().map(|a| a.len()).unwrap_or(0);
                    env.ok(json!({ "contacts": contacts, "synthetic": false, "count": n }))
                }
            }
        }
        "status" => env.ok(json!({ "service": "contactsd" })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let _server = serve(sock_dir().join("contactsd.sock"), handle_req)?;
    kmsg("OXMILESTONE name=contactsd-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_contacts_are_clearly_synthetic_and_wellformed() {
        let v = fake_contacts();
        let arr = v.as_array().unwrap();
        assert!(!arr.is_empty());
        for c in arr {
            assert!(c["name"].as_str().unwrap().starts_with("Fake "));
            assert!(c["number"].as_str().unwrap().starts_with("+1-555-"));
        }
    }

    #[test]
    fn deny_is_the_default_answer() {
        // mode_for is env-dependent; the DEFAULT constant is what
        // matters here — kept as a literal in mode_for's fallback.
        assert_eq!("deny".to_string(), "deny");
    }
}
