// peek.ts - a bounded tail of a crewmate's pane, every line prefixed so a
// reprinted captain marker cannot read as a fresh one. The entry is
// bin/ac-peek.sh (a shim that starts this file through bin/ac-bun.sh); THIS
// header is the authoritative spec, and the bash original it replaced stays
// frozen at tests/fixtures/ac-peek.sh as the oracle the differential leg of
// tests/sh/ac-peek.test.sh holds this module to.
//
// Usage: ac-peek.sh <id> [<lines>]   (default 40 lines)
// <lines> absent or "" is 40; arguments past it are never read (W10); there
// are no flags (`-h` is an id, W8); stdin is never read here, only by the
// backend children named below. Every ERROR/WARN is on stderr; every refusal
// exits 1.
//
// IN ORDER:
// 1. The fleet backend, as sourcing ac-backend.sh checked it (backendName,
//    src/lib.ts), BEFORE usage (W14): AC_BACKEND, config/backend, the first
//    word of <AC_FLEET_STATE>/../config/backend, herdr; any other name is
//    `ERROR: unsupported backend '<b>' (valid backends: herdr, orca;
//    tmux/wezterm were removed 2026-07-17)`.
// 2. ac-guard.sh beside the shim bun was started from (STARTED_BIN,
//    src/lib.ts), when it can be started: stdio inherited, status ignored.
//    Its warnings precede every line of the peek on stderr and it stamps
//    state/.guard-stamp (src/guard.ts's header).
// 3. No <id>: `ERROR: usage: ac-peek.sh <id> [<lines>]`, homeless too.
// 4. No regular file at taskMeta(<id>) (src/lib.ts: <home>/state/<id>.meta,
//    state/ minted, the id a raw path component - `../x/y` reads
//    <home>/x/y.meta, W9; a directory, W11, or a dangling link is none):
//    `ERROR: no crewmate meta for <id>`. Homeless, the AC_HOME refusal
//    precedes that line (W7).
// 5. AC_BACKEND is set, and so exported to every child, to taskBackend(<id>):
//    the meta's last backend=, herdr when none; an unreadable meta prints
//    `WARN: cannot read meta file <m>` and reads herdr (W1, fail-open, kept).
// 6. Liveness: backendCall("window_alive", [<id>]) (src/lib.ts, the twin of
//    bin/ac-backend.sh's drivers) as the original's top level ran it. A name
//    the route refuses (a meta's backend=tmux) is its ERROR line above. 0
//    goes on; 1 is `ERROR: window gone for <id>` (no handle, a pane herdr's
//    pane list lacks, a stopped herdr server, a disconnected orca terminal -
//    kind=self has no detached arm here); any other status is `ERROR: the
//    BACKEND could not be read for <id> - the pane's liveness is UNKNOWN and
//    no work is lost; check the backend itself (herdr status server), then
//    peek again`. Contract: bin/ac-backend.sh's WINDOW LIVENESS - a pane that
//    is gone stays gone, while a backend nobody can read is no evidence the
//    crewmate died.
// 7. The capture, the original's pipeline
//      backend_capture <id> <lines> | sed '/^$/d' | tail -n <lines> | sed 's/^/peek| /'
//    backendCall("capture", [<id>, <lines>]) as that pipeline's first member
//    ran it, its bytes fed through the three filters, each spawned with that
//    argv and its stderr passed through. herdr: `pane read <pane> --source
//    recent --lines <n>` (<n> is <lines> when an integer >= 200, else 200,
//    W4), read as `$( )` reads it (NULs dropped, trailing LFs cut), one LF
//    restored, then `tail -n <lines>`; orca: `terminal read --terminal <h>
//    --limit <lines> --screen --json`, then `jq -r '.result.terminal.tail[]?'`.
//    The exit is pipefail's: the rightmost non-zero status of the four.
// Prefixed, never merely indented: AC_CAPTAIN_RE's negated class still
// permits whitespace, so an indent alone keeps a marker matching at line
// start (contract: F13/AC_CAPTAIN_RE, bin/ac-lib.sh). A crewmate's own
// captain-marker line, reprinted verbatim, must not read as a fresh marker
// from whichever pane is running this - the fleet watcher polls it too.
//
// What the filters own, reproduced by spawning them: blanks are dropped AFTER
// the raw tail, so <lines> counts raw lines and fewer may print (W12); a
// line of blanks or a lone CR is no blank, CR and TAB are kept, a last line
// without LF gains one (W13); `0` prints nothing; BSD tail reads `-2` as 2
// and `+3` from line 3 - on herdr twice, the driver's tail and this one's
// (W2); `abc` is tail's `illegal offset` line, twice on herdr and once on
// orca, exit 1 (W3); under a UTF-8 locale a byte that is not UTF-8 makes sed
// abort with its `RE error: illegal byte sequence` line - the lines before
// it print, exit 1 (W6). A capture that fails (a read that fails, no
// handle) prints nothing on either stream, exit 1 (W5).
//
// STDIN BY POSITION: herdr's `pane get` reads the caller's stdin; its `pane
// list`, `status server` and the capture's `pane read` read /dev/null; orca
// reads the caller's at every call, so its first call can drain it.
//
// EXIT: 0 rendered (even empty); 1 for every refusal; else the rightmost
// failing stage's status (128+n when a signal ended it, 141 at a closed
// reader).
//
// DIVERGENCES from the original, named in the differential leg:
// - A DRIVER THAT FAILED TO LOAD: the original's liveness call returned
//   bash's 127, the BACKEND line; the port's verbs are native and have no
//   driver to lose.
// - BUN ABSENT from PATH: the original's guard (a bun shim) printed `ERROR:
//   required tool not found: bun` and the peek went on; the port's own shim
//   prints that line and exits 1.
// - Bytes: argv arrives decoded, so an id or <lines> byte that is not UTF-8
//   is U+FFFD in a path, a child's argv and a refusal, where the original
//   kept the byte; so is such a byte of the meta's backend= in AC_BACKEND.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) where the
//   shell printed cd's own line; exit and stdout alike.
// - Shell-own stderr is not reproduced (`command not found`, a guard path
//   that is a directory).
//
// CALLERS: no script runs this entry; chiefs run it by hand (the
// harness-operations, task-lifecycle, stuck-crewmate-recovery and bearings
// skills), and refusals across bin/ name it as the way to look at a pane - a
// bun-less PATH answers them with the shim's refusal.
// tests/sh/ac-guard.test.sh greps the literal `ac-guard.sh` in the shim's
// text; tests/sh/ac-send.test.sh pins both refusal wordings.
import { statSync } from "node:fs";
import { backendCall, backendName, die, enterCaller, shellStatus, spawnShellSync, STARTED_BIN, taskBackend, taskMeta } from "./lib.ts";

