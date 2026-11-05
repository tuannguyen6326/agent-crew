# Plan: <change title>

status: draft
change: <change id>
spec: spec.md

## Repositories

| Repository | Role | Branch | PR |
| --- | --- | --- | --- |
| <main repository> | record (+ code when it participates) | crew/<record story family> | <PR URL when raised> |
| <code repository> | code | crew/<code story family> | <PR URL when raised> |

## Order of work

1. <repository>: <task group, traceable to spec requirements>
2. <repository>: <...>

## Deploy order

1. <repository> - <why first>
2. <repository> - <depends on 1 because ...>

## Rollback

- <repository>: <the single command or runbook that reverts this change, and what it leaves behind>

## Risks

- <risk> - <mitigation>

## Tasks (<main repository>, only when it is also a code repository)

<The `## Tasks`, `## Order and dependencies`, `## Risks` and `## Departures from plan` sections of templates/repo-plan.md for this repository, folded here instead of a separate plan.<repository>.md.>

## Proof

<Which tests, checks and QA cases prove the change; qa/test-plan.md holds the cases.>
