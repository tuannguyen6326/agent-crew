---
name: order-direct
description: Captain starts a task with flow PINNED to direct (crewchief -> one crewmate). The arguments are the order verbatim. Use when the captain invokes /order-direct <order>.
---

# order-direct

The captain invoked this order with `/order-direct` - that IS the captain's
own words at the top of the flow precedence ladder (AGENTS.md section 5):
flow is PINNED to `direct`. Do not re-triage the flow; everything else
(mode, promote) you still triage yourself.

1. The arguments may START with captain pins - strip them before reading
   the order: `--mode <crew-ship|direct-pr|local-only>` pins the delivery
   mode (pass it through as `ac-brief.sh/ac-spawn.sh --mode <m>`),
   `--review <yes|no>` pins independent review for `direct-pr`/`local-only`
   (`crew-ship` is always `yes`; `--review no` there is invalid) - a pinned
   `--review yes` IS the captain's request, and ac-brief refuses that raise
   without it declared, so pass it on as `ac-brief.sh --review yes
   --captain-requested '/order-direct --review yes'`,
   `--promote <yes|no>` pins the promotion decision, and `--qa <yes|no>`
   pins whether the change gets a crew-qa gate - an independent behavioral
   proof the implementer runs AFTER ship (it gates the merge, never the
   push; AGENTS.md section 5). A pin is the captain's own words for THAT
   dimension; every unpinned dimension you still triage yourself with
   receipts (for qa, the triage signals are user-facing/DB/financial/
   captain-critical). The REST of the arguments is the captain's order,
   verbatim.
2. Run the section-5 intake exactly as law: WRITE the pinned dimensions
   onto the backlog row as its delivery-contract token group (section 9
   grammar) - `src:cap flow:direct` plus a token per flag the captain gave
   (e.g. `[src:cap flow:direct mode:crew-ship rev:yes qa:no]`); the pin IS
   the record that skips the escalation ask, today and on every future
   touch of this row. Unpinned heavy dimensions your OWN triage wants
   still go through the section-5 escalation ask before you mint them.
   Then the TRIAGE receipt to the family room WITH your reasoning for
   mode/promote and qa when unpinned (flow needs none - the captain
   pinned it), then brief and
   spawn ONE execution crewmate for implement + delivery. When review is yes,
   `crew-ship` fulfills it inside its engine and other modes call
   `ac-verify codereview` directly. When qa is on (pinned yes, or
   your triage says so), the crewmate calls crew-qa after delivery and fixes
   its findings before the merge gate.
3. The upgrade rule still applies: if the task sprouts `needs-decision:`
   requirement questions, STOP and upgrade to staged - but because the
   captain pinned direct, upgrading is an ASK (why + options + lean),
   not a self-decision.
   That ASK follows the select rule - AGENTS.md section 8
   (`AskUserQuestion`).
