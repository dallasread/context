#!/usr/bin/env bash
# Single-run lock for pr-feedback-fixer.
# Usage: lock.sh acquire|release
#
# The owner is the run's `claude` process (the nearest ancestor running the
# claude binary), or LOCK_OWNER_PID. The lock is held while that exact process
# lives: its PID and start time both match. Age never frees it, so a run
# suspended by a closed laptop keeps the lock until it ends or dies.
set -u

LOCK_DIR=${LOCK_DIR:-/tmp/pr-feedback-fixer.lock}

owner_pid() {
  [ -n "${LOCK_OWNER_PID:-}" ] && { echo "$LOCK_OWNER_PID"; return; }
  p=$PPID
  while [ "$p" -gt 1 ]; do
    case "$(ps -o comm= -p "$p")" in */MacOS/claude) echo "$p"; return ;; esac
    p=$(ps -o ppid= -p "$p" | tr -d ' ')
  done
  echo "no claude ancestor" >&2; exit 2
}

# The "<pid> <start time>" that identifies a live process; empty when dead.
identity() { s=$(ps -o lstart= -p "$1" 2>/dev/null) && echo "$1 $s"; }

me=$(identity "$(owner_pid)")

case "${1:-}" in
  acquire)
    if mkdir "$LOCK_DIR" 2>/dev/null; then echo "$me" > "$LOCK_DIR/owner"; echo acquired; exit 0; fi
    held=$(cat "$LOCK_DIR/owner" 2>/dev/null)
    pid=${held%% *}
    if [ -n "$held" ] && [ "$(identity "$pid")" = "$held" ]; then echo "held by $held"; exit 1; fi
    rm -rf "$LOCK_DIR"
    exec "$0" acquire
    ;;
  release)
    [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$me" ] && rm -rf "$LOCK_DIR" && echo released
    exit 0
    ;;
  *) echo "usage: lock.sh acquire|release" >&2; exit 2 ;;
esac
