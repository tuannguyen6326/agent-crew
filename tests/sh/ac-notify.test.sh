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

# --- differential: src/notify.ts against the frozen bash original -----------
# DISPUTED: the implementation (tests/fixtures/ac-notify.sh under bash vs src/notify.ts through bin/ac-notify.sh)
# HELD-CONSTANT: two side roots seeded alike ($NOH for the oracle, $NNH for the shim), each with a home at <side>/home; argv and env (the side root spelled HOME, substituted in values only); cwd (the side root); stdin /dev/null; LC_ALL=C; one PATH per row for both sides - herdr and osascript stubs that log their argv to <side>/stub.log and exit per HERDR_RC / OSA_RC, then bun's directory, /usr/bin and /bin, or a stub dir without herdr, or $NBIN:/bin holding only dirname, head and bun; exit status, stdout and stderr compared whole (the side root spelled HOME), then the stub log and the command hook's sink.
nobin="$(make_oracle_bin ac-notify)"
NOH="$TMP/nside-o"; NNH="$TMP/nside-n"
NSTUB="$TMP/nstubs"; NOSA="$TMP/nstubs-osa"; NBIN="$TMP/nbin"
mkdir -p "$NSTUB" "$NOSA" "$NBIN"
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
nseed() { local h; for h in "$NOH" "$NNH"; do rm -rf "$h"; mkdir -p "$h/home/config"; done; }
nalarm() {  # nalarm <printf format> - config/wedge-alarm on both sides
  local h; for h in "$NOH" "$NNH"; do printf -- "$1" >"$h/home/config/wedge-alarm"; done
}
nbackend() { local h; for h in "$NOH" "$NNH"; do printf '%s\n' "$1" >"$h/home/config/backend"; done; }
nrun_side() {  # nrun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C "PATH=$NPATH" "STUB_DIR=$h" "AC_NOTIFY_SINK=$h/sink")
  [ "$NHOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${NENV[@]+"${NENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h" && env -u AC_HOME "${e[@]}" "$bin/ac-notify.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
NO_RC=0; NN_RC=0
npair() {
  local h
  for h in "$NOH" "$NNH"; do rm -f "$h/stub.log" "$h/sink"; done
  NO_RC=0; NN_RC=0
  nrun_side "$nobin" "$NOH" o "$@" || NO_RC=$?
  nrun_side "$BIN" "$NNH" n "$@" || NN_RC=$?
  LC_ALL=C sed "s#$NOH#HOME#g" "$TMP/o.err" >"$TMP/o.err2"; LC_ALL=C sed "s#$NNH#HOME#g" "$TMP/n.err" >"$TMP/n.err2"
}
nsame() {
  npair "$@"
  assert_eq "$NO_RC $NN_RC" "0 0" "notify differential exit for '$*'"
  assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "notify writes no stdout for '$*'"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "notify differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | od -c | head -n 6)"
  assert_eq "$(cat "$NNH/stub.log" 2>/dev/null)" "$(cat "$NOH/stub.log" 2>/dev/null)" "notify differential stub argv for '$*'"
  assert_eq "$(cat "$NNH/sink" 2>/dev/null)" "$(cat "$NOH/sink" 2>/dev/null)" "notify differential hook sink for '$*'"
}
nlog() { cat "$NNH/stub.log" 2>/dev/null; }
nerr() { cat "$TMP/n.err2"; }
nseed

# 1. off: nothing at all.
nalarm 'off\n'; nsame t m; assert_eq "$(nerr)$(nlog)" "" "1: off"
# 2. the bell's bytes: BEL, the default title, `$*` joining, a % and a newline.
nalarm 'bell\n'
nsame t m; assert_eq "$(nerr)" "$(printf '\at: m')" "2: the bell"
nsame; assert_eq "$(nerr)" "$(printf '\aagent-crew: ')" "2: no arguments"
nsame onlytitle; nsame "" m; assert_eq "$(nerr)" "$(printf '\aagent-crew: m')" "2: an empty title is the default"
nsame t a "" b "c d"; assert_eq "$(nerr)" "$(printf '\at: a  b c d')" "2: empty words kept"
nsame 'ti%s' $'l1\nl2'
npair t "$(printf 'd\351sc')"
assert_eq "$NO_RC $NN_RC" "0 0" "2: argv bytes - both exit 0"
assert_eq "$(od -An -tx1 "$TMP/o.err2" | tr -d ' \n')" "07743a2064e973630a" "2: the original rings the raw byte"
assert_eq "$(od -An -tx1 "$TMP/n.err2" | tr -d ' \n')" "07743a2064efbfbd73630a" "2: named - argv reaches the port decoded (U+FFFD)"
# 3. herdr: the exact argv, its output dropped, a failure rings.
nalarm 'herdr\n'
nsame t 'say "hi"'; assert_eq "$(nlog)" 'herdr [notification] [show] [t] [--body] [say "hi"] [--sound] [none] [--position] [top-right]' "3: herdr's argv"
NENV=(HERDR_RC=7); nsame t m; assert_eq "$(nerr)" "$(printf '\at: m')" "3: a failing herdr rings"; NENV=()
# 4. osascript: only `"` escaped; a failure rings.
nalarm 'osascript\n'
nsame 'ti"tle' 'say "hi" \ back'
assert_eq "$(nlog)" 'osascript [-e] [display notification "say \"hi\" \ back" with title "ti\"tle"]' "4: osascript's argv"
nsame t $'line\nbreak'
NENV=(OSA_RC=1); nsame t m; assert_eq "$(nerr)" "$(printf '\at: m')" "4: a failing osascript rings"; NENV=()
# 5-6. command:<cmd>: the wire names reach the hook; a failure rings; the
#      first line, trimmed, is the command.
nalarm 'command:printf "%%s|%%s\\n" "$AC_NOTIFY_TITLE" "$AC_NOTIFY_MESSAGE" >>"$AC_NOTIFY_SINK"\n'
nsame "crew blocked" "fam: GATE: x"; assert_eq "$(cat "$NNH/sink")" "crew blocked|fam: GATE: x" "5: the hook's env"
nalarm 'command:exit 9\n'; nsame x y; assert_eq "$(nerr)" "$(printf '\ax: y')" "6: a failing hook rings"
nalarm 'command:\n'; nsame x y; assert_eq "$(nerr)" "" "6: an empty command succeeds"
nalarm 'command: echo hi; exit 2\nsecond line ignored\n'; nsame x y; assert_eq "$(nerr)" "$(printf '\ax: y')" "6: only the first line runs"
nalarm '  command:exit 0  \r\n'; nsame x y; assert_eq "$(nerr)" "" "6: trimmed"
nalarm 'command:exit 0\r\n'; nsame x y
# 7-8. auto, and every unknown value as auto: herdr when the CONFIG backend
#      is herdr (the default) and herdr is on PATH, else osascript.
for nv in 'auto\n' 'bogus-channel\n' 'OFF\n' '\357\273\277off\n'; do nalarm "$nv"; nsame t m; assert_contains "$(nlog)" "herdr [notification]" "8: '$nv' is auto"; done
nalarm 'auto\n'
nbackend herdr; nsame t m
nbackend tmux; nsame t m; assert_contains "$(nlog)" "osascript [-e]" "7: a non-herdr backend takes osascript"
for nh in "$NOH" "$NNH"; do rm -f "$nh/home/config/backend"; done
NENV=(AC_BACKEND=orca); nsame t m; assert_contains "$(nlog)" "herdr [notification]" "7: AC_BACKEND is not consulted"; NENV=()
NENV=(HERDR_RC=1); nsame t m; assert_eq "$(nerr)" "$(printf '\at: m')" "7: a failing herdr rings"; NENV=()
for nh in "$NOH" "$NNH"; do rm -f "$nh/home/config/wedge-alarm"; done; nsame t m; assert_contains "$(nlog)" "herdr [notification]" "8: no config file"
for nh in "$NOH" "$NNH"; do mkdir -p "$nh/home/config/wedge-alarm"; done; nsame t m; assert_contains "$(nlog)" "herdr [notification]" "8: a directory"
for nh in "$NOH" "$NNH"; do rmdir "$nh/home/config/wedge-alarm"; done
if [ "$(id -u)" != 0 ]; then
  nalarm 'bell\n'; for nh in "$NOH" "$NNH"; do chmod 000 "$nh/home/config/wedge-alarm"; done
  nsame t m; assert_contains "$(nerr)" "head: HOME/home/config/wedge-alarm: Permission denied" "8: an unreadable channel is head's line"
  assert_contains "$(nlog)" "herdr [notification]" "8: ...and the empty channel, read as auto"
  for nh in "$NOH" "$NNH"; do chmod 644 "$nh/home/config/wedge-alarm"; done
fi
# 9. auto down the ladder: no herdr on PATH, then neither binary.
nalarm 'auto\n'
NPATH="$NOSA:$(dirname "$(command -v bun)"):/usr/bin:/bin"; nsame t m; assert_contains "$(nlog)" "osascript [-e]" "9: no herdr on PATH"
NPATH="$NBIN:/bin"; nsame t m; assert_eq "$(nerr)$(nlog)" "$(printf '\at: m')" "9: neither binary rings"
NPATH="$NPATH_BOTH"
# 10. homeless reads auto; a home cd cannot enter reads auto (the original's
#     cd lines are the shell's own - not reproduced, named).
NHOMELESS=1; nsame t m; assert_contains "$(nlog)" "herdr [notification]" "10: homeless is auto"; NHOMELESS=0
NENV=(AC_HOME=HOME/nonexistent); npair t m; NENV=()
assert_eq "$NO_RC $NN_RC" "0 0" "10: an unenterable home exits 0"
assert_contains "$(cat "$TMP/o.err2")" "HOME/nonexistent: No such file or directory" "10: the original's cd lines"
assert_eq "$(nerr)" "" "10: named - the port prints none"
assert_eq "$(nlog)" "$(cat "$NOH/stub.log")" "10: ...and both take herdr"
# 11. two lines: the first is the channel.
nalarm 'bell\noff\n'; nsame t m; assert_eq "$(nerr)" "$(printf '\at: m')" "11: the first line"
# 12. a closed stderr: the bell is lost and both still exit 0 - the original
#     ran without errexit, so its failed printf changed nothing, and
#     bin/ac-bun.sh leaves this module's closed channels to bun.
nalarm 'bell\n'
nshut() {  # nshut <bin> <side root> - the exit of a bell with stderr closed
  (cd "$2" && env -u AC_HOME LC_ALL=C "PATH=$NPATH" "STUB_DIR=$2" AC_HOME="$2/home" bash -c '"$0" t m 2>&-; printf "%s" "$?"' "$1/ac-notify.sh") </dev/null
}
assert_eq "$(nshut "$nobin" "$NOH") $(nshut "$BIN" "$NNH")" "0 0" "12: a closed stderr leaves the bell's exit 0 on both sides"

pass
