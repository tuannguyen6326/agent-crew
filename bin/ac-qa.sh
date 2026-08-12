#!/usr/bin/env bash
# ac-qa.sh - state machine + deterministic runner for the qa pipeline
# (behavioral verification with evidence, the ac-ship model applied to QA).
#
# Run from inside the target repo/worktree being verified. State lives at
# <repo>/.crew/qa/<run-id>/ with a `current` symlink; durable and resumable
# after a pane restart.
#
# Usage:
#   ac-qa.sh start --target <ref> [--task <id>] [--evidence <dir>] [--store <dir>]
#                                 [--home <abs>]
#                                 [--scope <name> --app <name>]
#   ac-qa.sh step <name> <status> [--note <text>]
#                                         (baseline and serve are OWNED
#                                          transitions; see BOUNDARY POLICY)
#   ac-qa.sh baseline                     (validate the FROZEN ship test
#                                          receipt; never runs a suite)
#   ac-qa.sh boundary-run --case <id>
#            --boundary <http|grpc|client-cli|workflow|queue|schedule>
#            --evidence <path> -- <command> [args...]
#                                         (drive the booted deliverable from
#                                          OUTSIDE its process; stdout is the
#                                          published receipt path)
#   ac-qa.sh boundary-register --case <id> --boundary web
#            --transcript <path> --visual <path>
#   ac-qa.sh boundary-register --case <id> --boundary e2e
#            --upstream-receipt <path> --evidence <path>
#   ac-qa.sh case <case-id> <pass|fail|unverifiable> --tier <api|db|workflow|web>
#            [--boundary <b> --receipt <path>]
#                                         (REQUIRED on pass/fail; see
#                                          BOUNDARY POLICY)
#            [--classification <defect|flaky|test-maintenance|environment>]
#            [--confidence <0..1>] [--grade <A|B|C|D>] [--evidence <path>]
#            [--note <text>]              (the park's REASON; see INFRA
#                                          CONTAINMENT)
#            [--authority <text>] [--repro <path>]
#                                         (REQUIRED on `fail
#                                          --classification defect`; see
#                                          FINDING AUTHORITY)
#   ac-qa.sh visual <path> [--case <id>] [--note <text>]
#                                         (register a VISUAL artifact; see
#                                          VISUAL EVIDENCE)
#   ac-qa.sh findings <step>              (JSON array on stdin, ac-ship schema:
#                                          id,severity,action,file,line,description,
#                                          authority_class,authority;
#                                          refuses a tty)
#   ac-qa.sh findings <step> --show       (print stored findings, writes nothing)
#   ac-qa.sh testplan-amend --case <id> [--case <id> ...]
#                  --authority <behavioral-authority> --reason <why>
#   ac-qa.sh fixture <pack-id> --selector <selector>
#                  --case <case-id> [--case <case-id> ...]
#   ac-qa.sh harness-classify <path>
#                  --classification <repo-regression|e2e-regression|fixture-pack|
#                                    evidence-only|retire>
#                  --target <suite-or-store> --invariant <behavior>
#                  --evidence <path>
#   ac-qa.sh regression-proposal <patch>
#   ac-qa.sh curation <completed|skipped|failed> [--note <reason>]
#   ac-qa.sh store-install <curation-candidate-dir>
#   ac-qa.sh infra <detect|up|down|status|reap> [--services <a,b,...>] [--task <id>]
#     detect = scan the repo for needed profiles (postgres/redis/temporal);
#     up with NO --services (and no qa.infra) boots NOTHING - a service that
#     needs no backend never pulls infra it will not use;
#     the FIRST up DECLARES the run's need - a wider later up is REFUSED
#     (see INFRA CONTAINMENT).
#   ac-qa.sh store-dir                    (resolve + create the per-project QA
#                                          knowledge store; see KNOWLEDGE STORE)
#   ac-qa.sh serve                        (boot qa.serve under the minimal env)
#   ac-qa.sh health                       (bounded readiness poll of qa.health)
#   ac-qa.sh seed                         (run qa.seed once, after health)
#   ac-qa.sh cmd e2e --cases <id>[,<id>...] (config-resolved runner, minimal
#                                             env, durable execution receipt)
#   ac-qa.sh evidence-dir
#   ac-qa.sh config <dotted.key>          (fleet-home config, frozen at start)
#   ac-qa.sh config-proposal [--id <id>]  (stage a uniquely named config draft)
#   ac-qa.sh config-install <id>           (chief-only conflict-safe install)
#   ac-qa.sh fix-report                   (markdown handoff for a fixer crewmate)
#   ac-qa.sh relay-report [--repo <dir>]  (markdown handoff for the CALLER, who
#                                          is in another worktree; see RELAY
#                                          CONTRACT)
#   ac-qa.sh fetch-check <url>...         (HTTP-GET each embedded visual URL,
#                                          refuse on any non-200; see RELAY
#                                          CONTRACT)
#   ac-qa.sh agent --target <ref> --task <id> [--evidence <dir>] [--brief <path>]
#                  [--home <abs>] [--scope <name> --app <name>]
#                  [--qa-rule <number|default>] [--ship-run <run-id>]
#   ac-qa.sh status
#   ac-qa.sh finish <passed|failed|unverifiable|cancelled>
#                   [--retry-reason <context-limit|tool-limit|capability-limit>]
#
# EXECUTION SURFACE (captain's rule): qa always runs through `agent`, a policy
# adapter over `ac-verify qa`, NEVER inside the implementing crewmate and never
# inline in the orchestrator. The facade prepares a fresh exact-ref lease and
# pane per round, preserves only structured result history, exports verdict,
# run state, artifacts, and relay-report before normal reap, and preserves
# invalid/timeout state for recovery. QA owns no reviewer session, pane
# replacement, headless fallback, or duplicate lifecycle.
#
# PROFILE RESOLVE (authoritative - the fail-closed preflight `agent` runs BEFORE
# ac-verify leases a worktree or spawns a pane): it compiles + validates +
# FREEZES one immutable runtime bundle from the project config
# (ac_project_config_file), repo-knowledge scope/app membership
# (ac_knowledge_scopes), the selected QA-store files, and any caller-selected
# panes.qa routing receipt. It hands <bundle>/profile.json to ac-verify with
# --profile. Covers single-repo (flat + scoped) AND the separate-E2E dual-ref
# case: when qa.e2e.repo is configured, the profile also freezes an `e2e` block
# (the resolved LOCAL clone path, the exact E2E SHA chosen by ref_policy, the
# product workdir, the E2E command, and the explicit endpoint-env map). See
# SEPARATE E2E REPOSITORY below.
# The frozen profile records the sha256 of BOTH durable sources
# (provenance.project_config_sha256 + repo_knowledge_sha256), the exact source
# ref, and its OWN canonical hash (top-level profile_sha256, over the concrete
# execution values + durable-source hashes + exact source/E2E refs, EXCLUDING
# volatile allocation paths and the resolve timestamp). Fixture/resolver
# references are stored by NAME only - a raw secret value never enters it. The
# bundle is assembled under a unique temporary directory, validated, and
# atomically published at <repo>/.crew/qa/agent-<task>-r<N>.profile/ with
# profile.json, config.yaml, scopes.tsv, a hash-bound store/ manifest, and
# ship/test-receipt.env - the frozen exact-SHA ship test receipt named by
# --ship-run (BOUNDARY POLICY). The canonical profile hash covers its snapshot
# entry, so a repaired ship receipt requires a fresh profile and a fresh pane,
# and a change to any frozen source between freeze and spawn is profile-stale.
# The preflight returns exactly one structured status and, for any non-ready
# status, spawns NO verifier pane (the return precedes the ac-verify call):
#   profile-ready    complete, current, safe, frozen -> spawn the verifier.
#   needs-profile    a durable source is absent (no project config, or the flat
#                    service contract / a scoped config block is missing).
#   profile-conflict the two durable sources disagree (mode mismatch, an
#                    undeclared config scope block, an ambiguous scope map, or a
#                    named scope/app absent from the closed membership list).
#   profile-stale    a durable source changed between freeze and spawn (a frozen
#                    hash no longer matches) - abort and re-resolve.
#   ask-user         a credential/secret-resolver decision is not mechanical
#                    (a declared qa.fixtures.resolver with no authorized
#                    qa.fixtures.profile) - hold for the chief to relay.
# A caller-argument error (a flat project given --scope/--app, or a scoped
# project with neither named) is refused fail-closed too, but is not one of the
# five statuses: its remedy is to fix the invocation, not the durable sources.
#
# Steps (fixed order):
#   pin testplan baseline infra serve cases e2e evidence verdict
# Step statuses: pending running fixing completed skipped failed
# Environment/infra step failures HOLD the run (resume re-runs the held step);
# CASE failures are findings and ledger rows, never a run abort - the run
# collects every case result before the verdict.
#
# BOUNDARY POLICY (authoritative - every other mention points HERE by name;
# captain ruling 2026-07-25: "QA phai boot service roi kiem tra behavior qua
# client/API/integration boundary", and QA never runs or re-runs unit tests).
# WHAT A QA ROUND MAY BUILD ITS VERDICT FROM:
#  - THE BOUNDARY RULE. Every behavioral case exercises the BOOTED deliverable
#    from OUTSIDE its process, through one closed set of client boundaries: an
#    HTTP/gRPC request against the served endpoint (an SDK or CLI acting only as
#    its client counts), a queue message / workflow signal / scheduled trigger
#    consumed by a RUNNING worker, a real browser driving the served UI, or the
#    approved E2E suite. Database, cache, and event-history reads are ASSERTION
#    surfaces for behavior stimulated that way - never the stimulus. A case
#    whose only stimulus is a direct DB write, or a service object constructed
#    inside the QA harness process (dependency-injection recipes included), is
#    NOT behavioral evidence: it is `unverifiable` with an `ask-user` finding
#    naming the missing boundary, never an in-process substitute.
#  - TIERS, closed: api | db | workflow | web. The tier names the client
#    boundary that stimulated the behavior plus the PRIMARY assertion surface;
#    when one stimulus proves both a response and a durable delta, pick the
#    tier of the primary assertion. `integration` is deliberately NOT a tier -
#    under this policy every case is integration-level by construction, so a
#    catch-all would carry no information. `unit` is not a QA execution tier:
#    it is refused at record time and again at finish against a forged row. QA
#    may still AUTHOR a non-executed, test-only unit regression PROPOSAL -
#    execution lands it and the SHIP pipeline runs it; it cannot satisfy the
#    current round.
#  - FROZEN COVERAGE LADDER. The exact `## Coverage` and `## Full Flow`
#    declarations in testplan.md freeze as
#    <run>/testplan-manifest.json (`agentcrew.qa-testplan-manifest/v1`) when
#    `testplan` completes. Every case-producing command refuses before that
#    point. A `ut` coverage row cites a regular test blob in the exact target
#    Git tree and creates no QA case; it is admissible only when the frozen
#    exact-SHA ship receipt qualifies. `it` maps to a passing
#    api|db|workflow case; `e2e` maps to a passing web case or a case carrying
#    the existing E2E wrapper receipt. The ship receipt remains informational
#    when no `ut` row exists, so coverage selection - never model dispatch -
#    decides whether it gates.
#  - FULL-FLOW FINAL GROUP. At least one IT/E2E-mapped case is declared as the
#    assembled flow. Every declared case must pass and the minimum effective
#    full-flow receipt started_at must be >= the maximum effective non-flow
#    receipt completed_at. A late component retry therefore re-runs and rebinds
#    the final group. Selection may change by authority only before any case,
#    boundary, fixture, or E2E evidence exists.
#  - RUNTIME BOOT RECEIPT. `serve=completed` is not proof by itself, so `serve`
#    is an OWNED transition: `ac-qa.sh serve` boots the frozen qa.serve command,
#    freezes the runtime descriptor (the resolved endpoint/worker mapping every
#    boundary driver runs under), records the provisional launch, and makes the
#    step completed - a direct `step serve completed` REFUSES. `health` stays a
#    COMMAND and owns no step; its proof is <run>/runtime/receipt.env
#    (agentcrew.qa-runtime-receipt/v1), which only a zero-exit probe against a
#    still-live process group can publish. There is NO re-issue path inside one
#    round: a restart would detach every case already recorded from the runtime
#    it exercised, so `serve` refuses once a receipt exists and the round
#    finishes honestly instead.
#  - CLIENT-BOUNDARY EXECUTION RECEIPTS. Every pass/fail case binds one
#    immutable <run>/boundaries/<case-id>/<ts>-<pid>.env
#    (agentcrew.qa-boundary-receipt/v1) hash-bound to that boot receipt.
#    `boundary-run` executes a shell client under the minimal env plus ONLY the
#    frozen descriptor's mapping, publishes a receipt even on non-zero exit, and
#    returns the driver's code (its stdout is the receipt path, so a case
#    composes: `--receipt "$(ac-qa.sh boundary-run ... -- <cmd>)"`).
#    `boundary-register` wraps the two drivers this script did not run: a real
#    browser (transcript + visual, registered BEFORE the final case row exists)
#    and the existing immutable `cmd e2e` receipt (valid only when it NAMES the
#    case and matches the frozen source/E2E/profile/command). Tier/boundary
#    coherence, case identity, runtime identity, and `pass => exit 0` are
#    checked at RECORD time and again at the gate, so a hand-forged ledger row
#    meets exactly the check that admitted the honest one.
#  - BASELINE IS A RECEIPT CHECK, NEVER A RE-RUN. Unit-suite health belongs to
#    the ship pipeline exclusively (ac-ship.sh's SHIP TEST RECEIPT block).
#    `agent --ship-run <id>` freezes that run's exact-SHA receipt into
#    <bundle>/ship/test-receipt.env before the verifier lease exists - the
#    mutable ship `current` symlink is never consulted, and every non-qualifying
#    shape (omitted flag, missing run, another target, interrupted, non-zero)
#    normalizes to one closed reason. `ac-qa.sh baseline` owns the step
#    transition (a direct `step baseline completed|skipped` REFUSES), records
#    `qualifies:<reason>` or `not-qualifies:<reason>`, and on the latter files
#    no finding. The state is report-only when no UT mapping exists. When the
#    frozen manifest selects UT, `testplan completed` and the pass gate require
#    `qualifies:<reason>` for the exact source SHA; otherwise the affected AC
#    escalates to IT. A repaired receipt is visible only to a fresh round.
#  - READY RUNTIME IS MANDATORY FOR A PASS. `finish passed` requires
#    serve=completed, a valid boot receipt whose process group is still alive,
#    every passing case bound to that receipt, and - after every other
#    invariant holds and before any teardown - a final live-process check plus a
#    re-run of the frozen health probe, published as an immutable
#    agentcrew.qa-runtime-gate/v1 under <run>/runtime/gates/ with
#    <run>/runtime/gate.current pointing at it. Post-teardown reconciliation
#    (ac-verify.sh) validates THAT record; it never asks a normally terminated
#    process to still be alive. `step serve skipped` stays a valid recording
#    operation and remains compatible with failed|unverifiable|cancelled - it
#    can never satisfy a pass. A standalone CLI-only product has no long-lived
#    booted runtime and is OUTSIDE this passing policy (`unverifiable`), never
#    represented by a fake background command.
# The validators are shared, in ac-qa-lib.sh (ac_qa_ship_receipt_status,
# ac_qa_runtime_receipt_validate, ac_qa_runtime_gate_validate,
# ac_qa_boundary_coherent, ac_qa_boundary_receipt_validate), because three
# actors must agree byte-for-byte: this script records and gates, ac-verify.sh
# reconciles the exported run, and the merge gate reads what they published.
# WHAT THIS DOES NOT PROVE: that arbitrary command text is semantically a good
# test. The mechanism proves an approved driver ran against the recorded ready
# runtime and produced the registered artifacts; rejecting in-process
# construction dressed as a client call stays the verifier's and the captain's
# reading, exactly like INFRA CONTAINMENT and FINDING AUTHORITY below.
#
# TRUSTED CONFIG (unattended-safety): a profiled `start` validates and consumes
# the fixed .crew/qa/profile-runtime/ bundle into <run>/profile/ and uses only
# its config.yaml, scopes.tsv, store/, and profile identity. It never re-reads
# live fleet config or repo knowledge. Direct unprofiled diagnostics retain the
# legacy snapshot behavior. The durable config source is captain-owned and
# branch-immune by LOCATION; the project repo is never a config source.
#
# TARGET-CHECKOUT BINDING (authoritative - every other mention points HERE by
# name): the pass marker is keyed by target_sha, so the checkout the cases
# exercise MUST BE that commit - never merely claimed to be. `start` refuses,
# before it mints any run dir, unless the repo's actual HEAD (`git rev-parse
# HEAD`) resolves to target_sha; `finish passed` RE-PROVES it, before the
# outcome rewrite, so a HEAD that drifted mid-run mints no pass. Both name both
# shas on a mismatch. A DIRTY tree is refused the same way (the exercised code
# is then no commit at all) - but only tracked-file changes count: untracked
# and the sanctioned .crew/ pool artifacts are ignored (`git status -uno`, the
# ac-sync model). A status that cannot be READ is refused too, never taken for
# clean: an unreadable tree is not evidence of a committed one, and this guard is
# what stands between a qa pass and a run that exercised something else.
# In production the `agent` verb runs from a fresh pool worktree
# detached at the target, so HEAD == target_sha by construction; this guard is
# what makes that a proof, not a convention.
#
# INFRA (docker, unattended-safe): compose profiles ship with the crew-qa skill
# (assets/compose.yaml: postgres, redis, temporal dev-server, wiremock).
# Everything is task-scoped: compose project `crew-qa-<repo>-<task>`, no
# container_name, no fixed host ports (readback via `docker compose port`
# into <run>/ports.env). A project override (config qa.mocks_compose) is
# LINTED before use: external volumes, host bind mounts, container_name,
# docker.sock, privileged, network_mode host all fail closed. `down` is
# label/project-scoped only; `reap` sweeps crew-qa-* projects whose state
# dir is gone (wired into ac-teardown.sh / ac-session-start.sh). Cleanup
# never touches containers this tool did not create.
#
# INFRA CONTAINMENT (authoritative - every other mention points HERE by name): a
# run DECLARES its infra need ONCE, and nothing outside that declaration ever
# boots. The FIRST `infra up` writes its requested list to <run>/infra.declared;
# a later `infra up` naming a service outside it is REFUSED, before docker runs,
# so a case that discovers a missing service mid-run PARKS with the reason
# (`case <id> unverifiable --classification environment --note <why>`) instead of
# silently widening the stack. Booting what the cases never touch is not free:
# slower boots, resource conflicts, flakier runs, noisier failures.
# A REPEAT or a SUBSET of the declaration SUCCEEDS. Infra failures HOLD the run
# and a resume re-runs the held step verbatim, so a once-only guard would break
# resume; the refusal fires on WIDENING only.
# THE SPLIT (the load-bearing design decision): this SCRIPT enforces CONTAINMENT
# (what BOOTS), the crew-qa SKILL owns DECLARATION (which services the run needs
# and WHY - the testplan's `## Infra` block). `infra up --services <list>` IS the
# declaration act: an execution this script observes, which is the only thing it
# can enforce. The testplan is agent-authored markdown in AC_HOME, outside the
# repo under test; parsing it to check "did each service get a why" would be an
# honor claim dressed as attestation by execution - the same reason the RELAY
# CONTRACT below is deliberately not fail-closed.
# What this does NOT prove: the declaration is whatever the first `infra up`
# asked for - never checked against the testplan, the diff, or the real need. A
# run that over-declares is contained to a list it over-declared, and a run that
# declares nothing simply boots nothing. This bounds WIDENING mid-run, nothing
# more; the skill's declaration gate and the captain's review are what keep the
# list itself honest.
#
# MINIMAL ENV: serve/seed/e2e run under `env -i` + PATH/HOME/LANG + the
# generated <run>/ports.env (QA_BASE_URL, QA_PORT, QA_PG_URL, ...) - the
# ambient shell env (tokens, cloud keys) never reaches the target service.
#
# VERDICT AND COMPLETION: the pane records an outcome, but durable run.meta is
# the sole exported-verdict authority. Before `passed` changes the outcome or
# publishes a marker, qa_finish_gate requires every fixed step terminal,
# actionable findings resolved, a hash-valid test plan, a completed serve step
# with a live valid runtime boot receipt, a qualifying frozen ship test
# receipt, every unique passing case graded with in-root durable evidence AND a
# coherent boundary receipt bound to that runtime, every web case linked to a
# valid visual, any completed E2E step backed by its exact-ref receipt, and
# finally a freshly published runtime gate receipt (BOUNDARY POLICY). A passing
# profiled run publishes a parser-validated agentcrew.qa-attestation/v2 marker
# through a unique temporary file plus atomic rename; an unprofiled diagnostic
# pass writes no merge marker. Non-passing outcomes remain recordable. The
# verifier facade reconciles the run, atomically publishes canonical report.md,
# and keeps relay-report.md as a separate transport checklist.
# finish ALWAYS tears down the serve process group + infra and emits:
#   QA_VERDICT= QA_TOTAL= QA_PASSED= QA_FAILED= QA_UNVERIFIABLE= QA_FLAKY=
#   QA_VISUALS= QA_REPORT= QA_RUN_ID= SERVICE_LAUNCHED=
#
# VISUAL EVIDENCE (fail-closed): EVERY run owes >=1 portable visual artifact -
# normally a screenshot of the test report - even when every case is api/db.
# `visual <path> [--case <id>] [--note <text>]` registers one into
# <run>/visuals.tsv (path, kind, bytes, case, at, note; locked read-modify-write
# like cases.tsv, last write per PATH wins so a re-shot screenshot updates its
# row instead of double-counting). It is admitted only after its MAGIC BYTES say
# png/jpeg/gif/webp - the extension is never consulted, so `touch shot.png`
# cannot mint a pass - and a `--case` link must already be in the ledger.
# The gate RE-READS every row at finish: a row whose file is gone, or no longer
# the kind it claimed, does not count. Registration-time validation alone would
# let a screenshot registered from a temp dir that is later cleaned mint a pass
# whose evidence page links a dead file.
# `finish passed` REFUSES with zero valid visuals, and REFUSES on an empty case
# ledger (a run that recorded no case verified nothing). Both guards sit before
# the run.meta rewrite, so a refusal leaves outcome=running and mints no pass
# attestation - ac_qa_gate_ok never sees a lie. `step evidence completed`
# refuses too, while the live stack is still UP (ergonomics only: finish tears
# down serve+infra BEFORE its guards, so a refusal there costs a whole re-run;
# `step evidence skipped --note <why>` is the escape, exactly as `step review
# skipped` bypasses ac-ship.sh's review.agent gate).
# What this does NOT prove: only the first 3-12 bytes are read and no decoder
# runs, so ANY file carrying a valid signature passes - a 1x1 png, or a real
# screenshot of the wrong thing. The floor is auditability - one artifact per
# RUN, deliberately asserted - not proof of behavior; the crew-qa skill owns
# what a picture must SHOW (and still requires a screenshot per web case). Rows
# never carry across runs: each re-run captures its own.
#
# FINDING AUTHORITY (authoritative - every other mention points HERE by name):
# asserting a DEFECT is the act that turns a statement into a fixer's work, so
# it is the act this script binds. `case <id> fail --classification defect` is
# REFUSED without both:
#   --authority <text>  WHO states the case's EXPECTED behaviour and WHERE - a
#     file:line, a URL, or `captain <date>`. A bare document name is not a
#     citation; a line number is the cheapest evidence the author opened it.
#     With nothing citable the case is `unverifiable --note '<why>'`, never a
#     defect - and the refusal NAMES that remedy, like the INFRA CONTAINMENT one.
#   --repro <path>      an EXECUTABLE reproduction carrying two non-empty header
#     lines, `# DISPUTED: <the one variable under dispute>` and
#     `# HELD-CONSTANT: <everything the two legs share, named>`. Missing,
#     non-executable, or either header absent/empty is refused.
# Both land in cases.tsv as APPENDED columns ($9 authority, $10 repro), so every
# existing awk -F'\t' index stays valid and pre-change rows render as "-".
# THE SPLIT (deliberate, not an omission): a machine can check that the
# reproduction EXISTS, is executable, and DECLARES its controls. It cannot check
# that the declaration is TRUE - deciding whether a script varies more than one
# variable is not decidable in general. Comparing the two headers against the
# script body is therefore a named READING step in the code-review brief and in
# the crew-qa skill's adversarial checklist, not a check here. Same honest split
# as INFRA CONTAINMENT: enforce the executed act, leave the judgment to a reader.
# Findings (`findings <step>`) carry the same contract on their own wire via
# ac_findings_normalize - see bin/ac-ship.sh's Findings JSON block.
#
# RELAY CONTRACT (authoritative - every other mention points HERE by name): qa
# writes to `data/<family>/qa/` ONLY. It never posts to the PR, the room, or the
# captain, and it never merges; staying off those surfaces is what keeps the
# verdict independent. Whoever CALLED qa relays it outward, and carries the
# EVIDENCE, not just the verdict: the QA_* envelope, the case table, the on-disk
# report, and every registered visual EMBEDDED in the PR comment (private-repo
# recipe: crew-qa skill), each one run through `fetch-check <url>...` first -
# a URL that never serves is a 404 the captain would otherwise discover
# themselves. Plus the CORRECTION DUTY - any claim in the PR body
# this run supersedes ("not run", "verified statically only", "tests pending")
# MUST be corrected in the SAME relay; a stale validation claim left standing is
# a lie the crew told the captain. `relay-report [--repo <dir>]` renders the
# contract from the finished run's own state (the fix-report shape: a contract
# for another actor, rendered from state only this script holds); aim it with
# --repo, since qa ran in a worktree the caller is not standing in.
# NOT fail-closed, deliberately: the relay lands on surfaces (gh, ac-room.sh)
# this script cannot observe, and a marker the crewmate asks for would be an
# honor claim, not attestation by execution. The merge gate is where a human
# still checks. Contrast VISUAL EVIDENCE, which this script CAN enforce (it owns
# cmd_finish and the attestation it mints) and therefore must.
#
# Config keys (qa.*): serve, health, health_timeout, seed, e2e.command,
# e2e.repo, e2e.ref_policy, e2e.workdir, e2e.endpoint_env (map),
# e2e.fixture_profile, infra (agent-read list), mocks_compose.
# `cmd` exit codes: the command's own; 4 = not configured.
#
# SEPARATE E2E REPOSITORY (authoritative - the dual-ref path; every other
# mention points HERE by name): a qa.e2e.repo turns this profile into a dual-ref
# run whose E2E suite lives in its OWN repository at an exact frozen SHA.
#  - RESOLVE (cmd_agent): qa.e2e.repo resolves via ac_project_dir to a LOCAL
#    clone (a project name under $AC_HOME/projects, or a path) - an EXTERNAL
#    actor that must already exist; an absent clone is needs-profile. The exact
#    E2E SHA comes from qa.e2e.ref_policy (only configured-default-branch-head:
#    the local clone's default-branch head), frozen into the profile's e2e block
#    with workdir (scope-level, repo-level fallback, default `.`), command
#    (repo-level, scope override), endpoint_env (name->runtime-ref map), and
#    fixture_profile (reference name).
#  - LEASE (ac-verify.sh): the facade reads the profile's e2e block and leases a
#    SECOND worktree at the exact E2E SHA, records BOTH under the plural `leases`
#    grammar (source:e2e), and releases BOTH on pass/fail/timeout/pre-spawn
#    abort. A pane does not inherit the facade's env, so the runtime E2E worktree
#    + profile identity are handed to this script through the validated
#    <source-lease>/.crew/qa/profile-runtime/ bundle. Volatile allocations live
#    only in runtime.json; `start` consumes the directory into <run>/profile/.
#  - RUN (cmd_cmd e2e): with an E2E worktree recorded, the e2e step runs from
#    <e2e-worktree>/<workdir> under the minimal env PLUS the explicit
#    endpoint-env mapping (each configured NAME receives the runtime value of
#    the reference it maps to, e.g. BASE_URL <- $QA_BASE_URL), and REFUSES an
#    undeclared developer .env in that workdir (a personal .env is never an
#    approved credential source). A bundle with an empty E2E worktree runs the
#    approved command in the source repo (single-repo behavior unchanged).
#  - ATTEST (cmd_finish): the pass marker BODY binds source_sha, e2e_repo,
#    e2e_sha, and profile_sha256 (empty dual-ref fields are omitted, so a flat
#    marker keeps its lean shape). The gate still keys off the marker FILENAME.
#
# SCOPED CONFIG (authoritative - qa_key_path and qa_validate_selection
# implement exactly this). A monorepo's qa config is keyed by SCOPE - a group
# of apps sharing a DB schema and infra - and by APP below it. Which keys move
# below the repo is decided by ONE test: does a wrong value produce a FALSE
# GREEN? `serve` boots a different binary and `health` probes another app's
# route, so both are APP level; `seed` migrates another schema, so it is SCOPE
# level; `infra`, `health_timeout`, `mocks_compose`, `e2e.*` cost time or fail
# loudly, so they stay REPO level.
#
#   qa:
#     infra: [postgres, redis]       # REPO level, unchanged
#     scopes:
#       orchid:
#         seed: ...                  # SCOPE level (required when seed runs)
#         apps:
#           orchid-service:
#             serve: ...             # APP level (required when serve runs)
#             health: ...
#
# WHICH SCOPES EXIST is not the yaml's to say: the yaml says how to RUN a
# scope, the repo-knowledge record's `scope` entries are the CLOSED LIST of
# which ones exist (bin/ac-know.sh). Mode detection is therefore TWO-SIDED,
# and every invocation on a scoped project names BOTH the scope AND the app -
# there is no one-member inference, because an inference that is safe only
# while a fact stays true is the same stale-fact failure in another costume,
# and naming the app is what puts it in run.meta.
#
# THE PRECEDENCE CHAIN is TOTAL and ORDERED; the first hit wins, nothing below
# it runs, and no refusal ever falls back to a repo-level value, the first
# scope, or the first app:
#   parse  a repeated selector refuses naming BOTH values (identical repeats
#          included - the flag loop is last-wins by construction, which is
#          exactly the silent default this closes)
#   -1     an AMBIGUOUS map refuses at the freeze, never degrades to flat
#   0      mode detection: map declares scopes? yaml carries qa.scopes?
#          BOTH -> scoped;  EXACTLY ONE -> F8;  NEITHER -> flat.
#          The yaml side asks PRESENCE (ac_yaml_has), never "has children":
#          `scopes:` lands before the first block under it, so an EMPTY block
#          is the ordinary half-authored state, and reading it as ABSENT drops
#          the project to FLAT and runs the stale single-app profile - the
#          exact hole two-sided detection exists to close. F9 below is the
#          one that wants the child NAMES.
#   0b     a selector on a FLAT project refuses naming that the project
#          declares no scopes. This is NOT F8: F8 says "neither cleanly flat
#          nor cleanly scoped", 0b says "this project declares none at all",
#          and conflating them tells a caller their config is half-migrated
#          when they merely named a profile on a single-app repo
#   1      F9 closed list over the WHOLE file, not just the selected scope
#   2-5    F1, F2, F4, F5 - answered from the MAP alone
#   6-8    F3, F7, F6 - answered from the YAML
# Everything checkable against the declared truth is checked before anything
# is asked of the configuration, so "you named a scope that does not exist"
# never arrives disguised as "that scope has no config block". F6/F7 are
# conditional on their step RUNNING, and serve/health/seed all run under the
# one `serve` step, so that condition is a single test.
#
# THE FLEET HOME (authoritative - ac-know.sh carries the identical contract,
# and one rule a crewmate can learn beats two it must tell apart): `start` and
# `agent` take `--home <abs>`, and it is the SINGLE home resolution of a run.
# BOTH sources the run needs - the project config and the scope map - descend
# from that ONE value and are FROZEN into the run dir, so the two can never
# straddle two homes; every later step reads only the frozen copies and the
# home is never consulted again.
# Ladder (ac_home_resolve, ac-lib.sh, shared with ac-know.sh): `--home` >
# $AC_HOME tested DIRECTLY > this checkout's own home. Rung 2 is tested
# directly rather than through ac_home(), which REFUSES when the variable is
# unset and would kill this ladder before rung 3. Rung 3 is KEPT rather than
# refused, for the reason ac-know.sh keeps it, and it is now the ONE surviving
# path by which the distro checkout can still become a home: ac_home itself no
# longer adopts it. OPEN (routed, not decided here): whether rung 3 should
# refuse too is a captain call, not a side effect of that change. What made
# rung 3 dangerous was INVISIBILITY, so a run that lands on it PRINTS the home
# it used - the same answer as ac-know.sh's `recorded in <path>` receipt.
# Guards on `--home`: ABSOLUTE, and not inside $repo - the invariant
# ac_project_config_file states in code ("the project repo is never a config
# source... so a branch under test cannot alter commands or merge policy").
# HOW THE PATH TRAVELS: exactly as --store does. qa panes carry no AC_HOME, so
# the actor that HAS it bakes --home into the qa brief and the agent passes it
# at `start`. It is a trust IMPROVEMENT over what it replaces: an
# unauthenticated ac_root fallback becomes a value baked by the actor that
# holds the authority. What it does NOT prove: --home is taken on trust beyond
# its two guards, exactly like --store.
#
# KNOWLEDGE STORE (qa-knowledge-reuse): per-project, durable, OUTSIDE the
# repo clone - $AC_HOME/data/qa-store/<project>/ (project = the repo scope,
# same key infra containment uses). Layout, owned here:
#   guide.md      the project TEST GUIDE: how to boot its infra, run its e2e
#                 suite, accounts/selectors/scrub rules - corrected every run.
#   catalog.md    the index the skill loads FIRST: one line per case -
#                 `- <case-id> | <surface> | <one-liner> | verified <sha> <date>`.
#   cases/<case-id>.md   one reusable case per file: surface, needs (infra),
#                 fixtures, drive steps, expected, `verified: <sha> <date>`,
#                 `status: active|retired (<reason>)`.
# STALENESS: a case is SUSPECT when `git diff --stat <verified-sha>..HEAD --
# <its surface paths>` is non-empty, or its verification is older than 30
# days - suspects are re-verified or re-derived, never silently reused.
# CURATION is part of every run (the crew-qa skill owns the mechanics): after
# the verdict, new/changed cases are recorded, failing-because-code-moved cases
# are retired with a reason, and guide corrections land - knowledge
# accumulates instead of evaporating. `store-dir` prints the store path
# (creating it), so scripts and skills share ONE path contract.
# RESOLUTION (fail-closed): store-dir's ladder mirrors evidence-dir's - an
# explicit `--store` recorded at `start` > $AC_HOME/data/qa-store/<project>
# when the caller's env carries AC_HOME > REFUSE. The absent third rung is the
# ONE deliberate departure from cmd_evidence_dir, which falls back to the run
# dir: misplaced evidence is local and visible, but a per-project durable store
# inside a disposable pool worktree is not a store. Resolving anyway is worse
# than refusing - and before ac_home() refused an unset AC_HOME (ac-lib.sh,
# "a fleet home is NAMED, never guessed"), it answered the checkout that owns
# bin/, which collapsed EVERY fleet's store into the distro tree
# and handed the agent an empty one to rebuild from scratch: the exact disease
# the store cures, now invisible instead of merely absent. The guard precedes
# the mkdir, so a refusal mints nothing.
# HOW THE PATH TRAVELS: not the environment. qa panes (ac-pane-agent.sh) and
# crewmate panes (ac-spawn.sh:184-191) carry NO AC_HOME - only the roomchief and
# crewdeputy launch lines ride it (ac-spawn.sh:1022,1154). So the actor that HAS
# AC_HOME bakes the absolute path into the qa brief, the agent passes it at
# `start`, and run.meta holds it for every later store-dir (load at step 2,
# curate at step 10) - the same route --evidence already travels.
# What this does NOT prove: --store is taken on trust beyond being absolute.
# A path into a pool worktree is accepted and evaporates with the lease; this
# script cannot see the fleet home to check. The brief is the only defense,
# exactly as with --evidence.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-pipeline-lib.sh"
. "$(dirname "$0")/ac-qa-lib.sh"
. "$(dirname "$0")/ac-backend.sh"   # ac_herdr_agents_workspace/ac_herdr_tab_open
ac_require git jq

