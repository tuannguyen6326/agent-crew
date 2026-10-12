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
// transcript, and logs its sleeps. A drift in the bash drivers turns these red.
//
// DISPUTED: the implementation of the backend verbs (the bash drivers vs src/lib.ts backendCall)
// HELD-CONSTANT: one side root per side and row seeded alike (a home at <side>/home, the stubs' sentinels and log at <side>/stub); argv; env (PATH, LC_ALL=C unless a row names UTF-8, HOME, TMPDIR, STUB_DIR, AC_HOME unless homeless, the row's own names); cwd (the side root); stdin (/dev/null, or the row's bytes); PATH = a logging sleep on send_line rows, the herdr and orca stubs (or a variant without one), a dir holding the host's jq (dropped by the jq-absent rows, a noisy wrapper of it on the noisy-jq rows), and /bin plus /usr/bin without jq, herdr or orca - no row can reach a real herdr or orca.
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

// A claude pane, when ui-<pane> exists: the transcript, then the composer
// (cmp-<pane>, folded at 40 bytes) between two rules - empty, the dim hint
// under --ansi - then a status row. send-text types into the composer (the
// last keep-tail bytes of it, or the paste file's text); an Enter submits it
// into the transcript unless the pane is unfocused (tab focus focuses it) or
// drop-enters still counts, the redraw showing on the late-th read after it;
// ctrl+u deletes the last composer row unless ctrlu-stuck. norules, onerule
// and tight (no composer row) draw a broken frame; ticker heads every screen
// with the read's number. read-fails-from and read-hangs-from count every pane
// read from 1.
const RULE = "─".repeat(12);
const HERDR = `#!/bin/sh
d="$STUB_DIR"
if [ -e "$d/readstdin" ]; then
  printf 'herdr %s [%s] stdin=[%s]\\n' "$*" "\${HERDR_SESSION:-}" "$(cat)" >>"$d/log"
elif [ -e "$d/readline" ]; then
  IFS= read -r l
  printf 'herdr %s [%s] line=[%s]\\n' "$*" "\${HERDR_SESSION:-}" "$l" >>"$d/log"
else
  printf 'herdr %s [%s]\\n' "$*" "\${HERDR_SESSION:-}" >>"$d/log"
fi
n=0
if [ "$1 $2" = "pane read" ]; then
  n=$(($(cat "$d/reads" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$d/reads"
fi
if [ -e "$d/hang" ] || [ -e "$d/hang-$2" ] || { [ -e "$d/read-hangs-from" ] && [ "$n" -ge "$(cat "$d/read-hangs-from")" ]; }; then
  ( trap '' TERM; exec /bin/sleep 97 ) &
  printf '%s\\n' "$!" >>"$d/hang-children"
  wait
  exit 0
fi
[ ! -e "$d/slow-get" ] || [ "$1 $2" != "pane get" ] || sleep 1.4
case "$1 $2" in
  "pane get") [ -e "$d/win-$3" ] || exit 1; [ ! -e "$d/get-$3" ] || cat "$d/get-$3" ;;
  "pane list") [ ! -e "$d/list-fails" ] || exit 1; if [ -e "$d/list" ]; then cat "$d/list"; else printf '{"result":{"panes":[]}}\\n'; fi ;;
  "status server") [ ! -e "$d/status-fails" ] || exit 1; if [ -e "$d/status" ]; then cat "$d/status"; else printf '{"running":true}\\n'; fi ;;
  "pane read")
    [ ! -e "$d/read-fails-from" ] || [ "$n" -lt "$(cat "$d/read-fails-from")" ] || exit 1
    [ -e "$d/ui-$3" ] || { [ -e "$d/read-$3" ] || exit 1; cat "$d/read-$3"; exit 0; }
    if [ -e "$d/lag" ]; then
      if [ "$(cat "$d/lag")" -gt 1 ]; then echo $(($(cat "$d/lag") - 1)) >"$d/lag"; else rm "$d/lag"; mv "$d/next-ui" "$d/ui-$3"; mv "$d/next-cmp" "$d/cmp-$3"; fi
    fi
    [ ! -e "$d/ticker" ] || echo "tick $n"
    cat "$d/ui-$3"
    [ -e "$d/norules" ] || [ -e "$d/onerule" ] || echo '${RULE}'
    if [ -s "$d/cmp-$3" ]; then LC_ALL=C sed -e '1s/^/❯ /' -e '2,$s/^/  /' "$d/cmp-$3"
    elif [ ! -e "$d/tight" ]; then
      case "$*" in *--ansi*) printf '❯ \\033[2mTry "fix lint errors"\\033[22m\\n' ;; *) echo '❯ Try "fix lint errors"' ;; esac
    fi
    [ -e "$d/norules" ] || echo '${RULE}'
    echo '  ? for shortcuts' ;;
  "pane send-text")
    [ ! -e "$d/text-rc" ] || exit "$(cat "$d/text-rc")"
    [ -e "$d/ui-$3" ] || exit 0
    t="$4"
    [ ! -e "$d/keep-tail" ] || t="$(printf '%s' "$t" | tail -c "$(cat "$d/keep-tail")")"
    [ ! -e "$d/paste" ] || t="$(cat "$d/paste")"
    { LC_ALL=C tr -d '\\n' <"$d/cmp-$3"; printf '%s\\n' "$t"; } | LC_ALL=C fold -w 40 | LC_ALL=C sed '/^$/d' >"$d/cmp.new"
    mv "$d/cmp.new" "$d/cmp-$3" ;;
  "tab focus") [ ! -e "$d/focus-rc" ] || exit "$(cat "$d/focus-rc")"; rm -f "$d/unfocused" ;;
  "pane report-agent") [ ! -e "$d/report-fails" ] ;;
  "pane release-agent") [ ! -e "$d/release-fails" ] ;;
  "pane process-info") [ -e "$d/pinfo-$4" ] || exit 1; cat "$d/pinfo-$4" ;;
  "pane send-keys")
    [ ! -e "$d/keys-rc" ] || exit "$(cat "$d/keys-rc")"
    [ -e "$d/ui-$3" ] || exit 0
    case "$4" in
      enter)
        if [ -e "$d/unfocused" ]; then :
        elif [ "$(cat "$d/drop-enters" 2>/dev/null || echo 0)" -gt 0 ]; then echo $(($(cat "$d/drop-enters") - 1)) >"$d/drop-enters"
        else
          { cat "$d/ui-$3"; printf '> %s\\n' "$(LC_ALL=C tr -d '\\n' <"$d/cmp-$3")"; } >"$d/next-ui"
          : >"$d/next-cmp"
          if [ -e "$d/late" ]; then mv "$d/late" "$d/lag"; else mv "$d/next-ui" "$d/ui-$3"; mv "$d/next-cmp" "$d/cmp-$3"; fi
        fi ;;
      ctrl+u) [ -e "$d/ctrlu-stuck" ] || { LC_ALL=C sed '$d' "$d/cmp-$3" >"$d/cmp.new"; mv "$d/cmp.new" "$d/cmp-$3"; } ;;
    esac ;;
  *) exit 2 ;;
esac
`;
// The send verbs' waits, logged in line with the stubs' calls and then slept.
const SLEEPS = join(W, "sleeps");
mkdirSync(SLEEPS);
writeFileSync(join(SLEEPS, "sleep"), `#!/bin/sh\nprintf 'sleep %s\\n' "$*" >>"$STUB_DIR/log"\nexec /bin/sleep "$@"\n`, { mode: 0o755 });
// An orca claude pane, when oui-<h> exists: `terminal read --screen` serves
// the last --limit lines of the screen - the transcript, a popup row while
// popups counts, the composer (ocmp-<h>, its first row behind ❯) between two
// rules, a status row - as JSON the host's jq builds. `send --text` appends
// the chunk to the composer (keep-head bytes of it at most; text-fails
// refuses it); `send --enter` submits it into the transcript unless the pane
// is unfocused (`terminal switch` focuses it), drop-enters still counts, or a
// popup eats it (the render changes, the text stays); late, norules, onerule,
// ticker and read-fails-from as the herdr pane has them, counting `terminal
// read`s.
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
    if [ -e "$d/oui-$4" ]; then
      case "$5" in
        --text)
          [ ! -e "$d/text-fails" ] || exit 1
          printf '%s' "$6" >>"$d/ocmp-$4"
          if [ -e "$d/keep-head" ]; then head -c "$(cat "$d/keep-head")" "$d/ocmp-$4" >"$d/cmp.new"; mv "$d/cmp.new" "$d/ocmp-$4"; fi ;;
        --enter)
          if [ -e "$d/unfocused" ]; then :
          elif [ "$(cat "$d/drop-enters" 2>/dev/null || echo 0)" -gt 0 ]; then echo $(($(cat "$d/drop-enters") - 1)) >"$d/drop-enters"
          elif [ "$(cat "$d/popups" 2>/dev/null || echo 0)" -gt 0 ]; then echo $(($(cat "$d/popups") - 1)) >"$d/popups"
          else
            { cat "$d/oui-$4"; printf '> %s\\n' "$(LC_ALL=C tr -d '\\n' <"$d/ocmp-$4")"; } >"$d/next-ui"
            : >"$d/next-cmp"
            if [ -e "$d/late" ]; then mv "$d/late" "$d/lag"; else mv "$d/next-ui" "$d/oui-$4"; mv "$d/next-cmp" "$d/ocmp-$4"; fi
          fi ;;
      esac
    fi
    if [ -e "$d/send" ]; then cat "$d/send"; else printf '{"ok":true}\\n'; fi ;;
  *) exit 2 ;;
