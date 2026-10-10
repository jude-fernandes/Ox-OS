//! ox-btair: Ox's virtual Bluetooth radio server (dev target).
//!
//! Serves the kernel's hci_vhci controllers from one process: opens two
//! /dev/vhci fds (vendor handshake per fd), answers the minimal
//! BR/EDR+LE command set the kernel needs to bring an hci device up,
//! and shares LE advertising state between the two radios — when one
//! enables scanning while the other advertises, an LE Advertising
//! Report event crosses "the air". The kernel BT stack and the BlueZ
//! userspace on both sides are real; only the radio is emulated.

use std::fs::File;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const VHCI: &str = "/dev/vhci";
const HCI_COMMAND_PKT: u8 = 0x01;
const HCI_EVENT_PKT: u8 = 0x04;

/// Cross-radio shared state.
#[derive(Default)]
struct Air {
    /// radio index currently advertising (LE_Set_Advertise_Enable=1)
    advertiser: Mutex<Option<usize>>,
    /// advertising payload captured from LE_Set_Advertising_Data
    adv_data: Mutex<Vec<u8>>,
    /// radio index with scanning enabled (hcitool lescan)
    scanner: Mutex<Option<usize>>,
}

fn cc(opcode: u16, status: u8, params: &[u8]) -> Vec<u8> {
    let mut e = Vec::with_capacity(6 + params.len());
    e.push(HCI_EVENT_PKT);
    e.push(0x0e); // Command Complete
    e.push((4 + params.len()) as u8);
    e.push(0x01); // allowed command packets
    e.extend_from_slice(&opcode.to_le_bytes());
    e.push(status);
    e.extend_from_slice(params);
    e
}

fn le_meta_adv_report(addr: [u8; 6], data: &[u8]) -> Vec<u8> {
    // LE Meta Event: Advertising Report, one report, ADV_IND, public addr
    let mut e = Vec::with_capacity(15 + data.len());
    e.push(HCI_EVENT_PKT);
    e.push(0x3e); // LE Meta Event
    e.push((12 + data.len()) as u8);
    e.push(0x02); // subevent: advertising report
    e.push(0x01); // number of reports
    e.push(0x00); // event type: connectable undirected
    e.push(0x00); // address type: public
    e.extend_from_slice(&addr);
    e.push(data.len() as u8);
    e.extend_from_slice(data);
    e.push(0xc8); // rssi -56 dBm
    e
}

/// Fabricate the Command Complete RETURN PARAMS for read commands
/// (the status byte itself is added by cc()).
fn read_params(opcode: u16, idx: usize) -> Option<Vec<u8>> {
    let mut p = Vec::new();
    match opcode {
        0x1001 => {
            // Local Version Info: hci_ver, hci_rev, lmp_ver, mfr, subver
            p.extend_from_slice(&[0x0b, 0x00, 0x00, 0x0c, 0x2c, 0x01, 0x00, 0x00]);
        }
        0x1002 => {
            // Local Supported Commands: claim ONLY what we answer —
            // bit0 = Set Event Mask (0x0c01), bit2 = Reset (0x0c03).
            // Claiming anything else makes the kernel send it at init
            // and abort the whole init on our "unknown command".
            let mut c = [0u8; 64];
            c[0] = 0x05;
            p.extend_from_slice(&c);
        }
        0x1003 => {
            // Local Supported Features: byte 4 bit 6 = LE supported
            let mut f = [0u8; 8];
            f[4] = 0x40;
            p.extend_from_slice(&f);
        }
        0x1005 => {
            // Buffer Size: ACL_MTU=1021, SCO_MTU=64, ACL pkts=8, SCO pkts=4
            // (zeros here make hci_dev_open fail with EINVAL)
            p.extend_from_slice(&[0xfd, 0x03, 0x40, 0x08, 0x00, 0x04, 0x00]);
        }
        0x1009 => {
            // BD_ADDR: per-radio static, locally administered
            let mut a = [0x02u8, 0x00, 0x00, 0x00, 0x00, 0x00];
            a[5] += idx as u8;
            p.extend_from_slice(&a);
        }
        0x100a => {
            // Data Block Size
            p.extend_from_slice(&[0; 6]);
        }
        0x0c14 => {
            // Local Name
            let mut n = [0u8; 248];
            n[..8].copy_from_slice(b"Ox-Phone");
            p.extend_from_slice(&n);
        }
        0x0c23 => {
            // Class of Device
            p.extend_from_slice(&[0x00, 0x00, 0x00]);
        }
        0x2002 => {
            // LE Buffer Size: 27-byte PDUs, 1 packet
            p.extend_from_slice(&[0x1b, 0x00, 0x01]);
        }
        0x2003 => {
            // LE Local Features
            p.extend_from_slice(&[0; 8]);
        }
        0x201c => {
            // LE Supported States: all zeros (none) is accepted
            p.extend_from_slice(&[0; 8]);
        }
        _ => return None,
    }
    Some(p)
}

