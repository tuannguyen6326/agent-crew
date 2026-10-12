// ship.test.ts - what src/ship.ts brought into src/lib.ts, held to the LIVE
// bash it twins, which the frozen tests/fixtures/ac-qa.sh and ac-spawn.sh
// keep calling: yamlGet (ac_yaml_get), findingsNormalize and findingsSummary (ac_findings_normalize,
// ac_findings_summary) and projectConfigFile (ac_project_config_file as its
// `$(...)` callers read it). The CLI contract is tests/sh/ac-ship.test.sh's,
// whose differential leg runs the frozen original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (yaml, findings input and a git repo with a home under it); argv; env (PATH = the host's bun, jq and git, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C unless a row names en_US.UTF-8; HOME and TMPDIR the test root; AC_HOME and AC_FINDINGS_* where a row sets them); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status (the side root spelled S) and the side root's world after the call - every path with its mode and bytes - compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-ship-ts-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph", "jq", "git"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "jq", "git"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const PATH = `${TOOLS}:${BASE}`;

type Row = {
  // the bash call, run after sourcing ac-lib.sh and ac-pipeline-lib.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
};
type Side = { out: string; err: string; world: string; status: number | null };

function world(s: string): string {
  const lines: string[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      const st = lstatSync(p);
      const rel = p.slice(s.length);
      if (rel.startsWith("/repo/.git")) continue;
      if (st.isSymbolicLink()) lines.push(`${rel} -> ${readlinkSync(p)}`);
      else if (st.isDirectory()) {
        lines.push(`${rel}/ ${(st.mode & 0o7777).toString(8)}`);
        walk(p);
      } else {
        let body = "<unreadable>";
        try {
          body = readFileSync(p, "latin1");
        } catch {}
        lines.push(`${rel} ${(st.mode & 0o7777).toString(8)}\n${body}`);
      }
    }
  };
  walk(s);
  return lines.join("\n");
}

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: "C" };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/../tests/fixtures/ac-pipeline-lib.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { readFileSync, writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; let rc; try { rc = await (async () => { ${row.twin} })(); } catch (e) { rc = "throw:" + (e.code ?? e.message); } writeSync(1, "|rc=" + rc);`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  // mktemp names its failed attempt by a random suffix.
  const norm = (t: string): string => t.replaceAll(s, "S").replace(/(mkstemp failed on [^:\n]*\.)[A-Za-z0-9]{6}:/g, "$1XXXXXX:");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
}

function pair(row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(s, { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]! };
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const put = (p: string, b: string | Buffer): void => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, b);
};

const YAML = `# leading comment
commands:
  test: "echo quoted"
  lint: 'single'
  format:
  test-changed: printf '[%s]\\n' {files}
review:
  max_rounds: 7
   odd: three spaces
  nested:
    deep: value with: colon
test:
  evidence:
    store_in_repo: true
 one: space
auto_fix:
  lint: 5
`;
const GET: Row = {
  bash: `ac_yaml_get "$1" "$2"`,
  twin: `const r = L.yamlGet(A[0], A[1]); writeSync(1, Buffer.from(r.out, "latin1")); return r.status;`,
};

test("yamlGet: awk's own reading of the flat nested-scalar subset", () => {
  const seed = (s: string): void => put(join(s, "c.yaml"), YAML);
  for (const key of ["commands.test", "commands.lint", "commands.format", "commands.test-changed", "review.max_rounds", "review.odd", "review.nested.deep", "test.evidence.store_in_repo", "one", "auto_fix.lint", "commands", "nope", "commands.nope", "", "a\\nb"])
    same(`key ${key}`, { ...GET, args: ["@S/c.yaml", key], seed });
  same("a missing file", { ...GET, args: ["@S/none.yaml", "commands.test"] });
  same("a directory", { ...GET, args: ["@S", "commands.test"] });
}, 60_000);

test("yamlGet: an invalid byte at or before the key aborts under a UTF-8 locale (W10), awk's own lines on stderr; quiet drops them", () => {
  const seed = (s: string): void => put(join(s, "c.yaml"), Buffer.from('doc: "caf\xe9"\ncommands:\n  test: "echo t"\n', "latin1"));
  for (const lc of ["C", "en_US.UTF-8"]) {
    const p = same(`${lc}`, { ...GET, args: ["@S/c.yaml", "commands.test"], seed, env: { LC_ALL: lc } });
    if (lc !== "C") expect(p.o.out).toBe("|rc=2");
    same(`${lc} quiet`, { bash: `ac_yaml_get "$1" "$2" 2>/dev/null`, twin: `const r = L.yamlGet(A[0], A[1], true); writeSync(1, Buffer.from(r.out, "latin1")); return r.status;`, args: ["@S/c.yaml", "commands.test"], seed, env: { LC_ALL: lc } });
  }
}, 60_000);

const NORMALIZE: Row = {
  bash: `ac_findings_normalize "$1" <"$2"`,
  twin: `return L.findingsNormalize(A[0], readFileSync(A[1]));`,
  args: ["@S/out.json", "@S/in.json"],
};
const FINDINGS = JSON.stringify([
  { id: "a", severity: "error", title: "legacy title" },
  { id: "b", action: "", detail: "d" },
  { id: "c", action: "auto-fix", severity: "warning", authority_class: "internal", authority: "x" },
  { id: "d", action: "fix", severity: "info", authority_class: "internal", authority: "x" },
  { id: "e", action: "fix", severity: "warning", authority_class: "weird", authority: "  " },
  { id: "f", action: "fix", severity: "warning", file: "out.txt", authority_class: "internal", authority: "x" },
  { id: "g", action: "fix", severity: "warning", file: "in.txt", authority_class: "internal", authority: "x" },
  { id: "h", action: "fix", severity: "error", class: "security", file: "out.txt", authority_class: "internal", authority: "x" },
  { id: "i", action: "fix", severity: "error", file: "out.txt", authority_class: "internal", authority: "x" },
  { id: "j", action: "ask-user", description: "pick", decision: "a\tb\r\nc", options: ["x", "y", "z"], tradeoffs: ["1"], axis: "security", decider: "captain", impact: ["p", "q", "r"] },
  { id: "k", action: "ask-user", question: "  ", options: "no", recommendation: " ", axis: "bogus", decider: " ", impact: ["1"] },
  { action: "no-op", description: "n" },
]);

test("findingsNormalize: the normalizer's bytes, mode and status under every round metadata the environment can carry", () => {
  const seed = (s: string): void => put(join(s, "in.json"), `${FINDINGS}\n`);
  same("round 1", { ...NORMALIZE, seed });
  same("round 2 with a prior-open set", { ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "2", AC_FINDINGS_DELTA: "in.txt\nother", AC_FINDINGS_PRIOR_OPEN: '["f"]' } });
  same("round 2 with no prior-open set floors nothing", { ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "2", AC_FINDINGS_DELTA: "in.txt" } });
  same("round 2 with a malformed prior-open set", { ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "2", AC_FINDINGS_PRIOR_OPEN: "[1]" } });
  same("round 02 reads as 2", { ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "02", AC_FINDINGS_PRIOR_OPEN: "[]" } });
  same("round abc reads as 1", { ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "abc", AC_FINDINGS_PRIOR_OPEN: "[]" } });
  // Past int64 the bash's `[ -ge ]` printed its own `integer expression
  // expected` line (SHELL-OWN, not reproduced) and read false; jq still read
  // the round as a number.
  const big = pair({ ...NORMALIZE, seed, env: { AC_FINDINGS_ROUND: "99999999999999999999", AC_FINDINGS_PRIOR_OPEN: "[]", AC_FINDINGS_DELTA: "in.txt" } });
  expect(big.o.err).toContain("integer expression expected");
  expect([big.t.out, big.t.status, big.t.world, big.t.err]).toEqual([big.o.out, big.o.status, big.o.world, ""]);
  same("a call's own round metadata overrides the inherited one (review-agent's prefix assignments)", {
    bash: `AC_FINDINGS_ROUND=2 AC_FINDINGS_DELTA=in.txt AC_FINDINGS_PRIOR_OPEN='["i"]' ac_findings_normalize "$1" <"$2"`,
    twin: `return L.findingsNormalize(A[0], readFileSync(A[1]), { round: "2", delta: "in.txt", prior: '["i"]' });`,
    args: ["@S/out.json", "@S/in.json"],
    seed,
    env: { AC_FINDINGS_ROUND: "1", AC_FINDINGS_DELTA: "x", AC_FINDINGS_PRIOR_OPEN: "[]" },
  });
  same("an element that is no object fails, no temp left", { ...NORMALIZE, seed: (s) => put(join(s, "in.json"), "[1,2]\n") });
  same("not JSON", { ...NORMALIZE, seed: (s) => put(join(s, "in.json"), "{\n") });
  same("an outfile whose dir is missing", { ...NORMALIZE, seed, args: ["@S/no/out.json", "@S/in.json"] });
  same("an existing outfile is replaced whole", {
    ...NORMALIZE,
    seed: (s) => {
      seed(s);
      put(join(s, "out.json"), "old\n");
      chmodSync(join(s, "out.json"), 0o644);
    },
  });
}, 60_000);

