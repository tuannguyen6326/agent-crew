#!/usr/bin/env bash
# ac-tree.test.sh - the in-repo worktree pool: acquire inside the repo,
# .git/info/exclude handling (tracked .gitignore stays untouched, legacy
# lines migrate out), lease/reuse/return semantics, dirty-slot protection,
# prune/remove safety, pool cap, get --prefer slot affinity.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo)"

# Acquire: worktree lands inside the repo, detached HEAD, ignored via
# .git/info/exclude - the tracked .gitignore is never created or touched.
wt1="$("$BIN/ac-tree.sh" get --repo "$repo" --id t1 --holder crew:t1 2>/dev/null)"
assert_eq "$wt1" "$repo/.crew/worktrees/1-repo" "slot 1 path"
[ -d "$wt1" ] || fail "worktree dir missing"
git -C "$wt1" symbolic-ref -q HEAD >/dev/null && fail "worktree should be detached HEAD"
grep -qxF '/.crew/' "$repo/.git/info/exclude" || fail "info/exclude entry missing"
[ -e "$repo/.gitignore" ] && fail "tracked .gitignore must not be created"
git -C "$repo" check-ignore -q .crew/x || fail "git must ignore .crew/ paths"
git -C "$wt1" check-ignore -q .crew/x || fail "exclude must reach linked worktrees"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "acquire dirtied the clone"

# List shows the lease and the task id; second acquire grows the pool.
out="$("$BIN/ac-tree.sh" list --repo "$repo")"
assert_contains "$out" "leased" "list shows lease"
assert_contains "$out" "t1" "list shows task"
wt2="$("$BIN/ac-tree.sh" get --repo "$repo" --id t2 2>/dev/null)"
assert_eq "$wt2" "$repo/.crew/worktrees/2-repo" "slot 2 path"

# The generated editor workspace: repo + one folder per ACTIVE lease so
# VSCode/Cursor shows active task trees as repositories without idle pool
# slots filling the Git tab (header: pool layout, .code-workspace).
ws="$repo/.crew/repo.code-workspace"
assert_file "$ws" "workspace file generated on acquire"
jq empty "$ws" >/dev/null 2>&1 || fail "workspace file must be valid JSON"
assert_contains "$(cat "$ws")" '"path": ".."' "main repo folder present"
assert_contains "$(cat "$ws")" '"path": "worktrees/1-repo", "name": "wt1-repo - t1"' "leased slot named with its task"
assert_contains "$(cat "$ws")" '"path": "worktrees/2-repo", "name": "wt2-repo - t2"' "every active slot listed"

# Return refuses to discard dirty work without --force, then resets.
printf 'junk\n' >"$wt1/junk.txt"
assert_fails "$BIN/ac-tree.sh" return "$wt1"
"$BIN/ac-tree.sh" return "$wt1" --force 2>/dev/null
assert_no_file "$wt1/junk.txt" "forced return reset the tree"
assert_contains "$("$BIN/ac-tree.sh" list --repo "$repo")" "available" "slot released"
case "$(cat "$ws")" in
  *'"path": "worktrees/1-repo"'*) fail "returned slot must leave the active editor workspace" ;;
esac
assert_contains "$(cat "$ws")" '"path": "worktrees/2-repo", "name": "wt2-repo - t2"' "other active slot remains"
wt3="$("$BIN/ac-tree.sh" get --repo "$repo" --id t3 2>/dev/null)"
assert_eq "$wt3" "$wt1" "released slot reused"
assert_contains "$(cat "$ws")" '"path": "worktrees/1-repo", "name": "wt1-repo - t3"' "re-leased slot returns with its new task"

# An available-but-dirty slot is never silently reset: acquire skips it.
"$BIN/ac-tree.sh" return "$wt3" 2>/dev/null
printf 'unlanded\n' >>"$wt1/file.txt"
wt4="$("$BIN/ac-tree.sh" get --repo "$repo" --id t4 2>/dev/null)"
assert_eq "$wt4" "$repo/.crew/worktrees/3-repo" "dirty slot skipped, pool grew"

# Remove: refuses a leased slot without --include-leased.
assert_fails "$BIN/ac-tree.sh" remove "$wt2"

