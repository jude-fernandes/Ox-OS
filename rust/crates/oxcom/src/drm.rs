#![cfg(feature = "gui")]
#![allow(non_camel_case_types, non_snake_case, dead_code)]

use std::ffi::CString;
use std::io;
use std::os::unix::io::{AsRawFd, FromRawFd};

const DRM_IOCTL_BASE: u32 = 0x64;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;

const fn ioc(dir: u32, nr: u32, size: u32) -> u32 {
    (dir << 30) | (size << 16) | (DRM_IOCTL_BASE << 8) | nr
}

fn iowr<T>(nr: u32) -> u32 {
    ioc(IOC_WRITE | IOC_READ, nr, std::mem::size_of::<T>() as u32)
}

const fn iowr_c<T>(nr: u32) -> u32 {
    ioc(IOC_WRITE | IOC_READ, nr, std::mem::size_of::<T>() as u32)
}

const fn io_nr(nr: u32) -> u32 {
    ioc(0, nr, 0)
}

const DRM_IOCTL_SET_MASTER: u32 = io_nr(0x1e);
const DRM_IOCTL_MODE_GETRESOURCES: u32 = iowr_c::<drm_mode_card_res>(0xA0);
const DRM_IOCTL_MODE_GETCRTC: u32 = iowr_c::<drm_mode_crtc>(0xA1);
const DRM_IOCTL_MODE_SETCRTC: u32 = iowr_c::<drm_mode_crtc>(0xA2);
const DRM_IOCTL_MODE_GETENCODER: u32 = iowr_c::<drm_mode_get_encoder>(0xA6);
const DRM_IOCTL_MODE_GETCONNECTOR: u32 = iowr_c::<drm_mode_get_connector>(0xA7);
const DRM_IOCTL_MODE_ADDFB: u32 = iowr_c::<drm_mode_fb_cmd>(0xAE);
const DRM_IOCTL_MODE_CREATE_DUMB: u32 = iowr_c::<drm_mode_create_dumb>(0xB2);
const DRM_IOCTL_MODE_MAP_DUMB: u32 = iowr_c::<drm_mode_map_dumb>(0xB3);
const DRM_IOCTL_MODE_DIRTYFB: u32 = iowr_c::<drm_mode_fb_dirty_cmd>(0xAB);

