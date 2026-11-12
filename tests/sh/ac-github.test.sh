#!/usr/bin/env bash
# ac-github.test.sh - the GitHub intake DETECTOR (bin/ac-github.sh). Proves
# clauses 2/3 of the captain's pipeline classify correctly, polling twice is
# idempotent, a hostile issue/PR body can never steer anything, and the
# script refuses cleanly (no half-written record, no wake) when gh cannot
# answer at all.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# A verdict quoting a local error can carry the operator's home path or a
# credential-bearing URL - a comment PUBLISHES, so it goes through
# redactPublish first (one boundary, src/lib.ts).
"$BIN/ac-github.sh" comment --repo "$repo" --pr 1 \
  --body "failed at /Users/operator/lab/run.log after push to https://x:tok9@github.com/a/b" >/dev/null
redacted="$(tail -1 "$FAKE_GH/comments.log")"
case "$redacted" in *"/Users/operator"*) fail "a published comment must not carry a home path" ;; esac
case "$redacted" in *tok9*) fail "a published comment must not carry URL credentials" ;; esac
assert_contains "$redacted" "~/lab/run.log" "the path is redacted to ~, the tail intact"

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

# --- the entry, row by row ----------------------------------------------------
# One side root $H: a home at $H/home, a repo at $H/repo whose origin is
# https://github.com/acme/widgets.git, a no-origin repo at $H/noorig, the fake
# gh's lists and log at $H/gh. This half's fake gh (argv, cwd and stdin logged)
# and a `date` stub fixing `+%s%N` per row come FIRST on PATH; HOME=$H/u,
# TMPDIR=$H/tmp, LC_ALL=C, cwd $H. `HOME` in an argument or an env value is $H,
# and stdout, stderr, the store and spool trees under state/ (a record's pid
# spelled PID, a temp's suffix RANDOM) and the gh log are read with $H spelled
# HOME.
H="$TMP/side"
mkdir -p "$TMP/dstub" "$TMP/datestub"
cat >"$TMP/dstub/gh" <<'FAKE'
#!/usr/bin/env bash
# $FAKE_GH/{prs,issues}.json answer the lists (an array cut to --limit, anything
# else as written); .warn is printed on stderr before a list; .fail-<pr|issue>-list
# fails that list with its text; .fail-comment fails a comment; every call is
# logged with its cwd; .read-stdin copies stdin to $FAKE_GH/stdin.
d="$FAKE_GH"
{ printf 'gh'; printf ' [%s]' "$@"; printf ' cwd=%s\n' "$PWD"; } >>"$d/log"
[ ! -f "$d/.read-stdin" ] || cat >>"$d/stdin"
case "$1 $2" in
  "pr list" | "issue list")
    f="$d/prs.json"; [ "$1" = pr ] || f="$d/issues.json"
    [ ! -f "$d/.warn" ] || cat "$d/.warn" >&2
    if [ -f "$d/.fail-$1-list" ]; then cat "$d/.fail-$1-list" >&2; exit 1; fi
    limit=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -n "$limit" ] && jq -se 'length == 1 and (.[0] | type) == "array"' "$f" >/dev/null 2>&1; then jq -c ".[0:$limit]" "$f"; else cat "$f"; fi
    exit 0 ;;
  "pr comment")
    if [ -f "$d/.fail-comment" ]; then printf 'boom\n' >&2; printf 'and its stdout\n'; exit 1; fi
    exit 0 ;;
esac
exit 2
FAKE
cat >"$TMP/dstub/date" <<'STUB'
#!/bin/sh
case "$1" in
  +%s%N) [ -z "${DATE_FAIL:-}" ] || exit "$DATE_FAIL"; printf '%s\n' "$STUB_STAMP" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
