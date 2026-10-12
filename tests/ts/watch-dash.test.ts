// watch-dash.test.ts - the board body's idle clock, held to the FROZEN bash
// body it replaced (tests/fixtures/ac-watch-dash.sh's idle_since, sourced after
// the live ac-lib.sh): the newest mtime of steps.tsv and logs/run.log, a role's
// extra file counted when it exists and tolerated when it does not. The CLI
// contract itself is tests/sh/ac-watch-dash.test.sh's and the two boards'
// suites, whose differential legs run the frozen originals beside the shims.
//
// DISPUTED: the implementation of the idle clock (idle_since in tests/fixtures/ac-watch-dash.sh vs idleSince in src/watch-dash.ts)
// HELD-CONSTANT: one run dir per row with its files' mtimes set by utimes; env (PATH the host's); cwd (the distro root); stdin (/dev/null); the answer compared whole.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { idleSince } from "../../src/watch-dash.ts";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const BODY = join(ROOT, "tests", "fixtures", "ac-watch-dash.sh");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-watch-dash-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

function bashIdle(rd: string, extra: string): string {
  const r = Bun.spawnSync(
    ["/bin/bash", "-c", 'set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$1"; IDLE_EXTRA_FILES="$2"; idle_since "$3"', BIN, BODY, extra, rd],
    { cwd: ROOT, env: { PATH: process.env.PATH! }, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  return r.stdout.toString().replace(/\n+$/, "");
}

const at = (p: string, epoch: number): void => utimesSync(p, epoch, epoch);

test("idleSince answers idle_since: the newest of steps.tsv and run.log, an extra file when it exists", () => {
  const rd = join(W, "idlerd");
  mkdirSync(join(rd, "logs"), { recursive: true });
  writeFileSync(join(rd, "steps.tsv"), "a\n");
  writeFileSync(join(rd, "logs", "run.log"), "b\n");
  at(join(rd, "steps.tsv"), 1767225600);
  at(join(rd, "logs", "run.log"), 1767312000);
  expect(bashIdle(rd, "")).toBe("1767312000");
  expect(idleSince(rd, [])).toBe("1767312000");
  // A missing extra file (qa's cases.tsv before the first case lands) must not
  // break the max-mtime reading.
  expect(bashIdle(rd, "cases.tsv")).toBe("1767312000");
  expect(idleSince(rd, ["cases.tsv"])).toBe("1767312000");
  writeFileSync(join(rd, "cases.tsv"), "c\n");
  at(join(rd, "cases.tsv"), 1767398400);
  expect(bashIdle(rd, "cases.tsv")).toBe("1767398400");
  expect(idleSince(rd, ["cases.tsv"])).toBe("1767398400");
});

test("idleSince of a run dir with none of the files is 0, as idle_since's", () => {
  const rd = join(W, "emptyrd");
  mkdirSync(rd);
  expect(bashIdle(rd, "cases.tsv")).toBe("0");
  expect(idleSince(rd, ["cases.tsv"])).toBe("0");
});
