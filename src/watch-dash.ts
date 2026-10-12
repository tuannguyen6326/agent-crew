// watch-dash.ts - the shared body of the two live run boards, src/ship-watch.ts
// and src/qa-watch.ts: arg parsing, colors, the step table, findings/log
// rendering, paint, and the idle/refresh main loop. A module only, never an
// entry: the two entries bin/ac-ship-watch.sh and bin/ac-qa-watch.sh stay real
// paths (shims) because a herdr `pane run` string and the tests both embed
// them, and each entry's header states its role's auto-open/auto-close
// contract. THIS header is the authoritative spec of the shared body; the bash
// body it replaced stays frozen at tests/fixtures/ac-watch-dash.sh, sourced by
// the frozen entries tests/fixtures/ac-ship-watch.sh and ac-qa-watch.sh, the
// oracles of the differential legs of tests/sh/ac-watch-dash.test.sh,
// ac-ship-watch.test.sh and ac-qa-watch.test.sh.
//
// An entry calls watchDashArgs, builds its Role (the run base, the step-table
// status width, the findings/log separator lines, the step statuses counted
// ACTIVE besides running/fixing - ship adds awaiting_approval, qa nothing, the
// one real per-role behaviour difference -, the extra run-dir files the idle
// clock also watches, the no-run/waiting texts, the idle-limit knob, and its
// header/extra/finish hooks), then awaits watchDashMain.
//
// ARGS, scanned in order: `--repo DIR` (default the cwd), `--self-pane ID`,
// `--interval SECS` (default 2), `--once`; the last one wins; a missing or
// EMPTY value is `ERROR: <flag> needs a value`, exit 1, at that flag; any
// other word, `-h` included, is `ERROR: unknown arg: <word>`, exit 1. Then the
// repo is the stdout of a spawned `git rev-parse --show-toplevel` run in DIR
// (resolved against the cwd, no CDPATH; a subdir reads its toplevel), stderr
// dropped; DIR that cannot be entered or no repo is `ERROR: not a git repo: `
// with the name EMPTY (WD1). Then the session: AC_HERDR_SESSION, else
// config/herdr-session (configReadSoft), else `default`; a homeless run is
// legitimate. stdin is never read.
//
// COLORS only when stdout is a tty: reset `\033[0m`, bold `\033[1m`, dim
// `\033[2m`, green `\033[32m`, cyan `\033[36m`, yellow `\033[33m`, magenta
// `\033[35m`, red `\033[31m`; piped, every code is "".
//
// ONE FRAME = the role's header + the step table + the role's extra + the
// findings + the log, every byte as bash 3.2 and the BSD tools wrote it:
// - COLS: the first line a spawned `tput cols` prints (stdin kept, stderr
//   dropped), `200` when tput fails - piped, 80 for TERM=xterm, 200 with TERM
//   unset or empty.
// - Steps: <rd>/steps.tsv read as `IFS=$'\t' read -r step status rounds` read
//   it (tabFields: TAB runs collapse, a 4th field folds into rounds, a last
//   line with no LF is never read); a file that cannot be read draws no row.
//   Glyph and color by status: completed `✓` green, running `▶` cyan, fixing
//   `▶` yellow, awaiting_approval `⏸` magenta, failed `✗` red, skipped `-`
//   dim, anything else `○` dim. `round <rounds as typed>` (dim) when rounds is
//   a `[ -gt 0 ]` integer above 0 (testInt: `08` and ` 3` are, `abc`, `1e2`,
//   `2\tx` are not). Line ` <glyph> <step %-10s> <status %-<width>s> <extra>`,
//   pads in BYTES, a trailing space when there is no extra.
// - Findings: every non-dot <rd>/findings/*.json that is a regular file and
//   not *.meta.json, in BYTE order, asked of a spawned `jq -r 'if length == 0
//   then "" else group_by(.action) | map("\(.[0].action)=\(length)") |
//   join("  ") end'` (stderr dropped, `$(...)` read: NULs dropped, trailing
//   LFs cut); an empty answer (`[]`, not JSON, an object) is no line. The first
//   line answered is preceded by `\n<dim><findings separator><reset>\n`; each
//   is ` findings <name less .json %-9s> <color><counts><reset>`, magenta when
//   the counts hold `ask-user`, else yellow when they hold `fix`, else dim.
// - Log: when <rd>/logs/run.log is a regular file, `\n<dim><log
//   separator><reset>\n` and the output of a spawned `tail -n 6` piped into a
//   spawned awk running the original program verbatim (the timestamp's text
//   past its last `T`, one trailing `Z` dropped, dim, two spaces, the rest past
//   the first field and ONE space; a line longer than COLS BYTES cut to COLS-1
//   bytes plus `…` - WD2, the cut may split a character); both tools' stderr is
//   theirs.
//
// --once: with <run base>/current a symlink (a dangling one counts), the run
// dir is `<run base>/<its target>` (an absolute target joins as `//abs`) and
// the frame goes out as rendered; then, when run.meta's outcome is not
// `running` and no step is active - a spawned awk prints the first steps.tsv
// row whose second TAB field is running, fixing or a role status (its own
// `can't open file` line when there is none) -, `run finished: <outcome>\n`.
// Exit 0. With no symlink, the role's no-run text and a LF, exit 0.
//
// LIVE LOOP: the prelude `\033[2J\033[H\033[?25l` hides the cursor, and every
// exit from here on restores it with `\033[?25h`. Each tick: with a run, the
// frame (trailing LFs cut, NULs dropped as `$(...)` read it) painted only when
// it differs from the last one painted - `\033[H`, every line followed by
// `\033[K`, `\033[J\n`; finished -> `run finished: <outcome>\n`, the role's
// finish hook, a spawned `sleep 5`, the self-close; else idle when now (nowRaw,
// a spawned `date +%s`) minus the newest mtime of steps.tsv, logs/run.log and
// the role's extra files (fileMtime, 0 when unstattable) is a `[ -gt ]` integer
// past the role's idle limit (no integer: never) -> `\nrun idle too long -
// closing watch\n`, `sleep 2`, the self-close. With no run, the role's waiting
// text painted once, `waited` grown by the interval as `$((waited +
// INTERVAL))` read it (arithValue: `010` is 8, `0` and `00` add nothing, a
// negative shrinks it), and past 300 the self-close - before that tick's
// sleep; an interval that is no arithmetic operand ends the board there, the
// cursor restored: exit 1 (`5abc`, `0.5`, `08`), exit 0 for a name (`abc` -
// set -u ended the script with the status of the assignment before it). Each
// tick ends in a spawned `sleep <interval as typed>` (stdio inherited, a PATH
// stub fast-forwards it, its failure ignored: an interval sleep refuses spins
// the loop while a run is shown - WD4). The self-close: with --self-pane and
// herdr on PATH, `herdr --session <session> pane close <id>` (stdout and stderr
// dropped, status ignored, whatever the backend - WD5), then exit 0.
//
// SIGNALS: the live loop restores the cursor on HUP, INT and TERM and exits
// 128+n; --once registers no handler.
//
// AT PARITY (each pinned in the legs until its own fix lands):
// - WD1: `--repo` naming no repo refuses with an empty name.
// - WD2: the log cut counts bytes and may split a character before `…`.
// - WD4: an interval sleep refuses (`abc`, `0`) spins the loop while a run is
//   shown; with no run, `0`/`00` never self-close and a non-operand ends it.
// - WD5: the self-close is RAW herdr whatever the backend - an orca fleet's
//   board never closes its pane.
// - The 4-column steps.tsv fold, the step table's TAB-run collapse beside the
//   awk readers' single-TAB fields, a non-integer idle limit never idling.
//
// DIVERGENCES from the frozen original (the legs name each one a row can show):
// - FAIL-PATH (WD6): under a UTF-8 locale the original's paint `sed` stopped at
//   the first frame line holding a byte that is no UTF-8 (WD2's cut, a byte cut
//   of a role header) - `sed: RE error: illegal byte sequence`, the pane cut
//   there every refresh; the port paints the whole frame.
// - FINDINGS ORDER: the findings files are walked in byte order, where bash's
//   glob collated them under a UTF-8 locale.
// - SIGNALS: a SIGINT to the board's pid ALONE ends it 130 with the cursor
//   restored, where bash swallowed it while its sleep child ran (WD3); ctrl-c,
//   which reaches both, ends both. The board EXITS 128+n where bash re-raised
//   the signal after its EXIT trap: the same `$?`, a different wait status.
//   The handlers are installed even when INT was ignored at entry.
// - SHELL-OWN STDERR is not reproduced, the status kept: `${2:?}`'s `parameter
//   null or not set` (the port names the flag, exit 1 both); cd's line for a
//   --repo it cannot enter; the redirection's line for a steps.tsv that cannot
//   be read; the interval's arithmetic and unbound-variable lines; `[`'s
//   `integer expression expected` for a non-integer idle limit;
//   `sleep: command not found`.
// - INTERVAL ARITHMETIC: an interval that is a whole expression (`1+1`) or
//   names a variable holding a number ends the board at its first no-run tick,
//   where bash evaluated it.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is the session default with
//   nothing printed, where the shell printed cd's line; a relative --repo is
//   resolved without CDPATH.
// - BYTES: argv arrives decoded and config/herdr-session is read as UTF-8, so
//   a --repo, interval or pane id byte that is no UTF-8 is U+FFFD.
// - BUN IN THE PANE: the board's pane runs bun; without it the shim's `ERROR:
//   required tool not found: bun` is all the pane shows until the run's finish
//   closes it, where the original needed bash, jq and the BSD tools.
// - A caller whose cwd has no name is `ERROR: not a git repo: ` with no
//   --repo, as bash's `cd "$PWD"` failed there.
import { readFileSync, readdirSync, readlinkSync, lstatSync, statSync, writeSync } from "node:fs";
import { isatty } from "node:tty";
import { arithValue, commandV, configReadSoft, die, fileMtime, metaGet, nowRaw, physicalDir, shellStatus, spawnShell, spawnShellSync, tabFields, testInt } from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv, the env and
// the lib's paths are UTF-8 strings and cross over here.
export const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
export const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
export const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
export const subst = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");

