---
name: pr-dry
description: Dry-run a pull request. Run the review-dry skill over the branch (four lenses + mandatory live QA), then draft the PR title and description from the repo's PR template — QA section, 👓 Preview rendered from the QA evidence, deploy sections — for the user to review. Nothing is created, pushed, or uploaded until explicitly asked. Use when asked to prep or dry-run a PR.
---

# pr-dry

Produce a ready-to-ship PR draft the user can read before anything touches GitHub. The dry run ends at a draft in chat; creating the PR, pushing, and uploading evidence are separate, explicitly requested steps.

## Workflow

1. Use your memory.
2. Ensure there are no related uncommitted items.
3. Run the **review-dry** skill over the branch — the four lenses plus its mandatory live QA. Fix or surface what it finds before drafting. Skip its comment draft (the PR description below is this skill's deliverable), but keep its QA evidence dir: the 👓 Preview section renders from it.
4. Draft the PR title and description using the repo's pull request template (`.github/pull_request_template.md`), completing every section. Title carries no issue IDs — linkage goes in the body ("Fixes #1234" / "Belongs to #1234").
5. Show the draft and stop. Do not create the PR, push, or upload anything unless explicitly asked.

## Description sections

- **QA** — keep it short: one "Specs cover…" line plus a short manual-verification walkthrough. Instructions include server start (check the README) and use local URLs.
- **👓 Preview** — goes ABOVE the QA section. Include it when the change has a visible UI effect; omit it entirely when there's no visible surface (pure backend/refactor/docs). It uses the SAME canonical QA template as review-dry comments, rendered by the **review-dry** skill's formatter from the evidence dir the review-dry run produced (or a direct util-qa run) — never hand-written. Render it as that skill documents, with this section's `## 👓 Preview` heading (video style by default; frame-by-frame only when the user asks). At most one authored line may follow the block, naming a residual gap the run could not cover. In the dry draft, render with local evidence paths. When the user asks to actually create the PR, publish the evidence with the **util-gh-upload** skill (create the PR first so there's a page to attach to), re-render the Preview with the hosted URLs, and follow its consent rule.
- **Verification** — remote URLs, with the two deploy checkboxes:
  - [ ] sandbox: Verify a successful deploy
  - [ ] production: Verify a successful deploy
- **Deployment PRE/POST tasks** — the string "N / A" without a checkbox or list, unless there is a script to run (data migration scripts and feature-flag removals get the POST snippet and per-environment sub-checkboxes).

## Finishing touches

- Label the PR: every dnsimple-app PR carries `bug` or `enhancement`.
- Assign it.
