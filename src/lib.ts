// lib.ts - the TypeScript twin of the bin/ac-lib.sh helpers the ported
// scripts under src/ need, and nothing more: a helper lands here only when a
// port calls it. Each one keeps its bash original's observable contract (the
// same stderr shape, exit status and homeless answer), because callers of a
// ported bin/ac-*.sh entry cannot tell which language answered them. Two
// helpers are no twins: contractLint is the delivery-contract judge itself,
// and harnessLaunchable joins facts three bash arms each hold a part of; two
// twin a port's own bash rather than ac-lib's: leaseAgeSecs (ac-pool-health's
// reader of an ac_iso stamp) and tabFields (`IFS=$'\t' read -r`).

import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
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

// `cd "$1" && pwd -P`, or null when the cd fails. A chdir round-trip, not
// realpath: cd tries the logical spelling (link/.. walks back up the link)
// before the physical one, needs only search permission, and takes spellings
// Bun's realpath refuses (over PATH_MAX, a backslash). A directory Bun cannot
// name (a trailing backslash) is null where cd entered it: failing closed
// beats reading its sibling. "" is the cwd, the no-op `cd ""` is.
export function physicalDir(p: string): string | null {
  const here = process.cwd();
  for (const dir of [resolve(p), p]) {
    try {
      process.chdir(dir);
      const named = namedCwd();
      if (named) return named;
    } catch {
    } finally {
      process.chdir(here);
    }
  }
  return null;
}

// ac_home_resolve's no-flag rungs: `cd "$AC_HOME" && pwd -P`, or "" when
// unset - a homeless caller is legitimate and decides what "no home" means.
export function envHome(): string {
  const h = process.env.AC_HOME;
  if (!h) return "";
  return physicalDir(h) ?? die(`AC_HOME is not a readable directory: ${h}`);
}

// The shell's [:space:] under the operators' UTF-8 locale (measured, bash
// 3.2 on macOS): Unicode White_Space except U+0085; U+FEFF is not space there.
// Under the C locale - LC_ALL, else LC_CTYPE, else LANG, naming no UTF-8
// charset - it is the ASCII six, and a non-breaking space is a value byte.
const SHELL_TRIM = /^(?:(?!\x85)\p{White_Space})+|(?:(?!\x85)\p{White_Space})+$/gu;
const C_TRIM = /^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g;
function shellTrim(): RegExp {
  const loc = process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "";
  return /utf-?8/i.test(loc) ? SHELL_TRIM : C_TRIM;
}