# Resolved ONCE, here, while the cwd is still the caller's: the watch dashboard
# is handed to a pane that runs in a DIFFERENT directory (--cwd "$repo"), so a
# caller-relative "$(dirname "$0")" would not resolve there.
bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

STEPS="pin testplan baseline infra serve cases e2e evidence verdict"
STATUSES="pending running fixing completed skipped failed"
CASE_STATUSES="pass fail unverifiable"
# The CLOSED tier set of the QA boundary policy. Every tier names a client
# boundary outside the deliverable's process plus the primary assertion
# surface; `unit` is REMOVED, and `integration` is deliberately absent because
# every case here is integration-level by construction (header: BOUNDARY RULE).
CASE_TIERS="api db workflow web"
BOUNDARIES="http grpc client-cli workflow queue schedule web e2e"
KNOWN_SERVICES="postgres redis temporal wiremock"
# Set by the commands that OWN a step transition (baseline, serve) while they
# call cmd_step, so the direct-transition refusal below can tell the owning
# command apart from an agent typing `step baseline completed` by hand.
step_owner=""

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || ac_die "not inside a git repo"
qdir="$repo/.crew/qa"
current="$qdir/current"
assets_dir="$(ac_root)/.agents/skills/crew-qa/assets"

require_run() { [ -L "$current" ] || ac_die "no active qa run; ac-qa.sh start first"; }
run_dir() { readlink "$current" >/dev/null || ac_die "broken current symlink"; printf '%s/%s\n' "$qdir" "$(readlink "$current")"; }

watch_open() {
  # Auto-open the live qa dashboard in a herdr tab (label ac-qa-watch),
  # mirroring ac-ship.sh: idempotent, never fails the caller, disabled with
  # AC_QA_WATCH=off. The watch self-closes on finish/idle; finish also
  # closes it via <run>/watch.pane.
  local rd="$1" task="$2" ses ws out p label
  [ "${AC_QA_WATCH:-auto}" = off ] && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  ses="${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}"
  herdr --session "$ses" pane list 2>/dev/null | grep -q '"label":"ac-qa-watch"' && return 0
  label="ac-qa-watch-$(sanitize_compose "$task")"
  # The watch tab joins its FAMILY's workspace (ac-backend.sh FAMILY
  # WORKSPACE GROUPING), family from the task id through the scope ladder.
  ws="$(AC_WINDOW_FAMILY="$(ac_window_family "$task")" \
    ac_herdr_agents_workspace 2>/dev/null || true)"
  out="$(ac_herdr_tab_open "$ses" "$label" "$repo" "$ws")" || return 0
  p="${out%% *}"
  # DEGRADE (F26, mirrors ac-ship.sh): the tab is already open by now, so a
  # rename/run that fails (pane gone, herdr wedged) must cost this run its
  # DASHBOARD, never abort the caller under `set -euo pipefail` - unguarded,
  # this was a live start-abort hazard the ac-ship.sh copy had already fixed.
  herdr --session "$ses" pane rename "$p" ac-qa-watch >/dev/null 2>&1 || true
  herdr --session "$ses" pane run "$p" \
    "'$bin_dir/ac-qa-watch.sh' --repo '$repo' --self-pane $p" >/dev/null 2>&1 || true
  printf '%s\n' "$p" >"$rd/watch.pane"
  return 0
}

sanitize_compose() {
  # docker compose project-name grammar: lowercase [a-z0-9_-].
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-'
}


image_kind() {
  # image_kind <file> - print png|jpeg|gif|webp from the file's MAGIC BYTES, or
  # return 1. The extension is never consulted: `touch shot.png` must not be able
  # to mint a pass. `od` is POSIX (BSD and GNU agree on -An -v -tx1 -N) - `file`
  # is absent from slim container images and worded differently per platform, `xxd`
  # ships with vim, and reading raw bytes through $( ) would strip NULs. Reading
  # via `<"$1"` keeps a path starting with `-` from being parsed as a flag.
  local hex
  hex="$(od -An -v -tx1 -N 12 <"$1" | tr -d ' \n')"
  case "$hex" in
    89504e470d0a1a0a*)           printf 'png\n' ;;
    ffd8ff*)                     printf 'jpeg\n' ;;
    474946383761*|474946383961*) printf 'gif\n' ;;   # GIF87a / GIF89a
    52494646????????57454250*)   printf 'webp\n' ;;  # RIFF + 4-byte size + WEBP
    *) return 1 ;;
  esac
}

qa_sha_string() {
  # qa_sha_string <text> - the one string hasher; command text, argv, and
  # descriptors must hash identically wherever they are compared.
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

qa_path_sha() {
  # Delegates to the shared ac_qa_path_sha (ac-qa-lib.sh): the receipt writers
  # here and the re-provers in the gate and verifier must compute ONE identity.
  ac_qa_path_sha "$1"
}

qa_testplan_path() {
  printf '%s/testplan.md\n' "$(dirname "$(cmd_evidence_dir)")"
}

qa_testplan_ut_rows_ok() {
  # qa_testplan_ut_rows_ok <run-dir> <manifest> - UT is reused only from the
  # frozen exact-SHA ship receipt. Refuse the plan before case execution so the
  # author can escalate the affected AC to IT instead of stranding the round.
  local rd="$1" manifest="$2" status ac
  jq -e '.coverage | any(.rung == "ut")' "$manifest" >/dev/null || return 0
  status="$(ac_qa_ship_receipt_status "$rd/profile/ship/test-receipt.env" \
    "$(ac_meta_get "$rd/run.meta" target_sha)")"
  case "$status" in qualifies:*) return 0 ;; esac
  ac="$(jq -r '.coverage[] | select(.rung == "ut") | .ac' "$manifest" \
    | paste -sd, -)"
  AC_QA_MANIFEST_ERROR="UT coverage ${ac:-<unknown>} requires a qualifying exact-SHA ship receipt (got $status); map the affected AC to IT instead"
  return 1
}

qa_testplan_ready() {
  # qa_testplan_ready <run-dir> - the one precedence check every case-producing
  # command calls before it can mint evidence.
  local rd="$1" plan manifest expected
  [ "$(awk -F'\t' '$1=="testplan"{print $2}' "$rd/steps.tsv")" = completed ] \
    || { AC_QA_MANIFEST_ERROR="a completed testplan step and frozen coverage manifest are required before QA case execution"; return 1; }
  plan="$(qa_testplan_path)"
  manifest="$rd/testplan-manifest.json"
  expected="$(ac_meta_get "$rd/run.meta" testplan_manifest_sha256)"
  ac_qa_testplan_manifest_validate "$repo" "$(ac_meta_get "$rd/run.meta" target_sha)" \
    "$plan" "$manifest" "$expected" || return 1
  qa_testplan_ut_rows_ok "$rd" "$manifest"
}

qa_case_evidence_exists() {
  # Selection becomes immutable once any command has produced case evidence.
  local rd="$1"
  [ -s "$rd/cases.tsv" ] && return 0
  find "$rd/boundaries" "$rd/fixtures/receipts" "$rd/e2e/receipts" \
    -type f -print -quit 2>/dev/null | grep -q .
}

qa_pgid_alive() {
  # qa_pgid_alive <pgid> - is the recorded process GROUP still there? `kill -0`
  # on the negated pgid asks the group, not one pid, so a server that forked
  # workers and exited its wrapper is still correctly seen as alive.
  local pgid="$1"
  case "$pgid" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 -- "-$pgid" 2>/dev/null || kill -0 "$pgid" 2>/dev/null
}

qa_runtime_identity() {
  # qa_runtime_identity <run-dir> - load the five values a runtime receipt
  # binds into qa_id_source / qa_id_profile / qa_id_serve / qa_id_health /
  # qa_id_desc. ONE derivation, shared by the publisher (health), the boundary
  # receipts, and the finish gate - so a mismatch is real drift and never two
  # functions disagreeing about how to hash.
  # It ASSIGNS rather than printing a delimited row on purpose: an unprofiled
  # run has an empty profile hash, and a tab-delimited row read back through
  # `IFS=<tab> read` silently COLLAPSES that empty field (tab is IFS
  # whitespace), shifting every later value one column left.
  local rd="$1"
  qa_id_source="$(ac_meta_get "$rd/run.meta" target_sha)"
  qa_id_profile="$(ac_meta_get "$rd/run.meta" profile_sha256)"
  qa_id_serve="$(qa_sha_string "$(cmd_config qa.serve 2>/dev/null || true)")"
  qa_id_health="$(qa_sha_string "$(cmd_config qa.health 2>/dev/null || true)")"
  qa_id_desc=""
  [ ! -f "$rd/runtime/descriptor.env" ] \
    || qa_id_desc="$(ac_config_sha256 "$rd/runtime/descriptor.env")"
}

qa_runtime_receipt_ok() {
  # qa_runtime_receipt_ok <run-dir> - the boot receipt exists, binds this run's
  # frozen identity, and its recorded process group is STILL ALIVE. Callers that
  # must not require liveness (post-teardown reconciliation) validate the file
  # through ac_qa_runtime_receipt_validate directly instead.
  local rd="$1"
  qa_runtime_identity "$rd"
  ac_qa_runtime_receipt_validate "$rd/runtime/receipt.env" \
    "$qa_id_source" "$qa_id_profile" "$qa_id_serve" "$qa_id_health" "$qa_id_desc" || return 1
  qa_pgid_alive "$(ac_meta_get "$rd/runtime/receipt.env" process_group)" \
    || { AC_QA_RECEIPT_ERROR="the runtime receipt's process group is no longer alive - the booted deliverable is gone"; return 1; }
  return 0
}

