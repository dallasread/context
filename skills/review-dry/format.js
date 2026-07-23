#!/usr/bin/env node
// Turn a completed QA run into the "### 👓 QA" block of a review comment.
//
// Reads <evidence-dir>/steps.json (written by run.js) plus a map of uploaded
// frame -> user-attachments URL, and emits <evidence-dir>/comment.md in one of
// two styles:
//   VIDEO (default) — the QA heading, the k/K count line, a terse ✅/⚠️
//   checkpoint checklist, the failing checkpoint's frame (only when there is
//   one), the video inline, and below it the QA script in a collapsible
//   <details> (always present when there is a video). Frames stay out.
//   FRAMES (--frames) — the per-checkpoint table whose "what it proves" cells
//   expand (<details>) to the screenshot, plus one collapsed "🎬 Video & QA
//   script" block. For when a frame-by-frame review is explicitly wanted.
//
// This is deliberately NOT the whole comment: the review-dry skill authors the
// lead (verdict + "verified against <sha>") and the plain-prose Top points —
// which is where findings (findings.json + the auto assertion-failure) surface —
// and prepends them to this output. format.js never renders findings; it only
// guarantees their frames are in --list-frames so Top points can link them.
//
// GitHub's comment sanitizer strips class/style, so a failing row cannot be
// tinted or colored — the ONLY cues that survive are (a) sorting it first,
// (b) opening its <details>, and (c) a ⚠️ glyph (emoji carry their own color).
// The table is raw HTML because markdown pipe tables cannot nest <details>.
//
//   node format.js <evidence-dir> [--frames] [--heading <md>] [--assets map.json] [--video <url>] [--scenario <path>]
//   node format.js <evidence-dir> [--frames] --list-frames   # print frames to upload, then exit
//
// --list-frames matches the style: video mode names only the failing frame +
// finding frames (nothing else is embedded or linked); --frames adds every
// table row's frame.
//
// --heading replaces the default "### 👓 QA" heading line — pr-dry takes over a
// PR description's QA section, rendering it as "## 👓 QA" from the same evidence.
//
// --assets map.json: { "02-see.png": "https://github.com/user-attachments/assets/…", … }
//   keyed by frame basename. A missing entry renders that row without an image.
const { parseArgs } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');

const PASS_ICON = '✅';
const FLAG_ICON = '⚠️';

// The severities, highest first — this is both the render sort order for
// findings and the closed set a findings.json entry may name. There is no `nit`
// tier: the review never reports nits, so a nit-level finding has no home here.
const SEVERITY_RANK = { blocker: 0, major: 1, minor: 2 };

// Stop the run on a malformed findings.json — a specific message on stderr and
// a non-zero exit. The whole point: a bad findings file (from any author) must
// fail LOUDLY here, not degrade quietly into a wrong or empty QA comment.
// @param {string} msg the specific breach, naming the offending entry
// @return {never}
function bail(msg) {
  console.error(`format.js: ${msg}`);
  process.exit(1);
}

// Load and validate <dir>/findings.json — the observations the reviewer authored
// from the frames. The file is optional (absent → no findings), but when present
// it is a contract, not a hint: a JSON array whose every entry names a severity
// (from SEVERITY_RANK), a one-sentence summary, and a frame basename that was
// actually captured under frames/. That last check catches the common real
// mistake — a cited frame that was never shot — before it becomes a dead image
// link in the comment. Any breach is fatal via bail().
// @param {string} dir evidence directory (holds findings.json and frames/)
// @return {Array<{severity: string, summary: string, frame: string}>}
function loadFindings(dir) {
  const fp = path.join(dir, 'findings.json');
  if (!fs.existsSync(fp)) return [];
  let authored;
  try {
    authored = JSON.parse(fs.readFileSync(fp, 'utf8'));
  } catch (e) {
    bail(`findings.json is not valid JSON — ${e.message}`);
  }
  if (!Array.isArray(authored)) bail('findings.json must be a JSON array of findings');
  authored.forEach((f, i) => {
    const at = `findings.json entry ${i}`;
    if (!f || typeof f !== 'object' || Array.isArray(f)) bail(`${at} is not an object`);
    for (const key of ['severity', 'summary', 'frame']) {
      if (!f[key]) bail(`${at} is missing "${key}" — all three are required`);
    }
    if (!(String(f.severity).toLowerCase() in SEVERITY_RANK)) {
      bail(`${at} has an unknown severity "${f.severity}" — use blocker | major | minor (the review never reports nits)`);
    }
    if (!fs.existsSync(path.join(dir, 'frames', path.basename(f.frame)))) {
      bail(`${at} cites frame "${f.frame}" but no such file exists under frames/`);
    }
  });
  return authored;
}

