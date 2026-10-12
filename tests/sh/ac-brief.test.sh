#!/usr/bin/env bash
# ac-brief.test.sh - brief scaffolding: ship and scout templates, overwrite
# refusal, id validation.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# staged is a TIME-EXPENSIVE flow now, and mode is per-task: the widget family
# rows below are PINNED on the ledger - the durable pre-consent path - so
# these scaffolds run without a per-call declaration, which is exactly the
# half of the escalation gate that never asks about what the ledger pins.
mkdir -p "$AC_HOME/records"
cat >>"$AC_HOME/records/backlog.md" <<'PINEOF'
## Queued
- [ ] widget [src:cap flow:staged mode:crew-ship rev:yes qa:no] - the widget family, pinned by the captain (repo: myproj)
- [ ] widget-spec [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-arch [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-plan [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-qa [src:cap flow:staged mode:local-only rev:yes qa:yes] - pinned (repo: myproj)
- [ ] widget-design [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-implement [src:cap flow:staged mode:crew-ship rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-pr [src:cap flow:staged mode:direct-pr rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-spec-r2 [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] widget-r2 [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] other-plan [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] audit [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: myproj)
- [ ] task-1 [src:cap flow:staged mode:crew-ship rev:yes qa:no] - pinned: crew-ship content for the flat brief, staged for the layout-collision case (repo: myproj)
- [ ] gizmo [src:cap flow:staged mode:local-only rev:yes qa:yes] - pinned (repo: QaClone)
- [ ] gizmo-qa [src:cap flow:staged mode:local-only rev:yes qa:yes] - pinned (repo: QaClone)
- [ ] mstaged [src:cap flow:staged mode:local-only rev:yes qa:yes] - pinned (repo: myproj)
- [ ] ktask2-spec [src:cap flow:staged mode:local-only rev:yes qa:no] - pinned (repo: kproj)
- [ ] ktask3-qa [src:cap flow:staged mode:local-only rev:yes qa:yes] - pinned (repo: kproj)
- [ ] mtask1 [src:cap mode:local-only qa:yes] - pinned qa (repo: myproj)
- [ ] mtask2 [src:cap mode:local-only qa:yes] - pinned qa (repo: myproj)
- [ ] mbad [src:cap mode:local-only qa:yes] - pinned qa, the malformed-profile refusal stays reachable (repo: myproj)
PINEOF


"$BIN/ac-brief.sh" task-1 myproj >/dev/null   # mode+review ride the row pin
brief="$AC_HOME/data/task-1/brief.md"
assert_file "$brief"
assert_contains "$(cat "$brief")" "crew/task-1" "ship brief names the branch"
assert_contains "$(cat "$brief")" "crew-ship" "ship brief names the pipeline"
assert_contains "$(cat "$brief")" "Review: yes" "direct crew-ship derives a review obligation"
assert_contains "$(cat "$brief")" "self-review" "execution owns implementer self-review"
assert_contains "$(cat "$brief")" "Prefer an applicable code-review plugin" \
  "implementer self-review is plugin-first"
assert_contains "$(cat "$brief")" "with project-provided plugins first" \
  "project-provided review plugins have precedence"
assert_contains "$(cat "$brief")" "Only when no applicable plugin exists, manually self-review the full diff" \
  "manual full-diff review is the fallback"
assert_contains "$(cat "$brief")" "Do not run a second manual full-diff review after the plugin" \
  "self-review does not duplicate plugin work"
assert_contains "$(cat "$brief")" "run-suite.sh" "execution brief names the full suite"
assert_contains "$(cat "$brief")" "per-change" \
  "execution brief marks the full suite as never the per-change verify"
# A ship/execution crewmate owes no report.md by the ship-vs-scout rule, so the
# universal "## Lessons" report contract had no file to land in and no wiring
# ever fired it. The brief must name the exact sink and state the obligation
# as unconditional - every ending, not only a landed one.
assert_contains "$(cat "$brief")" "$AC_HOME/data/task-1/report.md" \
  "execution brief names its own report.md sink by absolute path"
assert_contains "$(cat "$brief")" "## Lessons" \
  "execution brief states the Lessons section obligation"
assert_contains "$(cat "$brief")" "every ending" \
  "execution brief states the Lessons obligation fires at every ending, not only done"
assert_contains "$(cat "$brief")" "\`none\`" \
  "execution brief carries the none convention for a lessons-free ending"
assert_contains "$(cat "$brief")" "git rev-parse --show-toplevel" \
  "execution brief names YOUR worktree at runtime (Part c: primary-as-read-only)"
assert_contains "$(cat "$brief")" "git-common-dir" \
  "execution brief names the primary checkout as the never-commit target (Part c)"
assert_contains "$(cat "$brief")" "STOP and REPORT it" \
  "execution brief makes a primary EDIT a stop-and-report, never a cleanup"
assert_contains "$(cat "$brief")" "git checkout --" \
  "execution brief forbids the destructive revert in the primary"
assert_contains "$(cat "$brief")" "git restore" \
  "execution brief forbids the restore form too"
assert_contains "$(cat "$brief")" "git reset --hard" \
  "execution brief forbids the hard reset too"
# "Never touch other worktrees" is a rule about FILES; a raw
# `git worktree remove --force` or prune bypasses every lease guard the pool has.
assert_contains "$(cat "$brief")" "Never administer the worktree pool" \
  "execution brief forbids administering the pool"
assert_contains "$(cat "$brief")" "Captain: captain" "captain defaults to the role word"
assert_fails "$BIN/ac-brief.sh" task-1 myproj

# config/captain personalizes the address everywhere briefs stamp it.
printf 'TN\n' >"$AC_HOME/config/captain"
"$BIN/ac-brief.sh" task-2 myproj --mode local-only >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-2/brief.md")" "Captain: TN" "configured captain name"
digest="$("$BIN/ac-session-start.sh" 2>/dev/null)"
assert_contains "$digest" "captain: TN" "session digest shows the captain"
assert_contains "$digest" "flow: auto" "session digest shows the default flow"
assert_contains "$digest" "promote: always" "session digest shows the promote policy (default always)"
printf 'direct\n' >"$AC_HOME/config/flow"
assert_contains "$("$BIN/ac-session-start.sh" 2>/dev/null)" "flow: direct" "configured flow"
rm -f "$AC_HOME/config/captain" "$AC_HOME/config/flow"

# --mode overrides the registry default per task; junk modes rejected.
"$BIN/ac-brief.sh" task-3 myproj --mode local-only >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-3/brief.md")" "Mode: local-only" "per-task mode override"
assert_contains "$(cat "$AC_HOME/data/task-3/brief.md")" "Review: no" "direct local-only defaults review off"
assert_contains "$(cat "$AC_HOME/data/task-3/brief.md")" "Skip independent code review" "review=no is explicit in delivery"
# review=yes on direct + direct-pr/local-only is the CAPTAIN's call, never a
# chief's (AGENTS.md's review-obligation block: "no by default, optional yes when
# the captain requests independent review"). The case above validates the VALUE;
# nothing validated the AUTHORITY, and two roomchiefs self-raised it on
# 2026-07-30 and paid 3 and 4 review rounds on families that owed none - both
# self-reported afterwards, nothing refused them at the time.
out="$("$BIN/ac-brief.sh" task-3-selfraise myproj --mode local-only --review yes 2>&1)" \
  && fail "a chief self-raising review=yes on direct + local-only must be refused"
assert_contains "$out" "--captain-requested" "the refusal names the exact fix"
assert_no_file "$AC_HOME/data/task-3-selfraise/brief.md" "a refused self-raise scaffolds no brief"
out="$("$BIN/ac-brief.sh" task-3-selfraise myproj --mode direct-pr --review yes 2>&1)" \
  && fail "direct-pr is the same captain-only raise"
assert_contains "$out" "--captain-requested" "direct-pr names the same fix"
# The legitimate caller stays reachable in ONE flag, and NAMES the captain words
# it carries out - ac-spawn.sh's --captain-initiated shape for the same claim.
# The brief RECORDS the authority, so a later reader sees who asked.
"$BIN/ac-brief.sh" task-3-reviewed myproj --mode local-only --review yes \
  --captain-requested "captain TN 2026-07-30: review this one" --reason "captain asked for independent eyes" >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "Review: yes" "direct local-only can opt into review when the captain asks"
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "captain TN 2026-07-30: review this one" "the brief records WHO asked for the review"
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "ac-verify.sh codereview" "optional direct review uses the verifier facade"
# A rev:yes pin authorizes the raise for its own row only: awk's == once
# matched numeric-looking ids as numbers, so row 01's pin raised row 1.
printf -- '- [ ] 01 [src:cap rev:yes] - pins its own review (repo: myproj)\n- [ ] 1 - pins nothing (repo: myproj)\n' \
  >>"$AC_HOME/records/backlog.md"
out="$("$BIN/ac-brief.sh" 1 myproj --mode local-only --review yes 2>&1)" \
  && fail "row 01's rev:yes pin must not raise review on row 1"
assert_contains "$out" "--captain-requested" "a raise another row pinned is refused like any self-raise"
"$BIN/ac-brief.sh" 01 myproj --mode local-only --review yes >/dev/null \
  || fail "the row's own rev:yes pin must authorize the raise"
assert_contains "$(cat "$AC_HOME/data/01/brief.md")" "Review: yes (pinned on the backlog row)" \
  "the row's own rev:yes pin authorizes the raise"
# An empty ref is no ref: the declaration must NAME the captain's words.
assert_fails "$BIN/ac-brief.sh" task-3-empty myproj --mode local-only --review yes --captain-requested ""
# A declaration with nothing to authorize is a caller mistake, not a silent no-op.
assert_fails "$BIN/ac-brief.sh" task-3-noraise myproj --mode local-only --captain-requested "ref"
# Where review was never optional, the guard changes nothing: crew-ship derives
# review=yes with no declaration to make.
# crew-ship is a TIME-EXPENSIVE mode now (the escalation gate): the call must
# carry the captain's word or a row pin - this one declares.
"$BIN/ac-brief.sh" task-3-ship myproj --mode crew-ship --review yes --captain-requested "captain: ship it through the pipeline" --reason "multi-file risk: the slice spans three subsystems" >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-3-ship/brief.md")" "Review: yes" "crew-ship review=yes needs no captain declaration"
assert_fails "$BIN/ac-brief.sh" task-crew-no myproj --mode crew-ship --review no
assert_fails "$BIN/ac-brief.sh" task-4 myproj --mode bogus

"$BIN/ac-brief.sh" scout-1 myproj --scout >/dev/null
scout="$AC_HOME/data/scout-1/brief.md"
assert_contains "$(cat "$scout")" "report.md" "scout brief demands a report"
assert_contains "$(cat "$scout")" "NEVER open a PR" "scout brief forbids PRs"
assert_contains "$(cat "$scout")" "Never administer the worktree pool" "scout brief forbids administering the pool"

# Completion discipline: every brief teaches BOTH channels - the printed marker
# line (the watcher's backup) and the push that wakes the chief now. The push
# command is baked with an ABSOLUTE path, since the crewmate works in the
# PROJECT's worktree and may have no bin/ac-done.sh of its own.
root="$(cd "$BIN/.." && pwd -P)"
assert_contains "$(cat "$scout")" "$root/bin/ac-done.sh scout-1" \
  "the brief names the push command with an absolute path and the task id"
assert_contains "$(cat "$AC_HOME/data/task-1/brief.md")" "$root/bin/ac-done.sh task-1" \
  "the ship brief teaches the push too"
# A crewmate idling on its OWN background job otherwise reads to the watcher as
# a bare ended turn, which wakes the chief to read the pane.
for b in "$scout" "$AC_HOME/data/task-1/brief.md"; do
  assert_contains "$(cat "$b")" "print \`paused: <the job> - resumes when <what ends it>\` and push it the same way" \
    "every brief asks for a declared wait before idling on the crewmate's own work ($b)"
done
# Scratch left in the slot makes teardown refuse the task as dirty.
assert_contains "$(cat "$scout")" "under \`$AC_HOME/data/scout-1/\` or a temp dir, never inside the worktree" \
  "a scout brief keeps proof and scratch out of the worktree"
assert_contains "$(cat "$AC_HOME/data/task-1/brief.md")" "under \`$AC_HOME/data/task-1/\` or a temp dir, never inside the worktree" \
  "an execution brief keeps proof and scratch out of the worktree"
assert_contains "$(cat "$scout")" "leave the worktree clean before \`done:\`." "the clean-tree rule binds done, never a mid-task stop"

assert_fails "$BIN/ac-brief.sh" "bad id" myproj

# Mint-side grammar is [a-z0-9-], tighter than the loose read-path charset
# ([a-zA-Z0-9_-]) other tools still accept for an EXISTING id - underscore and
# uppercase must die here, immediately, naming [a-z0-9-].
err="$("$BIN/ac-brief.sh" "bad_id" myproj 2>&1 || true)"
assert_contains "$err" "id must be [a-z0-9-]" "underscore id refused, naming the tightened charset"
assert_no_file "$AC_HOME/data/bad_id/brief.md" "no brief scaffolded for a refused id"
err="$("$BIN/ac-brief.sh" "BadId" myproj 2>&1 || true)"
assert_contains "$err" "id must be [a-z0-9-]" "uppercase id refused, naming the tightened charset"
assert_no_file "$AC_HOME/data/BadId/brief.md" "no brief scaffolded for a refused id"

# Stage templates: design reports and execution remain; normal code-review and
# ship stages are retired. The stage flag validates its argument; qa remains a
# verifier charter, not a production crewmate stage.
"$BIN/ac-brief.sh" widget-spec myproj --stage spec >/dev/null
spec="$(cat "$AC_HOME/data/widget/spec/brief.md")"
assert_contains "$spec" "ACCEPTANCE CRITERIA" "spec demands criteria"
assert_contains "$spec" "NEVER open a PR" "spec is report-only"
"$BIN/ac-brief.sh" widget-arch myproj --stage architecture >/dev/null
arch="$(cat "$AC_HOME/data/widget/arch/brief.md")"
assert_contains "$arch" "viable alternatives" "architecture demands alternatives"
assert_contains "$arch" "understand the component without reading its internals" \
  "architecture brief carries contract-level understandability"
assert_contains "$arch" "internals can change without breaking consumers that honor that contract" \
  "architecture brief carries consumer-safe internal change"
assert_contains "$arch" "NEVER open a PR" "architecture is report-only"
"$BIN/ac-brief.sh" widget-plan myproj --stage plan >/dev/null
assert_contains "$(cat "$AC_HOME/data/widget/plan/brief.md")" "implementation plan" "plan stage"
assert_fails "$BIN/ac-brief.sh" widget-review myproj --stage code-review
assert_no_file "$AC_HOME/data/widget/review/brief.md" "normal flow scaffolds no code-review stage"
# qa stage: nested scaffold with the verify-only contract; unsuffixed id dies.
# myproj has NO clone here, so the store is unresolvable: the brief must name NO
# path and tell the agent to run store-less (a wrong path is worse than none -
# aa55baf's whole lesson), never leak a half-derived qa-store path.
"$BIN/ac-brief.sh" widget-qa myproj --stage qa >/dev/null
assert_contains "$(cat "$AC_HOME/data/widget/qa/brief.md")" "Never administer the worktree pool" \
  "the qa charter forbids administering the pool too"
qab="$(cat "$AC_HOME/data/widget/qa/brief.md")"
assert_contains "$qab" "NEVER fix" "qa brief is verify-only"
assert_contains "$qab" "verdict: passed|failed|unverifiable" "qa brief demands the 3-state verdict"
assert_contains "$qab" "crew/widget" "qa brief names the family target branch"
assert_contains "$qab" "store-less" "no-clone qa brief runs store-less"
case "$qab" in *qa-store*) fail "no-clone qa brief must not name a store path" ;; esac
assert_fails "$BIN/ac-brief.sh" widget-old myproj --stage qa

# qa store path is baked by the ONE deriver: a qa brief for a project WITH a
# clone names the absolute store path, byte-identical to `ac-qa.sh store-dir`
# resolved in that clone. The clone name carries an UPPERCASE letter so a naive
# $data_dir/qa-store/$project interpolation (the rejected second deriver) would
# print `.../QaClone` while store-dir's repo_scope LOWERCASES to `.../qaclone` -
# this assertion can only pass if the brief called store-dir, not by construction.
make_repo home/projects/QaClone >/dev/null
want="$(cd "$AC_HOME/projects/QaClone" && "$BIN/ac-qa.sh" store-dir)"
"$BIN/ac-brief.sh" gizmo-qa QaClone --stage qa >/dev/null
assert_contains "$(cat "$AC_HOME/data/gizmo/qa/brief.md")" "$want" "qa brief names the store-dir-resolved path"
assert_fails "$BIN/ac-brief.sh" widget-ship myproj --stage ship
assert_no_file "$AC_HOME/data/widget/ship/brief.md" "normal flow scaffolds no ship stage"
"$BIN/ac-brief.sh" widget-design myproj --stage design >/dev/null
dsg="$(cat "$AC_HOME/data/widget/design/brief.md")"
assert_contains "$dsg" "spec/report.md" "design covers spec"
assert_contains "$dsg" "arch/report.md" "design covers architecture"
assert_contains "$dsg" "plan/report.md" "design covers plan"
assert_contains "$dsg" "understand the component without reading its internals" \
  "merged design brief carries architecture contract-level understandability"
assert_contains "$dsg" "internals can change without breaking consumers that honor that contract" \
  "merged design brief carries architecture consumer-safe internal change"
assert_contains "$dsg" "awaiting gate" "design pauses at each gate"
assert_contains "$dsg" "reviews EVERY report" "per-report gate, not one review at the end"
assert_contains "$dsg" "NEVER change code" "design is report-only"
"$BIN/ac-brief.sh" widget myproj --stage implement >/dev/null
implbrief="$(cat "$AC_HOME/data/widget/implement/brief.md")"
assert_contains "$implbrief" "crew/widget" "implement = ship template"
assert_contains "$implbrief" "Review: yes" "staged execution always requires review"
assert_contains "$implbrief" "Prefer an applicable code-review plugin" \
  "staged implementer self-review is plugin-first"
assert_contains "$implbrief" "with project-provided plugins first" \
  "staged self-review prefers project-provided plugins"
assert_contains "$implbrief" "Only when no applicable plugin exists, manually self-review the full diff" \
  "staged implementer falls back to one manual full-diff review"
assert_contains "$implbrief" "Do not run a second manual full-diff review after the plugin" \
  "staged self-review does not duplicate plugin work"
# The staged execution crewmate is the same ship template as the flat one (both
# ride the same `implement)` scaffold branch) and owes the identical sink.
assert_contains "$implbrief" "$AC_HOME/data/widget/implement/report.md" \
  "staged execution brief names its nested report.md sink by absolute path"
assert_contains "$implbrief" "## Lessons" \
  "staged execution brief states the Lessons section obligation"
assert_contains "$implbrief" "every ending" \
  "staged execution brief states the Lessons obligation fires at every ending"
assert_fails "$BIN/ac-brief.sh" widget-no myproj --stage implement --review no
"$BIN/ac-brief.sh" widget-pr myproj --stage implement --mode direct-pr >/dev/null
prbrief="$(cat "$AC_HOME/data/widget-pr/implement/brief.md")"
assert_contains "$prbrief" "Review: yes" "staged direct-pr keeps mandatory review"
assert_contains "$prbrief" "ac-verify.sh codereview" "staged direct-pr invokes the canonical verifier"
assert_fails "$BIN/ac-brief.sh" widget-x myproj --stage bogus

# Execution owns IMPLEMENT + DELIVERY in both direct and staged flow. Staged no
# longer stops for separate code-review/ship crewmates.
flatimpl="$(cat "$AC_HOME/data/task-1/brief.md")"
assert_contains "$flatimpl" "Mode crew-ship: run the \`crew-ship\` skill" \
  "direct crew-ship execution owns its delivery engine"
case "$flatimpl" in *"Mode direct-pr:"*|*"Mode local-only:"*) \
  fail "a mode-specific execution brief must not advertise unused delivery branches" ;; esac
assert_contains "$implbrief" "Mode crew-ship: run the \`crew-ship\` skill" \
  "staged execution owns crew-ship delivery"
assert_contains "$implbrief" "Independent review" "staged execution owns the review obligation"
assert_contains "$implbrief" "Do not invoke \`ac-verify codereview\` separately" \
  "crew-ship satisfies the obligation with one reviewer"
case "$implbrief" in *"code-review runs next"*|*"ship is a later stage"*) \
  fail "staged execution must not advertise retired production stages" ;; esac

# Design-report contract (docs/staged-design-flow-spec.md is authoritative):
# every design-kind brief (spec/architecture/plan/design) carries the operative
# report contract - shared sections, n/a convention, Trace ID rules, upstream
# path+sha references, the inline self-review checklist - and points at the
# spec doc by a path that actually resolves. Execution and scout briefs stay
# free of it: the contract governs design reports only.
assert_file "$ROOT/docs/staged-design-flow-spec.md"
planb="$(cat "$AC_HOME/data/widget/plan/brief.md")"
for pair in "spec|$spec" "arch|$arch" "plan|$planb" "design|$dsg"; do
  which="${pair%%|*}"; body="${pair#*|}"
  assert_contains "$body" "## Report contract" "$which brief carries the report contract"
  assert_contains "$body" "docs/staged-design-flow-spec.md" "$which brief points at the authoritative spec"
  assert_contains "$body" "report_sha256" "$which brief carries the upstream path+sha reference rule"
  assert_contains "$body" "retired-ID check" "$which brief carries the inline self-review checklist"
  assert_contains "$body" "all nine checks" "$which brief carries the full nine-check self-review"
  assert_contains "$body" "Diagram Rule" "$which brief carries the diagram self-review check"
  assert_contains "$body" "TDD check" "$which brief carries the TDD self-review check"
  assert_contains "$body" 'n/a: <reason>' "$which brief carries the n/a section convention"
  assert_contains "$body" "six required-and-gated sections" \
    "$which brief marks the six sections as gated, not an exhaustive report shape"
  assert_contains "$body" '`## Lessons`' \
    "$which brief's report contract names the Lessons heading"
  assert_contains "$body" "rides alongside those six" \
    "$which brief states Lessons rides alongside the six gated sections, not a seventh"
  assert_contains "$body" "before you announce that report ready" \
    "$which brief pins writing Lessons in the same pass, before announcing the report ready"
  assert_contains "$body" "exact string \`## Lessons\` at column 0" \
    "$which brief pins the exact Lessons heading the automatic consumer recognises"
done
assert_contains "$dsg" "STAGE-ADMISSION" \
  "design brief reminds the chief the admission receipts precede the spawn"
assert_contains "$dsg" "the admitted spec/architecture/plan stages" \
  "design brief scopes the session to the admitted stages, not always all three"
case "$implbrief" in *"## Report contract"*) \
  fail "an execution brief must not carry the design report contract" ;; esac
case "$(cat "$AC_HOME/data/scout-1/brief.md")" in *"## Report contract"*) \
  fail "a plain scout brief must not carry the design report contract" ;; esac
case "$spec$planb" in *"understand the component without reading its internals"*) \
  fail "spec and plan briefs must not carry architecture-only isolation checks" ;; esac

