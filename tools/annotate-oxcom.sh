#!/bin/sh
set -eu
python3 - <<'PYEOF'
import io

note = ("// Consumed by the gui-feature-gated paths (and tests); dead without\n"
        "// the feature, hence the module-level allow.\n"
        "#![allow(dead_code)]\n\n")
for f in ["screen.rs", "font.rs", "scene.rs", "evdev.rs"]:
    p = "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/rust/crates/oxcom/src/" + f
    s = io.open(p, encoding="utf-8", newline="").read()
    if "#![allow(dead_code)]" not in s:
        io.open(p, "w", encoding="utf-8", newline="").write(note + s)
        print("annotated", f)
    else:
        print("already annotated", f)
PYEOF
cd "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/rust/crates/oxcom/src" && sed -i 's/\r$//' screen.rs font.rs scene.rs evdev.rs
echo done
