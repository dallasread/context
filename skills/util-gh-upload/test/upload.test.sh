#!/usr/bin/env bash
# Behavioral test for post.js's zero-footprint contract: the util-gh-upload skill
# has no package.json/node_modules of its own — post.js must load by resolving
# playwright from the util-util-qa skill's install. If someone reintroduces a local
# dependency or breaks the cross-skill resolve, these go red.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# post.js (loads without a local npm install)"

chk "no local package.json"    "[ ! -e '$DIR/package.json' ]"
chk "no local node_modules"    "[ ! -e '$DIR/node_modules' ]"

# Running with no args must reach the usage message — which only happens after
# the playwright require has resolved (via ../qa). A resolve failure throws
# before usage and prints a module error instead.
OUT=$(node "$DIR/post.js" 2>&1)
chk "post.js loads and prints usage"  "echo \"\$OUT\" | grep -q '^Usage: post.js'"
chk "no module resolution error"      "! echo \"\$OUT\" | grep -qi 'cannot find module'"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
