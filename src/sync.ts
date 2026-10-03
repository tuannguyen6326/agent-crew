// sync.ts - keep project clones fresh: fetch, fast-forward the checked-out
// default branch, and prune local branches whose upstream is gone. The entry
// is bin/ac-sync.sh (a shim that starts this file through bin/ac-bun.sh);
// THIS header is the authoritative spec, and the bash original it replaced
// stays frozen at tests/fixtures/ac-sync.sh as the oracle the differential
// leg of tests/sh/ac-sync.test.sh holds this module to.
//
// Usage:
//   ac-sync.sh [<project>]
//     <project> is a name under projects/ or a path to (inside) a repo;
//     with no argument every git repo under projects/ is swept.
//
// ARGUMENTS: a first argument starting with `-` (-h, --help, a lone `-`) or
// more than one argument prints this header on stdout, exit 2. <project> is
// resolved by projectDir (src/lib.ts, the ac_project_dir + ac_repo_root
// twin): a DIRECTORY argument first - any path in or inside a repo, relative
// to the caller's cwd, a trailing slash or a subdirectory fine, a linked
// worktree resolving to its MAIN repo, a symlink to its physical target -
// else projects/<project>; neither, or a directory that is no repo, is
// `ERROR: no such project: <project>` on stderr, exit 1. The directory rung
// never consults the home; the name rung does, through a swallowed
// substitution in the original: homeless, it prints `ERROR: <AC_HOME
// refusal>` and then `ERROR: no such project: <project>` - TWO lines, kept.
// No argument: `ERROR: <AC_HOME refusal>` exit 1 when homeless; else every
// child directory of projects/ (minted if absent; symlinks to directories
// included, dot names excluded) in BYTE order - a child that is no repo is
// `WARN: skip <child>: not a git repository` on stderr and the sweep goes on;
// no child at all is `WARN: no projects under <projects dir>`, exit 0.
// stdin is never read.
//
// PER PROJECT, one line on stdout in this order; <name> is the basename of
// the PHYSICAL repo root (a symlinked projects/<link> -> /x/src reports
// `src`; kept - a wart of the original):
// - `fresh <name> (no origin)` when `git remote get-url origin` fails: no
//   fetch, no prune, the project counts as fresh.
// - the fetch, `git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=<t> fetch
//   origin --prune --quiet` with its stdout and stderr discarded, bounded by
//   <t> seconds: AC_SYNC_TIMEOUT when set and non-empty, else
//   config/sync-timeout (first line, whitespace and CR trimmed; one this user
//   cannot read is "", as is the knob of an AC_HOME that cannot be entered -
//   the sweep goes on, and the knob is not read at all under a non-empty
//   AC_SYNC_TIMEOUT), else 60; a
//   value that is not all ASCII digits reads as 60 (`007` stays `007` on the
//   git command line and in the line below, and times out after 7 s).
//   Timed out: `FAILED <name>: fetch timed out after <t>s`, exit 1, NO prune
//   pass. Any other non-zero status: `FAILED <name>: fetch origin failed
//   (exit <rc>)`, exit 1, no prune - <rc> is the shell's reading of the
//   child (128 for an unreachable path, 128+signal for a fetch some other
//   process killed, 127 for a git that cannot start).
// - then exactly one of, with <branch> the default branch (origin/HEAD, else
//   main, else master, else the checked-out one), <behind>/<ahead> the
//   `rev-list --count` of the two ranges (a missing ref counts 0):
//     fresh <name>                                              behind = 0, whatever ahead is
//     STUCK <name>: checked out <cur>, not <branch> (<behind> commits behind)
//                                                               <cur> = `symbolic-ref --short HEAD`, `detached HEAD` when it prints nothing
//     STUCK <name>: dirty tree (<behind> commits behind)        `status --porcelain` has a line not starting with `??` (untracked never counts)
//     STUCK <name>: diverged, ahead <ahead> (<behind> commits behind)
//     synced <name>: <branch> <old>..<new>                      `merge --ff-only --quiet origin/<branch>` succeeded; <old>/<new> are `rev-parse --short HEAD` before and after
//     STUCK <name>: fast-forward failed (<behind> commits behind)
//                                                               git refused the merge (an untracked file in the way, a locked index)
//   Every STUCK line exits 1 and the working tree is never touched.
// - then the prune pass, STUCK or not: every `refs/heads` ref whose
//   `%(upstream:track)` is exactly `[gone]`, in `for-each-ref` order, is
//     kept <name>: branch <b> (upstream gone, still in use)     <b> is checked out in some worktree of the repo (`worktree list --porcelain`), or is `crew/<task>` for a slot meta <repo>/.crew/slots/*.meta whose LAST `leased=` line is `1` and whose `task=` is non-empty, each value cut at its first NUL as awk handed it over (read-only; the pool owns the records)
//     pruned <name>: branch <b> (upstream gone)                 after `git branch -D <b>`
//     kept <name>: branch <b> (upstream gone, delete refused)   `branch -D` failed
//   An unreadable slot meta prints `WARN: cannot read meta file <path>` on
//   stderr and its lease is IGNORED - the branch prunes (kept - fail-open,
//   a wart of the original). The slot scan runs only when some branch is
//   gone, so the WARN appears only then.
//
// EXIT: 0 when every project is synced or fresh; 1 when any project was
// STUCK or FAILED (the sweep still visits every project); 2 usage.
//
// THE BOUNDED FETCH reproduces fetch_bounded's mechanics, not its bytes: the
// fetch is spawned DETACHED (node:child_process - Bun.spawn has no detached
// option), so it leads its own process group as a job backgrounded under
// `set -m` did, and the deadline kills the GROUP - TERM, `sleep 0.5`, KILL,
// then the leader is reaped - so a transport helper git forked (`git
// remote-ext` for an `ext::` URL, and the command under it) dies with it
// instead of living on under ppid 1. Liveness is polled every `sleep 0.2`
// (the sleeps are spawned so a PATH stub binds both sides); the clock is the
// shell's integer `$SECONDS`: whole wall-clock seconds, so a deadline of N
// fires at the first poll after the Nth second boundary (N=0 on the first
// poll; N=1 anywhere in (0, 1.2] s). A value past 2^63 never fires, as bash's
// `[ -ge ]` refused the comparison (kept - W3): the fetch runs to its own
// end. A fetch that ends before the deadline answers its own status; the
// timeout answers 124 whatever killed it.
//
// GIT: every result is git's - `git -C <repo>` spawns with the original's
// arguments and the original's handling of each one's output:
// remote get-url (quiet), the fetch (discarded), symbolic-ref --quiet --short
// HEAD, rev-list --count x2 (stderr dropped), status --porcelain (stderr
// dropped), rev-parse --short HEAD x2, merge --ff-only --quiet (quiet),
// for-each-ref (stderr passes through), worktree list --porcelain (stderr
// dropped), branch -D (quiet), plus defaultBranch's symbolic-ref/show-ref and
// projectDir's rev-parse --git-common-dir. The fetch's `-c` options stay on
// the command line as given. Byte order replaces the shell's glob order for
// projects/ and the slot metas (the LC_ALL=C sort idiom; the leg runs the
// oracle under LC_ALL=C). Ref names, meta values and the lines built from
// them are bytes end to end (latin1 in, latin1 out).
//
// DIVERGENCES from the original, named in the differential leg: `-h` prints
// THIS header where the original printed its bash header (same exit 2); a
// path or ref name holding a byte that is not UTF-8 reaches Bun's argv as
// U+FFFD, so such a name prints as that character where the original echoed
// the byte; bash's own `[: integer expression expected` under a 2^63+
// timeout was already silenced by the original's `2>/dev/null` block, so
// nothing of the shell's reaches the reader on either side.
//
// CALLERS: none in bin/, src/, dashboard/, .agents/ or .claude/ runs this
// entry - bin/ac-session-start.sh's digest prints `run bin/ac-sync.sh ...` as
// a suggestion and deliberately never runs it; captains and chiefs run it by
// hand (standing jobs may name it in prose). Without bun the shim prints
// `ERROR: required tool not found: bun` and exits 1 to that hand; no `set -e`
// caller dies silently, so nothing fails soft.
import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { basename } from "node:path";
import { configRead, defaultBranch, die, enterCaller, metaGet, physicalDir, projectDir, projectsDir, warn } from "./lib.ts";

