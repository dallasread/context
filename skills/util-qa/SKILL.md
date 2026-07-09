---
name: util-qa
description: Run a scripted browser scenario against the booted app and record a video plus per-step screenshots as evidence, reporting a pass/fail verdict. A RUNNER, not an author: it executes exactly the scenario it is handed (a .spec.js module) and never invents, repairs, waits-pads, re-seeds, or extends steps. Deciding what to test and reviewing the frames for bugs belong to the caller (the review-dry skill). Assertions (`expect` steps) make the run pass/fail — a green run is proof, not vibes.
---

# util-qa

Scripted browser QA with video evidence. **You are a runner, not an author.** You are handed a **complete** scenario (a `.spec.js` module), you boot the app, run it **verbatim**, and report the results — the verdict, which checkpoints passed or failed, and the evidence paths. Deciding *what* to test (the flows, the checkpoints, the regression cases), authoring the selectors, and reviewing the frames for bugs are the **caller's** job — the review-dry skill. None of that is yours. (How a scenario is written lives in [REFERENCE.md](REFERENCE.md); you do not need it to run one you were handed.)

**Run only what you were handed. Change nothing.** Never add, drop, reorder, or reinterpret a step or checkpoint; never insert a `wait`, re-seed or re-clean data, or re-run with tweaks on your own initiative. If the scenario will not run cleanly — a selector misses, a step needs a wait, the timing is off — that is the **author's** to fix, not yours: report the failing step and its frame, and stop. Do not "repair" the script, and never paper over a real failure to manufacture a green run. A faithful red run is the correct output; a doctored green one is a lie.

## Run it

1. **Prepare the app**: provision the worktree and build assets (fresh-worktree setup is in [REFERENCE.md](REFERENCE.md)). Do NOT boot the server yourself — qa.sh owns the server lifecycle. The caller hands you a complete scenario file; you do not write it, extend it, derive it, or fill anything in. If no runnable scenario was provided, that is a missing input — say so and stop, don't invent one.

2. **Run the scenario verbatim, from the app directory:**

   ```
   ~/.claude/skills/util-qa/qa.sh <evidence-dir>/scenario.spec.js <evidence-dir>
   ```

   qa.sh picks a free port, runs the repo's configured `serve` command, waits for readiness, runs the scenario, and (by default) kills the server on exit — pass, fail, error, or interrupt. There is NO stack detection: the boot comes from the repo's REQUIRED QA config (`profiles/<repo>.json`), and a repo without one fails with `QA_CONFIG_MISSING` — onboarding a repo is a once-per-repo task in [REFERENCE.md](REFERENCE.md). A command after `--` explicitly overrides `serve` for one-off runs; commands run with `$PORT` exported. Server (and any chained build) output lands in `<evidence-dir>/server.log`. To run against an already-running server instead: `node ~/.claude/skills/util-qa/run.js <scenario.spec.js> --out <dir> --base <url> --repo <name>`.

   **Iterating? Keep the server warm.** A fresh boot rebuilds assets and boots the framework every run (tens of seconds). For repeated runs against the same worktree, add `--keep`: the server is left running and recorded, and later runs REUSE it — skipping the whole boot, so they start in well under a second and the only cost is the scenario itself. Reuse serves the assets the server booted with; framework dev-reload still picks up backend/view edits live, but a **JS/CSS source** change needs `--fresh` (stop, rebuild, reboot). `--stop` tears this worktree's warm server down. State is keyed by the git worktree root, so warm servers across parallel worktrees each get their own port and never collide.

   ```
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --keep    # boot once, leave warm
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --keep    # again → reuses, ~instant
   ~/.claude/skills/util-qa/qa.sh <dir>/scenario.spec.js <dir> --fresh   # rebuild assets + reboot (frontend changed)
   ~/.claude/skills/util-qa/qa.sh --stop                            # done — kill the warm server
   ```

   Evidence dir convention: `<project>/tmp/qa/<branch-name>/` (gitignored). The runner copies the scenario there, records `qa.mp4`, saves `frames/NN-<action>.png` after every step, and writes `steps.json` with the PASS/FAIL verdict. Exit 0 = all steps passed.

   **The saved scenario replays with no model.** The scenario the reviewer authored persists in that evidence dir and is faithful (credentials are referenced through `vars`, never embedded), so a plain re-run against the saved copy — `qa.sh <evidence-dir>/scenario.spec.js <evidence-dir>` — reproduces the exact QA with no authoring step or model in the loop; a human or a cron can run it.

