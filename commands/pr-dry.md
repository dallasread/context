0. Use your memory.
1. Ensure there are no related uncommitted items
3. /simplify
4. /codereview
2. Show me a PR title/description using the related pull request template. QA instructions should include server start (check readme) and be local URLs. Verification instructions should be remote URLs.
3. Verification is: 
  - [ ] sandbox: Verify a successful deploy
  - [ ] production: Verify a successful deploy 
4. POST/PRE is the string of "N / A" without a checkbox or list unless there is a script to run
5. When the change has a visible UI effect, add a "## 👓 Preview" section: run the /qa skill (~/.claude/skills/qa/SKILL.md) and embed its evidence (video and/or frames; the skill also handles the GitHub upload — always ask first). Omit the section entirely when there's no visible surface (pure backend/refactor/docs).
6. Don't forget to label and assign.
