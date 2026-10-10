#!/usr/bin/env python3
"""paydemo: wait for the receipt COUNT to grow past the pre-tap baseline —
otherwise a receipt from an earlier boot (same amount) satisfies the poll
before this boot's payment is even accepted."""

path = "rust/crates/oxctl/src/main.rs"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''            // The wallet records the payment only after the user accepts on
            // the compositor; poll the receipt store for this amount.
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
                if hits
                    .iter()
                    .any(|r| r.get("amount_minor").and_then(|v| v.as_u64()) == Some(amount))
                {
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
            }'''
new = '''            // The wallet records the payment only after the user accepts on
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
            }'''
assert text.count(old) == 1, text.count(old)
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
