//! ox-dialer: the Dialer app v1 — a number pad with call/end over
//! oxmodemd's permission-checked dial/hangup ops (permstored
//! `telephony.dial`; the raw AT path refuses call setup by design).
//! The app renders the honest outcome: refused dials show the denial,
//! fake-mode calls are labeled SYNTHETIC, granted calls dial for real
//! (egress-journaled by the daemon).
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
const PAD_ORIGIN: (u64, u64) = (80, 200);
const PAD_CELL: (u64, u64) = (90, 56);
const PAD_GAP: u64 = 12;
const PAD_LABELS: [&str; 12] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "+"];
const APP: &str = "Dialer";

fn kmsg(line: &str) {
    eprintln!("ox-dialer: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-dialer: {}", line);
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

fn call_rect() -> (u64, u64, u64, u64) {
    (420, 210, 180, 56)
}

fn end_rect() -> (u64, u64, u64, u64) {
    (420, 290, 180, 56)
}

fn answer_rect() -> (u64, u64, u64, u64) {
    (420, 370, 180, 56)
}

fn close_rect() -> (u64, u64, u64, u64) {
    (WIN_W - 48 - 150, WIN_H - 24 - 48, 150, 48)
}

fn hit(x: u64, y: u64, r: (u64, u64, u64, u64)) -> bool {
    x >= r.0 && x < r.0 + r.2 && y >= r.1 && y < r.1 + r.3
}

/// Resolve a click to a pad label / call / end / close action.
fn hit_action(x: u64, y: u64) -> Option<&'static str> {
    for (r, label) in &pad_rects() {
        if hit(x, y, *r) {
            return Some(match *label {
                "C" => "clear",
                "+" => "plus",
                d => d,
            });
        }
    }
    if hit(x, y, call_rect()) {
        return Some("call");
    }
    if hit(x, y, end_rect()) {
        return Some("end");
    }
    if hit(x, y, answer_rect()) {
        return Some("answer");
    }
    if hit(x, y, close_rect()) {
        return Some("close");
    }
    None
}

struct State {
    number: String,
    in_call: Option<(String, bool)>, // number, synthetic
    incoming: Option<String>,        // MT call ringing: caller number
    status: String,
}

