#!/usr/bin/env bash
# Behavioral test for lock.sh: one holder at a time, held for as long as the
# owner process lives (however long that is), and free once the owner dies.
set -u

LOCK_SH="$(cd "$(dirname "$0")" && pwd)/lock.sh"
PASS=0; FAIL=0
export LOCK_DIR=$(mktemp -d)/lock
trap 'kill $A $B 2>/dev/null; rm -rf "$(dirname "$LOCK_DIR")"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

sleep 600 & A=$!
sleep 600 & B=$!

LOCK_OWNER_PID=$A "$LOCK_SH" acquire >/dev/null
chk "T1 acquire when free" "[ $? -eq 0 ]"

LOCK_OWNER_PID=$B "$LOCK_SH" acquire >/dev/null
chk "T2 second owner refused while first lives" "[ $? -ne 0 ]"

LOCK_OWNER_PID=$B "$LOCK_SH" release >/dev/null
chk "T3 other owner cannot release" "[ -d '$LOCK_DIR' ]"

kill $A; wait $A 2>/dev/null
LOCK_OWNER_PID=$B "$LOCK_SH" acquire >/dev/null
chk "T4 acquire once the owner died" "[ $? -eq 0 ]"

LOCK_OWNER_PID=$B "$LOCK_SH" release >/dev/null
chk "T5 owner releases" "[ ! -e '$LOCK_DIR' ]"

echo "# $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
