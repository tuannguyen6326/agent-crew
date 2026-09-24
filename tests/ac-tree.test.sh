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

# A verifier's distinct id (grammar: bin/ac-verify.sh, <caller>-verify-<kind>
# and its -e2e companion) never gets a crew meta - get must mint none for it.
"$BIN/ac-tree.sh" get --repo "$repoM" --id fam-verify-codereview --holder verify >/dev/null 2>&1
assert_no_file "$AC_HOME/state/fam-verify-codereview.meta" "no stray meta for a verifier id"
"$BIN/ac-tree.sh" get --repo "$repoM" --id fam-verify-qa-e2e --holder verify >/dev/null 2>&1
assert_no_file "$AC_HOME/state/fam-verify-qa-e2e.meta" "no stray meta for a verifier -e2e id"

# --- destructive-path hardening ----------------------------------------------

nolsof_path() {
  # The current PATH with EVERY directory that holds an executable lsof
  # replaced, in place, by a mirror of itself without it - so `command -v lsof`
  # genuinely fails while every other tool the pool shells out to still
  # resolves. Two things this shape is deliberate about: dropping only the one
  # directory `command -v` named is not enough, because a merged-/usr Linux
  # carries both /usr/bin and /bin on PATH pointing at the same real directory
  # and the twin would keep resolving lsof; and mirrors are keyed by RESOLVED
  # path, so those twins share one mirror instead of symlinking it twice.
  # Stripping the whole PATH would test the harness, not the pool.
  local dirs d f b key mirror out=""
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/lsof" ]; then
      key="$(cd "$d" && pwd -P)"
      mirror="$TMP/nolsof$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do
          b="$(basename "$f")"
          [ "$b" = lsof ] || ln -sf "$f" "$mirror/$b" 2>/dev/null || true
        done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}

# A process walk that COULD NOT RUN must never arrive at a destructive gate
# looking like "nothing is there". prune's in-use guard reads live_procs, and
# live_procs cannot run at all without lsof - so on a host without it the
# guard never fired and prune fell straight through to drop_slot
# (git worktree remove --force + rm -rf) on a tree with a live process in it.
repoP="$(make_repo nolsof)"
wtP="$("$BIN/ac-tree.sh" get --repo "$repoP" --id np1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtP" 2>/dev/null
# disowned: nothing here signals it, and a tracked job would print a notice.
( cd "$wtP" && exec sleep 30 ) &
holderP=$!
disown "$holderP"
sleep 0.5
outP="$(PATH="$(nolsof_path)" "$BIN/ac-tree.sh" prune --repo "$repoP" --yes 2>&1 || true)"
kill "$holderP" 2>/dev/null || true
assert_contains "$outP" "skip slot 1-nolsof: cannot check for live processes" \
  "a process walk that could not run must not read as 'no live processes'"
assert_file "$wtP/file.txt" "prune must not destroy a slot whose in-use state it could not check"
assert_file "$repoP/.crew/slots/1-nolsof.meta" "the unchecked slot keeps its meta"

# return's dirty-check runs under the pool lock; the reset it authorizes runs
# deliberately UNLOCKED, after an lsof walk of the whole tree and a 2s kill
# grace. Work written into the tree inside that window used to be destroyed by
# a reset whose only authority was a check that had gone stale.
# lsof is what opens the grace; without it there is no window to write into.
if command -v lsof >/dev/null 2>&1; then
  repoT="$(make_repo toctou)"
  wtT="$("$BIN/ac-tree.sh" get --repo "$repoT" --id tc1 2>/dev/null)"
  ( cd "$wtT" && exec sleep 30 ) &
  holderT=$!
  disown "$holderT"
  sleep 0.5
  "$BIN/ac-tree.sh" return "$wtT" >"$TMP/toctou.out" 2>&1 &
  returnerT=$!
  sleep 1
  printf 'written after the check\n' >"$wtT/late-work.txt"
  wait "$returnerT" && fail "a return whose verified state moved under it must refuse"
  kill "$holderT" 2>/dev/null || true
  assert_file "$wtT/late-work.txt" "work written after the dirty-check must survive the return"
  assert_contains "$(cat "$TMP/toctou.out")" "changed after it was verified clean" \
    "the refusal names the check that went stale"
  assert_contains "$("$BIN/ac-tree.sh" list --repo "$repoT" 2>/dev/null)" "leased" \
    "a refused return must not release the slot"