/// Handle one complete H4 command frame; returns bytes to write back.
fn handle(air: &Air, idx: usize, cmd: &[u8]) -> Option<Vec<u8>> {
    if cmd.len() < 4 {
        return None;
    }
    let opcode = u16::from_le_bytes([cmd[1], cmd[2]]);
    let plen = cmd[3] as usize;
    let params = &cmd[4..(4 + plen).min(cmd.len())];
    let mut out = None;
    match opcode {
        0x0c03 => out = Some(cc(opcode, 0x00, &[])), // Reset
        0x0c01 => out = Some(cc(opcode, 0x00, &[])), // Set Event Mask
        0x0c13 => out = Some(cc(opcode, 0x00, &[])), // Write Local Name
        0x0c33 => out = Some(cc(opcode, 0x00, &[])), // Host Buffer Size
        0x0c38 => out = Some(cc(opcode, 0x00, &[0x01])), // Read Num Supported IAC: 1
        0x0c39 => {
            // Read Current IAC LAP: the general inquiry LAP 0x9e8b33
            out = Some(cc(opcode, 0x00, &[0x01, 0x33, 0x8b, 0x9e]));
        }
        0x0c05 => out = Some(cc(opcode, 0x00, &[])), // Set Event Filter (clear all at init)
        0x0c16 => out = Some(cc(opcode, 0x00, &[])), // Write Conn Accept Timeout
        0x0c0d => out = Some(cc(opcode, 0x00, &[0x00, 0x00, 0x00])), // Read Stored Link Key: status + max 0
        0x0c63 | 0x2027 => out = Some(cc(opcode, 0x00, &[])), // LE Host Support
        0x2001 => out = Some(cc(opcode, 0x00, &[])), // LE Set Event Mask
        0x2005 => out = Some(cc(opcode, 0x00, &[])), // LE Set Random Address
        0x2006 => out = Some(cc(opcode, 0x00, &[])), // LE Set Adv Parameters
        0x2007 => out = Some(cc(opcode, 0x00, &[0x00])), // LE Read Adv TX Power
        0x2008 => {
            // LE Set Advertising Data: [len][data]
            if !params.is_empty() {
                let n = params[0] as usize;
                let n = n.min(params.len() - 1);
                *air.adv_data.lock().unwrap() = params[1..1 + n].to_vec();
            }
            out = Some(cc(opcode, 0x00, &[]));
        }
        0x2009 => out = Some(cc(opcode, 0x00, &[])), // LE Set Scan Response Data
        0x200a => {
            // LE Set Advertise Enable
            if params.first() == Some(&0x01) {
                *air.advertiser.lock().unwrap() = Some(idx);
            } else if *air.advertiser.lock().unwrap() == Some(idx) {
                *air.advertiser.lock().unwrap() = None;
            }
            out = Some(cc(opcode, 0x00, &[]));
        }
        0x200b => out = Some(cc(opcode, 0x00, &[])), // LE Set Scan Parameters
        0x200c => {
            // LE Set Scan Enable: [enable][filter_dup]
            if params.first() == Some(&0x01) {
                *air.scanner.lock().unwrap() = Some(idx);
            } else {
                *air.scanner.lock().unwrap() = None;
            }
            out = Some(cc(opcode, 0x00, &[]));
        }
        _ => {
            // read commands get fabricated success params; everything
            // else reports "Unknown Command", which the kernel treats
            // as an absent optional feature
            match read_params(opcode, idx) {
                Some(p) => out = Some(cc(opcode, 0x00, &p)),
                None => {
                    eprintln!("ox-btair: radio {} UNKNOWN opcode {:04x}", idx, opcode);
                    out = Some(cc(opcode, 0x01, &[]));
                }
            }
        }
    }
    out
}

