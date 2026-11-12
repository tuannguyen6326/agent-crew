#!/usr/bin/env bash
# ac-session.test.sh - view/talk resume commands: fork-session on view,
# un-forked on talk, archive lookup, missing-session refusals.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Live claude task with a recorded session id.
mkdir -p "$AC_HOME/state/archive/old1"
cat >"$AC_HOME/state/t1.meta" <<'EOF'
worktree=/tmp/wt1
harness=claude
backend=tmux
session_id=aaaabbbb-cccc-dddd-eeee-ffff00001111
EOF

out="$("$BIN/ac-session.sh" t1 2>/dev/null)"
assert_contains "$out" "resume aaaabbbb" "view resumes the session"
assert_contains "$out" "fork-session" "view is forked (safe)"

# Talk on a parked task (window gone -> state 'gone') is allowed, un-forked.
out="$("$BIN/ac-session.sh" t1 --talk 2>/dev/null)"
assert_contains "$out" "TALK: un-forked" "talk mode"
case "$out" in *--fork-session*) fail "talk must not fork" ;; esac

# Talk is REFUSED when the BACKEND itself is unobservable (F12): the state
# we don't know is exactly what could be mid-turn, and --talk's own hazard
# (two writers corrupt one session) is destructive the same way a REAP acting
# on an unknown pane is (contract: records/repo-knowledge/agent-crew.md:86,
# reap_orphan_window - REFUSE must not proceed on unknown), so unobservable is
# treated like busy, not like a silently-permitted unknown.
make_fake_herdr
printf 'worktree=/tmp/wt-t4\nharness=claude\nbackend=herdr\nsession_id=aaaabbbb-cccc-dddd-eeee-ffff00004444\n' \
  >"$AC_HOME/state/t4.meta"
printf 'pT4 tT4\n' >"$AC_HOME/state/.pane-t4"
printf 'pT4\n' >"$FAKE_HERDR/tabs/tT4"
: >"$FAKE_HERDR/panes/pT4.buf"
touch "$FAKE_HERDR/.unreachable"
err="$("$BIN/ac-session.sh" t4 --talk 2>&1)" && fail "talk must refuse an unobservable backend"
assert_contains "$err" "backend" "the talk refusal blames the BACKEND, not the pane"
assert_contains "$err" "UNKNOWN" "the talk refusal names liveness as unknown, not mid-turn"
rm -f "$FAKE_HERDR/.unreachable"

# Archived task still resolves.
cat >"$AC_HOME/state/archive/old1/meta" <<'EOF'
worktree=/tmp/wt-old
harness=claude
session_id=99998888-7777-6666-5555-444433332222
EOF
assert_contains "$("$BIN/ac-session.sh" old1 2>/dev/null)" "resume 99998888" "archive lookup"

# Refusals: no session id, non-claude harness.
printf 'worktree=/tmp/x\nharness=claude\n' >"$AC_HOME/state/t2.meta"
assert_fails "$BIN/ac-session.sh" t2
printf 'worktree=/tmp/x\nharness=fake\nsession_id=x\n' >"$AC_HOME/state/t3.meta"
assert_fails "$BIN/ac-session.sh" t3

# --- the CLI contract, byte for byte ------------------------------------------
run() {  # run <args...> - one call; sets rc, out, err
  rc=0
  out="$("$BIN/ac-session.sh" "$@" 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
}
view="# VIEW: forked - safe to read and poke, never mutates the real session"
talk="# TALK: un-forked - your words become part of what --resume-from continues"
refuse() {  # refuse <want-stderr> <args...> - exit 1, nothing on stdout, that one line
  local want="$1"; shift
  run "$@"
  assert_eq "$rc" "1" "'$*' exits 1"
  assert_eq "$out" "" "'$*' prints no command"
  assert_eq "$err" "$want" "the refusal for '$*'"
}

