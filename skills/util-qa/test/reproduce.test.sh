#!/usr/bin/env bash
# Behavioral test for qa.sh --reproduce: the MODEL-FREE re-run path. A prior
# review/QA leaves a faithful scenario in the branch's evidence dir; --reproduce
# resolves and replays it with no authoring step. Uses the QA_SKIP_RUN seam + a
# stub server, so it exercises the resolution/boot without a browser or profile.
# Needs: git + python3.
set -u

QA="$(cd "$(dirname "$0")/.." && pwd)/qa.sh"
STUB='python3 -m http.server "$PORT"'   # $PORT expanded by qa.sh's sh -c
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
trap 'pkill -f "http.server" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

# A repo on a known branch, with a saved scenario already in tmp/qa/<branch>/.
mkrepo_with_saved() {
  d=$(mktemp -d "$TMPROOT/repo.XXXX")
  ( cd "$d" && git init -q && git checkout -q -b "$1" )
  mkdir -p "$d/tmp/qa/$1"
  printf 'module.exports = async ({ visit }) => { await visit("/"); };' > "$d/tmp/qa/$1/scenario.spec.js"
  echo "$d"
}

echo "# qa.sh --reproduce (model-free re-run)"

# --- T1: derives the saved scenario from the current branch's evidence dir ---
BR="feat/repro-me"
A=$(mkrepo_with_saved "$BR")
# qa.sh derives the evidence dir from git's toplevel, which is the realpath
# (macOS resolves /var/folders -> /private/var/folders); resolve the same way.
WT=$( cd "$A" && git rev-parse --show-toplevel )
out=$( cd "$A" && QA_SKIP_RUN=1 "$QA" --reproduce -- $STUB 2>&1 )
rc=$?
chk "T1 exits 0"                          "[ $rc -eq 0 ]"
chk "T1 resolved the branch's saved scenario" \
    "echo \"\$out\" | grep -q 'reproduce: $WT/tmp/qa/$BR/scenario.spec.js'"

# --- T2: an explicit evidence dir overrides branch derivation ----------------
ALT="$A/tmp/qa/$BR"
out=$( cd "$A" && QA_SKIP_RUN=1 "$QA" --reproduce "$ALT" -- $STUB 2>&1 )
chk "T2 uses the given dir"               "echo \"\$out\" | grep -q 'reproduce: $ALT/scenario.spec.js'"

# --- T3: no saved scenario fails loudly, before any boot ---------------------
B=$(mktemp -d "$TMPROOT/empty.XXXX"); ( cd "$B" && git init -q && git checkout -q -b bare )
out=$( cd "$B" && QA_SKIP_RUN=1 "$QA" --reproduce -- $STUB 2>&1 )
rc=$?
chk "T3 exits non-zero"                   "[ $rc -ne 0 ]"
chk "T3 reports REPRODUCE_NO_SCENARIO"    "echo \"\$out\" | grep -q REPRODUCE_NO_SCENARIO"

echo
echo "# reproduce: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
