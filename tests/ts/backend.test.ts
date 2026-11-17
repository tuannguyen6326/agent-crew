// backend.test.ts - backendCall (src/lib.ts) held to the LIVE bash drivers it
// twins, bin/ac-backend.sh and bin/ac-backend-orca.sh: every row runs the
// verb as a bash caller sourcing the drivers ran it, `/bin/bash -c 'set -uo
// pipefail; . ac-lib.sh; . ac-backend.sh; <verb> "$@"; printf "|rc=%s" "$?"'`
// (inside `( )` for a subshell row, under `set -e` for an errexit row), beside
// a bun child calling the twin that exits with an exited result's status (an
// errexit row's non-zero status too), and compares stdout, stderr (less the
// shell's own `line N:` lines), the `|rc=` status and the process's exit, the
// stub log, the home's tree and, on the hang rows, the elapsed time and the
// grandchildren left alive; a send_line row also its stub pane's composer and
// transcript, and logs its sleeps. A side a signal ended is no answer: its row
// fails by name. A drift in the bash drivers turns these red.
//
// DISPUTED: the implementation of the backend verbs (the bash drivers vs src/lib.ts backendCall)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home, the stubs' sentinels and log at <side>/stub); argv; env (PATH, LC_ALL=C unless a row names UTF-8, HOME, TMPDIR, STUB_DIR, AC_HOME unless homeless, the row's own names); cwd (the side root); stdin (/dev/null, or the row's bytes); PATH = a logging sleep on send_line rows, the orca stub (or a variant without one), a dir holding the host's jq (dropped by the jq-absent rows, a noisy wrapper of it on the noisy-jq rows), and /bin plus /usr/bin without jq or orca - no row can reach a real orca.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-backend-ts-")));
const ROOTED = process.getuid?.() === 0;
const HANGERS: number[] = [];
afterAll(() => {
  for (const p of HANGERS)
    try {
      process.kill(p, "SIGKILL");
    } catch {}
  rmSync(W, { recursive: true, force: true });
});

const BASE = join(W, "base");
mkdirSync(BASE);
for (const d of ["/usr/bin", "/bin"])
  for (const name of readdirSync(d)) {
    if (["jq", "herdr", "orca"].includes(name) || existsSync(join(BASE, name))) continue;
    symlinkSync(join(d, name), join(BASE, name));
  }
const JQ = join(W, "jq");
mkdirSync(JQ);
symlinkSync(Bun.which("jq")!, join(JQ, "jq"));

const RULE = "─".repeat(12);
// The send verbs' waits, logged in line with the stubs' calls and then slept.
const SLEEPS = join(W, "sleeps");
mkdirSync(SLEEPS);
writeFileSync(join(SLEEPS, "sleep"), `#!/bin/sh\nprintf 'sleep %s\\n' "$*" >>"$STUB_DIR/log"\nexec /bin/sleep "$@"\n`, { mode: 0o755 });
// An orca claude pane, when oui-<h> exists: `terminal read --screen` serves
// the last --limit lines of the screen - the transcript, a popup row while
// popups counts, the composer (ocmp-<h>, its first row behind ❯) between two
// rules, a status row - as JSON the host's jq builds. `send --text` appends
// the text to the composer (keep-head bytes of it at most; text-fails
// refuses it; prompt-blocked refuses a `--text --enter` send untyped, as
// agent_prompt_blocked); an `--enter`, alone or after the text, submits it
// into the transcript unless the pane
// is unfocused (`terminal switch` focuses it), drop-enters still counts, or a
// popup eats it (the render changes, the text stays); late, norules, onerule,
// ticker and read-fails-from all count `terminal read`s.
const ORCA = `#!/bin/sh
d="$STUB_DIR"
if [ -e "$d/readstdin" ]; then
  printf 'orca %s stdin=[%s]\\n' "$*" "$(cat)" >>"$d/log"
elif [ -e "$d/readline" ]; then
  IFS= read -r l
  printf 'orca %s line=[%s]\\n' "$*" "$l" >>"$d/log"
else
  printf 'orca %s\\n' "$*" >>"$d/log"
fi
[ ! -e "$d/orca-slow" ] || sleep 3
[ ! -e "$d/kill-caller" ] || kill -TERM "$PPID"
n=0
if [ "$1 $2" = "terminal read" ]; then
  n=$(($(cat "$d/reads" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$d/reads"
fi
case "$1 $2" in
  "terminal show")
    [ ! -e "$d/show-fails" ] || exit 1
    if [ -e "$d/show" ]; then cat "$d/show"; else printf '{"ok":true,"result":{"terminal":{"connected":true}}}\\n'; fi
    [ ! -e "$d/show-next" ] || mv "$d/show-next" "$d/show"
    [ ! -e "$d/show-fails-next" ] || mv "$d/show-fails-next" "$d/show-fails" ;;
  "status --json") [ ! -e "$d/ostatus-fails" ] || exit 1; printf '{"ok":true,"result":{}}\\n' ;;
  "terminal read")
    if [ -e "$d/oui-$4" ]; then
      [ ! -e "$d/read-fails-from" ] || [ "$n" -lt "$(cat "$d/read-fails-from")" ] || exit 1
      if [ -e "$d/lag" ]; then
        if [ "$(cat "$d/lag")" -gt 1 ]; then echo $(($(cat "$d/lag") - 1)) >"$d/lag"; else rm "$d/lag"; mv "$d/next-ui" "$d/oui-$4"; mv "$d/next-cmp" "$d/ocmp-$4"; fi
      fi
      {
        [ ! -e "$d/ticker" ] || echo "tick $n"
        cat "$d/oui-$4"
        [ "$(cat "$d/popups" 2>/dev/null || echo 0)" -eq 0 ] || echo "[popup $(cat "$d/popups")]"
        [ -e "$d/norules" ] || [ -e "$d/onerule" ] || echo '${RULE}'
        if [ -s "$d/ocmp-$4" ]; then LC_ALL=C awk '{ print (NR == 1 ? "❯ " : "  ") $0 }' "$d/ocmp-$4"; else echo '❯ '; fi
        [ -e "$d/norules" ] || echo '${RULE}'
        echo '  ? for shortcuts'
      } | tail -n "$6" | '${Bun.which("jq")}' -Rnc '{ok: true, result: {terminal: {tail: [inputs]}}}'
      exit 0
    fi
    [ -e "$d/oread" ] || exit 1; cat "$d/oread"; [ ! -e "$d/oread-next" ] || mv "$d/oread-next" "$d/oread" ;;
  "terminal wait") [ -e "$d/owait" ] || exit 1; cat "$d/owait" ;;
  "terminal switch") [ ! -e "$d/switch-fails" ] || exit 1; rm -f "$d/unfocused"; printf '{"ok":true}\\n' ;;
  "terminal send")
    [ ! -e "$d/send-fails" ] || exit 1
    if [ -e "$d/prompt-blocked" ] && [ "$5 $7" = "--text --enter" ]; then printf '{"ok":false,"error":{"code":"agent_prompt_blocked"}}\\n'; exit 1; fi
    if [ -e "$d/oui-$4" ]; then
      if [ "$5" = --text ]; then
        [ ! -e "$d/text-fails" ] || exit 1
        printf '%s' "$6" >>"$d/ocmp-$4"
        if [ -e "$d/keep-head" ]; then head -c "$(cat "$d/keep-head")" "$d/ocmp-$4" >"$d/cmp.new"; mv "$d/cmp.new" "$d/ocmp-$4"; fi
      fi
      if [ "$5" = --enter ] || [ "$7" = --enter ]; then
        if [ -e "$d/unfocused" ]; then :
        elif [ "$(cat "$d/drop-enters" 2>/dev/null || echo 0)" -gt 0 ]; then echo $(($(cat "$d/drop-enters") - 1)) >"$d/drop-enters"
        elif [ "$(cat "$d/popups" 2>/dev/null || echo 0)" -gt 0 ]; then echo $(($(cat "$d/popups") - 1)) >"$d/popups"
        else
          { cat "$d/oui-$4"; printf '> %s\\n' "$(LC_ALL=C tr -d '\\n' <"$d/ocmp-$4")"; } >"$d/next-ui"
          : >"$d/next-cmp"
          if [ -e "$d/late" ]; then mv "$d/late" "$d/lag"; else mv "$d/next-ui" "$d/oui-$4"; mv "$d/next-cmp" "$d/ocmp-$4"; fi
        fi
      fi
    fi
    if [ -e "$d/send" ]; then cat "$d/send"; else printf '{"ok":true}\\n'; fi ;;
  *) exit 2 ;;
esac
`;
// One stub dir per PATH variant: orca present or absent; and a jq that names
// each call on its stderr, so a row shows which jq's stderr reached the
// caller.
function stubs(name: string, orca: boolean): string {
  const d = join(W, name);
  mkdirSync(d);
  if (orca) writeFileSync(join(d, "orca"), ORCA, { mode: 0o755 });
  return d;
}
const NOISY = join(W, "noisyjq");
mkdirSync(NOISY);
writeFileSync(join(NOISY, "jq"), `#!/bin/sh\nprintf 'jq-stderr %s\\n' "$*" >&2\nexec '${Bun.which("jq")}' "$@"\n`, { mode: 0o755 });
const PATHS = {
  both: `${stubs("stubs", true)}:${JQ}:${BASE}`,
  nojq: `${join(W, "stubs")}:${BASE}`,
  noorca: `${stubs("stubs-noorca", false)}:${JQ}:${BASE}`,
  noisyjq: `${join(W, "stubs")}:${NOISY}:${BASE}`,
};