run t1
assert_eq "$rc" "0" "a gone worktree is never a refusal"
assert_eq "$out" "$view
cd '/tmp/wt1' && claude --resume aaaabbbb-cccc-dddd-eeee-ffff00001111 --fork-session" "the view command"
assert_eq "$err" "WARN: worktree /tmp/wt1 is gone; mkdir -p it to let --resume load the transcript" "a gone worktree is a WARN"
run t1 --talk extra
assert_eq "$rc" "0" "a third argument is ignored"
assert_eq "$out" "$talk
cd '/tmp/wt1' && claude --resume aaaabbbb-cccc-dddd-eeee-ffff00001111" "the talk command"

refuse "ERROR: t2 has no recorded session_id (pre-plumbing task)" t2
refuse "ERROR: t3 is not a claude crewmate" t3
refuse "ERROR: no crewmate meta for nope" nope
refuse "ERROR: usage: ac-session.sh <id> [--talk]"

# A worktree that exists, with a quote in its name: printed as spelled, no WARN.
mkdir -p "$TMP/wt'q"
printf "worktree=%s\nharness=claude\nbackend=herdr\nsession_id=00000000-0000-0000-0000-000000000005\n" "$TMP/wt'q" >"$AC_HOME/state/t5.meta"
run t5
assert_eq "$out" "$view
cd '$TMP/wt'q' && claude --resume 00000000-0000-0000-0000-000000000005 --fork-session" "a quoted worktree is printed as spelled"
assert_eq "$err" "" "a worktree that exists draws no WARN"
# A crew-ship step mid-run reads busy through ac-crew-state.sh: refused.
mkdir -p "$TMP/wt'q/.crew/ship/current"
printf 'build\trunning\n' >"$TMP/wt'q/.crew/ship/current/steps.tsv"
refuse "ERROR: REFUSED: t5 is mid-turn (validate:build:running) - two writers corrupt one session. Talk when it parks, or ac-follow.sh to watch now." t5 --talk
rm -rf "$TMP/wt'q/.crew"
# A self task's dead pane reads detached, which talk allows.
printf 'worktree=%s\nharness=claude\nbackend=herdr\nkind=self\nsession_id=00000000-0000-0000-0000-000000000006\n' "$TMP/wt'q" >"$AC_HOME/state/t6.meta"
run t6 --talk
assert_eq "$rc" "0" "talk on a detached self task is allowed"
assert_eq "$out" "$talk
cd '$TMP/wt'q' && claude --resume 00000000-0000-0000-0000-000000000006" "the self task's talk command"
# Duplicate keys (last wins), CRLF, a value carrying '=', a UTF-8 path.
printf 'worktree=/one\r\nworktree=/tmp/đường\nharness=claude\nsession_id=a=b=c\n' >"$AC_HOME/state/t7.meta"
run t7
assert_eq "$out" "$view
cd '/tmp/đường' && claude --resume a=b=c --fork-session" "the last duplicate key wins and a value keeps its '='"
assert_eq "$err" "WARN: worktree /tmp/đường is gone; mkdir -p it to let --resume load the transcript" "a UTF-8 path is printed byte for byte"
# A worktree that EXISTS under a UTF-8 name draws no WARN, and a non-ASCII id
# is looked up by its native spelling.
mkdir -p "$TMP/wt-đã-có"
printf 'worktree=%s\nharness=claude\nbackend=herdr\nsession_id=00000000-0000-0000-0000-000000000009\n' "$TMP/wt-đã-có" >"$AC_HOME/state/tđ9.meta"
run tđ9 --talk
assert_eq "$rc" "0" "a non-ASCII id resolves its meta"
assert_eq "$out" "$talk
cd '$TMP/wt-đã-có' && claude --resume 00000000-0000-0000-0000-000000000009" "a UTF-8 worktree is printed as spelled"
assert_eq "$err" "" "a UTF-8 worktree that exists draws no WARN"
refuse "ERROR: no crewmate meta for tđ-missing" tđ-missing
AC_HOME= run t1
assert_eq "$rc" "1" "homeless exits 1"
assert_contains "$err" "ERROR: AC_HOME is not set" "the homeless refusal"
assert_eq "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" "1" "homeless: said once"

pass
