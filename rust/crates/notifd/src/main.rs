//! notifd: the notification daemon. Apps post notifications over IPC;
//! every post is checked against the permission store (permstored) —
//! no grant means the post is refused and journaled. Accepted posts
//! raise a banner window on the compositor (drawn via ox-ui) and are
//! listable/dismissible over IPC. Notifications are ephemeral by
//! design: they live in RAM and die with the boot.
use ox_ipc::{Client, serve, Envelope};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn kmsg(line: &str) {
    eprintln!("notifd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>notifd: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

/// Ask permstored for the app's permission mode. Fail closed: if the
/// permission store cannot be reached, the answer is deny.
fn permission_mode(app: &str, permission: &str) -> String {
    let path = sock_dir().join("permstored.sock");
    let Ok(mut cl) = Client::connect(&path) else {
        return "deny".to_string();
    };
    match cl.request(
        "get",
        json!({ "app": app, "permission": permission }),
    ) {
        Ok(resp) => resp
            .payload
            .as_ref()
            .and_then(|p| p.get("mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("deny")
            .to_string(),
        Err(_) => "deny".to_string(),
    }
}

#[derive(Clone)]
struct Notif {
    id: u64,
    app: String,
    title: String,
    body: String,
}

fn notifs_value(list: &[Notif]) -> Value {
    Value::Array(
        list.iter()
            .map(|n| {
                json!({ "id": n.id, "app": n.app, "title": n.title, "body": n.body })
            })
            .collect(),
    )
}

fn main() {
    let list: Arc<Mutex<Vec<Notif>>> = Arc::new(Mutex::new(Vec::new()));
    let next_id = Arc::new(Mutex::new(1u64));
    let banner_win: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));

    kmsg("OXMILESTONE name=notifd-ready");

    let h_list = Arc::clone(&list);
    let h_id = Arc::clone(&next_id);
    let h_banner = Arc::clone(&banner_win);
    let handle = serve("/run/ox/sockets/notifd.sock", move |req: &mut Envelope| {
        match req.op.as_str() {
            "post" => {
                let app = str_field(req.payload.as_ref(), "app");
                let title = str_field(req.payload.as_ref(), "title");
                let body = str_field(req.payload.as_ref(), "body");
                if app.is_empty() || title.is_empty() {
                    return req.err("app and title must not be empty");
                }
                // Chunk 68: the post permission consult uses the
                // KERNEL-verified peer comm, never the payload claim —
                // the payload `app` stays display-only metadata.
                let poster = ox_ipc::peer_comm();
                if poster.is_empty() {
                    return req.err("post: unknown peer identity");
                }
                let mode = permission_mode(&poster, "post-notification");
                if mode != "grant" {
                    kmsg(&format!(
                        "notif journal {poster} -> post DENIED (mode={mode})"
                    ));
                    return req.err(&format!(
                        "post-notification denied for {poster} (mode={mode})"
                    ));
                }
                let id = {
                    let mut n = h_id.lock().unwrap();
                    let id = *n;
                    *n += 1;
                    id
                };
                {
                    let mut l = h_list.lock().unwrap();
                    if l.len() >= 32 {
                        l.remove(0);
                    }
                    l.push(Notif {
                        id,
                        app: app.clone(),
                        title: title.clone(),
                        body: body.clone(),
                    });
                }
                kmsg(&format!("notif journal {app} -> post #{id} accepted"));
                raise_banner(&mut h_banner.lock().unwrap(), cl_for_banner(), &title, &body);
                req.ok(json!({ "id": id, "app": app, "title": title }))
            }
            "list" => {
                let l = h_list.lock().unwrap();
                req.ok(json!({ "notifications": notifs_value(&l) }))
            }
            "dismiss" => {
                let id = req
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("id"))
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0);
                let mut l = h_list.lock().unwrap();
                let before = l.len();
                l.retain(|n| n.id != id);
                if l.len() == before {
                    return req.err("no such notification");
                }
                req.ok(json!({ "dismissed": id }))
            }
            "clear" => {
                h_list.lock().unwrap().clear();
                req.ok(json!({ "cleared": true }))
            }
            _ => req.err("unknown op (post|list|dismiss|clear)"),
        }
    });

    match handle {
        Ok(_) => {
            kmsg("IPC up at /run/ox/sockets/notifd.sock");
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

fn cl_for_banner() -> Option<Client> {
    let path = sock_dir().join("oxcom.sock");
    Client::connect(&path).ok()
}

/// Raise/refresh the notification banner window (top-right, drawn via
/// ox-ui showing the latest notification). Best-effort: no compositor
/// means no banner, notifications still work over IPC.
fn raise_banner(
    banner_win: &mut Option<u64>,
    cl: Option<Client>,
    title: &str,
    body: &str,
) {
    let Some(mut cl) = cl else { return };
    let win_w = 320u64;
    let win_h = 88u64;
    let win_id = match *banner_win {
        Some(id) => id,
        None => {
            // compositor reported 1280x800 in every gate; place top-right
            let resp = cl.request(
                "window-new",
                json!({ "x": 1280 - win_w - 12, "y": 12, "w": win_w, "h": win_h }),
            );
            let id = resp
                .ok()
                .and_then(|r| r.payload)
                .and_then(|p| p.get("id").and_then(|v| v.as_u64()));
            match id {
                Some(id) => {
                    *banner_win = Some(id);
                    id
                }
                None => return,
            }
        }
    };
    let mut s = ox_ui::Screen::new(win_w, win_h);
    s.card(0, 0, win_w, win_h, title, body);
    let payload = s.ops_payload();
    let _ = cl.request("window-commit", json!({ "id": win_id, "ops": payload["ops"] }));
    kmsg(&format!("notif banner raised: {title}"));
}
