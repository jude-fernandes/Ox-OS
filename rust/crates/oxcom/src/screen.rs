// Consumed by the gui-feature-gated paths (and tests); dead without
// the feature, hence the module-level allow.
#![allow(dead_code)]

//! Pure screen model for oxcom: background gradient + client draw ops.
//! No DRM dependency — applied directly to the mapped dumb buffer, so the
//! whole layer is unit-testable on any host. All painting is region-aware:
//! damage tracking renders only the changed region each frame.

use crate::font;
use serde_json::Value;

/// An inclusive-exclusive pixel region, clamped to >= 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Region {
    pub x0: u32,
    pub y0: u32,
    pub x1: u32,
    pub y1: u32,
}

impl Region {
    pub fn full(w: u32, h: u32) -> Region {
        Region { x0: 0, y0: 0, x1: w, y1: h }
    }

    pub fn rect(x: u32, y: u32, w: u32, h: u32) -> Region {
        Region {
            x0: x,
            y0: y,
            x1: x.saturating_add(w),
            y1: y.saturating_add(h),
        }
    }

    /// Overlap of both regions (empty if disjoint).
    pub fn intersect(&self, other: &Region) -> Region {
        Region {
            x0: self.x0.max(other.x0),
            y0: self.y0.max(other.y0),
            x1: self.x1.min(other.x1),
            y1: self.y1.min(other.y1),
        }
    }

    /// Bounding box of both regions.
    pub fn union(&self, other: &Region) -> Region {
        Region {
            x0: self.x0.min(other.x0),
            y0: self.y0.min(other.y0),
            x1: self.x1.max(other.x1),
            y1: self.y1.max(other.y1),
        }
    }

    pub fn area(&self) -> u64 {
        (self.x1.saturating_sub(self.x0) as u64) * (self.y1.saturating_sub(self.y0) as u64)
    }

    pub fn is_empty(&self) -> bool {
        self.x1 <= self.x0 || self.y1 <= self.y0
    }
}

/// One client draw operation. Coordinates are in framebuffer pixels.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Rect { x: u32, y: u32, w: u32, h: u32, rgb: u32 },
    Text { x: u32, y: u32, rgb: u32, s: String, scale: u32 },
    /// Raw RGB24 pixel block (base64 in the JSON op), drawn at scale —
    /// the viewfinder primitive.
    Pixels { x: u32, y: u32, w: u32, h: u32, scale: u32, data: Vec<u8> },
}

fn json_u32(v: &Value, key: &str) -> Result<Option<u32>, String> {
    match v.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(n)) => n
            .as_u64()
            .map(|u| Some(u as u32))
            .ok_or_else(|| format!("{}: not a u32", key)),
        Some(_) => Err(format!("{}: not a number", key)),
    }
}

