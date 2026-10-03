// standing-jobs.test.ts - the local logic src/standing-jobs.ts ported from
// bin/ac-standing-jobs.sh (frozen at tests/fixtures/ac-standing-jobs.sh), held
// to the bash it replaced differentially: the `while IFS= read -r` line
// reader, the case-pattern job-line filter and the three sed field
// extractions, each run by bash over the same bytes. The CLI contract itself
// (both verbs, stdout, stderr, exit) is tests/sh/ac-standing-jobs.test.sh's,
// whose differential leg runs the frozen original beside the shim.
//
// Every bash side runs under LC_ALL=C: that is the byte reading the port
// keeps. Under a UTF-8 locale BSD sed refuses a byte that is not valid UTF-8
// (`RE error: illegal byte sequence`), the outside actor's behaviour the sh
// leg names as the port's one declared divergence.
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isJobLine, jobFields, readLines } from "../../src/standing-jobs.ts";

const dir = mkdtempSync(join(tmpdir(), "ac-standing-jobs-"));
const file = (name: string, body: string): string => {
  const f = join(dir, name);
  writeFileSync(f, Buffer.from(body, "latin1"));
  return f;
};
const bash = (script: string, f: string): string => {
  const r = Bun.spawnSync(["bash", "-c", script, "--", f], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C" },
  });
  expect(r.exitCode).toBe(0);
  expect(r.stderr.length).toBe(0);
  return r.stdout.toString("latin1");
};

const READ_LOOP = 'while IFS= read -r line; do printf \'%s\\n\' "$line"; done <"$1"';
// The original's filter and extractions verbatim, over the one line the file
// holds, each answer on its own line (no value can hold a newline); the
// `$(...)` around each sed is the original's, dropping sed's own newline.
const PARSE = [
  'IFS= read -r line <"$1"',
  'case "$line" in "- "*"["*"]"*) printf \'y\\n\' ;; *) printf \'n\\n\' ;; esac',
  "printf '%s\\n' \"$(sed -n 's/^- \\([^ ]*\\) .*/\\1/p' <<<\"$line\")\"",
  "printf '%s\\n' \"$(sed -n 's/^- [^[]*\\[\\([^]]*\\)\\].*/\\1/p' <<<\"$line\")\"",
  "printf '%s\\n' \"$(sed -n 's/.*cadence:\\(.*\\) recreate:.*/\\1/p' <<<\"$line\")\"",
  "printf '%s\\n' \"$(sed -n 's/.*recreate:\\(.*\\)$/\\1/p' <<<\"$line\")\"",
].join("; ");

test("readLines reads what `while IFS= read -r` reads: an unterminated last line is dropped, CR stays, NUL truncates", () => {
  const cases: Record<string, string> = {
    terminated: "- a [on] cadence:1 recreate:r1\n- b [off] recreate:r2\n",
    unterminated: "- a [on] cadence:1 recreate:r1\n- b [off] recreate:r2",
    onlyUnterminated: "- a [on] cadence:1 recreate:r1",
    blankAndProse: "# title\n\nProse [with] brackets\n\n- a [on] cadence:1 recreate:r1\n",
    crlf: "- a [on] cadence:1 recreate:r1\r\n- b [off] recreate:r2\r\n",
    nulInsideId: "- a\0b [on] cadence:1 recreate:r1\n- c [on] cadence:2\0 recreate:r2\n",
    invalidByte: "- caf\xe9 [on] cadence:x recreate:y\n",
    newlineOnly: "\n",
    empty: "",
  };
  for (const [name, body] of Object.entries(cases)) {
    const f = file(`${name}.md`, body);
    const want = bash(READ_LOOP, f);
    const got = readLines(Buffer.from(body, "latin1"));
    expect(got.map((l) => `${l}\n`).join("")).toBe(want);
  }
});

const LINES = [
  "- alpha-job [on] cadence::07/:37 recreate:CronCreate a job at :07 and :37",
  "- beta-job [off] cadence:every 30 minutes recreate:CronCreate a 30-min job (disabled)",
  "- gamma-job [maybe] cadence:hourly recreate:whatever",
  '- delta-job [on] cadence:30m recreate:CronCreate "*/30 * * * *" -> bin/ac-brain.sh sync --home $AC_HOME --compact',
  "- noSpace[on]",
  "- [x] weird",
  "- tabbed\tid [on] cadence:c recreate:r",
  "- a [on] cadence:x recreate:y recreate:z",
  "- b [on] cadence:p cadence:q recreate:r",
  "- b2 [on] cadence:p recreate:r cadence:q",
  "- c [on] cadence:only",
  "- d [off] recreate:r",
  "- e [] cadence:x recreate:y",
  "- f [on] [off] cadence:x recreate:y",
  "- g [on] cadence:x recreate:",
  "- h [on] cadence: recreate:",
  "- i [on] cadence:x  recreate:y",
  "- j [on] recreate:r cadence:c",
  "-  doubleSpace [on] cadence:x recreate:y",
  "- k [on] cadence:x recreate:y\r",
  "- caf\xe9 [on] cadence:x recreate:y",
  "- ] [ x",
  "- x [no close",
  "- plain",
  " - indented [x]",
  "Prose [with] brackets",
  "-- standing jobs --",
  "",
];

test("isJobLine and jobFields answer what the case pattern and the three sed extractions answer", () => {
  LINES.forEach((line, i) => {
    const f = file(`line${i}.md`, `${line}\n`);
    const [job, id, state, cadence, recreate] = bash(PARSE, f).split("\n");
    expect([line, isJobLine(line)]).toEqual([line, job === "y"]);
    if (job !== "y") return;
    expect([line, jobFields(line)]).toEqual([line, { id, state, cadence, recreate }]);
  });
  rmSync(dir, { recursive: true, force: true });
});