// Escape text for safe inclusion in HTML table cells, <summary>, and alt="".
// @param {*} s value to escape
// @return {string} HTML-safe string
function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// The steps that become table rows: the checkpoints (a run's meaningful proofs),
// or — for a legacy no-checkpoint run — every step that captured a frame. The
// failing step is always included even when it is plumbing, so a break is never
// hidden.
// @param {object} manifest parsed steps.json
// @return {{primary: object[], failing: (object|null), hasCheckpoints: boolean}}
function selectRows(manifest) {
  const steps = manifest.steps || [];
  const checkpoints = steps.filter((s) => s.checkpoint);
  const hasCheckpoints = checkpoints.length > 0;
  const primary = hasCheckpoints ? checkpoints : steps.filter((s) => s.frame || s.ok === false);
  const failing = steps.find((s) => s.ok === false) || null;
  return { primary, failing, hasCheckpoints };
}

// Absolute paths of the frames that must be uploaded for this comment: the
// failing step's frame plus every frame a finding cites (findings render as
// the review-dry skill's Top points, which link these frames), and — in --frames
// mode only — one per table row that has a screenshot. Reconstructed from the
// evidence dir so the list is stable regardless of where run.js wrote from.
// @param {object} manifest parsed steps.json
// @param {string} dir evidence directory
// @param {boolean} frames true for the frame-by-frame table style
// @return {string[]} frame paths under <dir>/frames
function framesToUpload(manifest, dir, frames) {
  const { primary, failing } = selectRows(manifest);
  const withFrame = frames ? [...primary] : [];
  if (failing && !withFrame.includes(failing)) withFrame.push(failing);
  const names = new Set(withFrame.filter((s) => s.frame).map((s) => path.basename(s.frame)));
  for (const f of collectFindings(manifest, dir)) if (f.frame) names.add(f.frame);
  return [...names].map((n) => path.join(dir, 'frames', n));
}

// Merge the run's findings from two provenances, highest severity first:
//   - AUTO (kind "assertion"): the step the run failed on IS a finding — a
//     blocker, backed by its frame. run.js already knows this.
//   - OBSERVED (kind "observation"): defects the reviewing agent saw in the
//     frames that no assertion caught, authored into <dir>/findings.json.
// The merged list is NOT rendered into comment.md — the review-dry skill surfaces
// findings as its plain-prose Top points. Here it only feeds framesToUpload, so a
// finding's screenshot is uploaded and linkable from a Top point.
// A finding's `forReview` lead (a suspected code cause) is deliberately NOT
// returned here — it is a handoff for the review-dry skill, not a QA claim, so it
// never reaches the posted QA comment. QA only states what a frame can show.
// @param {object} manifest parsed steps.json
// @param {string} dir evidence directory (holds findings.json)
// @return {Array<{severity: string, summary: string, frame: (string|undefined)}>}
function collectFindings(manifest, dir) {
  const findings = [];
  const failing = (manifest.steps || []).find((s) => s.ok === false);
  if (failing) {
    findings.push({
      severity: 'blocker',
      summary: failing.error ? `${failing.caption} — ${failing.error}` : failing.caption,
      frame: failing.frame ? path.basename(failing.frame) : undefined,
    });
  }
  for (const f of loadFindings(dir)) {
    findings.push({
      severity: String(f.severity).toLowerCase(),
      summary: f.summary,
      frame: path.basename(f.frame),
    });
  }
  return findings.sort((a, b) => (SEVERITY_RANK[a.severity] ?? 9) - (SEVERITY_RANK[b.severity] ?? 9));
}

// Render one <tr>: number, result glyph, and the expandable proof cell.
// @param {object} spec { num, ok, caption, url, detail }
// @return {string} HTML rows
function renderRow({ num, ok, caption, url, detail }) {
  const cap = esc(caption);
  const inner = [`        <summary>${cap}</summary>`, '        <br>'];
  if (url) inner.push(`        <img alt="${cap}" src="${esc(url)}">`);
  if (detail) inner.push(`        <br>${detail}`);
  return [
    '    <tr>',
    `      <td align="center">${num}</td>`,
    `      <td align="center">${ok ? PASS_ICON : FLAG_ICON}</td>`,
    '      <td>',
    `        <details${ok ? '' : ' open'}>`,
    ...inner,
    '        </details>',
    '      </td>',
    '    </tr>',
  ].join('\n');
}

