// brief.test.ts - what src/brief.ts brought into src/lib.ts, held to the LIVE
// bash helpers it twins: rowContractForId over ledgerRead
// (ac_row_contract_for_id), epicBaseFor over a ledger already read
// (ac_epic_base_for), knowledgeFile (ac_knowledge_file) and captainRead
// (ac_captain). The CLI contract itself is tests/sh/ac-brief.test.sh's, whose
// differential leg runs the frozen original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with state/ records/ data/ config/, repos at <side>/<name> built by the same git commands with fixed dates); argv; env (PATH = the host's bun, git and jq, /bin and /usr/bin without herdr, orca, docker or codegraph; LC_ALL=C unless a row names UTF-8; HOME, TMPDIR, AC_HOME unless homeless); cwd (the distro root, so the bash's AC_DONELINE_AWK and the twin start the one src/backlog.ts); stdin (/dev/null); stdout, stderr and the status compared whole (the side root spelled S), then the home's tree.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-brief-ts-")));
const ROOTED = process.getuid?.() === 0;
afterAll(() => rmSync(W, { recursive: true, force: true }));

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "git", "jq"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const PATH = `${TOOLS}:${BASE}`;
const GIT_ENV = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z", GIT_CONFIG_NOSYSTEM: "1" };

type Row = {
  // the bash call, run after sourcing ac-lib.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  homeless?: boolean;
  lc?: string;
};
type Side = { out: string; err: string; rc: number | null; world: string };

