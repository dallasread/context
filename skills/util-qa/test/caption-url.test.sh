#!/usr/bin/env bash
# Behavioral tests for the current-URL line in the caption chrome.
#
# setCaption stamps the page's current URL into the bar as a small subtext line
# under the main caption text — so a viewer (or a frame reviewer) always knows
# which page a step ran against, without leaving the video.
#
#   1. The URL line renders in smaller text than the caption line, and sits
#      below it within the same bottom-anchored bar (not a separate box that
#      could drift from the caption or collide with the badge).
#   2. It always reflects THIS call's page.url() — proven by driving the real
#      setCaption across a navigation and reading the DOM, not by string-matching
#      the stylesheet.
# Needs: node + playwright/chromium (the skill's own deps).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# caption url line"

export NODE_PATH="$DIR/node_modules"

# --- T1: geometry — url line is smaller than the caption text, and sits below it, all within the bottom-anchored bar ---
GEO=$(node -e "
const { chromium } = require('playwright');
const { CAPTION_CSS } = require('$RUN');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 800, height: 600 } });
  await p.setContent('<!doctype html><body style=margin:0>');
  const r = await p.evaluate((css) => {
    const host = document.createElement('div');
    document.body.appendChild(host);
    const s = host.attachShadow({ mode: 'open' });
    s.innerHTML = '<style>' + css + '</style>'
      + '<div id=\"cap\"><span id=\"captext\">running a step</span><span id=\"capurl\">https://example.test/a/b</span></div>'
      + '<div id=\"badge\"></div>';
    const box = (el) => { const b = el.getBoundingClientRect(); return { top: b.top, bottom: b.bottom }; };
    const fontSize = (el) => parseFloat(getComputedStyle(el).fontSize);
    return {
      vh: innerHeight,
      capBottom: box(s.getElementById('cap')).bottom,
      textTop: box(s.getElementById('captext')).top,
      urlTop: box(s.getElementById('capurl')).top,
      textSize: fontSize(s.getElementById('captext')),
      urlSize: fontSize(s.getElementById('capurl')),
    };
  }, CAPTION_CSS);
  console.log(JSON.stringify(r));
  await b.close();
})().catch((e) => { console.error(e); process.exit(2); });
")

jq_val() { node -e "const d=$GEO;console.log($1)" 2>/dev/null; }

chk "T1 geometry captured"                       "[ -n \"\$GEO\" ]"
chk "T1 url line renders smaller than caption text" \
  "[ \"\$(jq_val 'd.urlSize < d.textSize')\" = true ]"
chk "T1 url line sits below the caption text" \
  "[ \"\$(jq_val 'd.urlTop >= d.textTop')\" = true ]"
chk "T1 bar (url included) stays flush with the frame bottom" \
  "[ \"\$(jq_val 'Math.abs(d.vh - d.capBottom) <= 1')\" = true ]"

# --- T2: setCaption stamps THIS call's page.url(), not a stale one ----------
FIX="$TMPROOT/page.html"
printf '<!doctype html><meta charset=utf-8><title>fix</title><h1>fixture</h1>' > "$FIX"

OUT=$(node -e "
const { chromium } = require('playwright');
const { setCaption } = require('$RUN');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 800, height: 600 } });
  await setCaption(p, 'before navigation', 'running', false, {});
  const before = await p.evaluate(() => document.getElementById('__qa_host__').__qaShadow.getElementById('capurl').textContent);
  await p.goto('file://$FIX');
  await setCaption(p, 'after navigation', 'running', false, {});
  const after = await p.evaluate(() => document.getElementById('__qa_host__').__qaShadow.getElementById('capurl').textContent);
  console.log(JSON.stringify({ before, after, pageUrl: p.url() }));
  await b.close();
})().catch((e) => { console.error(e); process.exit(2); });
")

val() { node -e "const d=$OUT;console.log($1)" 2>/dev/null; }

chk "T2 result captured"                         "[ -n \"\$OUT\" ]"
chk "T2 url line matches page.url() before navigation" \
  "[ \"\$(val 'd.before')\" = about:blank ]"
chk "T2 url line updates to the new page.url() after navigation" \
  "[ \"\$(val 'd.after === d.pageUrl && /page.html\$/.test(d.after)')\" = true ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
