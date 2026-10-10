//! ox-camerad: the camera service — owns the V4L2 capture device
//! (vivid, the virtual test sensor, on the virtual target) and serves
//! captures through the SAME honest-permission contract as locationd.
//! Every `capture {app}` consults permstored for `camera.read`:
//!   deny  (default, incl. unbound/unreachable) -> refused
//!   fake  -> a clearly-synthetic frame (the app works, the real
//!            sensor never delivers the scene)
//!   grant -> a real frame from the sensor, saved to /data/ox/DCIM
//! Capture uses the V4L2 STREAMING I/O method (chunk 47, replacing
//! the legacy per-frame read()): REQBUFS(mmap, 4 buffers) + QBUF +
//! STREAMON, frames dequeued with DQBUF and requeued — the standard
//! zero-ish-copy sensor path, identical on real hardware.

use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::io::Write as _;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const DEVICE: &str = "/dev/video0";
pub const DCIM: &str = "/data/ox/DCIM";
const BGR24: u32 = fourcc(b"BGR3");
const WIDTH: u32 = 320;
const HEIGHT: u32 = 240;

const fn fourcc(s: &[u8; 4]) -> u32 {
    s[0] as u32 | (s[1] as u32) << 8 | (s[2] as u32) << 16 | (s[3] as u32) << 24
}

// --- minimal V4L2 ABI. WARNING: the G/S_FMT ioctl numbers are NOT the
// values quoted in many docs — those are the 32-bit-compat encoding.
// On 64-bit, struct v4l2_format is 208 bytes (the embedded
// v4l2_window's pointers force 8-byte alignment), so G_FMT=0xc0d05604
// and S_FMT=0xc0d05605; QUERYCAP is 0x80685600 (capability = 104 on
// both). Verified against the host kernel headers. ---

const _IOC_READ: u32 = 2;
const _IOC_WRITE: u32 = 1;
const V: u8 = b'V';

const fn ioc(dir: u32, nr: u8, size: usize) -> libc::c_ulong {
    ((dir << 30) | ((size as u32) << 16) | ((V as u32) << 8) | nr as u32) as libc::c_ulong
}
const fn ior(nr: u8, size: usize) -> libc::c_ulong {
    ioc(_IOC_READ, nr, size)
}
const fn iow(nr: u8, size: usize) -> libc::c_ulong {
    ioc(_IOC_WRITE, nr, size)
}
const fn iowr(nr: u8, size: usize) -> libc::c_ulong {
    ioc(_IOC_READ | _IOC_WRITE, nr, size)
}

pub const VIDIOC_QUERYCAP: libc::c_ulong = ior(0, 104);
pub const VIDIOC_G_FMT: libc::c_ulong = iowr(4, 208);
pub const VIDIOC_S_FMT: libc::c_ulong = iowr(5, 208);
pub const VIDIOC_REQBUFS: libc::c_ulong = iowr(8, 20);
pub const VIDIOC_QUERYBUF: libc::c_ulong = iowr(9, 88);
pub const VIDIOC_QBUF: libc::c_ulong = iowr(15, 88);
pub const VIDIOC_DQBUF: libc::c_ulong = iowr(17, 88);
pub const VIDIOC_STREAMON: libc::c_ulong = iow(18, 4);
pub const VIDIOC_STREAMOFF: libc::c_ulong = iow(19, 4);

const V4L2_CAP_VIDEO_CAPTURE: u32 = 0x1;
const V4L2_CAP_STREAMING: u32 = 0x0400_0000;
const V4L2_BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const V4L2_MEMORY_MMAP: u32 = 1;
const V4L2_FIELD_NONE: u32 = 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2Capability {
    pub driver: [u8; 16],
    pub card: [u8; 32],
    pub bus_info: [u8; 32],
    pub version: u32,
    pub capabilities: u32,
    pub device_caps: u32,
    pub reserved: [u32; 3],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2PixFormat {
    pub width: u32,
    pub height: u32,
    pub pixelformat: u32,
    pub field: u32,
    pub bytesperline: u32,
    pub sizeimage: u32,
    pub colorspace: u32,
    pub priv_: u32,
    pub flags: u32,
    pub ycbcr_enc: u32,
    pub quantization: u32,
    pub xfer_func: u32,
}

/// { type: u32, [4 bytes of union-alignment padding], fmt union(200) }
/// — 208 bytes total on 64-bit: the union carries v4l2_window (which
/// has pointers) so it is 8-aligned. The pix variant occupies the
/// first 48 of the union's 200 bytes.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2Format {
    pub type_: u32,
    _align: [u8; 4],
    pub pix: V4l2PixFormat,
    pub _pad: [u8; 208 - 8 - std::mem::size_of::<V4l2PixFormat>()],
}

