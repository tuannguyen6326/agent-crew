// send.ts - send one literal line (or one named key) to a crewmate pane; the
// marked order channel to a crewdeputy; the write-side marker guard. The entry
// is bin/ac-send.sh (a shim that starts this file through bin/ac-bun.sh); THIS
// header is the authoritative spec, and the bash original it replaced stays
// frozen at tests/fixtures/ac-send.sh as the oracle the differential leg of
// tests/sh/ac-send.test.sh holds this module to.
//
// Usage: ac-send.sh <id> [--force] '<text>'
//        ac-send.sh <id> [--force] --key <Enter|Escape|C-c>
// --force counts only as the argument right after <id> (`--force --key` is
// legal, the force unused); one argument past <text> or <key> is never read
// (W6); stdin is never read here, only by the backend children below. Every
// ERROR/WARN and the marker warning are on stderr; the one result line is the
// only stdout. Refused in a solo session (AC_SOLO=1): the crew belongs to the
// chief.
//
// Fail-closed, four ways:
// - a crewmate meta or window that is missing refuses, so a message can never
//   land in the wrong pane.
// - TEXT into a BLOCKED pane (the agent sits on an interactive prompt) is
//   refused: typed text feeds the dialog, its trailing Enter ACCEPTS whatever
//   option is highlighted, and digit-selectable options can reach a PERMANENT
//   always-allow grant. Peek first, answer deliberately with --key (a key never
//   needs --force: it IS the deliberate answer), or pass --force.
// - TEXT into a DEAD-SHELL pane (the harness exited and the terminal fell back
//   to its shell) is refused: the text plus the submit's Enter would EXECUTE as
//   shell commands. Only a PROVEN shell refuses; an unobservable probe delivers
//   - it cannot prove a harness, but a false refusal would strand every steer
//   to a themed shell title. --force types into the shell (a recovery relaunch
//   is exactly that).
// - TEXT delivery is VERIFIED (contract: ac-backend.sh delivery verification):
//   a submit never acknowledged exits non-zero naming WHICH failure it was -
//   text STRANDED in the composer is resubmitted, a pane that could not be
//   READ is peeked at first. A claude composer on herdr is proven BEFORE the
//   Enter: one showing only part of the message (a long send lands as its
//   tail), holding a draft, or not on screen is REFUSED with nothing submitted
//   - send a short pointer to a file instead; --force types without the proof.
//   ARRIVAL is verified on top (contract: ac-lib.sh's claude transcript
//   arrival check, twinned as arrivalWait): a confirmed submit only proves the
//   composer reacted to Enter, never that the text that ARRIVED is the text
//   SENT. A capable target (claude, a resolvable session transcript) whose
//   last typed turn does not match is REFUTED and refused - never "sent to" on
//   a text that landed wrong; a target with no such capability, an unreadable
//   transcript or a slash command (claude runs `/compact` locally and records
//   no typed turn) is UNOBSERVABLE, reported honestly as `delivered (arrival
//   unverified) to <target>`. A REFUTED refusal says WHAT ARRIVED: measured
//   over five steers into one claude pane (4700 chars arrived as 482, 1900 as
//   158, 1100 as 203, 2000 as 883; one 1700-char send arrived whole), a long
//   steer lands TRUNCATED TO ITS TAIL, starting mid-word, and that tail renders
//   exactly like a delivered message - three peeks in that run were read as
//   proof of a landing that had lost 90 percent. The fix for a long
//   instruction is a file plus a SHORT pointer, never a resubmit. No ceiling on
//   the send itself: the cliff is the backend's, and one intact send is a
//   floor, not a number worth refusing on.
// --key is FOCUSED but UNVERIFIED and says so: a keypress has no reliable
// observable (Escape with no dialog, C-c on an idle pane, a key the TUI
// absorbs redraw nothing), so a verdict would be a coin flip;
// `delivered (unverified) to <target>` leaves confirming the EFFECT to the
// caller (bin/ac-peek.sh).
//
// IN ORDER:
//  1. The fleet backend, as sourcing ac-backend.sh checked it (backendName,
//     src/lib.ts), before anything else: AC_BACKEND, config/backend, the first
//     word of <AC_FLEET_STATE>/../config/backend, herdr; any other name is
//     `ERROR: unsupported backend '<b>' (valid backends: herdr, orca;
//     tmux/wezterm were removed 2026-07-17)` - ahead of the solo refusal.
//  2. AC_SOLO exactly `1`: `ERROR: a solo session (AC_SOLO=1) never steers a
//     pane - the crew belongs to the chief session; hand it the order with
//     bin/ac-remote.sh order (solo-session skill)`, homeless too.
//  3. ac-guard.sh beside the shim bun was started from (STARTED_BIN,
//     src/lib.ts), when it can be started: stdio inherited, status ignored.
//     Its warnings precede everything below on stderr, and it may stamp
//     state/.guard-stamp (src/guard.ts's header) - a promotion notice
//     (src/promote.ts) stamps it too.
//  4. No <id>: `ERROR: usage: ac-send.sh <id> [--force] '<text>' | --key
//     <key>`, homeless too.
//  5. No regular file at taskMeta(<id>) (<home>/state/<id>.meta, state/
//     minted, the id a raw path component; a directory or a dangling link is
//     none): `ERROR: no crewmate meta for <id>`; homeless, the AC_HOME refusal
//     precedes that line.
//  6. AC_BACKEND is set, and so exported to every child, to the meta's last
//     backend= (cut at a NUL), herdr when none; an unreadable meta prints
//     `WARN: cannot read meta file <meta>` and reads herdr (W1).
//  7. Liveness: backendCall("window_alive") (src/lib.ts, the twin of the
//     bin/ac-backend.sh drivers) at the original's top level. A route that
//     refuses the name (a meta's backend=tmux) is its ERROR line, exit 1.
//     0 goes on; 1 is `ERROR: window gone for <id>`; anything else is
//     `ERROR: the BACKEND could not be read for <id> - nothing was delivered,
//     and the pane's liveness is UNKNOWN (it may well be alive); check the
//     backend itself (herdr status server), then send again` (contract:
//     ac-backend.sh WINDOW LIVENESS - an unreadable backend is no dead pane).
//     It runs before the arguments past --force are read: `--key` alone on an
//     unreadable backend is that line.
//  8. --key: an empty or absent <key> is `ERROR: missing key name`;
//     backendCall("send_key") as the original ran it, bare under errexit - herdr
//     focuses the tab, and a focus that fails ends the run SILENTLY with its
//     status before any key (V5), as does a send-keys that fails; orca sends
//     one key, 1 on a failure. Then step 15 with `delivered (unverified) to`.
//  9. TEXT: an empty or absent <text> is `ERROR: refusing to send an empty
//     message`. Without --force: backendCall("agent_blocked") answering 0
//     (status !== 0 is "not blocked" - orca's is jq -e's own status; a
//     captain-wait stamp masks it, so the steer that answers a stamped pane is
//     never refused) is `ERROR: <id> is BLOCKED on an interactive prompt -
//     text would feed the dialog and its Enter would ACCEPT it (digit options
//     can grant a permanent always-allow). Peek it (bin/ac-peek.sh <id>),
//     answer deliberately with ac-send.sh <id> --key <key>, or override with
//     ac-send.sh <id> --force '<text>'`; then backendCall("harness_up")
//     answering 1 (2 delivers) is `ERROR: <id>'s pane is a BARE SHELL - its
//     harness has exited, so this text would EXECUTE as shell commands rather
//     than reach an agent. Peek it (bin/ac-peek.sh <id>), recover the session
//     (the stuck-crewmate-recovery skill), or type into the shell deliberately
//     with ac-send.sh <id> --force '<text>'`.
// 10. THE WRITE-SIDE MARKER GUARD: steer text lands VERBATIM in a pane the
//     watcher greps, so a chief instructing a crewmate ABOUT the marker
//     protocol wakes ITSELF with its own words - lived, in this fleet. The
//     text is scanned by bareMarkerVerbs (src/lib.ts, ac_bare_marker_verbs'
//     twin, which owns the detection contract and is broader than
//     AC_CAPTAIN_RE: a mid-sentence marker soft-wraps to visual column 0); a
//     hit prints ONE line
//       warning: this steer carries a bare marker verb (<tokens>) - the watcher greps the pane TAIL, so your own words can wake you and stamp the pane (a mid-sentence marker soft-wraps to visual column 0 and matches). Backtick-wrap it (`done:`) or drop the trailing colon. Delivering anyway.
//     <tokens> joined by one space. It WARNS and DELIVERS - steer text may
//     quote a marker; exit, stdout and the delivered bytes are unchanged.
//     Under a UTF-8 locale [[:space:]] holds NBSP, so `done:<NBSP>` warns
//     there with the NBSP in its token, not under C (W7); a CR after the
//     colon rides in the token.
// 11. THE CHIEF-ORDER MARKER - authoritative for the marked chief-to-deputy
//     channel. A crewdeputy is itself a chief whose chat the crewchief never
//     reads: unmarked, a routed order is indistinguishable from the captain
//     typing into that pane, and the deputy cannot know its answer is owed to
//     a parent chief that will never look there. So when - and ONLY when - the
//     meta's kind= is exactly `crewdeputy` (an unreadable meta WARNs and is
//     none), the delivered line becomes
//       [chief-order home=<parent home, physical> deputy=<id>] <text>
//     applied once, after every refusal above. A captain typing into the
//     pane, and --key, stay UNMARKED: an explicit intervention, not a routed
//     order. The prefix cannot false-wake a watcher - AC_CAPTAIN_RE needs a
//     marker VERB right after its tolerated prefix class. Its home comes from
//     the routing table: deputyParse (src/lib.ts, ac_deputy_parse's awk) fed
//     to `awk -F'\t' -v i=<id> '$1 != "INVALID" && $2 == i { print $3; exit
//     }'` - awk's == is numeric where both sides look numeric, so id 07 reads
//     registry entry 7 (W4) - and either awk failing (the parse aborts on a
//     byte that is not UTF-8 under a UTF-8 locale) ends the run with the
//     rightmost failing status, awk's own line on stderr. Refused BEFORE
//     delivery, since an unmarked or misaddressed order is worse than a failed
//     one: no home found is `ERROR: <id> is a crewdeputy with no parseable
//     entry in <records>/crewdeputies.md - a routed order needs a home for its
//     answer to land in; fix the registry line first`; a home that is no
//     directory is `ERROR: crewdeputy home is gone: <home> - fix or remove the
//     registry line for <id> before routing work to it`; a parent home that is
//     no directory is `ERROR: cannot resolve the parent home for the
//     chief-order marker - refusing to deliver an UNMARKED routed order` (the
//     fail-closed floor: the meta gate already needed the home).
// 12. A SLASH COMMAND is the DELIVERED line matching
//     `^/[a-z][a-z0-9_-]*(:[a-z0-9_-]+)?( |$)`, `$` the string's end (W11:
//     `/compact\nfoo` is none, `/compact x\nfoo` is one); a marked order never
//     is, nor a path-leading steer (/tmp/x ...). claude runs it locally and
//     records no typed turn, so its arrival has nothing to compare, and it
//     answers no captain-wait.
// 13. backendCall("send_line") with AC_SEND_UNPROVEN set to `1` under --force,
//     else `0`, for that one call and restored after - an exported 1 never
//     skips the proof (only herdr reads it; orca --force skips only the
//     refusals above). A route refusal is its line, exit 1 (V12); 0 goes on;
//     2 is `ERROR: delivery UNVERIFIED for <id> - the pane could not be read,
//     so the submit was neither confirmed nor refuted (see stderr above)`; 3
//     (herdr only) is `ERROR: delivery REFUSED for <id> - nothing was
//     submitted (see stderr above)`; anything else - orca's DIALOG verdict
//     included - is `ERROR: delivery NOT confirmed for <id> - the text likely
//     sits stranded in the composer (see stderr above)`; the driver's
//     `ac-backend: ...` line precedes each.
// 14. ARRIVAL: the meta's harness= (cut at a NUL) read; an unreadable meta
//     WARNs and ends the run with 1 - the text has landed, nothing is
//     recorded (W1). harness=claude and no slash command: arrivalWait(the
//     meta's session_id=, the delivered text) - 0 `sent to`; 2 `delivered
//     (arrival unverified) to`; 1 is
//       ERROR: arrival REFUTED for <id> - sent <N> chars, arrived <M>: <shape>
//     <N>/<M> spawned `wc -m` counts (characters under a UTF-8 locale, bytes
//     otherwise) of the delivered text less ONE trailing LF - the arrival
//     compare cut them all, so a refuted `x\n\n` counts one (W12) - and of
//     the arrived turn; <shape> `TRUNCATED TO ITS TAIL - the head was cut in
//     transport, and the pane renders the remainder exactly like a delivered
//     message. Write the instruction to a file and send a SHORT pointer to it
//     instead of resubmitting` when the arrived turn is a non-empty suffix of
//     that text, else `a DIFFERENT text is in the composer, not a cut one -
//     peek it (bin/ac-peek.sh <id>) before resubmitting, since the composer
//     already accepted SOMETHING`. Any other harness, or a slash command:
//     `delivered (arrival unverified) to`. A transcript with one malformed
//     line in its last 200 makes jq fail every read: unobservable after the
//     whole budget (W8).
//     Then the record, the chief's durable index of what it asked (so a
//     restart is not amnesia): statusAppend (src/lib.ts) of `routed: <text>`
//     for a marked order, else `steered: <text>`, the ORIGINAL text with every
//     LF a space - stamped by date(1) and mirrored to the task's timeline,
//     written only on a confirmed or unobservable arrival. As the original's
//     bare call under errexit: a date(1) that fails ends the run with its
//     status, a status file that cannot be appended with 1 - after the text
//     landed, before the stamp below (W5).
// 15. Unless a slash command: backendCall("clear_wait") with its stderr
//     dropped - a delivered steer, text or key, IS the answer a captain-wait
//     stamped pane was parked on, and herdr re-adopts a released pane only on
//     the state TRANSITION this steer supplies (contract: ac-backend.sh
//     CAPTAIN-WAIT STAMP). The same non-slash steer also removes
//     state/.ended-<id> (the ENDED BUSY LATCH, watch.ts header): a reply
//     answered and re-ended inside one poll is that same transition, and
//     must not stay latched quiet waiting for a busy poll that may never
//     come. Then stdout: `<verb> <target>`, <target> backendCall("target")
//     as `$( )` read it - `herdr:pane-<pane>` or `orca:<handle>`.
//
// STDIN BY POSITION (backendCall's comment): the guard and every top-level
// herdr call read the caller's stdin; nested reads read /dev/null; orca reads
// the caller's at every call.
//
// EXIT: 0 delivered; 1 for every refusal and a route refusal; send_key's own
// status on the key path; awk's for a deputy lookup that failed; date's for a
// stamp that failed; 141, silently, when the reader has closed stdout.
//
// NAMED DIVERGENCES from the frozen original, each in the leg:
// - A DRIVER THAT FAILED TO LOAD: the original's liveness call returned
//   bash's 127, the BACKEND line; the port's verbs are native and have no
//   driver to lose (oracle-only row).
// - BUN ABSENT from PATH: the original's guard (a bun shim) printed `ERROR:
//   required tool not found: bun` and the send went on; the port's own shim
//   prints that line and exits 1. So the Stop hook bin/ac-compact-advise.sh's
//   detached opt-in `--send` (config/compact-auto=on) logs `send failed
//   (ERROR: required tool not found: bun )` to its send.log where the original
//   typed /compact: that opt-in path depends on bun through this entry, by
//   design.
// - STDIN BY HISTORY (V1): once harness_up's own `done <<<` had
//   run, bash 3.2 handed a later `$( )`'s herdr - the submit check's `pane
//   read` - the caller's stdin; the port's reads /dev/null.
// - The marker guard's verb list is judged by its text (a-z, |, -) under
//   every locale; bash 3.2's case range collated under UTF-8 and let an
//   uppercase verb (an AC_CAPTAIN_RE override) pass and warn.
// - Bytes: argv and the environment arrive decoded, so an <id> or text byte
//   that is not UTF-8 is U+FFFD in a refusal, a child's argv and the typed
//   text where the original kept the byte (its W2 - tr cutting the record at
//   such a byte under a UTF-8 locale - and its W3 - wc's `Illegal byte
//   sequence` line in a REFUTED count - cannot arise); so is such a byte of
//   the meta's backend= in AC_BACKEND.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) where the
//   shell printed cd's own line; exit and stdout alike.
// - Shell-own stderr is not reproduced: the redirection error of a status
//   file that cannot be appended (W5 - exit 1 kept), `command not found`, a
//   guard path that is a directory, HOME unset where the transcript root
//   needed it (unobservable on both sides).
// - The deputy lookup's two awks run one after the other where the
//   original's ran at once: a lookup that matched early and exited while the
//   parse still wrote a registry past the pipe buffer could end the original
//   with SIGPIPE's 141 - a race no registry of that size has.
//
// CALLERS (exit status only, all fail-soft): src/promote.ts's pane notice
// (stdout and stderr dropped), dashboard/app.ts's composer and chief sends,
// bin/ac-compact-advise.sh's `--send` (`|| verdict='send failed'`, its merged
// output flattened into send.log), tests/fixtures/ac-promote.sh (`if`); chiefs
// run it by hand (the harness-operations, task-lifecycle,
// stuck-crewmate-recovery, rooms-threads, remote-orders and deputies-domains
// skills); refusals across bin/ and src/ name it as the remedy.
// tests/sh/ac-guard.test.sh greps the literal `ac-guard.sh` in the shim's text.
import { rmSync, statSync, writeSync } from "node:fs";
import {
  arrivalWait,
  backendCall,
  backendName,
  bareMarkerVerbs,
  deputyParse,
  deputyRegistry,
  die,
  enterCaller,
  envHome,
  metaGet,
  shellStatus,
  spawnShellSync,
  STARTED_BIN,
  stateDir,
  statusAppend,
  taskBackend,
  taskMeta,
} from "./lib.ts";

