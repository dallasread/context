#!/usr/bin/env node
// QA scenario runner: drives a running web app in headless Chromium from a
// scripted scenario, records a video of the session, captures a screenshot
// after every step, and fails the run if any `expect` step fails.
//
// Usage: node run.js <scenario.json> --out <dir> [--no-auth]
//
// Reuses the dnscreenshot skill's Playwright install and cookie store.
const { parseArgs } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const { chromium } = require('playwright');
const COOKIES_FILE = path.join(__dirname, 'cookies.json');
const CREDENTIALS_FILE = path.join(__dirname, 'credentials.json');

// Load a scenario as a CommonJS module regardless of the app repo's package
// type. Scenarios are always CommonJS (`module.exports`), but the evidence dir
// lives in the app repo's own tmp/, so in an ESM app ("type":"module") Node
// parses a bare `.js` scenario as ESM and require() throws ERR_REQUIRE_ESM. A
// `.cjs` extension forces CommonJS parsing no matter the enclosing package, so
// for any non-.cjs path we materialize a sibling `.cjs` copy (adjacent, to keep
// relative resolution intact) and require that — the author never has to rename
// the scenario to .cjs to work in an ESM repo.
function requireScenario(absPath, source) {
  if (/\.cjs$/i.test(absPath)) return require(absPath);
  const shim = path.join(path.dirname(absPath), `.${path.basename(absPath)}.qa-load.cjs`);
  fs.writeFileSync(shim, source);
  try { return require(shim); }
  finally { fs.rmSync(shim, { force: true }); }
}

const STEP_TIMEOUT_MS = 2_000; // the per-step cap: how long an assertion/interaction waits for its target (also how long a real failure takes to surface red), AND the ceiling an explicit `wait` is clamped to — no single step may stall the run past this. Kept tight because the app is served locally.
const FAIL_HOLD_MS = 1800; // a failed step holds red a touch longer than a pass holds green, so the failure clearly reads as the end
const CHECKPOINT_HOLD_MS = 1000; // a passed checkpoint holds green ~1s before the next one goes in-progress
const CHECKPOINT_INTRO_MS = 400; // brief in-progress beat when a checkpoint becomes active, before its plumbing runs

// Caption bar injected into the page itself: perfectly synced with the video
// and included in the frames, no ffmpeg text rendering. pointer-events: none
// so it can never interfere with the flow under test.
const CAPTION_COLORS = { running: '#4a4a4a', pass: '#1d7a4f', fail: '#a32d2d' };
// A corner badge — the little SVG that rides bottom-right over the caption bar —
// is supplied by the repo's profile, not the engine: distinct art per outcome
// state (running/pass/fail, and any future state), loaded by loadBadges. The
// engine carries no default mascot, so a repo without a `badge` in its profile
// shows nothing there. See loadBadges for the mapping.
//
// The caption chrome's stylesheet, anchored to the BOTTOM of the frame so it
// reads like a subtitle track under the app rather than masking the app's own
// header. Plumbing steps read as subdued mechanical narration; checkpoints — the
// human-meaningful moments — pop with a gold left accent and larger type, so a
// viewer's eye lands on exactly the things the change set out to prove. The
// badge is anchored to the same bottom edge so it keeps riding over the bar.
const CAPTION_CSS =
    '#cap{position:fixed;left:0;right:0;bottom:0;z-index:2147483647;padding:13px 20px;font:500 19px/1.4 -apple-system,sans-serif;color:#fff;pointer-events:none;opacity:.9;transition:opacity .2s ease,padding .2s ease}'
  + '#cap.cp{padding:18px 22px;font-weight:700;font-size:26px;opacity:1;box-shadow:inset 8px 0 0 #ffd24a}'
  + '#captext{vertical-align:middle}'
  + '#capurl{display:block;margin-top:3px;font-size:11px;line-height:1.3;font-weight:400;opacity:.6;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}'
  + '#badge{position:fixed;bottom:4px;right:16px;width:104px;height:104px;z-index:2147483647;pointer-events:none;filter:drop-shadow(0 2px 4px rgba(0,0,0,.35))}'
  + '#badge svg{width:100%;height:100%;display:block}';

