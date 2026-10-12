#!/usr/bin/env bash
# ac-tree.test.sh - the in-repo worktree pool: acquire inside the repo,
# .git/info/exclude handling (tracked .gitignore stays untouched, legacy
# lines migrate out), lease/reuse/return semantics, dirty-slot protection,
# prune/remove safety, pool cap, get --prefer slot affinity.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# Hidden edits are dirt too: `git status` skips a file flagged assume-unchanged
# (git-update-index, "USING ASSUME UNCHANGED BIT"), and a return would reset it.
git -C "$wt2" update-index --assume-unchanged file.txt
printf 'hidden edit\n' >>"$wt2/file.txt"
[ -z "$(git -C "$wt2" status --porcelain)" ] || fail "fixture: status must be blind to the assume-unchanged edit"
assert_fails "$BIN/ac-tree.sh" return "$wt2"
assert_contains "$(cat "$wt2/file.txt")" "hidden edit" "the hidden edit survives the refused return"
git -C "$wt2" update-index --no-assume-unchanged file.txt
git -C "$wt2" checkout -- file.txt
# ...and so are the hidden edits that change no bytes: a deletion and an
# executable-bit flip behind the same bit.
git -C "$wt2" update-index --assume-unchanged file.txt
rm "$wt2/file.txt"
assert_fails "$BIN/ac-tree.sh" return "$wt2"
git -C "$wt2" checkout -- file.txt 2>/dev/null || git -C "$wt2" show HEAD:file.txt >"$wt2/file.txt"
chmod +x "$wt2/file.txt"
assert_fails "$BIN/ac-tree.sh" return "$wt2"
chmod -x "$wt2/file.txt"
git -C "$wt2" update-index --no-assume-unchanged file.txt
[ -z "$(git -C "$wt2" status --porcelain)" ] || fail "fixture: the tree must be clean again"
# An absent skip-worktree file is a deletion hidden like any other - unless a
# sparse checkout is on, which leaves files absent by design.
git -C "$wt2" update-index --skip-worktree file.txt
rm "$wt2/file.txt"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) ;; *) fail "a skip-worktree deletion outside a sparse checkout is work" ;; esac
git -C "$wt2" update-index --no-skip-worktree file.txt
git -C "$wt2" checkout -- file.txt
# Under a sparse checkout, absence is by design only for a path the sparse
# rules EXCLUDE; a path they include that is absent is still a hidden deletion.
git -C "$wt2" sparse-checkout set --no-cone '/nothing-here/' >/dev/null 2>&1
[ -e "$wt2/file.txt" ] && fail "fixture: the sparse rules must leave file.txt out"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) fail "a file the sparse rules exclude is absent by design" ;; esac
git -C "$wt2" sparse-checkout set --no-cone '/*' >/dev/null 2>&1
git -C "$wt2" update-index --skip-worktree file.txt
rm "$wt2/file.txt"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) ;; *) fail "a skip-worktree deletion of a file the sparse rules include is work" ;; esac
git -C "$wt2" update-index --no-skip-worktree file.txt
git -C "$wt2" checkout -- file.txt
# A path the rules include is work even when its name is only newlines, which a
# command substitution would otherwise shave down to nothing.
nl=$'\n'
printf 'nl\n' >"$wt2/$nl"
git -C "$wt2" add -- "$nl"
git -C "$wt2" -c user.email=t@t -c user.name=t commit -qm "a newline-only name"
git -C "$wt2" update-index --skip-worktree -- "$nl"
rm "$wt2/$nl"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) ;; *) fail "an included skip-worktree deletion is work whatever its name" ;; esac
git -C "$wt2" update-index --no-skip-worktree -- "$nl"
# Only a file whose hidden bit is set is re-hashed, whatever the locale: in a
# UTF-8 locale a bash [a-z] range also matches `ls-files -v`'s `H`, the tag of
# every ordinary tracked file, and each one then costs its own git calls.
gcount="$TMP/git-count"; mkdir -p "$gcount"
printf '#!/usr/bin/env bash\ncase " $* " in *" hash-object "*) printf x >>"%s" ;; esac\nexec "%s" "$@"\n' \
  "$TMP/hash-object.calls" "$(command -v git)" >"$gcount/git"
chmod +x "$gcount/git"
: >"$TMP/hash-object.calls"
LC_ALL=en_US.UTF-8 PATH="$gcount:$PATH" "$BIN/ac-tree.sh" list --repo "$repo" >/dev/null
assert_eq "$(wc -c <"$TMP/hash-object.calls" | tr -d ' ')" "0" "a tree with no hidden-bit file hashes nothing, in a UTF-8 locale too"
git -C "$wt2" checkout -- "$nl"
# A git older than 2.41 has no `sparse-checkout check-rules` (it exits 129):
# then the sparse flag alone decides, as it did before, rather than every
# sparse omission reading as work on a git the fleet still supports.
mkdir -p "$TMP/oldgit"
cat >"$TMP/oldgit/git" <<OLDGIT
#!/usr/bin/env bash
case " \$* " in *" check-rules "*) exit 129 ;; esac
exec $(command -v git) "\$@"
OLDGIT
chmod +x "$TMP/oldgit/git"
git -C "$wt2" sparse-checkout set --no-cone '/nothing-here/' >/dev/null 2>&1
case "$(PATH="$TMP/oldgit:$PATH" "$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) fail "a git without check-rules must not turn sparse omissions into work" ;; esac
git -C "$wt2" sparse-checkout disable >/dev/null 2>&1
# git C-quotes a non-ASCII path in `ls-files -v`; the scan must read the real
# name - a clean flagged file is clean, an edited one is work.
printf 'quoted\n' >"$wt2/エ.txt"
git -C "$wt2" add "エ.txt"
git -C "$wt2" -c user.email=t@t -c user.name=t commit -qm "a non-ASCII name"
git -C "$wt2" update-index --assume-unchanged "エ.txt"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) fail "a clean flagged file with a quoted name must not read as dirty" ;; esac
git -C "$wt2" update-index --no-assume-unchanged "エ.txt"
git -C "$wt2" update-index --skip-worktree "エ.txt"
printf 'edited\n' >>"$wt2/エ.txt"
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) ;; *) fail "an edited skip-worktree file with a quoted name is work" ;; esac
git -C "$wt2" update-index --no-skip-worktree "エ.txt"
git -C "$wt2" checkout -- "エ.txt"

# An interrupted rebase or bisect leaves a CLEAN tree, and the reset a return
# runs keeps its state dir - the next lessee's `git rebase` then refuses
# ("there is already a rebase-merge directory", probed on git 2.55). It is work
# in progress like any edit, never silently reset.
git -C "$wt2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "mid-rebase work"
GIT_SEQUENCE_EDITOR="sed -i.bak 's/^pick/edit/'" git -C "$wt2" -c user.email=t@t -c user.name=t rebase -q -i HEAD~1 >/dev/null 2>&1 || true
[ -d "$(git -C "$wt2" rev-parse --git-dir)/rebase-merge" ] || fail "fixture: the rebase must stop mid-way"
[ -z "$(git -C "$wt2" status --porcelain)" ] || fail "fixture: the stopped rebase leaves a clean tree"
assert_fails "$BIN/ac-tree.sh" return "$wt2"
[ -d "$(git -C "$wt2" rev-parse --git-dir)/rebase-merge" ] || fail "a refused return must keep the rebase"
git -C "$wt2" rebase --abort
# A FORCED return discards it with the rest of the slot - including the state
# dir a plain reset keeps - so the next lessee's rebase runs.
git -C "$wt2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "mid-rebase work"
GIT_SEQUENCE_EDITOR="sed -i.bak 's/^pick/edit/'" git -C "$wt2" -c user.email=t@t -c user.name=t rebase -q -i HEAD~1 >/dev/null 2>&1 || true
"$BIN/ac-tree.sh" return "$wt2" --force 2>/dev/null
[ -e "$(git -C "$wt2" rev-parse --git-dir)/rebase-merge" ] && fail "a forced return must clear the interrupted rebase"
wt2="$("$BIN/ac-tree.sh" get --repo "$repo" --id t2 --prefer 2 2>/dev/null)"
assert_eq "$wt2" "$repo/.crew/worktrees/2-repo" "fixture: re-lease slot 2"
git -C "$wt2" bisect start HEAD HEAD~1 >/dev/null 2>&1
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) ;; *) fail "a bisect in progress is work" ;; esac
git -C "$wt2" bisect reset >/dev/null 2>&1
case "$("$BIN/ac-tree.sh" list --repo "$repo")" in *"leased dirty"*) fail "fixture: the slot must be clean again" ;; esac

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

# A slot whose .git FILE is gone is broken too, and worse disguised: git walks
# up from it and answers for the PRIMARY checkout above, so a git-dir probe
# reads it healthy, get would reuse it by resetting and detaching the primary,
# and prune would judge the primary's state and rm -rf the slot's files.
repoG="$(make_repo gitless)"
wtG="$("$BIN/ac-tree.sh" get --repo "$repoG" --id g1 2>/dev/null)"
"$BIN/ac-tree.sh" return "$wtG" >/dev/null 2>&1
printf 'files git can no longer report\n' >"$wtG/keep.txt"
rm -f "$wtG/.git"
[ "$(git -C "$wtG" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$repoG" && pwd -P)" ] \
  || fail "fixture: git must answer for the primary from inside the gitless slot"
out="$("$BIN/ac-tree.sh" list --repo "$repoG" 2>/dev/null)"
assert_contains "$out" "1-gitless	broken" "a slot with no .git file lists broken, not available"
outP="$("$BIN/ac-tree.sh" prune --repo "$repoG" 2>&1)" || fail "prune dry run failed: $outP"
assert_contains "$outP" "skip slot 1-gitless: worktree broken" "prune never judges a gitless slot by the primary"
wtG2="$("$BIN/ac-tree.sh" get --repo "$repoG" --id g2 2>/dev/null)"
[ "$wtG2" != "$wtG" ] || fail "get must not reuse a gitless slot"
assert_eq "$(git -C "$repoG" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)" "main" \
  "the primary checkout stays on its branch"
printf 'primary work in progress\n' >>"$repoG/file.txt"
assert_eq "$("$BIN/ac-tree.sh" list --repo "$repoG" 2>/dev/null | awk -F'\t' '$1=="1-gitless"{print $2}')" "broken" \
  "a dirty PRIMARY never reads as the broken slot's own dirt"
outH="$("$BIN/ac-pool-health.sh" --repo "$repoG")"
assert_contains "$outH" "1 broken" "pool health still buckets the gitless slot as broken"
assert_contains "$outH" "$wtG" "...and names it for the reclaim"
"$BIN/ac-tree.sh" return --force "$wtG" >/dev/null 2>&1 \
  && fail "return --force must refuse a gitless slot: its reset would land on the primary"
assert_eq "$(git -C "$repoG" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)" "main" \
  "...and the primary checkout is still on its branch"
assert_contains "$(cat "$repoG/file.txt")" "primary work in progress" "...with its uncommitted work intact"
"$BIN/ac-tree.sh" remove "$wtG" >/dev/null 2>&1 \
  && fail "remove without --force must refuse a gitless slot it cannot check"
assert_file "$wtG/keep.txt" "the gitless slot's files survive"

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
# A ledger nobody can read cannot prove there is no fence, so the lease
# refuses instead of cutting from the default branch, and remove and prune
# refuse instead of judging an epic-landed slot by the default branch alone.
# Skipped under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0; outU="$("$BIN/ac-tree.sh" get --repo "$repoF" --id shadow-s1 --holder t 2>&1)" || rc=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  [ "$rc" != 0 ] || fail "a lease must refuse when the ledger cannot be read, got: $outU"
  assert_contains "$outU" "cannot read the ledger" "the refusal names the unreadable ledger"
  assert_eq "$(sed -n 's/^leased=//p' "$repoF/.crew/slots/1-fence.meta")" "0" "an unreadable ledger leases no slot"

  repoU="$(make_repo unread)"
  sleep 0.1 &
  deadU=$!
  wait "$deadU" 2>/dev/null || true
  wtU="$("$BIN/ac-tree.sh" get --repo "$repoU" --id shadow-s2 --owner "$deadU" 2>/dev/null)"
  git -C "$wtU" commit -q --allow-empty -m "landed on the feature branch only"
  chmod 000 "$AC_HOME/records/backlog.md"
  outU="$("$BIN/ac-tree.sh" remove "$wtU" 2>&1 || true)"
  outP="$("$BIN/ac-tree.sh" prune --repo "$repoU" --yes 2>&1 || true)"
  chmod 644 "$AC_HOME/records/backlog.md"
  assert_contains "$outU" "remove: cannot read the ledger" "remove names the unreadable ledger, not unmerged work"
  assert_contains "$outP" "prune: cannot read the ledger" "prune names the unreadable ledger, not unmerged work"
  [ -d "$wtU" ] || fail "an unreadable ledger must leave the slot in place"
fi

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