chmod +x "$TMP/dstub/gh" "$TMP/dstub/date"
cp "$TMP/dstub/date" "$TMP/datestub/date"
# No jq anywhere: only what the entry needs before its jq check.
mkdir -p "$TMP/nojq"
for t in bash dirname bun; do ln -s "$(command -v "$t")" "$TMP/nojq/$t"; done
cp "$TMP/dstub/gh" "$TMP/dstub/date" "$TMP/nojq/"
seed_side() {
  mkdir -p "$H/home" "$H/gh" "$H/u" "$H/tmp"; : >"$H/gh/log"
  printf '[]\n' >"$H/gh/prs.json"; printf '[]\n' >"$H/gh/issues.json"
  git init -q -b main "$H/repo"; git -C "$H/repo" remote add origin https://github.com/acme/widgets.git
  git -C "$H/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git init -q -b main "$H/noorig"
}
ghfile() { printf "$2" >"$H/gh/$1"; }      # ghfile <name> <printf format> - one fake gh input
ghrm() { rm -f "$H/gh/$1"; }
lists() { printf '%s\n' "$1" >"$H/gh/prs.json"; printf '%s\n' "$2" >"$H/gh/issues.json"; }
origin() { git -C "$H/repo" remote set-url origin "$1"; }
HOMELESS=0
NOHOMEVAR=0
GH_ENV=()
ROW=0
run() {  # run <args...> - sets rc; stdout in $TMP/n.out, stderr in $TMP/n.err2, the state tree in $TMP/n.tree, the gh log in $TMP/n.log; cwd is $H (or GH_CWD under it)
  local x v
  local a=() e=(LC_ALL=C FAKE_GH="$H/gh" TMPDIR="$H/tmp" PATH="$TMP/dstub:$PATH")
  ROW=$((ROW + 1))
  e+=(STUB_STAMP="$((1700000000 + ROW))123456789")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$H/home")
  [ "$NOHOMEVAR" = 1 ] || e+=(HOME="$H/u")
  for x in ${GH_ENV[@]+"${GH_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  rc=0
  (cd "$H/${GH_CWD:-}" && { [ -z "${GH_GONE:-}" ] || { mkdir gone && cd gone && rmdir "$PWD"; }; } && env -u AC_HOME -u HOME -u CDPATH "${e[@]}" "$BIN/ac-github.sh" ${a[@]+"${a[@]}"}) <"${GH_STDIN:-/dev/null}" >"$TMP/n.raw" 2>"$TMP/n.err" || rc=$?
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.err" >"$TMP/n.err2"
  snap >"$TMP/n.snap"; norm "$TMP/n.snap" >"$TMP/n.tree"
  norm "$H/gh/log" >"$TMP/n.log"
}
norm() { LC_ALL=C sed -e "s#$H#HOME#g" "$1"; }
snap() {  # every store and spool entry under state/, byte order: name, mode, bytes
  [ -d "$H/home/state" ] || return 0
  (cd "$H/home/state" && find . -mindepth 1 \( -path './.github*' -o -path './.wake-*' \) | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s %s\n' "$f" "$(ls -ld "$f" | cut -c1-10)" | LC_ALL=C sed -E -e 's/\.[0-9]+\.([0-9]{6}) /.PID.\1 /' -e 's/\.wake-tmp\.[A-Za-z0-9]{8} /.wake-tmp.RANDOM /'
    [ ! -f "$f" ] || [ ! -r "$f" ] || cat "$f"
  done)
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
shim_tree() { cat "$TMP/n.tree"; }
store_ls() { ls "$H/home/state/.github/$1" 2>/dev/null | tr '\n' ' '; }
clear_state() { rm -rf "$H/home/state"; }
resync() { rm -rf "$H/home/state"; : >"$H/gh/log"; }
seed_side
NO_HOME_TEXT="$(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)"

# 1. usage: no verb, -h, --help print the two usage lines on stdout, exit 0;
#    any other verb is refused
for v in "" -h --help "--help extra"; do
  run $v
  assert_eq "$rc" "0" "row 1: usage '$v' exits 0"
  assert_eq "$(shim_out)" "usage: ac-github.sh poll --repo <path>
       ac-github.sh comment --repo <path> --pr <n> --body <text>" "row 1: the usage lines for '$v'"
done
run bogus
assert_eq "$rc" "1" "row 1: an unknown verb exits 1"
assert_eq "$(shim_err)" "ERROR: unknown verb: bogus" "row 1: unknown verb"

# 2. flags and the repo checks, each refusal before any gh call: no --repo, a
#    dangling --repo, an empty one, an unknown flag, `--repo=`, a missing dir,
#    a repo with no origin; the comment verb's flag grammar likewise
run poll
assert_eq "$(shim_err)" "ERROR: usage: ac-github.sh poll --repo <path>" "row 2: no --repo"
run poll --repo
assert_eq "$(shim_err)" "ERROR: --repo needs a value" "row 2: a dangling --repo"
run poll --repo HOME/repo --repo
assert_eq "$(shim_err)" "ERROR: --repo needs a value" "row 2: a second, dangling --repo"
run poll --repo ''
assert_eq "$(shim_err)" "ERROR: usage: ac-github.sh poll --repo <path>" "row 2: an empty --repo"
run poll --bogus
assert_eq "$(shim_err)" "ERROR: unknown flag: --bogus (ac-github.sh poll takes --repo <path>)" "row 2: unknown flag"
run poll --repo=HOME/repo
assert_eq "$(shim_err)" "ERROR: unknown flag: --repo=HOME/repo (ac-github.sh poll takes --repo <path>)" "row 2: --repo= is no flag"
run poll --repo HOME/nope
assert_eq "$(shim_err)" "ERROR: not a git repo: HOME/nope" "row 2: a missing dir"
assert_eq "$rc" "1" "row 2: a refusal exits 1"
run poll --repo HOME/noorig
assert_eq "$(shim_err)" "ERROR: could not resolve the origin remote of HOME/noorig" "row 2: no origin"
run comment
assert_eq "$(shim_err)" "ERROR: usage: ac-github.sh comment --repo <path> --pr <n> --body <text>" "row 2: comment usage"
run comment --repo HOME/repo --pr
assert_eq "$(shim_err)" "ERROR: --pr needs a value" "row 2: a dangling --pr"
run comment --body
assert_eq "$(shim_err)" "ERROR: --body needs a value" "row 2: a dangling --body"
run comment --repo HOME/repo --pr 1 --nope x
assert_eq "$(shim_err)" "ERROR: unknown flag: --nope (ac-github.sh comment takes --repo <path> --pr <n> --body <text>)" "row 2: comment unknown flag"
run comment --repo HOME/noorig --pr 1 --body x
assert_eq "$(shim_err)" "ERROR: could not resolve the origin remote of HOME/noorig" "row 2: comment with no origin"
assert_eq "$(cat "$H/gh/log")" "" "row 2: no refusal ever reached gh"

# 3. no gh on PATH (every dir holding a gh removed), no jq on PATH: refused,
#    nothing written, gh never run
GH_ENV=("PATH=$TMP/datestub:$narrow")
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: gh not found on PATH - cannot poll GitHub" "row 3: no gh (poll)"
run comment --repo HOME/repo --pr 1 --body x
assert_eq "$(shim_err)" "ERROR: gh not found on PATH - cannot comment" "row 3: no gh (comment)"
GH_ENV=("PATH=$TMP/nojq")
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: jq not found on PATH - cannot poll GitHub" "row 3: no jq"
GH_ENV=()
assert_eq "$(shim_tree)" "" "row 3: nothing written"

# 4. a list gh fails: its merged text (trailing blank lines dropped) in the
#    refusal, no store; the issue list fails after the PR list answered
ghfile .fail-pr-list 'gh: authentication required\nsecond line\n\n\n'
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: gh pr list failed: gh: authentication required
second line" "row 4: the pr list failure"
ghrm .fail-pr-list
ghfile .fail-issue-list 'gh: rate limited\n'
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: gh issue list failed: gh: rate limited" "row 4: the issue list failure"
ghrm .fail-issue-list
assert_eq "$(shim_tree)" "" "row 4: a failed list writes no store"

# 5. a list is read from gh's stdout alone: a Warning line gh prints on stderr
#    ahead of a good list does not make it malformed
ghfile .warn 'Warning: an update is available\n'
lists '[{"number":5,"title":"t5","url":"u5","author":{"login":"l"}}]' '[]'
run poll --repo HOME/repo
assert_eq "$rc" "0" "row 5: a stderr notice does not fail the poll"
assert_eq "$(shim_out)" "ac-github.sh poll: recorded pr-5 and woke the crewchief" "row 5: the list is read past gh's warning"
ghrm .warn
lists '[]' '[]'
resync

# 6. clause 2 then clause 3: one PR, two issues - three seen files, three
#    wakes in one poll (.000000 to .000002), stdout lines in that order; a
#    second poll records and wakes nothing
lists '[{"number":1,"title":"fix it","url":"https://github.com/acme/widgets/pull/1","author":{"login":"nphattai"}}]' \
  '[{"number":3,"title":"","url":"u3","author":{"login":"a"}},{"number":4,"title":"t4","url":"u4","author":{"login":"b"}}]'
run poll --repo HOME/repo
assert_eq "$(shim_out)" "ac-github.sh poll: recorded pr-1 and woke the crewchief
ac-github.sh poll: recorded issue-3 and woke the crewchief
ac-github.sh poll: recorded issue-4 and woke the crewchief" "row 6: three items"
assert_contains "$(shim_tree)" "== ./.github/github.com-acme-widgets/seen-issue-3 -rw-r--r--
issue #3:  (a) u3" "row 6: an empty title leaves two spaces"
assert_contains "$(shim_tree)" "== ./.wake-spool/$((1700000000 + ROW))123456789.PID.000002 -rw-------
$(printf '%s\tgithub\tissue-4\tissue #4: t4 (b) u4' "$((1700000000 + ROW))")" "row 6: the third record of the poll"
run poll --repo HOME/repo
assert_eq "$(shim_out)" "" "row 6: the second poll is silent"
assert_eq "$(ls "$H/home/state/.wake-spool" | wc -l | tr -d ' ')" 3 "row 6: and wakes nobody"

# 7. the item lines: jq's tostring spelling decides the number (a JSON string
#    "7" passes; 1.5, -1, 1E+2, 1E+21, 1E+20, 7.0 and null are refused;
#    100000000000000000000 passes whole); no url / no login refused; control
#    bytes cleaned, an invalid UTF-8 byte repaired by jq
clear_state
items7="$(cat <<'JSON'
[{"number":"7","title":"str","url":"u7","author":{"login":"l"}},
 {"number":1.5,"title":"t","url":"u","author":{"login":"l"}},
 {"number":-1,"title":"t","url":"u","author":{"login":"l"}},
 {"number":1e2,"title":"t","url":"u","author":{"login":"l"}},
 {"number":1e21,"title":"t","url":"u","author":{"login":"l"}},
 {"number":1e20,"title":"t","url":"u","author":{"login":"l"}},
 {"number":100000000000000000000,"title":"t","url":"u","author":{"login":"l"}},
 {"number":7.0,"title":"t","url":"u","author":{"login":"l"}},
 {"number":2,"title":"no url","author":{"login":"l"}},
 {"number":8,"title":"no login","url":"u8","author":{}},
 {"number":4,"title":"a\tb\nc\u0001d\u007fe\u001ff","url":"u4\u001b","author":{"login":"l\u0007m"}},
 {"number":5,"title":"bad@FF@byte","url":"u5","author":{"login":"l"}},
 {"number":6,"title":"x\u00a0y","url":"u6","author":{"login":"l"}},
 {"title":"nonum","url":"u","author":{"login":"l"}}]
JSON
)"
issues7() { lists '[]' "$items7"; LC_ALL=C sed -i '' "s/@FF@/$(printf '\377')/" "$H/gh/issues.json"; }
issues7
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ac-github.sh poll: refusing an unattributable issue (bad number 1.5) - never guess
ac-github.sh poll: refusing an unattributable issue (bad number -1) - never guess
ac-github.sh poll: refusing an unattributable issue (bad number 1E+2) - never guess
ac-github.sh poll: refusing an unattributable issue (bad number 1E+21) - never guess
ac-github.sh poll: refusing an unattributable issue (bad number 1E+20) - never guess
ac-github.sh poll: refusing an unattributable issue (bad number 7.0) - never guess
ac-github.sh poll: refusing issue #2 - missing author or url, never guess
ac-github.sh poll: refusing issue #8 - missing author or url, never guess
ac-github.sh poll: refusing an unattributable issue (bad number null) - never guess" "row 7: every refusal, in order"
assert_eq "$(shim_out)" "ac-github.sh poll: recorded issue-7 and woke the crewchief
ac-github.sh poll: recorded issue-100000000000000000000 and woke the crewchief
ac-github.sh poll: recorded issue-4 and woke the crewchief
ac-github.sh poll: recorded issue-5 and woke the crewchief
ac-github.sh poll: recorded issue-6 and woke the crewchief" "row 7: every record, in order"
assert_eq "$(cat "$H/home/state/.github/github.com-acme-widgets/seen-issue-4")" "issue #4: abcdef (lm) u4" "row 7: control bytes cleaned"
assert_eq "$(cat "$H/home/state/.github/github.com-acme-widgets/seen-issue-5")" "issue #5: bad$(printf '\357\277\275')byte (l) u5" "row 7: jq's U+FFFD"
#    a capture of several JSON texts whose last is an array passes the type
#    check and each text is extracted - jq's exit is its LAST text's, so one it
#    cannot measure or walk ahead of an array costs only jq's own lines
clear_state
lists '[]' '{"a":1} [{"number":30,"title":"t","url":"u30","author":{"login":"l"}}]'
run poll --repo HOME/repo
assert_eq "$rc" "0" "row 7: a multi-text capture exits 0"
assert_eq "$(shim_out)" "ac-github.sh poll: recorded issue-30 and woke the crewchief" "row 7: a multi-text capture"
lists '[]' 'true []'
run poll --repo HOME/repo
assert_eq "$rc $(cat "$TMP/n.raw")" "0 " "row 7: exit 0, nothing recorded"

# 8. a full page: exactly 100 is loud; 99 is quiet
clear_state
page() { jq -n "[range(500;$1) | {number: ., title: \"bulk\", url: (\"u\" + tostring), author: {login: \"l\"}}]" >"$H/gh/issues.json"; printf '[]\n' >"$H/gh/prs.json"; }
page 600
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ac-github.sh poll: the issue list came back at exactly its --limit 100 - there may be MORE open issues than this poll saw; re-run with a higher limit to be sure none are missed" "row 8: exactly 100 is loud"
clear_state; page 599
run poll --repo HOME/repo
assert_eq "$(shim_err)" "" "row 8: 99 is quiet"

# 9. the slug: ssh, https, ssh://, userinfo, a relative path and a trailing
#    slash each name their store dir; a URL that strips to nothing is no slug
clear_state; lists '[]' '[]'
for url in git@github.com:acme/widgets.git https://github.com/acme/widgets.git ssh://git@github.com/acme/widgets https://u:tok@host/o/r.git ./x.git host:a/b.git/; do
  origin "$url"
  run poll --repo HOME/repo
done
assert_eq "$(LC_ALL=C ls -A "$H/home/state/.github" | tr '\n' ' ')" ".-x github.com-acme-widgets host-a-b.git- host-o-r " "row 9: the store dirs"
origin 'x://'
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: could not resolve the origin remote of HOME/repo" "row 9: an empty slug"
# the substitution's trailing-LF strip comes AFTER the suffix cuts: an LF right
# before .git keys the same store as the plain URL; a URL that is only an LF
# there strips to nothing
origin "$(printf 'https://host/owner/repo\n.git')"
run poll --repo HOME/repo
[ -d "$H/home/state/.github/host-owner-repo" ] || fail "row 9: an LF before .git keys the plain store"
[ ! -e "$H/home/state/.github/host-owner-repo"$'\n' ] || fail "row 9: no LF-named store"
origin "$(printf 'https://\n.git')"
run poll --repo HOME/repo
assert_eq "$(shim_err)" "ERROR: could not resolve the origin remote of HOME/repo" "row 9: an LF-only slug is none"
origin https://github.com/acme/widgets.git

# 10. comment: posted; the same text again a no-op with no gh call; a
#     different text posts; `007` kept as typed; refusals; gh's merged
#     failure text
clear_state; lists '[]' '[]'
run comment --repo HOME/repo --pr 1 --body 'LGTM, tests pass'
assert_eq "$rc" "0" "row 10: a post exits 0"
assert_eq "$(shim_out)" "ac-github.sh comment: posted verdict on PR #1" "row 10: posted"
assert_contains "$(shim_tree)" "commented-pr-1-3103439218 -rw-r--r--
LGTM, tests pass" "row 10: the donefile, named by cksum"
run comment --repo HOME/repo --pr 1 --body 'LGTM, tests pass'
assert_eq "$(shim_out)" "ac-github.sh comment: this exact verdict is already posted on PR #1 - no-op" "row 10: the duplicate"
assert_eq "$(grep -c '^gh \[pr\] \[comment\]' "$TMP/n.log")" "1" "row 10: the duplicate never reached gh"
run comment --repo HOME/repo --pr 1 --body 'Actually, one nit to fix'
assert_eq "$(shim_out)" "ac-github.sh comment: posted verdict on PR #1" "row 10: a different text posts"
run comment --repo HOME/repo --pr 007 --body zero
assert_contains "$(store_ls github.com-acme-widgets)" "commented-pr-007-" "row 10: 007 kept"
run comment --repo HOME/repo --pr abc --body x
assert_eq "$(shim_err)" "ERROR: refusing an unattributable PR number: abc" "row 10: a bad PR number"
run comment --repo HOME/repo --pr -1 --body x
assert_eq "$(shim_err)" "ERROR: refusing an unattributable PR number: -1" "row 10: a signed PR number"
run comment --repo HOME/repo --pr 1 --body ''
assert_eq "$(shim_err)" "ERROR: usage: ac-github.sh comment --repo <path> --pr <n> --body <text>" "row 10: an empty body"
ghfile .fail-comment ''
run comment --repo HOME/repo --pr 1 --body 'a brand new verdict'
assert_eq "$(shim_err)" "ERROR: gh pr comment failed for PR #1: boom
and its stdout" "row 10: gh's merged failure text"
ghrm .fail-comment
assert_no_file "$H/home/state/.github/github.com-acme-widgets/commented-pr-1-$(printf 'a brand new verdict' | cksum | awk '{print $1}')" "row 10: no donefile for a failed post"

# 11. redaction before the hash: HOME, foreign /Users and /home homes,
#     userinfo; HOME is a BRE (`.` matches any char); a sed that refuses (an
#     empty HOME, one holding `|`) ends the run with nothing posted; HOME
#     unset is refused
run comment --repo HOME/repo --pr 50 --body 'at HOME/u/x then /Users/operator/lab/run.log, /home/op/z via https://x:tok9@github.com/a/b'
assert_contains "$(cat "$H/gh/log")" "[at ~/x then ~/lab/run.log, ~/z via https://***@github.com/a/b]" "row 11: redacted"
GH_ENV=(HOME=/Users.op)
run comment --repo HOME/repo --pr 51 --body 'at /UsersXop/k'
assert_contains "$(cat "$H/gh/log")" "[at ~/k]" "row 11: HOME is a BRE"
GH_ENV=(HOME=)
run comment --repo HOME/repo --pr 52 --body x
[ "$rc" -ne 0 ] || fail "row 11: an empty HOME must end the run"
GH_ENV=('HOME=/Users/a|b')
run comment --repo HOME/repo --pr 52 --body x
[ "$rc" -ne 0 ] || fail "row 11: a HOME holding | must end the run"
case "$(cat "$TMP/n.log")" in *"[52]"*) fail "row 11: a refused redaction posts nothing" ;; esac
GH_ENV=()
NOHOMEVAR=1
run comment --repo HOME/repo --pr 53 --body x
NOHOMEVAR=0
assert_eq "$rc" "1" "row 11: HOME unset exits 1"
assert_eq "$(shim_err)" "ERROR: HOME is not set" "row 11: HOME unset is refused"