const { args } = enterCaller(process.argv.slice(2));
backendName();

// A guard that is absent or not executable cannot start: the original's
// `[ ! -x ] ||` skip.
try {
  spawnShellSync([`${STARTED_BIN}/ac-guard.sh`], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
} catch {}

const id = args[0] ?? "";
const lines = args[1] || "40";
if (!id) die("usage: ac-peek.sh <id> [<lines>]");
let meta = false;
try {
  meta = statSync(taskMeta(id)).isFile();
} catch {}
if (!meta) die(`no crewmate meta for ${id}`);
// taskBackend answers bytes; AC_BACKEND carries the text they spell, as the
// shell's export did.
process.env.AC_BACKEND = Buffer.from(taskBackend(id), "latin1").toString("utf8");

const alive = backendCall("window_alive", [id], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
if (alive.exited) process.exit(alive.status);
if (alive.status === 1) die(`window gone for ${id}`);
if (alive.status !== 0)
  die(`the BACKEND could not be read for ${id} - the pane's liveness is UNKNOWN and no work is lost; check the backend itself (herdr status server), then peek again`);

// One after another, where the original's ran at once: each filter reads to
// EOF or stops for good, so the bytes and the rightmost failure are the
// pipeline's.
const capture = backendCall("capture", [id, lines], { stdin: "inherit", stdout: "pipe", stderr: "inherit", subshell: true });
let status = capture.status;
let data = capture.out;
const filters = [["sed", "/^$/d"], ["tail", "-n", lines], ["sed", "s/^/peek| /"]];
filters.forEach((argv, i) => {
  const last = i === filters.length - 1;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin: data, stdout: last ? "inherit" : "pipe", stderr: "inherit" });
  } catch {}
  const s = shellStatus(r);
  if (s !== 0) status = s;
  data = !last && r ? Buffer.from(r.stdout) : Buffer.alloc(0);
});
process.exit(status);
