---
name: util-qa
description: Prove a UI change works by driving the running app in a headless browser from a scripted scenario, recording a video of the session plus per-step screenshots as evidence. A utility skill: normally invoked by the review-dry and pr-dry skills rather than on its own, though it also serves direct asks to QA, verify, or demonstrate that a change works in the real app. Assertions (`expect` steps) make the run pass/fail — a green run is proof, not vibes.
---

# util-qa

Scripted browser QA with video evidence. You (Claude) derive a scenario from the change under review, run it against the booted app, review the evidence yourself, and report the verdict with the video path.

**Be thorough: aim to surface bugs and inconsistencies, not just confirm the happy path.** Think about what the change could get wrong and write steps that would reveal it. A green run is only meaningful if a broken version of the change would have turned it red — if your scenario would pass either way, it proved little. Report what you covered and what you couldn't exercise, so a clean pass reads as "verified these paths," not a blanket "it works."

## Workflow

1. **Get the scenario's WHAT — from the caller's skeleton scenario when there is one, from the diff only when standalone.**

   **With a skeleton scenario (the /review case): fill the plumbing, don't re-derive the intent.** The review orchestrator has already read the change and hands you a **skeleton scenario**: the checkpoints are authored — the exact `see … :: caption` lines and the negative/regression assertions, in the order a real user would hit them, plus the `visit`/route lines it could read from the diff — with the DOM-dependent plumbing between them (clicks, fills, element selectors, seed setup) left as `TODO`. Your job is to complete and drive it, not to re-investigate. Fill each `TODO` with real steps against THIS profile's known-good targets and the live DOM, and **repair any target the orchestrator did author that misses the running page** — it authored those without seeing the DOM, and a diff usually touches a selector the profile's targets doc doesn't list, so only the running page confirms the real one. **Do not rewrite the authored checkpoints or their caption wording:** that is the orchestrator's diff-derived intent, and reinterpreting "prove X" into a different assertion is exactly the wasted run the skeleton exists to prevent. Keep prep to what booting needs (no diff spelunking, no git archaeology beyond checking out what the brief names), and cover every checkpoint — anything you couldn't reach is a residual gap named in your verdict. You may still ADD checkpoints for on-screen risks the skeleton missed, and everything you observe in the frames is yours to report; the skeleton floors your coverage, it doesn't cap it. For refactor work, run the branch once by default (equivalence reported un-proven) and do the baseline comparison only if the skeleton asks for it.

   **Standalone (no brief): derive the scenario from the diff — QA the observable change, not the instructions.** Read the branch diff and work out the user-visible flow it touches: which page, what the user does, what must now be true. Every claim in the change's description should map to a `see` step. Pre-existing QA instructions (issue text, PR bodies, old scenarios) are hints, never the spec: if the diff's observable behavior differs from what the instructions describe, test the behavior and say so. Don't test what the diff doesn't touch.

   **Use the caller's review questions as scenario prompts.** A /review brief includes the review lenses' questions. Treat the ones observable in a running app — data lengths, form re-fill after errors, i18n, grammar, links, required fields, mobile, CTAs, what happens *after* the page, server-side enforcement you can trip via the UI — as prompts for steps and assertions. Questions only code can answer (renames, docs, patterns, test coverage) are not yours: ignore them, and as always report nothing a frame cannot show.

   **Think like the customer, not like the diff.** Before writing steps, picture the real person on this screen: what are they trying to get done, and how would they actually behave getting there — including the messy, human parts. Customers change their mind (tick a member to remove, then reconsider and raise the seat count back up), fat-finger a value and correct it, hit back, re-submit, or arrive with more or less data than the happy path assumes. Those wandering journeys are where regressions hide, because a mechanically-correct happy path never revisits a decision — and revisiting a decision is exactly what exposes stale state left behind by a change. Walk the goal the way a customer would and follow it through to the outcome they'd see, and the risky steps write themselves.

   **Write assertions that would fail if the change regressed — not just ones that pass today.** A green run only proves the steps you wrote passed; it says nothing about the path you never exercised. So for every behavior the change adds, alters, or *guards against*, include a checkpoint a regression would break, and **drive the consequence, not only the visible pre-state**: if the change affects what a form submits, what an action does, or what a later page shows, perform that submit/action and assert the resulting state — a correct-looking screen can still submit the wrong thing (a stale hidden field, an unremoved record). Derive at least one **negative/regression assertion** per changed behavior: name the thing that must *not* happen (a member is not removed, no error banner, a section's stale input does not post), then assert the positive end-state that holds only when that bad thing didn't happen (the member still appears in the list, the success page renders, the saved record is unchanged) — see the negation note below for why negatives are always written this way. When the *only* proof of a regression would be a destructive or irreversible action the skill forbids (deleting real dev data, a real purchase), do not fake coverage: assert as close to the consequence as you safely can, and state the residual gap explicitly in your verdict rather than letting a green run imply the risk was covered.

   **Refactors: run the branch once by default; compare against the baseline only when asked.** When the change claims no behavior change (a refactor, an extraction, a dependency or framework swap), a green branch run does not by itself prove equivalence, because the spec is "identical to before." The baseline comparison that would prove it doubles the run (two boots, two worktrees), so it is NOT the default. By default, run the branch scenario once, assert the change's visible claims, and name the un-proven half as a residual gap in your verdict: "matches these paths on the branch; not diffed against the pre-refactor baseline." Do the full comparison ONLY when the caller's brief or the user explicitly asks for it. When asked, run the SAME scenario twice: once against the baseline (the main branch in its own worktree, since warm servers are keyed by worktree root so the two never collide) into its own evidence dir (e.g. `tmp/qa/<branch>-baseline/`), and once against the branch. Then compare the two runs' checkpoint frames pairwise (layout, copy, counts, values, what's enabled) and treat ANY unintended observable difference as a finding in `findings.json`. State that verdict as an equivalence claim ("matches baseline on these paths"), and if the baseline cannot be booted or a path can't be compared, say so as a residual gap.

