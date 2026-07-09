---
name: util-gh-upload
description: Upload files (QA videos, frames, images) to GitHub as user-attachments assets by driving a logged-in browser profile, printing the hosted URLs. Uploading PUBLISHES the files, so the user must confirm immediately before it runs, every time. Used by the review-dry and pr-dry skills to publish QA evidence; not a general file host.
---

# util-gh-upload

The one place that knows how to publish evidence files to GitHub. GitHub has no API for user-attachments uploads, so `post.js` drives a PR page's comment box in a real logged-in Chromium profile (`gh-profile/`, created by `--login`; machine-local state, never committed). It ONLY uploads and prints URLs — posting comments or editing PRs is done by the caller with `gh` afterwards.

**The consent rule — uploading already publishes.** Files land on GitHub-hosted user-attachments URLs the moment the upload runs, before any comment exists. Confirm with the user immediately before running `post.js`, every single time, no standing consent — even when they already asked you to post the thing the upload is for.

## Usage

```
# one-time interactive login (headed browser, including 2FA)
node ~/.claude/skills/util-gh-upload/post.js --login

# upload files against an existing PR (one browser session).
# --json prints a basename -> URL map; a single file without --json prints the bare URL.
node ~/.claude/skills/util-gh-upload/post.js <file…> --repo <owner/repo> --pr <N> --json
```

Uploads need an existing PR page to attach to — for a not-yet-created PR (pr-dry), create the PR first, then upload, then edit the description with the hosted URLs.

## Failure modes

- `NOT_LOGGED_IN` — ask the user to run the `--login` command above (real browser, 2FA). Never fabricate cookie values.
- Upload failure — a GitHub DOM change breaks it loudly; fall back to giving the user the local file paths for manual drag-drop.
- Module resolution — this skill has no npm footprint; it depends on the **util-qa** skill's Playwright setup. If Playwright cannot be resolved, run the util-qa skill once to provision it.

## Callers

- **review-dry** — uploads the frames and video its posted comment needs.
- **pr-dry** — uploads 👓 QA evidence once the PR exists.
- **util-qa** — never uploads; it stops at the evidence dir.
