// ship.ts - the crew-ship pipeline's state machine and deterministic runner.
// The entry is bin/ac-ship.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-ship.sh as the oracle the
// differential leg of tests/sh/ac-ship.test.sh holds this module to.
//
// Run from inside the target repo/worktree being validated. State lives at
// <repo>/.crew/ship/<run-id>/ with a `current` symlink.
//
// Usage:
//   ac-ship.sh start --intent <text> [--skip <a,b,...>] [--target <branch>] [--lint] [--tdd]
//
// LEAN PIPELINE - two steps are conditional, both
// FAILING TOWARD RUNNING:
//   - `lint` is OPT-IN: skip-by-default, and RUNS only when `--lint` is passed
//     (the captain/brief requests it).
//   - `test` SKIPS on `--tdd`: the implement DECLARES its TDD run is the test
//     evidence. FAIL CLOSED - absent `--tdd`, test RUNS. `--tdd` is a DECLARATION,
//     not attestation-by-execution: no re-run, no `commands.test` needed, and no
//     tree check, so it is only as good as the claim. A fix that changes code
//     re-runs test regardless (the fix-reopen rule) - the implement's TDD never
//     covers a later fix diff. `intent` and `review` refuse `--skip` outright at
//     `start` (F4): one flag used to be able to mint a
//     validated run with zero steps done, including these two, so both are
//     machine-unskippable rather than resting on convention. `skip-remaining`
//     is a separate command and is unaffected - it still marks any step that
//     is still pending/running `skipped` after an empty-diff rebase.
// Every step stays RUNNABLE on request. (The separate `attest-test` /
// `test.attestation` machinery is the EVIDENCE-backed variant, used for chief
// verify via `attest-check`; `--tdd` is the lightweight declaration for the
// lean skip.)
//
// --target <branch> pins the run's DELIVERY TARGET when it is not the repo
// default branch (a prelive/release-vN PR): every base-derived step - review
// diff, test/lint reopen scope, push incorporation, the finish `passed`
// merged-evidence gate - computes against origin/<branch> (local fallback;
// mistyped = loud refusal), recorded as target= in run.meta and recomputed
// each round for rebase drift. Omitted = origin/HEAD, byte-compatible with
// every existing run. Pushing the target branch itself is refused exactly
// like the default branch.
//   ac-ship.sh step <name> <status> [--note <text>]
//   ac-ship.sh findings <step>            (JSON array on stdin; refuses a tty)
//   ac-ship.sh findings <step> --show     (print stored findings, writes nothing)
//   ac-ship.sh meta <step>                (JSON object on stdin, refuses a tty:
//                                              risk_level, risk_rationale,
//                                              testing_summary, tested, artifacts)
//   ac-ship.sh cmd <test|lint|format>
//   ac-ship.sh attest-test                (implementer's final TDD run;
//                                              green -> attestation on disk)
//   ac-ship.sh attest-check               (verifier's freshness query:
//                                              0 fresh / 1 stale / 2 none)
//   ac-ship.sh push                       (lease + patch-id guarded push)
//   ac-ship.sh base                       (fresh merge-base vs the run's target,
//                                          else the default ref)
//   ac-ship.sh evidence-dir               (resolved test-evidence dir)
//   ac-ship.sh skip-remaining             (empty diff: skip what's left)
//   ac-ship.sh config <dotted.key>
//   ac-ship.sh fix-report <step>          (markdown handoff for a fixer)
//   ac-ship.sh review-agent               (independent exact-ref verifier)
//   ac-ship.sh review-residual accept --grounds '<text>'
//                                         (owning chief accepts a capped review residual)
//   ac-ship.sh status
//   ac-ship.sh finish <checks-passed|passed|failed|cancelled>
//
// LIVE DASHBOARD: start auto-opens ac-ship-watch.sh in a herdr tab (label
// ac-ship-watch, agents workspace; AC_SHIP_WATCH=off disables; an orca fleet
// opens none) - it marks the
// active step, shows fix rounds + findings, tails the run log, and SELF-CLOSES
// when the run finishes or idles; finish also retires it via <run>/watch.pane.
//
// Steps (fixed order):
//   intent rebase review test document lint push pr
// Step statuses: pending running fixing awaiting_approval completed skipped failed
// `step <name> fixing` also increments the step's durable auto-fix round
// counter (third steps.tsv column) - compare it against auto_fix.<step>. The
// review CAP and the review ROUND NUMBER do not read it (see REVIEW-ROUND
// CONVERGENCE below); fix-report numbering and auto_fix still do.
//
// INDEPENDENT REVIEW: the review step is never self-review. `review-agent` is a
// policy adapter over `ac-verify codereview`; the facade owns one fresh pane,
// one exact-ref isolated lease, the canonical prompt, verdict validation, and
// durable capture-before-reap. review-agent passes only the immediately previous
// validated round (`logs/review-history-rN.json`, machine-built so the fixer
// never authors what steers its reviewer) as --history; ac-verify turns it into
// an interdiff attention map plus fail-closed disposition of that round's open
// ids. crew-ship never
// resumes a reviewer session, replaces a pane, or invokes a headless fallback.
// `<run>/review.agent` binds the receipt to `reviewed_ref`; `step review
// completed` refuses when HEAD differs, and `push` and `finish
// checks-passed|passed` re-check the SAME binding (assertReviewCurrent), so a
// fix landing after review cannot be pushed or recorded as validated - the
// completed transition proved currency at one instant, not at delivery.
// The manual `meta review` path stamps reviewed_ref = HEAD into
// review.meta.json at the SAME `step review completed` transition (F8), so it
// is bound exactly like the review-agent path from then on. Which receipt that
// transition reads is decided by CURRENCY, not by which files exist (F8b): a
// review.agent bound to HEAD wins; a STALE one does not veto the manual
// channel, it is SUPERSEDED by an explicit reviewer record and retired to
// `<run>/review.agent.superseded` (renamed, never deleted) so delivery reads
// the receipt that was actually stamped - assertReviewCurrent prefers
// review.agent and is left byte-unchanged. A stale receipt with NO manual
// record still refuses, unchanged. A completed
// review whose receipt STILL carries no reviewed_ref (a legacy run recorded
// before F8 landed) warns rather than blocks: enforce-when-present, so those
// older runs stay finishable. Historical review.session/review.pane files
// remain cleanup inputs only. The validated object routes `.findings` to
// `findings review` and advisory risk fields to `meta review`.
//
// REVIEW-ROUND CONVERGENCE (the delivery-review skill carries
// the policy, this header the mechanics). Three gates on review-agent:
// - ENTRY: a round opens only with the test step completed this run or a
//   FRESH attestation (attestConditions; a bare --tdd declaration does not
//   qualify) - machine-catchable failures never buy a review round. The
//   8-step order is unchanged; this is a precondition on entering review.
// - POST-PASS FREEZE: a round that returned ZERO `fix` findings (verdict
//   `pass`) FREEZES the tree - its advisory findings are notes for the PR body
//   and the backlog, never a licence to commit - so review-agent REFUSES to
//   re-open while the delta since that reviewed_ref is DECIDABLY the caller's
//   own post-pass commits, naming the ref that passed and the two remedies
//   (land it, or have the chief mint a follow-up task). Decidability is the
//   whole guard (reviewDeltaIsCallerPolish): an unresolvable ref, a
//   rewritten history, upstream commits in the delta, or a failed git call all
//   OPEN the round, because a crewmate jammed after a genuine rebase is a worse
//   failure than one wasted round. The crewmate-side law it enforces is seeded
//   from docs/examples/CREWMATE.md; the bare-SHA receipt re-check that makes a
//   post-pass commit expensive is deliberately untouched.
// - SAME-REF BRAKE: a THIRD invocation on ONE `--ref` within a run HOLDs, ahead
//   of the cap. Two attempts on an unchanged ref already failed, so the next
//   one fails the same way: that is an infrastructure or validator signal, and
//   the cap's remedies (accept the residual, grant a final round) are the wrong
//   advice for it. The refusal names BOTH prior attempts with their outcomes
//   (`ok` / `dead-pane` / `rejected-verdict` / `opened` for one killed
//   mid-flight, from the same invocation ledger the cap counts) plus where to
//   read them: the family's ac-verify round evidence (transcript.jsonl,
//   pane-result.ndjson[.tmp]) resolved through AC_FLEET_STATE, and this run's
//   own rejection lines in logs/run.log.
// - CAP: past review.max_rounds (project yaml, default 3) the loop HOLDs for
//   the OWNING CHIEF's chief-decide. What it COUNTS is verifier INVOCATIONS in
//   this run - rows in <run>/logs/review-invocations.tsv, appended before the
//   verifier runs, so a REJECTED attempt counts too (a dead pane costs the
//   same) - never `step review fixing` ticks: nothing but an explicit call ever
//   ticks that column, so a run whose verdicts needed no fix piled up
//   invocations while the counter read round 1. `review.max_rounds` therefore
//   means invocations per run, and `review-residual` reads the SAME counter, or
//   the release the cap points at would be unreachable. The ROUND NUMBER is a
//   separate count - durable round results (logs/review-agent-rN.json) + 1 - so
//   a rejected round's retry stays the same round while still costing a slot.
//   The `fixing` tick keeps its own consumers (fix-report numbering, auto_fix).
//   `review-residual accept --grounds` turns
//   the remaining fix findings advisory (residual_accepted + grounds on the
//   wire, receipt printed for the room; refused below the cap, refused
//   outright while the residual holds a critical correctness/security/
//   data-loss finding - that carve-out is non-overridable). `review-agent
//   --final-round` grants exactly ONE extra round; the durable
//   <run>/review.final-round marker refuses a second grant.
// - REJECTION TRACE: a verdict this adapter refuses writes ONE line to
//   logs/run.log naming the check that failed (findings shape, HEAD binding,
//   verdict/risk enum, unparseable JSON), and the refused verdict itself is
//   kept at logs/review-agent-rN.json.rejected. The verifier writes the same
//   kind of line on ITS side (src/verify.ts). Before this, a rejected round
//   left no trace of why, so the caller's only move was to re-run the same ref.
//   The facade also gives a reviewer output that fails an ENVELOPE check ONE
//   correction turn before anything reaches this adapter (src/verify.ts,
//   ONE CORRECTION TURN): the corrected object is that round's verdict at the
//   same reviewed_ref, `.correction.failed_check` on the stored result says it
//   happened, and the turn costs no invocation here - the facade returned
//   once. A result this adapter still refuses fails closed exactly as above.
// - FLOOR METADATA: round 2+ passes AC_FINDINGS_ROUND + AC_FINDINGS_DELTA
//   (files changed since the IMMEDIATELY PREVIOUS round's reviewed ref) plus
//   AC_FINDINGS_PRIOR_OPEN (that round's blocking ids) into
//   ac_findings_normalize. Only NEW out-of-delta findings floor; an unresolved
//   previous finding never becomes advisory merely because its file was not in
//   the latest fix delta. The normalizer owns the floor directions
//   (src/lib.ts findingsNormalize, held to its frozen bash original
//   ac_findings_normalize in tests/fixtures/ac-pipeline-lib.sh; src/qa.ts
//   calls it too).
//   A delta name holding a newline cannot ride that newline list, so such a
//   round passes no delta and floors nothing.
//
// Findings JSON (per step):
//   [{"id","severity","action","file","line","description",
//     "authority_class","authority"}]
//   severity: error|warning|info    action: fix|ask-user|no-op
//   authority_class: internal|external|none   authority: one sentence
// `fix` = objective, ASSIGNED to a crewmate fixer (the reviewer never fixes;
// the runner fixes under hold-and-fix, or the orchestrator dispatches a
// fixer via fix-report). A finding with a missing, EMPTY, or unknown action
// (including the retired `auto-fix` alias, which no producer emits) fails
// closed to ask-user - it reaches the captain instead of a fixer.
// `fix` is RESERVED for delivery-blocking findings - correctness, security,
// regression, data loss, accepted-requirement/ruling violation: every fix
// finding forces a fresh fix-and-rereview round, so
// advisory improvements ride as no-op with suggested_fix - recorded in the
// findings and the PR, never looping the pipeline. The reviewer prompt
// (ac-verify.sh) carries the same rule; action stays the ONE loop lever.
// FINDING AUTHORITY (same fail-closed shape, same normalizer): `authority`
// names WHO states the finding's EXPECTED behaviour and WHERE - a file:line,
// a URL, or `captain <date>`; `internal` = stated inside this repo or by the
// diff itself, `external` = an actor outside it. An unknown class or an empty
// `authority` normalizes to `none`, and a `fix` finding with class `none` is
// DOWNGRADED to ask-user with `authority_downgraded: true` - so a statement
// nobody can source reaches the captain instead of a fixer. Only `fix` is
// bound, so a legacy run of no-op/ask-user findings finishes unchanged.
// SEVERITY FLOOR (same normalizer, checked first): a `fix` finding with
// `severity: info` is DOWNGRADED to `no-op` with `severity_floored: true` -
// info means no action required, so it never reopens a review round,
// authority-named or not.
// `meta <step>` records the envelope data the PR body needs (review:
// risk_level/risk_rationale; test: testing_summary/tested/artifacts).
//
// TDD ATTESTATION (attestation by execution - never an honor claim):
// `attest-test` is the implementer's final TDD green run: it RUNS the
// configured commands.test in this worktree (output teed to
// <repo>/.crew/ship/attest-test.log) and, ONLY on exit 0, atomically
// writes <repo>/.crew/ship/attest-test.json {branch, commit: HEAD sha,
// tree: HEAD tree hash, cmd: the exact configured test command, at: ISO,
// duration_s, output_sha256: hash of the log}. A failing run writes
// NOTHING and propagates the command's exit code; a worktree with
// uncommitted changes is REFUSED before anything runs, and a test run
// that itself dirties the tree is REFUSED after it (a mutating suite
// proves nothing about the committed state either way). A worktree state
// that cannot be READ is refused at BOTH points: an unreadable status is
// not evidence of a clean one, and this attestation is what lets the test
// step skip the suite.
// `cmd test` ACCEPTS the attestation - marks the test step completed
// WITHOUT re-running the suite, records empty findings plus a
// testing_summary meta note - only when ALL hold: config test.attestation
// is absent/accept (the literal `ignore` disables it, and any OTHER value
// fails CLOSED: the suite runs, with a warning about the unknown value);
// attest-test.json exists; its branch == the current branch; its commit ==
// the current HEAD; its tree == HEAD's tree; its cmd == the currently-
// configured commands.test; and when output_sha256 is present the log
// still hashes to it. ANY condition failing -> the suite runs exactly as
// before, and the rejection reason is logged when an attestation file
// exists. Hold-and-fix stays consistent by construction: a fix commit
// moves HEAD, the attestation goes STALE, and the reopened test step RUNS
// the suite. Its LIFETIME is the TREE it describes, not the run that
// consumed it: `finish` leaves the file in place, and a leftover from any
// run - finished or abandoned - is honored only while branch/HEAD/tree/cmd
// still match. Retiring it at `finish` would make the chief-verify query
// below structurally dead, since the chief reads it after the run ends.
// TRUST BOUNDARY: the attestation lives in the implementer's own
// worktree - an actor who could forge it has strictly easier lies
// available already; the independent reviewer and crew-qa remain the
// cross-checks.
// `attest-check` is the VERIFIER's freshness query (run-independent, like
// attest-test - including which config it reads: the INSTALLED project
// config, never a run's frozen snapshot, since a query outlives the run):
// it validates the existing attest-test.json against the
// CURRENT tree using the exact acceptance conditions above (ONE
// implementation, attestConditions, shared with `cmd test`) and prints
// `attested: fresh @<short-sha> (<cmd>)` exit 0, `stale: <why>` exit 1,
// or `no attestation` exit 2. It is NOT gated by test.attestation - that
// key only governs the pipeline's auto-accept, and a query never skips
// anything by itself. Chief-verify usage: a verifier (roomchief or
// crewchief) runs attest-check in the delivered worktree; FRESH means the
// implementer's green run already covers this exact tree - do NOT re-run
// the suite; anything else -> run it. A rebase or fix commit moves HEAD
// and stales the attestation automatically.
//
// SHIP TEST RECEIPT (authoritative - every other mention points HERE by name):
// unit-suite health is the ship pipeline's business EXCLUSIVELY, and a QA round
// may only READ it (QA boundary policy: QA never executes or
// re-runs unit tests). `cmd test` therefore publishes ONE run-scoped receipt at
// <repo>/.crew/ship/<run>/test/receipt.env, schema
// agentcrew.ship-test-receipt/v1, atomically:
//   BEFORE the command runs, any prior receipt is replaced with
//   `not-qualifies:incomplete` - so a second attempt, an interruption, or a
//   crash can never leave an earlier success current for a later QA freeze;
//   a zero-exit managed execution then replaces it with
//   `qualifies:executed`, a non-zero one with `not-qualifies:non-zero`, and an
//   ACCEPTED attestation with `qualifies:execution-attestation` carrying the
//   attestation's own exact execution identity (command hash, output hash, and
//   the append-only started_at/completed_at pair attest-test now records).
// The receipt is keyed to `git rev-parse HEAD` at write time; a QA round freezes
// it by exact run id and target SHA, never through the mutable `current`
// symlink. Declaration-only `--tdd`, a plain `step test completed`, and legacy
// run metadata create NO receipt - they are claims, and the whole point of the
// receipt is that it is an execution record. qaShipReceiptStatus
// (src/qa-lib.ts, held to ac_qa_ship_receipt_status in
// tests/fixtures/ac-qa-lib.sh) is
// the ONE reader that decides whether a receipt qualifies; this
// module only writes what actually happened.
//
// PUSH INCORPORATION (authoritative - the guard's exact shape):
// `push` refuses to force-push over remote commits this branch has not
// incorporated, computed by patch-id
// (`rev-list --cherry-pick --right-only HEAD...<remote> ^<fresh_base>`).
// That check alone had NO LEGAL PATH for the most ordinary step of a multi-PR
// chain: resolving a conflict during a rebase REWRITES that commit's diff, so
// its patch-id changes, --cherry-pick stops cancelling the pre-rebase commit,
// and the branch's own superseded history reads as foreign remote work. A clean
// rebase preserves the patch-id and was never affected. Measured cost: chiefs
// approving manual force-push-with-lease to do the routine thing - a guard that
// is routinely bypassed is no longer a guard.
// THE EXCUSE, and its exact bound: a non-empty unincorporated set is excused
// ONLY when `<remote>` is BYTE-IDENTICAL to a sha THIS command published for
// THIS branch, recorded in <repo>/.crew/ship/pushed.tsv (`<branch>\t<sha>`,
// appended after each push actually lands, run-independent like
// attest-test.json because a chain rebases in run N+1 over what run N pushed).
// Equality, not ancestry: it is the tightest statement of "nothing has touched
// the ref since we published it", and it avoids merge-base --is-ancestor's
// conflation of 1 (not an ancestor) with 128 (unreadable sha).
// It is NOT an operator declaration and cannot be minted by timing: the only way
// to be excused is to have pushed that sha through this command, so anything
// ANOTHER actor pushed moves the ref off every published sha and is still
// refused - whether or not this branch ever held it locally. The lease
// (--force-with-lease=<ref>:<remote>) re-verifies the same sha at write time.
// Everything else is unchanged: the lease, the detached-HEAD refusal, the
// default-branch and delivery-target refusals, and the fail-closed remote read.
// FAILS CLOSED, one push at a time: a branch whose current head this pipeline
// never published (a first push after this landed, a fresh worktree lease, a
// hand-rolled push) is refused exactly as before, and the next pipeline push
// records it.
// RESIDUAL, stated rather than hidden: the excuse also lets the pipeline
// republish over ITS OWN previously published commits that the rebase DROPPED
// (`rebase --skip`, an abandoned `reset --hard`). No git primitive distinguishes
// "conflict-resolved" from "dropped" - both are "the old patch is not in the new
// history" - so closing it needs a fuzzy matcher (commit-subject or range-diff),
// which is not a safety boundary worth building.
// The excuse keys ONLY on a sha this pipeline published, and never on one only
// another actor pushed - but "published" INCLUDES another actor's commit once we
// incorporated it and pushed a head containing it. From that moment dropping it
// falls inside this residual too (reproduced), so the bound is on the sha's
// provenance, not on whose work the commit was.
//
// FINISH - FAIL CLOSED (checks-passed|passed only): `finish` REFUSES to mint a
// validated outcome for a fresh or incomplete run (the proven bypass was `start`
// then `finish checks-passed`, minting a passed run with zero steps done). It
// gates on the EXISTING step + finding state - no new state machine:
//   1. every pipeline step that was NOT user-skipped must be `completed`; any
//      pending/running/fixing/awaiting_approval/failed step is NAMED and finish
//      dies (skip-remaining's skips count as skipped, so an empty-diff run
//      still finishes);
//   2. no unresolved finding may remain across findings/<step>.json - any `fix`
//      finding (resolution is the reviewer's re-run dropping it, never an
//      in-place flag - machine-held for the review step specifically: `findings`
//      refuses a plain re-post that drops a recorded `fix` finding, F9), or any
//      `ask-user` finding without a recorded captain `decision`, is NAMED and blocks;
//   3. a COMPLETED review must still cover HEAD (assertReviewCurrent): the
//      reviewed_ref on the receipt is re-compared here, so a fix commit landing
//      after the review transition cannot be recorded as validated. A `skipped`
//      review, or a receipt carrying no reviewed_ref, does not block (the
//      latter warns);
//   4. the documented checks-passed vs passed split is enforced -
//      checks-passed = validated but UNMERGED (the crew's stop
//      point; needs 1+2+3 only), passed = MERGED and so ADDITIONALLY requires
//      merged evidence: HEAD reachable from the run's delivery target (the
//      default ref, ac_default_ref, when no --target was pinned).
//      A squash merge rewrites history and is not an ancestor, so `passed` then
//      fails CLOSED - use checks-passed; the merge helpers own the merge record.
// failed and cancelled are ALWAYS allowed - a crew must never be trapped unable
// to record a failure. The merge helpers (ac-pr-merge, ac-merge-local) stay
// consistent by construction: they act on a real PR / crew branch that exists
// only once a genuine run reached this gate, so a run that never reached
// checks-passed has nothing for them to merge.
//
// OVERRIDE MARKER (authoritative): an APPROVED failure is attested as
// passed-with-override, never as clean green. Two releases let a run finish
// without the evidence the step exists for - `review-residual accept` (the
// residual fix findings rewritten advisory on the chief's receipt) and `--tdd`
// (the test step declared, not run) - and before this marker nothing
// machine-readable told such a run from a clean one: residual_accepted lived
// on individual findings the finish gate reads only for `action`, a --tdd
// run's steps.tsv was byte-identical to `--skip test`, run.meta took the same
// outcome=checks-passed, the PR body's meta inputs (findings/review.meta.json,
// findings/test.meta.json) were written before the acceptance or not at all,
// attest-check is run-independent, and ac-pr-check/ac-pr-merge/ac-merge-local/
// ac-teardown read no ship run state at all. ONE marker on the run state now
// carries it: <run>/override, one row per kind - `kind<TAB>at<TAB>
// receipt_sha256<TAB>reason` - written at the moment of acceptance (kind
// review-residual: the sha of the SELF-APPROVED receipt line + the grounds;
// kind tdd-declared: the sha of the start note + the declaration), CLEARED when
// the evidence it stands in for arrives - a fresh review round (review-agent,
// the residual is re-judged) drops review-residual, the test step reaching
// `completed` drops tdd-declared. A config change cannot stale it: a run's
// config is frozen at start. Every receipt a reader gates on COPIES it rather
// than reading green: `status` prints the rows, `finish checks-passed|passed`
// appends `attestation=passed-with-override:<kinds>` beside outcome= in
// run.meta and suffixes both its stdout line and the chief-facing
// `checks-passed:` marker, and the live dashboard colours the run yellow.
// The PR body's attestation line carries it verbatim (the crew-ship skill
// owns that wording); the marker never BLOCKS finish - the acceptance IS the
// sanctioned release - it only refuses to let it read as clean.
//
// Config, HOME-ONLY (resolver: ac-lib.sh ac_project_config_file, twinned by
// src/lib.ts projectConfigFile; the values are read by ac_yaml_get's awk program,
// spawned through src/lib.ts yamlGet):
// $AC_HOME/projects/<name>.yaml is captain-owned and branch-immune.
// The project repo is never a config source.
// Keys: commands.{test,lint,format}, commands.test-changed (see SCOPED TEST),
// auto_fix.<step>,
// ignore_patterns, document.instructions, test.evidence.{store_in_repo,dir},
// test.attestation (accept|ignore, default accept - see TDD ATTESTATION),
// test.base_attribution (on|off, default off - see BASE ATTRIBUTION).
// `cmd` exit codes: the command's own code; 4 = no command configured.
// `start` FREEZE: trusts AC_FLEET_HOME_CHECKED/AC_FLEET_PROJECT_CONFIG (threaded
// by ac-spawn.sh, which resolved the file with a real AC_HOME) over its own
// bare ac_project_config_file when present, else resolves normally under a
// real AC_HOME, else REFUSES - a homeless, unchecked caller freezing an empty
// config would be indistinguishable from a project verified to have none,
// silently dropping any key the captain pinned (ship-config-and-know-citation-
// blind-spots). attest-test, attest-check and a pre-run `config` read trust the
// same handover (homeConfigFile); with neither signal, or a threaded file
// since deleted, they report no config instead of refusing, so no attestation
// is written or honoured and the suite runs.
//
// SCOPED TEST (prefer changed-file tests over the
// full suite): commands.test-changed is an OPT-IN per-project command template
// that MUST carry a {files} placeholder (refused loud otherwise); `cmd test`
// replaces it with the shell-quoted base-to-HEAD changed set (same recomputed
// fresh_base as review, deletions excluded) and runs it INSTEAD of the full
// commands.test. Precedence inside `cmd test`: a fresh TDD attestation is
// accepted first (a full green run beats everything and stays qualifying);
// then the scoped run when the key is set and the changed set is non-empty;
// the full suite remains the fallback (no key, or an empty changed set -
// failing toward running). Fix commits extend base..HEAD, so the fix-reopen
// re-run scopes to them automatically. EVIDENCE HONESTY: a scoped green
// completes the test step but its receipt says `not-qualifies:scoped` - a
// partial run is pipeline evidence, never suite proof, so QA's UT bridge
// escalates instead of freezing it; full-suite evidence remains attest-test
// or the full commands.test run.
//
// BASE ATTRIBUTION (opt-in test.base_attribution: on): when the FULL
// commands.test fails, `cmd test` re-runs it on the run's fresh_base in a
// throwaway detached worktree (<run>/base-tree, removed after) and prints one
// `base attribution:` line - the base passes (this change broke it) or also
// fails (exit N) - with the base run's output in logs/test-base.log and a
// run.log row. A hand-made "pre-existing failure" claim was measured wrong
// before; this makes it a measurement. It never changes the step: the exit is
// the HEAD run's. A scoped run is not re-run (its file list may not exist on
// the base), and a base checkout carries no untracked setup, so "also fails"
// is evidence to read, not a verdict.
//
// EVERY CALL, in order: the backend name is checked first (an AC_BACKEND or
// config/backend that is neither herdr nor orca refuses, before usage and the
// repo); git and jq must be on PATH; the repo is the caller's cwd's
// `git rev-parse --show-toplevel` (else `ERROR: not inside a git repo`, before
// the verb is read); no verb, `-h` or an unknown verb print this header on
// stdout, exit 2. Every verb but start, attest-test, attest-check, base and
// config needs a run (`current` a symlink, checked before the verb's own
// arguments). Every refusal is `ERROR: <text>` on stderr, exit 1; warnings are
// `WARN: <text>`. stdin is read only by findings and meta (the suite, the
// verifier, git and herdr inherit it).
// The mechanics stay the original's by spawning what it ran at the same points:
// every jq program verbatim (each document's bytes are jq's), git, mktemp beside
// each file it stages, mv, cp, ln -sfn, mkdir -p, sed and awk over the run's own
// files, `sleep` for the ledger lock's waits, date(1) for every stamp and the run
// id, herdr. A suite runs as the original's own pipeline -
// `( cd <repo> && sh -c <cmd> ) 2>&1 | tee <log>` - inside /bin/bash --posix,
// its exit the left side's (128+n for a signal); the base attribution runs
// `sh -c <cmd>` in the base tree into its log. A --skip word holding a pattern
// character is expanded by /bin/bash against the caller's cwd, as the shell's
// word splitting and globbing did. A failure the original's errexit ended the run
// on ends it here with the failing command's status; inside the test
// attestation's acceptance, which the original ran as an `if` condition, those
// failures are passed over as they were there.
//
// EXIT: 0; 1 every refusal; 2 the usage header, attest-check's `no attestation`,
// and a yaml read awk aborted (W10); 4 no config or no command (cmd,
// attest-test); the suite's own status (cmd, attest-test); 128 git's status where
// a git read the original's errexit ended on failed (W13); 128+n when a signal
// ends the process - no handler is registered, so TERM (143) and HUP (129) end it
// at once while the suite, the verifier or git runs, the child orphaned and
// finishing on its own (W2).
//
// ESCAPE HATCH. A broken port stops every lab money-path delivery at its first
// `start` (and the step, push and finish of runs in flight) and chiefs'
// attest-check. If a landed change breaks this module, run the frozen original
// from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-ship.sh "$o/bin/ac-ship.sh"
//   cp tests/fixtures/ac-qa-lib.sh tests/fixtures/ac-pipeline-lib.sh "$o/bin/"
// then the crewmate (through its chief) runs "$o/bin/ac-ship.sh" <verb> from its
// worktree. The copy reaches its own ac-verify.sh, ac-pane-agent.sh and
// ac-ship-watch.sh siblings and writes the same run-dir formats, so a run can
// switch implementations mid-pipeline (the leg's continuation rows pin it); it
// bakes only the board's launch path ("$o/bin/ac-ship-watch.sh", typed into a
// pane). The captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W2: a TERM to the pid alone while the verifier runs leaves the verifier's
//   RAW result as a durable round with nothing else written - the next round on
//   that HEAD refuses `already reviewed`, review completed has no evidence and
//   review-residual finds no findings, until a new commit.
// - W3: a RETIRED legacy <home>/config/projects/<name>.yaml prints its refusal
//   and start freezes an EMPTY config (attest-test, config and cmd read none).
// - W4: the finish gate passes a 0-byte or `{}` findings file and an empty
//   steps.tsv.
// - W5: the F9 drop guard compares fix ids with `.id // "?"`, so two id-less
//   fix findings re-posted as one pass.
// - W6: any pane labelled ac-ship-watch anywhere in the herdr session
//   suppresses this run's board.
// - W7: push's ls-remote, fetch and push carry no time bound.
// - W8: the normalizer reads AC_FINDINGS_ROUND/DELTA/PRIOR_OPEN from the
//   environment, so inherited values floor a plain post.
// - W10: an invalid byte in a yaml value at or before the key aborts the reader
//   under a UTF-8 locale - config and cmd exit 2, review-agent's cap read falls
//   back to 3.
// - W13: cmd test with commands.test-changed and a merge-base that fails prints
//   fresh_base's refusal, then git's own `ambiguous argument ''` and exits 128,
//   the receipt left `incomplete`.
// - W15: ls-remote matches a ref's tail, so origin's
//   refs/heads/x/refs/heads/<b> reads as <b>: an up-to-date that never pushed, or
//   two shas the incorporation check cannot read.
// - W16: the board's launch line single-quotes the bin and repo paths raw.
// - W17: a dangling `current` passes the run check: status prints its run line
//   then sed's own error, step and skip-remaining wait the lock out, finish dies
//   on its run.meta append.
// - W18: a homeless query prints ac_home's ERROR beside its answer (attest-check,
//   attest-test, config, and start's two lines).
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every verb needs bun now (the shim's `ERROR: required tool not
//   found: bun`, exit 1, before anything), where the original ran without it.
// - USAGE HEADER: the usage is this header; the original printed its own.
// - W9: the review-agent caller grammar is read per its text (a-z, 0-9, -),
//   where bash 3.2's bracket ranges under a UTF-8 locale admitted an uppercase
//   or accented letter.
// - W11 and BYTES: the override reason's tabs and newlines become spaces and
//   every other byte is kept, where the original's `tr` under a UTF-8 locale cut
//   the reason at an invalid byte (`tr: Illegal byte sequence`); argv and the
//   environment arrive decoded, so a byte that is no UTF-8 in a flag, the intent
//   or an env value reaches the run's files and children as U+FFFD, and a config
//   value's reaches the suite's `sh -c` so (its `$ <cmd>` line and digest keep the
//   bytes).
// - W12 EXCLUSIVE TEMPS: the invocation ledger's outcome rewrite goes through
//   logs/review-invocations.tsv.tmp.<pid> (then .<n>) created exclusively, where
//   the original wrote through whatever sat at the predictable `.tmp` - a link
//   planted there had its target overwritten and the ledger became the link.
// - TRUSTED RE-POST: only review-agent's own call skips the F9 drop guard, where
//   the original's guard also read `_ac_findings_trusted=1` from the caller's
//   environment - so an exported one let a plain re-post drop a fix finding.
// - W14: a push refused over unincorporated commits prints the header, the
//   first ten shas and the refusal, exit 1, where the original's
//   `printf | head -10` died of SIGPIPE past the pipe buffer (141, no refusal).
// - W19: SIGINT to the pid alone ends the process at once (130), the suite
//   finishing on its own, where the original waited its foreground child out
//   and completed.
// - W20 and SHELL-OWN STDERR are not reproduced, the status kept: a value flag
//   as start's last word (`$2: unbound variable`), config with no key and a
//   config present (`1: dotted key required`), a step listed twice in fix-report
//   (`$((rounds + 1))`'s arithmetic error), a dangling finish's redirection line,
//   `[: <n>: integer expression expected`, and the `Terminated` notice a
//   signalled suite leaves in its log and on stdout names the port's helper
//   shell (`ac-ship.sh: line 1:`), so that log's digest differs.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is
//   `ERROR: AC_HOME is not a readable directory: <h>` where the original printed
//   cd's own line; both go on with no config.
// - git or jq on PATH as a file that is not executable is `required tool not
//   found` (Bun.which), where the original's `command -v` accepted it.
// - The default verifier and pane agent are <this distro's bin>/ac-verify.sh
//   and ac-pane-agent.sh by absolute path, where the original joined a relative
//   `$0`'s dirname.
// - The board sweep's `tab close` calls read /dev/null, where the original's
//   read the rest of its loop's jq pipe.
//
// CALLERS: the execution crewmate through the crew-ship skill (start, step,
// findings, meta, cmd, base, skip-remaining, review-agent, push, evidence-dir,
// status, finish, fix-report); chiefs verifying a delivered tree (attest-check)
// and releasing a capped review (review-residual accept); harness smoke tests by
// hand; tests/sh/ac-ship.test.sh. No `set -e` script runs it. What it WRITES is
// read by src/ship-watch.ts and src/watch-dash.ts (run.meta, steps.tsv,
// findings, override, logs/run.log, `current`), src/crew-state.ts (steps.tsv),
// src/teardown.ts (run.meta's branch=, review.pane, watch.pane), bin/ac-watch.sh
// (findings/review.json), src/qa.ts (test/receipt.env through
// qaShipReceiptStatus) and the watcher and wake drain (the `checks-passed:`
// marker through AC_CAPTAIN_RE).

import { accessSync, appendFileSync, closeSync, constants as fsc, lstatSync, openSync, readFileSync, readSync, readdirSync, readlinkSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { isatty } from "node:tty";
import {
  STARTED_BIN,
  arithValue,
  backendName,
  commandV,
  configReadSoft,
  defaultBranch,
  defaultRef,
  die,
  enterCaller,
  exclusiveTemp,
  findingsNormalize,
  findingsSummary,
  herdrResolveWorkspace,
  herdrTabOpen,
  lockAcquire,
  lockRelease,
  projectConfigFile,
  require,
  shellStatus,
  spawnShellSync,
  testInt,
  warn,
  windowFamily,
  writeAll,
  wsFamilyLabel,
  yamlGet,
} from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv, the
// environment and the lib's UTF-8 paths cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const B = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const cap = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
const firstLine = (s: string): string => {
  const i = s.indexOf("\n");
  return i < 0 ? s : s.slice(0, i);
};
const lastLine = (s: string): string => {
  const l = s.split("\n");
  if (l.length > 1 && l[l.length - 1] === "") l.pop();
  return l[l.length - 1] ?? "";
};
const basename = (p: string): string => {
  const t = p.replace(/\/+$/, "");
  return t === "" ? (p === "" ? "" : "/") : t.slice(t.lastIndexOf("/") + 1);
};

type Exit = { exit: number };
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};
const fail = (msg: string): never => die(B(msg));
const say = (s: string): void => writeAll(1, B(s));
const tell = (s: string): void => writeAll(2, B(s));

// errexit: a failed command ends the run with its status - except inside
// attest_accept, which the original called as an `if` condition, where
// errexit sleeps for it and everything it calls.
let soft = false;
const ee = (status: number): void => {
  if (status !== 0 && !soft) fatal(status);
};

type Io = "inherit" | "ignore" | "pipe" | number;
type Ran = { status: number; out: string };
function run(argv: string[], o: { stdin?: "inherit" | "ignore" | Buffer; stdout?: Io; stderr?: Io; cwd?: string } = {}): Ran {
  const stdout = o.stdout ?? "pipe";
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv.map(u8), { stdin: o.stdin ?? "inherit", stdout, stderr: o.stderr ?? "inherit", ...(o.cwd === undefined ? {} : { cwd: u8(o.cwd) }) });
  } catch {}
  return { status: shellStatus(r), out: r && stdout === "pipe" ? Buffer.from(r.stdout).toString("latin1") : "" };
}