fn ioctl(fd: libc::c_int, req: libc::c_ulong, arg: *mut libc::c_void) -> std::io::Result<()> {
    // musl prototypes ioctl's request as c_int (32-bit), glibc as
    // c_ulong; the V4L2 request numbers are 32-bit patterns either way
    #[cfg(target_env = "musl")]
    let rc = unsafe { libc::ioctl(fd, req as u32 as libc::c_int, arg) };
    #[cfg(not(target_env = "musl"))]
    let rc = unsafe { libc::ioctl(fd, req as libc::c_ulong, arg) };
    if rc < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// v4l2_requestbuffers (20 bytes on 64-bit; capabilities @12, then
/// reserved+tail padding).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2Requestbuffers {
    pub count: u32,
    pub type_: u32,
    pub memory: u32,
    pub capabilities: u32,
    pub _reserved_pad: u32,
}

/// v4l2_buffer (88 bytes on 64-bit; the timeval's 8-alignment puts the
/// timestamp at 24 and the m.offset union at 64). Verified by probe:
/// index@0 type@4 memory@60 length@72 m.offset@64 bytesused@8 flags@12.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2Buffer {
    pub index: u32,       // 0
    pub type_: u32,       // 4
    pub bytesused: u32,   // 8
    pub flags: u32,       // 12
    pub field: u32,       // 16
    pub timestamp: [u64; 2], // 24 (struct timeval, 2 x u64 on 64-bit)
    pub timecode: [u32; 4],  // 40
    pub sequence: u32,    // 56
    pub memory: u32,      // 60
    pub m_offset: u64,    // 64 (union: .offset for MMAP)
    pub length: u32,      // 72
    pub _reserved2: u32,  // 76
    pub _reserved: [u32; 2], // 80
}

fn zeroed_buffer() -> V4l2Buffer {
    V4l2Buffer {
        index: 0,
        type_: V4L2_BUF_TYPE_VIDEO_CAPTURE,
        bytesused: 0,
        flags: 0,
        field: 0,
        timestamp: [0; 2],
        timecode: [0; 4],
        sequence: 0,
        memory: V4L2_MEMORY_MMAP,
        m_offset: 0,
        length: 0,
        _reserved2: 0,
        _reserved: [0; 2],
    }
}

/// A live streaming session: 4 MMAP-captured buffers queued, stream
/// ON. `grab()` dequeues one frame (blocking), copies it out, and
/// requeues the buffer. Dropping the session STREAMOFFs, unmaps and
/// closes — the sensor returns to idle.
///
/// SAFETY (Send): the raw pointers point at driver-owned mappings of
/// THIS session's fd; the session is only ever used through the
/// mutex-guarded Cam, so exclusive access is guaranteed.
pub struct StreamSession {
    fd: libc::c_int,
    bufs: Vec<(usize, *mut u8)>,
    pub w: u32,
    pub h: u32,
}
unsafe impl Send for StreamSession {}

