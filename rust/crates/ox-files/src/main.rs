//! ox-files: the Files app — offline-first file browsing on the intentd
//! app model. Lists a directory as cards (directories first), taps drill
//! down or open a read-only text view, Up walks back out. The browser is
//! sandboxed to its start directory: `..` components are refused (the
//! owner's file manager still respects app confinement until a
//! scoped-storage policy exists). All drawing through ox-ui.
use ox_ipc::Client;
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

const WIN_X: u64 = 190;
const WIN_Y: u64 = 80;
const WIN_W: u64 = 900;
const WIN_H: u64 = 680;
const ROW_X: u64 = 48;
const ROW_W: u64 = WIN_W - 96;
const ROW_H: u64 = 84;
const ROW_GAP: u64 = 16;
const ROWS_Y0: u64 = 120;
const MAX_ROWS: usize = 5;
const BTN_W: u64 = 150;
const BTN_H: u64 = 48;
/// Browser root: every path the app shows lives under this directory.
const START_DIR: &str = "/data/ox";
const VIEW_LINES: usize = 18;

fn kmsg(line: &str) {
    eprintln!("ox-files: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-files: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn row_y(i: usize) -> u64 {
    ROWS_Y0 + i as u64 * (ROW_H + ROW_GAP)
}

/// (Up button, Close button) rects in window coordinates.
fn action_rects() -> ((u64, u64, u64, u64), (u64, u64, u64, u64)) {
    (
        (ROW_X, WIN_H - 24 - BTN_H, BTN_W, BTN_H),
        (WIN_W - ROW_X - BTN_W, WIN_H - 24 - BTN_H, BTN_W, BTN_H),
    )
}

/// Refuse any path that escapes the browser root (plain `..` components
/// and absolute prefixes outside START_DIR).
fn path_allowed(p: &str) -> bool {
    // Prefix must end at a boundary: "/data/ox" must NOT match
    // "/data/ox2/..." (the unit test caught exactly that escape).
    let root = START_DIR.trim_end_matches('/');
    if p != root && !p.starts_with(&format!("{root}/")) {
        return false;
    }
    !p.split('/').any(|c| c == "..")
}

/// One directory listing row: (name, subtitle, is_dir).
fn entry_rows(dir: &str) -> Vec<(String, String, bool)> {
    let mut dirs: Vec<(String, String, bool)> = Vec::new();
    let mut files: Vec<(String, String, bool)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let Ok(name) = e.file_name().into_string() else { continue };
            let meta = e.metadata();
            let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
            let sub = if is_dir {
                "directory".to_string()
            } else {
                format!("{size} B")
            };
            if is_dir {
                dirs.push((name, sub, true));
            } else {
                files.push((name, sub, false));
            }
        }
    }
    dirs.sort();
    files.sort();
    let mut all = dirs;
    all.extend(files);
    all.truncate(MAX_ROWS);
    all
}

enum View {
    List { path: String },
    File { path: String, lines: Vec<String> },
}

