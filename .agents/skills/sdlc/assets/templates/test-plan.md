# QA test plan: <change title>

status: draft
change: <change id>
spec: <the spec, relative to this file>
plan: <the plan, relative to this file>

## Profiles

| Profile | Where it runs | Prerequisites |
| --- | --- | --- |
| <project/scope/app> | <environment> | <data, services, credentials by name only> |

## Cases

| Case | Acceptance criterion | Profile | Steps | Expected evidence |
| --- | --- | --- | --- | --- |
| TC1 | AC1 | <profile> | <steps> | <what proves it: output, screenshot, record> |
| TC2 | AC2 | <profile> | <...> | <...> |

## Regression

<Live regression cases from qa/regression.md this change must keep green, by id.>
