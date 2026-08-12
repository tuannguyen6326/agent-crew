#!/usr/bin/env bash
# ac-watch.sh - zero-token fleet watcher for any backend.
#
# Usage: ac-watch.sh [--once | --release <pid>]
#
# Polls every crewmate pane on an interval, absorbs benign activity in bash,
# and only surfaces ACTIONABLE events: a captain-relevant report line
# (AC_CAPTAIN_RE), a stage report.md appearing or advancing (the ARTIFACT
# CHANNEL below), a vanished window, or a stalled-quiet pane. Actionable
# events are published durably (ac_wake_publish: one record per file, atomic
# ln) to the wake spool OF THIS WATCHER'S SCOPE and the watcher EXITS with a
# one-line reason on stdout, so a harness running it as a background task
# gets woken exactly once per actionable event batch.
#
# ARTIFACT CHANNEL (watch-artifact-wake). A stage's report.md is a completion
# in its own right, so it wakes the chief with NO pane cooperation at all: a
# scout that printed no marker, or one whose marker was deduped or consumed by
# another watcher, is detected within a poll instead of at the next turn
# boundary (which is all ac-wake-drain.sh's report_completions can do - that
# PULL half stays exactly as it is, this is the PUSH half). The report path is
# ac_task_dir's, so the flat/nested layout stays ac-brief.sh's contract and is
# never guessed here; a task whose data dir is ambiguous is simply not
# reported. Dedup is by CONTENT hash (state/.report-hash-<id>, the artifact
# twin of the pane tail's .hash-<id>), never mtime: a touched-but-identical
# report is not new work, while a revision that rewrites it wakes again. That
# hash has a second writer - the push exit anchors it (the PUSH CHANNEL's
# artifact arm below), so a completion announced on BOTH channels wakes once. It
# files through queue_wake like every other wake (kind `report`, payload
# naming the file), so scope routing is unchanged. PLACEMENT: it sits between
# the marker branch and the stale branch, and the marker branch FALLS THROUGH
# to it instead of `continue`ing - a marker that was already seen must not
# suppress the artifact, which is the whole point of a second channel.
# BUSY GUARD (watch-artifact-wake-debounce), the one thing standing between
# "a revision wakes again" and a WAKE STORM. That sentence assumed a revision
# is ONE atomic rewrite; a real agent revising a long report writes it MANY
# times, and every write is a new content hash. Measured on the live case that
# named this behavior: 174 write-ops to one design report.md, 57 of them inside
# the 25-minute window in which the chief's watcher re-armed ~15 times - at a
# 15s poll the report changed on essentially every poll, so the chief paid a
# drain, a re-arm and a turn PER EDIT, every one a no-op with the scout
# mid-sentence. The dedup was never at fault (held-constant repro: a byte-stable
# report over 5 polls wakes 0 times, 5 rewrites wake 5 times), and neither was
# the fleet/scoped double-watch (.report-hash-<id> hangs off ac_state_dir, which
# is scope-INDEPENDENT, so both watchers share it and one advance still wakes
# exactly once - only WHICH spool it lands in is a race, the pre-existing
# wake-steal the AC_WATCH_SKIP revalidation below already documents).
# The discriminator is the one the three sibling branches already use, at no new
# cost: a report only ever changes while an agent is WRITING it, so a pane
# matching AC_BUSY_RE is writing the very file we would wake the chief to read,
# and the pane channel already covers a live agent. While the tail reads busy
# the artifact wake is DEFERRED and the pass stamps NOTHING - the same discipline
# as SUPERVISING-CHIEF QUIET below ("a suppressed pass touches NO .stale-<id>") -
# so the first quiet poll wakes ONCE, carrying the report as it FINALLY stands.
# A revision round therefore costs one wake instead of one per edit.
# It FAILS TOWARD WAKING, which is the direction this whole channel is built to
# fail in: the appear-case this channel EXISTS for - a scout that crashed or
# finished without printing a marker - leaves a SILENT pane and wakes on the very
# next poll, unchanged; and a harness whose tail carries no busy marker at all
# is bit-for-bit today's behavior. RESIDUAL, stated rather than hidden: a pane
# that reads busy forever never earns its artifact wake. That is not new - the
# MARKER RE-WAKE and stale branches carry the identical residual under the
# identical predicate - and a pane that is busy forever is a live agent, which
# is precisely what the pane channel supervises.
#
# MARKER RE-WAKE (watch-marker-rewake). A pane that re-announces the SAME
# marker string is deduped by state/.seen-<id> - but only while the pane has
# stood still. Re-announcing it AFTER doing new work is new news, and it is the
# shape of every gate loop past round 1: the crewmate revises and prints a
# byte-identical `done:`, which the raw .seen-<id> dedup swallowed until the
# next turn boundary. The discriminator is the pane-tail hash recorded AT THE
# MOMENT OF THE WAKE (state/.seen-hash-<id>, written wherever the marker branch
# queues its wake): differs from the current tail hash and the pane is not busy
# (AC_BUSY_RE) => the pane demonstrably moved since the chief was told, so it
# wakes again. Cost is that one state file - no extra capture, no backend call.
# .seen-<id> semantics are unchanged, and the AC_DECISION_RE re-stamp reconcile
# still wins the pass it fires on (a re-wake follows on the next poll if the
# pane keeps moving).
#
# ENDED-TURN LOUD WAKE (watch-idle-loud-wake). A pane past AC_STALE with no
# marker is TWO different situations, and one stale: signal for both is why
# chiefs learn to discount it: a pane merely quiet while WORKING (soft news,
# keeps stale:) versus a pane that ENDED ITS TURN (it is done talking and
# waiting on the chief, with nothing AC_CAPTAIN_RE can see - the live case was
# an implement crewmate raising a real chief decision as PROSE inside a long
# summary, twice, looking exactly like a crewmate working). The discriminator
# is the backend's own agent status, the same field the ask path already reads
# (backend_agent_idle, herdr's idle|working|blocked|unknown - only `idle` is an
# ended turn), so it costs one backend call per stale episode. An ended turn
# exits `ended:<id>` instead of `stale:` and stamps the pane BLOCKED through the
# advisory backend_mark_wait path the marker branch uses (a stamp failure never
# blocks the wake). Everything else is bit-for-bit today's behavior: the reader
# FAILS CLOSED (unreadable pane, missing handle, any non-idle status => stale:),
# the .stale-<id> dedup marker and BOTH chief suppressions (ac_chief_gate_parked
# and SUPERVISING-CHIEF QUIET below) cover both paths, and a busy pane never
# reaches either. So this is a CREWMATE net: a chief supervising a live crewmate
# is quiet on this arm too, and SUPERVISING-CHIEF QUIET argues why.
#
# COMPLETION ALREADY REPORTED (stale-signal-costs-a-hard-wake). The one ended
# turn that goes QUIET, not loud: a pane whose .seen-<id> holds an already-
# reported chief-facing completion (done/failed/paused/merged - an AC_CAPTAIN_RE
# match that is NOT a captain-wait marker). Its report: wake fired when the
# marker was fresh; the marker has merely scrolled past the bounded 25-line tail,
# so the pane now reads as a bare ended turn. Re-firing ended: there is the bug
# this closes - .stale-<id> is cleared by every cosmetic TUI redraw, so the loud
# wake re-armed every quiet window forever. Such a pane is anchored SILENTLY
# (touch .stale-<id> + a status note, no wake), the same once-only shape as the
# push-channel anchor. The memory is DROPPED the moment the pane is seen BUSY
# again (a re-task busies it, and once its completion marker has also scrolled
# out the .seen-<id> is cleared), which re-arms the loud net for genuinely-new
# prose-only work. Completion-class ONLY: a captain-wait marker parks the pane
# BLOCKED and is handled by the ask path, never here.
#
# SUPERVISING-CHIEF QUIET (watch-chief-child-quiet). `stale` is documented as
# the SOFT signal, but a wake IS this watcher's EXIT - so a merely-quiet pane
# terminates it exactly like report:/gone:/ask: do and costs the chief the full
# hard-wake cycle: drain, peek, ack, RE-ARM. On a <fam>-chief quiet BECAUSE its
# own crewmate is working, that cycle buys nothing - supervising is the one
# thing a roomchief is supposed to be doing while a family task flies, and the
# crewchief paid this churn every few minutes for a whole session on chief panes
# doing exactly what they should. So a <fam>-chief with at least one LIVE family
# task (ac_chief_child_live: a meta other than its own chief pane whose
# membership is decided AUTHORITATIVELY and never by an id prefix - ac-lib.sh's
# CHIEF-QUIET block owns that rule - and whose backend window is alive, the same
# pair ac_roomchief_live reads for the chief itself) produces NO WAKE ON THIS
# ARM AT ALL - neither stale: nor ended:.
# It is ac_chief_gate_parked's TWIN, at the same rung: that one suppresses a
# chief parked at the CAPTAIN (unanswered GATE:/ASK:), this one a chief parked
# at its CREWMATE, and both answer a LIVE question, not a remembered marker.
# THE RE-TRIP is why the live-state form is required and not merely tidy: the
# .stale-<id> dedup marker is removed by ANY pane-content change, and a
# supervising chief produces content between waits (its own turn output), so the
# marker cleared and the IDENTICAL non-news re-tripped on the next quiet window
# - acking it never settled it. A predicate re-asked every poll has nothing to
# re-trip: no wake is emitted, so there is no dedup for a pane change to undo.
# BOTH ARMS, and this REVERSES watch-idle-loud-wake's original "`ended:` stays
# loud however busy the family is" (ended-wake-refires-on-a-prose-reporting-
# chief). What the reversal closes is a RULE CONFLICT, not a missing case: the
# roomchief charter injected into every chief prompt (bin/ac-spawn.sh:1018, and
# AGENTS.md section 8) ORDERS the chief to keep AC_CAPTAIN_RE marker verbs out of
# its room and pane prose, while the ONE quiet path an ended turn had -
# COMPLETION ALREADY REPORTED above - REQUIRES exactly such a marker in
# .seen-<id>. A chief that OBEYS its charter has no .seen-<id> at all, so it
# never qualified; and .stale-<id> is cleared by any pane change, the chief's OWN
# ack output included. So the loud wake re-armed every AC_STALE window for the
# whole life of the family - the same churn the stale arm above was narrowed for,
# every one a full hard-wake cycle with nothing to act on - and obeying the
# charter was what GUARANTEED it.
# Hence ac_chief_child_live sits at ac_chief_gate_parked's rung, guarding it.
# BOTH predicates are SHARED, defined in ac-lib.sh's CHIEF-QUIET block, because
# the wake this arm declines is also a notice ac-wake-drain.sh's idle fallback
# would otherwise resurrect from the .change-<id> stamp THIS watcher wrote (that
# block owns the second consumer's reasoning).
# Deliberately narrow otherwise:
#  - The CREWMATE net the loud wake was BUILT for is UNTOUCHED. Its live case is
#    a crewmate pane (an implement crewmate raising a real chief decision as
#    PROSE inside a long summary), and ac_chief_child_live returns false for
#    every non-chief id, so a crewmate still wakes loudly at the DEFAULT
#    threshold.
#    The asymmetry that justifies the split: a CREWMATE's pane is its ONLY
#    channel to its chief, while a ROOMCHIEF's are DURABLE by charter - it
#    reports back with ac-room.sh handback, which posts the room record AND
#    queues a durable wake (bin/ac-spawn.sh:1018, "never rely on a pane line
#    alone") - and a captain-facing GATE:/ASK: is the room's, already covered by
#    ac_chief_gate_parked.
#  - RESIDUAL, stated rather than hidden: a chief that ends its turn on a
#    prose-only ask for the CREWCHIEF while its own crewmate still flies is
#    DEFERRED, not swallowed. The suppressed pass stamps nothing, so the first
#    poll after the family stops flying wakes it - loudly, if it is still idle.
#    Its durable channel is the one to use meanwhile, which is what the charter
#    already tells it.
#  - Non-chief ids never reach it (the *-chief case gate returns first), and
#    report:/gone:/ask:/push:/heartbeat, AC_STALE itself and the busy guard are
#    untouched.
#  - It FAILS TOWARD WAKING, on both arms. A suppressed pass touches NO
#    .stale-<id>, so the first poll after the last family task dies emits
#    ended:/stale: with nothing consumed; and a child whose window cannot be
#    probed reads NOT live, which is the direction ac_roomchief_live already
#    fails in.
#
# PUSH CHANNEL (agent-done-push). The watcher is the BACKUP; a finished agent
# announces itself (bin/ac-done.sh, which owns the push contract) and the chief
# wakes in tens of milliseconds instead of at the next tick. The agent PUBLISHES
# its record into this scope's spool and then kills this watcher's poll `sleep`
# CHILD - behavior poll_wait already documents ("A kill aimed at the sleep CHILD
# alone just ends the wait early"), used here, not built. Ending the wait alone
# would only poll SOONER, and a wake IS this watcher's EXIT, so a record in the
# spool is an exit condition in its own right: the check sits at the TOP of the
# cycle (before the beacon and the poll pass) so a nudged watcher exits at once
# without paying for a pane pass, and exits `push:<id>`. The two hazards that
# creates are closed here:
#  - RE-ARM SPIN. A chief re-arms while a record it has not drained is still in
#    the spool. That record is NOT news to a fresh watcher, and exiting on it
#    would exit instantly, forever. So the arm SNAPSHOTS the record names it
#    finds and only a name outside that snapshot is a push (records are named
#    once and never renamed in place - ac-lib.sh's store contract - so the
#    snapshot cannot go stale under a live watcher). A `--once` checkpoint
#    snapshots the same way and therefore never reports a push: its caller
#    drains.
#  - DOUBLE-PUBLISH. The pane carries the same completion, so the poll that
#    follows a push would read the marker and publish a SECOND record. The
#    EXISTING dedup markers absorb it, with no new state file: ac-done.sh
#    stamps .seen-<id> with the marker text (marker_seen below also accepts the
#    pane's TUI-glyph rendering of that same line, which the agent cannot know
#    to include) and REMOVES .seen-hash-<id>, whose absence the re-wake branch
#    reads as PUSH ADOPT - the wake for this marker came from the other channel,
#    so the first non-busy poll anchors the pane hash SILENTLY instead of
#    treating a missing discriminator as movement. The re-wake channel is
#    anchored by that, never disabled: a pane that does new work and re-prints
#    the marker still wakes.
#    Dedup alone is not enough, because the `seen` read is STALE by the time
#    the branch publishes - the status append and a BACKEND call sit between
#    them, tens of ms in which the agent can announce the same completion, and
#    a push landing THERE produced two records. So the branch RE-READS the
#    stamp immediately before publishing and stands down when it is no longer
#    its own write and still covers the marker. That is sound because
#    ac-done.sh stamps BEFORE it publishes: a foreign stamp means the record
#    exists or is one syscall away. RESIDUAL, stated rather than hidden: a push
#    that stamps between that re-read and our own `ln` still duplicates - a few
#    syscalls wide instead of a backend round trip. Exactly-once across two
#    lock-free producers needs an atomic test-and-set the wake store does not
#    offer (its `ln` is keyed by producer-unique name, not by completion), and
#    a duplicate wake costs the chief one drained line while a LOST one costs a
#    stranded crewmate - so the trade is deliberate in that direction.
#  - DOUBLE-PUBLISH, ARTIFACT ARM. An agent that finishes writes its report.md
#    too, and that third stamp (.report-hash-<id>) has no agent-side twin: a
#    crewmate has no AC_HOME (ac-spawn.sh strips it), so ac-done.sh cannot even
#    resolve where report.md lives. The EXIT closes it instead - push_adopt_report
#    below anchors the hash to the report as it stands at the moment of the push
#    exit, so the completion the chief is about to drain does not wake it a
#    second time off the artifact channel one poll later. Same shape as the pane
#    adopt, same direction of failure: an unanchored push (no watcher armed to
#    exit) still wakes twice rather than risking a lost wake.
# Nothing else in the wait loop changes: with no push, the poll interval and
# every existing exit behave exactly as they did.
# ROLLOUT: the push channel lives in the watcher PROCESS, so a watcher armed
# BEFORE this change has neither the loop-top check nor marker_seen. Such a
# watcher exits `report:<id>` off the pane and, comparing markers byte-exactly,
# files its own record beside the pushed one - two records for one completion,
# and .seen-<id> overwritten with the captured line (observed live 2026-07-20,
# and expected: nothing was wrong with the push, the process simply predates
# it). Nothing is LOST in that state; re-arming the watcher on this code is the
# whole remedy.
#
# STALE-STAMP SUPERSESSION (send-guards-own-marker-verbs). DEMONSTRATED LATER
# PROGRESS SUPERSEDES AN UNANSWERED MARKER. A captain-wait marker writes a
# DURABLE state/<id>.status line and every fleet view renders the NEWEST one
# (ac-fleets.sh, ac-crew-state.sh), so a crewmate that is demonstrably WORKING
# kept reporting `blocked` in every view until a human steered it - and the
# marker that parked it can be one the pane never meant (a chief's own steer
# text, the write-side guard's case at ac-send.sh). Fixing it HERE, at the
# source, makes every renderer and the herdr UI stamp correct at once with no
# renderer change - ac-fleets.sh must stay probe-free, so it cannot decide this
# itself. The EVIDENCE is disk + tail, both already in hand each poll: the pane
# matches AC_BUSY_RE while this fleet's own stamp file (state/.captain-wait-<id>,
# ac-backend.sh's CAPTAIN-WAIT STAMP) still stands - a genuinely parked pane has
# ended its turn and matches no busy pattern. On that evidence the watcher
# appends a superseding status line (`working: superseded <marker>`, which
# matches no AC_CAPTAIN_RE itself) and releases the stamp. NO wake: the chief is
# told nothing new. The stamp file's own removal is the once-only guard.
# It FAILS TOWARD KEEPING THE STAMP - no evidence of progress (watcher down,
# pane quiet, marker scrolled out) leaves the marker standing, because a false
# `superseded` hides a real captain-wait, the worse error.
# OSCILLATION, the subtle half: the Reconcile branch below re-stamps an
# already-seen captain-wait marker still sitting in the tail the moment the pane
# reads non-busy, which would re-park the pane supersession had just freed. So
# the superseded marker TEXT is recorded durably (state/.superseded-<id>) and
# Reconcile skips a match. That record covers ONE marker, never the pane: a NEW
# marker clears it and parks the pane again. RESIDUAL: a pane that re-prints a
# BYTE-IDENTICAL captain-wait marker after real work is not re-stamped (the
# marker is not new), but it still wakes the chief through MARKER RE-WAKE above
# - the wake, not the stamp, is what the chief acts on.
#
# Render-wrap hazard: a marker token that appears in PROSE/narrative (not as a
# real status line) can soft-wrap to visual column 0 and false-match
# AC_CAPTAIN_RE - the mitigation is author discipline (the marker-verb rule in
# CREWMATE.md and the roomchief charter), which complements the REAL-marker-wrap
# Residual note at ac-lib.sh (AC_CAPTAIN_RE definition) rather than duplicating it.
#
# ARMING CONTRACT: the wake IS the harness's notification on this watcher's
# EXIT, so it MUST be armed as the harness's OWN background task - the harness
# runs it, tracks it, and is woken by its exit. NEVER shell-background it
# (nohup/&/disown) inside a tool call: the harness then tracks the wrapper
# (which returns instantly), the watcher is orphaned, and its exit reason wakes
# no one - silently degrading it from real-time eyes to a note found only at
# the next turn boundary.
#
# Wake routing (ac-lib.sh owns the keying): a wake is filed for the CONSUMER
# that must act on it - the fleet watcher publishes to state/.wake-spool/,
# while a promoted family's watcher (AC_SCOPE=<fam>, inherited from the
# roomchief) publishes to state/.wake-spool.<fam>/, which only that roomchief
# drains. This changes only WHERE a wake is filed, never WHEN one is
# produced. A scoped watcher likewise stamps its OWN beacon,
# state/.last-watcher-beat.<fam>.
# Scope-containment reconciliation (applies to --once too, which files wakes
# just like an armed watcher): with a valid AC_SCOPE set, AC_WATCH_ONLY must
# CONTAIN AC_SCOPE. AC_WATCH_ONLY == AC_SCOPE is the single-family case;
# AC_WATCH_ONLY holding AC_SCOPE plus extra entries is an epic roomchief
# watching its in-flight story families too (their ids, from ac-ready.sh
# watch-set), so a story crewmate's pane-poll backup routes to the epic's
# spool not the fleet's (epic-roomchief-watch-only-omits-story-ids). An
# AC_WATCH_ONLY that does NOT contain AC_SCOPE is REFUSED (exit 2), since the
# family's wakes would land under a key nobody drains; and AC_WATCH_ONLY UNSET
# is DEFAULTED to AC_SCOPE. AC_WATCH_ONLY and AC_SCOPE are not equal by
# construction (AC_SCOPE is real launch env, AC_WATCH_ONLY is prompt text the
# roomchief types), and undefaulted that case watches every pane fleet-wide
# while filing every wake to one family. A malformed AC_SCOPE is exempt: it
# routes to the fleet spool, so such a watcher is a fleet watcher.
#
# Exit reasons: `report:<id>` (a pane marker, or the artifact channel above -
# the payload says which), `push:<id>` (the PUSH CHANNEL above - an agent
# published its own completion), `gone:<id>`, `unobservable:<id>` (the BACKEND
# could not be read, so the pane's liveness is UNKNOWN - never a death: no
# failure is stamped, the pane keeps being polled, and one outage costs one wake
# and one status line; contract: ac-backend.sh WINDOW LIVENESS), `ask:<id>` (agent blocked on an
# interactive prompt - herdr backend only), `ended:<id>` (the ENDED-TURN LOUD
# WAKE above - a pane that finished its turn with no marker), `stale:<id>`
# (a pane merely quiet while working). Neither of those two is ever a chief
# supervising a live crewmate, see SUPERVISING-CHIEF QUIET above. `remote:<rid>`
# (new remote captain orders arrived), `heartbeat`, `signal:<NAME>` (a TERM/INT
# - either the owner's own `--release`, see OWNER-MARKED RELEASE, or a kill
# from outside, see EXTERNAL KILLS; the reason text says which). Every one of
# them exits 0: the reason line, not the exit status, is the payload the chief
# reads.
# With --once it does a single bounded pass (Codex-style checkpoint), and with
# --release <pid> it releases ONE named watcher and exits without arming.
# A captain-wait marker (AC_DECISION_RE: needs-decision:/blocked: and the
# delivery-await checks-passed:) also stamps the pane BLOCKED in the herdr UI until
# the answering ac-send, a later non-decision marker, or the STALE-STAMP
# SUPERSESSION above clears it; a pane still parked on an already-seen
# captain-wait marker with no stamp is reconciled silently each pass (busy and
# superseded panes exempt) - contract: ac-backend.sh CAPTAIN-WAIT STAMP.
#
# OWNER-MARKED RELEASE (`--release <pid>`). The distro's OWN way to stop a
# watcher: it writes state/.watcher-release-<pid> (releaser pid, target pid,
# reason=config-swap, epoch) and THEN sends `kill -TERM <pid>` to that one pid,
# so intent and signal can never drift apart. The exiting watcher whose pid the
# marker names logs and prints `config-swap by owner (released by pid=<n>)`
# instead of `watcher killed externally`; nothing else about the exit changes -
# same reason-line shape, same lock release, same beacon stand-down, exit 0.
# This exists because ONE template labelled EVERY TERM `killed externally`,
# which made the crewchief's own config-swap release (read the live pid, TERM
# it, `sleep 1`, re-arm a different AC_WATCH_SKIP - exactly what the refusal
# below prescribes) indistinguishable from a hostile kill, and cost two
# families four days of false investigation (2026-07-19/20).
# The marker is COOPERATIVE, not authenticated: it separates this distro's own
# release from everything else and claims nothing stronger. Three bounds keep
# it from becoming a SILENCER: it is keyed by TARGET pid (it can quiet only the
# one process it names), it is valid for 30s from its epoch (the real gap is
# the idiom's `sleep 1` plus a trap bash defers to the end of a running poll
# pass), and it is CONSUMED on the first signal that reads it - stale, unmatched
# or missing, the `killed externally` wording stands byte for byte. A release
# whose TERM cannot be delivered withdraws its own marker. Releaser and target
# share one AC_HOME by construction (the marker lives in state/).
# SCOPED TARGETS (watcher-release-scope, 2026-07-21): only the FLEET watcher is
# releasable this way. A SCOPED watcher (AC_WATCH_ONLY, armed by a roomchief)
# BELONGS to that roomchief - releasing it leaves its family with no real-time
# crash/blocked detection until the roomchief notices and re-arms. So a target
# pid recorded under a SCOPED lock (state/.watch-only-<fam>.lock.d/pid - the
# lock is the authoritative record of a watcher's target, since its suffix
# already partitions scoped watchers from the fleet one, while the arm log is
# trimmed and the beacon carries no pid) is REFUSED (exit 2, on stderr) BEFORE
# the marker is stamped, so a refused release leaves NO trace on the watcher it
# declined to touch. This is the code half of a behavior the crewchief already
# corrected: its config-swap loop read every ac-watch pid and released each,
# reaping roomchiefs' scoped watchers with the fleet one - seven re-arms in a
# single session (2026-07-21). No wake was lost (ac-done.sh publishes durably),
# but the real-time gap was real. There is no override knob: nothing in this
# distro releases a scoped watcher - teardown/demote let it exit on its own
# heartbeat - and a knob nobody needs is just the mistake with one more step.
# The refusal covers the whole UNIT, not just the watcher pid
# (watcher-release-wrapper-orphan, 2026-07-21): the harness arms a watcher
# inside a WRAPPER shell it tracks (`chain=<watcher>(bash) < <wrapper>(zsh) <
# ...`), and a release aimed at that wrapper TERM'd the tracked parent while
# the guard spared the watcher - which survived reparented to PPID=1, still
# polling but with an exit that wakes no one, the very orphan the ARMING
# CONTRACT above forbids (observed live: wrapper 67124 released, scoped watcher
# 67150 refused and orphaned). So a target pid that is the DIRECT PARENT of a
# pid under a scoped lock is refused the same way, with the same no-trace rule.
# The fleet watcher and its wrapper stay releasable.
# HOME-CROSSING TARGETS (watcher-release-crosses-home-boundaries, 2026-08-05):
# the scoped guard above stops nothing outside the caller's OWN home - a pid
# recorded under NO lock in this home's state dir fell straight through to
# `kill -TERM`, so --release could TERM a pid belonging to a DIFFERENT
# fleet's home with no check at all (real incident: an operator pattern-
# matched the process list for "a" watcher pid and released it by exact
# number; every home on the box runs the same command line, so the pid could
# have been this home's watcher or another fleet's, and it was gone before
# either could be proven). So --release now refuses ANY target that is not
# THIS home's own fleet-watcher UNIT - the pid recorded in
# $state_dir/.watch.lock.d/pid, or its direct parent (the wrapper, same unit
# as above) - REFUSED (exit 2, on stderr) BEFORE the marker is stamped, same
# no-trace rule. This home having no fleet watcher armed at all (no lock, no
# pid file, empty or non-numeric contents) refuses too - fail CLOSED, never
# fall through to the kill for want of our own record. As with the scoped
# guard, there is no override knob: nothing in this distro has any business
# releasing another home's watcher, so no caller exists to need one.
#
# EXTERNAL KILLS. Something outside the fleet SIGTERMs long-idle watchers
# (10 observed on drydock 2026-07-15/16, ~10-20min apart, landing on the poll
# `sleep`); nothing in this distro sends them - a TERM that reads `killed
# externally` is one no owner marked. Two guarantees answer that:
#  - TERM/INT are TRAPPED: the watcher prints ONE `signal:<NAME> pid=<n>
#    target=<t> - <reason>` line and exits cleanly, so its EXIT trap releases
#    the lock.
#    Untrapped, a non-interactive bash dies by the signal's DEFAULT
#    disposition and NEVER runs its EXIT trap - that leaked the lock dir.
#    The poll wait is therefore a BACKGROUND `sleep` + `wait`, not a
#    foreground `sleep`: bash defers a trap until the foreground child
#    finishes, and the trap has to fire where the kills actually land.
#    A kill aimed only at the sleep CHILD is absorbed - the loop just polls
#    again, and the watcher survives.
#    TERM is the one that carries this: an ARMED watcher is a background task,
#    and a shell backgrounding a job without job control must set SIGINT to
#    SIG_IGN in it (POSIX) - a signal ignored on entry can never be trapped,
#    so an armed watcher never sees INT at all. The INT trap is for the
#    FOREGROUND shapes (a hand-run watcher, `--once`, Ctrl-C), where it
#    releases the lock just the same.
#  - Arming logs one ATTRIBUTION line (pid + parent chain + poll target) to
#    state/.watcher-arm.log and stderr - never stdout, which carries the exit
#    reason alone - and the signal line joins it there, so the next kill is
#    attributable to a NAMED ancestor instead of a bare pid. A FAILED wake
#    publish joins it there too (`wake-publish FAILED ...`): the dedup marker
#    has already advanced by then, so the loss would otherwise be traceless -
#    the reason line still prints and wakes the chief once, only the durable
#    record is missing. The log is bounded (trimmed to AC_ARMLOG_KEEP lines).
#
# Remote-order slot: on the poll interval the loop runs `ac-remote.sh poll`
# (poll queues the wakes durably itself; the watcher then exits
# `remote:<first-rid>` so the chief drains at once). Interval resolution:
# AC_REMOTE_POLL env > config/remote-poll-interval > 300; the 300 default
# applies only when an executable config/remote-poll hook exists - no
# transport, no slot - and a non-numeric or 0 value at any layer turns the
# slot off. LOCK GATE (one poller fleet-wide): the slot runs
# ONLY in the fleet-scoped watcher (no AC_WATCH_ONLY) whose recorded owner
# (state/.watcher-owner) IS the session-lock holder (state/.session-lock
# pid=); scoped roomchief watchers and foreign-lock homes NEVER poll.
# --once runs at most one poll (same gate), after a quiet pane pass.
#
# IDLE MODE (standing remote coverage): zero crew in flight is NOT an exit
# condition. With the remote slot live (interval on, executable
# config/remote-poll hook, and this watcher passing the lock gate above),
# an idle fleet watcher stays up - beating the liveness beacon and running
# the remote poll slot on its interval, absorbing nothing else - so remote
# orders keep flowing while the fleet is parked; a new order exits
# `remote:<rid>` exactly as with crew in flight, and a crewmate spawned
# mid-idle is picked up on the next pass. Zero crew with no remote slot
# idles the same loop with nothing to do (unchanged). Either way
# AC_HEARTBEAT still bounds the loop (exit `heartbeat`); the turn-end
# guard's standing-coverage rule (ac-turnend-guard.sh) is what keeps a
# watcher armed over an idle remote-wired fleet.
#
# Singleton: state/.watch.lock.d (scoped watchers take their own suffixed
# lock). ac-lib.sh's lock block is the authoritative spec for what makes a
# lock STALE and reclaimable; both shapes an external kill leaves - a dead
# owner pid, and a dir whose pid file was never published - are reclaimed, so
# a killed watcher can never wedge the re-arm at `already running` while
# NOTHING watches the fleet (the confirmed 2026-07-16 failure). A LIVE owner
# refuses an IDENTICAL second arm (exit 0 `already running`, idempotent) - with
# ONE exception, because `already running` is a statement about NOW and a chief
# arming by hand is asking about its next TURN END. An arm ac-watch-autoarm.sh
# owns carries AC_AUTOARM and records it in its own lock dir ($lock/autoarm,
# retired with the lock): that watcher is BOUNDED - it lives in the foreground of
# one Stop-hook firing and dies with it at the budget handback - while a hand arm
# is a harness background task and is not. So a HAND FLEET arm over a marked
# incumbent REFUSES LOUDLY (exit 2) instead of reporting coverage it does not
# own, naming that pid and the single-target release; a HOOK arm over the same
# incumbent, a SCOPED arm (--release is fleet-only, and a family's panes are
# re-covered by the fleet watcher's skip revalidation), and any arm over an
# unmarked (durable) incumbent all stay idempotent `already running`.
# Measured 2026-08-06 with per-process stamps: hand arm `already running` at T+0
# with the incumbent live -> its stand_down_beacon at T+2.513s -> the hook's
# budget handback at T+2.536s -> the turn-end guard blocking at T+2.602s. The
# discriminator is OWNERSHIP, never a beacon state: the incumbent is beating
# normally at arm time (behavior: rearm-stands-aside-for-a-watcher-that-then-exits).
# But a second arm carrying a DIFFERENT watch-config than the running singleton
# must WIN, never silently no-op leaving the stale config in charge: the arm
# that acquires records its AC_WATCH_SKIP to state/.watcher-config[<suffix>],
# and a second arm that finds the lock held compares configs - same config
# stays idempotent, a DIFFERING config REFUSES LOUDLY (exit 2, naming both)
# so the caller releases the stale watcher (`--release` frees its lock cleanly,
# above) and re-arms the corrected config. AC_WATCH_ONLY needs no compare here:
# the lock suffix already partitions scoped watchers onto separate locks.
# NAMED RELEASE TARGET: that refusal names the RUNNING watcher's pid (read from
# the lock dir) and prints the exact single-target command
# (`bin/ac-watch.sh --release <pid>`, the OWNER-MARKED RELEASE above - so the
# remedy and the log that release produces agree), and states that a pattern
# kill is never the mechanic. A remedy naming no target and no command is what
# drove operators to improvise `pkill -f ac-watch`
# (observed 2026-07-14/15, one of them self-reported as having reaped ANOTHER
# session's scoped watcher) - and because every home on a box runs the same
# command line, such a kill crosses home boundaries and reaps every fleet's
# watcher at once. ac-watch-policy-hook.sh denies those patterns for sessions
# rooted in THIS repo; sessions rooted elsewhere are unguarded, so this message
# is the only barrier they get.
# Liveness beacon: state/.last-watcher-beat[.<fam>] (epoch secs, refreshed
# every poll - see the scope note above); the turn-end guard treats a stale
# beacon as "watcher down". On EXIT the watcher STANDS ITS BEACON DOWN (writes
# 0 = stale), so a fresh beat can never outlive the process that made it: an
# armed watcher's exit always wakes the chief, and without the stand-down a
# just-exited heartbeat left a deceptively-fresh beacon that let the turn-end
# guard read "covered" and allowed the chief to PARK - after which no turn
# boundary recurs and the fleet goes deaf (idle-chief-deaf, 2026-07-18). Stood
# down, the guard blocks that post-exit turn and forces a re-arm. BOTH writes go
# through publish_beacon (tmp + rename): a truncate-in-place write is readable as
# an EMPTY file mid-flight, and every consumer computes `now - beat`, so an empty
# read renders the raw epoch as an age - observed live 2026-07-27 with this
# watcher beating 1s earlier. ac_watcher_beat_read (ac-wake-lib.sh) is the reader half
# and owns what each no-beat state means.
# Owner gate: arming the FLEET-scoped watcher runs `ac-lock.sh acquire` -
# idempotent for the home's lock-holding session (and claims an unlocked
# home for the arming session), but a live foreign holder REFUSES the arm
# (prints `refused: ...`, exit 2). The holder pid is recorded to
# state/.watcher-owner beside the beacon. Scoped watchers (AC_WATCH_ONLY)
# and --once checkpoints are exempt.
#
# Scoping (design C): AC_WATCH_ONLY=<fam1,fam2> watches only those
# families' ids (<fam> and <fam>-*; a promoted roomchief watches its own
# family this way, and an EPIC roomchief adds its in-flight story families -
# ids that share no prefix with the epic - via ac-ready.sh watch-set);
# AC_WATCH_SKIP=<fams> ignores them (the fleet watcher skips promoted
# families). Scoped watchers take their own lock.
# The <fam>-chief pane is NOT a family member: it reports to the FLEET
# (its hand-back must wake the crewchief), so family scoping excludes it
# - ONLY=<fam> never self-watches the chief, SKIP=<fam> never hides it.
# A STORY crewmate's pane matches its epic's SKIP by neither id rule (its id
# shares no prefix with the epic); the fleet matches it by the pane's meta
# fleet_scope (the epic, recorded at spawn) instead, and revalidates coverage
# against that EPIC - so a story pane the epic roomchief owns is skipped while
# the epic's scoped coverage is live and re-covered when it dies, exactly like
# an epic's own pane (behavior: epic-roomchief-watch-only-omits-story-ids).
# AC_WATCH_SKIP is REVALIDATED every poll: the skip exists ONLY because the
# family's OWN scoped watcher covers it, so a skip is honored only while that
# coverage is LIVE - the <fam>-chief is live (meta + window) AND the family
# beacon state/.last-watcher-beat.<fam> is fresh (younger than AC_GUARD_GRACE,
# the turn-end guard's own bound). A GONE roomchief (meta/window) REVOKES the
# skip that poll: the fleet watcher covers the family's panes directly and logs
# the takeover once, until the scoped watcher (or teardown) is back. This is the
# watcher-skip-staleness fix (2026-07-18: a scoped watcher died, its family
# went ZERO-covered because the fleet trusted the skip forever). RE-ARM GRACE
# (roomchief-scoped-watcher-blindness, 2026-07-19): a LIVE roomchief with a
# merely-stale beacon is almost always mid re-arm - its scoped watcher
# heartbeat-exits every AC_HEARTBEAT and STANDS ITS BEACON DOWN (below), and the
# roomchief re-arms it a turn or two later. So the fleet holds the skip through
# a grace (AC_GUARD_GRACE from when the gap opened, tracked in
# state/.skip-stale-since-<fam>) and revokes only if the beacon stays stale PAST
# it - a roomchief genuinely not re-arming. Without the grace the stand-down
# made every benign scoped exit read as instant coverage-down, so the fleet
# revoked during the NORMAL re-arm gap and stole the family's done wake to the
# fleet spool (the per-id dedup marker is shared, so a stolen marker never
# re-emits to the family spool) - the roomchief went blind to its own crewmate.
# BUSY DECLARATION (skip-grace-too-short-for-a-chief-inside-a-long-synchronous-gate,
# 2026-07-26): that grace is sized for a chief MID RE-ARM - a turn or two. A chief
# blocked inside ONE synchronous call cannot take a turn AT ALL, so it cannot
# re-arm and its beacon stays down for the whole call: ac-gate.sh waits up to
# AC_GATE_TIMEOUT (600s) against a 300s grace, so a HEALTHY chief lost its skip
# merely for being busy (measured: ~15 crewchief turns in one evening spent
# draining and silently acking a parked crewmate's wakes while its chief was
# legitimately adjudicating a second-chief round). In that window the takeover buys
# NOTHING: the roomchief is blocked and cannot act on the wake, and the crewchief
# does not own the family and may not either - so it converts a wake that would
# have reached the right owner slightly later into one that reaches the wrong owner
# and is discarded. So a blocking caller DECLARES the bounded window
# (ac_chief_busy_path, ac-wake-lib.sh - a SEPARATE signal, never the beacon, which
# asserts something else to five other consumers) and the fleet holds the skip
# while it is unexpired. This teaches the fleet to tell BUSY from DEAD; it does NOT
# widen into "a live roomchief always keeps its skip" (that is the fail-OPEN,
# unbounded shape of the 2026-07-18 defect above). REVOCATION IS UNCHANGED
# OTHERWISE and stays the safety behaviour: a GONE roomchief still revokes
# IMMEDIATELY whatever it declared, and an ABSENT or EXPIRED declaration plus a
# beacon stale past the grace still revokes exactly as before - so a family whose
# scoped coverage is genuinely down is still covered directly by the fleet.
# At ARM every
# AC_WATCH_SKIP entry is also validated to name a family of THIS home (a
# data/<fam>/ dir or a <fam>*/state meta); a foreign/unknown family is refused
# LOUDLY (exit 2), since it blinds nothing real while masking a real misconfig
# (2026-07-18: a drydock family named on the LAB singleton's skip).
#
# Knobs: AC_POLL=15 AC_HEARTBEAT=600 AC_STALE=240 AC_REMOTE_POLL
# AC_CAPTAIN_RE AC_BUSY_RE AC_ARMLOG_KEEP=200 (arm-log trim floor;
# AC_LOCK_STALE_GRACE=5 is ac-lib.sh's, and governs the reclaim above)
# AC_CAPTAIN_RE (env-overridable; default defined in ac-lib.sh, which is the
# authoritative spec for its shape): the default anchors status markers
# (done/needs-decision/blocked/failed/paused/merged/checks-passed) to the line
# START, tolerating only leading whitespace and TUI glyphs - a pane merely
# DISPLAYING code or docs that contain "done:" (quoted strings, printf lines,
# comment leaders, markdown bullets/code spans) does NOT wake. It is fully
# anchored: the retired bare phrase markers are gone (see ac-lib.sh).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

