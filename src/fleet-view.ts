// fleet-view.ts - render the fleet as one TAB-separated line per crewmate.
// The entry is bin/ac-fleet-view.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-fleet-view.sh as the oracle the
// differential leg of tests/sh/ac-fleet-view.test.sh holds this module to.
//
// Usage: ac-fleet-view.sh
//   Arguments are never read (`ac-fleet-view.sh -h extra` renders the fleet).
//   stdin is never read by the view; every ac-crew-state.sh child inherits it.
//
// OUTPUT on stdout, one row per listed meta in list order:
//   <id>\t<kind>\t<project>\t<mode>\t<state>\t<window>
// or the one line `no crewmates in flight` when nothing is listed.
//
// HOME: AC_HOME through physicalDir (`cd && pwd -P`), relative to the
// caller's cwd. Unset -> `ERROR: <ac_home's refusal>`, exit 1, nothing on
// stdout; not enterable -> `ERROR: AC_HOME is not a readable directory:
// <AC_HOME>`, exit 1. state/ is minted by a spawned `mkdir -p`, as
// ac_state_dir minted it: one that fails (a regular file at the path) prints
// mkdir's own line and the view goes on with that path - `no crewmates in
// flight`, exit 0.
//
// THE LIST is crewMetas(<state>, "verify") (src/lib.ts, ac_crew_metas's twin;
// the skip policy is its "accounting skips only verify" - kind=self, roomchief
// and crewdeputy metas are rows, a `verify-*` kind is not): the non-dot
// `*.meta` entries in BYTE order, NOTHING when the first one does not exist,
// else the paths one spawned awk keeps, rendered as awk prints them. Hence the
// warts of the original, reproduced:
//   W1 a dangling symlink sorting FIRST hides every meta: `no crewmates in flight`.
//   W2 a DIRECTORY named x.meta aborts awk there - awk's own two lines on
//      stderr (`awk: i/o error occurred on <path>`, ` source line number 7`),
//      every meta after it lost, exit still 0.
//   W3 a FIFO named x.meta holds awk in its open until a writer comes: the rows
//      before it are printed and the view waits - forever if none comes.
//   W4 a later dangling or unreadable meta is listed kind-less.
//   W6 a name holding an LF arrives as TWO paths: `b7\nx.meta` is `<state>/b7`
//      and a RELATIVE `x.meta`, read from the caller's cwd - an x.meta there
//      fills the row of id `x`.
//
// A ROW per path: <id> is `basename <path> .meta` (the last component less ONE
// trailing `.meta`: `x.meta.meta` -> `x.meta`, `b8.y.meta` -> `b8.y`; a
// trailing slash dropped, `.meta` alone kept). <state> is crewState(<root>,
// <id>, "inherit") (src/lib.ts): the stdout of `<root>/bin/ac-crew-state.sh
// <id>` with the caller's stdin INHERITED (the original kept its list on fd 3
// so the children got the caller's stdin), stderr dropped, `unknown` APPENDED
// when the child exits non-zero, dies of a signal or cannot start - W10: one
// that printed `half` and then failed reads `halfunknown` - NULs dropped,
// trailing LFs stripped. The line itself is ac-crew-state.sh's (the header of
// src/crew-state.ts is that spec): `validate:<step>`, `gone`, `detached`,
// `unobservable: ...`, `busy`, `status| <line>`, `idle`; an AC_BACKEND it
// refuses makes every row `unknown`. kind, project, mode and window are
// metaGet reads: last key wins,
// the text after the first `=` (`window=x=y` is `x=y`), cut at a NUL as awk
// handed it over (W7), CR and TAB kept raw - a TAB shifts the columns (W8); a
// path that is no regular file reads "". W5: a meta this user cannot read
// prints `WARN: cannot read meta file <path>` once PER READ - four times - and
// its row still prints, those fields empty: the reads sat in printf's
// arguments, where errexit sleeps.
//
// EXIT: 0 once the home resolves, whatever a row read (awk's abort included);
// 1 homeless or an AC_HOME that cannot be entered; 141, silently, when the
// reader has closed stdout (SIGPIPE ended the shell there).
//
// BINARIES: mkdir -p once; awk at most once (crewMetas: stdin /dev/null,
// stderr passed through); <root>/bin/ac-crew-state.sh per row. <root> is the
// directory this module was STARTED in (process.cwd() before enterCaller -
// bin/ac-bun.sh runs bun in the shim's physical <bin>/..), so a copied bin/
// drives its own crew-state, as the original's `cd "$(dirname "$0")" && pwd
// -P` did.
//
// NAMED DIVERGENCES from the frozen original, each in the leg:
//   W9 ORDER: byte order under every locale, where the original's glob
//      followed libc collation under a UTF-8 locale (`_u A2 b1`; C: `A2 _u b1`).
//   An AC_HOME that cannot be entered names the variable where the shell
//      printed its own `cd:` line (exit 1 both; the HOME RESOLUTION ruling).
//   A relative AC_HOME from a caller cwd that has no name is refused, exit 1,
//      never resolved inside the distro root bun was started in; the original
//      resolved it in the deleted directory (`rel`: exit 1 alike; `.`: the
//      shell's getcwd lines and an empty view, exit 0). A relative W6 half is
//      read from the distro root there, where the original's open failed.
//   A meta name that is not UTF-8 reaches readdir as U+FFFD: its path does not
//      exist, so it is a kind-less `unknown` row (as the FIRST entry: no rows,
//      the W1 arm) where the original read the file.
//   An awk that cannot start lists nothing without the shell's own
//      `awk: command not found` line.
//
// CALLERS: bin/ac-session-start.sh prints the view under `-- fleet --` and,
// since the view needs bun, degrades to `WARN: fleet view unavailable ...
// the crew list is UNKNOWN, not empty` when it fails (pinned in
// tests/sh/ac-session-start.test.sh); the bearings and debrief skills run it by
// hand; tests/sh/ac-fleet-view.test.sh asserts the column order, the TABs
// and the verify skip. Nothing parses it.
import { writeSync } from "node:fs";
import { isAbsolute } from "node:path";
import { crewMetas, crewState, die, enterCaller, metaGet, NO_HOME, physicalDir, spawnShellSync } from "./lib.ts";

