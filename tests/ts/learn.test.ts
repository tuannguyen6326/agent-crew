// learn.test.ts - what src/learn.ts brought into src/lib.ts, held to the bash
// it twins - learnDue, skillsDir and maintenanceIncomplete to the live readers
// session start keeps (bin/ac-maintenance-lib.sh, bin/ac-lib.sh), the writers
// to their originals frozen at tests/fixtures/ac-maintenance-retired.sh: the
// Learning cadence (learnTick, learnTickKeyed,
// learnGeneration, learnDue, learnReset and the legacy-key migrate under them),
// curateTick, skillsDir (ac_skills_dir), maintenanceIncomplete and
// crewmateLearnedNoLoss; plus src/learn.ts's read-evidence floor, held to the
// lib's AC_MAINTENANCE_QUOTE_MIN. The CLI contract is tests/sh/ac-learn.test.sh's,
// whose differential leg runs the frozen original beside the shim.
//
// DISPUTED: the implementation of each helper (its bash - live or frozen - vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home); argv; env (PATH = a stub dir - date answering one instant, sleep logging to <side>/sleep.log and returning - then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C; HOME and TMPDIR the test root; AC_HOME where a row sets it); cwd (the distro root); stdin (/dev/null); the process started through /bin/sh; stdout, stderr and the status (the side root spelled S, the side's pid PID) and the side root's world after the call - every path with its mode and bytes - compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const LEARN = join(ROOT, "src", "learn.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-learn-ts-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph", "jq", "date", "sleep"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "jq"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
writeFileSync(join(TOOLS, "date"), '#!/bin/sh\ncase "$*" in\n  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;\n  *%s*) echo 1767225600 ;;\n  *) exec /bin/date "$@" ;;\nesac\n');
writeFileSync(join(TOOLS, "sleep"), '#!/bin/sh\nprintf \'%s\\n\' "$*" >>"$SIDE/sleep.log"\n');
chmodSync(join(TOOLS, "date"), 0o755);
chmodSync(join(TOOLS, "sleep"), 0o755);
const PATH = `${TOOLS}:${BASE}`;

type Row = {
  // the bash call, run after sourcing ac-lib.sh, ac-maintenance-lib.sh, ac-bun.sh and the frozen ac-maintenance-retired.sh, its arguments "$@"
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
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-maintenance-lib.sh" || exit $?; . "$0/ac-bun.sh" || exit $?; . "$0/../tests/fixtures/ac-maintenance-retired.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; let rc; try { rc = await (async () => { ${row.twin} })(); } catch (e) { rc = "throw:" + (e.code ?? e.message); } writeSync(1, "|rc=" + rc);`,
      ];
  const r = Bun.spawnSync(["/bin/sh", "-c", 'exec "$@"', "sh", ...cmd], { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const pid = String(r.pid);
  const norm = (t: string): string => t.replaceAll(s, "S").replace(new RegExp(`(^|[^0-9a-f])${pid}([^0-9a-f]|$)`, "g"), "$1PID$2");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
}

function same(label: string, row: Row, ended?: { status: number; code: string; shell: string }): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const sides: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(join(s, "home"), { recursive: true });
    row.seed?.(s);
    sides.push(side(row, s, name === "o"));
  }
  const [o, t] = sides as [Side, Side];
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  if (ended) {
    expect([o.out, o.status, o.err.includes(ended.shell), t.out, t.err]).toEqual(["", ended.status, true, `|rc=throw:${ended.code}`, ""]);
    t.out = o.err = "";
    t.status = o.status;
  }
  expect(view(t)).toEqual(view(o));
  return { o, t };
}

const put = (p: string, b: string | Buffer): void => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, b);
};
const STATE = (s: string, name: string, body: string): void => put(join(s, "home", "state", name), body);
const HOME = { AC_HOME: "@S/home" };

// learn_cadence_call's reading of a cadence function: its words replayed to
// stderr, and 2 for a failure that spoke.
const CADENCE = (call: string): string => `err="$(${call} 2>&1)"; rc=$?; [ -z "$err" ] || printf '%s\\n' "$err" >&2; [ "$rc" -eq 0 ] || [ -z "$err" ] || rc=2; (exit "$rc")`;

test("the read-evidence floor src/learn.ts passes is the lib's AC_MAINTENANCE_QUOTE_MIN", () => {
  const r = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-maintenance-lib.sh"; printf %s "$AC_MAINTENANCE_QUOTE_MIN"`, BIN], { cwd: ROOT, env: { PATH, HOME: W, LC_ALL: "C" }, stdin: "ignore", stdout: "pipe" });
  expect(/^const QUOTE_MIN = ([0-9]+);$/m.exec(readFileSync(LEARN, "utf8"))?.[1]).toBe(r.stdout.toString());
});

