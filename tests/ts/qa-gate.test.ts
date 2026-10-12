// qa-gate.test.ts - the qa.require_for_ship merge gate twins (src/lib.ts,
// `// --- qa-gate twins ---`) held to the frozen bash functions of
// tests/fixtures/ac-qa-lib.sh differentially: qaRequired against ac_qa_required (Q rows),
// qaAttestationParse against ac_qa_attestation_parse (P rows), qaGateOk
// against ac_qa_gate_ok (G rows). Each row runs on two side roots seeded
// alike and compares stdout, stderr, the exit (a die is the exit with no `#`,
// a return is `#<rc>`) and the home tree (what the gate minted under data/
// and records/). The bash side sources the libs by hand as the frozen entry
// oracles do, under `set -uo pipefail` - errexit asleep, as every caller ran
// the gate - and LC_ALL=C unless a row names a locale; the twin runs in a bun
// child started in the distro root. The rows that NAME a divergence assert
// both sides' answers explicitly. The entries' own legs are
// tests/sh/ac-merge-local.test.sh and ac-pr-merge.test.sh.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { retiredBin } from "./retired-bin.ts";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const binDir = retiredBin();
const LIB = join(ROOT, "src", "lib.ts");
const FIXED = "2026-01-01T00:00:00Z";
const ROOTUSER = process.getuid?.() === 0;
const made: string[] = [];
afterAll(() => made.forEach((d) => rmSync(d, { recursive: true, force: true })));

type Fn = "ac_qa_required" | "ac_qa_gate_ok" | "ac_qa_attestation_parse";
type Row = { fn: Fn; args: string[]; env?: Record<string, string>; cwd?: string; homeless?: boolean; path?: string };
type Run = { out: string; err: string; rc: number; tree: string[] };

// Two side roots: `HOME` in an argument, an env value or a cwd is that side's
// root, so both sides see the same spelling of every path.
class World {
  readonly o: string;
  readonly n: string;
  constructor() {
    this.o = this.side();
    this.n = this.side();
  }
  private side(): string {
    const r = realpathSync(mkdtempSync(join(tmpdir(), "ac-qa-gate-")));
    made.push(r);
    mkdirSync(join(r, "home", "state"), { recursive: true });
    return r;
  }
  both(f: (root: string) => void): void {
    f(this.o);
    f(this.n);
  }
  // The row on both sides; the twin's answer, already proven equal. bun's diff
  // hunk shows only the lines around a difference, so the row names itself.
  pair(name: string, row: Row): Run {
    const want = oracle(this.o, row);
    const got = twin(this.n, row);
    if (!Bun.deepEquals(got, want)) console.error(`row differs: ${name}`);
    expect(got).toEqual(want);
    return got;
  }
}

const sub = (s: string, root: string): string => s.split("HOME").join(root);
const norm = (b: Uint8Array, root: string): string => Buffer.from(b).toString("latin1").split(root).join("HOME");

function envFor(root: string, row: Row): Record<string, string> {
  const e: Record<string, string> = { PATH: row.path ?? process.env.PATH!, LC_ALL: "C" };
  if (!row.homeless) e.AC_HOME = `${root}/home`;
  for (const [k, v] of Object.entries(row.env ?? {})) e[k] = sub(v, root);
  return e;
}

// Everything under the home but projects/ - the gate mints data/ and records/.
function tree(root: string): string[] {
  return (readdirSync(join(root, "home"), { recursive: true }) as string[]).filter((p) => p !== "projects" && !p.startsWith("projects/")).sort();
}

const read = (r: ReturnType<typeof Bun.spawnSync>, root: string): Run => ({ out: norm(r.stdout, root), err: norm(r.stderr, root), rc: r.exitCode ?? -1, tree: tree(root) });

function oracle(root: string, row: Row): Run {
  const tail = row.fn === "ac_qa_attestation_parse" ? 'printf "#%s%s" "$rc" "${AC_QA_ATTESTATION_ERROR-}"' : 'printf "#%s" "$rc"';
  const script = `set -uo pipefail; . "$0/ac-lib.sh"; . "$0/ac-pipeline-lib.sh"; . "$0/ac-qa-lib.sh"; ${row.fn} "$@" && rc=0 || rc=$?; ${tail}`;
  const r = Bun.spawnSync(["/bin/bash", "-c", script, binDir, ...row.args.map((a) => sub(a, root))], {
    env: envFor(root, row),
    cwd: row.cwd ? sub(row.cwd, root) : root,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    timeout: 30000,
  });
  return read(r, root);
}

// The twin takes <repo> and <task> as the native strings the entries hold and
// <sha>, <file>, <scope>, <app> as bytes (latin1); a `{status}` throw is the
// die's exit.
const TWIN = `import * as L from ${JSON.stringify(LIB)};
const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const A: string[] = JSON.parse(process.env.TWIN_ARGS!);
try {
  let r: string;
  if (process.env.TWIN_FN === "ac_qa_required") r = "#" + (L.qaRequired(A[0]!) ? 0 : 1);
  else if (process.env.TWIN_FN === "ac_qa_gate_ok") r = "#" + (L.qaGateOk(A[0]!, lat(A[1]!), A[2] ?? "") ? 0 : 1);
  else { const e = L.qaAttestationParse(lat(A[0]!), lat(A[1]!), lat(A[2]!), lat(A[3]!), lat(A[4] ?? ""), lat(A[5] ?? "")); r = e === null ? "#0" : "#1" + e; }
  process.stdout.write(Buffer.from(r, "latin1"));
} catch (e) { const s = (e as { status?: number }).status; if (s === undefined) throw e; process.exit(s); }
`;

function twin(root: string, row: Row): Run {
  const r = Bun.spawnSync([process.execPath, "-e", TWIN], {
    env: { ...envFor(root, row), TWIN_FN: row.fn, TWIN_ARGS: JSON.stringify(row.args.map((a) => sub(a, root))) },
    cwd: row.cwd ? sub(row.cwd, root) : ROOT,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    timeout: 30000,
  });
  return read(r, root);
}

