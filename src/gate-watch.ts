// gate-watch.ts - ACTIVE-run observer for the second-chief gate, modeled on
// nm-claude-watch (dashboard + --tail). It shows ONLY gates running RIGHT NOW;
// settled reviews (second-chief.md) are ordinary artifacts browsed elsewhere and
// never appear here. The entry is bin/ac-gate-watch.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-gate-watch.sh as
// the oracle the differential leg of tests/sh/ac-gate-watch.test.sh holds this
// module to.
//
//   ac-gate-watch.sh [SECS]        default: dashboard, one row per ACTIVE gate
//   ac-gate-watch.sh --tail        follow the newest active gate's live output,
//                                  auto-switching when it completes and another
//                                  becomes active
//     [--family F] [--stage S] [--round 1|2]
//                                     optional simple pins
//     [--self-pane ID]             DASHBOARD MODE ONLY: a pane to close on idle
//     [--interval SECS] [--once]
//
// Data sources - ACTIVE runs ONLY: data/<family>/.gate-running.<pid> (the marker
// each ac-gate run stamps: family/stage/round/engine/model/at/observe/pid - one
// per run, so overlapping runs of one family are separate rows) plus the
// TRANSIENT observation descriptor named by `observe=` (pane/tab/harness + the real
// prompt/out/err file paths the one-shot run uses, published by
// `ac-pane-agent --observe`). It follows ONLY bytes the selected harness actually
// emitted to those streams - it never invents reasoning, claims hidden
// chain-of-thought, or turns missing output into synthetic progress (a
// final-answer-only harness shows the prompt, then its final output when it
// lands). A settled second-chief.md NEVER creates a row. Read-only, HOME-scoped.
//
// WHY A CODEX GATE HAD NO ACTIVITY TO SHOW (measured, historical): a real run
// once printed `reasoning effort: high` then `reasoning summaries: none` in its
// own banner, and its transcript carried exactly ONE event (the final answer) -
// the harness emitted no reasoning bytes to follow, by codex's own default. A
// knob to ask for them was verified LIVE (2026-07-26): `codex exec -c
// model_reasoning_summary=<auto|concise|detailed>` (enum confirmed via
// --strict-config; `detailed` measurably changed the banner and produced an
// actual reasoning-summary line before the final answer, on a prompt that
// required real reasoning). DECISION: run gate summaries
// at `auto` - the smallest footprint of the enabled options that still answers
// "what is it thinking" - wired into oneshot_launch's codex form
// (bin/ac-pane-agent.sh), unconditionally, since the gate was then that table's
// one consumer. So a codex gate's activity now generally carries real
// reasoning-summary bytes when the model produces any; an empty section still
// means exactly what it always did - the model reasoned little enough that
// `auto` chose not to summarize, never a harness or board defect.
//
// Auto-open: ac-gate.sh opens a board pane PER RUN, ac-ship-watch style
// (gate-watch is per-family, like ac-ship-watch - superseding the earlier
// always-open fleet board): label ac-gate-watch:<family>, in the
// FAMILY's workspace, IN --tail MODE pinned --family - the exact prompt plus
// the live emitted output, not the row dashboard. The board is retired WITH the
// run by ac-gate.sh's own exit; the tail loop itself still never
// self-closes and is still handed no --self-pane, so nothing here claims a
// close the tail loop cannot perform. Self-close is DASHBOARD-ONLY: run
// without --tail, it exits after AC_GATE_WATCH_IDLE secs (default 1800) with no
// active gate, closing the pane named by --self-pane when one was given.
// Session: AC_HERDR_SESSION > config/herdr-session > default.
//
// ARGS, scanned in order: `--tail`; `--family`/`--stage`/`--round`/
// `--self-pane`/`--interval` each take the next word (the last one wins; a
// missing or EMPTY value is `ERROR: <flag> needs a value`, exit 1, at that
// flag); `--once`; a word starting with a digit is the interval AS TYPED
// (`5abc`, `00`, `010` are taken - the loops below say what they make of
// them); anything else is `ERROR: unknown arg: <word>`, exit 1, at that word.
// Then a --round other than 1 or 2 is `ERROR: --round must be 1 or 2`, exit 1.
// --tail wins over --once. stdin is never read.
//
// HOME: AC_HOME through physicalDir (`cd && pwd -P`). Unset, ac_home's
// `ERROR: AC_HOME is not set ...` is printed and the board goes on HOMELESS:
// data/ is `/data`, the fleet name AC_FLEET_NAME else `agent-crew`, exit 0 as
// ever (GW3). One cd cannot enter prints `ERROR: AC_HOME is not a readable
// directory: <AC_HOME>` and goes on the same way with an empty fleet name.
// Then the session is read (configReadSoft: an unreadable config/herdr-session
// is head's own line and ""), then jq: absent from PATH (`command -v`) is
// `ERROR: ac-gate-watch needs jq`, exit 1. Nothing is ever written under the
// home.
//
// COLORS only when stdout is a tty: bold `\033[1m`, reset `\033[0m`, dim
// `\033[2m`, cyan `\033[36m`, green `\033[32m`; piped, every code is "".
//
// ROWS, one per ACTIVE gate: every data/<dir>/.gate-running.<anything> (a
// non-dot dir, the empty suffix included), walked in BYTE order of the whole
// path, that is a regular file (a link to one counts) and LIVE - its meta
// `pid` (metaGet, the value cut at its first NUL as awk handed it over) all
// digits and `kill -0` succeeding: pid 0 signals the board's own group and is
// live (GW4); a process this user may not signal, or a pid past pid_t, is dead.
// An unreadable marker is metaGet's `WARN: cannot read meta file <m>` on
// stderr on every pass over the markers, and no row. The family is the dir's
// name, trailing LFs dropped as `$(dirname)` and `$(basename)` left it; the
// pins compare family, stage and round exactly. A row is the TSV line
// `<mtime>\t<family>\t<stage>\t<round>\t<engine>\t<model>\t<at>\t<observe>\t<pid>`,
// each empty field but family and pid written `-` (an empty interior field
// would collapse under the tab read), mtime the marker's own (fileMtime, a
// link's own; 0 when it cannot be stat'ed). The lines are ordered as `sort -rn`
// ordered them: by the leading number, newest first, a tie by the WHOLE line in
// reverse byte order. They are read back as `IFS=$'\t' read -r` read them
// (tabFields), so a TAB inside a value shifts the columns after it.
//
// ACTIVITY of a row: when the descriptor `observe` names is a regular file, a
// spawned `jq -r --arg k <key> '.[$k] // ""' <descriptor>` answers `out`, then
// `err` (stderr dropped, NULs dropped, trailing LFs cut: an unparsable
// descriptor or a null field is "", several JSON values give a path holding
// LFs, a number is a path); the first of the two that is a non-empty file
// whose last line - a spawned `tail -n 1`, read the same way - is not empty
// gives it. The rows are read as bash 3.2 read their here-string: from a temp
// file (TMPDIR, else /tmp; none made, no row is drawn) on an fd every child of
// the loop shares as its stdin. So GW5: an empty observe is the placeholder
// `-`, and when the cwd holds a file of that name jq is handed `-` and reads
// that stdin - each of its two reads swallows the next row line, which is then
// never drawn though n counted it. In --tail every child's stdin is the
// board's own, where jq handed `-` waits on a terminal.
//
// DASHBOARD FRAME (stdout, bytes; trailing LFs cut as `$(render)` cut them):
//   <b>ac-gate<r> <cyan><fleet><r>  <dim><n> active<r>
//   <blank>
//   <dim>(no gate running)<r>                      no row: the frame ends here
//   <dim>  family                 stage    round engine/model         since | activity<r>
//    <cyan>><r> <family %-22s> <stage %-8s> <rlabel %-5s> <eng %-20s> <dim><since><r> <activity cut>
//   <blank>
//   <dim>--tail to follow the exact prompt + live emitted output of the active gate<r>
// n counts the non-empty row lines; a row whose family field is empty is
// skipped. eng is the engine, `<engine>/<model>` when the model is not `-`;
// rlabel `r<round>`, `-` when the round is `-`; since is `at` past its last
// `T` with one trailing `Z` dropped (`now` and `-` pass through). Pads count
// BYTES, as bash's printf padded. The activity is cut to its first CUT
// characters as `cut -c1-CUT` cut them under the caller's locale (shellPrefix:
// characters under a UTF-8 LC_ALL > LC_CTYPE > LANG, bytes under any other),
// CUT = COLS-77 when COLS > 80, else 20; COLS is the first line a spawned
// `tput cols` prints (stdin kept, stderr dropped), `200` when tput fails -
// piped, tput answers TERM's terminfo width (80 for xterm) and fails when TERM
// is unset or empty, so the cut is 20 or 123.
//
// DASHBOARD LOOP: --once prints the frame and a LF, exit 0. Otherwise the
// prelude `\033[2J\033[H\033[?25l` hides the cursor, and every exit from here
// on restores it with `\033[?25h`. Each tick renders the frame and paints it
// only when it differs from the last one painted: `\033[H`, every frame line
// followed by `\033[K`, `\033[J\n`. Then idle time: `waited` is 0 while a row is
// active, else it grows by the interval as the shell's `$((waited + INTERVAL))`
// read it (arithValue: `010` is 8, `00` adds nothing, so that board never
// idles out); an interval that is no arithmetic operand (`5abc`, `0.5`, `08`,
// `abc`) ends the board 1 at its first idle tick (GW2, GW8). Once `waited`
// exceeds AC_GATE_WATCH_IDLE (unset or empty: 1800; no `[ -gt ]` integer:
// never) the board prints `\nno active gate - closing watch\n`, sleeps 2, closes
// the pane --self-pane named - `herdr --session <session> pane close <id>` when
// herdr is on PATH, stdout and stderr dropped, its status ignored, whatever the
// backend - and exits 0. Each tick ends in a spawned `sleep <interval as
// typed>` (stdio inherited, a PATH stub fast-forwards it; its failure is
// ignored, so an interval sleep refuses spins the loop while a gate is
// active).
//
// --tail LOOP: the header `<b>ac-gate<r> <cyan><fleet><r> <dim>- following the
// active second-chief run (Ctrl-C to quit)<r>`, then each tick the FIRST row.
// None: once per waiting spell, `<dim>  (settled - prompt retained at
// <prompt>)<r>` when a prompt path was known, then `<dim>  ... waiting for an
// active gate ...<r>`. A row whose `<family>/<stage>/<round>/<observe>` is not
// the one followed: `\n<cyan>== <family> / <stage> / <rlabel>  [<eng>] ==<r>`,
// and the prompt, the streams and their offsets are forgotten. The descriptor
// is re-read every tick, since the marker lands before the pane agent
// publishes it: a non-empty prompt, out or err path that differs is adopted (a
// stream from offset 0, the prompt shown again). The prompt, once per
// adoption, when it is a regular file: `<dim>-- prompt --<r>\n`, its bytes (a
// spawned cat), `\n`. `<dim>-- activity/output (live emitted bytes) --<r>\n`
// once, when a stream path is known. Then err's, then out's NEW bytes: a
// stream that is a regular file whose size (the opened file's; one that
// cannot be opened prints nothing) passed its offset prints a spawned `tail -c
// +<offset+1>` of it, stdout inherited, and the offset becomes that size - out
// wrapped in green on a tty. Then the tick's sleep. The tail loop never ends
// on its own (no --self-pane is ever handed to it).
//
// SIGNALS: the dashboard loop (not --once) restores the cursor on HUP, INT
// and TERM and exits 128+n; --once and --tail register no handler and end on
// the signal's default action.
//
// ESCAPE HATCH. A broken board costs a gate only its observer: ac-gate opens it
// fail-soft and nothing parses what it prints. If a landed change breaks this
// module, run the frozen original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-gate-watch.sh "$o/bin/ac-gate-watch.sh"
// then "$o/bin/ac-gate-watch.sh" --tail --family <family> (or the dashboard)
// by hand; a gate started as "$o/bin/ac-gate.sh" opens its board from "$o/bin"
// too, because the launch line names the bin root the gate started from. The
// captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - GW3: homeless, the refusal is printed and the board renders `/data`, exit 0.
// - GW4: a marker whose pid is 0 is live.
// - GW2/GW8: an interval that is no arithmetic operand ends the dashboard 1 at
//   its first idle tick, its pane left open; `0`/`00` never idle out; while a
//   gate is active the interval is never evaluated, only handed to sleep.
// - GW5: an empty `observe=` hands jq `-` when the cwd holds a file of that
//   name: a dashboard row line swallowed per read, a --tail board waiting on
//   its terminal.
// - An unreadable marker warns on every pass over the markers (twice a
//   dashboard tick).
// - The self-close is RAW herdr whatever the backend, so an orca fleet's
//   board never closes its pane.
// - A TAB inside a marker value shifts the row's columns.
//
// DIVERGENCES from the frozen original (the leg names each one a row can show):
// - FAIL-PATH (GW6, GW7, GW10): under a UTF-8 locale the original's BSD tools
//   aborted on a byte that is no UTF-8 - `cut` cut the activity at it (`cut:
//   stdin: Illegal byte sequence`), and `sort` dropped EVERY row when one
//   marker value held one (`sort: Illegal byte sequence`: `0 active`, the
//   dashboard idling out under a live gate, --tail waiting), which left the
//   paint's `sed` no such byte to abort on. Here such a byte is one character
//   to the cut, the rows are ordered by bytes and the frame is painted whole.
// - TIE ORDER: rows of one mtime are ordered by reverse BYTE order of the whole
//   line under every locale, where `sort` collated them under UTF-8.
// - WARN ORDER: markers are walked in byte order of their paths, where bash's
//   glob followed the locale's collation under UTF-8.
// - SIGNALS: a SIGINT to the board's pid ALONE ends it 130 (the dashboard
//   restoring the cursor first), where bash swallowed it while its sleep child
//   ran and went on; ctrl-c, which reaches both, ends both alike. The
//   dashboard EXITS 128+n after its restore, where bash, its EXIT trap done,
//   re-raised the signal: the shell's `$?` reads the same, a parent reading the
//   wait status sees an exit, not a signal. The handlers are installed even
//   when INT was ignored at entry, which bash would have left ignored.
// - SHELL-OWN STDERR is not reproduced, the status kept: `${2:?}`'s
//   `parameter null or not set` is `ERROR: <flag> needs a value` (exit 1
//   both); the interval's arithmetic error and unbound variable (exit 1 both);
//   `[`'s `integer expression expected` for a non-integer AC_GATE_WATCH_IDLE
//   (never closes, both) or an unreadable stream (nothing printed, both);
//   `sleep: command not found`.
// - HOME RESOLUTION: an AC_HOME cd cannot enter prints the one ERROR line
//   above, where the shell printed cd's own line at each read of the home (at
//   start, at the session read, at every render and in the tail's header); a
//   relative AC_HOME is resolved without CDPATH. A home whose name ends in LF
//   is read as named, where `$(...)` dropped the LF and read the sibling's
//   data/.
// - INTERVAL ARITHMETIC: an interval that is a whole expression (`1+1`) or
//   names a variable holding a number (`waited`, `SECONDS`) ends the
//   dashboard 1 at its first idle tick, where bash evaluated it.
// - BYTES: argv arrives decoded and config/herdr-session is read as UTF-8, so
//   a pin, an interval, a pane id or a session byte that is no UTF-8 is
//   U+FFFD; a marker value naming a path with such a byte reaches jq, tail and
//   cat decoded.
// - BUN IN THE PANE: the board's pane runs bun; without it on the pane's PATH
//   the shim's `ERROR: required tool not found: bun` is all the pane shows,
//   and ac-gate reads that pane dead and replaces it at every run, where the
//   original needed bash and jq.
// - A caller whose cwd has no name reads relative descriptor paths (and `-`)
//   from the distro root.
//
// CALLERS: src/gate.ts's watchOpen runs `AC_HOME=<home> '<its bin>/
// ac-gate-watch.sh' --tail --family <family>` in a herdr pane (fail-soft) and
// its watchStalePane reads that board live while the pane's foreground
// cmdline matches `ac-gate-watch\.sh|/src/gate-watch\.ts` - the shim execs bun,
// so the cmdline names this file; operators run it by hand. Nothing parses
// what it prints: tests/sh/ac-gate-watch.test.sh and tests/sh/ac-gate.test.sh's
// board rows read it as text.
import { closeSync, fstatSync, openSync, readSync, readdirSync, statSync, unlinkSync, writeSync } from "node:fs";
import { isatty } from "node:tty";
import {
  NO_HOME,
  arithValue,
  commandV,
  configReadSoft,
  die,
  enterCaller,
  fileMtime,
  fleetName,
  metaGet,
  physicalDir,
  shellPrefix,
  shellStatus,
  spawnShell,
  spawnShellSync,
  tabFields,
  testInt,
} from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv, the env and
// the lib's paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

