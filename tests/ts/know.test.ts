// know.test.ts - what src/know.ts brought into src/lib.ts, held to the LIVE
// bash it twins: homeResolve (ac_home_resolve's whole ladder), shellLength
// (bash 3.2's `${#v}`) and shellPrefix as recall's quote reads it (`cut
// -c1-60`); and src/know.ts's value-flag arms, which
// tests/sh/flag-values.test.sh's static grep over bin/*.sh no longer sees
// now that bin/ac-know.sh is a shim. The CLI contract itself is
// tests/sh/ac-know.test.sh's, whose differential leg runs the frozen
// original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home, repos at <side>/<name> built by the same git commands with fixed dates); argv; env (PATH = the host's bun and git, /bin and /usr/bin without herdr, orca, docker or codegraph; LC_ALL=C unless a row names UTF-8; HOME, TMPDIR, AC_HOME only where a row sets it); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status compared whole (the side root spelled S).
import { afterAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-know-ts-")));
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
for (const t of ["bun", "git"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const PATH = `${TOOLS}:${BASE}`;
const GIT_ENV = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z", GIT_CONFIG_NOSYSTEM: "1" };

type Row = {
  // the bash call, run after sourcing ac-lib.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  lc?: string;
};
type Side = { out: string; err: string; rc: number | null };

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: row.lc ?? "C", ...GIT_ENV };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
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
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), rc: r.exitCode };
}

function pair(row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(join(s, "home"), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]! };
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const git = (...args: string[]): void => {
  Bun.spawnSync(["git", ...args], { env: { PATH, HOME: W, ...GIT_ENV }, stdin: "ignore", stdout: "ignore", stderr: "ignore" });
};

// A clone at <s>/home/projects/proj with one commit, a linked worktree of it
// outside the main dir at <s>/wt, a plain directory and a link back into the
// repo.
function world(s: string): void {
  const r = join(s, "home", "projects", "proj");
  git("init", "-q", "-b", "main", r);
  git("-C", r, "commit", "-q", "--allow-empty", "-m", "init");
  git("-C", r, "worktree", "add", "-q", "--detach", join(s, "wt"));
  mkdirSync(join(r, ".crew", "h"), { recursive: true });
  mkdirSync(join(s, "wt", "h"), { recursive: true });
  mkdirSync(join(s, "plain", "h"), { recursive: true });
  symlinkSync(join(r, ".crew", "h"), join(s, "evil"));
  writeFileSync(join(s, "file"), "x\n");
}

// The ladder's refusals end the run (ac_die there, die here), so the bash is
// called bare: a refusal prints no rc on either side.
const RESOLVE: Row = {
  bash: `ac_home_resolve "$1" "$2"`,
  twin: `const h = L.homeResolve(A[0], A[1]); if (h !== "") writeSync(1, h + "\\n"); return 0;`,
  seed: world,
};

test("homeResolve: --home absolute, enterable and physically outside the main repo root", () => {
  const cases: [string, string][] = [
    ["@S/home", "@S/home/projects/proj"],
    ["@S/home/", "@S/home/projects/proj/"],
    ["@S/home/projects/../", "@S/home/projects/proj"],
    ["home", "@S/home/projects/proj"],
    ["./home", "@S/home/projects/proj"],
    ["@S/nope", "@S/home/projects/proj"],
    ["@S/file", "@S/home/projects/proj"],
    ["@S/home/projects/proj", "@S/home/projects/proj"],
    ["@S/home/projects/proj/.crew/h", "@S/home/projects/proj"],
    ["@S/evil", "@S/home/projects/proj"],
    ["@S/evil/", "@S/wt"],
    ["@S/wt/h", "@S/wt"],
    ["@S/plain/h", "@S/plain"],
    ["@S/plain", "@S/plain"],
    ["@S/plain/h", "@S/gone"],
    ["@S/home/projects/proj-other", "@S/home/projects/proj"],
    ["/", "@S/home/projects/proj"],
  ];
  for (const [flag, repo] of cases) same(`--home ${flag} for ${repo}`, { ...RESOLVE, args: [flag, repo] });
  expect(same("inside", { ...RESOLVE, args: ["@S/evil", "@S/home/projects/proj"] }).t.err).toBe(
    "ERROR: --home must be an ABSOLUTE path outside the project repo: S/evil resolves to S/home/projects/proj/.crew/h, inside S/home/projects/proj\n",
  );
  expect(same("W16", { ...RESOLVE, args: ["@S/wt/h", "@S/wt"] }).t.out).toBe("S/wt/h\n|rc=0");
});

