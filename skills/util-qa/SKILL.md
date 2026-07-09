---
name: util-qa
description: Run a scripted browser scenario against the booted app and record a video plus per-step screenshots as evidence, reporting a pass/fail verdict. A RUNNER, not an author: it executes exactly the scenario it is handed (a .spec.js module) and never invents, repairs, waits-pads, re-seeds, or extends steps. Deciding what to test and reviewing the frames for bugs belong to the caller (the review-dry skill). Assertions (`expect` steps) make the run pass/fail — a green run is proof, not vibes.
---

# util-qa

Scripted browser QA with video evidence. **You are a runner, not an author.** You are handed a **complete** scenario (a `.spec.js` module), you boot the app, run it **verbatim**, and report the results — the verdict, which checkpoints passed or failed, and the evidence paths. Deciding *what* to test (the flows, the checkpoints, the regression cases), authoring the selectors, and reviewing the frames for bugs are the **caller's** job — the review-dry skill under /review. None of that is yours.

**Run only what you were handed. Change nothing.** Never add, drop, reorder, or reinterpret a step or checkpoint; never insert a `wait`, re-seed or re-clean data, or re-run with tweaks on your own initiative. If the scenario will not run cleanly — a selector misses, a step needs a wait, the timing is off — that is the **author's** to fix, not yours: report the failing step and its frame, and stop. Do not "repair" the script, and never paper over a real failure to manufacture a green run. A faithful red run is the correct output; a doctored green one is a lie.

## Workflow

1. **Prepare the app** (see per-project profiles below): provision the worktree and build assets. Do NOT boot the server yourself — qa.sh owns the server lifecycle. The caller hands you a complete scenario file to run; you do not write it, extend it, derive it, or fill anything in. If no runnable scenario was provided, that is a missing input — say so and stop, don't invent one.

2. **Run the scenario verbatim, from the app directory:**

   ```
   ~/.claude/skills/util-qa/qa.sh <evidence-dir>/scenario.spec.js <evidence-dir>
   ```

   qa.sh picks a free port, runs the repo's configured `serve` command, waits for readiness, runs the scenario, and (by default) kills the server on exit — pass, fail, error, or interrupt. There is NO stack detection: the boot comes from the repo's REQUIRED QA config (`profiles/<repo>.json`, see below), and a repo without one fails with `QA_CONFIG_MISSING`. A command after `--` explicitly overrides `serve` for one-off runs; commands run with `$PORT` exported. Server (and any chained build) output lands in `<evidence-dir>/server.log`. To run against an already-running server instead: `node ~/.claude/skills/util-qa/run.js <scenario.spec.js> --out <dir> --base <url> --repo <name>`.

   **Iterating? Keep the server warm.** A fresh boot rebuilds assets and boots the framework every run (tens of seconds). For repeated runs against the same worktree, add `--keep`: the server is left running and recorded, and later runs REUSE it — skipping the whole boot, so they start in well under a second and the only cost is the scenario itself. Reuse serves the assets the server booted with; framework dev-reload still picks up backend/view edits live, but a **JS/CSS source** change needs `--fresh` (stop, rebuild, reboot). `--stop` tears this worktree's warm server down. State is keyed by the git worktree root, so warm servers across parallel worktrees each get their own port and never collide.

   ```
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --keep    # boot once, leave warm
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --keep    # again → reuses, ~instant
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --fresh   # rebuild assets + reboot (frontend changed)
   ~/.claude/skills/util-qa/qa.sh --stop                            # done — kill the warm server
   ```

   Evidence dir convention: `<project>/tmp/qa/<branch-name>/` (gitignored). The runner copies the scenario there, records `qa.mp4`, saves `frames/NN-<action>.png` after every step, and writes `steps.json` with the PASS/FAIL verdict. Exit 0 = all steps passed.

   **Re-run a saved scenario with no model — `--reproduce`.** The scenario the reviewer authored persists in that evidence dir and is faithful (credentials are referenced through `vars`, never embedded), so it can be replayed without any authoring step or model in the loop — a human or a cron re-runs the exact QA. It resolves the scenario from the current branch's evidence dir, or from an explicit dir:

   ```
   ~/.claude/skills/util-qa/qa.sh --reproduce                 # replay tmp/qa/<branch>/scenario.spec.js
   ~/.claude/skills/util-qa/qa.sh --reproduce <evidence-dir>  # replay a specific saved scenario
   ```

