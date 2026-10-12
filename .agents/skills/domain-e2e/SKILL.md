---
name: domain-e2e
description: Prove behaviour by extending and running a DOMAIN'S MAINTAINED END-TO-END SUITE - the one repository that drives a whole product line across every repo it spans, boots its own stack from their sources, and is kept alive between campaigns. Use when a brief leases you into a domain's e2e repository (the domain declares it - ac-domain.sh qa-repo), when the order says extend the e2e suite / run the suite / prove this journey, or when a change's proof needs hops no single repo's tests can see. Not crew-qa: this route mints no attestation and never boots one deliverable in isolation.
---

# domain-e2e

You are working a domain's END-TO-END SUITE: one repository, maintained, that
proves the whole product line. The domain declares it once (`ac-domain.sh
qa-repo <domain>`); it is reused, never re-created. Standing up a second suite
beside it is the one thing this route exists to prevent.

The suite's OWN docs are authoritative for its mechanics - how its stack boots,
which refs it builds from, which credentials gate which tier. Read them before
you run anything, and trust them over re-deriving. What follows is what the
fleet owes on top, and it binds whatever the suite's shape.

## Extending is part of the proof

A change that widens behaviour widens the suite in the SAME slice. A case you
add follows the repo's own tier layout and its naming; a case that already
covers the behaviour is reused. Never leave the suite behind the product and
call the run a proof - a suite that does not assert the change asserts nothing
about it.

## Run the whole chain, then measure

- Take a BASELINE before you read the diff: run the suite as it stands, keep the
  log. Otherwise a red you meet later has no owner, and a diff invites a guess.
- Boot through the repo's own full-chain entry point. When you assemble the
  steps by hand, assemble ALL of them: a skipped setup step fails as reds in
  files named after none of it, and the reading that follows blames the code
  under test.
- When you fix something and the red clears, prove the link with a
  NEGATIVE CONTROL: break exactly that one thing again, and watch the same
  red return.

## What a green is a claim about

- "0 failed" is a claim about the cases that RAN. Count the skips FIRST and read
  where they cluster; every skip names the variable or gate the harness printed
  for it. An unexplained skip is a hole in the proof, not a detail.
- A case pinned to a non-success (an expected 502, an expected null) inflates
  the pass count without proving the behaviour. Name every one beside the count.
- A disabled/fixme case on an invariant is a LOUDER finding than most reds:
  nobody sees it and it never goes red.
- A read-back uses the id the WRITE returned. A lookup by type or by name is
  satisfied by residue on a shared environment, and proves nothing.
- Read what each passing case actually asserts, never what its title says. A
  suite can be green across a hundred cases and never have exercised the one
  journey the order was about.

## A shared environment is written once and accounted for

Writing to a shared deployment needs EXPLICIT authority in the brief, and a
write cannot be rolled back. Use the case's own persona and identifiers - never
another person's data - and list in the report exactly what was written:
accounts opened, orders placed, rows mutated, so a human can find every one. A
write the brief did not authorise is a `needs-decision:`, whatever it would
have proven.

## Evidence and the report

Keep every run's log verbatim and name it in the report. The report states, in
this order: which tree/refs were actually built, what ran, what each number
means, what is still unproven and why. A limit of the suite is stated plainly,
never buried: a boundary that declares no field cannot be asserted on, and
"this axis cannot settle X" belongs in the report the first time it is true.

Do not diagnose in the report what you did not measure. "Reproduced, cause not
established" is worth more than a guess that reads as a finding.

## Boundaries

Never edit product code from this repository, never weaken an assertion to get
a green, and never re-point a case at what the code does instead of what the
authority says it should. A defect you find is a finding with evidence; the
fix belongs to whoever owns that repo.

Close as any crewmate does: durable lessons in the report's `## Lessons`,
verified repo facts through `ac-know.sh add`. This route mints no QA
attestation - a project whose merge gates on one still needs the
profile-driven route (crew-qa).