3. **Report the results.** State the verdict (PASS/FAIL), the per-checkpoint ✓/✗ checklist the run printed, and the evidence paths — **always surface the local `qa.mp4` path** (the primary evidence a human watches) plus the frames dir and evidence dir. Hand the evidence dir (`steps.json`, `qa.mp4`, `frames/`) to the caller and stop. You do **not** review the frames for bugs, author a `findings.json`, judge whether a passing frame "looks right", format a PR comment, or upload anything — reviewing the evidence for defects is the caller's job (the **review-dry** skill), and uploading is **util-gh-upload**'s. Report the run faithfully: if a step failed, say so with its frame; never soften a red run into a green one.

## Authoring a scenario, and onboarding a repo → REFERENCE.md

Both are off the runner's per-run hot path, in [REFERENCE.md](REFERENCE.md):

- **Authoring** — writing the `.spec.js` (the harness, the verb vocabulary and its exact matching semantics, checkpoints, `vars`, and the evidence engine) is the caller's job, not the runner's.
- **Onboarding** — standing up a new repo's `profiles/<repo>.json` is a once-per-repo task; a run stops with `QA_CONFIG_MISSING` when it is absent.

**Auth is automatic.** On a stale or missing session the runner logs in through the app's real form via the repo's `login` macro, persists the session, and retries — no manual step. Use `--no-auth` for logged-out flows (login page, marketing pages). The macro schema, the manual cookie fallback, and the one sanctioned dev-data exception live in REFERENCE.

## Posting evidence to GitHub

Not QA's job. Formatting the evidence into a PR comment is the **review-dry** skill's job; uploading it is the **util-gh-upload** skill's. QA produces the evidence dir and stops. If you are running QA standalone and want to post, follow those two skills — and, as always, ask the user before uploading or posting, every single time.

## Maintaining the runner

**Environment quirks are encoded, never re-derived per run.** When the runner must assume something about the host — the app's package `type`, an available binary, a path convention, the scenario's module shape — that assumption lives in code with a boundary test in `test/`, never as a per-run "here's the workaround" note the caller rediscovers each time. A recurring note of that kind is a bug: encode it and add the test. The ESM `.cjs` loader (`requireScenario`, guarded by the `type:module` case in `test/js-scenario.test.sh`) is the template; the other host seams — a non-JS scenario path, a scenario that doesn't export a function, a repo with no profile — are pinned in `test/boundary.test.sh`.

## Failure modes

- `AUTH_FAILED` — stale cookie; re-save it (see REFERENCE's Auth section).
- `QA_CONFIG_MISSING` — the repo has no `profiles/<repo>.json`; onboard it (REFERENCE).
- Selector timeout — the selector is wrong or the feature is broken. Read the frame for that step before deciding which.
- `NO_COOKIE` — no stored cookie for the host; save one or pass `--no-auth`.
- ffmpeg missing — `brew install ffmpeg`.
- Playwright missing — qa.sh self-heals this on every run: it preflight-installs the `playwright` npm package and the chromium browser binary (two SEPARATE installs, both living in `~/.claude/skills/util-qa`) before booting. You should not need to install anything by hand. Only if that auto-install itself fails (`PLAYWRIGHT_NPM_INSTALL_FAILED` / `PLAYWRIGHT_BROWSER_INSTALL_FAILED`) run it manually: `cd ~/.claude/skills/util-qa && npm install && npx playwright install chromium`. Do NOT install Playwright into the app worktree — the runner resolves it from the skill dir, not the app.
