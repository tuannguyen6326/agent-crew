// qa.ts - the qa pipeline's state machine and deterministic runner
// (behavioral verification with evidence, the ac-ship model applied to QA).
// The entry is bin/ac-qa.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-qa.sh as the oracle the
// differential leg of tests/sh/ac-qa.test.sh holds this module to.
//
// Run from inside the target repo/worktree being verified. State lives at
// <repo>/.crew/qa/<run-id>/ with a `current` symlink; durable and resumable
// after a pane restart.
//
// Usage:
//   ac-qa.sh start --target <ref> [--task <id>] [--evidence <dir>] [--store <dir>]
//                                 [--home <abs>]
//                                 [--scope <name> --app <name>]
//   ac-qa.sh step <name> <status> [--note <text>]
//                                         (baseline and serve are OWNED
//                                          transitions; see BOUNDARY POLICY)
//   ac-qa.sh baseline                     (validate the FROZEN ship test
//                                          receipt; never runs a suite)
//   ac-qa.sh boundary-run --case <id>
//            --boundary <http|grpc|client-cli|workflow|queue|schedule>
//            --evidence <path> -- <command> [args...]
//                                         (drive the booted deliverable from
//                                          OUTSIDE its process; stdout is the
//                                          published receipt path)
//   ac-qa.sh boundary-register --case <id> --boundary web
//            --transcript <path> --visual <path>
//   ac-qa.sh boundary-register --case <id> --boundary e2e
//            --upstream-receipt <path> --evidence <path>
//   ac-qa.sh case <case-id> <pass|fail|unverifiable> --tier <api|db|workflow|web>
//            [--boundary <b> --receipt <path>]
//                                         (REQUIRED on pass/fail; see
//                                          BOUNDARY POLICY)
//            [--classification <defect|flaky|test-maintenance|environment>]
//            [--confidence <0..1>] [--grade <A|B|C|D>] [--evidence <path>]
//            [--note <text>]              (the park's REASON; see INFRA
//                                          CONTAINMENT)
//            [--authority <text>] [--repro <path>]
//                                         (REQUIRED on `fail
//                                          --classification defect`; see
//                                          FINDING AUTHORITY)
//   ac-qa.sh visual <path> [--case <id>] [--note <text>]
//                                         (register a VISUAL artifact; see
//                                          VISUAL EVIDENCE)
//   ac-qa.sh findings <step>              (JSON array on stdin, ac-ship schema:
//                                          id,severity,action,file,line,description,
//                                          authority_class,authority;
//                                          refuses a tty)
//   ac-qa.sh findings <step> --show       (print stored findings, writes nothing)
//   ac-qa.sh testplan-amend --case <id> [--case <id> ...]
//                  --authority <behavioral-authority> --reason <why>
//   ac-qa.sh fixture <pack-id> --selector <selector>
//                  --case <case-id> [--case <case-id> ...]
//   ac-qa.sh harness-classify <path>
//                  --classification <repo-regression|e2e-regression|fixture-pack|
//                                    evidence-only|retire>
//                  --target <suite-or-store> --invariant <behavior>
//                  --evidence <path>
//   ac-qa.sh regression-proposal <patch>
//   ac-qa.sh curation <completed|skipped|failed> [--note <reason>]
//   ac-qa.sh store-install <curation-candidate-dir>
//   ac-qa.sh store-curate --candidate <dir> [--promote-after <n>]
//                                         (pane side, at curation: append this
//                                          run's case rows to the candidate
//                                          store's history and promote cases
//                                          that passed <n> consecutive runs;
//                                          see QA STORE LEARNING LOOP in
//                                          tests/fixtures/ac-qa-lib.sh)
//   ac-qa.sh store-label <case-id> --run <sha> <confirmed|not-a-defect> [--by <who>]
//                                         (chief side: the human's word on a
//                                          defect the pane classed)
//   ac-qa.sh store-calibration            (chief side: Cohen's kappa between
//                                          the pane's defect calls and the
//                                          chief's labels, written beside the
//                                          store)
//   ac-qa.sh infra <detect|up|down|status|reap> [--services <a,b,...>] [--task <id>]
//     detect = scan the repo for needed profiles (postgres/redis/temporal);
//     up with NO --services (and no qa.infra) boots NOTHING - a service that
//     needs no backend never pulls infra it will not use;
//     the FIRST up DECLARES the run's need - a wider later up is REFUSED
//     (see INFRA CONTAINMENT).
//   ac-qa.sh store-dir                    (resolve + create the per-project QA
//                                          knowledge store; see KNOWLEDGE STORE)
//   ac-qa.sh serve                        (boot qa.serve under the minimal env)
//   ac-qa.sh health                       (bounded readiness poll of qa.health)
//   ac-qa.sh seed                         (run qa.seed once, after health)
//   ac-qa.sh cmd e2e --cases <id>[,<id>...] (config-resolved runner, minimal
//                                             env, durable execution receipt)
//   ac-qa.sh evidence-dir
//   ac-qa.sh config <dotted.key>          (fleet-home config, frozen at start)
//   ac-qa.sh config-proposal [--id <id>]  (stage a uniquely named config draft)
//   ac-qa.sh config-install <id>           (chief-only conflict-safe install)
//   ac-qa.sh fix-report                   (markdown handoff for a fixer crewmate)
//   ac-qa.sh relay-report [--repo <dir>]  (markdown handoff for the CALLER, who
//                                          is in another worktree; see RELAY
//                                          CONTRACT)
//   ac-qa.sh fetch-check <url>...         (HTTP-GET each embedded visual URL,
//                                          refuse on any non-200; see RELAY
//                                          CONTRACT)
//   ac-qa.sh agent --target <ref> --task <id> [--evidence <dir>] [--brief <path>]
//                  [--home <abs>] [--scope <name> --app <name>]
//                  [--qa-rule <number|default>] [--ship-run <run-id>]
//   ac-qa.sh status
//   ac-qa.sh finish <passed|failed|unverifiable|cancelled>
//                   [--retry-reason <context-limit|tool-limit|capability-limit>]
//
// EXECUTION SURFACE (captain's rule): qa always runs through `agent`, a policy
// adapter over `ac-verify qa`, NEVER inside the implementing crewmate and never
// inline in the orchestrator. The facade prepares a fresh exact-ref lease and
// pane per round, preserves only structured result history, exports verdict,
// run state, artifacts, and relay-report before normal reap, and preserves
// invalid/timeout state for recovery. QA owns no reviewer session, pane
// replacement, headless fallback, or duplicate lifecycle.
//
// PROFILE RESOLVE (authoritative - the fail-closed preflight `agent` runs BEFORE
// ac-verify leases a worktree or spawns a pane): it compiles + validates +
// FREEZES one immutable runtime bundle from the project config
// (ac_project_config_file), repo-knowledge scope/app membership
// (ac_knowledge_scopes), the selected QA-store files, and any caller-selected
// panes.qa routing receipt. It hands <bundle>/profile.json to ac-verify with
// --profile. Covers single-repo (flat + scoped) AND the separate-E2E dual-ref
// case: when qa.e2e.repo is configured, the profile also freezes an `e2e` block
// (the resolved LOCAL clone path, the exact E2E SHA chosen by ref_policy, the
// product workdir, the E2E command, and the explicit endpoint-env map). See
// SEPARATE E2E REPOSITORY below.
// The frozen profile records the sha256 of BOTH durable sources
// (provenance.project_config_sha256 + repo_knowledge_sha256), the exact source
// ref, and its OWN canonical hash (top-level profile_sha256, over the concrete
// execution values + durable-source hashes + exact source/E2E refs, EXCLUDING
// volatile allocation paths and the resolve timestamp). Fixture/resolver
// references are stored by NAME only - a raw secret value never enters it. The
// bundle is assembled under a unique temporary directory, validated, and
// atomically published at <repo>/.crew/qa/agent-<task>-r<N>.profile/ with
// profile.json, config.yaml, scopes.tsv, a hash-bound store/ manifest, and
// ship/test-receipt.env - the frozen exact-SHA ship test receipt named by
// --ship-run (BOUNDARY POLICY). The canonical profile hash covers its snapshot
// entry, so a repaired ship receipt requires a fresh profile and a fresh pane,
// and a change to any frozen source between freeze and spawn is profile-stale.
// The preflight returns exactly one structured status and, for any non-ready
// status, spawns NO verifier pane (the return precedes the ac-verify call):
//   profile-ready    complete, current, safe, frozen -> spawn the verifier.
//   needs-profile    a durable source is absent (no project config, or the flat
//                    service contract / a scoped config block is missing).
//   profile-conflict the two durable sources disagree (mode mismatch, an
//                    undeclared config scope block, an ambiguous scope map, or a
//                    named scope/app absent from the closed membership list).
//   profile-stale    a durable source changed between freeze and spawn (a frozen
//                    hash no longer matches) - abort and re-resolve.
//   ask-user         a credential/secret-resolver decision is not mechanical
//                    (a declared qa.fixtures.resolver with no authorized
//                    qa.fixtures.profile) - hold for the chief to relay.
// A caller-argument error (a flat project given --scope/--app, or a scoped
// project with neither named) is refused fail-closed too, but is not one of the
// five statuses: its remedy is to fix the invocation, not the durable sources.
//
// Steps (fixed order):
//   pin testplan baseline infra serve cases e2e evidence verdict
// Step statuses: pending running fixing completed skipped failed
// Environment/infra step failures HOLD the run (resume re-runs the held step);
// CASE failures are findings and ledger rows, never a run abort - the run
// collects every case result before the verdict.
//
// BOUNDARY POLICY (authoritative - every other mention points HERE by name;
// QA boots the service and checks behavior through the
// client/API/integration boundary, and QA never runs or re-runs unit tests).
// WHAT A QA ROUND MAY BUILD ITS VERDICT FROM:
//  - THE BOUNDARY RULE. Every behavioral case exercises the BOOTED deliverable
//    from OUTSIDE its process, through one closed set of client boundaries: an
//    HTTP/gRPC request against the served endpoint (an SDK or CLI acting only as
//    its client counts), a queue message / workflow signal / scheduled trigger
//    consumed by a RUNNING worker, a real browser driving the served UI, or the
//    approved E2E suite. Database, cache, and event-history reads are ASSERTION
//    surfaces for behavior stimulated that way - never the stimulus. A case
//    whose only stimulus is a direct DB write, or a service object constructed
//    inside the QA harness process (dependency-injection recipes included), is
//    NOT behavioral evidence: it is `unverifiable` with an `ask-user` finding
//    naming the missing boundary, never an in-process substitute.
//  - TIERS, closed: api | db | workflow | web. The tier names the client
//    boundary that stimulated the behavior plus the PRIMARY assertion surface;
//    when one stimulus proves both a response and a durable delta, pick the
//    tier of the primary assertion. `integration` is deliberately NOT a tier -
//    under this policy every case is integration-level by construction, so a
//    catch-all would carry no information. `unit` is not a QA execution tier:
//    it is refused at record time and again at finish against a forged row. QA
//    may still AUTHOR a non-executed, test-only unit regression PROPOSAL -
//    execution lands it and the SHIP pipeline runs it; it cannot satisfy the
//    current round.
//  - FROZEN COVERAGE LADDER. The exact `## Coverage` and `## Full Flow`
//    declarations in testplan.md freeze as
//    <run>/testplan-manifest.json (`agentcrew.qa-testplan-manifest/v1`) when
//    `testplan` completes. Every case-producing command refuses before that
//    point. A `ut` coverage row cites a regular test blob in the exact target
//    Git tree and creates no QA case; it is admissible only when the frozen
//    exact-SHA ship receipt qualifies. `it` maps to a passing
//    api|db|workflow case; `e2e` maps to a passing web case or a case carrying
//    the existing E2E wrapper receipt. The ship receipt remains informational
//    when no `ut` row exists, so coverage selection - never model dispatch -
//    decides whether it gates.
//  - FULL-FLOW FINAL GROUP. At least one IT/E2E-mapped case is declared as the
//    assembled flow. Every declared case must pass and the minimum effective
//    full-flow receipt started_at must be >= the maximum effective non-flow
//    receipt completed_at. A late component retry therefore re-runs and rebinds
//    the final group. Selection may change by authority only before any case,
//    boundary, fixture, or E2E evidence exists.
//  - RUNTIME BOOT RECEIPT. `serve=completed` is not proof by itself, so `serve`
//    is an OWNED transition: `ac-qa.sh serve` boots the frozen qa.serve command,
//    freezes the runtime descriptor (the resolved endpoint/worker mapping every
//    boundary driver runs under), records the provisional launch, and makes the
//    step completed - a direct `step serve completed` REFUSES. `health` stays a
//    COMMAND and owns no step; its proof is <run>/runtime/receipt.env
//    (agentcrew.qa-runtime-receipt/v1), which only a zero-exit probe against a
//    still-live process group can publish. There is NO re-issue path inside one
//    round: a restart would detach every case already recorded from the runtime
//    it exercised, so `serve` refuses once a receipt exists and the round
//    finishes honestly instead.
//  - CLIENT-BOUNDARY EXECUTION RECEIPTS. Every pass/fail case binds one
//    immutable <run>/boundaries/<case-id>/<ts>-<pid>.env
//    (agentcrew.qa-boundary-receipt/v1) hash-bound to that boot receipt.
//    `boundary-run` executes a shell client under the minimal env plus ONLY the
//    frozen descriptor's mapping, publishes a receipt even on non-zero exit, and
//    returns the driver's code (its stdout is the receipt path, so a case
//    composes: `--receipt "$(ac-qa.sh boundary-run ... -- <cmd>)"`).
//    `boundary-register` wraps the two drivers this module did not run: a real
//    browser (transcript + visual, registered BEFORE the final case row exists)
//    and the existing immutable `cmd e2e` receipt (valid only when it NAMES the
//    case and matches the frozen source/E2E/profile/command). Tier/boundary
//    coherence, case identity, runtime identity, and `pass => exit 0` are
//    checked at RECORD time and again at the gate, so a hand-forged ledger row
//    meets exactly the check that admitted the honest one.
//  - BASELINE IS A RECEIPT CHECK, NEVER A RE-RUN. Unit-suite health belongs to
//    the ship pipeline exclusively (src/ship.ts's SHIP TEST RECEIPT block).
//    `agent --ship-run <id>` freezes that run's exact-SHA receipt into
//    <bundle>/ship/test-receipt.env before the verifier lease exists - the
//    mutable ship `current` symlink is never consulted, and every non-qualifying
//    shape (omitted flag, missing run, another target, interrupted, non-zero)
//    normalizes to one closed reason. `ac-qa.sh baseline` owns the step
//    transition (a direct `step baseline completed|skipped` REFUSES), records
//    `qualifies:<reason>` or `not-qualifies:<reason>`, and on the latter files
//    no finding. The state is report-only when no UT mapping exists. When the
//    frozen manifest selects UT, `testplan completed` and the pass gate require
//    `qualifies:<reason>` for the exact source SHA; otherwise the affected AC
//    escalates to IT. A repaired receipt is visible only to a fresh round.
//  - READY RUNTIME IS MANDATORY FOR A PASS. `finish passed` requires
//    serve=completed, a valid boot receipt whose process group is still alive,
//    every passing case bound to that receipt, and - after every other
//    invariant holds and before any teardown - a final live-process check plus a
//    re-run of the frozen health probe, published as an immutable
//    agentcrew.qa-runtime-gate/v1 under <run>/runtime/gates/ with
//    <run>/runtime/gate.current pointing at it. Post-teardown reconciliation
//    (ac-verify.sh) validates THAT record; it never asks a normally terminated
//    process to still be alive. `step serve skipped` stays a valid recording
//    operation and remains compatible with failed|unverifiable|cancelled - it
//    can never satisfy a pass. A standalone CLI-only product has no long-lived
//    booted runtime and is OUTSIDE this passing policy (`unverifiable`), never
//    represented by a fake background command.
// The validators are shared, in src/qa-lib.ts (qaShipReceiptStatus,
// qaRuntimeReceiptValidate, qaRuntimeGateValidate, qaBoundaryCoherent,
// qaBoundaryReceiptValidate, twins of tests/fixtures/ac-qa-lib.sh), because three
// actors must agree byte-for-byte: this module records and gates, ac-verify.sh
// reconciles the exported run, and the merge gate reads what they published.
// WHAT THIS DOES NOT PROVE: that arbitrary command text is semantically a good
// test. The mechanism proves an approved driver ran against the recorded ready
// runtime and produced the registered artifacts; rejecting in-process
// construction dressed as a client call stays the verifier's and the captain's
// reading, exactly like INFRA CONTAINMENT and FINDING AUTHORITY below.
//
// TRUSTED CONFIG (unattended-safety): a profiled `start` validates and consumes
// the fixed .crew/qa/profile-runtime/ bundle into <run>/profile/ and uses only
// its config.yaml, scopes.tsv, store/, and profile identity. It never re-reads
// live fleet config or repo knowledge. Direct unprofiled diagnostics retain the
// legacy snapshot behavior. The durable config source is captain-owned and
// branch-immune by LOCATION; the project repo is never a config source.
//
// TARGET-CHECKOUT BINDING (authoritative - every other mention points HERE by
// name): the pass marker is keyed by target_sha, so the checkout the cases
// exercise MUST BE that commit - never merely claimed to be. `start` refuses,
// before it mints any run dir, unless the repo's actual HEAD (`git rev-parse
// HEAD`) resolves to target_sha; `finish passed` RE-PROVES it, before the
// outcome rewrite, so a HEAD that drifted mid-run mints no pass. Both name both
// shas on a mismatch. A DIRTY tree is refused the same way (the exercised code
// is then no commit at all) - but only tracked-file changes count: untracked
// and the sanctioned .crew/ pool artifacts are ignored (`git status -uno`, the
// ac-sync model). A status that cannot be READ is refused too, never taken for
// clean: an unreadable tree is not evidence of a committed one, and this guard is
// what stands between a qa pass and a run that exercised something else.
// EXEMPTION: a verifier round running inside this same lease stubs CLAUDE.md /
// AGENTS.md (ac-verify's context neutralization) and records exactly which
// paths plus the exact stub bytes at .crew/qa/neutralized-manifest and
// neutralized-stub; a tracked-file modification is exempt ONLY when its path
// is in that manifest AND its current content is still byte-identical to the
// recorded stub - a path absent from the manifest, a manifest absent entirely,
// or a neutralized path whose content has since changed all still refuse.
// In production the `agent` verb runs from a fresh pool worktree
// detached at the target, so HEAD == target_sha by construction; this guard is
// what makes that a proof, not a convention.
//
// INFRA (docker, unattended-safe): compose profiles ship with the crew-qa skill
// (assets/compose.yaml: postgres, redis, temporal dev-server, wiremock).
// Everything is task-scoped: compose project `crew-qa-<repo>-<task>`, no
// container_name, no fixed host ports (readback via `docker compose port`
// into <run>/ports.env). A project override (config qa.mocks_compose) is
// LINTED before use: external volumes, host bind mounts, container_name,
// docker.sock, privileged, network_mode host all fail closed. `down` is
// label/project-scoped only; `reap` sweeps crew-qa-* projects whose state
// dir is gone (wired into ac-teardown.sh / ac-session-start.sh). Cleanup
// never touches containers this tool did not create.
//
// INFRA CONTAINMENT (authoritative - every other mention points HERE by name): a
// run DECLARES its infra need ONCE, and nothing outside that declaration ever
// boots. The FIRST `infra up` writes its requested list to <run>/infra.declared;
// a later `infra up` naming a service outside it is REFUSED, before docker runs,
// so a case that discovers a missing service mid-run PARKS with the reason
// (`case <id> unverifiable --classification environment --note <why>`) instead of
// silently widening the stack. Booting what the cases never touch is not free:
// slower boots, resource conflicts, flakier runs, noisier failures.
// A REPEAT or a SUBSET of the declaration SUCCEEDS. Infra failures HOLD the run
// and a resume re-runs the held step verbatim, so a once-only guard would break
// resume; the refusal fires on WIDENING only.
// THE SPLIT (the load-bearing design decision): this SCRIPT enforces CONTAINMENT
// (what BOOTS), the crew-qa SKILL owns DECLARATION (which services the run needs
// and WHY - the testplan's `## Infra` block). `infra up --services <list>` IS the
// declaration act: an execution this module observes, which is the only thing it
// can enforce. The testplan is agent-authored markdown in AC_HOME, outside the
// repo under test; parsing it to check "did each service get a why" would be an
// honor claim dressed as attestation by execution - the same reason the RELAY
// CONTRACT below is deliberately not fail-closed.
// What this does NOT prove: the declaration is whatever the first `infra up`
// asked for - never checked against the testplan, the diff, or the real need. A
// run that over-declares is contained to a list it over-declared, and a run that
// declares nothing simply boots nothing. This bounds WIDENING mid-run, nothing
// more; the skill's declaration gate and the captain's review are what keep the
// list itself honest.
//
// MINIMAL ENV: serve/seed/e2e run under `env -i` + PATH/HOME/LANG + the
// generated <run>/ports.env (QA_BASE_URL, QA_PORT, QA_PG_URL, ...) - the
// ambient shell env (tokens, cloud keys) never reaches the target service.
//
// VERDICT AND COMPLETION: the pane records an outcome, but durable run.meta is
// the sole exported-verdict authority. Before `passed` changes the outcome or
// publishes a marker, qa_finish_gate requires every fixed step terminal,
// actionable findings resolved, a hash-valid test plan, a completed serve step
// with a live valid runtime boot receipt, a qualifying frozen ship test
// receipt, every unique passing case graded with in-root durable evidence AND a
// coherent boundary receipt bound to that runtime, every web case linked to a
// valid visual, any completed E2E step backed by its exact-ref receipt, and
// finally a freshly published runtime gate receipt (BOUNDARY POLICY). A passing
// profiled run publishes a parser-validated agentcrew.qa-attestation/v2 marker
// through a unique temporary file plus atomic rename; an unprofiled diagnostic
// pass writes no merge marker. Non-passing outcomes remain recordable. The
// verifier facade reconciles the run, atomically publishes canonical report.md,
// and keeps relay-report.md as a separate transport checklist.
// finish ALWAYS tears down the serve process group + infra and emits:
//   QA_VERDICT= QA_TOTAL= QA_PASSED= QA_FAILED= QA_UNVERIFIABLE= QA_FLAKY=
//   QA_VISUALS= QA_REPORT= QA_RUN_ID= SERVICE_LAUNCHED=
//
// VISUAL EVIDENCE (fail-closed): EVERY run owes >=1 portable visual artifact -
// normally a screenshot of the test report - even when every case is api/db.
// `visual <path> [--case <id>] [--note <text>]` registers one into
// <run>/visuals.tsv (path, kind, bytes, case, at, note; locked read-modify-write
// like cases.tsv, last write per PATH wins so a re-shot screenshot updates its
// row instead of double-counting). It is admitted only after its MAGIC BYTES say
// png/jpeg/gif/webp - the extension is never consulted, so `touch shot.png`
// cannot mint a pass - and a `--case` link must already be in the ledger.
// The gate RE-READS every row at finish: a row whose file is gone, or no longer
// the kind it claimed, does not count. Registration-time validation alone would
// let a screenshot registered from a temp dir that is later cleaned mint a pass
// whose evidence page links a dead file.
// `finish passed` REFUSES with zero valid visuals, and REFUSES on an empty case
// ledger (a run that recorded no case verified nothing). Both guards sit before
// the run.meta rewrite, so a refusal leaves outcome=running and mints no pass
// attestation - ac_qa_gate_ok never sees a lie. `step evidence completed`
// refuses too, while the live stack is still UP (ergonomics only: finish tears
// down serve+infra BEFORE its guards, so a refusal there costs a whole re-run;
// `step evidence skipped --note <why>` is the escape, exactly as `step review
// skipped` bypasses ac-ship.sh's review.agent gate).
// What this does NOT prove: only the first 3-12 bytes are read and no decoder
// runs, so ANY file carrying a valid signature passes - a 1x1 png, or a real
// screenshot of the wrong thing. The floor is auditability - one artifact per
// RUN, deliberately asserted - not proof of behavior; the crew-qa skill owns
// what a picture must SHOW (and still requires a screenshot per web case). Rows
// never carry across runs: each re-run captures its own.
//
// FINDING AUTHORITY (authoritative - every other mention points HERE by name):
// asserting a DEFECT is the act that turns a statement into a fixer's work, so
// it is the act this module binds. `case <id> fail --classification defect` is
// REFUSED without both:
//   --authority <text>  WHO states the case's EXPECTED behaviour and WHERE - a
//     file:line, a URL, or `captain <date>`. A bare document name is not a
//     citation; a line number is the cheapest evidence the author opened it.
//     With nothing citable the case is `unverifiable --note '<why>'`, never a
//     defect - and the refusal NAMES that remedy, like the INFRA CONTAINMENT one.
//   --repro <path>      an EXECUTABLE reproduction carrying two non-empty header
//     lines, `# DISPUTED: <the one variable under dispute>` and
//     `# HELD-CONSTANT: <everything the two legs share, named>`. Missing,
//     non-executable, or either header absent/empty is refused.
// Both land in cases.tsv as APPENDED columns ($9 authority, $10 repro), so every
// existing awk -F'\t' index stays valid and pre-change rows render as "-".
// THE SPLIT (deliberate, not an omission): a machine can check that the
// reproduction EXISTS, is executable, and DECLARES its controls. It cannot check
// that the declaration is TRUE - deciding whether a script varies more than one
// variable is not decidable in general. Comparing the two headers against the
// script body is therefore a named READING step in the code-review brief and in
// the crew-qa skill's adversarial checklist, not a check here. Same honest split
// as INFRA CONTAINMENT: enforce the executed act, leave the judgment to a reader.
// Findings (`findings <step>`) carry the same contract on their own wire via
// ac_findings_normalize - see src/ship.ts's Findings JSON block.
//
// RELAY CONTRACT (authoritative - every other mention points HERE by name): qa
// writes to `data/<family>/qa/` ONLY. It never posts to the PR, the room, or the
// captain, and it never merges; staying off those surfaces is what keeps the
// verdict independent. Whoever CALLED qa relays it outward, and carries the
// EVIDENCE, not just the verdict: the QA_* envelope, the case table, the on-disk
// report, and every registered visual EMBEDDED in the PR comment (private-repo
// recipe: crew-qa skill), each one run through `fetch-check <url>...` first -
// a URL that never serves is a 404 the captain would otherwise discover
// themselves. Plus the CORRECTION DUTY - any claim in the PR body
// this run supersedes ("not run", "verified statically only", "tests pending")
// MUST be corrected in the SAME relay; a stale validation claim left standing is
// a lie the crew told the captain. `relay-report [--repo <dir>]` renders the
// contract from the finished run's own state (the fix-report shape: a contract
// for another actor, rendered from state only this module holds); aim it with
// --repo, since qa ran in a worktree the caller is not standing in.
// NOT fail-closed, deliberately: the relay lands on surfaces (gh, ac-room.sh)
// this module cannot observe, and a marker the crewmate asks for would be an
// honor claim, not attestation by execution. The merge gate is where a human
// still checks. Contrast VISUAL EVIDENCE, which this module CAN enforce (it owns
// cmd_finish and the attestation it mints) and therefore must.
//
// Config keys (qa.*): serve, health, health_timeout, seed, e2e.command,
// e2e.repo, e2e.ref_policy, e2e.workdir, e2e.endpoint_env (map),
// e2e.fixture_profile, infra (agent-read list), mocks_compose.
// `cmd` exit codes: the command's own; 4 = not configured.
//
// SEPARATE E2E REPOSITORY (authoritative - the dual-ref path; every other
// mention points HERE by name): a qa.e2e.repo turns this profile into a dual-ref
// run whose E2E suite lives in its OWN repository at an exact frozen SHA.
//  - RESOLVE (cmd_agent): qa.e2e.repo resolves via ac_project_dir to a LOCAL
//    clone (a project name under $AC_HOME/projects, or a path) - an EXTERNAL
//    actor that must already exist; an absent clone is needs-profile. The exact
//    E2E SHA comes from qa.e2e.ref_policy (only configured-default-branch-head:
//    the local clone's default-branch head), frozen into the profile's e2e block
//    with workdir (scope-level, repo-level fallback, default `.`), command
//    (repo-level, scope override), endpoint_env (name->runtime-ref map), and
//    fixture_profile (reference name).
//  - LEASE (ac-verify.sh): the facade reads the profile's e2e block and leases a
//    SECOND worktree at the exact E2E SHA, records BOTH under the plural `leases`
//    grammar (source:e2e), and releases BOTH on pass/fail/timeout/pre-spawn
//    abort. A pane does not inherit the facade's env, so the runtime E2E worktree
//    + profile identity are handed to this module through the validated
//    <source-lease>/.crew/qa/profile-runtime/ bundle. Volatile allocations live
//    only in runtime.json; `start` consumes the directory into <run>/profile/.
//  - RUN (cmd_cmd e2e): with an E2E worktree recorded, the e2e step runs from
//    <e2e-worktree>/<workdir> under the minimal env PLUS the explicit
//    endpoint-env mapping (each configured NAME receives the runtime value of
//    the reference it maps to, e.g. BASE_URL <- $QA_BASE_URL), and REFUSES an
//    undeclared developer .env in that workdir (a personal .env is never an
//    approved credential source). A bundle with an empty E2E worktree runs the
//    approved command in the source repo (single-repo behavior unchanged).
//  - ATTEST (cmd_finish): the pass marker BODY binds source_sha, e2e_repo,
//    e2e_sha, and profile_sha256 (empty dual-ref fields are omitted, so a flat
//    marker keeps its lean shape). The gate still keys off the marker FILENAME.
//
// SCOPED CONFIG (authoritative - qa_key_path and qa_validate_selection
// implement exactly this). A monorepo's qa config is keyed by SCOPE - a group
// of apps sharing a DB schema and infra - and by APP below it. Which keys move
// below the repo is decided by ONE test: does a wrong value produce a FALSE
// GREEN? `serve` boots a different binary and `health` probes another app's
// route, so both are APP level; `seed` migrates another schema, so it is SCOPE
// level; `infra`, `health_timeout`, `mocks_compose`, `e2e.*` cost time or fail
// loudly, so they stay REPO level.
//
//   qa:
//     infra: [postgres, redis]       # REPO level, unchanged
//     scopes:
//       orchid:
//         seed: ...                  # SCOPE level (required when seed runs)
//         apps:
//           orchid-service:
//             serve: ...             # APP level (required when serve runs)
//             health: ...
//
// WHICH SCOPES EXIST is not the yaml's to say: the yaml says how to RUN a
// scope, the repo-knowledge record's `scope` entries are the CLOSED LIST of
// which ones exist (src/know.ts). Mode detection is therefore TWO-SIDED,
// and every invocation on a scoped project names BOTH the scope AND the app -
// there is no one-member inference, because an inference that is safe only
// while a fact stays true is the same stale-fact failure in another costume,
// and naming the app is what puts it in run.meta.
//
// THE PRECEDENCE CHAIN is TOTAL and ORDERED; the first hit wins, nothing below
// it runs, and no refusal ever falls back to a repo-level value, the first
// scope, or the first app:
//   parse  a repeated selector refuses naming BOTH values (identical repeats
//          included - the flag loop is last-wins by construction, which is
//          exactly the silent default this closes)
//   -1     an AMBIGUOUS map refuses at the freeze, never degrades to flat
//   0      mode detection: map declares scopes? yaml carries qa.scopes?
//          BOTH -> scoped;  EXACTLY ONE -> F8;  NEITHER -> flat.
//          The yaml side asks PRESENCE (ac_yaml_has), never "has children":
//          `scopes:` lands before the first block under it, so an EMPTY block
//          is the ordinary half-authored state, and reading it as ABSENT drops
//          the project to FLAT and runs the stale single-app profile - the
//          exact hole two-sided detection exists to close. F9 below is the
//          one that wants the child NAMES.
//   0b     a selector on a FLAT project refuses naming that the project
//          declares no scopes. This is NOT F8: F8 says "neither cleanly flat
//          nor cleanly scoped", 0b says "this project declares none at all",
//          and conflating them tells a caller their config is half-migrated
//          when they merely named a profile on a single-app repo
//   1      F9 closed list over the WHOLE file, not just the selected scope
//   2-5    F1, F2, F4, F5 - answered from the MAP alone
//   6-8    F3, F7, F6 - answered from the YAML
// Everything checkable against the declared truth is checked before anything
// is asked of the configuration, so "you named a scope that does not exist"
// never arrives disguised as "that scope has no config block". F6/F7 are
// conditional on their step RUNNING, and serve/health/seed all run under the
// one `serve` step, so that condition is a single test.
//
// THE FLEET HOME (authoritative - src/know.ts carries the identical contract,
// and one rule a crewmate can learn beats two it must tell apart): `start` and
// `agent` take `--home <abs>`, and it is the SINGLE home resolution of a run.
// BOTH sources the run needs - the project config and the scope map - descend
// from that ONE value and are FROZEN into the run dir, so the two can never
// straddle two homes; every later step reads only the frozen copies and the
// home is never consulted again.
// Ladder (ac_home_resolve, ac-lib.sh, shared with ac-know.sh): `--home` >
// $AC_HOME tested DIRECTLY > NOTHING. Rung 2 is tested directly rather than
// through ac_home(), which REFUSES when the variable is unset and would kill
// the ladder before it can answer empty.
// THERE IS NO RUNG 3. The checkout that owns bin/ is not a fleet home and is no
// longer adopted as one (closing what this block carried as
// OPEN). The two verbs answer a homeless run differently, because each already
// had its own no-home answer written before the rung was questioned:
//   start  KEEPS RUNNING. Its only home-derived inputs are the project config
//          and the scope map; the no-home answer is an empty frozen config with
//          config_source=none, plus an empty scope map, behind a notice. Both
//          reads are SKIPPED rather than left to miss - ac_home's refusal is an
//          ac_die, so running them homeless would end the process on a message
//          about AC_HOME, and ac_records_dir would mkdir records/ into the
//          checkout on the way past.
//   agent  RETURNS needs-profile. Every durable source it freezes descends from
//          the home and it has no per-source flag, so nothing can compile.
// WHY NOT PLAIN SYMMETRY WITH ac-know.sh, which REFUSES outright (@42803c6):
// the premise that kept the rung here was that ac-qa has a real homeless
// production path ac-know lacks - a pane running `start --store <baked-abs>`.
// That premise was false; ac-brief.sh bakes `--home` into every qa charter
// beside `--store`, and has since the initial release, so the rung caught only
// calls that had LOST their --home and answered them from a phantom tree.
// MEASURED before the removal: on a real checkout (no projects/<name>.yaml)
// rung 3 froze those same empty artifacts anyway, so nothing that worked
// stopped working - what it additionally did was mint records/ into the
// checkout. `start` not refusing is therefore a kept behaviour, not an
// oversight.
// Guards on `--home`: ABSOLUTE, and not inside $repo - the invariant
// ac_project_config_file states in code ("the project repo is never a config
// source... so a branch under test cannot alter commands or merge policy").
// HOW THE PATH TRAVELS: exactly as --store does, on BOTH verbs, and each verb
// has its own baked line because each has its own caller. qa panes and crewmate
// panes alike carry no AC_HOME, so the actor that HAS it bakes the path into a
// brief: ac-brief.sh's qa charter carries it for the pane's `start` line, and
// ac-brief.sh's EXECUTION brief carries a whole runnable `agent` line for the
// crewmate that calls the adapter. Two bakes, not one, because `agent` never
// reads the charter - a single bake left `agent` with no caller able to comply
// and every crewmate QA call answering needs-profile. It is a trust IMPROVEMENT
// over what it replaces: an unauthenticated ac_root fallback becomes a value
// baked by the actor that holds the authority. What it does NOT prove: --home
// is taken on trust beyond its two guards, exactly like --store.
//
// LEARNING LOOP on the store (contract: QA STORE LEARNING LOOP in
// tests/fixtures/ac-qa-lib.sh): store/history.tsv records every case row of every curated
// run; store-curate promotes a case that passed three consecutive runs with
// the same body into cases/ by machine, and re-stamps `verified:` on store
// cases that passed again; store-label records the chief's verdict on a
// defect the pane classed, and store-calibration turns the pairs into a
// kappa beside the store - the honest measure of how far the pane's defect
// calls can be trusted, computed from decisions the chief already makes.
// KNOWLEDGE STORE (qa-knowledge-reuse): per-project, durable, OUTSIDE the
// repo clone - $AC_HOME/data/qa-store/<project>/ (project = the repo scope,
// same key infra containment uses). Layout, owned here:
//   guide.md      the project TEST GUIDE: how to boot its infra, run its e2e
//                 suite, accounts/selectors/scrub rules - corrected every run.
//   catalog.md    the index the skill loads FIRST: one line per case -
//                 `- <case-id> | <surface> | <one-liner> | verified <sha> <date>`.
//   cases/<case-id>.md   one reusable case per file: surface, needs (infra),
//                 fixtures, drive steps, expected, `verified: <sha> <date>`,
//                 `status: active|retired (<reason>)`.
// STALENESS: a case is SUSPECT when `git diff --stat <verified-sha>..HEAD --
// <its surface paths>` is non-empty, or its verification is older than 30
// days - suspects are re-verified or re-derived, never silently reused.
// CURATION is part of every run (the crew-qa skill owns the mechanics): after
// the verdict, new/changed cases are recorded, failing-because-code-moved cases
// are retired with a reason, and guide corrections land - knowledge
// accumulates instead of evaporating. `store-dir` prints the store path
// (creating it), so scripts and skills share ONE path contract.
// RESOLUTION (fail-closed): store-dir's ladder mirrors evidence-dir's - an
// explicit `--store` recorded at `start` > $AC_HOME/data/qa-store/<project>
// when the caller's env carries AC_HOME > REFUSE. The absent third rung is the
// ONE deliberate departure from cmd_evidence_dir, which falls back to the run
// dir: misplaced evidence is local and visible, but a per-project durable store
// inside a disposable pool worktree is not a store. Resolving anyway is worse
// than refusing - and before ac_home() refused an unset AC_HOME (ac-lib.sh,
// "a fleet home is NAMED, never guessed"), it answered the checkout that owns
// bin/, which collapsed EVERY fleet's store into the distro tree
// and handed the agent an empty one to rebuild from scratch: the exact disease
// the store cures, now invisible instead of merely absent. The guard precedes
// the mkdir, so a refusal mints nothing.
// HOW THE PATH TRAVELS: not the environment. qa panes (ac-pane-agent.sh) and
// crewmate panes (ac-spawn.sh's AC_FLEET_MODEL/AC_FLEET_EFFORT header block) carry NO AC_HOME - only the roomchief and
// crewdeputy launch lines ride it (ac-spawn.sh's --roomchief and --crewdeputy launch lines). So the actor that HAS
// AC_HOME bakes the absolute path into the qa brief, the agent passes it at
// `start`, and run.meta holds it for every later store-dir (load at step 2,
// curate at step 10) - the same route --evidence already travels.
// What this does NOT prove: --store is taken on trust beyond being absolute.
// A path into a pool worktree is accepted and evaporates with the lease; this
// script cannot see the fleet home to check. The brief is the only defense,
// exactly as with --evidence.
//
// EVERY CALL, in order: the backend name is checked first (an AC_BACKEND or
// config/backend that is neither herdr nor orca refuses, before usage and the
// repo, outside a repo too); git and jq must be on PATH; the repo is the
// caller's cwd's `git rev-parse --show-toplevel` (else `ERROR: not inside a
// git repo`, before the verb is read); no verb or an unknown one is
// `ERROR: usage: ac-qa.sh <start|...|finish>` (thirty of the verbs), exit 1.
// Every refusal is `ERROR: <text>` on stderr, exit 1; warnings are
// `WARN: <text>`. Every run-bound verb checks `current` first.
// The mechanics stay the original's by spawning what it ran at the same
// points: every jq and awk program verbatim (each document's and ledger's bytes
// are theirs), the caller-locale `tr`/`sed` scrubs and sanitizers, git, find
// and `LC_ALL=C sort`, mktemp beside each file it stages, mv, cp, ln -sfn,
// mkdir -p, docker, curl, gh, herdr, the verifier and the dispatch selector;
// date(1) for every stamp and name, `sleep` for lock waits and the health
// poll, perl's alarm around each health probe. Every child that ran under
// `env -i` runs through /usr/bin/env -i with the same NAME=VALUE arguments.
// The serve job is the original's launcher, spawned: a subshell of
// /bin/bash --posix that turns job control on (`set -m`) and backgrounds
// `env -i ... sh -c <qa.serve>` with both fds appended to serve.log, so the
// job leads its own process group (pgid == pid) in the caller's session with
// stdin from /dev/null, and `$!` lands in serve.pid. Seed, cmd e2e and
// boundary-run's driver run as the original's own pipeline, `( cd <dir> &&
// <cmd> ) 2>&1 | tee -a <log>` inside /bin/bash --posix, their status the
// left side's; `infra up`'s service list is split and pathname-expanded by
// bash in the caller's cwd, as the original's unquoted loops did. A failure
// the original's errexit ended the run on ends it here with the failing
// command's status; where it ran a function as an `if` condition or inside
// `$(...)`, errexit sleeps there as it did.
//
// EXIT: 0; 1 every refusal and every profile status; 4 an unconfigured serve,
// health or seed; the child's own status for seed, cmd e2e (the suite),
// boundary-run (the driver) and infra down (docker); a failing tool's own
// status where the original's errexit ended on it (jq 5, awk 2, git 128);
// 128+n when a signal ends the process - no handler is registered but
// store-install's, so TERM (143) and HUP (129) end every other verb at once
// while a child runs, the child orphaned and finishing on its own.
//
// ESCAPE HATCH. A broken port stops every QA round at its first `agent` or
// `start`, every relay ac-verify asks for, and chiefs' config-install and
// store-install. If a landed change breaks this module, run the frozen
// original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   ln -s "$PWD/.agents" "$o/.agents"; cp tests/fixtures/ac-qa.sh "$o/bin/ac-qa.sh"
//   cp tests/fixtures/ac-qa-lib.sh tests/fixtures/ac-pipeline-lib.sh "$o/bin/"
// then the crewmate runs "$o/bin/ac-qa.sh" agent ... (the combined brief then
// bakes "$o/bin/ac-qa.sh start" for the pane), ac-verify's relay takes
// AC_VERIFY_QA_RELAY_BIN=$o/bin/ac-qa.sh, and chiefs run "$o/bin/ac-qa.sh"
// config-install|store-install. The `.agents` link carries the compose
// template the copy resolves through its own root. The run-dir formats are
// identical, so a round can switch implementations between verbs (the leg's
// continuation rows pin it). The captain's revert of the land is the last
// resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W3: a TERM during finish's teardown exits 143 with the verdict step done,
//   the serve group killed and serve.pid gone, but run.meta still
//   `outcome=running` and no envelope; a later `finish passed` can never pass
//   (the gate needs a live group).
// - W4: under a UTF-8 locale a non-UTF-8 byte in run.meta fails both of
//   finish's `sed -i` rewrites: exit 1, `outcome=running`, no envelope.
// - W5: the compose project name is sanitized by `tr` in the caller's locale:
//   `é` is one `-` under UTF-8 and two under C, an invalid byte truncates.
// - W6: a TERM inside serve after the fork and before serve.pid leaves a
//   group finish cannot find; after serve.pid and before launch.env it jams
//   the round (`serve already running`, health publishes no receipt).
// - W7: `health` reads qa.health_timeout raw into its arithmetic: `abc`,
//   `1m`, `08` and `3x` end it (exit 1, no probe run), `010` is 8 s, and a
//   deadline past the signed 64-bit limit wraps to one already gone (no probe
//   run, `health probe never passed`).
// - W8: store-install renames the store to `.prev` before the stage into
//   place, with no rollback between the two.
// - W9: run.meta has four writer shapes (ac_meta_set's lock, curation's,
//   testplan-amend's, and finish's unlocked `sed -i`).
// - W10: a TERM during `agent` leaves the verifier running; the next `agent`
//   is round N+1 with `--history rN.json` unvalidated.
// - W11 (named): the caller-locale scrubs (step and curation notes, visual
//   notes, testplan-amend's authority and reason, harness-classify's columns,
//   start's qa_when/qa_why) spawn the same tr and sed, so an invalid byte under
//   UTF-8 refuses exit 1 as it did, tr's own line included.
// - W13: a homeless `start` with herdr on PATH prints ac_home's ERROR beside
//   `started qa run` where the board's family lookup needs the data dir.
// - W16: the usage refusal lists thirty of the thirty-three verbs.
// - W17: the yaml reader's unquote strips one trailing quote from an unquoted
//   value.
// - W19: config-proposal reads stdin with no tty refusal, and its base read
//   swallows a legacy-path refusal into an empty base.
// - W20: curation dies through errexit holding `.curation.lock` when its awk
//   or mv fails.
// - W21: any `ac-qa-watch` pane in the herdr session suppresses this run's
//   board, and the launch line single-quotes the bin and repo paths raw.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every verb needs bun now (the shim's `ERROR: required tool not
//   found: bun`, exit 1, before anything), where the original ran most verbs
//   without it.
// - BYTES: argv and the environment arrive decoded, so a byte that is no UTF-8
//   in a flag, an id or an env value reaches the run's files and children as
//   U+FFFD, where the original kept the byte; a value read from a file keeps
//   its bytes.
// - W12: every id and charset guard (case ids, fixture packs and selectors,
//   cmd e2e's --cases, testplan-amend's --case, proposal ids, --ship-run,
//   AC_CREW_ID, --promote-after) is read per its text (ASCII ranges), where
//   bash 3.2's bracket ranges under a UTF-8 locale admitted an accented letter.
// - W14 EXCLUSIVE TEMPS: testplan-amend's run.meta.amend.<pid>, the store
//   manifest merge's <manifest>.tmp.<pid>, config-proposal's
//   proposed.yaml.tmp.<pid> and the profile hash's profile.json.tmp.<pid> are
//   created exclusively (the next name on EEXIST), where the original wrote
//   through whatever sat at the predictable name.
// - W15 and SHELL-OWN STDERR are not reproduced, the status kept: a value flag
//   with no value (`$2: unbound variable`, exit 1), `config` with no key and a
//   config present (exit 1), W7's arithmetic errors, `[`'s `integer
//   expression expected`, a failed redirection's own line, and the
//   `AC_QA_MANIFEST_ERROR: unbound variable` a staged test-plan manifest that
//   cannot be written ends `step testplan completed` and `testplan-amend` on
//   (exit 1, the temp removed, nothing published).
// - LAST PROBE: a health wait that times out after running a probe ends
//   `health probe never passed within <t>s (last probe: exit <n>[: <line>])`,
//   the line the last one wrote on stderr (at most 200 bytes), where the
//   original said only `never passed`; a wait that ran none is unchanged.
// - EXPRESSIONS: a qa.health_timeout that is a whole arithmetic expression
//   (`1+1`) rather than one operand, or an identifier naming a variable the
//   original had set (`OPTIND`), ends `health` as W7's malformed values do
//   (exit 1, no probe run), where bash evaluated it into the deadline.
// - W18: SIGINT to the pid alone ends the process at once (130), where the
//   original waited its foreground child out.
// - SIGNALS: store-install alone registers a handler - on its exit, and on
//   TERM, HUP and INT (128+n), it removes its manifest temp and releases
//   `<store>.lock`, as the original's EXIT trap did on bash 3.2. The original
//   ended at once while a child ran, the child orphaned and finishing on its
//   own; here the signal acts at the turn after that child, which completes
//   first, and before the store's next move - the original's world once its
//   orphan finished (the leg's store-install signal row). INT there ends it
//   130 after the child, where the original waited the child out and went on.
// - HOME RESOLUTION: an AC_HOME store-install cannot enter is
//   `ERROR: AC_HOME is not a readable directory: <h>`, a candidate or E2E dir
//   cd cannot enter is exit 1 with no cd line.
// - The default verifier is <this distro's bin>/ac-verify.sh by absolute path,
//   where the original joined a relative `$0`'s dirname.
// - In process, where the original started a child: the image magic bytes
//   (od), every sha256 (shasum), and src/paths.ts's within, receipt-ok,
//   realpath and free-port (started through bun); the knowledge scope map is
//   read as bytes, where the original's awk under a UTF-8 caller locale
//   aborted on a byte that is no UTF-8 (towc, exit 2) - the "read bytes"
//   precedent.
// - A relative `visual` path is tried against the caller's physical cwd,
//   where the original's `$PWD` could spell a symlinked one.
// - ORDER: findings/*.json and the run metas reap scans are listed in byte
//   order, where the original's glob followed the locale's collation.
//
// CALLERS: the qa pane agent ac-verify spawns (start, step, infra, baseline,
// serve, health, seed, case, boundary-run, boundary-register, visual, cmd,
// evidence-dir, fetch-check, findings, finish, store-curate, curation,
// relay-report, testplan-amend, fixture, harness-classify,
// regression-proposal); the execution crewmate (agent, config-proposal,
// fix-report, relay-report --repo); chiefs (config-install, store-install,
// store-label, store-calibration); bin/ac-verify.sh (relay-report --repo, a
// hard dependency), bin/ac-session-start.sh (infra reap, bounded, only 124
// read), src/teardown.ts (infra down --task, bounded, a WARN on non-zero) and
// src/brief.ts (store-dir, soft); tests/sh/ac-qa.test.sh and its leg. What it
// WRITES is read by bin/ac-verify.sh (current, run.meta, cases.tsv, the
// runtime, gate, boundary and e2e receipts, the manifest, the ship receipt
// and the passed marker), src/lib.ts's qa gate, src/merge-local.ts,
// src/pr-merge.ts, src/feature.ts and src/epic-ship.ts (the passed markers),
// bin/ac-qa-watch.sh and src/watch-dash.ts (run.meta, cases.tsv, steps.tsv,
// findings, logs, current), src/teardown.ts (the agent pane file, run.meta's
// task, watch.pane, serve.pid, current) and src/tree.ts (which removes
// <wt>/.crew/qa on a slot reset).

