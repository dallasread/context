---
name: pr-feedback-fixer
description: Fix high-confidence review feedback on the user's open PRs, reply with the commit, and resolve the thread. Report the rest to the user without replying. Unattended. Use on the scheduled run or when asked to address PR feedback.
---

Address unresolved review feedback on the user's open, non-draft pull requests. The user is the GitHub account `gh` is signed in as; `<me>` below is the login that `gh api user -q .login` prints. Fix what is clearly right to fix, reply with the commit, and resolve the thread. Defer everything else to the user: do not reply on GitHub, and put the thread in the report with a note that says why.

Every run starts from a blank slate. GitHub and `origin` are the only record of what is done. The activity log (see Output) is a report for the user, and a run never reads it to decide what to do. A run can stop at any point, for example when the network drops or the laptop sleeps, and the next run finishes the work.

## 0. Lock

- Run `~/.claude/skills/pr-feedback-fixer/lock.sh acquire`. If it exits non-zero, another run is still alive (it may be suspended). Stop at once and report "previous run still active". Do not remove the lock yourself.
- Run `~/.claude/skills/pr-feedback-fixer/lock.sh release` when you finish, and also when you stop early.

## 1. Find the threads

- List the PRs: `gh search prs --author @me --state open --draft=false --json repository,number,title,url --limit 100`.
- For each PR, read its review threads with GraphQL (`gh api graphql`): `repository(owner, name) { pullRequest(number) { headRefName reviewThreads(first: 100) { nodes { id isResolved isOutdated path line comments(first: 50) { nodes { author { login } body createdAt url } } } } } }`.
- Skip a thread when it is resolved.
- If the latest comment is by `<me>` and its body is exactly `🤖 says: Fixed in <sha>.` (or the older `Fixed in <sha>.`), an earlier run replied but did not resolve the thread. Resolve it with `resolveReviewThread`, and move on.
- Skip any other thread whose latest comment is by `<me>`. That comment means the user, or an earlier run, already answered.
- Act on comments from humans and from review bots, such as Copilot.
- Only review threads are in scope. Do not act on top-level PR comments or review summary bodies.

## 2. Classify each thread

Read the comment, the code at `path` on the PR's head branch, and the surrounding code. Then put the thread in exactly one group:

- Already fixed: a commit on `origin/<headRefName>` made after the latest comment's `createdAt` already makes the requested change. This happens when an earlier run pushed but stopped before it replied. Reply `🤖 says: Fixed in <short-sha>.` with that commit, and resolve the thread. Do not make a new commit.
- Question: the reviewer asks something, or the right change depends on the user's intent. Do not reply, and leave the thread open. Log it with a note that says what the question waits on.
- High confidence: the change is clearly correct, small, and contained, and it does not change the product's behavior beyond what the reviewer asked for. Typical cases are a real bug the reviewer points at, a missed convention from the repo's AGENTS.md or CLAUDE.md, a missing YARD tag, a typo, a missing test, or a lint issue. Fix it (step 3).
- Not high confidence: the suggestion is plausible, but there is something substantial to consider. Examples are a design trade-off, a behavior change, a wide refactor, a conflict with the repo's conventions, or a change you could not verify. Do not reply on GitHub, do not change code, and do not resolve the thread. Log it with a note that names the concern, so the user can decide from the report.

When unsure between "high confidence" and "not high confidence", choose "not high confidence".

## 3. Make the fixes, one PR at a time

### Worktree (one per repo, owned by this task)

- Find the local checkout: it is the git checkout under `$CODE_DIR` (default `~/apps`), at most three levels down, whose `origin` remote matches the PR's repository. Prefer the directory with the shortest name, such as `app` over `app-copy`.
- In that checkout, run `git fetch origin`. The worktree is `<checkout>/.claude/worktrees/pr-feedback`. Only this task uses it.
- If the worktree does not exist, create it with `git worktree add --detach <worktree> origin/<headRefName>`, then run `~/.claude/skills/util-qa/setup-worktree.sh <worktree>` once. That script copies the gitignored configs and clones `node_modules` from the checkout (an APFS clone, so it uses almost no disk) when the lockfile matches.
- Before each PR, reset the worktree to a blank slate: `git merge --abort` (ignore the error when no merge is in progress), `git reset --hard`, `git clean -fd`, then `git checkout --detach origin/<headRefName>`. This throws away anything an interrupted run left, including commits it never pushed. `git clean -fd` keeps the ignored files, so configs and `node_modules` stay.
- After each checkout, in `dnsimple/dnsimple-app`: if `package-lock.json` differs from the checkout's copy, or `node_modules` is missing, run `npm ci`. Never use yarn, and never symlink node_modules. Then run `RAILS_ENV=test bundle exec rails assets:precompile`.

