#!/usr/bin/env bash
# ac-follow.test.sh - transcript renderer: text, tool calls, results,
# errors, clipping, the exact bytes of every record shape; follow mode
# (waiting, tail-on-attach, appends, session switch); meta resolution errors
# for non-claude/missing tasks.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

fx="$TMP/session.jsonl"
long="$(head -c 2000 /dev/zero | tr '\0' x)"
cat >"$fx" <<EOF
{"type":"user","message":{"content":"read the brief and begin"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the spec now."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bash tests/greet.test.sh"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"ALL PASS (14 cases)"}],"is_error":false}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"boom"}],"is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"$long"}}]}}
EOF

out="$("$BIN/ac-follow.sh" --render "$fx")"
assert_contains "$out" "user: read the brief" "user line"
assert_contains "$out" "Reading the spec now." "assistant text"
assert_contains "$out" "tool Bash" "tool call named"
assert_contains "$out" "ALL PASS (14 cases)" "tool result"
assert_contains "$out" "ERR boom" "error result marked"
assert_contains "$out" "chars]" "huge payloads clipped"

# Byte-exact render of every record shape. The BOM line, a non-user string
# message, a null message, a non-JSON line and a blank line print nothing;
# CRLF or a lone CR ends a line; tool input is Python-style JSON (", " and
# ": ", non-ASCII raw); truthiness is Python's (an is_error of [] is not an
# error); clipping counts code points, so the emoji is one of the 1500 kept.
fx2="$TMP/shapes.jsonl"
x1499="$(head -c 1499 /dev/zero | tr '\0' x)"
u2001="$(head -c 2001 /dev/zero | tr '\0' u)"
{
  printf '\357\273\277{"type":"user","message":{"content":"bom"}}\n'
  printf '{"type":"assistant","message":{"content":"not a user"}}\n'
  printf '{"type":"user","message":null}\n'
  printf 'not json\n\n'
  printf '{"type":"user","message":{"content":"crlf"}}\r\n'
  printf '{"type":"user","message":{"content":"cr1"}}\r{"type":"user","message":{"content":"cr2"}}\n'
  printf '{"type":"user","message":{"content":"%s"}}\n' "$u2001"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":""},{"type":"text","text":true},{"type":"thinking","thinking":"hidden"}]}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"s":"\\u00e9\\t\\u0001\\"\\\\/","n":2,"ok":false,"z":null,"l":[1,"x"],"o":{}}}]}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use"},{"type":"tool_use","name":null,"input":null}]}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"ALL "},"skip",{"type":"image"},{"type":"text","text":"PASS"}]},{"type":"tool_result"},{"type":"tool_result","content":"soft","is_error":[]},{"type":"tool_result","content":"hard","is_error":"no"}]}}\n'
  printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"%s\\ud83d\\ude00yy"}]}}\n' "$x1499"
} >"$fx2"
{
  printf '\nuser: crlf\n\nuser: cr1\n\nuser: cr2\n'
  printf '\nuser: %s...[+1 chars]\n' "${u2001:0:2000}"
  printf 'aTrue'
  printf '\ntool Edit {"s": "\303\251\\t\\u0001\\"\\\\/", "n": 2, "ok": false, "z": null, "l": [1, "x"], "o": {}}\n'
  printf '\ntool ? {}\n'
  printf '\ntool None null\n'
  printf -- '-> ALL PASS\n-> None\n-> soft\nERR hard\n'
  printf -- '-> %s\360\237\230\200...[+2 chars]\n' "$x1499"
  printf '\n'
} >"$TMP/shapes.want"
"$BIN/ac-follow.sh" --render "$fx2" >"$TMP/shapes.out"
cmp -s "$TMP/shapes.want" "$TMP/shapes.out" \
  || fail "render bytes differ: $(diff "$TMP/shapes.want" "$TMP/shapes.out" | head -20)"

# A record whose block is not an object ends the render there, exit 1, with
# what was already printed kept and no closing newline.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"before"},7]}}' \
  '{"type":"user","message":{"content":"never"}}' >"$TMP/crash.jsonl"