const IO = { stdin: "inherit", stdout: "inherit", stderr: "inherit" } as const;
const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
// A message built from bytes (latin1) - an id, a registry path, a home read
// back from awk - is written as those bytes.
const refuse = (msg: string): never => die(Buffer.from(msg, "latin1"));

function isA(p: string | Buffer, dir: boolean): boolean {
  try {
    const s = statSync(p);
    return dir ? s.isDirectory() : s.isFile();
  } catch {
    return false;
  }
}

function run(cmd: string[], stdin: "inherit" | Buffer): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout: "pipe", stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), out: r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// The route's refusal was an `exit 1` inside the sourced driver: it ended
// ac-send wherever the call sat, under `||` and `if` too (V12).
function call(fn: Parameters<typeof backendCall>[0], args: string[], io: Parameters<typeof backendCall>[2] = IO): number {
  const r = backendCall(fn, args, io);
  if (r.exited) process.exit(r.status);
  return r.status;
}

// The meta's <key> as a bare `v="$(ac_meta_get ...)"` read it under errexit:
// an unreadable meta (its WARN printed) ended the run with 1.
function metaKey(meta: string, key: string): string {
  try {
    return cutNul(metaGet(meta, key));
  } catch {
    process.exit(1);
  }
}

function chars(s: string): string {
  return subst(run(["wc", "-m"], Buffer.from(s, "latin1")).out).replace(/ /g, "");
}