# Nested-layout edges: revision ids keep their suffix as the dir name; an id
# suffix contradicting --stage dies; ac_task_dir resolves staged ids to the
# nested dir, direct ids to the flat one, and dies on a double brief.
"$BIN/ac-brief.sh" widget-spec-r2 myproj --stage spec >/dev/null
assert_file "$AC_HOME/data/widget/spec-r2/brief.md"
err="$("$BIN/ac-brief.sh" other-plan myproj --stage spec 2>&1 || true)"
assert_contains "$err" "maps to stage dir 'plan'" "suffix/stage contradiction dies"
# shellcheck disable=SC1091
. "$BIN/ac-lib.sh"
assert_eq "$(ac_task_dir widget-spec)" "$AC_HOME/data/widget/spec" "staged id resolves nested"
assert_eq "$(ac_task_dir widget)" "$AC_HOME/data/widget/implement" "unsuffixed staged implement resolves nested"
assert_eq "$(ac_task_dir task-1)" "$AC_HOME/data/task-1" "direct task resolves flat"
mkdir -p "$AC_HOME/data/widget-spec"
printf 'stray\n' >"$AC_HOME/data/widget-spec/brief.md"
assert_fails bash -c ". '$BIN/ac-lib.sh'; ac_task_dir widget-spec"   # briefs in both layouts
rm -rf "$AC_HOME/data/widget-spec"

# Nested stage briefs embed the NESTED report path (deliverable == the dir
# teardown checks). Retired ship revisions cannot be scaffolded.
assert_contains "$(cat "$AC_HOME/data/widget/spec/brief.md")" \
  "$AC_HOME/data/widget/spec/report.md" "stage brief embeds the nested report path"
assert_fails "$BIN/ac-brief.sh" widget-ship-r2 myproj --stage ship

# An implement REVISION (bare <family>-rN) stays inside the family dir.
"$BIN/ac-brief.sh" widget-r2 myproj --stage implement >/dev/null
assert_file "$AC_HOME/data/widget/implement-r2/brief.md"
assert_eq "$(ac_task_dir widget-r2)" "$AC_HOME/data/widget/implement-r2" "implement revision resolves nested"
# A family-scoped id (revision suffix) names the FAMILY branch crew/widget, the
# same branch tests/sh/ac-merge-local.test.sh proves ac-merge-local.sh lands to -
# never a hand-made crew/widget-r2 alias.
assert_contains "$(cat "$AC_HOME/data/widget/implement-r2/brief.md")" "crew/widget" \
  "a family-scoped id names crew/<family>, matching ac-merge-local.sh's derivation"
case "$(cat "$AC_HOME/data/widget/implement-r2/brief.md")" in *crew/widget-r2*) \
  fail "a family-scoped id must never name a raw crew/<id> alias branch" ;; esac

# A suffix-bearing stage refuses an unsuffixed id (the resolver could never
# find that brief), and a second brief in the OTHER layout is refused.
err="$("$BIN/ac-brief.sh" audit myproj --stage spec 2>&1 || true)"
assert_contains "$err" "canonical id form <task>-spec" "unsuffixed id for a scout stage dies"
err="$("$BIN/ac-brief.sh" task-1 myproj --stage implement 2>&1 || true)"
assert_contains "$err" "other layout" "staged scaffold refuses when a flat brief exists"
err="$("$BIN/ac-brief.sh" widget-spec myproj --scout 2>&1 || true)"
assert_contains "$err" "other layout" "flat scaffold refuses when the nested brief exists"

