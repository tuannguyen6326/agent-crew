// watch.test.ts - what src/watch.ts brought into src/lib.ts, held to the bash
// it twins: DECISION_RE against the value bin/ac-lib.sh sets, watcherBeatPath
// against ac_watcher_beat_path, pidChain against ac_pid_chain over one live
// process tree, brainMarkerAge / brainFreshen against ac_brain_marker_age /
// ac_brain_freshen - which bin/ac-prompt-recall.sh keeps calling - under one
// PATH `date` and a `bun` stub that logs the sync each side fires, and
// claudeTranscriptPath against ac_claude_transcript_path. The CLI
// contract is tests/sh/ac-watch.test.sh's, whose differential leg runs the
// frozen original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-watch-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

type Run = { code: number | null; out: string; err: string };

// Both sides start in ROOT, so a detached sync inherits the same cwd.
function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, BIN, ...args], {
    cwd: ROOT,
    env: { PATH: process.env.PATH!, LC_ALL: "C", ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(String(s)); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, LC_ALL: "C", ...env }, stdout: "pipe", stderr: "pipe" },
  );
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

let n = 0;
function dir(name: string): string {
  const d = join(W, `${name}${n++}`);
  mkdirSync(d, { recursive: true });
  return d;
}

function exe(path: string, body: string): void {
  writeFileSync(path, body);
  chmodSync(path, 0o755);
}

test("DECISION_RE is the value ac-lib.sh sets: its default, an exported value, an empty one", () => {
  for (const env of [{}, { AC_DECISION_RE: "decide" }, { AC_DECISION_RE: "" }]) {
    const want = bash('. "$0/ac-lib.sh"; printf "%s" "$AC_DECISION_RE"', env).out;
    expect(twin("say(L.DECISION_RE)", env).out).toBe(want);
  }
}, 30000);

test("watcherBeatPath names the beacon ac_watcher_beat_path names, a refused scope the fleet's", () => {
  const sd = dir("beat");
  for (const scope of ["", "f1", "fam_2-x", "a/b", "a.b", "..", " f", "café"]) {
    const want = bash('. "$0/ac-lib.sh"; . "$0/ac-wake-lib.sh"; ac_watcher_beat_path "$1" "$2"', {}, [sd, scope]).out;
    expect([scope, twin(`say(L.watcherBeatPath(${JSON.stringify(sd)}, ${JSON.stringify(scope)}) + "\\n")`, {}).out]).toEqual([scope, want]);
  }
}, 60000);

// One tree both sides read at once: a sleep under a bash under this runner, so
// the chain is the same live ancestry up to init.
test("pidChain names the chain ac_pid_chain names: a live tree, a dead pid, no integer, init", async () => {
  const holder = Bun.spawn(["/bin/bash", "-c", "sleep 30 & wait"], { stdout: "ignore", stderr: "ignore" });
  try {
    let leaf = "";
    for (let i = 0; i < 100 && leaf === ""; i++) {
      for (const l of Bun.spawnSync(["ps", "-o", "pid=,ppid=,comm=", "-A"]).stdout.toString().split("\n")) {
        const f = l.trim().split(/\s+/);
        if (f[1] === String(holder.pid) && /(^|\/)sleep$/.test(f[2] ?? "")) leaf = f[0]!;
      }
      if (leaf === "") Bun.sleepSync(50);
    }
    expect(leaf).not.toBe("");
    const dead = Bun.spawnSync(["/bin/sh", "-c", "echo $$"]).stdout.toString().trim();
    for (const pid of [leaf, String(holder.pid), dead, "1", "0", "abc"]) {
      const want = bash('. "$0/ac-lib.sh"; ac_pid_chain "$1"', {}, [pid]).out;
      expect([pid, twin(`say(L.pidChain(${JSON.stringify(pid)}) + "\\n")`, {}).out]).toEqual([pid, want]);
    }
    // No pid, or an empty one (`${1:-$$}`), chains from the caller itself: the
    // sides are two processes under this runner, alike from the runner up.
    const own = (chain: string): string[] => [chain.split(" < ")[0]!.replace(/^[0-9]+/, "P"), chain.split(" < ").slice(1).join(" < ")];
    const self = own(bash('. "$0/ac-lib.sh"; ac_pid_chain ""', {}).out);
    expect(self[0]).toBe("P(bash)");
    for (const arg of ["", '""']) expect(own(twin(`say(L.pidChain(${arg}) + "\\n")`, {}).out)).toEqual(["P(bun)", self[1]!]);
  } finally {
    holder.kill();
    await holder.exited;
  }
}, 60000);