export function out(s: string): void {
  const b = fsPath(s);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

type Io = "inherit" | "pipe" | "ignore";

// A child as the original ran it: stdin inherited unless the pipeline feeds
// it; its stdout's bytes when piped.
export function run(cmd: string[], io: { stdout?: Io; stderr?: Io; input?: string } = {}): { status: number; out: string } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  const stdout = io.stdout ?? "pipe";
  try {
    r = spawnShellSync(cmd.map(u8), { stdin: io.input === undefined ? "inherit" : fsPath(io.input), stdout, stderr: io.stderr ?? "inherit" });
  } catch {}
  return { status: shellStatus(r), out: r && stdout === "pipe" ? Buffer.from(r.stdout).toString("latin1") : "" };
}

const stat = (p: string): ReturnType<typeof statSync> | null => {
  try {
    return statSync(fsPath(p));
  } catch {
    return null;
  }
};
export const isFile = (p: string): boolean => stat(p)?.isFile() ?? false;
export const nonEmpty = (p: string): boolean => (stat(p)?.size ?? 0) > 0;
const isLink = (p: string): boolean => {
  try {
    return lstatSync(fsPath(p)).isSymbolicLink();
  } catch {
    return false;
  }
};
// The file's bytes, null when it cannot be read.
export function readBytes(p: string): string | null {
  try {
    return readFileSync(fsPath(p), "latin1");
  } catch {
    return null;
  }
}