export function configRead(name: string, dflt = ""): string {
  const h = envHome();
  if (!h) return dflt;
  const f = join(h, "config", name);
  if (!existsSync(f) || !statSync(f).isFile()) return dflt;
  return readFileSync(f, "utf8").split("\n")[0].replace(/\u0000/g, "").replace(shellTrim(), "");
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

// ac_home's refusal, exported for an entry that must print it and then keep
// its own exit status rather than die here.
export const NO_HOME = "AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one";

function homeSubdir(name: string): string {
  if (!process.env.AC_HOME) die(NO_HOME);
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

// ac_now's twin through date(1), the rung bash 3.2 (this host's /bin/bash)
// takes, so a PATH `date` stub binds the bash and the port to one instant.
// The live env, not Bun's startup snapshot, so a PATH set after start is the
// one searched.
const DATE_SPAWN = { stdout: "pipe", stderr: "ignore", env: process.env } as const;

export function now(): number {
  try {
    return Number(Bun.spawnSync(["date", "+%s"], DATE_SPAWN).stdout.toString().trim());
  } catch {
    return NaN;
  }
}

// `IFS=$'\t' read -r <n names>`: tab is IFS whitespace, so a run of tabs is
// one delimiter, leading and trailing runs are dropped, and the last name
// keeps the rest of the line. The ac-tree list wire is read this way, so a
// leased row with an empty leased_at lands its owner in leased_at.
export function tabFields(line: string, n: number): string[] {
  const fields: string[] = [];
  let rest = line.replace(/^\t+/, "");
  for (let i = 1; i < n && rest !== ""; i++) {
    const m = /\t+/.exec(rest);
    if (!m) break;
    fields.push(rest.slice(0, m.index));
    rest = rest.slice(m.index + m[0].length);
  }
  fields.push(rest.replace(/\t+$/, ""));
  while (fields.length < n) fields.push("");
  return fields;
}

// lease_age_secs' twin (bin/ac-pool-health.sh, the seam ac-learn.sh's
// learn_age_days shares): whole seconds since an ac_iso stamp, null when it
// misses the digit pattern or date(1) refuses it. The epoch comes from the
// same `date -u -j -f` (BSD; GNU `date -u -d` after it) the bash runs, never
// a JS parser: BSD strptime takes Feb 30, day 00 and :60 and rolls them while
// refusing month 13 or hour 24, and that acceptance set is what decides which
// leases read as aged.
export function leaseAgeSecs(ts: string): number | null {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/.test(ts)) return null;
  // A date(1) that cannot run at all reads as no age, as `|| return 0` did.
  let then = "";
  try {
    let r = Bun.spawnSync(["date", "-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", ts, "+%s"], DATE_SPAWN);
    if (r.exitCode !== 0) r = Bun.spawnSync(["date", "-u", "-d", ts, "+%s"], DATE_SPAWN);
    if (r.exitCode === 0) then = r.stdout.toString().trim();
  } catch {}
  if (then === "") return null;
  const n = now();
  if (!Number.isFinite(n)) return null;
  return n - Number(then);
}

// ac_seed_runtime_links's twin (the bash copy stays for bin/ac-fleet-new.sh;
// tests/ts/home-seed.test.ts holds the two together): the executable core
// linked into a home so a chief runs with cwd = home. A REAL entry is a
// per-home override and is left alone; `ln -sfn` is spawned, not re-done, so
// a stale or dangling link is repointed exactly as it is there, and its
// failure ends the run with its status as `set -e` did.
export function seedRuntimeLinks(home: string): void {
  for (const f of ["bin", "CLAUDE.md", ".claude", "AGENTS.md"]) {
    const p = join(home, f);
    if (existsSync(p) && !lstatSync(p).isSymbolicLink()) continue;
    const r = Bun.spawnSync(["ln", "-sfn", join(ROOT, f), p], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
  }
}

// ac_iso's twin: date(1) is spawned, not Date, so a PATH stub freezes a port
// and its bash oracle alike.
export function iso(): string {
  const r = Bun.spawnSync(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", stdout: "pipe", stderr: "inherit", env: process.env });
  return r.stdout.toString("latin1").replace(/\n+$/, "");
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
// TypeScript writers exclude each other (tests/ts/lib.test.ts). A caller whose
// contract test fast-forwards the bash `sleep 1` through a PATH stub passes a
// wait that spawns the PATH's sleep (tests/ts/scene.test.ts).
export function lockAcquire(dir: string, timeout: number, wait: () => void = () => Bun.sleepSync(1000)): boolean {
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
    wait();
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

// --- pr-check twins ---
import { accessSync, appendFileSync, chmodSync, constants as fsConstants } from "node:fs";

// ac_require's twin: the first command missing from the live PATH ends the run
// with its name, as the bash did before reading a single argument.
export function require(...cmds: string[]): void {
  for (const c of cmds) if (!Bun.which(c)) die(`required tool not found: ${c}`);
}

// ac_home as the path helpers read it inside `$(...)`: the physical home, or
// "" once the refusal is printed (when `report`) - ac_task_meta's printf went
// on with the empty capture and named `/<id>.meta`, so a homeless caller sees
// the refusal AND its own "no crewmate meta" (a wart kept: the second line is
// the entry's). An AC_HOME cd cannot enter was the shell's own `cd:` line
// there; the port names the variable (the HOME RESOLUTION ruling).
function softHome(report: boolean): string {
  const h = process.env.AC_HOME;
  if (!h) {
    if (report) writeSync(2, `ERROR: ${NO_HOME}\n`);
    return "";
  }
  const home = physicalDir(h);
  if (home === null) {
    if (report) writeSync(2, `ERROR: AC_HOME is not a readable directory: ${h}\n`);
    return "";
  }
  return home;
}

// ac_task_meta / ac_task_status twins: `<state dir>/<id>.<ext>`, state/ minted
// on the way (ac_state_dir's mkdir -p), the id a path component as given - the
// bash never validated it, so `../t1` names `<home>/t1.meta` on both sides.
function stateFile(id: string, ext: string, report: boolean): string {
  const home = softHome(report);
  let dir = "";
  if (home !== "") {
    dir = `${home}/state`;
    try {
      mkdirSync(dir, { recursive: true });
    } catch {}
  }
  return `${dir}/${id}.${ext}`;
}

export function taskMeta(id: string): string {
  return stateFile(id, "meta", true);
}

export function taskStatus(id: string): string {
  return stateFile(id, "status", true);
}

// ac_meta_set's twin: every line matching `^<key>=` dropped, every other line
// kept byte for byte in order (CRLF and all), an unterminated tail
// newline-terminated, `<key>=<value>\n` appended; an absent file is created
// with the one line. key and value are bytes (latin1), file a path. The
// rewrite goes through a sibling temp that a spawned `mv` renames over the
// file, as the bash did (a symlinked meta becomes a regular file, its target
// untouched); an mv that fails throws with mv's `status`, its own stderr
// already written. Named divergences: the temp is created EXCLUSIVELY
// (`<file>.tmp.<pid>`, the next name on EEXIST - the bash wrote through a
// planted sibling); the file's mode is kept (the bash's fresh temp left every
// meta umask-0644); the bytes are KEPT where the bash's `grep -v` destroyed
// them - a meta holding a NUL came back as `Binary file <path> matches` plus
// the new line, an unreadable one as the new line alone, both exit 0 - here a
// NUL is one more byte and an unreadable file THROWS, the caller deciding its
// exit; and the key is matched literally where the bash used it as a BRE
// (`a.b` also dropped `aXb=`) - every live caller's key is an identifier, so
// no reachable call differs.
export function metaSet(file: string, key: string, value: string): void {
  let data: Buffer | null = null;
  let mode: number | null = null;
  try {
    const st = statSync(file);
    if (st.isFile()) {
      mode = st.mode & 0o7777;
      data = readFileSync(file);
    }
  } catch (e) {
    if ((e as { code?: string }).code !== "ENOENT") throw e;
  }
  const prefix = Buffer.from(`${key}=`, "latin1");
  const lf = Buffer.from("\n");
  const parts: Buffer[] = [];
  if (data !== null) {
    for (let start = 0; start < data.length; ) {
      const nl = data.indexOf(10, start);
      const end = nl === -1 ? data.length : nl;
      const line = data.subarray(start, end);
      if (!(line.length >= prefix.length && line.subarray(0, prefix.length).equals(prefix))) parts.push(line, lf);
      start = end + 1;
    }
  }
  parts.push(Buffer.from(`${key}=${value}\n`, "latin1"));
  const out = Buffer.concat(parts);
  let tmp = `${file}.tmp.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, out, { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      tmp = `${file}.tmp.${process.pid}.${i}`;
    }
  }
  if (mode !== null) chmodSync(tmp, mode);
  let status = 127;
  try {
    status = Bun.spawnSync(["mv", tmp, file], { stdin: "ignore", stdout: "inherit", stderr: "inherit" }).exitCode ?? 1;
  } catch {}
  if (status !== 0) throw Object.assign(new Error(`mv ${tmp} ${file} failed`), { code: "EMV", status });
}

// ac_meta_is_verify's twin: the meta's kind is `verify-*`. An absent, kind-less
// or unreadable meta is not one, and the unreadable case stays silent - the
// bash drops ac_meta_get's WARN there (`2>/dev/null`), so readability is
// checked before metaGet gets to warn.
export function metaIsVerify(file: string): boolean {
  try {
    accessSync(file, fsConstants.R_OK);
    return metaGet(file, "kind").startsWith("verify-");
  } catch {
    return false;
  }
}

// ac_stage_dir_for_id's twin: the `<family>/<stage>[-rN]` subpath a staged id
// maps to, "" for an unsuffixed one; a bare `<family>-rN` is
// `<family>/implement-rN`. Pure suffix grammar, no disk check - bin/ac-brief.sh
// resolves where to CREATE a brief through it. `-rN` is one or two digits.
const STAGE_SUFFIXES = ["spec", "arch", "plan", "review", "ship", "design", "qa", "chief"];

export function stageDirForId(id: string): string {
  let base = id;
  let rev = "";
  const m = /-r([0-9]{1,2})$/.exec(base);
  if (m) {
    rev = `-r${m[1]}`;
    base = base.slice(0, -m[0].length);
  }
  for (const stage of STAGE_SUFFIXES) {
    if (!base.endsWith(`-${stage}`)) continue;
    const fam = base.slice(0, -(stage.length + 1));
    return fam === "" ? "" : `${fam}/${stage}${rev}`;
  }
  return rev === "" ? "" : `${base}/implement${rev}`;
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// ac_task_dir's twin, the brief-layout resolver of bin/ac-brief.sh resolved by
// what EXISTS: the nested stage dir when its brief lives there (a chief's on
// its FAMILY dir existing - the room is its brief), data/<id>/implement for an
// unsuffixed id with a brief there, the fan-out data/<base>/tasks/<slug> by
// longest prefix first, else the flat data/<id>. A brief in both places throws
// with ac_die's text, the caller deciding what the refusal costs. data/ is
// minted on the way (ac_data_dir).
export function taskDir(id: string): string {
  const d = dataDir();
  const flat = `${d}/${id}`;
  const sub = stageDirForId(id);
  let nested = "";
  let stage = "";
  let fam = "";
  if (sub !== "") {
    nested = `${d}/${sub}`;
    stage = sub.slice(sub.indexOf("/") + 1);
    fam = sub.slice(0, sub.indexOf("/"));
  } else if (isFile(`${flat}/implement/brief.md`)) {
    nested = `${flat}/implement`;
  }
  if (nested !== "" && (isFile(`${nested}/brief.md`) || (stage === "chief" && isDir(`${d}/${fam}`)))) {
    if (isFile(`${flat}/brief.md`)) throw new Error(`ambiguous task data for ${id}: briefs at both ${nested} and ${flat}`);
    return nested;
  }
  if (sub === "") {
    let base = id;
    while (base.lastIndexOf("-") !== -1) {
      base = base.slice(0, base.lastIndexOf("-"));
      const slug = id.slice(base.length + 1);
      if (!isFile(`${d}/${base}/tasks/${slug}/brief.md`)) continue;
      if (isFile(`${flat}/brief.md`)) throw new Error(`ambiguous task data for ${id}: briefs at both ${d}/${base}/tasks/${slug} and ${flat}`);
      return `${d}/${base}/tasks/${slug}`;
    }
  }
  return flat;
}

// ac_status_timeline_mirror's twin, fail-soft like it: the same line appended
// to `<taskDir>/timeline.log`, skipped for a verify-* meta, an id whose task
// dir is ambiguous, a dir not there for a task with no meta on disk, or a dir
// `mkdir -p` (spawned, its noise dropped as the bash dropped it) cannot make.
// A homeless run skipped too: its `/<id>` is no task dir.
function statusTimelineMirror(id: string, rec: Buffer): void {
  if (softHome(false) === "") return;
  const meta = stateFile(id, "meta", false);
  if (metaIsVerify(meta)) return;
  let dir: string;
  try {
    dir = taskDir(id);
  } catch {
    return;
  }
  if (!isDir(dir)) {
    if (!isFile(meta)) return;
    try {
      if (Bun.spawnSync(["mkdir", "-p", dir], { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exitCode !== 0) return;
    } catch {
      return;
    }
  }
  try {
    appendFileSync(`${dir}/timeline.log`, rec);
  } catch {}
}

// ac_status_append's twin: `<iso> <line>\n` appended to the task's status log,
// then mirrored to its durable timeline. The primary write's own failure is
// the answer (false), the mirror never changes it. line is bytes (latin1), id
// a path component.
export function statusAppend(id: string, line: string): boolean {
  const rec = Buffer.from(`${iso()} ${line}\n`, "latin1");
  let ok = true;
  try {
    appendFileSync(taskStatus(id), rec);
  } catch {
    ok = false;
  }
  statusTimelineMirror(id, rec);
  return ok;
}
