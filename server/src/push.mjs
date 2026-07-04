// Web Push (VAPID) so the phone gets a real OS notification when a turn finishes
// or a tool needs approval — even when the PWA is backgrounded or closed and no
// WebSocket is connected. Keys and subscriptions are file-backed so they survive
// restarts (a fresh key would silently invalidate every existing subscription).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VAPID_FILE = path.resolve(__dirname, '../.devdock-vapid.json');
const SUBS_FILE = path.resolve(__dirname, '../.devdock-subs.json');
const SUBJECT = process.env.DEVDOCK_VAPID_SUBJECT || 'mailto:dev-dock@localhost';

let webpush = null;      // lazy: web-push is optional, degrade gracefully if absent
let keys = null;         // { publicKey, privateKey }
let subs = [];           // [ PushSubscription ]
let ready = false;

function readJSON(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } }
function writeJSON(file, data) { try { fs.writeFileSync(file, JSON.stringify(data), { mode: 0o600 }); } catch (e) { console.error('push: write failed', e.message); } }

export async function init() {
  try { webpush = (await import('web-push')).default; }
  catch { console.log('· push: web-push not installed — OS notifications disabled (in-app toast still works)'); return; }

  keys = readJSON(VAPID_FILE);
  if (!keys || !keys.publicKey || !keys.privateKey) {
    keys = webpush.generateVAPIDKeys();
    writeJSON(VAPID_FILE, keys);
    console.log('· push: generated new VAPID keys');
  }
  webpush.setVapidDetails(SUBJECT, keys.publicKey, keys.privateKey);

  const stored = readJSON(SUBS_FILE);
  subs = Array.isArray(stored) ? stored.filter((s) => s && s.endpoint) : [];
  ready = true;
  console.log('· push: ready (' + subs.length + ' subscription' + (subs.length === 1 ? '' : 's') + ')');
}

export function enabled() { return ready; }
export function getPublicKey() { return keys ? keys.publicKey : null; }
export function subscriptionCount() { return subs.length; }

export function addSubscription(sub) {
  if (!sub || !sub.endpoint) return false;
  if (subs.some((s) => s.endpoint === sub.endpoint)) return true;   // already have it
  subs.push(sub);
  writeJSON(SUBS_FILE, subs);
  console.log('· push: +1 subscription (' + subs.length + ' total)');
  return true;
}

export function removeSubscription(endpoint) {
  const before = subs.length;
  subs = subs.filter((s) => s.endpoint !== endpoint);
  if (subs.length !== before) writeJSON(SUBS_FILE, subs);
  return before - subs.length;
}

// Fire-and-forget push to every subscription. Prunes ones the push service says
// are gone (404/410) so the store doesn't grow stale.
export async function notifyAll({ title, body, tag = 'dev-dock', url = '/' }) {
  if (!ready || !subs.length) return;
  const payload = JSON.stringify({ title, body, tag, url });
  const dead = [];
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification(s, payload, { TTL: 120, urgency: 'high' });
    } catch (e) {
      const code = e && e.statusCode;
      if (code === 404 || code === 410) dead.push(s.endpoint);
      // other errors (network etc.) are transient — keep the subscription
    }
  }));
  if (dead.length) { subs = subs.filter((s) => !dead.includes(s.endpoint)); writeJSON(SUBS_FILE, subs); console.log('· push: pruned ' + dead.length + ' dead subscription(s)'); }
}