const root = process.cwd();
const { atCaller } = enterCaller(process.argv.slice(2));

function out(s: string): void {
  const b = Buffer.from(s, "latin1");
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function field(meta: string, key: string): string {
  try {
    return metaGet(meta, key).replace(/\0[\s\S]*$/, "");
  } catch {
    return "";
  }
}

function metaId(path: string): string {
  const p = path.replace(/\/+$/, "") || path.slice(0, 1);
  const base = p.slice(p.lastIndexOf("/") + 1) || p;
  return base !== ".meta" && base.endsWith(".meta") ? base.slice(0, -".meta".length) : base;
}

const h = process.env.AC_HOME;
if (!h) die(NO_HOME);
// A caller cwd bun could not enter left this process in the distro root, where
// a relative AC_HOME would name the checkout itself.
const home = (atCaller || isAbsolute(h) ? physicalDir(h) : null) ?? die(`AC_HOME is not a readable directory: ${h}`);
const sd = `${home}/state`;
try {
  spawnShellSync(["mkdir", "-p", sd], { stdin: "ignore", stdout: "ignore", stderr: "inherit" });
} catch {}

let found = false;
for await (const meta of crewMetas(sd, "verify")) {
  found = true;
  const id = metaId(meta);
  const state = crewState(root, id, "inherit");
  const idBytes = Buffer.from(id, "utf8").toString("latin1");
  out(`${idBytes}\t${field(meta, "kind")}\t${field(meta, "project")}\t${field(meta, "mode")}\t${state}\t${field(meta, "window")}\n`);
}
if (!found) out("no crewmates in flight\n");
process.exit(0);
