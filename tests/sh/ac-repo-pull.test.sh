#!/usr/bin/env bash
# ac-repo-pull.test.sh - fetch + FAST-FORWARD-ONLY sync of a project clone's
# default branch. Never a merge, never a rebase, never a forced move: a
# diverged or dirty clone fetches and reports, nothing else.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

git_id() { git -C "$1" config user.email test@test; git -C "$1" config user.name test; }
commit() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$3"
}

# origin with one commit; clone tracks it.
origin="$TMP/origin"; clone="$TMP/clone"
git init -q -b main "$origin"; git_id "$origin"; commit "$origin" f.txt genesis
git clone -q "$origin" "$clone"; git_id "$clone"

# ---- Case 1: behind and clean -> fetch + ff-sync moves the default branch.
commit "$origin" g.txt "landed upstream"
out="$("$BIN/ac-repo-pull.sh" "$clone")"
assert_contains "$out" "synced" "a clean behind clone fast-forwards"
[ "$(git -C "$clone" rev-parse main)" = "$(git -C "$origin" rev-parse main)" ] \
  || fail "clone main did not reach origin main after pull"

# ---- Case 2: diverged -> fetch only, the local commit survives untouched.
commit "$origin" h.txt "more upstream"
commit "$clone" local.txt "local divergence"
localsha="$(git -C "$clone" rev-parse main)"
out2="$("$BIN/ac-repo-pull.sh" "$clone")"
assert_contains "$out2" "fetched" "a diverged clone still fetches"
case "$out2" in *synced*) fail "a diverged clone must never sync" ;; esac
[ "$(git -C "$clone" rev-parse main)" = "$localsha" ] \
  || fail "pull moved a diverged local branch"
[ "$(git -C "$clone" rev-parse origin/main)" = "$(git -C "$origin" rev-parse main)" ] \
  || fail "fetch did not update the remote-tracking ref"

# ---- Case 3: strictly AHEAD (unpushed local work) -> fetch only, and the
#      report says ahead, not diverged - the operator's next move differs.
git -C "$clone" reset -q --hard origin/main
commit "$clone" ahead.txt "local ahead"
out3="$("$BIN/ac-repo-pull.sh" "$clone")"
assert_contains "$out3" "ahead" "an ahead clone reports ahead, not diverged"
case "$out3" in *synced*) fail "an ahead clone must never sync" ;; esac

# ---- Case 4: not a git repo -> refuses.
mkdir -p "$TMP/notrepo"
if "$BIN/ac-repo-pull.sh" "$TMP/notrepo" >/dev/null 2>&1; then
  fail "a non-repo path must refuse"
fi

# --- the probes in order, row by row -------------------------------------------
# One home ($H) with its own origin and, per row, a FRESH clone (a run mutates
# the clone); cwd is the home and LC_ALL=C. HOME in an argument is the home,
# and the home path reads HOME in what the run printed.
H="$TMP/nh"
seed_home() {  # one origin on main; sub/ is tracked so a subdirectory root exists in every clone
  mkdir -p "$H/origin/sub"
  git init -q -b main "$H/origin"
  git_id "$H/origin"
  printf 'hello\n' >"$H/origin/file.txt"; printf 's\n' >"$H/origin/sub/s.txt"
  git -C "$H/origin" add -A; git -C "$H/origin" commit -qm genesis
}
advance() {  # advance <msg> [<branch>] - one more commit on origin's <branch> (main)
  local br="${2:-main}"
  git -C "$H/origin" checkout -q "$br"
  printf '%s\n' "$1" >>"$H/origin/file.txt"; git -C "$H/origin" add -A; git -C "$H/origin" commit -qm "$1"
  git -C "$H/origin" checkout -q main
}
fresh() {  # fresh - a new clone of the home's origin at $H/clone
  rm -rf "$H/clone"
  git clone -q "$H/origin" "$H/clone"
  git_id "$H/clone"
}
local_commit() { commit "$H/clone" "$1.txt" "$1"; }
norm() { LC_ALL=C sed -e "s#$H#HOME#g" "$1"; }
P_RC=0
pull() {  # pull <args...> - the shim from the home; sets P_RC
  local x a=()
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  P_RC=0
  (cd "$H" && LC_ALL=C "$BIN/ac-repo-pull.sh" ${a[@]+"${a[@]}"}) >"$TMP/n.raw" 2>"$TMP/n.err" || P_RC=$?
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.err" >"$TMP/n.err2"
}
says() {  # says <stdout> <label> - exit 0, exactly that line, silent on stderr
  assert_eq "$P_RC:$(cat "$TMP/n.out"):$(cat "$TMP/n.err2")" "0:$1:" "$2"
}
refuses() {  # refuses <stderr> <label> - exit 1, no stdout, exactly that line
  assert_eq "$P_RC:$(cat "$TMP/n.out"):$(cat "$TMP/n.err2")" "1::$1" "$2"
}
origin_sha() { git -C "$H/origin" rev-parse "${1:-main}"; }
short() { git -C "$H/origin" rev-parse --short "${1:-main}"; }
clone_head() { git -C "$H/clone" rev-parse HEAD; }
fetched() { assert_eq "$(git -C "$H/clone" rev-parse refs/remotes/origin/main)" "$(origin_sha)" "$1: the fetch landed origin/main"; }
seed_home