// A repo with one fixed-date empty commit, so both sides share the sha.
function gitRepo(dir: string): void {
  mkdirSync(dir, { recursive: true });
  for (const a of [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["commit", "-q", "--allow-empty", "-m", "i"]])
    expect(Bun.spawnSync(["git", "-C", dir, ...a], { env: { ...process.env, GIT_AUTHOR_DATE: FIXED, GIT_COMMITTER_DATE: FIXED } }).exitCode).toBe(0);
  mkdirSync(join(dir, ".crew", "qa", "passed"), { recursive: true });
}
const headOf = (dir: string): string => Bun.spawnSync(["git", "-C", dir, "rev-parse", "HEAD"]).stdout.toString().trim();
// A text as the latin1 reading of its UTF-8 bytes, the spelling `norm` gives.
const L8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const put = (root: string, rel: string, body: string | Buffer): void => {
  mkdirSync(join(root, rel, ".."), { recursive: true });
  writeFileSync(join(root, rel), body);
};
const rm = (root: string, rel: string): void => rmSync(join(root, rel), { recursive: true, force: true });

// A PATH holding every tool of the live one but <name>.
function pathWithout(name: string): string {
  const d = realpathSync(mkdtempSync(join(tmpdir(), `ac-qa-gate-no-${name}-`)));
  made.push(d);
  for (const dir of new Set([...process.env.PATH!.split(":"), join(process.execPath, "..")])) {
    let names: string[] = [];
    try {
      names = readdirSync(dir);
    } catch {}
    for (const f of names) {
      if (f === name) continue;
      try {
        symlinkSync(join(dir, f), join(d, f));
      } catch {}
    }
  }
  return d;
}

// ...and a <name> there that is no executable.
function pathWithDead(name: string): string {
  const d = pathWithout(name);
  writeFileSync(join(d, name), "#!/bin/sh\nexit 0\n", { mode: 0o644 });
  return d;
}

const REQ = "qa:\n  require_for_ship: true\n";
const SCOPED = 'qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n';
const MAP = "- scope orchid = orchid-service | src: cmd:true | at: d 2026-07-21 | by: f\n";
const RETIRED = (name: string): string =>
  `ERROR: project config for '${name}' found at the RETIRED legacy path (HOME/home/config/projects/${name}.yaml), which is no longer read - move it: mv "HOME/home/config/projects/${name}.yaml" "HOME/home/projects/${name}.yaml" (or delete it if HOME/home/projects/${name}.yaml is already authoritative)\n`;

const UNREADABLE = (p: string): string => `ERROR: qa.require_for_ship: the project policy ${p} cannot be read - refusing the merge rather than reading it as not enforced\n`;
const NOGIT = (repo: string): string =>
  `ERROR: qa.require_for_ship: git did not run (is it on PATH?), so the project policy for '${repo}' cannot be resolved - refusing the merge rather than reading it as not enforced\n`;

// A v2 marker body: the required keys, scope=/app= when given, overrides last.
function marker(sha: string, scope = "", app = "", extra: Record<string, string | null> = {}): string {
  const kv: Record<string, string | null> = {
    schema: "agentcrew.qa-attestation/v2",
    outcome: "passed",
    run: "r",
    task: "t",
    completed_at: "2026-07-24T00:00:00Z",
    source_sha: sha,
    profile_key: `g/${scope || "flat"}/${app || "flat"}`,
    profile_sha256: "p",
    config_sha256: "c",
    cases_passed: "1",
    cases_total: "1",
  };
  if (scope !== "") {
    kv.scope = scope;
    kv.app = app;
  }
  Object.assign(kv, extra);
  return Object.entries(kv)
    .filter(([, v]) => v !== null)
    .map(([k, v]) => `${k}=${v}\n`)
    .join("");
}