test("learnDue and learnGeneration: the counter (the legacy key as fallback) and learn-every, 0 and 8 unless digits", () => {
  const DUE: Row = { bash: `ac_learn_due`, twin: `writeSync(1, L.learnDue().join(" ") + "\\n"); return 0;`, env: HOME };
  const GEN: Row = { bash: `ac_learn_generation`, twin: `writeSync(1, L.learnGeneration() + "\\n"); return 0;`, env: HOME };
  for (const [label, body] of [
    ["absent", null],
    ["set", "generation=3\ndebriefs=7\n"],
    ["the legacy key", "stows=5\n"],
    ["both keys - debriefs wins", "stows=5\ndebriefs=2\n"],
    ["garbage", "generation=3x\ndebriefs=-1\n"],
    ["the last value wins", "debriefs=1\ndebriefs=4\ngeneration=2\ngeneration=\n"],
  ] as [string, string | null][]) {
    const seed = (s: string): void => {
      if (body !== null) STATE(s, ".learn.meta", body);
    };
    same(`due: ${label}`, { ...DUE, seed });
    same(`generation: ${label}`, { ...GEN, seed });
  }
  for (const [label, every] of [["5", "5\n"], ["spaced", "  12 \r\n"], ["garbage", "eight\n"], ["empty", ""]] as [string, string][])
    same(`due: learn-every ${label}`, { ...DUE, seed: (s) => put(join(s, "home", "config", "learn-every"), every) });
  if (process.getuid?.() !== 0)
    same("due: an unreadable meta warns and reads 0", {
      ...DUE,
      seed: (s) => {
        STATE(s, ".learn.meta", "debriefs=3\n");
        chmodSync(join(s, "home", "state", ".learn.meta"), 0);
      },
    });
}, 60_000);

test("learnTick: under the cadence lock, the migrate, generation kept and debriefs+1 as bash arithmetic", () => {
  const TICK: Row = { bash: `ac_learn_tick`, twin: `return L.learnTick() ? 0 : 1;`, env: HOME };
  same("no meta", TICK);
  same("a meta", { ...TICK, seed: (s) => STATE(s, ".learn.meta", "last_run=1\ngeneration=3\ndebriefs=4\nother=x\n") });
  same("the legacy key migrates", { ...TICK, seed: (s) => STATE(s, ".learn.meta", "generation=1\nstows=6\nlast_run=2\n") });
  same("a half-migrated meta keeps debriefs", { ...TICK, seed: (s) => STATE(s, ".learn.meta", "stows=6\ndebriefs=2\n") });
  same("an octal count", { ...TICK, seed: (s) => STATE(s, ".learn.meta", "debriefs=010\n") });
  same("a count too great for its base ends the shell, the lock still held", { ...TICK, seed: (s) => STATE(s, ".learn.meta", "debriefs=08\n") }, { status: 1, code: "EARITH", shell: "08: value too great for base" });
  same("a busy cadence lock: 10 waits, then the warning", { ...TICK, seed: (s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`) });
  same("a dead holder's lock is taken", { ...TICK, seed: (s) => STATE(s, ".learn-cadence.lock/pid", "999999\n") });
}, 60_000);

test("learnTickKeyed: one count per key inside 24 h, the stamp written before the count", () => {
  const KEYED = (key: string): Row => ({ bash: CADENCE(`ac_learn_tick_keyed "$1"`), twin: `return L.learnTickKeyed(A[0]);`, args: [key], env: HOME });
  same("a fresh key", KEYED("fam-a"));
  same("a key stamped inside the window", { ...KEYED("fam-a"), seed: (s) => STATE(s, ".learn-ticks", "1767225000\tfam-a\n") });
  same("a stamp past the window is pruned and the key counts again", { ...KEYED("fam-a"), seed: (s) => STATE(s, ".learn-ticks", "1767000000\tfam-a\n1767225000\tother\n") });
  same("a numeric-looking key is matched with `in`, never ==", { ...KEYED("7"), seed: (s) => STATE(s, ".learn-ticks", "1767225000\t07\n") });
  same("a stamp file with a byte no locale decodes", { ...KEYED("fam-a"), seed: (s) => STATE(s, ".learn-ticks", "1767225000\tcaf\xe9\n") });
  same("a busy cadence lock claims nothing and speaks", { ...KEYED("fam-a"), seed: (s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`) });
}, 60_000);