const tty = isatty(1);
export const C = {
  r: tty ? "\x1b[0m" : "",
  b: tty ? "\x1b[1m" : "",
  dim: tty ? "\x1b[2m" : "",
  grn: tty ? "\x1b[32m" : "",
  cyn: tty ? "\x1b[36m" : "",
  yel: tty ? "\x1b[33m" : "",
  mag: tty ? "\x1b[35m" : "",
  red: tty ? "\x1b[31m" : "",
};

export const pad = (s: string, w: number): string => s + " ".repeat(Math.max(0, w - s.length));

// The value as awk handed it to the shell: a C string, cut at its first NUL;
// an unreadable meta is "" after metaGet's warning, the status the `$(...)`
// swallowed.
export function meta(file: string, key: string): string {
  try {
    return metaGet(u8(file), key).replace(/\0[\s\S]*$/, "");
  } catch {
    return "";
  }
}

// `$(basename <p> [<suffix>])`: the suffix goes only when something is left.
export function baseName(p: string, suffix = ""): string {
  const s = p.replace(/\/+$/, "");
  if (s === "") return p === "" ? "" : "/";
  let b = s.slice(s.lastIndexOf("/") + 1);
  if (suffix !== "" && b !== suffix && b.endsWith(suffix)) b = b.slice(0, -suffix.length);
  return b.replace(/\n+$/, "");
}

export type Args = { repo: string; self: string; interval: string; once: boolean; ses: string };

