# Skills index

A map of the skills in this directory: what each one is for, and how they hand
work to each other. It names skills and their contracts only. For how any one
skill actually works, read that skill's own `SKILL.md` (this index never
duplicates or reaches into a skill's internals).

## Two tiers

- **Entry points** you invoke directly (`pickup`, `review-dry`, `pr-dry`).
- **`util-*` helpers** that exist to serve the entry points; you rarely invoke them alone.

One owner per capability: exactly one skill knows how to do a given thing, and
everyone else defers to it by name. So there is a single uploader, a single QA
runner, a single formatter, and so on.

## Entry points

| Skill | Hand it | You get back |
|---|---|---|
| **pickup** | a ticket or a description of a thing to build | a plan (entry point, preconditions, side effects) agreed with you, then an implementation in a fresh worktree |
| **review-dry** | a branch or PR to review | the review formatted for GitHub and put in front of you as a **draft** you read before anything is posted; posting, and the uploads it needs, happen only when you ask |
| **pr-dry** | a branch to ship | a runnable PR title and description drafted from the repo's template, with the QA evidence folded in; nothing is created, pushed, or uploaded until you ask |

## Helpers

| Skill | Hand it | You get back |
|---|---|---|
| **util-review** | a branch to review, and whether QA may run | the review itself: verdict, sections, findings anchored to lines, and the QA evidence. Owns the lenses, the scenario authoring and the findings. It formats nothing and publishes nothing. |
| **review-dev** | a review result and a drafts directory | that review written as a JSON draft the reviewer app reads. The other formatter, and the only place the draft file's shape lives. |
| **util-review-queue** | nothing, or a pull request to check out | which pull requests are waiting on you and have no draft yet, and one of them checked out in a throwaway worktree. Never clones and never touches a working tree. |
| **util-qa** | a complete browser scenario to run | an evidence directory (pass/fail verdict, video, per-step frames). A pure **runner**: it never authors, repairs, re-seeds, hunts for bugs, or posts. It needs a one-time per-repo setup before it can boot a given app. |
| **util-gh-upload** | evidence files and a target PR | those files published to GitHub as hosted URLs. The **only** uploader; it confirms with you immediately before every publish. |
| **util-cqrs-js** | a CQRS / Event Sourcing question (Vue / JS) | reference knowledge, not tooling |
| **util-cqrs-ruby** | a CQRS / Event Sourcing question (Ruby / Rails) | reference knowledge, not tooling |

## How the review pipeline hands off

The QA and review skills chain through contracts, never by peeking inside one
another:

```
                    util-review ─ authors a scenario ─► util-qa ─ evidence dir ─┐
                   (the reviewing)                    (boots + drives)          │
                          ▲                                                     │
                          └────────── reads the frames into findings ───────────┘
                          │
                          └─► a review result: verdict, sections, findings
                                       │
                    ┌──────────────────┴──────────────────┐
                    ▼                                     ▼
               review-dry                            review-dev
         (formats for GitHub)                (formats for the reviewer app)
                    │                                     │
        shows you the draft; pr-dry               writes a JSON draft file
        folds the same block into a PR            the app picks up
                    │
        if you approve posting ──► util-gh-upload publishes the evidence
```

The split is deliberate: deciding *what* to test, reading the frames for bugs,
and writing the verdict are judgement, and stay with util-review. How any of it
reads is a separate job again, and belongs to the formatters. Booting
the app, driving the browser, recording, and verifying are deterministic and
belong to the runner. That boundary is why an authored scenario can be re-run
later with no model in the loop.

## Conventions

- **`SKILL.md` is each skill's read-me.** There is no second per-skill README; a
  skill's overflow detail lives in its own load-on-demand reference file, owned
  by that skill.
- **Encapsulation.** A skill (and this index) refers to another by name and by
  contract only, never by its files, flags, or internals. Change a skill's
  insides freely; its contract is the promise.
- **`*-dry` skills end at a draft you read.** Nothing is posted, created,
  pushed, or uploaded until you explicitly ask, and publishing confirms again at
  the moment it happens.
- **Private by default.** Publishing a skill is a deliberate, separate act.