import { accessSync, appendFileSync, closeSync, lstatSync, openSync, readFileSync, readSync, readdirSync, readlinkSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { isatty } from "node:tty";
import {
  STARTED_BIN,
  arithValue,
  backendName,
  commandV,
  configReadSoft,
  dataDir,
  defaultBranch,
  die,
  enterCaller,
  exclusiveTemp,
  findingsNormalize,
  findingsSummary,
  herdrResolveWorkspace,
  herdrTabOpen,
  homeResolve,
  knowledgeFile,
  knowledgeScopes,
  lockAcquire,
  lockRelease,
  metaGet,
  metaSet,
  physicalDir,
  projectConfigFile,
  projectConfigName,
  projectDir,
  projectsDir,
  qaAttestationParse,
  repoRoot,
  require,
  shellStatus,
  softHome,
  spawnShellSync,
  taskDir,
  testInt,
  warn,
  windowFamily,
  writeAll,
  wsFamilyLabel,
  yamlGet,
  yamlHas,
  yamlKeys,
} from "./lib.ts";
import {
  qaBoundaryCoherent,
  qaBoundaryReceiptValidate,
  qaBrowserManifestOk,
  qaBundleValidate,
  qaCoverageValidate,
  qaPathSha,
  qaReceiptPathOk,
  qaRuntimeGateValidate,
  qaRuntimeReceiptValidate,
  qaShipReceiptStatus,
  qaStoreCalibration,
  qaStoreHistoryAppend,
  qaStorePromote,
  qaTestplanManifestRender,
  qaTestplanManifestValidate,
} from "./qa-lib.ts";
import { freePort, pyRealpath, within } from "./paths.ts";

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
const basename = (p: string): string => {
  const t = p.replace(/\/+$/, "");
  return t === "" ? (p === "" ? "" : "/") : t.slice(t.lastIndexOf("/") + 1);
};
const dirname = (p: string): string => {
  const t = p.replace(/\/+$/, "");
  if (t === "") return p === "" ? "." : "/";
  const i = t.lastIndexOf("/");
  if (i < 0) return ".";
  return t.slice(0, i).replace(/\/+$/, "") || "/";
};

type Exit = { exit: number };
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};
const fail = (msg: string): never => die(B(msg));
// `<cmd> >/dev/null` around an inner verb (baseline and serve own their step
// transition, boundary-register its visual): what it prints is dropped.
let mute = false;
const say = (s: string): void => {
  if (!mute) writeAll(1, B(s));
};
function muted(f: () => void): void {
  mute = true;
  try {
    f();
  } finally {
    mute = false;
  }
}
const tell = (s: string): void => writeAll(2, B(s));
const warnB = (s: string): void => warn(B(s));

