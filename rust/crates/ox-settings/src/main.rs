//! ox-settings: the Settings app. Info cards, a live airplane-mode
//! toggle, and a Change PIN flow — a pad-based enrollment (current →
//! new → confirm) that talks to lockd; the secret itself never enters
//! this process beyond the typed digits in memory. Proves the full
//! app lifecycle (spawn → draw → interact → exit → reap) and now a
//! multi-stage user flow. All drawing through ox-ui.
use ox_ipc::Client;
use ox_ui::{palette, type_scale, ButtonVariant, Screen};
use serde_json::json;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::Duration;

/// Window placement: offset from the shell (which owns 0,0 1000x700) so
/// both are visible in the launch screendump. oxcom stacks windows in
/// creation order — created later, this renders on top.
const WIN_X: u64 = 190;
const WIN_Y: u64 = 80;
const WIN_W: u64 = 900;
const WIN_H: u64 = 680;
const ROW_X: u64 = 48;
const ROW_W: u64 = WIN_W - 96;
const ROW_H: u64 = 84;
const ROW_GAP: u64 = 16;
const ROWS_Y0: u64 = 120; // below the top bar
const ROWS: [(&str, &str); 4] = [
    ("Network", "eth0 up \u{b7} 10.0.2.15 (virtual target)"),
    ("Display", "1280 \u{d7} 800 \u{b7} compositor-owned scanout"),
    ("Battery", "AC power \u{b7} no battery on the virtual target"),
    ("About", "Ox OS 0.1 dev \u{b7} no telemetry, ever"),
];
/// Airplane row sits under the cards; the three action buttons share
/// fixed rects used by both draw AND hit-testing.
const AP_ROW_Y: u64 = ROWS_Y0 + 4 * (ROW_H + ROW_GAP);
const BTN_W: u64 = 150;
const BTN_H: u64 = 48;
/// Enrollment pad (3 cols x 4 rows), centered under the action row.
const PAD_ORIGIN: (u64, u64) = (303, 200);
const PAD_CELL: (u64, u64) = (90, 56);
const PAD_GAP: u64 = 12;
const PAD_LABELS: [&str; 12] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "OK"];
const PIN_MAX_LEN: usize = 8;

fn kmsg(line: &str) {
    eprintln!("ox-settings: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-settings: {}", line);
    }
}

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn lockd_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("lockd.sock")
}

/// Ask lockd to rotate the PIN. Returns Err(reason) on refusal.
fn lockd_enroll(current: &str, new: &str) -> Result<(), String> {
    let Ok(mut cl) = Client::connect(&lockd_sock()) else {
        return Err("lockd unreachable".into());
    };
    let resp = cl
        .request("enroll", json!({ "current": current, "new": new }))
        .map_err(|e| format!("lockd request: {e}"))?;
    if let Some(e) = resp.error {
        return Err(e);
    }
    Ok(())
}

fn row_y(i: usize) -> u64 {
    ROWS_Y0 + i as u64 * (ROW_H + ROW_GAP)
}

/// (airplane, change-pin, permissions, apps, close) button rects.
type Rects = (
    (u64, u64, u64, u64),
    (u64, u64, u64, u64),
    (u64, u64, u64, u64),
    (u64, u64, u64, u64),
    (u64, u64, u64, u64),
);

fn action_rects() -> Rects {
    (
        (
            ROW_X + ROW_W - BTN_W,
            AP_ROW_Y + (ROW_H - BTN_H) / 2,
            BTN_W,
            BTN_H,
        ),
        (ROW_X, AP_ROW_Y + (ROW_H - BTN_H) / 2, BTN_W, BTN_H),
        (ROW_X + BTN_W + 24, AP_ROW_Y + (ROW_H - BTN_H) / 2, BTN_W, BTN_H),
        (
            ROW_X + 2 * (BTN_W + 24),
            AP_ROW_Y + (ROW_H - BTN_H) / 2,
            BTN_W,
            BTN_H,
        ),
        (WIN_W - ROW_X - BTN_W, WIN_H - 24 - BTN_H, BTN_W, BTN_H),
    )
}