// A clock both sides read through PATH's date, and a bun that only logs: the
// shim ac-brain.sh execs it, so a fired sync is one line in the log.
function freshenWorld(): { home: string; env: Record<string, string>; log: string } {
  const d = dir("brain");
  const stub = join(d, "stub");
  mkdirSync(stub);
  const log = join(d, "fired.log");
  exe(join(stub, "date"), `#!/bin/sh\ncase "$1" in +%s) printf '%s\\n' "$STUB_NOW" ;; *) exec /bin/date "$@" ;; esac\n`);
  exe(join(stub, "bun"), `#!/bin/sh\nprintf '%s\\n' "$*" >>${JSON.stringify(log)}\n`);
  const home = join(d, "home");
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(join(home, "config"), { recursive: true });
  return { home: realpathSync(home), env: { PATH: `${stub}:${process.env.PATH}`, AC_HOME: home, STUB_NOW: "2000000000" }, log };
}

// The sync is detached: a side that says it fired is waited for, one that
// did not gets a moment to prove it fired nothing.
const settle = (log: string, fired: boolean): string => {
  for (let i = 0; i < 100 && fired && !existsSync(log); i++) Bun.sleepSync(50);
  Bun.sleepSync(fired ? 100 : 300);
  return existsSync(log) ? readFileSync(log, "utf8") : "";
};

test("brainMarkerAge reads ac_brain_marker_age's age: no marker -1, a marker by date(1)'s clock, homeless the refusal", () => {
  const w = freshenWorld();
  const marker = join(w.home, "state", ".brain-last-sync");
  const age = (): [string, string] => [bash('. "$0/ac-lib.sh"; ac_brain_marker_age', w.env).out, twin("say(L.brainMarkerAge() + '\\n')", w.env).out];
  let [want, got] = age();
  expect(want).toBe("-1\n");
  expect(got).toBe(want);
  writeFileSync(marker, "");
  utimesSync(marker, 1999999000, 1999999000);
  [want, got] = age();
  expect(want).toBe("1000\n");
  expect(got).toBe(want);
  const { AC_HOME: _, ...homeless } = w.env;
  const b = bash('. "$0/ac-lib.sh"; ac_brain_marker_age; echo "rc=$?"', homeless);
  const t = twin("const a = L.brainMarkerAge(); say(a === null ? 'rc=1\\n' : a + '\\n')", homeless);
  expect(t.out).toBe(b.out);
  expect(t.err).toBe(b.err);
}, 60000);