# --- differential: src/tree.ts against the frozen bash original ------------
# DISPUTED: the implementation (tests/fixtures/ac-tree.sh under bash vs src/tree.ts through bin/ac-tree.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home (records/ state/ data/), repos at <side>/r* built by the same commands with fixed author/committer dates and one git config (GIT_CONFIG_GLOBAL, no system config) so every sha matches, an optional bare origin beside them; argv and env (the side root spelled @H, substituted in values only); cwd (<side>/cwd, an EMPTY dir, unless a row names a repo); stdin (/dev/null); umask 022 unless a row names 077; LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - date answering one instant per format, od answering one fixed 8 bytes (so one lease_id), sleep logging each call (and returning at once while <side>/sleep.fast exists) - plus a row's own stubs; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT, the entry's pid PID), then the world a row may touch: every path under the side root (git objects aside), each repo's worktree list, every slot meta, the workspace, the exclude, .gitignore, .crew/config and the lock's pid file with their modes, every hook and sidecar's mode and cksum, each slot's HEAD, branch and porcelain, and every crew meta.
xobin="$(make_oracle_bin ac-tree)"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig"
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%d*) echo 2026-01-01T00:00:00Z ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/od" <<'STUB'
#!/bin/sh
[ ! -e "$STUB_DIR/od.fail" ] || exit 1
case "$*" in *urandom*) printf ' 00 11 22 33 44 55 66 77\n' ;; *) exec /usr/bin/od "$@" ;; esac
STUB
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/sleep.log"
[ ! -e "$STUB_DIR/sleep.fast" ] || exit 0
exec /bin/sleep "$@"
STUB
chmod +x "$XSTUBS/date" "$XSTUBS/od" "$XSTUBS/sleep"
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() { rm -rf "$H"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/data" "$H/cwd" "$H/tmp"; }
xrepo() {  # xrepo <name> - a repo with one commit on main
  git init -q -b main "$H/$1"; printf 'hello\n' >"$H/$1/file.txt"; git -C "$H/$1" add -A; git -C "$H/$1" commit -qm init
}
xorigin() {  # xorigin <repo> - a bare origin at <repo>.git, main pushed and fetched
  git init -q --bare -b main "$H/$1.git"; git -C "$H/$1" remote add origin "$H/$1.git"
  git -C "$H/$1" push -q origin main 2>/dev/null; git -C "$H/$1" fetch -q origin
}
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
XLC=C; XENV=(); XHOMELESS=0; XCWD=cwd; XGONE=0; XPRE=""; XPATH=""; XUMASK=022; XNBIN="$BIN"
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v path; shift 3
  path="$XSTUBS:$PATH"; [ -z "$XPRE" ] || path="${XPRE//@H/$h}:$path"; [ -z "$XPATH" ] || path="${XPATH//@H/$h}"
  local a=() e=("LC_ALL=$XLC" "PATH=$path" "STUB_DIR=$h")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h/$XCWD" && { [ "$XGONE" != 1 ] || rmdir "$h/$XCWD"; } && umask "$XUMASK" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_MAX_TREES -u AC_LOCK_STALE_GRACE -u AC_SYNC_TIMEOUT -u EPOCHSECONDS \
    "${e[@]}" /bin/sh -c 'printf %s "$$" >"$0"; exec "$@"' "$TMP/$p.pid" "$bin/ac-tree.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
xnorm() {  # xnorm <file> <side root> <pid> - the pid only between non-hex bytes, never inside a sha nor on a cksum line (a size can equal it)
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-tree#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e "/^   cksum /!s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" -e "/^   cksum /!s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" "$1"
}
printf '%s\n' '   cksum 3236630796 1808' "lock held by pid 1808 at $XOH/tmp/1808.lock" 'sha 0a1808ff' >"$TMP/xnorm.in"
assert_eq "$(xnorm "$TMP/xnorm.in" "$XOH" 1808)" "   cksum 3236630796 1808
lock held by pid PID at @H/tmp/PID.lock
sha 0a1808ff" "xnorm: a cksum size and a sha equal to or holding the pid stay, the pid in a message or path goes"
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$xobin" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$XNBIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "tree differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "tree differential stdout differs for '$*' at line $(xrow): $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_err() {
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "tree differential stderr differs for '$*' at line $(xrow): $(diff "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - what a row may change
  local h="$1" r f w
  (cd "$h" && find . -path '*/.git/objects' -prune -o -path ./tmp -prune -o -name 'sleep.log' -prune -o -print 2>/dev/null | LC_ALL=C sort)
  for r in "$h"/r*; do
    [ -d "$r/.git" ] || continue
    printf '== repo %s\n' "$r"
    git -C "$r" worktree list --porcelain 2>&1 || true
    for f in "$r"/.crew/slots/* "$r"/.crew/*.code-workspace "$r"/.git/info/exclude "$r"/.gitignore "$r"/.crew/config "$r"/.crew/lock/pid; do
      [ -f "$f" ] || continue
      printf '== %s %s\n' "$f" "$(ls -l "$f" | cut -c1-10)"; cat "$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
    done
    for f in "$r"/.git/hooks/pre-commit* "$r"/.git/hooks/commit-msg*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      printf '== hook %s %s\n   cksum %s\n' "$f" "$(ls -ld "$f" | cut -c1-10)" "$(cksum "$f" 2>/dev/null | cut -d' ' -f1-2)"
    done
    for w in "$r"/.crew/worktrees/*; do
      [ -d "$w" ] || continue
      printf '== slot %s\n' "$w"; git -C "$w" status --porcelain=v2 --branch 2>&1 || true
      # The ignored files a slot holds are what WORKTREE INCLUDE copies in -
      # their bytes and modes, not only their names.
      git -C "$w" ls-files -z --others --ignored --exclude-standard 2>/dev/null | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do printf '== include %s %s\n   cksum %s\n' "$f" "$(ls -l "$w/$f" 2>&1 | cut -c1-10)" "$(cksum <"$w/$f" 2>&1 | cut -d' ' -f1-2)"; done || true
    done
  done
  for f in "$h"/home/state/*.meta "$h"/fstate/*.meta; do [ -f "$f" ] || continue; printf '== %s\n' "$f"; cat "$f"; done
}
# An owner pid an earlier row's process left in a meta differs per side; the
# test's own live pid and its known dead one stay spelled.
xowners() { LC_ALL=C sed -E -e "s/^owner_pid=$$\$/owner_pid=LIVE/" ${xdead:+-e "s/^owner_pid=$xdead\$/owner_pid=DEAD/"} -e 's/^owner_pid=[0-9]+$/owner_pid=PID/'; }
xsame_world() {
  xworld "$XOH" | xowners >"$TMP/xo.world"; xworld "$XNH" | xowners >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "tree differential world differs after '$*' at line $(xrow): $(diff "$TMP/xo.world2" "$TMP/xn.world2" | head -n 12)"
}
xsame() { xpair "$@"; xsame_rc_out "$@"; xsame_err "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoerr() { cat "$TMP/xo.err2"; }
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "tree refusal for '$*' at line $(xrow)"
}
xwithout() {  # xwithout <tool> - the leg's PATH with every dir holding <tool> mirrored without it (nolsof_path's shape)
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
  printf '%s:%s\n' "$XSTUBS" "$out"
}
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
xstub() {  # xstub <name> <body> - a stub at <side>/stubs, ahead of the leg's own when XPRE names it
  mkdir -p "$H/stubs"; printf '%s\n' "$2" >"$H/stubs/$1"; chmod +x "$H/stubs/$1"
}
# The pieces of a comparison, for rows that name a divergence between them.
xcheck_io() { xsame_rc_out "$@"; xsame_err "$@"; }
# SHELL-OWN STDERR (named): the original's `<script>: line N: ...` lines -
# unbound variables, failed redirections, test's integer complaints - are
# dropped from its stderr before the compare; the port never prints them.
xcheck_noise() {
  xsame_rc_out "$@"
  grep -q -E ': line [0-9]+: ' "$TMP/xo.err2" || fail "the row at line $(xrow) names shell noise the original did not print: $(xoerr)"
  grep -v -E ': line [0-9]+: ' "$TMP/xo.err2" >"$TMP/xo.err3" || true
  cmp -s "$TMP/xo.err3" "$TMP/xn.err2" || fail "tree differential stderr (shell lines aside) differs for '$*' at line $(xrow): $(diff "$TMP/xo.err3" "$TMP/xn.err2" | head -n 8)"
}
xsame_shellnoise() { xpair "$@"; xcheck_noise "$@"; xsame_world "$@"; }
# FAIL-PATH ARTIFACTS (W7, named): a refusal under the pool lock releases it in
# the port; the original's die left .crew/lock/ holding its dead pid.
xcheck_w7() {  # xcheck_w7 <repo under the side>
  [ -d "$XOH/$1/.crew/lock" ] || fail "W7: the original's die under the lock left .crew/lock behind (line $(xrow))"
  [ ! -e "$XNH/$1/.crew/lock" ] || fail "W7: the port releases the pool lock on a refusal (line $(xrow))"
  rm -rf "$XOH/$1/.crew/lock"
}
xrefuse_w7() {  # xrefuse_w7 <stderr> <repo under the side> <args...> - xrefuse for a refusal under the pool lock
  local want="$1" r="$2"; shift 2
  xpair "$@"; xcheck_io "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "tree refusal for '$*' at line $(xrow)"
  xcheck_w7 "$r"; xsame_world "$@"
}
xsetup() {  # xsetup <args...> - the same step on both sides, run by the ORIGINAL, so a port defect cannot shape a row's world
  local h; for h in "$XOH" "$XNH"; do xrun_side "$xobin" "$h" xs "$@" || fail "setup '$*' failed at line $(xrow): $(cat "$TMP/xs.err")"; done
}
xgitstub() {  # a PATH git counting `status --porcelain`: writes <status.file> before the <status.at>th, fails `worktree add` while wtadd.fail exists
  xstub git "#!/bin/sh
case \" \$* \" in *\" status --porcelain \"*)
  n=\$((\$(cat \"\$STUB_DIR/status.count\" 2>/dev/null || echo 0) + 1)); echo \"\$n\" >\"\$STUB_DIR/status.count\"
  [ \"\$n\" != \"\$(cat \"\$STUB_DIR/status.at\" 2>/dev/null)\" ] || printf 'late\\n' >\"\$(cat \"\$STUB_DIR/status.file\")\" ;;
esac
case \" \$* \" in *\" worktree add \"*) [ ! -e \"\$STUB_DIR/wtadd.fail\" ] || exit 128 ;; esac
exec $(command -v git) \"\$@\""
}
sleep 0.1 &
xdead=$!
wait "$xdead" 2>/dev/null || true

# 1. usage: none, '', -h, LIST and an unknown verb print the header on stdout,
#    exit 2, nothing else. Named divergence (USAGE HEADER): the header is each
#    implementation's own spec - the original's bash header, the port's
#    src/tree.ts header.
xboth xseed
for xv in "" "''" -h LIST bogus; do
  if [ "$xv" = "''" ]; then xpair ""; else
    # shellcheck disable=SC2086
    xpair $xv
  fi
  assert_eq "$XO_RC $XN_RC" "2 2" "1: '$xv' exits 2 on both sides"
  assert_eq "$(xoerr)$(xerr)" "" "1: '$xv' prints nothing on stderr"
  assert_eq "$(cat "$TMP/xo.raw")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-tree.sh" | sed 's/^# \{0,1\}//')" "1: the original prints its bash header"
  assert_eq "$(cat "$TMP/xn.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/tree.ts" | sed 's/^\/\/ \{0,1\}//')" "1: the port prints the src/tree.ts spec header"
  xsame_world "$xv"
done
assert_contains "$(xout)" "ac-tree.sh return <worktree-path | slot-name> [--repo <path>] [--force]" "1: the spec header carries the usage"

# 2. argument refusals per verb, in code order; a value flag given as the last
#    word is bash's own `$2: unbound variable` exit 1 (SHELL-OWN STDERR,
#    named: the port exits 1 saying nothing).
xboth xrepo r
xrefuse "ERROR: get: --repo is required" get
xrefuse "ERROR: get: --repo is required" get --repo ''
xrefuse "ERROR: get: unknown argument --bogus" get --bogus
xrefuse "ERROR: get: unknown argument x" get --id t x --repo @H/r
for xf in --repo --id --holder --owner --prefer; do
  xsame_shellnoise get --repo @H/r "$xf"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::" "2: get $xf with no value - exit 1, nothing said"
  assert_contains "$(xoerr)" '$2: unbound variable' "2: the original's line for a value-less $xf is bash's own"
done
xrefuse "ERROR: not a git repository: @H/nope" get --repo @H/nope
xrefuse "ERROR: not a git repository: @H/cwd" get --repo @H/cwd
xrefuse "ERROR: get: --prefer expects a slot id/number or a pool worktree path" get --repo @H/r --prefer abc
xrefuse "ERROR: get: --prefer expects a slot id/number or a pool worktree path" get --repo @H/r --prefer /
xrefuse "ERROR: get: --prefer expects a slot id/number or a pool worktree path" get --repo @H/r --prefer //
xrefuse "ERROR: get: --prefer expects a slot id/number or a pool worktree path" get --repo @H/r --prefer -1
xrefuse "ERROR: lease: slot name or worktree path required" lease
xrefuse "ERROR: lease: slot name or worktree path required" lease ''
xrefuse "ERROR: lease: unknown argument -x" lease 1-r -x
xrefuse "ERROR: lease: unknown argument --force" lease 1-r --force
xrefuse "ERROR: lease: --repo is required" lease 1-r
xsame_shellnoise lease 1-r --repo; assert_eq "$XN_RC:$(xerr)" "1:" "2: lease --repo with no value"
xsame_shellnoise lease 1-r --repo @H/r --holder; assert_eq "$XN_RC:$(xerr)" "1:" "2: lease --holder with no value"
xrefuse "ERROR: list: --repo is required" list
xrefuse "ERROR: list: unknown argument --yes" list --yes
xrefuse "ERROR: list: unknown argument x" list x --repo @H/r
xsame_shellnoise list --repo; assert_eq "$XN_RC:$(xerr)" "1:" "2: list --repo with no value"
xrefuse "ERROR: return: worktree path or slot name required" return
xrefuse "ERROR: return: worktree path or slot name required" return --force
xrefuse "ERROR: not a git repository: @H/cwd" return --bogus
xrefuse "ERROR: return: no such directory: sub/1-r" return sub/1-r
xrefuse "ERROR: return: no such directory: @H/nope/x" return @H/nope/x
xsame_shellnoise return 1-r --if-lease-id; assert_eq "$XN_RC:$(xerr)" "1:" "2: return --if-lease-id with no value"
xsame_shellnoise return 1-r --repo; assert_eq "$XN_RC:$(xerr)" "1:" "2: return --repo with no value"
xrefuse "ERROR: prune: --repo is required" prune
xrefuse "ERROR: prune: --repo is required" prune --yes
xrefuse "ERROR: prune: unknown argument --force" prune --repo @H/r --force
xsame_shellnoise prune --yes --repo; assert_eq "$XN_RC:$(xerr)" "1:" "2: prune --repo with no value"
xrefuse "ERROR: remove: worktree path required" remove
xrefuse "ERROR: remove: worktree path required" remove --force --include-leased
xrefuse "ERROR: remove: no such directory: --bogus" remove --bogus
xrefuse "ERROR: remove: no such directory: @H/nope" remove @H/nope
xrefuse "ERROR: remove: not a git worktree: @H/cwd" remove @H/cwd
xrefuse "ERROR: remove: not an agent-crew pool worktree: @H/r" remove @H/r
xrefuse "ERROR: return: not a git worktree: @H/cwd" return @H/cwd
xrefuse "ERROR: return: not an agent-crew pool worktree: @H/r" return @H/r
xrefuse "ERROR: return: no such slot 1-r in the pool of @H/r" return 1-r --repo @H/r
xrefuse_w7 "ERROR: lease: no such slot 9-r in the pool of @H/r" r lease 9-r --repo @H/r
xboth rm -rf @H/r/.crew

# 3. resolve_repo: a missing path, a dir that is no repo, a repo with no
#    commits, a linked slot (its MAIN pool), a symlink (git's physical path),
#    a clone nested in a slot.
xboth git init -q -b main @H/empty
xrefuse "ERROR: repository has no commits: @H/empty" get --repo @H/empty
xsame get --repo @H/r --id t1
assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/1-r" "3: the first slot"
xsame get --repo @H/r/.crew/worktrees/1-r --id t2
assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/2-r" "3: a slot path leases another slot of the main pool"
xboth ln -s @H/r @H/rlink
xsame list --repo @H/rlink
assert_contains "$(xout)" "@H/r/.crew/worktrees/1-r" "3: every printed path is git's physical one"
xboth git clone -q @H/r @H/r/.crew/worktrees/1-r/nested
xrefuse "ERROR: refusing to manage a pool inside a pool worktree: @H/r/.crew/worktrees/1-r/nested" get --repo @H/r/.crew/worktrees/1-r/nested
xrefuse "ERROR: refusing to manage a pool inside a pool worktree: @H/r/.crew/worktrees/1-r/nested" list --repo @H/r/.crew/worktrees/1-r/nested/.
xboth rm -rf @H/r @H/rlink @H/empty

# 4. the first get: the exclude (absent, LF-less, NUL-ended, present), the
#    .gitignore migration (tracked, created from scratch, kept untracked,
#    committed), and every guard-hook arm in its WARN order, bytes and modes
#    under umask 022 and 077.
xboth xstub mv '#!/bin/sh
case "$1" in *ac-crew-tmp*) [ ! -e "$STUB_DIR/mv.fail" ] || { echo "mv: the stub refuses" >&2; exit 1; } ;; esac
exec /bin/mv "$@"'
xboth xstub cp '#!/bin/sh
case "$*" in *ac-crew-*) [ ! -e "$STUB_DIR/cp.fail" ] || { echo "cp: the stub refuses" >&2; exit 1; } ;; esac
exec /bin/cp "$@"'
xboth xstub chmod '#!/bin/sh
[ ! -e "$STUB_DIR/chmod.fail" ] || { echo "chmod: the stub refuses" >&2; exit 1; }
exec /bin/chmod "$@"'
XPRE=@H/stubs
xboth xrepo r
xsame get --repo @H/r
assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/1-r" "4: a fresh repo's first lease"
assert_eq "$(xerr)" "WARN: added /.crew/ to @H/r/.git/info/exclude
WARN: installed commit-guard at @H/r/.git/hooks/pre-commit
WARN: installed agent-trailer-guard at @H/r/.git/hooks/commit-msg
WARN: creating worktree slot 1-r" "4: the first lease's WARNs, in order"
xsame get --repo @H/r
assert_eq "$(xerr)" "WARN: creating worktree slot 2-r" "4: our own byte-identical guards are left alone silently"
x4ex() { xrepo r; printf "$1" >"$H/r/.git/info/exclude"; }
for xex in 'vendor' 'vendor\n' 'vendor\0' '/.crew/\n' '/.crew/' '/.crew/\r\n' ''; do
  xboth rm -rf @H/r; xboth x4ex "$xex"
  xsame get --repo @H/r
  assert_eq "$XN_RC" 0 "4: the exclude '$xex'"
done
x4gi() {  # x4gi <tracked .gitignore bytes or -> <working bytes>
  xrepo r
  if [ "$1" != - ]; then printf "$1" >"$H/r/.gitignore"; git -C "$H/r" add .gitignore; git -C "$H/r" commit -qm gi; fi
  printf "$2" >"$H/r/.gitignore"
}
for xgi in 'node_modules\n|node_modules\n/.crew/\n' '-|/.crew/\n' '-|/.crew/\nbuild/\n' '/.crew/\n|/.crew/\n' 'a\n|a\n/.crew/\r\n' '-|/.crew/'; do
  xboth rm -rf @H/r; xboth x4gi "${xgi%%|*}" "${xgi#*|}"
  xsame get --repo @H/r
  assert_eq "$XN_RC" 0 "4: the .gitignore '$xgi'"
done
assert_eq "$(xerr | head -n 2 | tail -n 1)" "WARN: migrated: /.crew/ ignore moved to .git/info/exclude" "4: an unterminated /.crew/ line migrates too"
x4state() {  # x4state <pre-commit state> - shaped in <side>/r's hooks
  local h="$H/r/.git/hooks"
  case "$1" in
    foreign) printf '#!/bin/sh\necho project hook\n' >"$h/pre-commit"; chmod +x "$h/pre-commit" ;;
    stale) printf '#!/bin/sh\n# ac-crew-primary-commit-guard (an older text)\n' >"$h/pre-commit"; chmod 750 "$h/pre-commit" ;;
    stale-bak) x4state stale; : >"$h/pre-commit.ac-crew-stale-1767225600" ;;
    symlink) printf '#!/bin/sh\n' >"$H/managed"; ln -s "$H/managed" "$h/pre-commit" ;;
    prev-taken) x4state foreign; printf '#!/bin/sh\n' >"$h/pre-commit.ac-crew-prev" ;;
    hookspath) git -C "$H/r" config core.hooksPath .githooks ;;
    unreadable) x4state stale; chmod 000 "$h/pre-commit" ;;
  esac
}
x4hook() { xrepo r; x4state "$1"; }   # x4hook <pre-commit state> - a fresh repo so shaped
for xh in foreign stale stale-bak symlink prev-taken hookspath; do
  xboth rm -rf @H/r @H/managed; xboth x4hook "$xh"
  xsame get --repo @H/r
  assert_eq "$XN_RC" 0 "4: a $xh pre-commit never blocks the lease"
  case "$xh" in
    foreign) assert_contains "$(xerr)" "WARN: chained existing pre-commit hook aside to pre-commit.ac-crew-prev" "4: a foreign hook is chained" ;;
    stale) assert_contains "$(xerr)" "WARN: upgraded the outdated commit-guard at @H/r/.git/hooks/pre-commit (previous bytes kept at @H/r/.git/hooks/pre-commit.ac-crew-stale-1767225600)" "4: a stale guard is upgraded" ;;
    stale-bak) assert_contains "$(xerr)" "WARN: could not preserve the outdated commit-guard; leaving it in place (@H/r/.git/hooks/pre-commit)" "4: a taken backup name keeps the stale guard" ;;
    symlink) assert_contains "$(xerr)" "WARN: pre-commit is a symlink (hook-manager managed); skipping commit-guard install to leave it untouched (@H/r/.git/hooks/pre-commit)" "4: a symlink hook is left alone" ;;
    prev-taken) assert_contains "$(xerr)" "WARN: pre-commit present and pre-commit.ac-crew-prev already taken; skipping commit-guard install to avoid clobbering a project hook (@H/r/.git/hooks/pre-commit)" "4: a taken sidecar keeps the project hook" ;;
    hookspath) assert_contains "$(xerr)" "WARN: core.hooksPath is set; skipping commit-guard install (the guards cover only the default shared hooks)" "4: a custom hooksPath skips both guards" ;;
  esac
done
if [ "$(id -u)" != 0 ]; then
  xboth rm -rf @H/r; xboth x4hook unreadable
  xsame get --repo @H/r
  assert_contains "$(xerr)" "WARN: could not preserve existing pre-commit hook; skipping commit-guard install to avoid clobbering it" "4: an unreadable guard reads foreign and cannot be copied aside"
  xboth chmod 644 @H/r/.git/hooks/pre-commit
fi
for xf in chmod cp mv; do
  xboth rm -rf @H/r; xboth x4hook foreign; xboth touch "@H/$xf.fail"
  xsame get --repo @H/r
  case "$xf" in
    chmod) assert_contains "$(xerr)" "WARN: could not stage commit-guard (chmod); leaving any existing hook untouched (@H/r/.git/hooks/pre-commit)" "4: a failed chmod stages nothing" ;;
    cp) assert_contains "$(xerr)" "WARN: could not preserve existing pre-commit hook; skipping commit-guard install to avoid clobbering it (@H/r/.git/hooks/pre-commit)" "4: a failed copy aside keeps the project hook" ;;
    mv) assert_contains "$(xerr)" "WARN: could not install commit-guard (@H/r/.git/hooks/pre-commit)" "4: a failed rename keeps the hook whole" ;;
  esac
  xboth rm -f "@H/$xf.fail"
done
xboth rm -rf @H/r; xboth x4hook stale; xboth touch @H/mv.fail
xsame get --repo @H/r
assert_contains "$(xerr)" "WARN: could not upgrade the outdated commit-guard (@H/r/.git/hooks/pre-commit)" "4: a failed upgrade rename keeps the old guard"
xboth rm -f @H/mv.fail
if [ "$(id -u)" != 0 ]; then
  xboth rm -rf @H/r; xboth xrepo r; xboth chmod 555 @H/r/.git/hooks
  xsame_shellnoise get --repo @H/r
  assert_contains "$(xerr)" "WARN: could not stage commit-guard; leaving any existing hook untouched (@H/r/.git/hooks/pre-commit)" "4: an unwritable hooks dir stages nothing"
  xboth chmod 755 @H/r/.git/hooks
fi
# FAIL-PATH ARTIFACTS (W14, named): with grep off PATH the original read its
# own guard as foreign and chained it onto itself, and appended the exclude
# line again; the port reads both in-process.
xboth rm -rf @H/r; xboth xrepo r; xsetup get --repo @H/r
XPATH="$(xwithout grep)"
xpair get --repo @H/r
XPATH=""
assert_eq "$XO_RC:$XN_RC:$(xout)" "0:0:@H/r/.crew/worktrees/2-r" "4 (W14): both lease without grep"
assert_eq "$(xerr)" "WARN: creating worktree slot 2-r" "4 (W14): the port sees its own guards and the exclude line"
assert_contains "$(xoerr)" "WARN: chained existing pre-commit hook aside to pre-commit.ac-crew-prev" "4 (W14): the original chained its own guard onto itself"
cmp -s "$XOH/r/.git/hooks/pre-commit.ac-crew-prev" "$XOH/r/.git/hooks/pre-commit" || fail "4 (W14): the original's sidecar is its own guard"
assert_eq "$(grep -c '^/.crew/$' "$XOH/r/.git/info/exclude"):$(grep -c '^/.crew/$' "$XNH/r/.git/info/exclude")" "2:1" "4 (W14): the original appended the exclude line again"
XUMASK=077
xboth rm -rf @H/r; xboth xrepo r
xsame get --repo @H/r
assert_eq "$(ls -l "$XNH/r/.git/hooks/pre-commit" | cut -c1-10)" "-rwx------" "4: chmod +x honours the umask (077)"
XUMASK=022
XPRE=""
xboth rm -rf @H/r @H/managed @H/stubs


# 5. selection: reuse in byte order (10-r before 2-r), a dirty slot, a
#    half-written meta, a dead owner reclaimed, a live one kept, the cap from
#    env/config and its bogus spellings, an orphan dir, a failed worktree add,
#    a legacy slot's migration, and every --prefer why.
xboth xrepo r
for xi in a b c; do xsetup get --repo @H/r --id "$xi"; done
for xi in 1 2 3; do xsetup return "@H/r/.crew/worktrees/$xi-r"; done
x5move() { git -C "$H/r" worktree move "$H/r/.crew/worktrees/$1" "$H/r/.crew/worktrees/$2"; mv "$H/r/.crew/slots/$1.meta" "$H/r/.crew/slots/$2.meta"; }
xboth x5move 1-r 10-r
xsame get --repo @H/r --id d
assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/10-r" "5: the first free slot in byte order - 10-r before 2-r"
xboth xput r/.crew/worktrees/2-r/wip.txt 'wip'
xsame get --repo @H/r --id e
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/3-r:WARN: skip slot 2-r: dirty (unlanded work; inspect or remove --force)
WARN: reusing worktree slot 3-r" "5: a dirty slot is skipped"
xsetup return @H/r/.crew/worktrees/3-r
x5half() { grep -v '^leased=' "$H/r/.crew/slots/3-r.meta" >"$H/x" && mv "$H/x" "$H/r/.crew/slots/3-r.meta"; }
xboth x5half
xsame get --repo @H/r --id f
assert_eq "$(xout)" "@H/r/.crew/worktrees/11-r" "5: a half-written meta fails closed, the pool grows past the highest number"
assert_contains "$(xerr)" "WARN: skip slot 3-r: lease state unknown (half-written meta?)" "5: the unknown state is named"
xboth rm -rf @H/r; xboth xrepo r
xsetup get --repo @H/r --id o2 --owner "$$"
xsetup get --repo @H/r --id o1 --owner "$xdead"
XENV=(AC_MAX_TREES=2)
xsame get --repo @H/r --id o3
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/2-r:WARN: reclaiming slot 2-r from dead owner $xdead
WARN: reusing worktree slot 2-r" "5: a dead owner's lease self-heals; a live one is kept"
xpair get --repo @H/r --id o4; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$XN_RC:$(xerr)" "1:ERROR: pool is full (2/2); raise max_trees in .crew/config or prune" "5: the cap from AC_MAX_TREES"
XENV=()
xboth xput r/.crew/config $'max_trees=2\n'
xpair get --repo @H/r --id o4; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$(xerr)" "ERROR: pool is full (2/2); raise max_trees in .crew/config or prune" "5: the cap from .crew/config"
for xcap in abc 0x5 99999999999999999999 1e1 ' '; do
  XENV=("AC_MAX_TREES=$xcap")
  xpair get --repo @H/r --id o4; xcheck_noise; xcheck_w7 r; xsame_world
  assert_eq "$XN_RC:$(xerr)" "1:ERROR: pool is full (2/$xcap); raise max_trees in .crew/config or prune" "5: a bogus cap '$xcap' is full"
done
for xcap in ' 3' '+3' '3 ' '010'; do
  xboth rm -rf @H/r/.crew/worktrees/3-r; xboth rm -f @H/r/.crew/slots/3-r.meta
  XENV=("AC_MAX_TREES=$xcap")
  xsame get --repo @H/r --id o5
  assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/3-r" "5: the cap '$xcap' reads as an integer"
done
XENV=()
xboth rm -rf @H/r/.crew/config
xboth mkdir -p @H/r/.crew/worktrees/4-r/junk
xsame get --repo @H/r --id o6
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/4-r:WARN: cleaning orphan worktree dir at slot 4-r
WARN: creating worktree slot 4-r" "5: an orphan dir is cleaned and its number reused"
xboth xgitstub; XPRE=@H/stubs; xboth touch @H/wtadd.fail
xpair get --repo @H/r --id o7; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$XN_RC:$(xerr)" "1:WARN: creating worktree slot 5-r
ERROR: git worktree add failed for slot 5-r" "5: a failed worktree add drops the slot and dies"
xboth rm -f @H/wtadd.fail; XPRE=""
# An owner this user may not signal (pid 1) answers `kill -0` with a failure,
# so the lease reads as dead and is reclaimed.
if [ "$(id -u)" != 0 ]; then
  xsetup get --repo @H/r --id o8 --owner 1
  XENV=(AC_MAX_TREES=5); xsame get --repo @H/r --id o9; XENV=()
  assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/5-r:WARN: reclaiming slot 5-r from dead owner 1
WARN: reusing worktree slot 5-r" "5: an owner kill -0 cannot signal reads as dead"
fi
xboth rm -rf @H/r; xboth xrepo r
xsetup get --repo @H/r --id g1; xsetup return @H/r/.crew/worktrees/1-r
xboth x5move 1-r 1
xsame get --repo @H/r --id g2
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/1-r:WARN: migrated slot 1 -> 1-r
WARN: reusing worktree slot 1-r" "5: a legacy bare-number slot takes its <n>-<repo> name on reuse"
xboth rm -rf @H/r; xboth xrepo r
for xi in p1 p2 p3 p4; do xsetup get --repo @H/r --id "$xi"; done
for xi in 1 2 3 4; do xsetup return "@H/r/.crew/worktrees/$xi-r"; done
xsame get --repo @H/r --id q1 --prefer 2/
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/2-r:WARN: reusing worktree slot 2-r" "5: an available preferred slot, by number (a trailing / dropped)"
xsame get --repo @H/r --id q2 --prefer 2
assert_eq "$(xout):$(xerr)" "@H/r/.crew/worktrees/1-r:WARN: reusing worktree slot 1-r
WARN: prefer: slot 2-r unavailable (leased by task q1) - leased slot 1-r instead" "5: a leased preferred slot"
xsame get --repo @H/r --id q3 --prefer 9
assert_contains "$(xerr)" "WARN: prefer: slot 9 unavailable (no such slot) - leased slot 3-r instead" "5: a missing preferred slot"
xsame get --repo @H/r --id q4 --prefer 1x-y
assert_contains "$(xerr)" "WARN: prefer: slot 1x-y unavailable (no such slot) - leased slot 4-r instead" "5 (W18): 1x-y passes as an id"
xsetup return @H/r/.crew/worktrees/4-r
xboth xput r/.crew/worktrees/4-r/wip.txt 'wip'
xsame get --repo @H/r --id q5 --prefer @H/r/.crew/worktrees/4-r/
assert_contains "$(xerr)" "WARN: prefer: slot 4-r unavailable (dirty (unlanded work)) - leased slot 5-r instead" "5: a dirty preferred slot, by path"
xsame get --repo @H/r --id q6 --prefer ''
assert_eq "$(xout)" "@H/r/.crew/worktrees/6-r" "5 (W18): --prefer '' is ignored"
xsetup return @H/r/.crew/worktrees/6-r
x5unknown() { grep -v '^leased=' "$H/r/.crew/slots/6-r.meta" >"$H/x" && mv "$H/x" "$H/r/.crew/slots/6-r.meta"; }
xboth x5unknown
xsame get --repo @H/r --id q7 --prefer 6-r
assert_contains "$(xerr)" "WARN: prefer: slot 6-r unavailable (lease state unknown (half-written meta?)) - leased slot 7-r instead" "5: an unknown preferred slot"
xsetup return @H/r/.crew/worktrees/7-r
xboth rm -rf @H/r/.git/worktrees/7-r
xsame get --repo @H/r --id q8 --prefer 7
assert_contains "$(xerr)" "WARN: prefer: slot 7-r unavailable (reset failed) - leased slot 8-r instead" "5: a broken preferred slot cannot reset"
assert_contains "$(xerr)" "WARN: skip slot 7-r: reset failed" "5: nor can the loop reset it"
xboth rm -rf @H/r; xboth xrepo r
xsetup get --repo @H/r --id c1; xsetup return @H/r/.crew/worktrees/1-r
xboth xgitstub; XPRE=@H/stubs
xboth xput status.at 3; xboth xput status.file @H/r/.crew/worktrees/1-r/late.txt
xsame get --repo @H/r --id c2 --prefer 1
assert_contains "$(xerr)" "WARN: skip slot 1-r: dirty (unlanded work; inspect or remove --force)
WARN: creating worktree slot 2-r
WARN: prefer: slot 1-r unavailable (changed under the check (a process still alive in the slot?)) - leased slot 2-r instead" "5: a preferred slot that moves under the check is not reset"
assert_eq "$(cat "$XNH/r/.crew/worktrees/1-r/late.txt")" "late" "5: the write that landed under the check survives"
xboth rm -rf @H/r; xboth xrepo r
xsetup get --repo @H/r --id c3; xsetup return @H/r/.crew/worktrees/1-r
xboth rm -f @H/status.count; xboth xput status.at 3
xsame get --repo @H/r --id c4
assert_contains "$(xerr)" "WARN: skip slot 1-r: changed under the check (a process still alive in the slot?)" "5: the loop does not reset a slot that moves under the check"
XPRE=""; xboth rm -rf @H/stubs @H/status.count @H/status.at @H/status.file @H/r

# 6. the epic/feature fence: the origin, local and push=deferred arms, hit and
#    missed, a same-named tag, the id-prefix walk, an unreadable ledger, and
#    the homeless leases (W1, fixed: a crewmate pane's
#    AC_FLEET_STATE names the home the fence reads; with no home at all, the
#    home's refusal printed and the fence OFF).
x6() {
  xrepo rf; xorigin rf; xrepo rl
  git -C "$H/rf" checkout -qb epic/ep1; git -C "$H/rf" commit -q --allow-empty -m 'on epic ep1'
  git -C "$H/rf" push -q origin epic/ep1 2>/dev/null; git -C "$H/rf" checkout -q main
  git -C "$H/rl" checkout -qb epic/ep1; git -C "$H/rl" commit -q --allow-empty -m 'on epic ep1 locally'
  git -C "$H/rl" checkout -qb feat/ft1; git -C "$H/rl" commit -q --allow-empty -m 'on feature ft1'
  git -C "$H/rl" checkout -q main; git -C "$H/rl" branch -q feat/shadow
  git -C "$H/rl" tag feat/shadow "$(printf 'x' | git -C "$H/rl" hash-object -w --stdin)"
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] ep1-s1 - story; epic:ep1\n- [ ] ft1-s1 - story; feature:ft1\n- [ ] ep2-s1 - story; epic:ep2\n- [ ] sh-s1 - story; feature:sh\n'
  xput home/data/ep1/branches $'rf epic/ep1\nrl epic/ep1\n'
  xput home/data/ft1/branches $'rl feat/ft1 target=main push=deferred\nrf feat/ft1 push=deferred\n'
  xput home/data/ep2/branches $'rf epic/missing\nrl epic/missing\n'
  xput home/data/sh/branches $'rl feat/shadow push=deferred\n'
}
xboth x6
xsame get --repo @H/rf --id ep1-s1
assert_eq "$XN_RC:$(git -C "$XNH/rf/.crew/worktrees/1-rf" log -1 --format=%s)" "0:on epic ep1" "6: the origin arm cuts the slot from origin/<branch>"
xsame get --repo @H/rl --id ep1-s1-verify-codereview
assert_eq "$XN_RC:$(git -C "$XNH/rl/.crew/worktrees/1-rl" log -1 --format=%s)" "0:on epic ep1 locally" "6: no origin - the local branch, found by the id-prefix walk"
xsame get --repo @H/rl --id ft1-s1
assert_eq "$XN_RC:$(git -C "$XNH/rl/.crew/worktrees/2-rl" log -1 --format=%s)" "0:on feature ft1" "6: push=deferred - the local feature branch"
xrefuse "ERROR: get: epic branch epic/missing is not on origin of rf - cut it first: ac-epic-branch.sh create <epic> rf" get --repo @H/rf --id ep2-s1
xrefuse "ERROR: get: epic branch epic/missing does not exist in rl - cut it first: ac-epic-branch.sh create <epic> rl" get --repo @H/rl --id ep2-s1
xrefuse "ERROR: get: feature branch feat/ft1 does not exist in rf - cut it first: ac-feature.sh create <feature> rf" get --repo @H/rf --id ft1-s1
xrefuse "error: feat/shadow^{commit}: expected commit type, but the object dereferences to blob type
ERROR: get: base ref feat/shadow (named by the integration-branch record for sh-s1 on rl) does not resolve to a commit - nothing was leased; fix the ref before retrying" get --repo @H/rl --id sh-s1
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  # Named divergence: the fence reads the ledger in-process, so awk's own
  # `can't open file` pair the original's parser printed before its refusal
  # is not reproduced.
  xpair get --repo @H/rl --id ep1-s1; xsame_rc_out; xsame_world
  assert_eq "$(xoerr | sed 's/^ source line number [0-9]*$/ source line number N/')" "awk: can't open file @H/home/records/backlog.md
 source line number N
ERROR: get: cannot read the ledger to resolve the epic-branch fence for ep1-s1" "6: the original's unreadable-ledger lines"
  assert_eq "$XN_RC:$(xerr)" "1:ERROR: get: cannot read the ledger to resolve the epic-branch fence for ep1-s1" "6: an unreadable ledger refuses the lease"
  xboth chmod 644 @H/home/records/backlog.md
fi
XHOMELESS=1
xsame get --repo @H/rl --id ep2-s1
assert_eq "$XN_RC:$(xerr)" "0:$XNOHOME
WARN: creating worktree slot 3-rl" "6 (W1): homeless, the fence is OFF and the home's refusal is its only sign"
assert_eq "$(git -C "$XNH/rl/.crew/worktrees/3-rl" log -1 --format=%s)" "init" "6 (W1): the homeless slot is cut from the default base"
XENV=(AC_FLEET_STATE=@H/home/state)
xrefuse "ERROR: get: epic branch epic/missing does not exist in rl - cut it first: ac-epic-branch.sh create <epic> rl" get --repo @H/rl --id ep2-s1
xsame get --repo @H/rl --id ep1-s1-verify-codereview
assert_eq "$XN_RC:$(xerr)" "0:WARN: creating worktree slot 4-rl" "6 (W1): a crewmate pane's AC_FLEET_STATE names the home - the fence holds, no refusal printed"
assert_eq "$(git -C "$XNH/rl/.crew/worktrees/4-rl" log -1 --format=%s)" "on epic ep1 locally" "6 (W1): the pane's lease is cut from the epic branch"
XENV=(AC_HOME=@H/missing)
xpair get --repo @H/rl --id ep1-s1; xsame_rc_out; xsame_world
# HOME RESOLUTION (named): the original's lines are cd's own, once for the
# fence's records dir and once for the crew-meta state dir; the port names the
# variable on the same two lines.
assert_eq "$(xoerr | sed 's/^.*: cd: @H\/missing: No such file or directory$/CD/')" "$(xerr | sed 's/^ERROR: AC_HOME is not a readable directory: @H\/missing$/CD/')" "6: an unenterable home - the port names the variable where cd spoke"
assert_eq "$(xerr | grep -c 'AC_HOME is not a readable directory')" "2" "6: twice, as the original's cd"
XENV=(); XHOMELESS=0
# Named divergence: the original read the ledger through the bun backlog
# parser, so with bun off PATH its fence answered rc 2 (`cannot read the
# ledger`) after the exclude, the hooks and the fetch; the port needs bun to
# start at all and refuses before touching anything.
xboth xrepo rb
XPATH="$(xwithout bun)"
xpair get --repo @H/rb --id ep1-s1
XPATH=""
assert_eq "$XO_RC:$XN_RC" "1:1" "6: with bun off PATH both sides refuse"
assert_eq "$(xerr)" "ERROR: required tool not found: bun" "6: the port's refusal is the shim's"
assert_contains "$(xoerr)" "ERROR: get: cannot read the ledger to resolve the epic-branch fence for ep1-s1" "6: the original's was its fence's rc 2"
[ -f "$XOH/rb/.git/hooks/pre-commit" ] && [ ! -e "$XNH/rb/.crew" ] || fail "6: the original installed the hooks before refusing, the port touched nothing"
xboth rm -rf @H/rf @H/rf.git @H/rl @H/rb @H/home/data @H/home/records/backlog.md

# 7. WORKTREE INCLUDE: every refusal and skip, a dir and files copied (one in
#    a subdir), a `#` comment cut, blanks trimmed, a CRLF line, a NBSP (kept
#    under C, trimmed under UTF-8), and a copy that fails.
x7() {
  xrepo r
  printf '.env\ncache\nlink\n*.env\n.crew/\n' >"$H/r/.gitignore"
  printf '# runtime files every slot needs\n.env\ncache/\nlink\n../x\n/abs\n..\na/..\na/../b\n.crew\n.crew/x\nfile.txt\nabsent.env\n\n   \n  spaced.env  # trailing comment\ncrlf.env\r\n\302\240nb.env\ndir/sub/deep.env\n' >"$H/r/.worktreeinclude"
  git -C "$H/r" add -A; git -C "$H/r" commit -qm manifest
  printf 'SECRET=1\n' >"$H/r/.env"; mkdir -p "$H/r/cache"; printf 'blob\n' >"$H/r/cache/data"
  ln -s /etc/hosts "$H/r/link"; printf 's\n' >"$H/r/spaced.env"; printf 'c\n' >"$H/r/crlf.env"; printf 'n\n' >"$H/r/nb.env"
  mkdir -p "$H/r/dir/sub"; printf 'd\n' >"$H/r/dir/sub/deep.env"
}
xboth x7
for xlc in C en_US.UTF-8; do
  XLC="$xlc"
  xsame get --repo @H/r --id i1
  assert_eq "$XN_RC" 0 "7: the seeded slot leases ($xlc)"
  for xf in .env cache/data spaced.env crlf.env dir/sub/deep.env; do assert_file "$XNH/r/.crew/worktrees/1-r/$xf" "7: '$xf' is seeded ($xlc)"; done
  if [ "$xlc" = C ]; then
    assert_contains "$(xerr)" "WARN: worktreeinclude: skipping '"$'\302\240'"nb.env' (absent from the primary checkout)" "7: a NBSP is no [:space:] under C"
  else
    assert_file "$XNH/r/.crew/worktrees/1-r/nb.env" "7: a NBSP is [:space:] under UTF-8, trimmed"
  fi
  xsetup return @H/r/.crew/worktrees/1-r
  for xf in .env cache nb.env spaced.env crlf.env dir; do xboth rm -rf "@H/r/.crew/worktrees/1-r/$xf"; done
done
XLC=C
assert_contains "$(xerr)" "WARN: worktreeinclude: refusing '../x' (a relative path inside the repo, outside .crew)" "7: an escaping entry"
assert_contains "$(xerr)" "WARN: worktreeinclude: refusing 'link' (a symlink is never followed)" "7: a symlink entry"
assert_contains "$(xerr)" "WARN: worktreeinclude: skipping 'absent.env' (absent from the primary checkout)" "7: an absent entry"
assert_contains "$(xerr)" "WARN: worktreeinclude: skipping 'file.txt' (not ignored - it is project content, already in the tree)" "7: a tracked entry"
x7file() { printf 'not a dir\n' >"$H/r/.crew/worktrees/1-r/cache"; }
xboth x7file
xsame get --repo @H/r --id i2
assert_contains "$(xerr)" "WARN: worktreeinclude: copy of 'cache' failed" "7: a copy that cannot land is named, and the lease stands"
assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/1-r" "7: the failed copy does not fail the lease"
xboth rm -rf @H/r

# 8. the crew-meta append: no id, no meta, a meta (leases= and lease_ids=
#    aligned), an orca-shaped first lease with no id, AC_FLEET_STATE over
#    AC_HOME, a verifier id (never a mint), and od failing (the pid-epoch id).
xboth xrepo r
xboth xput home/state/other.meta $'kind=ship\n'
xsame get --repo @H/r
xsame get --repo @H/r --id t8
assert_no_file "$XNH/home/state/t8.meta" "8: a first lease mints no crew meta"
xboth xput home/state/t8.meta $'kind=ship\nworktree=@H/r/.crew/worktrees/2-r\nleases=@H/r/.crew/worktrees/2-r\nlease_ids=0011223344556677\n'
xsame get --repo @H/r --id t8
assert_eq "$(sed -n 's/^leases=//p' "$XNH/home/state/t8.meta")" "$XNH/r/.crew/worktrees/2-r:$XNH/r/.crew/worktrees/3-r" "8: a second lease is appended to leases="
assert_eq "$(sed -n 's/^lease_ids=//p' "$XNH/home/state/t8.meta")" "0011223344556677:0011223344556677" "8: lease_ids stays aligned"
xboth xput home/state/o8.meta $'kind=ship\nleases=/orca/wt\n'
xsame get --repo @H/r --id o8
assert_eq "$(sed -n 's/^lease_ids=//p' "$XNH/home/state/o8.meta")" ":0011223344556677" "8: after an orca first lease with no id, the separator follows leases="
xboth xput fstate/t8.meta $'kind=ship\nleases=/x\nlease_ids=a\n'
XENV=(AC_FLEET_STATE=@H/fstate)
xsame get --repo @H/r --id t8
assert_eq "$(sed -n 's/^leases=//p' "$XNH/fstate/t8.meta")" "/x:$XNH/r/.crew/worktrees/5-r" "8: AC_FLEET_STATE is the crew meta's dir, over AC_HOME"
XENV=()
xsame get --repo @H/r --id t8-verify-codereview
assert_no_file "$XNH/home/state/t8-verify-codereview.meta" "8: a verifier id never mints a meta"
xboth xput home/state/n8.meta $'kind=ship\n'
xsame get --repo @H/r --id n8
assert_eq "$(sed -n 's/^leases=//p;s/^lease_ids=//p' "$XNH/home/state/n8.meta" | tr '\n' '|')" "$XNH/r/.crew/worktrees/7-r|0011223344556677|" "8: a meta with no leases= yet takes the first path and id with no separator"
xboth touch @H/od.fail
xsame get --repo @H/r --id t8
assert_eq "$(sed -n 's/^lease_id=//p' "$XNH/r/.crew/slots/8-r.meta")" "$(cat "$TMP/xn.pid")-1767225600" "8: od failing, the lease id is <pid>-<epoch>"
xboth rm -f @H/od.fail
# Named divergence (bytes): argv reaches the port decoded, so a byte that is
# not UTF-8 in --id is written as U+FFFD where the original kept the byte.
XENV=(AC_MAX_TREES=9); xpair get --repo @H/r --id $'caf\351'; xsame_rc_out; XENV=()
assert_eq "$(sed -n 's/^task=//p' "$XOH/r/.crew/slots/9-r.meta" | od -An -tx1 | tr -d ' \n')" "636166e90a" "8: the original records the byte"
assert_eq "$(sed -n 's/^task=//p' "$XNH/r/.crew/slots/9-r.meta" | od -An -tx1 | tr -d ' \n')" "636166efbfbd0a" "8: the port records U+FFFD"
xboth rm -rf @H/r @H/fstate @H/home/state

# 9. lease: state only (a branch checkout and wip survive), the path form, a
#    live holder refused by name, a dead owner reclaimed, an unknown state,
#    the crew-meta append, and the lock released on every refusal (W7).
xboth mkdir -p @H/home/state; xboth xrepo r
xsetup get --repo @H/r --id e1; xsetup get --repo @H/r --id e2; xsetup return @H/r/.crew/worktrees/1-r
x9park() { local w="$H/r/.crew/worktrees/1-r"; git -C "$w" checkout -qb crew/park; printf 'parked\n' >"$w/parked.txt"; git -C "$w" add -A; git -C "$w" commit -qm parked; printf 'wip\n' >"$w/wip.txt"; }
xboth x9park
xsame lease 1-r --repo @H/r --id park --holder self:park
assert_eq "$XN_RC:$(xout):$(xerr)" "0:@H/r/.crew/worktrees/1-r:WARN: worktree slot 1-r leased to park (state only, tree untouched)" "9: a state-only lease"
assert_eq "$(git -C "$XNH/r/.crew/worktrees/1-r" symbolic-ref -q --short HEAD):$(cat "$XNH/r/.crew/worktrees/1-r/wip.txt")" "crew/park:wip" "9: the tree is untouched"
xrefuse_w7 "ERROR: lease: slot 2-r is leased by task e2 (holder cli) - refusing" r lease @H/r/.crew/worktrees/2-r/ --repo @H/r --id other
xrefuse_w7 "ERROR: lease: slot 1-r is leased by task park (holder self:park) - refusing" r lease 1-r --repo @H/r
xsetup get --repo @H/r --id e3 --owner "$xdead"
xboth xput home/state/e9.meta $'kind=ship\nleases=@H/x\nlease_ids=x\n'
xsame lease 3-r --repo @H/r --id e9
assert_eq "$(xerr)" "WARN: reclaiming slot 3-r from dead owner $xdead
WARN: worktree slot 3-r leased to e9 (state only, tree untouched)" "9: a dead owner's slot is reclaimed by lease"
assert_eq "$(sed -n 's/^leases=//p' "$XNH/home/state/e9.meta")" "$XNH/x:$XNH/r/.crew/worktrees/3-r" "9: a lease is appended to the task's crew meta"
xboth rm -rf @H/r/.crew/worktrees/2-r
xsame return @H/r/.crew/worktrees/3-r
case "$(cat "$XNH/r/.crew/r.code-workspace")" in *worktrees/2-r*) fail "9: a leased slot whose dir is gone stays out of the workspace" ;; esac
x9half() { grep -v '^leased=' "$H/r/.crew/slots/3-r.meta" >"$H/x" && mv "$H/x" "$H/r/.crew/slots/3-r.meta"; }
xboth x9half
xrefuse_w7 "ERROR: lease: slot 3-r lease state unknown (half-written meta?) - refusing" r lease 3-r --repo @H/r
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/r/.crew/slots/2-r.meta
  xrefuse_w7 "WARN: cannot read meta file @H/r/.crew/slots/2-r.meta
ERROR: lease: slot 2-r lease state unknown (half-written meta?) - refusing" r lease 2-r --repo @H/r
  xboth chmod 644 @H/r/.crew/slots/2-r.meta
fi
xboth rm -rf @H/r @H/home/state

# 10. list: an empty pool (.crew minted), every state - leased, leased dirty,
#     available, available dirty, broken, a durable lease, `'-'` for no task
#     (W12) - a leased slot whose .git file is gone over a dirty primary (W10),
#     an unreadable meta (W5, named: the original lists it available, the
#     port leased; one WARN per read), and a vanished dir healed.
xboth mkdir -p @H/home/state; xboth xrepo r
xsame list --repo @H/r
assert_eq "$XN_RC:$(xout):$(xerr)" "0::WARN: no worktrees in pool" "10: an empty pool"
assert_eq "$(ls -A "$XNH/r/.crew")" "" "10: list mints .crew/ and leaves no lock"
for xi in l1 l2 l3 l4 l5; do xsetup get --repo @H/r --id "$xi" --owner "$$"; done
xsetup get --repo @H/r
xsetup return @H/r/.crew/worktrees/3-r; xsetup return @H/r/.crew/worktrees/4-r; xsetup return @H/r/.crew/worktrees/5-r
xsetup lease 5-r --repo @H/r --id park
x10() {
  printf 'x\n' >"$H/r/.crew/worktrees/2-r/wip.txt"; printf 'x\n' >"$H/r/.crew/worktrees/4-r/wip.txt"
  rm -rf "$H/r/.git/worktrees/3-r"
}
xboth x10
xsame list --repo @H/r
assert_eq "$(xout)" "1-r	leased	l1	@H/r/.crew/worktrees/1-r	2026-01-01T00:00:00Z	$$
2-r	leased dirty	l2	@H/r/.crew/worktrees/2-r	2026-01-01T00:00:00Z	$$
3-r	broken	l3	@H/r/.crew/worktrees/3-r		
4-r	available dirty	l4	@H/r/.crew/worktrees/4-r		
5-r	leased	park	@H/r/.crew/worktrees/5-r	2026-01-01T00:00:00Z	
6-r	leased	'-'	@H/r/.crew/worktrees/6-r	2026-01-01T00:00:00Z	" "10: every state on the wire"
assert_eq "$(xerr)" "WARN: slot 3-r: worktree broken (gitdir unreadable) - NOT healed, its files may be unlanded work git can no longer report; reclaim it deliberately with: bin/ac-tree.sh remove --force @H/r/.crew/worktrees/3-r" "10: heal names the broken slot"
xboth rm -f @H/r/.crew/worktrees/1-r/.git; xboth xput r/file.txt 'primary edit'
xsame list --repo @H/r
assert_contains "$(xout)" "1-r	leased dirty	l1" "10 (W10): a leased slot with no .git file lists leased, with the PRIMARY's dirt"
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/r/.crew/slots/4-r.meta
  xpair list --repo @H/r; xsame_err list; xsame_world list
  assert_eq "$XO_RC:$XN_RC" "0:0" "10 (W5): list exits 0 over an unreadable meta"
  assert_contains "$(cat "$TMP/xo.out")" "4-r	available dirty	'-'	@H/r/.crew/worktrees/4-r		" "10 (W5): the original lists an unreadable meta available"
  assert_contains "$(xout)" "4-r	leased dirty	'-'	@H/r/.crew/worktrees/4-r		" "10 (W5, named): the port lists it leased, no leased_at, no owner"
  assert_eq "$(grep -v '^4-r	' "$TMP/xn.out")" "$(grep -v '^4-r	' "$TMP/xo.out")" "10 (W5): every other row alike"
  assert_eq "$(xerr | grep -c 'cannot read meta file @H/r/.crew/slots/4-r.meta')" "2" "10 (W5): one WARN per read"
  xboth chmod 644 @H/r/.crew/slots/4-r.meta
fi
xboth rm -rf @H/r/.crew/worktrees/6-r
xsame list --repo @H/r
assert_contains "$(xerr)" "WARN: healed slot 6-r (worktree dir vanished)" "10: a vanished dir is healed"
xboth rm -rf @H/r @H/home/state

# 11. return: every refusal, dirty and --force, the lease id (match, mismatch,
#     none, a second return), by name through --repo and the cwd, relative and
#     symlinked paths, an AVAILABLE slot returned again, a broken slot (reset
#     failed, the lease now owned by a pid that died), a live stranger in the
#     tree (TERM, the real 2s grace), ps failing, lsof absent, a write landing
#     under the check, and a slots/ dir the claim cannot write.
xboth mkdir -p @H/home/state; xboth xrepo r
for xi in r1 r2 r3 r4; do xsetup get --repo @H/r --id "$xi"; done
xboth mkdir -p @H/r/.crew/worktrees/9-r
xrefuse "ERROR: return: unmanaged slot: @H/r/.crew/worktrees/9-r" return @H/r/.crew/worktrees/9-r
xboth xput r/.crew/worktrees/1-r/wip.txt 'wip'
xpair return @H/r/.crew/worktrees/1-r; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$XN_RC:$(xerr)" "1:ERROR: return: worktree is dirty; land the work or pass --force to discard: @H/r/.crew/worktrees/1-r" "11: a dirty slot refuses"
xsame return @H/r/.crew/worktrees/1-r --force
assert_eq "$XN_RC:$(xout):$(xerr)" "0::WARN: worktree slot 1-r returned to pool" "11: --force discards and releases"
xsame return @H/r/.crew/worktrees/1-r
assert_eq "$XN_RC" 0 "11: an available slot returned again is reset and succeeds"
xpair return 2-r --repo @H/r --if-lease-id nope; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$(xerr)" "ERROR: return: slot 2-r holds lease 0011223344556677, not nope - refusing (the slot was re-leased; nothing was reset)" "11: a lease-id mismatch refuses"
xsame return 2-r --repo @H/r --if-lease-id 0011223344556677
assert_eq "$XN_RC" 0 "11: the matching lease id returns by name"
xpair return 2-r --repo @H/r --if-lease-id 0011223344556677; xcheck_io; xcheck_w7 r; xsame_world
assert_eq "$(xerr)" "ERROR: return: slot 2-r holds lease none, not 0011223344556677 - refusing (the slot was re-leased; nothing was reset)" "11: a second return with the same id refuses"
XCWD=r
xsame return 3-r
assert_eq "$XN_RC" 0 "11: by name, in the pool of the cwd's repo"
xsame return .crew/worktrees/4-r
assert_eq "$XN_RC" 0 "11: a relative path"
XCWD=cwd
# Named divergence: the caller's cwd reaches the port physical, so a refusal
# naming it spells the physical path where the original spelled $PWD; and a
# cwd with no name resolves no relative path (the original named its stale
# $PWD, the port names nothing), while `--repo .` refuses alike.
xboth ln -s @H/cwd @H/cwdlink
XCWD=cwdlink
xpair return 1-r; xsame_rc_out; xsame_world
assert_eq "$XN_RC:$(xoerr):$(xerr)" "1:ERROR: not a git repository: @H/cwdlink:ERROR: not a git repository: @H/cwd" "11: a symlinked cwd, logical in the original, physical in the port"
XCWD=gone; XGONE=1
xboth mkdir -p @H/gone
xpair return 1-r; xsame_rc_out; xsame_world
assert_eq "$XN_RC:$(xoerr | tail -n 1):$(xerr | tail -n 1)" "1:ERROR: not a git repository: @H/gone:ERROR: not a git repository: " "11: a cwd with no name"
# The port runs from a decoy root here: a cwd with no name leaves the module
# in the root it was started from, so a relative path that resolved there
# would lease in the decoy's pool, never in this checkout's.
xdecoy="$TMP/decoy-ac-tree"; mkdir -p "$xdecoy/bin"; cp "$BIN"/*.sh "$xdecoy/bin/"
ln -s "$ROOT/src" "$xdecoy/src"; ln -s "$ROOT/dashboard" "$xdecoy/dashboard"
git init -q -b main "$xdecoy"; git -C "$xdecoy" commit -q --allow-empty -m decoy
xboth mkdir -p @H/gone
XNBIN="$xdecoy/bin"; xsame get --repo .; XNBIN="$BIN"
assert_eq "$XN_RC:$(xerr | tail -n 1)" "1:ERROR: not a git repository: ." "11: a relative --repo from a cwd with no name resolves nothing, on both sides"
assert_no_file "$xdecoy/.crew" "11: ...not even in the root the port was started from"
XCWD=cwd; XGONE=0
xboth rm -f @H/cwdlink
xsame return 3-r --repo @H/r/.crew/worktrees/2-r
assert_eq "$XN_RC:$(xerr)" "0:WARN: worktree slot 3-r returned to pool" "11: a --repo naming a slot resolves to its main pool"
xboth ln -s @H/r @H/rlink
xsetup get --repo @H/r --id r5
xsame return @H/rlink/.crew/worktrees/1-r
assert_eq "$(xerr)" "WARN: worktree slot 1-r returned to pool" "11: a symlinked path resolves to the physical slot"
xboth rm -rf @H/r/.git/worktrees/3-r
xrefuse "ERROR: return: not a git worktree: @H/r/.crew/worktrees/3-r" return @H/r/.crew/worktrees/3-r --force
xboth rm -f @H/r/.crew/worktrees/4-r/.git
xpair return @H/r/.crew/worktrees/4-r --force; xcheck_io; xsame_world
assert_eq "$XN_RC:$(xerr)" "1:ERROR: return: reset failed for @H/r/.crew/worktrees/4-r" "11: a slot whose .git file is gone cannot be reset"
assert_eq "$(sed -n 's/^owner_pid=//p' "$XNH/r/.crew/slots/4-r.meta")" "$(cat "$TMP/xn.pid")" "11: its lease is left owned by the returner, a pid that died"
xboth rm -rf @H/r @H/rlink; xboth xrepo r
for xi in s1 s2 s3 s4; do xsetup get --repo @H/r --id "$xi"; done
if command -v lsof >/dev/null 2>&1; then
  x11stranger() { (cd "$H/r/.crew/worktrees/1-r" && exec sleep 30) >/dev/null 2>&1 & printf '%s\n' "$!" >"$H/stranger.pid"; disown; }
  xboth x11stranger
  sleep 0.5
  xsame return @H/r/.crew/worktrees/1-r --force
  assert_eq "$(xerr)" "WARN: terminating processes still inside @H/r/.crew/worktrees/1-r
WARN: worktree slot 1-r returned to pool" "11: a stranger in the tree is terminated"
  for xh in "$XOH" "$XNH"; do
    kill -0 "$(cat "$xh/stranger.pid")" 2>/dev/null && { kill "$(cat "$xh/stranger.pid")"; fail "11: the stranger must be gone ($xh)"; }
  done
  xboth xstub ps '#!/bin/sh
exit 1'
  XPRE=@H/stubs
  xsame return @H/r/.crew/worktrees/2-r --force
  assert_eq "$(xerr)" "WARN: could not walk the caller's ancestry (ps) - protecting only this process from the kill
WARN: worktree slot 2-r returned to pool" "11: ps failing protects only the returner"
  XPRE=""; xboth rm -rf @H/stubs
fi
XPATH="$(nolsof_path)"; XPATH="$XSTUBS:$XPATH"
xsame return @H/r/.crew/worktrees/3-r --force
XPATH=""
assert_eq "$(xerr)" "WARN: cannot enumerate processes inside @H/r/.crew/worktrees/3-r (lsof unavailable) - none killed
WARN: worktree slot 3-r returned to pool" "11: without lsof nothing is killed, and that is said"
xboth xgitstub; XPRE=@H/stubs
xboth xput status.at 3; xboth xput status.file @H/r/.crew/worktrees/4-r/late.txt
xsame return @H/r/.crew/worktrees/4-r
assert_eq "$XN_RC:$(xerr)" "1:ERROR: return: worktree changed after it was verified clean, so nothing was reset - inspect it, then return --force to discard: @H/r/.crew/worktrees/4-r" "11: a write landing under the check refuses the reset"
assert_file "$XNH/r/.crew/worktrees/4-r/late.txt" "11: the late write survives"
assert_eq "$(sed -n 's/^leased=//p' "$XNH/r/.crew/slots/4-r.meta")" "1" "11: the lease is kept"
XPRE=""; xboth rm -rf @H/stubs @H/status.count @H/status.at @H/status.file
if [ "$(id -u)" != 0 ]; then
  xboth chmod 555 @H/r/.crew/slots
  xsame return @H/r/.crew/worktrees/4-r --force
  assert_eq "$XN_RC:$(xerr)" "1:WARN: cannot lock meta file @H/r/.crew/slots/4-r.meta - nothing written" "11: a claim that cannot be written ends the run, exit 1, before any reset"
  assert_file "$XNH/r/.crew/worktrees/4-r/late.txt" "11: nothing was reset"
  xboth chmod 755 @H/r/.crew/slots
fi
xboth rm -rf @H/r @H/stranger.pid

# 12. prune: dry and --yes over every skip - leased, broken, dirty, in-use,
#     lsof absent, unmerged - an epic-landed slot (the heads and the origin
#     arms), origin unreachable, a stale origin, an unreadable ledger
#     mid-loop (W7 named), and a pool that never leased (W9).
x12() { xrepo r; xorigin r; }
xboth x12
for xi in leased broken dirty inuse unmerged ep1-a ep1-b clean; do xsetup get --repo @H/r --id "$xi"; done
for xi in 2 3 4 5 6 7 8; do xsetup return "@H/r/.crew/worktrees/$xi-r"; done
x12shape() {
  local w="$H/r/.crew/worktrees"
  rm -rf "$H/r/.git/worktrees/2-r"; printf 'x\n' >"$w/3-r/wip.txt"
  git -C "$w/5-r" commit -q --allow-empty -m unmerged
  git -C "$w/6-r" commit -q --allow-empty -m 'landed on epic ep1'; git -C "$H/r" branch -q epic/ep1 "$(git -C "$w/6-r" rev-parse HEAD)"
  git -C "$w/7-r" commit -q --allow-empty -m 'landed on origin epic ep1b'
  git -C "$H/r" push -q origin "$(git -C "$w/7-r" rev-parse HEAD):refs/heads/epic/ep1b" 2>/dev/null; git -C "$H/r" fetch -q origin
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] ep1-a - story; epic:ep1\n- [ ] ep1-b - story; epic:ep1b\n- [ ] solo - story\n'
  xput home/data/ep1/branches $'r epic/ep1\n'; xput home/data/ep1b/branches $'r epic/ep1b\n'
}
xboth x12shape
x12meta() { local m="$H/r/.crew/slots/$1.meta"; grep -v '^task=' "$m" >"$H/x"; printf 'task=%s\n' "$2" >>"$H/x"; mv "$H/x" "$m"; }
xboth x12meta 5-r solo
if command -v lsof >/dev/null 2>&1; then
  x12inuse() { (cd "$H/r/.crew/worktrees/4-r" && exec sleep 30) >/dev/null 2>&1 & printf '%s\n' "$!" >"$H/inuse.pid"; disown; }
  xboth x12inuse; sleep 0.5
  xsame prune --repo @H/r
  assert_eq "$(xout)" "skip slot 1-r: leased
skip slot 2-r: worktree broken (git cannot read the slot itself)
skip slot 3-r: dirty
skip slot 4-r: in-use (live processes)
skip slot 5-r: HEAD not merged into origin/main
would prune slot 6-r: @H/r/.crew/worktrees/6-r (run with --yes)
would prune slot 7-r: @H/r/.crew/worktrees/7-r (run with --yes)
would prune slot 8-r: @H/r/.crew/worktrees/8-r (run with --yes)" "12: a dry run names every slot's fate"
  for xh in "$XOH" "$XNH"; do kill "$(cat "$xh/inuse.pid")" 2>/dev/null || true; done
fi
XPATH="$(nolsof_path)"; XPATH="$XSTUBS:$XPATH"
xsame prune --repo @H/r
XPATH=""
assert_contains "$(xout)" "skip slot 4-r: cannot check for live processes (lsof unavailable)" "12: without lsof prune cannot look, so it skips"
x12origin() { git -C "$H/r" remote set-url origin "$H/nowhere.git"; }
xboth x12origin
xsame prune --repo @H/r --yes
assert_contains "$(xout)" "skip slot 8-r: origin unreachable (cannot verify)" "12: an unreachable origin verifies nothing"
x12stale() {
  git -C "$H/r" remote set-url origin "$H/r.git"; git -C "$H/r" config remote.origin.fetch '+refs/heads/epic/ep1b:refs/remotes/origin/epic/ep1b'
  git -C "$H/r" push -q origin "$(git -C "$H/r/.crew/worktrees/5-r" rev-parse HEAD):refs/heads/main" 2>/dev/null
}
xboth x12stale
xsame prune --repo @H/r --yes
assert_contains "$(xout)" "skip slot 8-r: origin/main stale vs remote (cannot verify)" "12: a stale tracking ref verifies nothing"
x12fresh() { git -C "$H/r" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'; git -C "$H/r" push -q -f origin "$(git -C "$H/r" rev-parse main):refs/heads/main" 2>/dev/null; git -C "$H/r" fetch -q origin; }
xboth x12fresh
xsame prune --repo @H/r --yes
assert_eq "$(xout | grep '^pruned')" "pruned slot 4-r
pruned slot 6-r
pruned slot 7-r
pruned slot 8-r" "12: --yes prunes the merged (4-r's holder is gone) and the epic-landed (heads and origin arms)"
if [ "$(id -u)" != 0 ]; then
  xsetup get --repo @H/r --id solo
  xworktree="$(cat "$TMP/xs.raw")"; xworktree="${xworktree##*/}"
  xsetup return "@H/r/.crew/worktrees/$xworktree"
  x12land() { git -C "$H/r/.crew/worktrees/$xworktree" commit -q --allow-empty -m 'not merged anywhere'; }
  xboth x12land
  xboth chmod 000 @H/home/records/backlog.md
  xpair prune --repo @H/r --yes; xcheck_io; xcheck_w7 r; xsame_world
  xboth chmod 644 @H/home/records/backlog.md
  assert_eq "$XN_RC:$(xerr | tail -n 1)" "1:ERROR: prune: cannot read the ledger to resolve the epic-branch fence for solo" "12: an unreadable ledger stops prune mid-loop"
  assert_contains "$(xout)" "skip slot 3-r: dirty" "12: the lines before the stop stand"
