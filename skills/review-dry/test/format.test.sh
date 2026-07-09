#!/usr/bin/env bash
# Behavioral test for format.js: turning a run's steps.json into comment.md,
# the "### 👓 QA" block of the canonical review-comment template.
# Two styles are proven here:
#   VIDEO (default) — count line, a terse ✅/⚠️ checkpoint checklist (no
#   table), the video inline, then below it the QA script in a collapsible
#   <details> (always present when there is a video); ONLY the failing
#   checkpoint's frame is embedded. --list-frames names just failing + finding
#   frames.
#   FRAMES (--frames) — the checkpoint table: failing row sorts FIRST, opens
#   by default, carries ⚠️; passing rows collapse with ✅; video + script in
#   one collapsed block; --list-frames names every row frame too.
# In both: findings are never rendered (they ride in the review skill's Top
# points) and captions are HTML-escaped. Pure Node + fs.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FMT="$DIR/format.js"
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }
# comment.md contains a (possibly unicode/multiline) substring?
has() { node -e "process.exit(require('fs').readFileSync(process.argv[1],'utf8').includes(process.argv[2])?0:1)" "$1" "$2"; }
# in file $1, does needle $2 appear before needle $3?
before() { node -e "const s=require('fs').readFileSync(process.argv[1],'utf8');const a=s.indexOf(process.argv[2]),b=s.indexOf(process.argv[3]);process.exit(a>=0&&b>=0&&a<b?0:1)" "$1" "$2" "$3"; }

echo "# format.js (steps.json -> comment.md)"

# --- fixture: a FAIL run — cp1 passes, cp2 fails --------------------------
FRUN="$TMP/failrun"; mkdir -p "$FRUN/frames"
cat > "$FRUN/steps.json" <<'EOF'
{
  "name": "Registration order summary",
  "verdict": "FAIL",
  "base": "http://x",
  "music": "sunrise",
  "steps": [
    { "n": 1, "action": "visit", "checkpoint": false, "caption": "visit /r", "ok": true },
    { "n": 2, "action": "see", "checkpoint": true, "caption": "Order summary shows the amount due today", "ok": true, "frame": "/old/frames/02-see.png" },
    { "n": 3, "action": "see", "checkpoint": true, "caption": "Total survives contact edit", "ok": false, "error": "see \"Total due today\" timed out", "frame": "/old/frames/03-see.png" }
  ],
  "video": "/old/qa.mp4"
}
EOF
cat > "$TMP/assets.json" <<'EOF'
{ "02-see.png": "https://github.com/user-attachments/assets/PASSURL",
  "03-see.png": "https://github.com/user-attachments/assets/FAILURL" }
EOF
printf "module.exports = async ({ visit, checkpoint, see }) => {\n  await visit('/r');\n  await checkpoint('order summary', () => see('Total due today'));\n};\n" > "$TMP/scenario.spec.js"
# An eyeballed defect no assertion caught, on a NON-checkpoint frame, with a
# code lead meant only for review.
cat > "$FRUN/findings.json" <<'EOF'
[ { "severity": "minor", "summary": "Footer overlaps the total at mobile widths", "frame": "05-scroll.png", "forReview": "check the flex-wrap in OrderSummary.css" } ]
EOF

# ---------- VIDEO style (default) ------------------------------------------
node "$FMT" "$FRUN" --assets "$TMP/assets.json" \
  --video "https://github.com/user-attachments/assets/VIDURL" --scenario "$TMP/scenario.spec.js" >/dev/null 2>&1