test("Q: qaRequired reads the policy as ac_qa_required: the spellings that enforce and those that do not, the block grammar, the RETIRED die, an unreadable or directory yaml, a linked worktree, `-C \"\"`, homeless, NUL, git absent", () => {
  const w = new World();
  w.both((r) => {
    gitRepo(join(r, "home", "projects", "q"));
    mkdirSync(join(r, "plain"));
  });
  const Q = (args: string[], more: Partial<Row> = {}): Row => ({ fn: "ac_qa_required", args, ...more });
  const yaml = (body: string): void => w.both((r) => put(r, "home/projects/q.yaml", body));
  const REPO = "HOME/home/projects/q";

  expect(w.pair("1 non-repo", Q(["HOME/plain"]))).toEqual({ out: "#1", err: "", rc: 0, tree: ["state"] });
  expect(w.pair("2 no yaml", Q([REPO])).out).toBe("#1");
  yaml(REQ);
  expect(w.pair("3 true", Q([REPO]))).toEqual({ out: "#0", err: "", rc: 0, tree: ["state"] });
  // The value is the text past the key's own colon, its comment (a `#` after
  // a space) cut, quotes deleted, its ends trimmed of the C locale's space:
  // anything but a false spelling enforces.
  for (const v of ['"true"', "'true'", "tr ue", "x:true", "true   ", '"tr"ue', "True", "true # c", "true\t", "true\t# c", "yes", "1", "maybe", "on", "n", "", " # c", "fAlse", "false#x", "fal se", "false:x", "x: false", "'false'x", "false\u00a0"]) {
    yaml(`qa:\n  require_for_ship: ${v}\n`);
    expect(w.pair(`4 ${JSON.stringify(v)} enforces`, Q([REPO]))).toEqual({ out: "#0", err: "", rc: 0, tree: ["state"] });
  }
  for (const v of ["false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF", '"false"', "'off'", "  NO  ", "false # c", "false\t# c", "fa\"l'se", "false\t", "false\v\f"]) {
    yaml(`qa:\n  require_for_ship: ${v}\n`);
    expect(w.pair(`5 ${JSON.stringify(v)} does not`, Q([REPO]))).toEqual({ out: "#1", err: "", rc: 0, tree: ["state"] });
  }
  for (const [name, body] of [
    ["CRLF", "qa:\r\n  require_for_ship: true\r\n"],
    ["header comment", "qa: # c\n  require_for_ship: true\n"],
    ["header comment, no space", "qa:#c\n  require_for_ship: true\n"],
    ["header TAB, comment, CR", "qa:\t# c\r\n  require_for_ship: true\r\n"],
    ["no space past the key's colon", "qa:\n  require_for_ship:true\n"],
    ["a comment right past the key's colon", "qa:\n  require_for_ship:#c\n"],
    ["nested", "qa:\n  scopes:\n    x:\n      require_for_ship: true\n"],
    ["comment and blank keep the block", "qa:\n# c\n\n  require_for_ship: true\n"],
    ["second qa block", "qa:\nother: 1\nqa:\n  require_for_ship: true\n"],
    ["trailing spaces on qa:", "qa:  \t\n  require_for_ship: true\n"],
  ] as const) {
    yaml(body);
    expect(w.pair(`6/7 ${name}`, Q([REPO])).out).toBe("#0");
  }
  // NOT enforced: a false spelling, a key absent from the block or no block.
  // A NBSP indent is no space in the C locale: its line closes the block.
  for (const [name, body] of [
    ["CRLF false", "qa:\r\n  require_for_ship: false\r\n"],
    ["absent from the block", "qa:\n  other: 1\n"],
    ["no qa block", "require_for_ship: true\n"],
    ["qa: <value> is no header", "qa: x\n  require_for_ship: true\n"],
    ["column-0 key closes", "qa:\nother: 1\n  require_for_ship: true\n"],
    ["first wins", "qa:\n  require_for_ship: false\n  require_for_ship: true\n"],
    ["no colon right past the key", "qa:\n  require_for_ship :true\n"],
    ["nbsp indent under C", "qa:\n\u00a0 require_for_ship: true\n"],
  ] as const) {
    yaml(body);
    expect(w.pair(`5 ${name}`, Q([REPO]))).toEqual({ out: "#1", err: "", rc: 0, tree: ["state"] });
  }
  // NUL: `$(cat)` drops it, so the value reads whole.
  yaml("qa:\n  require_for_ship: fal\0se\n");
  expect(w.pair("13 NUL", Q([REPO])).out).toBe("#1");
  yaml(REQ);
  // 8. the RETIRED legacy copy: the die, alone or beside the canonical; a directory there is no copy
  w.both((r) => {
    rm(r, "home/projects/q.yaml");
    put(r, "home/config/projects/q.yaml", REQ);
  });
  expect(w.pair("8 legacy alone", Q([REPO]))).toEqual({ out: "", err: RETIRED("q"), rc: 1, tree: ["config", "config/projects", "config/projects/q.yaml", "state"] });
  yaml(REQ);
  expect(w.pair("8 legacy and canonical", Q([REPO]))).toEqual({ out: "", err: RETIRED("q"), rc: 1, tree: ["config", "config/projects", "config/projects/q.yaml", "state"] });
  w.both((r) => {
    rm(r, "home/config/projects/q.yaml");
    mkdirSync(join(r, "home/config/projects/q.yaml"));
  });
  expect(w.pair("8 legacy a directory", Q([REPO])).out).toBe("#0");
  w.both((r) => rm(r, "home/config"));
  // 9. the canonical a directory: no config; a regular file that cannot be read ends the run
  w.both((r) => {
    rm(r, "home/projects/q.yaml");
    mkdirSync(join(r, "home/projects/q.yaml"));
  });
  expect(w.pair("9 canonical a directory", Q([REPO]))).toEqual({ out: "#1", err: "", rc: 0, tree: ["state"] });
  w.both((r) => rm(r, "home/projects/q.yaml"));
  if (!ROOTUSER) {
    yaml(REQ);
    w.both((r) => chmodSync(join(r, "home/projects/q.yaml"), 0));
    expect(w.pair("9 canonical unreadable", Q([REPO]))).toEqual({ out: "", err: UNREADABLE("HOME/home/projects/q.yaml"), rc: 1, tree: ["state"] });
    w.both((r) => chmodSync(join(r, "home/projects/q.yaml"), 0o644));
  }
  yaml(REQ);
  // 10. a linked worktree answers the MAIN repo's name; 11. `-C ""` is the cwd
  w.both((r) => expect(Bun.spawnSync(["git", "-C", join(r, "home/projects/q"), "worktree", "add", "-q", "--detach", join(r, "wt")]).exitCode).toBe(0));
  expect(w.pair("10 linked worktree", Q(["HOME/wt"])).out).toBe("#0");
  expect(w.pair("11 -C \"\" from the repo", Q([""], { cwd: REPO })).out).toBe("#0");
  expect(w.pair("11 -C \"\" from a plain dir", Q([""], { cwd: "HOME/plain" })).out).toBe("#1");
  // 11b. a main repo whose name ends in LF, reached through a worktree: the
  // name's `$(...)` cut the LF, so q.yaml is its policy and the RETIRED die
  w.both((r) => {
    gitRepo(join(r, "lfrepo", "q\n"));
    expect(Bun.spawnSync(["git", "-C", join(r, "lfrepo", "q\n"), "worktree", "add", "-q", "--detach", join(r, "wtlf")]).exitCode).toBe(0);
  });
  expect(w.pair("11b a main repo named q<LF>", Q(["HOME/wtlf"])).out).toBe("#0");
  w.both((r) => put(r, "home/config/projects/q.yaml", REQ));
  expect(w.pair("11b ...its RETIRED legacy copy", Q(["HOME/wtlf"])).rc).toBe(1);
  w.both((r) => rm(r, "home/config"));
  // 12. homeless: the AC_HOME refusal once, then NOT enforced
  expect(w.pair("12 homeless", Q([REPO], { homeless: true }))).toEqual({
    out: "#1",
    err: "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n",
    rc: 0,
    tree: ["state"],
  });
  // 14. a git that cannot run: no repo can be resolved to its policy, so the
  // run ends - where a dir git answers is no repo stays NOT enforced (row 1)
  expect(w.pair("14 no git", Q([REPO], { path: pathWithout("git") }))).toEqual({ out: "", err: NOGIT("HOME/home/projects/q"), rc: 1, tree: ["state"] });
  expect(w.pair("14 a git that is no executable", Q(["HOME/plain"], { path: pathWithDead("git") }))).toEqual({ out: "", err: NOGIT("HOME/plain"), rc: 1, tree: ["state"] });
}, 120000);

test("Q, under a UTF-8 locale: the policy's awk reads in the C locale, so a byte that is no UTF-8 before or on the require_for_ship line reads as it does under C, and a NBSP indent is no space on either side", () => {
  const w = new World();
  w.both((r) => gitRepo(join(r, "home", "projects", "q")));
  for (const [name, body, want] of [
    ["a comment", Buffer.from("# caf\xe9\nqa:\n  require_for_ship: true\n", "latin1"), "#0"],
    ["a key", Buffer.from("name: caf\xe9\nqa:\n  require_for_ship: true\n", "latin1"), "#0"],
    ["the value", Buffer.from("qa:\n  require_for_ship: tru\xe9\n", "latin1"), "#0"],
    ["a false value's comment", Buffer.from("qa:\n  require_for_ship: false # caf\xe9\n", "latin1"), "#1"],
    ["a NBSP indent", "qa:\n\u00a0 require_for_ship: true\n", "#1"],
    ["a valid UTF-8 comment", "# café\nqa:\n  require_for_ship: true\n", "#0"],
  ] as const) {
    w.both((r) => put(r, "home/projects/q.yaml", body));
    expect(w.pair(`UTF-8 ${name}`, { fn: "ac_qa_required", args: ["HOME/home/projects/q"], env: { LC_ALL: "en_US.UTF-8" } })).toEqual({ out: want, err: "", rc: 0, tree: ["state"] });
  }
}, 60000);

