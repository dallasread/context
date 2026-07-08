---
name: review-dry
description: Dry pull request review — the deliverable is a DRAFT comment, never a post. Check out the branch, review the diff through four lenses, run the util-qa skill for video evidence, and draft the comment from the canonical template (verdict lead, tagged Top points, 👓 QA section — video by default, frame-by-frame table on request). Posting, and the uploads it needs, happen only after the user reads the draft and explicitly asks. Use when asked to review a PR or branch.
---

# review-dry

Full-template pull request review with live QA evidence. You (Claude) check out the branch, review the diff through the four lenses below, run the util-qa skill for frame-backed evidence, and **draft a comment** from the canonical template. The drafted comment is the review's endpoint: the user always reads the draft before anything is posted. Posting is a separate step that runs only when the user, having read the draft, explicitly asks for it.

## Workflow

1. **Check out the branch.**

2. **Read the diff once, author a checkpoint-precise skeleton scenario, and start QA in the background — before you write up the lenses.** QA is the long pole, so kick it off first and let it run while you do the reading review. The split is by knowledge source, not author-vs-runner: **you own the WHAT (diff knowledge), QA owns the HOW (profile and live-DOM knowledge).** From the diff, author the **checkpoints** that prove the change — the actual `see "…" :: <caption>` / `see button "…" :: <caption>` lines, in the exact words to assert, each negative/regression assertion written as the positive end-state it implies (see util-qa's negation rule), in the order a real user would hit them — plus the `visit`/route lines you can read straight from the diff. Leave the DOM-dependent plumbing between checkpoints — the clicks, fills, element selectors, and any seed setup — as `TODO` lines for QA to fill against the running page. **Do not author selectors you cannot see:** you are not driving the browser, so a "precise" `click element #foo` is a blind guess a diff-touched DOM usually breaks, QA has to repair it at runtime anyway, and you have burned tokens being precise about something you can't verify. This skeleton scenario, plus (d) the refactor decision and (e) the observable lens questions below, is the single diff-derived artifact you hand down. Spawn the util-qa subagent on it **in the background** (it fills the plumbing, runs, and reviews the frames — frame review stays where the frames are, out of your context) and move straight on to the lenses while it works.

   - (d) whether this is refactoring work, and if so whether a baseline comparison is warranted. By default qa runs the branch once and reports equivalence as un-proven; ask for the doubled baseline comparison only when the refactor's risk justifies the extra run, and name the baseline ref (e.g. `origin/main`) when you do.
   - (e) the observable lens questions (UI and UX, Marketing, below) as QA's frame-review checklist.

   Pin the checkpoints precisely because their wording is yours alone to know — QA must not reinterpret "prove X" into a different caption and waste a run — but selectors and frame review both belong to the agent that can see the page. "The tests pass" / "the rendered HTML looks right" is NOT a substitute for a real run; the ONLY acceptable reason to skip QA is that the app genuinely cannot be booted here, and then you MUST say so explicitly and state what you did instead.

3. **Review the diff through the four lenses** (General, Development, UI and UX, Marketing — see below) while QA runs in the background, and output those sections in chat. They are the user's working view of the review and are never pasted into the drafted comment. **Never run linters or the test suite during a review** — CI owns those. Answer "are tests complete and passing?" by reading the specs in the diff and the PR's CI status (`gh pr checks`), not by executing anything locally.

4. **Collect QA and keep its findings in a separate, labelled bucket** (see Findings and provenance below): read the evidence dir the subagent produced — `findings.json`, the verdict, and the frames it already reviewed — without re-reviewing the PNGs yourself, and chase any `forReview` leads QA handed you as part of your code review.

5. **Synthesize Top points**: a maximum of four terse points in ELI5, prioritized by importance — do not spam the builder. Be absolutely clear on what any potential issues are and provide examples. Also form one refactoring suggestion that would make the change cleaner; it enters the draft only if it clears a 75/100 usefulness bar.

6. **Draft the comment** from the canonical template below and show it to the user in chat (or write it to `<qa-dir>/draft.md`). A draft publishes nothing — no uploads, no `gh`, no browser. Then stop.

7. **Post only on explicit request.** If the user reads the draft and asks you to post it, run the posting flow below — and still confirm before the upload step actually publishes files.

## Findings and provenance

QA's findings and your code-review findings have different provenance and different weight — never blur them:

- **Observed while running (QA)** — read `<evidence-dir>/findings.json` (and the run's verdict) that the QA subagent produced. These are defects *seen in the running app*, each backed by a frame; they are empirical. Surface them under an "Observed while running" heading in your chat reply, distinct from everything you concluded by reading code. A failed checkpoint is a blocker here. **Always relay the local `qa.mp4` path to the user in that chat reply** — the QA subagent reports it to you, not to the user, and the draft comment carries no video until something is uploaded, so the recording is only reachable if you surface its path.
- **From the diff (review)** — your own findings from the four lenses, backed by `file:line`, not frames.
- A finding's optional `forReview` field is a *lead* QA handed you (a suspected code cause it could not confirm on screen). Chase it as part of your code review and report the conclusion as YOUR finding with a `file:line` — never as a QA observation. Do not treat a QA symptom as if you had proven its cause, and do not restate a code-read finding as if QA had observed it.

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
**<Verdict>** — <one-line tally, e.g. "1 blocker, a server-side gap, and 2 nits">. <sub>verified against <a href="https://github.com/<owner>/<repo>/commit/<sha>"><sha></a></sub>

### Top points

1. **[QA · blocker]** <symptom observed on screen, naming its checkpoint; link the uploaded frame when posted>
2. **[code · major]** <finding backed by `file:line`>
3. **[QA · minor]** <...>
4. **[code · nit]** <the refactor suggestion, if it clears the 75/100 bar>

### 👓 QA

<format.js output verbatim — video style by default; --frames when a frame-by-frame review was requested>
```

Rules:

- **The lead** is one line: a verdict ("Requesting changes" / "Looks good" / "Comment"), the tally, and `verified against <sha>` linking the commit (`git rev-parse --short HEAD`). Always include the sha — a pasted comment freezes while the PR moves on, so a reader must know which tree the evidence covers.
- **Top points** is the single merged, prioritized list — max four, ELI5. Every point carries a provenance tag: `[QA · <severity>]` for frame-backed observations (from `findings.json` and failed checkpoints), `[code · <severity>]` for diff findings (with `file:line`). Severities: blocker | major | minor | nit. Every `findings.json` entry and every failed checkpoint must surface here; if more than four points survive triage, the four most severe go in, the tally says so, and the rest stay in the chat review. The refactor suggestion, when it clears the bar, takes a `[code · nit]` slot.
- **👓 QA** is `format.js` output, untouched, in one of two styles. **Video (the default):** count line, a terse ✅/⚠️ checkpoint checklist, the failing checkpoint's frame embedded only when there is one, the video inline, the QA script collapsed. **Frame-by-frame (`--frames`):** the checkpoint table (failing rows first, `<details open>`, ⚠️) with the collapsed 🎬 Video & QA script block — this is the style the approved mock shows. Use `--frames` only when the user asks for a frame-by-frame review; never hand-edit either form. The formatter also serves other surfaces: `--heading` swaps the heading line, which is how pr-dry takes over a PR description's QA section — rendering it as a `## 👓 QA` section from the same evidence.
- **If QA was skipped** (the app genuinely could not boot — the only sanctioned reason), the `### 👓 QA` section instead contains one paragraph saying so and what you did instead. It is never silently omitted, and no `[QA · …]` tags may appear in Top points.
- Never blur provenance: a QA symptom is not a proven code cause, and a code-read finding is not a QA observation.

## Drafting the comment

The output of every review is a **draft the user can read** — that is the deliverable, and it is how the user reviews the comment before it is posted. A draft publishes nothing: no uploads, no `gh`, no browser.

The draft IS the comment template above, rendered without live asset URLs: run `format.js` *without* `--assets` (the table renders with no frame/video URLs and uploads nothing), prepend your authored lead + Top points, and reference frames by local path. Nothing else goes in — keep it terse; don't spam the builder.

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
     --scenario <qa-dir>/scenario.md
# writes <qa-dir>/comment.md — the ### 👓 QA block only
```

Then prepend the authored lead + Top points (per the approved draft) to `comment.md`, and post it as one review comment: `gh pr comment <N> --body-file <qa-dir>/comment.md`. The posted comment must match the draft the user approved — if anything material changed between draft and post (new findings, a new commit on the branch), re-draft and show the user again instead of silently posting the difference.