state_dir="$(ac_state_dir)"

watch_log() {
  # watch_log <text> - one timestamped attribution line to
  # state/.watcher-arm.log AND stderr. NEVER stdout: that channel carries the
  # exit reason and nothing else. Trimmed in place so the trail stays bounded.
  local f="$state_dir/.watcher-arm.log" line keep="${AC_ARMLOG_KEEP:-200}"
  line="$(ac_iso) $1"
  printf '%s\n' "$line" >>"$f" 2>/dev/null || true
  printf '%s\n' "$line" >&2
  if [ "$(wc -l <"$f" 2>/dev/null || printf 0)" -gt "$(( keep * 2 ))" ]; then
    tail -n "$keep" "$f" >"$f.tmp.$$" 2>/dev/null && mv "$f.tmp.$$" "$f"
  fi
  return 0
}

release_marker() {
  # release_marker <pid> - the owner-release marker for the watcher <pid>
  # (see OWNER-MARKED RELEASE in the header). Keyed by TARGET pid, in THIS
  # home's state dir, so releaser and target must share AC_HOME - which the
  # config-swap idiom does by construction.
  printf '%s/.watcher-release-%s\n' "$state_dir" "$1"
}

release_scoped_family() {
  # release_scoped_family <pid> - `<role> <family>` when <pid> is part of a
  # SCOPED watcher UNIT, else 1 (see SCOPED TARGETS in the header). <role> is
  # `watcher` when <pid> IS the scoped watcher, `wrapper` when it is the shell
  # the harness tracks around it - its direct parent, the one the arm chain
  # records as `<watcher>(bash) < <wrapper>(zsh) < ...`. Both are refused: a
  # TERM to the wrapper alone leaves the watcher alive under PPID=1.
  # The authoritative record of a watcher's target is the LOCK it holds, not the
  # arm log (trimmed) and not the beacon (no pid): the lock suffix already
  # partitions scoped watchers from the fleet one, so a pid recorded under
  # .watch-only-<fam>.lock.d IS that family's scoped watcher. ac-done.sh's
  # watcher_pid reads the same file from the other direction (scope -> pid).
  local d pid fam
  for d in "$state_dir"/.watch-only-*.lock.d; do
    [ -d "$d" ] || continue
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    [ -n "$pid" ] || continue
    fam="${d##*/}"; fam="${fam#.watch-only-}"; fam="${fam%.lock.d}"
    if [ "$pid" = "$1" ]; then
      printf 'watcher %s\n' "$fam"
      return 0
    fi
    if [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)" = "$1" ]; then
      printf 'wrapper %s\n' "$fam"
      return 0
    fi
  done
  return 1
}