// errexit: a failed command ends the run with its status, except where the
// original ran it as a condition or inside `$(...)` (errexit asleep there).
const ee = (status: number): void => {
  if (status !== 0) fatal(status);
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
// A program spawned over files: awk/jq/sed as the original ran them.
const awk = (args: string[], o: Parameters<typeof run>[1] = {}): Ran => run(["awk", ...args], o);
const jq = (args: string[], o: Parameters<typeof run>[1] = {}): Ran => run(["jq", ...args], o);

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
const rmrf = (p: string): void => {
  run(["rm", "-rf", p], { stdout: "inherit" });
};
const mv = (from: string, to: string): number => run(["mv", from, to], { stdout: "inherit" }).status;
const mkdirp = (...dirs: string[]): number => run(["mkdir", "-p", ...dirs], { stdout: "inherit" }).status;
const mktemp = (args: string[]): { status: number; path: string } => {
  const r = run(["mktemp", ...args]);
  return { status: r.status, path: cap(r.out) };
};
const sha = (s: string): string => createHash("sha256").update(B(s)).digest("hex");
// ac_config_sha256: null where the original's `shasum <file` failed.
const shaFile = (p: string): string | null => {
  try {
    return createHash("sha256").update(readFileSync(B(p))).digest("hex");
  } catch {
    return null;
  }
};
// `x="$(ac_config_sha256 <f>)"`: an unreadable file ends the run, status 1.
const shaFileA = (p: string): string => shaFile(p) ?? fatal(1);
// <argv> with stdout redirected into <file> (`>`, or `>>` with "a"): the
// redirection opens first, and a file it cannot open fails the command.
function runTo(argv: string[], file: string, flag = "w", stdin: "inherit" | Buffer = "inherit"): number {
  let fd: number;
  try {
    fd = openSync(B(file), flag);
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
// The local `date +%Y%m%d-%H%M%S` every run, receipt and gate name carries.
const stampA = (): string => {
  const r = run(["date", "+%Y%m%d-%H%M%S"]);
  ee(r.status);
  return cap(r.out);
};
// The PATH's sleep, so a test's stub fast-forwards a lock wait.
const sleepOne = (): void => {
  run(["sleep", "1"], { stdout: "inherit" });
};
// ac_meta_get: the last `<key>=` value, bytes; an unreadable file warns and
// reads as nothing.
const meta = (f: string, key: string): string => {
  try {
    return metaGet(B(f) as unknown as string, key);
  } catch {
    return "";
  }
};
// ac_meta_set: its refusal (a WARN) ends the run as the original's errexit did.
const metaPut = (f: string, key: string, value: string): void => {
  try {
    metaSet(u8(f), key, value);
  } catch (e) {
    fatal((e as { status?: number }).status ?? 1);
  }
};
// `sed -n 's/^<key>=//p' <file> | head -n1` as `$(...)` read it.
const sedFirst = (file: string, key: string, stderr: Io = "inherit"): string => cap(firstLine(run(["sed", "-n", `s/^${key}=//p`, file], { stderr }).out));
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
// The complete lines a `while read` loop takes, each cut at its first NUL.
const lines = (text: string): string[] => {
  const l = text.split("\n");
  l.pop();
  return l.map((x) => x.split("\0", 1)[0]!);
};
// `IFS=$'\t' read -r <n names>`: tab is IFS whitespace (runs collapse, the
// ends drop), the last name takes the rest.
const tabRead = (line: string, n: number): string[] => {
  const f: string[] = [];
  let rest = line.replace(/^\t+/, "");
  for (let i = 1; i < n && rest !== ""; i++) {
    const m = /\t+/.exec(rest);
    if (!m) break;
    f.push(rest.slice(0, m.index));
    rest = rest.slice(m.index + m[0].length);
  }
  f.push(rest.replace(/\t+$/, ""));
  while (f.length < n) f.push("");
  return f;
};
// `IFS=$'\037' read -r <n names>`: every separator splits, empty fields stay,
// one separator that ends the line drops from the last field.
const usRead = (line: string, n: number): string[] => {
  const f: string[] = [];
  let rest = line;
  for (let i = 1; i < n; i++) {
    const at = rest.indexOf("\x1f");
    f.push(at < 0 ? rest : rest.slice(0, at));
    rest = at < 0 ? "" : rest.slice(at + 1);
  }
  const at = rest.indexOf("\x1f");
  f.push(at >= 0 && at === rest.length - 1 ? rest.slice(0, at) : rest);
  return f;
};
// `case "$x" in *[!<class>]*)` - true when <s> holds a byte outside <cls>.
const outside = (s: string, cls: RegExp): boolean => [...s].some((c) => !cls.test(c));

const STEPS = "pin testplan baseline infra serve cases e2e evidence verdict";
const STATUSES = "pending running fixing completed skipped failed";
const CASE_STATUSES = "pass fail unverifiable";
const CASE_TIERS = "api db workflow web";
const BOUNDARIES = "http grpc client-cli workflow queue schedule web e2e";
const KNOWN_SERVICES = "postgres redis temporal wiremock";
const inList = (list: string, w: string): boolean => ` ${list} `.includes(` ${w} `);
// Set by the commands that OWN a step transition (baseline, serve) while they
// call cmdStep, so the direct-transition refusal can tell the owning command
// apart from an agent typing `step baseline completed` by hand.
let stepOwner = "";

let repo = "";
let qdir = "";
let current = "";
let assetsDir = "";
let binDir = "";
const cwdFn = (): string => process.cwd();

const requireRun = (): void => {
  if (!isLink(current)) fail("no active qa run; ac-qa.sh start first");
};
const runDir = (): string => {
  const t = readLink(current);
  if (t === null) fail("broken current symlink");
  return `${qdir}/${t}`;
};

// --- run helpers ------------------------------------------------------------------

function watchOpen(rd: string, task: string): void {
  if ((process.env.AC_QA_WATCH || "auto") === "off") return;
  if (backendName() !== "herdr") return;
  if (!commandV("herdr")) return;
  const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
  if (run(["herdr", "--session", ses, "pane", "list"], { stderr: "ignore" }).out.includes('"label":"ac-qa-watch"')) return;
  const label = `ac-qa-watch-${sanitizeCompose(task)}`;
  const ws = herdrResolveWorkspace(wsFamilyLabel(b8(windowFamily(u8(task)))), true) ?? "";
  const opened = herdrTabOpen(ses, label, repo, ws);
  if (opened === null) return;
  const p = opened.split(" ")[0]!;
  run(["herdr", "--session", ses, "pane", "rename", p, "ac-qa-watch"], { stdout: "ignore", stderr: "ignore" });
  run(["herdr", "--session", ses, "pane", "run", p, `'${binDir}/ac-qa-watch.sh' --repo '${repo}' --self-pane ${p}`], { stdout: "ignore", stderr: "ignore" });
  ee(put(`${rd}/watch.pane`, `${p}\n`));
}

// docker compose's project-name grammar through the original's two `tr`s, in
// the caller's locale (W5).
function sanitizeCompose(s: string): string {
  const lower = run(["tr", "[:upper:]", "[:lower:]"], { stdin: B(s) });
  return run(["tr", "-c", "a-z0-9_-", "-"], { stdin: B(lower.out) }).out;
}

// png|jpeg|gif|webp from the file's first twelve bytes, else null.
function imageKind(p: string): string | null {
  let head: Buffer;
  try {
    const fd = openSync(B(p), "r");
    try {
      head = Buffer.alloc(12);
      head = head.subarray(0, readSync(fd, head, 0, 12, 0));
    } finally {
      closeSync(fd);
    }
  } catch {
    return null;
  }
  const hex = head.toString("hex");
  if (hex.startsWith("89504e470d0a1a0a")) return "png";
  if (hex.startsWith("ffd8ff")) return "jpeg";
  if (hex.startsWith("474946383761") || hex.startsWith("474946383961")) return "gif";
  if (/^52494646[0-9a-f]{8}57454250/.test(hex)) return "webp";
  return null;
}

const qaTestplanPath = (): string => `${dirname(cmdEvidenceDir())}/testplan.md`;

// UT is reused only from the frozen exact-SHA ship receipt; null when it may.
function qaTestplanUtRowsOk(rd: string, manifest: string): string | null {
  if (jq(["-e", '.coverage | any(.rung == "ut")', manifest], { stdout: "ignore" }).status !== 0) return null;
  const status = qaShipReceiptStatus(`${rd}/profile/ship/test-receipt.env`, meta(`${rd}/run.meta`, "target_sha"));
  if (status.startsWith("qualifies:")) return null;
  const acs = jq(["-r", '.coverage[] | select(.rung == "ut") | .ac', manifest]);
  const ac = cap(run(["paste", "-sd,", "-"], { stdin: B(acs.out) }).out);
  return `UT coverage ${ac || "<unknown>"} requires a qualifying exact-SHA ship receipt (got ${status}); map the affected AC to IT instead`;
}

// The one precedence check every case-producing command calls; null when ready.
function qaTestplanReady(rd: string): string | null {
  if (stepStatus(rd, "testplan") !== "completed") return "a completed testplan step and frozen coverage manifest are required before QA case execution";
  const plan = qaTestplanPath();
  const manifest = `${rd}/testplan-manifest.json`;
  const err = qaTestplanManifestValidate(repo, meta(`${rd}/run.meta`, "target_sha"), plan, manifest, meta(`${rd}/run.meta`, "testplan_manifest_sha256"));
  if (err !== null) return err;
  return qaTestplanUtRowsOk(rd, manifest);
}

// `awk -F'\t' '$1=="<step>"{print $2}' steps.tsv` as `$(...)` read it.
const stepStatus = (rd: string, step: string): string => cap(awk(["-F\\t", `$1=="${step}"{print $2}`, `${rd}/steps.tsv`]).out);

function qaCaseEvidenceExists(rd: string): boolean {
  if (nonEmpty(`${rd}/cases.tsv`)) return true;
  return run(["find", `${rd}/boundaries`, `${rd}/fixtures/receipts`, `${rd}/e2e/receipts`, "-type", "f", "-print", "-quit"], { stderr: "ignore" }).out !== "";
}

// Is the recorded process GROUP still there (the group, then the one pid, by
// signal 0)? 0, 00 and 1 are no recorded group: the caller's own group, and
// -1 the broadcast to every process of the user.
function qaPgidAlive(pgid: string): boolean {
  if (pgid === "" || /[^0-9]/.test(pgid) || pgid.startsWith("0") || pgid === "1") return false;
  return signal0(-Number(pgid)) || signal0(Number(pgid));
}
const signal0 = (pid: number): boolean => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

type Identity = { source: string; profile: string; serve: string; health: string; desc: string };
function qaRuntimeIdentity(rd: string): Identity {
  return {
    source: meta(`${rd}/run.meta`, "target_sha"),
    profile: meta(`${rd}/run.meta`, "profile_sha256"),
    serve: sha(configValue("qa.serve")),
    health: sha(configValue("qa.health")),
    desc: isFile(`${rd}/runtime/descriptor.env`) ? shaFileA(`${rd}/runtime/descriptor.env`) : "",
  };
}

// The boot receipt binds this run's frozen identity and its group still lives.
function qaRuntimeReceiptOk(rd: string): string | null {
  const id = qaRuntimeIdentity(rd);
  const err = qaRuntimeReceiptValidate(`${rd}/runtime/receipt.env`, id.source, id.profile, id.serve, id.health, id.desc);
  if (err !== null) return err;
  if (!qaPgidAlive(meta(`${rd}/runtime/receipt.env`, "process_group"))) return "the runtime receipt's process group is no longer alive - the booted deliverable is gone";
  return null;
}

// The minimal environment a child runs under: PATH, HOME, LANG (C.UTF-8 when
// unset) and the non-empty lines of <file>, as `env -i` NAME=VALUE arguments.
function envFrom(file: string): string[] {
  const e = [`PATH=${b8(process.env.PATH ?? "")}`, `HOME=${b8(process.env.HOME ?? "")}`, `LANG=${b8(process.env.LANG || "C.UTF-8")}`];
  const text = readText(file);
  if (text !== null) for (const l of lines(text)) if (l !== "") e.push(l);
  return e;
}
const qaBoundaryEnv = (rd: string): string[] => envFrom(`${rd}/runtime/descriptor.env`);
const minimalEnv = (rd: string): string[] => envFrom(`${rd}/ports.env`);

function qaBoundaryReceiptPublish(rd: string, caseId: string, boundary: string, driver: string, stimulus: string, evidence: string, upstream: string, started: string, ended: string, code: string): string {
  const dir = `${rd}/boundaries/${caseId}`;
  ee(mkdirp(dir));
  const name = `${stampA()}-${process.pid}.env`;
  const m = mktemp([`${dir}/.receipt.XXXXXX`]);
  ee(m.status);
  const tmp = m.path;
  ee(
    put(
      tmp,
      `schema=agentcrew.qa-boundary-receipt/v1\nsource_sha=${meta(`${rd}/run.meta`, "target_sha")}\nprofile_sha256=${meta(`${rd}/run.meta`, "profile_sha256")}\n` +
        `runtime_receipt_sha256=${shaFile(`${rd}/runtime/receipt.env`) ?? ""}\ncase_id=${caseId}\nboundary=${boundary}\ndriver=${driver}\n` +
        `stimulus_sha256=${stimulus}\nevidence_sha256=${evidence}\nupstream_receipt_sha256=${upstream}\nstarted_at=${started}\ncompleted_at=${ended}\nexit_code=${code}\n`,
    ),
  );
  if (meta(tmp, "schema") !== "agentcrew.qa-boundary-receipt/v1" || meta(tmp, "stimulus_sha256") === "" || meta(tmp, "evidence_sha256") === "") {
    rm(tmp);
    fail(`boundary receipt for case ${caseId} could not be staged`);
  }
  if (mv(tmp, `${dir}/${name}`) !== 0) {
    rm(tmp);
    fail(`boundary receipt for case ${caseId} could not be published`);
  }
  return `${dir}/${name}`;
}

// `$(awk ... | wc -l | tr -d ' ')` over the case ledger.
const countRows = (rd: string, prog: string): string => cap(run(["wc", "-l"], { stdin: B(awk(["-F\\t", prog, `${rd}/cases.tsv`]).out) }).out).replace(/ /g, "");

// "total passed failed unverifiable flaky visuals" off the two ledgers.
function qaCounts(rd: string): string[] {
  let text: string | null = readText(`${rd}/cases.tsv`);
  const total = text === null ? "" : cap(run(["wc", "-l"], { stdin: B(text) }).out).replace(/ /g, "");
  text = null;
  return [total, countRows(rd, '$3=="pass"'), countRows(rd, '$3=="fail"'), countRows(rd, '$3=="unverifiable"'), countRows(rd, '$4=="flaky"'), visualsValid(rd)];
}

function qaEnvelope(rd: string): string {
  const m = `${rd}/run.meta`;
  const verdict = sedFirst(m, "outcome");
  const scope = sedFirst(m, "scope");
  const app = sedFirst(m, "app");
  const attestation = meta(m, "attestation");
  const reason = meta(m, "attestation_reason");
  const [total = "", passed = "", failed = "", unver = "", flaky = "", visuals = ""] = qaCounts(rd).join(" ").split(" ").filter((x) => x !== "");
  return (
    `QA_VERDICT=${verdict}\nQA_SCOPE=${scope}\nQA_APP=${app}\nQA_RULE=${meta(m, "qa_rule")}\nQA_HARNESS=${meta(m, "qa_harness")}\nQA_MODEL=${meta(m, "qa_model")}\n` +
    `QA_EFFORT=${meta(m, "qa_effort")}\nQA_DISPATCH_SHA256=${meta(m, "dispatch_sha256")}\nQA_TOTAL=${total}\nQA_PASSED=${passed}\nQA_FAILED=${failed}\n` +
    `QA_UNVERIFIABLE=${unver}\nQA_FLAKY=${flaky}\nQA_VISUALS=${visuals}\nQA_REPORT=${cmdEvidenceDir()}/../report.md\nQA_RUN_ID=${readLink(current) ?? ""}\n` +
    `QA_ATTESTATION=${attestation || "none"}\nQA_ATTESTATION_REASON=${reason}\nSERVICE_LAUNCHED=${isFile(`${rd}/logs/serve.log`) ? "true" : "false"}\n`
  );
}

// The registered rows still backed by a real artifact of the kind they claim.
function visualsLive(rd: string): string[] {
  const text = readText(`${rd}/visuals.tsv`);
  if (!isFile(`${rd}/visuals.tsv`) || text === null) return [];
  const out: string[] = [];
  for (const l of lines(text)) {
    const [path = "", kind = "", rest = ""] = tabRead(l, 3);
    if (path === "" || !isFile(path)) continue;
    const actual = imageKind(path);
    if (actual === null || kind === "" || actual !== kind) continue;
    out.push(`${path}\t${kind}\t${rest}\n`);
  }
  return out;
}
const visualsValid = (rd: string): string => `${visualsLive(rd).length}`;

// An existing file or directory resolving below the resolved evidence root.
function qaEvidencePathOk(root: string, path: string): boolean {
  if (root === "" || path === "" || path === "-") return false;
  const a = [root, path].map(u8);
  if (a.some((x) => x.includes("�"))) return false;
  return within(a[0]!, a[1]!, cwdFn);
}

// A completed E2E step is an execution claim only when its immutable receipt
// binds the current run and exited zero.
function qaE2eReceiptOk(rd: string): boolean {
  const ptr = `${rd}/e2e/receipt.current`;
  if (!isFile(ptr)) return false;
  const receipt = `${rd}/e2e/receipts/${cap(readText(ptr) ?? "")}`;
  if (!isFile(receipt)) return false;
  if (meta(receipt, "schema") !== "agentcrew.qa-e2e-receipt/v1" || meta(receipt, "exit_code") !== "0") return false;
  const m = `${rd}/run.meta`;
  if (meta(receipt, "source_sha") !== meta(m, "target_sha")) return false;
  if (meta(receipt, "e2e_repo") !== meta(m, "e2e_repo")) return false;
  if (meta(receipt, "e2e_sha") !== meta(m, "e2e_ref")) return false;
  if (meta(receipt, "profile_sha256") !== meta(m, "profile_sha256")) return false;
  const command = configValue("qa.e2e.command");
  if (command === "" || meta(receipt, "command_sha256") !== sha(command)) return false;
  return meta(receipt, "cases") !== "";
}

// --- the pass gate ------------------------------------------------------------------

const OUTSTANDING_AWK = `$2 != "completed" && $2 != "skipped" {
    printf "%s%s=%s", (n++ ? ", " : ""), $1, $2
  }`;
const BAD_SKIPS_AWK = `$2 == "skipped" && (NF < 4 || $4 == "" || $4 == "-") {
    printf "%s%s", (n++ ? ", " : ""), $1
  }`;
const FINDINGS_VALID_JQ = `
      type == "array"
      and all(.[];
        type == "object"
        and (.id | type == "string" and length > 0)
        and (.action | type == "string" and IN("fix", "ask-user", "no-op"))
      )`;
const BLOCKERS_JQ = String.raw`
      .[]
      | select(
          .action == "fix"
          or (.action == "ask-user"
              and ((.decision | type) != "string"
                   or (.decision | gsub("^[[:space:]]+|[[:space:]]+$"; "") | length) == 0))
        )
      | "\(.id):\(.action)"`;
const DUPLICATE_AWK = 'seen[$1]++ { printf "%s%s", (n++ ? ", " : ""), $1 }';

// `for f in <dir>/*.json` in byte order (the oracle runs under C; ORDER).
function globJson(dir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(B(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  return names.filter((n) => !n.startsWith(".") && n.endsWith(".json")).sort().map((n) => `${dir}/${n}`).filter(exists);
}

// The single pass-completion adjudicator: reads the durable ledgers only and
// runs before teardown, outcome mutation and attestation publication.
function qaFinishGate(rd: string): void {
  const no = (msg: string): never => fail(`finish passed refused: ${msg}`);
  const steps = `${rd}/steps.tsv`;
  const outstanding = awk(["-F\\t", OUTSTANDING_AWK, steps]);
  ee(outstanding.status);
  if (cap(outstanding.out) !== "") no(`non-terminal steps: ${cap(outstanding.out)}`);
  const badSkips = awk(["-F\\t", BAD_SKIPS_AWK, steps]);
  ee(badSkips.status);
  if (cap(badSkips.out) !== "") no(`skipped steps lack durable notes: ${cap(badSkips.out)}`);
  const tp = awk(["-F\\t", '$1 == "testplan" { print $2 }', steps]);
  ee(tp.status);
  if (cap(tp.out) !== "completed") no(`a passing run requires a completed testplan step (testplan is ${cap(tp.out) || "absent"})`);
  const testplan = `${dirname(cmdEvidenceDir())}/testplan.md`;
  const frozen = meta(`${rd}/run.meta`, "testplan_sha256");
  if (frozen === "") no("completed testplan has no frozen test-plan hash");
  if (!isFile(testplan)) no(`frozen test plan is missing: ${testplan}`);
  const tsha = shaFileA(testplan);
  if (tsha !== frozen) no(`test plan changed after completion (frozen=${frozen} current=${tsha}); record an authority-backed testplan-amend`);

  const serve = awk(["-F\\t", '$1 == "serve" { print $2 }', steps]);
  ee(serve.status);
  if (cap(serve.out) !== "completed")
    no(`a passing run must boot the deliverable - the serve step is ${cap(serve.out) || "absent"}, and 'step serve skipped' can never satisfy a pass. Record this round as failed|unverifiable|cancelled instead.`);
  const rerr = qaRuntimeReceiptOk(rd);
  if (rerr !== null) no(rerr);
  const runtimeSha = shaFileA(`${rd}/runtime/receipt.env`);

  let findingsBad = "";
  for (const f of globJson(`${rd}/findings`)) {
    if (jq(["-e", FINDINGS_VALID_JQ, f], { stdout: "ignore", stderr: "ignore" }).status !== 0) no(`invalid or unreadable findings data: ${f}`);
    const blockers = jq(["-r", BLOCKERS_JQ, f]);
    ee(blockers.status);
    for (const b of lines(`${cap(blockers.out)}\n`)) if (b !== "") findingsBad += `${findingsBad ? ", " : ""}${basename(f).replace(/\.json$/, "")}/${b}`;
  }
  if (findingsBad !== "") no(`unresolved findings (step/id:action): ${findingsBad}`);

  if (!nonEmpty(`${rd}/cases.tsv`)) no("the case ledger is EMPTY - a run that recorded no case verified nothing");
  const dup = awk(["-F\\t", DUPLICATE_AWK, `${rd}/cases.tsv`]);
  ee(dup.status);
  if (cap(dup.out) !== "") no(`duplicate case ids: ${cap(dup.out)}`);

  const evidenceRoot = cmdEvidenceDir();
  const ledger = run(["/usr/bin/env", "LC_ALL=C", "tr", "\t", "\x1f"], { stdin: B(readText(`${rd}/cases.tsv`) ?? "") }).out;
  for (const line of lines(ledger)) {
    const [id = "", tier = "", status = "", , , grade = "", evidence = "", , , , boundary = "", receipt = ""] = usRead(line, 12);
    if (id === "") no("a case has an empty id");
    if (!inList(CASE_TIERS, tier)) no(`case ${id} has invalid tier '${tier}' (the closed set is ${CASE_TIERS})`);
    if (status !== "pass") no(`case ${id} is ${status}, not pass`);
    if (!["A", "B", "C", "D"].includes(grade)) no(`case ${id} has no valid grade (got '${grade}')`);
    if (!qaEvidencePathOk(evidenceRoot, evidence)) no(`case ${id} evidence is missing, broken, or outside the declared evidence root: ${evidence}`);
    if (receipt === "" || receipt === "-") no(`case ${id} binds no client-boundary execution receipt - a tier label and a completed serve step are not proof`);
    if (!qaReceiptPathOk(rd, id, receipt))
      no(`case ${id} boundary receipt escapes this run's own boundary directory (canonical check refuses traversal, symlinks, and foreign paths): ${receipt}`);
    let expected = "-";
    if (meta(receipt, "driver") === "browser") {
      const berr = qaBrowserManifestOk(rd, id, receipt);
      if (berr !== null) no(`case ${id} - ${berr}`);
    } else expected = qaPathSha(evidence.startsWith("/") ? evidence : `${evidenceRoot}/${evidence}`);
    const verr = qaBoundaryReceiptValidate(receipt, id, tier, status, meta(`${rd}/run.meta`, "target_sha"), meta(`${rd}/run.meta`, "profile_sha256"), runtimeSha, expected);
    if (verr !== null) no(`case ${id} - ${verr}`);
    if (boundary !== meta(receipt, "boundary")) no(`case ${id} records boundary '${boundary}' but its receipt says '${meta(receipt, "boundary")}'`);
    if (tier === "web" && !visualsLive(rd).some((r) => r.replace(/\n$/, "").split("\t")[3] === id)) no(`web case ${id} has no valid visual linked to that case id`);
  }

  const cerr = qaCoverageValidate(rd, repo, meta(`${rd}/run.meta`, "target_sha"));
  if (cerr !== null) no(cerr);

  let harnessMissing = "";
  if (isDir(`${evidenceRoot}/harness`)) {
    const found = run(["find", `${evidenceRoot}/harness`, "-type", "f", "(", "-perm", "-u+x", "-o", "-perm", "-g+x", "-o", "-perm", "-o+x", ")", "-print"]);
    const sorted = run(["/usr/bin/env", "LC_ALL=C", "sort"], { stdin: B(found.out) }).out;
    for (const h of lines(sorted)) {
      if (h === "") continue;
      if (!isFile(`${rd}/regression-candidates.tsv`) || awk(["-F\\t", "-v", `p=${h}`, "$1 == p { found=1 } END { exit !found }", `${rd}/regression-candidates.tsv`]).status !== 0)
        harnessMissing += `${harnessMissing ? ", " : ""}${h}`;
    }
  }
  if (harnessMissing !== "") no(`task-local executable harnesses lack regression-promotion classification: ${harnessMissing}`);

  if (!(Number(visualsValid(rd)) > 0)) no("no visual artifact on record - register one with 'ac-qa.sh visual <path>'");

  const e2e = awk(["-F\\t", '$1 == "e2e" { print $2 }', steps]);
  ee(e2e.status);
  if (cap(e2e.out) === "completed" && !qaE2eReceiptOk(rd))
    no("completed e2e step has no valid zero-exit execution receipt bound to the frozen command and refs; run 'ac-qa.sh cmd e2e --cases <ids>'");

  const [total = "", , failed = "", unver = "", , visuals = ""] = qaCounts(rd).join(" ").split(" ").filter((x) => x !== "");
  if (failed !== "0") no(`${failed} failed case(s) in the ledger`);
  if (unver !== "0") no(`${unver} unverifiable case(s) - finish unverifiable instead`);
  if (!(testInt(total)! > 0n)) no("the case ledger is EMPTY - a run that recorded no case verified nothing");
  if (!(testInt(visuals)! > 0n))
    no(
      "no visual artifact on record - register one with 'ac-qa.sh visual <path>' (every run owes >=1 portable picture of what it proved, even an all-api/db run: screenshot the test report)",
    );

  const id = qaRuntimeIdentity(rd);
  qaPublishRuntimeGate(rd, runtimeSha, id.source, id.profile, id.health);
}

// The final gate record: the group still alive and the frozen health probe
// green again, published immutably with a pointer beside it.
function qaPublishRuntimeGate(rd: string, runtimeSha: string, sourceSha: string, profileSha: string, healthSha: string): void {
  const no = (msg: string): never => fail(`finish passed refused: ${msg}`);
  const pgid = meta(`${rd}/runtime/receipt.env`, "process_group");
  if (!qaPgidAlive(pgid)) no(`the booted deliverable (process group ${pgid}) died before the final runtime gate - the evidence describes a runtime that is no longer the one under test`);
  const c = configValue("qa.health");
  if (c === "") no("the frozen qa.health probe is gone, so the final runtime gate cannot be re-run");
  const rc = probe(rd, c, true, minimalEnv(rd)).status;
  if (rc !== 0) no(`the final health probe exited ${rc} - the deliverable was not ready when the pass would have been minted`);
  ee(mkdirp(`${rd}/runtime/gates`));
  const name = `${stampA()}-${process.pid}.env`;
  const m = mktemp([`${rd}/runtime/gates/.gate.XXXXXX`]);
  ee(m.status);
  ee(
    put(
      m.path,
      `schema=agentcrew.qa-runtime-gate/v1\nsource_sha=${sourceSha}\nprofile_sha256=${profileSha}\nruntime_receipt_sha256=${runtimeSha}\nprocess_group=${pgid}\n` +
        `health_command_sha256=${healthSha}\nvalidated_at=${iso()}\nalive=1\nhealth_exit_code=0\n`,
    ),
  );
  if (mv(m.path, `${rd}/runtime/gates/${name}`) !== 0) {
    rm(m.path);
    no("the runtime gate receipt could not be published");
  }
  const gerr = qaRuntimeGateValidate(`${rd}/runtime/gates/${name}`, sourceSha, profileSha, runtimeSha, healthSha, pgid);
  if (gerr !== null) no(`the published runtime gate receipt is invalid: ${gerr}`);
  const p = mktemp([`${rd}/runtime/.gate-current.XXXXXX`]);
  ee(p.status);
  ee(put(p.path, `${name}\n`));
  if (mv(p.path, `${rd}/runtime/gate.current`) !== 0) {
    rm(p.path);
    no("the runtime gate pointer could not be published");
  }
}

// The health probe as the original ran it: `( cd <repo> && env -i <env>
// perl -e 'alarm 10; exec "sh","-c",$ARGV[0]' <c> )`, or `sh -c` without perl.
function probeArgv(c: string, perl: boolean, env: string[]): string[] {
  const body = perl ? ["perl", "-e", 'alarm 10; exec "sh", "-c", $ARGV[0]', c] : ["sh", "-c", c];
  return ["/usr/bin/env", "-i", ...env, ...body];
}
function probe(rd: string, c: string, perl: boolean, env: string[], out: Io = "ignore"): Ran {
  void rd;
  return run(probeArgv(c, perl, env), { cwd: repo, stdout: out, stderr: out === "ignore" ? "ignore" : "inherit" });
}
function probeFailure(c: string, perl: boolean, env: string[]): { status: number; why: string } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(probeArgv(c, perl, env).map(u8), { cwd: u8(repo), stdin: "inherit", stdout: "ignore", stderr: "pipe" });
  } catch {}
  const lines = r ? Buffer.from(r.stderr).toString("latin1").split("\n").map((l) => l.trim()).filter((l) => l !== "") : [];
  return { status: shellStatus(r), why: (lines.at(-1) ?? "").slice(0, 200) };
}

// Stage, parse with the merge gate's own v2 parser, then rename into the
// marker path; 2 for a run with no profile identity. The original ran it as
// an `if` condition, so errexit slept inside: a failed mkdir, mktemp, write
// or rename is passed over (the parse refuses a temp that never landed).
function qaPublishAttestation(rd: string, passed: string, total: string): number {
  const m = `${rd}/run.meta`;
  const root = repoRoot(u8(repo));
  const main = root === null ? repo : b8(root);
  const tsha = meta(m, "target_sha");
  const scope = meta(m, "scope");
  const app = meta(m, "app");
  const profileKey = meta(m, "profile_key");
  const profileSha = meta(m, "profile_sha256");
  const configSha = meta(m, "config_sha256");
  const qaRule = meta(m, "qa_rule");
  const e2eRepo = meta(m, "e2e_repo");
  const e2eSha = meta(m, "e2e_ref");
  const task = meta(m, "task");
  if (profileKey === "" || profileSha === "") return 2;
  const marker = scope === "" ? tsha : `${tsha}.${scope}.${app}`;
  const dir = `${main}/.crew/qa/passed`;
  mkdirp(dir);
  const t = mktemp([`${dir}/.${marker}.XXXXXX`]);
  if (t.path !== "")
    put(
      t.path,
      `schema=agentcrew.qa-attestation/v2\noutcome=passed\nrun=${readLink(current) ?? ""}\ntask=${task}\ncompleted_at=${iso()}\nsource_sha=${tsha}\n` +
        `profile_key=${profileKey}\nprofile_sha256=${profileSha}\nconfig_sha256=${configSha}\ncases_passed=${passed}\ncases_total=${total}\n` +
        (scope === "" ? "" : `scope=${scope}\napp=${app}\n`) +
        (qaRule === "" ? "" : `qa_rule=${qaRule}\n`) +
        (e2eRepo === "" ? "" : `e2e_repo=${e2eRepo}\n`) +
        (e2eSha === "" ? "" : `e2e_sha=${e2eSha}\n`),
    );
  const perr = qaAttestationParse(t.path, tsha, scope, app);
  if (perr !== null) {
    rm(t.path);
    fail(`passing attestation failed its own v2 validation: ${perr}`);
  }
  mv(t.path, `${dir}/${marker}`);
  return 0;
}

// The MAIN repo's basename, sanitized: a run in a pool worktree scopes to
// the project, so the teardown and reap hooks (run from the main repo) match.
const repoScope = (): string => sanitizeCompose(basename(b8(repoRoot(u8(repo)) ?? "")));
const qaStorePath = (data: string): string => `${data}/qa-store/${repoScope()}`;
function composeProject(): string {
  const rd = runDir();
  const task = sedFirst(`${rd}/run.meta`, "task");
  return `crew-qa-${repoScope()}-${sanitizeCompose(task || (readLink(current) ?? ""))}`;
}

// -f arguments: the shipped template, plus the linted project override.
function composeFiles(): string[] {
  runDir();
  if (!isFile(`${assetsDir}/compose.yaml`)) fail(`qa compose template missing: ${assetsDir}/compose.yaml`);
  const files = ["-f", `${assetsDir}/compose.yaml`];
  const override = configValue("qa.mocks_compose");
  if (override !== "") {
    if (override.startsWith("/") || override.includes("..")) fail(`qa.mocks_compose must be repo-relative: ${override}`);
    if (!isFile(`${repo}/${override}`)) fail(`qa.mocks_compose not found: ${repo}/${override}`);
    lintOverride(`${repo}/${override}`);
    files.push("-f", `${repo}/${override}`);
  }
  return files;
}

const LINT_ERE =
  'container_name:|external:|privileged:|network_mode:|docker\\.sock|build:|extends:|include:|env_file:|cap_add:|cap_drop:|devices:|(pid|ipc|userns_mode|uts):|type:[[:space:]]*"?bind|source:[[:space:]]*"?(/|\\.\\.)|^[[:space:]]*-[[:space:]]*"?(/|\\.\\.)[^:]*:';
function lintOverride(f: string): void {
  const bad = cap(run(["grep", "-nE", LINT_ERE, f]).out);
  if (bad !== "") fail(`qa.mocks_compose fails the safety lint (captain must review):\n${bad}`);
}

// Execute under the minimal env from the repo root, teeing to the run log;
// the command's status. cmd e2e ran it as an `if` condition (<asleep>), where
// a failed run.log write is passed over.
function runMinimal(rd: string, log: string, c: string, asleep = false): number {
  const status = teeRun(["/usr/bin/env", "-i", ...minimalEnv(rd), "sh", "-c", c], repo, `${rd}/logs/${log}.log`);
  const w = append(`${rd}/logs/run.log`, `${iso()} cmd=${log} exit=${status}\n`);
  if (!asleep) ee(w);
  return status;
}

// `( cd <cwd> && <argv> ) 2>&1 | tee -a <log>` - the original's own pipeline,
// run by bash so tee streams and outlives this process as it outlived the
// original's; the left side's status (128+n for a signal).
function teeRun(argv: string[], cwd: string, log: string, toStderr = false): number {
  const pipeline = `( cd "$1" && shift 2 && "$@" ) 2>&1 | tee -a "$2"${toStderr ? " >&2" : ""}; exit "\${PIPESTATUS[0]}"`;
  return run(["/bin/bash", "--posix", "-c", pipeline, "ac-qa.sh", cwd, log, ...argv], { stdout: "inherit" }).status;
}

// The exact paths ac-verify's context neutralization stubbed THIS round, or
// null when no manifest exists (a plain qa run, or a round that stubbed
// nothing) - the guard reads that absence as "exempt nothing", never "exempt
// everything".
function neutralizedManifestPaths(): Set<string> | null {
  const manifest = `${repo}/.crew/qa/neutralized-manifest`;
  const raw = readText(manifest);
  if (raw === null) return null;
  const paths = raw.split("\0");
  paths.pop();
  return new Set(paths);
}

// A path is exempt only while its bytes are still exactly what ac-verify
// wrote - any further edit (including a non-stub edit of a neutralized path)
// is a real change and must still refuse.
function isNeutralizedStub(absPath: string): boolean {
  const stub = readText(`${repo}/.crew/qa/neutralized-stub`);
  if (stub === null) return false;
  return readText(absPath) === stub;
}

// Drops exactly the porcelain lines this round's neutralization manifest
// accounts for (unstaged modification of a listed path whose content is
// still the recorded stub); every other line - including a non-stub edit of
// a neutralized path - passes through untouched.
function dirtyResidual(porcelain: string): string {
  if (porcelain === "") return "";
  const manifest = neutralizedManifestPaths();
  if (manifest === null) return porcelain;
  const residual: string[] = [];
  for (const line of porcelain.split("\n")) {
    if (line === "") continue;
    const absPath = `${repo}/${line.slice(3)}`;
    if (line.slice(0, 2) === " M" && manifest.has(absPath) && isNeutralizedStub(absPath)) continue;
    residual.push(line);
  }
  return residual.join("\n");
}

// TARGET-CHECKOUT BINDING: the checkout the cases exercise IS the target.
function assertTargetCheckout(tsha: string): void {
  const head = run(["git", "-C", repo, "rev-parse", "HEAD"], { stderr: "ignore" });
  if (head.status !== 0) fail(`target-checkout: cannot resolve HEAD in ${repo} (qa must run against a definite checkout)`);
  if (cap(head.out) !== tsha)
    fail(
      `target-checkout MISMATCH: --target resolves to ${tsha} but this worktree's HEAD is ${cap(head.out)} - the qa run would exercise the wrong code. Check out the target commit here (a fresh pool worktree detached at it) before starting.`,
    );
  const dirty = run(["git", "-C", repo, "status", "--porcelain", "-uno"], { stderr: "ignore" });
  if (dirty.status !== 0) fail(`target-checkout: cannot read the worktree state in ${repo} (failing closed - an unreadable status is not a clean tree)`);
  const residual = dirtyResidual(cap(dirty.out));
  if (residual !== "")
    fail(
      `target-checkout DIRTY: uncommitted changes to tracked files, so the exercised code is not commit ${tsha}:\n${residual}\nCommit or discard them before a qa run (untracked and .crew/ artifacts are ignored).`,
    );
}

type Refuse = (cls: "caller-error" | "conflict" | "needs-profile", msg: string) => never;
const keysOf = (cfg: string, key: string): string => yamlKeys(cfg, key).out;

// THE precedence chain: mode detection, the closed scope list, then app
// membership; every violation reaches <refuse>, which ends the call.
function qaSelectionPrecedence(map: string, cfg: string, scope: string, app: string, refuse: Refuse): void {
  const cut = run(["cut", "-f1", map]);
  const declared = cut.out.replace(/\n/g, " ").replace(/ $/, "");
  const yamlHasScopes = yamlHas(cfg, "qa.scopes") === 0;
  const yamlScopes = keysOf(cfg, "qa.scopes").replace(/\n/g, " ").replace(/ $/, "");
  if (declared === "" && !yamlHasScopes) {
    if (scope !== "" || app !== "")
      refuse(
        "caller-error",
        `this project declares no scopes, so --scope/--app select nothing (got${scope ? ` --scope ${scope}` : ""}${app ? ` --app ${app}` : ""}). A scoped project needs BOTH a qa.scopes block in its fleet-home config AND scope entries in its repo-knowledge record; this one has neither. Drop the selectors, or declare the scopes first.`,
      );
    return;
  }
  if (declared === "" || !yamlHasScopes) {
    if (declared === "")
      refuse(
        "conflict",
        `F8 MODE MISMATCH: the fleet-home config declares scopes (${yamlScopes || "the qa.scopes block is present but still EMPTY"}) but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped. The record is the closed list of which scopes exist; declare them there (bin/ac-know.sh scope-proposal), or remove the qa.scopes block.`,
      );
    refuse(
      "conflict",
      `F8 MODE MISMATCH: the repo-knowledge record declares scopes (${declared}) but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped. The config says how to RUN a scope; add the block (ac-qa.sh config-proposal), or retire the scope entries.`,
    );
  }
  let undeclared = "";
  for (const k of yamlScopes.split(/[ \t\n]+/).filter((x) => x !== "")) if (!inList(declared, k)) undeclared += ` ${k}`;
  if (undeclared !== "")
    refuse(
      "conflict",
      `F9 UNDECLARED SCOPE BLOCK: the config carries qa.scopes for${undeclared}, which the repo-knowledge record does not declare. Declared scopes: ${declared}. The yaml says how to run a scope; it can never add one.`,
    );
  if (scope === "") refuse("caller-error", `F1: this project declares scopes, so every run must name one. Declared scopes: ${declared}`);
  if (!inList(declared, scope)) refuse("conflict", `F2: '${scope}' is not a declared scope. Declared scopes: ${declared}`);
  const members = cap(awk(["-F\\t", "-v", `s=${scope}`, "$1 == s { print $2 }", map]).out);
  if (app === "") refuse("caller-error", `F4: scope '${scope}' needs an app named too. Members of ${scope}: ${members}`);
  if (!`,${members},`.includes(`,${app},`)) refuse("conflict", `F5: '${app}' is not a member of scope '${scope}'. Members of ${scope}: ${members}`);
  if (cap(keysOf(cfg, `qa.scopes.${scope}`)) === "")
    refuse("needs-profile", `F3: scope '${scope}' is declared but the fleet-home config carries no qa.scopes.${scope} block - it has not been configured yet.`);
}

// The chain on the two FROZEN sources, every refusal fatal; then F6.
function qaValidateSelection(rd: string, scope: string, app: string, refuse: (msg: string) => never = fail): void {
  qaSelectionPrecedence(`${rd}/scopes.tsv`, `${rd}/config.yaml`, scope, app, (_c, msg) => refuse(msg));
  if (scope === "") return;
  if (cap(keysOf(`${rd}/config.yaml`, `qa.scopes.${scope}.apps.${app}`)) === "") refuse(`F6: app '${app}' has no config block (qa.scopes.${scope}.apps.${app}).`);
}

const RUNTIME_JSON_JQ = `
    type == "object"
    and .schema == "agentcrew.qa-runtime/v1"
    and (.e2e_worktree | type == "string")
    and ((keys | sort) == ["e2e_worktree","schema"])
  `;

// The shared immutable-bundle validator plus the volatile runtime checks;
// each refusal is a WARN and false.
function qaRuntimeBundleValidate(runtime: string, sourceSha: string, scope: string, app: string): boolean {
  const profile = `${runtime}/profile.json`;
  const runtimeJson = `${runtime}/runtime.json`;
  const no = (msg: string): boolean => {
    warnB(msg);
    return false;
  };
  const berr = qaBundleValidate(profile, sourceSha);
  if (berr !== null) return no(`qa runtime bundle invalid: ${berr}`);
  if (!isFile(runtimeJson) || isLink(runtimeJson)) return no("qa runtime bundle has no regular runtime.json");
  if (jq(["-e", RUNTIME_JSON_JQ, runtimeJson], { stdout: "ignore", stderr: "ignore" }).status !== 0) return no("qa runtime.json has an invalid schema or unknown keys");
  const pscope = cap(jq(["-r", '.target.scope // ""', profile]).out);
  const papp = cap(jq(["-r", '.target.app // ""', profile]).out);
  if (pscope !== scope || papp !== app) return no(`qa runtime bundle selector mismatch (profile=${pscope}/${papp} invocation=${scope}/${app})`);
  let key = cap(jq(["-r", ".project", profile]).out);
  if (scope !== "") key = `${key}/${scope}/${app}`;
  if (cap(jq(["-r", ".profile_key", profile]).out) !== key) return no("qa runtime bundle profile_key does not match project/scope/app");
  const worktree = cap(jq(["-r", ".e2e_worktree", runtimeJson]).out);
  const e2eRef = cap(jq(["-r", '.e2e.ref // ""', profile]).out);
  if (e2eRef !== "") {
    if (!isDir(worktree) || cap(run(["git", "-C", worktree, "rev-parse", "HEAD"], { stderr: "ignore" }).out) !== e2eRef)
      return no("qa runtime E2E worktree is missing or off the frozen E2E ref");
  } else if (worktree !== "") return no("qa runtime names an E2E worktree but the frozen profile has no E2E ref");
  return true;
}

// --- start ------------------------------------------------------------------------

// `x="$2"; shift 2` under set -u: a flag with no value ends the run, status 1
// (W15: the shell's own `$2: unbound variable` is not written).
const flagValue = (a: string[], i: number): string => a[i + 1] ?? fatal(1);

// The env a home-scoped call ran under (`AC_HOME="$qa_home" <helper>`).
function withHome<T>(home: string, f: () => T): T {
  const was = process.env.AC_HOME;
  process.env.AC_HOME = u8(home);
  try {
    return f();
  } finally {
    if (was === undefined) delete process.env.AC_HOME;
    else process.env.AC_HOME = was;
  }
}

// `$(... | tr '\t\r\n' '   ')` in the caller's locale, as `x="$(...)"` read it.
function scrubA(text: string): string {
  const r = run(["tr", "\t\r\n", "   "], { stdin: B(text) });
  ee(r.status);
  return cap(r.out);
}
// `x="$(jq -r <prog> <file>)"`.
const jqA = (prog: string, file: string): string => {
  const r = jq(["-r", prog, file]);
  ee(r.status);
  return cap(r.out);
};

function cmdStart(a: string[]): void {
  let target = "";
  let task = "";
  let evidence = "";
  let store = "";
  let home = "";
  let scope = "";
  let app = "";
  let scopeSeen = false;
  let appSeen = false;
  for (let i = 0; i < a.length; i += 2) {
    const f = a[i]!;
    if (f === "--target") target = flagValue(a, i);
    else if (f === "--task") task = flagValue(a, i);
    else if (f === "--skip") fail("start --skip was removed: record the durable reason after start with 'ac-qa.sh step <name> skipped --note <reason>'");
    else if (f === "--evidence") evidence = flagValue(a, i);
    else if (f === "--store") store = flagValue(a, i);
    else if (f === "--home") home = flagValue(a, i);
    else if (f === "--scope") {
      if (scopeSeen) fail(`--scope given twice ('${scope}' then '${flagValue(a, i)}') - name one scope, or the run silently takes the last`);
      scope = flagValue(a, i);
      scopeSeen = true;
    } else if (f === "--app") {
      if (appSeen) fail(`--app given twice ('${app}' then '${flagValue(a, i)}') - name one app, or the run silently takes the last`);
      app = flagValue(a, i);
      appSeen = true;
    } else fail(`unknown flag: ${f}`);
  }
  if (target === "") fail("--target is required (branch/ref/commit under verification)");
  if (store !== "" && !store.startsWith("/"))
    fail(
      `--store must be an ABSOLUTE path (got '${store}'): qa runs from a disposable pool worktree, so a relative store evaporates with the lease (see KNOWLEDGE STORE in this script's header). Copy the absolute path your qa brief names:\n  ac-qa.sh start --target ${target}${task ? ` --task ${task}` : ""} --store <abs-store-dir>`,
    );
  if (run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", `${target}^{commit}`], { stdout: "ignore" }).status !== 0) fail(`target does not resolve to a commit: ${target}`);
  const ts = run(["git", "-C", repo, "rev-parse", `${target}^{commit}`]);
  ee(ts.status);
  const targetSha = cap(ts.out);
  assertTargetCheckout(targetSha);
  const runtimeDir = `${qdir}/profile-runtime`;
  const qaHome = b8(homeResolve(u8(home), u8(repo)));
  const id = `${stampA()}-${process.pid}`;
  const rd = `${qdir}/${id}`;
  ee(mkdirp(`${rd}/logs`, `${rd}/findings`));
  const common = run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]);
  const c = cap(common.out);
  if (
    common.status !== 0 ||
    mkdirp(`${c}/info`) !== 0 ||
    (run(["grep", "-qx", "\\.crew/", `${c}/info/exclude`], { stderr: "ignore" }).status !== 0 && append(`${c}/info/exclude`, ".crew/\n") !== 0)
  )
    warnB("could not add .crew/ to info/exclude - it stays visible in git status");

  let homeCfg = "";
  let profiled = false;
  if (isDir(runtimeDir)) {
    if (!qaRuntimeBundleValidate(runtimeDir, targetSha, scope, app)) {
      rmrf(rd);
      fail(`qa refuses the invalid frozen runtime bundle at ${runtimeDir}`);
    }
    if (mv(runtimeDir, `${rd}/profile`) !== 0) {
      rmrf(rd);
      fail("qa could not consume the frozen runtime bundle");
    }
    ee(run(["cp", `${rd}/profile/config.yaml`, `${rd}/config.yaml`], { stdout: "inherit" }).status);
    ee(run(["cp", `${rd}/profile/scopes.tsv`, `${rd}/scopes.tsv`], { stdout: "inherit" }).status);
    homeCfg = "profile/config.yaml";
    profiled = true;
  } else if (qaHome !== "") {
    const cfg = withHome(qaHome, () => projectConfigFile(u8(repo)));
    if (cfg !== null) {
      homeCfg = cfg;
      ee(run(["cp", cfg, `${rd}/config.yaml`], { stdout: "inherit" }).status);
    } else ee(put(`${rd}/config.yaml`, ""));
    const map = withHome(qaHome, () => knowledgeScopes(u8(repo)));
    ee(put(`${rd}/scopes.tsv`, map.out));
    tell(map.err);
    if (map.status !== 0) {
      rmrf(rd);
      fail("qa refuses to start: the scope map is ambiguous (see above)");
    }
  } else {
    ee(put(`${rd}/config.yaml`, ""));
    ee(put(`${rd}/scopes.tsv`, ""));
    tell(
      "notice: no fleet home named (--home) and none in the environment - freezing an EMPTY project config and an EMPTY scope map; the checkout that owns bin/ is not a fleet home. Pass --home <abs> (your qa brief bakes it) to resolve them.\n",
    );
  }
  const configSha = shaFileA(`${rd}/config.yaml`);

  qaValidateSelection(rd, scope, app, (msg) => {
    tell(`ERROR: ${msg}\n`);
    rmrf(rd);
    return fatal(1);
  });

  const f: Record<string, string> = { e2e_worktree: "", e2e_repo: "", e2e_ref: "", profile_key: "", profile_sha256: "", qa_rule: "", qa_harness: "", qa_model: "", qa_effort: "", qa_when: "", qa_why: "", dispatch_sha256: "" };
  if (profiled) {
    const p = `${rd}/profile/profile.json`;
    f.e2e_worktree = jqA(".e2e_worktree", `${rd}/profile/runtime.json`);
    f.e2e_repo = jqA('.e2e.repo // ""', p);
    f.e2e_ref = jqA('.e2e.ref // ""', p);
    f.profile_key = jqA(".profile_key", p);
    f.profile_sha256 = jqA(".profile_sha256", p);
    f.qa_rule = jqA('.routing.rule // ""', p);
    f.qa_harness = jqA('.routing.use.harness // ""', p);
    f.qa_model = jqA('.routing.use.model // ""', p);
    f.qa_effort = jqA('.routing.use.effort // ""', p);
    f.qa_when = scrubA(jq(["-r", '.routing.when // ""', p]).out);
    f.qa_why = scrubA(jq(["-r", '.routing.why // ""', p]).out);
    f.dispatch_sha256 = jqA('.routing.dispatch_sha256 // ""', p);
    store = `${rd}/profile/store`;
  }
  ee(
    put(
      `${rd}/run.meta`,
      `target=${target}\ntarget_sha=${targetSha}\ntask=${task}\nevidence=${evidence}\nstore=${store}\nscope=${scope}\napp=${app}\n` +
        `e2e_worktree=${f.e2e_worktree}\ne2e_repo=${f.e2e_repo}\ne2e_ref=${f.e2e_ref}\nprofile_key=${f.profile_key}\nprofile_sha256=${f.profile_sha256}\n` +
        `qa_rule=${f.qa_rule}\nqa_harness=${f.qa_harness}\nqa_model=${f.qa_model}\nqa_effort=${f.qa_effort}\nqa_when=${f.qa_when}\nqa_why=${f.qa_why}\n` +
        `dispatch_sha256=${f.dispatch_sha256}\nconfig_source=${homeCfg || "none"}\nconfig_sha256=${configSha}\ncreated_at=${iso()}\noutcome=running\n`,
    ),
  );
  ee(put(`${rd}/cases.tsv`, ""));
  ee(put(`${rd}/visuals.tsv`, ""));
  ee(put(`${rd}/steps.tsv`, STEPS.split(" ").map((s) => `${s}\tpending\t0\t-\n`).join("")));
  ee(run(["ln", "-sfn", id, current], { stdout: "inherit" }).status);
  watchOpen(rd, task);
  say(`started qa run ${id} target=${target}${task ? ` task=${task}` : ""}\n`);
}

// --- steps ------------------------------------------------------------------------

const STEP_AWK = `
      $1 == s {
        $2 = st
        if (st == "fixing") $3 = ($3 + 0) + 1
        $4 = ENVIRON["AC_QA_STEP_NOTE"]
      }
      NF < 4 { $4 = "-" }
      { print }`;

// A free-text value through the original's scrub, in the caller's locale:
// `tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'`, as `x="$(...)"`
// read it (a failing stage ends the run - W11).
function noteScrubA(note: string): string {
  const t = run(["tr", "\t\r\n", "   "], { stdin: B(note) });
  const s = run(["sed", "s/  */ /g; s/^ //; s/ $//"], { stdin: B(t.out) });
  ee(t.status || s.status);
  return cap(s.out);
}

function cmdStep(a: string[]): void {
  requireRun();
  const usage = "usage: ac-qa.sh step <name> <status> [--note <text>]";
  if (a.length < 2) fail(usage);
  const [name = "", status = "", ...rest] = a;
  let note = "";
  if (rest.length > 0) {
    if (rest.length !== 2 || rest[0] !== "--note") fail(usage);
    note = rest[1]!;
  }
  if (!inList(STEPS, name)) fail(`unknown step: ${name}`);
  if (!inList(STATUSES, status)) fail(`unknown status: ${status}`);
  if (name === "baseline" && stepOwner !== "baseline" && (status === "completed" || status === "skipped"))
    fail(
      `step baseline ${status} is refused: 'ac-qa.sh baseline' owns this transition - it validates the frozen exact-SHA ship test receipt and records the result. QA never re-runs the unit suite - fixed policy.`,
    );
  if (name === "serve" && status === "completed" && stepOwner !== "serve")
    fail(
      "step serve completed is refused: 'ac-qa.sh serve' owns this transition - it boots the frozen qa.serve command and records the launch the runtime receipt binds. 'step serve skipped --note <why>' stays valid and can never satisfy a pass.",
    );
  note = noteScrubA(note);
  if (status === "skipped" && note === "") fail(`step ${name} skipped requires --note '<reason>' so the non-applicability decision is durable`);
  if (note === "") note = "-";
  const rd = runDir();
  let testplan = "";
  let testplanSha = "";
  let manifestTmp = "";
  let manifestSha = "";
  if (name === "testplan" && status === "completed") {
    testplan = qaTestplanPath();
    if (!isFile(testplan)) fail(`testplan completed requires the durable plan beside the evidence directory: ${testplan}`);
    testplanSha = shaFileA(testplan);
    const m = mktemp([`${rd}/.testplan-manifest.XXXXXX`]);
    ee(m.status);
    manifestTmp = m.path;
    const r = qaTestplanManifestRender(repo, meta(`${rd}/run.meta`, "target_sha"), testplan);
    if (put(manifestTmp, r.out.toString("latin1")) !== 0) {
      rm(manifestTmp);
      fatal(1);
    }
    if (r.status !== 0) {
      rm(manifestTmp);
      fail(`testplan completed refused: ${r.error}`);
    }
    const ut = qaTestplanUtRowsOk(rd, manifestTmp);
    if (ut !== null) {
      rm(manifestTmp);
      fail(`testplan completed refused: ${ut}`);
    }
    manifestSha = shaFileA(manifestTmp);
    const previous = meta(`${rd}/run.meta`, "testplan_sha256");
    if (previous !== "" && previous !== testplanSha) {
      rm(manifestTmp);
      fail(`testplan was already frozen at ${previous} and now hashes to ${testplanSha}; record the authority-backed transition with 'ac-qa.sh testplan-amend'`);
    }
  }
  if (name === "evidence" && status === "completed" && !(Number(visualsValid(rd)) > 0))
    fail(
      "evidence step has no visual artifact: register one with 'ac-qa.sh visual <path>' while the stack is still up, or 'step evidence skipped --note <why>' when the change has no visual surface",
    );
  const lock = `${rd}/.steps.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) {
    if (manifestTmp) rm(manifestTmp);
    fail("steps ledger lock timeout");
  }
  const t = mktemp([`${rd}/.steps.tsv.XXXXXX`]);
  if (
    t.status !== 0 ||
    runTo(["/usr/bin/env", `AC_QA_STEP_NOTE=${note}`, "awk", "-F\\t", "-v", "OFS=\\t", "-v", `s=${name}`, "-v", `st=${status}`, STEP_AWK, `${rd}/steps.tsv`], t.path) !== 0 ||
    mv(t.path, `${rd}/steps.tsv`) !== 0
  ) {
    if (t.path) rm(t.path);
    if (manifestTmp) rm(manifestTmp);
    lockRelease(u8(lock));
    fail(`step: could not update the steps ledger (${rd}/steps.tsv) - failing closed`);
  }
  lockRelease(u8(lock));
  if (testplanSha !== "") {
    if (mv(manifestTmp, `${rd}/testplan-manifest.json`) !== 0) {
      rm(manifestTmp);
      fail("testplan completed could not publish its frozen manifest");
    }
    metaPut(`${rd}/run.meta`, "testplan_sha256", testplanSha);
    metaPut(`${rd}/run.meta`, "testplan_manifest_sha256", manifestSha);
    metaPut(`${rd}/run.meta`, "testplan_path", testplan);
  }
  ee(append(`${rd}/logs/run.log`, `${iso()} step=${name} status=${status}${note !== "-" ? ` note=${note}` : ""}\n`));
  if (status === "running" || status === "fixing") watchOpen(rd, sedFirst(`${rd}/run.meta`, "task"));
  say(`${name} -> ${status}\n`);
}

// --- cases, visuals, findings -----------------------------------------------------

// A path the original took as `[ -x ]`.
const executable = (p: string): boolean => {
  try {
    accessSync(B(p), 1);
    return true;
  } catch {
    return false;
  }
};
// `printf '%s' "$v" | LC_ALL=C tr '\t\n\037' '   '` as `$(...)` read it.
const usScrub = (v: string): string => v.replace(/[\t\n\x1f]/g, " ");
// The case-id grammar per its text (W12: bash 3.2's range under a UTF-8
// locale admitted an accented letter).
const badId = (id: string): boolean => id === "" || id === "." || id.includes("..") || /[^a-zA-Z0-9_.-]/.test(id);

function cmdCase(a: string[]): void {
  requireRun();
  const usage = "usage: ac-qa.sh case <id> <pass|fail|unverifiable> --tier <t> [...]";
  if (a.length < 2) fail(usage);
  const [id = "", status = "", ...rest] = a;
  const v: Record<string, string> = { tier: "", cls: "-", conf: "-", grade: "-", ev: "-", note: "-", auth: "-", repro: "-", boundary: "-", receipt: "-" };
  const flags: Record<string, string> = {
    "--tier": "tier",
    "--classification": "cls",
    "--confidence": "conf",
    "--grade": "grade",
    "--evidence": "ev",
    "--note": "note",
    "--authority": "auth",
    "--repro": "repro",
    "--boundary": "boundary",
    "--receipt": "receipt",
  };
  for (let i = 0; i < rest.length; i += 2) {
    if (!Object.hasOwn(flags, rest[i]!)) fail(`unknown flag: ${rest[i]}`);
    v[flags[rest[i]!]!] = flagValue(rest, i);
  }
  if (badId(id)) fail(`case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '${id}'`);
  if (!inList(CASE_STATUSES, status)) fail(`unknown case status: ${status}`);
  if (!inList(CASE_TIERS, v.tier!)) fail(`--tier must be one of: ${CASE_TIERS}`);
  if (!["-", "defect", "flaky", "test-maintenance", "environment"].includes(v.cls!)) fail(`bad --classification: ${v.cls}`);
  if (!["-", "A", "B", "C", "D"].includes(v.grade!)) fail("--grade must be A|B|C|D (evidence ladder)");
  const ev = v.ev!;
  if (ev !== "-") {
    if (ev.includes("\t")) fail(`--evidence must not contain a tab: ${ev}`);
    if (ev.includes("\n")) fail(`--evidence must not contain a newline: ${ev}`);
    if (ev.includes("\x1f")) fail(`--evidence must not contain a unit separator (\\037): ${ev}`);
  }
  if (status === "fail" && v.cls === "defect") {
    const auth = v.auth!;
    const repro = v.repro!;
    if (auth === "-" || auth.replace(/[ \t\n\v\f\r]/g, "") === "")
      fail(
        `case ${id} fail --classification defect needs --authority <file:line | URL | 'captain <date>'> - WHO states the expected behaviour, and WHERE. With nothing citable this is unverifiable --note '<why>', never a defect: ac-qa.sh case ${id} unverifiable --tier ${v.tier} --note '<why it cannot be verified>'`,
      );
    if (repro === "-" || repro === "") fail(`case ${id} fail --classification defect needs --repro <path to an executable repro-${id}.sh declaring '# DISPUTED:' and '# HELD-CONSTANT:'>`);
    if (!isFile(repro)) fail(`--repro ${repro}: no such file`);
    if (!executable(repro)) fail(`--repro ${repro}: not executable`);
    if (run(["grep", "-qE", "^# DISPUTED:[[:space:]]*[^[:space:]]", repro]).status !== 0) fail(`--repro ${repro}: missing or empty '# DISPUTED: <the one variable under dispute>' header`);
    if (run(["grep", "-qE", "^# HELD-CONSTANT:[[:space:]]*[^[:space:]]", repro]).status !== 0)
      fail(`--repro ${repro}: missing or empty '# HELD-CONSTANT: <everything the two legs share, named>' header`);
  }
  const rd = runDir();
  const ready = qaTestplanReady(rd);
  if (ready !== null) fail(`case ${id} refused: ${ready}`);
  let boundary = v.boundary!;
  const receipt = v.receipt!;
  if (status === "pass" || status === "fail") {
    if (boundary === "-" || boundary === "")
      fail(
        `case ${id} ${status} needs --boundary <${BOUNDARIES.replaceAll(" ", "|")}>: a behavioral result names the client boundary it was stimulated through. A case with no reachable boundary is 'unverifiable' with an ask-user finding naming the missing boundary, never an in-process substitute.`,
      );
    if (receipt === "-" || receipt === "")
      fail(
        `case ${id} ${status} needs --receipt <path>: drive it with 'ac-qa.sh boundary-run' (or register a browser/e2e boundary with 'ac-qa.sh boundary-register') and pass the receipt it prints. A tier label and a completed serve step are not proof.`,
      );
  }
  if (receipt !== "-" && receipt !== "") {
    if (!qaReceiptPathOk(rd, id, receipt))
      fail(`case ${id}: --receipt must be a regular file this run published under ${rd}/boundaries/${id}/ - traversal, symlinks, and foreign paths are refused (got '${receipt}')`);
    let expected = "-";
    if (meta(receipt, "driver") === "browser") {
      const berr = qaBrowserManifestOk(rd, id, receipt);
      if (berr !== null) fail(`case ${id}: ${berr}`);
    } else if (ev !== "-" && exists(ev)) expected = qaPathSha(ev);
    const verr = qaBoundaryReceiptValidate(receipt, id, v.tier!, status, meta(`${rd}/run.meta`, "target_sha"), meta(`${rd}/run.meta`, "profile_sha256"), shaFile(`${rd}/runtime/receipt.env`) ?? "-", expected);
    if (verr !== null) fail(`case ${id}: ${verr}`);
    if (boundary !== "-" && boundary !== meta(receipt, "boundary")) fail(`case ${id}: --boundary ${boundary} contradicts the receipt's boundary ${meta(receipt, "boundary")}`);
    if (boundary === "-") boundary = meta(receipt, "boundary");
  }
  const row = [id, v.tier!, status, v.cls!, usScrub(v.conf!), v.grade!, ev, usScrub(v.note!), usScrub(v.auth!), usScrub(v.repro!), usScrub(boundary), receipt];
  const lock = `${rd}/.cases.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail("cases ledger lock timeout");
  const t = mktemp([`${rd}/.cases.tsv.XXXXXX`]);
  if (
    t.status !== 0 ||
    runTo(["awk", "-F\\t", "-v", `id=${id}`, "$1 != id", `${rd}/cases.tsv`], t.path) !== 0 ||
    append(t.path, `${row.join("\t")}\n`) !== 0 ||
    mv(t.path, `${rd}/cases.tsv`) !== 0
  ) {
    if (t.path) rm(t.path);
    lockRelease(u8(lock));
    fail(`cases ledger rewrite failed for: ${id} (the ledger is unchanged)`);
  }
  lockRelease(u8(lock));
  say(`case ${id}: ${status} (tier=${v.tier}${v.cls !== "-" ? ` class=${v.cls}` : ""})\n`);
}

function cmdVisual(a: string[]): void {
  requireRun();
  const usage = "usage: ac-qa.sh visual <path> [--case <id>] [--note <text>]";
  if (a.length < 1) fail(usage);
  const [path = "", ...rest] = a;
  let cid = "";
  let note = "-";
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i] === "--case") cid = flagValue(rest, i);
    else if (rest[i] === "--note") note = flagValue(rest, i);
    else fail(`unknown flag: ${rest[i]}`);
  }
  if (path === "") fail(usage);
  visualRegister(path, cid, note, true);
}

// THE visual registration; boundary-register's web arm calls it before the
// case row exists (requireCase false).
function visualRegister(path: string, cid: string, note: string, requireCase: boolean): void {
  const rd = runDir();
  let abs = path;
  if (!path.startsWith("/")) abs = isFile(`${b8(process.cwd())}/${path}`) ? `${b8(process.cwd())}/${path}` : `${cmdEvidenceDir()}/${path}`;
  if (abs.includes("\t")) fail(`visual path must not contain a tab: ${abs}`);
  if (abs.includes("\n")) fail(`visual path must not contain a newline: ${abs}`);
  if (!isFile(abs)) fail(`visual not found: ${abs}`);
  if (!nonEmpty(abs)) fail(`visual is empty: ${abs} (a capture that wrote nothing is not evidence)`);
  const kind = imageKind(abs) ?? fail(`not an image: ${abs} - the extension is never trusted; its magic bytes are not png/jpeg/gif/webp`);
  if (cid !== "" && requireCase && awk(["-F\\t", "-v", `id=${cid}`, "$1 == id { hit = 1 } END { exit !hit }", `${rd}/cases.tsv`]).status !== 0)
    fail(`--case ${cid} is not in the ledger: record the case first (ac-qa.sh case ${cid} ...)`);
  const n = run(["tr", "\t\n", "  "], { stdin: B(note) });
  ee(n.status);
  note = cap(n.out);
  const bytes = `${stat(abs)!.size}`;
  const lock = `${rd}/.visuals.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail("visuals ledger lock timeout");
  if (!isFile(`${rd}/visuals.tsv`)) ee(put(`${rd}/visuals.tsv`, ""));
  const t = mktemp([`${rd}/.visuals.tsv.XXXXXX`]);
  if (
    t.status !== 0 ||
    runTo(["/usr/bin/env", `p=${abs}`, "awk", "-F\\t", '$1 != ENVIRON["p"]', `${rd}/visuals.tsv`], t.path) !== 0 ||
    append(t.path, `${abs}\t${kind}\t${bytes}\t${cid || "-"}\t${iso()}\t${note}\n`) !== 0 ||
    mv(t.path, `${rd}/visuals.tsv`) !== 0
  ) {
    if (t.path) rm(t.path);
    lockRelease(u8(lock));
    fail(`visuals ledger rewrite failed for: ${abs} (the ledger is unchanged)`);
  }
  lockRelease(u8(lock));
  say(`visual ${kind} registered: ${abs} (${bytes} bytes${cid !== "" ? `, case ${cid}` : ""})\n`);
}

function cmdFindings(a: string[]): void {
  requireRun();
  const step = a[0] ?? "";
  if (!inList(STEPS, step)) fail(`unknown step: ${step}`);
  const mode = a[1] ?? "";
  if (mode !== "--show" && mode !== "") fail("usage: ac-qa.sh findings <step> [--show]");
  const f = `${runDir()}/findings/${step}.json`;
  if (mode === "--show") {
    if (!isFile(f)) fail(`no findings recorded for step ${step}`);
    const t = readText(f);
    if (t === null) fatal(1);
    say(t!);
    return;
  }
  if (isatty(0)) fail(`findings ${step} reads a JSON array on stdin - refusing a tty (pipe JSON in, or use --show to view)`);
  const json = cap(readStdin().toString("latin1"));
  if (jq(["-e", 'type == "array"'], { stdin: B(`${json}\n`), stdout: "ignore" }).status !== 0) fail("findings must be a JSON array");
  ee(findingsNormalize(f, B(`${json}\n`)));
  const s = findingsSummary(f);
  say(s.out);
  ee(s.status);
}

// --- the oracle amendment, harness classification, regression proposal, curation --

// <argv> with stdout into an already-open fd (an exclusive temp), closed after.
function runToFd(argv: string[], fd: number): number {
  try {
    return run(argv, { stdout: fd }).status;
  } finally {
    closeSync(fd);
  }
}
// `x="$(printf '%s' "$v" | tr '\t\r\n' '   ')"` in the caller's locale; a
// failing tr leaves what it wrote (a printf argument's substitution never
// ends the run).
const trScrub = (v: string): string => cap(run(["tr", "\t\r\n", "   "], { stdin: B(v) }).out);
// `${v//[[:space:]]/}` is empty.
const blank = (v: string): boolean => v.replace(/[ \t\n\v\f\r]/g, "") === "";

const AMEND_DENY = [
  "implementation",
  "implementation-behavior",
  "source",
  "source-code",
  "source code",
  "current code",
  "source implementation",
  "current implementation",
  "the code currently does this",
  "code currently does this",
];
const AMEND_ENTRY_JQ = `{schema:"agentcrew.qa-oracle-amendment/v1",old_sha256:$old,new_sha256:$new,
      cases:$cases,authority:$authority,reason:$reason,recorded_at:$at}`;

function cmdTestplanAmend(a: string[]): void {
  requireRun();
  let authority = "";
  let reason = "";
  let caseJson = "[]";
  for (let i = 0; i < a.length; ) {
    const f = a[i]!;
    if (f === "--case") {
      const id = a[i + 1] ?? "";
      if (id === "" || /[^A-Za-z0-9_.-]/.test(id)) fail("testplan-amend --case must be [A-Za-z0-9_.-]");
      const r = jq(["-c", "--arg", "id", id, ". + [$id] | unique"], { stdin: B(`${caseJson}\n`) });
      ee(r.status);
      caseJson = cap(r.out);
      if (i + 2 > a.length) fatal(1);
      i += 2;
    } else if (f === "--authority" || f === "--reason") {
      if (i + 2 > a.length) fail(`${f} needs a value`);
      if (f === "--authority") authority = a[i + 1]!;
      else reason = a[i + 1]!;
      i += 2;
    } else fail("usage: ac-qa.sh testplan-amend --case <id> [--case <id> ...] --authority <accepted-authority> --reason <why>");
  }
  const len = jq(["length"], { stdin: B(`${caseJson}\n`) });
  if (!((testInt(cap(len.out)) ?? 0n) > 0n)) fail("testplan-amend requires at least one --case");
  if (blank(authority)) fail("testplan-amend requires accepted behavioral authority");
  if (blank(reason)) fail("testplan-amend requires a reason");
  const lower = run(["tr", "[:upper:]", "[:lower:]"], { stdin: B(authority) });
  const trimmed = cap(run(["sed", "s/^[[:space:]]*//; s/[[:space:]]*$//"], { stdin: B(lower.out) }).out);
  if (AMEND_DENY.includes(trimmed)) fail("source implementation alone cannot redefine the oracle; record the case unverifiable or raise an ask-user finding");
  const rd = runDir();
  if (stepStatus(rd, "testplan") !== "completed") fail("testplan-amend requires the testplan step to be completed first");
  const oldSha = meta(`${rd}/run.meta`, "testplan_sha256");
  if (oldSha === "") fail("testplan-amend found no frozen test-plan hash");
  const testplan = `${dirname(cmdEvidenceDir())}/testplan.md`;
  if (!isFile(testplan)) fail(`testplan-amend cannot find the durable test plan: ${testplan}`);
  const newSha = shaFileA(testplan);
  if (newSha === oldSha) fail("testplan-amend requires an actual test-plan content change");
  const manifest = `${rd}/testplan-manifest.json`;
  if (!isFile(manifest)) fail("testplan-amend found no frozen test-plan manifest");
  if (shaFile(manifest) !== meta(`${rd}/run.meta`, "testplan_manifest_sha256")) fail("testplan-amend found a stale or corrupt frozen manifest");
  const mt = mktemp([`${rd}/.testplan-manifest-amend.XXXXXX`]);
  ee(mt.status);
  const r = qaTestplanManifestRender(repo, meta(`${rd}/run.meta`, "target_sha"), testplan);
  if (put(mt.path, r.out.toString("latin1")) !== 0) {
    rm(mt.path);
    fatal(1);
  }
  if (r.status !== 0) {
    rm(mt.path);
    fail(`testplan-amend refused: ${r.error}`);
  }
  const ut = qaTestplanUtRowsOk(rd, mt.path);
  if (ut !== null) {
    rm(mt.path);
    fail(`testplan-amend refused: ${ut}`);
  }
  const changed = jq(["-e", "--slurpfile", "old", manifest, ".coverage == $old[0].coverage and .full_flow == $old[0].full_flow", mt.path], { stdout: "ignore" }).status !== 0;
  if (changed && qaCaseEvidenceExists(rd)) {
    rm(mt.path);
    fail("testplan-amend refused: coverage/full-flow selection is frozen after case evidence exists; start a fresh QA round");
  }
  const manifestSha = shaFileA(mt.path);
  authority = scrubA(authority);
  reason = scrubA(reason);
  const ledger = `${rd}/oracle-amendments.jsonl`;
  const lock = `${rd}/.testplan-amend.lock.d`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail("testplan-amend lock timeout");
  const t = mktemp([`${rd}/.oracle-amendments.XXXXXX`]);
  ee(t.status);
  if (isFile(ledger)) ee(runTo(["cat", ledger], t.path));
  const entry = jq(["-cn", "--arg", "old", oldSha, "--arg", "new", newSha, "--arg", "authority", authority, "--arg", "reason", reason, "--arg", "at", iso(), "--argjson", "cases", caseJson, AMEND_ENTRY_JQ]);
  ee(entry.status);
  ee(append(t.path, `${cap(entry.out)}\n`));
  let mtmp: { path: string; fd: number } | undefined;
  try {
    mtmp = exclusiveTemp(u8(`${rd}/run.meta.amend`));
  } catch {}
  const metaTmp = mtmp === undefined ? "" : b8(mtmp.path);
  if (mtmp === undefined || runToFd(["awk", "-F=", '$1!="testplan_sha256" && $1!="testplan_manifest_sha256" && $1!="testplan_path"', `${rd}/run.meta`], mtmp.fd) !== 0) {
    rm(t.path);
    rm(mt.path);
    if (metaTmp !== "") rm(metaTmp);
    lockRelease(u8(lock));
    fail("testplan-amend refused: could not rewrite run.meta (the run is unchanged)");
  }
  ee(append(metaTmp, `testplan_sha256=${newSha}\ntestplan_manifest_sha256=${manifestSha}\ntestplan_path=${testplan}\n`));
  if (mv(t.path, ledger) !== 0 || mv(mt.path, manifest) !== 0 || mv(metaTmp, `${rd}/run.meta`) !== 0) {
    rm(t.path);
    rm(mt.path);
    rm(metaTmp);
    lockRelease(u8(lock));
    fail("testplan-amend could not publish the amendment");
  }
  lockRelease(u8(lock));
  say(`testplan amended: ${oldSha} -> ${newSha} cases=${cap(jq(["-r", 'join(",")'], { stdin: B(`${caseJson}\n`) }).out)}\n`);
}

const FIXTURE_MANIFEST_JQ = `
    type == "object"
    and .schema == "agentcrew.qa-fixture-pack/v1"
    and (.id | type) == "string" and (.id | length) > 0
    and (.runner | type) == "string" and (.runner | length) > 0
    and (.selectors | type) == "array" and (.selectors | length) > 0
    and all(.selectors[]; type == "string" and length > 0)
    and ((.selectors | unique | length) == (.selectors | length))
    and (.capabilities | type) == "array"
    and all(.capabilities[]; type == "string" and length > 0)
    and (.mutation as $m | ["read-only","read-write"] | index($m) != null)
    and (.retry as $r | ["idempotent","read-only"] | index($r) != null)
    and (if .mutation == "read-write" then .retry == "idempotent" else true end)
    and ((.assets // []) | type) == "array"
    and all((.assets // [])[]; type == "string" and length > 0)
  `;
const unsafeRel = (r: string): boolean => r === "" || r.startsWith("/") || r === ".." || r.startsWith("../") || r.includes("/../") || r.endsWith("/..");

// A path-closed, retry-safe fixture-pack manifest.
function qaFixtureManifestValidate(pack: string): boolean {
  const manifest = `${pack}/manifest.json`;
  if (!isFile(manifest) || isLink(manifest)) return false;
  if (jq(["-e", FIXTURE_MANIFEST_JQ, manifest], { stdout: "ignore", stderr: "ignore" }).status !== 0) return false;
  for (const rel of lines(jq(["-r", ".runner, (.assets // [])[]", manifest]).out)) {
    if (unsafeRel(rel)) return false;
    if (!isFile(`${pack}/${rel}`) || isLink(`${pack}/${rel}`)) return false;
  }
  return true;
}

function cmdHarnessClassify(a: string[]): void {
  requireRun();
  if (a.length < 1) fail("usage: ac-qa.sh harness-classify <path> --classification <kind> --target <target> --invariant <text> --evidence <path>");
  let [path = "", ...rest] = a;
  const v: Record<string, string> = { "--classification": "", "--target": "", "--invariant": "", "--evidence": "" };
  for (let i = 0; i < rest.length; i += 2) {
    if (!Object.hasOwn(v, rest[i]!)) fail(`unknown harness-classify flag: ${rest[i]}`);
    if (i + 2 > rest.length) fail(`${rest[i]} needs a value`);
    v[rest[i]!] = rest[i + 1]!;
  }
  const classification = v["--classification"]!;
  const target = v["--target"]!;
  const invariant = v["--invariant"]!;
  let evidence = v["--evidence"]!;
  if (!["repo-regression", "e2e-regression", "fixture-pack", "evidence-only", "retire"].includes(classification))
    fail("harness classification must be repo-regression|e2e-regression|fixture-pack|evidence-only|retire");
  if (path === "" || target === "" || invariant === "" || evidence === "") fail("harness-classify requires path, classification, target, invariant, and evidence");
  if (!isFile(path)) fail(`harness-classify path is not a file: ${path}`);
  const pdir = run(["/bin/sh", "-c", 'cd "$1" && pwd -P', "sh", dirname(path)]);
  ee(pdir.status);
  path = `${cap(pdir.out)}/${basename(path)}`;
  const rd = runDir();
  if (!qaEvidencePathOk(cmdEvidenceDir(), evidence)) fail(`harness-classify evidence is missing, broken, or outside the declared evidence root: ${evidence}`);
  if (!evidence.startsWith("/")) evidence = `${cmdEvidenceDir()}/${evidence}`;
  evidence = b8(pyRealpath(u8(evidence), cwdFn));
  const ledger = `${rd}/regression-candidates.tsv`;
  const t = mktemp([`${rd}/.regression-candidates.XXXXXX`]);
  ee(t.status);
  if (isFile(ledger)) ee(runTo(["awk", "-F\\t", "-v", `p=${path}`, "$1 != p", ledger], t.path));
  ee(append(t.path, `${trScrub(path)}\t${classification}\t${trScrub(target)}\t${trScrub(invariant)}\t${trScrub(evidence)}\n`));
  ee(mv(t.path, ledger));
  say(`harness classified: ${path} -> ${classification}\n`);
}

function cmdRegressionProposal(a: string[]): void {
  requireRun();
  const patch = a[0] ?? "";
  if (a.length !== 1 || !isFile(patch)) fail("usage: ac-qa.sh regression-proposal <test-only.patch>");
  const heads = run(["sed", "-n", "-e", "s/^--- //p", "-e", "s/^+++ //p", patch]);
  for (let path of lines(run(["sed", "s/[[:space:]].*$//"], { stdin: B(heads.out) }).out)) {
    if (path === "/dev/null") continue;
    path = path.replace(/^a\//, "").replace(/^b\//, "");
    const test = /^(tests|test|spec|specs)\//.test(path) || /\/(tests|test|spec|specs)\//.test(path) || path.includes("__tests__/") || /\.test\./.test(path) || /\.spec\./.test(path);
    if (!test) fail(`regression proposal touches a production path: ${path}`);
  }
  if (cap(run(["sed", "-n", "-e", "s/^--- //p", "-e", "s/^+++ //p", patch]).out) === "") fail("regression proposal contains no file changes");
  const out = `${cmdEvidenceDir()}/regression-proposal.patch`;
  ee(mkdirp(dirname(out)));
  const t = mktemp([`${out}.XXXXXX`]);
  ee(t.status);
  ee(run(["cp", patch, t.path], { stdout: "inherit" }).status);
  ee(mv(t.path, out));
  say(`${out}\n`);
}

function cmdCuration(a: string[]): void {
  requireRun();
  const usage = "usage: ac-qa.sh curation <completed|skipped|failed> [--note <reason>]";
  if (a.length < 1) fail(usage);
  const [status = "", ...rest] = a;
  let note = "";
  if (rest.length > 0) {
    if (rest.length !== 2 || rest[0] !== "--note") fail(usage);
    note = rest[1]!;
  }
  if (!["completed", "skipped", "failed"].includes(status)) fail(`invalid curation status: ${status}`);
  if (status !== "completed" && blank(note)) fail(`curation ${status} requires --note <reason>`);
  note = scrubA(note);
  if (note === "") note = "-";
  const rd = runDir();
  if (!["passed", "failed", "unverifiable", "cancelled"].includes(meta(`${rd}/run.meta`, "outcome"))) fail("curation is valid only after a terminal QA outcome");
  if (!lockAcquire(u8(`${rd}/.curation.lock`), 30, sleepOne)) fail("curation receipt lock timeout");
  const t = mktemp([`${rd}/.run-meta-curation.XXXXXX`]);
  ee(t.status);
  ee(runTo(["awk", "-F=", '$1!="curation" && $1!="curation_note"', `${rd}/run.meta`], t.path));
  ee(append(t.path, `curation=${status}\ncuration_note=${note}\n`));
  ee(mv(t.path, `${rd}/run.meta`));
  lockRelease(u8(`${rd}/.curation.lock`));
  say(`curation=${status} note=${note}\n`);
}

// --- the QA knowledge store -------------------------------------------------------

const MERGE_JQ = ".entries += [{path:$path,sha256:$sha}] | .entries |= sort_by(.path)";

// One (path, sha256) entry merged into a store-snapshot manifest, sorted by
// path, through an exclusive temp beside it (W14); false when it fails.
function qaStoreManifestMerge(manifest: string, rel: string, hash: string): boolean {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(`${manifest}.tmp`));
  } catch {
    return false;
  }
  if (runToFd(["jq", "--arg", "path", rel, "--arg", "sha", hash, MERGE_JQ, manifest], t.fd) !== 0) return false;
  return mv(b8(t.path), manifest) === 0;
}

