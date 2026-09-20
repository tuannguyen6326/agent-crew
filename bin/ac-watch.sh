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
# BUSY-STALL BOUND (code-reviewer-plugin-has-no-self-timeout). The arms above
# all read a pane that has gone QUIET; a pane hung INSIDE one tool call is the
# opposite and was invisible to every one of them. Its harness keeps rendering
# the busy footer, so AC_BUSY_RE reads busy=1 and BOTH the artifact channel and
# the stale/ended arm are gated off, while a footer that renders an elapsed
# counter also rewrites the tail hash every poll, resetting .change-<id> and
# clearing .stale-<id>. Two independent guards, each alone enough to make the
# fleet read a hung crewmate as healthy - the live case was a delegated code
# reviewer that returned neither findings nor an error for over an hour and
# stopped only when a human noticed. So a busy RUN past AC_BUSY_MAX seconds
# (default 2700, 0 disables) wakes on the existing `stale` reason with its own
# message. The SAME bound the verifier arm already has (AC_PANE_STALL_MAX,
# ac-pane-agent.sh), reached with the data this watcher already holds, because
# ac-watch.sh reads no transcript and a transcript-shaped bound would cover only
# the harnesses that write one.
#
# The clock is a run stamp written on the busy 0->1 edge, never .change-<id>:
# defeating the footer guard alone still leaves the hash guard free to reset the
# clock forever. It fires ONCE per run (.busy-stalled-<id>, the silent-anchor
# discipline of the branches around it), and both files clear when the pane goes
# non-busy, so the next run is bounded afresh.
#
# The one suppression is an UNEXPIRED busy declaration (chief_busy_declared):
# ac-verify.sh and ac-gate.sh write it before entering one bounded synchronous
# call of up to AC_VERIFY_TIMEOUT, well past this bound, so a roomchief in a
# review round - and a crewmate running crew-verify - is legitimately blocked,
# not stalled. It is bounded by construction and expires on its own. The two
# CHIEF-QUIET predicates guarding the stale arm are deliberately NOT applied:
# they exist to keep a QUIET supervising chief quiet, and a chief hung inside a
# call is the case this arm exists to surface. Fail direction, chosen once and
# stated: one extra wake per busy run, never silence.
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
# STALE DEFERRAL (watch-stale-defer-on-declared-wait). The stale arm measured
# idle time alone, and its one dedup (.stale-<id>) is cleared by any cosmetic
# redraw - so a worker that had SAID why it is quiet, or one parked at a gate on
# the captain, was re-reported stale every AC_STALE window. On the branch about
# to emit stale: (never the healthy path, which pays nothing, and never ended:),
# the worker's word is read first, in two forms (declared_wait owns the reads):
#  - DECLARED WAIT: the LAST line of state/<id>.status (the line ac-crew-state.sh
#    reports) is a captain-wait marker (AC_DECISION_RE: needs-decision:,
#    blocked:, checks-passed:) or `paused:` - the AC_CAPTAIN_RE verbs that mean
#    "stopped on purpose"; `done:` is NOT a wait (it waits on the chief's reap,
#    which the stale wake exists to prompt), and this watcher's OWN wait-shaped
#    notes (WATCH_ASK_NOTE, WATCH_ENDED_NOTE) are its verdicts, not the worker's
#    word, so they never defer.
#  - GATE PARKED: the line explains nothing, but the latest review findings file
#    (the family's newest verify/codereview round, or the crew-ship run's
#    findings/review.json - newest mtime wins) holds a finding whose `action`
#    is exactly `ask-user` with no recorded `decision`, read by jq KEY - a
#    description or branch name that merely contains the word parks nothing.
#    LIMITATION, stated: the room is NOT consulted. The ship pipeline records the
#    captain's decision ON the finding (bin/ac-ship.sh finish contract), so that
#    pairing is by key; a verify round's findings.json carries no decision field
#    and the room grammar has no finding-id token, so a decided-but-not-yet-
#    re-reviewed verify ask-user keeps deferring until the next round's file
#    replaces it - bounded by the restart rule below, never a cancellation.
# A deferral RESTARTS the idle clock (.change-<id>, the stamp the arm measures
# from - not merely .stale-<id>) and logs `deferred-stale:<id> <reason>` to the
# arm log, ONCE per declaration (.deferred-<id> holds the key: the status line
# plus the log's byte size, or the findings path plus its content hash). The
# SAME declaration a full AC_STALE window later falls through to today's stale:
# - the declaration itself went stale - and a NEW one defers again. The
# declaration outranks the liveness verdict because it is what the worker said
# about its own silence; it never outranks the clock twice.
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
# interactive prompt - herdr's pane state or Orca's agentWait), `ended:<id>` (the ENDED-TURN LOUD
# WAKE above - a pane that finished its turn with no marker), `stale:<id>`
# (a pane merely quiet while working). Neither of those two is ever a chief
# supervising a live crewmate, see SUPERVISING-CHIEF QUIET above. `remote:<rid>`
# (new remote captain orders arrived), `remote-failed:<last-rid|none>` (the poll
# DIED mid-ingest and abandoned the rest of the batch - the named rid is the
# last one that landed, so re-sending starts after it; see FAILED POLL under the
# Remote-order slot below), `remote-timeout:<last-rid|none>` (the poll blew
# through its ceiling and was killed - a WEDGED transport, not a dead spool, and
# a different prefix precisely so the reader can tell the two apart; see HUNG
# POLL below), `heartbeat`, `signal:<NAME>` (a TERM/INT
# - either the owner's own `--release`, see OWNER-MARKED RELEASE, or a kill
# from outside, see EXTERNAL KILLS; the reason text says which), `check:quiet`
# (the --once checkpoint below completed one bounded pane pass plus one bounded
# remote poll and found nothing actionable). Every one of
# them exits 0: the reason line, not the exit status, is the payload the chief
# reads. A reason may carry ONE trailing clause after ` - `, on the same line
# (the reader keeps only the last non-empty line): a wake branch whose durable
# record failed to write appends `WAKE NOT DURABLE: ...` (emit_reason), and
# `signal:<NAME>` appends `poll interrupted mid-flight; last rid ingested:
# <rid|none>` when the kill landed inside a poll. The prefix before ` - ` is
# the classifier; the clause is for the chief.
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
# (poll queues the wakes durably itself for every order it ingests - see FAILED
# POLL for the one that does not; the watcher then exits
# `remote:<first-rid>` so the chief drains at once). Interval resolution:
# AC_REMOTE_POLL env > config/remote-poll-interval > 300; the 300 default
# applies only when an executable config/remote-poll hook exists - no
# transport, no slot - and a non-numeric or 0 value at any layer turns the
# slot off. LOCK GATE (one poller fleet-wide): the slot runs
# ONLY in the fleet-scoped watcher (no AC_WATCH_ONLY) whose recorded owner
# (state/.watcher-owner) IS the session-lock holder (state/.session-lock
# pid=); scoped roomchief watchers and foreign-lock homes NEVER poll.
# --once runs at most one poll (same gate), after a quiet pane pass.
# FAILED POLL (poll-or-true-swallows-a-failed-ingest). `ac-remote.sh poll` exits
# non-zero when it DIED, the usual cause being that ingest_stream could not
# publish a wake for an rid: it rolls that stash back, dies, and drops every
# later line on the same stdin UNREAD - which is why its own message tells the
# operator to re-send that rid and everything after it. Not the only cause,
# which is why the status alone is never the whole diagnosis: ingest_stream has
# a second ac_die whose remedy is the opposite (a stash that SURVIVED a failed
# publish now blocks every re-delivery of that rid - remove it, then re-send),
# and under errexit the poll can also die before reading anything. Only the
# producer knows which, so its own last stderr line is forwarded verbatim in the
# wake rather than guessed at here. A failing transport HOOK is none of these:
# it is warned and swallowed there, a designed QUIET poll that exits 0.
# Reading stdout alone made the death invisible in both its shapes - nothing
# printed yet read as a quiet poll, and a mid-batch death read as a NORMAL one,
# a success report over the orders just dropped. The status is now read, and the
# death gets the same two channels every other actionable event here gets: a
# durable `remote-failed` wake (id `captain`, as the orders' own wakes are) and
# the exit reason line above - which a death carries whether or not it ingested
# anything first, since the watcher exits on that path either way and naming the
# last rid that landed costs no extra wake.
# ONE DURABLE WAKE PER EPISODE, the same mark-then-wake latch shape as the pane
# branches and for the UNOBSERVABLE reason - state/.remote-poll-failed stands
# while the fault does, so a persistent fault (an unwritable spool) costs the
# arm log a line per interval instead of the chief a wake record per interval,
# and the first poll that COMPLETES clears it and re-arms the loud channel. KEEP
# POLLING: a death never exits the loop except through its own reason line, and
# the orders a failed poll DID ingest keep their own wakes, published before it.
# RESIDUAL, stated rather than hidden: the fault that kills the poll is often
# the fault that kills the wake (an unwritable spool reaches both), and then the
# durable half is lost - queue_wake's own contract below governs that case, so
# the loss is logged loudly and the reason line still carries the death.
#
# HUNG POLL (a-hung-transport-hook-wedges-the-whole-watcher-loop). A poll that
# DIES gets the two channels above; a poll that NEVER RETURNS used to get
# nothing at all. check_remote sits between the beacon at the top of this loop
# and the poll wait at the bottom, so everything that proves this watcher alive
# is either before it (and stops being refreshed) or after it (and never runs):
# a wedged transport froze the whole loop in silence, and the only thing anyone
# eventually saw was the beacon ageing past AC_GUARD_GRACE - reported as
# WATCHER-DOWN, the exact opposite of the truth about a watcher that is alive
# and blocked.
# THE CEILING IS THE DISTRO'S, and that is the point: config/remote-poll is the
# captain's own transport, a file this distro neither ships nor tests, so a home
# whose hook is a python script or a curl without --max-time carries no bound at
# all. AC_REMOTE_POLL_TIMEOUT env > config/remote-poll-timeout > 120s
# (remote_poll_timeout). The arithmetic behind 120, measured on this fleet's own
# hook and host: a HEALTHY poll costs ~0.42s per API call over 1 + live-families
# + min(roomless,10) calls - ~6s today, ~13s at twenty live families - while the
# pathological case is 15s per call, a 36x spread that leaves a constant plenty
# of room. The upper limit is the beacon gap, which must stay under
# AC_GUARD_GRACE (300s) or the turn-end guard blocks the chief's turn demanding
# it arm a watcher that is already running: remote ceiling + pane pass + AC_POLL
# < 300. BOTH TERMS CAN BLOW IN ONE ITERATION and the SUM is what the grace has
# to hold - the beacon is published at the top of the loop, check_fleet and
# check_remote both run before the next one, and a pane pass that finds nothing
# actionable falls straight through to the remote gate. The pane pass is bounded
# by herdr_rpc_timeout (ac-backend.sh, 2s per RPC) times the RPCs a wedged pass
# spends, which is what the pass costs when every pane has already latched its
# outage: 2 per pane (window_alive's deliberate two-call ladder, and its
# `continue` lands before capture), and 4 per meta of a SKIPPED family - the
# coverage probe on the chief pane plus the crewmate pane's own - both counts
# measured against a stub that answers nothing, not derived. It was 6 until
# skip_coverage_live started REPORTING which half of the coverage test failed:
# the caller's re-probe was asking the backend the same question about the same
# chief pane a second time in one pass. So the inequality is
# R x ceiling + 120 + 15 < 300, i.e. R < 82 timed-out RPCs at the 2s default:
# the distro's own shape (room-parallel 5, a couple of panes a family) spends
# ~50 and holds at 235s (50 x 2 + 120 + 15), and a fleet past that lowers
# config/herdr-rpc-timeout rather than discovering the gap as a false
# WATCHER-DOWN. Against the LIVE test stub the same dedup reads 5 -> 4 chief-
# pane calls, because window_alive's ladder short-circuits at one call when
# the pane answers; the two counts are the same fix priced on two backends.
# WHAT A KILL COSTS is a property of the TRANSPORT, not of this distro, so this
# header claims only what it owns: the rids ac-remote.sh had already stashed AND
# published keep their own wakes, and the ceiling costs those nothing. Everything
# the poll had NOT yet handed over is the hook's business - cmd_poll reads the
# hook's whole stdout before ingesting a single line, so a hook that advances its
# own read cursor as it EMITS loses what the kill interrupts, while one that
# commits only at the end re-delivers the lot next interval (the shipped Slack
# example is the latter - commit_pending in docs/examples/slack-remote/
# remote-poll). A transport that cannot be re-read is one whose fleet must size
# config/remote-poll-timeout for its own worst poll.
# RESIDUAL THIS BOUND CREATES, named because it is new: ingest_stream commits an
# order in two steps, the stash then its wake, and says of the gap "A death
# BETWEEN the two is not covered and cannot be from here" (bin/ac-remote.sh:380).
# A ceiling kill CAN now be from here. One landing in that gap leaves a stash
# with no wake, and the stash is also the dedup sign, so that rid is silently
# burned. The gap is ~11.7 ms per rid - MEASURED on this host, five fork+execs
# from that stash `ln` to the wake's own durable `ln` inside ac_wake_publish -
# against a ceiling of seconds, and what it replaces is a watcher wedged for
# ever - but closing it belongs to ingest_stream's own commit ordering, not to
# this bound.
# SIZING THE KNOB: keep ceiling + the bounded pane pass + AC_POLL under
# AC_GUARD_GRACE - the pane pass is a term in that sum, not the `~0` it once
# was, and the arithmetic above spends it. Above the grace a
# wedged poll re-opens the very beacon gap the guard reads, and the chief is
# blocked at its turn end to arm a watcher that is already running - the exact
# false report this bound exists to kill. Deliberately NOT clamped: serving a
# value the captain did not write is the other half of that same defect.
# THE REAP IS THE PROCESS GROUP, not the pid: a kill aimed at ac-remote.sh alone
# leaves the hook and its curl children alive under ppid=1 (measured), so the
# launch runs under `set -m` to make the job its own group leader and the kill
# is TERM, grace, KILL over the negative pid. check_remote reaps on every path
# it returns through and on_signal reaps the one path that skips them all,
# naming on its way out the last rid that poll had ingested - the ceiling path
# already did, and a signal can land at ANY moment, including inside the
# stash-then-wake gap above. It gets no ceiling of its own: the reap it shares
# with the ceiling path is the same bounded TERM-grace-KILL-wait, and a handler
# is the wrong place for a third copy - it runs on the way out, with the EXIT
# trap that releases the lock behind it and every other trap deferred.
# ONE DURABLE WAKE PER EPISODE here too, on its OWN latch
# (state/.remote-poll-timeout): a wedged transport and an unwritable spool are
# different faults with different remedies, and one shared latch would leave
# whichever arrived second silent for as long as the first stood. A poll that
# COMPLETES clears both.
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
# Knobs: AC_POLL=15 AC_HEARTBEAT=600 AC_STALE=240 AC_BUSY_MAX=2700 AC_REMOTE_POLL
# AC_REMOTE_POLL_TIMEOUT=120 (one poll's ceiling; see HUNG POLL)
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