# Prune: dry-run by default; skips leased and dirty; removes merged idle.
"$BIN/ac-tree.sh" return "$wt4" 2>/dev/null
out="$("$BIN/ac-tree.sh" prune --repo "$repo" 2>&1)"
assert_contains "$out" "would prune slot 3-repo" "dry-run"
[ -d "$wt4" ] || fail "dry-run must not remove"
out="$("$BIN/ac-tree.sh" prune --repo "$repo" --yes 2>&1)"
assert_contains "$out" "skip slot 1-repo: dirty" "dirty skipped"
assert_contains "$out" "skip slot 2-repo: leased" "leased skipped"
assert_contains "$out" "pruned slot 3-repo" "idle merged pruned"
assert_no_file "$wt4" "pruned dir gone"
case "$(cat "$ws")" in *worktrees/3-repo*) fail "a pruned slot must leave the workspace file" ;; esac

# Remove: refuses a dirty tree without --force.
assert_fails "$BIN/ac-tree.sh" remove "$wt1"
"$BIN/ac-tree.sh" remove "$wt1" --force 2>/dev/null
assert_no_file "$wt1" "forced remove"

# Pool cap: AC_MAX_TREES bounds growth.
# A legacy numeric slot migrates to <n>-<repo> on its next reuse.
repoG="$(make_repo legacy)"
lg1="$("$BIN/ac-tree.sh" get --repo "$repoG" --id g1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$lg1" >/dev/null 2>&1
git -C "$repoG" worktree move "$lg1" "$repoG/.crew/worktrees/1" >/dev/null 2>&1
mv "$repoG/.crew/slots/1-legacy.meta" "$repoG/.crew/slots/1.meta"
lg2="$("$BIN/ac-tree.sh" get --repo "$repoG" --id g2 2>/dev/null)"
assert_eq "$lg2" "$repoG/.crew/worktrees/1-legacy" "legacy slot renamed on reuse"
assert_file "$repoG/.crew/slots/1-legacy.meta" "meta followed the rename"
assert_no_file "$repoG/.crew/slots/1.meta" "old meta gone"
git -C "$lg2" rev-parse HEAD >/dev/null 2>&1 || fail "moved worktree still a valid checkout"
"$BIN/ac-tree.sh" return "$lg2" >/dev/null 2>&1

repo2="$(make_repo capped)"
AC_MAX_TREES=1 "$BIN/ac-tree.sh" get --repo "$repo2" --id a >/dev/null 2>&1
AC_MAX_TREES=1 assert_fails "$BIN/ac-tree.sh" get --repo "$repo2" --id b

# A lease whose recorded owner pid is dead self-heals: the slot is reclaimed.
repo3="$(make_repo owned)"
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
wta="$("$BIN/ac-tree.sh" get --repo "$repo3" --id o1 --owner "$dead_pid" 2>/dev/null)"
wtb="$(AC_MAX_TREES=1 "$BIN/ac-tree.sh" get --repo "$repo3" --id o2 2>/dev/null)"
assert_eq "$wtb" "$wta" "dead-owner lease reclaimed"

# Clean-but-unmerged work is refused by remove without --force.
git -C "$wtb" commit --allow-empty -qm "unmerged detached commit"
python3 - "$repo3/.crew/slots/1-owned.meta" <<'EOF'
import sys
p = sys.argv[1]
lines = [l for l in open(p) if not l.startswith("leased=")]
open(p, "w").writelines(lines + ["leased=0\n"])
EOF
assert_fails "$BIN/ac-tree.sh" remove "$wtb"
"$BIN/ac-tree.sh" remove "$wtb" --force 2>/dev/null
assert_no_file "$wtb" "forced remove of unmerged"

# A half-written slot meta (no leased key) fails closed: never reused.
repo4="$(make_repo halfmeta)"
wtc="$("$BIN/ac-tree.sh" get --repo "$repo4" --id h1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtc" 2>/dev/null
grep -v '^leased=' "$repo4/.crew/slots/1-halfmeta.meta" >"$repo4/.crew/slots/1-halfmeta.meta.t" \
  && mv "$repo4/.crew/slots/1-halfmeta.meta.t" "$repo4/.crew/slots/1-halfmeta.meta"