let repo = "";
let vdir = "";
let current = "";
let binDir = "";
const git = (args: string[], o: Parameters<typeof run>[1] = {}): Ran => run(["git", "-C", repo, ...args], o);
// `x="$(git ...)"`: errexit on its status.
const gitA = (args: string[]): string => {
  const r = git(args);
  ee(r.status);
  return cap(r.out);
};

const stat = (p: string, follow = true) => {
  try {
    return follow ? statSync(B(p)) : lstatSync(B(p));
  } catch {
    return null;
  }
};
const isLink = (p: string): boolean => stat(p, false)?.isSymbolicLink() ?? false;
const isFile = (p: string): boolean => stat(p)?.isFile() ?? false;
const isDir = (p: string): boolean => stat(p)?.isDirectory() ?? false;
const exists = (p: string): boolean => stat(p) !== null;
const nonEmpty = (p: string): boolean => (stat(p)?.size ?? 0) > 0;
const can = (p: string, mode: number): boolean => {
  try {
    accessSync(B(p), mode);
    return true;
  } catch {
    return false;
  }
};
const readLink = (p: string): string | null => {
  try {
    return readlinkSync(B(p), { encoding: "buffer" }).toString("latin1");
  } catch {
    return null;
  }
};
const readText = (p: string): string | null => {
  try {
    return readFileSync(B(p)).toString("latin1");
  } catch {
    return null;
  }
};
// `>` and `>>`: a redirection that cannot open is the command's failure.
const put = (p: string, s: string, flag = "w"): number => {
  try {
    writeFileSync(B(p), B(s), { flag });
    return 0;
  } catch {
    return 1;
  }
};
const append = (p: string, s: string): number => {
  try {
    appendFileSync(B(p), B(s));
    return 0;
  } catch {
    return 1;
  }
};
const rm = (p: string): void => {
  try {
    rmSync(B(p), { force: true });
  } catch {}
};
const mv = (from: string, to: string): number => run(["mv", from, to], { stdout: "inherit" }).status;
const mktemp = (template: string): { status: number; path: string } => {
  const r = run(["mktemp", template]);
  return { status: r.status, path: cap(r.out) };
};
const sha = (s: string): string => createHash("sha256").update(B(s)).digest("hex");
const shaFile = (p: string): string | null => {
  try {
    return createHash("sha256").update(readFileSync(B(p))).digest("hex");
  } catch {
    return null;
  }
};
// <args> of a command whose stdout the bash redirected into <file>: the
// redirection opens first, and a file it cannot open fails the command.
function runTo(argv: string[], file: string, stdin: "inherit" | Buffer = "inherit"): number {
  let fd: number;
  try {
    fd = openSync(B(file), "w");
  } catch {
    return 1;
  }
  try {
    return run(argv, { stdin, stdout: fd }).status;
  } finally {
    closeSync(fd);
  }
}
// ac_iso: `$(ac_iso)` inside a command's arguments is an empty stamp when
// date fails; `x="$(ac_iso)"` ends the run there (isoA).
const isoRun = (): Ran => run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"]);
const iso = (): string => cap(isoRun().out);
const isoA = (): string => {
  const r = isoRun();
  ee(r.status);
  return cap(r.out);
};
// The PATH's sleep, so a test's stub fast-forwards the lock wait.
const sleepOne = (): void => {
  run(["sleep", "1"], { stdout: "inherit" });
};
// `sed -n '<script>' <file> | head -n 1` as `$(...)` read it, and the
// pipeline's status under pipefail.
function sedFirst(file: string, script: string, stderr: Io = "inherit"): Ran {
  const r = run(["sed", "-n", script, file], { stderr });
  return { status: r.status, out: cap(firstLine(r.out)) };
}
// `$(cat)` of stdin.
function readStdin(): Buffer {
  const parts: Buffer[] = [];
  const chunk = Buffer.alloc(65536);
  for (;;) {
    let n: number;
    try {
      n = readSync(0, chunk, 0, chunk.length, null);
    } catch (e) {
      if ((e as { code?: string }).code === "EAGAIN") {
        Bun.sleepSync(5);
        continue;
      }
      if ((e as { code?: string }).code === "EOF") break;
      return fatal(1);
    }
    if (n === 0) break;
    parts.push(Buffer.from(chunk.subarray(0, n)));
  }
  return Buffer.concat(parts);
}
// A here-string's stdin: `<<<"$x"` is x and one LF.
const here = (s: string): Buffer => B(`${s}\n`);

