// done.test.ts - the lib.ts twins src/done.ts introduced, held to their bash
// originals in bin/ac-wake-lib.sh differentially: wakeScopeOk / wakeSpoolPath
// against ac_wake_scope_ok / ac_wake_spool_path, wakePublish against
// ac_wake_publish on the RECORD BYTES and the FILENAME grammar (the fleet wire
// three bash producers still write) under one PATH `date` stub, and watcherPid /
// watcherNudge against ac_watcher_pid / ac_watcher_nudge over the lock-file
// shapes and a stand-in watcher. A record the twin wrote is also drained by the
// real bin/ac-wake-drain.sh. The CLI contract itself is tests/sh/ac-done.test.sh's,
// whose differential leg runs the frozen bash original beside the shim.
import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { wakePublish, wakeScopeOk, wakeSpoolPath, watcherNudge, watcherPid } from "../../src/lib.ts";

const root = join(import.meta.dir, "..", "..");
const binDir = join(root, "bin");
const savedEnv = { ...process.env };
const dirs: string[] = [];
afterEach(() => {
  for (const k of Object.keys(process.env)) if (!(k in savedEnv)) delete process.env[k];
  Object.assign(process.env, savedEnv);
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});
const tmp = (tag: string): string => {
  const d = mkdtempSync(join(tmpdir(), `ac-done-${tag}-`));
  dirs.push(d);
  return d;
};

// The bash side sources both libs and runs under LC_ALL=C (the leg's locale -
// under a UTF-8 locale bash 3.2's [!A-Za-z0-9_-] accepts `é` by range
// collation, an outside actor's behaviour the port does not reproduce).
function bash(body: string, ...args: string[]) {
  const r = Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-wake-lib.sh"; ${body}`, binDir, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C" },
  });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

// `date +%s%N` answers STUB_STAMP to both sides; every other call reaches the
// real date.
function stubDate(stamp: string): void {
  const d = tmp("date");
  writeFileSync(join(d, "date"), '#!/bin/sh\ncase "$1" in +%s%N) printf "%s\\n" "$STUB_STAMP" ;; *) exec /bin/date "$@" ;; esac\n', { mode: 0o755 });
  process.env.PATH = `${d}:${process.env.PATH}`;
  process.env.STUB_STAMP = stamp;
}

// Every entry under a state dir, byte order, as `<name>` plus its bytes and mode
// for a file - the pid in a record name spelled PID, mktemp's suffix RANDOM.
function snapshot(sd: string, pid: number): string[] {
  const names = (readdirSync(sd, { recursive: true }) as string[]).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  return names.map((n) => {
    const p = join(sd, n);
    const st = statSync(p);
    const shown = n.replace(`.${pid}.`, ".PID.").replace(/\.wake-tmp\.[A-Za-z0-9]{8}$/, ".wake-tmp.RANDOM");
    return st.isFile() ? `${shown} ${(st.mode & 0o777).toString(8)} ${readFileSync(p, "latin1")}` : `${shown}/`;
  });
}

const SCOPES = ["f1", "a/b", ".x", "f 1", "", "-", "_", "A-Z_09", "é", "a\n", "spool", "draining", "a.b", " f1"];

test("wakeScopeOk and wakeSpoolPath answer as ac_wake_scope_ok and ac_wake_spool_path", () => {
  for (const s of SCOPES) {
    const ok = bash('ac_wake_scope_ok "$1"', s);
    expect([s, wakeScopeOk(s)]).toEqual([s, ok.rc === 0]);
    const path = bash('ac_wake_spool_path "$1" "$2"', "/sd", s);
    expect([s, `${wakeSpoolPath("/sd", s)}\n`]).toEqual([s, path.out]);
  }
});

