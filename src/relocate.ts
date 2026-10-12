// relocate.ts - move a live herdr task window to another workspace WITHOUT
// losing its claude session: close the old tab, recreate it in the target
// workspace, resume the recorded session_id there, and tell the agent to pick
// up where it left off (a roomchief is also told to re-arm its family
// watcher, which died with the old tab). The entry is bin/ac-relocate.sh (a
// shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-relocate.sh as the oracle the differential leg of
// tests/sh/ac-relocate.test.sh holds this module to.
//
// Usage: ac-relocate.sh <id> [--family <fam> | --root]
// Target (FAMILY WORKSPACE GROUPING, bin/ac-backend.sh header): by default the
// task's OWN family workspace (the healing move for a tab stranded in the
// wrong space); --family <fam> names another family's; --root the fleet ROOT
// workspace. The workspace is resolved adopt-by-label (created when absent),
// never from a knob. Refuses, fail-closed: an unknown task, a non-herdr
// backend (a stale meta has no window groups), no session_id (nothing to
// resume - respawn instead), an agent not idle (never kill a pane mid-write).
// Already in the target workspace is a no-op success. Knob: AC_SPAWN_SETTLE,
// the seconds between the resume line and the notice (default 8). stdin is
// never read here, only by the herdr children named below. Every ERROR/WARN
// is on stderr.
//
// Both steers are DIAGNOSED, never a bare abort, and split on what their
// failure costs: an undelivered RESUME line means nothing was resumed, so it
// dies; an undelivered NOTICE fails after the tab was recreated, the meta
// updated and the session resumed, so it WARNS - a fatal there would skip the
// status line and leave the fleet's durable record blind to a relocation that
// really happened.
//
// IN ORDER:
// 1. The fleet backend, as sourcing ac-backend.sh checked it (backendName,
//    src/lib.ts), before usage: any name but herdr or orca is `ERROR:
//    unsupported backend '<b>' (valid backends: herdr, orca; tmux/wezterm were
//    removed 2026-07-17)`.
// 2. No <id>, or "": `ERROR: usage: ac-relocate.sh <id> [--family <fam> |
//    --root]`. The first argument is the id whatever it spells (`-h` too);
//    then, in any order, `--family <fam>` (no value or "": `ERROR: --family
//    needs a value`; the last one wins) and `--root`; any other token is
//    `ERROR: unknown flag: <tok> (usage: ac-relocate.sh <id> [--family <fam> |
//    --root])`; both is `ERROR: --family and --root are mutually exclusive`.
// 3. No regular file at taskMeta(<id>) (<home>/state/<id>.meta, state/
//    minted): `ERROR: no such task in flight: <id>` - homeless, after the
//    AC_HOME refusal (W5: the meta read is `/<id>.meta`).
// 4. taskBackend(<id>) - the meta's last non-empty backend= cut at a NUL,
//    herdr without one; an unreadable meta WARNs and reads herdr - must be
//    herdr, else `ERROR: relocate is herdr-only; backend of <id> is <b>` (its
//    bytes). AC_BACKEND=herdr for every later call and child.
// 5. herdr, then jq, on PATH (require), else `ERROR: required tool not found:
//    <c>`.
// 6. kind, session_id and worktree, each read as `awk -F= '$1=="<key>"{print
//    $2}' <meta>` read it, awk spawned: every matching line prints (W1: a
//    repeated key is a multi-line value) and a value is cut at its second `=`
//    (W2); awk's failure (an unreadable meta) ends the run with its line and
//    status. No session_id: `ERROR: no session_id recorded for <id> - cannot
//    resume; respawn instead`; no worktree: `ERROR: no worktree recorded for
//    <id>`.
// 7. The family: "" for --root; --family's value, never checked against the
//    scope grammar (W3); "" for kind crewdeputy (its home is fleet-level);
//    else windowFamily(<id>) (src/lib.ts: AC_SCOPE, then AC_FLEET_SCOPE, each
//    only inside [A-Za-z0-9_-]+, then familyOfId). <label> is
//    wsFamilyLabel(<family>) - `<fleet> · <family>`, or `<fleet>` for "",
//    <fleet> the physical home's basename - and <group> the family, or `root`.
// 8. <ws> is herdrResolveWorkspace(<label>) (src/lib.ts): the busiest twin
//    adopted, provably empty twins closed and the rest WARNed, else one
//    created; its death (a failed create, an answer with no id) ends the run 1
//    with its ERROR. The original's `could not resolve herdr workspace` refusal
//    is unreachable - both of its empty answers died inside the resolver.
// 9. The handle: fields 1 and 2 of state/.pane-<id>'s first line (paneField:
//    blank-separated, "" when absent); either empty is `ERROR: no window handle
//    for <id>`. A tab whose part before its first `:` is <ws> prints
//      <id> already in group <group> (workspace <ws>)
//    exit 0, nothing written - before the idle gate, so a busy agent already in
//    place answers the no-op.
// 10. The idle gate: `herdr tab get <tab> | jq -r '.result.tab.agent_status //
//    "unknown"'`, herdr's stderr and jq's left open; a failing stage ends the
//    run with pipefail's status and nothing more (V15: a failing tab get is
//    silent but for herdr's own lines, 124 at the RPC ceiling; jq's parse
//    error). Only idle and done pass; anything else - every line of it - is
//    `ERROR: agent of <id> is '<status>' - relocate only an idle window (never
//    kill a pane mid-write)`.
// 11. `herdr tab close <tab>`, its output dropped; a failure is `WARN: old tab
//    <tab> already gone` and the move goes on.
// 12. herdrTabCreate(<ws>, <worktree>, <id>) (src/lib.ts): its failure is
//    herdr's stderr, then `ERROR: herdr tab create failed (workspace <ws>)`.
//    The answer's `.result.tab.tab_id` and `.result.root_pane.pane_id`, each
//    through `jq -r '... // empty'` (jq's failure ends the run with its line
//    and status); either empty is `ERROR: could not parse herdr tab create
//    output`.
// 13. herdrCloseDefaultTabs(<ws>) (src/lib.ts): herdr's default `1` tabs there
//    closed, best-effort; a tab list jq cannot read ends the run with jq's
//    status, silently, the new tab open and nothing written (W6).
// 14. state/.pane-<id> truncated to `<pane> <tab>`, then the meta's window=
//    set to `herdr:pane-<pane>` (metaSet: every window= line dropped, the new
//    one appended); a write that fails ends the run 1 (mv's status for mv's).
// 15. The resume line is `claude --resume <sid>`, the notice `Notice: your
//    window was relocated to the <group> workspace (<ws>) - same session,
//    nothing lost. Continue where you left off.` For kind roomchief - whose
//    worktree= holds its fleet HOME, and whose resume line takes ac-spawn.sh's
//    roomchief launch shape - the line is `AC_HOME=<%q worktree> AC_SCOPE=<%q
//    project> [AC_DOMAIN=<%q domain> ]claude --resume <sid>` (AC_DOMAIN only
//    for a domainchief, domain= set), project and domain read as in 6, and the
//    notice ends `... nothing lost. Your family watcher died with the old tab:
//    re-arm it as a background task (AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set
//    <project>) bin/ac-watch.sh - recompute the set each re-arm so an epic
//    keeps covering its in-flight story panes), then continue.` (the `$(` is
//    typed text). For kind crewdeputy: `AC_HOME=<%q worktree> claude --resume
//    <sid>`. %q is shellQuote (src/lib.ts: bash 3.2's printf %q under the
//    caller's locale).
// 16. AC_SPAWN_SETTLE (unset or "" is 8) holding a byte outside [0-9.] or two
//    dots is `ERROR: AC_SPAWN_SETTLE must be a number: <v>` - checked only
//    HERE, after the handle and meta were rewritten (W4).
// 17. backendCall("send_line", [<id>, <resume>]) (src/lib.ts) with
//    AC_SEND_UNPROVEN=1 for that one call - a shell line, no composer to
//    prove - then restored; any non-zero is `ERROR: resume line NOT delivered
//    to <id> (see stderr above) - the session was never resumed; the new tab
//    exists, so re-send it by hand: bin/ac-send.sh <id> '<resume>'`.
// 18. `sleep <settle>`, PATH's, spawned; its failure ends the run with its
//    status (W7: `.` passes 16 and sleep refuses it - after the resume, before
//    the notice).
// 19. backendCall("send_line", [<id>, <notice>]) under the caller's own
//    AC_SEND_UNPROVEN (a claude meta's composer is proven); any non-zero is
//    `WARN: relocation notice NOT delivered to <id> (see stderr above) - the
//    session IS resumed, so re-send it only if the agent looks confused:
//    bin/ac-send.sh <id> '<notice>'`.
// 20. statusAppend(<id>, `working: relocated to <group> (<ws>)`) as the
//    original's bare call under errexit ran it: date failing ends the run with
//    date's status, a failed append with 1, both before the timeline mirror.
// 21. stdout `relocated <id> group=<group> window=herdr:pane-<pane>`, exit 0.
//
// EXIT: 0 relocated or already there; 1 for every refusal and failed write;
// else the status of the stage that ended the run - herdr's, jq's, awk's,
// sleep's or date's; 124 a herdr call past its ceiling; 141, silently, when
// the reader has closed stdout.
//
// Every herdr call goes through herdrCli (src/lib.ts, the bounded herdr_cli):
// the AC_HERDR_RPC_TIMEOUT / config/herdr-rpc-timeout ceiling, and
// AC_HERDR_SESSION / config/herdr-session as a trailing `--session <s>`.
// STDIN BY POSITION: the old tab's close and send_line's typing and keys read
// the caller's stdin, every other herdr call /dev/null.
//
// NAMED DIVERGENCES from the frozen original, each in the leg:
// - stdin by history (V1, the D-E ruling): the original's twin-sweep calls
//   read its loop's here-string, and its workspace create the caller's stdin
//   (a compound command with a stdin redirect had run in that `$( )`); here
//   both read /dev/null.
// - The scope grammar per the text: bash 3.2's [!A-Za-z0-9_-] under a UTF-8
//   locale admitted é by collation, so AC_SCOPE=é grouped there; here it is
//   skipped for the id's family.
// - Bytes: argv and the environment arrive decoded, so an id byte that is not
//   UTF-8 is U+FFFD in a path, a child's argv and a refusal; and a resume line
//   or label holding such a byte - under a UTF-8 locale printf %q leaves a
//   UTF-8 lead byte raw beside its escaped continuation - reaches herdr's argv
//   with U+FFFD where the original typed the byte (W17).
// - A meta holding a NUL keeps its bytes (metaSet), where the original's grep
//   rewrote it as `Binary file <meta> matches` plus the new line.
// - The workspace close's `2>&1` capture is read as stdout, then stderr, not
//   interleaved; only its workspace_group_close_required test reads it.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) where the
//   shell printed cd's own line.
// - Shell-own stderr is not reproduced: a redirection refused (a status log
//   that is a directory, a read-only handle - exit 1 alike) and bash 3.2's
//   job-control race line `child setpgid (...): Operation not permitted`.
// - require (src/lib.ts) uses Bun.which, which refuses a non-executable PATH
//   file `command -v` accepted.
// - BUN ABSENT from PATH: the original never needed it; the shim refuses with
//   `ERROR: required tool not found: bun`.
//
// CALLERS: no script runs this entry; chiefs run it by hand (docs/scripts.md).
// bin/ac-sessionstart-nudge.sh and two hook tests reason about the roomchief
// resume line's env shape; tests/sh/ac-relocate.test.sh pins its bytes.
import { statSync, writeFileSync, writeSync } from "node:fs";
import {
  backendCall,
  backendName,
  die,
  enterCaller,
  herdrCli,
  herdrCloseDefaultTabs,
  herdrResolveWorkspace,
  herdrTabCreate,
  metaSet,
  paneField,
  require,
  shellQuote,
  shellStatus,
  spawnShellSync,
  stateDir,
  statusAppend,
  taskBackend,
  taskMeta,
  warn,
  windowFamily,
  wsFamilyLabel,
} from "./lib.ts";

