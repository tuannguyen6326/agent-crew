#!/usr/bin/env bash
# ac-deputy.test.sh - deputy_state (bin/ac-deputy.sh) edge cases.
#
# Part 1: a stale meta naming an unsupported backend (e.g. tmux, removed
# 2026-07-17) must degrade that ONE entry to DOWN, never abort the whole
# `list` - the SUBSHELL isolation in deputy_state is what a "simplify away
# the parens" edit would break: `list` runs at every session start
# (bin/ac-session-start.sh), so a direct call would take the whole digest
# down over one stale deputy. tests/sh/ac-deputy-registry.test.sh (which
# otherwise exhaustively covers `list`/`validate`) only ever constructs
# backend=herdr entries, so this branch is untested there.
#
# Part 2: a SUPPORTED backend (herdr) the fleet genuinely cannot read (rc=2,
# or 127 from a driver that failed to load) is a DIFFERENT variable from
# part 1's malformed meta, and must render its own UNOBSERVABLE state, never
# silently collapse to DOWN (contract: ac-backend.sh WINDOW LIVENESS;
# AGENTS.md section 7 - "NOT a death and no work is lost").

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

h="$AC_HOME/crewdeputies/stale"
mkdir -p "$h/state"
: >"$h/.ac-crewdeputy-home"
printf '# Crewdeputies\n\n- stale - duty - home: %s - scope: legacy - projects: none (added 2026-07-19T00:00:00Z)\n' "$h" \
  >"$AC_HOME/records/crewdeputies.md"
printf 'backend=tmux\nkind=crewdeputy\n' >"$AC_HOME/state/stale.meta"
printf 'pSTALE tSTALE\n' >"$AC_HOME/state/.pane-stale"

out="$("$BIN/ac-deputy.sh" list)" || fail "list must never die on an unsupported-backend meta"
assert_contains "$out" "$(printf 'DOWN\tstale')" "an unsupported backend degrades the entry to DOWN, not a crash"

# --- A3 / window-liveness contract: deputy_state must distinguish "not ------
# running" from "could not be asked" -----------------------------------------
# A stale meta naming an UNSUPPORTED backend (above) is a DIFFERENT variable
# (a malformed meta - ac_backend_route's `b="$(ac_backend)" || exit 1` degrades
# to rc=1 INSIDE the deliberate subshell, and that degradation to DOWN stays
# correct and untouched) from a SUPPORTED backend the fleet genuinely cannot
# read (rc=2, or 127 from a driver that failed to load) - that second
# variable must render as its own state, never silently as DOWN.
make_fake_herdr

h2="$AC_HOME/crewdeputies/unread"
mkdir -p "$h2/state"
: >"$h2/.ac-crewdeputy-home"
printf -- '- unread - duty - home: %s - scope: legacy - projects: none (added 2026-07-19T00:00:00Z)\n' "$h2" \
  >>"$AC_HOME/records/crewdeputies.md"
printf 'backend=herdr\nkind=crewdeputy\n' >"$AC_HOME/state/unread.meta"

# rc=0 (A4 no-regression floor): a genuinely alive pane still renders LIVE.
printf 'pUNREAD tUNREAD\n' >"$AC_HOME/state/.pane-unread"
printf 'pUNREAD\n' >"$FAKE_HERDR/tabs/tUNREAD"; : >"$FAKE_HERDR/panes/pUNREAD.buf"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must not die on a live herdr-backed deputy"
assert_contains "$out" "$(printf 'LIVE\tunread')" "a genuinely alive pane still renders LIVE (A4)"

# rc=1 (A4 no-regression floor): a genuinely gone pane still renders DOWN.
rm -f "$FAKE_HERDR/tabs/tUNREAD" "$FAKE_HERDR/panes/pUNREAD.buf"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must not die on a gone herdr-backed deputy"
assert_contains "$out" "$(printf 'DOWN\tunread')" "a genuinely gone pane still renders DOWN (A4)"

# rc=2: THE REGRESSION this row closes.
printf 'pUNREAD tUNREAD\n' >"$AC_HOME/state/.pane-unread"
printf 'pUNREAD\n' >"$FAKE_HERDR/tabs/tUNREAD"; : >"$FAKE_HERDR/panes/pUNREAD.buf"
touch "$FAKE_HERDR/.unreachable"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must never die on an unreadable herdr backend"
rm -f "$FAKE_HERDR/.unreachable"
case "$out" in *"$(printf 'DOWN\tunread')"*) \
  fail "THE REGRESSION: an unreadable backend (rc=2) must never render as DOWN" ;; esac
assert_contains "$out" "$(printf 'UNOBSERVABLE\tunread')" "an unreadable backend renders UNOBSERVABLE, not DOWN"

# ...and a backend that cannot be READ at all renders the SAME way. This row
# once drove a driver that failed to LOAD (bash's 127, through a lab bin/ with
# the herdr driver renamed); the backend verbs are native now (src/lib.ts
# backendCall), so no driver can fail to load under list, and the row reaches
# the same unobservable read with herdr absent from PATH (the liveness
# ladder's 2).
nh_path="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$nh_path" command -v herdr || true)" ]; then
  out="$(PATH="$nh_path" "$BIN/ac-deputy.sh" list)" || fail "list must never die on a backend absent from PATH"
  case "$out" in *"$(printf 'DOWN\tunread')"*) \
    fail "THE REGRESSION: herdr absent from PATH must never render as DOWN" ;; esac
  assert_contains "$out" "$(printf 'UNOBSERVABLE\tunread')" \
    "herdr absent from PATH renders UNOBSERVABLE, same as rc=2"
else
  printf 'SKIP: list with herdr absent - bun shares its directory with a herdr on this host\n'
fi