/// Reader thread for one radio: block on the fd, parse H4 command
/// frames, answer each with its Command Complete.
fn serve_radio(mut fd: File, idx: usize, air: Arc<Air>) {
    // OX_BTAIR_QUIET=1 drops the per-command hex dumps (boot-selftest
    // boots: they flooded the console during every gate and starved
    // other daemons' console/serial budget under TCG). Attach/advert/
    // error lines stay.
    let quiet = std::env::var_os("OX_BTAIR_QUIET").is_some();
    let mut buf = Vec::new();
    eprintln!("ox-btair: radio {} reader running", idx);
    loop {
        let mut chunk = [0u8; 512];
        match fd.read(&mut chunk) {
            Ok(0) => {
                eprintln!("ox-btair: radio {} read EOF", idx);
                return;
            }
            Ok(n) => {
                if !quiet {
                    eprintln!("ox-btair: radio {} read {} bytes: {:02x?}", idx, n, &chunk[..n]);
                }
                buf.extend_from_slice(&chunk[..n]);
            }
            Err(ref e) => {
                eprintln!("ox-btair: radio {} read err: {}", idx, e);
                return;
            }
        }
        // re-parse pending + new bytes
        loop {
            if buf.len() < 4 {
                break;
            }
            if buf[0] != HCI_COMMAND_PKT {
                buf.remove(0);
                continue;
            }
            let plen = buf[3] as usize;
            if buf.len() < 4 + plen {
                break;
            }
            let frame: Vec<u8> = buf.drain(..4 + plen).collect();
            if let Some(resp) = handle(&air, idx, &frame) {
                if !quiet {
                    eprintln!("ox-btair: radio {} respond {} bytes: {:02x?}", idx, resp.len(), &resp[..resp.len().min(12)]);
                }
                if fd.write_all(&resp).is_err() {
                    eprintln!("ox-btair: radio {} write failed", idx);
                    return;
                }
            }
        }
    }
}

fn open_radio(idx: usize) -> Option<(File, File)> {
    let f = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(VHCI)
        .ok()?;
    // vendor handshake: [0xff][opcode 0x00 = primary BR/EDR+LE]
    let mut f = f;
    f.write_all(&[0xff, 0x00]).ok()?;
    let mut rsp = [0u8; 4];
    f.read_exact(&mut rsp).ok()?;
    if rsp[0] != 0xff || rsp[1] != 0x00 {
        return None;
    }
    eprintln!("ox-btair: radio {} attached (index {})", idx, rsp[2]);
    // writer side for cross-radio deliveries
    let w = f.try_clone().ok()?;
    Some((f, w))
}

