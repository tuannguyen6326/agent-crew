#!/usr/bin/env bash
# ac-commit-guard.test.sh - the fleet-wide guard against a git commit made
# OUTSIDE a leased worktree (a crewmate/roomchief committing into the PRIMARY
# checkout, the observed 5x failure). A pre-commit hook, installed ONCE at lease
# time (ac-tree.sh get) into the SHARED git-common-dir/hooks, REFUSES such a
# commit and passes everything legitimate. Covers AC1-AC9 + E1 (chain, never
# clobber) + E2 (fail-open) from data/crewmate-edits-primary-checkout/spec.
#
# TEST SAFETY: every git repo here is a throwaway from helpers.sh make_repo /
# $TMP - the hook is NEVER installed into the live primary .git or the live pool.
# AC8 (harness-agnostic) holds by construction: the guard is a git-layer hook,
# exercised below with plain `git`, with no harness anywhere in the test.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# hook_dir <repo-or-worktree> - the resolved hooks dir git would run hooks from
# (respects core.hooksPath; otherwise the shared common-dir hooks).
hook_dir() { git -C "$1" rev-parse --path-format=absolute --git-path hooks; }

# --- Install site (Q1) = lease time: ac-tree.sh get wires the hook in --------
repo="$(make_repo)"
wt1="$("$BIN/ac-tree.sh" get --repo "$repo" --id g1 --holder crew:g1 2>/dev/null)"
hook="$(hook_dir "$repo")/pre-commit"
assert_file "$hook" "lease-time install wrote the shared pre-commit hook"
[ -x "$hook" ] || fail "hook must be executable"
assert_contains "$(cat "$hook")" "ac-crew-primary-commit-guard" "hook carries its sentinel"

main0="$(git -C "$repo" rev-parse main)"

# --- AC1: crewmate commit in PRIMARY is refused, no commit object created -----
out="$(cd "$repo" && AC_CREW_ID=g1 git commit --allow-empty -m sneak 2>&1)" \
  && fail "AC1: a crewmate commit in the primary must be refused"
assert_eq "$(git -C "$repo" rev-parse main)" "$main0" "AC1: main HEAD unchanged (no commit object)"
assert_contains "$out" "$repo" "AC1: the refusal names the primary path"
assert_contains "$out" "crew/" "AC1: the refusal tells the agent to commit in its worktree on crew/<id>"
assert_contains "$out" "leave the primary working tree ALONE" \
  "AC1: the refusal forbids the destructive cleanup the refused agent reaches for next"

# --- AC9 (regression): the exact instance-A shape, now stopped ---------------
#     instance A: a crew-scalar env committed "fix(watch): ..." onto primary
#     main (28892c8), then had to be reset/re-landed. Assert it is now stopped
#     and the baseline every fresh lease resets from is not poisoned.
before="$(git -C "$repo" rev-parse main)"
( cd "$repo" && AC_CREW_ID=watch-done AC_FLEET_STATE="$AC_HOME/state" \
    git commit --allow-empty -m "fix(watch): done-but-unreaped pane goes quiet" ) >/dev/null 2>&1 \
  && fail "AC9: the reproduced instance-A commit must be stopped"
assert_eq "$(git -C "$repo" rev-parse main)" "$before" "AC9: primary main baseline not poisoned"

# --- AC2: roomchief (AC_SCOPE, no AC_CREW_ID) commit in PRIMARY refused -------
out="$(cd "$repo" && AC_SCOPE=g1fam git commit --allow-empty -m "chief sneak" 2>&1)" \
  && fail "AC2: a roomchief commit in the primary must be refused"
assert_eq "$(git -C "$repo" rev-parse main)" "$main0" "AC2: main HEAD unchanged"

# --- AC3: crewmate commit INSIDE its own leased worktree succeeds ------------
wt_head0="$(git -C "$wt1" rev-parse HEAD)"
( cd "$wt1" && AC_CREW_ID=g1 git commit --allow-empty -m "real crew work" ) >/dev/null 2>&1 \
  || fail "AC3: a crewmate commit inside its worktree must succeed"