rc=$?
CMT="$FRUN/comment.md"; cp "$CMT" "$TMP/video-comment.md"; VCMT="$TMP/video-comment.md"
chk "video: exits zero"                  "[ $rc -eq 0 ]"
chk "video: QA heading present"          "has '$VCMT' '### 👓 QA'"
chk "video: status counts 1/2 passed"    "has '$VCMT' '1 / 2 checkpoints passed'"
chk "video: flags failing checkpoint"    "has '$VCMT' 'checkpoint 2 needs another look'"
chk "video: NO table"                    "! has '$VCMT' '<table>'"
chk "video: pass checklist line"         "has '$VCMT' '- ✅ Order summary shows the amount due today'"
chk "video: fail checklist line"         "has '$VCMT' '- ⚠️ Total survives contact edit'"
chk "video: error text on fail line"     "has '$VCMT' 'timed out'"
chk "video: failing frame embedded"      "has '$VCMT' 'assets/FAILURL'"
chk "video: passing frame NOT embedded"  "! has '$VCMT' 'assets/PASSURL'"
chk "video: video url inline"            "has '$VCMT' 'assets/VIDURL'"
chk "video: video is inline (before the script details)" "before '$VCMT' 'assets/VIDURL' '<details>'"
chk "video: script in a details/summary" "has '$VCMT' '<summary>📜 QA script</summary>'"
chk "video: script content present"      "has '$VCMT' \"visit('/r')\""
chk "video: script BELOW the video"      "before '$VCMT' 'assets/VIDURL' \"visit('/r')\""
chk "video: no combined 🎬 block"        "! has '$VCMT' '🎬 Video & QA script'"
chk "video: no Issues observed section"  "! has '$VCMT' 'Issues observed'"
chk "video: forReview lead NOT present"  "! has '$VCMT' 'OrderSummary.css'"
chk "video: no sha footer"               "! has '$VCMT' 'verified against'"

# video-mode --list-frames: only the failing frame + finding frames.
LF=$(node "$FMT" "$FRUN" --list-frames 2>/dev/null)
chk "video list-frames: fail frame"      "echo \"\$LF\" | grep -q '$FRUN/frames/03-see.png'"
chk "video list-frames: finding frame"   "echo \"\$LF\" | grep -q '$FRUN/frames/05-scroll.png'"
chk "video list-frames: NO pass frame"   "! echo \"\$LF\" | grep -q '02-see.png'"

# ---------- FRAMES style (--frames) -----------------------------------------
node "$FMT" "$FRUN" --frames --assets "$TMP/assets.json" \
  --video "https://github.com/user-attachments/assets/VIDURL" --scenario "$TMP/scenario.spec.js" >/dev/null 2>&1
rc=$?
TCMT="$FRUN/comment.md"
chk "frames: exits zero"                 "[ $rc -eq 0 ]"
chk "frames: QA heading present"         "has '$TCMT' '### 👓 QA'"
chk "frames: table present"              "has '$TCMT' '<table>'"
chk "frames: failing row opens"          "has '$TCMT' '<details open>'"
chk "frames: failing glyph"              "has '$TCMT' '⚠️'"
chk "frames: passing glyph"              "has '$TCMT' '✅'"
chk "frames: error text surfaced"        "has '$TCMT' 'timed out'"
chk "frames: pass frame url embedded"    "has '$TCMT' 'assets/PASSURL'"
chk "frames: fail frame url embedded"    "has '$TCMT' 'assets/FAILURL'"
chk "frames: failing row sorts FIRST"    "before '$TCMT' 'assets/FAILURL' 'assets/PASSURL'"
chk "frames: combined video+script"      "has '$TCMT' '🎬 Video & QA script'"
chk "frames: video url in block"         "has '$TCMT' 'assets/VIDURL'"
chk "frames: no Issues observed"         "! has '$TCMT' 'Issues observed'"

# frames-mode --list-frames: row frames AND finding frames.
LFT=$(node "$FMT" "$FRUN" --frames --list-frames 2>/dev/null)
chk "frames list-frames: pass frame"     "echo \"\$LFT\" | grep -q '$FRUN/frames/02-see.png'"
chk "frames list-frames: fail frame"     "echo \"\$LFT\" | grep -q '$FRUN/frames/03-see.png'"
chk "frames list-frames: finding frame"  "echo \"\$LFT\" | grep -q '$FRUN/frames/05-scroll.png'"

