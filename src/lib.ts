// lib.ts - the TypeScript twin of the bin/ac-lib.sh helpers the ported
// scripts under src/ need, and nothing more: a helper lands here only when a
// port calls it. Each one keeps its bash original's observable contract (the
// same stderr shape, exit status and homeless answer), because callers of a
// ported bin/ac-*.sh entry cannot tell which language answered them. Two
// helpers are no twins: contractLint is the delivery-contract judge itself,
// and harnessLaunchable joins facts three bash arms each hold a part of.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");

// writeSync, not process.stderr.write: the message must be on the fd before
// process.exit tears the process down.
export function die(msg: string | Uint8Array): never {
  writeSync(2, prefixed("ERROR: ", msg));
  process.exit(1);
}

// ac_warn's twin: the same prefix, the same fd, the caller goes on.
export function warn(msg: string | Uint8Array): void {
  writeSync(2, prefixed("WARN: ", msg));
}

// A message that arrived as bytes (a meta value read as latin1, a path) is
// written as those bytes; a string is UTF-8 like every other line.
function prefixed(prefix: string, msg: string | Uint8Array): Uint8Array {
  return typeof msg === "string"
    ? Buffer.from(`${prefix}${msg}\n`, "utf8")
    : Buffer.concat([Buffer.from(prefix, "utf8"), Buffer.from(msg), Buffer.from("\n")]);
}

// ac_meta_get's twin: `<key>=<value>` lines, the LAST one wins and an empty
// last value reads as absent; a line that is the bare key reads as empty too
// (the awk takes the value from past "key="). A file that is gone, or no
// regular file, is absent - "" - because `[ -f ]` fails first; one that is
// there and unreadable is warned and THROWN, the status 1 the bash returns.
// Bytes in, bytes out: the value is latin1 so a caller can print it as the
// shell would, byte for byte.
export function metaGet(file: string, key: string): string {
  // `[ -f ]` first, as the bash: a FIFO or a directory is never opened (a FIFO
  // read would wait for a writer), and a file gone by this instant is absent.
  try {
    if (!statSync(file).isFile()) return "";
  } catch {
    return "";
  }
  let text: string;
  try {
    text = readFileSync(file, "latin1");
  } catch (e) {
    try {
      statSync(file);
    } catch {
      return "";
    }
    warn(`cannot read meta file ${file}`);
    throw e;
  }
  let v = "";
  for (const line of text.split("\n")) {
    if (line === key || line.startsWith(`${key}=`)) v = line.slice(key.length + 1);
  }
  return v;
}

// Bun's process.cwd() drops a trailing backslash from the directory's name,
// so the name it reports counts only once it stats as the directory entered.
function namedCwd(): string | null {
  try {
    const named = process.cwd();
    const a = statSync(named);
    const b = statSync(".");
    return a.dev === b.dev && a.ino === b.ino ? named : null;
  } catch {
    return null;
  }
}

// ac_home_resolve's no-flag rungs: `cd "$AC_HOME" && pwd -P`, or "" when
// unset - a homeless caller is legitimate and decides what "no home" means.
// A chdir round-trip, not realpath: cd tries the logical spelling (link/..
// walks back up the link) before the physical one, needs only search
// permission, and takes spellings Bun's realpath refuses (over PATH_MAX, a
// backslash). A home Bun cannot name (a trailing backslash) is refused where
// ac_home_resolve accepts it: failing closed beats reading its sibling.
export function envHome(): string {
  const h = process.env.AC_HOME;
  if (!h) return "";
  const here = process.cwd();
  for (const dir of [resolve(h), h]) {
    try {
      process.chdir(dir);
      const named = namedCwd();
      if (named) return named;
    } catch {
    } finally {
      process.chdir(here);
    }
  }
  die(`AC_HOME is not a readable directory: ${h}`);
}

// The shell's [:space:] under the operators' UTF-8 locale (measured, bash
// 3.2 on macOS): Unicode White_Space except U+0085; U+FEFF is not space there.
const SHELL_TRIM = /^(?:(?!\x85)\p{White_Space})+|(?:(?!\x85)\p{White_Space})+$/gu;