release_family_is_over() {
  # release_family_is_over <family> - 0 when the family this scoped watcher was
  # armed for is DEMONSTRABLY finished, so the watcher is an ORPHAN with no
  # roomchief left to protect and `--release` may take it.
  #
  # WHY THE OBVIOUS SIGNAL IS NOT USED, measured 2026-08-09 and recorded so it
  # is not retried: "state/<family>-chief.meta is absent" looks like the test
  # for a demoted roomchief, and it is NOT one this codebase treats as family
  # liveness - the (8e) scoped-refusal fixture holds a LIVE scoped watcher with
  # no chief meta on disk (several `rm -f "$state"/*.meta` sweeps run before
  # it), so keying on absence would release a watcher that is doing its job.
  #
  # The ROOM is the signal that actually records the transition, because
  # demotion WRITES there: ac-teardown.sh posts `DEMOTED: roomchief closed` and
  # ac-room.sh close posts `CLOSED:`. Three conditions must hold TOGETHER, and
  # the conjunction is what makes this fail-closed rather than clever:
  #   1. the family has a room at all (a scoped watcher for a family with no
  #      room - the (8e) shape - is never touched);
  #   2. the LAST tenure marker in it is DEMOTED/CLOSED, not PROMOTED, so a
  #      family that was demoted and later re-promoted is protected again;
  #   3. no <family>-chief.meta exists, so a chief that is up right now wins
  #      over any stale room line.
  # Any one of them missing means refuse, which keeps the guard's default
  # exactly where it was.
  local fam="$1" room last
  case "$fam" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
  [ ! -e "$state_dir/$fam-chief.meta" ] || return 1
  room="$(ac_room_file "$fam" 2>/dev/null || true)"
  [ -n "$room" ] && [ -f "$room" ] || return 1
  last="$(awk '
    /> *PROMOTED:/  { m = "PROMOTED" }
    /> *DEMOTED:/   { m = "DEMOTED" }
    /> *CLOSED:/    { m = "CLOSED" }
    END { print m }
  ' "$room")"
  case "$last" in DEMOTED|CLOSED) return 0 ;; esac
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
    # ORPHAN EXCEPTION. The refusal below protects a family's real-time
    # coverage on behalf of its roomchief - and when that roomchief is GONE the
    # premise it states out loud ("until its roomchief notices and re-arms") is
    # false: nobody is left to notice, so the guard was protecting a watcher on
    # behalf of a family that no longer exists while the operator had no
    # sanctioned way to stop it. release_family_is_over owns the (deliberately
    # narrow) test.
    if release_family_is_over "$scoped_fam"; then
      # The pid was found in THIS home's own .watch-only-<fam>.lock.d, so its
      # home is already settled - and the home-crossing guard below only knows
      # how to recognise a FLEET watcher, so it would refuse this orphan a
      # second time (measured). Mark it and let it through both.
      orphan_release=1
      watch_log "release ALLOWED pid=$target - scoped $scoped_role for $scoped_fam, whose roomchief is demoted/closed (orphan)"
      printf 'note: pid %s is the scoped %s for family %s, whose roomchief is DEMOTED/CLOSED - releasing the orphan (nothing is left to re-arm it).\n' \
        "$target" "$scoped_role" "$scoped_fam" >&2
    else
      case "$scoped_role" in
        wrapper) scoped_what="the harness-tracked WRAPPER of the scoped watcher for family $scoped_fam (TERMing it leaves that watcher ALIVE under PPID=1 - an orphan that keeps polling while its exit wakes no one)" ;;
        *)       scoped_what="the scoped watcher for family $scoped_fam" ;;
      esac
      watch_log "release REFUSED pid=$target - scoped $scoped_role for $scoped_fam (belongs to its roomchief)"
      printf 'refused: pid %s is %s - it belongs to that family'"'"'s roomchief; only the fleet watcher is releasable via --release. Releasing it leaves %s with no real-time coverage until its roomchief notices and re-arms. Release the FLEET watcher instead (its pid: cat %s/.watch.lock.d/pid).\n' \
        "$target" "$scoped_what" "$scoped_fam" "$state_dir" >&2
      exit 2
    fi
  fi
  # HOME-CROSSING TARGETS (see the header): --release is THIS home's own
  # remedy. Refuse BEFORE the marker is stamped, same no-trace rule as the
  # scoped guard above - a refused release must leave no trace on the pid it
  # declined to touch, whatever home it turns out to belong to.
  if [ "${orphan_release:-0}" != 1 ] && ! home_fleet_watcher_role "$target" >/dev/null; then
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
  # A skip is the FLEET watcher's instrument, and the coverage record a revoked
  # skip publishes must land on the fleet spool - queue_wake files it under
  # AC_SCOPE, so a scoped watcher carrying a skip would hand that record to
  # the very family whose roomchief is gone. Refused rather than assumed.
  if [ -n "${AC_SCOPE:-}" ]; then
    watch_log "refused: AC_WATCH_SKIP is the fleet watcher's alone, but AC_SCOPE=$AC_SCOPE is set (AC_WATCH_SKIP=$AC_WATCH_SKIP)"
    printf 'refused: AC_WATCH_SKIP cannot be combined with AC_SCOPE=%s - a scoped watcher watches its own family, it skips nothing\n' "$AC_SCOPE"
    exit 2
  fi
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

