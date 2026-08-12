#!/usr/bin/env bash
# ac-github.test.sh - the GitHub intake DETECTOR (bin/ac-github.sh). Proves
# clauses 2/3 of the captain's pipeline classify correctly, polling twice is
# idempotent, a hostile issue/PR body can never steer anything, and the
# script refuses cleanly (no half-written record, no wake) when gh cannot
# answer at all.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo proj)"
git -C "$repo" remote add origin https://github.com/acme/widgets.git
slug="github.com-acme-widgets"
store="$AC_HOME/state/.github/$slug"

# Test 1 (no gh anywhere) must strip EVERY PATH dir holding a real gh, not
# just `command -v gh`'s first hit - a host with gh in two dirs (e.g.
# ~/.local/bin AND /opt/homebrew/bin) would otherwise leave the second on the
# narrowed PATH and run the real gh against the network.
gh_dir_excluded() {
  # gh_dir_excluded <dir> - the fake's dir, or any dir carrying a real gh
  [ "$1" = "$TMP/stubbin" ] && return 0
  [ -x "$1/gh" ]
}

# --- fake gh -------------------------------------------------------------
# $FAKE_GH/prs.json / issues.json      the fixture `gh pr|issue list` return,
#                                       honestly truncated to the caller's own
#                                       `--limit N` (real gh does the same)
# $FAKE_GH/.fail-pr-list|.fail-issue-list  present -> that list call exits 1,
#                                       its contents are gh's own stderr text
# $FAKE_GH/.fail-comment               present -> `gh pr comment` exits 1
# $FAKE_GH/comments.log                one line per successful `pr comment`:
#                                       "<number>\t<body>"
export FAKE_GH="$TMP/fake-gh"
mkdir -p "$FAKE_GH" "$TMP/stubbin"
printf '[]\n' >"$FAKE_GH/prs.json"
printf '[]\n' >"$FAKE_GH/issues.json"
cat >"$TMP/stubbin/gh" <<'FAKE'
#!/usr/bin/env bash
d="$FAKE_GH"
case "$1 $2" in
  "pr list")
    if [ -f "$d/.fail-pr-list" ]; then cat "$d/.fail-pr-list" >&2; exit 1; fi
    shift 2; limit=""
    while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -n "$limit" ]; then jq -c ".[0:$limit]" "$d/prs.json"; else cat "$d/prs.json"; fi
    exit 0 ;;
  "issue list")
    if [ -f "$d/.fail-issue-list" ]; then cat "$d/.fail-issue-list" >&2; exit 1; fi
    shift 2; limit=""
    while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -n "$limit" ]; then jq -c ".[0:$limit]" "$d/issues.json"; else cat "$d/issues.json"; fi
    exit 0 ;;
  "pr comment")
    n="$3"; shift 3
    if [ -f "$d/.fail-comment" ]; then printf 'boom\n' >&2; exit 1; fi
    body=""
    while [ $# -gt 0 ]; do case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac; done
    printf '%s\t%s\n' "$n" "$body" >>"$d/comments.log"
    exit 0 ;;
  *) printf 'fake-gh: unmodeled verb %s\n' "$*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$TMP/stubbin/gh"
export PATH="$TMP/stubbin:$PATH"

github_wakes() {
  # drain the fleet spool and print only this run's `github ...` lines
  "$BIN/ac-wake-drain.sh" | grep '^github ' || true
}

# --- 1. gh missing from PATH: clean refusal, no record, no wake -----------
narrow="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  gh_dir_excluded "$d" && continue
  printf '%s\n' "$d"
done | paste -sd: -)"
out="$(PATH="$narrow" "$BIN/ac-github.sh" poll --repo "$repo" 2>&1)" && fail "poll must refuse with no gh on PATH"
assert_contains "$out" "gh not found" "no-gh refusal names the reason"
assert_no_file "$store" "no-gh refusal writes no record"