wtd="$("$BIN/ac-tree.sh" get --repo "$repo4" --id h2 2>/dev/null)"
assert_eq "$wtd" "$repo4/.crew/worktrees/2-halfmeta" "unknown lease state skipped"

# info/exclude append never corrupts a newline-less final line, and a
# tracked .gitignore without our line is left byte-identical.
repo5="$(make_repo nl)"
printf 'node_modules\n' >"$repo5/.gitignore"
git -C "$repo5" add -A && git -C "$repo5" commit -qm gitignore
printf 'vendor' >"$repo5/.git/info/exclude"
"$BIN/ac-tree.sh" get --repo "$repo5" --id n1 >/dev/null 2>&1
grep -qxF 'vendor' "$repo5/.git/info/exclude" || fail "existing exclude rule corrupted"
grep -qxF '/.crew/' "$repo5/.git/info/exclude" || fail "/.crew/ exclude entry missing"
assert_eq "$(cat "$repo5/.gitignore")" "node_modules" ".gitignore must stay untouched"
[ -z "$(git -C "$repo5" status --porcelain)" ] || fail "acquire dirtied the clone"

# Migration: an exact /.crew/ line a previous version appended to the
# TRACKED .gitignore is removed - and only it - announced once, and the
# clone comes back clean.
repo6="$(make_repo migrate)"
printf 'node_modules\n' >"$repo6/.gitignore"
git -C "$repo6" add -A && git -C "$repo6" commit -qm gitignore
printf '/.crew/\n' >>"$repo6/.gitignore"
out="$("$BIN/ac-tree.sh" get --repo "$repo6" --id m1 2>&1)"
assert_contains "$out" "migrated: /.crew/ ignore moved to .git/info/exclude" "migration announced"
grep -qxF '/.crew/' "$repo6/.gitignore" && fail "/.crew/ still in tracked .gitignore"
grep -qxF 'node_modules' "$repo6/.gitignore" || fail "other .gitignore content lost"
grep -qxF '/.crew/' "$repo6/.git/info/exclude" || fail "exclude missing after migration"
[ -z "$(git -C "$repo6" status --porcelain)" ] || fail "migrated clone still dirty"

# Migration edge: a .gitignore we created from scratch (only /.crew/, never
# tracked) is removed entirely instead of lingering empty.
repo7="$(make_repo migrate2)"
printf '/.crew/\n' >"$repo7/.gitignore"
"$BIN/ac-tree.sh" get --repo "$repo7" --id m2 >/dev/null 2>&1
assert_no_file "$repo7/.gitignore" "orphan .gitignore removed"
[ -z "$(git -C "$repo7" status --porcelain)" ] || fail "clone still dirty after migration"

# get --prefer: an AVAILABLE preferred slot is leased exactly, beating the
# normal lowest-slot selection; both the bare number and the worktree path
# forms are accepted.
repo9="$(make_repo prefer)"
p1="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p1 2>/dev/null)"
p2="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p2 2>/dev/null)"
"$BIN/ac-tree.sh" return "$p1" 2>/dev/null
"$BIN/ac-tree.sh" return "$p2" 2>/dev/null
p3="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p3 --prefer 2 2>/dev/null)"
assert_eq "$p3" "$repo9/.crew/worktrees/2-prefer" "prefer honored when slot available"
"$BIN/ac-tree.sh" return "$p3" 2>/dev/null
p4="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p4 --prefer "$repo9/.crew/worktrees/2-prefer" 2>/dev/null)"
assert_eq "$p4" "$repo9/.crew/worktrees/2-prefer" "prefer accepts the worktree path form"

# A preferred slot leased by another task falls back to normal selection
# with ONE warning line naming both slots.
out="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p5 --prefer 2 2>&1)"
assert_eq "$(printf '%s\n' "$out" | tail -n1)" "$repo9/.crew/worktrees/1-prefer" "leased prefer falls back"
assert_contains "$out" "prefer: slot 2-prefer unavailable (leased by task p4) - leased slot 1-prefer instead" "leased prefer warned"

# An available-but-dirty preferred slot is never silently reset: fall back
# and warn, like the normal selection does.
"$BIN/ac-tree.sh" return "$p4" 2>/dev/null
printf 'dirt\n' >>"$repo9/.crew/worktrees/2-prefer/file.txt"
out="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p6 --prefer 2 2>&1)"
assert_eq "$(printf '%s\n' "$out" | tail -n1)" "$repo9/.crew/worktrees/3-prefer" "dirty prefer falls back"
assert_contains "$out" "prefer: slot 2-prefer unavailable (dirty" "dirty prefer warned"

