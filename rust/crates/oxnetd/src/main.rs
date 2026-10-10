//! netd: Phase-2 network daemon. Owns interface bring-up on the virtual
//! target (slirp defaults) and the local DNS forwarder every app is
//! pointed at. The network is the OS's other egress channel, so — like
//! oxmodemd — every lookup is journaled to the kernel log before it
//! leaves, and name policy (deny list + refusal canary) is enforced at
//! the resolver layer. Per-app socket enforcement arrives with the
//! netfilter integration; this is the resolver-level policy ground work.
//!
//! Milestones (kmsg → console): netd-up, netd-dns-ok, netd-policy-ok.
use ox_ipc::{serve, Envelope};
use serde_json::json;
use std::io::{self, Write as _};
use std::net::UdpSocket;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const LISTEN: &str = "127.0.0.1:53";
/// Slirp DNS proxy on the virtual target; hardware learns this via DHCP.
pub const DEFAULT_UPSTREAM: &str = "10.0.2.3:53";
/// Names under this suffix are refused by a built-in canary rule: it
/// exercises the refusal path on every boot without implying any
/// product-level blocklist.
pub const CANARY_SUFFIX: &str = ".refused.ox";
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(3);

fn kmsg(line: &str) {
    eprintln!("netd: {}", line);
    if let Ok(mut f) = std::fs::OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = writeln!(f, "<6>netd: {}", line);
    }
}

/// First non-loopback interface from sysfs, if any.
pub fn find_iface() -> Option<String> {
    let mut names: Vec<String> = std::fs::read_dir("/sys/class/net")
        .ok()?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n != "lo")
        .collect();
    names.sort();
    names.into_iter().next()
}

/// Extract the question name from a DNS query (labels until root).
/// Questions are never compressed, so a plain label walk is correct.
pub fn query_name(pkt: &[u8]) -> Option<String> {
    if pkt.len() < 12 {
        return None;
    }
    let mut i = 12usize;
    let mut labels: Vec<String> = Vec::new();
    loop {
        if i >= pkt.len() {
            return None;
        }
        let l = pkt[i] as usize;
        if l == 0 {
            break;
        }
        if l > 63 || i + 1 + l > pkt.len() {
            return None;
        }
        labels.push(String::from_utf8_lossy(&pkt[i + 1..i + 1 + l]).to_string());
        i += 1 + l;
    }
    if labels.is_empty() {
        return None;
    }
    Some(labels.join("."))
}

/// Does a queried name match a deny suffix (suffix or exact)?
pub fn name_denied(name: &str, deny: &[String]) -> bool {
    deny.iter()
        .any(|d| name == d || name.ends_with(&format!(".{d}")))
}

/// Response RCODE (low nibble of byte 3).
pub fn response_rcode(pkt: &[u8]) -> Option<u8> {
    if pkt.len() < 4 {
        return None;
    }
    Some(pkt[3] & 0x0F)
}

/// Turn a query packet into a REFUSED response: echo id + question,
/// set QR|RA and RCODE=5, zero the counts.
pub fn build_refused(query: &[u8]) -> Vec<u8> {
    let mut out = query.to_vec();
    out[2] = 0x81; // QR=1, RD=1 (echoed opcode bits cleared)
    out[3] = (out[3] & 0xF0) | 5; // RA=0, RCODE=REFUSED
    if out.len() >= 12 {
        out[6] = 0;
        out[7] = 0; // ANCOUNT
        out[8] = 0;
        out[9] = 0; // NSCOUNT
        out[10] = 0;
        out[11] = 0; // ARCOUNT
    }
    out
}

/// Build a minimal A query for `name` (RD=1, QTYPE=A, QCLASS=IN).
pub fn build_query(name: &str, id: u16) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(&id.to_be_bytes());
    out.extend_from_slice(&[0x01, 0x00, 0, 1, 0, 1, 0, 0, 0, 0]); // RD, QD=1
    for label in name.split('.') {
        if label.is_empty() || label.len() > 63 {
            return None;
        }
        out.push(label.len() as u8);
        out.extend_from_slice(label.as_bytes());
    }
    out.push(0);
    out.extend_from_slice(&[0, 1, 0, 1]); // A, IN
    Some(out)
}

/// Walk past a (possibly compressed) DNS name starting at `i`.
fn skip_name(pkt: &[u8], mut i: usize) -> Option<usize> {
    loop {
        let l = *pkt.get(i)?;
        if l & 0xC0 == 0xC0 {
            return Some(i + 2);
        }
        if l == 0 {
            return Some(i + 1);
        }
        i += 1 + l as usize;
        if i > pkt.len() {
            return None;
        }
    }
}

