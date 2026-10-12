// watch-autoarm.ts - Stop-hook watcher continuity: the fleet re-arms its own
// watcher instead of the chief remembering to.
// The entry is bin/ac-watch-autoarm.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-watch-autoarm.sh as the oracle the differential leg of
// tests/sh/ac-watch-autoarm.test.sh holds this module to.
//
// Wired in .claude/settings.json as a Stop hook with "asyncRewake": true and an
// explicit timeout. Claude Code runs it in the BACKGROUND on every turn end and
// wakes the session when it exits 2, showing its stderr as a system reminder.
//
// WHY IT EXISTS - three failures this fleet already recorded, all with the same
// root (records/learnings.md):
//   - a second arm exits `already running`, so when the FIRST watcher
//     heartbeat-exits the chief is left blind with no notification (2026-07-16);
//   - `already running` is not proof of coverage: an externally-killed watcher
//     leaves a stale lock that false-positives every re-arm (2026-07-16);
//   - a watcher can be killed externally, and the recorded remedy is "after ANY
//     watcher task ends, check the exit reason and re-arm" (2026-07-16).
// Every one of them ends in "and then the chief must remember". This hook is
// what remembers.
//
// MEASURED CONTRACT (Claude Code 2.1.220, probed directly 2026-07-26 in an
// isolated sandbox - these are observations, not documentation claims, and the
// published docs DISAGREE with two of them):
//   1. Stop hooks fire in headless (`claude -p`) runs too, payload carries
//      `stop_hook_active`.
//   2. A blocking Stop hook is admitted NINE times per turn chain (one with
//      stop_hook_active=false, then eight with true) before Claude stops
//      anyway. The docs say the SECOND block is ignored; on 2.1.220 it is not.
//   3. `stop_hook_active` is true on EVERY firing after the first block in a
//      chain - which is exactly why ac-turnend-guard.sh's `stop_hook_active ->
//      exit 0` line means the synchronous guard blocks at most ONCE per chain
//      even though the harness would admit nine.
//   4. `asyncRewake: true` works: the hook runs detached, exit 2 wakes the
//      session, and its stderr reaches the model (observed: the model answered
//      the probe's stderr text).
//   5. Each firing gets its OWN process group, so the hook's timeout takes the
//      whole tree - including a watcher started in its foreground - with it.
//
// WHAT IT DOES. While supervision is owed, run bin/ac-watch.sh in the
// FOREGROUND of this hook-owned process tree and translate how it closed:
//   heartbeat        -> re-arm silently and keep going. This is the whole
//                       point: a heartbeat costs the chief nothing instead of
//                       one wake plus one re-arm turn every AC_HEARTBEAT -
//                       unless this session's spool already holds a record,
//                       which hands back (exit 2) instead of being re-armed over.
//   already running  -> someone else holds the singleton; exit 0, stay out.
//                       A config-swap REFUSAL says the same thing (a LIVE
//                       watcher holds the lock, with another config) and stands
//                       aside too - never "supervision is NOT covered".
//   anything else    -> print that reason to stderr and exit 2, which wakes the
//                       chief with the reason already in front of it.
// The loop is bounded by AC_AUTOARM_BUDGET (default 3000s, under the hook
// timeout): no arm starts unless a full AC_HEARTBEAT still fits inside it. It
// ends in exit 2 as well, so coverage is handed back to a live chief rather
// than lapsing silently when the budget runs out.
//
// THE REASON LINE is the classifier, NEVER the exit status: every
// ac-watch.sh close prints it on stdout (src/watch.ts watchLog - stderr is the
// arm log and "NEVER stdout") and its REFUSALS print one too while exiting 2.
// The watcher's stdout is read whatever its status (its stderr dropped), its
// empty lines dropped by `sed '/^$/d'` and its last line kept by `tail -n 1`,
// both spawned. `already running` and `refused: a live watcher` are matched as
// PREFIXES; a refusal that armed NOTHING (the owner gate) is no live watcher
// and hands back with its own reason.
//
// EVERY ARM THIS HOOK MAKES IS MARKED BOUNDED (AC_AUTOARM=1, recorded by
// ac-watch.sh in its lock dir). The watcher dies with this firing, so a CHIEF
// arming by hand must not be told `already running` and stand its own - durable -
// arm aside for it: measured 2026-08-06, the chief's arm reported coverage at T+0
// and that same watcher was retired by the budget handback 2.5s later, leaving the
// turn-end guard to block on a stood-down beacon. ac-watch.sh's Singleton block
// owns the refusal; the flag is only how it can tell the two owners apart, and it
// does not change what THIS hook reads (a firing standing aside from a
// predecessor's watcher still gets the `already running` prefix it globs on).
//
// THE ARM ENV is reconstructed on every pass, exactly as the chief would set it
// by hand (rooms-threads skill): a SCOPED roomchief session arms with
// AC_WATCH_ONLY=<its watch set> (ac-ready.sh watch-set; the scope itself when
// that fails), an UNSCOPED crewchief session with AC_WATCH_SKIP=<the promoted
// families>. Arming the fleet watcher UNSKIPPED puts BOTH watchers on a
// promoted family's panes, and they share the per-id dedup marker - so that
// family's wake lands in whichever spool won the race rather than the one its
// roomchief drains.
// SOURCE OF THE PROMOTED SET: the state/<fam>-chief.meta files with
// kind=roomchief - the same metas ac-spawn.sh counts against the room-parallel
// cap and ac-room.sh reads to decide a room is promoted, so no second predicate
// is invented here, and a demote (the meta goes) drops the family at the next
// re-arm. Meta PRESENCE is deliberately the whole test: ac-watch.sh REVALIDATES
// every skip on every poll (roomchief window liveness, beacon freshness, busy
// declaration) and covers the family directly the moment its scoped coverage is
// down - so this hook owes it a cheap list, never a liveness probe that could
// hang inside the Stop hook. The list is comma-joined in byte order.
//
// SUPERVISION IS OWED while a state/*.meta (no dot name) is in flight - a
// crewdeputy's never, a roomchief's only to the UNSCOPED session (its pane
// reports to the FLEET watcher, its hand-back must wake the crewchief), a
// verifier's (kind=verify-*) and a chief SELF TASK's (kind=self, a `tail -f`
// that can never emit a captain marker) never - or, fleet only, while
// config/remote-poll is executable, the standing coverage ac-turnend-guard.sh
// enforces at a turn end. A meta's kind is read as ac_meta_get read it, an
// unreadable one warned (`WARN: cannot read meta file <path>`) and counted.
//
// THE NUDGE. A SCOPED handback (exit 2) first types `wake: <reason> - run
// bin/ac-wake-drain.sh, act on each wake, then re-arm bin/ac-watch.sh as your
// own background task` into its own chief pane, <scope>-chief through the
// backend its meta names (herdr without one), stdout and stderr dropped, its
// failure ignored. asyncRewake delivery is a harness contract (measured on
// Claude Code 2.1.220; hosts move on): when the rewake is swallowed the chief
// sleeps on a durable spool - measured 101 minutes, woken by a human. A
// keystroke is a real turn on every backend; a scoped hook knows its own pane
// through the chief meta. No meta, or a dead pane, skips it - the exit-2
// handback stays the primary channel either way. The budget handback with
// only remote-poll coverage owed nudges nobody.
//
// NEVER `&`, `nohup` or `disown` here: the point is that the watcher lives
// INSIDE the hook's process tree, which the harness owns and reaps.
//
// SCOPE (mirrors ac-turnend-guard.sh, which owns the reasoning): a genuine
// primary checkout of a fleet home (a crewdeputy's own home included - the
// deputy is the chief there), never a crewmate's linked worktree (`git -C
// <home> rev-parse` --git-dir differing from --git-common-dir), and for an
// UNSCOPED session only when this session's harness ancestor holds the home
// lock (the pid= of state/.session-lock, when that pid answers `kill -0`) - a
// read-only session must not arm the fleet watcher. A scoped roomchief does
// not hold that lock and is not read-only, so it arms its own family watcher
// with the watch set recomputed here, exactly as its charter tells it to do by
// hand - while its family is alive: no state/<scope>-chief.meta (ac-teardown.sh
// archives it at demotion) stands it aside, or a dead family's hook would
// re-arm for its own corpse as long as the fleet has any crew at all.
// A SOLO session (AC_SOLO=1) never arms: supervision is the chief's
// obligation, and a solo hook that took the watcher would steal the chief's
// own wake channel (the bounded arm dies with this firing, stranding it).
//
// ROLLBACK. Suspecting this hook is enough to back it out - no captain approval
// needed, the standing authorization and the symptom list are in
// records/captain.md ("ROLLBACK ROUTE FOR THE WATCHER AUTO-ARM HOOK").
// In short: confirm with `printf '{}' | bin/ac-watch-autoarm.sh;
// echo rc=$?` (rc=0 and silent means the hook declined this turn and is not your
// problem), then LEVEL 1 - delete the Stop block naming this script from
// .claude/settings.json, which takes effect at the next turn end and leaves this
// file and its test in place; LEVEL 2, only if the code is actually wrong,
// `git revert` the commit that added it. EITHER WAY, arm the watcher by hand
// afterwards (AGENTS.md section 7) - this hook is what was remembering.
//
// A BROKEN PORT. The frozen original needs bash, git and the bash libs beside
// it (ac-lib.sh's ac_hook_trace, ac-wake-lib.sh's ac_wake_pending, ac-backend.sh
// for the nudge): while bin/ keeps those, copying
// tests/fixtures/ac-watch-autoarm.sh over bin/ac-watch-autoarm.sh in the
// checkout the fleets run restores it whole until the fix lands; the
// captain's revert of the land is the last resort.
//
// Fails open (exit 0) on every missing dependency. A broken continuity hook must
// leave the fleet exactly as it found it, never wedge the harness.
// Exit codes: 0 nothing owed / someone else covers / broken dependency / -h,
//             1 any other argument (refused before anything is read or armed;
//               the shim answers it 0 - F7 below),
//             2 wake the chief, reason on stderr.
// stdout carries nothing but -h's header. The payload on stdin is read to its
// end and ignored. Its argument is the only one it reads: the Stop hook passes
// none, so one marks a hand run - and a hand run from the chief's own tool
// passes the lock-holder test and would hold that tool call inside the
// owed-loop for the whole budget.
//
// TRACE (state/.stop-hooks.log, via src/lib.ts's hookTrace, ac_hook_trace's
// twin): every branch that reaches a real verdict appends one durable
// file-only line (never stdout/stderr), so a chief can tell whether this hook
// even ran. A firing that ENTERS the owed-loop logs TWICE - once when it
// starts (verdict=armed), once when it closes (armed/stood-aside/handed-back)
// - because the loop can hold the chief's coverage for up to
// AC_AUTOARM_BUDGET (~50min) and a single line at exit answers nothing during
// that whole window. NOT traced: a module that cannot load (the floor -
// nothing here runs to resolve a home to write to), no AC_HOME or one cd
// cannot enter, and a linked worktree. The AC_SOLO exit is also untraced: a
// solo session never arms anything, so it never reaches a verdict this trace
// is for.
//
// THE CLOCK. `started` and every pass's now are `date -u +%s`, spawned, so a
// PATH stub binds both sides; an arm starts only while `$(( <now> - started +
// ${AC_HEARTBEAT:-600} ))` is `[ -le ]` ${AC_AUTOARM_BUDGET:-3000}, the
// heartbeat spliced into the sum as text - each operand read by arithValue
// (src/lib.ts) in that order - and a budget that is no integer arming nothing.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1 MALFORMED TRACE KEEP: AC_STOPHOOK_LOG_KEEP enters `$(( keep * 2 ))`
//   after each trace line is written. A malformed number there discards the
//   top-level command the trace stood in: a stand-aside's exit 0 and a
//   handback's exit 2 are skipped and the run falls through - an actionable
//   close goes on to the budget-spent arm (its line again on stderr, its
//   nudge, its trace), then the work-finished trace, and ends 0: the wake is
//   lost. An identifier there ends the run 0 at the first trace line - an
//   armed firing then never arms.
// - W2 MALFORMED HEARTBEAT: a malformed AC_HEARTBEAT (or clock text)
//   discards the owed-loop, so the firing hands back budget-spent at once,
//   every turn end; an identifier ends the run after the armed line with the
//   clock date's status (0 when date succeeded): no arm, no handback, no
//   closing trace. An AC_AUTOARM_BUDGET that is no integer arms nothing and
//   hands back at once too.
// - W3 BAD BACKEND: a scoped handback whose fleet backend name is refused
//   (AC_BACKEND, config/backend or the fleet-state config naming no herdr or
//   orca) ends the run 1 at the nudge, silently, before its trace and its
//   exit 2 - the wake is lost.
// - W4 LOCK PID: `kill -0 <pid=>` takes 0, -1 and -<n> as process-GROUP
//   probes (0 is this firing's own group), so a lock reading pid=0 or pid=-1
//   stands every unscoped firing aside as not the holder.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - F7 STATUS: the shim answers only the module's 0 or 2, so the 1 of an
//   unknown argument (its ERROR line still printed) or of W3, and an
//   identifier's clock status other than 2 (127 for a missing date), exit 0.
// - BUN: with no bun on PATH the shim exits 0 at once, saying nothing and
//   arming nothing, where the original armed; a module that cannot load or
//   crashes exits 0 too, bun's diagnosis on stderr, nothing traced - the
//   floor the original's missing ac-lib.sh was.
// - USAGE HEADER: -h prints THIS header.
// - THE PROCESS: the ancestry walk starts at bun's pid, the shim shell's
//   child, where the original started at its own shell; the harness the lock
//   names is an ancestor of both.
// - PHYSICAL BIN: ac-watch.sh and ac-ready.sh start from the bin/ bun was
//   started in (STARTED_BIN, physical), where the original used its own
//   logical dir - the same files through a symlinked bin/.
// - NUDGE DRIVER: the backend driver is src/lib.ts's (backendCall), so the
//   original's skip when no ac-backend.sh sat beside the hook is gone.
// - EXPRESSIONS: an AC_HEARTBEAT, AC_STOPHOOK_LOG_KEEP or clock text that is
//   an arithmetic expression (60*10) rather than one operand reads as
//   malformed, and an identifier naming a SET variable (HOME, the hook's own
//   `started`) reads as unbound, where bash evaluated both.
// - SHELL-OWN STDERR: bash's `unbound variable`, `syntax error in
//   expression`, `integer expression expected`, `command not found` and
//   failed-redirection lines are not reproduced.
// - ORDER: the metas are walked in byte order; under a UTF-8 locale bash
//   3.2's glob followed collation - the order of the WARN lines and of the
//   AC_WATCH_SKIP list.
// - SCOPE GRAMMAR: the spool the heartbeat check reads is chosen by
//   AC_SCOPE's grammar per its text (wakePending), where bash 3.2's range
//   under a UTF-8 locale let an accented letter through.
// - HOME RESOLUTION: an AC_HOME whose name ends in LF is the directory it
//   names, and a relative one is entered without CDPATH; a caller whose cwd
//   Bun cannot enter resolves no relative AC_HOME (silent).
// - EXCLUSIVE TEMP: the trace trim's temp is created exclusively
//   (`<log>.tmp.<pid>[.<n>]`), where the original's `$f.tmp.$$` wrote
//   through whatever sat there.
// - BYTES: AC_SCOPE, an argument and a state/ entry's name arrive decoded,
//   so a byte that is not UTF-8 prints as U+FFFD, and one in the watcher's
//   reason is typed by the nudge as U+FFFD (stderr and the trace keep the
//   byte); a lock pid of `-l` is no holder, where bash's kill listed its
//   signals on stdout and read it live.
//
// CALLERS: the Stop wiring of .claude/settings.json, behind its [ -x ] gate
// (claude-only: asyncRewake exists on no other harness); a chief by hand.

