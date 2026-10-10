#!/usr/bin/env python3
"""Durable payment receipts: patch paymentsd (store + list op), oxctl
(paydemo lists the receipt back), and pay-gate.sh (gate checks)."""
import sys

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

helpers = '''/// Dev/demo receipt store: one JSON line per authorized payment, on the
/// persistent data volume (/data is the LUKS store mounted by stage 2).
fn data_dir() -> PathBuf {
    PathBuf::from(std::env::var("OX_DATA_DIR").unwrap_or_else(|_| "/data/ox".into()))
}

fn record_receipt(r: &ndef::PaymentRequest) -> std::io::Result<PathBuf> {
    let dir = data_dir();
    std::fs::create_dir_all(&dir)?;
    let rec = json!({
        "ts": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        "amount_minor": r.amount_minor,
        "merchant": r.merchant,
        "reference": r.reference,
    });
    let path = dir.join("receipts.jsonl");
    use std::io::Write as _;
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(f, "{rec}")?;
    Ok(path)
}

fn read_receipts() -> Vec<serde_json::Value> {
    std::fs::read_to_string(data_dir().join("receipts.jsonl"))
        .map(|s| s.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
        .unwrap_or_default()
}

fn main() -> std::io::Result<()> {'''

list_op = '''        "list_receipts" => req.ok(json!({ "receipts": read_receipts() })),
        "handoff-read" => {'''

authorized = '''                        eprintln!(
                            "OXMILESTONE name=payment-authorized amount={} merchant={}",
                            r.amount_minor, r.merchant
                        );
                        match record_receipt(&r) {
                            Ok(path) => {
                                eprintln!(
                                    "OXMILESTONE name=receipt-recorded file={}",
                                    path.display()
                                );
                            }
                            Err(e) => eprintln!("paymentsd: receipt write failed: {e}"),
                        }
                        "AUTHORIZED"'''

test = '''        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn receipts_record_and_list() {
        let dir = std::env::temp_dir().join(format!("pay-receipts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::env::set_var("OX_DATA_DIR", &dir);
        let r = ndef::PaymentRequest {
            amount_minor: 1250,
            merchant: "cafe.example".into(),
            reference: Some("order-9".into()),
        };
        let path = record_receipt(&r).unwrap();
        assert!(path.exists());
        let rs = read_receipts();
        assert_eq!(rs.len(), 1);
        assert_eq!(rs[0]["amount_minor"].as_u64(), Some(1250));
        assert_eq!(rs[0]["reference"].as_str(), Some("order-9"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}'''

patch(PAY, [
    ("fn main() -> std::io::Result<()> {", helpers),
    ('        "handoff-read" => {', list_op),
    ('''                        eprintln!(
                            "OXMILESTONE name=payment-authorized amount={} merchant={}",
                            r.amount_minor, r.merchant
                        );
                        "AUTHORIZED"''', authorized),
    ('''        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}''', test),
])

OXCTL = "rust/crates/oxctl/src/main.rs"

paydemo_poll = '''            print_resp(&read);
            if read.error.is_some() {
                std::process::exit(5);
            }
            // The wallet records the payment only after the user accepts on
            // the compositor; poll the receipt store for this amount.
            let mut got: Option<serde_json::Value> = None;
            for _ in 0..40 {
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
                if let Some(m) = hits
                    .iter()
                    .find(|r| r.get("amount_minor").and_then(|v| v.as_u64()) == Some(amount))
                {
                    got = Some(m.clone());
                    break;
                }
            }
            match got {
                Some(rec) => println!("ox-pay receipts: {rec}"),
                None => {
                    eprintln!("oxctl: receipt not recorded (timeout)");
                    std::process::exit(6);
                }
            }
        }'''

patch(OXCTL, [
    ('''            print_resp(&read);
            if read.error.is_some() {
                std::process::exit(5);
            }
        }''', paydemo_poll),
])

GATE = "tools/pay-gate.sh"

receipts_check = '''# 4b. durable receipts: the wallet writes the payment to /data and the
# paydemo client lists it back over IPC
k=0
while [ $k -lt 30 ]; do
    grep -q "name=receipt-recorded" "$LOG" 2>/dev/null \\
        && grep -q "ox-pay receipts:" "$LOG" 2>/dev/null && break
    sleep 1; k=$((k + 1))
done
grep -q "name=receipt-recorded" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "no receipt-recorded milestone (durable write failed)"; }
grep -q "ox-pay receipts:" "$LOG" || {
    tail -8 "$LOG" 2>/dev/null || true; pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
    fail "paydemo did not list the receipt back (receipt IPC failed)"; }
say "durable receipt:"
grep "name=receipt-recorded" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
grep "ox-pay receipts:" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1'''

allgreen = '''say "ALL GREEN — tap -> wallet card -> user accept -> authorized -> durable receipt"'''

patch(GATE, [
    ('''say "authorized:"
grep "name=payment-authorized" "$LOG" | tail -1 | sed 's/^/[ox-pay]   /'
pkill -f qemu-system-aarch64 >/dev/null 2>&1 || true
sleep 1''', receipts_check),
    ('say "ALL GREEN — tap -> wallet card -> user accept -> authorized"', allgreen),
])

print("ALL PATCHES OK")