export function configRead(name: string, dflt = ""): string {
  const h = envHome();
  if (!h) return dflt;
  const f = join(h, "config", name);
  if (!existsSync(f) || !statSync(f).isFile()) return dflt;
  return readFileSync(f, "utf8").split("\n")[0].replace(/\u0000/g, "").replace(SHELL_TRIM, "");
}

// Copies of two bash tables - bin/ac-harness.sh's registry (ac_harness_known)
// and the arms only ac-pane-agent.sh's oneshot_launch has - which
// tests/ts/lib.test.ts lifts and holds these to.
export const HARNESSES = ["claude", "codex", "opencode", "pi", "cursor"] as const;
export const ONESHOT_ONLY_HARNESSES = ["agy"] as const;
const BUILT_IN: readonly string[] = [...HARNESSES, ...ONESHOT_ONLY_HARNESSES];

// A name some arm can launch: a registry or one-shot-only harness, or one the
// home gives a template ac-spawn.sh would take (`[ -f config/launch-<h> ]`).
export function harnessLaunchable(home: string, h: string): boolean {
  if (BUILT_IN.includes(h)) return true;
  const f = join(home, "config", `launch-${h}`);
  return existsSync(f) && statSync(f).isFile();
}

// ac_sha256_file's twin. A file it cannot read throws, where the shell's
// pipeline printed an empty hash for its caller to mistake for a value.
export function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function homeSubdir(name: string): string {
  if (!process.env.AC_HOME)
    die("AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one");
  const dir = join(envHome(), name);
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function stateDir(): string {
  return homeSubdir("state");
}

export function recordsDir(): string {
  return homeSubdir("records");
}

export function dataDir(): string {
  return homeSubdir("data");
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

// ac_epic_branches_file's twin: the live record, else the first archive year
// holding one, null when the record never existed. Paths are joined as the
// bash joined them (`data/../x/branches` stays spelled so), and the live rung
// precedes the charset guard as it does there. The archive years are walked
// in byte order, the repo's own `LC_ALL=C sort` idiom; year names are digits,
// where every collation agrees with it.
export function epicBranchesFile(epic: string): string | null {
  const data = dataDir();
  const live = `${data}/${epic}/branches`;
  if (isFile(live)) return live;
  if (!/^[a-zA-Z0-9_-]+$/.test(epic)) return null;
  const archive = `${data}/archive`;
  let years: string[] = [];
  try {
    years = readdirSync(archive);
  } catch {}
  years = years.filter((y) => !y.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const y of years) {
    const f = `${archive}/${y}/${epic}/branches`;
    if (isFile(f)) return f;
  }
  return null;
}

// What onetrue awk's is_number accepts (strtod's grammar: blanks around, a
// sign, decimal or hex digits, nan; +inf is HUGE_VAL and refused, so is an
// overflow), and the value it compares by.
const AWK_NUMBER = /^[ \t\n\v\f\r]*([+-]?)(?:(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|0[xX]([0-9a-fA-F]+)|([nN][aA][nN])|([iI][nN][fF](?:[iI][nN][iI][tT][yY])?))[ \t\n\r]*$/;
function awkNumber(s: string): number | null {
  const m = AWK_NUMBER.exec(s);
  if (!m) return null;
  const neg = m[1] === "-";
  if (m[3] !== undefined) return NaN;
  if (m[4] !== undefined) return neg ? -Infinity : null;
  if (m[2] !== undefined) return (neg ? -1 : 1) * parseInt(m[2], 16);
  const v = Number(s);
  return Number.isFinite(v) ? v : null;
}

export type EpicBranchEntry = { rc: 0; entry: string } | { rc: 1 | 2 };

// ac_epic_branch_entry's twin: `<branch> [key=value ...]` for <repo>, rc 1 for
// no record or no entry (a record this process cannot read included), rc 2
// when the FIRST line starts with `# retired`. The record is bytes (latin1 in,
// the entry latin1 out; <repo> is compared as its bytes). The reader is awk's
// `$1==r { $1=""; sub(/^ /, ""); print; exit }`, reproduced quirks and all -
// fields split on runs of space/TAB with the ends trimmed and rejoined by
// single spaces, and `==` numeric when both sides read as numbers (`07` is
// `7`, `1e2` is `100`, nan equals everything) - because the bash reader stays
// live for ac-epic-ship/ac-tree/ac-feature/ac-merge-local/ac-backend-orca and
// the two must never disagree about one record.
export function epicBranchEntry(epic: string, repo: string): EpicBranchEntry {
  const f = epicBranchesFile(epic);
  if (f === null) return { rc: 1 };
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    return { rc: 1 };
  }
  if (text.split("\n")[0]!.startsWith("# retired")) return { rc: 2 };
  const r = Buffer.from(repo, "utf8").toString("latin1");
  const rn = awkNumber(r);
  for (const line of text.split("\n")) {
    const fields = line.replace(/^[ \t]+|[ \t]+$/g, "").split(/[ \t]+/);
    const first = fields[0]!;
    const fn = rn === null ? null : awkNumber(first);
    const hit = fn !== null && rn !== null ? !(fn < rn) && !(fn > rn) : first === r;
    if (!hit) continue;
    const entry = fields.slice(1).join(" ");
    return entry === "" ? { rc: 1 } : { rc: 0, entry };
  }
  return { rc: 1 };
}

function gitOut(repo: string, args: string[]): string | null {
  const r = Bun.spawnSync(["git", "-C", repo, ...args], { stdout: "pipe", stderr: "ignore" });
  return r.exitCode === 0 ? r.stdout.toString().replace(/\n+$/, "") : null;
}

function gitRef(repo: string, ref: string): boolean {
  return Bun.spawnSync(["git", "-C", repo, "show-ref", "--verify", "--quiet", ref], { stdout: "ignore", stderr: "ignore" }).exitCode === 0;
}

// ac_default_branch's twin: origin/HEAD's target, else main, else master,
// else the checked-out branch, else `main` for a detached HEAD.
export function defaultBranch(repo: string): string {
  const head = gitOut(repo, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]);
  if (head) return head.startsWith("refs/remotes/origin/") ? head.slice("refs/remotes/origin/".length) : head;
  for (const b of ["main", "master"]) if (gitRef(repo, `refs/heads/${b}`)) return b;
  return gitOut(repo, ["symbolic-ref", "--short", "HEAD"]) ?? "main";
}

// ac_freshest_ref's twin: whichever of local and origin is AHEAD on the
// default (or the named) branch, origin winning a true divergence.
export function freshestRef(repo: string, branch = ""): string {
  if (!branch) branch = defaultBranch(repo);
  const local = gitRef(repo, `refs/heads/${branch}`);
  const origin = gitRef(repo, `refs/remotes/origin/${branch}`);
  if (local && origin) {
    const r = Bun.spawnSync(["git", "-C", repo, "merge-base", "--is-ancestor", `refs/remotes/origin/${branch}`, `refs/heads/${branch}`], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return r.exitCode === 0 ? branch : `origin/${branch}`;
  }
  return origin ? `origin/${branch}` : branch;
}

// ac_git_push_control_plane's twin: a push with the repository's pre-push hook
// skipped, for bookkeeping that publishes nothing new for review. git's own
// stdout/stderr pass through; its status is returned.
export function pushControlPlane(repo: string, args: string[]): number {
  const r = Bun.spawnSync(["git", "-C", repo, "push", "--no-verify", ...args], { stdout: "inherit", stderr: "inherit" });
  return r.exitCode ?? 1;
}

// ac_pid_alive's twin: an owner is a canonical positive pid, and a process this
// user may not signal (EPERM) exists - reading it as dead would hand a live
// holder's lock to a second writer.
export function pidAlive(pid: string): boolean {
  if (!/^[1-9][0-9]*$/.test(pid)) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch (e) {
    return (e as { code?: string }).code === "EPERM";
  }
}

function lockOwner(dir: string): string {
  try {
    return readFileSync(join(dir, "pid"), "latin1").replace(/\n+$/, "");
  } catch {
    return "";
  }
}

// ac_lock_stale's twin: a dead owner is stale at once; a dir with no owner yet
// (an acquirer between its mkdir and its pid write) only after the grace.
function lockStale(dir: string): boolean {
  const owner = lockOwner(dir);
  if (owner !== "") return !pidAlive(owner);
  let mtime: number;
  try {
    mtime = Math.floor(statSync(dir).mtimeMs / 1000);
  } catch {
    return false;
  }
  return Math.floor(Date.now() / 1000) - mtime >= Number(process.env.AC_LOCK_STALE_GRACE || "5");
}

// ac_lock_acquire's twin, the same lock dir and pid file, so bash and
// TypeScript writers exclude each other (tests/ts/lib.test.ts).
export function lockAcquire(dir: string, timeout: number): boolean {
  let waited = 0;
  for (;;) {
    try {
      mkdirSync(dir);
      break;
    } catch {}
    if (lockStale(dir)) {
      // A dir that will not go is waited on like a live holder's, so an
      // unremovable one times out instead of spinning or throwing.
      try {
        rmSync(dir, { recursive: true, force: true });
      } catch {}
      if (!existsSync(dir)) continue;
    }
    if (waited >= timeout) return false;
    Bun.sleepSync(1000);
    waited++;
  }
  writeFileSync(join(dir, "pid"), `${process.pid}\n`);
  return true;
}

// ac_lock_release's twin: a reclaim may have handed the dir to another writer
// since this one took it, so only an unowned dir or our own is removed.
export function lockRelease(dir: string): void {
  const owner = lockOwner(dir);
  if (owner === "" || owner === String(process.pid)) rmSync(dir, { recursive: true, force: true });
}

// The delivery-contract value judge, one violation per entry and none when the
// contract is clean. The VALUE vocabulary lives HERE - src/backlog.ts extracts
// shape only. It also flags the two combinations AGENTS.md section 5 outlaws
// (flow:staged with rev:no; mode:crew-ship with rev:no), so a contract that
// contradicts the law is loud at the scheduler and refused by ac-task.sh add.
export function contractLint(c: string): string[] {
  const out: string[] = [];
  let flow = "", mode = "", rev = "";
  const want = (key: string, val: string, ok: string, why = ok) => {
    if (!ok.split("|").includes(val)) out.push(`${key}:${val} invalid - want ${why}`);
  };
  for (const tok of c.split(/[ \t\n]+/)) {
    if (tok === "") continue;
    const i = tok.indexOf(":");
    const key = i < 0 ? tok : tok.slice(0, i);
    const val = tok.slice(i + 1);
    if (key === "src") want(key, val, "cap|chief|mon|gh|crew|learn");
    else if (key === "flow") want(key, (flow = val), "direct|staged");
    else if (key === "mode") want(key, (mode = val), "crew-ship|direct-pr|local-only|feature-pr");
    else if (key === "rev") want(key, (rev = val), "yes|no");
    else if (key === "qa") want(key, val, "yes|no");
    else if (key === "promote") want(key, val, "no", "no (always is the default and is never written)");
  }
  if (flow === "staged" && rev === "no") out.push("flow:staged with rev:no - staged review is mandatory (AGENTS.md section 5)");
  if (mode === "crew-ship" && rev === "no") out.push("mode:crew-ship with rev:no - crew-ship review is mandatory (AGENTS.md section 5)");
  return out;
}

// The module's half of bin/ac-bun.sh: bun started in the distro root, and the
// caller's cwd arrived as the first argument ("" when it has no name).
// Returning there keeps every relative input the caller's.
let atCallerCwd = false;

export function enterCaller(argv: string[]): { args: string[]; atCaller: boolean } {
  const [caller = "", ...args] = argv;
  atCallerCwd = false;
  try {
    process.chdir(caller);
    if (namedCwd()) atCallerCwd = true;
    else process.chdir(ROOT);
  } catch {}
  return { args, atCaller: atCallerCwd };
}

// Another src/ module started the way bin/ac-bun.sh starts one, for a module
// that spawns bun itself. A parent that never reached its caller's cwd sits in
// the distro root, so it hands the child "" rather than the root.
export function bunChild(module: string, args: string[]): { cmd: string[]; cwd: string; env: Record<string, string> } {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && !/^(BUN_|JSC_)/.test(k)) env[k] = v;
  return { cmd: [process.execPath, "--no-env-file", join(ROOT, module), atCallerCwd ? process.cwd() : "", ...args], cwd: ROOT, env };
}
