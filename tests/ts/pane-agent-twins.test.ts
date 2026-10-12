// pane-agent-twins.test.ts - the pane-agent twins of src/lib.ts held to the
// LIVE bash helpers they twin, each run in the call context bin/ac-pane-agent.sh
// gave it: inside `$(...)`, or bare with no errexit (the status read after the
// call). bin/ac-lib.sh: transcriptFinalEpoch (ac_transcript_final_epoch, which
// starts this module's iso-epoch verb), claudeTranscriptRoot; bin/ac-harness.sh:
// harnessPaneArm; bin/ac-backend.sh and bin/ac-backend-orca.sh, both drivers:
// backendCapturePane, backendHarnessUpPane, backendSendKeyPane,
// backendSendLinePane, backendAgentStatusPane and backendStartupDialogsPane.
// Every row compares stdout, stderr (less the shell's own `line N:` lines),
// the status, the stub log and the side's tree.
//
// DISPUTED: the implementation of each helper (the live bash vs src/lib.ts's pane-agent twins)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home with state/ records/ data/ config/, transcripts under <side>, the stubs' answer files, call counters and log at <side>/stub, TMPDIR at <side>/tmp); argv; env (PATH = refusing claude/codex/opencode/pi/cursor-agent/docker/codegraph/gh stand-ins, then herdr, orca, sleep and date stubs, the host's jq and git, bun alone, /bin plus /usr/bin without those names - no row can reach a real backend or harness; LC_ALL=C unless a row names UTF-8; TZ=UTC; HOME an empty dir unless a row unsets it; AC_SEND_SETTLE=0 and AC_STARTUP_DIALOG_BUDGET=2 unless a row names others; STUB_DIR, TMPDIR, AC_HOME, the row's own names); cwd (the distro root, so the bash's ac_bun_exec and the twins name one src/); stdin (/dev/null).
import { afterAll, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = realpathSync(join(import.meta.dir, "..", ".."));
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-pane-agent-twins-ts-")));
afterAll(() => {
  Bun.spawnSync(["chmod", "-R", "u+rwX", W]);
  rmSync(W, { recursive: true, force: true });
});

const STOOD_IN = ["claude", "codex", "opencode", "pi", "cursor-agent", "agy", "docker", "codegraph", "gh"];
const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if ([...STOOD_IN, "jq", "herdr", "orca", "sleep", "date", "bun"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const GUARD = join(W, "guard");
mkdirSync(GUARD);
for (const t of STOOD_IN) writeFileSync(join(GUARD, t), `#!/bin/sh\necho "refused stand-in: ${t}" >&2\nexit 97\n`, { mode: 0o755 });
const TOOLS = join(W, "tools");
mkdirSync(TOOLS);
symlinkSync(Bun.which("jq")!, join(TOOLS, "jq"));
const BUN = join(W, "bun");
mkdirSync(BUN);
symlinkSync(process.execPath, join(BUN, "bun"));

// A file-backed herdr: every call logged with its argv bracketed and the
// HERDR_SESSION it saw; the n-th call of a verb (`<a>-<b>`) answers from
// <verb>.<n>.{err,out,rc} when any exists, else <verb>.{err,out,rc}, else
// nothing and 0.
const HERDR = String.raw`#!/bin/sh
d="$STUB_DIR"
{ printf herdr; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' {%s}\n' "$HERDR_SESSION"; } >>"$d/log"
v="$1-$2"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.err" ]; then
    [ ! -e "$d/$f.err" ] || cat "$d/$f.err" >&2
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
exit 0
`;
// orca, the same file-backed shape; a verb with no answer file is an ok
// envelope with an empty result.
const ORCA = String.raw`#!/bin/sh
d="$STUB_DIR"
{ printf orca; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$d/log"
v="$1-$2"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.err" ]; then
    [ ! -e "$d/$f.err" ] || cat "$d/$f.err" >&2
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
printf '{"ok":true,"result":{}}\n'
`;
const SLEEP = String.raw`#!/bin/sh
printf 'sleep %s\n' "$*" >>"$STUB_DIR/log"
[ ! -e "$STUB_DIR/sleep.rc" ] || { echo "sleep: refused" >&2; exit "$(cat "$STUB_DIR/sleep.rc")"; }
`;
const DATE = String.raw`#!/bin/sh
case "$*" in *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;; *%s*) echo 1767225600 ;; *) exec /bin/date "$@" ;; esac
`;
const STUBS = join(W, "stubs");
mkdirSync(STUBS);
writeFileSync(join(STUBS, "herdr"), HERDR, { mode: 0o755 });
writeFileSync(join(STUBS, "orca"), ORCA, { mode: 0o755 });
writeFileSync(join(STUBS, "sleep"), SLEEP, { mode: 0o755 });
writeFileSync(join(STUBS, "date"), DATE, { mode: 0o755 });
const PATH = `${GUARD}:${STUBS}:${TOOLS}:${BUN}:${BASE}`;
const NOHOME = join(W, "nohome");
mkdirSync(NOHOME);

type Row = {
  // the bash call, after sourcing ac-lib.sh and ac-backend.sh, its arguments "$@"
  bash: string;
  // the twin's body: L is src/lib.ts, A the arguments, say/sayU write latin1/UTF-8
  twin: string;
  args?: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  noHome?: boolean;
  lc?: string;
};
type Side = { out: string; err: string; rc: number | null; log: string; world: string };

const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const byBytes = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

// The side's tree, TMPDIR and the stub's bookkeeping skipped.
function world(s: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(s, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort(byBytes)) {
    const r = rel ? `${rel}/${name}` : name;
    if (r === "tmp" || r === "stub") continue;
    const p = join(s, r);
    const st = lstatSync(p);
    const mode = (st.mode & 0o777).toString(8);
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(p)}\n`;
    else if (st.isDirectory()) w += `${r}/ ${mode}\n${world(s, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(p, "latin1");
      } catch {}
      w += `${r} ${mode} = ${JSON.stringify(body)}\n`;
    }
  }
  return w;
}

function read(f: string): string {
  try {
    return readFileSync(f, "latin1");
  } catch {
    return "";
  }
}

const PRE = `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const say = (s) => void writeSync(1, Buffer.from(s, "latin1")); const sayU = (s) => void writeSync(1, Buffer.from(s, "utf8")); const cap = (b) => b.toString("latin1").replace(/\\0/g, "").replace(/\\n+$/, "");`;

let rows = 0;
function side(row: Row, s: string, oracle: boolean): Side {
  const env: Record<string, string> = { PATH, HOME: NOHOME, TMPDIR: join(s, "tmp"), LC_ALL: row.lc ?? "C", TZ: "UTC", STUB_DIR: join(s, "stub"), AC_HOME: join(s, "home"), AC_SEND_SETTLE: "0", AC_STARTUP_DIALOG_BUDGET: "2" };
  if (row.noHome) delete env.HOME;
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  const args = (row.args ?? []).map((a) => a.replaceAll("@S", s));
  const cmd = oracle
    ? ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; ${row.bash}; printf '|rc=%s' "$?"`, BIN, ...args]
    : [process.execPath, "-e", `${PRE} const A = ${JSON.stringify(args)}; const rc = await (async () => { ${row.twin} })(); writeSync(1, "|rc=" + rc); process.exit(0);`];
  const r = Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  // bash 3.2's `set -m` (herdr_rpc_bounded) now and then prints its own
  // `child setpgid` line - shell-own stderr, never reproduced.
  const norm = (t: string): string => t.replaceAll(s, "S").replace(/^.*: child setpgid \([0-9]+ to [0-9]+\): Operation not permitted\n/gm, "");
  let err = norm(r.stderr.toString("latin1"));
  if (oracle) err = err.replace(/^.*: line [0-9]+: .*\n/gm, "");
  const out = { out: norm(r.stdout.toString("latin1")), err, rc: r.exitCode, log: norm(read(join(s, "stub", "log"))), world: norm(world(s)) };
  Bun.spawnSync(["chmod", "-R", "u+rwX", s]);
  return out;
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const root = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(root, name);
    for (const sub of ["home/state", "home/records", "home/data", "home/config", "stub", "tmp"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  const view = (x: Side) => ({ label, ...x });
  expect(view(out[1]!)).toEqual(view(out[0]!));
  return { o: out[0]!, t: out[1]! };
}

const put = (s: string, rel: string, body: string, mode = 0o644): void => {
  mkdirSync(join(s, rel, ".."), { recursive: true });
  writeFileSync(join(s, rel), Buffer.from(body.replaceAll("@S", s), "latin1"), { mode });
  chmodSync(join(s, rel), mode);
};

// The bare raw-pane calls: the status is the verb's own, a refused backend
// name ends the caller before anything after it prints.
const verb = (call: string, ts: string, args: string[]): Row => ({ bash: `${call} "$@"`, twin: `const r = ${ts}; if (r.exited) process.exit(r.status); return r.status;`, args });
// The captured ones: `x="$(<call>)"; s=$?` - a refused name ends only the
// substitution. ac-backend.sh refuses a bad name when it is sourced too, so a
// row of either kind reaches the route's refusal only with the name set after
// that.
const capture = (call: string, ts: string, args: string[], redirect = ""): Row => ({
  bash: `x="$(${call} "$@"${redirect})"; s=$?; printf '[%s]' "$x"; (exit $s)`,
  twin: `const r = ${ts}; say("[" + (r.exited ? "" : cap(r.out)) + "]"); return r.exited ? 1 : r.status;`,
  args,
});
const tmuxAtCall = (row: Row): Row => ({ ...row, bash: `export AC_BACKEND=tmux; ${row.bash}`, twin: `process.env.AC_BACKEND = "tmux"; ${row.twin}` });
const IO = `{ stderr: "inherit" }`;
const ORCA_ = { AC_BACKEND: "orca" };
const OSHOW = (terminal: string): string => `{"ok":true,"result":{"terminal":${terminal}}}\n`;
const PGET = (st: string): string => `{"result":{"pane":{"pane_id":"p1","tab_id":"w1:t1","agent_status":"${st}"}}}\n`;
const FG = (...names: string[]): string => `{"result":{"process_info":{"foreground_processes":[${names.map((n) => `{"argv0":"${n}"}`).join(",")}]}}}\n`;
const BLK = (rule: string): string => `{"state":"blocked","matched_rule":{"id":"${rule}"}}\n`;

test("transcriptFinalEpoch reads the last assistant stamp as ac_transcript_final_epoch did", () => {
  const ep: Row = { bash: `ac_transcript_final_epoch "$1"`, twin: `const r = L.transcriptFinalEpoch(A[0]); say(r.out); return r.status;`, args: ["@S/t.jsonl"] };
  const tr = (...lines: string[]) => (s: string): void => put(s, "t.jsonl", lines.map((l) => `${l}\n`).join(""));
  same("a Z stamp", { ...ep, seed: tr('{"type":"assistant","timestamp":"2026-03-04T05:06:07.890Z","message":{}}') });
  same("an offset stamp", { ...ep, seed: tr('{"type":"assistant","timestamp":"2026-03-04T05:06:07+02:00"}') });
  same("no offset: local time (TZ=UTC)", { ...ep, seed: tr('{"type":"assistant","timestamp":"2026-03-04 05:06"}') });
  same("the LAST assistant's stamp", { ...ep, seed: tr('{"type":"assistant","timestamp":"2020-01-01T00:00:00Z"}', '{"type":"user","timestamp":"2030-01-01T00:00:00Z"}', '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z"}') });
  same("a last assistant with no stamp", { ...ep, seed: tr('{"type":"assistant","timestamp":"2020-01-01T00:00:00Z"}', '{"type":"assistant"}') });
  same("no assistant", { ...ep, seed: tr('{"type":"user","timestamp":"2020-01-01T00:00:00Z"}') });
  same("a stamp outside the grammar", { ...ep, seed: tr('{"type":"assistant","timestamp":"2026-02-30T00:00:00Z"}') });
  same("a transcript that is no JSON", { ...ep, seed: tr("oops") });
  same("no transcript", ep);
  same("an empty path", { ...ep, args: [""] });
}, 120000);

test("harnessPaneArm answers ac_harness_pane_arm's arm map", () => {
  const arm: Row = { bash: `x="$(ac_harness_pane_arm "$1")"; s=$?; printf '[%s]' "$x"; (exit $s)`, twin: `const r = L.harnessPaneArm(A[0]); say("[" + (r ?? "") + "]"); return r === null ? 1 : 0;` };
  for (const h of ["claude", "codex", "opencode", "pi", "cursor", "agy", "cursor-agent", "", "Claude", "toString"]) same(`arm '${h}'`, { ...arm, args: [h] });
}, 60000);

test("claudeTranscriptRoot answers ac_claude_transcript_root's ladder", () => {
  const root: Row = { bash: `x="$(ac_claude_transcript_root)"; s=$?; printf '[%s]' "$x"; (exit $s)`, twin: `const r = L.claudeTranscriptRoot(); sayU("[" + (r ?? "") + "]"); return r === null ? 1 : 0;` };
  same("HOME's", root);
  same("CLAUDE_CONFIG_DIR's", { ...root, env: { CLAUDE_CONFIG_DIR: "/x/cfg" } });
  same("AC_CLAUDE_TRANSCRIPT_ROOT wins", { ...root, env: { CLAUDE_CONFIG_DIR: "/x/cfg", AC_CLAUDE_TRANSCRIPT_ROOT: "/x/tr" } });
  same("empty knobs fall through", { ...root, env: { CLAUDE_CONFIG_DIR: "", AC_CLAUDE_TRANSCRIPT_ROOT: "" } });
  same("HOME unset: the capture's set -u death", { ...root, noHome: true });
  same("HOME unset, CLAUDE_CONFIG_DIR set", { ...root, noHome: true, env: { CLAUDE_CONFIG_DIR: "/x/cfg" } });
}, 60000);

test("backendCapturePane reads a raw pane as the drivers did, inside a capture", () => {
  const cp = capture("backend_capture_pane", `L.backendCapturePane(A[0], A[1], { stdout: "pipe", stderr: "ignore" })`, ["p1", "2"], " 2>/dev/null");
  same("herdr: the last lines", { ...cp, seed: (s) => put(s, "stub/pane-read.out", "a\nb\nc\n") });
  same("herdr: 400 lines fetch 400", { ...cp, args: ["p1", "400"], seed: (s) => put(s, "stub/pane-read.out", "a\nb\n") });
  same("herdr: a read that fails", { ...cp, seed: (s) => put(s, "stub/pane-read.rc", "1\n") });
  same("herdr: no pane", { ...cp, args: ["", "40"] });
  same("herdr: no line count", { ...cp, args: ["p1", ""], seed: (s) => put(s, "stub/pane-read.out", "x\n") });
  same("orca: the screen", { ...cp, args: ["h1", "40"], env: ORCA_, seed: (s) => put(s, "stub/terminal-read.out", '{"ok":true,"result":{"terminal":{"tail":["a","b"]}}}\n') });
  same("orca: a read that fails", { ...cp, args: ["h1", "40"], env: ORCA_, seed: (s) => put(s, "stub/terminal-read.rc", "1\n") });
  expect(same("an unsupported backend", tmuxAtCall(cp)).o.out).toBe("[]|rc=1");
}, 120000);

test("backendHarnessUpPane probes a raw pane's came-up states as the drivers did", () => {
  const up = verb("backend_harness_up_pane", `L.backendHarnessUpPane(A[0], ${IO})`, ["p1"]);
  same("herdr: a harness in the foreground", { ...up, seed: (s) => put(s, "stub/pane-process-info.out", FG("-zsh", "/usr/local/bin/codex")) });
  same("herdr: a shell alone", { ...up, seed: (s) => put(s, "stub/pane-process-info.out", FG("-zsh", "bash")) });
  same("herdr: no process named", { ...up, seed: (s) => put(s, "stub/pane-process-info.out", '{"result":{"process_info":{"foreground_processes":[]}}}\n') });
  same("herdr: the read fails", { ...up, seed: (s) => put(s, "stub/pane-process-info.rc", "1\n") });
  same("herdr: no pane", { ...up, args: [""] });
  const show = (t: string) => (s: string): void => put(s, "stub/terminal-show.out", lat(OSHOW(t)));
  same("orca: a shell title", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"-zsh"}') });
  same("orca: orca's own identity", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"cd","agentIdentity":"codex"}') });
  same("orca: claude's idle glyph", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"✳ Claude Code"}') });
  same("orca: a spinner", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"◐ work"}') });
  same("orca: a cwd title, not idle", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"repo"}') });
  same("orca: a cwd title, tui-idle satisfied", { ...up, args: ["h1"], env: ORCA_, seed: (s) => (show('{"connected":true,"title":"repo"}')(s), put(s, "stub/terminal-wait.out", '{"ok":true,"result":{"wait":{"satisfied":true}}}\n')) });
  same("orca: disconnected", { ...up, args: ["h1"], env: ORCA_, seed: show('{"connected":false,"title":"codex"}') });
  same("orca: the show fails", { ...up, args: ["h1"], env: ORCA_, seed: (s) => put(s, "stub/terminal-show.rc", "1\n") });
  same("an unsupported backend", tmuxAtCall(up));
}, 180000);

test("backendSendKeyPane presses one key at a raw pane as the drivers did", () => {
  const key = verb("backend_send_key_pane", `L.backendSendKeyPane(A[0], A[1], ${IO})`, ["p1", "Enter"]);
  same("herdr: Enter, the tab focused first", { ...key, seed: (s) => put(s, "stub/pane-get.out", PGET("idle")) });
  same("herdr: an unnamed key", { ...key, args: ["p1", "2"], seed: (s) => put(s, "stub/pane-get.out", PGET("idle")) });
  same("herdr: no tab to focus still presses", { ...key, args: ["p1", "Escape"], seed: (s) => put(s, "stub/pane-get.rc", "1\n") });
  same("herdr: the press fails", { ...key, seed: (s) => (put(s, "stub/pane-get.out", PGET("idle")), put(s, "stub/pane-send-keys.rc", "3\n")) });
  same("herdr: no pane", { ...key, args: ["", "Enter"] });
  for (const k of ["Enter", "Esc", "C-c", "y"]) same(`orca: ${k}`, { ...key, args: ["h1", k], env: ORCA_ });
  same("orca: the send fails", { ...key, args: ["h1", "Enter"], env: ORCA_, seed: (s) => put(s, "stub/terminal-send.rc", "1\n") });
  same("orca: no pane", { ...key, args: ["", "Enter"], env: ORCA_ });
  same("an unsupported backend", tmuxAtCall(key));
}, 120000);

test("backendSendLinePane types and verifies one line at a raw pane as the drivers did", () => {
  const line = verb("backend_send_line_pane", `L.backendSendLinePane(A[0], A[1], ${IO})`, ["p1", "hello there"]);
  same("herdr: the render reacts", { ...line, seed: (s) => (put(s, "stub/pane-read.1.out", "a\n"), put(s, "stub/pane-read.out", "b\n")) });
  same("herdr: never reacts: focus and one retry, stranded", { ...line, seed: (s) => (put(s, "stub/pane-read.out", "a\n"), put(s, "stub/pane-get.out", PGET("idle"))) });
  same("herdr: the retry reacts", {
    ...line,
    seed: (s) => {
      for (let n = 1; n <= 9; n++) put(s, `stub/pane-read.${n}.out`, "a\n");
      put(s, "stub/pane-read.out", "b\n");
      put(s, "stub/pane-get.out", PGET("idle"));
    },
  });
  same("herdr: unreadable", { ...line, seed: (s) => put(s, "stub/pane-read.rc", "1\n") });
  same("herdr: no pane", { ...line, args: ["", "x"] });
  const screen = (n: string, tail: string): string => `{"ok":true,"result":{"terminal":{"tail":${tail}}}}\n`;
  same("orca: the render reacts", { ...line, args: ["h1", "hi"], env: ORCA_, seed: (s) => (put(s, "stub/terminal-read.1.out", screen("1", '["a"]')), put(s, "stub/terminal-read.out", screen("2", '["b"]'))) });
  same("orca: a dialog owns the pane: 1, no retry", { ...line, args: ["h1", "hi"], env: ORCA_, seed: (s) => put(s, "stub/terminal-show.out", OSHOW('{"agentWait":{"reason":"x"}}')) });
  same("orca: never reacts, a dialog on the retry: 3", {
    ...line,
    args: ["h1", "hi"],
    env: ORCA_,
    seed: (s) => (put(s, "stub/terminal-show.1.out", OSHOW("{}")), put(s, "stub/terminal-show.out", OSHOW('{"agentWait":{"reason":"x"}}')), put(s, "stub/terminal-read.out", screen("1", '["a"]'))),
  });
  same("orca: unreadable", { ...line, args: ["h1", "hi"], env: ORCA_, seed: (s) => put(s, "stub/terminal-read.rc", "1\n") });
  same("orca: no pane", { ...line, args: ["", "hi"], env: ORCA_ });
  same("an unsupported backend", tmuxAtCall(line));
}, 180000);

test("backendAgentStatusPane prints a raw pane's status word as the drivers did, inside a capture", () => {
  const st = capture("backend_agent_status_pane", `L.backendAgentStatusPane(A[0], ${IO})`, ["p1"]);
  for (const v of ["idle", "working", "blocked", "done", ""]) same(`herdr: '${v}'`, { ...st, seed: (s) => put(s, "stub/pane-get.out", PGET(v)) });
  same("herdr: an answer that is no JSON", { ...st, seed: (s) => put(s, "stub/pane-get.out", "oops\n") });
  same("herdr: the read fails", { ...st, seed: (s) => put(s, "stub/pane-get.rc", "1\n") });
  same("herdr: no pane", { ...st, args: [""] });
  const show = (t: string) => (s: string): void => put(s, "stub/terminal-show.out", lat(OSHOW(t)));
  same("orca: a wait", { ...st, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"agentWait":{"reason":"x"}}') });
  same("orca: disconnected", { ...st, args: ["h1"], env: ORCA_, seed: show('{"connected":false}') });
  same("orca: claude idle", { ...st, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"✳ Claude Code"}') });
  same("orca: a spinner", { ...st, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"✻ thinking"}') });
  same("orca: nothing to tell", { ...st, args: ["h1"], env: ORCA_, seed: show('{"connected":true,"title":"repo"}') });
  same("orca: the show fails", { ...st, args: ["h1"], env: ORCA_, seed: (s) => put(s, "stub/terminal-show.rc", "1\n") });
  same("orca: no pane", { ...st, args: [""], env: ORCA_ });
  const refused = same("an unsupported backend", tmuxAtCall(st)).o;
  expect([refused.out, refused.err]).toEqual(["[]|rc=1", "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)\n"]);
}, 180000);

test("backendStartupDialogsPane runs ac_startup_dialogs over the raw-pane verbs, no errexit", () => {
  const sd: Row = { bash: `backend_startup_dialogs_pane "$1" "$2"`, twin: `const r = L.backendStartupDialogsPane(A[0], A[1], ${IO}); if (r.exited) process.exit(r.status); return r.status;`, args: ["p1", "codex"] };
  same("herdr: named, unnamed, then up", {
    ...sd,
    seed: (s) => (put(s, "stub/pane-process-info.out", FG("codex")), put(s, "stub/agent-explain.1.out", BLK("startup_update")), put(s, "stub/agent-explain.2.out", BLK("trust")), put(s, "stub/agent-explain.3.out", '{"state":"idle"}\n'), put(s, "stub/pane-get.out", PGET("idle"))),
  });
  same("herdr: an unnamed dialog twice: the key once", { ...sd, seed: (s) => put(s, "stub/agent-explain.out", BLK("trust")) });
  same("herdr: claude has no key", { ...sd, args: ["p1", "claude"], seed: (s) => put(s, "stub/agent-explain.out", BLK("trust")) });
  same("herdr: unobservable: the key, once, and out", sd);
  same("herdr: answered every round, the budget spent", { ...sd, seed: (s) => (put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/pane-get.out", PGET("blocked"))) });
  same("herdr: nothing pending, a bare shell", { ...sd, seed: (s) => (put(s, "stub/agent-explain.out", '{"state":"idle"}\n'), put(s, "stub/pane-process-info.out", FG("-zsh"))) });
  same("herdr: a sleep that fails is passed over", { ...sd, seed: (s) => (put(s, "stub/agent-explain.out", BLK("startup_update")), put(s, "stub/pane-get.out", PGET("blocked")), put(s, "stub/sleep.rc", "3\n")) });
  same("orca: both codex prompts answered, then up", {
    ...sd,
    args: ["h1", "codex"],
    env: ORCA_,
    seed: (s) => (put(s, "stub/terminal-show.1.out", OSHOW('{"connected":true,"agentWait":{"reason":"codex-update-prompt"}}')), put(s, "stub/terminal-show.2.out", OSHOW('{"connected":true,"agentWait":{"reason":"codex-hooks-review-prompt"}}')), put(s, "stub/terminal-show.out", OSHOW('{"connected":true,"agentIdentity":"codex"}'))),
  });
  same("an unsupported backend", tmuxAtCall(sd));
}, 180000);