# A preferred slot that does not exist falls back too; a malformed value dies.
out="$("$BIN/ac-tree.sh" get --repo "$repo9" --id p7 --prefer 9 2>&1)"
assert_contains "$out" "prefer: slot 9 unavailable (no such slot)" "missing prefer warned"
assert_fails "$BIN/ac-tree.sh" get --repo "$repo9" --id p8 --prefer bogus

# Lease identity: a slot is identified by PATH, and paths are REUSED, so a
# return that arrives after the slot was re-leased must refuse instead of
# resetting the tree of whoever holds it now (the ABA case).
repoL="$(make_repo lease)"
wtA="$("$BIN/ac-tree.sh" get --repo "$repoL" --id a1 --holder crew:a1 2>/dev/null)"
metaL="$repoL/.crew/slots/1-lease.meta"
idA="$(sed -n 's/^lease_id=//p' "$metaL")"
[ -n "$idA" ] || fail "acquire must mint a lease id"
"$BIN/ac-tree.sh" return "$wtA" --force --if-lease-id "$idA" 2>/dev/null \
  || fail "return with the matching lease id must succeed"
assert_eq "$(sed -n 's/^lease_id=//p' "$metaL")" "" "the identity dies with the lease"

# Same slot, same holder, second acquisition: a NEW identity.
wtB="$("$BIN/ac-tree.sh" get --repo "$repoL" --id a1 --holder crew:a1 2>/dev/null)"
assert_eq "$wtB" "$wtA" "released slot reused"
idB="$(sed -n 's/^lease_id=//p' "$metaL")"
[ -n "$idB" ] || fail "re-acquire must mint a lease id"
[ "$idA" != "$idB" ] || fail "each acquisition needs its OWN identity"

# The late return: A's teardown fires while B holds the slot. It must refuse,
# and B's uncommitted work must survive - that is the whole point.
printf 'work in progress\n' >"$wtB/b-work.txt"
assert_fails "$BIN/ac-tree.sh" return "$wtB" --force --if-lease-id "$idA"
assert_file "$wtB/b-work.txt" "a refused return must not reset the tree"
assert_contains "$("$BIN/ac-tree.sh" list --repo "$repoL")" "leased" "a refused return must not release the slot"
out="$("$BIN/ac-tree.sh" return "$wtB" --force --if-lease-id "$idA" 2>&1 || true)"
assert_contains "$out" "$idA" "the refusal names the id that was offered"

# Back-compat: a slot meta with no lease_id (a pool predating the id) is
# returned unconditionally, exactly as before.
"$BIN/ac-tree.sh" return "$wtB" --force --if-lease-id "$idB" 2>/dev/null \
  || fail "return with the current id must succeed"
wtC="$("$BIN/ac-tree.sh" get --repo "$repoL" --id a2 2>/dev/null)"
grep -v '^lease_id=' "$metaL" >"$metaL.tmp" && mv "$metaL.tmp" "$metaL"
"$BIN/ac-tree.sh" return "$wtC" --force 2>/dev/null \
  || fail "an unflagged return must still work on a pre-identity slot"

# return's destructive section is GATED on the pool lock: the identity check,
# the proc-kill and the tree reset used to run unlocked, so a return could
# hard-reset a tree while a locked acquire_slot was re-leasing the slot. Hold
# the lock from here (it is a plain dir under .crew/lock, like any other
# holder) and nothing may be destroyed until it is free.
repoR="$(make_repo poollock)"
wtR="$("$BIN/ac-tree.sh" get --repo "$repoR" --id r1 --holder crew:r1 2>/dev/null)"
metaR="$repoR/.crew/slots/1-poollock.meta"
idR="$(sed -n 's/^lease_id=//p' "$metaR")"
printf 'unlanded\n' >"$wtR/sentinel.txt"
lockR="$repoR/.crew/lock"
mkdir "$lockR" && printf '%s\n' "$$" >"$lockR/pid"
"$BIN/ac-tree.sh" return "$wtR" --force >/dev/null 2>&1 &
returner=$!
sleep 3
assert_file "$wtR/sentinel.txt" "a return must not reset the tree while the pool lock is held"
assert_eq "$(sed -n 's/^leased=//p' "$metaR")" "1" "a blocked return must not release the slot"
assert_eq "$(sed -n 's/^lease_id=//p' "$metaR")" "$idR" "a blocked return must not drop the lease identity"
rm -rf "$lockR"
wait "$returner" || fail "the return must complete once the pool lock is free"
assert_no_file "$wtR/sentinel.txt" "the return resets the tree once it holds the lock"
assert_eq "$(sed -n 's/^leased=//p' "$metaR")" "0" "the return releases the slot"

