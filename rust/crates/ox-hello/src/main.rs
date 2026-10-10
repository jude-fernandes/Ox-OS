//! ox-hello: the demo app shipped as the first `.oxp` package. Proves
//! the packaging path end to end: oxpkg installs the package, intentd
//! resolves the installed manifest (not a built-in), spawns this
//! binary from /data/ox/apps, and reaps the exit. Draws one window via
//! ox-ui, holds the foreground wake-lock contract, and auto-exits
//! after a short demo window (the packaging gate screendumps it).
use ox_ipc::Client;
use ox_ui::{palette, type_scale, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

const WIN_X: u64 = 190;
const WIN_Y: u64 = 80;
const WIN_W: u64 = 900;
const WIN_H: u64 = 680;

fn kmsg(line: &str) {
    eprintln!("ox-hello: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-hello: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn main() -> std::io::Result<()> {
    let sock = socket_path();
    let mut cl = None;
    for _ in 0..50 {
        match Client::connect(&sock) {
            Ok(c) => {
                cl = Some(c);
                break;
            }
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
    let Some(mut cl) = cl else {
        eprintln!("ox-hello: no compositor — exiting");
        return Ok(());
    };
    let resp =
        cl.request("window-new", json!({ "x": WIN_X, "y": WIN_Y, "w": WIN_W, "h": WIN_H }))?;
    let id = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_u64())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no window id"))?;
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Hello");
    s.card(
        48,
        160,
        WIN_W - 96,
        120,
        "Hello from an .oxp package",
        "installed by oxpkg, launched by intentd",
    );
    s.label(
        48,
        320,
        palette::ON_SURFACE_MUTED,
        "dynamic app set: manifest-driven, not compiled in",
        type_scale::BODY,
    );
    s.label(48, WIN_H - 40, palette::PRIMARY, "ox-hello 0.1", type_scale::LABEL);
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    kmsg("OXMILESTONE name=hello-ready");
    // App-visible permission proof: post a notification as this app.
    // Freshly installed -> bound deny -> refused; after the user grants
    // post-notification in Settings, relaunches get hello-notify-ok.
    {
        let nsock = std::env::var_os("OX_SOCK_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
            .join("notifd.sock");
        match Client::connect(&nsock) {
            Ok(mut nc) => match nc.request(
                "post",
                json!({ "app": "Hello", "title": "Hello", "body": "package app check-in" }),
            ) {
                Ok(r) if r.error.is_none() => kmsg("OXMILESTONE name=hello-notify-ok"),
                Ok(r) => kmsg(&format!(
                    "OXMILESTONE name=hello-notify-denied reason={}",
                    r.error.as_deref().unwrap_or("unknown")
                )),
                Err(e) => kmsg(&format!("hello-notify-denied reason={e}")),
            },
            Err(_) => kmsg("hello-notify-denied reason=notifd unreachable"),
        }
    }
    // Foreground app contract: hold the screen on for the demo window.
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-hello\"}"])
        .status();
    std::thread::sleep(Duration::from_secs(20));
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-hello\",\"release\":true}"])
        .status();
    kmsg("OXMILESTONE name=hello-exit");
    Ok(())
}
