#!/usr/bin/env bash
# ac-lint.test.sh - the lint runner's FILE SELECTION: `--all` lints the whole
# owned set, the default lints only CHANGED files (tracked-diff + untracked) in
# that set, a clean tree lints nothing, plus arg handling. Hermetic: ac-lint cds
# to its own dirname/.., so a copy under a throwaway git repo lints THAT repo.
# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v git >/dev/null || { printf 'SKIP: git not available\n'; exit 0; }

repo="$TMP/lintrepo"
mkdir -p "$repo/bin"
cp "$BIN/ac-lint.sh" "$repo/bin/ac-lint.sh"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
lint() { (cd "$repo" && ./bin/ac-lint.sh "$@"); }

# --- arg handling ---
lint -h | grep -q 'Usage: ac-lint.sh' || fail "-h prints usage"
# marker-bounded (repo-deep-review F38): -h must reach the end of its own
# header, not stop mid-list on a stale line-range pin.
lint -h | grep -q 'AC_LINT_ALLOW_MISSING' || fail "-h must print the full header, not a stale line-pinned prefix"
rc=0; lint bogus >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 "an unknown arg exits 2"

# A committed CLEAN baseline (ac-lint.sh + one good script).
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/bin/good.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm base

# Clean tree: the default lints nothing.
out="$(lint 2>&1)"
case "$out" in *"no changed lint targets"*) ;; *) fail "clean tree -> no changed targets (got: $out)" ;; esac

# An UNTRACKED bad script (unclosed `if` -> bash -n fails) is a CHANGE the
# default catches.
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/bin/bad.sh"
rc=0; lint >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the default must catch a changed (untracked) syntax error"

# Once that bad file is COMMITTED and unchanged, the default no longer lints it
# (clean tree) - but --all still reaches it.
git -C "$repo" add -A
git -C "$repo" commit -qm bad
rc=0; lint >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 "the default skips an unchanged committed file (even a broken one)"
rc=0; lint --all >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--all lints the whole set, incl. the committed bad file"

pass
