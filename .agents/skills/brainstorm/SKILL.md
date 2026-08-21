---
name: brainstorm
description: Captain-invocable ideation flow - the captain thinks a topic through with a DEDICATED brainstorm roomchief (clean context, its own room journal, chat right in the dashboard Board detail), not in the crewchief's own loaded session; the crewchief only opens it and, at the end, mints what the captain confirms - backlog rows, the requirements.md the session authored, and optionally a SPEC on top of it (the captain's live acceptance is the gate). The roomchief is machine-barred from the ledger. No code, no crewmate, no ledger write while thinking. Use when the captain invokes /brainstorm <topic> (or --direct <topic> for a quick riff in the chief session), or opens a "should we / how might we" conversation that is not yet an order.
---

# brainstorm

The captain invoked `/brainstorm <topic>` - an IDEATION session, upstream of
every execution flow. Nothing here is an order yet: the deliverable is queued
backlog rows the captain has confirmed - each order-shaped one linking the
`data/<family>/requirements.md` the session authored with the captain, plus,
when a thread went deep enough, a SPEC on top of it (below) - or the
explicit outcome "no rows". What this flow mints is the INPUT a later
`/order-direct`, `/order-staged`, or `epic-intake` runs on - this skill
never starts execution itself.

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
   grammar) and the DRAFT-REQUIREMENTS behind them - written into this
   room's own dir - for the crewchief to
   confirm and mint."` - the room IS the
   brief, so the charter is the contract.