fi

# SIGKILL is not synchronous, and both kill callers run a git command straight
# afterwards. The kill must WAIT - bounded - for the pids it killed to leave
# the process table. A child whose parent never reaps it is the deterministic
# stand-in for "killed but still present" (helpers.sh stands in for a live
# foreign pid the same way); kill -0 answers for it exactly as it does for a
# process that has not finished dying.
if command -v lsof >/dev/null 2>&1; then
  repoK="$(make_repo reap)"
  wtK="$("$BIN/ac-tree.sh" get --repo "$repoK" --id rp1 2>/dev/null)"
  mkfifo "$TMP/reap-gate"
  cat >"$TMP/reap-holder.sh" <<'EOF'
# $1 worktree, $2 gate fifo. The CHILD keeps its cwd inside the worktree (so
# the pool's lsof walk finds it) and ignores SIGTERM (so it survives to the
# SIGKILL leg). The PARENT leaves the tree and execs `sleep`, a process that
# never wait()s - so the SIGKILLed child stays in the process table as an
# unreaped pid (measured stat=Z, answering kill -0) until the parent is
# killed. `bash` is no good as that parent: it reaps on SIGCHLD, and the
# child was gone within 300ms - measured, which is why this exec is here.
cd "$1" || exit 1
bash -c 'trap "" TERM; exec 3<>"$1"; read -t 60 _ <&3' _ "$2" &
cd /
exec sleep 60
EOF
  bash "$TMP/reap-holder.sh" "$wtK" "$TMP/reap-gate" >/dev/null 2>&1 &
  parentK=$!
  disown "$parentK"
  sleep 0.5
  outK="$("$BIN/ac-tree.sh" return "$wtK" 2>&1 || true)"
  kill "$parentK" 2>/dev/null || true
  assert_contains "$outK" "still present after SIGKILL" \
    "the kill must wait for its pids instead of racing the next git command"
  assert_contains "$outK" "returned to pool" \
    "the wait is BOUNDED - a pid that can never be reaped must not hang the pool"
fi

# A return run from INSIDE the slot (cwd in the tree) used to kill its own
# caller: the lsof walk lists the caller's shell and every ancestor whose cwd
# is in the tree, and the kill set excluded only the pool script's own pid - a
# self-inflicted teardown that read as a crashed pane. The caller's whole
# ancestry is protected; a stranger inside the tree still dies.
if command -v lsof >/dev/null 2>&1; then
  repoS="$(make_repo selfkill)"
  wtS="$("$BIN/ac-tree.sh" get --repo "$repoS" --id sk1 2>/dev/null)"
  ( cd "$wtS" && exec sleep 30 ) &
  strangerS=$!
  disown "$strangerS"
  sleep 0.5
  # The caller: a shell whose cwd is inside the slot, which runs the return
  # and then proves it is still alive to print. `|| true` sits OUTSIDE the
  # substitution: a caller killed mid-return runs nothing after the kill, and
  # the substitution's own 143 would abort this script under errexit instead
  # of reaching the assert.
  outS="$(cd "$wtS" && bash -c '"$1" return "$2" --force >/dev/null 2>&1; echo "caller-alive $$"' _ "$BIN/ac-tree.sh" "$wtS" 2>&1)" || true
  assert_contains "$outS" "caller-alive" "a return from inside the slot must not kill its own caller"
  case "$(ps -o stat= -p "$strangerS" 2>/dev/null)" in
    ''|Z*) : ;;
    *) kill "$strangerS" 2>/dev/null; fail "a stranger inside the slot must still be terminated" ;;
  esac
  assert_eq "$(sed -n 's/^leased=//p' "$repoS/.crew/slots/1-selfkill.meta")" "0" "the inside return still releases the slot"
fi

