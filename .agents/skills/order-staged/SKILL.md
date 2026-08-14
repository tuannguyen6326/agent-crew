---
name: order-staged
description: Captain starts a task with flow PINNED to staged (design -> execution, where execution owns implement + delivery). The arguments are the order verbatim. Use when the captain invokes /order-staged <order>.
---

# order-staged

The captain invoked this order with `/order-staged` - that IS the captain's
own words at the top of the flow precedence ladder (AGENTS.md section 5):
flow is PINNED to `staged`. Do not re-triage the flow; everything else
(mode, promote, WHICH design sub-stages the task needs) you still triage
yourself.

1. The arguments may START with captain pins - strip them before reading
   the order: `--mode <crew-ship|direct-pr|local-only>` pins the delivery
   mode (pass it through as `ac-brief.sh/ac-spawn.sh --mode <m>`),
   `--promote <yes|no>` pins the promotion decision, and `--qa <yes|no>`
   pins whether the task carries a `<family>-qa` stage - an independent
   behavioral proof run AFTER ship that gates the merge, never the push
   (AGENTS.md section 5). A pin is the captain's own words for THAT
   dimension; every unpinned dimension you still triage yourself with
   receipts (for qa, the triage signals are user-facing/DB/financial/
   captain-critical). The REST of the arguments is the captain's order,
   verbatim.
   Staged review is always `yes`; `--review no` is invalid and no review flag
   is needed.
2. PO STEP first (the section-5 REQUIREMENTS CHECK clause is the
   authoritative contract): run the brief-without-guessing test on the
   order and route by guess count (0 -> draft; 1-4 -> ONE bundled clarify
   exchange with the captain; >=5 -> propose `/brainstorm` and stop). When
   the family is promoted the ROOMCHIEF owns the interview in its own
   thread. Write `data/<family>/requirements.md` (every line
   cite-carrying) and get the captain's LIVE acceptance - NO SPEC WORK
   STARTS before that file exists; the design brief links it under
   `## Inputs` and the spec report's Trace IDs trace to its lines.

3. Run the section-5 intake exactly as law: WRITE the pinned dimensions
   onto the backlog row as its delivery-contract token group (section 9
   grammar) - `src:cap flow:staged rev:yes` plus a token per flag the
   captain gave (e.g. `[src:cap flow:staged mode:crew-ship rev:yes qa:yes]`);
   the pin IS the record that skips the escalation ask, today and on every
   future touch of this row. Unpinned heavy dimensions your OWN triage
   wants still go through the section-5 escalation ask before you mint
   them. Then the TRIAGE
   receipt to the family room WITH your reasoning for mode/promote, qa (when
   unpinned), and for the design sub-stages you keep or drop, then start
   the design crewmate (`--stage design`, per-report chief review and
   `ac-room.sh gate-route`). Run `ac-gate.sh` only when the derived route is
   `second-chief`; a low-consequence, evidence-clear report stays chief-owned,
   while captain-owned authority goes directly to a pending captain gate.
   Any ASK this intake puts to the captain follows the select rule -
   AGENTS.md section 8 (`AskUserQuestion`).
4. After the pre-implement gate, spawn one execution crewmate. It owns TDD,
   code, self-review, commit, independent review, checks, docs, and delivery.
   Its self-review is plugin-first over the full diff (project-provided plugins
   first) and falls back to a manual full-diff pass only when no applicable
   code-review plugin exists; it never runs both passes.
   There is no code-review or ship crewmate. In `crew-ship`, the engine's
   review step fulfills `review=yes` exactly once; in `direct-pr`/`local-only`,
   execution calls `ac-verify codereview` directly. When qa is on, execution
   calls `bin/ac-qa.sh agent` after delivery and owns any fix/re-delivery loop.
