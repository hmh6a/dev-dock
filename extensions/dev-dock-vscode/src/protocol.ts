/**
 * Wire protocol shared with the macOS app. Must stay in sync with
 * `apps/macos/Sources/DevDockCore/BridgeMessage.swift`.
 * See `docs/websocket-protocol.md`.
 */

export type BridgeMessageType =
  // Editor → Dock (context updates)
  | 'hello'
  | 'workspaceInfo'
  | 'activeFile'
  | 'selection'
  // Dock → Editor (commands)
  | 'openFile'
  | 'createFile'
  | 'replaceSelection'
  | 'insertText'
  | 'runTerminalCommand'
  // Chat sync (dev-dock app ↔ extension chat panel)
  | 'chatSnapshot'
  | 'chatSend'
  | 'chatStop'
  | 'chatNew'
  | 'permissionResponse'
  // Project / conversation browsing
  | 'listProjects'
  | 'openProject'
  | 'listSessions'
  | 'resumeSession'
  | 'projectList'
  | 'sessionList'
  // Settings / lifecycle
  | 'setAutoApprove'
  | 'restartProject'
  // Terminal (interactive PTY for the phone PWA)
  | 'termOpen'
  | 'termInput'
  | 'termResize'
  | 'termClose'
  | 'termData'
  | 'termExit'
  | 'termRename'
  | 'termList'
  // File browser
  | 'listDir'
  | 'readFile'
  | 'dirList'
  | 'fileContent'
  // Meta
  | 'ack'
  | 'error';

/** One entry in a directory listing. Mirrors Swift's `FileEntryWire`. */
export interface FileEntryWire {
  name: string;
  isDir: boolean;
  size: number;
}

/** An open terminal session, shared across devices. Mirrors Swift's `TerminalWire`. */
export interface TerminalWire {
  id: string;
  title: string;
  color: string;
  projectId?: string | null;
}

/** A project available to open remotely. Mirrors Swift's `ProjectWire`. */
export interface ProjectWire {
  id: string;
  name: string;
  path: string;
  branch?: string | null;
  sessionCount: number;
  modified: number; // epoch seconds
}

/** A past conversation available to resume. Mirrors Swift's `SessionWire`. */
export interface SessionWire {
  id: string;
  title: string;
  messageCount: number;
  modified: number; // epoch seconds
}

/** One message in a synced conversation. Mirrors Swift's `ChatWireMessage`. */
export interface ChatWireMessage {
  role: 'user' | 'assistant';
  text: string;
  tools: string[];
  streaming: boolean;
  isError: boolean;
}

/** A pending tool-permission request. Mirrors Swift's `PermissionWire`. */
export interface PermissionWire {
  id: string;
  tool: string;
  title: string;
  body: string;
  /** Whether an "always allow" option is available (a third choice). */
  canRemember?: boolean;
}

export interface BridgeMessage {
  type: BridgeMessageType;
  /** Absolute path of the active workspace root. */
  workspace?: string;
  /** Absolute path of the active file. */
  file?: string;
  /** Language id of the active file (e.g. `swift`, `typescript`). */
  language?: string;
  /** Full document text or command payload text. */
  text?: string;
  /** Currently selected text in the editor. */
  selection?: string;
  /** Shell command for `runTerminalCommand`. */
  command?: string;
  /** File contents for `createFile`. */
  content?: string;
  /** 1-based line, used by `openFile`. */
  line?: number;
  /** 1-based column, used by `openFile`. */
  column?: number;
  /** Correlates a command with its `ack`/`error` reply. */
  requestId?: string;
  /** Full conversation snapshot for `chatSnapshot`. */
  chat?: ChatWireMessage[];
  /** Short status line accompanying a snapshot. */
  status?: string;
  /** A pending permission request carried in a `chatSnapshot`. */
  permission?: PermissionWire | null;
  /** Request id for a `permissionResponse`. */
  permissionId?: string;
  /** Allow/deny for a `permissionResponse`. */
  allow?: boolean;
  /** "Always allow" (persist suggested rules) for a `permissionResponse`. */
  remember?: boolean;
  /** Available projects, for a `projectList`. */
  projects?: ProjectWire[];
  /** Past conversations, for a `sessionList`. */
  sessions?: SessionWire[];
  /** Project to open (`openProject`) or list sessions for (`listSessions`). */
  projectId?: string;
  /** Conversation id to resume (`resumeSession`). */
  sessionRef?: string;
  /** Active project display name, carried in `chatSnapshot`/`sessionList`. */
  projectName?: string;
  /** Auto-approve toggle: set by `setAutoApprove`, echoed in `chatSnapshot`. */
  autoApprove?: boolean;
  /** Whether the terminal is allowed (Settings), echoed in `chatSnapshot`. */
  terminalEnabled?: boolean;
  /** Terminal session id for `term*` messages. */
  termId?: string;
  /** Base64 payload for `termInput` / `termData`. */
  data?: string;
  /** Terminal size for `termOpen` / `termResize`. */
  cols?: number;
  rows?: number;
  /** Directory entries for `dirList`. */
  entries?: FileEntryWire[];
  /** Whether a `fileContent` payload was truncated. */
  truncated?: boolean;
  /** Running session cost in USD, in `chatSnapshot`. */
  costUSD?: number;
  /** Open terminals for `termList`. */
  terminals?: TerminalWire[];
  /** Terminal tab colour for `termRename`. */
  color?: string;
  /** Whether a `termData` payload is a full scrollback replay. */
  reset?: boolean;
}