# --- AC17: the repo-knowledge record is reachable from a scaffolded brief ----
# RUNNABLE command lines, not a bare path: the crewmate's pane has no AC_HOME,
# so its own ac-know.sh would resolve a different record. Every emitted line
# therefore carries --home and an ABSOLUTE bin/ prefix.
kproj="$AC_HOME/projects/kproj"
git init -q -b main "$kproj"
git -C "$kproj" config user.email t@t
git -C "$kproj" config user.name t
"$BIN/ac-brief.sh" ktask kproj --mode local-only >/dev/null
kb="$(cat "$AC_HOME/data/ktask/brief.md")"
assert_contains "$kb" "$AC_HOME/records/repo-knowledge/kproj.md" "the brief names the resolved record path"
# --repo names the CREWMATE'S OWN tree ROOT, resolved at the crewmate's shell
# at RUN time via `git rev-parse --show-toplevel`, never the clone path baked
# at scaffold time - a bare --repo $kproj would pin every entry to the clone
# regardless of which worktree actually observed the fact (the false-fresh
# regression below). A bare --repo "$PWD" is not enough either: a pathspec
# `git -C "$repo" diff --quiet <at> -- <path>` resolves relative to CWD, so a
# command run from a worktree SUBDIRECTORY would silently match nothing and
# pass vacuously (the sub-dir regression further below) - --show-toplevel
# resolves the same root regardless of cwd.
assert_contains "$kb" "$ROOT/bin/ac-know.sh verify --home $AC_HOME --repo \"\$(git rev-parse --show-toplevel)\"" \
  "the re-check line is runnable, carries --home, and binds the crewmate's own tree ROOT"
assert_contains "$kb" "$ROOT/bin/ac-know.sh add --home $AC_HOME --repo \"\$(git rev-parse --show-toplevel)\" --family ktask" \
  "the record line is runnable, carries --home, is attributed to the family, and binds the crewmate's own tree ROOT"

# (brief-recall) The PULL verb leads the block: the chief's intake recall is a
# discipline link, so the worker gets the same tiered read baked - ranked and
# budgeted, with --home it cannot resolve itself - and the cite hand-over that
# closes the heat loop from the worker side. The full-record cat survives as
# the explicitly-labelled fallback, never the first move.
assert_contains "$kb" "$ROOT/bin/ac-know.sh recall '<your question" \
  "the ask line bakes the tiered recall verb"
assert_contains "$kb" "recall '<your question - subject/mechanism/terms>' --home $AC_HOME --repo \"\$(git rev-parse --show-toplevel)\"" \
  "... carrying --home and the crewmate's own tree ROOT like every other baked line"
assert_contains "$kb" "an uncited read is an invisible read" \
  "the cite line states why the heat loop needs the worker's read"
case "$kb" in
  *"ask:"*"full:"*) : ;;
  *) fail "the ask verb must LEAD and the full-record cat must be the labelled fallback" ;;
esac

# (brief-qa-home) The execution brief bakes the FLEET HOME onto the `ac-qa.sh
# agent` line, for exactly the reason knowledge() bakes it onto the ac-know
# lines: the crewmate's pane carries no AC_HOME by design (bin/ac-spawn.sh),
# every durable source the QA profile freezes descends from that ONE value, and
# cmd_agent never reads the qa charter that already bakes --home for `start`.
# Without this bake the crewmate is the caller that cannot comply, and its QA
# call answers QA_PROFILE_STATUS=needs-profile on every project.
assert_contains "$kb" "$ROOT/bin/ac-qa.sh agent --home $AC_HOME" \
  "the execution brief bakes a runnable ac-qa.sh agent line carrying --home"
assert_contains "$kb" "--task ktask-qa" \
  "... naming the family's qa task id, so the baked line runs as written"

# --- AC17 regression: a fact recorded from a POOLED WORKTREE must bind that
# worktree's tree, not the primary clone's - the false-fresh class (door B,
# bin/ac-know.sh's header) the old $dir bake minted on every write while
# still reporting success. This drives the ACTUAL emitted command, from the
# worktree's own cwd, and inspects the RECORDED at: sha - a string assert on
# the command text alone cannot see this class (it stayed green while the
# defect was live).
wproj="$AC_HOME/projects/wproj"
git init -q -b main "$wproj"
git -C "$wproj" config user.email t@t
git -C "$wproj" config user.name t
printf 'clone version\n' >"$wproj/file.txt"
git -C "$wproj" add -A
git -C "$wproj" commit -qm clone-commit
clone_sha="$(git -C "$wproj" rev-parse HEAD)"

wtree="$TMP/wtree-know"
git -C "$wproj" worktree add -q -b crew/wtask "$wtree" main
printf 'worktree version\n' >"$wtree/file.txt"
git -C "$wtree" add -A
git -C "$wtree" commit -qm worktree-commit
wtree_sha="$(git -C "$wtree" rev-parse HEAD)"

"$BIN/ac-brief.sh" wtask wproj --mode local-only >/dev/null
wb="$(cat "$AC_HOME/data/wtask/brief.md")"
# Extract the two-physical-line `record:` block verbatim and fill its
# placeholders - the same text a crewmate would copy out of its own brief.
record_cmd="$(printf '%s\n' "$wb" | sed -n '/^ *record: */,/--fact/p' \
  | sed -e '1s/^ *record: *//' \
        -e 's/<path>:<line>/file.txt:1/' \
        -e 's/<what you learned>/worktree fact/')"

wrec="$AC_HOME/records/repo-knowledge/wproj.md"
out="$(cd "$wtree" && eval "$record_cmd" 2>&1)"; rc=$?
assert_eq "$rc" "0" \
  "the scaffolded record command exits 0 from the crewmate's own worktree (output: $out)"
assert_contains "$(cat "$wrec")" "at: $wtree_sha " \
  "a fact recorded from the worktree binds to the WORKTREE's sha, not the clone's (the false-fresh regression - it would silently record 'at: $clone_sha' instead)"

# --- AC17 regression, cwd variant: the SAME baked command, run from a
# SUBDIRECTORY of the worktree. A bare `--repo "$PWD"` would bind the
# subdirectory: assert_bound's pathspec (`git -C "$repo" diff --quiet <at> --
# <path>`, <path> repo-relative - validate_src_file refuses absolute/..) then
# resolves relative to that wrong cwd, matches nothing, and `git diff`
# exits 0 on an unmatched pathspec - a vacuous PASS, not a refusal.
# `--show-toplevel` must resolve the SAME root regardless of cwd, so both
# halves hold from a subdirectory too: the happy path still binds the
# worktree's sha, and a genuinely dirty file is still CAUGHT, never
# vacuously passed.
mkdir -p "$wtree/sub"
sub_record_cmd="$(printf '%s\n' "$wb" | sed -n '/^ *record: */,/--fact/p' \
  | sed -e '1s/^ *record: *//' \
        -e 's/<path>:<line>/file.txt:1/' \
        -e 's/<what you learned>/worktree fact from sub/')"
out2="$(cd "$wtree/sub" && eval "$sub_record_cmd" 2>&1)"; rc2=$?
assert_eq "$rc2" "0" \
  "the scaffolded record command exits 0 from a SUBDIRECTORY of the worktree too (output: $out2)"
assert_contains "$(cat "$wrec")" "at: $wtree_sha " \
  "a fact recorded from a worktree SUBDIRECTORY still binds the worktree ROOT's sha (--show-toplevel), not a subdir-relative resolution"

# The refusal half - the point of this regression: a file that genuinely
# differs from HEAD must still be REFUSED when the record command runs from
# a subdirectory, never vacuously passed by a pathspec resolved against the
# wrong cwd.
printf 'dirtied after commit\n' >"$wtree/file.txt"
dirty_record_cmd="$(printf '%s\n' "$wb" | sed -n '/^ *record: */,/--fact/p' \
  | sed -e '1s/^ *record: *//' \
        -e 's/<path>:<line>/file.txt:1/' \
        -e 's/<what you learned>/dirty file must refuse/')"
if (cd "$wtree/sub" && eval "$dirty_record_cmd") >/dev/null 2>&1; then
  fail "a dirty file must be REFUSED even when the record command runs from a worktree subdirectory (vacuous pathspec pass)"
fi
git -C "$wtree" checkout -q -- file.txt

# A staged brief attributes to the FAMILY, not the stage id.
"$BIN/ac-brief.sh" ktask2-spec kproj --stage spec >/dev/null
assert_contains "$(cat "$AC_HOME/data/ktask2/spec/brief.md")" "--family ktask2" \
  "a staged brief attributes the entry to its family"

# No clone resolves -> NOTHING is named. A brief that names a wrong record is
# worse than one that names none, and this one WRITES.
"$BIN/ac-brief.sh" noclone-task nosuchproject --mode local-only >/dev/null
nb="$(cat "$AC_HOME/data/noclone-task/brief.md")"
case "$nb" in *ac-know.sh*) fail "an unresolvable clone must name no ac-know.sh command" ;; esac
case "$nb" in *repo-knowledge*) fail "an unresolvable clone must name no record path" ;; esac

# The qa brief bakes the FLEET HOME the same way and for the same reason it
# bakes the store: the qa pane has no AC_HOME, and --home is the single
# resolution from which BOTH the config and the scope map descend.
"$BIN/ac-brief.sh" ktask3-qa kproj --stage qa >/dev/null
qb="$(cat "$AC_HOME/data/ktask3/qa/brief.md")"
assert_contains "$qb" '--home <path>' "the qa brief names the --home flag"
assert_contains "$qb" "$AC_HOME" "the qa brief bakes the resolved fleet home"

# The closed scope list is chief-tier: no brief template may ever name its
# install verb, or the trust boundary re-opens through documentation.
grep -q 'scope-install' "$ROOT/src/brief.ts" && fail "no brief template may name scope-install"

# --- required-profile MANIFEST recording at intake (Story 4) ------------------
# --qa-required-profile <key> (repeatable) records the task's explicit required
# profile set into data/<family>/qa/manifest.json - the set the merge gate
# adjudicates. Without the flag NO manifest is written (a flat/single-profile
# task keeps the simple one-profile gate behavior).
"$BIN/ac-brief.sh" mtask1 myproj --mode local-only >/dev/null
assert_no_file "$AC_HOME/data/mtask1/qa/manifest.json" "no --qa-required-profile -> no manifest"

"$BIN/ac-brief.sh" mtask2 myproj --mode local-only \
  --qa-required-profile sample-platform/maple/maple-core-service \
  --qa-required-profile sample-platform/birch/birch-core-service >/dev/null
mman2="$AC_HOME/data/mtask2/qa/manifest.json"
assert_file "$mman2"
jq -e . "$mman2" >/dev/null || fail "the manifest is well-formed JSON the gate can read"
assert_eq "$(jq -r '.task' "$mman2")" "mtask2" "manifest records the task/family"
assert_eq "$(jq -r '.required_profiles | length' "$mman2")" "2" "manifest records every required profile"
assert_eq "$(jq -r '.required_profiles[0].profile_key' "$mman2")" "sample-platform/maple/maple-core-service" "the first required profile key, verbatim"
assert_eq "$(jq -r '.required_profiles[1].profile_key' "$mman2")" "sample-platform/birch/birch-core-service" "the second required profile key"

# A staged execution brief records the manifest under the FAMILY, alongside the
# stage dir - the layout the merge gate reads (data/<family>/qa/manifest.json).
"$BIN/ac-brief.sh" mstaged myproj --stage implement \
  --qa-required-profile sample-platform/orchid/orchid-service >/dev/null
assert_file "$AC_HOME/data/mstaged/qa/manifest.json"
assert_eq "$(jq -r '.required_profiles[0].profile_key' "$AC_HOME/data/mstaged/qa/manifest.json")" \
  "sample-platform/orchid/orchid-service" "staged manifest attributes to the family"

# A malformed profile key is refused at intake, not written as garbage.
assert_fails "$BIN/ac-brief.sh" mbad myproj --mode local-only --qa-required-profile 'has space/scope/app'
assert_no_file "$AC_HOME/data/mbad/brief.md" "a refused profile scaffolds no brief"
"$BIN/ac-brief.sh" mbad myproj --mode local-only --qa-required-profile sample-platform/maple/maple-core-service >/dev/null \
  || fail "the corrected re-run must scaffold, not die on a half-made brief"

# --- Fleet standing rules (issue #3 proposal 1): a captain STANDING rule in
# records/captain.md must reach every scaffolded brief mechanically, not by a
# chief hand-copying it. No captain.md exists in this fixture home yet - the
# FAIL LOUD path (ac-gate.sh's own "(no standing preferences file on record)"
# precedent), never a silent no-op.
"$BIN/ac-brief.sh" standing-none myproj --mode local-only >/dev/null
snb="$(cat "$AC_HOME/data/standing-none/brief.md")"
assert_contains "$snb" "## Fleet standing rules" "every brief carries the standing-rules section"
assert_contains "$snb" "(no standing preferences file on record)" \
  "a missing captain.md is reported LOUD, matching ac-gate.sh's own precedent"

# Now with a captain.md: select by the EXISTING STANDING marker token
# (ac-domain.sh's STANDING (domain:<name>): grammar), as a rule BLOCK - a
# `- ` line plus its indented continuations (the same block convention
# ac-curate.sh's _captain_plan already uses). A domain-scoped STANDING entry
# and a plain non-STANDING bullet must NOT leak into the fleet-wide channel.
cat >"$AC_HOME/records/captain.md" <<'CAP'
- 2026-01-01: STANDING (captain): ONE-LINE-FLEET-MARKER, always do X.
- 2026-01-02: STANDING (captain) - MULTI-LINE-FLEET-MARKER, this rule
  continues onto CONTINUATION-LINE-MARKER for the rest of its detail.