### Identity and signing

Every commit must be signed. The worktree shares the checkout's git config, so it commits with the identity and signing key that the checkout already has. Never set or change `user.*` or signing config. Before the first commit in a repo, check that `git config user.email` and `git config user.signingkey` both have a value in the worktree. If either one is empty, skip that repo's fixes, and report "no commit identity in <checkout>".

Never pass `--no-gpg-sign`, `-c commit.gpgsign=false`, or anything else that turns signing off. After each commit, confirm `git cat-file -p HEAD` contains `gpgsig`. If the commit fails to sign, or it has no signature, stop the whole run and report "1Password locked or signing failed".

### Commit and push

- Follow the repo's AGENTS.md / CLAUDE.md conventions. Every code change has a test: write or update the test, and make it pass. When you commit, export `PGGSSENCMODE=disable`.
- Make one commit per thread, with a concise imperative subject. Do not reference issues or PRs in the message. Let the pre-commit hook run. Do not use `--no-verify`. If the hook fails and the fix is not obvious, drop that commit (`git reset --hard HEAD~1`), and move the thread to "not high confidence" with a note that says why.
- Push with `git push origin HEAD:refs/heads/<headRefName>`. Never force push, never rebase, and never push to any other branch. If the push is rejected because the branch moved, run `git merge origin/<headRefName>` (commit the merge with `--no-verify`; it is still signed), and push once more. If it still fails, stop work on that PR and report it. If the push fails because the SSH agent is locked (1Password), stop the whole run and report "1Password locked". Never fall back to HTTPS.
- Only after the push succeeds: reply on each fixed thread with `addPullRequestReviewThreadReply`. The body is only `🤖 says: Fixed in <short-sha>.`. Then resolve the thread with `resolveReviewThread`.

Every comment this task posts on GitHub starts with `🤖 says:`.

## Network failures

If a `gh` or `git` call fails because GitHub is unreachable (a timeout, or a DNS or connection error), retry it once after 30 seconds. If it fails again, release the lock, report "network down", and stop. Do not try to save progress. The next run resets the worktree and redoes or finishes the work from GitHub's state.

## Writing rules for notes

Use plain, short sentences in active voice. Do not use em dashes. Do not restate the comment. Say the concern, then stop.

## Output

Log each unresolved thread you classified, right after you act on it (after the reply, or after you decide not to reply). The report is the only place a deferred thread shows up, so never skip the log for one. A deferred thread stays unanswered on GitHub, so later runs classify it again and log it again; the report keeps only its latest state.

```
~/.claude/skills/pr-feedback-fixer/report.py add --thread <thread id> --repo <owner/name> --pr <number> --outcome <fixed|already_fixed|deferred|question|skipped> --title "<PR title>" --url <PR url> --comment-url <url of the latest comment you acted on> [--reply-url <url of your reply>] --path <path> --reviewer <latest comment author> [--sha <short sha>] --note "<one short sentence>"
```

The note says what changed, or why you did not reply: the concern that needs the user's decision, or what the question waits on. Pass `--reply-url` only when you posted a reply. Do not log threads you skip because the latest comment is by `<me>`.

Before you release the lock, run `~/.claude/skills/pr-feedback-fixer/report.py render`. It writes `~/.local/state/pr-feedback-fixer/report.html`, which has the latest state of each thread from the last 30 days, with filters.

Write one line per PR you touched: the repo and number, threads fixed (with short SHAs), threads deferred to the user (no reply), threads left as questions, and any PR you skipped with the reason. If nothing needed action, say "no new feedback".