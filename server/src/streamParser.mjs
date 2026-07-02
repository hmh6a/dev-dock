// Decodes the newline-delimited stream-json emitted by the Claude Agent SDK
// (via agent-runner/runner.mjs). Port of Swift's ClaudeStreamParser. One line
// yields zero or more events: { kind, ... }.

export function parseStreamLine(line) {
  const trimmed = (line || '').trim();
  if (!trimmed) return [];
  let obj;
  try { obj = JSON.parse(trimmed); } catch { return []; }
  const type = obj && obj.type;

  switch (type) {
    case 'system':
      if (obj.subtype !== 'init') return [];
      return [{ kind: 'sessionStarted', sessionId: obj.session_id || '', model: obj.model || '', cwd: obj.cwd || '', agents: obj.agents || [] }];

    case 'assistant': {
      const content = obj.message && obj.message.content;
      if (!Array.isArray(content)) return [];
      const events = [];
      for (const block of content) {
        if (block.type === 'text' && block.text) events.push({ kind: 'assistantText', text: block.text });
        else if (block.type === 'tool_use') events.push({ kind: 'toolUse', name: describeTool(block.name || 'tool', block.input || {}) });
      }
      return events;
    }

    case 'result':
      return [{ kind: 'result', text: obj.result || '', isError: !!obj.is_error, costUSD: typeof obj.total_cost_usd === 'number' ? obj.total_cost_usd : null }];

    case 'stream_event':
      return partialEvents(obj);

    default:
      return [];
  }
}

function partialEvents(obj) {
  const event = obj.event;
  if (!event) return [];
  if (event.type === 'content_block_delta') {
    const delta = event.delta || {};
    if (delta.type === 'text_delta' && delta.text) return [{ kind: 'assistantDelta', text: delta.text }];
    if (delta.type === 'thinking_delta' && delta.thinking) return [{ kind: 'thinkingDelta', text: delta.thinking }];
    return [];
  }
  if (event.type === 'content_block_start') {
    const block = event.content_block;
    if (block && block.type === 'text') return [{ kind: 'assistantBlockStart' }];
    return [];
  }
  return [];
}

const baseName = (p) => (p && String(p).length ? String(p).split('/').pop() : '');

// Formats a tool call like Claude Code's activity log.
export function describeTool(name, input) {
  const joined = (detail) => (detail ? `${name} ${detail}` : name);
  switch (name) {
    case 'Read': {
      let detail = baseName(input.file_path);
      if (typeof input.offset === 'number') {
        detail += typeof input.limit === 'number'
          ? ` (lines ${input.offset}-${input.offset + input.limit - 1})`
          : ` (from line ${input.offset})`;
      }
      return joined(detail);
    }
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return joined(baseName(input.file_path || input.notebook_path));
    case 'Bash':
      return joined(String((input.command || '').split('\n')[0] || '').slice(0, 70));
    case 'Grep':
    case 'Glob':
      return joined(String(input.pattern || '').slice(0, 48));
    case 'Task':
      return joined(input.description || input.subagent_type || '');
    case 'WebFetch':
      return joined(String(input.url || '').slice(0, 48));
    case 'WebSearch':
      return joined(String(input.query || '').slice(0, 48));
    default:
      return name;
  }
}
