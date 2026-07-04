// Token auth for the dev-dock server. One shared secret gates every network
// client — the WebSocket bridge (Claude, the real shell, file reads) and the
// upload/media endpoints. The token is surfaced in the terminal as a QR code and
// a ?token=… link: a phone scans it, a browser opens it. Without it, nobody in.
//
// The active token is file-backed (server/.devdock-token) so it survives restarts
// and can be rotated on demand (see scripts/new-token.mjs + the SIGHUP handler).
// Pin an immutable one instead with DEVDOCK_TOKEN.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const TOKEN_FILE = process.env.DEVDOCK_TOKEN_FILE || path.resolve(__dirname, '../.devdock-token');

// 24 random bytes → 32-char URL-safe secret (~192 bits).
export function genToken() { return crypto.randomBytes(24).toString('base64url'); }

// A token set via DEVDOCK_TOKEN is pinned: immutable, no file, rotation refused.
export const TOKEN_PINNED = !!process.env.DEVDOCK_TOKEN;

// By default even localhost must present the token ("nobody enters without it").
// Set DEVDOCK_TRUST_LOCAL=1 to let genuine local processes (e.g. the VS Code
// extension on the same machine) connect without one.
const TRUST_LOCAL = process.env.DEVDOCK_TRUST_LOCAL === '1';

let current = '';

function writeFileSafe(tok) {
  try { fs.writeFileSync(TOKEN_FILE, tok, { mode: 0o600 }); } catch { /* best effort */ }
}

// Load (or create) the active token. Env pin wins; else read the file; else mint one.
export function loadToken() {
  if (TOKEN_PINNED) { current = process.env.DEVDOCK_TOKEN; return current; }
  try {
    const fromFile = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
    if (fromFile) { current = fromFile; return current; }
  } catch { /* no file yet */ }
  current = genToken();
  writeFileSafe(current);
  return current;
}

// Re-read the file — used when another process (new-token) rotated it. No-op if pinned.
export function reloadToken() {
  if (TOKEN_PINNED) return current;
  try { const t = fs.readFileSync(TOKEN_FILE, 'utf8').trim(); if (t) current = t; } catch { /* keep current */ }
  return current;
}

// Mint a brand-new token, persist it, make it active. Throws if pinned.
export function rotateToken() {
  if (TOKEN_PINNED) throw new Error('token is pinned via DEVDOCK_TOKEN — unset it to rotate');
  current = genToken();
  writeFileSafe(current);
  return current;
}

export function getToken() { return current || loadToken(); }

const stripV4 = (ip) => String(ip || '').replace(/^::ffff:/, '');

// A request is "proxied" if it arrived through a reverse proxy (e.g. `tailscale
// serve`). Such a request hits us from 127.0.0.1 but is really remote — so it
// must never be treated as trusted-local.
function proxied(req) {
  return !!(req.headers['x-forwarded-for'] || req.headers['forwarded'] || req.headers['x-real-ip']);
}

export function remoteIP(req) {
  const xff = req.headers['x-forwarded-for'];
  if (xff) return String(xff).split(',')[0].trim();
  return stripV4(req.socket?.remoteAddress);
}

function isTrustedLocal(req) {
  if (!TRUST_LOCAL || proxied(req)) return false;
  const ip = stripV4(req.socket?.remoteAddress);
  return ip === '127.0.0.1' || ip === '::1';
}

function tokenFromReq(req) {
  // ?token=… — the only channel a browser WebSocket can carry a secret on.
  try {
    const q = new URL(req.url || '/', 'http://x').searchParams.get('token');
    if (q) return q;
  } catch { /* ignore */ }
  // Header — for the VS Code extension / curl.
  if (req.headers['x-devdock-token']) return String(req.headers['x-devdock-token']);
  // Sec-WebSocket-Protocol: "devdock, <token>".
  const p = req.headers['sec-websocket-protocol'];
  if (p) { const parts = String(p).split(',').map((s) => s.trim()); if (parts.length > 1) return parts[parts.length - 1]; }
  return null;
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;         // length isn't secret (token length is fixed)
  return crypto.timingSafeEqual(ba, bb);
}

// -> { ok: boolean, reason: 'local' | 'token' | 'no-token' | 'bad-token' }
export function check(req) {
  if (isTrustedLocal(req)) return { ok: true, reason: 'local' };
  const t = tokenFromReq(req);
  if (!t) return { ok: false, reason: 'no-token' };
  if (!safeEqual(t, getToken())) return { ok: false, reason: 'bad-token' };
  return { ok: true, reason: 'token' };
}

// Best-effort human label for the connected-devices list.
export function deviceLabel(req) {
  const ua = String(req.headers['user-agent'] || '');
  const os = /iphone|ipad|ios/i.test(ua) ? 'iOS'
    : /android/i.test(ua) ? 'Android'
    : /mac os x|macintosh/i.test(ua) ? 'macOS'
    : /windows/i.test(ua) ? 'Windows'
    : /linux/i.test(ua) ? 'Linux' : '';
  const app = /vscode/i.test(ua) ? 'VS Code'
    : /edg\//i.test(ua) ? 'Edge'
    : /chrome\//i.test(ua) ? 'Chrome'
    : /firefox\//i.test(ua) ? 'Firefox'
    : /safari\//i.test(ua) ? 'Safari'
    : ua ? 'browser' : 'VS Code / CLI';
  return [app, os].filter(Boolean).join(' · ') || 'client';
}