home_fleet_watcher_role() {
  # home_fleet_watcher_role <pid> - `watcher` or `wrapper` when <pid> is THIS
  # home's own fleet-watcher UNIT (see HOME-CROSSING TARGETS in the header):
  # the pid recorded in $state_dir/.watch.lock.d/pid, or its direct PARENT
  # (the harness-tracked wrapper). Else 1 - including when this home has no
  # fleet watcher armed at all (missing, empty or non-numeric lock pid), so
  # the caller fails CLOSED rather than falling through to a foreign pid.
  local lock_pid
  lock_pid="$(cat "$state_dir/.watch.lock.d/pid" 2>/dev/null || true)"
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$lock_pid" = "$1" ]; then
    printf 'watcher\n'
    return 0
  fi
  if [ "$(ps -o ppid= -p "$lock_pid" 2>/dev/null | tr -d '[:space:]' || true)" = "$1" ]; then
    printf 'wrapper\n'
    return 0
  fi
  return 1
}

# OWNER-MARKED RELEASE (see the header): stamp the intent and send the TERM in
# ONE command, so the two can never drift apart. Handled before every arming
# concern below - a release neither arms nor watches, so the owner gate, the
# scope reconciliation and the skip guard are none of its business.
if [ "${1:-}" = "--release" ]; then
  target="${2:-}"
  case "$target" in
    ''|*[!0-9]*) printf 'usage: ac-watch.sh --release <pid>\n' >&2; exit 2 ;;
  esac
  # SCOPED TARGETS (see the header): --release is the FLEET watcher's remedy.
  # Refuse BEFORE the marker is stamped - a refused release must leave no trace
  # on the watcher it declined to touch.
  if scoped_hit="$(release_scoped_family "$target")"; then
    scoped_role="${scoped_hit%% *}"; scoped_fam="${scoped_hit#* }"
    case "$scoped_role" in
      wrapper) scoped_what="the harness-tracked WRAPPER of the scoped watcher for family $scoped_fam (TERMing it leaves that watcher ALIVE under PPID=1 - an orphan that keeps polling while its exit wakes no one)" ;;
      *)       scoped_what="the scoped watcher for family $scoped_fam" ;;
    esac
    watch_log "release REFUSED pid=$target - scoped $scoped_role for $scoped_fam (belongs to its roomchief)"
    printf 'refused: pid %s is %s - it belongs to that family'"'"'s roomchief; only the fleet watcher is releasable via --release. Releasing it leaves %s with no real-time coverage until its roomchief notices and re-arms. Release the FLEET watcher instead (its pid: cat %s/.watch.lock.d/pid).\n' \
      "$target" "$scoped_what" "$scoped_fam" "$state_dir" >&2
    exit 2
  fi
  # HOME-CROSSING TARGETS (see the header): --release is THIS home's own
  # remedy. Refuse BEFORE the marker is stamped, same no-trace rule as the
  # scoped guard above - a refused release must leave no trace on the pid it
  # declined to touch, whatever home it turns out to belong to.
  if ! home_fleet_watcher_role "$target" >/dev/null; then
    watch_log "release REFUSED pid=$target - not this home's fleet watcher (may belong to another fleet)"
    printf 'refused: pid %s is not this home'"'"'s fleet watcher - it may belong to another fleet; only this home'"'"'s own fleet watcher (or its wrapper) is releasable via --release. Its pid: cat %s/.watch.lock.d/pid.\n' \
      "$target" "$state_dir" >&2
    exit 2
  fi
  marker="$(release_marker "$target")"
  printf 'releaser=%s\ntarget=%s\nreason=config-swap\nepoch=%s\n' \
    "$$" "$target" "$(ac_now)" >"$marker"
  if ! kill -TERM "$target" 2>/dev/null; then
    # A marker outliving its kill is exactly the silencer the time bound
    # exists to retire - withdraw it rather than leave it lying around.
    rm -f "$marker"
    watch_log "release FAILED pid=$target - no such process (marker withdrawn)"
    printf 'refused: no process %s to release (marker withdrawn)\n' "$target" >&2
    exit 2
  fi
  watch_log "release pid=$target reason=config-swap releaser=$$"
  printf 'released: pid=%s reason=config-swap - re-arm the corrected config\n' "$target"
  exit 0
