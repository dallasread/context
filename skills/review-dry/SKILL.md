---
name: review-dry
description: Dry pull request review — the deliverable is a DRAFT comment, never a post. Check out the branch, review the diff through four lenses, run the util-qa skill for video evidence, and draft the comment from the canonical template (verdict lead, tagged Top points, 👓 QA section — video by default, frame-by-frame table on request). Posting, and the uploads it needs, happen only after the user reads the draft and explicitly asks. Use when asked to review a PR or branch.
---

# review-dry

Full-template pull request review with live QA evidence. You (Claude) check out the branch, review the diff through the four lenses below, run the util-qa skill for frame-backed evidence, and **draft a comment** from the canonical template. The drafted comment is the review's endpoint: the user always reads the draft before anything is posted. Posting is a separate step that runs only when the user, having read the draft, explicitly asks for it.

**Go in trying to break it — surfacing a couple of genuine failures is a good review, not a bad one.** The job of the QA run and the four lenses is to find what's wrong, not to bless what's there. Expect to come back with a few real problems; a review that finds nothing is the exception, and usually means you didn't push hard enough (the odd data length, the re-visited decision, the destructive path) rather than that the change is flawless. So aim a couple of your checkpoints at the things most likely to be broken, not just the happy path. When QA goes red on a genuine product bug, **that red is the deliverable** — keep it, report it, and never reshape the scenario to make it pass. (Correcting your own scenario's artifacts — a wrong selector, a missing wait — is the opposite: that makes the run honest. See step 5.)

**The util-qa skill is your runner.** You hand it the scenario you author; it boots the app, drives your scenario in a real headless browser, and hands back a pass/fail verdict with a video and per-checkpoint screenshots. It is a dumb executor — it does no thinking, authoring, or bug-hunting of its own — so *what* to test and *reading* the resulting frames both stay with you. **Pick it up in step 5, only after the user has approved your QA plan** (step 3); its scenario format and options are documented in the util-qa skill itself. Skip the run entirely in two cases only: the change has **no observable surface** (step 2), or the app genuinely cannot be booted here. Either way, say so and explain what you did instead. util-qa persists the scenario you author with the evidence, so the very same QA can be replayed later with no model in the loop — a model-free re-verification (from a follow-up check or CI); nothing you author here is a throwaway.

## Workflow

1. **Check out the branch.**

2. **Read the diff and the touched source and author a COMPLETE scenario — do not run it yet.** **You own the whole scenario — the WHAT and the HOW.** util-qa is a dumb runner: it executes exactly what you hand it and will not add, fill, repair, wait-pad, or re-run anything. So the scenario must be complete and runnable — **no TODOs, no blanks, real selectors** — written in the scenario format the **util-qa** skill runs (documented there): real checkpoints proving the change, with the clicks and fills between them spelled out in full.

   **Scale the QA to the change — proportionality is a rule, not a preference.** The scenario is as small as the diff allows and as large as its risk demands: one checkpoint per behavior the change adds, alters, or *guards against*, and none for behavior it does not touch. Never pad a run to look thorough, and never shrink a risky one to save a boot. Read the diff first, then pick the tier:

   - **No observable surface** — docs, comments, tooling/CI config, test-only changes, or a backend refactor a user cannot reach — gets **no browser run at all**. This is a sanctioned skip: say so and state what you did instead (read the specs in the diff, traced the call sites).
   - **A contained surface** — one screen, one control, a copy change — gets a few checkpoints on the affected screen plus the single consequence it can produce. Do not drive unrelated journeys to bulk it out.
   - **A substantial or risky surface** — a new flow, a changed submission, a destructive path, state that persists — earns the full treatment in (b) and (c): the wandering customer, the regression checkpoints, the seeded victim, the consequence driven and asserted.

   - **(a) Selectors: source first, then iterate — the loop is yours.** You checked out the branch, so read the real ids/classes/labels/`data-testid` straight from the templates and components the diff touches, and write them into the scenario up front. Later, once the plan is approved and you run it (step 5), a missed selector or a step that needs to wait is yours to fix — read the failing frame, correct the scenario, and re-run (keep the run warm so re-runs are cheap). Fixing your own selectors is a HOW detail and needs no re-confirmation; util-qa will never fix one for you — a red run comes back red until you correct the scenario.
   - **(b) Think like the customer and hunt the regressions — this is your job, not the runner's.** Picture the real person: they change their mind (tick to remove, then reconsider), fat-finger and correct, hit back, re-submit, arrive with more or less data than the happy path assumes. Those wandering journeys are where regressions hide. For every behavior the change adds, alters, or *guards against*, author a checkpoint a regression would break, and **drive the consequence, not just the pre-state** — perform the submit/action and assert the resulting state (a correct-looking screen can still submit a stale hidden field). util-qa can only assert that something IS on screen, never that it is absent, so write each negative/regression check as the positive end-state it implies: "the member was not removed" becomes asserting you still see `member@example.com` on the page after submitting.
   - **(c) Seed your own victim for destructive checks.** To prove a "must NOT be destroyed" path, create the at-risk record earlier in the same scenario (a throwaway member/contact) and run the risk against *that* — never a pre-existing record, and never a real charge or vendor call (assert the pre-commit screen and name the residual gap). Dev data is additive-only.
   - **(d) Refactor?** If the change claims no behavior change and the risk warrants it, author a **baseline comparison**: run the same scenario against `origin/main` in its own worktree and diff the checkpoint frames pairwise, treating any unintended observable difference as a finding. Otherwise run once and report equivalence as un-proven.
   - **(e) Observable lens questions** (UI and UX, Marketing, below) are your checklist when you review the frames in step 5 — and candidates to author as checkpoints here if you want them actually exercised.