// Elevator-music beds, all synthesized by ffmpeg's aevalsrc (no external asset,
// no licensing): a soft four-voice pad under a slow tremolo, plus a plucked
// arpeggio that steps the current chord up an octave. Each track varies the
// chord progression, tempo, arpeggio rate, tremolo, and low-pass cutoff for a
// distinct feel; a run picks one (via --music / a `music:` line, else at
// random). A track may set `skank: true` to swap the smooth tremolo for an
// offbeat chop (the reggae and ska beds). `pick(idx,[v0..v3])` is a nested-if selecting
// vN by floor(idx); `seg` is the chord index, `beat` the arpeggio step within a chord.
const MUSIC_TRACKS = ['lounge', 'twilight', 'sunrise', 'reggae', 'ska'];
function buildMusic(track) {
  const HZ = { F3: 174.61, G3: 196.0, A3: 220.0, B3: 246.94, C4: 261.63, D4: 293.66, E4: 329.63, F4: 349.23, G4: 392.0, A4: 440.0, B4: 493.88, C5: 523.25 };
  const TRACKS = {
    // I–vi–ii–V in C: mellow lounge (the original bed).
    lounge:   { chords: [['C4', 'E4', 'G4', 'B4'], ['A3', 'C4', 'E4', 'G4'], ['D4', 'F4', 'A4', 'C5'], ['G3', 'B3', 'D4', 'F4']], segSec: 2,   arpDivSec: 0.5,   tremRate: 0.15, lowpass: 2200 },
    // Slower, darker, dreamier — longer chords, lazier arpeggio, softer top end.
    twilight: { chords: [['F3', 'A3', 'C4', 'E4'], ['C4', 'E4', 'G4', 'B4'], ['D4', 'F4', 'A4', 'C5'], ['A3', 'C4', 'E4', 'G4']], segSec: 2.5, arpDivSec: 0.75,  tremRate: 0.1,  lowpass: 1700 },
    // I–V–vi–IV pop turnaround: quicker, brighter, busier arpeggio.
    sunrise:  { chords: [['C4', 'E4', 'G4', 'B4'], ['G3', 'B3', 'D4', 'F4'], ['A3', 'C4', 'E4', 'G4'], ['F3', 'A3', 'C4', 'E4']], segSec: 1.5, arpDivSec: 0.375, tremRate: 0.2,  lowpass: 2600 },
    // vi–IV–I–V roots with a `skank: true` offbeat chop instead of the smooth
    // tremolo — the staccato pad lands between the arp plucks, the reggae bubble.
    // Warm/dubby low-pass; the gate ∈ [0,1] like the tremolo, so the peak-amplitude
    // headroom below is unchanged.
    reggae:   { chords: [['A3', 'C4', 'E4', 'G4'], ['F3', 'A3', 'C4', 'E4'], ['C4', 'E4', 'G4', 'B4'], ['G3', 'B3', 'D4', 'F4']], segSec: 2,   arpDivSec: 0.4,   tremRate: 0.15, lowpass: 1600, skank: true },
    // Ska is the skank at double time: bright major I–IV–V–IV, a fast upstroke
    // chop (small arpDivSec = the "chukka-chukka"), brighter top end than reggae.
    ska:      { chords: [['C4', 'E4', 'G4', 'B4'], ['F3', 'A3', 'C4', 'E4'], ['G3', 'B3', 'D4', 'F4'], ['F3', 'A3', 'C4', 'E4']], segSec: 1.5, arpDivSec: 0.25,  tremRate: 0.2,  lowpass: 2800, skank: true },
  };
  const t = TRACKS[track] || TRACKS.lounge;
  const chords = t.chords.map((c) => c.map((n) => HZ[n]));
  const loopSec = chords.length * t.segSec;
  const pick = (idx, v) => `if(lt(${idx},1),${v[0]},if(lt(${idx},2),${v[1]},if(lt(${idx},3),${v[2]},${v[3]})))`;
  const seg = `floor(mod(t,${loopSec})/${t.segSec})`;
  const beat = `floor(mod(t,${t.segSec})/${t.arpDivSec})`;
  const sine = (f) => `sin(2*PI*(${f})*t)`;
  // Pad: four voices, each 0.09 (≤0.36 summed); ×0.7 master ×tremolo (≤1) plus
  // the ≤0.16 arpeggio keeps the peak ~0.41, well under clipping.
  const pad = [0, 1, 2, 3].map((k) => `0.09*${sine(pick(seg, chords.map((c) => c[k])))}`).join('+');
  const tremolo = `(0.85+0.15*sin(2*PI*${t.tremRate}*t))`;
  // Skank (reggae/ska): gate the pad with a sharp decaying chop landing on the
  // offbeat (half an arp-step out of phase with the pluck), giving staccato
  // upstroke chords instead of the smooth tremolo. Gate ∈ [0,1], same peak as tremolo.
  const skank = `exp(-8*mod(t+${(t.arpDivSec / 2).toFixed(4)},${t.arpDivSec}))`;
  const padGate = t.skank ? skank : tremolo;
  const arpFreq = pick(seg, chords.map((c) => pick(beat, c.map((f) => (f * 2).toFixed(2)))));
  const pluck = `exp(-5*mod(t,${t.arpDivSec}))`;
  const expr = `0.7*(${pad})*${padGate}+0.16*${pluck}*${sine(arpFreq)}`;
  // Commas inside the expression must be escaped for the lavfi option parser.
  return { src: `aevalsrc=${expr.replace(/,/g, '\\,')}:c=stereo:s=32000`, lowpass: t.lowpass };
}

