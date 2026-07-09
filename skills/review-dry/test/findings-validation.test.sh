#!/usr/bin/env bash
# Behavioral test for format.js's findings.json schema guard: a malformed
# findings file must fail LOUDLY — a specific, entry-named error on stderr and a
# non-zero exit — instead of silently degrading into a wrong or empty QA comment.
# findings.json is a JSON ARRAY of { severity, summary, frame }, all three keys
# required per entry; severity is blocker|major|minor (never nit — the review
# does not report nits, so a nit finding is rejected); frame is a basename
# that actually exists under the evidence dir's frames/. Any author (Claude or
# not) that writes a bad file gets stopped here. Pure Node + fs.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
FMT="$DIR/format.js"
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# format.js findings.json validation"

# A minimal valid run: one passing checkpoint, and a frame the finding can cite.
mkrun() {
  local run="$1"; mkdir -p "$run/frames"; : > "$run/frames/05-scroll.png"
  cat > "$run/steps.json" <<'EOF'
{
  "name": "Guard",
  "verdict": "PASS",
  "steps": [
    { "n": 1, "action": "see", "checkpoint": true, "caption": "A shows", "ok": true, "frame": "/x/frames/01-see.png" }
  ]
}
EOF
}

# --- a well-formed findings.json still renders fine (no regression) ----------
GOOD="$TMP/good"; mkrun "$GOOD"
cat > "$GOOD/findings.json" <<'EOF'
[ { "severity": "minor", "summary": "Footer overlaps the total at mobile widths", "frame": "05-scroll.png" } ]
EOF
OUT=$(node "$FMT" "$GOOD" 2>"$TMP/good.err"); rc=$?
chk "valid: exits zero"                  "[ $rc -eq 0 ]"
chk "valid: still writes comment.md"     "[ -f '$GOOD/comment.md' ]"
chk "valid: no error on stderr"          "[ ! -s '$TMP/good.err' ]"

# --- findings.json that is not an array --------------------------------------
NA="$TMP/notarray"; mkrun "$NA"
echo '{ "severity": "minor", "summary": "x", "frame": "05-scroll.png" }' > "$NA/findings.json"
ERR=$(node "$FMT" "$NA" 2>&1 >/dev/null); rc=$?
chk "not-array: exits non-zero"          "[ $rc -ne 0 ]"
chk "not-array: names the problem"       "echo \"\$ERR\" | grep -q 'must be a JSON array'"

# --- invalid JSON ------------------------------------------------------------
BAD="$TMP/badjson"; mkrun "$BAD"
echo '[ { not json } ]' > "$BAD/findings.json"
ERR=$(node "$FMT" "$BAD" 2>&1 >/dev/null); rc=$?
chk "bad-json: exits non-zero"           "[ $rc -ne 0 ]"
chk "bad-json: names the problem"        "echo \"\$ERR\" | grep -q 'not valid JSON'"

# --- entry missing severity --------------------------------------------------
MS="$TMP/missing-sev"; mkrun "$MS"
echo '[ { "summary": "x", "frame": "05-scroll.png" } ]' > "$MS/findings.json"
ERR=$(node "$FMT" "$MS" 2>&1 >/dev/null); rc=$?
chk "missing-severity: exits non-zero"   "[ $rc -ne 0 ]"
chk "missing-severity: names entry 0"    "echo \"\$ERR\" | grep -q 'entry 0'"
chk "missing-severity: names the key"    "echo \"\$ERR\" | grep -q 'severity'"

# --- entry missing summary ---------------------------------------------------
MSU="$TMP/missing-sum"; mkrun "$MSU"
echo '[ { "severity": "minor", "frame": "05-scroll.png" } ]' > "$MSU/findings.json"
ERR=$(node "$FMT" "$MSU" 2>&1 >/dev/null); rc=$?
chk "missing-summary: exits non-zero"    "[ $rc -ne 0 ]"
chk "missing-summary: names the key"     "echo \"\$ERR\" | grep -q 'summary'"

# --- entry missing frame -----------------------------------------------------
MF="$TMP/missing-frame"; mkrun "$MF"
echo '[ { "severity": "minor", "summary": "x" } ]' > "$MF/findings.json"
ERR=$(node "$FMT" "$MF" 2>&1 >/dev/null); rc=$?
chk "missing-frame: exits non-zero"      "[ $rc -ne 0 ]"
chk "missing-frame: names the key"       "echo \"\$ERR\" | grep -q 'frame'"

# --- unknown severity value --------------------------------------------------
US="$TMP/unknown-sev"; mkrun "$US"
echo '[ { "severity": "critical", "summary": "x", "frame": "05-scroll.png" } ]' > "$US/findings.json"
ERR=$(node "$FMT" "$US" 2>&1 >/dev/null); rc=$?
chk "unknown-severity: exits non-zero"   "[ $rc -ne 0 ]"
chk "unknown-severity: names the value"  "echo \"\$ERR\" | grep -q 'critical'"
chk "unknown-severity: entry named"      "echo \"\$ERR\" | grep -q 'entry 0'"

# --- `nit` is rejected: the review never reports nits ------------------------
NIT="$TMP/nit-sev"; mkrun "$NIT"
echo '[ { "severity": "nit", "summary": "x", "frame": "05-scroll.png" } ]' > "$NIT/findings.json"
ERR=$(node "$FMT" "$NIT" 2>&1 >/dev/null); rc=$?
chk "nit-severity: exits non-zero"       "[ $rc -ne 0 ]"
chk "nit-severity: rejected as unknown"  "echo \"\$ERR\" | grep -q 'nit'"

# --- a cited frame that was never captured -----------------------------------
NF="$TMP/no-frame"; mkrun "$NF"
echo '[ { "severity": "minor", "summary": "x", "frame": "99-never.png" } ]' > "$NF/findings.json"
ERR=$(node "$FMT" "$NF" 2>&1 >/dev/null); rc=$?
chk "absent-frame: exits non-zero"       "[ $rc -ne 0 ]"
chk "absent-frame: names the frame"      "echo \"\$ERR\" | grep -q '99-never.png'"
chk "absent-frame: says under frames/"   "echo \"\$ERR\" | grep -q 'frames/'"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