3. **Report the results.** State the verdict (PASS/FAIL), the per-checkpoint ✓/✗ checklist the run printed, and the evidence paths — **always surface the local `qa.mp4` path** (the primary evidence a human watches) plus the frames dir and evidence dir. Hand the evidence dir (`steps.json`, `qa.mp4`, `frames/`) to the caller and stop. You do **not** review the frames for bugs, author a `findings.json`, judge whether a passing frame "looks right", format a PR comment, or upload anything — reviewing the evidence for defects is the caller's job (the **review-dry** skill), and uploading is **util-gh-upload**'s. Report the run faithfully: if a step failed, say so with its frame; never soften a red run into a green one.

## Scenario format

A scenario is a **`.spec.js` CommonJS module** that drives the run imperatively — the only scenario format. It exports an async function (or `{ run, meta }`) whose argument is the harness below, and runs through the full evidence engine: captions, per-checkpoint frames, video, music, badge, redaction, auto-login, and the `steps.json` verdict. The runner `require()`s the `.js`/`.cjs` module; `.ts` is NOT executed — write plain JS. (The markdown and JSON scenario formats were removed; the verb-string syntax survives only in login macros — see Auth.)

```js
module.exports = async ({ page, base, visit, checkpoint, see, seeButton, seeElement, click, clickText, fill, select, wait, vars }) => {
  await visit('/a/1/domains/example.com/registration/new');

  await checkpoint('Order summary shows the amount due today', () => see('Total due today'));
  await checkpoint('The register button carries the price', () =>
    seeButton('Register example.com for $'));

  // Plumbing between checkpoints — real selectors, no caption/frame, off-camera.
  await clickText('Change contact');
  await fill('#user_email', 'a@b.com');

  // A checkpoint can assert with raw Playwright too — anything that THROWS on
  // failure counts (a locator that never becomes visible times out and throws).
  await checkpoint('The contact form reopened with the saved email', () =>
    page.getByRole('textbox', { name: 'Email' }).waitFor({ state: 'visible' }));
};

// Optional metadata (there is no other place to set these).
module.exports.meta = { name: 'Registration order summary', viewport: { width: 1280, height: 900 }, music: 'lounge', hold: 1000 };
```

The harness:

- **`checkpoint(caption, assertFn)`** is the unit that proves the change. `caption` is the human sentence burned on camera and collected as the QA narrative; `assertFn` is async and **throws to fail** (a passing assertion returns/resolves). Each checkpoint flips the caption green on pass / red on fail, holds a beat, and saves a frame — a failed checkpoint FAILs the run but execution continues to the next line.
- **`visit(path)`** navigates with auto-login retry, trims the video lead-in on the first call, and re-arms the caption chrome the navigation wiped. Start with your real target `visit`; **never hardcode a login** — auto-login fires only when a step hits the login wall (see Auth).
- **Sugar** — `see(text)`, `seeElement(css)`, `seeButton(label)`, `click(css)`, `clickText(text)`, `fill(css, value)`, `select(css, value)`, `wait(ms)` — compiles to the engine's steps, so the matching rules below, the 2s per-step cap, the gold click-cursor, and scroll-into-view all apply. Reach for the raw `page` when you need more than the sugar covers.
- **`vars`** — the profile's `variables` map (the same one login macros read via `$NAME`), so a scenario that legitimately needs a configured value references it **by name** — `fill('#q', vars.EMAIL)`, `see(vars.EMAIL)` — and **never embeds the literal**. This keeps the saved scenario copy faithful (there is no secret in the source for redaction to scrub), which is what makes a later model-free `--reproduce` run replay it identically; the redaction backstop still scrubs any value that reaches a caption. Do NOT reference the login password here — auto-login owns the login step.
- **`meta`** (optional): `name`, `viewport` `{width, height}`, `music`, `hold`; omitted values fall back to defaults. Credentials never appear in a scenario — auto-login supplies them, a value a scenario genuinely needs comes from `vars` (above), and the redaction backstop scrubs configured secret values from captions, `steps.json`, and console.

