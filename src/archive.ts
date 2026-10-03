// archive.ts - move CLOSED task families out of the flat data/ namespace. The
// entry is bin/ac-archive.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-archive.sh as the oracle the
// differential leg of tests/sh/ac-archive.test.sh holds this module to.
//
// AUTHORITATIVE for the archive layout and for which families are eligible.
// Where NEW artifacts are created is unchanged and stays owned by
// bin/ac-brief.sh's header: every brief/report/room is still born at
// data/<id>/ or data/<family>/<stage>/. This module only relocates families
// whose story is already over.
//
// Usage:
//   ac-archive.sh archive [--dry-run]            # move every CLOSED family
//   ac-archive.sh restore <family> [--dry-run]   # move one back, live again
//
// LAYOUT: an archived family becomes data/archive/<year>/<family>/, carrying
// its whole task dir verbatim (brief, report, room, nested stage dirs, gate
// artifacts). <year> is the year of the family's OWN last `CLOSED:` room entry -
// never the year the migration runs - so history groups by when it happened and
// re-running next year re-shards nothing.
//
// ELIGIBILITY - exactly one class moves:
//   - data/<family>/room.md contains a `CLOSED:` entry  -> ARCHIVE.
//   - room exists with no `CLOSED:`                     -> skipped, still open.
//   - no room.md at all (bare scouts, self-tasks)       -> skipped. Nothing on
//     disk says they are finished and guessing here loses data; whether they
//     should be archived is a captain question, not this module's.
//   - `CLOSED:` present but no resolvable year          -> REFUSED and named,
//     and the run exits 1. A refusal is never bucketed by a guess and never
//     passes silently.
// An entry is `- [<iso>] <actor>> CLOSED: ...` at the start of a line (the
// room grammar of bin/ac-room.sh's header); a prose mention never closes a
// family, and the year is the LAST such entry's `[YYYY-`. Learning run dirs
// (data/learning-<ts>/) and other roomless dirs are skipped by the same rule,
// with no special case. data/archive/ itself carries no room.md, so it can
// never select itself.
//
// OUTPUT (stdout), one line per selected family in byte order of the family
// names, then one trailer:
//   refused  <fam> - CLOSED: entry carries no resolvable year
//   refused  <fam> - <data>/archive/<year>/<fam> already exists
//   would archive  <fam> -> archive/<year>/<fam>          (dry run)
//   archived  <fam> -> archive/<year>/<fam>
//   would archive <n> family(ies); refused <r>  |  archived <n> family(ies); refused <r>
// restore prints `would restore  <fam> <- archive/<year>/<fam>` (dry run) or
// `restored  <fam>`; a family archived under two years comes back from the
// first year in byte order and the other copy stays. Exit 0; 1 when a family
// was refused (dry run too), on a usage error, a family outside [a-zA-Z0-9_-],
// a family that is not archived, a live data/<family> in restore's way, or no
// AC_HOME (`ERROR: ...` on stderr); 2 with this header on stdout for no verb or
// an unknown verb. Usage and charset are checked before the home is touched.
//
// BYTES AND ORDER: a room is read as bytes and matched per LF-split line (CR
// kept; a NUL ends the line for the year read, as awk's record did), under any
// locale - the bash original's grep, under a UTF-8 locale, missed a CLOSED
// line carrying a non-UTF-8 byte and left that family live, and its glob
// walked data/*/ in libc collation order; both are named in the differential
// leg. The move is `mv`, spawned as the original spawned it (a symlinked
// family moves as the link; a data/ split across devices is copied as mv
// copies), and `mkdir -p` the same way: their failure ends the run as errexit
// did, with the tool's own stderr and status. A room this process cannot
// read is skipped as not closed, the way the original's grep read it.
//
// MANUAL ONLY. Nothing in bin/, .agents/, docs/ or src/ may invoke this entry -
// not ac-curate.sh's CURATE-DUE auto-run, not ac-session-start.sh, not
// ac-wake-drain.sh. Moving hundreds of live directories is a deliberate act the
// crewchief performs when the fleet is quiet: ac-room.sh list, the turn-end
// guard and session-start all sweep data/ continuously, so a migration that can
// fire by itself defeats the split it exists for. tests/sh/ac-archive.test.sh
// asserts the absence of any caller.
//
// IDEMPOTENT: a second run finds no eligible live family and says so. REVERSIBLE:
// `restore` moves a family back to its live path (refusing to clobber an
// existing live dir, and refusing a family that is not archived); an
// archive -> restore round trip is byte-identical.
//
// Reads stay correct across the move: ac_room_file (bin/ac-lib.sh) resolves a
// family's room live-first then archived, which is what keeps
// `ac-room.sh show <family>` and the Learning retro snapshot working on an
// archived family. The live-only data/*/room.md globs (the captain inbox, the
// turn-end guard, the statusline, the remote push) deliberately do NOT follow:
// every archived family is CLOSED, so it contributes no pending item and no
// hand-back to any of them.
import { existsSync, readdirSync, readFileSync, rmdirSync, statSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { dataDir, die, enterCaller } from "./lib.ts";

const CLOSED = /^- \[[^\]]*\] [^>]*> CLOSED:/;
const YEAR = /^- \[[0-9]{4}-/;
const byCodePoint = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const out = (s: string): void => {
  writeSync(1, s);
};
// The tool itself, so its semantics and its failure (status, stderr) are the
// original's: mv across devices copies, mkdir -p on a read-only parent refuses.
const tool = (cmd: string[]): void => {
  const r = Bun.spawnSync(cmd, { stdout: "ignore", stderr: "inherit" });
  if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
};
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};