// The TS side publishes from a FRESH bun process per case, as each `bash -c`
// is: the sequence counter is process-global and never resets, so one long
// test process would drift from the bash's 000000. The payload travels as hex
// (argv cannot carry a byte that is not UTF-8 into bun - the entry's
// divergence, not the twin's); PLANT names sequence numbers to pre-occupy
// under this process's own pid before publishing.
function tsPublish(sd: string, scope: string, ids: string[], payload: string, plant: string[] = []) {
  const script = `
    import { mkdirSync, writeFileSync } from "node:fs";
    import { wakePublish } from "./src/lib.ts";
    const e = process.env;
    for (const seq of (e.PLANT ?? "").split(",").filter(Boolean)) {
      mkdirSync(e.SD + "/.wake-spool", { recursive: true });
      writeFileSync(e.SD + "/.wake-spool/" + e.STUB_STAMP + "." + process.pid + "." + seq, "planted\\n");
    }
    let ok = true;
    for (const id of e.IDS.split(",")) ok = ok && wakePublish(e.SD, e.SCOPE, "report", id, Buffer.from(e.HEX, "hex").toString("latin1"));
    console.log(process.pid);
    process.exit(ok ? 0 : 1);`;
  const r = Bun.spawnSync([process.execPath, "--no-env-file", "-e", script], {
    cwd: root,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, SD: sd, SCOPE: scope, IDS: ids.join(","), HEX: Buffer.from(payload, "latin1").toString("hex"), PLANT: plant.join(",") },
  });
  return { rc: r.exitCode ?? -1, pid: Number(r.stdout.toString().trim()), err: r.stderr.toString("latin1") };
}

// Both sides publish `report` for id c1 into their own state dir and the trees
// left behind are compared whole: one record whose name is <stamp>.<pid>.000000,
// mode 0600 (mktemp's, carried by the hard link), no .wake-tmp.* litter.
// The bash payload is a printf format so a byte that is not UTF-8 can reach it.
test("wakePublish writes the record bytes and filename ac_wake_publish writes", () => {
  stubDate("1700000000123456789");
  const cases: { fmt: string; ts: string; scope: string }[] = [
    { fmt: "done: shipped", ts: "done: shipped", scope: "" },
    { fmt: "done:\\tx\\ny", ts: "done:\tx\ny", scope: "" },
    { fmt: "  padded  ", ts: "  padded  ", scope: "f1" },
    { fmt: "caf\\351 ok", ts: "caf\xe9 ok", scope: "a/b" },
    { fmt: "%%s%%s -n", ts: "%s%s -n", scope: ".x" },
    { fmt: "a".repeat(4096), ts: "a".repeat(4096), scope: "" },
    { fmt: "tail\\n", ts: "tail\n", scope: "" },
  ];
  for (const c of cases) {
    const os = tmp("os"), ns = tmp("ns");
    const o = bash('printf -v p -- "$3"; ac_wake_publish "$1" "$2" report c1 "$p"; rc=$?; echo "$$"; exit $rc', os, c.scope, c.fmt);
    expect([c.fmt, o.rc]).toEqual([c.fmt, 0]);
    const n = tsPublish(ns, c.scope, ["c1"], c.ts);
    expect([c.fmt, n.rc]).toEqual([c.fmt, 0]);
    expect([c.fmt, snapshot(ns, n.pid)]).toEqual([c.fmt, snapshot(os, Number(o.out.trim()))]);
    const spool = wakeSpoolPath(ns, c.scope);
    const names = readdirSync(spool);
    expect(names).toEqual([`1700000000123456789.${n.pid}.000000`]);
    expect(readFileSync(join(spool, names[0]!), "latin1")).toBe(`1700000000\treport\tc1\t${c.ts.replace(/[\t\n]/g, " ")}\n`);
  }
});