qa_boundary_env() {
  # qa_boundary_env <run-dir> <array-name> - the environment a boundary driver
  # runs under: the minimal baseline plus ONLY the client endpoint/worker
  # mapping from the FROZEN runtime descriptor the boot receipt hash-binds.
  # Reading the frozen copy rather than live ports.env is what makes the
  # receipt's runtime_descriptor_sha256 mean something.
  local rd="$1" __out="$2" line
  eval "$__out=()"
  eval "$__out+=(\"PATH=\$PATH\" \"HOME=\$HOME\" \"LANG=\${LANG:-C.UTF-8}\")"
  if [ -f "$rd/runtime/descriptor.env" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && eval "$__out+=(\"\$line\")"
    done <"$rd/runtime/descriptor.env"
  fi
  return 0
}

qa_boundary_receipt_publish() {
  # qa_boundary_receipt_publish <run-dir> <case-id> <boundary> <driver>
  #   <stimulus-sha> <evidence-sha> <upstream-sha|-> <started> <completed> <exit>
  # Stage under a private name, validate the closed schema, then atomically
  # rename into <run>/boundaries/<case-id>/<timestamp>-<pid>.env and print the
  # path. Published even on a non-zero driver exit: the receipt records what
  # executed, and the behavioral verdict is decided elsewhere.
  local rd="$1" case_id="$2" boundary="$3" driver="$4" stimulus="$5" evidence="$6"
  local upstream="$7" started="$8" ended="$9" code="${10}"
  local dir name tmp
  dir="$rd/boundaries/$case_id"
  mkdir -p "$dir"
  name="$(date +%Y%m%d-%H%M%S)-$$.env"
  tmp="$(mktemp "$dir/.receipt.XXXXXX")"
  {
    printf 'schema=agentcrew.qa-boundary-receipt/v1\n'
    printf 'source_sha=%s\n' "$(ac_meta_get "$rd/run.meta" target_sha)"
    printf 'profile_sha256=%s\n' "$(ac_meta_get "$rd/run.meta" profile_sha256)"
    printf 'runtime_receipt_sha256=%s\n' "$(ac_config_sha256 "$rd/runtime/receipt.env")"
    printf 'case_id=%s\n' "$case_id"
    printf 'boundary=%s\n' "$boundary"
    printf 'driver=%s\n' "$driver"
    printf 'stimulus_sha256=%s\n' "$stimulus"
    printf 'evidence_sha256=%s\n' "$evidence"
    printf 'upstream_receipt_sha256=%s\n' "$upstream"
    printf 'started_at=%s\n' "$started"
    printf 'completed_at=%s\n' "$ended"
    printf 'exit_code=%s\n' "$code"
  } >"$tmp"
  [ "$(ac_meta_get "$tmp" schema)" = "agentcrew.qa-boundary-receipt/v1" ] \
    && [ -n "$(ac_meta_get "$tmp" stimulus_sha256)" ] \
    && [ -n "$(ac_meta_get "$tmp" evidence_sha256)" ] \
    || { rm -f "$tmp"; ac_die "boundary receipt for case $case_id could not be staged"; }
  mv "$tmp" "$dir/$name" \
    || { rm -f "$tmp"; ac_die "boundary receipt for case $case_id could not be published"; }
  printf '%s\n' "$dir/$name"
}

qa_counts() {
  # qa_counts <run-dir> - "total passed failed unverifiable flaky visuals" read
  # off the two ledgers. ONE owner: finish's guards and the QA_* envelope must
  # never disagree about what the run recorded.
  local rd="$1"
  printf '%s %s %s %s %s %s\n' \
    "$(wc -l <"$rd/cases.tsv" | tr -d ' ')" \
    "$(awk -F'\t' '$3=="pass"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
    "$(awk -F'\t' '$3=="fail"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
    "$(awk -F'\t' '$3=="unverifiable"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
    "$(awk -F'\t' '$4=="flaky"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
    "$(visuals_valid "$rd")"
}

qa_envelope() {
  # qa_envelope <run-dir> - the machine-readable block, from run state. finish
  # emits it at the verdict and relay-report re-renders it, so the contract the
  # caller relays arrives PREFILLED instead of telling them to go find it.
  local rd="$1" total passed failed unver flaky visuals verdict scope app attestation reason
  verdict="$(sed -n 's/^outcome=//p' "$rd/run.meta" | head -n1)"
  # READ BACK from run.meta, never re-derived: the profile the run proved is
  # what the caller relays outward, and a field nothing reads is decoration.
  scope="$(sed -n 's/^scope=//p' "$rd/run.meta" | head -n1)"
  app="$(sed -n 's/^app=//p' "$rd/run.meta" | head -n1)"
  attestation="$(ac_meta_get "$rd/run.meta" attestation)"
  reason="$(ac_meta_get "$rd/run.meta" attestation_reason)"
  read -r total passed failed unver flaky visuals <<<"$(qa_counts "$rd")"
  printf 'QA_VERDICT=%s\nQA_SCOPE=%s\nQA_APP=%s\nQA_RULE=%s\nQA_HARNESS=%s\nQA_MODEL=%s\nQA_EFFORT=%s\nQA_DISPATCH_SHA256=%s\nQA_TOTAL=%s\nQA_PASSED=%s\nQA_FAILED=%s\nQA_UNVERIFIABLE=%s\nQA_FLAKY=%s\nQA_VISUALS=%s\nQA_REPORT=%s\nQA_RUN_ID=%s\nQA_ATTESTATION=%s\nQA_ATTESTATION_REASON=%s\nSERVICE_LAUNCHED=%s\n' \
    "$verdict" "$scope" "$app" \
    "$(ac_meta_get "$rd/run.meta" qa_rule)" "$(ac_meta_get "$rd/run.meta" qa_harness)" \
    "$(ac_meta_get "$rd/run.meta" qa_model)" "$(ac_meta_get "$rd/run.meta" qa_effort)" \
    "$(ac_meta_get "$rd/run.meta" dispatch_sha256)" \
    "$total" "$passed" "$failed" "$unver" "$flaky" "$visuals" \
    "$(cmd_evidence_dir)/../report.md" "$(readlink "$current")" "${attestation:-none}" "$reason" \
    "$([ -f "$rd/logs/serve.log" ] && printf 'true' || printf 'false')"
}

visuals_live() {
  # visuals_live <run-dir> - the registered rows still backed by a real artifact
  # of the kind they CLAIM, re-reading each file's bytes. The ledger is a claim;
  # the file is the proof - a row registered from a temp dir that was later
  # cleaned, or hand-written into the tsv, is not evidence.
  # ONE owner: the finish gate counts these rows and relay-report embeds them, so
  # the envelope and the artifact list can never contradict each other.
  local rd="$1" path kind rest actual
  [ -f "$rd/visuals.tsv" ] || return 0
  while IFS="$(printf '\t')" read -r path kind rest; do
    [ -n "$path" ] && [ -f "$path" ] || continue
    # Take image_kind's EXIT STATUS, never `$(...) || true`: that would collapse
    # a magic-byte rejection to the empty string, and together with a missing
    # `[ -n "$kind" ]` it would match a blank-kind row and count a forged
    # non-image as proof. Both halves are load-bearing; neither alone is.
    actual="$(image_kind "$path" 2>/dev/null)" || continue
    [ -n "$kind" ] && [ "$actual" = "$kind" ] || continue
    printf '%s\t%s\t%s\n' "$path" "$kind" "$rest"
  done <"$rd/visuals.tsv"
}

visuals_valid() {
  # visuals_valid <run-dir> - how many visuals are real, for the gate + envelope.
  visuals_live "$1" | wc -l | tr -d ' '
}

qa_evidence_path_ok() {
  # qa_evidence_path_ok <declared-root> <path> - accept only an existing regular
  # file or directory whose resolved path remains below the resolved evidence
  # root. realpath-style resolution rejects broken links and symlink escapes.
  local root="$1" path="$2"
  python3 - "$root" "$path" <<'PY'
import os
import sys

root, candidate = sys.argv[1:]
if not root or not candidate or candidate == "-":
    raise SystemExit(1)
root = os.path.realpath(root)
candidate = candidate if os.path.isabs(candidate) else os.path.join(root, candidate)
candidate = os.path.realpath(candidate)
try:
    inside = os.path.commonpath((root, candidate)) == root
except ValueError:
    inside = False
raise SystemExit(0 if inside and (os.path.isfile(candidate) or os.path.isdir(candidate)) else 1)
PY
}

qa_e2e_receipt_ok() {
  # qa_e2e_receipt_ok <run-dir> - a completed E2E step is an execution claim
  # only when its immutable receipt binds the current run and exited zero.
  local rd="$1" ptr receipt command command_sha source_sha e2e_repo e2e_sha profile_sha cases
  ptr="$rd/e2e/receipt.current"
  [ -f "$ptr" ] || return 1
  receipt="$rd/e2e/receipts/$(cat "$ptr")"
  [ -f "$receipt" ] || return 1
  [ "$(ac_meta_get "$receipt" schema)" = "agentcrew.qa-e2e-receipt/v1" ] || return 1
  [ "$(ac_meta_get "$receipt" exit_code)" = 0 ] || return 1
  source_sha="$(ac_meta_get "$rd/run.meta" target_sha)"
  e2e_repo="$(ac_meta_get "$rd/run.meta" e2e_repo)"
  e2e_sha="$(ac_meta_get "$rd/run.meta" e2e_ref)"
  profile_sha="$(ac_meta_get "$rd/run.meta" profile_sha256)"
  [ "$(ac_meta_get "$receipt" source_sha)" = "$source_sha" ] || return 1
  [ "$(ac_meta_get "$receipt" e2e_repo)" = "$e2e_repo" ] || return 1
  [ "$(ac_meta_get "$receipt" e2e_sha)" = "$e2e_sha" ] || return 1
  [ "$(ac_meta_get "$receipt" profile_sha256)" = "$profile_sha" ] || return 1
  command="$(cmd_config qa.e2e.command 2>/dev/null || true)"
  [ -n "$command" ] || return 1
  command_sha="$(qa_sha_string "$command")"
  [ "$(ac_meta_get "$receipt" command_sha256)" = "$command_sha" ] || return 1
  cases="$(ac_meta_get "$receipt" cases)"
  [ -n "$cases" ] || return 1
  return 0
}

qa_finish_gate() {
  # qa_finish_gate <run-dir> - the single pass-completion adjudicator. It reads
  # existing durable ledgers only and runs before teardown, outcome mutation,
  # and attestation publication.
  local rd="$1" outstanding bad_skips findings_bad f blockers duplicate
  local evidence_root id tier status cls conf grade evidence note auth repro boundary receipt web_missing
  local testplan testplan_sha testplan_status frozen_sha e2e_status harness_file harness_missing=""
  local serve_status runtime_sha
  local gate_total gate_passed gate_failed gate_unver gate_flaky gate_visuals

  outstanding="$(awk -F'\t' '$2 != "completed" && $2 != "skipped" {
    printf "%s%s=%s", (n++ ? ", " : ""), $1, $2
  }' "$rd/steps.tsv")"
  [ -z "$outstanding" ] \
    || ac_die "finish passed refused: non-terminal steps: $outstanding"

  bad_skips="$(awk -F'\t' '$2 == "skipped" && (NF < 4 || $4 == "" || $4 == "-") {
    printf "%s%s", (n++ ? ", " : ""), $1
  }' "$rd/steps.tsv")"
  [ -z "$bad_skips" ] \
    || ac_die "finish passed refused: skipped steps lack durable notes: $bad_skips"

  # A behavioral pass cannot skip its own test plan: the frozen hash only
  # exists on `testplan completed`, so name the skip as the cause instead of
  # a misleading missing-hash refusal.
  testplan_status="$(awk -F'\t' '$1 == "testplan" { print $2 }' "$rd/steps.tsv")"
  [ "$testplan_status" = completed ] \
    || ac_die "finish passed refused: a passing run requires a completed testplan step (testplan is ${testplan_status:-absent})"
  testplan="$(dirname "$(cmd_evidence_dir)")/testplan.md"
  frozen_sha="$(ac_meta_get "$rd/run.meta" testplan_sha256)"
  [ -n "$frozen_sha" ] \
    || ac_die "finish passed refused: completed testplan has no frozen test-plan hash"
  [ -f "$testplan" ] \
    || ac_die "finish passed refused: frozen test plan is missing: $testplan"
  testplan_sha="$(ac_config_sha256 "$testplan")"
  [ "$testplan_sha" = "$frozen_sha" ] \
    || ac_die "finish passed refused: test plan changed after completion (frozen=$frozen_sha current=$testplan_sha); record an authority-backed testplan-amend"

  # READY RUNTIME IS MANDATORY (header: RUNTIME BOOT RECEIPT). A skipped serve
  # step, or a boot receipt that is missing, hash-drifted, or whose process is
  # gone, means nothing was proven against a running deliverable.
  serve_status="$(awk -F'\t' '$1 == "serve" { print $2 }' "$rd/steps.tsv")"
  [ "$serve_status" = completed ] \
    || ac_die "finish passed refused: a passing run must boot the deliverable - the serve step is ${serve_status:-absent}, and 'step serve skipped' can never satisfy a pass. Record this round as failed|unverifiable|cancelled instead."
  qa_runtime_receipt_ok "$rd" \
    || ac_die "finish passed refused: $AC_QA_RECEIPT_ERROR"
  runtime_sha="$(ac_config_sha256 "$rd/runtime/receipt.env")"

  # Receipt qualification is conditional coverage evidence, not a global
  # baseline gate. ac_qa_coverage_validate below requires it only when the
  # frozen manifest selected a UT row.

  findings_bad=""
  for f in "$rd"/findings/*.json; do
    [ -e "$f" ] || continue
    if ! jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (.id | type == "string" and length > 0)
        and (.action | type == "string" and IN("fix", "ask-user", "no-op"))
      )' "$f" >/dev/null 2>&1; then
      ac_die "finish passed refused: invalid or unreadable findings data: $f"
    fi
    blockers="$(jq -r '
      .[]
      | select(
          .action == "fix"
          or (.action == "ask-user"
              and ((.decision | type) != "string"
                   or (.decision | gsub("^[[:space:]]+|[[:space:]]+$"; "") | length) == 0))
        )
      | "\(.id):\(.action)"' "$f")"
    if [ -n "$blockers" ]; then
      while IFS= read -r blockers; do
        [ -n "$blockers" ] || continue
        findings_bad="${findings_bad}${findings_bad:+, }$(basename "$f" .json)/$blockers"
      done <<EOF
$blockers
EOF
    fi
  done
  [ -z "$findings_bad" ] \
    || ac_die "finish passed refused: unresolved findings (step/id:action): $findings_bad"

  [ -s "$rd/cases.tsv" ] \
    || ac_die "finish passed refused: the case ledger is EMPTY - a run that recorded no case verified nothing"
  duplicate="$(awk -F'\t' 'seen[$1]++ { printf "%s%s", (n++ ? ", " : ""), $1 }' "$rd/cases.tsv")"
  [ -z "$duplicate" ] \
    || ac_die "finish passed refused: duplicate case ids: $duplicate"

  evidence_root="$(cmd_evidence_dir)"
  while IFS="$(printf '\t')" read -r id tier status cls conf grade evidence note auth repro boundary receipt; do
    [ -n "$id" ] || ac_die "finish passed refused: a case has an empty id"
    case " $CASE_TIERS " in *" $tier "*) ;; *)
      ac_die "finish passed refused: case $id has invalid tier '$tier' (the closed set is $CASE_TIERS)" ;;
    esac
    [ "$status" = pass ] \
      || ac_die "finish passed refused: case $id is $status, not pass"
    case "$grade" in A|B|C|D) ;; *)
      ac_die "finish passed refused: case $id has no valid grade (got '$grade')" ;;
    esac
    qa_evidence_path_ok "$evidence_root" "$evidence" \
      || ac_die "finish passed refused: case $id evidence is missing, broken, or outside the declared evidence root: $evidence"
    # Re-validated at the GATE, not just at record time: a hand-forged ledger
    # row is refused by exactly the check that admitted the honest one.
    { [ -n "$receipt" ] && [ "$receipt" != "-" ]; } \
      || ac_die "finish passed refused: case $id binds no client-boundary execution receipt - a tier label and a completed serve step are not proof"
    ac_qa_receipt_path_ok "$rd" "$id" "$receipt" \
      || ac_die "finish passed refused: case $id boundary receipt escapes this run's own boundary directory (canonical check refuses traversal, symlinks, and foreign paths): $receipt"
    # Re-hash the registered artifact: a receipt cannot outlive the evidence
    # it vouched for (tamper after publication refuses here).
    local gate_driver gate_expected gate_resolved
    gate_driver="$(ac_meta_get "$receipt" driver)"
    gate_expected="-"
    if [ "$gate_driver" = browser ]; then
      ac_qa_browser_manifest_ok "$rd" "$id" "$receipt" \
        || ac_die "finish passed refused: case $id - $AC_QA_RECEIPT_ERROR"
    else
      gate_resolved="$evidence"
      case "$gate_resolved" in /*) ;; *) gate_resolved="$evidence_root/$gate_resolved" ;; esac
      gate_expected="$(qa_path_sha "$gate_resolved")"
    fi
    ac_qa_boundary_receipt_validate "$receipt" "$id" "$tier" "$status" \
      "$(ac_meta_get "$rd/run.meta" target_sha)" \
      "$(ac_meta_get "$rd/run.meta" profile_sha256)" "$runtime_sha" \
      "$gate_expected" \
      || ac_die "finish passed refused: case $id - $AC_QA_RECEIPT_ERROR"
    [ "$boundary" = "$(ac_meta_get "$receipt" boundary)" ] \
      || ac_die "finish passed refused: case $id records boundary '$boundary' but its receipt says '$(ac_meta_get "$receipt" boundary)'"
    if [ "$tier" = web ]; then
      web_missing=1
      if visuals_live "$rd" | awk -F'\t' -v cid="$id" '$4 == cid { found=1 } END { exit !found }'; then
        web_missing=0
      fi
      [ "$web_missing" = 0 ] \
        || ac_die "finish passed refused: web case $id has no valid visual linked to that case id"
    fi
  done <"$rd/cases.tsv"

  ac_qa_coverage_validate "$rd" "$repo" \
    "$(ac_meta_get "$rd/run.meta" target_sha)" \
    || ac_die "finish passed refused: $AC_QA_MANIFEST_ERROR"

  if [ -d "$evidence_root/harness" ]; then
    while IFS= read -r harness_file; do
      [ -n "$harness_file" ] || continue
      if [ ! -f "$rd/regression-candidates.tsv" ] \
        || ! awk -F'\t' -v p="$harness_file" '$1 == p { found=1 } END { exit !found }' \
             "$rd/regression-candidates.tsv"; then
        harness_missing="${harness_missing}${harness_missing:+, }$harness_file"
      fi
    done < <(find "$evidence_root/harness" -type f \
      \( -perm -u+x -o -perm -g+x -o -perm -o+x \) -print | LC_ALL=C sort)
  fi
  [ -z "$harness_missing" ] \
    || ac_die "finish passed refused: task-local executable harnesses lack regression-promotion classification: $harness_missing"

  [ "$(visuals_valid "$rd")" -gt 0 ] \
    || ac_die "finish passed refused: no visual artifact on record - register one with 'ac-qa.sh visual <path>'"

  e2e_status="$(awk -F'\t' '$1 == "e2e" { print $2 }' "$rd/steps.tsv")"
  if [ "$e2e_status" = completed ]; then
    qa_e2e_receipt_ok "$rd" \
      || ac_die "finish passed refused: completed e2e step has no valid zero-exit execution receipt bound to the frozen command and refs; run 'ac-qa.sh cmd e2e --cases <ids>'"
  fi

  # Ledger-level pass invariants, still INSIDE the gate and therefore before
  # the runtime-gate receipt below and before any teardown: a run that will be
  # refused for an empty ledger or a missing visual must not mint an immutable
  # gate record or kill the process group on the way to the refusal.
  read -r gate_total gate_passed gate_failed gate_unver gate_flaky gate_visuals <<<"$(qa_counts "$rd")"
  [ "$gate_failed" = 0 ] \
    || ac_die "finish passed refused: $gate_failed failed case(s) in the ledger"
  [ "$gate_unver" = 0 ] \
    || ac_die "finish passed refused: $gate_unver unverifiable case(s) - finish unverifiable instead"
  [ "$gate_total" -gt 0 ] \
    || ac_die "finish passed refused: the case ledger is EMPTY - a run that recorded no case verified nothing"
  [ "$gate_visuals" -gt 0 ] \
    || ac_die "finish passed refused: no visual artifact on record - register one with 'ac-qa.sh visual <path>' (every run owes >=1 portable picture of what it proved, even an all-api/db run: screenshot the test report)"

  # FINAL LIVE-PROCESS CHECK, after every other passing invariant succeeded and
  # before any teardown: re-prove the process group and re-run the frozen health
  # probe, then publish the immutable gate receipt. Post-teardown reconciliation
  # validates THAT record - it never asks a normally terminated process to still
  # be alive - so publishing it is the last thing standing between the run and a
  # pass, and its failure refuses the pass.
  qa_runtime_identity "$rd"
  qa_publish_runtime_gate "$rd" "$runtime_sha" "$qa_id_source" "$qa_id_profile" "$qa_id_health"
}

qa_publish_runtime_gate() {
  # qa_publish_runtime_gate <run-dir> <runtime-receipt-sha> <source-sha>
  #                         <profile-sha> <health-cmd-sha>
  # The final gate record: process group still alive + the frozen health probe
  # green again, written immutably to <run>/runtime/gates/<ts>-<pid>.env with
  # <run>/runtime/gate.current pointing at it.
  local rd="$1" runtime_sha="$2" source_sha="$3" profile_sha="$4" health_sha="$5"
  local pgid c rc name tmp ptr_tmp
  pgid="$(ac_meta_get "$rd/runtime/receipt.env" process_group)"
  qa_pgid_alive "$pgid" \
    || ac_die "finish passed refused: the booted deliverable (process group $pgid) died before the final runtime gate - the evidence describes a runtime that is no longer the one under test"
  c="$(cmd_config qa.health 2>/dev/null || true)"
  [ -n "$c" ] \
    || ac_die "finish passed refused: the frozen qa.health probe is gone, so the final runtime gate cannot be re-run"
  local -a qenv
  minimal_env "$rd" qenv
  # Capped like cmd_health's poll (perl alarm; macOS ships no timeout(1)): a
  # wedged accept-but-never-respond server must fail the gate, not hang it.
  set +e
  ( cd "$repo" && env -i "${qenv[@]}" perl -e 'alarm 10; exec "sh", "-c", $ARGV[0]' "$c" ) >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" = 0 ] \
    || ac_die "finish passed refused: the final health probe exited $rc - the deliverable was not ready when the pass would have been minted"
  mkdir -p "$rd/runtime/gates"
  name="$(date +%Y%m%d-%H%M%S)-$$.env"
  tmp="$(mktemp "$rd/runtime/gates/.gate.XXXXXX")"
  {
    printf 'schema=agentcrew.qa-runtime-gate/v1\n'
    printf 'source_sha=%s\n' "$source_sha"
    printf 'profile_sha256=%s\n' "$profile_sha"
    printf 'runtime_receipt_sha256=%s\n' "$runtime_sha"
    printf 'process_group=%s\n' "$pgid"
    printf 'health_command_sha256=%s\n' "$health_sha"
    printf 'validated_at=%s\n' "$(ac_iso)"
    printf 'alive=1\n'
    printf 'health_exit_code=0\n'
  } >"$tmp"
  mv "$tmp" "$rd/runtime/gates/$name" \
    || { rm -f "$tmp"; ac_die "finish passed refused: the runtime gate receipt could not be published"; }
  ac_qa_runtime_gate_validate "$rd/runtime/gates/$name" \
    "$source_sha" "$profile_sha" "$runtime_sha" "$health_sha" "$pgid" \
    || ac_die "finish passed refused: the published runtime gate receipt is invalid: $AC_QA_RECEIPT_ERROR"
  ptr_tmp="$(mktemp "$rd/runtime/.gate-current.XXXXXX")"
  printf '%s\n' "$name" >"$ptr_tmp"
  mv "$ptr_tmp" "$rd/runtime/gate.current" \
    || { rm -f "$ptr_tmp"; ac_die "finish passed refused: the runtime gate pointer could not be published"; }
}

qa_publish_attestation() {
  # qa_publish_attestation <run-dir> <passed> <total> - stage, parse with the
  # merge gate's own v2 parser, then atomically rename into the marker path.
  local rd="$1" passed="$2" total="$3" main tsha scope app marker dir tmp
  local profile_key profile_sha config_sha qa_rule e2e_repo e2e_sha task
  main="$(ac_repo_root "$repo")" || main="$repo"
  tsha="$(ac_meta_get "$rd/run.meta" target_sha)"
  scope="$(ac_meta_get "$rd/run.meta" scope)"
  app="$(ac_meta_get "$rd/run.meta" app)"
  profile_key="$(ac_meta_get "$rd/run.meta" profile_key)"
  profile_sha="$(ac_meta_get "$rd/run.meta" profile_sha256)"
  config_sha="$(ac_meta_get "$rd/run.meta" config_sha256)"
  qa_rule="$(ac_meta_get "$rd/run.meta" qa_rule)"
  e2e_repo="$(ac_meta_get "$rd/run.meta" e2e_repo)"
  e2e_sha="$(ac_meta_get "$rd/run.meta" e2e_ref)"
  task="$(ac_meta_get "$rd/run.meta" task)"
  [ -n "$profile_key" ] && [ -n "$profile_sha" ] \
    || return 2
  marker="$tsha"
  [ -z "$scope" ] || marker="$tsha.$scope.$app"
  dir="$main/.crew/qa/passed"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.${marker}.XXXXXX")"
  {
    printf 'schema=agentcrew.qa-attestation/v2\n'
    printf 'outcome=passed\n'
    printf 'run=%s\n' "$(readlink "$current")"
    printf 'task=%s\n' "$task"
    printf 'completed_at=%s\n' "$(ac_iso)"
    printf 'source_sha=%s\n' "$tsha"
    printf 'profile_key=%s\n' "$profile_key"
    printf 'profile_sha256=%s\n' "$profile_sha"
    printf 'config_sha256=%s\n' "$config_sha"
    printf 'cases_passed=%s\n' "$passed"
    printf 'cases_total=%s\n' "$total"
    [ -z "$scope" ] || {
      printf 'scope=%s\n' "$scope"
      printf 'app=%s\n' "$app"
    }
    [ -z "$qa_rule" ] || printf 'qa_rule=%s\n' "$qa_rule"
    [ -z "$e2e_repo" ] || printf 'e2e_repo=%s\n' "$e2e_repo"
    [ -z "$e2e_sha" ] || printf 'e2e_sha=%s\n' "$e2e_sha"
  } >"$tmp"
  if ! ac_qa_attestation_parse "$tmp" "$tsha" "$scope" "$app"; then
    rm -f "$tmp"
    ac_die "passing attestation failed its own v2 validation: $AC_QA_ATTESTATION_ERROR"
  fi
  mv "$tmp" "$dir/$marker"
  return 0
}

repo_scope() {
  # The MAIN repo's basename, sanitized - a qa run inside a pool worktree
  # (.crew/worktrees/<n>) must scope to the project, not the numeric slot,
  # or the teardown/reap hooks (which run from the main repo) never match.
  sanitize_compose "$(basename "$(ac_repo_root "$repo")")"
}

compose_project() {
  # crew-qa-<main-repo>-<task> - the per-task scope every docker resource
  # lives under; also the reaper's key. Same derivation on up/down/reap.
  local rd task
  rd="$(run_dir)"
  task="$(sed -n 's/^task=//p' "$rd/run.meta" | head -n1)"
  printf 'crew-qa-%s-%s\n' "$(repo_scope)" "$(sanitize_compose "${task:-$(readlink "$current")}")"
}

compose_files() {
  # -f arguments: the shipped template, plus the linted project override.
  local rd override
  rd="$(run_dir)"
  [ -f "$assets_dir/compose.yaml" ] || ac_die "qa compose template missing: $assets_dir/compose.yaml"
  printf -- '-f\n%s\n' "$assets_dir/compose.yaml"
  override="$(cmd_config qa.mocks_compose 2>/dev/null || true)"
  if [ -n "$override" ]; then
    case "$override" in /*|*..*) ac_die "qa.mocks_compose must be repo-relative: $override" ;; esac
    [ -f "$repo/$override" ] || ac_die "qa.mocks_compose not found: $repo/$override"
    lint_override "$repo/$override"
    printf -- '-f\n%s\n' "$repo/$override"
  fi
}

lint_override() {
  # Fail closed on compose constructs that defeat task-scoped cleanup, touch
  # the host, or execute branch code at up-time. The override FILE lives on
  # the branch under test (only its PATH comes from trusted config), so this
  # lint is a real trust boundary: structural deny of the escape hatches -
  # image-with-stubs services are the only supported shape.
  local f="$1" bad
  bad="$(grep -nE \
    'container_name:|external:|privileged:|network_mode:|docker\.sock|build:|extends:|include:|env_file:|cap_add:|cap_drop:|devices:|(pid|ipc|userns_mode|uts):|type:[[:space:]]*"?bind|source:[[:space:]]*"?(/|\.\.)|^[[:space:]]*-[[:space:]]*"?(/|\.\.)[^:]*:' \
    "$f" || true)"
  [ -z "$bad" ] || ac_die "qa.mocks_compose fails the safety lint (captain must review):
$bad"
}

minimal_env() {
  # minimal_env <run-dir> <array-name> - fill <array-name> with the ONLY
  # environment serve/seed/e2e run under: baseline vars + the generated
  # ports.env. Ambient tokens/keys never cross this line.
  local rd="$1" __out="$2" line
  eval "$__out=()"
  eval "$__out+=(\"PATH=\$PATH\" \"HOME=\$HOME\" \"LANG=\${LANG:-C.UTF-8}\")"
  if [ -f "$rd/ports.env" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && eval "$__out+=(\"\$line\")"
    done <"$rd/ports.env"
  fi
  return 0
}

run_minimal() {
  # run_minimal <run-dir> <log-name> <command> - execute under the minimal
  # env from the repo root, teeing to the run log; returns the command's rc.
  local rd="$1" log="$2" c="$3" rc
  local -a qenv
  minimal_env "$rd" qenv
  set +e
  ( cd "$repo" && env -i "${qenv[@]}" sh -c "$c" ) 2>&1 | tee -a "$rd/logs/$log.log"
  rc="${PIPESTATUS[0]}"
  set -e
  printf '%s cmd=%s exit=%s\n' "$(ac_iso)" "$log" "$rc" >>"$rd/logs/run.log"
  return "$rc"
}

# --- start ---------------------------------------------------------------------

assert_target_checkout() {
  # TARGET-CHECKOUT BINDING (header-owned): prove the checkout the cases
  # exercise IS the requested target commit. Called BEFORE a run starts and
  # again BEFORE finish mints a pass, so a pass keyed by target_sha can never
  # attest a run that exercised a different commit or an ambiguous dirty tree.
  local tsha="$1" head dirty
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" \
    || ac_die "target-checkout: cannot resolve HEAD in $repo (qa must run against a definite checkout)"
  [ "$head" = "$tsha" ] || ac_die "target-checkout MISMATCH: --target resolves to $tsha but this worktree's HEAD is $head - the qa run would exercise the wrong code. Check out the target commit here (a fresh pool worktree detached at it) before starting."
  # Dirty TRACKED files mean the exercised code is no commit at all. Untracked
  # and the sanctioned .crew/ pool artifacts are ignored (-uno, the ac-sync
  # model). Project-local files have no special config exemption.
  # `|| true` made an ERRORED status read as an empty string = CLEAN, on the very
  # guard that binds a qa PASS to the commit it claims to have exercised: a status
  # that cannot be READ is not proof of a clean tree, so it refuses like the HEAD
  # resolve above rather than letting a run attest a pass against an unknown tree.
  dirty="$(git -C "$repo" status --porcelain -uno 2>/dev/null)" \
    || ac_die "target-checkout: cannot read the worktree state in $repo (failing closed - an unreadable status is not a clean tree)"
  [ -z "$dirty" ] || ac_die "target-checkout DIRTY: uncommitted changes to tracked files, so the exercised code is not commit $tsha:
$dirty
Commit or discard them before a qa run (untracked and .crew/ artifacts are ignored)."
}

qa_selection_precedence() {
  # qa_selection_precedence <scopes-tsv-file> <config-yaml-file> <scope> <app>
  # <refuse-fn> - THE precedence chain (header block owns the contract):
  # mode detection, the closed scope list, then app membership. Shared by
  # cmd_start's qa_validate_selection (always fatal) and cmd_agent's live
  # pre-run profile check (F27 - the two used to reimplement this with
  # different wording and a different refusal channel). Every violation
  # reaches <refuse-fn> as `<refuse-fn> <class> "<message>"`, where <class>
  # is caller-error (a bad CLI argument, fatal in every caller today),
  # conflict (the two durable sources disagree), or needs-profile (a
  # declared scope with no config block yet) - the split cmd_agent's channel
  # already made before this dedup. <refuse-fn> is assumed to end the call
  # (ac_die or qa_profile_return both exit); nothing here ever falls back or
  # infers a value, because a refusal that helpfully fell back would be the
  # silent wrong-profile green this exists to prevent. Stops after the F3
  # scope-block check - F6 (the app's own config block) stays with
  # qa_validate_selection alone, because cmd_agent has no equivalent check:
  # its own serve/health/seed completeness check already covers an absent
  # apps.<app> block, just with different wording.
  local map="$1" cfg="$2" scope="$3" app="$4" refuse="$5"
  local declared yaml_scopes yaml_has=0 members undeclared k
  declared="$(cut -f1 "$map" | tr '\n' ' ')"; declared="${declared% }"
  # PRESENCE for the mode test, CHILDREN for F9. An empty `qa.scopes:` block is
  # the ordinary half-authored state - the key lands before the first block
  # under it - and reading it as ABSENT drops the project to FLAT and runs the
  # stale single-app profile, which is exactly the hole two-sided detection was
  # introduced to close.
  ac_yaml_has "$cfg" qa.scopes && yaml_has=1
  yaml_scopes="$(ac_yaml_keys "$cfg" qa.scopes | tr '\n' ' ')"; yaml_scopes="${yaml_scopes% }"

  # step 0 - mode detection, two-sided.
  if [ -z "$declared" ] && [ "$yaml_has" = 0 ]; then
    # step 0b - FLAT. A caller who thinks they are selecting a profile must
    # never be silently ignored, and this is NOT F8: the project declares no
    # scopes at all, which is a different true thing.
    if [ -n "$scope" ] || [ -n "$app" ]; then
      "$refuse" caller-error "this project declares no scopes, so --scope/--app select nothing (got${scope:+ --scope $scope}${app:+ --app $app}). A scoped project needs BOTH a qa.scopes block in its fleet-home config AND scope entries in its repo-knowledge record; this one has neither. Drop the selectors, or declare the scopes first."
    fi
    return 0
  fi
  if [ -z "$declared" ] || [ "$yaml_has" = 0 ]; then
    # F8 - exactly one side declares scopes, and on nothing else.
    if [ -z "$declared" ]; then
      "$refuse" conflict "F8 MODE MISMATCH: the fleet-home config declares scopes (${yaml_scopes:-the qa.scopes block is present but still EMPTY}) but the repo-knowledge record declares NONE, so this project is neither cleanly flat nor cleanly scoped. The record is the closed list of which scopes exist; declare them there (bin/ac-know.sh scope-proposal), or remove the qa.scopes block."
    fi
    "$refuse" conflict "F8 MODE MISMATCH: the repo-knowledge record declares scopes ($declared) but the fleet-home config carries no qa.scopes block, so this project is neither cleanly flat nor cleanly scoped. The config says how to RUN a scope; add the block (ac-qa.sh config-proposal), or retire the scope entries."
  fi

  # SCOPED from here down.
  # step 1 - F9, the closed list, over the WHOLE file rather than the selected
  # scope alone. This is what makes the closed list actually closed: the yaml
  # can never widen it.
  undeclared=""
  for k in $yaml_scopes; do
    case " $declared " in *" $k "*) ;; *) undeclared="$undeclared $k" ;; esac
  done
  [ -z "$undeclared" ] || "$refuse" conflict "F9 UNDECLARED SCOPE BLOCK: the config carries qa.scopes for${undeclared}, which the repo-knowledge record does not declare. Declared scopes: $declared. The yaml says how to run a scope; it can never add one."

  # steps 2-5 - answered from the MAP alone, before anything is asked of the
  # yaml, so "that scope does not exist" never arrives as "that scope has no
  # config block".
  [ -n "$scope" ] || "$refuse" caller-error "F1: this project declares scopes, so every run must name one. Declared scopes: $declared"
  case " $declared " in
    *" $scope "*) ;;
    *) "$refuse" conflict "F2: '$scope' is not a declared scope. Declared scopes: $declared" ;;
  esac
  members="$(awk -F'\t' -v s="$scope" '$1 == s { print $2 }' "$map")"
  # NO member-count branch, deliberately: a one-member scope is not special.
  # Inferring the app because a scope happens to have one member is still
  # silent inference, merely the currently-harmless kind - add a second member
  # and it starts choosing.
  [ -n "$app" ] || "$refuse" caller-error "F4: scope '$scope' needs an app named too. Members of $scope: $members"
  case ",$members," in
    *",$app,"*) ;;
    *) "$refuse" conflict "F5: '$app' is not a member of scope '$scope'. Members of $scope: $members" ;;
  esac

  # step 6 - now the yaml, closed list side. F6 (the app's own config block)
  # is NOT here - see the function header.
  [ -n "$(ac_yaml_keys "$cfg" "qa.scopes.$scope")" ] \
    || "$refuse" needs-profile "F3: scope '$scope' is declared but the fleet-home config carries no qa.scopes.$scope block - it has not been configured yet."
  return 0
}

_qa_selection_die_hard() {
  # <class> <message> - qa_validate_selection's channel: unconditionally
  # fatal regardless of class, matching this chain's original contract.
  ac_die "$2"
}

qa_validate_selection() {
  # qa_validate_selection <run-dir> <scope> <app> <unused> - THE precedence chain
  # (header block owns the contract). Runs once, inside cmd_start, on the two
  # FROZEN sources. Every refusal NAMES its candidates, and none of them ever
  # prints or reaches a repo-level value: a refusal that helpfully fell back
  # would be the silent wrong-profile green this exists to prevent. Shares its
  # steps with cmd_agent's live pre-run check via qa_selection_precedence
  # (F27); this wrapper stays unconditionally fatal, as it always was.
  local rd="$1" scope="$2" app="$3"
  qa_selection_precedence "$rd/scopes.tsv" "$rd/config.yaml" "$scope" "$app" _qa_selection_die_hard
  # F6 - the app's own config block. SCOPED-only (qa_selection_precedence
  # returns early for FLAT, where scope is empty); identity still requires
  # it even though individual mechanics are validated only when their
  # command runs, because start has no skip grammar.
  [ -z "$scope" ] && return 0
  [ -n "$(ac_yaml_keys "$rd/config.yaml" "qa.scopes.$scope.apps.$app")" ] \
    || ac_die "F6: app '$app' has no config block (qa.scopes.$scope.apps.$app)."
  return 0
}

qa_runtime_bundle_validate() {
  # qa_runtime_bundle_validate <runtime-dir> <source-sha> <scope> <app>
  # Adds volatile runtime validation to the shared immutable-bundle validator.
  local runtime="$1" source_sha="$2" scope="$3" app="$4"
  local profile="$runtime/profile.json" runtime_json="$runtime/runtime.json"
  local profile_scope profile_app expected_key worktree e2e_ref
  ac_qa_bundle_validate "$profile" "$source_sha" \
    || { ac_warn "qa runtime bundle invalid: $AC_QA_BUNDLE_ERROR"; return 1; }
  [ -f "$runtime_json" ] && [ ! -L "$runtime_json" ] \
    || { ac_warn "qa runtime bundle has no regular runtime.json"; return 1; }
  jq -e '
    type == "object"
    and .schema == "agentcrew.qa-runtime/v1"
    and (.e2e_worktree | type == "string")
    and ((keys | sort) == ["e2e_worktree","schema"])
  ' "$runtime_json" >/dev/null 2>&1 \
    || { ac_warn "qa runtime.json has an invalid schema or unknown keys"; return 1; }
  profile_scope="$(jq -r '.target.scope // ""' "$profile")"
  profile_app="$(jq -r '.target.app // ""' "$profile")"
  [ "$profile_scope" = "$scope" ] && [ "$profile_app" = "$app" ] \
    || { ac_warn "qa runtime bundle selector mismatch (profile=$profile_scope/$profile_app invocation=$scope/$app)"; return 1; }
  expected_key="$(jq -r '.project' "$profile")"
  [ -z "$scope" ] || expected_key="$expected_key/$scope/$app"
  [ "$(jq -r '.profile_key' "$profile")" = "$expected_key" ] \
    || { ac_warn "qa runtime bundle profile_key does not match project/scope/app"; return 1; }
  worktree="$(jq -r '.e2e_worktree' "$runtime_json")"
  e2e_ref="$(jq -r '.e2e.ref // ""' "$profile")"
  if [ -n "$e2e_ref" ]; then
    [ -d "$worktree" ] \
      && [ "$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)" = "$e2e_ref" ] \
      || { ac_warn "qa runtime E2E worktree is missing or off the frozen E2E ref"; return 1; }
  elif [ -n "$worktree" ]; then
    ac_warn "qa runtime names an E2E worktree but the frozen profile has no E2E ref"
    return 1
  fi
  return 0
}

cmd_start() {
  local target="" task="" evidence="" store="" home="" s target_sha
  local scope="" app="" scope_seen=0 app_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --skip)
        ac_die "start --skip was removed: record the durable reason after start with 'ac-qa.sh step <name> skipped --note <reason>'"
        ;;
      --evidence) evidence="$2"; shift 2 ;;
      --store) store="$2"; shift 2 ;;
      --home) home="$2"; shift 2 ;;
      # A REPEATED selector refuses, identical repeats included. The loop is
      # last-wins by construction, and silently taking the last value is the
      # very default this whole mechanism exists to kill; refusing the
      # identical repeat too removes the "is this the same value?" comparison
      # entirely, which is the branch a conflicting-value bug would hide in.
      --scope) [ "$scope_seen" = 0 ] || ac_die "--scope given twice ('$scope' then '$2') - name one scope, or the run silently takes the last"
               scope="$2"; scope_seen=1; shift 2 ;;
      --app) [ "$app_seen" = 0 ] || ac_die "--app given twice ('$app' then '$2') - name one app, or the run silently takes the last"
             app="$2"; app_seen=1; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$target" ] || ac_die "--target is required (branch/ref/commit under verification)"
  # A RELATIVE --store would resolve against this pane's cwd - the disposable
  # pool worktree - so the store would evaporate with the lease while every
  # path printed still looked right. Refuse before the run dir is minted.
  case "$store" in
    ""|/*) ;;
    *) ac_die "--store must be an ABSOLUTE path (got '$store'): qa runs from a disposable pool worktree, so a relative store evaporates with the lease (see KNOWLEDGE STORE in this script's header). Copy the absolute path your qa brief names:
  ac-qa.sh start --target $target${task:+ --task $task} --store <abs-store-dir>" ;;
  esac
  git -C "$repo" rev-parse --verify --quiet "$target^{commit}" >/dev/null \
    || ac_die "target does not resolve to a commit: $target"
  target_sha="$(git -C "$repo" rev-parse "$target^{commit}")"
  # Prove the checkout IS the target BEFORE any run dir is minted, so a refusal
  # leaves nothing on disk for ac_qa_gate_ok to ever trust.
  assert_target_checkout "$target_sha"
  local id rd status home_cfg config_sha qa_home home_named=1
  local runtime_dir="$qdir/profile-runtime" profiled=0
  # THE single home resolution of this run (header). Guards fire here, before
  # the run dir is minted, so a refusal leaves nothing on disk.
  qa_home="$(ac_home_resolve "$home" "$repo")"
  [ -n "$qa_home" ] || { qa_home="$(ac_root)"; home_named=0; }
  id="$(date +%Y%m%d-%H%M%S)-$$"
  rd="$qdir/$id"
  mkdir -p "$rd/logs" "$rd/findings"
  # Exclude .crew/ via info/exclude. DEGRADE as ONE unit: all this buys is
  # .crew/ staying out of `git status`, so an unresolvable common dir, an
  # uncreatable info/, or an unwritable exclude warns and continues - unguarded,
  # any of the three killed a whole qa run over an ignore line, AFTER the run
  # dir above was already minted. The && CHAIN is what short-circuits, NOT the
  # subshell: errexit is suppressed inside any non-final command of an AND-OR
  # list and the subshell INHERITS that suppression, so a bare sequence runs on
  # past the first failure - with an empty $common that means addressing
  # /info/exclude at FILESYSTEM ROOT, which on a writable-root box (root,
  # container, CI image) SUCCEEDS and reports 0, so the warning never fires.
  # Mirrors ac-ship.sh ensure_crew_excluded; the target-checkout binding above
  # stays fail-closed either way, so a degraded exclude buys no dirty tree.
  ( common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" \
    && mkdir -p "$common/info" \
    && { grep -qx '\.crew/' "$common/info/exclude" 2>/dev/null \
         || printf '.crew/\n' >>"$common/info/exclude"; } ) \
    || ac_warn "could not add .crew/ to info/exclude - it stays visible in git status"

  # A sanctioned verifier hands off the complete bundle at one fixed path.
  # Validate before consuming it and never reread live fleet sources.
  if [ -d "$runtime_dir" ]; then
    qa_runtime_bundle_validate "$runtime_dir" "$target_sha" "$scope" "$app" \
      || { rm -rf "$rd"; ac_die "qa refuses the invalid frozen runtime bundle at $runtime_dir"; }
    mv "$runtime_dir" "$rd/profile" \
      || { rm -rf "$rd"; ac_die "qa could not consume the frozen runtime bundle"; }
    cp "$rd/profile/config.yaml" "$rd/config.yaml"
    cp "$rd/profile/scopes.tsv" "$rd/scopes.tsv"
    home_cfg="profile/config.yaml"
    profiled=1
  else
    # Unprofiled direct diagnostics retain the live snapshot path.
    if home_cfg="$(AC_HOME="$qa_home" ac_project_config_file "$repo")"; then
      cp "$home_cfg" "$rd/config.yaml"
    else
      : >"$rd/config.yaml"
    fi
    AC_HOME="$qa_home" ac_knowledge_scopes "$repo" >"$rd/scopes.tsv" \
      || { rm -rf "$rd"; ac_die "qa refuses to start: the scope map is ambiguous (see above)"; }
    [ "$home_named" = 1 ] || printf 'notice: no fleet home named (--home) and none in the environment - using %s\n' "$qa_home" >&2
  fi
  config_sha="$(ac_config_sha256 "$rd/config.yaml")"

  # The precedence chain, on the FROZEN pair and before run.meta exists, so a
  # refusal leaves nothing on disk for the merge gate to ever trust.
  # In a SUBSHELL so the refusal's own exit cannot skip the cleanup: every
  # refusal in the chain is an ac_die, which would otherwise end the script
  # with a half-minted run dir on disk.
  ( qa_validate_selection "$rd" "$scope" "$app" "" ) || { rm -rf "$rd"; exit 1; }

  # Read the consumed runtime bundle that ac-verify published before the pane
  # ran. Profile identity stays in profile.json and volatile E2E allocation
  # stays in runtime.json; a plain unprofiled start has neither.
  local e2e_worktree="" e2e_repo="" e2e_ref="" profile_key="" profile_sha256="" qa_rule=""
  local qa_harness="" qa_model="" qa_effort="" qa_when="" qa_why="" dispatch_sha256=""
  if [ "$profiled" = 1 ]; then
    e2e_worktree="$(jq -r '.e2e_worktree' "$rd/profile/runtime.json")"
    e2e_repo="$(jq -r '.e2e.repo // ""' "$rd/profile/profile.json")"
    e2e_ref="$(jq -r '.e2e.ref // ""' "$rd/profile/profile.json")"
    profile_key="$(jq -r '.profile_key' "$rd/profile/profile.json")"
    profile_sha256="$(jq -r '.profile_sha256' "$rd/profile/profile.json")"
    qa_rule="$(jq -r '.routing.rule // ""' "$rd/profile/profile.json")"
    qa_harness="$(jq -r '.routing.use.harness // ""' "$rd/profile/profile.json")"
    qa_model="$(jq -r '.routing.use.model // ""' "$rd/profile/profile.json")"
    qa_effort="$(jq -r '.routing.use.effort // ""' "$rd/profile/profile.json")"
    qa_when="$(jq -r '.routing.when // ""' "$rd/profile/profile.json" | tr '\t\r\n' '   ')"
    qa_why="$(jq -r '.routing.why // ""' "$rd/profile/profile.json" | tr '\t\r\n' '   ')"
    dispatch_sha256="$(jq -r '.routing.dispatch_sha256 // ""' "$rd/profile/profile.json")"
    store="$rd/profile/store"
  fi
  {
    printf 'target=%s\n' "$target"
    printf 'target_sha=%s\n' "$target_sha"
    printf 'task=%s\n' "$task"
    printf 'evidence=%s\n' "$evidence"
    printf 'store=%s\n' "$store"
    # The run's PROFILE dimension. Empty on a flat project, and read back by
    # every consumer rather than re-derived: a field nothing reads is
    # decoration, not a record.
    printf 'scope=%s\n' "$scope"
    printf 'app=%s\n' "$app"
    # The E2E (dual-ref) dimension + frozen profile identity - empty unless a
    # separate-E2E profile drove this run. finish binds these into the pass
    # attestation; the e2e step runs from the recorded worktree.
    printf 'e2e_worktree=%s\n' "$e2e_worktree"
    printf 'e2e_repo=%s\n' "$e2e_repo"
    printf 'e2e_ref=%s\n' "$e2e_ref"
    printf 'profile_key=%s\n' "$profile_key"
    printf 'profile_sha256=%s\n' "$profile_sha256"
    printf 'qa_rule=%s\n' "$qa_rule"
    printf 'qa_harness=%s\n' "$qa_harness"
    printf 'qa_model=%s\n' "$qa_model"
    printf 'qa_effort=%s\n' "$qa_effort"
    printf 'qa_when=%s\n' "$qa_when"
    printf 'qa_why=%s\n' "$qa_why"
    printf 'dispatch_sha256=%s\n' "$dispatch_sha256"
    printf 'config_source=%s\n' "${home_cfg:-none}"
    printf 'config_sha256=%s\n' "$config_sha"
    printf 'created_at=%s\n' "$(ac_iso)"
    printf 'outcome=running\n'
  } >"$rd/run.meta"
  : >"$rd/cases.tsv"
  : >"$rd/visuals.tsv"
  for s in $STEPS; do
    status=pending
    printf '%s\t%s\t0\t-\n' "$s" "$status"
  done >"$rd/steps.tsv"
  ln -sfn "$id" "$current"
  watch_open "$rd" "$task"
  printf 'started qa run %s target=%s%s\n' "$id" "$target" "${task:+ task=$task}"
}

# --- steps / findings / cases --------------------------------------------------

cmd_step() {
  require_run
  local name="${1:-}" status="${2:-}" note="" rd tmp testplan testplan_sha=""
  local testplan_manifest_tmp="" testplan_manifest_sha=""
  shift 2 2>/dev/null || ac_die "usage: ac-qa.sh step <name> <status> [--note <text>]"
  if [ $# -gt 0 ]; then
    [ "$#" = 2 ] && [ "$1" = "--note" ] \
      || ac_die "usage: ac-qa.sh step <name> <status> [--note <text>]"
    note="$2"
  fi
  case " $STEPS " in *" $name "*) ;; *) ac_die "unknown step: $name" ;; esac
  case " $STATUSES " in *" $status "*) ;; *) ac_die "unknown status: $status" ;; esac
  # OWNED TRANSITIONS (QA boundary policy): a step whose terminal state is a
  # PROOF is transitioned only by the command that publishes that proof. A
  # hand-typed `step baseline completed` would record a check nobody ran, and a
  # hand-typed `step serve completed` would claim a boot with no runtime
  # receipt behind it - the two states the pass gate reads.
  if [ "$name" = baseline ] && [ "$step_owner" != baseline ]; then
    case "$status" in completed|skipped)
      ac_die "step baseline $status is refused: 'ac-qa.sh baseline' owns this transition - it validates the frozen exact-SHA ship test receipt and records the result. QA never re-runs the unit suite (captain 2026-07-25)." ;;
    esac
  fi
  if [ "$name" = serve ] && [ "$status" = completed ] && [ "$step_owner" != serve ]; then
    ac_die "step serve completed is refused: 'ac-qa.sh serve' owns this transition - it boots the frozen qa.serve command and records the launch the runtime receipt binds. 'step serve skipped --note <why>' stays valid and can never satisfy a pass."
  fi
  note="$(printf '%s' "$note" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//')"
  if [ "$status" = skipped ] && [ -z "$note" ]; then
    ac_die "step $name skipped requires --note '<reason>' so the non-applicability decision is durable"
  fi
  [ -n "$note" ] || note="-"
  rd="$(run_dir)"
  if [ "$name" = testplan ] && [ "$status" = completed ]; then
    testplan="$(qa_testplan_path)"
    [ -f "$testplan" ] \
      || ac_die "testplan completed requires the durable plan beside the evidence directory: $testplan"
    testplan_sha="$(ac_config_sha256 "$testplan")"
    testplan_manifest_tmp="$(mktemp "$rd/.testplan-manifest.XXXXXX")"
    if ! ac_qa_testplan_manifest_render "$repo" \
        "$(ac_meta_get "$rd/run.meta" target_sha)" "$testplan" \
        >"$testplan_manifest_tmp"; then
      rm -f "$testplan_manifest_tmp"
      ac_die "testplan completed refused: $AC_QA_MANIFEST_ERROR"
    fi
    if ! qa_testplan_ut_rows_ok "$rd" "$testplan_manifest_tmp"; then
      rm -f "$testplan_manifest_tmp"
      ac_die "testplan completed refused: $AC_QA_MANIFEST_ERROR"
    fi
    testplan_manifest_sha="$(ac_config_sha256 "$testplan_manifest_tmp")"
    local previous_testplan_sha
    previous_testplan_sha="$(ac_meta_get "$rd/run.meta" testplan_sha256)"
    if [ -n "$previous_testplan_sha" ] && [ "$previous_testplan_sha" != "$testplan_sha" ]; then
      rm -f "$testplan_manifest_tmp"
      ac_die "testplan was already frozen at $previous_testplan_sha and now hashes to $testplan_sha; record the authority-backed transition with 'ac-qa.sh testplan-amend'"
    fi
  fi
  # Visual-evidence gate, ERGONOMICS not enforcement (finish is the real gate,
  # and `evidence skipped --note <why>` sails past this exactly as `step review
  # skipped` bypasses ac-ship.sh's review.agent gate). It fires HERE because
  # cmd_finish tears down serve + infra before its guards run: refusing there
  # tells the agent to go screenshot a system that is already gone.
  if [ "$name" = evidence ] && [ "$status" = completed ]; then
    [ "$(visuals_valid "$rd")" -gt 0 ] \
      || ac_die "evidence step has no visual artifact: register one with 'ac-qa.sh visual <path>' while the stack is still up, or 'step evidence skipped --note <why>' when the change has no visual surface"
  fi
  tmp="$(mktemp)"
  # ABORT, never fall through: the ledger IS the state machine's truth, and
  # `awk >tmp && mv` is a non-final AND-OR element, which errexit EXEMPTS (and
  # pipefail does not cover - it is not a pipeline). Unguarded, a failed read or
  # a failed swap left the ledger unchanged, leaked the staged temp file, and
  # still printed `<step> -> <status>`. Mirrors ac-ship.sh cmd_step.
  # The note travels via ENVIRON, never `awk -v`: -v assignment re-interprets
  # C escapes, so a literal `\t`/`\n` in the note would re-become the very
  # control characters the scrub above removed (mirrors cmd_visual).
  if ! { AC_QA_STEP_NOTE="$note" awk -F'\t' -v OFS='\t' -v s="$name" -v st="$status" '
      $1 == s {
        $2 = st
        if (st == "fixing") $3 = ($3 + 0) + 1
        $4 = ENVIRON["AC_QA_STEP_NOTE"]
      }
      NF < 4 { $4 = "-" }
      { print }' "$rd/steps.tsv" >"$tmp" && mv "$tmp" "$rd/steps.tsv"; }; then
    rm -f "$tmp" "$testplan_manifest_tmp"
    ac_die "step: could not update the steps ledger ($rd/steps.tsv) - failing closed"
  fi
  if [ -n "$testplan_sha" ]; then
    mv "$testplan_manifest_tmp" "$rd/testplan-manifest.json" \
      || { rm -f "$testplan_manifest_tmp"; ac_die "testplan completed could not publish its frozen manifest"; }
    ac_meta_set "$rd/run.meta" testplan_sha256 "$testplan_sha"
    ac_meta_set "$rd/run.meta" testplan_manifest_sha256 "$testplan_manifest_sha"
    ac_meta_set "$rd/run.meta" testplan_path "$testplan"
  fi
  printf '%s step=%s status=%s%s\n' "$(ac_iso)" "$name" "$status" "$([ "$note" != "-" ] && printf ' note=%s' "$note")" >>"$rd/logs/run.log"
  # Re-ensure the dashboard when a step goes active (a run reopened under
  # hold-and-fix, or one that lost its watch pane). Idempotent, never fails.
  case "$status" in
    running|fixing) watch_open "$rd" "$(sed -n 's/^task=//p' "$rd/run.meta" | head -n1)" ;;
  esac
  printf '%s -> %s\n' "$name" "$status"
}

cmd_case() {
  require_run
  local id="${1:-}" status="${2:-}" tier="" cls="-" conf="-" grade="-" ev="-" note="-" auth="-" repro="-" rd tmp
  local boundary="-" receipt="-"
  shift 2 2>/dev/null || ac_die "usage: ac-qa.sh case <id> <pass|fail|unverifiable> --tier <t> [...]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) tier="$2"; shift 2 ;;
      --classification) cls="$2"; shift 2 ;;
      --confidence) conf="$2"; shift 2 ;;
      --grade) grade="$2"; shift 2 ;;
      --evidence) ev="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      --authority) auth="$2"; shift 2 ;;
      --repro) repro="$2"; shift 2 ;;
      --boundary) boundary="$2"; shift 2 ;;
      --receipt) receipt="$2"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  case "$id" in ''|.|*..*|*[!a-zA-Z0-9_.-]*) ac_die "case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '$id'" ;; esac
  case " $CASE_STATUSES " in *" $status "*) ;; *) ac_die "unknown case status: $status" ;; esac
  # UT is a COVERAGE rung, never a QA execution tier: the frozen manifest maps
  # it to ship's exact-SHA receipt plus a repository test reference. QA records
  # only live client/integration boundary cases here.
  case " $CASE_TIERS " in *" $tier "*) ;; *) ac_die "--tier must be one of: $CASE_TIERS" ;; esac
  case "$cls" in -|defect|flaky|test-maintenance|environment) ;; *) ac_die "bad --classification: $cls" ;; esac
  case "$grade" in -|A|B|C|D) ;; *) ac_die "--grade must be A|B|C|D (evidence ladder)" ;; esac
  # Reject BEFORE the ledger is touched, same shape as visual_register's own
  # path check: both characters break the tsv, and a case row is never
  # scrubbed like --note/--authority/--repro because $ev is a path that must
  # keep resolving to real evidence, not lossily rewritten.
  case "$ev" in
    -) ;;
    *$'\t'*) ac_die "--evidence must not contain a tab: $ev" ;;
    *$'\n'*) ac_die "--evidence must not contain a newline: $ev" ;;
  esac
  # FINDING AUTHORITY (header-owned): asserting a DEFECT is the act that turns a
  # statement into a fixer's work, so it is the only act bound here - a park, a
  # pass, and every non-defect classification are untouched.
  if [ "$status" = fail ] && [ "$cls" = defect ]; then
    [ "$auth" != "-" ] && [ -n "${auth//[[:space:]]/}" ] \
      || ac_die "case $id fail --classification defect needs --authority <file:line | URL | 'captain <date>'> - WHO states the expected behaviour, and WHERE. With nothing citable this is unverifiable --note '<why>', never a defect: ac-qa.sh case $id unverifiable --tier $tier --note '<why it cannot be verified>'"
    [ "$repro" != "-" ] && [ -n "$repro" ] \
      || ac_die "case $id fail --classification defect needs --repro <path to an executable repro-$id.sh declaring '# DISPUTED:' and '# HELD-CONSTANT:'>"
    [ -f "$repro" ] || ac_die "--repro $repro: no such file"
    [ -x "$repro" ] || ac_die "--repro $repro: not executable"
    grep -qE '^# DISPUTED:[[:space:]]*[^[:space:]]' "$repro" \
      || ac_die "--repro $repro: missing or empty '# DISPUTED: <the one variable under dispute>' header"
    grep -qE '^# HELD-CONSTANT:[[:space:]]*[^[:space:]]' "$repro" \
      || ac_die "--repro $repro: missing or empty '# HELD-CONSTANT: <everything the two legs share, named>' header"
  fi
  rd="$(run_dir)"
  qa_testplan_ready "$rd" \
    || ac_die "case $id refused: $AC_QA_MANIFEST_ERROR"
  # CLIENT-BOUNDARY EXECUTION RECEIPT (header-owned): a terminal behavioral row
  # binds one immutable receipt proving an approved driver stimulated the BOOTED
  # deliverable from outside its process. An `unverifiable` row may omit it -
  # the missing boundary is frequently the very reason it is unverifiable.
  if [ "$status" = pass ] || [ "$status" = fail ]; then
    { [ "$boundary" != "-" ] && [ -n "$boundary" ]; } \
      || ac_die "case $id $status needs --boundary <${BOUNDARIES// /|}>: a behavioral result names the client boundary it was stimulated through. A case with no reachable boundary is 'unverifiable' with an ask-user finding naming the missing boundary, never an in-process substitute."
    { [ "$receipt" != "-" ] && [ -n "$receipt" ]; } \
      || ac_die "case $id $status needs --receipt <path>: drive it with 'ac-qa.sh boundary-run' (or register a browser/e2e boundary with 'ac-qa.sh boundary-register') and pass the receipt it prints. A tier label and a completed serve step are not proof."
  fi
  if [ "$receipt" != "-" ] && [ -n "$receipt" ]; then
    ac_qa_receipt_path_ok "$rd" "$id" "$receipt" \
      || ac_die "case $id: --receipt must be a regular file this run published under $rd/boundaries/$id/ - traversal, symlinks, and foreign paths are refused (got '$receipt')"
    # Re-hash the registered artifact so a receipt cannot outlive the evidence
    # it vouched for: command/e2e receipts hash the evidence path, browser
    # receipts re-prove their transcript+visual manifest.
    local rec_driver rec_expected
    rec_driver="$(ac_meta_get "$receipt" driver)"
    rec_expected="-"
    if [ "$rec_driver" = browser ]; then
      ac_qa_browser_manifest_ok "$rd" "$id" "$receipt" \
        || ac_die "case $id: $AC_QA_RECEIPT_ERROR"
    elif [ "$ev" != "-" ] && [ -e "$ev" ]; then
      rec_expected="$(qa_path_sha "$ev")"
    fi
    ac_qa_boundary_receipt_validate "$receipt" "$id" "$tier" "$status" \
      "$(ac_meta_get "$rd/run.meta" target_sha)" \
      "$(ac_meta_get "$rd/run.meta" profile_sha256)" \
      "$(ac_config_sha256 "$rd/runtime/receipt.env" 2>/dev/null || printf '-')" \
      "$rec_expected" \
      || ac_die "case $id: $AC_QA_RECEIPT_ERROR"
    [ "$boundary" = "-" ] || [ "$boundary" = "$(ac_meta_get "$receipt" boundary)" ] \
      || ac_die "case $id: --boundary $boundary contradicts the receipt's boundary $(ac_meta_get "$receipt" boundary)"
    [ "$boundary" != "-" ] || boundary="$(ac_meta_get "$receipt" boundary)"
  fi
  # The park's REASON field (INFRA CONTAINMENT): a case that cannot be verified -
  # a service the declaration does not name, docker absent - parks WITH why.
  # Scrubbed like cmd_visual's note and for the same reason: the ledger rewrite
  # below must never run on a value that would break the row it rewrites.
  note="$(printf '%s' "$note" | tr '\t\n' '  ')"
  # Scrubbed AFTER the -f/-x checks resolved the real path, for the same reason
  # the note is: the ledger rewrite below must never run on a value that would
  # break the row it rewrites.
  auth="$(printf '%s' "$auth" | tr '\t\n' '  ')"
  repro="$(printf '%s' "$repro" | tr '\t\n' '  ')"
  # Locked read-modify-write: supervised case subprocesses may finish
  # concurrently inside the one QA pane. Without the lock, two parallel writers
  # lose rows. Last write per case id wins (re-runs update the row).
  ac_lock_acquire "$rd/.cases.lock" 30 || ac_die "cases ledger lock timeout"
  tmp="$(mktemp)"
  # A failed rewrite must DIE with the ledger intact - swallowing it with
  # `|| true` would leave $tmp holding only the new row and mv would destroy
  # every case on record, the same shape visual_register's ledger rewrite dies on.
  if ! awk -F'\t' -v id="$id" '$1 != id' "$rd/cases.tsv" >"$tmp"; then
    rm -f "$tmp"
    ac_lock_release "$rd/.cases.lock"
    ac_die "cases ledger rewrite failed for: $id (the ledger is unchanged)"
  fi
  # authority + repro are APPENDED ($9, $10) and boundary + boundary_receipt
  # after them ($11, $12), for the same reason: every existing awk -F'\t' index
  # keeps pointing at the field it always did, and a pre-change row renders
  # with "-" by the same mechanism --note already relies on.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$tier" "$status" "$cls" "$conf" "$grade" "$ev" "$note" "$auth" "$repro" \
    "$boundary" "$receipt" >>"$tmp"
  mv "$tmp" "$rd/cases.tsv"
  ac_lock_release "$rd/.cases.lock"
  printf 'case %s: %s (tier=%s%s)\n' "$id" "$status" "$tier" "$([ "$cls" != - ] && printf ' class=%s' "$cls")"
}

cmd_visual() {
  # Register a VISUAL artifact for this run (the header's VISUAL EVIDENCE
  # section is the contract). Registration is a DELIBERATE act - the qa agent
  # asserts "this picture is what I proved" - which is why the path is validated
  # here and re-validated at the gate, and why a --case link must resolve.
  require_run
  local path="${1:-}" cid="" note="-" rd abs kind bytes tmp
  shift 1 2>/dev/null || ac_die "usage: ac-qa.sh visual <path> [--case <id>] [--note <text>]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --case) cid="$2"; shift 2 ;;
      --note) note="$2"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$path" ] || ac_die "usage: ac-qa.sh visual <path> [--case <id>] [--note <text>]"
  visual_register "$path" "$cid" "$note" 1
}

visual_register() {
  # visual_register <path> <case-id|''> <note> <require-case-row:0|1> - the ONE
  # implementation of visual registration. `boundary-register --boundary web`
  # calls it with require-case-row=0: a browser boundary is registered while
  # the stack is still up, before the assertions are judged into a ledger row,
  # and the pass gate still refuses any web case whose visual link is missing.
  local path="$1" cid="$2" note="$3" require_case="$4" rd abs kind bytes tmp
  rd="$(run_dir)"
  # Absolute as given; a relative path is tried against $PWD (normal CLI
  # behavior) and then against the evidence dir, where the skill parks per-case
  # artifacts (cases/<id>/...).
  case "$path" in
    /*) abs="$path" ;;
    *)  if [ -f "$PWD/$path" ]; then abs="$PWD/$path"; else abs="$(cmd_evidence_dir)/$path"; fi ;;
  esac
  # Reject BEFORE the ledger is touched: both characters break the tsv, and awk
  # refuses a -v value containing a newline - a rewrite attempted on one would
  # write nothing and clobber every row already registered.
  case "$abs" in
    *$'\t'*) ac_die "visual path must not contain a tab: $abs" ;;
    *$'\n'*) ac_die "visual path must not contain a newline: $abs" ;;
  esac
  [ -f "$abs" ] || ac_die "visual not found: $abs"
  [ -s "$abs" ] || ac_die "visual is empty: $abs (a capture that wrote nothing is not evidence)"
  kind="$(image_kind "$abs")" \
    || ac_die "not an image: $abs - the extension is never trusted; its magic bytes are not png/jpeg/gif/webp"
  if [ -n "$cid" ] && [ "$require_case" = 1 ]; then
    awk -F'\t' -v id="$cid" '$1 == id { hit = 1 } END { exit !hit }' "$rd/cases.tsv" \
      || ac_die "--case $cid is not in the ledger: record the case first (ac-qa.sh case $cid ...)"
  fi
  note="$(printf '%s' "$note" | tr '\t\n' '  ')"
  bytes="$(wc -c <"$abs" | tr -d ' ')"
  # Locked read-modify-write, like cases.tsv: supervised browser/case
  # subprocesses may finish concurrently inside the one QA pane. Last write per
  # PATH wins.
  ac_lock_acquire "$rd/.visuals.lock" 30 || ac_die "visuals ledger lock timeout"
  [ -f "$rd/visuals.tsv" ] || : >"$rd/visuals.tsv"   # a run started before this verb existed
  tmp="$(mktemp)"
  # The path goes through the ENVIRONMENT, not `awk -v`, which escape-processes
  # its value: `-v p=/a\tb.png` would compare against a real tab and never match
  # the literal row, registering the same artifact twice. A failed rewrite must
  # DIE with the ledger intact - swallowing it with `|| true` would leave $tmp
  # holding only the new row and mv would destroy every artifact on record.
  if ! p="$abs" awk -F'\t' '$1 != ENVIRON["p"]' "$rd/visuals.tsv" >"$tmp"; then
    rm -f "$tmp"
    ac_lock_release "$rd/.visuals.lock"
    ac_die "visuals ledger rewrite failed for: $abs (the ledger is unchanged)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$abs" "$kind" "$bytes" "${cid:--}" "$(ac_iso)" "$note" >>"$tmp"
  mv "$tmp" "$rd/visuals.tsv"
  ac_lock_release "$rd/.visuals.lock"
  printf 'visual %s registered: %s (%s bytes%s)\n' "$kind" "$abs" "$bytes" \
    "$([ -n "$cid" ] && printf ', case %s' "$cid")"
}

cmd_findings() {
  require_run
  local step="${1:-}" rd f json
  case " $STEPS " in *" $step "*) ;; *) ac_die "unknown step: $step" ;; esac
  case "${2:-}" in
    --show) ;;
    "") ;;
    *) ac_die "usage: ac-qa.sh findings <step> [--show]" ;;
  esac
  rd="$(run_dir)"
  f="$rd/findings/$step.json"
  if [ "${2:-}" = "--show" ]; then
    [ -f "$f" ] || ac_die "no findings recorded for step $step"
    cat "$f"
    return 0
  fi
  [ -t 0 ] && ac_die "findings $step reads a JSON array on stdin - refusing a tty (pipe JSON in, or use --show to view)"
  json="$(cat)"
  jq -e 'type == "array"' <<<"$json" >/dev/null || ac_die "findings must be a JSON array"
  ac_findings_normalize "$f" <<<"$json"
  ac_findings_summary "$f"
}

cmd_testplan_amend() {
  require_run
  local authority="" reason="" rd testplan old_sha new_sha case_json="[]" case_id
  local ledger tmp entry lock meta_tmp manifest manifest_tmp manifest_sha selection_changed
  while [ $# -gt 0 ]; do
    case "$1" in
      --case)
        case_id="${2:-}"
        case "$case_id" in ''|*[!A-Za-z0-9_.-]*) ac_die "testplan-amend --case must be [A-Za-z0-9_.-]" ;; esac
        case_json="$(jq -c --arg id "$case_id" '. + [$id] | unique' <<<"$case_json")"
        shift 2 ;;
      --authority) authority="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) ac_die "usage: ac-qa.sh testplan-amend --case <id> [--case <id> ...] --authority <accepted-authority> --reason <why>" ;;
    esac
  done
  [ "$(jq 'length' <<<"$case_json")" -gt 0 ] \
    || ac_die "testplan-amend requires at least one --case"
  [ -n "${authority//[[:space:]]/}" ] \
    || ac_die "testplan-amend requires accepted behavioral authority"
  [ -n "${reason//[[:space:]]/}" ] \
    || ac_die "testplan-amend requires a reason"
  case "$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
    implementation|implementation-behavior|source|source-code|"source code"|"current code"|"source implementation"|"current implementation"|"the code currently does this"|"code currently does this")
      ac_die "source implementation alone cannot redefine the oracle; record the case unverifiable or raise an ask-user finding" ;;
  esac
  rd="$(run_dir)"
  [ "$(awk -F'\t' '$1=="testplan"{print $2}' "$rd/steps.tsv")" = completed ] \
    || ac_die "testplan-amend requires the testplan step to be completed first"
  old_sha="$(ac_meta_get "$rd/run.meta" testplan_sha256)"
  [ -n "$old_sha" ] || ac_die "testplan-amend found no frozen test-plan hash"
  testplan="$(dirname "$(cmd_evidence_dir)")/testplan.md"
  [ -f "$testplan" ] || ac_die "testplan-amend cannot find the durable test plan: $testplan"
  new_sha="$(ac_config_sha256 "$testplan")"
  [ "$new_sha" != "$old_sha" ] \
    || ac_die "testplan-amend requires an actual test-plan content change"
  manifest="$rd/testplan-manifest.json"
  [ -f "$manifest" ] \
    || ac_die "testplan-amend found no frozen test-plan manifest"
  [ "$(ac_config_sha256 "$manifest")" = "$(ac_meta_get "$rd/run.meta" testplan_manifest_sha256)" ] \
    || ac_die "testplan-amend found a stale or corrupt frozen manifest"
  manifest_tmp="$(mktemp "$rd/.testplan-manifest-amend.XXXXXX")"
  if ! ac_qa_testplan_manifest_render "$repo" \
      "$(ac_meta_get "$rd/run.meta" target_sha)" "$testplan" >"$manifest_tmp"; then
    rm -f "$manifest_tmp"
    ac_die "testplan-amend refused: $AC_QA_MANIFEST_ERROR"
  fi
  if ! qa_testplan_ut_rows_ok "$rd" "$manifest_tmp"; then
    rm -f "$manifest_tmp"
    ac_die "testplan-amend refused: $AC_QA_MANIFEST_ERROR"
  fi
  selection_changed=0
  jq -e --slurpfile old "$manifest" \
    '.coverage == $old[0].coverage and .full_flow == $old[0].full_flow' \
    "$manifest_tmp" >/dev/null || selection_changed=1
  if [ "$selection_changed" = 1 ] && qa_case_evidence_exists "$rd"; then
    rm -f "$manifest_tmp"
    ac_die "testplan-amend refused: coverage/full-flow selection is frozen after case evidence exists; start a fresh QA round"
  fi
  manifest_sha="$(ac_config_sha256 "$manifest_tmp")"
  authority="$(printf '%s' "$authority" | tr '\t\r\n' '   ')"
  reason="$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
  ledger="$rd/oracle-amendments.jsonl"
  lock="$rd/.testplan-amend.lock.d"
  ac_lock_acquire "$lock" 30 || ac_die "testplan-amend lock timeout"
  tmp="$(mktemp "$rd/.oracle-amendments.XXXXXX")"
  [ ! -f "$ledger" ] || cat "$ledger" >"$tmp"
  entry="$(jq -cn --arg old "$old_sha" --arg new "$new_sha" \
    --arg authority "$authority" --arg reason "$reason" --arg at "$(ac_iso)" \
    --argjson cases "$case_json" \
    '{schema:"agentcrew.qa-oracle-amendment/v1",old_sha256:$old,new_sha256:$new,
      cases:$cases,authority:$authority,reason:$reason,recorded_at:$at}')"
  printf '%s\n' "$entry" >>"$tmp"
  meta_tmp="$rd/run.meta.amend.$$"
  # A failed rewrite must DIE with the ledger intact - swallowing it with
  # `|| true` would leave $meta_tmp holding only the three testplan_* lines
  # appended below, and the mv gate two steps down would still publish that
  # stub as the run's SOLE VERDICT-AUTHORITY file.
  if ! awk -F= '$1!="testplan_sha256" && $1!="testplan_manifest_sha256" && $1!="testplan_path"' \
      "$rd/run.meta" >"$meta_tmp"; then
    rm -f "$tmp" "$manifest_tmp" "$meta_tmp"
    ac_lock_release "$lock"
    ac_die "testplan-amend refused: could not rewrite run.meta (the run is unchanged)"
  fi
  printf 'testplan_sha256=%s\ntestplan_manifest_sha256=%s\ntestplan_path=%s\n' \
    "$new_sha" "$manifest_sha" "$testplan" >>"$meta_tmp"
  # The receipt lands first. Until the metadata rename, the old hash continues
  # to block pass; after it, the authority record is already durable.
  if ! mv "$tmp" "$ledger" \
      || ! mv "$manifest_tmp" "$manifest" \
      || ! mv "$meta_tmp" "$rd/run.meta"; then
    rm -f "$tmp" "$manifest_tmp" "$meta_tmp"
    ac_lock_release "$lock"
    ac_die "testplan-amend could not publish the amendment"
  fi
  ac_lock_release "$lock"
  printf 'testplan amended: %s -> %s cases=%s\n' "$old_sha" "$new_sha" \
    "$(jq -r 'join(",")' <<<"$case_json")"
}

qa_fixture_manifest_validate() {
  # qa_fixture_manifest_validate <pack-dir> - path-closed, retry-safe manifest.
  local pack="$1" manifest rel
  manifest="$pack/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  jq -e '
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
  ' "$manifest" >/dev/null 2>&1 || return 1
  while IFS= read -r rel; do
    case "$rel" in ''|/*|..|../*|*/../*|*/..) return 1 ;; esac
    [ -f "$pack/$rel" ] && [ ! -L "$pack/$rel" ] || return 1
  done < <(jq -r '.runner, (.assets // [])[]' "$manifest")
  return 0
}

