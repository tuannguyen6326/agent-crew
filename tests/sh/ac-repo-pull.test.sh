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

# --- differential: src/repo-pull.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-repo-pull.sh under bash vs src/repo-pull.ts through bin/ac-repo-pull.sh)
# HELD-CONSTANT: two homes seeded alike ($OH for the oracle, $NH for the shim) - each with its own origin and, per row, a FRESH clone (a run mutates the clone), every commit stamped with one fixed date so the shas agree - argv (HOME spelled per side), cwd (the home), LC_ALL=C on both sides; exit status, stdout and stderr (the home path spelled HOME) compared whole, plus the clone's HEAD, origin/main and porcelain status after the run.
obin="$(make_oracle_bin ac-repo-pull)"
OH="$TMP/oh"; NH="$TMP/nh"
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each home
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
seed_home() {  # one origin on main; sub/ is tracked so a subdirectory root exists in every clone
  mkdir -p "$H/origin/sub"
  git init -q -b main "$H/origin"
  git -C "$H/origin" config user.email test@test; git -C "$H/origin" config user.name test
  printf 'hello\n' >"$H/origin/file.txt"; printf 's\n' >"$H/origin/sub/s.txt"
  git -C "$H/origin" add -A; gitc -C "$H/origin" commit -qm genesis
}
advance() {  # advance <msg> [<branch>] - one more fixed-date commit on origin's <branch> (main)
  local br="${2:-main}"
  git -C "$H/origin" checkout -q "$br"
  printf '%s\n' "$1" >>"$H/origin/file.txt"; git -C "$H/origin" add -A; gitc -C "$H/origin" commit -qm "$1"
  git -C "$H/origin" checkout -q main
}
fresh() {  # fresh - a new clone of the home's origin at $H/clone
  rm -rf "$H/clone"
  git clone -q "$H/origin" "$H/clone"
  git -C "$H/clone" config user.email test@test; git -C "$H/clone" config user.name test
}
local_commit() {  # local_commit <msg> - one fixed-date commit in the clone
  printf '%s\n' "$1" >"$H/clone/$1.txt"; git -C "$H/clone" add -A; gitc -C "$H/clone" commit -qm "$1"
}
run_side() {  # run_side <bin> <home> <prefix> <args...> - HOME in an arg is that side's home; cwd is the home
  local bin="$1" h="$2" p="$3" x; shift 3
  local a=()
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h" && LC_ALL=C "$bin/ac-repo-pull.sh" ${a[@]+"${a[@]}"}) >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$2#HOME#g" "$1"; }
same() {  # same <args...> - oracle on $OH and shim on $NH answer byte-identically
  local o_rc=0 n_rc=0
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$BIN" "$NH" n "$@" || n_rc=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 4)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
same_clone() {  # same_clone [<path under the home>] - HEAD, origin/main and the porcelain status agree
  local r="${1:-clone}" q o n
  for q in "rev-parse HEAD" "rev-parse --verify -q refs/remotes/origin/main" "status --porcelain"; do
    o="$(git -C "$OH/$r" $q 2>/dev/null || printf none)"
    n="$(git -C "$NH/$r" $q 2>/dev/null || printf none)"
    assert_eq "$n" "$o" "differential clone $r: $q"
  done
}
origin_sha() { git -C "$NH/origin" rev-parse "${1:-main}"; }
short() { git -C "$NH/origin" rev-parse --short "${1:-main}"; }
clone_head() { git -C "$NH/clone" rev-parse HEAD; }
both seed_home

# 1. up to date: `synced` although nothing moved (W2 - the operator cannot tell
#    "already current" from "moved"; the dashboard shows the line verbatim)
both fresh
same HOME/clone
assert_eq "$(shim_out)" "synced main -> $(short)" "up to date still says synced"
assert_eq "$(clone_head)" "$(origin_sha)" "nothing moved"
same_clone
# 2. behind, clean -> ff-sync moves HEAD to origin/main
both fresh
both advance upstream1
same HOME/clone
assert_eq "$(shim_out)" "synced main -> $(short)" "behind and clean syncs"
assert_eq "$(clone_head)" "$(origin_sha)" "HEAD reached origin main"
same_clone
# 3. behind, untracked file -> dirty; HEAD untouched, origin/main fetched
both fresh
both advance upstream2
untracked() { printf 'u\n' >"$H/clone/untracked.txt"; }
both untracked
same HOME/clone
assert_eq "$(shim_out)" "fetched only (working tree dirty)" "an untracked file is dirty"
[ "$(clone_head)" != "$(origin_sha)" ] || fail "a dirty clone must not move"
assert_eq "$(git -C "$NH/clone" rev-parse refs/remotes/origin/main)" "$(origin_sha)" "the fetch still happened"
same_clone
# 4. behind, modified tracked; behind, staged -> dirty
both fresh
modify() { printf 'edit\n' >>"$H/clone/file.txt"; }
both modify
same HOME/clone
assert_eq "$(shim_out)" "fetched only (working tree dirty)" "a modified tracked file is dirty"
same_clone
both fresh
stage() { printf 'edit\n' >>"$H/clone/file.txt"; git -C "$H/clone" add -A; }
both stage
same HOME/clone
assert_eq "$(shim_out)" "fetched only (working tree dirty)" "a staged change is dirty"
same_clone
# 5. ahead; ahead + untracked says ahead (ancestry is probed before dirtiness)
both fresh
both local_commit ahead
same HOME/clone
assert_eq "$(shim_out)" "fetched only (local main ahead of origin - nothing to pull)" "ahead"
same_clone
both untracked
same HOME/clone
assert_eq "$(shim_out)" "fetched only (local main ahead of origin - nothing to pull)" "ahead wins over dirty"
same_clone
# 6. diverged; diverged + dirty says diverged
both fresh
both advance upstream3
both local_commit diverge
same HOME/clone
assert_eq "$(shim_out)" "fetched only (main diverged from origin)" "diverged"
same_clone
both untracked
same HOME/clone
assert_eq "$(shim_out)" "fetched only (main diverged from origin)" "diverged wins over dirty"
same_clone
# 7. detached HEAD
both fresh
detach() { git -C "$H/clone" checkout -q --detach; }
both detach
same HOME/clone
assert_eq "$(shim_out)" "fetched only (detached HEAD)" "detached"
same_clone
# 8. a checked-out feat/x with no origin counterpart; then pushed
both fresh
feat() { git -C "$H/clone" checkout -q -b feat/x; }
both feat
same HOME/clone
assert_eq "$(shim_out)" "fetched only (origin has no feat/x)" "the branch name passes through"
same_clone
pushfeat() { git -C "$H/clone" push -q origin feat/x; }
both pushfeat
same HOME/clone
assert_eq "$(shim_out)" "synced feat/x -> $(short feat/x)" "a pushed feat/x syncs (no-op)"
same_clone
# 9. unborn HEAD with origin configured -> `diverged` (W1 - both merge-base
#    probes fail on the missing local ref and the second failure reads as diverged)
unborn() { git init -q -b main "$H/unborn"; git -C "$H/unborn" remote add origin "$H/origin"; }
both unborn
same HOME/unborn
assert_eq "$(shim_out)" "fetched only (main diverged from origin)" "an unborn branch is misreported as diverged"
# 10. no origin remote; an origin URL at a missing dir
noorigin() { git init -q -b main "$H/noorigin"; printf 'x\n' >"$H/noorigin/f"; git -C "$H/noorigin" add -A; gitc -C "$H/noorigin" commit -qm x; }
both noorigin
same HOME/noorigin
assert_eq "$(shim_err)" "ERROR: fetch failed (no origin, or network down)" "no origin"
assert_eq "$(shim_out)" "" "nothing on stdout"
both fresh
nowhere() { git -C "$H/clone" remote set-url origin "$H/nowhere"; }
both nowhere
same HOME/clone
assert_eq "$(shim_err)" "ERROR: fetch failed (no origin, or network down)" "origin missing on disk"
same_clone
# 11. a bare clone (no fetch refspec, so origin/main never appears)
bare() { git clone -q --bare "$H/origin" "$H/bare"; }
both bare
same HOME/bare
assert_eq "$(shim_out)" "fetched only (origin has no main)" "a bare clone"
# 12. root as a subdirectory, relative to the cwd, with a trailing slash
both fresh
both advance upstream4
same HOME/clone/sub
assert_eq "$(shim_out)" "synced main -> $(short)" "a subdirectory root"
same_clone
both fresh
both advance upstream5
same clone
assert_eq "$(shim_out)" "synced main -> $(short)" "a root relative to the cwd"
same_clone
both fresh
both advance upstream6
same HOME/clone/
assert_eq "$(shim_out)" "synced main -> $(short)" "a trailing slash"
same_clone
# 13. a plain dir, a missing path, a regular file: the argument echoed as given
plain() { mkdir -p "$H/plain"; printf 'f\n' >"$H/file.txt"; }
both plain
same HOME/plain
assert_eq "$(shim_err)" "ERROR: not a git repo: HOME/plain" "a plain dir"
same HOME/plain/
assert_eq "$(shim_err)" "ERROR: not a git repo: HOME/plain/" "the trailing slash is echoed"
same HOME/missing
assert_eq "$(shim_err)" "ERROR: not a git repo: HOME/missing" "a missing path"
same HOME/file.txt
assert_eq "$(shim_err)" "ERROR: not a git repo: HOME/file.txt" "a regular file"
# 14. no arg, an empty arg; an extra arg is ignored
same
assert_eq "$(shim_err)" "ERROR: usage: ac-repo-pull.sh <repo-root>" "no arg"
same ""
assert_eq "$(shim_err)" "ERROR: usage: ac-repo-pull.sh <repo-root>" "empty arg"
both fresh
same HOME/clone junk
assert_eq "$(shim_out)" "synced main -> $(short)" "an extra arg is ignored"
same_clone
# 15. the CHECKED-OUT branch syncs, never origin/HEAD: `other` moves while main moved too
mkother() { git -C "$H/origin" branch other main; }
both mkother
both fresh
other() { git -C "$H/clone" checkout -q other; }
both other
both advance upstream7
both advance other1 other
same HOME/clone
assert_eq "$(shim_out)" "synced other -> $(short other)" "the checked-out branch"
assert_eq "$(clone_head)" "$(origin_sha other)" "other followed origin/other"
assert_eq "$(git -C "$NH/clone" rev-parse main)" "$(git -C "$NH/clone" rev-parse origin/main~1)" "local main was not touched"
same_clone
# 16. .git/index.lock planted on a behind, clean clone: the merge is what git
#     refuses; status and fetch tolerate the lock (both sides spawn the same git)
both fresh
both advance upstream8
lock() { : >"$H/clone/.git/index.lock"; }
both lock
same HOME/clone
assert_eq "$(shim_out)" "fetched only (fast-forward refused)" "a locked index refuses the ff"
same_clone
# 17. Named divergence: a root with a byte that is not UTF-8. Bun's argv
#     decodes it to U+FFFD, so the port cannot echo the byte the original does;
#     exit status and stdout agree, the refusal's text differs in that byte.
o_rc=0; (cd "$OH" && LC_ALL=C "$obin/ac-repo-pull.sh" "$OH/caf"$'\351') >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (cd "$NH" && LC_ALL=C "$BIN/ac-repo-pull.sh" "$NH/caf"$'\351') >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "1 1" "non-UTF-8 root: both refuse"
assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "non-UTF-8 root: nothing on stdout"
assert_eq "$(norm "$TMP/o.err" "$OH")" "ERROR: not a git repo: HOME/caf"$'\351' "non-UTF-8 root: the original echoes the byte"
assert_eq "$(norm "$TMP/n.err" "$NH")" "ERROR: not a git repo: HOME/caf"$'\357\277\275' "non-UTF-8 root: the port prints U+FFFD"
# `rev-parse --short HEAD` failing after a successful merge is not constructible
# (the merge just wrote HEAD); its `synced <branch> -> ` shape is documented in
# the module header, not pinned here.

pass