// Smooth scroll (instead of an instant jump) so the movement itself is
// recorded — the recorder only captures frames when the page repaints.
async function smoothScrollTo(locator) {
  await locator.evaluate((el) => el.scrollIntoView({ behavior: 'smooth', block: 'center' })).catch(() => {});
}

// A rAF-driven pause: forces repaints for `ms` so an in-page animation (a click
// ripple, a CSS transition) is actually captured — the recorder only grabs
// frames when the page paints.
async function spinFrames(page, ms) {
  await page.evaluate((ms) => new Promise((resolve) => {
    const start = performance.now();
    const tick = (t) => (t - start >= ms ? resolve() : requestAnimationFrame(tick));
    requestAnimationFrame(tick);
  }), ms).catch(() => page.waitForTimeout(ms));
}

// Draw a click highlight — an expanding gold ring plus a cursor dot — centered
// on a viewport point, so clicks are visible on camera (a headless recording
// never shows the real OS cursor). It lives in the SAME closed shadow root as
// the caption chrome: pointer-events:none and text-free, so it neither blocks
// the click nor is ever seen by a `see` assertion. Self-removes after the run.
async function showClick(page, x, y) {
  await page.evaluate(([x, y]) => {
    const host = document.getElementById('__qa_host__');
    const shadow = host && host.__qaShadow;
    if (!shadow) return;
    if (!shadow.getElementById('__qa_click_style__')) {
      const st = document.createElement('style');
      st.id = '__qa_click_style__';
      st.textContent =
        '@keyframes qaRing{from{transform:translate(-50%,-50%) scale(.25);opacity:.95}to{transform:translate(-50%,-50%) scale(1);opacity:0}}'
        + '@keyframes qaDot{0%{transform:translate(-50%,-50%) scale(.5);opacity:0}25%{opacity:1}100%{transform:translate(-50%,-50%) scale(1.15);opacity:0}}'
        + '.qa-click{position:fixed;z-index:2147483646;pointer-events:none}'
        + '.qa-click i{position:absolute;left:0;top:0;border-radius:50%;display:block}'
        + '.qa-click .ring{width:72px;height:72px;border:4px solid #ffd24a;box-shadow:0 0 14px rgba(255,210,74,.85);animation:qaRing .9s ease-out forwards}'
        + '.qa-click .dot{width:24px;height:24px;background:#ffd24a;box-shadow:0 0 12px rgba(255,210,74,.95);animation:qaDot .9s ease-out forwards}';
      shadow.appendChild(st);
    }
    const c = document.createElement('div');
    c.className = 'qa-click';
    c.style.left = `${x}px`;
    c.style.top = `${y}px`;
    c.innerHTML = '<i class="ring"></i><i class="dot"></i>';
    shadow.appendChild(c);
    setTimeout(() => c.remove(), 1000);
  }, [x, y]).catch(() => {});
}

