// lib.ts - the TypeScript twin of the bin/ac-lib.sh helpers the ported
// scripts under src/ need, and nothing more: a helper lands here only when a
// port calls it. Each one keeps its bash original's observable contract (the
// same stderr shape, exit status and homeless answer), because callers of a
// ported bin/ac-*.sh entry cannot tell which language answered them.

import { existsSync, mkdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { join, resolve } from "node:path";

// writeSync, not process.stderr.write: the message must be on the fd before
// process.exit tears the process down.
export function die(msg: string): never {
  writeSync(2, `ERROR: ${msg}\n`);
  process.exit(1);
}

// ac_home_resolve's no-flag rungs: `cd "$AC_HOME" && pwd -P`, or "" when
// unset - a homeless caller is legitimate and decides what "no home" means.
// A chdir round-trip, not realpath: cd tries the logical spelling (link/..
// walks back up the link) before the physical one, needs only search
// permission, and takes spellings realpath refuses (over PATH_MAX, a
// backslash in Bun's).
export function envHome(): string {
  const h = process.env.AC_HOME;
  if (!h) return "";
  const here = process.cwd();
  for (const dir of [resolve(h), h]) {
    try {
      process.chdir(dir);
      return process.cwd();
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
  return readFileSync(f, "utf8").split("\n")[0].replace(SHELL_TRIM, "");
}

export function stateDir(): string {
  if (!process.env.AC_HOME)
    die("AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one");
  const dir = join(envHome(), "state");
  mkdirSync(dir, { recursive: true });
  return dir;
}