- 2026-01-03: STANDING (domain:widgets): DOMAIN-ONLY-MARKER must stay
  domain-scoped, delivered to that domainchief directly, never here.
- 2026-01-04: housekeeping note, NOT-STANDING-MARKER, not a rule at all.
CAP
"$BIN/ac-brief.sh" standing-yes myproj --mode local-only >/dev/null
syb="$(cat "$AC_HOME/data/standing-yes/brief.md")"
assert_contains "$syb" "ONE-LINE-FLEET-MARKER" "a single-line STANDING bullet is selected"
assert_contains "$syb" "MULTI-LINE-FLEET-MARKER" "a multi-line STANDING block's anchor line is selected"
assert_contains "$syb" "CONTINUATION-LINE-MARKER" \
  "the block's indented CONTINUATION lines are carried too, not just the anchor line"
case "$syb" in *DOMAIN-ONLY-MARKER*) \
  fail "a domain-scoped STANDING (domain:<name>): entry must not leak into every fleet brief" ;; esac
case "$syb" in *NOT-STANDING-MARKER*) \
  fail "a non-STANDING bullet must not be copied - the channel SELECTS, it does not dump captain.md wholesale" ;; esac
rm -f "$AC_HOME/records/captain.md"

# Regression (roomchief verify, real records/captain.md:63): a line that
# CARRIES the STANDING token but is authored as plain paragraph text under a
# `## heading` - never a `- ` bullet - must not vanish silently. WARN, do not
# widen the `- ` block selector to swallow it (src/backlog.ts's `domain` field doc names the
# trap: prose merely MENTIONING the token read as a real entry).
cat >"$AC_HOME/records/captain.md" <<'CAP'
- 2026-02-01: STANDING (captain): BULLETED-MARKER, this one parses fine.

## Some heading
STANDING (captain, via select on something): ORPHAN-STANDING-MARKER, never a bullet.
CAP
"$BIN/ac-brief.sh" standing-orphan myproj --mode local-only >/dev/null
sob="$(cat "$AC_HOME/data/standing-orphan/brief.md")"
assert_contains "$sob" "BULLETED-MARKER" "the conforming bulleted entry still selects normally"
assert_contains "$sob" "ORPHAN-STANDING-MARKER" \
  "a non-bulleted STANDING mention is surfaced, not silently dropped"
assert_contains "$sob" "UNPARSED" \
  "the orphan mention is flagged as unparsed, distinct from a selected rule block"
rm -f "$AC_HOME/records/captain.md"

# Regression (brief-step7-local-only-contradicts-standing-self-land):
# Delivery step 7 used to hard-code "leave the committed local handover for
# `local-only`" as distro law, while the SAME generated brief carries this
# fleet's own STANDING SELF-LAND rule a few dozen lines later under
# "## Fleet standing rules" - two contradicting instructions in one document,
# left for the crewmate to resolve at the last step of delivery. AGENTS.md
# is explicit that who lands a verified local-only branch is a per-fleet call,
# not distro law (rooms-threads skill, room lifecycle) - so step 7 must name that authority
# instead of asserting a direction, while still stating the reversible
# fail-closed default for a fleet with no such rule.
cat >"$AC_HOME/records/captain.md" <<'CAP'
- 2026-01-01: STANDING SELF-LAND (captain): local-only work that passed its
  independent verify SELF-LANDS via ac-merge-local.sh and ENDS without asking.
CAP
"$BIN/ac-brief.sh" step7-local myproj --mode local-only >/dev/null
s7b="$(cat "$AC_HOME/data/step7-local/brief.md")"
case "$s7b" in *"Open the PR, or leave the committed local handover for"*) \
  fail "step 7 must not hard-code a local-only landing direction that a fleet SELF-LAND rule contradicts elsewhere in the same brief" ;; esac
assert_contains "$s7b" 'see `## Fleet standing rules` below' \
  "step 7 names the fleet's own standing rule as the authority instead of asserting a direction"
assert_contains "$s7b" 'leave it as a handover for the chief' \
  "step 7 still states the fail-closed default when no standing rule speaks to the landing"
rm -f "$AC_HOME/records/captain.md"

# --- fan-out nesting (tasks/): the scope is the family signal -----------------
# A SCOPED chief's free-slug sub-task (AC_SCOPE=<family>, id=<family>-<slug>,
# no stage/-rN suffix) scaffolds at data/<family>/tasks/<slug>/; unscoped
# scaffolds and ids that do not extend the scope stay flat - an unrelated
# top-level id that merely EXTENDS another family's name must never nest.
cat >>"$AC_HOME/records/backlog.md" <<'PINEOF'
- [ ] wire [src:cap flow:direct mode:local-only rev:no qa:no] - fan-out base (repo: myproj)
- [ ] wire-camera [src:cap flow:direct mode:local-only rev:no qa:no] - unrelated task extending the name (repo: myproj)
PINEOF
mkdir -p "$AC_HOME/data/wire"
: >"$AC_HOME/data/wire/room.md"
AC_SCOPE=wire "$BIN/ac-brief.sh" wire-slice-a myproj --mode local-only >/dev/null
assert_file "$AC_HOME/data/wire/tasks/slice-a/brief.md" \
  "a scoped free-slug sub-task scaffolds tasks/-nested under its family"
assert_eq "$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_task_dir wire-slice-a")" \
  "$AC_HOME/data/wire/tasks/slice-a" "and the resolver finds it from the bare id"
"$BIN/ac-brief.sh" wire-camera myproj >/dev/null
assert_file "$AC_HOME/data/wire-camera/brief.md" \
  "an UNSCOPED scaffold stays flat even when the id extends a family's name"
AC_SCOPE=other-fam "$BIN/ac-brief.sh" wire-slice-b myproj --mode local-only >/dev/null 2>&1 || true
assert_file "$AC_HOME/data/wire-slice-b/brief.md" \
  "a scoped scaffold whose id does not extend the scope stays flat"
# the other-layout refusal covers the tasks/ twin in both directions
out="$(AC_SCOPE=wire "$BIN/ac-brief.sh" wire-camera myproj 2>&1 || true)"
assert_contains "$out" "already exists" \
  "a scoped re-scaffold of an id whose flat brief exists refuses"
out="$("$BIN/ac-brief.sh" wire-slice-a myproj --mode local-only 2>&1 || true)"
assert_contains "$out" "already exists" \
  "an unscoped re-scaffold of a tasks/-nested id refuses instead of minting a flat twin"

# --- the epic-branch fence: an unreadable ledger is not "no epic" ------------
# Read as no fence, an epic story's direct-pr brief names the default branch
# as its PR base; a scout skips every earlier ledger read. Skipped under root,
# which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  printf -- '- [ ] fe-s1 - story; epic:fe (repo: myproj)\n' >>"$AC_HOME/records/backlog.md"
  mkdir -p "$AC_HOME/data/fe"
  printf 'myproj epic/fe\n' >"$AC_HOME/data/fe/branches"
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0; out="$("$BIN/ac-brief.sh" fe-s1 myproj --mode direct-pr 2>&1)" || rc=$?
  rcs=0; outs="$("$BIN/ac-brief.sh" fe-s1 myproj --scout 2>&1)" || rcs=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  [ "$rc" != 0 ] && [ "$rcs" != 0 ] || fail "an unreadable ledger must refuse the scaffold"
  assert_contains "$out" "cannot read the ledger" "the direct-pr scaffold names the unreadable ledger"
  assert_contains "$outs" "cannot read the ledger" "the scout scaffold names the unreadable ledger"
  assert_no_file "$AC_HOME/data/fe-s1/brief.md" "an unreadable ledger scaffolds no brief"
fi

# --- differential: src/brief.ts against the frozen bash original -----------
# DISPUTED: the implementation (tests/fixtures/ac-brief.sh under bash vs src/brief.ts through bin/ac-brief.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home (records/backlog.md with the pinned rows below, data/<e>/branches live and archived, config/captain and records/captain.md where a row seeds them), clones at <side>/home/projects/<name> built by the same commands with fixed author/committer dates and one git config (GIT_CONFIG_GLOBAL, no system config) so every sha matches, a TMPDIR at <side>/tmp; argv and env (the side root spelled @H, substituted in values only); cwd (<side>/cwd, an EMPTY dir, unless a row names another); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; the live bin/ beside each entry (the oracle bin's copies, $BIN's own, a decoy root's copy for the rows from a cwd with no name) and a row's own PATH stubs; both entries invoked by absolute path except W1's row; exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT), then the world a row may touch: every path under the side root (git internals aside), every file under home/ and tmp/ with its mode and bytes, and each clone's porcelain.
xobin="$(make_oracle_bin ac-brief)"
cmp -s "$xobin/ac-brief.sh" "$ROOT/tests/fixtures/ac-brief.sh" || fail "the oracle bin holds the frozen original"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig"
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() { rm -rf "$H"; mkdir -p "$H/home" "$H/cwd" "$H/tmp"; }
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xrepo() {  # xrepo <path under the side> - a repo with one commit on main
  git init -q -b main "$H/$1"; printf 'hello\n' >"$H/$1/file.txt"; git -C "$H/$1" add -A; git -C "$H/$1" commit -qm init
}
XLEDGER='## Queued
- [ ] s [src:cap flow:staged mode:local-only rev:yes qa:yes] - a staged family, pinned
- [ ] sc [src:cap flow:staged mode:crew-ship rev:yes qa:yes] - staged crew-ship, pinned
- [ ] sd [src:cap flow:staged mode:direct-pr rev:yes qa:yes] - staged direct-pr, pinned
- [ ] c [src:cap mode:crew-ship] - crew-ship, pinned
- [ ] cq [src:cap mode:crew-ship qa:yes] - crew-ship with qa, pinned
- [ ] d [src:cap mode:direct-pr] - direct-pr
- [ ] dr [src:cap mode:direct-pr rev:yes] - direct-pr, review pinned
- [ ] l [src:cap mode:local-only] - local-only
- [ ] lr [src:cap mode:local-only rev:yes] - local-only, review pinned
- [ ] lq [src:cap mode:local-only qa:yes] - local-only, qa pinned
- [ ] ep [src:cap mode:direct-pr] - the epic row epic:ep
- [ ] ep-s1 [src:cap mode:direct-pr] - an epic story epic:ep
- [ ] ep-s2 [src:cap mode:crew-ship] - a crew-ship epic story epic:ep
- [ ] eps [src:cap flow:staged mode:local-only] - a staged epic story epic:ep
- [ ] epr [src:cap flow:staged mode:local-only rev:yes] - a staged epic story, review pinned epic:ep
- [ ] ft-m1 [src:cap mode:feature-pr] - a feature member feature:ft
- [ ] ft-m2 [src:cap mode:feature-pr] - a member whose feature has no record feature:nofeat
- [ ] ft-m3 [src:cap mode:feature-pr] - a member given by path feature:ft
- [ ] ret-s [src:cap mode:direct-pr] - a retired epic epic:ret
- [ ] arc-s [src:cap mode:direct-pr] - an archived epic epic:arc
- [ ] fam2 [src:cap mode:local-only rev:yes] - W8: the family pins rev
- [ ] bogus [src:cap mode:bogus] - W7: a pinned mode nothing validates
- [ ] twice [src:cap mode:local-only mode:crew-ship] - W7: a doubled pin
- [ ] tab [src:cap	mode:local-only] - a TAB-joined pin
- [ ] 01 [src:cap mode:crew-ship rev:yes] - numeric-looking
- [ ] 1 [src:cap mode:local-only] - matched as a string
- [ ] bare - no contract
- [ ] f [src:cap flow:staged mode:local-only rev:yes qa:no] - the family pin for its stage ids
- [ ] f-plan - an exact contractless stage row: the family answers
- [ ] eg [src:cap mode:] - an empty mode token: no contract at all
'
xstd() {  # the standard world: the ledger, the fence records, a clone at home/projects/proj
  xseed
  xput home/records/backlog.md "$XLEDGER"
  xput home/data/ep/branches 'proj epic/ep
'
  xput home/data/ft/branches 'proj feat/ft push=deferred
'
  xput home/data/ret/branches '# retired 2026-01-01
proj epic/ret
'
  xput home/data/archive/2025/arc/branches 'proj epic/arc
'
  xrepo home/projects/proj
}
XLC=C; XENV=(); XHOMELESS=0; XCWD=cwd; XGONE=0; XPRE=""; XPATH=""; XNBIN="$BIN"
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v path; shift 3
  path="$PATH"; [ -z "$XPRE" ] || path="${XPRE//@H/$h}:$path"; [ -z "$XPATH" ] || path="${XPATH//@H/$h}"
  local a=() e=("LC_ALL=$XLC" "PATH=$path" "TMPDIR=$h/tmp" "STUB_DIR=$h")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h/$XCWD" && { [ "$XGONE" != 1 ] || rmdir "$h/$XCWD"; } && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_BACKEND -u CDPATH \
    "${e[@]}" "$bin/ac-brief.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
