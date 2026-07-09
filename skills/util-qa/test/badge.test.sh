#!/usr/bin/env bash
# Behavioral tests for the profile-controlled corner badge.
#
# The little SVG on the video is no longer a hardcoded engine asset: each repo's
# profile owns it. profiles/<repo>.json carries a `badge` map of state -> SVG
# filename (resolved against profiles/), and the engine ships NO default — a
# profile with no `badge`, or one that omits a state, simply shows nothing there.
#
#   1. loadBadges reads the mapped SVGs, keyed by state, from the profile config:
#      present files load, missing files are dropped (not fatal), an absent map
#      yields {}, and an absolute path is honored as-is.
#   2. A run whose profile defines a badge still passes and encodes an mp4 — the
#      config -> badges -> caption wiring never throws for a real badge.
# Needs: node + playwright/chromium + ffmpeg + python3 (the skill's own deps).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
SRV=""
PROFILE="$DIR/profiles/zz-badge-test.json"   # temp profile; removed on exit
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$TMPROOT"; rm -f "$PROFILE"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }
sj()  { node -e "const d=require('$1');console.log($2)" 2>/dev/null; }

echo "# profile-controlled badge"

# --- badge SVGs (unique markers so we can prove which file loaded) ----------
BADGES="$TMPROOT/badges"; mkdir -p "$BADGES"
printf '<svg id="PASSMARK"/>'    > "$BADGES/pass.svg"
printf '<svg id="RUNMARK"/>'     > "$BADGES/run.svg"
ABS="$BADGES/pass.svg"

# --- T1: loadBadges maps present state files to their SVG content -----------
chk "T1 loads mapped pass SVG by state" \
  "node -e \"const {loadBadges}=require('$RUN');const b=loadBadges({badge:{pass:'pass.svg',running:'run.svg'}},'$BADGES');process.exit(b.pass&&b.pass.includes('PASSMARK')&&b.running.includes('RUNMARK')?0:1)\""

# --- T2: a state whose file is missing is dropped, not fatal ----------------
chk "T2 missing badge file is omitted" \
  "node -e \"const {loadBadges}=require('$RUN');const b=loadBadges({badge:{pass:'pass.svg',fail:'nope.svg'}},'$BADGES');process.exit(('pass' in b)&&!('fail' in b)?0:1)\" 2>/dev/null"

# --- T3: no badge map (or no config at all) yields an empty map -------------
chk "T3 no badge key -> {}" \
  "node -e \"const {loadBadges}=require('$RUN');process.exit(Object.keys(loadBadges({})).length===0?0:1)\""
chk "T3 undefined config -> {}" \
  "node -e \"const {loadBadges}=require('$RUN');process.exit(Object.keys(loadBadges(undefined)).length===0?0:1)\""

# --- T4: an absolute path is honored regardless of the base dir -------------
chk "T4 absolute badge path is honored" \
  "node -e \"const {loadBadges}=require('$RUN');const b=loadBadges({badge:{pass:'$ABS'}},'/no/such/base');process.exit(b.pass&&b.pass.includes('PASSMARK')?0:1)\""

# --- fixture + server for the end-to-end wiring check -----------------------
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
cat > "$FIX/index.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>fix</title>
<h1>Badge fixture</h1>
HTML
PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# --- T5: a profile that defines a badge runs green and encodes an mp4 -------
# The temp profile references the badge SVGs by absolute path, so the run
# exercises the real config -> loadBadges -> setCaption path end to end.
cat > "$PROFILE" <<EOF
{ "badge": { "pass": "$BADGES/pass.svg", "running": "$BADGES/run.svg", "fail": "$BADGES/pass.svg" } }
EOF
cat > "$TMPROOT/badge.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('The page renders under the badge', () => see('Badge fixture'));
};
EOF
node "$RUN" "$TMPROOT/badge.spec.js" --out "$TMPROOT/badgeout" --base "$BASE" --no-auth --repo zz-badge-test --music lounge >/dev/null 2>&1
rc=$?
BJSON="$TMPROOT/badgeout/steps.json"
chk "T5 runner exits zero with a badge"  "[ $rc -eq 0 ]"
chk "T5 verdict is PASS"                 "[ \"\$(sj '$BJSON' 'd.verdict')\" = PASS ]"
chk "T5 mp4 encoded (non-empty)"         "[ -s '$TMPROOT/badgeout/qa.mp4' ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
