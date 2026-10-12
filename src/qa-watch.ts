// qa-watch.ts - live dashboard for a qa run (the ac-ship-watch role, adapted to
// the qa pipeline): one screen per refresh showing the run header, the step
// table with the ACTIVE step marked, the CASE LEDGER (pass/fail/unverifiable +
// per-tier and recent rows), per-step findings summaries, and the tail of the
// run log. Read-only. The entry is bin/ac-qa-watch.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec of the qa
// role, src/watch-dash.ts's header that of the body it shares with
// src/ship-watch.ts. The bash original stays frozen at
// tests/fixtures/ac-qa-watch.sh (sourcing the frozen
// tests/fixtures/ac-watch-dash.sh) as the oracle the differential leg of
// tests/sh/ac-qa-watch.test.sh holds this module to.
//
//   ac-qa-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]
//
// Auto-open/auto-close contract (mirrors ac-ship-watch): ac-qa.sh start opens
// this in a herdr tab (label ac-qa-watch) and records the pane in
// <run>/watch.pane; the watch SELF-CLOSES its pane when the run finishes
// (outcome != running, after a short linger) or when the run goes idle for
// AC_QA_WATCH_IDLE secs (default 1800) - and ac-qa.sh finish also closes it
// belt-and-suspenders. Without --self-pane it just exits (foreground use).
// Session: AC_HERDR_SESSION > config/herdr-session > default.
//
// ROLE: the run base <repo>/.crew/qa; the status column `%-12s`; only running
// and fixing are ACTIVE (an `awaiting_approval` step holds no finished qa run
// open); the separators `── findings ──` and `── log ──`; `no active qa run in
// <repo>` (--once) and `waiting for a qa run in <repo> ...`; the idle limit
// AC_QA_WATCH_IDLE (unset or empty: 1800; AC_SHIP_WATCH_IDLE is not read); the
// idle clock watches cases.tsv too. No finish hook.
//
// HEADER: `<b>ac-qa<r> <cyan><task><r>  <dim>run <id><r>  [<color><outcome><r>]`
// then `<dim>target:<r> <target cut to 110 BYTES>` and an empty line; id is
// the run dir's basename, target/task/outcome run.meta's (metaGet, the last key
// wins, absent ""). The outcome's color: `running` cyan, `passed` green,
// `failed` red, `unverifiable` yellow, else dim.
//
// CASE LEDGER, after the step table, only when <run>/cases.tsv is non-empty:
// `\n<dim>── cases ─<r> <green><p> pass<r>  <red><f> fail<r>  <yellow><u>
// unverifiable<r>`, each count the lines (LF-split, a last line with no LF
// counted) whose third single-TAB field is exactly that status; then the last
// 8 lines: `   <col><glyph><r> <$1 %-22s> <dim><$2 %-4s><r> <$3 %-13s>
// <dim><grade><r>`, green `✓` for pass, red `✗` for fail, else yellow `?` (an
// unknown status is in no count - QW4), grade empty for a sixth field `-`, else
// `grade <$6>` - `grade ` with a trailing space on a row with fewer than six
// fields (QW3); pads in BYTES (QW8). A ledger that cannot be read counts 0 and
// lists no row.
//
// ESCAPE HATCH. A broken board costs a qa run only its observer: the opener
// fails soft and nothing parses what it prints. If a landed change breaks this
// module, run the frozen originals from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-watch-dash.sh tests/fixtures/ac-qa-watch.sh "$o/bin/"
// then "$o/bin/ac-qa-watch.sh" --repo <repo> by hand; a run started as
// "$o/bin/ac-qa.sh" start opens its board from "$o/bin" too, because
// ac-qa.sh names its own bin dir in the launch line. The captain's revert of
// the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands): the body's (see
// src/watch-dash.ts) and QW2 (a real 4-column steps.tsv folds its rounds, so
// `round N` never shows for a qa run), QW3, QW4, QW7 (the target cut in BYTES may
// split a character), QW8.
//
// DIVERGENCES from the frozen original: the body's (src/watch-dash.ts), and
// TOOL-OWN STDERR - for a non-empty ledger that cannot be read the original's
// three awks and its tail printed their own lines; the port prints none (the
// same 0 counts, no row).
//
// CALLERS: bin/ac-qa.sh's watch_open runs `'<its bin>/ac-qa-watch.sh' --repo
// '<repo>' --self-pane <pane>` in a herdr pane (fail-soft; a pane is reused by
// its label, never its cmdline), and its finish closes <run>/watch.pane;
// operators run it in any terminal; tests/sh/ac-qa.test.sh, ac-qa-watch.test.sh
// and ac-watch-dash.test.sh read its --once frames as text.
import { enterCaller } from "./lib.ts";
import { type Role, b8, baseName, C, meta, nonEmpty, pad, readBytes, watchDashArgs, watchDashMain } from "./watch-dash.ts";

const { args, atCaller } = enterCaller(process.argv.slice(2));
const a = watchDashArgs(args, atCaller);

function outcomeColor(o: string): string {
  if (o === "running") return C.cyn;
  if (o === "passed") return C.grn;
  if (o === "failed") return C.red;
  if (o === "unverifiable") return C.yel;
  return C.dim;
}

const PASS = b8("✓");
const FAIL = b8("✗");

function ledger(rd: string): string {
  const f = `${rd}/cases.tsv`;
  if (!nonEmpty(f)) return "";
  const lines = (readBytes(f) ?? "").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const rows = lines.map((l) => l.split("\t"));
  const count = (st: string): number => rows.filter((r) => (r[2] ?? "") === st).length;
  let s = `\n${C.dim}${b8("── cases ─")}${C.r} ${C.grn}${count("pass")} pass${C.r}  ${C.red}${count("fail")} fail${C.r}  ${C.yel}${count("unverifiable")} unverifiable${C.r}\n`;
  for (const r of rows.slice(-8)) {
    const st = r[2] ?? "";
    const col = st === "pass" ? C.grn : st === "fail" ? C.red : C.yel;
    const gl = st === "pass" ? PASS : st === "fail" ? FAIL : "?";
    const grade = r[5] === "-" ? "" : `grade ${r[5] ?? ""}`;
    s += `   ${col}${gl}${C.r} ${pad(r[0] ?? "", 22)} ${C.dim}${pad(r[1] ?? "", 4)}${C.r} ${pad(st, 13)} ${C.dim}${grade}${C.r}\n`;
  }
  return s;
}

const role: Role = {
  base: `${a.repo}/.crew/qa`,
  stepWidth: 12,
  activeStatuses: [],
  findingsHdr: b8("── findings ──"),
  logHdr: b8("── log ──"),
  noRunMsg: `no active qa run in ${a.repo}`,
  waitMsg: `waiting for a qa run in ${a.repo} ...`,
  idleExtraFiles: ["cases.tsv"],
  idleLimit: () => b8(process.env.AC_QA_WATCH_IDLE || "1800"),
  renderHeader(rd) {
    const id = baseName(rd);
    const target = meta(`${rd}/run.meta`, "target");
    const task = meta(`${rd}/run.meta`, "task");
    const outcome = meta(`${rd}/run.meta`, "outcome");
    return `${C.b}ac-qa${C.r} ${C.cyn}${task}${C.r}  ${C.dim}run ${id}${C.r}  [${outcomeColor(outcome)}${outcome}${C.r}]\n${C.dim}target:${C.r} ${target.slice(0, 110)}\n\n`;
  },
  renderExtra: ledger,
  onFinish: () => {},
};

await watchDashMain(a, role);