# 12. a body byte that is not UTF-8: Bun decodes argv, so U+FFFD is what is
#     posted and what names the file, under either locale
GH_ENV=(LC_ALL=en_US.UTF-8)
run comment --repo HOME/repo --pr 60 --body "bad$(printf '\377')byte"
assert_eq "$rc" "0" "row 12: posted under UTF-8"
assert_contains "$(cat "$H/gh/log")" "[60] [--body] [bad$(printf '\357\277\275')byte]" "row 12: U+FFFD is posted"
GH_ENV=()
run comment --repo HOME/repo --pr 61 --body "bad$(printf '\377')byte"
assert_eq "$rc" "0" "row 12: posted under C"
assert_contains "$(store_ls github.com-acme-widgets)" "commented-pr-61-$(printf 'bad\357\277\275byte' | cksum | awk '{print $1}')" "row 12: the file names the U+FFFD body"
resync

# 13. homeless: poll runs both gh lists and then refuses (no store); comment
#     refuses after the redaction; an AC_HOME that cannot be entered is named
HOMELESS=1
run poll --repo HOME/repo
assert_eq "$rc" "1" "row 13: a homeless poll exits 1"
assert_eq "$(shim_err)" "ERROR: $NO_HOME_TEXT" "row 13: homeless poll"
assert_eq "$(tail -n 2 "$TMP/n.log" | cut -d' ' -f1-3)" "gh [pr] [list]
gh [issue] [list]" "row 13: gh ran before the home was consulted"
run comment --repo HOME/repo --pr 70 --body x
assert_eq "$(shim_err)" "ERROR: $NO_HOME_TEXT" "row 13: homeless comment"
GH_ENV=(AC_HOME=HOME/missing)
run poll --repo HOME/repo
assert_eq "$rc" "1" "row 13: an unenterable home exits 1"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: HOME/missing" "row 13: an unenterable home is named"
GH_ENV=(); HOMELESS=0
[ ! -e "$H/missing" ] || fail "row 13: no home minted"

