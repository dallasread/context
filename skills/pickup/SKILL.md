---
name: pickup
description: Picks up a ticket or feature description and drives it to implementation — plan and agree the entrypoint, preconditions, and side-effects first, then create a worktree off a fresh main to build in. Use when handed a ticket or a description of a thing to build.
---

Take the ticket or description of the thing to implement. If it needs a ticket, issue templates live in the repo's `.github/ISSUE_TEMPLATE` — check there.

Plan first. Ask how the user would like it implemented in the existing project, and include suggestions.

Most importantly, agree on the entrypoint, preconditions, and side-effects — and where the side-effects and preconditions need to take place.

Only after that agreement, create a new worktree off a fresh main to work on the implementation.

DO NOT COMMIT, STAGE, OR PUSH UNTIL ASKED. IF YOU CAN'T FIND RELATED PROJECTS OR ISSUES, ASK CLARIFYING QUESTIONS.
