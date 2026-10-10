use ox_ipc::{peer_comm, serve, serve_with_disconnect, Client, Envelope, ServerHandle};
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

// Pure logic modules are always compiled (and unit-tested) on every target;
// only the DRM hardware path is gated behind the gui feature.
mod activity;
#[cfg(feature = "gui")]
mod drm;
mod evdev;
mod font;
mod keys;
mod log;
mod pointer;
mod scene;
mod screen;

/// Renderer → present-thread handoff. Renderers clone the (small)
/// scene and post snapshot + damage; ONE thread owns the DRM output
/// and does render + paced flips. Rationale: SETCRTC can block for
/// minutes when the host drains the virtio-gpu control vring slowly
/// (kernel hung-task trace: virtio_gpu_queue_ctrl_sgs) — those ioctls
/// must never run under a lock an input or IPC thread needs.
#[cfg(feature = "gui")]
#[derive(Clone)]
pub struct DisplayPipe {
    q: Arc<(
        Mutex<Option<(scene::CompositorScene, crate::screen::Region)>>,
        std::sync::Condvar,
    )>,
    pub w: u32,
    pub h: u32,
}

#[cfg(feature = "gui")]
impl DisplayPipe {
    /// Renderer side: post a scene snapshot + damage (latest wins —
    /// damage merges, the newer snapshot replaces the older one).
    /// Never blocks on ioctls.
    pub fn request(&self, scene: scene::CompositorScene, region: crate::screen::Region) {
        let (lock, cv) = &*self.q;
        let mut g = lock.lock().unwrap();
        *g = Some(match g.take() {
            Some((prev_scene, prev_region)) => (prev_scene, prev_region.union(&region)),
            None => (scene, region),
        });
        cv.notify_one();
    }

    /// Present-thread side: block until damage exists, take it all.
    fn wait_take(
        q: &Arc<(
            Mutex<Option<(scene::CompositorScene, crate::screen::Region)>>,
            std::sync::Condvar,
        )>,
    ) -> (scene::CompositorScene, crate::screen::Region) {
        let (lock, cv) = q.as_ref();
        let mut g = lock.lock().unwrap();
        while g.is_none() {
            g = cv.wait(g).unwrap();
        }
        g.take().unwrap()
    }
}

#[cfg(feature = "gui")]
/// The claimed display, late-bound: the IPC server starts before the
/// DRM path does, because a display claim can block indefinitely (a
/// suspend landing mid-modeset wedges the ioctl — chunk 64). The
/// display thread fills the cell when — if ever — the scanout lands.
type Display = Arc<Mutex<Option<DisplayPipe>>>;
#[cfg(feature = "gui")]
type Scene = Arc<Mutex<scene::CompositorScene>>;

#[cfg(feature = "gui")]
fn try_render() -> (Display, Option<drm::DrmOutput>) {
    match drm::render_once("/dev/dri/card0") {
        Ok(out) => {
            log::kmsg(&format!(
                "OXMILESTONE name=compositor-rendered w={} h={}",
                out.width, out.height
            ));
            let pipe = DisplayPipe {
                q: Arc::new((Mutex::new(None), std::sync::Condvar::new())),
                w: out.width,
                h: out.height,
            };
            (Arc::new(Mutex::new(Some(pipe))), Some(out))
        }
        Err(e) => {
            log::kmsg(&format!("compositor render failed: {}", e));
            (Arc::new(Mutex::new(None)), None)
        }
    }
}

#[cfg(not(feature = "gui"))]
type Display = Arc<Mutex<Option<()>>>;
#[cfg(not(feature = "gui"))]
type Scene = Arc<Mutex<scene::CompositorScene>>;

#[cfg(not(feature = "gui"))]
fn try_render() -> (Display, Option<()>) {
    (Arc::new(Mutex::new(None)), None)
}

/// Apply a scene mutation and queue the changed region for present
/// (no-op error without gui). `f` mutates the shared scene and reports
/// what it changed; the repaint renders only that damage — on the
/// present thread, never here.
#[cfg(feature = "gui")]
fn mutate<F>(display: &Display, scene: &Scene, f: F) -> Result<u64, String>
where
    F: FnOnce(&mut scene::CompositorScene) -> Result<(u64, scene::Dirty), String>,
{
    let (n, dirty) = f(&mut scene.lock().unwrap())?;
    // Clone the pipe out of the late-bound cell and drop the lock at
    // once — the queue push below takes no DRM-path locks.
    let pipe = match display.lock().unwrap().clone() {
        Some(p) => p,
        None => return Err("no display claimed".into()),
    };
    let region = dirty.resolve(pipe.w, pipe.h);
    let area = region.area();
    // Snapshot + hand off: rendering and the flip happen on the
    // present thread, so a blocked SETCRTC cannot stall IPC or input.
    let snapshot = scene.lock().unwrap().clone();
    pipe.request(snapshot, region);
    crate::log::kmsg(&format!(
        "OXMILESTONE name=repaint w={} h={} area={} frame_area={} frac={:.3}",
        region.x1 - region.x0,
        region.y1 - region.y0,
        area,
        (pipe.w as u64) * (pipe.h as u64),
        area as f64 / ((pipe.w as u64) * (pipe.h as u64)) as f64
    ));
    Ok(n)
}

#[cfg(not(feature = "gui"))]
fn mutate<F>(_display: &Display, _scene: &Scene, _f: F) -> Result<u64, String>
where
    F: FnOnce(&mut scene::CompositorScene) -> Result<(u64, scene::Dirty), String>,
{
    Err("gui feature disabled".into())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Init,
    CompositorReady,
    SessionActive,
    Shutdown,
}

#[derive(Debug)]
pub struct IllegalTransition(pub Phase, pub Phase);

pub struct Compositor {
    phase: Phase,
}

