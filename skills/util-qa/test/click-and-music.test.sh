#!/usr/bin/env bash
# Behavioral tests for two evidence-quality features:
#   1. Click highlight — clicks draw a cursor ring in the closed shadow root.
#      The overlay is pointer-events:none and text-free, so it must NOT break a
#      real click (a click that reveals text is still seen) nor be self-matched.
#   2. Music tracks — a run picks an "elevator music" bed (via --music, a
#      `music:` line, or at random); every named track must produce a valid
#      ffmpeg expression (a malformed expr fails the encode and leaves no mp4),
#      and an unknown name falls back to lounge.
# Drives run.js against a trivial static fixture in a real browser.
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
sj()  { node -e "const d=require('$1');console.log($2)" 2>/dev/null; }

echo "# click highlight + music tracks"

# --- fixture: a button that reveals hidden text when clicked ---------------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
REVEAL="NOW VISIBLE 7731"
cat > "$FIX/index.html" <<HTML
<!doctype html><meta charset=utf-8><title>fix</title>
<button id="go" onclick="document.getElementById('out').style.display='block'">Reveal</button>
<div id="out" style="display:none">$REVEAL</div>
HTML

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: a real click still works with the highlight overlay present -------
cat > "$TMPROOT/click.spec.js" <<EOF
module.exports = async ({ visit, click, checkpoint, see }) => {
  await visit('/');
  await click('#go');
  await checkpoint('The revealed text appears after the click', () => see('$REVEAL'));
};
EOF
node "$RUN" "$TMPROOT/click.spec.js" --out "$TMPROOT/clickout" --base "$BASE" --no-auth --music lounge >/dev/null 2>&1
rc=$?
CJSON="$TMPROOT/clickout/steps.json"
chk "T1 runner exits zero"                 "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                    "[ \"\$(sj '$CJSON' 'd.verdict')\" = PASS ]"
# The revealed-text checkpoint can only pass if the click landed (the div is
# display:none until #go is clicked), so it doubles as proof the click worked.
chk "T1 revealed-text checkpoint passed"    "[ \"\$(sj '$CJSON' 'd.steps[0].ok')\" = true ]"

# --- T2: every named music track produces a valid mp4 ----------------------
for track in lounge twilight sunrise reggae ska; do
  cat > "$TMPROOT/m.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('the reveal button is present', () => see('Reveal'));
};
EOF
  node "$RUN" "$TMPROOT/m.spec.js" --out "$TMPROOT/m-$track" --base "$BASE" --no-auth --music "$track" >/dev/null 2>&1
  MJSON="$TMPROOT/m-$track/steps.json"
  chk "T2 [$track] recorded in manifest"    "[ \"\$(sj '$MJSON' 'd.music')\" = $track ]"
  chk "T2 [$track] mp4 encoded (non-empty)" "[ -s '$TMPROOT/m-$track/qa.mp4' ]"
done

# --- T3: an unknown track falls back to lounge -----------------------------
cat > "$TMPROOT/bogus.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('the reveal button is present', () => see('Reveal'));
};
EOF
node "$RUN" "$TMPROOT/bogus.spec.js" --out "$TMPROOT/bogusout" --base "$BASE" --no-auth --music not-a-real-track >/dev/null 2>&1
BJSON="$TMPROOT/bogusout/steps.json"
chk "T3 unknown track falls back to lounge" "[ \"\$(sj '$BJSON' 'd.music')\" = lounge ]"
chk "T3 mp4 still encoded"                  "[ -s '$TMPROOT/bogusout/qa.mp4' ]"

# --- T4: with NO --music, the default bed is DETERMINISTIC per scenario ------
# A random default would make two runs of one scenario differ for no reason and
# defeat a model-free re-run; the bed is hashed from the scenario name, so
# the same scenario always lands on the same track.
cat > "$TMPROOT/det.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('the reveal button is present', () => see('Reveal'));
};
module.exports.meta = { name: 'Deterministic bed check' };
EOF
node "$RUN" "$TMPROOT/det.spec.js" --out "$TMPROOT/det1" --base "$BASE" --no-auth >/dev/null 2>&1
node "$RUN" "$TMPROOT/det.spec.js" --out "$TMPROOT/det2" --base "$BASE" --no-auth >/dev/null 2>&1
M1=$(sj "$TMPROOT/det1/steps.json" 'd.music'); M2=$(sj "$TMPROOT/det2/steps.json" 'd.music')
chk "T4 default track is a real bed"        "[ -n \"$M1\" ] && echo 'lounge twilight sunrise reggae ska' | grep -qw \"$M1\""
chk "T4 same scenario -> same default bed"  "[ -n \"$M1\" ] && [ \"$M1\" = \"$M2\" ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
