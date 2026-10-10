//! Pointer (absolute tablet/touchscreen) input for oxcom. Discovers evdev
//! devices with ABS_X/ABS_Y axes (virtio-tablet = touch precursor), reads
//! raw `input_event` records, normalizes positions via the EVIOCGABS axis
//! range, and feeds the compositor loop, which hit-tests clicks for
//! click-to-focus/raise. Keyboard events are ignored here — inputd owns them.

use crate::evdev::{self, EVENT_SIZE, EV_ABS, EV_KEY, ABS_X, ABS_Y};
use crate::scene::CompositorScene;
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::Read;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

const BTN_LEFT: u16 = 0x110;
const BTN_TOUCH: u16 = 0x14A;
/// Normalized position granularity sent over the channel (0..=NORM).
const NORM: u32 = 10_000;

/// One pointer-click event, window-relative, JSON-serializable for IPC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClickEv {
    pub x: u32,
    pub y: u32,
}

const CLICK_QUEUE_CAP: usize = 32;

/// One synthesized gesture event, window-relative: the swipe DIRECTION
/// (direction of travel) plus the press start point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GestureEv {
    pub dir: GestureDir,
    pub x: u32,
    pub y: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GestureDir {
    Up,
    Down,
    Left,
    Right,
}

impl GestureDir {
    pub fn as_str(self) -> &'static str {
        match self {
            GestureDir::Up => "up",
            GestureDir::Down => "down",
            GestureDir::Left => "left",
            GestureDir::Right => "right",
        }
    }
}

/// Tap-vs-swipe classification (pure, screen coords). A press whose
/// displacement stays under SWIPE_MIN_PX on BOTH axes is a TAP; a
/// longer press is a swipe named by its dominant-axis direction of
/// travel.
pub const SWIPE_MIN_PX: i64 = 60;

pub fn classify_gesture(start: (u32, u32), end: (u32, u32)) -> Option<GestureDir> {
    let dx = end.0 as i64 - start.0 as i64;
    let dy = end.1 as i64 - start.1 as i64;
    if dx.abs() < SWIPE_MIN_PX && dy.abs() < SWIPE_MIN_PX {
        return None; // a tap
    }
    if dy.abs() >= dx.abs() {
        Some(if dy < 0 {
            GestureDir::Up
        } else {
            GestureDir::Down
        })
    } else {
        Some(if dx < 0 {
            GestureDir::Left
        } else {
            GestureDir::Right
        })
    }
}

/// Per-window event queues with a condvar for blocking consumers —
/// the pointer-side twin of keys::KeyHub. Generic over the event kind:
/// taps (ClickEv) and synthesized gestures (GestureEv) share it.
#[derive(Debug)]
pub struct EventHub<T> {
    inner: Mutex<HashMap<u32, VecDeque<T>>>,
    cv: Condvar,
}

// Manual impl: the derive would require T: Default, which no event
// needs (the queues start empty regardless of T).
impl<T> Default for EventHub<T> {
    fn default() -> Self {
        EventHub {
            inner: Mutex::new(HashMap::new()),
            cv: Condvar::new(),
        }
    }
}

pub type ClickHub = EventHub<ClickEv>;
pub type GestureHub = EventHub<GestureEv>;

impl<T> EventHub<T> {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&self, window: u32, ev: T) {
        let mut map = self.inner.lock().unwrap();
        let q = map.entry(window).or_default();
        if q.len() >= CLICK_QUEUE_CAP {
            q.pop_front();
        }
        q.push_back(ev);
        drop(map);
        self.cv.notify_all();
    }

    pub fn drop_window(&self, window: u32) {
        self.inner.lock().unwrap().remove(&window);
        self.cv.notify_all();
    }

    /// Block up to `timeout` for the next event of `window`.
    pub fn pop(&self, window: u32, timeout: Duration) -> Option<T> {
        let mut map = self.inner.lock().unwrap();
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if let Some(q) = map.get_mut(&window) {
                if let Some(ev) = q.pop_front() {
                    return Some(ev);
                }
            }
            let now = std::time::Instant::now();
            if now >= deadline {
                return None;
            }
            let (m, _timed_out) = self.cv.wait_timeout(map, deadline - now).unwrap();
            map = m;
        }
    }
}

