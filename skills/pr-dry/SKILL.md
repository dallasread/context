---
name: pr-dry
description: Dry-run a pull request. Draft the PR title and description from the repo's PR template — taking over its QA section with a manual-verification walkthrough (a 👓 QA section) and the deploy sections — for the user to review. Nothing is created or pushed until explicitly asked. Use when asked to prep or dry-run a PR.
---

# pr-dry

Produce a ready-to-ship PR draft the user can read before anything touches GitHub. The dry run ends at a draft in chat; reviewing, creating the PR, pushing, and uploading evidence are separate, explicitly requested steps.

## Workflow

1. Use your memory — recall the relevant project memory (conventions, prior decisions, constraints) before drafting.
2. Ensure there are no related uncommitted items.
3. Use /util-review without QA and make the appropriate updates.
4. Draft the PR title and description using the repo's pull request template (`.github/pull_request_template.md`), completing every section — the review/qa block takes over the template's QA section (see below). Title carries no issue IDs — linkage goes in the body ("Fixes #1234" / "Belongs to #1234").
5. Show the draft and stop. Do not create the PR or push unless explicitly asked.

No QA run happen here.

## Description sections

- **Summary and trade-offs** — the body opens with at most two short paragraphs: what is wrong today, with the number that shows it, then what the change does. No mechanism tour. Follow with a `Trade-offs:` list whose bullets each lead with a bolded claim of three to six words and then one or two sentences, so the list scans on the bold alone. A bullet that needs a paragraph is either two bullets or belongs in the plan, not here. Omit the list when the change genuinely has no trade-offs rather than padding it.
- **👓 QA** — a manual-verification walkthrough takes over the PR template's QA section. When the template has a QA section, replace it wholesale — heading and body both — with this section; when the template has no QA section, add this one (whenever the change has a visible surface; omit entirely for pure backend/refactor/docs). The section is `## 👓 QA`: a lead line naming the start command (check the README, e.g. `bin/dev`) and the local base URL, then one bullet per page giving its local URL and what to check there by hand. Name any residual gap manual checking cannot cover (sandbox-only flows, request-spec-only coverage) here too.
- **Verification** — remote URLs, with the two deploy checkboxes:
  - [ ] sandbox: Verify a successful deploy
  - [ ] production: Verify a successful deploy
- **Deployment PRE/POST tasks** — the string "N / A" without a checkbox or list, unless there is a script to run (data migration scripts and feature-flag removals get the POST snippet and per-environment sub-checkboxes).

## Finishing touches

- Label the PR per the repo's convention (dnsimple-app uses `bug` or `enhancement`).
- Assign it.
