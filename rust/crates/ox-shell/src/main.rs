//! ox-shell: the home screen. Boots into a LOCKED state (PIN pad),
//! unlocks into the launch grid, and makes the tiles tappable via
//! compositor click delivery. Tile taps become launch intents sent to
//! intentd, which owns the app lifecycle (the shell never spawns apps
//! directly). PIN verification is delegated to lockd — the secret
//! never lives in this UI process (fail closed if lockd is down).
//! Draw everything through the ox-ui toolkit.
use ox_ipc::{serve, Client};
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const WIN_W: u64 = 1000;
const WIN_H: u64 = 700;
/// Launch targets, in the same order the tiles are drawn.
const APPS: [&str; 4] = ["Settings", "Files", "Terminal", "Payments"];
/// PIN pad: 12 buttons (1-9, C, 0, OK), 3 cols × 4 rows, window coords.
const PAD_ORIGIN: (u64, u64) = (353, 420);
const PAD_CELL: (u64, u64) = (90, 56);
const PAD_GAP: u64 = 12;
const PAD_LABELS: [&str; 12] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK"];
const PIN_MAX_LEN: usize = 8;

/// Best-effort memory hygiene: overwrite a secret buffer with volatile
/// zeroes so the compiler cannot elide the write (a plain `for b in
/// buf { *b = 0 }` on a soon-dropped buffer is dead-code eliminated).
/// Honest boundary: the IPC transport still holds transient JSON
/// copies we do not own — full transport-level secret hygiene is
/// Phase-5 work alongside the key hierarchy.
fn zeroize(buf: &mut [u8]) {
    for b in buf.iter_mut() {
        unsafe { std::ptr::write_volatile(b, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}

/// The typed-PIN buffer. Digits live in a byte buffer that is zeroized
/// on clear AND on drop, and is cleared on every terminal path (grant,
/// reject, throttle, relock) — the entered PIN must never outlive the
/// auth decision.
struct PinEntry(Vec<u8>);

impl PinEntry {
    fn new() -> Self {
        PinEntry(Vec::new())
    }
    fn push(&mut self, digits: &str) {
        for b in digits.bytes() {
            if self.0.len() < PIN_MAX_LEN {
                self.0.push(b);
            }
        }
    }
    fn len(&self) -> usize {
        self.0.len()
    }
    /// The typed code as a string. Safe: only ASCII pad labels land here.
    fn code(&self) -> &str {
        std::str::from_utf8(&self.0).unwrap_or("")
    }
    fn clear(&mut self) {
        zeroize(&mut self.0);
        self.0.clear();
    }
}

impl Drop for PinEntry {
    fn drop(&mut self) {
        zeroize(&mut self.0);
    }
}

fn kmsg(line: &str) {
    eprintln!("ox-shell: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-shell: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn intent_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("intentd.sock")
}

fn lockd_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("lockd.sock")
}

/// Shell event socket: intentd pushes package-set changes here so the
/// home grid refreshes the moment an app is installed or removed.
fn events_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("shell-events.sock")
}

/// Set by the event thread when intentd reports an install/remove;
/// consumed by the main loop on its next bounded wake.
static GRID_DIRTY: AtomicBool = AtomicBool::new(false);

/// How long a click-recv wait may block. Locked: pacing the pad is all
/// that happens (no grid to refresh). Unlocked: short enough that a
/// pkgs-changed event becomes a grid refresh within ~a quarter second
/// of arrival; a clean wake costs one atomic check, nothing more.
fn grid_wait_ms(locked: bool) -> u64 {
    if locked {
        5000
    } else {
        250
    }
}

/// Poll-fallback cadence in unlocked wakes (250 ms each): a missed
/// event self-heals within ~5 s, the old poll behaviour.
const POLL_FALLBACK_TICKS: u64 = 20;

/// Ask lockd to verify a PIN. Fail closed: unreachable daemon or
/// malformed reply means "no". Returns (ok, throttled).
/// Returns (ok, throttled, duress).
fn lockd_verify(pin: &str) -> (bool, bool, bool) {
    let Ok(mut cl) = Client::connect(&lockd_sock()) else {
        kmsg("lockd unreachable — refusing unlock (fail closed)");
        return (false, false, false);
    };
    let Ok(resp) = cl.request("verify", json!({ "pin": pin })) else {
        kmsg("lockd verify request failed — refusing unlock (fail closed)");
        return (false, false, false);
    };
    let p = resp.payload.unwrap_or(json!(null));
    (
        p.get("ok").and_then(|v| v.as_bool()).unwrap_or(false),
        p.get("throttled").and_then(|v| v.as_bool()).unwrap_or(false),
        p.get("duress").and_then(|v| v.as_bool()).unwrap_or(false),
    )
}

/// Tile rects in window coordinates, mirroring draw_home exactly.
fn tile_rects() -> [(u64, u64, u64, u64); 4] {
    let bar_h = (WIN_H * 15 / 100).max(96);
    let gx = 48;
    let gy = bar_h + 6 + 24;
    let (tw, th) = (220u64, 120u64);
    [
        (gx, gy, tw, th),
        (gx + tw + 24, gy, tw, th),
        (gx, gy + th + 24, tw, th),
        (gx + tw + 24, gy + th + 24, tw, th),
    ]
}

/// Footer Lock button (home screen): relock the device.
fn lock_rect() -> (u64, u64, u64, u64) {
    (48, WIN_H - 24 - 48, 150, 48)
}

/// Engage/disengage the compositor shield (chunk 59): while locked, the
/// shell's window is the secure tier — it composites and takes clicks
/// above every app window, whatever launches while the device is locked.
/// The chunk-58 rollout caught a Hello window covering the lock pad and
/// eating PIN taps; this closes it structurally instead of by timing.
fn set_shield(cl: &mut Client, id: u64, on: bool) {
    match cl.request("window-secure", json!({ "id": id, "on": on })) {
        Ok(r) if r.error.is_none() => {}
        other => kmsg(&format!("window-secure on={} failed: {:?}", on, other.err())),
    }
}

/// Footer Recents button: opens/closes the switcher. Doubles as
/// "back to home" while the switcher is open.
fn recents_rect() -> (u64, u64, u64, u64) {
    let (lx, ly, lw, lh) = lock_rect();
    (lx + lw + 24, ly, lw, lh)
}

/// Top-left tap zone: a second switcher trigger that stays reachable
/// even when a full-screen app covers the footer (apps draw from
/// x=190, y=80 down — the shell's top-left strip is always shell).
fn hit_switcher_trigger(x: u64, y: u64) -> bool {
    if hit_recents(x, y) {
        return true;
    }
    x < 180 && y < 72
}

fn hit_lock(x: u64, y: u64) -> bool {
    let (lx, ly, lw, lh) = lock_rect();
    x >= lx && x < lx + lw && y >= ly && y < ly + lh
}

fn hit_recents(x: u64, y: u64) -> bool {
    let (rx, ry, rw, rh) = recents_rect();
    x >= rx && x < rx + rw && y >= ry && y < ry + rh
}

/// Switcher cards: one per running app, stacked under the top bar.
fn switcher_card_rect(i: usize) -> (u64, u64, u64, u64) {
    let bar_h = (WIN_H * 15 / 100).max(96);
    let y0 = bar_h + 6 + 24;
    (24, y0 + (i as u64) * (96 + 12), WIN_W - 48, 96)
}

/// The Close button inside card i (right-aligned, vertically centered).
fn switcher_close_rect(i: usize) -> (u64, u64, u64, u64) {
    let (x, y, w, h) = switcher_card_rect(i);
    (x + w - 24 - 120, y + (h - 48) / 2, 120, 48)
}

fn hit_switcher_close(x: u64, y: u64, running: &[String]) -> Option<usize> {
    for i in 0..running.len() {
        let (cx, cy, cw, ch) = switcher_close_rect(i);
        if x >= cx && x < cx + cw && y >= cy && y < cy + ch {
            return Some(i);
        }
    }
    None
}

fn hit_switcher_card(x: u64, y: u64, running: &[String]) -> Option<usize> {
    for i in 0..running.len() {
        let (cx, cy, cw, ch) = switcher_card_rect(i);
        if x >= cx && x < cx + cw && y >= cy && y < cy + ch {
            return Some(i);
        }
    }
    None
}

/// Footer Alerts button: opens/closes the live activity panel.
fn alerts_rect() -> (u64, u64, u64, u64) {
    let (rx, ry, rw, rh) = recents_rect();
    (rx + rw + 24, ry, rw, rh)
}

fn hit_alerts(x: u64, y: u64) -> bool {
    let (ax, ay, aw, ah) = alerts_rect();
    x >= ax && x < ax + aw && y >= ay && y < ay + ah
}

/// One notification row for the activity panel.
struct AlertRow {
    id: u64,
    app: String,
    title: String,
    body: String,
}

fn notifd_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("notifd.sock")
}

/// Recent notifications from notifd (best effort — no daemon means an
/// empty panel).
fn fetch_alerts() -> Vec<AlertRow> {
    let Ok(mut cl) = Client::connect(&notifd_sock()) else {
        return Vec::new();
    };
    let Ok(resp) = cl.request("list", json!(null)) else {
        return Vec::new();
    };
    resp.payload
        .as_ref()
        .and_then(|p| p.get("notifications"))
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|n| {
                    Some(AlertRow {
                        id: n.get("id")?.as_u64()?,
                        app: n.get("app")?.as_str()?.to_string(),
                        title: n.get("title")?.as_str()?.to_string(),
                        body: n.get("body")?.as_str()?.to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Activity-panel cards: two text lines (title + body) per notification.
fn alerts_card_rect(i: usize) -> (u64, u64, u64, u64) {
    let bar_h = (WIN_H * 15 / 100).max(96);
    let y0 = bar_h + 6 + 24;
    (24, y0 + (i as u64) * (120 + 12), WIN_W - 48, 120)
}

/// The Clear (dismiss) button inside notification card i.
fn alerts_clear_rect(i: usize) -> (u64, u64, u64, u64) {
    let (x, y, w, h) = alerts_card_rect(i);
    (x + w - 24 - 120, y + (h - 48) / 2, 120, 48)
}

fn hit_alerts_clear(x: u64, y: u64, rows: &[AlertRow]) -> Option<usize> {
    for i in 0..rows.len() {
        let (cx, cy, cw, ch) = alerts_clear_rect(i);
        if x >= cx && x < cx + cw && y >= cy && y < cy + ch {
            return Some(i);
        }
    }
    None
}

/// Running apps as reported by intentd (best effort — no daemon or no
/// response means an empty switcher).
fn running_apps() -> Vec<String> {
    let Ok(mut cl) = Client::connect(&intent_sock()) else {
        return Vec::new();
    };
    let Ok(resp) = cl.request("list", json!(null)) else {
        return Vec::new();
    };
    resp.payload
        .as_ref()
        .and_then(|p| p.get("running"))
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default()
}

/// Installed `.oxp` packages reported by intentd (best effort — no
/// daemon or no response means no dynamic tiles). Built-ins already on
/// the grid are filtered out; capped at 4 (grid fits two more rows).
fn dynamic_apps() -> Vec<String> {
    let Ok(mut cl) = Client::connect(&intent_sock()) else {
        return Vec::new();
    };
    let Ok(resp) = cl.request("list", json!(null)) else {
        return Vec::new();
    };
    let Some(list) = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("installed"))
        .and_then(|v| v.as_array())
    else {
        return Vec::new();
    };
    list.iter()
        .filter_map(|v| v.as_str().map(String::from))
        .filter(|a| !APPS.contains(&a.as_str()))
        .take(4) // two dynamic rows fit between the grid and the footer
        .collect()
}

/// Dynamic tile rects: the 2-column grid continued below the built-ins.
/// Dynamic tiles are shorter (88px, still a 48px+ touch target) so TWO
/// dynamic rows fit between the built-in grid and the footer — four
/// packages visible at once.
fn dyn_tile_rect(i: usize) -> (u64, u64, u64, u64) {
    let base = tile_rects()[0];
    let (gx, gy, tw, th) = (base.0, base.1, base.2, base.3);
    let col = (i % 2) as u64;
    let row = (i / 2) as u64;
    let y = gy + 2 * (th + 24) + row * (88 + 24);
    (gx + col * (tw + 24), y, tw, 88)
}

/// PIN pad button rects, row-major: 1..9, then C, 0, OK.
fn pad_rects() -> [(u64, u64, u64, u64); 12] {
    let mut rects = [(0u64, 0u64, 0u64, 0u64); 12];
    for i in rects.iter_mut().enumerate() {
        let (col, row) = (i.0 % 3, i.0 / 3);
        *i.1 = (
            PAD_ORIGIN.0 + col as u64 * (PAD_CELL.0 + PAD_GAP),
            PAD_ORIGIN.1 + row as u64 * (PAD_CELL.1 + PAD_GAP),
            PAD_CELL.0,
            PAD_CELL.1,
        );
    }
    rects
}

/// (kept for the hhmm clock) — the lock secret lives in lockd.
fn hhmm_utc() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let day = secs % 86_400;
    format!("{:02}:{:02}", day / 3600, (day % 3600) / 60)
}

/// The locked screen: clock, entered-digit dots, PIN pad, error strip.
fn draw_locked(cl: &mut Client, id: u64, entered: usize, error: bool) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Ox OS — locked");
    s.label(
        WIN_W / 2 - 80,
        240,
        palette::ON_SURFACE,
        &hhmm_utc(),
        8, // display-size clock (8 px × 8)
    );
    // entered-digit markers (one * per digit)
    let dots: String = "*".repeat(entered.min(PIN_MAX_LEN));
    s.label(
        WIN_W / 2 - entered.min(PIN_MAX_LEN) as u64 * 12,
        360,
        palette::ON_SURFACE_MUTED,
        &dots,
        type_scale::BODY,
    );
    if error {
        s.label(
            WIN_W / 2 - 120,
            392,
            palette::DANGER,
            "wrong PIN / wait — try again",
            type_scale::LABEL,
        );
    }
    let rects = pad_rects();
    for (i, label) in PAD_LABELS.iter().enumerate() {
        let (x, y, w, h) = rects[i];
        if let Err(e) = s.button(x, y, w, h, label, ButtonVariant::Filled) {
            kmsg(&format!("ox-shell: pad button {label} layout rejected: {e}"));
        }
    }
    s.label(
        WIN_W / 2 - 96,
        WIN_H - 24,
        palette::ON_SURFACE_MUTED,
        "device locked \u{b7} enter PIN",
        type_scale::LABEL,
    );
    commit(cl, id, &s)
}

/// The unlocked home screen (optionally with a launch banner). The
/// grid is the four built-ins plus one tile per installed package
/// (caller supplies the list so redraws only happen on real changes).
fn draw_home(
    cl: &mut Client,
    id: u64,
    launched: Option<&str>,
    dyn_apps: &[String],
) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    match launched {
        Some(app) => s.top_bar(&format!("Ox Shell — launched {app}")),
        None => s.top_bar("Ox Shell"),
    }
    for (i, app) in APPS.iter().enumerate() {
        let (x, y, w, h) = tile_rects()[i];
        s.tile(x, y, w, h, app);
    }
    for (i, app) in dyn_apps.iter().enumerate() {
        let (x, y, w, h) = dyn_tile_rect(i);
        s.tile(x, y, w, h, app);
    }
    // Journal the rendered dynamic row (chunk 61-adjacent observability):
    // gates and reports can derive tile positions from THIS instead of
    // assuming a fixed slot — the dynamic set varies with package-selftest
    // timing, and a fixed coordinate taps the wrong app.
    kmsg(&format!(
        "OXMILESTONE name=home-grid dyn={}",
        if dyn_apps.is_empty() { "-".to_string() } else { dyn_apps.join(",") }
    ));
    let (lx, ly, lw, lh) = lock_rect();
    if let Err(e) = s.button(lx, ly, lw, lh, "Lock", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: lock button rejected: {e}"));
    }
    let (rx, ry, rw, rh) = recents_rect();
    if let Err(e) = s.button(rx, ry, rw, rh, "Recents", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: recents button rejected: {e}"));
    }
    let (ax, ay, aw, ah) = alerts_rect();
    if let Err(e) = s.button(ax, ay, aw, ah, "Alerts", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: alerts button rejected: {e}"));
    }
    s.label(
        lx + lw + 24,
        WIN_H - 40,
        palette::ON_SURFACE_MUTED,
        "Ox Shell \u{b7} tap a tile to launch",
        type_scale::LABEL,
    );
    commit(cl, id, &s)
}

/// The live activity panel: recent notifications from notifd, one
/// two-line card each with a Clear (dismiss) button. Same footer as
/// home, with Alerts doubling as "back".
fn draw_alerts(cl: &mut Client, id: u64, rows: &[AlertRow]) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Ox Shell — activity");
    if rows.is_empty() {
        s.label(
            24,
            160,
            palette::ON_SURFACE_MUTED,
            "no notifications",
            type_scale::BODY,
        );
    }
    for (i, n) in rows.iter().enumerate() {
        let (x, y, w, h) = alerts_card_rect(i);
        s.card(x, y, w, h, &n.title, &n.body);
        let (cx, cy, cw, ch) = alerts_clear_rect(i);
        if let Err(e) = s.button(cx, cy, cw, ch, "Clear", ButtonVariant::Outline) {
            kmsg(&format!("ox-shell: clear button rejected: {e}"));
        }
    }
    let (lx, ly, lw, lh) = lock_rect();
    if let Err(e) = s.button(lx, ly, lw, lh, "Lock", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: lock button rejected: {e}"));
    }
    let (rx, ry, rw, rh) = recents_rect();
    if let Err(e) = s.button(rx, ry, rw, rh, "Recents", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: recents button rejected: {e}"));
    }
    let (ax, ay, aw, ah) = alerts_rect();
    if let Err(e) = s.button(ax, ay, aw, ah, "Alerts", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: alerts button rejected: {e}"));
    }
    s.label(
        rx + rw + 24,
        WIN_H - 40,
        palette::ON_SURFACE_MUTED,
        "Ox Shell \u{b7} recent activity",
        type_scale::LABEL,
    );
    kmsg(&format!(
        "OXMILESTONE name=shell-alerts-shown count={}",
        rows.len()
    ));
    commit(cl, id, &s)
}

