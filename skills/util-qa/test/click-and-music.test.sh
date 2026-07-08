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
cat > "$TMPROOT/click.md" <<EOF
# click still works with cursor highlight
- visit /
- click element #go
- see "$REVEAL" :: The revealed text appears after the click
EOF
node "$RUN" "$TMPROOT/click.md" --out "$TMPROOT/clickout" --base "$BASE" --no-auth --music lounge >/dev/null 2>&1
rc=$?
CJSON="$TMPROOT/clickout/steps.json"
chk "T1 runner exits zero"                 "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                    "[ \"\$(sj '$CJSON' 'd.verdict')\" = PASS ]"
chk "T1 click step passed"                  "[ \"\$(sj '$CJSON' 'd.steps[1].ok')\" = true ]"
chk "T1 revealed-text checkpoint passed"    "[ \"\$(sj '$CJSON' 'd.steps[2].ok')\" = true ]"

# --- T2: every named music track produces a valid mp4 ----------------------
for track in lounge twilight sunrise reggae ska; do
  cat > "$TMPROOT/m.md" <<EOF
# music $track
- visit /
- see "Reveal"
EOF
  node "$RUN" "$TMPROOT/m.md" --out "$TMPROOT/m-$track" --base "$BASE" --no-auth --music "$track" >/dev/null 2>&1
  MJSON="$TMPROOT/m-$track/steps.json"
  chk "T2 [$track] recorded in manifest"    "[ \"\$(sj '$MJSON' 'd.music')\" = $track ]"
  chk "T2 [$track] mp4 encoded (non-empty)" "[ -s '$TMPROOT/m-$track/qa.mp4' ]"
done

# --- T3: an unknown track falls back to lounge -----------------------------
cat > "$TMPROOT/bogus.md" <<EOF
# music fallback
- visit /
- see "Reveal"
EOF
node "$RUN" "$TMPROOT/bogus.md" --out "$TMPROOT/bogusout" --base "$BASE" --no-auth --music not-a-real-track >/dev/null 2>&1
BJSON="$TMPROOT/bogusout/steps.json"
chk "T3 unknown track falls back to lounge" "[ \"\$(sj '$BJSON' 'd.music')\" = lounge ]"
chk "T3 mp4 still encoded"                  "[ -s '$TMPROOT/bogusout/qa.mp4' ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