xnorm() {  # xnorm <file> <side root>
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-brief#ROOT#g" -e "s#$TMP/xdecoy#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$xobin" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$XNBIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "brief differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "brief differential stdout differs for '$*' at line $(xrow): $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_err() {
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "brief differential stderr differs for '$*' at line $(xrow): $(diff "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - what a row may change
  local h="$1" f r
  (cd "$h" && { find . -path '*/.git' -prune -o -print 2>/dev/null || true; } | LC_ALL=C sort)
  (cd "$h" && { find home 'my home' tmp -path '*/.git' -prune -o \( -type f -o -type l \) -print 2>/dev/null || true; } | LC_ALL=C sort) | while IFS= read -r f; do
    if [ -L "$h/$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$h/$f")"; continue; fi
    printf '== %s %s\n' "$f" "$(ls -l "$h/$f" | cut -c1-10)"; cat "$h/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  for r in "$h"/home/projects/*; do
    [ -d "$r/.git" ] || continue
    printf '== porcelain %s\n' "$r"; git -C "$r" status --porcelain 2>&1 || true
  done
}
xsame_world() {
  xworld "$XOH" >"$TMP/xo.world"; xworld "$XNH" >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "brief differential world differs after '$*' at line $(xrow): $(diff "$TMP/xo.world2" "$TMP/xn.world2" | head -n 12)"
}
xsame() { xpair "$@"; xsame_rc_out "$@"; xsame_err "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoout() { cat "$TMP/xo.out"; }
xoerr() { cat "$TMP/xo.err2"; }
xbrief() { xnorm "$XNH/$1" "$XNH"; }   # xbrief <path under the side> - the shim side's file, normalised
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "brief refusal for '$*' at line $(xrow)"
}
xmade() {  # xmade <path under the side> <args...> - both sides scaffold alike, the brief at <path>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xerr)" "0:" "brief scaffold for '$*' at line $(xrow)"
  assert_contains "$(xout)" "brief scaffolded: @H/$want (stage: " "the scaffold of '$*' at line $(xrow)"
  [ -f "$XNH/$want" ] || fail "no brief at $want for '$*' at line $(xrow)"
}
xwithout() {  # xwithout <tool> - the leg's PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
XUSAGE='ERROR: usage: ac-brief.sh <id> <project-name> [--scout | --stage <s>]'
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XUNSPEC() { printf "ERROR: mode unspecified for '%s': pass --mode <crew-ship|direct-pr|local-only|feature-pr> (your triage - the time-expensive crew-ship will still ask the captain), or pin it on the backlog row's contract group. There is no registry default any more (captain order: mode is per-task)" "$1"; }
XUNAUTH() { printf "ERROR: time-expensive mode(s) not confirmed:%s - the captain's rule: confirm BEFORE using staged/crew-ship/qa/independent review. Put ONE ask to the captain carrying (1) the REASON each is warranted for THIS task (the signal: financial surface, behavioral surface, multi-file risk, ...), (2) the options, (3) your lean - then either PIN the answer on the backlog row's contract group (e.g. [src:cap flow:staged mode:crew-ship rev:yes qa:no]) so it is never re-asked, or re-run with --captain-requested '<the captain's words, or the order ref>' (nothing scaffolded)" "$1"; }
XRAISE() { printf "ERROR: review=yes on direct + %s is the CAPTAIN's call, not a chief's (delivery-review skill: 'no by default, optional yes when the captain requests independent review'); if they asked for it, PIN rev:yes on the backlog row's contract group or re-run with --captain-requested '<their words, or the order ref>' - if they did not, drop --review yes" "$1"; }
XROOTED=0; [ "$(id -u)" != 0 ] || XROOTED=1

# 1. arguments, in code order, every one before any home read: fewer than
#    two words (none, '', one word, -h), an unknown flag before the empty-id
#    check, an extra positional, each value flag as the last word, a value
#    flag swallowing the next word, last-wins, the id grammar under C and
#    UTF-8, the stage, the review value, the profile charset; --mode '' reads
#    as no flag, --scout ignores --mode, and dash-led ids scaffold (W13).
XHOMELESS=1
xboth xseed
xrefuse "$XUSAGE"
xrefuse "$XUSAGE" ''
xrefuse "$XUSAGE" x
xrefuse "$XUSAGE" -h
xrefuse "ERROR: unknown flag: --bogus" '' '' --bogus
xrefuse "ERROR: unknown flag: c" a b c
xrefuse "$XUSAGE" '' p
xrefuse "$XUSAGE" a ''
for xf in --stage --mode --review --captain-requested --reason --qa-required-profile; do
  xrefuse "ERROR: $xf needs a value" a b "$xf"
done
xrefuse "ERROR: invalid --review: --scout (want yes|no)" a b --review --scout
xrefuse "ERROR: unknown flag: --bogus" a b --mode x --bogus
xrefuse "ERROR: unknown stage:  (want spec|architecture|plan|implement|design|qa)" a b --stage ''
xrefuse "ERROR: unknown stage: chief (want spec|architecture|plan|implement|design|qa)" a b --stage chief
xrefuse "ERROR: unknown stage: code-review (want spec|architecture|plan|implement|design|qa)" a b --scout --stage code-review
xrefuse "ERROR: invalid --review: maybe (want yes|no)" a b --review maybe
xrefuse "ERROR: invalid --review: Yes (want yes|no)" a b --review Yes
for xid in Bad t_1 'a b' 'a/b' $'\xc3\x891'; do
  xrefuse "ERROR: id must be [a-z0-9-]: $xid" "$xid" p
done
XLC=en_US.UTF-8
for xid in Bad t_1 $'\xc3\x891' $'\xc3\xa91'; do
  xrefuse "ERROR: id must be [a-z0-9-]: $xid" "$xid" p
done
XLC=C
xrefuse "ERROR: invalid --qa-required-profile '' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)" a p --qa-required-profile ''
xrefuse "ERROR: invalid --qa-required-profile 'a b' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)" a p --qa-required-profile ok/x/y --qa-required-profile 'a b' --qa-required-profile ''
xrefuse "ERROR: invalid --qa-required-profile 'x.y' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)" a p --qa-required-profile x.y
xrefuse "$XNOHOME" a p --qa-required-profile a --qa-required-profile / --review no --stage spec --scout
XHOMELESS=0
xboth xstd
xrefuse "$(XUNSPEC a)" a proj --mode ''
xmade home/data/sm/brief.md sm proj --scout --mode bogus
xmade home/data/-x/brief.md -x proj --mode local-only
xmade home/data/--/brief.md -- proj --mode local-only
xmade home/data/--scout/brief.md --scout myid --mode local-only
assert_contains "$(xbrief home/data/--scout/brief.md)" "Project: myid" "1 (W13): a mis-ordered --scout is the id"
xmade home/data/lw/brief.md lw proj --stage spec --mode d --scout --mode local-only

# 2. the home: unset (with AC_FLEET_STATE too), relative to the caller's cwd,
#    and the named divergences - an AC_HOME cd cannot enter or that is a file
#    (HOME RESOLUTION: the original's own cd line), a relative AC_HOME from a
#    cwd with no name, a relative AC_HOME under an exported CDPATH (the
#    original's cd echoed into the path), and bun off PATH (the original
#    scaffolded where no ledger exists, and printed its parser's lines where
#    one does; the shim refuses before anything).
XHOMELESS=1
xrefuse "$XNOHOME" t1 proj --mode local-only
XENV=("AC_FLEET_STATE=@H/home/state")
xrefuse "$XNOHOME" t1 proj --mode local-only
XENV=(); XHOMELESS=0
xboth xstd
XCWD=.; XENV=("AC_HOME=home")
xmade home/data/t1/brief.md t1 proj --mode local-only
XCWD=cwd; XENV=("AC_HOME=@H/nope")
xpair t1 proj --mode local-only
xsame_rc_out t1
assert_eq "$XN_RC:$(xerr)" "1:ERROR: AC_HOME is not a readable directory: @H/nope" "2 (HOME RESOLUTION, named): an AC_HOME cd cannot enter is named"
assert_eq "$(xoerr)" "ROOT/bin/ac-lib.sh: line 60: cd: @H/nope: No such file or directory" "2: the original's line for it is cd's own"
xsame_world t1
XENV=("AC_HOME=@H/home/projects/proj/file.txt")
xpair t1 proj --mode local-only
xsame_rc_out t1
assert_eq "$XN_RC:$(xerr)" "1:ERROR: AC_HOME is not a readable directory: @H/home/projects/proj/file.txt" "2 (HOME RESOLUTION, named): a file is no home"
assert_contains "$(xoerr)" ": Not a directory" "2: the original's line for a file is cd's own"
# Both bashes' own shell-init/chdir complaints about the cwd aside (SHELL-OWN).
x2cwd() { grep -v -E '^(shell-init|chdir): error retrieving current directory' "$1" || true; }
# From a cwd with no name bun sits in its bin's root, so the shim runs from a
# DECOY root holding a home/ and a repo a regression would resolve.
xdecoy="$TMP/xdecoy"
rm -rf "$xdecoy"; mkdir -p "$xdecoy/home"; cp -R "$ROOT/bin" "$ROOT/src" "$ROOT/dashboard" "$xdecoy/"
git init -q -b main "$xdecoy"; git -C "$xdecoy" commit -q --allow-empty -m decoy
XNBIN="$xdecoy/bin"
XCWD=cwd; XGONE=1; XENV=("AC_HOME=home")
xpair t1 proj --mode local-only
assert_eq "$XO_RC:$XN_RC:$(x2cwd "$TMP/xn.err2")" "1:1:ERROR: AC_HOME is not a readable directory: home" "2 (named): a relative AC_HOME from a cwd with no name resolves nowhere"
assert_eq "$(x2cwd "$TMP/xo.err2")" "ROOT/bin/ac-lib.sh: line 60: cd: home: No such file or directory" "2: ...where the original's cd failed on it"
xboth mkdir -p @H/cwd
XENV=()
xpair t2 src --mode local-only
xsame_rc_out t2
assert_eq "$XN_RC:$(x2cwd "$TMP/xn.err2")" "0:" "2 (named): from a cwd with no name a project is looked up under projects/ only"
case "$(xbrief home/data/t2/brief.md)" in *repo-knowledge*) fail "2: the distro's own src/ is never the project" ;; esac
xsame_world t2
xboth mkdir -p @H/cwd
[ ! -e "$xdecoy/home/data" ] || fail "2: nothing is minted under the decoy root's home/"
XNBIN="$BIN"
XGONE=0; XCWD=.; XENV=("AC_HOME=home" "CDPATH=@H")
xpair t3 proj --mode local-only
assert_eq "$XN_RC:$(xout):$(xerr)" "0:brief scaffolded: @H/home/data/t3/brief.md (stage: implement):" "2 (HOME RESOLUTION, named): CDPATH never moves the home"
assert_eq "$XO_RC" 0 "2: the original scaffolded too..."
assert_contains "$(xoout)" "brief scaffolded: @H/home"$'\n'"@H/home/data/t3/brief.md" "2: ...under a path cd's echo doubled"
XCWD=cwd; XENV=()
xboth xseed
XPATH="$(xwithout bun)"
xpair t1 proj --mode local-only
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "2 (BUN, named): the shim refuses without bun"
assert_eq "$XO_RC" 0 "2: the original scaffolded with no ledger to parse"
xboth xput home/records/backlog.md "$XLEDGER"
xpair l proj
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "2 (BUN, named): the shim refuses without bun, a ledger or not"
assert_eq "$XO_RC:$(xoerr)" "1:ERROR: required tool not found: bun
ERROR: the backlog parser failed on @H/home/records/backlog.md
ERROR: cannot read the ledger @H/home/records/backlog.md for the delivery contract of l" "2: the original refused through its parser's lines"
XPATH=""

# 3. the layout: flat, every stage at its nested dir, -rN revisions, the
#    unsuffixed implement, suffix contradictions, the canonical form, a brief
#    already there (a file, a directory), the other layout in every
#    direction (the tasks/ twin by longest prefix), AC_SCOPE nesting, the
#    two holes of the other-layout refusal (W14), and a dangling symlink at
#    the brief (W15, named by the Q5 ruling).
# data/ is minted at the home read; records/ at the first ledger question -
# the mode's, or a --scout's fence - ledger or none.
xboth xseed
xrefuse "ERROR: --stage spec needs the canonical id form <task>-spec[-rN] (got 'r0')" r0 noclone --stage spec
xrefuse "$(XUNSPEC r0)" r0 noclone
xmade home/data/r0/brief.md r0 noclone --mode local-only
xboth xseed
xmade home/data/r1/brief.md r1 noclone --scout
xboth xstd
xmade home/data/l/brief.md l proj
xmade home/data/lx/brief.md lx proj --scout
xmade home/data/s/spec/brief.md s-spec proj --stage spec
xmade home/data/s/arch/brief.md s-arch proj --stage architecture
xmade home/data/s/plan/brief.md s-plan proj --stage plan
xmade home/data/s/design/brief.md s-design proj --stage design
xmade home/data/s/implement/brief.md s proj --stage implement
xmade home/data/s/qa/brief.md s-qa proj --stage qa
xmade home/data/s/spec-r2/brief.md s-spec-r2 proj --stage spec
xmade home/data/s/implement-r2/brief.md s-r2 proj --stage implement
xmade home/data/s/qa-r12/brief.md s-qa-r12 proj --stage qa
xrefuse "ERROR: id suffix of 's-spec' maps to stage dir 'spec' but --stage implement wants 'implement'" s-spec proj --stage implement
xrefuse "ERROR: id suffix of 's-chief' maps to stage dir 'chief' but --stage implement wants 'implement'" s-chief proj --stage implement
xrefuse "ERROR: id suffix of 's-review' maps to stage dir 'review' but --stage spec wants 'spec'" s-review proj --stage spec
xrefuse "ERROR: id suffix of 's-spec-r3' maps to stage dir 'spec-r3' but --stage architecture wants 'arch'" s-spec-r3 proj --stage architecture
xrefuse "ERROR: --stage spec needs the canonical id form <task>-spec[-rN] (got 's-x')" s-x proj --stage spec
xrefuse "ERROR: --stage spec needs the canonical id form <task>-spec[-rN] (got 's-spec-r100')" s-spec-r100 proj --stage spec
xrefuse "ERROR: --stage architecture needs the canonical id form <task>-arch[-rN] (got 's')" s proj --stage architecture
# W19: --stage scout passes the stage check and dies on set -u's unbound
# $short after data/ is minted - its line is the shell's (SHELL-OWN, named).
for xid in t19 t19-spec; do
  xpair "$xid" proj --stage scout
  xsame_rc_out "$xid"; xsame_world "$xid"
  assert_eq "$XN_RC:$(xerr)" "1:" "3 (W19): --stage scout ends the run 1, the shell's line not reproduced"
  assert_contains "$(xoerr)" ": short: unbound variable" "3: the original's line"