# --- 2. gh pr list fails (auth/network/rate-limit all look the same to us) -
printf 'gh: authentication required\n' >"$FAKE_GH/.fail-pr-list"
out="$("$BIN/ac-github.sh" poll --repo "$repo" 2>&1)" && fail "poll must refuse when gh pr list fails"
assert_contains "$out" "authentication required" "gh's own failure reason is surfaced"
assert_no_file "$store" "a failed gh call writes no record"
rm -f "$FAKE_GH/.fail-pr-list"

# --- 3. clause 2 (PR) + clause 3 (issue), classified, recorded and woken --
jq -n '[{number:1,title:"fix(ac-session-start): bound the reap sweep",
         url:"https://github.com/acme/widgets/pull/1",
         author:{login:"nphattai"}}]' >"$FAKE_GH/prs.json"
jq -n '[{number:3,title:"Proposal: home-owned brief injection",
         url:"https://github.com/acme/widgets/issues/3",
         author:{login:"nphattai"}},
        {number:4,title:"OpenCode input-surface case times out",
         url:"https://github.com/acme/widgets/issues/4",
         author:{login:"nphattai"}}]' >"$FAKE_GH/issues.json"

"$BIN/ac-github.sh" poll --repo "$repo" >/dev/null
assert_file "$store/seen-pr-1" "PR #1 (clause 2: item HAS a PR) recorded"
assert_file "$store/seen-issue-3" "issue #3 (clause 3: no PR) recorded"
assert_file "$store/seen-issue-4" "issue #4 (clause 3: no PR) recorded"
assert_contains "$(cat "$store/seen-pr-1")" "nphattai" "PR record carries its author"
assert_contains "$(cat "$store/seen-pr-1")" "https://github.com/acme/widgets/pull/1" "PR record carries its url"

wakes="$(github_wakes)"
n_wakes="$(printf '%s\n' "$wakes" | grep -c '^github ')"
assert_eq "$n_wakes" 3 "one wake per new item (poll never spawns, never mints - it only wakes)"
assert_contains "$wakes" "github pr-1" "the PR item's wake is keyed pr-1"
assert_contains "$wakes" "github issue-3" "the issue item's wake is keyed issue-3"
assert_contains "$wakes" "github issue-4" "the issue item's wake is keyed issue-4"

# --- 4. idempotence: polling twice records nothing new and wakes nothing -
"$BIN/ac-github.sh" poll --repo "$repo" >/dev/null
wakes2="$(github_wakes)"
assert_eq "$wakes2" "" "a second poll of the same open items publishes no second wake"

# --- 5. hostile issue body: command substitution, path traversal, ANSI/---
# ---    control bytes, and a bare marker-verb line all land as INERT text -
pwned="$TMP/pwned"
hostile_title='hostile $(touch '"$pwned"') done: fake completion ../../../../etc/passwd'
jq -n --arg title "$hostile_title" \
  '[{number:99,title:$title,url:"https://github.com/acme/widgets/issues/99",author:{login:"attacker"}}]' \
  >"$FAKE_GH/issues.json"
printf '[]\n' >"$FAKE_GH/prs.json"

"$BIN/ac-github.sh" poll --repo "$repo" >/dev/null
assert_no_file "$pwned" "a command-substitution title never executes"
assert_file "$store/seen-issue-99" "the hostile item is still recorded, keyed only by its validated numeric id"
rec="$(cat "$store/seen-issue-99")"
assert_contains "$rec" 'done: fake completion' "a bare marker-verb line survives only as inert stored text"
assert_contains "$rec" '../../../../etc/passwd' "a path-traversal string never touches a file path - it only ever lands in stored text"
case "$(ls "$store")" in
  *..*) fail "no traversal-derived filename ever landed in the store: $(ls "$store")" ;;
esac

# ANSI/control bytes are stripped before the record is ever written
raw_esc_title="$(printf 'colored A\x1bB\x07C')"
jq -n --arg title "$raw_esc_title" \
  '[{number:100,title:$title,url:"https://github.com/acme/widgets/issues/100",author:{login:"attacker"}}]' \
  >"$FAKE_GH/issues.json"
