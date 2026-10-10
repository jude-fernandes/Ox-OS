// Consumed by the gui-feature-gated paths (and tests); dead without
// the feature, hence the module-level allow.
#![allow(dead_code)]

//! Shared evdev plumbing (always compiled): raw record parsing and
//! axis queries. Readers in `pointer.rs` (absolute) and `keys.rs`
//! (keyboards) build on this.

use std::fs::File;
use std::os::fd::AsRawFd;

pub const EVENT_SIZE: usize = 24;
pub const EV_KEY: u16 = 0x01;
pub const EV_ABS: u16 = 0x03;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const VAL_DOWN: i32 = 1;
pub const VAL_REPEAT: i32 = 2;

/// One evdev record, parsed from 24 raw bytes (aarch64 layout).
pub fn parse_event(raw: &[u8; EVENT_SIZE]) -> (u16, u16, i32) {
    let ty = u16::from_le_bytes([raw[16], raw[17]]);
    let code = u16::from_le_bytes([raw[18], raw[19]]);
    let val = i32::from_le_bytes([raw[20], raw[21], raw[22], raw[23]]);
    (ty, code, val)
}

/// EVIOCGABS(axis) request number: _IOR('E', 0x40 + axis, input_absinfo).
pub fn eviocgabs(axis: u16) -> u32 {
    (2u32 << 30) | (24u32 << 16) | (0x45u32 << 8) | (0x40u32 + axis as u32)
}

/// Returns the axis maximum (input_absinfo.maximum), or None if the device
/// has no such absolute axis.
pub fn abs_axis_max(file: &File, axis: u16) -> Option<i32> {
    let mut info = [0u8; 24];
    let rc = unsafe {
        libc::ioctl(file.as_raw_fd(), eviocgabs(axis) as _, info.as_mut_ptr())
    };
    if rc < 0 {
        return None;
    }
    let le = |o: usize| i32::from_le_bytes([info[o], info[o + 1], info[o + 2], info[o + 3]]);
    Some(le(8)) // maximum
}

/// True if the device has both absolute X and Y axes (pointer/touch class).
pub fn has_abs_axes(file: &File) -> bool {
    abs_axis_max(file, ABS_X).is_some() && abs_axis_max(file, ABS_Y).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eviocgabs_numbers_match_uapi() {
        assert_eq!(eviocgabs(ABS_X), 0x8018_4540);
        assert_eq!(eviocgabs(ABS_Y), 0x8018_4541);
    }

    #[test]
    fn event_parse_matches_layout() {
        let mut raw = [0u8; EVENT_SIZE];
        raw[16] = 0x03; // EV_ABS
        raw[18] = 0x01; // ABS_Y
        raw[20] = 0x39;
        raw[21] = 0x30; // value = 12345 (LE)
        let (ty, code, val) = parse_event(&raw);
        assert_eq!((ty, code, val), (0x03, 0x01, 12345));
    }
}
