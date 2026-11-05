// lib.ts - the TypeScript twin of the bin/ac-lib.sh helpers the ported
// scripts under src/ need, and nothing more: a helper lands here only when a
// port calls it. Each one keeps its bash original's observable contract (the
// same stderr shape, exit status and homeless answer), because callers of a
// ported bin/ac-*.sh entry cannot tell which language answered them. Two
// helpers are no twins: contractLint is the delivery-contract judge itself,
// and harnessLaunchable joins facts three bash arms each hold a part of; two
// twin a port's own bash rather than ac-lib's: leaseAgeSecs (ac-pool-health's
// reader of an ac_iso stamp) and tabFields (`IFS=$'\t' read -r`).
// THE FANOUT RULE: a twin that one or two ports alone call, and nothing in
// this file uses, lives beside its port in src/lib-<port>.ts, importing what
// it needs from here; this file never imports one back. tests/run-suite.sh
// --changed selects by import closure, so a twin
// kept here would make every edit to it select every module's tests.

import { createHash } from "node:crypto";
import { accessSync, constants, existsSync, linkSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
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
export function prefixed(prefix: string, msg: string | Uint8Array): Uint8Array {
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
  return metaValue(text, key);
}

function metaValue(text: string, key: string): string {
  let v = "";
  for (const line of text.split("\n")) {
    if (line === key || line.startsWith(`${key}=`)) v = line.slice(key.length + 1);
  }
  return v;
}

// Bun before 1.4.4 reported a directory whose name ends in a backslash as its
// backslash-less sibling, so the name process.cwd() reports counts only once
// it stats as the directory entered.
export function namedCwd(): string | null {
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
// name (before 1.4.4, a trailing backslash) is null where cd entered it:
// failing closed beats reading its sibling. "" is the cwd, the no-op `cd ""`
// is.
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

// Copies of two tables - bin/ac-harness.sh's registry (ac_harness_known) and
// the arms only src/pane-agent.ts's ONESHOT has - which tests/ts/lib.test.ts
// reads and holds these to.
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

export function homeSubdir(name: string): string {
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
const DATE_SPAWN = { stdout: "pipe", stderr: "ignore" } as const;

export function now(): number {
  try {
    return Number(spawnShellSync(["date", "+%s"], DATE_SPAWN).stdout.toString().trim());
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

// lease_age_secs' twin (bin/ac-pool-health.sh, the seam src/learn.ts's
// ageDays shares): whole seconds since an ac_iso stamp, null when it
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
    let r = spawnShellSync(["date", "-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", ts, "+%s"], DATE_SPAWN);
    if (r.exitCode !== 0) r = spawnShellSync(["date", "-u", "-d", ts, "+%s"], DATE_SPAWN);
    if (r.exitCode === 0) then = r.stdout.toString().trim();
  } catch {}
  if (then === "") return null;
  const n = now();
  if (!Number.isFinite(n)) return null;
  return n - Number(then);
}

// ac_seed_runtime_links's twin, and since the fleet-new port its only form -
// the bash helper is retired, frozen at tests/fixtures/ac-seed-runtime-links.sh
// where tests/ts/home-seed.test.ts holds the two together: the executable core
// linked into a home so a chief runs with cwd = home. A REAL entry is a
// per-home override and is left alone; `ln -sfn` is spawned, not re-done, so
// a stale or dangling link is repointed exactly as it is there, and its
// failure ends the run with its status as `set -e` did. The .claude link is
// the home's shape only until its first writing session start, when
// src/home-carriers.ts replaces it with a real dir that names the home.
export function seedRuntimeLinks(home: string): void {
  for (const f of ["bin", "CLAUDE.md", ".claude", "AGENTS.md", ".agents"]) {
    const p = join(home, f);
    if (existsSync(p) && !lstatSync(p).isSymbolicLink()) continue;
    const r = spawnShellSync(["ln", "-sfn", join(ROOT, f), p], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    if (r.exitCode === 0) continue;
    const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
    process.exit(r.exitCode ?? 128 + sig);
  }
}

// ac_iso's twin: date(1) is spawned, not Date, so a PATH stub freezes a port
// and its bash oracle alike.
export function iso(): string {
  const r = spawnShellSync(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
  return r.stdout.toString("latin1").replace(/\n+$/, "");
}

export function dataDir(): string {
  return homeSubdir("data");
}

export function isFile(p: string | Buffer): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

// ac_fence_dir's twin: the home's <sub> under AC_HOME (records soft, data as
// dataDir has it), else the home a crewmate pane's AC_FLEET_STATE sits in -
// joined as text, so the kernel resolves the `..` past a symlinked state dir
// as the bash's path has it; "" for records with no home at all.
function fenceDir(sub: "records" | "data"): string {
  const fleet = process.env.AC_FLEET_STATE;
  if (!process.env.AC_HOME && fleet) return `${fleet.replace(/\/$/, "")}/../${sub}`;
  return sub === "records" ? softSubdir("records", false) : dataDir();
}

// ac_epic_branches_file's twin: the live record, else the first archive year
// holding one, null when the record never existed. Paths are joined as the
// bash joined them (`data/../x/branches` stays spelled so), and the live rung
// precedes the charset guard as it does there. The archive years are walked
// in byte order, the repo's own `LC_ALL=C sort` idiom; year names are digits,
// where every collation agrees with it.
export function epicBranchesFile(epic: string): string | null {
  const data = fenceDir("data");
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
// live under ac_epic_base_for (ac-backend-orca, ac-spawn) and the
// two must never disagree about one record.
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
  const r = spawnShellSync(["git", "-C", repo, ...args], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  return r.exitCode === 0 ? r.stdout.toString().replace(/\n+$/, "") : null;
}

function gitRef(repo: string, ref: string, loud = false): boolean {
  return spawnShellSync(["git", "-C", repo, "show-ref", "--verify", "--quiet", ref], { stdin: "inherit", stdout: "ignore", stderr: loud ? "inherit" : "ignore" }).exitCode === 0;
}

// ac_default_branch's twin: origin/HEAD's target, else main, else master,
// else the checked-out branch, else `main` for a detached HEAD. `loud` keeps
// the stderr of the bash's unsilenced show-refs (git's `fatal: not a git
// repository` for a dir that is none).
export function defaultBranch(repo: string, loud = false): string {
  const head = gitOut(repo, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]);
  if (head) return head.startsWith("refs/remotes/origin/") ? head.slice("refs/remotes/origin/".length) : head;
  for (const b of ["main", "master"]) if (gitRef(repo, `refs/heads/${b}`, loud)) return b;
  return gitOut(repo, ["symbolic-ref", "--short", "HEAD"]) ?? "main";
}

// ac_freshest_ref's twin: whichever of local and origin is AHEAD on the
// default (or the named) branch, origin winning a true divergence.
export function freshestRef(repo: string, branch = ""): string {
  if (!branch) branch = defaultBranch(repo);
  const local = gitRef(repo, `refs/heads/${branch}`);
  const origin = gitRef(repo, `refs/remotes/origin/${branch}`);
  if (local && origin) {
    const r = spawnShellSync(["git", "-C", repo, "merge-base", "--is-ancestor", `refs/remotes/origin/${branch}`, `refs/heads/${branch}`], {
      stdout: "ignore",
      stderr: "ignore",
    });
    return r.exitCode === 0 ? branch : `origin/${branch}`;
  }
  return origin ? `origin/${branch}` : branch;
}

// ac_git_push_control_plane's twin: a push with the repository's pre-push hook
// skipped, for bookkeeping that publishes nothing new for review. git's own
// stdout passes through, its stderr unless the caller dropped it; its status
// is returned.
export function pushControlPlane(repo: string, args: string[], stderr: "inherit" | "ignore" = "inherit"): number {
  const r = spawnShellSync(["git", "-C", repo, "push", "--no-verify", ...args], { stdout: "inherit", stderr });
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

function lockFile(dir: string, name: string): string {
  try {
    return readFileSync(join(dir, name), "latin1").replace(/\n+$/, "");
  } catch {
    return "";
  }
}
const lockOwner = (dir: string): string => lockFile(dir, "pid");

// ac_pid_start's twin: the process's start time as ps prints it, "" when ps
// cannot say. Compared byte for byte, never parsed - both writers read the
// same ps - with ps's column padding trimmed, so the width it pads to can
// never tell two readings of one start apart.
export function pidStart(pid: string): string {
  try {
    const r = spawnShellSync(["/usr/bin/env", "LC_ALL=C", "ps", "-o", "lstart=", "-p", pid], { stdout: "pipe", stderr: "ignore" });
    return r.exitCode === 0 ? r.stdout.toString("latin1").trim() : "";
  } catch {
    return "";
  }
}

// ac_lock_stale's twin: a dead owner is stale at once, and so is a live pid
// whose process started after the holder recorded its own start - the OS
// handed the number to a later process, and kill(pid, 0) would hold the lock
// for it for ever. A dir with no start file (an older writer's) is judged by
// liveness alone; a dir with no owner yet (an acquirer between its mkdir and
// its pid write) only after the grace.
function lockStale(dir: string): boolean {
  const owner = lockOwner(dir);
  if (owner !== "") {
    if (!pidAlive(owner)) return true;
    const start = lockFile(dir, "start");
    if (start === "") return false;
    const now = pidStart(owner);
    return now !== "" && now !== start;
  }
  let mtime: number;
  try {
    mtime = Math.floor(statSync(dir).mtimeMs / 1000);
  } catch {
    return false;
  }
  return Math.floor(Date.now() / 1000) - mtime >= Number(process.env.AC_LOCK_STALE_GRACE || "5");
}

function mkdirClaim(dir: string): boolean {
  try {
    mkdirSync(dir);
    return true;
  } catch {
    return false;
  }
}

// ac_lock_acquire's twin, the same lock dir and pid file, so bash and
// TypeScript writers exclude each other (tests/ts/lib.test.ts). A caller whose
// contract test fast-forwards the bash `sleep 1` through a PATH stub passes a
// wait that spawns the PATH's sleep (tests/ts/scene.test.ts), and one whose
// test watches the bash's `mkdir` claim through a PATH stub passes a make that
// spawns the PATH's mkdir (src/learn.ts).
export function lockAcquire(dir: string, timeout: number, wait: () => void = () => Bun.sleepSync(1000), make: (dir: string) => boolean = mkdirClaim): boolean {
  let waited = 0;
  for (;;) {
    if (make(dir)) break;
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
  const start = pidStart(String(process.pid));
  if (start !== "") writeFileSync(join(dir, "start"), `${start}\n`);
  return true;
}

// ac_lock_release's twin: a reclaim may have handed the dir to another writer
// since this one took it, so only an unowned dir or our own is removed.
export function lockRelease(dir: string): void {
  const owner = lockOwner(dir);
  if (owner === "" || owner === String(process.pid)) rmSync(dir, { recursive: true, force: true });
}

// A watch-lock incumbent the autoarm hook marked records the SESSION-LOCK pid
// of the Stop-hook firing that armed it (src/watch-autoarm.ts's header owns
// the evidence that session can outlive itself, reparented to init). A
// mismatch against the CURRENT session-lock pid, or a recorded pid that no
// longer answers kill -0, either alone proves orphaning - a recorded pid
// that is coincidentally still live under a mismatch is still a different
// session, and a dead recorded pid is dead whether or not a later lock
// holder happens to share its text. No marker (never armed by this hook) is
// never orphaned - there is no incumbent to reclaim a claim about.
export function autoarmIncumbentOrphaned(recordedHolder: string, sessionLockPid: string): boolean {
  if (recordedHolder === "") return false;
  return recordedHolder !== sessionLockPid || !pidAlive(recordedHolder);
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
    else if (key === "flow") want(key, (flow = val), "direct|staged|sdlc");
    else if (key === "mode") want(key, (mode = val), "crew-ship|direct-pr|local-only|feature-pr");
    else if (key === "rev") want(key, (rev = val), "yes|no");
    else if (key === "qa") want(key, val, "yes|no");
    else if (key === "promote") want(key, val, "no", "no (always is the default and is never written)");
  }
  if (flow === "staged" && rev === "no") out.push("flow:staged with rev:no - staged review is mandatory (AGENTS.md section 5)");
  if (flow === "sdlc" && rev === "no") out.push("flow:sdlc with rev:no - sdlc review is mandatory (AGENTS.md section 5)");
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
// that spawns bun itself: through env(1), which drops the BUN_*/JSC_* names
// ac-bun.sh unset and keeps every other value's bytes, as an env option would
// not (spawnShellSync). A parent that never reached its caller's cwd sits in
// the distro root, so it hands the child "" rather than the root.
export function bunChild(module: string, args: string[]): { cmd: string[]; cwd: string } {
  const unset = Object.keys(process.env).filter((k) => /^(BUN_|JSC_)/.test(k)).flatMap((k) => ["-u", k]);
  return { cmd: ["/usr/bin/env", ...unset, ...envCommand([process.execPath]), "--no-env-file", join(ROOT, module), atCallerCwd ? process.cwd() : "", ...args], cwd: ROOT };
}

// --- fleets twins ---
// The shell's [:space:] over a value read as bytes, under the locale bash was
// given (shellTrim): a valid UTF-8 value under a UTF-8 name is trimmed as its
// characters, anything else of ASCII whitespace only.
function trimShellSpaceBytes(b: string): string {
  const u = Buffer.from(b, "latin1").toString("utf8");
  if (Buffer.from(u, "utf8").toString("latin1") !== b) return b.replace(/^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g, "");
  return Buffer.from(u.replace(shellTrim(), ""), "utf8").toString("latin1");
}

// bin/ac-fleets.sh cfg_read's twin, the per-directory cousin of configRead
// (which is bound to AC_HOME): the first line of <cfgDir>/<name>, NULs dropped
// as a command substitution drops them, [:space:]-trimmed, <dflt> when the
// file is absent or no regular file. Bytes in, bytes out (latin1), so a value
// prints as the shell printed it; a present-but-unreadable file throws.
export function configReadDir(cfgDir: string, name: string, dflt = ""): string {
  const f = join(cfgDir, name);
  try {
    if (!statSync(f).isFile()) return dflt;
  } catch {
    return dflt;
  }
  return trimShellSpaceBytes(readFileSync(f, "latin1").split("\n")[0]!.replace(/\u0000/g, ""));
}

// ac_meta_is_verify's twin: the meta's kind is `verify-*`. An absent, kind-less
// or unreadable meta is not one, and the unreadable case stays silent - the
// bash drops ac_meta_get's WARN there (`2>/dev/null`), so readability is
// checked before metaGet gets to warn.
export function metaIsVerify(file: string): boolean {
  try {
    accessSync(file, constants.R_OK);
    return metaGet(file, "kind").startsWith("verify-");
  } catch {
    return false;
  }
}

// --- done twins ---

// ac_wake_scope_ok's twin (bin/ac-wake-lib.sh): a legal family name is one bare
// path segment of [A-Za-z0-9_-], read per the text under any locale.
export function wakeScopeOk(scope: string): boolean {
  return /^[A-Za-z0-9_-]+$/.test(scope);
}

// ac_watcher_beat_read's twin: the `<beat> <note>` line, note empty for a
// usable beat. The beacon is watcherBeatPath's; its content loses trailing
// newlines and NULs as `$(cat)` loses them, then a leading zero, any
// non-digit (a second line, a CR) or an empty read is the unreadable 0 - so a
// zero-padded beat can never reach a caller's arithmetic.
export function watcherBeatRead(stateDir: string, scope = ""): string {
  const f = watcherBeatPath(stateDir, scope);
  if (!existsSync(f)) return "0 no beat on record (no beacon - nothing has armed a watcher here)";
  let beat = "";
  try {
    beat = readFileSync(f, "latin1").replace(/\u0000/g, "").replace(/\n+$/, "");
  } catch {}
  if (beat === "0") return "0 no beat on record (a watcher stood its beacon down on exit - drain and re-arm)";
  if (!/^[1-9][0-9]*$/.test(beat)) return "0 no beat on record (the beacon is unreadable)";
  return `${beat} `;
}

// ac_wake_family_spools' twin: every `state/.wake-spool.<family>` directory
// (a symlink to one included) whose suffix is a legal family name - which
// excludes the fleet spool, the drain claim dirs (`.wake-spool-draining.<pid>`)
// and a dotted or empty suffix. Byte order, the repo's `LC_ALL=C sort` idiom.
export function wakeFamilySpools(stateDir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(stateDir);
  } catch {}
  const out: string[] = [];
  for (const n of names.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    if (!n.startsWith(".wake-spool.") || !wakeScopeOk(n.slice(".wake-spool.".length))) continue;
    const p = join(stateDir, n);
    try {
      if (statSync(p).isDirectory()) out.push(p);
    } catch {}
  }
  return out;
}

// ac_wake_spool_path's twin: the family spool for a legal scope, else the
// FLEET spool - a malformed scope lands on the crewchief, the catch-all. Pure.
export function wakeSpoolPath(sd: string, scope: string): string {
  return wakeScopeOk(scope) ? `${sd}/.wake-spool.${scope}` : `${sd}/.wake-spool`;
}

// _ac_wake_seq's twin: strictly increasing for the life of the process, never
// reset, so two same-stamp records from one process can never share a name.
let wakeSeq = 0;

// ac_wake_seam's twin: the test-only fault-injection hook, inert (0) unless
// AC_WAKE_SEAM_AT names the label; the answer is the hook's own status.
function wakeSeam(label: string): number {
  if (process.env.AC_WAKE_SEAM_AT !== label) return 0;
  const hook = process.env.AC_WAKE_SEAM_RUN ?? "";
  try {
    accessSync(hook, constants.X_OK);
  } catch {
    return 0;
  }
  try {
    return shellStatus(spawnShellSync([hook], { stdin: "inherit", stdout: "inherit", stderr: "inherit" }));
  } catch {
    return 126;
  }
}

// ac_wake_publish's twin, writing the fleet wire the bash ac_wake_publish
// still writes for its own callers (ac-spawn's kickoff, ac-learn's due wake), so
// the record `<ts10>\tkind\tid\tpayload\n` and the name `<ts_ns>.<pid>.<seq6>`
// are byte-identical to the bash's: TAB and LF in the payload fold to spaces;
// `date +%s%N` is ONE spawned capture, kept verbatim in the name (a date
// without %N prints a literal N) and refused before any byte exists unless ten
// digits lead it; the record is written whole on a private `.wake-tmp.` +
// eight [A-Za-z0-9] inode created exclusively with mktemp's 0600, then
// published by one link(2), stepping the sequence past a name already taken
// (a dead predecessor's). mkdir -p is spawned so a spool path a file sits on
// fails with mkdir's own line. False means NOT published; from the write
// onward the bytes stay on disk as litter, and only the commit removes the
// temp. id and payload are bytes (latin1), sd and scope paths. A producer
// that called ac_wake_publish from an `||` list slept through a failing
// `date` and a failing seam hook; `unguarded` is the one that called it bare
// under errexit (ac-github.sh's poll), ended right there with that child's
// status - thrown as code EDATE / ESEAM with the shell's `status`.
export function wakePublish(sd: string, scope: string, kind: string, id: string, payload: string, unguarded = false): boolean {
  payload = payload.replace(/[\t\n]/g, " ");
  const spool = wakeSpoolPath(sd, scope);
  let tsNs = "";
  let date: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    date = spawnShellSync(["date", "+%s%N"], { stdout: "pipe", stderr: "inherit" });
    tsNs = date.stdout.toString("latin1").replace(/\n+$/, "");
  } catch {}
  if (unguarded && shellStatus(date) !== 0) throw Object.assign(new Error("date failed"), { code: "EDATE", status: shellStatus(date) });
  if (!/^[0-9]{10}/.test(tsNs)) return false;
  const record = Buffer.from(`${tsNs.slice(0, 10)}\t${kind}\t${id}\t${payload}\n`, "latin1");
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let tmp = "";
  for (let tries = 0; tmp === ""; tries++) {
    let suffix = "";
    for (let i = 0; i < 8; i++) suffix += alphabet[Math.floor(Math.random() * alphabet.length)];
    const candidate = `${sd}/.wake-tmp.${suffix}`;
    try {
      writeFileSync(candidate, record, { flag: "wx", mode: 0o600 });
      tmp = candidate;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST" || tries >= 100) return false;
    }
  }
  const seam = wakeSeam("after-write");
  if (unguarded && seam !== 0) throw Object.assign(new Error("seam hook failed"), { code: "ESEAM", status: seam });
  let isDir = false;
  try {
    isDir = statSync(spool).isDirectory();
  } catch {}
  if (!isDir) {
    try {
      if (spawnShellSync(["mkdir", "-p", spool], { stdin: "ignore", stdout: "inherit", stderr: "inherit" }).exitCode !== 0) return false;
    } catch {
      return false;
    }
  }
  for (;;) {
    const dest = `${spool}/${tsNs}.${process.pid}.${String(wakeSeq).padStart(6, "0")}`;
    try {
      linkSync(tmp, dest);
    } catch {
      if (!existsSync(dest)) return false;
      wakeSeq++;
      continue;
    }
    try {
      rmSync(tmp, { force: true });
    } catch {}
    wakeSeq++;
    return true;
  }
}

// ac_watcher_pid's twin: the pid of the LIVE watcher covering a scope (the
// fleet lock, or the scoped lock a legal scope names), null when there is none
// to nudge - a pid file that is not canonical digits, a dead pid, or a REUSED
// pid whose `ps -o command=` names no watcher. A watcher the shim started runs
// as `bun --no-env-file <root>/src/watch.ts <cwd>`, a frozen original copied
// out as an escape hatch as `bash .../ac-watch.sh`: either is one.
export function watcherPid(sd: string, scope: string): string | null {
  const lock = wakeScopeOk(scope) ? `${sd}/.watch-only-${scope}.lock.d` : `${sd}/.watch.lock.d`;
  const pid = lockOwner(lock);
  if (!pidAlive(pid)) return null;
  let cmd = "";
  try {
    cmd = spawnShellSync(["ps", "-o", "command=", "-p", pid], { stdout: "pipe", stderr: "ignore" }).stdout.toString("latin1");
  } catch {}
  return cmd.includes("ac-watch") || cmd.includes("/src/watch.ts") ? pid : null;
}

// ac_watcher_nudge's twin: end the covering watcher's poll wait by signalling
// its `sleep` CHILD alone (one `ps -A` walk, the first child whose comm is
// sleep), and say which of the four quiet outcomes happened - never a failure,
// the record is the guarantee and the nudge only an accelerator.
export function watcherNudge(sd: string, scope: string): string {
  const wpid = watcherPid(sd, scope);
  if (wpid === null) return "no armed watcher for this scope - the record waits in the spool";
  let child = "";
  try {
    for (const line of spawnShellSync(["ps", "-o", "pid=,ppid=,comm=", "-A"], { stdout: "pipe", stderr: "ignore" }).stdout.toString("latin1").split("\n")) {
      const f = line.replace(/^[ \t]+|[ \t]+$/g, "").split(/[ \t]+/);
      if (f[1] === wpid && /(^|\/)sleep$/.test(f[2] ?? "")) {
        child = f[0]!;
        break;
      }
    }
  } catch {}
  if (child === "") return `watcher pid=${wpid} is mid-poll, nothing to nudge - the record waits in the spool`;
  try {
    process.kill(Number(child), "SIGTERM");
  } catch {
    return `watcher pid=${wpid} could not be nudged, nothing to nudge - the record waits in the spool`;
  }
  return `nudged watcher pid=${wpid} (poll sleep ${child} ended early)`;
}

// --- pr-check twins ---
import { appendFileSync, chmodSync, constants as fsConstants } from "node:fs";
import { constants as osConstants } from "node:os";

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

// The path helpers (ac_state_dir, ac_data_dir, ac_records_dir) as `$(...)`
// read them: `<home>/<name>`, minted, or "" once the refusal is printed.
function softSubdir(name: string, report: boolean): string {
  const home = softHome(report);
  if (home === "") return "";
  const dir = `${home}/${name}`;
  try {
    mkdirSync(dir, { recursive: true });
  } catch {}
  return dir;
}

// ac_task_meta / ac_task_status twins: `<state dir>/<id>.<ext>`, state/ minted
// on the way (ac_state_dir's mkdir -p), the id a path component as given - the
// bash never validated it, so `../t1` names `<home>/t1.meta` on both sides.
function stateFile(id: string, ext: string, report: boolean): string {
  return `${softSubdir("state", report)}/${id}.${ext}`;
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
// no reachable call differs. The rewrite runs under ac_meta_set's lock
// (<dir>/.<file>.lock, the same protocol, 10 PATH `sleep 1` waits); one that
// cannot be taken is the WARN the bash prints and a throw (code ELOCK,
// status 1) with nothing written. `quiet` (a caller's `2>/dev/null`) drops
// that WARN and mv's own line.
export function metaSet(file: string, key: string, value: string, quiet = false): void {
  metaUpdate(file, () => [[key, value]], quiet);
}

// Several keys rewritten in ONE rename, each value computed by `pairs` from
// the meta as it stands once the lock is held, so a read-modify-write loses
// no concurrent writer's update (short of the lock protocol's two-reclaimer
// residual, bin/ac-lib.sh) and a reader never sees half of a set. Every
// line of a named key is dropped and the pairs are appended in order - the
// bytes successive metaSet calls would leave.
export function metaUpdate(file: string, pairs: (get: (key: string) => string) => [string, string][], quiet = false): void {
  metaLocked(file, () => metaRewrite(file, pairs, quiet), quiet);
}

// ac_meta_set's lock around a rewrite of <file> that is not metaUpdate's own
// (a twin keeping grep's BRE key match), so every writer of one meta still
// excludes every other; refused exactly as metaUpdate is.
export function metaLocked(file: string, rewrite: () => void, quiet = false): void {
  const cut = file.lastIndexOf("/");
  const dir = cut < 0 ? "." : file.slice(0, cut);
  const lock = `${dir}/.${file.slice(cut + 1)}.lock`;
  let held = false;
  try {
    accessSync(dir, constants.W_OK | constants.X_OK);
    held = lockAcquire(lock, 10, sleepOne);
  } catch {}
  if (!held) {
    if (!quiet) warn(`cannot lock meta file ${file} - nothing written`);
    throw Object.assign(new Error(`cannot lock meta file ${file}`), { code: "ELOCK", status: 1 });
  }
  try {
    rewrite();
  } finally {
    lockRelease(lock);
  }
}

export function metaRewrite(file: string, pairs: (get: (key: string) => string) => [string, string][], quiet = false): void {
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
  const text = data === null ? "" : data.toString("latin1");
  const set = pairs((key) => metaValue(text, key));
  const prefixes = set.map(([key]) => Buffer.from(`${key}=`, "latin1"));
  const lf = Buffer.from("\n");
  const parts: Buffer[] = [];
  if (data !== null) {
    for (let start = 0; start < data.length; ) {
      const nl = data.indexOf(10, start);
      const end = nl === -1 ? data.length : nl;
      const line = data.subarray(start, end);
      if (!prefixes.some((prefix) => line.length >= prefix.length && line.subarray(0, prefix.length).equals(prefix))) parts.push(line, lf);
      start = end + 1;
    }
  }
  for (const [key, value] of set) parts.push(Buffer.from(`${key}=${value}\n`, "latin1"));
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
    status = shellStatus(spawnShellSync(["mv", tmp, file], { stdin: "ignore", stdout: "inherit", stderr: quiet ? "ignore" : "inherit" }));
  } catch {}
  if (status !== 0) throw Object.assign(new Error(`mv ${tmp} ${file} failed`), { code: "EMV", status });
}

// ac_stage_dir_for_id's twin: the `<family>/<stage>[-rN]` subpath a staged id
// maps to, "" for an unsuffixed one; a bare `<family>-rN` is
// `<family>/implement-rN`. Pure suffix grammar, no disk check - src/brief.ts
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

export function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// ac_fam_dir's twin: the data dir holding a family's files, by what EXISTS -
// <d>/<fam> when it is there, else the ONE <d>/<epic>/<fam>/ one level down
// carrying the `.family` marker (a story of an epic lives inside its epic's
// dir; the marker is what tells it from a crewmate's own work/ or verify/
// subdir). Two marked dirs throw with ac_die's text, the dirs in byte order;
// a family nowhere on disk is placed by the live ledger (ledgerEpicOf): a
// story's path under its epic, else the flat path - so the writer that creates
// it lands it right, through famDirMint. An unsafe name never reaches the
// scan, and archive/ is no epic. <d> is the caller's own data-dir read, so a
// homeless call prints the refusal exactly as often as the bash did and never
// reaches the ledger.
export function famDir(fam: string, d: string = dataDir()): string {
  const flat = `${d}/${fam}`;
  if (isDir(flat) || fam === "" || /[^a-zA-Z0-9_-]/.test(fam)) return flat;
  let tops: string[] = [];
  try {
    tops = readdirSync(d);
  } catch {}
  const hits = tops
    .filter((t) => t !== "archive" && !t.startsWith(".") && isFile(`${d}/${t}/${fam}/.family`))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((t) => `${d}/${t}/${fam}`);
  if (hits.length > 1) throw new Error(`ambiguous family data for ${fam}: dirs at both ${hits[0]} and ${hits[1]}`);
  if (hits.length === 1) return hits[0]!;
  if (d === "") return flat;
  const e = ledgerEpicOf(fam);
  return e === "" ? flat : `${d}/${e}/${fam}`;
}

// ac_ledger_epic_of's twin: the epic a story belongs to, by the live ledger -
// the first row with that id carries epic:<e>, <e> is not the id itself, and
// <e> has a row of its own bracketed [EPIC]; else "". A token naming no [EPIC]
// row is a stray pointer, never a layout instruction. No ledger, or one that
// cannot be read, is no epic. Rows are what the awk read (records,
// acDoneline), the id what `awk -v want=` made of it (awkAssign), and the
// epic's bytes come back as the UTF-8 the twin's strings are. The ledger is
// LOOKED AT, never minted: a path resolve must not create records/ (fenceDir
// would), so the fence's two rungs are spelled here unminted.
export function ledgerEpicOf(id: string, read?: Ledger): string {
  let ledger = read;
  if (ledger === undefined) {
    const fleet = process.env.AC_FLEET_STATE;
    let rdir = "";
    if (!process.env.AC_HOME && fleet) rdir = `${fleet.replace(/\/$/, "")}/../records`;
    else {
      const h = softHome(false);
      rdir = h === "" ? "" : `${h}/records`;
    }
    if (rdir === "") return "";
    ledger = ledgerRead(`${rdir}/backlog.md`);
  }
  if (ledger.rc !== 0) return "";
  const want = awkAssign(Buffer.from(id, "utf8").toString("latin1"));
  const epics = new Set<string>();
  let epic: string | undefined;
  for (const line of records(ledger.text)) {
    if (!line.startsWith("- [")) continue;
    const f = acDoneline(line);
    if (f.terminal === "epic") epics.add(f.id);
    if (epic === undefined && f.id === want) epic = f.epic;
  }
  if (!epic || epic === want || !epics.has(epic)) return "";
  return Buffer.from(epic, "latin1").toString("utf8");
}

// ac_fam_dir_mint's twin: famDir with the dir created, a nested one (a story
// under its epic) marked `.family` so every later read finds it with no
// ledger - the row is pruned long before the dir is archived.
export function famDirMint(fam: string, d: string = dataDir()): string {
  const dir = famDir(fam, d);
  mkdirSync(dir, { recursive: true });
  if (dir.startsWith(`${d}/`) && dir.slice(d.length + 1).includes("/")) writeFileSync(`${dir}/.family`, "");
  return dir;
}

// The room walkers' `data/*/room.md` glob widened one level: every non-dot
// entry of <d> as the glob listed it (what lies under it stays the caller's
// judgement, so a file or a dir named room.md keeps its old effect), plus each
// dir one level down carrying the `.family` marker - a story of an epic -
// never under archive/. Byte order of the whole path, so a story follows its
// epic. No data dir is no family at all.
export function familyDirs(d: string): string[] {
  let tops: string[] = [];
  try {
    tops = readdirSync(d);
  } catch {
    return [];
  }
  const out: string[] = [];
  for (const t of tops) {
    if (t.startsWith(".")) continue;
    out.push(`${d}/${t}`);
    if (t === "archive") continue;
    let subs: string[] = [];
    try {
      subs = readdirSync(`${d}/${t}`);
    } catch {
      continue;
    }
    for (const s of subs) if (!s.startsWith(".") && isFile(`${d}/${t}/${s}/.family`)) out.push(`${d}/${t}/${s}`);
  }
  return out.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

// ac_task_dir's twin, the brief-layout resolver of src/brief.ts resolved by
// what EXISTS: the nested stage dir when its brief lives there (a chief's on
// its FAMILY dir existing - the room is its brief), <family dir>/implement for
// an unsuffixed id with a brief there, the fan-out <family dir>/tasks/<slug>
// by longest prefix first, else the id's own family dir (famDir). A brief in
// both places throws with ac_die's text, the caller deciding what the refusal
// costs. data/ is minted on the way (ac_data_dir).
export function taskDir(id: string): string {
  const d = dataDir();
  const flat = famDir(id, d);
  const sub = stageDirForId(id);
  let nested = "";
  let stage = "";
  let famd = "";
  if (sub !== "") {
    stage = sub.slice(sub.indexOf("/") + 1);
    famd = famDir(sub.slice(0, sub.indexOf("/")), d);
    nested = `${famd}/${stage}`;
  } else if (isFile(`${flat}/implement/brief.md`)) {
    nested = `${flat}/implement`;
  }
  if (nested !== "" && (isFile(`${nested}/brief.md`) || (stage === "chief" && isDir(famd)))) {
    if (isFile(`${flat}/brief.md`)) throw new Error(`ambiguous task data for ${id}: briefs at both ${nested} and ${flat}`);
    return nested;
  }
  if (sub === "") {
    let base = id;
    while (base.lastIndexOf("-") !== -1) {
      base = base.slice(0, base.lastIndexOf("-"));
      const slug = id.slice(base.length + 1);
      famd = famDir(base, d);
      if (!isFile(`${famd}/tasks/${slug}/brief.md`)) continue;
      if (isFile(`${flat}/brief.md`)) throw new Error(`ambiguous task data for ${id}: briefs at both ${famd}/tasks/${slug} and ${flat}`);
      return `${famd}/tasks/${slug}`;
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
    // `$(ac_task_dir ...)`: the capture lost every trailing LF of the path.
    dir = taskDir(id).replace(/\n+$/, "");
  } catch {
    return;
  }
  if (!isDir(dir)) {
    if (!isFile(meta)) return;
    try {
      if (spawnShellSync(["mkdir", "-p", dir], { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exitCode !== 0) return;
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
// a path component. `unguarded` is the caller whose bash ran the helper under
// errexit (ac-pr-check.sh's bare call): a date(1) that fails ends it with
// date's status before any write (thrown here as code EDATE), and a failed
// primary append ends it before the mirror - the guarded callers' bash (`||`)
// slept through both and mirrored anyway.
export function statusAppend(id: string, line: string, unguarded = false): boolean {
  let stamp: string;
  if (unguarded) {
    let r: ReturnType<typeof Bun.spawnSync> | null = null;
    try {
      r = spawnShellSync(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", stdout: "pipe", stderr: "inherit" });
    } catch {}
    // The shell's status for the child: its exit, 128+signal when a signal
    // ended it, 127 when it could not start.
    if (r === null) throw Object.assign(new Error("date failed"), { code: "EDATE", status: 127 });
    if (r.exitCode !== 0) {
      const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
      throw Object.assign(new Error("date failed"), { code: "EDATE", status: r.exitCode ?? 128 + sig });
    }
    // `$(...)`: NUL bytes dropped, trailing newlines stripped.
    stamp = r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  } else stamp = iso();
  const rec = Buffer.from(`${stamp} ${line}\n`, "latin1");
  let ok = true;
  try {
    appendFileSync(taskStatus(id), rec);
  } catch {
    ok = false;
  }
  if (!ok && unguarded) return false;
  statusTimelineMirror(id, rec);
  return ok;
}

// classifyCi: pr-check.ts's reading of `gh pr view <url> --json
// statusCheckRollup` into the ci= recorded on the task meta (--pr-ready's
// gate, src/teardown.ts). statusCheckRollup mixes two GitHub GraphQL shapes
// (docs.github.com/en/graphql/reference/objects#checkrun and
// #statuscontext): a CheckRun's `status` (CheckStatusState: QUEUED,
// IN_PROGRESS, COMPLETED, WAITING, PENDING, REQUESTED -
// reference/enums#checkstatusstate) gates whether its `conclusion`
// (CheckConclusionState: ACTION_REQUIRED, CANCELLED, FAILURE, NEUTRAL,
// SKIPPED, STALE, STARTUP_FAILURE, SUCCESS, TIMED_OUT -
// reference/enums#checkconclusionstate) is final; a legacy StatusContext
// carries only `state` (StatusState: ERROR, EXPECTED, FAILURE, PENDING,
// SUCCESS - reference/enums#statusstate), no separate status/conclusion
// split. An empty rollup is `none` - no check has registered, so nothing has
// verified the PR. A real failure (CheckRun conclusion FAILURE, CANCELLED,
// ACTION_REQUIRED, STARTUP_FAILURE, TIMED_OUT, or StatusState FAILURE/ERROR)
// makes the whole rollup `failing`, checked first - a green sibling must
// never hide a real failure. Short of that, an entry not yet COMPLETED (or a
// StatusContext PENDING/EXPECTED), one whose conclusion is outside the ok set
// (SUCCESS/NEUTRAL/SKIPPED/STALE), or a shape this never names makes it
// `pending` - the fail-closed default, since a false `green` is the
// unrecoverable direction here and a stuck `pending` costs nothing
// (ci=pending keeps today's --pr-ready behavior). Only a non-empty rollup
// whose every entry reads ok is `green`.
export function classifyCi(rollup: unknown): "green" | "pending" | "failing" | "none" {
  if (!Array.isArray(rollup) || rollup.length === 0) return "none";
  const FAILING = new Set(["FAILURE", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "TIMED_OUT"]);
  const OK = new Set(["SUCCESS", "NEUTRAL", "SKIPPED", "STALE"]);
  let pending = false;
  for (const e of rollup) {
    if (typeof e !== "object" || e === null) {
      pending = true;
      continue;
    }
    const r = e as Record<string, unknown>;
    if (typeof r.state === "string") {
      if (r.state === "FAILURE" || r.state === "ERROR") return "failing";
      if (r.state !== "SUCCESS") pending = true;
      continue;
    }
    if (r.status !== "COMPLETED") {
      pending = true;
      continue;
    }
    const c = typeof r.conclusion === "string" ? r.conclusion : "";
    if (FAILING.has(c)) return "failing";
    if (!OK.has(c)) pending = true;
  }
  return pending ? "pending" : "green";
}

// --- promote twins ---

// ac_delivery_mode_block's twin (tests/fixtures/ac-pipeline-lib.sh), whose bash copy stays
// for the frozen originals tests/fixtures/ac-promote.sh and
// tests/fixtures/ac-brief.sh, which their legs run beside it: two renderers of
// the one per-mode delivery contract, held together by tests/ts/promote.test.ts.
// No trailing newline, "" for a mode the bash case has no arm for.
export function deliveryModeBlock(mode: string, branch: string, base: string, integ: string, loop: string): string {
  switch (mode) {
    case "crew-ship":
      return "- Mode crew-ship: run the `crew-ship` skill. Its `ac-ship` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL.";
    case "direct-pr":
      return `- Mode direct-pr: after ${loop}, push \`${branch}\` and open a PR against ${base}. The PR body covers intent, changes, and verification evidence, and ends with \`Closes #<n>\` only for the GitHub issue the brief says this task fixes; never put close, fix or resolve before any other \`#<n>\` - GitHub closes that issue on merge.`;
    case "feature-pr":
      return `- Mode feature-pr: after ${loop}, leave \`${branch}\` clean and fully committed - it lands onto the feature integration branch \`${integ}\` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.`;
    case "local-only":
      return `- Mode local-only: after ${loop}, leave \`${branch}\` clean and fully committed. Never push or open a PR.`;
    default:
      return "";
  }
}

// --- fleet-new twins ---

// ac_config_dir / ac_projects_dir twins: the dir minted under the home AC_HOME
// names. With stateDir, dataDir and recordsDir these ARE the fleet-home layout
// ac-lib.sh defines, which is why src/fleet-new.ts seeds through them.
export function configDir(): string {
  return homeSubdir("config");
}

export function projectsDir(): string {
  return homeSubdir("projects");
}

// --- review-diff twins ---
import { acDoneline, records } from "./backlog.ts";

// ac_family_of_id's twin: the family a task id belongs to. Suffix grammar is
// stageDirForId's; a PLAIN stage suffix is trusted only when data/<family>/
// <stage> exists (a flat id merely colliding with a stage name stays its own
// family), a staged revision checks the BASE stage dir and falls back to the
// un-revised id, a bare `<family>-rN` is unconditional. The dir test reads the
// data dir as the bash's `[ -d "$(ac_data_dir)/..." ]` did: minted when there
// is a home, and homeless the refusal is printed and the test runs on "/...".
export function familyOfId(id: string): string {
  const sub = stageDirForId(id);
  if (sub === "") return id;
  const fam = sub.slice(0, sub.indexOf("/"));
  const stage = sub.slice(sub.indexOf("/") + 1);
  if (/^implement-r[0-9]{1,2}$/.test(stage)) return fam;
  const rev = /^(.*)-r[0-9]{1,2}$/.exec(stage);
  if (rev) return isDir(`${famDir(fam, softSubdir("data", true))}/${rev[1]}`) ? fam : id.slice(0, id.lastIndexOf("-r"));
  return isDir(`${famDir(fam, softSubdir("data", true))}/${stage}`) ? fam : id;
}

// ac_crew_branch's twin: the ONE crew-branch derivation.
export function crewBranch(id: string): string {
  return `crew/${familyOfId(id)}`;
}

// What `awk -v name="$v"` makes of its value (onetrue awk, probed): the C
// escapes, `\"` and `\/`, up to three DIGITS read as octal into one byte, any
// other escaped character kept without its backslash, a lone final backslash
// kept, and the string cut at a NUL as every C string is.
function awkAssign(v: string): string {
  let out = "";
  for (let i = 0; i < v.length; i++) {
    if (v[i] !== "\\") {
      out += v[i];
      continue;
    }
    const n = v[++i];
    if (n === undefined) {
      out += "\\";
      break;
    }
    const simple: Record<string, string> = { n: "\n", t: "\t", b: "\b", f: "\f", r: "\r", v: "\v", a: "\x07", "\\": "\\", '"': '"', "/": "/" };
    if (simple[n] !== undefined) out += simple[n];
    else if (/[0-9]/.test(n)) {
      let code = 0;
      let k = 0;
      while (k < 3 && /[0-9]/.test(v[i + k] ?? "")) code = code * 8 + Number(v[i + k++]);
      i += k - 1;
      out += String.fromCharCode(code & 0xff);
    } else out += n;
  }
  return out.split("\0", 1)[0]!;
}

export type EpicBase = { rc: 0; entry: string } | { rc: 1 | 2 };

// ac_epic_base_for's twin: the integration-branch entry a lease for <id> on
// <repo> must honor. The ledger row is <id>'s by LONGEST id-prefix (the id,
// then the id cut at its last `-`, and so on), the FIRST row per id winning;
// its `epic:` token, then its `feature:` token, then the row id itself are
// tried against the branch record (epicBranchEntry), a retired or missing
// record falling to the next. rc 1 = no fence (no home, no ledger, no row, no
// entry), rc 2 = the ledger is there but cannot be read. Rows are what the awk
// read (records/acDoneline, src/backlog.ts: a record cut at a NUL, CR kept)
// and the id is what `awk -v want=` made of it (awkAssign). A ledger that is a
// directory is absent (`[ -f ]`), never rc 2. Homeless, the refusal the bash's
// `$(ac_records_dir)` printed is not reproduced here: src/tree.ts's get, whose
// original let it through, prints it at its call site. The bun-missing path
// that gave the awk rc 2 has no in-process equivalent. A caller that already
// read the ledger (ledgerRead) hands it over as <read>, so one read answers
// every question it asks of the ledger.
export function epicBaseFor(id: string, repo: string, read?: Ledger): EpicBase {
  let ledger = read;
  if (ledger === undefined) {
    const rdir = fenceDir("records");
    if (rdir === "") return { rc: 1 };
    ledger = ledgerRead(`${rdir}/backlog.md`);
  }
  if (ledger.rc !== 0) return { rc: ledger.rc };
  const rows = new Map<string, [string, string]>();
  for (const line of records(ledger.text)) {
    if (!line.startsWith("- [")) continue;
    const f = acDoneline(line);
    if (!rows.has(f.id)) rows.set(f.id, [f.epic, f.feature]);
  }
  let b = awkAssign(Buffer.from(id, "utf8").toString("latin1"));
  let row = rows.get(b);
  while (row === undefined) {
    if (!b.includes("-")) return { rc: 1 };
    b = b.replace(/-[^-]*$/, "");
    row = rows.get(b);
  }
  for (const cand of [row[0], row[1], b]) {
    if (cand === "") continue;
    const e = epicBranchEntry(Buffer.from(cand, "latin1").toString("utf8"), repo);
    if (e.rc === 0) return e;
  }
  return { rc: 1 };
}

// --- sync twins ---
import { dirname } from "node:path";

// ac_project_dir + ac_repo_root twins (the bash pair stays live for seven
// callers): the MAIN repo root for a project argument - a directory (any path
// in or inside a repo, as cd enters it: a symlink reports its physical root)
// else projects/<arg> - null when neither is a directory or the directory is
// no repo. The root is `dirname` of `rev-parse --git-common-dir`, so a linked
// worktree answers its main repo and a bare x.git its PARENT (kept). The
// projects/ rung runs inside a swallowed substitution in the original, so a
// homeless or unenterable home prints its refusal (once per substitution) and
// the lookup goes on with "" as the projects dir; a reachable home has
// projects/ minted, as ac_projects_dir mints it.
export function projectDir(arg: string): string | null {
  let dir: string;
  if (isDir(arg)) dir = physicalDir(arg) ?? "";
  else {
    const soft = (): string => {
      const home = softHome(true);
      if (home === "") return "";
      try {
        mkdirSync(`${home}/projects`, { recursive: true });
      } catch {}
      return `${home}/projects`;
    };
    if (!isDir(`${soft()}/${arg}`)) return null;
    dir = `${soft()}/${arg}`;
  }
  let common: string | null = null;
  try {
    const r = spawnShellSync(["git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
    if (r.exitCode === 0) common = r.stdout.toString().replace(/\n+$/, "");
  } catch {}
  return common === null ? null : dirname(common);
}

// --- lock twins ---

// AC_HARNESS_RE's copy (bin/ac-harness.sh), the ERE the session lock's
// ancestry walk classifies a command line with, held to that file by
// tests/ts/lock.test.ts. Not HARNESSES joined: the regex names the PROCESS
// (`cursor-agent`) where the registry names the harness id (`cursor`).
export const HARNESS_RE = "claude|codex|opencode|pi|cursor-agent";

// --- fleet-view twins ---

// ac_crew_metas's awk, verbatim: the kind read, the skip classes, the abort on
// a directory, the wait on a FIFO and the -1 of an unreadable or dangling path
// are the binary's, so the binary runs them.
const CREW_METAS_AWK = `
    BEGIN {
      for (i = 1; i < ARGC; i++) {
        file = ARGV[i]; kind = ""
        while ((getline line < file) > 0)
          if (line ~ /^kind=/) kind = substr(line, 6)
        close(file)
        if (sv && kind ~ /^verify-/) continue
        if (ss && kind == "self") continue
        if (sc && (kind == "roomchief" || kind == "crewdeputy")) continue
        print file
      }
    }
  `;

// ac_crew_metas's twin (the bash function keeps its own callers): the non-dot
// `*.meta` entries of <sd> in BYTE order (the glob followed the locale's
// collation), nothing at all when the FIRST one does not exist (`[ -e "$1" ]`
// alone - a dangling symlink sorting first hides every meta), else every path
// handed to ONE awk whose stdout is yielded line by line AS IT ARRIVES, split
// on LF as `read -r` split it: a path holding an LF arrives as two, and the
// paths before a FIFO reach the caller while awk waits on it. awk's stderr is
// the caller's, dropped under `quiet` (a caller's `2>/dev/null`); its status
// is never read, as a process substitution's was not.
export async function* crewMetas(sd: string, ...flags: ("verify" | "self" | "chiefs" | "quiet")[]): AsyncGenerator<string> {
  let names: string[] = [];
  try {
    names = readdirSync(sd);
  } catch {}
  const paths = names
    .filter((n) => !n.startsWith(".") && n.endsWith(".meta"))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${sd}/${n}`);
  if (paths.length === 0 || !existsSync(paths[0]!)) return;
  const on = (c: "verify" | "self" | "chiefs"): string => (flags.includes(c) ? "1" : "0");
  let awk: ReturnType<typeof Bun.spawn>;
  try {
    awk = spawnShell(["awk", "-v", `sv=${on("verify")}`, "-v", `ss=${on("self")}`, "-v", `sc=${on("chiefs")}`, CREW_METAS_AWK, ...paths], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: flags.includes("quiet") ? "ignore" : "inherit",
    });
  } catch {
    return;
  }
  let buf = Buffer.alloc(0);
  for await (const chunk of awk.stdout as ReadableStream<Uint8Array>) {
    buf = Buffer.concat([buf, chunk]);
    for (let lf = buf.indexOf(10); lf >= 0; lf = buf.indexOf(10)) {
      yield buf.subarray(0, lf).toString("utf8");
      buf = buf.subarray(lf + 1);
    }
  }
}

// `$(<root>/bin/ac-crew-state.sh <id> 2>/dev/null || printf unknown)`: the
// child's stdout, `unknown` appended when it failed (a non-zero exit, a
// signal, or it could not start), NULs dropped and trailing LFs stripped as
// `$(...)` did - a child that printed and then failed reads `<text>unknown`.
export function crewState(root: string, id: string, stdin: "inherit" | "ignore"): string {
  let text = "";
  let failed = false;
  try {
    const r = spawnShellSync([`${root}/bin/ac-crew-state.sh`, id], { stdin, stdout: "pipe", stderr: "ignore" });
    text = r.stdout.toString("latin1");
    failed = r.exitCode !== 0;
  } catch {
    failed = true;
  }
  if (failed) text += "unknown";
  return text.replace(/\0/g, "").replace(/\n+$/, "");
}

// --- github twins ---

// The shell's status for a spawned child: its exit, 128+signal when a signal
// ended it, 127 when it never started (a null result).
export function shellStatus(r: { exitCode: number | null; signalCode?: string | null } | null): number {
  if (r === null) return 127;
  return r.exitCode ?? 128 + ((osConstants.signals as Record<string, number>)[r.signalCode ?? ""] ?? 0);
}

// ac_redact_publish's twin (tests/fixtures/ac-pipeline-lib.sh, whose frozen
// bash copy holds its own tests): the same four sed expressions, SPAWNED,
// because what they match is sed's under the caller's locale - HOME is spliced into a BRE
// (`.` one character under UTF-8, one byte under C) and `[:space:]` is Unicode
// white space under UTF-8 (a NBSP ends no userinfo there), the reason jq stays
// spawned too. text and the answer are bytes (latin1). HOME unset throws
// ENOHOME before any spawn (the bash died on `set -u`); a sed that fails throws
// ESED with the shell's status, sed's own line already on stderr.
export function redactPublish(text: string): string {
  const home = process.env.HOME;
  if (home === undefined) throw Object.assign(new Error("HOME is not set"), { code: "ENOHOME" });
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(
      ["sed", "-e", `s|${home}|~|g`, "-e", "s|/Users/[A-Za-z0-9._-]\\{1,\\}|~|g", "-e", "s|/home/[A-Za-z0-9._-]\\{1,\\}|~|g", "-e", "s|://[^/@[:space:]]\\{1,\\}@|://***@|g"],
      { stdin: Buffer.from(text, "latin1"), stdout: "pipe", stderr: "inherit" },
    );
  } catch {}
  const status = shellStatus(r);
  if (status !== 0) throw Object.assign(new Error("sed failed"), { code: "ESED", status });
  return r!.stdout.toString("latin1");
}

// POSIX cksum's CRC (the `cksum` binary's first field): polynomial 0x04C11DB7
// MSB first over the bytes, then the length's bytes least significant first
// (none for an empty input), then complemented.
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i << 24;
    for (let k = 0; k < 8; k++) c = c & 0x80000000 ? (c << 1) ^ 0x04c11db7 : c << 1;
    t[i] = c >>> 0;
  }
  return t;
})();

export function cksumPosix(bytes: Uint8Array): number {
  let crc = 0;
  const step = (b: number): void => {
    crc = ((crc << 8) ^ CRC_TABLE[((crc >>> 24) ^ b) & 0xff]!) >>> 0;
  };
  for (const b of bytes) step(b);
  for (let n = bytes.length; n > 0; n = Math.floor(n / 256)) step(n % 256);
  return ~crc >>> 0;
}

// --- feature twins ---

// ac_room_file's twin (the bash one stays for ac-learn, ac-room,
// ac-watch and ac-lib.sh's landing checks): the room a
// HISTORY read uses - the live data/<fam>/room.md, else an archived
// data/archive/<year>/<fam>/room.md (years in byte order, dot names skipped as
// the glob skipped them), else the room of the family a fan-out sub-task id
// belongs to (the longest prefix with data/<base>/tasks/<slug>/brief.md,
// resolution starting over on <base>), else the live path a writer creates.
// Only a name of [a-zA-Z0-9_-] reaches the archive glob, read per the text:
// bash 3.2's range let é through under a UTF-8 locale. Each `$(ac_data_dir)`
// the bash evaluated is one data-dir read here, so a homeless call prints the
// refusal as often as the bash did and goes on with the dir-less path.
export function roomFile(fam: string): string {
  const live = `${famDir(fam, softSubdir("data", true))}/room.md`;
  if (isFile(live)) return live;
  if (/[^a-zA-Z0-9_-]/.test(fam)) return live;
  const archive = `${softSubdir("data", true)}/archive`;
  let years: string[] = [];
  try {
    years = readdirSync(archive);
  } catch {}
  years = years.filter((y) => !y.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  for (const y of years) {
    // join, not a template: the glob printed an empty name's match with the
    // doubled slash collapsed.
    const f = join(archive, y, fam, "room.md");
    if (isFile(f)) return f;
  }
  // A story archived WITH its epic (src/archive.ts moves the epic dir whole)
  // sits one level down, still carrying its marker.
  for (const y of years) {
    let epics: string[] = [];
    try {
      epics = readdirSync(join(archive, y));
    } catch {}
    for (const e of epics.filter((n) => !n.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
      const story = join(archive, y, e, fam);
      if (isFile(join(story, ".family")) && isFile(join(story, "room.md"))) return join(story, "room.md");
    }
  }
  for (let base = fam; base.includes("-"); ) {
    base = base.slice(0, base.lastIndexOf("-"));
    if (isFile(`${famDir(base, softSubdir("data", true))}/tasks/${fam.slice(base.length + 1)}/brief.md`)) return roomFile(base);
  }
  return live;
}

// src/feature.ts reads a feature name as `awk -v want=` read it.
export { awkAssign };

// --- spawn-sweep twins ---
import { closeSync, openSync, readSync } from "node:fs";
// A child spawned without an env option gets the environment this process
// started with, byte for byte; a later process.env write never reaches it, and
// an env option is re-encoded as UTF-8 (a 0xE9 arrives as EF BF BD). So no
// spawn passes one: a name set or deleted since start reaches the child
// through env(1), every other name keeps its bytes. env(1) answers a command
// it cannot launch with 127 (or execvp's next PATH match) where Bun throws,
// and every caller reads that throw as the shell's "could not start" (EACCES
// its 126), so the command and the absolute #! interpreter it names are
// looked up first and throw what Bun throws. An interpreter that starts
// (`#!/usr/bin/env NAME` with NAME missing) is the child's own 127 either way.
// env's execvp hands a file the kernel refuses to /bin/sh, so one without a
// #! that bash would not call binary goes to enoexecArgv's /bin/bash first.
const STARTED_ENV = { ...process.env };

function launchError(code: string, argv0: string): Error {
  return Object.assign(new Error(`${code}: ${argv0}`), { code, path: argv0 });
}

function envRun(argv: string[], cwd: string | undefined): string[] {
  const argv0 = argv[0]!;
  let file: string | null;
  if (argv0.includes("/")) {
    file = resolve(cwd ?? ".", argv0);
    try {
      accessSync(file, constants.X_OK);
    } catch (e) {
      throw launchError((e as { code?: string }).code ?? "ENOENT", argv0);
    }
    if (statSync(file).isDirectory()) throw launchError("EACCES", argv0);
  } else {
    file = Bun.which(argv0, { PATH: process.env.PATH ?? "", cwd });
    if (!file) throw launchError("ENOENT", argv0);
  }
  const head = Buffer.alloc(512);
  let n = 0;
  try {
    const fd = openSync(file, "r");
    try {
      n = readSync(fd, head, 0, head.length, 0);
    } finally {
      closeSync(fd);
    }
  } catch {
    return argv;
  }
  const lf = head.indexOf(10);
  const line = head.subarray(0, lf < 0 || lf > n ? n : lf);
  if (line[0] !== 0x23 || line[1] !== 0x21) return line.includes(0) ? argv : ["/bin/bash", argv0.includes("/") ? argv0 : file, ...argv.slice(1)];
  let s = 2;
  while (s < line.length && (line[s] === 0x20 || line[s] === 0x09)) s++;
  let e = s;
  // The kernel ends the token at a blank or LF only: a CR stays in the path.
  while (e < line.length && line[e] !== 0x20 && line[e] !== 0x09) e++;
  const raw = line.subarray(s, e);
  // The path is filesystem bytes; only one that is UTF-8 has a spelling the
  // fs calls take, so any other is left to the launch itself.
  const interp = raw.toString("utf8");
  if (!interp.startsWith("/") || !Buffer.from(interp, "utf8").equals(raw)) return argv;
  // X_OK passes a directory, which the kernel never runs as an interpreter.
  try {
    accessSync(interp, constants.X_OK);
    if (!statSync(interp).isDirectory()) return argv;
  } catch {}
  throw launchError("ENOENT", argv0);
}

function launchable(argv0: string, cwd: string | undefined): boolean {
  try {
    envRun([argv0], cwd);
    return true;
  } catch {
    return false;
  }
}

// env(1) reads every leading operand holding `=` as one more assignment, so
// such a command is exec'd by a shell instead.
function envCommand(argv: string[]): string[] {
  return argv[0]!.includes("=") ? ["/bin/sh", "-c", 'exec "$0" "$@"', ...argv] : argv;
}

function launchArgv(argv: string[], cwd: string | undefined): string[] {
  const d: string[] = [];
  for (const k of Object.keys(STARTED_ENV)) if (process.env[k] === undefined) d.push("-u", k);
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && v !== STARTED_ENV[k]) d.push(`${k}=${v}`);
  if (d.length === 0) return [...intIgnorePrefix(), ...argv];
  const run = envRun(argv, cwd);
  return ["/usr/bin/env", ...d, ...(intIgnored ? [...intIgnorePrefix(), ...run] : envCommand(run))];
}

// bash runs an executable the kernel refuses (no shebang, ENOEXEC) as a
// script of its own: the same file under /bin/bash, $0 the path it resolved,
// with the same io.
function enoexecArgv(argv: string[], e: unknown): string[] {
  if ((e as { code?: string }).code !== "ENOEXEC") throw e;
  const file = argv[0]!.includes("/") ? argv[0]! : Bun.which(argv[0]!);
  if (!file) throw e;
  return ["/bin/bash", file, ...argv.slice(1)];
}

export const spawnShellSync = ((argv: string[], opts?: Parameters<typeof Bun.spawnSync>[1]) => {
  try {
    return Bun.spawnSync(launchArgv(argv, opts?.cwd), opts);
  } catch (e) {
    return Bun.spawnSync([...intIgnorePrefix(), ...enoexecArgv(argv, e)], opts);
  }
}) as typeof Bun.spawnSync;

export const spawnShell = ((argv: string[], opts?: Parameters<typeof Bun.spawn>[1]) => {
  try {
    return Bun.spawn(launchArgv(argv, opts?.cwd), opts);
  } catch (e) {
    return Bun.spawn([...intIgnorePrefix(), ...enoexecArgv(argv, e)], opts);
  }
}) as typeof Bun.spawn;

// --- the bounded network call (src/sync.ts's twin of fetch_bounded, shared
// with src/tree.ts) ---

// `${AC_SYNC_TIMEOUT:-$(ac_config_read ...)}`: the knob is read only when the
// override is empty, and inside `$(...)` an AC_HOME that cannot be entered
// (cd's own line on stderr) or a knob this user cannot read (head's) read as
// "" - neither line is reproduced, the digit check falls back to 60 and the
// caller goes on.
export function syncTimeout(): string {
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

const sleepAsync = async (secs: string): Promise<void> => {
  await spawnShell(["sleep", secs], { stdin: "ignore", stdout: "ignore", stderr: "ignore" }).exited;
};

// fetch_bounded's mechanics (src/sync.ts header: THE BOUNDED FETCH) for any
// argv, run in <cwd> when one is given: the child leads its own process group
// and keeps the caller's stdin, its stderr is discarded; one that ends answers
// its own status and, piped, its stdout; past the deadline the GROUP is killed
// and the answer is 124 with the output read so far; one that cannot start is
// 127. Piped, the call ends only when the pipe does too - a descendant can
// hold it after the leader exits, so the deadline governs both.
export async function runBounded(argv: string[], secs: string, stdout: "ignore" | "inherit" | "pipe", cwd?: string): Promise<{ status: number; out: Buffer }> {
  let child: ReturnType<typeof spawnShell>;
  try {
    child = spawnShell(argv, { detached: true, stdin: "inherit", stdout, stderr: "ignore", cwd });
  } catch {
    return { status: 127, out: Buffer.alloc(0) };
  }
  const chunks: Uint8Array[] = [];
  let drained = stdout !== "pipe";
  if (!drained) {
    const reader = (child.stdout as ReadableStream<Uint8Array>).getReader();
    void (async () => {
      try {
        for (let r = await reader.read(); !r.done; r = await reader.read()) chunks.push(r.value);
      } catch {}
      drained = true;
    })();
  }
  let status: number | null = null;
  const ended = child.exited.then(() => {
    status = child.exitCode ?? 128 + ((osConstants.signals as Record<string, number>)[child.signalCode ?? ""] ?? 0);
  });
  const limit = Number(secs);
  const start = Math.floor(Date.now() / 1000);
  const killGroup = (sig: "SIGTERM" | "SIGKILL"): void => {
    try {
      process.kill(-child.pid, sig);
    } catch {}
  };
  while (status === null || !drained) {
    if (Math.floor(Date.now() / 1000) - start >= limit) {
      killGroup("SIGTERM");
      await sleepAsync("0.5");
      killGroup("SIGKILL");
      await ended;
      return { status: 124, out: Buffer.concat(chunks) };
    }
    await sleepAsync("0.2");
  }
  return { status, out: Buffer.concat(chunks) };
}

// --- room twins ---

// The bin/ of the root bun was started in: bin/ac-bun.sh cd's there before the
// exec, and an import runs before enterCaller leaves it. A lab bin/ whose root
// links or copies src/ so drives its OWN sibling scripts and bash libs, never
// the distro's that import.meta.dir resolves to.
export const STARTED_BIN = `${process.cwd()}/bin`;

// ac_config_read as the bash read it, a reader that never refuses: an AC_HOME
// cd cannot enter is the default (the shell printed cd's own line), and a
// file that cannot be read is head(1)'s own line - on <stderr>, the caller's
// redirection - and "", not the default, as `line="$(head -n1 "$f")"` left it.
export function configReadSoft(name: string, dflt = "", stderr: "inherit" | "ignore" = "inherit"): string {
  const h = process.env.AC_HOME;
  if (h && physicalDir(h) === null) return dflt;
  try {
    return configRead(name, dflt);
  } catch {
    headLine(join(envHome(), "config", name), stderr);
    return "";
  }
}

function headLine(file: string, stderr: "inherit" | "ignore" = "inherit"): number {
  try {
    return shellStatus(spawnShellSync(["head", "-n1", file], { stdin: "inherit", stdout: "ignore", stderr }));
  } catch {
    return 127;
  }
}

// The shell's [:space:] under the locale bash was given, as shellTrim reads it.
export function shellSpaceClass(): RegExp {
  const loc = process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "";
  return /utf-?8/i.test(loc) ? /(?:(?!\x85)\p{White_Space})/gu : /[ \t\n\v\f\r]/g;
}

// ac_backend's twin (bin/ac-backend.sh keeps its own for the drivers):
// AC_BACKEND, else config/backend, else the first line of
// <AC_FLEET_STATE less one trailing slash>/../config/backend cut at its first
// [:space:], else herdr; any other name is refused with the bash's text. That
// last file unreadable ended the bash with head's line and status, and so here.
// `soft` is ac-backend.sh sourced with stderr dropped and errexit asleep
// (bin/ac-guard.sh's `. ac-backend.sh 2>/dev/null || exit 0`): nothing is
// printed, an unreadable rung reads as no name, a bad name is a bare exit 1.
export function backendName(soft = false): string {
  let b = process.env.AC_BACKEND || configReadSoft("backend", "", soft ? "ignore" : "inherit");
  const fs = process.env.AC_FLEET_STATE;
  if (b === "" && fs) {
    const f = `${fs.endsWith("/") ? fs.slice(0, -1) : fs}/../config/backend`;
    if (isFile(f)) {
      try {
        b = readFileSync(f, "utf8").split("\n")[0]!.replace(/\0/g, "");
      } catch {
        if (!soft) process.exit(headLine(f));
      }
      b = b.split(shellSpaceClass())[0]!;
    }
  }
  b ||= "herdr";
  if (b !== "herdr" && b !== "orca") {
    if (soft) process.exit(1);
    die(`unsupported backend '${b}' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)`);
  }
  return b;
}

// ac_task_backend's twin: the backend <id> was spawned on (its meta's
// backend=), herdr without one; an unreadable meta warns as ac_meta_get does
// and reads herdr.
export function taskBackend(id: string): string {
  let b = "";
  try {
    b = metaGet(taskMeta(id), "backend");
  } catch {}
  return b || "herdr";
}

// ac_vn_ts's twin, the captain-display stamp: date(1) with TZ ADDED, read as
// `$(...)` reads it, and the shell's status for date - its caller decides what
// a failure costs. TZ rides env(1) itself: Bun keeps a TZ written to
// process.env out of its enumeration, so spawnShellSync would never pass it.
export function vnTs(): { status: number; stamp: string } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["/usr/bin/env", "TZ=Asia/Ho_Chi_Minh", "date", "+%Y-%m-%d %H:%M"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), stamp: r ? r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "") : "" };
}

// ac_verb_emoji's twin: first matching prefix wins, the note for the rest.
const VERB_EMOJI: [string[], string][] = [
  [["ORDER"], "\u{1f4cc}"],
  [["TRIAGE"], "\u{1f9ed}"],
  [["GATE-PASSED", "SELF-APPROVED"], "\u2611\ufe0f"],
  [["GATE"], "\u{1f6a6}"],
  [["ASK"], "\u2753"],
  [["DECIDED"], "\u2705"],
  [["LANDED", "DONE"], "\u{1f389}"],
  [["UNLANDABLE"], "\u{1f9f1}"],
  [["HANDBACK"], "\u{1f91d}"],
  [["PROMOTED"], "\u{1f9f5}"],
  [["DEMOTED"], "\u{1f53b}"],
  [["CLOSED"], "\u{1f512}"],
  [["START"], "\u{1f680}"],
  [["FAILED", "BLOCKED"], "\u26d4"],
];

export function verbEmoji(verb: string): string {
  for (const [prefixes, emoji] of VERB_EMOJI) if (prefixes.some((p) => verb.startsWith(p))) return emoji;
  return "\u{1f4dd}";
}

// `${s:0:n}` over a value held as bytes (latin1): under a UTF-8 locale a
// strictly valid UTF-8 sequence is one character and every other byte one
// (bash 3.2's mbrlen - overlongs, surrogates and cut sequences count per
// byte), under any other locale a byte is a character.
const STRICT_UTF8 = new TextDecoder("utf-8", { fatal: true });

export function shellPrefix(s: string, n: number): string {
  const loc = process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "";
  if (!/utf-?8/i.test(loc)) return s.slice(0, n);
  let i = 0;
  for (let chars = 0; i < s.length && chars < n; chars++) {
    const c = s.charCodeAt(i);
    const len = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1;
    let step = 1;
    if (len > 1 && i + len <= s.length) {
      try {
        STRICT_UTF8.decode(Buffer.from(s.slice(i, i + len), "latin1"));
        step = len;
      } catch {}
    }
    i += step;
  }
  return s.slice(0, i);
}

// ac_spool_has_record's twin over `"$spool"/*`: some non-dot entry that
// `[ -e ]` finds (a subdirectory counts, a dangling link does not).
export function spoolHasRecord(dir: string): boolean {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names.some((n) => !n.startsWith(".") && existsSync(`${dir}/${n}`));
}

// The path helpers as `$(...)` reads them, for an entry that goes on with "".
export { softSubdir };

// --- remote twins ---

// `trap '' INT` leaves SIGINT ignored in every child the shell starts while it
// is set, and Bun resets SIGINT to the default in every child it starts - so
// while a caller holds the ignore (src/remote.ts's stash-to-wake commit), both
// spawn helpers start the command through /bin/sh, which ignores INT and execs
// it.
let intIgnored = false;

export function childrenIgnoreInt(on: boolean): void {
  intIgnored = on;
}

function intIgnorePrefix(): string[] {
  return intIgnored ? ["/bin/sh", "-c", 'trap "" INT; exec "$0" "$@"'] : [];
}

// `$(...)`'s reading of a child's stdout: NULs dropped, trailing LFs stripped,
// the bytes kept (latin1).
export function capturedText(b: Buffer): string {
  return b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
}

// ac_now as the shell spelled it, where now() reads a Number: a non-empty
// EPOCHSECONDS wins (bash 3.2 has no such builtin, so an exported one is read
// as the capture read it), else date(1)'s `+%s` as `$(...)` kept it, "" when
// date cannot run. stderr "ignore" is a caller's `2>/dev/null`.
export function nowRaw(stderr: "inherit" | "ignore" = "inherit"): string {
  const e = process.env.EPOCHSECONDS;
  // `$(ac_now)` read the printf of the variable: trailing LFs stripped like
  // any capture's, a value of only LFs reading as the empty operand.
  if (e) return Buffer.from(e, "utf8").toString("latin1").replace(/\n+$/, "");
  try {
    return capturedText(spawnShellSync(["date", "+%s"], { stdin: "inherit", stdout: "pipe", stderr }).stdout);
  } catch {
    return "";
  }
}

// ac_room_pending_lines' twin, retired from bin/ac-wake-lib.sh with its last
// caller: the unanswered GATE/ASK lines of one room, oldest first, joined by
// LF - each DECIDED settles the oldest open item and one with nothing open
// settles nothing, the count ac_room_pending reads. The room is bytes (latin1,
// a line cut at its first NUL, the C-locale reading); "" for a path that is no
// regular file, null for a room that cannot be read.
const ROOM_OPEN = /^- \[[^\]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;
const ROOM_DECIDED = /^- \[[^\]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/;

export function roomPendingLines(file: string): string | null {
  if (!isFile(file)) return "";
  let text: string;
  try {
    text = readFileSync(file, "latin1");
  } catch {
    return null;
  }
  const open: string[] = [];
  let settled = 0;
  for (const l of records(text)) {
    if (ROOM_OPEN.test(l)) open.push(l);
    if (ROOM_DECIDED.test(l) && settled < open.length) settled++;
  }
  return open.slice(settled).join("\n");
}

// src/remote.ts reads a family-keyed stamp with awk's `$1==k`, numeric when
// both sides look numeric, and launches a hook with exec only when its #!
// interpreter can start.
export { awkNumber, launchable };

// --- guard twins ---

// An operand of bash 3.2's `[ a -gt b ]` (legal_number, strtoimax in base 10):
// C isspace before, one optional sign, decimal digits, space or TAB after,
// inside int64 - `010` is ten; `0x10`, `1e3`, `' '` and `''` are no number.
// null is the test's `integer expression expected`: status 2, read as false.
export function testInt(s: string): bigint | null {
  const m = /^[ \t\n\v\f\r]*([+-]?[0-9]+)[ \t]*$/.exec(s);
  if (!m) return null;
  const v = BigInt(m[1]!);
  return v < -(2n ** 63n) || v >= 2n ** 63n ? null : v;
}

function arithError(what: string): Error {
  return Object.assign(new Error(what), { code: "EARITH" });
}

// bash 3.2's strlong: a leading 0 is octal, 0x hex, <base>#<digits> any base
// 2..64, accumulated with intmax_t's wrap.
function strlong(num: string): bigint {
  let base = 10n;
  let found = false;
  let i = 0;
  if (num[0] === "0") {
    if (num.length === 1) return 0n;
    found = true;
    i = num[1] === "x" || num[1] === "X" ? 2 : 1;
    base = i === 2 ? 16n : 8n;
  }
  let val = 0n;
  for (; i < num.length; i++) {
    const c = num.charCodeAt(i);
    if (c === 0x23) {
      if (found) throw arithError("invalid number");
      if (val < 2n || val > 64n) throw arithError("invalid arithmetic base");
      base = val;
      val = 0n;
      found = true;
      continue;
    }
    const d = c <= 0x39 ? c - 0x30 : c >= 0x61 ? c - 0x61 + 10 : c === 0x40 ? 62 : c <= 0x5a ? c - 0x41 + (base <= 36n ? 10 : 36) : 63;
    if (BigInt(d) >= base) throw arithError("value too great for base");
    val = BigInt.asIntN(64, val * base + BigInt(d));
  }
  return val;
}

// What `$(( ))` makes of a text holding ONE operand - a variable's value read
// as an expression, or text substituted into one: space, TAB and LF around,
// one optional sign, a constant (strlong); empty is 0. A digit too great for
// its base, or anything after the operand, throws EARITH: the shell discarded
// the command the expansion stood in and went on. An identifier throws
// EUNBOUND: no variable is set under that name here, so set -u ended the
// script with the status of the last command it ran. A text that is an
// expression (`1+1`, `12 abc`) is past this model and reads as EARITH.
export function arithValue(text: string): bigint {
  let t = text.replace(/^[ \t\n]+|[ \t\n]+$/g, "");
  if (t === "") return 0n;
  let neg = false;
  if (t[0] === "+" || t[0] === "-") {
    neg = t[0] === "-";
    t = t.slice(1).replace(/^[ \t\n]+/, "");
  }
  if (/^[A-Za-z_]/.test(t)) throw Object.assign(new Error(`${t}: unbound variable`), { code: "EUNBOUND" });
  const m = /^[0-9][0-9A-Za-z_@#]*/.exec(t);
  if (!m) throw arithError("operand expected");
  const v = strlong(m[0]);
  if (m[0] !== t) throw arithError("syntax error in expression");
  return BigInt.asIntN(64, neg ? -v : v);
}

// ac_watcher_down's twin (bin/ac-wake-lib.sh), behind the guard's
// WATCHER-DOWN: supervision is owed when
// crewMetas(sd, "verify", "self") lists a path - a roomchief, a crewdeputy, a
// kind-less meta and `kind=self\r` count - and the watcher is down when
// `$(( <nowRaw> - <beat> ))`, beat the scope's beacon (watcherBeatRead), is
// `[ -gt ]` AC_GUARD_GRACE (unset or empty: 300; testInt's grammar, no number
// never down). The clock text's EARITH discarded the caller's whole command:
// not down. EUNBOUND is thrown, the caller's script having ended there.
export async function watcherDown(sd: string, scope: string): Promise<boolean> {
  let inflight = 0;
  for await (const _ of crewMetas(sd, "verify", "self")) inflight++;
  if (inflight === 0) return false;
  const beat = BigInt(watcherBeatRead(sd, scope).split(" ")[0]!);
  let age: bigint;
  try {
    age = BigInt.asIntN(64, arithValue(nowRaw()) - beat);
  } catch (e) {
    if ((e as { code?: string }).code === "EARITH") return false;
    throw e;
  }
  const grace = testInt(process.env.AC_GUARD_GRACE || "300");
  return grace !== null && age > grace;
}

// ac_wake_pending's twin: the scope's own spool (wakeSpoolPath - a malformed
// scope's is the fleet's) holds a record (spoolHasRecord).
export function wakePending(sd: string, scope: string): boolean {
  return spoolHasRecord(wakeSpoolPath(sd, scope));
}

// ac_roomchief_live's twin: no chief meta (`[ -e ]`) is not live with no
// backend touched; else windowAliveAs probes <fam>-chief under the meta's
// backend=. Only status 0 is live: 1 gone, 2 unreadable and a refused backend
// name are orphans alike. stdin and stdout are dropped unless the caller
// passes its own: ac_wake_orphan_files' subshell wrote its stdout into the
// list it fed and handed the backgrounded herdr /dev/null (the orca CLI it
// handed the family-list pipe - src/guard.ts names that), while the drain's
// completion scope left both to the probe - a stdin only orca reads, the
// probe's `( )` handing herdr /dev/null there too.
export function roomchiefLive(sd: string, fam: string, io: ProbeIo = { stdin: "ignore", stdout: "ignore" }): boolean {
  const m = `${sd}/${fam}-chief.meta`;
  return existsSync(m) && windowAliveAs(m, `${fam}-chief`, io);
}

// ac_wake_orphan_pending's twin: the family spools (wakeFamilySpools, byte
// order) in turn, each family's liveness probed before its records are looked
// at; the first orphan holding a record answers.
export function wakeOrphanPending(sd: string): boolean {
  for (const d of wakeFamilySpools(sd)) {
    const fam = d.slice(d.lastIndexOf("/.wake-spool.") + "/.wake-spool.".length);
    if (!roomchiefLive(sd, fam) && spoolHasRecord(d)) return true;
  }
  return false;
}

// ac_repo_root's twin: `dirname` of `git -C <dir> rev-parse
// --path-format=absolute --git-common-dir` (stdin the caller's, stderr
// dropped, trailing LFs stripped), null when git fails - a linked worktree's
// MAIN root, a bare x.git's parent. <dir> goes to git as given, where
// projectDir resolves it physically first; git answers a canonical absolute
// path, on which path's dirname and dirname(1) agree.
export function repoRoot(dir: string): string | null {
  try {
    const r = spawnShellSync(["git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
    if (r.exitCode === 0) return dirname(r.stdout.toString().replace(/\0/g, "").replace(/\n+$/, ""));
  } catch {}
  return null;
}

// --- merge-local twins ---

export const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");

export const sleepOne = (): void => {
  spawnShellSync(["sleep", "1"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
};

// ac_project_config_name's twin: the basename of the main repo dir git's
// common dir names, so a linked worktree answers its main repo, its trailing
// LFs cut as every caller's `$(...)` cut them; null when git cannot say.
function projectConfigName(repo: string): string | null {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  if (r === null || r.exitCode !== 0) return null;
  const main = capturedText(Buffer.from(r.stdout)).replace(/\/\.git$/, "");
  const trimmed = main.replace(/\/+$/, "");
  const base = trimmed === "" ? (main === "" ? "" : "/") : trimmed.slice(trimmed.lastIndexOf("/") + 1);
  return Buffer.from(base, "latin1").toString("utf8").replace(/\n+$/, "");
}

// --- wake-drain twins ---

// AC_BUSY_RE's default (bin/ac-harness.sh) and AC_CAPTAIN_RE's (bin/ac-lib.sh),
// an exported non-empty value winning as it did at source time - EREs for a
// SPAWNED `grep -qE` over a pane tail, so the classes and the ellipsis bytes match
// as grep matches them under the caller's locale. Held to those files by
// tests/ts/wake-drain.test.ts.
export const BUSY_RE = process.env.AC_BUSY_RE || "esc (to )?interrupt|Working\u2026|Working\\.\\.\\.|Ctrl\\+c:cancel|[Tt]hinking";
export const CAPTAIN_RE =
  process.env.AC_CAPTAIN_RE || "^[^[:alpha:][:digit:]\"'`=+#/*-]*(done|needs-decision|blocked|failed|paused|merged|checks-passed):([[:space:]]|$)";

export const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");

// ac_meta_is_self's twin: kind= is exactly `self` as ac_meta_get's awk read it
// (cut at a NUL); an absent, kind-less or unreadable meta is none, silently.
export function metaIsSelf(file: string): boolean {
  try {
    accessSync(file, constants.R_OK);
    return cutNul(metaGet(file, "kind")) === "self";
  } catch {
    return false;
  }
}

export type ProbeIo = { stdin: "inherit" | "ignore"; stdout: "inherit" | "ignore" };

// `( AC_BACKEND="${b:-herdr}"; export AC_BACKEND; backend_window_alive
// <target> ) 2>/dev/null`, <b> the meta's backend= read as `ac_meta_get ...
// 2>/dev/null || true` read it (cut at a NUL; an unreadable meta or no key is
// herdr): AC_BACKEND set to the text <b>'s bytes spell, as the shell's export
// did, for the ONE backendCall, a subshell call as the `( )` made it, and
// restored after; true only for status 0.
export function windowAliveAs(m: string, target: string, io: ProbeIo): boolean {
  let b = "";
  try {
    accessSync(m, constants.R_OK);
    b = cutNul(metaGet(m, "backend"));
  } catch {}
  const saved = process.env.AC_BACKEND;
  process.env.AC_BACKEND = Buffer.from(b, "latin1").toString("utf8") || "herdr";
  try {
    return backendCall("window_alive", [target], { ...io, stderr: "ignore", subshell: true }).status === 0;
  } finally {
    if (saved === undefined) delete process.env.AC_BACKEND;
    else process.env.AC_BACKEND = saved;
  }
}

// --- deputy twins ---

// ac_is_crewdeputy_home's twin: `[ -f "$(ac_home)/.ac-crewdeputy-home" ]` -
// the marker a regular file (a symlink to one counts, a directory does not);
// homeless, the refusal printed and `/.ac-crewdeputy-home` tested.
export function isCrewdeputyHome(): boolean {
  return isFile(`${softHome(true)}/.ac-crewdeputy-home`);
}

// ac_deputy_registry's twin: `<records>/crewdeputies.md`, records/ minted;
// homeless, the refusal printed and `/crewdeputies.md`.
export function deputyRegistry(): string {
  return `${softSubdir("records", true)}/crewdeputies.md`;
}

// ac_deputy_parse's program, byte for byte: tests/ts/deputy.test.ts lifts it
// out of bin/ac-lib.sh, whose function stays live for ac-spawn.
const DEPUTY_PARSE_AWK = String.raw`
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function base(p) { sub(/\/+$/, "", p); sub(/^.*\//, "", p); return p }
    function bad(reason) { printf "INVALID\t%s\t\t\t\t\t%s\n", $0, reason }
    {
      if (substr($0, 1, 2) != "- ") next
      rest = substr($0, 3)
      if (rest !~ / \(added [^)]*\)$/) { bad("missing \"(added ...)\""); next }
      sub(/ \(added [^)]*\)$/, "", rest)

      p = index(rest, " - home:")            # 8 chars
      if (p == 0) { bad("missing \"home:\" field"); next }
      head = substr(rest, 1, p - 1)
      tail = substr(rest, p + 8)

      q = index(head, " - ")                 # id, then the free-text charter
      if (q > 0) { id = trim(substr(head, 1, q - 1)); charter = trim(substr(head, q + 3)) }
      else { id = trim(head); charter = "" }

      s = index(tail, " - scope:")           # 9 chars
      if (s > 0) {
        home = trim(substr(tail, 1, s - 1))
        after = substr(tail, s + 9)
        r = index(after, " - projects:")     # 12 chars
        if (r == 0) { bad("missing \"projects:\" field"); next }
        scope = trim(substr(after, 1, r - 1))
        projects = trim(substr(after, r + 12))
        if (charter == "") { bad("missing charter field"); next }
        cls = "VALID"
      } else {
        if (charter != "") { bad("missing \"scope:\" field"); next }
        cls = "LEGACY"
        t = index(tail, " - ")
        if (t > 0) { home = trim(substr(tail, 1, t - 1)); projects = trim(substr(tail, t + 3)) }
        else { home = trim(tail); projects = "" }
        charter = "(none)"
        scope = ""
        if (projects == "no projects") projects = ""
        else gsub(/[ \t]+/, ",", projects)
      }
      if (projects == "") projects = "none"

      if (id !~ /^[a-zA-Z0-9_-]+$/) { bad("bad id charset"); next }
      if (substr(home, 1, 1) != "/") { bad("home path is not absolute"); next }
      if (base(home) != id) { bad("id does not match home basename"); next }
      if (id in seen) { bad("duplicate id"); next }
      seen[id] = 1
      printf "%s\t%s\t%s\t%s\t%s\t%s\t\n", cls, id, home, charter, scope, projects
    }
  `;

// ac_deputy_parse's twin as the argv it ran - `awk <program> <file>` under
// the caller's locale, so a byte that is not UTF-8 aborts it under a UTF-8
// one (towc, exit 2) as it did the bash - for a caller to wire into its own
// pipeline. <file> defaults to deputyRegistry(); null when it is no regular
// file, where the bash returned 0 with no record.
export function deputyParse(file = ""): string[] | null {
  if (file === "") file = deputyRegistry();
  return isFile(file) ? ["awk", DEPUTY_PARSE_AWK, file] : null;
}

export function mkdirP(dir: string): void {
  try {
    spawnShellSync(["mkdir", "-p", dir], { stdin: "inherit", stdout: "ignore", stderr: "inherit" });
  } catch {}
}

// ac_records_backup's twin (the bash one is frozen at
// tests/fixtures/ac-maintenance-retired.sh for the oracles) as `$(...)` ran
// it, errexit asleep: records/ (`[ -d ] || mkdir -p`), skills/ and
// state/backups/ minted
// by spawned mkdir -p, a failure being mkdir's own line and no stop. The
// archive <state>/backups/<prefix>-<ac_now>[-<n>].tar.gz is CLAIMED first by
// an exclusive create - two backups in one second share an epoch, and tar
// -czf truncates whatever holds the name - stepping -<n> while the name
// exists (`[ -e ]`: a dangling link does not); any other failure is
// `WARN: records backup: could not create <arc> (is <dir> writable?) - no
// backup archive was taken` and null. Then `tar -czf <arc> -C <home> records
// skills`, each crewdomains/<p>/ in byte order adding its records (when a
// directory), CREWMATE.md (a file) and projects (a directory - links, never
// followed), then state/.learn.meta, state/.curate.meta and
// CREWMATE-learned.md when files; a tar that fails has its claim removed
// (`rm -f`) and is null. The answer is the substitution's reading of the
// function's stdout, as bytes (latin1): tar's, then the path.
export function recordsBackup(prefix: string): string | null {
  const home = softHome(true);
  const records = `${home}/records`;
  if (!isDir(records)) mkdirP(records);
  mkdirP(`${home}/skills`);
  mkdirP(`${home}/state`);
  const bdir = `${home}/state/backups`;
  mkdirP(bdir);
  const epoch = nowRaw();
  let arc = `${bdir}/${prefix}-${epoch}.tar.gz`;
  for (let n = 1; ; n++) {
    try {
      closeSync(openSync(arc, "wx"));
      break;
    } catch {
      if (!existsSync(arc)) {
        warn(`records backup: could not create ${arc} (is ${bdir} writable?) - no backup archive was taken`);
        return null;
      }
      arc = `${bdir}/${prefix}-${epoch}-${n}.tar.gz`;
    }
  }
  const members = ["records", "skills"];
  let pkgs: string[] = [];
  try {
    pkgs = readdirSync(`${home}/crewdomains`);
  } catch {}
  for (const p of pkgs.filter((x) => !x.startsWith(".")).sort((x, y) => Buffer.compare(Buffer.from(x), Buffer.from(y)))) {
    const pkg = `${home}/crewdomains/${p}`;
    if (!isDir(`${pkg}/records`)) continue;
    members.push(`crewdomains/${p}/records`);
    if (isFile(`${pkg}/CREWMATE.md`)) members.push(`crewdomains/${p}/CREWMATE.md`);
    if (isDir(`${pkg}/projects`)) members.push(`crewdomains/${p}/projects`);
  }
  for (const f of ["state/.learn.meta", "state/.curate.meta", "CREWMATE-learned.md"]) if (isFile(`${home}/${f}`)) members.push(f);
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["tar", "-czf", arc, "-C", home, ...members], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  if (shellStatus(r) !== 0) {
    try {
      spawnShellSync(["rm", "-f", arc], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
    } catch {}
    return null;
  }
  return capturedText(Buffer.concat([Buffer.from(r!.stdout), Buffer.from(`${arc}\n`)]));
}

// --- qa-gate twins ---
// The qa.require_for_ship merge gate src/merge-local.ts and src/pr-merge.ts
// run: tests/fixtures/ac-qa-lib.sh's ac_qa_required, ac_qa_gate_ok, ac_qa_gate_matrix
// and ac_qa_attestation_parse, which stay as the oracles
// tests/ts/qa-gate.test.ts holds these to (the parser stays live for
// the frozen ac-qa.sh and ac-verify.sh oracles too). The sha, paths and printed values are
// bytes (latin1); <repo>, <task> and the repo name and root git answers are
// native strings, which APFS makes round-trip (it refuses a name that is no
// UTF-8, EILSEQ). Files are read in the C locale, as the oracle's awk
// readings and its spelled-out name class read them under any locale: a NBSP
// is no space there, so a NBSP-indented require_for_ship closes the qa block
// (not enforced) on both sides. Named divergences: under a UTF-8 locale the
// bash's glob lists the scoped candidates in collation order (`a` before
// `B`), here in byte order - the same pairs and skips, in another order; the
// bash reads the matrix rows through a here-doc temp (a bad TMPDIR falls
// back to /tmp) - with none to be had its loop would read no row and pass
// `all 0` - unprobed, and nothing here needs a temp (fail-closed).

export const latBuf = (s: string): Buffer => Buffer.from(s, "latin1");
// ac_project_config_file's twin, the name resolved before the home is looked
// at: <home>/projects/<name>.yaml when it is a regular file, else null. A
// regular file at the RETIRED <home>/config/projects/<name>.yaml is checked
// first: `loud` (the bash's bare call) writes ac_die's line and throws status
// 1, the exit of the whole shell; quiet (a `$(...)` with stderr dropped) it
// is null like a homeless or unenterable home.
export function qaConfigFile(repo: string, loud: boolean): string | null {
  const n = projectConfigName(repo);
  if (n === null) return null;
  const name = lat(n);
  const home = softHome(loud);
  if (home === "") return null;
  const canonical = `${lat(home)}/projects/${name}.yaml`;
  const legacy = `${lat(home)}/config/projects/${name}.yaml`;
  if (isFile(latBuf(legacy))) {
    if (!loud) return null;
    writeSync(
      2,
      latBuf(
        `ERROR: project config for '${name}' found at the RETIRED legacy path (${legacy}), which is no longer read - move it: mv "${legacy}" "${canonical}" (or delete it if ${canonical} is already authoritative)\n`,
      ),
    );
    throw Object.assign(new Error(`RETIRED legacy project config ${legacy}`), { status: 1 });
  }
  return isFile(latBuf(canonical)) ? canonical : null;
}

// --- backend twins ---

type BackendFn = "window_alive" | "target" | "focus" | "capture" | "mark_wait" | "clear_wait" | "agent_blocked" | "harness_up" | "send_key" | "send_line";
export type Stdio = "inherit" | "ignore" | "pipe";

// One spawned child as a shell stage: its status (shellStatus), its stdout
// when piped.
export function stage(cmd: string[], stdin: "inherit" | "ignore" | Buffer, stdout: Stdio, stderr: "inherit" | "ignore"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// A here-string's jq: <text> and a LF on stdin.
export function jqOver(args: string[], text: string, stdout: Stdio, stderr: "inherit" | "ignore"): { status: number; out: Buffer } {
  return stage(["jq", ...args], Buffer.from(`${text}\n`, "latin1"), stdout, stderr);
}

// A field read as bytes goes to a child's argv decoded: a byte that is not
// UTF-8 reaches it as U+FFFD where the bash passed the byte (W17, named).
export const argvOf = (b: string): string => Buffer.from(b, "latin1").toString("utf8");

// ac_backend as the route read it (`b="$(ac_backend)" || exit 1`, errexit
// asleep): AC_BACKEND verbatim, else config/backend (configReadSoft), else
// the first line of <AC_FLEET_STATE less one trailing slash>/../config/backend
// cut at its first [:space:] - unreadable, head's line and no name - else
// herdr. Any other name is the ERROR line and null. The driver also ran this
// ladder once when it was sourced, so an unreadable knob's head line came
// once more per sourcing process (named).
function backendRoute(stderr: "inherit" | "ignore"): string | null {
  let b = process.env.AC_BACKEND || configReadSoft("backend", "", stderr);
  const fs = process.env.AC_FLEET_STATE;
  if (b === "" && fs) {
    const f = `${fs.endsWith("/") ? fs.slice(0, -1) : fs}/../config/backend`;
    if (isFile(f)) {
      try {
        b = readFileSync(f, "utf8").split("\n")[0]!.replace(/\0/g, "");
      } catch {
        headLine(f, stderr);
      }
      b = b.split(shellSpaceClass())[0]!;
    }
  }
  b ||= "herdr";
  if (b === "herdr" || b === "orca") return b;
  if (stderr === "inherit") writeSync(2, prefixed("ERROR: ", `unsupported backend '${b}' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)`));
  return null;
}

// ac_pane_field's twin: `awk -v n=<n> '{print $n; exit}' <state>/.pane-<id>`,
// awk's failure "", read as `$(...)` reads it (latin1) - awk spawned so the
// first record, the blank split, a NUL and a FIFO read as they did. state/ is
// minted per path as ac_state_dir minted it; homeless, the refusal is printed
// when stderr is passed and `/.pane-<id>` is read.
function paneField(id: string, n: number, report: boolean): string {
  return capturedText(stage(["awk", "-v", `n=${n}`, "{print $n; exit}", `${softSubdir("state", report)}/.pane-${id}`], "ignore", "pipe", "ignore").out);
}

// herdr_rpc_timeout's twin: AC_HERDR_RPC_TIMEOUT, else config/herdr-rpc-timeout,
// digits only and not `0`, else 2 - `00` passes.
function herdrRpcTimeout(): string {
  const t = process.env.AC_HERDR_RPC_TIMEOUT || configReadSoft("herdr-rpc-timeout", "", "ignore");
  return /^[0-9]+$/.test(t) && t !== "0" ? t : "2";
}

// herdr_cli through herdr_rpc_bounded: `herdr <args>`, plus `--session <s>`
// and HERDR_SESSION for the child when AC_HERDR_SESSION or
// config/herdr-session names one, both knobs re-read per RPC; herdr's stderr
// goes where the call site sends it, dropped by default (`pipe` returns the
// bytes). The call leads its own process group (setsid,
// where the original's `set -m` job led a group only - named) so the ceiling
// reaches what it forked: Bun's timeout TERMs the leader, the group is TERMed
// and KILLed once it is reaped (the original TERMed the group at the ceiling
// itself - named), and a call the ceiling reached reads 124 unless it ended
// 0. spawnSync returns when the leader exits, so a TERM-ignoring grandchild
// holding stdout cannot hold the caller - and bytes it writes after the
// leader's exit are not read, where a `$( )` read to EOF (named). sleep(1)
// refuses past 2147483647 s, so the original's watchdog fires at once there,
// as at 0. Bun's timeout wraps past 2^31-1 ms (measured, bun 1.3.13), so a
// ceiling longer than that, which the original slept in full, is no ceiling
// here (named).
function herdrCli(args: string[], stdin: "inherit" | "ignore", stdout: "ignore" | "pipe", stderr: Stdio = "ignore"): { status: number; out: Buffer; err: Buffer } {
  const s = process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "", "ignore");
  const secs = Number(herdrRpcTimeout());
  const saved = process.env.HERDR_SESSION;
  if (s) process.env.HERDR_SESSION = s;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["herdr", ...args, ...(s ? ["--session", s] : [])], {
      stdin,
      stdout,
      stderr,
      detached: true,
      timeout: secs < 1 || secs > 2147483647 ? 1 : secs * 1000 <= 2 ** 31 - 1 ? secs * 1000 : undefined,
    });
  } catch {
  } finally {
    if (saved === undefined) delete process.env.HERDR_SESSION;
    else process.env.HERDR_SESSION = saved;
  }
  let status = shellStatus(r);
  if (r?.exitedDueToTimeout && status !== 0) {
    for (const sig of ["SIGTERM", "SIGKILL"] as const)
      try {
        process.kill(-r.pid, sig);
      } catch {}
    status = 124;
  }
  return { status, out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0), err: stderr === "pipe" && r ? Buffer.from(r.stderr) : Buffer.alloc(0) };
}

// orca_json's twin: `orca <args> --json`, stdout captured, stderr dropped, no
// ceiling; then `jq -e '.ok == true'` over the capture, the stream's LAST
// value deciding. null when either fails, else the capture as the caller's
// `$(...)` read it back.
function orcaJson(args: string[], stdin: "inherit" | "ignore"): string | null {
  const r = stage(["orca", ...args, "--json"], stdin, "pipe", "ignore");
  if (r.status !== 0) return null;
  const out = capturedText(r.out);
  return jqOver(["-e", ".ok == true"], out, "ignore", "ignore").status === 0 ? out : null;
}

const LIVENESS = `
        if (.result.panes | type) == "array"
        then (if any(.result.panes[]; .pane_id == $p) then "alive" else "gone" end)
        else "unreadable" end`;

const SHELLS = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"];
// `${n##*/}` then `${n#-}`: a path is its command, a login shell's argv0 `-zsh`.
const commandName = (n: string): string => n.slice(n.lastIndexOf("/") + 1).replace(/^-/, "");
const IDLE_GLYPH = lat("✳");
// orca_title_spinner's prefixes: claude's spinner glyphs, then codex's braille
// block by its lead bytes (E2 A0-A3), whichever cell the animation shows.
const SPINNERS = ["◐", "◓", "◑", "◒", "✻", "✽", "✢", "✶", "·", "⏺"].map(lat).concat(["\xe2\xa0", "\xe2\xa1", "\xe2\xa2", "\xe2\xa3"]);
export const spins = (title: string): boolean => SPINNERS.some((g) => title.startsWith(g));
// The key spellings herdr_key_name and orca_send_key_pane both case on, by
// herdr's name for each.
export const keyNamed = (k: string): "enter" | "escape" | "ctrl+c" | null =>
  ["Enter", "enter"].includes(k) ? "enter" : ["Escape", "escape", "Esc", "esc"].includes(k) ? "escape" : ["C-c", "c-c", "ctrl+c", "Ctrl+C"].includes(k) ? "ctrl+c" : null;
// The composer readings run under LC_ALL=C: [:space:] is the ASCII six, and a
// glyph is its bytes.
const C_SPACE = /[ \t\n\v\f\r]/g;
const RULE_RUN = new RegExp(`(?:${lat("─")}){8,}`);
const PROMPT_ROW = new RegExp(`^[ \\t\\n\\v\\f\\r]*${lat("❯")}(?:${lat("\u00a0")})?`);
// The locale bash counts a string's length and offsets in, by its name:
// LC_ALL, else LC_CTYPE, else LANG. A UTF-8 name the host has no locale for
// left bash counting bytes (probed: xx_YY.UTF-8) - named.
const utf8Locale = (): boolean => /utf-?8/i.test(process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "");

// The backend_* verbs of bin/ac-backend.sh that src/ calls, both drivers, as
// a bash caller ran them:
// the route per call on process.env.AC_BACKEND (a refused name is exited,
// status 1, its line on stderr, nothing read or minted), then the driver's
// arm. Window liveness answers 0 alive, 1 gone, 2 unreadable (ac-backend.sh's
// WINDOW LIVENESS); focus answers herdr's own status (124 at the ceiling, 127
// absent); mark_wait/clear_wait answer touch's / rm's; agent_blocked 0
// blocked, 1 not, stamped or unreadable (orca: jq -e's own status);
// harness_up 0 up, 1 a bare shell, 2 unreadable (HARNESS CAME-UP PROBE);
// send_key herdr's focus, then send-keys' own status
// - a failing focus is returned before any key, as ac-send.sh's bare call
// under errexit ended there (a caller under `||` pressed the key anyway:
// named) - and orca's one send, 0 or 1. send_line types its arguments
// joined by a space and verifies the Enter by the render
// (ac-backend.sh's delivery verification): 0 accepted, 1 stranded, 2
// unreadable, 3 a claude composer not proven so nothing submitted (herdr
// only - orca answers a pane a dialog owns 1), the reason on stderr. stdin
// by POSITION: the original's
// top-level herdr calls (window_alive's pane get, tab focus, send-keys,
// send-text, report-agent, release-agent) read the caller's stdin
// unless the verb ran in a `( )` - `subshell` - and every herdr call inside a
// `$( )` or a pipeline read /dev/null in a fresh shell (once a compound
// command with a stdin redirect had run - harness_up's own `done <<<` -
// bash 3.2 handed a later one the caller's stdin: named, not reproduced);
// orca, a foreground command, always reads the caller's. stdout and stderr
// are where the call site sent them ("pipe" returns the bytes); the jqs whose
// stderr the bash left open (herdr agent_blocked's status, orca harness_up's
// title reads) write jq's error there.
export function backendCall(
  fn: BackendFn,
  args: string[],
  io: { stdin?: "inherit" | "ignore"; stdout: Stdio; stderr: "inherit" | "ignore"; subshell?: boolean },
): { status: number; exited: boolean; out: Buffer } {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true, out: Buffer.alloc(0) };
  const chunks: Buffer[] = [];
  const say = (buf: Buffer): void => {
    if (io.stdout === "pipe") chunks.push(buf);
    else if (io.stdout === "inherit") writeSync(1, buf);
  };
  const status = (b === "herdr" ? herdrVerb : orcaVerb)(fn, args, io, say);
  return { status, exited: false, out: Buffer.concat(chunks) };
}

export type VerbIo = Parameters<typeof backendCall>[2];

export function herdrVerb(fn: BackendFn, args: string[], io: VerbIo, say: (b: Buffer) => void): number {
  const id = args[0] ?? "";
  const report = io.stderr === "inherit";
  const top = io.subshell ? "ignore" : (io.stdin ?? "inherit");
  const pane = (): string => paneField(id, 1, report);
  switch (fn) {
    case "target":
      say(Buffer.from(`herdr:pane-${pane()}\n`, "latin1"));
      return 0;
    case "window_alive": {
      const p = pane();
      if (p === "") return 1;
      if (herdrCli(["pane", "get", argvOf(p)], top, "ignore").status === 0) return 0;
      const list = herdrCli(["pane", "list"], "ignore", "pipe");
      if (list.status !== 0) {
        const running = stage(["jq", "-r", ".running"], herdrCli(["status", "server", "--json"], "ignore", "pipe").out, "pipe", "ignore");
        return capturedText(running.out) === "false" ? 1 : 2;
      }
      const v = capturedText(jqOver(["-r", "--arg", "p", argvOf(p), LIVENESS], capturedText(list.out), "pipe", "ignore").out);
      return v === "alive" ? 0 : v === "gone" ? 1 : 2;
    }
    case "focus":
      return herdrCli(["tab", "focus", argvOf(paneField(id, 2, report))], top, "ignore").status;
    case "capture": {
      const p = pane();
      const lines = args[1] || "40";
      if (p === "") return 1;
      const n = testInt(lines);
      const read = herdrCli(["pane", "read", argvOf(p), "--source", "recent", "--lines", n !== null && n >= 200n ? lines : "200"], "ignore", "pipe");
      if (read.status !== 0) return 1;
      const t = stage(["tail", "-n", lines], Buffer.from(`${capturedText(read.out)}\n`, "latin1"), io.stdout, io.stderr);
      say(t.out);
      return t.status;
    }
    case "mark_wait": {
      const msg = args[1] || "awaiting captain decision";
      const p = pane();
      if (p === "") return 1;
      if (herdrCli(["pane", "report-agent", argvOf(p), "--source", "ac-fleet", "--agent", "crew", "--state", "blocked", "--message", msg], top, "ignore").status !== 0) return 1;
      return stage(["touch", `${softSubdir("state", report)}/.captain-wait-${id}`], "ignore", "ignore", io.stderr).status;
    }
    case "clear_wait": {
      const wf = `${softSubdir("state", report)}/.captain-wait-${id}`;
      if (!existsSync(wf)) return 0;
      const p = pane();
      if (p !== "") herdrCli(["pane", "release-agent", argvOf(p), "--source", "ac-fleet", "--agent", "crew"], top, "ignore");
      return stage(["rm", "-f", wf], "ignore", "ignore", io.stderr).status;
    }
    case "agent_blocked": {
      if (existsSync(`${softSubdir("state", report)}/.captain-wait-${id}`)) return 1;
      const p = pane();
      if (p === "") return 1;
      const get = herdrCli(["pane", "get", argvOf(p)], "ignore", "pipe");
      if (get.status !== 0) return 1;
      const status = jqOver(["-r", '[.. | .agent_status? // empty] | map(select(. != "")) | first // empty'], capturedText(get.out), "pipe", io.stderr);
      return capturedText(status.out) === "blocked" ? 0 : 1;
    }
    case "harness_up":
      return harnessUpHerdr(argvOf(pane()));
    case "send_key": {
      const focus = herdrVerb("focus", [id], io, say);
      if (focus !== 0) return focus;
      const k = args[1] ?? "";
      // herdr_key_name's printf through `$( )`: an unnamed key loses its trailing LFs.
      return herdrCli(["pane", "send-keys", argvOf(pane()), keyNamed(k) ?? k.replace(/\n+$/, "")], top, "ignore").status;
    }
    case "send_line": {
      const text = args.slice(1).join(" ");
      const p = pane();
      const meta = stateFile(id, "meta", report);
      let harness = "";
      try {
        accessSync(meta, constants.R_OK);
        harness = cutNul(metaGet(meta, "harness"));
      } catch {}
      const target = (): string => `herdr:pane-${paneField(id, 1, report)}`;
      const who = lat(id);
      const tell = (msg: string): void => {
        if (report) writeSync(2, Buffer.from(`ac-backend: ${msg}\n`, "latin1"));
      };
      let proof = false;
      if (harness === "claude" && (process.env.AC_SEND_UNPROVEN || "0") !== "1") {
        const pre = composerText(p, 20, io.stderr);
        if (pre.status === 2) {
          tell(`could not read the pane of ${target()} - NOTHING was typed or submitted (peek it: ac-peek.sh ${who})`);
          return 2;
        }
        if (pre.status !== 0) {
          tell(`cannot see the composer of ${target()} (no claude composer on screen) - NOTHING was typed; peek it (ac-peek.sh ${who}), or type anyway with ac-send.sh ${who} --force`);
          return 3;
        }
        if (pre.text.replace(C_SPACE, "") !== "") {
          tell(`the composer of ${target()} holds an unsent draft - NOTHING was typed or submitted, so the draft is untouched; send it or clear it first (peek: ac-peek.sh ${who})`);
          return 3;
        }
        proof = true;
      }
      herdrCli(["pane", "send-text", argvOf(p), text], top, "ignore");
      settle(io.stderr);
      if (proof) {
        // `${#text}`: characters under a UTF-8 locale, bytes under any other.
        const length = utf8Locale() ? [...text].length : Buffer.byteLength(text);
        const rows = Math.min(200, Math.max(20, Math.floor(length / 40) + 8));
        const post = composerText(p, rows, io.stderr);
        if (post.status !== 0 || !composerShows(text, post.text)) {
          const draft = composerClear(p, rows, top, io.stderr) ? "cleared" : `NOT cleared - peek it (ac-peek.sh ${who})`;
          tell(`the composer of ${target()} did not show the whole message before Enter (a long send lands as its tail) - NOTHING was submitted, draft ${draft}; write the instruction to a file and send a short pointer to it`);
          return 3;
        }
      }
      if (submitVerified(id, top, io.stderr) === 0) return 0;
      herdrVerb("focus", [id], io, say);
      const rc = submitVerified(id, top, io.stderr);
      if (rc === 0) return 0;
      if (rc === 2) {
        tell(`could not read the pane of ${target()} - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh ${who})`);
        return 2;
      }
      tell(`submit not acknowledged by ${target()} - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh ${who} --key Enter)`);
      return 1;
    }
  }
}

// `sleep "${AC_SEND_SETTLE:-0.4}"`: PATH's sleep, as the driver ran it, the
// knob read per pause; its complaint on the caller's stderr, its status
// ignored.
export function settle(stderr: "inherit" | "ignore"): void {
  stage(["sleep", process.env.AC_SEND_SETTLE || "0.4"], "ignore", "ignore", stderr);
}

// herdr_composer_text_pane's twin: the claude composer between the last two
// rules of the --ansi read's last <rows> lines, the dim hint, every SGR, CR and
// the first row's ❯ and the NBSP after it stripped; status 2 when the read
// failed, 1 when no two ordered rules frame it. Two adjacent rules gave sed a
// range ending before its start, which printed that start alone - the second
// rule.
function composerText(p: string, rows: number, stderr: "inherit" | "ignore"): { status: number; text: string } {
  const read = herdrCli(["pane", "read", argvOf(p), "--source", "recent", "--lines", "200", "--ansi"], "ignore", "pipe");
  if (read.status !== 0) return { status: 2, text: "" };
  const lines = capturedText(stage(["tail", "-n", String(rows)], Buffer.from(`${capturedText(read.out)}\n`, "latin1"), "pipe", stderr).out).split("\n");
  const ruled = lines.flatMap((l, i) => (RULE_RUN.test(l) ? [i] : []));
  const r2 = ruled.at(-1);
  const r1 = ruled.at(-2) ?? r2;
  if (r1 === undefined || r2 === undefined || r1 >= r2) return { status: 1, text: "" };
  const region = r2 - r1 > 1 ? lines.slice(r1 + 1, r2) : [lines[r2]!];
  const rowText = (l: string, i: number): string => {
    const t = l.replace(/\x1b\[2m[^\x1b]*/g, "").replace(/\x1b\[[0-9;]*m/g, "").replace(/\r/g, "");
    return i === 0 ? t.replace(PROMPT_ROW, "") : t;
  };
  return { status: 0, text: region.map(rowText).join("\n").replace(/\n+$/, "") };
}

// herdr_composer_shows' twin: the composer holds exactly <text>, white space
// ignored (it soft-wraps), or only claude's paste placeholders.
function composerShows(text: string, got: string): boolean {
  const want = lat(text).replace(C_SPACE, "");
  const have = got.replace(C_SPACE, "");
  if (want === "" || have === "") return false;
  return have === want || have.replace(/\[Pastedtext#[0-9]+(\+[0-9]+lines?)?\]/g, "") === "";
}

// herdr_composer_clear_pane's twin: up to <presses> ctrl+u, each re-read;
// true once the composer reads empty, false on a failed press or read.
function composerClear(p: string, presses: number, top: "inherit" | "ignore", stderr: "inherit" | "ignore"): boolean {
  for (let i = 0; i < presses; i++) {
    if (herdrCli(["pane", "send-keys", argvOf(p), "ctrl+u"], top, "ignore").status !== 0) return false;
    const t = composerText(p, presses, stderr);
    if (t.status !== 0) return false;
    if (t.text.replace(C_SPACE, "") === "") return true;
  }
  return false;
}

// backend_submit_verified_herdr's twin: the handle re-read, then the raw-pane
// verifier.
export function submitVerified(id: string, top: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
  return submitVerifiedPane(argvOf(paneField(id, 1, stderr === "inherit")), top, stderr);
}

// herdr_submit_verified_pane's twin, one RAW pane (decoded): the render's last
// 15 lines read, the Enter pressed (its status ignored, even when the read
// failed), then up to seven probes a settle apart - 0 the render changed, 1 it
// never did, 2 a read failed. An empty pane is never read.
export function submitVerifiedPane(p: string, top: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
  const render = (): string | null => {
    if (p === "") return null;
    const read = herdrCli(["pane", "read", p, "--source", "recent", "--lines", "200"], "ignore", "pipe");
    if (read.status !== 0) return null;
    const t = stage(["tail", "-n", "15"], Buffer.from(`${capturedText(read.out)}\n`, "latin1"), "pipe", "ignore");
    return t.status === 0 ? capturedText(t.out) : null;
  };
  const pre = render();
  herdrCli(["pane", "send-keys", p, "enter"], top, "ignore");
  if (pre === null) return 2;
  for (let i = 0; i < 7; i++) {
    settle(stderr);
    const post = render();
    if (post === null) return 2;
    if (post !== pre) return 0;
  }
  return 1;
}

export function orcaVerb(fn: BackendFn, args: string[], io: VerbIo, say: (b: Buffer) => void): number {
  const id = args[0] ?? "";
  const report = io.stderr === "inherit";
  const stdin = io.stdin ?? "inherit";
  const handle = (): string => paneField(id, 1, report);
  switch (fn) {
    case "target":
      say(Buffer.from(`orca:${handle()}\n`, "latin1"));
      return 0;
    case "window_alive": {
      const h = handle();
      if (h === "") return 1;
      const show = orcaJson(["terminal", "show", "--terminal", argvOf(h)], stdin);
      if (show !== null) return jqOver(["-e", ".result.terminal.connected == true"], show, "ignore", "ignore").status === 0 ? 0 : 1;
      return orcaJson(["status"], stdin) !== null ? 1 : 2;
    }
    case "focus":
      return orcaJson(["terminal", "switch", "--terminal", argvOf(handle())], stdin) !== null ? 0 : 1;
    case "capture": {
      const h = handle();
      const lines = args[1] || "40";
      if (h === "") return 1;
      const out = orcaJson(["terminal", "read", "--terminal", argvOf(h), "--limit", lines, "--screen"], stdin);
      if (out === null) return 1;
      const t = jqOver(["-r", ".result.terminal.tail[]?"], out, io.stdout, io.stderr);
      say(t.out);
      return t.status;
    }
    case "mark_wait":
      if (handle() === "") return 1;
      return stage(["touch", `${softSubdir("state", report)}/.captain-wait-${id}`], "ignore", "ignore", io.stderr).status;
    case "clear_wait": {
      const wf = `${softSubdir("state", report)}/.captain-wait-${id}`;
      return existsSync(wf) ? stage(["rm", "-f", wf], "ignore", "ignore", io.stderr).status : 0;
    }
    case "agent_blocked": {
      if (existsSync(`${softSubdir("state", report)}/.captain-wait-${id}`)) return 1;
      const h = handle();
      if (h === "") return 1;
      const show = orcaJson(["terminal", "show", "--terminal", argvOf(h)], stdin);
      return show === null ? 1 : jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status;
    }
    case "harness_up":
      return harnessUpOrca(argvOf(handle()), stdin, io.stderr);
    case "send_key": {
      const k = args[1] ?? "";
      const named = keyNamed(k);
      const how = named === "enter" ? ["--enter"] : named === "escape" ? ["--text", "\x1b"] : named === "ctrl+c" ? ["--interrupt"] : ["--text", k];
      return orcaJson(["terminal", "send", "--terminal", argvOf(handle()), ...how], stdin) !== null ? 0 : 1;
    }
    case "send_line": {
      const text = args.slice(1).join(" ");
      orcaType(argvOf(handle()), text, stdin, io.stderr);
      settle(io.stderr);
      let rc = orcaSubmitVerified(argvOf(handle()), text, stdin, io.stderr);
      if (rc === 0) return 0;
      if (rc !== 3) {
        orcaVerb("focus", [id], io, say);
        rc = orcaSubmitVerified(argvOf(handle()), text, stdin, io.stderr);
      }
      if (rc === 0) return 0;
      const target = `orca:${handle()}`;
      const who = lat(id);
      const tell = (msg: string): void => {
        if (report) writeSync(2, Buffer.from(`ac-backend: ${msg}\n`, "latin1"));
      };
      if (rc === 3) {
        tell(`a DIALOG owns the pane of ${target} - the text sits in the composer and no Enter was pressed (an Enter would ACCEPT the highlighted option). Peek it (ac-peek.sh ${who}) and answer deliberately with ac-send.sh ${who} --key <key>`);
        return 1;
      }
      if (rc === 2) {
        tell(`could not read the pane of ${target} - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh ${who})`);
        return 2;
      }
      tell(`submit not acknowledged by ${target} - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh ${who} --key Enter)`);
      return 1;
    }
  }
}

// orca_type_pane's twin: `--text` sends of 512 units - characters under a
// UTF-8 locale, bytes under any other (`${text:off:512}`) - with PATH's
// `sleep 0.05` between them, every status ignored. A cut inside a character
// sends each half as U+FFFD where the bash sent the half's bytes (named).
export function orcaType(h: string, text: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): void {
  const utf8 = utf8Locale();
  const units = utf8 ? [...text] : [...lat(text)];
  for (let off = 0; off < units.length; ) {
    const chunk = units.slice(off, off + 512).join("");
    orcaJson(["terminal", "send", "--terminal", h, "--text", utf8 ? chunk : argvOf(chunk)], stdin);
    off += 512;
    if (off < units.length) stage(["sleep", "0.05"], "ignore", "ignore", stderr);
  }
}

// backend_capture_pane_orca at 15 lines as `$(... 2>/dev/null)` read it:
// null when there is no handle (no call), the read fails or jq does.
function orcaScreen(h: string, stdin: "inherit" | "ignore"): string | null {
  if (h === "") return null;
  const out = orcaJson(["terminal", "read", "--terminal", h, "--limit", "15", "--screen"], stdin);
  if (out === null) return null;
  const r = jqOver(["-r", ".result.terminal.tail[]?"], out, "pipe", "ignore");
  return r.status === 0 ? capturedText(r.out) : null;
}

// orca_pane_dialog's twin: a show the runtime answered whose agentWait is
// not null.
function orcaDialog(h: string, stdin: "inherit" | "ignore"): boolean {
  const show = orcaJson(["terminal", "show", "--terminal", h], stdin);
  return show !== null && jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status === 0;
}

// orca_composer_pending's twin: the screen's region between its last two
// rules (C-locale grep; adjacent rules give sed's reversed range, the second
// rule) with LFs as spaces and space runs squeezed holds the text's 60-unit
// head, squeezed alike - cut by characters under a UTF-8 locale, bytes
// otherwise. The bash ran tr and cut under the caller's locale, where an
// invalid byte cuts tr's output short; none reaches them - jq writes U+FFFD
// for one (probed) and the text is a decoded argv - so the twin joins and
// squeezes the bytes itself.
function orcaPending(h: string, text: string, stdin: "inherit" | "ignore"): boolean {
  const cap = orcaScreen(h, stdin);
  if (cap === null) return false;
  const lines = cap.split("\n");
  const ruled = lines.flatMap((l, i) => (RULE_RUN.test(l) ? [i] : []));
  const r2 = ruled.at(-1);
  const r1 = ruled.at(-2) ?? r2;
  if (r1 === undefined || r2 === undefined || r1 >= r2) return false;
  const region = (r2 - r1 > 1 ? lines.slice(r1 + 1, r2) : [lines[r2]!]).map((l) => `${l} `).join("").replace(/ +/g, " ");
  const flat = text.replace(/\n/g, " ").replace(/ +/g, " ");
  const want = utf8Locale() ? lat([...flat].slice(0, 60).join("")) : lat(flat).slice(0, 60);
  return want !== "" && region.includes(want);
}

// orca_submit_verified_pane's twin: a dialog refuses (3) before any Enter;
// the render read, the Enter (its status ignored, even when the read failed),
// up to seven probes a settle apart - 2 a read failed, 1 the render never
// changed - then, for a text, while the text still sits pending, up to two
// retry Enters, each behind the dialog guard and followed by a settle; still
// pending after both, 1.
export function orcaSubmitVerified(h: string, text: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
  if (orcaDialog(h, stdin)) return 3;
  const pre = orcaScreen(h, stdin);
  orcaJson(["terminal", "send", "--terminal", h, "--enter"], stdin);
  if (pre === null) return 2;
  let i = 0;
  for (; i < 7; i++) {
    settle(stderr);
    const post = orcaScreen(h, stdin);
    if (post === null) return 2;
    if (post !== pre) break;
  }
  if (i === 7) return 1;
  if (text === "") return 0;
  for (let retries = 0; orcaPending(h, text, stdin); retries++) {
    if (retries >= 2) return 1;
    if (orcaDialog(h, stdin)) return 3;
    orcaJson(["terminal", "send", "--terminal", h, "--enter"], stdin);
    settle(stderr);
  }
  return 0;
}

// backend_agent_idle_pane_orca as harness_up reaches it: a second show, its
// title's glyph, then tui-idle's 1000 ms wait - the raw `orca terminal wait`,
// no ok test - and for a codex identity a 40-line screen taken before it and
// compared after a timed-out one.
export function orcaAgentIdle(h: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): boolean {
  const show = orcaJson(["terminal", "show", "--terminal", h], stdin);
  if (show === null || jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status === 0) return false;
  const title = capturedText(jqOver(["-r", ".result.terminal.title // empty"], show, "pipe", stderr).out);
  if (spins(title)) return false;
  if (title.startsWith(IDLE_GLYPH)) return true;
  const screen = (): { status: number; text: string } => {
    const out = orcaJson(["terminal", "read", "--terminal", h, "--limit", "40", "--screen"], stdin);
    if (out === null) return { status: 1, text: "" };
    const r = jqOver(["-r", ".result.terminal.tail[]?"], out, "pipe", "ignore");
    return { status: r.status, text: capturedText(r.out) };
  };
  let before = "";
  if (jqOver(["-e", '.result.terminal.agentIdentity == "codex"'], show, "ignore", "ignore").status === 0) {
    const b = screen();
    if (b.status === 0) before = b.text;
  }
  const waited = capturedText(stage(["orca", "terminal", "wait", "--terminal", h, "--for", "tui-idle", "--timeout-ms", "1000", "--json"], stdin, "pipe", "ignore").out);
  if (jqOver(["-e", "(.result.wait.satisfied // .result.terminal.wait.satisfied) == true"], waited, "ignore", "ignore").status === 0) return true;
  if (before === "" || jqOver(["-e", '.error.code == "timeout"'], waited, "ignore", "ignore").status !== 0) return false;
  return screen().text === before;
}

// --- lint twins ---

// `command -v <name>` for a slash-free name, as bash 3.2's PATH search answers
// it (probed): an executable non-directory in any entry is found; failing
// that, the FIRST entry that exists decides - a file that is not executable
// is found (Bun.which refuses it; the shell then fails to run it, 126), a
// directory hides every later match. An empty PATH element is the cwd.
export function commandV(name: string): boolean {
  let fallback: boolean | undefined;
  for (const d of (process.env.PATH ?? "").split(":")) {
    const f = `${d || "."}/${name}`;
    try {
      if (statSync(f).isDirectory()) {
        fallback ??= false;
        continue;
      }
    } catch {
      continue;
    }
    try {
      accessSync(f, constants.X_OK);
      return true;
    } catch {
      fallback ??= true;
    }
  }
  return fallback ?? false;
}

// --- relocate twins ---
export { herdrCli, paneField };

// ac_fleet_name's twin: the basename of the physical home AC_HOME names ("" when
// cd cannot enter it), else AC_FLEET_NAME, else the fixed agent-crew.
export function fleetName(): string {
  const h = process.env.AC_HOME;
  if (!h) return process.env.AC_FLEET_NAME || "agent-crew";
  const home = physicalDir(h) ?? "";
  return home === "/" ? home : home.slice(home.lastIndexOf("/") + 1);
}

// ac_window_family's twin: AC_SCOPE, then AC_FLEET_SCOPE, the first one set
// and inside [A-Za-z0-9_-]+, else the id's family. The grammar is read per the
// text: bash 3.2's range under a UTF-8 locale also admitted é (named).
export function windowFamily(id: string): string {
  for (const s of [process.env.AC_SCOPE, process.env.AC_FLEET_SCOPE]) if (s && wakeScopeOk(s)) return s;
  return familyOfId(id);
}

// herdr_ws_family_label's twin, bytes (latin1) in and out: `<fleet> · <fam>`,
// or the fleet's root label `<fleet>` for an empty family.
export function wsFamilyLabel(fam: string): string {
  const fleet = lat(fleetName()).replace(/\n+$/, "");
  return fam ? `${fleet} ${lat("·")} ${fam}` : fleet;
}

// `printf %q` as bash 3.2 spells it, bytes (latin1) in and out: '' for
// nothing; a string whose every byte isprint() takes backslash-quoted (the
// shell's specials, a leading #); any other as $'...' - \E \a \b \f \n \r \t
// \v, \\ and \', the bytes isprint() refuses in octal, the rest raw.
// isprint() is the locale's: the ASCII graphics and space, and under the
// macOS UTF-8 locale also 0xA0-0xFF but 0xAD (probed) - so a UTF-8
// character's lead byte can stay raw beside its escaped continuation.
const ANSI_C: Record<string, string> = { "\x1b": "E", "\x07": "a", "\x08": "b", "\x0c": "f", "\n": "n", "\r": "r", "\t": "t", "\x0b": "v", "\\": "\\", "'": "'" };
export function shellQuote(s: string): string {
  if (s === "") return "''";
  const loc = process.env.LC_ALL || process.env.LC_CTYPE || process.env.LANG || "";
  const utf8 = /utf-?8/i.test(loc);
  const printable = (ch: string): boolean => (ch >= " " && ch < "\x7f") || (utf8 && ch >= "\xa0" && ch !== "\xad");
  if ([...s].every(printable)) return s.replace(/[ '"\\|&;()<>!{}*[?\]^$`,]/g, "\\$&").replace(/^#/, "\\#");
  let q = "$'";
  for (const ch of s) q += ANSI_C[ch] !== undefined ? `\\${ANSI_C[ch]}` : printable(ch) ? ch : `\\${ch.charCodeAt(0).toString(8).padStart(3, "0")}`;
  return `${q}'`;
}

const TWINS_JQ = `
    [.result.workspaces[]? | select(.label == $lbl)]
    | sort_by(-(.tab_count // 0)) | .[].workspace_id`;
const TABS_STATE_JQ = `
    if (.result.tabs | type) == "array"
    then (if ([.result.tabs[].label] | all(. == "1")) then "empty" else "nonempty" end)
    else "unreadable" end`;

// herdr_resolve_workspace's twin as `$(...)` ran it, bytes (latin1) in and
// out: the workspace labelled <label> - the busiest twin adopted, every other
// one closed when its tabs are only herdr's default `1`s (the emptiness proof)
// and WARNed when one holds another tab or its list cannot be read - else one
// created. null once it died, the ERROR printed: a create that failed (herdr's
// own stderr first) or answered no id (jq's line first when it was no JSON).
// Every call reads /dev/null: the original's sweep calls read its loop's
// here-string and its create the caller's stdin (a compound command with a
// stdin redirect had run in that shell - named). `quiet` prints nothing, as
// a caller's `2>/dev/null` around the bash left it.
export function herdrResolveWorkspace(label: string, quiet = false): string | null {
  const err = quiet ? "ignore" : "inherit";
  const list = herdrCli(["workspace", "list"], "ignore", "pipe");
  const twins = capturedText(stage(["jq", "-r", "--arg", "lbl", argvOf(label), TWINS_JQ], list.out, "pipe", "ignore").out);
  let ws = twins.split("\n")[0]!;
  for (const t of twins.split("\n")) {
    if (t === "" || t === ws) continue;
    const state = wsTabsState(t);
    if (state === "empty") wsClose(t, false, quiet);
    else if (quiet) continue;
    else if (state === "nonempty") warn(Buffer.from(`twin workspace ${t} left open: it holds a tab other than herdr's default '1' - closing the workspace would take that tab with it`, "latin1"));
    else warn(Buffer.from(`twin workspace ${t} left open: its tab list could not be read - a close cannot be proven safe`, "latin1"));
  }
  if (ws !== "") return ws;
  const created = herdrCli(["workspace", "create", "--label", argvOf(label), "--no-focus"], "ignore", "pipe", err);
  if (created.status !== 0) {
    if (!quiet) writeSync(2, "ERROR: herdr workspace create failed (is the herdr server running?)\n");
    return null;
  }
  ws = capturedText(jqOver(["-r", ".result.workspace.workspace_id // empty"], capturedText(created.out), "pipe", err).out);
  if (ws === "" && !quiet) writeSync(2, "ERROR: could not parse herdr workspace create output\n");
  return ws || null;
}

// herdr_ws_tabs_state's twin: empty, nonempty or unreadable - a list that
// failed, no tabs array, or no answer at all.
function wsTabsState(ws: string): string {
  const r = herdrCli(["tab", "list", "--workspace", argvOf(ws)], "ignore", "pipe");
  if (r.status !== 0) return "unreadable";
  return capturedText(jqOver(["-r", TABS_STATE_JQ], capturedText(r.out), "pipe", "ignore").out) || "unreadable";
}

// herdr_ws_close's twin, best-effort: a refusal naming
// workspace_group_close_required is WARNed - or, with `group` (a caller that
// proved the workspace empty), retried as `--group` and WARNed only when that
// fails too; `quiet` drops the warning. The original matched it in a `2>&1`
// capture; here stdout and stderr are read whole, one after the other.
function wsClose(ws: string, group = false, quiet = false): void {
  const r = herdrCli(["workspace", "close", argvOf(ws)], "ignore", "pipe", "pipe");
  if (r.status === 0 || !capturedText(Buffer.concat([r.out, r.err])).includes("workspace_group_close_required")) return;
  if (!group) {
    if (!quiet) warn(Buffer.from(`workspace ${ws} left open: herdr refused the close with workspace_group_close_required (it heads a linked-worktree group, which this sweep is not authorized to close)`, "latin1"));
  } else if (herdrCli(["workspace", "close", argvOf(ws), "--group"], "inherit", "ignore").status !== 0)
    warn(Buffer.from(`workspace ${ws} refused workspace_group_close_required and the --group retry failed too - close it by hand`, "latin1"));
}

// herdr_tab_create's twin as `$(...)` ran it, bytes (latin1) in: a tab
// labelled crew:<id> in <ws> (herdr's default workspace for ""), its answer as
// the capture read it and herdr's status; herdr's stderr is the caller's.
export function herdrTabCreate(ws: string, dir: string, id: string): { status: number; out: string } {
  const r = herdrCli(["tab", "create", ...(ws ? ["--workspace", argvOf(ws)] : []), "--cwd", argvOf(dir), "--label", argvOf(`crew:${id}`), "--no-focus"], "ignore", "pipe", "inherit");
  return { status: r.status, out: capturedText(r.out) };
}

// herdr_close_default_tabs' twin: every `1` tab of <ws> closed, each close
// best-effort, the ids read as `jq ... | while IFS= read -r t` read them (whole
// lines only). The answer is that pipeline's status under pipefail - jq's,
// which ended an errexit caller - or 0 when the list itself failed.
export function herdrCloseDefaultTabs(ws: string): number {
  const list = herdrCli(["tab", "list", "--workspace", argvOf(ws)], "ignore", "pipe");
  if (list.status !== 0) return 0;
  const ids = jqOver(["-r", '.result.tabs[]? | select(.label == "1") | .tab_id'], capturedText(list.out), "pipe", "ignore");
  for (const t of ids.out.toString("latin1").split("\n").slice(0, -1)) if (t !== "") herdrCli(["tab", "close", argvOf(t)], "ignore", "ignore");
  return ids.status;
}

// --- domain twins ---
import { basename } from "node:path";
import { readlinkSync } from "node:fs";

// src/domain.ts derives a package path from `$(ac_home)` as the bash did:
// the refusal printed and "" when the home cannot be named.
export { softHome };

// --- ledger lock ---
// The backlog lock as src/task.ts takes it - <dir> is a ledger's
// records/.backlog.md.lock, waited on AC_TASK_LOCK_TIMEOUT secs (default 10)
// and released at exit - for the other writers of a ledger. Several sessions
// write one ledger, and a writer outside the lock both writes past a live
// holder and erases a commit made between its read and its rename. Null once
// held; else the refusal, naming <ledger>: a live holder that outlasts the
// wait, or a records/ the lock cannot be made in, which no wait would cure.
let ledgerSignalsArmed = false;
export function ledgerLock(dir: string, ledger: string): string | null {
  try {
    accessSync(dirname(dir), fsConstants.W_OK | fsConstants.X_OK);
  } catch {
    return `${ledger} cannot be locked - its directory is not writable - nothing written`;
  }
  if (!lockAcquire(dir, Number(process.env.AC_TASK_LOCK_TIMEOUT || "10"))) return `${ledger} is locked by another writer - nothing written`;
  process.on("exit", () => lockRelease(dir));
  // A signal's default action ends the process before any exit handler runs
  // and leaves the lock behind; handled, it becomes an exit.
  if (!ledgerSignalsArmed) {
    ledgerSignalsArmed = true;
    for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
  }
  return null;
}

// --- tree twins ---

// ac_sparse_excluded's twin: true when <wt>'s sparse rules exclude <path>
// (bytes), so its absence is by design. `sparse-checkout check-rules` needs
// git 2.41: an older git's 129 leaves the sparse flag to decide alone, any
// other failure is no exclusion. The answer is counted, never trimmed - a
// newline-only name would read as nothing.
function sparseExcluded(wt: string, path: string): boolean {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["git", "-C", wt, "sparse-checkout", "check-rules", "-z"], {
      stdin: Buffer.concat([Buffer.from(path, "latin1"), Buffer.from([0])]),
      stdout: "pipe",
      stderr: "ignore",
    });
  } catch {}
  const rc = shellStatus(r);
  return rc === 129 || (rc === 0 && r!.stdout.length === 0);
}

// ac_worktree_status's twin (no entry runs the bash since src/teardown.ts):
// every git is the PATH's, so a wrapper sees what each side hashes. <wt> is a path
// as given, the answer bytes (latin1) - git status's porcelain with submodule
// ignores overridden and untracked files listed whatever the repo's
// status.showUntrackedFiles says (a reset's clean would discard one it hid),
// an `H  <path>` per file whose assume-unchanged or skip-worktree bit hides
// an edit, a deletion or a mode/type change from it, an `O  <op>` per
// operation git left in progress - and status git status's.
// A path whose bytes are not UTF-8 reaches git's argv as U+FFFD.
export function worktreeStatus(wt: string): { status: number; out: string } {
  const g = (args: string[], stdin: "inherit" | Buffer = "inherit"): { status: number; out: Buffer } => {
    let r: ReturnType<typeof spawnShellSync> | null = null;
    try {
      r = spawnShellSync(["git", "--no-optional-locks", "-C", wt, ...args], { stdin, stdout: "pipe", stderr: "ignore" });
    } catch {}
    return { status: shellStatus(r), out: r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
  };
  const cap = (b: Buffer): string => capturedText(b);
  const st = g(["status", "--porcelain", "--ignore-submodules=none", "--untracked-files=normal"]);
  let out = st.out.toString("latin1");
  const fm = g(["config", "--get", "core.fileMode"]);
  const filemode = cap(fm.status === 0 ? fm.out : Buffer.concat([fm.out, Buffer.from("true")]));
  const sp = g(["config", "--get", "core.sparseCheckout"]);
  const sparse = cap(sp.status === 0 ? sp.out : Buffer.concat([sp.out, Buffer.from("false")]));
  const recs = g(["ls-files", "-v", "-z"]).out.toString("latin1").split("\0");
  recs.pop();
  const wtb = Buffer.from(wt, "utf8");
  for (const rec of recs) {
    const sp1 = rec.indexOf(" ");
    const tag = sp1 < 0 ? rec : rec.slice(0, sp1);
    if (!/^[a-z]$/.test(tag) && tag !== "S") continue;
    const path = rec.length >= 2 && rec[1] === " " ? rec.slice(2) : rec;
    const arg = Buffer.from(path, "latin1").toString("utf8");
    const f = Buffer.concat([wtb, Buffer.from("/"), Buffer.from(path, "latin1")]);
    const line = g(["--literal-pathspecs", "ls-files", "-s", "-z", "--", arg]).out.toString("latin1").replace(/\0/g, "\n").split("\n")[0]!;
    const [mode = "", blob = ""] = line.replace(/^[ \t]+/, "").split(/[ \t]+/);
    if (mode === "160000") continue;
    let isLink = false;
    try {
      isLink = lstatSync(f).isSymbolicLink();
    } catch {}
    let st2: ReturnType<typeof statSync> | null = null;
    try {
      st2 = statSync(f);
    } catch {}
    if (st2 === null && !isLink) {
      if (tag === "S" && sparse === "true" && sparseExcluded(wt, path)) continue;
      out += `H  ${path}\n`;
      continue;
    }
    if (mode === "120000") {
      let hit = false;
      if (isLink) {
        let target = Buffer.alloc(0);
        try {
          target = Buffer.from(readlinkSync(f, { encoding: "buffer" }));
        } catch {}
        hit = cap(g(["hash-object", "--stdin"], Buffer.from(cap(target), "latin1")).out) === blob;
      }
      if (!hit) out += `H  ${path}\n`;
      continue;
    }
    let x = false;
    try {
      accessSync(f, constants.X_OK);
      x = true;
    } catch {}
    if (
      isLink ||
      !st2!.isFile() ||
      cap(g(["hash-object", "--", arg]).out) !== blob ||
      (filemode === "true" && ((mode === "100755" && !x) || (mode !== "100755" && x)))
    )
      out += `H  ${path}\n`;
  }
  const gd = g(["rev-parse", "--absolute-git-dir"]);
  if (gd.status === 0) {
    const d = cap(gd.out);
    for (const op of ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "sequencer"])
      if (existsSync(Buffer.from(`${d}/${op}`, "latin1"))) out += `O  ${op}\n`;
  }
  return { status: st.status, out };
}

// ac_default_ref's twin (no bin/ entry calls the bash now): `origin/<default
// branch>` when that remote-tracking ref exists, else the branch - the cruder
// rule freshestRef refines. `loud` as defaultBranch's.
export function defaultRef(repo: string, loud = false): string {
  const b = defaultBranch(repo, loud);
  return gitRef(repo, `refs/remotes/origin/${b}`, loud) ? `origin/${b}` : b;
}

// crew_state_dir's twin (src/tree.ts's, src/verify.ts's state dir
// rule): AC_FLEET_STATE as given - what a homeless crewmate pane carries - else
// the home's state/, minted, else "" with nothing said. A home cd cannot enter
// is named, as the HOME RESOLUTION ruling has it.
export function crewStateDir(): string {
  const fleet = process.env.AC_FLEET_STATE;
  if (fleet) return fleet.replace(/\n+$/, "");
  return process.env.AC_HOME ? softSubdir("state", true) : "";
}

// The worktreeinclude manifest trims its lines with the shell's [:space:].
export { trimShellSpaceBytes };

// --- teardown twins ---

// <base>.<pid>, or <base>.<pid>.<n> past a name already taken, created
// EXCLUSIVELY - the originals' `<base>.$$` wrote through whatever sat there.
export function exclusiveTemp(base: string): { path: string; fd: number } {
  let path = `${base}.${process.pid}`;
  for (let n = 1; ; n++) {
    try {
      return { path, fd: openSync(path, "wx") };
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      path = `${base}.${process.pid}.${n}`;
    }
  }
}

// Every byte of <b> to <fd>: a regular file can take a write short at a size
// limit or a full disk, and a short temp renamed over its record loses the
// rest; the write that cannot continue throws.
export function writeAll(fd: number, b: Uint8Array): void {
  for (let off = 0; off < b.length; ) off += writeSync(fd, b, off, b.length - off);
}

// backend_kill_window's twin, both drivers, routed as backendCall routes (a
// refused name is its ERROR and an exited status 1, nothing read or swept).
// herdr, the KILL OWNERSHIP PROOF: the handle's tab (field 2) is closed only
// while `tab get` labels it crew:<id>, else the stale-handle WARN - an
// unreachable herdr reads the same (W18); a close that fails with the tab
// still there retries as a close of its workspace (the tab id's part before
// `:`) on the emptiness proof - every other tab a default `1` - taking
// wsClose's group retry; an occupied or unreadable workspace, or a tab that
// cannot be re-read, is WARNed and answers 1 (unclosed). orca: the handle's
// terminal closed, then up to 8 PATH `sleep 0.25`s while `terminal list` still
// shows it in its tab, and an emptied tab's state/.orca-fam-* records (byte
// order) removed; it answers the last rm's status (W19). Both remove the pane
// and captain-wait files with a spawned `rm -f`. stdin by position: a herdr
// call in a pipeline or `$( )` reads /dev/null, every other the caller's.
export function backendKillWindow(id: string): { status: number; exited: boolean } {
  const b = backendRoute("inherit");
  if (b === null) return { status: 1, exited: true };
  return { status: b === "herdr" ? herdrKillWindow(id) : orcaKillWindow(id), exited: false };
}

const CLOSEABLE_JQ = `
              if (.result.tabs | type) == "array"
              then (if ([.result.tabs[] | select(.tab_id != $t) | .label] | all(. == "1"))
                    then "closeable" else "occupied" end)
              else "unreadable" end`;

function herdrKillWindow(id: string): number {
  const tab = paneField(id, 2, true);
  const who = lat(id);
  let unclosed = 0;
  if (tab !== "") {
    const label = capturedText(stage(["jq", "-r", ".result.tab.label // empty"], herdrCli(["tab", "get", argvOf(tab)], "ignore", "pipe").out, "pipe", "ignore").out);
    if (label === `crew:${who}`) {
      const rc = herdrCli(["tab", "close", argvOf(tab)], "inherit", "ignore").status;
      if (rc !== 0) {
        if (herdrCli(["tab", "get", argvOf(tab)], "inherit", "ignore").status === 0) {
          const ws = tab.split(":")[0]!;
          const left = capturedText(stage(["jq", "-r", "--arg", "t", argvOf(tab), CLOSEABLE_JQ], herdrCli(["tab", "list", "--workspace", argvOf(ws)], "ignore", "pipe").out, "pipe", "ignore").out);
          if (left === "closeable") wsClose(ws, true);
          else {
            unclosed = 1;
            warn(Buffer.from(left === "occupied" ? `tab ${tab} of ${who} refused to close and its workspace ${ws} holds other live tabs - close the tab by hand` : `tab ${tab} of ${who} refused to close and workspace ${ws} could not be read - close the tab by hand`, "latin1"));
          }
        } else {
          unclosed = 1;
          warn(Buffer.from(`tab ${tab} of ${who}: close failed (rc ${rc}) and the tab could not be re-read - close it by hand if it is still open`, "latin1"));
        }
      }
    } else warn(Buffer.from(`not closing tab ${tab} for ${who}: it is labelled '${label || "none"}', not crew:${who} - the handle is stale (close the tab by hand if it really is this task's)`, "latin1"));
  }
  const sd = softSubdir("state", true);
  stage(["rm", "-f", `${sd}/.pane-${id}`, `${sd}/.captain-wait-${id}`], "inherit", "inherit", "inherit");
  return unclosed;
}

function orcaKillWindow(id: string): number {
  const handle = paneField(id, 1, true);
  const tab = paneField(id, 2, true);
  // orca_tab_handles: the list's jq keeps its stderr, and a failed list feeds
  // it nothing.
  const handles = (): string => {
    const list = orcaJson(["terminal", "list"], "inherit");
    const input = list === null ? Buffer.alloc(0) : Buffer.from(`${list}\n`, "latin1");
    return capturedText(stage(["jq", "-r", "--arg", "t", argvOf(tab), "[.result.terminals[] | select(.tabId==$t) | .handle] | sort | .[]"], input, "pipe", "inherit").out);
  };
  if (handle !== "") {
    orcaJson(["terminal", "close", "--terminal", argvOf(handle)], "inherit");
    for (let i = 0; tab !== "" && i < 8 && handles().includes(handle); i++) stage(["sleep", "0.25"], "inherit", "inherit", "inherit");
  }
  const sd = softSubdir("state", true);
  if (tab !== "" && handles().split("\n")[0] === "") {
    let names: string[] = [];
    try {
      names = readdirSync(sd);
    } catch {}
    for (const n of names.filter((x) => x.startsWith(".orca-fam-")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
      const f = `${sd}/${n}`;
      if (!existsSync(f)) continue;
      let held = "";
      try {
        held = capturedText(readFileSync(f));
      } catch {}
      if (held === tab) stage(["rm", "-f", f], "inherit", "inherit", "inherit");
    }
  }
  return stage(["rm", "-f", `${sd}/.pane-${id}`, `${sd}/.captain-wait-${id}`], "inherit", "inherit", "inherit").status;
}

// orca_worktree_release's twin: `orca worktree rm --worktree path:<p> --force
// --json`, its failure or an ok:false answer false.
export function orcaWorktreeRelease(path: string): boolean {
  return orcaJson(["worktree", "rm", "--worktree", `path:${path}`, "--force"], "inherit") !== null;
}

export { backendRoute, projectConfigName, statusTimelineMirror };

// --- brief twins ---

export type Ledger = { rc: 0; text: string } | { rc: 1 | 2 };

// The ledger as ac_row_contract_for_id and ac_epic_base_for open it: a path
// that is gone or no regular file is absent (rc 1, `[ -f ]`), else its bytes
// (latin1), rc 2 when they cannot be read - which no reader may take for an
// unpinned row.
export function ledgerRead(file: string): Ledger {
  if (!isFile(file)) return { rc: 1 };
  try {
    return { rc: 0, text: readFileSync(file, "latin1") };
  } catch {
    return { rc: 2 };
  }
}

// ac_row_contract_for_id's twin over a ledger read once (ledgerRead): the
// contract group of the FIRST `- [ ] `/`- [x] ` row whose id is <id> as `awk
// -v want=` made it, compared as a string (awk's `in`: 01 is never 1); an
// empty one falls through to the family row of an id with a stage suffix
// (stageDirForId), found the same way; "" when neither carries one, null for
// a ledger that could not be read. Rows are what the awk read
// (records/acDoneline, src/backlog.ts); the contract is bytes (latin1), a TAB
// joining its tokens kept.
export function rowContractForId(id: string, ledger: Ledger): string | null {
  if (ledger.rc === 2) return null;
  if (ledger.rc === 1) return "";
  const rows = records(ledger.text).filter((l) => /^- \[[ x]\] /.test(l));
  const contractOf = (want: string): string | undefined => {
    const w = awkAssign(Buffer.from(want, "utf8").toString("latin1"));
    for (const l of rows) {
      const f = acDoneline(l);
      if (f.id === w) return f.contract;
    }
    return undefined;
  };
  const exact = contractOf(id);
  if (exact) return exact;
  const sub = stageDirForId(id);
  return sub === "" ? "" : (contractOf(sub.slice(0, sub.indexOf("/"))) ?? "");
}

// ac_knowledge_file's twin: <records>/repo-knowledge/<the main repo's dir
// name>.md for a repo or any worktree of it, records/ minted (homeless, the
// refusal printed and the path rooted at /, as the bash's `$(ac_records_dir)`
// left it); null when git cannot name the repo. Never tested -f: the caller
// does.
export function knowledgeFile(repo: string): string | null {
  const name = projectConfigName(repo);
  return name === null ? null : `${softSubdir("records", true)}/repo-knowledge/${name}.md`;
}

// ac_captain's twin, byte for byte where configReadSoft decodes: config/
// captain's first line, NULs dropped, [:space:]-trimmed under the caller's
// locale (configReadDir), `captain` when there is no home (or one cd cannot
// enter) or no regular file there; a file that cannot be read is head's own
// line on stderr and "", not the default, as `line="$(head -n1 "$f")"` left it.
export function captainRead(): string {
  const home = softHome(false);
  if (home === "") return "captain";
  try {
    return configReadDir(`${home}/config`, "captain", "captain");
  } catch {
    headLine(`${home}/config/captain`);
    return "";
  }
}

// --- know twins ---

// ac_home_resolve's twin, the whole ladder (ac-jev.sh keeps the
// bash): --home must be absolute, enterable and - physically - outside the
// project's MAIN root (repoRoot, else <repo>'s own physical dir; a home that
// CONTAINS its clones is the normal layout, so the test is directional), else
// the three refusals; then AC_HOME unguarded, relative to the caller's cwd
// (one cd cannot enter, or a relative one from a cwd with no name, is named
// where the bash printed cd's own line - the HOME RESOLUTION ruling); then
// "", and the caller decides what no home means.
export function homeResolve(flag: string, repo: string): string {
  if (flag !== "") {
    if (!flag.startsWith("/")) die(`--home must be an ABSOLUTE path outside the project repo (got '${flag}')`);
    const home = physicalDir(flag) ?? die(`--home is not a readable directory: ${flag}`);
    const repoReal = repoRoot(repo) ?? physicalDir(repo) ?? "";
    if (repoReal !== "" && `${home}/`.startsWith(`${repoReal}/`)) die(`--home must be an ABSOLUTE path outside the project repo: ${flag} resolves to ${home}, inside ${repoReal}`);
    return home;
  }
  const h = process.env.AC_HOME;
  if (!h) return "";
  return (h.startsWith("/") || atCallerCwd ? physicalDir(h) : null) ?? die(`AC_HOME is not a readable directory: ${h}`);
}

// `${#v}` as bash 3.2 counts a value held as bytes, under the locale bash
// was given: shellPrefix's characters (a strictly valid UTF-8 sequence one,
// every other byte one) under a UTF-8 one, bytes under any other.
export function shellLength(s: string): number {
  let n = 0;
  for (let rest = s; rest !== ""; n++) rest = rest.slice(shellPrefix(rest, 1).length);
  return n;
}

// --- gate twins ---

// ac_harness_known's twin: a registry harness id (HARNESSES) - never the
// process names AC_HARNESS_RE lists (`cursor-agent` is cursor's process).
export function harnessKnown(h: string): boolean {
  return (HARNESSES as readonly string[]).includes(h);
}

// ac_chief_busy_path's twin (bin/ac-wake-lib.sh owns the declaration's
// contract): the family's busy declaration under <sd>.
export function chiefBusyPath(sd: string, fam: string): string {
  return `${sd}/.chief-busy-until.${fam}`;
}

// The paths a bash glob `<prefix>*` names, the prefix literal: the entries of
// its directory starting with its last component, in byte order.
function globPrefix(prefix: string): string[] {
  const cut = prefix.lastIndexOf("/");
  const dir = prefix.slice(0, cut);
  const base = prefix.slice(cut + 1);
  let names: string[];
  try {
    names = readdirSync(dir || "/");
  } catch {
    return [];
  }
  return names.filter((n) => n.startsWith(base)).sort().map((n) => `${dir}/${n}`);
}

// ac_chief_busy_held's twin: true while a live holder remains - a gate run's
// marker <famData>/.gate-running.<pid> or a verifier call's
// <sd>/.chief-busy-holder.<fam>.<pid> - every dead holder's mark removed on
// the way by a spawned `rm -f`, whose own complaint about a mark it cannot
// remove is the bash's, never a throw that would end its caller's cleanup. A
// mark that is there but unreadable reads dead (and goes) after ac_meta_get's
// warning; `quiet` drops both, as the gate's exit does.
export function chiefBusyHeld(sd: string, fam: string, famData: string, quiet = false): boolean {
  let held = false;
  for (const m of [...globPrefix(`${famData}/.gate-running.`), ...globPrefix(`${sd}/.chief-busy-holder.${fam}.`)]) {
    if (!isFile(m)) continue;
    let pid = "";
    try {
      pid = quiet ? metaValue(readFileSync(m, "latin1"), "pid") : metaGet(m, "pid");
    } catch {}
    if (pidAlive(pid)) held = true;
    else stage(["rm", "-f", m], "ignore", "ignore", quiet ? "ignore" : "inherit");
  }
  return held;
}

const TRANSCRIPT_FINAL_JQ = `[.[] | select(.type == "assistant")] | last
          | .message.content | map(select(.type == "text") | .text) | join("\\n")`;

// ac_transcript_final's twin (tests/fixtures/ac-pipeline-lib.sh): the pane agent's last
// assistant message, jq SPAWNED as `$(...)` read it - its status kept, so a
// transcript that is missing or no JSON ends a caller under errexit as it did
// there. The text is bytes (latin1).
export function transcriptFinal(file: string): { status: number; text: string } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["jq", "-rs", TRANSCRIPT_FINAL_JQ, file], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  return { status: shellStatus(r), text: r ? capturedText(Buffer.from(r.stdout)) : "" };
}

// ac_maintenance_plan_validate's closed schema, verbatim (the bash one frozen
// at tests/fixtures/ac-maintenance-retired.sh): jq's own reading of the plan
// is the judge.
const PLAN_SCHEMA_JQ = `length == 1 and (.[0] |
    type == "object"
    and keys == ["actions","input_manifest_sha256","mode","run_id","schema","subject"]
    and .schema == "agentcrew.maintenance-plan/v1"
    and (.mode == "learning" or .mode == "curate")
    and (.run_id | type == "string" and test("\\\\A[A-Za-z0-9][A-Za-z0-9._-]*\\\\z"))
    and (.subject | type == "string" and test("\\\\A[A-Za-z0-9][A-Za-z0-9._-]*\\\\z"))
    and (.input_manifest_sha256 | type == "string" and test("\\\\A[0-9a-f]{64}\\\\z"))
    and (.actions | type == "array")
    and ([.actions[].target] | length == (unique | length))
    and all(.actions[];
      type == "object"
      and keys == ["new_sha256","old_sha256","op","staged","target"]
      and (.op == "write-skill"
        or .op == "patch-skill"
        or .op == "move-skill"
        or .op == "append-archive"
        or .op == "rewrite-ledger"
        or .op == "rewrite-index"
        or .op == "rewrite-registry"
        or .op == "rewrite-crewmate-learned"
        or .op == "update-cadence")
      and (.target | type == "string"
        and test("\\\\A[A-Za-z0-9._/-]+\\\\z")
        and (test("(^|/)\\\\.\\\\.?(/|$)") | not)
        and (startswith("/") | not))
      and (.staged | type == "string"
        and test("\\\\Astaged/[A-Za-z0-9._/-]+\\\\z")
        and (test("(^|/)\\\\.\\\\.?(/|$)") | not))
      and (.old_sha256 | type == "string"
        and (. == "-" or test("\\\\A[0-9a-f]{64}\\\\z")))
      and (.new_sha256 | type == "string" and test("\\\\A[0-9a-f]{64}\\\\z"))
    ))
  `;

export const isLink = (p: string): boolean => {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};

// ac_maintenance_path_plain's twin: no EXISTING component of <rel> under the
// physical <root> is a link; an empty component fails.
export function maintenancePathPlain(root: string, rel: string): boolean {
  let cur = physicalDir(root);
  if (cur === null) return false;
  for (const part of rel === "" ? [] : rel.split("/")) {
    if (part === "") return false;
    cur = `${cur}/${part}`;
    if (isLink(cur)) return false;
  }
  return true;
}

function plainSha(f: string): string | null {
  if (!isFile(f) || isLink(f)) return null;
  try {
    return sha256File(f);
  } catch {
    return null;
  }
}

// ac_maintenance_plan_validate's twin: jq on PATH, a plain plan and run, the
// closed schema, then per action an allowed target, plain paths under the
// home and the run, a plain staged file hashing to new_sha256, and for
// move-skill an old_sha256 of `-` with its live source (else its archived
// target) hashing the same. Homeless, the refusal is printed and the home is
// the caller's cwd, as `home="$(ac_home)"` left it.
export function maintenancePlanValidate(plan: string, run: string): boolean {
  if (!commandV("jq")) return false;
  if (!isFile(plan) || isLink(plan) || !isDir(run) || isLink(run)) return false;
  const home = softHome(true);
  const jq = (args: string[], stdout: "ignore" | "pipe", stderr: "inherit" | "ignore"): { status: number; out: Buffer } => stage(["jq", ...args], "inherit", stdout, stderr);
  if (jq(["-e", "-s", PLAN_SCHEMA_JQ, plan], "ignore", "ignore").status !== 0) return false;
  const rows = jq(["-r", ".actions[] | [.op,.target,.staged,.new_sha256] | @tsv", plan], "pipe", "inherit").out.toString("latin1").split("\n").slice(0, -1);
  for (const row of rows) {
    const [op, target, staged, expected] = tabFields(row.split("\0", 1)[0]!, 4) as [string, string, string, string];
    if (!/^(records\/|skills\/)/.test(target) && !["state/.learn.meta", "state/.curate.meta", "CREWMATE-learned.md"].includes(target)) return false;
    if (!maintenancePathPlain(home, target) || !maintenancePathPlain(run, staged)) return false;
    if (plainSha(`${run}/${staged}`) !== expected) return false;
    if (op !== "move-skill") continue;
    if (capturedText(jq(["-r", "--arg", "target", target, ".actions[] | select(.target == $target) | .old_sha256", plan], "pipe", "inherit").out) !== "-") return false;
    const prefix = "skills/skills-archive/";
    if (!target.startsWith(prefix) || !target.slice(prefix.length).includes("/")) return false;
    const source = `skills/${target.slice(prefix.length)}`;
    if (!maintenancePathPlain(home, source)) return false;
    // A live source that is there is the one judged, readable or not; only
    // its absence lets the archived copy stand in.
    const plainAt = (f: string): boolean => isFile(f) && !isLink(f);
    const judged = plainAt(`${home}/${source}`) ? `${home}/${source}` : plainAt(`${home}/${target}`) ? `${home}/${target}` : null;
    if (judged === null || plainSha(judged) !== expected) return false;
  }
  return true;
}

// ac_herdr_tab_open's twin (the pane agent keeps the bash),
// bytes (latin1) in and out: a tab labelled <label> in <ws> (the session's
// default group for "") through RAW herdr addressed by <ses>, "<pane> <tab>"
// read from its answer as the bash's sed read it (per line, the LAST id on a
// line, the first line holding one), else null. With <ws> the workspace's
// default `1` tabs are closed, best-effort; each close reads /dev/null where
// the bash's read the rest of its loop's jq pipe.
export function herdrTabOpen(ses: string, label: string, cwd: string, ws: string): string | null {
  const created = stage(["herdr", "--session", argvOf(ses), "tab", "create", ...(ws ? ["--workspace", argvOf(ws)] : []), "--label", argvOf(label), "--cwd", argvOf(cwd), "--no-focus"], "inherit", "pipe", "ignore");
  if (created.status !== 0) return null;
  const answer = capturedText(created.out).split("\n");
  const id = (key: string): string => {
    const re = new RegExp(`^.*"${key}":"([^"]*)".*$`);
    for (const l of answer) {
      const m = re.exec(l);
      if (m) return m[1]!;
    }
    return "";
  };
  const p = id("pane_id");
  const tab = id("tab_id");
  if (p === "") return null;
  if (ws) {
    const list = stage(["herdr", "--session", argvOf(ses), "tab", "list", "--workspace", argvOf(ws)], "inherit", "pipe", "ignore");
    const ids = stage(["jq", "-r", '.result.tabs[]? | select(.label == "1") | .tab_id'], list.out, "pipe", "ignore");
    for (const t of ids.out.toString("latin1").split("\n").slice(0, -1))
      if (t.split("\0", 1)[0] !== "") stage(["herdr", "--session", argvOf(ses), "tab", "close", argvOf(t.split("\0", 1)[0]!)], "ignore", "ignore", "ignore");
  }
  return `${p} ${tab}`;
}

// --- curate twins ---
// (The bash originals of the cadence and transaction twins here and under
// `// --- learn twins ---` were retired from bin/ac-maintenance-lib.sh; they
// are frozen at tests/fixtures/ac-maintenance-retired.sh, which
// tests/ts/curate.test.ts and tests/ts/learn.test.ts hold the twins to.)

// AC_SKILLS_ARCHIVE_BASENAME: the reserved subdir of skills/ that Curate
// moves retired packages into; the seed and the brain index skip it by name.
export const SKILLS_ARCHIVE = "skills-archive";

// ac_file_mtime's twin: whole epoch seconds of the path ITSELF (stat(1)
// without -L reads a link, not its target), null when it cannot be stat'ed.
export function fileMtime(path: string | Buffer): string | null {
  try {
    return String(Math.floor(lstatSync(path).mtimeMs / 1000));
  } catch {
    return null;
  }
}

// --- ship twins ---

// tests/fixtures/ac-pipeline-lib.sh's ac_yaml_get awk program, verbatim (the shell's
// '\'' is the ' here): its line filter, indent arithmetic and unquote, and its
// towc abort on an invalid byte under the caller's UTF-8 locale, stay awk's.
const YAML_GET_AWK = `
    function unquote(s) { sub(/^["'"]/, "", s); sub(/["'"]$/, "", s); return s }
    BEGIN { n = split(key, parts, ".") ; depth = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      v = line; sub(/^[^:]*:[[:space:]]*/, "", v)
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { print unquote(v); exit }
        depth++
      }
    }
  `;

// ac_yaml_get's twin, bytes (latin1) in and out: the awk spawned over <file>
// with -v key=<key> (awk's escape pass on it included), its stdout as awk
// wrote it (a `$(...)` caller cuts it) and its status - a caller decides what
// a failed read means, as each bash site did through errexit or its absence.
// `quiet` is a caller's `2>/dev/null`.
export function yamlGet(file: string, key: string, quiet = false): { status: number; out: string } {
  const r = stage(["awk", "-v", `key=${argvOf(key)}`, YAML_GET_AWK, argvOf(file)], "inherit", "pipe", quiet ? "ignore" : "inherit");
  return { status: r.status, out: r.out.toString("latin1") };
}

// ac_findings_normalize's jq program, verbatim.
const FINDINGS_NORMALIZE_JQ = String.raw`
    ($delta | split("\n") | map(select(. != ""))) as $dfiles
    | [.[]
       | .action = (if ((.action // "") | tostring) == "" then "ask-user"
                    elif (.action == "fix" or .action == "ask-user" or .action == "no-op") then .action
                    else "ask-user" end)
       | .description = (.description // .detail // .title // "")
       | if has("decision") then
           .decision = ((.decision // "") | tostring | gsub("[\\t\\r\\n]+"; " "))
         else . end
       | .authority = ((.authority // "") | tostring)
       | .authority_class =
           (if (.authority | gsub("^\\s+|\\s+$"; "")) == "" then "none"
            elif ((.authority_class // "") | tostring) as $c
                 | ($c == "internal" or $c == "external") then .authority_class
            else "none" end)
       | if .action == "fix" and ((.severity // "") | tostring) == "info"
         then .action = "no-op" | .severity_floored = true
         else . end
       | ((.file // "") | tostring) as $ffile
       | ((.class // "") | tostring) as $fclass
       | ((.id // "") | tostring) as $fid
       | if $round >= 2 and .action == "fix"
            and (($prior_open | index($fid)) == null)
            and ($ffile != "")
            and (($dfiles | index($ffile)) == null)
            and ((((.severity // "") | tostring) != "error")
                 or ($fclass != ""
                     and ((["correctness","security","data-loss"] | index($fclass)) == null)))
         then .action = "no-op" | .round_floored = true
         else . end
       | if .action == "fix" and .authority_class == "none"
         then .action = "ask-user" | .authority_downgraded = true
         else . end
       | if .action == "ask-user" then
           .question = ((.question // "") | tostring)
           | if (.question | gsub("^\\s+|\\s+$"; "")) == "" then
               .question =
                 (if (.description | gsub("^\\s+|\\s+$"; "")) != "" then .description
                  else "What decision should resolve finding \((.id // "unknown") | tostring)?" end)
             else . end
           | .options =
               (if ((.options // null) | type) == "array"
                   and (.options | length) >= 2 and (.options | length) <= 4
                   and all(.options[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
                then .options
                else ["accept the finding as delivery direction",
                      "keep delivery held for more evidence"] end)
           | .tradeoffs =
               (if ((.tradeoffs // null) | type) == "array"
                   and (.tradeoffs | length) == (.options | length)
                   and all(.tradeoffs[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
                then .tradeoffs
                else (.options | map("Tradeoff not supplied for option: " + .)) end)
           | .recommendation = ((.recommendation // "") | tostring)
           | if (.recommendation | gsub("^\\s+|\\s+$"; "")) == "" then
               .recommendation = "Keep delivery held until the captain records a decision."
             else . end
           # The DECIDER shape - who answers, what kind of choice, what each
           # option does to a user or operator - is optional on the wire and
           # kept only when well-formed: axis in its enum, decider a non-empty
           # string, impact one line per option. A malformed value is dropped,
           # never defaulted - inventing "implementer" or an impact line would
           # put words in the mouth of the reviewer on the one finding the
           # captain reads most closely.
           | if (.axis as $a | ["impl","security","product","compliance"] | index($a)) == null
             then del(.axis) else . end
           | if ((.decider // "") | tostring | gsub("^\\s+|\\s+$"; "")) == "" then del(.decider)
             else .decider = (.decider | tostring) end
           | if ((.impact // null) | type) == "array"
                and (.impact | length) == (.options | length)
                and all(.impact[]; type == "string" and (gsub("^\\s+|\\s+$"; "") != ""))
             then . else del(.impact) end
         else . end
      ]`;
const PRIOR_OPEN_JQ = 'type == "array" and all(.[]; type == "string")';

// ac_findings_normalize's twin: the findings array on <input> (the bytes the
// bash's here-string carried) normalized into <outfile> through a spawned
// `mktemp <outfile>.XXXXXX`, the jq program and a spawned mv - the status the
// bash function returned: mktemp's failure 1, jq's 1 (its temp removed), else
// mv's. The round metadata is read from the ENVIRONMENT as the bash read it:
// AC_FINDINGS_ROUND (digits, else 1), AC_FINDINGS_DELTA and
// AC_FINDINGS_PRIOR_OPEN; <meta> stands in for a call's own prefix
// assignments of the three. <outfile> is bytes (latin1).
export function findingsNormalize(outfile: string, input: Buffer, meta?: { round: string; delta: string; prior: string }): number {
  let round = (meta ? meta.round : process.env.AC_FINDINGS_ROUND) || "1";
  const delta = (meta ? meta.delta : process.env.AC_FINDINGS_DELTA) || "";
  let prior = (meta ? meta.prior : process.env.AC_FINDINGS_PRIOR_OPEN) || "";
  if (!/^[0-9]+$/.test(round)) round = "1";
  const n = testInt(round);
  if (n !== null && n >= 2n) {
    if (prior === "" || stage(["jq", "-e", PRIOR_OPEN_JQ], Buffer.from(`${prior}\n`, "utf8"), "ignore", "ignore").status !== 0) {
      round = "1";
      prior = "[]";
    }
  } else prior = "[]";
  const made = stage(["mktemp", `${argvOf(outfile)}.XXXXXX`], "inherit", "pipe", "inherit");
  if (made.status !== 0) return 1;
  const tmp = capturedText(made.out);
  let fd: number;
  try {
    fd = openSync(latBuf(tmp), "w");
  } catch {
    rmSync(latBuf(tmp), { force: true });
    return 1;
  }
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["jq", "--argjson", "round", round, "--arg", "delta", delta, "--argjson", "prior_open", prior, FINDINGS_NORMALIZE_JQ], { stdin: input, stdout: fd, stderr: "inherit" });
  } catch {
  } finally {
    closeSync(fd);
  }
  const st = shellStatus(r);
  if (st !== 0) {
    rmSync(latBuf(tmp), { force: true });
    return 1;
  }
  return stage(["mv", argvOf(tmp), argvOf(outfile)], "inherit", "inherit", "inherit").status;
}

// ac_findings_summary's twin: jq's stdout bytes (latin1) and its status.
export function findingsSummary(file: string): { status: number; out: string } {
  const r = stage(["jq", "-r", 'if length == 0 then "none"\n         else group_by(.action) | map("\\(.[0].action)=\\(length)") | join(" ") end', argvOf(file)], "inherit", "pipe", "inherit");
  return { status: r.status, out: r.out.toString("latin1") };
}

// ac_project_config_file's twin as the bash's `$(...)` callers read it, bytes
// (latin1) out: <home>/projects/<name>.yaml when it is a regular file, else
// null. Every refusal is printed and answers null - no home (ac_home's ERROR),
// a home cd cannot enter, and a file at the RETIRED <home>/config/projects/
// <name>.yaml, whose die ended only the substitution, so the caller went on.
// `quiet` is a caller's `2>/dev/null`: the same answers, nothing printed.
export function projectConfigFile(repo: string, quiet = false): string | null {
  try {
    return qaConfigFile(repo, !quiet);
  } catch (e) {
    if ((e as { status?: number }).status === 1) return null;
    throw e;
  }
}

// --- spawn twins ---
// The bash helpers the frozen tests/fixtures/ac-spawn.sh leans on, which the
// frozen oracles of ac-learn, ac-pane-agent and ac-verify keep calling
// (src/self-task.ts calls the twins): each twin is pinned to the live helper
// by tests/ts/spawn-twins.test.ts, in the call context that oracle gave it (a
// `$(...)` capture, a `||` guard, or bare under errexit - named per twin,
// since one helper behaves differently in each).
import { ftruncateSync, rmdirSync } from "node:fs";

export type SpawnIo = { stdin?: "inherit" | "ignore"; stderr: "inherit" | "ignore" };
export type Ended = { status: number; exited: boolean };

// ac_die inside a driver the caller ran bare: the line, then the shell gone.
function died(msg: string | Uint8Array): Ended {
  writeSync(2, prefixed("ERROR: ", msg));
  return { status: 1, exited: true };
}

// ac_harness_startup_key's twin.
export function harnessStartupKey(h: string): string {
  return h === "codex" ? "Enter" : "";
}

// orca_resolve_group's twin: the nearest ancestor of <path> (itself first)
// that `orca worktree show --worktree path:<p>` resolves, else <path>.
function orcaResolveGroup(path: string): string {
  for (let p = path; p !== "" && p !== "/"; p = dirname(p)) if (orcaJson(["worktree", "show", "--worktree", `path:${p}`], "inherit") !== null) return p;
  return path;
}

// orca_node_jq verbatim (bin/ac-backend-orca.sh): the entries sharing one
// path, and the one named after the fleet - PIN, AMBIG or NONE.
const ORCA_NODE_JQ = `[.result.worktrees[]? | select(.path == $p)] as $all
  | ($all | map(select((.displayName // "") as $d | ($d | endswith($f))
      and (($d | length) == ($f | length) or ($d[:(($d | length) - ($f | length))] | .[-1:] | IN("/", " ")))))) as $hit
  | if ($hit | length) == 1 then "PIN\\t" + $hit[0].id + "\\t" + ($hit[0].displayName // "")
    elif ($all | length) > 1 then "AMBIG\\t" + ($all | length | tostring) + "\\t" + ($hit | length | tostring)
      + "\\t" + ($all | map(.id + " (" + (.displayName // "") + ")") | join("; "))
    else "NONE" end`;

// orca_home_node's twin: the selector a home pane is created at when
// config/orca-node is absent - the fleet-named entry at the home's resolvable
// ancestor, written to config/orca-node and announced (one fleet-named entry),
// else the ancestor's path selector, warned when several entries share it
// (the deputy-under-parent case the pin exists for) or when the list failed.
// The verdict is read as `IFS=<tab> read -r kind a b c` read it: the last
// field keeps every further tab.
function orcaHomeNode(homeP: string): string {
  const anc = orcaResolveGroup(homeP);
  const fleet = fleetName();
  const list = orcaJson(["worktree", "list"], "inherit");
  if (list === null) {
    warn(latBuf(`orca-node not pinned - orca worktree list failed; the pane goes to path:${anc}`));
    return `path:${anc}`;
  }
  const verdict = capturedText(jqOver(["-r", "--arg", "p", anc, "--arg", "f", fleet, ORCA_NODE_JQ], list, "pipe", "inherit").out);
  const [kind = "", a = "", b = "", ...more] = verdict.split("\t");
  if (kind === "PIN") {
    writeFileSync(join(configDir(), "orca-node"), latBuf(`id:${a}\n`));
    writeSync(2, latBuf(`orca-node: pinned id:${a} (${b})\n`));
    return `id:${a}`;
  }
  if (kind === "AMBIG") warn(latBuf(`orca-node not pinned - ${a} Orca entries share ${anc}, ${b} named '${fleet}': ${more.join("\t")} - write config/orca-node by hand`));
  return `path:${anc}`;
}

// orca_tab_handles' twin: jq's stdout (latin1) - the sorted handles of <tab>
// in the runtime's terminal list; a failed list feeds jq nothing, jq's stderr
// is the caller's.
function orcaTabHandles(tab: string): string {
  const list = orcaJson(["terminal", "list"], "inherit");
  const input = list === null ? Buffer.alloc(0) : latBuf(`${list}\n`);
  return stage(["jq", "-r", "--arg", "t", argvOf(tab), "[.result.terminals[] | select(.tabId==$t) | .handle] | sort | .[]"], input, "pipe", "inherit").out.toString("latin1");
}

// `comm -13 <(printf '%s\n' "$before") <(<after>) | grep -v '^$' | head -n 1`:
// the first non-empty line only <after> holds, by comm's merge walk over
// sorted input in byte order (comm compares by the locale's collation; for
// the jq-sorted handles both agree - named).
function firstNewLine(before: string, after: string): string {
  const a = before.split("\n");
  const b = after === "" ? [] : after.replace(/\n$/, "").split("\n");
  let i = 0;
  for (const line of b) {
    while (i < a.length && a[i]! < line) i++;
    if (i < a.length && a[i] === line) {
      i++;
      continue;
    }
    if (line !== "") return line;
  }
  return "";
}

// orca_place_pane's twin as `$(...)` ran it (errexit asleep), bytes (latin1)
// out: `<handle> <tab>`, or null once the WARN is printed. A pane whose
// physical cwd is not the home is a terminal created under its nearest
// resolvable worktree node; a home pane (a chief) joins its family TAB -
// AC_WINDOW_FAMILY when set (empty: `_root`), else windowFamily - splitting
// the tab state/.orca-fam-<fam> records once a handle there is live, under
// state/.orca-split.lock (41 tries 0.25 s of PATH sleep apart, then unlocked;
// the rmdir then frees whoever held it - kept), the new handle read as the
// tab's list after less before; else a terminal created at config/orca-node
// or the node orcaHomeNode derives, its tab recorded. An explicit command
// rides create/split --command; without one the pane is moved to <dir> by a
// `cd '<dir>'` TYPED and submitted through the send queue, because Orca types
// --command only once the shell prompt is up (measured 2026-10-30, 1.4.244)
// and the caller's launch line, sent right after placement, landed in front
// of it on one shell line - the typed cd shares the launch line's queue, so
// it runs first. The id (family ladder and title) defaults to `agent`.
export function orcaPlacePane(dir: string, cmd = "", agent = ""): string | null {
  const commandArgs = cmd === "" ? [] : ["--command", cmd];
  const id = agent || "agent";
  const dirP = physicalDir(dir) ?? dir;
  const homeP = process.env.AC_HOME ? (physicalDir(process.env.AC_HOME) ?? "") : "";
  const typeCd = (handle: string): void => {
    if (cmd !== "") return;
    const typed = orcaJson(["terminal", "send", "--terminal", argvOf(handle), "--text", `cd '${dir}'`], "inherit");
    const entered = typed === null ? null : orcaJson(["terminal", "send", "--terminal", argvOf(handle), "--enter"], "inherit");
    if (entered === null) warn(`could not type the cd into orca terminal ${handle} - the pane may sit at its node's root instead of ${dir}`);
  };
  const create = (node: string): { handle: string; tab: string } | null => {
    const out = orcaJson(["terminal", "create", "--worktree", node, "--title", `crew:${fleetName()}/${id}`, ...commandArgs], "inherit");
    if (out === null) {
      warn(`orca terminal create failed for ${dir} (is the Orca runtime running - orca open / orca serve - and the repo registered: orca repo add --path <repo>?)`);
      return null;
    }
    const handle = capturedText(jqOver(["-r", ".result.terminal.handle // empty"], out, "pipe", "inherit").out);
    const tab = capturedText(jqOver(["-r", ".result.terminal.tabId // empty"], out, "pipe", "inherit").out);
    if (handle === "" || tab === "") {
      warn("could not parse orca terminal create output");
      return null;
    }
    typeCd(handle);
    return { handle, tab };
  };
  if (dirP !== homeP) {
    const c = create(`path:${orcaResolveGroup(dirP)}`);
    return c === null ? null : `${c.handle} ${c.tab}`;
  }
  const famEnv = process.env.AC_WINDOW_FAMILY;
  const fam = (famEnv !== undefined ? famEnv : windowFamily(id)).replace(/\n+$/, "") || "_root";
  const famf = `${softSubdir("state", true)}/.orca-fam-${fam}`;
  let tab = "";
  try {
    tab = capturedText(readFileSync(famf));
  } catch {}
  const base = tab === "" ? "" : orcaTabHandles(tab).split("\n")[0]!;
  if (base !== "") {
    const lockdir = `${softSubdir("state", true)}/.orca-split.lock`;
    for (let i = 0; ; ) {
      try {
        mkdirSync(lockdir);
        break;
      } catch {}
      if (++i > 40) break;
      stage(["sleep", "0.25"], "inherit", "inherit", "inherit");
    }
    const unlock = (): void => {
      try {
        rmdirSync(lockdir);
      } catch {}
    };
    const before = capturedText(latBuf(orcaTabHandles(tab)));
    if (orcaJson(["terminal", "split", "--terminal", argvOf(base), "--direction", "vertical", ...commandArgs], "inherit") === null) {
      unlock();
      warn(latBuf(`orca terminal split failed (family tab ${tab})`));
      return null;
    }
    const handle = firstNewLine(before, orcaTabHandles(tab));
    unlock();
    if (handle === "") {
      warn(latBuf(`could not identify the split pane in family tab ${tab}`));
      return null;
    }
    typeCd(handle);
    return `${handle} ${tab}`;
  }
  const c = create(configReadSoft("orca-node", "") || orcaHomeNode(homeP));
  if (c === null) return null;
  try {
    writeFileSync(famf, latBuf(`${c.tab}\n`));
  } catch {}
  return `${c.handle} ${c.tab}`;
}

const LEGACY_GROUPS_JQ = `
    [.result.workspaces[]? | select(
      .label == ($f + " (crewchief)") or
      .label == ($f + " (crewmate)") or
      .label == ($f + " (pane-agent)"))] | .[].workspace_id`;

// herdr_sweep_legacy_groups' twin: this fleet's retired per-role workspaces
// closed once provably empty, silently. The answer is its pipeline's status
// under pipefail - jq's, else the list's - which ended the errexit caller
// before any tab existed (W5's sibling, kept).
function sweepLegacyGroups(fleet: string): number {
  const list = herdrCli(["workspace", "list"], "ignore", "pipe");
  const ids = stage(["jq", "-r", "--arg", "f", fleet, LEGACY_GROUPS_JQ], list.out, "pipe", "ignore");
  for (const t of ids.out.toString("latin1").split("\n").slice(0, -1)) if (t !== "" && wsTabsState(t) === "empty") wsClose(t);
  return ids.status !== 0 ? ids.status : list.status;
}

// backend_window_new's twin as ac-spawn.sh ran it - bare, under errexit -
// routed per call: the pane handle `<pane> <tab>` (herdr) or
// `<handle> <tab>` (orca) written LAST to state/.pane-<id>. herdr: the
// family's workspace (AC_WINDOW_FAMILY when set, empty the fleet root, else
// windowFamily) resolved after the legacy-group sweep, a `crew:<id>` tab
// created at <dir>, the default `1` tabs closed; orca: orcaPlacePane. Every
// death the bash had is `exited` with its status - a missing herdr/orca/jq, a
// refused backend name, the sweep's or herdrCloseDefaultTabs' pipeline (W5),
// a workspace or tab create that failed, a create answer jq could not read
// (jq's own line) or holding no ids, a placement that failed, a handle the
// shell could not write (its own line not reproduced). With `errexit` false it
// is the self-task start's `( ... ) || ac_die` subshell (the frozen
// tests/fixtures/ac-self-task.sh) or ac-learn.sh's suite launch inside its
// gate's `if ! ...="$(...)"` (tests/fixtures/ac-learn.sh), errexit asleep: the
// sweep's, both ids' jq and herdrCloseDefaultTabs' statuses go unread (an
// empty id is the parse ERROR), and a workspace that did not resolve is
// `could not resolve herdr workspace '<label>'`.
export function backendWindowNew(id: string, dir: string, errexit = true): Ended {
  const b = backendRoute("inherit");
  if (b === null) return { status: 1, exited: true };
  for (const t of [b, "jq"]) if (!commandV(t)) return died(`required tool not found: ${t}`);
  let handle: string;
  if (b === "herdr") {
    const famEnv = process.env.AC_WINDOW_FAMILY;
    const fam = famEnv !== undefined ? lat(famEnv) : lat(windowFamily(id)).replace(/\n+$/, "");
    const sweep = sweepLegacyGroups(fleetName());
    if (sweep !== 0 && errexit) return { status: sweep, exited: true };
    const label = wsFamilyLabel(fam).replace(/\n+$/, "");
    const ws = herdrResolveWorkspace(label);
    if (ws === null) return errexit ? { status: 1, exited: true } : died(latBuf(`could not resolve herdr workspace '${label}'`));
    const made = herdrTabCreate(ws, lat(dir), lat(id));
    if (made.status !== 0) return died(latBuf(`herdr tab create failed (workspace ${ws})`));
    const ids: string[] = [];
    for (const path of [".result.tab.tab_id // empty", ".result.root_pane.pane_id // empty"]) {
      const r = jqOver(["-r", path], made.out, "pipe", "inherit");
      if (r.status !== 0 && errexit) return { status: r.status, exited: true };
      ids.push(capturedText(r.out));
    }
    const [tab, pane] = ids as [string, string];
    if (tab === "" || pane === "") return died("could not parse herdr tab create output");
    const close = herdrCloseDefaultTabs(ws);
    if (close !== 0 && errexit) return { status: close, exited: true };
    handle = `${pane} ${tab}`;
  } else {
    const placed = orcaPlacePane(dir, "", id);
    if (placed === null) return died(`orca pane placement failed for ${id} at ${dir}`);
    handle = placed;
  }
  try {
    writeFileSync(`${softSubdir("state", true)}/.pane-${id}`, latBuf(`${handle}\n`));
  } catch {
    return { status: 1, exited: true };
  }
  return { status: 0, exited: false };
}

export const AGENT_STATUS_JQ = '[.. | .agent_status? // empty] | map(select(. != "")) | first // empty';

// backend_dialog_answer_pane_{herdr,orca}'s twin, one RAW pane (decoded): 0
// one named dialog answered with the key safe on it - herdr's `agent explain`
// rule startup_update, orca's agentWait reason codex-update-prompt or
// codex-hooks-review-prompt, each taking 2 - 1 nothing pending, 2 a dialog it
// cannot name, 3 unobservable (no pane, a failed read or press). herdr
// focuses the tab `pane get` names, best-effort, before its press.
export function dialogAnswerPane(b: string, p: string, io: SpawnIo): number {
  const top = io.stdin ?? "inherit";
  if (p === "") return 3;
  if (b === "orca") {
    const show = orcaJson(["terminal", "show", "--terminal", p], top);
    if (show === null) return 3;
    if (jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status !== 0) return 1;
    const reason = capturedText(jqOver(["-r", ".result.terminal.agentWait.reason // empty"], show, "pipe", "ignore").out);
    if (reason !== "codex-update-prompt" && reason !== "codex-hooks-review-prompt") return 2;
    return orcaJson(["terminal", "send", "--terminal", p, "--text", "2"], top) === null ? 3 : 0;
  }
  const ex = herdrCli(["agent", "explain", p, "--json"], "ignore", "pipe");
  if (ex.status !== 0) return 3;
  const out = capturedText(ex.out);
  const state = capturedText(jqOver(["-r", ".state // empty"], out, "pipe", "ignore").out);
  if (state === "") return 3;
  if (state !== "blocked") return 1;
  if (capturedText(jqOver(["-r", ".matched_rule.id // empty"], out, "pipe", "ignore").out) !== "startup_update") return 2;
  const tab = capturedText(stage(["jq", "-r", ".result.pane.tab_id // empty"], herdrCli(["pane", "get", p], "ignore", "pipe").out, "pipe", "ignore").out);
  if (tab !== "") herdrCli(["tab", "focus", argvOf(tab)], top, "ignore");
  return herdrCli(["pane", "send-keys", p, "2"], top, "ignore").status === 0 ? 0 : 3;
}

// backend_dialog_answer_pane's twin, routed per call over a raw pane id.
export function backendDialogAnswerPane(pane: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: dialogAnswerPane(b, pane, io), exited: false };
}

// backend_agent_idle_pane_{herdr,orca}'s twin, one RAW pane (decoded): 0
// idle. herdr: `pane get`'s agent_status is idle or done (jq's stderr the
// caller's); orca: the TUI read idle (orcaAgentIdle). No pane, or a failed
// read, is 1.
export function agentIdlePane(b: string, p: string, io: SpawnIo): number {
  if (p === "") return 1;
  if (b === "orca") return orcaAgentIdle(p, io.stdin ?? "inherit", io.stderr) ? 0 : 1;
  const get = herdrCli(["pane", "get", p], "ignore", "pipe");
  if (get.status !== 0) return 1;
  const s = capturedText(jqOver(["-r", AGENT_STATUS_JQ], capturedText(get.out), "pipe", io.stderr).out);
  return s === "idle" || s === "done" ? 0 : 1;
}

// backend_agent_idle's twin: the routed raw-pane reading for the pane the
// task's handle names.
export function backendAgentIdle(id: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: agentIdlePane(b, argvOf(paneField(id, 1, io.stderr === "inherit")), io), exited: false };
}

// ac_startup_dialogs' twin, over the caller's three verbs - <answer> (a
// dialog-answer verdict), <send> (a key press, its status ignored) and <up>
// (harness_up) - each addressing <h> as the caller's layer does (a task id
// or a raw pane), as deliverKickoff (src/spawn.ts) runs it: per round the
// answer's verdict - 0 answered (a PATH `sleep 1`, a round of the budget, look
// again), 1 nothing pending (done once <up> reads up or a shell; unreadable
// spends a round), 2 unnamed (the harness's startup key pressed once, a
// `sleep 1` that spends nothing; the second time done), else the key pressed
// and done. The budget is AC_STARTUP_DIALOG_BUDGET (15); one `[ -lt ]`
// cannot read ends the sequence (its own line not reproduced - W13). A verb
// that exited (a refused backend name) ends it so; a sleep that failed ends
// it exited with sleep's status under <errexit>, and is passed over without
// (the pane agent ran no errexit).
export function startupDialogs(answer: (h: string) => Ended, send: (h: string, key: string) => Ended, up: (h: string) => Ended, h: string, harness: string, errexit = true): Ended {
  const key = harnessStartupKey(harness);
  const budget = testInt(process.env.AC_STARTUP_DIALOG_BUDGET || "15");
  const done: Ended = { status: 0, exited: false };
  let i = 0n;
  let pressed = false;
  for (;;) {
    const a = answer(h);
    if (a.exited) return a;
    let spend = true;
    switch (a.status) {
      case 0:
        break;
      case 1: {
        const u = up(h);
        if (u.exited) return u;
        if (u.status !== 2) return done;
        break;
      }
      case 2: {
        if (key === "" || pressed) return done;
        const k = send(h, key);
        if (k.exited) return k;
        pressed = true;
        spend = false;
        break;
      }
      default: {
        const k = key === "" ? done : send(h, key);
        return k.exited ? k : done;
      }
    }
    if (spend) {
      if (budget === null || i >= budget) return done;
      i++;
    }
    const s = stage(["sleep", "1"], "inherit", "inherit", "inherit").status;
    if (s !== 0 && errexit) return { status: s, exited: true };
  }
}

// orca_worktree_lease's twin as `$(...)` ran it (errexit asleep): the path of
// an Orca-managed worktree on crew/<family> as the answer, status 0; 1 for a
// lease that failed, 2 for the epic-branch fence's refusal (WARNed, nothing
// created). The fence (epicBaseFor): an unreadable ledger, an <override>
// naming another branch, or its integration ref missing - after a best-effort
// fetch when origin exists - refuses; else that branch is the override. The
// base is freshestRef of the override, else of the live branch, else the
// detached HEAD. Unregistered repos are added (a failed add WARNed); a create
// answer whose path is no directory has its id released; the CLI's startup
// terminals on the path are closed (the list word-split, never globbed -
// named); the crew branch is switched to or created - a refused switch
// releases the worktree, status 1 - the CLI's own branch deleted, and the
// primary's node_modules carried (cp -Rc, else -R, else WARNed).
export function orcaWorktreeLease(id: string, repo: string, override = ""): { status: number; out: string } {
  const rname = basename(repo);
  const quiet: [Stdio, "ignore"] = ["ignore", "ignore"];
  const git = (args: string[], out: Stdio = "ignore", err: "inherit" | "ignore" = "ignore"): { status: number; out: Buffer } => stage(["git", "-C", repo, ...args], "inherit", out, err);
  let ov = lat(override);
  const eb = epicBaseFor(id, rname);
  if (eb.rc === 2) {
    warn(`cannot read the ledger to resolve the epic-branch fence for ${id} - nothing was leased`);
    return { status: 2, out: "" };
  }
  if (eb.rc === 0) {
    const ebranch = eb.entry.split(" ")[0]!;
    if (ov !== "" && ov !== ebranch) {
      warn(latBuf(`--base-branch ${ov} disagrees with the epic-branch fence for ${lat(id)} (recorded integration branch ${ebranch} in ${lat(rname)}) - nothing was leased; drop the flag or name ${ebranch}`));
      return { status: 2, out: "" };
    }
    const hasOrigin = (): boolean => git(["remote", "get-url", "origin"], ...quiet).status === 0;
    if (hasOrigin() && git(["fetch", "origin", "--quiet"]).status !== 0) warn(`fetch origin failed; judging the epic-branch fence for ${id} on local refs`);
    const ebref = ` ${eb.entry.slice(ebranch.length)} `.includes(" push=deferred ") || !hasOrigin() ? `refs/heads/${ebranch}` : `refs/remotes/origin/${ebranch}`;
    if (git(["show-ref", "--verify", "--quiet", argvOf(ebref)], "ignore", "inherit").status !== 0) {
      warn(latBuf(`integration branch ${ebranch} for ${lat(id)} is missing (${ebref} does not exist in ${lat(rname)}) - nothing was leased; cut it first: ac-epic-branch.sh create <epic> ${lat(rname)} (ac-feature.sh create <feature> ${lat(rname)} for a push=deferred entry)`));
      return { status: 2, out: "" };
    }
    ov = ebranch;
  }
  let ref: string;
  if (ov !== "") ref = freshestRef(repo, argvOf(ov));
  else {
    const live = git(["symbolic-ref", "--quiet", "--short", "HEAD"], "pipe");
    const base = argvOf(capturedText(live.out));
    ref = live.status === 0 && base !== "" ? freshestRef(repo, base) : argvOf(capturedText(git(["rev-parse", "HEAD"], "pipe", "inherit").out));
  }
  if (orcaJson(["repo", "show", "--repo", `path:${repo}`], "inherit") === null && orcaJson(["repo", "add", "--path", repo], "inherit") === null) warn(`orca repo add failed for ${repo}`);
  const out = orcaJson(["worktree", "create", "--repo", `path:${repo}`, "--name", `crew-${id}`, "--base-branch", ref, "--setup", "run", "--no-parent"], "inherit");
  if (out === null) return { status: 1, out: "" };
  const field = (path: string): string => capturedText(jqOver(["-r", path], out, "pipe", "inherit").out);
  const wt = field(".result.worktree.path // empty");
  if (wt === "" || !isDir(argvOf(wt))) {
    const wtId = field(".result.worktree.id // empty");
    if (wtId !== "") orcaJson(["worktree", "rm", "--worktree", `id:${argvOf(wtId)}`, "--force"], "inherit");
    return { status: 1, out: "" };
  }
  const path = argvOf(wt);
  const list = orcaJson(["terminal", "list"], "inherit");
  const startup = stage(["jq", "-r", "--arg", "p", path, ".result.terminals[] | select(.worktreePath==$p) | .handle"], list === null ? Buffer.alloc(0) : latBuf(`${list}\n`), "pipe", "inherit");
  for (const st of capturedText(startup.out).split(/[ \t\n]+/)) if (st !== "") orcaJson(["terminal", "close", "--terminal", argvOf(st)], "inherit");
  const obranch = field(".result.worktree.branch // empty").replace(/^refs\/heads\//, "");
  const cb = crewBranch(id);
  const inWt = (args: string[], err: "inherit" | "ignore" = "ignore"): number => stage(["git", "-C", path, ...args], "inherit", "ignore", err).status;
  const switched = inWt(["show-ref", "--verify", "-q", `refs/heads/${cb}`], "inherit") === 0 ? inWt(["switch", cb]) : inWt(["switch", "-c", cb]);
  if (switched !== 0) {
    orcaWorktreeRelease(path);
    return { status: 1, out: "" };
  }
  if (obranch !== "") inWt(["branch", "-D", argvOf(obranch)]);
  if (isDir(`${repo}/node_modules`) && !existsSync(`${path}/node_modules`)) {
    const cp = (flag: string): number => stage(["cp", flag, `${repo}/node_modules`, `${path}/node_modules`], "inherit", "ignore", "ignore").status;
    if (cp("-Rc") !== 0 && cp("-R") !== 0) warn(`node_modules carry failed for ${id} - crewmate installs fresh`);
  }
  return { status: 0, out: path };
}

// --- partials twins ---

// ac_claude_transcript_root's twin: AC_CLAUDE_TRANSCRIPT_ROOT, else
// <CLAUDE_CONFIG_DIR, else HOME/.claude>/projects, each rung taken when the
// one above is unset or empty; null where HOME was needed and is unset, the
// point a `set -u` caller died.
export function claudeTranscriptRoot(): string | null {
  const root = process.env.AC_CLAUDE_TRANSCRIPT_ROOT;
  if (root) return root;
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  if (cfg) return `${cfg}/projects`;
  const home = process.env.HOME;
  return home === undefined ? null : `${home}/.claude/projects`;
}

// --- pane-agent twins ---
// The helpers bin/ac-pane-agent.sh leaned on that other bash keeps calling
// (ac-verify, ac-follow, ac-lib's own) and the raw-pane backend verbs it alone
// called, each pinned to its live bash by tests/ts/pane-agent-twins.test.ts in
// the call context the pane agent gave it.

import { isoEpoch } from "./pane-agent.ts";

export { orcaJson };

// --- verify twins ---
// The helpers bin/ac-verify.sh called that had no twin, src/verify.ts's now,
// each pinned to the LIVE bash that ac-pane-agent.sh keeps calling for the
// epoch, the arm and the pane capture until its last bash caller goes
// (tests/ts/verify-twins.test.ts).


// herdr_focus_pane's twin: the tab `pane get` names (both reads /dev/null
// inside their `$( )`), focused; 1 when no tab answered, else the focus's
// status.
export function herdrFocusPane(p: string, top: "inherit" | "ignore"): number {
  const tab = capturedText(stage(["jq", "-r", ".result.pane.tab_id // empty"], herdrCli(["pane", "get", p], "ignore", "pipe").out, "pipe", "ignore").out);
  return tab === "" ? 1 : herdrCli(["tab", "focus", argvOf(tab)], top, "ignore").status;
}

// backend_harness_up_pane_herdr's twin, one RAW pane (decoded) - the HARNESS
// CAME-UP PROBE: 0 a foreground process that is no shell, 1 every one a
// shell, 2 no pane, a failed read or no process named.
function harnessUpHerdr(p: string): number {
  if (p === "") return 2;
  const info = herdrCli(["pane", "process-info", "--pane", p], "ignore", "pipe");
  if (info.status !== 0) return 2;
  const names = capturedText(jqOver(["-r", ".result.process_info.foreground_processes[]? | (.argv0 // .name // empty)"], capturedText(info.out), "pipe", "ignore").out);
  if (names === "") return 2;
  // `read -r n` trimmed each line's IFS blanks.
  return names.split("\n").every((n) => SHELLS.includes(commandName(n.replace(/^[ \t]+|[ \t]+$/g, "")))) ? 1 : 0;
}

// backend_harness_up_pane_orca's twin, one RAW pane (decoded): 1 a shell's
// title; 0 orca's own harness identity or wait, a harness glyph or an idle
// TUI; 2 anything else, a disconnected or unreadable terminal included.
function harnessUpOrca(h: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
  if (h === "") return 2;
  const show = orcaJson(["terminal", "show", "--terminal", h], stdin);
  if (show === null || jqOver(["-e", ".result.terminal.connected == true"], show, "ignore", "ignore").status !== 0) return 2;
  const title = commandName(capturedText(jqOver(["-r", ".result.terminal.title // empty"], show, "pipe", stderr).out));
  if (SHELLS.includes(title)) return 1;
  if (jqOver(["-e", ".result.terminal.agentIdentity != null or .result.terminal.agentWait != null"], show, "ignore", "ignore").status === 0) return 0;
  if (title.startsWith(IDLE_GLYPH) || spins(title)) return 0;
  return orcaAgentIdle(h, stdin, stderr) ? 0 : 2;
}

// backend_harness_up_pane's twin, routed per call over a raw pane id.
export function backendHarnessUpPane(pane: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  return { status: b === "herdr" ? harnessUpHerdr(pane) : harnessUpOrca(pane, io.stdin ?? "inherit", io.stderr), exited: false };
}

// backend_send_key_pane's twin, routed per call over a raw pane id: no pane
// 1; herdr focuses the tab `pane get` names (best-effort) and presses the
// key, its status the press's; orca sends the key straight to the PTY, 0 or 1.
export function backendSendKeyPane(pane: string, key: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  if (pane === "") return { status: 1, exited: false };
  const top = io.stdin ?? "inherit";
  if (b === "orca") {
    const named = keyNamed(key);
    const how = named === "enter" ? ["--enter"] : named === "escape" ? ["--text", "\x1b"] : named === "ctrl+c" ? ["--interrupt"] : ["--text", key];
    return { status: orcaJson(["terminal", "send", "--terminal", pane, ...how], top) !== null ? 0 : 1, exited: false };
  }
  herdrFocusPane(pane, top);
  return { status: herdrCli(["pane", "send-keys", pane, keyNamed(key) ?? key.replace(/\n+$/, "")], top, "ignore").status, exited: false };
}

// backend_startup_dialogs_pane's twin: ac_startup_dialogs' sequence over the
// raw-pane verbs - answered, keyed and probed by <pane> - as the pane agent
// ran it, bare without errexit.
export function backendStartupDialogsPane(pane: string, harness: string, io: SpawnIo): Ended {
  return startupDialogs((p) => backendDialogAnswerPane(p, io), (p, k) => backendSendKeyPane(p, k, io), (p) => backendHarnessUpPane(p, io), pane, harness, false);
}

// --- qa twins ---
// tests/fixtures/ac-pipeline-lib.sh's two other readers of the flat YAML subset, which
// the bash ac-qa.sh called (tests/ts/qa-lib.test.ts): yamlGet's siblings, each
// awk program the bash's verbatim and spawned in the caller's locale as
// yamlGet's is - its leading LF and indent included, since awk's own error
// lines name the program's source line.

const YAML_KEYS_AWK = `
    BEGIN { n = split(key, parts, ".") ; depth = 0 ; found = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      if (found) {
        # A sibling or anything shallower ends the block; deeper lines are
        # descendants, not children, and are skipped.
        if (ind < want) exit
        if (ind == want) print k
        next
      }
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { found = 1; want = ind + 1; next }
        depth++
      }
    }
  `;

// ac_yaml_keys' twin, bytes (latin1) in and out: awk's stdout - the block's
// immediate child keys, a LF after each - and its status.
export function yamlKeys(file: string, key: string): { status: number; out: string } {
  const r = stage(["awk", "-v", `key=${argvOf(key)}`, YAML_KEYS_AWK, argvOf(file)], "inherit", "pipe", "inherit");
  return { status: r.status, out: r.out.toString("latin1") };
}

const YAML_HAS_AWK = `
    BEGIN { n = split(key, parts, ".") ; depth = 0 }
    /^[[:space:]]*(#|$)/ { next }
    {
      match($0, /^ */); ind = int(RLENGTH / 2)
      line = $0; sub(/^ */, "", line)
      if (line !~ /^[A-Za-z0-9_-]+:/) next
      k = line; sub(/:.*$/, "", k)
      if (ind < depth) depth = ind
      if (ind == depth && k == parts[depth + 1]) {
        if (depth + 1 == n) { found = 1; exit }
        depth++
      }
    }
    END { exit(found ? 0 : 1) }
  `;

// ac_yaml_has' twin: awk's status - 0 present, 1 absent, 2 when awk failed (a
// file it could not read, or a byte a UTF-8 locale cannot decode; its lines on
// stderr).
export function yamlHas(file: string, key: string): number {
  return stage(["awk", "-v", `key=${argvOf(key)}`, YAML_HAS_AWK, argvOf(file)], "inherit", "inherit", "inherit").status;
}

// --- self-task twins ---

// ac_family_owned's twin as an `if` reads it: true when a meta crewMetas lists
// (verifiers and chiefs skipped) names a task of <id>'s family - the name
// `basename <m> .meta` leaves, read by familyOfId, the derivation crewBranch
// builds the branch from.
export async function familyOwned(id: string, sd: string): Promise<boolean> {
  const fam = familyOfId(id);
  for await (const m of crewMetas(sd, "verify", "chiefs")) {
    if (m === "") continue;
    const name = m.slice(m.lastIndexOf("/") + 1);
    if (familyOfId(name.endsWith(".meta") ? name.slice(0, -".meta".length) : name) === fam) return true;
  }
  return false;
}

// --- watch twins ---

// AC_DECISION_RE's default (bin/ac-lib.sh), an exported non-empty value
// winning as it did at source time: the captain-wait subset of CAPTAIN_RE,
// an ERE for a SPAWNED grep under the caller's locale. Held to that file by
// tests/ts/watch.test.ts.
export const DECISION_RE =
  process.env.AC_DECISION_RE || "^[^[:alpha:][:digit:]\"'`=+#/*-]*(needs-decision|blocked|checks-passed):([[:space:]]|$)";

// True once a line's own `until <epoch>` clause is no later than now. A
// line naming no `until` never expires - it defers for the worker's word
// alone, not a self-declared deadline. A 9+ digit run is required so a
// plain date, clock time or small count in the same sentence ("until
// 2026-11-01", "until 10:30", "until 3 tests pass") is never misread as an
// already-elapsed unix epoch; today's epoch is 10 digits.
export function pausedWaitExpired(line: string): boolean {
  const m = /\buntil\s+([0-9]{9,})\b/.exec(line);
  if (m === null) return false;
  const until = testInt(m[1]!);
  const now = testInt(nowRaw());
  return until !== null && now !== null && now >= until;
}

// rowContractForId's row-returning twin: the whole `- [ ] `/`- [x] ` ledger
// line for <id>, its own row first, else its family's (the same
// stageDirForId fallback) - null when neither exists or the ledger could
// not be read. src/watch.ts's STALE DEFERRAL header owns the backlog-hold
// read this feeds.
export function rowForId(id: string, ledger: Ledger): string | null {
  if (ledger.rc !== 0) return null;
  const rows = records(ledger.text).filter((l) => /^- \[[ x]\] /.test(l));
  const rowOf = (want: string): string | undefined => {
    const w = awkAssign(Buffer.from(want, "utf8").toString("latin1"));
    for (const l of rows) if (acDoneline(l).id === w) return l;
    return undefined;
  };
  const exact = rowOf(id);
  if (exact !== undefined) return exact;
  const sub = stageDirForId(id);
  return sub === "" ? null : rowOf(sub.slice(0, sub.indexOf("/"))) ?? null;
}

// ac_watcher_beat_path's twin: the liveness beacon of a scope under <sd>, the
// fleet's for a scope wakeScopeOk refuses. Pure.
export function watcherBeatPath(sd: string, scope = ""): string {
  return wakeScopeOk(scope) ? `${sd}/.last-watcher-beat.${scope}` : `${sd}/.last-watcher-beat`;
}

// One `ps -o <field>= -p <pid>` read as the bash's `$(ps ... 2>/dev/null |
// ...)` read it: the bytes (latin1), "" when ps fails or cannot start.
function psField(field: string, pid: string): string {
  try {
    return spawnShellSync(["ps", "-o", `${field}=`, "-p", Buffer.from(pid, "latin1").toString("utf8")], { stdin: "ignore", stdout: "pipe", stderr: "ignore" }).stdout.toString("latin1");
  } catch {
    return "";
  }
}

// ac_pid_chain's twin: `<pid>(<comm>) < <ppid>(<comm>) < ...` from <pid>
// (this process when absent or empty) toward init - a link only while the pid reads as
// an integer above 1, at most 16 - each comm the first line of its ps read
// with [:space:] (under the caller's locale) gone and cut after its last `/`,
// `?` when that leaves nothing; `?` for no link at all. Bytes (latin1).
export function pidChain(pid = ""): string {
  if (pid === "") pid = String(process.pid);
  const space = (s: string): string => Buffer.from(Buffer.from(s, "latin1").toString("utf8").replace(shellSpaceClass(), ""), "utf8").toString("latin1");
  let out = "";
  for (let depth = 0; pid !== "" && depth < 16; depth++) {
    const n = testInt(pid);
    if (n === null || n <= 1n) break;
    let comm = space(psField("comm", pid).split("\n")[0]!);
    comm = comm.slice(comm.lastIndexOf("/") + 1) || "?";
    out += `${out === "" ? "" : " < "}${pid}(${comm})`;
    pid = psField("ppid", pid).replace(/[ \t\n\v\f\r]/g, "");
  }
  return out || "?";
}

// ac_brain_marker_age's twin: seconds since state/.brain-last-sync's mtime
// (fileMtime, 0 when it cannot be read) by date(1)'s clock, -1 with no
// marker; null homeless, ac_home's refusal printed as the bash's `$(ac_home)`
// printed it.
export function brainMarkerAge(): bigint | null {
  const home = softHome(true);
  if (home === "") return null;
  const marker = `${home}/state/.brain-last-sync`;
  if (!isFile(marker)) return -1n;
  return BigInt.asIntN(64, arithValue(nowRaw()) - BigInt(fileMtime(marker) ?? "0"));
}

// ac_brain_freshen's twin, the catch-up throttle the watcher and the
// prompt-recall hook share: true when it fired ONE detached
// `<bin>/ac-brain.sh sync --home <home> --compact` - state/brain.sqlite
// present, config/brain-auto-sync on, the marker older than AC_BRAIN_SYNC_IV
// (1800; compared as `[ ]` compares, a knob that is no integer never fires)
// and so is the attempt stamp, which is touched first. The sync runs under a
// /bin/sh that backgrounds it and exits, so it is never this process's
// child, as the bash's `( ... & )` left it. An attempt stamp that cannot be
// written fires nothing (the bash's redirection failure ended an errexit
// caller there).
export function brainFreshen(): boolean {
  const home = softHome(true);
  if (home === "" || !isFile(`${home}/state/brain.sqlite`)) return false;
  if (configReadSoft("brain-auto-sync", "on") !== "on") return false;
  const iv = testInt(process.env.AC_BRAIN_SYNC_IV || "1800");
  const age = brainMarkerAge();
  if (iv === null || age === null || (age >= 0n && age < iv)) return false;
  const attempt = `${home}/state/.brain-freshen-attempt`;
  const la = isFile(attempt) ? BigInt(fileMtime(attempt) ?? "0") : 0n;
  if (BigInt.asIntN(64, arithValue(nowRaw()) - la) < iv) return false;
  try {
    writeFileSync(attempt, "");
  } catch {
    return false;
  }
  try {
    spawnShellSync(["/bin/sh", "-c", '"$0" "$@" >/dev/null 2>&1 &', `${STARTED_BIN}/ac-brain.sh`, "sync", "--home", home, "--compact"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  } catch {}
  return true;
}

// --- hook twins ---

// `payload="$(cat 2>/dev/null || true)"`, a hook's read of the harness's
// payload: stdin to its end (a read that fails keeps what arrived, as cat's
// partial output did), NULs dropped and trailing LFs stripped as the
// substitution did; bytes (latin1).
export function hookPayload(): string {
  const parts: Buffer[] = [];
  const chunk = Buffer.alloc(65536);
  for (;;) {
    let n: number;
    try {
      n = readSync(0, chunk, 0, chunk.length, null);
    } catch (e) {
      if ((e as { code?: string }).code === "EAGAIN") {
        Bun.sleepSync(5);
        continue;
      }
      break;
    }
    if (n === 0) break;
    parts.push(Buffer.from(chunk.subarray(0, n)));
  }
  return capturedText(Buffer.concat(parts));
}

// `$(<argv> 2>/dev/null || true)` in a hook: the child's stdout whatever its
// status, NULs dropped and trailing LFs stripped, "" when it cannot start;
// stderr dropped. Bytes (latin1).
export function hookCapture(argv: string[], stdin: "inherit" | Buffer = "inherit"): string {
  return capturedText(stage(argv, stdin, "pipe", "ignore").out);
}

// `$(jq -r <filter> <<<"$payload" 2>/dev/null || true)`: jq's own reading of
// the payload, so a value printed before a parse error still counts and a
// field that is no string arrives as jq's JSON text.
export function hookJq(filter: string, payload: string): string {
  return hookCapture(["jq", "-r", filter], Buffer.from(`${payload}\n`, "latin1"));
}

// ac_hook_trace's twin (bin/ac-lib.sh), the Stop hooks' durable trail: one
// `<iso> hook=<hook> <detail>` line appended to <home>/state/.stop-hooks.log,
// the state dir minted as ac_state_dir minted it - never a byte on stdout or
// stderr but date's own, and a date that cannot start stamps the line empty as
// `$(ac_iso)` did; no AC_HOME, or one cd cannot enter, writes nothing.
// <detail> is bytes (latin1). Past AC_STOPHOOK_LOG_KEEP*2 lines (unset or
// empty: 200) the log keeps its last AC_STOPHOOK_LOG_KEEP through tail(1),
// spawned into an exclusive temp (exclusiveTemp) that mv(1) puts in place; a
// tail that fails leaves its temp, as the original's did. The knob enters
// `$(( keep * 2 ))` only after the line is written, and arithValue's
// EUNBOUND (set -u ended the caller with the line count's status, 0) or
// EARITH (the caller's top-level command discarded) is thrown for the caller
// to act on.
export function hookTrace(hook: string, detail: string): void {
  const h = process.env.AC_HOME;
  const home = h ? physicalDir(h) : null;
  if (home === null) return;
  const sd = `${home}/state`;
  try {
    mkdirSync(sd, { recursive: true });
  } catch {}
  const f = `${sd}/.stop-hooks.log`;
  const keep = process.env.AC_STOPHOOK_LOG_KEEP || "200";
  let ts = "";
  try {
    ts = iso();
  } catch {}
  try {
    appendFileSync(f, Buffer.from(`${ts} hook=${hook} ${detail}\n`, "latin1"));
  } catch {}
  let lines = 0n;
  try {
    for (const c of readFileSync(f)) if (c === 10) lines++;
  } catch {}
  if (lines <= BigInt.asIntN(64, arithValue(keep) * 2n)) return;
  let tmp: { path: string; fd: number };
  try {
    tmp = exclusiveTemp(`${f}.tmp`);
  } catch {
    return;
  }
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["tail", "-n", keep, f], { stdin: "ignore", stdout: tmp.fd, stderr: "ignore" });
  } catch {}
  closeSync(tmp.fd);
  if (shellStatus(r) !== 0) return;
  try {
    spawnShellSync(["mv", tmp.path, f], { stdin: "ignore", stdout: "inherit", stderr: "ignore" });
  } catch {}
}

// --- sessionstart-nudge twins ---

// ac_self_tasks_in_flight's twin, as its callers ran it (`2>/dev/null ||
// true`): one line per kind=self meta crewMetas lists (verifiers and chiefs
// skipped), naming the task, its project= (bytes), its age - ac_now less the
// meta's mtime (the clock itself when that cannot be read), `<n>d` from a day
// up, else `<n>h`, truncated as `$(( ))` truncates - and the two ways out; ""
// homeless or when there is none. A clock `$(( ))` cannot read ends the list
// there, as the shell abandoned the statement. Bytes (latin1).
export async function selfTasksInFlight(): Promise<string> {
  const sd = softSubdir("state", false);
  if (sd === "") return "";
  const now = nowRaw("ignore");
  let out = "";
  for await (const m of crewMetas(sd, "verify", "chiefs", "quiet")) {
    if (!metaIsSelf(m)) continue;
    const id = Buffer.from(m.slice(m.lastIndexOf("/") + 1).replace(/\.meta$/, ""), "utf8").toString("latin1");
    let proj = "";
    try {
      proj = metaGet(m, "project");
    } catch {}
    let age: bigint;
    try {
      age = BigInt.asIntN(64, arithValue(now) - arithValue(fileMtime(m) ?? now));
    } catch {
      break;
    }
    const shown = age >= 86400n ? `${age / 86400n}d` : `${age / 3600n}h`;
    out += `self task ${id} (${proj}, opened ${shown} ago) is in flight: land it with bin/ac-teardown.sh ${id}, or discard it with bin/ac-teardown.sh ${id} --force - its lease holds a pool slot until then\n`;
  }
  return out;
}

// --- prompt-recall twins ---
// brainMarkerAge and brainFreshen, which the watcher shares, are the watch
// twins above.
