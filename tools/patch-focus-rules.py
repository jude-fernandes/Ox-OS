#!/usr/bin/env python3
"""Focus arbitration fix: polite focus (steal=false) is refused while
another window holds focus, so the dev console can no longer race a real
app (e.g. the payment card) for key routing."""

def patch(path, subs):
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read().replace("\r\n", "\n")
    for old, new in subs:
        n = text.count(old)
        assert n == 1, f"{path}: anchor found {n}x (expected 1):\n{old[:80]}"
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print(f"patched {path} ({len(subs)} edits)")

patch("rust/crates/oxcom/src/main.rs", [
    ('''        "window-focus" => match payload.get("id").and_then(|v| v.as_u64()) {
            Some(id) => {
                if scene.lock().unwrap().set_focus(id as u32) {
                    match mutate(display, scene, |_| Ok((0, scene::Dirty::Full))) {
                        Ok(_) => {
                            log::kmsg(&format!(
                                "OXMILESTONE name=window-focus id={}",
                                id
                            ));
                            req.ok(json!({ "focused": id }))
                        }
                        Err(e) => req.err(&e),
                    }
                } else {
                    req.err(&format!("no such window {}", id))
                }
            }
            None => req.err("id: missing/invalid"),''',
     '''        "window-focus" => match payload.get("id").and_then(|v| v.as_u64()) {
            Some(id) => {
                // A polite focus (steal=false) is refused while another
                // window already holds focus: background consoles must not
                // race a real app for key routing.
                let polite = !payload
                    .get("steal")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                let current = scene.lock().unwrap().focused();
                if polite && current.is_some() && current != Some(id as u32) {
                    req.ok(json!({ "granted": false, "focused": current }))
                } else if scene.lock().unwrap().set_focus(id as u32) {
                    match mutate(display, scene, |_| Ok((0, scene::Dirty::Full))) {
                        Ok(_) => {
                            log::kmsg(&format!(
                                "OXMILESTONE name=window-focus id={}",
                                id
                            ));
                            req.ok(json!({ "focused": id, "granted": true }))
                        }
                        Err(e) => req.err(&e),
                    }
                } else {
                    req.err(&format!("no such window {}", id))
                }
            }
            None => req.err("id: missing/invalid"),'''),
    ('''    fn req(op: &str) -> Envelope {
        Envelope::request(op, 1, serde_json::json!(null))
    }''',
     '''    fn req(op: &str) -> Envelope {
        Envelope::request(op, 1, serde_json::json!(null))
    }

    #[test]
    fn polite_focus_never_steals() {
        let (mut c, d, sc, hub) = new_comp_with_display();
        let mut r = |op: &str, p: serde_json::Value| {
            handle(&mut c, &d, &sc, &hub, &Envelope::request(op, 1, p))
        };
        let w1 = r(
            "window-new",
            serde_json::json!({"x": 0, "y": 0, "w": 100, "h": 50}),
        )
        .payload
        .unwrap()["id"]
            .as_u64()
            .unwrap();
        let w2 = r(
            "window-new",
            serde_json::json!({"x": 120, "y": 0, "w": 100, "h": 50}),
        )
        .payload
        .unwrap()["id"]
            .as_u64()
            .unwrap();
        // Explicit focus takes the window and reports it.
        let resp = r("window-focus", serde_json::json!({ "id": w1 }))
            .payload
            .unwrap();
        assert_eq!(resp["granted"], true);
        assert_eq!(sc.lock().unwrap().focused(), Some(w1 as u32));
        // Polite focus on another window is refused while focus is held.
        let resp = r("window-focus", serde_json::json!({ "id": w2, "steal": false }))
            .payload
            .unwrap();
        assert_eq!(resp["granted"], false);
        assert_eq!(sc.lock().unwrap().focused(), Some(w1 as u32));
        // Steal-focus still wins; polite re-focus of the holder is granted.
        let resp = r("window-focus", serde_json::json!({ "id": w2 }))
            .payload
            .unwrap();
        assert_eq!(resp["granted"], true);
        let resp = r("window-focus", serde_json::json!({ "id": w2, "steal": false }))
            .payload
            .unwrap();
        assert_eq!(resp["granted"], true);
    }'''),
])

patch("rust/crates/inputd/src/main.rs", [
    ('''    // Focus is ours to claim (window creation order races between daemons).
    let resp = cl.request("window-focus", json!({ "id": win_id }))?;
    if resp.error.is_some() {
        eprintln!("inputd: focus request refused: {:?}", resp.error);
    }''',
     '''    // The console only takes focus when nothing else holds it: a polite
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
    }'''),
])

print("ALL PATCHES OK")