// The canonical content receipt of a store dir (its manifest.json aside).
function qaStoreManifestBuild(source: string, output: string): void {
  ee(runTo(["jq", "-n", '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}'], output));
  if (!isDir(source)) return;
  const found = run(["find", source, "-type", "f", "!", "-path", output, "-print"]);
  for (const file of lines(run(["/usr/bin/env", "LC_ALL=C", "sort"], { stdin: B(found.out) }).out)) {
    if (file === "") continue;
    const rel = file.startsWith(`${source}/`) ? file.slice(source.length + 1) : file;
    if (rel === "manifest.json") continue;
    if (rel.startsWith("/") || rel === ".." || rel.startsWith("../") || rel.includes("/../") || rel.endsWith("/..") || rel.includes("\t") || rel.includes("\n"))
      fail(`qa store contains an unsafe relative path: ${rel}`);
    if (!qaStoreManifestMerge(output, rel, shaFileA(file))) fail("could not build QA store manifest");
  }
}

function cmdStoreCurate(a: string[]): void {
  requireRun();
  let candidate = "";
  let after = "3";
  for (let i = 0; i < a.length; i += 2) {
    const f = a[i]!;
    if (f !== "--candidate" && f !== "--promote-after") fail("usage: ac-qa.sh store-curate --candidate <dir> [--promote-after <n>]");
    if (i + 2 > a.length) fail(`${f} needs a value`);
    if (f === "--candidate") candidate = a[i + 1]!;
    else after = a[i + 1]!;
  }
  if (candidate === "" || !isDir(`${candidate}/store`)) fail("store-curate needs --candidate <dir> carrying store/ (the candidate the curation step writes)");
  if (after === "" || /[^0-9]/.test(after) || after === "0") fail("--promote-after must be a positive integer");
  const rd = runDir();
  const store = `${candidate}/store`;
  const plan = qaTestplanPath();
  const m = `${rd}/run.meta`;
  const n = qaStoreHistoryAppend(store, `${rd}/cases.tsv`, plan, meta(m, "target_sha"), meta(m, "qa_model") || "-", meta(m, "task") || "-");
  const prom = qaStorePromote(store, `${rd}/cases.tsv`, plan, meta(m, "target_sha"), after);
  say(`QA-STORE-CURATED: history=+${n} ${prom} store=${store}\n`);
}