fn main() {
    let air = Arc::new(Air::default());

    // open both controllers before spawning anything
    let mut readers = Vec::new();
    let mut writers: Vec<Option<Arc<Mutex<File>>>> = Vec::new();
    for i in 0..2 {
        match open_radio(i) {
            Some((r, w)) => {
                readers.push((r, i));
                writers.push(Some(Arc::new(Mutex::new(w))));
            }
            None => {
                eprintln!("ox-btair: radio {} attach failed", i);
                writers.push(None);
            }
        }
    }
    if readers.len() < 2 {
        eprintln!("ox-btair: not enough radios");
        std::process::exit(1);
    }

    for (r, i) in readers {
        let air = air.clone();
        thread::spawn(move || serve_radio(r, i, air));
    }

    // delivery watcher: scanner + advertiser on different radios =>
    // push advertising reports across the virtual air. Real advertisers
    // repeat continuously, and so do we: a scanner that is still
    // setting up its raw-socket event filter right after LE Set Scan
    // Enable would otherwise miss a one-shot report (the kernel drops
    // events for sockets whose filter is not set yet).
    loop {
        thread::sleep(Duration::from_millis(250));
        let scan = *air.scanner.lock().unwrap();
        let adv = *air.advertiser.lock().unwrap();
        if let (Some(s), Some(a)) = (scan, adv) {
            if s == a {
                continue;
            }
            let data = air.adv_data.lock().unwrap().clone();
            let mut addr = [0x02u8, 0x00, 0x00, 0x00, 0x00, 0x00];
            addr[5] += a as u8;
            let ev = le_meta_adv_report(addr, &data);
            if let Some(Some(w)) = writers.get(s) {
                if w.lock().unwrap().write_all(&ev).is_ok() {
                    eprintln!("ox-btair: advert radio {} -> scanner radio {}", a, s);
                }
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_complete_frame_is_well_formed() {
        let e = cc(0x0c03, 0x00, &[]);
        assert_eq!(e[0], HCI_EVENT_PKT);
        assert_eq!(e[1], 0x0e);
        assert_eq!(e[2] as usize, e.len() - 3);
        assert_eq!(&e[4..6], &0x0c03u16.to_le_bytes());
        assert_eq!(e[6], 0x00);
    }

    #[test]
    fn adv_report_frame_carries_name_payload() {
        let data = vec![0x02, 0x01, 0x06, 0x09, 0x09, b'O', b'x', b'-', b'P', b'h', b'o', b'n', b'e'];
        let e = le_meta_adv_report([2, 0, 0, 0, 0, 1], &data);
        assert_eq!(e[0], HCI_EVENT_PKT);
        assert_eq!(e[1], 0x3e);
        assert_eq!(e[2] as usize, e.len() - 3);
        assert_eq!(e[3], 0x02); // advertising report subevent
        assert_eq!(e[5], 0x00); // event type
        assert_eq!(e[13] as usize, data.len());
        assert_eq!(e[e.len() - 1], 0xc8); // rssi
    }

    #[test]
    fn reset_command_is_acknowledged() {
        let air = Air::default();
        let frame = [HCI_COMMAND_PKT, 0x03, 0x0c, 0x00];
        let resp = handle(&air, 0, &frame).expect("reset must be answered");
        assert_eq!(resp[1], 0x0e);
        assert_eq!(resp[6], 0x00); // status success
    }

    #[test]
    fn le_set_event_mask_is_acknowledged() {
        // the real kernel sends exactly this during hci init; answering
        // "unknown command" aborts the whole controller bring-up
        let air = Air::default();
        let frame = [HCI_COMMAND_PKT, 0x01, 0x20, 0x08, 0, 0, 0, 0, 0, 0, 0, 0];
        let resp = handle(&air, 0, &frame).expect("LE Set Event Mask must be answered");
        assert_eq!(resp[6], 0x00); // status success
    }

    #[test]
    fn advertise_then_scan_sets_air_state() {
        let air = Air::default();
        // radio 1 advertises (LE Set Adv Params 0x2006, Adv Data 0x2008,
        // Adv Enable 0x200a)
        let adv_param = [HCI_COMMAND_PKT, 0x06, 0x20, 0x0f];
        let adv_data = [
            HCI_COMMAND_PKT, 0x08, 0x20, 0x0e, 0x0d, 0x02, 0x01, 0x06, 0x09,
            0x09, b'O', b'x', b'-', b'P', b'h', b'o', b'n', b'e',
        ];
        let adv_en = [HCI_COMMAND_PKT, 0x0a, 0x20, 0x01, 0x01];
        assert!(handle(&air, 1, &adv_param).is_some());
        assert!(handle(&air, 1, &adv_data).is_some());
        assert!(handle(&air, 1, &adv_en).is_some());
        assert_eq!(*air.advertiser.lock().unwrap(), Some(1));
        // radio 0 enables scanning (LE Set Scan Enable 0x200c)
        let scan_en = [HCI_COMMAND_PKT, 0x0c, 0x20, 0x02, 0x01, 0x01];
        assert!(handle(&air, 0, &scan_en).is_some());
        assert_eq!(*air.scanner.lock().unwrap(), Some(0));
    }

    #[test]
    fn read_bd_addr_is_per_radio() {
        let air = Air::default();
        let f = [HCI_COMMAND_PKT, 0x09, 0x10, 0x00];
        let a = handle(&air, 0, &f).unwrap();
        let b = handle(&air, 1, &f).unwrap();
        assert_ne!(a[a.len() - 1], b[b.len() - 1]); // last address byte differs
    }
}