// Lines are bytes: git's output is read as latin1 and written back as the
// same bytes; a path from argv or readdir is UTF-8 and joins them as bytes.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const say = (line: string): void => {
  writeSync(1, Buffer.from(`${line}\n`, "latin1"));
};

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// A git that cannot be launched reads as the shell read it: status 127,
// nothing captured.
function git(repo: string, args: string[], stdout: "pipe" | "ignore", stderr: "ignore" | "inherit"): { rc: number; out: string } {
  try {
    // stdin is the caller's, as every git the bash ran inherited it.
    const r = Bun.spawnSync(["git", "-C", repo, ...args.map(u8)], { stdin: "inherit", stdout, stderr, env: process.env });
    const sig = r.signalCode ? ((osConstants.signals as Record<string, number>)[r.signalCode] ?? 0) : 0;
    return { rc: r.exitCode ?? 128 + sig, out: stdout === "pipe" ? r.stdout.toString("latin1") : "" };
  } catch {
    return { rc: 127, out: "" };
  }
}
// `$(...)`: trailing newlines dropped.
const captured = (s: string): string => s.replace(/\n+$/, "");

// awk's default field split: runs of blanks, the ends trimmed.
const awkFields = (line: string): string[] => line.replace(/^[ \t]+|[ \t]+$/g, "").split(/[ \t]+/);