# --- the entry end to end, one scenario per row -------------------------------
# One side root ($H): a parent home at $H/home with its deputy homes under
# crewdeputies/, and the fake herdr's state at $H/herdr; cwd the side root,
# stdin /dev/null, LC_ALL=C unless a row names en_US.UTF-8; PATH stubs -
# make_fake_herdr's herdr, an orca answering per sentinel file, a date
# answering one fixed instant per format (or failing per sentinel). A row
# reads the run's exit status, stdout and stderr (the side root spelled @H)
# and what it left under the side root.
H="$TMP/dside"
DSTUBS="$TMP/dstubs"; mkdir -p "$DSTUBS"
cat >"$DSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%N*) [ ! -e "$STUB_DIR/date.fail-ns" ] || exit 4
        echo 1767225600000000000 ;;
  *%S*) [ ! -e "$STUB_DIR/date.fail" ] || { echo 'date: the stub refuses' >&2; exit 3; }
        echo 2026-01-01T00:00:00Z ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$DSTUBS/orca" <<'STUB'
#!/bin/sh
printf 'orca %s\n' "$*" >>"$STUB_DIR/orca.log"
case "$1 $2" in
  "terminal show")
    [ ! -e "$STUB_DIR/orca.show-fail" ] || exit 1
    if [ -e "$STUB_DIR/orca.connected" ]; then c=true; else c=false; fi
    printf '{"ok":true,"result":{"terminal":{"connected":%s}}}\n' "$c" ;;
  "status --json")
    [ ! -e "$STUB_DIR/orca.status-fail" ] || exit 1
    printf '{"ok":true,"result":{}}\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$DSTUBS/date" "$DSTUBS/orca"
