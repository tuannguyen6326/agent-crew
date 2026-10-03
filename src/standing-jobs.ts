// standing-jobs.ts - render the standing-jobs digest block for the
// session-start digest: reports each DECLARED job's state from
// records/standing-jobs.md, with the exact re-create action. The entry is
// bin/ac-standing-jobs.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-standing-jobs.sh as the oracle
// the differential leg of tests/sh/ac-standing-jobs.test.sh holds this module
// to.
//
// CronCreate is SESSION-ONLY: the job lives in harness session memory, is
// never written to disk, and dies with the session (the CronCreate tool's own
// session-only contract). There is therefore no on-disk signal this module can
// read to tell whether a declared job is actually alive THIS session - so it
// never claims PRESENT/MISSING. It reports the DECLARED state (on/off) plus
// the exact re-create action, and tells the chief to run CronList to confirm
// actual liveness. A digest line that claimed a job was live when it cannot
// know that would be a worse defect than the invisible-cron failure this
// exists to surface.
//
// records/standing-jobs.md is the machine-readable source of truth for a
// job's current declared state - a fleet's captain.md should CITE it rather
// than duplicate cadence/on-off/re-create text, which would drift.
//
// Line format (one job per line):
//   - <id> [on|off] cadence:<cadence> recreate:<exact re-create action>
// Mirrors the records/projects.md bracket grammar (ac_project_mode). A job
// line starts with `- ` and holds a `[` with a `]` somewhere after it. The id
// is the run of non-space bytes after `- ` and NEEDS a space after it (a
// line `- foo[x]` is a job line with no id: counted, never printed); the
// state is the first `[...]` group; the cadence is the text between the last
// `cadence:` that has a ` recreate:` after it and the last ` recreate:` (""
// without one); the re-create action is everything after the last
// `recreate:` ("" when absent).
//
// Usage: ac-standing-jobs.sh [--ids]
//
// Only the first argument is read: `--ids` or nothing; anything else is
//   ERROR: usage: ac-standing-jobs.sh [--ids]      (stderr, exit 1)
//
// Digest (no argument), stdout, exit 0:
//   -- standing jobs --
//   (no standing-jobs declaration - records/standing-jobs.md)   file absent or empty
//   <id>: declared ON (cadence: <cadence>) - runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing: <recreate>
//   <id>: declared OFF - do not re-create (<recreate>)
//   <id>: unknown declared state [<state>] in records/standing-jobs.md - fix the line
//   (records/standing-jobs.md has no declared job lines)        non-empty file, no job line
// The header is printed BEFORE the home is resolved, so a missing AC_HOME
// refuses (exit 1) under it; a present file this process cannot read renders
// as a file with no job lines, exit 0 - the digest is prose a human reads.
//
// --ids prints one declared id per line, in file order, and nothing else - no
// header, no grading; absent or empty file: nothing, exit 0. It exists so the
// OTHER reader of this grammar (bin/ac-rig.sh's standing_jobs class) never
// re-derives the id itself: the grammar has exactly one parser, in the file
// AGENTS.md section 2 names as its owner, which is what section 13's
// one-contract-one-file rule requires. A present file it cannot read is
//   ERROR: records/standing-jobs.md is not readable - refusing to report an empty id set   (exit 1)
// because its consumer cannot tell an empty set from "no jobs declared".
// Both modes walk the SAME loop and the same line selection, so there is no
// second copy to drift.
//
// Always prints its "-- standing jobs --" header, unlike the pool-health
// ride-along which stays silent when healthy: a standing job with no
// declaration on disk is exactly the invisible-cron failure this exists to
// surface, so silence here would recreate the defect it fixes.
//
// Bytes in, bytes out: the file is read as latin1 and every id, state,
// cadence and action is written back as the same bytes. The file is read the
// way `while IFS= read -r line` read it - an unterminated last line is NOT a
// line (a hand-edited file without a final newline loses its last job in both
// modes), a CR before the LF stays inside the last field, and a NUL byte ends
// the line. Two declared divergences from the original: a byte that is not
// valid UTF-8 is parsed as a byte whatever the caller's locale, where BSD sed
// under a UTF-8 locale aborted the original mid-output (exit 1); and a digest
// over a present file this process cannot read says nothing on stderr, where
// the original's stderr was bash's own redirect error.
import { accessSync, constants, readFileSync, statSync, writeSync } from "node:fs";
import { join } from "node:path";
import { die, enterCaller, recordsDir } from "./lib.ts";

export function readLines(buf: Buffer): string[] {
  const text = buf.toString("latin1");
  const parts = text.split("\n");
  parts.pop();
  return parts.map((l) => l.split("\0")[0]);
}

export function isJobLine(line: string): boolean {
  if (!line.startsWith("- ")) return false;
  const open = line.indexOf("[", 2);
  return open >= 0 && line.indexOf("]", open + 1) >= 0;
}

export function jobFields(line: string): { id: string; state: string; cadence: string; recreate: string } {
  const pick = (re: RegExp): string => line.match(re)?.[1] ?? "";
  return {
    id: pick(/^- ([^ ]*) /s),
    state: pick(/^- [^[]*\[([^\]]*)\]/s),
    cadence: pick(/.*cadence:(.*) recreate:/s),
    recreate: pick(/.*recreate:(.*)$/s),
  };
}

const say = (s: string) => writeSync(1, Buffer.from(s, "latin1"));

function main(args: string[]): void {
  let ids = false;
  if (args[0] === "--ids") ids = true;
  else if (args[0] !== undefined && args[0] !== "") die("usage: ac-standing-jobs.sh [--ids]");

  if (!ids) say("-- standing jobs --\n");

  const f = join(recordsDir(), "standing-jobs.md");
  let size = 0;
  try {
    size = statSync(f).size;
  } catch {}
  if (size === 0) {
    if (!ids) say("(no standing-jobs declaration - records/standing-jobs.md)\n");
    return;
  }
  if (ids) {
    try {
      accessSync(f, constants.R_OK);
    } catch {
      die("records/standing-jobs.md is not readable - refusing to report an empty id set");
    }
  }

  let buf = Buffer.alloc(0);
  try {
    buf = readFileSync(f);
  } catch {}
  let found = false;
  for (const line of readLines(buf)) {
    if (!isJobLine(line)) continue;
    found = true;
    const { id, state, cadence, recreate } = jobFields(line);
    if (id === "") continue;
    if (ids) say(`${id}\n`);
    else if (state === "on")
      say(`${id}: declared ON (cadence: ${cadence}) - runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing: ${recreate}\n`);
    else if (state === "off") say(`${id}: declared OFF - do not re-create (${recreate})\n`);
    else say(`${id}: unknown declared state [${state}] in records/standing-jobs.md - fix the line\n`);
  }
  if (!ids && !found) say("(records/standing-jobs.md has no declared job lines)\n");
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  main(args);
}
