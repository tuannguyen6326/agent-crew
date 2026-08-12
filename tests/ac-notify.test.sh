#!/usr/bin/env bash
# ac-notify.test.sh - wedge-alarm channels: off is silent, command:<cmd>
# receives title/message via env, a broken command degrades to the bell,
# and the script never exits non-zero.
# shellcheck disable=SC2016  # the command channel is deliberately unexpanded

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# off: no output, exit 0.
out="$("$BIN/ac-notify.sh" title hello 2>&1)"
assert_eq "$out" "" "off channel is silent"

# command channel: env-injected title/message land in the sink.
printf 'command:printf "%%s|%%s\\n" "$AC_NOTIFY_TITLE" "$AC_NOTIFY_MESSAGE" >>"$AC_NOTIFY_SINK"\n' \
  >"$AC_HOME/config/wedge-alarm"
export AC_NOTIFY_SINK="$TMP/notify.log"
"$BIN/ac-notify.sh" "crew report" "t1: done: shipped"
assert_contains "$(cat "$TMP/notify.log")" "crew report|t1: done: shipped" "command channel"

# A failing command degrades to the bell but still exits 0.
printf 'command:exit 9\n' >"$AC_HOME/config/wedge-alarm"
out="$("$BIN/ac-notify.sh" x y 2>&1)" || fail "notify must never fail"
assert_contains "$out" "x: y" "bell fallback"

# bell channel prints to stderr, exit 0.
printf 'bell\n' >"$AC_HOME/config/wedge-alarm"
out="$("$BIN/ac-notify.sh" ping pong 2>&1)"
assert_contains "$out" "ping: pong" "bell channel"

pass