async function setCaption(page, text, state = 'running', checkpoint = false, badges = {}) {
  const url = redact(page.url()); // read+redact here (sync, off the live Page) — a token in a query string must not land in the video's own pixels
  await page.evaluate(([text, bg, badge, checkpoint, css, url]) => {
    // QA chrome — the caption bar and the corner badge — lives inside a CLOSED
    // shadow root, so it is completely invisible to the automation querying the
    // page under test. Playwright pierces OPEN shadow roots but cannot see
    // CLOSED ones, which is the whole point: a `see "X"` step sets the caption
    // to a label containing X, and if the chrome were in the light DOM (or an
    // open root) getByText(X) would match the caption itself and the assertion
    // could never fail. The isolation — not any text-rendering trick — is what
    // keeps text assertions honest. The closed root's handle is stashed on the
    // host element so both this function and the dwell repaint can reach in; the
    // whole thing is recreated after navigation wipes the DOM.
    let host = document.getElementById('__qa_host__');
    let shadow;
    if (!host) {
      host = document.createElement('div');
      host.id = '__qa_host__';
      // Join the top layer: a manual popover paints above ALL normal-flow
      // content regardless of z-index, so the caption can never be occluded by
      // the app — not even by a native modal/popover, which a mere z-index:MAX
      // box would lose to. Neutralise the popover UA chrome (centred bordered
      // box) so only the fixed-position bar inside the shadow shows; manual =
      // no focus grab, no light-dismiss, and pointer-events:none keeps clicks
      // passing straight through to the app under test.
      host.setAttribute('popover', 'manual');
      host.style.cssText = 'pointer-events:none;inset:auto;margin:0;padding:0;border:0;width:0;height:0;background:transparent;overflow:visible';
      document.body.appendChild(host);
      shadow = host.attachShadow({ mode: 'closed' });
      host.__qaShadow = shadow;
      shadow.innerHTML =
        `<style>${css}</style><div id="cap"><span id="captext"></span><span id="capurl"></span></div><div id="badge"></div>`;
    } else {
      shadow = host.__qaShadow;
    }
    // (Re-)promote to the very top of the top layer on every update, so a modal
    // the app opened since the last caption can't sit above us. Toggling moves
    // us to the front; wrapped because showPopover throws if the API is absent
    // (older engines) or the state is already what we asked for — either way,
    // never fatal (the caption then falls back to its z-index behaviour).
    try {
      if (host.matches(':popover-open')) host.hidePopover();
      host.showPopover();
    } catch (e) { /* popover unsupported — z-index still applies */ }
    const cap = shadow.getElementById('cap');
    cap.className = checkpoint ? 'cp' : '';
    cap.style.background = bg;
    shadow.getElementById('captext').textContent = text;
    shadow.getElementById('capurl').textContent = url;
    // Swap the corner badge to this state's art. The profile supplies distinct
    // art per outcome (empty when it defines none for this state → hidden), so
    // the engine just drops in whatever SVG this state maps to.
    const badgeEl = shadow.getElementById('badge');
    badgeEl.innerHTML = badge;
    badgeEl.style.display = badge ? '' : 'none';
  }, [text, CAPTION_COLORS[state], badges[state] || '', checkpoint, CAPTION_CSS, url]).catch(() => {});
}

// Browser cookies ignore ports, so stores fall back from "host:port" to bare
// hostname — an app booted on a random free port needs no new config entry.
function hostEntry(file, host) {
  if (!fs.existsSync(file)) return null;
  const store = JSON.parse(fs.readFileSync(file, 'utf8'));
  return store[host] || store[host.split(':')[0]] || null;
}

function loadCookies(host) {
  return Object.entries(hostEntry(COOKIES_FILE, host) || {}).filter(([k]) => k !== 'savedAt');
}

// Repo config is per-repo (profiles/<repo>.json) so two apps on localhost
// never collide; the host-keyed credentials.json remains as a fallback for
// standalone --base runs without --repo.
function loadRepoConfig(repo, host) {
  if (repo) {
    // A bare repo name resolves to profiles/<name>.js (a JS module exporting
    // { serve, variables, badge, login }); a value ending in .js/.json is loaded
    // as a direct path — handy for standalone runs pointed at an arbitrary
    // profile. require() handles both a JS module and a plain .json. A legacy
    // .json profile is still honored when no .js exists. qa.sh always passes a
    // bare origin-remote name, so it never trips the path branch.
    let f;
    if (/\.(js|json)$/i.test(repo)) {
      f = path.resolve(repo);
    } else {
      const stem = path.join(__dirname, 'profiles', repo);
      f = fs.existsSync(`${stem}.js`) ? `${stem}.js` : `${stem}.json`;
    }
    if (fs.existsSync(f)) return require(f);
  }
  return hostEntry(CREDENTIALS_FILE, host);
}

// The corner badge is profile-owned branding: profiles/<repo>.json may carry a
// `badge` map of state → SVG filename (resolved against profiles/, or an
// absolute path). Returns { state: svgSource } for the states whose files exist;
// a missing file is warned and skipped (never fatal), and a profile with no
// `badge` yields {} — the engine ships no default, so branding lives entirely in
// the profile. The keys match the caption states (running/pass/fail), and since
// setCaption just looks up badges[state], a profile can brand any future state
// by adding its key here.
function loadBadges(repoConfig, baseDir = path.join(__dirname, 'profiles')) {
  const map = repoConfig?.badge;
  if (!map || typeof map !== 'object') return {};
  const out = {};
  for (const [state, file] of Object.entries(map)) {
    const svgPath = path.resolve(baseDir, file);
    if (fs.existsSync(svgPath)) out[state] = fs.readFileSync(svgPath, 'utf8');
    else console.warn(`  (badge for "${state}" not found: ${file})`);
  }
  return out;
}