type Fn = "window_alive" | "target" | "focus" | "capture" | "mark_wait" | "clear_wait" | "agent_blocked" | "harness_up" | "send_key" | "send_line";
type Io = { stdin?: "inherit" | "ignore"; stdout: "inherit" | "ignore" | "pipe"; stderr: "inherit" | "ignore"; subshell?: boolean };
type Row = {
  fn: Fn;
  args: string[];
  seed?: (s: string) => void;
  env?: Record<string, string>;
  homeless?: boolean;
  path?: keyof typeof PATHS;
  io?: Io;
  input?: string;
  lc?: string;
  noLog?: boolean;
  // The call bare under errexit, where ac-send.sh's --key path makes it.
  errexit?: boolean;
};
type Side = { out: string; err: string; rc: number; log: string; world: string; ms: number; hangers: number[] };

let rows = 0;
const pane = (s: string, id: string, body: string): void => writeFileSync(join(s, "home", "state", `.pane-${id}`), Buffer.from(body, "latin1"));
const sent = (s: string, name: string, body = ""): void => writeFileSync(join(s, "stub", name), Buffer.from(body, "latin1"));
const cfg = (s: string, name: string, body: string): void => writeFileSync(join(s, "home", "config", name), body);

function world(h: string, rel = ""): string {
  let names: string[];
  try {
    names = readdirSync(join(h, rel));
  } catch {
    return "";
  }
  let w = "";
  for (const name of names.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    const r = rel ? `${rel}/${name}` : name;
    const st = lstatSync(join(h, r));
    if (st.isSymbolicLink()) w += `${r} -> ${readlinkSync(join(h, r))}\n`;
    else if (st.isDirectory()) w += `${r}/\n${world(h, r)}`;
    else {
      let body = "<unreadable>";
      try {
        body = readFileSync(join(h, r), "latin1");
      } catch {}
      w += `${r} = ${JSON.stringify(body)}\n`;
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

function side(row: Row, s: string, oracle: boolean, label: string): Side {
  const io: Io = row.io ?? { stdout: "inherit", stderr: "inherit" };
  const env: Record<string, string> = {
    PATH: (row.fn === "send_line" ? `${SLEEPS}:` : "") + PATHS[row.path ?? "both"],
    HOME: process.env.HOME!,
    TMPDIR: W,
    LC_ALL: row.lc ?? "C",
    STUB_DIR: join(s, "stub"),
  };
  if (!row.homeless) env.AC_HOME = join(s, "home");
  for (const [k, v] of Object.entries(row.env ?? {})) env[k] = v.replaceAll("@S", s);
  let cmd: string[];
  if (oracle) {
    let call = `backend_${row.fn} "$@"`;
    if (io.subshell) call = `( ${call} )`;
    if ((io.stdin ?? "inherit") === "ignore") call += " </dev/null";
    if (io.stdout === "ignore") call += " >/dev/null";
    if (io.stderr === "ignore") call += " 2>/dev/null";
    call = row.errexit ? `set -e; trap 'printf "|rc=%s" "$?"' EXIT; ${call}` : `${call}; printf "|rc=%s" "$?"`;
    cmd = ["/bin/bash", "-c", `set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; ${call}`, BIN, ...row.args];
  } else {
    const twinCall = `L.backendCall(${JSON.stringify(row.fn)}, ${JSON.stringify(row.args)}, io)`;
    cmd = [
      process.execPath,
      "-e",
      `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const io = ${JSON.stringify(io)}; const r = ${twinCall}; if (io.stdout === "pipe") writeSync(1, r.out); if (r.exited) process.exit(r.status); writeSync(1, "|rc=" + r.status);${row.errexit ? " process.exit(r.status);" : ""}`,
    ];
  }
  const t0 = Date.now();
  const r = Bun.spawnSync(cmd, { cwd: s, env, stdin: row.input === undefined ? "ignore" : Buffer.from(row.input, "latin1"), stdout: "pipe", stderr: "pipe" });
  const ms = Date.now() - t0;
  const norm = (t: string): string => t.replaceAll(s, "S");
  let err = norm(r.stderr.toString("latin1"));
  if (oracle) err = err.replace(/^.*: line [0-9]+: .*\n/gm, "");
  const hangers = read(join(s, "stub", "hang-children")).split("\n").filter(Boolean).map(Number);
  HANGERS.push(...hangers);
  // bun cannot interrupt this synchronous body: once the test's timeout passes
  // it SIGTERMs the spawn in flight and every later one at once, and two killed
  // sides compare equal.
  if (r.exitCode === null)
    throw new Error(
      `${label}: the ${oracle ? "oracle" : "twin"} side ended by ${r.signalCode} after ${ms} ms - no answer to compare (bun's per-test timeout kills a spawn with SIGTERM, and on macOS time the host spends asleep counts toward it)${err ? `; its stderr: ${err}` : ""}`,
    );
  return { out: norm(r.stdout.toString("latin1")), err, rc: r.exitCode, log: row.noLog ? "" : norm(read(join(s, "stub", "log"))), world: norm(world(join(s, "home"))), ms, hangers };
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

// Both sides of one row; the twin's answer and the oracle's are returned for a
// row's own assertions.
function pair(row: Row, label: string = row.fn): { o: Side; t: Side } {
  const r = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(r, name);
    for (const sub of ["home/state", "home/config", "stub"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o", label));
  }
  return { o: out[0]!, t: out[1]! };
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const p = pair(row, label);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc, log: x.log, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const X = (s: string): void => pane(s, "x", "px tx\n");
const ORCA_ = { AC_BACKEND: "orca" };
// A fleet state dir whose ../config/backend holds <body>.
const fleet = (body: string) => (s: string): void => {
  mkdirSync(join(s, "fleet", "state"), { recursive: true });
  mkdirSync(join(s, "fleet", "config"));
  writeFileSync(join(s, "fleet", "config", "backend"), body);
};

test("0. the harness: a side a signal ended fails its row by name - two killed sides are never compared as answers", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  // kill-caller signals its own $PPID, which the oracle's nested `$( )`
  // command substitutions shield (orca_json's own, inside
  // backend_window_alive_orca's) - the oracle reads the kill as an ordinary
  // orca_json failure and answers normally. The twin spawns orca directly,
  // no shell between it and the signal, so it is the twin that dies here.
  expect(() => same("killed", { fn: "window_alive", args: ["x"], env: ORCA_, seed: (s) => (H(s), sent(s, "kill-caller")) })).toThrow(/^killed: the twin side ended by SIGTERM after [0-9]+ ms/);
}, 30000);

test("1. the route: AC_BACKEND verbatim, config/backend trimmed, AC_FLEET_STATE cut at its first space, orca; any other name refused before anything is read or minted", () => {
  const accepted: [string, Record<string, string>, (s: string) => void][] = [
    ["AC_BACKEND orca", ORCA_, () => {}],
    ["config orca", {}, (s) => cfg(s, "backend", "orca\n")],
    ["config ' orca\\r'", {}, (s) => cfg(s, "backend", " orca\r\n")],
    ["fleet state orca", { AC_FLEET_STATE: "@S/fleet/state/" }, fleet("orca\n")],
    ["fleet state ' orca'", { AC_FLEET_STATE: "@S/fleet/state" }, fleet(" orca\n")],
    ["fleet state 'orca x'", { AC_FLEET_STATE: "@S/fleet/state" }, fleet("orca x\n")],
    ["no rung at all", {}, () => {}],
  ];
  for (const [label, env, seed] of accepted)
    for (const fn of ["window_alive", "target"] as Fn[]) {
      const p = same(`${label} ${fn}`, { fn, args: ["x"], env, seed: (s) => (X(s), sent(s, "win-px"), seed(s)) });
      if (fn === "target") expect({ label, out: p.t.out }).toEqual({ label, out: "orca:px\n|rc=0" });
    }
  const refused: [string, Record<string, string>, (s: string) => void][] = [
    ["AC_BACKEND herdr", { AC_BACKEND: "herdr" }, () => {}],
    ["AC_BACKEND tmux", { AC_BACKEND: "tmux" }, () => {}],
    ["AC_BACKEND Herdr", { AC_BACKEND: "Herdr" }, () => {}],
    ["AC_BACKEND ' herdr'", { AC_BACKEND: " herdr" }, () => {}],
    ["config tmux", {}, (s) => cfg(s, "backend", "tmux\n")],
    ["config herdr", {}, (s) => cfg(s, "backend", "herdr\n")],
    // Precedence still proven: the home's config/backend is read (and
    // refused) even though the fleet state alone would have accepted orca.
    ["fleet state under the home's knob", { AC_FLEET_STATE: "@S/fleet/state" }, (s) => (fleet("orca\n")(s), cfg(s, "backend", "herdr\n"))],
  ];
  for (const [label, env, seed] of refused)
    for (const fn of ["window_alive", "target", "focus", "capture", "mark_wait", "clear_wait", "agent_blocked", "harness_up", "send_key", "send_line"] as Fn[]) {
      const p = same(`${label} ${fn}`, {
        fn,
        args: fn === "send_key" ? ["x", "Enter"] : fn === "send_line" ? ["x", "hi"] : ["x"],
        errexit: fn === "send_key",
        env,
        seed: (s) => (rmSync(join(s, "home", "state"), { recursive: true }), sent(s, "win-px"), seed(s)),
      });
      expect({ label, fn, out: p.t.out, log: p.t.log, minted: p.t.world.includes("state/") }).toEqual({ label, fn, out: "", log: "", minted: false });
      expect(p.t.err).toMatch(/^ERROR: unsupported backend '.*' \(valid backend: orca\)\n$/);
    }
}, 30000);

test("1. the route, named: an unreadable knob prints head's line once per call - the sourced driver printed it once more at source time", () => {
  if (ROOTED) return;
  const knob = (dir: string) => (s: string) => {
    mkdirSync(join(s, dir), { recursive: true });
    mkdirSync(join(s, "fleet", "state"), { recursive: true });
    writeFileSync(join(s, dir, "backend"), "orca\n");
    chmodSync(join(s, dir, "backend"), 0o000);
  };
  for (const [label, env, seed] of [
    ["config/backend", {}, knob("home/config")],
    ["the fleet state's config/backend", { AC_FLEET_STATE: "@S/fleet/state" }, knob("fleet/config")],
  ] as const) {
    const p = pair({ fn: "window_alive", args: ["x"], env, seed: (s) => (X(s), sent(s, "win-px"), seed(s)) }, label);
    expect({ label, out: p.t.out, log: p.t.log, world: p.t.world }).toEqual({ label, out: p.o.out, log: p.o.log, world: p.o.world });
    expect(p.t.err).toMatch(/^head: .*backend: Permission denied\n$/);
    expect(p.o.err).toBe(p.t.err + p.t.err);
  }
}, 30000);

test("3. window_alive orca: connected is JSON true, a failing show asks status, no ceiling, the caller's stdin", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  const show = (body: string) => (s: string) => (H(s), sent(s, "show", body));
  const cases: [string, (s: string) => void, (keyof typeof PATHS)?][] = [
    ["connected", H],
    ["disconnected", show('{"ok":true,"result":{"terminal":{"connected":false}}}\n')],
    ["connected \"true\"", show('{"ok":true,"result":{"terminal":{"connected":"true"}}}\n')],
    ["connected missing", show('{"ok":true,"result":{}}\n')],
    ["show fails, status answers", (s) => (H(s), sent(s, "show-fails"))],
    ["both fail", (s) => (H(s), sent(s, "show-fails"), sent(s, "ostatus-fails"))],
    ["ok false", show('{"ok":false}\n')],
    ["ok false then ok true", show('{"ok":false}{"ok":true,"result":{"terminal":{"connected":true}}}\n')],
    ["ok true then garbage", show('{"ok":true,"result":{"terminal":{"connected":true}}} garbage\n')],
    ["orca absent", H, "noorca"],
    ["jq absent", H, "nojq"],
    ["no handle", () => {}],
  ];
  for (const [label, seed, path] of cases) same(label, { fn: "window_alive", args: ["x"], env: ORCA_, seed, path });
  for (const subshell of [false, true]) {
    const io: Io = { stdout: "inherit", stderr: "inherit", subshell };
    const p = same(`readstdin, show fails, subshell ${subshell}`, { fn: "window_alive", args: ["x"], env: ORCA_, io, input: "from-caller\n", seed: (s) => (H(s), sent(s, "readstdin"), sent(s, "show-fails")) });
    expect(p.t.log).toBe("orca terminal show --terminal h1 --json stdin=[from-caller]\norca status --json stdin=[]\n");
  }
  // The orca driver carries no per-call RPC ceiling of its own (ac-backend.sh
  // HUNG RPC); a 3 s call completes fine, and the retired timeout knob - set
  // here to prove it is truly inert, not merely unset - changes nothing.
  const p = same("a 3 s orca call, no ceiling", { fn: "window_alive", args: ["x"], env: { ...ORCA_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (H(s), sent(s, "orca-slow")) });
  expect(p.t.out).toBe("|rc=0");
}, 30000);

test("5. capture orca: jq prints the tail, strings raw", () => {
  const read = (body: string) => (s: string) => (pane(s, "x", "h1 tab1\n"), sent(s, "oread", body));
  const cases: [string, (s: string) => void, (keyof typeof PATHS)?][] = [
    ["string tail", read('{"ok":true,"result":{"terminal":{"tail":["a","b"]}}}\n')],
    ["mixed tail", read('{"ok":true,"result":{"terminal":{"tail":[1,{"k":"v"},null,"x\\u0000y"]}}}\n')],
    ["a string as tail", read('{"ok":true,"result":{"terminal":{"tail":"abc"}}}\n')],
    ["tail absent", read('{"ok":true,"result":{"terminal":{}}}\n')],
    ["ok false", read('{"ok":false,"result":{"terminal":{"tail":["a"]}}}\n')],
    ["the read fails", (s) => pane(s, "x", "h1 tab1\n")],
    ["no handle", () => {}],
    ["jq absent", read('{"ok":true,"result":{"terminal":{"tail":["a"]}}}\n'), "nojq"],
    ["trailing garbage", read('{"ok":true,"result":{"terminal":{"tail":["a"]}}} garbage\n')],
  ];
  for (const [label, seed, path] of cases) same(label, { fn: "capture", args: ["x", "40"], env: ORCA_, seed, path });
  same("lines absent", { fn: "capture", args: ["x"], env: ORCA_, seed: read('{"ok":true,"result":{"terminal":{"tail":["a"]}}}\n') });
  same("the drain's io", { fn: "capture", args: ["x", "40"], env: ORCA_, io: { stdin: "inherit", stdout: "pipe", stderr: "ignore" }, seed: read('{"ok":true,"result":{"terminal":{"tail":["a","b"]}}}\n') });
}, 30000);

test("6. target: the handle's bytes behind the backend's prefix, never a call", () => {
  for (const [label, seed] of [
    ["present", (s: string) => pane(s, "x", "h1 t1\n")],
    ["absent", () => {}],
    ["blank", (s: string) => pane(s, "x", "\n")],
    ["one field", (s: string) => pane(s, "x", "h1\n")],
    ["a 0xE9 byte", (s: string) => pane(s, "x", "h\xe9 t\n")],
  ] as const) {
    same(`${label}`, { fn: "target", args: ["x"], env: ORCA_, seed });
    same(`${label}, piped`, { fn: "target", args: ["x"], env: ORCA_, seed, io: { stdout: "pipe", stderr: "inherit" } });
  }
  same("no state dir yet", { fn: "target", args: ["x"], env: ORCA_, seed: (s) => rmSync(join(s, "home", "state"), { recursive: true }) });
  same("homeless", { fn: "target", args: ["x"], env: ORCA_, homeless: true });
}, 30000);

test("7. focus: orca's switch", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  for (const [label, seed, path] of [
    ["orca ok", H],
    ["orca fails", (s: string) => (H(s), sent(s, "switch-fails"))],
    ["orca no handle", () => {}],
    ["orca absent", H, "noorca"],
  ] as const)
    same(label, { fn: "focus", args: ["x"], env: ORCA_, seed, path: path as keyof typeof PATHS | undefined, input: "from-caller\n" });
  same("homeless", { fn: "focus", args: ["x"], env: ORCA_, homeless: true });
}, 30000);

// backend_mark_wait_orca ignores the message argument entirely and only
// ever touches the stamp file, so no RPC, hung-call or message-encoding
// case applies here (no "report-agent" call is made). The stamp file
// itself (ac_wait_file) is shared code regardless of backend, so its own
// write mechanics (an unwritable state dir, a dangling-symlink stamp) are
// proven below against orca.
test("8. mark_wait: orca touches the stamp file on a handle, ignoring the message", () => {
  for (const [label, seed] of [
    ["with a handle", (s: string) => pane(s, "x", "h1 t\n")],
    ["without one", () => {}],
    ["a dangling-symlink stamp", (s: string) => (pane(s, "x", "h1 t\n"), symlinkSync(join(s, "home", "made"), join(s, "home", "state", ".captain-wait-x")))],
  ] as const)
    same(label, { fn: "mark_wait", args: ["x", "m"], env: ORCA_, seed });
  if (!ROOTED) {
    same("state unwritable", { fn: "mark_wait", args: ["x", "m"], env: ORCA_, seed: (s) => (pane(s, "x", "h1 t\n"), chmodSync(join(s, "home", "state"), 0o555)) });
    for (const x of ["o", "t"]) chmodSync(join(W, `r${rows - 1}`, x, "home", "state"), 0o755);
  }
  same("homeless", { fn: "mark_wait", args: ["x", "m"], env: ORCA_, homeless: true });
}, 30000);

test("9. clear_wait: no stamp is no call; a stamp is released and removed", () => {
  const stamp = (s: string): void => writeFileSync(join(s, "home", "state", ".captain-wait-x"), "");
  for (const [label, seed] of [
    ["no stamp", (s: string) => pane(s, "x", "h1 t\n")],
    ["stamp and handle", (s: string) => (pane(s, "x", "h1 t\n"), stamp(s))],
    ["stamp, no handle", stamp],
    ["a dangling-symlink stamp", (s: string) => (pane(s, "x", "h1 t\n"), symlinkSync(join(s, "home", "gone"), join(s, "home", "state", ".captain-wait-x")))],
    ["a directory stamp", (s: string) => (pane(s, "x", "h1 t\n"), mkdirSync(join(s, "home", "state", ".captain-wait-x")))],
  ] as const)
    same(label, { fn: "clear_wait", args: ["x"], env: ORCA_, seed });
  same("homeless", { fn: "clear_wait", args: ["x"], env: ORCA_, homeless: true });
}, 30000);

test("10. ids: the empty id and a U+FFFD id name the same path bytes on both sides, every verb", () => {
  for (const id of ["", "�"])
    for (const fn of ["window_alive", "target", "focus", "capture", "mark_wait", "clear_wait", "agent_blocked", "harness_up", "send_key", "send_line"] as Fn[])
      same(`${JSON.stringify(id)} ${fn}`, {
        fn,
        args: [id, ...(fn === "capture" ? ["40"] : fn === "mark_wait" ? ["m"] : fn === "send_key" ? ["Enter"] : fn === "send_line" ? ["hi"] : [])],
        errexit: fn === "send_key",
        env: { ...ORCA_, AC_SEND_SETTLE: "0" },
        seed: (s) => (pane(s, id, "h1 tab1\n"), sent(s, "show", '{"ok":true,"result":{"terminal":{"connected":true}}}\n'), sent(s, "oread", "r\n"), writeFileSync(join(s, "home", "state", `.captain-wait-${id}`), "")),
      });
}, 30000);

test("11. a driver that failed to load is the oracle's 127 alone - the twin has no driver file to lose (named)", () => {
  const lab = join(W, "loadfail");
  cpSync(BIN, join(lab, "bin"), { recursive: true });
  const f = join(lab, "bin", "ac-backend-orca.sh");
  writeFileSync(f, readFileSync(f, "utf8").replace(/^backend_window_alive_orca\(\) \{/m, "backend_window_alive_orca_MISSING_DRIVER() {"));
  const s = join(W, "r-loadfail");
  mkdirSync(join(s, "home", "state"), { recursive: true });
  mkdirSync(join(s, "stub"));
  X(s);
  const r = Bun.spawnSync(
    ["/bin/bash", "-c", 'set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; backend_window_alive "$@"; printf "|rc=%s" "$?"', join(lab, "bin"), "x"],
    {
      cwd: s,
      env: { PATH: PATHS.both, HOME: process.env.HOME!, LC_ALL: "C", STUB_DIR: join(s, "stub"), AC_HOME: join(s, "home"), AC_BACKEND: "orca" },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  expect(r.stdout.toString()).toBe("|rc=127");
  expect(r.stderr.toString()).toContain("backend_window_alive_orca: command not found");
}, 30000);

const STAMP = (s: string): void => writeFileSync(join(s, "home", "state", ".captain-wait-x"), "");
const DANGLING = (s: string): void => symlinkSync(join(s, "home", "gone"), join(s, "home", "state", ".captain-wait-x"));
const and =
  (...fs: ((s: string) => void)[]) =>
  (s: string): void => {
    for (const f of fs) f(s);
  };
type Case = [string, (s: string) => void, number, (keyof typeof PATHS)?, string?];

test("13. agent_blocked orca: the stamp masks, then jq -e's own status on agentWait", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  const show = (body: string) => (s: string): void => (H(s), sent(s, "show", body));
  const WAITING = '{"ok":true,"result":{"terminal":{"agentWait":{"reason":"codex-update-prompt"}}}}\n';
  const cases: Case[] = [
    ["agentWait set", show(WAITING), 0],
    ["agentWait false is not null", show('{"ok":true,"result":{"terminal":{"agentWait":false}}}\n'), 0],
    ["agentWait null", show('{"ok":true,"result":{"terminal":{"agentWait":null}}}\n'), 1],
    ["agentWait absent", H, 1],
    ["a result jq cannot index: jq -e's 5", show('{"ok":true,"result":"x"}\n'), 5],
    ["the last document decides", show(WAITING + '{"ok":true,"result":{"terminal":{"agentWait":null}}}\n'), 1],
    ["ok false", show('{"ok":false,"result":{"terminal":{"agentWait":{}}}}\n'), 1],
    ["show fails", (s) => (H(s), sent(s, "show-fails")), 1],
    ["no handle", () => {}, 1],
    ["stamped", and(show(WAITING), STAMP), 1],
    ["a dangling-symlink stamp", and(show(WAITING), DANGLING), 0],
    ["orca absent", H, 1, "noorca"],
    ["jq absent", show(WAITING), 1, "nojq"],
  ];
  for (const [label, seed, rc, path] of cases) {
    const p = same(label, { fn: "agent_blocked", args: ["x"], env: ORCA_, seed, path });
    expect({ label, out: p.t.out }).toEqual({ label, out: `|rc=${rc}` });
  }
  const noisy = same("the noisy jq: every jq's stderr dropped", { fn: "agent_blocked", args: ["x"], env: ORCA_, seed: show(WAITING), path: "noisyjq" });
  expect(noisy.t.err).toBe("");
  for (const stdin of ["inherit", "ignore"] as const) {
    const p = same(`readline, stdin ${stdin}: show reads the caller's stdin`, { fn: "agent_blocked", args: ["x"], env: ORCA_, io: { stdin, stdout: "inherit", stderr: "inherit" }, input: "l1\nl2\n", seed: and(show(WAITING), (s) => sent(s, "readline")) });
    expect(p.t.log).toBe(`orca terminal show --terminal h1 --json line=[${stdin === "inherit" ? "l1" : ""}]\n`);
  }
  same("homeless", { fn: "agent_blocked", args: ["x"], env: ORCA_, homeless: true });
}, 30000);

test("15. harness_up orca: a shell title is a bare shell; Orca's identity, a harness glyph or tui-idle is up; anything else unobservable", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  // Non-ASCII goes in as \u escapes: sent() writes latin1.
  const term = (t: Record<string, unknown>): string =>
    `{"ok":true,"result":{"terminal":${JSON.stringify({ connected: true, ...t }).replace(/[^\x00-\x7f]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`)}}}\n`;
  const show = (t: Record<string, unknown>, next?: Record<string, unknown>) => (s: string): void => {
    H(s);
    sent(s, "show", term(t));
    if (next) sent(s, "show-next", term(next));
  };
  const wait = (body: string) => (s: string): void => sent(s, "owait", body);
  const screen = (tail: string[]) => `{"ok":true,"result":{"terminal":{"tail":${JSON.stringify(tail)}}}}\n`;
  const SAT = wait('{"ok":true,"result":{"wait":{"satisfied":true}}}\n');
  const TIMEOUT = wait('{"ok":false,"error":{"code":"timeout"}}\n');
  const READY = (s: string): void => sent(s, "oread", screen(["> ready"]));
  const CODEX = show({ title: "cwd" }, { title: "cwd", agentIdentity: "codex" });
  const GLYPHS = ["✳ Claude Code", "✻ Working", "✽", "✢", "✶", "· x", "⏺", "◐", "◓", "◑", "◒", "⠇ cwd", "⣿"];
  const cases: Case[] = [
    ["no handle", () => {}, 2],
    ["show fails", (s) => (H(s), sent(s, "show-fails")), 2],
    ["ok false", (s) => (H(s), sent(s, "show", '{"ok":false,"result":{"terminal":{"connected":true,"title":"zsh"}}}\n')), 2],
    ["disconnected", show({ connected: false, agentIdentity: "claude" }), 2],
    ['connected "true"', show({ connected: "true", title: "zsh" }), 2],
    ["a shell title", show({ title: "zsh" }), 1],
    ["a login shell by path", show({ title: "-/bin/zsh" }), 1],
    ["a shell title beats Orca's identity", show({ title: "/usr/bin/bash", agentIdentity: "claude" }), 1],
    ["a NUL inside the shell title, dropped by $( )", show({ title: "z\u0000sh" }), 1],
    ["Orca's identity", show({ title: "cwd", agentIdentity: "claude" }), 0],
    ["a dialog", show({ title: "cd", agentWait: { reason: "codex-update-prompt" } }), 0],
    ...GLYPHS.flatMap((t): Case[] => [
      [`the title ${t}`, show({ title: t }), 0],
      [`the title ${t} under UTF-8`, show({ title: t }), 0, undefined, "en_US.UTF-8"],
    ]),
    ["a glyph past the braille block", show({ title: "⤀ x" }), 2],
    ["a glyph past the braille block under UTF-8", show({ title: "⤀ x" }), 2, undefined, "en_US.UTF-8"],
    ["two dashes", show({ title: "--zsh" }), 2],
    ["a glyph title holding a slash: the path cut takes the glyph", show({ title: "✳ ~/src" }, { title: "cwd" }), 2],
    ["tui-idle satisfied", and(show({ title: "cwd" }), SAT), 0],
    ["tui-idle satisfied, the terminal envelope", and(show({ title: "cwd" }), wait('{"ok":true,"result":{"terminal":{"wait":{"satisfied":true}}}}\n')), 0],
    ["tui-idle not satisfied", and(show({ title: "cwd" }), wait('{"ok":true,"result":{"wait":{"satisfied":false}}}\n')), 2],
    ["the wait fails", show({ title: "cwd" }), 2],
    ["the second show parks on a dialog", and(show({ title: "cwd" }, { title: "cwd", agentWait: {} }), SAT), 2],
    ["the second show spins", and(show({ title: "cwd" }, { title: "✻ x" }), SAT), 2],
    ["the second show is claude idle", show({ title: "cwd" }, { title: "✳ Claude Code" }), 0],
    ["the second show fails", and(show({ title: "cwd" }), SAT, (s) => sent(s, "show-fails-next")), 2],
    ["codex: the screen unchanged across a timed-out wait", and(CODEX, READY, TIMEOUT), 0],
    ["codex: the screen changed", and(CODEX, READY, (s) => sent(s, "oread-next", screen(["> busy"])), TIMEOUT), 2],
    ["codex: no screen before", and(CODEX, TIMEOUT), 2],
    ["codex: an empty screen before", and(CODEX, (s) => sent(s, "oread", screen([])), TIMEOUT), 2],
    ["codex: a screen jq read only half of before", and(CODEX, (s) => sent(s, "oread", `${screen(["a"])}{"ok":true,"result":"x"}\n`), TIMEOUT), 2],
    ["codex: a wait error that is no timeout", and(CODEX, READY, wait('{"ok":false,"error":{"code":"not_found"}}\n')), 2],
    ["codex: satisfied", and(CODEX, READY, SAT), 0],
    ["orca absent", show({ title: "zsh" }), 2, "noorca"],
    ["jq absent", show({ title: "zsh" }), 2, "nojq"],
  ];
  for (const [label, seed, rc, path, lc] of cases) {
    const p = same(label, { fn: "harness_up", args: ["x"], env: ORCA_, seed, path, lc });
    expect({ label, out: p.t.out }).toEqual({ label, out: `|rc=${rc}` });
  }
  const stream = (s: string): void => (H(s), sent(s, "show", `{"ok":true,"result":"x"}\n${term({ title: "cwd" })}`));
  const e = same("a title jq cannot index: its error on the caller's stderr, once per title read", { fn: "harness_up", args: ["x"], env: ORCA_, seed: stream });
  expect({ out: e.t.out, err: e.t.err }).toEqual({ out: "|rc=2", err: 'jq: error (at <stdin>:1): Cannot index string with string ("terminal")\n'.repeat(2) });
  same("the same, the caller's stderr dropped", { fn: "harness_up", args: ["x"], env: ORCA_, seed: stream, io: { stdout: "inherit", stderr: "ignore" } });
  const noisy = same("the noisy jq: only the two title reads reach the caller", { fn: "harness_up", args: ["x"], env: ORCA_, seed: and(show({ title: "cwd" }), SAT), path: "noisyjq" });
  expect(noisy.t.err).toBe("jq-stderr -r .result.terminal.title // empty\n".repeat(2));
  for (const stdin of ["inherit", "ignore"] as const) {
    const p = same(`readline, stdin ${stdin}: every orca call reads the caller's stdin`, {
      fn: "harness_up",
      args: ["x"],
      env: ORCA_,
      io: { stdin, stdout: "inherit", stderr: "inherit" },
      input: "l1\nl2\nl3\nl4\nl5\nl6\n",
      seed: and(CODEX, READY, TIMEOUT, (s) => sent(s, "readline")),
    });
    const l = (n: string): string => (stdin === "inherit" ? n : "");
    expect({ out: p.t.out, log: p.t.log }).toEqual({
      out: "|rc=0",
      log:
        `orca terminal show --terminal h1 --json line=[${l("l1")}]\n` +
        `orca terminal show --terminal h1 --json line=[${l("l2")}]\n` +
        `orca terminal read --terminal h1 --limit 40 --screen --json line=[${l("l3")}]\n` +
        `orca terminal wait --terminal h1 --for tui-idle --timeout-ms 1000 --json line=[${l("l4")}]\n` +
        `orca terminal read --terminal h1 --limit 40 --screen --json line=[${l("l5")}]\n`,
    });
  }
  same("homeless", { fn: "harness_up", args: ["x"], env: ORCA_, homeless: true });
}, 60000);

