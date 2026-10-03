// dash.ts - the captain dashboard in the TERMINAL (the web one is
// dashboard/app.ts): one render of five sections, or `--watch` redrawing it
// forever. The entry is bin/ac-dash.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-dash.sh as the oracle the
// differential leg of tests/sh/ac-dash.test.sh holds this module to.
//
//   ac-dash.sh                # render once, exit 0
//   ac-dash.sh --watch [<s>]  # clear, render, trailer, sleep <s> (default 5),
//                             # forever; ctrl-c (SIGINT) ends it with exit 0
//
// ARGS: only the first is inspected - `--watch` takes the second as the
// interval AS TYPED (`--watch ""` is 5; later words are ignored); absent or ""
// renders once (`ac-dash.sh "" extra` renders); anything else, `-h`/`--help`
// included, prints `usage: ac-dash.sh [--watch [<seconds>]]` on stderr and
// exits 2 before the home is looked at. stdin is never read.
//
// COLORS are on only when stdout is a tty AND NO_COLOR is unset or EMPTY:
// header `\033[1;36m`, green `\033[32m`, yellow `\033[33m`, red `\033[1;31m`,
// dim `\033[2m`, reset `\033[0m`; piped, every code is "". A crew row carries
// the reset code on both sides of the id even when uncolored.
//
// HOME: AC_HOME through physicalDir (`cd && pwd -P`). Unset -> ac_home's
// refusal, exit 1, nothing on stdout; not enterable -> `AC_HOME is not a
// readable directory: <AC_HOME>`, exit 1. The view MINTS state/, records/ and
// projects/ (stateDir, recordsDir, projectsDir - the mkdir -p of the path
// helpers the original called; config/ and data/ are not minted).
//
// RENDER (stdout, bytes; `%-Ns` pads by BYTES like bash's printf, never cuts):
//   ⚓ <basename of the physical home>  captain: <c>  backend: <b>  flow: <f>
//       c/b/f = config/captain|backend|flow, first line, [:space:]-trimmed under
//       the locale bash was given (configReadDir), NULs dropped; defaults
//       captain / herdr / auto when absent; "" when present but unreadable (the
//       original's `head` failed inside the substitution; its stderr is the
//       tool's own and not reproduced).
//   <blank>
//   CREW
//     <id %-16s> <kind %-10s> <project %-14s> <state>   per state/<n>.meta
//     (no crewmates in flight)                           when no crew row
//   <blank> + VERIFY (verification agents, not crew) + the same rows,
//       only when at least one meta is a verifier (metaIsVerify), in the same
//       order they were met, after the CREW block.
//   <blank>
//   ROOMS (captain inbox)
//     <line>                                             per line of <bin>/ac-room.sh list
//     WARN   rooms unreadable - the inbox is UNKNOWN, not empty (bin/ac-room.sh list)
//                                                        appended when list fails
//   <blank>
//   BACKLOG  in-flight:<f>  queued:<q>  done:<d>         NO newline after BACKLOG:
//                                                        the count line's two leading
//                                                        spaces follow it directly
//   BACKLOG  WARN   backlog unavailable: the parser exited <N> - rerun to see why
//   BACKLOG  (no backlog yet)                            records/backlog.md not a regular file
//   <blank>
//   POOLS
//     <project %-20s> leased:<n> avail:<m>               per projects/<p>/.crew/slots DIRECTORY
//     (no worktree pools yet)
//
// CREW rows: every non-dot `*.meta` entry of state/ that exists (a dangling
// symlink is skipped; a DIRECTORY named x.meta is a row - `[ -e ]` admitted it),
// in BYTE order; id = the name less `.meta`; kind and project by metaGet (last
// key wins, the value cut at its first NUL as awk handed it to the shell);
// state = the stdout of `<bin>/ac-crew-state.sh <id>` (stderr dropped) PLUS
// `unknown` when it exits non-zero or cannot start, NULs dropped and trailing
// LFs stripped as `$(...)` did - so a child that printed and then failed reads
// `<its text>unknown`, and a two-line answer embeds its LF raw. The state's
// color: green when it holds `done:` or `resolved:`; red when it holds
// `blocked:`, `failed:` or `needs-decision:` or STARTS with `gone`; else yellow.
// Verifiers (kind `verify-*`) are held back for the VERIFY block.
// ERREXIT CONTEXT, reproduced: the kind read was a bare assignment, so ONE meta
// this user cannot read ends the run - metaGet's `WARN: cannot read meta file
// <p>` on stderr, exit 1, the rows before it already printed and nothing after
// (the project read never runs). Every other read of the render sat inside a
// `$(...)`, an `if` or an `||` and reads on.
//
// ROOMS: `<bin>/ac-room.sh list` (stdout streamed, stderr dropped); when it
// exits non-zero (or cannot start) the WARN line is appended to whatever it
// printed - joined to an unterminated last line. The stream is then read as
// `read -r` read it: split on LF, an unterminated last line DROPPED, each line
// cut at its first NUL. A line starting `PENDING-CAPTAIN` or `WARN` is red,
// every other dim, each indented two spaces.
//
// BACKLOG: records/backlog.md must be a regular file (`[ -f ]`; a directory or
// an absent file is `(no backlog yet)`). The count walks the file's records as
// `LC_ALL=C awk` read them - split on LF, the empty element after a final LF
// dropped, CR kept, a record cut at its first NUL: `## ` starts a section
// (`## In flight`, `## Queued`, `## Done` by PREFIX - `## Done (archive)` is
// Done - any other `## ` header ends the section); a `- [` row (ANY bracket
// content) counts in its section, rows before the first header count nowhere;
// a Done row counts unless its terminal token (src/backlog.ts's `terminal`
// field) is `failed` or `abandoned`. The parser is run as the bash binding ran
// it: ONE child `src/backlog.ts fields <file>` (bunChild) started at the FIRST
// Done row - a ledger without one never starts it - its `r\t` records keyed by
// raw line, its `e\t<n>` trailer the proof it finished. The WARN line replaces
// the counts (exit of the render unchanged) when: the file cannot be read
// (N=2, awk's status on `can't open file`; awk's own stderr line is not
// reproduced, nothing is printed); the child ended non-zero (N = its status,
// 128+signal when signalled - where the awk could only ever report its own 2;
// not reachable differentially, named); the trailer is missing or disagrees
// with the record count, or a Done row is not among the records (N=2 with the
// binding's own `ERROR: the backlog parser failed on <file>` / `ERROR: <file>
// changed between the parse and this read` on stderr, as `_dl_die` printed).
// The child's own stderr passes through.
//
// POOLS: every projects/<p>/.crew/slots that is a directory, <p> non-dot, in
// BYTE order of <p>; per non-dot `*.meta` REGULAR file in it, `leased` by
// metaGet: exactly `1` is leased, anything else (`0`, `01`, absent) is avail;
// an unreadable one is metaGet's WARN on stderr and avail (the read sat inside
// an `if`). An empty slots dir prints `leased:0 avail:0`.
//
// --watch: ONE long-running process. Per frame: `clear` spawned with inherited
// stdio (its bytes are the binary's and depend on TERM; a non-zero exit ends
// the run with that status, as `set -e` did), the render, then the dim trailer
// `\n(refreshing every <s>s - ctrl-c to stop)\n`, then `sleep <s>` spawned
// with inherited stdio - a PATH stub fast-forwards it on both sides - whose
// non-zero exit ends the run with that status after that one frame (`--watch
// abc`: sleep's own usage on stderr, exit 1), a binary that cannot start with
// 127. SIGINT ends the run with exit 0 (`trap 'exit 0' INT`); a render that
// dies (unreadable meta, no home) ends it with 1.
//
// WHO READS IT: captains by hand; tests/sh/ac-dash.test.sh,
// ac-room.test.sh (exit 0 and `inbox is UNKNOWN` on an unreadable room) and
// ac-backlog-sections.test.sh (the counts line). No bin/, src/, dashboard/,
// .agents/ or .claude/ caller - the four bin/ mentions are comments - so a
// bun-less run (the shim's `required tool not found: bun`, exit 1) costs no
// set -e caller; the three tests red.
//
// BINARIES: <bin>/ac-crew-state.sh per meta, <bin>/ac-room.sh list,
// src/backlog.ts (bunChild), clear and sleep (--watch). <bin> is the bin/ this
// module was STARTED from (process.cwd() before enterCaller leaves it -
// bin/ac-bun.sh runs bun in <bin>/..), so a copied bin/ drives its own
// siblings. ac-backend.sh, which the original sourced and never called, is
// not read.
//
// NAMED DIVERGENCES from the frozen original: a homeless run dies ONCE with
// the refusal and prints nothing, where the original printed it three times
// around a header/CREW/ROOMS render and died at `BACKLOG` (exit 1 both); an
// AC_HOME that cannot be entered names the variable where the shell printed
// its `cd:` lines (exit 1 both; HOME RESOLUTION ruling); metas and pools are
// listed in byte order (bash's glob followed libc collation under a UTF-8
// locale); awk's `can't open file` line and `head`'s permission line are not
// reproduced; N on a child that ended non-zero is the child's; a SIGINT
// addressed to the process ALONE while its sleep runs ends --watch here, where
// bash ran its INT trap only once the foreground child had died of the INT
// (ctrl-c, which reaches both, ends both). Everything else - the three minted
// dirs, the directory row, the one-meta death, the joined WARN line, the
// dropped unterminated room line - is reproduced.
import { existsSync, readdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { isatty } from "node:tty";
import { bunChild, configReadDir, die, enterCaller, metaGet, metaIsVerify, NO_HOME, physicalDir, projectsDir, recordsDir, stateDir } from "./lib.ts";

const bin = `${process.cwd()}/bin`;
const { args } = enterCaller(process.argv.slice(2));

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const ANCHOR = bytes("⚓");

const color = isatty(1) && !process.env.NO_COLOR;
const C_H = color ? "\x1b[1;36m" : "";
const C_G = color ? "\x1b[32m" : "";
const C_Y = color ? "\x1b[33m" : "";
const C_R = color ? "\x1b[1;31m" : "";
const C_D = color ? "\x1b[2m" : "";
const C_0 = color ? "\x1b[0m" : "";

function write(fd: number, s: string): void {
  const b = Buffer.from(s, "latin1");
  for (let off = 0; off < b.length; ) off += writeSync(fd, b, off, b.length - off);
}
const out = (s: string): void => write(1, s);

const padBytes = (b: string, w: number): string => b + " ".repeat(Math.max(0, w - b.length));
const stateColor = (s: string): string =>
  s.includes("done:") || s.includes("resolved:") ? C_G : s.includes("blocked:") || s.includes("failed:") || s.includes("needs-decision:") || s.startsWith("gone") ? C_R : C_Y;

const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const listDir = (d: string): string[] => {
  try {
    return readdirSync(d)
      .filter((n) => !n.startsWith("."))
      .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  } catch {
    return [];
  }
};
// The value as awk handed it to the shell: a C string, cut at its first NUL.
const meta = (file: string, key: string): string => metaGet(file, key).replace(/\0[\s\S]*$/, "");

// The shell's status for a child: its exit, 128+signal when a signal ended it.
function status(r: { exitCode: number | null; signalCode: NodeJS.Signals | null }): number {
  if (r.exitCode !== null) return r.exitCode;
  return 128 + ((osConstants.signals as Record<string, number>)[r.signalCode ?? ""] ?? 0);
}

// `$(cmd 2>/dev/null || printf unknown)`: the child's stdout, `unknown`
// appended when it failed, NULs dropped, trailing LFs stripped.
function crewState(id: string): string {
  let text = "";
  let failed = false;
  try {
    const r = Bun.spawnSync([`${bin}/ac-crew-state.sh`, id], { stdin: "ignore", stdout: "pipe", stderr: "ignore", env: process.env });
    text = r.stdout.toString("latin1");
    failed = r.exitCode !== 0;
  } catch {
    failed = true;
  }
  if (failed) text += "unknown";
  return text.replace(/\0/g, "").replace(/\n+$/, "");
}

function renderCrew(sd: string): void {
  out(`\n${C_H}CREW${C_0}\n`);
  let found = false;
  let verify = "";
  for (const n of listDir(sd)) {
    const m = `${sd}/${n}`;
    if (!n.endsWith(".meta") || !existsSync(m)) continue;
    const id = n.slice(0, -".meta".length).replace(/\n+$/, "");
    let kind = "", project = "";
    try {
      kind = meta(m, "kind");
      project = meta(m, "project");
    } catch {
      // The bare assignment under errexit: metaGet has warned, the run ends.
      process.exit(1);
    }
    const state = crewState(id);
    const row = `  ${C_0}${padBytes(bytes(id), 16)}${C_0} ${padBytes(kind, 10)} ${padBytes(project, 14)} ${stateColor(state)}${state}${C_0}`;
    if (metaIsVerify(m)) verify += `${row}\n`;
    else {
      found = true;
      out(`${row}\n`);
    }
  }
  if (!found) out(`  ${C_D}(no crewmates in flight)${C_0}\n`);
  if (verify !== "") out(`\n${C_H}VERIFY (verification agents, not crew)${C_0}\n${verify}`);
}

function renderRooms(): void {
  out(`\n${C_H}ROOMS (captain inbox)${C_0}\n`);
  let text = "";
  let failed = false;
  try {
    const r = Bun.spawnSync([`${bin}/ac-room.sh`, "list"], { stdin: "ignore", stdout: "pipe", stderr: "ignore", env: process.env });
    text = r.stdout.toString("latin1");
    failed = r.exitCode !== 0;
  } catch {
    failed = true;
  }
  if (failed) text += "WARN   rooms unreadable - the inbox is UNKNOWN, not empty (bin/ac-room.sh list)\n";
  const lines = text.split("\n");
  lines.pop();
  for (const raw of lines) {
    const line = raw.replace(/\0[\s\S]*$/, "");
    const c = line.startsWith("PENDING-CAPTAIN") || line.startsWith("WARN") ? C_R : C_D;
    out(`  ${c}${line}${C_0}\n`);
  }
}

// awk's records under LC_ALL=C: LF-split, no empty record after a final LF,
// CR kept, each cut at its first NUL (src/backlog.ts reads the same way).
function awkRecords(text: string): string[] {
  const r = text.split("\n");
  if (r[r.length - 1] === "") r.pop();
  return r.map((l) => l.split("\0", 1)[0]!);
}

class ParserFailed extends Error {
  constructor(public rc: number) {
    super();
  }
}

// The binding's _dl_load: the parser's wire read once, `r\t` records keyed by
// their raw line, the `e\t<n>` trailer the proof the parse finished.
function loadTerminals(file: string): Map<string, string> {
  let r: ReturnType<typeof Bun.spawnSync>;
  const child = bunChild("src/backlog.ts", ["fields", file]);
  try {
    r = Bun.spawnSync(child.cmd, { cwd: child.cwd, env: child.env, stdin: "ignore", stdout: "pipe", stderr: "inherit" });
  } catch {
    write(2, `ERROR: the backlog parser failed on ${file}\n`);
    throw new ParserFailed(2);
  }
  if (r.exitCode !== 0) throw new ParserFailed(status(r));
  const recs = new Map<string, string>();
  let n = 0;
  let ok = false;
  for (const line of r.stdout.toString("latin1").split("\n")) {
    if (line.startsWith("r\t")) {
      let p = 1;
      for (let i = 0; i < 14; i++) p = line.indexOf("\t", p + 1);
      recs.set(line.slice(p + 1), line.slice(2, p).split("\t")[1] ?? "");
      n++;
    } else if (line.startsWith("e\t")) ok = Number(line.slice(2)) === n;
  }
  if (!ok) {
    write(2, `ERROR: the backlog parser failed on ${file}\n`);
    throw new ParserFailed(2);
  }
  return recs;
}

function backlogCounts(file: string): string {
  let text: string;
  try {
    text = readFileSync(file, "latin1");
  } catch {
    throw new ParserFailed(2);
  }
  let s = "";
  let f = 0, q = 0, d = 0;
  let terminals: Map<string, string> | null = null;
  for (const rec of awkRecords(text)) {
    if (rec.startsWith("## ")) s = "";
    if (rec.startsWith("## In flight")) { s = "f"; continue; }
    if (rec.startsWith("## Queued")) { s = "q"; continue; }
    if (rec.startsWith("## Done")) { s = "d"; continue; }
    if (!rec.startsWith("- [")) continue;
    if (s === "d") {
      if (terminals === null) terminals = loadTerminals(file);
      const t = terminals.get(rec);
      if (t === undefined) {
        write(2, `ERROR: ${file} changed between the parse and this read\n`);
        throw new ParserFailed(2);
      }
      if (t !== "failed" && t !== "abandoned") d++;
    } else if (s === "f") f++;
    else if (s === "q") q++;
  }
  return `  in-flight:${f}  queued:${q}  done:${d}\n`;
}

function renderBacklog(rd: string): void {
  out(`\n${C_H}BACKLOG${C_0}`);
  const bl = `${rd}/backlog.md`;
  if (!isFile(bl)) {
    out(`  ${C_D}(no backlog yet)${C_0}\n`);
    return;
  }
  try {
    out(backlogCounts(bl));
  } catch (e) {
    if (!(e instanceof ParserFailed)) throw e;
    out(`  ${C_R}WARN   backlog unavailable: the parser exited ${e.rc} - rerun to see why${C_0}\n`);
  }
}

function renderPools(pd: string): void {
  out(`\n${C_H}POOLS${C_0}\n`);
  let found = false;
  for (const p of listDir(pd)) {
    const slots = `${pd}/${p}/.crew/slots`;
    if (!isDir(slots)) continue;
    found = true;
    let leased = 0, avail = 0;
    for (const n of listDir(slots)) {
      const m = `${slots}/${n}`;
      if (!n.endsWith(".meta") || !isFile(m)) continue;
      let v = "";
      try {
        v = meta(m, "leased");
      } catch {}
      if (v === "1") leased++;
      else avail++;
    }
    out(`  ${padBytes(bytes(p), 20)} leased:${leased} avail:${avail}\n`);
  }
  if (!found) out(`  ${C_D}(no worktree pools yet)${C_0}\n`);
}

function render(): void {
  const envHome = process.env.AC_HOME;
  if (!envHome) die(NO_HOME);
  const home = physicalDir(envHome) ?? die(`AC_HOME is not a readable directory: ${envHome}`);
  const cfgd = `${home}/config`;
  const cfg = (n: string, d: string): string => {
    try {
      return configReadDir(cfgd, n, d);
    } catch {
      return "";
    }
  };
  const name = bytes(home.slice(home.lastIndexOf("/") + 1)).replace(/\n+$/, "");
  out(`${C_H}${ANCHOR} ${name}${C_0}  ${C_D}captain:${C_0} ${cfg("captain", "captain")}  ${C_D}backend:${C_0} ${cfg("backend", "herdr")}  ${C_D}flow:${C_0} ${cfg("flow", "auto")}\n`);
  renderCrew(stateDir());
  renderRooms();
  renderBacklog(recordsDir());
  renderPools(projectsDir());
}

// An inherited-stdio child whose failure ends the run with its status, as
// `set -e` ended the loop; one that cannot start is the shell's 127.
async function runOrExit(cmd: string[]): Promise<void> {
  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn(cmd, { stdin: "inherit", stdout: "inherit", stderr: "inherit", env: process.env });
  } catch {
    process.exit(127);
  }
  await proc.exited;
  const rc = status(proc);
  if (rc !== 0) process.exit(rc);
}

const verb = args[0] ?? "";
if (verb === "--watch") {
  const interval = args[1] || "5";
  process.on("SIGINT", () => process.exit(0));
  for (;;) {
    await runOrExit(["clear"]);
    render();
    out(`\n${C_D}(refreshing every ${bytes(interval)}s - ctrl-c to stop)${C_0}\n`);
    await runOrExit(["sleep", interval]);
  }
} else if (verb === "") {
  render();
} else {
  write(2, "usage: ac-dash.sh [--watch [<seconds>]]\n");
  process.exit(2);
}
