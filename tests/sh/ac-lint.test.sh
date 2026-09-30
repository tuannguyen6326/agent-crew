#!/usr/bin/env bash
# ac-lint.test.sh - the lint runner's FILE SELECTION: `--all` lints the whole
# owned set, the default lints only CHANGED files (tracked-diff + untracked) in
# that set, a clean tree lints nothing, plus arg handling. Hermetic: ac-lint cds
# to its own dirname/.., so a copy under a throwaway git repo lints THAT repo.
# One check reads the real tree instead: its `shellcheck source=` directives.
# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v git >/dev/null || { printf 'SKIP: git not available\n'; exit 0; }

repo="$TMP/lintrepo"
mkdir -p "$repo/bin"
cp "$BIN/ac-lint.sh" "$repo/bin/ac-lint.sh"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
lint() { (cd "$repo" && ./bin/ac-lint.sh "$@"); }

# --- arg handling ---
grep -q 'Usage: ac-lint.sh' < <(lint -h) || fail "-h prints usage"
# marker-bounded (repo-deep-review F38): -h must reach the end of its own
# header, not stop mid-list on a stale line-range pin.
grep -q 'AC_LINT_ALLOW_MISSING' < <(lint -h) || fail "-h must print the full header, not a stale line-pinned prefix"
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

# The shell tests and their stress harness live under tests/sh.
mkdir -p "$repo/tests/sh"
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/tests/sh/stress.sh"
out="$(lint 2>&1)" || true
assert_contains "$out" "syntax error: tests/sh/stress.sh" "a changed tests/sh/stress.sh is a lint target"
rm "$repo/tests/sh/stress.sh"
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/tests/sh/bad.test.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm badtest
out="$(lint --all 2>&1)" || true
assert_contains "$out" "syntax error: tests/sh/bad.test.sh" "--all reaches every tests/sh/*.test.sh"

# ac-lint runs shellcheck with -P SCRIPTDIR, so a `source=` directive in the
# REAL owned set is read against its script's own dir; one a move left stale
# stops being followed and lints SC1091. The count keeps a moved glob from
# passing vacuously.
n=0
while IFS=: read -r f _ d; do
  n=$((n + 1))
  t="${d#*source=}"
  [ -e "$ROOT/$(dirname "$f")/$t" ] || fail "$f: 'shellcheck source=$t' does not resolve from its dir"
done < <(cd "$ROOT" && grep -Hn '^# shellcheck source=' bin/*.sh tests/sh/*.test.sh tests/sh/stress.sh)
[ "$n" -gt 0 ] || fail "no shellcheck source= directive found in the owned set"

pass