# --- fixture: a clean PASS run (video default) ------------------------------
PRUN="$TMP/passrun"; mkdir -p "$PRUN"
cat > "$PRUN/steps.json" <<'EOF'
{
  "name": "All good",
  "verdict": "PASS",
  "steps": [
    { "n": 1, "action": "see", "checkpoint": true, "caption": "A shows", "ok": true, "frame": "/x/frames/01-see.png" },
    { "n": 2, "action": "see", "checkpoint": true, "caption": "B shows", "ok": true, "frame": "/x/frames/02-see.png" }
  ]
}
EOF
node "$FMT" "$PRUN" >/dev/null 2>&1
PCMT="$PRUN/comment.md"
chk "pass run: 2/2 passed"               "has '$PCMT' '2 / 2 checkpoints passed'"
chk "pass run: checklist only"           "! has '$PCMT' '<table>'"
chk "pass run: no warning glyph"         "! has '$PCMT' '⚠️'"
chk "pass run: no script when none given" "! has '$PCMT' '📜'"

# A PASS run WITH a scenario must STILL carry the script (in its <details>)
# below the video — this is exactly what the real review missed: a clean pass
# shipped with no script at all.
node "$FMT" "$PRUN" --video "https://github.com/user-attachments/assets/VIDURL2" --scenario "$TMP/scenario.spec.js" >/dev/null 2>&1
chk "pass+script: script present"        "has '$PCMT' '<summary>📜 QA script</summary>'"
chk "pass+script: script BELOW video"    "before '$PCMT' 'assets/VIDURL2' \"visit('/r')\""

# --- custom heading (--heading, for pr-dry taking over the PR's QA section) --
# pr-dry renders the QA block as a top-level "## 👓 QA" PR section — same label
# as the review comment's "### 👓 QA", one heading level up.
node "$FMT" "$PRUN" --heading '## 👓 QA' >/dev/null 2>&1
chk "heading: custom heading used"       "has '$PCMT' '## 👓 QA'"
chk "heading: default heading absent"    "! has '$PCMT' '### 👓 QA'"
node "$FMT" "$PRUN" --frames --heading '## 👓 QA' >/dev/null 2>&1
chk "heading: works with --frames too"   "has '$PCMT' '## 👓 QA'"

# --- pr-dry take-over parity: the PR's "## 👓 QA" section IS the review comment's
#     "### 👓 QA" block with only the heading level swapped. Render both from the
#     SAME evidence and prove the bodies (everything below the heading line) are
#     byte-identical — so a PR's QA section always matches the review's QA block.
node "$FMT" "$FRUN" --assets "$TMP/assets.json" \
  --video "https://github.com/user-attachments/assets/VIDURL" --scenario "$TMP/scenario.spec.js" >/dev/null 2>&1
tail -n +2 "$FRUN/comment.md" > "$TMP/qa-body.txt"
node "$FMT" "$FRUN" --heading '## 👓 QA' --assets "$TMP/assets.json" \
  --video "https://github.com/user-attachments/assets/VIDURL" --scenario "$TMP/scenario.spec.js" >/dev/null 2>&1
tail -n +2 "$FRUN/comment.md" > "$TMP/pr-body.txt"
chk "parity: PR render leads with its heading" "node -e \"process.exit(require('fs').readFileSync('$FRUN/comment.md','utf8').startsWith('## 👓 QA\n')?0:1)\""
chk "parity: PR QA body == review QA body"      "diff -q '$TMP/qa-body.txt' '$TMP/pr-body.txt' >/dev/null"

# --- escaping: caption with HTML metacharacters (video checklist) -----------
XRUN="$TMP/xrun"; mkdir -p "$XRUN"
cat > "$XRUN/steps.json" <<'EOF'
{
  "name": "Esc",
  "verdict": "PASS",
  "steps": [
    { "n": 1, "action": "see", "checkpoint": true, "caption": "shows <b> & \"x\"", "ok": true, "frame": "/x/frames/01-see.png" }
  ]
}
EOF
node "$FMT" "$XRUN" >/dev/null 2>&1
XCMT="$XRUN/comment.md"
chk "caption HTML-escaped (video)"       "has '$XCMT' 'shows &lt;b&gt; &amp; &quot;x&quot;'"
chk "no raw angle bracket in caption"    "! has '$XCMT' 'shows <b>'"
node "$FMT" "$XRUN" --frames >/dev/null 2>&1
chk "caption HTML-escaped (frames)"      "has '$XCMT' 'shows &lt;b&gt; &amp; &quot;x&quot;'"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
