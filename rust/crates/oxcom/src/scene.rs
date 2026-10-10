// Consumed by the gui-feature-gated paths (and tests); dead without
// the feature, hence the module-level allow.
#![allow(dead_code)]

//! Compositor scene state: the full-screen paint layer plus a list of
//! client windows, composited in order over the background gradient.

use crate::screen::{self, apply, Op, Region};

pub use crate::screen::parse_ops;
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct Window {
    pub id: u32,
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub ops: Vec<Op>,
    /// Secure-tier member (the lockscreen shield): always composites and
    /// takes clicks ABOVE every non-secure window, whatever raises land.
    pub secure: bool,
}

/// Full compositor scene. Windows stack in creation order (later = on top);
/// the full-screen paint layer sits beneath all windows. Interim trust
/// model: any client may touch any window id — per-client ownership lands
/// with the Phase-5 security work.
/// What a mutation changed: the whole frame, or a list of rects that need
/// repainting (screen coordinates).
#[derive(Debug, Clone)]
pub enum Dirty {
    Full,
    Regions(Vec<Region>),
}

impl Dirty {
    /// Resolve to one bounding region given the screen size.
    pub fn resolve(&self, w: u32, h: u32) -> Region {
        match self {
            Dirty::Full => Region::full(w, h),
            // union identity: x0/y0 = max, x1/y1 = 0 (an empty region)
            Dirty::Regions(rs) => rs.iter().fold(
                Region { x0: u32::MAX, y0: u32::MAX, x1: 0, y1: 0 },
                |acc, r| acc.union(r),
            ),
        }
    }