cmd_harness_classify() {
  require_run
  local path="${1:-}" classification="" target="" invariant="" evidence="" rd ledger tmp
  shift 1 2>/dev/null || ac_die "usage: ac-qa.sh harness-classify <path> --classification <kind> --target <target> --invariant <text> --evidence <path>"
  while [ $# -gt 0 ]; do
    case "$1" in
      --classification) classification="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;;
      --invariant) invariant="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      *) ac_die "unknown harness-classify flag: $1" ;;
    esac
  done
  case "$classification" in repo-regression|e2e-regression|fixture-pack|evidence-only|retire) ;; *)
    ac_die "harness classification must be repo-regression|e2e-regression|fixture-pack|evidence-only|retire" ;;
  esac
  [ -n "$path" ] && [ -n "$target" ] && [ -n "$invariant" ] && [ -n "$evidence" ] \
    || ac_die "harness-classify requires path, classification, target, invariant, and evidence"
  [ -f "$path" ] || ac_die "harness-classify path is not a file: $path"
  path="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  rd="$(run_dir)"
  qa_evidence_path_ok "$(cmd_evidence_dir)" "$evidence" \
    || ac_die "harness-classify evidence is missing, broken, or outside the declared evidence root: $evidence"
  case "$evidence" in /*) ;; *) evidence="$(cmd_evidence_dir)/$evidence" ;; esac
  evidence="$(python3 - "$evidence" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  ledger="$rd/regression-candidates.tsv"
  tmp="$(mktemp "$rd/.regression-candidates.XXXXXX")"
  [ ! -f "$ledger" ] || awk -F'\t' -v p="$path" '$1 != p' "$ledger" >"$tmp"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(printf '%s' "$path" | tr '\t\r\n' '   ')" "$classification" \
    "$(printf '%s' "$target" | tr '\t\r\n' '   ')" \
    "$(printf '%s' "$invariant" | tr '\t\r\n' '   ')" \
    "$(printf '%s' "$evidence" | tr '\t\r\n' '   ')" >>"$tmp"
  mv "$tmp" "$ledger"
  printf 'harness classified: %s -> %s\n' "$path" "$classification"
}

cmd_regression_proposal() {
  require_run
  local patch="${1:-}" path out tmp
  [ $# -eq 1 ] && [ -f "$patch" ] \
    || ac_die "usage: ac-qa.sh regression-proposal <test-only.patch>"
  while IFS= read -r path; do
    [ "$path" = /dev/null ] && continue
    path="${path#a/}"
    path="${path#b/}"
    case "$path" in
      tests/*|test/*|spec/*|specs/*|*/tests/*|*/test/*|*/spec/*|*/specs/*|*__tests__/*|*.test.*|*.spec.*) ;;
      *) ac_die "regression proposal touches a production path: $path" ;;
    esac
  done < <(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch" | sed 's/[[:space:]].*$//')
  [ -n "$(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch")" ] \
    || ac_die "regression proposal contains no file changes"
  out="$(cmd_evidence_dir)/regression-proposal.patch"
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "$out.XXXXXX")"
  cp "$patch" "$tmp"
  mv "$tmp" "$out"
  printf '%s\n' "$out"
}

cmd_curation() {
  require_run
  local status="${1:-}" note="" rd outcome tmp
  shift 1 2>/dev/null || ac_die "usage: ac-qa.sh curation <completed|skipped|failed> [--note <reason>]"
  if [ $# -gt 0 ]; then
    [ "$#" = 2 ] && [ "$1" = --note ] \
      || ac_die "usage: ac-qa.sh curation <completed|skipped|failed> [--note <reason>]"
    note="${2:-}"
  fi
  case "$status" in completed|skipped|failed) ;; *) ac_die "invalid curation status: $status" ;; esac
  if [ "$status" != completed ] && [ -z "${note//[[:space:]]/}" ]; then
    ac_die "curation $status requires --note <reason>"
  fi
  note="$(printf '%s' "$note" | tr '\t\r\n' '   ')"
  [ -n "$note" ] || note="-"
  rd="$(run_dir)"
  outcome="$(ac_meta_get "$rd/run.meta" outcome)"
  case "$outcome" in passed|failed|unverifiable|cancelled) ;; *)
    ac_die "curation is valid only after a terminal QA outcome" ;;
  esac
  ac_lock_acquire "$rd/.curation.lock" 30 || ac_die "curation receipt lock timeout"
  tmp="$(mktemp "$rd/.run-meta-curation.XXXXXX")"
  awk -F= '$1!="curation" && $1!="curation_note"' "$rd/run.meta" >"$tmp"
  printf 'curation=%s\ncuration_note=%s\n' "$status" "$note" >>"$tmp"
  mv "$tmp" "$rd/run.meta"
  ac_lock_release "$rd/.curation.lock"
  printf 'curation=%s note=%s\n' "$status" "$note"
}

qa_store_manifest_merge() {
  # qa_store_manifest_merge <manifest> <rel-path> <hash> - atomically append
  # one (path, sha256) entry into a store-snapshot manifest, keeping entries
  # sorted by path. THE one merge step (F27), shared by the read-only
  # manifest builder below and cmd_agent's freeze-and-copy loop; the
  # unsafe-path guard and any cleanup-on-failure stay with each caller, since
  # only cmd_agent stages a bundle that needs cleaning up on a failed freeze.
  local manifest="$1" rel="$2" hash="$3" tmp="$1.tmp.$$"
  jq --arg path "$rel" --arg sha "$hash" \
      '.entries += [{path:$path,sha256:$sha}] | .entries |= sort_by(.path)' \
      "$manifest" >"$tmp" \
    && mv "$tmp" "$manifest"
}

qa_store_manifest_build() {
  # qa_store_manifest_build <store-dir> <manifest-output> - canonical content
  # receipt used for both round freeze and conflict-safe curation installation.
  local source="$1" output="$2" file rel hash
  jq -n '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}' >"$output"
  [ -d "$source" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="${file#"$source"/}"
    [ "$rel" != manifest.json ] || continue
    case "$rel" in /*|..|../*|*/../*|*/..|*$'\t'*|*$'\n'*)
      ac_die "qa store contains an unsafe relative path: $rel" ;;
    esac
    hash="$(ac_config_sha256 "$file")"
    qa_store_manifest_merge "$output" "$rel" "$hash" \
      || ac_die "could not build QA store manifest"
  done < <(find "$source" -type f ! -path "$output" -print | LC_ALL=C sort)
}

