// dev-dock agent runner.
//
// Bridges the Claude Agent SDK to the Swift app over stdio, so the app gets
// interactive permission approvals (which the raw `claude` CLI can't surface in
// headless mode). One runner process per conversation turn.
//
// Protocol (newline-delimited JSON):
//   argv[2]      : config { prompt, model, effort, cwd, resume, sessionId, permissionMode, allowedTools }
//   stdout       : each SDK message verbatim (CLI stream-json compatible), plus
//                  { type: 'permission_request', id, tool, input }
//                  { type: 'runner_error', message } / { type: 'runner_done' }
//   stdin        : { type: 'permission', id, allow: bool, message? }  (approval replies)
import { query } from '@anthropic-ai/claude-agent-sdk';

const config = JSON.parse(process.argv[2] || '{}');

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// Pending permission requests awaiting a reply from the app.
const pending = new Map();
let permCounter = 0;
let stdinBuffer = '';

process.stdin.on('data', (chunk) => {
  stdinBuffer += chunk.toString();
  let index;
  while ((index = stdinBuffer.indexOf('\n')) >= 0) {
    const line = stdinBuffer.slice(0, index);
    stdinBuffer = stdinBuffer.slice(index + 1);
    if (!line.trim()) continue;
    try {
      const message = JSON.parse(line);
      if (message.type === 'permission' && pending.has(message.id)) {
        const resolve = pending.get(message.id);
        pending.delete(message.id);
        resolve(message);
      }
    } catch {
      /* ignore malformed input */
    }
  }
});

const options = {
  model: config.model,
  cwd: config.cwd,
  includePartialMessages: true,
  permissionMode: config.permissionMode || 'default',
  // Relay every decision to the app; the app applies its access-mode policy
  // (auto-allow / auto-deny / prompt the user) and replies. The SDK's 3rd arg
  // carries a nicer prompt (title/description) and "always allow" suggestions —
  // surface them so the user gets every option, not just Allow/Deny.
  canUseTool: async (toolName, input, opts = {}) => {
    const id = `perm-${++permCounter}`;
    const suggestions = Array.isArray(opts.suggestions) ? opts.suggestions : [];
    emit({
      type: 'permission_request',
      id,
      tool: toolName,
      input,
      title: opts.title,
      description: opts.description,
      canRemember: suggestions.length > 0,
    });
    const reply = await new Promise((resolve) => pending.set(id, resolve));
    if (reply.allow) {
      const result = { behavior: 'allow', updatedInput: input };
      // "Always allow" → persist the suggested rules for the rest of the session.
      if (reply.remember && suggestions.length) result.updatedPermissions = suggestions;
      return result;
    }
    return { behavior: 'deny', message: reply.message || 'Denied by user' };
  },
};

if (config.effort) options.effort = config.effort;
// Resume an existing session, or force a fresh one with our own id (otherwise
// the SDK continues the most-recent conversation, hijacking unrelated sessions).
if (config.resume && config.sessionId) {
  options.resume = config.sessionId;
} else if (config.sessionId) {
  options.sessionId = config.sessionId;
}
if (Array.isArray(config.allowedTools) && config.allowedTools.length) {
  options.allowedTools = config.allowedTools;
}

try {
  const conversation = query({ prompt: config.prompt || '', options });
  for await (const message of conversation) {
    emit(message); // CLI stream-json compatible; the app's parser handles it
  }
} catch (error) {
  emit({ type: 'runner_error', message: String((error && error.message) || error) });
}
emit({ type: 'runner_done' });
process.exit(0);