    /// Combine two dirty sets (batched events repaint once).
    pub fn merge_regions(self, other: Dirty) -> Dirty {
        match (self, other) {
            (Dirty::Full, _) | (_, Dirty::Full) => Dirty::Full,
            (Dirty::Regions(mut a), Dirty::Regions(b)) => {
                a.extend(b);
                Dirty::Regions(a)
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct CompositorScene {
    fullscreen: Vec<Op>,
    windows: Vec<Window>,
    next_id: u32,
    /// Absolute pointer position in screen pixels (None = never moved).
    cursor: Option<(u32, u32)>,
    /// Focused window id (click-to-focus); keys routing policy lands later.
    focused: Option<u32>,
}

impl Default for CompositorScene {
    fn default() -> Self {
        Self::new()
    }
}

impl CompositorScene {
    pub fn new() -> Self {
        CompositorScene {
            fullscreen: Vec::new(),
            windows: Vec::new(),
            next_id: 1,
            cursor: None,
            focused: None,
        }
    }

    /// Replace the full-screen paint layer (last-write-wins semantics).
    pub fn set_fullscreen(&mut self, ops: Vec<Op>) {
        self.fullscreen = ops;
    }

    /// Returns the new window's id. Focus policy: creation NEVER steals
    /// focus (a background daemon's surface must not interrupt typing);
    /// focus moves only via explicit `window-focus` or click-to-raise.
    /// New windows enter at the top of the NORMAL tier — directly below
    /// any secure window — so an app launched while the lockscreen
    /// shield is up can never land above it (the chunk-58 rollout catch).
    pub fn window_new(&mut self, x: u32, y: u32, w: u32, h: u32) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        let at = self
            .windows
            .iter()
            .position(|win| win.secure)
            .unwrap_or(self.windows.len());
        self.windows
            .insert(at, Window { id, x, y, w, h, ops: Vec::new(), secure: false });
        id
    }

    /// Move `id` into (or out of) the secure tier. Returns false for an
    /// unknown id. Order-preserving within each tier.
    pub fn window_set_secure(&mut self, id: u32, secure: bool) -> bool {
        let Some(win) = self.windows.iter_mut().find(|win| win.id == id) else {
            return false;
        };
        win.secure = secure;
        let mut normal = Vec::new();
        let mut secured = Vec::new();
        for w in self.windows.drain(..) {
            if w.secure {
                secured.push(w)
            } else {
                normal.push(w)
            }
        }
        normal.extend(secured);
        self.windows = normal;
        true
    }

    pub fn window_is_secure(&self, id: u32) -> bool {
        self.windows.iter().any(|win| win.id == id && win.secure)
    }

    /// Dirty regions for a successful commit (the window's rect).
    pub fn window_rect_dirty(&self, id: u32) -> Option<Dirty> {
        self.windows
            .iter()
            .find(|win| win.id == id)
            .map(|win| Dirty::Regions(vec![Region::rect(win.x, win.y, win.w, win.h)]))
    }

    /// Dirty regions when `id` gains focus: old + new focus rings.
    pub fn focus_change_dirty(&self, old: Option<u32>, new: u32) -> Dirty {
        let mut rs = Vec::new();
        for id in [old, Some(new)].into_iter().flatten() {
            if let Some(win) = self.windows.iter().find(|win| win.id == id) {
                rs.push(Region::rect(win.x, win.y, win.w, win.h));
            }
        }
        Dirty::Regions(rs)
    }

    /// Dirty regions for closing a window: its rect + old focus ring.
    pub fn window_close_dirty(&self, id: u32) -> Dirty {
        let mut rs = Vec::new();
        if let Some(win) = self.windows.iter().find(|win| win.id == id) {
            rs.push(Region::rect(win.x, win.y, win.w, win.h));
        }
        if self.focused == Some(id) {
            if let Some(win) = self.windows.iter().find(|win| win.id == id) {
                rs.push(Region::rect(win.x, win.y, win.w, win.h));
            }
        }
        Dirty::Regions(rs)
    }

    /// Dirty for a cursor move: old + new sprite boxes. The first move
    /// (from "no cursor") reports just the new sprite.
    pub fn cursor_move_dirty(&mut self, x: u32, y: u32) -> Option<Dirty> {
        let dirty = match self.cursor {
            Some(old) if old == (x, y) => return None,
            Some(old) => Dirty::Regions(vec![
                Region::rect(old.0, old.1, 16, 16),
                Region::rect(x, y, 16, 16),
            ]),
            None => Dirty::Regions(vec![Region::rect(x, y, 16, 16)]),
        };
        self.cursor = Some((x, y));
        Some(dirty)
    }

    pub fn window_commit(&mut self, id: u32, ops: Vec<Op>) -> bool {
        match self.windows.iter_mut().find(|win| win.id == id) {
            Some(win) => {
                win.ops = ops;
                true
            }
            None => false,
        }
    }

    pub fn window_close(&mut self, id: u32) -> bool {
        let before = self.windows.len();
        self.windows.retain(|win| win.id != id);
        self.windows.len() != before
    }

    /// Raise `id` to the top of ITS tier and focus it: a secure window
    /// goes above everything; a normal one stops below any secure
    /// window. Returns false if the id is unknown.
    pub fn window_raise(&mut self, id: u32, x: u32, y: u32) -> bool {
        let Some(pos) = self.windows.iter().position(|win| win.id == id) else {
            return false;
        };
        let win = self.windows.remove(pos);
        if win.secure {
            self.windows.push(win);
        } else {
            let at = self
                .windows
                .iter()
                .position(|w| w.secure)
                .unwrap_or(self.windows.len());
            self.windows.insert(at, win);
        }
        self.focused = Some(id);
        self.cursor = Some((x, y));
        true
    }

    /// Move the absolute pointer (no repaint-worthy change if unchanged).
    pub fn pointer_move(&mut self, x: u32, y: u32) -> bool {
        let moved = self.cursor != Some((x, y));
        self.cursor = Some((x, y));
        moved
    }

    /// Topmost window under the pointer position, if any. The secure
    /// tier invariant (secure windows sort last = topmost) makes this
    /// return the shield whenever it covers the point.
    pub fn hit_test(&self, x: u32, y: u32) -> Option<u32> {
        self.windows
            .iter()
            .rev()
            .find(|win| x >= win.x && x < win.x + win.w && y >= win.y && y < win.y + win.h)
            .map(|win| win.id)
    }

    /// Every window under the point, topmost first. The click path uses
    /// this to journal a shielded redirect (a tap that WOULD have hit a
    /// covered window while the shield is up — the tapjacking evidence).
    pub fn hit_all(&self, x: u32, y: u32) -> Vec<u32> {
        self.windows
            .iter()
            .rev()
            .filter(|win| x >= win.x && x < win.x + win.w && y >= win.y && y < win.y + win.h)
            .map(|win| win.id)
            .collect()
    }

    /// Explicit focus request (focus-follows-click still overrides later).
    /// Returns false if the id is unknown.
    pub fn set_focus(&mut self, id: u32) -> bool {
        if self.windows.iter().any(|win| win.id == id) {
            self.focused = Some(id);
            true
        } else {
            false
        }
    }

    pub fn cursor(&self) -> Option<(u32, u32)> {
        self.cursor
    }

    pub fn focused(&self) -> Option<u32> {
        self.focused
    }

    pub fn windows(&self) -> &[Window] {
        &self.windows
    }

    pub fn fullscreen_ops(&self) -> &[Op] {
        &self.fullscreen
    }

    /// Composite everything, restricted to `region` (the damage region).
    /// The caller has already painted the background gradient there.
    pub fn render(&self, buf: &mut [u8], w: u32, h: u32, pitch: u32, region: Region) {
        if region.is_empty() {
            return;
        }
        apply(buf, w, h, pitch, 0, 0, region, &self.fullscreen);
        for win in &self.windows {
            let wr = Region::rect(win.x, win.y, win.w, win.h);
            let vis = wr.intersect(&region);
            if vis.is_empty() {
                continue;
            }
            // opaque window backing, then the client's own ops (clipped)
            apply(
                buf,
                w,
                h,
                pitch,
                win.x,
                win.y,
                vis,
                &[Op::Rect { x: 0, y: 0, w: win.w, h: win.h, rgb: 0x101418 }],
            );
            apply(buf, w, h, pitch, win.x, win.y, vis, &win.ops);
        }
        // focus ring on the focused window
        if let Some(id) = self.focused {
            if let Some(win) = self.windows.iter().find(|win| win.id == id) {
                let wr = Region::rect(win.x, win.y, win.w, win.h).intersect(&region);
                if !wr.is_empty() {
                    apply(
                        buf,
                        w,
                        h,
                        pitch,
                        win.x,
                        win.y,
                        wr,
                        &border_ops(win.w, win.h, 0x2E7D32, 3),
                    );
                }
            }
        }
        // pointer cursor sprite, always topmost
        if let Some((cx, cy)) = self.cursor {
            let sr = Region::rect(cx, cy, 16, 16).intersect(&region);
            if sr.is_empty() {
                return;
            }
            apply(
                buf,
                w,
                h,
                pitch,
                cx,
                cy,
                sr,
                &[
                    Op::Rect { x: 0, y: 0, w: 16, h: 16, rgb: 0x000000 },
                    Op::Rect { x: 2, y: 2, w: 12, h: 12, rgb: 0xFFFFFF },
                    Op::Rect { x: 6, y: 2, w: 4, h: 12, rgb: 0x000000 },
                    Op::Rect { x: 2, y: 6, w: 12, h: 4, rgb: 0x000000 },
                ],
            );
        }
    }
}

/// Rect ops forming a border of `t` px just inside a w×h surface.
fn border_ops(w: u32, h: u32, rgb: u32, t: u32) -> Vec<Op> {
    let (w, h) = (w as i64, h as i64);
    let t = t as i64;
    let r = |x: i64, y: i64, rw: i64, rh: i64| Op::Rect {
        x: x.max(0) as u32,
        y: y.max(0) as u32,
        w: rw.max(0) as u32,
        h: rh.max(0) as u32,
        rgb,
    };
    vec![
        r(0, 0, w, t),
        r(0, h - t, w, t),
        r(0, 0, t, h),
        r(w - t, 0, t, h),
    ]
}

/// Parse `window-new` payload `{"x":..,"y":..,"w":..,"h":..}`.
pub fn parse_window_new(payload: &Value) -> Result<(u32, u32, u32, u32), String> {
    let get = |k: &str| -> Result<u32, String> {
        payload
            .get(k)
            .and_then(|v| v.as_u64())
            .map(|v| v as u32)
            .ok_or_else(|| format!("{}: missing/invalid", k))
    };
    let (x, y, w, h) = (get("x")?, get("y")?, get("w")?, get("h")?);
    if w == 0 || h == 0 {
        return Err("window must have nonzero size".into());
    }
    Ok((x, y, w, h))
}

/// Parse `window-commit` payload `{"id":..,"ops":[..]}`.
pub fn parse_window_commit(payload: &Value) -> Result<(u32, Vec<Op>), String> {
    let id = payload
        .get("id")
        .and_then(|v| v.as_u64())
        .ok_or("id: missing/invalid")? as u32;
    let ops = screen::parse_ops(payload)?;
    Ok((id, ops))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buf(w: u32, h: u32) -> (Vec<u8>, u32) {
        (vec![0u8; (w * h * 4) as usize], w * 4)
    }

    fn px(b: &[u8], pitch: u32, x: u32, y: u32) -> [u8; 4] {
        let o = (y * pitch + x * 4) as usize;
        [b[o], b[o + 1], b[o + 2], b[o + 3]]
    }

    #[test]
    fn window_lifecycle_and_z_order() {
        let mut sc = CompositorScene::new();
        let a = sc.window_new(0, 0, 10, 10);
        let b = sc.window_new(4, 0, 10, 10);
        assert_eq!((a, b), (1, 2));
        assert!(sc.window_commit(a, vec![Op::Rect { x: 0, y: 0, w: 10, h: 10, rgb: 0xFF0000 }]));
        assert!(sc.window_commit(b, vec![Op::Rect { x: 0, y: 0, w: 10, h: 10, rgb: 0x00FF00 }]));
        // later window paints over the earlier one in the overlap
        let (mut buf, pitch) = buf(20, 10);
        sc.render(&mut buf, 20, 10, pitch, crate::screen::Region::full(20, 10));
        // nothing focused yet -> pure fills, no ring
        assert_eq!(px(&buf, pitch, 2, 5)[2], 0xFF); // red under
        assert_eq!(px(&buf, pitch, 6, 5)[1], 0xFF); // green over
        // explicit focus draws the ring on b (local x<3 band)
        assert!(sc.set_focus(b));
        let mut buf2 = vec![0u8; 20 * 10 * 4];
        sc.render(&mut buf2, 20, 10, pitch, crate::screen::Region::full(20, 10));
        assert_eq!(px(&buf2, pitch, 5, 5), [0x32, 0x7D, 0x2E, 0x00]); // ring
        assert_eq!(px(&buf2, pitch, 8, 5)[1], 0xFF); // fill past the ring
        assert!(sc.window_close(a));
        assert!(!sc.window_close(a));
        assert_eq!(sc.windows().len(), 1);
    }

    #[test]
    fn window_ops_cannot_leak_outside_window() {
        let mut sc = CompositorScene::new();
        let id = sc.window_new(0, 0, 8, 8);
        // rect runs 20px wide but the window is only 8 wide
        assert!(sc.window_commit(id, vec![
            Op::Rect { x: 0, y: 0, w: 20, h: 8, rgb: 0xFFFFFF },
            Op::Text { x: 0, y: 0, rgb: 0xFFFFFF, s: "XXXXXXXXXXXXXXXX".to_string(), scale: 2 },
        ]));
        let (mut buf, pitch) = buf(40, 8);
        sc.render(&mut buf, 40, 8, pitch, crate::screen::Region::full(40, 8));
        // unfocused: plain fill; ops cannot leak past the window rect
        assert_eq!(px(&buf, pitch, 4, 4), [0xFF, 0xFF, 0xFF, 0x00]);
        assert_eq!(px(&buf, pitch, 7, 4), [0xFF, 0xFF, 0xFF, 0x00]);
        assert_eq!(px(&buf, pitch, 9, 4), [0, 0, 0, 0]);
        assert_eq!(px(&buf, pitch, 39, 4), [0, 0, 0, 0]);
        // focusing adds the ring, still clipped to the window
        assert!(sc.set_focus(1));
        sc.render(&mut buf, 40, 8, pitch, crate::screen::Region::full(40, 8));
        assert_eq!(px(&buf, pitch, 7, 4), [0x32, 0x7D, 0x2E, 0x00]); // ring
        assert_eq!(px(&buf, pitch, 9, 4), [0, 0, 0, 0]);
    }

    #[test]
    fn pointer_move_focus_and_raise() {
        let mut sc = CompositorScene::new();
        let a = sc.window_new(0, 0, 100, 100);
        let b = sc.window_new(50, 0, 100, 100);
        assert!(sc.pointer_move(60, 10));
        assert!(!sc.pointer_move(60, 10), "no change -> no repaint");
        // hit-test prefers the topmost (later) window
        assert_eq!(sc.hit_test(60, 10), Some(b));
        assert_eq!(sc.hit_test(10, 10), Some(a));
        assert_eq!(sc.hit_test(500, 500), None);
        // raise b -> focused, moved to top
        assert!(sc.window_raise(b, 60, 10));
        assert_eq!(sc.focused(), Some(b));
        assert_eq!(sc.windows().last().unwrap().id, b);
        // unknown id refused, cursor unchanged
        assert!(!sc.window_raise(99, 60, 10));
        assert_eq!(sc.cursor(), Some((60, 10)));
    }

    #[test]
    fn shield_tier_blocks_raise_and_new_windows() {
        let mut sc = CompositorScene::new();
        let pad = sc.window_new(0, 0, 100, 100);
        assert!(sc.window_set_secure(pad, true));
        assert!(sc.window_is_secure(pad));
        // an app window created (or raised) while the shield is up must
        // land BELOW it — the chunk-58 rollout tapjacking condition
        let app = sc.window_new(10, 10, 60, 60);
        assert_ne!(sc.hit_test(30, 30), Some(app), "new app above shield");
        assert_eq!(sc.hit_test(30, 30), Some(pad));
        assert!(sc.window_raise(app, 30, 30));
        assert_eq!(sc.hit_test(30, 30), Some(pad), "raise crossed the tier");
        assert_eq!(sc.windows().last().unwrap().id, pad);
        // but the app is topmost of its own tier: app2 sits OUTSIDE the
        // pad's rect (the pad covers the whole screen, so any point
        // inside a window over it hit-tests to the shield — that is the
        // point of the tier)
        let app2 = sc.window_new(110, 10, 30, 30);
        assert!(sc.window_raise(app2, 125, 25));
        assert_eq!(sc.hit_test(125, 25), Some(app2));
        assert_eq!(sc.hit_test(30, 30), Some(pad));
        assert_eq!(sc.windows().last().unwrap().id, pad);
        // hit_all exposes what the shield is covering (the journal's
        // tapjacking evidence): topmost first, pad always first here
        let shadowed = sc.hit_all(30, 30);
        assert_eq!(shadowed.first(), Some(&pad));
        assert!(shadowed.contains(&app));
    }

    #[test]
    fn shield_release_restores_normal_z_order() {
        let mut sc = CompositorScene::new();
        let pad = sc.window_new(0, 0, 100, 100);
        let app = sc.window_new(10, 10, 60, 60);
        assert!(sc.window_set_secure(pad, true));
        assert_eq!(sc.hit_test(30, 30), Some(pad));
        assert!(sc.window_set_secure(pad, false));
        assert!(!sc.window_is_secure(pad));
        // unlock: the home screen competes normally again
        assert!(sc.window_raise(app, 30, 30));
        assert_eq!(sc.hit_test(30, 30), Some(app));
        assert_eq!(sc.windows().last().unwrap().id, app);
        // relock: the shield goes back on top without any raise
        assert!(sc.window_set_secure(pad, true));
        assert_eq!(sc.hit_test(30, 30), Some(pad));
    }

    #[test]
    fn shield_unknown_and_degenerate_cases() {
        let mut sc = CompositorScene::new();
        assert!(!sc.window_set_secure(42, true));
        assert!(!sc.window_is_secure(42));
        assert!(sc.hit_all(1, 1).is_empty());
        let a = sc.window_new(0, 0, 50, 50);
        // non-overlapping windows: hit_all reports only the hit one
        let b = sc.window_new(60, 60, 20, 20);
        assert_eq!(sc.hit_all(10, 10), vec![a]);
        assert_eq!(sc.hit_all(70, 70), vec![b]);
    }

    #[test]
    fn first_cursor_move_reports_damage() {
        let mut sc = CompositorScene::new();
        assert!(sc.cursor_move_dirty(5, 5).is_some());
        assert_eq!(sc.cursor(), Some((5, 5)));
        assert!(sc.cursor_move_dirty(5, 5).is_none(), "same pos: no damage");
    }

    #[test]
    fn cursor_sprite_is_clipped_to_screen() {
        let mut sc = CompositorScene::new();
        sc.pointer_move(u32::MAX, u32::MAX); // off-screen bottom-right corner
        let (mut buf, pitch) = buf(8, 8);
        sc.render(&mut buf, 8, 8, pitch, crate::screen::Region::full(8, 8)); // must not panic / OOB
        assert_eq!(px(&buf, pitch, 0, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn region_render_matches_full_render() {
        // The damage contract: rendering only `region` produces pixels
        // identical to a full render inside it.
        let mut sc = CompositorScene::new();
        let a = sc.window_new(2, 1, 10, 6);
        let b = sc.window_new(8, 4, 10, 6);
        assert!(sc.window_commit(
            a,
            vec![
                Op::Rect { x: 0, y: 0, w: 10, h: 6, rgb: 0xCC0000 },
                Op::Text { x: 1, y: 1, rgb: 0xFFFFFF, s: "A".into(), scale: 1 },
            ]
        ));
        assert!(sc.window_commit(
            b,
            vec![Op::Rect { x: 0, y: 0, w: 10, h: 6, rgb: 0x00CC00 }]
        ));
        assert!(sc.set_focus(b));
        assert!(sc.cursor_move_dirty(10, 5).is_some(), "first move sets cursor");
        assert!(sc.cursor_move_dirty(13, 7).is_some(), "cursor move reports damage");

        let (w, h) = (24u32, 16u32);
        let (mut full, p) = buf(w, h);
        crate::screen::paint_gradient(&mut full, w, h, p, Region::full(w, h));
        sc.render(&mut full, w, h, p, Region::full(w, h));

        let region = Region::rect(8, 4, 10, 6);
        let (mut part, _) = buf(w, h);
        crate::screen::paint_gradient(&mut part, w, h, p, Region::full(w, h));
        sc.render(&mut part, w, h, p, region);

        for y in 0..h {
            for x in 0..w {
                let (pa, pb) = (px(&full, p, x, y), px(&part, p, x, y));
                let inside =
                    x >= region.x0 && x < region.x1 && y >= region.y0 && y < region.y1;
                if inside {
                    assert_eq!(pa, pb, "mismatch inside region at ({x},{y})");
                }
            }
        }
    }

    #[test]
    fn parse_window_payloads() {
        let (x, y, w, h) = parse_window_new(&serde_json::json!({"x": 8, "y": 16, "w": 100, "h": 50})).unwrap();
        assert_eq!((x, y, w, h), (8, 16, 100, 50));
        assert!(parse_window_new(&serde_json::json!({"x": 1})).is_err());
        assert!(parse_window_new(&serde_json::json!({"x": 1, "y": 1, "w": 0, "h": 9})).is_err());
        let (id, ops) = parse_window_commit(&serde_json::json!({"id": 3, "ops": [{"t": "rect"}]})).unwrap();
        assert_eq!(id, 3);
        assert_eq!(ops.len(), 1);
        assert!(parse_window_commit(&serde_json::json!({"ops": []})).is_err());
    }
}
