---
name: judgment-rules
description: The full text of the four fleet-wide judgment rules: finding-authority (binds a finding when written), evidence-class (binds a review request), financial-code proof (binds a resolution on money paths), and verify-before-assert (binds any chief claim about a mechanism, rule or authority). Load before writing a finding, requesting or judging a review, resolving anything on financially sensitive code without the captain, or when AGENTS.md's one-line summary of a rule leaves a case open.
---

# judgment-rules

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Judgment rules

- Finding-authority rule - FLEET-WIDE, and it binds when a finding is
  WRITTEN, not when a fix is decided. Every defect statement names the
  AUTHORITY for its EXPECTED behavior, and the author has read it.
  (a) A finding whose expected behavior is something an actor OUTSIDE
  this repository does - `herdr`, the `claude` CLI, `git`, `tmux`, a
  partner, a database, a client library's runtime, the network - cites
  a citable authority (in-repo docs, including `docs/bmad/**`, a spec,
  or a captain ruling; a stale doc is a doc bug, never a licence to
  ignore it), or it is `needs-decision:` / `ask-user` - NEVER a defect.
  A citation that CONTRADICTS the finding is that finding's refutation.
  (b) Any bash repro in this distro holds everything constant except
  the disputed variable, and DECLARES it (`# DISPUTED:` /
  `# HELD-CONSTANT:` headers).
  CLAUSE (a)'s citation - not (b)'s declaration - is what rides the
  findings wire, as two flat keys per finding: `authority_class`
  (internal|external|none) + `authority` (a `file:line`, a URL, or
  `captain <date>`). The shared normalizer `ac_findings_normalize`
  (`bin/ac-pipeline-lib.sh`, the single enforcement point for both
  pipelines) DOWNGRADES an `action: fix` finding with no authority to
  `ask-user`, so an unfounded statement reaches the captain instead of
  a fixer - EXCEPT a `severity: info` finding, which the same normalizer
  FLOORS to `no-op` first (`severity_floored: true`, authority named or
  not): info means no action required, so nothing is ever assigned and
  no review round reopens; the finding and its advisory `suggested_fix`
  still land in the findings JSON and the PR. `action: fix` itself is
  RESERVED for delivery-blocking findings - correctness, security,
  regression, data loss, accepted-requirement/ruling violation (the reviewer prompt in `bin/ac-verify.sh` and the
  findings contract in `bin/ac-ship.sh` carry the same rule).
  The normalizer preserves/supplies the captain-relay shape on every
  resulting `ask-user`; canonical verifiers must author it explicitly. The rule
  binds every author - crewmates, codereview/qa verifiers, gate judges, and you.
