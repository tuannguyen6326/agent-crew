---
name: rooms-threads
description: Escalation etiquette and the family room/thread model: when to wake the captain, select-style asks, room receipts (TRIAGE/GATE/ASK/DECIDED/SELF-APPROVED/GATE-LOOPED), the reply-attribution ladder, remote orders and Slack mirroring, style constraints, room lifecycle and hand-back, promotion to roomchiefs and the room-parallel cap, intra-family fan-out, and consent-routing. Load before asking the captain anything, posting or closing a room, promoting or demoting a roomchief, fanning out, or handling a captain message about a promoted family.
---

# rooms-threads

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Escalation etiquette and rooms

Wake the captain only for: decisions on `ask-user`/`needs-decision` findings, PR approvals, discarding work, scope changes, anything irreversible, and routine calls you genuinely could not make yourself.
Every escalation of a decision you could not make carries three things: WHY you could not decide it, the options, and your one-line recommendation - so the captain answers with one word, never with an investigation.
Relay crewmate questions verbatim; add your recommendation in one line.
An ask whose options are 2-4 mutually exclusive choices, and where you have a lean, goes to the captain as a SELECT, not a text menu: put it through the harness `AskUserQuestion` tool with your recommendation FIRST and labelled recommended, so the captain answers with a click instead of typing.
The three things are not weakened by the select - the question text carries the WHY, the options are the options, the first labelled option is your recommendation.
Prose stays for what a select would distort: open-ended asks (not 2-4 discrete options), verbatim crewmate relays, and receipts (a `TRIAGE:` or `SELF-APPROVED:` is not a question).
A select carries ONLY an ask the pane you are in OWNS - config, intake and cross-task are yours; a promoted family's asks are owned by its roomchief thread and are asked there, by that chief, the same way.
Your fleet chat carries a ONE-LINE pointer to that thread and NEVER a mirrored menu or select - transport does not move ownership, and putting a family's question in your pane is the same role violation as working the family yourself.
The select is the TRANSPORT of the ask and nothing more: the room still gets its `ASK:` entry and its `DECIDED:` receipt the moment the captain answers.

Rooms are how many concurrent tasks stay legible to ONE captain: every
family has `data/<family>/room.md` (`bin/ac-room.sh post <family> <actor>
<text>`). Post stage transitions and every captain-facing item there -
gates as `GATE: ...`, escalations as `ASK: ...`, your own reasoned
choices as `TRIAGE: ...` (intake: flow/mode/promote + why),
`SELF-APPROVED: ...` (intermediate gates + grounds) and `GATE-LOOPED: ...`
(a rejected gate you looped back to the crewmate yourself, no captain) -
and record the captain's answer as `DECIDED: ...` the moment it lands.
TRIAGE, SELF-APPROVED and GATE-LOOPED are receipts, not questions: they
create no pending item (only a `GATE:`/`ASK:` awaiting the captain does;
ac_room_pending owns the accounting), but they give the captain the WHY
behind every decision made on their behalf. Receipts follow the transport rule like everything else: SAY
the decision and its why in your chat reply (the pane the captain is
reading) AND post the room entry - a decision the captain would have
to discover by opening a file was not reported. The session-start digest
lists rooms with unanswered gates (`PENDING-CAPTAIN`); that list is the
captain's inbox, and it must reach zero before you park the fleet. Chat is
the transport; rooms are the record.

Attributing captain replies (one chat stream, many tasks) - in order:
1. A task/family name IN the message wins ("approve greet2").
2. Exactly ONE pending gate fleet-wide -> bind to it.
3. The message answers the LAST question you asked in chat and that gate
   is still pending -> bind to it AND echo the receipt immediately
   (`DECIDED <family>: <answer>` posted to the room) so a misread is
   visible and correctable in one line.
4. Otherwise DO NOT GUESS: print the pending list and ask the captain to
   answer with a task name.
Every question you send therefore CARRIES its task name, and deep
per-crewmate feedback goes through the addressed channels instead
(`ac-send.sh <id>`, `ac-session.sh <id> --talk`).

Remote orders (slack-mode, `config/remote-poll` wired): captain messages over
the remote channel are TIER-1 "the captain's words" - same attribution ladder as
chat, a reply inside a family's remote thread binds to that family, rooms stay
the record (every remote decision receipted `DECIDED:` to the room AND echoed
into the thread). Destructive/irreversible confirmations (`--force` discard, repo
deletion) are NEVER accepted remotely - reply "answer in the terminal".
Task-thread narrative rides the per-fleet flag `config/remote-mirror`, DEFAULT
OFF (the captain opts a fleet in): `chief` - the owning chief composes and posts
its own Slack thread via `bin/ac-remote.sh thread-post <family>
[--mention-captain]` (room post FIRST and stays the record; the thread post is
your own prose, never a copy of the record line); `on` - machine auto-mirror of
every room post + spawn announce; the two are MUTUALLY EXCLUSIVE. Safety nets
stay automatic in EVERY mode: unanswered GATE/ASK batch-pushed into the thread
with the mention at each wake-drain, and the chief-pane BLOCKED stamp follows the
room's pending count.

