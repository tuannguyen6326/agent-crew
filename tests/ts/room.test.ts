// room.test.ts - what src/room.ts brought into src/, held to its bash
// originals: the room twins of src/lib.ts (configReadSoft, backendName,
// taskBackend, vnTs, verbEmoji, shellPrefix, shellSpaceClass, spoolHasRecord)
// against the ac-lib.sh / ac-backend.sh / ac-wake-lib.sh functions they twin,
// roomPending against ac_room_pending, and backendCall against a direct bash
// call of the same driver through a fake herdr. The CLI contract
// itself is tests/sh/ac-room.test.sh's, whose differential leg runs the frozen
// bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const ROOM = join(ROOT, "src", "room.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-room-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

type Run = { code: number | null; out: string; err: string };

// bash over the live libs, the trailing newline of a capture dropped as `$(...)` does.
function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", `. "$B/ac-lib.sh"; ${script}`, "--", ...args], {
    env: { PATH: process.env.PATH!, B: BIN, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

// The twins in a bun child started in ROOT.
function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const R = await import(${JSON.stringify(ROOM)}); const say = (s) => process.stdout.write(Buffer.from(String(s), "latin1")); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, ...env }, stdout: "pipe", stderr: "pipe" },
  );
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

let n = 0;
function home(files: Record<string, string> = {}): string {
  const h = join(W, `h${n++}`);
  for (const sub of ["config", "state", "data"]) mkdirSync(join(h, sub), { recursive: true });
  for (const [rel, body] of Object.entries(files)) {
    mkdirSync(join(h, rel, ".."), { recursive: true });
    writeFileSync(join(h, rel), Buffer.from(body, "latin1"));
  }
  return h;
}

test("configReadSoft reads what ac_config_read reads: the trimmed first line, the default, an unenterable home's default, an unreadable file's head line and empty answer", () => {
  const h = home({ "config/a": "  x y \r\nsecond\n", "config/b": "\n" });
  mkdirSync(join(h, "config", "dir"));
  for (const [name, dflt] of [["a", "d"], ["b", "d"], ["none", "d"], ["dir", "d"]]) {
    const want = bash('printf "%s" "$(ac_config_read "$1" "$2")"', { AC_HOME: h }, [name!, dflt!]);
    expect(twin(`say(L.configReadSoft(${JSON.stringify(name)}, ${JSON.stringify(dflt)}))`, { AC_HOME: h }).out).toBe(want.out);
  }
  expect(twin(`say(L.configReadSoft("a", "dflt"))`, { AC_HOME: join(h, "nope") }).out).toBe("dflt");
  expect(twin(`say(L.configReadSoft("a", "dflt"))`, {}).out).toBe("dflt");
  if (process.getuid?.() !== 0) {
    chmodSync(join(h, "config", "a"), 0o000);
    const want = bash('printf "%s" "$(ac_config_read a dflt)"', { AC_HOME: h });
    const got = twin(`say(L.configReadSoft("a", "dflt"))`, { AC_HOME: h });
    chmodSync(join(h, "config", "a"), 0o644);
    expect(got).toEqual({ code: 0, out: "", err: want.err });
    expect(want.err).toContain("Permission denied");
  }
}, 30000);

// ac_backend as ac-backend.sh defines it, lifted out so a bogus name is judged
// by the function rather than by the file's own source-time call.
const AC_BACKEND_FN = `eval "$(sed -n '/^ac_backend() {/,/^}/p' "$0/ac-backend.sh")"; ac_backend`;