cmd_store_install() {
  # Chief-only installation of a complete curation candidate. The candidate's
  # base manifest must still equal the current shared store, so a concurrent
  # accepted update refuses rather than being overwritten.
  local candidate="${1:-}" source base_file base_sha home project dest lock
  local current_manifest current_sha stage previous=""
  [ $# -eq 1 ] && [ -d "$candidate/store" ] \
    || ac_die "usage: ac-qa.sh store-install <candidate-dir-with-store-and-base-manifest.sha256>"
  [ -n "${AC_HOME:-}" ] || ac_die "store-install is chief-only and requires the canonical fleet AC_HOME"
  candidate="$(cd "$candidate" && pwd -P)"
  source="$candidate/store"
  base_file="$candidate/base-manifest.sha256"
  base_sha="$(cat "$base_file" 2>/dev/null || true)"
  case "$base_sha" in ''|*[!0-9a-f]*) ac_die "curation candidate has no valid base-manifest.sha256" ;; esac
  [ "${#base_sha}" = 64 ] || ac_die "curation candidate base manifest hash must be SHA-256"
  [ -z "$(find "$source" -type l -print -quit)" ] \
    || ac_die "curation candidate store contains symlinks"
  home="$(cd "$AC_HOME" && pwd -P)"
  project="$(ac_project_config_name "$repo")" || ac_die "cannot resolve project identity for store install"
  dest="$home/data/qa-store/$project"
  mkdir -p "$(dirname "$dest")"
  lock="$dest.lock"
  ac_lock_acquire "$lock" 30 || ac_die "store-install lock timeout for $project"
  current_manifest="$(mktemp)"
  qa_store_manifest_build "$dest" "$current_manifest"
  current_sha="$(ac_config_sha256 "$current_manifest")"
  if [ "$current_sha" != "$base_sha" ]; then
    rm -f "$current_manifest"
    ac_lock_release "$lock"
    ac_die "store-install conflict: candidate base=$base_sha current=$current_sha; review against the newer store"
  fi
  stage="$(mktemp -d "$(dirname "$dest")/.${project}.curation.XXXXXX")"
  cp -R "$source/." "$stage/"
  if [ -d "$dest" ]; then
    previous="$dest.prev"
    rm -rf "$previous"
    mv "$dest" "$previous"
  fi
  mv "$stage" "$dest"
  rm -f "$current_manifest"
  ac_lock_release "$lock"
  printf 'QA-STORE-INSTALLED: %s base=%s%s\n' "$dest" "$base_sha" \
    "${previous:+ previous=$previous}"
}

# --- infra ----------------------------------------------------------------------

infra_services() {
  # The requested services, space-separated. NO full-stack default: an
  # unspecified list means BOOT NOTHING - the caller (agent) resolves the
  # real need from config qa.infra or `infra detect`, so a service that
  # needs no backend never pulls postgres/temporal it will not use.
  printf '%s\n' "${1:-}" | tr ',' ' '
}

infra_detect() {
  # Heuristic scan of the repo for which shipped profiles the service needs:
  # dependency manifests, a project compose/env, and lockfiles. Prints a
  # comma-separated subset of KNOWN_SERVICES (wiremock is NEVER auto-detected -
  # mocking an external HTTP dependency is a judgment call the agent makes).
  # The agent treats this as a grounded starting point, not gospel.
  local hay want=""
  # The scan MUST end exit 0: a no-match grep on the compose glob returns 2,
  # and under `set -e` an assignment from a non-zero command substitution
  # aborts the function. The trailing `true` guarantees a clean subshell.
  hay="$(
    { cd "$repo" 2>/dev/null && {
        cat requirements*.txt pyproject.toml Pipfile package.json go.mod \
            go.sum Gemfile Gemfile.lock composer.json pom.xml build.gradle \
            .env.example .env.sample .env.template 2>/dev/null
        grep -rhoiE 'image:[[:space:]]*[^[:space:]]*(postgres|redis|temporal)' \
            docker-compose*.y*ml compose*.y*ml 2>/dev/null
      }; } | tr '[:upper:]' '[:lower:]'
    true
  )"
  printf '%s' "$hay" | grep -qE 'psycopg|postgres|pg8000|asyncpg|sqlalchemy|pgx|lib/pq|jackc/pgx|database_url|pg_|activerecord.*postgres' && want="$want postgres"
  printf '%s' "$hay" | grep -qE 'redis|ioredis|go-redis|redis_url|redigo' && want="$want redis"
  printf '%s' "$hay" | grep -qE 'temporal' && want="$want temporal"
  printf '%s\n' "$want" | tr -s ' ' | sed -e 's/^ //' -e 's/ /,/g'
}

cmd_infra() {
  local verb="${1:-}"; shift || true
  local services="" task_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --services) services="$2"; shift 2 ;;
      --task) task_flag="$2"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  case "$verb" in
    detect)
      require_run
      infra_detect
      ;;
    up)
      require_run
      # bad/declared/undeclared are read on paths that may never assign them:
      # bash >= 4.4 treats a bare `local x` as declared-but-UNSET (set -u dies
      # on the read), where bash 3.2 made it empty - initialize explicitly.
      local rd proj svc files line args=() svclist bad="" declared="" undeclared=""
      rd="$(run_dir)"
      proj="$(compose_project)"
      svclist="$(infra_services "$services" | xargs)"
      # Validate every requested service is one we ship a profile for.
      for svc in $svclist; do
        case " $KNOWN_SERVICES " in *" $svc "*) ;; *) bad="$bad $svc" ;; esac
      done
      [ -z "$bad" ] || ac_die "unknown qa service(s):$bad (known: $KNOWN_SERVICES)"
      # INFRA CONTAINMENT (header-owned): the FIRST up DECLARES this run's need;
      # a later up may never reach past it. The guard precedes every boot below,
      # so a refusal boots nothing. It fires on WIDENING only - a repeat or a
      # subset must succeed, because an infra failure HOLDS the run and the
      # resume re-runs the held step verbatim. The declaration is stored
      # xargs-normalized (like svclist), never the raw comma string.
      if [ -f "$rd/infra.declared" ]; then
        declared="$(cat "$rd/infra.declared")"
        for svc in $svclist; do
          case " $declared " in *" $svc "*) ;; *) undeclared="${undeclared:-}$svc " ;; esac
        done
        [ -z "${undeclared:-}" ] || ac_die "infra up refused: this run declared '${declared:-(none)}' and ${undeclared}is outside it.
