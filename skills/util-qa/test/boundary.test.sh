#!/usr/bin/env bash
# Boundary tests for the runner's HOST-ENVIRONMENT seams — the assumptions the
# runner makes about the host that must fail fast and clearly, so no caller ever
# re-derives a workaround per run. Companion to js-scenario.test.sh's ESM case
# (the module-type seam); this file pins the rest:
#   - a non-JS scenario path is rejected (the markdown/JSON formats are gone);
#   - a JS scenario that doesn't export a function is rejected;
#   - qa.sh with no profile and no `--` override hard-fails with QA_CONFIG_MISSING.
# All three exit before any browser/boot, so this test is fast and needs no
# server. It also pins the maintainer rule in SKILL.md (encode quirks, don't
# re-derive them), the way runner-boundary.test.sh pins the runner contract.
# Needs: node + git.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
QASH="$DIR/qa.sh"
SKILL="$DIR/SKILL.md"
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# runner host-environment boundaries"

# --- T1: a non-JS scenario path is rejected with SCENARIO_NOT_JS -------------
printf '# not a scenario\n' > "$TMPROOT/notes.md"
out=$( node "$RUN" "$TMPROOT/notes.md" --out "$TMPROOT/o1" --base http://localhost:1 --no-auth 2>&1 )
rc=$?
chk "T1 exits non-zero"                    "[ $rc -ne 0 ]"
chk "T1 reports SCENARIO_NOT_JS"           "echo \"\$out\" | grep -q SCENARIO_NOT_JS"

# --- T2: a JS scenario that doesn't export a function is rejected ------------
printf 'module.exports = 42;' > "$TMPROOT/bad.spec.js"
out=$( node "$RUN" "$TMPROOT/bad.spec.js" --out "$TMPROOT/o2" --base http://localhost:1 --no-auth 2>&1 )
rc=$?
chk "T2 exits non-zero"                     "[ $rc -ne 0 ]"
chk "T2 reports the export contract"        "echo \"\$out\" | grep -q 'must export an async function'"

# --- T3: qa.sh with no profile and no override hard-fails, before any boot ---
REPO=$(mktemp -d "$TMPROOT/repo.XXXX"); ( cd "$REPO" && git init -q )
printf 'module.exports = async () => {};' > "$REPO/s.spec.js"
out=$( cd "$REPO" && QA_SKIP_RUN=1 "$QASH" s.spec.js "$REPO/o" 2>&1 )
rc=$?
chk "T3 exits non-zero"                     "[ $rc -ne 0 ]"
chk "T3 reports QA_CONFIG_MISSING"          "echo \"\$out\" | grep -q QA_CONFIG_MISSING"

# --- T4: the maintainer rule is stated in the SKILL (encode, don't re-derive)
chk "T4 SKILL pins the encode-quirks rule"  "grep -qF 'Environment quirks are encoded, never re-derived per run.' '$SKILL'"

echo
echo "# boundary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
