# agent-runner

The AI engine behind dev-dock's chat. A tiny Node adapter that drives the
**Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`) and bridges it to the
Swift app over stdio.

Why the SDK instead of the `claude` CLI? The SDK exposes a `canUseTool`
callback, which is the only supported way to surface **interactive permission
approvals** ("Allow this command? Yes / No"). The headless CLI just auto-allows
or auto-denies.

## Setup

```bash
cd agent-runner
npm install
```

The dev-dock app locates `runner.mjs` automatically (walking up from the app
binary), or via the `DEVDOCK_AGENT_RUNNER` env var.

## Protocol (newline-delimited JSON over stdio)

- **argv[2]** — config: `{ prompt, model, effort, cwd, resume, sessionId, permissionMode, allowedTools }`
- **stdout** — each Agent SDK message verbatim (CLI stream-json compatible), plus
  `{ type: "permission_request", id, tool, input }`, `{ type: "runner_error", message }`, `{ type: "runner_done" }`
- **stdin** — `{ type: "permission", id, allow, message? }` (the app's approval reply)

The app applies its access-mode policy to each request: **Read-only** auto-denies,
**Ask** prompts the user (in the app *and* the synced VS Code panel), **Full auto**
bypasses approvals entirely.