rc=0
"$BIN/ac-follow.sh" --render "$TMP/crash.jsonl" >"$TMP/crash.out" 2>/dev/null || rc=$?
assert_eq "$rc" "1" "a malformed block fails the render"
printf 'before' | cmp -s - "$TMP/crash.out" \
  || fail "the render stops at the malformed block, got: $(od -c "$TMP/crash.out" | head -3)"

# Meta resolution: non-claude refused, missing meta refused.
printf 'worktree=/tmp/x\nharness=fake\n' >"$AC_HOME/state/f1.meta"
assert_fails "$BIN/ac-follow.sh" f1
assert_fails "$BIN/ac-follow.sh" nosuch

# Follow mode, against the real renderer. The followed dir sits under the
# transcript root the pane's claude wrote to - CLAUDE_CONFIG_DIR's, not a
# hard-wired ~/.claude. It waits, saying so once, for the first transcript (a
# hidden or non-.jsonl name is not one), shows only the last 15 records of one
# first seen past 200000 bytes, streams appends, and switches to a newer
# transcript.
fdir="$TMP/cfg/projects/-tmp-wt-x"
printf 'worktree=/tmp/wt.x\nharness=claude\n' >"$AC_HOME/state/f2.meta"
env -u AC_CLAUDE_TRANSCRIPT_ROOT CLAUDE_CONFIG_DIR="$TMP/cfg" "$BIN/ac-follow.sh" f2 \
  >"$TMP/follow.out" 2>"$TMP/follow.err" &
fpid=$!
stop_follow() { pkill -P "$fpid" 2>/dev/null || true; kill "$fpid" 2>/dev/null || true; }
trap 'stop_follow; cleanup' EXIT
seen() {
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF -- "$1" "$TMP/follow.out" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "the follower never printed '$1': $(cat "$TMP/follow.out" "$TMP/follow.err")"
}
seen "waiting for the first transcript in $fdir ..."
mkdir -p "$fdir"
printf '{"type":"user","message":{"content":"hidden"}}\n' >"$fdir/.h.jsonl"
printf '{"type":"user","message":{"content":"notes"}}\n' >"$fdir/notes.txt"
sleep 1.5
pad="$(head -c 12000 /dev/zero | tr '\0' p)"
for i in $(seq 1 20); do
  printf '{"type":"user","pad":"%s","message":{"content":"r%s"}}\n' "$pad" "$i"
done >"$TMP/big.jsonl"
mv "$TMP/big.jsonl" "$fdir/s1.jsonl"
seen "user: r20"
printf '{"type":"user","message":{"content":"appended"}}\n' >>"$fdir/s1.jsonl"
seen "user: appended"
printf '{"type":"user","message":{"content":"forked"}}\n' >"$fdir/s2.jsonl"
seen "user: forked"
# A transcript rewritten shorter is read again from its start.
printf '{"type":"user","message":{"content":"t"}}\n' >"$fdir/s2.jsonl"
seen "user: t"
stop_follow
wait "$fpid" 2>/dev/null || true
trap cleanup EXIT
{
  printf 'waiting for the first transcript in %s ...\n' "$fdir"
  printf '\n-- session: s1.jsonl --\n'
  for i in $(seq 6 20); do printf '\nuser: r%s\n' "$i"; done
  printf '\nuser: appended\n'
  printf '\n-- session: s2.jsonl --\n\nuser: forked\n\nuser: t\n'
} >"$TMP/follow.want"
cmp -s "$TMP/follow.want" "$TMP/follow.out" \
  || fail "follow mode printed: $(diff "$TMP/follow.want" "$TMP/follow.out" | head -20)"
assert_contains "$(cat "$TMP/follow.err")" "following f2 ($fdir)" "follows the transcripts under CLAUDE_CONFIG_DIR"

# A reader that stops early (`| head`) ends the render silently, as SIGPIPE did.
for i in $(seq 1 5000); do printf '{"type":"user","message":{"content":"line %s"}}\n' "$i"; done >"$TMP/many.jsonl"
err="$( { "$BIN/ac-follow.sh" --render "$TMP/many.jsonl" | head -c1 >/dev/null; } 2>&1 || true)"
assert_eq "$err" "" "an early-closed pipe prints no error"

pass