test("P: qaAttestationParse answers ac_qa_attestation_parse's error text in its order over every arm, and null where it returns 0", () => {
  const w = new World();
  const F = "HOME/m";
  const S = "abc123";
  const P = (args: string[]): Row => ({ fn: "ac_qa_attestation_parse", args });
  const body = (b: string | Buffer): void => w.both((r) => put(r, "m", b));
  const check = (name: string, b: string | Buffer | null, args: string[], expected: string): void => {
    if (b !== null) body(b);
    expect(w.pair(name, P(args)).out).toBe(expected);
  };
  w.both((r) => mkdirSync(join(r, "d")));
  check("missing", null, ["HOME/nope", S, "", ""], "#1not a regular file");
  check("a directory", null, ["HOME/d", S, "", ""], "#1not a regular file");
  check("empty", "", [F, S, "", ""], "#1empty marker");
  check("blank line", `${marker(S)}\n`, [F, S, "", ""], "#1malformed line");
  check("no =", "schema\n", [F, S, "", ""], "#1malformed line");
  check("NUL cuts the line", `sche\0ma=agentcrew.qa-attestation/v2\n`, [F, S, "", ""], "#1malformed line");
  check("unknown key", `${marker(S)}foo=1\n`, [F, S, "", ""], "#1unknown key 'foo'");
  check("unknown key with bytes", Buffer.from(`${marker(S)}caf\xe9=1\n`, "latin1"), [F, S, "", ""], "#1unknown key 'caf\xe9'");
  check("duplicate key", `${marker(S)}run=again\n`, [F, S, "", ""], "#1duplicate key 'run'");
  check("schema v1", marker(S, "", "", { schema: "agentcrew.qa-attestation/v1" }), [F, S, "", ""], "#1unsupported schema");
  check("CRLF", marker(S).replace(/\n/g, "\r\n"), [F, S, "", ""], "#1unsupported schema");
  check("outcome", marker(S, "", "", { outcome: "failed" }), [F, S, "", ""], "#1outcome is not passed");
  check("no task", marker(S, "", "", { task: "" }), [F, S, "", ""], "#1missing run/task/completed_at");
  check("sha", marker(S), [F, "other", "", ""], "#1source_sha mismatch");
  check("no config sha", marker(S, "", "", { config_sha256: "" }), [F, S, "", ""], "#1missing profile/config identity");
  // Each count canonical decimal - digits, no leading zero, so at least 1 -
  // else `invalid case counts`; two canonical counts that differ are
  // `case counts differ`.
  for (const [p, t] of [["0", "0"], ["1", "x"], ["", "1"], ["10", "0"], ["1", ""], ["00", "00"], ["01", "1"], ["1", "01"], ["1", "00"], ["1:1", "1:1"], [" 1", "1"], ["1", "+1"]] as const)
    check(`counts ${p}:${t}`, marker(S, "", "", { cases_passed: p, cases_total: t }), [F, S, "", ""], "#1invalid case counts");
  for (const [p, t] of [["1", "2"], ["2", "1"], ["10", "1"]] as const) check(`counts ${p}:${t}`, marker(S, "", "", { cases_passed: p, cases_total: t }), [F, S, "", ""], "#1case counts differ");
  check("counts 10:10", marker(S, "", "", { cases_passed: "10", cases_total: "10" }), [F, S, "", ""], "#0");
  check("scope wanted, flat body", marker(S), [F, S, "orchid", "svc"], "#1scope/app body mismatch");
  check("scope wanted, other app", marker(S, "orchid", "other"), [F, S, "orchid", "svc"], "#1scope/app body mismatch");
  check("flat wanted, scoped body", marker(S, "orchid", "svc"), [F, S, "", ""], "#1flat marker carries scope/app");
  check("flat wanted, empty scope key", marker(S, "", "", { scope: "" }), [F, S, "", ""], "#1flat marker carries scope/app");
  for (const q of ["0", "", "abc", "1a"]) check(`qa_rule ${q}`, marker(S, "", "", { qa_rule: q }), [F, S, "", ""], "#1invalid qa_rule");
  for (const q of ["default", "00", "7"]) check(`qa_rule ${q}`, marker(S, "", "", { qa_rule: q }), [F, S, "", ""], "#0");
  check("partial e2e", marker(S, "", "", { e2e_repo: "r" }), [F, S, "", ""], "#1partial E2E identity");
  check("partial e2e empty", marker(S, "", "", { e2e_repo: "r", e2e_sha: "" }), [F, S, "", ""], "#1partial E2E identity");
  check("profile pin miss", marker(S), [F, S, "", "", "other"], "#1profile hash mismatch");
  check("profile pin hit", marker(S), [F, S, "", "", "p"], "#0");
  check("e2e pin miss", marker(S, "", "", { e2e_repo: "r", e2e_sha: "e" }), [F, S, "", "", "", "other"], "#1E2E hash mismatch");
  check("e2e pin hit", marker(S, "", "", { e2e_repo: "r", e2e_sha: "e" }), [F, S, "", "", "p", "e"], "#0");
  check("e2e pin, no e2e", marker(S), [F, S, "", "", "", "e"], "#1E2E hash mismatch");
  check("valid scoped", marker(S, "orchid", "svc"), [F, S, "orchid", "svc"], "#0");
  check("unterminated last line", marker(S).replace(/\n$/, ""), [F, S, "", ""], "#0");
  check("NUL in a value", `${marker(S)}qa_rule=default\0junk\n`, [F, S, "", ""], "#0");
  check("a symlink to a marker", null, ["HOME/link", S, "", ""], "#1not a regular file");
  w.both((r) => symlinkSync(join(r, "m"), join(r, "link")));
  check("a symlink to a marker", null, ["HOME/link", S, "", ""], "#0");
  if (!ROOTUSER) {
    // An unreadable marker: the shell's own redirect line is not reproduced
    // (SHELL-OWN STDERR); the result, `unsupported schema`, is.
    body(marker(S));
    w.both((r) => chmodSync(join(r, "m"), 0));
    const row = P([F, S, "", ""]);
    const want = oracle(w.o, row);
    const got = twin(w.n, row);
    expect(want.err).toContain("HOME/m: Permission denied");
    expect(want.out).toBe("#1unsupported schema");
    expect(got).toEqual({ ...want, err: "" });
    w.both((r) => chmodSync(join(r, "m"), 0o644));
  }
}, 120000);

