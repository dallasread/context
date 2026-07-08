#!/usr/bin/env bash
# Behavioral test for qa.sh's warm-server lifecycle (--keep / auto-reuse /
# --fresh / --stop). Uses a stub HTTP server (python3) and the QA_SKIP_RUN
# seam, so it exercises the boot/reuse/teardown logic WITHOUT booting Rails or
# driving a browser. Fast and dependency-light (git + python3 + pgrep).
set -u

QA="$(cd "$(dirname "$0")/.." && pwd)/qa.sh"
STUB='python3 -m http.server "$PORT"'   # $PORT expanded by qa.sh's sh -c
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
trap 'pkill -f "http.server" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

mkrepo() { d=$(mktemp -d "$TMPROOT/repo.XXXX"); ( cd "$d" && git init -q ); echo "$d"; }
state()  { echo "$1/tmp/qa/.warm-server"; }
alive()  { kill -0 "$1" 2>/dev/null; }
serverpid() { grep '^PID=' "$1" | cut -d= -f2; }
serverbase() { grep '^BASE=' "$1" | cut -d= -f2; }
responds() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$1/" 2>/dev/null)" != "000" ]; }

echo "# warm-server lifecycle"

# --- T1: --keep boots, writes state, leaves server alive ------------------
A=$(mkrepo); SA=$(state "$A")
( cd "$A" && QA_SKIP_RUN=1 "$QA" dummy.md "$A/out" --keep -- $STUB ) >/dev/null 2>&1
rc=$?
chk "T1 --keep exits 0"            "[ $rc -eq 0 ]"
chk "T1 state file written"        "[ -f '$SA' ]"
PIDA=$(serverpid "$SA"); BASEA=$(serverbase "$SA")
chk "T1 recorded pid is alive"     "alive '$PIDA'"
chk "T1 recorded base responds"    "responds '$BASEA'"

# --- T2: second --keep reuses the SAME server (no reboot) -----------------
( cd "$A" && QA_SKIP_RUN=1 "$QA" dummy.md "$A/out2" --keep -- $STUB ) >/dev/null 2>&1
PIDA2=$(serverpid "$SA")
chk "T2 reuse keeps same pid"      "[ '$PIDA2' = '$PIDA' ]"
chk "T2 server still alive"        "alive '$PIDA'"

# --- T3: --fresh replaces the warm server (new pid, old one dead) ---------
( cd "$A" && QA_SKIP_RUN=1 "$QA" dummy.md "$A/out3" --keep --fresh -- $STUB ) >/dev/null 2>&1
PIDA3=$(serverpid "$SA")
chk "T3 --fresh boots new pid"     "[ '$PIDA3' != '$PIDA' ]"
chk "T3 old server killed"         "! alive '$PIDA'"
chk "T3 new server alive"          "alive '$PIDA3'"

# --- T4: --stop tears it down and clears state ---------------------------
( cd "$A" && "$QA" --stop ) >/dev/null 2>&1
chk "T4 state removed"             "[ ! -f '$SA' ]"
chk "T4 server killed"             "! alive '$PIDA3'"

# --- T5: parallel worktrees stay independent -----------------------------
B=$(mkrepo); SB=$(state "$B")
( cd "$A" && QA_SKIP_RUN=1 "$QA" dummy.md "$A/o" --keep -- $STUB ) >/dev/null 2>&1
( cd "$B" && QA_SKIP_RUN=1 "$QA" dummy.md "$B/o" --keep -- $STUB ) >/dev/null 2>&1
PIDA=$(serverpid "$SA"); PIDB=$(serverpid "$SB")
BA=$(serverbase "$SA"); BB=$(serverbase "$SB")
chk "T5 distinct state files"      "[ '$SA' != '$SB' ]"
chk "T5 distinct ports"            "[ '$BA' != '$BB' ]"
chk "T5 both alive simultaneously" "alive '$PIDA' && alive '$PIDB'"
( cd "$A" && "$QA" --stop ) >/dev/null 2>&1
chk "T5 stopping A leaves B alive" "alive '$PIDB' && ! alive '$PIDA'"
( cd "$B" && "$QA" --stop ) >/dev/null 2>&1

# --- T6: default (no flag) is hermetic — killed on exit, no state --------
C=$(mkrepo); SC=$(state "$C")
out=$( cd "$C" && QA_SKIP_RUN=1 "$QA" dummy.md "$C/o" -- $STUB 2>&1 )
BASEC=$(echo "$out" | grep -o 'http://localhost:[0-9]*' | head -1)
chk "T6 no state file written"     "[ ! -f '$SC' ]"
chk "T6 server killed on exit"     "! responds '$BASEC'"

# --- T7: stale state (server died) triggers a reboot ---------------------
D=$(mkrepo); SD=$(state "$D")
( cd "$D" && QA_SKIP_RUN=1 "$QA" dummy.md "$D/o" --keep -- $STUB ) >/dev/null 2>&1
PIDD=$(serverpid "$SD")
kill_tree_d() { for c in $(pgrep -P "$1"); do kill_tree_d "$c"; done; kill "$1" 2>/dev/null; }
kill_tree_d "$PIDD"; sleep 1
( cd "$D" && QA_SKIP_RUN=1 "$QA" dummy.md "$D/o2" --keep -- $STUB ) >/dev/null 2>&1
PIDD2=$(serverpid "$SD")
chk "T7 stale state rebooted"      "[ '$PIDD2' != '$PIDD' ] && alive '$PIDD2'"
( cd "$D" && "$QA" --stop ) >/dev/null 2>&1

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