2. **Prepare the app** (see per-project profiles below): provision the worktree and build assets. Do NOT boot the server yourself — qa.sh owns the server lifecycle.

3. **Write the scenario as markdown** into the evidence dir (see format below) — or, under /review, **complete the handed skeleton in place** by filling its `TODO` plumbing and repairing any authored target that misses the live DOM. It doubles as the human-readable QA instructions — the same text can go straight into a PR's QA section. Omit `base:` — qa.sh injects it.

4. **Run it from the app directory:**

   ```
   ~/.claude/skills/util-qa/qa.sh <evidence-dir>/scenario.md <evidence-dir>
   ```

   qa.sh picks a free port, runs the repo's configured `serve` command, waits for readiness, runs the scenario, and (by default) kills the server on exit — pass, fail, error, or interrupt. There is NO stack detection: the boot comes from the repo's REQUIRED QA config (`profiles/<repo>.json`, see below), and a repo without one fails with `QA_CONFIG_MISSING`. A command after `--` explicitly overrides `serve` for one-off runs; commands run with `$PORT` exported. Server (and any chained build) output lands in `<evidence-dir>/server.log`. To run against an already-running server instead: `node ~/.claude/skills/util-qa/run.js <scenario.md> --out <dir> --base <url> --repo <name>`.

   **Iterating? Keep the server warm.** A fresh boot rebuilds assets and boots the framework every run (tens of seconds). For repeated runs against the same worktree, add `--keep`: the server is left running and recorded, and later runs REUSE it — skipping the whole boot, so they start in well under a second and the only cost is the scenario itself. Reuse serves the assets the server booted with; framework dev-reload still picks up backend/view edits live, but a **JS/CSS source** change needs `--fresh` (stop, rebuild, reboot). `--stop` tears this worktree's warm server down. State is keyed by the git worktree root, so warm servers across parallel worktrees each get their own port and never collide.

   ```
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.md <dir> --keep    # boot once, leave warm
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.md <dir> --keep    # again → reuses, ~instant
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.md <dir> --fresh   # rebuild assets + reboot (frontend changed)
   ~/.claude/skills/util-qa/qa.sh --stop                            # done — kill the warm server
   ```

   Evidence dir convention: `<project>/tmp/qa/<branch-name>/` (gitignored). The runner copies the scenario there, records `qa.mp4`, saves `frames/NN-<action>.png` after every step, and writes `steps.json` with the PASS/FAIL verdict. Exit 0 = all steps passed.

