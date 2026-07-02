# helper (reserved)

This directory is reserved for a privileged helper used by dev-dock for actions
that need elevated permissions — e.g. killing processes owned by another user,
or inspecting system-level resources.

It is **not part of the MVP**. Today the Ports feature only touches ports and
processes the current user owns, which needs no elevation.

## Planned design

- A small, sandboxed helper installed via `SMAppService` (macOS 13+) /
  `SMJobBless`.
- Communicates with the main app over a local, authenticated XPC connection.
- Exposes the narrowest possible surface (e.g. "kill PID N") rather than a
  general command runner, in keeping with the project's security stance:
  localhost only, confirmation before destructive actions, no automatic shell
  execution.