// A `date` without %N prints the literal N: the filename keeps it verbatim and
// the record's stamp is the first ten digits. A clock printing garbage, or
// nothing, refuses BEFORE any byte exists.
test("wakePublish keeps the stamp verbatim in the name and refuses a broken clock like the bash", () => {
  for (const stamp of ["1700000000N", "garbage", "", "170000000"]) {
    stubDate(stamp);
    const os = tmp("os"), ns = tmp("ns");
    const o = bash('ac_wake_publish "$1" "" report c1 "done: x"; rc=$?; echo "$$"; exit $rc', os);
    const n = tsPublish(ns, "", ["c1"], "done: x");
    expect([stamp, n.rc]).toEqual([stamp, o.rc]);
    expect([stamp, snapshot(ns, n.pid)]).toEqual([stamp, snapshot(os, Number(o.out.trim()))]);
    if (n.rc === 0) expect(readdirSync(join(ns, ".wake-spool"))).toEqual([`${stamp}.${n.pid}.000000`]);
    else expect(readdirSync(ns)).toEqual([]);
  }
});

// A name already taken (a dead predecessor's record bearing this pid) is
// stepped past, the counter never resets, and a second publish from the same
// process continues from where the first ended.
test("wakePublish steps past EEXIST and keeps one monotonic sequence per process", () => {
  stubDate("1700000000123456789");
  const os = tmp("os"), ns = tmp("ns");
  const o = bash(
    'mkdir "$1/.wake-spool"; for s in 000000 000001; do printf "planted\\n" >"$1/.wake-spool/1700000000123456789.$$.$s"; done; ac_wake_publish "$1" "" report c1 first && ac_wake_publish "$1" "" report c2 first; rc=$?; echo "$$"; exit $rc',
    os,
  );
  expect(o.rc).toBe(0);
  const n = tsPublish(ns, "", ["c1", "c2"], "first", ["000000", "000001"]);
  expect(n.rc).toBe(0);
  expect(snapshot(ns, n.pid)).toEqual(snapshot(os, Number(o.out.trim())));
  expect(readdirSync(join(ns, ".wake-spool")).sort()).toEqual(["000000", "000001", "000002", "000003"].map((s) => `1700000000123456789.${n.pid}.${s}`));
});

// The spool path taken by a regular file: mkdir -p fails with its own line,
// the publish refuses, and the written record is RETAINED as .wake-tmp.* litter.
test("wakePublish retains the temp as litter when the spool cannot be made", () => {
  stubDate("1700000000123456789");
  const os = tmp("os"), ns = tmp("ns");
  writeFileSync(join(os, ".wake-spool"), "");
  writeFileSync(join(ns, ".wake-spool"), "");
  const o = bash('ac_wake_publish "$1" "" report c1 "done: x"; rc=$?; echo "$$"; exit $rc', os);
  expect(o.rc).toBe(1);
  expect(o.err).toBe(`mkdir: ${os}/.wake-spool: File exists\n`);
  const n = tsPublish(ns, "", ["c1"], "done: x");
  expect(n.rc).toBe(1);
  expect(n.err).toBe(`mkdir: ${ns}/.wake-spool: File exists\n`);
  const litter = readdirSync(ns).filter((x) => x.startsWith(".wake-tmp."));
  expect(litter.length).toBe(1);
  expect(readFileSync(join(ns, litter[0]!), "latin1")).toBe("1700000000\treport\tc1\tdone: x\n");
  expect(snapshot(ns, n.pid)).toEqual(snapshot(os, Number(o.out.trim())));
});