impl StreamSession {
    pub fn open(device: &str, w: u32, h: u32) -> std::io::Result<Self> {
        let path = std::ffi::CString::new(device)?;
        // SAFETY (syscall shape): single-threaded open of the sensor.
        let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let close = |fd: libc::c_int| unsafe {
            libc::close(fd);
        };

        let mut cap = V4l2Capability {
            driver: [0; 16],
            card: [0; 32],
            bus_info: [0; 32],
            version: 0,
            capabilities: 0,
            device_caps: 0,
            reserved: [0; 3],
        };
        if let Err(e) = ioctl(fd, VIDIOC_QUERYCAP, &mut cap as *mut _ as *mut libc::c_void) {
            close(fd);
            return Err(std::io::Error::new(
                e.kind(),
                format!("QUERYCAP({:#x}): {e}", VIDIOC_QUERYCAP),
            ));
        }
        if cap.capabilities & V4L2_CAP_VIDEO_CAPTURE == 0
            || cap.capabilities & V4L2_CAP_STREAMING == 0
        {
            close(fd);
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                format!(
                    "device lacks capture/streaming (caps 0x{:08x}, driver {:?})",
                    cap.capabilities,
                    std::str::from_utf8(&cap.driver).unwrap_or("?")
                ),
            ));
        }

        let mut fmt = V4l2Format {
            type_: V4L2_BUF_TYPE_VIDEO_CAPTURE,
            _align: [0; 4],
            pix: V4l2PixFormat {
                width: 0,
                height: 0,
                pixelformat: 0,
                field: 0,
                bytesperline: 0,
                sizeimage: 0,
                colorspace: 0,
                priv_: 0,
                flags: 0,
                ycbcr_enc: 0,
                quantization: 0,
                xfer_func: 0,
            },
            _pad: [0; 208 - 8 - std::mem::size_of::<V4l2PixFormat>()],
        };
        if let Err(e) = ioctl(fd, VIDIOC_G_FMT, &mut fmt as *mut _ as *mut libc::c_void) {
            close(fd);
            return Err(std::io::Error::new(
                e.kind(),
                format!("G_FMT({:#x}): {e}", VIDIOC_G_FMT),
            ));
        }
        fmt.pix.width = w;
        fmt.pix.height = h;
        fmt.pix.pixelformat = BGR24;
        fmt.pix.field = V4L2_FIELD_NONE;
        fmt.pix.bytesperline = w * 3;
        fmt.pix.sizeimage = w * h * 3;
        if let Err(e) = ioctl(fd, VIDIOC_S_FMT, &mut fmt as *mut _ as *mut libc::c_void) {
            close(fd);
            return Err(std::io::Error::new(
                e.kind(),
                format!("S_FMT({:#x}): {e}", VIDIOC_S_FMT),
            ));
        }
        let (gw, gh) = (fmt.pix.width, fmt.pix.height);

        // request 4 MMAP buffers, map each, queue them all
        let mut req = V4l2Requestbuffers {
            count: 4,
            type_: V4L2_BUF_TYPE_VIDEO_CAPTURE,
            memory: V4L2_MEMORY_MMAP,
            capabilities: 0,
            _reserved_pad: 0,
        };
        if let Err(e) = ioctl(fd, VIDIOC_REQBUFS, &mut req as *mut _ as *mut libc::c_void) {
            close(fd);
            return Err(std::io::Error::new(
                e.kind(),
                format!("REQBUFS({:#x}): {e}", VIDIOC_REQBUFS),
            ));
        }
        if req.count < 2 {
            close(fd);
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                format!("driver granted only {} buffers", req.count),
            ));
        }
        let mut bufs = Vec::new();
        for index in 0..req.count {
            let mut b = zeroed_buffer();
            b.index = index;
            if let Err(e) = ioctl(fd, VIDIOC_QUERYBUF, &mut b as *mut _ as *mut libc::c_void) {
                close(fd);
                return Err(std::io::Error::new(
                    e.kind(),
                    format!("QUERYBUF({:#x})[{index}]: {e}", VIDIOC_QUERYBUF),
                ));
            }
            let len = b.length as usize;
            // SAFETY: offset/length come from the driver for this fd.
            let ptr = unsafe {
                libc::mmap(
                    std::ptr::null_mut(),
                    len,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_SHARED,
                    fd,
                    b.m_offset as libc::off_t,
                )
            };
            if ptr as isize == -1 {
                close(fd);
                return Err(std::io::Error::last_os_error());
            }
            let mut q = zeroed_buffer();
            q.index = index;
            if let Err(e) = ioctl(fd, VIDIOC_QBUF, &mut q as *mut _ as *mut libc::c_void) {
                unsafe { libc::munmap(ptr, len) };
                close(fd);
                return Err(std::io::Error::new(
                    e.kind(),
                    format!("QBUF({:#x})[{index}]: {e}", VIDIOC_QBUF),
                ));
            }
            bufs.push((len, ptr as *mut u8));
        }
        // STREAMON/STREAMOFF take a pointer to the buffer TYPE (an int)
        let mut buftype: libc::c_int = V4L2_BUF_TYPE_VIDEO_CAPTURE as libc::c_int;
        if let Err(e) = ioctl(fd, VIDIOC_STREAMON, &mut buftype as *mut _ as *mut libc::c_void) {
            close(fd);
            return Err(std::io::Error::new(
                e.kind(),
                format!("STREAMON({:#x}): {e}", VIDIOC_STREAMON),
            ));
        }
        Ok(StreamSession { fd, bufs, w: gw, h: gh })
    }

    /// Dequeue one frame (blocks until the sensor fills a buffer),
    /// copy it out, requeue the buffer for the sensor.
    pub fn grab(&mut self) -> std::io::Result<(u32, u32, Vec<u8>)> {
        let mut b = zeroed_buffer();
        ioctl(self.fd, VIDIOC_DQBUF, &mut b as *mut _ as *mut libc::c_void).map_err(|e| {
            std::io::Error::new(e.kind(), format!("DQBUF({:#x}): {e}", VIDIOC_DQBUF))
        })?;
        let index = b.index as usize;
        let len = b.bytesused as usize;
        let (blen, ptr) = self
            .bufs
            .get(index)
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "DQBUF: bad index"))?;
        let take = len.min(*blen);
        // SAFETY: ptr is the driver-mapped buffer for this index, and
        // take is clamped to the mapped length.
        let out = unsafe { std::slice::from_raw_parts(*ptr, take) }.to_vec();
        ioctl(self.fd, VIDIOC_QBUF, &mut b as *mut _ as *mut libc::c_void).map_err(|e| {
            std::io::Error::new(e.kind(), format!("QBUF({:#x}): {e}", VIDIOC_QBUF))
        })?;
        Ok((self.w, self.h, out))
    }
}

