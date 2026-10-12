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

# --- differential leg: src/follow.ts against the frozen bash original ---------
# The frozen original (tests/fixtures/ac-follow.sh) started the renderer as
# `follow.ts file|dir <path>`, a form the module no longer takes, so its oracle
# root holds a COPY of src/ with that renderer frozen beside it
# (tests/fixtures/follow.ts). Each row runs both sides in a world rebuilt from
# nothing; a side that is still following once its stdout holds the row's
# sentinel (or after 10 s) is TERMed, so a follow row compares the resolution
# and the first poll, never a wall clock. A divergence the port keeps on
# purpose is asserted on both sides, where it is.
# DISPUTED: the implementation (tests/fixtures/ac-follow.sh with tests/fixtures/follow.ts under bash vs src/follow.ts through bin/ac-follow.sh)
# HELD-CONSTANT: one world path ($XW: home/state, cwd/, tr/ the transcript root, hh/ the HOME) rebuilt by the row's world function before each side; argv; env (PATH the suite's unless the row names one, LC_ALL=C unless the row names en_US.UTF-8, HOME=$XW/hh and AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr unless the row unsets or empties them (or names another root, XROOT), AC_HOME=$XW/home unless the row is homeless or names another; CLAUDE_CONFIG_DIR, LANG, LC_CTYPE, CDPATH, AC_FLEET_STATE and AC_SCOPE unset unless the row sets one); cwd ($XW/cwd, deleted first where the row says); stdin (/dev/null); exit status, stdout and stderr compared whole.
xobin="$(make_oracle_bin ac-follow)"
cmp -s "$xobin/ac-follow.sh" "$ROOT/tests/fixtures/ac-follow.sh" || fail "the oracle bin holds the frozen original"
rm "$xobin/../src"
mkdir "$xobin/../src"
cp "$ROOT"/src/*.ts "$xobin/../src/"
cp "$ROOT/tests/fixtures/follow.ts" "$xobin/../src/follow.ts"
XW="$TMP/xw"
XLC=C; XHOMELESS=0; XE=""; XU=""; XPATH="$PATH"; XGONE=0; XRC=0; XROOT="$XW/tr"
xside() {  # xside <bin> <prefix> <sentinel> <args...> - one side in the current world
  local bin="$1" p="$2" sent="$3" pid i=0 rc=0 x
  shift 3
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
    exec env "${u[@]}" "${e[@]}" "$bin/ac-follow.sh" ${@+"$@"}
  ) </dev/null >"$TMP/$p.out" 2>"$TMP/$p.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    if [ -n "$sent" ] && grep -qF -- "$sent" "$TMP/$p.out"; then break; fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  # The braces' stderr takes the shell's own notice for a side TERM ended.
  { wait "$pid"; } 2>/dev/null || rc=$?
  # From a deleted cwd every bash prints its own getcwd lines, the original
  # one per cd it ran and the shim fewer (SHELL-OWN): both sides drop them.
  if [ "$XGONE" = 1 ]; then
    grep -av -e '^shell-init: error retrieving current directory' -e '^chdir: error retrieving current directory' "$TMP/$p.err" >"$TMP/$p.err.kept" || true
    mv "$TMP/$p.err.kept" "$TMP/$p.err"
  fi
  XRC=$rc
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <world fn> <sentinel> <args...> - each side in its own fresh world, nothing compared yet
  local wf="$1" sent="$2"
  shift 2
  "$wf"; xside "$xobin" xo "$sent" ${@+"$@"}; XO_RC=$XRC
  "$wf"; xside "$BIN" xn "$sent" ${@+"$@"}; XN_RC=$XRC
}
xline() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }
xsame() {  # xsame <world fn> <sentinel> <args...> - exit, stdout and stderr alike
  xpair "$@"
  local at; at="$(xline)"
  assert_eq "$XN_RC" "$XO_RC" "follow differential exit for '$*' at line $at"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "follow differential stdout differs for '$*' at line $at: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
  cmp -s "$TMP/xo.err" "$TMP/xn.err" || fail "follow differential stderr differs for '$*' at line $at: $(diff "$TMP/xo.err" "$TMP/xn.err" | head -n 6)"
}
xrefuse() {  # xrefuse <stderr> <world fn> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1" wf="$2"
  shift 2
  xsame "$wf" '' ${@+"$@"}
  assert_eq "$XN_RC:$(cat "$TMP/xn.out"):$(cat "$TMP/xn.err")" "1::$want" "follow refusal for '$*' at line $(xline)"
}
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err"; }
xoerr() { cat "$TMP/xo.err"; }
xseed() { rm -rf "$XW"; mkdir -p "$XW/home/state" "$XW/cwd" "$XW/tr" "$XW/hh"; }
xmeta() { printf '%b' "$2" >"$XW/home/state/$1.meta"; }   # xmeta <id> <meta lines, printf %b>
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XWAIT='waiting for the first transcript in'

# 1. --render: the usage, a missing or non-regular file, a file rendered byte
#    for byte (extra words ignored), a malformed record, an unreadable file,
#    and a relative path from a cwd that has no name.
w_render() {
  xseed
  printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Bash","input":{"a":"é"}}]}}' >"$XW/cwd/t.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"before"},7]}}' >"$XW/cwd/bad.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"x"}}' >"$XW/cwd/locked.jsonl"
  chmod 000 "$XW/cwd/locked.jsonl"
  ln -s t.jsonl "$XW/cwd/link.jsonl"
  cp "$XW/cwd/t.jsonl" "$XW/abs.jsonl"
}
xsame w_render '' --render t.jsonl
assert_eq "$(xout)" $'\nuser: hi\nok\ntool Bash {"a": "é"}' "row 1: the render, byte for byte"
xsame w_render '' --render t.jsonl extra words
xsame w_render '' --render "$XW/cwd/link.jsonl"
xsame w_render '' --render bad.jsonl
assert_eq "$XN_RC:$(xout)" "1:before" "row 1: a malformed record ends the render after what was printed"
if [ "$(id -u)" != 0 ]; then
  xsame w_render '' --render locked.jsonl
  assert_eq "$XN_RC:$(xout)" "1:" "row 1: an unreadable transcript fails"
fi
xrefuse "ERROR: no such transcript: nope.jsonl" w_render --render nope.jsonl
xrefuse "ERROR: no such transcript: $XW/cwd" w_render --render "$XW/cwd"
XGONE=1 xrefuse "ERROR: no such transcript: t.jsonl" w_render --render t.jsonl
XGONE=1 xsame w_render '' --render "$XW/abs.jsonl"
# SHELL-OWN STDERR, named: `${2:?}` printed the shell's own line where the
# port prints its usage line; exit 1 and no stdout on both sides.
xnopath() {  # xnopath <args...>
  xpair w_render '' "$@"
  assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "1:1:" "SHELL-OWN: '$*' fails both sides"
  assert_eq "$(xoerr)" "$xobin/ac-follow.sh: line 22: 2: usage: ac-follow.sh --render <jsonl>" "SHELL-OWN: the original's line for '$*' is the shell's"
  assert_eq "$(xerr)" "ERROR: usage: ac-follow.sh --render <jsonl>" "SHELL-OWN: the port's line for '$*' is its usage"
}
xnopath --render
xnopath --render ''

# 2. <id>: the usage, homeless (the refusal twice), a missing meta, the
#    archive meta, an empty worktree, a harness that is not claude (or none,
#    or past a NUL), an unreadable meta, and the id as a path component.
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
  mkdir -p "$XW/home/state/archive/arch" "$XW/home/up"
  printf 'worktree=/tmp/wt.arch\nharness=claude\n' >"$XW/home/state/archive/arch/meta"
  printf 'worktree=/tmp/up\nharness=claude\n' >"$XW/home/up.meta"
}
xrefuse "ERROR: usage: ac-follow.sh <id> | --render <jsonl>" w_metas
xrefuse "ERROR: usage: ac-follow.sh <id> | --render <jsonl>" w_metas ''
XHOMELESS=1 xrefuse "$XNOHOME
$XNOHOME" w_metas f1
XE="AC_HOME=" xrefuse "$XNOHOME
$XNOHOME" w_metas f1
xrefuse "ERROR: no crewmate meta for nosuch" w_metas nosuch
xrefuse "ERROR: meta for empty has no worktree" w_metas empty
xrefuse "ERROR: codex is not a claude crewmate; use ac-peek.sh instead" w_metas codex
xrefuse "ERROR: nohar is not a claude crewmate; use ac-peek.sh instead" w_metas nohar
xrefuse "ERROR: cr is not a claude crewmate; use ac-peek.sh instead" w_metas cr
if [ "$(id -u)" != 0 ]; then
  xrefuse "WARN: cannot read meta file $XW/home/state/locked.meta" w_metas locked
fi
xsame w_metas "$XWAIT" arch
assert_eq "$(xerr)" "WARN: no transcripts yet at $XW/tr/-tmp-wt-arch (crewmate still booting?)
following arch ($XW/tr/-tmp-wt-arch) - ctrl-c to stop" "row 2: the archive meta resolves"
assert_eq "$XN_RC:$(xout)" "143:$XWAIT $XW/tr/-tmp-wt-arch ..." "row 2: the follower waits for its first transcript"
xsame w_metas "$XWAIT" nulh
assert_contains "$(xerr)" "($XW/tr/-tmp-wt)" "row 2: each value is cut at its first NUL"
xsame w_metas "$XWAIT" last
assert_contains "$(xerr)" "($XW/tr/-tmp-last-wt)" "row 2: the last value of a key wins"
xsame w_metas "$XWAIT" ../up
assert_contains "$(xerr)" "following ../up ($XW/tr/-tmp-up)" "row 2: the id is a path component as given"

# 3. the transcript root's rungs: AC_CLAUDE_TRANSCRIPT_ROOT, CLAUDE_CONFIG_DIR
#    (an empty root falls through), HOME (both empty), a relative root from a
#    named cwd and from one that has no name; an existing transcript renders,
#    also under a root whose trailing LFs the original's `$(...)` cut.
w_one() { xseed; xmeta c1 'worktree=/w/a.b\nharness=claude\n'; }
w_live() { w_one; mkdir -p "$XW/tr/-w-a-b"; printf '%s\n' '{"type":"user","message":{"content":"first"}}' '{"type":"user","message":{"content":"last"}}' >"$XW/tr/-w-a-b/s1.jsonl"; }
xsame w_live "user: last" c1
assert_eq "$(xerr)" "following c1 ($XW/tr/-w-a-b) - ctrl-c to stop" "row 3: an existing transcript dir is no WARN"
assert_eq "$(xout)" $'\n-- session: s1.jsonl --\n\nuser: first\n\nuser: last' "row 3: the transcript streams"
XROOT="$XW/tr"$'\n\n' xsame w_live "user: last" c1
assert_eq "$(xerr)" "following c1 ($XW/tr/-w-a-b) - ctrl-c to stop" "row 3: a root's trailing LFs are cut"
XE="CLAUDE_CONFIG_DIR=$XW/cfg AC_CLAUDE_TRANSCRIPT_ROOT=" xsame w_one "$XWAIT" c1
assert_contains "$(xerr)" "following c1 ($XW/cfg/projects/-w-a-b)" "row 3: CLAUDE_CONFIG_DIR's projects/"
XE="CLAUDE_CONFIG_DIR= AC_CLAUDE_TRANSCRIPT_ROOT=" xsame w_one "$XWAIT" c1
assert_contains "$(xerr)" "following c1 ($XW/hh/.claude/projects/-w-a-b)" "row 3: HOME's .claude/projects"
w_rel() { w_one; mkdir -p "$XW/cwd/rel/-w-a-b"; printf '%s\n' '{"type":"user","message":{"content":"rel"}}' >"$XW/cwd/rel/-w-a-b/s.jsonl"; }
XE="AC_CLAUDE_TRANSCRIPT_ROOT=rel" xsame w_rel "user: rel" c1
XGONE=1 XE="AC_CLAUDE_TRANSCRIPT_ROOT=rel" xsame w_one '' c1
assert_eq "$XN_RC:$(xout):$(xerr)" "1::WARN: no transcripts yet at rel/-w-a-b (crewmate still booting?)
following c1 (rel/-w-a-b) - ctrl-c to stop
ERROR: the current directory cannot be resolved, so a relative transcript path cannot be either" "row 3: a relative root from a cwd that has no name"
# SHELL-OWN STDERR, named: HOME unset where the root needs it ended the
# original on the shell's `HOME: unbound variable`; the port names it.
# bun's transpiler cache follows XDG_CACHE_HOME there, so it stays in the world.
XU=HOME XE="AC_CLAUDE_TRANSCRIPT_ROOT= XDG_CACHE_HOME=$XW/xdg" xpair w_one '' c1
assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "1:1:" "SHELL-OWN: HOME unset fails both sides"
assert_contains "$(xoerr)" "HOME: unbound variable" "SHELL-OWN: the original's line is the shell's"
assert_eq "$(xerr)" "ERROR: HOME is not set, so the claude transcript root cannot be named" "SHELL-OWN: the port names HOME"

# 4. bytes in the worktree: UTF-8 under C and UTF-8 alike; a byte that is no
#    UTF-8 under C (the follower's own path decoded, AT PARITY); under UTF-8
#    the original's sed aborted (FAIL-PATH, named).
w_utf8() { xseed; xmeta u 'worktree=/tmp/wé.x\nharness=claude\n'; }
w_latin() { xseed; xmeta l 'worktree=/tmp/w\351.x\nharness=claude\n'; }
xsame w_utf8 "$XWAIT" u
XLC=en_US.UTF-8 xsame w_utf8 "$XWAIT" u
assert_contains "$(xerr)" "($XW/tr/-tmp-wé-x)" "row 4: a UTF-8 worktree is slugged by bytes"
xsame w_latin "$XWAIT" l
assert_contains "$(xerr)" "$(printf '(%s/tr/-tmp-w\351-x)' "$XW")" "row 4: the stderr lines carry the byte"
assert_contains "$(xout)" "$(printf '%s/tr/-tmp-w\357\277\275-x' "$XW")" "row 4: the follower's path is decoded, as bun decoded the original's argv"
XLC=en_US.UTF-8 xpair w_latin "$XWAIT" l
assert_eq "$XO_RC:$(cat "$TMP/xo.out"):$(xoerr)" "1::sed: RE error: illegal byte sequence" "FAIL-PATH: the original's sed aborted under UTF-8"
assert_eq "$XN_RC" "143" "FAIL-PATH: the port slugs the bytes and follows"
assert_contains "$(xerr)" "$(printf 'following l (%s/tr/-tmp-w\351-x)' "$XW")" "FAIL-PATH: ... naming the byte"

# 5. HOME RESOLUTION, named: a home cd cannot enter names the variable (twice,
#    where the shell printed its own cd line twice); a relative AC_HOME is
#    read from a named cwd alike, and refused from one that has no name.
XE="AC_HOME=$XW/nope" xpair w_metas '' arch
assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.out")$(xout)" "1:1:" "HOME RESOLUTION: an unenterable home fails both sides"
assert_eq "$(xerr)" "ERROR: AC_HOME is not a readable directory: $XW/nope
ERROR: AC_HOME is not a readable directory: $XW/nope" "HOME RESOLUTION: the port names the variable twice"
assert_contains "$(xoerr)" "cd: $XW/nope: No such file or directory" "HOME RESOLUTION: the original printed cd's line"
w_relhome() { w_metas; mv "$XW/home" "$XW/cwd/h"; }
XE="AC_HOME=h" xsame w_relhome "$XWAIT" arch
XGONE=1 XE="AC_HOME=h" xpair w_relhome '' arch
assert_eq "$XO_RC:$XN_RC" "1:1" "HOME RESOLUTION: a relative home from a nameless cwd fails both sides"
assert_eq "$(xerr)" "ERROR: the current directory cannot be resolved, so a relative AC_HOME cannot be either" "HOME RESOLUTION: the port refuses it once"

# 6. BUN, named: with no bun on PATH the shim refuses before any argument;
#    the original refused the argument first.
xnobun="$TMP/xnobun"
mkdir -p "$xnobun"
for x in bash env sed awk dirname cat mkdir rmdir; do ln -sf "$(command -v "$x")" "$xnobun/$x"; done
XPATH="$xnobun" xpair w_metas ''
assert_eq "$XO_RC:$XN_RC" "1:1" "BUN: both sides fail"
assert_eq "$(xoerr)" "ERROR: usage: ac-follow.sh <id> | --render <jsonl>" "BUN: the original refused the argument"
assert_eq "$(xerr)" "ERROR: required tool not found: bun" "BUN: the shim refuses first"

pass
