// done.ts - the agent-side PUSH of a completion. AUTHORITATIVE for the push
// contract; ac-watch.sh's PUSH CHANNEL block owns the watcher half. The entry
// is bin/ac-done.sh (a shim that starts this file through bin/ac-bun.sh); THIS
// header is the authoritative spec, and the bash original it replaced stays
// frozen at tests/fixtures/ac-done.sh as the oracle the differential leg of
// tests/sh/ac-done.test.sh holds this module to.
//
//   ac-done.sh <id> <marker>
//
// An agent runs this the moment it announces `done:` / `blocked:` /
// `needs-decision:` / `failed:` (or a roomchief its hand-back), so its chief's
// harness wakes in tens of milliseconds instead of waiting for the watcher's
// next poll tick (0-15s). The PRINTED marker line stays exactly as it is: the
// pane is the BACKUP channel, and ac-watch.sh stays the BACKUP WATCHER that
// catches an agent which crashed or forgot to announce. The crewmate's brief
// bakes this entry's absolute path (bin/ac-brief.sh); the entry's environment
// is the pane's.
//
// Three acts, in this order:
//
//  1. DEDUP STAMP - one completion, ONE wake. The pane carries the same
//     completion, so the push stamps the watcher's OWN marker dedup FIRST:
//     state/.seen-<id> = `<marker>\n` (the marker's RAW bytes, a TAB or LF in
//     it kept - ac-watch.sh marker_seen compares the pane line against it),
//     and state/.seen-hash-<id> is REMOVED, never faked: it is the pane-tail
//     hash recorded AT A WAKE, which an agent cannot know, and its ABSENCE is
//     what tells the watcher to adopt the pane silently (PUSH ADOPT there).
//  2. PUBLISH one durable wake record through wakePublish (src/lib.ts, the
//     twin of ac_wake_publish in bin/ac-wake-lib.sh - the ONE producer
//     chokepoint, whose record and filename grammar three bash producers still
//     write): kind `report`, spool `state/.wake-spool.<scope>` for a legal
//     scope (`[A-Za-z0-9_-]+`) else `state/.wake-spool`, the record
//     `<ts10>\treport\t<id>\t<payload>\n` with every TAB and LF of the marker
//     folded to a space, under `<date +%s%N verbatim>.<pid>.<seq6>`. From this
//     one process, never a child: the pid is the collision identity.
//  3. NUDGE the watcher covering that spool through watcherNudge (the twin of
//     ac_watcher_nudge): the poll `sleep` child of the pid in
//     `.watch.lock.d/pid` (`.watch-only-<scope>.lock.d/pid` for a legal scope)
//     is signalled, under the wrong-kill guard - the pid must be alive, its
//     `ps -o command=` must name ac-watch, and the target must be a `sleep`
//     child of exactly that pid. Nothing to nudge is the correct QUIET
//     outcome: the record is the guarantee, the nudge an accelerator.
//
// stdout on success, one line, exit 0:
//   pushed <id> scope=<AC_FLEET_SCOPE as given | fleet> - <nudge outcome>
// where the outcome is one of
//   no armed watcher for this scope - the record waits in the spool
//   watcher pid=<p> is mid-poll, nothing to nudge - the record waits in the spool
//   nudged watcher pid=<p> (poll sleep <child> ended early)
//   watcher pid=<p> could not be nudged, nothing to nudge - the record waits in the spool
// `scope=` prints the scalar RAW even when it is not a legal family name and
// the record went to the FLEET spool (`AC_FLEET_SCOPE=a/b` prints `scope=a/b`)
// - the bash's reading, kept.
//
// CHANNEL: a crewmate has no AC_HOME, deliberately (ac-spawn.sh's header
// block), so two NARROW SCALARS on its launch line carry what this needs:
//   AC_FLEET_STATE - the fleet's state/ dir (the spool to write and the
//                    watcher lock to read); a relative path resolves against
//                    the caller's cwd; empty reads as unset.
//   AC_FLEET_SCOPE - the family whose scoped watcher supervises this task,
//                    empty/absent for fleet-scoped work. Never AC_SCOPE: a
//                    roomchief's own session scope is not the scope of the
//                    wakes ABOUT it.
// Without AC_FLEET_STATE the state dir is `$AC_HOME/state` (minted), the way
// a chief running this by hand resolves it.
//
// Refusals, each `ERROR: ...` on stderr, exit 1, in order:
//   usage: ac-done.sh <id> <marker>                        either missing or empty
//   AC_HOME is not set - set AC_HOME=<fleet home> ...      no AC_FLEET_STATE and no AC_HOME
//   AC_HOME is not a readable directory: <h>               no AC_FLEET_STATE, AC_HOME unenterable
//   fleet state dir not found: <d> (AC_FLEET_STATE)        <d> is not a directory
//   cannot write the dedup stamp <d>/.seen-<id>: <code>    the stamp failed (an id with `/`,
//                                                          an unwritable dir); nothing published
//   wake NOT published for <id> - the completion is not durable; say so in the pane
//                                                          the publish failed (a clock printing
//                                                          garbage, a spool path a file sits on,
//                                                          link(2) refused) - the stamp has
//                                                          ALREADY advanced by then, on purpose:
//                                                          swallowing it would lose the completion
//                                                          with no trace, so the agent is told
// A failed publish past the private write leaves the record beside the stamp
// as `.wake-tmp.*` litter, never a half record in the spool; mkdir's own line
// precedes the ERROR when the spool cannot be made.
//
// FAIL-SOFT CONTRACT: callers are crewmates following a brief, and the pane
// marker is the backup channel - a push that fails (bun missing from the
// pane's PATH: `ERROR: required tool not found: bun`, exit 1, BEFORE any
// stamp or record exists) costs only the watcher's next poll tick.
//
// DIVERGENCES from the bash original, named in the differential leg: the
// shell's own stderr for a failed stamp (`line 83: ...: No such file or
// directory` / `Permission denied`) and for an unenterable AC_HOME (`cd: ...`)
// is not reproduced - the ERROR lines above stand there with the same exit;
// an argv byte that is not valid UTF-8 reaches this module as U+FFFD (bun's
// argv decoding), so such a marker or id is stamped and recorded as EF BF BD
// where the bash under LC_ALL=C carried the byte; under the crewmate's UTF-8
// locale the bash's `tr` TRUNCATED the record's payload at the first such
// byte (exit 0, a defect), where this module folds bytes and keeps them all.
import { rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import { die, enterCaller, stateDir, wakePublish, watcherNudge } from "./lib.ts";

const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const b = (s: string): Buffer => Buffer.from(s, "latin1");

const { args } = enterCaller(process.argv.slice(2));
const id = args[0] ?? "";
const marker = args[1] ?? "";
if (!id || !marker) die("usage: ac-done.sh <id> <marker>");

const sd = process.env.AC_FLEET_STATE || stateDir();
let isDir = false;
try {
  isDir = statSync(sd).isDirectory();
} catch {}
if (!isDir) die(b(`fleet state dir not found: ${bytes(sd)} (AC_FLEET_STATE)`));
const scope = process.env.AC_FLEET_SCOPE ?? "";

const stamp = `${sd}/.seen-${id}`;
try {
  writeFileSync(stamp, b(`${bytes(marker)}\n`));
} catch (e) {
  die(b(`cannot write the dedup stamp ${bytes(stamp)}: ${(e as { code?: string }).code ?? "error"}`));
}
rmSync(`${sd}/.seen-hash-${id}`, { force: true });

if (!wakePublish(sd, scope, "report", bytes(id), bytes(marker))) die(b(`wake NOT published for ${bytes(id)} - the completion is not durable; say so in the pane`));

writeSync(1, b(`pushed ${bytes(id)} scope=${bytes(scope) || "fleet"} - ${watcherNudge(sd, scope)}\n`));