function out(s: string): void {
  const b = fsPath(s);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

type Io = "inherit" | "pipe" | "ignore";

// A child as the original ran it: stdin inherited (or the rows loop's fd),
// stderr dropped; its stdout read as `$(...)` read it, or left on ours.
function run(cmd: string[], stdout: Io, stdin: "inherit" | number = "inherit"): { status: number; out: string } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd.map(u8), { stdin, stdout, stderr: "ignore" });
  } catch {}
  return { status: shellStatus(r), out: r && stdout === "pipe" ? subst(r.stdout) : "" };
}

const stat = (p: string): ReturnType<typeof statSync> | null => {
  try {
    return statSync(fsPath(p));
  } catch {
    return null;
  }
};
const isFile = (p: string): boolean => stat(p)?.isFile() ?? false;

const { args } = enterCaller(process.argv.slice(2));

let mode = "dashboard";
let interval = "2";
let once = false;
let self = "";
let pinFam = "";
let pinStage = "";
let pinRound = "";
for (let i = 0; i < args.length; i++) {
  const a = args[i]!;
  const value = (): string => {
    const v = args[++i] ?? "";
    if (v === "") die(`${a} needs a value`);
    return b8(v);
  };
  if (a === "--tail") mode = "tail";
  else if (a === "--family") pinFam = value();
  else if (a === "--stage") pinStage = value();
  else if (a === "--round") pinRound = value();
  else if (a === "--self-pane") self = value();
  else if (a === "--interval") interval = value();
  else if (a === "--once") once = true;
  else if (/^[0-9]/.test(a)) interval = b8(a);
  else die(`unknown arg: ${a}`);
}
if (pinRound !== "" && pinRound !== "1" && pinRound !== "2") die("--round must be 1 or 2");