5. **Review the evidence yourself — thoroughly, and record what you find.** Read the frame PNGs and check the UI actually looks right — assertions prove presence, not layout. A passing run with a broken-looking frame is a FAIL; say so. Look beyond what the assertions covered for bugs and inconsistencies: misaligned or overflowing layout, wrong/placeholder copy, stale or duplicated data, an off-by-one count, a control that should be disabled but isn't. If the caller passed review questions (see step 1), re-ask the observable ones of each frame — awkward long-data rendering, a lost form value, a missing CTA, unclear next steps are all findings. **Write every defect you spot into `<evidence-dir>/findings.json`** (schema below) — that file, not prose in your reply, is QA's structured list of issues. The failed checkpoint is already a finding automatically; `findings.json` is for the things no assertion caught.

6. **Report**: verdict, what was exercised, the issues found, the evidence dir, and any frames showing problems. **Always surface the local `qa.mp4` path** — it is the primary evidence a human watches, so it goes in your report every run, pass or fail, whether standalone or handed up to a caller. QA stops at evidence — it does **not** format or post a PR comment. Hand the evidence dir (`findings.json`, `verdict`, `steps.json`, `qa.mp4`, `frames/`) to the caller; assembling the PR comment is the **review-dry** skill's job, and uploading evidence is the **util-gh-upload** skill's. When run standalone (not under `/review-dry`), just report the verdict and paths and let the user decide what to do with them.

## Findings — what QA is allowed to claim

QA reports **only what it observed in the running app**, and every finding is backed by a frame. That is the whole boundary between QA and a code review: **QA answers "does it behave correctly?" (evidence = a screenshot); a code review answers "is it built correctly?" (evidence = a diff line).** The test for whether something is a QA finding: *can you point to a frame that shows it?* If yes, it's QA's to report. If the only evidence is the code, it is not a QA finding — QA never speculates about causes it cannot see on screen.

Findings live in `<evidence-dir>/findings.json`, an array the reviewing agent authors during step 5:

```json
[
  { "severity": "major", "summary": "Plan selector shows a stale price for one frame before updating", "frame": "07-select.png", "forReview": "possibly the price coercion in OrderSummary" }
]
```

- `severity` — `blocker` | `major` | `minor` | `nit`. A failed assertion is an automatic `blocker` (derived from `steps.json`); don't restate it here.
- `summary` — one observed sentence. Describe the symptom on screen, not a guess about the code.
- `frame` — the frame basename that shows it (from `frames/`). This is the evidence; include it.
- `forReview` *(optional)* — a lead handed to the review-dry skill (a suspected code cause). This is the ONE sanctioned place to record a code suspicion, and it is deliberately kept OUT of the posted QA comment — it exists so a reviewer can chase it, not so QA can claim it. The review skill's formatter never renders it.

`findings.json` is QA's whole output contract for issues: an array of observations, each backed by a frame. How the caller surfaces them — merged with the run's automatic assertion-failure finding, prioritized, linked to their screenshots — is the caller's business, not QA's.

## Scenario format

Scenarios are plain markdown. Prose and headings are free-form documentation (context, why a target domain was chosen); only bullets starting with a recognized verb execute, and the bullet text becomes the step's caption in `steps.json` and the report. An unrecognized bullet fails loudly — a typo cannot silently skip a step.

```markdown
# Registration shows an order summary with the total price

Belongs to org/repo#1234. Context prose is welcome and ignored by the runner.

## Registration

- visit /a/1/domains/example.com/registration/new
- see "Total due today" :: Order summary shows the amount due today
- see "example.com (1 year registration)" :: The domain and term are itemized
- see button "Register example.com for $" :: The register button carries the price
- click "Change contact"
- click element #submit
- fill #user_email with "a@b.com"
- select #plan with "gold"
- wait 500ms
```

**Checkpoints — mark the steps that prove the change; they drive the video.** Append ` :: <human caption>` to a step to make it a *checkpoint*: a human-meaningful moment tied precisely to what the change set out to do. The part before ` :: ` is the executable step (unchanged); the part after is a plain sentence describing what's being verified. Only checkpoints get this treatment — leave the mechanical setup (visits, clicks, fills) as raw plumbing so the meaningful checks stand out. Choose captions that a reader who doesn't know the code could still tell whether the feature works: "Order summary shows the amount due today", not "see the total".

