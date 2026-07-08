#!/usr/bin/env bash
# Behavioral test for the assertion-integrity guarantee: QA chrome (the caption
# bar + Trusty mascot) lives in a CLOSED shadow root, so it is invisible to the
# page's own automation. Without that isolation a `see "X"` step — which writes
# a caption label containing X — would match its own caption and could NEVER
# fail. This drives run.js against a trivial static fixture (real browser) and
# proves a `see` for absent text FAILS while a `see` for present text PASSES.
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

echo "# assertion isolation (closed shadow root)"

# --- fixture: a static page with one unique, known string -----------------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
PRESENT="ISOLATION FIXTURE OK 4718"
ABSENT="totally-absent-string-zzqq-9182"
printf '<!doctype html><meta charset=utf-8><title>fix</title><h1>%s</h1>' "$PRESENT" > "$FIX/index.html"

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: a `see` for ABSENT text must FAIL (chrome not self-matched) -------
cat > "$TMPROOT/fail.md" <<EOF
# isolation - absent text must fail
- visit /
- see "$PRESENT"
- see "$ABSENT"
EOF
node "$RUN" "$TMPROOT/fail.md" --out "$TMPROOT/failout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
FJSON="$TMPROOT/failout/steps.json"
chk "T1 runner exits non-zero"          "[ $rc -ne 0 ]"
chk "T1 verdict is FAIL"                "[ \"\$(sj '$FJSON' 'd.verdict')\" = FAIL ]"
chk "T1 present-text step passed"       "[ \"\$(sj '$FJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 absent-text step FAILED"        "[ \"\$(sj '$FJSON' 'd.steps[2].ok')\" = false ]"

# --- T2: positive control — present text alone PASSES (no false failures) --
cat > "$TMPROOT/pass.md" <<EOF
# isolation - present text passes
- visit /
- see "$PRESENT"
EOF
node "$RUN" "$TMPROOT/pass.md" --out "$TMPROOT/passout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
PJSON="$TMPROOT/passout/steps.json"
chk "T2 runner exits zero"              "[ $rc -eq 0 ]"
chk "T2 verdict is PASS"                "[ \"\$(sj '$PJSON' 'd.verdict')\" = PASS ]"
chk "T2 present-text step passed"       "[ \"\$(sj '$PJSON' 'd.steps[1].ok')\" = true ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
