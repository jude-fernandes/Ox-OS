//! ox-sms: the Messaging app v1 — recipient pad + text keyboard over
//! oxmodemd's permission-checked sms-send op (permstored
//! `telephony.sms`; the raw AT path refuses AT+CMGS by design). The
//! app renders the honest outcome: refused sends show the denial,
//! fake-mode sends are labeled SYNTHETIC, granted sends go to the
//! radio for real (egress-journaled by the daemon).
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
// recipient pad (same geometry as the Dialer pad, tighter cells)
const PAD_ORIGIN: (u64, u64) = (80, 180);
const PAD_CELL: (u64, u64) = (72, 48);
const PAD_GAP: u64 = 8;
const PAD_LABELS: [&str; 12] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "+"];
// text keyboard: a-z plus backspace and space, 7 keys per row
const KB_ORIGIN: (u64, u64) = (350, 180);
const KB_CELL: (u64, u64) = (72, 44);
const KB_GAP: u64 = 6;
const KB_ROWS: [&[&str]; 4] = [
    &["a", "b", "c", "d", "e", "f", "g"],
    &["h", "i", "j", "k", "l", "m", "n"],
    &["o", "p", "q", "r", "s", "t", "u"],
    &["v", "w", "x", "y", "z", "<-", "sp"],
];
const APP: &str = "Messaging";

fn kmsg(line: &str) {
    eprintln!("ox-sms: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-sms: {}", line);
    }
}

fn sock(name: &str) -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join(name)
}

fn pad_rects() -> Vec<((u64, u64, u64, u64), &'static str)> {
    PAD_LABELS
        .iter()
        .enumerate()
        .map(|(i, label)| {
            let (col, row) = (i % 3, i / 3);
            (
                (
                    PAD_ORIGIN.0 + col as u64 * (PAD_CELL.0 + PAD_GAP),
                    PAD_ORIGIN.1 + row as u64 * (PAD_CELL.1 + PAD_GAP),
                    PAD_CELL.0,
                    PAD_CELL.1,
                ),
                *label,
            )
        })
        .collect()
}

fn kb_rects() -> Vec<((u64, u64, u64, u64), &'static str)> {
    let mut out = Vec::new();
    for (row, keys) in KB_ROWS.iter().enumerate() {
        for (col, label) in keys.iter().enumerate() {
            out.push((
                (
                    KB_ORIGIN.0 + col as u64 * (KB_CELL.0 + KB_GAP),
                    KB_ORIGIN.1 + row as u64 * (KB_CELL.1 + KB_GAP),
                    KB_CELL.0,
                    KB_CELL.1,
                ),
                *label,
            ));
        }
    }
    out
}

fn send_rect() -> (u64, u64, u64, u64) {
    (80, 470, 180, 48)
}

fn inbox_rect() -> (u64, u64) {
    (80, 545)
}

fn close_rect() -> (u64, u64, u64, u64) {
    (WIN_W - 48 - 150, WIN_H - 24 - 48, 150, 48)
}

fn hit(x: u64, y: u64, r: (u64, u64, u64, u64)) -> bool {
    x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3
}

/// Resolve a click to a pad key / keyboard key / send / close action.
fn hit_action(x: u64, y: u64) -> Option<&'static str> {
    for (r, label) in pad_rects() {
        if hit(x, y, r) {
            return Some(match label {
                "C" => "clear",
                "+" => "plus",
                d => d,
            });
        }
    }
    for (r, label) in kb_rects() {
        if hit(x, y, r) {
            return Some(match label {
                "<-" => "backspace",
                "sp" => "space",
                c => c,
            });
        }
    }
    if hit(x, y, send_rect()) {
        return Some("send");
    }
    if hit(x, y, close_rect()) {
        return Some("close");
    }
    None
}

struct State {
    to: String,
    text: String,
    sent: Option<(String, String, bool)>, // to, text, synthetic
    status: String,
    inbox: Vec<(u64, String, String)>,    // id, from, text
    seen: std::collections::HashSet<u64>,
    ticks: u64,
}

/// The inbox line: count plus the latest message, text truncated to
/// keep the label inside the window.
fn inbox_line(inbox: &[(u64, String, String)]) -> String {
    if inbox.is_empty() {
        return "inbox: empty".to_string();
    }
    let (id, from, text) = inbox.last().unwrap();
    let t: String = text.chars().take(28).collect();
    format!("inbox: {} \u{b7} #{} from {from}: {t}", inbox.len(), id)
}