// Assemble the "### 👓 QA" block markdown.
// @param {object} manifest parsed steps.json
// @param {object} opts { assets, video, scenario, frames, heading }
// @return {string} comment markdown ending in a single newline
function build(manifest, opts) {
  const { assets = {}, video, scenario, frames = false, heading = '### 👓 QA' } = opts;
  const { primary, failing, hasCheckpoints } = selectRows(manifest);
  const K = primary.length;
  const passed = primary.filter((s) => s.ok !== false).length;
  const unit = hasCheckpoints ? 'checkpoints' : 'steps';

  const numOf = new Map();
  primary.forEach((s, i) => numOf.set(s, i + 1));

  // Failing rows first; the rest keep run order (stable sort).
  const rowSteps = [...primary];
  if (failing && !rowSteps.includes(failing)) rowSteps.unshift(failing);
  rowSteps.sort((a, b) => (a.ok === b.ok ? 0 : a.ok ? 1 : -1));

  const rows = rowSteps.map((s) => renderRow({
    num: numOf.has(s) ? numOf.get(s) : '—',
    ok: s.ok !== false,
    caption: s.caption,
    url: s.frame ? assets[path.basename(s.frame)] : undefined,
    detail: s.ok === false && s.error ? `<code>${esc(s.error)}</code>` : '',
  }));

  const out = [heading, ''];
  if (!failing) {
    out.push(`**${passed} / ${K} ${unit} passed.** Expand any row to see its screenshot.`);
  } else if (numOf.has(failing)) {
    out.push(`**${passed} / ${K} ${unit} passed** · ${unit.slice(0, -1)} ${numOf.get(failing)} needs another look.`);
  } else {
    out.push(`**${passed} / ${K} ${unit} passed** · the run stopped at \`${failing.caption}\`.`);
  }
  out.push('');
  if (frames) {
    out.push(
      '<table>',
      '  <thead>',
      '    <tr><th align="center">#</th><th align="center">Result</th><th align="left">What it proves — expand for the frame</th></tr>',
      '  </thead>',
      '  <tbody>',
      rows.join('\n'),
      '  </tbody>',
      '</table>',
      '',
    );
    if (video || scenario) {
      out.push('<details>', '<summary>🎬 Video & QA script</summary>', '');
      if (video) out.push(video, '');
      if (scenario) out.push('```js', scenario.replace(/```/g, '` ``').trimEnd(), '```', '');
      out.push('</details>', '');
    }
    return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
  }

  // VIDEO style: a terse checklist in run order (the failing plumbing step,
  // when the break was pre-checkpoint, is appended so it is never hidden),
  // the failing frame as the one embedded image, the video inline (GitHub
  // renders a bare user-attachments URL as a player), the script collapsed.
  const listSteps = [...primary];
  if (failing && !listSteps.includes(failing)) listSteps.push(failing);
  for (const s of listSteps) {
    const bad = s.ok === false;
    const err = bad && s.error ? ` — \`${s.error}\`` : '';
    out.push(`- ${bad ? FLAG_ICON : PASS_ICON} ${esc(s.caption)}${err}`);
  }
  out.push('');
  const failUrl = failing && failing.frame ? assets[path.basename(failing.frame)] : undefined;
  if (failUrl) out.push(`<img alt="${esc(failing.caption)}" src="${esc(failUrl)}">`, '');
  if (video) out.push(video, '');
  // The QA script sits below the video in a collapsible <details> — always
  // present whenever there is a video (the workflow always passes --scenario
  // alongside --video), so a reader can expand exactly what was driven.
  if (scenario) {
    out.push('<details>', '<summary>📜 QA script</summary>', '', '```js', scenario.replace(/```/g, '` ``').trimEnd(), '```', '', '</details>', '');
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

function main() {
  const { values, positionals } = parseArgs({
    options: {
      assets: { type: 'string' },
      video: { type: 'string' },
      scenario: { type: 'string' },
      frames: { type: 'boolean', default: false },
      heading: { type: 'string' },
      'list-frames': { type: 'boolean', default: false },
    },
    allowPositionals: true,
    strict: true,
  });
  const dir = positionals[0];
  if (!dir) {
    console.error('Usage: format.js <evidence-dir> [--frames] [--heading <md>] [--assets map.json] [--video <url>] [--scenario <path>] [--list-frames]');
    process.exit(1);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'steps.json'), 'utf8'));
  // Validate findings.json up front — every mode, not just --list-frames — so a
  // malformed file stops the run before any comment.md is written.
  loadFindings(dir);

  if (values['list-frames']) {
    for (const f of framesToUpload(manifest, dir, values.frames)) console.log(f);
    return;
  }

  const assets = values.assets ? JSON.parse(fs.readFileSync(values.assets, 'utf8')) : {};
  const scenario = values.scenario ? fs.readFileSync(values.scenario, 'utf8') : null;
  const md = build(manifest, { assets, video: values.video, scenario, frames: values.frames, heading: values.heading });
  const outPath = path.join(dir, 'comment.md');
  fs.writeFileSync(outPath, md);
  console.log(outPath);
}

main();
