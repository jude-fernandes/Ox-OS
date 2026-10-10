//! ox-camera: the Camera app v1 — a live viewfinder and shutter over
//! ox-camerad. Permission enforcement lives in the daemon (permstored
//! `camera.read` per frame/capture); this app only renders the honest
//! outcome of each request: refused frames draw the "denied — grant in
//! Settings" state, granted frames draw the viewfinder with the red
//! CAM LIVE badge (the in-use indicator travels with the preview, and
//! ox-status's card mirrors it device-wide).
use ox_ipc::Client;
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const WIN_X: u64 = 60;
const WIN_Y: u64 = 90;
const WIN_W: u64 = 940;
const WIN_H: u64 = 620;
const VF_X: u64 = 24;
const VF_Y: u64 = 130;
const VF_W: u64 = 160;
const VF_H: u64 = 120;
const VF_SCALE: u64 = 3;
const BTN_W: u64 = 180;
const BTN_H: u64 = 48;
const APP: &str = "Camera";

fn kmsg(line: &str) {
    eprintln!("ox-camera: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-camera: {}", line);
    }
}

fn sock(name: &str) -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join(name)
}

fn shutter_rect() -> (u64, u64, u64, u64) {
    (VF_X, VF_Y + VF_H * VF_SCALE + 40, BTN_W, BTN_H)
}

fn close_rect() -> (u64, u64, u64, u64) {
    (WIN_W - 48 - 150, WIN_H - 24 - BTN_H, 150, BTN_H)
}

fn hit(x: u64, y: u64, r: (u64, u64, u64, u64)) -> bool {
    x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3
}

/// One committed frame of app state.
struct State {
    denied: bool,
    frame: Option<(u64, u64, String, u64, bool)>, // w,h,rgb24(b64),seq,synthetic
    status: String,
}

fn draw(cl: &mut Client, id: u64, st: &State) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Camera");
    if st.denied {
        s.rect(VF_X, VF_Y, VF_W * VF_SCALE, VF_H * VF_SCALE, 0x202020);
        s.label(
            VF_X + 16,
            VF_Y + VF_H * VF_SCALE / 2 - 8,
            palette::ON_SURFACE_MUTED,
            "camera denied \u{2014} grant Camera in Settings \u{2192} Permissions",
            1,
        );
        s.label(
            VF_X,
            VF_Y + VF_H * VF_SCALE + 16,
            palette::ON_SURFACE_MUTED,
            &st.status,
            type_scale::BODY,
        );
    } else if let Some((w, h, data, _seq, _syn)) = &st.frame {
        s.pixels_b64(VF_X, VF_Y, *w, *h, VF_SCALE, data);
        // in-use badge: travels with the preview, painter order on top
        s.rect(VF_X, VF_Y, 190, 30, 0xB3261E);
        s.label(VF_X + 10, VF_Y + 8, 0xFFFFFF, "\u{25cf} CAM LIVE", 1);
        s.label(
            VF_X,
            VF_Y + VF_H * VF_SCALE + 16,
            palette::ON_SURFACE_MUTED,
            &st.status,
            type_scale::BODY,
        );
    } else {
        s.rect(VF_X, VF_Y, VF_W * VF_SCALE, VF_H * VF_SCALE, 0x202020);
        s.label(
            VF_X + 16,
            VF_Y + VF_H * VF_SCALE / 2 - 8,
            palette::ON_SURFACE_MUTED,
            "starting viewfinder\u{2026}",
            1,
        );
    }
    let (sx, sy, sw, sh) = shutter_rect();
    s.button(sx, sy, sw, sh, "Capture", ButtonVariant::Filled).ok();
    let (cx, cy, cw, ch) = close_rect();
    s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled).ok();
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