// Redact configured credential values from anything the runner emits
// (captions, steps.json, console, the scenario copy) so posted QA evidence
// can never carry them.
let SECRETS = [];
function redact(text) {
  return SECRETS.reduce((s, secret) => s.split(secret).join('••••••'), String(text));
}

// Log in by running the repo's "login" macro (steps like any scenario's),
// then persist the fresh session into the skill's cookie store.
async function formLogin(page, base, host, creds) {
  if (typeof creds?.login !== 'function') throw new Error('AUTH_FAILED and no login() function in the repo profile (profiles/<repo>.js — see REFERENCE.md)');

  // The profile's login() drives raw Playwright with the profile's `variables`
  // injected as `vars` — never the scenario's auto-login `visit`, which would
  // recurse. Credentials live in `variables` and reach login() only by name.
  await creds.login({ page, base, vars: { ...(creds.variables || {}) } });
  await page.waitForURL((url) => !/\/login\b|\/sessions\/new\b/.test(url.pathname), { timeout: 15_000 })
      .catch(() => { throw new Error('LOGIN_FAILED — the "login" macro ended still on the login page; check the repo config'); });

  // Persist the named session cookie, or every cookie when none is named.
  const cookies = await page.context().cookies(base);
  const session = creds.sessionCookie ? cookies.filter((c) => c.name === creds.sessionCookie) : cookies;
  const persisted = session.length > 0 ? session : cookies;
  if (persisted.length === 0) throw new Error('LOGIN_FAILED — no cookies after login');
  const store = fs.existsSync(COOKIES_FILE) ? JSON.parse(fs.readFileSync(COOKIES_FILE, 'utf8')) : {};
  const entry = { ...Object.fromEntries(persisted.map((c) => [c.name, c.value])), ...(creds.extraCookies || {}), savedAt: new Date().toISOString() };
  store[host] = entry;
  store[host.split(':')[0]] = entry;
  fs.writeFileSync(COOKIES_FILE, JSON.stringify(store, null, 2));
  console.log('  (logged in, refreshed cookie store)');
}

async function runStep(page, step, base) {
  switch (step.action) {
    case 'goto': {
      await page.goto(base + step.path, { waitUntil: 'networkidle' });
      const finalUrl = page.url();
      if (/\/login\b|\/sessions\/new\b/.test(finalUrl) && !/\/login\b|\/sessions\/new\b/.test(step.path)) {
        throw new Error(`AUTH_FAILED final_url=${finalUrl} — re-save the session cookie with dnscreenshot/save-cookie.js`);
      }
      break;
    }
    case 'click': {
      const loc = page.locator(step.selector).first();
      // Settle the target in view, mark where the click lands, let the ring
      // register on camera, then perform the real click.
      await loc.scrollIntoViewIfNeeded({ timeout: STEP_TIMEOUT_MS }).catch(() => {});
      const box = await loc.boundingBox().catch(() => null);
      if (box) {
        await showClick(page, box.x + box.width / 2, box.y + box.height / 2);
        await spinFrames(page, 300);
      }
      await loc.click({ timeout: STEP_TIMEOUT_MS });
      break;
    }
    case 'fill':
      await page.locator(step.selector).first().fill(step.value, { timeout: STEP_TIMEOUT_MS });
      break;
    case 'select':
      await page.locator(step.selector).first().selectOption(step.value, { timeout: STEP_TIMEOUT_MS });
      break;
    case 'hover':
      await page.locator(step.selector).first().hover({ timeout: STEP_TIMEOUT_MS });
      break;
    case 'expect':
      await page.locator(step.selector).first().waitFor({ state: 'visible', timeout: STEP_TIMEOUT_MS });
      await smoothScrollTo(page.locator(step.selector).first());
      break;
    case 'expectText':
      await page.getByText(step.text).first().waitFor({ state: 'visible', timeout: STEP_TIMEOUT_MS });
      await smoothScrollTo(page.getByText(step.text).first());
      break;
    case 'waitMs': {
      // An explicit wait is clamped to the per-step cap, so no single step —
      // not even a `wait` — can stall the run past STEP_TIMEOUT_MS. If a target
      // legitimately needs longer, chain more than one wait (each its own step).
      const ms = Math.min(step.ms, STEP_TIMEOUT_MS);
      if (ms < step.ms) console.warn(`  (wait ${step.ms}ms clamped to ${ms}ms — per-step cap)`);
      await page.waitForTimeout(ms);
      break;
    }
    default:
      throw new Error(`Unknown action: ${step.action}`);
  }
}