export function watchDashArgs(args: string[], atCaller: boolean): Args {
  let repo: string | null = atCaller ? process.cwd() : null;
  let self = "";
  let interval = "2";
  let once = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    const value = (): string => {
      const v = args[++i] ?? "";
      if (v === "") die(`${a} needs a value`);
      return v;
    };
    if (a === "--repo") repo = value();
    else if (a === "--self-pane") self = b8(value());
    else if (a === "--interval") interval = b8(value());
    else if (a === "--once") once = true;
    else die(`unknown arg: ${a}`);
  }
  const dir = repo === null ? null : physicalDir(repo);
  let top: string | null = null;
  if (dir !== null) {
    try {
      const r = spawnShellSync(["git", "rev-parse", "--show-toplevel"], { cwd: dir, stdin: "inherit", stdout: "pipe", stderr: "ignore" });
      if (r.exitCode === 0) top = subst(Buffer.from(r.stdout).toString("latin1"));
    } catch {}
  }
  if (top === null) die("not a git repo: ");
  const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
  return { repo: top, self, interval, once, ses };
}

export type Role = {
  base: string;
  stepWidth: number;
  activeStatuses: string[];
  findingsHdr: string;
  logHdr: string;
  noRunMsg: string;
  waitMsg: string;
  idleExtraFiles: string[];
  idleLimit: () => string;
  renderHeader: (rd: string) => string;
  renderExtra: (rd: string) => string;
  onFinish: (rd: string, ses: string) => void;
};

const GLYPHS: Record<string, [string, keyof typeof C]> = {
  completed: [b8("✓"), "grn"],
  running: [b8("▶"), "cyn"],
  fixing: [b8("▶"), "yel"],
  awaiting_approval: [b8("⏸"), "mag"],
  failed: [b8("✗"), "red"],
  skipped: ["-", "dim"],
};
const OTHER: [string, keyof typeof C] = [b8("○"), "dim"];

export function renderSteps(rd: string, width: number): string {
  const text = readBytes(`${rd}/steps.tsv`);
  if (text === null) return "";
  const lines = text.split("\n");
  lines.pop();
  let s = "";
  for (const line of lines) {
    const [step = "", status = "", rounds = ""] = tabFields(line, 3);
    const [glyph, k] = Object.hasOwn(GLYPHS, status) ? GLYPHS[status]! : OTHER;
    const color = C[k];
    const extra = (testInt(rounds || "0") ?? 0n) > 0n ? `${C.dim}round ${rounds}${C.r}` : "";
    s += ` ${color}${glyph}${C.r} ${pad(step, 10)} ${color}${pad(status, width)}${C.r} ${extra}\n`;
  }
  return s;
}

const FINDINGS_JQ = 'if length == 0 then "" else group_by(.action) | map("\\(.[0].action)=\\(length)") | join("  ") end';

export function renderFindings(rd: string, hdr: string): string {
  const dir = `${rd}/findings`;
  let names: string[];
  try {
    names = readdirSync(fsPath(dir), { encoding: "latin1" })
      .filter((n) => !n.startsWith(".") && n.endsWith(".json"))
      .sort();
  } catch {
    return "";
  }
  let s = "";
  let shown = false;
  for (const n of names) {
    const f = `${dir}/${n}`;
    if (!isFile(f) || n.endsWith(".meta.json")) continue;
    const counts = subst(run(["jq", "-r", FINDINGS_JQ, f], { stderr: "ignore" }).out);
    if (counts === "") continue;
    if (!shown) {
      s += `\n${C.dim}${hdr}${C.r}\n`;
      shown = true;
    }
    const ccolor = counts.includes("ask-user") ? C.mag : counts.includes("fix") ? C.yel : C.dim;
    s += ` findings ${pad(baseName(f, ".json"), 9)} ${ccolor}${counts}${C.r}\n`;
  }
  return s;
}

const LOG_AWK = b8(`{
    ts = $1; sub(/^[^ ]+ /, "", $0)
    t = ts; sub(/^.*T/, "", t); sub(/Z$/, "", t)
    line = " " dim t rst "  " $0
    if (length(line) > w) line = substr(line, 1, w - 1) "…"
    print line
  }`);

export function renderLog(rd: string, cols: string, hdr: string): string {
  const log = `${rd}/logs/run.log`;
  if (!isFile(log)) return "";
  const tail = run(["tail", "-n", "6", log]);
  const lines = run(["awk", "-v", `dim=${C.dim}`, "-v", `rst=${C.r}`, "-v", `w=${cols}`, LOG_AWK], { input: tail.out });
  return `\n${C.dim}${hdr}${C.r}\n${lines.out}`;
}