**Checkpoints drive the video; the caption bar shows only them.** Choose captions a reader who doesn't know the code could still judge the feature by: "Order summary shows the amount due today", not "see the total". Each checkpoint appears in-progress (⏳, subdued bar, the profile's pending badge) and stays on screen while the plumbing between checkpoints runs off-camera; the moment its assertion passes it flips green (✅, gold left accent, larger type, the profile's success badge) and holds ~1s (tune with `meta.hold`) before the next one arms. So the video reads as a sequence of meaningful checks going green, not a scroll of every visit/click/fill. A frame PNG is saved for each checkpoint (and for a failing step); plumbing runs off-camera — no caption change, no frame, and **no `steps.json` entry** (only checkpoints are recorded). Checkpoints are flagged `"checkpoint": true` in `steps.json` and printed as a ✓/✗ checklist at the end of the run — that checklist *is* the QA narrative and drops straight into a PR's QA section. Give every behavior you set out to prove its own checkpoint. A checkpoint whose assertion throws still fails the run; the friendly caption, living in the closed shadow root, never self-matches a `see`. An **uncaught error outside a checkpoint** (a plumbing `click` whose target never appears) is captured as a failed step and FAILs the run — the video still finalizes — rather than crashing; wrap plumbing in your own `try` to soldier on.

The sugar compiles to this underlying step vocabulary — also the exact syntax **login macros** are written in (see Auth): `visit <path>`, `see "<text>"`, `see button "<label substring>"`, `see element <css>`, `click "<text>"`, `click element <css>`, `fill <css> with "<value>"`, `select <css> with "<value>"`, `wait <n>ms`.

**Exact verb semantics — the engine's matching contract, governing the sugar and login macros alike; never read run.js to answer a matching question:**

- Every target resolves to the FIRST match in DOM order. Ambiguity never errors — it silently picks the first. When the text or selector appears more than once on the page (a heading above the button, repeated table rows), scope it: `click element <css>` with a parent selector, not `click "<text>"`.
- `see "<text>"` and `click "<text>"` use Playwright text matching: whitespace-normalized, case-insensitive substring, resolving to the innermost element containing the text. `click "<text>"` can therefore land on a non-interactive element (a `<td>`, a label) if that is the first match — prefer `click element` whenever the target isn't the page's only occurrence of that text.
- `see button "<label>"` matches an `input[type=submit]` by value substring (case-sensitive) or a `<button>` by text substring (case-insensitive).
- `see element`, `click element`, `fill`, and `select` take Playwright CSS — extensions like `:has-text("…")` and `:has()` work.
- `fill` clears the field, then sets the value; the target must be a fillable input/textarea. `select` matches an `<option>` by its `value` attribute OR its visible label (exact match either way — no substrings).
- `visit` waits for network idle; a redirect to the login page raises `AUTH_FAILED`, which triggers auto-login (see Auth) and a retry.
- Every step is capped at **2s** — an assertion or interaction waits up to 2s for its target, and a `wait` is itself clamped to 2s (an over-cap wait warns and runs for 2s) — so a wrong selector costs ~2s, not minutes, and no single step can stall the run. There are no per-step timeout overrides; if a target legitimately needs longer than 2s, chain more than one `wait(2000)` call, each its own ≤2s step. The app URL comes from qa.sh (or `run.js --base`) — a scenario should not hardcode one. Scenario-wide settings (`name`, `viewport` — default `1280x900`, `music`, `hold` — the checkpoint dwell, default 1000ms) live in `module.exports.meta`, not in the steps.

**Every `see`/`see element` is a *visibility* assertion — the vocabulary has no negation.** A `see` step passes only when the target is present AND visible (`display:none`, a closed `<dialog>`, or a detached node all read as not-visible and time out). There is deliberately no "don't see", "absent", "hidden", or "gone" verb. So **never assert that something disappeared** — `see element dialog:not([open])`, `see element .modal.hidden`, etc. will always fail even when the behavior is correct. To prove a transition (a dialog closed, a modal was replaced, an item was removed), **assert the positive end state instead**: `see` the thing that should now be on screen (the new modal, the empty-state text, the next page). This positive-end-state form *is* how you write a negative or regression assertion here — you do not skip the negative because there's no "don't see" verb; you pick the on-screen fact that is true **only** when the bad outcome is absent and assert that. "The member was not removed" becomes `see "member@example.com"` on the members page after submitting; "no validation error" becomes `see` the success state. If a check genuinely needs state a verb can't express (a value in the POST body, an attribute), the caller must read it off the frame when reviewing — and if not even the frame can show it, the scenario cannot prove it; the author should say so rather than let its absence read as covered.

Evidence quality is built in: the checkpoint caption is burned into the recording and frames via an in-page bar (green on pass, red on fail), passing `see` steps scroll their target into view, each passed checkpoint holds green ~1s (tune with `meta.hold`) so it registers on camera, and the mp4 is transcoded to constant 30fps so scrubbing works. The frames directory is wiped at the start of each run, so its numbered PNGs always belong to the latest run only. Every `click` draws a gold cursor highlight — an expanding ring plus a dot — at the exact point it lands, so the video shows where each interaction happened (a headless recording has no OS cursor); the highlight lives in the same closed shadow root as the caption chrome, so it neither blocks the click nor is seen by an assertion, and it animates on camera but has faded by the time the per-step frame PNG is captured (the frame shows the resulting state).

**Background music has a few beds; a run picks one.** The synthesized "elevator music" (ffmpeg `aevalsrc`, no external asset or licensing) comes in `lounge` (mellow I–vi–ii–V, the original), `twilight` (slower, darker, dreamier), `sunrise` (quicker, brighter I–V–vi–IV pop turnaround), `reggae` (warm, dubby, with an offbeat skank chop in place of the smooth tremolo), and `ska` (the skank at double time — bright major, fast upstroke chop) — each a distinct progression, tempo, arpeggio rate, and tone. Selection is `--music <track>` (or `run.js --music`), else `meta.music`, else random per run; an unknown name falls back to `lounge`. The chosen track is recorded in `steps.json` (`"music"`) and printed with the video path.

Branding is profile-owned: a repo may supply a per-state corner **badge** that rides bottom-right over the caption bar, and it swaps with the step outcome — the profile's `running` art while a checkpoint is in progress, its `pass` art on a pass, its `fail` art on a fail. The engine ships no mascot of its own, so a repo with no `badge` in its profile simply shows no corner art (caption bar only); see REFERENCE.md for the `badge` map. Both the caption bar and the badge live inside a **closed shadow root** injected into the page. That isolation is load-bearing, not cosmetic: a `see "X"` step sets the caption to a label containing `X`, and if the chrome were in the light DOM (or an open shadow root) `getByText(X)` would match the caption itself and the assertion could never fail. Playwright cannot pierce a closed shadow root, so chrome renders on camera (in both `qa.mp4` and the per-step `frames/`) while staying invisible to every assertion. This is guarded by `test/assertion-isolation.test.sh`, which proves a `see` for absent text fails. The chrome's host also joins the browser **top layer** (a manual popover, re-asserted on every caption update), so the caption is always on top of the app under test — nothing can occlude it, not even a native modal or popover, which a plain max-`z-index` box would lose to; guarded by `test/caption-stacking.test.sh`. A self-contained "elevator music" bed — a I–vi–ii–V progression (Cmaj7–Am7–Dm7–G7) played as a soft pad with a plucked arpeggio, synthesized by ffmpeg's `aevalsrc`, no external audio asset or licensing — is mixed into the mp4 and cut to length with `-shortest`.

**Dev-account data is additive-only.** Creating records (contacts, domains, whatever the flow needs) is fine; never delete or mutate records that were already there. Do NOT submit real purchases or actions that cost money or hit a vendor for real — prefer asserting the state of the screen where the commitment would happen. The one sanctioned deletion: the dev user's password history rows, when the app forces a password upgrade (see Auth).

**Seed your own victim to prove a "this must NOT be destroyed" bug.** Thinking like a customer often means following a journey to a destructive outcome — did that member actually get removed, was that record really deleted — which collides with additive-only. Resolve it by making the at-risk record one you *created* earlier in the same scenario: invite a throwaway member, seed a disposable contact, then run the risky flow against *that*. Now carrying the journey to its end can only ever destroy your own throwaway data, never a pre-existing record, and the assertion is the positive end-state ("I still see `qa-throwaway@example.com` on the members page after submitting") — which goes red exactly when the bug destroyed it. This is the sanctioned way to catch stale-state / unintended-deletion bugs live. It does NOT license a real charge or vendor call: if reaching the outcome requires actual money or a production-vendor action, stop there, assert the pre-commit screen, and note the residual gap in the verdict.

**Set up through the UI, not the console.** When a scenario needs prerequisite data (a contact, a domain, a template), create it by driving the UI as scenario steps — that setup is itself QA coverage, runs the real validations and side effects, and shows up in the video. `rails runner`/console is fine for READING state while designing a scenario (which account is subscribed, is a domain in the DB), but writing data through it is a last resort reserved for things the UI genuinely cannot do (e.g. the password-history exception).

## Auth

Fully automatic and per-repo: login is the repo's `login` macro. On a stale or missing session the runner executes the macro's steps through the app's real login form, persists the fresh session into this skill's cookie store (`cookies.json`), and retries the step — no manual cookie saving. **Do not hardcode `- run login` as a scenario's first step:** when the session is already valid, `visit /login` redirects to the dashboard and the macro's field-fills time out. Start the scenario with its real target `visit`; auto-login kicks in only when a step actually hits the login wall. qa.sh derives `<repo>` from the origin remote's repository name and passes it via `--repo`; pass `--repo` yourself on standalone `run.js` calls.

The JSON takes `variables` (values referenced in steps as `$NAME` — credentials live here), the `macros.login` steps, plus optional keys: `sessionCookie` (when unset, ALL post-login cookies are persisted), `extraCookies` written alongside the session (e.g. an app's interstitial-bypass cookie), and `badge` (per-state corner SVGs — see REFERENCE.md). `chmod 600` it.

**Credentials never appear in evidence.** Scenarios must not contain credentials (auto-login makes that unnecessary); a config value a scenario genuinely needs is read from the `vars` harness key by name (see Scenario format), never embedded. As a backstop the runner redacts the configured variable values from everything it emits — captions, steps.json, console output, and the scenario copy in the evidence dir — so posted QA evidence cannot leak them. Note the login itself can appear on camera when a session was stale (password fields are browser-masked); rerun for a login-free recording if that matters.

Manual fallback if form login ever breaks: `node ~/.claude/skills/util-qa/save-cookie.js --host <host:port> --name _dnsimple_session --value '<paste>'`.

If the app interrupts login with a forced password-upgrade prompt, it is sanctioned to delete the dev user's password history rows in the dev database (rails runner) so the existing credentials keep working — that is the ONLY mutation of pre-existing dev data ever allowed.

Use `--no-auth` for logged-out flows (login page, marketing pages). Never fabricate cookie values; the only sanctioned paths are form login and the user's own saved cookie.

## Posting evidence to GitHub

Not QA's job. Formatting the evidence into a PR comment is the **review-dry** skill's job; uploading it is the **util-gh-upload** skill's. QA produces the evidence dir and stops; `/review-dry` picks it up from there. If you are running QA standalone and want to post, follow those two skills — and, as always, ask the user before uploading or posting, every single time.

## First run on a repo

QA needs a per-repo config at `profiles/<repo>.json` before it can boot a repo; qa.sh hard-fails with `QA_CONFIG_MISSING` when it is absent. Authoring that config (and the optional `profiles/<repo>.md` facts file) is a once-per-repo onboarding task, not a per-run one, so its full schema, the profile-markdown template, and the fresh-worktree setup live in [REFERENCE.md](REFERENCE.md). Read it the first time you QA a repo, or when a run stops with `QA_CONFIG_MISSING`. A repo that already has a profile never needs it.

## Maintaining the runner

**Environment quirks are encoded, never re-derived per run.** When the runner must assume something about the host — the app's package `type`, an available binary, a path convention, the scenario's module shape — that assumption lives in code with a boundary test in `test/`, never as a per-run "here's the workaround" note the caller rediscovers each time. A recurring note of that kind is a bug: encode it and add the test. The ESM `.cjs` loader (`requireScenario`, guarded by the `type:module` case in `test/js-scenario.test.sh`) is the template; the other host seams — a non-JS scenario path, a scenario that doesn't export a function, a repo with no profile — are pinned in `test/boundary.test.sh`.

## Failure modes

- `AUTH_FAILED` — stale cookie; re-save it (above).
- Selector timeout — the selector is wrong or the feature is broken. Read the frame for that step before deciding which.
- `NO_COOKIE` — no stored cookie for the host; save one or pass `--no-auth`.
- ffmpeg missing — `brew install ffmpeg`.
- Playwright missing — qa.sh self-heals this on every run: it preflight-installs the `playwright` npm package and the chromium browser binary (two SEPARATE installs, both living in `~/.claude/skills/util-qa`) before booting. You should not need to install anything by hand. Only if that auto-install itself fails (`PLAYWRIGHT_NPM_INSTALL_FAILED` / `PLAYWRIGHT_BROWSER_INSTALL_FAILED`) run it manually: `cd ~/.claude/skills/util-qa && npm install && npx playwright install chromium`. Do NOT install Playwright into the app worktree — the runner resolves it from the skill dir, not the app.
