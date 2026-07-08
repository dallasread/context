#!/usr/bin/env bash
# Pins the `viewport: <w>x<h>` markdown scenario setting. A scenario can size the
# browser (and the recorded video/frames) so the same pages can be captured at a
# desktop and a mobile width. Proves: the line parses into scenario.viewport, it
# is recorded in steps.json, it actually sizes the frame PNGs, and its absence
# falls back to the documented 1280x900 default.
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
# PNG width lives in the IHDR chunk at bytes 16-19, big-endian. Read it with no
# image dependency so the test only needs the skill's own deps.
pngw() { node -e "const b=require('fs').readFileSync('$1');console.log(b.readUInt32BE(16))" 2>/dev/null; }

echo "# viewport setting"

FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
cat > "$FIX/index.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>vp</title>
<h1>Viewport Fixture Page</h1>
HTML

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T1: `viewport: 390x844` sizes the run and is recorded -------------------
cat > "$TMPROOT/mobile.md" <<'EOF'
# viewport - mobile width sizes the capture
hold: 0ms
viewport: 390x844
- visit /
- see "Viewport Fixture Page" :: Page renders at the requested width
EOF
node "$RUN" "$TMPROOT/mobile.md" --out "$TMPROOT/mobileout" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
MJSON="$TMPROOT/mobileout/steps.json"
chk "T1 runner exits zero"                    "[ $rc -eq 0 ]"
chk "T1 viewport width recorded in manifest"  "[ \"\$(sj '$MJSON' 'd.viewport.width')\" = 390 ]"
chk "T1 viewport height recorded in manifest" "[ \"\$(sj '$MJSON' 'd.viewport.height')\" = 844 ]"
FRAME=$(ls "$TMPROOT/mobileout/frames/"*.png 2>/dev/null | head -1)
chk "T1 a frame PNG was written"              "[ -n \"$FRAME\" ]"
chk "T1 frame PNG is 390px wide"              "[ \"\$(pngw \"$FRAME\")\" = 390 ]"

# --- T2: no viewport line falls back to the documented default ---------------
cat > "$TMPROOT/default.md" <<'EOF'
# viewport - default when unset
hold: 0ms
- visit /
- see "Viewport Fixture Page" :: Page renders at default width
EOF
node "$RUN" "$TMPROOT/default.md" --out "$TMPROOT/defaultout" --base "$BASE" --no-auth >/dev/null 2>&1
DJSON="$TMPROOT/defaultout/steps.json"
chk "T2 default width is 1280"                "[ \"\$(sj '$DJSON' 'd.viewport.width')\" = 1280 ]"
chk "T2 default height is 900"                "[ \"\$(sj '$DJSON' 'd.viewport.height')\" = 900 ]"
DFRAME=$(ls "$TMPROOT/defaultout/frames/"*.png 2>/dev/null | head -1)
chk "T2 default frame PNG is 1280px wide"     "[ \"\$(pngw \"$DFRAME\")\" = 1280 ]"

echo
echo "# viewport: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
