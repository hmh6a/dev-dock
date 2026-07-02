// Parses Claude Code `.jsonl` transcripts. Port of Swift's ClaudeTranscriptParser.
import { describeTool } from './streamParser.mjs';

function jsonObject(line) {
  const t = (line || '').trim();
  if (!t) return null;
  try { return JSON.parse(t); } catch { return null; }
}

function parseDate(v) {
  if (typeof v !== 'string') return null;
  const ms = Date.parse(v);
  return Number.isNaN(ms) ? null : ms; // epoch ms
}

function meaningful(text) {
  const t = (text || '').trim();
  if (!t) return false;
  if (t.startsWith('<')) return false;           // <ide_opened_file>, <command-name>, <system-reminder>…
  if (t.startsWith('Caveat:')) return false;
  return true;
}

// User content is a string or an array of blocks; keep visible prose only.
function cleanText(obj) {
  const message = obj.message;
  if (!message) return null;
  const content = message.content;
  if (typeof content === 'string') {
    return meaningful(content) ? content.trim() : null;
  }
  if (!Array.isArray(content)) return null;
  const parts = [];
  for (const block of content) {
    if (block && block.type === 'text' && typeof block.text === 'string' && meaningful(block.text)) {
      parts.push(block.text.trim());
    }
  }
  const joined = parts.join('\n');
  return joined || null;
}

function assistantContent(obj) {
  const message = obj.message;
  const blocks = message && message.content;
  if (!Array.isArray(blocks)) return { text: '', tools: [] };
  const parts = [];
  const tools = [];
  for (const block of blocks) {
    if (block.type === 'text' && block.text) parts.push(block.text);
    else if (block.type === 'tool_use') {
      const d = describeTool(block.name || 'tool', block.input || {});
      if (!tools.includes(d)) tools.push(d);
    }
  }
  return { text: parts.join('\n').trim(), tools };
}

/** One-line summary (title, cwd, branch, timing, count) of a transcript. */
export function summarize(lines) {
  let aiTitle = null, firstUserText = null, cwd = null, gitBranch = null;
  let firstTimestamp = null, lastTimestamp = null, messageCount = 0;

  for (const line of lines) {
    const obj = jsonObject(line);
    if (!obj) continue;
    const type = obj.type;
    if (cwd == null && typeof obj.cwd === 'string' && obj.cwd) cwd = obj.cwd;
    if (gitBranch == null && typeof obj.gitBranch === 'string' && obj.gitBranch) gitBranch = obj.gitBranch;
    const ts = parseDate(obj.timestamp);
    if (ts != null) { if (firstTimestamp == null) firstTimestamp = ts; lastTimestamp = ts; }

    if (type === 'ai-title') {
      if (obj.aiTitle) aiTitle = obj.aiTitle;
    } else if (type === 'user') {
      messageCount++;
      if (firstUserText == null && obj.isSidechain !== true) {
        const text = cleanText(obj);
        if (text) firstUserText = text;
      }
    } else if (type === 'assistant') {
      messageCount++;
    }
  }
  const title = aiTitle || (firstUserText ? firstUserText.slice(0, 80) : null);
  return { title, cwd, gitBranch, firstTimestamp, lastTimestamp, messageCount };
}

/** User/assistant messages for replaying a conversation. Skips sidechains. */
export function messages(lines) {
  const result = [];
  for (const line of lines) {
    const obj = jsonObject(line);
    if (!obj || obj.isSidechain === true) continue;
    const uuid = obj.uuid || Math.random().toString(36).slice(2);
    if (obj.type === 'user') {
      const text = cleanText(obj);
      if (text) result.push({ id: uuid, role: 'user', text, tools: [] });
    } else if (obj.type === 'assistant') {
      const { text, tools } = assistantContent(obj);
      if (text || tools.length) result.push({ id: uuid, role: 'assistant', text, tools });
    }
  }
  return result;
}