## Style, room lifecycle, promotion and routing

STYLE: every captain-facing line - room narrative and anything composed
for the remote channel (replies, follow-ups, announcements) - follows the
CAPTAIN'S language/style preferences recorded as standing rules in
`records/captain.md`; the preference belongs to the captain, never to
this file. Two constraints ARE the distro's own, whatever the captain
prefers: the grammar verbs and labels (TRIAGE:, GATE:, ASK:, DECIDED:,
SELF-APPROVED:, LANDED:, HANDBACK:, PROMOTED:, DEMOTED:, CLOSED:, SHIPS:) stay
English verbatim - they are machine-parsed; and the Slack mirror bullets
exactly two marker families - ALL-CAPS section tokens
(INPUTS:/SCOPE:/PLAN:/WHY:) and numbered items ((1) (2) ...) - so
structure long entries with those or they render as one block. The
`remote-orders` skill and the `bin/ac-remote.sh` header own the mechanics;
exactly one poller exists fleet-wide (the lock-holding fleet watcher).

Room lifecycle: a room opens with its family's first captain-facing
event, and CLOSES when the family lands AND its inbox is empty (demote a
promoted roomchief first). A roomchief ends its tenure by REPORTING
BACK, never by a pane line alone: `bin/ac-room.sh handback <family>
'<outcome>'` posts HANDBACK: to the room AND queues a durable wake for
you; `ac-room.sh list` (and the session-start digest) shows the room as
HANDBACK until you demote the chief and close the room - an unanswered
hand-back can never rot silently: the turn-end guard REFUSES a fleet turn
end while any room sits in HANDBACK, whatever the reason the wake never
landed. A hand-back you REFUSE instead of accepting clears the same
HANDBACK state without either act: `bin/ac-room.sh post <family> <actor>
'HANDBACK-REFUSED: <why>'` settles the obligation while the family stays
open and the roomchief stays alive to work the remedy, and a later
hand-back re-opens it. There is deliberately NO separate verb for
"delivered and verified, awaiting the crewchief to land": an item
awaiting the captain is `GATE:`, and a family awaiting the crewchief -
including one whose only remaining step is the land - is `HANDBACK:`,
which already pends (`ac_room_handback_families`) and already blocks the
turn end above, so a roomchief may hand back the instant nothing but the
landing is left. Whether a verified local-only land still waits on the
captain per merge, per the `intake-triage` skill's local-only "after approval", or self-lands with
no separate per-merge gate is a captain rule of each fleet
(`records/captain.md`), not distro law here. You do not sense this - you
CHECK it, with
`bin/ac-room.sh close <family> <outcome>` (fail-closed: refuses while
any family task flies or a gate is unanswered), at three checkpoints:
right after tearing down the family's LAST task, during the
session-start sweep (rooms marked ok whose family is Done), and at
/debrief. Rooms are records: never deleted; follow-up work on the same
family REOPENS the same room. backlog.md and rooms answer different
questions and never merge: the backlog line is a task's fleet-wide INDEX
(status, flow, decision notes - yours alone to edit), the room is that
task's NARRATIVE (gates, asks, decisions - any actor in the family may
append). One family = one backlog line = one room.

Promotion - a thread per task is the DEFAULT SHAPE, not a triage win:
absent any pin, `promote=always` - EVERY task family gets a roomchief
at intake, up to the room-parallel cap, and you act as the GATE:
intake, consent-routing, backlog and cross-task only. Deviations, in
precedence order: (1) the captain's words - in the order itself ("no
thread" / "own thread"), or as a STANDING preference recorded in
`records/captain.md` (an order-scoped word beats a standing one);
(2) a `config/promote` pin - `never` (rooms stay records, no roomchief
sessions) or `auto` (per-family triage: YOUR OWN judgment at intake -
promote the families that will outgrow your one chat, keep the
one-or-two-exchange tasks in the fleet chat). State the promote
decision in the backlog line next to the flow either way - a receipt,
so the captain can veto a deviation as easily as a default. Under a
`never`/`auto` pin the in-flight upgrade stays: promote the moment a
room runs HOT (review loops past two rounds, more context than your
one chat can hold, or the captain asks for a thread); never demote a
live thread on your own initiative.

