#!/usr/bin/env bash
# ac-notify.test.sh - wedge-alarm channels: off is silent, command:<cmd>
# receives title/message via env, a broken command degrades to the bell,
# and the script never exits non-zero.
# shellcheck disable=SC2016  # the command channel is deliberately unexpanded

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# --- the CLI contract, byte for byte ------------------------------------------
# One side root $NH with a home at $NH/home; argv and env values spell it HOME.
# herdr and osascript stubs log their argv to $NH/stub.log and exit per
# HERDR_RC / OSA_RC; a row's PATH is those stubs, a stub dir without herdr, or
# $NBIN:/bin holding only dirname, head and bun.
NH="$TMP/nside"
NSTUB="$TMP/nstubs"; NOSA="$TMP/nstubs-osa"; NBIN="$TMP/nbin"
mkdir -p "$NSTUB" "$NOSA" "$NBIN" "$NH/home/config"
for nx in herdr osascript; do
  cat >"$NSTUB/$nx" <<STUB
#!/bin/sh
printf '%s' "$nx" >>"\$STUB_DIR/stub.log"
for a in "\$@"; do printf ' [%s]' "\$a" >>"\$STUB_DIR/stub.log"; done
printf '\n' >>"\$STUB_DIR/stub.log"
printf 'noise\n'; printf 'noise\n' >&2
exit "\${$( [ "$nx" = herdr ] && printf HERDR_RC || printf OSA_RC ):-0}"
STUB
  chmod +x "$NSTUB/$nx"