/// Collect A-record addresses from a response.
pub fn parse_answers(pkt: &[u8]) -> Vec<String> {
    if pkt.len() < 12 {
        return vec![];
    }
    let qd = u16::from_be_bytes([pkt[4], pkt[5]]) as usize;
    let an = u16::from_be_bytes([pkt[6], pkt[7]]) as usize;
    let mut ips = Vec::new();
    let mut i = 12usize;
    for _ in 0..qd {
        match skip_name(pkt, i) {
            Some(next) => i = next + 4, // qtype + qclass
            None => return ips,
        }
    }
    for _ in 0..an {
        i = match skip_name(pkt, i) {
            Some(next) => next,
            None => return ips,
        };
        if i + 10 > pkt.len() {
            return ips;
        }
        let rtype = u16::from_be_bytes([pkt[i], pkt[i + 1]]);
        let rdlen = u16::from_be_bytes([pkt[i + 8], pkt[i + 9]]) as usize;
        let rd = i + 10;
        if rtype == 1 && rdlen == 4 && rd + 4 <= pkt.len() {
            ips.push(format!(
                "{}.{}.{}.{}",
                pkt[rd],
                pkt[rd + 1],
                pkt[rd + 2],
                pkt[rd + 3]
            ));
        }
        i = rd + rdlen;
    }
    ips
}

pub struct Policy {
    pub deny: Vec<String>,
}

pub struct Journal {
    pub entries: Mutex<Vec<String>>,
    count: AtomicU64,
}

impl Journal {
    pub fn new() -> Self {
        Journal { entries: Mutex::new(Vec::new()), count: AtomicU64::new(0) }
    }
    pub fn record(&self, name: &str, verdict: &str) {
        self.count.fetch_add(1, Ordering::Relaxed);
        let mut e = self.entries.lock().unwrap();
        if e.len() >= 64 {
            e.remove(0);
        }
        e.push(format!("{name} -> {verdict}"));
    }
}

/// Forward a raw query to the upstream resolver, return its reply.
fn forward(upstream: &str, query: &[u8]) -> io::Result<Vec<u8>> {
    let sock = UdpSocket::bind("0.0.0.0:0")?;
    sock.connect(upstream)?;
    sock.send(query)?;
    let mut buf = [0u8; 1500];
    let n = sock.recv(&mut buf)?;
    Ok(buf[..n].to_vec())
}

