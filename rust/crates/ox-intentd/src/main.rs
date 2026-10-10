//! intentd: the app lifecycle + package daemon. The shell (or oxpkg)
//! sends ops over IPC; intentd owns the app set — resolved dynamically
//! from installed `.oxp` packages in /data/ox/apps (manifest.json:
//! name/bin/version), falling back to the built-in rootfs apps — and
//! spawns/tracks/reaps app processes. Install validates the manifest
//! and copies the package into the store; a broken package is refused
//! by name and journaled. Nothing about the app set is compiled in
//! beyond the built-in fallbacks.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Child;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Installed-package store: <apps_dir>/<App>.oxp/{manifest.json, bin…}
const APPS_DIR: &str = "/data/ox/apps";
/// Pinned package public key (PEM). A package manifest is only
/// trusted when its detached signature verifies against this key.
const PACKAGE_PUBKEY: &str = "/etc/ox/packages.pub.pem";

fn kmsg(line: &str) {
    eprintln!("intentd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>intentd: {}", line);
    }
}

fn sock_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("intentd.sock")
}

fn powerd_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("powerd.sock")
}

/// Built-in fallback apps (shipped in the rootfs, /usr/bin). The
/// installed-package store overrides these on name collision.
fn builtin_for(app: &str) -> Option<&'static str> {
    match app {
        "Settings" => Some("ox-settings"),
        "Files" => Some("ox-files"),
        "Terminal" => Some("ox-term"),
        _ => None,
    }
}

/// A validated package manifest.
struct Manifest {
    name: String,
    bin: String,
    /// Declared permissions — bound into permstored (mode deny) at
    /// install time; installing an app grants nothing.
    permissions: Vec<String>,
}

/// Parse + validate manifest.json: name (alnum, non-empty), bin
/// (non-empty, no path separators — it lives inside the package dir).
fn parse_manifest(p: &Path) -> Result<Manifest, String> {
    let s = std::fs::read_to_string(p).map_err(|e| format!("read manifest: {e}"))?;
    let v: Value = serde_json::from_str(&s).map_err(|e| format!("manifest json: {e}"))?;
    let name = v
        .get("name")
        .and_then(|x| x.as_str())
        .ok_or("manifest: name missing")?;
    let bin = v
        .get("bin")
        .and_then(|x| x.as_str())
        .ok_or("manifest: bin missing")?;
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err("manifest: invalid name".into());
    }
    if bin.is_empty() || bin.contains('/') || bin.contains("..") {
        return Err("manifest: invalid bin".into());
    }
    let permissions = match v.get("permissions") {
        None => Vec::new(),
        Some(x) => {
            let list = x
                .as_array()
                .ok_or("manifest: permissions must be an array")?;
            let mut out = Vec::new();
            for e in list {
                let ps = e.as_str().ok_or("manifest: permission must be a string")?;
                if ps.is_empty() {
                    return Err("manifest: empty permission".into());
                }
                out.push(ps.to_string());
            }
            out
        }
    };
    Ok(Manifest {
        name: name.to_string(),
        bin: bin.to_string(),
        permissions,
    })
}

/// Resolve app -> executable path: installed `.oxp` manifest first,
/// then the built-in set. Unresolvable apps are refused by name.
fn resolve(app: &str, apps_dir: &str) -> Result<String, String> {
    let m = parse_manifest(Path::new(&format!("{apps_dir}/{app}.oxp/manifest.json")))?;
    let bin_path = format!("{apps_dir}/{app}.oxp/{}", m.bin);
    if Path::new(&bin_path).exists() {
        return Ok(bin_path);
    }
    Err(format!("package bin missing: {bin_path}"))
}

fn resolve_with_builtin(app: &str, apps_dir: &str) -> Result<String, String> {
    if let Ok(p) = resolve(app, apps_dir) {
        return Ok(p);
    }
    match builtin_for(app) {
        Some(b) => {
            let p = format!("/usr/bin/{b}");
            if Path::new(&p).exists() {
                Ok(p)
            } else {
                Err(format!("app-not-packaged: {app}"))
            }
        }
        None => Err(format!("app-not-packaged: {app}")),
    }
}

/// Recursively copy a package directory (manifest + payload files).
fn copy_dir(src: &Path, dst: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| format!("mkdir {dst:?}: {e}"))?;
    for entry in std::fs::read_dir(src).map_err(|e| format!("read {src:?}: {e}"))? {
        let entry = entry.map_err(|e| format!("entry {src:?}: {e}"))?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if from.is_dir() {
            copy_dir(&from, &to)?;
        } else {
            std::fs::copy(&from, &to).map_err(|e| format!("copy {from:?}: {e}"))?;
            let _ = std::fs::set_permissions(&to, std::os::unix::fs::PermissionsExt::from_mode(0o755));
        }
    }
    Ok(())
}

