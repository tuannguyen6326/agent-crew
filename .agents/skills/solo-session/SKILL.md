---
name: solo-session
description: The two sanctioned ways a chief-side or captain-driven session writes code itself: the small self-task (ac-self-task.sh), the SOLO CHIEF (a roomchief promoted --solo), and the SOLO SESSION (AC_SOLO=1) with its prohibitions, subagent rules, landing path, knowledge-loop teardown gate, and end-of-session states. Load at the start of any AC_SOLO=1 session, before any ac-self-task.sh start, and before promoting or running a --solo roomchief.
---

# solo-session

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## What the tools enforce

Under `AC_SOLO=1`, `bin/ac-wake-drain.sh` (drain and ack), `bin/ac-watch.sh`, `bin/ac-spawn.sh` and `bin/ac-send.sh` refuse, and the two Stop hooks stand down.
Answering gates and the ledger-write limits are NOT refused by any tool - those prohibitions hold only by this session's own discipline.

## Self-task, solo chief and solo session

A SMALL chief-side edit - the sanctioned no-invisible-tasks exception
(small tasks may be chief-self but stay backend-visible) -
goes through `bin/ac-self-task.sh start <id> <project>`, never by hand.
It leases a worktree per the fleet's backend, seeds the crewmate layer into it
(instructions, settings, skills - work on a worktree follows the crewmate
rules, whoever holds the hands), opens a labelled pane tailing the
task's progress log, and writes a `kind=self` meta BEFORE the first edit, so the
task is visible on the backend and in every fleet view like any other; the chief appends
its progress with `bin/ac-self-task.sh log <id> '<line>'` and lands on the
EXISTING path (`bin/ac-merge-local.sh` then `bin/ac-teardown.sh`).
It is VISIBILITY only - no brief, no harness, no room, no gate, no stage, no
promote tier - and it is not a loophole around the prime directive: real
project work still goes to a crewmate.
That script's header is the authoritative spec.
The ONE exception with a room behind it is the SOLO CHIEF (captain ruling
2026-09-16): a family the crewchief judges too small to cost a crewmate is
promoted with `bin/ac-spawn.sh --roomchief <family> --solo`, receipted
`TRIAGE: ... promote=solo-chief - why`, and its roomchief works each slice
ITSELF through `bin/ac-self-task.sh start <family>-<slug> <project>` - a
worker's hands under every other roomchief duty (room, receipts, gates,
handback, the `room-parallel` cap). The captain pins it with the order's
own words ("solo chief" / "no crewmate"); absent those, it is the
crewchief's triage like `promote`. Three things do not bend: independent
review is MANDATORY on every solo-chief slice (`rev:yes`, the `crew-verify`
skill), because nobody else reads the code; the ledger fence stays, so at
its slice's landing the chief posts `LANDED: <slice-id> - <outcome>` to the
room and the teardown gate reads that receipt where a Done row would be
(the crewchief moves the row at handback, as ever) - and a slice that
CANNOT land posts `UNLANDABLE: <slice-id> - <why>` instead, its own
non-pending verb (never `HANDBACK:`, which is the family's tenure-ending
receipt and would flip the whole family): main moving under a slice
withholds `--no-ff` from every scoped session BY DESIGN, so the slice stays
in flight, the crewchief lands `crew/<slice-id>` `--no-ff`, and only then
does the teardown pass, reading `UNLANDABLE` where `LANDED` would be - a
rebase to force the land is not an exit (it changes the sha a review
receipt binds by); and the delegation
fence stays - a solo chief edits with its own hands or spawns a crewmate,
never a harness subagent. `bin/ac-spawn.sh`'s header owns the flag.

