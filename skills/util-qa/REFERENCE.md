# util-qa reference — authoring scenarios and onboarding a repo

Cold-path detail lifted out of `SKILL.md` so the runner's per-run hot path stays tiny. The runner (util-qa) does not need any of this to execute a scenario it was handed. You reach for this file in two situations:

- **Authoring a scenario** — the caller (the review-dry skill) writes the `.spec.js` the runner will execute. The scenario format, the harness, the verb semantics, and the evidence engine are all here.
- **Onboarding a repo** — the first time a repo is QA'd, or when a run stops with `QA_CONFIG_MISSING`. A repo that already has a `profiles/<repo>.json` never needs the onboarding half.

---

# Authoring a scenario

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

- **`checkpoint(caption, assertFn, opts?)`** is the unit that proves the change. `caption` is the human sentence burned on camera and collected as the QA narrative; `assertFn` is async and **throws to fail** (a passing assertion returns/resolves). Each checkpoint flips the caption green on pass / red on fail, holds a beat, and saves a frame — a failed checkpoint FAILs the run but execution continues to the next line. `opts.narrate` (optional) is a separate SPOKEN line for the accessibility narration track — see Narration below; omit it and the caption itself is read aloud verbatim.
- **`visit(path)`** navigates with auto-login retry, trims the video lead-in on the first call, and re-arms the caption chrome the navigation wiped. Start with your real target `visit`; **never hardcode a login** — auto-login fires only when a step hits the login wall (see Auth).
- **Sugar** — `see(text)`, `seeElement(css)`, `seeButton(label)`, `click(css)`, `clickText(text)`, `fill(css, value)`, `select(css, value)`, `wait(ms)` — compiles to the engine's steps, so the matching rules below, the 2s per-step cap, the gold click-cursor, and scroll-into-view all apply. Reach for the raw `page` when you need more than the sugar covers.
- **`vars`** — the profile's `variables` map (the same one login macros read via `$NAME`), so a scenario that legitimately needs a configured value references it **by name** — `fill('#q', vars.EMAIL)`, `see(vars.EMAIL)` — and **never embeds the literal**. This keeps the saved scenario copy faithful (there is no secret in the source for redaction to scrub), which is what lets a later model-free re-run of the saved copy replay it identically; the redaction backstop still scrubs any value that reaches a caption. Do NOT reference the login password here — auto-login owns the login step.
- **`meta`** (optional): `name`, `viewport` `{width, height}`, `music`, `hold`, `intro`, `narrate`; omitted values fall back to defaults. Credentials never appear in a scenario — auto-login supplies them, a value a scenario genuinely needs comes from `vars` (above), and the redaction backstop scrubs configured secret values from captions, `steps.json`, and console.

**Accessibility narration** reads the scenario's goal and each checkpoint aloud (macOS `say`, offline TTS — no external asset or licensing, the same stance as the music beds), muxed into `qa.mp4`'s audio under the music bed, so a viewer who can't watch the screen still gets the QA narrative. It's on by default; `--no-narrate` (or `meta.narrate: false`) turns it off, and a host with no `say` binary silently gets no narration track (never a run failure) — either way `steps.json` records `narrated` and a `narration: [{text, atSec}]` array.

The WORDING is authored, not generated by the engine: write the spoken line yourself, once, in the `.spec.js` — `checkpoint(caption, assertFn, { narrate: "…" })` for a checkpoint, `meta.intro` for the opener — so a repo's voice ("delightfully cheerful", "funny and long-winded", deadpan, whatever fits the app) is baked into the saved scenario and a model-free re-run replays it identically. Omit `narrate`/`intro` and the default is the caption itself (`"Reviewing: <name>"` for the intro). The actual **voice** (a macOS `say` voice name, e.g. `Samantha`) is profile-owned — set `narrationVoice` in `profiles/<repo>.js` (see onboarding below); document the intended tone as `narrationStyle` guidance in `profiles/<repo>.md` so scenario authors write consistent narration for that app.

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

**Background music has a few beds; a run picks one.** The synthesized "elevator music" (ffmpeg `aevalsrc`, no external asset or licensing) comes in `lounge` (mellow I–vi–ii–V, the original), `twilight` (slower, darker, dreamier), `sunrise` (quicker, brighter I–V–vi–IV pop turnaround), `reggae` (warm, dubby, with an offbeat skank chop in place of the smooth tremolo), and `ska` (the skank at double time — bright major, fast upstroke chop) — each a distinct progression, tempo, arpeggio rate, and tone. Selection is `--music <track>` (or `run.js --music`), else `meta.music`, else a deterministic default hashed from the scenario name (the same scenario always gets the same bed, so a model-free re-run replays identically); an unknown name falls back to `lounge`. The chosen track is recorded in `steps.json` (`"music"`) and printed with the video path.