// The test seam: a hook named by AC_WAKE_SEAM_AT=after-write runs between the
// private write and the spool mkdir, so it sees the temp and no spool - the
// same two facts on both sides. Another label leaves it inert.
test("wakePublish runs the after-write seam exactly where ac_wake_publish does", () => {
  stubDate("1700000000123456789");
  const hookDir = tmp("hook");
  const hook = join(hookDir, "seam");
  writeFileSync(hook, '#!/bin/sh\nls -A "$SD" | sed -E "s/\\.wake-tmp\\..{8}/.wake-tmp.RANDOM/" >"$SD.seen"\n', { mode: 0o755 });
  for (const at of ["after-write", "elsewhere"]) {
    process.env.AC_WAKE_SEAM_AT = at;
    process.env.AC_WAKE_SEAM_RUN = hook;
    const os = tmp("os"), ns = tmp("ns");
    process.env.SD = os;
    expect(bash('ac_wake_publish "$1" "" report c1 "done: x"', os).rc).toBe(0);
    process.env.SD = ns;
    expect(wakePublish(ns, "", "report", "c1", "done: x")).toBe(true);
    const seen = (sd: string) => (existsSync(`${sd}.seen`) ? readFileSync(`${sd}.seen`, "utf8") : "not run");
    expect([at, seen(ns)]).toEqual([at, seen(os)]);
    if (at === "after-write") expect(seen(ns)).toBe(".wake-tmp.RANDOM\n");
    else expect(seen(ns)).toBe("not run");
  }
});

// What the twin publishes, the real bash drain claims and renders.
test("bin/ac-wake-drain.sh drains a record wakePublish wrote", () => {
  const home = tmp("home");
  for (const d of ["state", "data", "records", "config", "projects"]) mkdirSync(join(home, d));
  expect(wakePublish(join(home, "state"), "", "report", "c1", "done: shipped the widget")).toBe(true);
  const env = { ...process.env, AC_HOME: home };
  delete env.AC_SCOPE;
  const r = Bun.spawnSync([join(binDir, "ac-wake-drain.sh")], { stdout: "pipe", stderr: "pipe", env });
  expect(r.stdout.toString()).toContain("report c1 done: shipped the widget\n");
  expect(readdirSync(join(home, "state", ".wake-spool"))).toEqual([]);
});

// The lock-file shapes that read as "no watcher": not digits-only, a leading
// zero, empty, a missing file, a missing dir, a dead pid, a live pid running
// something that is not a watcher.
test("watcherPid and watcherNudge refuse every lock shape ac_watcher_pid refuses", () => {
  const sd = tmp("sd");
  const victim = Bun.spawn(["sleep", "30"], { stdout: "ignore", stderr: "ignore" });
  try {
    const dead = Bun.spawnSync(["sh", "-c", "echo $$"]).stdout.toString().trim();
    const shapes: [string, string | null][] = [
      ["lock", `${process.pid} \n`],
      ["lock", `0${process.pid}\n`],
      ["lock", "abc\n"],
      ["lock", ""],
      ["lock", `${dead}\n`],
      ["lock", `${victim.pid}\n`],
      ["lock", null],
      ["nolock", null],
    ];
    for (const [kind, pid] of shapes) {
      rmSync(join(sd, ".watch.lock.d"), { recursive: true, force: true });
      rmSync(join(sd, ".watch-only-f1.lock.d"), { recursive: true, force: true });
      for (const scope of ["", "f1", "a/b"]) {
        const lock = scope === "f1" ? ".watch-only-f1.lock.d" : ".watch.lock.d";
        if (kind === "lock") {
          mkdirSync(join(sd, lock), { recursive: true });
          if (pid !== null) writeFileSync(join(sd, lock, "pid"), pid);
        }
        const o = bash('ac_watcher_pid "$1" "$2"; echo "rc=$?"; ac_watcher_nudge "$1" "$2"', sd, scope);
        expect([kind, pid, scope, o.out]).toEqual([kind, pid, scope, "rc=1\nno armed watcher for this scope - the record waits in the spool\n"]);
        expect([kind, pid, scope, watcherPid(sd, scope)]).toEqual([kind, pid, scope, null]);
        expect(`${watcherNudge(sd, scope)}\n`).toBe(o.out.slice("rc=1\n".length));
        rmSync(join(sd, lock), { recursive: true, force: true });
      }
    }
    expect(victim.killed).toBe(false);
  } finally {
    victim.kill();
  }
});

