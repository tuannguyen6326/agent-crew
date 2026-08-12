---
name: debrief
description: Route and curate uncaptured session knowledge before a reset, then reconcile rooms and fleet state without discarding work. Use at the end of a work session, before a context reset, or when the captain invokes /debrief. Landing-time debriefs remain the primary task-level mechanism.
---

# debrief

Conversation memory is a cache and disk is the durable source of truth.
`/debrief` is the manual session-wide catch-all before a reset or handoff.
Landing remains the primary task-level debrief, so never defer landing-time backlog, room, learning, captain, or project updates to this skill.

## Sweep the session

Review the conversation, current records, rooms, and live fleet state for:

- task status changes, unfinished work, and newly discovered work;
- family decisions, unresolved captain choices, gates, handbacks, and narrative that exist only in chat or review artifacts;
- durable fleet or project lessons;
- captain preferences and standing decisions;
- project additions, mode changes, and retirements;
- project-intrinsic build, test, architecture, and convention knowledge;
- Agent Crew behavior that warrants a tracked repository change;
- finished, blocked, waiting, or otherwise in-flight crew state.

## Route and curate

Inspect each destination immediately before writing it.
Classify every candidate as duplicate, superseding, obsolete, or genuinely new.

- Leave duplicates unchanged.
- Rewrite a superseded ledger entry in place when that ledger permits revision.
- Prune or archive obsolete ledger entries only through that destination's existing convention.
- Append only genuinely new knowledge, one line and newest last where the ledger convention requires it.
- Treat rooms as append-only history, so post a correcting or superseding entry instead of rewriting prior room entries.

Route each candidate to exactly one durable owner:

- Task index, status, completion evidence, and undone work go to `records/backlog.md`.
- Family narrative, decisions, gates, and handbacks go through `bin/ac-room.sh post` to `data/<family>/room.md` for an UNPROMOTED family; a PROMOTED family with a live roomchief owns its own room, and `bin/ac-room.sh post` now REFUSES an unscoped write of its TRIAGE/GATE/ASK/SELF-APPROVED/LANDED/HANDBACK/R1-DISPOSITION/DECIDED receipts into it (AGENTS.md section 8) - route those to the roomchief instead of posting directly.
- Every unresolved captain choice becomes a `GATE:` or `ASK:` in its family room, and the backlog line records the blocked status or dependency when that choice blocks work.
- Durable fleet-local gotchas and lessons go to `records/learnings.md` through `bin/ac-learn.sh note`, never a hand-append: it places them under `## Pending`, the only section the next Learning transaction reads, while an append at end-of-file lands after `## Distilled`, where that transaction deletes it.
- Captain preferences and standing decisions go to `records/captain.md`.
- Project registration, delivery mode, and retirement changes go to `records/projects.md`.
- Record only project changes that were already authorized and completed, because `/debrief` never creates, removes, or changes a project's mode as cleanup.
- Project-intrinsic facts go to that project's `AGENTS.md` through normal crew delivery, never through a direct debrief edit.
- A verified codebase fact that does not warrant an `AGENTS.md` change goes to `records/repo-knowledge/<name>.md` via `ac-know.sh add --fact` - the one-line direct write any crewmate may make, so it need not die with the session or become a whole queued task.
- If a project fact cannot land in the current task, queue an explicit backlog item that names the fact and its target file.
- Generalizable Agent Crew behavior changes become a normal tracked Agent Crew task instead of policy hidden in a record.
- Skill candidates remain raw lessons only until the captain-approved DISTILL flow lands them.

Never create, edit, or promote a skill as debrief storage.
Never create a parallel session-notes file outside the existing records and room system.
Never write secrets into records, rooms, briefs, or resume pointers.

## Advance learning only when warranted

If this debrief materially adds or updates durable lesson knowledge in `records/learnings.md`, run `bin/ac-learn.sh tick` exactly once.
A duplicate-only, prune-only, backlog-only, captain-only, projects-only, or room-only debrief does not tick the learning counter.
`/debrief` never invokes `bin/ac-learn.sh run`, `bin/ac-learn.sh land`, or `bin/ac-learn.sh promote`.

## Reconcile fleet and rooms safely

Run `bin/ac-fleet-view.sh` and `bin/ac-room.sh list`, then inspect unclear tasks with `bin/ac-crew-state.sh <id>`.
Tear down only finished and landed crewmates through `bin/ac-teardown.sh <id>`.
Never use `bin/ac-teardown.sh --force` from `/debrief`.
Close eligible rooms through `bin/ac-room.sh close <family> <outcome>` and never delete a room.
Treat an idle persistent CrewDeputy or a durably tracked in-flight task as healthy state, not cleanup failure.
Report every remaining task, room, gate, or handback with its durable file or task identifier and the reason it remains.
Do not broaden approval authority or execute a destructive action because the session is ending.

## Return a reset verdict

Finish with these fixed sections:

- `Captured` - each file or room changed and the concise durable fact stored there.
- `Backlog and rooms` - items added, rewritten, queued, closed, or deliberately left open.
- `Fleet state` - tasks torn down and tasks, CrewDeputies, or panes left running with reasons.
- `Learning` - whether the counter ticked and why.
- `Verdict` - exactly `SAFE TO RESET` or `NOT SAFE TO RESET`.
- `Remaining` - every uncaptured or unverified item and its blocker, or `None`.
- `Resume pointer` - the exact records, rooms, task ids, and reports the next session should inspect first.

Return `SAFE TO RESET` only when every durable finding and unresolved captain choice is on disk, every cleanup claim is verified, and no next action exists solely in chat or a review artifact.
A durably tracked in-flight task is compatible with `SAFE TO RESET` when its state and resume pointer are sufficient to continue it.
Return `NOT SAFE TO RESET` when a required write failed, work remains untracked, fleet state is unknown, or the next session would need this conversation to reconstruct an action.
