#!/usr/bin/env bash
# Structural guard for the hot/cold documentation split.
#
# util-qa is a RUNNER, not an author: every QA subagent loads SKILL.md on a cold
# start just to invoke qa.sh and report, so per-run wall-clock pays for every
# byte of it. Two whole jobs are NOT the runner's per-run concern and belong off
# that hot path, in REFERENCE.md:
#   - AUTHORING a scenario (the harness, the verb vocabulary + its matching
#     semantics, checkpoints, the evidence engine) — that is the CALLER's job
#     (review-dry), which reaches into REFERENCE when it writes the .spec.js.
#   - ONBOARDING a repo (writing profiles/<repo>.json, the config schema) — a
#     ONCE-per-repo task, reached only when QA_CONFIG_MISSING sends you there.
#
# This test pins that split so a future edit can't silently (a) drag the
# authoring spec or the onboarding bulk back onto the runner's hot path, (b)
# leave a dangling pointer, or (c) strip the runner's own hot-path essentials
# (the qa.sh invocation, the runner-not-author identity, the QA_CONFIG_MISSING
# route) OFF the file the runner actually loads. It greps files — no browser, no
# boot — so it is cheap to keep green.
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

# --- authoring spec moved OFF the runner's hot path ------------------------
# The runner never writes scenarios, so the verb vocabulary and its exact
# matching semantics live in REFERENCE (where the author, review-dry, reads
# them), NOT in the file the runner loads every run.
has  "$REF"   'Authoring a scenario'  && ok "authoring spec lives in REFERENCE" \
  || no "authoring spec lives in REFERENCE"
has  "$REF"   'visit <path>'          && ok "verb vocabulary lives in REFERENCE" \
  || no "verb vocabulary lives in REFERENCE"
has  "$REF"   'Exact verb semantics'  && ok "verb semantics live in REFERENCE" \
  || no "verb semantics live in REFERENCE"
lacks "$SKILL" 'Exact verb semantics' && ok "verb semantics are NOT on the hot path" \
  || no "verb semantics are NOT on the hot path"
lacks "$SKILL" 'visit <path>'         && ok "verb vocabulary is NOT on the hot path" \
  || no "verb vocabulary is NOT on the hot path"

# --- onboarding bulk moved OFF the hot path --------------------------------
has  "$REF"   'Creating a per-repo config' && ok "config schema lives in REFERENCE" \
  || no "config schema lives in REFERENCE"
lacks "$SKILL" 'Creating a per-repo config' && ok "config schema is NOT on the hot path" \
  || no "config schema is NOT on the hot path"

# --- the RUNNER's own hot-path essentials STAY in SKILL --------------------
# What the runner does need every run: how to invoke, who it is, and the one
# mid-run route into onboarding.
has "$SKILL" 'runner, not an author' && ok "runner identity stays on the hot path" \
  || no "runner identity stays on the hot path"
has "$SKILL" 'qa\.sh'                && ok "qa.sh invocation stays on the hot path" \
  || no "qa.sh invocation stays on the hot path"
has "$SKILL" 'QA_CONFIG_MISSING'     && ok "QA_CONFIG_MISSING still surfaced on hot path" \
  || no "QA_CONFIG_MISSING still surfaced on hot path"

echo "# pass $PASS / fail $FAIL"
[ "$FAIL" -eq 0 ]
