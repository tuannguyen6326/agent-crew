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

# --- differential: src/session.ts against the frozen bash original -----------
# DISPUTED: the implementation (tests/fixtures/ac-session.sh under bash vs src/session.ts through bin/ac-session.sh)
# HELD-CONSTANT: the home, every meta and pane fixture, the fake herdr, argv; stdout, stderr and exit status compared whole
obin="$(make_oracle_bin ac-session)"
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  "$obin/ac-session.sh" "$@" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  "$BIN/ac-session.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
same t1                      # view, worktree gone (WARN)
same t1 --talk               # talk on a parked task
same old1                    # archived meta
same t2                      # no session_id
same t3                      # not claude
same nope                    # no meta at all
same                         # usage
same t1 --talk extra         # a third argument is ignored
touch "$FAKE_HERDR/.unreachable"
same t4 --talk               # backend unobservable: refused
rm -f "$FAKE_HERDR/.unreachable"
# A worktree that exists, with a quote in its name, printed as the shell did.
mkdir -p "$TMP/wt'q"
printf "worktree=%s\nharness=claude\nbackend=herdr\nsession_id=00000000-0000-0000-0000-000000000005\n" "$TMP/wt'q" >"$AC_HOME/state/t5.meta"
same t5
same t5 --talk
# A crew-ship step mid-run reads busy through ac-crew-state.sh: refused.
mkdir -p "$TMP/wt'q/.crew/ship/current"
printf 'build\trunning\n' >"$TMP/wt'q/.crew/ship/current/steps.tsv"
same t5 --talk
rm -rf "$TMP/wt'q/.crew"
# A self task's dead pane reads detached, which talk allows.
printf 'worktree=%s\nharness=claude\nbackend=herdr\nkind=self\nsession_id=00000000-0000-0000-0000-000000000006\n' "$TMP/wt'q" >"$AC_HOME/state/t6.meta"
same t6 --talk
# Duplicate keys (last wins), CRLF, a value carrying '=', a UTF-8 path.
printf 'worktree=/one\r\nworktree=/tmp/đường\nharness=claude\nsession_id=a=b=c\n' >"$AC_HOME/state/t7.meta"
same t7
same t7 --talk
# Homeless: the same refusal, exit 1. The ONE accepted divergence: the bash
# original printed it twice (ac_home died inside the $(ac_state_dir) nested in
# ac_task_meta's printf, whose status the assignment swallowed, then again on
# the archive rung) - an artifact, not a contract; the port says it once.
o_rc=0; AC_HOME= "$obin/ac-session.sh" t1 >/dev/null 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME= "$BIN/ac-session.sh" t1 >/dev/null 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "homeless: both refuse"
assert_eq "$(head -n 1 "$TMP/n.err")" "$(head -n 1 "$TMP/o.err")" "homeless: the same refusal line"
assert_eq "$(wc -l <"$TMP/n.err" | tr -d ' ')" "1" "homeless: the port says it once"

pass
