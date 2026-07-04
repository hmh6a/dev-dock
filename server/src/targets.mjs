// Where dev-dock can be reached, for building pairing links + QR codes: every
// local IPv4 on the machine, plus any configured public domains.
//
// Domains default to the ones dev-dock is served on; override/extend with
// DEVDOCK_DOMAINS="https://a.example,https://b.example" (comma-separated).
import os from 'node:os';

export const DOMAINS = (process.env.DEVDOCK_DOMAINS
  ? process.env.DEVDOCK_DOMAINS.split(',')
  : ['https://dev-dock.hmh.dev', 'https://dev-dock.hmh6.dev']
).map((s) => s.trim().replace(/\/+$/, '')).filter(Boolean);

// Docker/container/VM bridges (br-*, docker0, veth…) aren't reachable from a
// phone, so they'd just clutter the pairing menu. Skip them unless
// DEVDOCK_ALL_IFACES=1 asks for every interface.
const VIRTUAL_IFACE = /^(docker|br-|veth|virbr|vmnet|vboxnet|cni|flannel|cali|kube|weave)/i;

export function localIPv4s() {
  const showAll = process.env.DEVDOCK_ALL_IFACES === '1';
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    if (!showAll && VIRTUAL_IFACE.test(name)) continue;
    for (const a of ifaces[name] || []) {
      if (a.family === 'IPv4' && !a.internal) out.push(a.address);
    }
  }
  return out;
}

export function classify(ip) {
  const p = ip.split('.').map(Number);
  if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return 'Tailscale';
  if (p[0] === 10 || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) || (p[0] === 192 && p[1] === 168)) return 'LAN';
  return 'IP';
}

// [{ base: 'http://host:port' | 'https://domain', note }] — localhost, then IPs, then domains.
export function listTargets(pwaPort) {
  const t = [{ base: 'http://localhost:' + pwaPort, note: 'this machine' }];
  for (const ip of localIPv4s()) t.push({ base: 'http://' + ip + ':' + pwaPort, note: classify(ip) });
  for (const d of DOMAINS) t.push({ base: d, note: 'domain' });
  return t;
}

export const pairURL = (base, token) => base + '/?token=' + token;
