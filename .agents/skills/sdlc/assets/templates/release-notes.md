# Release notes: <change title>

status: verified
change: <change id>
qa_report: <the QA report, relative to this file>

## Changes

- R1: <what is true after this change, as a user or an operator sees it>
- R2: <...>

## Evidence

| Repository | source_sha | PR | QA verdict |
| --- | --- | --- | --- |
| <repository> | <the sha the passing QA round exercised> | <PR URL> | <pass, round n> |

## Deploy order

1. <repository> - <from the plan, with its departures applied>

## Rollback

- <repository>: <from the plan, with its departures applied, and what it leaves behind>

## Known issues

<Excluded or deferred cases and open questions carried forward, each with the role that owns it; "none" when none.>

## Live-document reconciliation

<Each live document this change made stale and its update in this branch, or why it needed none.>