import { accessSync, constants, existsSync, readFileSync, statSync, writeSync } from "node:fs";
import {
  arithValue,
  backendCall,
  backendName,
  enterCaller,
  hookCapture,
  hookPayload,
  hookTrace,
  metaGet,
  metaIsSelf,
  metaIsVerify,
  metaPaths,
  physicalDir,
  shellStatus,
  spawnShellSync,
  STARTED_BIN,
  testInt,
  wakePending,
} from "./lib.ts";

const { args, atCaller } = enterCaller(process.argv.slice(2));
const arg = args[0] ?? "";
if (arg === "-h" || arg === "--help") {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(0);
}
if (arg !== "") {
  writeSync(2, `ERROR: unknown argument: ${arg} (the hook takes none; -h prints its header)\n`);
  process.exit(1);
}
hookPayload();
if (process.env.AC_SOLO === "1") process.exit(0);

const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const say = (text: string): void => {
  writeSync(2, Buffer.from(text, "latin1"));
};
const latin1 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const captured = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");

const homeVar = process.env.AC_HOME ?? "";
const home = homeVar !== "" && (atCaller || homeVar.startsWith("/")) ? physicalDir(homeVar) : null;
if (home === null) process.exit(0);
const gd = hookCapture(["git", "-C", home, "rev-parse", "--git-dir"]);
const gcd = hookCapture(["git", "-C", home, "rev-parse", "--git-common-dir"]);
if (gd !== "" && gd !== gcd) process.exit(0);
const sd = `${home}/state`;
try {
  if (!statSync(sd).isDirectory()) process.exit(0);
} catch {
  process.exit(0);
}
const scope = process.env.AC_SCOPE ?? "";
const where = scope === "" ? "fleet" : latin1(scope);