test("G: qaGateOk answers ac_qa_gate_ok: not enforced mints nothing; the flat arm over no, a directory, an empty, an invalid and a valid marker; MODE MISMATCH both ways; AMBIGUOUS records; the scoped arm's skip list in byte order", () => {
  const w = new World();
  w.both((r) => gitRepo(join(r, "home", "projects", "g")));
  const REPO = "HOME/home/projects/g";
  const sha = headOf(join(w.n, "home/projects/g"));
  const sha12 = sha.slice(0, 12);
  const G = (args: string[] = [REPO, sha], more: Partial<Row> = {}): Row => ({ fn: "ac_qa_gate_ok", args, ...more });
  const yaml = (body: string): void => w.both((r) => put(r, "home/projects/g.yaml", body));
  const record = (body: string | null): void => w.both((r) => (body === null ? rm(r, "home/records/repo-knowledge/g.md") : put(r, "home/records/repo-knowledge/g.md", body)));
  const mark = (suffix: string, body: string | Buffer | null): void =>
    w.both((r) => (body === null ? rm(r, `home/projects/g/.crew/qa/passed/${sha}${suffix}`) : put(r, `home/projects/g/.crew/qa/passed/${sha}${suffix}`, body)));
  const NOPASS = `WARN: qa.require_for_ship: no passing crew-qa run recorded for ${sha12} - run crew-qa on this head before merging\n`;

  // 1. not enforced: open, and neither data/ nor records/ minted even with a task
  expect(w.pair("1 not enforced", G([REPO, sha, "t1"]))).toEqual({ out: "#0", err: "", rc: 0, tree: ["state"] });
  // a policy that cannot be read ends the run before the mode is read: nothing minted
  expect(w.pair("1 no git", G([REPO, sha, "t1"], { path: pathWithout("git") }))).toEqual({ out: "", err: NOGIT(REPO), rc: 1, tree: ["state"] });
  if (!ROOTUSER) {
    yaml(REQ);
    w.both((r) => chmodSync(join(r, "home/projects/g.yaml"), 0));
    expect(w.pair("1 an unreadable policy", G([REPO, sha, "t1"]))).toEqual({ out: "", err: UNREADABLE("HOME/home/projects/g.yaml"), rc: 1, tree: ["state"] });
    w.both((r) => chmodSync(join(r, "home/projects/g.yaml"), 0o644));
  }
  // 2. flat: the two-sided read mints records/ (W7), no data/ without a task
  yaml(REQ);
  expect(w.pair("2 flat, no marker", G())).toEqual({ out: "#1", err: NOPASS, rc: 0, tree: ["records", "state"] });
  w.both((r) => mkdirSync(join(r, `home/projects/g/.crew/qa/passed/${sha}`)));
  expect(w.pair("2 flat, a directory (W15)", G()).err).toBe(NOPASS);
  mark("", null);
  mark("", "");
  expect(w.pair("2 flat, empty", G()).err).toBe(`WARN: qa.require_for_ship: ignored invalid flat QA attestation for ${sha12}: empty marker\n${NOPASS}`);
  mark("", marker("other"));
  expect(w.pair("2 flat, another sha", G()).err).toBe(`WARN: qa.require_for_ship: ignored invalid flat QA attestation for ${sha12}: source_sha mismatch\n${NOPASS}`);
  mark("", marker(sha, "orchid", "svc"));
  expect(w.pair("2 flat, scoped body", G()).err).toContain(": flat marker carries scope/app\n");
  mark("", marker(sha));
  expect(w.pair("2 flat, valid", G())).toEqual({ out: "#0", err: "", rc: 0, tree: ["records", "state"] });
  // 3. MODE MISMATCH both ways; an empty `scopes:` block is a declaration
  yaml(SCOPED);
  expect(w.pair("3 yaml scopes, no map", G()).err).toBe(
    "WARN: qa.require_for_ship: MODE MISMATCH - the fleet-home config declares scopes but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge.\n",
  );
  yaml("qa:\n  require_for_ship: true\n  scopes:\n");
  expect(w.pair("3 empty scopes block", G()).err).toContain("the fleet-home config declares scopes but the repo-knowledge record declares NONE");
  yaml("qa:\n  require_for_ship: true\nscopes:\n  x: 1\n");
  expect(w.pair("3 scopes outside qa", G()).out).toBe("#0");
  yaml("qa:\n  require_for_ship: true\nother:\n  scopes:\n    x: 1\n");
  expect(w.pair("3 scopes under a later key", G()).out).toBe("#0");
  yaml(REQ);
  record(MAP);
  expect(w.pair("3 map, no yaml scopes", G()).err).toBe(
    "WARN: qa.require_for_ship: MODE MISMATCH - the repo-knowledge record declares scopes but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge.\n",
  );
  record("## Superseded\n- scope orchid = orchid-service\n");
  expect(w.pair("3 superseded map is none", G()).out).toBe("#0");
  // 4. AMBIGUOUS: a duplicate, a malformed line, a CRLF one (W8), an unreadable record (W8)
  const AMB =
    "WARN: qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify\n";
  for (const [name, body] of [
    ["duplicate", `${MAP}${MAP}`],
    ["malformed", "- scope orchid\n"],
    ["empty apps", "- scope orchid = \n"],
    ["bad app", "- scope orchid = a,,b\n"],
    ["crlf", "- scope orchid = orchid-service\r\n"],
    ["bad name", "- scope café = a\n"],
  ] as const) {
    record(body);
    expect(w.pair(`4 ${name}`, G())).toEqual({ out: "#1", err: AMB, rc: 0, tree: ["records", "records/repo-knowledge", "records/repo-knowledge/g.md", "state"] });
  }
  record("- scope orchid = orchid-service, other | src: x = y | by: f\n- scope cedar = orchid-service\n");
  expect(w.pair("4 an app in two scopes is no ambiguity", G()).err).toContain("MODE MISMATCH - the repo-knowledge record declares scopes");
  // awk's `.` takes the CR with the rest of ` | src: ...`, so this one is live
  record(MAP.replace("\n", "\r\n"));
  expect(w.pair("4 a CRLF line cut at its src", G()).err).toContain("MODE MISMATCH - the repo-knowledge record declares scopes");
  if (!ROOTUSER) {
    record(MAP);
    w.both((r) => chmodSync(join(r, "home/records/repo-knowledge/g.md"), 0));
    expect(w.pair("4 unreadable record", G()).err).toBe(AMB);
    w.both((r) => chmodSync(join(r, "home/records/repo-knowledge/g.md"), 0o644));
  }
  // 5. SCOPED: the bare marker named (even empty), strays skipped and named in
  //    byte order, a directory skipped unnamed, an invalid body with its error,
  //    two pairs byte-ordered, a genuine pair beside strays
  yaml(SCOPED);
  record(MAP);
  mark("", "");
  const BARE = " A bare sha-only marker IS on disk; it names no scope+app, so it proves nothing about WHICH profile ran and cannot satisfy the gate here - re-run crew-qa naming the scope and app.";
  const SCOPEDFAIL = `WARN: qa.require_for_ship: no passing crew-qa run recorded for ${sha12} on this SCOPED project - a run must name the scope+app it proved.`;
  expect(w.pair("5 bare only", G()).err).toBe(`${SCOPEDFAIL}${BARE}\n`);
  mark(".a", "x");
  mark(".a.b.c", "x");
  mark(".a b.c", "x");
  mark("..", "x");
  mark(".", "x");
  mark(".orchid.svc", marker(sha, "orchid", "svc", { schema: "v1" }));
  w.both((r) => mkdirSync(join(r, `home/projects/g/.crew/qa/passed/${sha}.d.x`)));
  // 10. a name outside the C grammar is skipped and named by its bytes
  mark(".café.x", "x");
  expect(w.pair("5 strays", G()).err).toBe(
    `${SCOPEDFAIL}${BARE} Malformed markers ignored: ${sha}. ${sha}.. ${sha}.a ${sha}.a b.c ${sha}.a.b.c ${sha}.${L8("café")}.x ${sha}.orchid.svc(unsupported schema)\n`,
  );
  mark("", null);
  mark(".b.x", marker(sha, "b", "x"));
  mark(".a.y", marker(sha, "a", "y"));
  expect(w.pair("5 two pairs beside strays", G())).toEqual({ out: `qa: passed profiles for ${sha12}: a/y b/x\n#0`, err: "", rc: 0, tree: ["records", "records/repo-knowledge", "records/repo-knowledge/g.md", "state"] });
  mark(".a.y", marker(sha, "a", "z"));
  expect(w.pair("5 one pair, one body mismatch", G()).out).toBe(`qa: passed profiles for ${sha12}: b/x\n#0`);
  mark(".b.x", null);
  expect(w.pair("5 only mismatches", G()).err).toBe(
    `${SCOPEDFAIL} Malformed markers ignored: ${sha}. ${sha}.. ${sha}.a ${sha}.a b.c ${sha}.a.b.c ${sha}.a.y(scope/app body mismatch) ${sha}.${L8("café")}.x ${sha}.orchid.svc(unsupported schema)\n`,
  );
  // `$(basename)` cut the name's trailing LF, so this one is the pair c/z
  mark(".c.z\n", marker(sha, "c", "z"));
  expect(w.pair("5 a name ending in LF", G()).out).toBe(`qa: passed profiles for ${sha12}: c/z\n#0`);
  // 9. the RETIRED die through the gate
  w.both((r) => put(r, "home/config/projects/g.yaml", REQ));
  expect(w.pair("9 RETIRED", G())).toEqual({
    out: "",
    err: RETIRED("g"),
    rc: 1,
    tree: ["config", "config/projects", "config/projects/g.yaml", "records", "records/repo-knowledge", "records/repo-knowledge/g.md", "state"],
  });
}, 120000);

