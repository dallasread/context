---
name: review-dry
description: Dry pull request review for GitHub — the deliverable is a DRAFT comment, never a post. Controls the formatting of a /util-review. Posting, and the uploads it needs, happen only after you read the draft and explicitly ask. Use when asked to review a PR or branch.
---

# review-dry

**You format a review for GitHub and show it to the user before anything is sent.** The reviewing itself belongs to the **util-review** skill; how it reads on GitHub belongs here. The counterpart is **dev-review**, which formats the same review for the reviewer app.

The draft is the deliverable. A review that gets posted without the user reading it first has failed at the one thing this skill exists for.

## Workflow

1. **Run the util-review skill over the branch**, in its plan-confirming mode: it presents its QA plan and waits for a go-ahead before booting anything. Do not re-review, re-order, or second-guess what it hands back.

2. **Format it as the comment below**, and show the user two things: the review's sections, as their working view of what was found, and the drafted comment. Also surface the local `qa.mp4` path in chat — the draft carries no video until something is uploaded, so the recording is only reachable if you name its path.

   Then stop. A draft publishes nothing: no uploads, no `gh`, no browser.

3. **Post only on explicit request**, via the flow at the end.

## The comment

One line of lead, then the QA section. Findings are not in here: they are posted as inline comments on their own lines.

```markdown
**<Verdict>** — <one-line tally, e.g. "1 blocker, a server-side gap, and 2 minor issues">. <sub>verified against <a href="https://github.com/<owner>/<repo>/commit/<sha>"><sha></a></sub>

### 👓 QA

<format.js output verbatim, or one paragraph if QA was skipped>
```

- **The lead** is one line: the verdict ("Requesting changes" / "Looks good" / "Comment"), the tally, and `verified against <sha>` linking the commit. Use the 7-character abbreviation — that is how GitHub renders SHAs, so the text matches. Always include it: a comment freezes while the pull request moves on, and the reader needs to know which tree the evidence covers.
- **The QA section** is `format.js` output, untouched. If QA was skipped it is one paragraph saying so and what was read instead. It is never silently omitted, and no QA-sourced point may appear when it was skipped.
- Nothing carries a severity or provenance tag. GitHub's sanitizer strips `class` and `style`, so any such tag renders as inert text.

## Inline comments

Each finding becomes one comment, on the new side of the diff:

```json
{ "path": "lib/thing.rb", "line": 12, "side": "RIGHT", "body": "…" }
```

A finding with a suggestion carries it as a committable block below its body. GitHub needs the replacement to end in a newline before the closing fence, or Apply does the wrong thing to the following line:

````markdown
The rescue never matches, because…

```suggestion
module Error; end
```
````

Keep the review's ordering: most important first. `line` must be a line the diff actually touches, or GitHub refuses the comment.

## Rendering the QA section

```
node ~/.claude/skills/review-dry/format.js <qa-dir> --scenario <qa-dir>/scenario.spec.js
```

`--scenario` is not optional: the block carries the script below the video, so a reader sees exactly what was driven. Add `--frames` only when a frame-by-frame review was asked for.

`--heading` swaps the heading line, for a caller placing this block somewhere other than a review comment — that is how **pr-dry** renders it into a pull request description.

## Posting — only after the user reads the draft and asks

1. List the frames the comment needs: every frame a finding cites, plus the failing frame — or all of them, with `--frames`.

   ```
   node ~/.claude/skills/review-dry/format.js <qa-dir> --list-frames
   ```

2. Upload those frames and the video per the **util-gh-upload** skill — follow its instructions and its consent rule, which confirms immediately before anything is published, every time. It hands back an asset manifest.

3. Render the published form. This uploads nothing; it resolves URLs that already exist. Use the same `--frames` choice as in step 1, or the uploads and the links drift apart.

   ```
   node ~/.claude/skills/review-dry/format.js <qa-dir> \
        --assets <qa-dir>/assets.json \
        --video "<the qa.mp4 url from assets.json>" \
        --scenario <qa-dir>/scenario.spec.js
   ```

4. Post it as one review, with the findings as its inline comments.

**The posted review must match the draft the user approved.** If anything material changed between draft and post — new findings, a new commit on the branch — re-draft and show the user again rather than silently posting the difference.
