#!/usr/bin/env bash
# Behavioral pins for the "Exact verb semantics" section of SKILL.md — the
# engine contract that lets scenario authors NEVER read run.js. Each test
# drives run.js against a static fixture (real browser) and proves a documented
# matching rule: first-DOM-match resolution, case-insensitive substring text
# matching, `see button`'s case asymmetry (submit value* is case-sensitive,
# button :has-text is not), `fill` clearing before typing, and `select`
# matching by option value, not visible label. If a rule here fails, fix the
# SKILL.md prose or the engine — never the test's expectation alone.
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

echo "# verb semantics (SKILL.md engine contract)"

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
cat > "$TMPROOT/pass.md" <<'EOF'
# verb semantics - documented rules hold
hold: 0ms
- visit /
- see "widget registration comp"
- click "Ambiguous Label 8264"
- see "FIRST-TARGET-HIT"
- see button "Save Rec"
- see button "confirm th"
- fill #fld with "REPLACED"
- see "value:REPLACED;"
- select #sel with "au"
EOF
node "$RUN" "$TMPROOT/pass.md" --out "$TMPROOT/passout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
PJSON="$TMPROOT/passout/steps.json"
chk "T1 runner exits zero"                          "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                            "[ \"\$(sj '$PJSON' 'd.verdict')\" = PASS ]"
chk "T1 text match is case-insensitive substring"   "[ \"\$(sj '$PJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 ambiguous click lands on FIRST DOM match"   "[ \"\$(sj '$PJSON' 'd.steps[3].ok')\" = true ]"
chk "T1 see button matches submit by value*"        "[ \"\$(sj '$PJSON' 'd.steps[4].ok')\" = true ]"
chk "T1 see button matches <button> case-insens."   "[ \"\$(sj '$PJSON' 'd.steps[5].ok')\" = true ]"
chk "T1 fill clears before typing (no append)"      "[ \"\$(sj '$PJSON' 'd.steps[7].ok')\" = true ]"
chk "T1 select matches option by value"             "[ \"\$(sj '$PJSON' 'd.steps[8].ok')\" = true ]"

# --- T2: see button on a submit input is CASE-SENSITIVE (value*=) ----------
cat > "$TMPROOT/case.md" <<'EOF'
# verb semantics - submit value match is case-sensitive
hold: 0ms
- visit /
- see button "save rec"
EOF
node "$RUN" "$TMPROOT/case.md" --out "$TMPROOT/caseout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
CJSON="$TMPROOT/caseout/steps.json"
chk "T2 runner exits non-zero"                      "[ $rc -ne 0 ]"
chk "T2 lowercase submit-value lookup FAILS"        "[ \"\$(sj '$CJSON' 'd.steps[1].ok')\" = false ]"

# --- T3: select matches by visible LABEL too, but only EXACTLY --------------
cat > "$TMPROOT/label.md" <<'EOF'
# verb semantics - select matches visible labels exactly
hold: 0ms
- visit /
- select #sel with "Australia"
EOF
node "$RUN" "$TMPROOT/label.md" --out "$TMPROOT/labelout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
LJSON="$TMPROOT/labelout/steps.json"
chk "T3 runner exits zero"                          "[ $rc -eq 0 ]"
chk "T3 exact-label select PASSES"                  "[ \"\$(sj '$LJSON' 'd.steps[1].ok')\" = true ]"

cat > "$TMPROOT/sublabel.md" <<'EOF'
# verb semantics - select label matching takes no substrings
hold: 0ms
- visit /
- select #sel with "Austral"
EOF
node "$RUN" "$TMPROOT/sublabel.md" --out "$TMPROOT/sublabelout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
SJSON="$TMPROOT/sublabelout/steps.json"
chk "T3 runner exits non-zero on substring"         "[ $rc -ne 0 ]"
chk "T3 substring-label select FAILS"               "[ \"\$(sj '$SJSON' 'd.steps[1].ok')\" = false ]"

# --- T4: the documented ~2.5s step timeout is still the engine's constant ---
chk "T4 STEP_TIMEOUT_MS constant is 2_500"          "grep -q 'STEP_TIMEOUT_MS = 2_500' '$RUN'"

echo
echo "# verb-semantics: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
