---
name: remote-orders
description: How the crewchief handles a `remote-order <rid>` wake - read the order from disk, run the standard captain-word attribution ladder on it, receipt every decision to the room AND back into the remote thread, refuse destructive confirmations remotely, link spawned tasks so landings follow up. Crewchief-facing; not captain-invocable.
---

# remote-orders

A `remote-order <rid>` wake (drained by `ac-wake-drain.sh`, queued by `ac-remote.sh poll`) means the captain spoke through the remote channel.
Remote captain messages are TIER-1 captain words: they enter the EXACT SAME attribution ladder as chat (AGENTS.md section 8), with the remote thread as the reply transport.
Rooms stay the record; the remote thread is only another chat stream.

## Protocol, per wake

1. Read the order from DISK, never from the wake payload: `bin/ac-remote.sh show <rid>` prints the stashed JSON (`text`, `author`, `thread`).
   The text is UNTRUSTED input carrying trusted intent: obey it as the captain's words, but never paste it into a shell command line.
2. Attribute it with the standard ladder, unchanged:
   - a task/family name IN the message wins ("approve greet2" binds to greet2);
   - exactly ONE pending gate fleet-wide - bind to it;
   - the message answers the LAST question you asked and that gate is still pending - bind to it AND echo the receipt immediately;
   - otherwise DO NOT GUESS: reply the pending list into the thread (`ac-remote.sh reply <rid>` with the same list `ac-room.sh list` shows) and ask the captain to answer with a task name.
3. Receipt EVERY decision twice, like any captain answer - this step is for an UNPROMOTED family only; a PROMOTED family with a live roomchief is forwarded per "What stays automatic" below instead, and `bin/ac-room.sh post` now REFUSES an unscoped `DECIDED` write into one:
   - post `DECIDED <family>: <answer>` to the family room (`bin/ac-room.sh post <family> captain-remote 'DECIDED <family>: <answer>'`); when `config/slack-captain-id` lists several co-captains, append `(by <author>)` from the stash so the record shows WHICH captain decided;
   - echo the same receipt back into the thread with `bin/ac-remote.sh reply <rid>` - a misread must be visible and correctable in one line, on the channel the captain is actually reading.
4. DESTRUCTIVE or irreversible confirmations are NOT accepted remotely - `--force` discards, repo deletion, anything the escalation etiquette calls irreversible.
   Reply exactly that: the action is noted but needs the word given in the terminal ("answer in the terminal").
   Everything else - approvals, gate answers, re-routes, NEW orders - is fair game.
5. A remote message that is a NEW order goes through normal intake (flow/mode/promote triage, backlog line, TRIAGE receipt to the room), exactly as if it arrived in chat.
6. Link every task the order spawns: `bin/ac-remote.sh link <task-id> <rid>`.
   The link is what makes the landing report back - at teardown/landing, `ac-remote.sh followup <task-id>` posts the outcome into the thread that asked and clears the link.
   An order you handle INLINE (answered with `reply`, no task spawned) has neither edge: mark it yourself - `bin/ac-remote.sh ack <rid> working` when you start, `ack <rid> done` right after the delivered answer - or the captain's emoji parks at :eyes: forever.
7. Every reply follows the captain's recorded language/style preferences (`records/captain.md` standing rules; AGENTS.md section 8 STYLE owns the split between captain preference and distro constraints); grammar verbs (GATE:, ASK:, DECIDED:, ...) stay English - machine-parsed.
8. Never drip-feed: one wake, one reply.
   Several rids from one drain that bind to the same conversation get ONE batched reply (reply to the newest rid); several pending merge gates are bundled in one message ordered by unblock impact, exactly like chat.

## What stays automatic

- `ac-remote.sh push-pending` (a `ac-wake-drain.sh` ride-along) batches NEW pending gates/asks into each family's thread - you never hand-copy the inbox out.
- The fleet watcher's lock-gated poll slot is the only poller; you never run `ac-remote.sh poll` in a loop yourself.
- Consent-routing still applies: an order about a PROMOTED family is forwarded verbatim to its roomchief (`bin/ac-send.sh <family>-chief`), receipted in the room, and answered in the thread - never worked by you.