/// Verify a manifest's detached ed25519 signature with the guest's
/// static openssl — the same primitive the host keytool signs with.
/// Every install MUST pass this; a structurally valid manifest with a
/// signature that does not match is refused exactly like a broken one.
fn verify_signature(manifest_path: &Path, sig_path: &Path) -> Result<(), String> {
    if !sig_path.exists() {
        return Err("missing-signature".into());
    }
    let (Some(m), Some(s)) = (manifest_path.to_str(), sig_path.to_str()) else {
        return Err("path encoding".into());
    };
    let out = std::process::Command::new("/usr/bin/openssl")
        .args([
            "pkeyutl",
            "-verify",
            "-rawin",
            "-pubin",
            "-inkey",
            PACKAGE_PUBKEY,
            "-sigfile",
            s,
            "-in",
            m,
        ])
        .output()
        .map_err(|e| format!("openssl exec: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        let detail = String::from_utf8_lossy(&out.stderr);
        let detail = detail.lines().last().unwrap_or("").trim().to_string();
        kmsg(&format!(
            "sig-verify-failed file={} exit={} detail={detail}",
            m,
            out.status.code().unwrap_or(-1)
        ));
        Err("bad-signature".into())
    }
}

/// Identities that hold system privileges or seeded grants: a package
/// declaring one of these as its `bin` would spawn a process whose
/// kernel comm impersonates them (chunk 68 made the comm the permission
/// identity — this closes the packaging route to that spoof). The four
/// legitimate package bins (ox-hello/ox-camera/ox-dialer/ox-sms) are
/// deliberately absent.
const RESERVED_BINS: &[&str] = &[
    "oxcom", "oxpaymentsd", "ox-status", "inputd", "powerd", "oxctl", "oxmodemd", "oxnetd",
    "oxresourced", "oxthermald", "ox-shell", "notifd", "permstored", "ox-intentd", "ox-settings",
    "ox-files", "ox-term", "oxpkg", "ox-lockd", "ox-contactsd", "ox-locationd", "ox-messagesd",
    "oxwifid", "ox-btair", "ox-gnssd", "ox-camerad", "ox-nfcd", "ox-usbd",
];

/// Install a staged package: validate its manifest, VERIFY its
/// signature, copy it into the store. Returns the installed app name.
fn install(src: &str, apps_dir: &str) -> Result<String, String> {
    let srcp = Path::new(src);
    let m = parse_manifest(&srcp.join("manifest.json"))?;
    verify_signature(&srcp.join("manifest.json"), &srcp.join("manifest.sig"))?;
    if RESERVED_BINS.contains(&m.bin.as_str()) {
        kmsg(&format!(
            "OXMILESTONE name=install-refused app={} reason=reserved-bin",
            m.name
        ));
        return Err(format!(
            "bin '{}' is a reserved system identity",
            m.bin
        ));
    }
    let dst = Path::new(apps_dir).join(format!("{}.oxp", m.name));
    copy_dir(srcp, &dst)?;
    kmsg(&format!(
        "OXMILESTONE name=intent-sig-ok app={} src={src}",
        m.name
    ));
    bind_permissions(&m, apps_dir);
    kmsg(&format!(
        "OXMILESTONE name=intent-install app={} src={src}",
        m.name
    ));
    Ok(m.name)
}

/// Register the manifest's declared permissions with permstored
/// (mode deny — installing grants nothing). Best-effort bookkeeping:
/// enforcement is fail-closed at consult time regardless.
/// Chunk 68: the permission identity is the manifest's `bin` — the
/// spawned process's kernel-visible comm — not the display `name`
/// (a consult can never be satisfied by claiming a pretty name).
fn bind_permissions(m: &Manifest, apps_dir: &str) {
    if m.permissions.is_empty() {
        return;
    }
    let _ = apps_dir;
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("permstored.sock");
    let Ok(mut cl) = ox_ipc::Client::connect(&sock) else {
        kmsg(&format!("perm-bind-failed app={}: permstored unreachable", m.bin));
        return;
    };
    match cl.request(
        "bind",
        json!({ "app": m.bin, "permissions": m.permissions }),
    ) {
        Ok(resp) if resp.error.is_none() => {
            kmsg(&format!(
                "OXMILESTONE name=perm-bound app={} identity={}",
                m.name, m.bin
            ));
        }
        Ok(resp) => kmsg(&format!(
            "perm-bind-failed app={}: {}",
            m.bin,
            resp.error.as_deref().unwrap_or("unknown")
        )),
        Err(e) => kmsg(&format!("perm-bind-failed app={}: {e}", m.bin)),
    }
}

/// Push a package-set change to the shell's event socket so the home
/// grid refreshes immediately. Best-effort: an absent or busy shell
/// just falls back to its poll; this never fails the install/remove.
fn broadcast_pkgs_changed(app: &str) {
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("shell-events.sock");
    let Ok(mut cl) = Client::connect(&sock) else {
        return;
    };
    if let Ok(resp) = cl.request("pkgs-changed", json!({ "app": app })) {
        if resp.error.is_none() {
            kmsg(&format!(
                "OXMILESTONE name=intent-pkgs-changed app={app}"
            ));
        }
    }
}

/// Running app table: app name -> child process.
type Apps = Arc<Mutex<BTreeMap<String, Child>>>;

/// Stage an installed app's binary for execution. /data is mounted
/// noexec (deliberate: data at rest never executes), so the binary
/// that actually execs is copied to a per-app scratch dir on the /run
/// tmpfs (nosuid,nodev but exec-ok). The package store stays the
/// source of truth; the scratch copy is recreated on every start.
fn stage_executable(bin_path: &str, app: &str) -> Result<String, String> {
    let dst_dir = PathBuf::from("/run/ox/appexec").join(app);
    std::fs::create_dir_all(&dst_dir).map_err(|e| format!("stage mkdir: {e}"))?;
    let name = Path::new(bin_path)
        .file_name()
        .ok_or("stage: bad bin name")?;
    let dst = dst_dir.join(name);
    std::fs::copy(bin_path, &dst).map_err(|e| format!("stage copy: {e}"))?;
    std::fs::set_permissions(&dst, std::os::unix::fs::PermissionsExt::from_mode(0o755))
        .map_err(|e| format!("stage chmod: {e}"))?;
    Ok(dst.to_string_lossy().into_owned())
}

/// Start one app instance (idempotent while it runs).
fn start_app(apps: &Apps, app: &str, apps_dir: &str) -> Result<u32, String> {
    {
        let guard = apps.lock().unwrap();
        if let Some(child) = guard.get(app) {
            return Ok(child.id());
        }
    }
    let path = resolve_with_builtin(app, apps_dir)?;
    let exec_path = if path.starts_with(apps_dir) {
        let staged = stage_executable(&path, app)?;
        kmsg(&format!(
            "OXMILESTONE name=intent-stage app={app} dst={staged}"
        ));
        staged
    } else {
        path // built-ins live on the exec-capable rootfs
    };
    let child = std::process::Command::new(&exec_path)
        .spawn()
        .map_err(|e| format!("spawn {exec_path}: {e}"))?;
    let pid = child.id();
    kmsg(&format!(
        "OXMILESTONE name=intent-start app={app} pid={pid}"
    ));
    apps.lock().unwrap().insert(app.to_string(), child);
    Ok(pid)
}

/// Reap exited apps so no zombies accumulate; every exit is journaled.
fn reap_loop(apps: Apps) {
    loop {
        std::thread::sleep(Duration::from_secs(3));
        let mut guard = apps.lock().unwrap();
        let mut done: Vec<String> = Vec::new();
        for (app, child) in guard.iter_mut() {
            match child.try_wait() {
                Ok(Some(status)) => {
                    kmsg(&format!(
                        "intent-exit app={app} code={}",
                        status.code().unwrap_or(-1)
                    ));
                    done.push(app.clone());
                }
                Ok(None) => {}
                Err(e) => {
                    kmsg(&format!("intent-wait app={app}: {e}"));
                    done.push(app.clone());
                }
            }
        }
        for app in done {
            guard.remove(&app);
        }
    }
}

fn installed(apps_dir: &str) -> Value {
    let mut names: Vec<String> = std::fs::read_dir(apps_dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| {
                    let n = e.file_name().into_string().ok()?;
                    n.strip_suffix(".oxp").map(|app| app.to_string())
                })
                .collect()
        })
        .unwrap_or_default();
    // Deterministic tile order: the shell renders this list straight
    // into the grid, so fs directory order would reshuffle tiles boot
    // to boot.
    names.sort();
    Value::Array(names.into_iter().map(Value::String).collect())
}

