// guard.test.ts - what src/guard.ts brought into src/lib.ts, held to the bash
// it twins: testInt against bash 3.2's `[ -gt ]` operand grammar, arithValue
// against `$(( ))` over one operand (a variable's value and substituted text),
// nowRaw against `$(ac_now)`, watcherDown against ac_watcher_down,
// wakePending / wakeOrphanPending /
// roomchiefLive against ac-wake-lib.sh with ac-backend.sh sourced and a fake
// herdr and orca logging every call, repoRoot against ac_repo_root,
// backendName's soft rung against ac-backend.sh sourced as the guard sources
// it. The CLI contract itself is
// tests/sh/ac-guard.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-guard-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

type Run = { code: number | null; out: string; err: string };

function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, BIN, ...args], {
    env: { PATH: process.env.PATH!, LC_ALL: "C", ...env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

// The twins in a bun child started in ROOT (STARTED_BIN is ROOT/bin).
function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(Buffer.from(String(s), "latin1")); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, LC_ALL: "C", ...env }, stdin: "ignore", stdout: "pipe", stderr: "pipe" },
  );
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
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

test("testInt reads `[ a -gt b ]`'s operand as bash 3.2 does: isspace before, one sign, decimal digits, blanks after, int64", () => {
  const vals = [" 600 ", "+600", "-5", "010", "0x10", "600abc", "1e3", "", " ", "+", "- 5", "\t7\t", "7\n", "\n7", "\v7", "\r7", "7\r", "7\v",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "99999999999999999999", "abc", "00", "007"];
  const got = twin(`say(${JSON.stringify(vals)}.map((v) => { const x = L.testInt(v); return x === null ? "null" : String(x); }).join("|"))`, {}).out.split("|");
  vals.forEach((v, i) => {
    const want = got[i] === "null" ? "2" : "0";
    const rc = bash('[ "$1" -eq "$2" ] 2>/dev/null; printf %s "$?"', {}, [v, got[i] === "null" ? "0" : got[i]!]).out;
    expect({ v, rc }).toEqual({ v, rc: want });
  });
  expect(got.filter((g) => g !== "null").length).toBe(12);
}, 60000);

test("arithValue evaluates one operand as `$(( ))` does: octal, hex, base#, the 64-bit wrap, an error, set -u's abort", () => {
  const vals = ["", " 77 ", "0012", "01000", "0099", "08", "0x1F", "0X1f", "0x", "2#101", "64#z", "37#1", "1#1", "0#1", "010#7", "1_0", "12abc",
    "99999999999999999999", "18446744073709551616", "9223372036854775808", "-5", "- 5", "+5", "\t5\n", "5\r", "garbage", "_x", "-garbage", "1+1"];
  const got = twin(
    `say(${JSON.stringify(vals)}.map((v) => { try { return "v=" + L.arithValue(v); } catch (e) { return e.code; } }).join("|"))`,
    {},
  ).out.split("|");
  vals.forEach((v, i) => {
    // A value prints `v=N` then `next`; an evaluation error discards its
    // command - its LINE, so each command stands on its own - and the script
    // goes on to `next`; set -u's abort ends it.
    for (const script of ['set -u\nnow=$1\necho "v=$(( now - 0 ))"\necho next', 'set -u\necho "v=$(( $1 - 0 ))"\necho next']) {
      const r = bash(script, {}, [v]).out;
      const want = r === "" ? "EUNBOUND" : r === "next\n" ? "EARITH" : r.split("\n")[0];
      // `1+1` is an expression, out of the one-operand model (named in the header).
      if (v === "1+1") expect(want).toBe("v=2");
      else expect({ v, got: got[i] }).toEqual({ v, got: want });
    }
  });
  expect(got[vals.indexOf("1+1")]).toBe("EARITH");
}, 60000);

function dateStub(out: string): string {
  const d = dir("date");
  exe(join(d, "date"), `#!/bin/sh\nprintf '${out}'\nprintf 'datestub-err\\n' >&2\n`);
  return d;
}