test("G: the required-profile matrix arm - a manifest's presence selects it, its jq reading (W10), the key grammar (W12), tab collapse (W11), the pins, the success line - and the staged-id family, a linked worktree", () => {
  const w = new World();
  w.both((r) => gitRepo(join(r, "home", "projects", "g")));
  const REPO = "HOME/home/projects/g";
  const sha = headOf(join(w.n, "home/projects/g"));
  const sha12 = sha.slice(0, 12);
  const G = (task = "t", more: Partial<Row> = {}): Row => ({ fn: "ac_qa_gate_ok", args: [REPO, sha, task], ...more });
  const manifest = (body: string | null, fam = "t"): void => w.both((r) => (body === null ? rm(r, `home/data/${fam}/qa/manifest.json`) : put(r, `home/data/${fam}/qa/manifest.json`, body)));
  const mark = (suffix: string, body: string | null): void =>
    w.both((r) => (body === null ? rm(r, `home/projects/g/.crew/qa/passed/${sha}${suffix}`) : put(r, `home/projects/g/.crew/qa/passed/${sha}${suffix}`, body)));
  const req = (...keys: string[]): string => JSON.stringify({ required_profiles: keys.map((k) => ({ profile_key: k })) });
  const M = "HOME/home/data/t/qa/manifest.json";
  const EMPTY = `WARN: qa.require_for_ship: the task's required-profile manifest is empty or unreadable (${M}) - refusing rather than merging against an undefined required set\n`;
  const NOKEY = `WARN: qa.require_for_ship: a required-profile manifest entry has no profile_key (${M}) - refusing rather than guessing which profile it means\n`;
  const missing = (key: string): string =>
    `WARN: qa.require_for_ship: required profile '${key}' has no passing crew-qa attestation for ${sha12} - run crew-qa for EVERY required profile at this head before merging\n`;
  const BASE = ["data", "data/t", "data/t/qa", "data/t/qa/manifest.json", "records", "state"];

  w.both((r) => put(r, "home/projects/g.yaml", REQ));
  // no manifest: the two-sided arm, data/ minted by the family lookup (W7)
  expect(w.pair("6 no manifest", G())).toEqual({ out: "#1", err: `WARN: qa.require_for_ship: no passing crew-qa run recorded for ${sha12} - run crew-qa on this head before merging\n`, rc: 0, tree: ["data", "records", "state"] });
  w.both((r) => mkdirSync(join(r, "home/data/t/qa/manifest.json"), { recursive: true }));
  expect(w.pair("6 a directory at the manifest (W9)", G()).err).toContain("no passing crew-qa run recorded");
  w.both((r) => rm(r, "home/data/t"));
  for (const [name, body] of [
    ["[]", "[]\n"],
    ["not json", "not json\n"],
    ["no profiles", "{}"],
    ["string element", '{"required_profiles":["g/s/a"]}'],
    ["object profile_key", '{"required_profiles":[{"profile_key":{"x":1}}]}'],
    ["trailing garbage after a good row", '{"required_profiles":[{"profile_key":"g/s/a"}]} garbage'],
    ["empty", ""],
  ] as const) {
    manifest(body);
    expect(w.pair(`6 ${name}`, G())).toEqual({ out: "#1", err: EMPTY, rc: 0, tree: BASE });
  }
  manifest(req("g/s/a"));
  expect(w.pair("6 jq absent", G("t", { path: pathWithout("jq") })).err).toBe(EMPTY);
  manifest('{"required_profiles":[null]}');
  expect(w.pair("6 null element", G()).err).toBe(NOKEY);
  manifest('{"required_profiles":[{"profile_key":""}]}');
  expect(w.pair("6 empty key", G()).err).toBe(NOKEY);
  manifest('{"required_profiles":[{"profile_key":"g/s/a"},{"profile_sha256":"p"}]}');
  mark(".s.a", marker(sha, "s", "a"));
  // W11: an entry without a key reads its profile_sha256 AS the key
  expect(w.pair("6 keyless entry (W11)", G()).err).toBe(missing("p"));
  manifest('{"required_profiles":[{"profile_key":"g/s/a","e2e_sha":"E"}]}');
  // W11: an e2e pin with no profile pin lands in the profile pin
  expect(w.pair("6 e2e pin shifts (W11)", G()).err).toBe(
    `WARN: qa.require_for_ship: the attestation for 'g/s/a' is invalid (profile hash mismatch) - re-run crew-qa for this exact profile and head\n`,
  );
  // W12: the last two segments only; the project segment is never compared
  for (const key of ["s/a", "x/y/s/a", "other/s/a"]) {
    manifest(req(key));
    expect(w.pair(`6 key ${key}`, G())).toEqual({ out: `qa: all 1 required profile(s) satisfied for ${sha12}: ${key}\n#0`, err: "", rc: 0, tree: BASE });
  }
  mark(".a.a", marker(sha, "a", "a"));
  manifest(req("a"));
  expect(w.pair("6 key a", G()).out).toBe(`qa: all 1 required profile(s) satisfied for ${sha12}: a\n#0`);
  manifest(req("p/s/"));
  expect(w.pair("6 key p/s/", G()).err).toBe("WARN: qa.require_for_ship: required profile 'p/s/' does not parse to <project>/<scope>/<app> (app segment invalid) - fix the task manifest\n");
  manifest(req("/a"));
  expect(w.pair("6 key /a", G()).err).toBe("WARN: qa.require_for_ship: required profile '/a' does not parse to <project>/<scope>/<app> (scope segment invalid) - fix the task manifest\n");
  manifest(req("g/s.x/a"));
  expect(w.pair("6 key with a dot", G()).err).toContain("(scope segment invalid)");
  manifest(req("g/s/a\tb"));
  expect(w.pair("6 key with a tab (@tsv escapes it)", G()).err).toContain("required profile 'g/s/a\\tb' does not parse");
  manifest(req("g/café/a"));
  expect(w.pair("6 key with UTF-8", G()).err).toContain("(scope segment invalid)");
  // the object-valued set iterates its values; two documents are both read; a duplicate key counts twice
  manifest('{"required_profiles":{"k":{"profile_key":"g/s/a"}}}');
  expect(w.pair("6 object-valued", G()).out).toBe(`qa: all 1 required profile(s) satisfied for ${sha12}: g/s/a\n#0`);
  manifest(`${req("g/s/a")}\n${req("g/a/a")}\n`);
  expect(w.pair("6 two documents", G()).out).toBe(`qa: all 2 required profile(s) satisfied for ${sha12}: g/s/a g/a/a\n#0`);
  manifest(req("g/s/a", "g/s/a"));
  expect(w.pair("6 a duplicate key", G()).out).toBe(`qa: all 2 required profile(s) satisfied for ${sha12}: g/s/a g/s/a\n#0`);
  // one of two missing; the pins; a marker that is a directory; jq's number spelling
  manifest(req("g/s/a", "g/cedar/svc"));
  expect(w.pair("6 one of two", G()).err).toBe(missing("g/cedar/svc"));
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":"p"}]}');
  expect(w.pair("6 profile pin hit", G()).out).toContain("all 1 required");
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":"q"}]}');
  expect(w.pair("6 profile pin miss", G()).err).toContain("(profile hash mismatch)");
  mark(".s.a", marker(sha, "s", "a", { e2e_repo: "r", e2e_sha: "e" }));
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":"p","e2e_sha":"e"}]}');
  expect(w.pair("6 e2e pin hit", G()).out).toContain("all 1 required");
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":"p","e2e_sha":"f"}]}');
  expect(w.pair("6 e2e pin miss", G()).err).toContain("(E2E hash mismatch)");
  mark(".s.a", marker(sha, "s", "a", { profile_sha256: "1.0" }));
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":1.0}]}');
  expect(w.pair("6 a 1.0 pin keeps jq's spelling", G()).out).toContain("all 1 required");
  manifest('{"required_profiles":[{"profile_key":"g/s/a","profile_sha256":false}]}');
  expect(w.pair("6 a false pin is no pin", G()).out).toContain("all 1 required");
  mark(".s.a", null);
  w.both((r) => mkdirSync(join(r, `home/projects/g/.crew/qa/passed/${sha}.s.a`)));
  manifest(req("g/s/a"));
  expect(w.pair("6 marker a directory", G()).err).toBe(missing("g/s/a"));
  w.both((r) => rm(r, `home/projects/g/.crew/qa/passed/${sha}.s.a`));
  mark(".s.a", marker(sha, "s", "a"));
  // the matrix arm reads no mode: a scoped yaml with no map passes it
  w.both((r) => put(r, "home/projects/g.yaml", SCOPED));
  expect(w.pair("6 no mode read", G()).out).toContain("all 1 required");
  w.both((r) => put(r, "home/projects/g.yaml", REQ));
  // 7. a staged id: fam-ship reads data/fam/ only when data/fam/ship exists
  manifest(req("g/s/a"), "fam");
  expect(w.pair("7 fam-ship, no stage dir", G("fam-ship")).err).toContain("no passing crew-qa run recorded");
  w.both((r) => mkdirSync(join(r, "home/data/fam/ship"), { recursive: true }));
  expect(w.pair("7 fam-ship, stage dir", G("fam-ship")).out).toContain("all 1 required");
  // 8. a linked worktree: the main repo's markers, yaml and manifest
  w.both((r) => expect(Bun.spawnSync(["git", "-C", join(r, "home/projects/g"), "worktree", "add", "-q", "--detach", join(r, "wt")]).exitCode).toBe(0));
  expect(w.pair("8 linked worktree", { fn: "ac_qa_gate_ok", args: ["HOME/wt", sha, "t"] }).out).toBe(`qa: all 1 required profile(s) satisfied for ${sha12}: g/s/a\n#0`);
}, 120000);

