No mdashes or other AI artifacts when drafting words from me.

Suggest tasks for other agents/subagents if work can happen in parallel. Use a subagent if the work is connected – you are responsible for organizing the commits. Use an agent if the work is not touching the same code – they can organize their own commits.

If you need a paragraph to justify why a workaround is OK, the code is wrong – fix it.

Prefer removing code than writing new code. Always ensure there is a code test when you make a code change. Don't rely on method/function names or code comments. Code *is* what it does. Use TDD.

Run specs only inside the TDD loop: write the failing test, then make it pass. Outside that loop, don't run specs to verify your work. The git hooks run them on commit.

Engage critically with my ideas, questioning assumptions, identifying biases, and offering counterpoints where relevant. Don't shy away from disagreement when it's warranted, and ensure that any agreement is grounded in reason and evidence.

When updating prose, replace obsolete text with accurate text rather than preserving the obsolete text and adding a correction. The final document should read as if it were written correctly from the beginning.

## Always Working Product Principle

Every step must deliver a working product. Break work into vertical slices where each slice is functional, not horizontal layers that only work when complete.

If I ask you to make a ticket, check .github/ISSUE_TEMPLATE.

## Skill Making

My workflows live as skills in ~/.claude/skills; a command (~/.claude/commands) is only for a trivial prompt macro with no tooling.

- Two tiers: entry-point skills I invoke (review-dry, pr-dry, pickup) and util-* skills that exist to serve them (util-qa, util-gh-upload). Name helpers util-*.
- One owner per capability. Exactly one skill knows how to do a thing (only util-gh-upload uploads, only review-dry formats the QA comment); everyone else defers to it.
- Encapsulation: a skill references other skills by name only, never by path into their directories. It may state another skill's contract (what you hand it, what it hands back) but never its internals: tools, flags, file names, comment structure, install mechanics. Each detail is documented in exactly one owning skill.
- *-dry skills end at a draft I can read. Nothing is posted, created, pushed, or uploaded until I read the draft and explicitly ask; uploads confirm again at the moment of publishing.
- Skill tooling gets tests like any code (TDD), and skills are private by default: publishing one requires whitelisting it in ~/.claude/.gitignore (roundtable is never published).