// Every value is held as its bytes (a latin1 string), as the shell held it:
// what a file or a capture gave is already bytes, argv's text is turned into
// its UTF-8 bytes, and a child's argv turns them back into text.
const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const text = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
const bytes = (b: string): Buffer => Buffer.from(b, "latin1");
// `$(...)`: NULs dropped, trailing LFs cut.
const cap = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const fail = (msg: string): never => die(bytes(msg));

function run(cmd: string[], stdin: "inherit" | "ignore" | Buffer, stdout: "inherit" | "pipe"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// A stage errexit watched: its failure ends the run with its status.
function must(r: { status: number; out: Buffer }): string {
  if (r.status !== 0) process.exit(r.status);
  return cap(r.out);
}

function say(line: string): never {
  const b = bytes(`${line}\n`);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
  process.exit(0);
}

const { args } = enterCaller(process.argv.slice(2));
backendName();
const USAGE = "usage: ac-relocate.sh <id> [--family <fam> | --root]";
const id = args[0] ?? "";
const who = lat(id);
if (id === "") fail(USAGE);
let famFlag = "";
let root = false;
for (let i = 1; i < args.length; i++) {
  const a = lat(args[i]!);
  if (a === "--family") {
    famFlag = lat(args[++i] ?? "");
    if (famFlag === "") fail("--family needs a value");
  } else if (a === "--root") root = true;
  else fail(`unknown flag: ${a} (${USAGE})`);
}
if (root && famFlag !== "") fail("--family and --root are mutually exclusive");

const meta = taskMeta(id);
let isMeta = false;
try {
  isMeta = statSync(meta).isFile();
} catch {}
if (!isMeta) fail(`no such task in flight: ${who}`);
const backend = taskBackend(id).replace(/\0[\s\S]*$/, "");
if (backend !== "herdr") fail(`relocate is herdr-only; backend of ${who} is ${backend}`);
process.env.AC_BACKEND = "herdr";
require("herdr", "jq");

const field = (key: string): string => must(run(["awk", "-F=", `$1=="${key}"{print $2}`, meta], "ignore", "pipe"));
const kind = field("kind");
const sid = field("session_id");
const dir = field("worktree");
if (sid === "") fail(`no session_id recorded for ${who} - cannot resume; respawn instead`);
if (dir === "") fail(`no worktree recorded for ${who}`);

const fam = root ? "" : famFlag !== "" ? famFlag : kind === "crewdeputy" ? "" : lat(windowFamily(id)).replace(/\n+$/, "");
const ws = herdrResolveWorkspace(wsFamilyLabel(fam).replace(/\n+$/, ""));
if (ws === null) process.exit(1);
const group = fam || "root";

const pane = paneField(id, 1, true);
const tab = paneField(id, 2, true);
if (pane === "" || tab === "") fail(`no window handle for ${who}`);
if (tab.split(":")[0] === ws) say(`${who} already in group ${group} (workspace ${ws})`);

const got = herdrCli(["tab", "get", text(tab)], "ignore", "pipe", "inherit");
const read = run(["jq", "-r", '.result.tab.agent_status // "unknown"'], got.out, "pipe");
if (read.status !== 0 || got.status !== 0) process.exit(read.status || got.status);
const status = cap(read.out);
if (status !== "idle" && status !== "done") fail(`agent of ${who} is '${status}' - relocate only an idle window (never kill a pane mid-write)`);

if (herdrCli(["tab", "close", text(tab)], "inherit", "ignore").status !== 0) warn(bytes(`old tab ${tab} already gone`));
const created = herdrTabCreate(ws, dir, who);
if (created.status !== 0) fail(`herdr tab create failed (workspace ${ws})`);
const newtab = must(run(["jq", "-r", ".result.tab.tab_id // empty"], bytes(`${created.out}\n`), "pipe"));
const newpane = must(run(["jq", "-r", ".result.root_pane.pane_id // empty"], bytes(`${created.out}\n`), "pipe"));
if (newtab === "" || newpane === "") fail("could not parse herdr tab create output");
const swept = herdrCloseDefaultTabs(ws);
if (swept !== 0) process.exit(swept);
try {
  writeFileSync(`${stateDir()}/.pane-${id}`, bytes(`${newpane} ${newtab}\n`));
  metaSet(meta, "window", `herdr:pane-${newpane}`);
} catch (e) {
  process.exit((e as { status?: number }).status ?? 1);
}

let resume = `claude --resume ${sid}`;
let notice = `Notice: your window was relocated to the ${group} workspace (${ws}) - same session, nothing lost. Continue where you left off.`;
if (kind === "roomchief") {
  const project = field("project");
  const dom = field("domain");
  resume = `AC_HOME=${shellQuote(dir)} AC_SCOPE=${shellQuote(project)} ${dom === "" ? "" : `AC_DOMAIN=${shellQuote(dom)} `}${resume}`;
  notice = `Notice: your window was relocated to the ${group} workspace (${ws}) - same session, nothing lost. Your family watcher died with the old tab: re-arm it as a background task (AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set ${project}) bin/ac-watch.sh - recompute the set each re-arm so an epic keeps covering its in-flight story panes), then continue.`;
} else if (kind === "crewdeputy") resume = `AC_HOME=${shellQuote(dir)} ${resume}`;

const settle = process.env.AC_SPAWN_SETTLE || "8";
if (/[^0-9.]|\..*\./.test(settle)) fail(`AC_SPAWN_SETTLE must be a number: ${lat(settle)}`);
const io = { stdin: "inherit", stdout: "inherit", stderr: "inherit" } as const;
const unproven = process.env.AC_SEND_UNPROVEN;
process.env.AC_SEND_UNPROVEN = "1";
const resumed = backendCall("send_line", [id, text(resume)], io);
if (unproven === undefined) delete process.env.AC_SEND_UNPROVEN;
else process.env.AC_SEND_UNPROVEN = unproven;
if (resumed.exited) process.exit(resumed.status);
if (resumed.status !== 0)
  fail(`resume line NOT delivered to ${who} (see stderr above) - the session was never resumed; the new tab exists, so re-send it by hand: bin/ac-send.sh ${who} '${resume}'`);
const slept = run(["sleep", settle], "inherit", "inherit");
if (slept.status !== 0) process.exit(slept.status);
const told = backendCall("send_line", [id, text(notice)], io);
if (told.exited) process.exit(told.status);
if (told.status !== 0)
  warn(bytes(`relocation notice NOT delivered to ${who} (see stderr above) - the session IS resumed, so re-send it only if the agent looks confused: bin/ac-send.sh ${who} '${notice}'`));

try {
  if (!statusAppend(id, `working: relocated to ${group} (${ws})`, true)) process.exit(1);
} catch (e) {
  process.exit((e as { status?: number }).status ?? 1);
}
say(`relocated ${who} group=${group} window=herdr:pane-${newpane}`);
