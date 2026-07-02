// Serves the PWA (identical assets to the macOS app) plus the image upload/media
// endpoints. Port of Swift's PWAServer.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.resolve(__dirname, '../public');
const UPLOAD_DIR = path.join(os.tmpdir(), 'dev-dock-mobile');
const MAX_UPLOAD = 30_000_000;

const TYPES = { '.html': 'text/html; charset=utf-8', '.webmanifest': 'application/manifest+json', '.js': 'text/javascript; charset=utf-8', '.png': 'image/png', '.json': 'application/json' };
const cors = (type) => ({ 'Content-Type': type, 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache' });

export function startPWA(port) {
  fs.mkdirSync(UPLOAD_DIR, { recursive: true });
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    if (req.method === 'POST' && u.pathname === '/upload') return handleUpload(req, res);
    if (u.pathname === '/media') return handleMedia(u, res);
    serveStatic(u.pathname, res);
  });
  server.on('error', (e) => console.error('PWA server error:', e.message));
  server.listen(port, '0.0.0.0');
  return server;
}

function serveStatic(p, res) {
  const name = (p === '/' || p === '/index.html') ? 'index.html' : p.replace(/^\/+/, '');
  const file = path.join(PUBLIC, path.basename(name));   // flat assets; basename blocks traversal
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404, cors('text/plain')); res.end('not found'); return; }
    res.writeHead(200, cors(TYPES[path.extname(file)] || 'application/octet-stream'));
    res.end(data);
  });
}

function handleUpload(req, res) {
  const chunks = [];
  let size = 0, aborted = false;
  req.on('data', (c) => { size += c.length; if (size > MAX_UPLOAD) { aborted = true; req.destroy(); } else chunks.push(c); });
  req.on('end', () => {
    if (aborted) { res.writeHead(413, cors('text/plain')); res.end('too large'); return; }
    const ct = req.headers['content-type'] || 'image/jpeg';
    const ext = ct.includes('png') ? 'png' : ct.includes('gif') ? 'gif' : ct.includes('webp') ? 'webp' : ct.includes('heic') ? 'heic' : 'jpg';
    const file = path.join(UPLOAD_DIR, crypto.randomUUID() + '.' + ext);
    try { fs.writeFileSync(file, Buffer.concat(chunks)); res.writeHead(200, cors('application/json')); res.end(JSON.stringify({ path: file })); }
    catch { res.writeHead(500, cors('text/plain')); res.end('upload failed'); }
  });
}

// Serve an uploaded image back, restricted to the system temp dir.
function handleMedia(u, res) {
  const p = u.searchParams.get('p');
  if (!p) { res.writeHead(404, cors('text/plain')); res.end('no path'); return; }
  const file = path.resolve(p);
  const tmp = path.resolve(os.tmpdir());
  if (!(file === tmp || file.startsWith(tmp + path.sep)) || !fs.existsSync(file)) { res.writeHead(404, cors('text/plain')); res.end('not found'); return; }
  const ext = path.extname(file).toLowerCase();
  const type = ext === '.png' ? 'image/png' : ext === '.gif' ? 'image/gif' : ext === '.webp' ? 'image/webp' : ext === '.heic' ? 'image/heic' : 'image/jpeg';
  res.writeHead(200, cors(type));
  fs.createReadStream(file).pipe(res);
}
