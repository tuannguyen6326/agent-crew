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
import { existsSync, lstatSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
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