fi
xboth rm -rf @H/r @H/r.git @H/home/data @H/home/records/backlog.md @H/inuse.pid
xboth xrepo r
xsame prune --repo @H/r
assert_eq "$XN_RC:$(xout):$(xerr)" "0::" "12: a pool that never leased prunes nothing"
assert_eq "$(git -C "$XNH/r" status --porcelain)" "?? .crew/" "12 (W9): ...and writes the workspace into a primary with no exclude line"
xboth rm -rf @H/r

# 13. remove: every refusal (W7 named on each), --force, --include-leased, a
#     broken slot's only way out, an epic-landed slot, an unreadable ledger.
xboth xrepo r
xsetup get --repo @H/r --id leased --owner "$$"
for xi in dirty unmerged landed broken clean; do xsetup get --repo @H/r --id "$xi"; done
for xi in 2 3 4 5 6; do xsetup return "@H/r/.crew/worktrees/$xi-r"; done
x13() {
  local w="$H/r/.crew/worktrees"
  printf 'x\n' >"$w/2-r/wip.txt"; git -C "$w/3-r" commit -q --allow-empty -m unmerged
  git -C "$w/4-r" commit -q --allow-empty -m 'landed on epic'; git -C "$H/r" branch -q epic/ep1 "$(git -C "$w/4-r" rev-parse HEAD)"
  rm -rf "$H/r/.git/worktrees/5-r"; mkdir -p "$w/9-r"
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] landed - story; epic:ep1\n- [ ] unmerged - story\n'
  xput home/data/ep1/branches $'r epic/ep1\n'
}
xboth x13
xrefuse_w7 "ERROR: remove: unmanaged slot: @H/r/.crew/worktrees/9-r" r remove @H/r/.crew/worktrees/9-r
xrefuse_w7 "ERROR: remove: slot 1-r is leased (task leased); pass --include-leased to take it anyway" r remove @H/r/.crew/worktrees/1-r
xrefuse_w7 "ERROR: remove: worktree is dirty; use --force to discard" r remove @H/r/.crew/worktrees/2-r
xrefuse_w7 "ERROR: remove: slot 3-r holds commits not merged into the default branch; use --force to discard" r remove @H/r/.crew/worktrees/3-r
xrefuse_w7 "ERROR: remove: slot 5-r is broken (gitdir unreadable) so its contents cannot be checked; use --force to discard" r remove @H/r/.crew/worktrees/5-r
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xrefuse_w7 "ERROR: remove: cannot read the ledger to resolve the epic-branch fence for unmerged" r remove @H/r/.crew/worktrees/3-r
  xboth chmod 644 @H/home/records/backlog.md
