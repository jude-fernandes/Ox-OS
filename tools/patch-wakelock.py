#!/usr/bin/env python3
"""Wake lock during payment confirmation: paymentsd holds a powerd wake
lock while the card is up (idle doze must not interrupt a payment)."""

def patch(path, subs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    text = text.replace("\r\n", "\n")
    for old, new in subs:
        n = text.count(old)
        assert n == 1, f"{path}: anchor found {n}x (expected 1):\n{old[:80]}"
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"patched {path} ({len(subs)} edits)")

PAY = "rust/crates/oxpaymentsd/src/main.rs"

guard = '''/// Holds a powerd wake lock for the lifetime of a confirmation card: a
/// payment decision must not be interrupted by idle doze (dropped on every
/// exit path, including timeouts).
struct WakeGuard {
    pwr: Option<Client>,
    id: String,
}
impl Drop for WakeGuard {
    fn drop(&mut self) {
        if let Some(p) = self.pwr.as_mut() {
            let _ = p.request("wake-lock", json!({ "id": self.id, "release": true }));
        }
    }
}

fn confirm_wake_lock() -> WakeGuard {
    let id = format!("paymentsd-confirm-{}", std::process::id());
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("powerd.sock");
    let pwr = connect_retry(&sock);
    if pwr.is_none() {
        eprintln!("paymentsd: powerd unreachable — confirm runs without wake lock");
    }
    WakeGuard { pwr, id }
}

/// The wallet-side confirmation flow:'''

acquire = '''    let Some(mut cl) = connect_retry(&sock) else {
        eprintln!("paymentsd: no compositor — confirmation unavailable");
        return;
    };
    let wake = confirm_wake_lock();'''

patch(PAY, [
    ("/// The wallet-side confirmation flow:", guard),
    ('''    let Some(mut cl) = connect_retry(&sock) else {
        eprintln!("paymentsd: no compositor — confirmation unavailable");
        return;
    };''', acquire),
])

# The receipts poll runs after the decision (lock released); the machine may
# doze mid-poll and resume — give it a wide margin.
patch("rust/crates/oxctl/src/main.rs", [
    ("            for _ in 0..40 {", "            for _ in 0..240 {"),
])

# Gate: wake-lock evidence is required, and the receipts wait covers a doze
# cycle after the decision.
patch("tools/pay-gate.sh", [
    ("while [ $k -lt 30 ]; do", "while [ $k -lt 60 ]; do"),
    ('say "durable receipt:"', '''grep -q "name=wake-lock-acquire id=paymentsd-confirm" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no wake lock during confirmation (idle doze can kill the flow)"; }
say "wake lock held during confirmation"
say "durable receipt:"'''),
])

print("ALL PATCHES OK")