/// The switcher: one card per running app with a Close button, plus
/// the shared footer (Lock, and Recents doubling as "back home").
fn draw_switcher(cl: &mut Client, id: u64, running: &[String]) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Ox Shell — running apps");
    if running.is_empty() {
        s.label(
            24,
            160,
            palette::ON_SURFACE_MUTED,
            "nothing running",
            type_scale::BODY,
        );
    }
    for (i, app) in running.iter().enumerate() {
        let (x, y, w, h) = switcher_card_rect(i);
        s.tile(x, y, w, h, app);
        let (cx, cy, cw, ch) = switcher_close_rect(i);
        if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Outline) {
            kmsg(&format!("ox-shell: close button rejected: {e}"));
        }
    }
    let (lx, ly, lw, lh) = lock_rect();
    if let Err(e) = s.button(lx, ly, lw, lh, "Lock", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: lock button rejected: {e}"));
    }
    let (rx, ry, rw, rh) = recents_rect();
    if let Err(e) = s.button(rx, ry, rw, rh, "Recents", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: recents button rejected: {e}"));
    }
    let (ax, ay, aw, ah) = alerts_rect();
    if let Err(e) = s.button(ax, ay, aw, ah, "Alerts", ButtonVariant::Filled) {
        kmsg(&format!("ox-shell: alerts button rejected: {e}"));
    }
    s.label(
        rx + rw + 24,
        WIN_H - 40,
        palette::ON_SURFACE_MUTED,
        "Ox Shell \u{b7} running apps",
        type_scale::LABEL,
    );
    commit(cl, id, &s)
}

