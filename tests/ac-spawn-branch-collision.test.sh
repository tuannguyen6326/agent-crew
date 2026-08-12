#!/usr/bin/env bash
# ac-spawn-branch-collision.test.sh - spawn validates the crew BRANCH, not just
# the meta:
#   - no crew/<family> ref => the spawn proceeds exactly as before,
#   - a crew/<family> ref that NOTHING in flight owns => the spawn is REFUSED,
#     naming the ref and BOTH the rename and the delete command, before any
#     window/lease/meta exists - and the ref itself is never touched,
#   - a crew/<family> ref a LIVE family sibling owns => the spawn proceeds:
#     ac_crew_branch collapses every stage/revision id in a family onto ONE
#     branch, so the fresh-crewmate-on-the-crew-branch recovery of AGENTS.md
#     section 5 legitimately continues it.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
repo="$(make_repo proj)"

# Deliver the kickoff prompt immediately (default 8s) so the suite stays fast.
export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs its spawns to
# complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5

# A claude stub so the spawns below pass ac-spawn's command -v check; the fake
# herdr never executes the launch line.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

# --- control: no crew/<id> ref => the spawn proceeds ---------------------------
"$BIN/ac-brief.sh" c0 proj >/dev/null
"$BIN/ac-spawn.sh" c0 "$repo" --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/c0.meta" "an id with no crew branch spawns as before"
"$BIN/ac-teardown.sh" c0 --force >/dev/null 2>&1

# --- an UNOWNED crew/<id> ref refuses the spawn --------------------------------
# The live shape (2026-07-27): crew/learning outlived its task because teardown
# deletes a crew branch only when it is MERGED, so the next spawn of that id
# would have committed onto a foreign history.
git -C "$repo" branch crew/c1 main
sha="$(git -C "$repo" rev-parse --verify crew/c1)"
"$BIN/ac-brief.sh" c1 proj >/dev/null
err="$("$BIN/ac-spawn.sh" c1 "$repo" --harness claude 2>&1 1>/dev/null || true)"
assert_contains "$err" "crew/c1" "the refusal names the colliding ref"
assert_contains "$err" "branch -m crew/c1" "the refusal states the rename command"
assert_contains "$err" "branch -D crew/c1" "the refusal states the delete command"
assert_no_file "$AC_HOME/state/c1.meta" "the refused spawn writes no meta"
assert_eq "$(git -C "$repo" rev-parse --verify crew/c1)" "$sha" \
  "spawn never renames or deletes the ref - that is the operator's call"
# It refuses BEFORE the lease, so no pool slot leaks on the refusal.
case "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null || true)" in
  *"crew:c1"*) fail "the refused spawn must not leak a worktree lease" ;;
esac

# --- a LIVE family sibling owns the branch => no refusal -----------------------
# c2 is in flight and commits on crew/c2; c2-r2 is the fresh execution crewmate
# that continues that same branch (AGENTS.md section 5 recovery). Refusing it
# would tell the operator to delete a branch holding live unlanded work.
"$BIN/ac-brief.sh" c2 proj >/dev/null
"$BIN/ac-spawn.sh" c2 "$repo" --harness claude >/dev/null 2>&1
git -C "$repo" branch crew/c2 main
"$BIN/ac-brief.sh" c2-r2 proj --stage implement >/dev/null
"$BIN/ac-spawn.sh" c2-r2 "$repo" --harness claude >/dev/null 2>&1
assert_file "$AC_HOME/state/c2-r2.meta" \
  "a branch a live family sibling owns is continued, not refused"
"$BIN/ac-teardown.sh" c2-r2 --force >/dev/null 2>&1
"$BIN/ac-teardown.sh" c2 --force >/dev/null 2>&1

pass