fi

once=0
[ "${1:-}" = "--once" ] && once=1

# Scope-containment reconciliation, BEFORE anything keys off either variable
# (the lock suffix below, and every wake this run files). A scoped watcher
# FILES its wakes under AC_SCOPE but WATCHES the ids in AC_WATCH_ONLY, so
# AC_WATCH_ONLY must CONTAIN AC_SCOPE - and this applies to --once too, which
# files wakes exactly like the armed watcher.
#
# The two are NOT equal by construction: AC_SCOPE rides the roomchief's
# launch line as real env (bin/ac-spawn.sh's backend_send_line call, the
# AC_SCOPE=... it appends after the prompt), while AC_WATCH_ONLY is only
# prompt text the agent must remember to type (that same launch's roomchief
# kickoff prompt, the "Arm your watcher... AC_WATCH_ONLY=..." sentence). So:
# - AC_WATCH_ONLY unset -> DEFAULT it from the scope. The scope is the
#   authoritative signal ("I am this family's session"), and unguarded this
#   case armed a FLEET-wide watch that filed every wake under one family.
# - AC_WATCH_ONLY == AC_SCOPE -> the single-family case, unchanged.
# - AC_WATCH_ONLY CONTAINING AC_SCOPE plus extra entries -> ALLOWED: an epic
#   roomchief watches its own family PLUS its in-flight story families (their
#   ids, computed by ac-ready.sh watch-set), so the pane-poll backup for a
#   story crewmate that never ran ac-done routes to the epic's spool, not the
#   fleet's (behavior: epic-roomchief-watch-only-omits-story-ids).
# - AC_WATCH_ONLY NOT containing AC_SCOPE -> refuse: its wakes would land under
#   a key nobody drains.
# Only a VALID scope reaches this: a malformed AC_SCOPE routes to the fleet
# spool (ac_wake_spool_path), so such a watcher IS a fleet watcher and its
# watch set must not be narrowed to a family name that can never exist.
if ac_wake_scope_ok "${AC_SCOPE:-}"; then
  if [ -z "${AC_WATCH_ONLY:-}" ]; then
    AC_WATCH_ONLY="$AC_SCOPE"
    export AC_WATCH_ONLY
    printf 'scoped watcher: AC_WATCH_ONLY defaulted to AC_SCOPE=%s\n' "$AC_SCOPE" >&2
  else
    # AC_WATCH_ONLY must CONTAIN AC_SCOPE. AC_WATCH_ONLY == AC_SCOPE is the
    # single-family case and passes here UNCHANGED; extra entries are an epic
    # roomchief's in-flight story families, whose panes it also watches. An
    # AC_WATCH_ONLY that does NOT contain AC_SCOPE is refused: it files its
    # wakes under AC_SCOPE, a key that would then be watched by no one.
    _scope_watched=0
    for _wo in ${AC_WATCH_ONLY//,/ }; do
      if [ "$_wo" = "$AC_SCOPE" ]; then _scope_watched=1; break; fi
    done
    if [ "$_scope_watched" != 1 ]; then
      printf 'refused: scoped watcher AC_WATCH_ONLY must contain the family it files for (AC_WATCH_ONLY=%s, AC_SCOPE=%s)\n' \
        "$AC_WATCH_ONLY" "$AC_SCOPE"
      exit 2
    fi
  fi
fi

poll_target="fleet"
[ -n "${AC_WATCH_ONLY:-}" ] && poll_target="only:$AC_WATCH_ONLY"

watch_skip_set() {
  # watch_skip_set <list> - normalise an AC_WATCH_SKIP-shaped comma list to a
  # SET (split, dedupe, sort, rejoin) so two configs with the same membership
  # in a different order - or with a duplicate - compare equal. Empty stays
  # empty. Comparison-only: never write the result back to $config_file,
  # which keeps the RAW string an incumbent actually armed with (the refusal
  # prints it verbatim, and a chief diagnosing a real swap wants the config
  # as armed, not a re-sorted rendering of it).
  [ -n "$1" ] || return 0
  printf '%s\n' "${1//,/$'\n'}" | sort -u | paste -sd, -
}

family_known() {
  # family_known <fam> - 0 when <fam> belongs to THIS home: it has a data dir,
  # or any state meta (the family, its roomchief, or a member <fam>-<stage>).
  # The cheapest sound "is this a real family here" check, used to refuse an
  # AC_WATCH_SKIP entry that names a foreign family (see the header).
  local fam="$1" m
  [ -d "$(ac_data_dir)/$fam" ] && return 0
  for m in "$state_dir/$fam.meta" "$state_dir/$fam"-*.meta; do
    [ -e "$m" ] && return 0
  done
  return 1
}

# AC_WATCH_SKIP home guard (behavior: watcher-skip foreign-family, 2026-07-18) -
# the twin of the AC_WATCH_ONLY/AC_SCOPE reconciliation above, placed here
# because it needs watch_log. A skip naming a family absent from this home is
# always a misconfig: it blinds nothing real while masking one, so it is
# REFUSED at arm (exit 2, naming the entry AND the whole set). Runs for --once
# too - a foreign skip is equally wrong in a bounded checkpoint.
if [ -n "${AC_WATCH_SKIP:-}" ]; then
  for _skf in ${AC_WATCH_SKIP//,/ }; do
    if ! family_known "$_skf"; then
      watch_log "refused: AC_WATCH_SKIP names $_skf, absent from this home (AC_WATCH_SKIP=$AC_WATCH_SKIP)"
      printf 'refused: AC_WATCH_SKIP entry %s does not belong to this home (AC_WATCH_SKIP=%s)\n' \
        "$_skf" "$AC_WATCH_SKIP"
      exit 2
    fi
  done
fi

publish_beacon() {
  # publish_beacon <value> - write the liveness beacon by tmp+rename, NEVER by
  # truncating it in place. `printf >"$beat_file"` truncates first, so a reader
  # that cat(1)s inside that window succeeds with an EMPTY string - and every
  # consumer computes `now - beat`, where an empty beat is arithmetic on 0: the
  # raw epoch the turn-end guard printed live 2026-07-27 ("beacon is stale
  # (1785121773s)") while this watcher was beating 1s earlier. rename(2) is
  # atomic within the directory, so a reader sees the previous beat or the new
  # one and never a half-written file. Best-effort like the write it replaces:
  # a beacon that cannot be published must never fail a poll or an exit.
  local t="$beat_file.tmp.$$"
  printf '%s\n' "$1" >"$t" 2>/dev/null && mv -f "$t" "$beat_file" 2>/dev/null \
    || rm -f "$t" 2>/dev/null || true
}

stand_down_beacon() {
  # stand_down_beacon - mark THIS watcher's liveness beacon stale on EXIT, so a
  # fresh beat can never outlive the process that made it (behavior:
  # idle-chief-deaf, 2026-07-18; see the header). Written 0, not removed: every
  # reader does `cat || 0` (age=now => stale => "watcher down", which the
  # turn-end guard turns into a forced re-arm), and the file's continued
  # existence keeps existence checks honest. Best-effort; never fails the exit.
  publish_beacon 0
}

release_note() {
  # release_note - the calm reason text when a FRESH owner-release marker names
  # THIS pid, else 1 (see OWNER-MARKED RELEASE in the header). The marker is
  # CONSUMED either way: single use, so a leftover can never become a standing
  # silencer for a later kill.
  local m epoch age reason releaser
  m="$(release_marker "$$")"
  [ -f "$m" ] || return 1
  epoch="$(ac_meta_get "$m" epoch)"
  reason="$(ac_meta_get "$m" reason)"
  releaser="$(ac_meta_get "$m" releaser)"
  rm -f "$m"
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  # 30s: two orders of magnitude above the real gap (the idiom's `sleep 1`,
  # and a TERM whose trap bash defers until the running poll pass returns),
  # and far below the "a leftover marker mutes a genuine kill minutes later"
  # class it exists to retire.
  age=$(( $(ac_now) - epoch ))
  [ "$age" -le 30 ] || return 1
  printf '%s by owner (released by pid=%s)\n' "${reason:-release}" "${releaser:-unknown}"
}

sleep_pid=""
on_signal() {
  # on_signal <NAME> - a TERM/INT from outside this process (see the header).
  # Print ONE reason line and exit cleanly, so the EXIT trap releases the lock
  # instead of leaking it. Untrapped, this process would just die and wedge
  # every later re-arm.
  # An OWNER-MARKED release says so calmly; every other signal keeps the
  # alarming wording byte for byte. Only the wording differs - the reason-line
  # shape, the lock release, the beacon stand-down and the exit status are the
  # same for both.
  local sig="$1" note
  trap - TERM INT                       # never re-enter on a second signal
  if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; fi
  note="$(release_note)" || note="watcher killed externally"
  watch_log "signal:$sig pid=$$ target=$poll_target - $note"
  printf 'signal:%s pid=%s target=%s - %s, lock released; re-arm to restore coverage\n' \
    "$sig" "$$" "$poll_target" "$note"
  exit 0
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT

poll_wait() {
  # poll_wait <secs> - the interval sleep, INTERRUPTIBLE. bash defers a trap
  # while a FOREGROUND child runs, so a foreground `sleep` would hold the
  # TERM trap for up to a full interval - and the poll wait is exactly where
  # every observed kill landed. Backgrounding it and `wait`ing runs the trap
  # at once. A kill aimed at the sleep CHILD alone just ends the wait early.
  sleep "$1" &
  sleep_pid=$!
  wait "$sleep_pid" 2>/dev/null || true
  sleep_pid=""
}

lock_suffix=""
if [ -n "${AC_WATCH_ONLY:-}" ]; then
  # A scoped watcher is identified by the ONE family it FILES for (AC_SCOPE),
  # NOT by its full watch set: an epic roomchief also watches its in-flight
  # story panes (AC_WATCH_ONLY=<epic>,<story>...), and that set changes as
  # stories start and land. Keying the lock on AC_SCOPE keeps its name STABLE
  # across those re-arms and equal to the `.watch-only-<scope>.lock.d` name
  # ac_watcher_pid/ac_watcher_nudge (ac-wake-lib.sh) rebuild from AC_FLEET_SCOPE - so
  # ac-done's push still finds the watcher, and the beacon/spool/lock all key on
  # the same family (behavior: epic-roomchief-watch-only-omits-story-ids). A set
  # AC_WATCH_ONLY with no valid AC_SCOPE (a bare hand-run) keeps the old
  # comma-flattened suffix.
  if ac_wake_scope_ok "${AC_SCOPE:-}"; then
    lock_suffix="-only-$AC_SCOPE"
  else
    lock_suffix="-only-$(printf '%s' "$AC_WATCH_ONLY" | tr ',' '_')"
  fi
fi
lock="$state_dir/.watch$lock_suffix.lock.d"
# The running singleton's watch-config lives beside its lock (keyed by the same
# suffix, so a fleet arm and a scoped arm never read each other's): a second
# arm that finds the lock held compares against it (behavior: config-aware
# re-arm). beat_file is stood down on exit (behavior: idle-chief-deaf).
config_file="$state_dir/.watcher-config$lock_suffix"
beat_file="$(ac_watcher_beat_path "$state_dir" "${AC_SCOPE:-}")"
if [ "$once" = 0 ]; then
  if [ -z "${AC_WATCH_ONLY:-}" ]; then
    # Owner gate (see header): only the home's lock-holding session arms
    # the fleet watcher; scoped watchers are exempt.
    if owner_note="$("$(dirname "$0")/ac-lock.sh" acquire 2>&1)"; then
      [ -n "$owner_note" ] && printf '%s\n' "$owner_note" >&2
      "$(dirname "$0")/ac-lock.sh" status \
        | sed -n 's/^held pid=\([0-9][0-9]*\).*/\1/p' >"$state_dir/.watcher-owner"
    else
      [ -n "$owner_note" ] && printf '%s\n' "$owner_note" >&2
      printf 'refused: fleet watcher not armed - another session owns this home\n'
      exit 2
    fi
  fi
  if ! ac_lock_acquire "$lock" 0; then
    # The lock is held by a LIVE watcher (a dead/stale one would have been
    # reclaimed by ac_lock_acquire above). Behavior: config-aware re-arm - an
    # IDENTICAL arm stays idempotent, a DIFFERING one must not silently no-op
    # and leave the stale config running. Config identity = AC_WATCH_SKIP's SET
    # of families, not its literal string (behavior:
    # watch-skip-compared-as-a-string-not-a-set): a chief's typed order and
    # ac-watch-autoarm.sh's promoted_families() glob (shell-sorted
    # alphabetically) name the same families in different order by
    # construction, so same membership in a different order is the same
    # config, never a swap. The lock suffix already partitions the fleet
    # watcher from scoped ones, and scoped ones from each other by AC_SCOPE -
    # so a roomchief re-arming with an evolved story set shares its own lock
    # and reads "already running" too.
    running="$(cat "$config_file" 2>/dev/null || true)"
    # A refusal means coverage exists, not that the arming session has
    # nothing to do: name whether ITS OWN inbox holds a wake, the same
    # predicate and scoping bin/ac-turnend-guard.sh's queued-wakes gate uses
    # (a scoped arm is judged on its own spool; a fleet arm on its own spool
    # plus any orphan). Appended to the SAME line as the prefix, never a new
    # one - ac-watch-autoarm.sh:195-196 reduces this output to its LAST
    # non-empty line before classifying it, so a genuinely new line would
    # replace "already running"/"refused: a live watcher" as the reason the
    # hook matches on and silently misclassify the refusal.
    if [ -n "${AC_SCOPE:-}" ]; then
      ac_wake_pending "$state_dir" "${AC_SCOPE:-}" && pending=0 || pending=1
    else
      { ac_wake_pending "$state_dir" '' || ac_wake_orphan_pending "$state_dir"; } && pending=0 || pending=1
    fi
    if [ "$pending" = 0 ]; then
      pending_note='pending: your inbox is non-empty - drain with bin/ac-wake-drain.sh before ending the turn'
    else
      pending_note='pending: your inbox is empty - nothing waiting'
    fi
    # Name the ONE process to release and the exact command (behavior:
    # named-release-target). A remedy that says only "release the stale
    # watcher" leaves the caller to FIND it, and the improvisation observed
    # in the wild is a pattern kill (`pkill -f ac-watch`), which reaps every
    # home's watcher because every home runs the same command line. Read here
    # because BOTH refusals below name it.
    running_pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ "$(watch_skip_set "$running")" = "$(watch_skip_set "${AC_WATCH_SKIP:-}")" ]; then
      # BOUNDED INCUMBENT (behavior: rearm-stands-aside-for-a-watcher-that-then-exits).
      # `already running` answers "does a watcher exist right now"; a HAND arm is
      # asking "will the coming turn be covered", and for a watcher the auto-arm
      # hook owns the two answers differ. The hook's watcher runs in the
      # FOREGROUND of one Stop-hook firing and dies with it (ac-watch-autoarm.sh's
      # MEASURED CONTRACT, item 5), so AC_AUTOARM_BUDGET retires it on a schedule;
      # a chief's arm is a harness background task and carries no such bound.
      # Standing the DURABLE arm aside for the BOUNDED one is what turns a
      # scheduled handback into a turn the chief believes it just covered.
      # MEASURED 2026-08-06, one instrumented run, every stamp taken from the
      # process that produced it: the hand arm printed `already running` at T+0
      # with the incumbent LIVE -> the incumbent's stand_down_beacon landed at
      # T+2.513s (the beacon inode's own mtime) -> the hook's budget handback at
      # T+2.536s -> the turn-end guard blocked on the stood-down beacon at
      # T+2.602s. Nothing raced: the owner retired its own watcher on time.
      # This branches on OWNERSHIP, never on a beacon state - at the instant of
      # the arm the incumbent is beating normally (a REAL BEAT, the fourth of
      # ac_watcher_beat_read's four states), so no beacon read could have caught
      # it. The HOOK arming over its own predecessor is the untouched path: it
      # sets AC_AUTOARM, and `already running` is the prefix it classifies on.
      # FLEET ARMS ONLY, for two reasons that both point the same way and were
      # each checked rather than assumed. (1) The remedy below is REFUSED for a
      # scoped target - the SCOPED TARGETS guard above exits 2 with "only the
      # fleet watcher is releasable via --release" (executed against a scoped
      # lock, not read) - and a refusal whose remedy is itself refused is worse
      # than the lie it replaces. (2) A scoped family already has the backstop
      # the fleet has none of: AC_WATCH_SKIP is REVALIDATED every poll, so when
      # the family's beacon stays stale past the re-arm grace the FLEET watcher
      # covers its panes directly (the watcher-skip-staleness block above). The
      # fleet watcher IS that backstop, so when IT lapses nothing catches the
      # turn but the guard, after the fact.
      if [ -z "${AC_AUTOARM:-}" ] && [ -z "${AC_WATCH_ONLY:-}" ] && [ -f "$lock/autoarm" ]; then
        watch_log "refused: live watcher pid=${running_pid:-unknown} is the auto-arm hook's own (bounded by AC_AUTOARM_BUDGET) - take durable ownership with: ac-watch.sh --release ${running_pid:-<pid>}"
        printf 'refused: the live watcher (pid %s) is the auto-arm hook'"'"'s own - it dies with that Stop-hook firing when the hook hands its budget back, so THIS arm covers nothing and your next turn end may have no watcher. Take durable ownership with: bin/ac-watch.sh --release %s (marks the release as yours and TERMs that one pid, which releases its lock cleanly), then re-arm - a hand-armed watcher is a harness background task and carries no budget. Never release by pattern (pkill/killall -f ac-watch): every home on this box runs the same command line, so a pattern kill reaps the watchers of every other fleet too. %s\n' \
          "${running_pid:-unknown}" "${running_pid:-<pid>}" "$pending_note"
        exit 2
      fi
      printf 'already running - %s\n' "$pending_note"
      exit 0
    fi
    watch_log "refused: live watcher pid=${running_pid:-unknown} runs AC_WATCH_SKIP=[$running], this arm carries AC_WATCH_SKIP=[${AC_WATCH_SKIP:-}] - release with: ac-watch.sh --release ${running_pid:-<pid>}"
    printf 'refused: a live watcher (pid %s) holds a DIFFERENT watch-config (running AC_WATCH_SKIP=[%s], new AC_WATCH_SKIP=[%s]); release THAT ONE with: bin/ac-watch.sh --release %s (marks the release as yours and TERMs that one pid, which releases its lock cleanly), then re-arm the corrected config. Never release by pattern (pkill/killall -f ac-watch): every home on this box runs the same command line, so a pattern kill reaps the watchers of every other fleet too. %s\n' \
      "${running_pid:-unknown}" "$running" "${AC_WATCH_SKIP:-}" "${running_pid:-<pid>}" "$pending_note"
    exit 2
  fi
  printf '%s\n' "${AC_WATCH_SKIP:-}" >"$config_file"
  # An arm ac-watch-autoarm.sh owns is BOUNDED - it runs in the foreground of one
  # Stop-hook firing and dies with it. Recorded INSIDE the lock dir, so
  # ac_lock_release's `rm -rf` retires it with the lock: the marker has no second
  # lifetime and can never outlive the watcher it describes (behavior:
  # rearm-stands-aside-for-a-watcher-that-then-exits).
  [ -z "${AC_AUTOARM:-}" ] || : >"$lock/autoarm"
  trap 'stand_down_beacon; rm -f "$config_file"; ac_lock_release "$lock"' EXIT
  # Attribution (see the header): name this watcher and every ancestor that
  # could reap it, BEFORE the first poll wait where the kills land.
  watch_log "arm pid=$$ target=$poll_target poll=${AC_POLL:-15}s heartbeat=${AC_HEARTBEAT:-600}s chain=$(ac_pid_chain)"
fi

in_scope() {
  # in_scope <id> <fam1,fam2,...> - id is <fam> or <fam>-*, EXCEPT the
  # family's own roomchief (<fam>-chief), which belongs to the fleet scope.
  local id="$1" fam
  for fam in ${2//,/ }; do
    case "$id" in
      "$fam"-chief) return 1 ;;
      "$fam"|"$fam"-*) return 0 ;;
    esac
  done
  return 1
}

skip_family() {
  # skip_family <id> [<fleet_scope>] - the AC_WATCH_SKIP family <id> belongs to,
  # printed, or empty when it belongs to none (or is a <fam>-chief, which is
  # fleet-scoped and never skipped). Two membership rules, both RETURNING the
  # matched family so its scoped coverage can be revalidated before the skip is
  # honored (behavior: watcher-skip-staleness):
  #  - the id GRAMMAR (<fam>/<fam>-*, same as in_scope): an epic's OWN panes.
  #  - the pane's meta FLEET_SCOPE: a STORY crewmate's id matches its epic by
  #    NEITHER grammar rule, but its fleet_scope names the epic whose roomchief
  #    covers it (ac-spawn records it at spawn). Returning the EPIC means the
  #    caller revalidates the EPIC's coverage, not the (unwatched) story id
  #    (behavior: epic-roomchief-watch-only-omits-story-ids).
  local id="$1" fleet_scope="${2:-}" fam
  for fam in ${AC_WATCH_SKIP//,/ }; do
    case "$id" in
      "$fam"-chief) : ;;
      "$fam"|"$fam"-*) printf '%s\n' "$fam"; return 0 ;;
    esac
    if [ -n "$fleet_scope" ] && [ "$fleet_scope" = "$fam" ]; then
      printf '%s\n' "$fam"; return 0
    fi
  done
  return 1
}

