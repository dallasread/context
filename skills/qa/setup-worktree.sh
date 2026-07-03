#!/usr/bin/env sh
# Provision a git worktree with the gitignored files it needs to boot and run
# tests, sourced from the main checkout. Repo-agnostic: the file list is the
# main checkout's own gitignored files (git ls-files -o -i), minus universal
# junk — dependency installs, logs, caches, temp dirs — which every stack
# rebuilds locally instead.
#
# Usage: setup-worktree.sh [--symlink] [--main <path>] [<worktree-path>]
#
# The main checkout is derived from the worktree's own git metadata
# (--git-common-dir); pass --main only to override it.
#
#   --symlink   Symlink instead of copying (edits then propagate both ways).
#               DANGER: symlinked build outputs let a worktree rebuild clobber
#               the main checkout's files through the link — prefer copy.
#
# node_modules is NEVER carried over: symlinks break vite (/@fs 403 outside
# server.fs.allow) and copies are hundreds of MB — install it in the worktree
# (e.g. `yarn install --frozen-lockfile`). Copied build outputs are
# point-in-time: rebuild in the worktree when the branch changed them.
set -eu

MODE=copy
MAIN=""
WT=$(pwd)

while [ $# -gt 0 ]; do
  case "$1" in
    --symlink) MODE=symlink ;;
    --main) shift; MAIN=$1 ;;
    *) WT=$1 ;;
  esac
  shift
done

if [ -z "$MAIN" ]; then
  common=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
  MAIN=$(dirname "$common")
fi

[ "$MAIN" = "$WT" ] && { echo "already the main checkout, nothing to provision: $WT"; exit 0; }
echo "main: $MAIN"

# Ignored entries (--directory collapses ignored dirs to one entry), minus
# universal junk no worktree should inherit: dependency installs, editor and
# tool state, OS droppings, logs, caches, temp/session dirs — at any depth.
SKIP='(^|/)(node_modules|vendor|log|tmp|coverage|storage|\.DS_Store|\.cache|\.idea|\.vscode|\.claude|\.ruby-lsp|\.bundle)(/|$)|\.log$'

git -C "$MAIN" ls-files --others --ignored --exclude-standard --directory \
  | grep -Ev "$SKIP" \
  | while IFS= read -r f; do
      rel=${f%/}
      src="$MAIN/$rel"
      dst="$WT/$rel"
      [ -e "$src" ] || continue
      [ -e "$dst" ] && { echo "keep  $rel"; continue; }
      mkdir -p "$(dirname "$dst")"
      if [ "$MODE" = symlink ]; then
        ln -s "$src" "$dst" && echo "link  $rel"
      else
        cp -R "$src" "$dst" && echo "copy  $rel"
      fi
    done

mkdir -p "$WT/log"
[ -f "$MAIN/log/development.log" ] && touch "$WT/log/development.log" && echo "touch log/development.log"

[ -e "$MAIN/node_modules" ] && [ ! -d "$WT/node_modules" ] && echo "NOTE: node_modules missing — install it in the worktree (never symlink)"
echo "done: $WT"
