//! ox-status: first Ox OS UI client. Connects to the oxcom IPC socket
//! and commits the status screen through the ox-ui toolkit (tokens +
//! components → draw ops), then runs the camera in-use indicator: the
//! card window mirrors ox-camerad's activity (a red CAM chip while a
//! viewfinder is consuming the sensor) so the user sees the camera is
//! on from a surface OUTSIDE the camera app.
use ox_ipc::Client;
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

fn kmsg(line: &str) {
    eprintln!("ox-status: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-status: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn daemon_sock(name: &str) -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join(name)
}

/// The main screen, composed entirely from ox-ui components.
fn draw_payload(w: u64, h: u64) -> serde_json::Value {
    let mut s = Screen::new(w, h);
    s.top_bar("Ox OS");
    // status line, inside the bar under the wordmark
    let bar_h = (h * 15 / 100).max(96);
    let big = (bar_h / 24).max(2);
    s.label(
        48,
        16 + big * 8 + 12,
        palette::ON_SURFACE_MUTED,
        "compositor online \u{b7} verified boot \u{b7} IPC ok",
        type_scale::BODY,
    );
    // home grid seed (Phase 3): app tiles
    let tile_w = 220u64.min(w / 2 - 32);
    let tile_h = 120;
    let gy = bar_h + 6 + 24;
    let gx = 48;
    s.tile(gx, gy, tile_w, tile_h, "Settings");
    s.tile(gx + tile_w + 24, gy, tile_w, tile_h, "Files");
    s.tile(gx, gy + tile_h + 24, tile_w, tile_h, "Terminal");
    s.tile(gx + tile_w + 24, gy + tile_h + 24, tile_w, tile_h, "Payments");
    // dock hint
    if h > gy + tile_h * 2 + 24 + 60 {
        s.button(
            gx,
            h - 72,
            tile_w * 2 + 24,
            48,
            "apps (phase 3)",
            ButtonVariant::Outline,
        )
        .ok();
    }
    s.ops_payload()
}

/// The card window (top-right): gives the pointer stack a second
/// window so click-to-focus/raise is observable — and carries the
/// camera in-use indicator (red CAM chip) while the sensor is active.
fn card_ops(card_w: u64, cam_active: bool) -> serde_json::Value {
    let mut s = Screen::new(card_w, 64);
    s.card(0, 0, card_w, 64, "Ox OS 0.1", "windows + input live");
    if cam_active {
        s.rect(card_w - 78, 17, 62, 30, 0xB3261E);
        s.label(card_w - 66, 25, 0xFFFFFF, "CAM", 1);
    }
    s.ops_payload()
}

/// Poll ox-camerad's activity and keep the card indicator + journal in
/// step. A frame within the last 5 seconds (camerad's own rule) means
/// a viewfinder is consuming the camera right now.
fn indicator_loop(cl: &mut Client, card_id: Option<u64>, card_w: u64) {
    let mut last: Option<bool> = None;
    loop {
        std::thread::sleep(Duration::from_secs(2));
        let active = Client::connect(&daemon_sock("camerad.sock"))
            .and_then(|mut c| c.request("active", json!(null)))
            .ok()
            .and_then(|r| r.payload)
            .and_then(|p| p.get("active").and_then(|v| v.as_bool()))
            .unwrap_or(false);
        if Some(active) == last {
            continue;
        }
        match last {
            Some(true) => kmsg("OXMILESTONE name=status-cam-inactive"),
            Some(false) => kmsg("OXMILESTONE name=status-cam-active"),
            None => kmsg(&format!(
                "OXMILESTONE name=status-cam-state active={active}"
            )),
        }
        last = Some(active);
        if let Some(id) = card_id {
            let _ = cl.request(
                "window-commit",
                json!({ "id": id, "ops": card_ops(card_w, active)["ops"] }),
            );
        }
    }
}

fn main() -> std::io::Result<()> {
    let sock = socket_path();
    // The compositor may still be starting under supervision — retry politely.
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
    let mut cl = match cl {
        Some(c) => c,
        None => {
            eprintln!("ox-status: no compositor at {} — exiting", sock.display());
            return Ok(());
        }
    };
    let st = cl.request("status", json!(null))?;
    let payload = st.payload.ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::Other, "oxcom status: no payload")
    })?;
    let w = payload.get("w").and_then(|v| v.as_u64()).unwrap_or(0);
    let h = payload.get("h").and_then(|v| v.as_u64()).unwrap_or(0);
    if w == 0 || h == 0 {
        eprintln!("ox-status: compositor has no display — exiting");
        return Ok(());
    }
    let mut drawn = false;
    if let Ok(resp) = cl.request("draw", draw_payload(w, h)) {
        drawn = resp.error.is_none();
    }
    // A small card window (top-right) — gives the pointer stack a second
    // window so click-to-focus/raise is observable.
    let card_w = 248u64.min(w as u64 - 16);
    let mut card_id = None;
    if let Ok(resp) = cl.request(
        "window-new",
        json!({"x": w as u64 - card_w - 12, "y": 12, "w": card_w, "h": 64}),
    ) {
        if let Some(id) = resp.payload.as_ref().and_then(|p| p.get("id")).and_then(|v| v.as_u64()) {
            let ops = card_ops(card_w, false);
            let _ = cl.request("window-commit", json!({ "id": id, "ops": ops["ops"] }));
            card_id = Some(id);
        }
    }
    if drawn {
        println!("ox-status: UI committed ({}x{})", w, h);
        // longrun semantics: keep the camera indicator live.
        indicator_loop(&mut cl, card_id, card_w);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::Value;
    use super::*;

    #[test]
    fn main_screen_composes_through_the_toolkit() {
        let v = draw_payload(1280, 800);
        let ops = v.get("ops").and_then(|o| o.as_array()).unwrap();
        // surface + bar + accent + title + status + 4 tiles×3 + dock(border×4+label)
        assert_eq!(ops[0]["t"], "rect");
        assert_eq!(ops[0]["w"], 1280);
        assert_eq!(ops[1]["rgb"], palette::SURFACE_HIGH); // bar
        assert_eq!(ops[2]["rgb"], palette::PRIMARY); // accent
        assert_eq!(ops[3]["s"], "Ox OS");
        // tiles: find the Settings tile rect
        // h==120 also matches the top bar (15% of 800) — exclude y==0
        let tiles: Vec<&Value> = ops
            .iter()
            .filter(|o| o["h"] == serde_json::json!(120) && o["y"] != serde_json::json!(0))
            .collect();
        assert_eq!(tiles.len(), 4, "expected 4 app tiles");
        // labels include the four apps
        let text: Vec<&str> = ops
            .iter()
            .filter(|o| o["t"] == serde_json::json!("text"))
            .filter_map(|o| o["s"].as_str())
            .collect();
        for app in ["Settings", "Files", "Terminal", "Payments"] {
            assert!(text.contains(&app), "missing app tile label {app}");
        }
    }

    #[test]
    fn card_window_keeps_pointer_stack_surface() {
        let v = card_ops(248, false);
        let ops = v.get("ops").and_then(|o| o.as_array()).unwrap();
        assert_eq!(ops[0]["w"], 248);
        assert_eq!(ops[3]["s"], "Ox OS 0.1");
        // inactive: no CAM chip text anywhere
        assert!(!ops.iter().any(|o| o["s"] == serde_json::json!("CAM")));
    }

    #[test]
    fn card_shows_the_cam_chip_while_the_camera_is_active() {
        let v = card_ops(248, true);
        let ops = v.get("ops").and_then(|o| o.as_array()).unwrap();
        assert!(ops.iter().any(|o| o["s"] == serde_json::json!("CAM")));
        // the chip rect is the alarm red
        assert!(ops.iter().any(|o| o["t"] == serde_json::json!("rect")
            && o["rgb"] == serde_json::json!(0xB3261E)));
    }
}
