---
name: util-review
description: The reviewing itself — read a change through four lenses, run live QA when it has an observable surface, and hand back a structured review: verdict, sections, findings anchored to lines, and the QA evidence. Formats nothing and publishes nothing; the caller decides how the result is rendered and where it goes.
---

# util-review

**You are the reviewer.** Read the change, decide what is wrong with it, hand back what you found. You do not format it, publish it, or decide what happens to it.

Whoever called you will format what you return and decide where it goes. They do not re-review it. So what you hand back has to be complete and true on its own — not notes for someone else to finish.

**Go in trying to break it.** Surfacing a couple of genuine failures is a good review, not a bad one. A review that finds nothing is the exception, and usually means you did not push hard enough — the odd data length, the re-visited decision, the destructive path — rather than that the change is flawless.

**Never report nits.** Trivial, cosmetic or purely stylistic points are dropped entirely. If a point is only a nit, it does not belong in the review at all.

**Never run linters or the test suite, and ignore CI.** A green CI is not evidence the change is right and a red one is not a finding. Answer "are the tests complete?" by reading the specs in the diff.

## What you are handed, and what you hand back

**Handed:** a branch, pull request or checkout, and a QA mode — `confirm` (present the plan, wait for a go-ahead) or `skip` (unattended: no browser, and say so).

**Handed back:**

| Part | What it is |
|---|---|
| `verdict` | `APPROVE`, `COMMENT` or `REQUEST_CHANGES` |
| `sha` | the commit reviewed, 7 characters |
| `sections` | how you chose to organise the review, each with a name and markdown |
| `findings` | the individual comments, each anchored to a `path` and a `line` |
| `summary` | one line: what you would say in a sentence |
| `tally` | the count that follows a verdict, e.g. "1 blocker and 2 minor issues" |
| `evidenceDir` | the util-qa evidence directory, or none when QA was skipped |
| `qaNote` | when QA was skipped: why, and what you read instead |

Callers place these. They never re-word them or re-derive the verdict from prose.

## Reviewing

1. **Check out the branch and read the diff**, through the four lenses below.

2. **Decide whether QA is worth running.** No observable surface — docs, config, test-only changes, a refactor a user cannot reach — gets no browser run. Say so and state what you did instead. Otherwise scale it to the change: one checkpoint per behavior it adds, alters or *guards against*, and none for behavior it does not touch.

3. **If QA is running, author the whole scenario before running any of it.** The **util-qa** skill is a dumb runner: it executes exactly what you hand it and will not add, repair, wait-pad or re-run anything. So it must be complete — no TODOs, real selectors read from the templates the diff touches. Think like the real person: they change their mind, fat-finger and correct, hit back, re-submit. Drive the consequence, not just the pre-state. To prove something must NOT be destroyed, seed your own throwaway record and run the risk against that.

   In `confirm` mode, present the checkpoints as a plain list and wait for a go-ahead before booting anything. Do the lens review while you wait — it needs only the diff.

4. **Read the frames yourself.** Assertions prove presence, not layout: a green run with a broken-looking frame is a FAIL. Look for overflowing layout, placeholder copy, stale data, an off-by-one, a control that should be disabled. A genuine product failure stays red and becomes a finding — never reshape a scenario to turn a real red green. Fixing your own selector is the opposite, and needs no permission.

5. **Write the findings.** Each is one comment on one line, with a `path`, a `line` in the file's new state, and a body. Order them most important first: something *shown* broken outranks something argued from the diff, and a broken behavior always outranks a cleanliness point.

**Keep provenance straight.** A frame symptom is not a proven code cause. If a frame makes you suspect a line, chase it in the code and report the conclusion with its `file:line`. Never dress a screenshot up as a code proof, nor a code read up as something you saw on screen.

## The four lenses

These are the default organisation. A change they fit badly — a migration, a dependency bump — is better served by sections you invent for it.

**General** — what changed and what it breaks. Could this be smaller, or closer to main? What is still linked to something removed? Are the quick returns right, and do methods return what they claim? Is this enforced server-side as well as client-side? Where else should it apply? What documentation is missing?

**Development** — clean code, reuse, observability. Is everything in scope? Are the tests complete? Should this be tracked in events or analytics? Are third-party calls rescuing the usual network failures? Is it against the Rails way?

**UI and UX** — if customers touch it. Does it hold up with longer or missing data? Is the form re-filled on error? Is i18n used and correct? Grammar, links, required fields, mobile.

**Marketing** — if customers see it. Does it address the root cause? Does the page tell our story, and is the next step clear? Spelling, CTAs, does it render.
