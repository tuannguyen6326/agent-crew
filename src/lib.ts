// lib.ts - the TypeScript twin of the bin/ac-lib.sh helpers the ported
// scripts under src/ need, and nothing more: a helper lands here only when a
// port calls it. Each one keeps its bash original's observable contract (the
// same stderr shape, exit status and homeless answer), because callers of a
// ported bin/ac-*.sh entry cannot tell which language answered them.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");

// writeSync, not process.stderr.write: the message must be on the fd before
// process.exit tears the process down.
export function die(msg: string): never {
  writeSync(2, `ERROR: ${msg}\n`);
  process.exit(1);
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

// ac_contract_lint's twin, one violation per entry. ac-task.sh add still calls
// the shell original, so the value vocabulary lives in two places and
// tests/ts/lib.test.ts holds this copy to that one.
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
