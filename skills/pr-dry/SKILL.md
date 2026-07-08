---
name: pr-dry
description: Dry-run a pull request. Tidy the branch, run /simplify and /code-review, then draft the PR title and description from the repo's PR template — QA section, 👓 Preview evidence via the util-qa skill, deploy sections — for the user to review. Nothing is created, pushed, or uploaded until explicitly asked. Use when asked to prep or dry-run a PR.
---

# pr-dry

Produce a ready-to-ship PR draft the user can read before anything touches GitHub. The dry run ends at a draft in chat; creating the PR, pushing, and uploading evidence are separate, explicitly requested steps.

## Workflow

1. Use your memory.
2. Ensure there are no related uncommitted items.
3. Run /simplify.
4. Run /code-review.
5. Draft the PR title and description using the repo's pull request template (`.github/pull_request_template.md`), completing every section. Title carries no issue IDs — linkage goes in the body ("Fixes #1234" / "Belongs to #1234").
6. Show the draft and stop. Do not create the PR, push, or upload anything unless explicitly asked.

## Description sections

- **QA** — keep it short: one "Specs cover…" line plus a short manual-verification walkthrough. Instructions include server start (check the README) and use local URLs.
- **👓 Preview** — goes ABOVE the QA section. Include it when the change has a visible UI effect; omit it entirely when there's no visible surface (pure backend/refactor/docs). Produce the evidence with the util-qa skill (`~/.claude/skills/util-qa/SKILL.md`): it boots the app, runs a scripted scenario, and hands back an evidence dir (`qa.mp4`, `frames/`, `steps.json`, `findings.json`). In the dry draft, reference the local evidence paths. Uploading is NOT the util-qa skill's job — when the user asks to actually create the PR, publish the evidence with the **util-gh-upload skill** (`~/.claude/skills/util-gh-upload/SKILL.md`: create the PR first so there's a page to attach to, upload, swap in the hosted URLs) and follow its consent rule.
- **Verification** — remote URLs, with the two deploy checkboxes:
  - [ ] sandbox: Verify a successful deploy
  - [ ] production: Verify a successful deploy
- **Deployment PRE/POST tasks** — the string "N / A" without a checkbox or list, unless there is a script to run (data migration scripts and feature-flag removals get the POST snippet and per-environment sub-checkboxes).

## Finishing touches

- Label the PR: every dnsimple-app PR carries `bug` or `enhancement`.
- Assign it.