// <data>/qa-store/<scope>, the home's data/ minted on the way (ac_data_dir).
const homeStore = (): string => qaStorePath(b8(dataDir()));

function cmdStoreLabel(a: string[]): void {
  const usage = "usage: ac-qa.sh store-label <case-id> --run <sha> <confirmed|not-a-defect> [--by <who>]";
  const id = a[0] ?? "";
  if (id === "") fail(usage);
  let label = "";
  let sha = "";
  let by = "chief";
  for (let i = 1; i < a.length; ) {
    const f = a[i]!;
    if (f === "--run" || f === "--by") {
      if (i + 2 > a.length) fail(`${f} needs a value`);
      if (f === "--run") sha = a[i + 1]!;
      else by = a[i + 1]!;
      i += 2;
    } else if (f === "confirmed" || f === "not-a-defect") {
      label = f;
      i += 1;
    } else fail(usage);
  }
  if (sha === "" || label === "") fail("store-label needs --run <sha> and one of confirmed|not-a-defect");
  if (!process.env.AC_HOME) fail("store-label is chief-side and needs AC_HOME (the labels sit beside the fleet's store)");
  const f = `${homeStore()}.labels.tsv`;
  ee(mkdirp(dirname(f)));
  ee(append(f, `${sha}\t${id}\t${label}\t${by}\t${iso()}\n`));
  say(`labelled ${id}@${sha} ${label} (${f})\n`);
}

function cmdStoreCalibration(): void {
  if (!process.env.AC_HOME) fail("store-calibration is chief-side and needs AC_HOME");
  const base = homeStore();
  const r = qaStoreCalibration(`${base}/history.tsv`, `${base}.labels.tsv`);
  ee(r.status);
  ee(put(`${base}.calibration.json`, `${r.out}\n`));
  say(`${r.out}\n`);
}

// A signal held through a synchronous child acts only when the event loop
// turns; store-install turns it after each child from the manifest build on,
// so a signal never lets a later move of the store run.
const turn = (): Promise<void> => new Promise((r) => setTimeout(r, 0));

