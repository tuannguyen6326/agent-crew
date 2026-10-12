// remote.test.ts - the lib.ts twins src/remote.ts introduced (nowRaw, vnTs,
// roomPendingLines, childrenIgnoreInt) and its own byte-level readers
// (quoteOffender, the META SET key match, the family-keyed stamp read, the
// ack arithmetic), each held to the bash it replaced; and the four process
// mechanics its header names, each pinned against a direct bash probe of the
// same shape. The CLI contract itself is tests/sh/ac-remote.test.sh's, whose
// differential leg runs the frozen bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { childrenIgnoreInt, nowRaw, roomPendingLines, spawnShellSync, vnTs } from "../../src/lib.ts";
import { arithConst, hookArgv, keyOpens, metaValueAwk, quoteOffender, testInt } from "../../src/remote.ts";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-remote-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));
let n = 0;
const file = (bytes: Buffer | string): string => {
  const f = join(W, `f${n++}`);
  writeFileSync(f, bytes);
  return f;
};
const L = (s: string): Buffer => Buffer.from(s, "latin1");

function bash(script: string, args: string[], env: Record<string, string> = {}): { out: string; rc: number } {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, "_", ...args], { env: { PATH: process.env.PATH!, ...env }, stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString("latin1"), rc: r.exitCode ?? -1 };
}

// The bash original's own text of a function, frozen with it.
function frozen(name: string): string {
  const lines = readFileSync(join(ROOT, "tests", "fixtures", "ac-remote.sh"), "latin1").split("\n");
  const start = lines.indexOf(`${name}() {`);
  return lines.slice(start, lines.indexOf("}", start) + 1).join("\n");
}

const STUBS = join(W, "stubs");
mkdirSync(STUBS);
writeFileSync(join(STUBS, "date"), '#!/bin/sh\n[ -z "$DATE_FAIL" ] || exit 1\nprintf \'%s|%s\\n\\n\' "${TZ-unset}" "$*"\n');
chmodSync(join(STUBS, "date"), 0o755);

// A bun child, so EPOCHSECONDS and PATH are the process's own, as the entry's.
function ts(expr: string, env: Record<string, string>): string {
  const body = `const L = await import(${JSON.stringify(join(ROOT, "src", "lib.ts"))}); process.stdout.write(Buffer.from(String(${expr}), "latin1"));`;
  return Bun.spawnSync([process.execPath, "-e", body], { env: { PATH: process.env.PATH!, ...env }, stdout: "pipe" }).stdout.toString("latin1");
}

test("nowRaw is ac_now's capture: EPOCHSECONDS or date's stdout less trailing LFs, empty when date fails", () => {
  for (const env of [{ EPOCHSECONDS: "5" }, { EPOCHSECONDS: "5\n\n" }, { EPOCHSECONDS: "\n" }, { PATH: `${STUBS}:${process.env.PATH}` }, { PATH: `${STUBS}:${process.env.PATH}`, DATE_FAIL: "1" }]) {
    const sh = bash(`. "$1/ac-lib.sh"; x="$(ac_now)"; printf '%s' "$x"`, [BIN], env);
    expect(ts("L.nowRaw()", env)).toBe(sh.out);
  }
  expect(typeof nowRaw()).toBe("string");
});

test("vnTs is ac_vn_ts: date spawned with TZ=Asia/Ho_Chi_Minh for it alone", () => {
  const env = { PATH: `${STUBS}:${process.env.PATH}` };
  const sh = bash(`. "$1/ac-lib.sh"; x="$(ac_vn_ts)"; printf '%s' "$x"`, [BIN], env);
  expect(sh.out).toBe("Asia/Ho_Chi_Minh|+%Y-%m-%d %H:%M");
  expect(ts("L.vnTs().stamp", env)).toBe(sh.out);
  expect(typeof vnTs().stamp).toBe("string");
});

const PENDING_LINES = `ac_room_pending_lines() {
  ac_room_scan '^- \\[[^]]*\\] [^>]*> (GATE|ASK|DECIDED)' '
    /^- \\[[^]]*\\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \\([^)]*\\))?:/ { open[++n] = $0 }
    /^- \\[[^]]*\\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \\([^)]*\\))?:/ { if (settled < n) settled++ }
    END { for (i = settled + 1; i <= n; i++) print open[i] }
  ' "$1"
}`;

