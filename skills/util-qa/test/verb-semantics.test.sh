#!/usr/bin/env bash
# Behavioral pins for the "Exact verb semantics" section of SKILL.md — the
# matching contract the .spec.js sugar (see/click/fill/select/wait) and the
# login macros share, so scenario authors NEVER need to read run.js. Each test
# drives run.js against a static fixture (real browser) and proves a documented
# rule: first-DOM-match resolution, case-insensitive substring text matching,
# `seeButton`'s case asymmetry (submit value* is case-sensitive, button has-text
# is not), `fill` clearing before typing, `select` matching by option value and
# by exact visible label, and the per-step wait clamp. If a rule here fails, fix
# the SKILL.md prose or the engine — never the test's expectation alone.
#
# NOTE: in a JS scenario only checkpoint() calls land in steps.json; plumbing
# (visit/click/fill) is not recorded. So each rule under test is asserted as a
# checkpoint, and steps[] indexes the checkpoint sequence (0-based).
# Needs: node + playwright/chromium + ffmpeg + python3 (the skill's own deps).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }
# Read a jq-ish value out of steps.json with node (no jq dependency).
sj()  { node -e "const d=require('$1');console.log($2)" 2>/dev/null; }

echo "# verb semantics (SKILL.md matching contract)"

# --- fixture: one page exhibiting every documented matching rule -----------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
cat > "$FIX/index.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>verbs</title>
<div id="out">no-click-yet</div>
<span onclick="document.getElementById('out').textContent='FIRST-TARGET-HIT'">Ambiguous Label 8264</span>
<button type="button" onclick="document.getElementById('out').textContent='SECOND-TARGET-HIT'">Ambiguous Label 8264</button>
<p>Widget Registration Complete 7431</p>
<form onsubmit="return false"><input type="submit" value="Save Record Now"></form>
<button type="button">Confirm Thing</button>
<input id="fld" value="PREFILLED" oninput="document.getElementById('echo').textContent='value:'+this.value+';'">
<span id="echo">value:unset;</span>
<select id="sel"><option value="">--</option><option value="au">Australia</option></select>
HTML

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: every documented positive rule holds, in one run -------------------
cat > "$TMPROOT/pass.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see, seeButton, clickText, fill, select }) => {
  await visit('/');
  await checkpoint('text match is case-insensitive substring', () => see('widget registration comp'));
  await clickText('Ambiguous Label 8264');
  await checkpoint('ambiguous click lands on the FIRST DOM match', () => see('FIRST-TARGET-HIT'));
  await checkpoint('seeButton matches a submit by value substring', () => seeButton('Save Rec'));
  await checkpoint('seeButton matches a <button> case-insensitively', () => seeButton('confirm th'));
  await fill('#fld', 'REPLACED');
  await checkpoint('fill clears before typing (no append)', () => see('value:REPLACED;'));
  await checkpoint('select matches an option by value', () => select('#sel', 'au'));
};
EOF
node "$RUN" "$TMPROOT/pass.spec.js" --out "$TMPROOT/passout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
PJSON="$TMPROOT/passout/steps.json"
chk "T1 runner exits zero"                          "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                            "[ \"\$(sj '$PJSON' 'd.verdict')\" = PASS ]"
chk "T1 text match is case-insensitive substring"   "[ \"\$(sj '$PJSON' 'd.steps[0].ok')\" = true ]"
chk "T1 ambiguous click lands on FIRST DOM match"   "[ \"\$(sj '$PJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 seeButton matches submit by value*"         "[ \"\$(sj '$PJSON' 'd.steps[2].ok')\" = true ]"
chk "T1 seeButton matches <button> case-insens."    "[ \"\$(sj '$PJSON' 'd.steps[3].ok')\" = true ]"
chk "T1 fill clears before typing (no append)"      "[ \"\$(sj '$PJSON' 'd.steps[4].ok')\" = true ]"
chk "T1 select matches option by value"             "[ \"\$(sj '$PJSON' 'd.steps[5].ok')\" = true ]"

# --- T2: seeButton on a submit input is CASE-SENSITIVE (value*=) ------------
cat > "$TMPROOT/case.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, seeButton }) => {
  await visit('/');
  await checkpoint('lowercase submit-value lookup (value* is case-sensitive)', () => seeButton('save rec'));
};
EOF
node "$RUN" "$TMPROOT/case.spec.js" --out "$TMPROOT/caseout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
CJSON="$TMPROOT/caseout/steps.json"
chk "T2 runner exits non-zero"                      "[ $rc -ne 0 ]"
chk "T2 lowercase submit-value lookup FAILS"        "[ \"\$(sj '$CJSON' 'd.steps[0].ok')\" = false ]"

# --- T3: select matches by visible LABEL too, but only EXACTLY --------------
cat > "$TMPROOT/label.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, select }) => {
  await visit('/');
  await checkpoint('exact-label select passes', () => select('#sel', 'Australia'));
};
EOF
node "$RUN" "$TMPROOT/label.spec.js" --out "$TMPROOT/labelout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
LJSON="$TMPROOT/labelout/steps.json"
chk "T3 runner exits zero"                          "[ $rc -eq 0 ]"
chk "T3 exact-label select PASSES"                  "[ \"\$(sj '$LJSON' 'd.steps[0].ok')\" = true ]"

cat > "$TMPROOT/sublabel.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, select }) => {
  await visit('/');
  await checkpoint('substring-label select', () => select('#sel', 'Austral'));
};
EOF
node "$RUN" "$TMPROOT/sublabel.spec.js" --out "$TMPROOT/sublabelout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
SJSON="$TMPROOT/sublabelout/steps.json"
chk "T3 runner exits non-zero on substring"         "[ $rc -ne 0 ]"
chk "T3 substring-label select FAILS"               "[ \"\$(sj '$SJSON' 'd.steps[0].ok')\" = false ]"

# --- T4: the documented 2s per-step cap is still the engine's constant ------
chk "T4 STEP_TIMEOUT_MS constant is 2_000"          "grep -q 'STEP_TIMEOUT_MS = 2_000' '$RUN'"

# --- T5: an explicit wait is CLAMPED to the per-step cap (no long stalls) ----
cat > "$TMPROOT/wait.spec.js" <<'EOF'
module.exports = async ({ visit, wait, checkpoint, see }) => {
  await visit('/');
  await wait(8000);
  await checkpoint('the fixture still renders after a clamped wait', () => see('widget registration comp'));
};
EOF
WOUT="$(node "$RUN" "$TMPROOT/wait.spec.js" --out "$TMPROOT/waitout" --base "$BASE" --no-auth 2>&1)"
rc=$?
WJSON="$TMPROOT/waitout/steps.json"
chk "T5 runner exits zero"                          "[ $rc -eq 0 ]"
chk "T5 over-cap wait warns it was clamped"         "printf '%s' \"\$WOUT\" | grep -q clamped"
chk "T5 the checkpoint after the wait passed"       "[ \"\$(sj '$WJSON' 'd.steps[0].ok')\" = true ]"
chk "T5 a within-cap wait is NOT re-clamped"        "! printf '%s' \"\$WOUT\" | grep -q 'clamped to 8000'"

echo
echo "# verb-semantics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
