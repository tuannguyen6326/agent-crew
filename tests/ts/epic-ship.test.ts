// epic-ship.test.ts - src/epic-ship.ts's two ledger filters (storyRows,
// epicContract) held to the awk programs of the frozen original
// (tests/fixtures/ac-epic-ship.sh), run through the AC_DONELINE_AWK binding
// over the same ledger. The CLI contract itself is tests/sh/ac-epic-ship.test.sh's,
// whose differential leg runs that original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { epicContract, storyRows } from "../../src/epic-ship.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const home = realpathSync(mkdtempSync(join(tmpdir(), "ac-epic-ship-")));
afterAll(() => rmSync(home, { recursive: true, force: true }));

function bash(script: string, args: string[]): string {
  const r = Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; shift; ${script}`, "--", binDir, ...args], {
    env: { PATH: process.env.PATH!, LC_ALL: "C", AC_HOME: home },
    stdout: "pipe",
    stderr: "pipe",
  });
  expect(r.stderr.toString()).toBe("");
  return r.stdout.toString("latin1");
}

const STORY_AWK = `LC_ALL=C awk "$AC_DONELINE_AWK"'index($0, "- [") == 1 { ac_doneline($0, f); print f["id"] "\\t" f["epic"] "\\t" f["terminal"] "\\t" $0 }' "$1"`;
const EPIC_AWK = `LC_ALL=C awk -v want="$2" "$AC_DONELINE_AWK"'
  BEGIN { w[want] }
  /^- \\[/ { ac_doneline($0, f); if (f["id"] in w) { print f["contract"]; exit } }' "$1"`;

const LEDGER = [
  "# Backlog",
  "- [x] s0 - rows above the first section count too; epic:e",
  "## In flight",
  "- [ ] e [EPIC] [src:cap flow:direct mode:direct-pr rev:no\tqa:yes] - the epic (repo: p)",
  "- [ ] s1 - open story; epic:e (repo: p)",
  "- [X] s2 - a capital X is no checkbox; epic:e",
  "- [~] s2b - nor a tilde; epic:e",
  "- [ ]s2c - nor a box with no space; epic:e",
  "- [x] s3 - landed\0 epic:e nul cuts the record",
  "- [x] s4 - landed; epic:e\r",
  "  - [ ] indented - no row; epic:e",
  "* [ ] starred - no row; epic:e",
  "## Queued",
  "- [ ] s5 [failed] - an open box with a terminal token; epic:e",
  "- [ ] 07 [src:cap qa:no] - numeric; epic:7",
  "- [ ] 7 [src:cap qa:yes] - numeric epic",
  "- [ ] q\\x [src:cap qa:yes] - backslash id",
  "- [ ] qx [src:cap qa:no] - what awk -v makes of q\\x",
  "## Done",
  "- [x] s6 [abandoned] - dead; epic:e",
  "- [x] s7 [failed] - dead; epic:e feature:f",
  "- [x] e - the epic landing early; epic:e",
  "- [x] s8 - epic:E case differs",
  "- [x] s9* [failed] - a pattern id; epic:e",
  "- [ ]",
  "- [ ] s10 - unterminated last line; epic:e",
].join("\n");

const ledgerFile = (() => {
  mkdirSync(join(home, "records"), { recursive: true });
  const f = join(home, "records", "backlog.md");
  writeFileSync(f, LEDGER, "latin1");
  return f;
})();

test("storyRows reads what the story awk read: every `- [` record in every section, the line NUL-cut, an unterminated last line included", () => {
  const got = storyRows(LEDGER)
    .map((r) => `${r.id}\t${r.epic}\t${r.terminal}\t${r.line}\n`)
    .join("");
  expect(got).toBe(bash(STORY_AWK, [ledgerFile]));
  expect(got).toContain("s10\te\t\t- [ ] s10 - unterminated last line; epic:e\n");
  expect(got).toContain("s3\t\t\t- [x] s3 - landed\n");
  expect(storyRows(LEDGER).filter((r) => r.id === "-").map((r) => r.line.slice(0, 5))).toEqual(["- [X]", "- [~]", "- [ ]", "- [ ]"]);
  expect(storyRows("")).toEqual([]);
});

test("epicContract reads what the epic-row awk read: the FIRST row whose id is the epic by string (never numeric) equality, the want read as awk -v reads it, TABs kept", () => {
  for (const want of ["e", "7", "07", "7.0", "s1", "nosuch", "q\\x", "q\\\\x", "", "s10"])
    expect({ want, got: epicContract(LEDGER, want) }).toEqual({ want, got: bash(EPIC_AWK, [ledgerFile, want]).replace(/\n$/, "") });
  expect(epicContract(LEDGER, "e")).toBe("src:cap flow:direct mode:direct-pr rev:no\tqa:yes");
  expect(epicContract(LEDGER, "7")).toBe("src:cap qa:yes");
  expect(epicContract(LEDGER, "q\\x")).toBe("src:cap qa:no");
});
