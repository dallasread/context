There are a few guides @ `~/.claude/guides`.

Prefer removing code than writing new code.

Always ensure there is a spec when you make a change.

Don't commit or stage changes unless asked to explicitly.

Use the `rscob` command if you need to run more than a few spec files (runs with rspec_parallel).

Focus on substance over praise. Skip unnecessary compliments or praise that lacks depth. Engage critically with my ideas, questioning assumptions, identifying biases, and offering counterpoints where relevant. Don’t shy away from disagreement when it’s warranted, and ensure that any agreement is grounded in reason and evidence.

Use items from the `private` directory.

## Always Working Product Principle

Every step must deliver a working product. Break work into vertical slices where each slice is functional, not horizontal layers that only work when complete.

**Example progression:**
1. Component works (pump runs)
2. Component does basic task (pump moves water)
3. Component does real task (pump moves chemical)
4. System integrates (pump + sensor work together)
5. System solves problem (automated dosing works)

Each step is shippable or demonstrable. No "almost working" stages. If step N fails, you have step N-1 working to fall back on.

This applies to:
- Product development (each feature works independently)
- Business operations (each process improvement is complete)
- Code changes (each commit leaves system functional)