async function cmdStoreInstall(a: string[]): Promise<void> {
  let candidate = a[0] ?? "";
  if (a.length !== 1 || !isDir(`${candidate}/store`)) fail("usage: ac-qa.sh store-install <candidate-dir-with-store-and-base-manifest.sha256>");
  if (!process.env.AC_HOME) fail("store-install is chief-only and requires the canonical fleet AC_HOME");
  candidate = b8(physicalDir(u8(candidate)) ?? fatal(1));
  const source = `${candidate}/store`;
  const baseSha = cap(readText(`${candidate}/base-manifest.sha256`) ?? "");
  if (baseSha === "" || /[^0-9a-f]/.test(baseSha)) fail("curation candidate has no valid base-manifest.sha256");
  if (baseSha.length !== 64) fail("curation candidate base manifest hash must be SHA-256");
  if (cap(run(["find", source, "-type", "l", "-print", "-quit"]).out) !== "") fail("curation candidate store contains symlinks");
  const h = process.env.AC_HOME;
  const home = b8(physicalDir(h) ?? fail(`AC_HOME is not a readable directory: ${h}`));
  const dest = qaStorePath(`${home}/data`);
  ee(mkdirp(dirname(dest)));
  const lock = `${dest}.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail(`store-install lock timeout for ${dest}`);
  // The original's EXIT trap releases the lock and drops the temp on every
  // exit past here - TERM, HUP and INT included (bash 3.2 runs it there).
  let manifest = "";
  const cleanup = (): void => {
    if (manifest !== "") rm(manifest);
    lockRelease(u8(lock));
  };
  const handlers = (["SIGHUP", "SIGINT", "SIGTERM"] as const).map((sig, k) => [sig, () => process.exit(128 + [1, 2, 15][k]!)] as const);
  process.on("exit", cleanup);
  for (const [sig, h2] of handlers) process.on(sig, h2);
  const m = mktemp([]);
  ee(m.status);
  manifest = m.path;
  qaStoreManifestBuild(dest, manifest);
  await turn();
  const currentSha = shaFileA(manifest);
  if (currentSha !== baseSha) fail(`store-install conflict: candidate base=${baseSha} current=${currentSha}; review against the newer store`);
  const st = mktemp(["-d", `${dirname(dest)}/.${basename(dest)}.curation.XXXXXX`]);
  ee(st.status);
  ee(run(["cp", "-R", `${source}/.`, `${st.path}/`], { stdout: "inherit" }).status);
  await turn();
  let previous = "";
  if (isDir(dest)) {
    previous = `${dest}.prev`;
    ee(run(["rm", "-rf", previous], { stdout: "inherit" }).status);
    await turn();
    ee(mv(dest, previous));
    await turn();
  }
  ee(mv(st.path, dest));
  await turn();
  rm(manifest);
  lockRelease(u8(lock));
  process.removeListener("exit", cleanup);
  for (const [sig, h2] of handlers) process.removeListener(sig, h2);
  say(`QA-STORE-INSTALLED: ${dest} base=${baseSha}${previous ? ` previous=${previous}` : ""}\n`);
}

// --- infra ------------------------------------------------------------------------

// `for w in $<text>` as the original's unquoted loops read a service list:
// split, then pathname-expanded against the caller's cwd - by bash, so a
// pattern word matching a file there names that file, as it did.
function words(text: string): string[] {
  const r = run(["/bin/bash", "--posix", "-c", "for w in $1; do printf '%s\\0' \"$w\"; done", "ac-qa.sh", text]);
  return r.out.split("\0").slice(0, -1);
}

const DETECT_SH = `{ cd "$1" 2>/dev/null && {
        cat requirements*.txt pyproject.toml Pipfile package.json go.mod \\
            go.sum Gemfile Gemfile.lock composer.json pom.xml build.gradle \\
            .env.example .env.sample .env.template 2>/dev/null
        grep -rhoiE 'image:[[:space:]]*[^[:space:]]*(postgres|redis|temporal)' \\
            docker-compose*.y*ml compose*.y*ml 2>/dev/null
      }; } | tr '[:upper:]' '[:lower:]'
    true`;

// The shipped profiles the repo's manifests point at, a comma list.
function infraDetect(): string {
  const hay = cap(run(["/bin/sh", "-c", DETECT_SH, "sh", repo]).out);
  const has = (re: RegExp): boolean => hay.split("\n").some((l) => re.test(l));
  let want = "";
  if (has(/psycopg|postgres|pg8000|asyncpg|sqlalchemy|pgx|lib\/pq|jackc\/pgx|database_url|pg_|activerecord.*postgres/)) want += " postgres";
  if (has(/redis|ioredis|go-redis|redis_url|redigo/)) want += " redis";
  if (has(/temporal/)) want += " temporal";
  return want.replace(/ +/g, " ").replace(/^ /, "").replace(/ /g, ",");
}

// <run>/ports.env: the host ports compose published, then QA_PORT.
function portsEnv(rd: string, proj: string, services: string): void {
  ee(put(`${rd}/ports.env`, ""));
  const map: Record<string, [string, (p: string) => string]> = {
    postgres: ["5432", (p) => `QA_PG_URL=postgresql://test:test@127.0.0.1:${p}/test\nQA_PG_PORT=${p}\n`],
    redis: ["6379", (p) => `QA_REDIS_URL=redis://127.0.0.1:${p}\nQA_REDIS_PORT=${p}\n`],
    temporal: ["7233", (p) => `QA_TEMPORAL_ADDR=127.0.0.1:${p}\n`],
    wiremock: ["8080", (p) => `QA_MOCK_URL=http://127.0.0.1:${p}\n`],
  };
  for (const svc of words(run(["tr", ",", " "], { stdin: B(`${services}\n`) }).out)) {
    const m = map[svc];
    if (m === undefined) continue;
    const r = run(["docker", "compose", "-p", proj, "port", svc, m[0]], { stderr: "ignore" });
    const port = cap(awk(["-F:", "{print $NF}"], { stdin: B(r.out) }).out);
    if (port !== "") ee(append(`${rd}/ports.env`, m[1](port)));
  }
  const qaPort = `${freePort()}`;
  ee(append(`${rd}/ports.env`, `QA_PORT=${qaPort}\nQA_BASE_URL=http://127.0.0.1:${qaPort}\n`));
}

function cmdInfra(a: string[]): number {
  const [verb = "", ...rest] = a;
  let services = "";
  let taskFlag = "";
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i] === "--services") services = flagValue(rest, i);
    else if (rest[i] === "--task") taskFlag = flagValue(rest, i);
    else fail(`unknown flag: ${rest[i]}`);
  }
  switch (verb) {
    case "detect":
      requireRun();
      say(`${infraDetect()}\n`);
      return 0;
    case "up": {
      requireRun();
      const rd = runDir();
      const proj = composeProject();
      const tr = run(["tr", ",", " "], { stdin: B(`${services}\n`) });
      const xa = run(["xargs"], { stdin: B(tr.out) });
      ee(xa.status || tr.status);
      const svclist = cap(xa.out);
      const svcs = words(svclist);
      let bad = "";
      for (const s of svcs) if (!inList(KNOWN_SERVICES, s)) bad += ` ${s}`;
      if (bad !== "") fail(`unknown qa service(s):${bad} (known: ${KNOWN_SERVICES})`);
      if (isFile(`${rd}/infra.declared`)) {
        const declared = cap(readText(`${rd}/infra.declared`) ?? fatal(1));
        let undeclared = "";
        for (const s of svcs) if (!` ${declared} `.includes(` ${s} `)) undeclared += `${s} `;
        if (undeclared !== "")
          fail(
            `infra up refused: this run declared '${declared || "(none)"}' and ${undeclared}is outside it.\nA qa run declares its infra need ONCE and nothing outside that declaration boots (see INFRA CONTAINMENT in this script's header). Park the case instead:\n  ac-qa.sh case <id> unverifiable --tier <t> --classification environment --note 'needs ${undeclared}- outside the run declaration'\nA need you got WRONG is re-declared deliberately: fix the testplan's '## Infra' block and start a fresh run (ac-qa.sh start --target <ref> --task <id>).`,
          );
      } else ee(put(`${rd}/infra.declared`, `${svclist}\n`));
      require("bun");
      if (svclist === "") {
        portsEnv(rd, proj, "");
        say("infra up: no backend services (service needs none)\n");
        return 0;
      }
      require("docker");
      const args = composeFiles();
      for (const s of svcs) args.push("--profile", s);
      if (run(["docker", "compose", "-p", proj, ...args, "up", "-d", "--wait"], { stdout: "inherit" }).status !== 0)
        fail(`infra up failed (project ${proj}); logs: docker compose -p ${proj} logs`);
      portsEnv(rd, proj, services);
      say(`infra up: ${proj} (${svclist})\n`);
      return 0;
    }
    case "down": {
      require("docker");
      let proj: string;
      if (taskFlag !== "") proj = `crew-qa-${repoScope()}-${sanitizeCompose(taskFlag)}`;
      else {
        requireRun();
        proj = composeProject();
      }
      if (!proj.startsWith("crew-qa-")) fail(`refusing down of non-crew-qa project: ${proj}`);
      const rc = run(["docker", "compose", "-p", proj, "down", "-v", "--remove-orphans"], { stdout: "inherit", stderr: "ignore" }).status;
      say(`infra down: ${proj}\n`);
      return rc;
    }
    case "status": {
      require("docker");
      const ps = run(["docker", "ps", "--filter", "label=com.docker.compose.project", "--format", '{{.Label "com.docker.compose.project"}}\\t{{.Names}}\\t{{.Status}}']);
      const g = run(["grep", "-F", `crew-qa-${repoScope()}-`], { stdin: B(ps.out), stdout: "inherit" });
      if (ps.status !== 0 || g.status !== 0) say("(no crew-qa containers for this repo)\n");
      return 0;
    }
    case "reap": {
      if (!commandV("docker")) {
        say("reap: docker absent, nothing to do\n");
        return 0;
      }
      const scope = repoScope();
      const main = b8(repoRoot(u8(repo)) ?? "");
      const ps = run(["docker", "ps", "-a", "--filter", "label=crew.qa=1", "--format", '{{.Label "com.docker.compose.project"}}'], { stderr: "ignore" });
      const sorted = run(["sort", "-u"], { stdin: B(ps.out) });
      const projects = cap(run(["grep", "-F", `crew-qa-${scope}-`], { stdin: B(sorted.out) }).out);
      if (projects === "") {
        say("reap: nothing to reap\n");
        return 0;
      }
      const worktrees: string[] = [];
      for (const l of lines(run(["git", "-C", main, "worktree", "list", "--porcelain"]).out)) if (l.startsWith("worktree ")) worktrees.push(l.slice("worktree ".length));
      if (worktrees.length === 0) fail(`reap: cannot list the worktrees of ${main} - nothing reaped`);
      for (const p of lines(`${projects}\n`)) {
        let live = false;
        for (const wt of worktrees) {
          for (const m of runMetas(wt)) {
            if (run(["grep", "-qx", "outcome=running", m]).status !== 0) continue;
            const t = cap(firstLine(run(["sed", "-n", "s/^task=//p", m]).out));
            if (`crew-qa-${scope}-${sanitizeCompose(t || basename(dirname(m)))}` === p) {
              live = true;
              break;
            }
          }
          if (live) break;
        }
        if (!live) {
          run(["docker", "compose", "-p", p, "down", "-v", "--remove-orphans"], { stdout: "inherit", stderr: "ignore" });
          say(`reaped ${p}\n`);
        }
      }
      return 0;
    }
  }
  return fail("usage: ac-qa.sh infra <detect|up|down|status|reap>");
}

// `<wt>/.crew/qa/*/run.meta` that are regular files, in byte order.
function runMetas(wt: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(B(`${wt}/.crew/qa`), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort()
    .map((n) => `${wt}/.crew/qa/${n}/run.meta`)
    .filter(isFile);
}

// --- the live service: baseline, boundaries, serve, health, seed -----------------

// bash's builtin `kill -0 <text>`: a decimal (a leading `-` names a group).
function killZero(text: string): boolean {
  if (!/^-?[0-9]+$/.test(text)) return false;
  try {
    process.kill(Number(text), 0);
    return true;
  } catch {
    return false;
  }
}

function cmdBaseline(): void {
  requireRun();
  const rd = runDir();
  const status = qaShipReceiptStatus(`${rd}/profile/ship/test-receipt.env`, meta(`${rd}/run.meta`, "target_sha"));
  stepOwner = "baseline";
  muted(() => cmdStep(["baseline", "completed", "--note", status]));
  stepOwner = "";
  say(`baseline: ship test receipt ${status} (receipt check only; the suite was NOT re-run; UT coverage requires qualification)\n`);
}

// `--flag) x="${2:-}"; shift 2 || ac_die "$1 needs a value"` over <a>, stopping
// at `--` when <dashdash>; the rest after it.
function valueFlags(a: string[], names: string[], usage: string, dashdash = false): { v: Record<string, string>; rest: string[] } {
  const v: Record<string, string> = {};
  for (const n of names) v[n] = "";
  let i = 0;
  while (i < a.length) {
    const f = a[i]!;
    if (dashdash && f === "--") return { v, rest: a.slice(i + 1) };
    if (!names.includes(f)) fail(usage);
    if (i + 2 > a.length) fail(`${f} needs a value`);
    v[f] = a[i + 1]!;
    i += 2;
  }
  return { v, rest: [] };
}

function cmdBoundaryRun(a: string[]): number {
  requireRun();
  const usage = "usage: ac-qa.sh boundary-run --case <id> --boundary <http|grpc|client-cli|workflow|queue|schedule> --evidence <path> -- <command> [args...]";
  const { v, rest } = valueFlags(a, ["--case", "--boundary", "--evidence"], usage, true);
  const caseId = v["--case"]!;
  const boundary = v["--boundary"]!;
  const evidence = v["--evidence"]!;
  if (caseId === "" || boundary === "" || evidence === "" || rest.length === 0) fail(usage);
  if (badId(caseId)) fail(`case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '${caseId}'`);
  if (!["http", "grpc", "client-cli", "workflow", "queue", "schedule"].includes(boundary))
    fail(
      "boundary-run drives shell clients only: --boundary must be http|grpc|client-cli|workflow|queue|schedule (a browser run registers with 'boundary-register --boundary web', an approved E2E run with '--boundary e2e'; QA never executes UT)",
    );
  const rd = runDir();
  const ready = qaTestplanReady(rd);
  if (ready !== null) fail(`boundary-run refused: ${ready}`);
  const rerr = qaRuntimeReceiptOk(rd);
  if (rerr !== null)
    fail(
      `boundary-run refused: ${rerr}. Boot the deliverable with 'ac-qa.sh serve' and publish its runtime receipt with 'ac-qa.sh health' first - a case that never reached a booted system is not behavioral evidence.`,
    );
  if (!exists(evidence)) fail(`boundary-run --evidence ${evidence}: no such file or directory`);
  // `${s:+$'\n'}`: a leading empty argument adds no separator.
  const stimulus = rest.reduce((s, arg) => (s === "" ? arg : `${s}\n${arg}`), "");
  const benv = qaBoundaryEnv(rd);
  const started = iso();
  const rc = teeRun(["/usr/bin/env", "-i", ...benv, ...rest], repo, `${rd}/logs/boundary-${caseId}.log`, true);
  const ended = iso();
  ee(append(`${rd}/logs/run.log`, `${iso()} boundary-run case=${caseId} boundary=${boundary} exit=${rc}\n`));
  say(`${qaBoundaryReceiptPublish(rd, caseId, boundary, "command", sha(stimulus), qaPathSha(evidence), "-", started, ended, `${rc}`)}\n`);
  return rc;
}

function cmdBoundaryRegister(a: string[]): void {
  requireRun();
  const { v } = valueFlags(
    a,
    ["--case", "--boundary", "--transcript", "--visual", "--upstream-receipt", "--evidence"],
    "usage: ac-qa.sh boundary-register --case <id> --boundary <web|e2e> [--transcript <p> --visual <p>] [--upstream-receipt <p> --evidence <p>]",
  );
  const caseId = v["--case"]!;
  if (caseId === "") fail("boundary-register requires --case <id>");
  if (badId(caseId)) fail(`case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '${caseId}'`);
  const rd = runDir();
  const ready = qaTestplanReady(rd);
  if (ready !== null) fail(`boundary-register refused: ${ready}`);
  const rerr = qaRuntimeReceiptOk(rd);
  if (rerr !== null) fail(`boundary-register refused: ${rerr}`);
  const boundary = v["--boundary"]!;
  if (boundary === "web") {
    const transcript = v["--transcript"]!;
    const visual = v["--visual"]!;
    if (transcript === "" || !isFile(transcript)) fail("boundary-register --boundary web requires --transcript <path to the browser transcript>");
    if (visual === "" || !isFile(visual)) fail("boundary-register --boundary web requires --visual <path to the screenshot>");
    muted(() => visualRegister(visual, caseId, "browser boundary evidence", false));
    const manifest = `${rd}/boundaries/${caseId}/browser-${stampA()}-${process.pid}.manifest`;
    ee(mkdirp(dirname(manifest)));
    ee(put(manifest, `transcript ${qaPathSha(transcript)}\nvisual ${qaPathSha(visual)}\n`));
    const evSha = shaFileA(manifest);
    const now = iso();
    say(`${qaBoundaryReceiptPublish(rd, caseId, "web", "browser", qaPathSha(transcript), evSha, "-", now, now, "0")}\n`);
  } else if (boundary === "e2e") {
    const upstream = v["--upstream-receipt"]!;
    const evidence = v["--evidence"]!;
    if (upstream === "" || !isFile(upstream)) fail("boundary-register --boundary e2e requires --upstream-receipt <path to an agentcrew.qa-e2e-receipt/v1>");
    if (evidence === "" || !exists(evidence)) fail("boundary-register --boundary e2e requires --evidence <path>");
    const nerr = qaE2eReceiptNamed(rd, upstream, caseId);
    if (nerr !== null) fail(`boundary-register: ${nerr}`);
    const upstreamSha = shaFileA(upstream);
    say(
      `${qaBoundaryReceiptPublish(rd, caseId, "e2e", "e2e", meta(upstream, "command_sha256"), qaPathSha(evidence), upstreamSha, meta(upstream, "started_at"), meta(upstream, "completed_at"), meta(upstream, "exit_code"))}\n`,
    );
  } else fail("boundary-register --boundary must be web or e2e (shell-driven boundaries run through 'ac-qa.sh boundary-run')");
}

// The upstream E2E receipt is this run's, at its frozen refs, and names the case.
function qaE2eReceiptNamed(rd: string, receipt: string, caseId: string): string | null {
  const m = `${rd}/run.meta`;
  if (meta(receipt, "schema") !== "agentcrew.qa-e2e-receipt/v1") return "upstream receipt has the wrong schema";
  if (meta(receipt, "source_sha") !== meta(m, "target_sha")) return "upstream E2E receipt binds another source sha";
  if (meta(receipt, "e2e_sha") !== meta(m, "e2e_ref")) return "upstream E2E receipt binds another E2E ref";
  if (meta(receipt, "profile_sha256") !== meta(m, "profile_sha256")) return "upstream E2E receipt binds another profile hash";
  const command = configValue("qa.e2e.command");
  if (command === "" || meta(receipt, "command_sha256") !== sha(command)) return "upstream E2E receipt binds another command";
  if (!`,${meta(receipt, "cases")},`.includes(`,${caseId},`)) return `upstream E2E receipt does not name case ${caseId}`;
  return null;
}

// The serve job as the original launched it: a SUBSHELL in the repo turning
// job control on, so the job leads its own process group (pgid == pid) in the
// caller's session, both fds appended to serve.log. The subshell is load-
// bearing: job control set at a shell's top level would hand the job the
// caller's stdin, where the subshell's job reads /dev/null.
const SERVE_SH = '( cd "$1" || exit 1\nset -m\nlog=$2; pidf=$3; shift 3\n/usr/bin/env -i "$@" >>"$log" 2>&1 &\nprintf \'%s\' "$!" >"$pidf" )';

function cmdServe(): void {
  requireRun();
  const rd = runDir();
  const c = configValue("qa.serve");
  if (c === "") {
    tell("(no qa.serve configured)\n");
    fatal(4);
  }
  const pidFile = `${rd}/serve.pid`;
  if (isFile(pidFile) && killZero(cap(readText(pidFile) ?? ""))) fail(`serve already running (pid ${cap(readText(pidFile) ?? "")})`);
  if (isFile(`${rd}/runtime/receipt.env`))
    fail(
      "serve refused: this round already published a runtime boot receipt, and there is no re-issue path inside one round - every boundary receipt is bound to it. Finish this round honestly (failed|unverifiable|cancelled) and re-prove against the new runtime in a fresh round.",
    );
  ee(mkdirp(`${rd}/runtime`));
  if (isFile(`${rd}/ports.env`)) ee(runTo(["/usr/bin/env", "LC_ALL=C", "sort", `${rd}/ports.env`], `${rd}/runtime/descriptor.env`));
  else ee(put(`${rd}/runtime/descriptor.env`, ""));
  ee(run(["/bin/bash", "--posix", "-c", SERVE_SH, "ac-qa.sh", repo, `${rd}/logs/serve.log`, pidFile, ...minimalEnv(rd), "sh", "-c", c], { stdout: "inherit" }).status);
  const pid = cap(readText(pidFile) ?? "");
  ee(put(`${rd}/runtime/launch.env`, `serve_started_at=${iso()}\nprocess_group=${pid}\nserve_command_sha256=${sha(c)}\n`));
  ee(append(`${rd}/logs/run.log`, `${iso()} serve pid=${pid}\n`));
  stepOwner = "serve";
  muted(() => cmdStep(["serve", "completed", "--note", `provisional launch pid=${pid} (readiness is proven by the runtime receipt, not this status)`]));
  stepOwner = "";
  say(`serving (pid ${pid}, log ${rd}/logs/serve.log)\n`);
}

// THE writer of the boot receipt, after a zero-exit probe against a live group.
function qaPublishRuntimeReceipt(rd: string): void {
  const launch = `${rd}/runtime/launch.env`;
  if (!isFile(launch)) {
    tell('notice: no recorded serve launch - probing only, no runtime receipt published (a passing run needs "ac-qa.sh serve" first)\n');
    return;
  }
  const pgid = meta(launch, "process_group");
  if (!qaPgidAlive(pgid)) fail(`health: the recorded serve process group (${pgid}) is gone - the deliverable is not booted, so no runtime receipt can be published`);
  if (isFile(`${rd}/runtime/receipt.env`)) {
    const bound = meta(`${rd}/runtime/receipt.env`, "process_group");
    if (bound !== pgid)
      fail(`health: this round's runtime receipt binds process group ${bound}, not ${pgid} - a restarted runtime invalidates the round; finish it honestly and re-prove in a fresh one`);
    return;
  }
  const id = qaRuntimeIdentity(rd);
  if (id.serve !== meta(launch, "serve_command_sha256")) fail("health: the frozen qa.serve command changed since the launch this receipt would describe");
  const t = mktemp([`${rd}/runtime/.receipt.XXXXXX`]);
  ee(t.status);
  ee(
    put(
      t.path,
      `schema=agentcrew.qa-runtime-receipt/v1\nsource_sha=${id.source}\nprofile_sha256=${id.profile}\nserve_command_sha256=${id.serve}\nhealth_command_sha256=${id.health}\n` +
        `runtime_descriptor_sha256=${id.desc}\nserve_started_at=${meta(launch, "serve_started_at")}\nhealth_completed_at=${iso()}\nprocess_group=${pgid}\n`,
    ),
  );
  if (mv(t.path, `${rd}/runtime/receipt.env`) !== 0) {
    rm(t.path);
    fail("health could not publish the runtime boot receipt");
  }
  const verr = qaRuntimeReceiptValidate(`${rd}/runtime/receipt.env`, id.source, id.profile, id.serve, id.health, id.desc);
  if (verr !== null) fail(`health published an invalid runtime receipt: ${verr}`);
  say(`runtime receipt published (process group ${pgid})\n`);
}

// `x="$(date +%s)"`.
const epochA = (): string => {
  const r = run(["date", "+%s"]);
  ee(r.status);
  return cap(r.out);
};
// `$(( <text> ))` of one operand; any arithmetic error ends the run, status 1
// (W7: the shell's own line is not written).
function arith(text: string): bigint {
  try {
    return arithValue(text);
  } catch {
    return fatal(1);
  }
}

function cmdHealth(): void {
  requireRun();
  const rd = runDir();
  const c = configValue("qa.health");
  if (c === "") {
    tell("(no qa.health configured)\n");
    fatal(4);
  }
  const timeout = configValue("qa.health_timeout") || "60";
  const pid = cap(readText(`${rd}/serve.pid`) ?? "");
  const env = minimalEnv(rd);
  const start = epochA();
  const deadline = BigInt.asIntN(64, arith(start) + arith(timeout));
  const perl = commandV("perl");
  let last = "";
  for (;;) {
    const now = testInt(cap(run(["date", "+%s"]).out));
    if (now === null || !(now < deadline)) break;
    if (pid !== "" && !killZero(pid)) fail(`serve process died during health wait (see ${rd}/logs/serve.log)`);
    const p = probeFailure(c, perl, env);
    if (p.status === 0) {
      say(`healthy after ${BigInt.asIntN(64, arith(cap(run(["date", "+%s"]).out)) - arith(start))}s\n`);
      qaPublishRuntimeReceipt(rd);
      return;
    }
    last = ` (last probe: exit ${p.status}${p.why === "" ? "" : `: ${p.why}`})`;
    ee(run(["sleep", "2"], { stdout: "inherit" }).status);
  }
  fail(`health probe never passed within ${timeout}s${last}`);
}

function cmdSeed(): number {
  requireRun();
  const rd = runDir();
  const c = configValue("qa.seed");
  if (c === "") {
    tell("(no qa.seed configured)\n");
    fatal(4);
  }
  return runMinimal(rd, "seed", c);
}

// --- cmd e2e, fixtures ------------------------------------------------------------

function cmdCmd(a: string[]): number {
  requireRun();
  const usage = "usage: ac-qa.sh cmd e2e --cases <case-id>[,<case-id>...]";
  const [name = "", ...rest] = a;
  if (name !== "e2e") fail(usage);
  const { v } = valueFlags(rest, ["--cases"], usage);
  const selected = v["--cases"]!;
  if (selected === "") fail("cmd e2e requires --cases <case-id>[,<case-id>...]");
  if (/[^A-Za-z0-9_.,-]/.test(selected)) fail(`cmd e2e --cases accepts comma-separated case ids only: ${selected}`);
  const rd = runDir();
  const ready = qaTestplanReady(rd);
  if (ready !== null) fail(`cmd e2e refused: ${ready}`);
  let normalized = "";
  for (const cid of selected.split(",").filter((x) => x !== "")) {
    if (awk(["-F\\t", "-v", `id=${cid}`, "$1 == id { found=1 } END { exit !found }", `${rd}/cases.tsv`]).status !== 0)
      fail(`cmd e2e refused: selected case '${cid}' is not in the current behavioral ledger`);
    if (!`,${normalized},`.includes(`,${cid},`)) normalized += `${normalized ? "," : ""}${cid}`;
  }
  if (normalized === "") fail("cmd e2e requires at least one existing case id");
  const c = configValue("qa.e2e.command");
  if (c === "")
    fail("cmd e2e needs a frozen chief-approved qa.e2e.command; record affected cases unverifiable and an ask-user finding with action=ask-user when the profile is missing it");
  const desc = `${rd}/profile/runtime.json`;
  muted(() => cmdStep(["e2e", "running", "--note", `approved command selected for cases ${normalized}`]));
  const started = iso();
  const rc =
    isFile(desc) && cap(jq(["-r", '.e2e_worktree // ""', desc], { stderr: "ignore" }).out) !== ""
      ? runE2eSeparate(rd, `${rd}/profile/profile.json`, desc, c)
      : runMinimal(rd, "e2e", c, true);
  const ended = iso();
  const dir = `${rd}/e2e/receipts`;
  ee(mkdirp(dir));
  const name2 = `${stampA()}-${process.pid}.env`;
  const t = mktemp([`${dir}/.receipt.XXXXXX`]);
  ee(t.status);
  const m = `${rd}/run.meta`;
  ee(
    put(
      t.path,
      `schema=agentcrew.qa-e2e-receipt/v1\nsource_sha=${meta(m, "target_sha")}\ne2e_repo=${meta(m, "e2e_repo")}\ne2e_sha=${meta(m, "e2e_ref")}\nprofile_sha256=${meta(m, "profile_sha256")}\n` +
        `command_sha256=${sha(c)}\ncases=${normalized}\nstarted_at=${started}\ncompleted_at=${ended}\nexit_code=${rc}\n`,
    ),
  );
  if (meta(t.path, "schema") !== "agentcrew.qa-e2e-receipt/v1" || meta(t.path, "command_sha256") === "" || meta(t.path, "cases") === "") {
    rm(t.path);
    fail("cmd e2e could not validate its staged execution receipt");
  }
  ee(mv(t.path, `${dir}/${name2}`));
  const p = mktemp([`${rd}/e2e/.receipt-current.XXXXXX`]);
  ee(p.status);
  ee(put(p.path, `${name2}\n`));
  ee(mv(p.path, `${rd}/e2e/receipt.current`));
  if (rc === 0) muted(() => cmdStep(["e2e", "completed", "--note", `receipt=${name2} cases=${normalized}`]));
  else muted(() => cmdStep(["e2e", "failed", "--note", `receipt=${name2} exit=${rc} cases=${normalized}`]));
  return rc;
}

// The E2E command from the separate E2E worktree's product workdir, under the
// minimal env plus the explicit endpoint mapping; an undeclared .env refuses.
// The original ran it as an `if` condition, so only its refusals end the run.
function runE2eSeparate(rd: string, profile: string, runtime: string, c: string): number {
  const wt = cap(jq(["-r", '.e2e_worktree // ""', runtime]).out);
  const workdir = cap(jq(["-r", '.e2e.workdir // "."', profile]).out) || ".";
  if (!isDir(wt)) fail(`e2e: the leased E2E worktree is gone: ${wt}`);
  const cwd = `${wt}/${workdir}`;
  if (!isDir(cwd)) fail(`e2e: the configured product workdir does not exist in the E2E worktree: ${cwd}`);
  if (exists(`${cwd}/.env`))
    fail(
      `e2e: an undeclared .env is present in the E2E workdir (${cwd}/.env) - it is not an approved credential source and would silently change the run. Remove it, or declare its values through the profile's fixture mechanism.`,
    );
  const env = minimalEnv(rd);
  for (const l of lines(jq(["-r", '.e2e.endpoint_env // {} | to_entries[] | "\\(.key)\\t\\(.value)"', profile]).out)) {
    const [k = "", v = ""] = tabRead(l, 2);
    if (k === "") continue;
    env.push(`${k}=${cap(run(["/usr/bin/env", "-i", ...env, "sh", "-c", `printf '%s' "${v}"`]).out)}`);
  }
  const rc = teeRun(["/usr/bin/env", "-i", ...env, "sh", "-c", c], cwd, `${rd}/logs/e2e.log`);
  append(`${rd}/logs/run.log`, `${iso()} cmd=e2e-separate exit=${rc} cwd=${cwd}\n`);
  return rc;
}

const FIXTURE_RECEIPT_JQ = `{schema:"agentcrew.qa-fixture-receipt/v1",pack:$pack,selector:$selector,
      cases:$cases,source_sha:$source_sha,profile_sha256:$profile_sha,
      store_manifest_sha256:$store_manifest_sha,mutation:$mutation,retry:$retry,
      started_at:$started,completed_at:$completed,exit_code:$exit_code}`;

function cmdFixture(a: string[]): void {
  requireRun();
  const usage = "usage: ac-qa.sh fixture <pack-id> --selector <name> --case <id> [--case <id> ...]";
  if (a.length < 1) fail(usage);
  const [packId = "", ...rest] = a;
  let selector = "";
  const caseIds: string[] = [];
  for (let i = 0; i < rest.length; i += 2) {
    const f = rest[i]!;
    if (f !== "--selector" && f !== "--case") fail(usage);
    if (i + 2 > rest.length) fail(`${f} needs a value`);
    if (f === "--selector") selector = rest[i + 1]!;
    else caseIds.push(rest[i + 1]!);
  }
  if (packId === "" || /[^A-Za-z0-9_.-]/.test(packId)) fail(`fixture pack id must be [A-Za-z0-9_.-]: '${packId}'`);
  if (selector === "" || /[^A-Za-z0-9_.-]/.test(selector)) fail(`fixture selector must be [A-Za-z0-9_.-]: '${selector}'`);
  if (caseIds.length === 0) fail("fixture requires at least one --case <id>");
  const rd = runDir();
  const ready = qaTestplanReady(rd);
  if (ready !== null) fail(`fixture refused: ${ready}`);
  if (!isFile(`${rd}/profile/profile.json`)) fail("fixture packs are available only to a sanctioned run with a frozen profile");
  const berr = qaBundleValidate(`${rd}/profile/profile.json`, meta(`${rd}/run.meta`, "target_sha"));
  if (berr !== null) fail(`fixture refused a tampered runtime bundle: ${berr}`);
  const pack = `${rd}/profile/store/fixtures/${packId}`;
  const manifest = `${pack}/manifest.json`;
  if (!isDir(pack) || isLink(pack) || !isFile(manifest) || isLink(manifest)) fail(`fixture pack is missing or symlinked: ${packId}`);
  if (!qaFixtureManifestValidate(pack)) fail(`fixture pack '${packId}' has an invalid, unsafe, or non-retry-safe manifest`);
  if (cap(jq(["-r", ".id", manifest]).out) !== packId) fail(`fixture pack directory '${packId}' disagrees with manifest id`);
  if (jq(["-e", "--arg", "selector", selector, ".selectors | index($selector) != null", manifest], { stdout: "ignore" }).status !== 0)
    fail(`fixture pack ${packId} has no selector '${selector}'`);
  const runner = jqA(".runner", manifest);
  const mutation = jqA(".mutation", manifest);
  const retry = jqA(".retry", manifest);
  if (mutation === "read-write" && retry !== "idempotent") fail(`fixture pack ${packId} selector ${selector} is read-write but does not declare retry=idempotent`);
  for (const rel of lines(`${runner}\n${jq(["-r", ".assets[]?", manifest]).out}`)) {
    if (unsafeRel(rel) || rel.includes("\t")) fail(`fixture pack ${packId} contains an unsafe runner/asset path: ${rel}`);
    if (!isFile(`${pack}/${rel}`) || isLink(`${pack}/${rel}`)) fail(`fixture pack ${packId} references a missing or symlinked file: ${rel}`);
  }
  let casesJson = "[]";
  for (const id of caseIds) {
    if (id === "" || id === "." || id.includes("..") || /[^A-Za-z0-9_.-]/.test(id)) fail(`fixture case id must be [A-Za-z0-9_.-] and never '.' or contain '..': '${id}'`);
    if (awk(["-F\\t", "-v", `id=${id}`, "$1 == id { found=1 } END { exit !found }", `${rd}/cases.tsv`]).status !== 0)
      fail(`fixture selector ${selector} maps to case '${id}', which is not in the current behavioral ledger`);
    if (jq(["-e", "--arg", "id", id, "index($id) != null"], { stdin: B(`${casesJson}\n`), stdout: "ignore" }).status === 0) fail(`fixture case id repeated: ${id}`);
    const r = jq(["-c", "--arg", "id", id, ". + [$id]"], { stdin: B(`${casesJson}\n`) });
    ee(r.status);
    casesJson = cap(r.out);
  }
  let command: string[];
  if (runner.endsWith(".sh")) command = ["sh", `./${runner}`];
  else {
    if (!executable(`${pack}/${runner}`)) fail(`fixture runner is not executable: ${pack}/${runner}`);
    command = [`./${runner}`];
  }
  command.push("--selector", selector);
  for (const id of caseIds) command.push("--case", id);
  const env = minimalEnv(rd);
  const started = iso();
  const rc = run(["/usr/bin/env", "-i", ...env, `AC_QA_RUN_ID=${basename(rd)}`, `AC_QA_FIXTURE_PACK=${packId}`, `AC_QA_EVIDENCE=${cmdEvidenceDir()}`, ...command], {
    cwd: pack,
    stdout: "inherit",
  }).status;
  const ended = iso();
  const dir = `${rd}/fixtures/receipts`;
  ee(mkdirp(dir));
  const name = `${stampA()}-${process.pid}-${packId}-${selector}.json`;
  const t = mktemp([`${dir}/.receipt.XXXXXX`]);
  ee(t.status);
  ee(
    runTo(
      [
        "jq",
        "-n",
        "--arg",
        "pack",
        packId,
        "--arg",
        "selector",
        selector,
        "--arg",
        "started",
        started,
        "--arg",
        "completed",
        ended,
        "--arg",
        "source_sha",
        meta(`${rd}/run.meta`, "target_sha"),
        "--arg",
        "profile_sha",
        meta(`${rd}/run.meta`, "profile_sha256"),
        "--arg",
        "store_manifest_sha",
        cap(jq(["-r", ".snapshots.store_manifest_sha256", `${rd}/profile/profile.json`]).out),
        "--arg",
        "mutation",
        mutation,
        "--arg",
        "retry",
        retry,
        "--argjson",
        "cases",
        casesJson,
        "--argjson",
        "exit_code",
        `${rc}`,
        FIXTURE_RECEIPT_JQ,
      ],
      t.path,
    ),
  );
  ee(mv(t.path, `${dir}/${name}`));
  if (rc !== 0) fail(`fixture selector ${packId}/${selector} failed with status ${rc} (receipt: ${dir}/${name})`);
  say(`fixture selector completed: ${packId}/${selector} cases=${caseIds.join(",")} receipt=${dir}/${name}\n`);
}

// --- config -------------------------------------------------------------------------

// The key-level table: qa.serve/qa.health at the app, qa.seed at the scope,
// everything else at the repo; a flat run reads the key verbatim.
function qaKeyPath(scope: string, app: string, key: string): string {
  if (scope === "") return key;
  if (key === "qa.serve" || key === "qa.health") return `qa.scopes.${scope}.apps.${app}.${key.slice(3)}`;
  if (key === "qa.seed") return `qa.scopes.${scope}.seed`;
  return key;
}

// cmd_config: the frozen value; status 1 (silent) for an empty config or value.
function cmdConfig(a: string[]): number {
  requireRun();
  const rd = runDir();
  if (!nonEmpty(`${rd}/config.yaml`)) return 1;
  const key = a[0] ?? "";
  if (key === "") fatal(1);
  const r = yamlGet(`${rd}/config.yaml`, qaKeyPath(sedFirst(`${rd}/run.meta`, "scope"), sedFirst(`${rd}/run.meta`, "app"), key));
  ee(r.status);
  const v = cap(r.out);
  if (v === "") return 1;
  say(`${v}\n`);
  return 0;
}

// `$(cmd_config <key> 2>/dev/null || true)`: the value, or "" for every
// refusal (no run included) and every failure.
function configValue(key: string): string {
  const t = readLink(current);
  if (!isLink(current) || t === null) return "";
  const rd = `${qdir}/${t}`;
  if (!nonEmpty(`${rd}/config.yaml`)) return "";
  return cap(yamlGet(`${rd}/config.yaml`, qaKeyPath(sedFirst(`${rd}/run.meta`, "scope", "ignore"), sedFirst(`${rd}/run.meta`, "app", "ignore"), key), true).out);
}

// --- config proposals, the store and evidence dirs, the reports --------------------

const badProposalId = (id: string): boolean => id === "" || /[^A-Za-z0-9._-]/.test(id);

function cmdConfigProposal(a: string[]): void {
  const { v } = valueFlags(a, ["--id"], "usage: ac-qa.sh config-proposal [--id <proposal-id>]");
  const id = v["--id"] || `${stampA()}-${process.pid}`;
  if (badProposalId(id)) fail(`invalid proposal id: ${id}`);
  const n = projectConfigName(u8(repo));
  if (n === null) fail(`config-proposal: cannot resolve the project name for ${repo}`);
  const name = b8(n!);
  const home = softHome(true);
  if (home === "") fatal(1);
  const homePath = `${b8(home)}/projects/${name}.yaml`;
  const out = `${repo}/.crew/config-proposals/${id}`;
  ee(mkdirp(`${repo}/.crew/config-proposals`));
  if (run(["mkdir", out], { stderr: "ignore" }).status !== 0) fail(`config-proposal: id already exists: ${id}`);
  const prop = `${out}/proposed.yaml`;
  const patch = `${out}/proposal.patch`;
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(`${prop}.tmp`));
  } catch {
    return fatal(1);
  }
  try {
    writeAll(t.fd, readStdin());
  } finally {
    closeSync(t.fd);
  }
  const staged = b8(t.path);
  if (!nonEmpty(staged)) {
    rm(staged);
    run(["rmdir", out], { stderr: "ignore" });
    fail("config-proposal: empty draft on stdin - compose the full proposed config first");
  }
  ee(mv(staged, prop));
  const cur = `${out}/base.yaml`;
  const installed = projectConfigFile(u8(repo), true);
  if (installed === null) ee(put(cur, ""));
  else ee(run(["cp", installed, cur], { stdout: "inherit" }).status);
  const baseSha = shaFileA(cur);
  ee(put(`${out}/base.sha256`, `${baseSha}\n`));
  ee(put(`${out}/project`, `${name}\n`));
  if (runTo(["diff", "-u", "--label", "current", "--label", "proposed", cur, prop], patch) === 0) {
    for (const f of [cur, patch, prop, `${out}/base.sha256`, `${out}/project`]) rm(f);
    run(["rmdir", out], { stderr: "ignore" });
    fail("config-proposal: draft is identical to the resolved config - nothing to propose");
  }
  say(
    `proposal_id: ${id}\nproposal written:\n  ${patch}\n  ${prop}\ntarget: ${homePath}\nbase_sha256: ${baseSha}\ninstall (CHIEF, after review - never the drafting agent): bin/ac-qa.sh config-install ${id}\n`,
  );
}

