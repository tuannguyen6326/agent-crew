#!/usr/bin/env bash
# ac-promote.test.sh - scout-to-ship promotion and the scout teardown
# backstop. Covers: teardown refuses a scout holding unlanded commits on
# crew/<id> even when report.md exists (and points at ac-promote.sh);
# a landed crew branch does not trip the backstop; ac-promote.sh flips
# kind/mode in the meta (registry default and --mode override) so ship
# teardown rules apply; --force still discards; promote refuses non-scout,
# unknown tasks, and bad --mode values; a live window gets the notice.
# Pure git + meta except the final notice case, which drives the fake
# herdr backend (tests/helpers.sh).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# The fake herdr CLI keeps every backend call hermetic (panes are files
# under $FAKE_HERDR): backend_kill_window and the notice send below can
# never reach the operator's live server.
make_fake_herdr

make_home

mk_meta() {
  # mk_meta <id> <repo> <kind> - the minimal crewmate meta teardown/promote read.
  local m="$AC_HOME/state/$1.meta"
  {
    printf 'project=%s\n' "$(basename "$2")"
    printf 'project_dir=%s\n' "$2"
    printf 'worktree=%s\n' "$2/.crew/worktrees/1"
    printf 'kind=%s\n' "$3"
    printf 'mode=-\n'
  } >"$m"
}

add_crew() {
  # add_crew <repo> <id> - crew/<id> one commit ahead of main, back on main.
  git -C "$1" checkout -q -b "crew/$2"
  printf 'crew change\n' >"$1/crewfile.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm "scout wrote code"
  git -C "$1" checkout -q main
}

meta_get() { awk -F= -v k="$2" '$1==k{v=substr($0,length(k)+2)} END{print v}' "$AC_HOME/state/$1.meta"; }

# ---- Case 1: scout with report but UNLANDED crew branch -> teardown refuses -
repo="$(make_repo p1)"
printf -- '- p1 [local-only] - promote test repo (added 2026-07-16)\n' >"$AC_HOME/records/projects.md"
mkdir -p "$AC_HOME/data/s1"
printf 'findings\n' >"$AC_HOME/data/s1/report.md"
mk_meta s1 "$repo" scout
# A GONE window, faithfully: the pane handle a spawn records survives, but
# the herdr pane behind it no longer exists (no fake pane files) - so
# liveness probes fail while teardown's kill path can still resolve the tab.
printf 'p10 t10\n' >"$AC_HOME/state/.pane-s1"
add_crew "$repo" s1
out="$("$BIN/ac-teardown.sh" s1 2>&1)" && fail "teardown must refuse a scout with an unlanded crew branch"
assert_contains "$out" "unlanded work" "refusal names the unlanded work"
assert_contains "$out" "ac-promote.sh s1" "refusal points at ac-promote.sh"
assert_file "$AC_HOME/state/s1.meta" "meta survives the refusal"

# ---- Case 2: promote in place -> kind=ship, mode EXPLICIT (per-task) --------
# Mode is per-task: a bare promote refuses - the
# registry default is gone, and a promotion is exactly the moment the task
# acquires a mode.
out="$("$BIN/ac-promote.sh" s1 2>&1)" && fail "a bare promote must refuse: mode is per-task now"
assert_contains "$out" "mode unspecified" "the refusal names the missing mode"
assert_eq "$(meta_get s1 kind)" "scout" "a refused promote flips nothing"
out="$("$BIN/ac-promote.sh" s1 --mode local-only)"
assert_contains "$out" "kind scout -> ship" "promote prints the kind flip"
assert_contains "$out" "mode=local-only" "the explicit mode is recorded"
assert_contains "$out" "window not reachable" "gone window reported, not fatal"
assert_eq "$(meta_get s1 kind)" "ship" "meta kind flipped to ship"
assert_eq "$(meta_get s1 mode)" "local-only" "meta mode recorded"
assert_contains "$(cat "$AC_HOME/state/s1.status")" "promoted: scout -> ship" "status logged"

# ---- Case 3: promoted task now falls under SHIP teardown rules --------------
out="$("$BIN/ac-teardown.sh" s1 2>&1)" && fail "ship rules must still refuse the unlanded branch"
assert_contains "$out" "not landed" "ship-rule refusal message"

# ---- Case 4: --force still discards (captain's explicit call) ---------------
"$BIN/ac-teardown.sh" s1 --force >/dev/null
assert_no_file "$AC_HOME/state/s1.meta" "meta archived on --force"
assert_file "$AC_HOME/state/archive/s1/meta"
assert_eq "$(awk -F= '$1=="kind"{v=$2} END{print v}' "$AC_HOME/state/archive/s1/meta")" "ship" "archived meta keeps the promotion"