fn pad_rects() -> [(u64, u64, u64, u64); 12] {
    let mut rects = [(0u64, 0u64, 0u64, 0u64); 12];
    for (i, r) in rects.iter_mut().enumerate() {
        let (col, row) = (i % 3, i / 3);
        *r = (
            PAD_ORIGIN.0 + col as u64 * (PAD_CELL.0 + PAD_GAP),
            PAD_ORIGIN.1 + row as u64 * (PAD_CELL.1 + PAD_GAP),
            PAD_CELL.0,
            PAD_CELL.1,
        );
    }
    rects
}

/// Which pad button (if any) is at this window coordinate?
fn hit_pad(x: u64, y: u64) -> Option<usize> {
    for (i, (px, py, pw, ph)) in pad_rects().iter().enumerate() {
        if x >= *px && x < px + pw && y >= *py && y < py + ph {
            return Some(i);
        }
    }
    None
}

/// Which action button (if any) is at this window coordinate? 0 =
/// airplane toggle, 1 = change PIN, 2 = close, 3 = permissions.
/// Wi-Fi button: a fourth action in the airplane row (code 5).
fn wifi_rect() -> (u64, u64, u64, u64) {
    (
        ROW_X + 3 * (BTN_W + 24),
        AP_ROW_Y + (ROW_H - BTN_H) / 2,
        BTN_W,
        BTN_H,
    )
}

fn oxwifid_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxwifid.sock")
}

/// Fetch Wi-Fi state + scan results through oxwifid (Settings holds a
/// wifi.scan grant). Best effort: a dead daemon yields an error string.
/// Returns (status line, [(ssid, signal_dbm)]).
fn wifi_fetch() -> Result<(String, Vec<(String, i32)>), String> {
    let mut cl = Client::connect(&oxwifid_sock())
        .map_err(|e| format!("oxwifid unreachable: {e}"))?;
    let st = cl
        .request("status", json!({ "app": "Settings" }))
        .map_err(|e| format!("status: {e}"))?;
    if st.error.is_some() {
        return Err(st.error.unwrap_or_default());
    }
    let p = st.payload.unwrap_or(json!(null));
    let state = p
        .get("state")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let ssid = p
        .get("ssid")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let scan = cl
        .request("scan", json!({ "app": "Settings" }))
        .map_err(|e| format!("scan: {e}"))?;
    if scan.error.is_some() {
        return Err(scan.error.unwrap_or_default());
    }
    let mut rows = Vec::new();
    if let Some(list) = scan
        .payload
        .as_ref()
        .and_then(|p| p.get("networks"))
        .and_then(|v| v.as_array())
    {
        for n in list {
            if let (Some(ssid), Some(sig)) = (
                n.get("ssid").and_then(|v| v.as_str()),
                n.get("signal_dbm").and_then(|v| v.as_i64()),
            ) {
                rows.push((ssid.to_string(), sig as i32));
            }
        }
    }
    Ok((format!("{state} {ssid}"), rows))
}

/// Wi-Fi rows in the panel view.
fn wifi_row_y(i: usize) -> u64 {
    P_ROWS_Y0 + i as u64 * (P_ROW_H + P_ROW_GAP)
}

fn hit_action(x: u64, y: u64) -> Option<u8> {
    let ((ax, ay, aw, ah), (cx, cy, cw, ch), (px, py, pw, ph), (abx, aby, abw, abh), (fx, fy, fw, fh)) =
        action_rects();
    let (wx, wy, ww, wh) = wifi_rect();
    // codes are the app's action verbs: 0 airplane, 1 change-pin,
    // 2 close (footer), 3 permissions, 4 apps, 5 wifi — NEVER derive
    // them from list order (that swap shipped once and closed the app
    // on tap).
    for (code, (x0, y0, w, h)) in [
        (0u8, (ax, ay, aw, ah)),
        (1u8, (cx, cy, cw, ch)),
        (3u8, (px, py, pw, ph)),
        (4u8, (abx, aby, abw, abh)),
        (5u8, (wx, wy, ww, wh)),
        (2u8, (fx, fy, fw, fh)),
    ] {
        if x >= x0 && x < x0 + w && y >= y0 && y < y0 + h {
            return Some(code);
        }
    }
    None
}