fn draw(cl: &mut Client, id: u64, st: &State) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Messaging");
    s.label(80, 130, palette::ON_SURFACE, &format!("To: {}", st.to), 2);
    s.label(
        350,
        130,
        palette::ON_SURFACE_MUTED,
        "tap keys to compose",
        type_scale::LABEL,
    );
    for (r, label) in pad_rects() {
        s.button(r.0, r.1, r.2, r.3, label, ButtonVariant::Outline).ok();
    }
    for (r, label) in kb_rects() {
        s.button(r.0, r.1, r.2, r.3, label, ButtonVariant::Outline).ok();
    }
    s.label(80, 420, palette::ON_SURFACE, &st.text, 2);
    if let Some((n, t, syn)) = &st.sent {
        let tag = if *syn { "SYNTHETIC send" } else { "sent" };
        s.label(
            350,
            420,
            if *syn { palette::ON_SURFACE_MUTED } else { palette::PRIMARY },
            &format!("{tag} \u{b7} to {n} \u{b7} {t}"),
            type_scale::BODY,
        );
    }
    let (sx, sy, sw, sh) = send_rect();
    s.button(sx, sy, sw, sh, "Send", ButtonVariant::Filled).ok();
    s.label(300, 484, palette::ON_SURFACE_MUTED, &st.status, type_scale::BODY);
    let (ix, iy) = inbox_rect();
    s.label(ix, iy, palette::ON_SURFACE, &inbox_line(&st.inbox), type_scale::BODY);
    let (lx, ly, lw, lh) = close_rect();
    s.button(lx, ly, lw, lh, "Close", ButtonVariant::Filled).ok();
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
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-messaging\"}"])
        .status();

    let mut modem = match Client::connect(&sock("oxmodemd.sock")) {
        Ok(c) => c,
        Err(_) => {
            kmsg("OXMILESTONE name=sms-exit reason=no-modem");
            return Ok(());
        }
    };

    let mut st = State {
        to: String::new(),
        text: String::new(),
        sent: None,
        status: "enter a number, compose, tap Send".to_string(),
        inbox: Vec::new(),
        seen: std::collections::HashSet::new(),
        ticks: 0,
    };
    draw(&mut cl, id, &st)?;
    kmsg("OXMILESTONE name=sms-ready");

    let closed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let click_tx = {
        let closed = Arc::clone(&closed);
        let (tx, rx): (std::sync::mpsc::Sender<&'static str>, _) = std::sync::mpsc::channel();
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
                if let Some(action) = hit_action(x, y) {
                    if action == "close" {
                        closed.store(true, std::sync::atomic::Ordering::SeqCst);
                        return;
                    }
                    let _ = tx.send(action);
                }
            }
        });
        rx
    };

    loop {
        if closed.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        // DRAIN the click queue, apply every action to state, draw ONCE
        // (a redraw per keypress starves the bounded click hub under TCG).
        let mut actions = Vec::new();
        match click_tx.recv_timeout(Duration::from_millis(500)) {
            Ok(a) => actions.push(a),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
        while let Ok(a) = click_tx.try_recv() {
            actions.push(a);
        }
        // Inbox poll (~every 2s of idle time): attributed sms-list
        // read (permission-checked like sends); new entries are
        // journaled and drawn. During the deny phase the read is
        // refused and the inbox stays honestly empty.
        let mut dirty = false;
        st.ticks += 1;
        if st.ticks % 4 == 0 {
            match modem.request("sms-list", json!({ "app": APP })) {
                Ok(resp) if resp.error.is_none() => {
                    let p = resp.payload.unwrap_or(json!(null));
                    if let Some(entries) = p["sms_received"].as_array() {
                        for e in entries {
                            let id = e["id"].as_u64().unwrap_or(0);
                            let from = e["from"].as_str().unwrap_or("").to_string();
                            let text = e["text"].as_str().unwrap_or("").to_string();
                            if id != 0 && !st.seen.contains(&id) {
                                st.seen.insert(id);
                                st.inbox.push((id, from.clone(), text.clone()));
                                kmsg(&format!(
                                    "OXMILESTONE name=sms-received from={from} text={text}"
                                ));
                                dirty = true;
                            }
                        }
                    }
                }
                _ => {} // denied or IPC hiccup: the inbox stays empty; retry next tick
            }
        }
        for action in actions {
            match action {
                "close" => continue,
                "clear" => {
                    st.to.clear();
                    kmsg(&format!(
                        "OXMILESTONE name=sms-key c=C to={}",
                        st.to
                    ));
                    dirty = true;
                }
                "plus" => {
                    if st.to.is_empty() {
                        st.to.push('+');
                        kmsg(&format!(
                            "OXMILESTONE name=sms-key c=+ to={}",
                            st.to
                        ));
                        dirty = true;
                    }
                }
                "backspace" => {
                    st.text.pop();
                    kmsg(&format!(
                        "OXMILESTONE name=sms-key c=<- txt={}",
                        st.text
                    ));
                    dirty = true;
                }
                "space" => {
                    if st.text.len() < 160 {
                        st.text.push(' ');
                        dirty = true;
                    }
                }
                d if d.len() == 1 && d.as_bytes()[0].is_ascii_digit() => {
                    if st.to.len() < 20 {
                        st.to.push_str(d);
                        kmsg(&format!(
                            "OXMILESTONE name=sms-key c={d} to={}",
                            st.to
                        ));
                        dirty = true;
                    }
                }
                c if c.len() == 1 && c.as_bytes()[0].is_ascii_lowercase() => {
                    if st.text.len() < 160 {
                        st.text.push_str(c);
                        kmsg(&format!(
                            "OXMILESTONE name=sms-key c={c} txt={}",
                            st.text
                        ));
                        dirty = true;
                    }
                }
                "send" => {
                    match modem
                        .request("sms-send", json!({ "app": APP, "to": st.to, "text": st.text }))
                    {
                        Ok(resp) if resp.error.is_none() => {
                            let p = resp.payload.unwrap_or(json!(null));
                            let syn = p["synthetic"].as_bool().unwrap_or(true);
                            let (n, t) = (st.to.clone(), st.text.clone());
                            st.sent = Some((n.clone(), t.clone(), syn));
                            st.status = if syn {
                                "synthetic send \u{b7} the radio never saw it".to_string()
                            } else {
                                "message sent".to_string()
                            };
                            kmsg(&format!(
                                "OXMILESTONE name=sms-sent to={n} text={t} synthetic={syn}"
                            ));
                            dirty = true;
                        }
                        Ok(resp) => {
                            let e = resp.error.unwrap_or_default();
                            st.status = format!("send refused: {e}");
                            // journal EVERY failure: a denied-once dedupe
                            // (for the deny leg) used to silence real
                            // modem/transport errors after the grant
                            if e.contains("denied") {
                                kmsg(&format!(
                                    "OXMILESTONE name=sms-send-denied error={e}"
                                ));
                            } else {
                                kmsg(&format!(
                                    "OXMILESTONE name=sms-send-error error={e}"
                                ));
                            }
                            dirty = true;
                        }
                        Err(e) => {
                            kmsg(&format!(
                                "OXMILESTONE name=sms-send-error error=ipc {e}"
                            ));
                        }
                    }
                }
                _ => {}
            }
        }
        if dirty {
            draw(&mut cl, id, &st)?;
        }
    }
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-messaging\",\"release\":true}"])
        .status();
    kmsg("OXMILESTONE name=sms-exit");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_and_keyboard_stay_inside_the_window() {
        let rects: Vec<_> = pad_rects()
            .into_iter()
            .chain(kb_rects())
            .map(|(r, l)| (r, l))
            .collect();
        assert_eq!(rects.len(), 12 + 28);
        for (r, label) in &rects {
            assert!(r.2 >= 44 && r.3 >= 44, "key {label} below touch target");
            assert!(r.0 + r.2 <= WIN_W && r.1 + r.3 <= WIN_H, "{label} escapes window");
        }
    }

    #[test]
    fn keyboards_and_buttons_do_not_overlap() {
        let pad_last = pad_rects()[11].0; // last pad key: +
        let kb_last = kb_rects()[27].0; // last keyboard key: sp
        assert!(
            kb_last.0 >= pad_last.0 + pad_last.2,
            "keyboard overlaps the pad"
        );
        let (sx, sy, sw, sh) = send_rect();
        assert!(sy >= 420 + 16 + 20, "send button crowds the text preview");
        let (lx, ly, _, lh) = close_rect();
        assert!(sx + sw <= lx && ly + lh <= WIN_H);
    }

    #[test]
    fn clicks_resolve_to_actions() {
        let ((x, y, w, h), _) = pad_rects()[0];
        assert_eq!(hit_action(x + 5, y + 5), Some("1"));
        assert_eq!(hit_action(x + w + 5, y + 5), None);
        let ((kx, ky, _, _), _) = kb_rects()[0]; // 'a'
        assert_eq!(hit_action(kx + 5, ky + 5), Some("a"));
        let ((bx, by, _, _), _) = kb_rects()[26]; // '<-'
        assert_eq!(hit_action(bx + 5, by + 5), Some("backspace"));
        let ((px, py, _, _), _) = kb_rects()[27]; // 'sp'
        assert_eq!(hit_action(px + 5, py + 5), Some("space"));
        let (sx, sy, _, _) = send_rect();
        assert_eq!(hit_action(sx + 5, sy + 5), Some("send"));
        let (lx, ly, _, _) = close_rect();
        assert_eq!(hit_action(lx + 5, ly + 5), Some("close"));
    }

    #[test]
    fn kb_rows_cover_the_alphabet() {
        let letters: String = kb_rects()
            .into_iter()
            .map(|(_, l)| l)
            .filter(|l| l.len() == 1)
            .collect();
        assert_eq!(letters, "abcdefghijklmnopqrstuvwxyz");
    }

    #[test]
    fn inbox_line_truncates_and_counts() {
        assert_eq!(inbox_line(&[]), "inbox: empty");
        let inbox = vec![
            (1u64, "+15550002".to_string(), "first".to_string()),
            (
                2u64,
                "+15550003".to_string(),
                "a very long message that should be truncated at some point!!".to_string(),
            ),
        ];
        let line = inbox_line(&inbox);
        assert!(line.starts_with("inbox: 2 \u{b7} #2 from +15550003: "));
        assert!(line.chars().count() < 60, "inbox line must stay short");
        assert!(!line.contains("!!"), "text must be truncated");
    }
}