// `(tput cols 2>/dev/null || echo 200) | head -1`, as `$(...)` read it.
function columns(): string {
  const r = run(["tput", "cols"], { stderr: "ignore" });
  const text = r.status === 0 ? r.out : `${r.out}200\n`;
  return text.split("\n", 1)[0]!.replace(/\0/g, "");
}

export function render(rd: string, role: Role): string {
  const cols = columns();
  return role.renderHeader(rd) + renderSteps(rd, role.stepWidth) + role.renderExtra(rd) + renderFindings(rd, role.findingsHdr) + renderLog(rd, cols, role.logHdr);
}

// The newest mtime of the run's live files, "0" for none.
export function idleSince(rd: string, extra: string[]): string {
  let m1 = fileMtime(fsPath(`${rd}/steps.tsv`)) ?? "0";
  for (const f of ["logs/run.log", ...extra]) {
    const m = fileMtime(fsPath(`${rd}/${f}`)) ?? "0";
    if (BigInt(m) > BigInt(m1)) m1 = m;
  }
  return m1;
}

function isActive(rd: string, statuses: string[]): string {
  const cond = ["running", "fixing", ...statuses].map((st) => `$2 == "${st}"`).join(" || ");
  return subst(run(["awk", "-F\\t", `${cond} { print $1; exit }`, `${rd}/steps.tsv`]).out);
}

const paint = (frame: string): void =>
  out(`\x1b[H${frame
    .split("\n")
    .map((l) => `${l}\x1b[K`)
    .join("\n")}\x1b[J\n`);

// The tick's sleep, spawned so a PATH stub fast-forwards it; awaited, so a
// signal handler runs while it waits. One that cannot start still yields to
// the event loop, or a handler could never run.
export async function nap(secs: string): Promise<void> {
  try {
    await spawnShell(["sleep", u8(secs)], { stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  } catch {
    await Bun.sleep(0);
  }
}

function selfClose(a: Args): never {
  if (a.self !== "" && commandV("herdr")) run(["herdr", "--session", a.ses, "pane", "close", a.self], { stdout: "ignore", stderr: "ignore" });
  process.exit(0);
}

export async function watchDashMain(a: Args, role: Role): Promise<never> {
  if (!a.once) {
    out("\x1b[2J\x1b[H\x1b[?25l");
    process.on("exit", () => {
      try {
        writeSync(1, "\x1b[?25h");
      } catch {}
    });
    for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
  }
  let waited = 0n;
  let last = "";
  const current = `${role.base}/current`;
  for (;;) {
    if (isLink(current)) {
      let target = "";
      try {
        target = readlinkSync(fsPath(current), { encoding: "latin1" });
      } catch {}
      const rd = `${role.base}/${subst(target)}`;
      if (a.once) out(render(rd, role));
      else {
        const frame = subst(render(rd, role));
        if (frame !== last) {
          paint(frame);
          last = frame;
        }
      }
      const outcome = meta(`${rd}/run.meta`, "outcome");
      // A reopened run (finish recorded, then a step re-entered running/fixing
      // under hold-and-fix) is NOT done: close only when no step is active.
      const active = isActive(rd, role.activeStatuses);
      if (outcome !== "running" && active === "") {
        out(`run finished: ${outcome}\n`);
        if (a.once) process.exit(0);
        role.onFinish(rd, a.ses);
        await nap("5");
        selfClose(a);
      }
      if (a.once) process.exit(0);
      let idle: bigint;
      try {
        idle = arithValue(nowRaw()) - arithValue(idleSince(rd, role.idleExtraFiles));
      } catch {
        process.exit(1);
      }
      const limit = testInt(subst(role.idleLimit()));
      if (limit !== null && idle > limit) {
        out("\nrun idle too long - closing watch\n");
        await nap("2");
        selfClose(a);
      }
    } else {
      if (a.once) {
        out(`${role.noRunMsg}\n`);
        process.exit(0);
      }
      if (role.waitMsg !== last) {
        paint(role.waitMsg);
        last = role.waitMsg;
      }
      try {
        waited = BigInt.asIntN(64, waited + arithValue(a.interval));
      } catch (e) {
        process.exit((e as { code?: string }).code === "EUNBOUND" ? 0 : 1);
      }
      if (waited > 300n) selfClose(a);
    }
    await nap(a.interval);
  }
}