let home = "";
const envHome = process.env.AC_HOME;
if (!envHome) writeSync(2, `ERROR: ${NO_HOME}\n`);
else {
  const p = physicalDir(envHome);
  if (p === null) writeSync(2, `ERROR: AC_HOME is not a readable directory: ${envHome}\n`);
  else home = b8(p);
}
const data = `${home}/data`;
const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
if (!commandV("jq")) die("ac-gate-watch needs jq");

const tty = isatty(1);
const C_R = tty ? "\x1b[0m" : "";
const C_B = tty ? "\x1b[1m" : "";
const C_DIM = tty ? "\x1b[2m" : "";
const C_CYN = tty ? "\x1b[36m" : "";
const C_GRN = tty ? "\x1b[32m" : "";

const fleet = (): string => b8(fleetName()).replace(/\n+$/, "");
const pad = (s: string, w: number): string => s + " ".repeat(Math.max(0, w - s.length));
const rlabel = (round: string): string => (round !== "-" ? `r${round}` : "-");
const eng = (engine: string, model: string): string => (model !== "" && model !== "-" ? `${engine}/${model}` : engine);

// The value as awk handed it to the shell: a C string, cut at its first NUL;
// an unreadable meta is "" after metaGet's warning, the status the `$(...)`
// swallowed.
function meta(m: string, key: string): string {
  try {
    return metaGet(u8(m), key).replace(/\0[\s\S]*$/, "");
  } catch {
    return "";
  }
}