# 14. the publish is UNGUARDED: a seam that empties the spool between two
#     publishes leaves only the second record; a seam that makes state/
#     read-only fails the first publish (exit 1, no seen file,
#     the temp left behind); a seam hook or a `date` that fails ends the run
#     with its own status
clear_state
lists '[]' '[{"number":80,"title":"a","url":"u","author":{"login":"l"}},{"number":81,"title":"b","url":"u","author":{"login":"l"}}]'
printf '#!/bin/sh\nrm -rf "$AC_HOME/state/.wake-spool"\n' >"$TMP/seam-rm"
printf '#!/bin/sh\nchmod 555 "$AC_HOME/state"\n' >"$TMP/seam-ro"
printf '#!/bin/sh\nexit 4\n' >"$TMP/seam-4"
chmod +x "$TMP/seam-rm" "$TMP/seam-ro" "$TMP/seam-4"
GH_ENV=(AC_WAKE_SEAM_AT=after-write "AC_WAKE_SEAM_RUN=$TMP/seam-rm")
run poll --repo HOME/repo
assert_eq "$(ls "$H/home/state/.wake-spool" | sed -E 's/\.[0-9]+\./.PID./')" "$((1700000000 + ROW))123456789.PID.000001" "row 14: only the second record survives"
clear_state
if [ "$(id -u)" != 0 ]; then
  GH_ENV=(AC_WAKE_SEAM_AT=after-write "AC_WAKE_SEAM_RUN=$TMP/seam-ro")
  run poll --repo HOME/repo
  chmod 755 "$H/home/state"
  assert_eq "$rc" "1" "row 14: a publish that fails exits 1"
  case "$(shim_tree)" in *seen-*) fail "row 14: no seen file after a failed publish" ;; esac
  assert_contains "$(shim_tree)" ".wake-tmp.RANDOM -rw-------" "row 14: the temp is left behind"