fn main() {
    let upstream = Arc::new(
        std::env::var("OX_DNS_UPSTREAM").unwrap_or_else(|_| DEFAULT_UPSTREAM.to_string()),
    );

    // --- interface bring-up (virtual target: slirp addressing) ---
    let state = Arc::new(Mutex::new(Policy {
        deny: vec!["refused.ox".to_string()], // canary suffix, always armed
    }));
    let run = |cmd: &str| -> bool {
        std::process::Command::new("/bin/busybox")
            .args(cmd.split_whitespace())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    // Loopback must be raised before anything can bind 127.x — ox-init
    // leaves it down.
    if !run("ifconfig lo 127.0.0.1 up") {
        kmsg("warning: could not raise loopback");
    }
    match find_iface() {
        Some(iface) => {
            let ok = run(&format!("ifconfig {iface} 10.0.2.15 netmask 255.255.255.0 up"))
                && run("route add default gw 10.0.2.2");
            let _ = std::fs::write("/etc/resolv.conf", "nameserver 127.0.0.1\n");
            if ok {
                kmsg(&format!("OXMILESTONE name=netd-up iface={iface} addr=10.0.2.15"));
            } else {
                kmsg(&format!("netd-up-incomplete iface={iface}"));
            }
        }
        None => kmsg("OXMILESTONE name=netd-no-iface"),
    }

    // --- DNS forwarder thread (127.0.0.1:53) ---
    let journal = Arc::new(Journal::new());
    let policy = Arc::clone(&state);
    let upstream_fwd = Arc::clone(&upstream);
    let j = Arc::clone(&journal);
    std::thread::spawn(move || {
        let sock = match UdpSocket::bind(LISTEN) {
            Ok(s) => s,
            Err(e) => {
                kmsg(&format!("FATAL: cannot bind {LISTEN}: {e}"));
                return;
            }
        };
        kmsg("dnsd listening on 127.0.0.1:53");
        let mut buf = [0u8; 1500];
        loop {
            let (n, src) = match sock.recv_from(&mut buf) {
                Ok(x) => x,
                Err(_) => continue,
            };
            let pkt = &buf[..n];
            let Some(name) = query_name(pkt) else { continue };
            let denied = {
                let p = policy.lock().unwrap();
                name_denied(&name, &p.deny)
            };
            if denied || name.ends_with(CANARY_SUFFIX) {
                kmsg(&format!("dns journal {name} -> REFUSED (policy)"));
                j.record(&name, "REFUSED (policy)");
                let _ = sock.send_to(&build_refused(pkt), src);
                continue;
            }
            // Egress journal BEFORE anything leaves the machine.
            kmsg(&format!("dns journal {name} -> forward {upstream_fwd}"));
            j.record(&name, "forward");
            match forward(&upstream_fwd, pkt) {
                Ok(resp) => {
                    let _ = sock.send_to(&resp, src);
                }
                Err(e) => kmsg(&format!("forward failed for {name}: {e}")),
            }
        }
    });

    // --- self-test: resolve through our own forwarder ---
    {
        let journal = Arc::clone(&journal);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            let q = build_query("ox-gate.test", 0x4F58).unwrap();
            let resolved = forward_query(&q);
            let dns_ok = resolved
                .as_ref()
                .map(|r| response_rcode(r) == Some(0))
                .unwrap_or(false);
            if dns_ok {
                kmsg("OXMILESTONE name=netd-dns-ok");
            } else {
                kmsg("OXMILESTONE name=netd-dns-failed");
            }
            let canary = build_query("canary.refused.ox", 0x4F59).unwrap();
            let refused = forward_query(&canary);
            let policy_ok = refused
                .as_ref()
                .map(|r| response_rcode(r) == Some(5))
                .unwrap_or(false);
            if policy_ok {
                kmsg("OXMILESTONE name=netd-policy-ok");
            } else {
                kmsg("OXMILESTONE name=netd-policy-failed");
            }
            let _ = journal;
        });
    }

    // --- IPC surface ---
    let h_journal = Arc::clone(&journal);
    let h_policy = Arc::clone(&state);
    let upstream_ipc = Arc::clone(&upstream);
    let handle = serve("/run/ox/sockets/netd.sock", move |req: &mut Envelope| {
        match req.op.as_str() {
            "status" => {
                let iface = find_iface().unwrap_or_default();
                let j = h_journal.entries.lock().unwrap();
                req.ok(json!({
                    "iface": iface,
                    "addr": "10.0.2.15",
                    "upstream": upstream_ipc.as_str(),
                    "queries": h_journal.count.load(Ordering::Relaxed),
                    "recent": *j,
                }))
            }
            "dnsq" => {
                let name = req
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("name"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let Some(q) = build_query(&name, 0x1234) else {
                    return req.err("bad name");
                };
                match forward_query(&q) {
                    Some(resp) => req.ok(json!({
                        "rcode": response_rcode(&resp).unwrap_or(2),
                        "answers": parse_answers(&resp),
                    })),
                    None => req.err("no response"),
                }
            }
            "policy" => {
                let deny: Vec<String> = req
                    .payload
                    .as_ref()
                    .and_then(|p| p.get("deny"))
                    .and_then(|v| v.as_array())
                    .map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_str().map(String::from))
                            .collect()
                    })
                    .unwrap_or_default();
                let mut p = h_policy.lock().unwrap();
                p.deny = deny;
                req.ok(json!({ "deny": p.deny }))
            }
            _ => req.err("unknown op (status|dnsq|policy)"),
        }
    });

    match handle {
        Ok(_) => {
            kmsg("IPC up at /run/ox/sockets/netd.sock");
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

/// Send a query to our own forwarder on 127.0.0.1:53 and wait for the
/// reply (the product path — apps resolve exactly like this).
fn forward_query(query: &[u8]) -> Option<Vec<u8>> {
    let sock = UdpSocket::bind("127.0.0.1:0").ok()?;
    sock.connect(LISTEN).ok()?;
    sock.send(query).ok()?;
    let mut buf = [0u8; 1500];
    sock.set_read_timeout(Some(UPSTREAM_TIMEOUT)).ok()?;
    let n = sock.recv(&mut buf).ok()?;
    Some(buf[..n].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_query(name: &str) -> Vec<u8> {
        build_query(name, 0x1234).unwrap()
    }

    #[test]
    fn extracts_question_names() {
        assert_eq!(query_name(&test_query("ox-gate.test")).unwrap(), "ox-gate.test");
        assert_eq!(query_name(&test_query("a.b")).unwrap(), "a.b");
        assert!(query_name(&[0u8; 10]).is_none()); // too short
        // empty name is rejected by the BUILDER (test_query would unwrap-panic)
        assert!(build_query("", 0x1234).is_none());
    }

    #[test]
    fn policy_matches_suffix_and_exact() {
        let deny = vec!["evil.example".to_string()];
        assert!(name_denied("evil.example", &deny));
        assert!(name_denied("cdn.evil.example", &deny));
        assert!(!name_denied("notevil.example", &deny));
        assert!(name_denied("x.refused.ox", &["refused.ox".to_string()]));
    }

    #[test]
    fn refused_response_keeps_question_zeroes_counts() {
        let q = test_query("canary.refused.ox");
        let r = build_refused(&q);
        assert_eq!(r.len(), q.len());
        assert_eq!(response_rcode(&r), Some(5));
        assert_eq!(&r[0..2], &q[0..2]); // id echoed
        assert_eq!(query_name(&r).unwrap(), "canary.refused.ox");
    }

    #[test]
    fn parses_a_records_from_response() {
        // header
        let mut r = vec![0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0];
        // question: a.test A IN
        r.extend_from_slice(&[1, b'a', 4, b't', b'e', b's', b't', 0, 0, 1, 0, 1]);
        // answer: pointer to qname, A, IN, ttl=60, rdlen=4, 192.0.2.1
        r.extend_from_slice(&[0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1]);
        assert_eq!(parse_answers(&r), vec!["192.0.2.1"]);
        assert_eq!(response_rcode(&r), Some(0));
    }

    #[test]
    fn query_builder_rejects_bad_names() {
        assert!(build_query("", 1).is_none());
        assert!(build_query(&"x".repeat(64), 1).is_none());
    }
}
