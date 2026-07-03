#!/usr/bin/env node
// Upload a QA video (or image) to GitHub as a user-attachments asset by
// driving the PR page's comment box in a logged-in browser profile.
//
// This script ONLY uploads and prints the resulting URL. It never posts a
// comment or edits a PR — posting is done separately (gh pr comment / gh pr
// edit) after the user has approved it.
//
// One-time setup (interactive login, headed browser):
//   node post.js --login
//
// Upload:
//   node post.js <file> --repo owner/name --pr <number>
const { parseArgs } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');

const { chromium } = require('playwright');
const PROFILE_DIR = path.join(__dirname, 'gh-profile');

const UPLOAD_TIMEOUT_MS = 120_000;

async function currentLogin(page) {
  return page.evaluate(() => document.querySelector('meta[name="user-login"]')?.content || '');
}

async function login() {
  const ctx = await chromium.launchPersistentContext(PROFILE_DIR, { headless: false });
  const page = ctx.pages()[0] || await ctx.newPage();
  await page.goto('https://github.com/login');
  console.log('Log in to GitHub in the opened browser window (including 2FA).');
  console.log('Waiting for login to complete...');
  await page.waitForFunction(
    () => (document.querySelector('meta[name="user-login"]')?.content || '') !== '',
    null,
    { timeout: 300_000 },
  );
  console.log(`LOGGED_IN user=${await currentLogin(page)} profile=${PROFILE_DIR}`);
  await ctx.close();
}

async function upload(file, repo, pr) {
  if (!fs.existsSync(file)) throw new Error(`NO_FILE ${file}`);
  if (!fs.existsSync(PROFILE_DIR)) throw new Error('NOT_LOGGED_IN — run: node post.js --login');

  const ctx = await chromium.launchPersistentContext(PROFILE_DIR, { headless: true });
  try {
    const page = ctx.pages()[0] || await ctx.newPage();
    await page.goto(`https://github.com/${repo}/pull/${pr}`, { waitUntil: 'domcontentloaded' });
    if ((await currentLogin(page)) === '') {
      throw new Error('NOT_LOGGED_IN — session expired; run: node post.js --login');
    }

    const textarea = page.locator('#new_comment_field');
    await textarea.waitFor({ state: 'attached', timeout: 15_000 });
    // The page can hold several attachment inputs (e.g. the PR-body edit
    // form's) — target the one wired to the new-comment field specifically,
    // or the upload lands in the wrong form and the wait below never resolves.
    const fileInput = page.locator('#fc-new_comment_field').or(page.locator('file-attachment:has(#new_comment_field) input[type=file]')).first();
    await fileInput.setInputFiles(file);

    // GitHub replaces a "[Uploading ...]" placeholder with the asset URL.
    await page.waitForFunction(
      () => {
        const v = document.querySelector('#new_comment_field')?.value || '';
        return v.includes('user-attachments/assets') && !v.includes('Uploading');
      },
      null,
      { timeout: UPLOAD_TIMEOUT_MS },
    );
    const value = await textarea.inputValue();
    const url = value.match(/https:\/\/github\.com\/user-attachments\/assets\/[\w-]+/)?.[0];
    if (!url) throw new Error(`UPLOAD_PARSE_FAILED textarea=${JSON.stringify(value)}`);

    await textarea.fill(''); // leave no draft behind; nothing is ever posted here
    console.log(url);
  } finally {
    await ctx.close();
  }
}

async function main() {
  const { values, positionals } = parseArgs({
    options: {
      login: { type: 'boolean', default: false },
      repo: { type: 'string' },
      pr: { type: 'string' },
    },
    allowPositionals: true,
    strict: true,
  });

  if (values.login) return login();
  if (positionals.length !== 1 || !values.repo || !values.pr) {
    console.error('Usage: post.js --login | post.js <file> --repo owner/name --pr <number>');
    process.exit(1);
  }
  return upload(positionals[0], values.repo, values.pr);
}

main().catch(e => { console.error(e.message || e); process.exit(2); });
