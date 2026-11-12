// project-mode.ts - resolve a project's YOLO flag from records/projects.md.
// The entry is bin/ac-project-mode.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and
// tests/sh/ac-project-mode.test.sh is its contract test. The ac-lib.sh helper
// the bash original wrapped, ac_project_mode, had no other caller and was
// retired with the port; the read lives here whole.
//
//   ac-project-mode.sh <project-name>
//
// Output: one line, `yolo=on` or `yolo=off`. Exit 0 on every answer path; the
// only refusal is a missing or empty name: `ERROR: usage: ac-project-mode.sh
// <project-name>` on stderr, exit 1. There is no -h/--help - every word is a
// project name - and every argument past the first is ignored. stdin is never
// read.
//
// records/projects.md line format (one project per line):
//   - <name> [+yolo] - <one-line description> (added <date>)
// `+yolo` lets the orchestrator self-approve routine decisions for that
// project. DELIVERY MODE IS NOT ANSWERED HERE (mode is per-task, fixed
// policy: recorded as the backlog row's contract token `mode:<m>` and
// resolved by ac-brief.sh - pin > --mode flag > refuse, never a registry
// default). A legacy `[<mode>]` bracket on a registry line is tolerated and
// IGNORED so old registries keep resolving yolo without a migration.
//
// The read: the row is the FIRST line of
// `grep -E "^- <name> \[" <records>/projects.md` (the name is operator text
// in that ERE, so `a.b` answers for a row `- aXb [...]` and `a|gamma` reads
// `^- a` OR `gamma \[`; an ERE grep refuses, or an unreadable registry, is a
// silent no-row - grep's stderr is dropped, its status ignored); the bracket is
// `sed -n 's/^- [^[]*\[\([^]]*\)\].*/\1/p'` over that line (the text between
// the first `[` and the first `]` after it, so `[[+yolo]]` yields `[+yolo`
// and `[a] [+yolo]` yields `a`); yolo is on iff the bracket contains the
// substring `+yolo`, case-sensitive. The ERE wants exactly one space before
// `[`; a CR is an ordinary byte. Both tools are spawned, this host's own,
// under the caller's locale, so every reading below is theirs:
// - a NUL byte where this host's grep looks for one (2.6.0-FreeBSD samples
//   the start of the file) makes it print `Binary file ... matches` instead
//   of the row, so every project answers off; a NUL far past that sample
//   leaves the earlier rows matching;
// - a byte that is not valid UTF-8 on the MATCHED row under a UTF-8 locale
//   aborts BSD sed (`sed: RE error: illegal byte sequence` on stderr) and the
//   run exits with sed's status (1) and NO answer; under LC_ALL=C the row
//   answers normally;
// - a NAME carrying such a byte never matches: Bun's argv decodes it to
//   U+FFFD, so the grep pattern cannot carry the row's bytes and the answer is
//   off.
// No registry file (or a directory there), an empty file, no row: off. The
// records/ dir is minted by the read with the same spawned `mkdir -p`, so a
// records that is a regular file prints mkdir's own line and leaves
// `/projects.md` to read: off.
//
// Without AC_HOME the run prints ac_home's refusal (`ERROR: AC_HOME is not set
// - ...`) and goes on: the path left to read is `/projects.md`, read as any
// registry, and the run answers off with exit 0 - the bash original's reading,
// kept, including the path. An AC_HOME that cannot be entered reads the same
// path silently. The home is entered as physicalDir enters it, the twin every
// port binds its home by, so it is the directory AC_HOME names: one whose NAME
// ends in LF is never its sibling without the LF, and a relative one is
// entered without CDPATH.
//
// The one caller, bin/ac-spawn.sh, already defaults `|| printf 'yolo=off\n'`
// and drops stderr, so nothing there changed with the port.
import { statSync, writeSync } from "node:fs";
import { die, enterCaller, NO_HOME, physicalDir, spawnShellSync } from "./lib.ts";

const { args } = enterCaller(process.argv.slice(2));
const name = args[0] ?? "";
if (!name) die("usage: ac-project-mode.sh <project-name>");

let reg = "/projects.md";
if (!process.env.AC_HOME) writeSync(2, `ERROR: ${NO_HOME}\n`);
else {
  const home = physicalDir(process.env.AC_HOME);
  if (home !== null) {
    // mkdir itself, behind ac_records_dir's own directory check: its line on a
    // failure, and the substitution that died there left `/projects.md` to read.
    const records = `${home}/records`;
    let made = true;
    try {
      if (!statSync(records).isDirectory()) throw 0;
    } catch {
      try {
        made = spawnShellSync(["mkdir", "-p", records], { stdout: "ignore", stderr: "inherit" }).exitCode === 0;
      } catch {
        made = false;
      }
    }
    if (made) reg = `${records}/projects.md`;
  }
}

const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

let bracket = "";
if (isFile(reg)) {
  let line = "";
  try {
    line = spawnShellSync(["grep", "-E", `^- ${name} \\[`, reg], { stdout: "pipe", stderr: "ignore" }).stdout.toString("latin1").split("\n")[0];
  } catch {}
  if (line !== "") {
    let r: { exitCode: number | null; stdout: Buffer };
    try {
      r = spawnShellSync(["sed", "-n", "s/^- [^[]*\\[\\([^]]*\\)\\].*/\\1/p"], { stdin: Buffer.from(`${line}\n`, "latin1"), stdout: "pipe", stderr: "inherit" });
    } catch {
      r = { exitCode: 127, stdout: Buffer.alloc(0) };
    }
    // The original's `bracket="$(...)"` is errexit-fatal with sed's status.
    if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
    bracket = r.stdout.toString("latin1").replace(/\n+$/, "");
  }
}

writeSync(1, `yolo=${bracket.includes("+yolo") ? "on" : "off"}\n`);
