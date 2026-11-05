# QA report: <change title>

status: draft
change: <change id>
test_plan: test-plan.md
verdict: <pass | fail>
round: <n>

## Sources

| Repository | source_sha | PR |
| --- | --- | --- |
| <repository> | <exact sha the round exercised> | <PR URL> |

## Results

| Case | Result | Evidence |
| --- | --- | --- |
| TC1 | <pass | fail> | <path or link to the evidence the verifier produced> |

## Findings

<One line per failed case: what was observed, what the spec expected, who fixes it; "none" on a passing round.>

## Regression updates

<Cases to add to qa/regression.md at landing, so the next change keeps them.>
