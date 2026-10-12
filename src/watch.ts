// watch.ts - the chief's zero-token fleet watcher for any backend, one
// long-running process per arm. The entry is bin/ac-watch.sh (a shim that
// starts this file through bin/ac-bun.sh); THIS header is the authoritative
// spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-watch.sh as the oracle the differential leg of
// tests/sh/ac-watch.test.sh holds this module to. Its blocks follow a run in
// code order: the exits, --release, the scope and skip guards, the signals,
// the arm, then the loop - push check, beacon, brain freshen, the pane pass,
// the remote slot, heartbeat, poll wait - and last the knobs and the port's
// own terms.
//
// Usage: ac-watch.sh [--once | --release <pid>]
//
// PREAMBLE, in order: the backend AC_BACKEND, config/backend or the
// AC_FLEET_STATE rung names is validated (`ERROR: unsupported backend '<b>'
// (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)`, exit
// 1); a solo session refuses (`ERROR: a solo session (AC_SOLO=1) never arms a
// watcher - supervision belongs to the chief session (solo-session skill)`,
// exit 1) - its watcher would publish into the chief's spool, whose records
// only the chief may consume; the home is bound and state/ minted (no AC_HOME
// is ac_home's refusal, exit 1). Only the first argument is read: `--release`
// takes the second, `--once` is the checkpoint, and ANY other word or none
// ARMS (W1); later words are ignored. There is no usage text but --release's
// line.
//
// Polls every crewmate pane on an interval, absorbs benign activity itself,
// and only surfaces ACTIONABLE events: a captain-relevant report line
// (AC_CAPTAIN_RE), a stage report.md appearing or advancing (the ARTIFACT
// CHANNEL below), a vanished window, or a stalled-quiet pane. Actionable
// events are published durably (ac_wake_publish: one record per file, atomic
// ln) to the wake spool OF THIS WATCHER'S SCOPE and the watcher EXITS with a
// one-line reason on stdout, so a harness running it as a background task
// gets woken exactly once per actionable event batch.
//
// Exit reasons: `report:<id>` (a pane marker, or the artifact channel below -
// the payload says which), `push:<id>` (the PUSH CHANNEL below - an agent
// published its own completion), `gone:<id>`, `unobservable:<id>` (the BACKEND
// could not be read, so the pane's liveness is UNKNOWN - never a death: no
// failure is stamped, the pane keeps being polled, and one outage costs one wake
// and one status line; contract: ac-backend.sh WINDOW LIVENESS), `ask:<id>` (agent blocked on an
// interactive prompt - herdr's pane state or Orca's agentWait), `ended:<id>` (the ENDED-TURN LOUD
// WAKE below - a pane that finished its turn with no marker), `limited:<id>`
// (USAGE LIMIT below - an ended turn stopped by the provider), `needs-login:<id>`
// (its EXPIRED LOGIN sibling - a human must sign in again), `stale:<id>`
// (a pane merely quiet while working). Neither of those two is ever a chief
// supervising a live crewmate, see SUPERVISING-CHIEF QUIET below. `remote:<rid>`
// (new remote captain orders arrived), `remote-failed:<last-rid|none>` (the poll
// DIED mid-ingest and abandoned the rest of the batch - the named rid is the
// last one that landed, so re-sending starts after it; see FAILED POLL under the
// Remote-order slot below), `remote-timeout:<last-rid|none>` (the poll blew
// through its ceiling and was killed - a WEDGED transport, not a dead spool, and
// a different prefix precisely so the reader can tell the two apart; see HUNG
// POLL below), `heartbeat`, `signal:<NAME>` (a TERM/INT
// - either the owner's own `--release`, see OWNER-MARKED RELEASE, or a kill
// from outside, see EXTERNAL KILLS; the reason text says which), `check:quiet`
// (the --once checkpoint below completed one bounded pane pass plus one bounded
// remote poll and found nothing actionable). Every one of
// them exits 0: the reason line, not the exit status, is the payload the chief
// reads. A reason may carry ONE trailing clause after ` - `, on the same line
// (the reader keeps only the last non-empty line): a wake branch whose durable
// record failed to write appends `WAKE NOT DURABLE: ...` (reasonLine), and
// `signal:<NAME>` appends `poll interrupted mid-flight; last rid ingested:
// <rid|none>` when the kill landed inside a poll. The prefix before ` - ` is
// the classifier; the clause is for the chief.
// With --once it does a single bounded pass (Codex-style checkpoint), and with
// --release <pid> it releases ONE named watcher and exits without arming.
// A captain-wait marker (AC_DECISION_RE: needs-decision:/blocked: and the
// delivery-await checks-passed:) also stamps the pane BLOCKED in the herdr UI until
// the answering ac-send, a later non-decision marker, or the STALE-STAMP
// SUPERSESSION below clears it; a pane still parked on an already-seen
// captain-wait marker with no stamp is reconciled silently each pass (busy and
// superseded panes exempt) - contract: ac-backend.sh CAPTAIN-WAIT STAMP.
//
// OWNER-MARKED RELEASE (`--release <pid>`). The distro's OWN way to stop a
// watcher: it writes state/.watcher-release-<pid> (releaser pid, target pid,
// reason=config-swap, epoch) and THEN sends `kill -TERM <pid>` to that one pid,
// so intent and signal can never drift apart. The exiting watcher whose pid the
// marker names logs and prints `config-swap by owner (released by pid=<n>)`
// instead of `watcher killed externally`; nothing else about the exit changes -
// same reason-line shape, same lock release, same beacon stand-down, exit 0.
// This exists because ONE template labelled EVERY TERM `killed externally`,
// which made the crewchief's own config-swap release (read the live pid, TERM
// it, `sleep 1`, re-arm a different AC_WATCH_SKIP - exactly what the refusal
// below prescribes) indistinguishable from a hostile kill, and cost two
// families four days of false investigation (2026-07-19/20).
// The marker is COOPERATIVE, not authenticated: it separates this distro's own
// release from everything else and claims nothing stronger. Three bounds keep
// it from becoming a SILENCER: it is keyed by TARGET pid (it can quiet only the
// one process it names), it is valid for 30s from its epoch (the real gap is
// the idiom's `sleep 1` plus a handler deferred to the end of the synchronous
// step in flight), and it is CONSUMED on the first signal that reads it -
// stale, unmatched or missing, the `killed externally` wording stands byte for
// byte. A release
// whose TERM cannot be delivered withdraws its own marker. Releaser and target
// share one AC_HOME by construction (the marker lives in state/).
// SCOPED TARGETS (watcher-release-scope, 2026-07-21): only the FLEET watcher is
// releasable this way. A SCOPED watcher (AC_WATCH_ONLY, armed by a roomchief)
// BELONGS to that roomchief - releasing it leaves its family with no real-time
// crash/blocked detection until the roomchief notices and re-arms. So a target
// pid recorded under a SCOPED lock (state/.watch-only-<fam>.lock.d/pid - the
// lock is the authoritative record of a watcher's target, since its suffix
// already partitions scoped watchers from the fleet one, while the arm log is
// trimmed and the beacon carries no pid) is REFUSED (exit 2, on stderr) BEFORE
// the marker is stamped, so a refused release leaves NO trace on the watcher it
// declined to touch. This is the code half of a behavior the crewchief already
// corrected: its config-swap loop read every ac-watch pid and released each,
// reaping roomchiefs' scoped watchers with the fleet one - seven re-arms in a
// single session (2026-07-21). No wake was lost (ac-done.sh publishes durably),
// but the real-time gap was real. There is no override knob: nothing in this
// distro releases a scoped watcher - teardown/demote let it exit on its own
// heartbeat - and a knob nobody needs is just the mistake with one more step.
// The refusal covers the whole UNIT, not just the watcher pid
// (watcher-release-wrapper-orphan, 2026-07-21): the harness arms a watcher
// inside a WRAPPER shell it tracks (`chain=<watcher>(bun) < <wrapper>(zsh) <
// ...`), and a release aimed at that wrapper TERM'd the tracked parent while
// the guard spared the watcher - which survived reparented to PPID=1, still
// polling but with an exit that wakes no one, the very orphan the ARMING
// CONTRACT below forbids (observed live: wrapper 67124 released, scoped watcher
// 67150 refused and orphaned). So a target pid that is the DIRECT PARENT of a
// pid under a scoped lock is refused the same way, with the same no-trace rule.
// The fleet watcher and its wrapper stay releasable.
// HOME-CROSSING TARGETS (watcher-release-crosses-home-boundaries, 2026-08-05):
// the scoped guard above stops nothing outside the caller's OWN home - a pid
// recorded under NO lock in this home's state dir fell straight through to
// `kill -TERM`, so --release could TERM a pid belonging to a DIFFERENT
// fleet's home with no check at all (real incident: an operator pattern-
// matched the process list for "a" watcher pid and released it by exact
// number; every home on the box runs the same command line, so the pid could
// have been this home's watcher or another fleet's, and it was gone before
// either could be proven). So --release now refuses ANY target that is not
// THIS home's own fleet-watcher UNIT - the pid recorded in
// state/.watch.lock.d/pid, or its direct parent (the wrapper, same unit
// as above) - REFUSED (exit 2, on stderr) BEFORE the marker is stamped, same
// no-trace rule. This home having no fleet watcher armed at all (no lock, no
// pid file, empty or non-numeric contents) refuses too - fail CLOSED, never
// fall through to the kill for want of our own record. As with the scoped
// guard, there is no override knob: nothing in this distro has any business
// releasing another home's watcher, so no caller exists to need one.
//
// Wake routing (ac-lib.sh owns the keying): a wake is filed for the CONSUMER
// that must act on it - the fleet watcher publishes to state/.wake-spool/,
// while a promoted family's watcher (AC_SCOPE=<fam>, inherited from the
// roomchief) publishes to state/.wake-spool.<fam>/, which only that roomchief
// drains. This changes only WHERE a wake is filed, never WHEN one is
// produced. A scoped watcher likewise stamps its OWN beacon,
// state/.last-watcher-beat.<fam>.
// Scope-containment reconciliation (applies to --once too, which files wakes
// just like an armed watcher): with a valid AC_SCOPE set, AC_WATCH_ONLY must
// CONTAIN AC_SCOPE. AC_WATCH_ONLY == AC_SCOPE is the single-family case;
// AC_WATCH_ONLY holding AC_SCOPE plus extra entries is an epic roomchief
// watching its in-flight story families too (their ids, from ac-ready.sh
// watch-set), so a story crewmate's pane-poll backup routes to the epic's
// spool not the fleet's (epic-roomchief-watch-only-omits-story-ids). An
// AC_WATCH_ONLY that does NOT contain AC_SCOPE is REFUSED (exit 2), since the
// family's wakes would land under a key nobody drains; and AC_WATCH_ONLY UNSET
// is DEFAULTED to AC_SCOPE. AC_WATCH_ONLY and AC_SCOPE are not equal by
// construction (AC_SCOPE is real launch env, AC_WATCH_ONLY is prompt text the
// roomchief types), and undefaulted that case watches every pane fleet-wide
// while filing every wake to one family. A malformed AC_SCOPE is exempt: it
// routes to the fleet spool, so such a watcher is a fleet watcher.
//
// Scoping (design C): AC_WATCH_ONLY=<fam1,fam2> watches only those
// families' ids (<fam> and <fam>-*; a promoted roomchief watches its own
// family this way, and an EPIC roomchief adds its in-flight story families -
// ids that share no prefix with the epic - via ac-ready.sh watch-set);
// AC_WATCH_SKIP=<fams> ignores them (the fleet watcher skips promoted
// families). Scoped watchers take their own lock.
// The <fam>-chief pane is NOT a family member: it reports to the FLEET
// (its hand-back must wake the crewchief), so family scoping excludes it
// - ONLY=<fam> never self-watches the chief, SKIP=<fam> never hides it.
// A STORY crewmate's pane matches its epic's SKIP by neither id rule (its id
// shares no prefix with the epic); the fleet matches it by the pane's meta
// fleet_scope (the epic, recorded at spawn) instead, and revalidates coverage
// against that EPIC - so a story pane the epic roomchief owns is skipped while
// the epic's scoped coverage is live and re-covered when it dies, exactly like
// an epic's own pane (behavior: epic-roomchief-watch-only-omits-story-ids).
// AC_WATCH_SKIP is REVALIDATED every poll: the skip exists ONLY because the
// family's OWN scoped watcher covers it, so a skip is honored only while that
// coverage is LIVE - the <fam>-chief is live (meta + window) AND the family
// beacon state/.last-watcher-beat.<fam> is fresh (younger than AC_GUARD_GRACE,
// the turn-end guard's own bound). A GONE roomchief (meta/window) REVOKES the
// skip that poll: the fleet watcher covers the family's panes directly and logs
// the takeover once, until the scoped watcher (or teardown) is back. This is the
// watcher-skip-staleness fix (2026-07-18: a scoped watcher died, its family
// went ZERO-covered because the fleet trusted the skip forever). RE-ARM GRACE
// (roomchief-scoped-watcher-blindness, 2026-07-19): a LIVE roomchief with a
// merely-stale beacon is almost always mid re-arm - its scoped watcher
// heartbeat-exits every AC_HEARTBEAT and STANDS ITS BEACON DOWN (below), and the
// roomchief re-arms it a turn or two later. So the fleet holds the skip through
// a grace (AC_GUARD_GRACE from when the gap opened, tracked in
// state/.skip-stale-since-<fam>) and revokes only if the beacon stays stale PAST
// it - a roomchief genuinely not re-arming. Without the grace the stand-down
// made every benign scoped exit read as instant coverage-down, so the fleet
// revoked during the NORMAL re-arm gap and stole the family's done wake to the
// fleet spool (the per-id dedup marker is shared, so a stolen marker never
// re-emits to the family spool) - the roomchief went blind to its own crewmate.
// BUSY DECLARATION (skip-grace-too-short-for-a-chief-inside-a-long-synchronous-gate,
// 2026-07-26): that grace is sized for a chief MID RE-ARM - a turn or two. A chief
// blocked inside ONE synchronous call cannot take a turn AT ALL, so it cannot
// re-arm and its beacon stays down for the whole call: ac-gate.sh waits up to
// AC_GATE_TIMEOUT (600s) against a 300s grace, so a HEALTHY chief lost its skip
// merely for being busy (measured: ~15 crewchief turns in one evening spent
// draining and silently acking a parked crewmate's wakes while its chief was
// legitimately adjudicating a second-chief round). In that window the takeover buys
// NOTHING: the roomchief is blocked and cannot act on the wake, and the crewchief
// does not own the family and may not either - so it converts a wake that would
// have reached the right owner slightly later into one that reaches the wrong owner
// and is discarded. So a blocking caller DECLARES the bounded window
// (ac_chief_busy_path, ac-wake-lib.sh - a SEPARATE signal, never the beacon, which
// asserts something else to five other consumers) and the fleet holds the skip
// while it is unexpired. This teaches the fleet to tell BUSY from DEAD; it does NOT
// widen into "a live roomchief always keeps its skip" (that is the fail-OPEN,
// unbounded shape of the 2026-07-18 defect above). REVOCATION IS UNCHANGED
// OTHERWISE and stays the safety behaviour: a GONE roomchief still revokes
// IMMEDIATELY whatever it declared, and an ABSENT or EXPIRED declaration plus a
// beacon stale past the grace still revokes exactly as before - so a family whose
// scoped coverage is genuinely down is still covered directly by the fleet.
// At ARM every
// AC_WATCH_SKIP entry is also validated to name a family of THIS home (a
// data/<fam>/ dir or a <fam>*/state meta); a foreign/unknown family is refused
// LOUDLY (exit 2), since it blinds nothing real while masking a real misconfig
// (2026-07-18: a drydock family named on the LAB singleton's skip).
//
// EXTERNAL KILLS. Something outside the fleet SIGTERMs long-idle watchers
// (10 observed on drydock 2026-07-15/16, ~10-20min apart, landing on the poll
// `sleep`); nothing in this distro sends them - a TERM that reads `killed
// externally` is one no owner marked. Two guarantees answer that:
//  - TERM/INT are HANDLED: the watcher prints ONE `signal:<NAME> pid=<n>
//    target=<t> - <reason>` line and exits cleanly, so its exit cleanup
//    releases the lock (SIGNALS below holds every disposition).
//    The poll wait is an AWAITED `sleep` child, so the handler fires where
//    the kills actually land instead of after the interval. A kill aimed only
//    at the sleep CHILD is absorbed - the loop just polls again, and the
//    watcher survives.
//    TERM is the one that carries this: an ARMED watcher is a background task,
//    and a shell backgrounding a job without job control must set SIGINT to
//    SIG_IGN in it (POSIX), so an armed watcher never sees INT at all. The INT
//    handler is for the FOREGROUND shapes (a hand-run watcher, `--once`,
//    Ctrl-C), where it releases the lock just the same.
//  - Arming logs one ATTRIBUTION line (pid + parent chain + poll target) to
//    state/.watcher-arm.log and stderr - never stdout, which carries the exit
//    reason alone - and the signal line joins it there, so the next kill is
//    attributable to a NAMED ancestor instead of a bare pid. A FAILED wake
//    publish joins it there too (`wake-publish FAILED ...`): the dedup marker
//    has already advanced by then, so the loss would otherwise be traceless -
//    the reason line still prints and wakes the chief once, only the durable
//    record is missing. The log is bounded (trimmed to AC_ARMLOG_KEEP lines).
//
// ARMING CONTRACT: the wake IS the harness's notification on this watcher's
// EXIT, so it MUST be armed as the harness's OWN background task - the harness
// runs it, tracks it, and is woken by its exit. NEVER shell-background it
// (nohup/&/disown) inside a tool call: the harness then tracks the wrapper
// (which returns instantly), the watcher is orphaned, and its exit reason wakes
// no one - silently degrading it from real-time eyes to a note found only at
// the next turn boundary.
//
// Owner gate: arming the FLEET-scoped watcher runs `ac-lock.sh acquire` -
// idempotent for the home's lock-holding session (and claims an unlocked
// home for the arming session), but a live foreign holder REFUSES the arm
// (prints `refused: ...`, exit 2). The holder pid is recorded to
// state/.watcher-owner beside the beacon. An acquire that fails any OTHER
// way (rc 1: bun missing from PATH, an unreadable lock) is no foreign owner,
// and neither is a status read that fails after a good acquire: the watcher
// arms with a WARN naming the entry and an EMPTY owner record.
// Scoped watchers (AC_WATCH_ONLY) and --once checkpoints are exempt.
//
// Singleton: state/.watch.lock.d (scoped watchers take their own suffixed
// lock). ac-lib.sh's lock block is the authoritative spec for what makes a
// lock STALE and reclaimable; both shapes an external kill leaves - a dead
// owner pid, and a dir whose pid file was never published - are reclaimed, so
// a killed watcher can never wedge the re-arm at `already running` while
// NOTHING watches the fleet (the confirmed 2026-07-16 failure). A LIVE owner
// refuses an IDENTICAL second arm (exit 0 `already running`, idempotent) - with
// ONE exception, because `already running` is a statement about NOW and a chief
// arming by hand is asking about its next TURN END. An arm ac-watch-autoarm.sh
// owns carries AC_AUTOARM and records it in its own lock dir ($lock/autoarm,
// retired with the lock): that watcher is BOUNDED - it lives in the foreground of
// one Stop-hook firing and dies with it at the budget handback - while a hand arm
// is a harness background task and is not. So a HAND FLEET arm over a marked
// incumbent REFUSES LOUDLY (exit 2) instead of reporting coverage it does not
// own, naming that pid and the single-target release; a HOOK arm over the same
// incumbent, a SCOPED arm (--release is fleet-only, and a family's panes are
// re-covered by the fleet watcher's skip revalidation), and any arm over an
// unmarked (durable) incumbent all stay idempotent `already running`.
// Measured 2026-08-06 with per-process stamps: hand arm `already running` at T+0
// with the incumbent live -> its beacon stand-down at T+2.513s -> the hook's
// budget handback at T+2.536s -> the turn-end guard blocking at T+2.602s. The
// discriminator is OWNERSHIP, never a beacon state: the incumbent is beating
// normally at arm time (behavior: rearm-stands-aside-for-a-watcher-that-then-exits).
// But a second arm carrying a DIFFERENT watch-config than the running singleton
// must WIN, never silently no-op leaving the stale config in charge: the arm
// that acquires records its AC_WATCH_SKIP to state/.watcher-config[<suffix>],
// and a second arm that finds the lock held compares configs - same config
// stays idempotent, a DIFFERING config REFUSES LOUDLY (exit 2, naming both)
// so the caller releases the stale watcher (`--release` frees its lock cleanly,
// above) and re-arms the corrected config. AC_WATCH_ONLY needs no compare here:
// the lock suffix already partitions scoped watchers onto separate locks.
// NAMED RELEASE TARGET: that refusal names the RUNNING watcher's pid (read from
// the lock dir) and prints the exact single-target command
// (`bin/ac-watch.sh --release <pid>`, the OWNER-MARKED RELEASE above - so the
// remedy and the log that release produces agree), and states that a pattern
// kill is never the mechanic. A remedy naming no target and no command is what
// drove operators to improvise `pkill -f ac-watch`
// (observed 2026-07-14/15, one of them self-reported as having reaped ANOTHER
// session's scoped watcher) - and because every home on a box runs the same
// command line, such a kill crosses home boundaries and reaps every fleet's
// watcher at once. ac-watch-policy-hook.sh denies those patterns for sessions
// rooted in THIS repo; sessions rooted elsewhere are unguarded, so this message
// is the only barrier they get.
// Liveness beacon: state/.last-watcher-beat[.<fam>] (epoch secs, refreshed
// every poll - see the scope note above); the turn-end guard treats a stale
// beacon as "watcher down". On EXIT the watcher STANDS ITS BEACON DOWN (writes
// 0 = stale), so a fresh beat can never outlive the process that made it: an
// armed watcher's exit always wakes the chief, and without the stand-down a
// just-exited heartbeat left a deceptively-fresh beacon that let the turn-end
// guard read "covered" and allowed the chief to PARK - after which no turn
// boundary recurs and the fleet goes deaf (idle-chief-deaf, 2026-07-18). Stood
// down, the guard blocks that post-exit turn and forces a re-arm. BOTH writes go
// through publishBeacon (tmp + rename): a truncate-in-place write is readable as
// an EMPTY file mid-flight, and every consumer computes `now - beat`, so an empty
// read renders the raw epoch as an age - observed live 2026-07-27 with this
// watcher beating 1s earlier. ac_watcher_beat_read (ac-wake-lib.sh) is the reader half
// and owns what each no-beat state means.
//
// PUSH CHANNEL (agent-done-push). The watcher is the BACKUP; a finished agent
// announces itself (bin/ac-done.sh; src/done.ts owns the push contract) and the chief
// wakes in tens of milliseconds instead of at the next tick. The agent PUBLISHES
// its record into this scope's spool and then kills this watcher's poll `sleep`
// CHILD - behavior pollWait already documents (a kill aimed at the sleep
// alone is absorbed), used here, not built. Ending the wait alone
// would only poll SOONER, and a wake IS this watcher's EXIT, so a record in the
// spool is an exit condition in its own right: the check sits at the TOP of the
// cycle (before the beacon and the poll pass) so a nudged watcher exits at once
// without paying for a pane pass, and exits `push:<id>`. The FLEET watcher also
// answers for an ORPHANED family's spool (its roomchief gone, so no scoped
// watcher exists to nudge - the fleet drains it, ac_wake_orphan_files): such a
// push is met at the next poll tick, the backup tick ac-done.sh names, while a
// LIVE family's push stays its own chief's. The two hazards that
// creates are closed here:
//  - RE-ARM SPIN. A chief re-arms while a record it has not drained is still in
//    the spool. That record is NOT news to a fresh watcher, and exiting on it
//    would exit instantly, forever. So the arm SNAPSHOTS the record names it
//    finds and only a name outside that snapshot is a push (records are named
//    once and never renamed in place - ac-lib.sh's store contract - so the
//    snapshot cannot go stale under a live watcher). A `--once` checkpoint
//    snapshots the same way, so a record already in the spool when it starts
//    never reports a push: its caller drains.
//  - DOUBLE-PUBLISH. The pane carries the same completion, so the poll that
//    follows a push would read the marker and publish a SECOND record. The
//    EXISTING dedup markers absorb it, with no new state file: ac-done.sh
//    stamps .seen-<id> with the marker text (markerSeen below also accepts the
//    pane's TUI-glyph rendering of that same line, which the agent cannot know
//    to include) and REMOVES .seen-hash-<id>, whose absence the re-wake branch
//    reads as PUSH ADOPT - the wake for this marker came from the other channel,
//    so the first non-busy poll anchors the pane hash SILENTLY instead of
//    treating a missing discriminator as movement. The re-wake channel is
//    anchored by that, never disabled: a pane that does new work and re-prints
//    the marker still wakes.
//    Dedup alone is not enough, because the `seen` read is STALE by the time
//    the branch publishes - the status append and a BACKEND call sit between
//    them, tens of ms in which the agent can announce the same completion, and
//    a push landing THERE produced two records. So the branch RE-READS the
//    stamp immediately before publishing and stands down when it is no longer
//    its own write and still covers the marker. That is sound because
//    ac-done.sh stamps BEFORE it publishes: a foreign stamp means the record
//    exists or is one syscall away. RESIDUAL, stated rather than hidden: a push
//    that stamps between that re-read and our own `ln` still duplicates - a few
//    syscalls wide instead of a backend round trip. Exactly-once across two
//    lock-free producers needs an atomic test-and-set the wake store does not
//    offer (its `ln` is keyed by producer-unique name, not by completion), and
//    a duplicate wake costs the chief one drained line while a LOST one costs a
//    stranded crewmate - so the trade is deliberate in that direction.
//  - DOUBLE-PUBLISH, ARTIFACT ARM. An agent that finishes writes its report.md
//    too, and that third stamp (.report-hash-<id>) has no agent-side twin: a
//    crewmate has no AC_HOME (ac-spawn.sh strips it), so ac-done.sh cannot even
//    resolve where report.md lives. The EXIT closes it instead - pushAdoptReport
//    below anchors the hash to the report as it stands at the moment of the push
//    exit, so the completion the chief is about to drain does not wake it a
//    second time off the artifact channel one poll later. Same shape as the pane
//    adopt, same direction of failure: an unanchored push (no watcher armed to
//    exit) still wakes twice rather than risking a lost wake.
// Nothing else in the wait loop changes: with no push, the poll interval and
// every existing exit behave exactly as they did.
// ROLLOUT: the push channel lives in the watcher PROCESS, so a watcher armed
// BEFORE this change has neither the loop-top check nor markerSeen. Such a
// watcher exits `report:<id>` off the pane and, comparing markers byte-exactly,
// files its own record beside the pushed one - two records for one completion,
// and .seen-<id> overwritten with the captured line (observed live 2026-07-20,
// and expected: nothing was wrong with the push, the process simply predates
// it). Nothing is LOST in that state; re-arming the watcher on this code is the
// whole remedy.
//
// IDLE MODE (standing remote coverage): zero crew in flight is NOT an exit
// condition. With the remote slot live (interval on, executable
// config/remote-poll hook, and this watcher passing the lock gate below),
// an idle fleet watcher stays up - beating the liveness beacon and running
// the remote poll slot on its interval, absorbing nothing else - so remote
// orders keep flowing while the fleet is parked; a new order exits
// `remote:<rid>` exactly as with crew in flight, and a crewmate spawned
// mid-idle is picked up on the next pass. Zero crew with no remote slot
// idles the same loop with nothing to do (unchanged). Either way
// AC_HEARTBEAT still bounds the loop (exit `heartbeat`); the turn-end
// guard's standing-coverage rule (ac-turnend-guard.sh) is what keeps a
// watcher armed over an idle remote-wired fleet.
//
// STALE-STAMP SUPERSESSION (send-guards-own-marker-verbs). DEMONSTRATED LATER
// PROGRESS SUPERSEDES AN UNANSWERED MARKER. A captain-wait marker writes a
// DURABLE state/<id>.status line and every fleet view renders the NEWEST one
// (ac-fleets.sh, ac-crew-state.sh), so a crewmate that is demonstrably WORKING
// kept reporting `blocked` in every view until a human steered it - and the
// marker that parked it can be one the pane never meant (a chief's own steer
// text, the write-side guard's case at ac-send.sh). Fixing it HERE, at the
// source, makes every renderer and the herdr UI stamp correct at once with no
// renderer change - ac-fleets.sh must stay probe-free, so it cannot decide this
// itself. The EVIDENCE is disk + tail, both already in hand each poll: the pane
// matches AC_BUSY_RE while this fleet's own stamp file (state/.captain-wait-<id>,
// ac-backend.sh's CAPTAIN-WAIT STAMP) still stands - a genuinely parked pane has
// ended its turn and matches no busy pattern. On that evidence the watcher
// appends a superseding status line (`working: superseded <marker>`, which
// matches no AC_CAPTAIN_RE itself) and releases the stamp. NO wake: the chief is
// told nothing new. The stamp file's own removal is the once-only guard.
// It FAILS TOWARD KEEPING THE STAMP - no evidence of progress (watcher down,
// pane quiet, marker scrolled out) leaves the marker standing, because a false
// `superseded` hides a real captain-wait, the worse error.
// OSCILLATION, the subtle half: the Reconcile branch below re-stamps an
// already-seen captain-wait marker still sitting in the tail the moment the pane
// reads non-busy, which would re-park the pane supersession had just freed. So
// the superseded marker TEXT is recorded durably (state/.superseded-<id>) and
// Reconcile skips a match. That record covers ONE marker, never the pane: a NEW
// marker clears it and parks the pane again. RESIDUAL: a pane that re-prints a
// BYTE-IDENTICAL captain-wait marker after real work is not re-stamped (the
// marker is not new), but it still wakes the chief through MARKER RE-WAKE below
// - the wake, not the stamp, is what the chief acts on.
//
// MARKER RE-WAKE (watch-marker-rewake). A pane that re-announces the SAME
// marker string is deduped by state/.seen-<id> - but only while the pane has
// stood still. Re-announcing it AFTER doing new work is new news, and it is the
// shape of every gate loop past round 1: the crewmate revises and prints a
// byte-identical `done:`, which the raw .seen-<id> dedup swallowed until the
// next turn boundary. The discriminator is the pane-tail hash recorded AT THE
// MOMENT OF THE WAKE (state/.seen-hash-<id>, written wherever the marker branch
// queues its wake): differs from the current tail hash and the pane is not busy
// (AC_BUSY_RE) => the pane demonstrably moved since the chief was told, so it
// wakes again. Cost is that one state file - no extra capture, no backend call.
// .seen-<id> semantics are unchanged, and the AC_DECISION_RE re-stamp reconcile
// still wins the pass it fires on (a re-wake follows on the next poll if the
// pane keeps moving).
// BACKGROUND DEFER (paused-rewake-on-moving-pane): a turn that ENDED with a
// background agent, shell or monitor still running reads not busy, yet its tail keeps
// moving (subagent progress, completion notices) under the very marker the chief
// was already told - observed live as a `paused:` re-wake every 10-60 s, each one
// a turn in the supervising chief's pane. So the re-wake also waits while the
// LAST claude turn-summary line (`✻ ...`) in the tail says work is still running
// (BACKGROUND_RE). Only the last one: claude prints one per turn end and the
// earlier ones stay in scrollback, so a stale `Waiting for ...` line must not
// mute a pane forever. A deferred pass stamps nothing, so the first poll after a
// turn ends clean still wakes once if the pane moved - deferred, never dropped.
// A harness that prints no such line is bit-for-bit the behavior above.
// RESIDUAL: a background shell that finishes without claude opening a new turn
// keeps the re-wake deferred until the next turn summary.
//
// ARTIFACT CHANNEL (watch-artifact-wake). A stage's report.md is a completion
// in its own right, so it wakes the chief with NO pane cooperation at all: a
// scout that printed no marker, or one whose marker was deduped or consumed by
// another watcher, is detected within a poll instead of at the next turn
// boundary (which is all ac-wake-drain.sh's completion report can do - that
// PULL half stays exactly as it is, this is the PUSH half). The report path is
// ac_task_dir's, so the flat/nested layout stays ac-brief.sh's contract and is
// never guessed here; a task whose data dir is ambiguous is simply not
// reported. Dedup is by CONTENT hash (state/.report-hash-<id>, the artifact
// twin of the pane tail's .hash-<id>), never mtime: a touched-but-identical
// report is not new work, while a revision that rewrites it wakes again. That
// hash has a second writer - the push exit anchors it (the PUSH CHANNEL's
// artifact arm above), so a completion announced on BOTH channels wakes once. It
// files through queueWake like every other wake (kind `report`, payload
// naming the file), so scope routing is unchanged. PLACEMENT: it sits between
// the marker branch and the stale branch, and the marker branch FALLS THROUGH
// to it instead of `continue`ing - a marker that was already seen must not
// suppress the artifact, which is the whole point of a second channel.
// BUSY GUARD (watch-artifact-wake-debounce), the one thing standing between
// "a revision wakes again" and a WAKE STORM. That sentence assumed a revision
// is ONE atomic rewrite; a real agent revising a long report writes it MANY
// times, and every write is a new content hash. Measured on the live case that
// named this behavior: 174 write-ops to one design report.md, 57 of them inside
// the 25-minute window in which the chief's watcher re-armed ~15 times - at a
// 15s poll the report changed on essentially every poll, so the chief paid a
// drain, a re-arm and a turn PER EDIT, every one a no-op with the scout
// mid-sentence. The dedup was never at fault (held-constant repro: a byte-stable
// report over 5 polls wakes 0 times, 5 rewrites wake 5 times), and neither was
// the fleet/scoped double-watch (.report-hash-<id> hangs off ac_state_dir, which
// is scope-INDEPENDENT, so both watchers share it and one advance still wakes
// exactly once - only WHICH spool it lands in is a race, the pre-existing
// wake-steal the AC_WATCH_SKIP revalidation above already documents).
// The discriminator is the one the three sibling branches already use, at no new
// cost: a report only ever changes while an agent is WRITING it, so a pane
// matching AC_BUSY_RE is writing the very file we would wake the chief to read,
// and the pane channel already covers a live agent. While the tail reads busy
// the artifact wake is DEFERRED and the pass stamps NOTHING - the same discipline
// as SUPERVISING-CHIEF QUIET below ("a suppressed pass touches NO .stale-<id>") -
// so the first quiet poll wakes ONCE, carrying the report as it FINALLY stands.
// A revision round therefore costs one wake instead of one per edit.
// It FAILS TOWARD WAKING, which is the direction this whole channel is built to
// fail in: the appear-case this channel EXISTS for - a scout that crashed or
// finished without printing a marker - leaves a SILENT pane and wakes on the very
// next poll, unchanged; and a harness whose tail carries no busy marker at all
// is bit-for-bit today's behavior. RESIDUAL, stated rather than hidden: a pane
// that reads busy forever never earns its artifact wake. That is not new - the
// MARKER RE-WAKE and stale branches carry the identical residual under the
// identical predicate - and a pane that is busy forever is a live agent, which
// is precisely what the pane channel supervises.
//
// BUSY-STALL BOUND (code-reviewer-plugin-has-no-self-timeout). The quiet arms below
// all read a pane that has gone QUIET; a pane hung INSIDE one tool call is the
// opposite and was invisible to every one of them. Its harness keeps rendering
// the busy footer, so AC_BUSY_RE reads busy=1 and BOTH the artifact channel and
// the stale/ended arm are gated off, while a footer that renders an elapsed
// counter also rewrites the tail hash every poll, resetting .change-<id> and
// clearing .stale-<id>. Two independent guards, each alone enough to make the
// fleet read a hung crewmate as healthy - the live case was a delegated code
// reviewer that returned neither findings nor an error for over an hour and
// stopped only when a human noticed. So a busy RUN past AC_BUSY_MAX seconds
// (default 2700, 0 disables) wakes on the existing `stale` reason with its own
// message. The SAME bound the verifier arm already has (AC_PANE_STALL_MAX,
// src/pane-agent.ts), reached with the data this watcher already holds, because
// this watcher reads no transcript and a transcript-shaped bound would cover only
// the harnesses that write one.
//
// The clock is a run stamp written on the busy 0->1 edge, never .change-<id>:
// defeating the footer guard alone still leaves the hash guard free to reset the
// clock forever. It fires ONCE per run (.busy-stalled-<id>, the silent-anchor
// discipline of the branches around it), and both files clear when the pane goes
// non-busy, so the next run is bounded afresh.
//
// The one suppression is an UNEXPIRED busy declaration (chiefBusyDeclared):
// ac-verify.sh and ac-gate.sh write it before entering one bounded synchronous
// call of up to AC_VERIFY_TIMEOUT, well past this bound, so a roomchief in a
// review round - and a crewmate running crew-verify - is legitimately blocked,
// not stalled. It is bounded by construction and expires on its own. The two
// CHIEF-QUIET predicates guarding the stale arm are deliberately NOT applied:
// they exist to keep a QUIET supervising chief quiet, and a chief hung inside a
// call is the case this arm exists to surface. Fail direction, chosen once and
// stated: one extra wake per busy run, never silence.
//
// ENDED-TURN LOUD WAKE (watch-idle-loud-wake). A pane past AC_STALE with no
// marker is TWO different situations, and one stale: signal for both is why
// chiefs learn to discount it: a pane merely quiet while WORKING (soft news,
// keeps stale:) versus a pane that ENDED ITS TURN (it is done talking and
// waiting on the chief, with nothing AC_CAPTAIN_RE can see - the live case was
// an implement crewmate raising a real chief decision as PROSE inside a long
// summary, twice, looking exactly like a crewmate working). The discriminator
// is the backend's own agent status, the same field the ask path already reads
// (backend_agent_idle, herdr's idle|working|blocked|unknown - only `idle` is an
// ended turn), so it costs one backend call per stale episode. An ended turn
// exits `ended:<id>` instead of `stale:` and stamps the pane BLOCKED through the
// advisory backend_mark_wait path the marker branch uses (a stamp failure never
// blocks the wake). Everything else is bit-for-bit today's behavior: the reader
// FAILS CLOSED (unreadable pane, missing handle, any non-idle status => stale:),
// the .stale-<id> dedup marker and BOTH chief suppressions (ac_chief_gate_parked
// and SUPERVISING-CHIEF QUIET below) cover both paths, and a busy pane never
// reaches either. So this is a CREWMATE net: a chief supervising a live crewmate
// is quiet on this arm too, and SUPERVISING-CHIEF QUIET argues why.
//
// USAGE LIMIT. An ended turn whose pane tail carries claude's provider
// usage-limit line (`You've hit your weekly limit · resets 10pm (<tz>)`, the
// exact line a drydock agent stopped on 2026-09-20) is not waiting on the
// chief: steering it only spends another refused turn, and it can do nothing
// until the reset. It exits `limited:<id>` with that line as the payload
// instead of `ended:`, under the same dedup and suppressions. The match is the
// error's own `limit · ` shape, so the words in an agent's prose never trip it.
// A codex pane states its limit in its own sentences (codex-cli 0.160.0's
// strings: `You’ve hit your usage limit.`, `Selected model is at capacity.`,
// `You hit your spend cap`, `is out of credits.`, `Quota exceeded. Check your
// plan`); they carry no `·`, so they count only on a pane whose meta says
// harness=codex. EXPIRED LOGIN is the same arm's sibling: claude's `<cause> ·
// Please run /login` / `· Sign in again` / `· Fix external API key` shapes
// (2.1.293), or on a codex pane its refresh-token and session-expired
// sentences, exit `needs-login:<id>` - waiting is no cure there, only the
// captain signing that harness in again.
//
// COMPLETION ALREADY REPORTED (stale-signal-costs-a-hard-wake). The one ended
// turn that goes QUIET, not loud: a pane whose .seen-<id> holds an already-
// reported chief-facing completion (done/failed/paused/merged - an AC_CAPTAIN_RE
// match that is NOT a captain-wait marker). Its report: wake fired when the
// marker was fresh; the marker has merely scrolled past the bounded 25-line tail,
// so the pane now reads as a bare ended turn. Re-firing ended: there is the bug
// this closes - .stale-<id> is cleared by every cosmetic TUI redraw, so the loud
// wake re-armed every quiet window forever. Such a pane is anchored SILENTLY
// (touch .stale-<id> + a status note, no wake), the same once-only shape as the
// push-channel anchor. The memory is DROPPED the moment the pane is seen BUSY
// again (a re-task busies it, and once its completion marker has also scrolled
// out the .seen-<id> is cleared), which re-arms the loud net for genuinely-new
// prose-only work. Completion-class ONLY: a captain-wait marker parks the pane
// BLOCKED and is handled by the ask path, never here.
//
// JEV NOTE (the System One net, config/jev). On the two quiet-arm wakes -
// the loud ended: and the soft stale: - and ONLY there, the watcher asks
// bin/ac-jev.sh the compact-adviser `done` question over the bounded pane
// tail plus the task's last status line, and appends ` jev=<choice> p=<p>`
// to the wake PAYLOAD when the knob is `on`. The exit-reason token, the
// status-log note (declaredWait reads it), the dedup markers and the
// BLOCKED stamp are untouched, so every consumer of the reason line is
// unchanged; only the drained record and the inbox show the note. Absent or
// off is byte-identical (the adapter prints nothing and makes no request);
// shadow logs the answer for the captain's agreement read and shows nothing;
// a failed answer is one `jev:` line in the arm log and today's payload.
// The call sits past the deferral reads and the dedup marker, so it costs
// one bounded request per quiet EPISODE and nothing while a pane is healthy
// or busy. It is a net under the marker channel, never a replacement for
// AC_CAPTAIN_RE or the ac-done.sh push - the agent's own word stays primary.
// COMPACT NOTE rides the same two wakes: when the task meta names a claude
// session_id, bin/ac-compact-advise.sh judges that crewmate's own transcript
// (its header owns the questions, score, floor and knob) and a ready verdict
// appends ` compact=advise score=<s> floor=<f> usage=<u>` - a hint for the
// chief, who may `ac-send.sh <id> /compact`; the watcher never sends it.
// STALE DEFERRAL (watch-stale-defer-on-declared-wait). The stale arm measured
// idle time alone, and its one dedup (.stale-<id>) is cleared by any cosmetic
// redraw - so a worker that had SAID why it is quiet, or one parked at a gate on
// the captain, was re-reported stale every AC_STALE window. On the branch about
// to emit stale: (never the healthy path, which pays nothing, and never ended:),
// the worker's word is read first, in two forms (declaredWait owns the reads):
//  - DECLARED WAIT: the LAST line of state/<id>.status (the line ac-crew-state.sh
//    reports) is a captain-wait marker (AC_DECISION_RE: needs-decision:,
//    blocked:, checks-passed:) or `paused:` - the AC_CAPTAIN_RE verbs that mean
//    "stopped on purpose"; `done:` is NOT a wait (it waits on the chief's reap,
//    which the stale wake exists to prompt), and this watcher's OWN wait-shaped
//    notes (WATCH_ASK_NOTE, WATCH_ENDED_NOTE) are its verdicts, not the worker's
//    word, so they never defer.
//  - GATE PARKED: the line explains nothing, but the latest review findings file
//    (the family's newest verify/codereview round, or the crew-ship run's
//    findings/review.json - newest mtime wins) holds a finding whose `action`
//    is exactly `ask-user` with no recorded `decision`, read by jq KEY - a
//    description or branch name that merely contains the word parks nothing.
//    LIMITATION, stated: the room is NOT consulted. The ship pipeline records the
//    captain's decision ON the finding (bin/ac-ship.sh finish contract), so that
//    pairing is by key; a verify round's findings.json carries no decision field
//    and the room grammar has no finding-id token, so a decided-but-not-yet-
//    re-reviewed verify ask-user keeps deferring until the next round's file
//    replaces it - bounded by the restart rule below, never a cancellation.
// A deferral RESTARTS the idle clock (.change-<id>, the stamp the arm measures
// from - not merely .stale-<id>) and logs `deferred-stale:<id> <reason>` to the
// arm log, ONCE per declaration (.deferred-<id> holds the key: the status line
// plus the log's byte size, or the findings path plus its content hash). The
// SAME declaration a full AC_STALE window later falls through to today's stale:
// - the declaration itself went stale - and a NEW one defers again. The
// declaration outranks the liveness verdict because it is what the worker said
// about its own silence; it never outranks the clock twice.
//
// SUPERVISING-CHIEF QUIET (watch-chief-child-quiet). `stale` is documented as
// the SOFT signal, but a wake IS this watcher's EXIT - so a merely-quiet pane
// terminates it exactly like report:/gone:/ask: do and costs the chief the full
// hard-wake cycle: drain, peek, ack, RE-ARM. On a <fam>-chief quiet BECAUSE its
// own crewmate is working, that cycle buys nothing - supervising is the one
// thing a roomchief is supposed to be doing while a family task flies, and the
// crewchief paid this churn every few minutes for a whole session on chief panes
// doing exactly what they should. So a <fam>-chief with at least one LIVE family
// task (ac_chief_child_live: a meta other than its own chief pane whose
// membership is decided AUTHORITATIVELY and never by an id prefix - ac-lib.sh's
// CHIEF-QUIET block owns that rule - and whose backend window is alive, the same
// pair ac_roomchief_live reads for the chief itself) produces NO WAKE ON THIS
// ARM AT ALL - neither stale: nor ended:.
// It is ac_chief_gate_parked's TWIN, at the same rung: that one suppresses a
// chief parked at the CAPTAIN (unanswered GATE:/ASK:), this one a chief parked
// at its CREWMATE, and both answer a LIVE question, not a remembered marker.
// THE RE-TRIP is why the live-state form is required and not merely tidy: the
// .stale-<id> dedup marker is removed by ANY pane-content change, and a
// supervising chief produces content between waits (its own turn output), so the
// marker cleared and the IDENTICAL non-news re-tripped on the next quiet window
// - acking it never settled it. A predicate re-asked every poll has nothing to
// re-trip: no wake is emitted, so there is no dedup for a pane change to undo.
// BOTH ARMS, and this REVERSES watch-idle-loud-wake's original "`ended:` stays
// loud however busy the family is" (ended-wake-refires-on-a-prose-reporting-
// chief). What the reversal closes is a RULE CONFLICT, not a missing case: the
// roomchief charter injected into every chief prompt (the bin/ac-spawn.sh
// roomchief prompt) ORDERS the chief to keep AC_CAPTAIN_RE marker verbs out of
// its room and pane prose, while the ONE quiet path an ended turn had -
// COMPLETION ALREADY REPORTED above - REQUIRES exactly such a marker in
// .seen-<id>. A chief that OBEYS its charter has no .seen-<id> at all, so it
// never qualified; and .stale-<id> is cleared by any pane change, the chief's OWN
// ack output included. So the loud wake re-armed every AC_STALE window for the
// whole life of the family - the same churn the stale arm above was narrowed for,
// every one a full hard-wake cycle with nothing to act on - and obeying the
// charter was what GUARANTEED it.
// Hence ac_chief_child_live sits at ac_chief_gate_parked's rung, guarding it.
// BOTH predicates are SHARED, defined in ac-lib.sh's CHIEF-QUIET block, because
// the wake this arm declines is also a notice ac-wake-drain.sh's idle fallback
// would otherwise resurrect from the .change-<id> stamp THIS watcher wrote (that
// block owns the second consumer's reasoning).
// Deliberately narrow otherwise:
//  - The CREWMATE net the loud wake was BUILT for is UNTOUCHED. Its live case is
//    a crewmate pane (an implement crewmate raising a real chief decision as
//    PROSE inside a long summary), and ac_chief_child_live returns false for
//    every non-chief id, so a crewmate still wakes loudly at the DEFAULT
//    threshold.
//    The asymmetry that justifies the split: a CREWMATE's pane is its ONLY
//    channel to its chief, while a ROOMCHIEF's are DURABLE by charter - it
//    reports back with ac-room.sh handback, which posts the room record AND
//    queues a durable wake (bin/ac-spawn.sh roomchief prompt, "never rely on a pane line
//    alone") - and a captain-facing GATE:/ASK: is the room's, already covered by
//    ac_chief_gate_parked.
//  - RESIDUAL, stated rather than hidden: a chief that ends its turn on a
//    prose-only ask for the CREWCHIEF while its own crewmate still flies is
//    DEFERRED, not swallowed. The suppressed pass stamps nothing, so the first
//    poll after the family stops flying wakes it - loudly, if it is still idle.
//    Its durable channel is the one to use meanwhile, which is what the charter
//    already tells it.
//  - Non-chief ids never reach it (the *-chief case gate returns first), and
//    report:/gone:/ask:/push:/heartbeat, AC_STALE itself and the busy guard are
//    untouched.
//  - It FAILS TOWARD WAKING, on both arms. A suppressed pass touches NO
//    .stale-<id>, so the first poll after the last family task dies emits
//    ended:/stale: with nothing consumed; and a child whose window cannot be
//    probed reads NOT live, which is the direction ac_roomchief_live already
//    fails in.
//
// Render-wrap hazard: a marker token that appears in PROSE/narrative (not as a
// real status line) can soft-wrap to visual column 0 and false-match
// AC_CAPTAIN_RE - the mitigation is author discipline (the marker-verb rule in
// CREWMATE.md and the roomchief charter), which complements the REAL-marker-wrap
// Residual note at ac-lib.sh (AC_CAPTAIN_RE definition) rather than duplicating it.
//
// Remote-order slot: on the poll interval the loop runs `ac-remote.sh poll`
// (poll queues the wakes durably itself for every order it ingests - see FAILED
// POLL for the one that does not; the watcher then exits
// `remote:<first-rid>` so the chief drains at once). Interval resolution:
// AC_REMOTE_POLL env > config/remote-poll-interval > 300; the 300 default
// applies only when an executable config/remote-poll hook exists - no
// transport, no slot - and a non-numeric or 0 value at any layer turns the
// slot off. LOCK GATE (one poller fleet-wide): the slot runs
// ONLY in the fleet-scoped watcher (no AC_WATCH_ONLY) whose recorded owner
// (state/.watcher-owner) IS the session-lock holder (state/.session-lock
// pid=); scoped roomchief watchers and foreign-lock homes NEVER poll.
// --once runs at most one poll (same gate), after a quiet pane pass.
// FAILED POLL (poll-or-true-swallows-a-failed-ingest). `ac-remote.sh poll` exits
// non-zero when it DIED, the usual cause being that ingest_stream could not
// publish a wake for an rid: it rolls that stash back, dies, and drops every
// later line on the same stdin UNREAD - which is why its own message tells the
// operator to re-send that rid and everything after it. Not the only cause,
// which is why the status alone is never the whole diagnosis: ingest_stream has
// a second ac_die whose remedy is the opposite (a stash that SURVIVED a failed
// publish now blocks every re-delivery of that rid - remove it, then re-send),
// and under errexit the poll can also die before reading anything. Only the
// producer knows which, so its own last stderr line is forwarded verbatim in the
// wake rather than guessed at here. A failing transport HOOK is none of these:
// it is warned and swallowed there, a designed QUIET poll that exits 0.
// Reading stdout alone made the death invisible in both its shapes - nothing
// printed yet read as a quiet poll, and a mid-batch death read as a NORMAL one,
// a success report over the orders just dropped. The status is now read, and the
// death gets the same two channels every other actionable event here gets: a
// durable `remote-failed` wake (id `captain`, as the orders' own wakes are) and
// the exit reason line above - which a death carries whether or not it ingested
// anything first, since the watcher exits on that path either way and naming the
// last rid that landed costs no extra wake.
// ONE DURABLE WAKE PER EPISODE, the same mark-then-wake latch shape as the pane
// branches and for the UNOBSERVABLE reason - state/.remote-poll-failed stands
// while the fault does, so a persistent fault (an unwritable spool) costs the
// arm log a line per interval instead of the chief a wake record per interval,
// and the first poll that COMPLETES clears it and re-arms the loud channel. KEEP
// POLLING: a death never exits the loop except through its own reason line, and
// the orders a failed poll DID ingest keep their own wakes, published before it.
// RESIDUAL, stated rather than hidden: the fault that kills the poll is often
// the fault that kills the wake (an unwritable spool reaches both), and then the
// durable half is lost - queueWake's own contract below governs that case, so
// the loss is logged loudly and the reason line still carries the death.
//
// HUNG POLL (a-hung-transport-hook-wedges-the-whole-watcher-loop). A poll that
// DIES gets the two channels above; a poll that NEVER RETURNS used to get
// nothing at all. checkRemote sits between the beacon at the top of this loop
// and the poll wait at the bottom, so everything that proves this watcher alive
// is either before it (and stops being refreshed) or after it (and never runs):
// a wedged transport froze the whole loop in silence, and the only thing anyone
// eventually saw was the beacon ageing past AC_GUARD_GRACE - reported as
// WATCHER-DOWN, the exact opposite of the truth about a watcher that is alive
// and blocked.
// THE CEILING IS THE DISTRO'S, and that is the point: config/remote-poll is the
// captain's own transport, a file this distro neither ships nor tests, so a home
// whose hook is a python script or a curl without --max-time carries no bound at
// all. AC_REMOTE_POLL_TIMEOUT env > config/remote-poll-timeout > 120s
// (remotePollTimeout). The arithmetic behind 120, measured on this fleet's own
// hook and host: a HEALTHY poll costs ~0.42s per API call over 1 + live-families
// + min(roomless,10) calls - ~6s today, ~13s at twenty live families - while the
// pathological case is 15s per call, a 36x spread that leaves a constant plenty
// of room. The upper limit is the beacon gap, which must stay under
// AC_GUARD_GRACE (300s) or the turn-end guard blocks the chief's turn demanding
// it arm a watcher that is already running: remote ceiling + pane pass + AC_POLL
// < 300. BOTH TERMS CAN BLOW IN ONE ITERATION and the SUM is what the grace has
// to hold - the beacon is published at the top of the loop, checkFleet and
// checkRemote both run before the next one, and a pane pass that finds nothing
// actionable falls straight through to the remote gate. The pane pass is bounded
// by herdr_rpc_timeout (ac-backend.sh, 2s per RPC) times the RPCs a wedged pass
// spends, which is what the pass costs when every pane has already latched its
// outage: 2 per pane (window_alive's deliberate two-call ladder, and its
// `continue` lands before capture), and 4 per meta of a SKIPPED family - the
// coverage probe on the chief pane plus the crewmate pane's own - both counts
// measured against a stub that answers nothing, not derived. It was 6 until
// skipCoverageLive started REPORTING which half of the coverage test failed:
// the caller's re-probe was asking the backend the same question about the same
// chief pane a second time in one pass. So the inequality is
// R x ceiling + 120 + 15 < 300, i.e. R < 82 timed-out RPCs at the 2s default:
// the distro's own shape (room-parallel 5, a couple of panes a family) spends
// ~50 and holds at 235s (50 x 2 + 120 + 15), and a fleet past that lowers
// config/herdr-rpc-timeout rather than discovering the gap as a false
// WATCHER-DOWN. Against the LIVE test stub the same dedup reads 5 -> 4 chief-
// pane calls, because window_alive's ladder short-circuits at one call when
// the pane answers; the two counts are the same fix priced on two backends.
// WHAT A KILL COSTS is a property of the TRANSPORT, not of this distro, so this
// header claims only what it owns: the rids ac-remote.sh had already stashed AND
// published keep their own wakes, and the ceiling costs those nothing. Everything
// the poll had NOT yet handed over is the hook's business - cmd_poll reads the
// hook's whole stdout before ingesting a single line, so a hook that advances its
// own read cursor as it EMITS loses what the kill interrupts, while one that
// commits only at the end re-delivers the lot next interval (the shipped Slack
// example is the latter - commit_pending in docs/examples/slack-remote/
// remote-poll). A transport that cannot be re-read is one whose fleet must size
// config/remote-poll-timeout for its own worst poll.
// RESIDUAL THIS BOUND CREATES, named because it is new: ingest_stream commits an
// order in two steps, the stash then its wake, and says of the gap "A death
// BETWEEN the two is not covered and cannot be from here" (src/remote.ts).
// A ceiling kill CAN now be from here. One landing in that gap leaves a stash
// with no wake, and the stash is also the dedup sign, so that rid is silently
// burned. The gap is ~5 ms per rid - MEASURED on this host, one date(1) spawn
// between that stash's link(2) and the wake's own durable link inside the
// wakePublish twin (src/lib.ts) - against a ceiling of seconds, and what it replaces is a watcher wedged for
// ever - but closing it belongs to ingest_stream's own commit ordering, not to
// this bound.
// SIZING THE KNOB: keep ceiling + the bounded pane pass + AC_POLL under
// AC_GUARD_GRACE - the pane pass is a term in that sum, not the `~0` it once
// was, and the arithmetic above spends it. Above the grace a
// wedged poll re-opens the very beacon gap the guard reads, and the chief is
// blocked at its turn end to arm a watcher that is already running - the exact
// false report this bound exists to kill. Deliberately NOT clamped: serving a
// value the captain did not write is the other half of that same defect.
// THE REAP IS THE PROCESS GROUP, not the pid: a kill aimed at ac-remote.sh alone
// leaves the hook and its curl children alive under ppid=1 (measured), so the
// poll is spawned detached as its own group leader and the kill is TERM,
// grace, KILL over the negative pid. checkRemote reaps on every path it
// returns through and onSignal reaps the one path that skips them all,
// naming on its way out the last rid that poll had ingested - the ceiling path
// already did, and a signal can land at ANY moment, including inside the
// stash-then-wake gap above. It gets no ceiling of its own: the reap it shares
// with the ceiling path is the same bounded TERM-grace-KILL, and a handler
// is the wrong place for a third copy - it runs on the way out, with the exit
// cleanup that releases the lock behind it.
// ONE DURABLE WAKE PER EPISODE here too, on its OWN latch
// (state/.remote-poll-timeout): a wedged transport and an unwritable spool are
// different faults with different remedies, and one shared latch would leave
// whichever arrived second silent for as long as the first stood. A poll that
// COMPLETES clears both.
//
// Knobs: AC_POLL=15 AC_HEARTBEAT=600 AC_STALE=240 AC_BUSY_MAX=2700 AC_REMOTE_POLL
// AC_REMOTE_POLL_TIMEOUT=120 (one poll's ceiling; see HUNG POLL)
// AC_CAPTAIN_RE AC_BUSY_RE AC_ARMLOG_KEEP=200 (arm-log trim floor;
// AC_LOCK_STALE_GRACE=5 is ac-lib.sh's, and governs the reclaim above)
// AC_CAPTAIN_RE (env-overridable; default defined in ac-lib.sh, which is the
// authoritative spec for its shape): the default anchors status markers
// (done/needs-decision/blocked/failed/paused/merged/checks-passed) to the line
// START, tolerating only leading whitespace and TUI glyphs - a pane merely
// DISPLAYING code or docs that contain "done:" (quoted strings, printf lines,
// comment leaders, markdown bullets/code spans) does NOT wake. It is fully
// anchored: the retired bare phrase markers are gone (see ac-lib.sh).
//
// SIGNALS. TERM - and INT, unless the process started with it ignored - run
// onSignal: the poll `sleep` killed, a remote poll in flight reaped by group
// (its capture read first for the last rid it ingested, then dropped), the
// owner-release marker consumed, ONE `signal:<NAME> ...` reason line, exit 0
// with an armed run's exit cleanup (beacon stood down to 0, the watch-config
// removed, the lock released). HUP, USR1, USR2, ALRM, PIPE, XCPU and VTALRM
// run the same exit cleanup and then die of the signal re-raised (128+n), with
// NO reason line (W6) - exit 128+n should the default disposition not end the
// process; QUIT, PROF, KILL and STOP keep their default - no cleanup, the lock
// left to the dead-pid reclaim. A signal of the first two groups the process
// started with ignored stays ignored, as the original could not trap it: each
// disposition is read through sigaction(2) before any listener exists - Bun
// takes a signal back the moment one is added, even one inherited as ignored -
// and no handler is registered for an ignored one. An armed watcher is a
// background task that starts with INT ignored, so every child is then
// started with INT ignored too, as the original's children inherited it.
//
// LOOP SHAPE. One bun process per arm, looping in-process. The poll wait is
// the one DIRECT `sleep` child - spawned from PATH, so a stub fast-forwards it,
// and the child ac-done's nudge looks for. Every other wait (the remote poll's
// 0.2 s ticks, its reap's 1 s grace) is a `sleep` under a /bin/sh that does not
// exec it: a grandchild the nudge can never mistake for the poll wait. Backend
// calls, the pane pass's greps and every other child run synchronously, so a
// signal waits for the step in flight as the original's trap waited for its
// foreground child; a handler runs at the next checkpoint - the top of each
// loop phase, each pane, and before any reason line prints.
//
// ESCAPE HATCH. A broken port leaves the lab without supervision (every pane
// wake, the push acceleration, the remote slot, and then every chief turn end,
// which the turn-end guard blocks on the stale beacon); the solo session never
// arms a watcher, so it never stops the slice that fixes one. Run the frozen
// original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-watch.sh "$o/bin/ac-watch.sh"
// then the chief arms `AC_HOME=<home> "$o/bin/ac-watch.sh"` (with its usual
// AC_WATCH_SKIP or AC_WATCH_ONLY) as its harness's background task and
// releases with either side's --release: the lock, marker, beacon and stamp
// formats are shared, and the copy's command line names ac-watch, which every
// nudge accepts. The autoarm hook runs the watcher beside itself, so either
// point the Stop hook's command at "$o/bin/ac-watch-autoarm.sh" or keep a
// hand-armed copy running (the hook then reads `already running` and stands
// aside). The copy bakes nothing of its path into state. LANDING: bash reads
// its script lazily, so land with no bash watcher running from the file -
// release the fleet watcher and let a scoped one end, or re-arm at once.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1: any argument but `--once` and `--release` ARMS: a typo (`-h`,
//   `--onc`) is a fleet arm that acquires the session lock for the caller.
// - W2: under a UTF-8 locale an invalid byte in the 40-line capture stops the
//   tail's sed (`sed: RE error: illegal byte sequence`): a marker or a busy
//   footer below it is lost (`check:quiet` where C reads `report:`, a busy pane
//   read idle), and while the byte stays in the window the cut tail freezes
//   the hash and the idle clock. The same sed, tail and greps are spawned
//   under the caller's locale.
// - W3: `.skip-stale-since-<f>` and `.skip-revoked-<f>` outlive the family's
//   tenure: a stale-since stamp from an earlier tenure revokes a freshly
//   promoted family's skip at its first poll (its done wake stolen to the
//   fleet spool), and a standing revoked stamp silences the next episode's
//   coverage wake; neither is reaped at demotion.
// - W4: --release TERMs whatever pid the lock names, with no check that it
//   runs a watcher - a reused pid is killed and its marker left.
// - W5: releasing the fleet WRAPPER orphans the watcher: alive under PPID=1,
//   still holding the lock, its marker never consumed.
// - W6: the HUP group ends with the exit cleanup and no reason line, the poll
//   `sleep` and a remote poll in flight orphaned; QUIT/PROF/KILL leave the
//   lock (reclaimable), a FRESH beacon and the watch-config.
// - W7: the knobs are unvalidated. AC_POLL that `sleep` refuses spins the loop
//   (sleep's complaint per pass) to heartbeat; an AC_HEARTBEAT, AC_STALE,
//   AC_BUSY_MAX or AC_GUARD_GRACE that is no integer reads every comparison
//   false - never a heartbeat, never stale, never stalled, every skip revoked;
//   AC_ARMLOG_KEEP enters `$(( keep * 2 ))` at each arm-log line, where an
//   identifier ends the run (armed: exit 0, the cleanup, no reason line; else
//   1) and a malformed number discards the command it stood in - the arm goes
//   on, a --release or a skip refusal falls through to arming, and inside the
//   loop the run ends 1.
// - W10: `.deferred-<id>` is written but absent from the one reap list
//   (taskStamps, ac_task_stamps), so a reused id inherits a deferral.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every verb needs bun now - the shim's `ERROR: required tool not
//   found: bun`, exit 1, no stdout, which the autoarm hook's no-reason-line arm
//   hands back - where --once and a scoped arm ran without it.
// - THE PROCESS is `bun --no-env-file <root>/src/watch.ts <cwd> [args]`: the
//   arm log's chain names it `bun`, and the nudge's watcher match (watcherPid,
//   ac_watcher_pid) accepts `/src/watch.ts` beside `ac-watch`.
// - SIGNAL TIMING: a TERM/INT is handled at the next checkpoint, so one landing
//   inside a pane's pass lets that pane's stamps and record land before the
//   signal line; a second TERM inside the handler is ignored, where the
//   original's reset trap let it kill at once.
// - W8: AC_SCOPE's grammar is read per its text, where bash 3.2's range under a
//   UTF-8 locale let an accented letter through (`café` scoped there).
// - W9: the comma lists are split, never globbed against the caller's cwd.
// - W11 EXCLUSIVE TEMPS: the arm-log trim, the beacon, the remote poll's two
//   capture files and jev's error file are created exclusively (the name, then
//   `.<n>` past one taken), and the release marker lands by rename, where the
//   original wrote through whatever sat at each predictable name.
// - W12 SHELL-OWN STDERR is not reproduced, the status kept: `[: <x>: integer
//   expression expected`, `<x>: unbound variable`, `value too great for base`,
//   a redirection's own failure, and a missing child's `No such file or
//   directory` - which the original also captured into the jev/compact error
//   line and the remote poll's last stderr line.
// - FAIL-PATH: a touch, rm or stamp that fails prints nothing, where touch and
//   rm printed their own line; an unwritable brain attempt stamp skips that
//   fire, where the original's errexit ended the run; a reason line stdout
//   cannot take leaves the exit's beacon its 0 alone, where the original's
//   printf kept the line buffered and the beacon write flushed it in first.
// - SIGPIPE: a closed stdout ends the run 141 with the exit cleanup, even
//   with PIPE ignored at entry - Bun ignores it itself before any code runs,
//   so an inherited SIG_IGN cannot be told apart.
// - INHERITED SIG_IGN reaches no child but INT's: Bun starts every child at
//   default dispositions, so a poll `sleep` or a backend call ends on a HUP or
//   TERM the original's children would have ignored.
// - The coverage revoke's typed line runs in this process (the original's ran
//   in a subshell), so its verified-send settle `sleep`s are direct children
//   for that call: a push nudge landing then ends one ("nudged") instead of
//   reading mid-poll, and the record waits for the next loop top.
// - The remote poll leads its own SESSION, where `set -m` made a group only.
// - CHILDREN resolve from the bin/ bun was started in (ac-lock.sh,
//   ac-remote.sh, ac-jev.sh, ac-compact-advise.sh, ac-brain.sh), where the
//   original joined `$(dirname "$0")` - the same files through a home's link.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is `ERROR: AC_HOME is not a
//   readable directory: <h>`, where the original printed cd's own line.
// - BYTES: argv and the environment arrive decoded, so a byte that is no UTF-8
//   in a scope or list variable, a meta's file name, or a marker handed back to
//   the backend's wait stamp reaches its line or child as U+FFFD.
// - A pid-less lock dir's age is read off the host clock (lockAcquire), where
//   the original read date(1).
//
// CALLERS: the chief arms it as its harness's OWN background task (CLAUDE.md
// section 7, the task-lifecycle and rooms-threads skills, session start's
// digest); the Stop hook bin/ac-watch-autoarm.sh runs it in its foreground
// with AC_AUTOARM=1 and classifies the last stdout line (`heartbeat`
// re-arms, `already running`/`refused: a live watcher` stand aside, anything
// else - none included - hands back); tests. Nothing in src/, dashboard/ or
// another bin/ entry executes it. What it WRITES is read by
// bin/ac-turnend-guard.sh (beacon, lock, spools), bin/ac-watch-autoarm.sh,
// src/guard.ts, src/wake-drain.ts (beacon, `.change-`), src/fleets.ts
// (`.watcher-owner`, beacon), src/done.ts (`.seen-`,
// `.seen-hash-`, the lock pid and its nudge), src/room.ts (`.ask-`, the
// nudge), src/remote.ts (the lock pid), src/teardown.ts (the per-id stamps)
// and every fleet view (the status lines).