# return by SLOT NAME: list and pool health print the slot id as the thing to
# act on, so return takes it too - resolved in the pool of --repo, or of the
# repo the cwd is in. A bare name that is no directory and no slot dies
# naming it; anything with a path separator stays a path.
repoN="$(make_repo byname)"
wtN="$("$BIN/ac-tree.sh" get --repo "$repoN" --id n1 2>/dev/null)"
metaN="$repoN/.crew/slots/1-byname.meta"
"$BIN/ac-tree.sh" return 1-byname --repo "$repoN" 2>/dev/null \
  || fail "return must accept a slot name with --repo"
assert_eq "$(sed -n 's/^leased=//p' "$metaN")" "0" "return by name releases the slot"
"$BIN/ac-tree.sh" get --repo "$repoN" --id n2 >/dev/null 2>&1
(cd "$repoN" && "$BIN/ac-tree.sh" return 1-byname 2>/dev/null) \
  || fail "return must resolve a slot name in the repo the cwd is in"
assert_eq "$(sed -n 's/^leased=//p' "$metaN")" "0" "return by name from inside the repo releases the slot"
"$BIN/ac-tree.sh" get --repo "$repoN" --id n3 >/dev/null 2>&1
idN="$(sed -n 's/^lease_id=//p' "$metaN")"
assert_fails "$BIN/ac-tree.sh" return 1-byname --repo "$repoN" --if-lease-id not-this-one
assert_eq "$(sed -n 's/^leased=//p' "$metaN")" "1" "a by-name return keeps the lease-id refusal"
printf 'junk\n' >"$wtN/junk.txt"
assert_fails "$BIN/ac-tree.sh" return 1-byname --repo "$repoN"
"$BIN/ac-tree.sh" return 1-byname --repo "$repoN" --force --if-lease-id "$idN" 2>/dev/null \
  || fail "return by name must honor --force and --if-lease-id together"
assert_no_file "$wtN/junk.txt" "a by-name forced return resets the tree"
outN="$("$BIN/ac-tree.sh" return 9-byname --repo "$repoN" 2>&1 || true)"
assert_contains "$outN" "no such slot 9-byname" "an unknown slot name dies naming it"
outN="$("$BIN/ac-tree.sh" return sub/1-byname --repo "$repoN" 2>&1 || true)"
assert_contains "$outN" "no such directory: sub/1-byname" "a name with a separator is a path, never a slot lookup"

# A committed .worktreeinclude manifest seeds project-ignored runtime files
# from the PRIMARY checkout into every acquired slot, so a fresh slot and a
# recycled one boot alike (header: WORKTREE INCLUDE). Read from the slot's
# HEAD, never a working tree. Entries that escape the repo, are absolute, are
# symlinks, or are not ignored are refused with a warning and nothing else
# breaks; the slot stays clean, since only ignored paths ever land.
repoI="$(make_repo include)"
printf '.env\ncache/\nlink\n' >"$repoI/.gitignore"
printf '# runtime files every slot needs\n.env\ncache/\nlink\n../x\n/abs\nfile.txt\n' >"$repoI/.worktreeinclude"
git -C "$repoI" add -A && git -C "$repoI" commit -qm manifest
printf 'SECRET=1\n' >"$repoI/.env"
mkdir -p "$repoI/cache" && printf 'blob\n' >"$repoI/cache/data"
ln -s /etc/hosts "$repoI/link"
outI="$("$BIN/ac-tree.sh" get --repo "$repoI" --id i1 2>&1)"
wtI="$(printf '%s\n' "$outI" | tail -n1)"
assert_eq "$wtI" "$repoI/.crew/worktrees/1-include" "the seeded slot still leases"
assert_eq "$(cat "$wtI/.env")" "SECRET=1" "an ignored file named by the manifest is seeded"
assert_eq "$(cat "$wtI/cache/data")" "blob" "an ignored directory named by the manifest is seeded"
assert_no_file "$wtI/link" "a symlink entry is never followed or copied"
assert_contains "$outI" "worktreeinclude: refusing '../x'" "an escaping entry is refused with a warning"
assert_contains "$outI" "worktreeinclude: refusing '/abs'" "an absolute entry is refused with a warning"
assert_contains "$outI" "worktreeinclude: refusing 'link'" "a symlink entry is refused with a warning"
assert_contains "$outI" "worktreeinclude: skipping 'file.txt'" "a tracked (not ignored) entry is never copied over"
[ -z "$(git -C "$wtI" status --porcelain)" ] || fail "seeding must leave the slot clean"
# A recycled slot gets the primary's CURRENT copy, not the previous lessee's.
printf 'SECRET=stale\n' >"$wtI/.env"
"$BIN/ac-tree.sh" return "$wtI" 2>/dev/null
printf 'SECRET=2\n' >"$repoI/.env"
wtI2="$("$BIN/ac-tree.sh" get --repo "$repoI" --id i2 2>/dev/null)"
assert_eq "$wtI2" "$wtI" "the recycled slot is reused"
assert_eq "$(cat "$wtI2/.env")" "SECRET=2" "a recycled slot is re-seeded from the primary"