const DRM_MODE_CONNECTED: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct drm_mode_modeinfo {
    pub clock: u32,
    pub hdisplay: u16,
    pub hsync_start: u16,
    pub hsync_end: u16,
    pub htotal: u16,
    pub hskew: u16,
    pub vdisplay: u16,
    pub vsync_start: u16,
    pub vsync_end: u16,
    pub vtotal: u16,
    pub vscan: u16,
    pub vrefresh: u32,
    pub flags: u32,
    pub type_: u32,
    pub name: [u8; 32],
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_card_res {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
}

#[repr(C)]
struct drm_mode_crtc {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: drm_mode_modeinfo,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_get_encoder {
    encoder_id: u32,
    encoder_type: u32,
    crtc_id: u32,
    possible_crtcs: u32,
    possible_clones: u32,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_get_connector {
    encoders_ptr: u64,
    modes_ptr: u64,
    props_ptr: u64,
    prop_values_ptr: u64,
    count_modes: u32,
    count_props: u32,
    count_encoders: u32,
    encoder_id: u32,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connection: u32,
    mm_width: u32,
    mm_height: u32,
    subpixel: u32,
    pad: u32,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_fb_cmd {
    fb_id: u32,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    depth: u32,
    handle: u32,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_create_dumb {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32,
    handle: u32,
    pitch: u32,
    size: u64,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_map_dumb {
    handle: u32,
    pad: u32,
    offset: u64,
}

#[repr(C)]
#[derive(Default)]
struct drm_clip_rect {
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,
}

#[repr(C)]
#[derive(Default)]
struct drm_mode_fb_dirty_cmd {
    fb_id: u32,
    flags: u32,
    color: u32,
    num_clips: u32,
    clips_ptr: u64,
}

const _: () = assert!(std::mem::size_of::<drm_mode_modeinfo>() == 68);
const _: () = assert!(std::mem::size_of::<drm_mode_crtc>() == 104);
const _: () = assert!(std::mem::size_of::<drm_mode_card_res>() == 64);
const _: () = assert!(std::mem::size_of::<drm_mode_get_connector>() == 80);
const _: () = assert!(std::mem::size_of::<drm_mode_get_encoder>() == 20);
const _: () = assert!(std::mem::size_of::<drm_mode_fb_cmd>() == 28);
const _: () = assert!(std::mem::size_of::<drm_mode_create_dumb>() == 32);
const _: () = assert!(std::mem::size_of::<drm_mode_map_dumb>() == 16);
const _: () = assert!(std::mem::size_of::<drm_clip_rect>() == 8);
const _: () = assert!(std::mem::size_of::<drm_mode_fb_dirty_cmd>() == 24);

fn xioctl(fd: i32, req: u32, arg: *mut core::ffi::c_void) -> io::Result<()> {
    // request type is target-dependent (glibc: c_ulong, musl: c_int)
    let rc = unsafe { libc::ioctl(fd, req as _, arg) };
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn xioctl_named(fd: i32, what: &'static str, req: u32, arg: *mut core::ffi::c_void) -> io::Result<()> {
    xioctl(fd, req, arg).map_err(|e| {
        io::Error::new(
            e.kind(),
            format!("{} ({:#x}): {}", what, req, e),
        )
    })
}

use crate::log::kmsg;

pub struct DrmOutput {
    file: std::fs::File,
    map: *mut u8,
    map_len: usize,
    pub width: u32,
    pub height: u32,
    pub pitch: u32,
    fb_id: u32,
    crtc: drm_mode_crtc,
    conn_id: u32,
    /// None = untested; Some(false) = DIRTYFB unsupported (full flip instead)
    dirtyfb: Option<bool>,
    /// Flip pacing: never issue SETCRTC/DIRTYFB faster than one per
    /// FLIP_MIN_INTERVAL. A burst of N rapid repaints must not queue N
    /// control-ring transfers faster than the host drains them — under
    /// TCG a vring-full SETCRTC blocked in D-state for 120+ s (kernel
    /// hung-task trace: virtio_gpu_queue_ctrl_sgs inside drm_mode_setcrtc).
    last_flip: Option<std::time::Instant>,
    /// Scanout self-heal: damage presents are DIRTYFB-only, which never
    /// re-establishes a scanout the HOST forgot (guest suspend/resume
    /// kills QEMU's display surface while kernel-side GETCRTC still
    /// reports ours — nothing errors, the screen is just gone). Every
    /// FULL_PRESENT_INTERVAL a damage present is upgraded to a full
    /// SETCRTC, which re-sends scanout and rebuilds the host surface.
    last_full_present: Option<std::time::Instant>,
}

unsafe impl Send for DrmOutput {}

impl DrmOutput {
    pub fn open(card: &str) -> io::Result<DrmOutput> {
        let path = CString::new(card)?;
        let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        xioctl_named(fd, "set-master", DRM_IOCTL_SET_MASTER, std::ptr::null_mut())
            .or_else(|e| if e.raw_os_error() == Some(libc::EACCES) { Ok(()) } else { Err(e) })?;

        let mut res = drm_mode_card_res::default();
        xioctl_named(fd, "get-resources(0)", DRM_IOCTL_MODE_GETRESOURCES, &mut res as *mut _ as *mut _)?;
        if res.count_connectors == 0 || res.count_crtcs == 0 {
            return Err(io::Error::new(io::ErrorKind::NotFound, "no kms objects"));
        }
        // All four id arrays must be backed: the kernel copies every array
        // whose count is nonzero, and a NULL pointer with a nonzero count
        // fails the whole ioctl with EFAULT.
        let mut fb_ids = vec![0u32; res.count_fbs as usize];
        let mut crtc_ids = vec![0u32; res.count_crtcs as usize];
        let mut conn_ids = vec![0u32; res.count_connectors as usize];
        let mut enc_ids = vec![0u32; res.count_encoders as usize];
        res.fb_id_ptr = fb_ids.as_mut_ptr() as u64;
        res.crtc_id_ptr = crtc_ids.as_mut_ptr() as u64;
        res.connector_id_ptr = conn_ids.as_mut_ptr() as u64;
        res.encoder_id_ptr = enc_ids.as_mut_ptr() as u64;
        xioctl_named(fd, "get-resources(1)", DRM_IOCTL_MODE_GETRESOURCES, &mut res as *mut _ as *mut _)?;
        kmsg(&format!(
            "kms: crtcs={} conns={} encs={} fbs={}",
            res.count_crtcs, res.count_connectors, res.count_encoders, res.count_fbs
        ));

        // decl-initializer is never read; the loop reassigns before any use
        #[allow(unused_assignments)]
        let mut conn = drm_mode_get_connector::default();
        let mut mode = drm_mode_modeinfo::default();
        let mut found = None;
        for &cid in conn_ids.iter() {
            conn = drm_mode_get_connector::default();
            conn.connector_id = cid;
            conn.count_modes = 1;
            conn.modes_ptr = &mut mode as *mut _ as u64;
            if xioctl_named(fd, "get-connector", DRM_IOCTL_MODE_GETCONNECTOR, &mut conn as *mut _ as *mut _).is_ok()
                && conn.connection == DRM_MODE_CONNECTED
                && conn.encoder_id != 0
            {
                found = Some(conn);
                break;
            }
        }
        let conn = found.ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no connected output"))?;

        let mut enc = drm_mode_get_encoder::default();
        enc.encoder_id = conn.encoder_id;
        xioctl_named(fd, "get-encoder", DRM_IOCTL_MODE_GETENCODER, &mut enc as *mut _ as *mut _)?;
        let crtc_id = if enc.crtc_id != 0 {
            enc.crtc_id
        } else {
            crtc_ids[0]
        };

        let mut crtc = drm_mode_crtc {
            set_connectors_ptr: 0,
            count_connectors: 0,
            crtc_id,
            fb_id: 0,
            x: 0,
            y: 0,
            gamma_size: 0,
            mode_valid: 0,
            mode: drm_mode_modeinfo::default(),
        };
        xioctl_named(fd, "get-crtc", DRM_IOCTL_MODE_GETCRTC, &mut crtc as *mut _ as *mut _)?;
        if crtc.mode_valid == 0 || crtc.mode.hdisplay == 0 {
            return Err(io::Error::new(io::ErrorKind::Unsupported, "no active mode"));
        }
        let width = crtc.mode.hdisplay as u32;
        let height = crtc.mode.vdisplay as u32;

        let mut dumb = drm_mode_create_dumb {
            height,
            width,
            bpp: 32,
            ..Default::default()
        };
        xioctl_named(fd, "create-dumb", DRM_IOCTL_MODE_CREATE_DUMB, &mut dumb as *mut _ as *mut _)?;

        let mut fb = drm_mode_fb_cmd {
            fb_id: 0,
            width,
            height,
            pitch: dumb.pitch,
            bpp: 32,
            depth: 24,
            handle: dumb.handle,
        };
        xioctl_named(fd, "addfb", DRM_IOCTL_MODE_ADDFB, &mut fb as *mut _ as *mut _)?;

        let mut map = drm_mode_map_dumb {
            handle: dumb.handle,
            ..Default::default()
        };
        xioctl_named(fd, "map-dumb", DRM_IOCTL_MODE_MAP_DUMB, &mut map as *mut _ as *mut _)?;
        let map_len = dumb.size as usize;
        let map = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                map_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                map.offset as libc::off_t,
            )
        };
        if map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }

        Ok(DrmOutput {
            file,
            map: map as *mut u8,
            map_len,
            width,
            height,
            pitch: dumb.pitch,
            fb_id: fb.fb_id,
            crtc,
            conn_id: conn.connector_id,
            dirtyfb: None,
            last_flip: None,
            last_full_present: None,
        })
    }

    /// Render only `region` of the scanout: background gradient + the
    /// composited scene, both restricted to the damage region. Pure
    /// memory writes into the shared framebuffer — no vring ioctls — so
    /// callers may hold whatever locks they need without risking a
    /// multi-second host-side stall.
    pub fn render(
        &mut self,
        scene: &crate::scene::CompositorScene,
        region: crate::screen::Region,
    ) -> io::Result<()> {
        let full = crate::screen::Region::full(self.width, self.height);
        let region = full.union(&region); // clamp
        let buf = unsafe {
            std::slice::from_raw_parts_mut(self.map, self.map_len)
        };
        crate::screen::paint_gradient(buf, self.width, self.height, self.pitch, region);
        scene.render(buf, self.width, self.height, self.pitch, region);
        Ok(())
    }

    /// Present the framebuffer to the host: DRM_MODE_DIRTYFB (region
    /// transfer) with a full-flip fallback for drivers without
    /// framebuffer damage (e.g. virtio-gpu). Flips are PACED — one per
    /// FLIP_MIN_INTERVAL — so a burst of repaints coalesces on the host
    /// side (the ioctl transfers whatever the framebuffer holds at that
    /// moment, i.e. the LATEST pixels) instead of queueing one 4 MB
    /// transfer per repaint and wedging the control vring.
    pub fn present_region(&mut self, region: crate::screen::Region) -> io::Result<()> {
        const FLIP_MIN_INTERVAL: std::time::Duration =
            std::time::Duration::from_millis(33);
        const FULL_PRESENT_INTERVAL: std::time::Duration =
            std::time::Duration::from_secs(5);
        if let Some(t) = self.last_flip {
            let since = t.elapsed();
            if since < FLIP_MIN_INTERVAL {
                std::thread::sleep(FLIP_MIN_INTERVAL - since);
            }
        }
        let full = crate::screen::Region::full(self.width, self.height);
        let region = full.union(&region); // clamp
        // Scanout self-heal: upgrade this present to a full SETCRTC when
        // the last full one is stale (see last_full_present). Idempotent
        // on a healthy pipe — one extra modeset per interval.
        let full_due = self
            .last_full_present
            .map_or(true, |t| t.elapsed() >= FULL_PRESENT_INTERVAL);
        let res = if region == full || full_due {
            let r = self.present();
            if r.is_ok() {
                self.last_full_present = Some(std::time::Instant::now());
            }
            r
        } else {
            match self.dirtyfb {
                Some(true) => self.present_dirty(region),
                Some(false) => self.present(),
                None => {
                    if self.present_dirty(region).is_ok() {
                        self.dirtyfb = Some(true);
                        self.last_full_present = Some(std::time::Instant::now());
                        Ok(())
                    } else {
                        self.dirtyfb = Some(false);
                        crate::log::kmsg("oxcom: DIRTYFB unsupported; full-flip fallback");
                        self.present()
                    }
                }
            }
        };
        self.last_flip = Some(std::time::Instant::now());
        res
    }

    /// Present a damage region via DRM_IOCTL_MODE_DIRTYFB.
    fn present_dirty(&mut self, region: crate::screen::Region) -> io::Result<()> {
        let clips = [drm_clip_rect {
            x1: region.x0 as u16,
            y1: region.y0 as u16,
            x2: region.x1 as u16,
            y2: region.y1 as u16,
        }];
        let mut cmd = drm_mode_fb_dirty_cmd {
            fb_id: self.fb_id,
            flags: 0,
            color: 0,
            num_clips: 1,
            clips_ptr: clips.as_ptr() as u64,
        };
        xioctl_named(
            self.file.as_raw_fd(),
            "dirtyfb",
            DRM_IOCTL_MODE_DIRTYFB,
            &mut cmd as *mut _ as *mut _,
        )
    }

    pub fn present(&mut self) -> io::Result<()> {
        let mut connectors = [self.conn_id];
        self.crtc.set_connectors_ptr = connectors.as_mut_ptr() as u64;
        self.crtc.count_connectors = 1;
        self.crtc.fb_id = self.fb_id;
        self.crtc.x = 0;
        self.crtc.y = 0;
        self.crtc.mode_valid = 1;
        xioctl_named(
            self.file.as_raw_fd(),
            "set-crtc",
            DRM_IOCTL_MODE_SETCRTC,
            &mut self.crtc as *mut _ as *mut _,
        )?;
        // Verify the flip from the kernel's point of view: GETCRTC must now
        // report OUR fb as the scanned-out one.
        let mut verify = drm_mode_crtc {
            set_connectors_ptr: 0,
            count_connectors: 0,
            crtc_id: self.crtc.crtc_id,
            fb_id: 0,
            x: 0,
            y: 0,
            gamma_size: 0,
            mode_valid: 0,
            mode: drm_mode_modeinfo::default(),
        };
        xioctl_named(
            self.file.as_raw_fd(),
            "get-crtc(verify)",
            DRM_IOCTL_MODE_GETCRTC,
            &mut verify as *mut _ as *mut _,
        )?;
        kmsg(&format!(
            "post-setcrtc: crtc={} scans fb={} (ours={}) mode_valid={}",
            self.crtc.crtc_id, verify.fb_id, self.fb_id, verify.mode_valid
        ));
        Ok(())
    }
}

impl Drop for DrmOutput {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.map as *mut libc::c_void, self.map_len);
        }
    }
}

/// Claim the display: returns the live output, which the caller must keep
/// open — dropping it closes the fd, releases DRM master, and lets the
/// kernel's fbdev client repaint the console over our scanout.
pub fn render_once(card: &str) -> io::Result<DrmOutput> {
    let mut out = DrmOutput::open(card)?;
    out.render(
        &crate::scene::CompositorScene::default(),
        crate::screen::Region::full(out.width, out.height),
    )?;
    out.present_region(crate::screen::Region::full(out.width, out.height))?;
    // Diagnostic window closed: reset drm.debug (if a debug run enabled it).
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .write(true)
        .open("/sys/module/drm/parameters/debug")
    {
        use std::io::Write;
        let _ = writeln!(f, "0");
    }
    Ok(out)
}
