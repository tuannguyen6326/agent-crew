// ship-watch.ts - live dashboard for a crew-ship run: one screen per refresh
// showing the run header, the step table with the ACTIVE step marked, fix
// rounds, per-step findings summaries, and the tail of the run log. Read-only.
// The entry is bin/ac-ship-watch.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec of the crew-ship role,
// src/watch-dash.ts's header that of the body it shares with src/qa-watch.ts.
// The bash original stays frozen at tests/fixtures/ac-ship-watch.sh (sourcing
// the frozen tests/fixtures/ac-watch-dash.sh) as the oracle the differential
// leg of tests/sh/ac-ship-watch.test.sh holds this module to.
//
//   ac-ship-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]
//
// Auto-open/auto-close contract: ac-ship.sh start
// opens this in a herdr tab (label ac-ship-watch) and records the pane in
// <run>/watch.pane; the watch SELF-CLOSES its pane when the run finishes
// (outcome != running, after a short linger) or when the run goes idle for
// AC_SHIP_WATCH_IDLE secs (default 1800) - and ac-ship.sh finish also closes
// it belt-and-suspenders. Without --self-pane it just exits instead of
// closing anything (foreground use).
// Session: AC_HERDR_SESSION > config/herdr-session > default.
//
// ROLE: the run base <repo>/.crew/ship; the status column `%-18s`; a step
// `awaiting_approval` is ACTIVE too (a ship run waiting on it is not
// finished); the separators `── findings ` and `── log ` filled with `─` to 33
// characters; `no active crew-ship run in <repo>` (--once) and `waiting for a
// crew-ship run in <repo> ...`; the idle limit AC_SHIP_WATCH_IDLE (unset or
// empty: 1800; AC_QA_WATCH_IDLE is not read); no idle file beyond steps.tsv
// and logs/run.log.
//
// HEADER: `<b>ac-ship<r> <cyan><branch><r>  <dim>run <id><r>  [<color><outcome><r>]`
// then `<dim>intent:<r> <intent cut to 110 BYTES>` and an empty line; id is
// the run dir's basename, branch/intent/outcome run.meta's (metaGet, the last
// key wins, absent ""). When <run>/override is a regular file the outcome
// reads `<outcome> passed-with-override:<the first TAB field of each line,
// joined by `,`>` - an empty file lists nothing, a blank line keeps an empty
// slot, a last line with no LF counts, a file that cannot be read lists
// nothing - so an accepted failure never renders as clean green. The outcome's
// color: `running` cyan, anything holding `passed-with-override` yellow,
// `checks-passed`/`passed` green, `failed` red, else dim.
//
// FINISH (the live loop's only): when <run>/review.pane is a regular file and
// herdr is on PATH, `herdr --session <session> pane close <the file as a
// spawned cat gave it>` (stdout and stderr dropped, status ignored) and a
// spawned `rm -f` of the file - with or without --self-pane (SW3), raw herdr
// whatever the backend: a reviewer pane a reopened run's last round left.
//
// ESCAPE HATCH. A broken board costs a ship run only its observer: the opener
// fails soft and nothing parses what it prints. If a landed change breaks this
// module, run the frozen originals from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-watch-dash.sh tests/fixtures/ac-ship-watch.sh "$o/bin/"
// then "$o/bin/ac-ship-watch.sh" --repo <repo> by hand; a run started as
// "$o/bin/ac-ship.sh" start opens its board from "$o/bin" too, because the
// launch line names the bin root the pipeline started from. The captain's
// revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands): the body's (see
// src/watch-dash.ts) and SW2 (the override list's shapes), SW3 (a foreground
// board closes the reviewer pane, raw herdr), SW6 (the intent cut in BYTES may
// split a character).
//
// DIVERGENCES from the frozen original: the body's (src/watch-dash.ts), and
// FAIL-PATH - under a UTF-8 locale the original's `cut -f1` stopped at an
// override line holding a byte that is no UTF-8 (`cut: <file>: Illegal byte
// sequence`, the list emptied from there); the port lists every line. TOOL-OWN
// STDERR: for an override that cannot be read cut printed its own line; the
// port prints none (both list nothing).
//
// CALLERS: src/ship.ts's watchOpen runs `'<its bin>/ac-ship-watch.sh' --repo
// '<repo>' --self-pane <pane>` in a herdr pane (fail-soft; a pane is reused by
// its label, never its cmdline, so the bun process needs no match), and its
// finish closes <run>/watch.pane; operators run it in any terminal;
// tests/sh/ac-ship.test.sh, ac-ship-watch.test.sh and ac-watch-dash.test.sh
// read its --once frames as text.
import { commandV, enterCaller } from "./lib.ts";
import { type Role, b8, baseName, C, isFile, meta, readBytes, run, subst, watchDashArgs, watchDashMain } from "./watch-dash.ts";

const { args, atCaller } = enterCaller(process.argv.slice(2));
const a = watchDashArgs(args, atCaller);

function outcomeColor(o: string): string {
  if (o === "running") return C.cyn;
  if (o.includes("passed-with-override")) return C.yel;
  if (o === "checks-passed" || o === "passed") return C.grn;
  if (o === "failed") return C.red;
  return C.dim;
}

// `$(cut -f1 <override> | paste -sd, -)`.
function overrideList(text: string): string {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return subst(lines.map((l) => l.split("\t", 1)[0]!).join(","));
}

const role: Role = {
  base: `${a.repo}/.crew/ship`,
  stepWidth: 18,
  activeStatuses: ["awaiting_approval"],
  findingsHdr: b8(`── findings ${"─".repeat(21)}`),
  logHdr: b8(`── log ${"─".repeat(26)}`),
  noRunMsg: `no active crew-ship run in ${a.repo}`,
  waitMsg: `waiting for a crew-ship run in ${a.repo} ...`,
  idleExtraFiles: [],
  idleLimit: () => b8(process.env.AC_SHIP_WATCH_IDLE || "1800"),
  renderHeader(rd) {
    const id = baseName(rd);
    const intent = meta(`${rd}/run.meta`, "intent");
    const branch = meta(`${rd}/run.meta`, "branch");
    let outcome = meta(`${rd}/run.meta`, "outcome");
    if (isFile(`${rd}/override`)) outcome = `${outcome} passed-with-override:${overrideList(readBytes(`${rd}/override`) ?? "")}`;
    return `${C.b}ac-ship${C.r} ${C.cyn}${branch}${C.r}  ${C.dim}run ${id}${C.r}  [${outcomeColor(outcome)}${outcome}${C.r}]\n${C.dim}intent:${C.r} ${intent.slice(0, 110)}\n\n`;
  },
  renderExtra: () => "",
  onFinish(rd, ses) {
    const f = `${rd}/review.pane`;
    if (!isFile(f) || !commandV("herdr")) return;
    const pane = subst(run(["cat", f]).out);
    run(["herdr", "--session", ses, "pane", "close", pane], { stdout: "ignore", stderr: "ignore" });
    run(["rm", "-f", f], { stdout: "inherit" });
  },
};

await watchDashMain(a, role);