/// Chunk 69: the lifecycle ops mutate the app set — they are restricted
/// to the BUILT-IN system clients (the shell drives launches and the
/// switcher, ox-settings the Apps panel, oxctl/oxpkg the dev+selftest
/// surface). Installed apps have no lifecycle powers: without this, an
/// app could stop another app mid-flow or remove a package. The
/// identity is the kernel-verified peer comm (chunk 68) — a package
/// cannot spawn into a system comm (install refuses reserved bins).
/// `list` stays open: read-only.
fn is_system_caller() -> bool {
    matches!(
        ox_ipc::peer_comm().as_str(),
        "ox-shell" | "ox-settings" | "oxctl" | "oxpkg"
    )
}

fn refuse_unless_system(env: &mut Envelope, op: &str, app: &str) -> Option<Envelope> {
    if is_system_caller() {
        return None;
    }
    let caller = ox_ipc::peer_comm();
    kmsg(&format!(
        "OXMILESTONE name=intent-acl-refused op={op} caller={caller} app={app}"
    ));
    Some(env.err(&format!(
        "acl: {op} requires a system client (caller: {})",
        if caller.is_empty() { "unknown" } else { &caller }
    )))
}

fn handle_req(apps: &Apps, env: &mut Envelope) -> Envelope {
    match env.op.as_str() {
        "start" => {
            let app = env
                .payload
                .as_ref()
                .and_then(|p| p.get("app"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if app.is_empty() {
                return env.err("start: missing app");
            }
            if let Some(r) = refuse_unless_system(env, "start", &app) {
                return r;
            }
            match start_app(apps, &app, APPS_DIR) {
                Ok(pid) => env.ok(json!({ "app": app, "pid": pid })),
                Err(e) => {
                    kmsg(&format!("intent-refused app={app} reason={e}"));
                    env.err(&e)
                }
            }
        }
        "install" => {
            let src = env
                .payload
                .as_ref()
                .and_then(|p| p.get("src"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if let Some(r) = refuse_unless_system(env, "install", &src) {
                return r;
            }
            match install(&src, APPS_DIR) {
                Ok(name) => {
                    // Notify the shell off-thread: the grid refreshes on
                    // the event, and the installer gets its answer now.
                    let broadcast = name.clone();
                    std::thread::spawn(move || broadcast_pkgs_changed(&broadcast));
                    env.ok(json!({ "app": name }))
                }
                Err(e) => {
                    kmsg(&format!("intent-refused src={src} reason={e}"));
                    env.err(&e)
                }
            }
        }
        "remove" => {
            let app = env
                .payload
                .as_ref()
                .and_then(|p| p.get("app"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if let Some(r) = refuse_unless_system(env, "remove", &app) {
                return r;
            }
            if apps.lock().unwrap().contains_key(&app) {
                kmsg(&format!("intent-refused app={app} reason=app-is-running"));
                return env.err("app is running");
            }
            let dir = format!("{APPS_DIR}/{app}.oxp");
            match std::fs::remove_dir_all(&dir) {
                Ok(()) => {
                    kmsg(&format!("OXMILESTONE name=intent-remove app={app}"));
                    // Grants die with the app: drop its permission
                    // entries (best-effort; default deny covers us).
                    let sock = std::env::var_os("OX_SOCK_DIR")
                        .map(PathBuf::from)
                        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
                        .join("permstored.sock");
                    if let Ok(mut cl) = Client::connect(&sock) {
                        let _ = cl.request("unbind", json!({ "app": app }));
                    }
                    let broadcast = app.clone();
                    std::thread::spawn(move || broadcast_pkgs_changed(&broadcast));
                    env.ok(json!({ "removed": app }))
                }
                Err(e) => {
                    kmsg(&format!("intent-refused app={app} reason=remove: {e}"));
                    env.err(&format!("remove: {e}"))
                }
            }
        }
        "stop" => {
            // The switcher's Close: kill the running app. SIGKILL means
            // the app cannot release its own wake locks, so intentd
            // releases the well-known app-<name> ids on its behalf
            // (best effort — a leaked lock would pin the device awake).
            let app = env
                .payload
                .as_ref()
                .and_then(|p| p.get("app"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if app.is_empty() {
                return env.err("stop: missing app");
            }
            if let Some(r) = refuse_unless_system(env, "stop", &app) {
                return r;
            }
            let mut guard = apps.lock().unwrap();
            let Some(child) = guard.get_mut(&app) else {
                drop(guard);
                kmsg(&format!("intent-refused app={app} reason=not-running"));
                return env.err("app not running");
            };
            let pid = child.id();
            let killed = child.kill().is_ok();
            let _ = child.wait(); // reap immediately: no zombie, and a
                                  // quick re-launch sees a clean table
            guard.remove(&app);
            drop(guard);
            kmsg(&format!(
                "OXMILESTONE name=intent-stop app={app} pid={pid} ok={killed}"
            ));
            for id in [
                format!("app-{}", app.to_lowercase()),
                format!("app-{}", app),
            ] {
                if let Ok(mut pc) = Client::connect(&powerd_sock()) {
                    let _ = pc.request("wake-lock", json!({ "id": id, "release": true }));
                }
            }
            env.ok(json!({ "stopped": app, "pid": pid }))
        }
        "list" => env.ok(json!({
            "installed": installed(APPS_DIR),
            "running": apps.lock().unwrap().keys().cloned().collect::<Vec<_>>(),
        })),
        "status" => env.ok(json!({ "running": apps.lock().unwrap().len() })),
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let apps: Apps = Arc::new(Mutex::new(BTreeMap::new()));
    std::thread::spawn({
        let apps = Arc::clone(&apps);
        move || reap_loop(apps)
    });
    let handler_apps = Arc::clone(&apps);
    let _server = serve(sock_path(), move |env| handle_req(&handler_apps, env))?;
    kmsg("OXMILESTONE name=intentd-ready");
    loop {
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_validation_accepts_and_rejects() {
        let dir = std::env::temp_dir().join(format!("intentd-manifest-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let good = dir.join("manifest.json");
        std::fs::write(&good, r#"{"name":"Hello","bin":"ox-hello","version":"0.1.0"}"#).unwrap();
        let m = parse_manifest(&good).unwrap();
        assert_eq!(m.name, "Hello");
        assert_eq!(m.bin, "ox-hello");
        for bad in [
            r#"{"bin":"ox-hello"}"#,                       // name missing
            r#"{"name":"Bad/Name","bin":"b"}"#,            // name not alnum
            r#"{"name":"Ok","bin":"../escape"}"#,          // bin traversal
            r#"{"name":"Ok","bin":"a/b"}"#,                // bin path separator
            r#"not json"#,                                 // not json
        ] {
            std::fs::write(&good, bad).unwrap();
            assert!(parse_manifest(&good).is_err(), "{bad} must be refused");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn resolve_prefers_installed_over_builtin_and_refuses_unknown() {
        let dir = std::env::temp_dir().join(format!("intentd-resolve-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let appdir = dir.join("Hello.oxp");
        std::fs::create_dir_all(&appdir).unwrap();
        std::fs::write(appdir.join("manifest.json"), r#"{"name":"Hello","bin":"hello-bin"}"#).unwrap();
        std::fs::write(appdir.join("hello-bin"), "#!/bin/sh\n").unwrap();
        let p = resolve("Hello", dir.to_str().unwrap()).unwrap();
        assert!(p.ends_with("Hello.oxp/hello-bin"));
        // installed manifest missing its bin -> refused (not a silent fallback)
        std::fs::remove_file(appdir.join("hello-bin")).unwrap();
        assert!(resolve("Hello", dir.to_str().unwrap()).is_err());
        // unknown app -> refused by name
        assert_eq!(
            resolve_with_builtin("NotAnApp", dir.to_str().unwrap()),
            Err("app-not-packaged: NotAnApp".to_string())
        );
        // built-in fallback still resolves outside the guest (path check only)
        assert_eq!(builtin_for("Settings"), Some("ox-settings"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn unpackaged_apps_are_refused_by_name() {
        for app in ["Drop", "Table", ""] {
            assert_eq!(builtin_for(app), None, "{app} must not silently map");
        }
    }

    #[test]
    fn installed_list_is_sorted_and_dotp_stripped() {
        let dir = std::env::temp_dir().join(format!("intentd-installed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["Zebra.oxp", "apple.oxp", "not-a-package.txt"] {
            std::fs::create_dir_all(dir.join(&name)).unwrap();
        }
        let list = installed(dir.to_str().unwrap());
        let names: Vec<String> = list
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        assert_eq!(names, vec!["Zebra", "apple"]); // sorted, .oxp stripped, junk ignored
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn reserved_bins_cover_the_system_identities() {
        // chunk 69: every comm that holds seeded grants or system
        // privileges must be install-refused as a package bin.
        for bin in [
            "ox-shell",
            "ox-settings",
            "oxctl",
            "oxpkg",
            "ox-lockd",
            "permstored",
            "oxcom",
            "ox-gnssd",
        ] {
            assert!(RESERVED_BINS.contains(&bin), "{bin} must be reserved");
        }
        // and the four legitimate package bins must stay installable
        for bin in ["ox-hello", "ox-camera", "ox-dialer", "ox-sms"] {
            assert!(!RESERVED_BINS.contains(&bin), "{bin} must stay free");
        }
    }
}
