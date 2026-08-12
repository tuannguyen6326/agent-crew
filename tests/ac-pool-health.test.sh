#!/usr/bin/env bash
# ac-pool-health.test.sh - the session-start pool-health digest block: it
# must render the exact reclaim command for every available-dirty slot, name
# a leased slot as active (never stuck), and stay completely silent when the
# pool is healthy.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo)"

# Build a real pool: two leases, one returned clean, one dirtied after return
# so it becomes available-dirty (stuck); the other stays leased (active).
wt1="$("$BIN/ac-tree.sh" get --repo "$repo" --id t1 2>/dev/null)"
wt2="$("$BIN/ac-tree.sh" get --repo "$repo" --id t2 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wt1" 2>/dev/null
printf 'unlanded\n' >>"$wt1/file.txt"

# RENDERS: with >=1 available-dirty slot, the header, repo name, stuck-dirty
# count, verbatim reclaim command and the dirty slot's path all appear; the
# still-leased slot is never flagged.
out="$("$BIN/ac-pool-health.sh" --repo "$repo")"
assert_contains "$out" "-- pool (worktree health) --" "header prints when unhealthy"
assert_contains "$out" "$(basename "$repo")" "repo name printed"
assert_contains "$out" "1 stuck-dirty" "stuck-dirty count printed"
assert_contains "$out" "bin/ac-tree.sh remove --force <worktree-path>" "verbatim reclaim command"
assert_contains "$out" "$wt1" "dirty slot's worktree path printed"
case "$out" in
  *"$wt2"*) fail "leased slot must never be flagged as stuck" ;;
  *"reclaim each broken slot"*) fail "a dirty-only pool must not print the broken reclaim hint (0 broken)" ;;
esac

# QUIET: clear the dirt (return --force resets it to available); no
# available-dirty slots remain, so the block prints nothing at all.
"$BIN/ac-tree.sh" return "$wt1" --force 2>/dev/null
out2="$("$BIN/ac-pool-health.sh" --repo "$repo")"
assert_eq "$out2" "" "quiet when every slot is available or leased"

# BROKEN, own bucket: a slot released to the pool (leased=0) whose gitdir
# pointer is then broken must be named as its own bucket - never silently
# counted as leasable (wrong bucket) and never folded into stuck-dirty
# (different chief action). A broken-ONLY pool must still render.
repoB="$(make_repo broken)"
wtB="$("$BIN/ac-tree.sh" get --repo "$repoB" --id b1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtB" 2>/dev/null
rm -rf "$repoB/.git/worktrees/1"
git -C "$wtB" rev-parse --git-dir >/dev/null 2>&1 && fail "fixture: the worktree must be broken"

outB="$("$BIN/ac-pool-health.sh" --repo "$repoB")"
assert_contains "$outB" "-- pool (worktree health) --" "header prints for a broken-only pool"
assert_contains "$outB" "0 leasable" "broken slot must never be counted as leasable"
assert_contains "$outB" "0 stuck-dirty" "a broken slot is not a dirty slot"
assert_contains "$outB" "1 broken" "broken count printed"
assert_contains "$outB" "$wtB" "broken slot's worktree path printed"
assert_contains "$outB" "bin/ac-tree.sh remove --force <worktree-path>" "broken-slot reclaim command printed"
case "$outB" in
  *"reclaim each dirty slot"*) fail "a broken-only pool must not print the dirty reclaim hint (0 stuck-dirty)" ;;
esac

# ARITHMETIC, mixed pool: 1 dirty + 1 broken + 1 leased. leasable + stuck +
# broken must account for every NON-LEASED slot (2 here) with no slot
# silently missing - "leasable + stuck < total" alone is not diagnostic
# since a leased slot matches neither bucket either.
repoM="$(make_repo mixed)"
wtM1="$("$BIN/ac-tree.sh" get --repo "$repoM" --id m1 2>/dev/null)"
wtM2="$("$BIN/ac-tree.sh" get --repo "$repoM" --id m2 2>/dev/null)"
"$BIN/ac-tree.sh" get --repo "$repoM" --id m3 >/dev/null 2>&1
"$BIN/ac-tree.sh" return "$wtM1" 2>/dev/null
printf 'unlanded\n' >>"$wtM1/file.txt"
"$BIN/ac-tree.sh" return "$wtM2" 2>/dev/null
rm -rf "$repoM/.git/worktrees/2"

outM="$("$BIN/ac-pool-health.sh" --repo "$repoM")"
assert_contains "$outM" "0 leasable" "mixed pool: no genuinely clean available slot"
assert_contains "$outM" "1 stuck-dirty" "mixed pool: exactly one dirty slot"
assert_contains "$outM" "1 broken" "mixed pool: exactly one broken slot"
assert_contains "$outM" "3 total" "mixed pool: all three slots counted"

pass
