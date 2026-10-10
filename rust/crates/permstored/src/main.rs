//! permstored: the permission store. Persistent per-app permission
//! grants with the three charter modes:
//!   grant — the app gets real data / real capability
//!   deny  — no access (the default; nothing is silent)
//!   fake  — fake-data provider: the app gets plausible synthetic
//!           data and its UI must mark it as fake
//! State lives in /data/ox/permstore.json and survives reboot — a
//! security model that resets every boot would be theater. Every
//! mutation is journaled to kmsg.
use ox_ipc::{serve, Envelope};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const STATE_PATH: &str = "/data/ox/permstore.json";
/// The three charter modes; anything else is refused.
const MODES: [&str; 3] = ["grant", "deny", "fake"];

fn kmsg(line: &str) {
    eprintln!("permstored: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>permstored: {}", line);
    }
}

/// Chunk 70: the store's write path (set/bind/unbind) is restricted to
/// the BUILT-IN system writers — the Settings grants panel (ox-settings)
/// where the user expresses grants, oxctl (dev + selftest seeds), and
/// ox-intentd (install-time bind / uninstall-time unbind). The identity
/// is the kernel-verified peer comm (chunk 68): a copied binary under a
/// different name is a different identity, and an app's claim is noise.
/// Refusals journal with the caller named.
fn is_system_writer(req: &Envelope, op: &str) -> bool {
    let caller = ox_ipc::peer_comm();
    let ok = matches!(caller.as_str(), "ox-settings" | "oxctl" | "ox-intentd");
    if !ok {
        kmsg(&format!(
            "OXMILESTONE name=perm-acl-refused op={op} caller={}",
            if caller.is_empty() { "unknown" } else { &caller }
        ));
    }
    let _ = req;
    ok
}

type State = HashMap<String, HashMap<String, String>>;

/// Journal a completed package-permission binding (install-time).
fn permstored_kmsg_bound(app: &str, n: usize) {
    kmsg(&format!("OXMILESTONE name=perm-bound app={app} n={n}"));
}

fn load(path: &str) -> State {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(_) => return State::new(),
    };
    let parsed: Option<HashMap<String, HashMap<String, String>>> =
        serde_json::from_str(&text).ok();
    parsed.unwrap_or_default()
}