# An EXPLICIT base ref (the integration-branch fence) is verified as a COMMIT
# before any slot is touched. The fence proves the branch exists by its full
# refname, but reset and worktree add resolve the SHORT name through git's
# DWIM order, where a same-named tag wins - so a ref that passed the fence can
# still fail every reset ("skip slot: reset failed" per slot, then a failed
# worktree add) with the cause never named. The gate dies once, naming the ref
# and the record that named it, and leases nothing.
repoF="$(make_repo fence)"
fF="$("$BIN/ac-tree.sh" get --repo "$repoF" --id f0 2>/dev/null)"
"$BIN/ac-tree.sh" return "$fF" 2>/dev/null
git -C "$repoF" branch -q feat/shadow
git -C "$repoF" tag feat/shadow "$(printf 'x' | git -C "$repoF" hash-object -w --stdin)"
printf -- '- [ ] shadow-s1 - story; feature:shadow (repo: fence)\n' >>"$AC_HOME/records/backlog.md"
mkdir -p "$AC_HOME/data/shadow"
printf 'fence feat/shadow push=deferred\n' >"$AC_HOME/data/shadow/branches"
outF="$("$BIN/ac-tree.sh" get --repo "$repoF" --id shadow-s1 --holder t 2>&1 || true)"
assert_contains "$outF" "base ref feat/shadow" "the refusal names the ref"
assert_contains "$outF" "does not resolve to a commit" "the refusal names the cause"
assert_contains "$outF" "record for shadow-s1 on fence" "the refusal names where the ref came from"
case "$outF" in *"reset failed"*) fail "the gate must fire BEFORE the acquire loop tries a slot" ;; esac
assert_eq "$(ls "$repoF/.crew/slots" | wc -l | tr -d ' ')" "1" "an unresolvable base leases and creates no slot"
assert_eq "$(sed -n 's/^leased=//p' "$repoF/.crew/slots/1-fence.meta")" "0" "the existing free slot stays available"

# lease <slot>: a DURABLE, STATE-ONLY lease on an existing pool worktree. The
# only other way to mint a lease is get, which resets the tree, so a tree that
# must live on (QA infra, a parked investigation) could be protected from get
# and prune only by staying dirty - which pool health then reports as stuck.
# lease stamps exactly the lease state get writes and touches the tree not at
# all; return releases it like any other lease.
repoE="$(make_repo parked)"
e1="$("$BIN/ac-tree.sh" get --repo "$repoE" --id e1 2>/dev/null)"
e2="$("$BIN/ac-tree.sh" get --repo "$repoE" --id e2 2>/dev/null)"
"$BIN/ac-tree.sh" return "$e1" 2>/dev/null
printf 'parked investigation\n' >"$e1/parked.txt"
git -C "$e1" checkout -q -b crew/park && git -C "$e1" add -A && git -C "$e1" commit -qm parked
printf 'wip\n' >"$e1/wip.txt"
headE="$(git -C "$e1" rev-parse HEAD)"
metaE="$repoE/.crew/slots/1-parked.meta"
"$BIN/ac-tree.sh" lease 1-parked --repo "$repoE" --id park --holder self:park 2>/dev/null \
  || fail "lease of an available slot must succeed"
