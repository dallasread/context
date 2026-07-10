#!/usr/bin/env bash
# Structural guard for review-dry OWNING the scenario authoring.
#
# review-dry is the brain: it authors a COMPLETE scenario (real selectors, no
# TODO/blanks), thinks like a customer, hunts regressions, and reviews the
# frames itself into findings.json. util-qa only runs what it is handed. This
# pins that ownership so a future edit can't quietly push the thinking back onto
# the runner or reintroduce a TODO-skeleton handoff.
#
# It also guards ENCAPSULATION: review-dry must reference util-qa BY NAME and by
# contract, never by reaching into its internals (its qa.sh/run.js tools or
# their flags). Greps review-dry's OWN SKILL.md only.
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$DIR/SKILL.md"
PASS=0; FAIL=0
ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else no "$3 [missing: $2]"; fi; }
lacks() { if grep -qF -- "$2" "$1"; then no "$3 [present: $2]"; else ok "$3"; fi; }

echo "# review-dry authoring ownership + encapsulation"

# --- review-dry is adversarial: it tries to break the change ---------------
has "$SKILL" "trying to break it"                "review-dry goes in trying to break the change"
has "$SKILL" "that red is the deliverable"       "a genuine product failure is kept, not smoothed to green"

# --- QA runs only after the user confirms the plan -------------------------
has "$SKILL" "Confirm the QA plan with the user before running" "review-dry confirms the QA plan before running"
has "$SKILL" "do not run it yet"                 "authoring does not run QA immediately"

# --- QA is scaled to the diff, and a surfaceless change gets no browser run -
has "$SKILL" "proportionality is a rule, not a preference" "QA is scaled to the change"
has "$SKILL" "no observable surface"             "a surfaceless change is a sanctioned skip"

# --- review-dry owns the complete-scenario authoring + frame review --------
has "$SKILL" "author a COMPLETE"                 "review-dry authors the complete scenario"
has "$SKILL" "no TODOs, no blanks, real selectors" "review-dry forbids TODO/blanks in the handoff"
has "$SKILL" "Think like the customer"           "review-dry owns customer-journey thinking"
has "$SKILL" "Write every defect you spot into"  "review-dry owns the frame review + findings.json"

# --- encapsulation: name util-qa, don't reach into its tools/flags ---------
has   "$SKILL" "util-qa"      "review-dry references util-qa by name"
lacks "$SKILL" "qa.sh"        "review-dry does not invoke util-qa's qa.sh tool"
lacks "$SKILL" "run.js"       "review-dry does not invoke util-qa's run.js tool"
lacks "$SKILL" "--keep"       "review-dry does not spell out util-qa's --keep flag"
lacks "$SKILL" "--fresh"      "review-dry does not spell out util-qa's --fresh flag"

echo
echo "# authoring-ownership: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
