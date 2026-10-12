// lint.ts - the single lint definition: `bash -n` then shellcheck over the
// scripts a checkout owns. The entry is bin/ac-lint.sh (a shim that starts
// this file through bin/ac-bun.sh); THIS header is the authoritative spec, and
// the bash original it replaced stays frozen at tests/fixtures/ac-lint.sh as
// the oracle the differential leg of tests/sh/ac-lint.test.sh holds this
// module to.
//
// Usage: ac-lint.sh [--all]
//   By DEFAULT only the CHANGED files of the set are linted - staged, unstaged
//   and untracked vs HEAD - so an edit-lint cycle stays fast; `--all` lints
//   the whole set (the pre-release / CI sweep). Outside a git repo it falls
//   back to the whole set; with no HEAD yet it lints the untracked files. A
//   clean tree lints nothing and exits 0. Set AC_LINT_ALLOW_MISSING=1 to
//   tolerate a missing shellcheck locally.
//
// THE CHECKOUT is the one the shim's bin/ sits in PHYSICALLY: bin/ac-bun.sh
// starts bun in the physical parent of its own directory and this module
// lints the root of the bin/ it was started in (STARTED_BIN, src/lib.ts) - so
// a copy of bin/ac-lint.sh with bin/ac-bun.sh beside it and src/ linked lints
// the copy's tree. Every path below is relative to that root, where every
// child runs; the caller's cwd is never read.
//
// ARGUMENTS: only the first is read: `--all`; `-h`/`--help` prints this
// header on stdout, exit 0; absent or "" is the default; anything else is
// `ac-lint.sh: unknown arg: <arg> (use --all)` on stderr, exit 2. stdin is
// never read.
//
// THE SET is the original's `case` over a relative path - `*` crosses `/` and
// a dot name is no special case: bin/*.sh, tests/sh/*.test.sh,
// tests/sh/stress.sh, docs/examples/slack-remote/remote-* (bin/x/y.sh and
// bin/.hidden.sh are in it).
//
// SELECTION:
// - `--all`, or `git rev-parse --git-dir` failing (no repo, no git): the same
//   four patterns expanded as the shell's globs - one level deep, a dot name
//   never matched (W2, kept: a changed bin/.hidden.sh is linted by default and
//   never by --all), each pattern's matches in BYTE order - keeping every name
//   that exists, a directory included.
// - default: the lines of `git diff --name-only --diff-filter=d HEAD` (with no
//   HEAD it fails and adds nothing) and `git ls-files --others
//   --exclude-standard`, stderr dropped, deduped in BYTE order, each kept when
//   it names an existing path in the set. Deletions are excluded and a staged
//   rename lists its new name. git QUOTES a path holding a non-ASCII byte
//   (core.quotePath, on by default) and the quoted spelling names no file, so
//   such a change is never linted by default and is by --all (W1, kept).
// - nothing selected: `ac-lint: no changed lint targets (use --all to lint
//   everything)` on stdout, exit 0 - for --all over an empty set too.
//
// CHECKS, in selection order, one child at a time with stdio inherited:
// `bash -n <file>` (the PATH bash); any non-zero status - a syntax error, an
// unreadable file, a directory (W3, kept: all three read `syntax error`) -
// prints `syntax error: <file>` on stderr after the child's own lines and
// fails the lint. Then, when `command -v shellcheck` finds it (commandV,
// src/lib.ts, bash's own PATH search: a found entry that is not executable
// counts, and then fails to run), ONE `shellcheck -x -P SCRIPTDIR
// <files...>`; a non-zero status fails the lint. Not found: `shellcheck not
// found (install it, or set AC_LINT_ALLOW_MISSING=1)` on stderr and a
// failure, unless AC_LINT_ALLOW_MISSING is exactly 1. bash -n runs for every
// file, and shellcheck runs even when every bash -n failed.
//
// Findings are enforced down to INFO level, and that set MOVES between
// releases: 0.11 dropped SC2015 (`A && B || C`), which older builds still emit
// across seven files here, plus SC2119/SC2317 in four more. The definition
// assumes 0.11+; an older local build will report findings this repo does not
// consider defects. A comment line in a linted script may not BEGIN with the
// linter's own name: that prefix is its directive syntax, so the sentence is
// parsed as a directive and dies SC1073 while `bash -n` waves it through.
//
// EXIT: 0 clean; 1 any failure above; 2 usage.
//
// DIVERGENCES from the original, named in the differential leg: -h prints
// THIS header where the original printed its bash header; the checkout is
// the PHYSICAL one where the original cd'd to
// `$(dirname "$0")/..` LOGICALLY - run through a fleet home's symlinked bin/
// it linted the HOME (no repo, so the whole set through the link), the port
// lints the checkout behind the link; BYTE order replaces the original's
// `sort -u` and glob order under the operator's locale (the same under
// LC_ALL=C); when a found shellcheck cannot run, the shell's own `Permission
// denied` line is not reproduced, the failure is; without bun the shim
// refuses with `ERROR: required tool not found: bun`, exit 1, where the
// original needed none. An argument that is not UTF-8 reaches this module as
// U+FFFD, and the unknown-arg line prints that character.
//
// CALLERS: humans, opt-in by captain ruling (AGENTS.md section 13); the
// bootstrap doctor only names it; no `set -e` caller runs it, so nothing
// fails soft.
import { existsSync, readdirSync, readFileSync, writeSync } from "node:fs";
import { dirname } from "node:path";
import { commandV, enterCaller, spawnShellSync, STARTED_BIN } from "./lib.ts";