[ "$(git -C "$wt1" rev-parse HEAD)" != "$wt_head0" ] || fail "AC3: worktree commit did not advance HEAD"

# --- AC4: captain (no crew scalars) commit in PRIMARY is NOT blocked ---------
( cd "$repo" && git commit --allow-empty -m "captain hand-commit" ) >/dev/null 2>&1 \
  || fail "AC4: the captain's own primary commit must not be blocked"
[ "$(git -C "$repo" rev-parse main)" != "$main0" ] || fail "AC4: captain commit did not advance main"

# --- AC7: ONE shared hook covers a second worktree, no per-worktree install --
hook_inode0="$(ls -i "$hook" | awk '{print $1}')"
hook_sum0="$(cksum <"$hook")"
wt2="$("$BIN/ac-tree.sh" get --repo "$repo" --id g2 2>/dev/null)"
assert_eq "$(ls -i "$hook" | awk '{print $1}')" "$hook_inode0" "AC7: a second lease did not re-install (same hook inode)"
assert_eq "$(cksum <"$hook")" "$hook_sum0" "AC7: a second lease left the hook byte-identical"
assert_eq "$(hook_dir "$wt2")/pre-commit" "$hook" "AC7: the second worktree shares the one common-dir hook"
# the shared hook is ACTIVE from the second worktree: a commit there passes (D1)
( cd "$wt2" && AC_CREW_ID=g2 git commit --allow-empty -m "slot2 work" ) >/dev/null 2>&1 \
  || fail "AC7: a commit in the second worktree must pass the shared hook"
# ...and that same single hook still refuses a primary commit under crew scalars
before="$(git -C "$repo" rev-parse main)"
( cd "$repo" && AC_CREW_ID=g2 git commit --allow-empty -m "slot2 sneak into primary" ) >/dev/null 2>&1 \
  && fail "AC7: the single shared hook must still guard the primary"
assert_eq "$(git -C "$repo" rev-parse main)" "$before" "AC7: primary still protected by the one hook"

# --- AC6: fetch/status/log + ac-tree.sh return are unaffected ----------------
# A real fetch needs a remote: clone the primary into a bare origin and wire it.
bare="$TMP/origin.git"
git clone -q --bare "$repo" "$bare"
git -C "$repo" remote add origin "$bare"
( cd "$repo" && AC_CREW_ID=g1 git fetch origin ) >/dev/null 2>&1 \
  || fail "AC6: git fetch under crew scalars must be unaffected by the guard"
( cd "$repo" && AC_CREW_ID=g1 git status >/dev/null && AC_CREW_ID=g1 git log -1 >/dev/null ) \
  || fail "AC6: read-only git under crew scalars must be unaffected"
"$BIN/ac-tree.sh" return "$wt1" 2>/dev/null || fail "AC6: ac-tree.sh return must not be blocked by the guard"

# --- AC5: a local-only ff-land runs green through the installed guard --------
#     ac-merge-local.sh fast-forwards (git merge --ff-only) - no commit object,
#     and it runs with no crew scalars, so the guard never fires. Doubly safe.
r5="$(make_repo mlrepo)"
"$BIN/ac-tree.sh" get --repo "$r5" --id ac5 >/dev/null 2>&1   # installs the guard
git -C "$r5" checkout -q -b crew/ac5
printf 'crew change\n' >"$r5/crewfile.txt"
git -C "$r5" add -A && git -C "$r5" commit -qm "crew work"
git -C "$r5" checkout -q main
mkdir -p "$AC_HOME/state"
printf 'project_dir=%s\nworktree=%s\n' "$r5" "$r5/.crew/worktrees/1" >"$AC_HOME/state/ac5.meta"
out="$("$BIN/ac-merge-local.sh" ac5 2>&1)" || fail "AC5: local land must run green through the guard"
assert_contains "$out" "fast-forwarded" "AC5: ff land succeeded with the guard installed"
assert_eq "$(git -C "$r5" rev-parse main)" "$(git -C "$r5" rev-parse crew/ac5)" "AC5: main ff'd to crew/ac5"

