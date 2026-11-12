// watch-dash.test.ts - the board body's idle clock: the newest mtime of
// steps.tsv and logs/run.log, a role's extra file counted when it exists and
// tolerated when it does not. The CLI contract itself is
// tests/sh/ac-watch-dash.test.sh's and the two boards' suites.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { idleSince } from "../../src/watch-dash.ts";

const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-watch-dash-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

const at = (p: string, epoch: number): void => utimesSync(p, epoch, epoch);

test("idleSince is the newest of steps.tsv and run.log, an extra file when it exists", () => {
  const rd = join(W, "idlerd");
  mkdirSync(join(rd, "logs"), { recursive: true });
  writeFileSync(join(rd, "steps.tsv"), "a\n");
  writeFileSync(join(rd, "logs", "run.log"), "b\n");
  at(join(rd, "steps.tsv"), 1767225600);
  at(join(rd, "logs", "run.log"), 1767312000);
  expect(idleSince(rd, [])).toBe("1767312000");
  // A missing extra file (qa's cases.tsv before the first case lands) must not
  // break the max-mtime reading.
  expect(idleSince(rd, ["cases.tsv"])).toBe("1767312000");
  writeFileSync(join(rd, "cases.tsv"), "c\n");
  at(join(rd, "cases.tsv"), 1767398400);
  expect(idleSince(rd, ["cases.tsv"])).toBe("1767398400");
});

test("idleSince of a run dir with none of the files is 0", () => {
  const rd = join(W, "emptyrd");
  mkdirSync(rd);
  expect(idleSince(rd, ["cases.tsv"])).toBe("0");
});