**The caption bar shows only checkpoints.** Each checkpoint appears in-progress (⏳, subdued bar, the profile's pending badge) and stays on screen while the plumbing steps leading up to it run off-camera; the moment its own assertion passes it flips green (✅, gold left accent, larger type, the profile's success badge) and holds ~1s before the next checkpoint arms. So the video reads as a sequence of meaningful checks going green, not a scroll of every visit/click/fill. A frame PNG is saved for each checkpoint (and for a failing step); plumbing steps execute and record their PASS/FAIL in `steps.json` but produce no caption change and no frame. Checkpoints are numbered as their own `k/K` series, flagged `"checkpoint": true` in `steps.json`, and printed as a ✓/✗ checklist at the end of the run — that checklist *is* the QA narrative and drops straight into a PR's QA section. **A scenario with no checkpoints falls back to captioning every step** (classic mode) — but since checkpoints are what the viewer sees, give every scenario at least one, and usually one per behavior you set out to prove. A checkpoint whose assertion fails still fails the run (and, on a plumbing-step failure, the bar turns red naming the failed step under the checkpoint it was working toward); the friendly caption never weakens the check (and, living in the closed shadow root, never self-matches a `see`). Attach ` :: ` to a primitive step, not to `run <macro>`.

Verbs: `visit <path>`, `see "<text>"`, `see button "<label substring>"`, `see element <css>`, `click "<text>"`, `click element <css>`, `fill <css> with "<value>"`, `select <css> with "<value>"`, `wait <n>ms`, `run <macro>`.

**Exact verb semantics — this section is the engine's contract; never read run.js to answer a matching question:**