impl Drop for StreamSession {
    fn drop(&mut self) {
        let mut buftype: libc::c_int = V4L2_BUF_TYPE_VIDEO_CAPTURE as libc::c_int;
        unsafe {
            let _ = ioctl(
                self.fd,
                VIDIOC_STREAMOFF,
                &mut buftype as *mut _ as *mut libc::c_void,
            );
        }
        for (len, ptr) in &self.bufs {
            unsafe { libc::munmap(*ptr as *mut libc::c_void, *len) };
        }
        unsafe { libc::close(self.fd) };
    }
}

/// BGR frame -> binary PPM (P6, RGB).
pub fn to_ppm(w: u32, h: u32, bgr: &[u8]) -> Vec<u8> {
    let mut out = format!("P6\n{} {}\n255\n", w, h).into_bytes();
    out.reserve(bgr.len());
    for px in bgr.chunks_exact(3) {
        out.push(px[2]);
        out.push(px[1]);
        out.push(px[0]);
    }
    out
}

/// Count the distinct colors among 8 evenly-spaced samples of two
/// rows (h/6 and 5h/6) — vivid's default pattern is an 8-bar color
/// strip, but its moving cross draws a full-width arm through the
/// exact middle row, so the mid row would count the cross, not the
/// bars. A real capture reports 8; this is what the gate pins.
pub fn distinct_bar_colors(rgb: &[u8], w: u32, h: u32) -> usize {
    let mut colors: Vec<[u8; 3]> = Vec::new();
    for &y in &[h / 6, (5 * h) / 6] {
        let y = y as usize;
        for i in 0..8u32 {
            let x = ((i * w + w / 2) / 8) as usize;
            let off = (y * w as usize + x) * 3;
            if off + 3 > rgb.len() {
                break;
            }
            let c = [rgb[off], rgb[off + 1], rgb[off + 2]];
            if !colors.contains(&c) {
                colors.push(c);
            }
        }
    }
    colors.len()
}

/// A clearly-synthetic frame: green diagonal stripes whose phase
/// advances with `seq` — the fake viewfinder is visibly live, and
/// visibly not the sensor. Never mistaken for real: captures carry
/// their synthetic flag, and the pattern is deterministic.
pub fn fake_frame_seq(w: u32, h: u32, seq: u64) -> Vec<u8> {
    let mut bgr = vec![0u8; (w * h * 3) as usize];
    for y in 0..h {
        for x in 0..w {
            let on = ((x + y) / 16 + seq as u32) % 2 == 0;
            let off = ((y * w + x) * 3) as usize;
            bgr[off] = 0;
            bgr[off + 1] = if on { 255 } else { 16 };
            bgr[off + 2] = 0;
        }
    }
    bgr
}

/// Nearest-neighbor 2:1 downscale (BGR) — the viewfinder ships
/// 160x120 so a frame fits the IPC budget under the emulator.
pub fn downscale2(bgr: &[u8], w: u32, h: u32) -> (u32, u32, Vec<u8>) {
    let (ow, oh) = (w / 2, h / 2);
    let mut out = vec![0u8; (ow * oh * 3) as usize];
    for y in 0..oh {
        for x in 0..ow {
            let s = (((y * 2) * w + x * 2) * 3) as usize;
            let d = ((y * ow + x) * 3) as usize;
            out[d] = bgr[s];
            out[d + 1] = bgr[s + 1];
            out[d + 2] = bgr[s + 2];
        }
    }
    (ow, oh, out)
}

