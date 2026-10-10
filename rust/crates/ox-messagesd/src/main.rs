//! messagesd: the messages service — honest-permission modes like
//! contactsd. Every `list {app}` consults permstored for `messages.read`:
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> plausible SYNTHETIC messages (the app works, the user's
//!            real conversations never leave the store)
//!   grant -> the real store (/data/ox/messages.json), which the
//!            telephony stack WRITES: an ingest thread polls
//!            oxmodemd's snapshot as an un-attributed system caller
//!            and appends every real SMS (sent non-synthetic +
//!            received), deduped, journaled. The Phase-3 contract
//!            ("the real store, populated by the telephony stack")
//!            got its writer with ZERO permission-layer changes.
//! Every consult is journaled with the mode that was served.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

const REAL_STORE: &str = "/data/ox/messages.json";

fn kmsg(line: &str) {
    eprintln!("messagesd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>messagesd: {}", line);
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
        json!({ "app": app, "permission": "messages.read" }),
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

/// Synthetic messages: plausible shape, obviously not real people.
fn fake_messages() -> Value {
    json!([
        {"from": "Fake Alice", "number": "+1-555-0100", "text": "synthetic message one"},
        {"from": "Fake Bob", "number": "+1-555-0101", "text": "synthetic message two"},
        {"from": "Fake Carol", "number": "+1-555-0102", "text": "synthetic message three"}
    ])
}

/// The user's real messages (populated by the telephony ingest).
fn real_messages() -> Value {
    real_messages_at(REAL_STORE)
}

fn real_messages_at(path: &str) -> Value {
    let text = std::fs::read_to_string(path).unwrap_or_else(|_| "[]".into());
    serde_json::from_str(&text).unwrap_or(json!([]))
}

/// One real telephony record for the store.
pub fn entry(dir: &str, id: u64, number: &str, text: &str) -> Value {
    json!({ "dir": dir, "id": id, "number": number, "text": text })
}

/// Dedupe key: (dir, id, number, text). Radio ids reset per boot, so
/// the tuple — not the id alone — decides "already stored".
pub fn entry_key(dir: &str, id: u64, number: &str, text: &str) -> String {
    format!("{dir}:{id}:{number}:{text}")
}

fn entry_key_v(e: &Value) -> Option<String> {
    Some(entry_key(
        e["dir"].as_str()?,
        e["id"].as_u64()?,
        e["number"].as_str()?,
        e["text"].as_str()?,
    ))
}

/// Merge new real records into the store file (atomic tmp+rename).
/// The existing file seeds the seen-set, so a reboot with reset radio
/// ids cannot duplicate rows. Returns the entries ACTUALLY added.
pub fn merge_into_store(path: &str, incoming: &[Value]) -> Vec<Value> {
    let text = std::fs::read_to_string(path).unwrap_or_else(|_| "[]".into());
    let mut arr: Vec<Value> =
        serde_json::from_str(&text).unwrap_or_default();
    let mut seen: HashSet<String> =
        arr.iter().filter_map(entry_key_v).collect();
    let mut added = Vec::new();
    for e in incoming {
        if let Some(k) = entry_key_v(e) {
            if seen.insert(k) {
                added.push(e.clone());
            }
        }
    }
    if !added.is_empty() {
        arr.extend(added.iter().cloned());
        let tmp = format!("{path}.tmp");
        if std::fs::write(&tmp, serde_json::to_string(&arr).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
    added
}

/// Map an oxmodemd snapshot into candidate store records: everything
/// received, plus every NON-synthetic send (fake-mode sends never
/// touched the radio and stay out of the real store).
pub fn candidates_from_snapshot(snap: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for r in snap["sms_received"].as_array().unwrap_or(&Vec::new()) {
        out.push(entry(
            "in",
            r["id"].as_u64().unwrap_or(0),
            r["from"].as_str().unwrap_or(""),
            r["text"].as_str().unwrap_or(""),
        ));
    }
    for r in snap["sms_sent"].as_array().unwrap_or(&Vec::new()) {
        if r["synthetic"].as_bool().unwrap_or(true) {
            continue;
        }
        out.push(entry(
            "out",
            r["id"].as_u64().unwrap_or(0),
            r["to"].as_str().unwrap_or(""),
            r["text"].as_str().unwrap_or(""),
        ));
    }
    out
}

fn handle_req(env: &mut Envelope) -> Envelope {
    match env.op.as_str() {
        "list" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("list: unknown peer identity");
            }
            let mode = mode_for(&app);
            kmsg(&format!(
                "OXMILESTONE name=messages-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("messages.read denied"),
                "fake" => env.ok(json!({
                    "messages": fake_messages(),
                    "synthetic": true,
                    "count": 3
                })),
                _ => {
                    let messages = real_messages();
                    let n = messages.as_array().map(|a| a.len()).unwrap_or(0);
                    env.ok(json!({ "messages": messages, "synthetic": false, "count": n }))
                }
            }
        }
        "status" => env.ok(json!({ "service": "messagesd" })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    // The telephony writer: poll oxmodemd's full snapshot as an
    // un-attributed SYSTEM caller (the daemon is the OS, not an app —
    // no permstored consult on this path), append new real records to
    // the store, journal each one.
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(2));
        let Ok(mut cl) = Client::connect(&sock_dir().join("oxmodemd.sock")) else {
            continue;
        };
        let Ok(resp) = cl.request("sms-list", json!({})) else {
            continue;
        };
        let Some(p) = resp.payload else {
            continue;
        };
        let candidates = candidates_from_snapshot(&p);
        if candidates.is_empty() {
            continue;
        }
        let added = merge_into_store(REAL_STORE, &candidates);
        for e in &added {
            kmsg(&format!(
                "OXMILESTONE name=messages-ingested dir={} number={} text={}",
                e["dir"].as_str().unwrap_or("?"),
                e["number"].as_str().unwrap_or("?"),
                e["text"].as_str().unwrap_or("?"),
            ));
        }
    });

    let _server = serve(sock_dir().join("messagesd.sock"), handle_req)?;
    kmsg("OXMILESTONE name=messagesd-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fake_messages_are_clearly_synthetic_and_wellformed() {
        let v = fake_messages();
        let arr = v.as_array().unwrap();
        assert!(!arr.is_empty());
        for m in arr {
            assert!(m["from"].as_str().unwrap().starts_with("Fake "));
            assert!(m["number"].as_str().unwrap().starts_with("+1-555-"));
            assert!(m["text"].as_str().unwrap().contains("synthetic"));
        }
    }

    #[test]
    fn real_store_defaults_to_empty_array() {
        assert_eq!(real_messages_at("/nonexistent/messages.json").as_array().unwrap().len(), 0);
        // garbage never crashes the service: it degrades to empty
        assert_eq!(real_messages_at("/dev/null").as_array().unwrap().len(), 0);
    }

    #[test]
    fn snapshot_maps_both_directions_but_not_synthetics() {
        let snap = json!({
            "sms_received": [
                {"id": 1, "from": "+15550042", "text": "hi"},
                {"id": 2, "from": "+15550002", "text": "yo"}
            ],
            "sms_sent": [
                {"id": 1, "to": "+15550001", "text": "real send", "synthetic": false},
                {"id": 2, "to": "+15550009", "text": "ghost send", "synthetic": true}
            ]
        });
        let c = candidates_from_snapshot(&snap);
        assert_eq!(c.len(), 3, "synthetic send must be excluded");
        assert_eq!(c[0]["dir"], "in");
        assert_eq!(c[0]["number"], "+15550042");
        assert_eq!(c[2]["dir"], "out");
        assert_eq!(c[2]["text"], "real send");
    }

    #[test]
    fn merge_dedupes_within_and_across_calls() {
        let path = std::env::temp_dir().join("messagesd-merge-test.json");
        let _ = std::fs::remove_file(&path);
        let p = path.to_str().unwrap();
        let batch = vec![
            entry("in", 1, "+15550042", "the eagle lands at dawn"),
            entry("in", 2, "+15550002", "second"),
        ];
        let added = merge_into_store(p, &batch);
        assert_eq!(added.len(), 2);
        // identical re-poll: nothing new
        assert_eq!(merge_into_store(p, &batch).len(), 0);
        // one new record lands, old ones kept
        let added = merge_into_store(p, &[entry("out", 1, "+15550001", "reply")]);
        assert_eq!(added.len(), 1);
        let store = real_messages_at(p);
        assert_eq!(store.as_array().unwrap().len(), 3);
        // a reboot resets radio ids, but the seeded seen-set (same
        // tuple) still refuses the duplicate
        assert_eq!(merge_into_store(p, &batch).len(), 0);
        let _ = std::fs::remove_file(&path);
    }
}
