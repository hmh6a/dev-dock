import * as vscode from 'vscode';
import * as path from 'path';
import { BridgeClient } from './bridgeClient';
import { BridgeMessage } from './protocol';
import { ChatViewProvider } from './chatView';

let client: BridgeClient | undefined;
let chatProvider: ChatViewProvider | undefined;
let statusBar: vscode.StatusBarItem;
let output: vscode.OutputChannel;

// Track conversation state across snapshots so we can notify on the transitions
// the user cares about: a new approval prompt, and a turn finishing.
let lastPermissionId: string | null = null;
let wasStreaming = false;

export function activate(context: vscode.ExtensionContext): void {
  output = vscode.window.createOutputChannel('dev-dock');
  statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBar.command = 'devDock.connect';
  updateStatusBar(false);
  statusBar.show();

  const config = vscode.workspace.getConfiguration('devDock');
  const port = config.get<number>('bridgePort', 51888);

  client = new BridgeClient(
    port,
    handleIncoming,
    (connected) => {
      updateStatusBar(connected);
      chatProvider?.setConnected(connected);
      if (connected) {
        sendContext(); // Push current state on (re)connect.
      }
    },
    (msg) => output.appendLine(msg)
  );

  // The synced chat panel — mirrors the dev-dock app conversation in real time.
  chatProvider = new ChatViewProvider({
    onSend: (text) => client?.send({ type: 'chatSend', text }),
    onStop: () => client?.send({ type: 'chatStop' }),
    onNew: () => client?.send({ type: 'chatNew' }),
    onPermission: (id, allow, message, remember) =>
      client?.send({ type: 'permissionResponse', permissionId: id, allow, text: message, remember }),
    onListProjects: () => client?.send({ type: 'listProjects' }),
    onOpenProject: (projectId) => client?.send({ type: 'openProject', projectId }),
    onListSessions: (projectId) => client?.send({ type: 'listSessions', projectId }),
    onResumeSession: (sessionRef) => client?.send({ type: 'resumeSession', sessionRef }),
    onSetAutoApprove: (on) => client?.send({ type: 'setAutoApprove', autoApprove: on }),
    onRestart: () => client?.send({ type: 'restartProject' }),
    onOpenTerminal: (cwd) => {
      const terminal = vscode.window.createTerminal({ name: `dev-dock · ${path.basename(cwd)}`, cwd });
      terminal.show();
    },
  });

  context.subscriptions.push(
    output,
    statusBar,
    { dispose: () => client?.dispose() },
    vscode.window.registerWebviewViewProvider(ChatViewProvider.viewType, chatProvider),
    vscode.commands.registerCommand('devDock.connect', () => client?.connect()),
    vscode.commands.registerCommand('devDock.disconnect', () => client?.disconnect()),
    vscode.commands.registerCommand('devDock.sendContext', () => sendContext()),
    // Keep the cockpit in sync as the user works.
    vscode.window.onDidChangeActiveTextEditor(() => sendContext()),
    vscode.window.onDidChangeTextEditorSelection(() => sendSelection())
  );

  if (config.get<boolean>('autoConnect', true)) {
    client.connect();
  }
}

export function deactivate(): void {
  client?.dispose();
}

// MARK: - Editor → Dock (context)

function sendContext(): void {
  if (!client?.isConnected) {
    return;
  }
  const folder = vscode.workspace.workspaceFolders?.[0];
  client.send({ type: 'workspaceInfo', workspace: folder?.uri.fsPath });

  const editor = vscode.window.activeTextEditor;
  if (editor) {
    client.send({
      type: 'activeFile',
      file: editor.document.uri.fsPath,
      language: editor.document.languageId,
    });
  }
  sendSelection();
}

function sendSelection(): void {
  const editor = vscode.window.activeTextEditor;
  if (!client?.isConnected || !editor) {
    return;
  }
  client.send({
    type: 'selection',
    file: editor.document.uri.fsPath,
    selection: editor.document.getText(editor.selection),
  });
}

// MARK: - Dock → Editor (commands)