// The original's top-level commands: a malformed number in a `$(( ))` it ran
// discarded the one it stood in, and the script went on with the next (W1,
// W2); every block below is one of them.
class Discard {}
function block(run: () => void): void {
  try {
    run();
  } catch (e) {
    if (!(e instanceof Discard)) throw e;
  }
}
function arith(text: string, unboundStatus: number): bigint {
  try {
    return arithValue(text);
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "EUNBOUND") process.exit(unboundStatus);
    if (code === "EARITH") throw new Discard();
    throw e;
  }
}
function trace(detail: string): void {
  try {
    hookTrace("watch-autoarm", detail);
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "EUNBOUND") process.exit(0);
    if (code === "EARITH") throw new Discard();
    throw e;
  }
}

// `$(sed -n 's/^pid=//p' <lock> | head -1)`.
function lockHolder(lock: string): string {
  let out = "";
  try {
    out = Buffer.from(spawnShellSync(["sed", "-n", "s/^pid=//p", lock], { stdin: "ignore", stdout: "pipe", stderr: "inherit" }).stdout).toString("latin1");
  } catch {}
  const nl = out.indexOf("\n");
  return (nl < 0 ? out : out.slice(0, nl)).replace(/\0/g, "");
}

// bash's `kill -0` takes a decimal that fits a pid_t (legal_number, testInt's
// grammar) and sends 0 and -<n> to process groups as kill(2) does.
function answersKill0(pid: string): boolean {
  const n = testInt(pid);
  if (n === null || n < -(2n ** 31n) || n >= 2n ** 31n) return false;
  try {
    process.kill(Number(n), 0);
    return true;
  } catch {
    return false;
  }
}