A qa run declares its infra need ONCE and nothing outside that declaration boots (see INFRA CONTAINMENT in this script's header). Park the case instead:
  ac-qa.sh case <id> unverifiable --tier <t> --classification environment --note 'needs ${undeclared}- outside the run declaration'
A need you got WRONG is re-declared deliberately: fix the testplan's '## Infra' block and start a fresh run (ac-qa.sh start --target <ref> --task <id>)."
      else
        printf '%s\n' "$svclist" >"$rd/infra.declared"
      fi
      ac_require python3            # QA_PORT pick, even with zero backends
      if [ -z "$svclist" ]; then
        # Service needs no backend: allocate its port, boot no containers.
        ports_env "$rd" "$proj" ""
        printf 'infra up: no backend services (service needs none)\n'
      else
        ac_require docker
        # Command substitution, NOT process substitution: a compose_files die
        # (lint failure, missing template) must abort up, never fail open.
        files="$(compose_files)"
        while IFS= read -r line; do args+=("$line"); done <<<"$files"
        for svc in $svclist; do args+=(--profile "$svc"); done
        docker compose -p "$proj" "${args[@]}" up -d --wait \
          || ac_die "infra up failed (project $proj); logs: docker compose -p $proj logs"
        ports_env "$rd" "$proj" "$services"
        printf 'infra up: %s (%s)\n' "$proj" "$svclist"
      fi
      ;;
    down)
      ac_require docker
      local proj rc=0
      if [ -n "$task_flag" ]; then
        proj="crew-qa-$(repo_scope)-$(sanitize_compose "$task_flag")"
      else
        require_run; proj="$(compose_project)"
      fi
      case "$proj" in crew-qa-*) ;; *) ac_die "refusing down of non-crew-qa project: $proj" ;; esac
      # Best-effort teardown, but NOT a silent one: the status is reported so a
      # caller can tell a torn-down stack from an unusable docker (down on an
      # absent project is 0 anyway). Reported, never fatal - a stack that
      # outlives one attempt is reclaimed by the next down, not by dying here.
      docker compose -p "$proj" down -v --remove-orphans 2>/dev/null || rc=$?
      printf 'infra down: %s\n' "$proj"
      return "$rc"
      ;;
    status)
      ac_require docker
      docker ps --filter "label=com.docker.compose.project" \
        --format '{{.Label "com.docker.compose.project"}}\t{{.Names}}\t{{.Status}}' \
        | grep -F "crew-qa-$(repo_scope)-" || printf '(no crew-qa containers for this repo)\n'
      ;;
    reap)
      # Orphan sweep: every crew-qa-<this-repo>-* compose project whose run
      # state is gone gets torn down. Label-scoped; never touches other
      # containers. Safe with docker absent (no-op).
      command -v docker >/dev/null 2>&1 || { printf 'reap: docker absent, nothing to do\n'; return 0; }
      local p live m t rid projects scope main
      scope="$(repo_scope)"
      main="$(ac_repo_root "$repo")"
      projects="$(docker ps -a --filter "label=crew.qa=1" \
        --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | sort -u \
        | grep -F "crew-qa-$scope-" || true)"
      [ -n "$projects" ] || { printf 'reap: nothing to reap\n'; return 0; }
      printf '%s\n' "$projects" | while IFS= read -r p; do
        # Live = some still-running qa run for this repo maps to project p.
        # Run state can live in the MAIN repo's .crew/qa OR inside any pool
        # worktree's .crew/qa - scan both.
        live=0
        for m in "$main"/.crew/qa/*/run.meta "$main"/.crew/worktrees/*/.crew/qa/*/run.meta; do
          [ -f "$m" ] || continue
          grep -qx 'outcome=running' "$m" || continue
          t="$(sed -n 's/^task=//p' "$m" | head -n1)"
          rid="$(basename "$(dirname "$m")")"
          [ "crew-qa-$scope-$(sanitize_compose "${t:-$rid}")" = "$p" ] && { live=1; break; }
        done
        if [ "$live" = 0 ]; then
          docker compose -p "$p" down -v --remove-orphans 2>/dev/null || true
          printf 'reaped %s\n' "$p"
        fi
      done
      return 0
      ;;
    *) ac_die "usage: ac-qa.sh infra <detect|up|down|status|reap>" ;;
  esac
}

ports_env() {
  # Read back the ephemeral host ports into <run>/ports.env - the ONLY
  # source of endpoints for serve/seed/e2e.
  local rd="$1" proj="$2" services="$3" svc host_port
  : >"$rd/ports.env"
  for svc in $(infra_services "$services"); do
    case "$svc" in
      postgres)
        host_port="$(docker compose -p "$proj" port postgres 5432 2>/dev/null | awk -F: '{print $NF}')" || true
        [ -n "$host_port" ] && printf 'QA_PG_URL=postgresql://test:test@127.0.0.1:%s/test\nQA_PG_PORT=%s\n' "$host_port" "$host_port" >>"$rd/ports.env" ;;
      redis)
        host_port="$(docker compose -p "$proj" port redis 6379 2>/dev/null | awk -F: '{print $NF}')" || true
        [ -n "$host_port" ] && printf 'QA_REDIS_URL=redis://127.0.0.1:%s\nQA_REDIS_PORT=%s\n' "$host_port" "$host_port" >>"$rd/ports.env" ;;
      temporal)
        host_port="$(docker compose -p "$proj" port temporal 7233 2>/dev/null | awk -F: '{print $NF}')" || true
        [ -n "$host_port" ] && printf 'QA_TEMPORAL_ADDR=127.0.0.1:%s\n' "$host_port" >>"$rd/ports.env" ;;
      wiremock)
        host_port="$(docker compose -p "$proj" port wiremock 8080 2>/dev/null | awk -F: '{print $NF}')" || true
        [ -n "$host_port" ] && printf 'QA_MOCK_URL=http://127.0.0.1:%s\n' "$host_port" >>"$rd/ports.env" ;;
    esac
  done
  # A free port for the service under test itself.
  local qa_port
  qa_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  printf 'QA_PORT=%s\nQA_BASE_URL=http://127.0.0.1:%s\n' "$qa_port" "$qa_port" >>"$rd/ports.env"
}

# --- live service ----------------------------------------------------------------

cmd_baseline() {
  # BASELINE IS A RECEIPT CHECK (header-owned): validate the caller-frozen
  # exact-SHA ship test receipt and record the answer. It NEVER executes a
  # suite, in either outcome - unit-suite health belongs to the ship pipeline
  # exclusively (captain 2026-07-25).
  require_run
  local rd receipt status qual reason
  rd="$(run_dir)"
  receipt="$rd/profile/ship/test-receipt.env"
  status="$(ac_qa_ship_receipt_status "$receipt" "$(ac_meta_get "$rd/run.meta" target_sha)")"
  qual="${status%%:*}"
  reason="${status#*:}"
  step_owner=baseline
  cmd_step baseline completed --note "$status" >/dev/null
  step_owner=""
  # This command records only the receipt state. The frozen coverage manifest
  # decides its effect: informational without UT rows, required evidence for
  # each selected UT row.
  : "$qual" "$reason"
  printf 'baseline: ship test receipt %s (receipt check only; the suite was NOT re-run; UT coverage requires qualification)\n' "$status"
}

cmd_boundary_run() {
  # Drive one behavioral case against the BOOTED deliverable from outside its
  # process and publish the immutable execution receipt (header: CLIENT
  # BOUNDARY). The driver's own exit code is returned, and the receipt is
  # published either way: it records execution facts, never the verdict.
  require_run
  local case_id="" boundary="" evidence="" rd started ended rc stimulus arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --case) case_id="${2:-}"; shift 2 ;;
      --boundary) boundary="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --) shift; break ;;
      *) ac_die "usage: ac-qa.sh boundary-run --case <id> --boundary <http|grpc|client-cli|workflow|queue|schedule> --evidence <path> -- <command> [args...]" ;;
    esac
  done
  [ -n "$case_id" ] && [ -n "$boundary" ] && [ -n "$evidence" ] && [ $# -gt 0 ] \
    || ac_die "usage: ac-qa.sh boundary-run --case <id> --boundary <http|grpc|client-cli|workflow|queue|schedule> --evidence <path> -- <command> [args...]"
  case "$case_id" in ''|.|*..*|*[!a-zA-Z0-9_.-]*) ac_die "case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '$case_id'" ;; esac
  case "$boundary" in http|grpc|client-cli|workflow|queue|schedule) ;;
    *) ac_die "boundary-run drives shell clients only: --boundary must be http|grpc|client-cli|workflow|queue|schedule (a browser run registers with 'boundary-register --boundary web', an approved E2E run with '--boundary e2e'; QA never executes UT)" ;;
  esac
  rd="$(run_dir)"
  qa_testplan_ready "$rd" \
    || ac_die "boundary-run refused: $AC_QA_MANIFEST_ERROR"
  qa_runtime_receipt_ok "$rd" \
    || ac_die "boundary-run refused: $AC_QA_RECEIPT_ERROR. Boot the deliverable with 'ac-qa.sh serve' and publish its runtime receipt with 'ac-qa.sh health' first - a case that never reached a booted system is not behavioral evidence."
  [ -e "$evidence" ] || ac_die "boundary-run --evidence $evidence: no such file or directory"
  stimulus=""
  for arg in "$@"; do stimulus="${stimulus}${stimulus:+$'\n'}$arg"; done
  local -a benv
  qa_boundary_env "$rd" benv
  started="$(ac_iso)"
  set +e
  # The driver's own output goes to the log and to STDERR, never stdout: this
  # command's stdout IS the receipt path, so the case record composes directly
  # (`--receipt "$(ac-qa.sh boundary-run ... -- <cmd>)"`).
  ( cd "$repo" && env -i "${benv[@]}" "$@" ) 2>&1 | tee -a "$rd/logs/boundary-$case_id.log" >&2
  rc="${PIPESTATUS[0]}"
  set -e
  ended="$(ac_iso)"
  printf '%s boundary-run case=%s boundary=%s exit=%s\n' "$(ac_iso)" "$case_id" "$boundary" "$rc" >>"$rd/logs/run.log"
  qa_boundary_receipt_publish "$rd" "$case_id" "$boundary" command \
    "$(qa_sha_string "$stimulus")" "$(qa_path_sha "$evidence")" "-" "$started" "$ended" "$rc"
  return "$rc"
}

cmd_boundary_register() {
  # Register a boundary whose driver is NOT a shell command this script ran: a
  # real browser transcript, or the existing immutable E2E receipt. Both get the
  # same runtime-bound wrapper, so the pass gate reads one receipt shape.
  require_run
  local case_id="" boundary="" transcript="" visual="" upstream="" evidence="" rd now
  local manifest ev_sha stimulus upstream_sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --case) case_id="${2:-}"; shift 2 ;;
      --boundary) boundary="${2:-}"; shift 2 ;;
      --transcript) transcript="${2:-}"; shift 2 ;;
      --visual) visual="${2:-}"; shift 2 ;;
      --upstream-receipt) upstream="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      *) ac_die "usage: ac-qa.sh boundary-register --case <id> --boundary <web|e2e> [--transcript <p> --visual <p>] [--upstream-receipt <p> --evidence <p>]" ;;
    esac
  done
  [ -n "$case_id" ] || ac_die "boundary-register requires --case <id>"
  case "$case_id" in ''|.|*..*|*[!a-zA-Z0-9_.-]*) ac_die "case id must be [a-zA-Z0-9_.-] and never '.' or contain '..': '$case_id'" ;; esac
  rd="$(run_dir)"
  qa_testplan_ready "$rd" \
    || ac_die "boundary-register refused: $AC_QA_MANIFEST_ERROR"
  qa_runtime_receipt_ok "$rd" \
    || ac_die "boundary-register refused: $AC_QA_RECEIPT_ERROR"
  case "$boundary" in
    web)
      [ -n "$transcript" ] && [ -f "$transcript" ] \
        || ac_die "boundary-register --boundary web requires --transcript <path to the browser transcript>"
      [ -n "$visual" ] && [ -f "$visual" ] \
        || ac_die "boundary-register --boundary web requires --visual <path to the screenshot>"
      # The visual link is registered HERE, with no requirement that the final
      # case row already exists: a browser run is registered while the stack is
      # up, and the ledger row is written after the assertions are judged.
      visual_register "$visual" "$case_id" "browser boundary evidence" 0 >/dev/null
      manifest="$rd/boundaries/$case_id/browser-$(date +%Y%m%d-%H%M%S)-$$.manifest"
      mkdir -p "$(dirname "$manifest")"
      printf 'transcript %s\nvisual %s\n' "$(qa_path_sha "$transcript")" "$(qa_path_sha "$visual")" >"$manifest"
      ev_sha="$(ac_config_sha256 "$manifest")"
      now="$(ac_iso)"
      qa_boundary_receipt_publish "$rd" "$case_id" web browser \
        "$(qa_path_sha "$transcript")" "$ev_sha" "-" "$now" "$now" 0 ;;
    e2e)
      [ -n "$upstream" ] && [ -f "$upstream" ] \
        || ac_die "boundary-register --boundary e2e requires --upstream-receipt <path to an agentcrew.qa-e2e-receipt/v1>"
      [ -n "$evidence" ] && [ -e "$evidence" ] \
        || ac_die "boundary-register --boundary e2e requires --evidence <path>"
      # The upstream E2E receipt is the execution record and stays untouched;
      # the wrapper is valid ONLY when that receipt names this case and was
      # produced at the frozen source, E2E ref, profile, and command.
      qa_e2e_receipt_named "$rd" "$upstream" "$case_id" \
        || ac_die "boundary-register: $AC_QA_RECEIPT_ERROR"
      upstream_sha="$(ac_config_sha256 "$upstream")"
      stimulus="$(ac_meta_get "$upstream" command_sha256)"
      qa_boundary_receipt_publish "$rd" "$case_id" e2e e2e \
        "$stimulus" "$(qa_path_sha "$evidence")" "$upstream_sha" \
        "$(ac_meta_get "$upstream" started_at)" "$(ac_meta_get "$upstream" completed_at)" \
        "$(ac_meta_get "$upstream" exit_code)" ;;
    *) ac_die "boundary-register --boundary must be web or e2e (shell-driven boundaries run through 'ac-qa.sh boundary-run')" ;;
  esac
}

qa_e2e_receipt_named() {
  # qa_e2e_receipt_named <run-dir> <receipt> <case-id> - the upstream E2E
  # receipt is this run's, at its frozen refs, and NAMES this case. Sets
  # AC_QA_RECEIPT_ERROR on refusal.
  local rd="$1" receipt="$2" case_id="$3" command command_sha cases
  AC_QA_RECEIPT_ERROR=""
  [ "$(ac_meta_get "$receipt" schema)" = "agentcrew.qa-e2e-receipt/v1" ] \
    || { AC_QA_RECEIPT_ERROR="upstream receipt has the wrong schema"; return 1; }
  [ "$(ac_meta_get "$receipt" source_sha)" = "$(ac_meta_get "$rd/run.meta" target_sha)" ] \
    || { AC_QA_RECEIPT_ERROR="upstream E2E receipt binds another source sha"; return 1; }
  [ "$(ac_meta_get "$receipt" e2e_sha)" = "$(ac_meta_get "$rd/run.meta" e2e_ref)" ] \
    || { AC_QA_RECEIPT_ERROR="upstream E2E receipt binds another E2E ref"; return 1; }
  [ "$(ac_meta_get "$receipt" profile_sha256)" = "$(ac_meta_get "$rd/run.meta" profile_sha256)" ] \
    || { AC_QA_RECEIPT_ERROR="upstream E2E receipt binds another profile hash"; return 1; }
  command="$(cmd_config qa.e2e.command 2>/dev/null || true)"
  command_sha="$(qa_sha_string "$command")"
  [ -n "$command" ] && [ "$(ac_meta_get "$receipt" command_sha256)" = "$command_sha" ] \
    || { AC_QA_RECEIPT_ERROR="upstream E2E receipt binds another command"; return 1; }
  cases=",$(ac_meta_get "$receipt" cases),"
  case "$cases" in *",$case_id,"*) ;;
    *) AC_QA_RECEIPT_ERROR="upstream E2E receipt does not name case $case_id"; return 1 ;;
  esac
  return 0
}

cmd_serve() {
  require_run
  local rd c
  rd="$(run_dir)"
  c="$(cmd_config qa.serve 2>/dev/null || true)"
  [ -n "$c" ] || { printf '(no qa.serve configured)\n' >&2; exit 4; }
  if [ -f "$rd/serve.pid" ] && kill -0 "$(cat "$rd/serve.pid")" 2>/dev/null; then
    ac_die "serve already running (pid $(cat "$rd/serve.pid"))"
  fi
  # NO RE-ISSUE INSIDE ONE ROUND (header: RUNTIME BOOT RECEIPT): boundary
  # receipts hash-bind the boot receipt, so a restart would silently detach
  # every case already recorded from the runtime it actually exercised.
  [ ! -f "$rd/runtime/receipt.env" ] \
    || ac_die "serve refused: this round already published a runtime boot receipt, and there is no re-issue path inside one round - every boundary receipt is bound to it. Finish this round honestly (failed|unverifiable|cancelled) and re-prove against the new runtime in a fresh round."
  mkdir -p "$rd/runtime"
  # FREEZE the runtime descriptor the boot receipt hash-binds: the resolved
  # endpoint/worker mapping every boundary driver will run under. Frozen, not
  # re-read, so `runtime_descriptor_sha256` names one immutable thing.
  if [ -f "$rd/ports.env" ]; then
    LC_ALL=C sort "$rd/ports.env" >"$rd/runtime/descriptor.env"
  else
    : >"$rd/runtime/descriptor.env"
  fi
  local -a qenv
  minimal_env "$rd" qenv
  # Job control (set -m) puts the serve job in its OWN process group with
  # pgid == $!, so finish can kill the whole tree - killing just the sh
  # wrapper leaves the real server orphaned.
  ( cd "$repo" || exit 1
    set -m
    env -i "${qenv[@]}" sh -c "$c" >>"$rd/logs/serve.log" 2>&1 &
    printf '%s' "$!" >"$rd/serve.pid" )
  {
    printf 'serve_started_at=%s\n' "$(ac_iso)"
    printf 'process_group=%s\n' "$(cat "$rd/serve.pid")"
    printf 'serve_command_sha256=%s\n' "$(qa_sha_string "$c")"
  } >"$rd/runtime/launch.env"
  printf '%s serve pid=%s\n' "$(ac_iso)" "$(cat "$rd/serve.pid")" >>"$rd/logs/run.log"
  step_owner=serve
  cmd_step serve completed --note "provisional launch pid=$(cat "$rd/serve.pid") (readiness is proven by the runtime receipt, not this status)" >/dev/null
  step_owner=""
  printf 'serving (pid %s, log %s/logs/serve.log)\n' "$(cat "$rd/serve.pid")" "$rd"
}

qa_publish_runtime_receipt() {
  # qa_publish_runtime_receipt <run-dir> - the ONE writer of the boot receipt,
  # called by `health` after a zero-exit probe against a still-live process
  # group. Immutable once published: a second health with the same group is a
  # no-op, a different group is refused rather than re-issued.
  local rd="$1" launch="$1/runtime/launch.env" pgid tmp
  [ -f "$launch" ] || {
    printf 'notice: no recorded serve launch - probing only, no runtime receipt published (a passing run needs "ac-qa.sh serve" first)\n' >&2
    return 0
  }
  pgid="$(ac_meta_get "$launch" process_group)"
  qa_pgid_alive "$pgid" \
    || ac_die "health: the recorded serve process group ($pgid) is gone - the deliverable is not booted, so no runtime receipt can be published"
  if [ -f "$rd/runtime/receipt.env" ]; then
    [ "$(ac_meta_get "$rd/runtime/receipt.env" process_group)" = "$pgid" ] \
      || ac_die "health: this round's runtime receipt binds process group $(ac_meta_get "$rd/runtime/receipt.env" process_group), not $pgid - a restarted runtime invalidates the round; finish it honestly and re-prove in a fresh one"
    return 0
  fi
  qa_runtime_identity "$rd"
  [ "$qa_id_serve" = "$(ac_meta_get "$launch" serve_command_sha256)" ] \
    || ac_die "health: the frozen qa.serve command changed since the launch this receipt would describe"
  tmp="$(mktemp "$rd/runtime/.receipt.XXXXXX")"
  {
    printf 'schema=agentcrew.qa-runtime-receipt/v1\n'
    printf 'source_sha=%s\n' "$qa_id_source"
    printf 'profile_sha256=%s\n' "$qa_id_profile"
    printf 'serve_command_sha256=%s\n' "$qa_id_serve"
    printf 'health_command_sha256=%s\n' "$qa_id_health"
    printf 'runtime_descriptor_sha256=%s\n' "$qa_id_desc"
    printf 'serve_started_at=%s\n' "$(ac_meta_get "$launch" serve_started_at)"
    printf 'health_completed_at=%s\n' "$(ac_iso)"
    printf 'process_group=%s\n' "$pgid"
  } >"$tmp"
  mv "$tmp" "$rd/runtime/receipt.env" \
    || { rm -f "$tmp"; ac_die "health could not publish the runtime boot receipt"; }
  ac_qa_runtime_receipt_validate "$rd/runtime/receipt.env" \
    "$qa_id_source" "$qa_id_profile" "$qa_id_serve" "$qa_id_health" "$qa_id_desc" \
    || ac_die "health published an invalid runtime receipt: $AC_QA_RECEIPT_ERROR"
  printf 'runtime receipt published (process group %s)\n' "$pgid"
}

cmd_health() {
  require_run
  local rd c timeout pid
  rd="$(run_dir)"
  c="$(cmd_config qa.health 2>/dev/null || true)"
  [ -n "$c" ] || { printf '(no qa.health configured)\n' >&2; exit 4; }
  timeout="$(cmd_config qa.health_timeout 2>/dev/null || true)"; timeout="${timeout:-60}"
  pid="$(cat "$rd/serve.pid" 2>/dev/null || true)"
  local -a qenv
  minimal_env "$rd" qenv
  # Wall-clock deadline (a slow probe must not stretch the budget), and each
  # probe is capped at 10s (perl alarm; macOS ships no timeout(1)) so a
  # wedged accept-but-never-respond server cannot hang the poll forever.
  local start deadline
  start="$(date +%s)"; deadline=$((start + timeout))
  if command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # perl code, not shell expansion
    probe(){ ( cd "$repo" && env -i "${qenv[@]}" perl -e 'alarm 10; exec "sh", "-c", $ARGV[0]' "$c" ); }
  else
    probe(){ ( cd "$repo" && env -i "${qenv[@]}" sh -c "$c" ); }
  fi
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      ac_die "serve process died during health wait (see $rd/logs/serve.log)"
    fi
    if probe >/dev/null 2>&1; then
      printf 'healthy after %ss\n' "$(( $(date +%s) - start ))"
      # The probe is a COMMAND, never a step: its proof is the runtime receipt
      # only a zero-exit probe against a live process group can publish.
      qa_publish_runtime_receipt "$rd"
      return 0
    fi
    sleep 2
  done
  ac_die "health probe never passed within ${timeout}s"
}

cmd_seed() {
  require_run
  local rd c
  rd="$(run_dir)"
  c="$(cmd_config qa.seed 2>/dev/null || true)"
  [ -n "$c" ] || { printf '(no qa.seed configured)\n' >&2; exit 4; }
  run_minimal "$rd" seed "$c"
}

cmd_cmd() {
  require_run
  local name="${1:-}" selected="" c rd desc cid normalized="" started ended rc
  local command_sha receipt_dir receipt_name receipt_tmp receipt ptr_tmp
  shift 2>/dev/null || true
  case "$name" in e2e) ;; *) ac_die "usage: ac-qa.sh cmd e2e --cases <case-id>[,<case-id>...]" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --cases) selected="${2:-}"; shift 2 ;;
      *) ac_die "usage: ac-qa.sh cmd e2e --cases <case-id>[,<case-id>...]" ;;
    esac
  done
  [ -n "$selected" ] || ac_die "cmd e2e requires --cases <case-id>[,<case-id>...]"
  case "$selected" in *[!A-Za-z0-9_.,-]*)
    ac_die "cmd e2e --cases accepts comma-separated case ids only: $selected" ;;
  esac
  rd="$(run_dir)"
  qa_testplan_ready "$rd" \
    || ac_die "cmd e2e refused: $AC_QA_MANIFEST_ERROR"
  for cid in ${selected//,/ }; do
    [ -n "$cid" ] || continue
    awk -F'\t' -v id="$cid" '$1 == id { found=1 } END { exit !found }' "$rd/cases.tsv" \
      || ac_die "cmd e2e refused: selected case '$cid' is not in the current behavioral ledger"
    case ",$normalized," in *",$cid,"*) ;; *)
      normalized="${normalized}${normalized:+,}$cid" ;;
    esac
  done
  [ -n "$normalized" ] || ac_die "cmd e2e requires at least one existing case id"
  c="$(cmd_config qa.e2e.command 2>/dev/null || true)"
  [ -n "$c" ] \
    || ac_die "cmd e2e needs a frozen chief-approved qa.e2e.command; record affected cases unverifiable and an ask-user finding with action=ask-user when the profile is missing it"
  command_sha="$(qa_sha_string "$c")"
  desc="$rd/profile/runtime.json"
  cmd_step e2e running --note "approved command selected for cases $normalized" >/dev/null
  started="$(ac_iso)"
  # SEPARATE E2E repo (Story 3): run from the leased E2E worktree's product
  # workdir with the endpoint-env mapping + the undeclared-.env guard. Absent a
  # runtime bundle with a worktree, otherwise run in the source repository.
  if [ -f "$desc" ] && [ -n "$(jq -r '.e2e_worktree // ""' "$desc" 2>/dev/null)" ]; then
    if run_e2e_separate "$rd" "$rd/profile/profile.json" "$desc" "$c"; then rc=0; else rc=$?; fi
  else
    if run_minimal "$rd" e2e "$c"; then rc=0; else rc=$?; fi
  fi
  ended="$(ac_iso)"

  receipt_dir="$rd/e2e/receipts"
  mkdir -p "$receipt_dir"
  receipt_name="$(date +%Y%m%d-%H%M%S)-$$.env"
  receipt="$receipt_dir/$receipt_name"
  receipt_tmp="$(mktemp "$receipt_dir/.receipt.XXXXXX")"
  {
    printf 'schema=agentcrew.qa-e2e-receipt/v1\n'
    printf 'source_sha=%s\n' "$(ac_meta_get "$rd/run.meta" target_sha)"
    printf 'e2e_repo=%s\n' "$(ac_meta_get "$rd/run.meta" e2e_repo)"
    printf 'e2e_sha=%s\n' "$(ac_meta_get "$rd/run.meta" e2e_ref)"
    printf 'profile_sha256=%s\n' "$(ac_meta_get "$rd/run.meta" profile_sha256)"
    printf 'command_sha256=%s\n' "$command_sha"
    printf 'cases=%s\n' "$normalized"
    printf 'started_at=%s\n' "$started"
    printf 'completed_at=%s\n' "$ended"
    printf 'exit_code=%s\n' "$rc"
  } >"$receipt_tmp"
  [ "$(ac_meta_get "$receipt_tmp" schema)" = "agentcrew.qa-e2e-receipt/v1" ] \
    && [ -n "$(ac_meta_get "$receipt_tmp" command_sha256)" ] \
    && [ -n "$(ac_meta_get "$receipt_tmp" cases)" ] \
    || { rm -f "$receipt_tmp"; ac_die "cmd e2e could not validate its staged execution receipt"; }
  mv "$receipt_tmp" "$receipt"
  ptr_tmp="$(mktemp "$rd/e2e/.receipt-current.XXXXXX")"
  printf '%s\n' "$receipt_name" >"$ptr_tmp"
  mv "$ptr_tmp" "$rd/e2e/receipt.current"
  if [ "$rc" = 0 ]; then
    cmd_step e2e completed --note "receipt=$receipt_name cases=$normalized" >/dev/null
  else
    cmd_step e2e failed --note "receipt=$receipt_name exit=$rc cases=$normalized" >/dev/null
  fi
  return "$rc"
}

cmd_fixture() {
  # Execute one selector from a reviewed fixture pack in the frozen store
  # snapshot. Common setup stays in the pack; the invocation maps that selector
  # to the current test-plan case ids and writes an immutable execution receipt.
  require_run
  local pack_id="${1:-}" selector="" case_id rd pack manifest runner mutation retry
  local rel started ended rc receipt_dir receipt_tmp receipt_name cases_json="[]"
  local -a case_ids=() command=() qenv=()
  shift 1 2>/dev/null || ac_die "usage: ac-qa.sh fixture <pack-id> --selector <name> --case <id> [--case <id> ...]"
  while [ $# -gt 0 ]; do
    case "$1" in
      --selector) selector="${2:-}"; shift 2 ;;
      --case) case_ids+=("${2:-}"); shift 2 ;;
      *) ac_die "usage: ac-qa.sh fixture <pack-id> --selector <name> --case <id> [--case <id> ...]" ;;
    esac
  done
  case "$pack_id" in ''|*[!A-Za-z0-9_.-]*) ac_die "fixture pack id must be [A-Za-z0-9_.-]: '$pack_id'" ;; esac
  case "$selector" in ''|*[!A-Za-z0-9_.-]*) ac_die "fixture selector must be [A-Za-z0-9_.-]: '$selector'" ;; esac
  [ "${#case_ids[@]}" -gt 0 ] || ac_die "fixture requires at least one --case <id>"

  rd="$(run_dir)"
  qa_testplan_ready "$rd" \
    || ac_die "fixture refused: $AC_QA_MANIFEST_ERROR"
  [ -f "$rd/profile/profile.json" ] \
    || ac_die "fixture packs are available only to a sanctioned run with a frozen profile"
  ac_qa_bundle_validate "$rd/profile/profile.json" "$(ac_meta_get "$rd/run.meta" target_sha)" \
    || ac_die "fixture refused a tampered runtime bundle: $AC_QA_BUNDLE_ERROR"
  pack="$rd/profile/store/fixtures/$pack_id"
  manifest="$pack/manifest.json"
  [ -d "$pack" ] && [ ! -L "$pack" ] && [ -f "$manifest" ] && [ ! -L "$manifest" ] \
    || ac_die "fixture pack is missing or symlinked: $pack_id"
  qa_fixture_manifest_validate "$pack" \
    || ac_die "fixture pack '$pack_id' has an invalid, unsafe, or non-retry-safe manifest"
  [ "$(jq -r '.id' "$manifest")" = "$pack_id" ] \
    || ac_die "fixture pack directory '$pack_id' disagrees with manifest id"
  jq -e --arg selector "$selector" '.selectors | index($selector) != null' "$manifest" >/dev/null \
    || ac_die "fixture pack $pack_id has no selector '$selector'"
  runner="$(jq -r '.runner' "$manifest")"
  mutation="$(jq -r '.mutation' "$manifest")"
  retry="$(jq -r '.retry' "$manifest")"
  if [ "$mutation" = read-write ] && [ "$retry" != idempotent ]; then
    ac_die "fixture pack $pack_id selector $selector is read-write but does not declare retry=idempotent"
  fi
  while IFS= read -r rel; do
    case "$rel" in ''|/*|..|../*|*/../*|*/..|*$'\t'*|*$'\n'*)
      ac_die "fixture pack $pack_id contains an unsafe runner/asset path: $rel" ;;
    esac
    [ -f "$pack/$rel" ] && [ ! -L "$pack/$rel" ] \
      || ac_die "fixture pack $pack_id references a missing or symlinked file: $rel"
  done < <({ printf '%s\n' "$runner"; jq -r '.assets[]?' "$manifest"; })
  for case_id in "${case_ids[@]}"; do
    case "$case_id" in ''|.|*..*|*[!A-Za-z0-9_.-]*) ac_die "fixture case id must be [A-Za-z0-9_.-] and never '.' or contain '..': '$case_id'" ;; esac
    awk -F'\t' -v id="$case_id" '$1 == id { found=1 } END { exit !found }' "$rd/cases.tsv" \
      || ac_die "fixture selector $selector maps to case '$case_id', which is not in the current behavioral ledger"
    if jq -e --arg id "$case_id" 'index($id) != null' <<<"$cases_json" >/dev/null; then
      ac_die "fixture case id repeated: $case_id"
    fi
    cases_json="$(jq -c --arg id "$case_id" '. + [$id]' <<<"$cases_json")"
  done

  case "$runner" in
    *.sh) command=(sh "./$runner") ;;
    *) [ -x "$pack/$runner" ] || ac_die "fixture runner is not executable: $pack/$runner"
       command=("./$runner") ;;
  esac
  command+=(--selector "$selector")
  for case_id in "${case_ids[@]}"; do command+=(--case "$case_id"); done
  minimal_env "$rd" qenv
  started="$(ac_iso)"
  if (cd "$pack" && env -i "${qenv[@]}" \
      AC_QA_RUN_ID="$(basename "$rd")" AC_QA_FIXTURE_PACK="$pack_id" \
      AC_QA_EVIDENCE="$(cmd_evidence_dir)" "${command[@]}"); then
    rc=0
  else
    rc=$?
  fi
  ended="$(ac_iso)"
  receipt_dir="$rd/fixtures/receipts"
  mkdir -p "$receipt_dir"
  receipt_name="$(date +%Y%m%d-%H%M%S)-$$-$pack_id-$selector.json"
  receipt_tmp="$(mktemp "$receipt_dir/.receipt.XXXXXX")"
  jq -n --arg pack "$pack_id" --arg selector "$selector" \
    --arg started "$started" --arg completed "$ended" \
    --arg source_sha "$(ac_meta_get "$rd/run.meta" target_sha)" \
    --arg profile_sha "$(ac_meta_get "$rd/run.meta" profile_sha256)" \
    --arg store_manifest_sha "$(jq -r '.snapshots.store_manifest_sha256' "$rd/profile/profile.json")" \
    --arg mutation "$mutation" --arg retry "$retry" \
    --argjson cases "$cases_json" --argjson exit_code "$rc" \
    '{schema:"agentcrew.qa-fixture-receipt/v1",pack:$pack,selector:$selector,
      cases:$cases,source_sha:$source_sha,profile_sha256:$profile_sha,
      store_manifest_sha256:$store_manifest_sha,mutation:$mutation,retry:$retry,
      started_at:$started,completed_at:$completed,exit_code:$exit_code}' \
    >"$receipt_tmp"
  mv "$receipt_tmp" "$receipt_dir/$receipt_name"
  [ "$rc" = 0 ] \
    || ac_die "fixture selector $pack_id/$selector failed with status $rc (receipt: $receipt_dir/$receipt_name)"
  printf 'fixture selector completed: %s/%s cases=%s receipt=%s\n' \
    "$pack_id" "$selector" "$(IFS=,; printf '%s' "${case_ids[*]}")" "$receipt_dir/$receipt_name"
}

