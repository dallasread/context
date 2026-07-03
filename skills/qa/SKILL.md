---
name: qa
description: Prove a UI change works by driving the running app in a headless browser from a scripted scenario, recording a video of the session plus per-step screenshots as evidence. Use when asked to QA, verify, or demonstrate that a change works in the real app, and as the live-QA step of /review. Assertions (`expect` steps) make the run pass/fail — a green run is proof, not vibes.
---

# qa

Scripted browser QA with video evidence. You (Claude) derive a scenario from the change under review, run it against the booted app, review the evidence yourself, and report the verdict with the video path.

## Workflow

1. **Derive the scenario from the diff — QA the observable change, not the instructions.** Read the branch diff and work out the user-visible flow it touches: which page, what the user does, what must now be true. Every claim in the change's description should map to a `see` step. Pre-existing QA instructions (issue text, PR bodies, old scenarios) are hints, never the spec: if the diff's observable behavior differs from what the instructions describe, test the behavior and say so. Don't test what the diff doesn't touch.

2. **Prepare the app** (see per-project profiles below): provision the worktree and build assets. Do NOT boot the server yourself — qa.sh owns the server lifecycle.

3. **Write the scenario as markdown** into the evidence dir (see format below). It doubles as the human-readable QA instructions — the same text can go straight into a PR's QA section. Omit `base:` — qa.sh injects it.

4. **Run it from the app directory:**

   ```
   ~/.claude/skills/qa/qa.sh <evidence-dir>/scenario.md <evidence-dir>
   ```

   qa.sh picks a free port, runs the repo's configured `serve` command, waits for readiness, runs the scenario, and ALWAYS kills the server on exit — pass, fail, error, or interrupt. There is NO stack detection: the boot comes from the repo's REQUIRED QA config (`profiles/<repo>.json`, see below), and a repo without one fails with `QA_CONFIG_MISSING`. A command after `--` explicitly overrides `serve` for one-off runs; commands run with `$PORT` exported. Server (and any chained build) output lands in `<evidence-dir>/server.log`. To run against an already-running server instead: `node ~/.claude/skills/qa/run.js <scenario.md> --out <dir> --base <url> --repo <name>`.

   Evidence dir convention: `<project>/tmp/qa/<branch-name>/` (gitignored). The runner copies the scenario there, records `qa.mp4`, saves `frames/NN-<action>.png` after every step, and writes `steps.json` with the PASS/FAIL verdict. Exit 0 = all steps passed.

5. **Review the evidence yourself.** Read the frame PNGs and check the UI actually looks right — assertions prove presence, not layout. A passing run with a broken-looking frame is a FAIL; say so.

6. **Report**: verdict, what was exercised, the video path, and any frames showing problems. To embed the mp4/frames in a PR, use `post.js` (see "Posting evidence to GitHub" below) — ask the user first, every time.

## Scenario format

Scenarios are plain markdown. Prose and headings are free-form documentation (context, why a target domain was chosen); only bullets starting with a recognized verb execute, and the bullet text becomes the step's caption in `steps.json` and the report. An unrecognized bullet fails loudly — a typo cannot silently skip a step.

```markdown
# Registration shows an order summary with the total price

Belongs to org/repo#1234. Context prose is welcome and ignored by the runner.

## Registration

- visit /a/1/domains/example.com/registration/new
- see "Total due today"
- see "example.com (1 year registration)"
- see button "Register example.com for $"
- click "Change contact"
- click element #submit
- fill #user_email with "a@b.com"
- select #plan with "gold"
- wait 500ms
```

Verbs: `visit <path>`, `see "<text>"`, `see button "<label substring>"`, `see element <css>`, `click "<text>"`, `click element <css>`, `fill <css> with "<value>"`, `select <css> with "<value>"`, `wait <n>ms`, `run <macro>`. The first `#` heading names the run; optional `hold: <n>ms` sets the per-step dwell (default 1500ms). The app URL comes from qa.sh (or `run.js --base`) — a scenario should not hardcode one, though a `base:` line still works standalone.