# 2. behind, clean -> ff-sync moves HEAD to origin/main
fresh; advance upstream1
pull HOME/clone
says "synced main -> $(short)" "behind and clean syncs"
assert_eq "$(clone_head)" "$(origin_sha)" "HEAD reached origin main"
# 3. behind and dirty (untracked, modified tracked, staged) -> the fetch lands
#    origin/main, the local branch stays where it was
untracked() { printf 'u\n' >"$H/clone/untracked.txt"; }
modify() { printf 'edit\n' >>"$H/clone/file.txt"; }
stage() { modify; git -C "$H/clone" add -A; }
for dirt in untracked modify stage; do
  fresh; advance "behind-$dirt"; "$dirt"
  was="$(clone_head)"
  pull HOME/clone
  says "fetched only (working tree dirty)" "$dirt is dirty"
  assert_eq "$(clone_head)" "$was" "$dirt: a dirty clone does not move"
  fetched "$dirt"
done
# 5. ahead
fresh; local_commit ahead
was="$(clone_head)"
pull HOME/clone
says "fetched only (local main ahead of origin - nothing to pull)" "ahead"
assert_eq "$(clone_head)" "$was" "ahead: the local commit stays"
# 6. diverged
fresh; advance upstream3; local_commit diverge
was="$(clone_head)"
pull HOME/clone
says "fetched only (main diverged from origin)" "diverged"
assert_eq "$(clone_head)" "$was" "diverged: the local commit stays"
fetched diverged
# 7. detached HEAD
fresh; advance upstream-detached
git -C "$H/clone" checkout -q --detach
was="$(clone_head)"
pull HOME/clone
says "fetched only (detached HEAD)" "detached"
assert_eq "$(clone_head)" "$was" "detached: HEAD stays"
fetched detached
# 8. a checked-out feat/x with no origin counterpart; then pushed and moved on
fresh
git -C "$H/clone" checkout -q -b feat/x
pull HOME/clone
says "fetched only (origin has no feat/x)" "the branch name passes through"
git -C "$H/clone" push -q origin feat/x
advance featmove feat/x
pull HOME/clone
says "synced feat/x -> $(short feat/x)" "a pushed feat/x syncs"
assert_eq "$(clone_head)" "$(origin_sha feat/x)" "feat/x followed origin/feat/x"
# 10. no origin remote; an origin URL at a missing dir
git init -q -b main "$H/noorigin"; git_id "$H/noorigin"; commit "$H/noorigin" f x
pull HOME/noorigin
refuses "ERROR: fetch failed (no origin, or network down)" "no origin"
fresh
git -C "$H/clone" remote set-url origin "$H/nowhere"
pull HOME/clone
refuses "ERROR: fetch failed (no origin, or network down)" "origin missing on disk"
# 11. a bare clone (no fetch refspec, so origin/main never appears)
git clone -q --bare "$H/origin" "$H/bare"
pull HOME/bare
says "fetched only (origin has no main)" "a bare clone"
# 12. root as a subdirectory, relative to the cwd, with a trailing slash; an
#     extra arg is ignored
n=0
for root in HOME/clone/sub clone HOME/clone/; do
  n=$((n + 1))
  fresh; advance "upstream-root$n"
  pull "$root"
  says "synced main -> $(short)" "root given as '$root'"
  assert_eq "$(clone_head)" "$(origin_sha)" "root given as '$root': HEAD reached origin main"
