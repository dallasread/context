#!/usr/bin/env bash
# Behavioral test for format.js: turning a run's steps.json into comment.md,
# the "### 👓 QA" block of the canonical review-comment template.
# Proves (a) the checkpoint table renders with the uploaded frame URLs; (b) a
# failing checkpoint sorts FIRST, opens by default, and carries the ⚠️ glyph
# while passing rows collapse with ✅; (c) the error text is surfaced; (d) the
# video and QA script share ONE collapsed details block; (e) findings are NOT
# rendered (they ride in the review skill's authored Top points) but their
# frames ARE in --list-frames so Top points can link them; (f) a clean run
# reads as "K / K passed" with no open row and no ⚠️. Pure Node + fs.
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
printf '# Registration order summary\n- visit /r\n' > "$TMP/scenario.md"
# An eyeballed defect no assertion caught, on a NON-checkpoint frame, with a
# code lead meant only for review.
cat > "$FRUN/findings.json" <<'EOF'
[ { "severity": "minor", "summary": "Footer overlaps the total at mobile widths", "frame": "05-scroll.png", "forReview": "check the flex-wrap in OrderSummary.css" } ]
EOF

node "$FMT" "$FRUN" --assets "$TMP/assets.json" \
  --video "https://github.com/user-attachments/assets/VIDURL" --scenario "$TMP/scenario.md" >/dev/null 2>&1
rc=$?
CMT="$FRUN/comment.md"
chk "exits zero"                        "[ $rc -eq 0 ]"
chk "writes comment.md"                 "[ -f '$CMT' ]"
chk "QA heading present"                "has '$CMT' '### 👓 QA'"
chk "old run-name heading gone"         "! has '$CMT' '## QA —'"
chk "status counts 1/2 passed"          "has '$CMT' '1 / 2 checkpoints passed'"
chk "flags the failing checkpoint"      "has '$CMT' 'checkpoint 2 needs another look'"
chk "failing row opens by default"      "has '$CMT' '<details open>'"
chk "passing row stays collapsed"       "has '$CMT' '<details>'"
chk "failing glyph present"             "has '$CMT' '⚠️'"
chk "passing glyph present"             "has '$CMT' '✅'"
chk "error text surfaced"               "has '$CMT' 'timed out'"
chk "pass frame url embedded"           "has '$CMT' 'assets/PASSURL'"
chk "fail frame url embedded"           "has '$CMT' 'assets/FAILURL'"
chk "failing row sorts FIRST"           "before '$CMT' 'assets/FAILURL' 'assets/PASSURL'"
chk "no sha footer (lead owns the sha)" "! has '$CMT' 'verified against'"
chk "combined video+script summary"     "has '$CMT' '🎬 Video & QA script'"
chk "video url inside the block"        "has '$CMT' 'assets/VIDURL'"
chk "qa script inside the block"        "has '$CMT' 'visit /r'"
chk "video precedes script in block"    "before '$CMT' 'assets/VIDURL' 'visit /r'"
chk "no separate script details"        "! has '$CMT' '📜 QA script'"

# Findings are the review skill's to render (tagged Top points), never format.js's.
chk "no Issues observed section"        "! has '$CMT' 'Issues observed'"
chk "no severity shouting"              "! has '$CMT' '**BLOCKER**'"
chk "authored observation NOT rendered" "! has '$CMT' 'Footer overlaps the total'"
chk "forReview lead NOT in comment"     "! has '$CMT' 'OrderSummary.css'"

# --list-frames reports checkpoint + failing frames AND finding frames, so the
# authored Top points can link a finding's screenshot.
LF=$(node "$FMT" "$FRUN" --list-frames 2>/dev/null)
chk "list-frames finds pass frame"      "echo \"\$LF\" | grep -q '$FRUN/frames/02-see.png'"
chk "list-frames finds fail frame"      "echo \"\$LF\" | grep -q '$FRUN/frames/03-see.png'"
chk "list-frames finds finding frame"   "echo \"\$LF\" | grep -q '$FRUN/frames/05-scroll.png'"
chk "list-frames writes no comment"     "[ ! -f '$TMP/none/comment.md' ]"

# --- fixture: a clean PASS run --------------------------------------------
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
chk "pass run: no open row"              "! has '$PCMT' '<details open>'"
chk "pass run: no warning glyph"         "! has '$PCMT' '⚠️'"
chk "pass run: no video/script block"    "! has '$PCMT' '🎬'"

# --- escaping: caption/error with HTML metacharacters ----------------------
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
chk "caption HTML-escaped"               "has '$XCMT' 'shows &lt;b&gt; &amp; &quot;x&quot;'"
chk "no raw angle bracket in caption"    "! has '$XCMT' 'shows <b>'"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
