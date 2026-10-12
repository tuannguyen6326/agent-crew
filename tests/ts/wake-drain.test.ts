// wake-drain.test.ts - what src/wake-drain.ts brought into src/lib.ts, held to
// the bash it twins: BUSY_RE and CAPTAIN_RE against the values bin/ac-harness.sh
// and bin/ac-lib.sh set, metaPaths against the `"$sd"/*.meta` glob, metaIsSelf
// against ac_meta_is_self, chiefGateParked against ac_chief_gate_parked,
// chiefChildLive against ac_chief_child_live and roomchiefLive's io against
// ac_roomchief_live's stdin (both through backendCall, under a fake herdr and
// orca logging every call), and claimLive against the frozen original's
// dead-claim verdict.
// The CLI contract is tests/sh/ac-wake-drain.test.sh's, whose differential leg
// runs that original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-wake-drain-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));
const ROOTED = process.getuid?.() === 0;

type Run = { code: number | null; out: string; err: string };

function bash(script: string, env: Record<string, string>, args: string[] = [], stdin: "ignore" | Buffer = "ignore"): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, BIN, ...args], {
    env: { PATH: process.env.PATH!, LC_ALL: "C", ...env },
    stdin,
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

// The twins in a bun child started in ROOT.
function twin(body: string, env: Record<string, string>, stdin: "ignore" | Buffer = "ignore"): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(String(s)); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, LC_ALL: "C", ...env }, stdin, stdout: "pipe", stderr: "pipe" },
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

// herdr and orca answering per sentinel file, every call logged; orca logs
// what reached its stdin too.
function fakeBackend(): string {
  const d = dir("fake");
  mkdirSync(join(d, "bin"));
  exe(
    join(d, "bin", "herdr"),
    `#!/bin/sh
d="${d}"
printf 'herdr %s\\n' "$*" >>"$d/log"
case "$1 $2" in
  "pane get") [ -e "$d/win-$3" ] ;;
  "pane list") printf '{"result":{"panes":[]}}\\n' ;;
  "status server") printf '{"running":true}\\n' ;;
  *) exit 2 ;;
esac
`,
  );
  exe(
    join(d, "bin", "orca"),
    `#!/bin/sh
d="${d}"
printf 'orca %s stdin=[%s]\\n' "$*" "$(cat)" >>"$d/log"
case "$1 $2" in
  "terminal show") printf '{"ok":true,"result":{"terminal":{"connected":%s}}}\\n' "$( [ -e "$d/win-$4" ] && echo true || echo false )" ;;
  *) printf '{"ok":true}\\n' ;;
esac
`,
  );
  return d;
}

function takeLog(d: string): string {
  let s = "";
  try {
    s = readFileSync(join(d, "log"), "utf8");
  } catch {}
  rmSync(join(d, "log"), { force: true });
  return s;
}

const WAKE = '. "$0/ac-lib.sh"; . "$0/ac-backend.sh"; . "$0/ac-wake-lib.sh"';
// The shell's own `<file>: line N: ...` lines, which no twin prints.
// Shell-own stderr, never reproduced: a `<script>: line <n>:` diagnostic, and
// bash 3.2's job-control race line from herdr_rpc_bounded's `set -m`.
const shellOwn = (s: string): string =>
  s.replace(/^[^ ]*: line [0-9]+: .*\n/gm, "").replace(/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted\n/gm, "");

test("BUSY_RE and CAPTAIN_RE are the values ac-harness.sh and ac-lib.sh set: their defaults, an exported value, an empty one", () => {
  for (const env of [{}, { AC_BUSY_RE: "busy", AC_CAPTAIN_RE: "cap" }, { AC_BUSY_RE: "", AC_CAPTAIN_RE: "" }]) {
    const want = bash('. "$0/ac-lib.sh"; printf "%s\\n%s" "$AC_BUSY_RE" "$AC_CAPTAIN_RE"', env).out;
    expect(twin('say(L.BUSY_RE + "\\n" + L.CAPTAIN_RE)', env).out).toBe(want);
  }
}, 30000);

test("metaPaths lists what the `*.meta` glob lists under C: no dot names, links of every kind, byte order", () => {
  const sd = dir("mp");
  for (const f of ["b.meta", "B.meta", "a.meta", ".hidden.meta", "x.metax", "meta", "é.meta", "z.meta.meta"]) writeFileSync(join(sd, f), "");
  mkdirSync(join(sd, "d.meta"));
  symlinkSync(join(sd, "nowhere"), join(sd, "dangling.meta"));
  const want = bash('for m in "$1"/*.meta; do printf "%s\\n" "$m"; done', {}, [sd]).out;
  expect(twin(`say(L.metaPaths(${JSON.stringify(sd)}).map((p) => p + "\\n").join(""))`, {}).out).toBe(want);
  expect(twin(`say(JSON.stringify(L.metaPaths(${JSON.stringify(join(sd, "absent"))})))`, {}).out).toBe("[]");
}, 30000);