/// Standard-alphabet base64 decode (no padding required). Returns None
/// on any character outside the alphabet or an impossible length.
pub fn b64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a') as u32 + 26),
            b'0'..=b'9' => Some((c - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes: Vec<u8> = s.bytes().collect();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    let mut acc: u32 = 0;
    let mut nbits: u32 = 0;
    for b in bytes {
        if b == b'=' {
            continue;
        }
        acc = (acc << 6) | val(b)?;
        nbits += 6;
        if nbits >= 8 {
            nbits -= 8;
            out.push((acc >> nbits) as u8);
            acc &= (1 << nbits) - 1;
        }
    }
    Some(out)
}

/// Parse the `draw` op payload: `{"ops": [{"t":"rect", x,y,w,h,rgb},
/// {"t":"text", x,y,rgb,s,scale}]}`. Unknown keys are ignored; the first
/// error aborts the whole batch (atomic — a rejected draw changes nothing).
pub fn parse_ops(payload: &Value) -> Result<Vec<Op>, String> {
    let items = payload
        .get("ops")
        .and_then(|v| v.as_array())
        .ok_or("payload.ops: missing array")?;
    let mut ops = Vec::with_capacity(items.len());
    for item in items {
        let t = item.get("t").and_then(|v| v.as_str()).unwrap_or("");
        let rgb = json_u32(item, "rgb")?.unwrap_or(0xFFFFFF);
        match t {
            "rect" => ops.push(Op::Rect {
                x: json_u32(item, "x")?.unwrap_or(0),
                y: json_u32(item, "y")?.unwrap_or(0),
                w: json_u32(item, "w")?.unwrap_or(0),
                h: json_u32(item, "h")?.unwrap_or(0),
                rgb,
            }),
            "text" => ops.push(Op::Text {
                x: json_u32(item, "x")?.unwrap_or(0),
                y: json_u32(item, "y")?.unwrap_or(0),
                rgb,
                s: item
                    .get("s")
                    .and_then(|v| v.as_str())
                    .ok_or("text.s: missing string")?
                    .to_string(),
                scale: json_u32(item, "scale")?.unwrap_or(2).max(1),
            }),
            "pixels" => ops.push(Op::Pixels {
                x: json_u32(item, "x")?.unwrap_or(0),
                y: json_u32(item, "y")?.unwrap_or(0),
                w: json_u32(item, "w")?.unwrap_or(0),
                h: json_u32(item, "h")?.unwrap_or(0),
                scale: json_u32(item, "scale")?.unwrap_or(1).max(1),
                data: b64_decode(
                    item.get("data")
                        .and_then(|v| v.as_str())
                        .ok_or("pixels.data: missing base64")?,
                )
                .ok_or("pixels.data: bad base64")?,
            }),
            other => return Err(format!("unknown op type {:?}", other)),
        }
    }
    Ok(ops)
}

fn put_pixel(buf: &mut [u8], w: u32, h: u32, pitch: u32, x: u32, y: u32, rgb: u32, clip: Region) {
    if x >= w || y >= h || x < clip.x0 || y < clip.y0 || x >= clip.x1 || y >= clip.y1 {
        return; // clip to screen, the damage region, and the window rect
    }
    let off = (y * pitch + x * 4) as usize;
    if off + 3 >= buf.len() {
        return;
    }
    // dumb-buffer format is BGRX on little-endian virtio-gpu
    buf[off] = (rgb & 0xFF) as u8; // B
    buf[off + 1] = ((rgb >> 8) & 0xFF) as u8; // G
    buf[off + 2] = ((rgb >> 16) & 0xFF) as u8; // R
    buf[off + 3] = 0; // X
}

/// Paint the background gradient, restricted to `region`.
pub fn paint_gradient(buf: &mut [u8], w: u32, h: u32, pitch: u32, region: Region) {
    let full = Region::full(w, h);
    let c = region.intersect(&full); // clamp to screen
    for y in c.y0..c.y1 {
        let g = ((y * 255) / h.max(1)) as u8;
        for x in c.x0..c.x1 {
            let r = ((x * 255) / w.max(1)) as u8;
            put_pixel(buf, w, h, pitch, x, y, (r as u32) << 16 | (g as u32) << 8 | 0x40, c);
        }
    }
}

/// Apply draw ops onto the buffer (painter's algorithm). Ops coordinates
/// are translated by (`dx`, `dy`) first — window-local ops use the window
/// origin — and clipped to the absolute `clip` region ∩ screen bounds.
pub fn apply(
    buf: &mut [u8],
    w: u32,
    h: u32,
    pitch: u32,
    dx: u32,
    dy: u32,
    clip: Region,
    ops: &[Op],
) {
    let lim = clip.intersect(&Region::full(w, h));
    for op in ops {
        match op {
            Op::Rect { x, y, w: rw, h: rh, rgb } => {
                let x0 = dx.saturating_add(*x).max(lim.x0);
                let y0 = dy.saturating_add(*y).max(lim.y0);
                let x1 = dx.saturating_add(*x).saturating_add(*rw).min(lim.x1);
                let y1 = dy.saturating_add(*y).saturating_add(*rh).min(lim.y1);
                for yy in y0..y1 {
                    for xx in x0..x1 {
                        put_pixel(buf, w, h, pitch, xx, yy, *rgb, lim);
                    }
                }
            }
            Op::Text { x, y, rgb, s, scale } => {
                let (mut cx, mut cy) = (dx.saturating_add(*x), dy.saturating_add(*y));
                for ch in s.chars() {
                    if ch == '\n' {
                        cy += 8 * scale;
                        cx = dx.saturating_add(*x);
                        continue;
                    }
                    font::glyph(ch, *scale, |gx, gy| {
                        put_pixel(buf, w, h, pitch, cx + gx, cy + gy, *rgb, lim);
                    });
                    cx += 8 * scale;
                }
            }
            Op::Pixels { x, y, w: pw, h: ph, scale, data } => {
                // RGB24 rows; each source pixel paints a scale×scale
                // block. Truncated data paints what it has (the
                // viewfinder is best-effort by contract).
                for sy in 0..*ph {
                    for sx in 0..*pw {
                        let o = ((sy * *pw + sx) * 3) as usize;
                        if o + 2 >= data.len() {
                            continue;
                        }
                        // incoming RGB24 -> dumb buffer BGRX
                        let rgb = (data[o] as u32) << 16
                            | (data[o + 1] as u32) << 8
                            | data[o + 2] as u32;
                        let bx = dx.saturating_add(*x) + sx * scale;
                        let by = dy.saturating_add(*y) + sy * scale;
                        for yy in 0..*scale {
                            for xx in 0..*scale {
                                put_pixel(buf, w, h, pitch, bx + xx, by + yy, rgb, lim);
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Encode a BGRX framebuffer (the same layout the DRM dumb buffer
/// uses) as a binary PPM (P6, RGB) — the guest-side screendump format.
/// QEMU's own screendump dies permanently with the first guest
/// suspend/resume (host surface lost while every guest-side ioctl
/// stays healthy), so the compositor renders its own scene snapshot
/// to disk instead.
pub fn ppm_bytes(buf: &[u8], w: u32, h: u32, pitch: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(20 + (w * h * 3) as usize);
    out.extend_from_slice(format!("P6\n{w} {h}\n255\n").as_bytes());
    for y in 0..h {
        let row = (y * pitch) as usize;
        for x in 0..w {
            let o = row + (x * 4) as usize;
            if o + 2 < buf.len() {
                out.push(buf[o + 2]); // R
                out.push(buf[o + 1]); // G
                out.push(buf[o]); // B
            } else {
                out.extend_from_slice(&[0, 0, 0]);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buf(w: u32, h: u32) -> (Vec<u8>, u32) {
        (vec![0u8; (w * h * 4) as usize], w * 4)
    }

    fn px(buf: &[u8], pitch: u32, x: u32, y: u32) -> [u8; 4] {
        let o = (y * pitch + x * 4) as usize;
        [buf[o], buf[o + 1], buf[o + 2], buf[o + 3]]
    }

    #[test]
    fn region_math() {
        let a = Region::rect(2, 3, 4, 5);
        let b = Region::rect(5, 1, 4, 4);
        let u = a.union(&b);
        assert_eq!((u.x0, u.y0, u.x1, u.y1), (2, 1, 9, 8));
        assert_eq!(a.area(), 20);
        assert!(Region::rect(5, 5, 0, 5).is_empty());
    }

    #[test]
    fn ppm_encodes_bgrx_as_rgb() {
        // 2x1 BGRX buffer: one pure-red pixel, one pure-blue pixel.
        let buf = [0u8, 0, 255, 0, 255, 0, 0, 0];
        let ppm = ppm_bytes(&buf, 2, 1, 8);
        let header = b"P6\n2 1\n255\n";
        assert_eq!(&ppm[..header.len()], &header[..]);
        assert_eq!(&ppm[header.len()..], &[255, 0, 0, 0, 0, 255]);
    }

    #[test]
    fn gradient_is_deterministic_and_lit() {
        let (mut b, p) = buf(8, 4);
        paint_gradient(&mut b, 8, 4, p, Region::full(8, 4));
        assert_eq!(px(&b, p, 0, 0), [0x40, 0x00, 0x00, 0x00]);
        assert_eq!(px(&b, p, 7, 3), [0x40, 191, 223, 0x00]);
    }

    #[test]
    fn gradient_region_paints_only_region() {
        let (mut b, p) = buf(8, 4);
        paint_gradient(&mut b, 8, 4, p, Region::rect(2, 1, 3, 2));
        assert_eq!(px(&b, p, 0, 0), [0, 0, 0, 0], "outside untouched");
        assert_eq!(px(&b, p, 2, 1), [0x40, 63, 63, 0x00], "inside painted");
        assert_eq!(px(&b, p, 4, 2), [0x40, 127, 127, 0x00]);
        assert_eq!(px(&b, p, 5, 1), [0, 0, 0, 0], "x past region untouched");
    }

    #[test]
    fn rect_paints_and_clips() {
        let (mut b, p) = buf(8, 4);
        paint_gradient(&mut b, 8, 4, p, Region::full(8, 4));
        apply(
            &mut b,
            8,
            4,
            p,
            0,
            0,
            Region::full(8, 4),
            &[Op::Rect { x: 6, y: 2, w: 10, h: 10, rgb: 0x112233 }],
        );
        assert_eq!(px(&b, p, 6, 2), [0x33, 0x22, 0x11, 0x00]);
        assert_eq!(px(&b, p, 7, 3), [0x33, 0x22, 0x11, 0x00]); // clipped at edge
        assert_eq!(px(&b, p, 5, 2), [0x40, 127, 159, 0x00]); // outside untouched
    }

    #[test]
    fn region_clips_ops() {
        let (mut b, p) = buf(16, 4);
        paint_gradient(&mut b, 16, 4, p, Region::full(16, 4));
        // rect spans x 0..16 but the damage region is only x 8..16
        apply(
            &mut b,
            16,
            4,
            p,
            0,
            0,
            Region::rect(8, 0, 8, 4),
            &[Op::Rect { x: 0, y: 0, w: 16, h: 4, rgb: 0xAAAAAA }],
        );
        assert_eq!(px(&b, p, 7, 2), [0x40, 127, 111, 0x00], "left of region");
        assert_eq!(px(&b, p, 8, 2)[0], 0xAA, "inside region");
        assert_eq!(px(&b, p, 15, 2)[0], 0xAA);
    }

    #[test]
    fn text_renders_glyph_pixels() {
        let (mut b, p) = buf(32, 16);
        paint_gradient(&mut b, 32, 16, p, Region::full(32, 16));
        apply(
            &mut b,
            32,
            16,
            p,
            0,
            0,
            Region::full(32, 16),
            &[Op::Text { x: 1, y: 1, rgb: 0xFFFFFF, s: "A".into(), scale: 1 }],
        );
        let on = b.iter().filter(|&&v| v == 0xFF).count();
        assert!(on > 10, "expected glyph pixels, got {}", on);
    }

    #[test]
    fn parse_ops_full_and_atomic() {
        let ops = parse_ops(&serde_json::json!({"ops": [
            {"t": "rect", "x": 1, "w": 3, "rgb": 255},
            {"t": "text", "s": "hi", "y": 9},
        ]}))
        .unwrap();
        assert_eq!(ops.len(), 2);
        assert_eq!(ops[0], Op::Rect { x: 1, y: 0, w: 3, h: 0, rgb: 255 });
        assert_eq!(ops[1], Op::Text { x: 0, y: 9, rgb: 0xFFFFFF, s: "hi".into(), scale: 2 });
        // first bad op aborts the batch
        assert!(parse_ops(
            &serde_json::json!({"ops": [{"t": "rect"}, {"t": "wat"}]})
        )
        .is_err());
        assert!(parse_ops(&serde_json::json!({"ops": "no"})).is_err());
    }

    #[test]
    fn pixels_op_parses_blits_and_rejects_bad_base64() {
        // "AAECAwQFBgc" -> bytes 00 01 02 03 04 05 (two RGB pixels)
        let ops = parse_ops(&serde_json::json!({"ops": [
            {"t": "pixels", "x": 5, "y": 6, "w": 2, "h": 2, "scale": 2, "data": "AAECAwQFBgc"},
        ]}))
        .unwrap();
        assert_eq!(ops.len(), 1);
        let buf_w = 32u32;
        let mut buf = vec![0u8; (buf_w * 16 * 4) as usize];
        apply(&mut buf, buf_w, 16, buf_w * 4, 0, 0, Region::full(buf_w, 16), &ops);
        // pixel (x,y) = rgb(o+2, o+1, o); scale 2 -> 2x2 blocks at (5,6)
        let px = |x: u32, y: u32| -> [u8; 3] {
            let o = ((y * buf_w + x) * 4) as usize;
            [buf[o + 2], buf[o + 1], buf[o]]
        };
        assert_eq!(px(5, 6), [0, 1, 2]);
        assert_eq!(px(6, 7), [0, 1, 2]); // scale block
        assert_eq!(px(7, 6), [3, 4, 5]); // second source pixel
        // corrupt base64 is rejected atomically
        assert!(parse_ops(
            &serde_json::json!({"ops": [{"t": "pixels", "data": "not*base64!"}]})
        )
        .is_err());
    }
}