// The three keys ac-send.sh's usage names, in every spelling the orca case
// map uses, with orca's flags for each.
const KEYS: [string[], string][] = [
  [["Enter", "enter"], "--enter"],
  [["Escape", "escape", "Esc", "esc"], "--text \x1b"],
  [["C-c", "c-c", "ctrl+c", "Ctrl+C"], "--interrupt"],
];
const UNKNOWN = ["ENTER", "Tab", "a b", "x\n\n"];

test("18. send_key orca: one terminal send - --enter, ESC as --text, --interrupt, else the key as --text - answering 0 or 1, no focus", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  const K = (label: string, args: string[], rc: number, log: string, row: Partial<Row> = {}): { o: Side; t: Side } => {
    const p = same(label, { fn: "send_key", args, env: ORCA_, seed: H, errexit: true, ...row });
    expect({ label, out: p.t.out, log: p.t.log }).toEqual({ label, out: `|rc=${rc}`, log });
    return p;
  };
  const pressed = (flags: string, h = "h1"): string => `orca terminal send --terminal ${h} ${flags} --json\n`;
  for (const [spellings, flags] of KEYS) for (const k of spellings) K(k, ["x", k], 0, pressed(flags));
  for (const k of UNKNOWN) K(`an unknown key ${JSON.stringify(k)}: the text, verbatim`, ["x", k], 0, pressed(`--text ${k}`));
  for (const [label, seed, rc] of [
    ["send fails", (s: string) => (H(s), sent(s, "send-fails")), 1],
    ["ok false", (s: string) => (H(s), sent(s, "send", '{"ok":false}\n')), 1],
    ["not JSON", (s: string) => (H(s), sent(s, "send", "garbage\n")), 1],
    ["ok false, then ok true: the last document decides", (s: string) => (H(s), sent(s, "send", '{"ok":false}{"ok":true}\n')), 0],
  ] as const)
    K(label, ["x", "Enter"], rc, pressed("--enter"), { seed });
  K("orca absent", ["x", "Enter"], 1, "", { path: "noorca" });
  K("jq absent", ["x", "Enter"], 1, pressed("--enter"), { path: "nojq" });
  const noisy = K("the noisy jq: its stderr dropped", ["x", "Enter"], 0, pressed("--enter"), { path: "noisyjq" });
  expect(noisy.t.err).toBe("");
  K("no handle: --terminal ''", ["x", "Enter"], 0, pressed("--enter", ""), { seed: () => {} });
  K("homeless: --terminal ''", ["x", "Enter"], 0, pressed("--enter", ""), { homeless: true });
  for (const stdin of ["inherit", "ignore"] as const)
    K(`readline, stdin ${stdin}: the send reads the caller's stdin`, ["x", "Enter"], 0, `orca terminal send --terminal h1 --enter --json line=[${stdin === "inherit" ? "l1" : ""}]\n`, {
      io: { stdin, stdout: "inherit", stderr: "inherit" },
      input: "l1\nl2\n",
      seed: (s) => (H(s), sent(s, "readline")),
    });
}, 60000);