3. **Confirm the QA plan with the user before running anything.** With the scenario authored, present its checkpoints as a plain, readable list — the human captions in the order they'll run, plus the routes they visit and any data you'll seed: the *steps you're about to drive*, not the code. Then STOP and wait for the user's explicit go-ahead. Booting the app and driving a real browser is a side effect, and like everything in a dry review it waits until the user has read the plan and approved it; if they push back, adjust the checkpoints and re-present. **Do the four-lens review (step 4) while you wait — it needs only the diff, not the app**, so no time is lost. (You skip QA entirely only when the change has no observable surface, or the app genuinely cannot be booted here; say so and state what you did instead — and there is nothing to confirm.)

4. **Review the diff through the four lenses** (General, Development, UI and UX, Marketing — see below) while you wait for the QA go-ahead, and output those sections in chat. They are the user's working view of the review and are never pasted into the drafted comment. **Never run linters or the test suite during a review, and ignore CI entirely** — its passes and its failures alike play no part in this review. A green CI is not evidence the change is right, and a red CI is not a finding you report; do not run `gh pr checks` or cite CI status anywhere. Answer "are the tests complete?" by reading the specs in the diff itself — do they exist and cover the change? — never by executing anything or consulting CI.

5. **Once the user approves the plan, run QA — then review the frames yourself and record what you find** (see Findings and provenance below). Hand the scenario to the **util-qa** skill and iterate it to faithfulness: fix your own artifacts (a wrong selector, a missing wait) so the run is honest, keeping the run warm so re-runs are cheap — but a genuine product failure stays red and becomes a finding; never reshape the scenario to turn a real red green, and "the tests pass" / "the HTML looks right" is no substitute for a real run. util-qa hands you a bare evidence dir — `steps.json` (the checkpoint verdict), `qa.mp4`, and `frames/` — and no judgement. Read the frame PNGs and check the UI actually looks right: assertions prove presence, not layout, so a green run with a broken-looking frame is a FAIL — say so. Look beyond the assertions for bugs — misaligned or overflowing layout, wrong/placeholder copy, stale or duplicated data, an off-by-one count, a control that should be disabled but isn't — and re-ask the observable lens questions (e) of each frame. **Write every defect you spot into `<qa-dir>/findings.json`** (schema below); that file feeds the comment's frame uploads and the failing-frame embed. If a frame is broken because the script itself is wrong (bad selector, missing wait), fix the script and re-run — don't log a runner artifact as a product bug.

6. **Synthesize Top points**: a maximum of four terse points in ELI5, prioritized by importance — do not spam the builder. Be absolutely clear on what any potential issues are and provide examples. **Lead with what's broken.** A point that *shows* something broken — a failed checkpoint, a defect you saw in a frame, a reproduced misbehavior — is the most valuable thing a review carries, so it takes a Top-point slot ahead of any code-quality, cleanliness, or theoretical point, and it is *never* the point cut when trimming to four (drop the cleaner-code points first). Order the four so demonstrated breakage comes first. If the change is genuinely broken, the reader must see that in the four points, not buried in the chat review. Also form one refactoring suggestion that would make the change cleaner; it enters the draft only if it clears a 75/100 usefulness bar. **A threshold gates whether a factor is mentioned at all — never narrate the ones that miss it.** If the refactor suggestion (or any scored/gated factor) does not clear its bar, drop it silently: do not say a suggestion was considered, do not show its score, do not report it as discarded or below threshold. A factor that misses its threshold is invisible, not rejected-in-writing — the reader never learns it existed. **Never report nits.** Trivial, cosmetic, or purely stylistic points are dropped entirely — not in Top points, not in the four-lens chat output. Findings are `blocker`, `major`, or `minor` only; if a point is only a nit, it does not belong in the review at all. (The refactor suggestion is not a nit: it must clear the 75/100 bar to appear, and rides as the lowest-priority `minor`.)

