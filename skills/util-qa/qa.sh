#!/usr/bin/env sh
# Boot the app on a free port, run a QA scenario against it, and (by default)
# stop the server afterwards — on pass, fail, error, or interrupt (trap EXIT).
#
# Usage:
#   qa.sh <scenario.md> <out-dir> [--keep|--fresh] [-- <server command>]
#   qa.sh --stop
#
# Runs from the app directory under test. The boot is the "serve" key of the
# repo's REQUIRED QA config, profiles/<repo>.json next to this script — one
# flat shell command run with the chosen port exported as $PORT, e.g.:
#
#   "serve": "npm run build && exec my-server --port \"$PORT\""
#
# `exec` the final server command so it owns the process (teardown also walks
# and kills the whole descendant tree as a safety net). <repo> is the origin
# remote's repository name. There is NO stack detection — a repo without a
# config fails with QA_CONFIG_MISSING. A command after -- explicitly overrides
# serve for one-off runs.
#
# Warm servers (--keep / auto-reuse): the default is hermetic — fresh boot,
# killed on exit. `--keep` instead leaves the server running and records it in
# a per-worktree state file; a later run REUSES that warm server (skipping the
# boot+build entirely, so it runs in seconds). Reuse serves the assets the
# server booted with — Rails dev-reload still picks up backend/view edits, but
# a JS/CSS source change needs `--fresh` (stop, rebuild, reboot). State is
# keyed by the git worktree root, so parallel QA across worktrees each keeps
# its own independent server and never collides. `--stop` tears the warm
# server for this worktree down.
set -eu

SKILL_DIR=$(cd "$(dirname "$0")" && pwd)

# Playwright preflight — the runner does `require('playwright')` and launches
# chromium deep in the run, so a missing npm package or (separately) a missing
# browser binary would otherwise surface as a cryptic error mid-scenario, after
# a full server boot. These two installs live in THIS skill dir and are
# idempotent, so just self-heal them once, up front. Skipped when QA_SKIP_RUN
# is set (lifecycle tests don't touch the browser).
preflight_playwright() {
  [ -n "${QA_SKIP_RUN:-}" ] && return 0
  if [ ! -d "$SKILL_DIR/node_modules/playwright" ]; then
    echo "playwright package missing — installing (one-time) in $SKILL_DIR"
    (cd "$SKILL_DIR" && npm install) || { echo "PLAYWRIGHT_NPM_INSTALL_FAILED — run: cd $SKILL_DIR && npm install" >&2; exit 2; }
  fi
  # The browser binary is a separate download from the npm package. Resolve its
  # expected path and confirm it exists on disk; install chromium if not.
  if ! node -e "const p=require('$SKILL_DIR/node_modules/playwright').chromium.executablePath();process.exit(require('fs').existsSync(p)?0:1)" 2>/dev/null; then
    echo "chromium browser missing — installing (one-time)"
    (cd "$SKILL_DIR" && npx playwright install chromium) || { echo "PLAYWRIGHT_BROWSER_INSTALL_FAILED — run: cd $SKILL_DIR && npx playwright install chromium" >&2; exit 2; }
  fi
}
preflight_playwright

# Warm-server state, keyed by the git worktree root (stable per worktree, so
# parallel branches stay independent), falling back to the cwd.
WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE="$WORKTREE/tmp/qa/.warm-server"

# Kill a process and all of its descendants — bin/vite, puma, and node spawn
# grandchildren a bare `kill` would orphan.
kill_tree() {
  for _child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$_child"; done
  kill "$1" 2>/dev/null || true
}

# Stop this worktree's warm server (if any) and clear its state.
stop_warm() {
  if [ -f "$STATE" ]; then
    PID=""; . "$STATE"
    [ -n "$PID" ] && kill_tree "$PID"
    rm -f "$STATE"
    echo "stopped warm server (pid=$PID) for $WORKTREE"
  else
    echo "no warm server for $WORKTREE"
  fi
}

