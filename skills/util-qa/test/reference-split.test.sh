#!/usr/bin/env bash
# Structural guard for the hot/cold documentation split.
#
# util-qa/SKILL.md is loaded IN FULL by every QA subagent on a cold start, so
# per-run wall-clock pays for every byte of it. Onboarding a repo (writing a
# profiles/<repo>.json, the config schema, the profile-markdown template) is a
# ONCE-per-repo task, not a per-run one — it belongs off the hot path in
# REFERENCE.md, reached only when QA_CONFIG_MISSING sends you there.
#
# This test pins that split so a future edit can't silently (a) drag the
# onboarding bulk back onto the hot path, (b) leave a dangling pointer, or
# (c) move a RUNTIME-critical contract (the verb list, checkpoint syntax) OFF
# the hot path where the runner author would stop seeing it. It greps files —
# no browser, no boot — so it is cheap to keep green.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$DIR/SKILL.md"
REF="$DIR/REFERENCE.md"
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
# has <file> <regex> — file contains a line matching regex
has()   { grep -Eq "$2" "$1"; }
# lacks <file> <regex> — file has NO line matching regex
lacks() { ! grep -Eq "$2" "$1"; }

echo "# util-qa hot/cold documentation split"

# --- the cold reference file exists and the hot file points at it ----------
[ -f "$REF" ] && ok "REFERENCE.md exists" || no "REFERENCE.md exists"
has "$SKILL" 'REFERENCE\.md' && ok "SKILL.md points to REFERENCE.md" \
  || no "SKILL.md points to REFERENCE.md"

# --- onboarding bulk moved OFF the hot path --------------------------------
# The per-repo config schema (the "serve" key example + the machine-config
# heading) is onboarding, not per-run: it must live in REFERENCE, not SKILL.
has  "$REF"   'Creating a per-repo config' && ok "config schema lives in REFERENCE" \
  || no "config schema lives in REFERENCE"
lacks "$SKILL" 'Creating a per-repo config' && ok "config schema is NOT on the hot path" \
  || no "config schema is NOT on the hot path"
lacks "$SKILL" '^## Booting any repo' && ok "onboarding section is NOT on the hot path" \
  || no "onboarding section is NOT on the hot path"

# --- runtime-critical contract STAYS on the hot path -----------------------
# The subagent writes scenarios every run; the verb vocabulary and checkpoint
# ( :: ) syntax must stay where it will read them, NOT get swept into REFERENCE.
has "$SKILL" 'visit <path>' && ok "verb vocabulary stays on the hot path" \
  || no "verb vocabulary stays on the hot path"
has "$SKILL" 'Exact verb semantics' && ok "verb semantics stay on the hot path" \
  || no "verb semantics stay on the hot path"
has "$SKILL" 'Checkpoints' && ok "checkpoint syntax stays on the hot path" \
  || no "checkpoint syntax stays on the hot path"

# --- QA_CONFIG_MISSING still routes the reader to the reference ------------
# The one moment onboarding matters mid-run is a missing config; the failure
# path must name where the instructions now live.
has "$SKILL" 'QA_CONFIG_MISSING' && ok "QA_CONFIG_MISSING still surfaced on hot path" \
  || no "QA_CONFIG_MISSING still surfaced on hot path"

echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
