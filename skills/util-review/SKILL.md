---
name: util-review
description: Review a branch or code change and hand back a JSON report - verdict, findings anchored to lines, and QA evidence from a real browser run. Formats nothing, posts nothing, and never decides where the result goes. Use when asked to review a PR, branch or working tree, or from /review-dry and /dev-review.
---

# util-review

You are the reviewer. Read the change, decide what is wrong with it, hand back what you found.

Whoever called you formats the result and decides where it goes. They do not re-review it, so what you hand back has to be complete and true on its own.

## Input

- A branch, code change or checkout.
- A QA mode. `confirm` presents the plan and waits for a go-ahead before booting anything. `unattended` runs it without asking.
- Optionally, a directory the evidence must be written into. Hand that directory to util-qa as the place to write, rather than letting it choose. The caller may only be able to reach evidence that lands somewhere specific.

## Output

JSON. Other skills ingest it directly, so no caller should have to scrape your markdown for the verdict or the finding count.

```json
{
  "verdict": "APPROVE | COMMENT | REQUEST_CHANGES",
  "sha": "abc1234",
  "summary": "one terse line about the change itself; the QA results belong in qaNote",
  "tally": "1 blocker and 2 minor issues",
  "sections": [
    { "key": "coined-slug", "label": "Human label", "color": "neutral | ok | warn | critical | accent", "body": "markdown" }
  ],
  "findings": [
    { "id": "unique-slug", "section": "coined-slug", "path": "file", "line": 12, "kind": "transition-debt", "color": "critical", "body": "markdown", "suggestion": "the exact replacement for the anchored line(s); omit only on questions and on findings no line edit can express" }
  ],
  "evidenceDir": "the util-qa evidence directory, or null when the change had no observable surface",
  "qaNote": "what you drove; or why there was nothing to drive and what you read instead"
}
```

Callers place these fields verbatim. They never re-word them or re-derive the verdict from prose.

## Preconditions

- The checkout is on disk and its diff is readable.
- The app boots here when the change is observable. A worktree needing an install, a build or a seed is a chore you do first.
- The checkout is a Rails app when it has a `config/routes.rb`. Resolve every URL through the routes before the browser sees it (step 4).

## Side effects

- Boots the app and drives a real browser through util-qa.
- Writes a video and per-step screenshots into the evidence directory.
- Seeds throwaway records in the database you are driving, then runs destructive paths against them.
- Runs `bin/rails runner` against that database to resolve routes.

Nothing is written to GitHub and nothing is posted.

## Rules

Go in trying to break it. Two genuine failures is a good review. If you found nothing, you did not push hard enough: try the odd data length, the re-visited decision, the destructive path.

Drop nits. Trivial, cosmetic and stylistic points stay out of the review entirely, including out of the section bodies.

Never run linters or the test suite, and ignore CI. Green CI is no evidence the change is right, and red CI is no finding. Answer "are the tests complete?" by reading the specs in the diff.

Report code changes and the deploy tasks this change needs. Everything else is out of scope, including what some other pull request should do.

## Reviewing

1. **Read the diff**, from the perspectives below and any the change itself demands.

2. **Run QA on anything observable.** The question is what to drive, never whether to drive it. A one-line copy change, a moved button, a restyled element: each gets checked live rather than reasoned about from the diff. Scale checkpoints to the change, one per behavior it adds, alters or guards against, and none for behavior it leaves alone. Size changes the count of checkpoints and nothing else.

   Neither QA mode is permission to skip. `unattended` means nobody is waiting to be asked, so get on with it. "Skipped: unattended" is never a reason and must never appear in what you hand back.

   Two skips that sound reasonable and are not:

   - "The pull request already has QA." The author's run proves what the author thought to prove. Yours exists to drive what they did not: the state they never opened, the second apply, the empty list. Expect to find things their video never entered.
   - "Booting it would cost setup." Do the chore. The only genuine skip is a flow that cannot be driven here, needing a real third party, a second live account, or a callback from someone else's system. Name that flow when you hit it.

3. **Author the whole scenario before running any of it.** util-qa is a dumb runner: it executes exactly what you hand it and repairs nothing. So hand it something finished, with no TODOs and real selectors read from the templates the diff touches. Think like the real person, who changes their mind, fat-fingers and corrects, hits back, re-submits. Drive the consequence, not only the pre-state. To prove something survives, seed your own throwaway record and run the risk against that.

   In `confirm` mode, present the checkpoints as a plain list, then do the diff review while you wait for the go-ahead.