done
cp "$NSTUB/osascript" "$NOSA/osascript"
for nx in dirname head; do ln -s "/usr/bin/$nx" "$NBIN/$nx"; done
ln -s "$(command -v bun)" "$NBIN/bun"
NPATH_BOTH="$NSTUB:$(dirname "$(command -v bun)"):/usr/bin:/bin"
NPATH="$NPATH_BOTH"; NHOMELESS=0; NENV=()
nalarm() { printf -- "$1" >"$NH/home/config/wedge-alarm"; }  # nalarm <printf format>
nrun() {  # nrun <args...> - one notification; always exit 0 and a silent stdout
  local x v rc=0
  local a=() e=(LC_ALL=C "PATH=$NPATH" "STUB_DIR=$NH" "AC_NOTIFY_SINK=$NH/sink")
  [ "$NHOMELESS" = 1 ] || e+=(AC_HOME="$NH/home")
  for x in ${NENV[@]+"${NENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$NH}"); done
  for x in "$@"; do a+=("${x//HOME/$NH}"); done
  rm -f "$NH/stub.log" "$NH/sink"
  (cd "$NH" && env -u AC_HOME "${e[@]}" "$BIN/ac-notify.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/n.raw" 2>"$TMP/n.err" || rc=$?
  assert_eq "$rc" "0" "notify exits 0 for '$*'"
  assert_eq "$(cat "$TMP/n.raw")" "" "notify writes no stdout for '$*'"
}
nlog() { cat "$NH/stub.log" 2>/dev/null; }
nerr() { cat "$TMP/n.err"; }

# 1. off: nothing at all.
nalarm 'off\n'; nrun t m; assert_eq "$(nerr)$(nlog)" "" "1: off"
# 2. the bell's bytes: BEL, the default title, the message's joining, a % and a newline.
nalarm 'bell\n'
nrun t m; assert_eq "$(nerr)" "$(printf '\at: m')" "2: the bell"
nrun; assert_eq "$(nerr)" "$(printf '\aagent-crew: ')" "2: no arguments"
nrun onlytitle; assert_eq "$(nerr)" "$(printf '\aonlytitle: ')" "2: a title alone"
nrun "" m; assert_eq "$(nerr)" "$(printf '\aagent-crew: m')" "2: an empty title is the default"
nrun t a "" b "c d"; assert_eq "$(nerr)" "$(printf '\at: a  b c d')" "2: empty words kept"
nrun 'ti%s' $'l1\nl2'; assert_eq "$(nerr)" "$(printf '\ati%%s: l1\nl2')" "2: a % and a newline pass as bytes"
nrun t "$(printf 'd\351sc')"
assert_eq "$(od -An -tx1 "$TMP/n.err" | tr -d ' \n')" "07743a2064efbfbd73630a" "2: an argv byte that is not UTF-8 rings as U+FFFD"
# 3. herdr: the exact argv, its output dropped, a failure rings.
nalarm 'herdr\n'
nrun t 'say "hi"'; assert_eq "$(nlog)" 'herdr [notification] [show] [t] [--body] [say "hi"] [--sound] [none] [--position] [top-right]' "3: herdr's argv"
assert_eq "$(nerr)" "" "3: herdr's own output is dropped"
NENV=(HERDR_RC=7); nrun t m; assert_eq "$(nerr)" "$(printf '\at: m')" "3: a failing herdr rings"; NENV=()
# 4. osascript: only `"` escaped; a failure rings.
nalarm 'osascript\n'
nrun 'ti"tle' 'say "hi" \ back'
assert_eq "$(nlog)" 'osascript [-e] [display notification "say \"hi\" \ back" with title "ti\"tle"]' "4: osascript's argv"
nrun t $'line\nbreak'
assert_eq "$(nlog)" 'osascript [-e] [display notification "line
break" with title "t"]' "4: a newline passes"
NENV=(OSA_RC=1); nrun t m; assert_eq "$(nerr)" "$(printf '\at: m')" "4: a failing osascript rings"; NENV=()
# 5-6. command:<cmd>: the wire names reach the hook; a failure rings; the
#      first line, trimmed, is the command.
nalarm 'command:printf "%%s|%%s\\n" "$AC_NOTIFY_TITLE" "$AC_NOTIFY_MESSAGE" >>"$AC_NOTIFY_SINK"\n'
nrun "crew blocked" "fam: GATE: x"; assert_eq "$(cat "$NH/sink")" "crew blocked|fam: GATE: x" "5: the hook's env"
nalarm 'command:exit 9\n'; nrun x y; assert_eq "$(nerr)" "$(printf '\ax: y')" "6: a failing hook rings"
nalarm 'command:\n'; nrun x y; assert_eq "$(nerr)" "" "6: an empty command succeeds"
nalarm 'command: echo hi; exit 2\nsecond line ignored\n'; nrun x y; assert_eq "$(nerr)" "$(printf '\ax: y')" "6: only the first line runs"
nalarm '  command:exit 0  \r\n'; nrun x y; assert_eq "$(nerr)" "" "6: trimmed"
# 7-8. auto, and every unknown value as auto: herdr when the CONFIG backend
#      is herdr (the default) and herdr is on PATH, else osascript.
for nv in 'auto\n' 'bogus-channel\n' 'OFF\n' '\357\273\277off\n'; do nalarm "$nv"; nrun t m; assert_contains "$(nlog)" "herdr [notification]" "8: '$nv' is auto"; done
nalarm 'auto\n'
printf 'herdr\n' >"$NH/home/config/backend"; nrun t m; assert_contains "$(nlog)" "herdr [notification]" "7: a herdr backend takes herdr"
printf 'tmux\n' >"$NH/home/config/backend"; nrun t m; assert_contains "$(nlog)" "osascript [-e]" "7: a non-herdr backend takes osascript"
rm -f "$NH/home/config/backend"
NENV=(AC_BACKEND=orca); nrun t m; assert_contains "$(nlog)" "herdr [notification]" "7: AC_BACKEND is not consulted"; NENV=()
NENV=(HERDR_RC=1); nrun t m; assert_eq "$(nerr)" "$(printf '\at: m')" "7: a failing herdr rings"; NENV=()
rm -f "$NH/home/config/wedge-alarm"; nrun t m; assert_contains "$(nlog)" "herdr [notification]" "8: no config file"
mkdir -p "$NH/home/config/wedge-alarm"; nrun t m; assert_contains "$(nlog)" "herdr [notification]" "8: a directory"
rmdir "$NH/home/config/wedge-alarm"
if [ "$(id -u)" != 0 ]; then
  nalarm 'bell\n'; chmod 000 "$NH/home/config/wedge-alarm"
  nrun t m; assert_contains "$(nlog)" "herdr [notification]" "8: an unreadable channel is read as auto"
  chmod 644 "$NH/home/config/wedge-alarm"
fi
# 9. auto down the ladder: no herdr on PATH, then neither binary.
nalarm 'auto\n'
NPATH="$NOSA:$(dirname "$(command -v bun)"):/usr/bin:/bin"; nrun t m; assert_contains "$(nlog)" "osascript [-e]" "9: no herdr on PATH"
NPATH="$NBIN:/bin"; nrun t m; assert_eq "$(nerr)$(nlog)" "$(printf '\at: m')" "9: neither binary rings"
NPATH="$NPATH_BOTH"
# 10. homeless reads auto; so does a home that cannot be entered, silently.
NHOMELESS=1; nrun t m; assert_contains "$(nlog)" "herdr [notification]" "10: homeless is auto"; NHOMELESS=0
NENV=(AC_HOME=HOME/nonexistent); nrun t m; NENV=()
assert_eq "$(nerr)" "" "10: an unenterable home prints nothing"
assert_contains "$(nlog)" "herdr [notification]" "10: ...and is auto"
# 11. two lines: the first is the channel.
nalarm 'bell\noff\n'; nrun t m; assert_eq "$(nerr)" "$(printf '\at: m')" "11: the first line"
# 12. a closed stderr: the bell is lost and the exit is still 0 -
#     bin/ac-bun.sh leaves this module's closed channels to bun.
nalarm 'bell\n'
assert_eq "$(cd "$NH" && env -u AC_HOME LC_ALL=C "PATH=$NPATH" "STUB_DIR=$NH" AC_HOME="$NH/home" bash -c '"$0" t m 2>&-; printf "%s" "$?"' "$BIN/ac-notify.sh" </dev/null)" "0" "12: a closed stderr leaves the bell's exit 0"

pass