done
fresh; advance upstream-extra
pull HOME/clone junk
says "synced main -> $(short)" "an extra arg is ignored"
# 13. a plain dir, a missing path, a regular file: the argument echoed as given
mkdir -p "$H/plain"; printf 'f\n' >"$H/file.txt"
for root in HOME/plain HOME/plain/ HOME/missing HOME/file.txt; do
  pull "$root"
  refuses "ERROR: not a git repo: $root" "no repo at $root"
done
# 14. no arg, an empty arg
pull
refuses "ERROR: usage: ac-repo-pull.sh <repo-root>" "no arg"
pull ""
refuses "ERROR: usage: ac-repo-pull.sh <repo-root>" "empty arg"
# 15. the CHECKED-OUT branch syncs, never origin/HEAD: `other` moves while main moved too
git -C "$H/origin" branch other main
fresh
git -C "$H/clone" checkout -q other
advance upstream7
advance other1 other
pull HOME/clone
says "synced other -> $(short other)" "the checked-out branch"
assert_eq "$(clone_head)" "$(origin_sha other)" "other followed origin/other"
assert_eq "$(git -C "$H/clone" rev-parse main)" "$(git -C "$H/clone" rev-parse origin/main~1)" "local main was not touched"
# 16. .git/index.lock planted on a behind, clean clone: the merge is what git
#     refuses; status and fetch tolerate the lock
fresh; advance upstream8
: >"$H/clone/.git/index.lock"
was="$(clone_head)"
pull HOME/clone
says "fetched only (fast-forward refused)" "a locked index refuses the ff"
assert_eq "$(clone_head)" "$was" "locked: HEAD stays"
fetched locked
# 17. a root with a byte that is not UTF-8 is refused like any missing path.
pull "HOME/caf"$'\351'
assert_eq "$P_RC:$(cat "$TMP/n.out")" "1:" "non-UTF-8 root refuses, nothing on stdout"
assert_contains "$(cat "$TMP/n.err2")" "ERROR: not a git repo: HOME/caf" "non-UTF-8 root: the entry's refusal"
# `rev-parse --short HEAD` failing after a successful merge is not constructible
# (the merge just wrote HEAD); its `synced <branch> -> ` shape is documented in
# the module header, not pinned here.

# 18. no git on PATH: the first probe fails - the entry's own refusal, never a
#     runtime's stack
fresh
farm="$TMP/nogit"; mkdir -p "$farm"
IFS=: read -ra pathdirs <<<"$PATH"
for d in "${pathdirs[@]}"; do
  for x in "$d"/*; do [ -x "$x" ] && [ ! -e "$farm/$(basename "$x")" ] && ln -s "$x" "$farm/"; done
done 2>/dev/null; rm -f "$farm/git"
n_rc=0; (cd "$H" && PATH="$farm" LC_ALL=C "$BIN/ac-repo-pull.sh" clone) >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.raw"):$(cat "$TMP/n.err")" "1::ERROR: not a git repo: clone" "no git: the entry's own line, no stack"

# 19. git's own diagnostics pass through for show-ref, status and the final
#     rev-parse: under GIT_TRACE=1 each traces once, the quiet probes never
fresh; advance upstream-trace
n_rc=0; (cd "$H" && GIT_TRACE=1 LC_ALL=C "$BIN/ac-repo-pull.sh" clone) >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.raw")" "0:synced main -> $(short)" "GIT_TRACE: the answer is unchanged"
for probe in 'show-ref' 'status --porcelain' 'rev-parse --short HEAD'; do
  assert_eq "$(grep -c "built-in: git $probe" "$TMP/n.err")" "1" "GIT_TRACE: $probe traces once"
done
for probe in fetch merge symbolic-ref merge-base; do
  assert_eq "$(grep -c "built-in: git $probe" "$TMP/n.err")" "0" "GIT_TRACE: $probe stays quiet"
done

# 20. a caller cwd bun cannot enter (a name ending in a backslash): a relative
#     root is still the caller's, never the distro checkout's
fresh; advance upstream-odd
mkdir -p "$H/odd\\"
n_rc=0; (cd "$H/odd\\" && LC_ALL=C "$BIN/ac-repo-pull.sh" ../clone) >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.raw")" "0:synced main -> $(short)" "backslash cwd: the relative root resolved against the caller"
assert_eq "$(clone_head)" "$(origin_sha)" "backslash cwd: the caller's clone moved"

pass