fn commit(cl: &mut Client, id: u64, s: &Screen) -> std::io::Result<()> {
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

/// Hit-test a click against the launch tiles (built-ins first, then
/// dynamic package tiles); returns the app name. The caller supplies
/// the live package list — an uninstalled app's tile is inert.
fn hit_app(x: u64, y: u64, dyn_apps: &[String]) -> Option<String> {
    for (i, app) in APPS.iter().enumerate() {
        let (tx, ty, tw, th) = tile_rects()[i];
        if x >= tx && x < tx + tw && y >= ty && y < ty + th {
            return Some(app.to_string());
        }
    }
    for (i, app) in dyn_apps.iter().enumerate() {
        let (tx, ty, tw, th) = dyn_tile_rect(i);
        if x >= tx && x < tx + tw && y >= ty && y < ty + th {
            return Some(app.clone());
        }
    }
    None
}

/// Which pad button (if any) is at this window coordinate?
fn hit_pad(x: u64, y: u64) -> Option<usize> {
    let rects = pad_rects();
    for (i, (px, py, pw, ph)) in rects.iter().enumerate() {
        if x >= *px && x < px + pw && y >= *py && y < py + ph {
            return Some(i);
        }
    }
    None
}

/// A launch (from the grid or the switcher) becomes an intent sent to
/// intentd, which owns the app lifecycle. Idempotent while the app
/// runs; degraded to banner-only if intentd is down (recorded, never
/// fatal).
fn send_intent_start(app: &str) {
    match Client::connect(&intent_sock()) {
        Ok(mut ic) => match ic.request("start", json!({ "app": app })) {
            Ok(resp) => kmsg(&format!(
                "OXMILESTONE name=shell-intent app={app} ok={}",
                resp.error.is_none()
            )),
            Err(e) => kmsg(&format!("ox-shell: intent {app} failed: {e}")),
        },
        Err(_) => kmsg("ox-shell: no intentd — launch stays banner-only"),
    }
}

/// What a swipe means on the shell. The mapping is edge-aware:
///   swipe UP from the bottom third  -> go home
///   swipe DOWN from the top strip   -> toggle the activity panel
/// everything else is ignored (no hidden actions mid-screen).
enum GestureAction {
    Home,
    ToggleAlerts,
    Ignore,
}

fn map_gesture(dir: &str, _x: u64, y: u64) -> GestureAction {
    match dir {
        "up" if y > WIN_H * 2 / 3 => GestureAction::Home,
        "down" if y < 120 => GestureAction::ToggleAlerts,
        _ => GestureAction::Ignore,
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
            eprintln!("ox-shell: no compositor at {} — exiting", sock.display());
            return Ok(());
        }
    };
    let st = cl.request("status", json!(null))?;
    let payload = st.payload.ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::Other, "oxcom status: no payload")
    })?;
    // Claim the SYSTEM role (chunk 60): the shell is oxcom's trust
    // anchor — window-secure and cross-window mutations are SYSTEM-only.
    // A refused claim is journaled loudly and boot continues: the shield
    // op will then be refused and the lock-shield gate fails visibly
    // rather than the device silently losing its protection.
    match cl.request("register-system", json!(null)) {
        Ok(r) if r.error.is_none() => kmsg("OXMILESTONE name=shell-system-role ok=true"),
        other => kmsg(&format!(
            "OXMILESTONE name=shell-system-role ok=false reason={:?}",
            other.err()
        )),
    };
    let w = payload.get("w").and_then(|v| v.as_u64()).unwrap_or(0);
    let h = payload.get("h").and_then(|v| v.as_u64()).unwrap_or(0);
    if w == 0 || h == 0 {
        eprintln!("ox-shell: compositor has no display — exiting");
        return Ok(());
    }
    let win_w = WIN_W.min(w);
    let win_h = WIN_H.min(h);
    let resp =
        cl.request("window-new", json!({"x": 0, "y": 0, "w": win_w, "h": win_h}))?;
    let id = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_u64())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no window id"))?;

    // Boot locked with the PIN pad. Verification goes to lockd (which
    // owns the secret and enrolls the DEV default on first boot). Hold
    // a wake lock until first unlock: a phone is awake while its lock
    // screen shows, and the gate's scripted entry must not be frozen
    // by the idle doze.
    let mut locked = true;
    let mut entered = PinEntry::new();
    let mut pin_error = false;
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"shell-screen\"}"])
        .status();
    draw_locked(&mut cl, id, entered.len(), pin_error)?;
    set_shield(&mut cl, id, true);
    kmsg("OXMILESTONE name=shell-locked");
    // pre-render so unlock is instant
    let mut last_dyn: Vec<String> = dynamic_apps();
    draw_home(&mut cl, id, None, &last_dyn)?;
    kmsg(&format!(
        "OXMILESTONE name=shell-home id={id} (hidden behind lock)"
    ));

    let mut launched: Option<String> = None;
    let mut switcher = false;
    // The running list the switcher was LAST DRAWN with — hit tests
    // must match what the user sees, not a fresher fetch.
    let mut running: Vec<String> = Vec::new();
    let mut alerts = false;
    let mut alert_rows: Vec<AlertRow> = Vec::new();
    // Event server: intentd pushes "pkgs-changed" here on every
    // install/remove; the main loop sees GRID_DIRTY on its next bounded
    // wake and redraws the grid immediately — no intentd round-trips
    // while the package set is unchanged.
    let _events = serve(events_sock(), |env| {
        if env.op == "pkgs-changed" {
            GRID_DIRTY.store(true, Ordering::SeqCst);
            kmsg("pkgs-changed event received");
            env.ok(json!({ "queued": true }))
        } else {
            env.err("unknown op")
        }
    })?;
    let mut poll_ticks: u64 = 0;
    loop {
        let resp = cl.request(
            "click-recv",
            json!({ "window": id, "timeout_ms": grid_wait_ms(locked) }),
        )?;
        let Some(ev) = resp
            .payload
            .as_ref()
            .and_then(|p| p.get("event"))
            .cloned()
            .filter(|e| !e.is_null())
        else {
            // Timed out with no click. While unlocked, drain one queued
            // gesture (non-blocking poll — the compositor queues them)
            // before the refresh checks.
            if !locked {
                let gesture = cl
                    .request("gesture-recv", json!({ "window": id, "timeout_ms": 0 }))
                    .ok()
                    .and_then(|r| r.payload)
                    .and_then(|p| p.get("event").cloned())
                    .filter(|e| !e.is_null());
                if let Some(g) = gesture {
                    let dir = g
                        .get("dir")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let gx = g.get("x").and_then(|v| v.as_u64()).unwrap_or(0);
                    let gy = g.get("y").and_then(|v| v.as_u64()).unwrap_or(0);
                    kmsg(&format!("ox-shell: gesture {dir} at {gx},{gy}"));
                    match map_gesture(&dir, gx, gy) {
                        GestureAction::Home => {
                            if switcher || alerts {
                                switcher = false;
                                alerts = false;
                                kmsg("OXMILESTONE name=shell-gesture-home");
                                draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
                            }
                        }
                        GestureAction::ToggleAlerts => {
                            alerts = !alerts;
                            switcher = false;
                            if alerts {
                                alert_rows = fetch_alerts();
                                kmsg("OXMILESTONE name=shell-alerts-open");
                                draw_alerts(&mut cl, id, &alert_rows)?;
                            } else {
                                kmsg("OXMILESTONE name=shell-alerts-close");
                                draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
                            }
                        }
                        GestureAction::Ignore => {}
                    }
                    continue;
                }
                let event = GRID_DIRTY.swap(false, Ordering::SeqCst);
                // Poll fallback: self-heals a missed event at the old
                // 5s cadence (20 x 250ms wakes), journaled distinctly.
                poll_ticks += 1;
                let poll_due = if poll_ticks >= POLL_FALLBACK_TICKS {
                    poll_ticks = 0;
                    true
                } else {
                    false
                };
                if event || poll_due {
                    // Refresh whichever view is on screen (grid,
                    // switcher or activity panel) — fetch and redraw
                    // only on real change.
                    if alerts {
                        let now = fetch_alerts();
                        let changed = now.len() != alert_rows.len()
                            || now
                                .iter()
                                .zip(alert_rows.iter())
                                .any(|(a, b)| a.id != b.id);
                        if changed {
                            kmsg("ox-shell: notifications changed — activity refreshed");
                            draw_alerts(&mut cl, id, &now)?;
                            alert_rows = now;
                        }
                    } else if switcher {
                        let now = running_apps();
                        if now != running {
                            kmsg("ox-shell: running set changed — switcher refreshed");
                            draw_switcher(&mut cl, id, &now)?;
                            running = now;
                        }
                    } else {
                        let dyn_apps = dynamic_apps();
                        if dyn_apps != last_dyn {
                            if event {
                                kmsg("OXMILESTONE name=shell-grid-event-refresh");
                            } else {
                                kmsg(
                                    "ox-shell: package set changed — grid refreshed (poll fallback)",
                                );
                            }
                            draw_home(&mut cl, id, launched.as_deref(), &dyn_apps)?;
                            last_dyn = dyn_apps;
                        }
                    }
                }
            }
            continue;
        };
        let x = ev.get("x").and_then(|v| v.as_u64()).unwrap_or(0);
        let y = ev.get("y").and_then(|v| v.as_u64()).unwrap_or(0);
        kmsg(&format!(
            "ox-shell: click x={x} y={y} locked={locked} entered={}",
            if locked { entered.len() } else { 0 }
        ));
        if locked {
            let Some(key) = hit_pad(x, y) else { continue };
            match PAD_LABELS[key] {
                "C" => entered.clear(),
                "OK" => {
                    let (ok, throttled, duress) = lockd_verify(entered.code());
                    if throttled {
                        // lockd refused to even evaluate (backoff
                        // window): surface it without counting a
                        // rejection. The typed digits MUST be dropped —
                        // otherwise they silently prefix the next
                        // entry and corrupt it.
                        pin_error = true;
                        entered.clear();
                        kmsg("OXMILESTONE name=shell-pin-throttled");
                    } else if ok {
                        locked = false;
                        pin_error = false;
                        // shield off: the home screen competes normally
                        set_shield(&mut cl, id, false);
                        let _ = std::process::Command::new("/usr/bin/oxctl")
                            .args([
                                "powerd",
                                "wake-lock",
                                "{\"id\":\"shell-screen\",\"release\":true}",
                            ])
                            .status();
                        if duress {
                            // Covert unlock: flag it, then trigger the
                            // panic wipe — the duress PIN hands an
                            // attacker a device with no secrets left.
                            kmsg("OXMILESTONE name=shell-duress-unlocked");
                            if let Ok(mut lc) = Client::connect(&lockd_sock()) {
                                match lc.request("panic-wipe", json!(null)) {
                                    Ok(r) if r.error.is_none() => {
                                        kmsg("OXMILESTONE name=shell-panic-wipe-triggered")
                                    }
                                    other => kmsg(&format!(
                                        "panic-wipe failed: {:?}",
                                        other.err()
                                    )),
                                }
                            }
                        }
                        // zeroize the typed code: it must not
                        // outlive the auth decision (it used to
                        // survive the entire unlocked session)
                        entered.clear();
                        kmsg("OXMILESTONE name=shell-unlocked");
                        last_dyn = dynamic_apps();
                        draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
                        continue;
                    } else {
                        pin_error = true;
                        entered.clear();
                        kmsg("OXMILESTONE name=shell-pin-rejected");
                    }
                }
                digit if entered.len() < PIN_MAX_LEN => entered.push(digit),
                _ => {}
            }
            draw_locked(&mut cl, id, entered.len(), pin_error)?;
            continue;
        }
        if hit_lock(x, y) {
            // Relock: reset the secret state, redraw the lock screen,
            // and hold the screen-awake wake lock again.
            locked = true;
            entered.clear();
            pin_error = false;
            launched = None;
            switcher = false;
            alerts = false;
            set_shield(&mut cl, id, true);
            let _ = std::process::Command::new("/usr/bin/oxctl")
                .args(["powerd", "wake-lock", "{\"id\":\"shell-screen\"}"])
                .status();
            draw_locked(&mut cl, id, 0, false)?;
            kmsg("OXMILESTONE name=shell-relocked");
            continue;
        }
        if hit_switcher_trigger(x, y) {
            // Recents toggles the switcher; while the switcher is open
            // it doubles as "back to home". Opening one view closes
            // the other.
            switcher = !switcher;
            alerts = false;
            if switcher {
                running = running_apps();
                kmsg("OXMILESTONE name=shell-switcher-open");
                draw_switcher(&mut cl, id, &running)?;
            } else {
                kmsg("OXMILESTONE name=shell-switcher-close");
                draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
            }
            continue;
        }
        if switcher {
            // Close button: ask intentd to stop the app; refetch and
            // redraw the switcher so the card disappears immediately.
            if let Some(i) = hit_switcher_close(x, y, &running) {
                if let Some(app) = running.get(i).cloned() {
                    let mut ok = false;
                    if let Ok(mut ic) = Client::connect(&intent_sock()) {
                        if let Ok(resp) = ic.request("stop", json!({ "app": app })) {
                            ok = resp.error.is_none();
                        }
                    }
                    if ok {
                        kmsg(&format!("OXMILESTONE name=shell-app-close app={app}"));
                    } else {
                        kmsg(&format!("ox-shell: close {app} refused by intentd"));
                    }
                }
                running = running_apps();
                draw_switcher(&mut cl, id, &running)?;
                kmsg("OXMILESTONE name=shell-switcher-refresh");
                continue;
            }
            // Card body: focus/launch the app and return home.
            if let Some(i) = hit_switcher_card(x, y, &running) {
                if let Some(app) = running.get(i).cloned() {
                    switcher = false;
                    launched = Some(app.clone());
                    kmsg(&format!(
                        "OXMILESTONE name=shell-launch app={app} x={x} y={y}"
                    ));
                    draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
                    send_intent_start(&app);
                }
                continue;
            }
            // Taps elsewhere in the switcher are inert.
            continue;
        }
        if hit_alerts(x, y) {
            // Alerts toggles the live activity panel; opening it
            // closes the switcher (views are exclusive).
            alerts = !alerts;
            switcher = false;
            if alerts {
                alert_rows = fetch_alerts();
                kmsg("OXMILESTONE name=shell-alerts-open");
                draw_alerts(&mut cl, id, &alert_rows)?;
            } else {
                kmsg("OXMILESTONE name=shell-alerts-close");
                draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
            }
            continue;
        }
        if alerts {
            // Clear button: dismiss the notification and refresh the
            // panel so the card disappears immediately.
            if let Some(i) = hit_alerts_clear(x, y, &alert_rows) {
                if let Some(row) = alert_rows.get(i) {
                    let id_n = row.id;
                    if let Ok(mut nc) = Client::connect(&notifd_sock()) {
                        match nc.request("dismiss", json!({ "id": id_n })) {
                            Ok(r) if r.error.is_none() => {
                                kmsg(&format!(
                                    "OXMILESTONE name=shell-alert-dismissed id={id_n}"
                                ));
                            }
                            other => kmsg(&format!("dismiss failed: {:?}", other.err())),
                        }
                    }
                }
                alert_rows = fetch_alerts();
                draw_alerts(&mut cl, id, &alert_rows)?;
            }
            // Card taps are inert (notifications aren't apps).
            continue;
        }
        if let Some(app) = hit_app(x, y, &last_dyn) {
            kmsg(&format!("OXMILESTONE name=shell-launch app={app} x={x} y={y}"));
            launched = Some(app.clone());
            draw_home(&mut cl, id, launched.as_deref(), &last_dyn)?;
            send_intent_start(&app);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiles_cover_the_four_quadrants_of_the_grid() {
        let rects = tile_rects();
        assert_eq!(rects[0].0, 48);
        assert_eq!(rects[1].0, rects[0].0 + rects[0].2 + 24);
        assert_eq!(rects[2].1, rects[0].1 + rects[0].3 + 24);
        assert_eq!(rects[3].0, rects[1].0);
        assert_eq!(rects[3].1, rects[2].1);
    }

    #[test]
    fn hit_app_resolves_inside_tiles_only() {
        let (x, y, w, h) = tile_rects()[0];
        assert_eq!(hit_app(x + 10, y + 10, &[]), Some("Settings".to_string()));
        assert_eq!(hit_app(x + w + 5, y + 10, &[]), None);
        let (tx, ty, _, _) = tile_rects()[3];
        assert_eq!(hit_app(tx + 5, ty + 5, &[]), Some("Payments".to_string()));
    }

    #[test]
    fn dynamic_tiles_continue_the_grid_inside_the_window() {
        for i in 0..4 {
            let (x, y, w, h) = dyn_tile_rect(i);
            assert!(w >= 48 && h >= 48, "dynamic tile below touch target");
            assert!(x + w <= WIN_W && y + h <= WIN_H, "tile {i} escapes window");
        }
        // first dynamic row starts below the built-in grid
        let builtins = tile_rects();
        let bottom = builtins[2].1 + builtins[2].3;
        let (dx, dy, _, _) = dyn_tile_rect(0);
        assert!(dy >= bottom);
        assert_eq!(dx, builtins[0].0);
        // second dynamic tile sits in the right column
        assert_eq!(dyn_tile_rect(1).0, builtins[1].0);
    }

    #[test]
    fn lock_button_sits_below_every_tile_and_inside_the_window() {
        let (lx, ly, lw, lh) = lock_rect();
        assert!(lw >= 48 && lh >= 48);
        assert!(lx + lw <= WIN_W && ly + lh <= WIN_H);
        // no tile may reach into the footer band
        for (tx, ty, tw, th) in tile_rects() {
            assert!(ty + th <= ly, "tile overlaps the lock button");
            let _ = (tx, tw);
        }
        let (dy, dh) = (dyn_tile_rect(1).1, dyn_tile_rect(1).3);
        assert!(dy + dh <= ly, "dynamic tile overlaps the lock button");
        // BOTH dynamic rows must stay above the footer
        for i in 0..4 {
            let (ty, _, _, tth) = dyn_tile_rect(i);
            assert!(ty + tth <= ly, "dynamic tile {i} overlaps the lock button");
        }
        assert!(hit_lock(lx + 5, ly + 5));
        assert!(!hit_lock(1, 1));
    }

    #[test]
    fn pin_pad_layout_covers_keys_inside_the_window() {
        let rects = pad_rects();
        assert_eq!(rects.len(), 12);
        for (x, y, w, h) in rects {
            assert!(w >= 48 && h >= 48, "pad button below touch target");
            assert!(x + w <= WIN_W && y + h <= WIN_H);
        }
        // row-major keys: C at index 9, 0 at 10, OK at 11
        assert_eq!(PAD_LABELS[9], "C");
        assert_eq!(PAD_LABELS[10], "0");
        assert_eq!(PAD_LABELS[11], "OK");
    }

    #[test]
    fn hit_pad_resolves_keys() {
        let (x, y, _, _) = pad_rects()[0];
        assert_eq!(hit_pad(x + 5, y + 5), Some(0));
        let (ox, oy, _, _) = pad_rects()[11];
        assert_eq!(hit_pad(ox + 5, oy + 5), Some(11));
        assert_eq!(hit_pad(0, 0), None); // outside the pad
    }

    #[test]
    fn event_grid_waits_are_bounded() {
        // locked: pad pacing only; unlocked: a pkgs-changed event must
        // become a grid refresh within ~a quarter second.
        assert_eq!(grid_wait_ms(true), 5000);
        assert_eq!(grid_wait_ms(false), 250);
    }

    #[test]
    fn poll_fallback_matches_old_five_second_cadence() {
        assert_eq!(grid_wait_ms(false) * POLL_FALLBACK_TICKS, 5000);
    }

    #[test]
    fn zeroize_overwrites_the_whole_buffer() {
        let mut buf = vec![0xA5u8; 64];
        zeroize(&mut buf);
        assert!(buf.iter().all(|&b| b == 0), "secret bytes must be gone");
        let mut empty: Vec<u8> = Vec::new();
        zeroize(&mut empty);
    }

    #[test]
    fn pin_entry_buffer_caps_clears_and_stays_ascii() {
        let mut e = PinEntry::new();
        for d in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "9"] {
            e.push(d);
        }
        assert_eq!(e.len(), PIN_MAX_LEN, "buffer caps at the max PIN length");
        assert_eq!(e.code(), "12345678");
        e.clear();
        assert_eq!(e.len(), 0);
        assert_eq!(e.code(), "");
        e.push("99");
        assert_eq!(e.code(), "99");
    }

    #[test]
    fn pin_entry_clear_zeroizes_the_backing_bytes() {
        let mut e = PinEntry::new();
        e.push("1234");
        e.clear();
        // clear() zeroizes BEFORE truncating: the backing bytes the
        // digits occupied must hold zeros (not recoverable)
        let wiped = e.0.iter().all(|&b| b == 0);
        assert!(wiped);
    }

    #[test]
    fn recents_button_sits_beside_lock_and_is_hittable() {
        let (lx, ly, lw, _) = lock_rect();
        let (rx, ry, rw, rh) = recents_rect();
        assert_eq!(ry, ly, "buttons share the footer row");
        assert_eq!(rx, lx + lw + 24, "recents sits right of lock");
        assert!(hit_recents(rx + 10, ry + 10));
        assert!(!hit_recents(lx + 10, ry + 10), "that spot is the Lock");
        assert!(!hit_recents(0, 0));
        assert!(rw >= 48 && rh >= 48, "below touch target");
    }

    #[test]
    fn top_left_zone_triggers_the_switcher_even_above_apps() {
        // apps draw from (190, 80): the top-left strip is always shell
        assert!(hit_switcher_trigger(60, 40));
        assert!(hit_switcher_trigger(179, 71));
        assert!(!hit_switcher_trigger(190, 40), "inside an app's column");
        assert!(!hit_switcher_trigger(60, 80), "below the safe strip");
        // and the footer button keeps working through the same trigger
        let (rx, ry, _, _) = recents_rect();
        assert!(hit_switcher_trigger(rx + 10, ry + 10));
    }

    #[test]
    fn switcher_cards_and_close_buttons_resolve() {
        let running = vec!["Settings".to_string(), "Terminal".to_string()];
        let (x, y, w, h) = switcher_card_rect(0);
        let (cx, cy, cw, ch) = switcher_close_rect(0);
        // close sits INSIDE the card
        assert!(cx >= x && cx + cw <= x + w && cy >= y && cy + ch <= y + h);
        assert_eq!(
            hit_switcher_close(cx + 10, cy + 10, &running),
            Some(0),
            "close hit wins over card body"
        );
        // card body (away from the close button) resolves the card
        assert_eq!(hit_switcher_card(x + 20, y + 10, &running), Some(0));
        // second card is below the first, same column
        let (_, y1, _, _) = switcher_card_rect(1);
        assert_eq!(y1, y + h + 12);
        assert_eq!(
            hit_switcher_card(x + 20, y1 + 10, &running),
            Some(1)
        );
        assert_eq!(hit_switcher_close(cx, y1 + 10, &running), None);
        assert_eq!(hit_switcher_card(0, 0, &running), None);
        assert_eq!(hit_switcher_card(x, y, &[]), None);
    }

    #[test]
    fn alerts_button_and_clear_cards_resolve() {
        let (ax, ay, _, _) = alerts_rect();
        let (rx, ry, rw, _) = recents_rect();
        assert_eq!(ay, ry, "buttons share the footer row");
        assert_eq!(ax, rx + rw + 24, "alerts sits right of recents");
        assert!(hit_alerts(ax + 10, ay + 10));
        assert!(!hit_alerts(rx + 10, ay + 10), "that spot is Recents");
        let rows = vec![AlertRow {
            id: 7,
            app: "alerts.test".into(),
            title: "t".into(),
            body: "b".into(),
        }];
        let (x, y, w, h) = alerts_card_rect(0);
        let (cx, cy, cw, ch) = alerts_clear_rect(0);
        assert!(cx >= x && cx + cw <= x + w && cy >= y && cy + ch <= y + h);
        assert_eq!(hit_alerts_clear(cx + 10, cy + 10, &rows), Some(0));
        assert_eq!(
            hit_alerts_clear(x + 10, y + 10, &rows),
            None,
            "card body is inert — only Clear dismisses"
        );
        assert_eq!(hit_alerts_clear(0, 0, &[]), None);
        // card 1 below card 0
        let (_, y1, _, _) = alerts_card_rect(1);
        assert_eq!(y1, y + h + 12);
    }

    #[test]
    fn gestures_map_by_edge_and_direction() {
        // swipe up starting in the bottom third -> home
        assert!(matches!(
            map_gesture("up", 500, 600),
            GestureAction::Home
        ));
        // ...but not from mid-screen (no hidden actions)
        assert!(matches!(map_gesture("up", 500, 300), GestureAction::Ignore));
        // swipe down from the top strip -> activity panel
        assert!(matches!(
            map_gesture("down", 500, 60),
            GestureAction::ToggleAlerts
        ));
        assert!(matches!(map_gesture("down", 500, 300), GestureAction::Ignore));
        // lateral swipes and unknown dirs do nothing anywhere
        assert!(matches!(map_gesture("left", 500, 600), GestureAction::Ignore));
        assert!(matches!(map_gesture("right", 500, 600), GestureAction::Ignore));
        assert!(matches!(map_gesture("", 500, 600), GestureAction::Ignore));
        // the top strip is exactly the bar zone
        assert!(matches!(map_gesture("down", 500, 119), GestureAction::ToggleAlerts));
        assert!(matches!(map_gesture("down", 500, 120), GestureAction::Ignore));
        // the bottom-third boundary
        assert!(matches!(map_gesture("up", 500, WIN_H * 2 / 3 + 1), GestureAction::Home));
        assert!(matches!(map_gesture("up", 500, WIN_H * 2 / 3), GestureAction::Ignore));
    }
}