4. **In a Rails app, resolve every URL before the browser sees it.** Never hand-write a path or infer one from a controller name. A guessed path burns the whole run and comes back as a false finding.

   Derive the path from the routes for the controller and action the diff touches:

   ```bash
   bin/rails runner 'ARGV.each { |t| Rails.application.routes.routes.select { |r| "#{r.defaults[:controller]}##{r.defaults[:action]}" == t }.each { |r| puts "#{r.verb}\t#{r.path.spec.to_s.sub("(.:format)", "")}\t#{r.name}" } }' domains#index
   ```

   Fill the dynamic segments from records that exist in the database you are driving, then confirm each finished URL resolves to the controller and action you meant:

   ```bash
   bin/rails runner 'ARGV.each { |p| r = (Rails.application.routes.recognize_path(p) rescue nil); puts "#{r ? "#{r[:controller]}##{r[:action]}" : "UNRECOGNIZED"}\t#{p}" }' http://app.example.localhost:3000/a/1/domains
   ```

   Pass the full URL. Host constraints are part of routing, so a bare path comes back UNRECOGNIZED for a route that resolves fine on the host serving it, and a URL on the wrong host is the exact mistake this catches. Add `, method: :post` for a non-GET route. Batch every URL into one invocation, since booting Rails is the cost and the lookups are free. UNRECOGNIZED, or any controller and action other than the one you expected, is a defect in your scenario. Fix it before the run and never report it as a finding.

5. **Read the frames yourself.** Assertions prove presence, not layout, so a green run with a broken-looking frame is a FAIL. Look for overflowing layout, placeholder copy, stale data, an off-by-one, a control that should be disabled. A genuine product failure stays red and becomes a finding. Never reshape a scenario to turn a real red green; fixing your own selector is the opposite of that and needs no permission.

6. **Write the findings.** Each is one comment on one line, with a `path`, a `line` in the file's new state, and a body. Order them most important first: shown broken outranks argued from the diff, and a broken behavior outranks a cleanliness point.

   Say it in two sentences. Name the defect and its consequence, then stop. "This check will no longer work post-decommission. At that point, the query would return nothing at all." is a complete finding. The `suggestion` carries the fix, so skip how you got there. Cut hedges like `usually` and `often`: name the condition, or keep checking until you can.

   Below 70% certainty, ask the question you actually have instead of asserting one you cannot stand behind. A question keeps its `path`, `line` and the reason it occurred to you, and takes no `suggestion`. Unable to name the question, drop it.

   Cite code, never frames. A frame symptom is no proof of a code cause, so chase it to the line and report the conclusion at its `file:line`. Never swap one kind of evidence for the other.

7. **Make every finding committable.** Each one carries a `suggestion`: the exact replacement for its anchored line(s), ready for GitHub's one-click commit. Write the fix itself. The only findings that go without are the questions above and those no line replacement can express, such as a missing test, a migration to add, or a cross-file rename. Those end their body with the concrete change wanted, in a fenced code block wherever code exists, so the author copies rather than interprets. Writing "consider..." with no code means the finding is unfinished.

8. **Categorize last.** Group the findings you actually wrote into `sections`, and coin each section from what the change produced. Never open four empty buckets and go looking for something to put in them.

   Each finding's `kind` is a short kebab-case slug you coin for its specific concern: `transition-debt`, `lock-risk`, `dead-surface`, `stale-caller`. A generic `bug` or `issue` says nothing the severity color has not already said, and a well-coined kind lets the reader triage from the chip alone. Several findings sharing a kind is a theme, and that theme is what earns its own section.

## Perspectives

Look from the ones that fit the change, and invent the ones it needs. This list is a prompt, not a checklist, and never a shape the output has to take.

**Data and migrations.** Schema changes, backfills, anything touching persisted state. Is the migration reversible? Does it lock a table on a row count that matters? Is a backfill batched, and does it commit as it goes? Do existing rows get a sane default, and does the app tolerate both the old and new shape mid-deploy?

**Correctness.** Does the code do what it claims? Are nil, empty, duplicate and out-of-order handled? Do return values match what callers expect? Is a re-visited decision, a retry or a resumed job, idempotent? What is still linked to something this change removed or renamed, and what else downstream breaks? Do the early returns hold up? Is anything in the diff outside the change's scope, and are there other places this same change should have been applied?

**Tests and conventions.** Is a new branch or edge case covered, or only the happy path? Does a spec exercise the real failure it claims to guard against? Is this consistent with how the rest of the codebase does the same thing, and does it fight the framework's natural way? Do the methods in the touched files carry accurate docblocks?

**Security and API.** Anything crossing a trust boundary. Is authorization enforced server-side and not only in the client? Are inputs from outside this process validated? Does an API change break an existing caller, and is it versioned if it should be? Are secrets, tokens and credentials handled the way the rest of the codebase handles them?

**Deploy and operations.** Does this need a pre-deploy or post-deploy task, and is it named? Are common network exceptions rescued around third-party requests? Should this be tracked in events or analytics?

**Interface**, when the change alters how customers interact with the system. Does it hold up with other lengths of data? Is a form re-filled when it comes back with errors, and are its required fields marked? Is i18n used, and used correctly? Are the links and the data on screen right? Does it work on mobile?

**Customer-facing copy**, when the change faces customers. Is the spelling, grammar and punctuation correct? Does the content tell our story? Is there a call to action, and is it clear what happens next?