test("findingsSummary: jq's counts by action, its failure as jq's", () => {
  const SUMMARY: Row = { bash: `ac_findings_summary "$1"`, twin: `const r = L.findingsSummary(A[0]); writeSync(1, Buffer.from(r.out, "latin1")); return r.status;`, args: ["@S/f.json"] };
  same("empty", { ...SUMMARY, seed: (s) => put(join(s, "f.json"), "[]") });
  same("mixed", { ...SUMMARY, seed: (s) => put(join(s, "f.json"), '[{"action":"fix"},{"action":"no-op"},{"action":"fix"},{"action":"ask-user"},{}]') });
  same("corrupt", { ...SUMMARY, seed: (s) => put(join(s, "f.json"), "[{") });
  same("missing", SUMMARY);
}, 60_000);

const CONFIG: Row = {
  bash: `f="$(ac_project_config_file "$1")"; rc=$?; printf '%s' "$f"; (exit "$rc")`,
  twin: `const f = L.projectConfigFile(A[0]); writeSync(1, f ?? ""); return f === null ? 1 : 0;`,
  args: ["@S/repo"],
};
const repoWithHome = (s: string, files: Record<string, string> = {}): void => {
  Bun.spawnSync(["git", "init", "-q", join(s, "repo")], { env: { PATH } });
  for (const [rel, body] of Object.entries(files)) put(join(s, "home", rel), body);
  mkdirSync(join(s, "home"), { recursive: true });
};

