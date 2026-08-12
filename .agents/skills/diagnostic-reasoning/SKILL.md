---
name: diagnostic-reasoning
description: Crewchief judgment for scoping a reported bug, regression, intermittent failure, or unexplained behavior into an implementation-ready root-cause diagnosis. Load before writing a diagnostic investigation brief, and again before accepting a diagnostic report as ready. A diagnosis is evidence only and never authorizes a code change. Not for ordinary feature work, code review, or post-change QA - crew-qa owns behavioral verification after a change.
---

# diagnostic-reasoning

Judgment for turning an observed failure into a defensible root-cause diagnosis BEFORE any implementation.
You (the crewchief or roomchief) own the reasoning; a crewmate owns the inspection.
This skill owns only the investigation-brief judgment and the report bar - command syntax, task-lifecycle state, and delivery mechanics stay in the `bin/ac-*.sh` script headers and `AGENTS.md`.

## When to load

- Before scoping a reported bug, regression, intermittent failure, unexplained behavior, or any root-cause investigation.
- Again before accepting a diagnostic report as implementation-ready.
- Do NOT load for ordinary feature implementation, code review, or post-change QA unless a causal diagnosis is actually required.

## Prime directive - diagnosis is not authorization

- You use this skill to WRITE and EVALUATE the investigation brief; delegate project inspection to a crewmate in its own worktree (spawn a scout for evidence-only work).
- A diagnostic report is evidence, not authorization to modify code.
- Implementation begins only under the captain's order or another existing task-lifecycle authority - never as a side effect of a convincing diagnosis.
- When a fix is later authorized, turn the reproduction into a regression test whenever practical.

## The brief must require this reasoning contract

Write the investigation brief so the crewmate cannot return a plausible guess. Require every item:

1. Start from the end-user or operator-visible path, not the first suspicious function.
2. Capture the ground facts: expected behavior; observed behavior; reproduction setup and inputs; repeatability; and, when a faithful reproduction is unavailable, the closest representative path and its limitations.
3. Separate three concepts explicitly - do not collapse them:
   - the initiating trigger (what set the failure in motion);
   - the masking or exposing condition (what let it stay hidden or made it visible now);
   - the visible symptom (what the report actually observed).
4. Compare the failing path against a proven path where the intended behavior works, and inspect the earliest meaningful divergence in input, state, timing, dependency, or control flow.
5. Inspect relevant history, blame, migrations, or prior implementations when they can explain the intended invariant.
6. Name a leading causal explanation as the smallest practical counterfactual - the minimal change that would have prevented the symptom.
7. Seek disconfirming evidence for that explanation and retain contradictory results rather than discarding them.

## The report bar - what "ready" means

Accept a diagnosis as implementation-ready only when it:

- carries reproduction evidence (or the representative-path substitute with its stated limits);
- keeps trigger, masking-or-exposing condition, and symptom distinct;
- shows the failing-versus-proven-path comparison and the earliest divergence;
- cites the relevant history that fixes the intended invariant;
- states the counterfactual and the falsification check it survived;
- distinguishes observed facts, supported inference, hypotheses, and unresolved uncertainty.

Confidence alone is not evidence. A report that asserts a cause without a counterfactual or a disconfirming check is not ready - loop it back to the crewmate.

## Non-overlap

This skill does not replace `crew-qa`.
Diagnosis explains the cause of an observed failure BEFORE implementation; `crew-qa` independently verifies delivered behavior AFTER a change.