test("learnReset: the generation guard, the migrate and the reset under the cadence lock", () => {
  const RESET = (expected = ""): Row => ({
    bash: CADENCE(`ac_learn_reset ${expected === "" ? "" : '"$1"'}`),
    twin: `return L.learnReset(${expected === "" ? "" : "A[0]"});`,
    args: expected === "" ? [] : [expected],
    env: HOME,
  });
  same("no meta", RESET());
  same("a meta", { ...RESET(), seed: (s) => STATE(s, ".learn.meta", "last_run=1\ngeneration=3\ndebriefs=9\n") });
  same("the expected generation", { ...RESET("3"), seed: (s) => STATE(s, ".learn.meta", "generation=3\ndebriefs=9\n") });
  same("a newer generation is silent", { ...RESET("2"), seed: (s) => STATE(s, ".learn.meta", "generation=3\ndebriefs=9\n") });
  same("the legacy key migrates first", { ...RESET(), seed: (s) => STATE(s, ".learn.meta", "stows=4\n") });
  same("a busy cadence lock speaks", { ...RESET(), seed: (s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`) });
  same("the landing stamps are left alone", { ...RESET(), seed: (s) => STATE(s, ".learn-ticks", "1767225000\tfam-a\n") });
}, 60_000);

test("curateTick: under the Curate cadence lock, generation kept and runs_since+1", () => {
  const TICK: Row = { bash: `ac_curate_tick`, twin: `return L.curateTick() ? 0 : 1;`, env: HOME };
  same("no meta", TICK);
  same("a meta", { ...TICK, seed: (s) => STATE(s, ".curate.meta", "generation=3\nruns_since=4\nlast_run=1\n") });
  same("garbage", { ...TICK, seed: (s) => STATE(s, ".curate.meta", "generation=x\nruns_since=-2\n") });
  same("a busy lock", { ...TICK, seed: (s) => STATE(s, ".curate-cadence.lock/pid", `${process.pid}\n`) });
}, 60_000);

test("skillsDir: <home>/skills, minted", () => {
  same("minted", { bash: `ac_skills_dir`, twin: `writeSync(1, L.skillsDir() + "\\n"); return 0;`, env: HOME });
});

test("maintenanceIncomplete: one row per unsettled transaction, in byte order", () => {
  const INC: Row = {
    bash: `ac_maintenance_incomplete "$1"`,
    twin: `for (const r of L.maintenanceIncomplete(A[0])) writeSync(1, Buffer.from(r + "\\n", "latin1")); return 0;`,
    args: ["@S/home/state/.maintenance-transactions"],
    env: HOME,
  };
  const J = (s: string, id: string, body: string): void => STATE(s, `.maintenance-transactions/${id}/journal`, body);
  same("no root", INC);
  same("settled and unsettled", {
    ...INC,
    seed: (s) => {
      J(s, "learning-b-x", "status=applying\nplan=/p.json\naction_0=complete\naction_1=complete\naction_2=pending\n");
      J(s, "learning-a-y", "status=complete\n");
      J(s, "curate-1-z", "status=abandoned\n");
      J(s, "Learning-C", "plan=\n");
      mkdirSync(join(s, "home", "state", ".maintenance-transactions", "no-journal"), { recursive: true });
      put(join(s, "home", "state", ".maintenance-transactions", "a-file"), "x");
    },
  });
}, 60_000);

test("crewmateLearnedNoLoss: every live `## ` head kept or retired", () => {
  const NL = (retired = ""): Row => ({
    bash: `ac_crewmate_learned_no_loss "$1" "$2" "$3"`,
    twin: `return L.crewmateLearnedNoLoss(A[0], A[1], A[2]) ? 0 : 1;`,
    args: ["@S/live", "@S/staged", retired === "" ? "" : "@S/retired"],
  });
  const seed = (live: string | null, staged: string | null, retired: string | null) => (s: string): void => {
    if (live !== null) put(join(s, "live"), live);
    if (staged !== null) put(join(s, "staged"), staged);
    if (retired !== null) put(join(s, "retired"), retired);
  };
  same("no live file", { ...NL(), seed: seed(null, "## a\n", null) });
  same("no staged file", { ...NL(), seed: seed("## a\n", null, null) });
  same("every head kept", { ...NL(), seed: seed("## a\nx\n## b\n", "## b\n## a\n## c\n", null) });
  same("a head dropped", { ...NL(), seed: seed("## a\n## b\n", "## a\n", null) });
  same("a head dropped and retired", { ...NL("r"), seed: seed("## a\n## b\n", "## a\n", "retired: b\n") });
  same("a head kept only as a substring", { ...NL(), seed: seed("## a\n", "## ab\n", null) });
  same("a live file with no heads", { ...NL(), seed: seed("text\n", "", null) });
}, 60_000);
