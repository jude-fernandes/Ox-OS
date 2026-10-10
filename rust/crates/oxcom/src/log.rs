//! Console logging used by every daemon: stderr lands on the serial
//! console; /dev/kmsg carries it into the kernel ring (quiet filters the
//! ring off the console, which is why both channels matter).

pub fn kmsg(line: &str) {
    use std::io::Write;
    eprintln!("oxcom: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>oxcom: {}", line);
    }
}
