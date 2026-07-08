#!/usr/bin/env node
const { parseArgs } = require('node:util');
const fs = require('node:fs');
const path = require('node:path');

const COOKIES_FILE = path.join(__dirname, 'cookies.json');

const { values } = parseArgs({
  options: {
    host: { type: 'string' },
    name: { type: 'string' },
    value: { type: 'string' },
  },
  strict: true,
});

if (!values.host || !values.name || !values.value) {
  console.error('Usage: save-cookie.js --host <host:port> --name <cookie-name> --value <value>');
  process.exit(1);
}

const store = fs.existsSync(COOKIES_FILE)
  ? JSON.parse(fs.readFileSync(COOKIES_FILE, 'utf8'))
  : {};

store[values.host] = store[values.host] || {};
store[values.host][values.name] = values.value;
store[values.host].savedAt = new Date().toISOString();

fs.writeFileSync(COOKIES_FILE, JSON.stringify(store, null, 2) + '\n', { mode: 0o600 });
fs.chmodSync(COOKIES_FILE, 0o600);
console.log(`SAVED host=${values.host} name=${values.name}`);