fi
clear_state
GH_ENV=(AC_WAKE_SEAM_AT=after-write "AC_WAKE_SEAM_RUN=$TMP/seam-4")
run poll --repo HOME/repo
assert_eq "$rc" 4 "row 14: the hook's status"
clear_state
GH_ENV=(DATE_FAIL=3)
run poll --repo HOME/repo
assert_eq "$rc" 3 "row 14: date's status"
case "$(shim_tree)" in *seen-*|*wake-tmp*) fail "row 14: a failed date writes nothing" ;; esac
GH_ENV=()

# 15. gh inherits the caller's stdin; a relative --repo is the caller's (the
#     cwd gh runs in)
clear_state; lists '[]' '[]'
ghfile .read-stdin ''
printf 'fed to gh\n' >"$TMP/stdin15"
GH_STDIN="$TMP/stdin15" run poll --repo repo
assert_eq "$(cat "$H/gh/stdin")" "fed to gh" "row 15: the caller's stdin reached gh"
ghrm .read-stdin
assert_contains "$(cat "$TMP/n.log")" "gh [issue] [list] [--state] [open] [--limit] [100] [--json] [number,title,url,author] cwd=HOME/repo" "row 15: gh ran in the repo"

# 16. a seen file that cannot be written: refused after its wake, exit 1
clear_state
lists '[]' '[{"number":90,"title":"a","url":"u","author":{"login":"l"}}]'
dangle() { mkdir -p "$H/home/state/.github/github.com-acme-widgets"; ln -s "$H/nowhere/x" "$H/home/state/.github/github.com-acme-widgets/seen-issue-90"; }
dangle
run poll --repo HOME/repo
assert_eq "$rc" "1" "row 16: an unwritable seen file exits 1"
assert_eq "$(shim_err)" "ERROR: cannot write HOME/home/state/.github/github.com-acme-widgets/seen-issue-90: ENOENT" "row 16: the unwritable seen file is named"
assert_contains "$(shim_tree)" "$(printf 'issue-90\tissue #90: a (l) u')" "row 16: the wake was published first"

