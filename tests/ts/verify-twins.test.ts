// verify-twins.test.ts - the `// --- verify twins ---` block of src/lib.ts held
// to the LIVE bash it twins, which bin/ac-verify.sh (and bin/ac-pane-agent.sh)
// keeps calling: verdictJson (ac_verdict_json, V rows), transcriptFinalEpoch
// (ac_transcript_final_epoch, E rows), chiefBusyHold and chiefBusyLeave
// (ac_chief_busy_hold / ac_chief_busy_leave, B and L rows), roomReviewRulings
// (ac_room_review_rulings, R rows), harnessPaneArm (ac_harness_pane_arm, H
// rows) and backendCapturePane (backend_capture_pane, C rows). The entry's
// own contract is tests/sh/ac-verify.test.sh's.
//
// DISPUTED: the implementation of each helper (the bash vs src/lib.ts)
// HELD-CONSTANT: one side root per side and row, seeded alike by the same bash snippet (a home at <side>/home with config/backend, state/ and data/); argv; env (PATH = a stub dir - sleep logging to <side>/sleep.log and returning, a fake herdr and orca logging their argv to <side>/herdr.log and <side>/orca.log - then the host's bun and jq, then /bin and /usr/bin without herdr, orca, docker, codegraph or sleep; LC_ALL=C unless a row names a locale; HOME and TMPDIR the test root; AC_HOME the side's home; SIDE the side root); cwd (the distro root); stdin (/dev/null); stdout, stderr and the status (the side root spelled S, the side process's pid PID) and the side root's world after the call - every path with its mode and bytes - compared whole. A row naming a shell-own line asserts it on the bash side and drops it there before the comparison (the twin writes none: SHELL-OWN STDERR).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const ROOTUSER = process.getuid?.() === 0;
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-verify-twins-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["herdr", "orca", "docker", "codegraph", "jq", "sleep"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
for (const t of ["bun", "jq"]) symlinkSync(Bun.which(t)!, join(TOOLS, t));
const tool = (name: string, body: string): void => {
  writeFileSync(join(TOOLS, name), body);
  chmodSync(join(TOOLS, name), 0o755);
};
tool("sleep", '#!/bin/sh\nprintf \'%s\\n\' "$*" >>"$SIDE/sleep.log"\n');
// herdr's `pane read` prints 300 numbered lines (FAKE_HERDR=fail: exit 1).
tool(
  "herdr",
  '#!/bin/sh\nprintf \'%s\\n\' "$*" >>"$SIDE/herdr.log"\n[ "${FAKE_HERDR:-ok}" = ok ] || exit 1\ncase "$1 $2" in "pane read") i=1; while [ "$i" -le 300 ]; do printf \'line %s\\n\' "$i"; i=$((i + 1)); done ;; esac\n',
);
// orca's `terminal read` answers per FAKE_ORCA: ok, notok (ok:false), notail, fail.
tool(
  "orca",
  '#!/bin/sh\nprintf \'%s\\n\' "$*" >>"$SIDE/orca.log"\ncase "${FAKE_ORCA:-ok}" in\n  ok) printf \'{"ok":true,"result":{"terminal":{"tail":["first row","second row","third row"]}}}\\n\' ;;\n  notok) printf \'{"ok":false,"error":"no such terminal"}\\n\' ;;\n  notail) printf \'{"ok":true,"result":{}}\\n\' ;;\n  *) exit 1 ;;\nesac\n',
);
const PATH = `${TOOLS}:${BASE}`;

type Row = {
  // the bash call after the libs are sourced, its arguments "$@", S the side root
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments, S the side root, out(buf) writes stdout
  twin: string;
  args?: string[];
  // a bash snippet run in the side root before the call, SIDE exported
  seed?: string;
  env?: Record<string, string>;
  // the bash's own shell writes `<file>.sh: line N: ...` lines here
  shell?: boolean;
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
        try {
          walk(p);
        } catch {
          lines.push(`${rel}/<unlistable>`);
        }
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

const LIBS = '. "$0/ac-lib.sh" || exit $?; . "$0/../tests/fixtures/ac-pipeline-lib.sh" || exit $?; . "$0/ac-wake-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?';

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: W, TMPDIR: W, LC_ALL: "C", SIDE: s, AC_HOME: join(s, "home") };
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; ${LIBS}; S="$SIDE"; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [
        process.execPath,
        "-e",
        `import { readFileSync, writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const A = ${JSON.stringify(args)}; const S = process.env.SIDE; const out = (b) => writeSync(1, typeof b === "string" ? Buffer.from(b, "latin1") : b); let rc; try { rc = await (async () => { ${row.twin} })(); } catch (e) { rc = "throw:" + (e.code ?? e.message); } writeSync(1, "|rc=" + rc);`,
      ];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 60000 });
  const pid = String(r.pid);
  const norm = (t: string): string => t.replaceAll(s, "S").replace(new RegExp(`(^|[^0-9a-f])${pid}([^0-9a-f]|$)`, "g"), "$1PID$2");
  return { out: norm(r.stdout.toString("latin1")), err: norm(r.stderr.toString("latin1")), world: norm(world(s)), status: r.exitCode };
}