# A `git` that errors on every call, for the fail-open paths below.
stub="$TMP/failgit"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 3\n' >"$stub/git"
chmod +x "$stub/git"

# --- E1: a pre-existing foreign pre-commit hook is CHAINED, not clobbered -----
r6="$(make_repo chainrepo)"
marker="$TMP/foreign-ran"
foreign="$(hook_dir "$r6")/pre-commit"
cat >"$foreign" <<EOF
#!/usr/bin/env bash
: >"$marker"
exit 0
EOF
chmod +x "$foreign"
"$BIN/ac-tree.sh" get --repo "$r6" --id ch1 >/dev/null 2>&1
h6="$(hook_dir "$r6")/pre-commit"
assert_contains "$(cat "$h6")" "ac-crew-primary-commit-guard" "E1: our guard is now the pre-commit hook"
assert_file "$(hook_dir "$r6")/pre-commit.ac-crew-prev" "E1: the foreign hook was preserved, not clobbered"
rm -f "$marker"
( cd "$r6" && git commit --allow-empty -m "chain test" ) >/dev/null 2>&1 \
  || fail "E1: an allowed commit must still succeed"
assert_file "$marker" "E1: the chained foreign hook still ran after our guard passed"

# --- CR-003: fail-open skips only OUR guard, never the chained project hook ---
#     A rev-parse error under crew scalars must still hand off to the preserved
#     foreign hook (not swallow it with a bare exit 0).
rm -f "$marker"
rc=0
( cd "$r6" && PATH="$stub:$PATH" AC_CREW_ID=ch1 "$h6" ) || rc=$?
assert_eq "$rc" "0" "CR-003: a rev-parse failure with a chained hook still exits 0"
assert_file "$marker" "CR-003: the chained foreign hook still ran on a fail-open probe failure"

# --- CR-002: an existing sidecar + a NEWLY replaced foreign hook -> SKIP ------
#     After the first chain (foreign1 -> sidecar, ours -> pre-commit), a hook
#     manager replaces our guard with foreign2; a later lease must keep foreign2
#     and the preserved foreign1, installing nothing rather than clobbering.
r7="$(make_repo relockrepo)"
f7="$(hook_dir "$r7")/pre-commit"
printf '#!/usr/bin/env bash\n: >"%s/foreign1"\nexit 0\n' "$TMP" >"$f7"; chmod +x "$f7"
"$BIN/ac-tree.sh" get --repo "$r7" --id rl1 >/dev/null 2>&1
assert_contains "$(cat "$f7")" "ac-crew-primary-commit-guard" "CR-002 setup: our guard installed, foreign1 chained"
printf '#!/usr/bin/env bash\n: >"%s/foreign2"\nexit 0\n' "$TMP" >"$f7"; chmod +x "$f7"   # hook manager replaces ours
out="$("$BIN/ac-tree.sh" get --repo "$r7" --id rl2 2>&1)"
assert_contains "$out" "skipping commit-guard install" "CR-002: the installer skips rather than clobber"
case "$(cat "$f7")" in *ac-crew-primary-commit-guard*) fail "CR-002: the replacement foreign hook was clobbered" ;; esac
assert_contains "$(cat "$f7")" "foreign2" "CR-002: the current foreign hook survived intact"
assert_contains "$(cat "$(hook_dir "$r7")/pre-commit.ac-crew-prev")" "foreign1" "CR-002: the originally-preserved hook is intact"

