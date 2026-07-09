#!/usr/bin/env bash
# Behavioral test for JS/PLAYWRIGHT SCENARIOS: a scenario authored as a .spec.js
# module (the artifact review-dry now hands QA) drives the SAME evidence
# machinery as the markdown DSL — captions, per-checkpoint frames, steps.json
# verdict. Proves (a) a passing checkpoint records the human caption +
# checkpoint:true + ok:true and captures a frame; (b) the raw Playwright `page`
# handed to the author works as an assertion source, not just the see* sugar;
# (c) a checkpoint whose assertion throws FAILs the run, and its human caption
# does NOT self-match the assertion (closed shadow-root isolation holds for the
# JS path too); (d) an uncaught error OUTSIDE a checkpoint is captured as a
# failure, not a crash. Drives run.js against a trivial static fixture.
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
# Read a value out of steps.json with node (no jq dependency).
sj()  { node -e "const d=require('$1');console.log($2)" 2>/dev/null; }

echo "# js scenario (.spec.js handoff)"

# --- fixture: a static page with one unique, known string -----------------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
PRESENT="JS SCENARIO FIXTURE OK 7742"
ABSENT="totally-absent-string-qzqz-2718"
printf '<!doctype html><meta charset=utf-8><title>fix</title><h1>%s</h1>' "$PRESENT" > "$FIX/index.html"

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: a passing JS scenario — see* sugar AND raw page both assert ---------
cat > "$TMPROOT/pass.spec.js" <<EOF
module.exports = async ({ page, base, checkpoint, visit, see }) => {
  await visit('/');
  await checkpoint('The fixture headline is visible', () => see('$PRESENT'));
  await checkpoint('The raw Playwright page also asserts', () =>
    page.getByText('$PRESENT').first().waitFor({ state: 'visible', timeout: 2000 }));
};
EOF
node "$RUN" "$TMPROOT/pass.spec.js" --out "$TMPROOT/passout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
PJSON="$TMPROOT/passout/steps.json"
chk "T1 runner exits zero"                 "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                   "[ \"\$(sj '$PJSON' 'd.verdict')\" = PASS ]"
chk "T1 checkpoint 0 flagged"              "[ \"\$(sj '$PJSON' 'd.steps[0].checkpoint')\" = true ]"
chk "T1 checkpoint 0 caption is human"     "[ \"\$(sj '$PJSON' 'd.steps[0].caption')\" = 'The fixture headline is visible' ]"
chk "T1 checkpoint 0 passed (sugar see)"   "[ \"\$(sj '$PJSON' 'd.steps[0].ok')\" = true ]"
chk "T1 checkpoint 1 passed (raw page)"    "[ \"\$(sj '$PJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 checkpoint 0 captured a frame"     "[ -n \"\$(sj '$PJSON' 'd.steps[0].frame')\" ]"
chk "T1 a frame PNG exists on disk"        "[ -n \"\$(ls '$TMPROOT/passout/frames/'*.png 2>/dev/null)\" ]"

# --- T2: a checkpoint whose assertion THROWS fails; caption doesn't self-match
cat > "$TMPROOT/fail.spec.js" <<EOF
module.exports = async ({ checkpoint, visit, see }) => {
  await visit('/');
  await checkpoint('The missing banner should appear', () => see('$ABSENT'));
};
EOF
node "$RUN" "$TMPROOT/fail.spec.js" --out "$TMPROOT/failout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
FJSON="$TMPROOT/failout/steps.json"
chk "T2 runner exits non-zero"             "[ $rc -ne 0 ]"
chk "T2 verdict is FAIL"                   "[ \"\$(sj '$FJSON' 'd.verdict')\" = FAIL ]"
chk "T2 checkpoint flagged"                "[ \"\$(sj '$FJSON' 'd.steps[0].checkpoint')\" = true ]"
chk "T2 caption is human text"             "[ \"\$(sj '$FJSON' 'd.steps[0].caption')\" = 'The missing banner should appear' ]"
chk "T2 checkpoint FAILED (isolation)"     "[ \"\$(sj '$FJSON' 'd.steps[0].ok')\" = false ]"

# --- T3: an uncaught error OUTSIDE a checkpoint is captured, not a crash -----
cat > "$TMPROOT/throw.spec.js" <<EOF
module.exports = async ({ visit, click }) => {
  await visit('/');
  await click('#definitely-not-on-this-page');
};
EOF
node "$RUN" "$TMPROOT/throw.spec.js" --out "$TMPROOT/throwout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
TJSON="$TMPROOT/throwout/steps.json"
chk "T3 runner exits non-zero"             "[ $rc -ne 0 ]"
chk "T3 verdict is FAIL"                   "[ \"\$(sj '$TJSON' 'd.verdict')\" = FAIL ]"
chk "T3 a failed step was recorded"        "[ \"\$(sj '$TJSON' 'd.steps.some(s=>s.ok===false)')\" = true ]"
chk "T3 steps.json still written (no crash)" "[ -f '$TJSON' ]"

# --- T4: a .spec.js scenario INSIDE an ESM package ("type":"module") loads ---
# Node parses a bare .js file in a "type":"module" package as ESM, so a naive
# require() of the CommonJS scenario throws ERR_REQUIRE_ESM. The evidence dir is
# the app repo's own tmp/, so in an ESM app every .spec.js hits this — the runner
# must load it as CommonJS regardless of the enclosing package type, WITHOUT the
# author having to rename it .cjs.
ESM="$TMPROOT/esm-app"; mkdir -p "$ESM"
printf '{"type":"module"}' > "$ESM/package.json"
cat > "$ESM/pass.spec.js" <<EOF
module.exports = async ({ checkpoint, visit, see }) => {
  await visit('/');
  await checkpoint('Loads under an ESM package', () => see('$PRESENT'));
};
EOF
node "$RUN" "$ESM/pass.spec.js" --out "$TMPROOT/esmout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
EJSON="$TMPROOT/esmout/steps.json"
chk "T4 runner exits zero under ESM pkg"    "[ $rc -eq 0 ]"
chk "T4 verdict is PASS"                    "[ \"\$(sj '$EJSON' 'd.verdict')\" = PASS ]"
chk "T4 checkpoint passed"                  "[ \"\$(sj '$EJSON' 'd.steps[0].ok')\" = true ]"

echo
echo "# js-scenario: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
