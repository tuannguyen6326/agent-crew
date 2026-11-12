// learn.test.ts - what src/learn.ts brought into src/lib-learn.ts: learnDue,
// skillsDir and maintenanceIncomplete held to the live readers session start
// keeps (bin/ac-maintenance-lib.sh, bin/ac-lib.sh); the Learning cadence
// writers (learnTick, learnTickKeyed, learnGeneration, learnReset and the
// legacy-key migrate under them), curateTick and crewmateLearnedNoLoss held to
// the expectations the comment above each states; and src/learn.ts's
// read-evidence floor, held to the lib's AC_MAINTENANCE_QUOTE_MIN. The CLI
// contract is tests/sh/ac-learn.test.sh's.
//
// DISPUTED: the implementation of each live-bash reader (bin/ac-lib.sh and bin/ac-maintenance-lib.sh vs src/lib-learn.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home); argv; env (PATH = a stub dir - date answering one instant, sleep logging to <side>/sleep.log and returning - then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C; HOME and TMPDIR the test root; AC_HOME where a row sets it); cwd (the distro root); stdin (/dev/null); the process started through /bin/sh; stdout, stderr and the status (the side root spelled S, the side's pid PID) and the side root's world after the call - every path with its mode and bytes - compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib-learn.ts");
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
  // the live bash call, run after sourcing ac-lib.sh and ac-maintenance-lib.sh, its arguments "$@"; none for a row only the twin runs
  bash?: string;
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
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-maintenance-lib.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
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

function same(label: string, row: Row): { o: Side; t: Side } {
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
  expect(view(t)).toEqual(view(o));
  return { o, t };
}

// The twin alone on a fresh side root: its stdout and stderr, and each of
// <read> (paths under the root) as its bytes, `<dir>` for a directory, null
// when absent.
function twin(row: Row, read: string[] = []): Record<string, string | null> {
  const s = join(W, `r${rows++}`);
  mkdirSync(join(s, "home"), { recursive: true });
  row.seed?.(s);
  const r = side(row, s, false);
  const got: Record<string, string | null> = { out: r.out, err: r.err };
  for (const rel of read) {
    const p = join(s, rel);
    got[rel] = !existsSync(p) ? null : lstatSync(p).isDirectory() ? "<dir>" : readFileSync(p, "latin1");
  }
  return got;
}

const put = (p: string, b: string | Buffer): void => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, b);
};
const STATE = (s: string, name: string, body: string): void => put(join(s, "home", "state", name), body);
const HOME = { AC_HOME: "@S/home" };

const META = "home/state/.learn.meta";
const TICKS = "home/state/.learn-ticks";
const LOCK = "home/state/.learn-cadence.lock";
const SLEPT = "1\n".repeat(10);
const STAMPED = "last_run=1767225600\n";

test("the read-evidence floor src/learn.ts passes is the lib's AC_MAINTENANCE_QUOTE_MIN", () => {
  const r = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-maintenance-lib.sh"; printf %s "$AC_MAINTENANCE_QUOTE_MIN"`, BIN], { cwd: ROOT, env: { PATH, HOME: W, LC_ALL: "C" }, stdin: "ignore", stdout: "pipe" });
  expect(/^const QUOTE_MIN = ([0-9]+);$/m.exec(readFileSync(LEARN, "utf8"))?.[1]).toBe(r.stdout.toString());
});