// `kill -0`: a pid this user may not signal reads dead, unlike pidAlive, and
// 0 - the board's own process group - reads live.
function markerLive(m: string): boolean {
  const pid = meta(m, "pid");
  if (!/^[0-9]+$/.test(pid)) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function markers(): string[] {
  const found: string[] = [];
  let dirs: string[];
  try {
    dirs = readdirSync(fsPath(data), { encoding: "latin1" });
  } catch {
    return found;
  }
  for (const d of dirs) {
    if (d.startsWith(".")) continue;
    let names: string[];
    try {
      names = readdirSync(fsPath(`${data}/${d}`), { encoding: "latin1" });
    } catch {
      continue;
    }
    for (const n of names) if (n.startsWith(".gate-running.")) found.push(`${data}/${d}/${n}`);
  }
  return found.sort();
}

const sortKey = (l: string): number => Number(/^[ \t]*(-?[0-9]+(?:\.[0-9]*)?)/.exec(l)?.[1] ?? 0);

// active_rows' lines as `sort -rn` left them. A family name holding a LF
// splits its row into lines of their own, as it split the TSV.
function activeRows(): string[] {
  const lines: string[] = [];
  for (const m of markers()) {
    if (!isFile(m) || !markerLive(m)) continue;
    // A name of LFs only left `$(dirname)` the data dir itself.
    const fam = m.slice(data.length + 1, m.lastIndexOf("/")).replace(/\n+$/, "") || "data";
    if (pinFam !== "" && pinFam !== fam) continue;
    const stage = meta(m, "stage");
    if (pinStage !== "" && pinStage !== stage) continue;
    const round = meta(m, "round");
    if (pinRound !== "" && pinRound !== round) continue;
    const engine = meta(m, "engine");
    const model = meta(m, "model");
    const at = meta(m, "at");
    const obs = meta(m, "observe");
    const pid = meta(m, "pid");
    const mt = fileMtime(fsPath(m)) ?? "0";
    lines.push(...`${mt}\t${fam}\t${stage || "-"}\t${round || "-"}\t${engine || "-"}\t${model || "-"}\t${at || "-"}\t${obs || "-"}\t${pid}`.split("\n"));
  }
  return lines.sort((a, b) => sortKey(b) - sortKey(a) || (a < b ? 1 : a > b ? -1 : 0));
}

function obsField(obs: string, key: string, stdin: "inherit" | number = "inherit"): string {
  if (!isFile(obs)) return "";
  return run(["jq", "-r", "--arg", "k", key, '.[$k] // ""', obs], "pipe", stdin).out;
}

function lastActivity(obs: string, stdin: number): string {
  if (obs === "") return "";
  const streams = [obsField(obs, "out", stdin), obsField(obs, "err", stdin)];
  for (const f of streams) {
    if (f === "" || !((stat(f)?.size ?? 0) > 0)) continue;
    const line = run(["tail", "-n", "1", f], "pipe", stdin).out;
    if (line !== "") return line;
  }
  return "";
}

// `<<<"$rows"` as bash 3.2 made it: the text and a LF in a temp file, unlinked
// and left open at offset 0 - in TMPDIR, else /tmp, as bash fell back.
function hereString(text: string): number | null {
  const b = fsPath(`${text}\n`);
  for (const dir of [process.env.TMPDIR, "/tmp"]) {
    if (!dir) continue;
    const p = `${dir.replace(/\/+$/, "")}/ac-gate-watch-rows.${process.pid}`;
    let fd: number;
    try {
      fd = openSync(p, "wx+");
    } catch {
      continue;
    }
    try {
      unlinkSync(p);
      for (let off = 0; off < b.length; ) off += writeSync(fd, b, off, b.length - off, off);
      return fd;
    } catch {
      closeSync(fd);
    }
  }
  return null;
}

// `read -r` off that fd a byte at a time, so a child spawned meanwhile starts
// just past the line; a last line with no LF is never read.
function readLine(fd: number): string | null {
  const one = Buffer.alloc(1);
  let line = "";
  while (readSync(fd, one, 0, 1, null) === 1) {
    if (one[0] === 0x0a) return line;
    line += String.fromCharCode(one[0]!);
  }
  return null;
}

// `(tput cols 2>/dev/null || echo 200) | head -1`.
function columns(): number {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["tput", "cols"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  let text = r ? Buffer.from(r.stdout).toString("latin1") : "";
  if (shellStatus(r) !== 0) text += "200\n";
  return Number(text.split("\n", 1)[0]!.replace(/\0/g, "")) || 0;
}

function render(): string {
  const width = columns();
  const name = fleet();
  const rows = activeRows()
    .map((l) => `${l}\n`)
    .join("")
    .replace(/\n+$/, "");
  const n = rows === "" ? 0 : rows.split("\n").filter((l) => l !== "").length;
  let s = `${C_B}ac-gate${C_R} ${C_CYN}${name}${C_R}  ${C_DIM}${n} active${C_R}\n\n`;
  if (rows === "") return `${s}${C_DIM}(no gate running)${C_R}`;
  s += `${C_DIM}  ${pad("family", 22)} ${pad("stage", 8)} ${pad("round", 5)} ${pad("engine/model", 20)} since | activity${C_R}\n`;
  const cut = width > 80 ? width - 77 : 20;
  const fd = hereString(rows);
  if (fd !== null) {
    try {
      for (let line = readLine(fd); line !== null; line = readLine(fd)) {
        const [, fam = "", stage = "", round = "", engine = "", model = "", at = "", obs = ""] = tabFields(line, 9);
        if (fam === "") continue;
        const when = at.slice(at.lastIndexOf("T") + 1).replace(/Z$/, "");
        const act = shellPrefix(lastActivity(obs, fd), cut);
        s += ` ${C_CYN}>${C_R} ${pad(fam, 22)} ${pad(stage, 8)} ${pad(rlabel(round), 5)} ${pad(eng(engine, model), 20)} ${C_DIM}${when}${C_R} ${act}\n`;
      }
    } finally {
      closeSync(fd);
    }
  }
  return `${s}\n${C_DIM}--tail to follow the exact prompt + live emitted output of the active gate${C_R}`;
}

const paint = (frame: string): void =>
  out(`\x1b[H${frame
    .split("\n")
    .map((l) => `${l}\x1b[K`)
    .join("\n")}\x1b[J\n`);

// The tick's sleep, spawned so a PATH stub fast-forwards it; awaited, so a
// signal handler runs while it waits. One that cannot start still yields to
// the event loop, or a handler could never run.
async function nap(secs: string): Promise<void> {
  try {
    await spawnShell(["sleep", u8(secs)], { stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  } catch {
    await Bun.sleep(0);
  }
}

function size(p: string): number | null {
  let fd: number;
  try {
    fd = openSync(fsPath(p), "r");
  } catch {
    return null;
  }
  try {
    return fstatSync(fd).size;
  } catch {
    return null;
  } finally {
    closeSync(fd);
  }
}

async function tailLoop(): Promise<never> {
  let cur = "__none__";
  let prompt = "";
  let outF = "";
  let errF = "";
  let offOut = 0;
  let offErr = 0;
  let shownPrompt = false;
  let announced = false;
  // Name the fleet home, exactly as the dashboard header does: a host runs
  // several homes and a tail board that names none leaves the operator unable to
  // tell WHICH fleet it is watching.
  out(`${C_B}ac-gate${C_R} ${C_CYN}${fleet()}${C_R} ${C_DIM}- following the active second-chief run (Ctrl-C to quit)${C_R}\n`);
  for (;;) {
    const row = activeRows()[0] ?? "";
    if (row === "") {
      if (cur !== "__wait__") {
        if (prompt !== "") out(`${C_DIM}  (settled - prompt retained at ${prompt})${C_R}\n`);
        out(`${C_DIM}  ... waiting for an active gate ...${C_R}\n`);
      }
      cur = "__wait__";
      await nap(interval);
      continue;
    }
    const [, fam = "", stage = "", round = "", engine = "", model = "", , obs = ""] = tabFields(row, 9);
    const target = `${fam}/${stage}/${round}/${obs}`;
    if (cur !== target) {
      cur = target;
      prompt = outF = errF = "";
      shownPrompt = announced = false;
      offOut = offErr = 0;
      out(`\n${C_CYN}== ${fam} / ${stage} / ${rlabel(round)}  [${eng(engine, model)}] ==${C_R}\n`);
    }

    // The marker is published before pane-agent atomically publishes its
    // observation descriptor. Re-read until the descriptor is ready instead of
    // permanently pinning empty paths from that startup window.
    const nextPrompt = obsField(obs, "prompt");
    const nextOut = obsField(obs, "out");
    const nextErr = obsField(obs, "err");
    if (nextPrompt !== "" && nextPrompt !== prompt) {
      prompt = nextPrompt;
      shownPrompt = false;
    }
    if (nextOut !== "" && nextOut !== outF) {
      outF = nextOut;
      offOut = 0;
    }
    if (nextErr !== "" && nextErr !== errF) {
      errF = nextErr;
      offErr = 0;
    }

    if (!shownPrompt && prompt !== "" && isFile(prompt)) {
      out(`${C_DIM}-- prompt --${C_R}\n`);
      run(["cat", prompt], "inherit");
      out("\n");
      shownPrompt = true;
    }
    if (!announced && (outF !== "" || errF !== "")) {
      out(`${C_DIM}-- activity/output (live emitted bytes) --${C_R}\n`);
      announced = true;
    }
    if (errF !== "" && isFile(errF)) {
      const se = size(errF);
      if (se !== null && se > offErr) {
        run(["tail", "-c", `+${offErr + 1}`, errF], "inherit");
        offErr = se;
      }
    }
    if (outF !== "" && isFile(outF)) {
      const so = size(outF);
      if (so !== null && so > offOut) {
        out(C_GRN);
        run(["tail", "-c", `+${offOut + 1}`, outF], "inherit");
        out(C_R);
        offOut = so;
      }
    }
    await nap(interval);
  }
}

async function dashboard(): Promise<never> {
  if (once) {
    out(`${render()}\n`);
    process.exit(0);
  }
  out("\x1b[2J\x1b[H\x1b[?25l");
  process.on("exit", () => {
    try {
      writeSync(1, "\x1b[?25h");
    } catch {}
  });
  for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
  const idle = testInt(process.env.AC_GATE_WATCH_IDLE || "1800");
  let last = "";
  let waited = 0n;
  for (;;) {
    const frame = render();
    if (frame !== last) {
      paint(frame);
      last = frame;
    }
    // Idle is time with NO active gate: a live gate's marker is written once at
    // its start, so its age says nothing about whether the board is needed.
    if ((activeRows()[0] ?? "") !== "") waited = 0n;
    else {
      try {
        waited = BigInt.asIntN(64, waited + arithValue(interval));
      } catch {
        process.exit(1);
      }
      if (idle !== null && waited > idle) {
        out("\nno active gate - closing watch\n");
        await nap("2");
        if (self !== "" && commandV("herdr")) run(["herdr", "--session", ses, "pane", "close", self], "ignore");
        process.exit(0);
      }
    }
    await nap(interval);
  }
}

if (mode === "tail") await tailLoop();
await dashboard();