# --- CR-006: concurrent first leases must not race the install into a
#     self-referential sidecar. The installer now runs under the pool lock, so
#     the second lease sees our sentinel and no-ops rather than moving our own
#     fresh wrapper onto pre-commit.ac-crew-prev (which run_chained would then
#     exec forever).
rcr="$(make_repo racerepo)"
( "$BIN/ac-tree.sh" get --repo "$rcr" --id rc1 >/dev/null 2>&1 ) & p1=$!
( "$BIN/ac-tree.sh" get --repo "$rcr" --id rc2 >/dev/null 2>&1 ) & p2=$!
# Per-PID waits (a bare `wait` returns 0 even if a lease failed): the lease path
# must stay HEALTHY under the concurrency scenario, not merely avoid a sidecar.
wait "$p1" || fail "CR-006: concurrent lease rc1 failed (lease path regressed)"
wait "$p2" || fail "CR-006: concurrent lease rc2 failed (lease path regressed)"
[ -d "$rcr/.crew/worktrees/1" ] && [ -d "$rcr/.crew/worktrees/2" ] \
  || fail "CR-006: both concurrent leases must produce a worktree"
assert_contains "$(cat "$(hook_dir "$rcr")/pre-commit")" "ac-crew-primary-commit-guard" \
  "CR-006: the installed hook is our guard after concurrent leases"
assert_no_file "$(hook_dir "$rcr")/pre-commit.ac-crew-prev" \
  "CR-006: no self-referential sidecar from a concurrent install"

# --- CR-009: a failed guard write must NOT destroy an existing hook ----------
#     Failure-atomic install (stage-to-temp + atomic swap). Force the staging
#     write to fail by making the hooks dir read-only with a foreign hook in it;
#     the foreign hook must survive byte-identical and the lease must proceed.
#     Skipped under root: root bypasses DAC, so a read-only dir cannot force the
#     write to fail (the injection is UID-dependent, not the implementation).
if [ "$(id -u)" != 0 ]; then
  r10="$(make_repo atomicrepo)"
  hd="$(hook_dir "$r10")"
  printf '#!/usr/bin/env bash\n: >"%s/atomic-foreign"\nexit 0\n' "$TMP" >"$hd/pre-commit"
  chmod +x "$hd/pre-commit"
  foreign_sum="$(cksum <"$hd/pre-commit")"
  chmod a-w "$hd"
  out="$("$BIN/ac-tree.sh" get --repo "$r10" --id at1 2>&1)" || { chmod u+w "$hd"; fail "CR-009: the lease must proceed when the guard cannot be staged"; }
  chmod u+w "$hd"
  assert_eq "$(cksum <"$hd/pre-commit")" "$foreign_sum" "CR-009: a failed guard write left the foreign hook byte-identical"
  assert_no_file "$hd/pre-commit.ac-crew-prev" "CR-009: nothing was moved aside on a failed stage"
  [ -d "$r10/.crew/worktrees/1" ] || fail "CR-009: the lease still proceeded despite the guard install being skipped"
fi

# --- CR-012: a symlink-managed pre-commit is left untouched (skip fail-open) --
#     Chaining would dereference a live symlink or clobber a dangling one, both
#     severing a hook manager's target. The install must skip and leave it.
r11="$(make_repo symlinkrepo)"
hd11="$(hook_dir "$r11")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/hookmgr-target"; chmod +x "$TMP/hookmgr-target"
ln -s "$TMP/hookmgr-target" "$hd11/pre-commit"
out="$("$BIN/ac-tree.sh" get --repo "$r11" --id sl1 2>&1)"
assert_contains "$out" "pre-commit is a symlink" "CR-012: a symlink hook is recognized and skipped"
[ -L "$hd11/pre-commit" ] || fail "CR-012: the pre-commit symlink must be left in place, not replaced"
assert_eq "$(readlink "$hd11/pre-commit")" "$TMP/hookmgr-target" "CR-012: the symlink still points at the hook manager target"
assert_no_file "$hd11/pre-commit.ac-crew-prev" "CR-012: nothing was moved aside for a symlink hook"