7. **Draft the comment** from the canonical template below and show it to the user in chat (or write it to `<qa-dir>/draft.md`). A draft publishes nothing — no uploads, no `gh`, no browser. Then stop.

8. **Post only on explicit request.** If the user reads the draft and asks you to post it, run the posting flow below — and still confirm before the upload step actually publishes files.

## Findings and provenance

Every finding carries a provenance tag in the drafted comment, because the reader must know whether it rests on a screenshot or a diff line — never blur the two, even though you produce both:

- **Observed while running** — a defect you saw in a frame of the real run, each backed by that frame; empirical. Record these in `<qa-dir>/findings.json` (schema below); a failed checkpoint is an automatic blocker (already in `steps.json` — don't restate it). They become `[QA · <severity>]` points. **Always relay the local `qa.mp4` path to the user in your chat reply** — the draft comment carries no video until something is uploaded, so the recording is only reachable if you surface its path.
- **From the diff** — findings from the four lenses, backed by `file:line`, not frames. They become `[code · <severity>]` points.
- A frame symptom is not a proven code cause. If a frame makes you suspect a specific line, chase it in the code and report the conclusion as a `[code · …]` finding with its `file:line` — do not dress a screenshot up as a code proof, nor a code read up as something you saw on screen.

`findings.json` lives in the evidence dir, an array you author while reviewing the frames (step 5):

```json
[
  { "severity": "major", "summary": "Plan selector shows a stale price for one frame before updating", "frame": "07-select.png" }
]
```

- `severity` — `blocker` | `major` | `minor`. There is no `nit` level: the review never reports nits, and `format.js` rejects a `nit` finding.
- `summary` — one sentence describing the on-screen symptom, not a guess about the code.
- `frame` — the frame basename that shows it (from `frames/`); this is the evidence, so include it.

## The four lenses

### General

Review the pull request holistically.

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

Review the pull request in terms of clean code, reusability, and observability.

- [ ] Should we be tracking this in events or analytics?
- [ ] Does it make sense to do this?
- [ ] Are all code changes in scope?
- [ ] Are tests complete and passing?
- [ ] Is documentation accurate and complete?
- [ ] Do all QA scenarios complete successfully?
- [ ] Are we rescuing common network exceptions during third-party requests?
- [ ] Is this against the Rails way?

### UI and UX

If the pull request changes how customers interact with the system, review it from the standpoint of user interface and user experience.

- Does it look good with other lengths of data?
- Is form pre-filled if it has errors?
- Should i18n be used, is it correct?
- Is grammar and punctuation correct?
- Are links and important data correct?
- Are form fields required?
- Does it perform well on mobile?

### Marketing

If the pull request is facing customers, review it from the perspective of potential confusion, conversion, and how it fits into the overall system.

- [ ] Does it address the root cause?
- [ ] Does the page content tell our story?
- [ ] Is it clear what happens *after* this page in terms of conversion?
- [ ] Are spelling and grammar correct?
- [ ] Are CTAs present?
- [ ] Does it render successfully?

## The comment template

**Every drafted or posted comment uses this exact structure — no sections reordered, renamed, or silently omitted.** The visual spec is the approved mock: https://claude.ai/code/artifact/4bb8a30a-a135-449e-929c-eaaf8b63f3d8. GitHub's sanitizer strips `class`/`style`, so no color survives: provenance and severity ride in text tags, and the failing table row reads by sorting first, opening its `<details>`, and carrying ⚠️.

```markdown
**<Verdict>** — <one-line tally, e.g. "1 blocker, a server-side gap, and 2 minor issues">. <sub>verified against <a href="https://github.com/<owner>/<repo>/commit/<sha>"><sha></a></sub>

### Top points

1. **[QA · blocker]** <symptom observed on screen, naming its checkpoint; link the uploaded frame when posted>
2. **[code · major]** <finding backed by `file:line`>
3. **[QA · minor]** <...>
4. **[code · minor]** <the refactor suggestion, if it clears the 75/100 bar — always the lowest-priority point>

### 👓 QA

<format.js output verbatim — video style by default; --frames when a frame-by-frame review was requested>
```

Rules:

- **The lead** is one line: a verdict ("Requesting changes" / "Looks good" / "Comment"), the tally, and `verified against <sha>` linking the commit (`git rev-parse --short=7 HEAD`). Use the 7-character abbreviation — that is the short form GitHub renders commit SHAs as, so the displayed text matches GitHub's own; the href may carry the same 7-char sha (GitHub resolves it). Always include the sha — a pasted comment freezes while the PR moves on, so a reader must know which tree the evidence covers.
- **Top points** is the single merged, prioritized list — max four, ELI5. Every point carries a provenance tag: `[QA · <severity>]` for frame-backed observations (from `findings.json` and failed checkpoints), `[code · <severity>]` for diff findings (with `file:line`). Severities: blocker | major | minor — never nit (nits are not reported anywhere). Every `findings.json` entry and every failed checkpoint must surface here; if more than four points survive triage, the four most severe go in, the tally says so, and the rest stay in the chat review — **but demonstrated breakage is never what gets cut.** Order and slot by this rule: a failed checkpoint or an on-screen defect (a *shown* break) outranks a same-severity finding argued only from the diff, and a broken behavior always keeps its slot over a cleanliness or theoretical point — trim those first. The lead names the breakage first. The refactor suggestion, when it clears the bar, takes the lowest-priority `[code · minor]` slot.
- **👓 QA** is `format.js` output, untouched, in one of two styles. **Video (the default):** count line, a terse ✅/⚠️ checkpoint checklist, the failing checkpoint's frame embedded only when there is one, the video inline, then **below it the QA script in a collapsible `<details>`** — always present whenever there is a video, never omitted (the draft and the post both pass `--scenario`, so the reader can expand exactly what was driven). **Frame-by-frame (`--frames`):** the checkpoint table (failing rows first, `<details open>`, ⚠️) with the collapsed 🎬 Video & QA script block — this is the style the approved mock shows. Use `--frames` only when the user asks for a frame-by-frame review; never hand-edit either form. The formatter also serves other surfaces: `--heading` swaps the heading line, which is how pr-dry takes over a PR description's QA section — rendering it as a `## 👓 QA` section from the same evidence.
- **If QA was skipped** (the change has no observable surface, or the app genuinely could not boot — the only two sanctioned reasons), the `### 👓 QA` section instead contains one paragraph saying so and what you did instead. It is never silently omitted, and no `[QA · …]` tags may appear in Top points.
- Never blur provenance: a QA symptom is not a proven code cause, and a code-read finding is not a QA observation.

## Drafting the comment

The output of every review is a **draft the user can read** — that is the deliverable, and it is how the user reviews the comment before it is posted. A draft publishes nothing: no uploads, no `gh`, no browser.

The draft IS the comment template above, rendered without live asset URLs: run `format.js` *without* `--assets` (the table renders with no frame/video URLs and uploads nothing) but **with `--scenario <qa-dir>/scenario.spec.js`**, so the draft already carries the QA script below where the video will sit — the user approves the same structure that gets posted, script and all. Prepend your authored lead + Top points, reference frames by local path, and surface the local `qa.mp4` path in chat. Keep it terse; don't spam the builder.

QA is a pure evidence producer — it hands you an evidence dir (`findings.json`, `verdict`, `steps.json`, `qa.mp4`, `frames/`) and stops. Everything in the draft is assembled from that dir plus your own review; none of it touches the network.

## Posting — only after the user reads the draft and asks

Only then does the upload/post flow run. This skill's `format.js` renders the 👓 QA block with live asset URLs; the actual uploading belongs to the **util-gh-upload** skill — follow its instructions and its consent rule.

```
# 1. list the frames the comment needs (always includes every frame a
#    findings.json entry cites, so Top points can link their screenshots;
#    the default video style adds only the failing frame, --frames adds all).
#    Use the SAME --frames flag here as in step 3, or uploads and links drift.
node ~/.claude/skills/review-dry/format.js <qa-dir> --list-frames > /tmp/frames.txt

# 2. upload frames + video per the util-gh-upload skill (its SKILL.md has the
#    command; confirm first, every time) -> <qa-dir>/assets.json

# 3. render the 👓 QA block (--scenario embeds the repro script)
node ~/.claude/skills/review-dry/format.js <qa-dir> \
     --assets <qa-dir>/assets.json \
     --video "$(node -e 'console.log(require(process.argv[1])["qa.mp4"]||"")' <qa-dir>/assets.json)" \
     --scenario <qa-dir>/scenario.spec.js
# writes <qa-dir>/comment.md — the ### 👓 QA block only
```

Then prepend the authored lead + Top points (per the approved draft) to `comment.md`, and post it as one review comment: `gh pr comment <N> --body-file <qa-dir>/comment.md`. The posted comment must match the draft the user approved — if anything material changed between draft and post (new findings, a new commit on the branch), re-draft and show the user again instead of silently posting the difference.