skip_coverage_live() {
  # skip_coverage_live <fam> - 0 when <fam>'s OWN scoped coverage is LIVE, so
  # the fleet watcher may keep skipping it: its roomchief is live (meta +
  # window, via ac_roomchief_live) AND its liveness beacon is fresh (younger
  # than AC_GUARD_GRACE, the turn-end guard's bound). Either half gone means
  # the skip's justification is gone and the fleet watcher must cover the
  # family's panes directly (behavior: watcher-skip-staleness, 2026-07-18).
  # Read through ac_watcher_beat_read, never a raw cat: it is the one place that
  # classifies an UNREADABLE beacon (present but empty or non-numeric) as no
  # beat. A raw value reaches the arithmetic below, where bash evaluates the
  # VALUE as an expression, looks its first identifier up as a variable and dies
  # under set -u - killing fleet supervision silently, naming a variable that
  # exists in no version of this file (observed live 2026-08-05, pid 66812).
  local fam="$1" beat age
  ac_roomchief_live "$state_dir" "$fam" || return 1
  beat="$(ac_watcher_beat_read "$state_dir" "$fam")"; beat="${beat%% *}"
  age=$(( $(ac_now) - beat ))
  [ "$age" -le "${AC_GUARD_GRACE:-300}" ]
}

rearm_grace_active() {
  # rearm_grace_active <fam> - 0 while <fam>'s currently-stale scoped coverage
  # is still inside its RE-ARM GRACE, so the fleet must keep skipping rather
  # than revoke (behavior: roomchief-scoped-watcher-blindness, 2026-07-19).
  # Called only when the caller has confirmed the roomchief is LIVE but the
  # beacon stale. The family's scoped watcher heartbeat-exits every AC_HEARTBEAT
  # and STANDS ITS BEACON DOWN, so a stale beacon under a live roomchief is the
  # normal exit->re-arm gap, not lost coverage - revoking then would steal the
  # family's done wake to the fleet spool (the per-id dedup marker is shared)
  # and blind the roomchief. Records when the gap opened in
  # state/.skip-stale-since-<fam> and holds the skip until the gap outlives
  # AC_GUARD_GRACE (the same bound the guard gives the roomchief to re-arm),
  # after which coverage is genuinely down and the caller revokes. Restores the
  # grace the beacon stand-down removed.
  local fam="$1" since now marker
  marker="$state_dir/.skip-stale-since-$fam"
  now="$(ac_now)"
  since="$(cat "$marker" 2>/dev/null || true)"
  case "$since" in
    ''|*[!0-9]*) since="$now"; printf '%s\n' "$now" >"$marker" ;;
  esac
  [ $(( now - since )) -le "${AC_GUARD_GRACE:-300}" ]
}