# ... and the destructive section itself runs UNLOCKED (it would otherwise hold
# the pool lock across lsof, a 2s kill grace and a whole-tree reset), so the
# claim it takes under the lock must be what keeps a concurrent acquire off the
# slot: the lease is re-owned by the LIVE returning process, which acquire,
# prune and remove all refuse to reclaim. This is the ABA of the lease-identity
# block above seen from the other side. lsof is what opens the kill grace that
# makes the window observable; without it there is no window to test.
if command -v lsof >/dev/null 2>&1; then
  repoW="$(make_repo poolwindow)"
  sleep 0.1 &
  deadW=$!
  wait "$deadW" 2>/dev/null || true
  wtW="$("$BIN/ac-tree.sh" get --repo "$repoW" --id w1 --owner "$deadW" 2>/dev/null)"
  # disowned: the return SIGTERMs this holder, and a tracked job dying by
  # signal makes bash print a "Terminated" notice that reads like a crash.
  ( cd "$wtW" && exec sleep 30 ) &
  holderW=$!
  disown "$holderW"
  sleep 0.5
  "$BIN/ac-tree.sh" return "$wtW" >/dev/null 2>&1 &
  returner=$!
  sleep 1
  outW="$(AC_MAX_TREES=1 "$BIN/ac-tree.sh" get --repo "$repoW" --id w2 2>&1 || true)"
  case "$outW" in
    *"$repoW/.crew/worktrees/1-poolwindow"*) fail "a return in flight must not leave its slot re-leasable: $outW" ;;
  esac
  assert_contains "$outW" "pool is full" "the slot under return stays leased to its live owner"
  wait "$returner" || fail "the return must still complete"
  kill "$holderW" 2>/dev/null || true
fi

# heal_slots must not rm -rf a BROKEN slot that still has its directory: the
# files there may be unlanded work, and the signal that would prove otherwise
# is exactly the one a broken gitdir takes away (is_dirty runs `git status`,
# which fails EMPTY on such a tree and reports it CLEAN). Leased state, read
# from the pool's own meta, is what still answers.
repoH="$(make_repo broken)"
wtH="$("$BIN/ac-tree.sh" get --repo "$repoH" --id b1 --holder crew:b1 2>/dev/null)"
printf 'unlanded work\n' >"$wtH/wip.txt"
rm -rf "$repoH/.git/worktrees/1-broken"
git -C "$wtH" rev-parse --git-dir >/dev/null 2>&1 && fail "fixture: the worktree must be broken"
[ -n "$(git -C "$wtH" status --porcelain 2>/dev/null)" ] && fail "fixture: is_dirty must be blind here"
out="$("$BIN/ac-tree.sh" list --repo "$repoH" 2>&1)"
assert_file "$wtH/wip.txt" "a broken slot's unlanded work must survive heal"
assert_file "$repoH/.crew/slots/1-broken.meta" "a broken slot's meta must survive heal"
assert_contains "$out" "slot 1-broken: worktree broken" "the skip is announced"
assert_contains "$out" "remove --force --include-leased $wtH" "the warn names the exact reclaim command"

# ... and that named reclaim must actually RUN on such a slot - a skip whose
# exit is refused strands the slot forever. It stays fail-closed: git can check
# neither dirty nor merged here, so the discard needs --force like every other
# unverifiable one.
outR="$("$BIN/ac-tree.sh" remove "$wtH" --include-leased 2>&1 || true)"
assert_contains "$outR" "slot 1-broken is broken (gitdir unreadable)" "remove refuses an unverifiable slot without --force"
assert_file "$wtH/wip.txt" "a refused remove must not destroy the slot"
"$BIN/ac-tree.sh" remove "$wtH" --force --include-leased 2>/dev/null \
  || fail "the reclaim command the warn names must work on a broken slot"