test("metaIsSelf answers ac_meta_is_self: kind exactly self as awk read it, absent, unreadable and a directory none, silently", () => {
  const sd = dir("self");
  const metas: [string, string | null][] = [
    ["self", "kind=self\n"],
    ["cr", "kind=self\r\n"],
    ["nulmid", "kind=se\0lf\n"],
    ["nulend", "kind=self\0x\n"],
    ["last", "kind=x\nkind=self\n"],
    ["emptied", "kind=self\nkind=\n"],
    ["bare", "kind\n"],
    ["selfie", "kind=selfie\n"],
    ["empty", ""],
    ["absent", null],
  ];
  for (const [id, body] of metas) if (body !== null) writeFileSync(join(sd, `${id}.meta`), body);
  mkdirSync(join(sd, "dir.meta"));
  const ids = [...metas.map(([id]) => id), "dir"];
  if (!ROOTED) {
    writeFileSync(join(sd, "shut.meta"), "kind=self\n");
    chmodSync(join(sd, "shut.meta"), 0o000);
    ids.push("shut");
  }
  for (const id of ids) {
    const m = join(sd, `${id}.meta`);
    const want = bash(`. "$0/ac-lib.sh"; ac_meta_is_self "$1" && printf y || printf n`, {}, [m]);
    const got = twin(`say(L.metaIsSelf(${JSON.stringify(m)}) ? "y" : "n")`, {});
    expect({ id, out: got.out, err: got.err }).toEqual({ id, out: want.out, err: want.err });
  }
  if (!ROOTED) chmodSync(join(sd, "shut.meta"), 0o644);
}, 60000);

test("chiefGateParked answers ac_chief_gate_parked: an open GATE/ASK parks, an answered one or no room does not, an unreadable room is grep's line and not parked", () => {
  const home = dir("gp");
  const data = join(home, "data");
  const rooms: [string, string][] = [
    ["open", "# Room\n\n- [t] crewchief> GATE: approve?\n"],
    ["ask", "- [t] crewchief> ASK (1 of 2): which?\n"],
    ["settled", "- [t] crewchief> GATE: approve?\n- [t] captain> DECIDED: yes\n"],
    ["looped", "- [t] crewchief> GATE-LOOPED: r1\n"],
    ["quoted", "- [t] crewchief> note > GATE: not a marker\n"],
  ];
  for (const [fam, body] of rooms) {
    mkdirSync(join(data, fam), { recursive: true });
    writeFileSync(join(data, fam, "room.md"), body);
  }
  mkdirSync(join(data, "dirroom", "room.md"), { recursive: true });
  const ids = [...rooms.map(([f]) => `${f}-chief`), "none-chief", "dirroom-chief", "open", "open-chiefx", "-chief"];
  if (!ROOTED) {
    mkdirSync(join(data, "shut"));
    writeFileSync(join(data, "shut", "room.md"), "- [t] crewchief> GATE: x\n");
    chmodSync(join(data, "shut", "room.md"), 0o000);
    ids.push("shut-chief");
  }
  const env = { AC_HOME: home };
  for (const id of ids) {
    const want = bash(`${WAKE}; ac_chief_gate_parked "$1" && printf y || printf n`, env, [id]);
    const got = twin(`say(L.chiefGateParked(${JSON.stringify(id)}) ? "y" : "n")`, env);
    expect({ id, out: got.out, err: got.err }).toEqual({ id, out: want.out, err: shellOwn(want.err) });
  }
  if (!ROOTED) chmodSync(join(data, "shut", "room.md"), 0o644);
}, 60000);

