#!/usr/bin/env bash
# ac-spawn-review-annotation.test.sh - ac-spawn.sh's `Review:` line parser
# accepts every annotated review_line ac-brief.sh actually writes
# (bin/ac-brief.sh:235/237/271/277 - "yes (...)"/"no (...)" shapes), not only
# the bare yes/no fallback at :282. Regression for the bug fixed alongside
# this test: `sed -n 's/^Review: //p' | head -n 1` captured the WHOLE
# annotated string, so every annotated brief fell through
# `case "$review" in yes|no)` into `ac_die "... must carry exactly one
# Review: yes|no obligation"`.
#
# Spawns real briefs through the same fake-herdr harness as
# tests/ac-spawn-branch-collision.test.sh, covering all four annotated
# branches, the surviving bare fallback, and the still-fail-closed invalid
# value (the fix loosens the annotation, not the validation).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
# The epic branches below (:235/:237) need a real project clone at
# projects/<name> - ac-epic-branch.sh's create verb only ever looks there
# (bin/ac-epic-branch.sh:repo_dir). Placed under $AC_HOME so every case in
# this file, epic and non-epic alike, shares the one clone and passes "proj"
# as the project argument the ordinary way.
repo="$(make_repo home/projects/proj)"

# Deliver the kickoff prompt immediately (default 8s) so the suite stays fast.
export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation immediately - this
# suite is not testing that gate (tests/ac-spawn-kickoff-ready.test.sh owns
# it), it just needs its spawns to complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5

# A claude stub so the spawns below pass ac-spawn's command -v check; the fake
# herdr never executes the launch line.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

meta_review() { awk -F= '$1=="review"{print $2}' "$AC_HOME/state/$1.meta"; }

mkdir -p "$AC_HOME/records"

# --- :271 - review_flag=yes + a rev:yes row pin --------------------------------
# review_line="yes (pinned on the backlog row)"
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] revpin [src:cap flow:direct mode:local-only rev:yes qa:no] - regression fixture (repo: proj)
EOF
"$BIN/ac-brief.sh" revpin proj --mode local-only --review yes >/dev/null
assert_contains "$(cat "$AC_HOME/data/revpin/brief.md")" "Review: yes (pinned on the backlog row)" \
  "fixture brief carries the :271 annotated form"
"$BIN/ac-spawn.sh" revpin proj --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/revpin.meta" "annotated :271 Review line spawns"
assert_eq "$(meta_review revpin)" yes "the annotation is stripped before the value lands in meta"
"$BIN/ac-teardown.sh" revpin --force >/dev/null 2>&1

# --- :277 - review_flag=yes + --captain-requested ------------------------------
# review_line="yes (captain-requested: $captain_requested)"
"$BIN/ac-brief.sh" capreq proj --mode local-only --review yes \
  --captain-requested "captain TN: fixture review raise" \
  --reason "fixture: exercising the captain-requested review raise" >/dev/null
assert_contains "$(cat "$AC_HOME/data/capreq/brief.md")" \
  "Review: yes (captain-requested: captain TN: fixture review raise)" \
  "fixture brief carries the :277 annotated form"
"$BIN/ac-spawn.sh" capreq proj --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/capreq.meta" "annotated :277 Review line spawns"
assert_eq "$(meta_review capreq)" yes "the annotation is stripped before the value lands in meta"
"$BIN/ac-teardown.sh" capreq --force >/dev/null 2>&1

# --- :235/:237 - a staged epic story's derived review (captain ruling 2026-08-19) ---
mkdir -p "$AC_HOME/data/epicfix"
printf 'proj epic/epicfix\n' >"$AC_HOME/data/epicfix/branches"
"$BIN/ac-epic-branch.sh" create epicfix proj >/dev/null
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] epicfix-s1 [src:cap flow:staged mode:local-only qa:no] - staged epic story, default review; epic:epicfix (repo: proj)
- [ ] epicfix-s2 [src:cap flow:staged mode:local-only qa:no] - staged epic story, raised review; epic:epicfix (repo: proj)
EOF

# :237 - review_line="no (epic gate owns the review round - captain ruling 2026-08-19)"
"$BIN/ac-brief.sh" epicfix-s1 proj --stage implement >/dev/null
assert_contains "$(cat "$AC_HOME/data/epicfix-s1/implement/brief.md")" \
  "Review: no (epic gate owns the review round - captain ruling 2026-08-19)" \
  "fixture brief carries the :237 annotated form"
"$BIN/ac-spawn.sh" epicfix-s1 proj --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/epicfix-s1.meta" "annotated :237 Review line spawns"
assert_eq "$(meta_review epicfix-s1)" no "the annotation is stripped before the value lands in meta"
"$BIN/ac-teardown.sh" epicfix-s1 --force >/dev/null 2>&1

# :235 - review_line="yes (captain word required - see the raise guard below)"
"$BIN/ac-brief.sh" epicfix-s2 proj --stage implement --review yes >/dev/null
assert_contains "$(cat "$AC_HOME/data/epicfix-s2/implement/brief.md")" \
  "Review: yes (captain word required - see the raise guard below)" \
  "fixture brief carries the :235 annotated form"
"$BIN/ac-spawn.sh" epicfix-s2 proj --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/epicfix-s2.meta" "annotated :235 Review line spawns"
assert_eq "$(meta_review epicfix-s2)" yes "the annotation is stripped before the value lands in meta"
"$BIN/ac-teardown.sh" epicfix-s2 --force >/dev/null 2>&1

# --- surviving fallback (:282) - a bare Review: value still spawns as before ---
"$BIN/ac-brief.sh" barefall proj --mode local-only >/dev/null
assert_contains "$(cat "$AC_HOME/data/barefall/brief.md")" "Review: no" \
  "the fallback template still writes a bare value"
"$BIN/ac-spawn.sh" barefall proj --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/barefall.meta" "bare Review: no still spawns as before"
assert_eq "$(meta_review barefall)" no "bare value still lands unchanged"
"$BIN/ac-teardown.sh" barefall --force >/dev/null 2>&1

# --- fail-closed is unchanged: an invalid Review: value still refuses ----------
# The fix loosens the ANNOTATION, never the VALIDATION - a value that is
# neither yes nor no (whitespace and all) must still die exactly as before.
mkdir -p "$AC_HOME/data/badreview"
cat >"$AC_HOME/data/badreview/brief.md" <<'EOF'
# Crew brief: badreview

Project: proj
Kind: execution (IMPLEMENT + DELIVERY)
Mode: local-only
Review: maybe
Captain: TN
EOF
err="$("$BIN/ac-spawn.sh" badreview proj --harness claude 2>&1 1>/dev/null || true)"
assert_contains "$err" "must carry exactly one Review: yes|no obligation" \
  "an invalid Review: value still fail-closes"
assert_no_file "$AC_HOME/state/badreview.meta" "the refused spawn writes no meta"

pass
