#!/bin/sh
# Ox build-machine watcher.
# Duplicate-guard: only one watcher may run per VM. The lock is
# SELF-HEALING (a stale lock is cleared via the cmdline check) —
# NEVER rm it manually: a blind rm orphans a live watcher lockless
# and the next launcher steals the queue (two fleets, Sep 25).
Q=/root/oxbuild/queue
LOCK=$Q/watcher.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    PID=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$PID" ] && grep -qa watcher.sh "/proc/$PID/cmdline" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" || exit 1
fi
echo $$ > "$LOCK/pid"
# Recovery first: an interrupted job (watcher died mid-run) re-queues ahead of new work.
if [ -s "$Q/running.txt" ]; then
    cat "$Q/running.txt" "$Q/queue.txt" > "$Q/queue.txt.recovered" 2>/dev/null
    mv "$Q/queue.txt.recovered" "$Q/queue.txt"
    rm -f "$Q/running.txt"
    echo "RECOVERED interrupted job into queue" >> "$Q/board.txt"
fi
mkdir -p "$Q/status"
touch "$Q/queue.txt" "$Q/board.txt"
while :; do
    if [ -f "$Q/AGENT.lock" ]; then
        sleep 30
        continue
    fi
    JOB=$(head -1 "$Q/queue.txt" 2>/dev/null)
    if [ -z "$JOB" ]; then
        sleep 30
        continue
    fi
    tail -n +2 "$Q/queue.txt" > "$Q/queue.txt.next" 2>/dev/null
    mv "$Q/queue.txt.next" "$Q/queue.txt"
    printf "%s\n" "$JOB" > "$Q/running.txt"
    TS=$(date -u +%Y%m%d-%H%M%S)
    NAME=$(printf "%s" "$JOB" | tr -c "a-zA-Z0-9._-" "_" | cut -c1-60)
    echo "[$(date -u +%F" "%T)] START $JOB" >> "$Q/board.txt"
    # setsid + stdin=/dev/null: the watcher itself may run behind a
    # foreign foreground group on a pty (harness background task), and
    # a job touching that pty's termios (qemu -nographic stdio chardev)
    # gets SIGTTOU and freezes in state T before printing a byte
    # (2026-10-09 slotboot reds). A new session has no controlling
    # terminal, so no job can be stopped that way.
    if cd /root/oxbuild && setsid sh -c "$JOB" </dev/null > "$Q/status/$TS-$NAME.log" 2>&1; then
        echo "[$(date -u +%F" "%T)] PASS  $JOB  (log: status/$TS-$NAME.log)" >> "$Q/board.txt"
    else
        RC=$?
        echo "[$(date -u +%F" "%T)] FAIL($RC) $JOB  (log: status/$TS-$NAME.log)" >> "$Q/board.txt"
        printf "[%s] JOB FAILED rc=%s: %s\n  log: /root/oxbuild/queue/status/%s-%s.log\n" \
            "$(date -u +%F" "%T)" "$RC" "$JOB" "$TS" "$NAME" >> "$Q/NEEDS-AGENT.txt"
    fi
    rm -f "$Q/running.txt"
    sleep 10
done