run_e2e_separate() {
  # run_e2e_separate <run-dir> <profile> <runtime> <command> - execute the E2E command
  # from the SEPARATE E2E worktree's product workdir, under the minimal env PLUS
  # the explicit endpoint-env mapping, refusing an undeclared developer .env.
  local rd="$1" profile="$2" runtime="$3" c="$4" wt workdir cwd k v ev rc
  wt="$(jq -r '.e2e_worktree // ""' "$runtime")"
  workdir="$(jq -r '.e2e.workdir // "."' "$profile")"; workdir="${workdir:-.}"
  [ -d "$wt" ] || ac_die "e2e: the leased E2E worktree is gone: $wt"
  cwd="$wt/$workdir"
  [ -d "$cwd" ] || ac_die "e2e: the configured product workdir does not exist in the E2E worktree: $cwd"
  # Undeclared-.env guard (design: a personal repository .env is NOT an approved
  # credential source, and the suite's own dotenv loader would read it
  # silently). Refuse rather than run under an unversioned environment; declared
  # fixtures ride the profile's fixture mechanism, never a stray .env.
  if [ -e "$cwd/.env" ]; then
    ac_die "e2e: an undeclared .env is present in the E2E workdir ($cwd/.env) - it is not an approved credential source and would silently change the run. Remove it, or declare its values through the profile's fixture mechanism."
  fi
  local -a qenv
  minimal_env "$rd" qenv
  # Explicit endpoint mapping: each configured NAME receives the runtime value
  # of the reference it maps to (e.g. BASE_URL -> $QA_BASE_URL), expanded
  # against the same minimal env - so the suite never assumes QA_BASE_URL is its
  # own interface. Values are captain-owned config, same trust as qa.e2e.command.
  while IFS="$(printf '\t')" read -r k v; do
    [ -n "$k" ] || continue
    ev="$(env -i "${qenv[@]}" sh -c "printf '%s' \"$v\"")"
    qenv+=("$k=$ev")
  done < <(jq -r '.e2e.endpoint_env // {} | to_entries[] | "\(.key)\t\(.value)"' "$profile")
  set +e
  ( cd "$cwd" && env -i "${qenv[@]}" sh -c "$c" ) 2>&1 | tee -a "$rd/logs/e2e.log"
  rc="${PIPESTATUS[0]}"
  set -e
  printf '%s cmd=e2e-separate exit=%s cwd=%s\n' "$(ac_iso)" "$rc" "$cwd" >>"$rd/logs/run.log"
  return "$rc"
}

# --- config / evidence / report ---------------------------------------------------

qa_key_path() {
  # qa_key_path <scope> <app> <dotted.key> - the whole of the key-level table,
  # as a pure string map:
  #   qa.serve / qa.health -> qa.scopes.<scope>.apps.<app>.<leaf>   (APP level)
  #   qa.seed              -> qa.scopes.<scope>.seed                (SCOPE level)
  #   everything else      -> unchanged                             (REPO level)
  # An EMPTY scope (a flat project) returns the key verbatim, which is what
  # makes flat behaviour byte-identical by STRUCTURE rather than by defending
  # it. The level split is the false-green test: a wrong `serve` boots a
  # different binary and a wrong `seed` migrates another schema, while a wrong
  # `health_timeout` merely costs time and a missing container kills boot
  # visibly - so only the first two move below the repo.
  local scope="$1" app="$2" key="$3"
  [ -n "$scope" ] || { printf '%s\n' "$key"; return 0; }
  case "$key" in
    qa.serve|qa.health) printf 'qa.scopes.%s.apps.%s.%s\n' "$scope" "$app" "${key#qa.}" ;;
    qa.seed) printf 'qa.scopes.%s.seed\n' "$scope" ;;
    *) printf '%s\n' "$key" ;;
  esac
}

cmd_config() {
  # THE rewrite point. Every script-consumed qa key already funnels through
  # here - serve, health, seed, cmd, and the mocks_compose read - so the level
  # table can be wrong in exactly one place, and those call sites change by
  # zero lines.
  require_run
  local rd v scope app
  rd="$(run_dir)"
  [ -s "$rd/config.yaml" ] || return 1
  scope="$(sed -n 's/^scope=//p' "$rd/run.meta" | head -n1)"
  app="$(sed -n 's/^app=//p' "$rd/run.meta" | head -n1)"
  v="$(ac_yaml_get "$rd/config.yaml" \
    "$(qa_key_path "$scope" "$app" "${1:?usage: ac-qa.sh config <dotted.key>}")")"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

cmd_config_proposal() {
  # cmd_config_proposal - render the fleet-home config SELF-DISCOVERY proposal,
  # the ONE contract shared by qa AND crew-ship: the agent DISCOVERS the repo's
  # keys (qa.serve/qa.health/
  # qa.e2e.command and the ship keys commands.*/auto_fix/ignore_patterns/
  # document.instructions/test.evidence/test.attestation/review.model -
  # from records/projects.md, package scripts, nx targets, docker-compose,
  # README/QA_RUNBOOK, the qa-store guide) and composes the FULL proposed
  # config on stdin. This verb only diffs it against the installed home config
  # into <repo>/.crew/config-proposals/<id>/. The project working tree is never
  # written and nothing here runs proposed commands. Each proposal records its
  # base hash; install refuses if another proposal landed first. Refuses empty,
  # duplicate-id, and no-op drafts.
  local id="" name home_path cur prop out patch base_sha
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id="${2:-}"; shift 2 ;;
      *) ac_die "usage: ac-qa.sh config-proposal [--id <proposal-id>]" ;;
    esac
  done
  [ -n "$id" ] || id="$(date +%Y%m%d-%H%M%S)-$$"
  case "$id" in *[!A-Za-z0-9._-]*|"") ac_die "invalid proposal id: $id" ;; esac
  name="$(ac_project_config_name "$repo")" || ac_die "config-proposal: cannot resolve the project name for $repo"
  home_path="$(ac_home)/projects/$name.yaml"
  out="$repo/.crew/config-proposals/$id"
  mkdir -p "$repo/.crew/config-proposals"
  mkdir "$out" 2>/dev/null || ac_die "config-proposal: id already exists: $id"
  prop="$out/proposed.yaml"
  patch="$out/proposal.patch"
  # Stage on a temp name: a refused draft (empty stdin) must never clobber a
  # proposal from a concurrent task.
  cat >"$prop.tmp.$$"
  [ -s "$prop.tmp.$$" ] || { rm -f "$prop.tmp.$$"; rmdir "$out" 2>/dev/null || true; ac_die "config-proposal: empty draft on stdin - compose the full proposed config first"; }
  mv "$prop.tmp.$$" "$prop"
  # Review diff vs the currently installed home config (or nothing).
  cur="$out/base.yaml"
  if ! ac_project_config_file "$repo" >/dev/null 2>&1; then
    : >"$cur"
  else
    cp "$(ac_project_config_file "$repo")" "$cur"
  fi
  base_sha="$(ac_config_sha256 "$cur")"
  printf '%s\n' "$base_sha" >"$out/base.sha256"
  printf '%s\n' "$name" >"$out/project"
  if diff -u --label current --label proposed "$cur" "$prop" >"$patch"; then
    rm -f "$cur" "$patch" "$prop" "$out/base.sha256" "$out/project"
    rmdir "$out" 2>/dev/null || true
    ac_die "config-proposal: draft is identical to the resolved config - nothing to propose"
  fi
  printf 'proposal_id: %s\nproposal written:\n  %s\n  %s\ntarget: %s\nbase_sha256: %s\ninstall (CHIEF, after review - never the drafting agent): bin/ac-qa.sh config-install %s\n' \
    "$id" "$patch" "$prop" "$home_path" "$base_sha" "$id"
}

cmd_config_install() {
  # cmd_config_install - the CHIEF-TIER install of a config-proposal draft
  # (captain order 2026-07-20: the captain touches nothing; the auto-tier
  # pattern applies - chief reviews + applies + receipts, captain vetoes).
  # LAW, not mechanics, keeps the roles apart: the DRAFTING agent (crewmate/
  # ship/qa pane) never runs this verb - a chief with fresh eyes does, after
  # reading the diff - because the home config is the pipeline's TRUSTED shell
  # source. Under a per-project lock, compare the proposal base hash with the
  # installed config, then atomically replace it. A concurrent proposal based on
  # an older config refuses instead of overwriting the winner. Keep one `.prev`
  # copy as the captain's veto net and print the room receipt.
  local id="${1:-}" name home_path out prop prev="" lock current base_sha current_sha tmp installed_sha
  [ $# -eq 1 ] || ac_die "usage: ac-qa.sh config-install <proposal-id>"
  case "$id" in *[!A-Za-z0-9._-]*|"") ac_die "invalid proposal id: $id" ;; esac
  name="$(ac_project_config_name "$repo")" || ac_die "config-install: cannot resolve the project name for $repo"
  home_path="$(ac_projects_dir)/$name.yaml"
  out="$repo/.crew/config-proposals/$id"
  prop="$out/proposed.yaml"
  [ -f "$prop" ] || ac_die "config-install: no staged proposal $id at $out"
  [ "$(cat "$out/project" 2>/dev/null || true)" = "$name" ] \
    || ac_die "config-install: proposal $id does not target project $name"
  base_sha="$(cat "$out/base.sha256" 2>/dev/null || true)"
  [ -n "$base_sha" ] || ac_die "config-install: proposal $id has no base hash"
  mkdir -p "$(dirname "$home_path")"
  lock="$home_path.lock"
  ac_lock_acquire "$lock" 30 || ac_die "config-install: lock timeout for $name"
  current="$(mktemp "$home_path.current.XXXXXX")"
  if [ -f "$home_path" ]; then cp "$home_path" "$current"; else : >"$current"; fi
  current_sha="$(ac_config_sha256 "$current")"
  if [ "$current_sha" != "$base_sha" ]; then
    rm -f "$current"
    ac_lock_release "$lock"
    ac_die "config-install: proposal $id conflicts with a newer installed config (base=$base_sha current=$current_sha); rebase the proposal"
  fi
  if [ -f "$home_path" ] && ! diff -q "$home_path" "$prop" >/dev/null 2>&1; then
    prev="$home_path.prev"
    cp "$home_path" "$prev"
  fi
  tmp="$(mktemp "$home_path.install.XXXXXX")"
  cp "$prop" "$tmp"
  mv "$tmp" "$home_path"
  installed_sha="$(ac_config_sha256 "$home_path")"
  rm -f "$current"
  ac_lock_release "$lock"
  printf '%s\n' "$installed_sha" >"$out/installed.sha256"
  printf 'installed proposal %s: %s -> %s%s\n' "$id" "$prop" "$home_path" "${prev:+ (previous kept at $prev)}"
  printf 'receipt (post to the family room): CONFIG-INSTALLED: %s sha256=%s proposal=%s - drafted by the task agent, reviewed + installed by the chief; captain veto: restore %s\n' \
    "$home_path" "$installed_sha" "$id" "${prev:-"(no previous config)"}"
}

cmd_store_dir() {
  # KNOWLEDGE STORE resolver (contract: header, which owns the ladder and the
  # refusal). Per-project, in the fleet home - durable across worktree resets
  # and clone re-creation. No require_run: the store outlives every run, so it
  # stays resolvable with none active (rung 1 is simply unavailable then).
  local scope dir meta store=""
  scope="$(repo_scope)"
  if [ -L "$current" ]; then
    # -f on run.meta, not the -L alone: readlink SUCCEEDS on a DANGLING link,
    # so a run dir deleted out-of-band would hand sed a missing file and kill
    # the whole resolution - including the AC_HOME rung that can still answer.
    meta="$(run_dir)/run.meta"
    [ -f "$meta" ] && store="$(sed -n 's/^store=//p' "$meta" | head -n1)"
  fi
  if [ -n "$store" ]; then
    dir="$store"
  elif [ -n "${AC_HOME:-}" ]; then
    dir="$(ac_data_dir)/qa-store/$scope"
  else
    ac_die "qa knowledge store unresolvable: no run recorded a store= path and this env has no AC_HOME.
The store is per-project and durable in the FLEET HOME (see KNOWLEDGE STORE in this script's header). Resolving it from here would answer with the agent-crew checkout that owns bin/, collapsing every fleet's store into one and silently reading an empty store - so it refuses instead. Your qa brief names the absolute path; re-start this run with it:
  ac-qa.sh start --target <ref> --task <id> --store <abs-store-dir>
Brief names no store? A sanctioned profiled round still carries an explicit empty versioned store manifest. Only an unprofiled diagnostic run may proceed without reusable store content; derive each case locally, record curation as skipped, and say so in the testplan and report. Never point --store at a pool worktree; it is disposable."
  fi
  case "$dir" in */profile/store) ;; *) mkdir -p "$dir/cases" ;; esac
  printf '%s\n' "$dir"
}

cmd_evidence_dir() {
  # Resolution: an explicit --evidence recorded at start (the qa brief bakes
  # the absolute task-data path - crewmate panes have no AC_HOME) > the task
  # data dir when --task was given AND AC_HOME resolves > the run dir.
  require_run
  local rd task dir
  rd="$(run_dir)"
  dir="$(sed -n 's/^evidence=//p' "$rd/run.meta" | head -n1)"
  if [ -z "$dir" ]; then
    task="$(sed -n 's/^task=//p' "$rd/run.meta" | head -n1)"
    if [ -n "$task" ] && [ -n "${AC_HOME:-}" ]; then
      dir="$(ac_task_dir "$task")/evidence"
    else
      dir="$rd/evidence"
    fi
  fi
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

cmd_fix_report() {
  # Render failed cases + fix-action findings as a fixer crewmate's contract.
  require_run
  local rd
  rd="$(run_dir)"
  printf '# QA fix contract (run %s)\n\n' "$(readlink "$current")"
  printf 'Target: %s\n\n## Failed cases\n\n' "$(sed -n 's/^target=//p' "$rd/run.meta")"
  printf '| id | tier | classification | evidence |\n|---|---|---|---|\n'
  awk -F'\t' '$3 == "fail" { printf "| %s | %s | %s | %s |\n", $1, $2, $4, $7 }' "$rd/cases.tsv"
  printf '\n## Findings (action=fix)\n\n'
  local f
  for f in "$rd/findings/"*.json; do
    [ -f "$f" ] || continue
    jq -r '.[] | select(.action == "fix")
           | "- [\(.severity)] \(.file // "-")\(if .line then ":" + (.line|tostring) else "" end): \(.description)"' "$f"
  done
  printf '\nRules: fix the product defects above; NEVER weaken a test to green; the qa run re-verifies after your fix.\n'
}

# shellcheck disable=SC2016  # this function emits MARKDOWN: backticks are code
# spans and $-less braces are literals - nothing here is meant to expand.
cmd_relay_report() {
  # The RELAY CONTRACT (header) rendered from this run's own state, for the actor
  # who CALLED qa - the fix-report shape. A rendered checklist arrives in that
  # actor's context at the moment of use, prefilled with the real verdict and the
  # literal phrases to grep the PR body for; the prose it replaces is what let a
  # PR body keep claiming "verified statically only" while the report sat on disk.
  # --repo AIMS it at the run: qa runs in its OWN worktree (EXECUTION SURFACE),
  # so the caller this contract addresses is NEVER in the tree holding the run
  # state. Without it the one actor the contract is written for cannot run it.
  local rd id outcome target full_flow
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$(cd "$2" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
                || ac_die "not a git repo: $2"
              qdir="$repo/.crew/qa"; current="$qdir/current"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  require_run
  rd="$(run_dir)"
  id="$(readlink "$current")"
  outcome="$(sed -n 's/^outcome=//p' "$rd/run.meta" | head -n1)"
  [ "$outcome" != running ] || ac_die "nothing to relay yet: ac-qa.sh finish first"
  target="$(sed -n 's/^target=//p' "$rd/run.meta" | head -n1)"
  full_flow="$(jq -r '.full_flow | join(",")' "$rd/testplan-manifest.json" 2>/dev/null || printf '-')"
  printf '# QA relay contract (run %s)\n\n' "$id"
  printf 'Verdict: **%s** | Target: %s | Full flow: `%s`\n\n' \
    "$outcome" "$target" "$full_flow"
  printf 'qa wrote to disk ONLY - it never posts or merges. YOU carry it outward,\n'
  printf 'and you carry the EVIDENCE, not just the verdict.\n\n'
  printf '## 1. Post to the PR (`gh pr comment <PR>`)\n\n'
  printf -- '- the envelope below, verbatim;\n'
  printf -- '- the case table below;\n'
  printf -- '- the authoritative on-disk report: %s\n' "$(cmd_evidence_dir)/../report.md"
  printf -- '- every visual artifact below, EMBEDDED in the comment, not just linked\n'
  printf -- '  (private repos: the crew-qa skill has the hosting recipe).\n'
  printf -- '- REQUIRED first: `ac-qa.sh fetch-check <url>...` on every embedded URL\n'
  printf -- '  above - post only once it exits 0. A URL that never serves is a 404\n'
  printf -- '  the captain would otherwise discover themselves.\n'
  printf -- '- Never paraphrase away a finding. "Ready for merge" only on a FINAL passed.\n\n'
  printf '## 2. CORRECT every claim this run supersedes\n\n'
  printf 'Re-read the PR body NOW and rewrite anything this run has made false.\n'
  printf 'Grep it for: "not run", "verified statically", "statically only",\n'
  printf '"tests pending", "not verified", "unverified", "verification pending".\n'
  printf 'A stale validation claim left standing is a lie the crew told the captain.\n\n'
  printf '## 3. Post to the room (captain + chief, one post serves both)\n\n'
  printf -- '`bin/ac-room.sh post <family> <you> "QA verdict=%s, N/N cases, evidence <path>"`\n' "$outcome"
  printf 'Post interim status each failing round, not just at the end.\n\n'
  printf '## Envelope\n\n```\n'
  qa_envelope "$rd"
  printf '```\n\n'
  printf '## Cases\n\n| id | tier | status | classification | grade | evidence | note | authority | repro |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
  # $8 is the note: a parked case's REASON is the half of the escalation the
  # caller must carry outward, so the table that leaves this script has it. A row
  # written before --note existed has no $8 - it renders as "-", which is why no
  # ledger migration is needed. $9/$10 (authority, repro) ride the same
  # mechanism: a pre-change row simply has neither.
  awk -F'\t' '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $6, $7, ($8 == "" ? "-" : $8), ($9 == "" ? "-" : $9), ($10 == "" ? "-" : $10) }' "$rd/cases.tsv"
  printf '\n## Visual artifacts (embed these)\n\n'
  # Re-validated, exactly like the envelope's count: never offer the caller a
  # dead path to embed under a QA_VISUALS that already dropped it.
  local live
  live="$(visuals_live "$rd")"
  if [ -n "$live" ]; then
    printf '%s\n' "$live" \
      | awk -F'\t' '{ printf "- %s (%s%s)%s\n", $1, $2, ($4 == "-" ? "" : ", case " $4), ($6 == "-" ? "" : " - " $6) }'
  else
    printf '(none on record)\n'
  fi
  printf '\nThe merge gate stays with the captain: this verdict informs it, never bypasses it.\n'
}

cmd_fetch_check() {
  # RELAY CONTRACT verb (header): HTTP-GET every embedded visual URL and
  # REFUSE on any non-200 or transport failure, naming the offending URL -
  # so a dead or unauthenticated embed is caught here, not discovered by
  # the captain as a 404 in the PR. Fail closed when no HTTP client exists.
  # Auth: the private-repo recipe this serves needs the caller's GitHub
  # token, so send one when discoverable - no new config key, no new flag.
  [ $# -ge 1 ] || ac_die "usage: ac-qa.sh fetch-check <url>..."
  command -v curl >/dev/null 2>&1 || ac_die "fetch-check: curl not found on PATH - cannot verify URLs"
  local token
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ] && command -v gh >/dev/null 2>&1; then
    token="$(gh auth token 2>/dev/null || true)"
  fi
  local auth=()
  [ -z "$token" ] || auth=(-H "Authorization: token $token")
  local url code
  for url in "$@"; do
    # -L: the raw-embed URL this serves (blob/<ref>/<path>?raw=true) redirects
    # before the content - unfollowed, a genuinely live URL reads as non-200.
    # --max-time: a hung fetch must not hang the caller relaying the report.
    code="$(curl -s -L --max-time 15 -o /dev/null -w '%{http_code}' "${auth[@]}" "$url" 2>/dev/null)" || code=""
    [ "$code" = "200" ] \
      || ac_die "fetch-check: $url returned ${code:-no response} (non-200 can also mean not authenticated for a private repo)"
  done
  printf 'fetch-check: %s url(s) OK\n' "$#"
}


qa_source_sha256() {
  # qa_source_sha256 <file> - the sha256 of a durable source file, or the
  # sha256 of empty input when the file is absent. A missing source (a flat
  # project has no repo-knowledge record) still records a STABLE, comparable
  # hash for the freeze->recheck, never an empty field that cannot be compared.
  local f="$1"
  if [ -f "$f" ]; then ac_config_sha256 "$f"; else printf '' | shasum -a 256 | awk '{print $1}'; fi
}

qa_profile_return() {
  # qa_profile_return <status> <detail> - print a structured non-ready PROFILE
  # RESOLVE status to stdout for the caller/chief and exit fail-closed. Called
  # only from cmd_agent BEFORE the ac-verify invocation, so a non-ready status
  # structurally creates no verifier pane. Reads cmd_agent's qa_profile_key /
  # qa_project locals through bash dynamic scope (single caller by design).
  printf 'QA_PROFILE_STATUS=%s\nprofile-status: %s\nprofile-key: %s\nprofile-detail: %s\n' \
    "$1" "$1" "${qa_profile_key:-${qa_project:-?}}" "$2"
  exit 1
}

qa_profile_ask() {
  # qa_profile_ask <question> <recommendation> - the ask-user status carrying
  # the chief->captain relay shape. A credential/secret-resolver decision is not
  # a mechanical one, so QA holds until the chief relays and records a decision.
  printf 'QA_PROFILE_STATUS=ask-user\nprofile-status: ask-user\nprofile-key: %s\nprofile-question: %s\nprofile-recommendation: %s\n' \
    "${qa_profile_key:-${qa_project:-?}}" "$1" "$2"
  exit 1
}

_qa_agent_selection_refuse() {
  # <class> <message> - cmd_agent's qa_selection_precedence channel: a
  # caller-usage mistake (missing --scope/--app) still dies the way it always
  # has, a genuine disagreement between the two durable sources reports as
  # the profile-resolve conflict status, and a declared-but-unconfigured
  # scope reports needs-profile - reads qa_profile_key/qa_project through the
  # same dynamic scope qa_profile_return already relies on.
  case "$1" in
    caller-error) ac_die "$2" ;;
    conflict) qa_profile_return profile-conflict "$2" ;;
    needs-profile) qa_profile_return needs-profile "$2" ;;
  esac
}

cmd_agent() {
  # Policy adapter only. ac-verify owns the exact-ref lease, fresh pane,
  # verdict capture, evidence export, failure preservation, and normal reap.
  local target="" task="" evidence="" brief="" home="" scope="" app="" qa_rule_select="" ship_run=""
  local scope_seen=0 app_seen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --evidence) evidence="$2"; shift 2 ;;
      --brief) brief="$2"; shift 2 ;;
      --home) home="$2"; shift 2 ;;
      --qa-rule) qa_rule_select="$2"; shift 2 ;;
      --ship-run) ship_run="$2"; shift 2 ;;
      --scope) [ "$scope_seen" = 0 ] || ac_die "--scope given twice ('$scope' then '$2') - name one scope"
               scope="$2"; scope_seen=1; shift 2 ;;
      --app) [ "$app_seen" = 0 ] || ac_die "--app given twice ('$app' then '$2') - name one app"
             app="$2"; app_seen=1; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$target" ] && [ -n "$task" ] \
    || ac_die "usage: ac-qa.sh agent --target <ref> --task <id> [--evidence <dir>] [--brief <path>] [--qa-rule <number|default>]"
  [ -n "$brief" ] && [ -f "$brief" ] \
    || ac_die "qa agent requires the durable QA charter via --brief <path>"

  local target_sha caller family verify task_slug round result previous combined verdict summary report
  local -a args
  target_sha="$(git -C "$repo" rev-parse --verify "${target}^{commit}" 2>/dev/null)" \
    || ac_die "target does not resolve to a commit: $target"
  caller="${AC_CREW_ID:-}"
  case "$caller" in ''|*[!a-z0-9-]*) ac_die "qa agent needs AC_CREW_ID from ac-spawn (got '${caller:-empty}')" ;; esac
  family="${AC_FLEET_SCOPE:-}"
  if [ -z "$family" ]; then
    case "$caller" in *-implement) family=${caller%-implement} ;; *) family=$caller ;; esac
  fi
  verify="${AC_VERIFY_BIN:-$(dirname "$0")/ac-verify.sh}"
  [ -x "$verify" ] || ac_die "verifier facade is not executable: $verify"

  mkdir -p "$qdir"
  task_slug="$(sanitize_compose "$task")"
  evidence="${evidence:-$qdir/agent-$task_slug-evidence}"
  mkdir -p "$evidence"
  evidence="$(cd "$evidence" && pwd -P)"
  round=1
  while [ -e "$qdir/agent-$task_slug-r$round.json" ] \
    || [ -e "$qdir/agent-$task_slug-r$round.profile" ]; do
    round=$((round + 1))
  done
  result="$qdir/agent-$task_slug-r$round.json"
  previous="$qdir/agent-$task_slug-r$((round - 1)).json"
  combined="$qdir/agent-$task_slug-r$round.brief.md"
  report="$(cd "$(dirname "$brief")" && pwd -P)/report.md"

  # --- PROFILE RESOLVE (fail-closed preflight) --------------------------------
  # Compile, validate, and atomically freeze the complete runtime bundle from
  # project config, repo-knowledge scope membership, the selected store
  # snapshot, exact source/optional E2E refs, and any caller-selected panes.qa
  # routing receipt BEFORE ac-verify leases a worktree or spawns a pane. Only
  # profile-ready reaches the verifier, so every non-ready status creates no
  # pane. The same bundle covers flat, scoped, and separate-E2E profiles.
  local qa_home qa_project profile bundle bundle_tmp qa_profile_key=""
  local cfg cfg_sha know know_sha scopes_out scopes_rc
  local serve health seed health_timeout fx_profile fx_resolver
  local config_snapshot_sha scopes_snapshot_sha store_manifest_sha
  local store_source store_manifest store_file store_rel store_hash
  local dispatch_cfg dispatch_select routing_json="" qa_pane_profile=""
  local qa_harness="" qa_model="" qa_effort="" available_rules=""
  local e2e_repo="" e2e_repo_path="" e2e_ref="" e2e_ref_policy="" e2e_workdir="" e2e_command="" e2e_fixture=""
  local e2e_endpoint_json="{}" e2e_prefix ep_prefix ek
  qa_home="$(ac_home_resolve "$home" "$repo")"
  if [ -z "$qa_home" ]; then
    qa_home="$(ac_root)"
    printf 'notice: no fleet home named (--home) and none in the environment - resolving the profile against %s\n' "$qa_home" >&2
  fi
  qa_project="$(ac_project_config_name "$repo")" || ac_die "cannot resolve the project config name for $repo"
  bundle="$qdir/agent-$task_slug-r$round.profile"
  dispatch_cfg="$qa_home/config/crew-dispatch.json"
  dispatch_select="$bin_dir/ac-dispatch-select.sh"

  # Routed panes.qa is caller judgment, never pane judgment. The dispatcher
  # validates the shared when/use/why grammar and resolves exactly the selector
  # supplied here. Static panes.qa remains on its existing downstream rung.
  if [ -f "$dispatch_cfg" ]; then
    jq -e . "$dispatch_cfg" >/dev/null 2>&1 \
      || ac_die "invalid JSON in QA dispatch config: $dispatch_cfg"
  fi
  if [ -f "$dispatch_cfg" ] \
    && jq -e '.panes.qa | type == "object" and has("rules")' "$dispatch_cfg" >/dev/null 2>&1; then
    if [ -z "$qa_rule_select" ]; then
      available_rules="$(AC_HOME="$qa_home" "$dispatch_select" --pane qa --list 2>&1)" \
        || ac_die "routed panes.qa is invalid: $available_rules"
      ac_die "routed panes.qa requires --qa-rule <number|default> before pane placement. Available rules:
$available_rules"
    fi
    qa_pane_profile="$(AC_HOME="$qa_home" "$dispatch_select" --pane qa --rule "$qa_rule_select")"
    routing_json="$(AC_HOME="$qa_home" "$dispatch_select" --pane qa --receipt "$qa_rule_select")"
    read -r qa_harness qa_model qa_effort <<EOF
$qa_pane_profile
EOF
    qa_harness="${qa_harness#harness=}"
    qa_model="${qa_model#model=}"
    qa_effort="${qa_effort#effort=}"
  else
    [ -z "$qa_rule_select" ] \
      || ac_die "--qa-rule is valid only when config/crew-dispatch.json defines routed panes.qa.rules[]"
    if [ -f "$dispatch_cfg" ] && jq -e '.panes | has("qa")' "$dispatch_cfg" >/dev/null 2>&1; then
      AC_HOME="$qa_home" "$dispatch_select" --pane qa >/dev/null
    fi
  fi

  # The scope map first: an ambiguous durable record is a conflict, never a
  # silent degrade to flat (ac_knowledge_scopes exits 2 on ambiguity).
  scopes_rc=0
  scopes_out="$(AC_HOME="$qa_home" ac_knowledge_scopes "$repo" 2>/dev/null)" || scopes_rc=$?
  [ "$scopes_rc" = 0 ] \
    || qa_profile_return profile-conflict "the repo-knowledge scope map is ambiguous - resolve it (bin/ac-know.sh) before a profile can compile"

  # The two durable sources. Absent project config is absent durable knowledge.
  # A DIRECT guard call first, so an ambiguous dual copy fails the run CLOSED
  # with the resolver's own migration message (its ac_die exits the process) -
  # a $(...) capture would swallow it and mis-report a genuine dual copy as
  # needs-profile (mirror of ac_qa_required, ac-qa-lib.sh).
  know="$(AC_HOME="$qa_home" ac_knowledge_file "$repo" 2>/dev/null || true)"
  AC_HOME="$qa_home" ac_project_config_file "$repo" >/dev/null || true
  cfg="$(AC_HOME="$qa_home" ac_project_config_file "$repo" 2>/dev/null)" \
    || qa_profile_return needs-profile "no project config at the canonical home path (\$AC_HOME/projects/$qa_project.yaml) - the chief installs one (ac-qa.sh config-proposal / config-install)"

  health_timeout="$(ac_yaml_get "$cfg" qa.health_timeout)"
  case "$health_timeout" in ''|*[!0-9]*) health_timeout=60 ;; esac
  fx_profile="$(ac_yaml_get "$cfg" qa.fixtures.profile)"
  fx_resolver="$(ac_yaml_get "$cfg" qa.fixtures.resolver)"

  # THE precedence chain (F27 - shared with cmd_start's qa_validate_selection
  # via qa_selection_precedence): mode detection, the closed scope list, then
  # app membership. scopes_out is written to a scratch file only so the chain
  # can use the same file-based awk/cut idiom qa_validate_selection's frozen
  # copy already uses.
  local scopes_scratch; scopes_scratch="$(mktemp)"
  printf '%s\n' "$scopes_out" >"$scopes_scratch"
  qa_selection_precedence "$scopes_scratch" "$cfg" "$scope" "$app" _qa_agent_selection_refuse
  rm -f "$scopes_scratch"

  if [ -z "$scope" ]; then
    # FLAT: no scopes on either side (qa_selection_precedence already proved
    # this - a lone selector would have refused there).
    qa_profile_key="$qa_project"
    serve="$(ac_yaml_get "$cfg" qa.serve)"
    health="$(ac_yaml_get "$cfg" qa.health)"
    seed="$(ac_yaml_get "$cfg" qa.seed)"
    [ -n "$serve" ] && [ -n "$health" ] \
      || qa_profile_return needs-profile "the flat project config is missing the service contract (need qa.serve and qa.health) - the chief completes it before QA runs"
  else
    # SCOPED: qa_selection_precedence already proved scope/app are declared,
    # in the closed list, mutually consistent, and configured.
    qa_profile_key="$qa_project/$scope/$app"
    serve="$(ac_yaml_get "$cfg" "qa.scopes.$scope.apps.$app.serve")"
    health="$(ac_yaml_get "$cfg" "qa.scopes.$scope.apps.$app.health")"
    seed="$(ac_yaml_get "$cfg" "qa.scopes.$scope.seed")"
    [ -n "$serve" ] && [ -n "$health" ] && [ -n "$seed" ] \
      || qa_profile_return needs-profile "scoped profile $qa_profile_key is missing required mechanics (need qa.scopes.$scope.apps.$app.serve + .health and qa.scopes.$scope.seed) - the chief completes the config"
  fi

  # A declared secret resolver with no authorized fixture profile is not a
  # mechanical decision - hold for the chief/captain. Only the reference NAME is
  # read here; a raw secret value never enters the profile.
  if [ -n "$fx_resolver" ] && [ -z "$fx_profile" ]; then
    qa_profile_ask \
      "Secret resolver '$fx_resolver' is declared for $qa_profile_key but no authorized fixture profile is named (qa.fixtures.profile). Which fixture profile should QA use?" \
      "Name an authorized safe fixture profile in qa.fixtures.profile, or confirm this target needs no secret-resolved fixtures."
  fi

  # --- E2E resolution (Story 3: separate-E2E-repo dual-ref) -------------------
  # When qa.e2e.repo is configured, this profile drives a SEPARATE E2E suite
  # from its OWN repository at an exact frozen SHA. The resolver freezes the
  # local repo path + exact E2E ref here; ac-verify leases the second worktree,
  # and ac-qa's e2e step runs from the product workdir with the endpoint-env
  # mapping. Absent qa.e2e.repo, the profile stays single-repo (unchanged).
  e2e_repo="$(ac_yaml_get "$cfg" qa.e2e.repo)"
  if [ -n "$e2e_repo" ]; then
    # The E2E repository is an EXTERNAL actor: its local clone must already
    # exist, resolved like any project (a name under $AC_HOME/projects, or a
    # path). An absent clone is needs-profile, never a silent skip.
    e2e_repo_path="$(AC_HOME="$qa_home" ac_project_dir "$e2e_repo" 2>/dev/null)" \
      || qa_profile_return needs-profile "qa.e2e.repo '$e2e_repo' does not resolve to a local git repository (a project name under \$AC_HOME/projects, or an absolute path) - clone it before QA can lease the E2E worktree"
    e2e_ref_policy="$(ac_yaml_get "$cfg" qa.e2e.ref_policy)"; e2e_ref_policy="${e2e_ref_policy:-configured-default-branch-head}"
    case "$e2e_ref_policy" in
      configured-default-branch-head)
        e2e_ref="$(git -C "$e2e_repo_path" rev-parse --verify "$(ac_default_branch "$e2e_repo_path")^{commit}" 2>/dev/null)" \
          || qa_profile_return needs-profile "cannot resolve the E2E default-branch head in $e2e_repo_path - the E2E clone has no resolvable default branch" ;;
      *) qa_profile_return profile-conflict "unsupported qa.e2e.ref_policy '$e2e_ref_policy' for $qa_profile_key (only configured-default-branch-head is supported)" ;;
    esac
    # workdir / command / fixture_profile: scope-level first (a scoped project
    # names its product suite there), then the repo-level default. workdir
    # defaults to the E2E repo root.
    if [ -n "$scope" ]; then e2e_prefix="qa.scopes.$scope.e2e"; else e2e_prefix="qa.e2e"; fi
    e2e_workdir="$(ac_yaml_get "$cfg" "$e2e_prefix.workdir")"
    [ -n "$e2e_workdir" ] || e2e_workdir="$(ac_yaml_get "$cfg" qa.e2e.workdir)"
    e2e_workdir="${e2e_workdir:-.}"
    e2e_command="$(ac_yaml_get "$cfg" "$e2e_prefix.command")"
    [ -n "$e2e_command" ] || e2e_command="$(ac_yaml_get "$cfg" qa.e2e.command)"
    [ -n "$e2e_command" ] \
      || qa_profile_return needs-profile "qa.e2e.repo is set for $qa_profile_key but no E2E command is configured (qa.e2e.command) - the chief completes it"
    e2e_fixture="$(ac_yaml_get "$cfg" "$e2e_prefix.fixture_profile")"
    [ -n "$e2e_fixture" ] || e2e_fixture="$(ac_yaml_get "$cfg" qa.e2e.fixture_profile)"
    # endpoint_env: an explicit name->value map. Values are runtime references
    # (e.g. $QA_BASE_URL) expanded against the minimal env at e2e run time, so
    # the E2E suite never has to assume QA_BASE_URL is its own interface.
    ep_prefix="$e2e_prefix.endpoint_env"
    [ -n "$(ac_yaml_keys "$cfg" "$ep_prefix")" ] || ep_prefix="qa.e2e.endpoint_env"
    for ek in $(ac_yaml_keys "$cfg" "$ep_prefix"); do
      e2e_endpoint_json="$(jq -c --arg k "$ek" --arg v "$(ac_yaml_get "$cfg" "$ep_prefix.$ek")" \
        '. + {($k): $v}' <<<"$e2e_endpoint_json")"
    done
  fi

  # FREEZE the complete runtime bundle under a private name. Only the final
  # validated directory is atomically published for verifier handoff.
  cfg_sha="$(qa_source_sha256 "$cfg")"
  know_sha="$(qa_source_sha256 "$know")"
  bundle_tmp="$(mktemp -d "$qdir/.agent-$task_slug-r$round.profile.tmp.XXXXXX")" \
    || ac_die "could not stage the qa profile bundle under $qdir"
  mkdir -p "$bundle_tmp/store" \
    || { rm -rf "$bundle_tmp"; ac_die "could not stage the qa profile store"; }
  cp "$cfg" "$bundle_tmp/config.yaml" \
    || { rm -rf "$bundle_tmp"; ac_die "could not freeze project config into the qa profile bundle"; }
  if [ -n "$scopes_out" ]; then
    printf '%s\n' "$scopes_out" >"$bundle_tmp/scopes.tsv"
  else
    : >"$bundle_tmp/scopes.tsv"
  fi
  config_snapshot_sha="$(ac_config_sha256 "$bundle_tmp/config.yaml")"
  scopes_snapshot_sha="$(ac_config_sha256 "$bundle_tmp/scopes.tsv")"

  store_source="$qa_home/data/qa-store/$qa_project"
  store_manifest="$bundle_tmp/store/manifest.json"
  jq -n '{schema:"agentcrew.qa-store-snapshot/v1",entries:[]}' >"$store_manifest"
  if [ -d "$store_source" ]; then
    [ -z "$(find "$store_source" -type l -print -quit)" ] \
      || { rm -rf "$bundle_tmp"; ac_die "qa store contains a symlink and cannot be frozen safely: $store_source"; }
    while IFS= read -r store_file; do
      [ -n "$store_file" ] || continue
      store_rel="${store_file#"$store_source"/}"
      [ "$store_rel" != manifest.json ] || continue
      case "$store_rel" in /*|..|../*|*/../*|*/..|*$'\t'*|*$'\n'*)
        rm -rf "$bundle_tmp"
        ac_die "qa store contains an unsafe relative path: $store_rel" ;;
      esac
      mkdir -p "$bundle_tmp/store/$(dirname "$store_rel")"
      cp "$store_file" "$bundle_tmp/store/$store_rel" \
        || { rm -rf "$bundle_tmp"; ac_die "could not freeze qa store entry: $store_rel"; }
      store_hash="$(ac_config_sha256 "$bundle_tmp/store/$store_rel")"
      qa_store_manifest_merge "$store_manifest" "$store_rel" "$store_hash" \
        || { rm -rf "$bundle_tmp"; ac_die "could not record qa store entry: $store_rel"; }
    done < <(find "$store_source" -type f -print | LC_ALL=C sort)
  fi
  store_manifest_sha="$(ac_config_sha256 "$store_manifest")"

  # FREEZE the ship test receipt (header: SHIP TEST RECEIPT READ). The caller
  # names the intended run EXPLICITLY; the mutable ship `current` symlink is
  # never consulted, because a symlink that moved after delivery would let a
  # later, unrelated suite run stand in for this target's evidence. Every
  # non-qualifying shape - omitted flag, missing run, another target, an
  # interrupted or failing execution - normalizes to one closed reason here,
  # so the pane reads a receipt rather than an absence it must interpret.
  local ship_receipt_src="" ship_status ship_receipt_sha ship_src_sha
  if [ -n "$ship_run" ]; then
    case "$ship_run" in
      *[!A-Za-z0-9._-]*|'') ac_die "--ship-run must be a ship run id ([A-Za-z0-9._-]): '$ship_run'" ;;
    esac
    ship_receipt_src="$repo/.crew/ship/$ship_run/test/receipt.env"
  fi
  ship_src_sha="$(qa_source_sha256 "$ship_receipt_src")"
  ship_status="$(ac_qa_ship_receipt_status "$ship_receipt_src" "$target_sha")"
  mkdir -p "$bundle_tmp/ship" \
    || { rm -rf "$bundle_tmp"; ac_die "could not stage the frozen ship test receipt"; }
  {
    printf 'schema=agentcrew.ship-test-receipt/v1\n'
    printf 'source_sha=%s\n' "$target_sha"
    printf 'qualification=%s\n' "${ship_status%%:*}"
    printf 'reason=%s\n' "${ship_status#*:}"
    printf 'ship_run=%s\n' "${ship_run:--}"
    printf 'command_sha256=%s\n' "$([ -f "$ship_receipt_src" ] && ac_meta_get "$ship_receipt_src" command_sha256 || printf '-')"
    printf 'output_sha256=%s\n' "$([ -f "$ship_receipt_src" ] && ac_meta_get "$ship_receipt_src" output_sha256 || printf '-')"
    printf 'started_at=%s\n' "$([ -f "$ship_receipt_src" ] && ac_meta_get "$ship_receipt_src" started_at || printf '-')"
    printf 'completed_at=%s\n' "$([ -f "$ship_receipt_src" ] && ac_meta_get "$ship_receipt_src" completed_at || printf '-')"
    printf 'exit_code=%s\n' "$([ -f "$ship_receipt_src" ] && ac_meta_get "$ship_receipt_src" exit_code || printf '-')"
  } >"$bundle_tmp/ship/test-receipt.env"
  ship_receipt_sha="$(ac_config_sha256 "$bundle_tmp/ship/test-receipt.env")"

  profile="$bundle_tmp/profile.json"
  jq -n \
    --arg key "$qa_profile_key" --arg project "$qa_project" \
    --arg source_repo "$qa_project" --arg source_ref "$target_sha" \
    --arg scope "$scope" --arg app "$app" \
    --arg serve "$serve" --arg health "$health" --arg seed "$seed" \
    --argjson health_timeout "$health_timeout" \
    --arg fx_profile "$fx_profile" --arg fx_resolver "$fx_resolver" \
    --arg cfg_path "$cfg" --arg cfg_sha "$cfg_sha" \
    --arg know_path "$know" --arg know_sha "$know_sha" \
    --arg config_snapshot_sha "$config_snapshot_sha" \
    --arg scopes_snapshot_sha "$scopes_snapshot_sha" \
    --arg store_manifest_sha "$store_manifest_sha" \
    --arg ship_receipt_sha "$ship_receipt_sha" \
    --argjson routing "${routing_json:-null}" \
    --arg e2e_repo "$e2e_repo" --arg e2e_repo_path "$e2e_repo_path" \
    --arg e2e_ref "$e2e_ref" --arg e2e_ref_policy "$e2e_ref_policy" \
    --arg e2e_workdir "$e2e_workdir" --arg e2e_command "$e2e_command" \
    --arg e2e_fixture "$e2e_fixture" --argjson e2e_endpoint "$e2e_endpoint_json" \
    --arg resolved_at "$(ac_iso)" '
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
    ' >"$profile" \
    || ac_die "could not compile the qa profile: $profile"

  # profile_sha256: the canonical profile hash the dual-ref verdict binds. It
  # covers concrete execution values, durable-source hashes, and exact
  # source/E2E refs, but EXCLUDES volatile allocation paths (the local E2E
  # clone path) and the resolve timestamp - so a re-resolve at the same refs
  # and config yields an identical hash. Stored top-level and therefore
  # deleted from its own canonical payload.
  local profile_sha
  profile_sha="$(jq -S '
      del(.profile_sha256,
          .provenance.resolved_at,
          .provenance.project_config_path,
          .provenance.repo_knowledge_path,
          .e2e.repo_path)
    ' "$profile" \
    | shasum -a 256 | awk '{print $1}')"
  if ! jq --arg psha "$profile_sha" '. + { profile_sha256: $psha }' \
      "$profile" >"$profile.tmp" \
    || ! mv "$profile.tmp" "$profile"; then
    ac_die "could not record the profile hash: $profile"
  fi

  # A durable source that changes after freeze but before spawn is stale: the
  # frozen hash no longer matches, so abort and re-resolve rather than run an
  # obsolete profile. AC_QA_PROFILE_RECHECK_HOOK is the deterministic test seam
  # for that TOCTOU window; it is unset in every normal run.
  # TEST SEAM, double-keyed (audit-f8): same contract as ac-curate.sh's
  # snapshot hook - the exec additionally requires AC_TEST_HOOKS=1 (exported
  # by tests/helpers.sh and nothing else), so one inherited env var cannot
  # make a production qa run execute an arbitrary file.
  if [ "${AC_TEST_HOOKS:-}" = 1 ] && [ -n "${AC_QA_PROFILE_RECHECK_HOOK:-}" ] \
    && [ -x "${AC_QA_PROFILE_RECHECK_HOOK}" ]; then
    "${AC_QA_PROFILE_RECHECK_HOOK}" "$cfg" "$know" || true
  fi
  { [ "$(qa_source_sha256 "$cfg")" = "$cfg_sha" ] && [ "$(qa_source_sha256 "$know")" = "$know_sha" ] \
    && [ "$(qa_source_sha256 "$ship_receipt_src")" = "$ship_src_sha" ]; } \
    || { rm -rf "$bundle_tmp"; qa_profile_return profile-stale "a durable source changed between freeze and spawn (project config, repo-knowledge, or the selected ship test receipt no longer matches the frozen profile) - re-resolve"; }
  ac_qa_bundle_validate "$profile" "$target_sha" \
    || { rm -rf "$bundle_tmp"; ac_die "staged qa profile bundle is invalid: $AC_QA_BUNDLE_ERROR"; }
  mv "$bundle_tmp" "$bundle" \
    || { rm -rf "$bundle_tmp"; ac_die "could not atomically publish qa profile bundle: $bundle"; }
  profile="$bundle/profile.json"
  # --- end PROFILE RESOLVE ----------------------------------------------------

  {
    printf '# QA verifier brief\n\n'
    # shellcheck disable=SC2016  # backticks are Markdown delimiters.
    printf 'Exact target: `%s`\n\n' "$target_sha"
    printf 'Run the QA pipeline from the verifier worktree with this command shape:\n\n'
    # shellcheck disable=SC2016  # backticks are Markdown delimiters.
    printf '`%s/ac-qa.sh start --target %s --task %s --evidence %s%s%s%s`\n' \
      "$bin_dir" "$target_sha" "$task" "$evidence/evidence" \
      "${home:+ --home $home}" "${scope:+ --scope $scope}" "${app:+ --app $app}"
    if [ -n "$brief" ]; then
      printf '\n## Acceptance input\n\n'
      cat "$brief"
      printf '\n'
    fi
  } >"$combined"

  args=(qa --repo "$repo" --ref "$target_sha" --family "$family"
        --caller "$caller" --brief "$combined" --output "$result"
        --evidence-dir "$evidence" --profile "$profile" --report "$report")
  if [ -n "$qa_harness" ]; then
    args+=(--harness "$qa_harness")
    [ -z "$qa_model" ] || args+=(--model "$qa_model")
    [ -z "$qa_effort" ] || args+=(--effort "$qa_effort")
  fi
  [ "$round" -le 1 ] || [ ! -s "$previous" ] || args+=(--history "$previous")
  "$verify" "${args[@]}" >/dev/null \
    || ac_die "independent QA round $round failed; inspect verifier state and $result"
  jq -e --arg ref "$target_sha" '
    type == "object"
    and (.verdict as $v | ["passed","failed","unverifiable"] | index($v) != null)
    and (.summary | type) == "string"
    and (.evidence | type) == "array"
    and (.report | type) == "string" and (.report | length) > 0
    and (.verified_ref == $ref)
  ' "$result" >/dev/null \
    || ac_die "QA verifier result is invalid or does not bind the exact target: $result"
  [ "$(jq -r '.report' "$result")" = "$report" ] \
    && [ -s "$report" ] \
    && [ "$(sed -n '1p' "$report")" = "verdict: $(jq -r '.verdict' "$result")" ] \
    || ac_die "QA verifier result has no matching canonical stage report: $report"
  [ -s "$evidence/verdict.json" ] && [ -s "$evidence/relay-report.md" ] \
    || ac_die "QA verifier returned without durable verdict and relay evidence: $evidence"

  verdict="$(jq -r '.verdict' "$result")"
  summary="$(jq -r '.summary' "$result")"
  printf 'verdict: %s\nQA_VERDICT=%s\nQA_VERIFIED_REF=%s\nQA_REPORT=%s\nsummary: %s\n' \
    "$verdict" "$verdict" "$target_sha" "$report" "$summary"
  printf 'QA_PROFILE_STATUS=profile-ready\nprofile-key: %s\n' "$qa_profile_key"
  printf '\nqa-agent round %s evidence=%s profile=%s\n' "$round" "$evidence" "$profile"
}

cmd_status() {
  require_run
  local rd
  rd="$(run_dir)"
  printf 'run %s\n' "$(readlink "$current")"
  sed -n 's/^/  /p' "$rd/run.meta"
  printf '  steps:\n'
  awk -F'\t' '{ printf "    %-10s %s%s\n", $1, $2, ($3 > 0 ? " (rounds " $3 ")" : "") }' "$rd/steps.tsv"
  if [ -s "$rd/cases.tsv" ]; then
    printf '  cases: %s pass / %s fail / %s unverifiable\n' \
      "$(awk -F'\t' '$3=="pass"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
      "$(awk -F'\t' '$3=="fail"' "$rd/cases.tsv" | wc -l | tr -d ' ')" \
      "$(awk -F'\t' '$3=="unverifiable"' "$rd/cases.tsv" | wc -l | tr -d ' ')"
  fi
  # Preview the visual-evidence gate: learning at finish that a two-hour run
  # cannot pass is the failure this line exists to prevent.
  local nvis
  nvis="$(visuals_valid "$rd")"
  if [ "$nvis" -gt 0 ]; then
    printf '  visuals: %s on record\n' "$nvis"
  else
    printf '  visuals: none - finish passed will refuse\n'
  fi
  return 0
}

cmd_finish() {
  require_run
  local outcome="${1:-}" retry_reason="" rd total passed failed unver flaky visuals verdict
  shift 2>/dev/null || true
  case "$outcome" in passed|failed|unverifiable|cancelled) ;; *) ac_die "usage: ac-qa.sh finish <passed|failed|unverifiable|cancelled>" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --retry-reason) retry_reason="${2:-}"; shift 2 ;;
      *) ac_die "usage: ac-qa.sh finish <passed|failed|unverifiable|cancelled> [--retry-reason <context-limit|tool-limit|capability-limit>]" ;;
    esac
  done
  if [ -n "$retry_reason" ]; then
    [ "$outcome" = unverifiable ] \
      || ac_die "--retry-reason is valid only with 'finish unverifiable'"
    case "$retry_reason" in context-limit|tool-limit|capability-limit) ;; *)
      ac_die "invalid --retry-reason '$retry_reason' (expected context-limit|tool-limit|capability-limit)" ;;
    esac
  fi
  rd="$(run_dir)"
  # A pass refusal must leave evidence-producing state alive. Adjudicate before
  # teardown, outcome mutation, or marker publication.
  if [ "$outcome" = passed ]; then
    assert_target_checkout "$(sed -n 's/^target_sha=//p' "$rd/run.meta" | head -n1)"
    qa_finish_gate "$rd"
  elif [ "$outcome" = failed ] || [ "$outcome" = unverifiable ]; then
    cmd_step verdict completed --note "recorded terminal outcome $outcome" >/dev/null
  fi
  [ -z "$retry_reason" ] || ac_meta_set "$rd/run.meta" retry_reason "$retry_reason"

  # Teardown after the pass gate: the serve PROCESS GROUP (serve ran under set
  # -m, so pgid == recorded pid), then compose. kill -0 first: never signal a
  # recycled pid.
  if [ -f "$rd/serve.pid" ]; then
    local spid
    spid="$(cat "$rd/serve.pid")"
    if [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null; then
      kill -TERM -- "-$spid" 2>/dev/null || kill -TERM "$spid" 2>/dev/null || true
    fi
    rm -f "$rd/serve.pid"
  fi
  if command -v docker >/dev/null 2>&1; then
    docker compose -p "$(compose_project)" down -v --remove-orphans 2>/dev/null || true
  fi
  read -r total passed failed unver flaky visuals <<<"$(qa_counts "$rd")"
  # The ledger pass invariants (failed/unver/empty/visual-floor) now live at
  # the TOP of qa_finish_gate, before the runtime-gate receipt and teardown;
  # this read only feeds the envelope below.
  verdict="$outcome"
  sed -i '' -e "s/^outcome=.*/outcome=$verdict/" "$rd/run.meta" 2>/dev/null \
    || sed -i -e "s/^outcome=.*/outcome=$verdict/" "$rd/run.meta"
  printf '%s finish outcome=%s\n' "$(ac_iso)" "$verdict" >>"$rd/logs/run.log"
  # Only a sanctioned profiled round can publish a merge attestation. Direct
  # starts remain useful diagnostics, but explicitly export `none/unprofiled`.
  if [ "$verdict" = passed ]; then
    if qa_publish_attestation "$rd" "$passed" "$total"; then
      ac_meta_set "$rd/run.meta" attestation v2
      ac_meta_set "$rd/run.meta" attestation_reason ""
    else
      local publish_rc=$?
      if [ "$publish_rc" = 2 ]; then
        ac_meta_set "$rd/run.meta" attestation none
        ac_meta_set "$rd/run.meta" attestation_reason unprofiled
      else
        ac_die "could not publish the validated v2 passing attestation"
      fi
    fi
  else
    ac_meta_set "$rd/run.meta" attestation none
    ac_meta_set "$rd/run.meta" attestation_reason "outcome-$verdict"
  fi
  # Retire the live dashboard (belt-and-suspenders; it also self-closes).
  if [ -f "$rd/watch.pane" ] && command -v herdr >/dev/null 2>&1; then
    herdr --session "${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}" \
      pane close "$(cat "$rd/watch.pane")" >/dev/null 2>&1 || true
    rm -f "$rd/watch.pane"
  fi
  qa_envelope "$rd"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  step) shift; cmd_step "$@" ;;
  case) shift; cmd_case "$@" ;;
  visual) shift; cmd_visual "$@" ;;
  findings) shift; cmd_findings "$@" ;;
  testplan-amend) shift; cmd_testplan_amend "$@" ;;
  fixture) shift; cmd_fixture "$@" ;;
  harness-classify) shift; cmd_harness_classify "$@" ;;
  regression-proposal) shift; cmd_regression_proposal "$@" ;;
  curation) shift; cmd_curation "$@" ;;
  store-install) shift; cmd_store_install "$@" ;;
  infra) shift; cmd_infra "$@" ;;
  baseline) shift; cmd_baseline "$@" ;;
  serve) shift; cmd_serve "$@" ;;
  health) shift; cmd_health "$@" ;;
  boundary-run) shift; cmd_boundary_run "$@" ;;
  boundary-register) shift; cmd_boundary_register "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  cmd) shift; cmd_cmd "$@" ;;
  config) shift; cmd_config "$@" ;;
  config-proposal) shift; cmd_config_proposal "$@" ;;
  config-install) shift; cmd_config_install "$@" ;;
  evidence-dir) shift; cmd_evidence_dir "$@" ;;
  store-dir) shift; cmd_store_dir "$@" ;;
  fix-report) shift; cmd_fix_report "$@" ;;
  relay-report) shift; cmd_relay_report "$@" ;;
  fetch-check) shift; cmd_fetch_check "$@" ;;
  agent) shift; cmd_agent "$@" ;;
  status) shift; cmd_status "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  *) ac_die "usage: ac-qa.sh <start|step|case|visual|findings|testplan-amend|fixture|harness-classify|regression-proposal|curation|store-install|infra|baseline|serve|health|boundary-run|boundary-register|seed|cmd|config|config-proposal|config-install|evidence-dir|store-dir|fix-report|relay-report|fetch-check|agent|status|finish>" ;;
esac