test("learnDue and learnGeneration: the counter (the legacy key as fallback) and learn-every, 0 and 8 unless digits", () => {
  const DUE: Row = { bash: `ac_learn_due`, twin: `writeSync(1, L.learnDue().join(" ") + "\\n"); return 0;`, env: HOME };
  const GEN: Row = { twin: `writeSync(1, L.learnGeneration() + "\\n"); return 0;`, env: HOME };
  for (const [label, body, gen] of [
    ["absent", null, "0"],
    ["set", "generation=3\ndebriefs=7\n", "3"],
    ["the legacy key", "stows=5\n", "0"],
    ["both keys - debriefs wins", "stows=5\ndebriefs=2\n", "0"],
    ["garbage", "generation=3x\ndebriefs=-1\n", "0"],
    ["the last value wins", "debriefs=1\ndebriefs=4\ngeneration=2\ngeneration=\n", "0"],
  ] as [string, string | null, string][]) {
    const seed = (s: string): void => {
      if (body !== null) STATE(s, ".learn.meta", body);
    };
    same(`due: ${label}`, { ...DUE, seed });
    expect([label, twin({ ...GEN, seed }, [META])]).toEqual([label, { out: `${gen}\n|rc=0`, err: "", [META]: body }]);
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
  const TICK: Row = { twin: `return L.learnTick() ? 0 : 1;`, env: HOME };
  const tick = (seed?: (s: string) => void) => twin({ ...TICK, seed }, [META, LOCK, "sleep.log"]);
  const counted = (meta: string) => ({ out: "|rc=0", err: "", [META]: meta, [LOCK]: null, "sleep.log": null });
  expect(tick()).toEqual(counted("generation=0\ndebriefs=1\n"));
  expect(tick((s) => STATE(s, ".learn.meta", "last_run=1\ngeneration=3\ndebriefs=4\nother=x\n"))).toEqual(counted("last_run=1\nother=x\ngeneration=3\ndebriefs=5\n"));
  expect(tick((s) => STATE(s, ".learn.meta", "generation=1\nstows=6\nlast_run=2\n"))).toEqual(counted("last_run=2\ngeneration=1\ndebriefs=7\n"));
  expect(tick((s) => STATE(s, ".learn.meta", "stows=6\ndebriefs=2\n"))).toEqual(counted("generation=0\ndebriefs=3\n"));
  expect(tick((s) => STATE(s, ".learn.meta", "debriefs=010\n"))).toEqual(counted("generation=0\ndebriefs=9\n"));
  expect(tick((s) => STATE(s, ".learn.meta", "debriefs=08\n"))).toEqual({ out: "|rc=throw:EARITH", err: "", [META]: "debriefs=08\ngeneration=0\n", [LOCK]: "<dir>", "sleep.log": null });
  expect(tick((s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`))).toEqual({
    out: "|rc=1",
    err: "WARN: learning tick: cadence lock S/home/state/.learn-cadence.lock could not be acquired within 10s - the debrief counter was NOT advanced. Missing a tick only delays the next distill (the LEVEL trigger still fires); it never loses a landing outright, but a caller that assumes success will believe the counter moved when it did not.\n",
    [META]: null,
    [LOCK]: "<dir>",
    "sleep.log": SLEPT,
  });
  expect(tick((s) => STATE(s, ".learn-cadence.lock/pid", "999999\n"))).toEqual(counted("generation=0\ndebriefs=1\n"));
}, 60_000);

test("learnTickKeyed: one count per key inside 24 h, the stamp written before the count", () => {
  const keyed = (key: string, seed?: (s: string) => void) => twin({ twin: `return L.learnTickKeyed(A[0]);`, args: [key], env: HOME, seed }, [TICKS, META]);
  const ONE = "generation=0\ndebriefs=1\n";
  expect(keyed("fam-a")).toEqual({ out: "|rc=0", err: "", [TICKS]: "1767225600\tfam-a\n", [META]: ONE });
  expect(keyed("fam-a", (s) => STATE(s, ".learn-ticks", "1767225000\tfam-a\n"))).toEqual({ out: "|rc=1", err: "", [TICKS]: "1767225000\tfam-a\n", [META]: null });
  expect(keyed("fam-a", (s) => STATE(s, ".learn-ticks", "1767000000\tfam-a\n1767225000\tother\n"))).toEqual({ out: "|rc=0", err: "", [TICKS]: "1767225000\tother\n1767225600\tfam-a\n", [META]: ONE });
  expect(keyed("7", (s) => STATE(s, ".learn-ticks", "1767225000\t07\n"))).toEqual({ out: "|rc=0", err: "", [TICKS]: "1767225000\t07\n1767225600\t7\n", [META]: ONE });
  expect(keyed("fam-a", (s) => put(join(s, "home", "state", ".learn-ticks"), Buffer.from("1767225000\tcaf\xe9\n", "latin1")))).toEqual({ out: "|rc=0", err: "", [TICKS]: "1767225000\tcaf\xe9\n1767225600\tfam-a\n", [META]: ONE });
  const busy = twin({ twin: `return L.learnTickKeyed(A[0]);`, args: ["fam-a"], env: HOME, seed: (s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`) }, [TICKS, META, "sleep.log"]);
  expect(busy).toEqual({
    out: "|rc=2",
    err: "WARN: learning tick: cadence lock S/home/state/.learn-cadence.lock could not be acquired within 10s - landing 'fam-a' was NOT claimed. Missing a tick only delays the next distill (the LEVEL trigger still fires); counting one twice consumes a retro window and cannot be undone.\n",
    [TICKS]: null,
    [META]: null,
    "sleep.log": SLEPT,
  });
}, 60_000);

test("learnReset: the generation guard, the migrate and the reset under the cadence lock", () => {
  const reset = (expected: string, seed?: (s: string) => void) =>
    twin({ twin: `return L.learnReset(${expected === "" ? "" : "A[0]"});`, args: expected === "" ? [] : [expected], env: HOME, seed }, [META, TICKS, LOCK, "sleep.log"]);
  const done = (meta: string, ticks: string | null = null) => ({ out: "|rc=0", err: "", [META]: meta, [TICKS]: ticks, [LOCK]: null, "sleep.log": null });
  expect(reset("")).toEqual(done(`generation=1\ndebriefs=0\n${STAMPED}`));
  expect(reset("", (s) => STATE(s, ".learn.meta", "last_run=1\ngeneration=3\ndebriefs=9\n"))).toEqual(done(`generation=4\ndebriefs=0\n${STAMPED}`));
  expect(reset("3", (s) => STATE(s, ".learn.meta", "generation=3\ndebriefs=9\n"))).toEqual(done(`generation=4\ndebriefs=0\n${STAMPED}`));
  expect(reset("2", (s) => STATE(s, ".learn.meta", "generation=3\ndebriefs=9\n"))).toEqual({ ...done("generation=3\ndebriefs=9\n"), out: "|rc=1" });
  expect(reset("", (s) => STATE(s, ".learn.meta", "stows=4\n"))).toEqual(done(`generation=1\ndebriefs=0\n${STAMPED}`));
  expect(reset("", (s) => STATE(s, ".learn-cadence.lock/pid", `${process.pid}\n`))).toEqual({
    out: "|rc=2",
    err: "WARN: learning reset: cadence lock S/home/state/.learn-cadence.lock could not be acquired within 10s - the debrief counter was NOT reset and its generation did NOT advance, so a due DISTILL cycle stays due. This is a lock failure, not a newer cadence generation.\n",
    [META]: null,
    [TICKS]: null,
    [LOCK]: "<dir>",
    "sleep.log": SLEPT,
  });
  expect(reset("", (s) => STATE(s, ".learn-ticks", "1767225000\tfam-a\n"))).toEqual(done(`generation=1\ndebriefs=0\n${STAMPED}`, "1767225000\tfam-a\n"));
}, 60_000);

test("curateTick: under the Curate cadence lock, generation kept and runs_since+1", () => {
  const CMETA = "home/state/.curate.meta";
  const CLOCK = "home/state/.curate-cadence.lock";
  const tick = (seed?: (s: string) => void) => twin({ twin: `return L.curateTick() ? 0 : 1;`, env: HOME, seed }, [CMETA, CLOCK, "sleep.log"]);
  const counted = (meta: string) => ({ out: "|rc=0", err: "", [CMETA]: meta, [CLOCK]: null, "sleep.log": null });
  expect(tick()).toEqual(counted("generation=0\nruns_since=1\n"));
  expect(tick((s) => STATE(s, ".curate.meta", "generation=3\nruns_since=4\nlast_run=1\n"))).toEqual(counted("last_run=1\ngeneration=3\nruns_since=5\n"));
  expect(tick((s) => STATE(s, ".curate.meta", "generation=x\nruns_since=-2\n"))).toEqual(counted("generation=0\nruns_since=1\n"));
  expect(tick((s) => STATE(s, ".curate-cadence.lock/pid", `${process.pid}\n`))).toEqual({
    out: "|rc=1",
    err: "WARN: curate tick: cadence lock S/home/state/.curate-cadence.lock could not be acquired within 10s - the learning-run counter was NOT advanced. Missing a tick only delays the next Curate pass, but a caller that assumes success will believe the counter moved when it did not.\n",
    [CMETA]: null,
    [CLOCK]: "<dir>",
    "sleep.log": SLEPT,
  });
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
    twin: `return L.crewmateLearnedNoLoss(A[0], A[1], A[2]) ? 0 : 1;`,
    args: ["@S/live", "@S/staged", retired === "" ? "" : "@S/retired"],
  });
  const seed = (live: string | null, staged: string | null, retired: string | null) => (s: string): void => {
    if (live !== null) put(join(s, "live"), live);
    if (staged !== null) put(join(s, "staged"), staged);
    if (retired !== null) put(join(s, "retired"), retired);
  };
  const rows: [string, Row, string][] = [
    ["no live file", { ...NL(), seed: seed(null, "## a\n", null) }, "|rc=0"],
    ["no staged file", { ...NL(), seed: seed("## a\n", null, null) }, "|rc=1"],
    ["every head kept", { ...NL(), seed: seed("## a\nx\n## b\n", "## b\n## a\n## c\n", null) }, "|rc=0"],
    ["a head dropped", { ...NL(), seed: seed("## a\n## b\n", "## a\n", null) }, "|rc=1"],
    ["a head dropped and retired", { ...NL("r"), seed: seed("## a\n## b\n", "## a\n", "retired: b\n") }, "|rc=0"],
    ["a head kept only as a substring", { ...NL(), seed: seed("## a\n", "## ab\n", null) }, "|rc=1"],
    ["a live file with no heads", { ...NL(), seed: seed("text\n", "", null) }, "|rc=0"],
  ];
  for (const [label, row, out] of rows) expect([label, twin(row)]).toEqual([label, { out, err: "" }]);
}, 60_000);
