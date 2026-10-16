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
  return metaValue(text, key);
}

function metaValue(text: string, key: string): string {
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
// failure ends the run with its status as `set -e` did.
export function seedRuntimeLinks(home: string): void {
  for (const f of ["bin", "CLAUDE.md", ".claude", "AGENTS.md"]) {
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

function isFile(p: string | Buffer): boolean {
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

function metaRewrite(file: string, pairs: (get: (key: string) => string) => [string, string][], quiet = false): void {
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

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// ac_task_dir's twin, the brief-layout resolver of src/brief.ts resolved by
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
  if (rev) return isDir(`${softSubdir("data", true)}/${fam}/${rev[1]}`) ? fam : id.slice(0, id.lastIndexOf("-r"));
  return isDir(`${softSubdir("data", true)}/${sub}`) ? fam : id;
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
  const live = `${softSubdir("data", true)}/${fam}/room.md`;
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
  for (let base = fam; base.includes("-"); ) {
    base = base.slice(0, base.lastIndexOf("-"));
    if (isFile(`${softSubdir("data", true)}/${base}/tasks/${fam.slice(base.length + 1)}/brief.md`)) return roomFile(base);
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
function capturedText(b: Buffer): string {
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

const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");

// A string in awk arithmetic (onetrue awk's getfval is atof): strtod's longest
// numeric PREFIX - `17x` is 17, a hex or inf/nan spelling counts - and 0 when
// there is none, so a header line's epoch reads 0.
function awkAtof(s: string): number {
  const m = /^[ \t\n\v\f\r]*([+-]?)(?:0[xX]([0-9a-fA-F]+)|((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|([iI][nN][fF])|[nN][aA][nN])/.exec(s);
  if (!m) return 0;
  const sign = m[1] === "-" ? -1 : 1;
  if (m[2] !== undefined) return sign * parseInt(m[2], 16);
  if (m[3] !== undefined) return sign * Number(m[3]);
  return m[4] !== undefined ? sign * Infinity : NaN;
}

// awk's %d: the number cast to a 64-bit integer.
function awkInt(x: number): bigint {
  if (x >= 2 ** 63) return 2n ** 63n - 1n;
  if (x < -(2 ** 63)) return -(2n ** 63n);
  return Number.isNaN(x) ? 0n : BigInt(Math.trunc(x));
}

const landingsPath = (): string => `${softSubdir("state", true)}/.landings`;

const sleepOne = (): void => {
  spawnShellSync(["sleep", "1"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
};

// ac_landing_overlaps' awk over state/.landings, `<family>\t<age>\t<path>` per
// record: the epoch read as awk reads it, the family compared numerically when
// both sides look numeric (`07` is the family `7`), the path matched as a
// whole third field. An unreadable ledger throws awk's status 2 (its own
// `can't open file` line is not reproduced).
export function landingOverlaps(max: number, excl: string, paths: string[]): string[] {
  const f = landingsPath();
  if (!isFile(f) || paths.length === 0) return [];
  const now = awkAtof(awkAssign(nowRaw()));
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    throw Object.assign(new Error(`cannot read ${f}`), { code: "EAWK", status: 2 });
  }
  const plist = lat(paths.join("\n")).replace(/\n+$/, "");
  const want = new Set(plist === "" ? [] : plist.split("\n"));
  const ex = awkAssign(lat(excl));
  const exN = awkNumber(ex);
  const hits: string[] = [];
  for (const r of records(text)) {
    const [f1 = "", f2 = "", f3 = ""] = r.split("\t");
    const age = now - awkAtof(f1);
    if (!(age < max) || !want.has(f3)) continue;
    const n2 = exN === null ? null : awkNumber(f2);
    if (n2 !== null && exN !== null ? !(n2 - exN < 0 || n2 - exN > 0) : f2 === ex) continue;
    hits.push(`${f2}\t${awkInt(age)}\t${f3}`);
  }
  return hits;
}

// ac_landing_warn's twin (no entry calls the bash copy, nor the
// ac_landing_overlaps under it, now): one
// `LANDING-OVERLAP: <path> landed <h>h ago by family <f> - required reading:
// <room>` WARN per record younger than a day from another family touching one
// of <paths>, read back as `IFS=$'\t' read -r` reads it - so a record with an
// EMPTY family shifts its age into the family and its path into the age.
// Where the bash's errexit ended the run it throws with the status: 2 for an
// unreadable ledger, 1 for an age the shell's arithmetic refused under
// nounset - here any but a plain decimal (the shell evaluated the shifted path
// as an expression, so `p` or `UID` read as numbers there; not reproduced).
export function landingWarn(fam: string, paths: string[]): void {
  for (const hit of landingOverlaps(86400, fam, paths)) {
    const [pf, age, p] = tabFields(hit, 3) as [string, string, string];
    if (age !== "" && !/^-?(0|[1-9][0-9]*)$/.test(age)) throw Object.assign(new Error(`arithmetic on ${age}`), { code: "EARITH", status: 1 });
    const hours = age === "" ? 0n : BigInt(age) / 3600n;
    const room = lat(roomFile(Buffer.from(pf, "latin1").toString("utf8")));
    warn(Buffer.from(`LANDING-OVERLAP: ${p} landed ${hours}h ago by family ${pf} - required reading: ${room}`, "latin1"));
  }
}

// ac_landing_record's twin (no entry calls the bash copy now): under
// state/.landings.lock (10 s through a spawned `sleep`, then the UNSERIALIZED
// WARN and the write anyway) the ledger is rewritten with its records older
// than 7 days pruned by awk's reading and `<now>\t<fam>\t<path>` appended per
// path, <now> as ac_now spelled it. The temp is created EXCLUSIVELY
// (`<ledger>.tmp.<pid>`, the next name on EEXIST - the bash wrote through a
// planted sibling) and a spawned `mv` renames it over the ledger: false when
// the mv failed, the bash's return 1. Where the bash's errexit ended the run
// it throws with the status, the lock left held as it was there: 2 for an
// unreadable ledger, 1 for a temp that cannot be created.
export function landingRecord(fam: string, paths: string[]): boolean {
  if (paths.length === 0) return true;
  const f = landingsPath();
  const lock = `${f}.lock`;
  const locked = lockAcquire(lock, 10, sleepOne);
  if (!locked)
    warn(`landing ledger: ${lock} could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them`);
  const now = nowRaw();
  const nowN = awkAtof(awkAssign(now));
  let body = "";
  if (isFile(f)) {
    let text: string;
    try {
      text = readFileSync(f, "latin1");
    } catch {
      throw Object.assign(new Error(`cannot read ${f}`), { code: "EAWK", status: 2 });
    }
    for (const r of records(text)) if (nowN - awkAtof(r.split("\t")[0]!) <= 604800) body += `${r}\n`;
  }
  for (const p of paths) body += `${now}\t${lat(fam)}\t${lat(p)}\n`;
  let tmp = `${f}.tmp.${process.pid}`;
  for (let i = 1; ; i++) {
    try {
      writeFileSync(tmp, Buffer.from(body, "latin1"), { flag: "wx" });
      break;
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw Object.assign(e as object, { status: 1 });
      tmp = `${f}.tmp.${process.pid}.${i}`;
    }
  }
  let status = 127;
  try {
    status = shellStatus(spawnShellSync(["mv", tmp, f], { stdin: "ignore", stdout: "inherit", stderr: "inherit" }));
  } catch {}
  if (locked) lockRelease(lock);
  return status === 0;
}

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

// ac_knowledge_warn's twin (no entry calls the bash copy now): the KNOWLEDGE-GAP
// WARN when <fam> left no live `- ... | by: <fam>` entry in the project's
// repo-knowledge record - the suffix compared as a string (awk -v read its
// escapes), the scan stopped at `## Superseded`. Silent for an empty family,
// a <repo> that is no directory or no repo. The remedy names
// <STARTED_BIN>/ac-know.sh, the bin/ of ac_root, and the physical home. An
// unreadable record is no entry (awk's own line is not reproduced).
export function knowledgeWarn(fam: string, repo: string): void {
  if (fam === "" || repo === "" || !isDir(repo)) return;
  let repoOk = false;
  try {
    repoOk = spawnShellSync(["git", "-C", repo, "rev-parse", "--git-dir"], { stdin: "inherit", stdout: "ignore", stderr: "ignore" }).exitCode === 0;
  } catch {}
  if (!repoOk) return;
  const name = projectConfigName(repo);
  if (name === null) return;
  const rec = `${softSubdir("records", false)}/repo-knowledge/${name}.md`;
  let text = "";
  try {
    if (isFile(rec)) text = readFileSync(rec, "latin1");
  } catch {}
  const suffix = awkAssign(lat(`| by: ${fam}`));
  for (const r of records(text)) {
    if (r.startsWith("## Superseded")) break;
    if (r.startsWith("- ") && r.endsWith(suffix)) return;
  }
  const home = softHome(true);
  warn(
    `KNOWLEDGE-GAP: family ${fam} is landing on ${name} with no repo-knowledge entry -\nrecord what it learned (${STARTED_BIN}/ac-know.sh add --home ${home} --repo ${repo} --family ${fam} --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: ${rec}`,
  );
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

const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");

// `"$sd"/*.meta` as a bash loop walked it: every non-dot name ending .meta, in
// byte order (the glob followed the locale's collation); the caller tests
// `[ -e ]`.
export function metaPaths(sd: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(sd);
  } catch {}
  return names
    .filter((n) => !n.startsWith(".") && n.endsWith(".meta"))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${sd}/${n}`);
}

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

type ProbeIo = { stdin: "inherit" | "ignore"; stdout: "inherit" | "ignore" };

// `( AC_BACKEND="${b:-herdr}"; export AC_BACKEND; backend_window_alive
// <target> ) 2>/dev/null`, <b> the meta's backend= read as `ac_meta_get ...
// 2>/dev/null || true` read it (cut at a NUL; an unreadable meta or no key is
// herdr): AC_BACKEND set to the text <b>'s bytes spell, as the shell's export
// did, for the ONE backendCall, a subshell call as the `( )` made it, and
// restored after; true only for status 0.
function windowAliveAs(m: string, target: string, io: ProbeIo): boolean {
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

// ac_chief_child_live's twin: <id> is a <fam>-chief with a LIVE member - over
// metaPaths, a verifier skipped and the chief's own pane skipped first, an id
// familyOfId reads as <fam>, else a fleet_scope= of <fam> read LOUD (an
// unreadable member warns `cannot read meta file` and is no member) - each
// probed by windowAliveAs with the caller's stdin and stdout; the first live
// member answers.
export function chiefChildLive(sd: string, id: string, io: ProbeIo): boolean {
  if (!id.endsWith("-chief")) return false;
  const fam = id.slice(0, -"-chief".length);
  for (const m of metaPaths(sd)) {
    if (!existsSync(m) || metaIsVerify(m)) continue;
    const cid = m.slice(sd.length + 1, -".meta".length).replace(/\n+$/, "");
    if (cid === `${fam}-chief`) continue;
    if (familyOfId(cid) !== fam) {
      let scope = "";
      try {
        scope = cutNul(metaGet(m, "fleet_scope"));
      } catch {}
      if (scope !== fam) continue;
    }
    if (windowAliveAs(m, cid, io)) return true;
  }
  return false;
}

// ac_chief_gate_parked's twin: <id> is a <fam>-chief whose LIVE room
// (<data>/<fam>/room.md, data/ minted as `$(ac_data_dir)` minted it) still
// holds an unanswered GATE/ASK (roomPendingLines' count). A room it cannot read
// is not parked, after ac_room_scan's grep printed its own refusal - spawned
// again for that line, under C; the `[` line bash added there is the shell's.
export function chiefGateParked(id: string): boolean {
  if (!id.endsWith("-chief")) return false;
  const f = `${softSubdir("data", true)}/${id.slice(0, -"-chief".length)}/room.md`;
  const open = roomPendingLines(f);
  if (open !== null) return open !== "";
  try {
    spawnShellSync(["/usr/bin/env", "LC_ALL=C", "grep", "-a", "-H", "-E", "--", "^- \\[[^]]*\\] [^>]*> (GATE|ASK|DECIDED)", f], {
      stdin: "inherit",
      stdout: "ignore",
      stderr: "inherit",
    });
  } catch {}
  return false;
}

// The dead-claim sweep's verdict on a claim dir's pid (src/wake-drain.ts):
// KEPT while it is not this process, is alive (pidAlive) and its `ps -o
// command= -p <pid>` either cannot be read - failing toward live - or names a
// drainer: the bash entry by its name, or this module, which a drainer the
// shim started runs as `bun --no-env-file <root>/src/wake-drain.ts <cwd>`.
// Matching the entry name alone would read a live TS drainer as a reused pid
// and hand its claimed records to a second drain, which emits them again.
export function claimLive(pid: string): boolean {
  if (pid === String(process.pid) || !pidAlive(pid)) return false;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["ps", "-o", "command=", "-p", pid], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  if (r === null || shellStatus(r) !== 0) return true;
  const cmd = capturedText(Buffer.from(r.stdout));
  return cmd.includes("ac-wake-drain") || cmd.includes("/src/wake-drain.ts");
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

function mkdirP(dir: string): void {
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

const latBuf = (s: string): Buffer => Buffer.from(s, "latin1");
const QA_SEGMENT = /^[A-Za-z0-9_-]+$/;

// ac_project_config_file's twin, the name resolved before the home is looked
// at: <home>/projects/<name>.yaml when it is a regular file, else null. A
// regular file at the RETIRED <home>/config/projects/<name>.yaml is checked
// first: `loud` (the bash's bare call) writes ac_die's line and throws status
// 1, the exit of the whole shell; quiet (a `$(...)` with stderr dropped) it
// is null like a homeless or unenterable home.
function qaConfigFile(repo: string, loud: boolean): string | null {
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

// ac_qa_required's twin: is the gate ENFORCED for <repo>? A policy that
// cannot be read writes its refusal and throws status 1, as the RETIRED copy
// does: a `git --version` that does not start or fails (no repo resolves to a
// policy), then a <repo>/.git that exists (`[ -e ]`) where git cannot name
// the repo, then a canonical yaml that is a regular file and cannot be read.
// The config is resolved loud, then quiet, and read as `$(cat)` read it. Then
// the grammar over that text and one LF, in the C locale: a column-0 `qa:`
// with optional space and an optional `#` comment or a flow mapping's `{`
// opens the block, a later column-0 line that is no comment closes it. A key
// is `require_for_ship`, bare or quoted with `"` or `'`, optional space, a
// colon, looked for in each block line's whole text (the flow header's too,
// a comment's too): at the line's start past its indent (the value runs to
// the line's end), or past a `{` or `,` and optional space (the value ends at
// the next `,` or `}`). ANY key whose value - a comment (`#` after a space)
// cut, `"` and `'` deleted, its ends trimmed - is no false spelling enforces;
// no key is not enforced.
export function qaRequired(repo: string): boolean {
  let gitRuns = false;
  try {
    gitRuns = spawnShellSync(["git", "--version"], { stdin: "inherit", stdout: "ignore", stderr: "ignore" }).exitCode === 0;
  } catch {}
  if (!gitRuns) {
    writeSync(2, `ERROR: qa.require_for_ship: git did not run (is it on PATH?), so the project policy for '${repo}' cannot be resolved - refusing the merge rather than reading it as not enforced\n`);
    throw Object.assign(new Error("git did not run"), { status: 1 });
  }
  if (existsSync(`${repo}/.git`) && projectConfigName(repo) === null) {
    writeSync(
      2,
      `ERROR: qa.require_for_ship: git could not read the repo at '${repo}' (it holds .git, but git rev-parse failed there - a corrupt repo, or one safe.directory refuses), so its project policy cannot be resolved - refusing the merge rather than reading it as not enforced\n`,
    );
    throw Object.assign(new Error("git could not read the repo"), { status: 1 });
  }
  qaConfigFile(repo, true);
  const cfg = qaConfigFile(repo, false);
  let text = "";
  if (cfg !== null) {
    try {
      text = capturedText(readFileSync(latBuf(cfg)));
    } catch {
      writeSync(2, latBuf(`ERROR: qa.require_for_ship: the project policy ${cfg} cannot be read - refusing the merge rather than reading it as not enforced\n`));
      throw Object.assign(new Error(`unreadable project policy ${cfg}`), { status: 1 });
    }
  }
  const on = (v: string): boolean =>
    !/^(false|False|FALSE|no|No|NO|off|Off|OFF)$/.test(
      v
        .replace(/[ \t\n\v\f\r]#[\s\S]*/, "")
        .replace(/["']/g, "")
        .replace(/^[ \t\n\v\f\r]+/, "")
        .replace(/[ \t\n\v\f\r]+$/, ""),
    );
  let inq = false;
  for (let l of records(`${text}\n`)) {
    if (/^qa:[ \t\n\v\f\r]*(#[\s\S]*)?$/.test(l)) {
      inq = true;
      continue;
    }
    if (/^[^ \t\n\v\f\r#]/.test(l)) inq = /^qa:[ \t\n\v\f\r]*\{/.test(l);
    if (!inq) continue;
    const block = /^[ \t\n\v\f\r]+(?:require_for_ship|"require_for_ship"|'require_for_ship')[ \t\n\v\f\r]*:/.exec(l);
    if (block && on(l.slice(block[0].length))) return true;
    for (let m; (m = /[{,][ \t\n\v\f\r]*(?:require_for_ship|"require_for_ship"|'require_for_ship')[ \t\n\v\f\r]*:/.exec(l)); ) {
      l = l.slice(m.index + m[0].length);
      if (on(l.replace(/[,}][\s\S]*/, ""))) return true;
    }
  }
  return false;
}

// ac_knowledge_scopes' twin: its stdout and stderr bytes (latin1) and its
// status. 0 with the live map's `<scope>\t<app>,<app>` rows, or with none (no
// repo name, no record, no live `- scope` line); 2 for AMBIGUOUS - a malformed
// live `- scope` line, or each repeat of a name after its first line (that
// first line reprinted every time) - with the AMBIGUOUS header and those lines
// on stderr and no row, or for a record it cannot read (awk's own `can't open`
// lines are not reproduced). records/ is minted once the name resolves
// (ac_knowledge_file's `$(ac_records_dir)`). The scan stops at `## Superseded`;
// ` | src: ` cuts the rest of a line, a CR included as awk's `.` takes one.
// The record is read as BYTES, in the C locale the gate's call sets: under a
// UTF-8 caller locale (the bash ac-qa.sh's calls) its awk aborts on a byte that
// is no UTF-8 (towc, exit 2) - named, the "read bytes" precedent.
export function knowledgeScopes(repo: string): { status: 0 | 2; out: string; err: string } {
  const none = { status: 0 as const, out: "", err: "" };
  const name = projectConfigName(repo);
  if (name === null) return none;
  const rec = latBuf(`${lat(softSubdir("records", false))}/repo-knowledge/${lat(name)}.md`);
  if (!isFile(rec)) return none;
  let text: string;
  try {
    text = readFileSync(rec, "latin1");
  } catch {
    return { status: 2, out: "", err: "" };
  }
  const first = new Map<string, string>();
  const bad: string[] = [];
  let rows = "";
  for (const line of records(text)) {
    if (line.startsWith("## Superseded")) break;
    if (!line.startsWith("- scope ")) continue;
    const subj = line.slice("- scope ".length).replace(/ \| src: [\s\S]*$/, "");
    const i = subj.indexOf(" = ");
    const scope = subj.slice(0, i);
    const apps = subj.slice(i + 3).replace(/[ \t]/g, "");
    if (i < 0 || !QA_SEGMENT.test(scope) || apps === "" || !apps.split(",").every((a) => QA_SEGMENT.test(a))) bad.push(line);
    else if (first.has(scope)) bad.push(first.get(scope)!, line);
    else {
      first.set(scope, line);
      rows += `${scope}\t${apps}\n`;
    }
  }
  if (bad.length === 0) return { status: 0, out: rows, err: "" };
  return { status: 2, out: "", err: `ac_knowledge_scopes: the scope map is AMBIGUOUS - refusing rather than picking a winner:\n${bad.map((l) => `  ${l}\n`).join("")}` };
}

// ac_yaml_has <cfg> qa.scopes, its awk's descent: a `scopes:` key PRESENT
// (children or not) one level under a column-0 `qa:`. Blank and comment lines
// are skipped, the indent is the leading SPACES / 2 floored, a key is
// `^[A-Za-z0-9_-]+:`, a shallower key ends the descent. A yaml it cannot read
// is absent, as awk's exit 2 was.
function qaScopesDeclared(cfg: string): boolean {
  let text: string;
  try {
    text = readFileSync(latBuf(cfg), "latin1");
  } catch {
    return false;
  }
  const parts = ["qa", "scopes"];
  let depth = 0;
  for (const line of records(text)) {
    if (/^[ \t\n\v\f\r]*(#|$)/.test(line)) continue;
    const spaces = /^ */.exec(line)![0].length;
    const key = /^[A-Za-z0-9_-]+(?=:)/.exec(line.slice(spaces));
    if (!key) continue;
    const ind = Math.floor(spaces / 2);
    if (ind < depth) depth = ind;
    if (ind === depth && key[0] === parts[depth]) {
      if (depth + 1 === parts.length) return true;
      depth++;
    }
  }
  return false;
}

const QA_KEYS = new Set(["schema", "outcome", "run", "task", "completed_at", "source_sha", "profile_key", "profile_sha256", "config_sha256", "cases_passed", "cases_total", "scope", "app", "qa_rule", "e2e_repo", "e2e_sha"]);

// ac_qa_attestation_parse's twin: null when the v2 marker holds for <sha>
// (and <scope>/<app>, or flat when <scope> is ""), else the bash's
// AC_QA_ATTESTATION_ERROR text, the checks in its order. Lines are what
// `IFS= read -r` gave - each cut at its first NUL, an unterminated last one
// read unless that leaves it empty - split at the first `=`. A marker that
// cannot be read has no lines (`unsupported schema`; the shell's own
// redirection line is not reproduced). Each count is canonical decimal (no
// leading zero, so at least 1) or `invalid case counts`.
export function qaAttestationParse(file: string, sha: string, scope: string, app: string, psha = "", e2e = ""): string | null {
  let size = -1;
  try {
    const st = statSync(latBuf(file));
    if (st.isFile()) size = st.size;
  } catch {}
  if (size < 0) return "not a regular file";
  if (size === 0) return "empty marker";
  let text = "";
  try {
    text = readFileSync(latBuf(file), "latin1");
  } catch {}
  const lines = text.split("\n").map((l) => l.split("\0", 1)[0]!);
  if (lines[lines.length - 1] === "") lines.pop();
  const kv = new Map<string, string>();
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq < 0) return "malformed line";
    const key = line.slice(0, eq);
    if (!QA_KEYS.has(key)) return `unknown key '${key}'`;
    if (kv.has(key)) return `duplicate key '${key}'`;
    kv.set(key, line.slice(eq + 1));
  }
  const v = (k: string): string => kv.get(k) ?? "";
  if (v("schema") !== "agentcrew.qa-attestation/v2") return "unsupported schema";
  if (v("outcome") !== "passed") return "outcome is not passed";
  if (!v("run") || !v("task") || !v("completed_at")) return "missing run/task/completed_at";
  if (v("source_sha") !== sha) return "source_sha mismatch";
  if (!v("profile_key") || !v("profile_sha256") || !v("config_sha256")) return "missing profile/config identity";
  if (!/^[1-9][0-9]*$/.test(v("cases_passed")) || !/^[1-9][0-9]*$/.test(v("cases_total"))) return "invalid case counts";
  if (v("cases_passed") !== v("cases_total")) return "case counts differ";
  if (scope !== "") {
    if (v("scope") !== scope || v("app") !== app) return "scope/app body mismatch";
  } else if (kv.has("scope") || kv.has("app")) return "flat marker carries scope/app";
  const rule = v("qa_rule");
  if (kv.has("qa_rule") && rule !== "default" && (/[^0-9]/.test(rule) || rule === "0" || rule === "")) return "invalid qa_rule";
  if ((kv.has("e2e_repo") || kv.has("e2e_sha")) && (!v("e2e_repo") || !v("e2e_sha"))) return "partial E2E identity";
  if (psha !== "" && v("profile_sha256") !== psha) return "profile hash mismatch";
  if (e2e !== "" && v("e2e_sha") !== e2e) return "E2E hash mismatch";
  return null;
}

const QA_MATRIX_JQ = '.required_profiles[]? | [.profile_key // "", .profile_sha256 // "", .e2e_sha // ""] | @tsv';

// ac_qa_gate_matrix's twin, the required-profile arm: jq SPAWNED with the
// bash's program (number spellings, several documents and errors are jq's),
// any failure or no row the EMPTY refusal; each row read as `IFS=$'\t' read
// -r` (tabFields - a missing field shifts the next into it); a key's LAST two
// segments name the `<sha>.<scope>.<app>` marker; the first unmet row refuses.
function qaGateMatrix(manifest: string, dir: string, sha: string): boolean {
  let rows = "";
  try {
    const r = spawnShellSync(["jq", "-r", QA_MATRIX_JQ, latBuf(manifest).toString("utf8")], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
    if (r.exitCode === 0) rows = capturedText(Buffer.from(r.stdout));
  } catch {}
  if (rows === "") {
    warn(latBuf(`qa.require_for_ship: the task's required-profile manifest is empty or unreadable (${manifest}) - refusing rather than merging against an undefined required set`));
    return false;
  }
  const sha12 = shellPrefix(sha, 12);
  let n = 0;
  let satisfied = "";
  for (const row of rows.split("\n")) {
    const [key, psha, e2e] = tabFields(row, 3) as [string, string, string];
    if (key === "") {
      warn(latBuf(`qa.require_for_ship: a required-profile manifest entry has no profile_key (${manifest}) - refusing rather than guessing which profile it means`));
      return false;
    }
    n++;
    const app = key.slice(key.lastIndexOf("/") + 1);
    const rest = key.includes("/") ? key.slice(0, key.lastIndexOf("/")) : key;
    const scope = rest.slice(rest.lastIndexOf("/") + 1);
    for (const [seg, what] of [
      [scope, "scope"],
      [app, "app"],
    ]) {
      if (QA_SEGMENT.test(seg!)) continue;
      warn(latBuf(`qa.require_for_ship: required profile '${key}' does not parse to <project>/<scope>/<app> (${what} segment invalid) - fix the task manifest`));
      return false;
    }
    const marker = `${dir}/${sha}.${scope}.${app}`;
    if (!isFile(latBuf(marker))) {
      warn(latBuf(`qa.require_for_ship: required profile '${key}' has no passing crew-qa attestation for ${sha12} - run crew-qa for EVERY required profile at this head before merging`));
      return false;
    }
    const err = qaAttestationParse(marker, sha, scope, app, psha, e2e);
    if (err !== null) {
      warn(latBuf(`qa.require_for_ship: the attestation for '${key}' is invalid (${err}) - re-run crew-qa for this exact profile and head`));
      return false;
    }
    satisfied += ` ${key}`;
  }
  writeSync(1, latBuf(`qa: all ${n} required profile(s) satisfied for ${sha12}:${satisfied}\n`));
  return true;
}

// ac_qa_gate_ok's twin: true = open (not enforced, or proven), false =
// refused, its WARN written; the RETIRED die is qaRequired's throw. The
// markers are <main>/.crew/qa/passed, <main> the dirname of git's common dir
// (a linked worktree's main repo), <repo> as given when git cannot say. A
// task whose family holds data/<family>/qa/manifest.json (data/ minted on
// the way) is judged by the matrix alone. Otherwise the mode is read
// TWO-SIDED, the scope map and the yaml's qa.scopes: both silent is FLAT (the
// bare <sha> marker), one alone the MODE MISMATCH, both SCOPED - every
// regular `<sha>.<scope>.<app>` in byte order (the oracle's C glob), a name
// off that grammar or a body the parse refuses skipped and named, a
// directory skipped unnamed, the proven pairs printed. The bash's `command
// -v ac_yaml_has` refusal has no twin: nothing here is sourced.
export function qaGateOk(repo: string, sha: string, task = ""): boolean {
  if (!qaRequired(repo)) return true;
  const dir = `${lat(repoRoot(repo) ?? repo)}/.crew/qa/passed`;
  if (task !== "") {
    const manifest = `${lat(softSubdir("data", true))}/${lat(familyOfId(task))}/qa/manifest.json`;
    if (isFile(latBuf(manifest))) return qaGateMatrix(manifest, dir, sha);
  }
  const map = knowledgeScopes(repo);
  const mapScoped = map.out !== "";
  if (map.status === 2) {
    warn(
      "qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify",
    );
    return false;
  }
  const cfg = qaConfigFile(repo, false);
  const yamlScoped = cfg !== null && qaScopesDeclared(cfg);
  const sha12 = shellPrefix(sha, 12);
  const bare = latBuf(`${dir}/${sha}`);
  if (!mapScoped && !yamlScoped) {
    if (isFile(bare)) {
      const err = qaAttestationParse(`${dir}/${sha}`, sha, "", "");
      if (err === null) return true;
      warn(latBuf(`qa.require_for_ship: ignored invalid flat QA attestation for ${sha12}: ${err}`));
    }
    warn(latBuf(`qa.require_for_ship: no passing crew-qa run recorded for ${sha12} - run crew-qa on this head before merging`));
    return false;
  }
  if (!mapScoped || !yamlScoped) {
    warn(
      mapScoped
        ? "qa.require_for_ship: MODE MISMATCH - the repo-knowledge record declares scopes but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge."
        : "qa.require_for_ship: MODE MISMATCH - the fleet-home config declares scopes but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge.",
    );
    return false;
  }
  let names: string[] = [];
  try {
    // Bun hands the names back as Uint8Array, whose toString ignores "latin1".
    names = readdirSync(latBuf(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  let pairs = "";
  let skipped = "";
  for (const entry of names.filter((e) => e.startsWith(`${sha}.`)).sort()) {
    const m = `${dir}/${entry}`;
    if (!isFile(latBuf(m))) continue;
    // `$(basename "$m")` lost the name's trailing LFs.
    const base = entry.replace(/\n+$/, "");
    const rest = base.slice(sha.length + 1);
    const dot = rest.indexOf(".");
    const scope = rest.slice(0, dot);
    const app = rest.slice(dot + 1);
    if (dot < 0 || app.includes(".") || !QA_SEGMENT.test(scope) || !QA_SEGMENT.test(app)) {
      skipped += ` ${base}`;
      continue;
    }
    const err = qaAttestationParse(m, sha, scope, app);
    if (err === null) pairs += ` ${scope}/${app}`;
    else skipped += ` ${base}(${err})`;
  }
  if (pairs !== "") {
    writeSync(1, latBuf(`qa: passed profiles for ${sha12}:${pairs}\n`));
    return true;
  }
  const bareSaid = isFile(bare)
    ? " A bare sha-only marker IS on disk; it names no scope+app, so it proves nothing about WHICH profile ran and cannot satisfy the gate here - re-run crew-qa naming the scope and app."
    : "";
  warn(
    latBuf(
      `qa.require_for_ship: no passing crew-qa run recorded for ${sha12} on this SCOPED project - a run must name the scope+app it proved.${bareSaid}${skipped === "" ? "" : ` Malformed markers ignored:${skipped}`}`,
    ),
  );
  return false;
}

// --- backend twins ---

type BackendFn = "window_alive" | "target" | "focus" | "capture" | "mark_wait" | "clear_wait" | "agent_blocked" | "harness_up" | "send_key" | "send_line";
type Stdio = "inherit" | "ignore" | "pipe";

// One spawned child as a shell stage: its status (shellStatus), its stdout
// when piped.
function stage(cmd: string[], stdin: "inherit" | "ignore" | Buffer, stdout: Stdio, stderr: "inherit" | "ignore"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// A here-string's jq: <text> and a LF on stdin.
function jqOver(args: string[], text: string, stdout: Stdio, stderr: "inherit" | "ignore"): { status: number; out: Buffer } {
  return stage(["jq", ...args], Buffer.from(`${text}\n`, "latin1"), stdout, stderr);
}

// A field read as bytes goes to a child's argv decoded: a byte that is not
// UTF-8 reaches it as U+FFFD where the bash passed the byte (W17, named).
const argvOf = (b: string): string => Buffer.from(b, "latin1").toString("utf8");

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
const spins = (title: string): boolean => SPINNERS.some((g) => title.startsWith(g));
// The key spellings herdr_key_name and orca_send_key_pane both case on, by
// herdr's name for each.
const keyNamed = (k: string): "enter" | "escape" | "ctrl+c" | null =>
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

type VerbIo = Parameters<typeof backendCall>[2];

function herdrVerb(fn: BackendFn, args: string[], io: VerbIo, say: (b: Buffer) => void): number {
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
function settle(stderr: "inherit" | "ignore"): void {
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
function submitVerified(id: string, top: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
  return submitVerifiedPane(argvOf(paneField(id, 1, stderr === "inherit")), top, stderr);
}

// herdr_submit_verified_pane's twin, one RAW pane (decoded): the render's last
// 15 lines read, the Enter pressed (its status ignored, even when the read
// failed), then up to seven probes a settle apart - 0 the render changed, 1 it
// never did, 2 a read failed. An empty pane is never read.
function submitVerifiedPane(p: string, top: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
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

function orcaVerb(fn: BackendFn, args: string[], io: VerbIo, say: (b: Buffer) => void): number {
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
function orcaType(h: string, text: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): void {
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
function orcaSubmitVerified(h: string, text: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): number {
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
function orcaAgentIdle(h: string, stdin: "inherit" | "ignore", stderr: "inherit" | "ignore"): boolean {
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

// --- send twins ---

// ac_bare_marker_verbs' twin (bin/ac-lib.sh keeps the bash one and its
// contract): the bare marker verbs <text> carries, one per line, deduped by
// awk's $1 in first-seen order, null for none. The verb list is the `(...)`
// group of CAPTAIN_RE by the bash's own sed; one that is empty or holds any
// byte but a-z, `|` and `-` is unparseable - none - read by that text under
// every locale (bash 3.2's case range collated under UTF-8 and let an
// uppercase verb pass: named). grep and awk are spawned under the caller's
// locale, so [[:space:]] is the class they read (NBSP under UTF-8 only).
export function bareMarkerVerbs(text: string): string | null {
  const verbs = capturedText(stage(["sed", "-n", "s/.*(\\([^)]*\\)):.*/\\1/p"], Buffer.from(`${CAPTAIN_RE}\n`), "pipe", "inherit").out);
  if (verbs === "" || /[^a-z|-]/.test(verbs)) return null;
  const hits = stage(["grep", "-oE", `(${verbs}):([[:space:]]|$)`], Buffer.from(`${text}\n`), "pipe", "inherit");
  const tokens = capturedText(stage(["awk", "!seen[$1]++ { print $1 }"], hits.out, "pipe", "inherit").out);
  return tokens === "" ? null : tokens;
}

// ac_claude_last_typed_turn's jq program, byte for byte (tests/ts/send.test.ts
// lifts it out of bin/ac-lib.sh, whose function stays live for ac-spawn).
const LAST_TYPED_TURN = `
    [.[] | select(.type == "user" and .promptSource == "typed"
                  and .origin.kind == "human"
                  and (.message.content | type) == "string")]
    | last | .message.content // empty
  `;

// ac_claude_transcript_path's twin: the one `<root>/*/<sid>.jsonl` that
// exists, <root> AC_CLAUDE_TRANSCRIPT_ROOT, else <CLAUDE_CONFIG_DIR, else
// HOME/.claude>/projects, its trailing LFs cut as the bash's `$(...)` cut
// them; null for none, two or more, or HOME unset where it was needed (the
// bash's `set -u` ended the reading there). <sid> is bytes (latin1), and so
// is the answer.
export function claudeTranscriptPath(sid: string): string | null {
  const home = process.env.HOME;
  const cfg = process.env.CLAUDE_CONFIG_DIR || (home === undefined ? null : `${home}/.claude`);
  const root = process.env.AC_CLAUDE_TRANSCRIPT_ROOT || (cfg === null ? null : `${cfg}/projects`);
  if (root === null) return null;
  const r = lat(root).replace(/\n+$/, "");
  let names: Uint8Array[] = [];
  try {
    names = readdirSync(Buffer.from(r, "latin1"), { encoding: "buffer" });
  } catch {}
  const hits = names
    .map((n) => Buffer.from(n).toString("latin1"))
    .filter((n) => !n.startsWith(".") && existsSync(Buffer.from(`${r}/${n}/${sid}.jsonl`, "latin1")));
  return hits.length === 1 ? `${r}/${hits[0]}/${sid}.jsonl` : null;
}

// ac_claude_last_typed_turn's twin: `tail -n 200 <file> | jq -rs <program>`,
// both spawned, their stderr dropped; null when either fails (pipefail) or
// the answer reads empty, else the turn as `$(...)` read it (latin1).
function claudeLastTypedTurn(path: string): string | null {
  const tail = stage(["tail", "-n", "200", argvOf(path)], "ignore", "pipe", "ignore");
  const turn = stage(["jq", "-rs", LAST_TYPED_TURN], tail.out, "pipe", "ignore");
  if (tail.status !== 0 || turn.status !== 0) return null;
  const out = capturedText(turn.out);
  return out === "" ? null : out;
}

// ac_arrival_wait's twin (ac-lib.sh's claude transcript arrival check; the
// bash stays live for ac-spawn): did <text>, its trailing LFs cut as the
// transcript reader cuts the arrived turn's, ARRIVE as the session's last
// typed human turn? Up to seven reads a settle apart (PATH's sleep, as the
// bash ran it), returning at the first match: 0 CONFIRMED; 1 REFUTED - some
// turn was read and none matched, `last` the last one read (the bash's
// AC_ARRIVAL_LAST); 2 UNOBSERVABLE - no <sid> (bytes, latin1), no single
// transcript, or no turn read at all.
export function arrivalWait(sid: string, text: string): { status: number; last: string } {
  const expected = lat(text).replace(/\n+$/, "");
  if (sid === "") return { status: 2, last: "" };
  const path = claudeTranscriptPath(sid);
  if (path === null) return { status: 2, last: "" };
  let last = "";
  for (let reads = 1; ; reads++) {
    const cur = claudeLastTypedTurn(path);
    if (cur !== null) {
      last = cur;
      if (last === expected) return { status: 0, last: "" };
    }
    if (reads >= 7) break;
    settle("inherit");
  }
  return { status: last === "" ? 2 : 1, last };
}

// --- domain twins ---
import { basename } from "node:path";
import { readlinkSync } from "node:fs";

// src/domain.ts derives a package path from `$(ac_home)` as the bash did:
// the refusal printed and "" when the home cannot be named.
export { softHome };

// ac_domain_registry's twin: `<records>/crewdomains.md`, records/ minted;
// homeless, the refusal printed and `/crewdomains.md`.
export function domainRegistry(): string {
  return `${softSubdir("records", true)}/crewdomains.md`;
}

// ac_domain_parse's program, byte for byte: tests/ts/domain.test.ts lifts it
// out of bin/ac-lib.sh, whose function stays live for ac-spawn and the
// dashboard's pin. Its comments quote words in backticks, which a template
// literal cannot hold raw.
const BT = "`";
const DOMAIN_PARSE_AWK = String.raw`
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function bad(reason) { printf "INVALID\t%s\t\t\t%s\n", $0, reason }
    {
      if (substr($0, 1, 2) != "- ") next
      rest = substr($0, 3)
      if (rest !~ / \(added [^)]*\)$/) { bad("missing \"(added ...)\""); next }
      sub(/ \(added [^)]*\)$/, "", rest)

      # Drop the ONE legitimate keyed field, then any keyed token left over is a
      # field this grammar does not have. Checked BEFORE the scope split so a
      # ${BT}home:${BT} line is refused by name rather than by a downstream symptom.
      probe = rest
      sub(/ - scope:/, "", probe)
      if (match(probe, / - [a-zA-Z][a-zA-Z0-9_-]*:/)) {
        bad("unknown field \"" substr(probe, RSTART + 3, RLENGTH - 3) "\""); next
      }

      p = index(rest, " - scope:")           # 9 chars
      if (p == 0) { bad("missing \"scope:\" field"); next }
      head = substr(rest, 1, p - 1)
      scope = trim(substr(rest, p + 9))

      q = index(head, " - ")                 # id, then the free-text charter
      if (q > 0) { id = trim(substr(head, 1, q - 1)); charter = trim(substr(head, q + 3)) }
      else { id = trim(head); charter = "" }
      if (charter == "") { bad("missing charter field"); next }

      # [a-z0-9-], TIGHTER than the loose read-path charset the deputy parser
      # uses, and equal to what ${BT}new${BT} mints - because a crewdomain id is
      # CONCATENATED into a package path. A parser calling ${BT}Payments${BT} VALID
      # would hand an id to a path verb that refuses it, and ${BT}list${BT} (which may
      # never exit non-zero) would then die on the digest. One charset, both
      # ends. NOTE: no apostrophes in this block - the awk program is inside a
      # shell single-quoted string, and one would close it.
      if (id !~ /^[a-z0-9-]+$/) { bad("bad id charset"); next }
      if (id in seen) { bad("duplicate id"); next }
      seen[id] = 1
      printf "VALID\t%s\t%s\t%s\t\n", id, charter, scope
    }
  `;

// ac_domain_parse's twin as the argv it ran - `awk <program> <file>` under
// the caller's locale, so a byte that is not UTF-8 aborts it under a UTF-8
// one (towc, exit 2) as it did the bash - for a caller to run and read.
// <file> defaults to domainRegistry(); null when it is no regular file, where
// the bash returned 0 with no record.
export function domainParse(file = ""): string[] | null {
  if (file === "") file = domainRegistry();
  return isFile(file) ? ["awk", DOMAIN_PARSE_AWK, file] : null;
}

// ac_domain_name_ok's twin: `''`, `/`, `.` and `..` refused, then the C
// locale's [a-z0-9-] - so the charset is the text's under any locale.
export function domainNameOk(name: string): boolean {
  return /^[a-z0-9-]+$/.test(name);
}

// ac_backlog_id_ok's twin, the same rule for a backlog row id.
export function backlogIdOk(id: string): boolean {
  return /^[a-z0-9-]+$/.test(id);
}

// `cd -P <p> && pwd -P`: entered as the kernel resolves it, links and `..`
// physically, never the lexical spelling physicalDir tries first.
function cdPhysical(p: string): string | null {
  const here = process.cwd();
  try {
    process.chdir(p);
    return namedCwd();
  } catch {
    return null;
  } finally {
    process.chdir(here);
  }
}

// `$(dirname ...)`, `$(basename ...)` and `$(readlink ...)` lost a trailing LF.
const noLF = (s: string): string => s.replace(/\n+$/, "");

// ac_domain_view_entry's twin: one projects/ view entry of <dom> classified as
// the capture read it - `ok`, `not-symlink`, `dangling`, `outside <target>`
// or `mismatch <target>`. The link chain is followed one hop at a time (its
// target resolved against the link's own physical dir) and stops the moment a
// hop lands in the physical <home>/projects - a fleet clone that is itself a
// symlink is trusted there - or after 16 hops (dangling); the landing point
// must sit under that dir and equal <clones>/<entry> as a literal string.
// Homeless, the refusal printed and the entry read under `/crewdomains`.
export function domainViewEntry(dom: string, entry: string): string {
  const home = softHome(true);
  const link = `${home}/crewdomains/${dom}/projects/${entry}`;
  const isLink = (p: string): boolean => {
    try {
      return lstatSync(p).isSymbolicLink();
    } catch {
      return false;
    }
  };
  if (!isLink(link)) return "not-symlink";
  if (!existsSync(link)) return "dangling";
  const clones = cdPhysical(`${home}/projects`) ?? `${home}/projects`;
  let t = link;
  let hops = 0;
  let landed = false;
  while (isLink(t) && hops < 16) {
    let d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    let rl: string;
    try {
      rl = noLF(readlinkSync(t));
    } catch {
      return "dangling";
    }
    t = rl.startsWith("/") ? rl : `${d}/${rl}`;
    hops++;
    d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    if (d === clones) {
      t = `${d}/${noLF(basename(t))}`;
      landed = true;
      break;
    }
  }
  if (!landed) {
    if (hops >= 16) return "dangling";
    const d = cdPhysical(noLF(dirname(t)));
    if (d === null) return "dangling";
    t = `${d}/${noLF(basename(t))}`;
  }
  if (!`${t}/`.startsWith(`${clones}/`)) return noLF(`outside ${t}`);
  if (t !== `${clones}/${entry}`) return noLF(`mismatch ${t}`);
  return "ok";
}

// ac_domain_qa_repo's twin: the main repo root of the project <dom>'s
// package member `qa-repo` names, null for none. The name is the member's
// first line with every [:space:] deleted by a spawned `tr` - the caller's
// locale decides what a space is, and under UTF-8 tr cuts at a byte that is
// not UTF-8 with its own line - then `[ -e <pkg>/projects/<name> ]` and
// projectDir (the physical path). Homeless, the refusal (stderr allowing) and
// null. <stderr> "ignore" is the caller that ran it under 2>/dev/null.
export function domainQaRepo(dom: string, stderr: "inherit" | "ignore" = "inherit"): string | null {
  if (!domainNameOk(dom)) return null;
  const home = softHome(stderr === "inherit");
  if (home === "") return null;
  const pkg = `${home}/crewdomains/${dom}`;
  let head = Buffer.alloc(0);
  try {
    const b = readFileSync(`${pkg}/qa-repo`);
    const lf = b.indexOf(10);
    head = lf < 0 ? b : b.subarray(0, lf + 1);
  } catch {}
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["tr", "-d", "[:space:]"], { stdin: head, stdout: "pipe", stderr });
  } catch {}
  const name = r === null ? "" : capturedText(Buffer.from(r.stdout));
  if (name === "") return null;
  const path = `${pkg}/projects/${Buffer.from(name, "latin1").toString("utf8")}`;
  if (!existsSync(path)) return null;
  return projectDir(path);
}

// ac_domain_tally's twin over the ledger's grammar in-process (records() +
// acDoneline(), the AC_DONELINE_AWK reading under LC_ALL=C):
// `<queued> <in flight> <done>` for the rows whose domain - their own token,
// else their epic row's - is <name> (every domain for ""), the section read
// from the last `## In flight` / `## Queued` / `## Done` PREFIX (any other
// `## ` line ends it), a [failed]/[abandoned] Done row not counted; `0 0 0`
// with no ledger. A ledger it cannot read is null, with the parser's own
// refusal where the original printed awk's `can't open file`.
export function domainTally(name: string): string | null {
  const f = `${softSubdir("records", true)}/backlog.md`;
  if (!isFile(f)) return "0 0 0";
  let text: string;
  try {
    text = readFileSync(f, "latin1");
  } catch {
    writeSync(2, Buffer.from(`ERROR: cannot read ${lat(f)}\n`, "latin1"));
    return null;
  }
  const recs = records(text);
  const dom = new Map<string, string>();
  for (const r of recs) {
    if (!r.startsWith("- [")) continue;
    const o = acDoneline(r);
    if (o.domain !== "") dom.set(o.id, o.domain);
  }
  const n: Record<string, number> = { q: 0, i: 0, d: 0 };
  let sec = "";
  for (const r of recs) {
    if (r.startsWith("## ")) sec = "";
    if (r.startsWith("## In flight")) sec = "i";
    else if (r.startsWith("## Queued")) sec = "q";
    else if (r.startsWith("## Done")) sec = "d";
    else if (r.startsWith("- [") && sec !== "") {
      const o = acDoneline(r);
      const d = o.domain === "" && o.epic !== "" ? dom.get(o.epic) ?? "" : o.domain;
      if (d === "" || (name !== "" && d !== name)) continue;
      if (sec === "d" && (o.terminal === "failed" || o.terminal === "abandoned")) continue;
      n[sec]!++;
    }
  }
  return `${n.q} ${n.i} ${n.d}`;
}

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
// ignores overridden, an `H  <path>` per file whose assume-unchanged or
// skip-worktree bit hides an edit, a deletion or a mode/type change from it,
// an `O  <op>` per operation git left in progress - and status git status's.
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
  const st = g(["status", "--porcelain", "--ignore-submodules=none"]);
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

// ac_task_stamps' twin: every per-id watcher stamp in <sd>, the one reap list
// (ac-watch and ac-done write them).
const TASK_STAMPS = ["hash", "change", "seen", "seen-hash", "stale", "gone", "ask", "unobservable", "report-hash", "superseded", "busy", "busy-stalled", "ended"];
export function taskStamps(sd: string, id: string): string[] {
  return TASK_STAMPS.map((b) => `${sd}/.${b}-${id}`);
}

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

// ac_port_slot_release's twin: <wt>'s row dropped from state/port-slots.tsv
// under the registry's lock (10 PATH `sleep 1` waits), never a failure - no
// home, no registry or a lock not taken (W20) leave it, silently. The rows are
// awk's `$2 != w` (-v escapes and all), spawned; its output goes to an
// exclusive <reg>.tmp.<pid> given the registry's mode (the bash's temp left
// it umask's) and is renamed over it by a spawned mv. An awk that fails, or a
// temp that cannot take all its bytes, leaves that temp and the registry as
// they were, as the bash's `awk >tmp && mv` did; so does a lock whose pid
// cannot be written (the bash's ac_lock_acquire answered 1 there).
export function portSlotRelease(wt: string): void {
  const sd = softSubdir("state", false);
  if (sd === "") return;
  const reg = `${sd}/port-slots.tsv`;
  if (!isFile(reg)) return;
  const lock = `${reg}.lock`;
  let held = false;
  try {
    held = lockAcquire(lock, 10, sleepOne);
  } catch {}
  if (!held) return;
  try {
    let t: { path: string; fd: number };
    try {
      t = exclusiveTemp(`${reg}.tmp`);
    } catch {
      return;
    }
    const r = stage(["awk", "-F\\t", "-v", `w=${wt}`, "$2 != w", reg], "inherit", "pipe", "inherit");
    let whole = true;
    try {
      writeAll(t.fd, r.out);
    } catch {
      whole = false;
    } finally {
      closeSync(t.fd);
    }
    if (r.status !== 0 || !whole) return;
    try {
      chmodSync(t.path, statSync(reg).mode & 0o7777);
    } catch {}
    stage(["mv", t.path, reg], "inherit", "inherit", "inherit");
  } finally {
    lockRelease(lock);
  }
}

// `awk <prog> <file>` as the gate's tests ran it - under the caller's locale,
// or LC_ALL=C for `c` - its own stderr the caller's: true on exit 0.
function awkFinds(prog: string, vars: [string, string][], file: string, c = false): boolean {
  const awk = ["awk", ...vars.flatMap(([k, v]) => ["-v", `${k}=${v}`]), prog, file];
  return stage(c ? ["/usr/bin/env", "LC_ALL=C", ...awk] : awk, "inherit", "ignore", "inherit").status === 0;
}

// ac_solo_landing_check's twin, the kind=self knowledge-loop gate: the one
// line `knowledge loop: lessons=<l> repo-knowledge=<f> done-row=<d>` (or
// `landed-receipt=<d>` for a <scope>) appended to <id>'s status record, its
// failure ignored, and printed on stdout, then `missing - the solo contract
// owes these at landing:` and the command for each missing write; true when
// none is missing, and for an empty <id> with nothing done. lessons: waived,
// or yes when records/learnings.md before `## Distilled` holds a `### `
// heading containing `(solo <id>)` or any line containing `(by: <id>,`;
// repo-knowledge: waived, or yes when <repo> is a directory git names a config
// name for and its records/repo-knowledge/<name>.md before `## Superseded`
// holds a `- ` line ending `| by: <id>`; the third: a scoped slice's room
// entry `- [` holding `> LANDED: <id> ` or `> UNLANDABLE: <id> `, else a line
// under `## Done` starting `- [x] <id> `. Each test is the original's awk,
// spawned (the last two under LC_ALL=C, as there), so an unreadable record
// prints awk's own line and reads as missing. The hints name the bin/ of
// STARTED_BIN, `date -u +%Y-%m-%d` (spawned) and the physical home. Every
// argument is text (UTF-8). <before>, given, runs just ahead of the record
// with the verdict, so a caller's own lines land before it - and only when
// they should.
export function soloLandingCheck(id: string, repo: string, noLesson: string, noFact: string, scope: string, before?: (pass: boolean) => void): boolean {
  if (id === "") return true;
  const recs = softSubdir("records", false);
  const led = `${recs}/learnings.md`;
  let lessons = "none";
  if (noLesson !== "") lessons = "waived";
  else if (
    isFile(led) &&
    awkFinds(
      "\n      /^## Distilled/ { exit }\n      /^### / && index($0, tag) { found = 1; exit }\n      index($0, by) { found = 1; exit }\n      END { exit(found ? 0 : 1) }",
      [["tag", `(solo ${id})`], ["by", `(by: ${id},`]],
      led,
    )
  )
    lessons = "yes";
  let facts = "none";
  if (noFact !== "") facts = "waived";
  else if (repo !== "" && isDir(repo)) {
    const name = projectConfigName(repo);
    const rec = name === null ? "" : `${softSubdir("records", false)}/repo-knowledge/${name}.md`;
    if (
      rec !== "" &&
      isFile(rec) &&
      awkFinds(
        "\n      /^## Superseded/ { exit }\n      /^- / && substr($0, length($0) - length(suffix) + 1) == suffix { found = 1; exit }\n      END { exit(found ? 0 : 1) }",
        [["suffix", `| by: ${id}`]],
        rec,
      )
    )
      facts = "yes";
  }
  let done = "none";
  let line: string;
  let bl = "";
  if (scope !== "") {
    const room = roomFile(scope);
    if (
      room !== "" &&
      isFile(room) &&
      awkFinds(
        "\n        /^- \\[/ && (index($0, landed) || index($0, unland)) { found = 1; exit }\n        END { exit(found ? 0 : 1) }",
        [["landed", `> LANDED: ${id} `], ["unland", `> UNLANDABLE: ${id} `]],
        room,
        true,
      )
    )
      done = "yes";
    line = `knowledge loop: lessons=${lessons} repo-knowledge=${facts} landed-receipt=${done}`;
  } else {
    bl = `${softSubdir("records", false)}/backlog.md`;
    if (
      isFile(bl) &&
      awkFinds(
        "\n        /^## Done/ { in_done = 1; next }\n        /^## / { in_done = 0 }\n        in_done && index($0, row) == 1 { found = 1; exit }\n        END { exit(found ? 0 : 1) }",
        [["row", `- [x] ${id} `]],
        bl,
        true,
      )
    )
      done = "yes";
    line = `knowledge loop: lessons=${lessons} repo-knowledge=${facts} done-row=${done}`;
  }
  const root = STARTED_BIN.slice(0, -"/bin".length);
  let hint = "";
  if (lessons === "none") {
    const day = capturedText(stage(["date", "-u", "+%Y-%m-%d"], "inherit", "pipe", "inherit").out);
    hint += `\n  lesson: ${root}/bin/ac-learn.sh note '### ${day} (solo ${id})' '- <one method lesson>'   (or --no-lesson '<why nothing new>')`;
  }
  if (facts === "none") hint += `\n  repo fact: ${root}/bin/ac-know.sh add --home ${softHome(true)} --repo ${repo || "<repo>"} --family ${id} --src-file <path>:<line> --fact '<verified fact>'   (or --no-fact '<why none verified>')`;
  if (done !== "yes") {
    if (scope !== "")
      hint += `\n  landed receipt: ${root}/bin/ac-room.sh post ${scope} ${scope}-chief 'LANDED: ${id} - <outcome>'   (the crewchief moves the backlog row at your hand-back)\n  ...or, when the slice CANNOT land: ${root}/bin/ac-room.sh post ${scope} ${scope}-chief 'UNLANDABLE: ${id} - <why>; crewchief to land'   (NEVER rebase to force it: a scoped actor is withheld --no-ff on purpose, and a rebase changes the sha a review receipt binds by. The slice STAYS IN FLIGHT until the crewchief lands crew/${id} --no-ff; this teardown keeps refusing 'unlanded work' until then, and passes on this receipt afterwards)`;
    else hint += `\n  done row: append '- [x] ${id} - <outcome>' under ## Done in ${bl}`;
  }
  before?.(hint === "");
  statusAppend(id, lat(line));
  writeSync(1, `${line}\n`);
  if (hint !== "") writeSync(1, `missing - the solo contract owes these at landing:${hint}\n`);
  return hint === "";
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

const isLink = (p: string): boolean => {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
};

// ac_maintenance_path_plain's twin: no EXISTING component of <rel> under the
// physical <root> is a link; an empty component fails.
function maintenancePathPlain(root: string, rel: string): boolean {
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

const curateMeta = (): string => `${softSubdir("state", true)}/.curate.meta`;

function metaGetSoft(file: string, key: string): string {
  try {
    return metaGet(file, key);
  } catch {
    return "";
  }
}

// ac_meta_set's failure is the bash caller's ignored status: its warning or
// mv's own line is already on stderr, and the sequence goes on.
function metaSetSoft(file: string, key: string, value: string): void {
  try {
    metaSet(file, key, value);
  } catch {}
}

// ac_curate_generation's twin: the meta's generation, "0" unless digits.
export function curateGeneration(): string {
  const g = metaGetSoft(curateMeta(), "generation");
  return /^[0-9]+$/.test(g) ? g : "0";
}

// ac_curate_due's twin: [runs_since, curate-every], "0" and "5" unless digits.
export function curateDue(): [string, string] {
  const cur = metaGetSoft(curateMeta(), "runs_since");
  const every = configReadSoft("curate-every", "5");
  return [/^[0-9]+$/.test(cur) ? cur : "0", /^[0-9]+$/.test(every) ? every : "5"];
}

// ac_curate_reset's twin, under state/.curate-cadence.lock (10 PATH `sleep 1`
// waits): false, warned, when the lock is not taken; false when <expected>
// names an older generation; else generation+1 (`$((current + 1))`, so a
// leading 0 reads octal and an 8 or 9 behind it THROWS EARITH with the lock
// still held, where the shell's arithmetic error ended the script), runs_since
// 0 and last_run stamped, each write's own failure ignored as the bash's was.
export function curateReset(expected = ""): boolean {
  const f = curateMeta();
  const lock = `${softSubdir("state", true)}/.curate-cadence.lock`;
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`curate reset: cadence lock ${lock} could not be acquired within 10s - the learning-run counter was NOT reset and its generation did NOT advance, so a due Curate pass stays due. This is a lock failure, not a newer cadence generation.`);
    return false;
  }
  const current = curateGeneration();
  if (expected !== "" && expected !== current) {
    lockRelease(lock);
    return false;
  }
  metaSetSoft(f, "generation", String(BigInt.asIntN(64, arithValue(current) + 1n)));
  metaSetSoft(f, "runs_since", "0");
  metaSetSoft(f, "last_run", nowRaw());
  lockRelease(lock);
  return true;
}

// ac_maintenance_gate_failure_reason's twin, keyed on the gate's exit only.
export function maintenanceGateFailureReason(rc: number | string): string {
  switch (String(rc)) {
    case "4":
      return "The maintenance gate is disabled (config/gate-agent=off).";
    case "3":
      return "The maintenance gate ran but produced no usable decision (an engine failure, an invalid response, a timeout, or a declared environment-error).";
    default:
      return `The maintenance gate rejected its own invocation before it could run (usage or input error, exit ${rc}).`;
  }
}

// ac_maintenance_incomplete_other's twin: some OTHER transaction dir under
// <root> (byte order) holds a journal that is neither complete nor abandoned;
// an unreadable journal is ac_meta_get's warning and reads unsettled.
function maintenanceIncompleteOther(root: string, current: string): boolean {
  if (!isDir(root)) return false;
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {}
  for (const n of names.filter((x) => !x.startsWith(".")).sort()) {
    const dir = `${root}/${n}`;
    if (!isDir(dir) || dir === current) continue;
    if (!isFile(`${dir}/journal`)) continue;
    const s = metaGetSoft(`${dir}/journal`, "status");
    if (s !== "complete" && s !== "abandoned") return true;
  }
  return false;
}

// _ac_maintenance_hold's twin: the journal keeps the claim and says how much
// landed, then the one warning naming the verbs that settle it.
function maintenanceHold(journal: string, txn: string, committed: number, total: string, why: string): void {
  const txid = basename(txn);
  metaSetSoft(journal, "held_committed", String(committed));
  metaSetSoft(journal, "held_reason", Buffer.from(why, "utf8").toString("latin1"));
  warn(`maintenance transaction ${txid} is HELD (${why}): ${committed} of its ${total} action(s) are already committed to disk and are NOT rolled back. It stays claimed, so every other Learning/Curate transaction refuses until it is settled. Fix the cause and replay it (already-applied actions are skipped by hash), or drop it and keep the record: bin/ac-learn.sh maintenance resume ${txid} | bin/ac-learn.sh maintenance abandon ${txid}`);
}

const shaSoft = (f: string): string => {
  try {
    return sha256File(f);
  } catch {
    return "";
  }
};

// ac_maintenance_apply's twin - the fleet-wide writer Learning and Curate
// call, beside the bash one the frozen oracles keep, so the two must leave
// the same claim, journal (key order included), backup and file bytes: a
// journal either side writes, the other resumes. The plan is validated (maintenancePlanValidate), the claim taken
// under state/.maintenance.lock (30 PATH `sleep 1` waits) and refused for a
// different recorded plan or another unsettled transaction; the journal
// records plan_sha256, plan, run, actions_total and status=applying before the
// first write, then the backup (recordsBackup <mode>, once per transaction).
// Each action is skipped when its target already holds new_sha256, applied
// when it holds old_sha256 (cp to <target>.maintenance.<pid>.<idx>, rehashed,
// mv over it - all spawned, so a link planted at the temp is written through
// as the bash's was), and a move-skill then removes its live source and every
// directory it empties below skills/. Every failure past the claim HOLDS the
// transaction with the bash's reason text. False wherever the bash returned 1.
export function maintenanceApply(plan: string, run: string): boolean {
  if (!maintenancePlanValidate(plan, run)) return false;
  const home = softHome(true);
  const root = `${softSubdir("state", true)}/.maintenance-transactions`;
  mkdirP(root);
  const jqr = (prog: string): string => capturedText(stage(["jq", "-r", prog, plan], "inherit", "pipe", "inherit").out);
  const runId = jqr(".run_id");
  const subject = jqr(".subject");
  const mode = jqr(".mode");
  const txn = `${root}/${runId}-${subject}`;
  const journal = `${txn}/journal`;
  const lock = `${softSubdir("state", true)}/.maintenance.lock`;
  const planSha = shaSoft(plan);
  if (planSha === "") return false;

  if (isFile(journal) && metaGetSoft(journal, "status") === "complete") {
    const recorded = metaGetSoft(journal, "plan_sha256");
    if (recorded === planSha) return true;
    warn(`maintenance apply: transaction ${runId}-${subject} already completed a different plan (plan_sha256 ${recorded}, this one ${planSha}), so this plan was not applied. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.`);
    return false;
  }
  if (!lockAcquire(lock, 30, sleepOne)) {
    warn(`maintenance apply: writer lock ${lock} could not be acquired within 30s - another Learning/Curate transaction holds it, so ${runId}-${subject} was neither claimed nor written. This is a busy lock, not a stale receipt or a refused plan.`);
    return false;
  }
  if (!maintenancePlanValidate(plan, run)) {
    lockRelease(lock);
    return false;
  }
  mkdirP(txn);
  const recorded = metaGetSoft(journal, "plan_sha256");
  if (recorded !== "" && recorded !== planSha) {
    warn(`maintenance apply: transaction ${runId}-${subject} already recorded a different plan (plan_sha256 ${recorded}, this one ${planSha}), so this plan was neither claimed nor written. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.`);
    lockRelease(lock);
    return false;
  }
  if (maintenanceIncompleteOther(root, txn)) {
    warn(`maintenance apply: another Learning/Curate transaction is still unsettled, so ${runId}-${subject} was neither claimed nor written. This is another transaction's claim, not a stale receipt or a refused plan - bin/ac-learn.sh maintenance status names it, and resume or abandon settles it.`);
    lockRelease(lock);
    return false;
  }

  const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
  const planAbs = `${physicalDir(dirname(plan)) ?? ""}/${basename(plan)}`;
  const runAbs = physicalDir(run) ?? "";
  const total = jqr(".actions | length");
  metaSetSoft(journal, "plan_sha256", planSha);
  metaSetSoft(journal, "plan", lat(planAbs));
  metaSetSoft(journal, "run", lat(runAbs));
  metaSetSoft(journal, "actions_total", total);
  metaSetSoft(journal, "status", "applying");
  const held = (idx: number, why: string): false => {
    maintenanceHold(journal, txn, idx, total, why);
    lockRelease(lock);
    return false;
  };
  let backup = metaGetSoft(journal, "backup");
  if (backup === "") {
    const b = recordsBackup(mode);
    if (b === null) return held(0, "the pre-mutation backup could not be taken");
    backup = b;
    metaSetSoft(journal, "backup", backup);
  } else if (!isFile(Buffer.from(backup, "latin1"))) {
    return held(0, "the recorded pre-mutation backup is missing");
  }

  const run1 = (cmd: string[], stderr: "inherit" | "ignore" = "inherit"): number => stage(cmd, "inherit", "inherit", stderr).status;
  const rows = stage(["jq", "-r", ".actions[] | [.op,.target,.old_sha256,.new_sha256,.staged] | @tsv", plan], "inherit", "pipe", "inherit").out.toString("latin1").split("\n").slice(0, -1);
  let idx = 0;
  for (const row of rows) {
    const [op, target, oldSha, newSha, staged] = tabFields(row.split("\0", 1)[0]!, 5) as [string, string, string, string, string];
    const targetAbs = `${home}/${target}`;
    const stagedAbs = `${run}/${staged}`;
    let actual: string;
    if (isFile(targetAbs) && !isLink(targetAbs)) {
      actual = shaSoft(targetAbs);
      if (actual === "") return held(idx, `target ${target} could not be hashed`);
    } else if (!existsSync(targetAbs)) {
      actual = "-";
    } else {
      return held(idx, `target ${target} is not a plain file`);
    }
    if (actual !== newSha) {
      if (actual !== oldSha) return held(idx, `target ${target} no longer matches the state the plan was staged against`);
      if (run1(["mkdir", "-p", dirname(targetAbs)]) !== 0) return held(idx, `the directory for ${target} could not be created`);
      if (!maintenancePathPlain(home, target)) return held(idx, `a path component of ${target} is a symlink`);
      const tmp = `${targetAbs}.maintenance.${process.pid}.${idx}`;
      if (run1(["cp", stagedAbs, tmp]) !== 0) return held(idx, `the staged bytes for ${target} could not be copied`);
      if (shaSoft(tmp) !== newSha) {
        run1(["rm", "-f", tmp]);
        return held(idx, `the copied bytes for ${target} do not match the planned hash`);
      }
      if (run1(["mv", tmp, targetAbs]) !== 0) {
        run1(["rm", "-f", tmp]);
        return held(idx, `${target} could not be replaced atomically`);
      }
    }
    if (op === "move-skill") {
      const prefix = `skills/${SKILLS_ARCHIVE}/`;
      if (!target.startsWith(prefix) || !target.slice(prefix.length).includes("/")) return held(idx, `the live source for ${target} could not be inferred`);
      const source = `skills/${target.slice(prefix.length)}`;
      const sourceAbs = `${home}/${source}`;
      if (isFile(sourceAbs) && !isLink(sourceAbs)) {
        if (shaSoft(sourceAbs) !== newSha) return held(idx, `live source ${source} does not match the archived bytes`);
        if (run1(["rm", sourceAbs]) !== 0) return held(idx, `live source ${source} could not be removed`);
      } else if (existsSync(sourceAbs) || isLink(sourceAbs)) {
        return held(idx, `live source ${source} is not a plain file`);
      }
      // Only directories the move emptied go; a failed rmdir means another
      // file remains there and is kept.
      for (let dir = dirname(sourceAbs); dir !== `${home}/skills`; dir = dirname(dir)) {
        if (run1(["rmdir", dir], "ignore") !== 0) break;
      }
    }
    metaSetSoft(journal, `action_${idx}`, "complete");
    idx++;
  }
  metaSetSoft(journal, "status", "complete");
  lockRelease(lock);
  return true;
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

type SpawnIo = { stdin?: "inherit" | "ignore"; stderr: "inherit" | "ignore" };
type Ended = { status: number; exited: boolean };

const SEED_STAMPS = ".claude/.ac-seed";
const SEED_FALLBACK = ".claude/CREWMATE.md";

// ac_die inside a driver the caller ran bare: the line, then the shell gone.
function died(msg: string | Uint8Array): Ended {
  writeSync(2, prefixed("ERROR: ", msg));
  return { status: 1, exited: true };
}

// ac_harness_instruction_file's twin as `$(...)` ran it: the file the harness
// loads, relative to its worktree ("" reads claude); a harness neither
// built-in nor given a config/launch-<h> template is the ERROR line and null -
// the die ended only the substitution.
export function harnessInstructionFile(h: string): string | null {
  const name = h || "claude";
  if (["codex", "opencode", "pi", "cursor"].includes(name)) return "AGENTS.md";
  if (name === "claude" || isFile(`${softHome(true)}/config/launch-${name}`)) return ".claude/CLAUDE.md";
  writeSync(2, prefixed("ERROR: ", `unknown harness '${name}': no registry entry (bin/ac-harness.sh) and no config/launch-${name} template - refusing to guess which instruction file it loads`));
  return null;
}

// ac_harness_startup_key's twin.
export function harnessStartupKey(h: string): string {
  return h === "codex" ? "Enter" : "";
}

// ac_record_launch_opts' twin: only what the harness's built-in launch applies
// is written - model, then effort, one metaSet each (values decoded, written as
// their UTF-8 bytes); <applied> "" reads <effort>. A refused write throws as
// metaSet does: the errexit caller ended there.
export function recordLaunchOpts(meta: string, harness: string, model: string, effort: string, applied = ""): void {
  const set = (k: string, v: string): void => {
    if (v !== "") metaSet(meta, k, lat(v));
  };
  const eff = applied || effort;
  if (harness === "claude") {
    set("model", model);
    set("effort", effort);
  } else if (harness === "codex" || harness === "pi") {
    set("model", model);
    set("effort", eff);
  } else if (harness === "opencode" || harness === "cursor") set("model", model);
}

// ac_compact_pct_env's twin as `$(...)` ran it: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=<p> `
// for a config/compact-pct of 1-100 as `[ -ge ]` reads it (007 is 7), "" when
// unset; any other value is the reason line on stderr - no WARN prefix - and
// "". The digit grammar is read per the text (bash 3.2's [!0-9] collated
// under UTF-8 - named); past int64 `[`'s own line is not reproduced.
export function compactPctEnv(): string {
  const p = configReadSoft("compact-pct", "");
  if (p === "") return "";
  const n = /^[0-9]+$/.test(p) ? testInt(p) : null;
  if (n !== null && n >= 1n && n <= 100n) return `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=${p} `;
  writeSync(2, `config/compact-pct: ${p} is not 1-100 - claude keeps its default threshold\n`);
  return "";
}

// ac_claude_config_env's twin, bytes (latin1) out: `CLAUDE_CONFIG_DIR=<%q> `
// when the variable is set non-empty, then always
// `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 `.
export function claudeConfigEnv(): string {
  const d = process.env.CLAUDE_CONFIG_DIR;
  return `${d ? `CLAUDE_CONFIG_DIR=${shellQuote(lat(d))} ` : ""}CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 `;
}

// ac_build_launch's twin as `$(...)` ran it: the built-in launch command for
// <h>, its parts concatenated unquoted as given; a resume id wins over a
// session id. Any other harness is the ERROR line naming <config>/launch-<h>
// and null - config/ minted on the way, as ac_config_dir did.
export function buildLaunch(h: string, m = "", e = "", rsid = "", sid = ""): string | null {
  const opt = (flag: string, v: string): string => (v === "" ? "" : ` ${flag} ${v}`);
  switch (h) {
    case "claude":
      return `claude --permission-mode auto${rsid ? opt("--resume", rsid) : opt("--session-id", sid)}${opt("--model", m)}${opt("--effort", e)}`;
    case "codex":
      return `codex -c check_for_update_on_startup=false${opt("-m", m)}${e === "" ? "" : ` -c model_reasoning_effort=${e}`}`;
    case "opencode":
      return `opencode${opt("-m", m)}`;
    case "pi":
      return `pi --tui-mode regular${opt("--model", m)}${opt("--thinking", e)}`;
    case "cursor":
      return `cursor-agent --yolo${opt("--model", m)}`;
  }
  writeSync(2, prefixed("ERROR: ", `no launch template for harness '${h}'; create ${softSubdir("config", true)}/launch-${h}`));
  return null;
}

// ac_resolve_profile's twin as `$(...)` ran it, bytes (latin1) out: the argv
// parsed as the bash parsed it, then `harness=<h>\tmodel=<m>\teffort=<e>` (the
// capture's reading, no LF) and 0. --rule resolves through
// <ac_root>/bin/ac-dispatch-select.sh --rule <n> - its stderr the caller's,
// its failure the status - read as `IFS=$'\t' read -r` reads the first line,
// a knob named explicitly winning per knob; with no rule and no harness a
// config/crew-dispatch.json refuses and config/crew-harness (else claude)
// answers. A refusal is the ERROR line and status 1.
export function resolveProfile(args: string[]): { status: number; out: string } {
  const vals = new Map([["--rule", ""], ["--harness", ""], ["--model", ""], ["--effort", ""]]);
  const refuse = (msg: string): { status: number; out: string } => {
    writeSync(2, prefixed("ERROR: ", msg));
    return { status: 1, out: "" };
  };
  for (let i = 0; i < args.length; i += 2) {
    const a = args[i]!;
    if (!vals.has(a)) return refuse(`ac_resolve_profile: unknown arg ${a}`);
    if (i + 1 >= args.length) return refuse(`${a} needs a value`);
    vals.set(a, lat(args[i + 1]!));
  }
  let [h, m, e] = [vals.get("--harness")!, vals.get("--model")!, vals.get("--effort")!];
  const rule = vals.get("--rule")!;
  if (rule !== "") {
    const r = stage([`${STARTED_BIN}/ac-dispatch-select.sh`, "--rule", argvOf(rule)], "inherit", "pipe", "inherit");
    if (r.status !== 0) return { status: r.status, out: "" };
    const [ph, pm, pe] = tabFields(capturedText(r.out).split("\n")[0]!, 3) as [string, string, string];
    const strip = (v: string, k: string): string => (v.startsWith(k) ? v.slice(k.length) : v);
    h ||= strip(ph, "harness=");
    m ||= strip(pm, "model=");
    e ||= strip(pe, "effort=");
  } else if (h === "") {
    if (isFile(`${softSubdir("config", true)}/crew-dispatch.json`))
      return refuse("config/crew-dispatch.json is configured: pick a profile (bin/ac-dispatch-select.sh --list, then --rule <n>) and pass --harness/--model/--effort explicitly");
    h = lat(configReadSoft("crew-harness", "claude"));
  }
  return { status: 0, out: `harness=${h}\tmodel=${m}\teffort=${e}` };
}

// ac_pane_profile's twin as `$(...)` ran it: <ac_root>/bin/ac-dispatch-select.sh
// --pane <kind>, its stdout as the capture read it (latin1), its stderr where
// the call site sent it, its status.
export function paneProfile(kind: string, stderr: "inherit" | "ignore" = "inherit"): { status: number; out: string } {
  const r = stage([`${STARTED_BIN}/ac-dispatch-select.sh`, "--pane", kind], "inherit", "pipe", stderr);
  return { status: r.status, out: capturedText(r.out) };
}

// ac_domain_binding's twin, decoded: AC_DOMAIN when set non-empty, else - for
// an AC_SCOPE inside [A-Za-z0-9_-]+, read per the text (W10) - the domain= of
// state/<scope>-chief.meta, an unreadable one warned and read as none; ""
// when neither answers.
export function domainBinding(): string {
  if (process.env.AC_DOMAIN) return process.env.AC_DOMAIN;
  const scope = process.env.AC_SCOPE ?? "";
  if (!wakeScopeOk(scope)) return "";
  try {
    return argvOf(metaGet(`${softSubdir("state", true)}/${scope}-chief.meta`, "domain"));
  } catch {
    return "";
  }
}

// `cat <src> >[>]<dst>`: the shell's open of <dst> (a failure skips cat, its
// own line not reproduced), then cat spawned into it.
function catInto(src: string, dst: string, append = false): void {
  let fd: number;
  try {
    fd = openSync(dst, append ? "a" : "w");
  } catch {
    return;
  }
  try {
    spawnShellSync(["cat", src], { stdin: "inherit", stdout: fd, stderr: "inherit" });
  } catch {
  } finally {
    closeSync(fd);
  }
}

const rmF = (p: string): number => stage(["rm", "-f", p], "inherit", "inherit", "inherit").status;
const gitExclude = (wt: string): string | null => {
  const g = stage(["git", "-C", wt, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], "inherit", "pipe", "ignore");
  return g.status === 0 ? capturedText(g.out) : null;
};
// `grep -qxF <line> <excl> 2>/dev/null || printf '<line>\n' >>"$excl"`: 0 when
// the line is there or appended, 1 when the append failed.
function excludeLine(excl: string, line: string): number {
  if (stage(["grep", "-qxF", line, argvOf(excl)], "inherit", "ignore", "ignore").status === 0) return 0;
  try {
    appendFileSync(latBuf(excl), Buffer.from(`${line}\n`, "utf8"));
    return 0;
  } catch {
    return 1;
  }
}

// ac_seed_exclude's twin: `/<rel>` in the repo's info/exclude (git's absolute
// --git-path - a linked worktree's lands in its main repo); 0 when git names
// no exclude file, else excludeLine's answer.
function seedExclude(wt: string, rel: string): number {
  const excl = gitExclude(wt);
  return excl === null ? 0 : excludeLine(excl, `/${rel}`);
}

// ac_seed_disposable's twin: `$(head -n 1 <file>)` opens with ac-verify's
// neutralized mark.
function seedDisposable(file: string): boolean {
  return capturedText(stage(["head", "-n", "1", file], "inherit", "pipe", "ignore").out).startsWith("# Neutralized by ac-verify:");
}

// ac_seed_install's twin, errexit asleep as every caller ran it: <staged>
// installed as <wt>/<rel> when the seed owns that path - nothing there,
// ac-verify's neutralized stub, or a file still hashing to its stamp
// (.claude/.ac-seed/<rel, / as %>.sha256; a suffix-less legacy stamp migrated
// when it verifies, removed either way) - then the stamp rewritten and both
// exclude lines ensured. The answer is the bash's status: 0 when <rel> holds
// the staged bytes already, 1 for a path someone else owns (left as it is) or
// a hash that could not be taken, else the second exclude line's - 1 when the
// exclude file could not take it, though the file was installed (kept). The
// hash is in process; cat, mkdir -p and rm -f are spawned.
function seedInstall(wt: string, rel: string, staged: string): number {
  const dst = `${wt}/${rel}`;
  const legacy = `${wt}/${SEED_STAMPS}/${rel.replaceAll("/", "%")}`;
  const stamp = `${legacy}.sha256`;
  const want = shaSoft(staged);
  if (want === "") return 1;
  const catText = (f: string): string => capturedText(stage(["cat", f], "inherit", "pipe", "inherit").out);
  if (existsSync(dst) && !seedDisposable(dst)) {
    let have: string;
    if (isFile(stamp)) {
      have = shaSoft(dst);
      if (have === "" || have !== catText(stamp)) return 1;
    } else if (isFile(legacy)) {
      have = shaSoft(dst);
      if (have === "") return 1;
      if (have !== catText(legacy)) {
        rmF(legacy);
        return 1;
      }
      try {
        writeFileSync(stamp, `${have}\n`);
      } catch {}
      rmF(legacy);
    } else return 1;
    if (have === want) return 0;
  }
  stage(["mkdir", "-p", dirname(dst), `${wt}/${SEED_STAMPS}`], "inherit", "inherit", "inherit");
  catInto(staged, dst);
  try {
    writeFileSync(stamp, `${want}\n`);
  } catch {}
  rmF(legacy);
  seedExclude(wt, rel);
  return seedExclude(wt, `${SEED_STAMPS}/`);
}

// ac_seed_crewmate_md's twin as `$(...)` ran it (errexit asleep), paths
// decoded: the layers there are - <container>/.claude/CLAUDE.md,
// CREWMATE-learned.md, CREWMATE.md, crewdomains/<domainBinding>/CREWMATE.md,
// in that order - composed once in a spawned `mktemp ${TMPDIR:-/tmp}/ac-seed.XXXXXX`
// (one layer as is; several each behind `<!-- agent-crew seed: <label>
// <path> -->`, a blank line between), installed at the harness's instruction
// file or, when someone else owns that, at .claude/CREWMATE.md - whose path is
// then the answer. "" otherwise: no layer, mktemp failed, or neither install
// took. An unknown harness is harnessInstructionFile's ERROR line and an
// install at the worktree itself, which never takes (kept).
export function seedCrewmateMd(wt: string, harness = ""): string {
  const fleet = `${softHome(true)}/CREWMATE.md`;
  const cont = `${dirname(softHome(true))}/.claude/CLAUDE.md`;
  const learned = `${softHome(true)}/CREWMATE-learned.md`;
  const bound = domainBinding();
  const dom = bound === "" ? "" : `${softHome(true)}/crewdomains/${bound}/CREWMATE.md`;
  const rel = harnessInstructionFile(harness) ?? "";
  const layers = (
    [
      [cont, "container"],
      [learned, "fleet-learned"],
      [fleet, "fleet"],
      [dom, "crewdomain"],
    ] as [string, string][]
  ).filter(([f]) => f !== "" && isFile(f));
  if (layers.length === 0) return "";
  const made = stage(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-seed.XXXXXX`], "inherit", "pipe", "inherit");
  if (made.status !== 0) return "";
  const staged = argvOf(capturedText(made.out));
  if (layers.length === 1) catInto(layers[0]![0], staged);
  else
    layers.forEach(([src, label], i) => {
      try {
        appendFileSync(staged, `${i === 0 ? "" : "\n"}<!-- agent-crew seed: ${label} ${src} -->\n`);
      } catch {}
      catInto(src, staged, true);
    });
  let out = "";
  if (seedInstall(wt, rel, staged) !== 0 && seedInstall(wt, SEED_FALLBACK, staged) === 0) out = SEED_FALLBACK;
  rmF(staged);
  return out;
}

// ac_seed_crew_settings' twin: settings.json and settings.local.json each from
// <home>/.claude/<file> - unless that dir resolves into the distro checkout
// (the runtime link, whose settings are the chief's) - else from
// <container>/.claude/<file>, a source that is no file skipped; each through
// seedInstall, its answer ignored.
export function seedCrewSettings(wt: string): void {
  let homeDir = `${softHome(true)}/.claude`;
  if (isDir(homeDir)) {
    const p = physicalDir(homeDir) ?? "";
    const root = STARTED_BIN.slice(0, -"/bin".length);
    if (p === root || p.startsWith(`${root}/`)) homeDir = "";
  }
  for (const rel of ["settings.json", "settings.local.json"]) {
    let src = `${homeDir}/${rel}`;
    if (homeDir === "" || !isFile(src)) src = `${dirname(softHome(true))}/.claude/${rel}`;
    if (isFile(src)) seedInstall(wt, `.claude/${rel}`, src);
  }
}

// ac_meta_set under a caller's `2>/dev/null`: metaSet's lock and rewrite with
// its refusal silent; false when nothing was written. A failed rename's mv
// line is not silenced (named).
function metaSetQuiet(file: string, key: string, value: string): boolean {
  const cut = file.lastIndexOf("/");
  const dir = cut < 0 ? "." : file.slice(0, cut);
  const lock = `${dir}/.${file.slice(cut + 1)}.lock`;
  try {
    accessSync(dir, constants.W_OK | constants.X_OK);
    if (!lockAcquire(lock, 10, sleepOne)) return false;
  } catch {
    return false;
  }
  try {
    metaRewrite(file, () => [[key, value]]);
    return true;
  } catch {
    return false;
  } finally {
    lockRelease(lock);
  }
}

// ac_skill_usage_bump's twin, silent: <dir>/.usage.meta's seeded_count + 1 (a
// count that is not digits reads 0, `$(( ))` reads a leading 0 as octal) and
// last_seeded = ac_now, a refused write ending the bump. A count the
// arithmetic refuses (a leading 0, then an 8 or 9) ENDED bash 3.2 itself,
// status 1, whatever guarded the call: false here.
function skillUsageBump(dir: string): boolean {
  if (dir === "" || !isDir(dir)) return true;
  const meta = `${dir}/.usage.meta`;
  let cur = "";
  try {
    accessSync(meta, constants.R_OK);
    cur = metaGet(meta, "seeded_count");
  } catch {}
  let next: bigint;
  try {
    next = BigInt.asIntN(64, arithValue(/^[0-9]+$/.test(cur) ? cur : "0") + 1n);
  } catch {
    return false;
  }
  if (metaSetQuiet(meta, "seeded_count", String(next))) metaSetQuiet(meta, "last_seeded", nowRaw());
  return true;
}

// The non-dot entries of <dir> as `"$dir"/*` lists them, in byte order (the
// glob collated under UTF-8 - named, the ORDER rule).
function globEntries(dir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${dir}/${n}`);
}

// ac_seed_crew_skills' twin as an errexit caller (ac-spawn.sh, ac-self-task.sh)
// ran it: symlinks in .claude/skills (.agents/skills for codex) - a dangling
// link there removed first, then each AC_CREW_SKILLS name (split on blanks,
// never globbed - named) from <container>/.claude/skills else
// <ac_root>/.agents/skills, then each directory of skills/ but the archive
// (every NEW one bumping its .usage.meta). A name a link or file already
// claims is skipped; every link the seed owns gets its info/exclude line under
// the skills dir's physical path inside the worktree (/<skrel> before it
// exists, none when it resolves outside). The answer is 0, or the status the
// caller ended with: a spawned rm -f, mkdir -p or ln -s that failed, an
// exclude line not appended (1), a usage count bash's arithmetic refused (1).
export function seedCrewSkills(wt: string, harness = ""): number {
  const skrel = harness === "codex" ? ".agents/skills" : ".claude/skills";
  const skdir = `${wt}/${skrel}`;
  const excl = gitExclude(wt) ?? "";
  let pfx = `/${skrel}`;
  if (isDir(skdir)) {
    pfx = "";
    const root = physicalDir(wt) ?? "";
    const sk = physicalDir(skdir) ?? "";
    if (root !== "" && sk.startsWith(`${root}/`)) pfx = `/${sk.slice(root.length + 1)}`;
    for (const dst of globEntries(skdir)) {
      if (!isLink(dst) || existsSync(dst)) continue;
      const s = rmF(dst);
      if (s !== 0) return s;
    }
  }
  // One name: linked when nothing is there yet, then its exclude line.
  const seed = (src: string, name: string, bump: boolean): number => {
    const dst = `${skdir}/${name}`;
    if (!existsSync(dst) && !isLink(dst)) {
      for (const cmd of [["mkdir", "-p", skdir], ["ln", "-s", src, dst]]) {
        const s = stage(cmd, "inherit", "inherit", "inherit").status;
        if (s !== 0) return s;
      }
      if (bump && !skillUsageBump(src)) return 1;
    }
    return isLink(dst) && excl !== "" && pfx !== "" ? excludeLine(excl, `${pfx}/${name}`) : 0;
  };
  for (const name of (process.env.AC_CREW_SKILLS || "crew-ship crew-verify crew-qa domain-e2e document").split(/[ \t\n]+/)) {
    if (name === "") continue;
    let src = `${dirname(softHome(true))}/.claude/skills/${name}`;
    if (!isDir(src)) src = `${STARTED_BIN.slice(0, -"/bin".length)}/.agents/skills/${name}`;
    if (!isDir(src)) continue;
    const s = seed(src, name, false);
    if (s !== 0) return s;
  }
  for (const src of globEntries(softSubdir("skills", true))) {
    const name = basename(src);
    if (!isDir(src) || name === SKILLS_ARCHIVE) continue;
    const s = seed(src, name, true);
    if (s !== 0) return s;
  }
  return 0;
}

// ac_port_slot_allocate's twin as `$(...)` ran it: under the registry lock (10
// PATH `sleep 1` waits) the rows whose worktree is no directory dropped by the
// bash's own awk (spawned, its `system("test -d ...")` and all) into an
// EXCLUSIVE <reg>.tmp.<pid> (named) that a spawned mv renames over the
// registry, then <wt>'s slot: its row's first field, else the lowest integer
// awk finds no row for, appended with ac_iso. null, nothing written, for a
// lock not taken - homeless too: the refusal printed, `/port-slots.tsv.lock`
// waited on, as ac_port_registry's printf went on with the empty state dir.
function portSlotAllocate(wt: string, proj: string): string | null {
  const reg = `${softSubdir("state", true)}/port-slots.tsv`;
  const lock = `${reg}.lock`;
  let held = false;
  try {
    held = lockAcquire(lock, 10, sleepOne);
  } catch {}
  if (!held) return null;
  try {
    if (!isFile(reg))
      try {
        writeFileSync(reg, "");
      } catch {}
    try {
      const t = exclusiveTemp(`${reg}.tmp`);
      let r: ReturnType<typeof Bun.spawnSync> | null = null;
      try {
        r = spawnShellSync(["awk", "-F\\t", '{ if ($2 != "" && system("test -d \\"" $2 "\\"") == 0) print }', reg], { stdin: "inherit", stdout: t.fd, stderr: "ignore" });
      } catch {}
      if (shellStatus(r) !== 0) ftruncateSync(t.fd, 0);
      closeSync(t.fd);
      stage(["mv", t.path, reg], "inherit", "inherit", "inherit");
    } catch {}
    let taken = capturedText(stage(["awk", "-F\\t", "-v", `w=${wt}`, "$2 == w { print $1; exit }", reg], "inherit", "pipe", "inherit").out);
    if (taken === "") {
      let slot = 1n;
      while (stage(["awk", "-F\\t", "-v", `s=${slot}`, "$1 == s { found = 1 } END { exit(found ? 0 : 1) }", reg], "inherit", "ignore", "inherit").status === 0) slot++;
      try {
        appendFileSync(reg, `${slot}\t${wt}\t${proj}\t${argvOf(iso())}\n`);
      } catch {}
      taken = String(slot);
    }
    return taken;
  } finally {
    lockRelease(lock);
  }
}

// ac_seed_ports_env's twin as `... >/dev/null || ac_warn` ran it:
// <wt>/.crew/ports.env for <wt>'s slot - AC_PORT_BASE (20000) + slot*100, a
// hundred ports, read by bash's arithmetic (arithValue THROWS where bash 3.2
// ended) - .crew/ excluded, and the range `<lo>-<hi>` as the answer; null for
// a worktree that is no directory or no slot. mkdir -p is spawned; a ports.env
// the shell could not write is skipped, as its redirect was.
export function seedPortsEnv(wt: string, proj = ""): string | null {
  if (!isDir(wt)) return null;
  const slot = portSlotAllocate(wt, proj);
  if (slot === null) return null;
  const lo = BigInt.asIntN(64, arithValue(process.env.AC_PORT_BASE || "20000") + arithValue(slot) * 100n);
  const hi = BigInt.asIntN(64, lo + 99n);
  stage(["mkdir", "-p", `${wt}/.crew`], "inherit", "inherit", "inherit");
  try {
    writeFileSync(
      `${wt}/.crew/ports.env`,
      latBuf(`# agent-crew port slot - one fleet-wide slot per leased worktree; every listener this worktree starts binds inside this range.\nAC_PORT_SLOT=${slot}\nAC_PORT_RANGE=${lo}-${hi}\nPORT=${lo}\n`),
    );
  } catch {}
  seedExclude(wt, ".crew/");
  return `${lo}-${hi}`;
}

// orca_resolve_group's twin: the nearest ancestor of <path> (itself first)
// that `orca worktree show --worktree path:<p>` resolves, else <path>.
function orcaResolveGroup(path: string): string {
  for (let p = path; p !== "" && p !== "/"; p = dirname(p)) if (orcaJson(["worktree", "show", "--worktree", `path:${p}`], "inherit") !== null) return p;
  return path;
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
// or the home's node, its tab recorded. The command defaults to
// `cd '<dir>' && exec ${SHELL:-/bin/zsh}`, the id (family ladder and title)
// to `agent`.
export function orcaPlacePane(dir: string, cmd = "", agent = ""): string | null {
  const command = cmd || `cd '${dir}' && exec \${SHELL:-/bin/zsh}`;
  const id = agent || "agent";
  const dirP = physicalDir(dir) ?? dir;
  const homeP = process.env.AC_HOME ? (physicalDir(process.env.AC_HOME) ?? "") : "";
  const create = (node: string): { handle: string; tab: string } | null => {
    const out = orcaJson(["terminal", "create", "--worktree", node, "--title", `crew:${fleetName()}/${id}`, "--command", command], "inherit");
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
    if (orcaJson(["terminal", "split", "--terminal", argvOf(base), "--direction", "vertical", "--command", command], "inherit") === null) {
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
    return `${handle} ${tab}`;
  }
  const c = create(configReadSoft("orca-node", "") || `path:${orcaResolveGroup(homeP)}`);
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

const AGENT_STATUS_JQ = '[.. | .agent_status? // empty] | map(select(. != "")) | first // empty';

// backend_dialog_answer_pane_{herdr,orca}'s twin, one RAW pane (decoded): 0
// one named dialog answered with the key safe on it - herdr's `agent explain`
// rule startup_update, orca's agentWait reason codex-update-prompt or
// codex-hooks-review-prompt, each taking 2 - 1 nothing pending, 2 a dialog it
// cannot name, 3 unobservable (no pane, a failed read or press). herdr
// focuses the tab `pane get` names, best-effort, before its press.
function dialogAnswerPane(b: string, p: string, io: SpawnIo): number {
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

// backend_dialog_answer's twin: the routed raw-pane answer for the pane the
// task's handle names.
export function backendDialogAnswer(id: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: dialogAnswerPane(b, argvOf(paneField(id, 1, io.stderr === "inherit")), io), exited: false };
}

// backend_agent_idle_pane_{herdr,orca}'s twin, one RAW pane (decoded): 0
// idle. herdr: `pane get`'s agent_status is idle or done (jq's stderr the
// caller's); orca: the TUI read idle (orcaAgentIdle). No pane, or a failed
// read, is 1.
function agentIdlePane(b: string, p: string, io: SpawnIo): number {
  if (p === "") return 1;
  if (b === "orca") return orcaAgentIdle(p, io.stdin ?? "inherit", io.stderr) ? 0 : 1;
  const get = herdrCli(["pane", "get", p], "ignore", "pipe");
  if (get.status !== 0) return 1;
  const s = capturedText(jqOver(["-r", AGENT_STATUS_JQ], capturedText(get.out), "pipe", io.stderr).out);
  return s === "idle" || s === "done" ? 0 : 1;
}

// backend_agent_idle_pane's twin, routed per call over a raw pane id.
export function backendAgentIdlePane(pane: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: agentIdlePane(b, pane, io), exited: false };
}

// backend_agent_idle's twin: the routed raw-pane reading for the pane the
// task's handle names.
export function backendAgentIdle(id: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: agentIdlePane(b, argvOf(paneField(id, 1, io.stderr === "inherit")), io), exited: false };
}

// backend_submit_verified's twin (id-keyed), routed per call: one Enter whose
// render must react - 0 accepted, 1 stranded, 2 unreadable, and on orca 3 a
// dialog owns the pane; orca re-presses (at most twice) while <text> still
// sits in its composer, herdr ignores <text>.
export function backendSubmitVerified(id: string, text: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  const top = io.stdin ?? "inherit";
  if (b === "herdr") return { status: submitVerified(id, top, io.stderr), exited: false };
  return { status: orcaSubmitVerified(argvOf(paneField(id, 1, io.stderr === "inherit")), text, top, io.stderr), exited: false };
}

// backend_send_key under `|| true`, routed per call: herdr focuses the
// handle's tab and presses whatever the focus answered (backendCall's
// send_key stops at a failed focus, as an errexit caller did).
function keyPress(id: string, key: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  const vio: VerbIo = { stdin: io.stdin, stdout: "ignore", stderr: io.stderr };
  if (b === "orca") return { status: orcaVerb("send_key", [id, key], vio, () => {}), exited: false };
  herdrVerb("focus", [id], vio, () => {});
  const keyName = keyNamed(key) ?? key.replace(/\n+$/, "");
  return { status: herdrCli(["pane", "send-keys", argvOf(paneField(id, 1, io.stderr === "inherit")), keyName], io.stdin ?? "inherit", "ignore").status, exited: false };
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

// backend_startup_dialogs' twin: the sequence over the id-keyed verbs - the
// task's handle answered, keyed and probed (the raw-pane sequence is
// backendStartupDialogsPane's).
export function backendStartupDialogs(id: string, harness: string, io: SpawnIo): Ended {
  const up = (h: string): Ended => {
    const r = backendCall("harness_up", [h], { stdin: io.stdin, stdout: "ignore", stderr: io.stderr });
    return { status: r.status, exited: r.exited };
  };
  return startupDialogs((h) => backendDialogAnswer(h, io), (h, k) => keyPress(h, k, io), up, id, harness);
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

// The lease install, shared by the crew spawn and the self task: the
// captain-owned commands.install of <repo>'s home yaml, run as `sh -c` in the
// fresh lease <wt> with AC_LEASE_PRIMARY=<repo> (so it can reuse the primary's
// caches), stdin closed, its output dropped, bounded by
// AC_LEASE_INSTALL_TIMEOUT (default 300 s) - past it the group is TERMed then
// KILLed, as herdrCli's ceiling does. "" when no command is declared; "ok"
// when it exits 0 and `git status --porcelain` is empty after it; else
// "failed", WARNed with the cause. The distro never refuses the lease and
// never restores what the command dirtied: a command that touches tracked
// files restores them itself.
export function leaseInstall(id: string, repo: string, wt: string): "" | "ok" | "failed" {
  const cf = projectConfigFile(repo, true);
  const cmd = cf === null ? "" : argvOf(yamlGet(cf, "commands.install", true).out.replace(/\n+$/, ""));
  if (cmd === "") return "";
  const t = process.env.AC_LEASE_INSTALL_TIMEOUT || "";
  const secs = /^[0-9]+$/.test(t) && Number(t) > 0 ? Number(t) : 300;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["/usr/bin/env", `AC_LEASE_PRIMARY=${repo}`, "sh", "-c", cmd], { cwd: wt, stdin: "ignore", stdout: "ignore", stderr: "ignore", detached: true, timeout: Math.min(secs * 1000, 2 ** 31 - 1) });
  } catch {}
  let cause = "";
  if (r?.exitedDueToTimeout) {
    for (const sig of ["SIGTERM", "SIGKILL"] as const)
      try {
        process.kill(-r.pid, sig);
      } catch {}
    cause = `timed out after ${secs}s`;
  } else if (shellStatus(r) !== 0) cause = `exit ${shellStatus(r)}`;
  else {
    const st = stage(["git", "-C", wt, "status", "--porcelain"], "ignore", "pipe", "ignore");
    const dirty = capturedText(st.out).split("\n").filter((l) => l !== "").map((l) => l.slice(3));
    if (st.status !== 0) cause = "its worktree state could not be read";
    else if (dirty.length > 0) cause = `it left the worktree dirty: ${dirty.join(", ")}`;
  }
  if (cause === "") return "ok";
  warn(latBuf(`commands.install failed for ${lat(id)} (${cause}) - the worktree's dependencies are not installed; install them before testing`));
  return "failed";
}

// --- learn twins ---

// ac_learn_meta / ac_learn_ticks twins: the dot-files under state/ (minted),
// outside the state/*.meta crewmate namespace.
export const learnMeta = (): string => `${softSubdir("state", true)}/.learn.meta`;
export const learnTicks = (): string => `${softSubdir("state", true)}/.learn-ticks`;
const learnCadenceLock = (): string => `${softSubdir("state", true)}/.learn-cadence.lock`;

// `{ ... } >"$f.tmp.$$"; mv "$f.tmp.$$" "$f"`: <fill> writes the temp, made
// exclusively (<f>.tmp.<pid>, then .<n>) where the bash's name was written
// through, and a spawned mv renames it; mv's status, 1 when no temp could be
// made (the bash's redirect failed and its mv found nothing to move).
function viaTemp(f: string, fill: (fd: number) => void): number {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(`${f}.tmp`);
  } catch {
    return 1;
  }
  try {
    fill(t.fd);
  } finally {
    closeSync(t.fd);
  }
  return stage(["mv", t.path, f], "inherit", "inherit", "inherit").status;
}

// One spawned child writing to <fd>, its stdin the caller's; its status.
function stageTo(cmd: string[], fd: number): number {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: "inherit", stdout: fd, stderr: "inherit" });
  } catch {}
  return shellStatus(r);
}

// ac_learn_migrate's twin: a meta holding the legacy `stows` key carries its
// count to `debriefs` (unless debriefs is already set - never clobbered) and
// loses every `stows=` line through a spawned `grep -v`, whose own failure is
// ignored as `|| true` ignored it.
export function learnMigrate(f: string): void {
  if (!isFile(f)) return;
  const old = metaGetSoft(f, "stows");
  if (old === "") return;
  if (metaGetSoft(f, "debriefs") === "") metaSetSoft(f, "debriefs", old);
  viaTemp(f, (fd) => {
    stageTo(["grep", "-v", "^stows=", f], fd);
  });
}

// `$((n + 1))` over a digits-only count: a leading 0 reads octal, and an 8 or
// 9 behind it throws EARITH where the shell's arithmetic error ended it.
const plusOne = (n: string): string => String(BigInt.asIntN(64, arithValue(n) + 1n));
const digitsOr = (v: string, d: string): string => (/^[0-9]+$/.test(v) ? v : d);

// ac_learn_count_one's twin, for a caller already holding the cadence lock:
// migrate, then generation (rewritten as read) and debriefs+1.
export function learnCountOne(): void {
  const f = learnMeta();
  learnMigrate(f);
  const cur = digitsOr(metaGetSoft(f, "debriefs"), "0");
  const gen = digitsOr(metaGetSoft(f, "generation"), "0");
  metaSetSoft(f, "generation", gen);
  metaSetSoft(f, "debriefs", plusOne(cur));
}

// ac_learn_tick's twin under state/.learn-cadence.lock (10 PATH `sleep 1`
// waits): false, warned, when the lock is not taken; else counted.
export function learnTick(): boolean {
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning tick: cadence lock ${lock} could not be acquired within 10s - the debrief counter was NOT advanced. Missing a tick only delays the next distill (the LEVEL trigger still fires); it never loses a landing outright, but a caller that assumes success will believe the counter moved when it did not.`);
    return false;
  }
  learnCountOne();
  lockRelease(lock);
  return true;
}

// ac_learn_generation's twin: the meta's generation, "0" unless digits.
export function learnGeneration(): string {
  return digitsOr(metaGetSoft(learnMeta(), "generation"), "0");
}

const TICK_HIT_AWK = "BEGIN { w[k] } ($2 in w) && now - $1 < win { hit = 1 } END { if (!hit) exit 1 }";

// ac_learn_tick_keyed's twin, its status as learn_cadence_call reads it: 0
// when <key>'s claim was fresh and the counter advanced, 1 when <key> is
// stamped inside 24 h (silent), 2 where the bash returned 1 having spoken - a
// busy cadence lock (warned) or a stamp whose mv failed (mv's own line). Both
// awks are spawned as the bash ran them (`in`, never ==, so `07` is not `7`),
// under LC_ALL=C: the stamp file is read as bytes. The stamp (the file's live
// rows plus `<now>\t<key>`) lands through an exclusive temp and a spawned mv
// BEFORE the count.
export function learnTickKeyed(key: string): number {
  const f = learnTicks();
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning tick: cadence lock ${lock} could not be acquired within 10s - landing '${key}' was NOT claimed. Missing a tick only delays the next distill (the LEVEL trigger still fires); counting one twice consumes a retro window and cannot be undone.`);
    return 2;
  }
  const now = nowRaw();
  const awk = ["/usr/bin/env", "LC_ALL=C", "awk", "-F\t", "-v", `now=${now}`];
  if (isFile(f) && stage([...awk, "-v", `k=${key}`, "-v", "win=86400", TICK_HIT_AWK, f], "inherit", "inherit", "inherit").status === 0) {
    lockRelease(lock);
    return 1;
  }
  const mv = viaTemp(f, (fd) => {
    if (isFile(f)) stageTo([...awk, "-v", "win=86400", "now - $1 < win", f], fd);
    writeAll(fd, Buffer.from(`${now}\t${key}\n`, "latin1"));
  });
  if (mv === 0) learnCountOne();
  lockRelease(lock);
  return mv === 0 ? 0 : 2;
}

// ac_learn_due's twin: [debriefs (the legacy stows when unset), learn-every],
// "0" and "8" unless digits. Reads only.
export function learnDue(): [string, string] {
  const m = learnMeta();
  let cur = metaGetSoft(m, "debriefs");
  if (cur === "") cur = metaGetSoft(m, "stows");
  return [digitsOr(cur, "0"), digitsOr(configReadSoft("learn-every", "8"), "8")];
}

// ac_learn_reset's twin under the cadence lock, its status as
// learn_cadence_call reads it: 2 for a lock not taken (warned), 1 when
// <expected> names an older generation (silent), else 0 - the migrate, then
// generation+1 (bash arithmetic, as curateReset), debriefs 0 and last_run
// stamped. The landing stamps are deliberately left alone.
export function learnReset(expected = ""): number {
  const f = learnMeta();
  const lock = learnCadenceLock();
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`learning reset: cadence lock ${lock} could not be acquired within 10s - the debrief counter was NOT reset and its generation did NOT advance, so a due DISTILL cycle stays due. This is a lock failure, not a newer cadence generation.`);
    return 2;
  }
  learnMigrate(f);
  const current = learnGeneration();
  if (expected !== "" && expected !== current) {
    lockRelease(lock);
    return 1;
  }
  metaSetSoft(f, "generation", plusOne(current));
  metaSetSoft(f, "debriefs", "0");
  metaSetSoft(f, "last_run", nowRaw());
  lockRelease(lock);
  return 0;
}

// ac_curate_tick's twin, under state/.curate-cadence.lock: false, warned,
// when the lock is not taken; else generation (as read) and runs_since+1.
export function curateTick(): boolean {
  const f = curateMeta();
  const lock = `${softSubdir("state", true)}/.curate-cadence.lock`;
  if (!lockAcquire(lock, 10, sleepOne)) {
    warn(`curate tick: cadence lock ${lock} could not be acquired within 10s - the learning-run counter was NOT advanced. Missing a tick only delays the next Curate pass, but a caller that assumes success will believe the counter moved when it did not.`);
    return false;
  }
  const cur = digitsOr(metaGetSoft(f, "runs_since"), "0");
  const gen = digitsOr(metaGetSoft(f, "generation"), "0");
  metaSetSoft(f, "generation", gen);
  metaSetSoft(f, "runs_since", plusOne(cur));
  lockRelease(lock);
  return true;
}

// ac_skills_dir's twin: <home>/skills, minted.
export function skillsDir(): string {
  return homeSubdir("skills");
}

// ac_maintenance_incomplete's twin: one `<txid>\t<status>\t<committed>\t<plan>`
// row per transaction dir under <root> whose journal is neither complete nor
// abandoned - status `unknown` when unset, committed the run of leading
// `action_<i>=complete` keys, plan `-` when unset - the dirs in byte order
// (W13: the bash's glob followed LC_COLLATE). Bytes (latin1) out.
export function maintenanceIncomplete(root: string): string[] {
  if (!isDir(root)) return [];
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {}
  const rows: string[] = [];
  for (const n of names.filter((x) => !x.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    const dir = `${root}/${n}`;
    const journal = `${dir}/journal`;
    if (!isDir(dir) || !isFile(journal)) continue;
    const status = metaGetSoft(journal, "status");
    if (status === "complete" || status === "abandoned") continue;
    let done = 0;
    while (metaGetSoft(journal, `action_${done}`) === "complete") done++;
    const plan = metaGetSoft(journal, "plan");
    rows.push(`${lat(n)}\t${status || "unknown"}\t${done}\t${plan || "-"}`);
  }
  return rows;
}

// ac_crewmate_learned_no_loss's twin: true when every `## ` line of <live>
// (as grep prints them - a NUL in its head makes that one `Binary file`
// line) is a whole line of <staged>, or its slug occurs in <retired>; a
// missing <live> passes, a missing <staged> fails.
export function crewmateLearnedNoLoss(live: string, staged: string, retired: string): boolean {
  if (!isFile(live)) return true;
  if (!isFile(staged)) return false;
  const heads = capturedText(stage(["grep", "^## ", live], "inherit", "pipe", "inherit").out);
  if (heads === "") return true;
  const lines = (p: string): string[] => {
    try {
      return readFileSync(p).toString("latin1").split("\n");
    } catch {
      return [];
    }
  };
  const have = new Set(lines(staged));
  for (const head of heads.split("\n")) {
    if (have.has(head)) continue;
    if (retired !== "" && isFile(retired) && lines(retired).some((l) => l.includes(head.replace(/^## /, "")))) continue;
    return false;
  }
  return true;
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


// ac_verdict_json's string-aware awk, verbatim: the brace depth, the string
// and escape states and the NUL after every top-level object are awk's, in
// the caller's locale.
const VERDICT_AWK = String.raw`
    { buf = buf $0 "\n" }
    END {
      n = length(buf); depth = 0; instr = 0; esc = 0; start = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (esc) { esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { instr = 0 }
          continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "{") { if (depth == 0) start = i; depth += 1 }
        else if (c == "}" && depth > 0) {
          depth -= 1
          if (depth == 0) { printf "%s%c", substr(buf, start, i - start + 1), 0; start = 0 }
        }
      }
    }
  `;

// ac_verdict_json's twin as its pipefail callers read it: <input> (what the
// bash read on stdin) through the spawned awk, then each NUL-terminated
// candidate - `read -r -d ''` leaves an unterminated tail unread - offered to a
// spawned `jq -e 'type == "object"'` as its bytes, the LAST one it accepts
// answered with a LF, nothing when none. The status is awk's when awk failed,
// else 0. Bytes in, bytes out.
export function verdictJson(input: Buffer): { status: number; out: Buffer } {
  const a = stage(["awk", VERDICT_AWK], input, "pipe", "inherit");
  const cands = a.out.toString("latin1").split("\0");
  cands.pop();
  let best = "";
  for (const c of cands) if (stage(["jq", "-e", 'type == "object"'], latBuf(c), "ignore", "ignore").status === 0) best = c;
  return { status: a.status, out: best === "" ? Buffer.alloc(0) : latBuf(`${best}\n`) };
}

const TRANSCRIPT_EPOCH_JQ = `[.[] | select(.type == "assistant")] | last | .timestamp // ""`;

// ac_transcript_final_epoch's twin: the last assistant message's own
// .timestamp through a spawned jq, read as `$(... || true)` read it, then the
// iso-epoch verb's isoEpoch in process: the epoch second and a LF (status 0),
// or nothing (status 1) for an empty stamp or one outside its calendar
// grammar. The bash starts that verb through bun with its stderr dropped, so
// its bun-less arm answered 1 silently; nothing here starts bun.
export function transcriptFinalEpoch(file: string): { status: number; out: string } {
  const ts = capturedText(stage(["jq", "-rs", TRANSCRIPT_EPOCH_JQ, file], "inherit", "pipe", "ignore").out);
  const epoch = ts === "" ? null : isoEpoch(Buffer.from(ts, "latin1").toString("utf8"));
  return epoch === null ? { status: 1, out: "" } : { status: 0, out: `${epoch}\n` };
}

// ac_chief_busy_hold's twin (bin/ac-wake-lib.sh owns the declaration's
// contract): this process's holder mark `pid=<pid>` first, then <until> over a
// declaration whose `$(cat)` text - anything but ASCII digits read as 0 - is
// below it, so a later bound is never shortened; a comparison `[` cannot make
// (a value past its range) writes, as its error status did. Every write best
// effort. The shell's own lines are not reproduced: `[`'s, and a failed
// write's, which its `2>/dev/null` - placed after the failing `>` - never
// silenced.
export function chiefBusyHold(sd: string, fam: string, until: string): void {
  const decl = chiefBusyPath(sd, fam);
  try {
    writeFileSync(`${sd}/.chief-busy-holder.${fam}.${process.pid}`, `pid=${process.pid}\n`);
  } catch {}
  let prev = "";
  try {
    prev = capturedText(readFileSync(decl));
  } catch {}
  if (prev === "" || /[^0-9]/.test(prev)) prev = "0";
  const p = testInt(prev);
  const u = testInt(until);
  if (p === null || u === null || p < u)
    try {
      writeFileSync(decl, `${until}\n`);
    } catch {}
}

// ac_chief_busy_leave's twin: this process's holder mark goes (a spawned
// `rm -f`), and the declaration with it unless chiefBusyHeld finds a live
// holder left - under <famData>/.gate-lock when <famData> is a directory and
// the lock is had within 10 PATH `sleep 1` waits, unlocked otherwise, as
// ac-gate.sh takes it at its exit. `quiet` is the caller's `2>/dev/null`.
export function chiefBusyLeave(sd: string, fam: string, famData: string, quiet = false): void {
  const err = quiet ? "ignore" : "inherit";
  stage(["rm", "-f", `${sd}/.chief-busy-holder.${fam}.${process.pid}`], "inherit", "inherit", err);
  const lock = `${famData}/.gate-lock`;
  const locked = isDir(famData) && lockAcquire(lock, 10, sleepOne);
  if (!chiefBusyHeld(sd, fam, famData, quiet)) stage(["rm", "-f", chiefBusyPath(sd, fam)], "inherit", "inherit", err);
  if (locked) lockRelease(lock);
}

// ac_room_review_rulings' awk, verbatim, run under LC_ALL=C as there.
const ROOM_RULINGS_AWK = String.raw`
    /^- \[[^]]*\] [^>]*> (GATE|ASK):/ { print; next }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { print; next }
    /^- \[[^]]*\] [^>]*> (TRIAGE|SELF-APPROVED):/ { print; next }
    /^- \[[^]]*\] [^>]*> GATE-PASSED \(auto\):/ { print; next }
    /^- \[[^]]*\] [^>]*> CORRECTION( \([^)]*\))?:/ { print; next }
  `;

// ac_room_review_rulings' twin: nothing (status 0) unless <file> is a regular
// file (`[ -f ]`), else the awk's stdout bytes and status.
export function roomReviewRulings(file: string): { status: number; out: Buffer } {
  if (!isFile(file)) return { status: 0, out: Buffer.alloc(0) };
  return stage(["/usr/bin/env", "LC_ALL=C", "awk", ROOM_RULINGS_AWK, file], "inherit", "pipe", "inherit");
}

// ac_harness_pane_arm's twin (bin/ac-harness.sh owns the arm map): null where
// the bash returned 1.
export function harnessPaneArm(h: string): "session" | "crewmate" | null {
  if (h === "claude") return "session";
  return ["codex", "opencode", "pi", "cursor"].includes(h) ? "crewmate" : null;
}

// backend_capture_pane's twin, the read addressed by RAW pane id - a pane with
// no state/.pane-<id> handle, a pane agent's or a verifier's: the route as
// backendCall reads it (a refused name exits, 1), an empty <pane> 1, then the
// driver's read - herdr `pane read <pane> --source recent --lines <n>` (n the
// lines when testInt reads them at least 200, else 200; stdin /dev/null and
// stderr dropped, as inside its `$( )`), failing 1, then `tail -n <lines>`
// over that text and a LF; orca `terminal read --terminal <pane> --limit
// <lines> --screen` through orcaJson, failing 1, then `jq -r
// '.result.terminal.tail[]?'` over it. The status is tail's or jq's. <lines>
// empty is 40.
export function backendCapturePane(pane: string, lines: string, io: { stdin?: "inherit" | "ignore"; stdout: Stdio; stderr: "inherit" | "ignore" }): { status: number; exited: boolean; out: Buffer } {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true, out: Buffer.alloc(0) };
  const none = { status: 1, exited: false, out: Buffer.alloc(0) };
  if (pane === "") return none;
  const n = lines || "40";
  if (b === "herdr") {
    const want = testInt(n);
    const read = herdrCli(["pane", "read", pane, "--source", "recent", "--lines", want !== null && want >= 200n ? n : "200"], "ignore", "pipe");
    if (read.status !== 0) return none;
    const t = stage(["tail", "-n", n], latBuf(`${capturedText(read.out)}\n`), io.stdout, io.stderr);
    return { status: t.status, exited: false, out: t.out };
  }
  const out = orcaJson(["terminal", "read", "--terminal", pane, "--limit", n, "--screen"], io.stdin ?? "inherit");
  if (out === null) return none;
  const t = jqOver(["-r", ".result.terminal.tail[]?"], out, io.stdout, io.stderr);
  return { status: t.status, exited: false, out: t.out };
}

// herdr_focus_pane's twin: the tab `pane get` names (both reads /dev/null
// inside their `$( )`), focused; 1 when no tab answered, else the focus's
// status.
function herdrFocusPane(p: string, top: "inherit" | "ignore"): number {
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

// backend_send_line_pane's twin, routed per call over a raw pane id, silent:
// no pane 1; herdr types <text>, settles and verifies one Enter, then focuses
// and verifies one more, that retry's verdict the answer (0 accepted, 1
// stranded, 2 unreadable); orca types it in chunks, settles and verifies the
// Enter with <text> - a dialog-owned pane (3) answers 1 with no retry, any
// other failure gets a terminal switch and one more verify whose verdict,
// 3 included, is the answer.
export function backendSendLinePane(pane: string, text: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  if (pane === "") return { status: 1, exited: false };
  const top = io.stdin ?? "inherit";
  if (b === "herdr") {
    herdrCli(["pane", "send-text", pane, text], top, "ignore");
    settle(io.stderr);
    if (submitVerifiedPane(pane, top, io.stderr) === 0) return { status: 0, exited: false };
    herdrFocusPane(pane, top);
    return { status: submitVerifiedPane(pane, top, io.stderr), exited: false };
  }
  orcaType(pane, text, top, io.stderr);
  settle(io.stderr);
  const rc = orcaSubmitVerified(pane, text, top, io.stderr);
  if (rc === 0) return { status: 0, exited: false };
  if (rc === 3) return { status: 1, exited: false };
  orcaJson(["terminal", "switch", "--terminal", pane], top);
  return { status: orcaSubmitVerified(pane, text, top, io.stderr), exited: false };
}

// backend_agent_status_pane's twin, routed per call over a raw pane id: the
// word and a LF, status 0. herdr: `pane get`'s agent_status (jq's stderr
// dropped), `unknown` for no pane, a failed read or no status; orca: blocked
// for a pending wait, unknown for no pane, an unreadable or disconnected
// terminal, idle when the TUI reads idle (orcaAgentIdle), working for a
// spinner title, else unknown.
export function backendAgentStatusPane(pane: string, io: SpawnIo): { status: number; exited: boolean; out: Buffer } {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true, out: Buffer.alloc(0) };
  const say = (w: string): { status: number; exited: boolean; out: Buffer } => ({ status: 0, exited: false, out: latBuf(`${w}\n`) });
  if (pane === "") return say("unknown");
  if (b === "herdr") {
    const get = herdrCli(["pane", "get", pane], "ignore", "pipe");
    if (get.status !== 0) return say("unknown");
    return say(capturedText(jqOver(["-r", AGENT_STATUS_JQ], capturedText(get.out), "pipe", "ignore").out) || "unknown");
  }
  const top = io.stdin ?? "inherit";
  const show = orcaJson(["terminal", "show", "--terminal", pane], top);
  if (show === null) return say("unknown");
  if (jqOver(["-e", ".result.terminal.agentWait != null"], show, "ignore", "ignore").status === 0) return say("blocked");
  if (jqOver(["-e", ".result.terminal.connected == true"], show, "ignore", "ignore").status !== 0) return say("unknown");
  if (orcaAgentIdle(pane, top, io.stderr)) return say("idle");
  return say(spins(capturedText(jqOver(["-r", ".result.terminal.title // empty"], show, "pipe", io.stderr).out)) ? "working" : "unknown");
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