# 17. a caller cwd Bun cannot name (a trailing backslash): a relative --repo is
#     still resolved against it, never against the distro root
resync; lists '[]' '[]'
bsdir() { mkdir -p "$H/cw\\"; }
bsdir
GH_CWD='cw\' run poll --repo ../repo
assert_contains "$(cat "$TMP/n.log")" "cwd=HOME/repo" "row 17: gh ran in the caller's ../repo"
#     A caller cwd that has no name (removed under it) holds nothing: a
#     relative --repo is no git repo, even when the shim's root is one whose
#     origin gh would answer for (the shim's own cd adds a getcwd line, so
#     stderr is asserted by hand)
lab="$TMP/lab17"
mkdir -p "$lab/bin"; cp "$BIN"/*.sh "$lab/bin/"; ln -s "$ROOT/src" "$lab/src"
git init -q -b main "$lab"; git -C "$lab" remote add origin https://github.com/distro/self.git
resync
GH_GONE=1 BIN="$lab/bin" run poll --repo .
assert_eq "$rc" 1 "row 17: poll from a nameless cwd"
assert_contains "$(shim_err)" "ERROR: not a git repo: ." "row 17: poll refuses"
GH_GONE=1 BIN="$lab/bin" run comment --repo . --pr 5 --body verdict
assert_eq "$rc" 1 "row 17: comment from a nameless cwd"
assert_contains "$(shim_err)" "ERROR: not a git repo: ." "row 17: comment refuses"
assert_eq "$(cat "$H/gh/log")" "" "row 17: gh never ran"

# 18. gh's cwd is the directory named, whatever cd's grammar would make of it:
#     an exported CDPATH, a <path> starting with `-`
clear_state
GH_ENV=("CDPATH=HOME")
run poll --repo repo
assert_eq "$rc" "0" "row 18: CDPATH does not disturb the poll"
assert_contains "$(cat "$TMP/n.log")" "cwd=HOME/repo" "row 18: CDPATH - gh ran in the repo"
dashrepo() { git init -q -b main "$H/-r"; git -C "$H/-r" remote add origin git@h:o/r.git; }
dashrepo
GH_ENV=()
run poll --repo -r
assert_eq "$rc" "0" "row 18: a dash-led path"
assert_contains "$(cat "$TMP/n.log")" "cwd=HOME/-r" "row 18: gh ran in the dash-led path"
#     an origin holding a byte that is not UTF-8 is refused before gh runs
resync
origin "https://h/a$(printf '\377')b.git"
run poll --repo HOME/repo
assert_eq "$rc" 1 "row 18: a non-UTF-8 origin"
assert_eq "$(shim_err)" "ERROR: origin remote of HOME/repo holds a byte that is not UTF-8: h-a$(printf '\377')b" "row 18: the non-UTF-8 origin is named"
assert_eq "$(cat "$H/gh/log")" "" "row 18: before gh"
origin https://github.com/acme/widgets.git
#     a gh on PATH that is not executable is no gh
mkdir -p "$TMP/nxgh"; printf '#!/bin/sh\nexit 0\n' >"$TMP/nxgh/gh"; chmod 644 "$TMP/nxgh/gh"
GH_ENV=("PATH=$TMP/datestub:$TMP/nxgh:$narrow")
run poll --repo HOME/repo
assert_eq "$rc" "1" "row 18: a non-executable gh"
assert_eq "$(shim_err)" "ERROR: gh not found on PATH - cannot poll GitHub" "row 18: a non-executable gh is not found"
#     a TMPDIR that cannot hold the capture
GH_ENV=(TMPDIR=HOME/missing-tmp)
run poll --repo HOME/repo
GH_ENV=()
assert_eq "$rc" "1" "row 18: no TMPDIR"
assert_eq "$(shim_err)" "ERROR: cannot capture gh's output under HOME/missing-tmp: ENOENT" "row 18: the TMPDIR is named"
# bun itself may park a `bun` entry under TMPDIR under load; only the capture's own names count
assert_eq "$(ls -A "$H/tmp" | /usr/bin/grep '^ac-github\.' || true)" "" "row 18: no capture file is ever left in TMPDIR"

pass