const META = (body: string) => (s: string): void => writeFileSync(join(s, "home", "state", "x.meta"), body);
const CLAUDE = META("harness=claude\n");
const TEXT = "hello world";
const SLEPT = (v = "0"): string => `sleep ${v}\n`;

// One send_line row: both sides alike, the stub pane's composer and
// transcript included; then the twin's status and, where the row names them,
// its stderr and log. env and seed always come from the caller (OSL's own
// orca defaults) - there is no second driver left to default to here.
function SL(label: string, rc: number, want: { err?: string; log?: string }, row: Partial<Row> = {}): { o: Side; t: Side; cmp: string; ui: string; ocmp: string; oui: string } {
  const p = same(label, { fn: "send_line", args: ["x", TEXT], ...row });
  const r = join(W, `r${rows - 1}`);
  const at = (x: string, f: string): string => read(join(r, x, "stub", f));
  const screen = (x: string) => ({ cmp: at(x, "cmp-px"), ui: at(x, "ui-px"), ocmp: at(x, "ocmp-h1"), oui: at(x, "oui-h1") });
  expect({ label, ...screen("t") }).toEqual({ label, ...screen("o") });
  const got: Record<string, string> = { label, out: p.t.out };
  if (want.err !== undefined) got.err = p.t.err;
  if (want.log !== undefined) got.log = p.t.log;
  expect(got).toEqual({ label, out: `|rc=${rc}`, ...want });
  return { ...p, ...screen("t") };
}

