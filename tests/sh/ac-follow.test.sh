#!/usr/bin/env bash
# ac-follow.test.sh - transcript renderer: text, tool calls, results,
# errors, clipping, the exact bytes of every record shape; follow mode
# (waiting, tail-on-attach, appends, session switch); meta resolution errors
# for non-claude/missing tasks.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# --- resolution and refusals, row by row --------------------------------------
# Each row runs the shim in a world rebuilt from nothing ($XW: home/state,
# cwd/, tr/ the transcript root, hh/ the HOME), cwd $XW/cwd (deleted first
# where the row says), stdin /dev/null. A run that is still following once its
# stdout holds the row's sentinel (or after 10 s) is TERMed, so a follow row
# reads the resolution and the first poll, never a wall clock.
XW="$TMP/xw"
XLC=C; XHOMELESS=0; XE=""; XU=""; XPATH="$PATH"; XGONE=0; XN_RC=0; XROOT="$XW/tr"
xrun() {  # xrun <world fn> <sentinel> <args...> - the shim in a fresh world; sets XN_RC
  local wf="$1" sent="$2" pid i=0 rc=0 x
  shift 2
  "$wf"
  local u=(-u AC_HOME -u HOME -u AC_CLAUDE_TRANSCRIPT_ROOT -u CLAUDE_CONFIG_DIR -u LANG -u LC_CTYPE -u CDPATH -u AC_FLEET_STATE -u AC_SCOPE)
  local e=()
  for x in "PATH=$XPATH" "LC_ALL=$XLC" "HOME=$XW/hh" "AC_CLAUDE_TRANSCRIPT_ROOT=$XROOT" "AC_HOME=$XW/home"; do
    case " $XU " in *" ${x%%=*} "*) continue ;; esac
    [ "$XHOMELESS" = 0 ] || [ "${x%%=*}" != AC_HOME ] || continue
    e+=("$x")
  done
  for x in $XE; do e+=("$x"); done
  ( cd "$XW/cwd" || exit 97
    [ "$XGONE" = 0 ] || rm -rf "$XW/cwd"
    exec env "${u[@]}" "${e[@]}" "$BIN/ac-follow.sh" ${@+"$@"}
  ) </dev/null >"$TMP/xn.out" 2>"$TMP/xn.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    if [ -n "$sent" ] && grep -qF -- "$sent" "$TMP/xn.out"; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  # The braces' stderr takes the shell's own notice for a run TERM ended.
  { wait "$pid"; } 2>/dev/null || rc=$?
  # From a deleted cwd the shim's bash prints its own getcwd lines; they are
  # the shell's, not the entry's.
  if [ "$XGONE" = 1 ]; then
    grep -av -e '^shell-init: error retrieving current directory' -e '^chdir: error retrieving current directory' "$TMP/xn.err" >"$TMP/xn.err.kept" || true
    mv "$TMP/xn.err.kept" "$TMP/xn.err"
  fi
  XN_RC=$rc
}
xrefuse() {  # xrefuse <stderr> <world fn> <args...> - exit 1, no stdout, exactly <stderr>
  local want="$1" wf="$2"
  shift 2
  xrun "$wf" '' ${@+"$@"}
  assert_eq "$XN_RC:$(cat "$TMP/xn.out"):$(cat "$TMP/xn.err")" "1::$want" "follow refusal for '$*'"
}
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err"; }
xseed() { rm -rf "$XW"; mkdir -p "$XW/home/state" "$XW/cwd" "$XW/tr" "$XW/hh"; }
xmeta() { printf '%b' "$2" >"$XW/home/state/$1.meta"; }   # xmeta <id> <meta lines, printf %b>
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XWAIT='waiting for the first transcript in'

# 1. --render: the usage, a missing or non-regular file, a file rendered byte
#    for byte (extra words ignored, a link to a file counts), an unreadable
#    file, and a relative path from a cwd that has no name.
w_render() {
  xseed
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash","input":{"a":"é"}}]}}' >"$XW/cwd/t.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"x"}}' >"$XW/cwd/locked.jsonl"
  chmod 000 "$XW/cwd/locked.jsonl"
  ln -s t.jsonl "$XW/cwd/link.jsonl"
  cp "$XW/cwd/t.jsonl" "$XW/abs.jsonl"
}
xrendered() {  # xrendered <label> <args...> - t.jsonl's render, exit 0, silent on stderr
  local label="$1"; shift
  xrun w_render '' "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" $'0:\nuser: hi\nok\ntool Bash {"a": "é"}:' "row 1: $label"
}
xrendered "the render, byte for byte" --render t.jsonl
xrendered "words after the path are ignored" --render t.jsonl extra words
xrendered "a link to a regular file counts" --render "$XW/cwd/link.jsonl"
XGONE=1 xrendered "an absolute path from a cwd that has no name" --render "$XW/abs.jsonl"
if [ "$(id -u)" != 0 ]; then
  xrun w_render '' --render locked.jsonl
  assert_eq "$XN_RC:$(xout)" "1:" "row 1: an unreadable transcript fails"