// `${AC_SYNC_TIMEOUT:-$(ac_config_read ...)}`: the knob is read only when the
// override is empty, and inside `$(...)` an AC_HOME that cannot be entered
// (cd's own line on stderr) or a knob this user cannot read (head's) read as
// "" - neither line is reproduced, the digit check falls back to 60 and the
// sweep goes on.
function syncTimeout(): string {
  let t = process.env.AC_SYNC_TIMEOUT || "";
  if (!t) {
    const h = process.env.AC_HOME;
    if (!h || physicalDir(h)) {
      try {
        t = configRead("sync-timeout", "60");
      } catch {}
    }
  }
  return /^[0-9]+$/.test(t) ? t : "60";
}

const sleep = async (secs: string): Promise<void> => {
  await Bun.spawn(["sleep", secs], { stdin: "ignore", stdout: "ignore", stderr: "ignore", env: process.env }).exited;
};

async function fetchBounded(repo: string, secs: string): Promise<number> {
  // stdin stays the caller's (a backgrounded job under `set -m` kept it);
  // stdout and stderr were discarded.
  const child = spawn("git", ["-C", repo, "-c", "http.lowSpeedLimit=1", `-c`, `http.lowSpeedTime=${secs}`, "fetch", "origin", "--prune", "--quiet"], {
    detached: true,
    stdio: ["inherit", "ignore", "ignore"],
    env: process.env,
  });
  let status: number | null = null;
  const ended = new Promise<void>((resolve) => {
    child.on("exit", (code, signal) => {
      status = code ?? 128 + ((osConstants.signals as Record<string, number>)[signal ?? ""] ?? 0);
      resolve();
    });
    child.on("error", () => {
      status = 127;
      resolve();
    });
  });
  if (child.pid === undefined) {
    await ended;
    return status!;
  }
  const limit = Number(secs);
  const start = Math.floor(Date.now() / 1000);
  const killGroup = (sig: "SIGTERM" | "SIGKILL"): void => {
    try {
      process.kill(-child.pid!, sig);
    } catch {}
  };
  while (status === null) {
    if (Math.floor(Date.now() / 1000) - start >= limit) {
      killGroup("SIGTERM");
      await sleep("0.5");
      killGroup("SIGKILL");
      await ended;
      return 124;
    }
    await sleep("0.2");
  }
  return status;
}

function neededBranches(repo: string): string[] {
  const needed: string[] = [];
  for (const line of git(repo, ["worktree", "list", "--porcelain"], "pipe", "ignore").out.split("\n")) {
    if (line.startsWith("branch ")) needed.push((awkFields(line)[1] ?? "").replace("refs/heads/", ""));
  }
  const slots = `${repo}/.crew/slots`;
  let metas: string[] = [];
  try {
    metas = readdirSync(slots);
  } catch {}
  metas = metas.filter((m) => !m.startsWith(".") && m.endsWith(".meta")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const m of metas) {
    const f = `${slots}/${m}`;
    try {
      if (!statSync(f).isFile()) continue;
    } catch {
      continue;
    }
    // `[ "$(ac_meta_get ...)" = 1 ]`: the WARN of an unreadable meta has been
    // printed and its substitution read as "" - the lease is ignored; a value
    // is awk's C string, cut at its first NUL.
    let leased = "";
    try {
      leased = metaGet(f, "leased").replace(/\0[\s\S]*$/, "");
    } catch {}
    if (leased !== "1") continue;
    let task = "";
    try {
      task = metaGet(f, "task").replace(/\0[\s\S]*$/, "");
    } catch {}
    if (task !== "") needed.push(`crew/${task}`);
  }
  return needed;
}