test("homeResolve: AC_HOME unguarded when --home is empty, and nothing at all is ''", () => {
  same("AC_HOME", { ...RESOLVE, args: ["", "@S/home/projects/proj"], env: { AC_HOME: "@S/home" } });
  same("AC_HOME inside the repo (W16)", { ...RESOLVE, args: ["", "@S/home/projects/proj"], env: { AC_HOME: "@S/home/projects/proj/.crew/h" } });
  same("AC_HOME through a link", { ...RESOLVE, args: ["", "@S/home/projects/proj"], env: { AC_HOME: "@S/evil" } });
  same("--home wins", { ...RESOLVE, args: ["@S/plain", "@S/home/projects/proj"], env: { AC_HOME: "@S/nope" } });
  expect(same("no home", { ...RESOLVE, args: ["", "@S/home/projects/proj"] }).t.out).toBe("|rc=0");
  // HOME RESOLUTION (named): the bash printed cd's own line and went on.
  const p = pair({ ...RESOLVE, args: ["", "@S/home/projects/proj"], env: { AC_HOME: "@S/nope" } });
  expect(p.o.out).toBe("|rc=1");
  expect(p.o.err).toMatch(new RegExp(`^${BIN}/ac-lib\\.sh: line [0-9]+: cd: S/nope: No such file or directory\n$`));
  expect([p.t.out, p.t.err, p.t.rc]).toEqual(["", "ERROR: AC_HOME is not a readable directory: S/nope\n", 1]);
});

const LENGTH: Row = {
  bash: `v="$(cat "$1")"; printf '%s' "\${#v}"`,
  twin: `writeSync(1, String(L.shellLength(require("node:fs").readFileSync(A[0], "latin1")))); return 0;`,
};
const PREFIX: Row = {
  bash: `q="$(printf '%s' "$(cat "$1")" | cut -c1-60)"; printf '%s' "$q"`,
  twin: `writeSync(1, Buffer.from(L.shellPrefix(require("node:fs").readFileSync(A[0], "latin1"), 60), "latin1")); return 0;`,
};
const TEXTS: string[] = [
  "",
  "plain ascii",
  "caf\xc3\xa9 \xe2\x80\x94 \xe2\x86\x92 \xf0\x9f\x98\x80",
  "unicode budget probe a" + " \xc3\xa9".repeat(40),
  "x".repeat(59) + "\xc3\xa9\xc3\xa9",
  "the chief's watcher beacon grace is three hundred seconds, it's said",
];
// Strict UTF-8 only: an invalid byte is one character to `${#v}`, while cut
// aborts on it - the FAIL-PATH recall never reaches (its awk aborted first).
const BAD: string[] = ["caf\xe9", "\xe2\x82", "\xc0\xafz", "\xed\xa0\x80"];

test("shellLength: ${#v} - characters under a UTF-8 locale (an invalid byte one each), bytes under C", () => {
  for (const lc of ["C", "en_US.UTF-8", "POSIX"])
    for (const [i, t] of [...TEXTS, ...BAD].entries())
      same(`length ${i} under ${lc}`, { ...LENGTH, lc, args: ["@S/v"], seed: (s) => writeFileSync(join(s, "v"), Buffer.from(t, "latin1")) });
  const p = same("UTF-8", { ...LENGTH, lc: "en_US.UTF-8", args: ["@S/v"], seed: (s) => writeFileSync(join(s, "v"), Buffer.from(TEXTS[3]!, "latin1")) });
  expect(p.t.out).toBe("102|rc=0");
});

test("shellPrefix: recall's quote, `cut -c1-60` over valid UTF-8 under either locale", () => {
  for (const lc of ["C", "en_US.UTF-8"])
    for (const [i, t] of TEXTS.entries())
      same(`prefix ${i} under ${lc}`, { ...PREFIX, lc, args: ["@S/v"], seed: (s) => writeFileSync(join(s, "v"), Buffer.from(t, "latin1")) });
});

// tests/sh/flag-values.test.sh read every bash flag arm for an unguarded
// `shift 2`; the module's arms are pinned here instead, each value flag as
// the last word, before anything is read.
test("src/know.ts: every value flag as the last word is `<flag> needs a value`, exit 1", () => {
  const verbs: [string[], string[]][] = [
    [["add"], ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--fact", "--supersede"]],
    [["retire"], ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--quote", "--by", "--why"]],
    [["cite"], ["--home", "--repo", "--quote", "--by"]],
    [["recall", "q"], ["--home", "--repo", "--max", "--bytes"]],
    [["verify"], ["--home", "--repo"]],
    [["scope-proposal"], ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--scope", "--apps", "--why", "--id"]],
    [["scope-install", "p1"], ["--home", "--repo"]],
  ];
  for (const [verb, flags] of verbs)
    for (const f of flags) {
      const r = Bun.spawnSync([process.execPath, "--no-env-file", join(ROOT, "src", "know.ts"), W, ...verb, f], { cwd: ROOT, env: { PATH, HOME: W, LC_ALL: "C" }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      expect({ verb: verb[0], f, out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode }).toEqual({ verb: verb[0], f, out: "", err: `ERROR: ${f} needs a value\n`, rc: 1 });
    }
});
