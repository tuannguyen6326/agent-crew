#!/usr/bin/env bash
# ac-review-reply.test.sh - bin/ac-review.sh reply's three body forms against
# a REAL dashboard on an ephemeral port: a plain argv string (unchanged), a
# file (`@<path>`) and stdin (`-`). A multi-paragraph "what I changed" used to
# be forced through one quoted argv, so paragraphs got flattened or cut; the
# file/stdin forms must reach the stored session byte-for-byte, newlines
# intact. The same bound the reply route enforces (dashboard/app.ts
# REVIEW_REPLY_MAX_BYTES, 413 past it) is refused by the shim BEFORE a byte is
# sent, naming the cap - and the refusal stores nothing.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }
command -v bun >/dev/null 2>&1 || { printf 'SKIP: bun not installed\n'; exit 0; }

make_home
DB="$BIN/ac-dashboard.sh"
trap '"$DB" stop >/dev/null 2>&1 || true; cleanup' EXIT

port=$((18000 + RANDOM % 2000))
while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
"$DB" start --port "$port" >/dev/null
export AC_DASH_PORT="$port"

artifact="$AC_HOME/data/report.html"
printf '<html><body><h1>r</h1></body></html>\n' >"$artifact"
session="$artifact.session.json"

review() { "$BIN/ac-review.sh" "$@"; }
stored() { jq -r ".replies[$1].text" "$session"; }
count() { jq '.replies | length' "$session"; }

# ---- plain argv keeps working -------------------------------------------
out="$(review reply "$artifact" "one line")"
assert_contains "$out" "replied" "argv reply is accepted"
assert_eq "$(stored 0)" "one line" "argv reply is stored verbatim"

# ---- @<file>: three paragraphs, blank lines between, newlines preserved --
body="$TMP/reply.md"
printf 'First paragraph: what changed.\n\nSecond paragraph:\n- a bullet\n- another\n\nThird paragraph, the why.\n' >"$body"
out="$(review reply "$artifact" "@$body")"
assert_contains "$out" "replied" "file reply is accepted"
assert_eq "$(count)" "2" "file reply stored as one record"
# The server trims the outer whitespace only (the trailing newline); every
# inner newline and blank line survives.
want="$(printf 'First paragraph: what changed.\n\nSecond paragraph:\n- a bullet\n- another\n\nThird paragraph, the why.')"
assert_eq "$(stored 1)" "$want" "file reply keeps its paragraphs and newlines"

# ---- `-`: the same body over stdin --------------------------------------
out="$(review reply "$artifact" - <"$body")"
assert_contains "$out" "replied" "stdin reply is accepted"
assert_eq "$(count)" "3" "stdin reply stored as one record"
assert_eq "$(stored 2)" "$want" "stdin reply keeps its paragraphs and newlines"

# ---- --agent-reply takes the same forms (the poll+reply shape the skill
# teaches): the reply lands BEFORE the poll holds, so ending the session
# from outside releases the poll once the record is on disk.
review poll "$artifact" --after 0 --agent-reply "@$body" >"$TMP/poll.out" 2>&1 &
pid=$!
for _ in $(seq 1 40); do [ "$(count)" = 4 ] && break; sleep 0.25; done
review end "$artifact" >/dev/null
wait "$pid" || true
assert_eq "$(count)" "4" "--agent-reply @file stored one record"
assert_eq "$(stored 3)" "$want" "--agent-reply @file keeps its newlines"
review open "$artifact" >/dev/null

# ---- over the cap: refused by the shim, named, nothing stored -------------
big="$TMP/big.md"
head -c $((1024 * 1024 + 1)) /dev/zero | tr '\0' 'x' >"$big"
rc=0; out="$(review reply "$artifact" "@$big" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an over-cap reply must be refused"
assert_contains "$out" "1048576" "the refusal names the byte cap"
assert_contains "$out" "REVIEW_REPLY_MAX_BYTES" "the refusal cites the server constant"
assert_eq "$(count)" "4" "an over-cap reply stores nothing"
# The server holds the same line on its own: a direct POST past the cap is a
# 413, so a caller bypassing the shim cannot grow the session past it either.
q="path=$(jq -rn --arg v "$AC_HOME" '$v|@uri')&file=$(jq -rn --arg v "$artifact" '$v|@uri')"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary "@$big" "http://127.0.0.1:$port/api/review/reply?$q")"
assert_eq "$code" "413" "the reply route refuses an over-cap body with 413"
assert_eq "$(count)" "4" "the 413 stores nothing"

# ---- a missing file and an empty body are refused, not sent ---------------
rc=0; out="$(review reply "$artifact" "@$TMP/nope.md" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a missing reply file must be refused"
assert_contains "$out" "no such reply file" "missing file is named"
rc=0; out="$(review reply "$artifact" - </dev/null 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an empty stdin reply must be refused"
assert_eq "$(count)" "4" "refusals store nothing"

pass