done
xrefuse "ERROR: brief already exists: @H/home/data/l/brief.md" l proj
xrefuse "ERROR: brief already exists: @H/home/data/s/spec/brief.md" s-spec proj --stage spec
xboth mkdir -p @H/home/data/dir/brief.md
xrefuse "ERROR: brief already exists: @H/home/data/dir/brief.md" dir proj --mode local-only
xrefuse "ERROR: a brief for 'l' already exists in the other layout: @H/home/data/l/brief.md" l proj --stage implement
xrefuse "ERROR: a brief for 's-spec' already exists in the other layout: @H/home/data/s/spec/brief.md" s-spec proj --scout
xrefuse "ERROR: a brief for 's' already exists in the other layout: @H/home/data/s/implement/brief.md" s proj --mode local-only
xboth xput home/data/a-b/tasks/c-d/brief.md 'nested
'
xboth xput home/data/a/tasks/b-c-d/brief.md 'nested, a shorter prefix
'
xrefuse "ERROR: a brief for 'a-b-c-d' already exists in the other layout: @H/home/data/a-b/tasks/c-d/brief.md" a-b-c-d proj --mode local-only
XENV=("AC_SCOPE=s")
xmade home/data/s/tasks/sl/brief.md s-sl proj --mode local-only
xmade home/data/s/tasks/sl-two/brief.md s-sl-two proj --mode local-only
xmade home/data/s/spec-r3/brief.md s-spec-r3 proj --stage spec
xmade home/data/s-r3/brief.md s-r3 proj --mode local-only
xmade home/data/x-a/brief.md x-a proj --mode local-only
xrefuse "ERROR: a brief for 'l' already exists in the other layout: @H/home/data/l/brief.md" l proj --stage implement
XENV=("AC_SCOPE=l")
xmade home/data/l/tasks/w/brief.md l-w proj --mode local-only
xboth xput home/data/l-x/brief.md 'a flat brief
'
xrefuse "ERROR: a brief for 'l-x' already exists in the other layout: @H/home/data/l-x/brief.md" l-x proj --mode local-only
XENV=("AC_SCOPE=")
xmade home/data/s-flat/brief.md s-flat proj --mode local-only
XENV=()
xrefuse "ERROR: a brief for 'l-w' already exists in the other layout: @H/home/data/l/tasks/w/brief.md" l-w proj --mode local-only
xrefuse "ERROR: a brief for 's-sl' already exists in the other layout: @H/home/data/s/tasks/sl/brief.md" s-sl proj --mode local-only
xmade home/data/w-chief/brief.md w-chief proj --mode local-only
xmade home/data/s-sl/implement/brief.md s-sl proj --stage implement --mode local-only --captain-requested 'W14 (b)' --reason 'the staged twin of a fan-out'
xboth xstd
xboth mkdir -p @H/home/data/t2 @H/outside
xboth ln -s @H/outside/nowhere @H/home/data/t2/brief.md
xpair t2 proj --mode local-only
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: brief already exists: @H/home/data/t2/brief.md" "3 (W15, named): a dangling symlink at the brief is refused, never written through"
assert_eq "$XO_RC" 0 "3: the original wrote through it..."
[ -f "$XOH/outside/nowhere" ] && [ ! -e "$XNH/outside/nowhere" ] || fail "3: ...into the link's target, which the port never creates"

# 4. the mode: the flag, the pin, both agreeing, a contradiction, none (a
#    spec or qa stage owes one too), the family's pin for a stage id and for
#    an exact contractless stage row, a TAB-joined pin, 01 never 1, an empty
#    mode token, a pinned mode nothing validates and a doubled one (W7), a
#    ledger that is a directory or absent, and one that cannot be read (awk's
#    own two lines named: the ledger is read in-process).
xboth xstd
xmade home/data/m1/brief.md m1 proj --mode direct-pr
xmade home/data/l/brief.md l proj
xmade home/data/d/brief.md d proj --mode direct-pr
xrefuse "ERROR: --mode crew-ship contradicts the row's pinned mode:local-only - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)" lr proj --mode crew-ship --review yes --captain-requested c --reason r
xrefuse "ERROR: invalid --mode: bogus (want crew-ship|direct-pr|local-only|feature-pr)" m2 proj --mode bogus
xrefuse "ERROR: invalid --mode: bogus (want crew-ship|direct-pr|local-only|feature-pr)" lr proj --mode bogus
xrefuse "$(XUNSPEC m3)" m3 proj
xrefuse "$(XUNSPEC m3-spec)" m3-spec proj --stage spec
xrefuse "$(XUNSPEC m3-qa)" m3-qa proj --stage qa
xrefuse "$(XUNSPEC bare)" bare proj
xrefuse "$(XUNSPEC eg)" eg proj
xmade home/data/f/spec/brief.md f-spec proj --stage spec
xmade home/data/f/plan/brief.md f-plan proj --stage plan
xmade home/data/f/arch-r2/brief.md f-arch-r2 proj --stage architecture
xrefuse "ERROR: --mode crew-ship contradicts the row's pinned mode:local-only - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)" tab proj --mode crew-ship --captain-requested c --reason r
xmade home/data/tab/brief.md tab proj
xrefuse "ERROR: --mode crew-ship contradicts the row's pinned mode:local-only - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)" 1 proj --mode crew-ship --captain-requested c --reason r
xmade home/data/01/brief.md 01 proj
xmade home/data/bogus/brief.md bogus proj
assert_contains "$(xbrief home/data/bogus/brief.md)" "Mode: bogus" "4 (W7): a pinned mode reaches the brief unvalidated"
xrefuse "ERROR: --mode local-only contradicts the row's pinned mode:local-only
crew-ship - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)" twice proj --mode local-only
xmade home/data/twice/brief.md twice proj
assert_contains "$(xbrief home/data/twice/brief.md)" "Mode: local-only"$'\n'"crew-ship"$'\n'"Review: no" "4 (W7): a doubled pin is both values, one per line"
if [ "$XROOTED" = 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xpair m4 proj --mode local-only
  xsame_rc_out m4; xsame_world m4
  assert_eq "$XN_RC:$(xerr)" "1:ERROR: cannot read the ledger @H/home/records/backlog.md for the delivery contract of m4" "4 (IN-PROCESS LEDGER, named): an unreadable ledger refuses in the entry's own words"
  assert_eq "$(xoerr)" "awk: can't open file @H/home/records/backlog.md
 source line number 26
ERROR: cannot read the ledger @H/home/records/backlog.md for the delivery contract of m4" "4: the original printed awk's two lines first"
  xrefuse "ERROR: cannot read the ledger to resolve the epic-branch fence for m5" m5 proj --scout
  xboth chmod 644 @H/home/records/backlog.md
fi
xboth rm -f @H/home/records/backlog.md
xboth mkdir @H/home/records/backlog.md
xrefuse "$(XUNSPEC l9)" l9 proj
xmade home/data/l9/brief.md l9 proj --mode local-only
xboth rmdir @H/home/records/backlog.md
xmade home/data/l10/brief.md l10 proj --mode crew-ship --captain-requested 'no ledger at all' --reason 'the gate still asks'

# 5. the fence: an epic story's PR base, a crew-ship story's EPIC TARGET, a
#    staged story's review default no and its raise by pin, by declaration
#    and refused, a feature member with its record and without one, --mode
#    feature-pr on no fence, a retired and an archived record, and a project
#    given as a path, which misses the fence (W2).
xboth xstd
xmade home/data/ep-s1/brief.md ep-s1 proj
assert_contains "$(xbrief home/data/ep-s1/brief.md)" 'open a PR against the epic integration branch `epic/ep`' "5: an epic story's PR base"
xmade home/data/ep-s2/brief.md ep-s2 proj
assert_contains "$(xbrief home/data/ep-s2/brief.md)" '- EPIC TARGET: start the engine with `--target epic/ep`' "5: a crew-ship story's target"
xmade home/data/eps/implement/brief.md eps proj --stage implement
assert_contains "$(xbrief home/data/eps/implement/brief.md)" "Review: no (epic gate owns the review round - captain ruling 2026-08-19)" "5: a staged story owes no review"
xmade home/data/eps/spec/brief.md eps-spec proj --stage spec
xmade home/data/eps/design/brief.md eps-design proj --stage design
xmade home/data/epr/implement/brief.md epr proj --stage implement --review yes
assert_contains "$(xbrief home/data/epr/implement/brief.md)" "Review: yes (the captain's word: a rev:yes pin or --captain-requested, checked by the escalation gate)" "5: the raise by pin"
xmade home/data/eps/implement-r2/brief.md eps-r2 proj --stage implement --review yes --captain-requested 'review this story' --reason 'a risky story'
xrefuse "$(XUNAUTH ' rev:yes')" eps-r3 proj --stage implement --review yes
xmade home/data/ft-m1/brief.md ft-m1 proj
assert_contains "$(xbrief home/data/ft-m1/brief.md)" 'the feature integration branch `feat/ft`' "5: a feature member lands on its record's branch"
xrefuse "ERROR: mode:feature-pr for 'ft-m2' resolves no integration-branch record - token the row 'feature:<name>', write data/<name>/branches ('proj <branch> [target=<t>] push=deferred', the captain's word receipted DECIDED: to the room), and cut it with ac-feature.sh create <name> proj" ft-m2 proj
xrefuse "ERROR: mode:feature-pr for 'm6' resolves no integration-branch record - token the row 'feature:<name>', write data/<name>/branches ('proj <branch> [target=<t>] push=deferred', the captain's word receipted DECIDED: to the room), and cut it with ac-feature.sh create <name> proj" m6 proj --mode feature-pr
xmade home/data/ret-s/brief.md ret-s proj
assert_contains "$(xbrief home/data/ret-s/brief.md)" "open a PR against the target branch" "5: a retired record is no fence"
xmade home/data/arc-s/brief.md arc-s proj
assert_contains "$(xbrief home/data/arc-s/brief.md)" 'open a PR against the epic integration branch `epic/arc`' "5: an archived record still fences"
xmade home/data/ep-sc/brief.md ep-sc proj --scout
XCWD=.
xmade home/data/ep-s4/brief.md ep-s4 home/projects/proj --mode direct-pr
assert_contains "$(xbrief home/data/ep-s4/brief.md)" "open a PR against the target branch" "5 (W2): a relative path project misses the fence"
xmade home/data/ep-s5/brief.md ep-s5 @H/home/projects/proj --mode direct-pr
assert_contains "$(xbrief home/data/ep-s5/brief.md)" "open a PR against the target branch" "5 (W2): so does an absolute one"
xrefuse "ERROR: mode:feature-pr for 'ft-m3' resolves no integration-branch record - token the row 'feature:<name>', write data/<name>/branches ('@H/home/projects/proj <branch> [target=<t>] push=deferred', the captain's word receipted DECIDED: to the room), and cut it with ac-feature.sh create <name> @H/home/projects/proj" ft-m3 @H/home/projects/proj
XCWD=cwd

# 6. the review obligation and the escalation gate: every review line, the
#    optional raise by its exact row's pin (a family pin on an -rN id does not
#    raise it - W8), by declaration and refused, an empty ref, a scout's
#    raise (its mode is "" - two spaces), every unauthorized list in its
#    order, a declaration with nothing to authorize, the reason missing,
#    multi-line or idle, an empty or multi-line ref that authorizes anyway
#    (W9), and the qa charter that records no Escalation line (W10).
xboth xstd
xmade home/data/lr/brief.md lr proj --review yes
assert_contains "$(xbrief home/data/lr/brief.md)" "Review: yes (pinned on the backlog row)" "6: the raise by the exact row's pin"
xmade home/data/l2/brief.md l2 proj --mode local-only --review yes --captain-requested 'the captain asked' --reason 'independent eyes'
assert_contains "$(xbrief home/data/l2/brief.md)" "Review: yes (captain-requested: the captain asked)"$'\n'"Escalation: rev:yes - captain-requested: the captain asked - reason: independent eyes" "6: the raise by declaration"
xmade home/data/l3/brief.md l3 proj --mode local-only --review no
xmade home/data/dr/brief.md dr proj --review yes
xmade home/data/d4/brief.md d4 proj --mode direct-pr --review yes --captain-requested 'pr review' --reason 'a public api'
xrefuse "ERROR: staged flow requires review=yes; --review no is not allowed" s proj --stage implement --review no
xrefuse "ERROR: crew-ship requires review=yes; --review no is not allowed" c proj --review no
xrefuse "$(XRAISE local-only)" l4 proj --mode local-only --review yes
xrefuse "$(XRAISE direct-pr)" d5 proj --mode direct-pr --review yes
xrefuse "$(XRAISE local-only)" fam2-r2 proj --review yes
xrefuse "$(XRAISE local-only)" 1 proj --review yes
xmade home/data/01/brief.md 01 proj --review yes
xrefuse "ERROR: --captain-requested needs a non-empty ref: name the captain words or order this review carries out" l5 proj --mode local-only --review yes --captain-requested ''
xrefuse "$(XRAISE '')" sc1 proj --scout --review yes
xmade home/data/sc2/brief.md sc2 proj --scout --review yes --captain-requested 'a scout review'
xmade home/data/sc3/brief.md sc3 proj --scout --review yes --captain-requested 'a scout review' --reason 'kept nowhere'
xrefuse "ERROR: --captain-requested with nothing to authorize: this call uses no time-expensive mode (staged/crew-ship/qa/review) - drop the flag" sc4 proj --scout --captain-requested 'c'
xrefuse "ERROR: --captain-requested with nothing to authorize: this call uses no time-expensive mode (staged/crew-ship/qa/review) - drop the flag" n1 proj --mode local-only --captain-requested 'c' --reason r
xrefuse "$(XUNAUTH ' flow:staged mode:crew-ship qa:yes')" u1 proj --stage implement --mode crew-ship --qa-required-profile a/b/c
xrefuse "$(XUNAUTH ' mode:crew-ship')" u2 proj --mode crew-ship
xrefuse "$(XUNAUTH ' qa:yes')" u3 proj --mode local-only --qa-required-profile a/b/c
xrefuse "$(XUNAUTH ' flow:staged')" u4-spec proj --stage spec --mode local-only
xrefuse "$(XUNAUTH ' qa:yes')" c proj --qa-required-profile a/b/c
xrefuse "ERROR: --captain-requested authorizes time-expensive mode(s) but carries no --reason '<the justification you gave the captain>': the reason must ride the record, not just the ask (nothing scaffolded)" r1 proj --mode crew-ship --captain-requested 'c'
xrefuse "ERROR: --reason must be a single line" r2 proj --mode crew-ship --captain-requested 'c' --reason $'two\nlines'
xrefuse "ERROR: --reason must be a single line" r3 proj --mode crew-ship --captain-requested 'c' --reason $'cr\r'
xrefuse "ERROR: --reason without --captain-requested documents an ask that never happened: a pinned row needs no reason (the pin is the captain's own act) and the cheap path spends nothing - drop the flag" r4 proj --mode local-only --reason 'x'
xrefuse "ERROR: --reason without --captain-requested documents an ask that never happened: a pinned row needs no reason (the pin is the captain's own act) and the cheap path spends nothing - drop the flag" c proj --reason 'x'
xmade home/data/w9/brief.md w9 proj --mode crew-ship --captain-requested '' --reason r
assert_contains "$(xbrief home/data/w9/brief.md)" "Escalation: mode:crew-ship rev:yes - captain-requested:  - reason: r" "6 (W9): an empty ref authorizes"
xmade home/data/w9b/brief.md w9b proj --mode crew-ship --captain-requested $'two\nlines' --reason r
xmade home/data/w10/qa/brief.md w10-qa proj --stage qa --mode local-only --captain-requested 'captain-said-qa' --reason 'behavioral-surface'
case "$(xbrief home/data/w10/qa/brief.md)" in *Escalation*|*behavioral-surface*) fail "6 (W10): the qa charter records no Escalation line" ;; esac
xmade home/data/e4/implement/brief.md e4 proj --stage implement --mode crew-ship --qa-required-profile a/b/c --captain-requested 'all four' --reason 'the whole pipeline'
assert_contains "$(xbrief home/data/e4/implement/brief.md)" "Escalation: flow:staged mode:crew-ship qa:yes rev:yes - captain-requested: all four - reason: the whole pipeline" "6: every spent mode on the line, in order"
xmade home/data/c/brief.md c proj
xmade home/data/sc/implement/brief.md sc proj --stage implement
xmade home/data/x/spec/brief.md x-spec proj --stage spec --mode local-only --captain-requested 'spec it' --reason 'unclear order'
xmade home/data/x/arch/brief.md x-arch proj --stage architecture --mode crew-ship --captain-requested 'arch it' --reason 'many modules'
xmade home/data/x/plan/brief.md x-plan proj --stage plan --mode direct-pr --captain-requested 'plan it' --reason 'ordering'
xmade home/data/x/design/brief.md x-design proj --stage design --mode local-only --captain-requested 'design it' --reason 'all three'
xmade home/data/sd/design/brief.md sd-design proj --stage design
xmade home/data/sd/implement/brief.md sd proj --stage implement