# --- UPG: an OUTDATED guard of OURS is upgraded in place ----------------------
#     The sentinel-only idempotence check made every guard TEXT change inert on
#     any repo already onboarded (the fleet split silently into old- and
#     new-wording repos). Provenance is BYTE-EXACT, following ensure_gitignore's
#     self-heal: identical -> untouched, ours-but-different -> replaced with the
#     previous bytes preserved, foreign -> chained (untouched by this block).
#     The reference "current text" is a hook installed into a virgin repo.
ref="$TMP/guard-current"
rref="$(make_repo refrepo)"
"$BIN/ac-tree.sh" get --repo "$rref" --id ref1 >/dev/null 2>&1
cp "$(hook_dir "$rref")/pre-commit" "$ref"

# UPG-1 (AC2/AC3): ours + DIFFERENT -> upgraded, old bytes preserved, warning
# names the backup path, and .ac-crew-prev is never written (that slot is the
# project hook's, and run_chained EXECs it - our own old guard must never land
# there).
r12="$(make_repo staleguard)"
hd12="$(hook_dir "$r12")"
"$BIN/ac-tree.sh" get --repo "$r12" --id up1 >/dev/null 2>&1
sed '/working tree ALONE/d' "$ref" >"$hd12/pre-commit.stale" \
  && printf '# hand-edit-marker-A\n' >>"$hd12/pre-commit.stale"
mv "$hd12/pre-commit.stale" "$hd12/pre-commit"
chmod +x "$hd12/pre-commit"
out="$("$BIN/ac-tree.sh" get --repo "$r12" --id up2 2>&1)"
assert_eq "$(cksum <"$hd12/pre-commit")" "$(cksum <"$ref")" \
  "UPG-1: an outdated guard of ours was upgraded to the current text"
[ -x "$hd12/pre-commit" ] || fail "UPG-1: the upgraded hook must stay executable"
bak="$(ls "$hd12"/pre-commit.ac-crew-stale-* 2>/dev/null | head -1)"
[ -n "$bak" ] || fail "UPG-1: the pre-upgrade bytes must survive in a backup"
assert_contains "$(cat "$bak")" "hand-edit-marker-A" "UPG-1: the backup carries the pre-upgrade bytes"
assert_contains "$out" "$bak" "UPG-1: the warning names the backup path"
assert_no_file "$hd12/pre-commit.ac-crew-prev" "UPG-1: the upgrade never writes the chain sidecar"
# the upgraded hook is ACTIVE: it still refuses a crewmate commit in the primary
before="$(git -C "$r12" rev-parse main)"
( cd "$r12" && AC_CREW_ID=up2 git commit --allow-empty -m "post-upgrade sneak" ) >/dev/null 2>&1 \
  && fail "UPG-1: the upgraded guard must still refuse a primary crewmate commit"
assert_eq "$(git -C "$r12" rev-parse main)" "$before" "UPG-1: primary main still protected after the upgrade"

# UPG-2 (AC1): ours + byte-identical -> no rewrite, no backup, no warning
sum12="$(cksum <"$hd12/pre-commit")"
out="$("$BIN/ac-tree.sh" get --repo "$r12" --id up3 2>&1)"
assert_eq "$(cksum <"$hd12/pre-commit")" "$sum12" "UPG-2: an up-to-date guard is left byte-identical"
assert_eq "$(ls "$hd12"/pre-commit.ac-crew-stale-* 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "UPG-2: an up-to-date guard creates no further backup"
case "$out" in *commit-guard*|*commit\ guard*) fail "UPG-2: an up-to-date guard must warn about nothing: $out" ;; esac

# UPG-3 (AC4): a backup that already exists is NEVER clobbered
r13="$(make_repo staleguard2)"
hd13="$(hook_dir "$r13")"
"$BIN/ac-tree.sh" get --repo "$r13" --id up4 >/dev/null 2>&1
printf 'decoy backup - must survive\n' >"$hd13/pre-commit.ac-crew-stale-1"
decoy_sum="$(cksum <"$hd13/pre-commit.ac-crew-stale-1")"
{ cat "$ref"; printf '# hand-edit-marker-B\n'; } >"$hd13/pre-commit.stale"
mv "$hd13/pre-commit.stale" "$hd13/pre-commit"; chmod +x "$hd13/pre-commit"
"$BIN/ac-tree.sh" get --repo "$r13" --id up5 >/dev/null 2>&1
assert_eq "$(cksum <"$hd13/pre-commit.ac-crew-stale-1")" "$decoy_sum" \
  "UPG-3: a pre-existing backup is never clobbered by a later upgrade"