- Every target resolves to the FIRST match in DOM order. Ambiguity never errors — it silently picks the first. When the text or selector appears more than once on the page (a heading above the button, repeated table rows), scope it: `click element <css>` with a parent selector, not `click "<text>"`.
- `see "<text>"` and `click "<text>"` use Playwright text matching: whitespace-normalized, case-insensitive substring, resolving to the innermost element containing the text. `click "<text>"` can therefore land on a non-interactive element (a `<td>`, a label) if that is the first match — prefer `click element` whenever the target isn't the page's only occurrence of that text.
- `see button "<label>"` matches an `input[type=submit]` by value substring (case-sensitive) or a `<button>` by text substring (case-insensitive).
- `see element`, `click element`, `fill`, and `select` take Playwright CSS — extensions like `:has-text("…")` and `:has()` work.
- `fill` clears the field, then sets the value; the target must be a fillable input/textarea. `select` matches an `<option>` by its `value` attribute OR its visible label (exact match either way — no substrings).
- `visit` waits for network idle; a redirect to the login page raises `AUTH_FAILED`, which triggers auto-login (see Auth) and a retry.
- Every step waits up to ~2.5s for its target, so a wrong selector costs seconds, not minutes; there are no per-step timeout overrides — use `wait <n>ms` before a step whose target legitimately takes longer to appear. The first `#` heading names the run; optional `hold: <n>ms` tunes the on-camera dwell — how long each passed checkpoint holds green (default 1000ms; in a checkpoint-less scenario it's the per-step dwell, default 250ms); raise it for a slower demo, set `hold: 0ms` to run as fast as the app responds; optional `music: <track>` picks the background bed (see below); optional `viewport: <w>x<h>` sizes the browser and the recorded video/frames (default `1280x900`) — set e.g. `viewport: 390x844` to capture the same pages at a mobile width. The app URL comes from qa.sh (or `run.js --base`) — a scenario should not hardcode one, though a `base:` line still works standalone.

**Every `see`/`see element` is a *visibility* assertion — the vocabulary has no negation.** A `see` step passes only when the target is present AND visible (`display:none`, a closed `<dialog>`, or a detached node all read as not-visible and time out). There is deliberately no "don't see", "absent", "hidden", or "gone" verb. So **never assert that something disappeared** — `see element dialog:not([open])`, `see element .modal.hidden`, etc. will always fail even when the behavior is correct. To prove a transition (a dialog closed, a modal was replaced, an item was removed), **assert the positive end state instead**: `see` the thing that should now be on screen (the new modal, the empty-state text, the next page). This positive-end-state form *is* how you write a negative or regression assertion here — you do not skip the negative because there's no "don't see" verb; you pick the on-screen fact that is true **only** when the bad outcome is absent and assert that. "The member was not removed" becomes `see "member@example.com"` on the members page after submitting; "no validation error" becomes `see` the success state. If you genuinely must inspect state a verb can't express (a value in the POST body, an attribute), do it in review (step 5) by reading the frame — and if not even the frame can show it, say so in the verdict; don't let its absence read as covered.

`run <macro>` expands a repo-defined macro from the QA config's `"macros"` key: a multi-line string or array of steps (leading `-` optional), one level deep — macros contain only primitive verbs, never `run`. `$NAME` placeholders in any step (macro or scenario) resolve from the config's `"variables"` at execution time only; captions and posted evidence keep the placeholder, so values — credentials included — never leave the config, and unknown names stay literal (prose like `"$14.50"` can't false-trip). The scenario stays terse — `- run login` — while the evidence captions show the expanded steps (`login › visit /login`). An unknown macro fails loudly, same as a typo'd verb. The `login` macro is special: it is also what auto-login executes on a stale session. A failed step stops the run (later steps are meaningless) but the video and manifest are still written. Legacy `.json` scenarios still run.

Evidence quality is built in: the checkpoint caption is burned into the recording and frames via an in-page bar (green on pass, red on fail), passing `see` steps scroll their target into view, each passed checkpoint holds green ~1s (tune with `hold:`) so it registers on camera, and the mp4 is transcoded to constant 30fps so scrubbing works. The frames directory is wiped at the start of each run, so its numbered PNGs always belong to the latest run only. Every `click` draws a gold cursor highlight — an expanding ring plus a dot — at the exact point it lands, so the video shows where each interaction happened (a headless recording has no OS cursor); the highlight lives in the same closed shadow root as the caption chrome, so it neither blocks the click nor is seen by an assertion, and it animates on camera but has faded by the time the per-step frame PNG is captured (the frame shows the resulting state).

**Background music has a few beds; a run picks one.** The synthesized "elevator music" (ffmpeg `aevalsrc`, no external asset or licensing) comes in `lounge` (mellow I–vi–ii–V, the original), `twilight` (slower, darker, dreamier), `sunrise` (quicker, brighter I–V–vi–IV pop turnaround), `reggae` (warm, dubby, with an offbeat skank chop in place of the smooth tremolo), and `ska` (the skank at double time — bright major, fast upstroke chop) — each a distinct progression, tempo, arpeggio rate, and tone. Selection is `--music <track>` (or `run.js --music`), else a `music: <track>` line in the scenario, else random per run; an unknown name falls back to `lounge`. The chosen track is recorded in `steps.json` (`"music"`) and printed with the video path.

Branding is profile-owned: a repo may supply a per-state corner **badge** that rides bottom-right over the caption bar, and it swaps with the step outcome — the profile's `running` art while a checkpoint is in progress, its `pass` art on a pass, its `fail` art on a fail. The engine ships no mascot of its own, so a repo with no `badge` in its profile simply shows no corner art (caption bar only); see "Creating a per-repo config" for the `badge` map. Both the caption bar and the badge live inside a **closed shadow root** injected into the page. That isolation is load-bearing, not cosmetic: a `see "X"` step sets the caption to a label containing `X`, and if the chrome were in the light DOM (or an open shadow root) `getByText(X)` would match the caption itself and the assertion could never fail. Playwright cannot pierce a closed shadow root, so chrome renders on camera (in both `qa.mp4` and the per-step `frames/`) while staying invisible to every assertion. This is guarded by `test/assertion-isolation.test.sh`, which proves a `see` for absent text fails. The chrome's host also joins the browser **top layer** (a manual popover, re-asserted on every caption update), so the caption is always on top of the app under test — nothing can occlude it, not even a native modal or popover, which a plain max-`z-index` box would lose to; guarded by `test/caption-stacking.test.sh`. A self-contained "elevator music" bed — a I–vi–ii–V progression (Cmaj7–Am7–Dm7–G7) played as a soft pad with a plucked arpeggio, synthesized by ffmpeg's `aevalsrc`, no external audio asset or licensing — is mixed into the mp4 and cut to length with `-shortest`.

**Dev-account data is additive-only.** Creating records (contacts, domains, whatever the flow needs) is fine; never delete or mutate records that were already there. Do NOT submit real purchases or actions that cost money or hit a vendor for real — prefer asserting the state of the screen where the commitment would happen. The one sanctioned deletion: the dev user's password history rows, when the app forces a password upgrade (see Auth).

**Seed your own victim to prove a "this must NOT be destroyed" bug.** Thinking like a customer often means following a journey to a destructive outcome — did that member actually get removed, was that record really deleted — which collides with additive-only. Resolve it by making the at-risk record one you *created* earlier in the same scenario: invite a throwaway member, seed a disposable contact, then run the risky flow against *that*. Now carrying the journey to its end can only ever destroy your own throwaway data, never a pre-existing record, and the assertion is the positive end-state ("I still see `qa-throwaway@example.com` on the members page after submitting") — which goes red exactly when the bug destroyed it. This is the sanctioned way to catch stale-state / unintended-deletion bugs live. It does NOT license a real charge or vendor call: if reaching the outcome requires actual money or a production-vendor action, stop there, assert the pre-commit screen, and note the residual gap in the verdict.

**Set up through the UI, not the console.** When a scenario needs prerequisite data (a contact, a domain, a template), create it by driving the UI as scenario steps — that setup is itself QA coverage, runs the real validations and side effects, and shows up in the video. `rails runner`/console is fine for READING state while designing a scenario (which account is subscribed, is a domain in the DB), but writing data through it is a last resort reserved for things the UI genuinely cannot do (e.g. the password-history exception).

## Auth

Fully automatic and per-repo: login is the repo's `login` macro. On a stale or missing session the runner executes the macro's steps through the app's real login form, persists the fresh session into this skill's cookie store (`cookies.json`), and retries the step — no manual cookie saving. **Do not hardcode `- run login` as a scenario's first step:** when the session is already valid, `visit /login` redirects to the dashboard and the macro's field-fills time out. Start the scenario with its real target `visit`; auto-login kicks in only when a step actually hits the login wall. qa.sh derives `<repo>` from the origin remote's repository name and passes it via `--repo`; pass `--repo` yourself on standalone `run.js` calls.

The JSON takes `variables` (values referenced in steps as `$NAME` — credentials live here), the `macros.login` steps, plus optional keys: `sessionCookie` (when unset, ALL post-login cookies are persisted), `extraCookies` written alongside the session (e.g. an app's interstitial-bypass cookie), and `badge` (per-state corner SVGs — see REFERENCE.md). `chmod 600` it.

**Credentials never appear in evidence.** Scenarios must not contain credentials (auto-login makes that unnecessary), and as a backstop the runner redacts the configured email/password values from everything it emits — captions, steps.json, console output, and the scenario copy in the evidence dir — so posted QA evidence cannot leak them. Note the login itself can appear on camera when a session was stale (password fields are browser-masked); rerun for a login-free recording if that matters.

Manual fallback if form login ever breaks: `node ~/.claude/skills/util-qa/save-cookie.js --host <host:port> --name _dnsimple_session --value '<paste>'`.

If the app interrupts login with a forced password-upgrade prompt, it is sanctioned to delete the dev user's password history rows in the dev database (rails runner) so the existing credentials keep working — that is the ONLY mutation of pre-existing dev data ever allowed.

Use `--no-auth` for logged-out flows (login page, marketing pages). Never fabricate cookie values; the only sanctioned paths are form login and the user's own saved cookie.

## Posting evidence to GitHub

Not QA's job. Formatting the evidence into a PR comment is the **review-dry** skill's job; uploading it is the **util-gh-upload** skill's. QA produces the evidence dir and stops; `/review-dry` picks it up from there. If you are running QA standalone and want to post, follow those two skills — and, as always, ask the user before uploading or posting, every single time.

## First run on a repo

QA needs a per-repo config at `profiles/<repo>.json` before it can boot a repo; qa.sh hard-fails with `QA_CONFIG_MISSING` when it is absent. Authoring that config (and the optional `profiles/<repo>.md` facts file) is a once-per-repo onboarding task, not a per-run one, so its full schema, the profile-markdown template, and the fresh-worktree setup live in [REFERENCE.md](REFERENCE.md). Read it the first time you QA a repo, or when a run stops with `QA_CONFIG_MISSING`. A repo that already has a profile never needs it.

## Failure modes

- `AUTH_FAILED` — stale cookie; re-save it (above).
- Selector timeout — the selector is wrong or the feature is broken. Read the frame for that step before deciding which.
- `NO_COOKIE` — no stored cookie for the host; save one or pass `--no-auth`.
- ffmpeg missing — `brew install ffmpeg`.
- Playwright missing — qa.sh self-heals this on every run: it preflight-installs the `playwright` npm package and the chromium browser binary (two SEPARATE installs, both living in `~/.claude/skills/util-qa`) before booting. You should not need to install anything by hand. Only if that auto-install itself fails (`PLAYWRIGHT_NPM_INSTALL_FAILED` / `PLAYWRIGHT_BROWSER_INSTALL_FAILED`) run it manually: `cd ~/.claude/skills/util-qa && npm install && npx playwright install chromium`. Do NOT install Playwright into the app worktree — the runner resolves it from the skill dir, not the app.