# 7. the templates, whole files, with the knowledge block's arms: no clone,
#    a directory that is no repo, a linked worktree given by path (its main
#    repo names the record), a project name a directory in the caller's cwd
#    shadows (W3), a home whose path holds a space; then every shape of
#    records/captain.md the standing-rules block reads, and config/captain's
#    bytes (W16).
xboth xstd
xmade home/data/k1/brief.md k1 noclone --mode local-only
case "$(xbrief home/data/k1/brief.md)" in *ac-know.sh*|*repo-knowledge*) fail "7: no clone names no record" ;; esac
xboth mkdir -p @H/home/projects/plain
xmade home/data/k2/brief.md k2 plain --mode local-only
xboth git -C @H/home/projects/proj worktree add -q --detach @H/wt
xmade home/data/k3/brief.md k3 @H/wt --mode local-only
assert_contains "$(xbrief home/data/k3/brief.md)" "full:     cat @H/home/records/repo-knowledge/proj.md" "7: a worktree names its main repo's record"
x7w3() { xrepo other; xcommit_other; git -C "$H/other" worktree add -q --detach "$H/cwd/proj"; }
xcommit_other() { printf 'other\n' >"$H/other/o.txt"; git -C "$H/other" add o.txt; git -C "$H/other" commit -qm other; }
xboth x7w3
xmade home/data/k4/brief.md k4 proj --mode local-only --qa-required-profile a/b/c --captain-requested 'the shadow' --reason 'W3'
assert_contains "$(xbrief home/data/k4/brief.md)" "repo-knowledge/other.md" "7 (W3): the cwd's directory shadows the project"
assert_contains "$(cat "$XNH/home/data/k4/qa/manifest.json")" "\"source_ref\": \"$(git -C "$XNH/other" rev-parse HEAD)\"" "7 (W3): ...and its head is the manifest's source"
xboth rm -rf @H/cwd/proj
x7sp() { xseed; mkdir -p "$H/my home"; xrepo 'my home/projects/proj'; }
xboth x7sp
XENV=("AC_HOME=@H/my home")
xpair k5 proj --mode local-only
xsame_rc_out k5; xsame_err k5; xsame_world k5
assert_contains "$(xbrief "my home/data/k5/brief.md")" "--home @H/my home --repo" "7: a home path with a space is baked unquoted"
XENV=()
xboth xstd
xmade home/data/cap0/brief.md cap0 proj --mode local-only
XCAPMD=$'- 2026-01-01: STANDING (captain): ONE, always.\n- 2026-01-02: STANDING (captain) - MULTI, this rule\n  continues here\n\tand with a TAB.\n- 2026-01-03: STANDING (domain:widgets): DOMAIN only.\n- 2026-01-04: housekeeping, not a rule.\n- STANDING_y counts\n- STANDING-ISH does not\n- NOTSTANDING does not\nplain STANDING orphan line\n\n## STANDING heading orphan\n- a CRLF STANDING rule\r\n- an indented domain block\n  STANDING (domain:x): inside it\n- a last STANDING rule with no newline'
xboth xput home/records/captain.md "$XCAPMD"
xmade home/data/cap1/brief.md cap1 proj --mode local-only
assert_contains "$(xbrief home/data/cap1/brief.md)" "UNPARSED - mentions STANDING but is not a \`- \` bulleted block" "7: the orphans are named"
xboth xput home/records/captain.md $'plain STANDING orphan only\n'
xmade home/data/cap2/brief.md cap2 proj --mode local-only
assert_contains "$(xbrief home/data/cap2/brief.md)" "(no STANDING-marked entries found in @H/home/records/captain.md)" "7: no block selected"
xboth xput home/records/captain.md ''
xmade home/data/cap3/brief.md cap3 proj --mode local-only
xboth rm -f @H/home/records/captain.md
xboth mkdir @H/home/records/captain.md
xmade home/data/cap4/brief.md cap4 proj --mode local-only
xboth rmdir @H/home/records/captain.md
if [ "$XROOTED" = 0 ]; then
  xboth xput home/records/captain.md "$XCAPMD"
  xboth chmod 000 @H/home/records/captain.md
  xmade home/data/cap5/brief.md cap5 proj --mode local-only
  assert_contains "$(xbrief home/data/cap5/brief.md)" "(no standing preferences file on record)" "7: an unreadable captain.md is said so"
  xboth chmod 644 @H/home/records/captain.md
fi
xboth rm -f @H/home/records/captain.md
xmade home/data/cap6/brief.md cap6 proj --mode local-only
assert_contains "$(xbrief home/data/cap6/brief.md)" "Captain: captain" "7: the role word by default"
xboth xput home/config/captain ''
xmade home/data/cap7/brief.md cap7 proj --mode local-only
assert_contains "$(xbrief home/data/cap7/brief.md)" "Captain: "$'\n' "7: an empty config/captain names no one"
xboth xput home/config/captain $'\xc2\xa0Anh TN \r\n'
xmade home/data/cap8/brief.md cap8 proj --mode local-only
assert_contains "$(xbrief home/data/cap8/brief.md)" "Captain: "$'\xc2\xa0'"Anh TN"$'\n' "7 (W16): under C a NBSP is a byte, kept"
XLC=en_US.UTF-8
xmade home/data/cap9/brief.md cap9 proj --mode local-only
assert_contains "$(xbrief home/data/cap9/brief.md)" "Captain: Anh TN"$'\n' "7 (W16): under UTF-8 it is space, trimmed"
XLC=C
xboth xput home/config/captain $'Tu\xe9n\n'
xmade home/data/cap10/brief.md cap10 proj --mode local-only
assert_contains "$(xbrief home/data/cap10/brief.md)" "Captain: Tu"$'\xe9'"n"$'\n' "7 (W16): a latin1 byte is kept raw"
if [ "$XROOTED" = 0 ]; then
  xboth chmod 000 @H/home/config/captain
  xsame cap11 proj --mode local-only
  assert_eq "$XN_RC:$(xerr)" "0:head: @H/home/config/captain: Permission denied" "7 (W16): an unreadable config/captain is head's own line"
  assert_contains "$(xbrief home/data/cap11/brief.md)" "Captain: "$'\n' "7 (W16): ...and no name, not the default"
  xboth chmod 644 @H/home/config/captain
fi
xboth rm -f @H/home/config/captain

# 8. the qa store, named by the one deriver (ac-qa.sh store-dir) or not at
#    all: a clone, no clone, a store-dir that refuses (an invalid
#    config/backend), a store= its current run recorded; and the oracle run
#    as bin/ac-brief.sh from the home, which lost the store (W1, named by the
#    Q2 ruling: the port resolves ac-qa.sh from its own bin/).
xboth xstd
xmade home/data/s/qa/brief.md s-qa proj --stage qa
assert_contains "$(xbrief home/data/s/qa/brief.md)" "Knowledge store (pass this VERBATIM as \`--store <path>\` on step 1's \`start\` line - your pane has no AC_HOME to resolve it):"$'\n'"@H/home/data/qa-store/proj"$'\n' "8: the store-dir path is baked"
xmade home/data/q2/qa/brief.md q2-qa noclone --stage qa --mode local-only --captain-requested c --reason r
assert_contains "$(xbrief home/data/q2/qa/brief.md)" "No knowledge store is wired for this project yet" "8: no clone, no store"
xboth xput home/config/backend $'bogus\n'
xmade home/data/q3/qa/brief.md q3-qa proj --stage qa --mode local-only --captain-requested c --reason r
assert_contains "$(xbrief home/data/q3/qa/brief.md)" "No knowledge store is wired for this project yet" "8: a store-dir that refuses names none"
xboth rm -f @H/home/config/backend
x8run() { xput home/projects/proj/.crew/qa/r1/run.meta $'store=@H/elsewhere/store\n'; ln -s r1 "$H/home/projects/proj/.crew/qa/current"; }
xboth x8run
xmade home/data/q4/qa/brief.md q4-qa proj --stage qa --mode local-only --captain-requested c --reason r
assert_contains "$(xbrief home/data/q4/qa/brief.md)" $'\n'"@H/elsewhere/store"$'\n' "8: the run's recorded store"
xboth xstd
ln -s "$xobin" "$XOH/home/bin"; ln -s "$BIN" "$XNH/home/bin"
for xh in "$XOH" "$XNH"; do
  (cd "$xh/home" && exec env -u AC_FLEET_STATE -u AC_SCOPE -u AC_BACKEND -u CDPATH LC_ALL=C AC_HOME="$xh/home" TMPDIR="$xh/tmp" bin/ac-brief.sh s-qa proj --stage qa) </dev/null >/dev/null 2>&1 \
    || fail "8 (W1): the relative invocation scaffolds"
done
assert_contains "$(cat "$XOH/home/data/s/qa/brief.md")" "No knowledge store is wired for this project yet" "8 (W1, named): the original lost the store, run as bin/ac-brief.sh"
assert_contains "$(cat "$XNH/home/data/s/qa/brief.md")" $'\n'"$XNH/home/data/qa-store/proj"$'\n' "8 (W1, named): the port names it however it is invoked"

