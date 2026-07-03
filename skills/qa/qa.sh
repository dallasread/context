#!/usr/bin/env sh
# Boot the app on a free port, run a QA scenario against it, and ALWAYS stop
# the server afterwards — on pass, fail, error, or interrupt (trap EXIT).
#
# Usage: qa.sh <scenario.md> <out-dir> [-- <server command>]
#
# Runs from the app directory under test. The boot is the "serve" key of the
# repo's REQUIRED QA config, profiles/<repo>.json next to this script — one
# flat shell command run with the chosen port exported as $PORT, e.g.:
#
#   "serve": "npm run build && exec my-server --port \"$PORT\""
#
# `exec` the final server command so it owns the process (the trap also kills
# direct children as a safety net). <repo> is the origin remote's repository
# name. There is NO stack detection — a repo without a config fails with
# QA_CONFIG_MISSING. A command after -- explicitly overrides serve for
# one-off runs.
set -eu

SCENARIO=$1
OUT=$2
shift 2
[ $# -gt 0 ] && [ "$1" = "--" ] && shift

SKILL_DIR=$(cd "$(dirname "$0")" && pwd)

# Repo name = origin remote's repository name (canonical, stable across
# worktrees and local directory names), falling back to the main checkout's
# directory name.
REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]##')
[ -n "$REPO" ] || REPO=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo /unknown/.git)")")

CONFIG="$SKILL_DIR/profiles/$REPO.json"
SERVER=""
[ -f "$CONFIG" ] && SERVER=$(node -e "console.log(require('$CONFIG').serve || '')")
if [ $# -gt 0 ]; then
  SERVER=$*
elif [ -z "$SERVER" ]; then
  echo "QA_CONFIG_MISSING for repo '$REPO' — create $CONFIG with a \"serve\" command (flat shell, \$PORT exported) and login config (see SKILL.md), or pass a server command after --"
  exit 2
fi

PORT=$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')
BASE="http://localhost:$PORT"
mkdir -p "$OUT"

echo "boot: $SERVER"
PORT=$PORT sh -c "$SERVER" > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
# Kill the boot process and any direct children (a boot file that forgot to
# `exec` its server leaves the server as a child of the sh).
trap 'pkill -P "$SERVER_PID" 2>/dev/null; kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
echo "server: pid=$SERVER_PID $BASE (log: $OUT/server.log)"

ready=""
i=0
while [ $i -lt 90 ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "SERVER_DIED — last log lines:"; tail -5 "$OUT/server.log"; exit 2; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null || true)
  [ "$code" != "000" ] && { ready=1; break; }
  sleep 2
  i=$((i + 1))
done
[ -n "$ready" ] || { echo "SERVER_NOT_READY after 180s — last log lines:"; tail -5 "$OUT/server.log"; exit 2; }

node "$SKILL_DIR/run.js" "$SCENARIO" --out "$OUT" --base "$BASE" --repo "$REPO"
