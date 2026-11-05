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
   Awaiting captain (decisions, approvals, mergeable PRs), Queued, Recently
   done, Risks.
5. Reply to the captain with the highlights and the report path - short,
   decision-oriented, no raw dumps.