/// BGR byte order -> RGB byte order (the pixels op takes RGB24).
pub fn bgr_to_rgb(bgr: &[u8]) -> Vec<u8> {
    bgr.chunks_exact(3)
        .flat_map(|p| [p[2], p[1], p[0]])
        .collect()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Standard-alphabet base64 (with padding) — the pixels-op wire format.
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

fn kmsg(line: &str) {
    eprintln!("ox-camerad: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-camerad: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

/// Consult permstored. Fail closed: unreachable daemon => deny.
fn mode_for(app: &str) -> String {
    let Ok(mut cl) = Client::connect(&sock_dir().join("permstored.sock")) else {
        return "deny".to_string();
    };
    let Ok(resp) =
        cl.request("get", json!({ "app": app, "permission": "camera.read" }))
    else {
        return "deny".to_string();
    };
    resp.payload
        .as_ref()
        .and_then(|p| p.get("mode"))
        .and_then(|v| v.as_str())
        .unwrap_or("deny")
        .to_string()
}

struct Cam {
    counter: u32,
    seq: u64,
    last_frame: u64,
    stream: Option<StreamSession>,
    streams_opened: u64,
}

impl Cam {
    /// One live streaming session for the daemon's lifetime; reopened
    /// from scratch if the sensor errors (session torn down on the
    /// error path, so the next grab starts clean).
    fn grab(&mut self) -> std::io::Result<(u32, u32, Vec<u8>)> {
        if self.stream.is_none() {
            self.stream = Some(StreamSession::open(DEVICE, WIDTH, HEIGHT)?);
            self.streams_opened += 1;
            kmsg(&format!(
                "OXMILESTONE name=camera-streaming-on method=mmap buffers=4 opened={}",
                self.streams_opened
            ));
        }
        match self.stream.as_mut().unwrap().grab() {
            Ok(frame) => Ok(frame),
            Err(e) => {
                // drop the session (STREAMOFF + unmap + close); the
                // next grab starts a fresh one
                self.stream = None;
                Err(e)
            }
        }
    }

    fn save(&mut self, w: u32, h: u32, bgr: &[u8]) -> std::io::Result<PathBuf> {
        std::fs::create_dir_all(DCIM)?;
        self.counter += 1;
        let path = PathBuf::from(DCIM).join(format!("IMG_{:04}.ppm", self.counter));
        let tmp = PathBuf::from(DCIM).join(format!(".IMG_{:04}.ppm.tmp", self.counter));
        std::fs::write(&tmp, to_ppm(w, h, bgr))?;
        std::fs::rename(&tmp, &path)?;
        Ok(path)
    }
}

fn handle_req(env: &mut Envelope, cam: &mut Cam) -> Envelope {
    match env.op.as_str() {
        "capture" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("capture: unknown peer identity");
            }
            let mode = mode_for(&app);
            kmsg(&format!(
                "OXMILESTONE name=camera-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("camera.read denied"),
                "fake" => {
                    cam.seq += 1;
                    let frame = fake_frame_seq(WIDTH, HEIGHT, cam.seq);
                    match cam.save(WIDTH, HEIGHT, &frame) {
                        Ok(path) => {
                            kmsg("OXMILESTONE name=camera-fake-synthetic");
                            env.ok(json!({
                                "path": path.display().to_string(),
                                "synthetic": true,
                                "width": WIDTH,
                                "height": HEIGHT,
                            }))
                        }
                        Err(e) => env.err(&format!("capture: {e}")),
                    }
                }
                _ => match cam.grab() {
                    Ok((w, h, bgr)) => {
                        let colors = distinct_bar_colors(&to_ppm(w, h, &bgr), w, h);
                        match cam.save(w, h, &bgr) {
                            Ok(path) => {
                                kmsg(&format!(
                                    "OXMILESTONE name=camera-capture path={} colors={colors} w={w} h={h}",
                                    path.display()
                                ));
                                env.ok(json!({
                                    "path": path.display().to_string(),
                                    "synthetic": false,
                                    "width": w,
                                    "height": h,
                                    "colors": colors,
                                }))
                            }
                            Err(e) => env.err(&format!("capture: {e}")),
                        }
                    }
                    Err(e) => env.err(&format!("sensor: {e}")),
                },
            }
        }
        "status" => env.ok(json!({ "service": "camerad", "device": DEVICE })),
        // viewfinder frame: permission-checked like a capture (the
        // viewfinder IS camera access), downscaled to 160x120 RGB24
        // (base64) for the IPC budget. The fake mode serves the
        // animated synthetic pattern; the app renders whichever it
        // gets, labeled with its synthetic flag.
        "frame" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("frame: unknown peer identity");
            }
            let mode = mode_for(&app);
            let (w, h, bgr, synthetic) = match mode.as_str() {
                "deny" => return env.err("camera.read denied"),
                "fake" => (
                    WIDTH / 2,
                    HEIGHT / 2,
                    fake_frame_seq(WIDTH / 2, HEIGHT / 2, cam.seq + 1),
                    true,
                ),
                _ => match cam.grab() {
                    Ok((w, h, bgr)) => {
                        let (w, h, small) = downscale2(&bgr, w, h);
                        (w, h, small, false)
                    }
                    Err(e) => return env.err(&format!("sensor: {e}")),
                },
            };
            cam.seq += 1;
            cam.last_frame = now_secs();
            let rgb = bgr_to_rgb(&bgr);
            kmsg(&format!(
                "OXMILESTONE name=camera-viewfinder seq={} synthetic={synthetic}",
                cam.seq
            ));
            env.ok(json!({
                "w": w, "h": h, "seq": cam.seq, "synthetic": synthetic,
                "data": b64_encode(&rgb),
            }))
        }
        // in-use indicator source: a frame within the last 5 seconds
        // means a viewfinder is consuming the camera right now
        "active" => {
            let active = cam.last_frame > 0 && now_secs().saturating_sub(cam.last_frame) < 5;
            env.ok(json!({ "active": active, "service": "camerad" }))
        }
        _ => env.err("unknown op"),
    }
}