test("nowRaw reads `$(ac_now)`: date's stdout, NULs dropped, trailing LFs stripped, its stderr passed through", () => {
  for (const out of ["1791043297\\n", "garbage\\n\\n", "", " 77 \\n", "a\\000b\\n", "12\\r\\n"]) {
    const d = dateStub(out);
    const env = { PATH: `${d}:${process.env.PATH}` };
    const want = bash('. "$0/ac-lib.sh"; x="$(ac_now)"; printf "[%s]" "$x"', env);
    expect({ out, ...twin(`say("[" + L.nowRaw() + "]")`, env) }).toEqual({ out, ...want });
  }
}, 30000);

// ac_watcher_down's answer as a caller under `set -uo pipefail` sees it: down,
// up, an evaluation error (the whole `if` discarded - the guard reads it
// as up) or set -u's abort (nothing after it runs).
const DOWN = 'set -uo pipefail; . "$0/ac-lib.sh"; . "$0/ac-wake-lib.sh"\nif ac_watcher_down "$1" "$2"; then echo down; else echo up; fi\necho end';
function bashDown(sd: string, scope: string, env: Record<string, string>): { answer: string; err: string } {
  const r = bash(DOWN, env, [sd, scope]);
  const answer = r.out === "" ? "EUNBOUND" : r.out === "end\n" ? "up" : r.out.split("\n")[0]!;
  return { answer, err: r.err };
}
function twinDown(sd: string, scope: string, env: Record<string, string>): { answer: string; err: string } {
  const r = twin(`try { say(await L.watcherDown(${JSON.stringify(sd)}, ${JSON.stringify(scope)}) ? "down" : "up"); } catch (e) { say(e.code); }`, env);
  return { answer: r.out, err: r.err };
}

test("watcherDown answers ac_watcher_down: the supervision set, the scope's beacon, the grace's [ -gt ] grammar, the clock's $(( )) reading", () => {
  const T = 1000000;
  const stub = dir("clock");
  exe(join(stub, "date"), `#!/bin/sh\nprintf '%s\\n' "\${CLOCK:-${T}}"\n`);
  const path = `${stub}:${process.env.PATH}`;
  const sd = join(dir("wd"), "state");
  mkdirSync(sd);
  const metas = (files: Record<string, string>): void => {
    rmSync(sd, { recursive: true, force: true });
    mkdirSync(sd);
    for (const [k, v] of Object.entries(files)) writeFileSync(join(sd, k), v);
  };
  const cases: [Record<string, string>, string, Record<string, string>][] = [
    [{}, "", {}],
    [{ "t.meta": "kind=ship\n" }, "", {}],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 100}\n` }, "", {}],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", {}],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "600" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: " 600 " }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "+600" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "0x10" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "600abc" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "99999999999999999999" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "-5" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "010" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T - 400}\n` }, "", { AC_GUARD_GRACE: "400" }],
    [{ "s.meta": "kind=self\n", "v.meta": "kind=verify-qa\n" }, "", {}],
    [{ "s.meta": "kind=self\r\n" }, "", {}],
    [{ "r.meta": "kind=roomchief\n", ".last-watcher-beat.fam": `${T}\n` }, "fam", {}],
    [{ "r.meta": "kind=roomchief\n", ".last-watcher-beat": `${T}\n` }, "fam", {}],
    [{ "r.meta": "kind=roomchief\n", ".last-watcher-beat": `${T}\n` }, "a.b", {}],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": "0100\n" }, "", {}],
    [{ "t.meta": "kind=ship\n" }, "", { CLOCK: "garbage" }],
    [{ "t.meta": "kind=ship\n" }, "", { CLOCK: "12abc" }],
    [{ "t.meta": "kind=ship\n" }, "", { CLOCK: "" }],
    [{ "t.meta": "kind=ship\n" }, "", { CLOCK: "0400" }],
    [{ "t.meta": "kind=ship\n" }, "", { CLOCK: "0499" }],
    [{ "t.meta": "kind=ship\n", ".last-watcher-beat": `${T}\n` }, "", { EPOCHSECONDS: `${T + 400}` }],
    [{ "t.meta": "kind=ship\n" }, "", { EPOCHSECONDS: "garbage" }],
    [{ "t.meta": "kind=ship\n" }, "", { EPOCHSECONDS: "12abc" }],
  ];
  for (const [files, scope, extra] of cases) {
    metas(files);
    const env = { PATH: path, ...extra };
    const want = bashDown(sd, scope, env);
    // bash's own lines (`integer expression expected`, the arithmetic error,
    // `unbound variable`) are shell noise the twin does not print.
    expect({ files, scope, extra, ...twinDown(sd, scope, env) }).toEqual({ files, scope, extra, answer: want.answer, err: "" });
  }
  // awk's own lines pass through on both: a directory named *.meta aborts it.
  metas({ "a.meta": "kind=ship\n" });
  mkdirSync(join(sd, "b.meta"));
  const want = bashDown(sd, "", { PATH: path });
  expect(want.err).toContain("awk: i/o error occurred on");
  expect(twinDown(sd, "", { PATH: path })).toEqual(want);
}, 120000);