fi
xrefuse "ERROR: no such transcript: nope.jsonl" w_render --render nope.jsonl
xrefuse "ERROR: no such transcript: $XW/cwd" w_render --render "$XW/cwd"
XGONE=1 xrefuse "ERROR: no such transcript: t.jsonl" w_render --render t.jsonl
xrefuse "ERROR: usage: ac-follow.sh --render <jsonl>" w_render --render
xrefuse "ERROR: usage: ac-follow.sh --render <jsonl>" w_render --render ''

# 2. <id>: the usage, homeless, a missing meta, the archive meta, an empty
#    worktree, a harness that is not claude (or none, or past a NUL), an
#    unreadable meta.
w_metas() {
  xseed
  xmeta empty 'worktree=\nharness=claude\n'
  xmeta codex 'worktree=/tmp/x\nharness=codex\n'
  xmeta nohar 'worktree=/tmp/x\n'
  xmeta cr 'worktree=/tmp/x\nharness=claude\r\n'
  xmeta nulh 'worktree=/tmp/wt\000junk\nharness=claude\000x\n'
  xmeta last 'harness=codex\nworktree=/a\nharness=claude\nworktree=/tmp/last.wt\n'
  xmeta locked 'worktree=/tmp/x\nharness=claude\n'
  chmod 000 "$XW/home/state/locked.meta"
  mkdir -p "$XW/home/state/archive/arch"
  printf 'worktree=/tmp/wt.arch\nharness=claude\n' >"$XW/home/state/archive/arch/meta"
}
xrefuse "ERROR: usage: ac-follow.sh <id> | --render <jsonl>" w_metas
xrefuse "ERROR: usage: ac-follow.sh <id> | --render <jsonl>" w_metas ''
XHOMELESS=1 xrun w_metas '' f1
assert_eq "$XN_RC:$(xout)" "1:" "row 2: homeless refuses"
assert_contains "$(xerr)" "$XNOHOME" "row 2: ...naming AC_HOME"
XE="AC_HOME=" xrun w_metas '' f1
assert_eq "$XN_RC:$(xout)" "1:" "row 2: an empty AC_HOME refuses"
assert_contains "$(xerr)" "$XNOHOME" "row 2: ...naming AC_HOME"
xrefuse "ERROR: no crewmate meta for nosuch" w_metas nosuch
xrefuse "ERROR: meta for empty has no worktree" w_metas empty
xrefuse "ERROR: codex is not a claude crewmate; use ac-peek.sh instead" w_metas codex
xrefuse "ERROR: nohar is not a claude crewmate; use ac-peek.sh instead" w_metas nohar
xrefuse "ERROR: cr is not a claude crewmate; use ac-peek.sh instead" w_metas cr
if [ "$(id -u)" != 0 ]; then
  xrefuse "WARN: cannot read meta file $XW/home/state/locked.meta" w_metas locked
fi
xrun w_metas "$XWAIT" arch
assert_eq "$(xerr)" "WARN: no transcripts yet at $XW/tr/-tmp-wt-arch (crewmate still booting?)
following arch ($XW/tr/-tmp-wt-arch) - ctrl-c to stop" "row 2: the archive meta resolves"
assert_eq "$XN_RC:$(xout)" "143:$XWAIT $XW/tr/-tmp-wt-arch ..." "row 2: the follower waits for its first transcript"
xrun w_metas "$XWAIT" nulh
assert_contains "$(xerr)" "($XW/tr/-tmp-wt)" "row 2: each value is cut at its first NUL"
xrun w_metas "$XWAIT" last
assert_contains "$(xerr)" "($XW/tr/-tmp-last-wt)" "row 2: the last value of a key wins"

