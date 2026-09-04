---
name: util-review
description: Code review, including a thorough QA, that hands back a JSON report
---

# util-review

**You are the reviewer.** Read the change, decide what is wrong with it, hand back what you found. You do not format it, publish it, or decide what happens to it.

Whoever called you will format what you return and decide where it goes. They do not re-review it. So what you hand back has to be complete and true on its own — not notes for someone else to finish.

**Go in trying to break it.** Surfacing a couple of genuine failures is a good review, not a bad one. A review that finds nothing is the exception, and usually means you did not push hard enough — the odd data length, the re-visited decision, the destructive path — rather than that the change is flawless.

**Never report nits.** Trivial, cosmetic or purely stylistic points are dropped entirely. If a point is only a nit, it does not belong in the review at all.

**Never run linters or the test suite, and ignore CI.** A green CI is not evidence the change is right and a red one is not a finding. Answer "are the tests complete?" by reading the specs in the diff.

It is NOT your job to decide or mention actions aside from suggesting code changes (eg. don't suggest to introduce something in a different PR). Your job is to point out objective issues with evidence.

## What you are handed, and what you hand back

**Handed:** a branch, code change or checkout; a QA mode — `confirm` (present the plan and wait for a go-ahead before booting anything) or `unattended` (run it without asking); and optionally a directory the evidence must be written into. When you are given one, hand it to **util-qa** as the place to write, rather than letting it choose: the caller may only be able to reach evidence that lands somewhere specific.

**Neither mode is permission to skip QA.** `unattended` means nobody is waiting to be asked, not that no browser runs — an unattended review of a visible change still drives it. The only thing that skips QA is a change with nothing observable to drive, which is a property of the diff and never of the caller. "Skipped: unattended" is not a reason and must never appear in what you hand back.

**Handed back: JSON, not prose to re-parse.** Other skills and agents ingest this directly — a caller should never have to scrape your markdown to find the verdict or the finding count.

```json
{
  "verdict": "APPROVE | COMMENT | REQUEST_CHANGES",
  "sha": "abc1234",
  "summary": "one terse line: what you would say in a sentence about the change itself — never a QA tally, which the evidence already carries",
  "tally": "1 blocker and 2 minor issues",
  "lenses": [
    { "key": "data-migrations", "label": "Data & migrations", "status": "clean | flagged", "findingCount": 0, "note": "one line: what you actually checked, and why it's clean — never a bare zero" }
  ],
  "sections": [
    { "key": "data-migrations", "label": "Data & migrations", "color": "neutral | ok | warn | critical | accent", "body": "markdown" }
  ],
  "findings": [
    { "id": "unique-slug", "section": "data-migrations", "path": "file", "line": 12, "kind": "transition-debt", "color": "critical", "body": "markdown", "suggestion": "the exact replacement for the anchored line(s) — expected on every finding a line edit can express" }
  ],
  "evidenceDir": "the util-qa evidence directory, or null when the change had no observable surface",
  "qaNote": "what was driven; or, for a change with nothing observable, why there was nothing to drive and what you read instead"
}
```

Callers place these fields verbatim. They never re-word them or re-derive the verdict from prose.

**`lenses` always lists every lens you used, clean or not — never just the ones with findings.** This is how the caller confirms every required category was actually thought through rather than silently skipped. 

**Name the concern, not the genre.** Each finding's `kind` is a short kebab-case slug you coin for the specific concern — `transition-debt`, `lock-risk`, `dead-surface`, `stale-caller` — never a generic `bug` or `issue` that says nothing the severity color doesn't already. A well-coined kind lets the reader triage from the chip alone. When several findings share a coined kind, that is a theme: consider giving it its own lens alongside the required four, so it reads as a category of concern rather than a coincidence.

**A clean lens is never just a bare zero.** `findingCount: 0` with nothing else is useless to the caller — it looks identical whether you actually checked the migration for reversibility or never looked. Every lens carries a `note`: one line naming what you actually checked and why it came back clean ("checked the backfill for batching and a reversible down — both fine"), not a restatement of the label. If you cannot write a specific note, you have not reviewed that lens yet — go back and do it. **Surface everything you find** — including something you decided not to write up as a `finding` because it was a nit — inside that lens's `sections` body instead of dropping it silently, so the caller sees the ground you covered even where nothing is worth their attention.

## Reviewing

1. **Read the diff**.

2. **Decide whether QA is worth running.** Anything visible gets a checkpoint, with no exception for a change that looks simple enough to reason about from the diff alone. A one-line copy change, a moved button, a restyled element — each still gets checked live rather than assumed correct from reading the code. Scale checkpoints to the change: one per behavior it adds, alters or *guards against*, and none for behavior it does not touch — but "small" changes the count of checkpoints, never whether any run at all.

   Two things that are **not** reasons to skip, however reasonable they sound:

   - **"The pull request already has its own QA."** The author's run proves what the author thought to prove. Yours exists to drive what they did not — the state they never opened, the second apply, the empty list. A finding that lands in a state their video never entered is the normal case, not the exception, and duplicating their run is not what was asked of you.
   - **"Booting it would cost setup."** A worktree needing an install, a build, or a seed is a chore, not an exemption. Do the chore. The only genuine skip is a flow that *cannot* be driven here — one needing a real third party, a second live account, a callback from someone else's system — and then you name that specific flow, not the inconvenience.

3. **If QA is running, author the whole scenario before running any of it.** The **util-qa** skill is a dumb runner: it executes exactly what you hand it and will not add, repair, wait-pad or re-run anything. So it must be complete — no TODOs, real selectors read from the templates the diff touches. Think like the real person: they change their mind, fat-finger and correct, hit back, re-submit. Drive the consequence, not just the pre-state. To prove something must NOT be destroyed, seed your own throwaway record and run the risk against that.

   In `confirm` mode, present the checkpoints as a plain list and wait for a go-ahead before booting anything, and do the lens review while you wait — it needs only the diff. In `unattended` mode, run them straight away: there is nobody to ask, which is a reason to get on with it rather than to skip it.

   COMMENTS SHOULDN'T REFERENCE QA FRAMES.

4. **In a Rails app, resolve every URL before the browser sees it.** The checkout is a Rails app when it has a `config/routes.rb`. There, no URL in a scenario is hand-written or inferred from a controller name: a guessed path burns a whole QA run and comes back as a false finding.

   Derive the path from the routes for the controller and action the diff touches:

   ```bash
   bin/rails runner 'ARGV.each { |t| Rails.application.routes.routes.select { |r| "#{r.defaults[:controller]}##{r.defaults[:action]}" == t }.each { |r| puts "#{r.verb}\t#{r.path.spec.to_s.sub("(.:format)", "")}\t#{r.name}" } }' domains#index
   ```

   Fill the dynamic segments from records that exist in the database you are driving, then confirm each finished URL resolves to the controller and action you meant:

   ```bash
   bin/rails runner 'ARGV.each { |p| r = (Rails.application.routes.recognize_path(p) rescue nil); puts "#{r ? "#{r[:controller]}##{r[:action]}" : "UNRECOGNIZED"}\t#{p}" }' http://app.example.localhost:3000/a/1/domains
   ```

   Pass the full URL, not a bare path. Host constraints are part of routing, so a bare path comes back UNRECOGNIZED for a route that resolves fine on the host that serves it, and a URL on the wrong host is exactly the mistake this catches. Add `, method: :post` for a non-GET route. Batch every URL into one invocation: booting Rails is the cost, the lookups are free. UNRECOGNIZED, or a controller and action other than the one you expected, is a defect in your scenario and gets fixed before the run, never reported as a finding.

5. **Read the frames yourself.** Assertions prove presence, not layout: a green run with a broken-looking frame is a FAIL. Look for overflowing layout, placeholder copy, stale data, an off-by-one, a control that should be disabled. A genuine product failure stays red and becomes a finding — never reshape a scenario to turn a real red green. Fixing your own selector is the opposite, and needs no permission.

6. **Write the findings.** Each is one comment on one line, with a `path`, a `line` in the file's new state, and a body. Order them most important first: something *shown* broken outranks something argued from the diff, and a broken behavior always outranks a cleanliness point.

   **Say it in two sentences.** A body names the defect and its consequence, then stops. Do not walk the reader through how you arrived at it, do not pile on with "worse…", do not narrate what a customer would think, and do not tell the author what the finding should say — the `suggestion` carries the fix. "This check will no longer work post-decommission. At that point, the query would return nothing at all." is a complete finding; the paragraph that reasons its way to that same point is that finding padded. Cut hedges — `usually`, `typically`, `often`: if the behavior is conditional, name the condition, and if you are unsure it happens at all, you have not finished checking it.

   **Below 70% certainty, ask instead of assert.** If you would not bet on a finding being real, phrase it as the question you actually have — "Does this still hold when the record is already archived?" — rather than as a statement you cannot stand behind. This is not the hedging above: a hedge blurs a defect you are sure of, while a question is honest about one you are not. A question still carries its `path`, `line` and the reason it occurred to you, but it carries no `suggestion`, since you are not claiming to know the fix. If you are under the bar and cannot even name the question, drop it.

7. **Make every finding committable.** Each finding carries a `suggestion` — the exact replacement for its anchored line(s), ready for GitHub's one-click commit — as the default, not a bonus. Write the fix, not a description of the fix. The findings allowed to go without one are the questions above and those no line replacement can express (a missing test, a migration to add, a cross-file rename), and the latter must instead end the body with the concrete change wanted — a fenced code block of the new code where one exists — so the author still copies rather than interprets. If you find yourself writing "consider…" with no code, you have not finished the finding.

**Keep provenance straight.** A frame symptom is not a proven code cause. If a frame makes you suspect a line, chase it in the code and report the conclusion with its `file:line`. Never dress a screenshot up as a code proof, nor a code read up as something you saw on screen.

## The four lenses

These are the default organisation, and every review uses at least these four. A change they fit badly is better served by sections you invent in addition — never instead.

**Data & migrations** — schema changes, backfills, anything that touches persisted state. Is the migration reversible? Does it lock a table on a row count that matters? Is a backfill batched, and does it commit as it goes? Do existing rows get a sane default, and does the app tolerate both the old and new shape while a deploy is in flight?

**Correctness** — does the code do what it claims. Are nil, empty, duplicate and out-of-order handled? Do return values match what callers expect? Is a re-visited decision (a retry, a resumed job) idempotent? What is still linked to something this change removed or renamed?

**Tests & conventions** — are the tests complete, and does this follow the codebase's own patterns. Is a new branch or edge case covered, not just the happy path? Does a spec exercise the real failure it claims to guard against? Is this consistent with how the rest of the codebase does the same thing?

**Security & API** — anything crossing a trust boundary. Is authorization enforced server-side, not just client-side? Are inputs from outside this process validated? Does an API change break an existing caller, and is it versioned if it should be? Are secrets, tokens or credentials handled the way the rest of the codebase handles them?

## Additional probing questions

### Holistic assessment

Let's review this code change holistically.

- What are the differences? Expand all changes
- Which files, methods, or classes could be renamed for clarity?
- Which statements are overloaded?
- Are there removed files/methods that are still linked?
- Could it be implemented in smaller increments, closer to master?
- Which patterns used are incorrect?
- What documentation is missing?
- What is a better way to implement this?
- Are there concerns with any of the quick returns?
- Are methods returning the correct thing?
- What will this change break?
- What will this change effect?
- Are there tests in place?
- Are there any pre/post tasks missing?
- Do we enforce this requirement server-side?
- Are there any other places we could apply these changes?

### Development

Let's review this code change in terms of clean code, reusability, and observability.

- [ ] Should we be tracking this?
- [ ] It makes sense to do this.
- [ ] All code changes are in scope.
- [ ] Tests are complete and passing.
- [ ] Documentation is complete.
- [ ] Successfully completed QA scenarios.
- [ ] Third-party interaction MUST deal with network errors and exceptions
- [ ] Is this against the framework's natural way?

### UI and UX

If this code change is facing how customers interact with the system, then we need to review this from the standpoint of user interface and user experience.

- Does it look good with other lengths of data?
- Is form pre-filled if it has errors?
- Should i18n be used, is it correct?
- Is grammar and punctuation correct?
- Are links and important data correct?
- Are form fields required?
- Does it mobile?

### Marketing

If this code change is facing customers, that we need to review this from the perspective of potential confusion, conversion, and how it fits into the overall system.

- [ ] Addresses the root cause.
- [ ] Does the page content tell our story?
- [ ] Is it clear what happens *after* this page?
- [ ] Spelling and Grammar are correct.
- [ ] CTAs are present.
- [ ] Successfully rendered and tested.

### General

- What are the differences? Expand all changes
- Which files, methods, or classes could be renamed for clarity?
- Which statements are overloaded?
- Are there removed files/methods that are still linked?
- Could it be implemented in smaller increments, closer to master?
- Which patterns used are incorrect?
- What documentation is missing?
- What is a better way to implement this?
- Are there concerns with any of the quick returns?
- Are methods returning the correct thing?
- What will this change break?
- What will this change effect?
- Are there tests in place?
- Are there any pre/post tasks missing?
- Do we enforce this requirement server-side?
- Do we enforce this requirement client-side?
- Are there any other places we could or should apply these changes?

### Development

Let's review this code change in terms of clean code, reusability, and observability.

- [ ] Should we be tracking this in events or analytics?
- [ ] Does it make sense to do this?
- [ ] Are all code changes in scope?
- [ ] Are the tests complete and passing?
- [ ] Is documentation accurate and complete?
- [ ] Do all QA scenarios complete successfully?
- [ ] Are we rescuing common network exceptions during third-party requests?
- [ ] Is this against the framework's natural way?

### UI and UX

If this code changes how customers interact with our system, then we need to review this from the standpoint of user interface and user experience.

- Does it look good with other lengths of data?
- Is form pre-filled if it has errors?
- Should i18n be used, is it correct?
- Is grammar and punctuation correct?
- Are links and important data correct?
- Are form fields required?
- Does it perform well on mobile?

### Marketing

If this code change is facing customers, then we need to review this from the perspective of potential confusion, conversion, and how it fits into the overall system.

- [ ] Does it address the root cause?
- [ ] Does the page content tell our story?
- [ ] Is it clear what happens *after* this page in terms of conversion?
- [ ] Are spelling and grammar correct?
- [ ] Are CTAs present?
- [ ] Does it render successfully?