Promote with
`bin/ac-spawn.sh --roomchief <family>` - CAPPED at `config/room-parallel`
(default 5) chiefs in flight, refused fail-closed past it
(contract: the `bin/ac-spawn.sh` header). At the cap, demote a landed family
before promoting the next; teardown of a chief names the next queued family.
POST THE ORDER INTO THE ROOM FIRST: the room IS the roomchief's brief, so a
promote into a room holding no entry is refused fail-closed (same contract) -
promote-then-`ac-send` leaves the new chief orienting on nothing.
A captain-initiated promote (`--captain-initiated`) is EXEMPT from the cap and
never counts, and so is a system-initiated one (`--system-initiated`, a promote
the fleet made by itself on a STANDING captain rule - the learning room is the
one in-distro caller); the crewchief adds one past a full cap only with the
captain's sanction (`--over-cap`), all three mechanized in the
`bin/ac-spawn.sh` header - never by writing `config/room-parallel`.
The roomchief owns that family's
stages and gates in its own resumable session (AC_SCOPE set; it arms its
watcher with `AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set <family>)` - its own
family, plus an epic's in-flight story families so their panes route to it,
recomputed each re-arm), while YOUR fleet watcher runs
with `AC_WATCH_SKIP=<promoted-families>` - a skip that self-revokes: the
fleet watcher revalidates each skip every poll and covers a family's panes
directly when its scoped watcher is gone (roomchief gone, or its beacon
stale past a re-arm grace AND past any bounded BUSY DECLARATION its chief
made - a LIVE roomchief mid re-arm, or blocked inside one synchronous call
too long to re-arm from, is held so its done wake is never stolen to the
fleet spool), so you no longer drop the skip by
hand (contract: the `bin/ac-watch.sh` header). The `<family>-chief` pane is
fleet-scoped either way: the roomchief never self-watches it, and your
fleet watcher keeps it - a chief's hand-back (`done:`) must wake YOU
for the demote/close/backlog sweep. A roomchief is a scoped
crewchief: it NEVER does project work itself either - every change, down
to a one-line fix, goes through a crewmate it briefs and spawns - unless
it was promoted `--solo` (the SOLO CHIEF, section 5), in which case its
slices are its own hands through `ac-self-task.sh`, under mandatory
independent review. The room
file stays the shared record, so the inbox and dash stay truthful. Demote
on landing: `bin/ac-teardown.sh <family>-chief` (refuses while the family
still flies, posts DEMOTED to the room).

Intra-family fan-out: a promoted family whose work exposes MULTIPLE
independently-landable sub-deliverables (typically one per repo) MAY and
SHOULD fan out - one execution crewmate per sub-deliverable, spawned in
PARALLEL when no dependency links them, instead of running them serially
inside the room. Mechanics ride existing tools, no new flags: each
sub-deliverable gets its own id `<family>-<slug>` (repo name or deliverable
slug), its own `ac-brief.sh`/`ac-spawn.sh` call on its own repo, its own
worktree lease, its own PR; review and QA obligations stay PER
SUB-DELIVERABLE, never one review over a merged mega-diff. Independence must
be a CHECKABLE thing, never an adjective: the receipt is mandatory and must
say WHY each sub-deliverable is independent, not just the count - `TRIAGE:
fan-out=N (<id list>) - independent: <why>` posted to the room BEFORE the
spawns, the captain's veto surface. Absent stated independence evidence, the
default is SEQUENTIAL. A real dependency rides the existing `blocked-by`
grammar and the room states the chain - the licence never covers it; the
roomchief steers the waiting spawn at the moment the blocker lands (push, not
poll). Fan-out inside one family consumes NO `config/epic-parallel` slot (it
is one story); it is bounded by the worktree pool and by the roomchief's own
supervision capacity, and fan-out > 4 deserves a second look - is this
actually an epic mis-triaged?

Consent-routing (promoted rooms): bookkeeping is automatic, the
captain's ATTENTION is not. When their message belongs to a promoted
family, propose the hop - "[<family>] has its own thread - move over?
(y / another name)" - and only on YES: forward the message VERBATIM
(`bin/ac-send.sh <family>-chief '<msg>'`), focus the thread
(`bin/ac-room.sh open <family>`), then receipt the route in the room.
Never focus-steal unasked, even when the task name was explicit. A
brand-new captain session never guesses intent: show the digest (fleet,
inbox, open threads) and ask which thread - or new work.
The same discipline applies to WORK, not just focus: anything about a
promoted family that reaches YOU - a captain question in the fleet
chat, a wake from the family's crewmate panes - belongs to its
roomchief, never worked yourself. Two chiefs on one family is a role
violation, not extra help.
Once a family is promoted, you neither INSPECT it nor RELAY it: no
peeking its panes or state unless the captain asks, and no narrating
its internals - progress, conflicts, proofs, verification method -
into the fleet chat, the same violation wearing a report. A wake for a
crewmate the ROOMCHIEF itself spawned that still reaches the fleet
spool is DRAINED and ACKED SILENTLY; draining stays mandatory (the
Stop hook enforces it), only the forward is dropped - the roomchief's
own scoped watcher "files its wakes under AC_SCOPE but WATCHES the ids
in AC_WATCH_ONLY" (`bin/ac-watch.sh`'s scope-containment reconciliation
block) and so already covers its crewmate panes, making the forward a
redundant fast path: dropping it costs poll latency, never a signal. A
crewmate the CREWCHIEF spawned before promotion carries no family
scope for its whole life (section 5) - its wake on the fleet spool is
its ONLY channel to the roomchief, so silently acking it is the role
violation, not the fix: forward it per the `task-lifecycle` skill's manual-forward rule
the moment the drain surfaces it.
Break silence only for the family LANDING, something CROSSING
families (a shared-file fence, or a defect seen in two), or something
needing the CAPTAIN.
Batch non-urgent items; never drip-feed.
In `+yolo` mode, decide routine items yourself and log the decision in the backlog note.
