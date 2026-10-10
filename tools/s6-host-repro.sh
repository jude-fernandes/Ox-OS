#!/usr/bin/env bash
# Reproduce the s6-rc boot sequence natively to debug the ENOENT.
set -u
B=/tmp/ox-s6/host/usr/bin
S=/tmp/ox-s6/host/usr/libexec
export PATH="$B:$PATH"
rm -rf /tmp/s6test
mkdir -p /tmp/s6test/scandir

# compile the same service source with the host toolset
"$B/s6-rc-compile" /tmp/s6test/compiled "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/s6-rc-source" || exit 1

"$B/s6-svscan" /tmp/s6test/scandir &
SV=$!
i=0
while [ $i -lt 50 ] && [ ! -d /tmp/s6test/scandir/.s6-svscan ]; do i=$((i+1)); sleep 0.1; done
echo "svscan pid=$SV alive=$(kill -0 $SV 2>/dev/null && echo y || echo n)"
"$B/s6-rc-init" -c /tmp/s6test/compiled -l /tmp/s6test/live -t 8000 /tmp/s6test/scandir
echo "rc-init rc=$?"
"$B/s6-rc" -up change default
echo "rc-change rc=$?"
sleep 1
ls /tmp/s6test/live/servicedirs/ 2>/dev/null
for d in /tmp/s6test/scandir/*/; do
    [ -e "$d" ] && "$B/s6-svstat" "$d"
done
kill $SV 2>/dev/null