// orca's own composer and strand-retry mechanics (OSHOW/OREAD/OENTER's
// pending check, tests 23-27 below) are proven end to end against orca's
// actual driver there, so no separate case is needed here.

const OUI = (s: string): void => (pane(s, "x", "h1 tab1\n"), sent(s, "oui-h1", "> earlier turn\n"), sent(s, "ocmp-h1"));
const OQUICK = { ...ORCA_, AC_SEND_SETTLE: "0" };
const L1 = (t: string): string => Buffer.from(t).toString("latin1");
const OSHOW = (h = "h1"): string => `orca terminal show --terminal ${h} --json\n`;
const OREAD = (h = "h1"): string => `orca terminal read --terminal ${h} --limit 15 --screen --json\n`;
const OENTER = (h = "h1"): string => `orca terminal send --terminal ${h} --enter --json\n`;
// The dialog guard, then the one prompt send.
const OSENT = (t = TEXT, h = "h1"): string => OSHOW(h) + `orca terminal send --terminal ${h} --text ${t} --enter --wait-submit 10 --json\n`;
// A pending check's read that finds the text still in the composer, then the
// dialog check, the retry Enter and its settle.
const PENDING = (v = "0"): string => OREAD() + OSHOW() + OENTER() + SLEPT(v);
const OSAYS = {
  dialog:
    "ac-backend: a DIALOG owns the pane of orca:h1 - the text was not submitted and no Enter was pressed into the dialog (an Enter would ACCEPT the highlighted option). Peek it (ac-peek.sh x) and answer deliberately with ac-send.sh x --key <key>\n",
  unverified: "ac-backend: no delivery receipt from orca:h1 - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh x)\n",
  stranded: "ac-backend: submit not acknowledged by orca:h1 - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh x --key Enter)\n",
};
const OSL = (label: string, rc: number, want: { err?: string; log?: string }, row: Partial<Row> = {}) => SL(label, rc, want, { env: OQUICK, seed: OUI, ...row });
const WAITING = '{"ok":true,"result":{"terminal":{"connected":true,"agentWait":{"reason":"permission"}}}}\n';
const NO_WAIT = '{"ok":true,"result":{"terminal":{"connected":true,"agentWait":null}}}\n';
// Orca's receipts (probe 2026-11-17): an idle agent's observed turn, a busy
// one's queued prompt.
const RECEIPT = (stages: string): string => `{"ok":true,"result":{"send":{"prompt":{"stages":${stages},"provider":"claude","observation":"supported"}}}}\n`;
const SEEN = RECEIPT('["input_accepted","turn_started"]');
const QUEUED = RECEIPT('["input_accepted"]');