// `$(ps -o ppid= -p <p> 2>/dev/null | tr -d ' ')`.
function ppidOf(p: string): string {
  try {
    return captured(spawnShellSync(["ps", "-o", "ppid=", "-p", p], { stdin: "ignore", stdout: "pipe", stderr: "ignore" }).stdout).replace(/ /g, "");
  } catch {
    return "";
  }
}

block(() => {
  if (scope !== "") {
    if (isFile(`${sd}/${scope}-chief.meta`)) return;
    trace(`verdict=stood-aside reason=family-demoted scope=${where}`);
    process.exit(0);
  }
  const lock = `${sd}/.session-lock`;
  if (!isFile(lock)) return;
  const holder = lockHolder(lock);
  if (holder === "" || !answersKill0(holder)) return;
  for (let p = String(process.pid); p !== "" && (testInt(p) ?? 0n) > 1n; p = ppidOf(p)) if (p === holder) return;
  trace("verdict=stood-aside reason=not-lock-holder scope=fleet");
  process.exit(0);
});

// ac_meta_get's awk printed the value up to a NUL, and an unreadable meta was
// warned about and read as no kind.
function kindOf(meta: string): string {
  try {
    return cutNul(metaGet(meta, "kind"));
  } catch {
    return "";
  }
}

function crewInFlight(): boolean {
  for (const m of metaPaths(sd)) {
    if (!existsSync(m)) continue;
    const kind = kindOf(m);
    if (kind === "crewdeputy" || (kind === "roomchief" && scope !== "")) continue;
    if (metaIsVerify(m) || metaIsSelf(m)) continue;
    return true;
  }
  return false;
}

