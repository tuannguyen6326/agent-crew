// project-mode.ts - resolve a project's YOLO flag from records/projects.md.
// The entry is bin/ac-project-mode.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-project-mode.sh as the oracle
// the differential leg of tests/sh/ac-project-mode.test.sh holds this module
// to. The ac-lib.sh helper the original wrapped, ac_project_mode, had no other
// caller and was retired with the port; the read lives here whole.
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
// The read, exactly the original's: the row is the FIRST line of
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
// - one NUL byte ANYWHERE in the registry makes grep print `Binary file ...
//   matches` instead of the row, so every project answers off;
// - a byte that is not valid UTF-8 on the MATCHED row under a UTF-8 locale
//   aborts BSD sed (`sed: RE error: illegal byte sequence` on stderr) and the
//   run exits with sed's status (1) and NO answer, as the original did; under
//   LC_ALL=C the row answers normally;
// - a NAME carrying such a byte is the one divergence: Bun's argv decodes it
//   to U+FFFD, so the grep pattern can never match the row's bytes and the
//   answer is off where the original's was on.
// No registry file (or a directory there), an empty file, no row: off. The
// records/ dir is minted by the read, as ac_records_dir minted it.
//
// Without AC_HOME the original printed ac_home's refusal (`ERROR: AC_HOME is
// not set - ...`) and went on: the dying `$(ac_records_dir)` left the path
// `/projects.md`, read as any registry, and the run answered off with exit 0
// - kept here, including the path. An AC_HOME that cannot be entered reads
// the same path silently (the original's stderr there was bash's own `cd:`
// line, not reproduced).
//
// The one caller, bin/ac-spawn.sh, already defaults `|| printf 'yolo=off\n'`
// and drops stderr, so nothing there changed with the port.
import { mkdirSync, statSync, writeSync } from "node:fs";
import { die, enterCaller, NO_HOME, physicalDir } from "./lib.ts";

const { args } = enterCaller(process.argv.slice(2));
const name = args[0] ?? "";
if (!name) die("usage: ac-project-mode.sh <project-name>");

let reg = "/projects.md";
if (!process.env.AC_HOME) writeSync(2, `ERROR: ${NO_HOME}\n`);
else {
  const home = physicalDir(process.env.AC_HOME);
  if (home !== null) {
    try {
      mkdirSync(`${home}/records`, { recursive: true });
    } catch {}
    reg = `${home}/records/projects.md`;
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
    line = Bun.spawnSync(["grep", "-E", `^- ${name} \\[`, reg], { stdout: "pipe", stderr: "ignore" }).stdout.toString("latin1").split("\n")[0];
  } catch {}
  if (line !== "") {
    let r: { exitCode: number | null; stdout: Buffer };
    try {
      r = Bun.spawnSync(["sed", "-n", "s/^- [^[]*\\[\\([^]]*\\)\\].*/\\1/p"], { stdin: Buffer.from(`${line}\n`, "latin1"), stdout: "pipe", stderr: "inherit" });
    } catch {
      r = { exitCode: 127, stdout: Buffer.alloc(0) };
    }
    // The original's `bracket="$(...)"` is errexit-fatal with sed's status.
    if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
    bracket = r.stdout.toString("latin1").replace(/\n+$/, "");
  }
}

writeSync(1, `yolo=${bracket.includes("+yolo") ? "on" : "off"}\n`);
