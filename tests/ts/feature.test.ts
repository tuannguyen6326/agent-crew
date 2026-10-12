// feature.test.ts - what src/feature.ts brought into src/, held to its bash
// originals differentially: roomFile (src/lib.ts) against ac_room_file over
// every arm (the live room, the charset guard, the archived copies in byte
// order, the fan-out walk and its restart, the live fallback, homeless), and
// the ship gate's two ledger filters (memberRows, containerContract) against
// the awk programs they replaced, run through the AC_DONELINE_AWK binding over
// the same ledger. The CLI contract itself (every verb, stdout, stderr, exit)
// is tests/sh/ac-feature.test.sh's, whose differential leg runs the frozen
// bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { containerContract, memberRows } from "../../src/feature.ts";
import { roomFile } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const made: string[] = [];
afterAll(() => {
  delete process.env.AC_HOME;
  made.forEach((d) => rmSync(d, { recursive: true, force: true }));
});

function freshHome(): string {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-feature-")));
  made.push(h);
  process.env.AC_HOME = h;
  return h;
}

// The bash side under LC_ALL=C (the leg's ORDER rule: the archive glob in
// byte order), read as its callers read it - inside `$(...)`, the trailing
// newline dropped - with stderr kept whole so a refusal on the way is pinned.
function bash(script: string, args: string[]): { out: string; err: string } {
  const env: Record<string, string> = { PATH: process.env.PATH!, LC_ALL: "C" };
  if (process.env.AC_HOME) env.AC_HOME = process.env.AC_HOME;
  const r = Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; shift; ${script}`, "--", binDir, ...args], { env, stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

// The twin in a bun child, so what it writes to fd 2 is captured too.
function twin(fam: string): { out: string; err: string } {
  const env: Record<string, string> = { PATH: process.env.PATH! };
  if (process.env.AC_HOME) env.AC_HOME = process.env.AC_HOME;
  const lib = join(import.meta.dir, "..", "..", "src", "lib.ts");
  const r = Bun.spawnSync([process.execPath, "-e", `import { roomFile } from "${lib}"; process.stdout.write(roomFile(${JSON.stringify(fam)}));`], { env, stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString(), err: r.stderr.toString("latin1") };
}

function put(home: string, rel: string, body = "x\n"): void {
  mkdirSync(join(home, rel, ".."), { recursive: true });
  writeFileSync(join(home, rel), body);
}

function sameRoom(fam: string): string {
  const want = bash('ac_room_file "$1"', [fam]);
  const got = roomFile(fam);
  // A path is a name: the bash's bytes read as the UTF-8 the twin's strings are.
  expect({ fam, got }).toEqual({ fam, got: Buffer.from(want.out, "latin1").toString("utf8").replace(/\n$/, "") });
  return got;
}

test("roomFile resolves what ac_room_file resolves: live first, the guarded archive glob in byte order, the fan-out walk restarting on the family, else the live path", () => {
  const h = freshHome();
  put(h, "data/live/room.md");
  put(h, "data/both/room.md");
  put(h, "data/archive/2026/both/room.md");
  put(h, "data/archive/a1/arch/room.md");
  put(h, "data/archive/B1/arch/room.md");
  put(h, "data/archive/2026/arch/room.md");
  put(h, "data/archive/a1/ord/room.md");
  put(h, "data/archive/B1/ord/room.md");
  put(h, "data/archive/.hidden/hid/room.md");
  put(h, "data/archive/2026/a.b/room.md");
  mkdirSync(join(h, "data", "dirroom", "room.md"), { recursive: true });
  put(h, "data/archive/2026/dirroom/room.md");
  writeFileSync(join(h, "data", "archive", "afile"), "not a year\n");
  put(h, "data/elsewhere/linked/room.md");
  symlinkSync(join(h, "data", "elsewhere"), join(h, "data", "archive", "zlink"));
  put(h, "data/fam/room.md");
  put(h, "data/fam/tasks/slug/brief.md");
  put(h, "data/fam/tasks/two-part/brief.md");
  put(h, "data/old/tasks/x/brief.md");
  put(h, "data/archive/2025/old/room.md");
  put(h, "data/a-b/tasks/c/brief.md");
  put(h, "data/a/tasks/b-c/brief.md");
  put(h, "data/a/room.md");
  put(h, "data/nest/tasks/kid/brief.md");
  put(h, "data/nest-kid/tasks/sub/brief.md");
  put(h, "data/archive/2026/nest/room.md");
  put(h, "data/archive/2026/room.md");
  for (const fam of [
    "live", "both", "arch", "ord", "hid", "a.b", "dirroom", "linked", "fam", "fam-slug", "fam-two-part", "fam-nope", "old-x", "a-b-c", "nest-kid-sub",
    "nest-kid", "ghost", "ghost-x-y", "bad.name", "../live", "a/b", "é", "", "-", "-x", "x-",
  ])
    sameRoom(fam);
  expect(roomFile("both")).toBe(join(h, "data", "both", "room.md"));
  expect(roomFile("arch")).toBe(join(h, "data", "archive", "2026", "arch", "room.md"));
  // Byte order: B1 before a1, where a case-folding collation reads a1 first.
  expect(roomFile("ord")).toBe(join(h, "data", "archive", "B1", "ord", "room.md"));
  expect(roomFile("linked")).toBe(join(h, "data", "archive", "zlink", "linked", "room.md"));
  expect(roomFile("hid")).toBe(join(h, "data", "hid", "room.md"));
  expect(roomFile("fam-slug")).toBe(join(h, "data", "fam", "room.md"));
  expect(roomFile("old-x")).toBe(join(h, "data", "archive", "2025", "old", "room.md"));
  // The longest prefix with a brief wins, though data/a/tasks/b-c has one too.
  expect(roomFile("a-b-c")).toBe(join(h, "data", "a-b", "room.md"));
  expect(roomFile("nest-kid-sub")).toBe(join(h, "data", "archive", "2026", "nest", "room.md"));
  expect(roomFile("dirroom")).toBe(join(h, "data", "archive", "2026", "dirroom", "room.md"));
  expect(roomFile("a.b")).toBe(join(h, "data", "a.b", "room.md"));
});

test("roomFile homeless prints the AC_HOME refusal once per data-dir read the bash made and answers the dir-less path", () => {
  delete process.env.AC_HOME;
  for (const fam of ["f", "f-x-y", "bad.name"]) {
    const want = bash('ac_room_file "$1"', [fam]);
    expect({ fam, ...twin(fam) }).toEqual({ fam, out: want.out.replace(/\n$/, ""), err: want.err });
  }
  expect(bash('ac_room_file "$1"', ["f-x-y"]).err.split("\n").filter((l) => l.startsWith("ERROR: AC_HOME is not set")).length).toBe(4);
});

const MEMBER_AWK = `LC_ALL=C awk "$AC_DONELINE_AWK"'
    index($0, "- [") == 1 { ac_doneline($0, f); print f["id"] "\\t" f["feature"] "\\t" f["epic"] "\\t" f["terminal"] "\\t" $0 }' "$1"`;
const CONTAINER_AWK = `LC_ALL=C awk -v want="$2" "$AC_DONELINE_AWK"'
    BEGIN { w[want] }
    /^- \\[/ { ac_doneline($0, f); if (f["id"] in w) { print f["contract"]; exit } }' "$1"`;

function ledger(home: string, body: string): string {
  const f = join(home, "records", "backlog.md");
  mkdirSync(join(home, "records"), { recursive: true });
  writeFileSync(f, body, "latin1");
  return f;
}

const LEDGER = [
  "# Backlog",
  "- [x] s0 - rows above the first section count too; feature:f",
  "## In flight",
  "- [ ] f [src:cap flow:direct mode:feature-pr rev:no\tqa:yes] - the container (repo: p)",
  "- [ ] s1 - open member; feature:f (repo: p)",
  "- [X] s2 - a capital X is no checkbox; feature:f",
  "- [x] s3 - landed\0 feature:f nul cuts the record",
  "- [x] s4 - landed; feature:f\r",
  "  - [ ] indented - no row; feature:f",
  "-  [ ] spaced - no row; feature:f",
  "## Queued",
  "- [ ] s5 [failed] - an open box with a terminal token; feature:f",
  "- [ ] 07 [src:cap qa:no] - numeric; feature:7",
  "- [ ] 7 [src:cap qa:yes] - numeric container",
  "- [ ] q\\x [src:cap qa:yes] - backslash id",
  "- [ ] qx [src:cap qa:no] - what awk -v makes of q\\x",
  "## Done",
  "- [x] s6 [abandoned] - dead; feature:f",
  "- [x] s7 [failed] - dead and poisoned; epic:e feature:f",
  "- [x] f - the container landing twice; feature:f",
  "- [x] s8 [epic] - feature:F case differs",
  "- [ ]",
  "- [ ] s9 - unterminated last line; feature:f",
].join("\n");

test("memberRows reads what the member awk read: every `- [` record in every section, its raw line NUL-cut, an unterminated last line included", () => {
  const h = freshHome();
  const f = ledger(h, LEDGER);
  const want = bash(MEMBER_AWK, [f]).out;
  const got = memberRows(LEDGER)
    .map((r) => `${r.id}\t${r.feature}\t${r.epic}\t${r.terminal}\t${r.line}\n`)
    .join("");
  expect(got).toBe(want);
  expect(got).toContain("s9\tf\t\t\t- [ ] s9 - unterminated last line; feature:f\n");
  expect(got).toContain("s3\t\t\t\t- [x] s3 - landed\n");
  expect(memberRows(LEDGER).find((r) => r.line.startsWith("- [X]"))?.id).toBe("-");
  expect(memberRows("")).toEqual([]);
});

test("containerContract reads what the container awk read: the FIRST row whose id is the feature by string (never numeric) equality, the want read as awk -v reads it, TABs in the contract kept", () => {
  const h = freshHome();
  const f = ledger(h, LEDGER);
  for (const want of ["f", "7", "07", "7.0", "s1", "nosuch", "q\\x", "q\\\\x", "", "s9"]) {
    const bashSide = bash(CONTAINER_AWK, [f, want]).out.replace(/\n$/, "");
    expect({ want, got: containerContract(LEDGER, want) }).toEqual({ want, got: bashSide });
  }
  expect(containerContract(LEDGER, "f")).toBe("src:cap flow:direct mode:feature-pr rev:no\tqa:yes");
  expect(containerContract(LEDGER, "7")).toBe("src:cap qa:yes");
  expect(containerContract(LEDGER, "q\\x")).toBe("src:cap qa:no");
});