dat() {  # dat <cmd> <args...> - a seeding step; a literal @H in an argument is the side root
  local x a=(); for x in "$@"; do a+=("${x//@H/$H}"); done; "${a[@]}"
}
dseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/records" "$H/home/config" "$H/home/data" "$H/herdr/panes" "$H/herdr/tabs"
  printf 'off\n' >"$H/home/config/wedge-alarm"
}
ddep() {  # ddep <id> [<dir under home>] - a seeded deputy home: the marker and the backlog skeleton home-seed writes
  local d="$H/home/${2:-crewdeputies}/$1"
  mkdir -p "$d/state" "$d/records" "$d/data"; : >"$d/.ac-crewdeputy-home"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$d/records/backlog.md"
}
dreg() {  # dreg <line>... - registry lines (@H the side root), appended
  local l; for l in "$@"; do printf '%s\n' "${l//@H/$H}" >>"$H/home/records/crewdeputies.md"; done
}
dput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # dput <path under the side> <bytes>
dlive() {  # dlive <id> <pane> - a meta and a pane the fake herdr answers for
  printf 'backend=herdr\nkind=crewdeputy\n' >"$H/home/state/$1.meta"
  printf '%s t%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  printf '%s\n' "$2" >"$H/herdr/tabs/t$2"; : >"$H/herdr/panes/$2.buf"
}
DLC=C; DENV=(); DHOME=home; DHOMELESS=0; DPATH=""; DN_RC=0
drun() {  # drun <args...> - one run of the entry; @H in an argument or a DENV value is the side root
  local x v a=() e=("LC_ALL=$DLC" "PATH=${DPATH:-$DSTUBS:$TMP/stubbin:$PATH}" "STUB_DIR=$H" "FAKE_HERDR=$H/herdr")
  [ "$DHOMELESS" = 1 ] || e+=("AC_HOME=$H/$DHOME")
  for x in ${DENV[@]+"${DENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$H}"); done
  for x in "$@"; do a+=("${x//@H/$H}"); done
  DN_RC=0
  (cd "$H" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN \
    "${e[@]}" "$BIN/ac-deputy.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/d.raw" 2>"$TMP/d.rawerr" || DN_RC=$?
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/d.raw" >"$TMP/d.out"; LC_ALL=C sed -e "s#$H#@H#g" "$TMP/d.rawerr" >"$TMP/d.err"
}
dout() { cat "$TMP/d.out"; }
derr() { cat "$TMP/d.err"; }
dspool() { cat "$H"/home/state/.wake-spool/* 2>/dev/null || true; }
DNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
DUSAGE='ERROR: usage: ac-deputy.sh <list|validate|report|handoff>'
DBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
DTS='2026-01-01T00:00:00Z'
dseed

# 1. usage, and the backend gate before the verb: none, -h, LIST and an
#    unknown verb are the usage line; config/backend tmux refuses each verb.
for dv in "" -h LIST bogus; do
  # shellcheck disable=SC2086
  drun $dv
  assert_eq "$DN_RC:$(dout):$(derr)" "1::$DUSAGE" "1: '$dv' is the usage line, exit 1"
done
drun list extra args
assert_eq "$DN_RC:$(dout)" "0:ABSENT: records/crewdeputies.md - no crewdeputies registered" "1: extra arguments to list are never read"
dput home/config/backend $'tmux\n'
for dv in list "report x" "handoff d x"; do
  # shellcheck disable=SC2086
  drun $dv
  assert_eq "$DN_RC:$(dout):$(derr)" "1::$DBAD" "1: config/backend tmux refuses '$dv' before the verb"
done
rm -f "$H/home/config/backend"
DENV=(AC_BACKEND=Herdr); drun list; DENV=()
assert_eq "$DN_RC:$(derr)" "1:ERROR: unsupported backend 'Herdr' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "1: AC_BACKEND=Herdr refuses"
dput fs/config/backend $'bogus\tx\n'; mkdir -p "$H/fs/state"
DENV=(AC_FLEET_STATE=@H/fs/state/); drun validate; DENV=()
assert_eq "$DN_RC:$(derr)" "1:ERROR: unsupported backend 'bogus' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "1: the AC_FLEET_STATE rung, cut at its first blank"

# 2. homeless: report and handoff are refused on the AC_HOME line first; an
#    AC_HOME that cannot be entered is named on every verb.
DHOMELESS=1
drun report x
assert_eq "$DN_RC:$(dout):$(sed -n 1p "$TMP/d.err")" "1::$DNOHOME" "2: homeless report"
drun handoff d x
assert_eq "$DN_RC:$(dout):$(sed -n 1p "$TMP/d.err")" "1::$DNOHOME" "2: homeless handoff"
DHOMELESS=0
DHOME=missing
for dv in list validate "report x" "handoff d x"; do
  # shellcheck disable=SC2086
  drun $dv
  assert_contains "$(derr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "2: an unenterable AC_HOME is named ('$dv')"
done
[ ! -e "$H/missing" ] || fail "2: an unenterable AC_HOME is never minted"
DHOME=home

# 3. list, the registry's shapes: absent, a directory, heading-only (EMPTY),
#    a lone `- `, the full table (LIVE, DOWN by a gone pane and by no handle,
#    NOT-RUNNING, HOME-MISSING by an absent home and by a marker DIRECTORY,
#    LEGACY with clones, a duplicate id, INVALID with its verbatim source), a
#    UTF-8 `e-acute` id and a lone 0xE9 byte under C (bad id charset).
drun list
assert_eq "$DN_RC:$(dout)" "0:ABSENT: records/crewdeputies.md - no crewdeputies registered" "3: absent"
mkdir "$H/home/records/crewdeputies.md"
drun list; assert_eq "$DN_RC:$(dout)" "0:ABSENT: records/crewdeputies.md - no crewdeputies registered" "3: a directory is ABSENT"
rmdir "$H/home/records/crewdeputies.md"
dput home/records/crewdeputies.md $'# Crewdeputies\n\n'
drun list; assert_eq "$(dout)" "EMPTY: records/crewdeputies.md present, 0 entries - no crewdeputies registered" "3: heading-only is EMPTY"
dreg '- '
drun list
assert_eq "$DN_RC:$(dout)" "0:INVALID	- 	reason: missing \"(added ...)\"
registered: 1 (live 0, down 0, not-running 0, home-missing 0, invalid 1)" "3: a lone '- '"
rm -f "$H/home/records/crewdeputies.md"
ddep dlive; ddep ddown; ddep dnohandle; ddep didle; ddep dmark; ddep dleg
rm -f "$H/home/crewdeputies/dmark/.ac-crewdeputy-home"; mkdir "$H/home/crewdeputies/dmark/.ac-crewdeputy-home"
dlive dlive pD1
printf 'backend=herdr\nkind=crewdeputy\n' >"$H/home/state/ddown.meta"; printf 'pGONE tGONE\n' >"$H/home/state/.pane-ddown"
printf 'backend=herdr\n' >"$H/home/state/dnohandle.meta"
dreg '# Crewdeputies' '' \
  '- dlive - payments duty - home: @H/home/crewdeputies/dlive - scope: payments incidents - projects: alpha (added 2026-07-19T00:00:00Z)' \
  '- ddown - ops duty - home: @H/home/crewdeputies/ddown - scope: alert noise - projects: none (added 2026-07-19T00:00:00Z)' \
  '- dnohandle - ops - home: @H/home/crewdeputies/dnohandle - scope:  - projects:  (added x)' \
  '- didle - home: @H/home/crewdeputies/didle - no projects (added 2026-07-19T00:00:00Z)' \
  '- dgone - gone duty - home: @H/home/crewdeputies/dgone - scope: nothing - projects: none (added 2026-07-19T00:00:00Z)' \
  '- dmark - marker dir - home: @H/home/crewdeputies/dmark - scope: s - projects: none (added x)' \
  '- dleg - home: @H/home/crewdeputies/dleg - alpha  beta	gamma (added x)' \
  '- dlive - again - home: @H/home/crewdeputies/dlive - scope: s - projects: none (added x)' \
  '- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)' \
  'prose that is no entry'
drun list
assert_eq "$DN_RC:$(dout)" "0:LIVE	dlive	home: @H/home/crewdeputies/dlive	projects: alpha
	charter: payments duty
	scope: payments incidents
DOWN	ddown	home: @H/home/crewdeputies/ddown	projects: none
	charter: ops duty
	scope: alert noise
	recover: bin/ac-spawn.sh ddown --crewdeputy --recover
DOWN	dnohandle	home: @H/home/crewdeputies/dnohandle	projects: none
	charter: ops
	scope: (unset - not routable until a scope: is added)
	recover: bin/ac-spawn.sh dnohandle --crewdeputy --recover
NOT-RUNNING	didle	home: @H/home/crewdeputies/didle	projects: none
	charter: (none)
	scope: (unset - not routable until a scope: is added)
	recover: bin/ac-spawn.sh didle --crewdeputy --recover
HOME-MISSING	dgone	home: @H/home/crewdeputies/dgone	projects: none
	charter: gone duty
	scope: nothing
HOME-MISSING	dmark	home: @H/home/crewdeputies/dmark	projects: none
	charter: marker dir
	scope: s
NOT-RUNNING	dleg	home: @H/home/crewdeputies/dleg	projects: alpha,beta,gamma
	charter: (none)
	scope: (unset - not routable until a scope: is added)
	recover: bin/ac-spawn.sh dleg --crewdeputy --recover
INVALID	- dlive - again - home: @H/home/crewdeputies/dlive - scope: s - projects: none (added x)	reason: duplicate id
INVALID	- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)	reason: missing \"home:\" field
registered: 9 (live 1, down 2, not-running 2, home-missing 2, invalid 2)" "3: the full table"
assert_contains "$(cat "$H/herdr/log")" "herdr pane get pD1" "3: the probe went to the fake herdr"
rm -f "$H/home/records/crewdeputies.md"
dreg $'- caf\303\251 - c - home: /h/caf\303\251 - scope: s - projects: none (added x)'
drun list
assert_eq "$(dout)" "INVALID	- caf$(printf '\303\251') - c - home: /h/caf$(printf '\303\251') - scope: s - projects: none (added x)	reason: bad id charset
registered: 1 (live 0, down 0, not-running 0, home-missing 0, invalid 1)" "3: an e-acute id is bad id charset"
DLC=en_US.UTF-8; drun list; DLC=C
assert_contains "$(dout)" "reason: bad id charset" "3: an e-acute id is bad id charset under UTF-8 too"
dreg $'- b\351d - c - home: /h/b\351d - scope: s - projects: none (added x)'
drun list
assert_contains "$(dout)" "INVALID	- b$(printf '\351')d - c - home: /h/b$(printf '\351')d - scope: s - projects: none (added x)	reason: bad id charset" "3: a 0xE9 byte under C"

# 4. liveness: a stale tmux meta is the route's ERROR then DOWN - in that
#    order on a merged stream, a UTF-8 name refused as its bytes, one that is
#    not UTF-8 as U+FFFD; an orca meta against the orca stub, connected
#    (LIVE), disconnected (DOWN), show failing with status answering (DOWN),
#    both failing (UNOBSERVABLE).
rm -f "$H/home/records/crewdeputies.md" "$H/home/state/"*.meta "$H/home/state/".pane-*
ddep dh; ddep dt; ddep dorca
dlive dh pH1
printf 'backend=tmux\nkind=crewdeputy\n' >"$H/home/state/dt.meta"; printf 'pT tT\n' >"$H/home/state/.pane-dt"
printf 'backend=orca\nkind=crewdeputy\n' >"$H/home/state/dorca.meta"; printf 'term-1 tab-1\n' >"$H/home/state/.pane-dorca"
dreg '- dh - h - home: @H/home/crewdeputies/dh - scope: s - projects: none (added x)' \
  '- dt - t - home: @H/home/crewdeputies/dt - scope: s - projects: none (added x)' \
  '- dorca - o - home: @H/home/crewdeputies/dorca - scope: s - projects: none (added x)'
drun list
assert_eq "$DN_RC:$(dout | /usr/bin/grep -v '^	')" "0:LIVE	dh	home: @H/home/crewdeputies/dh	projects: none
DOWN	dt	home: @H/home/crewdeputies/dt	projects: none
DOWN	dorca	home: @H/home/crewdeputies/dorca	projects: none
registered: 3 (live 1, down 2, not-running 0, home-missing 0, invalid 0)" "4: herdr live, tmux stale, orca disconnected"
assert_eq "$(derr)" "$DBAD" "4: the stale meta's refusal reaches stderr"
dmerged="$( (cd "$H" && env -u AC_HOME -u AC_BACKEND LC_ALL=C PATH="$DSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$H" FAKE_HERDR="$H/herdr" AC_HOME="$H/home" \
  "$BIN/ac-deputy.sh" list) </dev/null 2>&1 | LC_ALL=C sed -e "s#$H#@H#g" | /usr/bin/grep -v '^	')"
assert_eq "$(printf '%s\n' "$dmerged" | sed -n 2,3p)" "$DBAD
DOWN	dt	home: @H/home/crewdeputies/dt	projects: none" "4: the ERROR precedes its entry's line on a merged stream"
dput home/state/dt.meta $'backend=caf\303\251\nkind=crewdeputy\n'
drun list; assert_eq "$(derr)" "ERROR: unsupported backend 'caf$(printf '\303\251')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a meta's UTF-8 backend name is refused as its bytes"
dput home/state/dt.meta $'backend=caf\351\nkind=crewdeputy\n'
drun list
assert_eq "$(derr)" "ERROR: unsupported backend 'caf$(printf '\357\277\275')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= is refused as U+FFFD"
dput home/state/dt.meta $'backend=tmux\nkind=crewdeputy\n'
touch "$H/orca.connected"
drun list; assert_contains "$(dout)" "LIVE	dorca" "4: orca connected is LIVE"
rm -f "$H/orca.connected"
touch "$H/orca.show-fail"
drun list; assert_contains "$(dout)" "DOWN	dorca" "4: orca show failing, status answering, is DOWN"
touch "$H/orca.status-fail"
drun list; assert_contains "$(dout)" "UNOBSERVABLE	dorca" "4: orca unreadable is UNOBSERVABLE"
assert_contains "$(cat "$H/orca.log")" "orca terminal show --terminal term-1 --json" "4: the probe named the meta's terminal"
rm -f "$H/orca.show-fail" "$H/orca.status-fail"

# 5. validate: absent and clean are silent 0; each INVALID line is
#    `INVALID <src>: <reason>`, exit 1; a 0xE9 byte under C.
rm -f "$H/home/records/crewdeputies.md"
drun validate; assert_eq "$DN_RC:$(dout):$(derr)" "0::" "5: absent"
dreg '- ok - c - home: /h/ok - scope: s - projects: none (added x)'
drun validate; assert_eq "$DN_RC:$(dout):$(derr)" "0::" "5: clean"
dreg '- ops2 - home /abs - no projects (added x)' '- '
drun validate
assert_eq "$DN_RC:$(dout)" "1:INVALID - ops2 - home /abs - no projects (added x): missing \"home:\" field
INVALID - : missing \"(added ...)\"" "5: each INVALID line"
rm -f "$H/home/records/crewdeputies.md"
dreg '- ok - c - home: /h/ok - scope: s - projects: none (added x)' $'- b\351d - c - home: /h/b\351d - scope: s - projects: none (added x)'
drun validate
assert_eq "$DN_RC:$(dout)" "1:INVALID - b$(printf '\351')d - c - home: /h/b$(printf '\351')d - scope: s - projects: none (added x): bad id charset" "5: a 0xE9 byte under C"

# 6. report from a deputy home: the parent's status line and ONE spool
#    record; --doc; % and backslashes raw; an unregistered deputy and an
#    absent registry WARN and still deliver; a failing date.
dseed
ddep pay
dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
DHOME=home/crewdeputies/pay
drun report 'done: interest rounding fixed'
assert_eq "$DN_RC:$(dout):$(derr)" "0:reported pay to @H/home:" "6: the report line"
assert_eq "$(cat "$H/home/state/pay.status")" "$DTS report: done: interest rounding fixed" "6: the parent's status line"
assert_eq "$(dspool)" "1767225600	deputy	pay	done: interest rounding fixed" "6: one spool record"
assert_eq "$(ls -A "$H/home/crewdeputies/pay/state")" "" "6: the deputy home records nothing"
drun report 'done: audit' --doc @H/home/crewdeputies/pay/data/r.md
assert_eq "$(tail -n1 "$H/home/state/pay.status")" "$DTS report: done: audit doc: $H/home/crewdeputies/pay/data/r.md" "6: --doc rides the line"
rm -rf "$H/home/state/.wake-spool"
drun report 'done: 100% \n \\ %s done'
assert_eq "$(tail -n1 "$H/home/state/pay.status")" "$DTS report: done: 100% \\n \\\\ %s done" "6: % and backslashes reach the status line raw"
assert_eq "$(dspool)" "1767225600	deputy	pay	done: 100% \\n \\\\ %s done" "6: ... and the wake record"
dput home/records/crewdeputies.md $'# Crewdeputies\n'
drun report 'done: unregistered'
assert_eq "$DN_RC:$(derr)" "0:WARN: no registry entry for pay in the parent's routing table - delivering the return anyway" "6: unregistered warns"
rm -f "$H/home/records/crewdeputies.md"
rm -rf "$H/home/state/.wake-spool"
drun report 'done: no registry'
assert_contains "$(derr)" "no registry entry for pay" "6: an absent registry warns"
assert_eq "$DN_RC:$(dspool)" "0:1767225600	deputy	pay	done: no registry" "6: ... and still delivers"
touch "$H/date.fail"
drun report 'done: no stamp'
rm -f "$H/date.fail"
assert_eq "$DN_RC:$(tail -n1 "$H/home/state/pay.status")" "0: report: done: no stamp" "6: a failing date leaves the stamp empty"
rm -rf "$H/home/state/.wake-spool"
touch "$H/date.fail-ns"
drun report 'done: no clock'
rm -f "$H/date.fail-ns"
assert_eq "$DN_RC:$(dout)" "4:" "6: a failing ns date ends the unguarded publish with its status"
assert_eq "$(tail -n1 "$H/home/state/pay.status"):$(dspool)" "$DTS report: done: no clock:" "6: ... the status line written, no wake"

# 7. report refusals, each writing nothing: from the parent, empty text, no
#    text, a relative --doc, --doc with no value, an extra positional; an
#    orphan with no state/ two levels up; a symlinked deputy home resolves
#    physically.
dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
rm -rf "$H/home/state/.wake-spool"
dbefore="$(cat "$H/home/state/pay.status")"
DHOME=home; drun report x
assert_eq "$DN_RC:$(derr)" "1:ERROR: report runs INSIDE a crewdeputy home (no .ac-crewdeputy-home marker here)" "7: from the parent"
DHOME=home/crewdeputies/pay
drun report ''; assert_eq "$DN_RC:$(derr)" "1:ERROR: usage: ac-deputy.sh report '<text>' [--doc <abs-path>]" "7: empty text"
drun report; assert_eq "$DN_RC:$(derr)" "1:ERROR: usage: ac-deputy.sh report '<text>' [--doc <abs-path>]" "7: no text"
drun report x --doc rel/p; assert_eq "$DN_RC:$(derr)" "1:ERROR: --doc must be an absolute path (the parent resolves it from its own home): rel/p" "7: relative --doc"
drun report x --doc; assert_eq "$DN_RC:$(derr)" "1:ERROR: --doc needs a value" "7: --doc alone"
drun report x y; assert_eq "$DN_RC:$(derr)" "1:ERROR: unknown argument: y" "7: an extra positional"
drun report '' bogus; assert_eq "$DN_RC:$(derr)" "1:ERROR: unknown argument: bogus" "7: arguments are read before the text"
assert_eq "$(cat "$H/home/state/pay.status"):$(dspool)" "$dbefore:" "7: a refused report writes no status line and no wake"
mkdir -p "$H/orphan/crewdeputies/px/state"; : >"$H/orphan/crewdeputies/px/.ac-crewdeputy-home"
DHOME=orphan/crewdeputies/px; drun report x
assert_eq "$DN_RC:$(derr)" "1:ERROR: cannot resolve a parent fleet above @H/orphan/crewdeputies/px - refusing to write a return with nowhere to land" "7: an orphan"
[ ! -e "$H/orphan/state" ] || fail "7: a refused report mints nothing above"
ln -s "$H/home/crewdeputies/pay" "$H/paylink"
DHOME=paylink; drun report 'done: via link'
assert_eq "$DN_RC:$(dout)" "0:reported pay to @H/home" "7: a symlinked home resolves physically"
assert_eq "$(tail -n1 "$H/home/state/pay.status")" "$DTS report: done: via link" "7: ... into the parent's status log"
DHOME=home

# 8. report failures: an unwritable parent status log ends it 1 with no wake;
#    a spool directory that refuses the link ends it 1 with no line; a text
#    byte that is not UTF-8 arrives as U+FFFD (argv is decoded) and publishes
#    under UTF-8 too; no date on PATH leaves the stamp empty, writes the line
#    and ends the unguarded publish 127 with no wake.
DHOME=home/crewdeputies/pay
if [ "$(id -u)" != 0 ]; then
  dseed; ddep pay; dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
  dput home/state/pay.status $'old\n'; chmod 444 "$H/home/state/pay.status"
  drun report 'done: x'
  chmod 644 "$H/home/state/pay.status"
  assert_eq "$DN_RC:$(dout):$(cat "$H/home/state/pay.status")" "1::old" "8: an unwritable status log ends it 1"
  [ ! -e "$H/home/state/.wake-spool" ] || fail "8: ... with no wake"
  mkdir -p "$H/home/state/.wake-spool"; chmod 555 "$H/home/state/.wake-spool"
  drun report 'done: spool refuses'
  chmod 755 "$H/home/state/.wake-spool"
  assert_eq "$DN_RC:$(dout)" "1:" "8: a refused publish is exit 1, no line"
  assert_eq "$(ls -A "$H/home/state/.wake-spool")" "" "8: ... and no record"
fi
dseed; ddep pay; dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
drun report $'done: caf\351'
assert_eq "$DN_RC:$(tail -c 7 "$H/home/state/pay.status" | od -An -tx1 | tr -d ' \n')" "0:636166efbfbd0a" "8: the text's byte arrives decoded, as U+FFFD"
rm -rf "$H/home/state/.wake-spool"
DLC=en_US.UTF-8; drun report $'done: caf\351'; DLC=C
assert_eq "$DN_RC:$(dspool)" "0:1767225600	deputy	pay	done: caf$(printf '\357\277\275')" "8: under UTF-8 it publishes"
dnodate="$TMP/dnodate"; mkdir -p "$dnodate"
for c in bash bun awk tr basename mkdir mkfifo dirname; do ln -sf "$(command -v "$c")" "$dnodate/$c"; done
dseed; ddep pay; dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
DPATH="$dnodate"; drun report 'done: clock absent'; DPATH=""
assert_eq "$DN_RC:$(cat "$H/home/state/pay.status")" "127: report: done: clock absent" "8: no date - an empty stamp, the line written, exit 127"
assert_eq "$(ls -A "$H/home/state")" "pay.status" "8: no date - no wake record, no temp"
DHOME=home

# 9. handoff: one id, several (argv order) with a [x] row under Queued, a
#    local-only, an unpinned and a repo-less row; a second backup in the same
#    second; Queued last appends at EOF and an unterminated deputy line gains
#    its LF; the timeline mirror only for a deputy with a meta.
d9() {
  rm -f "$H/home/records/crewdeputies.md"; ddep pay
  dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
  cat >"$H/home/records/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] flying - already in flight (repo: alpha, since 2026-07-19)

## Queued
- [ ] qmove [mode:direct-pr] - move me (repo: alpha)
- [ ] qkeep [mode:direct-pr] - keep me (repo: alpha)
- [ ] q1 - the blocker (repo: alpha)
- [ ] q2 - the dependent (repo: alpha) blocked-by: q1 - waits on q1
- [ ] qnorepo - a malformed line with no repo token
- [ ] qnopin - no contract pin (repo: alpha)
- [ ] qlocal [mode:local-only] - land it locally (repo: locrepo)
- [ ] qepic - a story (repo: alpha); epic:bigone
- [ ] qprose - says epic: in passing (repo: alpha)
- [x] qx - checked but queued (repo: alpha)

## Done
- [x] donetask - landed (repo: alpha) - local main (merged 2026-07-19)
EOF
  printf '# Backlog\n\n## In flight\n\n## Queued\n- [ ] own1 - the deputy own queued work (repo: alpha)\n\n## Done\n' >"$H/home/crewdeputies/pay/records/backlog.md"
}
dseed; d9
drun handoff pay qmove
assert_eq "$DN_RC:$(dout)" "0:backup: @H/home/state/backups/deputy-handoff-1767225600.tar.gz
- [ ] qmove [mode:direct-pr] - move me (repo: alpha)
handed qmove to pay" "9: one id"
drun handoff pay qnopin qlocal qnorepo qx
assert_eq "$DN_RC:$(dout | sed -n 2,6p)" "0:- [ ] qnopin - no contract pin (repo: alpha)
- [ ] qlocal [mode:local-only] - land it locally (repo: locrepo)
- [ ] qnorepo - a malformed line with no repo token
- [x] qx - checked but queued (repo: alpha)
handed qnopin,qlocal,qnorepo,qx to pay" "9: argv order, a [x] row under Queued moves"
assert_eq "$(awk '/^## Queued/ { q = 1; next } /^## / { q = 0 } q && /^- /' "$H/home/crewdeputies/pay/records/backlog.md" | sed -E 's/^(- \[.\] [^ ]+).*/\1/')" "- [ ] own1
- [ ] qmove
- [ ] qnopin
- [ ] qlocal
- [ ] qnorepo
- [x] qx" "9: ... and lands in that order behind the deputy's own"
case "$(cat "$H/home/records/backlog.md")" in *qnopin*|*qlocal*|*qnorepo*|*" qx "*) fail "9: the parent keeps no copy" ;; esac
assert_eq "$(ls "$H/home/state/backups")" "deputy-handoff-1767225600-1.tar.gz
deputy-handoff-1767225600.tar.gz" "9: a second backup in the same second steps to -1"
assert_eq "$(cat "$H/home/state/pay.status")" "$DTS handoff: qmove
$DTS handoff: qnopin,qlocal,qnorepo,qx" "9: each handoff's status line"
[ ! -e "$H/home/data/pay" ] || fail "9: no timeline for a deputy without a meta"
printf '# Backlog\n\n## In flight\n\n## Done\n\n## Queued\n- [ ] own1 - unterminated' >"$H/home/crewdeputies/pay/records/backlog.md"
printf 'kind=crewdeputy\n' >"$H/home/state/pay.meta"
drun handoff pay qkeep
assert_eq "$(tail -n 2 "$H/home/crewdeputies/pay/records/backlog.md")" "- [ ] own1 - unterminated
- [ ] qkeep [mode:direct-pr] - keep me (repo: alpha)" "9: Queued last appends at EOF, the unterminated line gains its LF"
assert_eq "$(cat "$H/home/data/pay/timeline.log")" "$DTS handoff: qkeep" "9: the timeline mirror for a deputy with a meta"

# The ledger locks: handoff takes the PARENT ledger's lock and then the
# DEPUTY's, as ac-task.sh takes each, and a live writer holding either one is
# waited out (AC_TASK_LOCK_TIMEOUT) and refused with nothing moved.
dseed; d9
dlockrow() {  # dlockrow <lock dir under the side> <refusal> - a live holder there refuses handoff
  mkdir "$H/$1"; printf '%s\n' "$$" >"$H/$1/pid"
  local before; before="$(cat "$H/home/records/backlog.md" "$H/home/crewdeputies/pay/records/backlog.md")"
  DENV=(AC_TASK_LOCK_TIMEOUT=1); drun handoff pay qmove; DENV=()
  assert_eq "$DN_RC:$(dout):$(derr)" "1::ERROR: $2" "9: a live holder of $1 refuses handoff"
  assert_eq "$(cat "$H/home/records/backlog.md" "$H/home/crewdeputies/pay/records/backlog.md")" "$before" "9: ... with nothing moved"
  assert_eq "$(cat "$H/$1/pid")" "$$" "9: ... and the holder's lock left as it was"
  [ -z "$(ls "$H/home/state/backups" 2>/dev/null)" ] || fail "9: ... and no backup taken"
  rm -rf "${H:?}/$1"
}
dlockrow home/records/.backlog.md.lock "records/backlog.md is locked by another writer - nothing written"
dlockrow home/crewdeputies/pay/records/.backlog.md.lock "crewdeputy pay's records/backlog.md is locked by another writer - nothing written"
[ ! -e "$H/home/records/.backlog.md.lock" ] || fail "9: a refusal on the deputy's lock releases the parent's it took"
# The point of the lock: a commit the deputy ledger's holder makes before it
# releases survives the handoff, which reads and rewrites inside the lock.
mkdir "$H/home/crewdeputies/pay/records/.backlog.md.lock"; printf '%s\n' "$$" >"$H/home/crewdeputies/pay/records/.backlog.md.lock/pid"
DENV=(AC_TASK_LOCK_TIMEOUT=30); (drun handoff pay qmove; exit "$DN_RC") & dlpid=$!; DENV=()
# A checkpoint, not a timer: holding the parent's lock, the handoff is now
# waiting on the deputy's - only then does the holder commit and release.
for _ in $(seq 1 150); do [ ! -s "$H/home/records/.backlog.md.lock/pid" ] || break; /bin/sleep 0.2; done
[ -s "$H/home/records/.backlog.md.lock/pid" ] || fail "9: the waiting handoff never took the parent's lock"
case "$(cat "$H/home/records/backlog.md" "$H/home/crewdeputies/pay/records/backlog.md")" in
  *"own1"*"qmove"*) fail "9: handoff moved a row while another writer held the deputy's lock" ;;
