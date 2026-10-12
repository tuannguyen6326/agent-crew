// turnend-guard.ts - "no turn ends blind" turn-end predicate.
// The entry is bin/ac-turnend-guard.sh, the fail-open hook shim that starts
// this file through bin/ac-bun.sh's ac_bun_exec_hook; THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-turnend-guard.sh as the oracle the differential leg of
// tests/sh/ac-turnend-guard.test.sh holds this module to.
//
// Wired as the claude Stop hook (.claude/settings.json) and carried to the
// other primary harnesses by their own surfaces - .codex/hooks.json Stop,
// .opencode/plugins/ac-primary-guards.js (session.idle),
// .pi/extensions/ac-primary-turnend-guard.ts (agent_settled),
// .cursor/hooks.json stop via bin/ac-turnend-guard-cursor.sh (a follow-up
// message, never a block - cursor's stop cannot block); the
// non-claude wirings ship shape-faithful and fail open, live probes pending
// (tests/sh/ac-harness-hooks.test.sh is their drift fence). Blocks a turn end
// (exit 2 + reason on stderr) when the session would go blind: wakes IT must
// drain are pending, or the watcher serving it has a stale liveness beacon.
//
// Scoped (the wake twins of src/lib.ts own the keying): a roomchief
// (AC_SCOPE=<fam>) is judged on its OWN wake store (wakePending) and its OWN
// family watcher's beacon; the fleet chief on its own store plus any ORPHAN
// family store it would drain (a live family's store belongs to its chief and
// never pins the fleet's turn).
//
// The queued-wake predicate is judged BEFORE the inflight gate on purpose:
// demoting the last chief leaves its orphaned wake pending exactly as the
// inflight count hits 0, so gating on the count first would end the turn
// blind on that wake.
//
// STANDING COVERAGE (remote-wired idle fleet): with ZERO crew in flight the
// guard still blocks when config/remote-poll is executable, THIS session
// holds the live session lock, and no live watcher beacon exists (absent or
// older than AC_GUARD_GRACE) - remote orders are wired but nothing is
// polling, so the lock holder must arm bin/ac-watch.sh (its idle mode keeps
// the poll slot running) before parking. Without the remote hook an idle
// fleet may park unwatched.
//
// RELATION TO ac-watch-autoarm.sh (the sibling Stop hook, asyncRewake): that
// one ARMS, this one OBJECTS. They are deliberately not merged and not
// coordinated: the harness runs Stop hooks in parallel, so on a genuinely
// uncovered turn end this guard may block once before the auto-arm has armed -
// which is correct, because at that instant the fleet IS blind. The next firing
// carries stop_hook_active and this guard stands down while the auto-arm keeps
// working. The stop_hook_active stand-down is therefore KEPT on purpose:
// measured on Claude Code 2.1.220 the harness admits nine blocking firings per
// chain, but blocking nine times would only repeat a message nobody can act on
// faster - the auto-arm is what actually restores coverage.
//
// Inert (exit 0) when: stop_hook_active is set in the hook payload (loop
// guard), the home is a linked worktree (crewmates do not guard), an UNSCOPED
// session does not hold the home lock (read-only - a scoped roomchief is NOT
// exempted, it owns its store), or nothing is in flight and nothing is queued
// (except the standing-coverage rule above). Fails open on any missing
// dependency: a broken guard must never wedge the harness. A crewdeputy home is
// a fleet home like any other: the deputy is the chief there, its session holds
// that home's lock and this guard covers its crew; only the PARENT's tally
// skips the deputy's own meta (below), since the deputy supervises what runs
// under it.
//
// THE SESSION LOCK. When ANOTHER live session holds this home's lock
// (state/.session-lock, its `pid=` line), this session is READ-ONLY (it must
// not drain wakes or arm the fleet watcher - see ac-lock.sh), so blocking its
// turn end on fleet signals would demand exactly what the lock forbids. The
// holder is recognized by pid ancestry: the guard runs under the harness
// process the lock records, and the walk climbs `ps -o ppid=` from this
// process. UNSCOPED sessions only: a roomchief never holds the home lock
// either, but it is NOT read-only - it owns and drains its family's wake
// store - so a scoped session skips the exemption.
//
// THE TALLY of turn-end coverage: verifier panes are supervised runtime but
// not crewmates; a chief SELF TASK owes no coverage and must never pin the
// chief's turn while it edits; a crewdeputy supervises its own home's crew. A
// ROOMCHIEF counts for the fleet session: the fleet watcher keeps every
// <family>-chief pane because its hand-back must wake the crewchief, so a fleet
// with a live roomchief is not parked. Its own scoped session never counts it -
// its scoped watcher never covers its own pane. Every other kind - ship/scout,
// and any unknown/absent kind, counted fail-safe - still counts (crewMetas owns
// the classes).
//
// Standing coverage is FLEET business: it can only fire for the unscoped
// lock-holding session, because a roomchief never holds the home lock and its
// watcher never polls remote. So a scoped session reaches its own scoped
// predicate.
//
// LANDING-RECEIPT reminder (fleet only, additive): at an OTHERWISE-CLEAN turn
// end - past every wake and coverage predicate, so it masks none - the guard
// blocks (exit 2) when config/remote-mirror is chief/on and a backlog Done line
// (`- [x] <id>`, read by `LC_ALL=C awk '{print $3}'`) newer than the baseline
// has a family with a room and no landing-receipt stamp: a task landed but its
// Slack done-report may be unposted. It repeats on every such turn end until
// the family is stamped - a missed report is never silent - and fails open on
// any missing dependency. The baseline (state/.landing-seen) is the Done ids
// present at the first run, seeded silently and never grown; a family with no
// room (a solo slice, a chief self-task) has no thread narrative to close. The
// chief clears it by posting the report and running `ac-remote.sh done-stamp
// <family>` (state/.landing-receipt-stamp).
//
// HANDBACK block (fleet only, additive, PERSISTENT): while any room sits in
// HANDBACK - a roomchief reported back and nobody demoted it or closed the
// room - the guard reports it on EVERY blocking turn end, not only an
// otherwise-clean one. HANDBACK is a PERSISTENT state while queued wakes, the
// standing-coverage remote-poll gap, and a stale watcher beacon are all
// TRANSIENT conditions, so a persistent state is reported ALONGSIDE whatever
// else is firing instead of queueing behind it: the three earlier exit-2 sites
// (queued wakes, standing-coverage, stale-watcher-with-inflight) and the
// landing-receipt block each append the same HANDBACK line before their own
// exit 2, and the otherwise-clean tail still blocks on it alone. Absent this, a
// busy fleet - a wake queued at most turn ends, or a watcher beacon
// continuously stale - never reaches the otherwise-clean tail and a room can
// sit in HANDBACK indefinitely with nothing objecting (the incident this guards
// against: a real family that posted HANDBACK with its work merged and sat
// unclaimed for a day, caught by the captain, not the guard). This is a STATE
// check, so it catches the failure whatever the CAUSE (wake lost, wake ignored,
// chief forgot, a drain consumed into a backgrounded task nobody read). Like
// the landing-receipt reminder it is NOT fire-once: one dismissal would retire
// the property "a room cannot sit in HANDBACK across turn ends with nothing
// objecting". The chief clears it by one of THREE acts: `ac-teardown.sh
// <family>-chief` (demote) then `ac-room.sh close`, or - refusing the hand-back
// instead of accepting it - posting `HANDBACK-REFUSED:` to the room, which
// settles the obligation while the family stays open and the roomchief stays
// alive to work the remedy. stop_hook_active already bounds repeated blocks.
// The rooms are data/*/room.md in BYTE order, judged in ONE pass by
// src/room.ts's rowsOf (the room grammar's one copy; a room set that cannot be
// read whole owes nothing), so the cost of the one hook that always runs grows
// with no per-room process; it runs at most once per turn end, its answer
// shared by the line and the trace.
//
// PARKED reminder (fleet only, additive, and the one check here that does NOT
// block): at the same otherwise-clean turn end, with NO family in flight, a
// captain inbox of 0 and NO READY item (bin/ac-ready.sh, spawned), the guard
// prints one JSON `systemMessage` on stdout and exits 0 - Claude Code parses
// hook JSON on exit 0 and shows systemMessage to the user, while only exit 2 /
// decision:block stops a turn (Claude Code hooks reference,
// code.claude.com/docs/en/hooks). It reminds the chief to /debrief and end the
// session; records/captain.md ("Standing: PARKED-RESTART") is the authority and
// says explicitly that this is chief discipline, NOT code-enforced - so a
// refusal here would be a bug. The READY condition is the narrowing the same
// standing order forces ("keep working the backlog while items remain"): a
// reminder that fires while work is startable says stop at exactly the wrong
// moment, so anything on the schedule - a STUCK line included - keeps it
// silent. Silence is the load-bearing direction: every unreadable input keeps
// it quiet.
//
// SOLO (AC_SOLO=1) owes no supervision: the chief drains, arms and answers
// hand-backs - blocking the one session that must NOT discharge those
// obligations would nag it into role violations. Its one turn-end concern is
// its own: a self task (kind=self) whose worktree carries uncommitted changes,
// which the session's death would strand. That is a captain-facing NOTICE -
// jq's `{systemMessage: ...}` on stdout, exit 0 - never a block; the payload is
// never read.
//
// TRACE (state/.stop-hooks.log, hookTrace): every branch that reaches a real
// supervision verdict appends one durable file-only line (never stdout or
// stderr) naming what was OBSERVED and the VERDICT, so an incident where the
// wake was published but nobody was woken can tell whether this guard even
// ran: `verdict=<blocked|stood-aside> reason=<r> scope=<fam|fleet>
// queued=<yes|no|n/a> inflight=<n|n/a> age=<Ns|n/a> handback=<fams|none|n/a>`.
// A field never computed is n/a: the age with no beat on record (the beacon
// read's 0 is never printed as an age), the handback set of a scoped session
// (never checked) or of a path that never read it; `none` is an observed
// empty set. NOT traced: stop_hook_active, a linked worktree, the SOLO arm.
//
// Exit codes: 0 (no block; stdout empty or one systemMessage JSON line), 2
// (block; the reasons on stderr, the model reads them verbatim). No other
// status is the module's; anything else - a fault - is folded to 0 by the
// shim, so a fault never holds a stop.
//
// A BROKEN PORT. The frozen original needs bash, jq and its bin/ siblings
// (ac-lib.sh, ac-backend.sh, ac-wake-lib.sh, ac-ready.sh): copying
// tests/fixtures/ac-turnend-guard.sh over bin/ac-turnend-guard.sh in the
// checkout the fleets run (every wiring names that path) restores it whole
// until the fix lands; the captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - a home that is a SUBDIRECTORY of a git checkout reads as a linked worktree
//   - the bare `rev-parse --git-dir` answers absolute where `--git-common-dir`
//   answers relative - so the guard is inert there;
// - stop_hook_active is the payload TEXT `"stop_hook_active":true` (a spaced
//   `"stop_hook_active": true` is judged like any payload);
// - one room.md that cannot be read (a directory of that name) empties the
//   whole HANDBACK set and silences the PARKED reminder;
// - a lock `pid=` of `0`, `-1` or `+<pid>` reads live (kill -0's own
//   grammar) and the session stands aside as read-only;
// - an unreadable crew meta counts in flight, its `cannot read meta file`
//   WARN on the block-reason stderr;
// - AC_STOPHOOK_LOG_KEEP naming a variable ends the guard at its first trace
//   (set -u), so no block ever holds.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: with no bun on PATH the shim allows at once, saying nothing; a
//   module that cannot load or crashes allows too - never a held stop.
// - STATUS FOLD: wherever the original died with a status of its own (set -u
//   on an age a broken date(1) left unset), the shim answers 0.
// - KEEP ARITHMETIC: an AC_STOPHOOK_LOG_KEEP `$(( ))` cannot read (`2x`) made
//   the original abandon each whole top-level statement around a trace, so a
//   queued-wake or HANDBACK block lost its exit 2 and an idle fleet fell
//   through to the stale-watcher line with 0 crew in flight; the port skips
//   the trim and judges as with any keep.
// - SHELL-OWN STDERR: `[`'s `integer expression expected` for an
//   AC_GUARD_GRACE that is no integer, and a missing tool's `command not
//   found`, are not reproduced; the verdicts are the original's.
// - ORDER: the rooms are judged and named in byte order, where the original's
//   glob followed the locale's collation.
// - HOME RESOLUTION: an AC_HOME whose name ends in LF is the directory it
//   names, and a relative one is entered without CDPATH; a caller whose cwd
//   Bun cannot enter resolves no relative AC_HOME (inert).
// - EXCLUSIVE TEMPS: the trace trim and the landing baseline write through
//   <file>.tmp.<pid> created exclusively, where the original wrote through
//   whatever sat at its `.tmp.$$` name.
// - BYTES: an id or family byte that is not UTF-8 reaches grep and the
//   filesystem as U+FFFD.
//
// CALLERS: the Stop wiring of .claude/settings.json and .codex/hooks.json;
// bin/ac-turnend-guard-cursor.sh (AC_TURNEND_GUARD_BIN for its tests);
// .opencode/plugins/ac-primary-guards.js and
// .pi/extensions/ac-primary-turnend-guard.ts, which run the entry and read its
// status and stderr; tests/sh/ac-watch.test.sh drives it for the watcher's
// beacon. Its trace is read by chiefs and incident reviews.

