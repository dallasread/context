#!/usr/bin/env bash
# Behavioral test for where the caption chrome sits in the frame.
#
# The caption bar reads like a subtitle track, so it is anchored to the BOTTOM of
# the video, with the corner badge riding over that same bottom edge. This proves
# it by rendering the engine's real CAPTION_CSS in headless chromium and
# measuring the geometry — not by string-matching the stylesheet.
#
#   1. The caption bar's bottom edge sits on the viewport's bottom edge, and its
#      whole box lives in the lower half of the frame (i.e. it is NOT pinned to
#      the top the way it used to be).
#   2. The corner badge is anchored to the same bottom edge, so it keeps riding
#      over the bar.
# Needs: node + playwright/chromium (the skill's own deps).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# caption position"

# Render CAPTION_CSS with the same markup setCaption injects, then report the
# bounding boxes of the caption bar and badge against an 800x600 viewport.
# NODE_PATH points at the skill's own deps so `node -e` (run from an arbitrary
# cwd) can resolve playwright the way `node run.js` does.
export NODE_PATH="$DIR/node_modules"
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
      + '<div id=\"cap\" class=\"cp\"><span id=\"captext\">checkpoint</span></div>'
      + '<div id=\"badge\"><svg viewBox=\"0 0 1 1\"/></div>';
    const box = (el) => { const b = el.getBoundingClientRect(); return { top: b.top, bottom: b.bottom }; };
    return { vh: innerHeight, cap: box(s.getElementById('cap')), badge: box(s.getElementById('badge')) };
  }, CAPTION_CSS);
  console.log(JSON.stringify(r));
  await b.close();
})().catch((e) => { console.error(e); process.exit(2); });
")

jq_val() { node -e "const d=$GEO;console.log($1)" 2>/dev/null; }

chk "T1 geometry captured"                 "[ -n \"\$GEO\" ]"
# Caption bar's bottom edge is flush with the viewport bottom (allow 1px slop).
chk "T1 caption bar bottom flush at frame bottom" \
  "[ \"\$(jq_val 'Math.abs(d.vh - d.cap.bottom) <= 1')\" = true ]"
# ...and its whole box is in the lower half — proving it is not top-anchored.
chk "T1 caption bar lives in lower half" \
  "[ \"\$(jq_val 'd.cap.top > d.vh / 2')\" = true ]"
# Badge rides the same bottom edge (bottom:4px), not the top corner.
chk "T2 badge anchored near frame bottom" \
  "[ \"\$(jq_val 'd.vh - d.badge.bottom >= 0 && d.vh - d.badge.bottom <= 12')\" = true ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
