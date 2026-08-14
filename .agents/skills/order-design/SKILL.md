---
name: order-design
description: Captain starts a DESIGN-FIRST task - PO requirements from the captain, then the staged flow's design stages (spec/architecture/plan) run and gate NOW, execution does NOT - the accepted reports park the backlog row as design-complete and implement starts only on a later captain order. The arguments are the order verbatim. Use when the captain invokes /order-design <order>.
---

# order-design

The captain invoked this order with `/order-design` - that IS the captain's own words at the top of the flow precedence ladder (AGENTS.md section 5): flow is PINNED to `staged`, and the flow STOPS at the implement boundary.
Design runs and gates now; implementation is a LATER captain order.
Nothing here invents new machinery - every stage below is the staged flow's own design mechanics, verbatim; the only new behavior is where the flow stops.

1. The arguments may START with captain pins - strip them before reading the order: `--mode <crew-ship|direct-pr|local-only>`, `--promote <yes|no>`, `--qa <yes|no>` - exactly as `/order-staged` takes them.
   A pin is the captain's own words for THAT dimension; every unpinned dimension you still triage yourself with receipts.
   Staged review is always `yes`.
   The REST of the arguments is the captain's order, verbatim.

2. PO STEP (the section-5 REQUIREMENTS CHECK, grown into an artifact - that clause is the authoritative contract, this is only the activation): run the brief-without-guessing test on the order.
   Route by guess count: 0 -> draft; 1-4 -> ONE bundled clarify exchange with the captain first, select etiquette; >=5 or the deliverable itself a guess -> propose `/brainstorm` and stop.
   When the family is promoted, the ROOMCHIEF owns this interview in its own thread - the crewchief only promotes and hands the order over.
   Then write `data/<family>/requirements.md` (every line cite-carrying) and get the captain's LIVE acceptance - that acceptance is the whole gate.
   NO SPEC WORK STARTS before the accepted file exists.

3. Intake exactly as `/order-staged`: mint the row with its delivery-contract group - `src:cap flow:staged rev:yes` plus a token per captain flag - post the TRIAGE receipt (flow/mode/promote/qa + the design sub-stages you keep or drop), record `STAGE-ADMISSION:` per stage, and spawn ONE design crewmate (`--stage design`) with requirements.md linked under `## Inputs`.
   Per-report chief review, `ac-room.sh gate-route`, and `ac-gate.sh` only on `route=second-chief` - all unchanged law.

4. After the LAST accepted design report, run the pre-implement gate NOW, not at implement time - a defect is cheapest while the design context is warm, and the later implement start only re-hashes.
   The captain-required tier still asks now; the captain's "approve" AUTHORIZES implement and the row still parks ("approve - implement now" starts it immediately instead).

5. PARK instead of spawning execution - the one divergence from `/order-staged`:
   - tear down the design crewmate (a design task delivers only reports; they are on disk under `data/<family>/spec|arch|plan/`);
   - move the row to Queued reading `design-complete: <stages> accepted <date> - implement on captain order`, KEEPING the contract pins (the pin is pre-consent; the escalation gate never re-asks);
   - post `DESIGN-COMPLETE: reports=<paths>` to the room - a RECEIPT, never a pending `GATE:` (the captain's inbox must not carry a forever item for work that is deliberately parked);
   - a promoted roomchief hands back and is demoted; the room stays open history for the implement leg.

6. The later captain order ("implement <id>", any wording naming the row) restarts the family at the execution stage: reopen the room, brief `--stage implement` with requirements.md and every accepted report under `## Inputs`, and re-hash each admitted report against its `GATE-ROUTING:` receipt sha - unchanged reports proceed on the recorded gate pass; ANY mismatch reopens the earliest mismatched stage first (section 5's mechanical pre-implement rule, unchanged).
   Execution then owns implement + delivery (+ qa per pins) exactly as staged law says.