/// Permissions-view rows (Files layout) + footer buttons.
const P_ROWS_Y0: u64 = 120;
const P_ROW_H: u64 = 72;
const P_ROW_GAP: u64 = 12;
const P_MAX_ROWS: usize = 5; // 6 would collide with the footer (test-caught)

fn p_row_y(i: usize) -> u64 {
    P_ROWS_Y0 + i as u64 * (P_ROW_H + P_ROW_GAP)
}

/// (Back, Close) footer rects for the permissions view.
fn p_footer_rects() -> ((u64, u64, u64, u64), (u64, u64, u64, u64)) {
    (
        (ROW_X, WIN_H - 24 - BTN_H, BTN_W, BTN_H),
        (WIN_W - ROW_X - BTN_W, WIN_H - 24 - BTN_H, BTN_W, BTN_H),
    )
}

fn hit_p_footer(x: u64, y: u64) -> Option<u8> {
    let ((bx, by, bw, bh), (cx, cy, cw, ch)) = p_footer_rects();
    if x >= bx && x < bx + bw && y >= by && y < by + bh {
        return Some(0);
    }
    if x >= cx && x < cx + cw && y >= cy && y < cy + ch {
        return Some(1);
    }
    None
}

/// Which permissions row (if any) is at this window coordinate?
fn hit_p_row(y: u64) -> Option<usize> {
    if y < P_ROWS_Y0 {
        return None;
    }
    let idx = ((y - P_ROWS_Y0) / (P_ROW_H + P_ROW_GAP)) as usize;
    let within = (y - P_ROWS_Y0) % (P_ROW_H + P_ROW_GAP);
    if idx < P_MAX_ROWS && within < P_ROW_H {
        Some(idx)
    } else {
        None
    }
}

fn permstored_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("permstored.sock")
}

/// All permission entries, sorted (app, permission, mode).
fn perms_list() -> Vec<(String, String, String)> {
    let Ok(mut cl) = Client::connect(permstored_sock()) else {
        return Vec::new();
    };
    let Ok(resp) = cl.request("list", json!(null)) else {
        return Vec::new();
    };
    let Some(arr) = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("entries"))
        .and_then(|v| v.as_array())
    else {
        return Vec::new();
    };
    let mut out: Vec<(String, String, String)> = arr
        .iter()
        .filter_map(|e| {
            Some((
                e.get("app")?.as_str()?.to_string(),
                e.get("permission")?.as_str()?.to_string(),
                e.get("mode")?.as_str()?.to_string(),
            ))
        })
        .collect();
    out.sort();
    out.truncate(P_MAX_ROWS);
    out
}

/// Set one entry's mode. Err(reason) on refusal.
fn perm_set(app: &str, perm: &str, mode: &str) -> Result<(), String> {
    let Ok(mut cl) = Client::connect(permstored_sock()) else {
        return Err("permstored unreachable".into());
    };
    let resp = cl
        .request("set", json!({ "app": app, "permission": perm, "mode": mode }))
        .map_err(|e| format!("request: {e}"))?;
    match resp.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// Installed package names (intentd list).
fn installed_list() -> Vec<String> {
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("intentd.sock");
    let Ok(mut cl) = Client::connect(&sock) else {
        return Vec::new();
    };
    let Ok(resp) = cl.request("list", json!(null)) else {
        return Vec::new();
    };
    let Some(arr) = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("installed"))
        .and_then(|v| v.as_array())
    else {
        return Vec::new();
    };
    let mut out: Vec<String> = arr
        .iter()
        .filter_map(|v| v.as_str().map(String::from))
        .collect();
    out.sort();
    out
}