function cmdConfigInstall(a: string[]): void {
  const id = a[0] ?? "";
  if (a.length !== 1) fail("usage: ac-qa.sh config-install <proposal-id>");
  if (badProposalId(id)) fail(`invalid proposal id: ${id}`);
  const n = projectConfigName(u8(repo));
  if (n === null) fail(`config-install: cannot resolve the project name for ${repo}`);
  const name = b8(n!);
  const homePath = `${b8(projectsDir())}/${name}.yaml`;
  const out = `${repo}/.crew/config-proposals/${id}`;
  const prop = `${out}/proposed.yaml`;
  if (!isFile(prop)) fail(`config-install: no staged proposal ${id} at ${out}`);
  if (cap(readText(`${out}/project`) ?? "") !== name) fail(`config-install: proposal ${id} does not target project ${name}`);
  const baseSha = cap(readText(`${out}/base.sha256`) ?? "");
  if (baseSha === "") fail(`config-install: proposal ${id} has no base hash`);
  ee(mkdirp(dirname(homePath)));
  const lock = `${homePath}.lock`;
  if (!lockAcquire(u8(lock), 30, sleepOne)) fail(`config-install: lock timeout for ${name}`);
  const c = mktemp([`${homePath}.current.XXXXXX`]);
  ee(c.status);
  if (isFile(homePath)) ee(run(["cp", homePath, c.path], { stdout: "inherit" }).status);
  else ee(put(c.path, ""));
  const currentSha = shaFileA(c.path);
  if (currentSha !== baseSha) {
    rm(c.path);
    lockRelease(u8(lock));
    fail(`config-install: proposal ${id} conflicts with a newer installed config (base=${baseSha} current=${currentSha}); rebase the proposal`);
  }
  let prev = "";
  if (isFile(homePath) && run(["diff", "-q", homePath, prop], { stdout: "ignore", stderr: "ignore" }).status !== 0) {
    prev = `${homePath}.prev`;
    ee(run(["cp", homePath, prev], { stdout: "inherit" }).status);
  }
  const t = mktemp([`${homePath}.install.XXXXXX`]);
  ee(t.status);
  ee(run(["cp", prop, t.path], { stdout: "inherit" }).status);
  ee(mv(t.path, homePath));
  const installedSha = shaFileA(homePath);
  rm(c.path);
  lockRelease(u8(lock));
  ee(put(`${out}/installed.sha256`, `${installedSha}\n`));
  say(`installed proposal ${id}: ${prop} -> ${homePath}${prev ? ` (previous kept at ${prev})` : ""}\n`);
  say(
    `receipt (post to the family room): CONFIG-INSTALLED: ${homePath} sha256=${installedSha} proposal=${id} - drafted by the task agent, reviewed + installed by the chief; captain veto: restore ${prev || "(no previous config)"}\n`,
  );
}

const STORE_UNRESOLVABLE = `qa knowledge store unresolvable: no run recorded a store= path and this env has no AC_HOME.
The store is per-project and durable in the FLEET HOME (see KNOWLEDGE STORE in this script's header). Resolving it from here would answer with the agent-crew checkout that owns bin/, collapsing every fleet's store into one and silently reading an empty store - so it refuses instead. Your qa brief names the absolute path; re-start this run with it:
  ac-qa.sh start --target <ref> --task <id> --store <abs-store-dir>
Brief names no store? A sanctioned profiled round still carries an explicit empty versioned store manifest. Only an unprofiled diagnostic run may proceed without reusable store content; derive each case locally, record curation as skipped, and say so in the testplan and report. Never point --store at a pool worktree; it is disposable.`;

function cmdStoreDir(): void {
  let store = "";
  if (isLink(current)) {
    const m = `${runDir()}/run.meta`;
    if (isFile(m)) store = sedFirst(m, "store");
  }
  let dir: string;
  if (store !== "") dir = store;
  else if (process.env.AC_HOME) dir = homeStore();
  else return fail(STORE_UNRESOLVABLE);
  if (!dir.endsWith("/profile/store")) ee(mkdirp(`${dir}/cases`));
  say(`${dir}\n`);
}

// The evidence dir: run.meta's evidence=, else <task dir>/evidence when the
// run names a task and AC_HOME is set, else <run>/evidence - minted. Its
// `$(...)` callers (soft) ran it with errexit asleep: a task dir that refuses
// leaves `/evidence`, and a failed mkdir still answers the dir.
function evidenceDir(soft: boolean): string {
  if (!isLink(current)) return soft ? "" : fail("no active qa run; ac-qa.sh start first");
  const t = readLink(current);
  if (t === null) return soft ? "" : fail("broken current symlink");
  const rd = `${qdir}/${t}`;
  let dir = sedFirst(`${rd}/run.meta`, "evidence");
  if (dir === "") {
    const task = sedFirst(`${rd}/run.meta`, "task");
    if (task !== "" && process.env.AC_HOME) {
      try {
        dir = `${b8(taskDir(u8(task)))}/evidence`;
      } catch (e) {
        tell(`ERROR: ${b8((e as Error).message)}\n`);
        if (!soft) fatal(1);
        dir = "/evidence";
      }
    } else dir = `${rd}/evidence`;
  }
  const made = mkdirp(dir);
  if (!soft) ee(made);
  return dir;
}
const cmdEvidenceDir = (): string => evidenceDir(true);

const FIX_FINDINGS_JQ = `.[] | select(.action == "fix")
           | "- [\\(.severity)] \\(.file // "-")\\(if .line then ":" + (.line|tostring) else "" end): \\(.description)"`;

function cmdFixReport(): void {
  requireRun();
  const rd = runDir();
  say(`# QA fix contract (run ${readLink(current) ?? ""})\n\n`);
  say(`Target: ${cap(run(["sed", "-n", "s/^target=//p", `${rd}/run.meta`]).out)}\n\n## Failed cases\n\n`);
  say("| id | tier | classification | evidence |\n|---|---|---|---|\n");
  const t = awk(["-F\\t", '$3 == "fail" { printf "| %s | %s | %s | %s |\\n", $1, $2, $4, $7 }', `${rd}/cases.tsv`]);
  say(t.out);
  ee(t.status);
  say("\n## Findings (action=fix)\n\n");
  for (const f of globJson(`${rd}/findings`)) {
    if (!isFile(f)) continue;
    const r = jq(["-r", FIX_FINDINGS_JQ, f]);
    say(r.out);
    ee(r.status);
  }
  say("\nRules: fix the product defects above; NEVER weaken a test to green; the qa run re-verifies after your fix.\n");
}

const RELAY_CASES_AWK =
  '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\\n", $1, $2, $3, $4, $6, $7, ($8 == "" ? "-" : $8), ($9 == "" ? "-" : $9), ($10 == "" ? "-" : $10) }';
const RELAY_VISUALS_AWK = '{ printf "- %s (%s%s)%s\\n", $1, $2, ($4 == "-" ? "" : ", case " $4), ($6 == "-" ? "" : " - " $6) }';

function cmdRelayReport(a: string[]): void {
  for (let i = 0; i < a.length; i += 2) {
    if (a[i] !== "--repo") fail(`unknown flag: ${a[i]}`);
    const d = flagValue(a, i);
    const top = run(["/bin/sh", "-c", 'cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null', "sh", d]);
    if (top.status !== 0) fail(`not a git repo: ${d}`);
    repo = cap(top.out);
    qdir = `${repo}/.crew/qa`;
    current = `${qdir}/current`;
  }
  requireRun();
  const rd = runDir();
  const id = readLink(current) ?? "";
  const outcome = sedFirst(`${rd}/run.meta`, "outcome");
  if (outcome === "running") fail("nothing to relay yet: ac-qa.sh finish first");
  const target = sedFirst(`${rd}/run.meta`, "target");
  const ff = jq(["-r", '.full_flow | join(",")', `${rd}/testplan-manifest.json`], { stderr: "ignore" });
  const fullFlow = cap(ff.out + (ff.status === 0 ? "" : "-"));
  say(`# QA relay contract (run ${id})\n\n`);
  say(`Verdict: **${outcome}** | Target: ${target} | Full flow: \`${fullFlow}\`\n\n`);
  say("qa wrote to disk ONLY - it never posts or merges. YOU carry it outward,\n");
  say("and you carry the EVIDENCE, not just the verdict.\n\n");
  say("## 1. Post to the PR (`gh pr comment <PR>`)\n\n");
  say("- the envelope below, verbatim;\n");
  say("- the case table below;\n");
  say(`- the authoritative on-disk report: ${cmdEvidenceDir()}/../report.md\n`);
  say("- every visual artifact below, EMBEDDED in the comment, not just linked\n");
  say("  (private repos: the crew-qa skill has the hosting recipe).\n");
  say("- REQUIRED first: `ac-qa.sh fetch-check <url>...` on every embedded URL\n");
  say("  above - post only once it exits 0. A URL that never serves is a 404\n");
  say("  the captain would otherwise discover themselves.\n");
  say('- Never paraphrase away a finding. "Ready for merge" only on a FINAL passed.\n\n');
  say("## 2. CORRECT every claim this run supersedes\n\n");
  say("Re-read the PR body NOW and rewrite anything this run has made false.\n");
  say('Grep it for: "not run", "verified statically", "statically only",\n');
  say('"tests pending", "not verified", "unverified", "verification pending".\n');
  say("A stale validation claim left standing is a lie the crew told the captain.\n\n");
  say("## 3. Post to the room (captain + chief, one post serves both)\n\n");
  say(`\`bin/ac-room.sh post <family> <you> "QA verdict=${outcome}, N/N cases, evidence <path>"\`\n`);
  say("Post interim status each failing round, not just at the end.\n\n");
  say("## Envelope\n\n```\n");
  say(qaEnvelope(rd));
  say("```\n\n");
  say("## Cases\n\n| id | tier | status | classification | grade | evidence | note | authority | repro |\n");
  say("|---|---|---|---|---|---|---|---|---|\n");
  const cases = awk(["-F\\t", RELAY_CASES_AWK, `${rd}/cases.tsv`]);
  say(cases.out);
  ee(cases.status);
  say("\n## Visual artifacts (embed these)\n\n");
  const live = cap(visualsLive(rd).join(""));
  if (live !== "") {
    const r = awk(["-F\\t", RELAY_VISUALS_AWK], { stdin: B(`${live}\n`) });
    say(r.out);
    ee(r.status);
  } else say("(none on record)\n");
  say("\nThe merge gate stays with the captain: this verdict informs it, never bypasses it.\n");
}

function cmdFetchCheck(urls: string[]): void {
  if (urls.length < 1) fail("usage: ac-qa.sh fetch-check <url>...");
  if (!commandV("curl")) fail("fetch-check: curl not found on PATH - cannot verify URLs");
  let token = b8(process.env.GH_TOKEN || process.env.GITHUB_TOKEN || "");
  if (token === "" && commandV("gh")) token = cap(run(["gh", "auth", "token"], { stderr: "ignore" }).out);
  const auth = token === "" ? [] : ["-H", `Authorization: token ${token}`];
  for (const url of urls) {
    const r = run(["curl", "-s", "-L", "--max-time", "15", "-o", "/dev/null", "-w", "%{http_code}", ...auth, url], { stderr: "ignore" });
    const code = r.status === 0 ? cap(r.out) : "";
    if (code !== "200") fail(`fetch-check: ${url} returned ${code || "no response"} (non-200 can also mean not authenticated for a private repo)`);
  }
  say(`fetch-check: ${urls.length} url(s) OK\n`);
}

// --- agent: PROFILE RESOLVE, then the verifier facade ------------------------------

// `x="$(ac_yaml_get <cfg> <key>)"`: awk's failure ends the run with its status.
function yamlA(cfg: string, key: string): string {
  const r = yamlGet(cfg, key);
  ee(r.status);
  return cap(r.out);
}
// qa_source_sha256: a durable source's hash, the empty input's when absent.
const qaSourceSha256 = (f: string): string => (f !== "" && isFile(f) ? shaFileA(f) : sha(""));
// `$([ -f <src> ] && ac_meta_get <src> <key> || printf '-')`.
function receiptField(src: string, key: string): string {
  if (src === "" || !isFile(src)) return "-";
  try {
    return metaGet(B(src) as unknown as string, key);
  } catch {
    return "-";
  }
}

const PROFILE_JQ = `
    {
      schema: "agentcrew.qa-profile/v1",
      profile_key: $key,
      project: $project,
      source: { repo: $source_repo, ref: $source_ref },
      service: ({ serve: $serve, health: $health, health_timeout_seconds: $health_timeout }
                + (if $seed == "" then {} else { seed: $seed } end)),
      provenance: {
        project_config_path: $cfg_path,
        project_config_sha256: $cfg_sha,
        repo_knowledge_path: $know_path,
        repo_knowledge_sha256: $know_sha,
        resolved_at: $resolved_at
      },
      snapshots: {
        config_file: "config.yaml",
        config_sha256: $config_snapshot_sha,
        scopes_file: "scopes.tsv",
        scopes_sha256: $scopes_snapshot_sha,
        store_manifest_file: "store/manifest.json",
        store_manifest_sha256: $store_manifest_sha,
        ship_test_receipt_file: "ship/test-receipt.env",
        ship_test_receipt_sha256: $ship_receipt_sha
      }
    }
    + (if $scope == "" then {} else { target: { scope: $scope, app: $app } } end)
    + (if ($fx_profile == "" and $fx_resolver == "") then {}
       else { fixtures: ((if $fx_profile == "" then {} else { profile: $fx_profile } end)
                         + (if $fx_resolver == "" then {} else { resolver: $fx_resolver } end)) } end)
    + (if $routing == null then {} else { routing: $routing } end)
    + (if $e2e_repo == "" then {} else { e2e: (
         { repo: $e2e_repo, repo_path: $e2e_repo_path, ref: $e2e_ref,
           ref_policy: $e2e_ref_policy, workdir: $e2e_workdir, command: $e2e_command,
           endpoint_env: $e2e_endpoint }
         + (if $e2e_fixture == "" then {} else { fixture_profile: $e2e_fixture } end)) } end)
    `;
const CANONICAL_JQ = `
      del(.profile_sha256,
          .provenance.resolved_at,
          .provenance.project_config_path,
          .provenance.repo_knowledge_path,
          .e2e.repo_path)
    `;
const RESULT_JQ = `
    type == "object"
    and (.verdict as $v | ["passed","failed","unverifiable"] | index($v) != null)
    and (.summary | type) == "string"
    and (.evidence | type) == "array"
    and (.report | type) == "string" and (.report | length) > 0
    and (.verified_ref == $ref)
  `;

