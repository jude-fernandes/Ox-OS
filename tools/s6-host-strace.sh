#!/usr/bin/env bash
set -u
B=/tmp/ox-s6/host/usr/bin
export PATH="$B:$PATH"
rm -rf /tmp/s6test
mkdir -p /tmp/s6test/scandir
"$B/s6-rc-compile" /tmp/s6test/compiled "/mnt/c/Users/rawc1/Desktop/Opencode/Ox OS/ox/system/s6-rc-source" || exit 1
"$B/s6-svscan" /tmp/s6test/scandir &
SV=$!
i=0
while [ $i -lt 50 ] && [ ! -d /tmp/s6test/scandir/.s6-svscan ]; do i=$((i+1)); sleep 0.1; done
if command -v strace >/dev/null; then
    strace -f -qq -e trace=%file,chdir,readlink "$B/s6-rc-init" -c /tmp/s6test/compiled -l /tmp/s6test/live -t 8000 /tmp/s6test/scandir 2>&1 | grep -E 'ENOENT|execve|symlink|scandir' | tail -25
else
    echo NO_STRACE
fi
kill $SV 2>/dev/null