/// Persist atomically: write the sibling temp file, fsync it, rename.
fn save(path: &str, state: &State) -> std::io::Result<()> {
    let mut tmp = PathBuf::from(path);
    tmp.set_extension("json.tmp");
    let body = serde_json::to_string_pretty(state)?;
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(body.as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn state_to_value(state: &State) -> Value {
    let mut apps = Map::new();
    for (app, perms) in state {
        apps.insert(app.clone(), serde_json::to_value(perms).unwrap());
    }
    Value::Object(apps)
}

fn main() {
    let state_path =
        std::env::var("OX_PERMSTORE_PATH").unwrap_or_else(|_| STATE_PATH.to_string());
    // The store directory must exist before anything can persist —
    // a grant that cannot be saved must not look saved.
    if let Some(parent) = PathBuf::from(&state_path).parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            kmsg(&format!("FATAL: cannot create {}: {e}", parent.display()));
            std::process::exit(1);
        }
    }
    let state = Arc::new(Mutex::new(load(&state_path)));
    {
        let st = state.lock().unwrap();
        let grants: usize = st
            .values()
            .map(|p| p.values().filter(|m| m.as_str() == "grant").count())
            .sum();
        kmsg(&format!(
            "OXMILESTONE name=permstored-loaded apps={} grants={}",
            st.len(),
            grants
        ));
    }

    let h_state = Arc::clone(&state);
    let handle = serve("/run/ox/sockets/permstored.sock", move |req: &mut Envelope| {
        let mut st = h_state.lock().unwrap();
        match req.op.as_str() {
            "get" => {
                let app = str_field(req.payload.as_ref(), "app");
                let perm = str_field(req.payload.as_ref(), "permission");
                let mode = st
                    .get(&app)
                    .and_then(|p| p.get(&perm))
                    .cloned()
                    .unwrap_or_else(|| "deny".to_string());
                req.ok(json!({ "app": app, "permission": perm, "mode": mode }))
            }
            "unbind" => {
                // Uninstall-time cleanup: the app's grants die with it.
                // Chunk 70: writes are SYSTEM-only (see the ACL note on
                // `set` below) — intentd is the sole unbind caller.
                if !is_system_writer(req, "unbind") {
                    return req.err("acl: unbind requires a system writer");
                }
                let app = str_field(req.payload.as_ref(), "app");
                if app.is_empty() {
                    return req.err("unbind: app required");
                }
                let removed = st.remove(&app);
                let n = removed.as_ref().map(|p| p.len()).unwrap_or(0);
                if let Err(e) = save(&state_path, &st) {
                    // Roll back: put the entries back on persist failure.
                    if let Some(entries) = removed {
                        st.insert(app.clone(), entries);
                    }
                    return req.err(&format!("persist failed: {e}"));
                }
                kmsg(&format!("OXMILESTONE name=perm-unbound app={app} n={n}"));
                req.ok(json!({ "app": app, "removed": n }))
            }
            "list" => {
                // Sorted for stable UI ordering (the grants panel).
                let mut apps: Vec<(&String, &HashMap<String, String>)> =
                    st.iter().collect();
                apps.sort_by(|a, b| a.0.cmp(b.0));
                let mut out = Vec::new();
                for (app, perms) in apps {
                    let mut pv: Vec<(&String, &String)> = perms.iter().collect();
                    pv.sort();
                    for (perm, mode) in pv {
                        out.push(json!({
                            "app": app, "permission": perm, "mode": mode
                        }));
                    }
                }
                req.ok(json!({ "entries": out }))
            }
            "bind" => {
                // Package-install time registration: declared manifest
                // permissions become store entries at mode deny —
                // installing an app grants nothing. Existing entries
                // are NEVER overwritten (reinstall must not clobber a
                // user grant); the store is the user's record.
                // Chunk 70: writes are SYSTEM-only — intentd binds.
                if !is_system_writer(req, "bind") {
                    return req.err("acl: bind requires a system writer");
                }
                let app = str_field(req.payload.as_ref(), "app");
                let empty = Vec::new();
                let perms = req
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("permissions"))
                    .and_then(|v| v.as_array())
                    .unwrap_or(&empty)
                    .iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>();
                if app.is_empty() || perms.is_empty() {
                    return req.err("bind: app and permissions required");
                }
                let mut added: Vec<String> = Vec::new();
                {
                    let entry = st.entry(app.clone()).or_default();
                    for perm in &perms {
                        if !entry.contains_key(perm) {
                            entry.insert(perm.clone(), "deny".to_string());
                            added.push(perm.clone());
                        }
                    }
                }
                if let Err(e) = save(&state_path, &st) {
                    // Roll back the whole bind on persist failure.
                    if let Some(entry) = st.get_mut(&app) {
                        for perm in &added {
                            entry.remove(perm);
                        }
                        if entry.is_empty() {
                            st.remove(&app);
                        }
                    }
                    return req.err(&format!("persist failed: {e}"));
                }
                permstored_kmsg_bound(&app, added.len());
                req.ok(json!({ "app": app, "bound": added.len() }))
            }
            "set" => {
                // Chunk 70: THE write path of the permission store.
                // Grants are the USER's, expressed through the Settings
                // grants panel — so `set` is restricted to the system
                // writers (ox-settings panel, oxctl dev/selftest). An
                // app that could write here would simply grant itself
                // anything, making every downstream check decorative.
                // `get`/`list` stay open (the daemon intermediaries
                // consult; read-only).
                if !is_system_writer(req, "set") {
                    return req.err("acl: set requires a system writer");
                }
                let app = str_field(req.payload.as_ref(), "app");
                let perm = str_field(req.payload.as_ref(), "permission");
                let mode = str_field(req.payload.as_ref(), "mode");
                if app.is_empty() || perm.is_empty() {
                    return req.err("app and permission must not be empty");
                }
                if !MODES.contains(&mode.as_str()) {
                    return req.err("mode must be grant|deny|fake");
                }
                let previous = st
                    .entry(app.clone())
                    .or_default()
                    .insert(perm.clone(), mode.clone());
                if let Err(e) = save(&state_path, &st) {
                    // Roll back: the store must never show a grant it
                    // failed to persist.
                    let entry = st.get_mut(&app).unwrap();
                    match previous {
                        Some(prev) => {
                            entry.insert(perm.clone(), prev);
                        }
                        None => {
                            entry.remove(&perm);
                        }
                    }
                    if entry.is_empty() {
                        st.remove(&app);
                    }
                    return req.err(&format!("persist failed: {e}"));
                }
                kmsg(&format!("perm journal {app}/{perm} -> {mode}"));
                req.ok(json!({ "app": app, "permission": perm, "mode": mode }))
            }
            "list" => {
                let app = str_field(req.payload.as_ref(), "app");
                if app.is_empty() {
                    return req.ok(json!({ "apps": state_to_value(&st) }));
                }
                let empty = HashMap::new();
                let perms = st.get(&app).unwrap_or(&empty);
                req.ok(json!({ "app": app, "permissions": perms }))
            }
            _ => req.err("unknown op (get|set|list)"),
        }
    });

    match handle {
        Ok(_) => {
            kmsg("IPC up at /run/ox/sockets/permstored.sock");
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

fn str_field(payload: Option<&Value>, key: &str) -> String {
    payload
        .and_then(|p| p.get(key))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_through_save_and_load() {
        let path = "/tmp/oxpermstore-test.json";
        let _ = std::fs::remove_file(path);
        let mut st: State = State::new();
        st.entry("test.app".to_string())
            .or_default()
            .insert("post-notification".to_string(), "grant".to_string());
        save(path, &st).unwrap();
        let loaded = load(path);
        assert_eq!(
            loaded["test.app"]["post-notification"],
            "grant".to_string()
        );
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn corrupt_state_loads_as_empty() {
        let path = "/tmp/oxpermstore-corrupt.json";
        std::fs::write(path, "not json at all {{{").unwrap();
        assert!(load(path).is_empty());
        std::fs::remove_file(path).ok();
    }
}