test("brainFreshen fires when ac_brain_freshen fires, the same sync, and touches the same attempt stamp", () => {
  type Shape = { name: string; db: boolean; valve?: string; marker?: number | null; attempt?: number | null; iv?: string };
  const shapes: Shape[] = [
    { name: "no brain", db: false, marker: null },
    { name: "valve off", db: true, valve: "off", marker: null },
    { name: "never synced", db: true, marker: null },
    { name: "fresh marker", db: true, marker: 1999999900 },
    { name: "stale marker", db: true, marker: 1999990000 },
    { name: "stale marker, fresh attempt", db: true, marker: 1999990000, attempt: 1999999900 },
    { name: "stale marker, stale attempt", db: true, marker: 1999990000, attempt: 1999990000 },
    { name: "interval no integer", db: true, marker: null, iv: "abc" },
    { name: "interval 0", db: true, marker: 1999999999, iv: "0" },
  ];
  for (const s of shapes) {
    const runs: { fired: string; log: string; attempt: string }[] = [];
    for (const side of ["bash", "twin"] as const) {
      const w = freshenWorld();
      const st = join(w.home, "state");
      if (s.db) writeFileSync(join(st, "brain.sqlite"), "");
      if (s.valve) writeFileSync(join(w.home, "config", "brain-auto-sync"), `${s.valve}\n`);
      if (s.marker != null) {
        writeFileSync(join(st, ".brain-last-sync"), "");
        utimesSync(join(st, ".brain-last-sync"), s.marker, s.marker);
      }
      if (s.attempt != null) {
        writeFileSync(join(st, ".brain-freshen-attempt"), "");
        utimesSync(join(st, ".brain-freshen-attempt"), s.attempt, s.attempt);
      }
      const env = s.iv === undefined ? w.env : { ...w.env, AC_BRAIN_SYNC_IV: s.iv };
      const r = side === "bash" ? bash('. "$0/ac-lib.sh"; ac_brain_freshen', env) : twin("say(L.brainFreshen() ? 'fired\\n' : '')", env);
      const attempt = join(st, ".brain-freshen-attempt");
      runs.push({
        fired: r.out,
        log: settle(w.log, r.out !== "").replaceAll(w.home, "HOME"),
        attempt: !existsSync(attempt) ? "absent" : s.attempt == null ? "created" : Math.floor(statSync(attempt).mtimeMs / 1000) === s.attempt ? "kept" : "touched",
      });
    }
    expect([s.name, runs[1]]).toEqual([s.name, runs[0]]);
  }
}, 120000);

test("claudeTranscriptPath finds the one transcript ac_claude_transcript_path finds, the root read as its capture read it", () => {
  const sid = "0b1c2d3e-4f50-6172-8394-a5b6c7d8e9f0";
  const rows: { name: string; env: (d: string) => Record<string, string>; seed: string[] }[] = [
    { name: "AC_CLAUDE_TRANSCRIPT_ROOT", env: (d) => ({ AC_CLAUDE_TRANSCRIPT_ROOT: `${d}/tr` }), seed: ["tr/-w-a"] },
    { name: "a root ending in one LF", env: (d) => ({ AC_CLAUDE_TRANSCRIPT_ROOT: `${d}/tr\n` }), seed: ["tr/-w-a"] },
    { name: "a root ending in two LFs", env: (d) => ({ AC_CLAUDE_TRANSCRIPT_ROOT: `${d}/tr\n\n` }), seed: ["tr/-w-a"] },
    { name: "CLAUDE_CONFIG_DIR's projects", env: (d) => ({ CLAUDE_CONFIG_DIR: `${d}/cfg` }), seed: ["cfg/projects/-w-a"] },
    { name: "HOME's .claude/projects", env: () => ({}), seed: ["hh/.claude/projects/-w-a"] },
    { name: "no transcript", env: (d) => ({ AC_CLAUDE_TRANSCRIPT_ROOT: `${d}/tr` }), seed: [] },
    { name: "two transcripts", env: (d) => ({ AC_CLAUDE_TRANSCRIPT_ROOT: `${d}/tr` }), seed: ["tr/-w-a", "tr/-w-b"] },
  ];
  for (const r of rows) {
    const d = dir("tp");
    for (const s of r.seed) {
      mkdirSync(join(d, s), { recursive: true });
      writeFileSync(join(d, s, `${sid}.jsonl`), "{}\n");
    }
    const env = { HOME: join(d, "hh"), ...r.env(d) };
    const want = bash('. "$0/ac-lib.sh"; ac_claude_transcript_path "$1"; printf "rc=%s" "$?"', env, [sid]);
    const got = twin(`const p = L.claudeTranscriptPath(${JSON.stringify(sid)}); say(p === null ? "rc=1" : p + "\\nrc=0")`, env);
    expect([r.name, got.out]).toEqual([r.name, want.out]);
  }
}, 60000);
