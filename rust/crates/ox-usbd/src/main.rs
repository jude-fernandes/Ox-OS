//! ox-usbd: the USB daemon — watches the USB bus via /sys/bus/usb/devices
//! and enforces the BadUSB defense: EVERY new device is QUARANTINED
//! (kernel `authorized=0`, which unbinds its drivers) until explicitly
//! authorized. A plugged cable charges and enumerates; it does not get
//! drivers, block devices, or input until the user allows it.
//!
//! IPC surface:
//!   devices {app} -> permstored `usb.read` (fail-closed):
//!     deny  (default, incl. unbound/unreachable) -> refused
//!     fake  -> a clearly SYNTHETIC device list
//!     grant -> the real list with per-device authorized state
//!   authorize {dev, allow} -> the SYSTEM surface (root oxctl — the
//!     same trust level as the user tapping "allow" in a dialog).
//!     Journaled; unknown devices refused.
//!
//! Every add/quarantine/authorize/remove is journaled to the kernel
//! ring so gates see the physical event lifecycle.
use ox_ipc::{serve, Client, Envelope};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BUS_DIR: &str = "/sys/bus/usb/devices";

fn kmsg(line: &str) {
    // stderr + kernel ring, same dual-channel rule as the other daemons;
    // the kernel ring also mirrors to the console so gates see milestones.
    eprintln!("ox-usbd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>ox-usbd: {}", line);
    }
}

fn sock_dir() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
}

fn permstored_sock() -> PathBuf {
    sock_dir().join("permstored.sock")
}