test("roomPendingLines is the retired ac_room_pending_lines, room for room", () => {
  const rooms = [
    "- [t] c> GATE: one\n- [t] c> ASK (1 of 2): two\n- [t] c> DECIDED: ok\n- [t] c> ASK: three\n",
    "- [t] c> GATE: one\n- [t] c> DECIDED a.b: a dotted word settles nothing\n",
    "- [t] c> relay > GATE: quoted\n- [t] c> GATE-LOOPED: receipt\n- [t] c> DECIDED: nothing open\n- [t] c> GATE: real",
    "- [t] c> GATE: cut\0 after\n- [t] c> ASK: cr\r\n- [\xe9] c> GATE: a latin1 stamp\n",
    "",
    "no grammar here\n",
  ];
  for (const text of rooms) {
    const f = file(L(text));
    const sh = bash(`. "$1/ac-lib.sh"; . "$1/ac-wake-lib.sh"; ${PENDING_LINES}; x="$(ac_room_pending_lines "$2" 2>/dev/null)" || exit 3; printf '%s' "$x"`, [BIN, f], { LC_ALL: "en_US.UTF-8" });
    expect(sh.rc).toBe(0);
    expect(roomPendingLines(f)).toBe(sh.out);
  }
  const shut = file("- [t] c> GATE: x\n");
  chmodSync(shut, 0);
  expect(bash(`. "$1/ac-lib.sh"; . "$1/ac-wake-lib.sh"; ${PENDING_LINES}; ac_room_pending_lines "$2" 2>/dev/null`, [BIN, shut]).rc).not.toBe(0);
  expect(roomPendingLines(shut)).toBeNull();
  expect(roomPendingLines(join(W, "absent"))).toBe("");
});

test("quoteOffender is quote_offender: 60 bytes under C, 60 characters under UTF-8 (an invalid byte one)", () => {
  const texts = ["short", "x".repeat(60), "x".repeat(61), "two\nlines", "\xc3\xa9".repeat(61), `${"\xc3\xa9".repeat(59)}ab\xe9c`, `${"x".repeat(59)}\xe2\x82\xac`, "\xed\xa0\x80".repeat(30), ""];
  const saved = process.env.LC_ALL;
  try {
    for (const loc of ["C", "en_US.UTF-8"]) {
      process.env.LC_ALL = loc;
      for (const t of texts) {
        const sh = bash(`${frozen("quote_offender")}; quote_offender "$(cat "$1")"`, [file(L(t))], { LC_ALL: loc });
        expect(L(quoteOffender(t))).toEqual(L(sh.out));
      }
    }
  } finally {
    if (saved === undefined) delete process.env.LC_ALL;
    else process.env.LC_ALL = saved;
  }
});

test("the ack arithmetic is the shell's: `[ -ge ]` decimal, `$(( ))` octal on a leading 0, 64-bit wrap", () => {
  for (const v of ["0", "30", "010", "08", "007", "99999999999999999999", "9223372036854775808", "9223372036854775807"]) {
    const t = bash(`[ "$1" -ge 0 ] 2>/dev/null; rc=$?; [ "$rc" = 2 ] && echo err || echo ok`, [v]).out.trim();
    expect(testInt(v) === null ? "err" : "ok").toBe(t);
    const a = bash(`echo "$(( $1 - 0 ))"`, [v]);
    expect(arithConst(v) === null ? "fatal" : String(arithConst(v))).toBe(a.rc === 0 ? a.out.trim() : "fatal");
  }
});

test("the META SET key match is `grep -v \"^<key>=\"`: `.` one byte under C, one valid character under UTF-8", () => {
  const lines = ["a.b=1", "aXb=2", "a\xc3\xa9b=3", "a\xe9b=4", "ab=5", "a.bc=6", "a.b", "remote_request_ts=7", "remote_request=8"];
  for (const loc of ["C", "en_US.UTF-8"]) {
    for (const key of ["a.b", "remote_request"]) {
      for (const line of lines) {
        const kept = bash(`grep -v "^$2=" "$1"`, [file(L(`${line}\n`)), key], { LC_ALL: loc }).out !== "";
        expect(keyOpens(L(line), key, loc !== "C")).toBe(!kept);
      }
    }
  }
});

test("the family-keyed stamp read is ac_meta_get: awk's `$1==k`, numeric when both sides look like numbers", () => {
  const stamp = file("7=seven\n1.0=onedot\nfam=f\nnan=x\n");
  for (const key of ["07", "7", "1", "1.0", "1e0", "0x7", "fam", "nan", "inf", "absent"]) {
    const sh = bash(`. "$1/ac-lib.sh"; ac_meta_get "$2" "$3"`, [BIN, stamp, key]);
    expect(metaValueAwk(stamp, key)).toBe(sh.out.replace(/\n$/, ""));
  }
});

// --- the four mechanics, each against the bash shape it reproduces ---------

const hookDir = join(W, "hooks");
mkdirSync(hookDir);
function hook(name: string, body: string): string {
  const f = join(hookDir, name);
  writeFileSync(f, `#!/bin/sh\n${body}\n`);
  chmodSync(f, 0o755);
  return f;
}
function home(): string {
  const h = join(W, `home${n++}`);
  mkdirSync(join(h, "config"), { recursive: true });
  mkdirSync(join(h, "state", "remote-inbox"), { recursive: true });
  return h;
}
function entry(h: string, args: string[], stdin = ""): { out: string; err: string; rc: number; ms: number } {
  const t0 = Date.now();
  const r = Bun.spawnSync([join(BIN, "ac-remote.sh"), ...args], { env: { PATH: process.env.PATH!, AC_HOME: h }, stdin: Buffer.from(stdin), stdout: "pipe", stderr: "pipe" });
  return { out: r.stdout.toString(), err: r.stderr.toString(), rc: r.exitCode ?? -1, ms: Date.now() - t0 };
}