test("backendName walks ac_backend's ladder and refuses as it does", () => {
  const fsHome = home({ "config/backend": "orca\tjunk\n" });
  mkdirSync(join(fsHome, "state"), { recursive: true });
  const h = home({ "config/backend": " herdr \n" });
  const bad = home({ "config/backend": "tmux\n" });
  const cases: Record<string, string>[] = [
    {},
    { AC_HOME: h },
    { AC_HOME: bad },
    { AC_HOME: bad, AC_BACKEND: "orca" },
    { AC_BACKEND: "Herdr" },
    { AC_FLEET_STATE: `${fsHome}/state/` },
    { AC_FLEET_STATE: `${fsHome}/state` },
    { AC_FLEET_STATE: join(W, "no", "state") },
    { AC_HOME: join(W, "nope") },
  ];
  for (const env of cases) {
    const r = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; ${AC_BACKEND_FN}`, BIN], { env: { PATH: process.env.PATH!, ...env }, stdout: "pipe", stderr: "pipe" });
    const want = { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString().replace(/^.*: cd: .*\n/gm, "") };
    expect({ env, ...twin(`say(L.backendName() + "\\n")`, env) }).toEqual({ env, ...want });
  }
}, 30000);

test("taskBackend reads ac_task_backend's answer, the unreadable meta's warning included", () => {
  const h = home({ "state/a.meta": "backend=orca\n", "state/b.meta": "kind=x\n", "state/c.meta": "backend=\nbackend=orca\nbackend=\n" });
  const ids = ["a", "b", "c", "none"];
  if (process.getuid?.() !== 0) {
    writeFileSync(join(h, "state", "d.meta"), "backend=orca\n");
    chmodSync(join(h, "state", "d.meta"), 0o000);
    ids.push("d");
  }
  for (const id of ids) {
    const want = bash('printf "%s" "$(ac_task_backend "$1")"', { AC_HOME: h }, [id]);
    expect({ id, ...twin(`say(L.taskBackend(${JSON.stringify(id)}))`, { AC_HOME: h }) }).toEqual({ id, code: 0, out: want.out, err: want.err });
  }
}, 30000);

test("vnTs runs ac_vn_ts's date - TZ added, the format, the capture - and reports its status", () => {
  const stub = join(W, "datestub");
  mkdirSync(stub, { recursive: true });
  writeFileSync(join(stub, "date"), '#!/bin/sh\nprintf "%s|%s\\n\\n" "$TZ" "$*"\nexit "${DATE_RC:-0}"\n');
  chmodSync(join(stub, "date"), 0o755);
  const path = `${stub}:${process.env.PATH}`;
  const want = Bun.spawnSync(["/bin/bash", "-c", `. "$0/ac-lib.sh"; x="$(ac_vn_ts)"; printf "%s|%s" "$?" "$x"`, BIN], { env: { PATH: path }, stdout: "pipe" }).stdout.toString();
  expect(twin(`const v = L.vnTs(); say(v.status + "|" + v.stamp)`, { PATH: path }).out).toBe(want);
  expect(want).toBe("0|Asia/Ho_Chi_Minh|+%Y-%m-%d %H:%M");
  const failed = twin(`const v = L.vnTs(); say(v.status + "|" + v.stamp)`, { PATH: path, DATE_RC: "5" }).out;
  expect(failed).toBe("5|Asia/Ho_Chi_Minh|+%Y-%m-%d %H:%M");
}, 30000);

test("verbEmoji answers ac_verb_emoji for every arm and an unknown verb", () => {
  const verbs = ["ORDER", "TRIAGE", "GATE-PASSED (auto)", "SELF-APPROVED", "GATE", "GATE-LOOPED", "ASK", "DECIDED", "LANDED", "DONE", "UNLANDABLE", "HANDBACK", "HANDBACK-REFUSED", "PROMOTED", "DEMOTED", "CLOSED", "START", "FAILED", "BLOCKED", "note", "", "gate"];
  const want = bash('for v in "$@"; do ac_verb_emoji "$v"; printf "\\n"; done', {}, verbs).out;
  expect(twin(`say(${JSON.stringify(verbs)}.map((v) => Buffer.from(L.verbEmoji(v), "utf8").toString("latin1")).join("\\n") + "\\n")`, {}).out).toBe(want);
}, 30000);

test("shellPrefix cuts as bash 3.2's ${s:0:n} does, by character under UTF-8 and by byte under C", () => {
  const samples = [
    "plain ascii text",
    "\xc4\x90\xc3\x83 vi\xe1\xbb\x87t",
    "\xf0\x9f\x9a\xa6 emoji \xe2\x98\x91\xef\xb8\x8f",
    "caf\xe9 latin1 byte",
    "\xc0\x80 overlong \xe0\x80\x80",
    "\xed\xa0\x80 surrogate",
    "\xf8\x88\x80\x80\x80 five-byte",
    "\xf4\x90\x80\x80 past U+10FFFF",
    "cut at the end \xe1\x80",
    "\xc3 lone lead, \x80 lone tail",
  ];
  // argv would carry the samples UTF-8 encoded; a file carries their bytes.
  const f = join(W, "sample");
  for (const loc of ["C", "en_US.UTF-8"]) {
    for (const s of samples) {
      writeFileSync(f, Buffer.from(s, "latin1"));
      for (const k of [0, 1, 2, 3, 5, 8]) {
        const want = bash('s="$(cat "$1")"; printf "%s" "${s:0:$2}"', { LC_ALL: loc }, [f, String(k)]);
        const got = twin(`say(L.shellPrefix(${JSON.stringify(s)}, ${k}))`, { LC_ALL: loc });
        expect({ loc, s, k, out: got.out }).toEqual({ loc, s, k, out: want.out });
      }
    }
  }
}, 60000);

test("shellSpaceClass removes what ${g//[[:space:]]/} removes, per locale", () => {
  const chars = [" ", "\t", "\n", "\v", "\f", "\r", "\u00a0", "\u2003", "\u3000", "\u0085", "\ufeff", "\u200b", "x"];
  for (const loc of ["C", "en_US.UTF-8"]) {
    for (const c of chars) {
      const s = `a${c}b`;
      const want = bash('g="${1//[[:space:]]/}"; printf "%s" "$g"', { LC_ALL: loc }, [s]).out;
      const got = twin(`say(Buffer.from(${JSON.stringify(s)}.replace(L.shellSpaceClass(), ""), "utf8").toString("latin1"))`, { LC_ALL: loc }).out;
      expect({ loc, c: c.codePointAt(0), got }).toEqual({ loc, c: c.codePointAt(0), got: want });
    }
  }
}, 60000);

test("spoolHasRecord answers ac_spool_has_record over the spool's glob", () => {
  const sp = (name: string): string => {
    const d = join(W, "spools", name);
    mkdirSync(d, { recursive: true });
    return d;
  };
  const empty = sp("empty");
  const dot = sp("dot");
  writeFileSync(join(dot, ".hidden"), "x");
  const rec = sp("rec");
  writeFileSync(join(rec, "1.2.000000"), "x");
  const sub = sp("sub");
  mkdirSync(join(sub, "d"));
  const dang = sp("dang");
  symlinkSync(join(W, "nowhere"), join(dang, "l"));
  for (const d of [empty, dot, rec, sub, dang, join(W, "spools", "absent")]) {
    const want = bash('. "$B/ac-wake-lib.sh"; ac_spool_has_record "$1"/* && printf yes || printf no', {}, [d]).out;
    expect({ d, got: twin(`say(L.spoolHasRecord(${JSON.stringify(d)}) ? "yes" : "no")`, {}).out }).toEqual({ d, got: want });
  }
}, 30000);

test("roomPending counts what ac_room_pending counts, and an unreadable room throws where it failed", () => {
  const rooms: Record<string, string> = {
    "a/room.md": "- [t] c> GATE: one\n- [t] c> ASK (1 of 2): two\n- [t] c> GATE-LOOPED: no\n- [t] x> DECIDED gates (captain): one\n",
    "b/room.md": "- [t] c> GATE: one\r\n- [t] c> ASK\0: cut\n- [t] c> caf\xe9 \0x\n- [t] c> relayed > DECIDED: no\n",
    "c/room.md": "- [t] c> DECIDED: nothing open\n- [t] c> GATE: open\n",
    "d/room.md": "",
  };
  const h = home(Object.fromEntries(Object.entries(rooms).map(([k, v]) => [`data/${k}`, v])));
  for (const rel of Object.keys(rooms)) {
    const f = join(h, "data", rel);
    const want = bash('. "$B/ac-wake-lib.sh"; ac_room_pending "$1"', { LC_ALL: "en_US.UTF-8" }, [f]).out.trim();
    expect({ rel, got: twin(`say(R.roomPending(${JSON.stringify(f)}))`, {}).out }).toEqual({ rel, got: want });
  }
  if (process.getuid?.() !== 0) {
    const f = join(h, "data", "a", "room.md");
    chmodSync(f, 0o000);
    const want = bash('. "$B/ac-wake-lib.sh"; ac_room_pending "$1"', {}, [f]);
    const got = twin(`try { say(R.roomPending(${JSON.stringify(f)})) } catch { say("threw") }`, {});
    chmodSync(f, 0o644);
    expect(want.code).toBe(2);
    expect(got.out).toBe("threw");
  }
}, 30000);

// A herdr standing in for the real one: `pane get <p>` answers while
// <dir>/<p> exists, `pane list` and `status server` per sentinel files, and
// every call's argv is logged.
function fakeHerdr(): string {
  const d = join(W, `herdr${n++}`);
  mkdirSync(join(d, "bin"), { recursive: true });
  writeFileSync(
    join(d, "bin", "herdr"),
    `#!/bin/sh
d="${d}"
printf 'herdr %s\\n' "$*" >>"$d/log"
case "$1 $2" in
  "pane get") [ -e "$d/$3" ] ;;
  "pane list") [ ! -e "$d/list-fails" ] || exit 1; printf '{"result":{"panes":[]}}\\n' ;;
  "status server") printf '{"running":%s}\\n' "$( [ -e "$d/stopped" ] && echo false || echo true )" ;;
  "tab focus") printf '%s\\n' "$3" >"$d/focused" ;;
  *) exit 2 ;;
