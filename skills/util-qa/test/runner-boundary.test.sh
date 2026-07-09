#!/usr/bin/env bash
# Structural guard for util-qa's RUNNER contract.
#
# util-qa is a dumb runner: it executes exactly the scenario it is handed and
# never invents, repairs, wait-pads, re-seeds, extends steps, or reviews frames
# for bugs. All of that judgement — thinking like a customer, hunting
# regressions, authoring the complete script, and reviewing the frames into
# findings.json — belongs to the caller (review-dry), NOT here.
#
# This pins that so a future edit can't drift the creativity back into the
# runner (the "QA getting creative about what to run" failure this boundary
# exists to prevent). It greps util-qa's OWN SKILL.md only — it never reaches
# into another skill's directory (that would itself break encapsulation).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
QA="$DIR/SKILL.md"
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else no "$3 [missing: $2]"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then no "$3 [present: $2]"; else ok "$3"; fi; }

echo "# util-qa runner contract"

# --- util-qa states the runner contract ------------------------------------
has  "$QA" "You are a runner, not an author." "util-qa declares itself a runner"
has  "$QA" "Run only what you were handed. Change nothing." "util-qa pins run-verbatim"

# --- the AUTHORING creativity must NOT live in the runner -------------------
lacks "$QA" "Think like the customer"                  "util-qa does not tell the runner to think like a customer"
lacks "$QA" "Write assertions that would fail if the change regressed" "util-qa does not tell the runner to design regressions"
lacks "$QA" "Write every defect you spot into"         "util-qa does not tell the runner to author findings.json"
lacks "$QA" "// TODO(QA)"                               "util-qa carries no TODO-handoff (scenarios arrive complete)"

echo
echo "# runner-boundary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