test("wakePending answers ac_wake_pending: the scope's own spool, a malformed scope the fleet's, a file-spool empty", () => {
  const sd = join(dir("wp"), "state");
  mkdirSync(join(sd, ".wake-spool"), { recursive: true });
  mkdirSync(join(sd, ".wake-spool.fam"), { recursive: true });
  writeFileSync(join(sd, ".wake-spool.fam", "r"), "x");
  writeFileSync(join(sd, ".wake-spool.file"), "x");
  mkdirSync(join(sd, ".wake-spool.dot"));
  writeFileSync(join(sd, ".wake-spool.dot", ".r"), "x");
  for (const scope of ["", "fam", "a.b", "file", "dot", "none"]) {
    const want = bash('. "$0/ac-lib.sh"; . "$0/ac-wake-lib.sh"; ac_wake_pending "$1" "$2" && printf yes || printf no', {}, [sd, scope]).out;
    expect({ scope, got: twin(`say(L.wakePending(${JSON.stringify(sd)}, ${JSON.stringify(scope)}) ? "yes" : "no")`, {}).out }).toEqual({ scope, got: want });
  }
  writeFileSync(join(sd, ".wake-spool", "r"), "x");
  expect(twin(`say(L.wakePending(${JSON.stringify(sd)}, "a.b") ? "yes" : "no")`, {}).out).toBe("yes");
}, 30000);

// A herdr standing in for the real one, logging argv and HERDR_SESSION:
// `pane get <p>` answers while <d>/win-<p> exists, `pane list` fails while
// <d>/list-fails exists, `status server` reports <d>/stopped.
function fakeHerdr(): string {
  const d = dir("herdr");
  mkdirSync(join(d, "bin"));
  exe(
    join(d, "bin", "herdr"),
    `#!/bin/sh
d="${d}"
printf 'herdr %s [%s]\\n' "$*" "\${HERDR_SESSION:-}" >>"$d/log"
case "$1 $2" in
  "pane get") [ -e "$d/win-$3" ] ;;
  "pane list") [ ! -e "$d/list-fails" ] || exit 1; printf '{"result":{"panes":[]}}\\n' ;;
  "status server") printf '{"running":%s}\\n' "$( [ -e "$d/stopped" ] && echo false || echo true )" ;;
  *) exit 2 ;;
esac
`,
  );
  exe(
    join(d, "bin", "orca"),
    `#!/bin/sh
d="${d}"
printf 'orca %s\\n' "$*" >>"$d/log"
case "$1 $2" in
  "terminal show") printf '{"ok":true,"result":{"terminal":{"connected":%s}}}\\n' "$( [ -e "$d/win-$4" ] && echo true || echo false )" ;;
  *) printf '{"ok":true}\\n' ;;
esac
`,
  );
  return d;
}

const WAKE = '. "$0/ac-lib.sh"; . "$0/ac-backend.sh"; . "$0/ac-wake-lib.sh"';