2. `bin/ac-spawn.sh --roomchief brainstorm-<slug> --captain-initiated
   "/brainstorm <topic>" [--harness <h> --model <m> --effort <e>]`
   (counts toward the room-parallel cap like any roomchief).
   Profile, in order: (a) the captain named a harness in the invocation -
   pass it; (b) the fleet's `panes.roomchief` is ROUTED and a rule's
   `when` matches this brainstorm promote - you are the agent in the loop
   the routed-pane contract expects, so judge `bin/ac-dispatch-select.sh
   --pane roomchief --list`, resolve the match with `--rule <n>`, and
   pass its full profile as spawn flags (a fleet may pin brainstorms to a
   different harness this way - the rule is the captain's durable word);
   (c) neither - pass nothing and the promote resolves the ladder itself
   (routed default, else `config/crew-harness`; `bin/ac-spawn.sh` header
   owns the contract).
3. Tell the captain where it lives: Board -> brainstorm-<slug> -> chat, or
   the pane itself.

## The hard rule while thinking: no side effects

Whoever hosts the session (roomchief or crewchief), thinking spawns
NOTHING and writes NOTHING outside the room journal: no crewmate, no
brief, no worktree, no backlog row, no code or config change. Instruments
are conversation and READS. An idea that needs real investigation to
evaluate is itself a conclusion - "needs a scout to answer" becomes a
draft row the captain confirms like any other.

The room DIR is the one place a write lands: `room.md` plus the DRAFTS the
section below defines. That is the session's own output surface, owned by
nothing downstream - a draft there binds no family, enters no gate, and stays
journal until the crewchief copies it out on the captain's word. Everything
the ban names above stays banned.

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

Scale the cadence to the decision:

- For architectural or captain-required topics, ask one decision question at a time.
  For that decision, present 2-3 viable approaches with trade-offs and a recommendation.
  Journal the captain's answer before advancing to the next unresolved decision.
- Validate design sections incrementally before materializing a spec when the
  thread is becoming one. Preserve the final verbatim confirmation at minting,
  but do not make a monolithic draft the captain's first review.
- Quick riffs, routine topics, and already-settled decisions stay lightweight.
  Do not manufacture questions or checkpoints: there are no universal approval rounds.

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
   description, the `inputs:` clause naming what this brainstorm minted
   for it (section 9), `(repo: <name>)`.
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

## The artifacts: requirements.md for the order-shaped threads, a spec when one earned it

A brainstorm IS the product-owner interview - the captain settling in their
own words what the work must satisfy - so a thread that ends in an
ORDER-SHAPED row (something to build, with requirements the conversation
settled) also ends in `data/<family>/requirements.md`: the same PO artifact
section 5's PO STEP names, authored HERE instead of re-asked at intake. A
scout row ("needs a scout to answer") settles no requirements and gets no
file - the question it carries IS its brief. A thread that went
further still - boundaries drawn, acceptance criteria named - ends as a SPEC
on top of it. The staged flow's gates exist to bring the captain INTO design
decisions; in a brainstorm the captain is already in the loop, so what is
accepted here live outranks a stage report waiting for its gate. The shape:

1. The roomchief WRITES both drafts into its OWN room dir -
   `data/brainstorm-<slug>/requirements.md`, and `spec.md` beside it when the
   thread earned one - and posts a `DRAFT-REQUIREMENTS` entry (and
   `DRAFT-SPEC`) naming each path, so the journal stays the index of what
   exists. It writes them where they bind nothing rather than handing the
   crewchief prose to re-type: a long artifact reproduced by a second reader
   drifts, and the captain accepted the bytes, not the gist.
   Every requirements line carries its CITE
   (the captain's words verbatim, an answer already recorded `DECIDED:`, a
   standing rule), exactly as section 5 demands of the PO artifact.
2. At minting, the crewchief reads each draft back for the captain's yes
   like any row - then, and only then, MATERIALIZES it as
   `data/<family>/requirements.md`, and `data/<family>/spec/report.md` when
   a spec was accepted too, by COPYING the accepted draft out of the room dir
   and prepending a provenance header naming the brainstorm room and the
   acceptance date ("authored in brainstorm-<slug> with the captain; captain
   accepted <date>"). A copy, never a re-typing - the bytes the captain
   accepted are the bytes that land, and the draft stays in the room as the
   durable original. The captain's yes journaled in the brainstorm room is
   the gate receipt - each file enters no gate-route.
3. The row LINKS what was minted: `inputs: data/<family>/requirements.md`,
   plus `, data/<family>/spec/report.md` when there is one (section 9 owns
   the clause). The link is the point - the family's first brief lifts those
   paths into its `## Inputs` without hunting for them, and a captain
   reading the ledger sees what the row already stands on.
4. The pin stays the captain's: `flow:staged` rides the row only when the
   captain settled that dimension (Ending step 1 - settled dimensions
   only), and an accepted SPEC settles it by its nature (a spec is a
   design-stage artifact; the captain accepting one has chosen the flow
   that runs on it). On a row that IS staged, the accepted requirements.md
   IS the staged PO step - the family starts AT spec with it as the anchor
   and no chief re-interviews the captain on settled ground; with a spec
   accepted too, the family instead starts PAST spec, its next stage (plan
   or implement, per triage) linking the seeded `spec/report.md` exactly
   as it would an accepted stage report (the layout grammar already
   resolves it by path). On a row triaged `direct` later, the
   requirements.md is ordinary `## Inputs` context the brief cites -
   direct's own contract still authors no PO artifact (order-direct).
5. When the captain instead wants a draft CHECKED before it binds ("needs a
   scout on this"), mint the row with that stage still to run and the room
   as its input - the draft is then a head start, not
   the record.

## Leaving a trail: the scene and the Done row

A brainstorm that leaves only rows is unfindable the moment the rows are the
wrong search - and the outcome this flow is proudest of, "we thought it
through and decided not to", mints no row at all, so it leaves nothing. Two
writes at close fix that, both the CREWCHIEF's - the Done row because the
roomchief is ledger-barred, the scene because the close happens after the
roomchief is already demoted (Ending step 3), and mint-at-close is one act
by one actor:

1. A SCENE. The roomchief drafts the body as `data/brainstorm-<slug>/scene.md`
   and posts `DRAFT-SCENE` naming it - threads that settled and threads that
   died, each with its why, in the shape a reader needs to re-enter this topic
   in ONE read. At close the crewchief runs `bin/ac-scene.sh` on that file:
   `update <slug>` when the grounding step already FOUND a scene on this topic
   (it read the store first, and a second scene on one subject is the rot the
   store exists to prevent), else `new <topic-slug> --summary '<line>'`.
   `update` REPLACES the body wholesale (`bin/ac-scene.sh` header), so on an
   existing scene the draft must be the CONSOLIDATED body - the old scene,
   which grounding already read, folded together with what this brainstorm
   settled - never this brainstorm's notes alone, which would erase the very
   context the scene held. This
   is the point of the whole trail - `records/scenes/` is the layer the NEXT
   brainstorm's grounding reads, so a conclusion parked here is what ends that
   thread cheaply instead of re-running it. At the store's AMBER or RED cap
   `new` refuses and names the coldest scenes: merge per `bin/ac-scene.sh`,
   never work around it.
2. A DONE ROW - `- [x] brainstorm-<slug> - <outcome> -
   data/brainstorm-<slug>/room.md (reported <date>)`, its one line naming what
   came of it (`3 rows minted: a,b,c`, or `no rows - <why>`). It passed
   through neither In flight nor Queued because a brainstorm is not a task: it
   is a RECORD ROW written straight to Done (section 9 owns the shape), the
   ledger's own answer to "was this already thought about?".

"No rows" is a fully valid ending. Grammar, gate, and triage law stay where
they live (sections 5, 8, 9) - this skill cites them and duplicates nothing.