Branding is profile-owned: a repo may supply a per-state corner **badge** that rides bottom-right over the caption bar, and it swaps with the step outcome — the profile's `running` art while a checkpoint is in progress, its `pass` art on a pass, its `fail` art on a fail. The engine ships no mascot of its own, so a repo with no `badge` in its profile simply shows no corner art (caption bar only); see the onboarding half of this file for the `badge` map. Both the caption bar and the badge live inside a **closed shadow root** injected into the page. That isolation is load-bearing, not cosmetic: a `see "X"` step sets the caption to a label containing `X`, and if the chrome were in the light DOM (or an open shadow root) `getByText(X)` would match the caption itself and the assertion could never fail. Playwright cannot pierce a closed shadow root, so chrome renders on camera (in both `qa.mp4` and the per-step `frames/`) while staying invisible to every assertion. This is guarded by `test/assertion-isolation.test.sh`, which proves a `see` for absent text fails. The chrome's host also joins the browser **top layer** (a manual popover, re-asserted on every caption update), so the caption is always on top of the app under test — nothing can occlude it, not even a native modal or popover, which a plain max-`z-index` box would lose to; guarded by `test/caption-stacking.test.sh`.

**Dev-account data is additive-only.** Creating records (contacts, domains, whatever the flow needs) is fine; never delete or mutate records that were already there. Do NOT submit real purchases or actions that cost money or hit a vendor for real — prefer asserting the state of the screen where the commitment would happen. The one sanctioned deletion: the dev user's password history rows, when the app forces a password upgrade (see Auth).

**Seed your own victim to prove a "this must NOT be destroyed" bug.** Thinking like a customer often means following a journey to a destructive outcome — did that member actually get removed, was that record really deleted — which collides with additive-only. Resolve it by making the at-risk record one you *created* earlier in the same scenario: invite a throwaway member, seed a disposable contact, then run the risky flow against *that*. Now carrying the journey to its end can only ever destroy your own throwaway data, never a pre-existing record, and the assertion is the positive end-state ("I still see `qa-throwaway@example.com` on the members page after submitting") — which goes red exactly when the bug destroyed it. This is the sanctioned way to catch stale-state / unintended-deletion bugs live. It does NOT license a real charge or vendor call: if reaching the outcome requires actual money or a production-vendor action, stop there, assert the pre-commit screen, and note the residual gap in the verdict.

**Set up through the UI, not the console.** When a scenario needs prerequisite data (a contact, a domain, a template), create it by driving the UI as scenario steps — that setup is itself QA coverage, runs the real validations and side effects, and shows up in the video. A read-only console/`runner` query is fine for READING state while designing a scenario (which account is subscribed, is a domain in the DB), but writing data through it is a last resort reserved for things the UI genuinely cannot do (e.g. the password-history exception).

## Auth

