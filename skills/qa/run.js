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

const STEP_TIMEOUT_MS = 10_000;
const DEFAULT_HOLD_MS = 1500; // dwell on each state so the recording is watchable

// Caption bar injected into the page itself: perfectly synced with the video
// and included in the frames, no ffmpeg text rendering. pointer-events: none
// so it can never interfere with the flow under test.
const CAPTION_COLORS = { running: '#4a4a4a', pass: '#1d7a4f', fail: '#a32d2d' };

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
    const bar = document.getElementById('__qa_caption__');
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

async function setCaption(page, text, state = 'running') {
  await page.evaluate(([text, bg]) => {
    let el = document.getElementById('__qa_caption__');
    if (!el) {
      el = document.createElement('div');
      el.id = '__qa_caption__';
      el.style.cssText = 'position:fixed;left:0;right:0;top:0;z-index:2147483647;padding:16px 20px;font:600 24px/1.4 -apple-system,sans-serif;color:#fff;pointer-events:none;';
      document.body.appendChild(el);
    }
    el.style.background = bg;
    el.textContent = text;
  }, [text, CAPTION_COLORS[state]]).catch(() => {});
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
    case 'click':
      await page.locator(step.selector).first().click({ timeout: STEP_TIMEOUT_MS });
      break;
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
  return step.caption || `${step.action} ${step.path || step.selector || step.text || step.ms || ''}`.trim();
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
        return { ...parseStep(substituteVariables(body, config), name), caption: `${name} › ${body}` };
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
    const bullet = line.match(/^\s*[-*]\s+(.+)$/);
    if (!bullet) continue;
    const body = bullet[1].trim();

    // `run <macro>` expands a repo-defined multi-line step string inline,
    // one level deep — macros contain only primitive verbs.
    const macroCall = body.match(/^run\s+(\S+)$/i);
    if (macroCall) {
      scenario.steps.push(...macroSteps(macroCall[1], config));
      continue;
    }

    scenario.steps.push({ ...parseStep(substituteVariables(body, config)), caption: body });
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
  // Redaction backstop: every variable value is treated as sensitive (short
  // ones excepted — redacting "1" would mangle unrelated output).
  SECRETS = Object.values(repoConfig?.variables || {}).map(String).filter((v) => v.length >= 4);
  const viewport = scenario.viewport || { width: 1280, height: 900 };
  const outDir = path.resolve(values.out);
  const framesDir = path.join(outDir, 'frames');
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
  const holdMs = scenario.holdMs || DEFAULT_HOLD_MS;
  const total = scenario.steps.length;
  let failed = false;
  let reauthed = false;
  let firstContentAtSec = 0; // used to trim the blank lead-in before step 1 rendered

  for (const [i, step] of scenario.steps.entries()) {
    const n = String(i + 1).padStart(2, '0');
    const label = redact(stepLabel(step));
    const caption = `${i + 1}/${total}  ${label}`;
    const record = { n: i + 1, action: step.action, caption: label };
    await setCaption(page, `⏳ ${caption}`);
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
      record.ok = true;
      console.log(`  ${n} PASS ${label}`);
      await setCaption(page, `✅ ${caption}`, 'pass'); // navigation wipes the bar; re-set it
    } catch (e) {
      record.ok = false;
      record.error = redact(e.message.split('\n')[0]);
      failed = true;
      console.error(`  ${n} FAIL ${label}\n     ${record.error}`);
      await setCaption(page, `❌ ${caption}  FAIL`, 'fail');
    }
    if (i === 0) firstContentAtSec = Math.max(0, (Date.now() - videoStartedAt) / 1000 - 0.4);
    record.url = page.url();
    await holdWithMotion(page, holdMs);
    const frame = path.join(framesDir, `${n}-${step.action}.png`);
    try { await page.screenshot({ path: frame, fullPage: false }); record.frame = frame; } catch {}
    results.push(record);
    if (!record.ok) break; // later steps are meaningless after a failure
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
    // -ss (after -i: accurate seek) trims the blank lead-in before the first
    // step's page rendered.
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', webm, '-ss', firstContentAtSec.toFixed(2), '-vf', 'fps=30', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', videoPath]);
    fs.rmSync(webm);
  }

  const verdict = failed ? 'FAIL' : 'PASS';
  const manifest = { name: scenario.name, verdict, base, steps: results, video: videoPath };
  fs.writeFileSync(path.join(outDir, 'steps.json'), redact(JSON.stringify(manifest, null, 2)));
  console.log(`\n${verdict} ${scenario.name}`);
  console.log(`  video:  ${videoPath}`);
  console.log(`  frames: ${framesDir}`);
  process.exit(failed ? 1 : 0);
}

main().catch(e => { console.error(e); process.exit(1); });
