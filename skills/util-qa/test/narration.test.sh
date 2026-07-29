#!/usr/bin/env bash
# Behavioral tests for accessibility narration: the runner reads the scenario's
# goal and each checkpoint's caption aloud (macOS `say`), muxed into qa.mp4's
# audio track under the music bed, so a viewer who cannot see the screen still
# gets the QA narrative. Detected at runtime — a host without `say` just skips
# narration; the run still passes and the manifest says so.
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

echo "# accessibility narration"

FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
cat > "$FIX/index.html" <<'HTML'
<!doctype html><meta charset=utf-8><title>fix</title>
<h1>Fixture home</h1>
HTML

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

cat > "$TMPROOT/n.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('The fixture home page loaded', () => see('Fixture home'));
};
module.exports.meta = { name: 'Narration smoke test' };
EOF

if command -v say >/dev/null 2>&1; then
  # --- T1: narration is on by default and lands in the manifest -------------
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/on" --base "$BASE" --no-auth >/dev/null 2>&1
  ONJSON="$TMPROOT/on/steps.json"
  chk "T1 narrated flag is true"                 "[ \"\$(sj '$ONJSON' 'd.narrated')\" = true ]"
  chk "T1 narration has the intro + 1 checkpoint" "[ \"\$(sj '$ONJSON' 'd.narration.length')\" = 2 ]"
  chk "T1 checkpoint narration matches its caption" \
    "[ \"\$(sj '$ONJSON' 'd.narration[1].text')\" = 'The fixture home page loaded' ]"
  chk "T1 checkpoint narration is offset after the intro" \
    "[ \"\$(sj '$ONJSON' 'd.narration[1].atSec >= d.narration[0].atSec')\" = true ]"
  chk "T1 mp4 still encoded (non-empty)"          "[ -s '$TMPROOT/on/qa.mp4' ]"
  chk "T1 no leftover narration audio files"      "[ ! -d '$TMPROOT/on/narration' ]"

  # --- T2: --no-narrate turns it off, no narration array at all ------------
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/off" --base "$BASE" --no-auth --no-narrate >/dev/null 2>&1
  OFFJSON="$TMPROOT/off/steps.json"
  chk "T2 narrated flag is false"                "[ \"\$(sj '$OFFJSON' 'd.narrated')\" = false ]"
  chk "T2 narration array is empty"              "[ \"\$(sj '$OFFJSON' 'd.narration.length')\" = 0 ]"
  chk "T2 mp4 still encoded (non-empty)"         "[ -s '$TMPROOT/off/qa.mp4' ]"

  # --- T3: meta.narrate = false disables it from the scenario itself --------
  cat > "$TMPROOT/quiet.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('The fixture home page loaded', () => see('Fixture home'));
};
module.exports.meta = { name: 'Quiet scenario', narrate: false };
EOF
  node "$RUN" "$TMPROOT/quiet.spec.js" --out "$TMPROOT/quiet" --base "$BASE" --no-auth >/dev/null 2>&1
  QJSON="$TMPROOT/quiet/steps.json"
  chk "T3 meta.narrate:false disables narration"  "[ \"\$(sj '$QJSON' 'd.narrated')\" = false ]"

  # --- T4b: the scenario can write its own spoken line + intro, distinct from
  # the on-screen caption — this is the "delightfully cheerful" / "funny and
  # long-winded" per-app voice hook, authored once in the .spec.js -----------
  cat > "$TMPROOT/styled.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint(
    'The fixture home page loaded',
    () => see('Fixture home'),
    { narrate: "Oh happy day, the fixture home page has gloriously loaded!" }
  );
};
module.exports.meta = { name: 'Styled scenario', intro: "Buckle up, we are about to review something magnificent." };
EOF
  node "$RUN" "$TMPROOT/styled.spec.js" --out "$TMPROOT/styled" --base "$BASE" --no-auth >/dev/null 2>&1
  SJSON="$TMPROOT/styled/steps.json"
  chk "T5 custom intro line is spoken, not the default"  \
    "[ \"\$(sj '$SJSON' 'd.narration[0].text')\" = 'Buckle up, we are about to review something magnificent.' ]"
  chk "T5 custom checkpoint narration overrides the caption" \
    "[ \"\$(sj '$SJSON' 'd.narration[1].text')\" = 'Oh happy day, the fixture home page has gloriously loaded!' ]"
  chk "T5 on-screen caption is unaffected by the narrate override" \
    "[ \"\$(sj '$SJSON' 'd.steps[0].caption')\" = 'The fixture home page loaded' ]"
  # --- T6: repo-level defaults (profiles/<repo>.js), overridable per scenario -
  cat > "$TMPROOT/quiet-repo.js" <<'EOF'
module.exports = { narrate: false };
EOF
  cat > "$TMPROOT/noop-repo.js" <<'EOF'