function cmdAgent(a: string[]): void {
  const v: Record<string, string> = { "--target": "", "--task": "", "--evidence": "", "--brief": "", "--home": "", "--qa-rule": "", "--ship-run": "" };
  let scope = "";
  let app = "";
  let scopeSeen = false;
  let appSeen = false;
  for (let i = 0; i < a.length; i += 2) {
    const f = a[i]!;
    if (Object.hasOwn(v, f)) v[f] = flagValue(a, i);
    else if (f === "--scope") {
      if (scopeSeen) fail(`--scope given twice ('${scope}' then '${flagValue(a, i)}') - name one scope`);
      scope = flagValue(a, i);
      scopeSeen = true;
    } else if (f === "--app") {
      if (appSeen) fail(`--app given twice ('${app}' then '${flagValue(a, i)}') - name one app`);
      app = flagValue(a, i);
      appSeen = true;
    } else fail(`unknown flag: ${f}`);
  }
  const target = v["--target"]!;
  const task = v["--task"]!;
  let evidence = v["--evidence"]!;
  const brief = v["--brief"]!;
  const home = v["--home"]!;
  const qaRuleSelect = v["--qa-rule"]!;
  const shipRun = v["--ship-run"]!;
  if (target === "" || task === "") fail("usage: ac-qa.sh agent --target <ref> --task <id> [--evidence <dir>] [--brief <path>] [--qa-rule <number|default>]");
  if (brief === "" || !isFile(brief)) fail("qa agent requires the durable QA charter via --brief <path>");
  const ts = run(["git", "-C", repo, "rev-parse", "--verify", `${target}^{commit}`], { stderr: "ignore" });
  if (ts.status !== 0) fail(`target does not resolve to a commit: ${target}`);
  const targetSha = cap(ts.out);
  const caller = b8(process.env.AC_CREW_ID || "");
  if (caller === "" || /[^a-z0-9-]/.test(caller)) fail(`qa agent needs AC_CREW_ID from ac-spawn (got '${caller || "empty"}')`);
  let family = b8(process.env.AC_FLEET_SCOPE || "");
  if (family === "") family = caller.endsWith("-implement") ? caller.slice(0, -"-implement".length) : caller;
  const verify = b8(process.env.AC_VERIFY_BIN || "") || `${binDir}/ac-verify.sh`;
  if (!executable(verify)) fail(`verifier facade is not executable: ${verify}`);

  ee(mkdirp(qdir));
  const slug = sanitizeCompose(task);
  evidence = evidence || `${qdir}/agent-${slug}-evidence`;
  ee(mkdirp(evidence));
  evidence = b8(physicalDir(u8(evidence)) ?? fatal(1));
  let round = 1;
  while (exists(`${qdir}/agent-${slug}-r${round}.json`) || exists(`${qdir}/agent-${slug}-r${round}.profile`)) round++;
  const result = `${qdir}/agent-${slug}-r${round}.json`;
  const previous = `${qdir}/agent-${slug}-r${round - 1}.json`;
  const combined = `${qdir}/agent-${slug}-r${round}.brief.md`;
  const report = `${b8(physicalDir(u8(dirname(brief))) ?? fatal(1))}/report.md`;

  // --- PROFILE RESOLVE (fail-closed preflight) ---
  const qaHome = b8(homeResolve(u8(home), u8(repo)));
  const pn = projectConfigName(u8(repo));
  if (pn === null) fail(`cannot resolve the project config name for ${repo}`);
  const qaProject = b8(pn!);
  let profileKey = "";
  const ret = (status: string, detail: string): never => {
    say(`QA_PROFILE_STATUS=${status}\nprofile-status: ${status}\nprofile-key: ${profileKey || qaProject || "?"}\nprofile-detail: ${detail}\n`);
    return fatal(1);
  };
  const ask = (question: string, recommendation: string): never => {
    say(`QA_PROFILE_STATUS=ask-user\nprofile-status: ask-user\nprofile-key: ${profileKey || qaProject || "?"}\nprofile-question: ${question}\nprofile-recommendation: ${recommendation}\n`);
    return fatal(1);
  };
  if (qaHome === "")
    ret(
      "needs-profile",
      "no fleet home named (--home) and none in the environment - the project config, scope map, repo-knowledge, store snapshot and pane routing all descend from it, so no profile can compile. Pass --home <abs>: your EXECUTION brief bakes the whole runnable line, fleet home included, beside the sentence that sends you here. This verb never reads the qa charter, so the charter's own --home (baked for its 'start' line) does not reach it",
    );
  const bundle = `${qdir}/agent-${slug}-r${round}.profile`;
  const dispatchCfg = `${qaHome}/config/crew-dispatch.json`;
  const dispatchSelect = `${binDir}/ac-dispatch-select.sh`;
  const select = (args: string[], o: Parameters<typeof run>[1] = {}): Ran => run(["/usr/bin/env", `AC_HOME=${qaHome}`, dispatchSelect, ...args], o);

  let routingJson = "";
  let harness = "";
  let model = "";
  let effort = "";
  if (isFile(dispatchCfg) && jq(["-e", ".", dispatchCfg], { stdout: "ignore", stderr: "ignore" }).status !== 0) fail(`invalid JSON in QA dispatch config: ${dispatchCfg}`);
  if (isFile(dispatchCfg) && jq(["-e", '.panes.qa | type == "object" and has("rules")', dispatchCfg], { stdout: "ignore", stderr: "ignore" }).status === 0) {
    if (qaRuleSelect === "") {
      const list = run(["/bin/sh", "-c", 'exec "$@" 2>&1', "sh", "/usr/bin/env", `AC_HOME=${qaHome}`, dispatchSelect, "--pane", "qa", "--list"]);
      const rules = cap(list.out);
      if (list.status !== 0) fail(`routed panes.qa is invalid: ${rules}`);
      fail(`routed panes.qa requires --qa-rule <number|default> before pane placement. Available rules:\n${rules}`);
    }
    const prof = select(["--pane", "qa", "--rule", qaRuleSelect]);
    ee(prof.status);
    const rec = select(["--pane", "qa", "--receipt", qaRuleSelect]);
    ee(rec.status);
    routingJson = cap(rec.out);
    const [h = "", m = "", e = ""] = tabRead(firstLine(cap(prof.out)), 3);
    harness = h.replace(/^harness=/, "");
    model = m.replace(/^model=/, "");
    effort = e.replace(/^effort=/, "");
  } else {
    if (qaRuleSelect !== "") fail("--qa-rule is valid only when config/crew-dispatch.json defines routed panes.qa.rules[]");
    if (isFile(dispatchCfg) && jq(["-e", '.panes | has("qa")', dispatchCfg], { stdout: "ignore", stderr: "ignore" }).status === 0) ee(select(["--pane", "qa"], { stdout: "ignore" }).status);
  }

  const map = withHome(qaHome, () => knowledgeScopes(u8(repo)));
  if (map.status !== 0) ret("profile-conflict", "the repo-knowledge scope map is ambiguous - resolve it (bin/ac-know.sh) before a profile can compile");
  const scopesOut = cap(map.out);
  const kf = withHome(qaHome, () => knowledgeFile(u8(repo)));
  const know = kf === null ? "" : b8(kf);
  withHome(qaHome, () => {
    if (projectConfigFile(u8(repo)) === null && isFile(`${qaHome}/config/projects/${qaProject}.yaml`)) fatal(1);
  });
  const cfgFile = withHome(qaHome, () => projectConfigFile(u8(repo), true));
  if (cfgFile === null)
    ret("needs-profile", `no project config at the canonical home path ($AC_HOME/projects/${qaProject}.yaml) - the chief installs one (ac-qa.sh config-proposal / config-install)`);
  const cfg = cfgFile!;
  let healthTimeout = yamlA(cfg, "qa.health_timeout");
  if (healthTimeout === "" || /[^0-9]/.test(healthTimeout)) healthTimeout = "60";
  const fxProfile = yamlA(cfg, "qa.fixtures.profile");
  const fxResolver = yamlA(cfg, "qa.fixtures.resolver");
  const scratch = mktemp([]);
  ee(scratch.status);
  ee(put(scratch.path, `${scopesOut}\n`));
  qaSelectionPrecedence(scratch.path, cfg, scope, app, (cls, msg) => (cls === "caller-error" ? fail(msg) : ret(cls === "conflict" ? "profile-conflict" : "needs-profile", msg)));
  rm(scratch.path);

  let serve: string;
  let health: string;
  let seed: string;
  if (scope === "") {
    profileKey = qaProject;
    serve = yamlA(cfg, "qa.serve");
    health = yamlA(cfg, "qa.health");
    seed = yamlA(cfg, "qa.seed");
    if (serve === "" || health === "") ret("needs-profile", "the flat project config is missing the service contract (need qa.serve and qa.health) - the chief completes it before QA runs");
  } else {
    profileKey = `${qaProject}/${scope}/${app}`;
    serve = yamlA(cfg, `qa.scopes.${scope}.apps.${app}.serve`);
    health = yamlA(cfg, `qa.scopes.${scope}.apps.${app}.health`);
    seed = yamlA(cfg, `qa.scopes.${scope}.seed`);
    if (serve === "" || health === "" || seed === "")
      ret(
        "needs-profile",
        `scoped profile ${profileKey} is missing required mechanics (need qa.scopes.${scope}.apps.${app}.serve + .health and qa.scopes.${scope}.seed) - the chief completes the config`,
      );
  }
  if (fxResolver !== "" && fxProfile === "")
    ask(
      `Secret resolver '${fxResolver}' is declared for ${profileKey} but no authorized fixture profile is named (qa.fixtures.profile). Which fixture profile should QA use?`,
      "Name an authorized safe fixture profile in qa.fixtures.profile, or confirm this target needs no secret-resolved fixtures.",
    );

  const e2e = { repo: "", path: "", ref: "", policy: "", workdir: "", command: "", fixture: "", endpoint: "{}" };
  e2e.repo = yamlA(cfg, "qa.e2e.repo");
  if (e2e.repo !== "") {
    const p = withHome(qaHome, () => projectDir(u8(e2e.repo)));
    if (p === null)
      ret(
        "needs-profile",
        `qa.e2e.repo '${e2e.repo}' does not resolve to a local git repository (a project name under $AC_HOME/projects, or an absolute path) - clone it before QA can lease the E2E worktree`,
      );
    e2e.path = b8(p!);
    e2e.policy = yamlA(cfg, "qa.e2e.ref_policy") || "configured-default-branch-head";
    if (e2e.policy === "configured-default-branch-head") {
      const r = run(["git", "-C", e2e.path, "rev-parse", "--verify", `${b8(defaultBranch(u8(e2e.path)))}^{commit}`], { stderr: "ignore" });
      if (r.status !== 0) ret("needs-profile", `cannot resolve the E2E default-branch head in ${e2e.path} - the E2E clone has no resolvable default branch`);
      e2e.ref = cap(r.out);
    } else ret("profile-conflict", `unsupported qa.e2e.ref_policy '${e2e.policy}' for ${profileKey} (only configured-default-branch-head is supported)`);
    const prefix = scope !== "" ? `qa.scopes.${scope}.e2e` : "qa.e2e";
    e2e.workdir = yamlA(cfg, `${prefix}.workdir`) || yamlA(cfg, "qa.e2e.workdir") || ".";
    e2e.command = yamlA(cfg, `${prefix}.command`) || yamlA(cfg, "qa.e2e.command");
    if (e2e.command === "") ret("needs-profile", `qa.e2e.repo is set for ${profileKey} but no E2E command is configured (qa.e2e.command) - the chief completes it`);
    e2e.fixture = yamlA(cfg, `${prefix}.fixture_profile`) || yamlA(cfg, "qa.e2e.fixture_profile");
    let ep = `${prefix}.endpoint_env`;
    if (cap(yamlKeys(cfg, ep).out) === "") ep = "qa.e2e.endpoint_env";
    for (const ek of yamlKeys(cfg, ep).out.split(/[ \t\n]+/).filter((x) => x !== "")) {
      const r = jq(["-c", "--arg", "k", ek, "--arg", "v", cap(yamlGet(cfg, `${ep}.${ek}`).out), ". + {($k): $v}"], { stdin: B(`${e2e.endpoint}\n`) });
      ee(r.status);
      e2e.endpoint = cap(r.out);
    }
  }

  // FREEZE the complete runtime bundle under a private name.
  const cfgSha = qaSourceSha256(cfg);
  const knowSha = qaSourceSha256(know);
  const bt = mktemp(["-d", `${qdir}/.agent-${slug}-r${round}.profile.tmp.XXXXXX`]);
  if (bt.status !== 0) fail(`could not stage the qa profile bundle under ${qdir}`);
  const tmpd = bt.path;
  const drop = (msg: string): never => {
    rmrf(tmpd);
    return fail(msg);
  };
  if (mkdirp(`${tmpd}/store`) !== 0) drop("could not stage the qa profile store");
  if (run(["cp", cfg, `${tmpd}/config.yaml`], { stdout: "inherit" }).status !== 0) drop("could not freeze project config into the qa profile bundle");
  ee(put(`${tmpd}/scopes.tsv`, scopesOut !== "" ? `${scopesOut}\n` : ""));
  const configSnapshotSha = shaFileA(`${tmpd}/config.yaml`);
  const scopesSnapshotSha = shaFileA(`${tmpd}/scopes.tsv`);
  const storeSource = qaStorePath(`${qaHome}/data`);
  const storeManifest = `${tmpd}/store/manifest.json`;
  ee(runTo(["jq", "-n", '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}'], storeManifest));
  if (isDir(storeSource)) {
    if (cap(run(["find", storeSource, "-type", "l", "-print", "-quit"]).out) !== "") drop(`qa store contains a symlink and cannot be frozen safely: ${storeSource}`);
    const found = run(["find", storeSource, "-type", "f", "-print"]);
    for (const file of lines(run(["/usr/bin/env", "LC_ALL=C", "sort"], { stdin: B(found.out) }).out)) {
      if (file === "") continue;
      const rel = file.startsWith(`${storeSource}/`) ? file.slice(storeSource.length + 1) : file;
      if (rel === "manifest.json") continue;
      if (rel.startsWith("/") || rel === ".." || rel.startsWith("../") || rel.includes("/../") || rel.endsWith("/..") || rel.includes("\t") || rel.includes("\n"))
        drop(`qa store contains an unsafe relative path: ${rel}`);
      ee(mkdirp(`${tmpd}/store/${dirname(rel)}`));
      if (run(["cp", file, `${tmpd}/store/${rel}`], { stdout: "inherit" }).status !== 0) drop(`could not freeze qa store entry: ${rel}`);
      if (!qaStoreManifestMerge(storeManifest, rel, shaFileA(`${tmpd}/store/${rel}`))) drop(`could not record qa store entry: ${rel}`);
    }
  }
  const storeManifestSha = shaFileA(storeManifest);

  let shipSrc = "";
  if (shipRun !== "") {
    if (/[^A-Za-z0-9._-]/.test(shipRun)) fail(`--ship-run must be a ship run id ([A-Za-z0-9._-]): '${shipRun}'`);
    shipSrc = `${repo}/.crew/ship/${shipRun}/test/receipt.env`;
  }
  const shipSrcSha = qaSourceSha256(shipSrc);
  const shipStatus = qaShipReceiptStatus(shipSrc, targetSha);
  if (mkdirp(`${tmpd}/ship`) !== 0) drop("could not stage the frozen ship test receipt");
  const colon = shipStatus.indexOf(":");
  ee(
    put(
      `${tmpd}/ship/test-receipt.env`,
      `schema=agentcrew.ship-test-receipt/v1\nsource_sha=${targetSha}\nqualification=${colon < 0 ? shipStatus : shipStatus.slice(0, colon)}\nreason=${colon < 0 ? shipStatus : shipStatus.slice(colon + 1)}\n` +
        `ship_run=${shipRun || "-"}\ncommand_sha256=${receiptField(shipSrc, "command_sha256")}\noutput_sha256=${receiptField(shipSrc, "output_sha256")}\n` +
        `started_at=${receiptField(shipSrc, "started_at")}\ncompleted_at=${receiptField(shipSrc, "completed_at")}\nexit_code=${receiptField(shipSrc, "exit_code")}\n`,
    ),
  );
  const shipReceiptSha = shaFileA(`${tmpd}/ship/test-receipt.env`);

  let profile = `${tmpd}/profile.json`;
  const compiled = runTo(
    [
      "jq",
      "-n",
      ...["--arg", "key", profileKey, "--arg", "project", qaProject, "--arg", "source_repo", qaProject, "--arg", "source_ref", targetSha],
      ...["--arg", "scope", scope, "--arg", "app", app, "--arg", "serve", serve, "--arg", "health", health, "--arg", "seed", seed],
      ...["--argjson", "health_timeout", healthTimeout, "--arg", "fx_profile", fxProfile, "--arg", "fx_resolver", fxResolver],
      ...["--arg", "cfg_path", cfg, "--arg", "cfg_sha", cfgSha, "--arg", "know_path", know, "--arg", "know_sha", knowSha],
      ...["--arg", "config_snapshot_sha", configSnapshotSha, "--arg", "scopes_snapshot_sha", scopesSnapshotSha],
      ...["--arg", "store_manifest_sha", storeManifestSha, "--arg", "ship_receipt_sha", shipReceiptSha, "--argjson", "routing", routingJson || "null"],
      ...["--arg", "e2e_repo", e2e.repo, "--arg", "e2e_repo_path", e2e.path, "--arg", "e2e_ref", e2e.ref, "--arg", "e2e_ref_policy", e2e.policy],
      ...["--arg", "e2e_workdir", e2e.workdir, "--arg", "e2e_command", e2e.command, "--arg", "e2e_fixture", e2e.fixture, "--argjson", "e2e_endpoint", e2e.endpoint],
      ...["--arg", "resolved_at", iso(), PROFILE_JQ],
    ],
    profile,
  );
  if (compiled !== 0) fail(`could not compile the qa profile: ${profile}`);
  const canon = jq(["-S", CANONICAL_JQ, profile]);
  ee(canon.status);
  const profileSha = sha(canon.out);
  let staged: { path: string; fd: number } | null = null;
  try {
    staged = exclusiveTemp(u8(`${profile}.tmp`));
  } catch {}
  if (staged === null || runToFd(["jq", "--arg", "psha", profileSha, ". + { profile_sha256: $psha }", profile], staged.fd) !== 0 || mv(b8(staged.path), profile) !== 0)
    fail(`could not record the profile hash: ${profile}`);

  // TEST SEAM, double-keyed: the exec also needs AC_TEST_HOOKS=1, so one
  // inherited variable cannot make a production run execute an arbitrary file.
  const hook = b8(process.env.AC_QA_PROFILE_RECHECK_HOOK || "");
  if (process.env.AC_TEST_HOOKS === "1" && hook !== "" && executable(hook))
    run([hook, cfg, know], { stdout: "inherit" });
  if (qaSourceSha256(cfg) !== cfgSha || qaSourceSha256(know) !== knowSha || qaSourceSha256(shipSrc) !== shipSrcSha) {
    rmrf(tmpd);
    ret(
      "profile-stale",
      "a durable source changed between freeze and spawn (project config, repo-knowledge, or the selected ship test receipt no longer matches the frozen profile) - re-resolve",
    );
  }
  const berr = qaBundleValidate(profile, targetSha);
  if (berr !== null) drop(`staged qa profile bundle is invalid: ${berr}`);
  if (mv(tmpd, bundle) !== 0) drop(`could not atomically publish qa profile bundle: ${bundle}`);
  profile = `${bundle}/profile.json`;

  const briefText = readText(brief);
  if (briefText === null) fatal(1);
  ee(
    put(
      combined,
      `# QA verifier brief\n\nExact target: \`${targetSha}\`\n\nRun the QA pipeline from the verifier worktree with this command shape:\n\n` +
        `\`${binDir}/ac-qa.sh start --target ${targetSha} --task ${task} --evidence ${evidence}/evidence${home ? ` --home ${home}` : ""}${scope ? ` --scope ${scope}` : ""}${app ? ` --app ${app}` : ""}\`\n` +
        `\n## Acceptance input\n\n${briefText}\n`,
    ),
  );
  const args = ["qa", "--repo", repo, "--ref", targetSha, "--family", family, "--caller", caller, "--brief", combined, "--output", result, "--evidence-dir", evidence, "--profile", profile, "--report", report];
  if (harness !== "") {
    args.push("--harness", harness);
    if (model !== "") args.push("--model", model);
    if (effort !== "") args.push("--effort", effort);
  }
  if (round > 1 && nonEmpty(previous)) args.push("--history", previous);
  if (withHome(qaHome, () => run([verify, ...args], { stdout: "ignore" })).status !== 0) fail(`independent QA round ${round} failed; inspect verifier state and ${result}`);
  if (jq(["-e", "--arg", "ref", targetSha, RESULT_JQ, result], { stdout: "ignore" }).status !== 0) fail(`QA verifier result is invalid or does not bind the exact target: ${result}`);
  const verdictOf = (): string => cap(jq(["-r", ".verdict", result]).out);
  if (cap(jq(["-r", ".report", result]).out) !== report || !nonEmpty(report) || cap(firstLine(run(["sed", "-n", "1p", report]).out)) !== `verdict: ${verdictOf()}`)
    fail(`QA verifier result has no matching canonical stage report: ${report}`);
  if (!nonEmpty(`${evidence}/verdict.json`) || !nonEmpty(`${evidence}/relay-report.md`)) fail(`QA verifier returned without durable verdict and relay evidence: ${evidence}`);
  const verdict = jqA(".verdict", result);
  const summary = jqA(".summary", result);
  say(`verdict: ${verdict}\nQA_VERDICT=${verdict}\nQA_VERIFIED_REF=${targetSha}\nQA_REPORT=${report}\nsummary: ${summary}\n`);
  say(`QA_PROFILE_STATUS=profile-ready\nprofile-key: ${profileKey}\n`);
  say(`\nqa-agent round ${round} evidence=${evidence} profile=${profile}\n`);
}

// --- status, finish ---------------------------------------------------------------

const STATUS_STEPS_AWK = '{ printf "    %-10s %s%s\\n", $1, $2, ($3 > 0 ? " (rounds " $3 ")" : "") }';

function cmdStatus(): void {
  requireRun();
  const rd = runDir();
  say(`run ${readLink(current) ?? ""}\n`);
  const m = run(["sed", "-n", "s/^/  /p", `${rd}/run.meta`]);
  say(m.out);
  ee(m.status);
  say("  steps:\n");
  const s = awk(["-F\\t", STATUS_STEPS_AWK, `${rd}/steps.tsv`]);
  say(s.out);
  ee(s.status);
  if (nonEmpty(`${rd}/cases.tsv`)) say(`  cases: ${countRows(rd, '$3=="pass"')} pass / ${countRows(rd, '$3=="fail"')} fail / ${countRows(rd, '$3=="unverifiable"')} unverifiable\n`);
  const n = visualsValid(rd);
  say(Number(n) > 0 ? `  visuals: ${n} on record\n` : "  visuals: none - finish passed will refuse\n");
}

function cmdFinish(a: string[]): void {
  requireRun();
  const [outcome = "", ...rest] = a;
  if (!["passed", "failed", "unverifiable", "cancelled"].includes(outcome)) fail("usage: ac-qa.sh finish <passed|failed|unverifiable|cancelled>");
  const { v } = valueFlags(rest, ["--retry-reason"], "usage: ac-qa.sh finish <passed|failed|unverifiable|cancelled> [--retry-reason <context-limit|tool-limit|capability-limit>]");
  const retry = v["--retry-reason"]!;
  if (retry !== "") {
    if (outcome !== "unverifiable") fail("--retry-reason is valid only with 'finish unverifiable'");
    if (!["context-limit", "tool-limit", "capability-limit"].includes(retry)) fail(`invalid --retry-reason '${retry}' (expected context-limit|tool-limit|capability-limit)`);
  }
  const rd = runDir();
  if (outcome === "passed") {
    assertTargetCheckout(sedFirst(`${rd}/run.meta`, "target_sha"));
    qaFinishGate(rd);
  } else if (outcome === "failed" || outcome === "unverifiable") muted(() => cmdStep(["verdict", "completed", "--note", `recorded terminal outcome ${outcome}`]));
  if (retry !== "") metaPut(`${rd}/run.meta`, "retry_reason", retry);

  // Teardown after the pass gate: the serve PROCESS GROUP, then compose.
  if (isFile(`${rd}/serve.pid`)) {
    const spid = readText(`${rd}/serve.pid`);
    if (spid === null) fatal(1);
    const pid = cap(spid!);
    if (qaPgidAlive(pid)) {
      try {
        process.kill(-Number(pid), "SIGTERM");
      } catch {
        try {
          process.kill(Number(pid), "SIGTERM");
        } catch {}
      }
    }
    rm(`${rd}/serve.pid`);
  }
  if (commandV("docker")) run(["docker", "compose", "-p", composeProject(), "down", "-v", "--remove-orphans"], { stdout: "inherit", stderr: "ignore" });
  const [total = "", passed = ""] = qaCounts(rd).join(" ").split(" ").filter((x) => x !== "");
  if (run(["sed", "-i", "", "-e", `s/^outcome=.*/outcome=${outcome}/`, `${rd}/run.meta`], { stderr: "ignore" }).status !== 0)
    ee(run(["sed", "-i", "-e", `s/^outcome=.*/outcome=${outcome}/`, `${rd}/run.meta`]).status);
  ee(append(`${rd}/logs/run.log`, `${iso()} finish outcome=${outcome}\n`));
  if (outcome === "passed") {
    const pr = qaPublishAttestation(rd, passed, total);
    if (pr === 0) {
      metaPut(`${rd}/run.meta`, "attestation", "v2");
      metaPut(`${rd}/run.meta`, "attestation_reason", "");
    } else if (pr !== 2) fail("could not publish the validated v2 passing attestation");
    else {
      metaPut(`${rd}/run.meta`, "attestation", "none");
      metaPut(`${rd}/run.meta`, "attestation_reason", "unprofiled");
    }
  } else {
    metaPut(`${rd}/run.meta`, "attestation", "none");
    metaPut(`${rd}/run.meta`, "attestation_reason", `outcome-${outcome}`);
  }
  if (isFile(`${rd}/watch.pane`) && commandV("herdr")) {
    const ses = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default"));
    run(["herdr", "--session", ses, "pane", "close", cap(readText(`${rd}/watch.pane`) ?? "")], { stdout: "ignore", stderr: "ignore" });
    rm(`${rd}/watch.pane`);
  }
  say(qaEnvelope(rd));
}

// --- entry ------------------------------------------------------------------------

const USAGE =
  "usage: ac-qa.sh <start|step|case|visual|findings|testplan-amend|fixture|harness-classify|regression-proposal|curation|store-install|infra|baseline|serve|health|boundary-run|boundary-register|seed|cmd|config|config-proposal|config-install|evidence-dir|store-dir|fix-report|relay-report|fetch-check|agent|status|finish>";

async function main(argv: string[]): Promise<number> {
  backendName();
  require("git", "jq");
  binDir = b8(STARTED_BIN);
  const top = run(["git", "rev-parse", "--show-toplevel"], { stderr: "ignore" });
  if (top.status !== 0) fail("not inside a git repo");
  repo = cap(top.out);
  qdir = `${repo}/.crew/qa`;
  current = `${qdir}/current`;
  assetsDir = `${dirname(binDir)}/.agents/skills/crew-qa/assets`;
  const [verb = "", ...a] = argv;
  switch (verb) {
    case "start":
      cmdStart(a);
      return 0;
    case "step":
      cmdStep(a);
      return 0;
    case "case":
      cmdCase(a);
      return 0;
    case "visual":
      cmdVisual(a);
      return 0;
    case "findings":
      cmdFindings(a);
      return 0;
    case "testplan-amend":
      cmdTestplanAmend(a);
      return 0;
    case "fixture":
      cmdFixture(a);
      return 0;
    case "harness-classify":
      cmdHarnessClassify(a);
      return 0;
    case "regression-proposal":
      cmdRegressionProposal(a);
      return 0;
    case "curation":
      cmdCuration(a);
      return 0;
    case "store-install":
      await cmdStoreInstall(a);
      return 0;
    case "store-curate":
      cmdStoreCurate(a);
      return 0;
    case "store-label":
      cmdStoreLabel(a);
      return 0;
    case "store-calibration":
      cmdStoreCalibration();
      return 0;
    case "infra":
      return cmdInfra(a);
    case "baseline":
      cmdBaseline();
      return 0;
    case "serve":
      cmdServe();
      return 0;
    case "health":
      cmdHealth();
      return 0;
    case "boundary-run":
      return cmdBoundaryRun(a);
    case "boundary-register":
      cmdBoundaryRegister(a);
      return 0;
    case "seed":
      return cmdSeed();
    case "cmd":
      return cmdCmd(a);
    case "config":
      return cmdConfig(a);
    case "config-proposal":
      cmdConfigProposal(a);
      return 0;
    case "config-install":
      cmdConfigInstall(a);
      return 0;
    case "evidence-dir":
      say(`${evidenceDir(false)}\n`);
      return 0;
    case "store-dir":
      cmdStoreDir();
      return 0;
    case "fix-report":
      cmdFixReport();
      return 0;
    case "relay-report":
      cmdRelayReport(a);
      return 0;
    case "fetch-check":
      cmdFetchCheck(a);
      return 0;
    case "agent":
      cmdAgent(a);
      return 0;
    case "status":
      cmdStatus();
      return 0;
    case "finish":
      cmdFinish(a);
      return 0;
  }
  return fail(USAGE);
}

export { qaPgidAlive };

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  let rc = 0;
  try {
    rc = await main(args.map(b8));
  } catch (e) {
    if (typeof (e as Exit).exit !== "number") throw e;
    rc = (e as Exit).exit;
  }
  process.exit(rc);
}