function pruneGoneBranches(repo: string, name: string): void {
  const gone: string[] = [];
  for (const line of git(repo, ["for-each-ref", "--format=%(refname:short) %(upstream:track)", "refs/heads"], "pipe", "inherit").out.split("\n")) {
    const f = awkFields(line);
    if (f[1] === "[gone]") gone.push(f[0]!);
  }
  if (gone.length === 0) return;
  const needed = neededBranches(repo);
  for (const b of gone) {
    if (b === "") continue;
    if (needed.includes(b)) {
      say(`kept ${name}: branch ${b} (upstream gone, still in use)`);
      continue;
    }
    if (git(repo, ["branch", "-D", b], "ignore", "ignore").rc === 0) say(`pruned ${name}: branch ${b} (upstream gone)`);
    else say(`kept ${name}: branch ${b} (upstream gone, delete refused)`);
  }
}

async function syncProject(repo: string): Promise<number> {
  const name = b8(basename(repo));
  if (git(repo, ["remote", "get-url", "origin"], "ignore", "ignore").rc !== 0) {
    say(`fresh ${name} (no origin)`);
    return 0;
  }
  const t = syncTimeout();
  const frc = await fetchBounded(repo, t);
  if (frc === 124) {
    say(`FAILED ${name}: fetch timed out after ${t}s`);
    return 1;
  }
  if (frc !== 0) {
    say(`FAILED ${name}: fetch origin failed (exit ${frc})`);
    return 1;
  }

  const branch = b8(defaultBranch(repo));
  const cur = captured(git(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"], "pipe", "inherit").out);
  // `$(git rev-list ... 2>/dev/null || printf 0)`: whatever git printed, then
  // a 0 when it failed.
  const count = (range: string): string => {
    const r = git(repo, ["rev-list", "--count", range], "pipe", "ignore");
    return captured(r.out + (r.rc === 0 ? "" : "0"));
  };
  const behind = count(`refs/heads/${branch}..refs/remotes/origin/${branch}`);
  const ahead = count(`refs/remotes/origin/${branch}..refs/heads/${branch}`);

  let rc = 0;
  if (behind === "0") say(`fresh ${name}`);
  else if (cur !== branch) {
    say(`STUCK ${name}: checked out ${cur || "detached HEAD"}, not ${branch} (${behind} commits behind)`);
    rc = 1;
  } else if (git(repo, ["status", "--porcelain"], "pipe", "ignore").out.split("\n").some((l) => l !== "" && !l.startsWith("??"))) {
    say(`STUCK ${name}: dirty tree (${behind} commits behind)`);
    rc = 1;
  } else if (ahead !== "0") {
    say(`STUCK ${name}: diverged, ahead ${ahead} (${behind} commits behind)`);
    rc = 1;
  } else {
    const old = captured(git(repo, ["rev-parse", "--short", "HEAD"], "pipe", "inherit").out);
    if (git(repo, ["merge", "--ff-only", "--quiet", `origin/${branch}`], "ignore", "ignore").rc === 0) {
      const now = captured(git(repo, ["rev-parse", "--short", "HEAD"], "pipe", "inherit").out);
      say(`synced ${name}: ${branch} ${old}..${now}`);
    } else {
      say(`STUCK ${name}: fast-forward failed (${behind} commits behind)`);
      rc = 1;
    }
  }

  pruneGoneBranches(repo, name);
  return rc;
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(2);
}

const callerCwd = process.argv[2] ?? "";
const { args, atCaller } = enterCaller(process.argv.slice(2));
const target = args[0] ?? "";
if (target.startsWith("-") || args.length > 1) usage();
let bad = 0;
if (target !== "") {
  // A caller cwd bun could not enter leaves this process in the distro root;
  // a relative directory argument is still the caller's.
  const probe = !atCaller && callerCwd !== "" && !target.startsWith("/") && isDir(`${callerCwd}/${target}`) ? `${callerCwd}/${target}` : target;
  const repo = projectDir(probe) ?? die(`no such project: ${target}`);
  if (await syncProject(repo)) bad = 1;
} else {
  const pdir = projectsDir();
  let found = false;
  let names: string[] = [];
  try {
    names = readdirSync(pdir);
  } catch {}
  names = names.filter((n) => !n.startsWith(".") && isDir(`${pdir}/${n}`)).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const n of names) {
    found = true;
    const d = `${pdir}/${n}/`;
    if (git(d, ["rev-parse", "--git-dir"], "ignore", "ignore").rc !== 0) {
      warn(`skip ${n}: not a git repository`);
      continue;
    }
    if (await syncProject(physicalDir(d) ?? "")) bad = 1;
  }
  if (!found) warn(`no projects under ${pdir}`);
}
process.exit(bad);
