//! Keyboard input for oxcom: reads evdev devices without absolute axes
//! (i.e. keyboards — pointer/touch devices are claimed by `pointer.rs`),
//! tracks modifiers, maps Linux keycodes to semantic key events, and routes
//! them to the focused window's queue. Clients consume with the blocking
//! `key-recv` IPC op.

use crate::evdev::{self, EVENT_SIZE, EV_KEY, VAL_DOWN, VAL_REPEAT};
use crate::scene::CompositorScene;
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::Read;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
/// Per-window key queue cap; oldest events drop under pressure.
const QUEUE_CAP: usize = 64;

/// One semantic key event, JSON-serializable for IPC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEv {
    /// Linux EV_KEY code (linux/input-event-codes.h).
    pub code: u16,
    /// Pre-resolved character (shift applied); "\n" for Enter,
    /// "\x08" for Backspace, None for keys without a console meaning.
    pub ch: Option<char>,
}

/// Per-window key queues with a condvar for blocking consumers.
#[derive(Debug, Default)]
pub struct KeyHub {
    inner: Mutex<HashMap<u32, VecDeque<KeyEv>>>,
    cv: Condvar,
}

impl KeyHub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Route a key press to the focused window (dropped if none/no queue).
    pub fn push(&self, window: u32, ev: KeyEv) {
        let mut map = self.inner.lock().unwrap();
        let q = map.entry(window).or_default();
        if q.len() >= QUEUE_CAP {
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

    /// Block up to `timeout` for the next key of `window`.
    pub fn pop(&self, window: u32, timeout: Duration) -> Option<KeyEv> {
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

/// EV_KEY code → semantic character, shift-aware.
pub fn map_key(code: u16, shift: bool) -> Option<char> {
    let letter = |lower: u8| -> Option<char> {
        let c = lower as char;
        Some(if shift { c.to_ascii_uppercase() } else { c })
    };
    match code {
        2..=10 => Some((b'1' + (code - 2) as u8) as char),
        11 => Some(if shift { '=' } else { '0' }),
        12 => Some(if shift { '_' } else { '-' }),
        13 => Some(if shift { '+' } else { '=' }),
        14 => Some('\x08'),
        16..=25 => letter(b"qwertyuiop"[(code - 16) as usize]),
        30..=38 => letter(b"asdfghjkl"[(code - 30) as usize]),
        39 => Some(if shift { ':' } else { ';' }),
        40 => Some(if shift { '"' } else { '\'' }),
        43 => Some(if shift { '|' } else { '\\' }),
        44..=50 => letter(b"zxcvbnm"[(code - 44) as usize]),
        51 => Some(if shift { '<' } else { ',' }),
        52 => Some(if shift { '>' } else { '.' }),
        53 => Some(if shift { '?' } else { '/' }),
        57 => Some(' '),
        28 => Some('\n'),
        _ => None,
    }
}

type Scene = Arc<Mutex<CompositorScene>>;

/// Spawn one reader thread per keyboard (non-absolute) evdev device.
/// Releases are forwarded too — they drive modifier tracking.
fn spawn_readers(tx: Arc<Mutex<VecDeque<(u16, i32)>>>, cv: Arc<Condvar>) -> usize {
    let Ok(entries) = fs::read_dir("/dev/input") else {
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
        if evdev::has_abs_axes(&file) {
            continue; // pointer/touch — owned by pointer.rs
        }
        let tx = Arc::clone(&tx);
        let cv = Arc::clone(&cv);
        std::thread::spawn(move || {
            let path = entry.path();
            let mut file = file;
            let mut raw = [0u8; EVENT_SIZE];
            loop {
                if let Err(e) = file.read_exact(&mut raw) {
                    // A read error must NOT kill keyboard input for the
                    // whole session (a transient error under load or a
                    // device re-enumeration would otherwise silence the
                    // keyboard forever). Log it and re-open the node.
                    crate::log::kmsg(&format!(
                        "oxcom: keyboard reader {} error: {e} — reopening",
                        path.display()
                    ));
                    loop {
                        std::thread::sleep(Duration::from_secs(1));
                        match File::open(&path) {
                            Ok(f) => {
                                file = f;
                                crate::log::kmsg(&format!(
                                    "oxcom: keyboard reader {} reopened",
                                    path.display()
                                ));
                                break;
                            }
                            Err(_) => continue,
                        }
                    }
                    continue;
                }
                let (ty, code, val) = evdev::parse_event(&raw);
                if ty == EV_KEY {
                    let send_failed = {
                        let mut q = tx.lock().unwrap();
                        q.push_back((code, val));
                        false
                    };
                    if send_failed {
                        return;
                    }
                    cv.notify_all();
                }
            }
        });
        count += 1;
    }
    count
}

/// Discover keyboards and start the routing loop. `scene` provides the
/// current focus; `hub` receives the routed events.
pub fn start(scene: Scene, hub: Arc<KeyHub>) {
    let pending = Arc::new(Mutex::new(VecDeque::new()));
    let cv = Arc::new(Condvar::new());
    let devices = spawn_readers(Arc::clone(&pending), Arc::clone(&cv));
    crate::log::kmsg(&format!("oxcom: keyboard watching {} device(s)", devices));
    std::thread::spawn(move || {
        let mut shift = false;
        loop {
            let (code, val) = {
                let mut p = pending.lock().unwrap();
                loop {
                    if let Some(ev) = p.pop_front() {
                        break ev;
                    }
                    let (m, _t) = cv.wait_timeout(p, Duration::from_secs(3600)).unwrap();
                    p = m;
                }
            };
            match code {
                KEY_LEFTSHIFT | KEY_RIGHTSHIFT => shift = val != 0,
                _ => {
                    if val == VAL_DOWN || val == VAL_REPEAT {
                        crate::activity::mark_activity();
                        if let Some(ch) = map_key(code, shift) {
                            let focused = scene.lock().unwrap().focused();
                            if let Some(win) = focused {
                                crate::log::kmsg(&format!(
                                    "oxcom: key code={} ch={:?} -> win={}",
                                    code, ch, win
                                ));
                                hub.push(win, KeyEv { code, ch: Some(ch) });
                            } else {
                                crate::log::kmsg(&format!(
                                    "oxcom: key code={} dropped: no focused window",
                                    code
                                ));
                            }
                        } else {
                            crate::log::kmsg(&format!(
                                "oxcom: key code={} unmapped",
                                code
                            ));
                        }
                    }
                }
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keymap_covers_console_keys() {
        assert_eq!(map_key(30, false), Some('a'));
        assert_eq!(map_key(30, true), Some('A'));
        assert_eq!(map_key(2, false), Some('1'));
        assert_eq!(map_key(11, false), Some('0'));
        assert_eq!(map_key(57, false), Some(' '));
        assert_eq!(map_key(28, false), Some('\n'));
        assert_eq!(map_key(14, false), Some('\x08'));
        assert_eq!(map_key(103, false), None); // UP: not a console key
    }

    #[test]
    fn hub_routes_per_window_and_blocks() {
        let hub = KeyHub::new();
        assert_eq!(hub.pop(1, Duration::from_millis(30)), None); // timeout path
        hub.push(1, KeyEv { code: 30, ch: Some('a') });
        hub.push(1, KeyEv { code: 31, ch: Some('s') });
        hub.push(2, KeyEv { code: 32, ch: Some('d') });
        assert_eq!(hub.pop(1, Duration::from_millis(10)).unwrap().ch, Some('a'));
        assert_eq!(hub.pop(1, Duration::from_millis(10)).unwrap().ch, Some('s'));
        assert_eq!(hub.pop(2, Duration::from_millis(10)).unwrap().ch, Some('d'));
        // window removal clears its queue
        hub.push(3, KeyEv { code: 33, ch: Some('f') });
        hub.drop_window(3);
        assert_eq!(hub.pop(3, Duration::from_millis(10)), None);
    }

    #[test]
    fn queue_cap_drops_oldest() {
        let hub = KeyHub::new();
        for i in 0..(QUEUE_CAP + 10) {
            hub.push(9, KeyEv { code: i as u16, ch: Some('x') });
        }
        let map = hub.inner.lock().unwrap();
        assert_eq!(map.get(&9).unwrap().len(), QUEUE_CAP);
    }

    #[test]
    fn focus_routing_skips_unfocused_windows() {
        // Simulates the compositor loop's contract: keys go only to the
        // focused window id read from the scene.
        let scene = Arc::new(Mutex::new(CompositorScene::new()));
        let hub = KeyHub::new();
        assert_eq!(scene.lock().unwrap().focused(), None);
        let id = scene.lock().unwrap().window_new(0, 0, 10, 10);
        scene.lock().unwrap().window_raise(id, 0, 0);
        if let Some(win) = scene.lock().unwrap().focused() {
            hub.push(win, KeyEv { code: 30, ch: Some('a') });
        }
        assert_eq!(hub.pop(id, Duration::from_millis(10)).unwrap().ch, Some('a'));
    }
}