async function main() {
  const { values, positionals } = parseArgs({
    options: {
      out: { type: 'string' },
      base: { type: 'string' },
      repo: { type: 'string' },
      music: { type: 'string' },
      'no-auth': { type: 'boolean', default: false },
    },
    allowPositionals: true,
    strict: true,
  });

  if (positionals.length !== 1 || !values.out) {
    console.error('Usage: run.js <scenario.spec.js> --out <dir> [--base <url>] [--repo <name>] [--no-auth]');
    process.exit(1);
  }

  const raw = fs.readFileSync(positionals[0], 'utf8');
  const repoConfig = loadRepoConfig(values.repo, values.base ? new URL(values.base).host : 'localhost');
  // A scenario is a JS/PLAYWRIGHT module (`.spec.js`/`.js`/`.cjs`): the author
  // drives imperatively, calling the checkpoint()/visit() harness built below.
  // The module exports the async fn directly, or `{ run, meta }`; `meta` carries
  // name/viewport/music/hold. The sugar (see/click/fill/…) compiles to runStep
  // action objects — there is no scenario DSL; login is likewise a JS function.
  if (!/\.c?js$/i.test(positionals[0])) {
    console.error(`SCENARIO_NOT_JS "${positionals[0]}" — a scenario must be a .spec.js (or .js/.cjs) module; the markdown and JSON formats were removed (see SKILL.md).`);
    process.exit(1);
  }
  const mod = requireScenario(path.resolve(positionals[0]), raw);
  const jsScenario = typeof mod === 'function' ? mod : (typeof mod.run === 'function' ? mod.run : null);
  if (!jsScenario) throw new Error('JS scenario must export an async function (or { run, meta }) — see SKILL.md');
  const meta = mod.meta || {};
  const scenario = { name: meta.name || path.basename(positionals[0]), base: meta.base || null, holdMs: meta.hold, music: meta.music, viewport: meta.viewport };
  const base = values.base || scenario.base || 'http://localhost:3000';
  const cookieHost = scenario.cookieHost || new URL(base).host;
  const creds = values['no-auth'] ? null : repoConfig;
  const badges = loadBadges(repoConfig); // profile-owned corner art, keyed by state
  // Redaction backstop: every variable value is treated as sensitive (short
  // ones excepted — redacting "1" would mangle unrelated output).
  SECRETS = Object.values(repoConfig?.variables || {}).map(String).filter((v) => v.length >= 4);
  // The profile's `variables` map — the single home for per-repo credentials and
  // config values (the profile's login() also reads it as `vars`) — exposed to
  // the scenario as `vars` so an author references a value BY NAME (`vars.EMAIL`)
  // and never embeds the literal. The saved scenario copy therefore stays
  // faithful (redact() has nothing to scrub), and a model-free reproduce run
  // gets the same values from the profile at runtime. Any value that still
  // reaches a caption is caught by the redaction backstop (SECRETS, above).
  const vars = { ...(repoConfig?.variables || {}) };
  const viewport = scenario.viewport || { width: 1280, height: 900 };
  const outDir = path.resolve(values.out);
  const framesDir = path.join(outDir, 'frames');
  fs.rmSync(framesDir, { recursive: true, force: true }); // wipe a prior run's frames so numbering never mixes across runs
  fs.mkdirSync(framesDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, path.basename(positionals[0])), redact(raw));

  const browser = await chromium.launch({ slowMo: scenario.slowMo ?? 250 });
  const ctx = await browser.newContext({
    viewport,
    recordVideo: { dir: outDir, size: viewport },
  });

  if (!values['no-auth']) {
    const cookies = loadCookies(cookieHost);
    if (cookies.length === 0 && !creds) {
      console.error(`NO_LOGIN_CONFIG for ${values.repo || cookieHost} — create profiles/<repo>.json (see SKILL.md), save a cookie with save-cookie.js, or pass --no-auth`);
      await browser.close();
      process.exit(2);
    }
    await ctx.addCookies(cookies.map(([name, value]) => ({
      name, value, domain: new URL(base).hostname, path: '/', httpOnly: true, sameSite: 'Lax',
    })));
  }

  const page = await ctx.newPage();
  const videoStartedAt = Date.now(); // recording starts with the page
  const results = [];
  const celebrateMs = scenario.holdMs ?? CHECKPOINT_HOLD_MS; // how long a passed checkpoint holds green
  // Default the bed DETERMINISTICALLY from the scenario name (a stable string
  // hash) rather than at random: a random pick would make two runs of the same
  // scenario differ for no reason, and a model-free re-run should replay
  // identically down to the music. Distinct scenarios still get varied beds; an
  // explicit --music / meta.music always wins.
  const strHash = (s) => { let h = 0; for (let i = 0; i < s.length; i += 1) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0; return Math.abs(h); };
  let musicTrack = values.music || scenario.music || MUSIC_TRACKS[strHash(String(scenario.name)) % MUSIC_TRACKS.length];
  if (!MUSIC_TRACKS.includes(musicTrack)) {
    console.warn(`  (unknown music "${musicTrack}" — using lounge; choices: ${MUSIC_TRACKS.join(', ')})`);
    musicTrack = 'lounge';
  }
  const dwell = (ms) => spinFrames(page, ms); // static hold that still repaints for the recorder
  let failed = false;
  let reauthed = false;
  let firstContentAtSec = 0; // trims the blank lead-in before the first navigation rendered
  // Bind the page and this run's profile badges to every caption update.
  const caption = (text, state, cp = false) => setCaption(page, text, state, cp, badges);

  { // ---- scenario harness ----------------------------------------------------
    // The author's module drives; these helpers fire the caption/frame/verdict
    // machinery, so a scenario yields a steps.json of checkpoints (each flagged,
    // framed, and FAIL on any failed assertion). `page` is handed over for full
    // Playwright power; the see*/click/fill/select sugar reuses runStep so the
    // verb matching rules, click-highlight, and redaction all apply.
    let cpIndex = 0;
    let frameIdx = 0;
    let lastCap = null; // last caption shown, so visit() can re-arm the chrome a navigation wiped
    const cap = async (text, state, cp) => { lastCap = { text, state, cp }; await caption(text, state, cp); };
    const snapJs = async (record, action) => {
      frameIdx += 1;
      const frame = path.join(framesDir, `${String(frameIdx).padStart(2, '0')}-${action}.png`);
      try { await page.screenshot({ path: frame, fullPage: false }); record.frame = frame; } catch {}
    };
    // A checkpoint: the human-meaningful proof. `assert` runs Playwright (or the
    // see* sugar) and THROWS on failure; a throw records the checkpoint red and
    // FAILs the run, exactly like a false `see` assertion. The human caption
    // lives in the closed shadow root, so it can never self-match the assertion.
    const checkpoint = async (label, assert) => {
      cpIndex += 1;
      const text = redact(String(label));
      const record = { n: results.length + 1, action: 'checkpoint', checkpoint: true, caption: text };
      await cap(`⏳ ${cpIndex}  ${text}`, 'running', true);
      await dwell(CHECKPOINT_INTRO_MS);
      let error = null;
      try { await assert(); } catch (e) { error = redact(e.message.split('\n')[0]); }
      record.url = page.url();
      const n = String(cpIndex).padStart(2, '0');
      if (error) {
        record.ok = false; record.error = error; failed = true;
        console.error(`  ${n} FAIL ${text}\n     ${error}`);
        await cap(`❌ ${cpIndex}  ${text}  FAIL`, 'fail', true);
        await dwell(FAIL_HOLD_MS);
        await snapJs(record, 'checkpoint');
        results.push(record);
        return false;
      }
      record.ok = true;
      console.log(`  ${n} PASS ${text}`);
      await cap(`✅ ${cpIndex}  ${text}`, 'pass', true);
      await dwell(celebrateMs);
      await snapJs(record, 'checkpoint');
      results.push(record);
      return true;
    };
    // visit(): navigate with the same auto-login retry as a plain goto, trim
    // the video lead-in on the first navigation, then re-arm the caption chrome
    // the navigation wiped.
    const visit = async (p) => {
      try {
        await runStep(page, { action: 'goto', path: p }, base);
      } catch (e) {
        if (values['no-auth'] || reauthed || !/^AUTH_FAILED/.test(e.message)) throw e;
        reauthed = true;
        await formLogin(page, base, cookieHost, creds);
        await runStep(page, { action: 'goto', path: p }, base);
      }
      if (firstContentAtSec === 0) firstContentAtSec = Math.max(0, (Date.now() - videoStartedAt) / 1000 - 0.4);
      if (lastCap) await caption(lastCap.text, lastCap.state, lastCap.cp);
    };
    // Sugar over runStep: keeps runStep's exact matching semantics and the gold
    // click cursor on camera. Authors can also reach for `page` directly.
    const see = (text) => runStep(page, { action: 'expectText', text }, base);
    const seeElement = (css) => runStep(page, { action: 'expect', selector: css }, base);
    const seeButton = (label) => runStep(page, { action: 'expect', selector: `:is(input[type=submit][value*="${label}"], button:has-text("${label}"))` }, base);
    const click = (css) => runStep(page, { action: 'click', selector: css }, base);
    const clickText = (text) => runStep(page, { action: 'click', selector: `text=${text}` }, base);
    const fill = (css, value) => runStep(page, { action: 'fill', selector: css, value }, base);
    const select = (css, value) => runStep(page, { action: 'select', selector: css, value }, base);
    const wait = (ms) => runStep(page, { action: 'waitMs', ms }, base); // clamped to the per-step cap

    try {
      await jsScenario({ page, base, checkpoint, visit, see, seeElement, seeButton, click, clickText, fill, select, wait, vars });
    } catch (e) {
      // An uncaught error OUTSIDE a checkpoint (e.g. a plumbing click that never
      // resolved): record it red, snap a frame, and FAIL — the video still
      // finalizes below rather than the process crashing.
      failed = true;
      const msg = redact(e.message.split('\n')[0]);
      console.error(`  scenario error: ${msg}`);
      const record = { n: results.length + 1, action: 'error', checkpoint: false, caption: 'scenario error', ok: false, error: msg, url: page.url() };
      await cap(`❌ ${msg}`, 'fail', true).catch(() => {});
      await dwell(FAIL_HOLD_MS);
      await snapJs(record, 'error');
      results.push(record);
    }
  }

  const video = page.video();
  await ctx.close(); // finalizes the recording
  await browser.close();

  let videoPath = null;
  if (video) {
    const webm = await video.path();
    videoPath = path.join(outDir, 'qa.mp4');
    // Constant 30fps: real motion frames come from the dwell repaints/smooth
    // scrolling (the recorder only captures on repaint); fps=30 normalizes.
    // The lead-in before the first step's page rendered is trimmed inside the
    // filter graph (trim=start=… + setpts).
    //
    // Branding: the profile's per-state corner badge is drawn into the page
    // during the run (see loadBadges/setCaption), so nothing is overlaid here.
    // The "elevator music"
    // bed is synthesized entirely by ffmpeg's aevalsrc (no external asset, no
    // licensing) — see buildMusic for the chosen track's progression, tempo, and
    // feel — then mixed in and cut to the video length with -shortest.
    const { src: music, lowpass } = buildMusic(musicTrack);
    const filter = [
      `[0:v]trim=start=${firstContentAtSec.toFixed(2)},setpts=PTS-STARTPTS,fps=30[v]`,
      `[1:a]lowpass=f=${lowpass},afade=t=in:st=0:d=1.5[a]`
    ].join(';');
    execFileSync('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', webm,
      '-f', 'lavfi', '-i', music,
      '-filter_complex', filter,
      '-map', '[v]', '-map', '[a]', '-shortest',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k',
      videoPath
    ]);
    fs.rmSync(webm);
  }

  const verdict = failed ? 'FAIL' : 'PASS';
  const manifest = { name: scenario.name, verdict, base, music: musicTrack, viewport, steps: results, video: videoPath };
  fs.writeFileSync(path.join(outDir, 'steps.json'), redact(JSON.stringify(manifest, null, 2)));
  console.log(`\n${verdict} ${scenario.name}`);
  // The checkpoints are the QA narrative — the human-meaningful things the run
  // set out to prove. Surface them as a checklist so the verdict reads as
  // "here is what was verified", ready to drop into a PR's QA section.
  const checkpoints = results.filter((r) => r.checkpoint);
  if (checkpoints.length) {
    console.log('  checkpoints:');
    for (const c of checkpoints) console.log(`    ${c.ok ? '✓' : '✗'} ${c.caption}`);
  }
  console.log(`  video:  ${videoPath}  (music: ${musicTrack})`);
  console.log(`  frames: ${framesDir}`);
  process.exit(failed ? 1 : 0);
}

// Run as a script; stay quiet (and export the testable pieces) when required.
if (require.main === module) {
  main().catch(e => { console.error(e); process.exit(1); });
}
module.exports = { loadBadges, loadRepoConfig, formLogin, CAPTION_CSS, setCaption };
