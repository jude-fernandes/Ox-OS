//! ox-ui: the Ox UI toolkit foundation (Phase 3). Encodes the design
//! language (docs/design/design-language.md) as a token layer and
//! compiles a component tree into oxcom draw ops (`rect` / `text`
//! JSON payloads) — the same protocol the compositor already
//! rasterizes with damage-tracked repaints.
//!
//! v0.1 geometry is flat (rects + text): rounded corners arrive when
//! oxcom grows a `rrect` op. What v0.1 certifies is the architecture:
//! tokens in, deterministic ops out, touch targets enforced, layout
//! testable without a display.
use serde_json::{json, Value};

/// Palette roles (dark theme, true-black OLED default). Reference
/// values curated from the design language; tonal-ramp generation
/// from a user seed is a later token feature.
pub mod palette {
    pub const SURFACE: u32 = 0x000000; // true black (OLED)
    pub const SURFACE_HIGH: u32 = 0x0C1B33; // Ox navy
    pub const PRIMARY: u32 = 0x2E7D32; // Ox green
    /// Primary-tinted TEXT for dark surfaces: the plain PRIMARY green
    /// is 4.1:1 on true black — below WCAG AA (4.5:1) — so text that
    /// sits on the surface uses this brighter tone (10.4:1) while
    /// fills keep the brand green (white-on-PRIMARY stays 5.1:1).
    pub const PRIMARY_TEXT: u32 = 0x81C784;
    pub const ON_PRIMARY: u32 = 0xFFFFFF;
    pub const ON_SURFACE: u32 = 0xFFFFFF;
    pub const ON_SURFACE_MUTED: u32 = 0x9FD49F;
    pub const OUTLINE: u32 = 0x1E3A5F;
    pub const DANGER: u32 = 0xB3261E;
}

/// WCAG 2.1 minimum contrast ratios: normal text (below ~18 pt) vs
/// large text.
pub const MIN_CONTRAST_NORMAL: f64 = 4.5;
pub const MIN_CONTRAST_LARGE: f64 = 3.0;