#[cfg(feature = "gui")]
type Display = Arc<Mutex<Option<crate::DisplayPipe>>>;
#[cfg(not(feature = "gui"))]
type Display = Arc<Mutex<Option<()>>>;
type Scene = Arc<Mutex<CompositorScene>>;

#[derive(Debug, Clone, Copy)]
pub enum PointerEvent {
    /// Normalized absolute position, each axis 0..=NORM.
    Move { fx: u32, fy: u32 },
    Down,
    Up,
}

fn kmsg(line: &str) {
    crate::log::kmsg(line);
}

/// Spawn one reader thread per absolute-pointer device.
fn spawn_readers(tx: Sender<PointerEvent>) -> usize {
    let Ok(entries) = fs::read_dir("/dev/input") else {
        kmsg("oxcom: no /dev/input for pointer");
        return 0;
    };
    let mut count = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("event") {
            continue;
        }
        let Ok(file) = File::open(entry.path()) else { continue };
        let (Some(x_max), Some(y_max)) = (evdev::abs_axis_max(&file, ABS_X), evdev::abs_axis_max(&file, ABS_Y))
        else {
            continue; // not an absolute pointer device
        };
        let path = entry.path();
        let tx = tx.clone();
        std::thread::spawn(move || {
            let mut f = file;
            kmsg(&format!(
                "oxcom: pointer device {} (x_max {} y_max {})",
                path.display(),
                x_max,
                y_max
            ));
            let mut raw = [0u8; EVENT_SIZE];
            let mut fx: u32 = 0;
            let mut fy: u32 = 0;
            loop {
                if f.read_exact(&mut raw).is_err() {
                    kmsg("oxcom: pointer device read failed");
                    return;
                }
                let (ty, code, val) = evdev::parse_event(&raw);
                match (ty, code) {
                    (EV_ABS, ABS_X) => {
                        crate::activity::mark_activity();
                        fx = ((val.clamp(0, x_max) as u64) * NORM as u64
                            / x_max.max(1) as u64) as u32;
                        if tx.send(PointerEvent::Move { fx, fy }).is_err() {
                            return;
                        }
                    }
                    (EV_ABS, ABS_Y) => {
                        fy = ((val.clamp(0, y_max) as u64) * NORM as u64
                            / y_max.max(1) as u64) as u32;
                        if tx.send(PointerEvent::Move { fx, fy }).is_err() {
                            return;
                        }
                    }
                    (EV_KEY, BTN_LEFT) | (EV_KEY, BTN_TOUCH) => {
                        crate::activity::mark_activity();
                        let ev = if val != 0 { PointerEvent::Down } else { PointerEvent::Up };
                        if tx.send(ev).is_err() {
                            return;
                        }
                    }
                    _ => {}
                }
            }
        });
        count += 1;
    }
    count
}

/// One in-flight press: where it started and which window it hit.
/// Clicks are delivered on RELEASE (tap) or synthesized into a gesture
/// (swipe) — a press is classified only once it ends.
struct Press {
    start: (u32, u32),
    window: u32,
}