quiet_sleep() {
  # quiet_sleep <secs> - a wait ac_watcher_nudge cannot mistake for THE poll
  # wait. That nudge kills the first `sleep` that is a DIRECT CHILD of this pid
  # (ac-wake-lib.sh), so a bare `sleep` inside the poll's bound would eat a
  # push's nudge and let ac-done.sh report a watcher nudged early that is in
  # fact still mid-poll - and under a wedged transport that window is most of
  # the interval, exactly when supervision matters most. The brace group puts a
  # shell in between, so the sleep is a GRANDchild and no longer matches
  # (measured on this host); `wait` keeps a TERM firing at once, the same
  # reason poll_wait backgrounds its own sleep.
  { sleep "$1"; } &
  wait $! 2>/dev/null || true
}

poll_pid=""
poll_outfile=""
poll_errfile=""
reap_poll() {
  # reap_poll - end the bounded poll and everything it forked, or nothing when
  # none is in flight. The process GROUP, not the pid: a kill aimed at
  # ac-remote.sh alone leaves the transport hook and the curl children it
  # forked alive under ppid=1, still holding the capture open (measured), so a
  # hung transport would leak a tree per interval. `set -m` at the launch is
  # what makes that group addressable - a backgrounded job becomes its own
  # group leader - so the negative pid reaches the whole tree and never this
  # watcher, whose own group is a different one.
  [ -n "$poll_pid" ] || return 0
  kill -TERM -"$poll_pid" 2>/dev/null || true
  quiet_sleep 1
  kill -KILL -"$poll_pid" 2>/dev/null || true
  wait "$poll_pid" 2>/dev/null || true
  poll_pid=""
}

