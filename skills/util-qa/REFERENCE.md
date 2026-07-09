# util-qa reference — onboarding a repo

Cold-path detail lifted out of `SKILL.md` so the per-run hot path stays small. You only need this file the first time you QA a repo, or when a run stops with `QA_CONFIG_MISSING`. A repo that already has a `profiles/<repo>.json` never needs anything here.

## Booting any repo

This skill's engine carries no repo-specific knowledge and does no guessing: **every repo MUST have a QA config** at `profiles/<repo>.json` (gitignored, machine-local) before it can be QA'd. qa.sh hard-fails with `QA_CONFIG_MISSING` otherwise.

- **First time on a repo: author its config.** Read the repo's README/CONTRIBUTING/CLAUDE.md to learn the dev server and asset build, then write `profiles/<repo>.json` (see "Creating a per-repo config" below). This happens once, deliberately — never inferred at run time.
- **`profiles/<repo>.md`** (optional but encouraged) holds the human facts: why the boot is what it is, dev data caveats, scenario tips. Check it before writing scenarios.
- **Fresh worktree**: `~/.claude/skills/util-qa/setup-worktree.sh <worktree-path>` copies the main checkout's own gitignored files (minus universal junk: dependency installs, logs, caches, editor state) — repo-agnostic by construction. Then install dependencies; the config's `build` handles assets on each run.

### Creating a per-repo config

A per-repo config is two files named after the origin remote's repository name (`git remote get-url origin` basename, e.g. `app` for my/app):

- `profiles/<repo>.json` — REQUIRED. The machine config: boot + login. `chmod 600` it.

  ```json
  {
    "serve": "bin/vite build && exec bundle exec puma -C config/puma.rb -p \"$PORT\"",
    "variables": { "EMAIL": "dev-user@example.com", "PASSWORD": "…" },
    "extraCookies": { "some_interstitial_bypass": "1" },
    "badge": { "running": "<repo>.running.svg", "pass": "<repo>.pass.svg", "fail": "<repo>.fail.svg" },
    "macros": {
      "login": "visit /login\nfill input[type=email] with \"$EMAIL\"\nfill input[type=password] with \"$PASSWORD\"\nclick element form:has(input[type=password]) [type=submit]"
    }
  }
  ```

  `serve` is one flat shell command run via `sh -c` with `$PORT` exported — chain an asset build with `&&`, and `exec` the final server so it owns the process. `variables` are values steps reference as `$NAME` (credentials live here, never in scenarios). `macros` are named step lists (multi-line string or array) scenarios invoke with `run <name>`; the `login` macro is required for authenticated QA (auto-login executes it). Source the values from the repo's README/CONTRIBUTING/seeds — deliberately, once.

  `badge` is OPTIONAL branding: the little corner SVG on the video, mapped by outcome state to a file resolved against `profiles/` (an absolute path also works). Keys match the caption states — `running` (a checkpoint in progress), `pass`, `fail` — and the map is open, so any future state is branded by adding its key. Each state is independent; omit one and that outcome shows no badge. Omit `badge` entirely and the run shows no corner art at all — the engine carries no default mascot. Supply distinct art per state (they are swapped, not recolored); state the art's provenance/licensing in `<repo>.md`.

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

## Related
Seed/provisioning caveats that bite QA (one line each).
```

Profiles are gitignored (machine-local, may reference private data). When a fact is durable and shareable, prefer fixing the repo's own README/CLAUDE.md and shrinking the profile.
