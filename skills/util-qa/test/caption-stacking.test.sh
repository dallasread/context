#!/usr/bin/env bash
# Behavioral test: the caption chrome is ALWAYS on top — nothing the app draws
# can occlude it, not even a native top-layer element.
#
# Max z-index is not enough. A `<dialog>.showModal()`, a `popover`, or a
# fullscreen element render in the browser's TOP LAYER, which paints above every
# z-index in the normal stacking order. A caption that is a mere z-index:MAX box
# loses to any of these. To be always-on-top the caption host must itself join
# the top layer (and re-assert its place on each update, so it stays last).
#
# This proves it against the hardest case — a full-viewport native modal shown
# with showModal() — by driving the REAL setCaption and then SAMPLING THE PIXEL
# where the caption bar sits. Ground truth, not a stylesheet string match:
#   1. The pixel over the caption bar is the caption's colour (dark grey), NOT
#      the modal's colour (red) — i.e. the caption paints above a top-layer modal.
#   2. The caption host is in the top layer (:popover-open), which is the
#      mechanism that lets it beat top-layer app content in the first place.
# Needs: node + playwright/chromium (the skill's own deps).
set -u

DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$DIR/run.js"
PASS=0; FAIL=0

ok()  { echo "ok   - $1"; PASS=$((PASS+1)); }
no()  { echo "NOT ok - $1"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else no "$1 [$2]"; fi; }

echo "# caption always on top"

# Drive the real setCaption over a page whose app has opened a full-viewport
# native modal (top layer, solid red). Then read the single pixel at the centre
# of the caption bar and report its RGB plus whether the host is a live popover.
export NODE_PATH="$DIR/node_modules"
OUT=$(node -e "
const { chromium } = require('playwright');
const zlib = require('zlib');
const { setCaption } = require('$RUN');
// Decode the RGB of a 1x1 RGBA/RGB PNG screenshot. For a single pixel every PNG
// filter reduces to pass-through (all predictors reference absent/zero pixels),
// so bytes[1..3] are the raw R,G,B regardless of the filter byte at [0].
function rgb(buf) {
  let off = 8, idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString('ascii', off + 4, off + 8);
    if (type === 'IDAT') idat.push(buf.slice(off + 8, off + 8 + len));
    off += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  return { r: raw[1], g: raw[2], b: raw[3] };
}
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 800, height: 600 } });
  // A native modal whose backdrop paints the WHOLE viewport red — the backdrop
  // is a top-layer box, so it covers every z-index in the normal stacking order.
  await p.setContent('<!doctype html><body style=margin:0>'
    + '<style>#d{margin:0;padding:0;border:0;max-width:none;max-height:none;width:100vw;height:100vh;background:red}'
    + '#d::backdrop{background:red}</style><dialog id=d></dialog>');
  await p.evaluate(() => document.getElementById('d').showModal());
  // A checkpoint caption: solid (opacity 1), dark-grey (#4a4a4a) bar at the bottom.
  await setCaption(p, 'always on top', 'running', true, {});
  const shot = await p.screenshot({ clip: { x: 400, y: 588, width: 1, height: 1 } });
  const pop = await p.evaluate(() => document.getElementById('__qa_host__').matches(':popover-open'));
  const { r, g, b: bl } = rgb(shot);
  console.log(JSON.stringify({ r, g, b: bl, pop }));
  await b.close();
})().catch((e) => { console.error(e); process.exit(2); });
")

val() { node -e "const d=$OUT;console.log($1)" 2>/dev/null; }

chk "geometry captured"                    "[ -n \"\$OUT\" ]"
# The modal is pure red (g=b=0). The caption bar is dark grey (~74,74,74). If the
# modal occluded the caption the sampled pixel would be red; the caption on top
# keeps green+blue channels well off zero.
chk "caption pixel is NOT the modal's red" \
  "[ \"\$(val 'd.g > 40 && d.b > 40')\" = true ]"
chk "caption host is in the top layer" \
  "[ \"\$(val 'd.pop === true')\" = true ]"

echo
echo "# passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