# UPG-4 (AC6): the upgrade path is FAIL-OPEN - an unwritable hooks dir leaves
#     the outdated guard intact and running, and the lease still proceeds.
#     Skipped under root (root bypasses DAC, so the write cannot be forced to
#     fail) - same UID-dependent injection as CR-009.
if [ "$(id -u)" != 0 ]; then
  r14="$(make_repo staleguard3)"
  hd14="$(hook_dir "$r14")"
  "$BIN/ac-tree.sh" get --repo "$r14" --id up6 >/dev/null 2>&1
  { cat "$ref"; printf '# hand-edit-marker-C\n'; } >"$hd14/pre-commit.stale"
  mv "$hd14/pre-commit.stale" "$hd14/pre-commit"; chmod +x "$hd14/pre-commit"
  stale_sum="$(cksum <"$hd14/pre-commit")"
  chmod a-w "$hd14"
  "$BIN/ac-tree.sh" get --repo "$r14" --id up7 >/dev/null 2>&1 \
    || { chmod u+w "$hd14"; fail "UPG-4: the lease must proceed when the guard cannot be upgraded"; }
  chmod u+w "$hd14"
  assert_eq "$(cksum <"$hd14/pre-commit")" "$stale_sum" \
    "UPG-4: a failed upgrade left the outdated guard byte-identical (fail-open)"
  assert_no_file "$hd14/pre-commit.ac-crew-prev" "UPG-4: nothing was moved aside on a failed upgrade"
  [ -d "$r14/.crew/worktrees/2" ] || fail "UPG-4: the lease still proceeded despite the upgrade being skipped"
fi

# --- Option A (captain 2026-07-24): a custom core.hooksPath is SKIPPED --------
#     fail-open. The guard covers only the DEFAULT shared common-dir hooks; a
#     custom hooksPath is not shared (relative), could dirty the primary
#     (tracked), or would break the lease (/dev/null), so the install is skipped
#     and the lease still proceeds.
r8="$(make_repo hookspath-rel)"
git -C "$r8" config core.hooksPath .githooks
out="$("$BIN/ac-tree.sh" get --repo "$r8" --id hp1 2>&1)"
assert_contains "$out" "core.hooksPath is set; skipping commit-guard install" "A: a custom hooksPath skips the install"
assert_no_file "$r8/.git/hooks/pre-commit" "A: no guard written to the default hooks under a custom hooksPath"
assert_no_file "$r8/.githooks/pre-commit" "A: nothing written into the custom hooksPath dir"
[ -d "$r8/.crew/worktrees/1" ] || fail "A: the lease still proceeded under a custom hooksPath"

# /dev/null (hooks disabled) must not abort the lease.
r9="$(make_repo hookspath-devnull)"
git -C "$r9" config core.hooksPath /dev/null
"$BIN/ac-tree.sh" get --repo "$r9" --id hp2 >/dev/null 2>&1 \
  || fail "A: core.hooksPath=/dev/null must not break ac-tree.sh get"
[ -d "$r9/.crew/worktrees/1" ] || fail "A: the lease proceeded with hooks disabled via /dev/null"

# --- E2: the hook fails OPEN when a rev-parse call errors (never onto captain)
#     Invoke the installed hook directly with a `git` that errors, under crew
#     scalars in the primary - the one context that would otherwise REFUSE. With
#     no chained hook present it simply exits 0.
rc=0
( cd "$repo" && PATH="$stub:$PATH" AC_CREW_ID=g1 "$hook" ) || rc=$?
assert_eq "$rc" "0" "E2: a rev-parse failure fails OPEN (exit 0), never fail-closed onto the captain"

pass
