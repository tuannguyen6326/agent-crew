// curate.test.ts - what src/curate.ts brought into src/lib.ts, held to the
// bash it twins - the readers in bin/ac-maintenance-lib.sh, everything else
// as frozen at tests/fixtures/ac-maintenance-retired.sh: the maintenance
// transaction (maintenanceApply, the twin of ac_maintenance_apply, which the
// frozen oracles keep calling - a claim, journal, backup or hold one side
// writes, the other must read alike), the Curate
// cadence trio (curateGeneration, curateDue, curateReset), the gate's
// failure reason, fileMtime (ac_file_mtime) and SKILLS_ARCHIVE; plus
// src/maintenance-receipt.ts's receiptValidate (ac_maintenance_receipt_validate)
// and src/curate.ts's read-evidence floor, held to the lib's
// AC_MAINTENANCE_QUOTE_MIN. The CLI
// contract is tests/sh/ac-curate.test.sh's, whose differential leg runs the
// frozen original beside the shim.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts and src/curate.ts)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with records, skills, state and a maintenance run holding its plan and staged files); argv; env (PATH = a stub dir - date answering one instant, sleep logging to <side>/sleep.log and returning - then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or jq; LC_ALL=C; HOME and TMPDIR the test root; AC_HOME where a row sets it); cwd (the distro root); stdin (/dev/null); the process started through /bin/sh so a row can plant a link at a name its pid decides; stdout, stderr and the status (the side root spelled S, the side's pid PID) and the side root's world after the call - every path with its mode and bytes, a backup as its sorted tar listing - compared whole.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
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
  // the bash call, run after sourcing ac-lib.sh, ac-maintenance-lib.sh, ac-bun.sh and the frozen ac-maintenance-retired.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, C src/curate.ts, A the arguments
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  // a link to <plantTo> (<side>/victim) planted at <side>/<plant>.<the process's pid>.0
  plant?: string;
  plantTo?: string;
};
type Side = { out: string; err: string; world: string; status: number | null };

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
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-maintenance-lib.sh" || exit $?; . "$0/ac-bun.sh" || exit $?; . "$0/../tests/fixtures/ac-maintenance-retired.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const C = await import(${JSON.stringify(CURATE)}); const A = ${JSON.stringify(args)}; let rc; try { rc = await (async () => { ${row.twin} })(); } catch (e) { rc = "throw:" + (e.code ?? e.message); } writeSync(1, "|rc=" + rc);`,
      ];
  const plant = row.plant ? join(s, row.plant) : "";
  const r = Bun.spawnSync(["/bin/sh", "-c", '[ -z "$0" ] || ln -s "$1" "$0.$$.0"; shift; exec "$@"', plant, row.plantTo ?? join(s, "victim"), ...cmd], { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const pid = String(r.pid);
  // Only between non-hex bytes: a digest that happens to hold the pid is no pid.
  const norm = (t: string): string => t.replaceAll(s, "S").replace(new RegExp(`(^|[^0-9a-f])${pid}([^0-9a-f]|$)`, "g"), "$1PID$2");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
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

// `|rc=` is the bash's own status when it ran to the end; <ended> names a
// row where the bash's shell itself ended (its exit status and its own
// stderr line, nothing printed) and the twin threw <code> instead, silently,
// for its caller to end on.
function same(label: string, row: Row, ended?: { status: number; code: string; shell: string }): { o: Side; t: Side } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  if (ended) {
    expect([p.o.out, p.o.status, p.o.err.includes(ended.shell), p.t.out, p.t.err]).toEqual(["", ended.status, true, `|rc=throw:${ended.code}`, ""]);
    p.t.out = p.o.err = "";
    p.t.status = p.o.status;
  }
  expect(view(p.t)).toEqual(view(p.o));
  return p;
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
  for (const rc of ["4", "3", "1", "2", "127", "143", "x"])
    same(`rc ${rc}`, { bash: `ac_maintenance_gate_failure_reason "$1"`, twin: `writeSync(1, L.maintenanceGateFailureReason(A[0]) + "\\n"); return 0;`, args: [rc] });
});

const META = (body: string | null) => (s: string): void => {
  if (body !== null) put(join(s, "home", "state", ".curate.meta"), body);
};

test("curateGeneration and curateDue: the meta's numbers, 0 and 5 unless digits", () => {
  const GEN: Row = { bash: `ac_curate_generation`, twin: `writeSync(1, L.curateGeneration() + "\\n"); return 0;`, env: { AC_HOME: "@S/home" } };
  const DUE: Row = { bash: `ac_curate_due`, twin: `writeSync(1, L.curateDue().join(" ") + "\\n"); return 0;`, env: { AC_HOME: "@S/home" } };
  for (const [label, body] of [
    ["absent", null],
    ["set", "generation=3\nruns_since=7\n"],
    ["garbage", "generation=3x\nruns_since=-1\n"],
    ["the last value wins", "generation=1\ngeneration=4\nruns_since=2\nruns_since=\n"],
  ] as [string, string | null][]) {
    same(`generation: ${label}`, { ...GEN, seed: META(body) });
    same(`due: ${label}`, { ...DUE, seed: META(body) });
  }
  for (const [label, every] of [["3", "3\n"], ["spaced", "  12 \r\n"], ["garbage", "xx\n"], ["empty", ""]] as [string, string][])
    same(`due: curate-every ${label}`, { ...DUE, seed: (s) => put(join(s, "home", "config", "curate-every"), every) });
  same("generation: homeless", { ...GEN, env: {} });
  if (process.getuid?.() !== 0) {
    const unreadable = (s: string): void => {
      META("generation=3\n")(s);
      chmodSync(join(s, "home", "state", ".curate.meta"), 0);
    };
    same("generation: an unreadable meta warns and reads 0", { ...GEN, seed: unreadable });
    same("due: an unreadable curate-every", { ...DUE, seed: (s) => { put(join(s, "home", "config", "curate-every"), "3\n"); chmodSync(join(s, "home", "config", "curate-every"), 0); } });
  }
}, 60_000);

const RESET = (expected = ""): Row => ({
  bash: `ac_curate_reset ${expected === "" ? "" : '"$1"'}`,
  twin: `return L.curateReset(${expected === "" ? "" : "A[0]"}) ? 0 : 1;`,
  args: expected === "" ? [] : [expected],
  env: { AC_HOME: "@S/home" },
});

test("curateReset: under the cadence lock, the generation guard, generation+1 as bash arithmetic", () => {
  same("no meta", RESET());
  same("a meta", { ...RESET(), seed: META("last_run=1\ngeneration=3\nruns_since=4\nother=x\n") });
  same("the expected generation", { ...RESET("3"), seed: META("generation=3\nruns_since=4\n") });
  same("a newer generation", { ...RESET("2"), seed: META("generation=3\nruns_since=4\n") });
  same("an octal generation", { ...RESET(), seed: META("generation=010\nruns_since=4\n") });
  same("a generation too great for its base ends the shell, the lock still held", { ...RESET(), seed: META("generation=08\nruns_since=4\n") }, { status: 1, code: "EARITH", shell: "08: value too great for base" });
  same("a busy cadence lock: 10 waits, then the warning", {
    ...RESET(),
    seed: (s) => {
      META("generation=1\n")(s);
      put(join(s, "home", "state", ".curate-cadence.lock", "pid"), `${process.pid}\n`);
    },
  });
  same("a dead holder's lock is taken", {
    ...RESET(),
    seed: (s) => {
      META("generation=1\n")(s);
      put(join(s, "home", "state", ".curate-cadence.lock", "pid"), "999999\n");
    },
  });
}, 60_000);

// A curate run under <home>/data: a 2-action plan (captain.md rewritten,
// captain-archive.md appended), its staged files and manifest, the targets
// in their pre-state; <edit> changes the plan, <extra> the world.
type Action = { op: string; target: string; old_sha256: string; new_sha256: string; staged: string };
const PRE = "- rule one\n- rule two COMPLETED\n";
const POST = "- rule one\n";
const ARCH = "# captain-archive\n- rule two COMPLETED\n";
function run(s: string, edit: (a: Action[]) => void = () => {}, extra: (run: string, home: string, plan: string) => void = () => {}): void {
  const home = join(s, "home");
  const r = join(home, "data", "curate-1");
  put(join(home, "records", "captain.md"), PRE);
  put(join(home, "skills", "keep", "SKILL.md"), "kept\n");
  put(join(r, "input-manifest.json"), "{}\n");
  put(join(r, "staged", "records", "captain.md"), POST);
  put(join(r, "staged", "records", "captain-archive.md"), ARCH);
  const actions: Action[] = [
    { op: "append-archive", target: "records/captain-archive.md", old_sha256: "-", new_sha256: sha(ARCH), staged: "staged/records/captain-archive.md" },
    { op: "rewrite-registry", target: "records/captain.md", old_sha256: sha(PRE), new_sha256: sha(POST), staged: "staged/records/captain.md" },
  ];
  edit(actions);
  const plan = JSON.stringify({ schema: "agentcrew.maintenance-plan/v1", mode: "curate", run_id: "curate-1", subject: "deterministic-records", input_manifest_sha256: sha("{}\n"), actions }, null, 2);
  put(join(r, "plans", "deterministic-records.json"), `${plan}\n`);
  extra(r, home, plan);
}
const APPLY = (edit?: (a: Action[]) => void, extra?: (run: string, home: string, plan: string) => void): Row => ({
  bash: `ac_maintenance_apply "$1" "$2"`,
  twin: `return L.maintenanceApply(A[0], A[1]) ? 0 : 1;`,
  args: ["@S/home/data/curate-1/plans/deterministic-records.json", "@S/home/data/curate-1"],
  env: { AC_HOME: "@S/home" },
  seed: (s) => run(s, edit, extra),
});
const journal = (home: string, body: string): void => put(join(home, "state", ".maintenance-transactions", "curate-1-deterministic-records", "journal"), body);

test("maintenanceApply: the claim, the journal, the backup and each action, as the frozen bash leaves them", () => {
  const fresh = same("a fresh apply", APPLY());
  expect(fresh.o.out).toBe("|rc=0");
  expect(fresh.o.world).toContain("status=complete");
  expect(fresh.o.world).toContain("/home/state/backups/curate-1767225600.tar.gz");
  same("a replay of the completed plan", APPLY(undefined, (_, home, plan) => {
    put(join(home, "records", "captain.md"), POST);
    put(join(home, "records", "captain-archive.md"), ARCH);
    journal(home, `plan_sha256=${sha(`${plan}\n`)}\nstatus=complete\n`);
  }));
  same("a completed transaction recorded another plan", APPLY(undefined, (_, home) => journal(home, `plan_sha256=${sha("other")}\nstatus=complete\n`)));
  same("a claim that recorded another plan", APPLY(undefined, (_, home) => journal(home, `plan_sha256=${sha("other")}\nstatus=applying\n`)));
  same("another unsettled transaction", APPLY(undefined, (_, home) => put(join(home, "state", ".maintenance-transactions", "learning-x-y", "journal"), "status=applying\n")));
  same("an abandoned and a completed one settle", APPLY(undefined, (_, home) => {
    put(join(home, "state", ".maintenance-transactions", "learning-a", "journal"), "status=abandoned\n");
    put(join(home, "state", ".maintenance-transactions", "learning-b", "journal"), "status=complete\n");
    mkdirSync(join(home, "state", ".maintenance-transactions", "no-journal"), { recursive: true });
  }));
  same("a busy writer lock: 30 waits, then the warning", APPLY(undefined, (_, home) => put(join(home, "state", ".maintenance.lock", "pid"), `${process.pid}\n`)));
  same("a recorded backup that is gone", APPLY(undefined, (_, home, plan) => journal(home, `plan_sha256=${sha(`${plan}\n`)}\nstatus=applying\nbackup=${home}/state/backups/gone.tar.gz\n`)));
  same("a resume: the first action landed, the second applies", APPLY(undefined, (_, home, plan) => {
    put(join(home, "records", "captain-archive.md"), ARCH);
    put(join(home, "state", "backups", "curate-0.tar.gz"), "");
    journal(home, `plan_sha256=${sha(`${plan}\n`)}\nplan=x\nrun=y\nactions_total=2\nstatus=applying\nbackup=${home}/state/backups/curate-0.tar.gz\naction_0=complete\n`);
  }));
  same("a target that left its pre-state holds", APPLY(undefined, (_, home) => put(join(home, "records", "captain.md"), "- a captain edit\n")));
  same("a target that is a directory holds", APPLY(undefined, (_, home) => mkdirSync(join(home, "records", "captain-archive.md"))));
  same("a target that is a dangling link reads absent, then its component is a link", APPLY(undefined, (_, home) => symlinkSync(join(home, "nowhere"), join(home, "records", "captain-archive.md"))));
  same("a 0600 target is rewritten at the staged copy's mode", APPLY(undefined, (_, home) => chmodSync(join(home, "records", "captain.md"), 0o600)));
  same("a link planted at the temp is written through", { ...APPLY(), plant: "home/records/captain-archive.md.maintenance" });
  same("a temp whose copy does not read back the planned bytes holds", { ...APPLY(), plant: "home/records/captain-archive.md.maintenance", plantTo: "/dev/null" });
  same("a plan that fails validation claims nothing", APPLY((a) => (a[0]!.new_sha256 = sha("x"))));
  if (process.getuid?.() !== 0) {
    same("the backup cannot be taken: held before any write", APPLY(undefined, (_, home) => {
      mkdirSync(join(home, "state", "backups"), { recursive: true });
      chmodSync(join(home, "state", "backups"), 0o555);
    }));
    same("a file the tar cannot read holds the claim", APPLY(undefined, (_, home) => {
      put(join(home, "skills", "keep", "secret"), "x");
      chmodSync(join(home, "skills", "keep", "secret"), 0);
    }));
    same("a temp that cannot be copied holds after the first action", APPLY(undefined, (_, home) => {
      put(join(home, "records", "sub", "x.md"), "");
      chmodSync(join(home, "records"), 0o555);
    }));
  }
}, 60_000);

// A move-skill plan for skills/s (SKILL.md and refs/deep/n.md), an umbrella
// left beside it.
function moveRun(s: string, extra: (home: string) => void = () => {}): void {
  run(
    s,
    (a) => {
      a.length = 0;
      for (const [rel, body] of [["SKILL.md", "skill\n"], ["refs/deep/n.md", "notes\n"]] as [string, string][])
        a.push({ op: "move-skill", target: `skills/skills-archive/s/${rel}`, old_sha256: "-", new_sha256: sha(body), staged: `staged/skills/skills-archive/s/${rel}` });
    },
    (r, home) => {
      for (const [rel, body] of [["SKILL.md", "skill\n"], ["refs/deep/n.md", "notes\n"]] as [string, string][]) {
        put(join(r, "staged", "skills", "skills-archive", "s", rel), body);
        put(join(home, "skills", "s", rel), body);
      }
      extra(home);
    },
  );
}

test("maintenanceApply: move-skill copies, verifies, removes the live source and the dirs it empties", () => {
  const moved = same("a whole package", { ...APPLY(), seed: (s) => moveRun(s) });
  expect(moved.o.world).not.toContain("/home/skills/s/");
  same("another file stays, so its dir stays", { ...APPLY(), seed: (s) => moveRun(s, (home) => put(join(home, "skills", "s", "refs", "other.md"), "kept\n")) });
  same("a source already gone, its archived copy in place", {
    ...APPLY(),
    seed: (s) =>
      moveRun(s, (home) => {
        rmSync(join(home, "skills", "s"), { recursive: true });
        put(join(home, "skills", "skills-archive", "s", "SKILL.md"), "skill\n");
        put(join(home, "skills", "skills-archive", "s", "refs", "deep", "n.md"), "notes\n");
      }),
  });
}, 60_000);

// A policy receipt over the deterministic plan of run(), as src/curate.ts
// mints it.
function receiptRun(s: string, body = (m: string, p: string) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "2026-01-01T00:00:00Z"\n---\n# Maintenance Gate Decision\n## Decision\ncontinue\n## Grounds\nx.\n## Proposed Process\ny.\n`): void {
  run(s, undefined, (r, _, plan) => put(join(r, "gates", "deterministic-records", "decision.md"), body(sha("{}\n"), sha(`${plan}\n`))));
}
const VALIDATE: Row = {
  bash: `ac_maintenance_receipt_validate "$1" "$2" "$3"`,
  twin: `const M = await import(${JSON.stringify(join(ROOT, "src", "maintenance-receipt.ts"))}); const d = M.receiptValidate(A[0], A[1], A[2], 12); if (d !== null) writeSync(1, d + "\\n"); return d === null ? 1 : 0;`,
  args: ["@S/home/data/curate-1/gates/deterministic-records/decision.md", "@S/home/data/curate-1/plans/deterministic-records.json", "@S/home/data/curate-1/input-manifest.json"],
  env: { AC_HOME: "@S/home" },
};

