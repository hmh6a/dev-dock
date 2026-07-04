// Git + GitHub for the Git tab. Lists/clones repos the account can reach
// (personal + org), creates new repos, and runs status/commit/pull/push on a
// project — with a one-tap "let Claude resolve" path when a pull conflicts.
//
// Everything shells out through execFile with ARGUMENT ARRAYS (never a shell
// string), so a repo name/URL coming from the browser can't inject a command.
// Client-supplied refs are additionally validated and any value that could look
// like a git option (leading '-') is rejected. GitHub auth is delegated to the
// already-logged-in `gh` CLI, which is also wired as git's credential helper —
// so plain `git push`/`pull` over https work with no extra setup.
import { execFile } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';

const HOME = os.homedir();
// Where clones/new repos land. Defaults to ~/github (where dev-dock already lives).
export const CLONE_DIR = process.env.DEVDOCK_CLONE_DIR
  ? path.resolve(process.env.DEVDOCK_CLONE_DIR)
  : path.join(HOME, 'github');

const GIT_TIMEOUT = 120_000;    // ordinary git ops
const CLONE_TIMEOUT = 900_000;  // clone/create+clone can be slow on big repos
const GH_TIMEOUT = 45_000;
const MAX_BUF = 32 * 1024 * 1024;

// Run a command with array args (no shell). Never rejects — returns a result
// object so callers branch on `.ok`. GIT_TERMINAL_PROMPT=0 makes auth failures
// fail fast instead of hanging on a username prompt.
function run(cmd, args, { cwd, timeout = GIT_TIMEOUT } = {}) {
  return new Promise((resolve) => {
    execFile(cmd, args, {
      cwd, timeout, maxBuffer: MAX_BUF,
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
    }, (err, stdout, stderr) => {
      resolve({
        ok: !err,
        code: err && typeof err.code === 'number' ? err.code : (err ? -1 : 0),
        timedOut: !!(err && err.killed),
        stdout: stdout || '',
        stderr: stderr || '',
        error: err ? (err.message || String(err)) : null,
      });
    });
  });
}

const SAFE_SEG = /^[A-Za-z0-9._-]+$/;                       // one path segment
const SAFE_NWO = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;      // owner/repo

