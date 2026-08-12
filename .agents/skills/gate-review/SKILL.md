---
name: gate-review
description: Build the ONE consolidated pre-implement review page for a captain-required gate - a single self-contained HTML file reviewed in rich-review, letting the captain approve/veto a whole staged task without asking anything back. Use at a CAPTAIN-REQUIRED pre-implement gate on a substantial task (AGENTS.md section 5), or when the captain asks for the rich review.
---

# gate-review

The pre-implement gate law lives in AGENTS.md section 5: whether a gate is
CAPTAIN-REQUIRED (vs auto), and that the tier is never waived by `+yolo`.
This skill is the HOW for the rich path - the consolidated review page you
offer at a captain-required gate on a substantial task, so the captain
decides in one place instead of reading every stage report.

## The page

Render ONE consolidated review page as a single self-contained HTML file,
reviewed in rich-review (`bin/ac-review.sh open <file>.html --auto-open`, see
the `rich-review` skill - the `--auto-open` flag is this skill's own: the
captain is already blocked on this URL, so pop it without making them copy a
link out of a pane). ONE page per TASK, never one page per stage report. It must let the
captain decide without asking anything back - its sections, in order:

1. the original order, verbatim;
2. accepted spec summary with the ACCEPTANCE CRITERIA verbatim, plus
   assumptions made and out-of-scope;
3. chosen architecture with the rejected alternatives and why;
4. the full plan (steps, exact files, test strategy);
5. risks and irreversible steps (migrations, data changes, breaking
   changes) called out separately;
6. YOUR DECISIONS LOG - every intermediate report you self-approved and on
   what grounds (this gate is where the captain vetoes them);
7. the derived review obligation and whether `ac-ship` or direct `ac-verify`
   fulfills it inside execution delivery;
8. links (absolute paths) to every full stage report for drill-down;
9. your recommendation, one line.

## The loop

The captain annotates inline; you poll, apply, `--agent-reply`, loop.
"Approve" said in chat or in rich-review IS the gate - never silence, never a
proceed on no answer.
Putting approve/veto/revise to the captain in chat follows the select
rule - AGENTS.md section 8 (`AskUserQuestion`).