# 3. the transcript root's rungs: AC_CLAUDE_TRANSCRIPT_ROOT, CLAUDE_CONFIG_DIR
#    (an empty root falls through), HOME (both empty; unset is refused), a
#    relative root from a named cwd and from one that has no name; an existing
#    transcript renders.
w_one() { xseed; xmeta c1 'worktree=/w/a.b\nharness=claude\n'; }
w_live() { w_one; mkdir -p "$XW/tr/-w-a-b"; printf '%s\n' '{"type":"user","message":{"content":"first"}}' '{"type":"user","message":{"content":"last"}}' >"$XW/tr/-w-a-b/s1.jsonl"; }
xrun w_live "user: last" c1
assert_eq "$(xerr)" "following c1 ($XW/tr/-w-a-b) - ctrl-c to stop" "row 3: an existing transcript dir is no WARN"
assert_eq "$XN_RC:$(xout)" $'143:\n-- session: s1.jsonl --\n\nuser: first\n\nuser: last' "row 3: the transcript streams"
XE="CLAUDE_CONFIG_DIR=$XW/cfg AC_CLAUDE_TRANSCRIPT_ROOT=" xrun w_one "$XWAIT" c1
assert_contains "$(xerr)" "following c1 ($XW/cfg/projects/-w-a-b)" "row 3: CLAUDE_CONFIG_DIR's projects/"
XE="CLAUDE_CONFIG_DIR= AC_CLAUDE_TRANSCRIPT_ROOT=" xrun w_one "$XWAIT" c1
assert_contains "$(xerr)" "following c1 ($XW/hh/.claude/projects/-w-a-b)" "row 3: HOME's .claude/projects"
w_rel() { w_one; mkdir -p "$XW/cwd/rel/-w-a-b"; printf '%s\n' '{"type":"user","message":{"content":"rel"}}' >"$XW/cwd/rel/-w-a-b/s.jsonl"; }
XE="AC_CLAUDE_TRANSCRIPT_ROOT=rel" xrun w_rel "user: rel" c1
assert_eq "$XN_RC:$(xout):$(xerr)" $'143:\n-- session: s.jsonl --\n\nuser: rel:following c1 (rel/-w-a-b) - ctrl-c to stop' "row 3: a relative root is read from the caller's cwd"
XGONE=1 XE="AC_CLAUDE_TRANSCRIPT_ROOT=rel" xrun w_one '' c1
assert_eq "$XN_RC:$(xout):$(xerr)" "1::WARN: no transcripts yet at rel/-w-a-b (crewmate still booting?)
following c1 (rel/-w-a-b) - ctrl-c to stop
ERROR: the current directory cannot be resolved, so a relative transcript path cannot be either" "row 3: a relative root from a cwd that has no name"
# bun's transpiler cache follows XDG_CACHE_HOME with HOME unset, so it stays in the world.
XU=HOME XE="AC_CLAUDE_TRANSCRIPT_ROOT= XDG_CACHE_HOME=$XW/xdg" xrefuse "ERROR: HOME is not set, so the claude transcript root cannot be named" w_one c1

# 4. bytes in the worktree: UTF-8, and a byte that is no UTF-8, are slugged as
#    bytes under C and UTF-8 alike.
w_utf8() { xseed; xmeta u 'worktree=/tmp/wé.x\nharness=claude\n'; }
w_latin() { xseed; xmeta l 'worktree=/tmp/w\351.x\nharness=claude\n'; }
for lc in C en_US.UTF-8; do
  XLC="$lc" xrun w_utf8 "$XWAIT" u
  assert_eq "$XN_RC" "143" "row 4 ($lc): a UTF-8 worktree follows"
  assert_contains "$(xerr)" "following u ($XW/tr/-tmp-wé-x)" "row 4 ($lc): a UTF-8 worktree is slugged by bytes"
  XLC="$lc" xrun w_latin "$XWAIT" l
  assert_eq "$XN_RC" "143" "row 4 ($lc): a worktree byte that is no UTF-8 follows"
  assert_contains "$(xerr)" "$(printf 'following l (%s/tr/-tmp-w\351-x)' "$XW")" "row 4 ($lc): the stderr lines carry the byte"
done

# 5. a home that cannot be entered names the variable; a relative AC_HOME is
#    read from a named cwd, and refused from one that has no name.
XE="AC_HOME=$XW/nope" xrun w_metas '' arch
assert_eq "$XN_RC:$(xout)" "1:" "row 5: an unenterable home refuses"
assert_contains "$(xerr)" "ERROR: AC_HOME is not a readable directory: $XW/nope" "row 5: ...naming the variable"
w_relhome() { w_metas; mv "$XW/home" "$XW/cwd/h"; }
XE="AC_HOME=h" xrun w_relhome "$XWAIT" arch
assert_eq "$XN_RC" "143" "row 5: a relative home follows"
assert_contains "$(xerr)" "following arch ($XW/tr/-tmp-wt-arch)" "row 5: ...its archive meta resolved"
XGONE=1 XE="AC_HOME=h" xrefuse "ERROR: the current directory cannot be resolved, so a relative AC_HOME cannot be either" w_relhome arch

# 6. with no bun on PATH the shim refuses before any argument is read.
xnobun="$TMP/xnobun"
mkdir -p "$xnobun"
for x in bash env sed awk dirname cat mkdir rmdir; do ln -sf "$(command -v "$x")" "$xnobun/$x"; done
XPATH="$xnobun" xrefuse "ERROR: required tool not found: bun" w_metas

pass