function refuted(id: string, sent: string, got: string): never {
  const body = lat(sent).replace(/\n$/, "");
  const shape =
    got !== "" && body.endsWith(got)
      ? "TRUNCATED TO ITS TAIL - the head was cut in transport, and the pane renders the remainder exactly like a delivered message. Write the instruction to a file and send a SHORT pointer to it instead of resubmitting"
      : `a DIFFERENT text is in the composer, not a cut one - peek it (bin/ac-peek.sh ${lat(id)}) before resubmitting, since the composer already accepted SOMETHING`;
  refuse(`arrival REFUTED for ${lat(id)} - sent ${chars(body)} chars, arrived ${chars(got)}: ${shape}`);
}

function say(line: string): never {
  const b = Buffer.from(`${line}\n`, "latin1");
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
if (process.env.AC_SOLO === "1")
  die("a solo session (AC_SOLO=1) never steers a pane - the crew belongs to the chief session; hand it the order with bin/ac-remote.sh order (solo-session skill)");
// A guard that is absent or not executable cannot start: the original's
// `[ ! -x ] ||` skip.
try {
  spawnShellSync([`${STARTED_BIN}/ac-guard.sh`], IO);
} catch {}

const id = args[0] ?? "";
if (!id) die("usage: ac-send.sh <id> [--force] '<text>' | --key <key>");
const force = args[1] === "--force";
const rest = args.slice(force ? 2 : 1);
const meta = taskMeta(id);
if (!isA(meta, false)) die(`no crewmate meta for ${id}`);
// taskBackend answers bytes; AC_BACKEND carries the text they spell, as the
// shell's export did.
process.env.AC_BACKEND = Buffer.from(cutNul(taskBackend(id)), "latin1").toString("utf8") || "herdr";

const alive = call("window_alive", [id]);
if (alive === 1) die(`window gone for ${id}`);
if (alive !== 0)
  die(`the BACKEND could not be read for ${id} - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself (herdr status server), then send again`);

let verb: string;
let slash = false;
if (rest[0] === "--key") {
  const key = rest[1] ?? "";
  if (!key) die("missing key name");
  const pressed = call("send_key", [id, key]);
  if (pressed !== 0) process.exit(pressed);
  verb = "delivered (unverified) to";
} else {
  let text = rest[0] ?? "";
  if (!text) die("refusing to send an empty message");
  if (!force && call("agent_blocked", [id]) === 0)
    die(
      `${id} is BLOCKED on an interactive prompt - text would feed the dialog and its Enter would ACCEPT it (digit options can grant a permanent always-allow). Peek it (bin/ac-peek.sh ${id}), answer deliberately with ac-send.sh ${id} --key <key>, or override with ac-send.sh ${id} --force '<text>'`,
    );
  if (!force && call("harness_up", [id]) === 1)
    die(
      `${id}'s pane is a BARE SHELL - its harness has exited, so this text would EXECUTE as shell commands rather than reach an agent. Peek it (bin/ac-peek.sh ${id}), recover the session (the stuck-crewmate-recovery skill), or type into the shell deliberately with ac-send.sh ${id} --force '<text>'`,
    );
  const markers = bareMarkerVerbs(text);
  if (markers !== null)
    writeSync(
      2,
      Buffer.from(
        `warning: this steer carries a bare marker verb (${`${markers}\n`.replace(/\n/g, " ").replace(/ +$/, "")}) - the watcher greps the pane TAIL, so your own words can wake you and stamp the pane (a mid-sentence marker soft-wraps to visual column 0 and matches). Backtick-wrap it (\`done:\`) or drop the trailing colon. Delivering anyway.\n`,
        "latin1",
      ),
    );
  const order = text;
  let marked = false;
  let kind = "";
  try {
    kind = cutNul(metaGet(meta, "kind"));
  } catch {}
  if (kind === "crewdeputy") {
    const parse = deputyParse();
    const parsed = parse === null ? { status: 0, out: Buffer.alloc(0) } : run(parse, "inherit");
    const found = run(["awk", "-F\\t", "-v", `i=${id}`, '$1 != "INVALID" && $2 == i { print $3; exit }'], parsed.out);
    if (found.status !== 0 || parsed.status !== 0) process.exit(found.status || parsed.status);
    const depHome = subst(found.out);
    if (depHome === "")
      refuse(`${lat(id)} is a crewdeputy with no parseable entry in ${lat(deputyRegistry())} - a routed order needs a home for its answer to land in; fix the registry line first`);
    if (!isA(Buffer.from(depHome, "latin1"), true))
      refuse(`crewdeputy home is gone: ${depHome} - fix or remove the registry line for ${lat(id)} before routing work to it`);
    const parent = envHome();
    if (!isA(parent, true)) die("cannot resolve the parent home for the chief-order marker - refusing to deliver an UNMARKED routed order");
    text = `[chief-order home=${parent} deputy=${id}] ${text}`;
    marked = true;
  }
  slash = /^\/[a-z][a-z0-9_-]*(:[a-z0-9_-]+)?( |$)/.test(text);
  const unproven = process.env.AC_SEND_UNPROVEN;
  process.env.AC_SEND_UNPROVEN = force ? "1" : "0";
  const sent = backendCall("send_line", [id, text], IO);
  if (unproven === undefined) delete process.env.AC_SEND_UNPROVEN;
  else process.env.AC_SEND_UNPROVEN = unproven;
  if (sent.exited) process.exit(sent.status);
  if (sent.status === 2) die(`delivery UNVERIFIED for ${id} - the pane could not be read, so the submit was neither confirmed nor refuted (see stderr above)`);
  if (sent.status === 3) die(`delivery REFUSED for ${id} - nothing was submitted (see stderr above)`);
  if (sent.status !== 0) die(`delivery NOT confirmed for ${id} - the text likely sits stranded in the composer (see stderr above)`);
  verb = "delivered (arrival unverified) to";
  if (metaKey(meta, "harness") === "claude" && !slash) {
    const arrival = arrivalWait(metaKey(meta, "session_id"), text);
    if (arrival.status === 1) refuted(id, text, arrival.last);
    if (arrival.status === 0) verb = "sent to";
  }
  let recorded = false;
  try {
    recorded = statusAppend(id, `${marked ? "routed" : "steered"}: ${lat(order).replace(/\n/g, " ")}`, true);
  } catch (e) {
    if ((e as { code?: string }).code !== "EDATE") throw e;
    process.exit((e as { status: number }).status);
  }
  if (!recorded) process.exit(1);
}
if (!slash) {
  call("clear_wait", [id], { stdin: "inherit", stdout: "inherit", stderr: "ignore" });
  // ENDED BUSY LATCH (watch.ts header): the watcher's own clear is a poll-
  // sampled busy read, which a reply answered and re-ended inside one
  // AC_POLL interval never crosses. A delivered steer other than a slash
  // command is already the fleet's recognized answer to a parked pane
  // (CAPTAIN-WAIT STAMP, ac-backend.sh) - clearing the latch on the SAME
  // transition closes that gap without waiting for a busy poll that may
  // never come.
  try {
    rmSync(`${stateDir()}/.ended-${id}`, { force: true });
  } catch {}
}
say(`${verb} ${subst(backendCall("target", [id], { stdin: "inherit", stdout: "pipe", stderr: "inherit", subshell: true }).out)}`);