chief_busy_declared() {
  # chief_busy_declared <fam> - 0 while <fam>'s roomchief has an UNEXPIRED busy
  # declaration: it is blocked inside ONE bounded synchronous call and cannot take
  # a turn, so it cannot re-arm either (behavior:
  # skip-grace-too-short-for-a-chief-inside-a-long-synchronous-gate). The file and
  # its contract are ac_chief_busy_path's; a missing or malformed value is NO
  # declaration, which is the fail-closed default.
  local fam="$1" until_epoch
  until_epoch="$(cat "$(ac_chief_busy_path "$state_dir" "$fam")" 2>/dev/null || true)"
  case "$until_epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(ac_now)" -le "$until_epoch" ]
}

remote_poll_interval() {
  # remote_poll_interval - seconds between remote-order polls; 0 = slot off.
  # Resolution: AC_REMOTE_POLL env > config/remote-poll-interval > 300; the
  # 300 default applies only when the executable config/remote-poll hook
  # exists. Non-numeric or 0 at any layer = off (unchanged semantics).
  local iv="${AC_REMOTE_POLL:-}"
  [ -n "$iv" ] || iv="$(ac_config_read remote-poll-interval "")"
  if [ -z "$iv" ]; then
    if [ -x "$(ac_config_dir)/remote-poll" ]; then iv=300; else iv=0; fi
  fi
  case "$iv" in ''|*[!0-9]*) iv=0 ;; esac
  printf '%s\n' "$iv"
}

remote_poll_allowed() {
  # Lock gate (see header): fleet-scoped watcher only, and this home's
  # recorded watcher owner must BE the session-lock holder - so exactly one
  # poller exists fleet-wide, however many watchers run.
  [ -z "${AC_WATCH_ONLY:-}" ] || return 1
  local owner holder
  owner="$(cat "$state_dir/.watcher-owner" 2>/dev/null || true)"
  holder="$(ac_meta_get "$state_dir/.session-lock" pid)"
  [ -n "$owner" ] && [ "$owner" = "$holder" ]
}

check_remote() {
  # One remote poll. Prints `remote:<first-rid>` and returns 0 when new
  # orders arrived (poll already stashed them and queued their wakes
  # durably); returns 1 on a quiet poll.
  local out first
  out="$("$(dirname "$0")/ac-remote.sh" poll || true)"
  [ -n "$out" ] || return 1
  first="$(printf '%s\n' "$out" | awk '/^remote-order /{print $2; exit}')"
  printf 'remote:%s\n' "${first:-unknown}"
  return 0
}

queue_wake() {
  # queue_wake <kind> <id> <payload> - durable actionable wake, the record
  # every consumer (the crewchief's drain, a roomchief's scoped drain, the
  # inbox) reads. CAPTAIN 2026-07-28 first cut a captain notification
  # (config/wedge-alarm) down to ask/gone/unobservable+handback (a
  # notification on every wake was noise on a busy fleet). CAPTAIN 2026-07-30
  # ("k co gi thi dung co chay ac-notify" / "block boi captain") went
  # further: ask/gone/unobservable are chief-owned events, not captain
  # approval - the chief answers or steers them - so this watcher no longer
  # calls ac-notify.sh for ANY kind. The one thing that genuinely waits on
  # the captain - a room GATE:/ASK: pending on them - notifies from
  # bin/ac-room.sh's cmd_post instead, on ac_room_pending's edge into >0.
  # Filed for the CONSUMER that must act on it (see ac-lib.sh): this
  # watcher's AC_SCOPE - a family watcher's wakes go to .wake-spool.<fam>/,
  # which only its roomchief drains; the fleet watcher's go to .wake-spool/.
  # WHEN a wake is produced is unchanged - only how a record reaches disk:
  # ac_wake_publish (private write, one atomic ln), never a shared append.
  # Called from the watcher's MAIN shell only, never a subshell - $$ is the
  # publish collision-identity (ac_wake_publish's contract).
  # A FAILED publish is never swallowed: every call site runs inside the
  # `if check_fleet` condition where errexit is OFF, and the dedup marker
  # (.seen-/.gone-/.ask-/.stale-) has ALREADY advanced by the time this runs,
  # so a silent failure would lose the wake with no trace and no retry. The
  # failure goes loudly through watch_log (arm log + stderr - the one
  # out-of-band channel the header names; stdout stays the exit reason's
  # alone) and the pass continues: the printed reason line still wakes the
  # chief this once - only the DURABLE record is missing, and the log says so.
  if ! ac_wake_publish "$state_dir" "${AC_SCOPE:-}" "$1" "$2" "$3"; then
    watch_log "wake-publish FAILED kind=$1 id=$2 scope=${AC_SCOPE:-fleet} - record NOT durable, payload: $3"
  fi
}

