// curate.test.ts - what src/curate.ts brought into src/lib.ts and src/lib-curate.ts:
// fileMtime (ac_file_mtime), curateDue (ac_curate_due) and SKILLS_ARCHIVE held
// to the live bash in bin/ac-lib.sh and bin/ac-maintenance-lib.sh; the
// maintenance transaction (maintenanceApply), curateGeneration, curateReset,
// the gate's failure reason and src/maintenance-receipt.ts's receiptValidate
// held to the expectations their specs state (the comment above each, that
// module's header); and src/curate.ts's read-evidence floor, held to the lib's
// AC_MAINTENANCE_QUOTE_MIN. The CLI contract is tests/sh/ac-curate.test.sh's.
//
// DISPUTED: the implementation of each live-bash helper (bin/ac-lib.sh and bin/ac-maintenance-lib.sh vs src/lib.ts and src/lib-curate.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with records, skills, state and a maintenance run holding its plan and staged files); argv; env (PATH = a stub dir - date answering one instant, sleep logging to <side>/sleep.log and returning - then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C; HOME and TMPDIR the test root; AC_HOME where a row sets it); cwd (the distro root); stdin (/dev/null); the process started through /bin/sh so a row can plant a link at a name its pid decides; stdout, stderr and the status (the side root spelled S, the side's pid PID) and the side root's world after the call - every path with its mode and bytes, a backup as its sorted tar listing - compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { maintenanceGateFailureReason } from "../../src/lib-curate.ts";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const LIBC = join(ROOT, "src", "lib-curate.ts");
const CURATE = join(ROOT, "src", "curate.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-curate-ts-")));
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
  // the live bash call, run after sourcing ac-lib.sh, ac-maintenance-lib.sh and ac-bun.sh, its arguments "$@"; none for a row only the twin runs
  bash?: string;
  // the twin's body: L is src/lib.ts merged with src/lib-curate.ts, C src/curate.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  // a link to <plantTo> (<side>/victim) planted at <side>/<plant>.<the process's pid>.0
  plant?: string;
  plantTo?: string;
};
type Side = { out: string; err: string; world: string; status: number | null; norm: (t: string) => string };