function world(h: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(h, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    const r = rel ? `${rel}/${name}` : name;
    if (r.endsWith("/.git") || r === ".git") continue;
    const st = lstatSync(join(h, r));
    const mode = (st.mode & 0o777).toString(8);
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(join(h, r))}\n`;
    else if (st.isDirectory()) w += `${r}/ ${mode}\n${world(h, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(join(h, r), "latin1");
      } catch {}
      w += `${r} ${mode} = ${JSON.stringify(body)}\n`;
    }
  }
  return w;
}

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: row.lc ?? "C", ...GIT_ENV };
  if (!row.homeless) env.AC_HOME = join(s, "home");
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc);`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const norm = (t: string): string => t.replaceAll(s, "S");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), rc: r.exitCode, world: norm(world(join(s, "home"))) };
}

function pair(row: Row): { o: Side; t: Side; root: string } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    for (const sub of ["home/state", "home/records", "home/data", "home/config"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]!, root };
}

function same(label: string, row: Row): { o: Side; t: Side; root: string } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const put = (s: string, rel: string, body: string, mode = 0o644): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body.replaceAll("@S", s), "latin1"), { mode });
  chmodSync(join(s, rel), mode);
};

// A repo whose main checkout is <s>/<name>, one commit on main.
function repo(s: string, name: string): void {
  const r = join(s, name);
  for (const args of [["init", "-q", "-b", "main", r], ["-C", r, "commit", "-q", "--allow-empty", "-m", "init"]])
    Bun.spawnSync(["git", ...args], { env: { PATH, HOME: W, ...GIT_ENV }, stdin: "ignore", stdout: "ignore", stderr: "ignore" });
}

const LEDGER = "home/records/backlog.md";
// Every caller reads it through `$(...)`: a family with no row prints nothing
// where every other "" prints a newline, and the capture makes them one.
const CONTRACT: Row = {
  bash: `c="$(ac_row_contract_for_id "$1" "$2")"; rc=$?; [ $rc != 0 ] || printf '%s\\n' "$c"; (exit $rc)`,
  twin: `const c = L.rowContractForId(A[0], L.ledgerRead(A[1])); if (c === null) return 2; writeSync(1, Buffer.from(c + "\\n", "latin1")); return 0;`,
};
const ROWS = [
  "# Backlog",
  "## Queued",
  "- [ ] plain [src:cap mode:local-only rev:yes] - an exact row (repo: p)",
  "- [ ] plain [src:cap mode:crew-ship] - a second row with the id: the first wins",
  "- [x] done1 [src:cap flow:staged mode:direct-pr] - a done row counts (repo: p)",
  "- [X] upper [src:cap mode:local-only] - an uppercase box is no row",
  "- [ ] fam [src:cap flow:staged mode:crew-ship rev:yes qa:no] - the family pins",
  "- [ ] fam-spec - an exact row with no contract falls through to the family",
  "- [ ] fam-plan [src:cap mode:local-only] - an exact contract wins over the family's",
  "- [ ] 01 [src:cap mode:crew-ship] - numeric-looking",
  "- [ ] 1 [src:cap mode:local-only] - matched as a string",
  "- [ ] tabbed [src:cap\tmode:local-only] - a TAB joins the tokens",
  "- [ ] crlf [src:cap mode:direct-pr] - a CR ends this line\r",
  "- [ ] bad [src:cap bogus:v] - an invalid group is no contract",
  "- [ ] nul [src:cap mode:local-only]\0 - the record cut at the NUL",
  "- [ ] a\\tb [src:cap mode:feature-pr] - a backslash in the id",
  "  - [ ] indented [src:cap mode:local-only] - not at column 0",
  "",
].join("\n");

test("rowContractForId: the exact row's contract, else the family row's for a stage-suffixed id, bytes kept", () => {
  const seed = (s: string): void => put(s, LEDGER, ROWS);
  const ids = ["plain", "done1", "upper", "fam", "fam-spec", "fam-spec-r2", "fam-plan", "fam-arch", "fam-r2", "fam-chief", "fam-x", "01", "1", "1-spec", "tabbed", "crlf", "bad", "nul", "a\\tb", "a\tb", "a\\\\tb", "indented", "none", "none-qa", ""];
  for (const id of ids) same(`contract of ${JSON.stringify(id)}`, { ...CONTRACT, args: [id, `@S/${LEDGER}`], seed });
  const p = same("the first row with the id", { ...CONTRACT, args: ["plain", `@S/${LEDGER}`], seed });
  expect(p.t.out).toBe("src:cap mode:local-only rev:yes\n|rc=0");
  expect(same("the family's", { ...CONTRACT, args: ["fam-spec", `@S/${LEDGER}`], seed }).t.out).toBe("src:cap flow:staged mode:crew-ship rev:yes qa:no\n|rc=0");
  expect(same("01 is not 1", { ...CONTRACT, args: ["1", `@S/${LEDGER}`], seed }).t.out).toBe("src:cap mode:local-only\n|rc=0");
  expect(same("the TAB kept", { ...CONTRACT, args: ["tabbed", `@S/${LEDGER}`], seed }).t.out).toBe("src:cap\tmode:local-only\n|rc=0");
});

test("rowContractForId: no ledger and a ledger that is a directory read as no contract", () => {
  same("no ledger", { ...CONTRACT, args: ["plain", `@S/${LEDGER}`] });
  same("a directory", { ...CONTRACT, args: ["plain", `@S/${LEDGER}`], seed: (s) => mkdirSync(join(s, LEDGER)) });
  same("an empty ledger", { ...CONTRACT, args: ["plain", `@S/${LEDGER}`], seed: (s) => put(s, LEDGER, "") });
});

// awk's own two lines for a file it cannot open are not reproduced: the
// ledger is read in-process; the status is the bash's 2.
test("rowContractForId: a ledger that cannot be read is rc 2, never an unpinned row", () => {
  if (ROOTED) return;
  const p = pair({ ...CONTRACT, args: ["plain", `@S/${LEDGER}`], seed: (s) => put(s, LEDGER, ROWS, 0o000) });
  expect([p.o.out, p.t.out]).toEqual(["|rc=2", "|rc=2"]);
  expect(p.o.err).toMatch(/^awk: can't open file S\/home\/records\/backlog\.md\n source line number [0-9]+\n$/);
  expect(p.t.err).toBe("");
  expect(p.t.world).toBe(p.o.world);
});

test("epicBaseFor over a ledger already read answers what ac_epic_base_for answers", () => {
  const BASE_ROW: Row = {
    bash: `e="$(ac_epic_base_for "$1" "$2")"; rc=$?; printf '%s' "$e"; (exit $rc)`,
    twin: `const e = L.epicBaseFor(A[0], A[1], L.ledgerRead(A[2])); if (e.rc === 0) writeSync(1, Buffer.from(e.entry, "latin1")); return e.rc;`,
  };
  const seed = (s: string): void => {
    put(s, LEDGER, "- [ ] e1-s1 - story epic:e1 (repo: proj)\n- [ ] f1-m - member feature:f1\n- [ ] own - its own record\n- [ ] r1-s - retired epic:r1\n- [ ] ar-s - archived epic:ar\n");
    put(s, "home/data/e1/branches", "proj epic/e1 push=yes\nother epic/x\n");
    put(s, "home/data/f1/branches", "proj feat/f1 push=deferred\n");
    put(s, "home/data/own/branches", "proj epic/own\n");
    put(s, "home/data/r1/branches", "# retired 2026-01-01\nproj epic/r1\n");
    put(s, "home/data/archive/2025/ar/branches", "proj epic/ar\n");
  };
  for (const [id, repo] of [["e1-s1", "proj"], ["e1-s1-x", "proj"], ["e1-s1", "other"], ["e1-s1", "nope"], ["f1-m", "proj"], ["own-q", "proj"], ["r1-s", "proj"], ["ar-s", "proj"], ["zz", "proj"]] as const)
    same(`fence of ${id} on ${repo}`, { ...BASE_ROW, args: [id, repo, `@S/${LEDGER}`], seed });
  same("no ledger", { ...BASE_ROW, args: ["e1-s1", "proj", `@S/${LEDGER}`] });
  if (!ROOTED) {
    const p = pair({ ...BASE_ROW, args: ["e1-s1", "proj", `@S/${LEDGER}`], seed: (s) => (seed(s), chmodSync(join(s, LEDGER), 0o000)) });
    expect([p.o.out, p.t.out]).toEqual(["|rc=2", "|rc=2"]);
  }
});

test("knowledgeFile: <records>/repo-knowledge/<main repo name>.md, records/ minted; null where git cannot name the repo", () => {
  const KF: Row = {
    bash: `ac_knowledge_file "$1"`,
    twin: `const f = L.knowledgeFile(A[0]); if (f === null) return 1; writeSync(1, f + "\\n"); return 0;`,
  };
  const seed = (s: string): void => {
    rmSync(join(s, "home", "records"), { recursive: true });
    repo(s, "Proj");
    Bun.spawnSync(["git", "-C", join(s, "Proj"), "worktree", "add", "-q", "--detach", join(s, "wt")], { env: { PATH, HOME: W, ...GIT_ENV }, stdout: "ignore", stderr: "ignore" });
    mkdirSync(join(s, "plain"));
    mkdirSync(join(s, "Proj", "sub"));
  };
  for (const a of ["@S/Proj", "@S/wt", "@S/Proj/sub", "@S/plain", "@S/gone"]) same(`knowledge file of ${a}`, { ...KF, args: [a], seed });
  const p = same("homeless", { ...KF, args: ["@S/Proj"], seed, homeless: true });
  expect(p.t.out).toBe("/repo-knowledge/Proj.md\n|rc=0");
  expect(same("a repo", { ...KF, args: ["@S/wt"], seed }).t.out).toBe("S/home/records/repo-knowledge/Proj.md\n|rc=0");
});

test("captainRead: config/captain's first line as bytes, trimmed under the caller's locale, the role word by default", () => {
  const CAP: Row = { bash: `c="$(ac_captain)"; printf '[%s]' "$c"`, twin: `writeSync(1, Buffer.from("[" + L.captainRead() + "]", "latin1")); return 0;` };
  const F = "home/config/captain";
  const cases: [string, ((s: string) => void) | undefined, string?][] = [
    ["absent", undefined],
    ["a directory", (s) => mkdirSync(join(s, F))],
    ["empty", (s) => put(s, F, "")],
    ["a name", (s) => put(s, F, "TN\n")],
    ["two lines", (s) => put(s, F, "  TN  \nsecond\n")],
    ["CRLF", (s) => put(s, F, "TN\r\n")],
    ["a NUL", (s) => put(s, F, "T\0N\n")],
    ["a latin1 byte", (s) => put(s, F, "Tu\xe9n\n")],
    ["a latin1 byte under UTF-8", (s) => put(s, F, "Tu\xe9n \n"), "en_US.UTF-8"],
    ["NBSP under C", (s) => put(s, F, "\xc2\xa0Anh TN \r\n")],
    ["NBSP under UTF-8", (s) => put(s, F, "\xc2\xa0Anh TN \r\n"), "en_US.UTF-8"],
    ["only space", (s) => put(s, F, " \t \n")],
  ];
  for (const [label, seed, lc] of cases) same(`captain: ${label}`, { ...CAP, seed, lc });
  expect(same("default", { ...CAP }).t.out).toBe("[captain]|rc=0");
  expect(same("latin1", { ...CAP, seed: (s) => put(s, F, "Tu\xe9n\n") }).t.out).toBe("[Tu\xe9n]|rc=0");
  same("homeless", { ...CAP, homeless: true, seed: (s) => put(s, F, "TN\n") });
  if (!ROOTED) {
    const p = same("unreadable: head's line, and no name", { ...CAP, seed: (s) => put(s, F, "TN\n", 0o000) });
    expect(p.t.out).toBe("[]|rc=0");
    expect(p.t.err).toBe("head: S/home/config/captain: Permission denied\n");
  }
});