fn draw_list(cl: &mut Client, id: u64, path: &str) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar(&format!("Files — {path}"));
    let entries = entry_rows(path);
    if entries.is_empty() {
        s.label(
            ROW_X,
            ROWS_Y0 + 24,
            palette::ON_SURFACE_MUTED,
            "(empty directory)",
            type_scale::BODY,
        );
    }
    for (i, (name, sub, _is_dir)) in entries.iter().enumerate() {
        s.card(ROW_X, row_y(i), ROW_W, ROW_H, name, sub);
    }
    let n = entry_rows_all(path);
    if n > MAX_ROWS {
        s.label(
            ROW_X,
            row_y(MAX_ROWS) + 8,
            palette::ON_SURFACE_MUTED,
            &format!("+{} more", n - MAX_ROWS),
            type_scale::LABEL,
        );
    }
    let ((ux, uy, uw, uh), (cx, cy, cw, ch)) = action_rects();
    if let Err(e) = s.button(ux, uy, uw, uh, "Up", ButtonVariant::Filled) {
        kmsg(&format!("ox-files: up button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-files: close button rejected: {e}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

fn draw_file(cl: &mut Client, id: u64, path: &str, lines: &[String]) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar(&format!("Files — {}", file_name(path)));
    for (i, line) in lines.iter().take(VIEW_LINES).enumerate() {
        s.label(ROW_X, 130 + i as u64 * 22, palette::ON_SURFACE, line, 1);
    }
    let ((ux, uy, uw, uh), (cx, cy, cw, ch)) = action_rects();
    if let Err(e) = s.button(ux, uy, uw, uh, "Back", ButtonVariant::Filled) {
        kmsg(&format!("ox-files: back button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-files: close button rejected: {e}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

/// Total entry count (the list view truncates at MAX_ROWS).
fn entry_rows_all(dir: &str) -> usize {
    std::fs::read_dir(dir)
        .map(|rd| rd.flatten().count())
        .unwrap_or(0)
}

fn file_name(p: &str) -> &str {
    p.rsplit('/').next().unwrap_or(p)
}

/// Which list row (if any) is at this window coordinate?
fn hit_row(y: u64) -> Option<usize> {
    if y < ROWS_Y0 {
        return None;
    }
    let idx = ((y - ROWS_Y0) / (ROW_H + ROW_GAP)) as usize;
    let within = (y - ROWS_Y0) % (ROW_H + ROW_GAP);
    if idx < MAX_ROWS && within < ROW_H {
        Some(idx)
    } else {
        None
    }
}

/// Which footer button (if any)? 0 = Up/Back, 1 = Close.
fn hit_action(x: u64, y: u64) -> Option<u8> {
    let ((ax, ay, aw, ah), (cx, cy, cw, ch)) = action_rects();
    if x >= ax && x < ax + aw && y >= ay && y < ay + ah {
        return Some(0);
    }
    if x >= cx && x < cx + cw && y >= cy && y < cy + ch {
        return Some(1);
    }
    None
}

fn open_file_text(path: &str) -> Vec<String> {
    match std::fs::read(path) {
        Ok(bytes) => String::from_utf8_lossy(&bytes)
            .lines()
            .take(VIEW_LINES)
            .map(|s| s.to_string())
            .collect(),
        Err(e) => vec![format!("(unreadable: {e})")],
    }
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
    let mut cl = match cl {
        Some(c) => c,
        None => {
            eprintln!("ox-files: no compositor at {} — exiting", sock.display());
            return Ok(());
        }
    };
    let resp =
        cl.request("window-new", json!({ "x": WIN_X, "y": WIN_Y, "w": WIN_W, "h": WIN_H }))?;
    let id = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_u64())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no window id"))?;

    let mut view = View::List {
        path: START_DIR.to_string(),
    };
    match &view {
        View::List { path } => draw_list(&mut cl, id, path)?,
        View::File { path, lines } => draw_file(&mut cl, id, path, lines)?,
    }
    kmsg("OXMILESTONE name=files-ready");
    // Foreground app ⇒ screen stays on (same contract as ox-settings):
    // hold a wake lock from draw to exit; released on Close below.
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-files\"}"])
        .status();

    loop {
        let resp =
            cl.request("click-recv", json!({ "window": id, "timeout_ms": 600_000 }))?;
        let Some(ev) = resp
            .payload
            .as_ref()
            .and_then(|p| p.get("event"))
            .cloned()
            .filter(|e| !e.is_null())
        else {
            continue;
        };
        let x = ev.get("x").and_then(|v| v.as_u64()).unwrap_or(0);
        let y = ev.get("y").and_then(|v| v.as_u64()).unwrap_or(0);
        match hit_action(x, y) {
            Some(1) => {
                let _ = std::process::Command::new("/usr/bin/oxctl")
                    .args([
                        "powerd",
                        "wake-lock",
                        "{\"id\":\"app-files\",\"release\":true}",
                    ])
                    .status();
                kmsg("OXMILESTONE name=files-exit");
                break;
            }
            Some(0) => {
                // Up / Back: leave a file view, or climb one directory.
                kmsg("OXMILESTONE name=files-back");
                match std::mem::replace(
                    &mut view,
                    View::List {
                        path: START_DIR.to_string(),
                    },
                ) {
                    View::File { .. } => {
                        let path = START_DIR.to_string();
                        draw_list(&mut cl, id, &path)?;
                        view = View::List { path };
                    }
                    View::List { path } => {
                        let up = match path.trim_end_matches('/').rsplit_once('/') {
                            Some((parent, _)) if parent.len() >= START_DIR.len() => {
                                parent.to_string()
                            }
                            _ => START_DIR.to_string(),
                        };
                        draw_list(&mut cl, id, &up)?;
                        view = View::List { path: up };
                    }
                }
            }
            _ => {
                if let View::List { path } = &view {
                    if let Some(i) = hit_row(y) {
                        let entries = entry_rows(path);
                        if let Some((name, _, is_dir)) = entries.get(i) {
                            let target = format!("{}/{}", path.trim_end_matches('/'), name);
                            if !path_allowed(&target) {
                                kmsg(&format!("files-refused path={target} reason=outside-root"));
                                continue;
                            }
                            if *is_dir {
                                kmsg(&format!(
                                    "OXMILESTONE name=files-open path={target} kind=dir"
                                ));
                                draw_list(&mut cl, id, &target)?;
                                view = View::List { path: target };
                            } else {
                                kmsg(&format!(
                                    "OXMILESTONE name=files-open path={target} kind=file"
                                ));
                                let lines = open_file_text(&target);
                                draw_file(&mut cl, id, &target, &lines)?;
                                view = View::File {
                                    path: target,
                                    lines,
                                };
                            }
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn footer_buttons_stay_inside_the_window() {
        let ((ax, ay, aw, ah), (cx, cy, cw, ch)) = action_rects();
        for (x, y, w, h) in [(ax, ay, aw, ah), (cx, cy, cw, ch)] {
            assert!(w >= 48 && h >= 48, "button below touch target");
            assert!(x + w <= WIN_W && y + h <= WIN_H);
        }
        // the fifth row must end above the footer
        assert!(row_y(MAX_ROWS - 1) + ROW_H <= action_rects().0 .1);
    }

    #[test]
    fn traversal_outside_the_root_is_refused() {
        assert!(path_allowed("/data/ox/receipts.jsonl"));
        assert!(path_allowed("/data/ox/sub/dir"));
        assert!(!path_allowed("/data/ox/../etc/passwd"));
        assert!(!path_allowed("/etc/passwd"));
        assert!(!path_allowed("/data/ox2/steal"));
    }

    #[test]
    fn hit_row_maps_band_coordinates_only() {
        assert_eq!(hit_row(ROWS_Y0 + 10), Some(0));
        assert_eq!(hit_row(ROWS_Y0 + 5), Some(0)); // top edge of row 0
        assert_eq!(hit_row(ROWS_Y0 + ROW_H + 5), None); // in the gap
        assert_eq!(hit_row(ROWS_Y0 + ROW_H + ROW_GAP + 10), Some(1));
        assert_eq!(hit_row(10), None); // above the rows
    }
}