esac
printf -- '- [ ] held1 - committed by the lock holder\n' >>"$H/home/crewdeputies/pay/records/backlog.md"
rm -rf "$H/home/crewdeputies/pay/records/.backlog.md.lock"
wait "$dlpid" || fail "9: the waiting handoff failed: $(derr)"
assert_contains "$(cat "$H/home/crewdeputies/pay/records/backlog.md")" "- [ ] held1 - committed by the lock holder" "9: the holder's commit survives"
assert_contains "$(cat "$H/home/crewdeputies/pay/records/backlog.md")" "- [ ] qmove [mode:direct-pr] - move me (repo: alpha)" "9: ... and the moved row lands after the release"
[ ! -e "$H/home/records/.backlog.md.lock" ] && [ ! -e "$H/home/crewdeputies/pay/records/.backlog.md.lock" ] || fail "9: handoff releases both locks"
assert_contains "$(for xf in "$H"/home/state/backups/*; do tar -tzf "$xf"; done)" "records/.backlog.md.lock/pid" "9: the backup, taken under the parent's lock, carries the lock dir"

# 10. handoff refusals, the parent ledger byte-unchanged: usage x3, inside a
#     deputy home, its home gone, no deputy backlog, no Queued section, a row
#     before any heading, no parent backlog.
dseed; d9
drefuse() {  # drefuse <refusal> <args...> - handoff is refused on that line alone, nothing moved
  local want="$1"; shift
  local before; before="$(cat "$H/home/records/backlog.md" 2>/dev/null || true)"
  drun handoff "$@"
  assert_eq "$DN_RC:$(dout):$(derr)" "1::$want" "10: handoff $* is refused"
  assert_eq "$(cat "$H/home/records/backlog.md" 2>/dev/null || true)" "$before" "10: handoff $* moves nothing"
  [ ! -e "$H/home/state/backups" ] || fail "10: handoff $* takes no backup"
}
drefuse "ERROR: usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..."
drefuse "ERROR: usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..." pay
drefuse "ERROR: usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..." '' qmove
DHOME=home/crewdeputies/pay; drefuse "ERROR: handoff runs in the PARENT fleet home, not inside a crewdeputy home" pay qmove; DHOME=home
dreg '- gone - g - home: @H/home/crewdeputies/gone - scope: s - projects: none (added x)'
drefuse "ERROR: crewdeputy home is gone: @H/home/crewdeputies/gone" gone qmove
ddep nobl; rm "$H/home/crewdeputies/nobl/records/backlog.md"
dreg '- nobl - n - home: @H/home/crewdeputies/nobl - scope: s - projects: none (added x)'
drefuse "ERROR: crewdeputy nobl has no records/backlog.md to hand work into" nobl qmove
ddep noq; dput home/crewdeputies/noq/records/backlog.md $'# Backlog\n\n## Done\n'
dreg '- noq - n - home: @H/home/crewdeputies/noq - scope: s - projects: none (added x)'
drefuse "ERROR: crewdeputy noq has no '## Queued' section in its backlog" noq qmove
printf '%s\n%s' '- [ ] qtop - before any heading (repo: alpha)' "$(cat "$H/home/records/backlog.md")" >"$H/home/records/backlog.md"
drefuse "ERROR: 'qtop' sits under '## ', not '## Queued' - only queued work can follow a domain" pay qtop
rm "$H/home/records/backlog.md"
drefuse "ERROR: no parent backlog at @H/home/records/backlog.md" pay qmove