marker_seen() {
  # marker_seen <pane-line> <stored> - 0 when state/.seen-<id> already covers
  # this pane marker. EQUALITY is the watcher's own stamp (it stores the
  # captured line verbatim). The SUFFIX case is the agent PUSH (see the PUSH
  # CHANNEL in the header): ac-done.sh stamps the marker TEXT it published,
  # while the pane renders that same line behind a TUI glyph ("⏺ done: x") the
  # agent has no way to know - without it, one completion announced on both
  # channels would wake the chief twice. The stored value is a suffix only in
  # that case: every value this watcher writes is the full line.
  [ -n "$2" ] || return 1
  [ "$1" = "$2" ] && return 0
  case "$1" in *"$2") return 0 ;; esac
  return 1
}

check_fleet() {
  # One poll pass. Prints an exit reason and returns 0 when actionable.
  local meta id tail hash prev marker seen seen_hash seen_now idle changed_file skip_fam
  local task_dir report rhash sup alive_rc busy wait_file
  # DELIBERATELY does NOT branch on ac_meta_is_verify. A verification agent is
  # excluded from ACCOUNTING (ac_chief_child_live, and the ac-room/
  # ac-teardown/ac-wake-drain/ac-fleets enumerators), NEVER from SUPERVISION:
  # the watcher polls its pane exactly like a crewmate's, so a verifier that
  # dies, blocks on a prompt or ends its turn still wakes the chief.
  # ...but it DOES skip the self class, the mirror image: a chief SELF TASK's
  # pane holds a `tail -f` and no agent, so there is no marker to find and the
  # only thing polling it could produce is a stale:/ended: wake sent to the
  # very chief that is typing into it (contract: the SELF-TASK class block in
  # ac-lib.sh). ac_crew_metas batches that classification into one awk pass
  # instead of one ac_meta_get fork per pane per poll (audit-f4); the list
  # rides FD 3 because the body's backend/jq calls must not eat it.
  while IFS= read -r meta <&3; do
    id="$(basename "$meta" .meta)"
    if [ -n "${AC_WATCH_ONLY:-}" ] && ! in_scope "$id" "$AC_WATCH_ONLY"; then continue; fi
    if [ -n "${AC_WATCH_SKIP:-}" ]; then
      # A STORY pane belongs to its epic's skip by meta fleet_scope, not its id
      # (epic-roomchief-watch-only-omits-story-ids). Read only here (fleet
      # watcher), so scoped watchers pay nothing, and never the backlog.
      skip_fam="$(skip_family "$id" "$(ac_meta_get "$meta" fleet_scope)")"
      if [ -n "$skip_fam" ]; then
        # Revalidate the skip's justification: the family's OWN scoped watcher
        # must actually be covering it (behavior: watcher-skip-staleness). Live
        # coverage -> skip exactly as before (clear the takeover trackers).
        if skip_coverage_live "$skip_fam"; then
          rm -f "$state_dir/.skip-revoked-$skip_fam" "$state_dir/.skip-stale-since-$skip_fam"
          continue
        fi
        # Coverage is not live THIS poll. A LIVE roomchief with a merely-stale
        # beacon is almost always mid re-arm (its scoped watcher just
        # heartbeat-exited and stood its beacon down): hold the skip through the
        # re-arm grace so the fleet never revokes a healthy family and steals
        # its done wake to the fleet spool (behavior:
        # roomchief-scoped-watcher-blindness). It is also held while the chief has
        # DECLARED itself busy inside a bounded synchronous call - it cannot take a
        # turn, so it cannot re-arm, and the re-arm grace alone is too short for
        # that (behavior:
        # skip-grace-too-short-for-a-chief-inside-a-long-synchronous-gate). BUSY is
        # checked FIRST and short-circuits, so the declared window does not CONSUME
        # the re-arm grace: a chief with no gap already open when it blocked gets
        # its full grace afterwards, when it can actually re-arm.
        # Only a GONE roomchief, or a beacon stale past BOTH, revokes - fall
        # through and watch its panes, logging the takeover ONCE (the marker dedups).
        if ac_roomchief_live "$state_dir" "$skip_fam" \
           && { chief_busy_declared "$skip_fam" || rearm_grace_active "$skip_fam"; }; then
          continue
        fi
        if [ ! -e "$state_dir/.skip-revoked-$skip_fam" ]; then
          touch "$state_dir/.skip-revoked-$skip_fam"
          watch_log "skip revoked: $skip_fam scoped coverage down (roomchief gone or beacon stale past re-arm grace) - fleet watcher covering its panes directly"
        fi
      fi
    fi
    AC_BACKEND="$(ac_task_backend "$id")"
    export AC_BACKEND

    alive_rc=0
    backend_window_alive "$id" || alive_rc=$?
    if [ "$alive_rc" = 2 ]; then
      # UNOBSERVABLE (contract: ac-backend.sh WINDOW LIVENESS): the backend could
      # not be read, which is no evidence about the pane - stamping a death here
      # is what made a herdr protocol mismatch read as two dead agents. So: no
      # failure state, no `gone` marker (a real death after the outage is still
      # news), one wake and one status line per outage episode - the outage is
      # fleet-wide and only a human clears it, but re-waking every poll for every
      # pane would bury the chief. KEEP POLLING: recovery needs no re-arm, and the
      # readable pass below clears the marker so the NEXT outage wakes again.
      if [ ! -e "$state_dir/.unobservable-$id" ]; then
        touch "$state_dir/.unobservable-$id"
        ac_status_append "$id" "unobservable: backend could not be read for $(backend_target "$id") - NOT a death; the pane may well be alive (check the backend itself)"
        queue_wake unobservable "$id" "the backend could not be read - liveness unknown, no work assumed lost (check the backend: herdr status server)"
        printf 'unobservable:%s\n' "$id"
        return 0
      fi
      continue
    fi
    rm -f "$state_dir/.unobservable-$id"

    if [ "$alive_rc" != 0 ]; then
      if [ ! -e "$state_dir/.gone-$id" ]; then
        touch "$state_dir/.gone-$id"
        ac_status_append "$id" "failed: window gone"
        queue_wake gone "$id" "window $(backend_target "$id") vanished"
        printf 'gone:%s\n' "$id"
        return 0
      fi
      continue
    fi
    rm -f "$state_dir/.gone-$id"

    # Computed here (not just for the branches below): backend_agent_blocked
    # ALSO masks on this file (bin/ac-backend.sh:866), and the ask-alert
    # elif below must not mistake that mask for a real resume.
    wait_file="$(ac_wait_file "$id")"

    # ask-alert: the backend says the agent is BLOCKED on a prompt a human
    # must answer - a silent stall the busy-regex never catches.
    if backend_agent_blocked "$id" 2>/dev/null; then
      if [ ! -e "$state_dir/.ask-$id" ]; then
        touch "$state_dir/.ask-$id"
        ac_status_append "$id" "needs-decision: pane blocked on an interactive prompt"
        queue_wake ask "$id" "agent blocked on an interactive prompt (answer or steer it)"
        printf 'ask:%s\n' "$id"
        return 0
      fi
    elif [ -e "$state_dir/.ask-$id" ] && [ ! -e "$wait_file" ]; then
      # EDGE only (the latch existed and is now being dropped) - never on the
      # level, which the unguarded `rm -f` used to run on EVERY poll for
      # EVERY unblocked pane. ac_status_append has no dedupe of its own
      # (bin/ac-lib.sh:989), so an unconditional append here would spam one
      # line per pane per poll forever (ask-alert-never-clears-its-status-line).
      # backend_agent_idle distinguishes a completed turn from a resumed one -
      # collapsing both into one generic "no longer blocked" line would render
      # an idle pane and a working pane identically, which fails the bar just
      # as badly as the stale line did.
      #
      # The wait_file guard: backend_agent_blocked reads FALSE while a
      # CAPTAIN-WAIT STAMP is live (bin/ac-backend.sh:866) - that is a MASK,
      # not a real resume, and backend_agent_idle reads the same masked
      # `reported: blocked` status, so it would also answer false and land
      # this branch on "working: ... agent resumed" for a pane that is still
      # genuinely blocked, now on the captain (bin/ac-room.sh:262 stamps it
      # on any room GATE/ASK edge). Leave the latch alone while the stamp is
      # live: the stale needs-decision: line stays, and it is TRUE in this
      # window - the pane really is blocked. A stamp that clears while the
      # pane is still blocked falls back to the ordinary ask: path above on
      # the next poll (latch already set, so it neither re-wakes nor
      # re-appends); a stamp that clears once the pane has genuinely resumed
      # reaches this branch then, with an honest read.
      rm -f "$state_dir/.ask-$id"
      if backend_agent_idle "$id" 2>/dev/null; then
        ac_status_append "$id" "idle: pane no longer blocked, turn complete"
      else
        ac_status_append "$id" "working: pane no longer blocked, agent resumed"
      fi
    fi

    tail="$(backend_capture "$id" 40 | sed '/^$/d' | tail -n 25)"
    # Computed ONCE per pane per tick and reused below: $tail does not change
    # for the rest of this pass, so re-forking grep against the same input on
    # every branch that needs it is pure waste.
    if grep -qE "$AC_BUSY_RE" <<<"$tail"; then busy=1; else busy=0; fi
    hash="$(printf '%s' "$tail" | cksum | awk '{print $1}')"
    prev="$(cat "$state_dir/.hash-$id" 2>/dev/null || true)"
    changed_file="$state_dir/.change-$id"
    if [ "$hash" != "$prev" ]; then
      printf '%s\n' "$hash" >"$state_dir/.hash-$id"
      printf '%s\n' "$(ac_now)" >"$changed_file"
      rm -f "$state_dir/.stale-$id"
    fi

    marker="$(grep -E "$AC_CAPTAIN_RE" <<<"$tail" | tail -n 1 || true)"

    # RE-TASK FORGETS A REPORTED COMPLETION (stale-signal-costs-a-hard-wake).
    # The ENDED-TURN guard below stays quiet on a pane whose .seen-<id> records
    # an already-reported completion (done/failed/paused/merged). That guard is
    # the safety net for a pane that ends its turn on a PROSE-only ask, so it
    # must re-arm when the pane is re-tasked. A re-task busies the pane; once its
    # completion marker has also scrolled out of the tail (marker empty), forget
    # the reported completion so a later prose-only turn wakes the chief again.
    # Gated on an EMPTY marker so it never races the marker branch: a completion
    # still visible in the tail keeps its .seen-<id>, and clearing it there would
    # make that lingering marker read as new and re-wake.
    if [ -z "$marker" ] && [ "$busy" = 1 ]; then
      seen="$(cat "$state_dir/.seen-$id" 2>/dev/null || true)"
      if [ -n "$seen" ] && grep -qE "$AC_CAPTAIN_RE" <<<"$seen" \
          && ! grep -qE "$AC_DECISION_RE" <<<"$seen"; then
        rm -f "$state_dir/.seen-$id"
      fi
    fi

    # STALE-STAMP SUPERSESSION (see the header): the pane is BUSY while this
    # fleet's own captain-wait stamp still stands, so it demonstrably moved on
    # from the marker that parked it. Record WHICH marker was superseded (the
    # Reconcile branch below must not re-park the pane on it), say so in the
    # status log every fleet view renders, and release the stamp. No wake - the
    # chief is being told nothing new. The stamp file's own removal is the
    # once-only guard: next poll the condition is false.
    if [ -e "$wait_file" ] && [ "$busy" = 1 ]; then
      sup="$marker"
      [ -n "$sup" ] || sup="$(cat "$state_dir/.seen-$id" 2>/dev/null || true)"
      printf '%s\n' "$sup" >"$state_dir/.superseded-$id"
      ac_status_append "$id" "working: superseded ${sup:-the captain-wait stamp}"
      backend_clear_wait "$id" 2>/dev/null || true
    fi

    if [ -n "$marker" ]; then
      seen="$(cat "$state_dir/.seen-$id" 2>/dev/null || true)"
      seen_hash="$(cat "$state_dir/.seen-hash-$id" 2>/dev/null || true)"
      if ! marker_seen "$marker" "$seen"; then
        printf '%s\n' "$marker" >"$state_dir/.seen-$id"
        # A NEW marker re-parks the pane: the supersession record covers the
        # OLD one only, never a standing immunity from being stamped again.
        rm -f "$state_dir/.superseded-$id"
        ac_status_append "$id" "$marker"
        # herdr UI stamp: a captain-wait marker parks the pane BLOCKED until
        # the answering ac-send or a later non-decision marker clears it -
        # contract: ac-backend.sh CAPTAIN-WAIT STAMP. Advisory: a stamp
        # failure never blocks the wake.
        # BUSY GUARD (same polarity as Reconcile below): only a PARKED pane is
        # stamped. A stamp taken while busy can only be released by the
        # supersession above, which also fires while busy - so that release
        # lands with no state transition ahead of it, and herdr (which re-adopts
        # an agent on a state TRANSITION, never on screen churn) then holds NO
        # identity for the pane until its turn ends, emptying the grouped agents
        # panel. Not skipped, DEFERRED: Reconcile stamps this same marker the
        # moment the pane reads non-busy. The guard covers this CALL only - the
        # status append above and the wake below stay unconditional.
        if grep -qE "$AC_DECISION_RE" <<<"$marker"; then
          if [ "$busy" = 0 ]; then
            backend_mark_wait "$id" "$marker" 2>/dev/null || true
          fi
        else
          backend_clear_wait "$id" 2>/dev/null || true
        fi
        printf '%s\n' "$hash" >"$state_dir/.seen-hash-$id"
        # LAST-MOMENT RECHECK (see the PUSH CHANNEL's double-publish note). The
        # `seen` read above is already STALE here: the status append and a
        # BACKEND call sit between them, tens of milliseconds in which the agent
        # can announce the very same completion. ac-done.sh stamps .seen-<id>
        # BEFORE it publishes, so a stamp that is no longer OUR OWN write and
        # still covers this marker means that record exists or is one syscall
        # away - publishing now would be the second one. Anything else (our
        # stamp still standing, or a stamp for a DIFFERENT announcement) wakes
        # as before: an extra wake is cheap, a lost one is not.
        seen_now="$(cat "$state_dir/.seen-$id" 2>/dev/null || true)"
        if [ "$seen_now" = "$marker" ] || ! marker_seen "$marker" "$seen_now"; then
          queue_wake report "$id" "$marker"
          printf 'report:%s\n' "$id"
          return 0
        fi
      elif grep -qE "$AC_DECISION_RE" <<<"$marker" \
          && [ ! -e "$wait_file" ] \
          && [ "$marker" != "$(cat "$state_dir/.superseded-$id" 2>/dev/null || true)" ] \
          && [ "$busy" = 0 ]; then
        # Reconcile: a pane still PARKED on an already-seen captain-wait
        # marker but carrying no stamp (the marker predates the stamp
        # feature, or a steer cleared it and the pane never moved on) is
        # re-stamped silently - no wake, the chief already knows. The busy
        # guard keeps a working pane (old marker still in its tail)
        # unstamped, and the supersession record keeps this branch from
        # re-parking a pane the block above just freed the moment its tail
        # reads non-busy again (see STALE-STAMP SUPERSESSION in the header).
        backend_mark_wait "$id" "$marker" 2>/dev/null || true
      elif [ "$hash" != "$seen_hash" ] \
          && [ "$busy" = 0 ]; then
        # RE-WAKE: the marker is a repeat, but the pane MOVED since the wake
        # that consumed it - the shape of every gate loop past round 1, where
        # the crewmate revises and re-prints a byte-identical marker. The
        # discriminator is already on disk (the pane-tail hash recorded at that
        # wake), so this costs no capture and no backend call. The busy guard
        # keeps a working pane (old marker still in its tail) from flapping.
        printf '%s\n' "$hash" >"$state_dir/.seen-hash-$id"
        if [ -n "$seen_hash" ]; then
          queue_wake report "$id" "$marker (pane advanced since the last wake)"
          printf 'report:%s\n' "$id"
          return 0
        fi
        # PUSH ADOPT (see the PUSH CHANNEL in the header): NO hash was recorded
        # for this already-seen marker, so no wake of ours consumed it - the
        # agent's own push did (ac-done.sh stamps .seen-<id> and cannot know the
        # pane's hash). A missing discriminator is not movement: anchor it to
        # the pane as of now, SILENTLY, and the pane advancing FURTHER re-wakes
        # exactly as it does for any other marker. (The same branch quietly
        # settles a .seen-<id> that predates the re-wake channel.)
      fi
      # NO `continue` here: the ARTIFACT channel below must stay reachable for
      # a pane whose marker was already seen, or a deduped marker would silence
      # a finished stage exactly as it does today. The marker's own `continue`
      # (past the stale branch, which a pane carrying a marker never earns) is
      # re-applied after that channel.
    fi

    # ARTIFACT channel: a stage's report.md appearing or ADVANCING is a
    # completion in its own right - no pane cooperation needed, so a stage that
    # printed no marker at all (or one deduped/consumed elsewhere) still wakes
    # its chief within a poll instead of at the next turn boundary. The layout
    # is ac_task_dir's (ac-brief.sh's flat/nested contract), never guessed here,
    # and a task whose data is ambiguous is simply not reported. Dedup is by
    # CONTENT hash, not mtime: a touched-but-identical report is not new work,
    # while a revision that rewrites it wakes again.
    # The BUSY GUARD is what makes "a revision" one wake instead of one per
    # write (see the header): the pane is writing the very report we would wake
    # the chief to read, so the pane channel already covers it. A suppressed
    # pass deliberately stamps NOTHING, so the wake is DEFERRED to the first
    # quiet poll - carrying the report as it finally stands - never swallowed.
    task_dir="$(ac_task_dir "$id" 2>/dev/null)" || task_dir=""
    report="${task_dir:+$task_dir/report.md}"
    if [ -n "$report" ] && [ -f "$report" ] && [ "$busy" = 0 ]; then
      rhash="$(cksum <"$report" | awk '{print $1}')"
      if [ "$rhash" != "$(cat "$state_dir/.report-hash-$id" 2>/dev/null || true)" ]; then
        printf '%s\n' "$rhash" >"$state_dir/.report-hash-$id"
        queue_wake report "$id" "report.md ready at $report (artifact channel)"
        printf 'report:%s\n' "$id"
        return 0
      fi
    fi

    # A pane carrying a marker is never stale (it said something) - the
    # marker branch's original `continue`, moved past the artifact channel.
    if [ -n "$marker" ]; then continue; fi

    idle=$(( $(ac_now) - $(cat "$changed_file" 2>/dev/null || ac_now) ))
    if [ "$idle" -ge "${AC_STALE:-240}" ] && [ ! -e "$state_dir/.stale-$id" ] \
      && ! ac_chief_gate_parked "$id" && ! ac_chief_child_live "$state_dir" "$id"; then
      if [ "$busy" = 0 ]; then
        if backend_agent_idle "$id" 2>/dev/null; then
          # COMPLETION ALREADY REPORTED (stale-signal-costs-a-hard-wake): the
          # pane ended its turn but .seen-<id> holds a chief-facing completion
          # (done/failed/paused/merged - an AC_CAPTAIN_RE match that is NOT
          # captain-wait) whose report: wake already fired from the marker
          # branch. The marker has since scrolled past the bounded 25-line tail,
          # so the pane now reads as a bare ended turn - but the chief was told,
          # and .stale-<id> is cleared by every cosmetic TUI redraw, so without
          # this the loud ended: wake re-fires every quiet window forever. Anchor
          # SILENTLY instead (touch .stale-<id> like the other silent-anchor
          # branches, plus a status note): no wake. The re-task clear above drops
          # .seen-<id> the moment the pane is seen busy again, which re-arms this
          # net for genuinely-new prose-only work.
          seen="$(cat "$state_dir/.seen-$id" 2>/dev/null || true)"
          if [ -n "$seen" ] && grep -qE "$AC_CAPTAIN_RE" <<<"$seen" \
              && ! grep -qE "$AC_DECISION_RE" <<<"$seen"; then
            touch "$state_dir/.stale-$id"
            ac_status_append "$id" "ended its turn after a reported completion - awaiting reap"
            continue
          fi
          # ENDED-TURN LOUD WAKE (header): the pane is not quiet-while-working,
          # it is DONE and waiting on the chief with nothing the marker regex
          # can see. Advisory stamp, exactly like the marker path: a failure
          # never blocks the wake. A chief supervising a live crewmate never
          # reaches here - ac_chief_child_live guards the WHOLE arm one rung up
          # (header: SUPERVISING-CHIEF QUIET), because a chief that obeys its
          # charter reports in PROSE and so can never earn the quiet anchor above.
          touch "$state_dir/.stale-$id"
          ac_status_append "$id" "blocked: ended its turn with no report line"
          backend_mark_wait "$id" "ended its turn with no report line" 2>/dev/null || true
          queue_wake ended "$id" "ended its turn ${idle}s ago with no report line - read the pane, the ask may be prose"
          printf 'ended:%s\n' "$id"
          return 0
        else
          # SUPERVISING-CHIEF QUIET now guards this arm from one rung up, so
          # everything reaching here is a genuinely-unsupervised quiet pane:
          # today's soft stale:, unchanged.
          touch "$state_dir/.stale-$id"
          queue_wake stale "$id" "quiet for ${idle}s with no report line"
          printf 'stale:%s\n' "$id"
          return 0
        fi
      fi
    fi
  done 3< <(ac_crew_metas "$state_dir" self)
  return 1
}

