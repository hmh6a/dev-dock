#!/usr/bin/env node
// Mint a fresh dev-dock pairing token + QR, choosing which address to encode.
//
//   cd server && npm run new-token                    (interactive: pick a target)
//   npm run new-token -- --target 4                   (non-interactive: pick #4)
//   npm run new-token -- --target dev-dock.hmh.dev    (match by substring)
//   npm run new-token -- --target all                 (link + QR for every target)
//
// Writes the token to server/.devdock-token, signals a running server (SIGHUP) to
// adopt it and disconnect old devices, then prints the pairing link(s) + QR. The
// targets are every local IP on the machine plus the domains in src/targets.mjs
// (override with DEVDOCK_DOMAINS).
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import { listTargets, pairURL } from '../src/targets.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.resolve(__dirname, '..');
const TOKEN_FILE = process.env.DEVDOCK_TOKEN_FILE || path.join(SERVER_DIR, '.devdock-token');
const PID_FILE = path.join(SERVER_DIR, '.devdock.pid');
const PWA_PORT = Number(process.env.DEVDOCK_PWA_PORT || 51890);

if (process.env.DEVDOCK_TOKEN) {
  console.error('⚠  A token is pinned via DEVDOCK_TOKEN — it cannot be rotated.');
  console.error('   Unset DEVDOCK_TOKEN and restart the server to use rotatable tokens.');
  process.exit(1);
}

const targets = listTargets(PWA_PORT);

// --- selection: --target <n|substr|all>, or DEVDOCK_TARGET, or interactive menu ---
const argv = process.argv.slice(2);
function argVal(name) {
  const i = argv.findIndex((a) => a === '--' + name || a.startsWith('--' + name + '='));
  if (i < 0) return undefined;
  return argv[i].includes('=') ? argv[i].split('=').slice(1).join('=') : argv[i + 1];
}
let sel = argVal('target') ?? process.env.DEVDOCK_TARGET;
if (sel == null && /^\d+$/.test(argv[0] || '')) sel = argv[0];   // bare number

function resolveSel(s) {
  if (s == null || s === '') return null;
  if (String(s).toLowerCase() === 'all' || s === 'a') return targets;
  const n = Number(s);
  if (Number.isInteger(n) && n >= 1 && n <= targets.length) return [targets[n - 1]];
  const m = targets.filter((t) => t.base.toLowerCase().includes(String(s).toLowerCase()));
  return m.length ? m : null;
}

// Default: prefer a domain (nicest for phones — real HTTPS), else Tailscale, else localhost.
function defaultTarget() {
  return targets.find((t) => t.note === 'domain') || targets.find((t) => t.note === 'Tailscale') || targets[0];
}

function printMenu() {
  console.log('Pick an address for the pairing QR:');
  targets.forEach((t, i) => console.log('  ' + String(i + 1).padStart(2) + ') ' + t.base.padEnd(38) + '  ' + t.note));
  console.log('   a) all of them');
}
function ask(q) {
  return new Promise((res) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(q, (a) => { rl.close(); res(a); });
  });
}

async function pickTargets() {
  const pre = resolveSel(sel);
  if (pre) return pre;
  if (!process.stdin.isTTY) return [defaultTarget()];   // piped / non-interactive
  printMenu();
  const def = defaultTarget();
  const defIdx = targets.indexOf(def) + 1;
  const ans = (await ask('> number, or "a" for all [default ' + defIdx + ']: ')).trim();
  return resolveSel(ans) || [def];
}

const chosen = await pickTargets();

// --- mint the token, persist it, and hand it to a running server ---
const token = crypto.randomBytes(24).toString('base64url');
fs.writeFileSync(TOKEN_FILE, token, { mode: 0o600 });
let notified = false;
try {
  const pid = Number(fs.readFileSync(PID_FILE, 'utf8').trim());
  if (pid) { process.kill(pid, 'SIGHUP'); notified = true; }
} catch { /* server not running, or stale/absent pidfile */ }

async function printQR(text) {
  try {
    const { default: qr } = await import('qrcode-terminal');
    await new Promise((r) => qr.generate(text, { small: true }, (s) => { console.log(s); r(); }));
  } catch { console.log('   (install qrcode-terminal in server/ to render a QR)'); }
}

console.log('');
console.log('🔐 New pairing token: ' + token);
console.log('   ' + (notified
  ? 'Running server updated — old devices disconnected; they must re-pair.'
  : 'No running server detected — it will use this token on next launch.'));
console.log('');
for (const t of chosen) {
  const url = pairURL(t.base, token);
  console.log('▶ ' + t.note + ':  ' + url);
  await printQR(url);
  console.log('');
}
