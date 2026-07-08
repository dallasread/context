#!/usr/bin/env bash
# Behavioral test for CHECKPOINTS: a step becomes a human-meaningful checkpoint
# when the author appends " :: <caption>". This proves (a) the caption shown and
# recorded is the human sentence, not the raw syntax; (b) plumbing steps without
# " :: " keep their raw caption and are flagged checkpoint:false; (c) the
# executable part is still enforced (a checkpoint whose assertion is false FAILS)
# and the human caption does NOT self-match the assertion — i.e. the closed
# shadow-root isolation still holds for checkpoints. Drives run.js against a
# trivial static fixture in a real browser.
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

echo "# checkpoints (:: human caption)"

# --- fixture: a static page with one unique, known string -----------------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
PRESENT="CHECKPOINT FIXTURE OK 5529"
ABSENT="totally-absent-string-wwxx-3141"
printf '<!doctype html><meta charset=utf-8><title>fix</title><h1>%s</h1>' "$PRESENT" > "$FIX/index.html"

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: a passing checkpoint records the HUMAN caption + checkpoint:true ---
# Step 2 is a checkpoint (has " :: "); step 3 is the same assertion as plumbing.
cat > "$TMPROOT/pass.md" <<EOF
# checkpoints - human caption is recorded
- visit /
- see "$PRESENT" :: The fixture headline is visible
- see "$PRESENT"
EOF
node "$RUN" "$TMPROOT/pass.md" --out "$TMPROOT/passout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
PJSON="$TMPROOT/passout/steps.json"
chk "T1 runner exits zero"                 "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                   "[ \"\$(sj '$PJSON' 'd.verdict')\" = PASS ]"
chk "T1 checkpoint step flagged"           "[ \"\$(sj '$PJSON' 'd.steps[1].checkpoint')\" = true ]"
chk "T1 checkpoint caption is human text"  "[ \"\$(sj '$PJSON' 'd.steps[1].caption')\" = 'The fixture headline is visible' ]"
chk "T1 checkpoint executed (passed)"      "[ \"\$(sj '$PJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 plumbing step not a checkpoint"    "[ \"\$(sj '$PJSON' 'd.steps[2].checkpoint')\" = false ]"
chk "T1 plumbing caption is raw syntax"    "[ \"\$(sj '$PJSON' 'd.steps[2].caption.startsWith(\"see \")')\" = true ]"

# --- T2: a checkpoint whose assertion is FALSE must FAIL --------------------
# Proves the executable part is enforced and the human caption does not
# self-match (closed shadow-root isolation holds for checkpoints too).
cat > "$TMPROOT/fail.md" <<EOF
# checkpoints - false assertion fails despite friendly caption
- visit /
- see "$ABSENT" :: The missing banner should appear
EOF
node "$RUN" "$TMPROOT/fail.md" --out "$TMPROOT/failout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
FJSON="$TMPROOT/failout/steps.json"
chk "T2 runner exits non-zero"             "[ $rc -ne 0 ]"
chk "T2 verdict is FAIL"                   "[ \"\$(sj '$FJSON' 'd.verdict')\" = FAIL ]"
chk "T2 checkpoint step flagged"           "[ \"\$(sj '$FJSON' 'd.steps[1].checkpoint')\" = true ]"
chk "T2 checkpoint caption is human text"  "[ \"\$(sj '$FJSON' 'd.steps[1].caption')\" = 'The missing banner should appear' ]"
chk "T2 checkpoint FAILED (not matched)"   "[ \"\$(sj '$FJSON' 'd.steps[1].ok')\" = false ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