# --- argument parsing -----------------------------------------------------
KEEP=""; FRESH=""; SCENARIO=""; OUT=""; OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stop)  stop_warm; exit 0 ;;
    --keep)  KEEP=1; shift ;;
    --fresh) FRESH=1; shift ;;
    --)      shift; OVERRIDE=$*; break ;;
    *)
      if   [ -z "$SCENARIO" ]; then SCENARIO=$1
      elif [ -z "$OUT" ];      then OUT=$1
      else echo "unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

# Repo name = origin remote's repository name (canonical, stable across
# worktrees and local directory names), falling back to the main checkout's
# directory name.
REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]##')
[ -n "$REPO" ] || REPO=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo /unknown/.git)")")

CONFIG="$SKILL_DIR/profiles/$REPO.json"
SERVER=""
[ -f "$CONFIG" ] && SERVER=$(node -e "console.log(require('$CONFIG').serve || '')")
if [ -n "$OVERRIDE" ]; then
  SERVER=$OVERRIDE
elif [ -z "$SERVER" ]; then
  echo "QA_CONFIG_MISSING for repo '$REPO' — create $CONFIG with a \"serve\" command (flat shell, \$PORT exported) and login config (see SKILL.md), or pass a server command after --"
  exit 2
fi

# --- warm-server reuse / fresh --------------------------------------------
BASE=""; REUSE=""
if [ -n "$FRESH" ]; then
  [ -f "$STATE" ] && stop_warm >/dev/null 2>&1
elif [ -f "$STATE" ]; then
  PID=""; . "$STATE"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && \
     [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null || true)" != "000" ]; then
    REUSE=1
    echo "reuse: warm server pid=$PID $BASE"
  else
    echo "stale warm server (pid=$PID) — rebooting"
    [ -n "$PID" ] && kill_tree "$PID"
    rm -f "$STATE"; BASE=""
  fi
fi

[ -n "$SCENARIO" ] && [ -n "$OUT" ] || {
  echo "usage: qa.sh <scenario.md> <out-dir> [--keep|--fresh] [-- <server command>] | qa.sh --stop" >&2
  exit 2
}
mkdir -p "$OUT"

# --- boot (unless reusing a warm server) ----------------------------------
if [ -z "$REUSE" ]; then
  PORT=$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });')
  BASE="http://localhost:$PORT"

  echo "boot: $SERVER"
  PORT=$PORT sh -c "$SERVER" > "$OUT/server.log" 2>&1 &
  SERVER_PID=$!

  if [ -n "$KEEP" ]; then
    mkdir -p "$(dirname "$STATE")"
    printf 'PID=%s\nBASE=%s\n' "$SERVER_PID" "$BASE" > "$STATE"
    echo "server: pid=$SERVER_PID $BASE (kept warm; log: $OUT/server.log)"
  else
    # Hermetic: tear the whole server tree down on any exit.
    trap 'kill_tree "$SERVER_PID"' EXIT INT TERM
    echo "server: pid=$SERVER_PID $BASE (log: $OUT/server.log)"
  fi

  ready=""
  i=0
  while [ $i -lt 90 ]; do
    kill -0 "$SERVER_PID" 2>/dev/null || {
      echo "SERVER_DIED — last log lines:"; tail -5 "$OUT/server.log"
      [ -n "$KEEP" ] && rm -f "$STATE"
      exit 2
    }
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/" 2>/dev/null || true)
    [ "$code" != "000" ] && { ready=1; break; }
    sleep 2
    i=$((i + 1))
  done
  [ -n "$ready" ] || {
    echo "SERVER_NOT_READY after 180s — last log lines:"; tail -5 "$OUT/server.log"
    [ -n "$KEEP" ] && rm -f "$STATE"
    exit 2
  }
fi

# QA_SKIP_RUN short-circuits the browser run — used by the lifecycle tests to
# exercise boot/reuse/teardown without Rails or Playwright.
[ -n "${QA_SKIP_RUN:-}" ] || node "$SKILL_DIR/run.js" "$SCENARIO" --out "$OUT" --base "$BASE" --repo "$REPO"
