---
name: brainstorm
description: Captain-invocable ideation flow - the captain thinks a topic through with a DEDICATED brainstorm roomchief (clean context, its own room journal, chat right in the dashboard Board detail), not in the crewchief's own loaded session; the crewchief only opens it and, at the end, mints the rows the captain confirms - the roomchief is machine-barred from the ledger. No code, no crewmate, no ledger write while thinking. Use when the captain invokes /brainstorm <topic> (or --direct <topic> for a quick riff in the chief session), or opens a "should we / how might we" conversation that is not yet an order.
---

# brainstorm

The captain invoked `/brainstorm <topic>` - an IDEATION session, upstream of
every execution flow. Nothing here is an order yet: the deliverable is queued
backlog rows the captain has confirmed, or the explicit outcome "no rows".
Rows this flow mints are the INPUT a later `/order-direct`, `/order-staged`,
or `epic-intake` runs on - this skill never starts execution itself.

## The venue: a brainstorm ROOMCHIEF, not the crewchief's session

The crewchief session carries wakes, supervision, and intake - ideation is
long and token-heavy, and it both BURNS that context and gets anchored by
its operational noise. So the DEFAULT venue is a dedicated roomchief
(`ac-spawn.sh --roomchief`, existing machinery end to end), which brings
exactly what ideation wants:

- CLEAN context - grounding lives on disk (recall/scenes/learnings) and a
  fresh session pulls it as well as the crewchief holds it;
- its ROOM (`data/brainstorm-<slug>/room.md`) - the journal of threads
  settled and threads dropped, durable after the pane is gone;
- the captain chats with it from the dashboard Board detail (the chief
  panel mounts for any live roomchief) or in its pane;
- `bin/ac-ledger-guard.sh` machine-bars every scoped session from the
  fleet ledgers - "only the crewchief mints" is enforced, not asked.

The crewchief touches the flow twice: open it, and mint at close.
`--direct <topic>` keeps the quick-riff path - the captain ideates in the
crewchief session itself when a spawn costs more than it saves; the same
rules apply with the crewchief playing both parts.

## Open (crewchief): charter the room, promote it

The no-side-effect rule below binds CHIEF initiative; the captain invoking
`/brainstorm` IS the adoption of this one promote. Standard hot-room
promote, nothing new (mechanics: `bin/ac-spawn.sh` header):

1. `bin/ac-room.sh post brainstorm-<slug> crewchief "BRAINSTORM: <topic
   verbatim> - ideation only: converse with the captain and journal here;
   ground from disk first and cite; spawn NOTHING and write NOTHING
   outside this room - an idea needing real investigation becomes a draft
   row, not an action; end by posting DRAFT-ROWS entries (section-9
   grammar) for the crewchief to confirm and mint."` - the room IS the
   brief, so the charter is the contract.
2. `bin/ac-spawn.sh --roomchief brainstorm-<slug> --captain-initiated
   "/brainstorm <topic>"` (counts toward the room-parallel cap like any
   roomchief).
3. Tell the captain where it lives: Board -> brainstorm-<slug> -> chat, or
   the pane itself.

## The hard rule while thinking: no side effects

Whoever hosts the session (roomchief or crewchief), thinking spawns
NOTHING and writes NOTHING outside the room journal: no crewmate, no
brief, no worktree, no backlog row, no code or config change. Instruments
are conversation and READS. An idea that needs real investigation to
evaluate is itself a conclusion - "needs a scout to answer" becomes a
draft row the captain confirms like any other.

## Ground before proposing (the roomchief's first move)

- `bin/ac-know.sh recall '<the topic as a question>' --repo <clone>`;
  `records/scenes/` for prior context on the topic; `records/learnings.md`
  for lessons that bear on it. CITE hits - or state their absence.
- `bin/ac-ready.sh overlap` on the surface an idea would touch, so live or
  recent work on the same ground shapes the discussion now, not at intake.

A hit can end a thread ("this exists / was tried / is in flight") - the
cheapest outcome a brainstorm can produce; name it plainly.

## During: how to be useful

Explore WITH the captain, not for them: options with trade-offs, what each
would take, what it risks, a one-line lean when the choice is material.
Disagree with reasons when an idea fights something the fleet already
learned - cite the learning, not taste. Journal as you go: when a thread
settles or dies, one room entry says which and why - the room outlives the
session and IS the brainstorm's record.

## Ending: rows only on the captain's word, minted only by the crewchief

The roomchief cannot touch the ledger (ledger-guard) - it ends by posting
its `DRAFT-ROWS` entries to the room and telling the captain it is done;
the crewchief then:

1. Reads the draft rows: each in the section-9 grammar - id, a
   delivery-contract token group carrying ONLY the dimensions the captain
   actually settled in the conversation (`src:cap` always - the captain's
   confirmation is the order-source; a settled heavy dimension pinned here
   is pre-consent the escalation gate never re-asks; an UNSETTLED
   dimension stays off the row for intake to triage later), the one-line
   description, `(repo: <name>)`.
2. Reads every row back to the captain VERBATIM and waits for the yes -
   per row or batch, but real; a pin written without the captain's word is
   the exact drift the contract grammar exists to stop (section 9).
3. Appends the confirmed rows to `## Queued` in `records/backlog.md`,
   byte-identical to what was read back, then demotes/tears down the
   roomchief; the room stays as the durable journal.
4. Says what was minted and what was deliberately NOT (threads that ended
   "no", "later", or "needs a scout first") - the not-minted list is part
   of the outcome. In `--direct` mode the crewchief runs the same steps
   off its own conversation notes.

"No rows" is a fully valid ending. Grammar, gate, and triage law stay where
they live (sections 5, 8, 9) - this skill cites them and duplicates nothing.
