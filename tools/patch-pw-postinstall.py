#!/usr/bin/env python3
"""Fix the postInstall placeholder line in pipewire-scout.sh."""
import io

p = "tools/pipewire-scout.sh"
t = io.open(p, encoding="utf-8", newline="").read().replace("\r\n", "\n")

old = """    postInstall = (old.postInstall or "") + ''
      mkdir -p "" "" "" ""
    '';"""
new = """    postInstall = (old.postInstall or "") + ''
      mkdir -p "$doc" "$man" "$jack" "$installedTests"
    '';"""
assert t.count(old) == 1, t.count(old)
io.open(p, "w", encoding="utf-8", newline="").write(t.replace(old, new))
print("postInstall fixed")