test("23. send_line orca: one prompt send behind the dialog guard - an observed receipt 0, a refused prompt the dialog's 1, no receipt 2, an unobserved one the pending check", () => {
  const seen = OSL("observed, the turn started", 0, { err: "", log: OSENT() }, { seed: and(OUI, (s) => sent(s, "send", SEEN)) });
  expect({ cmp: seen.ocmp, ui: seen.oui }).toEqual({ cmp: "", ui: "> earlier turn\n> hello world\n" });
  const queued = OSL("observed, queued mid-turn: sent, never re-pressed", 0, { err: "", log: OSENT() }, { seed: and(OUI, (s) => sent(s, "send", QUEUED), (s) => sent(s, "drop-enters", "99")) });
  expect(queued.ocmp).toBe("hello world");
  const blind = OSL("unobserved, the text left the composer: sent", 0, { err: "", log: OSENT() + OREAD() });
  expect(blind.oui).toBe("> earlier turn\n> hello world\n");
  OSL("several arguments: joined by one space", 0, { log: OSENT("a  b c") + OREAD() }, { args: ["x", "a ", "b", "c"] });
  const none = OSL("an empty message: an empty prompt, never pending", 0, { log: OSENT("") + OREAD() }, { args: ["x", ""] });
  expect(none.oui).toBe("> earlier turn\n> \n");
  OSL("no text argument at all: the same", 0, { log: OSENT("") + OREAD() }, { args: ["x"] });
  const lost = OSL("unobserved, every Enter dropped: two retry Enters, then NOT confirmed", 1, { err: OSAYS.stranded, log: OSENT() + PENDING().repeat(2) + OREAD() }, { seed: and(OUI, (s) => sent(s, "drop-enters", "99")) });
  expect({ cmp: lost.ocmp, ui: lost.oui }).toEqual({ cmp: "hello world", ui: "> earlier turn\n" });
  OSL("the stranded line, the caller's stderr dropped: silent", 1, { err: "" }, { seed: and(OUI, (s) => sent(s, "drop-enters", "99")), io: { stdout: "inherit", stderr: "ignore" } });
  const refused = OSL("agent_prompt_blocked: the dialog's verdict, nothing typed or pressed", 1, { err: OSAYS.dialog, log: OSENT() }, { seed: and(OUI, (s) => sent(s, "prompt-blocked")) });
  expect({ cmp: refused.ocmp, ui: refused.oui }).toEqual({ cmp: "", ui: "> earlier turn\n" });
  const guarded = OSL("a dialog at the guard: refused before the send", 1, { err: OSAYS.dialog, log: OSHOW() }, { seed: and(OUI, (s) => sent(s, "show", WAITING)) });
  expect(guarded.ocmp).toBe("");
  OSL("the dialog, the caller's stderr dropped: silent", 1, { err: "" }, { seed: and(OUI, (s) => sent(s, "show", WAITING)), io: { stdout: "inherit", stderr: "ignore" } });
  for (const [label, seed] of [
    ["the send fails silently", (s: string) => sent(s, "send-fails")],
    ["the text refused", (s: string) => sent(s, "text-fails")],
    ["ok:false with no code", (s: string) => sent(s, "send", '{"ok":false}\n')],
    ["another error code", (s: string) => sent(s, "send", '{"ok":false,"error":{"code":"terminal_not_writable"}}\n')],
    ["not JSON", (s: string) => sent(s, "send", "garbage\n")],
    ["named: two documents, two verdicts - neither stands alone", (s: string) => sent(s, "send", `{"ok":false}${SEEN}`)],
  ] as const)
    OSL(`no receipt (${label}): UNVERIFIED, never resent`, 2, { err: OSAYS.unverified, log: OSENT() }, { seed: and(OUI, seed) });
  OSL("no receipt, the caller's stderr dropped: silent", 2, { err: "" }, { seed: and(OUI, (s) => sent(s, "send-fails")), io: { stdout: "inherit", stderr: "ignore" } });
  const draft = OSL("a claude meta and a draft: the text lands after the draft", 0, { log: OSENT() + OREAD() }, { seed: and(OUI, CLAUDE, (s) => sent(s, "ocmp-h1", "old draft")) });
  expect(draft.oui).toBe("> earlier turn\n> old drafthello world\n");
}, 120000);

