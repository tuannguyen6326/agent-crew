#!/usr/bin/env bash
# ac-repo-pull.test.sh - fetch + FAST-FORWARD-ONLY sync of a project clone's
# default branch. Never a merge, never a rebase, never a forced move: a
# diverged or dirty clone fetches and reports, nothing else.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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

pass
