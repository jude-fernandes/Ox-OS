//! ox-term: the Terminal app — the keyboard-driven counterpart to the
//! tap-driven apps. Input arrives as compositor key events (`key-recv`):
//! printable characters accumulate on the prompt line, Backspace edits,
//! Enter runs the line through /bin/sh -c and appends the captured
//! output. V1 honestly limits itself to non-interactive commands (the
//! child is awaited to completion and its output is capped) and no `cd`
//! state — each command runs in the app's working directory.
use ox_ipc::Client;
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const WIN_X: u64 = 60;
const WIN_Y: u64 = 60;
const WIN_W: u64 = 1000;
const WIN_H: u64 = 640;
const LINE_H: u64 = 18;
const LINES_Y0: u64 = 120;
const MAX_LINES: usize = 200;
const VISIBLE_LINES: usize = ((WIN_H - LINES_Y0 - 80) / LINE_H) as usize;
const INPUT_MAX: usize = 80;
const BTN_W: u64 = 150;
const BTN_H: u64 = 48;

fn kmsg(line: &str) {
    eprintln!("ox-term: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-term: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

/// (Close button) rect in window coordinates.
fn close_rect() -> (u64, u64, u64, u64) {
    (WIN_W - 48 - BTN_W, WIN_H - 24 - BTN_H, BTN_W, BTN_H)
}

fn hit_close(x: u64, y: u64) -> bool {
    let (cx, cy, cw, ch) = close_rect();
    x >= cx && x < cx + cw && y >= cy && y < cy + ch
}

/// Reduce a key event to the edit action it means. Printable ASCII
/// accumulates, code 14 (evdev BACKSPACE) / DEL edits, code 28
/// (evdev ENTER) or '\n' submits. Anything else is ignored.
fn key_action(code: u64, ch: Option<char>, input: &mut String) -> Action {
    match ch {
        Some('\n') => Action::Run,
        Some(c) if c as u32 == 127 => Action::Edit,
        Some(c) if (32..=126).contains(&(c as u32)) => {
            if input.len() < INPUT_MAX {
                input.push(c);
            }
            Action::None
        }
        _ if code == 28 => Action::Run,
        _ if code == 14 => Action::Edit,
        _ => Action::None,
    }
}

enum Action {
    None,
    Edit,
    Run,
}

/// Run one command line, returning the output lines to append (echo of
/// the command included, output capped).
fn run_line(line: &str) -> Vec<String> {
    let mut out = vec![format!("$ {line}")];
    if line.trim().is_empty() {
        return out;
    }
    match std::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(line)
        .output()
    {
        Ok(o) => {
            let text = String::from_utf8_lossy(&o.stdout);
            let mut n = 0;
            for l in text.lines().skip(0) {
                if n >= 20 {
                    out.push("... (output capped)".to_string());
                    break;
                }
                out.push(l.to_string());
                n += 1;
            }
            let err = String::from_utf8_lossy(&o.stderr);
            if !err.is_empty() {
                out.push(err.lines().next().unwrap_or("").to_string());
            }
            if let Some(code) = o.status.code() {
                if code != 0 {
                    out.push(format!("[exit {code}]"));
                }
            }
        }
        Err(e) => out.push(format!("(cannot run: {e})")),
    }
    out
}

/// Render buffer tail + prompt line + footer button.
fn draw(
    cl: &mut Client,
    id: u64,
    buffer: &[String],
    input: &str,
    status: &str,
) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Terminal");
    let skip = buffer.len().saturating_sub(VISIBLE_LINES - 1);
    for (i, line) in buffer.iter().skip(skip).enumerate() {
        s.label(
            24,
            LINES_Y0 + i as u64 * LINE_H,
            palette::ON_SURFACE,
            line,
            1,
        );
    }
    let py = LINES_Y0 + (VISIBLE_LINES - 1) as u64 * LINE_H;
    s.label(
        24,
        py,
        palette::PRIMARY,
        &format!("$ {input}"),
        type_scale::BODY,
    );
    s.label(
        24,
        WIN_H - 36,
        palette::ON_SURFACE_MUTED,
        status,
        type_scale::LABEL,
    );
    let (cx, cy, cw, ch) = close_rect();
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-term: close button rejected: {e}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
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
            eprintln!("ox-term: no compositor at {} — exiting", sock.display());
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

    let mut buffer: Vec<String> = vec!["Ox Terminal — type a command, Enter runs it".to_string()];
    let mut input = String::new();
    draw(&mut cl, id, &buffer, &input, "v1: non-interactive commands, output capped")?;
    kmsg("OXMILESTONE name=term-ready");
    // Foreground app ⇒ screen stays on (same contract as the other apps).
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-term\"}"])
        .status();

    // Close button: clicks arrive via click-recv while this thread
    // blocks in key-recv — two independent blocking queues. A helper
    // CONNECTION watches clicks and raises the close flag; the main
    // loop wakes on its short key-recv timeout to notice it.
    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let closed = Arc::clone(&closed);
        let mut click_cl = Client::connect(&sock)?;
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
                if hit_close(x, y) {
                    closed.store(true, std::sync::atomic::Ordering::SeqCst);
                    return;
                }
            }
        });
    }

    loop {
        if closed.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        let resp = cl.request("key-recv", json!({ "window": id, "timeout_ms": 1000 }))?;
        let Some(ev) = resp
            .payload
            .as_ref()
            .and_then(|p| p.get("event"))
            .cloned()
            .filter(|e| !e.is_null())
        else {
            continue;
        };
        let code = ev.get("code").and_then(|v| v.as_u64()).unwrap_or(0);
        let ch = ev
            .get("ch")
            .and_then(|v| v.as_str())
            .and_then(|s| s.chars().next());
        kmsg(&format!("ox-term: key code={} ch={:?}", code, ch));
        match key_action(code, ch, &mut input) {
            Action::None => {}
            Action::Edit => {
                // No redraw per edit: every commit is a full redraw
                // (~1 s under TCG), and redrawing per keystroke made the
                // hub queue drop subsequent keys during backspace
                // storms. The prompt repaints on the next Run.
                input.pop();
            }
            Action::Run => {
                let line = std::mem::take(&mut input);
                kmsg(&format!("OXMILESTONE name=term-exec cmd={line}"));
                buffer.extend(run_line(&line));
                if buffer.len() > MAX_LINES {
                    buffer.drain(..buffer.len() - MAX_LINES);
                }
                draw(&mut cl, id, &buffer, &input, "v1: non-interactive commands, output capped")?;
            }
        }
    }
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-term\",\"release\":true}"])
        .status();
    kmsg("OXMILESTONE name=term-exit");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn printable_keys_accumulate_and_backspace_edits() {
        let mut input = String::new();
        for (code, ch) in [(30, Some('l')), (31, Some('s'))] {
            assert!(matches!(key_action(code, ch, &mut input), Action::None));
        }
        assert_eq!(input, "ls");
        assert!(matches!(key_action(14, Some('\u{7f}'), &mut input), Action::Edit));
        input.pop();
        assert_eq!(input, "l");
    }

    #[test]
    fn enter_submits_both_by_char_and_by_code() {
        let mut a = String::new();
        assert!(matches!(key_action(28, Some('\n'), &mut a), Action::Run));
        let mut b = String::new();
        assert!(matches!(key_action(28, None, &mut b), Action::Run));
    }

    #[test]
    fn non_printable_keys_are_ignored() {
        let mut input = String::new();
        assert!(matches!(key_action(1, None, &mut input), Action::None));
        assert!(matches!(key_action(29, Some('\t'), &mut input), Action::None));
        assert!(input.is_empty());
    }

    #[test]
    fn run_line_echoes_and_captures() {
        let out = run_line("echo ox-term-test");
        assert_eq!(out[0], "$ echo ox-term-test");
        assert!(out.iter().any(|l| l == "ox-term-test"));
    }

    #[test]
    fn close_button_stays_inside_the_window() {
        let (x, y, w, h) = close_rect();
        assert!(w >= 48 && h >= 48);
        assert!(x + w <= WIN_W && y + h <= WIN_H);
    }
}