test("1. a capture reads to EOF as `$(...)` did: an orphan holding stdout holds it, where a spawnSync returns at the exit", () => {
  const orphan = hook("orphan", '(sleep 1; printf "1800.1\\n") & exit 0');
  const sh = bash(`out="$("$1")"; printf '%s' "$out"`, [orphan]);
  expect(sh.out).toBe("1800.1");
  const naive = Bun.spawnSync([orphan], { stdout: "pipe" });
  expect(naive.stdout.toString()).toBe("");
  const h = home();
  writeFileSync(join(h, "config", "remote-reply"), readFileSync(orphan));
  chmodSync(join(h, "config", "remote-reply"), 0o755);
  const r = entry(h, ["thread-post", "fam"], "text\n");
  expect(r.out).toBe("posted fam (1800.1)\n");
  expect(r.ms).toBeGreaterThanOrEqual(900);
}, 30000);

test("2. a child started while the ignore is held ignores SIGINT, as one started under `trap '' INT` did; Bun's default resets it", () => {
  const selfInt = ["/bin/sh", "-c", 'kill -INT $$; echo survived'];
  expect(bash(`trap '' INT; "$@"`, selfInt).out).toBe("survived\n");
  expect(Bun.spawnSync(selfInt, { stdout: "pipe" }).signalCode).toBe("SIGINT");
  childrenIgnoreInt(true);
  try {
    expect(spawnShellSync(selfInt, { stdout: "pipe" }).stdout.toString()).toBe("survived\n");
  } finally {
    childrenIgnoreInt(false);
  }
  expect(spawnShellSync(selfInt, { stdout: "pipe" }).signalCode).toBe("SIGINT");
});

test("3. a hook's added names reach it through env(1) - a hook path holding `=` included, which env(1) alone misreads", () => {
  const h = join(W, "a=b", `home${n++}`);
  mkdirSync(join(h, "config"), { recursive: true });
  mkdirSync(join(h, "state", "remote-inbox"), { recursive: true });
  const reply = join(h, "config", "remote-reply");
  writeFileSync(reply, '#!/bin/sh\nprintf "%s|%s|" "$AC_REMOTE_RID" "$AC_REMOTE_THREAD"; cat\n');
  chmodSync(reply, 0o755);
  expect(bash(`X=1 "$1"`, [reply]).out).toBe("||");
  expect(Bun.spawnSync(["/usr/bin/env", "X=1", reply], { stdout: "pipe" }).stdout.toString()).not.toContain("||");
  writeFileSync(join(h, "state", "remote-inbox", "r1.json"), '{"rid":"r1","text":"t","author":"a","thread":"café"}\n');
  const r = entry(h, ["reply", "r1"], "answer\n");
  expect(r.out).toBe("r1|café|answer\nreplied r1\n");
});

test("4. the ack hook leads its own process group, as a job backgrounded under `set -m` did", () => {
  const probe = 'printf "%s %s\\n" "$$" "$(ps -o pgid= -p $$ | tr -d " ")"';
  const leader = (line: string): boolean => {
    const [pid, pgid] = line.trim().split(" ");
    return pid === pgid;
  };
  expect(leader(bash(`set -m; "$1" & wait $!`, [hook("grp", probe)]).out)).toBe(true);
  const h = home();
  const log = join(W, `ack${n++}.log`);
  writeFileSync(join(h, "config", "remote-ack"), `#!/bin/sh\n${probe} >"${log}"\n`);
  chmodSync(join(h, "config", "remote-ack"), 0o755);
  writeFileSync(join(h, "state", "remote-inbox", "r1.json"), '{"rid":"r1","text":"t","author":"a","thread":"1"}\n');
  expect(entry(h, ["ack", "r1", "done"]).out).toBe("acked r1 (done)\n");
  expect(leader(readFileSync(log, "utf8"))).toBe(true);
}, 30000);

// /bin/sh is bash in POSIX mode here and dash on Debian-class hosts, where
// `set +o posix` is an illegal option and `set -m` without a tty complains -
// and an exported BASH_VERSION names no shell at all.
test("the hook launcher's script runs under any /bin/sh: bash already in POSIX mode, and dash when installed", () => {
  const ran = hook("ran", "echo ran");
  const dash = Bun.which("dash");
  const shells = [["/bin/bash", "--posix"], ...(dash ? [[dash]] : [])];
  expect(hookArgv(ran)[0]).toBe("/bin/sh");
  for (const sh of shells) {
    for (const version of [undefined, "3.2.57(1)-release"]) {
      const env = { ...process.env };
      if (version !== undefined) env.BASH_VERSION = version;
      for (const monitor of [false, true]) {
        const r = Bun.spawnSync([...sh, "-c", hookArgv(ran, monitor)[2]!, ran], { env, stdout: "pipe", stderr: "pipe" });
        const label = [sh.join(" "), version ?? "", monitor];
        expect([...label, r.exitCode, r.stdout.toString(), r.stderr.toString()]).toEqual([...label, 0, "ran\n", ""]);
      }
    }
  }
});