import { closeSync, constants, accessSync, lstatSync, readdirSync, statSync, writeSync } from "node:fs";
import {
  commandV,
  crewMetas,
  dataDir,
  enterCaller,
  exclusiveTemp,
  familyOfId,
  hookCapture,
  hookPayload,
  hookTrace,
  arithValue,
  configReadSoft,
  metaGet,
  metaIsSelf,
  physicalDir,
  softSubdir,
  spawnShellSync,
  STARTED_BIN,
  testInt,
  wakeOrphanPending,
  wakePending,
  watcherBeatRead,
  writeAll,
} from "./lib.ts";
import { rowsOf } from "./room.ts";

const { atCaller } = enterCaller(process.argv.slice(2));
const say = (text: string): void => {
  writeSync(2, Buffer.from(text, "utf8"));
};
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
const native = (b: string): string => Buffer.from(b, "latin1").toString("utf8");
// A child's status, "" stdout when it cannot start; stderr the caller's choice.
const run = (argv: string[], stderr: "inherit" | "ignore", stdin: "inherit" | Buffer = "inherit"): { status: number; out: string } => {
  try {
    const r = spawnShellSync(argv, { stdin, stdout: "pipe", stderr });
    return { status: r.exitCode ?? 1, out: r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "") };
  } catch {
    return { status: 127, out: "" };
  }
};

