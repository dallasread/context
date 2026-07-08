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

const STEP_TIMEOUT_MS = 2_500; // how long an assertion waits for its target; also how long a real failure takes to surface (red), so keep it tight — the app is served locally
const FAIL_HOLD_MS = 1800; // a failed step holds red a touch longer than a pass holds green, so the failure clearly reads as the end
const DEFAULT_HOLD_MS = 250; // per-step dwell when a scenario has no checkpoints (classic mode); override with `hold: <n>ms`
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

// Wait out the dwell while animating a subtle progress fill in the caption
// bar. requestAnimationFrame forces a repaint every tick, so the recording
// gets real frames through the hold instead of one long frozen frame.
async function holdWithMotion(page, ms) {
  await page.evaluate(async (ms) => {
    const host = document.getElementById('__qa_host__');
    const bar = host && host.__qaShadow && host.__qaShadow.getElementById('cap');
    const prog = document.createElement('div');
    prog.style.cssText = 'position:absolute;left:0;bottom:0;height:4px;width:0%;background:rgba(255,255,255,0.4);';
    bar?.appendChild(prog);
    const start = performance.now();
    await new Promise((resolve) => {
      const tick = (t) => {
        const f = Math.min(1, (t - start) / ms);
        prog.style.width = `${f * 100}%`;
        if (f >= 1) return resolve();
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    prog.remove();
  }, ms).catch(() => page.waitForTimeout(ms));
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
  await page.evaluate(([text, bg, badge, checkpoint, css]) => {
    // QA chrome — the caption bar and the corner badge — lives inside a CLOSED
    // shadow root, so it is completely invisible to the automation querying the
    // page under test. Playwright pierces OPEN shadow roots but cannot see
    // CLOSED ones, which is the whole point: a `see "X"` step sets the caption
    // to a label containing X, and if the chrome were in the light DOM (or an
    // open root) getByText(X) would match the caption itself and the assertion
    // could never fail. The isolation — not any text-rendering trick — is what
    // keeps text assertions honest. The closed root's handle is stashed on the
    // host element so both this function and holdWithMotion can reach in; the
    // whole thing is recreated after navigation wipes the DOM.
    let host = document.getElementById('__qa_host__');
    let shadow;
    if (!host) {
      host = document.createElement('div');
      host.id = '__qa_host__';
      host.style.pointerEvents = 'none';
      document.body.appendChild(host);
      shadow = host.attachShadow({ mode: 'closed' });
      host.__qaShadow = shadow;
      shadow.innerHTML =
        `<style>${css}</style><div id="cap"><span id="captext"></span></div><div id="badge"></div>`;
    } else {
      shadow = host.__qaShadow;
    }
    const cap = shadow.getElementById('cap');
    cap.className = checkpoint ? 'cp' : '';
    cap.style.background = bg;
    shadow.getElementById('captext').textContent = text;
    // Swap the corner badge to this state's art. The profile supplies distinct
    // art per outcome (empty when it defines none for this state → hidden), so
    // the engine just drops in whatever SVG this state maps to.
    const badgeEl = shadow.getElementById('badge');
    badgeEl.innerHTML = badge;
    badgeEl.style.display = badge ? '' : 'none';
  }, [text, CAPTION_COLORS[state], badges[state] || '', checkpoint, CAPTION_CSS]).catch(() => {});
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
    const f = path.join(__dirname, 'profiles', `${repo}.json`);
    if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8'));
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
  if (!creds?.macros?.login) throw new Error('AUTH_FAILED and no "login" macro in the repo\'s profiles/<repo>.json (see SKILL.md)');

  for (const step of macroSteps('login', creds)) {
    await runStep(page, step, base);
  }
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
    case 'waitMs':
      await page.waitForTimeout(step.ms);
      break;
    default:
      throw new Error(`Unknown action: ${step.action}`);
  }
}

function stepLabel(step) {
  return step.checkpoint || step.caption || `${step.action} ${step.path || step.selector || step.text || step.ms || ''}`.trim();
}

// A step becomes a CHECKPOINT — a human-meaningful moment tied to the change's
// goal — when the author appends " :: <caption>" to the bullet. The part before
// the first " :: " parses as the executable step (verb regexes are $-anchored,
// so the suffix must be stripped before matching); the part after is free prose
// shown prominently on camera and collected as the QA narrative. Steps without
// it stay mechanical plumbing and display their raw syntax. The delimiter needs
// surrounding spaces, so CSS pseudo-elements ("div::before") never collide.
function splitCheckpoint(body) {
  const i = body.indexOf(' :: ');
  if (i === -1) return { stepBody: body, checkpoint: null };
  return { stepBody: body.slice(0, i).trim(), checkpoint: body.slice(i + 4).trim() || null };
}

// Markdown scenario: prose and headings are free-form documentation; only
// bullets with a recognized verb execute, and the bullet text is the caption.
//   # <name>                          (first heading names the run)
//   base: http://localhost:PORT
//   - visit /a/1/domains/x.com/registration/new
//   - see "Total due today"
//   - see button "Register x.com for $"
//   - see element td.total
//   - click "Change contact"
//   - click element #submit
//   - fill #user_email with "a@b.com"
//   - select #plan with "gold"
//   - wait 500ms
// An unrecognized bullet is an error, so a typo fails loudly instead of
// silently skipping a step.
const VERBS = [
  [/^visit\s+(\S+)$/i, (m) => ({ action: 'goto', path: m[1] })],
  [/^see button "(.+)"$/i, (m) => ({ action: 'expect', selector: `:is(input[type=submit][value*="${m[1]}"], button:has-text("${m[1]}"))` })],
  [/^see element (.+)$/i, (m) => ({ action: 'expect', selector: m[1] })],
  [/^see "(.+)"$/i, (m) => ({ action: 'expectText', text: m[1] })],
  [/^click element (.+)$/i, (m) => ({ action: 'click', selector: m[1] })],
  [/^click "(.+)"$/i, (m) => ({ action: 'click', selector: `text=${m[1]}` })],
  [/^fill (.+?) with "(.*)"$/i, (m) => ({ action: 'fill', selector: m[1], value: m[2] })],
  [/^select (.+?) with "(.*)"$/i, (m) => ({ action: 'select', selector: m[1], value: m[2] })],
  [/^wait (\d+)ms$/i, (m) => ({ action: 'waitMs', ms: parseInt(m[1], 10) })],
];

function parseStep(body, context = null) {
  const verb = VERBS.find(([re]) => re.test(body));
  if (!verb) throw new Error(`UNRECOGNIZED_STEP "${body}"${context ? ` in macro "${context}"` : ''} — known verbs: visit, see, see button, see element, click, click element, fill, select, wait, run <macro>`);
  return verb[1](body.match(verb[0]));
}

// $NAME in a step body resolves from the config's "variables" map at
// execution time only — captions and evidence keep the placeholder, so
// values (credentials included) never leave the config. Unknown names stay
// literal, so prose like "$14.50" can't false-trip.
function substituteVariables(body, config) {
  return body.replace(/\$([A-Z_][A-Z0-9_]*)/g, (m, name) => (config?.variables?.[name] ?? m));
}

// A macro is a multi-line string (or array) of step bodies, leading "- "
// optional.
function macroSteps(name, config) {
  const macro = config?.macros?.[name];
  if (!macro) throw new Error(`UNKNOWN_MACRO "${name}" — define it under "macros" in the repo's profiles/<repo>.json`);
  const lines = Array.isArray(macro) ? macro : String(macro).split('\n');
  return lines
      .map((l) => String(l).trim().replace(/^[-*]\s+/, ''))
      .filter(Boolean)
      .map((body) => {
        if (/^run\s/i.test(body)) throw new Error(`NESTED_MACRO in "${name}" — macros cannot call macros`);
        const { stepBody, checkpoint } = splitCheckpoint(body);
        return { ...parseStep(substituteVariables(stepBody, config), name), caption: `${name} › ${stepBody}`, checkpoint };
      });
}

function parseMarkdownScenario(text, config = {}) {
  const scenario = { name: null, base: null, steps: [] };

  for (const line of text.split('\n')) {
    const heading = line.match(/^#\s+(.+)$/);
    if (heading && !scenario.name) { scenario.name = heading[1].trim(); continue; }
    const setting = line.match(/^base:\s*(\S+)/i);
    if (setting) { scenario.base = setting[1]; continue; }
    const hold = line.match(/^hold:\s*(\d+)ms/i);
    if (hold) { scenario.holdMs = parseInt(hold[1], 10); continue; }
    const music = line.match(/^music:\s*(\S+)/i);
    if (music) { scenario.music = music[1]; continue; }
    const viewport = line.match(/^viewport:\s*(\d+)\s*x\s*(\d+)/i);
    if (viewport) { scenario.viewport = { width: parseInt(viewport[1], 10), height: parseInt(viewport[2], 10) }; continue; }
    const bullet = line.match(/^\s*[-*]\s+(.+)$/);
    if (!bullet) continue;
    const body = bullet[1].trim();

    const { stepBody, checkpoint } = splitCheckpoint(body);

    // `run <macro>` expands a repo-defined multi-line step string inline,
    // one level deep — macros contain only primitive verbs. A checkpoint
    // caption belongs on a single primitive step, not on a macro expansion.
    const macroCall = stepBody.match(/^run\s+(\S+)$/i);
    if (macroCall) {
      if (checkpoint) throw new Error(`CHECKPOINT_ON_MACRO "${body}" — attach ":: caption" to a primitive step inside the flow, not to "run <macro>"`);
      scenario.steps.push(...macroSteps(macroCall[1], config));
      continue;
    }

    scenario.steps.push({ ...parseStep(substituteVariables(stepBody, config)), caption: stepBody, checkpoint });
  }

  if (!scenario.steps.length) throw new Error('EMPTY_SCENARIO — no recognized step bullets found');
  return scenario;
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
    console.error('Usage: run.js <scenario.md> --out <dir> [--base <url>] [--repo <name>] [--no-auth]');
    process.exit(1);
  }

  const raw = fs.readFileSync(positionals[0], 'utf8');
  const repoConfig = loadRepoConfig(values.repo, values.base ? new URL(values.base).host : 'localhost');
  const scenario = positionals[0].endsWith('.json') ? JSON.parse(raw) : parseMarkdownScenario(raw, repoConfig || {});
  const base = values.base || scenario.base || 'http://localhost:3000';
  const cookieHost = scenario.cookieHost || new URL(base).host;
  const creds = values['no-auth'] ? null : repoConfig;
  const badges = loadBadges(repoConfig); // profile-owned corner art, keyed by state
  // Redaction backstop: every variable value is treated as sensitive (short
  // ones excepted — redacting "1" would mangle unrelated output).
  SECRETS = Object.values(repoConfig?.variables || {}).map(String).filter((v) => v.length >= 4);
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
  const rawHoldMs = scenario.holdMs;                  // set only by a `hold: <n>ms` line
  const stepHoldMs = rawHoldMs ?? DEFAULT_HOLD_MS;     // per-step dwell in classic (no-checkpoint) mode
  const celebrateMs = rawHoldMs ?? CHECKPOINT_HOLD_MS; // how long a passed checkpoint holds green
  let musicTrack = values.music || scenario.music || MUSIC_TRACKS[Math.floor(Math.random() * MUSIC_TRACKS.length)];
  if (!MUSIC_TRACKS.includes(musicTrack)) {
    console.warn(`  (unknown music "${musicTrack}" — using lounge; choices: ${MUSIC_TRACKS.join(', ')})`);
    musicTrack = 'lounge';
  }
  const total = scenario.steps.length;
  // Checkpoints drive the video. The caption bar shows ONLY checkpoints: each
  // goes in-progress, the plumbing steps leading to it run off-camera under that
  // in-progress caption, then it flips green and holds a beat before the next
  // one arms. A scenario with no checkpoints falls back to captioning every step.
  const cpList = scenario.steps
    .map((s, i) => (s.checkpoint ? { i, label: redact(stepLabel(s)) } : null))
    .filter(Boolean);
  const K = cpList.length;
  const hasCheckpoints = K > 0;
  const cpCaption = (p) => (K > 1 ? `${p + 1}/${K}  ${cpList[p].label}` : cpList[p].label);
  const dwell = (ms) => spinFrames(page, ms); // static hold that still repaints for the recorder
  const snap = async (i, step, record) => {
    const frame = path.join(framesDir, `${String(i + 1).padStart(2, '0')}-${step.action}.png`);
    try { await page.screenshot({ path: frame, fullPage: false }); record.frame = frame; } catch {}
  };
  let nextCp = 0; // position in `checkpoints` of the next one not yet reached
  let failed = false;
  let reauthed = false;
  let firstContentAtSec = 0; // used to trim the blank lead-in before step 1 rendered
  // Bind the page and this run's profile badges to every caption update, so each
  // call just says what to show and which state it is.
  const caption = (text, state, cp = false) => setCaption(page, text, state, cp, badges);

  // Arm the first checkpoint's in-progress caption so it is already on screen as
  // the opening plumbing runs (the pre-content lead-in is trimmed from the mp4).
  if (hasCheckpoints) {
    await caption(`⏳ ${cpCaption(0)}`, 'running', true);
    await dwell(CHECKPOINT_INTRO_MS);
  }

  for (const [i, step] of scenario.steps.entries()) {
    const n = String(i + 1).padStart(2, '0');
    const isCheckpoint = !!step.checkpoint;
    const label = redact(stepLabel(step));
    const record = { n: i + 1, action: step.action, checkpoint: isCheckpoint, caption: label };

    // Classic mode (no checkpoints): caption every step as it runs.
    if (!hasCheckpoints) await caption(`⏳ ${i + 1}/${total}  ${label}`, 'running', false);

    let error = null;
    try {
      try {
        await runStep(page, step, base);
      } catch (e) {
        // Stale/absent session: log in through the form once and retry the step.
        if (values['no-auth'] || reauthed || !/^AUTH_FAILED/.test(e.message)) throw e;
        reauthed = true;
        await formLogin(page, base, cookieHost, creds);
        await runStep(page, step, base);
      }
    } catch (e) {
      error = redact(e.message.split('\n')[0]);
    }
    if (i === 0) firstContentAtSec = Math.max(0, (Date.now() - videoStartedAt) / 1000 - 0.4);
    record.url = page.url();

    if (error) {
      // A failure — plumbing or checkpoint — is always shown and stops the run.
      record.ok = false;
      record.error = error;
      failed = true;
      console.error(`  ${n} FAIL ${label}\n     ${error}`);
      const failCaption = hasCheckpoints && !isCheckpoint
        ? `❌ ${cpCaption(Math.min(nextCp, K - 1))}  —  FAILED: ${label}`
        : hasCheckpoints
          ? `❌ ${cpCaption(nextCp)}  FAIL`
          : `❌ ${i + 1}/${total}  ${label}  FAIL`;
      await caption(failCaption, 'fail', isCheckpoint || !hasCheckpoints);
      await dwell(FAIL_HOLD_MS);
      await snap(i, step, record);
      results.push(record);
      break;
    }

    record.ok = true;
    console.log(`  ${n} PASS ${label}`);

    if (!hasCheckpoints) {
      await caption(`✅ ${i + 1}/${total}  ${label}`, 'pass', false);
      if (stepHoldMs > 0) await holdWithMotion(page, stepHoldMs);
      else await dwell(0);
      await snap(i, step, record);
    } else if (isCheckpoint) {
      // Celebrate: flip the in-progress caption green, hold it a beat, and
      // capture this checkpoint's frame — the meaningful on-camera evidence.
      await caption(`✅ ${cpCaption(nextCp)}`, 'pass', true);
      await dwell(celebrateMs);
      await snap(i, step, record);
      nextCp += 1;
      if (nextCp < K) { // arm the next checkpoint for the plumbing that follows
        await caption(`⏳ ${cpCaption(nextCp)}`, 'running', true);
        await dwell(CHECKPOINT_INTRO_MS);
      }
    } else {
      // Plumbing: keep (and restore, since navigation wipes the chrome) the
      // in-progress checkpoint caption. No dwell, no frame — it stays off-camera.
      const done = nextCp >= K;
      await caption(`${done ? '✅' : '⏳'} ${cpCaption(done ? K - 1 : nextCp)}`, done ? 'pass' : 'running', true);
      await dwell(0);
    }
    results.push(record);
  }

  const video = page.video();
  await ctx.close(); // finalizes the recording
  await browser.close();

  let videoPath = null;
  if (video) {
    const webm = await video.path();
    videoPath = path.join(outDir, 'qa.mp4');
    // Constant 30fps: real motion frames come from holdWithMotion/smooth
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
module.exports = { loadBadges, loadRepoConfig, CAPTION_CSS };