fi
xsame remove @H/r/.crew/worktrees/4-r
assert_eq "$XN_RC:$(xerr)" "0:WARN: removed slot 4-r" "13: an epic-landed slot is merged"
xsame remove @H/r/.crew/worktrees/2-r --force
xsame remove @H/r/.crew/worktrees/1-r --include-leased
xsame remove --force @H/r/.crew/worktrees/5-r
assert_eq "$XN_RC:$(xerr)" "0:WARN: removed slot 5-r" "13: a broken slot leaves through remove --force"
xsame remove @H/r/.crew/worktrees/6-r/
assert_eq "$XN_RC:$(ls "$XNH/r/.crew/slots")" "0:3-r.meta" "13: every other slot is gone"
xboth rm -rf @H/r @H/home/data @H/home/records/backlog.md

# 14. the pool lock: a live holder (30 PATH sleeps, then the refusal), a
#     pid-less fresh dir, a garbage and a dead pid reclaimed at once, the
#     original and the port excluding each other, and six concurrent first
#     gets per side (distinct slots, one install; W8 named: the unlocked
#     exclude write may land more than once).
xboth xrepo r; xsetup get --repo @H/r
xboth touch @H/sleep.fast
for xowner in "$$" ""; do
  xboth rm -f @H/sleep.log; xboth mkdir -p @H/r/.crew/lock
  if [ -n "$xowner" ]; then xboth xput r/.crew/lock/pid "$xowner"; else xboth rm -f @H/r/.crew/lock/pid; fi
  xrefuse "ERROR: could not acquire pool lock: @H/r/.crew/lock" list --repo @H/r
  assert_eq "$(tr '\n' ' ' <"$XNH/sleep.log")" "$(tr '\n' ' ' <"$XOH/sleep.log")" "14: the same waits on both sides (owner '$xowner')"
  assert_eq "$(grep -c '^1$' "$XNH/sleep.log")" "30" "14: thirty one-second waits (owner '$xowner')"