# 11. handoff edges: an id's own row is never its dependent; a backup
#     directory that refuses the claim WARNs and moves nothing; an unwritable
#     status log ends handoff 1 after the move; a deputy records/ that cannot
#     be written refuses before any write; bun absent from PATH.
dseed; d9
perl -0pi -e 's/(## Queued\n)/$1- [ ] qself - mine (repo: alpha) blocked-by: qself, zz - spaced\n/' "$H/home/records/backlog.md"
drun handoff pay qself
assert_eq "$DN_RC:$(dout | tail -n1)" "0:handed qself to pay" "11: the own row's malformed blocked-by never refuses it"
if [ "$(id -u)" != 0 ]; then
  chmod 555 "$H/home/state/backups"
  drun handoff pay qnorepo
  chmod 755 "$H/home/state/backups"
  assert_eq "$DN_RC:$(dout)" "1:" "11: a backup that cannot be claimed ends it 1, nothing moved, no backup line"
  assert_contains "$(derr)" "WARN: records backup: could not create @H/home/state/backups/deputy-handoff-1767225600-" "11: the claim's WARN"
  assert_contains "$(derr)" ".tar.gz (is @H/home/state/backups writable?) - no backup archive was taken" "11: ... naming the directory"
  /usr/bin/grep -q qnorepo "$H/home/records/backlog.md" || fail "11: ... the row stays in the parent"
  dput home/state/pay.status $'old\n'; chmod 444 "$H/home/state/pay.status"
  drun handoff pay qx
  chmod 644 "$H/home/state/pay.status"
  assert_eq "$DN_RC:$(dout | tail -n1)" "1:- [x] qx - checked but queued (repo: alpha)" "11: an unwritable status log ends handoff 1 after the move, no handed line"
  /usr/bin/grep -q 'qx - checked' "$H/home/crewdeputies/pay/records/backlog.md" || fail "11: ... the row already moved"
  chmod 555 "$H/home/crewdeputies/pay/records"
  drun handoff pay qnorepo
  chmod 755 "$H/home/crewdeputies/pay/records"
  assert_eq "$DN_RC:$(dout):$(derr)" "1::ERROR: crewdeputy pay's records/backlog.md cannot be locked - its directory is not writable - nothing written" \
    "11: a deputy records/ that cannot be written refuses before any write"
  /usr/bin/grep -q qnorepo "$H/home/records/backlog.md" || fail "11: ... the row stays in the parent"
  [ -z "$(ls "$H/home/records" | /usr/bin/grep '\.moving\.' || true)" ] || fail "11: ... with no .moving. temp"