test("chiefChildLive answers ac_chief_child_live through backendCall: members by suffix or fleet_scope, the chief and verifiers skipped, the first live member", () => {
  const fb = fakeBackend();
  const home = dir("cl");
  const sd = join(home, "state");
  mkdirSync(sd);
  mkdirSync(join(home, "data", "c", "spec"), { recursive: true });
  // data/c/chief makes the chief's own id read as the family: skipped first all the same.
  mkdirSync(join(home, "data", "c", "chief"));
  const metas: [string, string, boolean][] = [
    ["c-chief", "kind=roomchief\n", true],
    ["c-spec", "kind=spec\n", false],
    ["c-api", "fleet_scope=c\nbackend=orca\n", true],
    ["c-curate-x", "kind=x\n", true],
    ["v-x", "kind=verify-qa\nfleet_scope=c\n", true],
    ["s-api", "fleet_scope=s\n", false],
    ["t-chief", "kind=roomchief\n", false],
  ];
  for (const [id, body, live] of metas) {
    writeFileSync(join(sd, `${id}.meta`), body);
    writeFileSync(join(sd, `.pane-${id}`), `p${id} t\n`);
    if (live) writeFileSync(join(fb, `win-p${id}`), "");
  }
  const env = { AC_HOME: home, PATH: `${fb}/bin:${process.env.PATH}` };
  const check = (label: string): void => {
    for (const id of ["c-chief", "s-chief", "t-chief", "x-chief", "c-api", "-chief"]) {
      takeLog(fb);
      const want = bash(`${WAKE}; ac_chief_child_live "$1" "$2" && printf y || printf n`, env, [sd, id]);
      const wantLog = takeLog(fb);
      const got = twin(`say(L.chiefChildLive(${JSON.stringify(sd)}, ${JSON.stringify(id)}, { stdin: "inherit", stdout: "inherit" }) ? "y" : "n")`, env);
      expect({ label, id, out: got.out, err: got.err, log: takeLog(fb) }).toEqual({ label, id, out: want.out, err: shellOwn(want.err), log: wantLog });
    }
  };
  check("c-api live");
  rmSync(join(fb, "win-pc-api"));
  check("c-api gone");
  if (!ROOTED) {
    chmodSync(join(sd, "s-api.meta"), 0o000);
    check("s-api unreadable");
    chmodSync(join(sd, "s-api.meta"), 0o644);
  }
}, 120000);

test("roomchiefLive passes the caller's stdin to the probe only when asked, as the completion scope's bash call left it", () => {
  const fb = fakeBackend();
  const home = dir("io");
  const sd = join(home, "state");
  mkdirSync(sd);
  writeFileSync(join(sd, "o-chief.meta"), "backend=orca\n");
  writeFileSync(join(sd, ".pane-o-chief"), "ho t\n");
  writeFileSync(join(fb, "win-ho"), "");
  const env = { AC_HOME: home, PATH: `${fb}/bin:${process.env.PATH}` };
  const input = Buffer.from("from-caller\n");
  takeLog(fb);
  const want = bash(`${WAKE}; ac_roomchief_live "$1" o && printf live`, env, [sd], input);
  const wantLog = takeLog(fb);
  expect(wantLog).toContain("stdin=[from-caller]");
  const got = twin(`say(L.roomchiefLive(${JSON.stringify(sd)}, "o", { stdin: "inherit", stdout: "inherit" }) ? "live" : "gone")`, env, input);
  expect({ out: got.out, log: takeLog(fb) }).toEqual({ out: want.out, log: wantLog });
  const quiet = twin(`say(L.roomchiefLive(${JSON.stringify(sd)}, "o") ? "live" : "gone")`, env, input);
  expect({ out: quiet.out, log: takeLog(fb) }).toEqual({ out: "live", log: "orca terminal show --terminal ho --json stdin=[]\n" });
}, 60000);

test("claimLive keeps what the original's sweep kept, and a live drainer running src/wake-drain.ts too", () => {
  const verdict = `. "$0/ac-lib.sh"; pid="$1"
if [ "$pid" != "$$" ] && ac_pid_alive "$pid"; then
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || { printf kept; exit 0; }
  case "$cmd" in *ac-wake-drain*) printf kept; exit 0 ;; esac
fi
printf swept`;
  const blind = dir("blind");
  exe(join(blind, "ps"), '#!/bin/sh\ncase "$*" in *command=*) exit 1 ;; esac\nexec /bin/ps "$@"\n');
  const dead = Bun.spawnSync(["/bin/sh", "-c", "echo $$"]).stdout.toString().trim();
  const procs = [
    Bun.spawn(["/bin/bash", "-c", "exec -a ac-wake-drain.sh sleep 30"]),
    Bun.spawn(["/bin/bash", "-c", "exec -a 'bun --no-env-file /x/src/wake-drain.ts /c' sleep 30"]),
    Bun.spawn(["sleep", "30"]),
  ];
  try {
    Bun.sleepSync(200);
    const [named, ts, reused] = procs.map((p) => String(p.pid));
    const cases: [string, Record<string, string>, string | null][] = [
      [dead, {}, null],
      [`0${named}`, {}, null],
      [named!, {}, null],
      [reused!, {}, null],
      [reused!, { PATH: `${blind}:${process.env.PATH}` }, null],
      // the widened match - the original read a live TS drainer as a reused pid
      [ts!, {}, "kept"],
    ];
    for (const [pid, env, diverge] of cases) {
      const want = diverge ?? bash(verdict, env, [pid]).out;
      expect({ pid, env, got: twin(`say(L.claimLive(${JSON.stringify(pid)}) ? "kept" : "swept")`, env).out }).toEqual({ pid, env, got: want });
    }
    expect(bash(verdict, {}, [ts!]).out).toBe("swept");
    expect(twin("say(L.claimLive(String(process.pid)) ? 'kept' : 'swept')", {}).out).toBe("swept");
  } finally {
    for (const p of procs) p.kill();
  }
}, 60000);
