#!/usr/bin/env bash
# Behavioral test for the profile `baseHost` seam: a repo whose dev config
# serves its app on a non-localhost host (e.g. dnsimple-app's subapp split,
# app.dnsimple.localhost) declares `baseHost` in profiles/<repo>.js, and qa.sh
# builds BASE from it — no two-step warm-boot workaround. Uses the python stub
# + QA_SKIP_RUN seam like warm-server.test.sh, so no Rails and no browser.
# Needs: node + git + python3 + curl. Any *.localhost name resolves to
# loopback via the system resolver, so the fixture host needs no /etc/hosts.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
QA="$DIR/qa.sh"
STUB="python3 -m http.server \"\$PORT\""
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
FIX1="$DIR/profiles/qa-basehost-fixture.js"
FIX2="$DIR/profiles/qa-nobasehost-fixture.js"
trap 'pkill -f "http.server" 2>/dev/null; rm -f "$FIX1" "$FIX2"; rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

mkrepo() { d="$TMPROOT/$1"; mkdir -p "$d"; ( cd "$d" && git init -q ); echo "$d"; }
serverbase() { grep '^BASE=' "$1/tmp/qa/.warm-server" | cut -d= -f2-; }
responds() { [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$1/" 2>/dev/null)" != "000" ]; }

echo "# profile baseHost"

# --- T1: profile with baseHost -> BASE built from it, and it responds -------
printf 'module.exports = { serve: %s, baseHost: "qa-basehost.localhost" };\n' "'$STUB'" > "$FIX1"
A=$(mkrepo qa-basehost-fixture)
( cd "$A" && QA_SKIP_RUN=1 "$QA" dummy.spec.js "$A/out" --keep ) >/dev/null 2>&1
rc=$?
BASEA=$(serverbase "$A")
chk "T1 exits 0"                        "[ $rc -eq 0 ]"
chk "T1 BASE uses the profile host"     "echo '$BASEA' | grep -q '^http://qa-basehost.localhost:'"
chk "T1 readiness passed on that host"  "responds '$BASEA'"
( cd "$A" && "$QA" --stop ) >/dev/null 2>&1

# --- T2: profile without baseHost -> BASE falls back to localhost -----------
printf 'module.exports = { serve: %s };\n' "'$STUB'" > "$FIX2"
B=$(mkrepo qa-nobasehost-fixture)
( cd "$B" && QA_SKIP_RUN=1 "$QA" dummy.spec.js "$B/out" --keep ) >/dev/null 2>&1
BASEB=$(serverbase "$B")
chk "T2 BASE falls back to localhost"   "echo '$BASEB' | grep -q '^http://localhost:'"
( cd "$B" && "$QA" --stop ) >/dev/null 2>&1

# --- T3: run.js resolveBase precedence: --base > scenario > baseHost > default
out=$(node -e "
const { resolveBase } = require('$DIR/run.js');
console.log(resolveBase('http://x:1', 'http://y:2', { baseHost: 'h.localhost' }));
console.log(resolveBase(null, 'http://y:2', { baseHost: 'h.localhost' }));
console.log(resolveBase(null, null, { baseHost: 'h.localhost' }));
console.log(resolveBase(null, null, null));
")
chk "T3 --base wins"                    "echo \"\$out\" | sed -n 1p | grep -q '^http://x:1$'"
chk "T3 scenario base second"           "echo \"\$out\" | sed -n 2p | grep -q '^http://y:2$'"
chk "T3 baseHost fills the default"     "echo \"\$out\" | sed -n 3p | grep -q '^http://h.localhost:3000$'"
chk "T3 localhost fallback"             "echo \"\$out\" | sed -n 4p | grep -q '^http://localhost:3000$'"

echo
echo "# base-host: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