// Every path under the side root with its mode and bytes, a backup's as its
// sorted tar listing.
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
      } else if (name.endsWith(".tar.gz")) {
        const t = Bun.spawnSync(["tar", "-tzf", p], { stdout: "pipe", stderr: "pipe" });
        lines.push(`${rel} ${(st.mode & 0o7777).toString(8)}\n${t.stdout.toString().split("\n").sort().join("\n")}`);
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
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-maintenance-lib.sh" || exit $?; . "$0/ac-bun.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = { ...await import(${JSON.stringify(LIB)}), ...await import(${JSON.stringify(LIBC)}) }; const C = await import(${JSON.stringify(CURATE)}); const A = ${JSON.stringify(args)}; let rc; try { rc = await (async () => { ${row.twin} })(); } catch (e) { rc = "throw:" + (e.code ?? e.message); } writeSync(1, "|rc=" + rc);`,
      ];
  const plant = row.plant ? join(s, row.plant) : "";
  const r = Bun.spawnSync(["/bin/sh", "-c", '[ -z "$0" ] || ln -s "$1" "$0.$$.0"; shift; exec "$@"', plant, row.plantTo ?? join(s, "victim"), ...cmd], { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const pid = String(r.pid);
  // Only between non-hex bytes: a digest that happens to hold the pid is no pid.
  const norm = (t: string): string => t.replaceAll(s, "S").replace(new RegExp(`(^|[^0-9a-f])${pid}([^0-9a-f]|$)`, "g"), "$1PID$2");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode, norm };
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
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

// The twin alone on a fresh side root. at(<path under the root>) is its
// bytes, `-> <target>` for a link, `<dir>` for a directory, a backup's sorted
// tar listing, null when absent; tree(<dir>) every path below it, sorted, a
// directory with its trailing slash.
type Got = { out: string; err: string; at: (p: string) => string | string[] | null; tree: (p: string) => string[] | null; mode: (p: string) => string };
function twin(row: Row): Got {
  const s = join(W, `r${rows++}`);
  mkdirSync(join(s, "home"), { recursive: true });
  row.seed?.(s);
  const r = side(row, s, false);
  const at = (rel: string): string | string[] | null => {
    const p = join(s, rel);
    let st;
    try {
      st = lstatSync(p);
    } catch {
      return null;
    }
    if (st.isSymbolicLink()) return `-> ${r.norm(readlinkSync(p))}`;
    if (st.isDirectory()) return "<dir>";
    if (p.endsWith(".tar.gz")) return r.norm(Bun.spawnSync(["tar", "-tzf", p], { stdout: "pipe" }).stdout.toString()).split("\n").filter((l) => l !== "").sort();
    return r.norm(readFileSync(p, "latin1"));
  };
  const tree = (rel: string): string[] | null => {
    const top = join(s, rel);
    if (!existsSync(top)) return null;
    const out: string[] = [];
    const walk = (dir: string): void => {
      for (const name of readdirSync(dir).sort()) {
        const p = join(dir, name);
        const isDir = lstatSync(p).isDirectory();
        out.push(`${p.slice(top.length + 1)}${isDir ? "/" : ""}`);
        if (isDir) walk(p);
      }
    };
    walk(top);
    return out;
  };
  const mode = (rel: string): string => (lstatSync(join(s, rel)).mode & 0o7777).toString(8);
  return { out: r.out, err: r.err, at, tree, mode };
}

const sha = (b: string | Buffer): string => createHash("sha256").update(b).digest("hex");
const put = (p: string, b: string | Buffer): void => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, b);
};

test("SKILLS_ARCHIVE is the lib's AC_SKILLS_ARCHIVE_BASENAME", () => {
  same("archive name", { bash: `printf %s "$AC_SKILLS_ARCHIVE_BASENAME"`, twin: `writeSync(1, L.SKILLS_ARCHIVE); return 0;` });
});

test("the read-evidence floor src/curate.ts passes is the lib's AC_MAINTENANCE_QUOTE_MIN", () => {
  const r = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-maintenance-lib.sh"; printf %s "$AC_MAINTENANCE_QUOTE_MIN"`, BIN], { cwd: ROOT, env: { PATH, HOME: W, LC_ALL: "C" }, stdin: "ignore", stdout: "pipe" });
  const src = readFileSync(CURATE, "utf8");
  expect(/^const QUOTE_MIN = ([0-9]+);$/m.exec(src)?.[1]).toBe(r.stdout.toString());
});

const MTIME: Row = {
  bash: `m="$(ac_file_mtime "$1")"; rc=$?; printf '%s' "$m"; (exit "$rc")`,
  twin: `const m = L.fileMtime(A[0]); if (m !== null) writeSync(1, m); return m === null ? 1 : 0;`,
  args: ["@S/f"],
};

test("fileMtime: a path's own mtime in epoch seconds, a link's own, nothing for a missing path", () => {
  const touched = (s: string): void => {
    put(join(s, "f"), "x");
    Bun.spawnSync(["touch", "-t", "202001020304.05", join(s, "f")]);
  };
  expect(same("a file", { ...MTIME, seed: touched }).o.out).toMatch(/^[0-9]+\|rc=0$/);
  same("a directory", {
    ...MTIME,
    seed: (s) => {
      mkdirSync(join(s, "f"));
      Bun.spawnSync(["touch", "-t", "202001020304.05", join(s, "f")]);
    },
  });
  same("missing", MTIME);
  same("a link, read as itself", {
    ...MTIME,
    seed: (s) => {
      put(join(s, "target"), "x");
      symlinkSync(join(s, "target"), join(s, "f"));
      Bun.spawnSync(["touch", "-h", "-t", "201901010000", join(s, "f")]);
    },
  });
  same("a dangling link", { ...MTIME, seed: (s) => symlinkSync(join(s, "nowhere"), join(s, "f")) });
}, 60_000); // dozens of bash and bun probes per test - past bun's 5 s default under load

