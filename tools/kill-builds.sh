#!/bin/sh
# Kill every stale PipeWire scout build (no self-match: this file's own
# command line is just "sh tools/kill-builds.sh").
pkill -9 -f 'pipewire-scout.sh' 2>/dev/null
pkill -9 -f 'nix build -L --impure' 2>/dev/null
pkill -9 -f 'nix build -L github:NixOS' 2>/dev/null
sleep 1
ps aux | grep -E '[n]ix|[p]ipewire-scout' | head -5
echo "kill done"