const STEPS = "intent rebase review test document lint push pr";
const STATUSES = "pending running fixing awaiting_approval completed skipped failed";
// `case " $LIST " in *" $w "*)`: a quoted word inside the pattern, so a word
// holding a space matches any run of listed names.
const listed = (list: string, w: string): boolean => ` ${list} `.includes(` ${w} `);

function requireRun(): void {
  if (!isLink(current)) fail("no active crew-ship run; ac-ship.sh start first");
}

function runDir(): string {
  const t = readLink(current);
  if (t === null) fail("broken current symlink");
  return cap(`${vdir}/${cap(t!)}`);
}

// home_config_file: the handover ac-spawn.sh threads, else the home's own
// resolution; null where the bash returned 1. `quiet` is a caller's
// `2>/dev/null`.
function homeConfigFile(quiet = false): string | null {
  if (process.env.AC_FLEET_HOME_CHECKED) {
    const p = process.env.AC_FLEET_PROJECT_CONFIG;
    return p ? cap(b8(p)) : null;
  }
  return projectConfigFile(u8(repo), quiet);
}

// config_file: the run's frozen snapshot when non-empty (an empty one is no
// config), else the installed config.
function configFile(quiet = false): string | null {
  if (isLink(current)) {
    const rd = runDir();
    if (nonEmpty(`${rd}/config.yaml`)) return `${rd}/config.yaml`;
    if (isFile(`${rd}/config.yaml`)) return null;
  }
  const cf = homeConfigFile(quiet);
  return cf !== null && isFile(cf) ? cf : null;
}