module.exports = { narrationIntro: false };
EOF

  # Repo default narrate:false, scenario says nothing -> off.
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/repo-off" --base "$BASE" --no-auth --repo "$TMPROOT/quiet-repo.js" >/dev/null 2>&1
  R1JSON="$TMPROOT/repo-off/steps.json"
  chk "T6 repo narrate:false disables narration by default" "[ \"\$(sj '$R1JSON' 'd.narrated')\" = false ]"

  # Same quiet repo, but the scenario explicitly opts back in -> on.
  cat > "$TMPROOT/opt-in.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('The fixture home page loaded', () => see('Fixture home'));
};
module.exports.meta = { name: 'Opt-in scenario', narrate: true };
EOF
  node "$RUN" "$TMPROOT/opt-in.spec.js" --out "$TMPROOT/repo-override" --base "$BASE" --no-auth --repo "$TMPROOT/quiet-repo.js" >/dev/null 2>&1
  R2JSON="$TMPROOT/repo-override/steps.json"
  chk "T6 scenario meta.narrate:true overrides a repo's narrate:false" "[ \"\$(sj '$R2JSON' 'd.narrated')\" = true ]"

  # Repo default narrationIntro:false, scenario doesn't set meta.intro -> checkpoint still narrated, no intro line.
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/repo-noop" --base "$BASE" --no-auth --repo "$TMPROOT/noop-repo.js" >/dev/null 2>&1
  R3JSON="$TMPROOT/repo-noop/steps.json"
  chk "T6 repo narrationIntro:false drops the intro but keeps checkpoints" \
    "[ \"\$(sj '$R3JSON' 'd.narration.length')\" = 1 ] && [ \"\$(sj '$R3JSON' 'd.narration[0].text')\" = 'The fixture home page loaded' ]"

  # meta.intro:false suppresses the intro for this scenario even under the (default) repo that would otherwise speak one.
  cat > "$TMPROOT/no-intro.spec.js" <<'EOF'
module.exports = async ({ visit, checkpoint, see }) => {
  await visit('/');
  await checkpoint('The fixture home page loaded', () => see('Fixture home'));
};
module.exports.meta = { name: 'No-intro scenario', intro: false };
EOF
  node "$RUN" "$TMPROOT/no-intro.spec.js" --out "$TMPROOT/no-intro" --base "$BASE" --no-auth >/dev/null 2>&1
  R4JSON="$TMPROOT/no-intro/steps.json"
  chk "T6 meta.intro:false suppresses the intro for this scenario" "[ \"\$(sj '$R4JSON' 'd.narration.length')\" = 1 ]"
  # --- T7: narrationVoice: 'random' in the profile picks one of the curated
  # "real" voices each run (true randomness — unlike the music bed's
  # per-scenario-name hash, a repo asking for variety wants it every run, not
  # a fixed pick per scenario name). --voice overrides the profile like --music
  # overrides meta.music. An explicit named voice still passes through as-is.
  cat > "$TMPROOT/random-repo.js" <<'EOF'
module.exports = { narrationVoice: 'random' };
EOF
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/voice-random" --base "$BASE" --no-auth --repo "$TMPROOT/random-repo.js" >/dev/null 2>&1
  VJSON="$TMPROOT/voice-random/steps.json"
  chk "T7 random voice is one of the curated choices" \
    "node -e \"const v=require('$VJSON').voice; const choices=['Samantha','Karen','Daniel','Moira','Tessa','Kathy']; process.exit(choices.includes(v)?0:1)\""

  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/voice-cli" --base "$BASE" --no-auth --repo "$TMPROOT/random-repo.js" --voice Daniel >/dev/null 2>&1
  VCJSON="$TMPROOT/voice-cli/steps.json"
  chk "T7 --voice overrides a profile's random voice" "[ \"\$(sj '$VCJSON' 'd.voice')\" = 'Daniel' ]"

  cat > "$TMPROOT/named-repo.js" <<'EOF'
module.exports = { narrationVoice: 'Moira' };
EOF
  node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/voice-named" --base "$BASE" --no-auth --repo "$TMPROOT/named-repo.js" >/dev/null 2>&1
  VNJSON="$TMPROOT/voice-named/steps.json"
  chk "T7 an explicit named voice passes through unchanged" "[ \"\$(sj '$VNJSON' 'd.voice')\" = 'Moira' ]"
else
  echo "# (say not found on this host — skipping narration content checks, T4 fallback still runs)"
fi

# --- T4: a `say` that can't produce audio degrades to no narration, never
# fails the run. Shadow the real `say` with a stub that always errors, rather
# than stripping PATH (this host resolves `node` itself through an asdf shim
# that needs sed/awk/grep/etc., so a bare-bones PATH breaks node before the
# narration code under test ever runs).
STUBDIR="$TMPROOT/stub"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/say" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$STUBDIR/say"
PATH="$STUBDIR:$PATH" node "$RUN" "$TMPROOT/n.spec.js" --out "$TMPROOT/nosayout2" --base "$BASE" --no-auth >/dev/null 2>&1
rc=$?
N2JSON="$TMPROOT/nosayout2/steps.json"
chk "T4 run still exits zero when say fails"      "[ $rc -eq 0 ]"
chk "T4 narrated is false when say fails"         "[ \"\$(sj '$N2JSON' 'd.narrated')\" = false ]"
chk "T4 mp4 still encoded when say fails"         "[ -s '$TMPROOT/nosayout2/qa.mp4' ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