fn main() -> std::io::Result<()> {
    let com = sock("oxcom.sock");
    let mut cl = None;
    for _ in 0..50 {
        match Client::connect(&com) {
            Ok(c) => {
                cl = Some(c);
                break;
            }
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
    let mut cl = match cl {
        Some(c) => c,
        None => return Ok(()),
    };
    let resp = cl.request(
        "window-new",
        json!({ "x": WIN_X, "y": WIN_Y, "w": WIN_W, "h": WIN_H }),
    )?;
    let id = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_u64())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no window id"))?;
    // Foreground app => screen stays on (same contract as the other apps).
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-camera\"}"])
        .status();

    let mut cam = match Client::connect(&sock("camerad.sock")) {
        Ok(c) => c,
        Err(_) => {
            kmsg("OXMILESTONE name=camera-app-exit reason=no-camerad");
            return Ok(());
        }
    };

    let mut st = State {
        denied: false,
        frame: None,
        status: String::new(),
    };
    draw(&mut cl, id, &st)?;
    kmsg("OXMILESTONE name=camera-app-ready");

    // clicks arrive on a helper connection: Close raises the exit flag,
    // Capture raises the shutter flag; the 1s viewfinder loop notices.
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let shot = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let closed = Arc::clone(&closed);
        let shot = Arc::clone(&shot);
        let mut click_cl = Client::connect(&com)?;
        std::thread::spawn(move || loop {
            let resp =
                click_cl.request("click-recv", json!({ "window": id, "timeout_ms": 400_000 }));
            let Ok(resp) = resp else { return };
            if let Some(ev) = resp
                .payload
                .as_ref()
                .and_then(|p| p.get("event"))
                .cloned()
                .filter(|e| !e.is_null())
            {
                let x = ev.get("x").and_then(|v| v.as_u64()).unwrap_or(0);
                let y = ev.get("y").and_then(|v| v.as_u64()).unwrap_or(0);
                if hit(x, y, close_rect()) {
                    closed.store(true, std::sync::atomic::Ordering::SeqCst);
                    return;
                }
                if hit(x, y, shutter_rect()) {
                    shot.store(true, std::sync::atomic::Ordering::SeqCst);
                }
            }
        });
    }

    let mut denied_journaled = false;
    loop {
        if closed.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        // shutter first: a capture while live is the app's whole point
        if shot.swap(false, std::sync::atomic::Ordering::SeqCst) {
            match cam.request("capture", json!({ "app": APP })) {
                Ok(resp) if resp.error.is_none() => {
                    let p = resp.payload.unwrap_or(json!(null));
                    let path = p["path"].as_str().unwrap_or("?").to_string();
                    let colors = p["colors"].as_u64().unwrap_or(0);
                    let syn = p["synthetic"].as_bool().unwrap_or(true);
                    st.status = if syn {
                        format!("saved {path} (synthetic)")
                    } else {
                        format!("saved {path} ({colors} bar colors)")
                    };
                    kmsg(&format!(
                        "OXMILESTONE name=camera-app-captured path={path} colors={colors} synthetic={syn}"
                    ));
                    draw(&mut cl, id, &st)?;
                }
                Ok(resp) => {
                    let e = resp.error.unwrap_or_default();
                    st.status = format!("capture refused: {e}");
                    kmsg(&format!("OXMILESTONE name=camera-app-shutter-denied error={e}"));
                    draw(&mut cl, id, &st)?;
                }
                Err(e) => kmsg(&format!("ox-camera: capture ipc error: {e}")),
            }
        }
        // viewfinder tick
        match cam.request("frame", json!({ "app": APP })) {
            Ok(resp) if resp.error.is_none() => {
                let p = resp.payload.unwrap_or(json!(null));
                let w = p["w"].as_u64().unwrap_or(0);
                let h = p["h"].as_u64().unwrap_or(0);
                let seq = p["seq"].as_u64().unwrap_or(0);
                let syn = p["synthetic"].as_bool().unwrap_or(true);
                let data = p["data"].as_str().unwrap_or("").to_string();
                if w > 0 && !data.is_empty() {
                    st.denied = false;
                    st.frame = Some((w, h, data, seq, syn));
                    st.status = if syn {
                        format!("SYNTHETIC preview (seq {seq}) \u{b7} no camera grant")
                    } else {
                        format!("live sensor preview (seq {seq}) \u{b7} tap Capture to save")
                    };
                    kmsg(&format!(
                        "OXMILESTONE name=camera-app-live seq={seq} synthetic={syn}"
                    ));
                    draw(&mut cl, id, &st)?;
                }
            }
            Ok(resp) => {
                if !denied_journaled {
                    denied_journaled = true;
                    st.denied = true;
                    st.status = resp.error.clone().unwrap_or_default();
                    kmsg("OXMILESTONE name=camera-app-denied");
                    draw(&mut cl, id, &st)?;
                }
            }
            Err(e) => kmsg(&format!("ox-camera: frame ipc error: {e}")),
        }
        std::thread::sleep(Duration::from_millis(1000));
    }
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-camera\",\"release\":true}"])
        .status();
    kmsg("OXMILESTONE name=camera-app-exit");
    Ok(())
}
