#!/usr/bin/env bash
# Behavioral test for JS PROFILES and the login() function.
# A profile is a `profiles/<repo>.js` module exporting { serve, variables, badge,
# login }. login() is a JS function the runner calls with { page, base, vars } —
# raw Playwright plus the profile's `variables` injected as `vars`. The old
# verb-string macro DSL is gone. Pure node (no browser): exercises the loader and
# the login-invocation seam via run.js's exports.
# Needs: node.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# JS profiles + login() function"

# --- fixtures ---------------------------------------------------------------
cat > "$TMPROOT/acme.js" <<'EOF'
module.exports = {
  serve: 'echo serving on "$PORT"',
  variables: { EMAIL: 'dev@example.com', PASSWORD: 'sekret-value-1234' },
  badge: { pass: 'x.svg' },
  login: async ({ page, base, vars }) => {
    await page.goto(base + '/login');
    await page.fill('#email', vars.EMAIL);
    await page.fill('#password', vars.PASSWORD);
  },
};
EOF
printf '{"serve":"legacy","variables":{"K":"vv"}}' > "$TMPROOT/legacy.json"

# --- T1: a <repo>.js module loads (serve + variables + a login FUNCTION) -----
chk "T1 .js profile loads serve+vars+login fn" \
  "node -e 'const {loadRepoConfig}=require(process.argv[1]);const a=require(\"assert\");const c=loadRepoConfig(process.argv[2],\"h\");a(c.serve);a.equal(c.variables.EMAIL,\"dev@example.com\");a.equal(typeof c.login,\"function\")' '$RUN' '$TMPROOT/acme.js'"

# --- T2: a legacy .json profile still loads (require reads either) -----------
chk "T2 legacy .json profile still loads" \
  "node -e 'const {loadRepoConfig}=require(process.argv[1]);const a=require(\"assert\");const c=loadRepoConfig(process.argv[2],\"h\");a.equal(c.variables.K,\"vv\");a.equal(typeof c.login,\"undefined\")' '$RUN' '$TMPROOT/legacy.json'"

# --- T3: formLogin calls login() with { page, base, vars } (vars injected) ---
# A stub page whose context has no cookies makes formLogin throw LOGIN_FAILED
# AFTER it runs login() and BEFORE it writes any cookie store — so we capture the
# harness login() received without touching the real cookies.json.
cat > "$TMPROOT/t3.js" <<'EOF'
const { formLogin } = require(process.argv[2]);
const assert = require('assert');
let got = null;
const page = {
  async goto() {}, async fill() {}, async click() {},
  async waitForURL() {},
  url() { return 'http://app/dashboard'; },
  context() { return { async cookies() { return []; } }; },
};
const creds = {
  variables: { EMAIL: 'dev@example.com' },
  login: async (h) => { got = h; await h.page.fill('#email', h.vars.EMAIL); },
};
formLogin(page, 'http://app', 'app', creds).then(
  () => { throw new Error('expected LOGIN_FAILED (no cookies)'); },
  (e) => {
    assert(/LOGIN_FAILED/.test(e.message), 'expected LOGIN_FAILED, got: ' + e.message);
    assert(got, 'login() was never called');
    assert.strictEqual(got.page, page, 'login() did not receive the page');
    assert.strictEqual(got.base, 'http://app', 'login() did not receive base');
    assert.strictEqual(got.vars.EMAIL, 'dev@example.com', 'login() did not receive injected vars');
    console.log('ok');
  },
);
EOF
chk "T3 formLogin invokes login({page,base,vars})" "node '$TMPROOT/t3.js' '$RUN'"

# --- T4: a profile with no login() gives a clear AUTH error -------------------
cat > "$TMPROOT/t4.js" <<'EOF'
const { formLogin } = require(process.argv[2]);
const assert = require('assert');
const page = { context() { return { async cookies() { return []; } }; }, url() { return ''; }, async waitForURL() {} };
formLogin(page, 'http://app', 'app', { variables: {} }).then(
  () => { throw new Error('expected a thrown error for a profile with no login()'); },
  (e) => { assert(/AUTH_FAILED and no login\(\) function/.test(e.message), 'wrong error: ' + e.message); console.log('ok'); },
);
EOF
chk "T4 no-login profile fails with a clear error" "node '$TMPROOT/t4.js' '$RUN'"

echo
echo "# profile-login: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