done
for xowner in abc "$xdead" 0 -1; do
  xboth rm -f @H/sleep.log; xboth xput r/.crew/lock/pid "$xowner"
  xsame list --repo @H/r
  assert_eq "$XN_RC:$([ -e "$XNH/sleep.log" ] && cat "$XNH/sleep.log")" "0:" "14: a lock owned by '$xowner' is stale and reclaimed at once"
done
xboth rm -f @H/sleep.fast @H/sleep.log
mkdir -p "$TMP/xblock"
cat >"$TMP/xblock/git" <<STUB
#!/bin/sh
case " \$* " in *" worktree prune "*) : >"\${XBLOCK}inside"; i=0; while [ ! -e "\${XBLOCK}go" ] && [ \$i -lt 600 ]; do /bin/sleep 0.1; i=\$((i + 1)); done ;; esac
exec $(command -v git) "\$@"
STUB
chmod +x "$TMP/xblock/git"
x14cross() {  # x14cross <holder bin> <waiter bin> <side root>
  local hb="$1" wb="$2" h="$3" hpid rc=0
  rm -f "$TMP/xblock-inside" "$TMP/xblock-go"
  (cd "$h/cwd" && exec env -u AC_FLEET_STATE AC_HOME="$h/home" STUB_DIR="$h" XBLOCK="$TMP/xblock-" PATH="$TMP/xblock:$XSTUBS:$PATH" "$hb/ac-tree.sh" get --repo "$h/r") </dev/null >"$TMP/xh.out" 2>"$TMP/xh.err" &
  hpid=$!
  for _ in $(seq 1 300); do [ -e "$TMP/xblock-inside" ] && break; sleep 0.1; done
  [ -e "$TMP/xblock-inside" ] || { touch "$TMP/xblock-go"; wait "$hpid" || true; fail "14: the holder never reached the lock: $(cat "$TMP/xh.err")"; }
  : >"$h/sleep.fast"
  (cd "$h/cwd" && exec env -u AC_FLEET_STATE AC_HOME="$h/home" STUB_DIR="$h" PATH="$XSTUBS:$PATH" "$wb/ac-tree.sh" list --repo "$h/r") </dev/null >"$TMP/xw.out" 2>"$TMP/xw.err" || rc=$?
  rm -f "$h/sleep.fast"
  touch "$TMP/xblock-go"
  wait "$hpid" || fail "14: the holder failed after the waiter gave up: $(cat "$TMP/xh.err")"
  assert_eq "$rc:$(cat "$TMP/xw.err")" "1:ERROR: could not acquire pool lock: $h/r/.crew/lock" "14: $wb waits out a lock $hb holds"
}
x14cross "$xobin" "$BIN" "$XOH"
x14cross "$BIN" "$xobin" "$XNH"
xboth rm -rf @H/r @H/sleep.log; xboth xrepo r
x14burst() {  # x14burst <bin> <side root> - six concurrent first gets
  local b="$1" h="$2" i pids=()
  for i in 1 2 3 4 5 6; do
    (cd "$h/cwd" && exec env -u AC_FLEET_STATE AC_HOME="$h/home" STUB_DIR="$h" PATH="$XSTUBS:$PATH" "$b/ac-tree.sh" get --repo "$h/r" --id "b$i") </dev/null >"$TMP/xb$i.out" 2>"$TMP/xb$i.err" &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do wait "$i" || fail "14: a concurrent get failed under $b: $(cat "$TMP"/xb*.err)"; done
  cat "$TMP"/xb[1-6].out | sed "s#$h#@H#" | LC_ALL=C sort | tr '\n' ' '
  printf '| %s installs |' "$(cat "$TMP"/xb[1-6].err | grep -c 'installed commit-guard at')"
  [ "$(grep -cxF '/.crew/' "$h/r/.git/info/exclude")" -ge 1 ] && printf ' excluded'
}
xburst="$(x14burst "$BIN" "$XNH")"
assert_eq "$xburst" "$(x14burst "$xobin" "$XOH")" "14: six concurrent first gets, alike on both sides"
assert_eq "$xburst" "@H/r/.crew/worktrees/1-r @H/r/.crew/worktrees/2-r @H/r/.crew/worktrees/3-r @H/r/.crew/worktrees/4-r @H/r/.crew/worktrees/5-r @H/r/.crew/worktrees/6-r | 1 installs | excluded" "14: distinct slots, one install, the pool excluded"
assert_eq "$(cksum <"$XNH/r/.git/hooks/pre-commit")" "$(cksum <"$XOH/r/.git/hooks/pre-commit")" "14: one guard body on both sides"
xboth rm -rf @H/r