# 9. the manifest: one and several profiles, a family's (the last brief
#    wins), a scout's (W11), no clone (source_ref ""), the default branch's
#    arms (origin/HEAD, master, a detached HEAD and an unborn main, where git
#    prints the name it could not resolve and the original kept it), then the
#    named failure arms: jq off PATH and an unwritable qa dir (W6: the
#    original emptied or kept nothing, the port leaves the old manifest), a
#    planted symlink at the temp name (never written through), and a
#    non-ASCII profile under UTF-8 (W12: refused per the text).
xboth xstd
xmade home/data/lq/brief.md lq proj --qa-required-profile a/b/c
xmade home/data/cq/brief.md cq proj --qa-required-profile a/b/c --qa-required-profile d_e/F-g/h
xmade home/data/s/spec/brief.md s-spec proj --stage spec --qa-required-profile one/two/three
xmade home/data/s/implement/brief.md s proj --stage implement --qa-required-profile x/y/z
assert_contains "$(xout)" "required-profile manifest: @H/home/data/s/qa/manifest.json (1 profile(s))" "9: the manifest line"
assert_contains "$(cat "$XNH/home/data/s/qa/manifest.json")" '"profile_key": "x/y/z"' "9: the last brief of the family wins"
xmade home/data/zz/brief.md zz proj --scout --qa-required-profile only/scout/x
[ -f "$XNH/home/data/zz/qa/manifest.json" ] || fail "9 (W11): a scout writes a manifest"
xmade home/data/nq/brief.md nq noclone --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r
assert_contains "$(cat "$XNH/home/data/nq/qa/manifest.json")" '"source_ref": ""' "9: no clone, no source"
x9oh() {
  xrepo home/projects/oh; git -C "$H/home/projects/oh" checkout -q -b trunk; xput home/projects/oh/t.txt 't
'; git -C "$H/home/projects/oh" add t.txt; git -C "$H/home/projects/oh" commit -qm trunk
  git init -q --bare -b main "$H/oh.git"; git -C "$H/home/projects/oh" remote add origin "$H/oh.git"
  git -C "$H/home/projects/oh" push -q origin main trunk 2>/dev/null; git -C "$H/home/projects/oh" fetch -q origin
  git -C "$H/home/projects/oh" remote set-head origin trunk; git -C "$H/home/projects/oh" checkout -q main
  git init -q -b master "$H/home/projects/ma"; git -C "$H/home/projects/ma" commit -q --allow-empty -m m
  git init -q -b dev "$H/home/projects/de"; git -C "$H/home/projects/de" commit -q --allow-empty -m d; git -C "$H/home/projects/de" checkout -q --detach
  git init -q -b main "$H/home/projects/un"
}
xboth x9oh
for xp in oh ma de un; do
  xmade "home/data/m$xp/brief.md" "m$xp" "$xp" --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r
done
assert_contains "$(cat "$XNH/home/data/moh/qa/manifest.json")" "\"source_ref\": \"$(git -C "$XNH/home/projects/oh" rev-parse trunk)\"" "9: origin/HEAD's branch"
assert_contains "$(cat "$XNH/home/data/mde/qa/manifest.json")" '"source_ref": "main"' "9: a ref git cannot resolve is the name it printed"
xboth xput home/data/w6/qa/manifest.json $'{"old": true}\n'
XPATH="$(xwithout jq)"
xpair w6 proj --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r
XPATH=""
xsame_rc_out w6
assert_eq "$XN_RC:$(xerr)" "127:" "9 (W6, named): jq off PATH ends the run 127, the shell's line not reproduced"
assert_contains "$(xoerr)" ": jq: command not found" "9: the original's line"
assert_eq "$(cat "$XNH/home/data/w6/qa/manifest.json")" '{"old": true}' "9 (W6, named): the family's manifest is left whole"
[ ! -s "$XOH/home/data/w6/qa/manifest.json" ] || fail "9: the original emptied it"
[ -f "$XNH/home/data/w6/brief.md" ] && [ -f "$XOH/home/data/w6/brief.md" ] || fail "9 (W6): the brief was written first, on both sides"
[ -z "$(ls "$XNH/home/data/w6/qa" | grep -v '^manifest.json$')" ] || fail "9 (W6): the port leaves no temp behind"
xboth rm -rf @H/home/data/w6
if [ "$XROOTED" = 0 ]; then
  xboth mkdir -p @H/home/data/w6b/qa
  xboth chmod 555 @H/home/data/w6b/qa
  xpair w6b proj --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r
  xboth chmod 755 @H/home/data/w6b/qa
  xsame_rc_out w6b; xsame_world w6b
  assert_eq "$XN_RC:$(xerr)" "1:" "9 (W6, named): an unwritable qa dir ends the run 1, the shell's line not reproduced"
  assert_contains "$(xoerr)" "manifest.json: Permission denied" "9: the original's line"
fi
cat >"$TMP/xgate.sh" <<'GATE'
#!/usr/bin/env bash
_id="$(/bin/ps -o lstart= -p $$)"
_wd="$( ( sleep 60; [ "$(/bin/ps -o lstart= -p $$)" != "$_id" ] || kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 & printf '%s' $! )"
read -r _ <"$1"
kill "$_wd" 2>/dev/null || true
cd "$2" || exit 1
b="$3"; shift 3
exec "$b/ac-brief.sh" "$@"
GATE
chmod +x "$TMP/xgate.sh"
xplant() {  # xplant <bin> <side root> - one gated scaffold, a symlink to <side>/victim planted at the manifest temp name its pid makes
  local b="$1" h="$2" gate pid; gate="$h/gate.fifo"; mkfifo "$gate"; printf 'victim bytes' >"$h/victim"; mkdir -p "$h/home/data/pl/qa"
  env -u AC_FLEET_STATE -u AC_SCOPE -u AC_BACKEND -u CDPATH LC_ALL=C AC_HOME="$h/home" TMPDIR="$h/tmp" \
    "$TMP/xgate.sh" "$gate" "$h/cwd" "$b" pl proj --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r </dev/null >"$h/plant.out" 2>"$h/plant.err" &
  pid=$!
  ln -s "$h/victim" "$h/home/data/pl/qa/manifest.json.tmp.$pid"
  printf x >"$gate"
  wait "$pid" || fail "9: the planted row under $b failed: $(cat "$h/plant.err")"
  rm -f "$gate"
}
xplant "$xobin" "$XOH"; xplant "$BIN" "$XNH"
assert_eq "$(xnorm "$XNH/plant.out" "$XNH"):$(cat "$XNH/plant.err")" "$(xnorm "$XOH/plant.out" "$XOH"):" "9: the planted row's output"
assert_eq "$(cat "$XNH/victim")" "victim bytes" "9 (EXCLUSIVE TEMPS, named): the port never writes through a planted temp"
assert_eq "$(xnorm "$XNH/home/data/pl/qa/manifest.json" "$XNH")" "$(xnorm "$XOH/home/data/pl/qa/manifest.json" "$XOH")" "9: ...and its manifest is the original's"
xboth rm -rf @H/home/data/pl @H/victim @H/plant.out @H/plant.err
xboth xput home/data/mm/qa/manifest.json $'{"old": true}\n'
xboth chmod 600 @H/home/data/mm/qa/manifest.json
xmade home/data/mm/brief.md mm proj --mode local-only --qa-required-profile a/b/c --captain-requested c --reason r
assert_eq "$(ls -l "$XNH/home/data/mm/qa/manifest.json" | cut -c1-10)" "-rw-------" "9: a replaced manifest keeps its mode, as the original's truncation did"
XLC=en_US.UTF-8
xpair w12 proj --mode local-only --qa-required-profile $'\xc3\x84/x/y' --captain-requested c --reason r
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: invalid --qa-required-profile '"$'\xc3\x84'"/x/y' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-]) (nothing scaffolded)" "9 (W12, named): a profile outside the charset is refused under any locale"
assert_eq "$XO_RC" 0 "9: the original took it under UTF-8..."
assert_contains "$(cat "$XOH/home/data/w12/qa/manifest.json")" "\"profile_key\": \""$'\xc3\x84'"/x/y\"" "9: ...and wrote it"
XLC=C

# 10. locale and fail paths: records/captain.md with a latin1 byte under a
#     UTF-8 locale (W4, named: the original's awk aborted and dropped every
#     rule past the byte; the port reads bytes and selects them all), an
#     unusable TMPDIR beside an orphan STANDING line (W5, named: the port
#     needs no temp), a task dir the brief cannot be created in (the shell's
#     own line not reproduced, exit 1 both), and a data/ mkdir cannot write
#     in (mkdir's own line, spawned on both sides).
xboth xstd
xboth xput home/records/captain.md $'- STANDING rule before\n- caf\xe9 STANDING rule with the byte\n- STANDING rule after\n'
XLC=en_US.UTF-8
xpair w4 proj --mode local-only
XLC=C
xsame_rc_out w4
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W4, named): the port selects past the byte, silently"
for xr in "- STANDING rule before" $'- caf\xe9 STANDING rule with the byte' "- STANDING rule after"; do
  assert_contains "$(xbrief home/data/w4/brief.md)" "$xr"$'\n' "10 (W4, named): the port selects '$xr'"
done
assert_contains "$(xoerr)" "awk: towc: multibyte conversion failure" "10: the original's awk aborted"
case "$(cat "$XOH/home/data/w4/brief.md")" in *"rule after"*) fail "10: the original lost the rule past the byte" ;; esac
xboth xput home/records/captain.md $'- STANDING one\nan orphan STANDING line\n- STANDING two\n'
XENV=("TMPDIR=@H/nope")
xpair w5 proj --mode local-only
XENV=()
xsame_rc_out w5
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W5, named): no temp, no failure"
assert_contains "$(xbrief home/data/w5/brief.md)" "- STANDING two"$'\n\n'"UNPARSED" "10 (W5, named): every rule and the orphan, the original's file read whole"
assert_contains "$(xoerr)" "mktemp" "10: the original's mktemp line"
xboth xstd
if [ "$XROOTED" = 0 ]; then
  xboth mkdir -p @H/home/data/t9
  xboth chmod 555 @H/home/data/t9
  for xs in "t9 proj --mode local-only" "t9 proj --scout"; do
    # shellcheck disable=SC2086
    xpair $xs
    xsame_rc_out $xs; xsame_world $xs
    assert_eq "$XN_RC:$(xerr)" "1:" "10 (SHELL-OWN STDERR, named): a brief that cannot be created ends the run 1"
    assert_contains "$(xoerr)" "ROOT/bin/ac-brief.sh: line " "10: the original's line is the shell's"
  done
  xboth chmod 755 @H/home/data/t9
  xboth chmod 555 @H/home/data
  xsame t10 proj --mode local-only
  xboth chmod 755 @H/home/data
  assert_eq "$XN_RC:$(xerr)" "1:mkdir: @H/home/data/t10: Permission denied" "10: mkdir's own line, both sides"
  xboth xseed
  xboth chmod 555 @H/home
  xpair tm proj --mode local-only
  xboth chmod 755 @H/home
  xsame_rc_out tm; xsame_world tm
  assert_eq "$XN_RC:$(xerr)" "1:mkdir: @H/home/data: Permission denied" "10 (MINTING, named): the port mints silently, the task dir's mkdir says it"
  [ "$(grep -c 'Permission denied' "$TMP/xo.err2")" -gt 1 ] || fail "10: the original printed mkdir's line at every mint it could not make: $(xoerr)"
  xboth xstd
fi
xboth xput home/data/tf 'a file where the task dir goes
'
xsame tf proj --mode local-only
assert_eq "$XN_RC:$(xerr)" "1:mkdir: @H/home/data/tf: File exists" "10: a task dir that is a file is mkdir's own refusal"
xpair tb $'p\xe9' --mode local-only
xsame_rc_out tb; xsame_err tb
assert_contains "$(xbrief home/data/tb/brief.md)" "Project: p"$'\xef\xbf\xbd'$'\n' "10 (BYTES, named): argv arrives decoded"
assert_contains "$(xnorm "$XOH/home/data/tb/brief.md" "$XOH")" "Project: p"$'\xe9'$'\n' "10: the original printed the byte"

# 11. the ledger read count (W17, named): the original parsed the ledger
#     through a bun child 2-5 times, so a parse failing after earlier ones
#     passed refused at the fence or the gate; the port reads it once,
#     in-process, so the same PATH stub reaches no parse at all.
mkdir -p "$TMP/xfailbun"
cat >"$TMP/xfailbun/bun" <<STUB
#!/bin/sh
if [ "\$4" = fields ] && [ "\$5" != --get ]; then
  n=\$(( \$(cat "\$STUB_DIR/parses" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"\$STUB_DIR/parses"
  [ "\$n" != "\$STUB_FAIL_AT" ] || exit 1
fi
exec "$(command -v bun)" "\$@"
STUB
chmod +x "$TMP/xfailbun/bun"
XPRE="$TMP/xfailbun"
for xat in 2 3; do
  xboth xstd
  XENV=("STUB_FAIL_AT=$xat")
  xpair "w17-$xat" proj --mode local-only
  assert_eq "$XN_RC:$(xerr)" "0:" "11 (W17, named): one in-process read, no parse to fail ($xat)"
  assert_eq "$XO_RC" 1 "11: the original's parse $xat failed"
done
assert_contains "$(xoerr)" "ERROR: cannot read the ledger @H/home/records/backlog.md for the delivery contract of w17-3" "11: the gate's own read refused"
XPRE=""; XENV=()

pass