test("homeless, skills-audit and run refuse at their first home read and never reach the host root (W14, named)", () => {
  for (const [verb, before] of [["skills-audit", "== skills-audit: territory overlap + stale candidates (propose-only, never mutates) ==\n"], ["run", ""]]) {
    const r = Bun.spawnSync([join(BIN, "ac-curate.sh"), verb], { cwd: W, env: { PATH, HOME: W, LC_ALL: "C", TMPDIR: W }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
    expect([verb, r.exitCode, r.stdout.toString(), r.stderr.toString()]).toEqual([
      verb,
      1,
      before,
      "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n",
    ]);
  }
}, 60_000);

test("maintenanceGateFailureReason: three texts keyed on the gate's exit only", () => {
  const rejected = (rc: string): string => `The maintenance gate rejected its own invocation before it could run (usage or input error, exit ${rc}).`;
  const rows: [string, string][] = [
    ["4", "The maintenance gate is disabled (config/gate-agent=off)."],
    ["3", "The maintenance gate ran but produced no usable decision (an engine failure, an invalid response, a timeout, or a declared environment-error)."],
    ["1", rejected("1")],
    ["2", rejected("2")],
    ["127", rejected("127")],
    ["143", rejected("143")],
    ["x", rejected("x")],
  ];
  for (const [rc, text] of rows) expect([rc, maintenanceGateFailureReason(rc)]).toEqual([rc, text]);
});

const META = (body: string | null) => (s: string): void => {
  if (body !== null) put(join(s, "home", "state", ".curate.meta"), body);
};
const NO_HOME = "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n";

test("curateGeneration and curateDue: the meta's numbers, 0 and 5 unless digits", () => {
  const GEN: Row = { twin: `writeSync(1, L.curateGeneration() + "\\n"); return 0;`, env: { AC_HOME: "@S/home" } };
  const DUE: Row = { bash: `ac_curate_due`, twin: `writeSync(1, L.curateDue().join(" ") + "\\n"); return 0;`, env: { AC_HOME: "@S/home" } };
  for (const [label, body, gen] of [
    ["absent", null, "0"],
    ["set", "generation=3\nruns_since=7\n", "3"],
    ["garbage", "generation=3x\nruns_since=-1\n", "0"],
    ["the last value wins", "generation=1\ngeneration=4\nruns_since=2\nruns_since=\n", "4"],
  ] as [string, string | null, string][]) {
    const g = twin({ ...GEN, seed: META(body) });
    expect([label, g.out, g.err, g.at("home/state/.curate.meta")]).toEqual([label, `${gen}\n|rc=0`, "", body]);
    same(`due: ${label}`, { ...DUE, seed: META(body) });
  }
  for (const [label, every] of [["3", "3\n"], ["spaced", "  12 \r\n"], ["garbage", "xx\n"], ["empty", ""]] as [string, string][])
    same(`due: curate-every ${label}`, { ...DUE, seed: (s) => put(join(s, "home", "config", "curate-every"), every) });
  const homeless = twin({ ...GEN, env: {} });
  expect([homeless.out, homeless.err]).toEqual(["0\n|rc=0", NO_HOME]);
  if (process.getuid?.() !== 0) {
    const unreadable = twin({
      ...GEN,
      seed: (s) => {
        META("generation=3\n")(s);
        chmodSync(join(s, "home", "state", ".curate.meta"), 0);
      },
    });
    expect([unreadable.out, unreadable.err]).toEqual(["0\n|rc=0", "WARN: cannot read meta file S/home/state/.curate.meta\n"]);
    same("due: an unreadable curate-every", { ...DUE, seed: (s) => { put(join(s, "home", "config", "curate-every"), "3\n"); chmodSync(join(s, "home", "config", "curate-every"), 0); } });
  }
}, 60_000);

const RESET = (expected = ""): Row => ({
  twin: `return L.curateReset(${expected === "" ? "" : "A[0]"}) ? 0 : 1;`,
  args: expected === "" ? [] : [expected],
  env: { AC_HOME: "@S/home" },
});
const RESET_LOCK = "home/state/.curate-cadence.lock";
const reset = (row: Row) => {
  const g = twin(row);
  return { out: g.out, err: g.err, meta: g.at("home/state/.curate.meta"), lock: g.at(RESET_LOCK), sleeps: g.at("sleep.log") };
};
const STAMPED = "last_run=1767225600\n";

test("curateReset: under the cadence lock, the generation guard, generation+1 as bash arithmetic", () => {
  expect(reset(RESET())).toEqual({ out: "|rc=0", err: "", meta: `generation=1\nruns_since=0\n${STAMPED}`, lock: null, sleeps: null });
  expect(reset({ ...RESET(), seed: META("last_run=1\ngeneration=3\nruns_since=4\nother=x\n") })).toEqual({ out: "|rc=0", err: "", meta: `other=x\ngeneration=4\nruns_since=0\n${STAMPED}`, lock: null, sleeps: null });
  expect(reset({ ...RESET("3"), seed: META("generation=3\nruns_since=4\n") })).toEqual({ out: "|rc=0", err: "", meta: `generation=4\nruns_since=0\n${STAMPED}`, lock: null, sleeps: null });
  expect(reset({ ...RESET("2"), seed: META("generation=3\nruns_since=4\n") })).toEqual({ out: "|rc=1", err: "", meta: "generation=3\nruns_since=4\n", lock: null, sleeps: null });
  expect(reset({ ...RESET(), seed: META("generation=010\nruns_since=4\n") })).toEqual({ out: "|rc=0", err: "", meta: `generation=9\nruns_since=0\n${STAMPED}`, lock: null, sleeps: null });
  expect(reset({ ...RESET(), seed: META("generation=08\nruns_since=4\n") })).toEqual({ out: "|rc=throw:EARITH", err: "", meta: "generation=08\nruns_since=4\n", lock: "<dir>", sleeps: null });
  expect(
    reset({
      ...RESET(),
      seed: (s) => {
        META("generation=1\n")(s);
        put(join(s, "home", "state", ".curate-cadence.lock", "pid"), `${process.pid}\n`);
      },
    }),
  ).toEqual({
    out: "|rc=1",
    err: "WARN: curate reset: cadence lock S/home/state/.curate-cadence.lock could not be acquired within 10s - the learning-run counter was NOT reset and its generation did NOT advance, so a due Curate pass stays due. This is a lock failure, not a newer cadence generation.\n",
    meta: "generation=1\n",
    lock: "<dir>",
    sleeps: "1\n".repeat(10),
  });
  expect(
    reset({
      ...RESET(),
      seed: (s) => {
        META("generation=1\n")(s);
        put(join(s, "home", "state", ".curate-cadence.lock", "pid"), "999999\n");
      },
    }),
  ).toEqual({ out: "|rc=0", err: "", meta: `generation=2\nruns_since=0\n${STAMPED}`, lock: null, sleeps: null });
}, 60_000);

// A curate run under <home>/data: a 2-action plan (captain.md rewritten,
// captain-archive.md appended), its staged files and manifest, the targets
// in their pre-state; <edit> changes the plan, <extra> the world.
type Action = { op: string; target: string; old_sha256: string; new_sha256: string; staged: string };
const PRE = "- rule one\n- rule two COMPLETED\n";
const POST = "- rule one\n";
const ARCH = "# captain-archive\n- rule two COMPLETED\n";
function planText(edit: (a: Action[]) => void = () => {}): string {
  const actions: Action[] = [
    { op: "append-archive", target: "records/captain-archive.md", old_sha256: "-", new_sha256: sha(ARCH), staged: "staged/records/captain-archive.md" },
    { op: "rewrite-registry", target: "records/captain.md", old_sha256: sha(PRE), new_sha256: sha(POST), staged: "staged/records/captain.md" },
  ];
  edit(actions);
  return JSON.stringify({ schema: "agentcrew.maintenance-plan/v1", mode: "curate", run_id: "curate-1", subject: "deterministic-records", input_manifest_sha256: sha("{}\n"), actions }, null, 2);
}
function run(s: string, edit: (a: Action[]) => void = () => {}, extra: (run: string, home: string, plan: string) => void = () => {}): void {
  const home = join(s, "home");
  const r = join(home, "data", "curate-1");
  put(join(home, "records", "captain.md"), PRE);
  put(join(home, "skills", "keep", "SKILL.md"), "kept\n");
  put(join(r, "input-manifest.json"), "{}\n");
  put(join(r, "staged", "records", "captain.md"), POST);
  put(join(r, "staged", "records", "captain-archive.md"), ARCH);
  const plan = planText(edit);
  put(join(r, "plans", "deterministic-records.json"), `${plan}\n`);
  extra(r, home, plan);
}
const APPLY = (edit?: (a: Action[]) => void, extra?: (run: string, home: string, plan: string) => void): Row => ({
  twin: `return L.maintenanceApply(A[0], A[1]) ? 0 : 1;`,
  args: ["@S/home/data/curate-1/plans/deterministic-records.json", "@S/home/data/curate-1"],
  env: { AC_HOME: "@S/home" },
  seed: (s) => run(s, edit, extra),
});
const journal = (home: string, body: string): void => put(join(home, "state", ".maintenance-transactions", "curate-1-deterministic-records", "journal"), body);

const TXN = "curate-1-deterministic-records";
const PLAN_SHA = sha(`${planText()}\n`);
const CLAIM = `plan_sha256=${PLAN_SHA}\nplan=S/home/data/curate-1/plans/deterministic-records.json\nrun=S/home/data/curate-1\nactions_total=2\n`;
const ARC = "home/state/backups/curate-1767225600.tar.gz";
const BACKUP = `backup=S/${ARC}\n`;
const DONE = "action_0=complete\naction_1=complete\nstatus=complete\n";
const TARRED = ["records/", "records/captain.md", "skills/", "skills/keep/", "skills/keep/SKILL.md"];
const HELD = (why: string, committed: number): string =>
  `WARN: maintenance transaction ${TXN} is HELD (${why}): ${committed} of its 2 action(s) are already committed to disk and are NOT rolled back. It stays claimed, so every other Learning/Curate transaction refuses until it is settled. Fix the cause and replay it (already-applied actions are skipped by hash), or drop it and keep the record: bin/ac-learn.sh maintenance resume ${TXN} | bin/ac-learn.sh maintenance abandon ${TXN}\n`;
const HELD_KEYS = (why: string, committed: number): string => `held_committed=${committed}\nheld_reason=${why}\n`;
const applied = (row: Row) => {
  const g = twin(row);
  return {
    out: g.out,
    err: g.err,
    journal: g.at(`home/state/.maintenance-transactions/${TXN}/journal`),
    captain: g.at("home/records/captain.md"),
    archive: g.at("home/records/captain-archive.md"),
    backup: g.at(ARC),
  };
};
const NOTHING = { journal: null, captain: PRE, archive: null, backup: null };

test("maintenanceApply: the claim, the journal, the backup and each action", () => {
  expect(applied(APPLY())).toEqual({ out: "|rc=0", err: "", journal: CLAIM + BACKUP + DONE, captain: POST, archive: ARCH, backup: TARRED });
  expect(
    applied(
      APPLY(undefined, (_, home, plan) => {
        put(join(home, "records", "captain.md"), POST);
        put(join(home, "records", "captain-archive.md"), ARCH);
        journal(home, `plan_sha256=${sha(`${plan}\n`)}\nstatus=complete\n`);
      }),
    ),
  ).toEqual({ out: "|rc=0", err: "", journal: `plan_sha256=${PLAN_SHA}\nstatus=complete\n`, captain: POST, archive: ARCH, backup: null });
  const other = sha("other");
  expect(applied(APPLY(undefined, (_, home) => journal(home, `plan_sha256=${other}\nstatus=complete\n`)))).toEqual({
    out: "|rc=1",
    err: `WARN: maintenance apply: transaction ${TXN} already completed a different plan (plan_sha256 ${other}, this one ${PLAN_SHA}), so this plan was not applied. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.\n`,
    ...NOTHING,
    journal: `plan_sha256=${other}\nstatus=complete\n`,
  });
  expect(applied(APPLY(undefined, (_, home) => journal(home, `plan_sha256=${other}\nstatus=applying\n`)))).toEqual({
    out: "|rc=1",
    err: `WARN: maintenance apply: transaction ${TXN} already recorded a different plan (plan_sha256 ${other}, this one ${PLAN_SHA}), so this plan was neither claimed nor written. A transaction replays only the plan it recorded - this is a changed plan under a reused run id, not a busy lock or a stale receipt.\n`,
    ...NOTHING,
    journal: `plan_sha256=${other}\nstatus=applying\n`,
  });
  expect(applied(APPLY(undefined, (_, home) => put(join(home, "state", ".maintenance-transactions", "learning-x-y", "journal"), "status=applying\n")))).toEqual({
    out: "|rc=1",
    err: `WARN: maintenance apply: another Learning/Curate transaction is still unsettled, so ${TXN} was neither claimed nor written. This is another transaction's claim, not a stale receipt or a refused plan - bin/ac-learn.sh maintenance status names it, and resume or abandon settles it.\n`,
    ...NOTHING,
  });
  expect(
    applied(
      APPLY(undefined, (_, home) => {
        put(join(home, "state", ".maintenance-transactions", "learning-a", "journal"), "status=abandoned\n");
        put(join(home, "state", ".maintenance-transactions", "learning-b", "journal"), "status=complete\n");
        mkdirSync(join(home, "state", ".maintenance-transactions", "no-journal"), { recursive: true });
      }),
    ),
  ).toEqual({ out: "|rc=0", err: "", journal: CLAIM + BACKUP + DONE, captain: POST, archive: ARCH, backup: TARRED });
  const busy = twin(APPLY(undefined, (_, home) => put(join(home, "state", ".maintenance.lock", "pid"), `${process.pid}\n`)));
  expect([busy.out, busy.err, busy.at("sleep.log"), busy.at(`home/state/.maintenance-transactions/${TXN}`)]).toEqual([
    "|rc=1",
    "WARN: maintenance apply: writer lock S/home/state/.maintenance.lock could not be acquired within 30s - another Learning/Curate transaction holds it, so curate-1-deterministic-records was neither claimed nor written. This is a busy lock, not a stale receipt or a refused plan.\n",
    "1\n".repeat(30),
    null,
  ]);
  const gone = "the recorded pre-mutation backup is missing";
  expect(applied(APPLY(undefined, (_, home, plan) => journal(home, `plan_sha256=${sha(`${plan}\n`)}\nstatus=applying\nbackup=${home}/state/backups/gone.tar.gz\n`)))).toEqual({
    out: "|rc=1",
    err: HELD(gone, 0),
    ...NOTHING,
    journal: `backup=S/home/state/backups/gone.tar.gz\n${CLAIM}status=applying\n${HELD_KEYS(gone, 0)}`,
  });
  expect(
    applied(
      APPLY(undefined, (_, home, plan) => {
        put(join(home, "records", "captain-archive.md"), ARCH);
        put(join(home, "state", "backups", "curate-0.tar.gz"), "");
        journal(home, `plan_sha256=${sha(`${plan}\n`)}\nplan=x\nrun=y\nactions_total=2\nstatus=applying\nbackup=${home}/state/backups/curate-0.tar.gz\naction_0=complete\n`);
      }),
    ),
  ).toEqual({ out: "|rc=0", err: "", journal: `backup=S/home/state/backups/curate-0.tar.gz\n${CLAIM}${DONE}`, captain: POST, archive: ARCH, backup: null });
  const left = "target records/captain.md no longer matches the state the plan was staged against";
  expect(applied(APPLY(undefined, (_, home) => put(join(home, "records", "captain.md"), "- a captain edit\n")))).toEqual({
    out: "|rc=1",
    err: HELD(left, 1),
    journal: `${CLAIM}status=applying\n${BACKUP}action_0=complete\n${HELD_KEYS(left, 1)}`,
    captain: "- a captain edit\n",
    archive: ARCH,
    backup: TARRED,
  });
  const notPlain = "target records/captain-archive.md is not a plain file";
  expect(applied(APPLY(undefined, (_, home) => mkdirSync(join(home, "records", "captain-archive.md"))))).toEqual({
    out: "|rc=1",
    err: HELD(notPlain, 0),
    journal: `${CLAIM}status=applying\n${BACKUP}${HELD_KEYS(notPlain, 0)}`,
    captain: PRE,
    archive: "<dir>",
    backup: ["records/", "records/captain-archive.md/", "records/captain.md", "skills/", "skills/keep/", "skills/keep/SKILL.md"],
  });
  expect(applied(APPLY(undefined, (_, home) => symlinkSync(join(home, "nowhere"), join(home, "records", "captain-archive.md"))))).toEqual({
    out: "|rc=1",
    err: "",
    ...NOTHING,
    archive: "-> S/home/nowhere",
  });
  const rw = twin(APPLY(undefined, (_, home) => chmodSync(join(home, "records", "captain.md"), 0o600)));
  expect([rw.out, rw.err, rw.at("home/records/captain.md"), rw.mode("home/records/captain.md")]).toEqual(["|rc=0", "", POST, "644"]);
  const through = twin({ ...APPLY(), plant: "home/records/captain-archive.md.maintenance" });
  expect([through.out, through.err, through.tree("home/records"), through.at("home/records/captain-archive.md"), through.at("victim"), through.at(`home/state/.maintenance-transactions/${TXN}/journal`)]).toEqual([
    "|rc=0",
    "",
    ["captain-archive.md", "captain.md"],
    "-> S/victim",
    ARCH,
    CLAIM + BACKUP + DONE,
  ]);
  const copied = "the copied bytes for records/captain-archive.md do not match the planned hash";
  const devnull = twin({ ...APPLY(), plant: "home/records/captain-archive.md.maintenance", plantTo: "/dev/null" });
  expect([devnull.out, devnull.err, devnull.tree("home/records"), devnull.at(`home/state/.maintenance-transactions/${TXN}/journal`)]).toEqual([
    "|rc=1",
    HELD(copied, 0),
    ["captain.md"],
    `${CLAIM}status=applying\n${BACKUP}${HELD_KEYS(copied, 0)}`,
  ]);
  expect(applied(APPLY((a) => (a[0]!.new_sha256 = sha("x"))))).toEqual({ out: "|rc=1", err: "", ...NOTHING });
  if (process.getuid?.() !== 0) {
    const noBackup = "the pre-mutation backup could not be taken";
    expect(
      applied(
        APPLY(undefined, (_, home) => {
          mkdirSync(join(home, "state", "backups"), { recursive: true });
          chmodSync(join(home, "state", "backups"), 0o555);
        }),
      ),
    ).toEqual({
      out: "|rc=1",
      err: `WARN: records backup: could not create S/${ARC} (is S/home/state/backups writable?) - no backup archive was taken\n${HELD(noBackup, 0)}`,
      ...NOTHING,
      journal: `${CLAIM}status=applying\n${HELD_KEYS(noBackup, 0)}`,
    });
    const tarFails = applied(
      APPLY(undefined, (_, home) => {
        put(join(home, "skills", "keep", "secret"), "x");
        chmodSync(join(home, "skills", "keep", "secret"), 0);
      }),
    );
    expect(tarFails.err.endsWith(HELD(noBackup, 0))).toBe(true);
    expect({ ...tarFails, err: "" }).toEqual({ out: "|rc=1", err: "", ...NOTHING, journal: `${CLAIM}status=applying\n${HELD_KEYS(noBackup, 0)}` });
    const noCopy = "the staged bytes for records/captain-archive.md could not be copied";
    const ro = applied(
      APPLY(undefined, (_, home) => {
        put(join(home, "records", "sub", "x.md"), "");
        chmodSync(join(home, "records"), 0o555);
      }),
    );
    expect(ro.err.endsWith(HELD(noCopy, 0))).toBe(true);
    expect({ ...ro, err: "" }).toEqual({
      out: "|rc=1",
      err: "",
      ...NOTHING,
      journal: `${CLAIM}status=applying\n${BACKUP}${HELD_KEYS(noCopy, 0)}`,
      backup: ["records/", "records/captain.md", "records/sub/", "records/sub/x.md", "skills/", "skills/keep/", "skills/keep/SKILL.md"],
    });
  }
}, 60_000);

// A move-skill plan for skills/s (SKILL.md and refs/deep/n.md), an umbrella
// left beside it.
const MOVED: [string, string][] = [["SKILL.md", "skill\n"], ["refs/deep/n.md", "notes\n"]];
const toArchive = (a: Action[]): void => {
  a.length = 0;
  for (const [rel, body] of MOVED) a.push({ op: "move-skill", target: `skills/skills-archive/s/${rel}`, old_sha256: "-", new_sha256: sha(body), staged: `staged/skills/skills-archive/s/${rel}` });
};
function moveRun(s: string, extra: (home: string) => void = () => {}): void {
  run(s, toArchive, (r, home) => {
    for (const [rel, body] of MOVED) {
      put(join(r, "staged", "skills", "skills-archive", "s", rel), body);
      put(join(home, "skills", "s", rel), body);
    }
    extra(home);
  });
}
const moved = (extra?: (home: string) => void) => {
  const g = twin({ ...APPLY(), seed: (s) => moveRun(s, extra) });
  return {
    out: g.out,
    err: g.err,
    journal: g.at(`home/state/.maintenance-transactions/${TXN}/journal`),
    live: g.tree("home/skills/s"),
    archived: g.tree("home/skills/skills-archive/s"),
    bytes: MOVED.map(([rel]) => g.at(`home/skills/skills-archive/s/${rel}`)),
  };
};

test("maintenanceApply: move-skill copies, verifies, removes the live source and the dirs it empties", () => {
  const done = `plan_sha256=${sha(`${planText(toArchive)}\n`)}\n${CLAIM.slice(CLAIM.indexOf("\n") + 1)}${BACKUP}${DONE}`;
  const landed = { out: "|rc=0", err: "", journal: done, archived: ["SKILL.md", "refs/", "refs/deep/", "refs/deep/n.md"], bytes: MOVED.map(([, body]) => body) };
  expect(moved()).toEqual({ ...landed, live: null });
  expect(moved((home) => put(join(home, "skills", "s", "refs", "other.md"), "kept\n"))).toEqual({ ...landed, live: ["refs/", "refs/other.md"] });
  expect(
    moved((home) => {
      rmSync(join(home, "skills", "s"), { recursive: true });
      put(join(home, "skills", "skills-archive", "s", "SKILL.md"), "skill\n");
      put(join(home, "skills", "skills-archive", "s", "refs", "deep", "n.md"), "notes\n");
    }),
  ).toEqual({ ...landed, live: null });
}, 60_000);

// A policy receipt over the deterministic plan of run(), as src/curate.ts
// mints it.
function receiptRun(s: string, body = (m: string, p: string) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "2026-01-01T00:00:00Z"\n---\n# Maintenance Gate Decision\n## Decision\ncontinue\n## Grounds\nx.\n## Proposed Process\ny.\n`): void {
  run(s, undefined, (r, _, plan) => put(join(r, "gates", "deterministic-records", "decision.md"), body(sha("{}\n"), sha(`${plan}\n`))));
}
const VALIDATE: Row = {
  twin: `const M = await import(${JSON.stringify(join(ROOT, "src", "maintenance-receipt.ts"))}); const d = M.receiptValidate(A[0], A[1], A[2], 12); if (d !== null) writeSync(1, d + "\\n"); return d === null ? 1 : 0;`,
  args: ["@S/home/data/curate-1/gates/deterministic-records/decision.md", "@S/home/data/curate-1/plans/deterministic-records.json", "@S/home/data/curate-1/input-manifest.json"],
  env: { AC_HOME: "@S/home" },
};
const judged = (row: Row): [string, string] => {
  const g = twin(row);
  return [g.out, g.err];
};

test("receiptValidate: the plan validated against its run, then the receipt check", () => {
  expect(judged({ ...VALIDATE, seed: (s) => receiptRun(s) })).toEqual(["continue\n|rc=0", ""]);
  expect(judged({ ...VALIDATE, seed: (s) => receiptRun(s, (m) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${sha("x")}"\nreviewed_at: "x"\n---\n## Grounds\nx.\n## Proposed Process\ny.\n`) })).toEqual(["|rc=1", ""]);
  expect(judged({ ...VALIDATE, seed: (s) => receiptRun(s, (m, p) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "revise"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "x"\n---\n## Grounds\nx.\n## Proposed Process\ny.\n`) })).toEqual(["revise\n|rc=0", ""]);
  expect(
    judged({
      ...VALIDATE,
      seed: (s) => {
        receiptRun(s);
        const d = join(s, "home", "data", "curate-1", "gates", "deterministic-records");
        writeFileSync(join(d, "real.md"), readFileSync(join(d, "decision.md")));
        rmSync(join(d, "decision.md"));
        symlinkSync(join(d, "real.md"), join(d, "decision.md"));
      },
    }),
  ).toEqual(["|rc=1", ""]);
  expect(judged({ ...VALIDATE, seed: (s) => { receiptRun(s); rmSync(join(s, "home", "data", "curate-1", "input-manifest.json")); } })).toEqual(["|rc=1", ""]);
  expect(
    judged({
      ...VALIDATE,
      args: [VALIDATE.args![0]!, "@S/home/data/curate-1/plan.json", VALIDATE.args![2]!],
      seed: (s) => {
        receiptRun(s);
        const r = join(s, "home", "data", "curate-1");
        writeFileSync(join(r, "plan.json"), readFileSync(join(r, "plans", "deterministic-records.json")));
      },
    }),
  ).toEqual(["continue\n|rc=0", ""]);
}, 60_000);