# ---- Case 5: LANDED crew branch does not trip the scout backstop ------------
repo5="$(make_repo p5)"
mkdir -p "$AC_HOME/data/s5"
printf 'findings\n' >"$AC_HOME/data/s5/report.md"
mk_meta s5 "$repo5" scout
printf 'p50 t50\n' >"$AC_HOME/state/.pane-s5"
add_crew "$repo5" s5
git -C "$repo5" merge -q --ff-only crew/s5
"$BIN/ac-teardown.sh" s5 >/dev/null
assert_file "$AC_HOME/state/archive/s5/meta" "landed scout branch tears down normally"

# ---- Case 6: promote refuses non-scout, unknown tasks, bad --mode -----------
repo6="$(make_repo p6)"
mk_meta n1 "$repo6" ship
out="$("$BIN/ac-promote.sh" n1 2>&1)" && fail "promote must refuse a non-scout task"
assert_contains "$out" "not scout" "non-scout refusal names the kind rule"
assert_eq "$(meta_get n1 kind)" "ship" "non-scout meta untouched"
assert_fails "$BIN/ac-promote.sh" nope
mk_meta s6 "$repo6" scout
assert_fails "$BIN/ac-promote.sh" s6 --mode bogus
assert_eq "$(meta_get s6 kind)" "scout" "bad --mode leaves the meta untouched"

# ---- Case 7: cheap modes promote on the chief's own authority ---------------
"$BIN/ac-promote.sh" s6 --mode direct-pr >/dev/null
assert_eq "$(meta_get s6 kind)" "ship" "--mode promote flips kind"
assert_eq "$(meta_get s6 mode)" "direct-pr" "the explicit mode is the record"
rm -f "$AC_HOME/state/s6.meta" "$AC_HOME/state/s6.status"

# ---- Case 7b: crew-ship is a time-expensive choice - captain's word only ----
repo7="$(make_repo p7)"
mk_meta s7 "$repo7" scout
out="$("$BIN/ac-promote.sh" s7 --mode crew-ship 2>&1)" \
  && fail "promoting into crew-ship without the captain's word must refuse"
assert_contains "$out" "time-expensive" "the refusal names the escalation rule"
assert_contains "$out" "REASON" "the refusal demands the reason ride the ask"
assert_contains "$out" "--captain-requested" "the refusal names the remedy"
assert_eq "$(meta_get s7 kind)" "scout" "a refused promotion flips nothing"
out="$("$BIN/ac-promote.sh" s7 --mode direct-pr --captain-requested 'order ref' 2>&1)" \
  && fail "declaring authority the cheap path never needed must refuse"
assert_contains "$out" "nothing to authorize" "an idle declaration is refused"
out="$("$BIN/ac-promote.sh" s7 --mode crew-ship --captain-requested 'captain: run the pipeline on s7' 2>&1)" \
  && fail "the captain's word without the chief's --reason must refuse: the reason rides the record"
assert_contains "$out" "--reason" "the refusal names the missing reason"
"$BIN/ac-promote.sh" s7 --mode crew-ship --captain-requested 'captain: run the pipeline on s7' --reason 'financial surface: the change touches the ledger math' >/dev/null
assert_eq "$(meta_get s7 mode)" "crew-ship" "the declared promotion records the mode"
assert_contains "$(cat "$AC_HOME/state/s7.status")" "captain-requested: captain: run the pipeline on s7" \
  "the captain's word rides the status record"
assert_contains "$(cat "$AC_HOME/state/s7.status")" "reason: financial surface" \
  "the chief's reason rides the status record too"
rm -f "$AC_HOME/state/s7.meta" "$AC_HOME/state/s7.status"

# ---- Case 8: a live window gets the ship-contract notice ---------------------
# Simulate s8's live pane: the recorded pane handle + live fake pane files
# (what a real spawn would have left behind).
repo8="$(make_repo p8)"
mk_meta s8 "$repo8" scout
printf 'p80 t80\n' >"$AC_HOME/state/.pane-s8"
printf 'p80\n' >"$FAKE_HERDR/tabs/t80"
: >"$FAKE_HERDR/panes/p80.buf"
out="$("$BIN/ac-promote.sh" s8 --mode local-only)"
assert_contains "$out" "notified crewmate s8" "live window gets the notice"
assert_contains "$(cat "$(fake_pane_buf s8)")" "crew/s8" "notice names the crew branch"

pass