// A trace whose keep knob names a variable ended the original 0 under set -u
// (the line count's status); one `$(( ))` cannot read only skips the trim here
// (KEEP ARITHMETIC).
function traceLine(detail: string): void {
  try {
    hookTrace("turnend-guard", Buffer.from(detail, "utf8").toString("latin1"));
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "EUNBOUND") process.exit(0);
    if (code !== "EARITH") throw e;
  }
}

// `[ -x <file> ]`: execute (search) permission for this user.
function accessOk(p: string): boolean {
  try {
    accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

if (process.env.AC_SOLO === "1") {
  if (!commandV("jq")) process.exit(0);
  const sd = softSubdir("state", false);
  if (sd === "") process.exit(0);
  let dirty = "";
  for await (const m of crewMetas(sd, "verify", "chiefs", "quiet")) {
    if (!metaIsSelf(m)) continue;
    let wt = "";
    try {
      wt = native(metaGet(m, "worktree"));
    } catch {}
    if (wt === "" || !isDir(wt)) continue;
    if (hookCapture(["git", "-C", wt, "status", "--porcelain"]) === "") continue;
    dirty += ` ${m.slice(m.lastIndexOf("/") + 1).replace(/\.meta$/, "")}`;
  }
  if (dirty === "") process.exit(0);
  try {
    spawnShellSync(
      ["jq", "-n", "--arg", "m", `solo: uncommitted changes in slice${dirty} - the session's end strands them; commit, land (bin/ac-teardown.sh <id>) or leave them on purpose`, "{systemMessage: $m}"],
      { stdin: "inherit", stdout: "inherit", stderr: "inherit" },
    );
  } catch {}
  process.exit(0);
}

const payload = hookPayload();
if (payload.includes('"stop_hook_active":true')) process.exit(0);

const homeVar = process.env.AC_HOME ?? "";
const home = homeVar !== "" && (atCaller || homeVar.startsWith("/")) ? physicalDir(homeVar) : null;
if (home === null) process.exit(0);

const gd = hookCapture(["git", "-C", home, "rev-parse", "--git-dir"]);
const gcd = hookCapture(["git", "-C", home, "rev-parse", "--git-common-dir"]);
if (gd !== "" && gd !== gcd) process.exit(0);

const stateDir = `${home}/state`;
const scope = process.env.AC_SCOPE ?? "";

// kill -0 <word> as bash 3.2's builtin reads it: legal_number (blanks around,
// one sign, base 10, int64), then kill(2) - EPERM is a failure there.
const killZero = (word: string): boolean => {
  const m = /^[ \t\n\v\f\r]*([+-]?[0-9]+)[ \t\n\v\f\r]*$/.exec(word);
  if (!m) return false;
  const n = BigInt(m[1]!);
  if (n < -(2n ** 63n) || n >= 2n ** 63n) return false;
  try {
    process.kill(Number(n), 0);
    return true;
  } catch {
    return false;
  }
};

let holdsLock = false;
const lock = `${stateDir}/.session-lock`;
if (scope === "" && isFile(lock)) {
  const holder = run(["sed", "-n", "s/^pid=//p", lock], "inherit").out.split("\n")[0]!;
  if (holder !== "" && killZero(holder)) {
    let p = String(process.pid);
    let mine = false;
    for (;;) {
      const n = testInt(p);
      if (p === "" || n === null || n <= 1n) break;
      if (p === holder) {
        mine = true;
        break;
      }
      p = run(["ps", "-o", "ppid=", "-p", native(p)], "ignore").out.replace(/ /g, "");
    }
    if (!mine) {
      traceLine(`verdict=stood-aside reason=read-only-lock scope=${scope || "fleet"} queued=n/a inflight=n/a age=n/a handback=n/a`);
      process.exit(0);
    }
    holdsLock = true;
  }
}

let inflight = 0;
for await (const meta of crewMetas(stateDir, "verify", "self")) {
  let kind = "";
  try {
    kind = metaGet(meta, "kind").replace(/\0[\s\S]*$/, "");
  } catch {}
  if (kind === "crewdeputy") continue;
  if (kind === "roomchief" && scope !== "") continue;
  inflight++;
}
// The beacon read reports 0 with a note for every no-beat state, the fire
// condition needs that number, and the trace must never print now-0 as an age.
const beatLine = watcherBeatRead(stateDir, scope);
const beatNote = beatLine.slice(beatLine.indexOf(" ") + 1);
const beat = BigInt(beatLine.slice(0, beatLine.indexOf(" ")));
// A clock text that names a variable was set -u's death right here; one that
// is no arithmetic left the age unset until its first `[ -gt ]`.
let age: bigint | null = null;
try {
  age = BigInt.asIntN(64, arithValue(run(["date", "+%s"], "inherit").out) - beat);
} catch (e) {
  if ((e as { code?: string }).code === "EUNBOUND") process.exit(1);
}
const grace = (): bigint | null => testInt(process.env.AC_GUARD_GRACE || "300");
// `[ "$age" -gt <grace> ]`: an age the arithmetic left unset is set -u's death.
const stale = (): boolean => {
  if (age === null) process.exit(1);
  const g = grace();
  return g !== null && age > g;
};

let hbSeen: string | undefined;
let queuedWord: string | undefined;
const hbField = (): string => (scope !== "" ? "n/a" : hbSeen === undefined ? "n/a" : hbSeen || "none");
const ageField = (): string => (age === null || beatNote !== "" ? "n/a" : `${age}s`);
const trace = (verdict: string, reason: string, queued: string, inflightField: string): void =>
  traceLine(`verdict=${verdict} reason=${reason} scope=${scope || "fleet"} queued=${queued} inflight=${inflightField} age=${ageField()} handback=${hbField()}`);

// data/*/room.md in byte order; [] when there is no data dir or the first
// match is no regular file (the original tested `[ -f "$1" ]` alone).
function rooms(): string[] | null {
  let data: string;
  try {
    data = dataDir();
  } catch {
    return null;
  }
  let names: string[] = [];
  try {
    names = readdirSync(data);
  } catch {}
  const out: string[] = [];
  for (const n of names.filter((n) => !n.startsWith(".")).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    try {
      lstatSync(`${data}/${n}/room.md`);
      out.push(`${data}/${n}/room.md`);
    } catch {}
  }
  return out;
}

type Row = { open: number; hb: boolean; family: string };
function roomRows(files: string[]): Row[] | null {
  const r = rowsOf(files, true);
  if ("error" in r) return null;
  return r.text
    .split("\n")
    .filter((l) => l !== "")
    .map((l) => {
      const [open, hb, family] = l.split("\x1f");
      return { open: Number(open), hb: hb === "1", family: native(family!) };
    });
}

function handbackOwed(): string {
  if (scope !== "") return "";
  const files = rooms();
  if (files === null || files.length === 0 || !isFile(files[0]!)) return "";
  const rows = roomRows(files);
  if (rows === null) return "";
  return rows
    .filter((r) => r.hb)
    .map((r) => r.family)
    .join(" ");
}

function handbackNote(): boolean {
  hbSeen = handbackOwed();
  if (hbSeen === "") return false;
  say(
    `agent-crew: room(s) in HANDBACK - a roomchief reported back and is still waiting: ${hbSeen}. Demote it (bin/ac-teardown.sh <family>-chief) then close the room (bin/ac-room.sh close <family> <outcome>), or if you REFUSE the hand-back post HANDBACK-REFUSED: <why> (bin/ac-room.sh post <family> <actor> "HANDBACK-REFUSED: <why>") to keep the family open and the roomchief alive, before ending the turn.\n`,
  );
  return true;
}

function landingReceiptCheck(): void {
  if (scope !== "") return;
  const mirror = configReadSoft("remote-mirror", "off", "ignore");
  if (mirror !== "chief" && mirror !== "on") return;
  const records = softSubdir("records", false);
  const backlog = `${records}/backlog.md`;
  if (!isFile(backlog)) return;
  const seen = `${stateDir}/.landing-seen`;
  const stamp = `${stateDir}/.landing-receipt-stamp`;
  const awk = (() => {
    try {
      const r = spawnShellSync(["/usr/bin/env", "LC_ALL=C", "awk", "/^- \\[x\\] /{print $3}", backlog], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
      return { status: r.exitCode ?? 1, out: r.stdout.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "") };
    } catch {
      return { status: 127, out: "" };
    }
  })();
  if (awk.status !== 0) return;
  const cur = awk.out;
  if (!isFile(seen)) {
    let tmp: { path: string; fd: number };
    try {
      tmp = exclusiveTemp(`${seen}.tmp`);
    } catch {
      return;
    }
    let written = false;
    try {
      writeAll(tmp.fd, Buffer.from(`${cur}\n`, "latin1"));
      written = true;
    } catch {}
    closeSync(tmp.fd);
    if (written) run(["mv", tmp.path, seen], "ignore");
    return;
  }
  const owed: string[] = [];
  for (const raw of cur.split("\n")) {
    if (raw === "") continue;
    const id = native(raw);
    if (run(["grep", "-qxF", id, seen], "ignore").status === 0) continue;
    let fam: string;
    try {
      fam = familyOfId(id);
    } catch {
      continue;
    }
    if (fam === "" || !isFile(`${home}/data/${fam}/room.md`)) continue;
    let stamped = "";
    try {
      accessSync(stamp, constants.R_OK);
      stamped = metaGet(stamp, fam);
    } catch {}
    if (stamped !== "") continue;
    if (!owed.includes(fam)) owed.push(fam);
  }
  if (owed.length === 0) return;
  say(`agent-crew: a task landed (backlog Done) but its Slack done-report may be unposted for: ${owed.join(" ")}. Post it then stamp it (bin/ac-remote.sh done-stamp <family>) - this repeats every turn end until it is stamped.\n`);
  handbackNote();
  trace("blocked", "landing-receipt", queuedWord ?? "n/a", String(inflight));
  process.exit(2);
}

function handbackCheck(): void {
  if (!handbackNote()) return;
  trace("blocked", "handback-pending", queuedWord ?? "n/a", String(inflight));
  process.exit(2);
}

function parkedReminder(): void {
  if (scope !== "") return;
  const ready = run([`${STARTED_BIN}/ac-ready.sh`], "ignore");
  if (ready.status !== 0 || ready.out !== "") return;
  const files = rooms();
  if (files === null) return;
  if (files.length > 0 && isFile(files[0]!)) {
    const rows = roomRows(files);
    if (rows === null || rows.reduce((n, r) => n + r.open, 0) !== 0) return;
  }
  writeSync(
    1,
    '{"systemMessage":"agent-crew: the fleet is PARKED - nothing in flight, captain inbox 0, no READY item. Run /debrief and END this session (records/captain.md, Standing: PARKED-RESTART); the next order opens a fresh one."}\n',
  );
}

const queued = scope !== "" ? wakePending(stateDir, scope) : wakePending(stateDir, "") || wakeOrphanPending(stateDir);
queuedWord = queued ? "yes" : "no";
if (queued) {
  say("agent-crew: queued wakes are pending. Run bin/ac-wake-drain.sh and handle them before ending the turn.\n");
  handbackNote();
  trace("blocked", "queued-wakes", "yes", String(inflight));
  process.exit(2);
}

if (inflight === 0) {
  if (holdsLock && accessOk(`${home}/config/remote-poll`) && stale()) {
    say("agent-crew: remote orders are wired but nothing is polling - arm bin/ac-watch.sh as a background task (it stays up when idle).\n");
    handbackNote();
    trace("blocked", "standing-coverage", "no", "0");
    process.exit(2);
  }
  landingReceiptCheck();
  handbackCheck();
  trace("stood-aside", "clean", "no", "0");
  parkedReminder();
  process.exit(0);
}

if (stale()) {
  say(`agent-crew: ${inflight} crewmate(s) in flight but ${beatNote || `the watcher beacon is stale (${age}s)`}. Arm bin/ac-watch.sh as a background task before ending the turn.\n`);
  handbackNote();
  trace("blocked", "stale-watcher", "no", String(inflight));
  process.exit(2);
}
landingReceiptCheck();
handbackCheck();
trace("stood-aside", "clean", "no", String(inflight));
process.exit(0);