test("roomchiefLive answers ac_roomchief_live through backendCall: no meta no call, the meta's backend for the one call, only rc 0 live", () => {
  const fh = fakeHerdr();
  const home = dir("rl");
  const sd = join(home, "state");
  mkdirSync(sd);
  const env = { AC_HOME: home, PATH: `${fh}/bin:${process.env.PATH}` };
  const fams: [string, string, string][] = [
    ["nometa", "", ""],
    ["live", "backend=herdr\n", "plive t\n"],
    ["dead", "kind=roomchief\n", "pdead t\n"],
    ["nopane", "backend=herdr\n", ""],
    ["orca", "backend=orca\n", "horca t\n"],
    ["orcadead", "backend=orca\n", "hgone t\n"],
    ["tmux", "backend=tmux\n", "ptmux t\n"],
    ["cr", "backend=herdr\r\n", "pcr t\n"],
  ];
  for (const [fam, meta, pane] of fams) {
    if (meta) writeFileSync(join(sd, `${fam}-chief.meta`), meta);
    if (pane) writeFileSync(join(sd, `.pane-${fam}-chief`), pane);
  }
  writeFileSync(join(fh, "win-plive"), "");
  writeFileSync(join(fh, "win-horca"), "");
  writeFileSync(join(fh, "win-ptmux"), "");
  writeFileSync(join(fh, "win-pcr"), "");
  for (const extra of [{}, { AC_HERDR_SESSION: "s1" }, { AC_BACKEND: "orca" }]) {
    for (const [fam] of fams) {
      rmSync(join(fh, "log"), { force: true });
      const want = bash(`${WAKE}; ac_roomchief_live "$1" "$2" && printf live || printf gone`, { ...env, ...extra }, [sd, fam]).out;
      const wantLog = readLog(fh);
      rmSync(join(fh, "log"), { force: true });
      const got = twin(`say(L.roomchiefLive(${JSON.stringify(sd)}, ${JSON.stringify(fam)}) ? "live" : "gone"); say(process.env.AC_BACKEND === undefined ? "" : "|" + process.env.AC_BACKEND)`, { ...env, ...extra });
      const backend = "AC_BACKEND" in extra ? `|${(extra as { AC_BACKEND: string }).AC_BACKEND}` : "";
      expect({ fam, extra, out: got.out, log: readLog(fh) }).toEqual({ fam, extra, out: want + backend, log: wantLog });
    }
  }
}, 120000);

function readLog(fh: string): string {
  try {
    return readFileSync(join(fh, "log"), "latin1");
  } catch {
    return "";
  }
}

test("wakeOrphanPending answers ac_wake_orphan_pending: family spools in byte order, a live family skipped, an orphan's record pending", () => {
  const fh = fakeHerdr();
  const home = dir("op");
  const sd = join(home, "state");
  mkdirSync(sd);
  const env = { AC_HOME: home, PATH: `${fh}/bin:${process.env.PATH}` };
  const spool = (fam: string, rec: boolean): void => {
    mkdirSync(join(sd, `.wake-spool.${fam}`), { recursive: true });
    if (rec) writeFileSync(join(sd, `.wake-spool.${fam}`, "1.1.000000"), "x");
  };
  const chief = (fam: string, live: boolean): void => {
    writeFileSync(join(sd, `${fam}-chief.meta`), "backend=herdr\n");
    writeFileSync(join(sd, `.pane-${fam}-chief`), `p${fam} t\n`);
    if (live) writeFileSync(join(fh, `win-p${fam}`), "");
    else rmSync(join(fh, `win-p${fam}`), { force: true });
  };
  const same = (): string => {
    rmSync(join(fh, "log"), { force: true });
    const want = bash(`${WAKE}; ac_wake_orphan_pending "$1" && printf yes || printf no`, env, [sd]).out;
    const wantLog = readLog(fh);
    rmSync(join(fh, "log"), { force: true });
    expect({ out: twin(`say(L.wakeOrphanPending(${JSON.stringify(sd)}) ? "yes" : "no")`, env).out, log: readLog(fh) }).toEqual({ out: want, log: wantLog });
    return want;
  };
  expect(same()).toBe("no");
  // The answering family sorts LAST in every row: the bash's liveness
  // producer runs ahead of its reader and outlives it, so a call log past the
  // answer is a race (named in src/guard.ts).
  spool("b", true);
  chief("b", true);
  spool("a", false);
  chief("a", false);
  expect(same()).toBe("no");
  chief("b", false);
  expect(same()).toBe("yes");
  chief("b", true);
  spool("z", true);
  expect(same()).toBe("yes");
  mkdirSync(join(sd, ".wake-spool.dotted.x"));
  writeFileSync(join(sd, ".wake-spool.dotted.x", "r"), "x");
  writeFileSync(join(sd, ".wake-spool.file"), "x");
  symlinkSync(join(sd, ".wake-spool.z"), join(sd, ".wake-spool.zlink"));
  rmSync(join(sd, ".wake-spool.z"), { recursive: true });
  expect(same()).toBe("no");
  mkdirSync(join(sd, ".wake-spool.z"));
  writeFileSync(join(sd, ".wake-spool.z", "r"), "x");
  expect(same()).toBe("yes");
}, 120000);

