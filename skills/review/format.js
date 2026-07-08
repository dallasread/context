#!/usr/bin/env node
// Turn a completed QA run into the "### 👓 QA" block of a review comment.
//
// Reads <evidence-dir>/steps.json (written by run.js) plus a map of uploaded
// frame -> user-attachments URL, and emits <evidence-dir>/comment.md: the QA
// heading, the k/K count line, a compact checkpoint table whose "what it
// proves" cells expand (<details>) to the screenshot, and one collapsed
// "🎬 Video & QA script" block. Frames load only when a row is opened.
//
// This is deliberately NOT the whole comment: the review skill authors the
// lead (verdict + "verified against <sha>") and the tagged Top points — which
// is where findings (findings.json + the auto assertion-failure) surface —
// and prepends them to this output. format.js never renders findings; it only
// guarantees their frames are in --list-frames so Top points can link them.
//
// GitHub's comment sanitizer strips class/style, so a failing row cannot be
// tinted or colored — the ONLY cues that survive are (a) sorting it first,
// (b) opening its <details>, and (c) a ⚠️ glyph (emoji carry their own color).
// The table is raw HTML because markdown pipe tables cannot nest <details>.
//
//   node format.js <evidence-dir> [--assets map.json] [--video <url>] [--scenario <path>]
//   node format.js <evidence-dir> --list-frames   # print frames to upload, then exit
//
// --assets map.json: { "02-see.png": "https://github.com/user-attachments/assets/…", … }
//   keyed by frame basename. A missing entry renders that row without an image.
const { parseArgs } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');

const PASS_ICON = '✅';
const FLAG_ICON = '⚠️';

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

// Absolute paths of the frames that must be uploaded for this comment: one per
// row that has a screenshot, plus the failing step's frame, plus every frame a
// finding cites (findings render as the review skill's Top points, which link
// these frames). Reconstructed from the evidence dir so the list is stable
// regardless of where run.js wrote from.
// @param {object} manifest parsed steps.json
// @param {string} dir evidence directory
// @return {string[]} frame paths under <dir>/frames
function framesToUpload(manifest, dir) {
  const { primary, failing } = selectRows(manifest);
  const withFrame = [...primary];
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
// The merged list is NOT rendered into comment.md — the review skill surfaces
// findings as its tagged Top points. Here it only feeds framesToUpload, so a
// finding's screenshot is uploaded and linkable from a Top point.
// A finding's `forReview` lead (a suspected code cause) is deliberately NOT
// returned here — it is a handoff for the review skill, not a QA claim, so it
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
  const fp = path.join(dir, 'findings.json');
  if (fs.existsSync(fp)) {
    let authored = [];
    try { authored = JSON.parse(fs.readFileSync(fp, 'utf8')); } catch { authored = []; }
    for (const f of Array.isArray(authored) ? authored : []) {
      if (!f || !f.summary) continue;
      findings.push({
        severity: String(f.severity || 'major').toLowerCase(),
        summary: f.summary,
        frame: f.frame ? path.basename(f.frame) : undefined,
      });
    }
  }
  const rank = { blocker: 0, major: 1, minor: 2, nit: 3 };
  return findings.sort((a, b) => (rank[a.severity] ?? 9) - (rank[b.severity] ?? 9));
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
// @param {object} opts { assets, video, scenario }
// @return {string} comment markdown ending in a single newline
function build(manifest, opts) {
  const { assets = {}, video, scenario } = opts;
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

  const out = ['### 👓 QA', ''];
  if (!failing) {
    out.push(`**${passed} / ${K} ${unit} passed.** Expand any row to see its screenshot.`);
  } else if (numOf.has(failing)) {
    out.push(`**${passed} / ${K} ${unit} passed** · ${unit.slice(0, -1)} ${numOf.get(failing)} needs another look.`);
  } else {
    out.push(`**${passed} / ${K} ${unit} passed** · the run stopped at \`${failing.caption}\`.`);
  }
  out.push('');
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
    if (scenario) out.push('```markdown', scenario.replace(/```/g, '` ``').trimEnd(), '```', '');
    out.push('</details>', '');
  }
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

function main() {
  const { values, positionals } = parseArgs({
    options: {
      assets: { type: 'string' },
      video: { type: 'string' },
      scenario: { type: 'string' },
      'list-frames': { type: 'boolean', default: false },
    },
    allowPositionals: true,
    strict: true,
  });
  const dir = positionals[0];
  if (!dir) {
    console.error('Usage: format.js <evidence-dir> [--assets map.json] [--video <url>] [--scenario <path>] [--list-frames]');
    process.exit(1);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'steps.json'), 'utf8'));

  if (values['list-frames']) {
    for (const f of framesToUpload(manifest, dir)) console.log(f);
    return;
  }

  const assets = values.assets ? JSON.parse(fs.readFileSync(values.assets, 'utf8')) : {};
  const scenario = values.scenario ? fs.readFileSync(values.scenario, 'utf8') : null;
  const md = build(manifest, { assets, video: values.video, scenario });
  const outPath = path.join(dir, 'comment.md');
  fs.writeFileSync(outPath, md);
  console.log(outPath);
}

main();