fi
DPATH="$DSTUBS:$TMP/stubbin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$DPATH" command -v bun || true)" ]; then
  dseed; d9
  drun handoff pay qmove
  assert_eq "$DN_RC:$(derr)" "1:ERROR: required tool not found: bun" "11: bun absent - the shim never starts"
else
  printf 'SKIP: row 11 bun-absent - bun shares a system directory on this host\n'
fi
DPATH=""

# 12. EXCLUSIVE TEMPS: a 0600 parent ledger keeps its mode. A symlink planted
#     at `<ledger>.tmp.<pid>` is left alone - the next name is claimed and
#     nothing is written through it. The run starts behind a fifo gate and
#     execs into the entry as the pid the name is planted for.
dseed; d9
chmod 600 "$H/home/records/backlog.md"
drun handoff pay qmove
assert_eq "$DN_RC:$(ls -l "$H/home/records/backlog.md" | cut -c1-10)" "0:-rw-------" "12: the ledger keeps its mode"
cat >"$TMP/dgate.sh" <<'EOF'
#!/usr/bin/env bash
_id="$(/bin/ps -o lstart= -p $$)"
( sleep 60; [ "$(/bin/ps -o lstart= -p $$)" != "$_id" ] || kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 &
_wd=$!
read -r _ <"$1"
kill "$_wd" 2>/dev/null || true
exec "$2/ac-deputy.sh" handoff pay qkeep
EOF
chmod +x "$TMP/dgate.sh"
dgate="$H/gate.fifo"; mkfifo "$dgate"
printf 'victim bytes\n' >"$H/victim"
env -u AC_BACKEND LC_ALL=C AC_HOME="$H/home" PATH="$DSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$H" FAKE_HERDR="$H/herdr" \
  "$TMP/dgate.sh" "$dgate" "$BIN" </dev/null >"$TMP/dplant.out" 2>&1 &
dppid=$!
ln -s "$H/victim" "$H/home/records/backlog.md.tmp.$dppid"
printf x >"$dgate"
wait "$dppid" || fail "12: handoff failed: $(cat "$TMP/dplant.out")"
assert_contains "$(cat "$TMP/dplant.out")" "handed qkeep to pay" "12: the handoff completes"
[ ! -L "$H/home/records/backlog.md" ] || fail "12: the ledger stays a regular file"
assert_eq "$(cat "$H/victim")" "victim bytes" "12: nothing is written through a planted temp name"
case "$(cat "$H/home/records/backlog.md")" in *qkeep*) fail "12: qkeep left the ledger" ;; *qnorepo*) ;; *) fail "12: the ledger kept its other rows" ;; esac
[ -L "$H/home/records/backlog.md.tmp.$dppid" ] || fail "12: the planted link is left where it was"

pass
