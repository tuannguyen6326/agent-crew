#!/usr/bin/env bash
# ac-push-gate.test.sh - the pre-push privacy gate: a clean range passes, a
# private identifier in a DIFF, a MESSAGE, or an AUTHOR ident refuses, hook
# mode reads git's stdin ref lines, and the missing-pattern-file behavior is
# permissive by default and fail-closed under AC_PUSH_GATE_REQUIRE=1.
# Patterns here are SYNTHETIC (acme-internal) - the real pattern file lives
# outside the repo by design (bin/ac-push-gate.sh header owns the contract).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

gate="$BIN/ac-push-gate.sh"
repo="$(make_repo)"
pats="$TMP/push-gate.patterns"
printf '# synthetic client floor\nacme-internal\n\ndev@secretcorp\n' > "$pats"
export AC_PUSH_GATE_PATTERNS="$pats"

commit_file() { # <repo> <file> <content> <msg> [author-ident]
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=crew -c user.email=crew@test \
    commit -q ${5:+--author="$5"} -m "$4"
}

base="$(git -C "$repo" rev-parse HEAD)"

# --- check mode: clean range passes -----------------------------------------
commit_file "$repo" clean.txt "nothing to see" "a clean change"
rc=0; ( cd "$repo" && "$gate" check "$base..HEAD" ) 2>"$TMP/o1" || rc=$?
assert_eq "$rc" "0" "clean range passes"
assert_contains "$(cat "$TMP/o1")" "floor scan" "a pass still names itself a floor"

# --- a private identifier in a DIFF refuses, case-insensitively -------------
commit_file "$repo" leak.txt "ref: ACME-Internal ticket 42" "innocent message"
rc=0; ( cd "$repo" && "$gate" check "$base..HEAD" ) 2>"$TMP/o2" || rc=$?
assert_eq "$rc" "1" "identifier in a diff refuses"
assert_contains "$(cat "$TMP/o2")" "REFUSED" "refusal says so"
assert_contains "$(cat "$TMP/o2")" "ACME-Internal" "refusal shows the offending line"
git -C "$repo" reset -q --hard "$base"

# --- a private identifier in the MESSAGE alone refuses ----------------------
commit_file "$repo" ok.txt "fine content" "fixes the acme-internal outage"
rc=0; ( cd "$repo" && "$gate" check "$base..HEAD" ) || rc=$?
assert_eq "$rc" "1" "identifier in a commit message refuses"
git -C "$repo" reset -q --hard "$base"

# --- a private identifier in the AUTHOR ident alone refuses -----------------
commit_file "$repo" ok2.txt "fine content" "a clean message" "Dev <dev@secretcorp.example>"
rc=0; ( cd "$repo" && "$gate" check "$base..HEAD" ) || rc=$?
assert_eq "$rc" "1" "identifier in an author ident refuses"
git -C "$repo" reset -q --hard "$base"

# --- hook mode: git's stdin ref lines, clean and dirty ----------------------
zeros=0000000000000000000000000000000000000000
commit_file "$repo" h.txt "clean hook content" "hook-mode change"
head_sha="$(git -C "$repo" rev-parse HEAD)"
rc=0; printf 'refs/heads/main %s refs/heads/main %s\n' "$head_sha" "$base" \
  | ( cd "$repo" && "$gate" hook ) || rc=$?
assert_eq "$rc" "0" "hook mode passes a clean pushed range"

commit_file "$repo" h2.txt "acme-internal residue" "another change"
head_sha="$(git -C "$repo" rev-parse HEAD)"
rc=0; printf 'refs/heads/main %s refs/heads/main %s\n' "$head_sha" "$zeros" \
  | ( cd "$repo" && "$gate" hook ) 2>"$TMP/o3" || rc=$?
assert_eq "$rc" "1" "hook mode scans FULL history on a zero remote sha and refuses"
rc=0; printf 'refs/heads/gone %s refs/heads/gone %s\n' "$zeros" "$head_sha" \
  | ( cd "$repo" && "$gate" hook ) || rc=$?
assert_eq "$rc" "0" "hook mode skips a branch deletion (nothing outgoing)"
git -C "$repo" reset -q --hard "$base"

# --- missing pattern file: permissive default, fail-closed when required ----
rc=0; ( cd "$repo" && AC_PUSH_GATE_PATTERNS="$TMP/absent" "$gate" check HEAD ) 2>"$TMP/o4" || rc=$?
assert_eq "$rc" "0" "no pattern file passes by default (public user)"
assert_contains "$(cat "$TMP/o4")" "nothing to scan" "the permissive pass says why"
rc=0; ( cd "$repo" && AC_PUSH_GATE_PATTERNS="$TMP/absent" AC_PUSH_GATE_REQUIRE=1 "$gate" check HEAD ) 2>"$TMP/o5" || rc=$?
assert_eq "$rc" "1" "AC_PUSH_GATE_REQUIRE=1 refuses a missing pattern file"
assert_contains "$(cat "$TMP/o5")" "AC_PUSH_GATE_REQUIRE" "the strict refusal names the pin"

pass