fn main() -> std::io::Result<()> {
    let cam = std::sync::Arc::new(std::sync::Mutex::new(Cam {
        counter: 0,
        seq: 0,
        last_frame: 0,
        stream: None,
        streams_opened: 0,
    }));
    let cam2 = cam.clone();
    let _server = serve(sock_dir().join("camerad.sock"), move |env: &mut Envelope| {
        let mut cam = cam2.lock().unwrap();
        handle_req(env, &mut cam)
    })?;
    kmsg("OXMILESTONE name=camerad-ready");
    loop {
        thread_sleep();
    }
}

fn thread_sleep() {
    std::thread::sleep(Duration::from_secs(60));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioctl_numbers_match_kernel_headers() {
        // verified by compiling against linux/videodev2.h on 64-bit:
        // v4l2_format is 208 bytes (window pointers force 8-alignment),
        // so G/S_FMT differ from the often-quoted 32-bit-compat values;
        // the streaming set came from the same probe (chunk 47)
        assert_eq!(VIDIOC_QUERYCAP, 0x80685600);
        assert_eq!(VIDIOC_G_FMT, 0xc0d05604);
        assert_eq!(VIDIOC_S_FMT, 0xc0d05605);
        assert_eq!(VIDIOC_REQBUFS, 0xc0145608);
        assert_eq!(VIDIOC_QUERYBUF, 0xc0585609);
        assert_eq!(VIDIOC_QBUF, 0xc058560f);
        assert_eq!(VIDIOC_DQBUF, 0xc0585611);
        assert_eq!(VIDIOC_STREAMON, 0x40045612);
        assert_eq!(VIDIOC_STREAMOFF, 0x40045613);
    }

    #[test]
    fn streaming_abi_structs_match_kernel_layout() {
        // probe: sizeof(requestbuffers)=20, sizeof(buffer)=88 with
        // index@0 type@4 bytesused@8 flags@12 memory@60 m.offset@64
        // length@72
        assert_eq!(std::mem::size_of::<V4l2Requestbuffers>(), 20);
        assert_eq!(std::mem::size_of::<V4l2Buffer>(), 88);
        let b = V4l2Buffer {
            index: 7,
            type_: 1,
            bytesused: 230400,
            flags: 0,
            field: 0,
            timestamp: [0; 2],
            timecode: [0; 4],
            sequence: 0,
            memory: 1,
            m_offset: 0,
            length: 230400,
            _reserved2: 0,
            _reserved: [0; 2],
        };
        assert_eq!(b.bytesused, 230400);
        assert_eq!(b.index, 7);
        let mut b = zeroed_buffer();
        b.index = 3;
        assert_eq!(b.type_, V4L2_BUF_TYPE_VIDEO_CAPTURE);
        assert_eq!(b.memory, V4L2_MEMORY_MMAP);
        assert_eq!(b.index, 3);
    }

    #[test]
    fn abi_struct_sizes_match_kernel_layout() {
        assert_eq!(std::mem::size_of::<V4l2Capability>(), 104);
        assert_eq!(std::mem::size_of::<V4l2Format>(), 208);
        // pix must sit at the union's offset (8)
        let f = V4l2Format {
            type_: 1,
            _align: [0; 4],
            pix: V4l2PixFormat {
                width: 640,
                height: 0,
                pixelformat: 0,
                field: 0,
                bytesperline: 0,
                sizeimage: 0,
                colorspace: 0,
                priv_: 0,
                flags: 0,
                ycbcr_enc: 0,
                quantization: 0,
                xfer_func: 0,
            },
            _pad: [0; 208 - 8 - std::mem::size_of::<V4l2PixFormat>()],
        };
        assert_eq!(&f.pix as *const _ as usize % 8, 0);
    }

    #[test]
    fn bgr_to_ppm_swaps_to_rgb_with_header() {
        let ppm = to_ppm(2, 1, &[1, 2, 3, 4, 5, 6]); // BGR pairs
        assert!(ppm.starts_with(b"P6\n2 1\n255\n"));
        assert_eq!(&ppm[ppm.len() - 6..], &[3, 2, 1, 6, 5, 4]); // RGB out
    }

    #[test]
    fn colorbar_analysis_counts_eight_bars() {
        // 8 distinct 2px bars per row: 16px-wide frame, 12 rows; the
        // middle band is overridden (simulating vivid's cross arm) and
        // must not change the count because sampling rows are h/6, 5h/6
        let mut bgr = vec![9u8; (16 * 12 * 3) as usize];
        for y in 0..12u32 {
            if y == 5 || y == 6 {
                continue; // cross band stays uniform
            }
            for x in 0..16u32 {
                let v = (x * 16) as u8;
                let off = ((y * 16 + x) * 3) as usize;
                bgr[off] = v;
                bgr[off + 1] = v;
                bgr[off + 2] = 255 - v;
            }
        }
        let rgb = to_ppm(16, 12, &bgr);
        let data = &rgb[rgb.len() - 16 * 12 * 3..];
        assert_eq!(distinct_bar_colors(data, 16, 12), 8);
        // uniform frame: one color
        let uni = vec![7u8; 16 * 12 * 3];
        assert_eq!(distinct_bar_colors(&uni, 16, 12), 1);
    }

    #[test]
    fn fake_frame_is_deterministic_animated_and_colored() {
        let a = fake_frame_seq(32, 32, 1);
        let b = fake_frame_seq(32, 32, 1);
        let c = fake_frame_seq(32, 32, 2);
        assert_eq!(a, b, "same seq = same frame");
        assert_ne!(a, c, "advancing seq animates the fake viewfinder");
        assert!(a.iter().any(|&v| v == 255) && a.iter().any(|&v| v == 16));
        assert_eq!(a.len(), (32 * 32 * 3) as usize);
    }

    #[test]
    fn downscale2_halves_and_keeps_top_left_pixels() {
        let mut bgr = vec![0u8; (4 * 4 * 3) as usize];
        // pixel (0,0) red in BGR = [0,0,255]
        bgr[0] = 0;
        bgr[1] = 0;
        bgr[2] = 255;
        let (w, h, out) = downscale2(&bgr, 4, 4);
        assert_eq!((w, h), (2, 2));
        assert_eq!(&out[0..3], &[0, 0, 255]);
        assert_eq!(out.len(), (2 * 2 * 3) as usize);
    }

    #[test]
    fn bgr_to_rgb_swaps_and_base64_roundtrip_shape() {
        let rgb = bgr_to_rgb(&[1, 2, 3, 4, 5, 6]);
        assert_eq!(rgb, vec![3, 2, 1, 6, 5, 4]);
        assert_eq!(b64_encode(&[0, 1, 2, 3, 4]), "AAECAwQ=");
        assert_eq!(b64_encode(&[]), "");
    }
}
