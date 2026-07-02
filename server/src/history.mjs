// Reads projects + past conversations from ~/.claude/projects. Port of Swift's
// ClaudeHistoryStore.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { summarize, messages } from './transcript.mjs';

const ROOT = path.join(os.homedir(), '.claude', 'projects');
const MAX_SESSIONS = 60;

function mtime(p) { try { return fs.statSync(p).mtimeMs; } catch { return 0; } }

function jsonlFiles(dir) {
  let entries;
  try { entries = fs.readdirSync(dir); } catch { return []; }
  return entries
    .filter((n) => n.endsWith('.jsonl'))
    .map((n) => path.join(dir, n))
    .sort((a, b) => mtime(b) - mtime(a));
}

function readLines(file, max) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return []; }
  const lines = text.split('\n').filter((l) => l.length);
  return max ? lines.slice(0, max) : lines;
}

// Best-effort fallback when a transcript has no cwd.
function decodePath(encoded) {
  return encoded.startsWith('-') ? encoded.replace(/-/g, '/') : encoded;
}

/** All projects, most-recently-used first. */
export function listProjects() {
  let dirs;
  try { dirs = fs.readdirSync(ROOT, { withFileTypes: true }); } catch { return []; }
  const projects = [];
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dir = path.join(ROOT, d.name);
    const files = jsonlFiles(dir);
    if (!files.length) continue;
    const head = readLines(files[0], 5);
    const s = summarize(head);
    projects.push({
      id: d.name,
      path: s.cwd || decodePath(d.name),
      gitBranch: s.gitBranch || null,
      sessionCount: files.length,
      modified: (mtime(files[0]) || 0) / 1000, // epoch seconds
    });
  }
  return projects.sort((a, b) => b.modified - a.modified);
}

/** Sessions within a project, most recent first. */
export function listSessions(encodedID) {
  const dir = path.join(ROOT, encodedID);
  const files = jsonlFiles(dir).slice(0, MAX_SESSIONS);
  const sessions = [];
  for (const file of files) {
    const lines = readLines(file);
    const s = summarize(lines);
    if (!s.messageCount) continue;
    sessions.push({
      id: path.basename(file, '.jsonl'),
      projectPath: s.cwd || decodePath(encodedID),
      title: s.title || 'Untitled conversation',
      messageCount: s.messageCount,
      modified: (s.lastTimestamp || mtime(file) || 0) / 1000,
      gitBranch: s.gitBranch || null,
    });
  }
  return sessions.sort((a, b) => b.modified - a.modified);
}

export function sessionFile(sessionID, encodedID) {
  return path.join(ROOT, encodedID, `${sessionID}.jsonl`);
}

/** Parsed messages of one conversation. */
export function transcript(sessionID, encodedID) {
  return messages(readLines(sessionFile(sessionID, encodedID)));
}
