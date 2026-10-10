#!/usr/bin/env python3
"""paydemo: print the whole receipt store so gates can compare receipts
recorded in earlier boots against the current listing."""

path = "rust/crates/oxctl/src/main.rs"
with open(path, "r", encoding="utf-8", newline="") as f:
    text = f.read().replace("\r\n", "\n")

old = '''            let mut got: Option<serde_json::Value> = None;
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
            }'''
new = '''            let mut found = false;
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
assert text.count(old) == 1, f"anchor found {text.count(old)}x"
with open(path, "w", encoding="utf-8", newline="") as f:
    f.write(text.replace(old, new))
print("patched", path)