started="$(ac_now)"
remote_iv="$(remote_poll_interval)"
next_remote=$(( started + remote_iv ))

# PUSH CHANNEL arm snapshot (see the header): the records already sitting in
# this scope's spool are the chief's undrained backlog, not news - only a name
# outside this set is a push worth exiting on.
push_spool="$(ac_wake_spool_path "$state_dir" "${AC_SCOPE:-}")"
armed_records=""
for _rec in "$push_spool"/*; do
  [ -e "$_rec" ] && armed_records="$armed_records|${_rec##*/}|"
done

push_adopt_report() {
  # push_adopt_report <id> - the ARTIFACT twin of the PUSH ADOPT branch above,
  # and the reason a pushed completion wakes the chief ONCE. An agent that
  # finishes writes its report.md AND pushes; the push is the wake, so the
  # report that came with it is the SAME completion, not a second one - yet the
  # artifact channel would find it unstamped on the very next poll and publish
  # again. So the exit anchors .report-hash-<id> to what exists RIGHT NOW,
  # silently, exactly as the marker branch anchors .seen-hash-<id> when it finds
  # no discriminator. It cannot swallow news: the anchor is taken milliseconds
  # after the agent's publish, a report written or REWRITTEN after it differs
  # from the anchor and wakes as always, and a task with no report yet is left
  # unstamped so its first one wakes. It lives here and not in ac-done.sh
  # because a crewmate has no AC_HOME (ac-spawn.sh strips it) and so cannot
  # resolve ac_task_dir at all. RESIDUAL, stated rather than hidden: a push that
  # reaches the chief WITHOUT this exit (no watcher armed at the time, so the
  # record is drained at a turn boundary) is unanchored and still costs one
  # artifact wake - failing toward waking, which is the direction this whole
  # channel is built to fail in.
  local id="$1" dir report rhash
  dir="$(ac_task_dir "$id" 2>/dev/null)" || return 0
  report="${dir:+$dir/report.md}"
  [ -n "$report" ] && [ -f "$report" ] || return 0
  rhash="$(cksum <"$report" | awk '{print $1}')"
  printf '%s\n' "$rhash" >"$state_dir/.report-hash-$id"
}

pushed_record() {
  # pushed_record - the id of the first spool record that was NOT there at
  # arm, else 1. Records are never CLAIMED here: draining one is the drain's
  # alone, so the chief still gets it in full. It does anchor the artifact
  # channel for every new COMPLETION record (kind `report`, what ac-done.sh
  # publishes) - all of them, not only the one this exit names, since two
  # agents pushing inside one poll wait are two completions the chief drains
  # together.
  local rec name kind rid first=""
  for rec in "$push_spool"/*; do
    [ -e "$rec" ] || continue
    name="${rec##*/}"
    case "$armed_records" in *"|$name|"*) continue ;; esac
    kind="$(awk -F'\t' 'NR==1 {print $2; exit}' "$rec" 2>/dev/null || true)"
    rid="$(awk -F'\t' 'NR==1 {print $3; exit}' "$rec" 2>/dev/null || true)"
    [ -n "$first" ] || first="${rid:-unknown}"
    if [ "$kind" = report ] && [ -n "$rid" ]; then
      push_adopt_report "$rid"
    fi
  done
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

# Main loop - identical with or without crew in flight: check_fleet is a
# no-op over zero metas, so an IDLE watcher (see header) keeps beating the
# beacon and serving the remote slot until heartbeat instead of exiting.
while :; do
  # The push check leads the cycle: a nudged watcher must exit in
  # milliseconds, without first paying for a pane pass.
  if pushed="$(pushed_record)"; then
    printf 'push:%s\n' "$pushed"
    exit 0
  fi
  publish_beacon "$(ac_now)"
  if check_fleet; then
    exit 0
  fi
  if [ "$once" = 1 ]; then
    # At most one poll per --once checkpoint, and only after a quiet pane
    # pass (pane wakes win the pass; poll's wakes are durable either way).
    if [ "$remote_iv" -gt 0 ] && remote_poll_allowed && check_remote; then
      exit 0
    fi
    printf 'check:quiet\n'
    exit 0
  fi
  if [ "$remote_iv" -gt 0 ] && [ "$(ac_now)" -ge "$next_remote" ]; then
    next_remote=$(( $(ac_now) + remote_iv ))
    if remote_poll_allowed && check_remote; then
      exit 0
    fi
  fi
  if [ $(( $(ac_now) - started )) -ge "${AC_HEARTBEAT:-600}" ]; then
    printf 'heartbeat\n'
    exit 0
  fi
  poll_wait "${AC_POLL:-15}"
done