fn draw(cl: &mut Client, id: u64, st: &State) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Dialer");
    s.label(80, 130, palette::ON_SURFACE, &st.number, 3);
    if let Some(n) = &st.incoming {
        s.label(
            80,
            166,
            palette::DANGER,
            &format!("INCOMING \u{b7} {n}"),
            type_scale::BODY,
        );
    } else if let Some((n, syn)) = &st.in_call {
        let tag = if *syn { "SYNTHETIC call" } else { "in call" };
        s.label(
            80,
            166,
            if *syn { palette::ON_SURFACE_MUTED } else { palette::PRIMARY },
            &format!("{tag} \u{b7} {n}"),
            type_scale::BODY,
        );
    }
    for (r, label) in pad_rects() {
        s.button(r.0, r.1, r.2, r.3, label, ButtonVariant::Outline).ok();
    }
    let (cx, cy, cw, ch) = call_rect();
    s.button(cx, cy, cw, ch, "Call", ButtonVariant::Filled).ok();
    let (ex, ey, ew, eh) = end_rect();
    s.button(ex, ey, ew, eh, "End", ButtonVariant::Filled).ok();
    if st.incoming.is_some() {
        let (ax, ay, aw, ah) = answer_rect();
        s.button(ax, ay, aw, ah, "Answer", ButtonVariant::Filled).ok();
    }
    s.label(80, 500, palette::ON_SURFACE_MUTED, &st.status, type_scale::BODY);
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
        .args(["powerd", "wake-lock", "{\"id\":\"app-dialer\"}"])
        .status();

    let mut modem = match Client::connect(&sock("oxmodemd.sock")) {
        Ok(c) => c,
        Err(_) => {
            kmsg("OXMILESTONE name=dialer-exit reason=no-modem");
            return Ok(());
        }
    };

    let mut st = State {
        number: String::new(),
        in_call: None,
        incoming: None,
        status: "enter a number, tap Call".to_string(),
    };
    draw(&mut cl, id, &st)?;
    kmsg("OXMILESTONE name=dialer-ready");

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

    let mut denied_journaled = false;
    let mut answer_denied_journaled = false;
    let mut incoming_journaled = false;
    let mut ticks: u64 = 0;
    loop {
        if closed.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        // DRAIN the click queue, apply every action to state, draw ONCE:
        // a redraw per digit (~1s under TCG) let the bounded click hub
        // overflow during fast pad entry and drop the Call click.
        let mut actions = Vec::new();
        match click_tx.recv_timeout(Duration::from_millis(500)) {
            Ok(a) => actions.push(a),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
        while let Ok(a) = click_tx.try_recv() {
            actions.push(a);
        }
        let mut dirty = false;
        // Incoming-call poll (~every 2s): callstatus drives the MT UI —
        // a ringing call raises the INCOMING banner + Answer button;
        // an answered or vanished call updates the state honestly.
        ticks += 1;
        if ticks % 4 == 0 {
            if let Ok(resp) = modem.request("callstatus", json!({ "app": APP })) {
                if resp.error.is_none() {
                    let p = resp.payload.unwrap_or(json!(null));
                    let call = p["call"].as_object();
                    let ringing = call
                        .map(|c| c["ringing"].as_bool().unwrap_or(false))
                        .unwrap_or(false);
                    let syn = call
                        .map(|c| c["synthetic"].as_bool().unwrap_or(true))
                        .unwrap_or(true);
                    match call.map(|c| c["number"].as_str()) {
                        Some(Some(n)) if ringing => {
                            if st.incoming.is_none() && st.in_call.is_none() {
                                st.incoming = Some(n.to_string());
                                if !incoming_journaled {
                                    incoming_journaled = true;
                                    kmsg(&format!(
                                        "OXMILESTONE name=dialer-incoming from={n}"
                                    ));
                                }
                                dirty = true;
                            }
                        }
                        Some(Some(n)) => {
                            // answered (possibly from this UI) — mirror state
                            if st.in_call.is_none() && st.incoming.is_some() {
                                st.incoming = None;
                                st.in_call = Some((n.to_string(), syn));
                                kmsg(&format!(
                                    "OXMILESTONE name=dialer-call-active number={n} synthetic={syn} incoming=true"
                                ));
                                dirty = true;
                            }
                        }
                        _ => {
                            if st.incoming.take().is_some() {
                                st.status = "incoming call ended".to_string();
                                dirty = true;
                            }
                        }
                    }
                }
            }
        }
        for action in actions {
            match action {
                "close" => continue,
                "clear" => {
                    st.number.clear();
                    kmsg("OXMILESTONE name=dialer-key c=C num=");
                    dirty = true;
                }
                "plus" => {
                    if st.number.is_empty() {
                        st.number.push('+');
                        // per-key journal: gates tap keys CAUSALLY
                        // (tap-until-key-journal) instead of firing
                        // single-shot clicks that input-queue lag drops
                        kmsg(&format!(
                            "OXMILESTONE name=dialer-key c=+ num={}",
                            st.number
                        ));
                        dirty = true;
                    }
                }
                d if d.len() == 1 && d.as_bytes()[0].is_ascii_digit() => {
                    if st.number.len() < 20 {
                        st.number.push_str(d);
                        kmsg(&format!(
                            "OXMILESTONE name=dialer-key c={d} num={}",
                            st.number
                        ));
                        dirty = true;
                    }
                }
                "call" => {
                    if st.in_call.is_some() {
                        st.status = "already in a call \u{b7} tap End first".to_string();
                        dirty = true;
                        continue;
                    }
                    match modem.request("dial", json!({ "app": APP, "number": st.number })) {
                        Ok(resp) if resp.error.is_none() => {
                            let p = resp.payload.unwrap_or(json!(null));
                            let syn = p["synthetic"].as_bool().unwrap_or(true);
                            let n = st.number.clone();
                            st.in_call = Some((n.clone(), syn));
                            st.status = "call placed \u{b7} tap End to hang up".to_string();
                            kmsg(&format!(
                                "OXMILESTONE name=dialer-call-active number={n} synthetic={syn}"
                            ));
                            dirty = true;
                        }
                        Ok(resp) => {
                            let e = resp.error.unwrap_or_default();
                            st.status = format!("dial refused: {e}");
                            if !denied_journaled {
                                denied_journaled = true;
                                kmsg(&format!(
                                    "OXMILESTONE name=dialer-call-denied error={e}"
                                ));
                            }
                            dirty = true;
                        }
                        Err(e) => kmsg(&format!("ox-dialer: dial ipc error: {e}")),
                    }
                }
                "answer" => {
                    let Some(n) = st.incoming.clone() else {
                        continue;
                    };
                    match modem.request("answer", json!({ "app": APP })) {
                        Ok(resp) if resp.error.is_none() => {
                            let p = resp.payload.unwrap_or(json!(null));
                            let syn = p["synthetic"].as_bool().unwrap_or(true);
                            st.incoming = None;
                            st.in_call = Some((n.clone(), syn));
                            st.status = "in call \u{b7} tap End to hang up".to_string();
                            kmsg(&format!(
                                "OXMILESTONE name=dialer-call-active number={n} synthetic={syn} incoming=true"
                            ));
                            dirty = true;
                        }
                        Ok(resp) => {
                            let e = resp.error.unwrap_or_default();
                            st.status = format!("answer refused: {e}");
                            if !answer_denied_journaled {
                                answer_denied_journaled = true;
                                kmsg(&format!(
                                    "OXMILESTONE name=dialer-answer-denied error={e}"
                                ));
                            }
                            dirty = true;
                        }
                        Err(e) => kmsg(&format!("ox-dialer: answer ipc error: {e}")),
                    }
                }
                "end" => match modem.request("hangup", json!({ "app": APP })) {
                    Ok(resp) if resp.error.is_none() => {
                        let p = resp.payload.unwrap_or(json!(null));
                        let syn = p["synthetic"].as_bool().unwrap_or(true);
                        st.in_call = None;
                        st.incoming = None;
                        st.status = if syn {
                            "synthetic call ended".to_string()
                        } else {
                            "call ended".to_string()
                        };
                        kmsg(&format!("OXMILESTONE name=dialer-call-ended synthetic={syn}"));
                        dirty = true;
                    }
                    Ok(resp) => {
                        st.status =
                            format!("end refused: {}", resp.error.unwrap_or_default());
                        dirty = true;
                    }
                    Err(e) => kmsg(&format!("ox-dialer: hangup ipc error: {e}")),
                },
                _ => {}
            }
        }
        if dirty {
            draw(&mut cl, id, &st)?;
        }
    }
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-dialer\",\"release\":true}"])
        .status();
    kmsg("OXMILESTONE name=dialer-exit");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_covers_twelve_keys_inside_the_window() {
        let rects = pad_rects();
        assert_eq!(rects.len(), 12);
        for (r, label) in &rects {
            assert!(r.2 >= 48 && r.3 >= 48, "pad key {label} below touch target");
            assert!(r.0 + r.2 <= WIN_W && r.1 + r.3 <= WIN_H, "{label} escapes window");
        }
    }

    #[test]
    fn clicks_resolve_to_actions() {
        let (x, y, w, h) = pad_rects()[0].0;
        assert_eq!(hit_action(x + 5, y + 5), Some("1"));
        assert_eq!(hit_action(x + w + 5, y + 5), None);
        let (cx, cy, _, _) = call_rect();
        assert_eq!(hit_action(cx + 5, cy + 5), Some("call"));
        let (ex, ey, _, _) = end_rect();
        assert_eq!(hit_action(ex + 5, ey + 5), Some("end"));
        let (ax, ay, _, _) = answer_rect();
        assert_eq!(hit_action(ax + 5, ay + 5), Some("answer"));
        let (lx, ly, _, _) = close_rect();
        assert_eq!(hit_action(lx + 5, ly + 5), Some("close"));
    }

    #[test]
    fn answer_button_clears_end_button_and_window() {
        let (ex, ey, ew, eh) = end_rect();
        let (ax, ay, aw, ah) = answer_rect();
        assert!(ax >= ex + ew || ay >= ey + eh, "answer overlaps end");
        assert!(ay + ah <= WIN_H);
        assert!(ax + aw <= WIN_W);
    }

    #[test]
    fn call_and_end_buttons_do_not_overlap_the_pad() {
        let (px, py, pw, ph) = pad_rects()[11].0; // last key: +
        let (cx, cy, cw, ch) = call_rect();
        assert!(cx >= px + pw || cy >= py + ph, "call button overlaps pad");
        let (ex, ey, ew, eh) = end_rect();
        assert!(ex >= px + pw || ey >= py + ph, "end button overlaps pad");
        assert!(cy + ch <= WIN_H && ey + eh <= WIN_H);
    }
}