esac
`,
  );
  chmodSync(join(d, "bin", "herdr"), 0o755);
  return d;
}

test("backendCall answers what a direct bash call of the driver answers, and tells a refused backend name from a return", () => {
  const fh = fakeHerdr();
  const h = home({ "state/.pane-x": "p1 t1\n", "state/.pane-y": "p2 t2\n" });
  writeFileSync(join(fh, "p1"), "");
  const env = { AC_HOME: h, PATH: `${fh}/bin:${process.env.PATH}` };
  const direct = (fn: string, id: string, extra: Record<string, string> = {}): Run => {
    const r = Bun.spawnSync(["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh"; . "$0/ac-backend.sh"; ${fn} "$1"; printf "|rc=%s" "$?"`, BIN, id], {
      env: { ...env, ...extra },
      stdout: "pipe",
      stderr: "pipe",
    });
    return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
  };
  const twinned = (fn: string, id: string, extra: Record<string, string> = {}): Run =>
    twin(`const r = L.backendCall(${JSON.stringify(fn.replace(/^backend_/, ""))}, [${JSON.stringify(id)}], { stdout: "pipe", stderr: "inherit" }); say(r.out.toString("latin1") + "|rc=" + r.status + (r.exited ? "|exited" : ""))`, { ...env, ...extra });
  for (const [fn, id] of [["backend_window_alive", "x"], ["backend_window_alive", "y"], ["backend_window_alive", "none"], ["backend_target", "x"], ["backend_focus", "x"]]) {
    const want = direct(fn!, id!);
    expect({ fn, id, ...twinned(fn!, id!) }).toEqual({ fn, id, ...want });
  }
  writeFileSync(join(fh, "list-fails"), "");
  expect(twinned("backend_window_alive", "y").out).toBe(direct("backend_window_alive", "y").out);
  expect(twinned("backend_window_alive", "y").out).toBe("|rc=2");
  writeFileSync(join(fh, "stopped"), "");
  expect(twinned("backend_window_alive", "y").out).toBe("|rc=1");
  // A bogus AC_BACKEND is refused by the route (the bash's source-time check
  // exits): an exit, never a return the caller would read as gone.
  const bogus = twinned("backend_window_alive", "x", { AC_BACKEND: "bogus" });
  expect(bogus).toEqual({ code: 0, out: "|rc=1|exited", err: "ERROR: unsupported backend 'bogus' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)\n" });
  const log = Bun.spawnSync(["cat", join(fh, "log")]).stdout.toString();
  expect(log).toContain("herdr pane get p1");
  expect(log).toContain("herdr tab focus t1");
}, 60000);
