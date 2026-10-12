// wake-drain.ts - the chief's consume path: drain this session's queued
// wakes, report the unacknowledged completions in its scope, and assert
// watcher liveness. The entry is bin/ac-wake-drain.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-wake-drain.sh as
// the oracle the differential leg of tests/sh/ac-wake-drain.test.sh holds
// this module to. The store contract it consumes - keying, atomicity,
// ordering, purity - is bin/ac-wake-lib.sh's.
//
// Usage: ac-wake-drain.sh
//        ac-wake-drain.sh ack <id> [<id>...]
// stdin is never read here; every child inherits it.
//
// WHY its shape. Scope is the point: a roomchief (AC_SCOPE=<fam>) drains its
// family's spool alone and the fleet chief the fleet's, so neither consumes
// the other's wakes; a family whose roomchief is not live (meta archived by
// teardown, window dead) is drained by the fleet in place, so a demoted
// family's wakes are never stranded. The completion report exists because a
// wake is one-shot - a deduped marker, a wake in the wrong scope's spool or a
// stage that printed none leaves a finished crewmate nobody learns about - so
// every pass reads durable evidence until it is acked, and a plain drain never
// acks: that would recreate the loss. The ride-alongs are fleet-wide side
// effects (the scheduler, the one remote pusher, the DISTILL autoroom - a
// roomchief's promotion is the crewchief's act, and a scoped AC_SCOPE would
// leak into that spawn), so a scoped drain runs none; every drain is a landing
// checkpoint, which keeps the autoroom level-triggered.
//
// BEFORE ANY ARGUMENT, in this order, every refusal `ERROR: <text>` on stderr,
// exit 1:
// 1. the fleet backend (backendName, src/lib.ts): AC_BACKEND, config/backend,
//    <AC_FLEET_STATE>/../config/backend, herdr - any other name is
//    `unsupported backend '<b>' (valid backends: herdr, orca; tmux/wezterm
//    were removed 2026-07-17)`, solo and ack included.
// 2. the home: no AC_HOME is ac_home's refusal (`AC_HOME is not set - ...`);
//    one cd cannot enter, or a relative one from a caller cwd bun could not
//    name, is `AC_HOME is not a readable directory: <h>`. <state> is
//    <home>/state, minted by a spawned `mkdir -p` as ac_state_dir minted it:
//    one that fails (a regular file there) is mkdir's own line and the run
//    goes on with that path - `no queued wakes`, exit 0.
// 3. AC_SOLO exactly `1`: `a solo session (AC_SOLO=1) never drains or acks
//    wakes - they belong to the chief session (solo-session skill)` - for the
//    drain, for ack and for any bad argument alike; the records it would
//    consume are the chief's. state/ is minted by then, nothing else.
// 4. the arguments: none, or a first one that is empty, is the drain (later
//    words ignored); `ack` with no id is `usage: ac-wake-drain.sh ack <id>
//    [<id>...]`; anything else is `usage: ac-wake-drain.sh | ac-wake-drain.sh
//    ack <id> [<id>...]`.
//
// ACK: `touch <state>/.ack-<id>` (the path's trailing LFs dropped, as `$(...)`
// read it) spawned per id IN ORDER - silent, exit 0; the first touch that
// fails ends the run with ITS line and status, the stamps before it written
// (`ack a '' ../x` stamps .ack-a and .ack-, then touch's `No such file or
// directory`, exit 1). The only writer outside the wake store, and it never
// drains: silencing an item can never consume a wake.
//
// THE DRAIN. <scope> is AC_SCOPE ("" unset or empty). Records are
// `<ts10>\t<kind>\t<id>\t<payload>\n` files named `<ts_ns>.<pid>.<seq6>` in
// <state>/.wake-spool (the fleet's) and <state>/.wake-spool.<family>
// (wakePublish's wire); a CLAIM dir is <state>/.wake-spool-draining.<pid>,
// <pid> THIS process's (the shim exec'd bun, so it is the shim's $$). Steps:
// 1. THE DEAD-CLAIM SWEEP. Each <state>/.wake-spool-draining.<suffix> that is
//    a directory (a link to one included), in byte order, whose suffix -
//    what follows the LAST `.wake-spool-draining.` - is all ASCII digits, and
//    whose pid is not KEPT (claimLive, src/lib.ts: KEPT while it is not this
//    process, is alive, and its `ps -o command= -p <pid>` cannot be read or
//    names `ac-wake-drain` or `/src/wake-drain.ts`): each non-dot entry `[ -e
//    ]` finds, in byte order, has its id read by `awk -F'\t' '{ print $3;
//    exit }' <f>` (a failing awk skips the entry) and goes back to the spool
//    its OWN id maps to - the fleet's for a `*-chief` id, else the one its
//    meta's fleet_scope= names (read silently, cut at a NUL), else
//    familyOfId's (an illegal family name is the fleet's) - through `mkdir -p
//    <spool>` (a failure ENDS THE RUN with mkdir's line and status: a file
//    sitting at a family spool's path wedges every drain here, before
//    anything drains - W12) and `mv <f> <spool>/<name>` (its stderr dropped,
//    its failure ignored); then `rmdir <claim>` (likewise). A flat id with no
//    meta lands in .wake-spool.<id>, for the orphan pass below (W9). The
//    sweep fails toward DUPLICATION: a drainer that died after emitting but
//    before removing its claim has its records emitted again.
// 2. THE OWN SPOOL, wakeSpoolPath(<state>, <scope>): the family spool for a
//    legal scope, else THE FLEET'S - a malformed scope (`bad.scope`) drains
//    the crewchief's wakes while skipping steps 3, 7 and 9 and every
//    completion but its own family's (W18, kept).
// 3. THE ORPHANS, unscoped only: each wakeFamilySpools(<state>) directory, in
//    byte order, whose roomchief is NOT live (roomchiefLive, src/lib.ts - its
//    stdin, stdout and stderr dropped) is drained in place.
// 4. DRAINING a spool: its non-dot entries, one snapshot in byte order; none
//    that `[ -e ]` finds -> nothing (the spool untouched; a dot entry or a
//    dangling link alone is litter). Else `mkdir <claim>` (failing: its line,
//    and the spool is skipped), ONE `mv <entries...> <claim>/` (stderr
//    dropped; a source another drainer took first just fails - the per-record
//    rename IS the claim, so each record emits once in the normal path), the
//    claim's entries listed again: none, or a FIRST one `[ -e ]` cannot find,
//    is "a racer took them all" - `rmdir <claim>` (its own `Directory not
//    empty` when a dangling link sorted first: the real records then sit in
//    the claim until the next drain's sweep - W11) and nothing emitted. Else
//    ONE `awk -F'\t' '{ printf "%s %s %s\n", $2, $3, $4 }' <claimed...>`
//    (per file, so a record missing its LF never merges with the next; a
//    payload is cut at a TAB - W6 - and at a NUL; a two-line record is two
//    wakes; a subdirectory claimed reads as nothing and is destroyed below -
//    W10) through THE RENDERING, then `rm -rf <claim>`: the records are gone,
//    and the spool counts as drained only when rm succeeded.
// 5. THE RENDERING, per awk line (`IFS=' ' read -r kind id rest`: spaces
//    around the fields dropped, inner runs of the payload kept, an empty id
//    field making the payload's first word the id - W4, W5): `<kind> <id>
//    <rest>` byte for byte, FIRST, then at most ONE context line starting
//    with two spaces:
//      kind `remote`: `  status <id>: no chief had drained this remote order
//        until now - ac-remote.sh show <rest less a leading "remote-order ">`
//        (such a record sits in a spool only between ac-remote.sh's publish
//        and its one claim, so the order sat undrained until this pass)
//      else, for a non-empty id whose <state>/<id>.status is a regular file
//      and no symlink, its last line as `tail -n 1` read it (an unreadable
//      file: nothing) less its first word: when non-empty, different from
//      the line, and no literal part of <rest>: `  status <id>: <text>`,
//      <text> past 160 characters cut to 157 plus `...` (characters under a
//      UTF-8 locale - a strictly valid sequence one, every other byte one -
//      bytes under any other: shellPrefix, W7).
// 6. `no queued wakes` when no spool drained.
// 7. COMPLETIONS, per metaPaths(<state>) entry that `[ -e ]` finds and is no
//    verifier (metaIsVerify), <id> its name less `.meta`: IN SCOPE when a
//    `*-chief` id and the session is the fleet's; else <fam> is the meta's
//    fleet_scope= (silent, cut at a NUL), else familyOfId(<id>) - a scoped
//    session takes <fam> = <scope>, the fleet one a <fam> whose roomchief is
//    NOT live (roomchiefLive with this run's stdin and stdout). Then:
//    ARTIFACT - <taskDir(id)>/report.md a regular file (an ambiguous task dir
//    is none): reported when it is `-nt` <state>/.ack-<id> - WHOLE SECONDS of
//    mtime, an absent ack older than anything (a report half a second newer
//    in the same second is NOT newer - W14):
//      UNACKNOWLEDGED COMPLETION: <id> has a report at <path> (silence it: bin/ac-wake-drain.sh ack <id>)
//    and the id ends there either way. IDLENESS - <state>/.change-<id> a
//    regular file `-nt` the ack, holding (NULs dropped, trailing LFs cut)
//    ASCII digits with no leading 0; <idle> = `$(( <clock> - stamp ))`
//    (THE CLOCK below; 64-bit wrap - W16) `[ -ge ]` AC_STALE (unset or
//    empty: 240; testInt's grammar, no number never idle - W15); a <fam>-chief
//    parked at the captain (chiefGateParked: its room holds an open GATE/ASK;
//    an UNREADABLE room is grep's line and NOT parked - W25) or supervising a
//    live member (chiefChildLive with this run's stdin and stdout) is
//    skipped - the watcher declined that wake, and acking it would settle
//    nothing (bin/ac-wake-lib.sh's CHIEF-QUIET block owns why); AC_BACKEND becomes the task's backend (taskBackend cut at a
//    NUL, herdr - an unreadable meta warns once - W20) and STAYS EXPORTED for
//    every later child, the ride-alongs included (W19); the pane through
//    backendCall (below) `backend_capture <id> 40` - any failure skips it; its
//    text through spawned `sed '/^$/d' | tail -n 25` - a failing sed or tail
//    ENDS THE RUN with the rightmost failing status (BSD sed under a UTF-8
//    locale aborts on an invalid byte: exit 1 after the wakes were consumed
//    and printed, before step 8 - W13); a spawned `grep -qE "$AC_BUSY_RE"`,
//    then `grep -qE "$AC_CAPTAIN_RE"` over it (BUSY_RE / CAPTAIN_RE, src/lib.ts;
//    the caller's locale; a bad ERE is no match) matching skips it; else
//      IDLE-MAY-BE-WAITING-ON-YOU: <id> quiet for <idle>s with no marker (peek: bin/ac-peek.sh <id>; silence it: bin/ac-wake-drain.sh ack <id>)
//    Neither line matches any AC_CAPTAIN_RE: they land in a watched pane.
// 8. WATCHER-DOWN: <n> = the metaPaths entries `[ -e ]` finds, minus
//    verifiers and self tasks (metaIsSelf) - FLEET-wide even for a roomchief;
//    above 0, the scope's beacon (watcherBeatRead: `<beat> <note>`) and
//    <age> = `$(( <clock> - beat ))` `[ -gt ]` AC_GUARD_GRACE (unset or
//    empty: 300; testInt) print
//      WATCHER-DOWN: <n> crewmate(s) in flight but <note | no fresh beat (age <age>s)>. Arm bin/ac-watch.sh as a background task now.
// 9. THE RIDE-ALONGS, unscoped only, each <started bin>/<entry> (the bin/ of
//    the root bun was started in - a lab bin/ drives its own siblings):
//    ac-ready.sh (stderr dropped; failing: `WARN   scheduler unavailable:
//    ac-ready.sh exited <rc> - run it to see why`, <rc> the shell's -
//    128+signal, 127 not found, 126 not executable); when
//    <home>/config/remote-poll is `-x`
//    (config/ minted by a spawned `mkdir -p` - W21) `ac-remote.sh
//    push-pending`; `ac-learn.sh autoroom`; when <state>/brain.sqlite is a
//    regular file `ac-brain.sh sync` (stderr dropped; succeeding: `brain-sync
//    ok - <f> files, <c> changed`, each number the first line of a spawned
//    `sed -n 's/.*"<key>":[[:space:]]*\([0-9][0-9]*\).*/\1/p'` over its
//    output - the LAST key on a line, empty when none - W22). Their failures
//    never end the drain.
// 10. THE BRAIN DELTA, both scopes, when <state>/brain.sqlite is a regular
//    file and jq is on PATH: `ac-brain.sh delta --agent <a> --session <s>
//    --compact` (<scope>-chief/<scope>, else crewchief/chief; stderr
//    dropped), succeeding -> its output, plus a LF, the stdin of a spawned `jq
//    -r --arg who <a> <DELTA_JQ>` (stderr dropped; jq's own semantics - a
//    string `.pages` counts its LENGTH - W23).
// EXIT: 0; 1 for every refusal above; the first failing touch's status
// (ack); mkdir's status (step 1, W12); the sed/tail status (step 7, W13); 1
// at set -u's abort (below); 141 when stdout's reader has gone (THE CLOSED
// READER, below).
//
// THE CLOCK: <clock> is nowRaw's text (a non-empty EPOCHSECONDS less trailing
// LFs - bash 3.2 has no such builtin, so the variable was the clock - else
// `date +%s`), spliced into `$(( <clock> - stamp ))` / `$(( <clock> - beat ))` and
// evaluated by a spawned `/bin/bash -c 'set -u; <name>=$1; printf %s "$((
// $0 - <name> ))"' <clock> <value>`: the text is an EXPRESSION there
// (`1700000000+1`, `(2*850000000)`, `0x6553F100`, `x=1700000000`, a comma).
// An evaluation error (`12abc`) discards the TOP-LEVEL command it struck -
// the rest of step 7 at the first idle candidate, or step 8 - and the drain
// goes on; an unset name (`abc`, or `beat` in step 7) is set -u's abort,
// exit 1.
//
// SPAWNED, with the original's argv (stdin the caller's): mkdir, mv, rmdir,
// rm -rf, awk, ps, touch, sed, tail, grep, jq, date and /bin/bash (the
// clock), the four siblings above. THE BACKEND VERBS go through backendCall
// (src/lib.ts, the twin of bin/ac-backend.sh's herdr and orca drivers: awk,
// herdr or orca, jq and tail spawned), stderr dropped every time:
//   backend_window_alive <fam>-chief  - step 3, stdin and stdout dropped
//                                       (roomchiefLive's default); step 7's
//                                       scope, stdin and stdout this run's
//   backend_window_alive <member id>  - step 7 (chiefChildLive), stdin and
//                                       stdout this run's
//   backend_capture <id> 40           - step 7, stdout captured
// each window probe under AC_BACKEND = the probed meta's backend= (herdr when
// none) for that call alone, as the original's `( )` - herdr reading
// /dev/null, orca the stdin passed; only status 0 is live, so a refused
// backend name reads gone and that family's spool drains.
//
// DIVERGENCES from the original, named in the differential leg:
// - W8, THE CLAIM MATCH: the sweep keeps a live claimer whose command names
//   `/src/wake-drain.ts` as well as `ac-wake-drain` - a drainer the shim
//   started is bun running this module, and the original's match alone read
//   it as a reused pid and re-emitted its records.
// - W24 ORDER: claim dirs, records, family spools and metas are walked in
//   byte order (the leg runs the oracle under LC_ALL=C); bash 3.2's glob
//   followed libc collation under a UTF-8 locale.
// - THE ORPHAN PROBE's stdin: the original's ran with the family-list pipe as
//   stdin (an orca CLI could read it - src/guard.ts names the same); the
//   port's reads /dev/null.
// - A name in the clock's text sees only <name> (stamp or beat), where the
//   original's arithmetic saw every variable in its scope (`id`, `meta`...).
// - Shell-own stderr is not reproduced: `[: integer expression expected`
//   (W15, W25), the arithmetic and `unbound variable` lines, `command not
//   found` for a missing sibling.
// - The HOME RESOLUTION ruling: an AC_HOME cd cannot enter is named here,
//   where the shell printed cd's own line.
// - Bytes: argv and env arrive decoded and file names are read as UTF-8, so a
//   byte that is not UTF-8 there (an id, AC_BUSY_RE) is U+FFFD; record and
//   status contents stay bytes. Such a byte of a task meta's backend= is
//   U+FFFD in AC_BACKEND, so in every later child's environment (W19).
// - `command -v jq` is Bun.which, which skips a jq on PATH that is not
//   executable where bash's lookup returned it (the epic-ship precedent).
// - THE CLOSED READER: with stdout's reader gone the port ends at its first
//   failing write, 141; one inside a spool's rendering leaves that spool's
//   records in the claim for the next drain's sweep to emit - toward
//   duplication, as the sweep fails. The original lost only the rendering
//   subshell of its `awk | annotate_wakes` pipeline to SIGPIPE, removed the
//   claim and went on: those records consumed unseen, exit 0 when nothing its
//   main shell printed later hit the pipe.
//
// CALLERS: bin/ac-session-start.sh runs it under `set -euo pipefail` and
// degrades a failure to `WARN: wake drain unavailable (bin/ac-wake-drain.sh
// failed) - queued wakes are UNKNOWN, not empty; run bin/ac-wake-drain.sh by
// hand` (a bun-less PATH, W12, W13); every other caller is a chief or a
// roomchief running it by hand on a wake (bin/ac-watch.sh, bin/ac-guard.sh,
// bin/ac-remote.sh and the hooks print the command, none spawns it).
import { existsSync, lstatSync, readdirSync, readFileSync, statSync, writeSync, accessSync, constants } from "node:fs";
import { isAbsolute } from "node:path";
import {
  backendCall,
  backendName,
  BUSY_RE,
  CAPTAIN_RE,
  chiefChildLive,
  chiefGateParked,
  claimLive,
  die,
  enterCaller,
  familyOfId,
  metaGet,
  metaIsSelf,
  metaIsVerify,
  metaPaths,
  NO_HOME,
  nowRaw,
  physicalDir,
  roomchiefLive,
  shellPrefix,
  shellStatus,
  spawnShellSync,
  STARTED_BIN,
  taskBackend,
  taskDir,
  testInt,
  wakeFamilySpools,
  wakeSpoolPath,
  watcherBeatRead,
} from "./lib.ts";