async function handleIncoming(message: BridgeMessage): Promise<void> {
  // Chat sync: render the app's conversation in the panel (no ack).
  if (message.type === 'chatSnapshot') {
    const chat = message.chat ?? [];
    const streaming = chat.some((m) => m.streaming);
    const permission = message.permission ?? null;

    // Notify: a new approval prompt appeared — offer to answer it from the toast.
    const permId = permission ? permission.id : null;
    if (permId && permId !== lastPermissionId) {
      const title = permission?.title || 'Claude needs your approval';
      const actions = permission?.canRemember ? ['Allow', 'Always allow', 'Deny'] : ['Allow', 'Deny'];
      vscode.window.showWarningMessage(`dev-dock — ${title}`, ...actions).then((choice) => {
        if (!choice) return;
        client?.send({
          type: 'permissionResponse',
          permissionId: permId,
          allow: choice === 'Allow' || choice === 'Always allow',
          remember: choice === 'Always allow',
        });
      });
    }
    lastPermissionId = permId;

    // Notify: the turn just finished.
    if (wasStreaming && !streaming && !permission) {
      vscode.window.showInformationMessage('dev-dock — Claude finished responding.');
    }
    wasStreaming = streaming;

    chatProvider?.update(chat, message.status ?? '', permission, message.projectName, message.autoApprove);
    return;
  }
  // Project / conversation browsing snapshots.
  if (message.type === 'projectList') {
    chatProvider?.updateProjects(message.projects ?? []);
    return;
  }
  if (message.type === 'sessionList') {
    chatProvider?.updateSessions(message.sessions ?? [], message.projectName);
    return;
  }

  try {
    switch (message.type) {
      case 'openFile':
        await openFile(message);
        break;
      case 'createFile':
        await createFile(message);
        break;
      case 'replaceSelection':
        await replaceSelection(message);
        break;
      case 'insertText':
        await insertText(message);
        break;
      case 'runTerminalCommand':
        runTerminalCommand(message);
        break;
      default:
        return; // Ignore context/meta echoes.
    }
    client?.send({ type: 'ack', requestId: message.requestId });
  } catch (error) {
    const text = error instanceof Error ? error.message : String(error);
    output.appendLine(`Command '${message.type}' failed: ${text}`);
    client?.send({ type: 'error', text, requestId: message.requestId });
  }
}

async function openFile(message: BridgeMessage): Promise<void> {
  if (!message.file) {
    throw new Error('openFile requires "file"');
  }
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(message.file));
  const editor = await vscode.window.showTextDocument(doc);
  if (message.line !== undefined) {
    const line = Math.max(0, message.line - 1);
    const column = Math.max(0, (message.column ?? 1) - 1);
    const position = new vscode.Position(line, column);
    editor.selection = new vscode.Selection(position, position);
    editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenter);
  }
}

async function createFile(message: BridgeMessage): Promise<void> {
  if (!message.file) {
    throw new Error('createFile requires "file"');
  }
  const root = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  const target = path.isAbsolute(message.file) || !root
    ? message.file
    : path.join(root, message.file);
  const uri = vscode.Uri.file(target);
  await vscode.workspace.fs.writeFile(uri, Buffer.from(message.content ?? '', 'utf8'));
  const doc = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(doc);
}

async function replaceSelection(message: BridgeMessage): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    throw new Error('No active editor');
  }
  await editor.edit((builder) => builder.replace(editor.selection, message.text ?? ''));
}

async function insertText(message: BridgeMessage): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    throw new Error('No active editor');
  }
  await editor.edit((builder) => builder.insert(editor.selection.active, message.text ?? ''));
}

function runTerminalCommand(message: BridgeMessage): void {
  if (!message.command) {
    throw new Error('runTerminalCommand requires "command"');
  }
  const terminal = vscode.window.activeTerminal ?? vscode.window.createTerminal('dev-dock');
  terminal.show();
  terminal.sendText(message.command);
}

// MARK: - Status bar

function updateStatusBar(connected: boolean): void {
  statusBar.text = connected ? '$(plug) dev-dock' : '$(debug-disconnect) dev-dock';
  statusBar.tooltip = connected
    ? 'Connected to dev-dock cockpit'
    : 'dev-dock: click to connect';
}
