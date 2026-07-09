#!/usr/bin/env bash
# Behavioral test for CREDENTIAL/VARIABLE INJECTION into a JS scenario.
# The profile (profiles/<repo>.json) owns a `variables` map; login macros already
# read it via $NAME. This proves the JS scenario body reads the SAME map as `vars`,
# so a scenario references a secret BY NAME and never embeds the literal. Three
# properties, all load-bearing for the no-model re-run:
#   (a) delivery — `vars.X` yields the REAL configured value at runtime (a
#       see()/fill() against it behaves as if the literal were typed);
#   (b) faithful saved copy — the scenario copy the runner writes into the
#       evidence dir still reads `vars.X`, NOT the secret, so redaction has
#       nothing to scrub and a later model-free `qa.sh` re-run drives it identically;
#   (c) no leak — a secret value that DOES reach a caption is redacted out of
#       steps.json by the existing backstop.
# Drives run.js against a trivial static fixture with a profile passed by path.
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

echo "# vars injection (profile variables -> scenario harness)"

# --- fixture: a page whose visible text IS the secret value, plus an input ----
SECRET="s3cr3t-qa-value-9931"
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
printf '<!doctype html><meta charset=utf-8><title>fix</title><h1>SENTINEL %s</h1><input id="q">' "$SECRET" > "$FIX/index.html"

# --- profile carrying the secret as a named variable, passed to run.js by path
PROFILE="$TMPROOT/test-profile.json"
printf '{"variables":{"SECRET":"%s"}}' "$SECRET" > "$PROFILE"

PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
( cd "$FIX" && exec python3 -m http.server "$PORT" ) >/dev/null 2>&1 &
SRV=$!
BASE="http://localhost:$PORT"
for i in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null)" != "000" ] && break
  sleep 0.25
done

# The scenario NEVER contains the literal secret — only `vars.SECRET`. It (1) sees
# the injected value on the page, (2) fills the input with it and asserts the field
# got the real value, (3) puts the value in a caption to exercise redaction.
cat > "$TMPROOT/vars.spec.js" <<'EOF'
module.exports = async ({ page, checkpoint, visit, see, fill, vars }) => {
  await visit('/');
  await checkpoint('The injected value matches the on-page sentinel', () => see(vars.SECRET));
  await fill('#q', vars.SECRET);
  await checkpoint('The field received the real injected value', () =>
    page.locator('#q').evaluate((el, v) => { if (el.value !== v) throw new Error('field value mismatch'); }, vars.SECRET));
  await checkpoint('Value ' + vars.SECRET + ' in the caption', () => see(vars.SECRET));
};
EOF
node "$RUN" "$TMPROOT/vars.spec.js" --out "$TMPROOT/out" --base "$BASE" --repo "$PROFILE" --no-auth >/dev/null 2>&1
rc=$?
JSON="$TMPROOT/out/steps.json"
SAVED="$TMPROOT/out/vars.spec.js"

# (a) delivery: the run passed, which is only possible if `vars.SECRET` resolved
#     to the real value the fixture and the fill assertion both check against.
chk "T1 runner exits zero"                   "[ $rc -eq 0 ]"
chk "T1 verdict is PASS"                      "[ \"\$(sj '$JSON' 'd.verdict')\" = PASS ]"
chk "T1 see(vars.SECRET) checkpoint passed"   "[ \"\$(sj '$JSON' 'd.steps[0].ok')\" = true ]"
chk "T1 fill(vars.SECRET) checkpoint passed"  "[ \"\$(sj '$JSON' 'd.steps[1].ok')\" = true ]"

# (b) faithful saved copy: still references vars.SECRET, never the literal secret.
chk "T2 saved scenario copy exists"           "[ -f '$SAVED' ]"
chk "T2 saved copy still reads vars.SECRET"   "grep -q 'vars.SECRET' '$SAVED'"
chk "T2 saved copy has no literal secret"     "! grep -q '$SECRET' '$SAVED'"

# (c) no leak: the secret that reached a caption is redacted out of steps.json.
chk "T3 steps.json carries no literal secret" "! grep -q '$SECRET' '$JSON'"

echo
echo "# vars: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
