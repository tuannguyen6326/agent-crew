---
name: bearings
description: Captain-facing status report of the whole fleet, saved to data/. Use when the captain asks where things stand or on /bearings.
---

# bearings

Give the captain their bearings: one durable, dated status report.

1. Run `bin/ac-wake-drain.sh` and handle anything actionable first.
2. Run `bin/ac-fleet-view.sh` for the live fleet, and `bin/ac-crew-state.sh
   <id>` / `bin/ac-peek.sh <id>` where a line needs detail.
3. Read `records/backlog.md` (in flight / queued / done) and
   `records/projects.md`.
4. Write the report to `data/status-report-<YYYY-MM-DD>.md` with sections:
   In flight (per crewmate: id, task one-liner, state, next action),
   Awaiting captain (decisions, approvals, mergeable PRs), Decided on your
   behalf since <ts>, Queued, Recently done, Risks.
   `<ts>` is the mtime of the newest earlier `data/status-report-*.md`, else
   24 hours ago. The section lists every chief-posted `TRIAGE:`,
   `SELF-APPROVED:`, `GATE-LOOPED:` and `DECIDED:` that answers no captain
   message, from each `data/*/room.md` entry after `<ts>`, one line each
   with the family and the decision: these are the calls the captain vetoes
   after the fact, and an unsurfaced decision cannot be vetoed.
5. Reply to the captain with the highlights and the report path - short,
   decision-oriented, no raw dumps.