test("repoRoot answers ac_repo_root: the main worktree's root from a linked worktree, a subdirectory or a bare repo's parent, null outside", () => {
  const base = dir("rr");
  const g = (args: string[]): void => {
    Bun.spawnSync(["git", ...args], { stdout: "ignore", stderr: "ignore" });
  };
  g(["init", "-q", "-b", "main", join(base, "repo")]);
  g(["-C", join(base, "repo"), "-c", "user.email=a@b", "-c", "user.name=n", "commit", "-q", "--allow-empty", "-m", "i"]);
  g(["-C", join(base, "repo"), "worktree", "add", "-q", "--detach", join(base, "wt")]);
  g(["init", "-q", "--bare", join(base, "bare.git")]);
  mkdirSync(join(base, "repo", "sub"));
  symlinkSync(join(base, "repo"), join(base, "link"));
  const r = join(base, "repo");
  for (const d of [r, join(r, "sub"), `${r}/`, join(base, "wt"), join(base, "bare.git"), join(base, "link"), join(base, "nope"), base]) {
    const want = bash('. "$0/ac-lib.sh"; r="$(ac_repo_root "$1")" && printf "[%s]" "$r" || printf null', {}, [d]).out;
    expect({ d, got: twin(`const r = L.repoRoot(${JSON.stringify(d)}); say(r === null ? "null" : "[" + r + "]")`, {}).out }).toEqual({ d, got: want });
  }
}, 30000);

test("backendName(true) is ac-backend.sh sourced with stderr dropped and errexit asleep: silent, exit 1 on a bad name, an unreadable rung read as none", () => {
  const SOURCE = 'set -uo pipefail; . "$0/ac-lib.sh" 2>/dev/null || exit 0; . "$0/ac-backend.sh" 2>/dev/null || exit 0; printf "ok:%s" "$(ac_backend 2>/dev/null)"';
  const fs = dir("fs");
  mkdirSync(join(fs, "state"));
  mkdirSync(join(fs, "config"));
  const h = dir("bh");
  mkdirSync(join(h, "config"));
  const cases: Record<string, string>[] = [
    {},
    { AC_BACKEND: "bogus" },
    { AC_BACKEND: "orca" },
    { AC_HOME: h },
    { AC_HOME: join(W, "missing") },
    { AC_FLEET_STATE: join(fs, "state") },
  ];
  const run = (env: Record<string, string>): void => {
    const want = bash(SOURCE, env);
    expect({ env, ...twin(`say("ok:" + L.backendName(true))`, env) }).toEqual({ env, ...want });
  };
  for (const env of cases) run(env);
  writeFileSync(join(h, "config", "backend"), "tmux\n");
  run({ AC_HOME: h });
  writeFileSync(join(fs, "config", "backend"), "wezterm x\n");
  run({ AC_FLEET_STATE: join(fs, "state") });
  if (process.getuid?.() !== 0) {
    chmodSync(join(fs, "config", "backend"), 0o000);
    writeFileSync(join(h, "config", "backend"), "orca\n");
    chmodSync(join(h, "config", "backend"), 0o000);
    run({ AC_FLEET_STATE: join(fs, "state") });
    run({ AC_HOME: h });
    chmodSync(join(fs, "config", "backend"), 0o644);
    chmodSync(join(h, "config", "backend"), 0o644);
  }
}, 60000);
