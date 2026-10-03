// review-diff.ts - show a crewmate's change as a diff against the authoritative
// base (merge-base with the LOCAL-ONLY-aware default branch, epic-branch
// aware). The entry is bin/ac-review-diff.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-review-diff.sh as the
// oracle the differential leg of tests/sh/ac-review-diff.test.sh holds this
// module to. Read-only over the repo (`git add -N` deliberately avoided); its
// one side effect is the bin/ac-guard.sh advisory it spawns, which stamps
// state/.guard-stamp.
//
//   ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked | --graph | --graph-data
//                          | --commit <sha> | --ref <branch>] [--tree <worktree>] [--no-guard]
//
// Modes (default = committed-only, base -> branch tip: the chief/roomchief
// delivered-change review):
// - --stat: `git diff --stat <base> <head>`.
// - --live: base -> WORKING TREE (`git diff <base>`, then every untracked file
//   as a new-file diff) - the mid-task view, where most of a crewmate's change
//   has not been committed yet.
// - --uncommitted: HEAD -> working tree, tracked files only (`git diff`).
// - --untracked: untracked files only, each `git diff --no-index -- /dev/null
//   <name>` over `git ls-files --others --exclude-standard -z`: RELATIVE names,
//   so the header reads `b/<name>` (from a worktree that is a subdirectory the
//   names are relative to it and files above it are not listed); a file git
//   cannot read prints git's own error and the run goes on, exit 0; a binary
//   is `Binary files /dev/null and b/<name> differ`. The three SCM groups a
//   dashboard file list wants are the default, --uncommitted and --untracked -
//   --live is their union for a single read.
// - --commit <sha>: `git show --format='' <sha>` - one commit's own change,
//   bare diff (the dashboard graph's click-through).
// - --graph: `git log --graph --oneline --decorate --no-color -n 40 HEAD
//   --branches`, or `refs/heads/<ref>` with --ref - git's own text graph.
// - --graph-data: the topology machine-readable, newest first, one commit per
//   line, `hash<TAB>parents<TAB>refs<TAB>subject` (a root commit has an empty
//   parents field), then `#base<TAB><short merge-base>` when a merge-base
//   exists - what dashboard/lib.ts graphHtml draws the Worktrees-tab lane
//   graph from (the FOUR TAB fields and the `#base\t` prefix are the frozen
//   wire). With --ref: `git log --format='%h%x09%p%x09%D%x09%s' -n 40
//   refs/heads/<ref>` streamed as is, the trailer from merge-base(defref, the
//   ref), exit 0. Without: `log --format='%ct%x09%h%x09%p%x09%D%x09%s' -n 40
//   HEAD --branches` plus, for every refs/heads/* in for-each-ref order, the
//   same format `-n 8 <ref> --not HEAD` (an old parked tip falls outside the
//   40-newest window), the streams merged through a spawned `sort -s -t<TAB>
//   -k1,1rn` under LC_ALL=C (newest first, STABLE on ties: the HEAD stream
//   precedes the per-ref slices) and deduped like awk's `!seen[$2]++ {print
//   $2,$3,$4,$5}` - the first occurrence of a hash wins, and `$5` is the
//   subject up to its first TAB, so a subject carrying a TAB is cut there in
//   THIS path and whole in the --ref path (W2, the bash's wire, kept); then the
//   trailer from merge-base(defref, HEAD).
//
// Guard: BEFORE git is required and the arguments are read, unless `--no-guard`
// appears anywhere in argv - as a token, as the VALUE of --tree, or inside one
// argument that holds ` --no-guard ` (the bash's `case " $* "` substring test,
// kept) - <this bin/>/ac-guard.sh is spawned when executable, stdout/stderr
// inherited, status ignored. Its lines precede everything else on stderr, and
// its stamp suppresses the SAME warning on the chief's next command for 60 s,
// which is why a caller that never reads stderr (the dashboard's /api/diff)
// passes --no-guard. Then `ERROR: required tool not found: git`, exit 1.
//
// Arguments: <id> is $1 and must be non-empty, else
//   ERROR: usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked | --graph | --graph-data | --commit <sha> | --ref <branch>] [--tree <worktree>] [--no-guard]
// exit 1 (a flag in its place IS the id: `--live` reaches `no crewmate meta for
// --live`; there is no help verb). The flags follow in any order, the LAST
// mode flag winning (`--commit x --stat` renders stat). `--commit` takes the
// next token as the sha (`ERROR: --commit needs a sha` when it is missing,
// empty, or no line of it matches ^[0-9a-f]{4,40}$); `--ref` likewise
// (`ERROR: --ref needs a branch name`, ^[A-Za-z0-9][A-Za-z0-9._/-]*$); `--tree`
// takes a path (`ERROR: --tree needs a path` when missing or empty); any other
// token is `ERROR: unknown argument: <tok>`. The two regex guards were `grep
// -Eq <<<"$v"`, which passes a MULTI-LINE value when ANY of its lines matches
// (W1, kept): git then refuses the value itself (`fatal: ambiguous argument`,
// exit 128). The classes are read per their text under any locale.
//
// Resolution, in this order, every mode:
// - meta = state/<id>.meta (taskMeta; state/ minted). With --tree the tree is
//   the worktree and `git -C <tree> rev-parse --git-dir` must pass (`ERROR: not
//   a git worktree: <tree>`; a relative tree resolves against the caller's
//   cwd); no meta is required. Without: the meta must be a regular file
//   (`ERROR: no crewmate meta for <id>` - a directory named <id>.meta fails
//   too), its LAST `worktree=` value - raw bytes, a trailing space or CR
//   included, cut at a NUL as awk handed it over - must be a directory
//   (`ERROR: worktree gone: <value>`, the value printed raw, empty when the
//   line is absent); a meta that is there but unreadable ends the run with
//   metaGet's `WARN: cannot read meta file <meta>` alone, exit 1 (the bash's
//   unguarded assignment fired errexit), on the --tree path too, where the
//   meta's `project=` is still read.
// - head = `crew/<family>` (crewBranch over familyOfId: `c1-ship` is
//   `crew/c1-ship` unless data/c1/ship/ exists, then `crew/c1`) when
//   refs/heads/<that> exists, else HEAD.
// - defref = the LOCAL default branch (defaultBranch) when origin/<default> is
//   absent or STRICTLY behind it (`merge-base --is-ancestor` both ways), else
//   `origin/<default>` - a local-only fleet never pushes its default, so
//   origin's copy sits frozen behind the real one; push-mode landings live on
//   origin and it is fresh. The topology decides, never the delivery mode.
// - The epic fence, only when the meta has `project=`: epicBaseFor(id,
//   project) rc 2 is `ERROR: cannot read the ledger to resolve the epic-branch
//   fence for <id>` (every mode); rc 0 gives `<branch> [k=v ...]` - with the
//   token `push=deferred` the local refs/heads/<branch> when it exists;
//   otherwise origin/<branch> when that ref exists, else the local when it
//   exists, else defref unchanged (the base the lease was cut from: a deferred
//   feature branch is local until ship; any other epic branch is origin's when
//   origin carries it).
// - base = `git merge-base <defref> <head>`, or <head> itself when there is
//   none (a tree pinned to rewritten history: the committed view reads empty,
//   the working-tree views still render).
//
// Exit: 0; 1 for every `ERROR:` above; git's own status when a streamed git
// command fails (an empty repo: `fatal: ambiguous argument 'HEAD'`, 128, in the
// default, --stat and --graph-data modes; in the merged graph-data path the
// rows gathered before the failing log are still printed, as the pipeline
// printed them, and the trailer is not), 128+signal for a git ended by a
// signal, 127 for one that could not start. Every git is spawned with the
// original's arguments and io: diffs, show and log stream through inherited
// stdout/stderr (the bytes are git's own; a 400 KB diff is never buffered
// here) and every git inherits the caller's stdin (an external diff
// configured through GIT_EXTERNAL_DIFF may read it); the probes (rev-parse,
// show-ref, merge-base) are quiet. The untracked
// names go from `ls-files -z` to `xargs -0 -r -n1 git ... diff --no-index --
// /dev/null` without passing through this process, because a JS string cannot
// carry a file name that is not UTF-8 (a space, a newline, a leading `-`, a
// UTF-8 or non-UTF-8 name all render as git renders them); a failing
// ls-files ends the run with its status after the names it did print.
//
// Homeless (no AC_HOME): without --tree, `ERROR: <the AC_HOME refusal>` then
// `ERROR: no crewmate meta for <id>`, exit 1 (taskMeta's swallow, the bash's
// `$(ac_task_meta)` wart kept); WITH --tree the refusal is printed and the run
// goes on to render, exit 0 (W3, kept) - a staged id prints the refusal once
// more from familyOfId's data-dir test, as the bash's `$(ac_data_dir)` did. An
// AC_HOME cd cannot enter prints `ERROR: AC_HOME is not a readable directory:
// <h>` where the bash printed its own `cd:` line (the HOME RESOLUTION ruling),
// then the same as homeless. argv arrives decoded: a byte that is not UTF-8 in
// the id, a flag value or --tree reaches this module as U+FFFD (named).
//
// Consumers (byte-frozen): dashboard/app.ts /api/diff runs the entry with
// `--no-guard` and the mode flag (or `--commit <sha>`), `--tree` and `--ref`
// when given, env AC_HOME; a non-zero exit is its 404, stdout is sliced at
// 400 KB; dashboard/lib.ts graphHtml parses the graph-data wire; dashboard/
// page.ts names this entry in its truncation note. tests/sh/ac-epic-branch.
// test.sh runs `--stat` over an epic story and the unreadable-ledger refusal;
// tests/sh/ac-guard.test.sh greps the literal `ac-guard.sh` in the shim's
// text. Callers: no bin/ or src/ script runs this entry (chiefs run it by hand
// per .agents/skills/task-lifecycle and docs/getting-started.md), so there is
// no `set -e` caller to fail soft; a bun-less run answers `ERROR: required
// tool not found: bun`, exit 1, from the shim - the dashboard already runs on
// bun.
import { accessSync, constants, statSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { resolve } from "node:path";
import { crewBranch, defaultBranch, die, enterCaller, epicBaseFor, metaGet, require, taskMeta } from "./lib.ts";

const b = (s: string): Buffer => Buffer.from(s, "latin1");
const native = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
type Io = "inherit" | "ignore" | "pipe";

// The shell's status for a child: its exit, 128+signal, 127 when it could not
// start. stdin is the caller's unless a buffer is fed (xargs, sort): every git
// the bash ran inherited it, and an external diff may read it.
function run(cmd: string[], stdout: Io, stderr: Io, opts: { stdin?: Buffer; env?: Record<string, string | undefined> } = {}): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync>;
  try {
    r = Bun.spawnSync(cmd, { stdin: opts.stdin ?? "inherit", stdout, stderr, env: opts.env ?? process.env });
  } catch {
    return { status: 127, out: Buffer.alloc(0) };
  }
  const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
  return { status: r.exitCode ?? 128 + sig, out: stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

const { args } = enterCaller(process.argv.slice(2));

if (!` ${args.join(" ")} `.includes(" --no-guard ")) {
  const guard = resolve(import.meta.dir, "..", "bin", "ac-guard.sh");
  let executable = false;
  try {
    accessSync(guard, constants.X_OK);
    executable = statSync(guard).isFile();
  } catch {}
  if (executable) run([guard], "inherit", "inherit");
}
require("git");

const id = args[0] ?? "";
if (!id)
  die("usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked | --graph | --graph-data | --commit <sha> | --ref <branch>] [--tree <worktree>] [--no-guard]");
let mode = "committed";
let tree = "";
let gref = "";
let commit = "";
const anyLine = (v: string, re: RegExp): boolean => v.split("\n").some((l) => re.test(l));
for (let i = 1; i < args.length; i++) {
  const tok = args[i]!;
  switch (tok) {
    case "--stat":
    case "--live":
    case "--uncommitted":
    case "--untracked":
    case "--graph":
      mode = tok.slice(2);
      break;
    case "--graph-data":
      mode = "graphdata";
      break;
    case "--commit":
      commit = args[++i] ?? "";
      mode = "commit";
      if (!anyLine(commit, /^[0-9a-f]{4,40}$/)) die("--commit needs a sha");
      break;
    case "--tree":
      tree = args[++i] ?? "";
      if (!tree) die("--tree needs a path");
      break;
    case "--no-guard":
      break;
    case "--ref":
      gref = args[++i] ?? "";
      if (!anyLine(gref, /^[A-Za-z0-9][A-Za-z0-9._\/-]*$/)) die("--ref needs a branch name");
      break;
    default:
      die(`unknown argument: ${tok}`);
  }
}

const meta = taskMeta(id);
let worktree: string;
if (tree) {
  worktree = tree;
  if (run(["git", "-C", worktree, "rev-parse", "--git-dir"], "ignore", "ignore").status !== 0) die(`not a git worktree: ${tree}`);
} else {
  let isFile = false;
  try {
    isFile = statSync(meta).isFile();
  } catch {}
  if (!isFile) die(`no crewmate meta for ${id}`);
  let wt: string;
  try {
    wt = metaGet(meta, "worktree").replace(/\0[\s\S]*$/, "");
  } catch {
    process.exit(1);
  }
  if (wt === "" || !isDir(native(wt))) die(b(`worktree gone: ${wt}`));
  worktree = native(wt);
}
const git = (gargs: string[], stdout: Io, stderr: Io): { status: number; out: Buffer } => run(["git", "-C", worktree, ...gargs], stdout, stderr);
const gitOk = (gargs: string[]): boolean => git(gargs, "ignore", "ignore").status === 0;
// `$(git ...)`: the capture with its trailing newlines dropped, null on failure.
const gitCapture = (gargs: string[], stderr: Io): string | null => {
  const r = git(gargs, "pipe", stderr);
  return r.status === 0 ? r.out.toString("latin1").replace(/\n+$/, "") : null;
};
const streamed = (gargs: string[]): void => {
  const s = git(gargs, "inherit", "inherit").status;
  if (s !== 0) process.exit(s);
};

const branch = crewBranch(id);
const head = git(["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], "ignore", "inherit").status === 0 ? branch : "HEAD";

const dflt = defaultBranch(worktree);
let defref = `origin/${dflt}`;
if (!gitOk(["show-ref", "--verify", "--quiet", `refs/remotes/origin/${dflt}`])) defref = dflt;
else if (gitOk(["merge-base", "--is-ancestor", `origin/${dflt}`, dflt]) && !gitOk(["merge-base", "--is-ancestor", dflt, `origin/${dflt}`])) defref = dflt;

let project: string;
try {
  project = metaGet(meta, "project").replace(/\0[\s\S]*$/, "");
} catch {
  process.exit(1);
}
if (project !== "") {
  const eb = epicBaseFor(id, native(project));
  if (eb.rc === 2) die(`cannot read the ledger to resolve the epic-branch fence for ${id}`);
  if (eb.rc === 0) {
    const ebb = native(eb.entry.split(" ")[0]!);
    const deferred = ` ${eb.entry.slice(eb.entry.split(" ")[0]!.length)} `.includes(" push=deferred ");
    if (!deferred && gitOk(["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${ebb}`])) defref = `origin/${ebb}`;
    else if (gitOk(["rev-parse", "--verify", "--quiet", `refs/heads/${ebb}`])) defref = ebb;
  }
}
const base = gitCapture(["merge-base", defref, head], "ignore") ?? head;

function untrackedDiffs(): void {
  const ls = git(["ls-files", "--others", "--exclude-standard", "-z"], "pipe", "inherit");
  if (ls.out.length > 0) run(["xargs", "-0", "-r", "-n1", "git", "-C", worktree, "diff", "--no-index", "--", "/dev/null"], "inherit", "inherit", { stdin: ls.out });
  if (ls.status !== 0) process.exit(ls.status);
}

function baseTrailer(ref: string): void {
  const gb = gitCapture(["merge-base", defref, ref], "ignore");
  if (gb === null) return;
  writeSync(1, b(`#base\t${gitCapture(["rev-parse", "--short", gb], "inherit") ?? ""}\n`));
}

const GRAPH_FORMAT = "--format=%ct%x09%h%x09%p%x09%D%x09%s";
// The bash pipeline `{ log HEAD --branches; for every ref: log -n 8 <ref> --not
// HEAD } | sort | awk`: errexit inside the group stops the logs at the first
// failing one, and what reached sort is still merged and printed before the
// group's status ends the run.
function graphData(): void {
  const chunks: Buffer[] = [];
  let failed = 0;
  const first = git(["log", GRAPH_FORMAT, "-n", "40", "HEAD", "--branches"], "pipe", "inherit");
  chunks.push(first.out);
  failed = first.status;
  if (failed === 0) {
    const refs = git(["for-each-ref", "refs/heads", "--format=%(refname)"], "pipe", "inherit");
    for (const ref of refs.out.toString("latin1").split("\n")) {
      if (ref === "") continue;
      const slice = git(["log", GRAPH_FORMAT, "-n", "8", native(ref), "--not", "HEAD"], "pipe", "inherit");
      chunks.push(slice.out);
      if (slice.status !== 0) {
        failed = slice.status;
        break;
      }
    }
    if (failed === 0 && refs.status !== 0) failed = refs.status;
  }
  const sorted = run(["sort", "-s", "-t\t", "-k1,1rn"], "pipe", "inherit", { stdin: Buffer.concat(chunks), env: { ...process.env, LC_ALL: "C" } });
  if (sorted.status !== 0) process.exit(sorted.status);
  // awk's records: split on LF, the empty tail after a final LF being none.
  const lines = sorted.out.toString("latin1").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const seen = new Set<string>();
  const rows: string[] = [];
  for (const line of lines) {
    const f = line.split("\t");
    const hash = f[1] ?? "";
    if (seen.has(hash)) continue;
    seen.add(hash);
    rows.push(`${hash}\t${f[2] ?? ""}\t${f[3] ?? ""}\t${f[4] ?? ""}\n`);
  }
  const out = b(rows.join(""));
  for (let off = 0; off < out.length; ) off += writeSync(1, out, off);
  if (failed !== 0) process.exit(failed);
  baseTrailer("HEAD");
}

switch (mode) {
  case "stat":
    streamed(["diff", "--stat", base, head]);
    break;
  case "live":
    streamed(["diff", base]);
    untrackedDiffs();
    break;
  case "uncommitted":
    streamed(["diff"]);
    break;
  case "untracked":
    untrackedDiffs();
    break;
  case "commit":
    streamed(["show", "--format=", commit]);
    break;
  case "graph":
    streamed(gref ? ["log", "--graph", "--oneline", "--decorate", "--no-color", "-n", "40", `refs/heads/${gref}`] : ["log", "--graph", "--oneline", "--decorate", "--no-color", "-n", "40", "HEAD", "--branches"]);
    break;
  case "graphdata":
    if (gref) {
      streamed(["log", "--format=%h%x09%p%x09%D%x09%s", "-n", "40", `refs/heads/${gref}`]);
      baseTrailer(`refs/heads/${gref}`);
      process.exit(0);
    }
    graphData();
    break;
  default:
    streamed(["diff", base, head]);
}
