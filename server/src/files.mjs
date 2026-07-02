// Read-only file access for the Files tab, clamped to a project root. Port of
// Swift's FileBrowser.
import fs from 'node:fs';
import path from 'node:path';

const MAX_BYTES = 400_000;
const HIDDEN = new Set(['.git', '.DS_Store', '.build']);

// Resolve `p` (relative to root unless absolute) and clamp inside root.
function resolved(p, root) {
  const rootStd = path.resolve(root);
  const raw = !p ? rootStd : (path.isAbsolute(p) ? p : path.join(rootStd, p));
  const std = path.resolve(raw);
  return (std === rootStd || std.startsWith(rootStd + path.sep)) ? std : rootStd;
}

export function list(p, root) {
  const dir = resolved(p, root);
  let names;
  try {
    if (!fs.statSync(dir).isDirectory()) return { path: root, entries: [] };
    names = fs.readdirSync(dir);
  } catch { return { path: root, entries: [] }; }

  const entries = [];
  for (const name of names) {
    if (HIDDEN.has(name)) continue;
    let st;
    try { st = fs.statSync(path.join(dir, name)); } catch { continue; }
    entries.push({ name, isDir: st.isDirectory(), size: st.isDirectory() ? 0 : st.size });
  }
  entries.sort((a, b) => (a.isDir === b.isDir ? a.name.toLowerCase().localeCompare(b.name.toLowerCase()) : (a.isDir ? -1 : 1)));
  return { path: dir, entries };
}

export function read(p, root) {
  const file = resolved(p, root);
  let buf;
  try {
    if (fs.statSync(file).isDirectory()) return null;
    buf = fs.readFileSync(file);
  } catch { return null; }

  const truncated = buf.length > MAX_BYTES;
  const slice = truncated ? buf.subarray(0, MAX_BYTES) : buf;
  if (slice.includes(0)) return { path: file, content: `[binary file — ${buf.length} bytes]`, truncated: false };
  return { path: file, content: slice.toString('utf8'), truncated };
}