test("projectConfigFile: the home-only config as `$(...)` reads it - every refusal printed and answered no file", () => {
  same("installed", { ...CONFIG, seed: (s) => repoWithHome(s, { "projects/repo.yaml": "x: 1\n" }), env: { AC_HOME: "@S/home" } });
  same("not installed", { ...CONFIG, seed: (s) => repoWithHome(s), env: { AC_HOME: "@S/home" } });
  same("a directory at the name", { ...CONFIG, seed: (s) => repoWithHome(s, { "projects/repo.yaml/x": "" }), env: { AC_HOME: "@S/home" } });
  const legacy = same("the RETIRED legacy path beside the canonical one", {
    ...CONFIG,
    seed: (s) => repoWithHome(s, { "projects/repo.yaml": "x: 1\n", "config/projects/repo.yaml": "x: 2\n" }),
    env: { AC_HOME: "@S/home" },
  });
  expect(legacy.o.err).toContain("found at the RETIRED legacy path");
  expect(legacy.o.out).toBe("|rc=1");
  const homeless = same("homeless", { ...CONFIG, seed: (s) => repoWithHome(s) });
  expect(homeless.o.err).toContain("ERROR: AC_HOME is not set");
  same("no repo", { ...CONFIG, seed: (s) => mkdirSync(join(s, "repo")), env: { AC_HOME: "@S/home" } });
  same("a linked worktree answers its main repo's name", {
    ...CONFIG,
    args: ["@S/wt"],
    seed: (s) => {
      repoWithHome(s, { "projects/repo.yaml": "x: 1\n" });
      Bun.spawnSync(["git", "-C", join(s, "repo"), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"], { env: { PATH } });
      Bun.spawnSync(["git", "-C", join(s, "repo"), "worktree", "add", "-q", "--detach", join(s, "wt")], { env: { PATH } });
    },
    env: { AC_HOME: "@S/home" },
  });
  const QUIET: Row = { ...CONFIG, bash: `f="$(ac_project_config_file "$1" 2>/dev/null)"; rc=$?; printf '%s' "$f"; (exit "$rc")`, twin: `const f = L.projectConfigFile(A[0], true); writeSync(1, f ?? ""); return f === null ? 1 : 0;` };
  same("quiet legacy", { ...QUIET, seed: (s) => repoWithHome(s, { "projects/repo.yaml": "x: 1\n", "config/projects/repo.yaml": "x: 2\n" }), env: { AC_HOME: "@S/home" } });
  same("quiet homeless", { ...QUIET, seed: (s) => repoWithHome(s) });
}, 60_000);

test("projectConfigFile: an AC_HOME cd cannot enter is named (HOME RESOLUTION), where the bash printed cd's own line", () => {
  const p = pair({ ...CONFIG, seed: (s) => repoWithHome(s), env: { AC_HOME: "@S/nohome" } });
  expect([p.o.out, p.t.out]).toEqual(["|rc=1", "|rc=1"]);
  expect(p.o.err).toContain("cd: S/nohome: No such file or directory");
  expect(p.t.err).toBe("ERROR: AC_HOME is not a readable directory: S/nohome\n");
});