# 15. failure arms, where the port's pool metas fail closed (each named): an
#     unreadable meta in the workspace pass (W4: the original's get ended exit
#     1 with no path after its lease; the port's lists the slot as leased and
#     prints the path), a workspace that cannot be written (the same end in
#     the original; a WARN in the port), a slots/ the stamp cannot write (W6:
#     the original printed the path of a lease it never recorded; the port
#     dies, nothing leased), a release that cannot be written (W6: three
#     rewrites in the original, one in the port), an unreadable meta in remove
#     and prune (W5: the original took it; the port holds it leased), a
#     planted symlink at every <file>.tmp.<pid> (EXCLUSIVE TEMPS), and two
#     appends racing on one crew meta (W2: the original's unlocked read drops
#     one; the port reads and renames under the meta lock).
xboth xrepo r
xsetup get --repo @H/r --id a; xsetup get --repo @H/r --id b; xsetup return @H/r/.crew/worktrees/2-r
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/r/.crew/slots/1-r.meta
  xpair get --repo @H/r --id c
  xboth chmod 644 @H/r/.crew/slots/1-r.meta
  xsame_err get
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "1:" "15 (W4): the original's workspace pass ended the get, exit 1, no path"
  assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/2-r" "15 (W4, named): the port's get prints the path it leased"
  assert_eq "$(cat "$XNH/r/.crew/r.code-workspace")" '{
  "folders": [
    { "path": "..", "name": "r (main)" },
    { "path": "worktrees/1-r", "name": "wt1-r" },
    { "path": "worktrees/2-r", "name": "wt2-r - c" }
  ]
}' "15 (W4, named): ...the unreadable slot in its workspace as a lease with no name"
  cp "$XNH/r/.crew/r.code-workspace" "$XOH/r/.crew/r.code-workspace"
  xsame_world get
  xsetup return @H/r/.crew/worktrees/2-r
  xboth xstub mv '#!/bin/sh
