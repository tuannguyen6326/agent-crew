#!/usr/bin/env bash
# ac-tests-exec-bit.test.sh - contract test asserting every tracked
# tests/*.test.sh file carries the exec bit (git mode 100755). Each of these
# files starts with a #!/usr/bin/env bash shebang - meant to be run directly
# (./tests/x.test.sh) - so a file tracked at 100644 reports a FAKE
# Permission-denied FAILURE under any runner that execs it directly, distinct
# from and indistinguishable (to that runner) from a real test failure. See
# repo-knowledge/agent-crew.md for the fake-failure history this guards.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# check_tests_exec_bit <repo> - exit 0 if every tracked tests/*.test.sh under
# <repo> is mode 100755, 1 (with a reason on stderr per offender) otherwise.
# The pathspec is QUOTED so git expands it relative to <repo>, not the shell
# relative to CWD.
check_tests_exec_bit() {
  local repo="$1" rc=0 mode obj stage path
  while read -r mode obj stage path; do
    [ -n "$path" ] || continue
    if [ "$mode" != 100755 ]; then
      printf 'NOT-EXECUTABLE(%s): tracked mode %s\n' "$path" "$mode" >&2
      rc=1
    fi
  done < <(git -C "$repo" ls-files -s -- 'tests/*.test.sh')
  return "$rc"
}

# --- Positive: every tracked tests/*.test.sh in THIS repo is 100755 ----------

check_tests_exec_bit "$ROOT" || fail "a tracked tests/*.test.sh lacks the exec bit"

# --- Negative: a file reverted to 100644 must fail the guard -----------------

repo="$(make_repo)"
mkdir -p "$repo/tests"
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/tests/a.test.sh"
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/tests/b.test.sh"
chmod +x "$repo/tests/a.test.sh" "$repo/tests/b.test.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm 'add tests, both executable'
check_tests_exec_bit "$repo" || fail "expected an all-100755 synthetic repo to pass"

chmod -x "$repo/tests/b.test.sh"
git -C "$repo" update-index --chmod=-x -- tests/b.test.sh
git -C "$repo" commit -qm 'simulated regression: drop the exec bit on b.test.sh'
assert_fails check_tests_exec_bit "$repo"

pass