test("receiptValidate: the plan validated against its run, then the receipt check, as the frozen bash judges them", () => {
  expect(same("a policy receipt", { ...VALIDATE, seed: (s) => receiptRun(s) }).o.out).toBe("continue\n|rc=0");
  same("a receipt bound to another plan", { ...VALIDATE, seed: (s) => receiptRun(s, (m) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "continue"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${sha("x")}"\nreviewed_at: "x"\n---\n## Grounds\nx.\n## Proposed Process\ny.\n`) });
  same("a revise", { ...VALIDATE, seed: (s) => receiptRun(s, (m, p) => `---\nschema: "agentcrew.maintenance-gate/v1"\nmode: "curate"\nsubject: "deterministic-records"\ndecision: "revise"\nauthority: "repository-policy"\nengine: "policy"\nmodel: ""\ninput_manifest_sha256: "${m}"\naction_plan_sha256: "${p}"\nreviewed_at: "x"\n---\n## Grounds\nx.\n## Proposed Process\ny.\n`) });
  same("a receipt that is a link", {
    ...VALIDATE,
    seed: (s) => {
      receiptRun(s);
      const d = join(s, "home", "data", "curate-1", "gates", "deterministic-records");
      writeFileSync(join(d, "real.md"), readFileSync(join(d, "decision.md")));
      rmSync(join(d, "decision.md"));
      symlinkSync(join(d, "real.md"), join(d, "decision.md"));
    },
  });
  same("a missing manifest", { ...VALIDATE, seed: (s) => { receiptRun(s); rmSync(join(s, "home", "data", "curate-1", "input-manifest.json")); } });
  same("a plan beside its run, not under plans/", {
    ...VALIDATE,
    args: [VALIDATE.args![0]!, "@S/home/data/curate-1/plan.json", VALIDATE.args![2]!],
    seed: (s) => {
      receiptRun(s);
      const r = join(s, "home", "data", "curate-1");
      writeFileSync(join(r, "plan.json"), readFileSync(join(r, "plans", "deterministic-records.json")));
    },
  });
}, 60_000);