// The glob `<dir>/*/`: every non-dot entry that is (or links to) a directory.
function subdirs(dir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names.filter((n) => !n.startsWith(".") && isDir(join(dir, n))).sort(byCodePoint);
}

function closedYear(lines: string[]): string {
  let y = "";
  for (const raw of lines) {
    const l = raw.split("\0")[0]!;
    if (YEAR.test(l) && CLOSED.test(l)) y = l.slice(3, 7);
  }
  return y;
}

function cmdArchive(opt: string | undefined): number {
  let dry = false;
  if (opt === "--dry-run") dry = true;
  else if (opt) die("usage: ac-archive.sh archive [--dry-run]");

  const data = dataDir();
  let moved = 0;
  let refused = 0;
  for (const fam of subdirs(data)) {
    if (fam === "archive") continue;
    const room = join(data, fam, "room.md");
    if (!isFile(room)) continue;
    let lines: string[];
    try {
      lines = readFileSync(room, "latin1").split("\n");
    } catch {
      continue;
    }
    if (!lines.some((l) => CLOSED.test(l))) continue;
    const year = closedYear(lines);
    if (!year) {
      out(`refused  ${fam} - CLOSED: entry carries no resolvable year\n`);
      refused++;
      continue;
    }
    const dest = join(data, "archive", year, fam);
    if (existsSync(dest)) {
      out(`refused  ${fam} - ${dest} already exists\n`);
      refused++;
      continue;
    }
    if (dry) {
      out(`would archive  ${fam} -> archive/${year}/${fam}\n`);
    } else {
      tool(["mkdir", "-p", join(data, "archive", year)]);
      tool(["mv", join(data, fam), dest]);
      out(`archived  ${fam} -> archive/${year}/${fam}\n`);
    }
    moved++;
  }
  out(`${dry ? "would archive" : "archived"} ${moved} family(ies); refused ${refused}\n`);
  return refused === 0 ? 0 : 1;
}

function cmdRestore(fam: string | undefined, opt: string | undefined): number {
  if (!fam) die("usage: ac-archive.sh restore <family> [--dry-run]");
  let dry = false;
  if (opt === "--dry-run") dry = true;
  else if (opt) die("usage: ac-archive.sh restore <family> [--dry-run]");
  if (/[^a-zA-Z0-9_-]/.test(fam)) die(`family must be [a-zA-Z0-9_-]: ${fam}`);

  const data = dataDir();
  const archive = join(data, "archive");
  const year = subdirs(archive).find((y) => isDir(join(archive, y, fam)));
  if (year === undefined) die(`restore: ${fam} is not archived`);
  const found = join(archive, year, fam);
  const live = join(data, fam);
  if (existsSync(live)) die(`restore: ${live} already exists - move it aside first`);

  if (dry) {
    out(`would restore  ${fam} <- archive/${year}/${fam}\n`);
    return 0;
  }
  tool(["mv", found, live]);
  // Leave no empty <year> shell behind; rmdir only ever succeeds when the year
  // bucket really is empty, so a concurrent archive is never clobbered.
  try {
    rmdirSync(dirname(found));
  } catch {}
  out(`restored  ${fam}\n`);
  return 0;
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(2);
}

const { args } = enterCaller(process.argv.slice(2));
let rc: number;
switch (args[0]) {
  case "archive":
    rc = cmdArchive(args[1]);
    break;
  case "restore":
    rc = cmdRestore(args[1], args[2]);
    break;
  default:
    usage();
}
process.exit(rc);
