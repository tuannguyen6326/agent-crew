// crew-state.ts - one deterministic current-state line for a crewmate. The
// entry is bin/ac-crew-state.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-crew-state.sh as the oracle the
// differential leg of tests/sh/ac-crew-state.test.sh holds this module to.
//
// Usage: ac-crew-state.sh <id>
// Precedence: crew-ship run step > window gone/unobservable > pane busy > last
// status log line > idle. Output is a single line, safe to embed in fleet
// views. `unobservable: ...` means the BACKEND could not be read - the pane's
// liveness is UNKNOWN, never rendered as gone (contract: ac-backend.sh WINDOW
// LIVENESS). Arguments past <id> are never read; the module never reads stdin
// (the backend children below may). Every ERROR/WARN is on stderr.
//
// In order:
// 1. BEFORE the usage check, the fleet backend is resolved as sourcing
//    ac-backend.sh resolved it (backendName, src/lib.ts): AC_BACKEND,
//    config/backend, the first word of <AC_FLEET_STATE>/../config/backend,
//    herdr; any other name is `ERROR: unsupported backend '<b>' (valid
//    backends: herdr, orca; tmux/wezterm were removed 2026-07-17)`, exit 1.
// 2. An empty or missing <id>: `ERROR: usage: ac-crew-state.sh <id>`, exit 1.
// 3. <meta> is taskMeta(<id>) - <home>/state/<id>.meta, state/ minted, <id> a
//    path component as given. No regular file there: `ERROR: no crewmate meta
//    for <id>`, exit 1. Homeless, the AC_HOME refusal comes first and the path
//    read is `/<id>.meta` - two lines.
// 4. <worktree> is the meta's worktree= (metaGet: the last key wins, the value
//    cut at a NUL); a meta that cannot be read is `WARN: cannot read meta file
//    <meta>`, exit 1. AC_BACKEND becomes the meta's backend= (cut at a NUL),
//    herdr without one, for every later call and child.
// 5. SHIP STEP: <worktree>/.crew/ship/current/steps.tsv a regular file (no
//    worktree= reads `/.crew/...`): `awk -F'\t' '<STEPS_AWK>'` on it, the
//    first row whose second TAB field is running, fixing or awaiting_approval,
//    read only to its first NUL; awk's failure (an unreadable file: its `can't
//    open file` lines) ends the run with awk's status. A row found (trailing
//    LFs cut) and a LF go through `tr '\t' ':'` (its failure ignored) and print
//      validate:<the row, TABs as colons>
//    exit 0. A CR rides along: `a\trunning\t1<CR>` is `validate:a:running:1<CR>`,
//    while `a\trunning<CR>` matches no arm. W2 (reproduced): under a UTF-8
//    locale tr stops at a byte that is not UTF-8 (`tr: Illegal byte
//    sequence`), so the row is printed cut there.
// 6. LIVENESS: backendCall("window_alive", [<id>]) (src/lib.ts, the twin of
//    bin/ac-backend.sh's drivers) at the original's top level - its stdin the
//    caller's, stdout and stderr passed through. A refused meta backend
//    (backend=tmux) is the route's ERROR line above, exit 1. 0 goes on; 1 is
//      detached     when the meta's kind= is exactly `self` (metaIsSelf) - a
//                   SELF task holds no agent, its pane is a tail that dies
//                   with the session that opened it while the slice lives
//                   on, and `gone` would send a chief the wrong way
//      gone         otherwise
//    exit 0; any other status - the verb's 2, the backend could not be read:
//    unreachable, past the RPC ceiling, its CLI absent from PATH - is
//      unobservable: backend could not be read for <target>
//    exit 0, <target> backendCall("target") read as `$( )` read it:
//    `herdr:pane-<pane>` or `orca:<handle>`.
// 7. BUSY: backendCall("capture", [<id>, "40"]) - herdr `pane read <pane>
//    --source recent --lines 200` cut to its last 40 lines, orca `terminal
//    read --limit 40 --screen` - piped through `sed '/^$/d'` then `tail -n 25`,
//    so the 25-line window is counted after the blank lines are gone. A stage
//    that fails ends the run with the rightmost failing status and nothing on
//    stdout: the capture's 1 (no handle, a read that fails), or W1
//    (reproduced) sed's 1 under a UTF-8 locale on any byte in the capture that
//    is not UTF-8 (its `RE error: illegal byte sequence` line - under LC_ALL=C
//    the bytes pass), which src/session.ts reads as not busy. The window
//    (NULs dropped, trailing LFs cut) and a LF go to `grep -qE <BUSY_RE>`
//    (AC_BUSY_RE when set and non-empty, else bin/ac-harness.sh's default); a
//    match prints
//      busy
//    exit 0; an ERE grep refuses is grep's line and no match.
// 8. STATUS: <status> is taskStatus(<id>). A size above zero (`[ -s ]`: a
//    symlink followed, a directory counts, a FIFO does not) prints
//      status| <rest>
//    <rest> being `tail -n 1 <status> | cut -d' ' -f2-` read as `$( )` (a last
//    line with no space whole, an empty one nothing, a CR kept; either child
//    failing only shortens <rest>, its own line on stderr - W3 (reproduced):
//    under a UTF-8 locale cut prints nothing for a line holding a byte that is
//    not UTF-8, `cut: stdin: Illegal byte sequence`); else
//      idle
//    exit 0. The prefix is never a bare indent: AC_CAPTAIN_RE's negated class
//    permits whitespace, so a crewmate's own `needs-decision:` status line
//    must not read as a fresh marker from whichever pane runs this (F13) -
//    the fleet watcher polls it too.
//
// EXIT: 0 for every rendered line; 1 for the refusals above and a capture
// that fails; awk's, sed's or tail's status where its failure ended the run;
// 141, silently, when the reader has closed stdout.
//
// SPAWNED under the caller's locale, stdin /dev/null and stderr passed
// through unless noted: awk, and tr (the row on stdin), for the ship step;
// sed, tail and grep, each fed the stage before it, for the busy read; tail
// and cut (tail's output on stdin) for the status line; and awk, herdr or
// orca, jq and tail per backendCall verb.
//
// NAMED DIVERGENCES from the frozen original, each in the leg:
// - A DRIVER THAT FAILED TO LOAD: the original's window_alive returned bash's
//   127, read as unobservable; the port's backend verbs are native and have
//   no driver to lose.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) where the
//   shell printed cd's own lines; exit and stdout alike.
// - Bytes: argv and the environment arrive decoded, so an <id> or AC_BUSY_RE
//   byte that is not UTF-8 is U+FFFD - the refusal names U+FFFD, the ERE no
//   longer matches the byte - and a worktree= path holding one reaches awk's
//   argv as U+FFFD (no such path can exist on APFS, which refuses the name).
//   So is such a byte of the meta's backend= in AC_BACKEND, and so in the
//   route's refusal.
//
// CALLERS: src/lib.ts crewState (src/fleet-view.ts, src/dash.ts: the stdout,
// `unknown` appended on a failure) and src/session.ts (`--talk` refuses on a
// busy, validate: or unobservable line) spawn this entry BY PATH, which is
// the seam their legs stub; the frozen oracles of those three entries do the
// same; the skills run it by hand.
import { statSync, writeSync } from "node:fs";
import { backendCall, backendName, BUSY_RE, die, enterCaller, metaGet, metaIsSelf, shellStatus, spawnShellSync, taskBackend, taskMeta, taskStatus } from "./lib.ts";

