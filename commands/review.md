# Pull Request Review

Let's review this pull request.

First, let's check out the branch.

Then work through the template sections below (General, Development, UI and UX, Marketing) and output them first.

After the template sections, at the very end, add a short summary: a maximum of four terse points in ELI5, prioritized by their importance — we do not want to spam the builder. Be absolutely clear on what any potential issues are and provide examples. Then, suggest a refactoring that would help make this cleaner.

We MUST perform a live QA by default: run the /qa skill (~/.claude/skills/qa/SKILL.md). It owns the whole procedure — booting the branch app, deriving the scenario from the diff, captioned video + frame evidence, and reviewing it. "The tests pass" / "the rendered HTML looks right" is NOT a substitute; the ONLY acceptable reason to skip is that the app genuinely cannot be booted here, and then you MUST say so explicitly and state what you did instead.

FINALLY, ASK IF I WANT TO POST A COMMENT TO THE PULL REQUEST.

## General

Let's review this pull request holistically.

- What are the differences? Expand all changes
- Which files, methods, or classes could be renamed for clarity?
- Which statements are overloaded?
- Are there removed files/methods that are still linked?
- Could it be implemented in smaller increments, closer to master?
- Which patterns used are incorrect?
- What documentation is missing?
- What is a better way to implement this?
- Are there concerns with any of the quick returns?
- Are methods returning the correct thing?
- What will this change break?
- What will this change effect?
- Are there tests in place?
- Are there any pre/post tasks missing?
- Do we enforce this requirement server-side?
- Are there any other places we could apply these changes?

## Development

Let's review this pull request in terms of clean code, reusability, and observability.

- [ ] Should we be tracking this?
- [ ] It makes sense to do this.
- [ ] All code changes are in scope.
- [ ] Tests are complete and passing.
- [ ] Documentation is complete.
- [ ] Successfully completed QA scenarios.
- [ ] Registrar interactions MUST rescue common network exceptions
- [ ] Third-party interaction MUST deal with network errors
- [ ] Is this against the Rails way?

## UI and UX

If this Paul request is facing how customers interact with the system, then we need to review this from the standpoint of user interface and user experience.

- Does it look good with other lengths of data?
- Is form pre-filled if it has errors?
- Should i18n be used, is it correct?
- Is grammar and punctuation correct?
- Are links and important data correct?
- Are form fields required?
- Does it mobile?

## Marketing

If this pull request is facing customers, that we need to review this from the perspective of potential confusion, conversion, and how it fits into the overall system.

- [ ] Addresses the root cause.
- [ ] Does the page content tell our story?
- [ ] Is it clear what happens *after* this page?
- [ ] Spelling and Grammar are correct.
- [ ] CTAs are present.
- [ ] Successfully rendered and tested.

## Template

Use this template:

```
## General

- What are the differences? Expand all changes
- Which files, methods, or classes could be renamed for clarity?
- Which statements are overloaded?
- Are there removed files/methods that are still linked?
- Could it be implemented in smaller increments, closer to master?
- Which patterns used are incorrect?
- What documentation is missing?
- What is a better way to implement this?
- Are there concerns with any of the quick returns?
- Are methods returning the correct thing?
- What will this change break?
- What will this change effect?
- Are there tests in place?
- Are there any pre/post tasks missing?
- Do we enforce this requirement server-side?
- Do we enforce this requirement client-side?
- Are there any other places we could or should apply these changes?

## Development

Let's review this pull request in terms of clean code, reusability, and observability.

- [ ] Should we be tracking this in events or anlytics?
- [ ] Does it makes sense to do this?
- [ ] Are all code changes in scope?
- [ ] Are tests are complete and passing?
- [ ] Is documentation accurate and complete?
- [ ] Do all QA scenarios complete successfully?
- [ ] Are we rescuing common network exceptions during third-party requests?

## UI and UX

If this pull request changes how customers interact with our system, then we need to review this from the standpoint of user interface and user experience.

- Does it look good with other lengths of data?
- Is form pre-filled if it has errors?
- Should i18n be used, is it correct?
- Is grammar and punctuation correct?
- Are links and important data correct?
- Are form fields required?
- Does it perform well on mobile?

## Marketing

If this pull request is facing customers, that we need to review this from the perspective of potential confusion, conversion, and how it fits into the overall system.

- [ ] Does it address the root cause?
- [ ] Does the page content tell our story?
- [ ] Is it clear what happens *after* this page in terms of conversion?
- [ ] Are spelling and grammar correct?
- [ ] Are CTAs present?
- [ ] Does it render successfully?
```