Fully automatic and per-repo: login is the repo's `login` function in `profiles/<repo>.js`. On a stale or missing session the runner calls `login({ page, base, vars })` — raw Playwright plus the profile's `variables` injected as `vars` — to drive the app's real login form, persists the fresh session into this skill's cookie store (`cookies.json`), and retries the step. The function gets the raw `page` (not the scenario's auto-login `visit`, which would recurse), so it uses `page.goto`/`page.fill`/`page.click` directly:

```js
login: async ({ page, base, vars }) => {
  await page.goto(base + '/login', { waitUntil: 'networkidle' });
  await page.fill('#email', vars.EMAIL);
  await page.fill('#password', vars.PASSWORD);
  await page.click('form [type=submit]');
},
```

**Never call `login` yourself from a scenario:** start the scenario with its real target `visit`, and auto-login fires only when a step actually hits the login wall (calling it up front, when the session is already valid, would land on the dashboard and its field-fills would time out). qa.sh derives `<repo>` from the origin remote's repository name and passes it via `--repo`; pass `--repo` yourself on standalone `run.js` calls.

The profile module exports `variables` (credentials and config values, read as `vars.NAME` in both `login()` and scenarios — never embedded in either), the `login` function, plus optional keys: `sessionCookie` (when unset, ALL post-login cookies are persisted), `extraCookies` written alongside the session (e.g. an app's interstitial-bypass cookie), and `badge` (per-state corner SVGs — see the onboarding half below). `chmod 600` it. A repo with no authenticated flows (a static site) needs no `login` and no `variables`; run it with `--no-auth`.

**Credentials never appear in evidence.** Scenarios must not contain credentials (auto-login makes that unnecessary); a config value a scenario genuinely needs is read from the `vars` harness key by name (see above), never embedded. As a backstop the runner redacts the configured variable values from everything it emits — captions, steps.json, console output, and the scenario copy in the evidence dir — so posted QA evidence cannot leak them. Note the login itself can appear on camera when a session was stale (password fields are browser-masked); rerun for a login-free recording if that matters.

Manual fallback if form login ever breaks: `node ~/.claude/skills/util-qa/save-cookie.js --host <host:port> --name <session-cookie> --value '<paste>'`.

If the app interrupts login with a forced password-upgrade prompt, it is sanctioned to delete the dev user's password history rows in the dev database so the existing credentials keep working — that is the ONLY mutation of pre-existing dev data ever allowed.

Use `--no-auth` for logged-out flows (login page, marketing pages). Never fabricate cookie values; the only sanctioned paths are form login and the user's own saved cookie.

---

# Onboarding a repo

This skill's engine carries no repo-specific knowledge and does no guessing: **every repo MUST have a QA config** at `profiles/<repo>.json` (gitignored, machine-local) before it can be QA'd. qa.sh hard-fails with `QA_CONFIG_MISSING` otherwise.

- **First time on a repo: author its config.** Read the repo's README/CONTRIBUTING/CLAUDE.md to learn the dev server and asset build, then write `profiles/<repo>.json` (see "Creating a per-repo config" below). This happens once, deliberately — never inferred at run time.
- **`profiles/<repo>.md`** (optional but encouraged) holds the human facts: why the boot is what it is, dev data caveats, scenario tips. Check it before writing scenarios.
- **Fresh worktree**: `~/.claude/skills/util-qa/setup-worktree.sh <worktree-path>` copies the main checkout's own gitignored files (minus universal junk: dependency installs, logs, caches, editor state) — repo-agnostic by construction. Then install dependencies; the config's `build` handles assets on each run.

### Creating a per-repo config

A per-repo config is one or two files named after the origin remote's repository name (`git remote get-url origin` basename, e.g. `app` for my/app):

- `profiles/<repo>.js` — REQUIRED. A JS module exporting the machine config: boot + login. `chmod 600` it.

  ```js
  module.exports = {
    serve: 'bin/vite build && exec bundle exec puma -C config/puma.rb -p "$PORT"',
    variables: { EMAIL: 'dev-user@example.com', PASSWORD: '…' },
    extraCookies: { some_interstitial_bypass: '1' },
    badge: { running: '<repo>.running.svg', pass: '<repo>.pass.svg', fail: '<repo>.fail.svg' },
    narrationVoice: 'Samantha', // optional — a macOS `say` voice name; default is Samantha
    login: async ({ page, base, vars }) => {
      await page.goto(base + '/login', { waitUntil: 'networkidle' });
      await page.fill('input[type=email]', vars.EMAIL);
      await page.fill('input[type=password]', vars.PASSWORD);
      await page.click('form:has(input[type=password]) [type=submit]');
    },
  };
  ```

  `serve` is one flat shell command run via `sh -c` with `$PORT` exported — chain an asset build with `&&`, and `exec` the final server so it owns the process. `variables` hold credentials and config values, read as `vars.NAME` by both `login()` and scenarios (never embedded in either). `login` is an async function that drives the real login form with raw Playwright (`page`) and the injected `vars`; it is required for authenticated QA (auto-login calls it) and omitted for logged-out-only repos. Source the values from the repo's README/CONTRIBUTING/seeds — deliberately, once.

  `badge` is OPTIONAL branding: the little corner SVG on the video, mapped by outcome state to a file resolved against `profiles/` (an absolute path also works). Keys match the caption states — `running` (a checkpoint in progress), `pass`, `fail` — and the map is open, so any future state is branded by adding its key. Each state is independent; omit one and that outcome shows no badge. Omit `badge` entirely and the run shows no corner art at all — the engine carries no default mascot. Supply distinct art per state (they are swapped, not recolored); state the art's provenance/licensing in `<repo>.md`.

  `narrate` and `narrationIntro` are OPTIONAL repo-level defaults (both default `true`): `narrate: false` turns off narration for every scenario in this repo unless one explicitly opts back in (`meta.narrate: true`); `narrationIntro: false` drops the spoken opener repo-wide (checkpoints still narrate) unless a scenario sets its own `meta.intro`. Either can still be overridden per scenario — the scenario's own `meta.narrate` / `meta.intro` always wins over the repo default; `--no-narrate` on the command line is the one override nothing can undo.

  `narrationVoice` is OPTIONAL: a macOS `say` voice name used for the accessibility narration track (default `Samantha`). It controls the delivery (the actual voice), not the wording — the spoken lines themselves are authored per scenario via `meta.intro` / `checkpoint(…, { narrate })` (see Authoring above). Document the intended tone as `narrationStyle` prose in `profiles/<repo>.md` (e.g. "delightfully cheerful", "funny and long-winded") so scenario authors write narration consistent with that repo's voice.

- `profiles/<repo>.md` — optional but encouraged human facts. Keep it facts-only (the engine's mechanics stay in the skill docs), and never put the actual credentials in the markdown; they live only in the JSON.

Sections for the markdown, each only when the repo actually deviates:

```markdown
# <repo> (<local path>)

## Boot
WHY the config's build/server are what they are (e.g. why the repo's own
bin/dev is unsuitable for headless QA), so the reasoning survives.

## Auth and data
Where the JSON's credentials come from (seeds, README), which dev account
has what state (subscriptions, roles), what the extraCookies bypass.

## Scenario targets
Known-good data for flows: what to visit, what redirects, what to avoid,
required page-distinguishing assertions.

## Narration style
The tone scenario authors should write `meta.intro` / `checkpoint(…, { narrate })`
lines in for this repo (e.g. "delightfully cheerful", "funny and long-winded",
deadpan) — pairs with the JS config's `narrationVoice`.

## Related
Seed/provisioning caveats that bite QA (one line each).
```

Profiles are gitignored (machine-local, may reference private data). When a fact is durable and shareable, prefer fixing the repo's own README/CLAUDE.md and shrinking the profile.
