#!/usr/bin/env bash
# ac-self-task.test.sh - the chief-self-but-visible mechanism:
#   - `start` leases a pooled worktree, opens a labelled pane tailing the
#     progress log, and writes a kind=self meta - ALL of it before the chief
#     makes its first edit,
#   - `log` appends to that progress log, so the pane and every fleet view
#     (ac-crew-state.sh) show the chief's progress,
#   - a kind=self meta is excluded from SUPERVISION: it holds no agent, so it
#     neither demands a watcher nor is polled for captain markers - while a
#     real crewmate meta in the same fleet still does both,
#   - `start` refuses an id that already exists.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
repo="$(make_repo proj)"
state="$AC_HOME/state"

# --- start: worktree + pane + meta, all before the first edit ------------------
out="$("$BIN/ac-self-task.sh" start s1 "$repo")"
assert_contains "$out" "self-task s1" "start reports the task it opened"
assert_file "$state/s1.meta" "start writes the task meta"
assert_eq "$(awk -F= '$1=="kind"{print $2}' "$state/s1.meta")" self "the meta records kind=self"
worktree="$(awk -F= '$1=="worktree"{print $2}' "$state/s1.meta")"
[ -n "$worktree" ] && [ -d "$worktree" ] || fail "start leases a pooled worktree and records it"
case "$worktree" in "$repo"/.crew/worktrees/*) ;; *) fail "the lease must come from the repo's own pool: $worktree" ;; esac
assert_eq "$(awk -F= '$1=="leases"{print $2}' "$state/s1.meta")" "$worktree" \
  "the lease is recorded so teardown gives it back"
assert_eq "$(awk -F= '$1=="project_dir"{print $2}' "$state/s1.meta")" "$repo" \
  "the meta records the project dir ac-merge-local.sh lands from"
[ -n "$(awk -F= '$1=="window"{print $2}' "$state/s1.meta")" ] || fail "the meta records the pane"

# The pane tails the progress log - that is the whole of "the pane shows chief
# progress"; no agent runs in it.
pane="$(cat "$(fake_pane_buf s1)")"
assert_contains "$pane" "tail -f" "the pane tails the progress log"
assert_contains "$pane" "$state/s1.status" "the pane tails THIS task's progress log"

# --- log: the chief's progress reaches the pane and every fleet view ----------
"$BIN/ac-self-task.sh" log s1 'working: edited bin/ac-foo.sh'
assert_contains "$(cat "$state/s1.status")" "working: edited bin/ac-foo.sh" \
  "log appends to the progress log the pane tails"
assert_contains "$("$BIN/ac-crew-state.sh" s1)" "edited bin/ac-foo.sh" \
  "the fleet's current-state line shows the chief's progress"

# --- supervision: a pane with no agent demands no watcher --------------------
# ac_meta_is_verify is EXCLUDED FROM ACCOUNTING, NEVER FROM SUPERVISION, because
# a verifier pane holds an agent. A self task is the opposite case: the chief IS
# the agent, so waking it about its own pane is a self-loop.
rm -f "$state/.last-watcher-beat"
printf '{}' | "$BIN/ac-turnend-guard.sh" \
  || fail "a self task alone must not block the turn end on a stale beacon"
case "$("$BIN/ac-guard.sh" 2>&1)" in
  *WATCHER-DOWN*) fail "a self task alone must not raise WATCHER-DOWN" ;;
esac
# ...and the watcher does not poll it for captain markers.
printf 'done: chief finished the edit\n' >>"$(fake_pane_buf s1)"
case "$(bash "$BIN/ac-watch.sh" --once 2>/dev/null || true)" in
  *s1*) fail "the watcher must not wake on a pane no agent lives in" ;;
esac
# DISPUTED: the meta's kind. HELD-CONSTANT: the same pane, the same marker
# already in its tail, the same watcher invocation - so the skip is what the
# first run proved, not an inert fixture.
sed -i.bak 's/^kind=self$/kind=ship/' "$state/s1.meta"; rm -f "$state/s1.meta.bak"
case "$(bash "$BIN/ac-watch.sh" --once 2>/dev/null || true)" in
  *s1*) ;;
  *) fail "the watcher must still wake on an ordinary crewmate pane" ;;
esac
sed -i.bak 's/^kind=ship$/kind=self/' "$state/s1.meta"; rm -f "$state/s1.meta.bak"

# --- ...while a REAL crewmate meta still demands both -------------------------
# The watcher run above refreshed the beacon; the demand is only meaningful
# against a stale one.
rm -f "$state/.last-watcher-beat"
printf 'window=crew:t9\n' >"$state/t9.meta"
rc=0; printf '{}' | "$BIN/ac-turnend-guard.sh" 2>/dev/null || rc=$?
assert_eq "$rc" "2" "a real crewmate still blocks the turn end on a stale beacon"
assert_contains "$("$BIN/ac-guard.sh" 2>&1)" "WATCHER-DOWN" \
  "a real crewmate still raises WATCHER-DOWN"
rm -f "$state/t9.meta"

# --- start refuses an id that already exists ---------------------------------
err="$("$BIN/ac-self-task.sh" start s1 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "already exists" "start refuses a duplicate id"

# --- branch collision refusal: the SAME hazard as ac-spawn.sh, shared --------
# A self task also commits on crew/<id> and lands via ac-merge-local.sh, so it
# carries the identical branch-collision hazard ac-spawn.sh refuses
# (tests/ac-spawn-branch-collision.test.sh covers that side) - proven here via
# ac_family_owned (bin/ac-lib.sh), the ONE predicate both callers share.

# control: no crew/<id> ref => start proceeds exactly as before.
"$BIN/ac-self-task.sh" start s2 "$repo" >/dev/null
assert_file "$state/s2.meta" "an id with no crew branch starts as before"
"$BIN/ac-teardown.sh" s2 >/dev/null 2>&1

# an UNOWNED crew/<id> ref refuses start, names the ref, touches no ref, and
# leaves no lease/meta behind.
git -C "$repo" branch crew/s3 main
sha="$(git -C "$repo" rev-parse --verify crew/s3)"
err="$("$BIN/ac-self-task.sh" start s3 "$repo" 2>&1 1>/dev/null || true)"
assert_contains "$err" "crew/s3" "the refusal names the colliding ref"
assert_contains "$err" "branch -m crew/s3" "the refusal states the rename command"
assert_contains "$err" "branch -D crew/s3" "the refusal states the delete command"
assert_no_file "$state/s3.meta" "the refused start writes no meta"
assert_eq "$(git -C "$repo" rev-parse --verify crew/s3)" "$sha" \
  "start never renames or deletes the ref - that is the operator's call"
case "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null || true)" in
  *"self:s3"*) fail "the refused start must not leak a worktree lease" ;;
esac

# a LIVE family sibling owns the branch => start proceeds (the same <fam>-r2
# recovery property AGENTS.md section 5 sanctions on the spawn side).
"$BIN/ac-self-task.sh" start s4 "$repo" >/dev/null
git -C "$repo" branch crew/s4 main
"$BIN/ac-self-task.sh" start s4-r2 "$repo" >/dev/null
assert_file "$state/s4-r2.meta" \
  "a branch a live family sibling owns is continued, not refused"
"$BIN/ac-teardown.sh" s4-r2 --force >/dev/null 2>&1
"$BIN/ac-teardown.sh" s4 --force >/dev/null 2>&1

# --- teardown is the EXISTING path, unchanged --------------------------------
# kind=self takes the ordinary committing-task landed proof (no self case
# anywhere in ac-teardown.sh), and the leases= key it reads is one this script
# writes by hand - a typo there would strand the pool slot forever.
"$BIN/ac-teardown.sh" s1 >/dev/null 2>&1 || fail "teardown must land a clean self task"
assert_no_file "$state/s1.meta" "teardown archives the self task's meta"
case "$("$BIN/ac-tree.sh" list --repo "$repo" 2>/dev/null || true)" in
  *"self:s1"*) fail "teardown must give the self task's lease back" ;;
esac

pass
