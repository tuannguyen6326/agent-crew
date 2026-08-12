---
name: stuck-crewmate-recovery
description: Crewchief evidence-ladder for recovering a stalled, looping, confused, or exited crewmate using the existing wake, peek, state, send, resume, room, and backlog primitives. Load after a stale wake, a failed steer, an apparently swallowed instruction, an unresponsive pane, a harness exit, or evidence of a loop. Never force-teardown and never discard dirty or unlanded work as recovery. A healthy idle CrewDeputy, declared pause, captain gate, or blocked interactive prompt is not stuck.
---

# stuck-crewmate-recovery

Recover a crewmate that has stopped making progress WITHOUT destroying its work.
Recovery climbs from evidence to a steer to a verified harness action - never a force-teardown, never a discarded worktree.
Command syntax, fail-closed refusals, and state transitions stay in the `bin/ac-*.sh` script headers; this skill owns only the ladder and its stop conditions.

## When to load - and what is NOT stuck

Load after a stale wake, a failed steer, repeated confusion, an apparently swallowed instruction, an unresponsive pane, a harness exit, or evidence that a direct report is looping.

Do NOT classify these as stuck - they are healthy states:

- a healthy idle CrewDeputy (a persistent supervisor waiting for work);
- a declared pause (the crewmate stamped `paused:` itself);
- a captain gate (the task is waiting on a decision you owe the captain);
- a blocked interactive prompt (a real dialog - answer it deliberately, do not "recover" it);
- a completed-but-awaiting-landing task (the work is done and waiting to merge).

## The evidence ladder - escalate in order

Every rung must verify the previous action landed before advancing. Never skip to a harder action on a hunch.

1. Drain the relevant wakes with `bin/ac-wake-drain.sh` and inspect the task's meta, status, room, and live state.
2. Read the bounded transcript with `bin/ac-peek.sh <id>`; when the state is unclear, add `bin/ac-crew-state.sh <id>` for the deterministic one-line state, and `bin/ac-follow.sh <id>` for the full read-only transcript.
3. Classify the condition: healthy work, declared wait, captain wait, delivery strand, stale agent, exited agent, or confirmed loop. Only the last three warrant an intervention.
4. Send ONE concise corrective steer with `bin/ac-send.sh <id> '<text>'` when the pane can safely receive text.
5. Use the target's verified harness operation (interrupt, resume) only when a steer cannot recover it - read `harness-operations` for the harness named in the task meta before sending any keystroke.
6. Relaunch or resume while preserving the branch, worktree, reports, and recorded session where the harness supports it: `bin/ac-spawn.sh <new-id> <project> --resume-from <old-id>` reopens the recorded claude session in a fresh worktree with its context intact.
7. Mark failure only after repeated recovery evidence shows no safe continuation path.

## Invariants - never trade work for a clean pane

- Every escalation verifies its predecessor landed; a send that never acknowledged its submit did not land.
- Never retype the same instruction blindly after a submit ambiguity - the text may already sit in the composer; resubmit it with `bin/ac-send.sh <id> --key Enter`, which re-submits rather than re-typing (retyping appends and garbles the line). That resubmit is focused but UNVERIFIED (it says `delivered (unverified)`), so peek to confirm it landed before escalating.
- Never send ordinary text into a pane blocked on an interactive dialog - its trailing Enter accepts whatever option is highlighted; answer with `--key` instead.
- Never use `bin/ac-teardown.sh --force` as recovery. `--force` is the captain explicitly discarding work, never your tool for a fresh pane.
- Never destroy a dirty or unlanded worktree to obtain a clean pane.

## Durable outcome

- Successful recovery leaves the task attached to its existing durable identity whenever possible (same id, branch, room, backlog line).
- When a replacement task identity is unavoidable, its new brief, room, backlog line, and resume relationship must point back to the original work.
- A failed recovery records the evidence, the remaining work, and the next safe action in the family room and backlog BEFORE the pane is abandoned.
- Preserve roomchief routing: a promoted family's project work belongs to its roomchief - the fleet crewchief must not silently take it over while recovering it. Route the recovery to the roomchief the same way any other work for that family is routed.
- Persistent CrewDeputy recovery is out of scope here - this ladder covers ordinary crewmate recovery only; a stuck or gone CrewDeputy home has its own explicit, guarded recovery path (`bin/ac-spawn.sh <id> --crewdeputy --recover`). Use that path; never reimplement it inline.