// `x="$(ac_yaml_get <cf> <key>)"` under errexit.
function yamlA(cf: string, key: string): string {
  const r = yamlGet(cf, key);
  ee(r.status);
  return cap(r.out);
}

// fresh_base: the merge-base against the run's target, else the default
// ref, or null once its refusal is printed - a `$(...)` caller's subshell
// ended there. `top` is the one call outside a substitution (the base verb),
// where a failed target read ended the run.
function freshBase(explicit = "", top = false): string | null {
  let ref = explicit;
  if (ref === "") {
    const t = readLink(current);
    if (t !== null) {
      const r = sedFirst(`${vdir}/${cap(t)}/run.meta`, "s/^target=//p", "ignore");
      if (top) ee(r.status);
      ref = r.out;
    }
  }
  if (ref === "") ref = b8(defaultRef(u8(repo), true));
  const m = git(["merge-base", ref, "HEAD"], { stderr: "ignore" });
  if (m.status !== 0) {
    tell(`ERROR: fresh_base: merge-base against '${ref}' failed - refusing to fall back to HEAD\n`);
    return null;
  }
  return cap(m.out);
}

function ensureCrewExcluded(): void {
  const c = git(["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  let ok = c.status === 0;
  if (ok) {
    const common = cap(c.out);
    ok = run(["mkdir", "-p", `${common}/info`], { stdout: "inherit" }).status === 0;
    if (ok && !(readText(`${common}/info/exclude`) ?? "").split("\n").includes(".crew/")) ok = append(`${common}/info/exclude`, ".crew/\n") === 0;
  }
  if (!ok) warn("could not add .crew/ to info/exclude - it stays visible in git status");
}

function overrideNote(rd: string, kind: string, receipt: string, reason: string): void {
  ee(append(`${rd}/override`, `${kind}\t${iso()}\t${sha(receipt)}\t${reason.replace(/[\t\n]/g, " ")}\n`));
}

function overrideClear(rd: string, kind: string): void {
  const f = `${rd}/override`;
  if (!isFile(f)) return;
  const m = mktemp(`${f}.XXXXXX`);
  if (m.status !== 0) fail("override: mktemp failed");
  if (runTo(["awk", "-F\\t", "-v", `k=${kind}`, "$1 != k", f], m.path) !== 0) {
    rm(m.path);
    fail(`override: could not rewrite ${f} - failing closed`);
  }
  if (nonEmpty(m.path)) ee(mv(m.path, f));
  else {
    rm(m.path);
    rm(f);
  }
}

function overrideKinds(rd: string): string {
  const f = `${rd}/override`;
  if (!isFile(f)) return "";
  const c = run(["cut", "-f1", f]);
  const p = run(["paste", "-sd,", "-"], { stdin: B(c.out) });
  ee(p.status !== 0 ? p.status : c.status);
  return cap(p.out);
}

// --- start ------------------------------------------------------------------

// `for tok in ${skip//,/ }`: split on the default IFS and, for a word that
// holds a pattern character, expanded against the caller's cwd as the shell
// expanded it - by bash itself, so its globbing and collation are the same.
function skipWords(skip: string): string[] {
  const spaced = skip.replaceAll(",", " ");
  if (!/[*?[]/.test(spaced)) return spaced.split(/[ \t\n]+/).filter((w) => w !== "");
  const r = run(["/bin/bash", "-c", 'for w in $1; do printf "%s\\0" "$w"; done', "bash", spaced]);
  ee(r.status);
  return r.out.split("\0").slice(0, -1);
}

function resolveTarget(t: string): string {
  if (git(["show-ref", "--verify", "--quiet", `refs/remotes/origin/${t}`]).status === 0) return `origin/${t}`;
  if (git(["show-ref", "--verify", "--quiet", `refs/heads/${t}`]).status === 0) return t;
  return fail(`start: --target branch not found (neither origin/${t} nor ${t}): ${t}`);
}

function cmdStart(a: string[]): void {
  let intent = "";
  let skip = "";
  let targetIn = "";
  let tref = "";
  let wantLint = false;
  let tdd = false;
  for (let i = 0; i < a.length; ) {
    const w = a[i]!;
    if (w === "--intent" || w === "--skip" || w === "--target") {
      // `$2: unbound variable` (set -u): its text is the shell's own.
      if (i + 1 >= a.length) fatal(1);
      if (w === "--intent") intent = a[i + 1]!;
      else if (w === "--skip") skip = a[i + 1]!;
      else targetIn = a[i + 1]!;
      i += 2;
    } else if (w === "--lint") {
      wantLint = true;
      i++;
    } else if (w === "--tdd") {
      tdd = true;
      i++;
    } else fail(`unknown flag: ${w}`);
  }
  if (targetIn !== "") tref = resolveTarget(targetIn);
  if (intent === "") fail("--intent is required (pass the captain's goal verbatim)");
  if (skip !== "")
    for (const tok of skipWords(skip)) {
      if (!listed(STEPS, tok)) fail(`unknown --skip step: ${tok}`);
      if (tok === "intent" || tok === "review")
        fail(`--skip ${tok} is refused: ${tok} can never be skipped (the intent-evidence pass is never skipped; crew-ship review is always required, AGENTS.md section 5)`);
    }

  let configSource = "";
  const hc = homeConfigFile();
  if (hc !== null) {
    if (!isFile(hc)) fail(`AC_FLEET_PROJECT_CONFIG names a missing file: ${hc}`);
    if (!can(hc, fsc.R_OK)) fail(`the project's pipeline config is unreadable: ${hc}`);
    configSource = hc;
  } else if (!process.env.AC_FLEET_HOME_CHECKED && !process.env.AC_HOME)
    fail(
      "cannot resolve the project's pipeline config: AC_HOME is unset and no AC_FLEET_PROJECT_CONFIG was threaded by ac-spawn.sh - freezing an empty config here would be indistinguishable from a project that genuinely has none installed, silently dropping any captain-pinned key. Re-spawn through bin/ac-spawn.sh (it resolves this with a real AC_HOME and hands the answer over), or export AC_HOME before running start directly.",
    );
  const sr = git(["symbolic-ref", "--short", "HEAD"], { stderr: "ignore" });
  const branch = cap(sr.status === 0 ? sr.out : `${sr.out}DETACHED`);
  const base = freshBase(tref || b8(defaultRef(u8(repo), true))) ?? fatal(1);

  // Every refusal sits above this line, so a refused start creates nothing.
  const d = run(["date", "+%Y%m%d-%H%M%S"]);
  ee(d.status);
  const id = `${cap(d.out)}-${process.pid}`;
  const rd = `${vdir}/${id}`;
  ee(run(["mkdir", "-p", `${rd}/logs`, `${rd}/findings`], { stdout: "inherit" }).status);
  ensureCrewExcluded();
  if (configSource !== "") ee(run(["cp", configSource, `${rd}/config.yaml`], { stdout: "inherit" }).status);
  else ee(put(`${rd}/config.yaml`, ""));
  const configSha = shaFile(`${rd}/config.yaml`) ?? fatal(1);
  ee(put(`${rd}/intent`, `${intent}\n`));
  ee(
    put(
      `${rd}/run.meta`,
      `intent=${firstLine(intent)}\nbranch=${branch}\nbase=${base}\n${tref ? `target=${tref}\n` : ""}config_source=${configSource || "none"}\nconfig_sha256=${configSha}\ncreated_at=${iso()}\noutcome=running\n`,
    ),
  );
  let tsv = "";
  for (const s of STEPS.split(" ")) {
    let st = "pending";
    if (s === "lint" && !wantLint) st = "skipped";
    if (s === "test" && tdd) st = "skipped";
    if (`,${skip},`.includes(`,${s},`)) st = "skipped";
    tsv += `${s}\t${st}\t0\n`;
  }
  ee(put(`${rd}/steps.tsv`, tsv));
  ee(run(["ln", "-sfn", id, current], { stdout: "inherit" }).status);
  watchOpen(rd, branch);
  const startline = cap(
    `started run ${id} branch=${branch} base=${base.slice(0, 12)}${tref ? ` target=${tref}` : ""}${wantLint ? "" : " (lint skip-by-default: pass --lint to run it)"}${tdd ? " (test skipped: --tdd declares the implement covered it)" : ""}`,
  );
  if (tdd) overrideNote(rd, "tdd-declared", startline, "test step declared by --tdd, suite not run by this pipeline");
  say(`${startline}\n`);
}

// The live board, a herdr tab: never fails the caller.
function watchOpen(rd: string, branch: string): void {
  if ((process.env.AC_SHIP_WATCH || "auto") === "off") return;
  if (backendName() !== "herdr") return;
  if (!commandV("herdr")) return;
  const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
  if (run(["herdr", "--session", ses, "pane", "list"], { stderr: "ignore" }).out.includes('"label":"ac-ship-watch"')) return;
  const label = `ac-ship-watch-${branch.replaceAll("/", "-")}`;
  const ws = herdrResolveWorkspace(wsFamilyLabel(b8(windowFamily(u8(branch.startsWith("crew/") ? branch.slice(5) : branch)))), true) ?? "";
  const opened = herdrTabOpen(ses, label, repo, ws);
  if (opened === null) return;
  const p = opened.split(" ")[0]!;
  run(["herdr", "--session", ses, "pane", "rename", p, "ac-ship-watch"], { stdout: "ignore", stderr: "ignore" });
  run(["herdr", "--session", ses, "pane", "run", p, `'${binDir}/ac-ship-watch.sh' --repo '${repo}' --self-pane ${p}`], { stdout: "ignore", stderr: "ignore" });
  ee(put(`${rd}/watch.pane`, `${p}\n`));
  if (ws === "") return;
  const tabs = run(["herdr", "--session", ses, "tab", "list"], { stderr: "ignore" });
  const ids = run(["jq", "-r", "--arg", "ws", ws, '.result.tabs[]? | select(.workspace_id == $ws and .label == "1") | .tab_id'], { stdin: B(tabs.out), stderr: "ignore" });
  for (const l of ids.out.split("\n").slice(0, -1))
    run(["herdr", "--session", ses, "tab", "close", l.replace(/^[ \t\n]+|[ \t\n]+$/g, "")], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
}

// --- step / skip-remaining ----------------------------------------------------

const STEP_AWK = `
      $1 == s { $2 = st; if (st == "fixing") $3 = ($3 + 0) + 1 }
      { print }`;
const SKIP_AWK = `
      $2 == "pending" || $2 == "running" { $2 = "skipped" }
      { print }`;

// The locked ledger swap: a temp beside steps.tsv, the awk, one rename - any
// failure releases the lock and refuses.
function ledgerRewrite(rd: string, awk: string[], verb: string): void {
  const lock = `${rd}/.steps.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail("steps ledger lock timeout");
  const m = mktemp(`${rd}/.steps.tsv.XXXXXX`);
  if (m.status !== 0 || runTo(["awk", "-F\\t", "-v", "OFS=\\t", ...awk, `${rd}/steps.tsv`], m.path) !== 0 || mv(m.path, `${rd}/steps.tsv`) !== 0) {
    rm(m.path);
    lockRelease(u8(lock));
    fail(`${verb}: could not update the steps ledger (${rd}/steps.tsv) - failing closed`);
  }
  lockRelease(u8(lock));
}

// `sed -n 's/^<key>=//p' <file> 2>/dev/null | tail -n 1` - "" when it fails.
function lastValue(file: string, key: string): string {
  const r = run(["sed", "-n", `s/^${key}=//p`, file], { stderr: "ignore" });
  return r.status === 0 ? cap(lastLine(r.out)) : "";
}

function reviewCompletedGate(rd: string): void {
  const agent = `${rd}/review.agent`;
  const meta = `${rd}/findings/review.meta.json`;
  const reviewed = lastValue(agent, "reviewed_ref");
  const head = gitA(["rev-parse", "HEAD"]);
  if (reviewed !== "" && reviewed === head) return;
  if (isFile(meta) && run(["jq", "-e", '(.reviewer // "") != ""', meta], { stdout: "ignore" }).status === 0) {
    const m = mktemp(`${rd}/findings/.review.meta.XXXXXX`);
    if (m.status !== 0) fail("step: mktemp failed while stamping reviewed_ref");
    if (runTo(["jq", "--arg", "ref", head, ".reviewed_ref = $ref", meta], m.path) === 0) ee(mv(m.path, meta));
    else {
      rm(m.path);
      fail("step: could not stamp reviewed_ref into review.meta.json");
    }
    if (isFile(agent) && mv(agent, `${rd}/review.agent.superseded`) !== 0) fail("step: could not retire the superseded review.agent receipt");
    return;
  }
  if (isFile(agent)) fail(`review receipt is stale: reviewed ${reviewed || "none"}, current HEAD ${head} - run a fresh independent review`);
  fail('review has no independent-reviewer evidence: run ac-ship.sh review-agent, or record meta review with a "reviewer" field after a clean-context subagent reviewed');
}

function cmdStep(a: string[], print = true): void {
  requireRun();
  const name = a[0] ?? "";
  const status = a[1] ?? "";
  if (a.length < 2) fail("usage: ac-ship.sh step <name> <status> [--note <text>]");
  const note = a[2] === "--note" ? (a[3] ?? "") : "";
  if (!listed(STEPS, name)) fail(`unknown step: ${name}`);
  if (!listed(STATUSES, status)) fail(`unknown status: ${status}`);
  const rd = runDir();
  if (name === "review" && status === "completed") reviewCompletedGate(rd);
  ledgerRewrite(rd, ["-v", `s=${name}`, "-v", `st=${status}`, STEP_AWK], "step");
  if (name === "test" && status === "completed") overrideClear(rd, "tdd-declared");
  ee(append(`${rd}/logs/run.log`, `${iso()} step=${name} status=${status}${note ? ` note=${note}` : ""}\n`));
  if (status === "running" || status === "fixing" || status === "awaiting_approval") watchOpen(rd, sedFirst(`${rd}/run.meta`, "s/^branch=//p").out);
  const r = run(["awk", "-F\\t", "-v", `s=${name}`, "$1 == s { print $3 }", `${rd}/steps.tsv`]);
  ee(r.status);
  if (!print) return;
  say(status === "fixing" ? `${name} -> ${status} (auto-fix round ${cap(r.out)})\n` : `${name} -> ${status}\n`);
}

function cmdSkipRemaining(): void {
  requireRun();
  const rd = runDir();
  ledgerRewrite(rd, [SKIP_AWK], "skip-remaining");
  ee(append(`${rd}/logs/run.log`, `${iso()} skip-remaining (empty diff)\n`));
  say("remaining steps skipped\n");
}

// --- findings / meta ------------------------------------------------------------

const DROPPED_JQ = `
      ([$old[0][]? | select(.action == "fix") | (.id // "?")]) as $o
      | ([$new[0][]? | select(.action == "fix") | (.id // "?")]) as $n
      | ($o - $n) | join(", ")
    `;

// <hereJson> is a trusted internal caller's here-string (review-agent), which
// is also the only caller that may replace a recorded `fix` finding; <meta>
// is its round metadata for the normalizer.
function cmdFindings(a: string[], hereJson: string | null = null, meta?: { round: string; delta: string; prior: string }): void {
  requireRun();
  const step = a[0] ?? "";
  if (!listed(STEPS, step)) fail(`unknown step: ${step}`);
  const mode = a[1] ?? "";
  if (mode !== "--show" && mode !== "") fail("usage: ac-ship.sh findings <step> [--show]");
  const rd = runDir();
  const f = `${rd}/findings/${step}.json`;
  if (mode === "--show") {
    if (!isFile(f)) fail(`no findings recorded for step ${step}`);
    const t = readText(f);
    if (t === null) fatal(1);
    say(t!);
    return;
  }
  if (hereJson === null && isatty(0)) fail(`findings ${step} reads a JSON array on stdin - refusing a tty (pipe JSON in, or use --show to view)`);
  const json = hereJson ?? cap(readStdin().toString("latin1"));
  if (run(["jq", "-e", 'type == "array"'], { stdin: here(json), stdout: "ignore" }).status !== 0) fail("findings must be a JSON array");
  const m = mktemp(`${rd}/findings/.${step}.XXXXXX`);
  if (m.status !== 0) fail(`findings ${step}: mktemp failed`);
  if (findingsNormalize(m.path, here(json), meta) !== 0) {
    rm(m.path);
    fail(`findings ${step}: normalize failed`);
  }
  if (step === "review" && hereJson === null && isFile(f)) {
    const d = run(["jq", "-n", "--slurpfile", "old", f, "--slurpfile", "new", m.path, "-r", DROPPED_JQ]);
    ee(d.status);
    const dropped = cap(d.out);
    if (dropped !== "") {
      rm(m.path);
      fail(
        `findings review refused (fail-closed): re-post drops fix finding(s) [${dropped}] with no resolution - only ac-ship.sh review-agent may resolve a fix finding (re-review it, or record its captain decision)`,
      );
    }
  }
  ee(mv(m.path, f));
  const s = findingsSummary(f);
  if (hereJson === null) say(s.out);
  ee(s.status);
}

function cmdMeta(a: string[], hereJson: string | null = null): void {
  requireRun();
  const step = a[0] ?? "";
  if (!listed(STEPS, step)) fail(`unknown step: ${step}`);
  const rd = runDir();
  const f = `${rd}/findings/${step}.meta.json`;
  if (hereJson === null && isatty(0)) fail(`meta ${step} reads a JSON object on stdin - refusing a tty`);
  const json = hereJson ?? cap(readStdin().toString("latin1"));
  if (run(["jq", "-e", 'type == "object"'], { stdin: here(json), stdout: "ignore" }).status !== 0) fail("meta must be a JSON object");
  const m = mktemp(`${f}.XXXXXX`);
  if (m.status !== 0) fail(`meta ${step}: mktemp failed`);
  if (runTo(["jq", "."], m.path, here(json)) === 0) ee(mv(m.path, f));
  else {
    rm(m.path);
    fail(`meta ${step}: write failed`);
  }
  ee(run(["jq", "-r", 'keys | join(" ")', f], { stdout: hereJson === null ? "inherit" : "ignore" }).status);
}

// --- cmd / attestation / receipt -------------------------------------------------

// `( cd <dir> && sh -c <c> ) 2>&1 | tee <log>` and the left side's status -
// the original's own pipeline, run by bash so the merge order, the live
// stream and every status stay the shell's.
function suite(c: string, log: string, dir = repo): number {
  return run(["/bin/bash", "--posix", "-c", '( cd "$1" && sh -c "$2" ) 2>&1 | tee "$3"; exit "${PIPESTATUS[0]}"', "ac-ship.sh", dir, c, log], { stdout: "inherit" }).status;
}

function attestConditions(af: string, c: string): string {
  const field = (k: string): string => {
    const r = run(["jq", "-r", `.${k} // ""`, af], { stderr: "ignore" });
    return r.status === 0 ? cap(r.out) : "";
  };
  const abranch = field("branch");
  const acommit = field("commit");
  const atree = field("tree");
  const acmd = field("cmd");
  const sr = git(["symbolic-ref", "--short", "HEAD"], { stderr: "ignore" });
  const branch = cap(sr.status === 0 ? sr.out : `${sr.out}DETACHED`);
  const head = cap(git(["rev-parse", "HEAD"]).out);
  const tree = cap(git(["rev-parse", "HEAD^{tree}"]).out);
  if (acommit === "" || atree === "" || acmd === "") return "unreadable or incomplete attestation file";
  if (abranch !== branch) return `branch moved (attested ${abranch}, on ${branch})`;
  if (acommit !== head) return `commit moved (attested ${acommit.slice(0, 12)}, HEAD ${head.slice(0, 12)})`;
  if (atree !== tree) return `tree mismatch (attested ${atree.slice(0, 12)}, HEAD tree ${tree.slice(0, 12)})`;
  if (acmd !== c) return "commands.test changed since attestation";
  const asha = field("output_sha256");
  if (asha !== "" && (!isFile(`${vdir}/attest-test.log`) || (shaFile(`${vdir}/attest-test.log`) ?? "") !== asha)) return "attestation log missing or does not hash to output_sha256";
  return "";
}

function cmdAttestTest(): void {
  const cf = homeConfigFile();
  if (cf === null || !isFile(cf)) {
    tell("(no config file)\n");
    fatal(4);
  }
  const c = yamlA(cf!, "commands.test");
  if (c === "") {
    tell("(no commands.test configured - nothing to attest)\n");
    fatal(4);
  }
  ensureCrewExcluded();
  const clean = (when: string): void => {
    const s = git(["status", "--porcelain"]);
    if (s.status !== 0) fail("attest-test: cannot read the worktree state (failing closed)");
    if (cap(s.out) !== "") fail(when);
  };
  clean("attest-test: worktree has uncommitted changes - an attestation must describe the COMMITTED state; commit first");
  ee(run(["mkdir", "-p", vdir], { stdout: "inherit" }).status);
  if (isDir(`${vdir}/attest-test.json`)) fail(`attest-test: ${vdir}/attest-test.json is a directory - remove it first`);
  const log = `${vdir}/attest-test.log`;
  tell(`$ ${c}\n`);
  const t0 = Math.floor(Date.now() / 1000);
  const started = isoA();
  const rc = suite(c, log);
  const ended = isoA();
  const secs = Math.floor(Date.now() / 1000) - t0;
  if (rc !== 0) {
    tell(`attest-test: test command failed (exit ${rc}) - no attestation written\n`);
    fatal(rc);
  }
  clean("attest-test: the test run left the worktree dirty - refusing to attest (does commands.test mutate tracked files?)");
  const sr = git(["symbolic-ref", "--short", "HEAD"], { stderr: "ignore" });
  const branch = cap(sr.status === 0 ? sr.out : `${sr.out}DETACHED`);
  const head = gitA(["rev-parse", "HEAD"]);
  const tree = gitA(["rev-parse", "HEAD^{tree}"]);
  const logSha = shaFile(log) ?? fatal(1);
  const m = mktemp(`${vdir}/.attest-XXXXXX`);
  ee(m.status);
  ee(
    runTo(
      [
        "jq", "-n", "--arg", "branch", branch, "--arg", "commit", head, "--arg", "tree", tree, "--arg", "cmd", c, "--arg", "at", iso(), "--arg", "sha", logSha, "--argjson", "secs", String(secs),
        "--arg", "started", started, "--arg", "ended", ended,
        "{branch: $branch, commit: $commit, tree: $tree, cmd: $cmd, at: $at, output_sha256: $sha, duration_s: $secs, started_at: $started, completed_at: $ended}",
      ],
      m.path,
    ),
  );
  ee(mv(m.path, `${vdir}/attest-test.json`));
  say(`attested: commands.test green @${head.slice(0, 12)} (branch ${branch}) - the test step will honor this until HEAD or the command changes\n`);
}

function cmdAttestCheck(): void {
  const af = `${vdir}/attest-test.json`;
  if (!isFile(af)) {
    say("no attestation\n");
    fatal(2);
  }
  let c = "";
  const cf = homeConfigFile();
  if (cf !== null && isFile(cf)) c = yamlA(cf, "commands.test");
  const why = attestConditions(af, c);
  if (why !== "") {
    say(`stale: ${why}\n`);
    fatal(1);
  }
  const head = gitA(["rev-parse", "HEAD"]);
  say(`attested: fresh @${head.slice(0, 12)} (${c})\n`);
}

// attest_accept, which the original ran as an `if` condition: errexit sleeps
// here and in everything it calls, explicit refusals still end the run.
function attestAccept(rd: string, c: string, cf: string): boolean {
  const was = soft;
  soft = true;
  try {
    const af = `${vdir}/attest-test.json`;
    const runLog = `${rd}/logs/run.log`;
    const mode = cap(yamlGet(cf, "test.attestation").out);
    if (mode === "ignore") {
      if (isFile(af)) {
        tell("test attestation present but test.attestation=ignore - running the suite\n");
        append(runLog, `${iso()} test attestation skipped: test.attestation=ignore\n`);
      }
      return false;
    }
    if (mode !== "" && mode !== "accept") {
      tell(`test.attestation=${mode} is not accept|ignore - failing closed, running the suite\n`);
      append(runLog, `${iso()} test attestation skipped: unknown test.attestation value ${mode}\n`);
      return false;
    }
    if (!isFile(af)) return false;
    const why = attestConditions(af, c);
    const head = cap(git(["rev-parse", "HEAD"]).out);
    if (why !== "") {
      tell(`attestation not accepted: ${why} - running the suite\n`);
      append(runLog, `${iso()} test attestation rejected: ${why}\n`);
      return false;
    }
    put(`${rd}/findings/test.json`, "[]\n");
    const at = cap(run(["jq", "-r", '.at // ""', af]).out);
    runTo(["jq", "-n", "--arg", "s", `TDD attestation @${head.slice(0, 12)}, suite not re-run`, "--arg", "t", `${c} green at attestation (${at})`, "{testing_summary: $s, tested: [$t], artifacts: []}"], `${rd}/findings/test.meta.json`);
    cmdStep(["test", "completed", "--note", "TDD attestation accepted"], false);
    append(runLog, `${iso()} test attestation accepted commit=${head.slice(0, 12)} - suite not re-run\n`);
    say(`test: TDD attestation accepted @${head.slice(0, 12)} - suite not re-run\n`);
    return true;
  } finally {
    soft = was;
  }
}

function receiptWrite(rd: string, qual: string, reason: string, cmdSha = "", outSha = "", started = "", ended = "", code = ""): void {
  ee(run(["mkdir", "-p", `${rd}/test`], { stdout: "inherit" }).status);
  const m = mktemp(`${rd}/test/.receipt.XXXXXX`);
  ee(m.status);
  const src = git(["rev-parse", "HEAD"], { stderr: "ignore" });
  ee(
    put(
      m.path,
      `schema=agentcrew.ship-test-receipt/v1\nsource_sha=${cap(src.status === 0 ? src.out : `${src.out}-`)}\nqualification=${qual}\nreason=${reason}\nship_run=${basename(rd)}\ncommand_sha256=${cmdSha || "-"}\noutput_sha256=${outSha || "-"}\nstarted_at=${started || "-"}\ncompleted_at=${ended || "-"}\nexit_code=${code || "-"}\n`,
    ),
  );
  if (mv(m.path, `${rd}/test/receipt.env`) !== 0) {
    rm(m.path);
    fail("cmd test could not publish its run-scoped test receipt");
  }
}

function receiptFromAttestation(rd: string, c: string): void {
  const af = `${vdir}/attest-test.json`;
  if (!isFile(af)) return receiptWrite(rd, "not-qualifies", "invalid");
  const field = (k: string): string => {
    const r = run(["jq", "-r", `.${k} // "-"`, af], { stderr: "ignore" });
    return r.status === 0 ? cap(r.out) : "-";
  };
  const started = field("started_at");
  const ended = field("completed_at");
  const outSha = field("output_sha256");
  const bad = started === "-" || started === "" || ended === "-" || ended === "" || outSha === "-" || outSha === "";
  receiptWrite(rd, bad ? "not-qualifies" : "qualifies", bad ? "invalid" : "execution-attestation", sha(c), outSha || "-", started || "-", ended || "-", "0");
}

function baseAttribution(rd: string, c: string): void {
  const base = freshBase() ?? fatal(1);
  const bt = `${rd}/base-tree`;
  if (git(["worktree", "add", "-q", "--detach", bt, base], { stderr: "ignore" }).status !== 0) {
    tell(`base attribution: could not check out the base ${base}\n`);
    return;
  }
  let brc = 1;
  try {
    const fd = openSync(B(`${rd}/logs/test-base.log`), "w");
    try {
      brc = run(["sh", "-c", c], { cwd: bt, stdout: fd, stderr: fd }).status;
    } finally {
      closeSync(fd);
    }
  } catch {}
  git(["worktree", "remove", "--force", bt], { stderr: "ignore" });
  if (brc === 0) tell(`base attribution: the base passes @${base.slice(0, 12)} - this change introduced the failure (logs/test-base.log)\n`);
  else
    tell(
      `base attribution: the base also fails (exit ${brc}) @${base.slice(0, 12)} - read logs/test-base.log before calling it pre-existing: a base checkout carries no untracked setup (dependencies, env)\n`,
    );
  ee(append(`${rd}/logs/run.log`, `${iso()} base_attribution base=${base} exit=${brc}\n`));
}

function cmdCmd(a: string[]): void {
  requireRun();
  const name = a[0] ?? "";
  if (name !== "test" && name !== "lint" && name !== "format") fail("usage: ac-ship.sh cmd <test|lint|format>");
  const cf = configFile();
  if (cf === null) {
    tell("(no config file)\n");
    fatal(4);
  }
  let c = yamlA(cf!, `commands.${name}`);
  if (c === "") {
    tell(`(no commands.${name} configured)\n`);
    fatal(4);
  }
  const rd = runDir();
  let scoped = false;
  if (name === "test") {
    receiptWrite(rd, "not-qualifies", "incomplete");
    if (attestAccept(rd, c, cf!)) {
      receiptFromAttestation(rd, c);
      fatal(0);
    }
    const tc = yamlA(cf!, "commands.test-changed");
    if (tc !== "") {
      if (!tc.includes("{files}")) fail("commands.test-changed must carry a {files} placeholder");
      const d = git(["diff", "-z", "--name-only", "--diff-filter=d", freshBase() ?? "", "HEAD"]);
      ee(d.status);
      const names = d.out.split("\0").slice(0, -1);
      if (names.length > 0) {
        c = tc.replaceAll("{files}", names.map((n) => ` '${n.replaceAll("'", "'\\''")}'`).join(""));
        scoped = true;
        tell(`(scoped test: ${names.length} changed files)\n`);
      }
    }
  }
  tell(`$ ${c}\n`);
  const started = isoA();
  const log = `${rd}/logs/${name}.log`;
  const rc = suite(c, log);
  ee(append(`${rd}/logs/run.log`, `${iso()} cmd=${name} exit=${rc}\n`));
  if (name === "test") {
    const csha = sha(c);
    const osha = shaFile(log) ?? "";
    if (rc === 0) receiptWrite(rd, scoped ? "not-qualifies" : "qualifies", scoped ? "scoped" : "executed", csha, osha, started, iso(), "0");
    else receiptWrite(rd, "not-qualifies", "non-zero", csha, osha, started, iso(), String(rc));
    if (rc !== 0 && !scoped && cap(yamlGet(cf!, "test.base_attribution").out) === "on") baseAttribution(rd, c);
  }
  fatal(rc);
}

// --- push / base / evidence-dir / config ------------------------------------------

function publishedHead(branch: string, head: string): boolean {
  if (!isFile(`${vdir}/pushed.tsv`)) return false;
  return run(["awk", "-F\\t", "-v", `b=${branch}`, "-v", `c=${head}`, "$1 == b && $2 == c { hit = 1 } END { exit !hit }", `${vdir}/pushed.tsv`]).status === 0;
}

function assertReviewCurrent(rd: string, what: string): void {
  const st = run(["awk", "-F\\t", '$1 == "review" { print $2 }', `${rd}/steps.tsv`], { stderr: "ignore" });
  if (st.status !== 0 || cap(st.out) !== "completed") return;
  let reviewed = lastValue(`${rd}/review.agent`, "reviewed_ref");
  const meta = `${rd}/findings/review.meta.json`;
  if (reviewed === "" && isFile(meta)) {
    const r = run(["jq", "-r", '.reviewed_ref // ""', meta], { stderr: "ignore" });
    reviewed = r.status === 0 ? cap(r.out) : "";
  }
  if (reviewed === "") {
    warn(B(`${what}: the review receipt records no reviewed_ref - review currency is UNPROVEN for this run`));
    return;
  }
  const h = git(["rev-parse", "HEAD"]);
  if (h.status !== 0) fail(`${what}: cannot read HEAD (failing closed)`);
  const head = cap(h.out);
  if (reviewed !== head)
    fail(
      `${what} refused (fail-closed): HEAD moved since review - reviewed ${reviewed.slice(0, 12)}, current ${head.slice(0, 12)}. The diff was never reviewed at this commit; run a fresh independent review (ac-ship.sh review-agent).`,
    );
}

function cmdPush(): void {
  requireRun();
  // A credential prompt would wait forever in an agent's tool call.
  process.env.GIT_TERMINAL_PROMPT = "0";
  process.env.GIT_OPTIONAL_LOCKS = "0";
  const rd = runDir();
  assertReviewCurrent(rd, "push");
  const b = git(["symbolic-ref", "--short", "HEAD"], { stderr: "ignore" });
  if (b.status !== 0) fail("push: refusing from a detached HEAD");
  const branch = cap(b.out);
  if (branch === b8(defaultBranch(u8(repo), true))) fail("push: refusing to push the default branch");
  const t = sedFirst(`${rd}/run.meta`, "s/^target=//p", "ignore");
  ee(t.status);
  const tname = t.out.startsWith("origin/") ? t.out.slice(7) : t.out;
  if (tname !== "" && branch === tname) fail(`push: refusing to push the delivery target branch (${tname})`);
  if (git(["remote", "get-url", "origin"], { stdout: "ignore", stderr: "ignore" }).status !== 0) fail("push: no origin remote");
  const ref = `refs/heads/${branch}`;
  const head = gitA(["rev-parse", "HEAD"]);
  const ls = git(["ls-remote", "origin", ref]);
  const first = run(["awk", "{print $1}"], { stdin: B(ls.out) });
  if (ls.status !== 0 || first.status !== 0) fail("push: cannot read the remote (failing closed)");
  const remote = cap(first.out);
  const pushed = `${vdir}/pushed.tsv`;
  if (remote === "") {
    if (git(["push", "-u", "origin", branch], { stdout: "inherit" }).status !== 0) fail("push: plain push of new branch failed");
    ee(append(pushed, `${branch}\t${head}\n`));
    say(`pushed new branch ${branch}\n`);
  } else if (remote === head) {
    say(`up-to-date: origin/${branch} == HEAD\n`);
  } else {
    if (git(["fetch", "--no-tags", "origin", ref], { stdout: "inherit", stderr: "ignore" }).status !== 0) fail(`push: fetch of ${ref} failed (failing closed)`);
    const base = freshBase() ?? fatal(1);
    const u = git(["rev-list", "--cherry-pick", "--right-only", `HEAD...${remote}`, `^${base}`], { stderr: "ignore" });
    if (u.status !== 0) fail("push: incorporation check failed (failing closed)");
    const unincorporated = cap(u.out);
    if (unincorporated !== "") {
      if (publishedHead(branch, remote)) say(`push: origin/${branch} is the head this pipeline published (${remote.slice(0, 12)}) - rebased, not diverged\n`);
      else {
        tell(`push: origin/${branch} has commits not incorporated by this branch:\n`);
        tell(unincorporated.split("\n").slice(0, 10).map((l) => `${l}\n`).join(""));
        fail("push: refusing to force-push over unincorporated remote commits");
      }
    }
    if (git(["push", `--force-with-lease=${ref}:${remote}`, "origin", branch], { stdout: "inherit" }).status !== 0) fail("push: lease-guarded push failed (remote moved; re-run)");
    ee(append(pushed, `${branch}\t${head}\n`));
    say(`pushed ${branch} with lease ${remote.slice(0, 12)}\n`);
  }
  ee(append(`${rd}/logs/run.log`, `${iso()} push branch=${branch}\n`));
}

// cmd_config: the frozen (or installed) config's value, raw as awk printed
// it, and awk's status; no config is status 1, a missing key the shell's own
// `1: dotted key required` death (its text not reproduced).
function cmdConfig(a: string[], quiet = false): Ran {
  const cf = configFile(quiet);
  if (cf === null) return { status: 1, out: "" };
  if ((a[0] ?? "") === "") return { status: 1, out: "" };
  return yamlGet(cf, a[0]!, quiet);
}

function cmdEvidenceDir(): void {
  requireRun();
  const rd = runDir();
  const sr = git(["symbolic-ref", "--short", "HEAD"], { stderr: "ignore" });
  const slug = cap(sr.out.replaceAll("/", "-") + (sr.status === 0 ? "" : "detached"));
  const store = cap(cmdConfig(["test.evidence.store_in_repo"], true).out);
  let dir = cap(cmdConfig(["test.evidence.dir"], true).out);
  if (store === "true") {
    dir ||= ".agent-crew/evidence";
    if (dir.startsWith("/") || dir.includes("..")) warn(B(`evidence dir unsafe (${dir}); using temp`));
    else {
      const target = `${repo}/${dir}/${slug}`;
      if (git(["check-ignore", "-q", dir], { stderr: "ignore" }).status === 0) warn(B(`evidence dir is gitignored (${dir}); using temp`));
      else {
        ee(run(["mkdir", "-p", target], { stdout: "inherit" }).status);
        say(`${target}\n`);
        return;
      }
    }
  }
  const target = `${process.env.TMPDIR ? b8(process.env.TMPDIR) : "/tmp"}/agent-crew-evidence/${basename(rd)}`;
  ee(run(["mkdir", "-p", target], { stdout: "inherit" }).status);
  say(`${target}\n`);
}

// --- review-agent / review-residual -------------------------------------------------

function reviewRoundsRecorded(rd: string): number {
  let n = 0;
  while (nonEmpty(`${rd}/logs/review-agent-r${n + 1}.json`)) n++;
  return n;
}

function reviewInvocationsRecorded(rd: string): string {
  const f = `${rd}/logs/review-invocations.tsv`;
  if (!nonEmpty(f)) return "0";
  const r = run(["awk", "END { print NR }", f]);
  ee(r.status);
  return cap(r.out);
}

function retireRejected(result: string): void {
  if (!exists(result)) return;
  if (run(["mv", "-f", result, `${result}.rejected`], { stdout: "inherit", stderr: "ignore" }).status !== 0) rm(result);
}

// The outcome rewrite goes through an exclusive temp: the original's
// predictable `<ledger>.tmp` wrote through whatever sat there.
function reviewInvocationOutcome(rd: string, outcome: string): void {
  const f = `${rd}/logs/review-invocations.tsv`;
  if (!nonEmpty(f)) return;
  const nr = run(["awk", "END { print NR }", f]);
  ee(nr.status);
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(`${f}.tmp`));
  } catch {
    return;
  }
  let st: number;
  try {
    st = run(["awk", "-F\\t", "-v", "OFS=\\t", "-v", `n=${cap(nr.out)}`, "-v", `o=${outcome}`, "FNR == n { $4 = o } { print }", f], { stdout: t.fd }).status;
  } finally {
    closeSync(t.fd);
  }
  if (st !== 0 || mv(b8(t.path), f) !== 0) rm(b8(t.path));
}

function reviewVerifyEvidenceDir(family: string): string {
  const st = process.env.AC_FLEET_STATE ? b8(process.env.AC_FLEET_STATE) : "";
  return st.endsWith("/state") ? `${st.slice(0, -"/state".length)}/data/${family}/verify/codereview` : `data/${family}/verify/codereview (under the fleet home)`;
}

function reviewDeltaIsCallerPolish(reviewed: string, head: string, base: string): boolean {
  if (reviewed === "" || head === "" || base === "") return false;
  if (git(["rev-parse", "-q", "--verify", `${reviewed}^{commit}`], { stdout: "ignore", stderr: "ignore" }).status !== 0) return false;
  if (git(["merge-base", "--is-ancestor", reviewed, head], { stderr: "ignore" }).status !== 0) return false;
  const total = git(["rev-list", "--count", `${reviewed}..${head}`], { stderr: "ignore" });
  if (total.status !== 0) return false;
  const own = git(["rev-list", "--count", `${reviewed}..${head}`, `^${base}`], { stderr: "ignore" });
  if (own.status !== 0) return false;
  return cap(total.out) !== "" && cap(total.out) === cap(own.out);
}

const LEDGER_JQ = `[. | {round: $round, reviewed_ref, verdict, risk_level, findings,
             resolved_ids: (.resolved_ids // [])}]`;
const REJECT_JQ = String.raw`
    if type != "object" then "not-a-json-object"
    elif (.findings | type) != "array" then "findings-not-an-array (\(.findings | type))"
    elif .reviewed_ref != $ref then "reviewed_ref-does-not-bind-HEAD (\(.reviewed_ref // "missing"))"
    elif (.verdict as $v | ["pass","fix","ask-user"] | index($v)) == null then "verdict-not-in-enum (\(.verdict // "missing"))"
    elif (.risk_level as $r | ["low","medium","high"] | index($r)) == null then "risk_level-not-in-enum (\(.risk_level // "missing"))"
    elif (.risk_rationale | type) != "string" then "risk_rationale-not-a-string (\(.risk_rationale | type))"
    else "" end
  `;
const PRIOR_OPEN_IDS_JQ = `[.findings[]?
      | select(.action == "fix" or .action == "ask-user")
      | .id | select(type == "string")] | unique`;
const VERDICT_JQ = `
      .findings = $findings[0]
      | .verdict = (if ([.findings[].action] | index("ask-user")) != null then "ask-user"
                    elif ([.findings[].action] | index("fix")) != null then "fix"
                    else "pass" end)`;
const RISK_META_JQ = `{risk_level, risk_rationale, reviewed_ref}
                        + (if (.summary // "") != "" then {summary: .summary} else {} end)`;

// `x="$(jq -r <prog> <file> 2>/dev/null)" || x=""`.
function jqSoft(prog: string, file: string): string {
  const r = run(["jq", "-r", prog, file], { stderr: "ignore" });
  return r.status === 0 ? cap(r.out) : "";
}

// `[ "$a" -gt "$b" ]` as bash 3.2 reads two operands: false when either is
// no number.
const gt = (a: string, b: string): boolean => {
  const x = testInt(a);
  const y = testInt(b);
  return x !== null && y !== null && x > y;
};

function maxRounds(): string {
  const m = cap(cmdConfig(["review.max_rounds"], true).out);
  return m === "" || /[^0-9]/.test(m) || m === "0" ? "3" : m;
}

function cmdReviewAgent(a: string[]): void {
  requireRun();
  const finalRound = a[0] === "--final-round";
  const rd = runDir();
  const base = freshBase() ?? fatal(1);
  const head = gitA(["rev-parse", "HEAD"]);
  const intent = runIntent(rd);
  const prevN = reviewRoundsRecorded(rd);
  const round = prevN + 1;

  let caller = process.env.AC_CREW_ID ? b8(process.env.AC_CREW_ID) : "";
  if (caller === "") {
    const s = sedFirst(`${rd}/run.meta`, "s/^branch=crew\\///p");
    ee(s.status);
    caller = s.out;
  }
  if (caller === "" || caller === "DETACHED" || /[^a-z0-9-]/.test(caller)) fail(`review-agent needs AC_CREW_ID from ac-spawn (got '${caller || "empty"}')`);
  let family = process.env.AC_FLEET_SCOPE ? b8(process.env.AC_FLEET_SCOPE) : "";
  if (family === "") family = caller.endsWith("-implement") ? caller.slice(0, -"-implement".length) : caller;

  const ts = run(["awk", "-F\\t", '$1 == "test" { print $2 }', `${rd}/steps.tsv`]);
  ee(ts.status);
  if (cap(ts.out) !== "completed") {
    const af = `${vdir}/attest-test.json`;
    let tc = "";
    const cf = configFile(true);
    if (cf !== null) tc = yamlA(cf, "commands.test");
    const why = isFile(af) ? attestConditions(af, tc) : "no attestation";
    if (why !== "")
      fail(
        `review-agent refuses to open without test evidence (${why}): complete the test step first (ac-ship.sh cmd test; ac-ship.sh step test completed) or record a fresh attestation (ac-ship.sh attest-test) - a suite-catchable failure must never burn a review round (review-round-convergence)`,
      );
  }

  let prev = "";
  let prevRef = "";
  if (prevN > 0) {
    prev = `${rd}/logs/review-agent-r${prevN}.json`;
    const prevVerdict = jqSoft('.verdict // ""', prev);
    prevRef = jqSoft('.reviewed_ref // ""', prev);
    if (prevRef !== "" && prevRef === head) {
      const remedy =
        prevVerdict === "pass"
          ? "complete delivery at this ref; advisory findings belong in the PR/backlog"
          : prevVerdict === "fix"
            ? "apply the blocking fix and commit it before requesting the next round - or, when the owning chief judges the finding WRONG (no code change warranted), release the loop roundless: ac-ship.sh review-residual accept --grounds '<why>' (critical correctness/security/data-loss still refuses)"
            : prevVerdict === "ask-user"
              ? "record the captain decision; commit only if that decision requires a code change"
              : "change the reviewed ref before requesting another round";
      fail(`review-agent refuses to re-open: round ${prevN} already reviewed current HEAD ${head.slice(0, 12)} with verdict ${prevVerdict || "unknown"} - ${remedy}`);
    }
    if (prevVerdict === "pass" && reviewDeltaIsCallerPolish(prevRef, head, base))
      fail(
        `review-agent refuses to re-open: round ${prevN} returned a PASS verdict (zero fix findings) at ${prevRef.slice(0, 12)}, and every commit since is this run's own - a 0-fix verdict FREEZES the tree, so advisory (no-op) findings are notes for the PR body and the backlog, never a licence to commit. Reset the crew branch back to ${prevRef.slice(0, 12)} and land, or ask your chief to mint a follow-up task for the advisory. A genuine rebase re-opens the round by itself.`,
      );
  }

  const ledger = `${rd}/logs/review-invocations.tsv`;
  let attempts = "";
  if (nonEmpty(ledger)) {
    const r = run(["awk", "-F\\t", "-v", `ref=${head}`, '$3 == ref {\n    printf "attempt %d (round %s, %s) %s\\n", ++n, $2, $1, ($4 == "" ? "unknown" : $4)\n  }', ledger]);
    ee(r.status);
    attempts = cap(r.out);
  }
  if (attempts.split("\n").filter((l) => l !== "").length >= 2)
    fail(
      `review-agent refuses a THIRD invocation on ref ${head.slice(0, 12)} - ${attempts.split("\n").join("; ")}. A repeated failure on ONE ref is an infrastructure or validator signal, and more model spend never fixes it. Diagnose before retrying: the verifier round evidence under ${reviewVerifyEvidenceDir(family)} (transcript.jsonl and pane-result.ndjson[.tmp], newest dir last) and this run's own rejection lines in ${rd}/logs/run.log. Report this hold with a blocked: line so the chief wakes.`,
    );

  let invocation: string;
  try {
    invocation = String(arithValue(reviewInvocationsRecorded(rd)) + 1n);
  } catch {
    return fatal(1);
  }
  const max = maxRounds();
  if (gt(invocation, max)) {
    const marker = `${rd}/review.final-round`;
    if (!finalRound)
      fail(
        `review-agent: verifier invocation ${invocation} exceeds review.max_rounds=${max} - the loop HOLDs for the owning chief's chief-decide (review-round-convergence): the chief accepts the residual as advisory (ac-ship.sh review-residual accept --grounds '<grounds>', which prints the SELF-APPROVED receipt to post to the room) or orders exactly ONE targeted final round (ac-ship.sh review-agent --final-round). Report this hold with a blocked: line so the chief wakes.`,
      );
    if (isFile(marker))
      fail(
        `review-agent: the one --final-round is already spent (${cap(firstLine(readText(marker) ?? ""))}) - the residual is the owning chief's call: accept it (ac-ship.sh review-residual accept --grounds '<...>') or the captain re-routes the task`,
      );
    ee(put(marker, `granted_at_round=${round} at=${iso()}\n`));
  }
  const verify = process.env.AC_VERIFY_BIN ? b8(process.env.AC_VERIFY_BIN) : `${binDir}/ac-verify.sh`;
  if (!can(verify, fsc.X_OK)) fail(`verifier facade is not executable: ${verify}`);

  const intentFile = `${rd}/logs/review-intent-r${round}.md`;
  ee(put(intentFile, `${intent}\n`));
  const result = `${rd}/logs/review-agent-r${round}.json`;
  const args = ["codereview", "--repo", repo, "--ref", head, "--base", base, "--family", family, "--caller", caller, "--intent", intentFile, "--output", result];
  if (prevN > 0) {
    if (!nonEmpty(prev)) fail(`review-agent: previous round result is missing: ${prev}`);
    const l = run(["jq", "-c", "--argjson", "round", String(prevN), LEDGER_JQ, prev]);
    if (l.status !== 0) fail(`review-agent: previous round result is unreadable: ${prev}`);
    const historyFile = `${rd}/logs/review-history-r${round}.json`;
    ee(put(historyFile, `${cap(l.out)}\n`));
    args.push("--history", historyFile);
  }
  ee(append(ledger, `${iso()}\t${round}\t${head}\topened\n`));
  overrideClear(rd, "review-residual");
  if (run([verify, ...args], { stdout: "ignore" }).status !== 0) {
    reviewInvocationOutcome(rd, "dead-pane");
    retireRejected(result);
    fail(`independent review round ${round} failed; inspect the verifier round evidence under ${reviewVerifyEvidenceDir(family)}`);
  }
  if (!nonEmpty(result)) {
    reviewInvocationOutcome(rd, "dead-pane");
    fail(`independent review round ${round} returned no durable result`);
  }

  let json = cap(readText(result) ?? fatal(1));
  const rj = run(["jq", "-r", "--arg", "ref", head, REJECT_JQ], { stdin: here(json), stderr: "ignore" });
  const rejectWhy = rj.status === 0 ? cap(rj.out) : "unparseable-json";
  if (rejectWhy !== "") {
    ee(append(`${rd}/logs/run.log`, `${iso()} review-agent round ${round}: verdict REJECTED - failed check: ${rejectWhy}\n`));
    reviewInvocationOutcome(rd, "rejected-verdict");
    retireRejected(result);
    fail(`verifier result rejected - failed check: ${rejectWhy}; the verdict is kept at ${result}.rejected`);
  }
  reviewInvocationOutcome(rd, "ok");
  const fj = run(["jq", "-c", ".findings"], { stdin: here(json) });
  ee(fj.status);
  const findingsJson = cap(fj.out);

  let floorRef = "";
  let priorOpen = "[]";
  if (round >= 2 && prevRef !== "") {
    const po = run(["jq", "-c", PRIOR_OPEN_IDS_JQ, prev], { stderr: "ignore" });
    priorOpen = po.status === 0 ? cap(po.out) : "";
    floorRef = cap(git(["rev-parse", "--verify", `${prevRef}^{commit}`], { stderr: "ignore" }).out);
    if (floorRef !== "" && git(["merge-base", "--is-ancestor", floorRef, head], { stderr: "ignore" }).status !== 0) floorRef = "";
  }
  let meta: { round: string; delta: string; prior: string } | undefined;
  if (floorRef !== "" && priorOpen !== "") {
    const d = git(["diff", "-z", "--name-only", floorRef, head, "--"], { stderr: "ignore" });
    const names = d.out.split("\0").slice(0, -1);
    // A delta name holding a newline cannot ride the newline list.
    if (d.status === 0 && !names.some((n) => n.includes("\n")))
      meta = { round: String(round), delta: u8(cap(names.map((n) => `${n}\n`).join(""))), prior: u8(priorOpen) };
  }
  cmdFindings(["review"], findingsJson, meta);

  const rt = mktemp(`${rd}/logs/.review-agent-r${round}.XXXXXX`);
  if (rt.status !== 0) fail("review-agent: could not stage normalized round result");
  if (runTo(["jq", "--slurpfile", "findings", `${rd}/findings/review.json`, VERDICT_JQ], rt.path, here(json)) === 0) ee(mv(rt.path, result));
  else {
    rm(rt.path);
    fail("review-agent: could not persist normalized round result");
  }
  json = cap(readText(result) ?? fatal(1));
  const rm2 = run(["jq", "-c", RISK_META_JQ], { stdin: here(json) });
  ee(rm2.status);
  cmdMeta(["review"], cap(rm2.out));
  const rv = run(["jq", "-r", ".reviewed_ref"], { stdin: here(json) });
  ee(rv.status);
  const reviewed = cap(rv.out);
  const rk = run(["jq", "-r", ".risk_level"], { stdin: here(json) });
  ee(rk.status);
  ee(put(`${rd}/review.agent`, `reviewer=ac-verify\nround=${round}\nreviewed_ref=${reviewed}\nresult=${result}\ncompleted_at=${iso()}\n`));
  say(`review-agent round ${round}: ${cap(findingsSummary(`${rd}/findings/review.json`).out)} risk=${cap(rk.out)} reviewed_ref=${reviewed}\n`);
}

// run_intent: the whole intent file, else run.meta's first intent= line.
function runIntent(rd: string): string {
  const t = readText(`${rd}/intent`);
  if (t !== null) return cap(t);
  const s = sedFirst(`${rd}/run.meta`, "s/^intent=//p");
  ee(s.status);
  return s.out;
}

const CARVE_JQ = `[.[] | ((.class // "") | tostring) as $c
    | select(.action == "fix" and ((.severity // "") | tostring) == "error"
             and ((["correctness","security","data-loss"] | index($c)) != null))] | length`;
const RESIDUAL_JQ = `[.[]
      | if .action == "fix"
        then .action = "no-op" | .residual_accepted = true | .residual_grounds = $g
        else . end]`;

// `ls <run>/logs/review-agent-r*.json | sort -V | tail -n 1 | xargs -r cat |
// jq -r '.reviewed_ref // ""'`, "" when any stage failed.
function newestReviewedRef(rd: string): string {
  let names: string[];
  try {
    names = readdirSync(B(`${rd}/logs`), { encoding: "buffer" })
      .map((n) => Buffer.from(n).toString("latin1"))
      .filter((n) => n.startsWith("review-agent-r") && n.endsWith(".json"))
      .sort((x, y) => Buffer.compare(B(x), B(y)));
  } catch {
    return "";
  }
  if (names.length === 0) return "";
  const sorted = run(["sort", "-V"], { stdin: B(names.map((n) => `${rd}/logs/${n}\n`).join("")) });
  const last = lastLine(sorted.out);
  const xargs = run(["xargs", "-r", "cat"], { stdin: B(sorted.out === "" ? "" : `${last}\n`), stderr: "ignore" });
  const jq = run(["jq", "-r", '.reviewed_ref // ""'], { stdin: B(xargs.out), stderr: "ignore" });
  if (sorted.status !== 0 || xargs.status !== 0 || jq.status !== 0) return "";
  return cap(jq.out);
}

function cmdReviewResidual(a: string[]): void {
  requireRun();
  if ((a[0] ?? "") !== "accept") fail("usage: ac-ship.sh review-residual accept --grounds '<text>'");
  let grounds = "";
  for (let i = 1; i < a.length; ) {
    if (a[i] !== "--grounds") fail(`review-residual: unknown argument ${a[i]}`);
    grounds = a[i + 1] ?? "";
    if (i + 1 >= a.length) fail("--grounds needs a value");
    i += 2;
  }
  if (grounds === "") fail("review-residual: --grounds is required - the receipt is the captain's veto surface, and a receipt with no grounds records nothing");
  const rd = runDir();
  const f = `${rd}/findings/review.json`;
  if (!isFile(f)) fail("review-residual: no review findings recorded");
  const rounds = reviewInvocationsRecorded(rd);
  const max = maxRounds();
  if (gt(max, rounds)) {
    const lastRef = newestReviewedRef(rd);
    const curHead = cap(git(["rev-parse", "HEAD"], { stderr: "ignore" }).out);
    if (lastRef === "" || lastRef !== curHead)
      fail(
        `review-residual: acceptance is only for a loop AT the cap (rounds=${rounds}, review.max_rounds=${max}) or STUCK at an already-reviewed HEAD (one ref, one round) - run the normal fix loop`,
      );
  }
  const carve = run(["jq", CARVE_JQ, f]);
  ee(carve.status);
  if (cap(carve.out) !== "0")
    fail(
      `review-residual: the residual holds ${cap(carve.out)} critical correctness/security/data-loss finding(s) - acceptance is refused (non-overridable carve-out); grant ac-ship.sh review-agent --final-round or the captain re-routes`,
    );
  const nf = run(["jq", '[.[] | select(.action == "fix")] | length', f]);
  ee(nf.status);
  const nfix = cap(nf.out);
  if (!gt(nfix, "0")) fail("review-residual: no fix residual to accept - complete the review step normally");
  const m = mktemp(`${rd}/findings/.review.residual.XXXXXX`);
  if (m.status !== 0) fail("review-residual: mktemp failed");
  if (runTo(["jq", "--arg", "g", grounds, RESIDUAL_JQ, f], m.path) === 0) ee(mv(m.path, f));
  else {
    rm(m.path);
    fail("review-residual: rewrite failed - findings left untouched");
  }
  ee(append(`${rd}/logs/run.log`, `${iso()} review residual accepted (${nfix} finding(s)) at rounds=${rounds} grounds=${grounds}\n`));
  const receipt = cap(`SELF-APPROVED: review-residual r${rounds} - decision: accepted - grounds: ${grounds}`);
  overrideNote(rd, "review-residual", receipt, grounds);
  say(`review-residual: ${nfix} finding(s) accepted as advisory - post this receipt to the family room:\n${receipt}\n`);
}

// --- fix-report / status / finish ----------------------------------------------

const LOC_JQ = String.raw`def loc: if (.file // "") != "" then "\(.file)\(if (.line // "") != "" and .line != null then ":\(.line)" else "" end) - " else "" end;`;
const FIX_JQ = String.raw`
    ${LOC_JQ}
    def tag: if (.id // "") != "" then " (\(.id))" else "" end;
    def auth: if (.authority // "") != "" then " - authority: \(.authority)" else "" end;
    .[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") != "")))
        | "- [\(.severity // "info")] \(loc)\(.description)\(tag)\(if (.decision // "") != "" then " - DECIDED: \(.decision)" else "" end)\(auth)"
  `;
const PARKED_JQ = String.raw`
      ${LOC_JQ}
      .[] | select(.action == "ask-user" and ((.decision // "") == ""))
          | "- [\(.severity // "info")] \(loc)\(.description)\(if .authority_downgraded then " - NO AUTHORITY NAMED (downgraded from fix)" else "" end)"
    `;

function cmdFixReport(a: string[]): void {
  requireRun();
  const step = a[0] ?? "";
  if (!listed(STEPS, step)) fail(`unknown step: ${step}`);
  const rd = runDir();
  const f = `${rd}/findings/${step}.json`;
  if (!isFile(f)) fail(`no findings recorded for step ${step} (pipe them to: ac-ship.sh findings ${step})`);
  const intent = runIntent(rd);
  const br = sedFirst(`${rd}/run.meta`, "s/^branch=//p");
  ee(br.status);
  const short = gitA(["rev-parse", "--short", "HEAD"]);
  const rr = run(["awk", "-F\\t", "-v", `s=${step}`, "$1 == s { print $3 + 0 }", `${rd}/steps.tsv`]);
  ee(rr.status);
  const capv = cap(cmdConfig([`auto_fix.${step}`], true).out);
  const nf = run(["jq", '[.[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") != "")))] | length', f]);
  ee(nf.status);
  const nfix = cap(nf.out);
  let round: bigint;
  try {
    round = arithValue(cap(rr.out)) + 1n;
  } catch {
    return fatal(1);
  }
  say(`# Fix report: ${basename(repo)} - run ${basename(rd)}, step ${step} (fix round ${round}/${capv || "-"})\n\n`);
  say(`Intent: ${intent}\nBranch: ${br.out} @ ${short}\n\n`);
  say(`## Findings to fix (${nfix})\n`);
  ee(run(["jq", "-r", FIX_JQ, f], { stdout: "inherit" }).status);
  if (run(["jq", "-e", '[.[] | select(.action == "ask-user" and ((.decision // "") == ""))] | length > 0', f], { stdout: "ignore" }).status === 0) {
    say("\n## Parked - awaiting captain (do NOT act on these)\n");
    ee(run(["jq", "-r", PARKED_JQ, f], { stdout: "inherit" }).status);
  }
  say("\n## Contract\n");
  say(
    "- Your unit of work is the INVARIANT a finding violates, not the line it cites: enumerate every sibling site in the changed area that violates the same invariant (the other axis, the sibling branch, the same map in a second file, the next unvalidated field) and close them in this round with the same small correction or at one shared boundary - still no refactors, no unrelated scope.\n",
  );
  say("- After editing and before verifying, SELF-TRACE: re-walk each finding's failing sequence AND the ordinary path through every changed function and its callers, deleting what the fix made unreachable.\n");
  say("- Commit to the crew branch. Do NOT push - the pipeline owns push.\n");
  say(`- When done print: done: fixed ${nfix} findings\n`);
  say(`- The run stays HELD at ${step} and re-runs on your diff; earlier completed steps do not re-run.\n`);
}

// `"$rd/findings/"*.json` in byte order: dotfiles are never matched.
function findingsGlob(rd: string): string[] {
  try {
    return readdirSync(B(`${rd}/findings`), { encoding: "buffer" })
      .map((n) => Buffer.from(n).toString("latin1"))
      .filter((n) => !n.startsWith(".") && n.endsWith(".json"))
      .sort((x, y) => Buffer.compare(B(x), B(y)))
      .map((n) => `${rd}/findings/${n}`)
      .filter(exists);
  } catch {
    return [];
  }
}

function cmdStatus(): void {
  requireRun();
  const rd = runDir();
  say(`run: ${basename(rd)}\n`);
  ee(run(["sed", "s/^/  /", `${rd}/run.meta`], { stdout: "inherit" }).status);
  if (isFile(`${rd}/override`)) ee(run(["awk", "-F\\t", '{ printf "override: %s at=%s receipt_sha256=%s reason=%s\\n", $1, $2, $3, $4 }', `${rd}/override`], { stdout: "inherit" }).status);
  say("steps:\n");
  ee(run(["awk", "-F\\t", '{ printf "  %-10s %-18s %s\\n", $1, $2, ($3 + 0 > 0 ? "fix-rounds=" $3 : "") }', `${rd}/steps.tsv`], { stdout: "inherit" }).status);
  for (const f of findingsGlob(rd)) {
    const n = basename(f);
    if (f.endsWith(".meta.json")) say(`meta ${n.slice(0, -".meta.json".length)}: ${cap(run(["jq", "-r", 'keys | join(" ")', f]).out)}\n`);
    else say(`findings ${n.slice(0, -".json".length)}: ${cap(findingsSummary(f).out)}\n`);
  }
}

function finishGate(rd: string, outcome: string): void {
  const o = run(["awk", "-F\\t", '$2 != "completed" && $2 != "skipped" { printf "%s(%s) ", $1, $2 }', `${rd}/steps.tsv`]);
  ee(o.status);
  const outstanding = cap(o.out);
  if (outstanding !== "")
    fail(`finish ${outcome} refused (fail-closed): pipeline steps not completed: ${outstanding.replace(/ $/, "")} - complete or --skip them, or finish failed/cancelled`);
  let resid = "";
  for (const f of findingsGlob(rd)) {
    if (f.endsWith(".meta.json")) continue;
    const step = basename(f).slice(0, -".json".length);
    const r = run(["jq", "-r", '[.[] | select(.action == "fix" or (.action == "ask-user" and ((.decision // "") | tostring) == ""))]\n                   | map((.id // "?") + "[" + (.action // "?") + "]") | join(", ")', f], {
      stderr: "ignore",
    });
    const bad = r.status === 0 ? cap(r.out) : `UNREADABLE (${step} findings file is corrupt or not valid JSON)`;
    if (bad !== "") resid = `${resid}${resid ? "; " : ""}${step}: ${bad}`;
  }
  if (resid !== "") fail(`finish ${outcome} refused (fail-closed): unresolved findings - ${resid} (fix the fix-findings, or record a captain decision on the ask-user ones)`);
  assertReviewCurrent(rd, `finish ${outcome}`);
  if (outcome !== "passed") return;
  const t = sedFirst(`${rd}/run.meta`, "s/^target=//p", "ignore");
  ee(t.status);
  const dref = t.out || b8(defaultRef(u8(repo), true));
  if (git(["merge-base", "--is-ancestor", "HEAD", dref], { stderr: "ignore" }).status !== 0)
    fail(`finish passed refused (fail-closed): HEAD is not merged into ${dref} - use checks-passed for a raised-but-unmerged PR; passed records a MERGED run`);
}

function cmdFinish(a: string[]): void {
  requireRun();
  const outcome = a[0] ?? "";
  if (!["checks-passed", "passed", "failed", "cancelled"].includes(outcome)) fail("usage: ac-ship.sh finish <checks-passed|passed|failed|cancelled>");
  const rd = runDir();
  const validated = outcome === "checks-passed" || outcome === "passed";
  if (validated) finishGate(rd, outcome);
  if (isFile(`${rd}/review.pane`)) {
    const helper = process.env.AC_PANE_AGENT ? b8(process.env.AC_PANE_AGENT) : `${binDir}/ac-pane-agent.sh`;
    if (can(helper, fsc.X_OK)) run([helper, "close", "--pane", cap(readText(`${rd}/review.pane`) ?? "")], { stdout: "ignore", stderr: "ignore" });
    rm(`${rd}/review.pane`);
  }
  if (isFile(`${rd}/watch.pane`) && commandV("herdr")) {
    const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
    run(["herdr", "--session", ses, "pane", "close", cap(readText(`${rd}/watch.pane`) ?? "")], { stdout: "ignore", stderr: "ignore" });
    rm(`${rd}/watch.pane`);
  }
  ee(append(`${rd}/run.meta`, `outcome=${outcome}\n`));
  ee(append(`${rd}/run.meta`, `finished_at=${iso()}\n`));
  let kinds = "";
  if (validated) {
    kinds = overrideKinds(rd);
    if (kinds !== "") ee(append(`${rd}/run.meta`, `attestation=passed-with-override:${kinds}\n`));
  }
  const id = basename(rd);
  say(`run ${id}: ${outcome}${kinds ? ` (passed-with-override: ${kinds})` : ""}\n`);
  if (outcome !== "checks-passed") return;
  const pr = run(["awk", "-F\\t", '$1 == "pr" { print $2 }', `${rd}/steps.tsv`]);
  ee(pr.status);
  const suffix = kinds ? ` - passed-with-override: ${kinds}` : "";
  if (cap(pr.out) === "completed") say(`checks-passed: ${id} PR raised, awaiting the captain's merge${suffix}\n`);
  else say(`checks-passed: ${id} validated, no PR raised (pr step ${cap(pr.out)}) - awaiting the captain${suffix}\n`);
}

// --- entry ------------------------------------------------------------------------

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  say(b8(`${head.join("\n")}\n`));
  return fatal(2);
}

function main(argv: string[]): void {
  backendName();
  require("git", "jq");
  binDir = b8(STARTED_BIN);
  const top = run(["git", "rev-parse", "--show-toplevel"], { stderr: "ignore" });
  if (top.status !== 0) fail("not inside a git repo");
  repo = cap(top.out);
  vdir = `${repo}/.crew/ship`;
  current = `${vdir}/current`;
  const [verb = "", ...a] = argv;
  switch (verb) {
    case "start":
      return cmdStart(a);
    case "step":
      return cmdStep(a);
    case "findings":
      return cmdFindings(a);
    case "meta":
      return cmdMeta(a);
    case "cmd":
      return cmdCmd(a);
    case "attest-test":
      return cmdAttestTest();
    case "attest-check":
      return cmdAttestCheck();
    case "push":
      return cmdPush();
    case "base": {
      const b = freshBase("", true);
      if (b === null) fatal(1);
      return say(`${b}\n`);
    }
    case "evidence-dir":
      return cmdEvidenceDir();
    case "skip-remaining":
      return cmdSkipRemaining();
    case "config": {
      const r = cmdConfig(a);
      say(r.out);
      return ee(r.status);
    }
    case "fix-report":
      return cmdFixReport(a);
    case "review-agent":
      return cmdReviewAgent(a);
    case "review-residual":
      return cmdReviewResidual(a);
    case "status":
      return cmdStatus();
    case "finish":
      return cmdFinish(a);
  }
  usage();
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  let rc = 0;
  try {
    main(args.map(b8));
  } catch (e) {
    if (typeof (e as Exit).exit !== "number") throw e;
    rc = (e as Exit).exit;
  }
  process.exit(rc);
}