const DELTA_JQ = `
      if .first_wake == true then "brain-delta: cursor registered for \\($who) (first wake)"
      elif .error != null then empty
      else
        "brain-delta: \\((.pages // []) | length) page(s), \\((.facts // []) | length) fact(s) since \\(.since // "?")"
          + (if .has_more == true then " (more pending - the next drain continues)" else "" end),
        ((.pages // [])[:8][] | "- " + (.path // .slug // "?")),
        ((.facts // [])[:5][] | "- fact: " + ((.fact // "") | .[0:160]))
      end`;

type Io = "inherit" | "ignore" | "pipe";
const PROBE_IO = { stdin: "inherit", stdout: "inherit" } as const;

// Output is bytes: wake text is held latin1, a decoded path or id joins it as
// its UTF-8 bytes.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
// `$(...)`: NULs dropped, trailing LFs cut.
const subst = (b: Buffer): string => b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");
const byteOrder = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

function out(s: string): void {
  const b = Buffer.from(s, "latin1");
  try {
    for (let o = 0; o < b.length; ) o += writeSync(1, b, o);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function run(cmd: string[], stdout: Io, stderr: Io, stdin: "inherit" | Buffer = "inherit"): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  let status = 127;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
    status = shellStatus(r);
  } catch (e) {
    if ((e as { code?: string }).code === "EACCES") status = 126;
  }
  return { status, out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// `"$dir"/*`: the non-dot entries, in byte order.
function entries(dir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort(byteOrder)
    .map((n) => `${dir}/${n}`);
}

// `[ a -nt b ]` in bash 3.2: whole seconds of mtime; an absent b is older.
function newer(a: string, b: string): boolean {
  let ma: number;
  try {
    ma = Math.floor(statSync(a).mtimeMs / 1000);
  } catch {
    return false;
  }
  try {
    return ma > Math.floor(statSync(b).mtimeMs / 1000);
  } catch {
    return true;
  }
}

// ac_meta_get under `2>/dev/null || true`.
function metaQuiet(m: string, key: string): string {
  try {
    accessSync(m, constants.R_OK);
    return cutNul(metaGet(m, key));
  } catch {
    return "";
  }
}

const { args, atCaller } = enterCaller(process.argv.slice(2));
backendName();
const h = process.env.AC_HOME;
if (!h) die(NO_HOME);
// A caller cwd bun could not enter left this process in the distro root, where
// a relative AC_HOME would name the checkout itself.
const home = (atCaller || isAbsolute(h) ? physicalDir(h) : null) ?? die(`AC_HOME is not a readable directory: ${h}`);
const sd = `${home}/state`;
run(["mkdir", "-p", sd], "ignore", "inherit");
const scope = process.env.AC_SCOPE || "";

if (process.env.AC_SOLO === "1") die("a solo session (AC_SOLO=1) never drains or acks wakes - they belong to the chief session (solo-session skill)");

if (args[0] === "ack") {
  const ids = args.slice(1);
  if (ids.length === 0) die("usage: ac-wake-drain.sh ack <id> [<id>...]");
  for (const id of ids) {
    const st = run(["touch", `${sd}/.ack-${id}`.replace(/\n+$/, "")], "inherit", "inherit").status;
    if (st !== 0) process.exit(st);
  }
  process.exit(0);
}
if ((args[0] ?? "") !== "") die("usage: ac-wake-drain.sh | ac-wake-drain.sh ack <id> [<id>...]");

// `IFS=' ' read -r kind id rest` over one line.
function readFields(line: string): [string, string, string] {
  let s = line.replace(/^ +/, "");
  const f: string[] = [];
  for (let i = 0; i < 2; i++) {
    const sp = s.indexOf(" ");
    f.push(sp < 0 ? s : s.slice(0, sp));
    s = sp < 0 ? "" : s.slice(sp).replace(/^ +/, "");
  }
  return [f[0]!, f[1]!, s.replace(/ +$/, "")];
}

// `$(tail -n 1 <file>)`.
function lastLine(b: Buffer): string {
  let end = b.length;
  if (end > 0 && b[end - 1] === 10) end--;
  if (end === 0) return "";
  return subst(b.subarray(b.lastIndexOf(10, end - 1) + 1, end));
}

function render(awkOut: Buffer): void {
  // read drops a last line with no LF; awk ends every one.
  const lines = awkOut.toString("latin1").split("\n");
  lines.pop();
  for (const line of lines) {
    const [kind, id, rest] = readFields(line);
    out(`${kind} ${id} ${rest}\n`);
    if (kind === "remote") {
      const rid = rest.startsWith("remote-order ") ? rest.slice("remote-order ".length) : rest;
      out(`  status ${id}: no chief had drained this remote order until now - ac-remote.sh show ${rid}\n`);
      continue;
    }
    if (id === "") continue;
    const sf = `${sd}/${u8(id)}.status`;
    let data: Buffer;
    try {
      if (!statSync(sf).isFile() || lstatSync(sf).isSymbolicLink()) continue;
      data = readFileSync(sf);
    } catch {
      continue;
    }
    const last = lastLine(data);
    const sp = last.indexOf(" ");
    let text = sp < 0 ? last : last.slice(sp + 1);
    if (text === "" || text === last || rest.includes(text)) continue;
    if (shellPrefix(text, 160) !== text) text = `${shellPrefix(text, 157)}...`;
    out(`  status ${id}: ${text}\n`);
  }
}

function drainSpool(spool: string): boolean {
  const recs = entries(spool);
  if (!recs.some((r) => existsSync(r))) return false;
  const claim = `${sd}/.wake-spool-draining.${process.pid}`;
  if (run(["mkdir", claim], "inherit", "inherit").status !== 0) return false;
  run(["mv", ...recs, `${claim}/`], "inherit", "ignore");
  const claimed = entries(claim);
  if (claimed.length === 0 || !existsSync(claimed[0]!)) {
    run(["rmdir", claim], "inherit", "inherit");
    return false;
  }
  render(run(["awk", "-F\\t", '{ printf "%s %s %s\\n", $2, $3, $4 }', ...claimed], "pipe", "inherit").out);
  return run(["rm", "-rf", claim], "inherit", "inherit").status === 0;
}

function sweepDeadClaims(): void {
  let names: string[] = [];
  try {
    names = readdirSync(sd);
  } catch {}
  const tag = ".wake-spool-draining.";
  for (const n of names.filter((x) => x.startsWith(tag)).sort(byteOrder)) {
    const d = `${sd}/${n}`;
    if (!isDir(d)) continue;
    const pid = d.slice(d.lastIndexOf(tag) + tag.length);
    if (!/^[0-9]+$/.test(pid) || claimLive(pid)) continue;
    for (const f of entries(d)) {
      if (!existsSync(f)) continue;
      const r = run(["awk", "-F\\t", "{ print $3; exit }", f], "pipe", "ignore");
      if (r.status !== 0) continue;
      const rid = u8(subst(r.out));
      let fam = "";
      if (!rid.endsWith("-chief")) fam = metaQuiet(`${sd}/${rid}.meta`, "fleet_scope") || familyOfId(rid);
      const dest = wakeSpoolPath(sd, fam);
      const mk = run(["mkdir", "-p", dest], "inherit", "inherit").status;
      if (mk !== 0) process.exit(mk);
      run(["mv", f, `${dest}/${f.slice(d.length + 1).replace(/\n+$/, "")}`], "inherit", "ignore");
    }
    run(["rmdir", d], "inherit", "ignore");
  }
}

sweepDeadClaims();
let emitted = drainSpool(wakeSpoolPath(sd, scope));
if (scope === "") {
  for (const f of wakeFamilySpools(sd)) {
    const fam = f.slice(f.lastIndexOf("/.wake-spool.") + "/.wake-spool.".length);
    if (!roomchiefLive(sd, fam) && drainSpool(f)) emitted = true;
  }
}
if (!emitted) out("no queued wakes\n");

// `$(( $(ac_now) - <name> ))` evaluated by /bin/bash itself, the clock's text
// spliced in and <name> a variable holding <value>: bash 3.2 reads that text
// as an EXPRESSION (`1700000000+1`, `0x6553F100`, `x=5`, a comma, a name) in
// an arithmetic language a one-operand model cannot read. Its failure throws
// EUNBOUND for set -u's `unbound variable`, EARITH for any other.
function clockMinus(name: "stamp" | "beat", value: string): bigint {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["/bin/bash", "-c", `set -u; ${name}=$1; printf %s "$(( $0 - ${name} ))"`, u8(nowRaw()), value], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
  } catch {}
  if (r !== null && r.exitCode === 0) return BigInt(r.stdout.toString());
  const err = r === null ? "" : r.stderr.toString();
  throw Object.assign(new Error(err), { code: /: unbound variable$/m.test(err) ? "EUNBOUND" : "EARITH" });
}

// An evaluation error in `$(( ))` discarded the whole top-level command it
// struck; an identifier there was set -u's abort.
function topLevel(step: () => void): void {
  try {
    step();
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "EUNBOUND") process.exit(1);
    if (code !== "EARITH") throw e;
  }
}