function same(label: string, row: Row): Side {
  const root = join(W, `r${rows++}`);
  const got: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    mkdirSync(join(s, "home", "config"), { recursive: true });
    mkdirSync(join(s, "home", "state"), { recursive: true });
    mkdirSync(join(s, "home", "data"), { recursive: true });
    writeFileSync(join(s, "home", "config", "backend"), "herdr\n");
    if (row.seed) {
      const r = Bun.spawnSync(["/bin/bash", "-c", `set -e; ${row.seed}`], { cwd: s, env: { PATH, HOME: W, SIDE: s }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      if (r.exitCode !== 0) throw new Error(`seed failed for ${label}: ${r.stderr.toString()}`);
    }
    got.push(side(row, s, name === "o"));
  }
  const [o, t] = got as [Side, Side];
  if (row.shell) {
    const own = /\.sh: line [0-9]+: /;
    expect(o.err).toMatch(own);
    o.err = o.err
      .split("\n")
      .filter((l) => !own.test(l))
      .join("\n");
  }
  const view = (x: Side) => ({ label, out: x.out, err: x.err, status: x.status, world: x.world });
  expect(view(t)).toEqual(view(o));
  return o;
}

// --- V: ac_verdict_json ------------------------------------------------------
// The input is a seeded file, so any byte reaches both sides as it is.
const verdict = (label: string, seed: string, env?: Record<string, string>): Side =>
  same(label, { seed, env, bash: 'ac_verdict_json <"$S/in"', twin: 'const r = L.verdictJson(readFileSync(S + "/in")); out(r.out); return r.status;' });

test("V: the last JSON object of a final message, through prose and fences", () => {
  expect(verdict("bare", `printf '{"findings":[],"verdict":"pass"}\\n' >in`).out).toBe('{"findings":[],"verdict":"pass"}\n|rc=0');
  verdict("fenced", "printf 'Summary first.\\n```json\\n{\"a\": 1,\\n \"b\": [1, 2]}\\n```\\nThanks.\\n' >in");
  expect(verdict("two objects, the last wins", `printf '{"a":1} and {"b":2}\\n' >in`).out).toBe('{"b":2}\n|rc=0');
  expect(verdict("braces and an escaped quote inside strings", `printf '%s\\n' 'x {"a":"}{\\"","b":"\\\\"} y' >in`).out).toContain('"b"');
  expect(verdict("a non-JSON brace region after the object", `printf '{"a":1} then {not json}\\n' >in`).out).toBe('{"a":1}\n|rc=0');
  verdict("nested", `printf '{"a":{"b":{"c":[{}]}}}\\n' >in`);
  verdict("a stray close brace first", `printf '} {"a":1}\\n' >in`);
  verdict("an unterminated string swallows the rest", `printf '{"a":1} "open {"b":2}\\n' >in`);
  verdict("no final LF", `printf '{"a":1}' >in`);
}, 120000);

test("V: nothing when no object parses", () => {
  expect(verdict("prose only", "printf 'no verdict here\\n' >in").out).toBe("|rc=0");
  expect(verdict("an array", "printf '[1,2]\\n' >in").out).toBe("|rc=0");
  expect(verdict("unbalanced", `printf '{"a":1\\n' >in`).out).toBe("|rc=0");
  expect(verdict("empty", ": >in").out).toBe("|rc=0");
}, 120000);

test("V: the locale's awk reads non-ASCII alike", () => {
  for (const loc of ["C", "en_US.UTF-8"]) {
    verdict(`Vietnamese text (${loc})`, `printf '{"summary":"Ti\\341\\272\\277ng Vi\\341\\273\\207t {ok}"}\\n' >in`, { LC_ALL: loc });
    verdict(`a byte that is no UTF-8 (${loc})`, `printf '{"summary":"caf\\351"}\\n' >in`, { LC_ALL: loc });
  }
}, 120000);

// --- E: ac_transcript_final_epoch --------------------------------------------
const assistant = (ts: string): string => `{"type":"assistant","timestamp":${ts},"message":{"content":[{"type":"text","text":"v"}]}}`;
const epoch = (label: string, seed: string, env?: Record<string, string>): Side =>
  same(label, { seed, env, bash: 'ac_transcript_final_epoch "$S/t.jsonl"', twin: 'const r = L.transcriptFinalEpoch(S + "/t.jsonl"); out(r.out); return r.status;' });

test("E: the last assistant message's own stamp, as an epoch second", () => {
  expect(epoch("Z", `printf '%s\\n' '${assistant('"2026-01-01T00:00:00.000Z"')}' >t.jsonl`).out).toBe("1767225600\n|rc=0");
  epoch("an offset", `printf '%s\\n' '${assistant('"2026-01-01T07:00:00+07:00"')}' >t.jsonl`);
  epoch("the last of two", `printf '%s\\n%s\\n' '${assistant('"2026-01-01T00:00:00Z"')}' '${assistant('"2026-06-01T00:00:00Z"')}' >t.jsonl`);
  for (const tz of ["UTC", "Asia/Ho_Chi_Minh"]) epoch(`no offset is local time (TZ=${tz})`, `printf '%s\\n' '${assistant('"2026-01-01T00:00:00"')}' >t.jsonl`, { TZ: tz });
}, 120000);

test("E: status 1 and nothing for every stamp it cannot read", () => {
  expect(epoch("no timestamp", `printf '%s\\n' '{"type":"assistant","message":{"content":[]}}' >t.jsonl`).out).toBe("|rc=1");
  expect(epoch("no assistant line", `printf '%s\\n' '{"type":"user","timestamp":"2026-01-01T00:00:00Z"}' >t.jsonl`).out).toBe("|rc=1");
  epoch("no JSON", "printf 'not json\\n' >t.jsonl");
  epoch("no file", ":");
  epoch("a day out of range", `printf '%s\\n' '${assistant('"2026-02-30T00:00:00Z"')}' >t.jsonl`);
  epoch("a number", `printf '%s\\n' '${assistant("123")}' >t.jsonl`);
}, 120000);

// --- B and L: ac_chief_busy_hold / ac_chief_busy_leave -----------------------
const hold = (label: string, until: string, seed?: string, shell = false): Side =>
  same(label, {
    seed,
    shell,
    args: [until],
    bash: 'ac_chief_busy_hold "$S/home/state" fam1 "$1"',
    twin: 'L.chiefBusyHold(S + "/home/state", "fam1", A[0]); return 0;',
  });

test("B: the holder mark first, then a bound that is never shortened", () => {
  hold("an empty state", "2000000000");
  hold("a later bound stays", "2000000000", "printf '3000000000\\n' >home/state/.chief-busy-until.fam1");
  hold("an earlier bound is raised", "2000000000", "printf '1000\\n' >home/state/.chief-busy-until.fam1");
  hold("text is read as 0", "2000000000", "printf 'abc\\n' >home/state/.chief-busy-until.fam1");
  hold("a bound below 0 never writes over 0", "-5");
  hold("a declaration that is a directory", "2000000000", "mkdir home/state/.chief-busy-until.fam1", true);
  hold("no state dir", "2000000000", "rm -r home/state", true);
  hold("a bound past [ 's range writes", "2000000000", "printf '99999999999999999999\\n' >home/state/.chief-busy-until.fam1", true);
}, 120000);

const leave = (label: string, seed?: string, quiet = true, shell = false): Side =>
  same(label, {
    seed,
    shell,
    bash: quiet
      ? 'ac_chief_busy_hold "$S/home/state" fam1 2000000000; ac_chief_busy_leave "$S/home/state" fam1 "$S/home/data/fam1" 2>/dev/null'
      : 'ac_chief_busy_hold "$S/home/state" fam1 2000000000; ac_chief_busy_leave "$S/home/state" fam1 "$S/home/data/fam1"',
    twin: `L.chiefBusyHold(S + "/home/state", "fam1", "2000000000"); L.chiefBusyLeave(S + "/home/state", "fam1", S + "/home/data/fam1", ${quiet}); return 0;`,
  });

test("L: the declaration goes only with the family's last live holder", () => {
  leave("the only holder, under the family lock", "mkdir -p home/data/fam1");
  leave("another live holder keeps it", "mkdir -p home/data/fam1; printf 'pid=1\\n' >home/state/.chief-busy-holder.fam1.1");
  leave("a dead holder is swept", "mkdir -p home/data/fam1; printf 'pid=99999\\n' >home/state/.chief-busy-holder.fam1.99999");
  leave("a live gate run keeps it", "mkdir -p home/data/fam1; printf 'pid=1\\n' >home/data/fam1/.gate-running.1");
  leave("a dead gate run is swept", "mkdir -p home/data/fam1; printf 'pid=99999\\n' >home/data/fam1/.gate-running.99999");
  leave("no family data dir takes no lock", "");
  leave("a family lock held by a live pid is waited on, then passed", "mkdir -p home/data/fam1/.gate-lock; printf '1\\n' >home/data/fam1/.gate-lock/pid");
  leave("a stale family lock is reclaimed", "mkdir -p home/data/fam1/.gate-lock; printf '99999\\n' >home/data/fam1/.gate-lock/pid");
}, 120000);

test.skipIf(ROOTUSER)("L: what the leave cannot read or remove, said aloud", () => {
  leave("an unreadable holder mark reads dead", "mkdir -p home/data/fam1; printf 'pid=1\\n' >home/state/.chief-busy-holder.fam1.7; chmod 000 home/state/.chief-busy-holder.fam1.7", false);
  leave("a mark it cannot remove", "mkdir -p home/data/fam1 home/state/sub; printf 'pid=99999\\n' >home/state/.chief-busy-holder.fam1.99999; chmod 555 home/state", false, true);
}, 120000);

// --- R: ac_room_review_rulings -----------------------------------------------
const rulings = (label: string, seed: string, env?: Record<string, string>): Side =>
  same(label, { seed, env, bash: 'ac_room_review_rulings "$S/room.md"', twin: 'const r = L.roomReviewRulings(S + "/room.md"); out(r.out); return r.status;' });

const ROOM = [
  "# Room: flow-v2",
  "",
  "- [2026-07-24T00:00:00Z] crewchief> TRIAGE: flow=staged mode=crew-ship",
  "- [2026-07-24T00:01:00Z] chief> GATE-LOOPED: rejected draft r1",
  "- [2026-07-24T00:02:00Z] chief> ASK: choose strict or compatible",
  "- [2026-07-24T00:02:30Z] chief> ASK (1 of 2): not a ruling shape here",
  "- [2026-07-24T00:03:00Z] captain> DECIDED flow-v2 (captain): strict",
  "- [2026-07-24T00:04:00Z] chief> SELF-APPROVED: architecture - grounded",
  "- [2026-07-24T00:05:00Z] chief> GATE-PASSED (auto): plan - reviewers concur",
  "- [2026-07-24T00:06:00Z] chief> CORRECTION (chief): target is prelive",
  "- [2026-07-24T00:07:00Z] chief> GATE: plan ready",
  "- [2026-07-24T00:08:00Z] chief> implementation narration not needed by review",
].join("\n");

test("R: the file-order projection of a room's rulings", () => {
  const o = rulings("a room with every shape", `cat >room.md <<'EOF'\n${ROOM}\nEOF`);
  expect(o.out).toContain("DECIDED flow-v2 (captain): strict");
  expect(o.out).not.toContain("GATE-LOOPED");
  rulings("no room", ":");
  rulings("a directory", "mkdir room.md");
  rulings("CRLF lines", "printf -- '- [t] chief> GATE: x\\r\\n- [t] chief> narration\\r\\n' >room.md");
  for (const loc of ["C", "en_US.UTF-8"]) rulings(`a byte that is no UTF-8 (${loc})`, "printf -- '- [t] chief> ASK: caf\\351?\\n' >room.md", { LC_ALL: loc });
}, 120000);

test.skipIf(ROOTUSER)("R: a room awk cannot open", () => {
  rulings("unreadable", "printf -- '- [t] chief> GATE: x\\n' >room.md; chmod 000 room.md");
}, 120000);

// --- H: ac_harness_pane_arm --------------------------------------------------
test("H: the pane-agent arm per harness, refused for any other", () => {
  for (const h of ["claude", "codex", "opencode", "pi", "cursor", "agy", "cursor-agent", "", "Claude"])
    same(`arm ${h || "(empty)"}`, {
      args: [h],
      bash: 'ac_harness_pane_arm "$1"',
      twin: 'const a = L.harnessPaneArm(A[0]); if (a === null) return 1; out(a + "\\n"); return 0;',
    });
}, 120000);

// --- C: backend_capture_pane -------------------------------------------------
const capture = (label: string, args: string[], env?: Record<string, string>, seed?: string): Side =>
  same(label, {
    seed,
    env,
    args,
    bash: 'backend_capture_pane "$@"',
    twin: 'const r = L.backendCapturePane(A[0] ?? "", A[1] ?? "", { stdout: "pipe", stderr: "inherit" }); out(r.out); if (r.exited) process.exit(r.status); return r.status;',
  });

test("C: herdr reads at least 200 lines and keeps the last <lines>", () => {
  capture("40 lines", ["p_1", "40"]);
  capture("250 lines", ["p_1", "250"]);
  capture("no lines given", ["p_1"]);
  capture("an empty lines value", ["p_1", ""]);
  capture("a lines value tail refuses", ["p_1", "abc"]);
  capture("a named session", ["p_1", "40"], { AC_HERDR_SESSION: "s1" });
  capture("the session knob", ["p_1", "40"], undefined, "printf 'knob\\n' >home/config/herdr-session");
}, 120000);

test("C: herdr's refusals", () => {
  capture("an empty pane", ["", "40"]);
  capture("a read that fails", ["p_1", "40"], { FAKE_HERDR: "fail" });
}, 120000);

test("C: orca reads the rendered screen", () => {
  capture("ok", ["t_1", "40"], undefined, "printf 'orca\\n' >home/config/backend");
  capture("ok:false", ["t_1", "40"], { FAKE_ORCA: "notok" }, "printf 'orca\\n' >home/config/backend");
  capture("a read that fails", ["t_1", "40"], { FAKE_ORCA: "fail" }, "printf 'orca\\n' >home/config/backend");
  capture("no tail", ["t_1", "40"], { FAKE_ORCA: "notail" }, "printf 'orca\\n' >home/config/backend");
  capture("an empty pane", ["", "40"], undefined, "printf 'orca\\n' >home/config/backend");
}, 120000);

test("C: a backend the route refuses exits 1", () => {
  const o = same("AC_BACKEND=tmux at the call", {
    args: ["p_1", "40"],
    bash: 'AC_BACKEND=tmux backend_capture_pane "$@"',
    twin: 'process.env.AC_BACKEND = "tmux"; const r = L.backendCapturePane(A[0], A[1], { stdout: "pipe", stderr: "inherit" }); out(r.out); if (r.exited) process.exit(r.status); return r.status;',
  });
  expect([o.status, o.out]).toEqual([1, ""]);
  expect(o.err).toContain("unsupported backend 'tmux'");
}, 120000);
