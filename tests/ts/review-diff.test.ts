// review-diff.test.ts - the lib.ts twins src/review-diff.ts introduced, held to
// their bash originals differentially: familyOfId against ac_family_of_id (the
// stage-dir existence rules, the bare and staged revision arms, the homeless
// refusal), crewBranch against ac_crew_branch, and epicBaseFor against
// ac_epic_base_for over a real ledger (first row per id, the longest-prefix
// walk, epic before feature before the row id, a retired record falling
// through, an unreadable ledger as rc 2, awk's -v escapes on the id). The CLI
// contract itself (every mode, stdout, stderr, exit) is
// tests/sh/ac-review-diff.test.sh's, whose differential leg runs the frozen
// bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crewBranch, epicBaseFor, familyOfId } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const made: string[] = [];
afterAll(() => {
  delete process.env.AC_HOME;
  made.forEach((d) => rmSync(d, { recursive: true, force: true }));
});

function freshHome(): string {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-review-diff-")));
  made.push(h);
  process.env.AC_HOME = h;
  return h;
}

// The bash side as every caller reads it: inside `$(...)`, so the trailing
// newline is dropped; stderr is kept whole so a refusal printed on the way is
// pinned too. AC_HOME is passed through only when set.
function bashLib(fn: string, args: string[]): { out: string; err: string; rc: number } {
  const env: Record<string, string> = { PATH: process.env.PATH! };
  if (process.env.AC_HOME) env.AC_HOME = process.env.AC_HOME;
  const r = Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; ${fn} "\${@:2}"`, "--", binDir, ...args], { env, stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1").replace(/\n$/, ""), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

// The twin's stderr, captured through a bun child so writeSync(2) is seen.
function twinStderr(expr: string): string {
  const env: Record<string, string> = { PATH: process.env.PATH! };
  if (process.env.AC_HOME) env.AC_HOME = process.env.AC_HOME;
  const r = Bun.spawnSync([process.execPath, "-e", `import { familyOfId, epicBaseFor } from "${join(import.meta.dir, "..", "..", "src", "lib.ts")}"; process.stdout.write(String(${expr}));`], { env, stdout: "pipe", stderr: "pipe" });
  return r.stderr.toString("latin1");
}

test("familyOfId and crewBranch resolve what ac_family_of_id and ac_crew_branch resolve: stage dirs on disk decide a plain suffix, revisions keep their family", () => {
  const h = freshHome();
  mkdirSync(join(h, "data", "foo", "spec"), { recursive: true });
  mkdirSync(join(h, "data", "bar", "ship"), { recursive: true });
  mkdirSync(join(h, "data", "cf", "chief"), { recursive: true });
  const ids = [
    "foo", "foo-r2", "foo-r12", "foo-spec", "foo-spec-r2", "foo-arch", "foo-arch-r3", "dash-review", "dash-review-r2",
    "bar-ship", "bar-ship-r1", "c1-ship", "c1-r2", "c1-spec-r2", "foo-chief", "cf-chief", "real-second-chief",
    "-spec", "spec", "a-b-c-qa", "x-r123", "x-r0", "foo-r-spec-r2", "e1-s1-x", "",
  ];
  for (const id of ids) {
    const fam = bashLib("ac_family_of_id", [id]);
    expect({ id, fam: familyOfId(id), rc: fam.rc }).toEqual({ id, fam: fam.out, rc: 0 });
    expect({ id, branch: crewBranch(id) }).toEqual({ id, branch: bashLib("ac_crew_branch", [id]).out });
  }
  expect(familyOfId("foo-spec")).toBe("foo");
  expect(familyOfId("foo-spec-r2")).toBe("foo");
  expect(familyOfId("dash-review")).toBe("dash-review");
  expect(familyOfId("dash-review-r2")).toBe("dash-review");
  expect(familyOfId("c1-ship")).toBe("c1-ship");
  expect(familyOfId("c1-r2")).toBe("c1");
  expect(familyOfId("cf-chief")).toBe("cf");
  expect(crewBranch("foo-r2")).toBe("crew/foo");
});

test("familyOfId homeless prints the AC_HOME refusal where the bash's `[ -d $(ac_data_dir)/... ]` did, and goes on with the id", () => {
  delete process.env.AC_HOME;
  for (const id of ["c1-ship", "c1-spec-r2", "c1", "c1-r2"]) {
    const want = bashLib("ac_family_of_id", [id]);
    expect({ id, fam: familyOfId(id) }).toEqual({ id, fam: want.out });
    expect({ id, err: twinStderr(`familyOfId(${JSON.stringify(id)})`) }).toEqual({ id, err: want.err });
  }
  expect(bashLib("ac_family_of_id", ["c1-ship"]).err).toContain("ERROR: AC_HOME is not set");
  expect(bashLib("ac_family_of_id", ["c1"]).err).toBe("");
});

function ledger(home: string, body: string): void {
  mkdirSync(join(home, "records"), { recursive: true });
  writeFileSync(join(home, "records", "backlog.md"), body, "latin1");
}
function record(home: string, epic: string, body: string): void {
  mkdirSync(join(home, "data", epic), { recursive: true });
  writeFileSync(join(home, "data", epic, "branches"), body, "latin1");
}
function sameBase(id: string, repo: string): ReturnType<typeof epicBaseFor> {
  const want = bashLib("ac_epic_base_for", [id, repo]);
  const got = epicBaseFor(id, repo);
  expect({ id, repo, rc: got.rc, entry: got.rc === 0 ? got.entry : "" }).toEqual({ id, repo, rc: want.rc, entry: want.out });
  return got;
}

test("epicBaseFor resolves what ac_epic_base_for resolves: the longest id prefix with a row, epic before feature before the row id, first row per id, a retired record falls through", () => {
  const h = freshHome();
  expect(sameBase("e1-s1", "proj")).toEqual({ rc: 1 });
  ledger(h, "");
  expect(sameBase("e1-s1", "proj")).toEqual({ rc: 1 });
  ledger(
    h,
    [
      "# ledger",
      "- [ ] e1 [EPIC] - the epic (repo: proj)",
      "- [ ] e1-s1 - story one; epic:e1 (repo: proj)",
      "- [ ] e1-s2 - story two; epic:e1 feature:f1 (repo: proj)",
      "- [ ] e1-s3 - story three; feature:f1 (repo: proj)",
      "- [ ] dup - first; epic:e1 (repo: proj)",
      "- [ ] dup - second; epic:ret (repo: proj)",
      "- [x] e1-s4 - landed; epic:ret (repo: proj)",
      "- [ ] plain - no token (repo: proj)",
      "- [ ] nul - prose\0junk epic:e1 (repo: proj)",
      "- [ ] own - its own record (repo: proj)",
      "- [ ]  - an empty id; epic:e1 (repo: proj)",
      "not a row; epic:e1",
      "- [ ] crlf - a CR row; epic:e1\r",
      "- [ ] 07 - numeric; epic:e1 (repo: proj)",
      "- [ ] last - unterminated; epic:e1 (repo: proj)",
    ].join("\n"),
  );
  record(h, "e1", "proj epic/e1 push=yes\nother epic/x\n");
  record(h, "f1", "proj feat/f1 push=deferred\n");
  record(h, "ret", "# retired 2026-01-01T00:00:00Z\nproj epic/ret\n");
  record(h, "own", "proj epic/own\n");
  record(h, "e1-s1", "proj epic/story\n");
  for (const [id, repo] of [
    ["e1", "proj"], ["e1-s1", "proj"], ["e1-s1-x", "proj"], ["e1-s1-x-y-z", "proj"], ["e1-s2", "proj"], ["e1-s2", "other"], ["e1-s3", "proj"],
    ["e1-s4", "proj"], ["e1-s4-sub", "proj"], ["dup", "proj"], ["plain", "proj"], ["plain-x", "proj"], ["nul", "proj"], ["own", "proj"],
    ["own-x", "proj"], ["nosuch", "proj"], ["no-such", "proj"], ["-", "proj"], ["crlf", "proj"], ["7", "proj"], ["07", "proj"], ["last", "proj"],
    ["e1", "nosuchrepo"], ["", "proj"], ["-x", "proj"],
  ] as [string, string][]) {
    sameBase(id, repo);
  }
  expect(epicBaseFor("e1-s1-x", "proj")).toEqual({ rc: 0, entry: "epic/e1 push=yes" });
  expect(epicBaseFor("e1-s2", "proj")).toEqual({ rc: 0, entry: "epic/e1 push=yes" });
  expect(epicBaseFor("e1-s2", "other")).toEqual({ rc: 0, entry: "epic/x" });
  expect(epicBaseFor("e1-s3", "proj")).toEqual({ rc: 0, entry: "feat/f1 push=deferred" });
  expect(epicBaseFor("e1-s4", "proj")).toEqual({ rc: 1 });
  expect(epicBaseFor("dup", "proj")).toEqual({ rc: 0, entry: "epic/e1 push=yes" });
  expect(epicBaseFor("own-x", "proj")).toEqual({ rc: 0, entry: "epic/own" });
  expect(epicBaseFor("nul", "proj")).toEqual({ rc: 1 });
  expect(epicBaseFor("07", "proj")).toEqual({ rc: 0, entry: "epic/e1 push=yes" });
  expect(epicBaseFor("7", "proj")).toEqual({ rc: 1 });
});

test("epicBaseFor reads the id as awk -v read it: `\\-` is a dash, `\\q` is q, octal is a byte, a NUL cuts it (the bash's wire, kept)", () => {
  const h = freshHome();
  ledger(h, "- [ ] e1-s1 - story; epic:e1 (repo: proj)\n- [ ] eq - q; epic:e1 (repo: proj)\n- [ ] A - octal; epic:e1 (repo: proj)\n");
  record(h, "e1", "proj epic/e1\n");
  for (const id of ["e1\\-s1", "e1\\-s1-x", "e\\q", "\\101", "e1-s1\\0zz", "e1-s1\\", "e1\\\\-s1", "e1\\ts1", "e1-s1\\0zz\\", "\\0\\"]) sameBase(id, "proj");
  // An escaped NUL cuts the string even when a lone backslash ends it.
  expect(epicBaseFor("e1-s1\\0zz\\", "proj")).toEqual({ rc: 0, entry: "epic/e1" });
  expect(epicBaseFor("e1\\-s1", "proj")).toEqual({ rc: 0, entry: "epic/e1" });
  expect(epicBaseFor("e\\q", "proj")).toEqual({ rc: 0, entry: "epic/e1" });
  expect(epicBaseFor("\\101", "proj")).toEqual({ rc: 0, entry: "epic/e1" });
  expect(epicBaseFor("e1\\\\-s1", "proj")).toEqual({ rc: 1 });
});

test("epicBaseFor answers rc 2 for a ledger that is there but cannot be read, rc 1 for one that is a directory", () => {
  const h = freshHome();
  mkdirSync(join(h, "records", "backlog.md"), { recursive: true });
  expect(sameBase("e1-s1", "proj")).toEqual({ rc: 1 });
  rmSync(join(h, "records", "backlog.md"), { recursive: true });
  ledger(h, "- [ ] e1-s1 - story; epic:e1 (repo: proj)\n");
  record(h, "e1", "proj epic/e1\n");
  expect(sameBase("e1-s1", "proj")).toEqual({ rc: 0, entry: "epic/e1" });
  if (process.getuid?.() === 0) return;
  chmodSync(join(h, "records", "backlog.md"), 0o000);
  expect(sameBase("e1-s1", "proj")).toEqual({ rc: 2 });
  chmodSync(join(h, "records", "backlog.md"), 0o644);
});

test("epicBaseFor homeless is rc 1 and says nothing - the refusal ac_records_dir printed inside the bash's `$(...)` is not reproduced (named divergence: the one live caller drops that stderr)", () => {
  delete process.env.AC_HOME;
  const want = bashLib("ac_epic_base_for", ["e1-s1", "proj"]);
  expect(want.rc).toBe(1);
  expect(want.err).toContain("ERROR: AC_HOME is not set");
  expect(epicBaseFor("e1-s1", "proj")).toEqual({ rc: 1 });
  expect(twinStderr('epicBaseFor("e1-s1", "proj").rc')).toBe("");
});
