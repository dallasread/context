---
name: pr-dry
description: Dry-run a pull request. Run the util-review skill over the branch (four lenses + live QA scaled to the change), then draft the PR title and description from the repo's PR template — taking over its QA section with the review/qa evidence block plus a manual-verification walkthrough below the video (a 👓 QA section), and the deploy sections — for the user to review. Nothing is created, pushed, or uploaded until explicitly asked. Use when asked to prep or dry-run a PR.
---

# pr-dry

Produce a ready-to-ship PR draft the user can read before anything touches GitHub. The dry run ends at a draft in chat; creating the PR, pushing, and uploading evidence are separate, explicitly requested steps.

## Workflow

1. Use your memory — recall the relevant project memory (conventions, prior decisions, constraints) before drafting.
2. Ensure there are no related uncommitted items.
3. Run the **util-review** skill over the branch — the four lenses plus its live QA, which it scales to the change (a diff with no observable surface gets no browser run). Fix or surface what it finds before drafting. Skip the comment (the PR description below is this skill's deliverable), but keep its QA evidence dir: the 👓 QA section renders from it.
4. Draft the PR title and description using the repo's pull request template (`.github/pull_request_template.md`), completing every section — the review/qa block takes over the template's QA section (see below). Title carries no issue IDs — linkage goes in the body ("Fixes #1234" / "Belongs to #1234").
5. Show the draft and stop. Do not create the PR, push, or upload anything unless explicitly asked.

## Description sections

- **👓 QA** — the review/qa evidence block takes over the PR template's QA section. When the template has a QA section, replace it wholesale — heading and body both — with this section; when the template has no QA section, add this one (whenever the change has a visible surface; omit entirely for pure backend/refactor/docs). The section is `## 👓 QA`, and it has two parts:
  - **The evidence block, on top** — the review-dry QA block verbatim: hand the evidence dir (the one the util-review run produced, or a direct util-qa run) to the **review-dry** skill and ask it for the `## 👓 QA` section; it renders the same block a review comment uses (video style by default, frame-by-frame on request). Never hand-written, so it reads identically to a review comment's QA block.
  - **A manual-verification walkthrough, below the video** — a lead line naming the start command (check the README, e.g. `bin/dev`) and the local base URL, then one bullet per page giving its local URL and what to check there by hand. Name any residual gap the run could not cover (sandbox-only flows, request-spec-only coverage) here too. Because util-qa persists the authored scenario with the evidence, this same QA can be replayed later with no model in the loop — a model-free re-verification of the PR's evidence.

  In the dry draft, render the evidence block with local evidence paths. When the user asks to actually create the PR, publish the evidence with the **util-gh-upload** skill (create the PR first so there's a page to attach to), re-render the block with the hosted URLs, and follow its consent rule.
- **Verification** — remote URLs, with the two deploy checkboxes:
  - [ ] sandbox: Verify a successful deploy
  - [ ] production: Verify a successful deploy
- **Deployment PRE/POST tasks** — the string "N / A" without a checkbox or list, unless there is a script to run (data migration scripts and feature-flag removals get the POST snippet and per-environment sub-checkboxes).

## Finishing touches

- Label the PR per the repo's convention (dnsimple-app uses `bug` or `enhancement`).
- Assign it.