/// Apply pending pointer events to the scene; one damage-region repaint
/// per batch (coalesced moves collapse into one small region).
fn apply_events(
    scene: &Scene,
    display: &Display,
    w: u32,
    h: u32,
    ev: PointerEvent,
    rx: &Receiver<PointerEvent>,
    clicks: &Arc<ClickHub>,
    gestures: &Arc<GestureHub>,
    press: &mut Option<Press>,
) {
    let mut dirty: Option<crate::scene::Dirty> = None;
    let mut handle_one = |scene: &Scene, ev: PointerEvent, w: u32, h: u32,
                          dirty: &mut Option<crate::scene::Dirty>| {
        match ev {
            PointerEvent::Move { fx, fy } => {
                let x = (fx as u64 * w as u64 / NORM as u64) as u32;
                let y = (fy as u64 * h as u64 / NORM as u64) as u32;
                if let Some(d) = scene.lock().unwrap().cursor_move_dirty(x, y) {
                    kmsg(&format!("OXMILESTONE name=pointer-move x={} y={}", x, y));
                    *dirty = Some(match dirty.take() {
                        Some(prev) => d.merge_regions(prev),
                        None => d,
                    });
                }
            }
            PointerEvent::Down => {
                let mut sc = scene.lock().unwrap();
                if let Some((x, y)) = sc.cursor() {
                    // Shield evidence first: if the tap lands where the
                    // secure shield sits over other windows, journal what
                    // WOULD have received it (chunk-58 rollout: this is
                    // how an app window stole lock-pad taps).
                    let hits = sc.hit_all(x, y);
                    if hits.len() > 1 && sc.window_is_secure(hits[0]) {
                        kmsg(&format!(
                            "OXMILESTONE name=lock-shield-kept win={} shadowed={}",
                            hits[0], hits[1]
                        ));
                    }
                    if let Some(id) = sc.hit_test(x, y) {
                        let old_focus = sc.focused();
                        let mut regions = vec![crate::screen::Region::rect(
                            x.saturating_sub(8),
                            y.saturating_sub(8),
                            16,
                            16,
                        )];
                        // Record the press; the click (or swipe) is
                        // delivered on release once it can be
                        // classified.
                        *press = Some(Press { start: (x, y), window: id });
                        if let Some(of) = old_focus {
                            if let Some(win) =
                                sc.windows().iter().find(|win| win.id == of)
                            {
                                regions.push(crate::screen::Region::rect(
                                    win.x, win.y, win.w, win.h,
                                ));
                            }
                        }
                        if sc.window_raise(id, x, y) {
                            if let Some(win) =
                                sc.windows().iter().find(|win| win.id == id)
                            {
                                regions.push(crate::screen::Region::rect(
                                    win.x, win.y, win.w, win.h,
                                ));
                            }
                            kmsg(&format!(
                                "OXMILESTONE name=window-raise id={} x={} y={}",
                                id, x, y
                            ));
                            *dirty = Some(match dirty.take() {
                                Some(prev) => prev.merge_regions(crate::scene::Dirty::Regions(regions)),
                                None => crate::scene::Dirty::Regions(regions),
                            });
                        }
                    }
                }
            }
            PointerEvent::Up => {
                // Release classifies the press: a tap delivers a click
                // at the press point (window-relative), a long move
                // becomes a swipe gesture on the pressed window.
                if let Some(p) = press.take() {
                    let sc = scene.lock().unwrap();
                    let end = sc.cursor().unwrap_or(p.start);
                    if let Some(win) = sc.windows().iter().find(|win| win.id == p.window) {
                        match classify_gesture(p.start, end) {
                            None => {
                                let cx = p.start.0.saturating_sub(win.x);
                                let cy = p.start.1.saturating_sub(win.y);
                                clicks.push(p.window, ClickEv { x: cx, y: cy });
                            }
                            Some(dir) => {
                                let gx = p.start.0.saturating_sub(win.x);
                                let gy = p.start.1.saturating_sub(win.y);
                                kmsg(&format!(
                                    "OXMILESTONE name=pointer-swipe dir={} x={} y={}",
                                    dir.as_str(),
                                    gx,
                                    gy
                                ));
                                gestures.push(
                                    p.window,
                                    GestureEv { dir, x: gx, y: gy },
                                );
                            }
                        }
                    }
                }
            }
        }
    };
    handle_one(scene, ev, w, h, &mut dirty);
    while let Ok(ev) = rx.try_recv() {
        handle_one(scene, ev, w, h, &mut dirty);
    }
    if let Some(dirty) = dirty {
        let region = dirty.resolve(w, h);
        // Snapshot + hand off to the present thread: cursor repaints
        // are memory-copy-free IPC — never a flip ioctl on this thread.
        #[cfg(feature = "gui")]
        {
            let snapshot = scene.lock().unwrap().clone();
            let pipe = display.lock().unwrap().clone();
            if let Some(p) = pipe.as_ref() {
                p.request(snapshot, region);
            }
        }
        #[cfg(not(feature = "gui"))]
        {
            let _ = (&scene, &display, &region);
        }
    }
}