function inDrainScope(id: string): boolean {
  if (id.endsWith("-chief")) return scope === "";
  const fam = metaQuiet(`${sd}/${id}.meta`, "fleet_scope") || familyOfId(id);
  return scope !== "" ? fam === scope : !roomchiefLive(sd, fam, PROBE_IO);
}

const grepQ = (re: string, text: string): boolean => run(["grep", "-qE", re], "ignore", "inherit", Buffer.from(`${text}\n`, "latin1")).status === 0;

topLevel(() => {
  for (const meta of metaPaths(sd)) {
    if (!existsSync(meta) || metaIsVerify(meta)) continue;
    const id = meta.slice(sd.length + 1, -".meta".length).replace(/\n+$/, "");
    if (!inDrainScope(id)) continue;
    const ack = `${sd}/.ack-${id}`;
    let dir = "";
    try {
      dir = taskDir(id).replace(/\n+$/, "");
    } catch {}
    const rep = dir === "" ? "" : `${dir}/report.md`;
    if (isFile(rep)) {
      if (newer(rep, ack)) out(b8(`UNACKNOWLEDGED COMPLETION: ${id} has a report at ${rep} (silence it: bin/ac-wake-drain.sh ack ${id})\n`));
      continue;
    }
    const changed = `${sd}/.change-${id}`;
    if (!isFile(changed) || !newer(changed, ack)) continue;
    let stamp = "";
    try {
      stamp = subst(readFileSync(changed));
    } catch {}
    if (!/^[1-9][0-9]*$/.test(stamp)) continue;
    const idle = clockMinus("stamp", stamp);
    const stale = testInt(process.env.AC_STALE || "240");
    if (stale === null || idle < stale) continue;
    if (chiefGateParked(id) || chiefChildLive(sd, id, PROBE_IO)) continue;
    // taskBackend answers bytes; AC_BACKEND carries the text they spell, as
    // the shell's export did.
    process.env.AC_BACKEND = u8(cutNul(taskBackend(id))) || "herdr";
    const cap = backendCall("capture", [id, "40"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
    if (cap.exited || cap.status !== 0) continue;
    const sed = run(["sed", "/^$/d"], "pipe", "inherit", Buffer.from(`${subst(cap.out)}\n`, "latin1"));
    const tl = run(["tail", "-n", "25"], "pipe", "inherit", sed.out);
    const st = tl.status || sed.status;
    if (st !== 0) process.exit(st);
    const tail = subst(tl.out);
    if (grepQ(BUSY_RE, tail) || grepQ(CAPTAIN_RE, tail)) continue;
    out(b8(`IDLE-MAY-BE-WAITING-ON-YOU: ${id} quiet for ${idle}s with no marker (peek: bin/ac-peek.sh ${id}; silence it: bin/ac-wake-drain.sh ack ${id})\n`));
  }
});

topLevel(() => {
  let inflight = 0;
  for (const m of metaPaths(sd)) if (existsSync(m) && !metaIsVerify(m) && !metaIsSelf(m)) inflight++;
  if (inflight === 0) return;
  const read = watcherBeatRead(sd, scope);
  const sp = read.indexOf(" ");
  const age = clockMinus("beat", read.slice(0, sp));
  const grace = testInt(process.env.AC_GUARD_GRACE || "300");
  if (grace === null || age <= grace) return;
  const note = read.slice(sp + 1) || `no fresh beat (age ${age}s)`;
  out(`WATCHER-DOWN: ${inflight} crewmate(s) in flight but ${note}. Arm bin/ac-watch.sh as a background task now.\n`);
});

if (scope === "") {
  const ready = run([`${STARTED_BIN}/ac-ready.sh`], "inherit", "ignore").status;
  if (ready !== 0) out(`WARN   scheduler unavailable: ac-ready.sh exited ${ready} - run it to see why\n`);
  const cfg = `${sd.slice(0, -"/state".length)}/config`;
  run(["mkdir", "-p", cfg], "inherit", "inherit");
  let remote = false;
  try {
    accessSync(`${cfg}/remote-poll`, constants.X_OK);
    remote = true;
  } catch {}
  if (remote) run([`${STARTED_BIN}/ac-remote.sh`, "push-pending"], "inherit", "inherit");
  run([`${STARTED_BIN}/ac-learn.sh`, "autoroom"], "inherit", "inherit");
  if (isFile(`${sd}/brain.sqlite`)) {
    const sync = run([`${STARTED_BIN}/ac-brain.sh`, "sync"], "pipe", "ignore");
    if (sync.status === 0) {
      const bsync = Buffer.from(subst(sync.out), "latin1");
      const first = (key: string): string => {
        const o = run(["sed", "-n", `s/.*"${key}":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p`], "pipe", "inherit", bsync).out;
        const lf = o.indexOf(10);
        return subst(lf < 0 ? o : o.subarray(0, lf + 1));
      };
      out(`brain-sync ok - ${first("files")} files, ${first("changed")} changed\n`);
    }
  }
}

if (isFile(`${sd}/brain.sqlite`) && Bun.which("jq")) {
  const [agent, session] = scope !== "" ? [`${scope}-chief`, scope] : ["crewchief", "chief"];
  const delta = run([`${STARTED_BIN}/ac-brain.sh`, "delta", "--agent", agent, "--session", session, "--compact"], "pipe", "ignore");
  if (delta.status === 0) run(["jq", "-r", "--arg", "who", agent, DELTA_JQ], "inherit", "ignore", Buffer.from(`${subst(delta.out)}\n`, "latin1"));
}
process.exit(0);