test("G, under a UTF-8 locale: sha12 cuts characters alike; a `<sha>.é.x` marker and a `g/é/x` required profile are off the name grammar on both sides; the scope map and qa.scopes are read in the C locale, so a byte that is no UTF-8 in either reads as it does under C; the candidates' order is the one NAMED divergence", () => {
  const w = new World();
  w.both((r) => gitRepo(join(r, "home", "projects", "g")));
  const REPO = "HOME/home/projects/g";
  const UTF8 = { LC_ALL: "en_US.UTF-8" };
  w.both((r) => put(r, "home/projects/g.yaml", REQ));
  const e13 = "é".repeat(13);
  const got = w.pair("11 sha12 of a multibyte sha", { fn: "ac_qa_gate_ok", args: [REPO, e13], env: UTF8 });
  expect(got.err).toBe(`WARN: qa.require_for_ship: no passing crew-qa run recorded for ${L8("é".repeat(12))} - run crew-qa on this head before merging\n`);
  const underC = w.pair("11 sha12 under C", { fn: "ac_qa_gate_ok", args: [REPO, e13] });
  expect(underC.err).toContain(`recorded for ${L8("é".repeat(6))} - run`);
  const sha = headOf(join(w.n, "home/projects/g"));
  const sha12 = sha.slice(0, 12);
  w.both((r) => {
    put(r, "home/projects/g.yaml", SCOPED);
    put(r, "home/records/repo-knowledge/g.md", MAP);
    put(r, `home/projects/g/.crew/qa/passed/${sha}.é.x`, marker(sha, "é", "x"));
  });
  const row: Row = { fn: "ac_qa_gate_ok", args: [REPO, sha], env: UTF8 };
  const strayE = w.pair("11 a <sha>.é.x marker", row);
  expect({ out: strayE.out, err: strayE.err }).toEqual({
    out: "#1",
    err: `WARN: qa.require_for_ship: no passing crew-qa run recorded for ${sha12} on this SCOPED project - a run must name the scope+app it proved. Malformed markers ignored: ${sha}.${L8("é")}.x\n`,
  });
  expect(w.pair("11 é under C", { fn: "ac_qa_gate_ok", args: [REPO, sha] }).out).toBe("#1");
  // NAMED divergence: the bash's glob lists the candidates in the caller's
  // collation (`a` before `B` under UTF-8), the twin in byte order.
  w.both((r) => {
    rm(r, `home/projects/g/.crew/qa/passed/${sha}.é.x`);
    put(r, `home/projects/g/.crew/qa/passed/${sha}.a.y`, marker(sha, "a", "y"));
    put(r, `home/projects/g/.crew/qa/passed/${sha}.B.x`, marker(sha, "B", "x"));
  });
  const orderWant = oracle(w.o, row);
  expect(orderWant.out).toBe(`qa: passed profiles for ${sha12}: a/y B/x\n#0`);
  expect(twin(w.n, row)).toEqual({ ...orderWant, out: `qa: passed profiles for ${sha12}: B/x a/y\n#0` });
  w.both((r) => ["a.y", "B.x"].forEach((m) => rm(r, `home/projects/g/.crew/qa/passed/${sha}.${m}`)));
  w.both((r) => put(r, "home/data/t/qa/manifest.json", JSON.stringify({ required_profiles: [{ profile_key: "g/é/x" }] })));
  const keyE = w.pair("11 a g/é/x required profile", { fn: "ac_qa_gate_ok", args: [REPO, sha, "t"], env: UTF8 });
  expect({ out: keyE.out, err: keyE.err }).toEqual({
    out: "#1",
    err: `WARN: qa.require_for_ship: required profile '${L8("g/é/x")}' does not parse to <project>/<scope>/<app> (scope segment invalid) - fix the task manifest\n`,
  });
  w.both((r) => rm(r, "home/data/t"));
  // A byte that is no UTF-8 in a scope line's src: the map still reads, and a
  // genuine pair passes.
  w.both((r) => {
    put(r, "home/records/repo-knowledge/g.md", Buffer.from("- scope orchid = orchid-service | src: caf\xe9\n", "latin1"));
    put(r, `home/projects/g/.crew/qa/passed/${sha}.orchid.orchid-service`, marker(sha, "orchid", "orchid-service"));
  });
  const mapE = w.pair("11 a byte that is no UTF-8 in the scope map", row);
  expect(mapE.out).toBe(`qa: passed profiles for ${sha12}: orchid/orchid-service\n#0`);
  // ...and one PAST the require_for_ship line, beside qa.scopes: the yaml is
  // still scoped, so with no map the mode is refused and the bare marker
  // proves nothing.
  w.both((r) => {
    put(r, "home/projects/g.yaml", Buffer.from("qa:\n  require_for_ship: true\n  note: caf\xe9\n  scopes:\n    orchid: {}\n", "latin1"));
    rm(r, "home/records/repo-knowledge/g.md");
    put(r, `home/projects/g/.crew/qa/passed/${sha}`, marker(sha));
  });
  const yamlE = w.pair("11 a byte that is no UTF-8 past the policy line", row);
  expect({ out: yamlE.out, err: yamlE.err }).toEqual({
    out: "#1",
    err: "WARN: qa.require_for_ship: MODE MISMATCH - the fleet-home config declares scopes but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped and no marker can be read against a mode. Refusing the merge.\n",
  });
}, 60000);