function owed(): boolean {
  if (crewInFlight()) return true;
  if (scope !== "") return false;
  try {
    accessSync(`${home}/config/remote-poll`, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// `out="$out${out:+,}$fam"`: a family with an empty name (a bare
// -chief.meta) adds nothing while the list is still empty.
function promotedFamilies(): string {
  let out = "";
  for (const m of metaPaths(sd)) {
    if (!m.endsWith("-chief.meta") || !existsSync(m) || kindOf(m) !== "roomchief") continue;
    out += `${out === "" ? "" : ","}${m.slice(sd.length + 1, -"-chief.meta".length)}`;
  }
  return out;
}

// The scoped chief's meta is read quietly, the bash having dropped the
// subshell's stderr; a fleet backend name the driver refuses ends the whole
// run 1 (W3), the driver having been sourced into the hook's own shell.
function nudge(why: string): void {
  const meta = `${sd}/${scope}-chief.meta`;
  if (scope === "" || !isFile(meta)) return;
  backendName(true);
  let b = "";
  try {
    accessSync(meta, constants.R_OK);
    b = cutNul(metaGet(meta, "backend"));
  } catch {}
  const saved = process.env.AC_BACKEND;
  process.env.AC_BACKEND = Buffer.from(b, "latin1").toString("utf8") || "herdr";
  try {
    backendCall(
      "send_line",
      [`${scope}-chief`, Buffer.from(`wake: ${why} - run bin/ac-wake-drain.sh, act on each wake, then re-arm bin/ac-watch.sh as your own background task`, "latin1").toString("utf8")],
      { stdout: "ignore", stderr: "ignore", subshell: true },
    );
  } catch {
  } finally {
    if (saved === undefined) delete process.env.AC_BACKEND;
    else process.env.AC_BACKEND = saved;
  }
}

function clock(): { status: number; text: string } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["date", "-u", "+%s"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), text: r ? captured(r.stdout) : "" };
}

// `printf '%s\n' "$reason" | sed '/^$/d' | tail -n 1`, each stage spawned.
function lastLine(text: string): string {
  let out = Buffer.from(`${text}\n`, "latin1");
  for (const argv of [["sed", "/^$/d"], ["tail", "-n", "1"]]) {
    try {
      out = Buffer.from(spawnShellSync(argv, { stdin: out, stdout: "pipe", stderr: "inherit" }).stdout);
    } catch {
      out = Buffer.alloc(0);
    }
  }
  return captured(out);
}

block(() => {
  if (owed()) return;
  trace(`verdict=stood-aside reason=nothing-owed scope=${where}`);
  process.exit(0);
});

const budget = process.env.AC_AUTOARM_BUDGET || "3000";
const started = clock().text;
process.env.AC_AUTOARM = "1";
block(() => trace(`verdict=armed reason=loop-start scope=${where} owed=yes`));

block(() => {
  while (owed()) {
    const now = clock();
    const end = BigInt.asIntN(64, BigInt.asIntN(64, arith(now.text, now.status) - arith(started, now.status)) + arith(process.env.AC_HEARTBEAT || "600", now.status));
    const limit = testInt(budget);
    if (limit === null || end > limit) break;
    if (scope !== "") {
      let only: string | null = null;
      try {
        const r = spawnShellSync([`${STARTED_BIN}/ac-ready.sh`, "watch-set", scope], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
        if (r.exitCode === 0) only = captured(r.stdout);
      } catch {}
      process.env.AC_WATCH_ONLY = only === null ? scope : Buffer.from(only, "latin1").toString("utf8");
    } else {
      process.env.AC_WATCH_SKIP = promotedFamilies();
    }

    const reason = lastLine(hookCapture([`${STARTED_BIN}/ac-watch.sh`]));
    if (reason === "heartbeat") {
      if (!wakePending(sd, scope)) continue;
      say("ac-watch-autoarm: queued wakes pending - drain them (bin/ac-wake-drain.sh); the watcher is re-armed automatically at your next turn end.\n");
      nudge("queued wakes pending");
      trace(`verdict=handed-back reason=queued-wakes scope=${where}`);
      process.exit(2);
    }
    if (reason.startsWith("already running") || reason.startsWith("refused: a live watcher")) {
      trace(`verdict=stood-aside reason=already-running scope=${where}`);
      process.exit(0);
    }
    if (reason === "") {
      say("ac-watch-autoarm: the watcher closed with no reason line - supervision is NOT covered; arm it yourself (bin/ac-watch.sh) and check state/.watch.lock.d\n");
      nudge("the watcher closed with no reason line - supervision is NOT covered");
      trace(`verdict=handed-back reason=no-reason-line scope=${where}`);
      process.exit(2);
    }
    say(`ac-watch-autoarm: ${reason}\n`);
    say("ac-watch-autoarm: drain it (bin/ac-wake-drain.sh); the watcher is re-armed automatically at your next turn end.\n");
    nudge(reason);
    trace(`verdict=handed-back reason=actionable-close scope=${where} detail=${reason}`);
    process.exit(2);
  }
});

block(() => {
  if (crewInFlight()) {
    say("ac-watch-autoarm: auto-arm budget spent with crew still in flight - coverage handed back; it re-arms at your next turn end.\n");
    nudge("auto-arm budget spent with crew still in flight - coverage handed back");
    trace(`verdict=handed-back reason=budget-spent-crew-in-flight scope=${where}`);
    process.exit(2);
  }
  if (owed()) {
    say("ac-watch-autoarm: auto-arm budget spent with standing remote-poll coverage still owed (no crew in flight) - coverage handed back; it re-arms at your next turn end.\n");
    trace(`verdict=handed-back reason=budget-spent-remote-poll scope=${where}`);
    process.exit(2);
  }
});
block(() => trace(`verdict=stood-aside reason=work-finished scope=${where}`));
process.exit(0);