`run <macro>` expands a repo-defined macro from the QA config's `"macros"` key: a multi-line string or array of steps (leading `-` optional), one level deep — macros contain only primitive verbs, never `run`. `$NAME` placeholders in any step (macro or scenario) resolve from the config's `"variables"` at execution time only; captions and posted evidence keep the placeholder, so values — credentials included — never leave the config, and unknown names stay literal (prose like `"$14.50"` can't false-trip). The scenario stays terse — `- run login` — while the evidence captions show the expanded steps (`login › visit /login`). An unknown macro fails loudly, same as a typo'd verb. The `login` macro is special: it is also what auto-login executes on a stale session. A failed step stops the run (later steps are meaningless) but the video and manifest are still written. Legacy `.json` scenarios still run.

Evidence quality is built in: each step's caption is burned into the recording and frames via an in-page bar (red ✗ on failure), passing `see` steps scroll their target into view, the runner dwells `hold:` ms on every state, and the mp4 is transcoded to constant 30fps so scrubbing works.

**Dev-account data is additive-only.** Creating records (contacts, domains, whatever the flow needs) is fine; never delete or mutate records that were already there. Do NOT submit real purchases or destructive actions — prefer asserting the state of the screen where the commitment would happen. The one sanctioned deletion: the dev user's password history rows, when the app forces a password upgrade (see Auth).

**Set up through the UI, not the console.** When a scenario needs prerequisite data (a contact, a domain, a template), create it by driving the UI as scenario steps — that setup is itself QA coverage, runs the real validations and side effects, and shows up in the video. `rails runner`/console is fine for READING state while designing a scenario (which account is subscribed, is a domain in the DB), but writing data through it is a last resort reserved for things the UI genuinely cannot do (e.g. the password-history exception).

## Auth

Fully automatic and per-repo: login is the repo's `login` macro. On a stale or missing session the runner executes the macro's steps through the app's real login form, persists the fresh session into this skill's cookie store (`cookies.json`), and retries the step — no manual cookie saving. qa.sh derives `<repo>` from the origin remote's repository name and passes it via `--repo`; pass `--repo` yourself on standalone `run.js` calls.

The JSON takes `variables` (values referenced in steps as `$NAME` — credentials live here), the `macros.login` steps, plus optional keys: `sessionCookie` (when unset, ALL post-login cookies are persisted) and `extraCookies` written alongside the session (e.g. an app's interstitial-bypass cookie). `chmod 600` it.

**Credentials never appear in evidence.** Scenarios must not contain credentials (auto-login makes that unnecessary), and as a backstop the runner redacts the configured email/password values from everything it emits — captions, steps.json, console output, and the scenario copy in the evidence dir — so posted QA evidence cannot leak them. Note the login itself can appear on camera when a session was stale (password fields are browser-masked); rerun for a login-free recording if that matters.

Manual fallback if form login ever breaks: `node ~/.claude/skills/qa/save-cookie.js --host <host:port> --name _dnsimple_session --value '<paste>'`.

If the app interrupts login with a forced password-upgrade prompt, it is sanctioned to delete the dev user's password history rows in the dev database (rails runner) so the existing credentials keep working — that is the ONLY mutation of pre-existing dev data ever allowed.

Use `--no-auth` for logged-out flows (login page, marketing pages). Never fabricate cookie values; the only sanctioned paths are form login and the user's own saved cookie.

## Posting evidence to GitHub

Inline-playable PR videos are `user-attachments` assets, which have no official API. `post.js` automates only the upload by driving the PR page's comment box in a logged-in browser profile; it prints the asset URL and never posts anything.

**ALWAYS ask the user before uploading/posting — every single time, no standing consent.** Uploading already publishes the file to a GitHub-hosted URL, so the ask comes before `post.js` runs, not just before the `gh` call.

```
node ~/.claude/skills/qa/post.js --login                         # one-time interactive login (headed)
node ~/.claude/skills/qa/post.js <qa-dir>/qa.mp4 --repo dnsimple/dnsimple-app --pr 12345
```

Then place the printed URL via `gh` (a bare user-attachments URL on its own line renders as an inline player), always followed by the scenario markdown that produced it in a collapsed block, so the evidence carries its reproducible script:

````markdown
https://github.com/user-attachments/assets/<id>

<details>
<summary>QA script</summary>

```markdown
<contents of scenario.md>
```

</details>
````

Placement:

- **The user's own PR** — into the `## 👓 Preview` section of the PR body (above QA), via `gh pr edit --body-file`.
- **Reviewing someone else's PR** — into the review/comment being posted, alongside the verdict and step list from `steps.json`.

On `NOT_LOGGED_IN`, ask the user to run the `--login` command above (it opens a real browser window for them, including 2FA). A GitHub DOM change can break the upload; it fails loudly — fall back to telling the user the video path for manual drag-drop.

## Booting any repo

This skill's engine carries no repo-specific knowledge and does no guessing: **every repo MUST have a QA config** at `profiles/<repo>.json` (gitignored, machine-local) before it can be QA'd. qa.sh hard-fails with `QA_CONFIG_MISSING` otherwise.

- **First time on a repo: author its config.** Read the repo's README/CONTRIBUTING/CLAUDE.md to learn the dev server and asset build, then write `profiles/<repo>.json` (see "Creating a per-repo config" below). This happens once, deliberately — never inferred at run time.
- **`profiles/<repo>.md`** (optional but encouraged) holds the human facts: why the boot is what it is, dev data caveats, scenario tips. Check it before writing scenarios.
- **Fresh worktree**: `~/.claude/skills/qa/setup-worktree.sh <worktree-path>` copies the main checkout's own gitignored files (minus universal junk: dependency installs, logs, caches, editor state) — repo-agnostic by construction. Then install dependencies; the config's `build` handles assets on each run.

### Creating a per-repo config

A per-repo config is two files named after the origin remote's repository name (`git remote get-url origin` basename, e.g. `dnsimple-app` for dnsimple/dnsimple-app):

- `profiles/<repo>.json` — REQUIRED. The machine config: boot + login. `chmod 600` it.

  ```json
  {
    "serve": "bin/vite build && exec bundle exec puma -C config/puma.rb -p \"$PORT\"",
    "variables": { "EMAIL": "dev-user@example.com", "PASSWORD": "…" },
    "extraCookies": { "some_interstitial_bypass": "1" },
    "macros": {
      "login": "visit /login\nfill input[type=email] with \"$EMAIL\"\nfill input[type=password] with \"$PASSWORD\"\nclick element form:has(input[type=password]) [type=submit]"
    }
  }
  ```

  `serve` is one flat shell command run via `sh -c` with `$PORT` exported — chain an asset build with `&&`, and `exec` the final server so it owns the process. `variables` are values steps reference as `$NAME` (credentials live here, never in scenarios). `macros` are named step lists (multi-line string or array) scenarios invoke with `run <name>`; the `login` macro is required for authenticated QA (auto-login executes it). Source the values from the repo's README/CONTRIBUTING/seeds — deliberately, once.

- `profiles/<repo>.md` — optional but encouraged human facts. Keep it facts-only (the engine's mechanics stay in this file), and never put the actual credentials in the markdown; they live only in the JSON.

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

## Related
Seed/provisioning caveats that bite QA (one line each).
```

Profiles are gitignored (machine-local, may reference private data). When a fact is durable and shareable, prefer fixing the repo's own README/CLAUDE.md and shrinking the profile.

## Failure modes

- `AUTH_FAILED` — stale cookie; re-save it (above).
- Selector timeout — the selector is wrong or the feature is broken. Read the frame for that step before deciding which.
- `NO_COOKIE` — no stored cookie for the host; save one or pass `--no-auth`.
- ffmpeg missing — `brew install ffmpeg`.
- Playwright missing — `cd ~/.claude/skills/qa && npm install && npx playwright install chromium`.