import { dlopen, FFIType, ptr } from "bun:ffi";
import type { Subprocess } from "bun";
import { accessSync, appendFileSync, closeSync, constants, existsSync, openSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { constants as osConstants } from "node:os";
import {
  BUSY_RE,
  CAPTAIN_RE,
  DECISION_RE,
  STARTED_BIN,
  arithValue,
  backendAgentIdle,
  backendCall,
  backendName,
  brainFreshen,
  chiefBusyPath,
  chiefChildLive,
  chiefGateParked,
  childrenIgnoreInt,
  cksumPosix,
  claudeTranscriptPath,
  configDir,
  configReadSoft,
  crewMetas,
  dataDir,
  die,
  enterCaller,
  exclusiveTemp,
  familyOfId,
  fileMtime,
  iso,
  lockAcquire,
  lockRelease,
  metaGet,
  nowRaw,
  pidChain,
  roomFile,
  roomchiefLive,
  shellStatus,
  spawnShell,
  spawnShellSync,
  stateDir,
  statusAppend,
  taskBackend,
  taskDir,
  taskStatus,
  testInt,
  wakeFamilySpools,
  wakeOrphanPending,
  wakePending,
  wakePublish,
  wakeScopeOk,
  wakeSpoolPath,
  warn,
  watcherBeatPath,
  watcherBeatRead,
  writeAll,
} from "./lib.ts";

// Read before any listener exists: Bun installs a handler with the first
// one, even over a disposition the process started with as ignored.
function ignoredAtStart(sigs: readonly NodeJS.Signals[]): Set<NodeJS.Signals> {
  const ignored = new Set<NodeJS.Signals>();
  try {
    const lib = dlopen(process.platform === "darwin" ? "/usr/lib/libSystem.B.dylib" : "libc.so.6", {
      sigaction: { args: [FFIType.i32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
    });
    for (const sig of sigs) {
      // Room for any platform's struct sigaction; the handler leads all of them.
      const old = new BigUint64Array(32);
      if (lib.symbols.sigaction(osConstants.signals[sig], null, ptr(old)) === 0 && old[0] === 1n) ignored.add(sig);
    }
    lib.close();
  } catch {}
  return ignored;
}
const RERAISED = ["SIGHUP", "SIGUSR1", "SIGUSR2", "SIGALRM", "SIGPIPE", "SIGXCPU", "SIGVTALRM"] as const;
// Bun ignores SIGPIPE itself before any of this runs, so PIPE is never probed.
const IGNORED = ignoredAtStart(["SIGINT", "SIGTERM", ...RERAISED.filter((s) => s !== "SIGPIPE")]);
if (IGNORED.has("SIGINT")) childrenIgnoreInt(true);

const { args } = enterCaller(process.argv.slice(2));

// Byte strings (latin1) carry what the bash held as bytes; argv, the
// environment and the lib's UTF-8 paths cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const B = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const cap = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
const env = (k: string): string => process.env[k] ?? "";
const knob = (k: string, dflt: string): string => process.env[k] || dflt;
const firstLine = (s: string): string => (s.includes("\n") ? s.slice(0, s.indexOf("\n")) : s);
// `tail -n 1` then `$(...)`.
const lastLine = (s: string): string => {
  const t = s.endsWith("\n") ? s.slice(0, -1) : s;
  return cap(t.slice(t.lastIndexOf("\n") + 1));
};
const readCap = (p: string): string => {
  try {
    return cap(readFileSync(p, "latin1"));
  } catch {
    return "";
  }
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
const touch = (p: string): void => {
  try {
    closeSync(openSync(p, "a"));
    const t = new Date();
    utimesSync(p, t, t);
  } catch {}
};
const stamp = (p: string, text: string): void => {
  try {
    writeFileSync(p, B(text));
  } catch {}
};
const rmF = (...ps: string[]): void => {
  for (const p of ps)
    try {
      rmSync(p, { force: true });
    } catch {}
};
// `"$dir"/*` that `[ -e ]` finds: non-dot entries in byte order.
const globIn = (dir: string): string[] => {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${dir}/${n}`)
    .filter((p) => existsSync(p));
};
// `${list//,/ }` unquoted: split on commas and IFS white space, empties gone.
// The words are never globbed against the cwd (W9).
const words = (list: string): string[] => list.replace(/,/g, " ").split(/[ \t\n]+/).filter((w) => w !== "");
const cksumFile = (p: string): string => {
  try {
    return String(cksumPosix(readFileSync(p)));
  } catch {
    return "";
  }
};

function put(fd: 1 | 2, s: string): void {
  try {
    writeAll(fd, B(s));
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}
const say = (s: string): void => put(1, s);
const tell = (s: string): void => put(2, s);

// `[ <a> <op> <b> ]`: a side that is no test integer is the test's status 2,
// read as false.
function test(a: string, op: "-gt" | "-ge" | "-le" | "-lt", b: string): boolean {
  const x = testInt(a);
  const y = testInt(b);
  if (x === null || y === null) return false;
  return op === "-gt" ? x > y : op === "-ge" ? x >= y : op === "-le" ? x <= y : x < y;
}

// The two ways a `$(( ))` over a knob or a clock text ended the original's
// command (W7): an identifier is `set -u`'s death - the run ends there, 0
// once the arm's exit cleanup is set (bash 3.2 exits with that cleanup's
// status), else 1 - and a malformed number discards the top-level command
// the expansion stood in, the run going on after it; the main loop is the
// last such command, so the run ends 1 there. Inside a `$(...)` either one
// ends only that subshell.
type Abort = { abort: "unbound" | "arith" };
function arith(text: string): bigint {
  try {
    return arithValue(text);
  } catch (e) {
    const code = (e as { code?: string }).code;
    if (code === "EUNBOUND") throw { abort: "unbound" } as Abort;
    if (code === "EARITH") throw { abort: "arith" } as Abort;
    throw e;
  }
}
const isAbort = (e: unknown): e is Abort => typeof e === "object" && e !== null && "abort" in e;
const minus = (a: bigint, b: bigint): bigint => BigInt.asIntN(64, a - b);

let armed = false;
async function topLevel(run: () => void | Promise<void>, lastCommand = false): Promise<void> {
  try {
    await run();
  } catch (e) {
    if (!isAbort(e)) throw e;
    if (e.abort === "unbound") process.exit(armed ? 0 : 1);
    if (lastCommand) process.exit(1);
  }
}

// A handler runs at the next turn of the event loop; every step between two
// of these is synchronous, as the original's commands were between traps.
const checkpoint = (): Promise<void> => new Promise((r) => setImmediate(r));

// One child as a pipeline stage over <input>: its status and stdout.
function filter(argv: string[], input: string): { status: number; out: string } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin: B(input), stdout: "pipe", stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), out: r ? Buffer.from(r.stdout).toString("latin1") : "" };
}
// `grep -qE <re> <<<"$text"`.
const grepQ = (re: string, text: string): boolean => filter(["grep", "-qE", re], `${text}\n`).status === 0;
// `grep -<flags> <re> <<<"$text"`'s stdout.
const grepOut = (flags: string, re: string, text: string): string => filter(["grep", flags, re], `${text}\n`).out;

backendName();
if (env("AC_SOLO") === "1") die("a solo session (AC_SOLO=1) never arms a watcher - supervision belongs to the chief session (solo-session skill)");
const sd = stateDir();
const sdB = b8(sd);

function watchLog(text: string): void {
  const f = `${sd}/.watcher-arm.log`;
  const keep = knob("AC_ARMLOG_KEEP", "200");
  const line = `${iso()} ${text}`;
  try {
    appendFileSync(f, B(`${line}\n`));
  } catch {}
  tell(`${line}\n`);
  let lines = 0n;
  try {
    for (const c of readFileSync(f)) if (c === 10) lines++;
  } catch {}
  if (lines <= BigInt.asIntN(64, arith(b8(keep)) * 2n)) return;
  let tmp: { path: string; fd: number };
  try {
    tmp = exclusiveTemp(`${f}.tmp`);
  } catch {
    return;
  }
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["tail", "-n", keep, f], { stdin: "ignore", stdout: tmp.fd, stderr: "ignore" });
  } catch {}
  closeSync(tmp.fd);
  if (shellStatus(r) !== 0) return;
  try {
    spawnShellSync(["mv", tmp.path, f], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
  } catch {}
}

const releaseMarker = (pid: string): string => `${sd}/.watcher-release-${pid}`;

// `$(ps -o ppid= -p <pid> 2>/dev/null | tr -d '[:space:]')`.
function ppidOf(pid: string): string {
  try {
    return spawnShellSync(["ps", "-o", "ppid=", "-p", u8(pid)], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
      .stdout.toString("latin1")
      .replace(/[ \t\n\v\f\r]/g, "");
  } catch {
    return "";
  }
}

// The lock is the authoritative record of a scoped watcher's target: its
// suffix partitions scoped watchers from the fleet one, the arm log is
// trimmed and the beacon carries no pid. The wrapper - the shell the harness
// tracks around the watcher - is its direct parent, and a TERM to it alone
// leaves the watcher alive under PPID=1.
function releaseScopedFamily(target: string): [string, string] | null {
  let names: string[] = [];
  try {
    names = readdirSync(sd);
  } catch {}
  const pre = ".watch-only-";
  const suf = ".lock.d";
  for (const n of names.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
    if (!n.startsWith(pre) || !n.endsWith(suf) || n.length < pre.length + suf.length) continue;
    const d = `${sd}/${n}`;
    if (!isDir(d)) continue;
    const pid = readCap(`${d}/pid`);
    if (pid === "") continue;
    const fam = b8(n.slice(pre.length, n.length - suf.length));
    if (pid === target) return ["watcher", fam];
    if (ppidOf(pid) === target) return ["wrapper", fam];
  }
  return null;
}

// "state/<family>-chief.meta is absent" is NOT the test for a demoted
// roomchief: a LIVE scoped watcher can sit beside no chief meta at all. The
// room records the transition (teardown posts `DEMOTED: roomchief closed`,
// ac-room.sh close posts `CLOSED:`), so the family is over only when it has
// a room, the LAST tenure marker that starts an entry there is DEMOTED or
// CLOSED (a re-promotion protects it again; a quoted `> CLOSED:` continuation
// line is prose), and no chief meta exists - any one missing refuses.
function releaseFamilyIsOver(fam: string): boolean {
  if (!/^[a-zA-Z0-9_-]+$/.test(fam)) return false;
  if (existsSync(`${sd}/${fam}-chief.meta`)) return false;
  let room = "";
  try {
    room = roomFile(fam);
  } catch {}
  if (room === "" || !isFile(room)) return false;
  let last = "";
  try {
    last = cap(
      spawnShellSync(
        [
          "/usr/bin/env",
          "LC_ALL=C",
          "awk",
          `
    /^- \\[[^]]*\\] [^>]*> PROMOTED:/ { m = "PROMOTED" }
    /^- \\[[^]]*\\] [^>]*> DEMOTED:/  { m = "DEMOTED" }
    /^- \\[[^]]*\\] [^>]*> CLOSED:/   { m = "CLOSED" }
    END { print m }
  `,
          room,
        ],
        { stdin: "inherit", stdout: "pipe", stderr: "inherit" },
      ).stdout.toString("latin1"),
    );
  } catch {}
  return last === "DEMOTED" || last === "CLOSED";
}

// THIS home's own fleet-watcher unit: the pid recorded in .watch.lock.d, or
// its direct parent. No fleet watcher armed here refuses (null) rather than
// falling through to a foreign pid.
function homeFleetWatcherRole(target: string): string | null {
  const lockPid = readCap(`${sd}/.watch.lock.d/pid`);
  if (!/^[0-9]+$/.test(lockPid)) return null;
  if (lockPid === target) return "watcher";
  if (ppidOf(lockPid) === target) return "wrapper";
  return null;
}

// Stamp the intent and send the TERM in one verb, so the two never drift
// apart; every refusal comes BEFORE the marker, so a refused release leaves
// no trace on the pid it declined.
function release(target: string): void {
  if (!/^[0-9]+$/.test(target)) {
    tell("usage: ac-watch.sh --release <pid>\n");
    process.exit(2);
  }
  let orphan = false;
  const hit = releaseScopedFamily(target);
  if (hit !== null) {
    const [role, fam] = hit;
    if (releaseFamilyIsOver(u8(fam))) {
      orphan = true;
      watchLog(`release ALLOWED pid=${target} - scoped ${role} for ${fam}, whose roomchief is demoted/closed (orphan)`);
      tell(`note: pid ${target} is the scoped ${role} for family ${fam}, whose roomchief is DEMOTED/CLOSED - releasing the orphan (nothing is left to re-arm it).\n`);
    } else {
      const what =
        role === "wrapper"
          ? `the harness-tracked WRAPPER of the scoped watcher for family ${fam} (TERMing it leaves that watcher ALIVE under PPID=1 - an orphan that keeps polling while its exit wakes no one)`
          : `the scoped watcher for family ${fam}`;
      watchLog(`release REFUSED pid=${target} - scoped ${role} for ${fam} (belongs to its roomchief)`);
      tell(
        `refused: pid ${target} is ${what} - it belongs to that family's roomchief; only the fleet watcher is releasable via --release. Releasing it leaves ${fam} with no real-time coverage until its roomchief notices and re-arms. Release the FLEET watcher instead (its pid: cat ${sdB}/.watch.lock.d/pid).\n`,
      );
      process.exit(2);
    }
  }
  if (!orphan && homeFleetWatcherRole(target) === null) {
    watchLog(`release REFUSED pid=${target} - not this home's fleet watcher (may belong to another fleet)`);
    tell(
      `refused: pid ${target} is not this home's fleet watcher - it may belong to another fleet; only this home's own fleet watcher (or its wrapper) is releasable via --release. Its pid: cat ${sdB}/.watch.lock.d/pid.\n`,
    );
    process.exit(2);
  }
  const marker = releaseMarker(target);
  try {
    const t = exclusiveTemp(`${marker}.tmp`);
    try {
      writeAll(t.fd, B(`releaser=${process.pid}\ntarget=${target}\nreason=config-swap\nepoch=${nowRaw()}\n`));
    } finally {
      closeSync(t.fd);
    }
    if (shellStatus(spawnShellSync(["mv", "-f", t.path, marker], { stdin: "ignore", stdout: "inherit", stderr: "inherit" })) !== 0) {
      rmF(t.path);
      process.exit(1);
    }
  } catch {
    process.exit(1);
  }
  try {
    process.kill(Number(target), "SIGTERM");
  } catch {
    // A marker outliving its kill is exactly the silencer the time bound
    // exists to retire.
    rmF(marker);
    watchLog(`release FAILED pid=${target} - no such process (marker withdrawn)`);
    tell(`refused: no process ${target} to release (marker withdrawn)\n`);
    process.exit(2);
  }
  watchLog(`release pid=${target} reason=config-swap releaser=${process.pid}`);
  say(`released: pid=${target} reason=config-swap - re-arm the corrected config\n`);
  process.exit(0);
}

if ((args[0] ?? "") === "--release") await topLevel(() => release(args[1] ?? ""));

const once = (args[0] ?? "") === "--once";

// Only a VALID scope reconciles: a malformed AC_SCOPE routes to the fleet
// spool, so such a watcher IS a fleet watcher.
if (wakeScopeOk(env("AC_SCOPE"))) {
  if (env("AC_WATCH_ONLY") === "") {
    process.env.AC_WATCH_ONLY = env("AC_SCOPE");
    tell(`scoped watcher: AC_WATCH_ONLY defaulted to AC_SCOPE=${b8(env("AC_SCOPE"))}\n`);
  } else if (!words(env("AC_WATCH_ONLY")).includes(env("AC_SCOPE"))) {
    say(
      `refused: scoped watcher AC_WATCH_ONLY must contain the family it files for (AC_WATCH_ONLY=${b8(env("AC_WATCH_ONLY"))}, AC_SCOPE=${b8(env("AC_SCOPE"))})\n`,
    );
    process.exit(2);
  }
}

const pollTarget = env("AC_WATCH_ONLY") !== "" ? `only:${b8(env("AC_WATCH_ONLY"))}` : "fleet";

// A data dir, or a state meta of the family, its roomchief or a member.
function familyKnown(fam: string): boolean {
  if (isDir(`${dataDir()}/${fam}`)) return true;
  if (existsSync(`${sd}/${fam}.meta`)) return true;
  const cut = `${sd}/${fam}`.lastIndexOf("/");
  const dir = `${sd}/${fam}`.slice(0, cut);
  const pre = `${`${sd}/${fam}`.slice(cut + 1)}-`;
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names.some((n) => n.startsWith(pre) && n.endsWith(".meta") && n.length >= pre.length + 5 && existsSync(`${dir}/${n}`));
}

await topLevel(() => {
  const skip = env("AC_WATCH_SKIP");
  if (skip === "") return;
  // A skip is the FLEET watcher's instrument: the coverage record a revoked
  // skip publishes files under AC_SCOPE, which here would hand it to the very
  // family whose roomchief is gone.
  if (env("AC_SCOPE") !== "") {
    watchLog(`refused: AC_WATCH_SKIP is the fleet watcher's alone, but AC_SCOPE=${b8(env("AC_SCOPE"))} is set (AC_WATCH_SKIP=${b8(skip)})`);
    say(`refused: AC_WATCH_SKIP cannot be combined with AC_SCOPE=${b8(env("AC_SCOPE"))} - a scoped watcher watches its own family, it skips nothing\n`);
    process.exit(2);
  }
  for (const f of words(skip)) {
    if (familyKnown(f)) continue;
    watchLog(`refused: AC_WATCH_SKIP names ${b8(f)}, absent from this home (AC_WATCH_SKIP=${b8(skip)})`);
    say(`refused: AC_WATCH_SKIP entry ${b8(f)} does not belong to this home (AC_WATCH_SKIP=${b8(skip)})\n`);
    process.exit(2);
  }
});

let sleepChild: Subprocess | null = null;
let pollChild: Subprocess | null = null;
let pollOut = "";
let pollErr = "";

// `/bin/sh -c 'sleep "$1"; :'`: the trailing command keeps sh from exec'ing
// sleep, so the sleep is a GRANDchild ac-done's nudge cannot mistake for the
// poll wait - under a wedged transport this wait is most of the interval.
const QUIET_SLEEP = ["/bin/sh", "-c", 'sleep "$1"; :', "sh"];
async function quietSleep(secs: string): Promise<void> {
  try {
    await spawnShell([...QUIET_SLEEP, secs], { stdin: "ignore", stdout: "inherit", stderr: "inherit" }).exited;
  } catch {}
}

// The process GROUP, never the pid: a kill aimed at ac-remote.sh alone
// leaves the transport hook and its curl children alive under ppid=1, still
// holding the capture open.
async function reapPoll(): Promise<void> {
  if (pollChild === null) return;
  const p = pollChild;
  try {
    process.kill(-p.pid, "SIGTERM");
  } catch {}
  await quietSleep("1");
  try {
    process.kill(-p.pid, "SIGKILL");
  } catch {}
  await p.exited;
  pollChild = null;
}

function dropPollFiles(): void {
  for (const f of [pollOut, pollErr]) if (f !== "" && f !== "/dev/null") rmF(f);
  pollOut = "";
  pollErr = "";
}

// `awk '/^remote-order /{r=$2} END{print r}'` over the poll's capture: the
// last rid that landed.
function lastRid(out: string): string {
  let r = "";
  for (const l of out.split("\n")) if (l.startsWith("remote-order ")) r = l.split(/[ \t]+/).filter((w) => w !== "")[1] ?? "";
  return r;
}

// The calm reason text when a FRESH owner-release marker names THIS pid, else
// null. Consumed either way, so a leftover can never become a standing
// silencer for a later kill. 30 s: two orders of magnitude above the real
// gap (the release idiom's `sleep 1`), far below a leftover muting a genuine
// kill minutes later. ac_now never writes a leading zero.
function releaseNote(): string | null {
  const m = releaseMarker(String(process.pid));
  if (!isFile(m)) return null;
  const get = (k: string): string => {
    try {
      return metaGet(m, k);
    } catch {
      return "";
    }
  };
  const epoch = get("epoch");
  const reason = get("reason");
  const releaser = get("releaser");
  rmF(m);
  if (!/^[1-9][0-9]*$/.test(epoch)) return null;
  if (minus(arith(nowRaw()), BigInt(epoch)) > 30n) return null;
  return `${reason || "release"} by owner (released by pid=${releaser || "unknown"})`;
}

let signalled = false;
function onSignal(sig: "TERM" | "INT"): void {
  if (signalled) return;
  signalled = true;
  if (sleepChild !== null)
    try {
      sleepChild.kill("SIGTERM");
    } catch {}
  // The guaranteed half of the poll's reap - a signal is the one way out
  // that skips checkRemote's own - and the capture READ before it is dropped:
  // the stash-then-wake gap in ac-remote.sh can burn a rid, and this file is
  // the only evidence the poll got that far.
  let pollNote = "";
  if (pollChild !== null) {
    const p = pollChild;
    try {
      process.kill(-p.pid, "SIGTERM");
    } catch {}
    try {
      spawnShellSync([...QUIET_SLEEP, "1"], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
    } catch {}
    try {
      process.kill(-p.pid, "SIGKILL");
    } catch {}
    pollChild = null;
    if (pollOut !== "") pollNote = ` - poll interrupted mid-flight; last rid ingested: ${lastRid(readCap(pollOut)) || "none"}`;
  }
  dropPollFiles();
  try {
    const note = releaseNote() ?? "watcher killed externally";
    watchLog(`signal:${sig} pid=${process.pid} target=${pollTarget} - ${note}${pollNote}`);
    say(`signal:${sig} pid=${process.pid} target=${pollTarget} - ${note}${pollNote}, lock released; re-arm to restore coverage\n`);
  } catch (e) {
    if (!isAbort(e)) throw e;
    process.exit(e.abort === "unbound" && armed ? 0 : 1);
  }
  process.exit(0);
}
if (!IGNORED.has("SIGTERM")) process.on("SIGTERM", () => onSignal("TERM"));
if (!IGNORED.has("SIGINT")) process.on("SIGINT", () => onSignal("INT"));
// The original died of these with its exit cleanup run first, then the signal
// re-raised - a parent reads a signal death, so the cleanup runs here and the
// signal is raised again under its default disposition.
for (const sig of RERAISED) {
  if (IGNORED.has(sig)) continue;
  process.on(sig, () => {
    exitCleanup();
    process.removeAllListeners(sig);
    process.kill(process.pid, sig);
    process.exit(128 + osConstants.signals[sig]);
  });
}

// A scoped watcher is keyed by the ONE family it files for (AC_SCOPE), never
// its whole watch set: an epic roomchief's set changes as stories start and
// land, and the lock, beacon and spool must keep the name ac-done's nudge
// rebuilds from AC_FLEET_SCOPE.
let lockSuffix = "";
if (env("AC_WATCH_ONLY") !== "") lockSuffix = wakeScopeOk(env("AC_SCOPE")) ? `-only-${env("AC_SCOPE")}` : `-only-${cap(env("AC_WATCH_ONLY")).replace(/,/g, "_")}`;
const lock = `${sd}/.watch${lockSuffix}.lock.d`;
const configFile = `${sd}/.watcher-config${lockSuffix}`;
const beatFile = watcherBeatPath(sd, env("AC_SCOPE"));

// tmp + rename, never a truncate in place: a reader catching a truncated
// beacon reads an EMPTY beat, and every consumer computes `now - beat`.
// Best-effort - a beacon that cannot be published never fails a poll or an
// exit.
function publishBeacon(value: string): void {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(`${beatFile}.tmp`);
  } catch {
    return;
  }
  try {
    writeAll(t.fd, B(`${value}\n`));
    closeSync(t.fd);
  } catch {
    try {
      closeSync(t.fd);
    } catch {}
    rmF(t.path);
    return;
  }
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["mv", "-f", t.path, beatFile], { stdin: "ignore", stdout: "inherit", stderr: "ignore" });
  } catch {}
  if (shellStatus(r) !== 0) rmF(t.path);
}

// An armed run's exit cleanup, once: the beacon stood down to 0 (a fresh beat
// must never outlive the process that made it), the watch-config removed,
// the lock released.
let cleanedUp = false;
function exitCleanup(): void {
  if (!armed || cleanedUp) return;
  cleanedUp = true;
  publishBeacon("0");
  rmF(configFile);
  try {
    lockRelease(lock);
  } catch {}
}

// `printf | sort -u | paste -sd, -`: the SET of an AC_WATCH_SKIP list, so the
// same families in another order (a typed arm against the autoarm hook's
// glob order) or with a duplicate compare equal. Compare-only: the config
// file keeps the raw string an incumbent armed with.
function skipSet(list: string): string {
  if (list === "") return "";
  const sorted = filter(["sort", "-u"], `${list.replace(/,/g, "\n")}\n`);
  return cap(filter(["paste", "-sd,", "-"], sorted.out).out);
}

async function ownerGate(): Promise<void> {
  let acquire: ReturnType<typeof spawnShellSync> | null = null;
  try {
    acquire = spawnShellSync(["/bin/sh", "-c", 'exec "$0" "$@" 2>&1', `${STARTED_BIN}/ac-lock.sh`, "acquire"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  const rc = shellStatus(acquire);
  const note = acquire ? cap(Buffer.from(acquire.stdout).toString("latin1")) : "";
  if (note !== "") tell(`${note}\n`);
  await checkpoint();
  if (rc === 2) {
    say("refused: fleet watcher not armed - another session owns this home\n");
    process.exit(2);
  }
  const owner = `${sd}/.watcher-owner`;
  if (rc !== 0) {
    // Only rc 2 is a foreign owner: a missing bun or an unreadable lock is no
    // one's claim on the home, and with no owner on record the remote poller
    // stays off until a lock-holding session arms.
    warn(`session lock acquire failed (rc=${rc}, ac-lock.sh) - arming without the owner gate`);
    stamp(owner, "");
    return;
  }
  let status: ReturnType<typeof spawnShellSync> | null = null;
  try {
    status = spawnShellSync([`${STARTED_BIN}/ac-lock.sh`, "status"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  await checkpoint();
  const held = (status ? Buffer.from(status.stdout).toString("latin1") : "")
    .split("\n")
    .flatMap((l) => {
      const m = /^held pid=([0-9]+)/.exec(l);
      return m ? [`${m[1]}\n`] : [];
    })
    .join("");
  stamp(owner, held);
  if (shellStatus(status) !== 0) {
    warn(`session lock status failed (rc=${shellStatus(status)}, ac-lock.sh) - arming without the owner gate`);
    stamp(owner, "");
  }
}

// The lock is held by a LIVE watcher (a dead or stale one was reclaimed by
// lockAcquire). An IDENTICAL arm is idempotent; a DIFFERING one refuses
// loudly so the caller releases the stale config instead of silently
// leaving it in charge. Every line names the running pid and the
// single-target release, because a remedy naming no target is what drove
// operators to pattern kills that reap every home's watcher.
function heldRefusal(): never {
  const running = readCap(configFile);
  const pending = env("AC_SCOPE") !== "" ? wakePending(sd, env("AC_SCOPE")) : wakePending(sd, "") || wakeOrphanPending(sd);
  const pendingNote = pending
    ? "pending: your inbox is non-empty - drain with bin/ac-wake-drain.sh before ending the turn"
    : "pending: your inbox is empty - nothing waiting";
  const runningPid = readCap(`${lock}/pid`);
  if (skipSet(running) === skipSet(b8(env("AC_WATCH_SKIP")))) {
    // BOUNDED INCUMBENT: the autoarm hook's watcher dies with its Stop-hook
    // firing, so a HAND fleet arm standing aside for it would cover nothing.
    if (env("AC_AUTOARM") === "" && env("AC_WATCH_ONLY") === "" && isFile(`${lock}/autoarm`)) {
      watchLog(
        `refused: live watcher pid=${runningPid || "unknown"} is the auto-arm hook's own (bounded by AC_AUTOARM_BUDGET) - take durable ownership with: ac-watch.sh --release ${runningPid || "<pid>"}`,
      );
      say(
        `refused: the live watcher (pid ${runningPid || "unknown"}) is the auto-arm hook's own - it dies with that Stop-hook firing when the hook hands its budget back, so THIS arm covers nothing and your next turn end may have no watcher. Take durable ownership with: bin/ac-watch.sh --release ${runningPid || "<pid>"} (marks the release as yours and TERMs that one pid, which releases its lock cleanly), then re-arm - a hand-armed watcher is a harness background task and carries no budget. Never release by pattern (pkill/killall -f ac-watch): every home on this box runs the same command line, so a pattern kill reaps the watchers of every other fleet too. ${pendingNote}\n`,
      );
      process.exit(2);
    }
    say(`already running - ${pendingNote}\n`);
    process.exit(0);
  }
  watchLog(
    `refused: live watcher pid=${runningPid || "unknown"} runs AC_WATCH_SKIP=[${running}], this arm carries AC_WATCH_SKIP=[${b8(env("AC_WATCH_SKIP"))}] - release with: ac-watch.sh --release ${runningPid || "<pid>"}`,
  );
  say(
    `refused: a live watcher (pid ${runningPid || "unknown"}) holds a DIFFERENT watch-config (running AC_WATCH_SKIP=[${running}], new AC_WATCH_SKIP=[${b8(env("AC_WATCH_SKIP"))}]); release THAT ONE with: bin/ac-watch.sh --release ${runningPid || "<pid>"} (marks the release as yours and TERMs that one pid, which releases its lock cleanly), then re-arm the corrected config. Never release by pattern (pkill/killall -f ac-watch): every home on this box runs the same command line, so a pattern kill reaps the watchers of every other fleet too. ${pendingNote}\n`,
  );
  process.exit(2);
}

await topLevel(async () => {
  if (once) return;
  if (env("AC_WATCH_ONLY") === "") await ownerGate();
  if (!lockAcquire(lock, 0, () => {})) heldRefusal();
  try {
    writeFileSync(configFile, B(`${b8(env("AC_WATCH_SKIP"))}\n`));
  } catch {
    process.exit(1);
  }
  // Inside the lock dir, so the release retires it with the lock: the marker
  // can never outlive the watcher it describes.
  if (env("AC_AUTOARM") !== "") stamp(`${lock}/autoarm`, "");
  armed = true;
  process.on("exit", exitCleanup);
  watchLog(`arm pid=${process.pid} target=${pollTarget} poll=${b8(knob("AC_POLL", "15"))}s heartbeat=${b8(knob("AC_HEARTBEAT", "600"))}s chain=${pidChain()}`);
});

const inScope = (id: string, list: string): boolean => {
  for (const fam of words(list)) {
    if (id === `${fam}-chief`) return false;
    if (id === fam || id.startsWith(`${fam}-`)) return true;
  }
  return false;
};

// The AC_WATCH_SKIP family <id> belongs to: by the id grammar (an epic's own
// panes; a <fam>-chief never), or by the pane's meta fleet_scope (a STORY
// crewmate, whose id shares no prefix with its epic) - returning the family
// whose scoped coverage the caller must revalidate.
function skipFamily(id: string, fleetScope: string): string | null {
  for (const fam of words(env("AC_WATCH_SKIP"))) {
    if (id !== `${fam}-chief` && (id === fam || id.startsWith(`${fam}-`))) return fam;
    if (fleetScope !== "" && fleetScope === b8(fam)) return fam;
  }
  return null;
}

// 0 the family's own scoped coverage is live (roomchief meta + window, and a
// beacon younger than AC_GUARD_GRACE), 1 the roomchief is not live, 2 it is
// and only the beacon is stale - saying which half failed is what spares the
// caller a second probe of the same chief pane.
function skipCoverageLive(fam: string): 0 | 1 | 2 {
  if (!roomchiefLive(sd, fam, { stdin: "inherit", stdout: "inherit" })) return 1;
  const beat = watcherBeatRead(sd, fam).split(" ")[0]!;
  return test(String(minus(arith(nowRaw()), BigInt(beat))), "-le", knob("AC_GUARD_GRACE", "300")) ? 0 : 2;
}

// A live roomchief with a stale beacon is almost always mid re-arm (its
// scoped watcher heartbeat-exited and stood its beacon down): the skip holds
// through AC_GUARD_GRACE from when the gap opened.
function rearmGraceActive(fam: string): boolean {
  const marker = `${sd}/.skip-stale-since-${fam}`;
  const now = nowRaw();
  let since = readCap(marker);
  if (!/^[1-9][0-9]*$/.test(since)) {
    since = now;
    stamp(marker, `${now}\n`);
  }
  return test(String(minus(arith(now), arith(since))), "-le", knob("AC_GUARD_GRACE", "300"));
}

// A missing or malformed declaration is NO declaration: fail closed.
function chiefBusyDeclared(fam: string): boolean {
  const until = readCap(chiefBusyPath(sd, fam));
  if (!/^[0-9]+$/.test(until)) return false;
  return test(nowRaw(), "-le", until);
}

// The epoch in a .change-/.busy- clock stamp, or now when the file holds
// nothing ac_now could have written - and the file is rewritten to now. Read
// raw, such a value killed the pass or read as a 56-year clock; restarting
// fails toward waking one window late.
function clockStamp(file: string): string {
  let v = readCap(file);
  if (!/^[1-9][0-9]*$/.test(v)) {
    v = nowRaw();
    stamp(file, `${v}\n`);
  }
  return v;
}

// A chief pane is `<fam>-chief`, which familyOfId does not strip, and the
// busy declaration is keyed by the bare family.
const busyFamilyOf = (id: string): string => (id.endsWith("-chief") ? id.slice(0, -"-chief".length) : familyOfId(id));

// The family's codereview rounds and the crew-ship run's review step, newest
// mtime winning; round ids sort by time, so a tie goes to the later entry.
function latestFindingsOf(id: string): string | null {
  let wt = "";
  try {
    accessSync(`${sd}/${id}.meta`, constants.R_OK);
    wt = metaGet(`${sd}/${id}.meta`, "worktree");
  } catch {}
  const rounds = `${dataDir()}/${busyFamilyOf(id)}/verify/codereview`;
  const cands = globIn(rounds).map((r) => `${r}/findings.json`);
  cands.push(`${wt === "" ? "/nonexistent" : u8(wt)}/.crew/ship/current/findings/review.json`);
  let best = "";
  let bestM = 0n;
  for (const c of cands) {
    if (!isFile(c)) continue;
    const m = fileMtime(c);
    if (m === null) continue;
    if (BigInt(m) >= bestM) {
      best = c;
      bestM = BigInt(m);
    }
  }
  return best === "" ? null : best;
}

// This watcher's OWN wait-shaped status notes: declaredWait must not mistake
// its verdict for the worker's word.
const WATCH_ASK_NOTE = "needs-decision: pane blocked on an interactive prompt";
const WATCH_ENDED_NOTE = "blocked: ended its turn with no report line";
// Claude's turn-summary wording for a turn that ended with work still running.
// `still running` takes any kind claude lists there (shells, monitors, ...): a
// kind missing from an enumeration re-opened the wake loop, while matching too
// wide only defers a wake.
const BACKGROUND_RE = "Waiting for [0-9]+ background agents? to finish|still running";

// <path> created exclusively, else <path>.<n> - never written through
// whatever sits at a predictable name.
function exclusiveAt(path: string): { path: string; fd: number } {
  for (let n = 0; ; n++) {
    const p = n === 0 ? path : `${path}.${n}`;
    try {
      return { path: p, fd: openSync(p, "wx") };
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
    }
  }
}

const mktemp = (template: string): string | null => {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["mktemp", template], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  } catch {}
  return r !== null && shellStatus(r) === 0 ? cap(Buffer.from(r.stdout).toString("latin1")) : null;
};
const tmpRoot = (): string => process.env.TMPDIR || "/tmp";

// The System One net on the quiet arm (JEV NOTE): ` jev=<choice> p=<p>` or
// "". Run as the original's `$(jev_note ...)` ran: a death inside it ends
// only the note.
function jevNote(idB: string, tail: string): string {
  const f = mktemp(`${tmpRoot()}/ac-watch-jev.XXXXXX`);
  if (f === null) return "";
  stamp(u8(f), `${tail}\nstatus: ${lastLine((() => {
    try {
      return readFileSync(`${sd}/${u8(idB)}.status`, "latin1");
    } catch {
      return "";
    }
  })())}\n`);
  let out = "";
  let errPath = "";
  try {
    const e = exclusiveAt(`${u8(f)}.err`);
    errPath = e.path;
    let r: ReturnType<typeof spawnShellSync> | null = null;
    try {
      r = spawnShellSync(
        [
          `${STARTED_BIN}/ac-jev.sh`,
          "ask",
          "--site",
          "watch",
          "--state-file",
          u8(f),
          "--choice",
          "done",
          "--instructions",
          "Decide whether the assistant's latest unit of work in this pane is finished.",
          "--criteria",
          "finished=Finished and reported, including a question, choice, or blocker fully stated and handed to whoever must act next.",
          "not_finished=The assistant still owes a next step it can take now.",
          "unclear=Not enough reliable evidence.",
        ],
        { stdin: "inherit", stdout: "pipe", stderr: e.fd },
      );
    } catch {}
    closeSync(e.fd);
    out = r !== null && shellStatus(r) === 0 ? cap(Buffer.from(r.stdout).toString("latin1")) : "";
  } catch {}
  const err = errPath === "" ? "" : cap(firstLine(readCap(errPath)));
  rmF(u8(f), ...(errPath === "" ? [] : [errPath]));
  try {
    if (err !== "") watchLog(`${err} (${idB})`);
  } catch (e) {
    if (isAbort(e)) return "";
    throw e;
  }
  if (out === "") return "";
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(["jq", "-r", '.done | " jev=\\(.choice) p=\\(.p[.choice])"'], { stdin: B(`${out}\n`), stdout: "pipe", stderr: "ignore" });
  } catch {}
  return r === null ? "" : cap(Buffer.from(r.stdout).toString("latin1"));
}

// The COMPACT NOTE: ` <adviser's line>` when the crewmate's own claude
// transcript is judged ready for /compact; AC_COMPACT_ADVISE is the seam.
function compactNote(id: string, idB: string): string {
  let sid = "";
  try {
    accessSync(`${sd}/${id}.meta`, constants.R_OK);
    sid = metaGet(`${sd}/${id}.meta`, "session_id");
  } catch {}
  if (sid === "") return "";
  const tx = claudeTranscriptPath(sid);
  if (tx === null) return "";
  const err = mktemp(`${tmpRoot()}/ac-watch-compact.XXXXXX`);
  if (err === null) return "";
  let out = "";
  try {
    const fd = openSync(u8(err), "w");
    let r: ReturnType<typeof spawnShellSync> | null = null;
    try {
      r = spawnShellSync([process.env.AC_COMPACT_ADVISE || `${STARTED_BIN}/ac-compact-advise.sh`, u8(tx), "--role", "crew"], { stdin: "inherit", stdout: "pipe", stderr: fd });
    } catch {}
    closeSync(fd);
    out = r !== null && shellStatus(r) === 0 ? cap(Buffer.from(r.stdout).toString("latin1")) : "";
  } catch {}
  let size = 0;
  try {
    size = statSync(u8(err)).size;
  } catch {}
  try {
    if (size > 0) watchLog(`${cap(firstLine(readCap(u8(err))))} (${idB})`);
  } catch (e) {
    if (isAbort(e)) return "";
    throw e;
  }
  rmF(u8(err));
  return out === "" ? "" : ` ${out}`;
}

// `<reason>\t<dedup key>` when <id>'s silence is EXPLAINED (STALE
// DEFERRAL), else null: the status log's last line when the WORKER wrote a
// captain-wait marker or `paused:` (keyed with the log's byte size, so a
// re-appended identical line is a new declaration), else the latest findings
// holding an undecided ask-user, read by jq KEY.
function declaredWait(id: string): string | null {
  const f = taskStatus(id);
  let text = "";
  try {
    text = readFileSync(f, "latin1");
  } catch {}
  const line = lastLine(text);
  const last = line.includes(" ") ? line.slice(line.indexOf(" ") + 1) : line;
  // AC_DECISION_RE's own anchoring with paused added to its verb group; an
  // overridden regex the substitution cannot see keeps its own set.
  const waitRe = DECISION_RE.replace("(needs-decision|blocked|checks-passed):", "(needs-decision|blocked|checks-passed|paused):");
  if (last !== "" && last !== WATCH_ASK_NOTE && last !== WATCH_ENDED_NOTE && grepQ(waitRe, last)) {
    const verb = firstLine(cap(grepOut("-oE", "(needs-decision|blocked|checks-passed|paused):", last)));
    let size = "";
    try {
      size = String(statSync(f).size);
    } catch {}
    return `declared-wait ${verb.replace(/:$/, "")}\t${size}:${last}`;
  }
  const fl = latestFindingsOf(id);
  if (fl === null) return null;
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(
      [
        "jq",
        "-e",
        `(if type == "array" then . else (.findings // []) end)
         | any(.action == "ask-user" and ((.decision // "") == ""))`,
        fl,
      ],
      { stdin: "inherit", stdout: "ignore", stderr: "ignore" },
    );
  } catch {}
  if (shellStatus(r) !== 0) return null;
  return `gate-parked\t${b8(fl)}:${cksumFile(fl)}`;
}

// "The wake the CURRENT branch queued reached disk", read by the one caller
// that must know - an episode latch - and reset by whoever reads it, or a 0
// left standing rides out on a later reason line as a false alarm.
let wakePublished = true;

// The durable record every consumer reads, filed under AC_SCOPE. A failed
// publish is never swallowed: the dedup latch has already advanced, so the
// loss is logged and then ridden out on the reason line.
function queueWake(kind: string, idB: string, payload: string): void {
  wakePublished = true;
  if (wakePublish(sd, env("AC_SCOPE"), kind, idB, payload)) return;
  wakePublished = false;
  watchLog(`wake-publish FAILED kind=${kind} id=${idB} scope=${b8(env("AC_SCOPE")) || "fleet"} - record NOT durable, payload: ${payload}`);
}

// The exit reason line - the ONE channel that survives an unwritable state
// dir (the autoarm hook drops stderr and the arm log has no reader) - so a
// lost record rides on the SAME line, never a second one.
function reasonLine(reason: string): string {
  const line = wakePublished ? `${reason}\n` : `${reason} - WAKE NOT DURABLE: this line is the only record; the state dir may be unwritable\n`;
  wakePublished = true;
  return line;
}

// A pending signal is handled before a reason line prints, so a run ends with
// one line either way.
async function finish(line: string): Promise<never> {
  await checkpoint();
  say(line);
  process.exit(0);
}

// EQUALITY is this watcher's own stamp (the captured line verbatim); a SUFFIX
// is the agent's push - ac-done.sh stamps the marker TEXT, the pane renders
// it behind a TUI glyph the agent cannot know.
const markerSeen = (line: string, stored: string): boolean => stored !== "" && (line === stored || line.endsWith(stored));

// A backend verb run in this process: a route that refuses its backend ended
// the original shell itself.
function routed(r: { status: number; exited: boolean }): number {
  if (r.exited) process.exit(1);
  return r.status;
}

const stdio = { stdin: "inherit", stdout: "inherit", stderr: "ignore" } as const;

// One pane of the pass: its reason line when it is actionable, else null.
async function checkPane(meta: string): Promise<string | null> {
  let id = meta.replace(/\/+$/, "");
  id = id.slice(id.lastIndexOf("/") + 1);
  if (id !== ".meta" && id.endsWith(".meta")) id = id.slice(0, -".meta".length);
  id = id.replace(/\n+$/, "");
  const idB = b8(id);
  const st = (b: string): string => `${sd}/.${b}-${id}`;

  if (env("AC_WATCH_ONLY") !== "" && !inScope(id, env("AC_WATCH_ONLY"))) return null;
  if (env("AC_WATCH_SKIP") !== "") {
    let fleetScope = "";
    try {
      fleetScope = cap(metaGet(meta, "fleet_scope"));
    } catch {}
    const fam = skipFamily(id, fleetScope);
    if (fam !== null) {
      const cov = skipCoverageLive(fam);
      if (cov === 0) {
        rmF(`${sd}/.skip-revoked-${fam}`, `${sd}/.skip-stale-since-${fam}`);
        return null;
      }
      // BUSY first, short-circuiting, so a declared window never consumes
      // the re-arm grace.
      if (cov === 2 && (chiefBusyDeclared(fam) || rearmGraceActive(fam))) return null;
      if (!existsSync(`${sd}/.skip-revoked-${fam}`)) {
        watchLog(`skip revoked: ${b8(fam)} scoped coverage down (roomchief gone or beacon stale past re-arm grace) - fleet watcher covering its panes directly`);
        // A revoke must WAKE, on two channels once per episode: a coverage
        // record on the fleet spool, and a line typed into the roomchief pane
        // - a keystroke starts a turn on a live-but-asleep chief, a dead pane
        // swallows it. No reason line of its own, so the latch defers to the
        // record and the flag is cleared here.
        queueWake("coverage", `${b8(fam)}-chief`, `scoped coverage down for ${b8(fam)} - fleet watcher covering its panes; the roomchief must drain and re-arm (or be recovered)`);
        if (wakePublished) touch(`${sd}/.skip-revoked-${fam}`);
        wakePublished = true;
        const chief = `${fam}-chief`;
        const saved = process.env.AC_BACKEND;
        let b = "";
        try {
          accessSync(`${sd}/${chief}.meta`, constants.R_OK);
          b = metaGet(`${sd}/${chief}.meta`, "backend");
        } catch {}
        process.env.AC_BACKEND = u8(b) || "herdr";
        try {
          backendCall(
            "send_line",
            [chief, `wake: your scoped watcher for ${fam} is down and wakes may be pending - run bin/ac-wake-drain.sh, act on each, then re-arm bin/ac-watch.sh as your own background task`],
            { stdin: "inherit", stdout: "ignore", stderr: "ignore", subshell: true },
          );
        } catch {}
        if (saved === undefined) delete process.env.AC_BACKEND;
        else process.env.AC_BACKEND = saved;
      }
    }
  }
  // Exported, as the original exported it: later children (jev, the
  // adviser, the remote poll) inherit the last pane's backend.
  process.env.AC_BACKEND = u8(taskBackend(id));

  const target = (): string => cap(backendCall("target", [id], { stdin: "inherit", stdout: "pipe", stderr: "inherit" }).out.toString("latin1"));
  const alive = routed(backendCall("window_alive", [id], { stdin: "inherit", stdout: "inherit", stderr: "inherit" }));
  if (alive !== 0 && alive !== 1) {
    // UNOBSERVABLE: only a definite 1 may become gone; one wake and one status
    // line per outage episode, and polling goes on.
    if (!existsSync(st("unobservable"))) {
      touch(st("unobservable"));
      statusAppend(id, `unobservable: backend could not be read for ${target()} - NOT a death; the pane may well be alive (check the backend itself)`);
      queueWake("unobservable", idB, "the backend could not be read - liveness unknown, no work assumed lost (check the backend: herdr status server)");
      return reasonLine(`unobservable:${idB}`);
    }
    return null;
  }
  rmF(st("unobservable"));
  if (alive === 1) {
    if (!existsSync(st("gone"))) {
      touch(st("gone"));
      statusAppend(id, "failed: window gone");
      queueWake("gone", idB, `window ${target()} vanished`);
      return reasonLine(`gone:${idB}`);
    }
    return null;
  }
  rmF(st("gone"));

  const waitFile = `${sd}/.captain-wait-${id}`;
  if (routed(backendCall("agent_blocked", [id], stdio)) === 0) {
    if (!existsSync(st("ask"))) {
      touch(st("ask"));
      statusAppend(id, WATCH_ASK_NOTE);
      queueWake("ask", idB, "agent blocked on an interactive prompt (answer or steer it)");
      return reasonLine(`ask:${idB}`);
    }
  } else if (existsSync(st("ask")) && !existsSync(waitFile)) {
    // The EDGE only: a live captain-wait stamp masks agent_blocked, which is
    // no resume, and the status log has no dedupe of its own.
    rmF(st("ask"));
    const idle = routed(backendAgentIdle(id, { stdin: "inherit", stderr: "ignore" }));
    statusAppend(id, idle === 0 ? "idle: pane no longer blocked, turn complete" : "working: pane no longer blocked, agent resumed");
  }

  // The same sed and tail the original piped the capture through, so the
  // caller's locale reads the bytes as it did there (W2).
  const captured = backendCall("capture", [id, "40"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" }).out.toString("latin1");
  const tail = cap(filter(["tail", "-n", "25"], filter(["sed", "/^$/d"], captured).out).out);
  // ONCE per pane per pass: every branch below reads the same tail.
  const busy = grepQ(BUSY_RE, tail);
  // The run is stamped on the 0->1 edge, never read off .change-<id>, which
  // any tail change resets - a footer rendering an elapsed counter would keep
  // the bound from ever accumulating.
  const busyFile = st("busy");
  if (busy) {
    if (!existsSync(busyFile)) stamp(busyFile, `${nowRaw()}\n`);
  } else rmF(busyFile, st("busy-stalled"));
  const hash = String(cksumPosix(B(tail)));
  const changedFile = st("change");
  if (hash !== readCap(st("hash"))) {
    stamp(st("hash"), `${hash}\n`);
    stamp(changedFile, `${nowRaw()}\n`);
    rmF(st("stale"));
  }

  const marker = lastLine(grepOut("-E", CAPTAIN_RE, tail));

  // RE-TASK FORGETS A REPORTED COMPLETION, gated on an EMPTY marker so a
  // completion still in the tail keeps its .seen-<id>.
  if (marker === "" && busy) {
    const seen = readCap(st("seen"));
    if (seen !== "" && grepQ(CAPTAIN_RE, seen) && !grepQ(DECISION_RE, seen)) rmF(st("seen"));
  }

  // STALE-STAMP SUPERSESSION: busy under this fleet's own captain-wait stamp.
  if (existsSync(waitFile) && busy) {
    const sup = marker !== "" ? marker : readCap(st("seen"));
    stamp(st("superseded"), `${sup}\n`);
    statusAppend(id, `working: superseded ${sup || "the captain-wait stamp"}`);
    routed(backendCall("clear_wait", [id], stdio));
  }

  if (marker !== "") {
    const seen = readCap(st("seen"));
    const seenHash = readCap(st("seen-hash"));
    if (!markerSeen(marker, seen)) {
      stamp(st("seen"), `${marker}\n`);
      // A NEW marker re-parks the pane: the supersession record covers the
      // old one only.
      rmF(st("superseded"));
      statusAppend(id, marker);
      // Only a PARKED pane is stamped - a stamp taken while busy is released
      // with no state transition ahead of it, and herdr then holds no
      // identity for the pane until its turn ends. Reconcile stamps it once
      // the pane reads non-busy.
      if (grepQ(DECISION_RE, marker)) {
        if (!busy) routed(backendCall("mark_wait", [id, u8(marker)], stdio));
      } else routed(backendCall("clear_wait", [id], stdio));
      stamp(st("seen-hash"), `${hash}\n`);
      // LAST-MOMENT RECHECK: ac-done.sh stamps .seen-<id> BEFORE it
      // publishes, so a stamp no longer ours that still covers this marker
      // means its record exists or is one syscall away.
      const seenNow = readCap(st("seen"));
      if (seenNow === marker || !markerSeen(marker, seenNow)) {
        queueWake("report", idB, marker);
        return reasonLine(`report:${idB}`);
      }
    } else if (grepQ(DECISION_RE, marker) && !existsSync(waitFile) && marker !== readCap(st("superseded")) && !busy) {
      // Reconcile: parked on an already-seen captain-wait marker with no
      // stamp - re-stamped silently, the chief already knows.
      routed(backendCall("mark_wait", [id, u8(marker)], stdio));
    } else if (hash !== seenHash && !busy && !grepQ(BACKGROUND_RE, lastLine(grepOut("-E", "^✻ ", tail)))) {
      stamp(st("seen-hash"), `${hash}\n`);
      if (seenHash !== "") {
        queueWake("report", idB, `${marker} (pane advanced since the last wake)`);
        return reasonLine(`report:${idB}`);
      }
      // PUSH ADOPT: no hash was recorded for this already-seen marker, so the
      // agent's own push consumed it - anchored silently, never movement.
    }
    // No early return: a deduped marker must not silence the artifact channel.
  }

  // ARTIFACT channel, deferred while the pane is busy writing the very
  // report - a suppressed pass stamps nothing.
  let dir = "";
  try {
    dir = taskDir(id).replace(/\n+$/, "");
  } catch {}
  const report = dir === "" ? "" : `${dir}/report.md`;
  if (report !== "" && isFile(report) && !busy) {
    const rhash = cksumFile(report);
    if (rhash !== readCap(st("report-hash"))) {
      stamp(st("report-hash"), `${rhash}\n`);
      queueWake("report", idB, `report.md ready at ${b8(report)} (artifact channel)`);
      return reasonLine(`report:${idB}`);
    }
  }

  // BUSY-STALL BOUND, before the marker's early return so an already-deduped
  // marker cannot route silence around it.
  if (busy && test(knob("AC_BUSY_MAX", "2700"), "-gt", "0") && !existsSync(st("busy-stalled")) && !chiefBusyDeclared(busyFamilyOf(id))) {
    const now = arith(nowRaw());
    const age = String(minus(now, arith(clockStamp(busyFile))));
    if (test(age, "-ge", knob("AC_BUSY_MAX", "2700"))) {
      touch(st("busy-stalled"));
      statusAppend(id, `busy but stalled: ${age}s inside one call with no turn end`);
      queueWake("stale", idB, `busy for ${age}s with no turn end - the pane may be hung inside a single call`);
      return reasonLine(`stale:${idB}`);
    }
  }

  if (marker !== "") return null;

  const now = arith(nowRaw());
  const idle = String(minus(now, arith(clockStamp(changedFile))));
  if (
    !test(idle, "-ge", knob("AC_STALE", "240")) ||
    existsSync(st("stale")) ||
    chiefGateParked(id) ||
    chiefChildLive(sd, id, { stdin: "inherit", stdout: "inherit" }) ||
    busy
  )
    return null;
  if (routed(backendAgentIdle(id, { stdin: "inherit", stderr: "ignore" })) === 0) {
    let limit = lastLine(grepOut("-oE", "You('|’)ve hit your [a-z ]*limit · .*", tail));
    let login = lastLine(grepOut("-oE", "(Not logged in|Login expired|OAuth token revoked|Authentication required|Invalid API key|Invalid auth token) · .*", tail));
    let harness = "";
    try {
      harness = cap(metaGet(meta, "harness"));
    } catch {}
    if (harness === "codex") {
      if (limit === "")
        limit = lastLine(
          grepOut("-oE", "You('|’)ve hit your usage limit.*|Selected model is at capacity\\..*|You hit your spend cap.*|is out of credits\\..*|Quota exceeded\\. Check your plan.*", tail),
        );
      if (login === "") login = lastLine(grepOut("-oE", "Your access token could not be refreshed.*|Your session has expired\\. Please reauthenticate\\.", tail));
    }
    if (limit !== "") {
      touch(st("stale"));
      statusAppend(id, `stopped on the provider usage limit: ${limit}`);
      queueWake("limited", idB, `stopped on the provider usage limit (${limit}) - it can do nothing until the reset; do not steer it`);
      return reasonLine(`limited:${idB}`);
    }
    if (login !== "") {
      touch(st("stale"));
      statusAppend(id, `stopped on an expired provider login: ${login}`);
      queueWake("needs-login", idB, `stopped on an expired provider login (${login}) - only the captain signing that harness in again unblocks it; do not steer it`);
      return reasonLine(`needs-login:${idB}`);
    }
    // COMPLETION ALREADY REPORTED: anchored silently, or the loud wake
    // re-fires every quiet window - .stale-<id> is cleared by any redraw.
    const seen = readCap(st("seen"));
    if (seen !== "" && grepQ(CAPTAIN_RE, seen) && !grepQ(DECISION_RE, seen)) {
      touch(st("stale"));
      statusAppend(id, "ended its turn after a reported completion - awaiting reap");
      return null;
    }
    touch(st("stale"));
    statusAppend(id, WATCH_ENDED_NOTE);
    routed(backendCall("mark_wait", [id, "ended its turn with no report line"], stdio));
    queueWake("ended", idB, `ended its turn ${idle}s ago with no report line - read the pane, the ask may be prose${jevNote(idB, tail)}${compactNote(id, idB)}`);
    return reasonLine(`ended:${idB}`);
  }
  // STALE DEFERRAL: the worker's word outranks the idle clock ONCE per
  // declaration - the TIMER restarts, so the same declaration a full window
  // later falls through to stale.
  const dw = declaredWait(id);
  if (dw !== null) {
    const key = dw.slice(dw.indexOf("\t") + 1);
    if (key !== readCap(st("deferred"))) {
      stamp(st("deferred"), `${key}\n`);
      stamp(changedFile, `${nowRaw()}\n`);
      watchLog(`deferred-stale:${idB} ${dw.slice(0, dw.indexOf("\t"))}`);
      return null;
    }
  }
  touch(st("stale"));
  queueWake("stale", idB, `quiet for ${idle}s with no report line${jevNote(idB, tail)}${compactNote(id, idB)}`);
  return reasonLine(`stale:${idB}`);
}

// One pass over every crew meta (self tasks skipped - a self task's pane
// holds no agent; verifiers polled - a verifier is excluded from ACCOUNTING,
// never from supervision), the first actionable pane winning.
async function checkFleet(): Promise<string | null> {
  for await (const meta of crewMetas(sd, "self")) {
    await checkpoint();
    const line = await checkPane(meta);
    if (line !== null) return line;
  }
  return null;
}

// AC_REMOTE_POLL > config/remote-poll-interval > 300 only when an executable
// config/remote-poll exists; anything not digits is 0, the slot off.
function remotePollInterval(): bigint {
  let iv = env("AC_REMOTE_POLL");
  if (iv === "") iv = configReadSoft("remote-poll-interval", "");
  if (iv === "") {
    let x = false;
    try {
      accessSync(`${configDir()}/remote-poll`, constants.X_OK);
      x = true;
    } catch {}
    iv = x ? "300" : "0";
  }
  return /^[0-9]+$/.test(iv) ? BigInt.asIntN(64, BigInt(iv)) : 0n;
}

// The same ladder for one poll's ceiling, 120 for anything that is not a
// positive integer: the ceiling is what keeps the loop alive, so there is
// deliberately no `0 = never`.
function remotePollTimeout(): string {
  let t = env("AC_REMOTE_POLL_TIMEOUT");
  if (t === "") t = configReadSoft("remote-poll-timeout", "");
  return /^[0-9]+$/.test(t) && t !== "0" ? t : "120";
}

// One poller fleet-wide: the fleet watcher whose recorded owner IS the
// session-lock holder.
function remotePollAllowed(): boolean {
  if (env("AC_WATCH_ONLY") !== "") return false;
  const owner = readCap(`${sd}/.watcher-owner`);
  let holder = "";
  try {
    holder = cap(metaGet(`${sd}/.session-lock`, "pid"));
  } catch {}
  return owner !== "" && owner === holder;
}

// A capture file the poll writes to: `<base>.<pid>` created exclusively, or
// /dev/null when it cannot be made - a redirect that cannot open would make
// the poll read as dead without ever running it.
function captureFile(base: string): { path: string; fd: number | "ignore" } {
  try {
    return exclusiveTemp(base);
  } catch {
    return { path: "/dev/null", fd: "ignore" };
  }
}

const running = (p: Subprocess): boolean => p.exitCode === null && p.signalCode === null;
const childStatus = (p: Subprocess): number => p.exitCode ?? 128 + (osConstants.signals[p.signalCode as keyof typeof osConstants.signals] ?? 0);
const seconds = (): bigint => BigInt(Math.floor(Date.now() / 1000));

// One remote poll (FAILED POLL / HUNG POLL): its reason line, or null for a
// quiet poll. FILES, not a pipe - a hook that exits while a child of its own
// holds stdout would wedge a read to EOF - and the poll's end is its own exit,
// which the ceiling can judge.
async function checkRemote(): Promise<string | null> {
  const marker = `${sd}/.remote-poll-failed`;
  const tmarker = `${sd}/.remote-poll-timeout`;
  const err = captureFile(`${sd}/.remote-poll.err`);
  const out = captureFile(`${sd}/.remote-poll.out`);
  pollErr = err.path;
  pollOut = out.path;
  const ceiling = remotePollTimeout();
  let rc = 0;
  let timedOut = false;
  let child: Subprocess | null = null;
  try {
    child = spawnShell([`${STARTED_BIN}/ac-remote.sh`, "poll"], { detached: true, stdin: "inherit", stdout: out.fd, stderr: err.fd });
  } catch {}
  for (const c of [out, err]) if (c.fd !== "ignore") closeSync(c.fd);
  if (child === null) rc = 127;
  else {
    pollChild = child;
    const began = seconds();
    // 0.2 s, not 1 s: the first check always finds the poll running, so
    // every poll pays one tick - --once wears it whole.
    while (running(child)) {
      if (test(String(seconds() - began), "-ge", ceiling)) {
        timedOut = true;
        break;
      }
      await quietSleep("0.2");
    }
    if (timedOut) {
      await reapPoll();
      rc = 124;
    } else {
      await child.exited;
      rc = childStatus(child);
      pollChild = null;
    }
  }
  const text = out.path === "/dev/null" ? "" : readCap(out.path);
  const errLine = err.path === "/dev/null" ? "" : lastLine((() => {
    try {
      return readFileSync(err.path, "latin1");
    } catch {
      return "";
    }
  })());
  dropPollFiles();
  const last = lastRid(text);
  if (rc === 0) {
    // A poll that ran to the end proves the fault over: the next death of
    // EITHER kind is loud again.
    rmF(marker, tmarker);
    if (text === "") return null;
    let first = "";
    for (const l of text.split("\n"))
      if (l.startsWith("remote-order ")) {
        first = l.split(/[ \t]+/).filter((w) => w !== "")[1] ?? "";
        break;
      }
    return `remote:${first || "unknown"}\n`;
  }
  if (timedOut) {
    // Its own prefix, wake kind and latch: a wedged transport and an
    // unwritable spool are different faults, and a shared latch would leave
    // whichever came second silent while the first stood.
    let detail = `poll exceeded ${ceiling}s and was killed; last rid ingested: ${last || "none"}`;
    if (errLine !== "") detail = `${detail} - ${errLine}`;
    if (!existsSync(tmarker)) {
      queueWake("remote-timeout", "captain", detail);
      // LATCH ON THE RECORD, NOT THE ATTEMPT.
      if (wakePublished) stamp(tmarker, "");
      watchLog(`remote poll TIMED OUT: ${detail}`);
    } else {
      watchLog(`remote poll TIMED OUT again, same episode: ${detail}`);
      if (text === "") return null;
    }
    return reasonLine(`remote-timeout:${last || "none"}`);
  }
  let detail = `poll exited ${rc}; last rid ingested: ${last || "none"}`;
  if (errLine !== "") detail = `${detail} - ${errLine}`;
  if (!existsSync(marker)) {
    queueWake("remote-failed", "captain", detail);
    if (wakePublished) stamp(marker, "");
    watchLog(`remote poll FAILED: ${detail}`);
  } else {
    // REPETITION: one durable wake per EPISODE; the rest goes to the arm log.
    watchLog(`remote poll FAILED again, same episode: ${detail}`);
    if (text === "") return null;
  }
  // A death that DID ingest part of its batch exits FAILED too, never
  // `remote:<first>`, naming the last rid that landed.
  return reasonLine(`remote-failed:${last || "none"}`);
}

// The arm SNAPSHOT: records already in this scope's spools are the chief's
// undrained backlog, never news - so a re-arm over them cannot spin. The
// fleet watcher also answers for every family spool whose roomchief is gone.
const pushSpool = wakeSpoolPath(sd, env("AC_SCOPE"));
const pushSpools = (): string[] => (wakeScopeOk(env("AC_SCOPE")) ? [pushSpool] : [pushSpool, ...wakeFamilySpools(sd)]);

// The artifact twin of PUSH ADOPT: a pushed completion's report.md is the
// SAME completion, so its hash is anchored at the exit and the artifact
// channel does not wake a second time a poll later.
function pushAdoptReport(ridB: string): void {
  const id = u8(ridB);
  let dir = "";
  try {
    dir = taskDir(id).replace(/\n+$/, "");
  } catch {
    return;
  }
  const report = dir === "" ? "" : `${dir}/report.md`;
  if (report === "" || !isFile(report)) return;
  stamp(`${sd}/.report-hash-${id}`, `${cksumFile(report)}\n`);
}

// The first record not there at arm, never CLAIMED (draining is the drain's
// alone); every new `report` record anchors its artifact.
function pushedRecord(armedRecords: Set<string>): string | null {
  let first: string | null = null;
  for (const sp of pushSpools()) {
    for (const rec of globIn(sp)) {
      if (armedRecords.has(rec)) continue;
      if (sp !== pushSpool && roomchiefLive(sd, sp.slice(sp.lastIndexOf("/.wake-spool.") + "/.wake-spool.".length), { stdin: "inherit", stdout: "ignore" })) continue;
      let line = "";
      try {
        line = firstLine(readFileSync(rec, "latin1"));
      } catch {}
      const f = line.split("\t");
      const kind = cap(f[1] ?? "");
      const rid = cap(f[2] ?? "");
      if (first === null) first = rid || "unknown";
      if (kind === "report" && rid !== "") pushAdoptReport(rid);
    }
  }
  return first;
}

// The interval wait: the ONE direct `sleep` child, the target ac-done's
// nudge kills to end the wait early - a kill aimed at it alone is absorbed,
// the loop just polls again.
async function pollWait(secs: string): Promise<void> {
  try {
    sleepChild = spawnShell(["sleep", secs], { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
  } catch {
    return;
  }
  await sleepChild.exited;
  sleepChild = null;
}

await topLevel(async () => {
  const started = arith(nowRaw());
  const remoteIv = remotePollInterval();
  let nextRemote = BigInt.asIntN(64, started + remoteIv);
  const armedRecords = new Set<string>();
  for (const sp of pushSpools()) for (const rec of globIn(sp)) armedRecords.add(rec);
  for (;;) {
    await checkpoint();
    // The push check leads the cycle: a nudged watcher exits in milliseconds,
    // before paying for a pane pass.
    const pushed = pushedRecord(armedRecords);
    if (pushed !== null) await finish(`push:${pushed}\n`);
    publishBeacon(nowRaw());
    brainFreshen();
    const pane = await checkFleet();
    if (pane !== null) await finish(pane);
    if (once) {
      // At most one poll per checkpoint, and only after a quiet pass. The
      // beacon stays fresh: the checkpoint counts as coverage.
      if (remoteIv > 0n && remotePollAllowed()) {
        const r = await checkRemote();
        if (r !== null) await finish(r);
      }
      await finish("check:quiet\n");
    }
    if (remoteIv > 0n && test(nowRaw(), "-ge", String(nextRemote))) {
      nextRemote = BigInt.asIntN(64, arith(nowRaw()) + remoteIv);
      if (remotePollAllowed()) {
        const r = await checkRemote();
        if (r !== null) await finish(r);
      }
    }
    if (test(String(minus(arith(nowRaw()), started)), "-ge", knob("AC_HEARTBEAT", "600"))) await finish("heartbeat\n");
    await pollWait(knob("AC_POLL", "15"));
  }
}, true);
