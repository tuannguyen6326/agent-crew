#!/usr/bin/env bash
# ac-brief.test.sh - brief scaffolding: ship and scout templates, overwrite
# refusal, id validation.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# staged is a TIME-EXPENSIVE flow now, and mode is per-task: the widget family
# rows below are PINNED on the ledger - the durable pre-consent path - so
# these scaffolds run without a per-call declaration, which is exactly the
# "đã define trong backlog thì không cần hỏi" half of the captain's rule.
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
  --captain-requested "captain TN 2026-07-30: review this one" >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "Review: yes" "direct local-only can opt into review when the captain asks"
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "captain TN 2026-07-30: review this one" "the brief records WHO asked for the review"
assert_contains "$(cat "$AC_HOME/data/task-3-reviewed/brief.md")" "ac-verify.sh codereview" "optional direct review uses the verifier facade"
# An empty ref is no ref: the declaration must NAME the captain's words.
assert_fails "$BIN/ac-brief.sh" task-3-empty myproj --mode local-only --review yes --captain-requested ""
# A declaration with nothing to authorize is a caller mistake, not a silent no-op.
assert_fails "$BIN/ac-brief.sh" task-3-noraise myproj --mode local-only --captain-requested "ref"
# Where review was never optional, the guard changes nothing: crew-ship derives
# review=yes with no declaration to make.
# crew-ship is a TIME-EXPENSIVE mode now (the escalation gate): the call must
# carry the captain's word or a row pin - this one declares.
"$BIN/ac-brief.sh" task-3-ship myproj --mode crew-ship --review yes --captain-requested "captain: ship it through the pipeline" >/dev/null
assert_contains "$(cat "$AC_HOME/data/task-3-ship/brief.md")" "Review: yes" "crew-ship review=yes needs no captain declaration"
assert_fails "$BIN/ac-brief.sh" task-crew-no myproj --mode crew-ship --review no
assert_fails "$BIN/ac-brief.sh" task-4 myproj --mode bogus

"$BIN/ac-brief.sh" scout-1 myproj --scout >/dev/null
scout="$AC_HOME/data/scout-1/brief.md"
assert_contains "$(cat "$scout")" "report.md" "scout brief demands a report"
assert_contains "$(cat "$scout")" "NEVER open a PR" "scout brief forbids PRs"

# Completion discipline: every brief teaches BOTH channels - the printed marker
# line (the watcher's backup) and the push that wakes the chief now. The push
# command is baked with an ABSOLUTE path, since the crewmate works in the
# PROJECT's worktree and may have no bin/ac-done.sh of its own.
root="$(cd "$BIN/.." && pwd -P)"
assert_contains "$(cat "$scout")" "$root/bin/ac-done.sh scout-1" \
  "the brief names the push command with an absolute path and the task id"
assert_contains "$(cat "$AC_HOME/data/task-1/brief.md")" "$root/bin/ac-done.sh task-1" \
  "the ship brief teaches the push too"

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
# same branch tests/ac-merge-local.test.sh proves ac-merge-local.sh lands to -
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
grep -q 'scope-install' "$BIN/ac-brief.sh" && fail "no brief template may name scope-install"

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
# widen the `- ` block selector to swallow it (bin/ac-domain.sh:150 names the
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
# not distro law (AGENTS.md:826-829) - so step 7 must name that authority
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

pass