const say = (fd: number, line: string): void => {
  writeSync(fd, Buffer.from(`${line}\n`, "utf8"));
};
const byteOrder = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(0);
}

const inLintSet = (f: string): boolean =>
  /^bin\/.*\.sh$/s.test(f) || /^tests\/sh\/.*\.test\.sh$/s.test(f) || f === "tests/sh/stress.sh" || /^docs\/examples\/slack-remote\/remote-/.test(f);

function glob(dir: string, match: (name: string) => boolean): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names.filter((n) => !n.startsWith(".") && match(n)).sort(byteOrder).map((n) => `${dir}/${n}`);
}

function run(argv: string[], stdout: "inherit" | "ignore" | "pipe"): { ok: boolean; out: string } {
  try {
    const r = spawnShellSync(argv, { stdin: "inherit", stdout, stderr: stdout === "inherit" ? "inherit" : "ignore" });
    return { ok: r.exitCode === 0, out: stdout === "pipe" ? r.stdout.toString("utf8") : "" };
  } catch {
    return { ok: false, out: "" };
  }
}

const { args } = enterCaller(process.argv.slice(2));
process.chdir(dirname(STARTED_BIN));

let all = false;
const a = args[0] ?? "";
if (a === "--all") all = true;
else if (a === "-h" || a === "--help") usage();
else if (a !== "") {
  say(2, `ac-lint.sh: unknown arg: ${a} (use --all)`);
  process.exit(2);
}

let files: string[];
if (all || !run(["git", "rev-parse", "--git-dir"], "ignore").ok) {
  files = [
    ...glob("bin", (n) => n.endsWith(".sh")),
    ...glob("tests/sh", (n) => n.endsWith(".test.sh")),
    "tests/sh/stress.sh",
    ...glob("docs/examples/slack-remote", (n) => n.startsWith("remote-")),
  ].filter((f) => existsSync(f));
} else {
  const listed = run(["git", "diff", "--name-only", "--diff-filter=d", "HEAD"], "pipe").out + run(["git", "ls-files", "--others", "--exclude-standard"], "pipe").out;
  files = [...new Set(listed.split("\n"))].sort(byteOrder).filter((f) => f !== "" && existsSync(f) && inLintSet(f));
}

if (files.length === 0) {
  say(1, "ac-lint: no changed lint targets (use --all to lint everything)");
  process.exit(0);
}

let rc = 0;
for (const f of files) {
  if (!run(["bash", "-n", f], "inherit").ok) {
    say(2, `syntax error: ${f}`);
    rc = 1;
  }
}

if (commandV("shellcheck")) {
  if (!run(["shellcheck", "-x", "-P", "SCRIPTDIR", ...files], "inherit").ok) rc = 1;
} else if ((process.env.AC_LINT_ALLOW_MISSING || "0") !== "1") {
  say(2, "shellcheck not found (install it, or set AC_LINT_ALLOW_MISSING=1)");
  rc = 1;
}
process.exit(rc);