test("24. send_line orca: an unobserved text is checked pending between the composer's rules - up to two retry Enters, each behind the dialog guard; a dialog refuses, 1", () => {
  const popups = (n: string) => and(OUI, (s) => sent(s, "popups", n));
  const once = OSL("a popup eats the Enter: pending, one retry Enter, sent", 0, { err: "", log: OSENT() + PENDING() + OREAD() }, { seed: popups("1") });
  expect(once.oui).toBe("> earlier turn\n> hello world\n");
  OSL("two popups: two retries, sent", 0, { log: OSENT() + PENDING().repeat(2) + OREAD() }, { seed: popups("2") });
  const stuck = OSL("three popups: still pending after two retries - stranded", 1, { err: OSAYS.stranded, log: OSENT() + PENDING().repeat(2) + OREAD() }, { seed: popups("3") });
  expect(stuck.ocmp).toBe("hello world");
  OSL("a dialog that appears at the retry's guard: 1", 1, { err: OSAYS.dialog, log: OSENT() + OREAD() + OSHOW() }, { seed: and(popups("1"), (s) => sent(s, "show", NO_WAIT), (s) => sent(s, "show-next", WAITING)) });
  for (const [label, show, rc] of [
    ["agentWait false is not null: a dialog", '{"ok":true,"result":{"terminal":{"agentWait":false}}}\n', 1],
    ["agentWait null: no dialog", NO_WAIT, 0],
    ["agentWait absent: no dialog", '{"ok":true,"result":{"terminal":{}}}\n', 0],
    ["ok false: no dialog", '{"ok":false,"result":{"terminal":{"agentWait":{}}}}\n', 0],
    ["a result jq cannot index: no dialog", '{"ok":true,"result":"x"}\n', 0],
    ["the last document decides", WAITING + NO_WAIT, 0],
    ["not JSON: no dialog", "garbage\n", 0],
  ] as const)
    OSL(label, rc, { err: rc ? OSAYS.dialog : "", log: rc ? OSHOW() : OSENT() + OREAD() }, { seed: and(OUI, (s) => sent(s, "show", show)) });
  OSL("the show fails: no dialog", 0, { log: OSENT() + OREAD() }, { seed: and(OUI, (s) => sent(s, "show-fails")) });
  const left = OSL("no rules on screen: pending is never claimed - sent, the text left", 0, { log: OSENT() + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "norules")) });
  expect(left.ocmp).toBe("hello world");
  OSL("one rule: the same", 0, { log: OSENT() + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "onerule")) });
  const R = L1(RULE);
  OSL("one rule holding the text: the same", 0, { log: OSENT() + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R} hello world\n`)) });
  OSL("named: two adjacent rules - sed's reversed range prints the second rule, not pending", 0, { log: OSENT() + OREAD() }, {
    seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R}\n${R}\n`)),
  });
  OSL("named: the same, the second rule holding the text - pending, and so on every read after: stranded", 1, { err: OSAYS.stranded }, {
    seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R}\n${R} hello world\n`)),
  });
  const framed = (turns: number) => (s: string): void => sent(s, "oui-h1", `${R}\n${Array.from({ length: turns }, (_, i) => `> turn ${i}\n`).join("")}`);
  OSL("a transcript rule beyond the last 15 lines is cut: one rule, not pending", 0, { log: OSENT() + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "onerule"), framed(20)) });
  const echo = OSL("named: a transcript rule within them frames the echo of the submitted line - it reads pending, stranded though delivered", 1, { err: OSAYS.stranded }, { seed: and(popups("1"), (s) => sent(s, "onerule"), framed(2)) });
  expect(echo.oui).toBe(`${R}\n> turn 0\n> turn 1\n> hello world\n> \n`);
  const long = "y".repeat(100);
  OSL("the text's first 60 characters on screen: pending, the retry", 0, { log: OSENT(long) + PENDING() + OREAD() }, { args: ["x", long], seed: and(popups("1"), (s) => sent(s, "keep-head", "60")) });
  OSL("59 on screen: not pending", 0, { log: OSENT(long) + OREAD() }, { args: ["x", long], seed: and(popups("1"), (s) => sent(s, "keep-head", "59")) });
  OSL("LFs and space runs squeezed on both sides: pending", 0, { log: OSENT("a  b\nc") + PENDING() + OREAD() }, { args: ["x", "a  b\nc"], seed: popups("1") });
  const e = "é".repeat(70);
  for (const [lc, pending] of [["C", true], ["en_US.UTF-8", false]] as const)
    OSL(`70 x é, 30 on screen, under ${lc}: the 60-${lc === "C" ? "byte head is" : "character head is not"} pending`, 0, { log: OSENT(L1(e)) + (pending ? PENDING() : "") + OREAD() }, {
      args: ["x", e],
      lc,
      seed: and(popups("1"), (s) => sent(s, "keep-head", "60")),
    });
  OSL("the pending check's read fails: not pending, sent", 0, { log: OSENT() + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "read-fails-from", "1")) });
}, 180000);

test("25. send_line orca: one send whatever the size or the locale - no chunks", () => {
  const x = (n: number): string => "x".repeat(n);
  for (const n of [512, 513, 4871]) {
    const p = OSL(`${n} characters: one send`, 0, { log: OSENT(x(n)) + OREAD() }, { args: ["x", x(n)] });
    expect(p.oui).toBe(`> earlier turn\n> ${x(n)}\n`);
  }
  const e = "é".repeat(600);
  for (const lc of ["C", "en_US.UTF-8"]) OSL(`600 x é under ${lc}: one send`, 0, { log: OSENT(L1(e)) + OREAD() }, { args: ["x", e], lc });
  const lines = Array.from({ length: 62 }, (_, i) => `line ${i}`).join("\n");
  OSL("62 lines: one send", 0, { log: OSENT(lines) + OREAD() }, { args: ["x", lines] });
}, 60000);

test("26. send_line orca: no handle, the caller's stdin for every send, homeless, orca or jq absent", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  OSL("a screen jq cannot iterate: not pending, sent", 0, { log: OSENT() + OREAD() }, { seed: (s) => (H(s), sent(s, "oread", '{"ok":true,"result":"x"}\n')) });
  OSL("no handle: every call with --terminal '', the runtime's refusal UNVERIFIED", 2, { err: OSAYS.unverified.replace("orca:h1", "orca:"), log: OSENT(TEXT, "") }, { seed: (s) => sent(s, "send", '{"ok":false}\n') });
  OSL("one field: the handle alone", 0, { log: OSENT() + OREAD() }, { seed: and(OUI, (s) => pane(s, "x", "h1\n")) });
  for (const [label, io, top] of [
    ["top level: every SEND call reads the caller's stdin, the reads stay /dev/null", { stdout: "inherit", stderr: "inherit" }, true],
    ["in a subshell: the same", { stdout: "inherit", stderr: "inherit", subshell: true }, true],
    ["stdin ignored", { stdin: "ignore", stdout: "inherit", stderr: "inherit" }, false],
  ] as const) {
    const at = (l: string, n: number): string => l.replace(/\n$/, ` line=[${top ? `l${n}` : ""}]\n`);
    const ig = (l: string): string => l.replace(/\n$/, " line=[]\n");
    // orcaScreen/orcaDialog (OSHOW/OREAD) hardcode "ignore" regardless of the
    // caller's stdin (the note above orcaScreen, src/lib.ts) - the read still
    // runs under the suite's own .readline sentinel, so it still logs an
    // EMPTY bracket, never an absent one. Only the SEND calls ever draw from
    // the real stream, so they are the only ones whose bracket can hold a
    // line and the only ones that advance its position.
    OSL(`readline, ${label}`, 0, { log: ig(OSHOW()) + at(OSENT().slice(OSHOW().length), 1) + ig(OREAD()) + ig(OSHOW()) + at(OENTER(), 2) + SLEPT() + ig(OREAD()) }, {
      io,
      input: "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
      seed: and(OUI, (s) => sent(s, "readline"), (s) => sent(s, "popups", "1")),
    });
  }
  const hl = OSL("homeless: an empty handle, the refusal per handle read", 2, {}, { homeless: true, seed: (s) => sent(s, "send", '{"ok":false}\n') });
  expect(hl.t.err.split("\n").filter((l) => l.startsWith("ERROR: AC_HOME is not set")).length).toBe(2);
  OSL("homeless, the caller's stderr dropped: silent", 2, { err: "" }, { homeless: true, io: { stdout: "inherit", stderr: "ignore" }, seed: (s) => sent(s, "send", '{"ok":false}\n') });
  OSL("orca absent: no receipt - UNVERIFIED", 2, { err: OSAYS.unverified, log: "" }, { path: "noorca" });
  const nojq = OSL("jq absent: the receipt unread, the send still lands - UNVERIFIED", 2, { err: OSAYS.unverified, log: OSENT() }, { path: "nojq" });
  expect(nojq.oui).toBe("> earlier turn\n> hello world\n");
  OSL("the noisy jq: every jq's stderr dropped", 0, { err: "", log: OSENT() + OREAD() }, { path: "noisyjq" });
  for (const id of ["", "�"]) {
    OSL(`the id ${JSON.stringify(id)}`, 0, { log: OSENT() + OREAD() }, { args: [id, TEXT], seed: and(OUI, (s) => pane(s, id, "h1 tab1\n")) });
    OSL(`the id ${JSON.stringify(id)} in the stranded line`, 1, {}, { args: [id, TEXT], seed: and(OUI, (s) => pane(s, id, "h1 tab1\n"), (s) => sent(s, "drop-enters", "99")) });
  }
}, 120000);

test("27. send_line orca: AC_SEND_SETTLE is the pause after a retry Enter, read per pause", () => {
  const d = OSL("unset: 0.4 s", 0, { log: OSENT() + PENDING("0.4") + OREAD() }, { env: ORCA_, seed: and(OUI, (s) => sent(s, "popups", "1")) });
  for (const x of [d.o, d.t]) expect(x.ms).toBeGreaterThan(350);
  OSL("empty: 0.4 s", 0, { log: OSENT() + PENDING("0.4") + OREAD() }, { env: { ...ORCA_, AC_SEND_SETTLE: "" }, seed: and(OUI, (s) => sent(s, "popups", "1")) });
  OSL("0.1 after each retry Enter", 1, { log: OSENT() + PENDING("0.1").repeat(2) + OREAD() }, { env: { ...ORCA_, AC_SEND_SETTLE: "0.1" }, seed: and(OUI, (s) => sent(s, "drop-enters", "99")) });
  OSL("an observed send: no pause at all", 0, { log: OSENT() }, { env: ORCA_, seed: and(OUI, (s) => sent(s, "send", SEEN)) });
  const bad = OSL("abc: sleep refuses every settle on the caller's stderr", 1, { log: OSENT() + PENDING("abc").repeat(2) + OREAD() }, {
    env: { ...ORCA_, AC_SEND_SETTLE: "abc" },
    seed: and(OUI, (s) => sent(s, "drop-enters", "99")),
  });
  expect(bad.t.err.split("\n").filter((l) => l.startsWith("sleep: invalid time interval")).length).toBe(2);
  OSL("abc and a strand, the caller's stderr dropped: silent", 1, { err: "" }, { env: { ...ORCA_, AC_SEND_SETTLE: "abc" }, seed: and(OUI, (s) => sent(s, "drop-enters", "99")), io: { stdout: "inherit", stderr: "ignore" } });
}, 60000);