A SOLO SESSION (env `AC_SOLO=1`, opened with `ac <fleet> --solo`) is the
OTHER sanctioned way a human-driven session writes code in a fleet: a second
session beside the chief, for the captain pair-coding directly, one slice at
a time.
It is not the chief and never substitutes for one - the prohibitions are the
point: no spawning crew or roomchiefs, no steering panes, no draining wakes
(a drain CONSUMES the chief's records), no arming or releasing watchers, no
answering gates, and no ledger writes beyond the two named below.
When the captain wants CREW on something from the solo chat, the solo
session hands the order to the chief instead of spawning: `bin/ac-remote.sh
order --text-file <draft>` (or `order '<text>'`) stashes the captain's words
as a local order and queues the chief's durable `remote-order <rid>` wake -
the chief drains it and runs the remote-orders protocol unchanged (intake,
triage, spawn, supervision, landing), and its replies land beside the stash
at `state/remote-inbox/<rid>.replies.md` for the solo session to read. The
solo session may draft the brief text the order carries; it never briefs,
spawns or supervises the crewmate itself, because a crewmate lives on the
chief's watcher, drain and gates, and a solo session stands all of those
down by design.
Harness-native subagents stay AVAILABLE to it: a solo session is
worker-shaped, keeping its own subagents exactly as a crewmate's worktree
does - the slice stays its responsibility, its self-task meta keeps the work
visible, and the captain is watching live (the delegation guard's solo
carve-out is this rule's enforcement shape).
Those subagents serve the SLICE, never replace it: read-only subagents fan
out freely, but a subagent that EDITS the leased worktree is pointed, in its
prompt, at the seeded crewmate instruction file inside that worktree before
it edits - the seeded crewmate layer reaches a subagent only through the
prompt, since instruction files and hooks load by the SESSION, never by the
tree being touched - writes go one subagent at a time per worktree, and the
solo session reads the full diff and runs the tests itself before
committing; work big enough to hand a subagent whole belongs on the fleet
backlog instead.
Its one write path per slice is `bin/ac-self-task.sh start <id> <project>
[--mode <m>] [--harness <h>]` - the SMALL cap above does not bind a solo
session, which takes real slices - and the slice lands through the ordinary
delivery machinery for the mode the start recorded (default local-only; a PR
slice passes its PR mode so the fleet views say what actually lands), PR
included, with the captain's approval given right in the chat.
Session-start runs read-only under `AC_SOLO` (no lock, no drain, banner
naming what it skipped), and the two Stop hooks stand down - a solo session
owes no supervision.
The knowledge loop still binds in both directions: intake reads
`records/captain.md` (the fleet's standing rules bind a solo session too),
`ac-know.sh recall` and `ac-brain.sh recall` - the brain read is also
MACHINE-made on every prompt: `bin/ac-prompt-recall.sh` (the harness's
prompt-submit hook, fired for a solo session and a chief at the fleet home,
silent in a crewmate worktree) hands the model the top hits with trust
labels and the brain's freshness before it reads the prompt, and fires the
catch-up sync when the brain is stale, since a solo session never syncs
otherwise; a hit is a pointer to open, never a fact to cite unread; landing
writes lessons with
`ac-learn.sh note`, verified repo facts with `ac-know.sh add`, ticks the
Learning cadence, and appends the row to `## Done` - the one backlog write a
solo session may make, because no chief knows its work to record it.
The CREWMATE layer binds its WORK too, and the leased worktree already
carries it: `ac-self-task.sh start` seeds the merged layer exactly as a crew
spawn does (`--harness` routes it to the instruction file that harness
loads - `.claude/CLAUDE.md` by default, `AGENTS.md` for an AGENTS.md-reading
harness - since a solo session is not only claude), so each slice begins by
reading the seeded crewmate instruction file inside that worktree - the FULL
merge, container baseline, fleet-learned, fleet and any domain layer, the
same file a crewmate on that tree loads - and discovers the seeded skills
there too.
The seed reaches the TREE, never the session (a solo session boots at the
fleet home, and instruction files load by the booting cwd), so that read is
the solo session's own act, once per slice - only the crewmate MECHANICS
(brief-following, `ac-done.sh`, pane markers, the handback report format) do
not apply, since a solo session has none of that machinery.
The report format's `## Lessons` section is part of what does not apply: a
solo session never prints a Lessons section in chat - chat dies with the
session, so a lesson printed there is lost, and the section reads as done
while nothing was recorded. A lesson has exactly two fates: a genuinely new
method lesson goes to `ac-learn.sh note` (the next Learning transaction
reads every Pending line, so a routine one is a cost, not a gift), a
verified repo fact goes to `ac-know.sh add`; anything else ends with the
answer.
Neither write waits for a slice: a repo fact verified while answering in
chat goes to `ac-know.sh add` right then, family `solo-chat`, since the
chat that verified it dies with the session. At a slice's landing the
machine GATES it: teardown of a `kind=self` task prints and records one
`knowledge loop:` line naming which of lesson, repo fact and `## Done` row
exist for that slice (Pending heading `(solo <id>)`, knowledge line
`by: <id>`, Done row `- [x] <id>`) with the exact command for each that is
missing, and REFUSES while any is - the slice stays in flight for the
writes to happen. It still cannot tell "learned nothing" from "did not
write it down", so nothing-new is SAID, never inferred: `--no-lesson
'<why>'` / `--no-fact '<why>'` waive those two on the record (the crewmate
report's `none` under `## Lessons`, same contract), and the Done row is
never waived. Once the loop is complete the teardown runs the keyed
`ac-learn.sh tick <id>` itself - no chief lands a solo slice, so no chief
would (`bin/ac-teardown.sh`'s header owns the gate).
A solo session ENDS when the captain closes it - no ritual, no lock to
release, nothing owed at that moment, because everything durable was
written when it happened. A slice does not end with the session: its pane
is a tail that dies, its meta, lease and branch live on, and the fleet
view reads it `detached` (never `gone`, the word for a dead crewmate).
Before closing, a slice is in one of three states on purpose: landed
(`bin/ac-teardown.sh <id>`), left in flight for the next session (which is
told at start, with its age and both ways out, since the lease holds a
pool slot until then), or discarded (`--force`). The turn-end guard's solo
arm has one concern of its own: uncommitted changes in a slice's worktree
get a captain-facing notice, never a block - the captain is pair-coding
live and decides when to commit.
A slice whose deliverable is KNOWLEDGE (an investigation, a diagnosis, a
comparison) leaves `data/<id>/report.md` exactly as a scout would - chat
dies with the session; a code slice's record is its PR and commits, no
report owed.