case "$2" in *.code-workspace) echo "mv: the stub refuses" >&2; exit 1 ;; esac
exec /bin/mv "$@"'
  XPRE=@H/stubs
  xpair get --repo @H/r --id c2
  XPRE=""; xboth rm -rf @H/stubs
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "1:" "15: the original's get ended on a workspace it could not write, no path"
  assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/2-r" "15 (named): the port's get prints the path"
  assert_eq "$(xerr)" "$(xoerr)
WARN: cannot write @H/r/.crew/r.code-workspace - the next pool change rewrites it" "15 (named): ...after a WARN naming the workspace"
  x15ws() { rm -f "$H"/r/.crew/r.code-workspace.tmp.*; }
  xboth x15ws
  xsame_world get
  xsetup return @H/r/.crew/worktrees/2-r
  xboth chmod 555 @H/r/.crew/slots
  xpair get --repo @H/r --id d
  xboth chmod 755 @H/r/.crew/slots
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:@H/r/.crew/worktrees/2-r" "15 (W6): the original printed the path of a lease it could not record"
  grep -q -E ': line [0-9]+: ' "$TMP/xo.err2" || fail "15 (W6): the original's failed stamp printed its shell noise"
  assert_eq "$XN_RC:$(xout)" "1:" "15 (W6, named): the port's stamp failure ends the get, no path"
  assert_eq "$(xerr)" "$(grep -v -E ': line [0-9]+: |^mv: ' "$TMP/xo.err2")
ERROR: cannot record the lease in @H/r/.crew/slots/2-r.meta - nothing leased" "15 (W6, named): ...naming the meta"
  [ ! -e "$XNH/r/.crew/lock" ] || fail "15 (W6): the port's failed stamp releases the pool lock"
  xsame_world get
  xsame get --repo @H/r --id e
  assert_eq "$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/2-r" "15 (W6): nothing was leased, so the next get leases that slot on both sides"
  xsetup return @H/r/.crew/worktrees/2-r