/// WCAG 2.1 relative luminance of an 0xRRGGBB color token.
pub fn rel_luminance(rgb: u32) -> f64 {
    let lin = |v: u32| {
        let s = v as f64 / 255.0;
        if s <= 0.03928 {
            s / 12.92
        } else {
            ((s + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * lin((rgb >> 16) & 0xFF) + 0.7152 * lin((rgb >> 8) & 0xFF) + 0.0722 * lin(rgb & 0xFF)
}

/// WCAG contrast ratio between two color tokens (1.0 ..= 21.0).
pub fn contrast(a: u32, b: u32) -> f64 {
    let (la, lb) = (rel_luminance(a), rel_luminance(b));
    let (hi, lo) = if la >= lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

/// 4 dp spacing grid (design language §2).
pub const SP: [u64; 7] = [0, 4, 8, 12, 16, 24, 32];

/// Type scale: oxcom glyph height is 8 px × scale.
pub mod type_scale {
    pub const DISPLAY: u64 = 5;
    pub const TITLE: u64 = 3;
    pub const BODY: u64 = 2;
    pub const LABEL: u64 = 1;
}

/// Minimum touch target in px (48 dp on the 4 dp grid).
pub const TOUCH_TARGET: u64 = 48;

#[derive(Clone, Copy, PartialEq)]
pub enum ButtonVariant {
    Filled,
    Outline,
    Danger,
}

/// A screen under construction; compiles to an oxcom `ops` payload.
pub struct Screen {
    w: u64,
    h: u64,
    ops: Vec<Value>,
}

impl Screen {
    /// New screen with a full-bleed surface.
    pub fn new(w: u64, h: u64) -> Self {
        Screen {
            w,
            h,
            ops: vec![json!({"t": "rect", "x": 0, "y": 0, "w": w, "h": h,
                             "rgb": palette::SURFACE})],
        }
    }

    pub fn w(&self) -> u64 {
        self.w
    }

    pub fn h(&self) -> u64 {
        self.h
    }

    fn push_rect(&mut self, x: u64, y: u64, w: u64, h: u64, rgb: u32) {
        self.ops.push(json!({"t": "rect", "x": x, "y": y, "w": w, "h": h, "rgb": rgb}));
    }

    fn push_text(&mut self, x: u64, y: u64, rgb: u32, s: &str, scale: u64) {
        self.ops.push(json!({"t": "text", "x": x, "y": y, "rgb": rgb, "s": s, "scale": scale}));
    }

    /// Raw RGB24 pixel block (the viewfinder primitive): each source
    /// pixel is drawn as scale×scale. The payload is base64-encoded
    /// RGB24 rows, top-left origin, matching the compositor's
    /// `pixels` op.
    pub fn pixels(&mut self, x: u64, y: u64, w: u64, h: u64, scale: u64, rgb24: &[u8]) {
        self.pixels_b64(x, y, w, h, scale, &b64_encode(rgb24));
    }

    /// Same as `pixels` with an already-encoded base64 payload (frames
    /// arrive base64 over IPC and need not be decoded re-encoded).
    pub fn pixels_b64(&mut self, x: u64, y: u64, w: u64, h: u64, scale: u64, data: &str) {
        self.ops.push(json!({
            "t": "pixels", "x": x, "y": y, "w": w, "h": h, "scale": scale,
            "data": data,
        }));
    }

    /// Public raw rectangle (app-level chrome the toolkit has no
    /// component for: badges, viewfinder backdrops).
    pub fn rect(&mut self, x: u64, y: u64, w: u64, h: u64, rgb: u32) {
        self.push_rect(x, y, w, h, rgb);
    }

    /// Top app bar: surface-high band, primary accent line, title.
    pub fn top_bar(&mut self, title: &str) {
        let bar_h = (self.h * 15 / 100).max(96);
        self.push_rect(0, 0, self.w, bar_h, palette::SURFACE_HIGH);
        self.push_rect(0, bar_h, self.w, 6, palette::PRIMARY);
        let big = (bar_h / 24).max(2);
        self.push_text(SP[5], SP[4], palette::ON_SURFACE, title, big);
    }

    /// Card: surface-high panel with a primary accent line and text.
    pub fn card(&mut self, x: u64, y: u64, w: u64, h: u64, title: &str, subtitle: &str) {
        self.push_rect(x, y, w, h, palette::SURFACE_HIGH);
        self.push_rect(x, y, w, 3, palette::PRIMARY);
        self.push_text(x + SP[3], y + SP[2], palette::ON_SURFACE, title, type_scale::BODY);
        self.push_text(
            x + SP[3],
            y + SP[2] + 8 * type_scale::BODY + SP[2],
            palette::ON_SURFACE_MUTED,
            subtitle,
            type_scale::LABEL,
        );
    }

    /// Button. Refuses anything below the 48 dp touch target in EITHER
    /// dimension — the design language bakes touch targets into the
    /// component, so the toolkit enforces them at compile time.
    pub fn button(
        &mut self,
        x: u64,
        y: u64,
        w: u64,
        h: u64,
        label: &str,
        variant: ButtonVariant,
    ) -> Result<(), String> {
        if w < TOUCH_TARGET || h < TOUCH_TARGET {
            return Err(format!(
                "button '{label}' {w}x{h}px is below the {TOUCH_TARGET}px touch target"
            ));
        }
        match variant {
            ButtonVariant::Filled => {
                self.push_rect(x, y, w, h, palette::PRIMARY);
                self.push_text(x + SP[3], y + h / 2 - 8, palette::ON_PRIMARY, label, type_scale::BODY);
            }
            ButtonVariant::Danger => {
                self.push_rect(x, y, w, h, palette::DANGER);
                self.push_text(x + SP[3], y + h / 2 - 8, palette::ON_PRIMARY, label, type_scale::BODY);
            }
            ButtonVariant::Outline => {
                // 2px border via four thin rects (flat v0.1 geometry)
                self.push_rect(x, y, w, 2, palette::PRIMARY);
                self.push_rect(x, y + h - 2, w, 2, palette::PRIMARY);
                self.push_rect(x, y, 2, h, palette::PRIMARY);
                self.push_rect(x + w - 2, y, 2, h, palette::PRIMARY);
                // label text sits on the SURFACE behind the border, so
                // it needs the bright primary (plain PRIMARY is 4.1:1
                // on true black — below WCAG AA)
                self.push_text(x + SP[3], y + h / 2 - 8, palette::PRIMARY_TEXT, label, type_scale::BODY);
            }
        }
        Ok(())
    }

    /// App tile for the home grid: filled square with the app label.
    pub fn tile(&mut self, x: u64, y: u64, w: u64, h: u64, label: &str) {
        self.push_rect(x, y, w, h, palette::SURFACE_HIGH);
        self.push_rect(x, y, w, 2, palette::PRIMARY);
        self.push_text(x + SP[3], y + h / 2 - 8, palette::ON_SURFACE, label, type_scale::BODY);
    }

    /// Free-form label (body scale by default).
    pub fn label(&mut self, x: u64, y: u64, rgb: u32, s: &str, scale: u64) {
        self.push_text(x, y, rgb, s, scale);
    }

    /// The oxcom payload: `{"ops": [...]}`.
    pub fn ops_payload(&self) -> Value {
        json!({ "ops": self.ops })
    }

    pub fn op_count(&self) -> usize {
        self.ops.len()
    }

    /// Accessibility audit: for EVERY text op, find the rect painted
    /// immediately beneath it (the last opaque rect containing its
    /// anchor) and require the WCAG contrast ratio to hold — 4.5:1 for
    /// normal text (BODY/LABEL scales), 3.0:1 for large (TITLE/DISPLAY).
    /// Returns the first violation, or Ok. Text drawn with NO backdrop
    /// rect is audited against SURFACE (the screen base).
    pub fn audit_contrast(&self) -> Result<(), String> {
        let rects: Vec<(i64, i64, i64, i64, u32)> = self
            .ops
            .iter()
            .filter_map(|op| {
                let t = op["t"].as_str()?;
                if t != "rect" {
                    return None;
                }
                Some((
                    op["x"].as_i64()?,
                    op["y"].as_i64()?,
                    op["w"].as_i64()?,
                    op["h"].as_i64()?,
                    op["rgb"].as_u64()? as u32,
                ))
            })
            .collect();
        for op in &self.ops {
            if op["t"].as_str() != Some("text") {
                continue;
            }
            let x = op["x"].as_i64().unwrap_or(0);
            let y = op["y"].as_i64().unwrap_or(0);
            let scale = op["scale"].as_u64().unwrap_or(1);
            let rgb = op["rgb"].as_u64().unwrap_or(0) as u32;
            let s = op["s"].as_str().unwrap_or("");
            // probe a point inside the first glyph, below its top edge
            let (px, py) = (x + 2, y + 4 * scale as i64);
            let backdrop = rects
                .iter()
                .rev()
                .find(|&&(rx, ry, rw, rh, _)| {
                    // thin accent lines (h <= 6) are decoration, not
                    // backdrops; the panel behind them is
                    rh > 6 && px >= rx && px < rx + rw && py >= ry && py < ry + rh
                })
                .map(|&(_, _, _, _, c)| c)
                .unwrap_or(palette::SURFACE);
            let ratio = contrast(rgb, backdrop);
            let min = if scale >= type_scale::TITLE {
                MIN_CONTRAST_LARGE
            } else {
                MIN_CONTRAST_NORMAL
            };
            if ratio < min {
                return Err(format!(
                    "text {:?} ({rgb:06X}) on backdrop {backdrop:06X}: contrast {ratio:.2} < {min} (WCAG AA)",
                    s.chars().take(24).collect::<String>()
                ));
            }
        }
        Ok(())
    }
}

/// Standard-alphabet base64 encode (with padding).
pub fn b64_encode(data: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(A[(n >> 18) as usize & 63] as char);
        out.push(A[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { A[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { A[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen() -> Screen {
        let mut s = Screen::new(1280, 800);
        s.top_bar("Ox OS");
        s
    }

    #[test]
    fn surface_covers_full_screen() {
        let s = screen();
        let binding = s.ops_payload();
        let ops = binding["ops"].as_array().unwrap();
        assert_eq!(ops[0]["t"], "rect");
        assert_eq!(ops[0]["w"], 1280);
        assert_eq!(ops[0]["h"], 800);
        assert_eq!(ops[0]["rgb"], 0);
    }

    #[test]
    fn top_bar_matches_compositor_idiom() {
        let s = screen();
        let binding = s.ops_payload();
        let ops = binding["ops"].as_array().unwrap();
        // surface, bar, accent, title
        assert_eq!(ops.len(), 4);
        assert_eq!(ops[1]["h"], 120); // 15% of 800
        assert_eq!(ops[2]["rgb"], palette::PRIMARY);
        assert_eq!(ops[3]["s"], "Ox OS");
    }

    #[test]
    fn buttons_enforce_touch_target() {
        let mut s = screen();
        assert!(s.button(0, 0, 200, 48, "Ok", ButtonVariant::Filled).is_ok());
        assert!(s.button(0, 0, 200, 40, "Ok", ButtonVariant::Filled)
            .err()
            .unwrap()
            .contains("touch target"));
    }

    #[test]
    fn outline_button_draws_border_rects() {
        let mut s = Screen::new(400, 300);
        s.button(10, 10, 120, 48, "Cancel", ButtonVariant::Outline).unwrap();
        let binding = s.ops_payload();
        let ops = binding["ops"].as_array().unwrap();
        // surface + 4 border rects + label
        assert_eq!(ops.len(), 6);
        assert_eq!(ops[1]["h"], 2);
        assert_eq!(ops[4]["w"], 2);
    }

    #[test]
    fn card_text_sits_inside_panel() {
        let mut s = screen();
        s.card(900, 12, 248, 64, "Ox OS 0.1", "windows + input live");
        let binding = s.ops_payload();
        let ops = binding["ops"].as_array().unwrap();
        let title_y = ops[3]["y"].as_u64().unwrap();
        assert!(title_y > 12 && title_y < 12 + 64); // inside the card
        assert_eq!(ops[1]["rgb"], palette::SURFACE_HIGH);
    }

    // ---------- accessibility (chunk 29) ----------

    #[test]
    fn contrast_math_matches_known_values() {
        // black vs white is the maximum ratio
        let ratio = contrast(palette::SURFACE, palette::ON_SURFACE);
        assert!((ratio - 21.0).abs() < 0.1, "black/white must be ~21:1, got {ratio}");
        // a color against itself is the minimum
        assert!((contrast(palette::PRIMARY, palette::PRIMARY) - 1.0).abs() < 0.001);
        // ratio is symmetric
        assert!((contrast(palette::PRIMARY, palette::SURFACE)
            - contrast(palette::SURFACE, palette::PRIMARY))
        .abs()
            < 1e-9);
    }

    #[test]
    fn filled_and_danger_buttons_meet_wcaa() {
        // white labels on the brand green / danger red
        assert!(contrast(palette::ON_PRIMARY, palette::PRIMARY) >= MIN_CONTRAST_NORMAL);
        assert!(contrast(palette::ON_PRIMARY, palette::DANGER) >= MIN_CONTRAST_NORMAL);
    }

    #[test]
    fn plain_primary_as_text_on_black_fails_aa() {
        // the finding that motivated PRIMARY_TEXT: the old outline
        // label color is below 4.5:1 on the surface — keep it that way
        // so a regression can never reintroduce it silently
        assert!(contrast(palette::PRIMARY, palette::SURFACE) < MIN_CONTRAST_NORMAL);
        // ...and the bright replacement clears AA comfortably
        assert!(contrast(palette::PRIMARY_TEXT, palette::SURFACE) >= MIN_CONTRAST_NORMAL);
        assert!(contrast(palette::PRIMARY_TEXT, palette::SURFACE_HIGH) >= MIN_CONTRAST_NORMAL);
    }

    #[test]
    fn every_text_on_a_representative_screen_passes_aa() {
        // a screen that exercises every component and every backdrop
        let mut s = Screen::new(1280, 800);
        s.top_bar("Ox Shell");
        s.tile(48, 135, 220, 120, "Settings");
        s.card(48, 279, 952, 120, "Welcome to Ox", "your activity lives here");
        s.button(48, 628, 150, 48, "Lock", ButtonVariant::Filled).unwrap();
        s.button(222, 628, 150, 48, "Recents", ButtonVariant::Filled).unwrap();
        s.button(396, 628, 150, 48, "Clear", ButtonVariant::Outline).unwrap();
        s.button(570, 628, 150, 48, "Wipe", ButtonVariant::Danger).unwrap();
        s.label(48, 500, palette::ON_SURFACE_MUTED, "muted hint text", type_scale::BODY);
        s.audit_contrast().unwrap_or_else(|e| panic!("{e}"));
    }

    #[test]
    fn thin_accent_lines_do_not_swallow_backdrop_audit() {
        // the 2-6px accent strips are decoration: the auditor must see
        // the PANEL behind the text, not the strip
        let mut s = Screen::new(400, 300);
        s.button(10, 10, 120, 48, "Go", ButtonVariant::Outline).unwrap();
        // must pass now that the outline label uses PRIMARY_TEXT; with
        // the old PRIMARY label this audit fails
        s.audit_contrast().unwrap_or_else(|e| panic!("{e}"));
    }

    #[test]
    fn buttons_enforce_width_and_height_targets() {
        let mut s = screen();
        assert!(s.button(0, 0, 48, 48, "Ok", ButtonVariant::Filled).is_ok());
        assert!(s.button(0, 0, 40, 48, "Ok", ButtonVariant::Filled)
            .err()
            .unwrap()
            .contains("touch target"), "narrow button must be refused");
        assert!(s.button(0, 0, 200, 40, "Ok", ButtonVariant::Filled)
            .err()
            .unwrap()
            .contains("touch target"));
    }

    #[test]
    fn pixels_op_is_wellformed_base64() {
        let mut s = screen();
        s.pixels(8, 16, 4, 2, 3, &[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
        let ops = s.ops_payload();
        let ops = ops.get("ops").and_then(|o| o.as_array()).unwrap();
        let px = ops
            .iter()
            .find(|o| o["t"] == serde_json::json!("pixels"))
            .expect("pixels op missing");
        assert_eq!(px["w"], 4);
        assert_eq!(px["scale"], 3);
        assert_eq!(px["data"], serde_json::json!("AAECAwQFBgcICQoL"));
    }
}