/// Discover pointer devices and start the compositor-side loop. Safe to call
/// once, after the scanout is claimed.
pub fn start(
    scene: Scene,
    display: Display,
    w: u32,
    h: u32,
    clicks: Arc<ClickHub>,
    gestures: Arc<GestureHub>,
) {
    let (tx, rx) = mpsc::channel();
    let devices = spawn_readers(tx);
    kmsg(&format!("oxcom: pointer watching {} device(s)", devices));
    std::thread::spawn(move || {
        // Small delay so early moves before display claim are not lost —
        // scene updates still apply; repaint just no-ops.
        let mut press: Option<Press> = None;
        loop {
            match rx.recv_timeout(Duration::from_secs(5)) {
                Ok(ev) => apply_events(
                    &scene,
                    &display,
                    w,
                    h,
                    ev,
                    &rx,
                    &clicks,
                    &gestures,
                    &mut press,
                ),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn move_normalization_is_monotonic() {
        // Documented contract: fx scales 0..=NORM across the axis range.
        let norm = |val: i64, max: i64| ((val.clamp(0, max) * NORM as i64) / max) as u32;
        assert_eq!(norm(0, 32767), 0);
        assert_eq!(norm(16383, 32767), 4999);
        assert_eq!(norm(32767, 32767), NORM);
        assert_eq!(norm(-5, 32767), 0, "negative clamps to axis start");
    }

    #[test]
    fn gestures_need_travel_and_name_their_direction() {
        // a press that stays put is a TAP (no gesture)
        assert_eq!(classify_gesture((100, 100), (110, 110)), None);
        // under the threshold on both axes is still a tap
        assert_eq!(classify_gesture((100, 100), (150, 150)), None);
        // vertical: up is NEGATIVE dy
        assert_eq!(
            classify_gesture((100, 600), (100, 400)),
            Some(GestureDir::Up)
        );
        assert_eq!(
            classify_gesture((100, 100), (100, 300)),
            Some(GestureDir::Down)
        );
        // horizontal: left is NEGATIVE dx
        assert_eq!(
            classify_gesture((800, 400), (600, 400)),
            Some(GestureDir::Left)
        );
        assert_eq!(
            classify_gesture((100, 400), (300, 400)),
            Some(GestureDir::Right)
        );
        // diagonal picks the DOMINANT axis
        assert_eq!(
            classify_gesture((100, 600), (130, 380)),
            Some(GestureDir::Up),
            "220px vertical beats 30px horizontal"
        );
        // exactly at the threshold on one axis is enough
        assert_eq!(
            classify_gesture((100, 100), (160, 100)),
            Some(GestureDir::Right)
        );
    }

    #[test]
    fn gesture_hub_queues_per_window() {
        let hub: GestureHub = GestureHub::new();
        hub.push(
            1,
            GestureEv {
                dir: GestureDir::Up,
                x: 10,
                y: 20,
            },
        );
        hub.push(
            2,
            GestureEv {
                dir: GestureDir::Down,
                x: 30,
                y: 40,
            },
        );
        let g = hub.pop(1, Duration::from_millis(0)).unwrap();
        assert_eq!((g.dir, g.x, g.y), (GestureDir::Up, 10, 20));
        assert!(hub.pop(1, Duration::from_millis(0)).is_none());
        // dropping a window clears only its queue
        hub.drop_window(2);
        assert!(hub.pop(2, Duration::from_millis(0)).is_none());
    }
}