fi
# W6's release half: the claim's rewrite lands and the release's do not - the
# reset has run, the return ends exit 1, and the slot stays leased to the
# returner. The original made three rewrites, the last one's status its exit;
# the port's release is one rewrite whose failure names the slot (named).
xsetup get --repo @H/r --id f
xboth xstub mv '#!/bin/sh
case "$2" in */.crew/slots/*.meta) n=$(($(cat "$STUB_DIR/mv.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_DIR/mv.count"; [ "$n" -lt 2 ] || { echo "mv: the stub refuses" >&2; exit 1; } ;; esac
exec /bin/mv "$@"'
XPRE=@H/stubs
xpair return @H/r/.crew/worktrees/2-r --force
XPRE=""; xboth rm -rf @H/stubs @H/mv.count
assert_eq "$XO_RC:$(cat "$TMP/xo.out"):$(xoerr)" "1::mv: the stub refuses
mv: the stub refuses
mv: the stub refuses" "15 (W6): the original's three release rewrites each failed"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::mv: the stub refuses
ERROR: return: cannot record the release in @H/r/.crew/slots/2-r.meta - slot 2-r stays leased to this return until a get reclaims it" "15 (W6, named): the port's one release rewrite failed, the slot named"
# EXCLUSIVE TEMPS: a rewrite whose rename fails leaves its temp.
assert_eq "$(ls "$XOH"/r/.crew/slots/ | grep -c '\.tmp\.'):$(ls "$XNH"/r/.crew/slots/ | grep -c '\.tmp\.')" "1:1" "15 (W6): the temp each side's failed rename left"
x15tmp() { rm -f "$H"/r/.crew/slots/2-r.meta.tmp.*; }
xboth x15tmp
xsame_world
assert_eq "$XN_RC:$(sed -n 's/^leased=//p' "$XNH/r/.crew/slots/2-r.meta")" "1:1" "15 (W6): a release that cannot be written ends the return, the slot still leased"
if [ "$(id -u)" != 0 ]; then
  xboth xrepo r5
  xsetup get --repo @H/r5 --id p1; xsetup get --repo @H/r5 --id p2
  xsetup return @H/r5/.crew/worktrees/1-r5; xsetup return @H/r5/.crew/worktrees/2-r5
  xboth chmod 000 @H/r5/.crew/slots/1-r5.meta @H/r5/.crew/slots/2-r5.meta
  xpair remove @H/r5/.crew/worktrees/1-r5
  [ ! -e "$XOH/r5/.crew/slots/1-r5.meta" ] && [ ! -e "$XOH/r5/.crew/worktrees/1-r5" ] || fail "15 (W5): the original removed a slot whose meta it could not read"
  assert_eq "$XO_RC" "1" "15 (W4): ...then its workspace pass ended the run on the other unreadable meta"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::WARN: cannot read meta file @H/r5/.crew/slots/1-r5.meta
ERROR: remove: slot 1-r5's meta cannot be read, so it is treated as leased; pass --include-leased to take it anyway" "15 (W5, named): the port refuses it as a lease"
  [ ! -e "$XNH/r5/.crew/lock" ] || fail "15 (W5): the port's refusal releases the pool lock"
  xpair remove @H/r5/.crew/worktrees/1-r5 --include-leased
  assert_eq "$XN_RC" "0" "15 (W5): --include-leased takes it"
  [ ! -e "$XNH/r5/.crew/slots/1-r5.meta" ] && [ ! -e "$XNH/r5/.crew/worktrees/1-r5" ] || fail "15 (W5): ...dropping the slot"
  xpair prune --repo @H/r5 --yes
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:pruned slot 2-r5" "15 (W5): the original pruned a slot whose meta it could not read"
  assert_eq "$XN_RC:$(xout)" "0:skip slot 2-r5: meta unreadable (treated as leased)" "15 (W5, named): the port's prune skips it"
  chmod 644 "$XNH/r5/.crew/slots/2-r5.meta"
  xboth rm -rf @H/r5
  xboth xrepo r6
  xsetup get --repo @H/r6 --id h1; xsetup return @H/r6/.crew/worktrees/1-r6
  xboth rm -rf @H/r6/.git/worktrees/1-r6
  xboth chmod 000 @H/r6/.crew/slots/1-r6.meta
  xpair list --repo @H/r6
  xboth rm -rf @H/r6
  assert_contains "$(xoerr)" "reclaim it deliberately with: bin/ac-tree.sh remove --force @H/r6/.crew/worktrees/1-r6" "15 (W5): the original's heal names a remove that takes a broken slot whose meta it cannot read"
  assert_contains "$(xerr)" "reclaim it deliberately with: bin/ac-tree.sh remove --force --include-leased @H/r6/.crew/worktrees/1-r6" "15 (W5, named): the port's names the --include-leased its remove needs for one"
fi
xboth rm -rf @H/r; xboth mkdir -p @H/home/state
x15() {
  xrepo r; printf 'node_modules\n' >"$H/r/.gitignore"; git -C "$H/r" add .gitignore; git -C "$H/r" commit -qm gi
  printf '/.crew/\n' >>"$H/r/.gitignore"; mkdir -p "$H/r/.crew/slots"
  xput home/state/t15.meta $'kind=ship\nleases=@H/first\nlease_ids=x\n'
  local i; for i in 1 2 3 4 5; do printf 'victim bytes\n' >"$H/victim$i"; done
}
xboth x15
cat >"$TMP/xgate.sh" <<'GATE'
#!/usr/bin/env bash
_id="$(/bin/ps -o lstart= -p $$)"
_wd="$( ( sleep 60; [ "$(/bin/ps -o lstart= -p $$)" != "$_id" ] || kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 & printf '%s' $! )"
read -r _ <"$1"
kill "$_wd" 2>/dev/null || true
cd "$2" || exit 1
b="$3"; shift 3
exec "$b/ac-tree.sh" "$@"
GATE
chmod +x "$TMP/xgate.sh"
X15TEMPS="r/.gitignore r/.git/hooks/pre-commit r/.crew/slots/1-r.meta r/.crew/r.code-workspace home/state/t15.meta"
xplant() {  # xplant <bin> <side root> <out> - one gated get, a symlink to <side>/victim<i> planted at each temp name its pid makes
  local b="$1" h="$2" o="$3" gate pid t i=0; gate="$h/gate.fifo"; mkfifo "$gate"
  env -u AC_FLEET_STATE LC_ALL=C AC_HOME="$h/home" PATH="$XSTUBS:$PATH" STUB_DIR="$h" \
    "$TMP/xgate.sh" "$gate" "$h/cwd" "$b" get --repo "$h/r" --id t15 </dev/null >"$o" 2>"$o.err" &
  pid=$!
  for t in $X15TEMPS; do
    i=$((i + 1)); case "$t" in *pre-commit) t="$t.ac-crew-tmp" ;; *) t="$t.tmp" ;; esac
    ln -s "$h/victim$i" "$h/$t.$pid"
  done
  printf x >"$gate"
  wait "$pid" || fail "15: the planted row under $b failed: $(cat "$o.err")"
  rm -f "$gate"; printf '%s' "$pid" >"$o.pid"
}
xplant "$xobin" "$XOH" "$TMP/xpo"; xplant "$BIN" "$XNH" "$TMP/xpn"
assert_eq "$(xnorm "$TMP/xpn" "$XNH" "$(cat "$TMP/xpn.pid")")" "$(xnorm "$TMP/xpo" "$XOH" "$(cat "$TMP/xpo.pid")")" "15: the planted row's stdout"
assert_eq "$(xnorm "$TMP/xpn.err" "$XNH" "$(cat "$TMP/xpn.pid")")" "$(xnorm "$TMP/xpo.err" "$XOH" "$(cat "$TMP/xpo.pid")")" "15: the planted row's stderr"
xi=0
for xf in $X15TEMPS; do
  xi=$((xi + 1))
  assert_eq "$(cat "$XNH/victim$xi")" "victim bytes" "15: the port never writes through the planted $xf temp"
  [ "$(cat "$XOH/victim$xi")" != "victim bytes" ] || fail "15: the original wrote through the planted $xf temp (the divergence's bash side)"
  [ -f "$XNH/$xf" ] && [ ! -L "$XNH/$xf" ] || fail "15: the port's $xf stays a regular file"
  # The crew meta's second rewrite reused the name the first one renamed away.
  [ "$xf" = home/state/t15.meta ] || [ -L "$XOH/$xf" ] || fail "15: the original renamed its planted link over $xf"
done
assert_eq "$(sed -n 's/^leases=//p' "$XNH/home/state/t15.meta")" "$XNH/first:$XNH/r/.crew/worktrees/1-r" "15: the port's crew meta took the append"
xboth rm -rf @H/r @H/victim1 @H/victim2 @H/victim3 @H/victim4 @H/victim5 @H/home/state; xboth mkdir -p @H/home/state; xboth xrepo r; xboth xrepo r2
# W2: gets from two pools append to one crew meta at once. The first is held
# at its rename of state/t2.meta (a FIFO in a PATH mv) until the second is
# seen waiting on the meta lock (its first PATH sleep), then let go. The
# original read leases= BEFORE that wait, so its rename drops the first
# append; the port reads under the lock and keeps both.
xsetup get --repo @H/r --id t2
xboth xput home/state/t2.meta $'kind=ship\nleases=@H/first\nlease_ids=x\n'
xboth xstub mv '#!/bin/sh
case "$2" in */state/t2.meta) if mkdir "$STUB_DIR/gate.taken" 2>/dev/null; then echo $$ >"$STUB_DIR/at.gate"; read -r _ <"$STUB_DIR/gate.fifo"; fi ;; esac
exec /bin/mv "$@"'
xwait() {  # xwait <test...> - poll a checkpoint for up to 30s
  local i=0
  until "$@"; do i=$((i + 1)); [ "$i" -lt 600 ] || return 1; sleep 0.05; done
}
xslept_past() { [ "$(cat "$1/sleep.log" 2>/dev/null | wc -l)" -gt "$2" ]; }
xrace() {  # xrace <bin> <side root> - the two gets, gated as above
  local b="$1" h="$2" pa pb n
  mkfifo "$h/gate.fifo"
  env -u AC_FLEET_STATE LC_ALL=C AC_HOME="$h/home" PATH="$h/stubs:$XSTUBS:$PATH" STUB_DIR="$h" \
    "$b/ac-tree.sh" get --repo "$h/r" --id t2 </dev/null >"$h/tmp/a.out" 2>"$h/tmp/a.err" &
  pa=$!
  xwait test -s "$h/at.gate" || { kill "$pa"; fail "15 (W2): the first append never reached its rename under $b: $(cat "$h/tmp/a.err")"; }
  n="$(cat "$h/sleep.log" 2>/dev/null | wc -l)"
  env -u AC_FLEET_STATE LC_ALL=C AC_HOME="$h/home" PATH="$h/stubs:$XSTUBS:$PATH" STUB_DIR="$h" \
    "$b/ac-tree.sh" get --repo "$h/r2" --id t2 </dev/null >"$h/tmp/b.out" 2>"$h/tmp/b.err" &
  pb=$!
  xwait xslept_past "$h" "$n" || { kill "$pa" "$pb" "$(cat "$h/at.gate")"; fail "15 (W2): the second append never waited on the meta lock under $b: $(cat "$h/tmp/b.err")"; }
  printf x >"$h/gate.fifo"
  wait "$pa" || fail "15 (W2): the first get failed under $b: $(cat "$h/tmp/a.err")"
  wait "$pb" || fail "15 (W2): the second get failed under $b: $(cat "$h/tmp/b.err")"
  assert_eq "$(cat "$h/tmp/a.out") $(cat "$h/tmp/b.out")" "$h/r/.crew/worktrees/2-r $h/r2/.crew/worktrees/1-r2" "15 (W2): both gets leased under $b"
  rm -rf "$h/gate.fifo" "$h/at.gate" "$h/gate.taken"
}
xrace "$xobin" "$XOH"; xrace "$BIN" "$XNH"
assert_eq "$(sed -n 's/^leases=//p' "$XOH/home/state/t2.meta")" "$XOH/first:$XOH/r2/.crew/worktrees/1-r2" "15 (W2): the original's unlocked read dropped the first append"
assert_eq "$(sed -n 's/^leases=//p' "$XNH/home/state/t2.meta")" "$XNH/first:$XNH/r/.crew/worktrees/2-r:$XNH/r2/.crew/worktrees/1-r2" "15 (W2, named): the port keeps both appends"
assert_eq "$(sed -n 's/^lease_ids=//p' "$XNH/home/state/t2.meta")" "x:0011223344556677:0011223344556677" "15 (W2, named): ...each with its id"
assert_eq "$(ls -A "$XNH/home/state")" "t2.meta" "15 (W2): no meta lock and no temp left"
xboth rm -rf @H/r @H/r2 @H/stubs
# W2's failure arm: a crew meta the append cannot write (its state/ read-only).
# The original printed the path of a lease teardown would never find; the port
# releases the stamp and dies, nothing leased - and when that release cannot
# be written either, it names the return to run (named).
if [ "$(id -u)" != 0 ]; then
  xboth xrepo r
  xsetup get --repo @H/r --id t3
  xboth xput home/state/t3.meta $'kind=ship\nleases=@H/first\nlease_ids=x\n'
  xboth chmod 555 @H/home/state
  xpair get --repo @H/r --id t3
  xboth chmod 755 @H/home/state
  assert_eq "$XO_RC:$(cat "$TMP/xo.out"):$(xoerr)" "0:@H/r/.crew/worktrees/2-r:WARN: creating worktree slot 2-r
WARN: cannot lock meta file @H/home/state/t3.meta - nothing written
WARN: cannot lock meta file @H/home/state/t3.meta - nothing written" "15 (W2): the original printed the path of a lease its crew meta never took"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::WARN: creating worktree slot 2-r
WARN: cannot lock meta file @H/home/state/t3.meta - nothing written
ERROR: cannot record the lease of @H/r/.crew/worktrees/2-r in @H/home/state/t3.meta - the slot is released, nothing leased" "15 (W2, named): the port releases the stamp and dies"
  assert_eq "$(sed -n 's/^leased=//p' "$XNH/r/.crew/slots/2-r.meta"):$(sed -n 's/^leases=//p' "$XNH/home/state/t3.meta")" "0:$XNH/first" "15 (W2, named): ...the slot available, the crew meta as it was"
  [ ! -e "$XNH/r/.crew/lock" ] || fail "15 (W2): the port's failed append releases the pool lock"
  H="$XNH" xstub mv '#!/bin/sh
case "$2" in */.crew/slots/*.meta) n=$(($(cat "$STUB_DIR/mv.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_DIR/mv.count"; [ "$n" -lt 2 ] || { echo "mv: the stub refuses" >&2; exit 1; } ;; esac
exec /bin/mv "$@"'
  chmod 555 "$XNH/home/state"
  XN_RC=0; XPRE=@H/stubs; xrun_side "$BIN" "$XNH" xn get --repo @H/r --id t3 || XN_RC=$?; XPRE=""
  chmod 755 "$XNH/home/state"
  assert_eq "$XN_RC:$(xnorm "$TMP/xn.raw" "$XNH" "$(cat "$TMP/xn.pid")"):$(xnorm "$TMP/xn.err" "$XNH" "$(cat "$TMP/xn.pid")")" "1::WARN: reusing worktree slot 2-r
WARN: cannot lock meta file @H/home/state/t3.meta - nothing written
mv: the stub refuses
ERROR: cannot record the lease of @H/r/.crew/worktrees/2-r in @H/home/state/t3.meta, nor release the slot - return it with: bin/ac-tree.sh return @H/r/.crew/worktrees/2-r" "15 (W2, named): a release that fails too names the return to run"
  assert_eq "$(sed -n 's/^task=//p;s/^leased=//p' "$XNH/r/.crew/slots/2-r.meta" | tr '\n' ' ')" "1 t3 " "15 (W2, named): ...the slot still leased to the task"
  xboth rm -rf @H/r @H/stubs @H/mv.count
fi

# 16. the network, bounded (W3 fixed, named): get's fetch and prune's fetch and
#     ls-remote run under the sync knob's deadline (src/lib.ts runBounded),
#     AC_SYNC_TIMEOUT=3 here - whole seconds, so a deadline of N fires within
#     (N-1, N+0.2] s and a fetch that must succeed needs N past 1. A stalled
#     origin (`ext::sleep 8`) the original waited out and read as a failure
#     is the port's timeout, said as one. An ls-remote that cannot answer
#     after a fetch that worked - stalled, or failing - left the original
#     pruning on the fetched ref; the port cannot verify.
x16() {
  xrepo r; git init -q --bare -b main "$H/r.git"; git -C "$H/r" push -q "$H/r.git" main 2>/dev/null
  git -C "$H/r" config protocol.ext.allow always
  git -C "$H/r" remote add origin "ext::sleep 8"
  printf '#!/bin/sh\nn=$(($(cat "$0.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$0.count"\n[ "$n" -lt 2 ] || { [ ! -e "$0.fail" ] || exit 1; exec sleep 8; }\nexec git upload-pack "%s"\n' "$H/r.git" >"$H/ext.sh"
  chmod +x "$H/ext.sh"
}
xboth rm -rf @H/home/state; xboth mkdir -p @H/home/state; xboth x16
XENV=(AC_SYNC_TIMEOUT=3)
xpair get --repo @H/r --id n1
assert_eq "$XO_RC:$(cat "$TMP/xo.out"):$XN_RC:$(xout)" "0:@H/r/.crew/worktrees/1-r:0:@H/r/.crew/worktrees/1-r" "16: get leases past a stalled origin on both sides"
assert_contains "$(xoerr)" "WARN: fetch origin failed; using local refs" "16: the original waited the stall out and read it as a failure"
assert_eq "$(xerr)" "$(xoerr | sed 's/^WARN: fetch origin failed; using local refs$/WARN: fetch origin timed out after 3s; using local refs/')" "16 (W3, named): the port's deadline fired first, and its line says so"
xsame_world get
xsetup return @H/r/.crew/worktrees/1-r
xpair prune --repo @H/r; xsame_err prune; xsame_world prune
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:skip slot 1-r: origin unreachable (cannot verify)" "16: the original's prune waited the stalled fetch out"
assert_eq "$XN_RC:$(xout)" "0:skip slot 1-r: origin fetch timed out after 3s (cannot verify)" "16 (W3, named): the port's fetch timed out under the pool lock"
x16ls() { git -C "$H/r" remote set-url origin "ext::$H/ext.sh %S"; rm -f "$H/ext.sh.count"; }
xboth x16ls
xpair prune --repo @H/r; xsame_err prune; xsame_world prune
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:would prune slot 1-r: @H/r/.crew/worktrees/1-r (run with --yes)" "16: the original's stalled ls-remote answered nothing, and it pruned on the fetched ref"
assert_eq "$XN_RC:$(xout)" "0:skip slot 1-r: origin ls-remote timed out after 3s (cannot verify)" "16 (W3, named): the port's ls-remote timed out"
x16fail() { : >"$H/ext.sh.fail"; rm -f "$H/ext.sh.count"; }
xboth x16fail
xpair prune --repo @H/r; xsame_err prune; xsame_world prune
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:would prune slot 1-r: @H/r/.crew/worktrees/1-r (run with --yes)" "16: the original's failing ls-remote answered nothing, and it pruned on the fetched ref"
assert_eq "$XN_RC:$(xout)" "0:skip slot 1-r: origin unreachable (cannot verify)" "16 (named): the port's failing ls-remote cannot verify"
XENV=()
xboth rm -rf @H/r @H/r.git @H/ext.sh @H/ext.sh.count @H/ext.sh.fail

pass
