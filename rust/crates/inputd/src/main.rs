//! inputd: the first Ox OS app — a console window. Keys arrive already
//! routed by oxcom (focus-follows-click / newest-window-wins) via the
//! blocking `key-recv` IPC op; this daemon just renders. That split is the
//! Phase-2 architecture proof: apps never touch input devices.
use ox_ipc::Client;
use serde_json::json;
use std::io::Result;
use std::path::PathBuf;
use std::time::Duration;

fn socket_path() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock")
}

fn connect_retry(sock: &PathBuf) -> Option<Client> {
    for _ in 0..50 {
        if let Ok(c) = Client::connect(sock) {
            return Some(c);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

/// Build the `window-commit` payload for the console view.
fn console_ops(input: &str, history: &[String], w: u32, h: u32) -> serde_json::Value {
    let line_h = 16u64;
    let pad = 12u64;
    let rows = 4u64;
    let _win_h = pad * 2 + rows * line_h;
    let mut lines: Vec<String> = history.iter().rev().take(3).rev().cloned().collect();
    lines.push(format!("> {}", input));
    let mut ops = vec![json!({"t": "rect", "x": 0, "y": 0, "w": w, "h": h, "rgb": 0x0A0E14})];
    for (i, line) in lines.iter().enumerate() {
        let y = pad + i as u64 * line_h;
        let rgb = if i + 1 == lines.len() { 0x9FE8FF } else { 0x6B7A8C };
        ops.push(json!({"t": "text", "x": pad, "y": y, "rgb": rgb, "s": line, "scale": 2}));
    }
    json!({ "ops": ops })
}

fn main() -> Result<()> {
    let sock = socket_path();
    let mut cl = match connect_retry(&sock) {
        Some(c) => c,
        None => {
            eprintln!("inputd: no compositor at {} — parking", sock.display());
            #[allow(unreachable_code)]
            {
                park();
                return Ok(());
            }
        }
    };
    let st = cl.request("status", json!(null))?;
    let payload = st
        .payload
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "no payload"))?;
    let (w, h) = (
        payload.get("w").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
        payload.get("h").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
    );
    if w == 0 || h == 0 {
        eprintln!("inputd: compositor has no display — parking");
        #[allow(unreachable_code)]
        {
            park();
            return Ok(());
        }
    }

    let (win_x, win_y, win_w, win_h) = (48u64, (h as u64) - 160, (w as u64) - 96, 120);
    let resp = cl.request(
        "window-new",
        json!({"x": win_x, "y": win_y, "w": win_w, "h": win_h}),
    )?;
    let win_id = resp
        .payload
        .as_ref()
        .and_then(|p| p.get("id"))
        .and_then(|v| v.as_u64())
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::Other, "window-new: no id"))?;
    eprintln!("inputd: console window {} ({}x{})", win_id, win_w, win_h);
    // The console only takes focus when nothing else holds it: a polite
    // request is refused while a real app (e.g. a payment card) is focused.
    let resp = cl.request("window-focus", json!({ "id": win_id, "steal": false }))?;
    if resp.error.is_some() {
        eprintln!("inputd: focus request refused: {:?}", resp.error);
    } else if resp
        .payload
        .as_ref()
        .and_then(|p| p.get("granted"))
        .and_then(|v| v.as_bool())
        == Some(false)
    {
        eprintln!("inputd: console not focused — another window holds focus");
    }

    let commit = |cl: &mut Client, input: &str, history: &[String]| -> Result<()> {
        let payload = console_ops(input, history, win_w as u32, win_h as u32);
        let resp = cl.request("window-commit", json!({"id": win_id, "ops": payload["ops"]}))?;
        if resp.error.is_some() {
            eprintln!("inputd: commit refused: {:?}", resp.error);
        }
        Ok(())
    };
    commit(&mut cl, "", &[])?;

    let mut input = String::new();
    let mut history: Vec<String> = Vec::new();
    loop {
        let resp = cl.request(
            "key-recv",
            json!({ "window": win_id, "timeout_ms": 4000 }),
        )?;
        let Some(ev) = resp
            .payload
            .as_ref()
            .and_then(|p| p.get("event"))
            .filter(|e| !e.is_null())
            .cloned()
        else {
            continue; // poll timeout — no keys for our window
        };
        let ch = ev
            .get("ch")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        match ch.as_str() {
            "\n" => {
                let line = std::mem::take(&mut input);
                eprintln!("inputd: line committed: {:?}", line);
                history.push(line);
            }
            "\x08" => {
                input.pop();
            }
            "" => {}
            c => {
                input.push_str(c);
                eprintln!("inputd: key '{}'", c);
            }
        }
        commit(&mut cl, &input, &history)?;
    }
}

fn park() -> ! {
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn console_renders_prompt_and_history() {
        let v = console_ops("hi", &["first".to_string(), "second".to_string()], 800, 120);
        let ops = v.get("ops").and_then(|o| o.as_array()).unwrap();
        // bg + 3 text rows (2 history + prompt)
        assert_eq!(ops.len(), 4);
        let last = ops.last().unwrap();
        assert_eq!(last["s"], "> hi");
        assert_eq!(last["y"], 12 + 2 * 16);
    }
}
