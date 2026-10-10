//! oxctl: guest CLI for Ox IPC daemons. A debug/gate tool — no daemon
//! logic lives here. Examples:
//!   oxctl paymentsd status
//!   oxctl paymentsd handoff-build '{"amount_minor":1250,"merchant":"x"}'
//!   oxctl paydemo 1250 cafe.example        # build a tag, then "tap" it
use ox_ipc::Client;
use ox_pay_proto::sha256::sha256;
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

fn connect_retry(p: &PathBuf) -> Option<Client> {
    for _ in 0..50 {
        if let Ok(c) = Client::connect(p) {
            return Some(c);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

fn print_resp(resp: &ox_ipc::Envelope) {
    match serde_json::to_string(resp) {
        Ok(s) => println!("{s}"),
        Err(e) => println!("{{\"error\":\"serialize: {e}\"}}"),
    }
}

fn kmsg(msg: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .write(true)
        .open("/dev/kmsg")
    {
        let _ = writeln!(f, "<6>oxctl: {msg}");
    }
    println!("{msg}");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("slot-confirm") => {
            // chunk 77: confirm this boot for the ACTIVE slot — clear the
            // unconfirmed-boot counter and bump the slot's boot count.
            // The metadata device comes from the kernel cmdline
            // (ox.slotmeta=/dev/...); integrity is the sha256 over the
            // first 104 bytes stored at 104 (the ox-slotmeta.h format).
            let meta_dev = std::fs::read_to_string("/proc/cmdline")
                .ok()
                .and_then(|c| {
                    c.split_whitespace()
                        .find(|t| t.starts_with("ox.slotmeta="))
                        .map(|t| t["ox.slotmeta=".len()..].to_string())
                })
                .unwrap_or_default();
            if meta_dev.is_empty() {
                kmsg("slot-confirm: no ox.slotmeta= on the cmdline (not a slot boot)");
                return; // non-slot layouts confirm nothing
            }
            let mut buf = [0u8; 4096];
            {
                use std::io::{Read, Seek, SeekFrom, Write};
                let mut f = std::fs::OpenOptions::new()
                    .read(true)
                    .write(true)
                    .open(&meta_dev)
                    .unwrap_or_else(|e| {
                        eprintln!("oxctl: cannot open {meta_dev}: {e}");
                        std::process::exit(3);
                    });
                f.read_exact(&mut buf).unwrap_or_else(|e| {
                    eprintln!("oxctl: metadata read failed: {e}");
                    std::process::exit(3);
                });
                if &buf[0..4] != b"OXSB" {
                    eprintln!("oxctl: not an ox slot-metadata block");
                    std::process::exit(4);
                }
                let sum = sha256(&buf[..104]);
                if sum != buf[104..136] {
                    eprintln!("oxctl: metadata integrity FAILED — refusing to confirm");
                    std::process::exit(5);
                }
                let active = u32::from_le_bytes(buf[8..12].try_into().unwrap());
                let attempts = u32::from_le_bytes(buf[12..16].try_into().unwrap());
                if attempts == 0 {
                    kmsg(&format!(
                        "OXMILESTONE name=slot-already-confirmed slot={active}"
                    ));
                    return;
                }
                buf[12..16].copy_from_slice(&0u32.to_le_bytes());
                let cnt_off = if active == 0 { 16 } else { 20 };
                let cnt = u32::from_le_bytes(buf[cnt_off..cnt_off + 4].try_into().unwrap()) + 1;
                buf[cnt_off..cnt_off + 4].copy_from_slice(&cnt.to_le_bytes());
                let sum = sha256(&buf[..104]);
                buf[104..136].copy_from_slice(&sum);
                f.seek(SeekFrom::Start(0)).unwrap();
                f.write_all(&buf[..136]).unwrap();
                f.sync_all().unwrap();
                kmsg(&format!(
                    "OXMILESTONE name=slot-confirmed slot={active} count={cnt}"
                ));
            }
        }
        Some("paydemo") => {
            // Simulate a tap: build a handoff tag, then read it back —
            // the read triggers the wallet's confirmation UI.
            let amount = args.get(2).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
            let merchant = args.get(3).cloned().unwrap_or_default();
            let reference = args.get(4).cloned();
            let mut c = match connect_retry(&sock_dir().join("paymentsd.sock")) {
                Some(c) => c,
                None => {
                    eprintln!("oxctl: paymentsd not reachable");
                    std::process::exit(3);
                }
            };
            let built = c
                .request(
                    "handoff-build",
                    json!({ "amount_minor": amount, "merchant": merchant,
                            "ref": reference }),
                )
                .expect("request handoff-build");
            print_resp(&built);
            let tag = built
                .payload
                .as_ref()
                .and_then(|p| p.get("tag_hex"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            let Some(tag_hex) = tag else {
                eprintln!("oxctl: handoff-build failed");
                std::process::exit(4);
            };
            let read = c.request("handoff-read", json!({ "tag_hex": tag_hex })).expect("request handoff-read");
            print_resp(&read);
            if read.error.is_some() {
                std::process::exit(5);
            }
            // The wallet records the payment only after the user accepts on
            // the compositor. Poll for the receipt COUNT to grow past the
            // pre-tap baseline: a matching receipt from an earlier boot must
            // not satisfy this poll before this boot's payment lands.
            let baseline = c
                .request("list_receipts", serde_json::Value::Null)
                .ok()
                .and_then(|r| r.payload)
                .and_then(|p| p.get("receipts").and_then(|v| v.as_array()).map(|a| a.len()))
                .unwrap_or(0);
            let mut found = false;
            for _ in 0..240 {
                std::thread::sleep(std::time::Duration::from_millis(500));
                let Ok(resp) = c.request("list_receipts", serde_json::Value::Null) else {
                    continue;
                };
                let hits = resp
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("receipts"))
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default();
                if hits.len() > baseline {
                    // Print the whole store: the persistence gate compares
                    // receipts recorded in earlier boots against this list.
                    println!(
                        "ox-pay receipts: {}",
                        serde_json::to_string(&hits).unwrap_or_default()
                    );
                    found = true;
                    break;
                }
            }
            if !found {
                eprintln!("oxctl: receipt not recorded (timeout)");
                std::process::exit(6);
            }
        }
        Some(daemon) if args.len() >= 3 => {
            let op = args[2].clone();
            let payload: serde_json::Value = args
                .get(3)
                .map(|s| serde_json::from_str(s).expect("payload must be JSON"))
                .unwrap_or(serde_json::Value::Null);
            let mut c = match connect_retry(&sock_dir().join(format!("{daemon}.sock"))) {
                Some(c) => c,
                None => {
                    eprintln!("oxctl: {daemon} not reachable");
                    std::process::exit(3);
                }
            };
            let resp = c.request(&op, payload).expect("request");
            print_resp(&resp);
            if resp.error.is_some() {
                std::process::exit(5);
            }
        }
        _ => {
            eprintln!("usage: oxctl <daemon> <op> [json-payload]");
            eprintln!("       oxctl paydemo <amount_minor> <merchant> [ref]");
            std::process::exit(2);
        }
    }
}