- Evidence-class rule: every review request NAMES the act (evidence
  class) the check must settle its question by - not merely a
  different reader. Clause R, UNCONDITIONAL, one line on every
  request: the request states `MUST BE SETTLED BY: <the act>`.
  Clause V, only when the family room already carries the requester's
  own ruling on the matter under review: the request ALSO states a
  `DISPUTED:` block naming the question and the act that already
  answered it, and Clause R's act may NOT be that act - an absent
  Clause V on such a request is the check's first finding. Same act =
  same class: two pieces of evidence are the same class when the same
  act would produce both (reading in-repo precedent twice is one act;
  reading the code and running the thing are two). Cannot name the act
  that would settle the question? That is itself a `needs-decision:`
  at request time, never a soft fallback - "any act other than the one
  already used" names no evidence class and enforces nothing. The
  check reads the family room FIRST (`bin/ac-room.sh show <family>`):
  a requester ruling already on record (a `SELF-APPROVED:`, a
  `GATE-PASSED (auto):`, a `GATE-LOOPED:`, a `DECIDED:` the chief
  recorded on its own call, or any chief entry stating a verdict) with
  no `DISPUTED` part on the request is the check's first finding,
  `needs-decision:`, naming the room entry, before it reviews
  anything. The check's verdict NAMES the act it used; an act that is
  not Clause R's act, or is Clause V's already-used act, reports `not
  independently settled` - a finding carrying `needs-decision:`,
  naming the act used and the act that would settle the question -
  instead of confirming, never a third verdict value. Fleet POLICY
  over a chief's request text: the codereview prompt in `bin/ac-verify.sh`
  carries only Clause V's room-ruling check (a requester ruling with no
  `DISPUTED` block settles to `ask-user`); Clause R's line and the `not
  independently settled` report are the requester's and the checker's to
  carry, and no tool checks them.
- Financial-code proof rule: on financially sensitive files (payments,
  interest, balances, notifications about money), a resolution the crew
  decides WITHOUT the captain must carry PROOF in its receipt -
  compile-forced, byte-identical to a reviewed blob, or an empirical
  invariant a test demonstrates (who is affected / how much stays
  unchanged). Each form is bound to the question it can answer:
  compile-forced and byte-identical prove CODE/FORM and cannot close
  a RISK or REACH question; an empirical invariant a test
  demonstrates is the form that does, exactly the who's-affected /
  how-much-stays-unchanged proof named above. A proof offered
  against a question it cannot answer counts as no proof.
  Compile-forced carries one burden beyond that, because its absence
  is SILENT: it proves only what the compiler ACTUALLY refuses to
  compile, so whoever invokes it NAMES the construct that fails to
  compile if the claim is false. A type system that merely PERMITS
  the shape has refused nothing, and an unrefused claim is a reading
  of the code - not one of the three forms, so it counts as no proof.
  The other two forms need no such clause - a byte comparison and a
  demonstrated invariant are acts someone performed and a reader
  re-performs to a definite answer, while a refusal that never
  happened looks exactly like one that did. A question about what an
  actor OUTSIDE this repository really sends or does is closable by
  NO static form: an assertion about a value's type is not an
  observation of that value, so no number of agreeing in-repo
  artifacts witnesses a field on the wire - that class is closed by
  an observation of the actor itself, or by nothing at all. No proof
  means it is not a decision, it is a guess: park it as
  `needs-decision:` and ASK. It is the twin of the finding-authority
  rule above: that one binds a FINDING at write-time, this one binds
  a RESOLUTION. Implement, review
  fixes, and delivery are ONE execution role: the same crewmate carries the
  task from first commit through fix rounds to delivery (steer its live
  session with ac-send; `--resume-from` it when already torn down - same
  role, resume allowed). A fresh execution crewmate on the crew branch is
  recovery only when that session is unrecoverable.
- Verify-before-assert rule - FLEET-WIDE, and it binds the crewchief and
  every roomchief the instant they ASSERT a mechanism, a rule, or an
  authority in ordinary prose - the gap the three rules above leave:
  finding-authority binds a finding at write-time, evidence-class binds a
  review request, financial-proof binds a resolution, and none binds an
  ordinary claim. (a) No claim about a mechanism, a rule, or an authority
  without running the check FIRST, and the claim CITES what was read - a
  `file:line`, a command's output, or a captain.md entry. No citation
  available? Say so and stop - never assert softly. This covers claims about
  code paths, about what a tool does, and about what the captain decided. (b)
  Never deviate from a config pin without QUOTING the `captain.md` line that
  permits it; cannot find that line, follow the pin - a `flow=staged(...)`
  token in a backlog row, a `[CAPTAIN-ORDERED]` tag on a task, or the captain
  having split or routed a row are NOT authority. (c) A self-correction meets
  the SAME evidence bar as the original claim: retracting on a feeling, or on
  the first fragment that fits a new hypothesis, is the same defect wearing
  the opposite sign - read the WHOLE contract before reversing. The failure
  shape this exists to kill: asserting from the first piece of evidence that
  matched a hypothesis when the disproving command was one line away - reach
  for the check BEFORE the sentence, not after being corrected.