/// Remove an installed package (intentd remove). Err(reason).
fn app_remove(app: &str) -> Result<(), String> {
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("intentd.sock");
    let Ok(mut cl) = Client::connect(&sock) else {
        return Err("intentd unreachable".into());
    };
    let resp = cl
        .request("remove", json!({ "app": app }))
        .map_err(|e| format!("request: {e}"))?;
    match resp.error {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

/// The multi-stage enrollment flow: which secret is being typed.
#[derive(PartialEq)]
enum Stage {
    Current,
    New,
    Confirm,
}

struct Enroll {
    stage: Stage,
    current: String,
    new: String,
    typing: String,
    error: Option<String>,
}

impl Enroll {
    fn new() -> Self {
        Enroll {
            stage: Stage::Current,
            current: String::new(),
            new: String::new(),
            typing: String::new(),
            error: None,
        }
    }

    fn stage_label(&self) -> &'static str {
        match self.stage {
            Stage::Current => "Change PIN — enter current PIN",
            Stage::New => "Change PIN — enter new PIN (4-8 digits)",
            Stage::Confirm => "Change PIN — confirm new PIN",
        }
    }

    /// Advance the flow with the collected `typing`. Returns Ok(true)
    /// when the rotation was accepted end to end.
    fn submit(&mut self) -> Result<bool, ()> {
        match self.stage {
            Stage::Current => {
                self.current = std::mem::take(&mut self.typing);
                self.stage = Stage::New;
                self.error = None;
                Ok(false)
            }
            Stage::New => {
                self.new = std::mem::take(&mut self.typing);
                self.stage = Stage::Confirm;
                self.error = None;
                Ok(false)
            }
            Stage::Confirm => {
                let confirm = std::mem::take(&mut self.typing);
                if confirm != self.new {
                    self.error = Some("new PINs do not match".into());
                    self.stage = Stage::New;
                    return Err(());
                }
                match lockd_enroll(&self.current, &self.new) {
                    Ok(()) => Ok(true),
                    Err(e) => {
                        self.error = Some(e);
                        self.stage = Stage::Current;
                        self.current.clear();
                        self.new.clear();
                        Err(())
                    }
                }
            }
        }
    }
}

fn draw_settings(cl: &mut Client, id: u64, airplane: bool) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Settings");
    for (i, (title, sub)) in ROWS.iter().enumerate() {
        s.card(ROW_X, row_y(i), ROW_W, ROW_H, title, sub);
    }
    let ((ax, ay, aw, ah), (cx, cy, cw, ch), (px, py, pw, ph), (abx, aby, abw, abh), (fx, fy, fw, fh)) =
        action_rects();
    let airplane_label = if airplane { "Airplane: on" } else { "Airplane: off" };
    if let Err(e) = s.button(ax, ay, aw, ah, airplane_label, ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: airplane button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Change PIN", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: change-pin button rejected: {e}"));
    }
    if let Err(e) = s.button(px, py, pw, ph, "Permissions", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: permissions button rejected: {e}"));
    }
    if let Err(e) = s.button(abx, aby, abw, abh, "Apps", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: apps button rejected: {e}"));
    }
    let (wx, wy, ww, wh) = wifi_rect();
    if let Err(e) = s.button(wx, wy, ww, wh, "Wi-Fi", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: wifi button rejected: {e}"));
    }
    if let Err(e) = s.button(fx, fy, fw, fh, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: close button rejected: {e}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

fn draw_enroll(cl: &mut Client, id: u64, e: &Enroll) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Settings");
    s.label(ROW_X, ROWS_Y0 + 8, palette::ON_SURFACE, e.stage_label(), type_scale::BODY);
    let dots: String = "*".repeat(e.typing.len().min(PIN_MAX_LEN));
    s.label(
        WIN_W / 2 - e.typing.len().min(PIN_MAX_LEN) as u64 * 12,
        ROWS_Y0 + 44,
        palette::ON_SURFACE_MUTED,
        &dots,
        type_scale::BODY,
    );
    if let Some(err) = &e.error {
        s.label(ROW_X, ROWS_Y0 + 76, palette::DANGER, err, type_scale::LABEL);
    }
    for (i, label) in PAD_LABELS.iter().enumerate() {
        let (x, y, w, h) = pad_rects()[i];
        if let Err(err) = s.button(x, y, w, h, label, ButtonVariant::Filled) {
            kmsg(&format!("ox-settings: pad button {label} rejected: {err}"));
        }
    }
    let (_, _, _, _, (fx, fy, fw, fh)) = action_rects();
    if let Err(err) = s.button(fx, fy, fw, fh, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: close button rejected: {err}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

/// The grants panel: one card per (app, permission) with its mode;
/// tapping a card toggles grant<->deny via permstored.
fn draw_perms(cl: &mut Client, id: u64, entries: &[(String, String, String)]) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Permissions");
    if entries.is_empty() {
        s.label(
            ROW_X,
            P_ROWS_Y0 + 24,
            palette::ON_SURFACE_MUTED,
            "(no permission entries)",
            type_scale::BODY,
        );
    }
    for (i, (app, perm, mode)) in entries.iter().enumerate() {
        let mode_color = match mode.as_str() {
            "grant" => palette::PRIMARY,
            "deny" => palette::DANGER,
            _ => palette::ON_SURFACE_MUTED,
        };
        // card + a mode chip drawn as a colored label on the right
        s.card(ROW_X, p_row_y(i), ROW_W - 160, P_ROW_H, app, perm);
        s.label(
            ROW_W - 96,
            p_row_y(i) + (P_ROW_H - 24) / 2,
            mode_color,
            mode,
            type_scale::BODY,
        );
        // Chunk 68: journal the rendered row so gates derive tap
        // coordinates from the ACTUAL layout (the grid-dyn lesson —
        // entry order shifts as grant identities change). y is the
        // row's CENTER in WINDOW space (the window's scene offset is
        // the shell's business — gates read it from window-new).
        kmsg(&format!(
            "OXMILESTONE name=perm-row row={} app={} perm={} mode={} y={}",
            i + 1,
            app,
            perm,
            mode,
            p_row_y(i) + P_ROW_H / 2
        ));
    }
    s.label(
        ROW_X,
        WIN_H - 60,
        palette::ON_SURFACE_MUTED,
        "tap an entry to toggle grant / deny",
        type_scale::LABEL,
    );
    let ((bx, by, bw, bh), (cx, cy, cw, ch)) = p_footer_rects();
    if let Err(e) = s.button(bx, by, bw, bh, "Back", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: back button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: close button rejected: {e}"));
    }
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

/// The installed-apps panel: one card per package; tapping removes it
/// (grants die with it — intentd unbinds).
/// The Wi-Fi panel: status line + one card per scanned network.
/// Informational (PSK entry comes with the credential store); the
/// count is journaled — the gate's assertion surface.
fn draw_wifi(
    cl: &mut Client,
    id: u64,
    status: &str,
    rows: &[(String, i32)],
) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Wi-Fi");
    s.label(
        ROW_X,
        P_ROWS_Y0,
        palette::ON_SURFACE,
        status,
        type_scale::BODY,
    );
    if rows.is_empty() {
        s.label(
            ROW_X,
            P_ROWS_Y0 + 48,
            palette::ON_SURFACE_MUTED,
            "(no networks found)",
            type_scale::BODY,
        );
    }
    for (i, (ssid, sig)) in rows.iter().take(P_MAX_ROWS).enumerate() {
        s.card(
            ROW_X,
            wifi_row_y(i),
            ROW_W - 160,
            P_ROW_H,
            ssid,
            &format!("signal {sig} dBm"),
        );
    }
    let ((bx, by, bw, bh), (cx, cy, cw, ch)) = p_footer_rects();
    if let Err(e) = s.button(bx, by, bw, bh, "Back", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: back button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: close button rejected: {e}"));
    }
    kmsg(&format!(
        "OXMILESTONE name=wifi-panel-shown networks={} status={status}",
        rows.len()
    ));
    let payload = s.ops_payload();
    cl.request("window-commit", json!({ "id": id, "ops": payload["ops"] }))?;
    Ok(())
}

fn draw_apps(cl: &mut Client, id: u64, apps: &[String]) -> std::io::Result<()> {
    let mut s = Screen::new(WIN_W, WIN_H);
    s.top_bar("Apps");
    if apps.is_empty() {
        s.label(
            ROW_X,
            P_ROWS_Y0 + 24,
            palette::ON_SURFACE_MUTED,
            "(no installed packages)",
            type_scale::BODY,
        );
    }
    for (i, app) in apps.iter().take(P_MAX_ROWS).enumerate() {
        s.card(ROW_X, p_row_y(i), ROW_W - 160, P_ROW_H, app, "tap to uninstall");
        s.label(
            ROW_W - 96,
            p_row_y(i) + (P_ROW_H - 24) / 2,
            palette::DANGER,
            "remove",
            type_scale::BODY,
        );
    }
    s.label(
        ROW_X,
        WIN_H - 60,
        palette::ON_SURFACE_MUTED,
        "tap a package to uninstall it (grants die with it)",
        type_scale::LABEL,
    );
    let ((bx, by, bw, bh), (cx, cy, cw, ch)) = p_footer_rects();
    if let Err(e) = s.button(bx, by, bw, bh, "Back", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: back button rejected: {e}"));
    }
    if let Err(e) = s.button(cx, cy, cw, ch, "Close", ButtonVariant::Filled) {
        kmsg(&format!("ox-settings: close button rejected: {e}"));
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
            eprintln!("ox-settings: no compositor at {} — exiting", sock.display());
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
    draw_settings(&mut cl, id, false)?;
    kmsg("OXMILESTONE name=settings-ready");
    // Foreground app ⇒ screen stays on: hold a wake lock from draw to
    // exit. Without it the idle-doze suspends the device mid-session;
    // released on Close below.
    let _ = std::process::Command::new("/usr/bin/oxctl")
        .args(["powerd", "wake-lock", "{\"id\":\"app-settings\"}"])
        .status();

    let mut airplane = false;
    let mut enroll: Option<Enroll> = None;
    let mut perms: Option<Vec<(String, String, String)>> = None;
    let mut apps: Option<Vec<String>> = None;
    let mut wifi: Option<(String, Vec<(String, i32)>)> = None;
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
        if let Some(entries) = perms.as_mut() {
            // Grants panel: footer Back/Close, rows toggle mode.
            match hit_p_footer(x, y) {
                Some(0) => {
                    kmsg("OXMILESTONE name=perms-back");
                    perms = None;
                    draw_settings(&mut cl, id, airplane)?;
                    continue;
                }
                Some(1) => {
                    let _ = std::process::Command::new("/usr/bin/oxctl")
                        .args([
                            "powerd",
                            "wake-lock",
                            "{\"id\":\"app-settings\",\"release\":true}",
                        ])
                        .status();
                    kmsg("OXMILESTONE name=settings-close");
                    break;
                }
                _ => {}
            }
            if let Some(i) = hit_p_row(y) {
                if let Some((app, perm, mode)) = entries.get(i).cloned() {
                    let next = if mode == "grant" { "deny" } else { "grant" };
                    match perm_set(&app, &perm, &next) {
                        Ok(()) => {
                            kmsg(&format!(
                                "OXMILESTONE name=perm-toggled app={app} permission={perm} mode={next}"
                            ));
                            *entries = perms_list();
                        }
                        Err(e) => kmsg(&format!("ox-settings: perm toggle refused: {e}")),
                    }
                }
                draw_perms(&mut cl, id, entries)?;
            }
            continue;
        }
        if let Some(list) = apps.as_mut() {
            match hit_p_footer(x, y) {
                Some(0) => {
                    kmsg("OXMILESTONE name=apps-back");
                    apps = None;
                    draw_settings(&mut cl, id, airplane)?;
                    continue;
                }
                Some(1) => {
                    let _ = std::process::Command::new("/usr/bin/oxctl")
                        .args([
                            "powerd",
                            "wake-lock",
                            "{\"id\":\"app-settings\",\"release\":true}",
                        ])
                        .status();
                    kmsg("OXMILESTONE name=settings-close");
                    break;
                }
                _ => {}
            }
            if let Some(i) = hit_p_row(y) {
                if let Some(app) = list.get(i).cloned() {
                    match app_remove(&app) {
                        Ok(()) => {
                            kmsg(&format!(
                                "OXMILESTONE name=app-removed app={app}"
                            ));
                            *list = installed_list();
                        }
                        Err(e) => kmsg(&format!(
                            "ox-settings: uninstall refused for {app}: {e}"
                        )),
                    }
                }
                draw_apps(&mut cl, id, list)?;
            }
            continue;
        }
        if let Some((status, rows)) = wifi.as_mut() {
            // Wi-Fi panel: footer Back/Close; rows are informational.
            match hit_p_footer(x, y) {
                Some(0) => {
                    kmsg("OXMILESTONE name=wifi-back");
                    wifi = None;
                    draw_settings(&mut cl, id, airplane)?;
                    continue;
                }
                Some(1) => {
                    let _ = std::process::Command::new("/usr/bin/oxctl")
                        .args([
                            "powerd",
                            "wake-lock",
                            "{\"id\":\"app-settings\",\"release\":true}",
                        ])
                        .status();
                    kmsg("OXMILESTONE name=settings-close");
                    break;
                }
                _ => {}
            }
            draw_wifi(&mut cl, id, status, rows)?;
            continue;
        }
        if let Some(e) = enroll.as_mut() {
            // Enrollment pad is up: keys, or the Close button.
            if hit_action(x, y) == Some(2) {
                let _ = std::process::Command::new("/usr/bin/oxctl")
                    .args([
                        "powerd",
                        "wake-lock",
                        "{\"id\":\"app-settings\",\"release\":true}",
                    ])
                    .status();
                kmsg("OXMILESTONE name=settings-close");
                break;
            }
            if let Some(key) = hit_pad(x, y) {
                match PAD_LABELS[key] {
                    "C" => e.typing.clear(),
                    "OK" => {
                        if e.typing.is_empty() {
                            continue;
                        }
                        match e.submit() {
                            Ok(true) => {
                                kmsg("OXMILESTONE name=settings-pin-changed");
                                enroll = None;
                            }
                            Ok(false) => {}
                            Err(()) => {
                                kmsg(&format!(
                                    "ox-settings: enroll step refused: {}",
                                    e.error.clone().unwrap_or_default()
                                ));
                                if e.stage == Stage::Current {
                                    kmsg("OXMILESTONE name=pin-enroll-refused");
                                }
                            }
                        }
                    }
                    digit if e.typing.len() < PIN_MAX_LEN => e.typing.push_str(digit),
                    _ => {}
                }
            }
            match &enroll {
                Some(e) => draw_enroll(&mut cl, id, e)?,
                None => draw_settings(&mut cl, id, airplane)?,
            }
            continue;
        }
        match hit_action(x, y) {
            Some(0) => {
                airplane = !airplane;
                kmsg(&format!(
                    "OXMILESTONE name=settings-toggle state={}",
                    if airplane { "on" } else { "off" }
                ));
                draw_settings(&mut cl, id, airplane)?;
            }
            Some(1) => {
                kmsg("OXMILESTONE name=settings-enroll-open");
                enroll = Some(Enroll::new());
                draw_enroll(&mut cl, id, enroll.as_ref().unwrap())?;
            }
            Some(3) => {
                kmsg("OXMILESTONE name=perms-open");
                let list = perms_list();
                draw_perms(&mut cl, id, &list)?;
                perms = Some(list);
            }
            Some(4) => {
                kmsg("OXMILESTONE name=apps-open");
                let list = installed_list();
                draw_apps(&mut cl, id, &list)?;
                apps = Some(list);
            }
            Some(5) => {
                kmsg("OXMILESTONE name=wifi-open");
                match wifi_fetch() {
                    Ok((status, rows)) => {
                        draw_wifi(&mut cl, id, &status, &rows)?;
                        wifi = Some((status, rows));
                    }
                    Err(e) => {
                        kmsg(&format!("ox-settings: wifi fetch failed: {e}"));
                        draw_wifi(&mut cl, id, &format!("unavailable: {e}"), &[])?;
                        wifi = Some((e, Vec::new()));
                    }
                }
            }
            Some(2) => {
                let _ = std::process::Command::new("/usr/bin/oxctl")
                    .args([
                        "powerd",
                        "wake-lock",
                        "{\"id\":\"app-settings\",\"release\":true}",
                    ])
                    .status();
                kmsg("OXMILESTONE name=settings-close");
                break;
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_buttons_stay_inside_the_window_above_touch_target() {
        let ((ax, ay, aw, ah), (cx, cy, cw, ch), (px, py, pw, ph), (abx, aby, abw, abh), (fx, fy, fw, fh)) =
            action_rects();
        for (x, y, w, h) in [
            (ax, ay, aw, ah),
            (cx, cy, cw, ch),
            (px, py, pw, ph),
            (abx, aby, abw, abh),
            (fx, fy, fw, fh),
        ] {
            assert!(w >= 48 && h >= 48, "button below touch target");
            assert!(x + w <= WIN_W && y + h <= WIN_H);
        }
    }

    #[test]
    fn pad_buttons_stay_inside_the_window() {
        for (x, y, w, h) in pad_rects() {
            assert!(w >= 48 && h >= 48);
            assert!(x + w <= WIN_W && y + h <= WIN_H);
        }
        assert_eq!(PAD_LABELS[11], "OK");
    }

    #[test]
    fn close_button_never_overlaps_the_action_row() {
        let ((_, ay, _, ah), _, _, _, (_, cy, _, _)) = action_rects();
        assert!(cy >= ay + ah, "close button collides with action row");
    }

    #[test]
    fn p_footer_and_rows_stay_inside_the_window() {
        let ((bx, by, bw, bh), (cx, cy, cw, ch)) = p_footer_rects();
        for (x, y, w, h) in [(bx, by, bw, bh), (cx, cy, cw, ch)] {
            assert!(w >= 48 && h >= 48);
            assert!(x + w <= WIN_W && y + h <= WIN_H);
        }
        // the last row must end above the footer TOP (y), not x
        assert!(p_row_y(P_MAX_ROWS - 1) + P_ROW_H <= by.min(cy));
        assert_eq!(hit_p_footer(1, 1), None);
        assert_eq!(hit_p_row(1), None);
        assert_eq!(hit_p_row(p_row_y(0) + 5), Some(0));
    }

    #[test]
    fn hit_action_resolves_all_four_buttons_only() {
        let ((ax, ay, _, _), (cx, cy, _, _), (px, py, _, _), (abx, aby, _, _), (fx, fy, _, _)) =
            action_rects();
        assert_eq!(hit_action(ax + 5, ay + 5), Some(0));
        assert_eq!(hit_action(cx + 5, cy + 5), Some(1));
        assert_eq!(hit_action(px + 5, py + 5), Some(3));
        assert_eq!(hit_action(abx + 5, aby + 5), Some(4));
        assert_eq!(hit_action(fx + 5, fy + 5), Some(2));
        assert_eq!(hit_action(1, 1), None);
    }

    #[test]
    fn hit_pad_resolves_keys() {
        let (x, y, _, _) = pad_rects()[0];
        assert_eq!(hit_pad(x + 5, y + 5), Some(0));
        let (ox, oy, _, _) = pad_rects()[11];
        assert_eq!(hit_pad(ox + 5, oy + 5), Some(11));
        assert_eq!(hit_pad(0, 0), None);
    }

    #[test]
    fn enroll_flow_stages_advance_and_mismatch_bounces() {
        let mut e = Enroll::new();
        assert_eq!(e.stage_label(), "Change PIN — enter current PIN");
        e.typing.push_str("1234");
        assert!(matches!(e.submit(), Ok(false)));
        assert_eq!(e.stage_label(), "Change PIN — enter new PIN (4-8 digits)");
        e.typing.push_str("5678");
        assert!(matches!(e.submit(), Ok(false)));
        e.typing.push_str("9999");
        // mismatch: stage bounces back to New with an error (no lockd
        // call happens — the confirm comparison runs first)
        assert!(e.submit().is_err());
        assert_eq!(e.stage_label(), "Change PIN — enter new PIN (4-8 digits)");
        assert!(e.error.is_some());
        assert!(e.typing.is_empty());
    }
}