drop_poll_files() {
  # drop_poll_files - remove the bounded poll's capture files. check_remote does
  # its own once it has read them; this exists for on_signal, the one exit that
  # reaches neither, and which reap_poll made an explicitly supported path.
  [ -z "$poll_outfile" ] || rm -f "$poll_outfile" 2>/dev/null || true
  [ -z "$poll_errfile" ] || rm -f "$poll_errfile" 2>/dev/null || true
  poll_outfile=""; poll_errfile=""
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
  local sig="$1" note poll_note="" was_polling=0 last
  trap - TERM INT                       # never re-enter on a second signal
  if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; fi
  # The GUARANTEED half of the poll's reap: check_remote reaps its own job on
  # every path it returns through, and a signal is the only way out that skips
  # them all. Without this a --release mid-poll would orphan the transport hook
  # and its curl children, which is the leak the bound exists to prevent.
  [ -z "$poll_pid" ] || was_polling=1
  reap_poll
  # READ THE CAPTURE BEFORE DROPPING IT, the ceiling path's own order. This
  # route into a killed poll is the MORE reachable of the two - any TERM at any
  # moment, against a transport that had to outrun its ceiling - and it used to
  # delete the capture unread, so the orders that poll HAD ingested were nowhere
  # on the record. ac-remote.sh commits a stash and its wake in two steps: a
  # kill inside that gap burns the rid, and this file is the only evidence the
  # poll ever got that far. No wake of its own: the watcher is exiting and the
  # reason line below is already the channel the chief reads.
  if [ "$was_polling" = 1 ] && [ -n "$poll_outfile" ]; then
    last="$(awk '/^remote-order /{r=$2} END{print r}' "$poll_outfile" 2>/dev/null || true)"
    poll_note=" - poll interrupted mid-flight; last rid ingested: ${last:-none}"
  fi
  drop_poll_files
  note="$(release_note)" || note="watcher killed externally"
  watch_log "signal:$sig pid=$$ target=$poll_target - $note$poll_note"
  printf 'signal:%s pid=%s target=%s - %s%s, lock released; re-arm to restore coverage\n' \
    "$sig" "$$" "$poll_target" "$note" "$poll_note"
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
  # A failure says WHICH half: 1 = the roomchief is not live, 2 = it IS live
  # and only the beacon is stale. The caller's next question is exactly that,
  # and answering it here is what stops it asking the backend about the same
  # chief pane a second time within one pass - with a per-RPC ceiling landed,
  # the CALL COUNT is what decides whether a wedged backend keeps a sweep
  # inside its budget.
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
  [ "$age" -le "${AC_GUARD_GRACE:-300}" ] || return 2
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

busy_family_of() {
  # busy_family_of <id> - the FAMILY whose busy declaration covers <id>'s pane.
  # A chief pane is `<fam>-chief`, which ac_family_of_id does not strip (chief is
  # no stage), and ac-verify.sh/ac-gate.sh key the declaration by the bare family.
  case "$1" in
    *-chief) printf '%s\n' "${1%-chief}" ;;
    *) ac_family_of_id "$1" 2>/dev/null || printf '%s\n' "$1" ;;
  esac
}