// A stand-in whose command line is a watcher's. With a poll `sleep` child each
// side nudges its own (the signal ends that wait, so one per side); with a
// child that is not a sleep both sides leave the one stand-in alone and say so.
function standIn(dir: string, body: string, flag: string) {
  const script = join(dir, "ac-watch.sh");
  writeFileSync(script, `#!/usr/bin/env bash\n${body} &\nwait $! 2>/dev/null || true\nprintf 'wait ended\\n' >"$1"\n`, { mode: 0o755 });
  const proc = Bun.spawn(["bash", script, flag], { stdout: "ignore", stderr: "ignore" });
  const deadline = Date.now() + 5000;
  for (;;) {
    const ps = Bun.spawnSync(["ps", "-o", "pid=,ppid=,comm=", "-A"]).stdout.toString();
    if (ps.split("\n").some((l) => l.trim().split(/\s+/)[1] === String(proc.pid))) break;
    if (Date.now() > deadline) throw new Error("the stand-in never started its child");
    Bun.sleepSync(50);
  }
  return proc;
}
const armed = (sd: string, lock: string, pid: number) => {
  mkdirSync(join(sd, lock), { recursive: true });
  writeFileSync(join(sd, lock, "pid"), `${pid}\n`);
};
const norm = (s: string) => s.replace(/pid=[0-9]+/, "pid=P").replace(/sleep [0-9]+/, "sleep C");

test("watcherNudge ends a live watcher's poll sleep, and only that, as ac_watcher_nudge does", async () => {
  const sd = tmp("sd");
  const fw = tmp("fw");
  const oFlag = join(fw, "o.woke"), nFlag = join(fw, "n.woke");
  for (const [scope, lock] of [["", ".watch.lock.d"], ["f2", ".watch-only-f2.lock.d"]] as const) {
    const o = standIn(fw, "sleep 30", oFlag);
    armed(sd, lock, o.pid);
    const want = bash('ac_watcher_nudge "$1" "$2"', sd, scope);
    expect(want.out).toMatch(/^nudged watcher pid=[0-9]+ \(poll sleep [0-9]+ ended early\)\n$/);
    await o.exited;
    expect(existsSync(oFlag)).toBe(true);
    const n = standIn(fw, "sleep 30", nFlag);
    armed(sd, lock, n.pid);
    expect(`${norm(watcherNudge(sd, scope))}\n`).toBe(norm(want.out));
    await n.exited;
    expect(existsSync(nFlag)).toBe(true);
    rmSync(oFlag, { force: true });
    rmSync(nFlag, { force: true });
    rmSync(join(sd, lock), { recursive: true, force: true });
  }
  // A legal scope consults only its own lock: a live fleet watcher is no watcher for f3.
  const fleet = standIn(fw, "sleep 30", oFlag);
  armed(sd, ".watch.lock.d", fleet.pid);
  try {
    expect(watcherNudge(sd, "f3")).toBe("no armed watcher for this scope - the record waits in the spool");
    expect(bash('ac_watcher_nudge "$1" f3', sd).out).toBe("no armed watcher for this scope - the record waits in the spool\n");
  } finally {
    fleet.kill();
    await fleet.exited;
  }
  // A child that is not the poll sleep is nobody's target.
  const busy = standIn(fw, "tail -f /dev/null", nFlag);
  armed(sd, ".watch.lock.d", busy.pid);
  try {
    const want = bash('ac_watcher_nudge "$1" ""', sd);
    expect(want.out).toBe(`watcher pid=${busy.pid} is mid-poll, nothing to nudge - the record waits in the spool\n`);
    expect(`${watcherNudge(sd, "")}\n`).toBe(want.out);
    expect(watcherPid(sd, "")).toBe(String(busy.pid));
    Bun.sleepSync(200);
    expect(existsSync(nFlag)).toBe(false);
  } finally {
    Bun.spawnSync(["pkill", "-P", String(busy.pid)]);
    busy.kill();
    await busy.exited;
  }
});