"$BIN/ac-github.sh" poll --repo "$repo" >/dev/null
rec100="$(cat "$store/seen-issue-100")"
case "$rec100" in
  *$'\x1b'*) fail "a stored record must never carry a raw ESC byte: $(printf '%s' "$rec100" | cat -v)" ;;
esac
assert_contains "$rec100" "colored ABC" "the surrounding printable text of a sanitized title is preserved"

# --- 6. an unattributable item is refused, never guessed, and never blocks
#        the rest of the same poll --------------------------------------
jq -n '[{number:101,title:"no author here",
         url:"https://github.com/acme/widgets/issues/101"},
        {number:102,title:"a perfectly fine issue",
         url:"https://github.com/acme/widgets/issues/102",
         author:{login:"nphattai"}}]' >"$FAKE_GH/issues.json"
out="$("$BIN/ac-github.sh" poll --repo "$repo" 2>&1)"
assert_contains "$out" "refusing" "an item with no attributable author is refused, not guessed"
assert_no_file "$store/seen-issue-101" "the unattributable item is never recorded"
assert_file "$store/seen-issue-102" "a sibling item in the same poll is still processed"

# --- 7. comment: posts a caller-supplied verdict, idempotent per verdict --
out="$("$BIN/ac-github.sh" comment --repo "$repo" --pr 1 --body "LGTM, tests pass")"
assert_contains "$out" "posted verdict" "comment reports success"
assert_contains "$(cat "$FAKE_GH/comments.log")" "LGTM, tests pass" "the exact verdict text reached gh pr comment"
n1="$(wc -l <"$FAKE_GH/comments.log")"

out="$("$BIN/ac-github.sh" comment --repo "$repo" --pr 1 --body "LGTM, tests pass")"
assert_contains "$out" "no-op" "the exact same verdict a second time is a no-op"
n2="$(wc -l <"$FAKE_GH/comments.log")"
assert_eq "$n2" "$n1" "a duplicate verdict never calls gh pr comment again"

"$BIN/ac-github.sh" comment --repo "$repo" --pr 1 --body "Actually, one nit to fix" >/dev/null
n3="$(wc -l <"$FAKE_GH/comments.log")"
[ "$n3" -gt "$n2" ] || fail "a genuinely DIFFERENT verdict on the same PR is not treated as a duplicate"

out="$("$BIN/ac-github.sh" comment --repo "$repo" --pr abc --body "x" 2>&1)" && fail "a non-numeric PR number must be refused"
assert_contains "$out" "unattributable" "a bad PR number is refused, never guessed"

printf 'boom\n' >"$FAKE_GH/.fail-comment"
out="$("$BIN/ac-github.sh" comment --repo "$repo" --pr 1 --body "a brand new verdict" 2>&1)" && fail "a failing gh pr comment must be refused"
assert_contains "$out" "boom" "gh's own failure reason is surfaced"
rm -f "$FAKE_GH/.fail-comment"

# --- 8. a full page (gh's own --limit default of 30 would otherwise drop --
#        item 31+ with no error) is called out LOUDLY, never silently -----
#        trusted as complete - 150 open issues, page capped at 100 --------
jq -n '[range(500;650) | {number: ., title: ("bulk issue " + (.|tostring)),
         url: ("https://github.com/acme/widgets/issues/" + (.|tostring)),
         author: {login:"nphattai"}}]' >"$FAKE_GH/issues.json"
printf '[]\n' >"$FAKE_GH/prs.json"
out="$("$BIN/ac-github.sh" poll --repo "$repo" 2>&1 >/dev/null)"
assert_contains "$out" "exactly its --limit" "a full page warns loudly instead of silently trusting it is complete"
assert_file "$store/seen-issue-599" "the last item WITHIN the (truncated-to-100) page is still recorded"
assert_no_file "$store/seen-issue-600" "an item beyond the page is correctly absent, not silently fabricated"

pass