assert_eq "$(git -C "$e1" rev-parse HEAD)" "$headE" "lease is state-only: HEAD untouched"
assert_eq "$(git -C "$e1" symbolic-ref -q --short HEAD)" "crew/park" "lease is state-only: the branch checkout survives"
assert_eq "$(cat "$e1/parked.txt")" "parked investigation" "lease is state-only: committed content preserved byte-for-byte"
assert_eq "$(cat "$e1/wip.txt")" "wip" "lease is state-only: uncommitted content preserved byte-for-byte"
assert_eq "$(sed -n 's/^leased=//p' "$metaE")" "1" "the slot is leased"
assert_eq "$(sed -n 's/^task=//p' "$metaE")" "park" "the lease records the task"
assert_eq "$(sed -n 's/^holder=//p' "$metaE")" "self:park" "the lease records the holder"
assert_eq "$(sed -n 's/^owner_pid=//p' "$metaE")" "" "a lease is durable: no owner pid"
[ -n "$(sed -n 's/^lease_id=//p' "$metaE")" ] || fail "lease must mint a lease id"
[ -n "$(sed -n 's/^leased_at=//p' "$metaE")" ] || fail "lease must stamp leased_at"
outE="$("$BIN/ac-tree.sh" list --repo "$repoE")"
assert_contains "$outE" "1-parked	leased dirty	park" "list shows the leased slot like any other lease"
assert_contains "$(cat "$repoE/.crew/parked.code-workspace")" '"path": "worktrees/1-parked", "name": "wt1-parked - park"' "the editor workspace picks the lease up"
# Already leased: refused naming the holder, the slot untouched; the path
# form names the same slot.
outE="$("$BIN/ac-tree.sh" lease "$e2" --repo "$repoE" --id other --holder crew:other 2>&1 || true)"
assert_contains "$outE" "slot 2-parked is leased by task e2" "a leased slot refuses naming the holder"
assert_eq "$(sed -n 's/^task=//p' "$repoE/.crew/slots/2-parked.meta")" "e2" "a refused lease changes nothing"
assert_fails "$BIN/ac-tree.sh" lease 2-parked --repo "$repoE" --id other
outE="$("$BIN/ac-tree.sh" lease 9-parked --repo "$repoE" --id x 2>&1 || true)"
assert_contains "$outE" "no such slot 9-parked" "an unknown slot name dies naming it"
# get never hands the leased slot out, prune never takes it.
e3="$("$BIN/ac-tree.sh" get --repo "$repoE" --id e3 2>/dev/null)"
assert_eq "$e3" "$repoE/.crew/worktrees/3-parked" "get skips the leased slot"
assert_eq "$(cat "$e1/parked.txt")" "parked investigation" "get left the leased tree alone"
assert_contains "$("$BIN/ac-tree.sh" prune --repo "$repoE" --yes 2>&1)" "skip slot 1-parked: leased" "prune skips the leased slot"
# A task whose crew meta exists gets the lease appended, like a second get.
printf 'kind=ship\nworktree=%s\nleases=%s\n' "$e3" "$e3" >"$AC_HOME/state/e3.meta"
"$BIN/ac-tree.sh" return "$e2" 2>/dev/null
"$BIN/ac-tree.sh" lease 2-parked --repo "$repoE" --id e3 --holder crew:e3 2>/dev/null || fail "lease for a task with a crew meta"
assert_eq "$(awk -F= '$1=="leases"{print $2}' "$AC_HOME/state/e3.meta")" "$e3:$e2" "a lease is appended to the task's leases="
# return releases it, bound to the lease id like any other.
idE="$(sed -n 's/^lease_id=//p' "$metaE")"
assert_fails "$BIN/ac-tree.sh" return 1-parked --repo "$repoE" --force --if-lease-id not-this-one
"$BIN/ac-tree.sh" return 1-parked --repo "$repoE" --force --if-lease-id "$idE" 2>/dev/null \
  || fail "return must release a state-only lease by its lease id"
assert_eq "$(sed -n 's/^leased=//p' "$metaE")" "0" "return released the lease"
assert_eq "$(sed -n 's/^lease_id=//p' "$metaE")" "" "the identity dies with the lease"

pass
