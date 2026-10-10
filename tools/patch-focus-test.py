#!/usr/bin/env python3
"""Focus test rework: pure decision function instead of driving the op
(the op needs a real display; the project tests decisions, not wiring)."""

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
    ('''                let current = scene.lock().unwrap().focused();
                if polite && current.is_some() && current != Some(id as u32) {
                    req.ok(json!({ "granted": false, "focused": current }))
                } else if scene.lock().unwrap().set_focus(id as u32) {''',
     '''                let current = scene.lock().unwrap().focused();
                if !polite_focus_granted(polite, current, id as u32) {
                    req.ok(json!({ "granted": false, "focused": current }))
                } else if scene.lock().unwrap().set_focus(id as u32) {'''),
    ('''    #[test]
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
    }''',
     '''    #[test]
    fn polite_focus_never_steals() {
        // Nothing focused: a polite request is granted.
        assert!(polite_focus_granted(true, None, 2));
        // Focus held by another window: refused.
        assert!(!polite_focus_granted(true, Some(1), 2));
        // Focus held by the requester itself: granted (re-focus own window).
        assert!(polite_focus_granted(true, Some(2), 2));
        // Explicit steal always wins.
        assert!(polite_focus_granted(false, Some(1), 2));
    }'''),
])

# Insert the pure decision function next to the op arm.
patch("rust/crates/oxcom/src/main.rs", [
    ('''fn handle(''',
     '''/// Polite focus (`steal=false`) must not take focus from another window:
/// background consoles may claim focus only while nothing else holds it.
fn polite_focus_granted(polite: bool, current: Option<u32>, id: u32) -> bool {
    !polite || current.is_none() || current == Some(id)
}

fn handle('''),
])

print("ALL PATCHES OK")
