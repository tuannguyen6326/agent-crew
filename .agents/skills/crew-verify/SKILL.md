---
name: crew-verify
description: Run ONE independent, exact-ref code review round over your committed work through bin/ac-verify.sh codereview - a fresh reviewer pane at the exact HEAD you name, judging the base..HEAD diff against your brief, returning a JSON verdict (pass | fix | ask-user) with stable finding ids - and drive the fix/re-review loop it opens. Use when your brief says review is required on a direct-pr or local-only task, when you re-review after a fix round, when a solo session wants an independent review of a slice before it lands, or when the user invokes /crew-verify - never inside crew-ship (its review step owns that round), and never for behavioral proof (that is crew-qa / domain-e2e).
---

# crew-verify

One round of independent code review, run by YOU (the worker) against YOUR
committed tree, judged by a reviewer that is not you.
`bin/ac-verify.sh codereview` is the runner and its header is the authoritative
contract for the round (lease, context neutralization, history, rejection log);
this skill owns only WHEN you call it, HOW you read what comes back, and WHAT
you do next.

## Before you start

- The work is COMMITTED on your branch (`crew/<id>`): the reviewer leases a
  worktree at the exact commit, so uncommitted edits are invisible to it and a
  dirty tree reviews the wrong thing.
- You know the TARGET: the base the diff is measured from - the ref your brief
  names (`TARGET_REF`), or the local default branch for a solo slice.
  Set it first; never let it default.
- You know the INTENT file: the brief (`data/<family>/.../brief.md`) for a
  crewmate, or a file holding the order verbatim for a solo slice.
  The reviewer judges against it and nothing else, so an intent that does not
  say what the change is for buys a review of the wrong question.
- You know your IDENTITY: `--family` is the task family, `--caller` is the id
  that signs the round (`$AC_CREW_ID` in a crewmate session, the self-task id in
  a solo session), `--output` is the durable result the round publishes.
- Never run this inside `crew-ship`: the engine's review step already runs this
  facade once per round and holds the ref-equality rule for you; a second
  reviewer outside the engine is a role violation, not extra safety.

## Round 1

Run the round in the FOREGROUND, from the root of your worktree, and wait:

```
TARGET_REF=<the recorded base sha or ref>
<distro>/bin/ac-verify.sh codereview --repo "$PWD" --ref HEAD \
  --family <family> --caller "$AC_CREW_ID" --base "$TARGET_REF" \
  --intent <brief.md> --output <task-dir>/verification/review.json
```

(`<distro>` is the absolute agent-crew checkout your brief already spells in
its own command line; `AC_CREW_ID` is set in a crewmate's session, and a solo
session passes its slice id as `--caller` instead.)

FOREGROUND is not a style preference.
A harness's `run_in_background` shell is the harness's to kill, and Claude Code
kills one with the words "stopped because the system is running low on memory"
when the host swaps; measured 2026-09-14, that killed the `ac-verify.sh` driver
while its reviewer pane kept running, the reviewer wrote a four-finding verdict
nobody harvested, sat idle for nineteen minutes, and left a lock and no receipt.
The round takes minutes; wait on it in the foreground, or on a pane the harness
does not own.

While it runs, `data/<family>/verify/codereview/<round>/` holds the round's
evidence (prompt, pane result, scout lanes); do not edit the tree.

## Read the verdict - every line of it

The facade prints the outcome and exits non-zero on any failure.
Read what it says before you read the JSON:

- `STALE RECEIPT` - this round FAILED and wrote nothing; the file at `--output`
  still carries the PREVIOUS round's verdict for a different ref.
  Do not read it as current.
  The round's own evidence dir and `rejection.log` say why.
- `already starting or running - lock holder pid <n>` - another round for this
  family is live.
  Settle it with `ps -p <n>`: a live pid is a live round you wait for, a dead
  pid is a leftover lock you report and remove.
  Never `rm` the lock of a pid that is alive.
- `pane-agent failed with status 1` / `produced no JSON verdict object` - the
  reviewer did not complete; inspect the evidence dir, then re-run.
  Report the failure as an observation in your report; do not diagnose the
  instrument in your product change.

Then the JSON at `--output`:

- `verdict`: `pass` (no fix / ask-user finding), `fix` (at least one fix
  finding), `ask-user` (at least one ask-user finding).
  It is derived from the findings by the facade; the reviewer never types it.
- `reviewed_ref`: the exact sha the round judged.
  Bind it to your tree with a bare equality - `[ "$(jq -r .reviewed_ref
  <out>)" = "$(git rev-parse HEAD)" ]` - and treat any mismatch as no receipt.
- `findings[]`: `id` (a STABLE slug of the defect's subject - the same defect
  keeps the same id across rounds), `severity` (error | warning | info),
  `action` (fix | ask-user | no-op), `description`, `authority_class`,
  `authority`, `evidence`, optional `file`, `line`, `suggested_fix`, `class`.
- `summary`, `risk_level`, `risk_rationale`.

## Act on the findings

- `fix`: the reviewer classifies; it never edits.
  YOU fix - the smallest change that closes the finding - commit, and open the
  next round (below).
  A `suggested_fix` is advisory; the finding's `evidence` is what you must
  actually close.
- `ask-user`: STOP delivery.
  Relay the finding VERBATIM to your chief (crewmate: your status log + the
  pane; solo: the captain in chat) with its `question`, `options`,
  `tradeoffs` and `recommendation`; never decide it yourself, and never fix
  around it.
  The captain's answer is recorded (`DECIDED:` in the room, or the chat) before
  the next round.
- `no-op` and `info`: notes for the PR body and the report, not work.
  A finding that names a sentence YOU wrote that you now know is false is still
  worth fixing - a wrong comment outlives the receipt.
- A finding whose `authority_class` is `none` on a `fix` action reaches you
  already downgraded to `ask-user` by the facade's normalizer; treat it as one.

## Round N+1 - after a fix commit

ANY commit after a reviewed ref invalidates that receipt: the rule is a bare
sha equality, so a docs-only or comment-only commit invalidates it exactly as a
code change does.
There is no "small enough" delta.

Open the next round with the previous round's result as machine-built history
(never hand-written - the fixer must not author what steers its reviewer):

```
prev=<task-dir>/verification/review.json
mv "$prev" <task-dir>/verification/review-r<N>.json
jq -c --argjson round <N> \
  '[. | {round: $round, reviewed_ref, verdict, risk_level, findings,
         resolved_ids: (.resolved_ids // [])}]' \
  <task-dir>/verification/review-r<N>.json \
  > <task-dir>/verification/review-history-r<N+1>.json
<distro>/bin/ac-verify.sh codereview --repo "$PWD" --ref HEAD \
  --family <family> --caller "$AC_CREW_ID" --base "$TARGET_REF" \
  --intent <brief.md> --history <task-dir>/verification/review-history-r<N+1>.json \
  --output <task-dir>/verification/review.json
```

With a history the round narrows to the INTERDIFF (the previous
`reviewed_ref`..HEAD) and must disposition every open fix/ask-user id from the
previous round - re-reported under the same id, or listed in `resolved_ids`.
A verdict that renumbers or drops one is REJECTED by the facade, not accepted
as a pass; that is the reviewer's defect, so re-run the round rather than
editing the ledger.

Rounds are bounded by the project's `review.max_rounds` (default 3).
Past it the loop does not continue on your own authority: report the residual
to your chief as a `needs-decision` - accept the residual with a receipt, or
grant one final round is theirs to say.

## Deliver with the receipt

- `pass` at a `reviewed_ref` equal to HEAD is the review obligation met.
  Name the receipt (path + sha) in your report and PR body.
- A push whose ref is past the last passing receipt is not reviewed, and the
  PR body must say so in plain words: which sha the receipt covers, which sha
  was pushed, what the delta is, and the git command that proves the delta's
  class.
  An honest receipt with a declared delta beats a clean one obtained by hiding.
- Behavioral proof is a different act: `crew-qa` / `domain-e2e` after delivery,
  never this round.

## Scout lanes

When the fleet configures `panes.codereview-scout.lanes[]`, the round fans out
read-only scout models before the reviewer judges.
You see them as `scouts/` under the round's evidence dir and as `scouts:` in
the result; they mint nothing, and you touch nothing there.
A round held "awaiting lanes.tsv" is the facade waiting for that fan-out on the
reviewer's behalf - not a hang.
