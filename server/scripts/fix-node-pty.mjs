// node-pty ships prebuilt binaries, but some npm/tar versions drop the execute
// bit on `spawn-helper`, causing "posix_spawnp failed". Restore it after install.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const prebuilds = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../node_modules/node-pty/prebuilds');
try {
  for (const platform of fs.readdirSync(prebuilds)) {
    const helper = path.join(prebuilds, platform, 'spawn-helper');
    if (fs.existsSync(helper)) { try { fs.chmodSync(helper, 0o755); } catch {} }
  }
} catch { /* node-pty not installed or no prebuilds — fine */ }