/// Consult permstored. Fail closed: unreachable daemon => deny.
fn mode_for(app: &str, permission: &str) -> String {
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

/// Bus entries of interest: plain device dirs ("1-1", "2-1.2") — not
/// interfaces (they contain ':'), not root hubs ("usb1", "usb2").
pub fn is_device_entry(name: &str) -> bool {
    !name.is_empty() && !name.contains(':') && !name.starts_with("usb")
}

fn sysfs_str(dev: &str, attr: &str) -> String {
    std::fs::read_to_string(format!("{BUS_DIR}/{dev}/{attr}"))
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn read_authorized(dev: &str) -> bool {
    sysfs_str(dev, "authorized") == "1"
}

/// Quarantine (or release) a device through the kernel's USB
/// authorization switch. authorized=0 makes the kernel unbind the
/// device's drivers — no block devices, no HID, no anything.
pub fn set_authorized(dev: &str, allow: bool) -> std::io::Result<()> {
    std::fs::write(format!("{BUS_DIR}/{dev}/authorized"), if allow { "1" } else { "0" })
}

#[derive(Clone, Debug, PartialEq)]
pub struct DevInfo {
    pub dev: String,
    pub vid: String,
    pub pid: String,
    pub product: String,
    pub authorized: bool,
}

impl DevInfo {
    pub fn to_json(&self) -> Value {
        json!({
            "dev": self.dev,
            "vid": self.vid,
            "pid": self.pid,
            "product": self.product,
            "authorized": self.authorized,
        })
    }
}

/// Read one device's identity from sysfs.
pub fn read_dev_info(dev: &str) -> DevInfo {
    DevInfo {
        dev: dev.to_string(),
        vid: sysfs_str(dev, "idVendor"),
        pid: sysfs_str(dev, "idProduct"),
        product: sysfs_str(dev, "product"),
        authorized: read_authorized(dev),
    }
}

/// List the bus's device entries (sorted for deterministic gates).
pub fn bus_devices() -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(BUS_DIR)
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| is_device_entry(n))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

/// Clearly synthetic device list for fake mode.
fn fake_devices() -> Value {
    json!([
        {"dev": "fake-1", "vid": "f4ce", "pid": "0001",
         "product": "synthetic device (no usb.read grant)", "authorized": false},
    ])
}

struct Shared {
    devices: Mutex<BTreeMap<String, DevInfo>>,
    scanning: AtomicBool,
}

fn handle_req(env: &mut Envelope, sh: Arc<Shared>) -> Envelope {
    match env.op.as_str() {
        "devices" => {
            // Chunk 68: kernel-verified peer comm, not the payload claim.
            let app = ox_ipc::peer_comm();
            if app.is_empty() {
                return env.err("devices: unknown peer identity");
            }
            let mode = mode_for(&app, "usb.read");
            kmsg(&format!(
                "OXMILESTONE name=usb-consult app={app} mode={mode}"
            ));
            match mode.as_str() {
                "deny" => env.err("usb.read denied"),
                "fake" => env.ok(json!({
                    "devices": fake_devices(),
                    "synthetic": true,
                })),
                _ => {
                    let map = sh.devices.lock().unwrap();
                    let list: Vec<Value> =
                        map.values().map(|d| d.to_json()).collect();
                    env.ok(json!({
                        "devices": list,
                        "synthetic": false,
                        "count": list.len(),
                    }))
                }
            }
        }
        // The SYSTEM surface: root oxctl acting for the user (the same
        // trust level as the dialog tap). Unknown devices refused.
        "authorize" => {
            let get = |k: &str| {
                env.payload
                    .as_ref()
                    .and_then(|p| p.get(k))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string()
            };
            let dev = get("dev");
            let allow = env
                .payload
                .as_ref()
                .and_then(|p| p.get("allow"))
                .and_then(|v| v.as_bool())
                .unwrap_or(true);
            let known = sh.devices.lock().unwrap().contains_key(&dev);
            if !known {
                return env.err(&format!("authorize: unknown device {dev}"));
            }
            if let Err(e) = set_authorized(&dev, allow) {
                return env.err(&format!("authorize: {e}"));
            }
            let mut map = sh.devices.lock().unwrap();
            if let Some(d) = map.get_mut(&dev) {
                d.authorized = allow;
                kmsg(&format!(
                    "OXMILESTONE name={} dev={} vid={} pid={}",
                    if allow { "usb-authorized" } else { "usb-deauthorized" },
                    d.dev, d.vid, d.pid
                ));
            }
            env.ok(json!({ "dev": dev, "authorized": allow }))
        }
        "status" => {
            // liveness probe (no permission needed): no payload leaves
            env.ok(json!({
                "service": "ox-usbd",
                "devices": sh.devices.lock().unwrap().len(),
                "scanning": sh.scanning.load(Ordering::Relaxed),
            }))
        }
        _ => env.err("unknown op (devices|authorize|status)"),
    }
}

fn main() {
    let sh = Arc::new(Shared {
        devices: Mutex::new(BTreeMap::new()),
        scanning: AtomicBool::new(true),
    });

    // Bus watcher: default-deny. Every NEW device is journaled and
    // immediately quarantined; the startup sweep quarantines anything
    // already connected (the daemon's policy starts at its boot).
    {
        let sh = Arc::clone(&sh);
        std::thread::spawn(move || loop {
            for dev in bus_devices() {
                let known = sh.devices.lock().unwrap().contains_key(&dev);
                if known {
                    continue;
                }
                let mut info = read_dev_info(&dev);
                kmsg(&format!(
                    "OXMILESTONE name=usb-added dev={} vid={} pid={} product={}",
                    info.dev, info.vid, info.pid, info.product
                ));
                // With usbcore.authorized_default=0 the KERNEL delivers
                // the device already quarantined; the write below is
                // belt-and-braces for boots without that cmdline. The
                // journal records WHO enforced it — and a failed
                // enforcement is never reported as quarantined.
                let kernel_default = !info.authorized;
                let mut enforced = kernel_default;
                if !enforced && set_authorized(&dev, false).is_ok() {
                    enforced = true;
                }
                info.authorized = !enforced;
                if enforced {
                    kmsg(&format!(
                        "OXMILESTONE name=usb-quarantined dev={} vid={} pid={} default={}",
                        info.dev, info.vid, info.pid, kernel_default
                    ));
                } else {
                    kmsg(&format!(
                        "OXMILESTONE name=usb-quarantine-failed dev={} vid={} pid={}",
                        info.dev, info.vid, info.pid
                    ));
                }
                sh.devices.lock().unwrap().insert(dev, info);
            }
            // removals: entries gone from the bus
            let live: Vec<String> = bus_devices();
            let mut map = sh.devices.lock().unwrap();
            let gone: Vec<String> = map
                .keys()
                .filter(|d| !live.contains(d))
                .cloned()
                .collect();
            for d in gone {
                map.remove(&d);
                kmsg(&format!("OXMILESTONE name=usb-removed dev={d}"));
            }
            drop(map);
            std::thread::sleep(Duration::from_millis(500));
        });
    }

    let hsh = Arc::clone(&sh);
    let handle = serve(sock_dir().join("usbd.sock"), move |env: &mut Envelope| {
        handle_req(env, Arc::clone(&hsh))
    });

    match handle {
        Ok(_h) => {
            kmsg("OXMILESTONE name=usbd-ready");
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        }
        Err(e) => {
            kmsg(&format!("FATAL: cannot serve IPC: {e}"));
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bus_entry_filter() {
        assert!(is_device_entry("1-1"));
        assert!(is_device_entry("2-1.2"));
        assert!(!is_device_entry("1-1:1.0"), "interface dir has a colon");
        assert!(!is_device_entry("usb1"), "root hub");
        assert!(!is_device_entry(""));
    }

    #[test]
    fn fake_devices_are_clearly_synthetic() {
        let v = fake_devices();
        let arr = v.as_array().unwrap();
        assert!(!arr.is_empty());
        for d in arr {
            assert!(d["dev"].as_str().unwrap().starts_with("fake-"));
            assert!(d["product"].as_str().unwrap().contains("synthetic"));
            assert!(!d["authorized"].as_bool().unwrap());
        }
    }

    #[test]
    fn devinfo_json_carries_authorized_state() {
        let d = DevInfo {
            dev: "1-1".into(),
            vid: "46f4".into(),
            pid: "0001".into(),
            product: "QEMU USB HARDDRIVE".into(),
            authorized: false,
        };
        let j = d.to_json();
        assert_eq!(j["vid"], "46f4");
        assert_eq!(j["authorized"], false);
    }
}