impl Compositor {
    pub fn new() -> Self {
        Compositor { phase: Phase::Init }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn advance(&mut self, to: Phase) -> Result<(), IllegalTransition> {
        let legal = matches!(
            (self.phase, to),
            (Phase::Init, Phase::CompositorReady)
                | (Phase::CompositorReady, Phase::SessionActive)
                | (Phase::SessionActive, Phase::Shutdown)
                | (Phase::CompositorReady, Phase::Shutdown)
        );
        if legal {
            self.phase = to;
            Ok(())
        } else {
            Err(IllegalTransition(self.phase, to))
        }
    }
}

/// Polite focus (`steal=false`) must not take focus from another window:
/// background consoles may claim focus only while nothing else holds it.
fn polite_focus_granted(polite: bool, current: Option<u32>, id: u32) -> bool {
    !polite || current.is_none() || current == Some(id)
}

/// Blocking input waits (key-recv/click-recv) are served WITHOUT the
/// compositor lock: they only pop per-window queues and may block for
/// minutes. Routing them through `handle` — which holds the compositor
/// lock for the whole request — let one app's input wait starve every
/// other client (rendering included) for the entire timeout.
fn handle_input_wait(
    hub: &keys::KeyHub,
    clicks: &pointer::ClickHub,
    gestures: &pointer::GestureHub,
    req: &Envelope,
) -> Option<Envelope> {
    let null = serde_json::Value::Null;
    let payload = req.payload.as_ref().unwrap_or(&null);
    // chunk 61: input waits are OWNER-PROCESS scoped — a foreign process
    // must not observe another process's keystrokes, clicks or gestures
    // (an app clicking-recv on the lock pad's window would read tap
    // positions). The pid is the kernel's (SO_PEERCRED), not client-
    // claimed. helper connections of the SAME process keep working.
    // ONLY the recv ops are gated: every other op passes through this
    // dispatcher on its way to handle() and must not be touched.
    if matches!(req.op.as_str(), "key-recv" | "click-recv" | "gesture-recv") {
        let win = payload.get("window").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
        let kind = connection_kind();
        if !input_wait_allowed(kind, ox_ipc::conn_peer_pid(), win) {
            #[cfg(feature = "gui")]
            log::kmsg(&format!(
                "OXMILESTONE name=acl-refused op={} win={} kind=normal",
                req.op, win
            ));
            return Some(req.err(&format!(
                "acl: {} requires ownership or the system role",
                req.op
            )));
        }
    }
    match req.op.as_str() {
        "key-recv" => {
            let win = payload.get("window").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            // Honor the caller's window; the old 30 s cap silently timed
            // out payment cards while the user was still deciding.
            let tmo = payload
                .get("timeout_ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(4000)
                .min(600_000);
            Some(match hub.pop(win, Duration::from_millis(tmo)) {
                Some(ev) => req.ok(json!({
                    "event": { "code": ev.code, "ch": ev.ch.map(|c| c.to_string()) }
                })),
                None => req.ok(json!({ "event": null })),
            })
        }
        "click-recv" => {
            let win = payload.get("window").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let tmo = payload
                .get("timeout_ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(4000)
                .min(600_000);
            Some(match clicks.pop(win, Duration::from_millis(tmo)) {
                Some(ev) => req.ok(json!({ "event": { "x": ev.x, "y": ev.y } })),
                None => req.ok(json!({ "event": null })),
            })
        }
        "gesture-recv" => {
            let win = payload.get("window").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let tmo = payload
                .get("timeout_ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(4000)
                .min(600_000);
            Some(match gestures.pop(win, Duration::from_millis(tmo)) {
                Some(ev) => req.ok(json!({
                    "event": { "dir": ev.dir.as_str(), "x": ev.x, "y": ev.y }
                })),
                None => req.ok(json!({ "event": null })),
            })
        }
        _ => None,
    }
}

/// Chunk 65: the screendump destination sandbox. A screen.read grant
/// buys PIXELS, not a root-owned arbitrary-file-write — without this,
/// a granted app could truncate /data/ox/permstore.journal or plant
/// files anywhere oxcom (root) can reach. The destination must be a
/// FLAT filename directly inside /data/ox/artifacts/ — the one
/// directory every selftest/gate artifact lives in. No `..`, no
/// subdirectories (one component symlink inside the prefix would
/// redirect the whole tail), no relative paths. The final component is
/// additionally opened O_NOFOLLOW at write time, so a planted symlink
/// cannot redirect the write itself.
fn dump_path_ok(path: &str) -> Option<&str> {
    const ARTIFACTS: &str = "/data/ox/artifacts/";
    let rest = path.strip_prefix(ARTIFACTS)?;
    if rest.is_empty()
        || rest == "."
        || rest == ".."
        || rest.contains('/')
        || rest.contains('\\')
    {
        return None;
    }
    Some(rest)
}

/// The window-close core (chunk 60): shared by the op handler (which the
/// ACL guards) and the disconnect reaper — the reaper legitimately closes
/// the dying client's own windows after CONN_WINDOWS was drained, so the
/// ownership check would refuse them; it must bypass the ACL.
fn close_window_core(
    display: &Display,
    scene: &Scene,
    hub: &keys::KeyHub,
    clicks: &pointer::ClickHub,
    id: u32,
) -> Result<serde_json::Value, String> {
    let dirty = scene.lock().unwrap().window_close_dirty(id);
    let gone = scene.lock().unwrap().window_close(id);
    hub.drop_window(id);
    clicks.drop_window(id);
    proc_windows_remove(id);
    if gone {
        match mutate(display, scene, |_| Ok((0, dirty))) {
            Ok(_) => Ok(json!({ "closed": id })),
            Err(e) => Err(e),
        }
    } else {
        Err(format!("no such window {}", id))
    }
}

fn handle(
    comp: &mut Compositor,
    display: &Display,
    scene: &Scene,
    hub: &keys::KeyHub,
    clicks: &pointer::ClickHub,
    req: &Envelope,
) -> Envelope {
    let null = serde_json::Value::Null;
    let payload = req.payload.as_ref().unwrap_or(&null);
    // chunk 60: per-client op ACLs — the gate every op passes first
    if let Some(refusal) = acl_check(req, payload) {
        return refusal;
    }
    match req.op.as_str() {
        "register-system" => {
            // The shell claims the SYSTEM role at boot: first claimant
            // wins, the claim dies with its connection (the disconnect
            // hook frees it), and a re-claim on the same connection is
            // idempotent. Late claimants are refused with the winner
            // still holding the role.
            if CONN_IS_SYSTEM.with(|s| s.get()) {
                req.ok(json!({ "system": true, "already": true }))
            } else if SYSTEM_CLAIMED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                CONN_IS_SYSTEM.with(|s| s.set(true));
                #[cfg(feature = "gui")]
                log::kmsg("OXMILESTONE name=system-client-registered");
                req.ok(json!({ "system": true }))
            } else {
                req.err("acl: system role already claimed")
            }
        }
        "status" => {
            let (w, h, has_display) = {
                #[cfg(feature = "gui")]
                {
                    match display.lock().unwrap().as_ref() {
                        Some(p) => (p.w, p.h, true),
                        None => (0, 0, false),
                    }
                }
                #[cfg(not(feature = "gui"))]
                {
                    (0, 0, false)
                }
            };
            req.ok(json!({
                "service": "oxcom",
                "phase": format!("{:?}", comp.phase).to_lowercase(),
                "w": w,
                "h": h,
                "display": has_display,
            }))
        }
        "screendump" => {
            // Guest-side screenshot: raster the CURRENT scene snapshot
            // to a PPM file. QEMU's own screendump is unusable on this
            // target — the first guest suspend/resume kills the host
            // display surface while every guest-side ioctl stays
            // healthy — so gates and selftests dump from here instead.
            // Chunk 62: the screen's CONTENT is permission-gated — the
            // caller's KERNEL-verified process name must hold a
            // screen.read grant (unbound/deny/fake all refuse; the
            // unbound default is deny, matching the negative matrix).
            {
                let app = peer_comm();
                let mode = gated_mode("screen.read", &app);
                if mode != "grant" {
                    #[cfg(feature = "gui")]
                    log::kmsg(&format!(
                        "OXMILESTONE name=acl-refused op=screendump app={app} mode={mode}"
                    ));
                    return req.err("acl: screendump requires a screen.read grant");
                }
            }
            #[cfg(feature = "gui")]
            let (w, h) = match display.lock().unwrap().as_ref() {
                Some(p) => (p.w, p.h),
                None => (0, 0),
            };
            #[cfg(not(feature = "gui"))]
            let (w, h) = (0u32, 0u32);
            let Some(path) = payload.get("path").and_then(|v| v.as_str()) else {
                return req.err("screendump: missing path");
            };
            if path.is_empty() {
                return req.err("screendump: missing path");
            }
            // Chunk 65: the destination sandbox — refuse anything that
            // is not a flat filename inside /data/ox/artifacts/, with
            // the refusal journalled as evidence (same class as the
            // permission refusal above).
            if dump_path_ok(path).is_none() {
                log::kmsg(&format!(
                    "OXMILESTONE name=acl-refused op=screendump app={} reason=outside-artifacts path={path}",
                    peer_comm()
                ));
                return req.err("screendump: path outside /data/ox/artifacts/");
            }
            if w == 0 || h == 0 {
                return req.err("screendump: no display");
            }
            let pitch = w * 4; // BGRX, same layout as the drm dumb buffer
            let mut buf = vec![0u8; pitch as usize * h as usize];
            {
                // Debug raster under the scene lock: presenters work on
                // snapshots, so this delays (never tears) the next one.
                let g = scene.lock().unwrap();
                crate::screen::paint_gradient(
                    &mut buf,
                    w,
                    h,
                    pitch,
                    crate::screen::Region::full(w, h),
                );
                g.render(&mut buf, w, h, pitch, crate::screen::Region::full(w, h));
            }
            let bytes = crate::screen::ppm_bytes(&buf, w, h, pitch);
            // O_NOFOLLOW: a symlink planted at the destination must be
            // refused by the kernel, not followed (the string check
            // above cannot see what the path resolves to).
            use std::io::Write;
            use std::os::unix::fs::OpenOptionsExt;
            let mut f = match std::fs::OpenOptions::new()
                .create(true)
                .truncate(true)
                .write(true)
                .custom_flags(0o400000) // O_NOFOLLOW (asm-generic)
                .open(path)
            {
                Ok(f) => f,
                Err(e) => {
                    log::kmsg(&format!(
                        "OXMILESTONE name=acl-refused op=screendump app={} reason=open path={path} err={e}",
                        peer_comm()
                    ));
                    return req.err(&format!("screendump: open: {e}"));
                }
            };
            match f.write_all(&bytes).and_then(|_| f.sync_all()) {
                Ok(()) => {
                    log::kmsg(&format!(
                        "OXMILESTONE name=compositor-screendump path={path} w={w} h={h}"
                    ));
                    req.ok(json!({ "path": path, "w": w, "h": h }))
                }
                Err(e) => req.err(&format!("screendump: write: {e}")),
            }
        }
        "draw" => {
            match scene::parse_ops(payload).and_then(|ops| {
                let n = ops.len() as u64;
                mutate(display, scene, move |sc| {
                    sc.set_fullscreen(ops);
                    Ok((n, scene::Dirty::Full))
                })
            }) {
                Ok(n) => {
                    #[cfg(feature = "gui")]
                    log::kmsg(&format!("OXMILESTONE name=oxcom-draw n={}", n));
                    req.ok(json!({ "drawn": n }))
                }
                Err(e) => req.err(&e),
            }
        }
        "window-new" => match scene::parse_window_new(payload) {
            Ok((x, y, w, h)) => {
                let id = scene.lock().unwrap().window_new(x, y, w, h);
                let dirty = scene
                    .lock()
                    .unwrap()
                    .window_rect_dirty(id)
                    .unwrap_or(scene::Dirty::Full);
                // ownership attaches at CREATION (chunk 60): a window the
                // client created is theirs even if its first paint fails
                // (headless tests, transient DRM errors) — the reaper and
                // the ACL both key off this
                CONN_WINDOWS.with(|c| c.borrow_mut().push(id as u32));
                proc_windows_add(ox_ipc::conn_peer_pid(), id as u32);
                match mutate(display, scene, |_| Ok((id as u64, dirty))) {
                    Ok(_) => {
                        #[cfg(feature = "gui")]
                        log::kmsg(&format!(
                            "OXMILESTONE name=window-new id={} x={} y={} w={} h={}",
                            id, x, y, w, h
                        ));
                        req.ok(json!({ "id": id }))
                    }
                    Err(e) => req.err(&e),
                }
            }
            Err(e) => req.err(&e),
        },
        "window-commit" => {
            match scene::parse_window_commit(payload).and_then(|(id, ops)| {
                let n = ops.len() as u64;
                mutate(display, scene, move |sc| {
                    if sc.window_commit(id, ops) {
                        let dirty = sc
                            .window_rect_dirty(id)
                            .unwrap_or(scene::Dirty::Full);
                        Ok((n, dirty))
                    } else {
                        Err(format!("no such window {}", id))
                    }
                })
            }) {
                Ok(n) => {
                    #[cfg(feature = "gui")]
                    log::kmsg(&format!(
                        "OXMILESTONE name=window-commit id={} ops={}",
                        payload.get("id").and_then(|v| v.as_u64()).unwrap_or(0),
                        n
                    ));
                    req.ok(json!({ "committed": n }))
                }
                Err(e) => req.err(&e),
            }
        }
        "window-focus" => match payload.get("id").and_then(|v| v.as_u64()) {
            Some(id) => {
                // A polite focus (steal=false) is refused while another
                // window already holds focus: background consoles must not
                // race a real app for key routing.
                let polite = !payload
                    .get("steal")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                let current = scene.lock().unwrap().focused();
                if !polite_focus_granted(polite, current, id as u32) {
                    req.ok(json!({ "granted": false, "focused": current }))
                } else if scene.lock().unwrap().set_focus(id as u32) {
                    match mutate(display, scene, |_| Ok((0, scene::Dirty::Full))) {
                        Ok(_) => {
                            log::kmsg(&format!(
                                "OXMILESTONE name=window-focus id={}",
                                id
                            ));
                            req.ok(json!({ "focused": id, "granted": true }))
                        }
                        Err(e) => req.err(&e),
                    }
                } else {
                    req.err(&format!("no such window {}", id))
                }
            }
            None => req.err("id: missing/invalid"),
        },
        "window-close" => match payload.get("id").and_then(|v| v.as_u64()) {
            Some(id) => match close_window_core(display, scene, hub, clicks, id as u32) {
                Ok(v) => req.ok(v),
                Err(e) => req.err(&e),
            },
            None => req.err("id: missing/invalid"),
        },
        "window-secure" => {
            // The lockscreen shield (chunk 59): a secure window composites
            // and takes clicks above every normal window, whatever raises
            // or launches land while the device is locked. Same-trust
            // surface as every oxcom op (root IPC, 0600 socket) — the
            // shell is the intended sole caller.
            let id = payload.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
            let on = payload.get("on").and_then(|v| v.as_bool()).unwrap_or(false);
            let already = scene.lock().unwrap().window_is_secure(id);
            if already == on {
                req.ok(json!({ "id": id, "secure": on, "unchanged": true }))
            } else if scene.lock().unwrap().window_set_secure(id, on) {
                if on {
                    scene.lock().unwrap().set_focus(id);
                }
                match mutate(display, scene, |_| Ok((0, scene::Dirty::Full))) {
                    Ok(_) => {
                        log::kmsg(&format!(
                            "OXMILESTONE name=lock-shield id={} on={}",
                            id, on
                        ));
                        req.ok(json!({ "id": id, "secure": on }))
                    }
                    Err(e) => req.err(&e),
                }
            } else {
                req.err(&format!("no such window {}", id))
            }
        }
        "ready" => match comp.advance(Phase::CompositorReady) {
            Ok(()) => req.ok(json!({ "phase": "compositorready" })),
            Err(_) => req.err("illegal transition"),
        },
        "session-start" => match comp.advance(Phase::SessionActive) {
            Ok(()) => req.ok(json!({ "phase": "sessionactive" })),
            Err(_) => req.err("illegal transition"),
        },
        "shutdown" => match comp.advance(Phase::Shutdown) {
            Ok(()) => req.ok(json!({ "bye": true })),
            Err(_) => req.err("illegal transition"),
        },
        _ => req.err("unknown op"),
    }
}

fn default_socket() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

thread_local! {
    /// Windows created on THIS connection. When the client goes away
    /// (clean exit or crash), the disconnect hook closes them — without
    /// this, an exited app leaves a ghost window that keeps swallowing
    /// input (a ghost lock-screen overlay made the device untappable).
    static CONN_WINDOWS: std::cell::RefCell<Vec<u32>> = const { std::cell::RefCell::new(Vec::new()) };
    /// True when THIS connection holds the SYSTEM role (the shell).
    static CONN_IS_SYSTEM: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Global SYSTEM-role claim: only one connection may hold it at a time.
/// First `register-system` wins; the claim frees when that connection
/// dies (shell crash -> next boot's shell reclaims it).
static SYSTEM_CLAIMED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientKind {
    System,
    Normal,
}

fn connection_kind() -> ClientKind {
    if CONN_IS_SYSTEM.with(|s| s.get()) {
        ClientKind::System
    } else {
        ClientKind::Normal
    }
}

fn owns_window(id: u32) -> bool {
    CONN_WINDOWS.with(|c| c.borrow().contains(&id))
}

/// Windows owned by each peer PROCESS (chunk 61), keyed by the
/// kernel-verified peer pid. An app's helper connections share its pid,
/// so the click-watcher pattern (window created on one connection,
/// clicks awaited on another) keeps working — while a FOREIGN process
/// cannot await another process's input queues.
static PROC_WINDOWS: std::sync::OnceLock<
    std::sync::Mutex<std::collections::HashMap<u32, Vec<u32>>>,
> = std::sync::OnceLock::new();

fn proc_windows() -> &'static std::sync::Mutex<std::collections::HashMap<u32, Vec<u32>>> {
    PROC_WINDOWS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

fn proc_windows_add(pid: u32, win: u32) {
    if pid == 0 {
        return;
    }
    proc_windows().lock().unwrap().entry(pid).or_default().push(win);
}

fn proc_windows_remove(win: u32) {
    let mut m = proc_windows().lock().unwrap();
    for v in m.values_mut() {
        v.retain(|w| *w != win);
    }
    m.retain(|_, v| !v.is_empty());
}

fn proc_windows_contains(pid: u32, win: u32) -> bool {
    proc_windows()
        .lock()
        .unwrap()
        .get(&pid)
        .map(|v| v.contains(&win))
        .unwrap_or(false)
}

/// The input-wait decision (chunk 61): the SYSTEM client may observe
/// anything; everyone else only their OWN process's windows.
fn input_wait_allowed(kind: ClientKind, pid: u32, win: u32) -> bool {
    kind == ClientKind::System || proc_windows_contains(pid, win)
}

fn permstored_sock() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("permstored.sock")
}

/// Consult permstored for (app, permission). First kernel-identity-
/// gated consult in the tree: oxwifid-style consults use CLIENT-CLAIMED
/// app names; this one uses the SO_PEERCRED pid's /proc comm. Fail
/// closed: unreachable daemon, unbound grant, or anything but "grant"
/// (a "fake" mode is meaningless for screen content — refused).
fn gated_mode(permission: &str, app: &str) -> String {
    if app.is_empty() {
        return "deny".to_string();
    }
    let Ok(mut cl) = Client::connect(&permstored_sock()) else {
        return "deny".to_string();
    };
    match cl.request("get", json!({ "app": app, "permission": permission })) {
        Ok(resp) => resp
            .payload
            .as_ref()
            .and_then(|p| p.get("mode"))
            .and_then(|v| v.as_str())
            .unwrap_or("deny")
            .to_string(),
        Err(_) => "deny".to_string(),
    }
}

/// What an op requires, beyond connecting (the pure, exhaustively
/// testable core of the chunk-60 ACL; the impure ownership lookup and
/// kind check happen at the call site). Mutations outside this
/// connection's ownership are the spoofing/tapjack surface; reads and
/// own-window lifecycle stay open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Every client.
    Allow,
    /// The window owner or the SYSTEM client.
    OwnerOrSystem,
    /// The SYSTEM client only.
    SystemOnly,
}

fn op_acl(op: &str) -> Decision {
    match op {
        "window-secure" => Decision::SystemOnly,
        "window-close" | "window-commit" | "window-focus" => Decision::OwnerOrSystem,
        _ => Decision::Allow,
    }
}

/// Enforce one op against the calling connection. Journals + answers
/// the refusal envelope when the ACL says no.
fn acl_check(req: &Envelope, payload: &serde_json::Value) -> Option<Envelope> {
    let kind = connection_kind();
    let id = payload.get("id").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    let ok = match op_acl(&req.op) {
        Decision::Allow => true,
        Decision::SystemOnly => kind == ClientKind::System,
        Decision::OwnerOrSystem => kind == ClientKind::System || owns_window(id),
    };
    if ok {
        return None;
    }
    #[cfg(feature = "gui")]
    log::kmsg(&format!(
        "OXMILESTONE name=acl-refused op={} win={} kind={}",
        req.op,
        id,
        if kind == ClientKind::System { "system" } else { "normal" }
    ));
    Some(req.err(&format!(
        "acl: {} requires {}",
        req.op,
        match op_acl(&req.op) {
            Decision::SystemOnly => "the system role",
            _ => "ownership or the system role",
        }
    )))
}

fn main() -> std::io::Result<()> {
    // Panic visibility (2026-09-29): the service run file does not
    // redirect stdio to the console, so a panic in ANY thread died
    // silently — oxcom vanished between KMS probe and socket bind with
    // nothing on the serial. Mirror panics to kmsg (always visible).
    std::panic::set_hook(Box::new(|info| {
        let msg = format!("oxcom PANIC: {info}");
        eprintln!("{msg}");
        #[cfg(feature = "gui")]
        log::kmsg(&msg);
    }));
    #[cfg(feature = "gui")]
    log::kmsg("oxcom: stage starting");
    // One shared scene: IPC clients and the input loops composite into it.
    let scene: Scene = Arc::new(Mutex::new(scene::CompositorScene::default()));
    let hub = Arc::new(keys::KeyHub::new());
    keys::start(Arc::clone(&scene), Arc::clone(&hub));
    let clicks = Arc::new(pointer::ClickHub::new());
    let gestures = Arc::new(pointer::GestureHub::new());
    let comp = Arc::new(Mutex::new(Compositor::new()));
    // Chunk 64 rev3: claim the display SYNCHRONOUSLY, FIRST — the
    // chunk-63 ordering — then serve. Two live experiments fixed the
    // strategy for this virtual target:
    //   rev1 (claim in a thread, serve first): the thread's scheduling
    //     delay under TCG load lost the race with the drill's suspend —
    //     the modeset wedged in-kernel mid-claim, headless forever.
    //   rev2 (wait out a powerd hold file, claim post-resume): the
    //     hold handshake worked, but the POST-resume modeset hangs too
    //     (kms probe answered, SETCRTC never returned) — there is no
    //     healthy post-resume claim on this target; only claims that
    //     complete BEFORE the first suspend survive it.
    // So: claim immediately (kms probe + modeset ~1s, suspend at
    // powerd+6s ≈ 5s later — chunk 63 passed exactly this way), keep
    // the bounded 5-attempt retry, and serve after. The late-bound
    // Display type stays: a failed claim still boots displayless and
    // the handlers already answer honestly with display:false.
    #[cfg(not(feature = "gui"))]
    let display: Display = try_render().0;
    #[cfg(feature = "gui")]
    let display: Display = {
        let cell: Display = Arc::new(Mutex::new(None));
        let mut attempt = 0;
        loop {
            attempt += 1;
            let (d, s) = try_render();
            let pipe_opt = d.lock().unwrap().clone();
            let ok = pipe_opt.is_some();
            if ok || attempt >= 5 {
                log::kmsg(&format!(
                    "oxcom: stage display-probed attempt={attempt} ok={ok}"
                ));
                if let (Some(pipe), Some(mut out)) = (pipe_opt, s) {
                    let (w, h) = (pipe.w, pipe.h);
                    let q = Arc::clone(&pipe.q);
                    *cell.lock().unwrap() = Some(pipe);
                    log::kmsg(&format!("oxcom: stage display-ready w={w} h={h}"));
                    // THE present thread: the only owner of the DRM
                    // output. Renderers post snapshots + damage; this
                    // thread renders and performs the paced flips — a
                    // slow host drain can block SETCRTC for minutes,
                    // and that must stall nothing else.
                    std::thread::spawn(move || loop {
                        let (snapshot, region) = DisplayPipe::wait_take(&q);
                        if out.render(&snapshot, region).is_err() {
                            continue;
                        }
                        let _ = out.present_region(region);
                    });
                    pointer::start(
                        Arc::clone(&scene),
                        Arc::clone(&cell),
                        w,
                        h,
                        Arc::clone(&clicks),
                        Arc::clone(&gestures),
                    );
                    // A successful scanout claim is exactly what
                    // CompositorReady means; illegal transitions stay
                    // compile-time-shaped even on this path.
                    let _ = comp.lock().unwrap().advance(Phase::CompositorReady);
                } else {
                    log::kmsg("oxcom: stage displayless");
                }
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        cell
    };
    let sock = default_socket();
    eprintln!("oxcom: serving on {}", sock.display());
    let handler_display = Arc::clone(&display);
    let handler_comp = Arc::clone(&comp);
    let handler_scene2 = Arc::clone(&scene);
    let handler_hub = Arc::clone(&hub);
    let handler_clicks = Arc::clone(&clicks);
    let handler_gestures = Arc::clone(&gestures);
    // Disconnect-side clones: reap a dead client's windows so no ghost
    // surface keeps consuming input after its process is gone.
    let gone_display = Arc::clone(&display);
    let gone_scene = Arc::clone(&scene);
    let gone_hub = Arc::clone(&hub);
    let gone_clicks = Arc::clone(&clicks);
    #[cfg(feature = "gui")]
    log::kmsg("oxcom: stage serving");
    let handle = serve_with_disconnect(
        &sock,
        move |req| {
            // Input waits pop per-window queues and must NOT hold the
            // compositor lock while blocked — one app's click-recv would
            // otherwise starve every other client for the whole timeout.
            if let Some(resp) =
                handle_input_wait(&handler_hub, &handler_clicks, &handler_gestures, req)
            {
                return resp;
            }
            handle(
                &mut handler_comp.lock().unwrap(),
                &handler_display,
                &handler_scene2,
                &handler_hub,
                &handler_clicks,
                &req,
            )
        },
        move || {
            // If the SYSTEM client died, free the role before reaping —
            // the reaping closes below run as this (now freed) connection.
            if CONN_IS_SYSTEM.with(|s| s.replace(false)) {
                SYSTEM_CLAIMED.store(false, Ordering::SeqCst);
                log::kmsg("oxcom: system client gone — role freed");
            }
            let ids = CONN_WINDOWS.with(|c| std::mem::take(&mut *c.borrow_mut()));
            if ids.is_empty() {
                return;
            }
            for id in ids {
                let _ = close_window_core(
                    &gone_display,
                    &gone_scene,
                    &gone_hub,
                    &gone_clicks,
                    id,
                );
            }
            log::kmsg("oxcom: client gone — its windows were closed");
        },
    )?;
    serve_forever(handle);
    Ok(())
}

fn serve_forever(_h: ServerHandle) {
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ox_ipc::Client;

    fn req(op: &str) -> Envelope {
        Envelope::request(op, 1, serde_json::json!(null))
    }

    #[test]
    fn polite_focus_never_steals() {
        // Nothing focused: a polite request is granted.
        assert!(polite_focus_granted(true, None, 2));
        // Focus held by another window: refused.
        assert!(!polite_focus_granted(true, Some(1), 2));
        // Focus held by the requester itself: granted (re-focus own window).
        assert!(polite_focus_granted(true, Some(2), 2));
        // Explicit steal always wins.
        assert!(polite_focus_granted(false, Some(1), 2));
    }

    #[test]
    fn screendump_path_sandbox() {
        // Chunk 65: the granted-write sandbox. Exactly one shape is
        // legal: a flat filename inside /data/ox/artifacts/.
        assert_eq!(
            dump_path_ok("/data/ox/artifacts/pm-resume.ppm"),
            Some("pm-resume.ppm")
        );
        assert_eq!(
            dump_path_ok("/data/ox/artifacts/acl-sandbox-ok.ppm"),
            Some("acl-sandbox-ok.ppm")
        );
        // escapes and rewrites
        assert!(dump_path_ok("/data/ox/permstore.journal").is_none());
        assert!(dump_path_ok("/etc/passwd").is_none());
        assert!(dump_path_ok("/data/ox/artifacts/../permstore.journal").is_none());
        assert!(dump_path_ok("/data/ox/artifacts/..").is_none());
        // subdirectory = component-symlink risk, refused outright
        assert!(dump_path_ok("/data/ox/artifacts/sub/x.ppm").is_none());
        // degenerate
        assert!(dump_path_ok("/data/ox/artifacts/").is_none());
        assert!(dump_path_ok("/data/ox/artifacts").is_none());
        assert!(dump_path_ok("data/ox/artifacts/x.ppm").is_none());
        assert!(dump_path_ok("").is_none());
    }

    fn new_comp_with_display() -> (Compositor, Display, Scene, keys::KeyHub, pointer::ClickHub) {
        (
            Compositor::new(),
            Arc::new(Mutex::new(None)),
            Arc::new(Mutex::new(scene::CompositorScene::default())),
            keys::KeyHub::new(),
            pointer::ClickHub::new(),
        )
    }

    #[test]
    fn lifecycle_is_forward_only() {
        let mut c = Compositor::new();
        assert!(c.advance(Phase::SessionActive).is_err());
        c.advance(Phase::CompositorReady).unwrap();
        assert!(c.advance(Phase::Init).is_err());
        c.advance(Phase::SessionActive).unwrap();
        c.advance(Phase::Shutdown).unwrap();
    }

    #[test]
    fn ops_drive_state_machine_over_ipc_shapes() {
        let (mut c, d, sc, hub, clicks) = new_comp_with_display();
        assert!(handle(&mut c, &d, &sc, &hub, &clicks, &req("session-start")).error.is_some());
        let st = handle(&mut c, &d, &sc, &hub, &clicks, &req("status")).payload.unwrap();
        assert_eq!(st["phase"], "init");
        assert_eq!(st["display"], false);
        handle(&mut c, &d, &sc, &hub, &clicks, &req("ready"));
        assert_eq!(
            handle(&mut c, &d, &sc, &hub, &clicks, &req("status")).payload.unwrap()["phase"],
            "compositorready"
        );
        assert!(handle(&mut c, &d, &sc, &hub, &clicks, &req("unknown-op")).error.is_some());
    }

    #[test]
    fn draw_is_rejected_without_display() {
        let (mut c, d, sc, hub, clicks) = new_comp_with_display();
        let payload = serde_json::json!({"ops": [{"t": "rect", "w": 4, "h": 4}]});
        let resp = handle(&mut c, &d, &sc, &hub, &clicks, &Envelope::request("draw", 2, payload));
        assert!(resp.error.is_some());
    }

    #[test]
    fn window_ops_track_scene_even_without_display() {
        let (mut c, d, sc, hub, clicks) = new_comp_with_display();
        let resp = handle(
            &mut c,
            &d,
            &sc,
            &hub,
            &clicks,
            &Envelope::request("window-new", 2, json!({"x": 4, "y": 4, "w": 40, "h": 20})),
        );
        // painting ops fail without a display, but the scene still mutates
        assert!(resp.error.is_some());
        assert_eq!(sc.lock().unwrap().windows()[0].id, 1);
        assert_eq!(sc.lock().unwrap().focused(), None, "creation must not steal focus");
        let resp = handle(
            &mut c,
            &d,
            &sc,
            &hub,
            &clicks,
            &Envelope::request(
                "window-commit",
                3,
                json!({"id": 1, "ops": [{"t": "rect", "w": 40, "h": 20, "rgb": 0}]}),
            ),
        );
        // no display -> repaint fails -> the error carries the reason
        assert!(resp.error.is_some());
        assert_eq!(sc.lock().unwrap().windows().len(), 1);
        // keys queued for the window before it closes
        hub.push(1, keys::KeyEv { code: 30, ch: Some('a') });
        let resp = handle(
            &mut c,
            &d,
            &sc,
            &hub,
            &clicks,
            &Envelope::request("window-close", 4, json!({"id": 1})),
        );
        assert!(resp.error.is_some()); // repaint fails without display
        assert_eq!(sc.lock().unwrap().windows().len(), 0);
        assert_eq!(hub.pop(1, Duration::from_millis(10)), None, "queue dropped");
        let resp = handle(
            &mut c,
            &d,
            &sc,
            &hub,
            &clicks,
            &Envelope::request("window-close", 5, json!({"id": 9})),
        );
        assert!(resp.error.is_some());
    }

    #[test]
    fn end_to_end_with_real_server() {
        let dir = std::env::temp_dir().join(format!("oxcom-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock = dir.join("oxcom.sock");
        let comp = Arc::new(Mutex::new(Compositor::new()));
        let display: Display = Arc::new(Mutex::new(None));
        let scn: Scene = Arc::new(Mutex::new(scene::CompositorScene::default()));
        let hub = Arc::new(keys::KeyHub::new());
        let clicks = Arc::new(pointer::ClickHub::new());
        let gestures = Arc::new(pointer::GestureHub::new());
        let hc = Arc::clone(&comp);
        let hd = Arc::clone(&display);
        let hs = Arc::clone(&scn);
        let h = serve(&sock, move |req| {
            // input waits bypass the compositor lock, same as main()
            if let Some(resp) = handle_input_wait(&hub, &clicks, &gestures, &req) {
                return resp;
            }
            handle(&mut hc.lock().unwrap(), &hd, &hs, &hub, &clicks, &req)
        })
        .unwrap();
        let mut cl = Client::connect(&sock).unwrap();
        assert!(cl.request("session-start", json!(null)).unwrap().error.is_some());
        assert!(cl.request("ready", json!(null)).unwrap().error.is_none());
        let st = cl.request("status", json!(null)).unwrap().payload.unwrap();
        assert_eq!(st["phase"], "compositorready");
        assert!(cl.request("shutdown", json!(null)).unwrap().error.is_none());
        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn acl_table_covers_every_mutation_op() {
        // the pure core: what each op demands
        assert_eq!(op_acl("window-secure"), Decision::SystemOnly);
        for op in ["window-close", "window-commit", "window-focus"] {
            assert_eq!(op_acl(op), Decision::OwnerOrSystem);
        }
        for op in [
            "status", "ready", "session-start", "shutdown", "register-system", "screendump",
            "draw", "window-new", "key-recv", "click-recv", "gesture-recv", "nonexistent-op",
        ] {
            assert_eq!(op_acl(op), Decision::Allow, "{op} must stay open");
        }
    }

    #[test]
    fn screendump_fails_closed_without_a_grant() {
        // No permstored on the test host → the consult fails closed
        // (deny) → the refusal carries the acl marker. The granted path
        // is proven in-guest by the grid/alerts/switcher gates (their
        // selftests grant oxctl screen.read before dumping).
        let mut c = Compositor::new();
        let d: Display = Arc::new(Mutex::new(None));
        let sc: Scene = Arc::new(Mutex::new(scene::CompositorScene::default()));
        let hub = keys::KeyHub::new();
        let clicks = pointer::ClickHub::new();
        let resp = handle(
            &mut c,
            &d,
            &sc,
            &hub,
            &clicks,
            &Envelope::request("screendump", 1, json!({"path": "/tmp/ox-test.ppm"})),
        );
        let err = resp.error.unwrap_or_default();
        assert!(err.starts_with("acl:"), "unbound screendump must refuse: {err}");
    }

    #[test]
    fn input_waits_are_process_scoped() {
        // registry semantics
        assert!(!proc_windows_contains(111, 7));
        proc_windows_add(111, 7);
        assert!(proc_windows_contains(111, 7));
        assert!(!proc_windows_contains(222, 7), "ownership is per-PROCESS");
        // the decision: SYSTEM bypasses, the owner process is allowed,
        // a foreign pid is refused, an unknown pid is never trusted
        assert!(input_wait_allowed(ClientKind::System, 222, 7));
        proc_windows_add(111, 8);
        assert!(input_wait_allowed(ClientKind::Normal, 111, 8));
        assert!(!input_wait_allowed(ClientKind::Normal, 222, 8));
        assert!(!input_wait_allowed(ClientKind::Normal, 0, 8));
        // closing removes ownership
        proc_windows_remove(8);
        assert!(!proc_windows_contains(111, 8));
        proc_windows_remove(7);
    }

    #[test]
    fn helper_connections_of_one_process_share_ownership() {
        // the chunk-50 pattern: window created on connection A, clicks
        // awaited on connection B — same process, both owned
        proc_windows_add(333, 9);
        assert!(input_wait_allowed(ClientKind::Normal, 333, 9));
        assert!(!input_wait_allowed(ClientKind::Normal, 334, 9));
        proc_windows_add(333, 9); // a second window, same process
        assert!(proc_windows_contains(333, 9));
        proc_windows_remove(9);
        assert!(!proc_windows_contains(333, 9));
    }

    #[test]
    fn acl_refuses_foreign_mutation_but_honors_system_and_owner() {
        let dir = std::env::temp_dir().join(format!("oxcom-acl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock = dir.join("oxcom.sock");
        let comp = Arc::new(Mutex::new(Compositor::new()));
        let display: Display = Arc::new(Mutex::new(None));
        let scn: Scene = Arc::new(Mutex::new(scene::CompositorScene::default()));
        let hub = Arc::new(keys::KeyHub::new());
        let clicks = Arc::new(pointer::ClickHub::new());
        let gestures = Arc::new(pointer::GestureHub::new());
        let hc = Arc::clone(&comp);
        let hd = Arc::clone(&display);
        let hs = Arc::clone(&scn);
        // the REAL disconnect contract (main's hook): free the SYSTEM
        // role, then reap the dead client's windows — serve()'s default
        // hook is empty and would never free the role
        let gd = Arc::clone(&display);
        let gs = Arc::clone(&scn);
        let gh = Arc::clone(&hub);
        let gc = Arc::clone(&clicks);
        let h = serve_with_disconnect(
            &sock,
            move |req| {
                if let Some(resp) = handle_input_wait(&hub, &clicks, &gestures, &req) {
                    return resp;
                }
                handle(&mut hc.lock().unwrap(), &hd, &hs, &hub, &clicks, &req)
            },
            move || {
                if CONN_IS_SYSTEM.with(|s| s.replace(false)) {
                    SYSTEM_CLAIMED.store(false, Ordering::SeqCst);
                }
                let ids = CONN_WINDOWS.with(|c| std::mem::take(&mut *c.borrow_mut()));
                for id in ids {
                    let _ = close_window_core(&gd, &gs, &gh, &gc, id);
                }
            },
        )
        .unwrap();
        // the shell claims SYSTEM first
        let mut sys = Client::connect(&sock).unwrap();
        assert!(sys.request("register-system", json!(null)).unwrap().error.is_none());
        // the pad window: created in the scene (id 1 — fresh scene), but
        // its first paint errors on this display-less server; ownership
        // attaches at creation, so the SYSTEM ops still run (their errors
        // are paint errors, never acl refusals)
        let _ = sys.request("window-new", json!({"x":0,"y":0,"w":100,"h":100})).unwrap();
        let r = sys
            .request("window-secure", json!({"id": 1, "on": true}))
            .unwrap();
        assert!(!r.error.as_deref().unwrap_or("").starts_with("acl:"),
            "SYSTEM may engage the shield (got: {:?})", r.error);
        // a normal client arrives
        let mut app = Client::connect(&sock).unwrap();
        let r = app.request("register-system", json!(null)).unwrap();
        assert!(r.error.is_some(), "second claim must be refused");
        // the app's own window: created in the scene as id 2
        let _ = app.request("window-new", json!({"x":10,"y":10,"w":50,"h":50})).unwrap();
        // foreign mutations refused, with the acl journal evidence
        let r = app.request("window-secure", json!({"id": 1, "on": false})).unwrap();
        assert!(r.error.as_deref().unwrap_or("").starts_with("acl:"),
            "normal client must not touch the shield");
        let r = app.request("window-close", json!({"id": 1})).unwrap();
        assert!(r.error.as_deref().unwrap_or("").starts_with("acl:"),
            "normal client must not close the pad");
        let r = app.request("window-focus", json!({"id": 1})).unwrap();
        assert!(r.error.as_deref().unwrap_or("").starts_with("acl:"),
            "normal client must not steal the pad's focus");
        // own-window lifecycle still works for the normal client
        let r = app.request("window-close", json!({"id": 2})).unwrap();
        assert!(!r.error.as_deref().unwrap_or("").starts_with("acl:"),
            "own close must pass the ACL (got: {:?})", r.error);
        // the SYSTEM client's death frees the role for the next claimant
        drop(sys);
        let mut late = Client::connect(&sock).unwrap();
        let mut claimed = false;
        for _ in 0..50 {
            if late.request("register-system", json!(null)).unwrap().error.is_none() {
                claimed = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(claimed, "role must free when the system client disconnects");
        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn input_wait_on_one_client_does_not_starve_another() {
        // Regression: key-recv/click-recv used to run while holding the
        // compositor lock, so one app's blocked input wait queued every
        // other client's requests (rendering included) behind it. The
        // server must route input waits lock-free.
        let dir = std::env::temp_dir().join(format!("oxcom-starve-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock = dir.join("oxcom.sock");
        let comp = Arc::new(Mutex::new(Compositor::new()));
        let display: Display = Arc::new(Mutex::new(None));
        let scn: Scene = Arc::new(Mutex::new(scene::CompositorScene::default()));
        let hub = Arc::new(keys::KeyHub::new());
        let clicks = Arc::new(pointer::ClickHub::new());
        let gestures = Arc::new(pointer::GestureHub::new());
        let hc = Arc::clone(&comp);
        let hd = Arc::clone(&display);
        let hs = Arc::clone(&scn);
        let h = serve(&sock, move |req| {
            if let Some(resp) = handle_input_wait(&hub, &clicks, &gestures, &req) {
                return resp;
            }
            handle(&mut hc.lock().unwrap(), &hd, &hs, &hub, &clicks, &req)
        })
        .unwrap();
        let mut a = Client::connect(&sock).unwrap();
        let mut b = Client::connect(&sock).unwrap();
        // A blocks in click-recv (10 s); nothing will click its window.
        let wait = std::thread::spawn(move || {
            a.request("click-recv", json!({ "window": 1, "timeout_ms": 10_000 }))
                .unwrap()
        });
        std::thread::sleep(std::time::Duration::from_millis(300));
        // B must still be served while A is blocked.
        let t0 = std::time::Instant::now();
        let resp = b.request("status", json!(null)).unwrap();
        assert!(resp.error.is_none(), "client B starved behind A's input wait");
        assert!(
            t0.elapsed() < std::time::Duration::from_secs(5),
            "client B waited {:?} behind A's input wait",
            t0.elapsed()
        );
        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