// Normalize whatever the user typed/tapped (owner/repo, https URL, ssh URL) into
// a clone spec. Returns null for anything that isn't a plain GitHub repo ref.
export function parseRepoRef(raw) {
  const s = String(raw || '').trim().replace(/\/+$/, '');
  if (!s || s.startsWith('-')) return null;
  let m = s.match(/^https:\/\/github\.com\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?$/i);
  if (m) return { owner: m[1], name: m[2], nameWithOwner: `${m[1]}/${m[2]}`, url: `https://github.com/${m[1]}/${m[2]}.git` };
  m = s.match(/^git@github\.com:([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?$/i);
  if (m) return { owner: m[1], name: m[2], nameWithOwner: `${m[1]}/${m[2]}`, url: `git@github.com:${m[1]}/${m[2]}.git` };
  if (SAFE_NWO.test(s)) { const [owner, name] = s.split('/'); return { owner, name, nameWithOwner: s, url: `https://github.com/${owner}/${name}.git` }; }
  return null;
}

// The git repo root for a directory (its toplevel), or null if not a work tree.
// Also serves as the "is this a git repo?" check.
export async function gitRoot(dir) {
  if (!dir) return null;
  const r = await run('git', ['rev-parse', '--show-toplevel'], { cwd: dir });
  const top = r.ok ? r.stdout.trim() : '';
  return top || null;
}

// --- discovery (GitHub) ---------------------------------------------------

// Repos the authenticated account can reach: owned + collaborator + org member,
// most-recently-updated first. One API call covers personal AND org repos.
export async function listRepos(limit = 100) {
  const r = await run('gh', ['api', '-H', 'Accept: application/vnd.github+json',
    `user/repos?per_page=${Math.min(Math.max(1, limit | 0), 100)}&sort=updated&affiliation=owner,collaborator,organization_member`],
    { timeout: GH_TIMEOUT });
  if (!r.ok) return { ok: false, error: ghError(r), repos: [] };
  let arr = [];
  try { arr = JSON.parse(r.stdout); } catch { return { ok: false, error: 'Could not parse GitHub response.', repos: [] }; }
  const repos = (Array.isArray(arr) ? arr : []).map((x) => ({
    nameWithOwner: x.full_name,
    name: x.name,
    owner: x.owner && x.owner.login,
    description: x.description || '',
    private: !!x.private,
    updatedAt: x.updated_at || x.pushed_at || '',
  })).filter((x) => x.nameWithOwner);
  return { ok: true, repos };
}

// Owners you can create a repo under: your account + every org you're a member of.
export async function listOwners() {
  const me = await run('gh', ['api', 'user', '--jq', '.login'], { timeout: GH_TIMEOUT });
  if (!me.ok) return { ok: false, error: ghError(me), owners: [] };
  const login = me.stdout.trim();
  const owners = [{ login, type: 'user' }];
  const orgs = await run('gh', ['api', 'user/orgs', '--jq', '.[].login'], { timeout: GH_TIMEOUT });
  if (orgs.ok) for (const o of orgs.stdout.split('\n').map((s) => s.trim()).filter(Boolean)) owners.push({ login: o, type: 'org' });
  return { ok: true, owners, login };
}

// --- clone / create -------------------------------------------------------

// A clone destination inside CLONE_DIR that doesn't collide (foo, foo-2, foo-3…).
function freeDest(name) {
  const safe = SAFE_SEG.test(name) ? name : name.replace(/[^A-Za-z0-9._-]/g, '-');
  let dest = path.join(CLONE_DIR, safe);
  let n = 2;
  while (fs.existsSync(dest)) dest = path.join(CLONE_DIR, `${safe}-${n++}`);
  return dest;
}

export async function clone(ref) {
  const spec = parseRepoRef(ref);
  if (!spec) return { ok: false, error: 'Not a valid GitHub repo. Use owner/repo or a github.com URL.' };
  fs.mkdirSync(CLONE_DIR, { recursive: true });
  const dest = freeDest(spec.name);
  const r = await run('git', ['clone', '--', spec.url, dest], { timeout: CLONE_TIMEOUT });
  if (!r.ok) return { ok: false, error: cleanGitErr(r), nameWithOwner: spec.nameWithOwner };
  return { ok: true, path: dest, nameWithOwner: spec.nameWithOwner };
}

// Create a new GitHub repo (with a README so it has a branch), then clone it
// locally. owner '' or your login => personal; otherwise an org you belong to.
export async function createRepo({ name, owner, isPrivate = true, description = '' }) {
  const nm = String(name || '').trim();
  if (!SAFE_SEG.test(nm)) return { ok: false, error: 'Repo name may only contain letters, numbers, . _ -' };
  const ow = String(owner || '').trim();
  if (ow && !SAFE_SEG.test(ow)) return { ok: false, error: 'Invalid owner.' };
  const slug = ow ? `${ow}/${nm}` : nm;
  fs.mkdirSync(CLONE_DIR, { recursive: true });
  const args = ['repo', 'create', slug, isPrivate ? '--private' : '--public', '--add-readme', '--clone'];
  const desc = String(description || '').slice(0, 350);
  if (desc.trim()) { args.push('--description', desc); }
  const r = await run('gh', args, { cwd: CLONE_DIR, timeout: CLONE_TIMEOUT });
  if (!r.ok) return { ok: false, error: ghError(r) };
  const dest = path.join(CLONE_DIR, nm);
  return { ok: true, path: fs.existsSync(dest) ? dest : null, nameWithOwner: slug.includes('/') ? slug : null };
}

// --- status / commit / pull / push ---------------------------------------

// Parse `git status --porcelain=v1 -b` into branch, ahead/behind, changed files.
// Unmerged (conflict) states get flagged so the UI can offer the Claude fix.
const CONFLICT_XY = new Set(['DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU']);
export async function status(root) {
  const top = await gitRoot(root);
  if (!top) return { ok: true, isRepo: false, root };
  const remotes = await run('git', ['remote'], { cwd: top });
  const hasRemote = remotes.ok && remotes.stdout.trim().length > 0;
  const r = await run('git', ['status', '--porcelain=v1', '-b', '-z'], { cwd: top });
  if (!r.ok) return { ok: false, error: cleanGitErr(r), isRepo: true, root: top };

  // -z gives NUL-separated records; the first is the `## branch` header.
  const parts = r.stdout.split('\0');
  let branch = '', ahead = 0, behind = 0, upstream = null;
  const files = [], conflicted = [];
  for (let i = 0; i < parts.length; i++) {
    const rec = parts[i];
    if (!rec) continue;
    if (rec.startsWith('## ')) {
      const head = rec.slice(3);
      const bm = head.match(/^(.+?)(?:\.\.\.(\S+))?(?:\s|$)/);
      if (bm) { branch = bm[1]; upstream = bm[2] || null; }
      const am = head.match(/ahead (\d+)/); if (am) ahead = +am[1];
      const bh = head.match(/behind (\d+)/); if (bh) behind = +bh[1];
      if (branch.startsWith('No commits yet on ')) branch = branch.replace('No commits yet on ', '');
      continue;
    }
    const xy = rec.slice(0, 2);
    const file = rec.slice(3);
    // A rename record ("R  old -> new") stores the origin path in the NEXT record.
    if (xy[0] === 'R' || xy[1] === 'R') i++;
    const entry = { path: file, xy: xy.trim() || xy, staged: xy[0] !== ' ' && xy[0] !== '?', conflict: CONFLICT_XY.has(xy) };
    files.push(entry);
    if (entry.conflict) conflicted.push(file);
  }
  return { ok: true, isRepo: true, root: top, branch, ahead, behind, upstream, hasRemote, files, conflicted, clean: files.length === 0 };
}

// Commit identity: use the repo/global git identity if set, else a GitHub-noreply
// fallback derived from the logged-in account, so a commit never fails on "please
// tell me who you are".
let _identityArgs = null;
async function identityArgs(cwd) {
  if (_identityArgs) return _identityArgs;
  const name = await run('git', ['config', 'user.name'], { cwd });
  const email = await run('git', ['config', 'user.email'], { cwd });
  if (name.ok && name.stdout.trim() && email.ok && email.stdout.trim()) { _identityArgs = []; return _identityArgs; }
  let login = 'dev-dock';
  const me = await run('gh', ['api', 'user', '--jq', '.login'], { timeout: GH_TIMEOUT });
  if (me.ok && me.stdout.trim()) login = me.stdout.trim();
  _identityArgs = ['-c', `user.name=${login}`, '-c', `user.email=${login}@users.noreply.github.com`];
  return _identityArgs;
}

export async function commit(root, message) {
  const top = await gitRoot(root);
  if (!top) return { ok: false, error: 'Not a git repository.' };
  const msg = String(message || '').trim();
  if (!msg) return { ok: false, error: 'Enter a commit message.' };
  const add = await run('git', ['add', '-A'], { cwd: top });
  if (!add.ok) return { ok: false, error: cleanGitErr(add) };
  const ident = await identityArgs(top);
  const r = await run('git', [...ident, 'commit', '-m', msg], { cwd: top });
  if (!r.ok) {
    const out = (r.stdout + r.stderr);
    if (/nothing to commit/i.test(out)) return { ok: false, error: 'Nothing to commit — the working tree is clean.' };
    return { ok: false, error: cleanGitErr(r) };
  }
  return { ok: true, output: r.stdout.trim() || 'Committed.' };
}

export async function pull(root) {
  const top = await gitRoot(root);
  if (!top) return { ok: false, error: 'Not a git repository.' };
  // Force a MERGE (not rebase). Modern git refuses divergent `pull` unless a
  // reconcile strategy is set; without --no-rebase the button would just error
  // out on divergence instead of producing the conflict the user wants to fix.
  // Identity args matter too: git checks committer identity BEFORE starting the
  // merge, so without a fallback the merge aborts (no conflict markers) on a box
  // with no git identity configured.
  const ident = await identityArgs(top);
  const r = await run('git', [...ident, 'pull', '--no-rebase', '--no-edit'], { cwd: top });
  const out = (r.stdout + '\n' + r.stderr).trim();
  // Merge conflict? Surface the unmerged files so the UI can offer the Claude fix.
  const st = await status(top);
  const conflicted = st.ok ? st.conflicted : [];
  if (conflicted && conflicted.length) return { ok: false, conflict: true, conflicted, output: out };
  if (!r.ok) {
    if (/would be overwritten|unstaged changes|commit your changes/i.test(out))
      return { ok: false, error: 'You have uncommitted changes. Commit them first, then pull.', output: out };
    return { ok: false, error: cleanGitErr(r), output: out };
  }
  return { ok: true, output: out || 'Already up to date.' };
}

export async function push(root) {
  const top = await gitRoot(root);
  if (!top) return { ok: false, error: 'Not a git repository.' };
  let r = await run('git', ['push'], { cwd: top });
  let out = (r.stdout + '\n' + r.stderr).trim();
  // No upstream yet → set it to origin/<current-branch> and retry once.
  if (!r.ok && /has no upstream branch|set-upstream/i.test(out)) {
    const br = await run('git', ['branch', '--show-current'], { cwd: top });
    const branch = br.ok ? br.stdout.trim() : '';
    if (branch) { r = await run('git', ['push', '-u', 'origin', branch], { cwd: top }); out = (r.stdout + '\n' + r.stderr).trim(); }
  }
  if (!r.ok) {
    if (/rejected|non-fast-forward|fetch first/i.test(out))
      return { ok: false, error: 'Push rejected — the remote has new commits. Pull first, then push.', output: out };
    return { ok: false, error: cleanGitErr(r), output: out };
  }
  return { ok: true, output: out || 'Pushed.' };
}

// The prompt handed to the Claude session when the user taps "let Claude fix".
// Deliberately scoped: resolve + stage, then STOP for the user to review.
export function resolvePrompt(conflicted) {
  const list = (conflicted && conflicted.length)
    ? conflicted.map((f) => `  - ${f}`).join('\n')
    : '  (run `git status` to find the unmerged files)';
  return [
    'A `git pull`/merge left this repository with unresolved merge conflicts.',
    'Conflicted files:',
    list,
    '',
    'Please resolve every conflict by editing the files: reconcile both sides so the',
    'result is correct and coherent (keep the intent of both changes where they don\'t',
    'clash), and remove ALL conflict markers (<<<<<<<, =======, >>>>>>>).',
    'Then stage the resolved files with `git add`.',
    '',
    'Do NOT commit and do NOT push — stop after staging so I can review the result',
    'and commit/push it myself. When done, briefly summarize what you changed per file.',
  ].join('\n');
}

// --- error shaping --------------------------------------------------------

function cleanGitErr(r) {
  const t = (r.stderr || r.stdout || r.error || '').trim();
  if (r.timedOut) return 'The git operation timed out.';
  // Keep it short for the phone UI — last few meaningful lines.
  const lines = t.split('\n').map((l) => l.trim()).filter(Boolean);
  return lines.slice(-4).join('\n') || 'git failed.';
}

function ghError(r) {
  const t = (r.stderr || r.error || '').trim();
  if (/gh: command not found|ENOENT/i.test(t)) return 'The GitHub CLI (gh) is not installed on the server.';
  if (/not logged|authentication|gh auth login/i.test(t)) return 'GitHub CLI is not logged in. Run `gh auth login` on the server.';
  const lines = t.split('\n').map((l) => l.trim()).filter(Boolean);
  return lines.slice(-3).join('\n') || 'GitHub request failed.';
}