latest_findings_of() {
  # latest_findings_of <id> - the newest review findings file bearing on <id>,
  # or return 1: the family's codereview rounds (bin/ac-verify.sh round_root;
  # round ids sort by time, so an equal mtime goes to the later glob entry) and
  # the crew-ship run's review step (bin/ac-ship.sh findings/<step>.json under
  # the leased worktree's .crew/ship/current), newest mtime winning.
  local id="$1" wt cand best="" best_m=0 m
  wt="$(ac_meta_get "$state_dir/$id.meta" worktree 2>/dev/null || true)"
  for cand in "$(ac_data_dir)/$(busy_family_of "$id")/verify/codereview"/*/findings.json \
              "${wt:-/nonexistent}/.crew/ship/current/findings/review.json"; do
    [ -f "$cand" ] || continue
    m="$(ac_file_mtime "$cand")" || continue
    [ "$m" -ge "$best_m" ] && { best="$cand"; best_m="$m"; }
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# This watcher's OWN wait-shaped status notes. Written by the ask and ended
# arms below and read back by declared_wait, which must not mistake the
# watcher's verdict for the worker's word - one constant keeps the two in step.
WATCH_ASK_NOTE="needs-decision: pane blocked on an interactive prompt"
WATCH_ENDED_NOTE="blocked: ended its turn with no report line"

declared_wait() {
  # declared_wait <id> - print `<reason>\t<dedup key>` when <id>'s silence is
  # EXPLAINED (contract: STALE DEFERRAL in the header), else return 1. The
  # status log's last line is read first: a captain-wait marker
  # (AC_DECISION_RE) or `paused:` - the one AC_CAPTAIN_RE completion verb that
  # means stopped on purpose - explains a quiet pane when the WORKER wrote it;
  # `done:` does not, it waits on the chief's reap, which the stale wake exists
  # to prompt, and this watcher's own notes above are its verdicts, not the
  # worker's word. The key is the line plus the log's byte size, so a
  # re-appended identical line is a new declaration. Only when the line
  # explains nothing are the review findings consulted, by KEY (a description
  # that merely mentions the word must not park anything): an ask-user with no
  # recorded captain decision.
  local id="$1" f last wait_re verb
  f="$(ac_task_status "$id")"
  last="$(tail -n 1 "$f" 2>/dev/null | cut -d' ' -f2-)"
  # The marker branch appends the pane line verbatim, TUI glyph prefix and all,
  # so the anchoring is AC_DECISION_RE's own with paused added to its verb
  # group (an overridden regex the substitution cannot see keeps its own set).
  wait_re="${AC_DECISION_RE/(needs-decision|blocked|checks-passed):/(needs-decision|blocked|checks-passed|paused):}"
  if [ -n "$last" ] && [ "$last" != "$WATCH_ASK_NOTE" ] && [ "$last" != "$WATCH_ENDED_NOTE" ] \
      && grep -qE "$wait_re" <<<"$last"; then
    verb="$(grep -oE '(needs-decision|blocked|checks-passed|paused):' <<<"$last" | head -n 1)"
    printf 'declared-wait %s\t%s:%s\n' "${verb%:}" "$(wc -c <"$f" | tr -d ' ')" "$last"
    return 0
  fi
  f="$(latest_findings_of "$id")" || return 1
  jq -e '(if type == "array" then . else (.findings // []) end)
         | any(.action == "ask-user" and ((.decision // "") == ""))' "$f" >/dev/null 2>&1 \
    || return 1
  printf 'gate-parked\t%s:%s\n' "$f" "$(cksum <"$f" | awk '{print $1}')"
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

remote_poll_timeout() {
  # remote_poll_timeout - seconds one `ac-remote.sh poll` may run before this
  # watcher kills it (see HUNG POLL in the header). Resolution: the same ladder
  # remote_poll_interval takes - AC_REMOTE_POLL_TIMEOUT env >
  # config/remote-poll-timeout > 120. Anything that is not a positive integer
  # falls back to the default rather than turning the bound off: the ceiling is
  # what keeps the loop alive, so there is deliberately no `0 = never`.
  local t="${AC_REMOTE_POLL_TIMEOUT:-}"
  [ -n "$t" ] || t="$(ac_config_read remote-poll-timeout "")"
  case "$t" in ''|*[!0-9]*|0) t=120 ;; esac
  printf '%s\n' "$t"
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
  # durably); returns 1 on a quiet poll. A poll that DIED is neither, and the
  # header's FAILED POLL block owns why it now gets a voice - what matters HERE
  # is the two shapes the branches below are cut for: a death before the first
  # rid lands prints NOTHING (so stdout alone read it as a quiet poll), and a
  # death mid-batch prints the orders it did ingest (so stdout alone read it as
  # a normal one, over the orders it had just dropped).
  #
  # `|| true` was never what kept the loop alive, whatever it looks like. Both
  # call sites invoke this from an `if` CONDITION, where bash suspends errexit
  # through the condition list and into the function body, so with or without
  # it a failed substitution just leaves `out` empty and the next line runs -
  # measured on this host's bash 3.2.57. It only forged the status to 0.
  # `|| rc=$?` is safe here AND at top level, which a bare substitution is not.
  #
  # STDERR is captured for the same reason the status is: a non-zero exit is
  # not single-cause, and only the producer knows which cause it was (the
  # header names them), so its own last line is forwarded rather than guessed
  # at. Nothing else would read it - ac-watch-autoarm.sh runs this watcher as
  # `2>/dev/null`. A fixed path rather than cmd_poll's `mktemp`: an mktemp that
  # failed would leave the redirect target empty, and a redirect that cannot
  # open makes the poll read as DEAD without ever running it.
  local out err rc=0 first last detail errfile outfile ceiling began timed_out=0
  local marker="$state_dir/.remote-poll-failed" tmarker="$state_dir/.remote-poll-timeout"
  # Module-level too (drop_poll_files), so a signal mid-poll sweeps them.
  poll_errfile="$state_dir/.remote-poll.err.$$"
  poll_outfile="$state_dir/.remote-poll.out.$$"
  errfile="$poll_errfile"
  outfile="$poll_outfile"
  : >"$errfile" 2>/dev/null || errfile=/dev/null
  : >"$outfile" 2>/dev/null || outfile=/dev/null
  ceiling="$(remote_poll_timeout)"
  # A FILE, not a command substitution, and a BACKGROUND job, not a foreground
  # one - the two halves of the bound, each answering a different hang.
  # `$(...)` reads until EOF on the pipe rather than until the child exits, so
  # a hook that exits cleanly while a child of its OWN still holds stdout wedges
  # the capture for as long as that child lives (measured: 6.6s against the
  # child's 0.01s exit, and for ever if the child is). Writing to a file makes
  # the poll's end the poll's own exit, which a bounded wait can judge - and the
  # partial output is on disk either way, so a killed poll can still name the
  # last rid that landed. Backgrounding is what gives us a pid to judge at all,
  # and parking in `wait`/`quiet_sleep` rather than a foreground child is what
  # keeps the TERM trap firing in milliseconds (measured: a foreground child
  # defers it for its whole remaining runtime).
  set -m
  "$(dirname "$0")/ac-remote.sh" poll >"$outfile" 2>"$errfile" &
  poll_pid=$!
  set +m
  began=$SECONDS
  while kill -0 "$poll_pid" 2>/dev/null; do
    if [ $(( SECONDS - began )) -ge "$ceiling" ]; then timed_out=1; break; fi
    # 0.2s, ac-sync.sh's fetch_bounded granularity, not 1s: `kill -0` right
    # after the fork is always true, so EVERY poll pays at least one tick -
    # and --once is the chief's own foreground checkpoint, which would wear it
    # whole.
    quiet_sleep 0.2
  done
  if [ "$timed_out" = 1 ]; then
    reap_poll
    rc=124
  else
    wait "$poll_pid" 2>/dev/null || rc=$?
    poll_pid=""
  fi
  out="$(cat "$outfile" 2>/dev/null || true)"
  err="$(tail -n 1 "$errfile" 2>/dev/null || true)"
  [ "$errfile" = /dev/null ] || rm -f "$errfile"
  [ "$outfile" = /dev/null ] || rm -f "$outfile"
  poll_outfile=""; poll_errfile=""
  last="$(printf '%s\n' "$out" | awk '/^remote-order /{r=$2} END{print r}')"
  if [ "$rc" -eq 0 ]; then
    # A poll that ran to the end is the proof the fault is over, so the next
    # death - of EITHER kind - is loud again.
    rm -f "$marker" "$tmarker"
    [ -n "$out" ] || return 1
    first="$(printf '%s\n' "$out" | awk '/^remote-order /{print $2; exit}')"
    printf 'remote:%s\n' "${first:-unknown}"
    return 0
  fi
  if [ "$timed_out" = 1 ]; then
    # A TIMED-OUT poll is not a DEAD one: the transport is wedged, not the
    # spool, and the remedy is the transport - so it gets its own reason prefix,
    # its own wake kind and its OWN episode latch. Sharing the death's latch
    # would leave whichever fault arrived second silent for as long as the first
    # stood. Everything else is the death's shape verbatim, including exiting
    # after a partial batch: the orders this poll DID ingest published their own
    # wakes before the kill, and naming the last of them costs no extra wake.
    detail="poll exceeded ${ceiling}s and was killed; last rid ingested: ${last:-none}"
    [ -z "$err" ] || detail="$detail - $err"
    if [ ! -e "$tmarker" ]; then
      queue_wake remote-timeout captain "$detail"
      # LATCH ON THE RECORD, NOT THE ATTEMPT. The latch is cleared only by a
      # poll that COMPLETES, so one set against a publish that failed stands
      # for the whole episode and every later timeout takes the quiet repeat
      # branch below - leaving the episode with nothing durable about it
      # anywhere. The fault that wedges the transport and the fault that
      # breaks the spool are different ones, but nothing rules out both.
      if [ "$wake_published" = 1 ]; then : >"$tmarker"; fi
      watch_log "remote poll TIMED OUT: $detail"
    else
      watch_log "remote poll TIMED OUT again, same episode: $detail"
      [ -n "$out" ] || return 1
    fi
    emit_reason "remote-timeout:${last:-none}"
    return 0
  fi
  detail="poll exited $rc; last rid ingested: ${last:-none}"
  [ -z "$err" ] || detail="$detail - $err"
  if [ ! -e "$marker" ]; then
    # The FIRST death of an episode, told on BOTH channels this watcher has:
    # a durable wake, which ac-wake-drain.sh renders verbatim whatever the
    # kind, and the exit reason line, which ac-watch-autoarm.sh hands straight
    # back to the chief on its catch-all arm. Marked before the wake, the same
    # order every pane branch here uses.
    queue_wake remote-failed captain "$detail"
    # LATCH ON THE RECORD, NOT THE ATTEMPT - see the timeout branch above. Here
    # the two faults are actively CORRELATED: an unwritable state dir kills the
    # poll and the wake alike, which is exactly the episode that used to go
    # entirely unrecorded.
    if [ "$wake_published" = 1 ]; then : >"$marker"; fi
    watch_log "remote poll FAILED: $detail"
  else
    # REPETITION. The slot re-polls every remote_iv, so a persistent fault
    # would wake the chief on every interval for as long as it lasts - the
    # treadmill every dedup marker in this watcher exists to stop. One durable
    # wake per EPISODE once one has REACHED DISK; the rest goes to the arm log.
    # The exception is the correlated fault the latch above defers on: while
    # the spool itself is unwritable no record can latch, so every death exits
    # loud with the loss on its reason line, one chief turn per interval,
    # until the spool is writable again - accepted (captain ruling
    # 2026-09-19), because the alternative was an episode nobody ever heard of.
    # The marker is presence-only and scope-free: the lock gate above means
    # exactly one watcher fleet-wide ever polls, so it has exactly one writer.
    watch_log "remote poll FAILED again, same episode: $detail"
    # Nothing ingested and nothing new to say - stay quiet and keep polling.
    [ -n "$out" ] || return 1
  fi
  # A death that DID ingest part of its batch exits FAILED too, never
  # `remote:<first>`: the watcher exits on this path either way, so naming the
  # last rid that landed costs no extra wake and is the whole point of the
  # repair - a repeat is still a success report over dropped orders otherwise.
  # The orders that landed keep their own wakes, published before the death.
  emit_reason "remote-failed:${last:-none}"
  return 0
}

# 1 between publishes: the flag means "the wake the CURRENT branch queued
# reached disk", and a branch that queued none must read it as clean.
wake_published=1
queue_wake() {
  # queue_wake <kind> <id> <payload> - durable actionable wake, the record
  # every consumer (the crewchief's drain, a roomchief's scoped drain, the
  # inbox) reads. captain ruling first cut a captain notification
  # (config/wedge-alarm) down to ask/gone/unobservable+handback (a
  # notification on every wake was noise on a busy fleet). The captain rule
  # (notify only when something needs the captain / blocked-by-captain only) went
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
  # A FAILED publish is never swallowed: every call site is reached from a
  # command inside an `if` condition list, where bash suspends errexit for the
  # whole list and inside the functions it calls, and a PANE branch's own dedup
  # latch has ALREADY advanced by the time this runs (the two remote-EPISODE
  # latches no longer do - they read wake_published below instead),
  # so a silent failure would lose the wake with no trace and no retry. The
  # failure is logged through watch_log AND ridden out on the exit reason line
  # by emit_reason below - the arm log is a forensic trail with no production
  # reader, and under an unwritable state dir it cannot be written either, so
  # it is a record rather than a channel. The pass continues: the reason line
  # wakes the chief this once and now SAYS the durable record is missing, which
  # is the difference between one lost wake and a loss nobody ever learns of.
  # wake_published is the STATUS without the status: a non-zero RETURN here
  # would reach twelve call sites that never test one, and the direction that
  # error fails in is a dead watcher - the fleet losing its eyes over a wake it
  # could not write. A module flag costs those sites nothing and lets the one
  # caller that must know - an episode latch, which means "the chief has been
  # told" - read whether the record actually exists. The flag is AMBIENT, so
  # whoever reads it must reset it to 1 (emit_reason does; the coverage site
  # does by hand): a 0 left standing was measured riding out on the next
  # reason line of a branch that queued no wake at all - "WAKE NOT DURABLE"
  # over a healthy spool, the false alarm on the one channel the chief reads.
  wake_published=1
  if ! ac_wake_publish "$state_dir" "${AC_SCOPE:-}" "$1" "$2" "$3"; then
    wake_published=0
    watch_log "wake-publish FAILED kind=$1 id=$2 scope=${AC_SCOPE:-fleet} - record NOT durable, payload: $3"
  fi
}

emit_reason() {
  # emit_reason <reason> - print the exit reason line, carrying the loss when
  # the wake this branch just queued never reached disk.
  #
  # THE ONE LIVE CHANNEL, and this is why it is this one. The contract used to
  # promise that a failed publish "goes loudly through watch_log (arm log +
  # stderr)". Neither half reaches anyone: bin/ac-watch-autoarm.sh runs this
  # watcher as `2>/dev/null` and reads only the last non-empty STDOUT line, so
  # that stderr is destroyed before it exists, and state/.watcher-arm.log has
  # no production reader at all. Worse, in the PRINCIPAL failure class - an
  # unwritable state dir - the arm log cannot be written either, so both halves
  # of the promised channel fail together with the publish they were meant to
  # report. The exit reason line survives that fault and is already read on
  # every arm. It must be the SAME line: the reader takes the last non-empty
  # one, so a second line would be mistaken for the reason itself and an
  # earlier one would be dropped.
  if [ "$wake_published" = 1 ]; then
    printf '%s\n' "$1"
  else
    printf '%s - WAKE NOT DURABLE: this line is the only record; the state dir may be unwritable\n' "$1"
  fi
  wake_published=1
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
  local busy_file busy_age
  local task_dir report rhash sup alive_rc busy wait_file cov_rc
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
        cov_rc=0; skip_coverage_live "$skip_fam" || cov_rc=$?
        if [ "$cov_rc" = 0 ]; then
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
        # cov_rc 2 IS "roomchief live, beacon stale" - the same fact a second
        # ac_roomchief_live used to buy from the backend.
        if [ "$cov_rc" = 2 ] \
           && { chief_busy_declared "$skip_fam" || rearm_grace_active "$skip_fam"; }; then
          continue
        fi
        if [ ! -e "$state_dir/.skip-revoked-$skip_fam" ]; then
          watch_log "skip revoked: $skip_fam scoped coverage down (roomchief gone or beacon stale past re-arm grace) - fleet watcher covering its panes directly"
          # A revoke must WAKE, not merely log - measured: a live-but-asleep
          # roomchief slept 101 minutes on piled family-spool wakes (its
          # hook-held scoped watcher died without a rewake) until the captain
          # poked it by hand. Two explicit channels, once per episode: a
          # durable coverage record on the FLEET spool so the chief that
          # drains it is told the family is down, and one line typed into the
          # roomchief pane - a keystroke starts a real turn on a
          # live-but-asleep chief, and a dead pane swallows it harmlessly.
          # Through queue_wake like every other wake: this branch used to call
          # the publish directly with `|| true`, so it carried not even the log
          # line the other sites had. The fleet spool it has always gone to is
          # where queue_wake sends it: AC_SCOPE is empty here by the refusal at
          # the top of this file, which makes the pairing a guard, not a habit.
          # It is the ONE queue_wake site with no reason line of its own - the
          # branch `continue`s into the pane pass - so the loss has no live
          # channel; the latch deferring to the record is the retry it gets,
          # exactly as check_remote's two episode latches do, and the flag is
          # cleared here because no emit_reason will do it.
          queue_wake coverage "$skip_fam-chief" \
            "scoped coverage down for $skip_fam - fleet watcher covering its panes; the roomchief must drain and re-arm (or be recovered)"
          if [ "$wake_published" = 1 ]; then touch "$state_dir/.skip-revoked-$skip_fam"; fi
          wake_published=1
          ( AC_BACKEND="$(ac_task_backend "$skip_fam-chief")"; export AC_BACKEND
            backend_send_line "$skip_fam-chief" \
              "wake: your scoped watcher for $skip_fam is down and wakes may be pending - run bin/ac-wake-drain.sh, act on each, then re-arm bin/ac-watch.sh as your own background task" \
          ) >/dev/null 2>&1 || true
        fi
      fi
    fi
    AC_BACKEND="$(ac_task_backend "$id")"
    export AC_BACKEND

    alive_rc=0
    backend_window_alive "$id" || alive_rc=$?
    if [ "$alive_rc" != 0 ] && [ "$alive_rc" != 1 ]; then
      # UNOBSERVABLE (contract: ac-backend.sh WINDOW LIVENESS): only a DEFINITE
      # `1` may become gone - everything else (2, or a driver-load failure like
      # bash's own 127 from ac_backend_route's per-call dispatch) is no evidence
      # about the pane, which is what made a herdr protocol mismatch read as two
      # dead agents. So: no failure state, no `gone` marker (a real death after
      # the outage is still news), one wake and one status line per outage
      # episode - the outage is fleet-wide and only a human clears it, but
      # re-waking every poll for every pane would bury the chief. KEEP POLLING:
      # recovery needs no re-arm, and the readable pass below clears the marker
      # so the NEXT outage wakes again.
      if [ ! -e "$state_dir/.unobservable-$id" ]; then
        touch "$state_dir/.unobservable-$id"
        ac_status_append "$id" "unobservable: backend could not be read for $(backend_target "$id") - NOT a death; the pane may well be alive (check the backend itself)"
        queue_wake unobservable "$id" "the backend could not be read - liveness unknown, no work assumed lost (check the backend: herdr status server)"
        emit_reason "unobservable:$id"
        return 0
      fi
      continue
    fi
    rm -f "$state_dir/.unobservable-$id"

    if [ "$alive_rc" = 1 ]; then
      if [ ! -e "$state_dir/.gone-$id" ]; then
        touch "$state_dir/.gone-$id"
        ac_status_append "$id" "failed: window gone"
        queue_wake gone "$id" "window $(backend_target "$id") vanished"
        emit_reason "gone:$id"
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
        ac_status_append "$id" "$WATCH_ASK_NOTE"
        queue_wake ask "$id" "agent blocked on an interactive prompt (answer or steer it)"
        emit_reason "ask:$id"
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
    # BUSY-STALL BOUND (contract: the header block of the same name). The run is
    # stamped on the 0->1 edge and cleared on the way back. DELIBERATELY not read
    # off .change-<id>: that clock is reset a few lines down by ANY tail change,
    # and a harness footer rendering an elapsed counter changes the tail every
    # poll, so a bound reading it could never accumulate.
    busy_file="$state_dir/.busy-$id"
    if [ "$busy" = 1 ]; then
      [ -e "$busy_file" ] || printf '%s\n' "$(ac_now)" >"$busy_file"
    else
      rm -f "$busy_file" "$state_dir/.busy-stalled-$id"
    fi
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
          emit_reason "report:$id"
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
          emit_reason "report:$id"
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
        emit_reason "report:$id"
        return 0
      fi
    fi

    # BUSY-STALL BOUND (contract: the header block of the same name): busy is
    # evidence of a process, never of progress. Checked BEFORE the marker
    # `continue` below, so a pane still showing an already-deduped marker is
    # bounded too - the arm exists to end silence, so it is placed where silence
    # cannot route around it.
    if [ "$busy" = 1 ] && [ "${AC_BUSY_MAX:-2700}" -gt 0 ] \
      && [ ! -e "$state_dir/.busy-stalled-$id" ] \
      && ! chief_busy_declared "$(busy_family_of "$id")"; then
      busy_age=$(( $(ac_now) - $(cat "$busy_file" 2>/dev/null || ac_now) ))
      if [ "$busy_age" -ge "${AC_BUSY_MAX:-2700}" ]; then
        touch "$state_dir/.busy-stalled-$id"
        ac_status_append "$id" "busy but stalled: ${busy_age}s inside one call with no turn end"
        queue_wake stale "$id" "busy for ${busy_age}s with no turn end - the pane may be hung inside a single call"
        emit_reason "stale:$id"
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
          ac_status_append "$id" "$WATCH_ENDED_NOTE"
          backend_mark_wait "$id" "ended its turn with no report line" 2>/dev/null || true
          queue_wake ended "$id" "ended its turn ${idle}s ago with no report line - read the pane, the ask may be prose"
          emit_reason "ended:$id"
          return 0
        else
          # STALE DEFERRAL (header): the worker already said why it is quiet,
          # or is parked at a gate on the captain - its word outranks the idle
          # clock, ONCE per declaration. The TIMER restarts (not merely the
          # dedup marker, which any redraw clears), so the same declaration a
          # full window later falls through to the stale: below.
          if dw="$(declared_wait "$id")" \
              && [ "${dw#*	}" != "$(cat "$state_dir/.deferred-$id" 2>/dev/null || true)" ]; then
            printf '%s\n' "${dw#*	}" >"$state_dir/.deferred-$id"
            printf '%s\n' "$(ac_now)" >"$changed_file"
            watch_log "deferred-stale:$id ${dw%%	*}"
            continue
          fi
          # SUPERVISING-CHIEF QUIET now guards this arm from one rung up, so
          # everything reaching here is a genuinely-unsupervised quiet pane:
          # today's soft stale:, unchanged.
          touch "$state_dir/.stale-$id"
          queue_wake stale "$id" "quiet for ${idle}s with no report line"
          emit_reason "stale:$id"
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
  # Brain freshness rides THIS process, the one component the Stop hook
  # machine-guarantees while crew flies (measured: a home whose chief lost
  # its session-only cron sat 7h stale while its watcher beat the whole time).
  ac_brain_freshen >/dev/null
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