esac
`;
// One stub dir per PATH variant: both CLIs, herdr absent, herdr not
// executable, orca absent; and a jq that names each call on its stderr, so a
// row shows which jq's stderr reached the caller.
function stubs(name: string, herdr: number | null, orca: boolean): string {
  const d = join(W, name);
  mkdirSync(d);
  if (herdr !== null) writeFileSync(join(d, "herdr"), HERDR, { mode: herdr });
  if (orca) writeFileSync(join(d, "orca"), ORCA, { mode: 0o755 });
  return d;
}
const NOISY = join(W, "noisyjq");
mkdirSync(NOISY);
writeFileSync(join(NOISY, "jq"), `#!/bin/sh\nprintf 'jq-stderr %s\\n' "$*" >&2\nexec '${Bun.which("jq")}' "$@"\n`, { mode: 0o755 });
const PATHS = {
  both: `${stubs("stubs", 0o755, true)}:${JQ}:${BASE}`,
  nojq: `${join(W, "stubs")}:${BASE}`,
  noherdr: `${stubs("stubs-noherdr", null, true)}:${JQ}:${BASE}`,
  noexec: `${stubs("stubs-noexec", 0o644, true)}:${JQ}:${BASE}`,
  noorca: `${stubs("stubs-noorca", 0o755, false)}:${JQ}:${BASE}`,
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
type Side = { out: string; err: string; rc: number | null; log: string; world: string; ms: number; hangers: number[] };

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

function side(row: Row, s: string, oracle: boolean): Side {
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
    cmd = [
      process.execPath,
      "-e",
      `import { writeSync } from "node:fs"; const L = await import(${JSON.stringify(LIB)}); const io = ${JSON.stringify(io)}; const r = L.backendCall(${JSON.stringify(row.fn)}, ${JSON.stringify(row.args)}, io); if (io.stdout === "pipe") writeSync(1, r.out); if (r.exited) process.exit(r.status); writeSync(1, "|rc=" + r.status);${row.errexit ? " process.exit(r.status);" : ""}`,
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
function pair(row: Row): { o: Side; t: Side } {
  const r = join(W, `r${rows++}`);
  const out: Side[] = [];
  for (const name of ["o", "t"]) {
    const s = join(r, name);
    for (const sub of ["home/state", "home/config", "stub"]) mkdirSync(join(s, sub), { recursive: true });
    row.seed?.(s);
    out.push(side(row, s, name === "o"));
  }
  return { o: out[0]!, t: out[1]! };
}

function same(label: string, row: Row): { o: Side; t: Side } {
  const p = pair(row);
  const view = (x: Side) => ({ label, out: x.out, err: x.err, rc: x.rc, log: x.log, world: x.world });
  expect(view(p.t)).toEqual(view(p.o));
  return p;
}

const X = (s: string): void => pane(s, "x", "px tx\n");
const HERDR_ = { AC_BACKEND: "herdr" };
const ORCA_ = { AC_BACKEND: "orca" };
// A fleet state dir whose ../config/backend holds <body>.
const fleet = (body: string) => (s: string): void => {
  mkdirSync(join(s, "fleet", "state"), { recursive: true });
  mkdirSync(join(s, "fleet", "config"));
  writeFileSync(join(s, "fleet", "config", "backend"), body);
};

test("1. the route: AC_BACKEND verbatim, config/backend trimmed, AC_FLEET_STATE cut at its first space, herdr; any other name refused before anything is read or minted", () => {
  const accepted: [string, Record<string, string>, (s: string) => void, string][] = [
    ["AC_BACKEND herdr", HERDR_, () => {}, "herdr"],
    ["AC_BACKEND orca", ORCA_, () => {}, "orca"],
    ["config orca", {}, (s) => cfg(s, "backend", "orca\n"), "orca"],
    ["config ' orca\\r'", {}, (s) => cfg(s, "backend", " orca\r\n"), "orca"],
    ["fleet state orca", { AC_FLEET_STATE: "@S/fleet/state/" }, fleet("orca\n"), "orca"],
    ["fleet state ' orca'", { AC_FLEET_STATE: "@S/fleet/state" }, fleet(" orca\n"), "herdr"],
    ["fleet state 'orca x'", { AC_FLEET_STATE: "@S/fleet/state" }, fleet("orca x\n"), "orca"],
    ["fleet state under the home's knob", { AC_FLEET_STATE: "@S/fleet/state" }, (s) => (fleet("orca\n")(s), cfg(s, "backend", "herdr\n")), "herdr"],
    ["no rung at all", {}, () => {}, "herdr"],
  ];
  for (const [label, env, seed, b] of accepted)
    for (const fn of ["window_alive", "target"] as Fn[]) {
      const p = same(`${label} ${fn}`, { fn, args: ["x"], env, seed: (s) => (X(s), sent(s, "win-px"), seed(s)) });
      if (fn === "target") expect({ label, out: p.t.out }).toEqual({ label, out: b === "herdr" ? "herdr:pane-px\n|rc=0" : "orca:px\n|rc=0" });
    }
  const refused: [string, Record<string, string>, (s: string) => void][] = [
    ["AC_BACKEND tmux", { AC_BACKEND: "tmux" }, () => {}],
    ["AC_BACKEND Herdr", { AC_BACKEND: "Herdr" }, () => {}],
    ["AC_BACKEND ' herdr'", { AC_BACKEND: " herdr" }, () => {}],
    ["config tmux", {}, (s) => cfg(s, "backend", "tmux\n")],
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
      expect(p.t.err).toMatch(/^ERROR: unsupported backend '.*' \(valid backends: herdr, orca; tmux\/wezterm were removed 2026-07-17\)\n$/);
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
    const p = pair({ fn: "window_alive", args: ["x"], env, seed: (s) => (X(s), sent(s, "win-px"), seed(s)) });
    expect({ label, out: p.t.out, log: p.t.log, world: p.t.world }).toEqual({ label, out: p.o.out, log: p.o.log, world: p.o.world });
    expect(p.t.err).toMatch(/^head: .*backend: Permission denied\n$/);
    expect(p.o.err).toBe(p.t.err + p.t.err);
  }
}, 30000);

test("2. window_alive herdr: pane get, then the list's verdict, then the server's status; no handle is gone with no call", () => {
  const list = (body: string) => (s: string) => sent(s, "list", body);
  const cases: [string, (s: string) => void][] = [
    ["alive", (s) => (X(s), sent(s, "win-px"))],
    ["list without the pane", X],
    ["get fails, the list has it", (s) => (X(s), list('{"result":{"panes":[{"pane_id":"px"}]}}\n')(s))],
    ["list fails, running false", (s) => (X(s), sent(s, "list-fails"), sent(s, "status", '{"running":false}\n'))],
    ["list fails, running \"false\"", (s) => (X(s), sent(s, "list-fails"), sent(s, "status", '{"running":"false"}\n'))],
    ["list fails, running true", (s) => (X(s), sent(s, "list-fails"))],
    ["list fails, status not JSON", (s) => (X(s), sent(s, "list-fails"), sent(s, "status", "garbage\n"))],
    ["list fails, status fails", (s) => (X(s), sent(s, "list-fails"), sent(s, "status-fails"))],
    ["list without panes", (s) => (X(s), list('{"result":{}}\n')(s))],
    ["list then garbage", (s) => (X(s), list('{"result":{"panes":[{"pane_id":"px"}]}} garbage\n')(s))],
    ["two list documents", (s) => (X(s), list('{"result":{"panes":[]}}\n{"result":{"panes":[]}}\n')(s))],
    ["a numeric pane_id", (s) => (pane(s, "x", "7 t\n"), list('{"result":{"panes":[{"pane_id":7}]}}\n')(s))],
    ["no handle file", () => {}],
    ["a blank first line", (s) => pane(s, "x", "\npx tx\n")],
    ["a CR handle", (s) => (pane(s, "x", "px\r\n"), sent(s, "win-px"))],
    ["one field", (s) => (pane(s, "x", "px\n"), sent(s, "win-px"))],
    ["tab-separated, leading blanks", (s) => (pane(s, "x", " \t px\ttx\n"), sent(s, "win-px"))],
    ["a NUL inside the handle", (s) => (pane(s, "x", "p\0x tx\n"), sent(s, "win-px"), sent(s, "win-p"))],
    ["the handle a directory", (s) => mkdirSync(join(s, "home", "state", ".pane-x"))],
  ];
  for (const [label, seed] of cases) same(label, { fn: "window_alive", args: ["x"], env: HERDR_, seed });
  same("the empty id", { fn: "window_alive", args: [""], env: HERDR_, seed: (s) => (pane(s, "", "px tx\n"), sent(s, "win-px")) });
  same("id ../x", { fn: "window_alive", args: ["../x"], env: HERDR_, seed: (s) => (mkdirSync(join(s, "home", "state", ".pane-..")), pane(s, "../x", "px t\n"), sent(s, "win-px")) });
  same("a U+FFFD id", { fn: "window_alive", args: ["a�b"], env: HERDR_, seed: (s) => (writeFileSync(join(s, "home", "state", ".pane-a�b"), "px t\n"), sent(s, "win-px")) });
}, 30000);

test("2. window_alive herdr: the session, jq and herdr absent, a herdr that is not executable, stdin by position (W6), homeless", () => {
  const gone = (s: string): void => X(s);
  same("AC_HERDR_SESSION", { fn: "window_alive", args: ["x"], env: { ...HERDR_, AC_HERDR_SESSION: "s1" }, seed: gone });
  same("config/herdr-session", { fn: "window_alive", args: ["x"], env: HERDR_, seed: (s) => (gone(s), cfg(s, "herdr-session", " s2 \n")) });
  same("AC_HERDR_SESSION over the knob", { fn: "window_alive", args: ["x"], env: { ...HERDR_, AC_HERDR_SESSION: "s1" }, seed: (s) => (gone(s), cfg(s, "herdr-session", "s2\n")) });
  if (!ROOTED)
    same("an unreadable herdr-session knob, stderr passed", {
      fn: "window_alive",
      args: ["x"],
      env: HERDR_,
      seed: (s) => (gone(s), cfg(s, "herdr-session", "s2\n"), cfg(s, "herdr-rpc-timeout", "3\n"), chmodSync(join(s, "home", "config", "herdr-session"), 0), chmodSync(join(s, "home", "config", "herdr-rpc-timeout"), 0)),
    });
  same("herdr absent", { fn: "window_alive", args: ["x"], env: HERDR_, seed: gone, path: "noherdr" });
  same("herdr not executable", { fn: "window_alive", args: ["x"], env: HERDR_, seed: gone, path: "noexec" });
  same("jq absent, pane get hits", { fn: "window_alive", args: ["x"], env: HERDR_, seed: (s) => (X(s), sent(s, "win-px")), path: "nojq" });
  same("jq absent, gone", { fn: "window_alive", args: ["x"], env: HERDR_, seed: gone, path: "nojq" });
  for (const subshell of [false, true]) {
    const io: Io = { stdout: "inherit", stderr: "inherit", subshell };
    const p = same(`readstdin, subshell ${subshell}`, { fn: "window_alive", args: ["x"], env: HERDR_, io, input: "from-caller\n", seed: (s) => (gone(s), sent(s, "readstdin")) });
    expect(p.t.log.split("\n")[0]).toBe(`herdr pane get px [] stdin=[${subshell ? "" : "from-caller"}]`);
    same(`readstdin, list fails, subshell ${subshell}`, { fn: "window_alive", args: ["x"], env: HERDR_, io, input: "from-caller\n", seed: (s) => (gone(s), sent(s, "readstdin"), sent(s, "list-fails")) });
    same(`readstdin, stdin ignored, subshell ${subshell}`, { fn: "window_alive", args: ["x"], env: HERDR_, io: { ...io, stdin: "ignore" }, input: "from-caller\n", seed: (s) => (gone(s), sent(s, "readstdin")) });
  }
  same("the guard's io: stdin and stdout dropped, a subshell", { fn: "window_alive", args: ["x"], env: HERDR_, io: { stdin: "ignore", stdout: "ignore", stderr: "ignore", subshell: true }, seed: (s) => (X(s), sent(s, "win-px")) });
  same("deputy's io: stdout piped", { fn: "window_alive", args: ["x"], env: HERDR_, io: { stdin: "ignore", stdout: "pipe", stderr: "inherit", subshell: true }, seed: gone });
  same("homeless", { fn: "window_alive", args: ["x"], env: HERDR_, homeless: true });
  // Named (W17): a handle byte that is not UTF-8 reaches herdr's argv as
  // U+FFFD where the bash passed the byte.
  const b17 = pair({ fn: "window_alive", args: ["x"], env: HERDR_, seed: (s) => pane(s, "x", "p\xe9 t\n") });
  expect({ out: b17.t.out, err: b17.t.err, o: b17.o.log, t: b17.t.log }).toEqual({
    out: b17.o.out,
    err: b17.o.err,
    o: "herdr pane get p\xe9 []\nherdr pane list []\n",
    t: "herdr pane get p\xef\xbf\xbd []\nherdr pane list []\n",
  });
  const p = pair({ fn: "window_alive", args: ["x"], env: { ...HERDR_, AC_HOME: "@S/nope" } });
  // Named (the HOME RESOLUTION ruling): an AC_HOME cd cannot enter is the
  // twin's own line where the shell printed cd's.
  expect({ out: p.t.out, log: p.t.log, err: p.t.err }).toEqual({ out: p.o.out, log: p.o.log, err: "ERROR: AC_HOME is not a readable directory: S/nope\n" });
  expect(p.o.err).toBe("");
}, 30000);

test("2. window_alive herdr: a hung herdr is three bounded calls, unreadable, and no grandchild survives", () => {
  const p = same("hang", { fn: "window_alive", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (X(s), sent(s, "hang")) });
  expect(p.t.out).toBe("|rc=2");
  expect(p.t.log).toBe("herdr pane get px []\nherdr pane list []\nherdr status server --json []\n");
  for (const x of [p.o, p.t]) {
    expect(x.ms).toBeLessThan(6000);
    expect(x.ms).toBeGreaterThan(2900);
    expect(x.hangers.length).toBe(3);
    expect(x.hangers.filter(alive)).toEqual([]);
  }
}, 30000);

test("2. window_alive herdr: the ceiling's grammar - a pane get that answers in 1.4 s, timed out at 1 s", () => {
  const slow = (s: string): void => (X(s), sent(s, "win-px"), sent(s, "slow-get"));
  for (const [label, env, seed, rc] of [
    ["1", { AC_HERDR_RPC_TIMEOUT: "1" }, slow, 1],
    ["config 1", {}, (s: string) => (slow(s), cfg(s, "herdr-rpc-timeout", "1\n")), 1],
    ["0 is the default", { AC_HERDR_RPC_TIMEOUT: "0" }, slow, 0],
    ["abc is the default, the knob unread", { AC_HERDR_RPC_TIMEOUT: "abc" }, (s: string) => (slow(s), cfg(s, "herdr-rpc-timeout", "1\n")), 0],
    ["' 2' is the default", { AC_HERDR_RPC_TIMEOUT: " 2" }, slow, 0],
    ["007 is seven", { AC_HERDR_RPC_TIMEOUT: "007" }, slow, 0],
    ["2147483647 sleeps", { AC_HERDR_RPC_TIMEOUT: "2147483647" }, slow, 0],
  ] as const) {
    const p = same(label, { fn: "window_alive", args: ["x"], env: { ...HERDR_, ...env }, seed });
    expect({ label, out: p.t.out }).toEqual({ label, out: `|rc=${rc}` });
  }
}, 60000);

test("2. window_alive herdr: a ceiling sleep(1) will not take fires at once - every call 124, unreadable", () => {
  for (const t of ["00", "2147483648"]) {
    // The kill races the stub's own log line, so the log is not compared.
    const p = same(t, { fn: "window_alive", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: t }, seed: (s) => (X(s), sent(s, "win-px")), noLog: true });
    expect(p.t.out).toBe("|rc=2");
    same(`${t} focus`, { fn: "focus", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: t }, seed: X, noLog: true });
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
  const p = same("a 3 s orca under a 1 s herdr ceiling", { fn: "window_alive", args: ["x"], env: { ...ORCA_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (H(s), sent(s, "orca-slow")) });
  expect(p.t.out).toBe("|rc=0");
}, 30000);

test("4. capture herdr: the read through `$( )` and tail, fetching 200 at least", () => {
  const read = (body: string) => (s: string) => (X(s), sent(s, "read-px", body));
  const sixty = Array.from({ length: 60 }, (_, i) => `line ${i}`).join("\n") + "\n";
  const cases: [string, string[], (s: string) => void, string?][] = [
    ["three lines", ["x", "40"], read("a\nb\nc\n")],
    ["sixty lines, the last 40", ["x", "40"], read(sixty)],
    ["trailing blank lines", ["x", "40"], read("a\n\n\n")],
    ["a NUL", ["x", "40"], read("a\0b\n")],
    ["CR", ["x", "40"], read("a\r\nb\r\n")],
    ["a 0xE9 byte", ["x", "40"], read("caf\xe9\n")],
    ["a 0xE9 byte under UTF-8", ["x", "40"], read("caf\xe9\n"), "en_US.UTF-8"],
    ["an empty read", ["x", "40"], read("")],
    ["the read fails", ["x", "40"], X],
    ["no handle", ["x", "40"], () => {}],
    ["lines 250", ["x", "250"], read(sixty)],
    ["lines ''", ["x", ""], read(sixty)],
    ["lines absent", ["x"], read(sixty)],
    ["lines 3", ["x", "3"], read(sixty)],
    ["lines abc", ["x", "abc"], read(sixty)],
  ];
  for (const [label, args, seed, lc] of cases) same(label, { fn: "capture", args, env: HERDR_, seed, lc });
  same("the drain's io: stdout piped, stderr dropped", { fn: "capture", args: ["x", "40"], env: HERDR_, io: { stdin: "inherit", stdout: "pipe", stderr: "ignore" }, seed: read("a\nb\n") });
  same("readstdin: the read is nested", { fn: "capture", args: ["x", "40"], env: HERDR_, input: "from-caller\n", seed: (s) => (read("a\n")(s), sent(s, "readstdin")) });
  same("jq absent", { fn: "capture", args: ["x", "40"], env: HERDR_, seed: read("a\n"), path: "nojq" });
  const p = same("hang", { fn: "capture", args: ["x", "40"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (X(s), sent(s, "hang")) });
  expect(p.t.out).toBe("|rc=1");
  for (const x of [p.o, p.t]) expect(x.hangers.filter(alive)).toEqual([]);
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
  for (const env of [HERDR_, ORCA_])
    for (const [label, seed] of [
      ["present", (s: string) => pane(s, "x", "h1 t1\n")],
      ["absent", () => {}],
      ["blank", (s: string) => pane(s, "x", "\n")],
      ["one field", (s: string) => pane(s, "x", "h1\n")],
      ["a 0xE9 byte", (s: string) => pane(s, "x", "h\xe9 t\n")],
    ] as const) {
      same(`${env.AC_BACKEND} ${label}`, { fn: "target", args: ["x"], env, seed });
      same(`${env.AC_BACKEND} ${label}, piped`, { fn: "target", args: ["x"], env, seed, io: { stdout: "pipe", stderr: "inherit" } });
    }
  same("no state dir yet", { fn: "target", args: ["x"], env: HERDR_, seed: (s) => rmSync(join(s, "home", "state"), { recursive: true }) });
  for (const env of [HERDR_, ORCA_]) same(`${env.AC_BACKEND} homeless`, { fn: "target", args: ["x"], env, homeless: true });
}, 30000);

test("7. focus: herdr's own status, the tab field even when empty; orca's switch", () => {
  const focus = (rc: string) => (s: string) => (X(s), sent(s, "focus-rc", rc));
  for (const [label, seed, path] of [
    ["ok", X],
    ["fails 1", focus("1")],
    ["fails 2", focus("2")],
    ["herdr absent", X, "noherdr"],
    ["no handle", () => {}],
    ["one field", (s: string) => pane(s, "x", "px\n")],
    ["a CR tab", (s: string) => pane(s, "x", "px tx\r\n")],
  ] as const)
    same(label, { fn: "focus", args: ["x"], env: HERDR_, seed, path: path as keyof typeof PATHS | undefined });
  same("homeless", { fn: "focus", args: ["x"], env: HERDR_, homeless: true, path: "noherdr" });
  for (const subshell of [false, true])
    same(`readstdin, subshell ${subshell}`, { fn: "focus", args: ["x"], env: HERDR_, io: { stdout: "inherit", stderr: "inherit", subshell }, input: "from-caller\n", seed: (s) => (X(s), sent(s, "readstdin")) });
  const p = same("hang", { fn: "focus", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (X(s), sent(s, "hang")) });
  expect(p.t.out).toBe("|rc=124");
  for (const x of [p.o, p.t]) expect(x.hangers.filter(alive)).toEqual([]);
  // Named (W16): bash runs a herdr it finds but cannot execute as 126, the
  // twin's lookup skips it - 127; every caller reads any non-zero alike.
  const ne = pair({ fn: "focus", args: ["x"], env: HERDR_, seed: X, path: "noexec" });
  expect({ o: ne.o.out, t: ne.t.out, err: ne.t.err, log: ne.t.log }).toEqual({ o: "|rc=126", t: "|rc=127", err: ne.o.err, log: ne.o.log });
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  for (const [label, seed, path] of [
    ["orca ok", H],
    ["orca fails", (s: string) => (H(s), sent(s, "switch-fails"))],
    ["orca no handle", () => {}],
    ["orca absent", H, "noorca"],
  ] as const)
    same(label, { fn: "focus", args: ["x"], env: ORCA_, seed, path: path as keyof typeof PATHS | undefined, input: "from-caller\n" });
}, 30000);

test("8. mark_wait: herdr reports blocked then stamps; orca stamps on a handle", () => {
  const VN = "ĐANG CHỜ captain - 2 mục trong room fam";
  for (const [label, args, seed, lc] of [
    ["ok", ["x", "a message"], X],
    ["the Vietnamese message", ["x", VN], X],
    ["the Vietnamese message under UTF-8", ["x", VN], X, "en_US.UTF-8"],
    ["msg empty", ["x", ""], X],
    ["msg absent", ["x"], X],
    ["report fails", ["x", "m"], (s: string) => (X(s), sent(s, "report-fails"))],
    ["no handle", ["x", "m"], () => {}],
    ["a dangling-symlink stamp", ["x", "m"], (s: string) => (X(s), symlinkSync(join(s, "home", "made"), join(s, "home", "state", ".captain-wait-x")))],
  ] as const)
    same(label, { fn: "mark_wait", args: [...args], env: HERDR_, seed, lc });
  if (!ROOTED) {
    same("state unwritable", { fn: "mark_wait", args: ["x", "m"], env: HERDR_, seed: (s) => (X(s), chmodSync(join(s, "home", "state"), 0o555)) });
    for (const x of ["o", "t"]) chmodSync(join(W, `r${rows - 1}`, x, "home", "state"), 0o755);
  }
  same("room's io: stderr dropped", { fn: "mark_wait", args: ["x", "m"], env: HERDR_, io: { stdout: "inherit", stderr: "ignore" }, seed: X });
  same("readstdin", { fn: "mark_wait", args: ["x", "m"], env: HERDR_, input: "from-caller\n", seed: (s) => (X(s), sent(s, "readstdin")) });
  same("hang", { fn: "mark_wait", args: ["x", "m"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (X(s), sent(s, "hang")) });
  same("homeless", { fn: "mark_wait", args: ["x", "m"], env: HERDR_, homeless: true });
  same("orca with a handle", { fn: "mark_wait", args: ["x", "m"], env: ORCA_, seed: (s) => pane(s, "x", "h1 t\n") });
  same("orca without one", { fn: "mark_wait", args: ["x", "m"], env: ORCA_ });
}, 30000);

test("9. clear_wait: no stamp is no call; a stamp is released (herdr, ignored status) and removed", () => {
  const stamp = (s: string): void => writeFileSync(join(s, "home", "state", ".captain-wait-x"), "");
  for (const [label, seed] of [
    ["no stamp", X],
    ["stamp and handle", (s: string) => (X(s), stamp(s))],
    ["stamp, no handle", stamp],
    ["release fails", (s: string) => (X(s), stamp(s), sent(s, "release-fails"))],
    ["a dangling-symlink stamp", (s: string) => (X(s), symlinkSync(join(s, "home", "gone"), join(s, "home", "state", ".captain-wait-x")))],
    ["a directory stamp", (s: string) => (X(s), mkdirSync(join(s, "home", "state", ".captain-wait-x")))],
  ] as const)
    same(label, { fn: "clear_wait", args: ["x"], env: HERDR_, seed });
  same("readstdin", { fn: "clear_wait", args: ["x"], env: HERDR_, input: "from-caller\n", seed: (s) => (X(s), stamp(s), sent(s, "readstdin")) });
  same("homeless", { fn: "clear_wait", args: ["x"], env: HERDR_, homeless: true });
  same("orca stamp", { fn: "clear_wait", args: ["x"], env: ORCA_, seed: (s) => (pane(s, "x", "h1 t\n"), stamp(s)) });
  same("orca no stamp", { fn: "clear_wait", args: ["x"], env: ORCA_ });
}, 30000);

test("10. ids: the empty id and a U+FFFD id name the same path bytes on both sides, every verb", () => {
  for (const id of ["", "�"])
    for (const fn of ["window_alive", "target", "focus", "capture", "mark_wait", "clear_wait", "agent_blocked", "harness_up", "send_key", "send_line"] as Fn[])
      same(`${JSON.stringify(id)} ${fn}`, {
        fn,
        args: [id, ...(fn === "capture" ? ["40"] : fn === "mark_wait" ? ["m"] : fn === "send_key" ? ["Enter"] : fn === "send_line" ? ["hi"] : [])],
        errexit: fn === "send_key",
        env: { ...HERDR_, AC_SEND_SETTLE: "0" },
        seed: (s) => (pane(s, id, "px tx\n"), sent(s, "win-px"), sent(s, "read-px", "r\n"), writeFileSync(join(s, "home", "state", `.captain-wait-${id}`), "")),
      });
}, 30000);

test("11. a driver that failed to load is the oracle's 127 alone - the twin has no driver to lose (named)", () => {
  const lab = join(W, "loadfail");
  cpSync(BIN, join(lab, "bin"), { recursive: true });
  const f = join(lab, "bin", "ac-backend.sh");
  writeFileSync(f, readFileSync(f, "utf8").replace(/^backend_window_alive_herdr\(\) \{/m, "backend_window_alive_herdr_MISSING_DRIVER() {"));
  const s = join(W, "r-loadfail");
  mkdirSync(join(s, "home", "state"), { recursive: true });
  mkdirSync(join(s, "stub"));
  X(s);
  const r = Bun.spawnSync(["/bin/bash", "-c", 'set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; backend_window_alive "$@"; printf "|rc=%s" "$?"', join(lab, "bin"), "x"], {
    cwd: s,
    env: { PATH: PATHS.both, HOME: process.env.HOME!, LC_ALL: "C", STUB_DIR: join(s, "stub"), AC_HOME: join(s, "home"), AC_BACKEND: "herdr" },
    stdout: "pipe",
    stderr: "pipe",
  });
  expect(r.stdout.toString()).toBe("|rc=127");
  expect(r.stderr.toString()).toContain("backend_window_alive_herdr: command not found");
}, 30000);

const STAMP = (s: string): void => writeFileSync(join(s, "home", "state", ".captain-wait-x"), "");
const DANGLING = (s: string): void => symlinkSync(join(s, "home", "gone"), join(s, "home", "state", ".captain-wait-x"));
const and =
  (...fs: ((s: string) => void)[]) =>
  (s: string): void => {
    for (const f of fs) f(s);
  };
type Case = [string, (s: string) => void, number, (keyof typeof PATHS)?, string?];

test("12. agent_blocked herdr: the stamp masks, then pane get's first non-empty agent_status must be blocked; jq's stderr is the caller's", () => {
  const get = (body: string) => (s: string): void => (X(s), sent(s, "win-px"), sent(s, "get-px", body));
  const B = '{"result":{"pane":{"agent_status":"blocked"}}}\n';
  const cases: Case[] = [
    ["blocked", get(B), 0],
    ["idle", get('{"result":{"pane":{"agent_status":"idle"}}}\n'), 1],
    ["the first non-empty status, at any depth", get('{"result":{"agent_status":"","pane":{"agent_status":null,"agent":{"agent_status":"blocked"}}}}\n'), 0],
    ["working ahead of blocked", get('{"a":{"agent_status":"working"},"b":{"agent_status":"blocked"}}\n'), 1],
    ["no status", get('{"result":{}}\n'), 1],
    ["an empty answer", (s) => (X(s), sent(s, "win-px")), 1],
    ["two blocked documents", get(B + B), 1],
    ["blocked, then garbage", get('{"agent_status":"blocked"} garbage\n'), 0],
    ["pane get fails", X, 1],
    ["no handle", () => {}, 1],
    ["stamped", and(get(B), STAMP), 1],
    ["a directory stamp", and(get(B), (s) => mkdirSync(join(s, "home", "state", ".captain-wait-x"))), 1],
    ["a dangling-symlink stamp", and(get(B), DANGLING), 0],
    ["herdr absent", get(B), 1, "noherdr"],
    ["jq absent", get(B), 1, "nojq"],
  ];
  for (const [label, seed, rc, path] of cases) {
    const p = same(label, { fn: "agent_blocked", args: ["x"], env: HERDR_, seed, path });
    expect({ label, out: p.t.out }).toEqual({ label, out: `|rc=${rc}` });
  }
  const bad = same("not JSON: jq's parse error on the caller's stderr", { fn: "agent_blocked", args: ["x"], env: HERDR_, seed: get("garbage\n") });
  expect({ out: bad.t.out, err: bad.t.err }).toEqual({ out: "|rc=1", err: "jq: parse error: Invalid numeric literal at line 2, column 0\n" });
  same("not JSON, the caller's stderr dropped", { fn: "agent_blocked", args: ["x"], env: HERDR_, seed: get("garbage\n"), io: { stdout: "inherit", stderr: "ignore" } });
  const noisy = same("the noisy jq", { fn: "agent_blocked", args: ["x"], env: HERDR_, seed: get(B), path: "noisyjq" });
  expect(noisy.t.err).toBe('jq-stderr -r [.. | .agent_status? // empty] | map(select(. != "")) | first // empty\n');
  same("AC_HERDR_SESSION", { fn: "agent_blocked", args: ["x"], env: { ...HERDR_, AC_HERDR_SESSION: "s1" }, seed: get(B) });
  for (const subshell of [false, true]) {
    const p = same(`readstdin, subshell ${subshell}: pane get sits in a $( )`, { fn: "agent_blocked", args: ["x"], env: HERDR_, io: { stdout: "inherit", stderr: "inherit", subshell }, input: "from-caller\n", seed: and(get(B), (s) => sent(s, "readstdin")) });
    expect(p.t.log).toBe("herdr pane get px [] stdin=[]\n");
  }
  const h = same("hang", { fn: "agent_blocked", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: and(get(B), (s) => sent(s, "hang")) });
  expect(h.t.out).toBe("|rc=1");
  for (const x of [h.o, h.t]) {
    expect(x.ms).toBeLessThan(4000);
    expect(x.ms).toBeGreaterThan(900);
    expect(x.hangers.length).toBe(1);
    expect(x.hangers.filter(alive)).toEqual([]);
  }
  same("homeless", { fn: "agent_blocked", args: ["x"], env: HERDR_, homeless: true });
}, 60000);

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

test("14. harness_up herdr: any non-shell foreground name is up, all shells a bare shell, no name unobservable", () => {
  const info = (body: string) => (s: string): void => (X(s), sent(s, "pinfo-px", body));
  const fg = (procs: string) => info(`{"result":{"process_info":{"foreground_processes":${procs}}}}\n`);
  const cases: Case[] = [
    ["a harness", fg('[{"argv0":"claude"}]'), 0],
    ["a login shell", fg('[{"argv0":"-zsh","name":"zsh"}]'), 1],
    ["every shell: by path, by name, IFS-padded, the dash before the path", fg('[{"argv0":"/bin/bash"},{"name":"fish"},{"argv0":" \\t sh\\t "},{"argv0":"-/bin/dash"},{"argv0":"/usr/bin/-ksh"},{"argv0":"tcsh"},{"argv0":"csh"}]'), 1],
    ["a shell, then a harness", fg('[{"argv0":"-zsh"},{"argv0":"node"}]'), 0],
    ["two dashes", fg('[{"argv0":"--zsh"}]'), 0],
    ["argv0 null or false: the name", fg('[{"argv0":null,"name":"zsh"},{"argv0":false,"name":"bash"}]'), 1],
    ["no argv0, a harness name", fg('[{"name":"codex"}]'), 0],
    ["an empty argv0 first", fg('[{"argv0":""},{"argv0":"zsh"}]'), 0],
    ["an empty argv0 last, cut by $( )", fg('[{"argv0":"zsh"},{"argv0":""}]'), 1],
    ["a CR after the shell", fg('[{"argv0":"zsh\\r"}]'), 0],
    ["a NUL inside the shell, dropped by $( )", fg('[{"argv0":"z\\u0000sh"}]'), 1],
    ["a number", fg('[{"argv0":7}]'), 0],
    ["an object, pretty-printed", fg('[{"argv0":{"a":"zsh"}}]'), 0],
    ["no foreground process", fg("[]"), 2],
    ["foreground_processes absent", info('{"result":{"process_info":{}}}\n'), 2],
    ["process_info a string", info('{"result":{"process_info":"x"}}\n'), 2],
    ["not JSON", info("garbage\n"), 2],
    ["an empty answer", info(""), 2],
    ["process-info fails", X, 2],
    ["no handle", () => {}, 2],
    ["herdr absent", fg('[{"argv0":"claude"}]'), 2, "noherdr"],
    ["jq absent", fg('[{"argv0":"claude"}]'), 2, "nojq"],
    ["the noisy jq: its stderr dropped", fg('[{"argv0":"claude"}]'), 0, "noisyjq"],
  ];
  for (const [label, seed, rc, path] of cases) {
    const p = same(label, { fn: "harness_up", args: ["x"], env: HERDR_, seed, path });
    expect({ label, out: p.t.out, err: p.t.err }).toEqual({ label, out: `|rc=${rc}`, err: "" });
  }
  same("AC_HERDR_SESSION", { fn: "harness_up", args: ["x"], env: { ...HERDR_, AC_HERDR_SESSION: "s1" }, seed: fg('[{"argv0":"claude"}]') });
  for (const subshell of [false, true]) {
    const p = same(`readstdin, subshell ${subshell}: process-info sits in a $( )`, { fn: "harness_up", args: ["x"], env: HERDR_, io: { stdout: "inherit", stderr: "inherit", subshell }, input: "from-caller\n", seed: and(fg('[{"argv0":"zsh"}]'), (s) => sent(s, "readstdin")) });
    expect(p.t.log).toBe("herdr pane process-info --pane px [] stdin=[]\n");
  }
  const h = same("hang", { fn: "harness_up", args: ["x"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: and(fg('[{"argv0":"claude"}]'), (s) => sent(s, "hang")) });
  expect(h.t.out).toBe("|rc=2");
  for (const x of [h.o, h.t]) {
    expect(x.ms).toBeLessThan(4000);
    expect(x.ms).toBeGreaterThan(900);
    expect(x.hangers.length).toBe(1);
    expect(x.hangers.filter(alive)).toEqual([]);
  }
  same("homeless", { fn: "harness_up", args: ["x"], env: HERDR_, homeless: true });
}, 60000);

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

test("16. named (V1): once harness_up's `done <<<` ran, bash 3.2 handed a later `$( )`'s herdr the caller's stdin - the twin keeps a fresh shell's /dev/null", () => {
  const logs: string[] = [];
  for (const oracle of [true, false]) {
    const s = join(W, `r-v1-${oracle ? "o" : "t"}`);
    mkdirSync(join(s, "home", "state"), { recursive: true });
    mkdirSync(join(s, "stub"));
    X(s);
    for (const [name, body] of [["win-px", ""], ["readstdin", ""], ["pinfo-px", '{"result":{"process_info":{"foreground_processes":[{"argv0":"claude"}]}}}\n']]) sent(s, name!, body);
    const cmd = oracle
      ? ["/bin/bash", "-c", 'set -uo pipefail; . "$0/ac-lib.sh" || exit $?; . "$0/ac-backend.sh" || exit $?; backend_harness_up x; backend_agent_blocked x', BIN]
      : [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const io = { stdout: "inherit", stderr: "inherit" }; L.backendCall("harness_up", ["x"], io); L.backendCall("agent_blocked", ["x"], io);`];
    Bun.spawnSync(cmd, { cwd: s, env: { PATH: PATHS.both, HOME: process.env.HOME!, TMPDIR: W, LC_ALL: "C", STUB_DIR: join(s, "stub"), AC_HOME: join(s, "home"), AC_BACKEND: "herdr" }, stdin: Buffer.from("from-caller\n"), stdout: "pipe", stderr: "pipe" });
    logs.push(read(join(s, "stub", "log")));
  }
  expect(logs).toEqual([
    "herdr pane process-info --pane px [] stdin=[]\nherdr pane get px [] stdin=[from-caller]\n",
    "herdr pane process-info --pane px [] stdin=[]\nherdr pane get px [] stdin=[]\n",
  ]);
}, 30000);

// The three keys ac-send.sh's usage names, in every spelling herdr_key_name
// and the orca case map, with herdr's name and orca's flags for each.
const KEYS: [string[], string, string][] = [
  [["Enter", "enter"], "enter", "--enter"],
  [["Escape", "escape", "Esc", "esc"], "escape", "--text \x1b"],
  [["C-c", "c-c", "ctrl+c", "Ctrl+C"], "ctrl+c", "--interrupt"],
];
const UNKNOWN = ["ENTER", "Tab", "a b", "x\n\n"];

test("17. send_key herdr: tab focus, then pane send-keys <pane> <herdr's key name>, bare under errexit - a failing focus ends it before any key", () => {
  const K = (label: string, args: string[], rc: number, log: string, row: Partial<Row> = {}): { o: Side; t: Side } => {
    const p = same(label, { fn: "send_key", args, env: HERDR_, seed: X, errexit: true, ...row });
    expect({ label, out: p.t.out, log: p.t.log }).toEqual({ label, out: `|rc=${rc}`, log });
    return p;
  };
  const pressed = (key: string, pane = "px", tab = "tx"): string => `herdr tab focus ${tab} []\nherdr pane send-keys ${pane} ${key} []\n`;
  for (const [spellings, name] of KEYS) for (const k of spellings) K(k, ["x", k], 0, pressed(name));
  for (const k of UNKNOWN) K(`an unknown key ${JSON.stringify(k)}: verbatim, its trailing LFs cut by $( )`, ["x", k], 0, pressed(k.replace(/\n+$/, "")));
  for (const rc of [1, 7]) K(`focus fails ${rc}: no key`, ["x", "Enter"], rc, "herdr tab focus tx []\n", { seed: (s) => (X(s), sent(s, "focus-rc", String(rc))) });
  K("send-keys fails 3", ["x", "Enter"], 3, pressed("enter"), { seed: (s) => (X(s), sent(s, "keys-rc", "3")) });
  K("herdr absent: focus's 127, no key", ["x", "Enter"], 127, "", { path: "noherdr" });
  K("no handle: both RPCs with an empty argument", ["x", "Enter"], 0, pressed("enter", "", ""), { seed: () => {} });
  K("one field: tab focus ''", ["x", "Enter"], 0, pressed("enter", "px", ""), { seed: (s) => pane(s, "x", "px\n") });
  K("a CR tab", ["x", "Enter"], 0, pressed("enter", "px", "tx\r"), { seed: (s) => pane(s, "x", "px tx\r\n") });
  const hl = K("homeless: both RPCs with an empty argument", ["x", "Enter"], 0, pressed("enter", "", ""), { homeless: true });
  expect(hl.t.err.split("\n").filter((l) => l.startsWith("ERROR: AC_HOME is not set")).length).toBe(2);
  K("AC_HERDR_SESSION", ["x", "Enter"], 0, "herdr tab focus tx --session s1 [s1]\nherdr pane send-keys px enter --session s1 [s1]\n", { env: { ...HERDR_, AC_HERDR_SESSION: "s1" } });
  for (const [label, io, l1, l2] of [
    ["top level: both read the caller's stdin", { stdout: "inherit", stderr: "inherit" }, "l1", "l2"],
    ["in a subshell", { stdout: "inherit", stderr: "inherit", subshell: true }, "", ""],
    ["stdin ignored", { stdin: "ignore", stdout: "inherit", stderr: "inherit" }, "", ""],
  ] as const)
    K(`readline, ${label}`, ["x", "Enter"], 0, `herdr tab focus tx [] line=[${l1}]\nherdr pane send-keys px enter [] line=[${l2}]\n`, { io, input: "l1\nl2\n", seed: (s) => (X(s), sent(s, "readline")) });
  for (const [label, sentinel, log] of [
    ["a hung focus is killed at the ceiling: 124, no key", "hang", "herdr tab focus tx []\n"],
    ["a hung send-keys is killed at the ceiling: 124", "hang-send-keys", pressed("enter")],
  ] as const) {
    const p = K(label, ["x", "Enter"], 124, log, { env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "1" }, seed: (s) => (X(s), sent(s, sentinel)) });
    for (const x of [p.o, p.t]) {
      expect(x.ms).toBeLessThan(4000);
      expect(x.ms).toBeGreaterThan(900);
      expect(x.hangers.length).toBe(1);
      expect(x.hangers.filter(alive)).toEqual([]);
    }
  }
  // Named: where errexit sleeps (`"$send" ... || true` in ac_startup_dialogs)
  // the bash presses the key after a failed focus; the twin answers ac-send's
  // bare position alone.
  const n = pair({ fn: "send_key", args: ["x", "Enter"], env: HERDR_, seed: (s) => (X(s), sent(s, "focus-rc", "7")) });
  expect({ o: [n.o.out, n.o.log], t: [n.t.out, n.t.log] }).toEqual({ o: ["|rc=0", pressed("enter")], t: ["|rc=7", "herdr tab focus tx []\n"] });
  // A ceiling past 2147483647 s, which sleep(1) refuses, fires at once under
  // errexit on both sides (the bash watchdog's wait survives the refusal), so
  // no key is pressed; the kill races the stub's log line, so only the status
  // is compared.
  const big = pair({ fn: "send_key", args: ["x", "Enter"], env: { ...HERDR_, AC_HERDR_RPC_TIMEOUT: "2147483648" }, seed: X, errexit: true });
  expect({ o: big.o.out, t: big.t.out }).toEqual({ o: "|rc=124", t: "|rc=124" });
}, 60000);

test("18. send_key orca: one terminal send - --enter, ESC as --text, --interrupt, else the key as --text - answering 0 or 1, no focus", () => {
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  const K = (label: string, args: string[], rc: number, log: string, row: Partial<Row> = {}): { o: Side; t: Side } => {
    const p = same(label, { fn: "send_key", args, env: ORCA_, seed: H, errexit: true, ...row });
    expect({ label, out: p.t.out, log: p.t.log }).toEqual({ label, out: `|rc=${rc}`, log });
    return p;
  };
  const pressed = (flags: string, h = "h1"): string => `orca terminal send --terminal ${h} ${flags} --json\n`;
  for (const [spellings, , flags] of KEYS) for (const k of spellings) K(k, ["x", k], 0, pressed(flags));
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

const UI = (s: string): void => (X(s), sent(s, "ui-px", "> earlier turn\n"), sent(s, "cmp-px"));
const META = (body: string) => (s: string): void => writeFileSync(join(s, "home", "state", "x.meta"), body);
const CLAUDE = META("harness=claude\n");
const TEXT = "hello world";
const QUICK = { ...HERDR_, AC_SEND_SETTLE: "0" };
// One call as the stubs log it.
const TYPE = (t = TEXT, p = "px"): string => `herdr pane send-text ${p} ${t} []\n`;
const SLEPT = (v = "0"): string => `sleep ${v}\n`;
const READ = (p = "px"): string => `herdr pane read ${p} --source recent --lines 200 []\n`;
const ANSI = (p = "px"): string => `herdr pane read ${p} --source recent --lines 200 --ansi []\n`;
const ENTER = (p = "px"): string => `herdr pane send-keys ${p} enter []\n`;
const CTRLU = (p = "px"): string => `herdr pane send-keys ${p} ctrl+u []\n`;
const FOCUS = (t = "tx"): string => `herdr tab focus ${t} []\n`;
// The submit verifier: a render read, the Enter, then <k> probes.
const VERIFY = (k: number, v = "0", p = "px"): string => READ(p) + ENTER(p) + (SLEPT(v) + READ(p)).repeat(k);
const SAYS = {
  noread: "ac-backend: could not read the pane of herdr:pane-px - NOTHING was typed or submitted (peek it: ac-peek.sh x)\n",
  nosee: "ac-backend: cannot see the composer of herdr:pane-px (no claude composer on screen) - NOTHING was typed; peek it (ac-peek.sh x), or type anyway with ac-send.sh x --force\n",
  draft: "ac-backend: the composer of herdr:pane-px holds an unsent draft - NOTHING was typed or submitted, so the draft is untouched; send it or clear it first (peek: ac-peek.sh x)\n",
  tail: (draft: string): string =>
    `ac-backend: the composer of herdr:pane-px did not show the whole message before Enter (a long send lands as its tail) - NOTHING was submitted, draft ${draft}; write the instruction to a file and send a short pointer to it\n`,
  unverified: "ac-backend: could not read the pane of herdr:pane-px - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh x)\n",
  stranded: "ac-backend: submit not acknowledged by herdr:pane-px - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh x --key Enter)\n",
};
const NOT_CLEARED = "NOT cleared - peek it (ac-peek.sh x)";

// One send_line row: both sides alike, the stub pane's composer and
// transcript included; then the twin's status and, where the row names them,
// its stderr and log.
function SL(label: string, rc: number, want: { err?: string; log?: string }, row: Partial<Row> = {}): { o: Side; t: Side; cmp: string; ui: string; ocmp: string; oui: string } {
  const p = same(label, { fn: "send_line", args: ["x", TEXT], env: QUICK, seed: UI, ...row });
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

test("19. send_line herdr: send-text, the settle, then the verified Enter - a strand focuses the tab and verifies ONE retry; 0 accepted, 1 stranded", () => {
  const typed = TYPE() + SLEPT();
  const ok = SL("delivered first try", 0, { err: "", log: typed + VERIFY(1) });
  expect({ cmp: ok.cmp, ui: ok.ui }).toEqual({ cmp: "", ui: "> earlier turn\n> hello world\n" });
  SL("several arguments: joined by one space", 0, { log: TYPE("a  b c") + SLEPT() + VERIFY(1) }, { args: ["x", "a ", "b", "c"] });
  const retry = SL("an Enter dropped on an unfocused pane: seven probes, the focus, then the verified retry", 0, { err: "", log: typed + VERIFY(7) + FOCUS() + VERIFY(1) }, { seed: and(UI, (s) => sent(s, "unfocused")) });
  expect(retry.ui).toBe("> earlier turn\n> hello world\n");
  const lost = SL("every Enter dropped: NOT confirmed, the text left in the composer", 1, { err: SAYS.stranded, log: typed + VERIFY(7) + FOCUS() + VERIFY(7) }, { seed: and(UI, (s) => sent(s, "drop-enters", "99")) });
  expect({ cmp: lost.cmp, ui: lost.ui }).toEqual({ cmp: "hello world\n", ui: "> earlier turn\n" });
  SL("the redraw shows on the third probe: accepted there", 0, { log: typed + VERIFY(3) }, { seed: and(UI, (s) => sent(s, "late", "3")) });
  const twice = SL("named: a redraw later than the seven probes - the retry's Enter submits the emptied composer", 0, { log: typed + VERIFY(7) + FOCUS() + VERIFY(1) }, { seed: and(UI, (s) => sent(s, "late", "8")) });
  expect(twice.ui).toBe("> earlier turn\n> hello world\n> \n");
  SL("the focus fails: its status ignored, the retry verified all the same", 1, { err: SAYS.stranded, log: typed + VERIFY(7) + FOCUS() + VERIFY(7) }, { seed: and(UI, (s) => sent(s, "unfocused"), (s) => sent(s, "focus-rc", "1")) });
  SL("send-keys fails 3: the Enter's status ignored, a strand", 1, { err: SAYS.stranded, log: typed + VERIFY(7) + FOCUS() + VERIFY(7) }, { seed: and(UI, (s) => sent(s, "keys-rc", "3")) });
  const blank = SL("named (V6): send-text fails 1, its status ignored - the Enter submits the empty composer and reads accepted", 0, { log: typed + VERIFY(1) }, { seed: and(UI, (s) => sent(s, "text-rc", "1")) });
  expect(blank.ui).toBe("> earlier turn\n> \n");
  const scroll = (s: string): void => sent(s, "ui-px", Array.from({ length: 20 }, (_, i) => `> turn ${i}\n`).join(""));
  SL("a ticker above the render's last 15 lines: a dropped Enter still reads stranded", 1, { err: SAYS.stranded, log: typed + VERIFY(7) + FOCUS() + VERIFY(7) }, { seed: and(UI, scroll, (s) => sent(s, "ticker"), (s) => sent(s, "drop-enters", "99")) });
  SL("no dialog guard on herdr: a pane whose agent reports blocked is typed into with no pane get", 0, { log: typed + VERIFY(1) }, {
    seed: and(UI, (s) => sent(s, "win-px"), (s) => sent(s, "get-px", '{"result":{"pane":{"agent_status":"blocked"}}}\n')),
  });
}, 120000);

test("20. send_line herdr: a claude pane's composer is proven before Enter - unreadable 2, no frame, a draft or a partial message 3, nothing submitted", () => {
  const C = (...fs: ((s: string) => void)[]) => and(UI, CLAUDE, ...fs);
  const proven = ANSI() + TYPE() + SLEPT() + ANSI();
  const ok = SL("proven: the composer empty before, the whole message after", 0, { err: "", log: proven + VERIFY(1) }, { seed: C() });
  expect(ok.ui).toBe("> earlier turn\n> hello world\n");
  SL("proven, then a strand: the retry as without the proof", 0, { log: proven + VERIFY(7) + FOCUS() + VERIFY(1) }, { seed: C((s) => sent(s, "unfocused")) });
  SL("the first read fails: 2, nothing typed", 2, { err: SAYS.noread, log: ANSI() }, { seed: C((s) => sent(s, "read-fails-from", "1")) });
  SL("no rules on screen: 3", 3, { err: SAYS.nosee, log: ANSI() }, { seed: C((s) => sent(s, "norules")) });
  SL("one rule: 3", 3, { err: SAYS.nosee, log: ANSI() }, { seed: C((s) => sent(s, "onerule")) });
  SL("named: two adjacent rules - sed's reversed range prints the second rule, read as a draft", 3, { err: SAYS.draft, log: ANSI() }, { seed: C((s) => sent(s, "tight")) });
  SL("an older rule above the read's last 20 lines is cut: one rule, 3", 3, { err: SAYS.nosee, log: ANSI() }, {
    seed: C((s) => sent(s, "ui-px", `${Buffer.from(RULE).toString("latin1")}\n${Array.from({ length: 20 }, (_, i) => `> turn ${i}\n`).join("")}`), (s) => sent(s, "onerule")),
  });
  const draft = SL("a draft in the composer: 3, untouched", 3, { err: SAYS.draft, log: ANSI() }, { seed: C((s) => sent(s, "cmp-px", "old draft\n")) });
  expect(draft.cmp).toBe("old draft\n");
  const cut = SL("the composer shows a tail: cleared, 3", 3, { err: SAYS.tail("cleared"), log: proven + CTRLU() + ANSI() }, { seed: C((s) => sent(s, "keep-tail", "5")) });
  expect(cut.cmp).toBe("");
  const long = "x".repeat(100);
  SL("a tail of three rows: three ctrl+u", 3, { err: SAYS.tail("cleared"), log: ANSI() + TYPE(long) + SLEPT() + ANSI() + (CTRLU() + ANSI()).repeat(3) }, { args: ["x", long], seed: C((s) => sent(s, "keep-tail", "90")) });
  const tall = "x".repeat(1000);
  SL("a tail of 23 rows: every re-read takes the message's 33 rows, 23 ctrl+u", 3, { err: SAYS.tail("cleared"), log: ANSI() + TYPE(tall) + SLEPT() + ANSI() + (CTRLU() + ANSI()).repeat(23) }, { args: ["x", tall], seed: C((s) => sent(s, "keep-tail", "900")) });
  SL("ctrl+u stuck: one press per row read, NOT cleared", 3, { err: SAYS.tail(NOT_CLEARED), log: proven + (CTRLU() + ANSI()).repeat(20) }, { seed: C((s) => sent(s, "keep-tail", "5"), (s) => sent(s, "ctrlu-stuck")) });
  SL("ctrl+u fails: one press, NOT cleared", 3, { err: SAYS.tail(NOT_CLEARED), log: proven + CTRLU() }, { seed: C((s) => sent(s, "keep-tail", "5"), (s) => sent(s, "keys-rc", "1")) });
  SL("the read after typing fails: one ctrl+u, its re-read fails, NOT cleared", 3, { err: SAYS.tail(NOT_CLEARED), log: proven + CTRLU() + ANSI() }, { seed: C((s) => sent(s, "read-fails-from", "2")) });
  for (const [label, paste, rc] of [
    ["the paste placeholder alone: proven", "[Pasted text #1 +3 lines]", 0],
    ["one line, singular", "[Pasted text #2 +1 line]", 0],
    ["no line count", "[Pasted text #12]", 0],
    ["two placeholders", "[Pasted text #1 +3 lines] [Pasted text #2]", 0],
    ["a placeholder and a remainder: 3", "[Pasted text #1 +3 lines] tail", 3],
    ["no number: 3", "[Pasted text #]", 3],
  ] as const)
    SL(label, rc, { err: rc ? SAYS.tail("cleared") : "" }, { seed: C((s) => sent(s, "paste", paste)) });
  SL("an empty message is never proven: 3, the composer cleared", 3, { err: SAYS.tail("cleared"), log: ANSI() + TYPE("") + SLEPT() + ANSI() + CTRLU() + ANSI() }, { args: ["x", ""], seed: C() });
  const unproven = SL("AC_SEND_UNPROVEN=1: no proof, typed after a draft", 0, { log: TYPE() + SLEPT() + VERIFY(1) }, { env: { ...QUICK, AC_SEND_UNPROVEN: "1" }, seed: C((s) => sent(s, "cmp-px", "old draft\n")) });
  expect(unproven.ui).toBe("> earlier turn\n> old drafthello world\n");
  for (const v of ["0", "", "yes", " 1"])
    SL(`AC_SEND_UNPROVEN ${JSON.stringify(v)}: proven`, 3, { err: SAYS.draft, log: ANSI() }, { env: { ...QUICK, AC_SEND_UNPROVEN: v }, seed: C((s) => sent(s, "cmp-px", "old draft\n")) });
  for (const [label, meta, proof] of [
    ["harness codex: no proof", "harness=codex\n", false],
    ["no harness key", "backend=herdr\n", false],
    ["harness claude with a CR: no proof", "harness=claude\r\n", false],
    ["the last harness line wins", "harness=codex\nharness=claude\n", true],
    ["an empty last value reads absent", "harness=claude\nharness=\n", false],
    ["a NUL inside the value", "harness=claude\0x\n", true],
  ] as const)
    SL(label, proof ? 3 : 0, { log: proof ? ANSI() : TYPE() + SLEPT() + VERIFY(1) }, { seed: and(UI, META(meta), (s) => sent(s, "cmp-px", "old draft\n")) });
  SL("the meta a directory: no proof", 0, { err: "", log: TYPE() + SLEPT() + VERIFY(1) }, { seed: and(UI, (s) => mkdirSync(join(s, "home", "state", "x.meta"))) });
  if (!ROOTED) SL("an unreadable meta: no proof, no warning", 0, { err: "", log: TYPE() + SLEPT() + VERIFY(1) }, { seed: and(UI, CLAUDE, (s) => chmodSync(join(s, "home", "state", "x.meta"), 0)) });
  const k = "x".repeat(1000);
  SL("a 1000-byte message: 33 rows hold its 25 wrapped rows", 0, { log: ANSI() + TYPE(k) + SLEPT() + ANSI() + VERIFY(1) }, { args: ["x", k], seed: C() });
  const huge = "x".repeat(8000);
  SL("an 8000-byte message: the 200-row clamp cannot hold its frame - one ctrl+u, NOT cleared", 3, { err: SAYS.tail(NOT_CLEARED), log: ANSI() + TYPE(huge) + SLEPT() + ANSI() + CTRLU() + ANSI() }, { args: ["x", huge], seed: C() });
  const e = "é".repeat(300);
  for (const [lc, presses] of [["C", 23], ["en_US.UTF-8", 20]] as const)
    SL(`300 x é under ${lc}: ${presses} rows - bash counts the message in ${lc === "C" ? "bytes" : "characters"}`, 3, { log: ANSI() + TYPE(Buffer.from(e).toString("latin1")) + SLEPT() + ANSI() + (CTRLU() + ANSI()).repeat(presses) }, {
      args: ["x", e],
      lc,
      seed: C((s) => sent(s, "keep-tail", "10"), (s) => sent(s, "ctrlu-stuck")),
    });
  SL("an invalid byte in the composer under UTF-8: not the message (the placeholder sed runs under C), cleared", 3, { err: SAYS.tail("cleared") }, { args: ["x", "é".repeat(30)], lc: "en_US.UTF-8", seed: C((s) => sent(s, "keep-tail", "59")) });
}, 180000);

test("21. send_line herdr: reads that fail or hang (2, bounded), no handle, the session, stdin by position, homeless, herdr absent", () => {
  const typed = TYPE() + SLEPT();
  SL("the verifier's first read fails: the Enter pressed all the same, twice - UNVERIFIED", 2, { err: SAYS.unverified, log: typed + READ() + ENTER() + FOCUS() + READ() + ENTER() }, { seed: and(UI, (s) => sent(s, "read-fails-from", "1")) });
  SL("a probe's read fails: 2 at once, then the retry's", 2, { err: SAYS.unverified, log: typed + READ() + ENTER() + SLEPT() + READ() + FOCUS() + READ() + ENTER() }, { seed: and(UI, (s) => sent(s, "read-fails-from", "2")) });
  const hung = SL("a hung probe read is killed at the ceiling: 2, bounded", 2, { err: SAYS.unverified, log: typed + READ() + ENTER() + SLEPT() + READ() + FOCUS() + READ() + ENTER() }, {
    env: { ...QUICK, AC_HERDR_RPC_TIMEOUT: "1" },
    seed: and(UI, (s) => sent(s, "read-hangs-from", "2")),
  });
  for (const x of [hung.o, hung.t]) {
    expect(x.ms).toBeLessThan(5000);
    expect(x.ms).toBeGreaterThan(1900);
    expect(x.hangers.length).toBe(2);
    expect(x.hangers.filter(alive)).toEqual([]);
  }
  const ht = SL("named (V6): a hung send-text is killed at the ceiling, 124 ignored, the Enter pressed", 0, { log: typed + VERIFY(1) }, { env: { ...QUICK, AC_HERDR_RPC_TIMEOUT: "1" }, seed: and(UI, (s) => sent(s, "hang-send-text")) });
  for (const x of [ht.o, ht.t]) {
    expect(x.ms).toBeGreaterThan(900);
    expect(x.hangers.filter(alive)).toEqual([]);
  }
  SL("a claude pane's first read hangs: 2, nothing typed", 2, { err: SAYS.noread, log: ANSI() }, { env: { ...QUICK, AC_HERDR_RPC_TIMEOUT: "1" }, seed: and(UI, CLAUDE, (s) => sent(s, "hang-read")) });
  SL("no handle: every call with an empty pane or tab, the reads never issued - UNVERIFIED", 2, { err: SAYS.unverified.replace("pane-px", "pane-"), log: TYPE(TEXT, "") + SLEPT() + ENTER("") + FOCUS("") + ENTER("") }, { seed: () => {} });
  SL("no handle on a claude pane: the proof reads pane '' - 2, nothing typed", 2, { err: SAYS.noread.replace("pane-px", "pane-"), log: ANSI("") }, { seed: CLAUDE });
  SL("one field: the retry focuses tab ''", 1, { log: typed + VERIFY(7) + FOCUS("") + VERIFY(7) }, { seed: and(UI, (s) => pane(s, "x", "px\n"), (s) => sent(s, "drop-enters", "99")) });
  const session = (l: string, s: string): string => l.replace(/ \[\]\n/g, ` --session ${s} [${s}]\n`);
  SL("AC_HERDR_SESSION: every call suffixed", 0, { log: session(typed + VERIFY(1), "s1") }, { env: { ...QUICK, AC_HERDR_SESSION: "s1" } });
  SL("config/herdr-session on a claude pane", 0, { log: session(ANSI() + typed + ANSI() + VERIFY(1), "s2") }, { seed: and(UI, CLAUDE, (s) => cfg(s, "herdr-session", "s2\n")) });
  const nested = (l: string): string => l.replace(/\n$/, " line=[]\n");
  for (const [label, io, top] of [
    ["top level: send-text, the Enters and the focus read the caller's stdin, every read nests", { stdout: "inherit", stderr: "inherit" }, true],
    ["in a subshell", { stdout: "inherit", stderr: "inherit", subshell: true }, false],
    ["stdin ignored", { stdin: "ignore", stdout: "inherit", stderr: "inherit" }, false],
  ] as const) {
    const at = (l: string, n: string): string => l.replace(/\n$/, ` line=[${top ? n : ""}]\n`);
    SL(`readline, ${label}`, 0, { log: at(TYPE(), "l1") + SLEPT() + nested(READ()) + at(ENTER(), "l2") + (SLEPT() + nested(READ())).repeat(7) + at(FOCUS(), "l3") + nested(READ()) + at(ENTER(), "l4") + SLEPT() + nested(READ()) }, {
      io,
      input: "l1\nl2\nl3\nl4\nl5\n",
      seed: and(UI, (s) => sent(s, "readline"), (s) => sent(s, "unfocused")),
    });
    SL(`readline, a claude pane cleared, ${label}`, 3, { log: nested(ANSI()) + at(TYPE(), "l1") + SLEPT() + nested(ANSI()) + at(CTRLU(), "l2") + nested(ANSI()) }, {
      io,
      input: "l1\nl2\nl3\n",
      seed: and(UI, CLAUDE, (s) => sent(s, "readline"), (s) => sent(s, "keep-tail", "5")),
    });
  }
  const hl = SL("homeless: an empty pane, the meta unread, the refusal per handle read", 2, {}, { homeless: true });
  expect(hl.t.err.split("\n").filter((l) => l.startsWith("ERROR: AC_HOME is not set")).length).toBe(6);
  SL("homeless, the caller's stderr dropped: silent", 2, { err: "" }, { homeless: true, io: { stdout: "inherit", stderr: "ignore" } });
  SL("herdr absent: every call 127 - UNVERIFIED", 2, { err: SAYS.unverified, log: SLEPT() }, { path: "noherdr" });
  SL("herdr absent on a claude pane: 2, nothing typed", 2, { err: SAYS.noread, log: "" }, { path: "noherdr", seed: and(UI, CLAUDE) });
}, 120000);

test("22. send_line herdr: AC_SEND_SETTLE is the pause after typing and between probes, read per pause, slept by PATH's sleep", () => {
  const d = SL("unset: 0.4 s", 0, { log: TYPE() + SLEPT("0.4") + VERIFY(1, "0.4") }, { env: HERDR_ });
  for (const x of [d.o, d.t]) expect(x.ms).toBeGreaterThan(750);
  SL("empty: 0.4 s", 0, { log: TYPE() + SLEPT("0.4") + VERIFY(1, "0.4") }, { env: { ...HERDR_, AC_SEND_SETTLE: "" } });
  const tenth = SL("0.1 across a strand: nine pauses", 0, { log: TYPE() + SLEPT("0.1") + VERIFY(7, "0.1") + FOCUS() + VERIFY(1, "0.1") }, { env: { ...HERDR_, AC_SEND_SETTLE: "0.1" }, seed: and(UI, (s) => sent(s, "unfocused")) });
  for (const x of [tenth.o, tenth.t]) expect(x.ms).toBeGreaterThan(850);
  const bad = SL("abc: sleep refuses every pause on the caller's stderr, the probes spin", 1, { log: TYPE() + SLEPT("abc") + VERIFY(7, "abc") + FOCUS() + VERIFY(7, "abc") }, { env: { ...HERDR_, AC_SEND_SETTLE: "abc" }, seed: and(UI, (s) => sent(s, "drop-enters", "99")) });
  expect(bad.t.err.split("\n").filter((l) => l.startsWith("sleep: invalid time interval")).length).toBe(15);
  SL("abc and a strand, the caller's stderr dropped: silent", 1, { err: "" }, { env: { ...HERDR_, AC_SEND_SETTLE: "abc" }, seed: and(UI, (s) => sent(s, "drop-enters", "99")), io: { stdout: "inherit", stderr: "ignore" } });
}, 60000);

const OUI = (s: string): void => (pane(s, "x", "h1 tab1\n"), sent(s, "oui-h1", "> earlier turn\n"), sent(s, "ocmp-h1"));
const OQUICK = { ...ORCA_, AC_SEND_SETTLE: "0" };
const L1 = (t: string): string => Buffer.from(t).toString("latin1");
const OTYPE = (t = TEXT, h = "h1"): string => `orca terminal send --terminal ${h} --text ${t} --json\n`;
const OSHOW = (h = "h1"): string => `orca terminal show --terminal ${h} --json\n`;
const OREAD = (h = "h1"): string => `orca terminal read --terminal ${h} --limit 15 --screen --json\n`;
const OENTER = (h = "h1"): string => `orca terminal send --terminal ${h} --enter --json\n`;
const OSWITCH = (h = "h1"): string => `orca terminal switch --terminal ${h} --json\n`;
const CHUNKED = SLEPT("0.05");
// The orca verifier: the dialog check, a render read, the Enter, then <k> probes.
const OVERIFY = (k: number, v = "0", h = "h1"): string => OSHOW(h) + OREAD(h) + OENTER(h) + (SLEPT(v) + OREAD(h)).repeat(k);
// A pending check's read that finds the text still in the composer, then the
// dialog check, the retry Enter and its settle.
const PENDING = (v = "0"): string => OREAD() + OSHOW() + OENTER() + SLEPT(v);
const OSAYS = {
  dialog:
    "ac-backend: a DIALOG owns the pane of orca:h1 - the text sits in the composer and no Enter was pressed (an Enter would ACCEPT the highlighted option). Peek it (ac-peek.sh x) and answer deliberately with ac-send.sh x --key <key>\n",
  unverified: "ac-backend: could not read the pane of orca:h1 - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh x)\n",
  stranded: "ac-backend: submit not acknowledged by orca:h1 - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh x --key Enter)\n",
};
const OSL = (label: string, rc: number, want: { err?: string; log?: string }, row: Partial<Row> = {}) => SL(label, rc, want, { env: OQUICK, seed: OUI, ...row });
const WAITING = '{"ok":true,"result":{"terminal":{"connected":true,"agentWait":{"reason":"permission"}}}}\n';
const NO_WAIT = '{"ok":true,"result":{"terminal":{"connected":true,"agentWait":null}}}\n';

test("23. send_line orca: the text typed, the settle, then the verified Enter and the pending check - a strand switches to the terminal and verifies ONE retry; 0 accepted, 1 stranded", () => {
  const typed = OTYPE() + SLEPT();
  const ok = OSL("delivered first try", 0, { err: "", log: typed + OVERIFY(1) + OREAD() });
  expect({ cmp: ok.ocmp, ui: ok.oui }).toEqual({ cmp: "", ui: "> earlier turn\n> hello world\n" });
  OSL("several arguments: joined by one space", 0, { log: OTYPE("a  b c") + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", "a ", "b", "c"] });
  const none = OSL("an empty message: nothing typed, the Enter verified, no pending check", 0, { log: SLEPT() + OVERIFY(1) }, { args: ["x", ""] });
  expect(none.oui).toBe("> earlier turn\n> \n");
  OSL("no text argument at all: the same", 0, { log: SLEPT() + OVERIFY(1) }, { args: ["x"] });
  const retry = OSL("an Enter dropped on an unfocused pane: seven probes, the switch, then the verified retry", 0, { err: "", log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "unfocused")) });
  expect(retry.oui).toBe("> earlier turn\n> hello world\n");
  const lost = OSL("every Enter dropped: NOT confirmed, the text left in the composer", 1, { err: OSAYS.stranded, log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(7) }, { seed: and(OUI, (s) => sent(s, "drop-enters", "99")) });
  expect({ cmp: lost.ocmp, ui: lost.oui }).toEqual({ cmp: "hello world", ui: "> earlier turn\n" });
  OSL("the stranded line, the caller's stderr dropped: silent", 1, { err: "" }, { seed: and(OUI, (s) => sent(s, "drop-enters", "99")), io: { stdout: "inherit", stderr: "ignore" } });
  OSL("the redraw shows on the third probe: accepted there", 0, { log: typed + OVERIFY(3) + OREAD() }, { seed: and(OUI, (s) => sent(s, "late", "3")) });
  const twice = OSL("named: a redraw later than the seven probes - the retry's Enter submits the emptied composer", 0, { log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "late", "8")) });
  expect(twice.oui).toBe("> earlier turn\n> hello world\n> \n");
  OSL("the switch fails: its status ignored, the retry verified all the same", 1, { err: OSAYS.stranded, log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(7) }, { seed: and(OUI, (s) => sent(s, "unfocused"), (s) => sent(s, "switch-fails")) });
  OSL("every send fails: the chunk's and the Enters' statuses ignored, a strand", 1, { err: OSAYS.stranded, log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(7) }, { seed: and(OUI, (s) => sent(s, "send-fails")) });
  OSL("every send answers ok:false: ignored, the render decides - accepted", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "send", '{"ok":false}\n')) });
  const blank = OSL("named (V6): the chunk refused, its status ignored - the Enter submits the empty composer and reads accepted", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "text-fails")) });
  expect(blank.oui).toBe("> earlier turn\n> \n");
  const scroll = (s: string): void => sent(s, "oui-h1", Array.from({ length: 20 }, (_, i) => `> turn ${i}\n`).join(""));
  OSL("a ticker above the render's last 15 lines: a dropped Enter still reads stranded", 1, { err: OSAYS.stranded, log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(7) }, { seed: and(OUI, scroll, (s) => sent(s, "ticker"), (s) => sent(s, "drop-enters", "99")) });
  const caught = OVERIFY(1) + PENDING().repeat(2) + OREAD();
  OSL("a ticker inside them: every probe reads changed - the pending check catches the dropped Enter, two retries per verify, stranded", 1, { err: OSAYS.stranded, log: typed + caught + OSWITCH() + caught }, {
    seed: and(OUI, (s) => sent(s, "ticker"), (s) => sent(s, "drop-enters", "99")),
  });
  const draft = OSL("a claude meta and a draft: the orca arm proves no composer - typed after the draft", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, CLAUDE, (s) => sent(s, "ocmp-h1", "old draft")) });
  expect(draft.oui).toBe("> earlier turn\n> old drafthello world\n");
}, 120000);

test("24. send_line orca: a changed render is checked for the text still pending between the composer's rules - up to two retry Enters, each behind the dialog guard; a dialog refuses, 1", () => {
  const typed = OTYPE() + SLEPT();
  const popups = (n: string) => and(OUI, (s) => sent(s, "popups", n));
  const once = OSL("a popup eats the Enter: pending, one retry Enter, accepted", 0, { err: "", log: typed + OVERIFY(1) + PENDING() + OREAD() }, { seed: popups("1") });
  expect(once.oui).toBe("> earlier turn\n> hello world\n");
  OSL("two popups: two retries, accepted", 0, { log: typed + OVERIFY(1) + PENDING().repeat(2) + OREAD() }, { seed: popups("2") });
  const capped = OVERIFY(1) + PENDING().repeat(2) + OREAD();
  OSL("three popups: still pending after two retries - the switch, and the second verify submits", 0, { log: typed + capped + OSWITCH() + OVERIFY(1) + OREAD() }, { seed: popups("3") });
  const stuck = OSL("popups without end: stranded", 1, { err: OSAYS.stranded, log: typed + capped + OSWITCH() + capped }, { seed: popups("99") });
  expect(stuck.ocmp).toBe("hello world");
  const d = OSL("named (V16): a dialog owns the pane - typed first, then refused before any Enter: 1, no switch", 1, { err: OSAYS.dialog, log: typed + OSHOW() }, { seed: and(OUI, (s) => sent(s, "show", WAITING)) });
  expect({ cmp: d.ocmp, ui: d.oui }).toEqual({ cmp: "hello world", ui: "> earlier turn\n" });
  OSL("the dialog, the caller's stderr dropped: silent", 1, { err: "" }, { seed: and(OUI, (s) => sent(s, "show", WAITING)), io: { stdout: "inherit", stderr: "ignore" } });
  OSL("a dialog that appears at the retry's guard: 1, no switch", 1, { err: OSAYS.dialog, log: typed + OVERIFY(1) + OREAD() + OSHOW() }, { seed: and(popups("1"), (s) => sent(s, "show", NO_WAIT), (s) => sent(s, "show-next", WAITING)) });
  OSL("a dialog that appears for the second verify: 1", 1, { err: OSAYS.dialog, log: typed + OVERIFY(7) + OSWITCH() + OSHOW() }, {
    seed: and(OUI, (s) => sent(s, "drop-enters", "99"), (s) => sent(s, "show", NO_WAIT), (s) => sent(s, "show-next", WAITING)),
  });
  for (const [label, show, rc] of [
    ["agentWait false is not null: a dialog", '{"ok":true,"result":{"terminal":{"agentWait":false}}}\n', 1],
    ["agentWait null: no dialog", NO_WAIT, 0],
    ["agentWait absent: no dialog", '{"ok":true,"result":{"terminal":{}}}\n', 0],
    ["ok false: no dialog", '{"ok":false,"result":{"terminal":{"agentWait":{}}}}\n', 0],
    ["a result jq cannot index: no dialog", '{"ok":true,"result":"x"}\n', 0],
    ["the last document decides", WAITING + NO_WAIT, 0],
    ["not JSON: no dialog", "garbage\n", 0],
  ] as const)
    OSL(label, rc, { err: rc ? OSAYS.dialog : "", log: rc ? typed + OSHOW() : typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "show", show)) });
  OSL("the show fails: no dialog", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => sent(s, "show-fails")) });
  const left = OSL("no rules on screen: pending is never claimed - the popup's change reads accepted, the text left", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "norules")) });
  expect(left.ocmp).toBe("hello world");
  OSL("one rule: the same", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "onerule")) });
  const R = L1(RULE);
  OSL("one rule holding the text: the same", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R} hello world\n`)) });
  OSL("named: two adjacent rules - sed's reversed range prints the second rule, not pending", 0, { log: typed + OVERIFY(1) + OREAD() }, {
    seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R}\n${R}\n`)),
  });
  OSL("named: the same, the second rule holding the text - pending, and so on every read after: stranded", 1, { err: OSAYS.stranded }, {
    seed: and(popups("1"), (s) => sent(s, "norules"), (s) => sent(s, "oui-h1", `> earlier turn\n${R}\n${R} hello world\n`)),
  });
  const framed = (turns: number) => (s: string): void => sent(s, "oui-h1", `${R}\n${Array.from({ length: turns }, (_, i) => `> turn ${i}\n`).join("")}`);
  OSL("a transcript rule beyond the last 15 lines is cut: one rule, not pending", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "onerule"), framed(20)) });
  const echo = OSL("named: a transcript rule within them frames the echo of the submitted line - it reads pending, stranded though delivered", 1, { err: OSAYS.stranded }, { seed: and(popups("1"), (s) => sent(s, "onerule"), framed(2)) });
  expect(echo.oui).toBe(`${R}\n> turn 0\n> turn 1\n> hello world\n> \n> \n> \n> \n`);
  const long = "y".repeat(100);
  OSL("the text's first 60 characters on screen: pending, the retry", 0, { log: OTYPE(long) + SLEPT() + OVERIFY(1) + PENDING() + OREAD() }, { args: ["x", long], seed: and(popups("1"), (s) => sent(s, "keep-head", "60")) });
  OSL("59 on screen: not pending", 0, { log: OTYPE(long) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", long], seed: and(popups("1"), (s) => sent(s, "keep-head", "59")) });
  OSL("LFs and space runs squeezed on both sides: pending", 0, { log: OTYPE("a  b\nc") + SLEPT() + OVERIFY(1) + PENDING() + OREAD() }, { args: ["x", "a  b\nc"], seed: popups("1") });
  const e = "é".repeat(70);
  for (const [lc, pending] of [["C", true], ["en_US.UTF-8", false]] as const)
    OSL(`70 x é, 30 on screen, under ${lc}: the 60-${lc === "C" ? "byte head is" : "character head is not"} pending`, 0, { log: OTYPE(L1(e)) + SLEPT() + OVERIFY(1) + (pending ? PENDING() : "") + OREAD() }, {
      args: ["x", e],
      lc,
      seed: and(popups("1"), (s) => sent(s, "keep-head", "60")),
    });
  OSL("the pending check's read fails: not pending, accepted", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(popups("1"), (s) => sent(s, "read-fails-from", "3")) });
}, 180000);

test("25. send_line orca: chunks of 512 characters under a UTF-8 locale, 512 bytes under any other, `sleep 0.05` between them", () => {
  const x = (n: number): string => "x".repeat(n);
  for (const n of [1, 511, 512, 513, 1024, 1025]) {
    const chunks: string[] = [];
    for (let off = 0; off < n; off += 512) chunks.push(OTYPE(x(Math.min(512, n - off))));
    const p = OSL(`${n} characters: ${chunks.length} chunk(s)`, 0, { log: chunks.join(CHUNKED) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", x(n)] });
    expect(p.oui).toBe(`> earlier turn\n> ${x(n)}\n`);
  }
  const e = "é".repeat(300);
  OSL("300 x é under UTF-8: one chunk", 0, { log: OTYPE(L1(e)) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", e], lc: "en_US.UTF-8" });
  OSL("300 x é under C: 600 bytes, two chunks cut between characters", 0, { log: OTYPE(L1("é".repeat(256))) + CHUNKED + OTYPE(L1("é".repeat(44))) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", e] });
  const two = OTYPE(L1("é".repeat(256))) + CHUNKED + OTYPE(L1("é".repeat(44))) + SLEPT() + OVERIFY(1) + OREAD();
  for (const [label, env, log] of [
    ["LC_ALL empty, LC_CTYPE UTF-8: characters", { LC_CTYPE: "en_US.UTF-8", LANG: "C" }, OTYPE(L1(e)) + SLEPT() + OVERIFY(1) + OREAD()],
    ["LC_ALL empty, LC_CTYPE C over LANG UTF-8: bytes", { LC_CTYPE: "C", LANG: "en_US.UTF-8" }, two],
    ["LC_ALL empty, LC_CTYPE empty, LANG UTF-8: characters", { LC_CTYPE: "", LANG: "en_US.UTF-8" }, OTYPE(L1(e)) + SLEPT() + OVERIFY(1) + OREAD()],
  ] as const)
    OSL(`300 x é, ${label}`, 0, { log }, { args: ["x", e], lc: "", env: { ...OQUICK, ...env } });
  OSL("600 x é under UTF-8: 512 + 88 characters", 0, { log: OTYPE(L1("é".repeat(512))) + CHUNKED + OTYPE(L1("é".repeat(88))) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", "é".repeat(600)], lc: "en_US.UTF-8" });
  const g = "😀".repeat(200);
  OSL("200 x a 4-byte character under UTF-8: one chunk", 0, { log: OTYPE(L1(g)) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", g], lc: "en_US.UTF-8" });
  OSL("the same under C: 800 bytes, two chunks", 0, { log: OTYPE(L1("😀".repeat(128))) + CHUNKED + OTYPE(L1("😀".repeat(72))) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", g] });
  OSL("a text holding LFs: chunked as any byte", 0, { log: OTYPE(`${x(510)}\n\n${x(3)}`.slice(0, 512)) + CHUNKED + OTYPE(x(3)) + SLEPT() + OVERIFY(1) + OREAD() }, { args: ["x", `${x(510)}\n\n${x(3)}`] });
  // Named (V3): under C the 512th byte can cut a character - the bash typed
  // its two halves as they were, the twin U+FFFD for each half (an argv
  // carries no partial sequence).
  const odd = `a${e}`;
  const n = pair({ fn: "send_line", args: ["x", odd], env: OQUICK, seed: OUI });
  const head = L1(`a${"é".repeat(255)}`);
  const tail = L1("é".repeat(44));
  const rest = SLEPT() + OVERIFY(1) + OREAD();
  expect({ out: n.t.out, err: n.t.err, o: n.o.log, t: n.t.log }).toEqual({
    out: n.o.out,
    err: n.o.err,
    o: OTYPE(`${head}\xc3`) + CHUNKED + OTYPE(`\xa9${tail}`) + rest,
    t: OTYPE(`${head}\xef\xbf\xbd`) + CHUNKED + OTYPE(`\xef\xbf\xbd${tail}`) + rest,
  });
  expect(n.t.out).toBe("|rc=0");
}, 120000);

test("26. send_line orca: reads that fail (2, UNVERIFIED), no handle, the caller's stdin for every orca call, homeless, orca or jq absent", () => {
  const typed = OTYPE() + SLEPT();
  const blind = OSHOW() + OREAD() + OENTER();
  OSL("the verifier's first read fails: the Enter pressed all the same, twice - UNVERIFIED", 2, { err: OSAYS.unverified, log: typed + blind + OSWITCH() + blind }, { seed: and(OUI, (s) => sent(s, "read-fails-from", "1")) });
  OSL("a probe's read fails: 2 at once, then the retry's", 2, { err: OSAYS.unverified, log: typed + blind + SLEPT() + OREAD() + OSWITCH() + blind }, { seed: and(OUI, (s) => sent(s, "read-fails-from", "2")) });
  OSL("the stderr dropped: silent", 2, { err: "" }, { seed: and(OUI, (s) => sent(s, "read-fails-from", "1")), io: { stdout: "inherit", stderr: "ignore" } });
  const H = (s: string): void => pane(s, "x", "h1 tab1\n");
  const oread = (body: string) => (s: string): void => (H(s), sent(s, "oread", body));
  OSL("a screen jq cannot iterate: unreadable, 2", 2, { err: OSAYS.unverified, log: typed + blind + OSWITCH() + blind }, { seed: oread('{"ok":true,"result":"x"}\n') });
  OSL("a screen read ok:false: unreadable, 2", 2, { err: OSAYS.unverified, log: typed + blind + OSWITCH() + blind }, { seed: oread('{"ok":false,"result":{"terminal":{"tail":["a"]}}}\n') });
  OSL("a screen whose tail is no array: an empty render that never changes, 1", 1, { err: OSAYS.stranded, log: typed + OVERIFY(7) + OSWITCH() + OVERIFY(7) }, { seed: oread('{"ok":true,"result":{"terminal":{"tail":"abc"}}}\n') });
  OSL("a NUL and trailing LFs dropped as $( ) drops them: the same render, 1", 1, { err: OSAYS.stranded }, {
    seed: (s) => (oread('{"ok":true,"result":{"terminal":{"tail":["a\\u0000b","",""]}}}\n')(s), sent(s, "oread-next", '{"ok":true,"result":{"terminal":{"tail":["ab"]}}}\n')),
  });
  OSL("no handle: every call with --terminal '', the reads never issued - UNVERIFIED", 2, { err: OSAYS.unverified.replace("orca:h1", "orca:"), log: OTYPE(TEXT, "") + SLEPT() + OSHOW("") + OENTER("") + OSWITCH("") + OSHOW("") + OENTER("") }, { seed: () => {} });
  OSL("one field: the handle alone", 0, { log: typed + OVERIFY(1) + OREAD() }, { seed: and(OUI, (s) => pane(s, "x", "h1\n")) });
  for (const [label, io, top] of [
    ["top level: every orca call reads the caller's stdin, in the dialog's pipeline and the reads' $( ) too", { stdout: "inherit", stderr: "inherit" }, true],
    ["in a subshell: the same", { stdout: "inherit", stderr: "inherit", subshell: true }, true],
    ["stdin ignored", { stdin: "ignore", stdout: "inherit", stderr: "inherit" }, false],
  ] as const) {
    const at = (l: string, n: number): string => l.replace(/\n$/, ` line=[${top ? `l${n}` : ""}]\n`);
    OSL(`readline, ${label}`, 0, { log: at(OTYPE(), 1) + SLEPT() + at(OSHOW(), 2) + at(OREAD(), 3) + at(OENTER(), 4) + SLEPT() + at(OREAD(), 5) + at(OREAD(), 6) }, {
      io,
      input: "l1\nl2\nl3\nl4\nl5\nl6\nl7\n",
      seed: and(OUI, (s) => sent(s, "readline")),
    });
  }
  const hl = OSL("homeless: an empty handle, the refusal per handle read", 2, {}, { homeless: true });
  expect(hl.t.err.split("\n").filter((l) => l.startsWith("ERROR: AC_HOME is not set")).length).toBe(5);
  OSL("homeless, the caller's stderr dropped: silent", 2, { err: "" }, { homeless: true, io: { stdout: "inherit", stderr: "ignore" } });
  OSL("orca absent: every call fails - UNVERIFIED", 2, { err: OSAYS.unverified, log: SLEPT() }, { path: "noorca" });
  const nojq = OSL("jq absent: every envelope unread, the sends still land - UNVERIFIED", 2, { err: OSAYS.unverified, log: typed + blind + OSWITCH() + blind }, { path: "nojq" });
  expect(nojq.oui).toBe("> earlier turn\n> hello world\n> \n");
  OSL("the noisy jq: every jq's stderr dropped", 0, { err: "", log: typed + OVERIFY(1) + OREAD() }, { path: "noisyjq" });
  for (const id of ["", "�"]) {
    OSL(`the id ${JSON.stringify(id)}`, 0, { log: typed + OVERIFY(1) + OREAD() }, { args: [id, TEXT], seed: and(OUI, (s) => pane(s, id, "h1 tab1\n")) });
    OSL(`the id ${JSON.stringify(id)} in the stranded line`, 1, {}, { args: [id, TEXT], seed: and(OUI, (s) => pane(s, id, "h1 tab1\n"), (s) => sent(s, "drop-enters", "99")) });
  }
}, 120000);

test("27. send_line orca: AC_SEND_SETTLE is the pause after typing, between probes and after a retry Enter, read per pause; the chunks' 0.05 is fixed", () => {
  const d = OSL("unset: 0.4 s", 0, { log: OTYPE() + SLEPT("0.4") + OVERIFY(1, "0.4") + OREAD() }, { env: ORCA_ });
  for (const x of [d.o, d.t]) expect(x.ms).toBeGreaterThan(750);
  OSL("empty: 0.4 s", 0, { log: OTYPE() + SLEPT("0.4") + OVERIFY(1, "0.4") + OREAD() }, { env: { ...ORCA_, AC_SEND_SETTLE: "" } });
  const tenth = OSL("0.1 across a strand: nine pauses", 0, { log: OTYPE() + SLEPT("0.1") + OVERIFY(7, "0.1") + OSWITCH() + OVERIFY(1, "0.1") + OREAD() }, {
    env: { ...ORCA_, AC_SEND_SETTLE: "0.1" },
    seed: and(OUI, (s) => sent(s, "unfocused")),
  });
  for (const x of [tenth.o, tenth.t]) expect(x.ms).toBeGreaterThan(850);
  OSL("0.1 after a retry Enter", 0, { log: OTYPE() + SLEPT("0.1") + OVERIFY(1, "0.1") + PENDING("0.1") + OREAD() }, { env: { ...ORCA_, AC_SEND_SETTLE: "0.1" }, seed: and(OUI, (s) => sent(s, "popups", "1")) });
  const x = "x".repeat(600);
  const bad = OSL("abc: sleep refuses every settle on the caller's stderr, the probes spin; the chunks' 0.05 still sleeps", 1, { log: OTYPE("x".repeat(512)) + CHUNKED + OTYPE("x".repeat(88)) + SLEPT("abc") + OVERIFY(7, "abc") + OSWITCH() + OVERIFY(7, "abc") }, {
    args: ["x", x],
    env: { ...ORCA_, AC_SEND_SETTLE: "abc" },
    seed: and(OUI, (s) => sent(s, "drop-enters", "99")),
  });
  expect(bad.t.err.split("\n").filter((l) => l.startsWith("sleep: invalid time interval")).length).toBe(15);
  OSL("abc and a strand, the caller's stderr dropped: silent", 1, { err: "" }, { env: { ...ORCA_, AC_SEND_SETTLE: "abc" }, seed: and(OUI, (s) => sent(s, "drop-enters", "99")), io: { stdout: "inherit", stderr: "ignore" } });
}, 60000);
