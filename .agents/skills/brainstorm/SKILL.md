---
name: brainstorm
description: Captain-invocable ideation flow - the captain thinks a topic through WITH the crewchief before any order exists. Conversation only - no crewmate, no scaffold, no code, no ledger write while thinking. Ends with confirmed backlog rows (or explicitly none). Use when the captain invokes /brainstorm <topic>, or opens an exploratory "should we / how might we / what would it take" conversation that is not yet an order.
---

# brainstorm

The captain invoked `/brainstorm <topic>` - an IDEATION session, upstream of
every execution flow. Nothing here is an order yet: the deliverable is queued
backlog rows the captain has confirmed, or the explicit outcome "no rows".
Rows this flow mints are the INPUT a later `/order-direct`, `/order-staged`,
or `epic-intake` runs on - this skill never starts execution itself.

## The one hard rule: thinking has no side effects

While the session is open you spawn NOTHING and write NOTHING: no scout
("cheap" does not make it free - an unasked spawn is still action taken on
an idea the captain has not adopted), no brief, no worktree, no backlog row,
no code or config change, no room entry. Your instruments are conversation
and READS. If an idea seems to need real investigation to evaluate, say so -
"this needs a scout to answer" is itself a brainstorm conclusion, and the
row it produces is a scout row the captain confirms like any other.

## Ground before you propose

Before offering direction, read what the fleet already knows about the topic
and CITE what you find - or state its absence explicitly (the same duty
intake carries, AGENTS.md section 5):

- `bin/ac-know.sh recall '<the topic as a question>' --repo <clone>` for
  repo knowledge; `records/scenes/` for a scene that restores prior context;
  `records/learnings.md` for lessons that bear on it.
- `bin/ac-ready.sh overlap` on the surface an idea would touch, so a live
  or recent task on the same ground shapes the discussion instead of
  surprising the intake later.

A hit can end a thread ("this exists / was tried / is in flight") - that is
the cheapest possible outcome of a brainstorm, name it plainly.

## During: how to be useful

Explore WITH the captain, not for them: options with trade-offs, what each
would take, what it risks, your one-line lean when asked or when the choice
is material. Disagree with reasons when an idea fights something the fleet
already learned - cite the learning, not your taste. Keep threads separate;
when one settles, say what settled and move on. Any structured choice you
put to the captain follows the select rule (AGENTS.md section 8).

## Ending: rows only on the captain's word

When the captain closes the session (or a thread produces a concrete task):

1. Draft each row in the section-9 grammar - id, a delivery-contract token
   group carrying ONLY the dimensions the captain actually settled in this
   conversation (`src:cap` always - the captain's confirmation is the
   order-source; a settled heavy dimension pinned here is pre-consent the
   escalation gate never re-asks; an UNSETTLED dimension stays off the row
   for intake to triage later), the one-line description, `(repo: <name>)`.
2. Read every drafted row back VERBATIM and wait for the captain's yes -
   per row or for the batch, but the yes must be real; a pin written
   without the captain's word is the exact drift the contract grammar
   exists to stop (section 9).
3. Only then append the confirmed rows to `## Queued` in
   `records/backlog.md`, byte-identical to what was read back.
4. Say what was minted and what was deliberately NOT (threads that ended
   with "no", "later", or "needs a scout first") - the not-minted list is
   part of the outcome.

"No rows" is a fully valid ending. Grammar, gate, and triage law stay where
they live (sections 5, 8, 9) - this skill cites them and duplicates nothing.