const STEPS_AWK = `$2 == "running" || $2 == "fixing" || $2 == "awaiting_approval" { print; exit }`;

const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const latin1 = (s: string): Buffer => Buffer.from(s, "latin1");

function isFile(p: string | Buffer): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function run(cmd: string[], stdin: "ignore" | Buffer): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout: "pipe", stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), out: r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

function say(line: string): never {
  const b = latin1(`${line}\n`);
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
const id = args[0] ?? "";
if (id === "") die("usage: ac-crew-state.sh <id>");
const meta = taskMeta(id);
if (!isFile(meta)) die(`no crewmate meta for ${id}`);
let worktree = "";
try {
  worktree = cutNul(metaGet(meta, "worktree"));
} catch {
  process.exit(1);
}
// taskBackend answers bytes; AC_BACKEND carries the text they spell, as the
// shell's export did.
process.env.AC_BACKEND = latin1(cutNul(taskBackend(id))).toString("utf8") || "herdr";

const steps = `${worktree}/.crew/ship/current/steps.tsv`;
if (isFile(latin1(steps))) {
  const found = run(["awk", "-F\\t", STEPS_AWK, latin1(steps).toString("utf8")], "ignore");
  if (found.status !== 0) process.exit(found.status);
  const row = subst(found.out);
  if (row !== "") say(`validate:${subst(run(["tr", "\\t", ":"], latin1(`${row}\n`)).out)}`);
}

const alive = backendCall("window_alive", [id], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
if (alive.exited) process.exit(1);
if (alive.status === 1) say(metaIsSelf(meta) ? "detached" : "gone");
if (alive.status !== 0) {
  const target = backendCall("target", [id], { stdin: "inherit", stdout: "pipe", stderr: "inherit", subshell: true });
  say(`unobservable: backend could not be read for ${subst(target.out)}`);
}

const cap = backendCall("capture", [id, "40"], { stdin: "inherit", stdout: "pipe", stderr: "inherit", subshell: true });
const sed = run(["sed", "/^$/d"], cap.out);
const win = run(["tail", "-n", "25"], sed.out);
const failed = win.status || sed.status || cap.status;
if (failed !== 0) process.exit(failed);
if (run(["grep", "-qE", BUSY_RE], latin1(`${subst(win.out)}\n`)).status === 0) say("busy");

const status = taskStatus(id);
let size = 0;
try {
  size = statSync(status).size;
} catch {}
if (size > 0) say(`status| ${subst(run(["cut", "-d ", "-f2-"], run(["tail", "-n", "1", status], "ignore").out).out)}`);
say("idle");