assert_no_file "$wtH" "the named reclaim takes the slot"
assert_no_file "$repoH/.crew/slots/1-broken.meta" "the reclaimed slot's meta is dropped"

# A slot whose DIRECTORY has vanished has nothing left to lose: still healed.
repoV="$(make_repo vanished)"
wtV="$("$BIN/ac-tree.sh" get --repo "$repoV" --id v1 2>/dev/null)"
rm -rf "$wtV"
out="$("$BIN/ac-tree.sh" list --repo "$repoV" 2>&1)"
assert_contains "$out" "healed slot 1-vanished" "a vanished worktree dir is still healed"
assert_no_file "$repoV/.crew/slots/1-vanished.meta" "the healed slot's meta is dropped"

# A /.crew/ line already committed in HEAD is project content: never
# stripped (removing it would dirty the clone the other way).
repo8="$(make_repo committed)"
printf '/.crew/\n' >"$repo8/.gitignore"
git -C "$repo8" add -A && git -C "$repo8" commit -qm gitignore
out="$("$BIN/ac-tree.sh" get --repo "$repo8" --id c1 2>&1)"
case "$out" in *migrated*) fail "committed /.crew/ line must not be migrated" ;; esac
grep -qxF '/.crew/' "$repo8/.gitignore" || fail "committed .gitignore line removed"
[ -z "$(git -C "$repo8" status --porcelain)" ] || fail "clone dirtied"

# A second worktree lease for a task whose crew meta already exists is
# appended to state/<id>.meta leases=/lease_ids=, index-aligned - the
# mechanism that lets ac-teardown.sh return every tree a task holds. The
# FIRST lease of a spawn/self-task always predates state/<id>.meta (spawn
# writes it only after get returns), so get must mint nothing for it.
repoM="$(make_repo secondlease)"
wtM1="$("$BIN/ac-tree.sh" get --repo "$repoM" --id t9 --holder crew:t9 2>/dev/null)"
assert_no_file "$AC_HOME/state/t9.meta" "the first lease predates the crew meta - get must not mint one"
idM1="$(awk -F= '$1=="lease_id"{print $2}' "$repoM/.crew/slots/$(basename "$wtM1").meta")"
# Mimic what ac-spawn.sh/ac-self-task.sh write right after this same call.
printf 'kind=ship\nworktree=%s\nleases=%s\nlease_ids=%s\n' "$wtM1" "$wtM1" "$idM1" \
  >"$AC_HOME/state/t9.meta"
wtM2="$("$BIN/ac-tree.sh" get --repo "$repoM" --id t9 --holder crew:t9 2>/dev/null)"
idM2="$(awk -F= '$1=="lease_id"{print $2}' "$repoM/.crew/slots/$(basename "$wtM2").meta")"
assert_eq "$(awk -F= '$1=="leases"{print $2}' "$AC_HOME/state/t9.meta")" "$wtM1:$wtM2" \
  "a second lease is appended to leases="
assert_eq "$(awk -F= '$1=="lease_ids"{print $2}' "$AC_HOME/state/t9.meta")" "$idM1:$idM2" \
  "lease_ids stays index-aligned with leases"
assert_eq "$(awk -F= '$1=="worktree"{print $2}' "$AC_HOME/state/t9.meta")" "$wtM1" \
  "worktree= (the primary tree) is untouched by the append"

# A verifier's distinct id (grammar: bin/ac-verify.sh, <family>-verify-<kind>
# and its -e2e companion) never gets a crew meta - get must mint none for it.
"$BIN/ac-tree.sh" get --repo "$repoM" --id fam-verify-codereview --holder verify >/dev/null 2>&1
assert_no_file "$AC_HOME/state/fam-verify-codereview.meta" "no stray meta for a verifier id"
"$BIN/ac-tree.sh" get --repo "$repoM" --id fam-verify-qa-e2e --holder verify >/dev/null 2>&1
assert_no_file "$AC_HOME/state/fam-verify-qa-e2e.meta" "no stray meta for a verifier -e2e id"

pass
