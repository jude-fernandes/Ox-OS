#!/bin/sh
echo "=== load ==="
uptime
echo "=== mem ==="
free -m | head -2
echo "=== qemu strays ==="
pgrep -f "qemu-system" | while read p; do echo "pid=$p $(ps -o etime= -p $p)"; done
[ -z "$(pgrep -f 'qemu-system')" ] && echo none
echo "=== top procs ==="
ps -eo pid,pcpu,etime,comm --sort=-pcpu | head -6
