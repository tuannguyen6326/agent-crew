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

# --- differential: src/deputy.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-deputy.sh under bash vs src/deputy.ts through bin/ac-deputy.sh)
# HELD-CONSTANT: two side roots seeded alike ($DOH for the oracle, $DNH for the shim) - a parent home at <side>/home with its deputy homes under crewdeputies/, and the fake herdr's state at <side>/herdr; argv and env (the side root spelled @H, substituted in values only); cwd (the side root); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - make_fake_herdr's herdr, an orca answering per sentinel file, a date answering one fixed instant per format (or failing per sentinel); the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT, pids PID), then the world a row may touch: every path under the home, every ledger and registry, every status log, spool record and timeline, the backup listings (tar -tzf) and the stub logs.
dobin="$(make_oracle_bin ac-deputy)"
# The frozen entry calls ac_records_backup, retired from
# bin/ac-maintenance-lib.sh once src/learn.ts took its last caller; the
# oracle's own lib copy gets it back, frozen at
# tests/fixtures/ac-maintenance-retired.sh.
cat "$ROOT/tests/fixtures/ac-maintenance-retired.sh" >>"$dobin/ac-maintenance-lib.sh"
DOH="$TMP/dside-o"; DNH="$TMP/dside-n"
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
dboth() {  # dboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$DOH" "$DNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
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
DLC=C; DENV=(); DHOME=home; DHOMELESS=0; DPATH=""
drun_side() {  # drun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=("LC_ALL=$DLC" "PATH=${DPATH:-$DSTUBS:$TMP/stubbin:$PATH}" "STUB_DIR=$h" "FAKE_HERDR=$h/herdr")
  [ "$DHOMELESS" = 1 ] || e+=("AC_HOME=$h/$DHOME")
  for x in ${DENV[@]+"${DENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN \
    "${e[@]}" "$bin/ac-deputy.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
dnorm() {
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-deputy#ROOT#g" -e "s#$TMP/dloadfail#ROOT#g" -e "s#$TMP/loadfail#ROOT#g" \
    -e "s#$ROOT#ROOT#g" -e 's/\.(moving|tmp)\.[0-9]+/.\1.PID/g' -e 's/(1767225600000000000)\.[0-9]+\./\1.PID./g' \
    -e 's/\.wake-tmp\.[A-Za-z0-9]{8}/.wake-tmp.XXXXXXXX/g' "$1"
}
DO_RC=0; DN_RC=0; DO_BIN="$dobin"; DN_BIN="$BIN"
dpair() {  # dpair <args...> - both sides run, outputs normalised, nothing compared yet
  DO_RC=0; DN_RC=0
  drun_side "$DO_BIN" "$DOH" o "$@" || DO_RC=$?
  drun_side "$DN_BIN" "$DNH" n "$@" || DN_RC=$?
  dnorm "$TMP/o.raw" "$DOH" >"$TMP/o.out"; dnorm "$TMP/o.err" "$DOH" >"$TMP/o.err2"
  dnorm "$TMP/n.raw" "$DNH" >"$TMP/n.out"; dnorm "$TMP/n.err" "$DNH" >"$TMP/n.err2"
}
drow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
dsame_rc_out() {
  assert_eq "$DN_RC" "$DO_RC" "deputy differential exit for '$*' at line $(drow)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "deputy differential stdout differs for '$*' at line $(drow): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
}
dsame_io() {
  dsame_rc_out "$@"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "deputy differential stderr differs for '$*' at line $(drow): $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 8)"
}
dworld() {  # dworld <side root> - what a row may change
  local h="$1" f
  # Names hold a pid, so each listing is ordered after the pid is spelled PID.
  (cd "$h/home" && find . 2>/dev/null | sed -E -e 's/\.(moving|tmp)\.[0-9]+/.\1.PID/g' -e 's/(1767225600000000000)\.[0-9]+\./\1.PID./g' \
    -e 's/\.wake-tmp\.[A-Za-z0-9]{8}/.wake-tmp.XXXXXXXX/g' | LC_ALL=C sort)
  printf '== spool\n'
  for f in "$h"/home/state/.wake-spool/* "$h"/home/state/.wake-tmp.*; do [ ! -f "$f" ] || cat "$f"; done | LC_ALL=C sort
  for f in "$h"/home/records/* "$h"/home/crewdeputies/*/records/* "$h"/home/other/*/records/* "$h"/home/state/*.status \
    "$h"/home/data/*/timeline.log "$h"/home/crewdeputies/*/state/* "$h"/herdr/log "$h"/*.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; cat "$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  # A backup the port takes under the ledger lock carries the lock dir, one
  # the original took with no lock does not (named in row 9).
  for f in "$h"/home/state/backups/*; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; tar -tzf "$f" 2>&1 | grep -v '^records/\.backlog\.md\.lock' | LC_ALL=C sort
  done
}
dsame_world() {
  dworld "$DOH" >"$TMP/o.world"; dworld "$DNH" >"$TMP/n.world"
  dnorm "$TMP/o.world" "$DOH" >"$TMP/o.world2"; dnorm "$TMP/n.world" "$DNH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "deputy differential world differs after '$*' at line $(drow): $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 10)"
}
dsame() { dpair "$@"; dsame_io "$@"; dsame_world "$@"; }
dout() { cat "$TMP/n.out"; }
derr() { cat "$TMP/n.err2"; }
doerr() { cat "$TMP/o.err2"; }
DNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
DUSAGE='ERROR: usage: ac-deputy.sh <list|validate|report|handoff>'
DBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
DTS='2026-01-01T00:00:00Z'
dboth dseed

# 1. usage, and the backend gate BEFORE the verb (W2): none, -h, LIST and an
#    unknown verb are the usage line; config/backend tmux ends every argv,
#    usage included, with ac_backend's refusal.
for dv in "" -h LIST bogus; do
  # shellcheck disable=SC2086
  dsame $dv
  assert_eq "$DN_RC:$(dout):$(derr)" "1::$DUSAGE" "1: '$dv' is the usage line, exit 1"
done
dsame list extra args
assert_eq "$(dout)" "ABSENT: records/crewdeputies.md - no crewdeputies registered" "1: extra arguments to list are never read"
dboth dput home/config/backend $'tmux\n'
for dv in list "report x" "handoff d x" bogus ""; do
  # shellcheck disable=SC2086
  dsame $dv
  assert_eq "$DN_RC:$(derr)" "1:$DBAD" "1 (W2): config/backend tmux refuses '$dv' before the verb"
done
dboth rm -f @H/home/config/backend
DENV=(AC_BACKEND=Herdr); dsame list; assert_eq "$DN_RC" 1 "1 (W2): AC_BACKEND=Herdr refuses"; DENV=()
dboth dput fs/config/backend $'bogus\tx\n'; dboth mkdir -p @H/fs/state
DENV=(AC_FLEET_STATE=@H/fs/state/); dsame validate
assert_eq "$(derr)" "ERROR: unsupported backend 'bogus' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "1: the AC_FLEET_STATE rung, cut at its first blank"
DENV=()

# 2. homeless (W1, reproduced): list says ABSENT after the refusal, exit 0;
#    validate is the refusal alone, exit 0; report prints it once then the
#    marker refusal; handoff prints it THREE times - one per swallowed
#    $(ac_home) - then names `/crewdeputies.md`. An AC_HOME that cannot be
#    entered: exit and stdout alike, the shell's own `cd:` lines named.
DHOMELESS=1
dsame list
assert_eq "$(derr)|$(dout)" "$DNOHOME|ABSENT: records/crewdeputies.md - no crewdeputies registered" "2 (W1): homeless list"
dsame validate
assert_eq "$DN_RC:$(derr)" "0:$DNOHOME" "2 (W1): homeless validate"
dsame report x
assert_eq "$(derr)" "$DNOHOME
ERROR: report runs INSIDE a crewdeputy home (no .ac-crewdeputy-home marker here)" "2 (W1): homeless report"
dsame handoff d x
assert_eq "$(derr)" "$DNOHOME
$DNOHOME
$DNOHOME
ERROR: no crewdeputy 'd' in /crewdeputies.md" "2 (W1): homeless handoff prints the refusal three times"
DHOMELESS=0
DHOME=missing
for dv in list validate "report x" "handoff d x"; do
  # shellcheck disable=SC2086
  dpair $dv; dsame_rc_out $dv; dsame_world $dv
  assert_contains "$(doerr)" "No such file or directory" "2: the original's line for an unenterable AC_HOME is cd's own ('$dv')"
  assert_contains "$(derr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "2: the port names the variable ('$dv', named)"
done
DHOME=home

# 3. list, the registry's shapes: absent, a directory, heading-only (EMPTY),
#    a lone `- `, the full table (LIVE, DOWN by a gone pane and by no handle,
#    NOT-RUNNING, HOME-MISSING by an absent home and by a marker DIRECTORY,
#    LEGACY with clones, a duplicate id, INVALID with its verbatim source),
#    a TAB inside an INVALID line and inside a VALID charter (W3), a UTF-8
#    `e-acute` id and a lone 0xE9 byte (bad id charset under C; under UTF-8
#    awk's towc abort ends list 2 with nothing printed - W4, reproduced: the
#    port spawns the same awk under the same locale).
dsame list
assert_eq "$(dout)" "ABSENT: records/crewdeputies.md - no crewdeputies registered" "3: absent"
dboth mkdir @H/home/records/crewdeputies.md
dsame list; assert_contains "$(dout)" "ABSENT:" "3: a directory is ABSENT"
dboth rmdir @H/home/records/crewdeputies.md
dboth dput home/records/crewdeputies.md $'# Crewdeputies\n\n'
dsame list; assert_eq "$(dout)" "EMPTY: records/crewdeputies.md present, 0 entries - no crewdeputies registered" "3: heading-only is EMPTY"
dboth dreg '- '
dsame list
assert_eq "$(dout)" "INVALID	- 	reason: missing \"(added ...)\"
registered: 1 (live 0, down 0, not-running 0, home-missing 0, invalid 1)" "3: a lone '- '"
d3() {
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
    'prose that is no entry' \
    $'- ta\tb - home /abs - no projects (added x)'
}
dboth d3
dsame list
assert_eq "$(dout)" "LIVE	dlive	home: @H/home/crewdeputies/dlive	projects: alpha
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
INVALID	- ta	reason: $(printf '\037')missing \"home:\" field
registered: 10 (live 1, down 2, not-running 2, home-missing 2, invalid 3)" "3: the full table, W3's cut INVALID source and its US-led reason"
assert_contains "$(cat "$DNH/herdr/log")" "herdr pane get pD1" "3: the probe went to the fake herdr"
d3b() {
  rm -f "$H/home/records/crewdeputies.md"; ddep dtab
  dreg $'- dtab - pay\tduty - home: @H/home/crewdeputies/dtab - scope: s - projects: p (added x)' \
    $'- caf\303\251 - c - home: /h/caf\303\251 - scope: s - projects: none (added x)'
}
dboth d3b
dsame list
assert_eq "$(dout)" "NOT-RUNNING	dtab	home: @H/home/crewdeputies/dtab	projects: s
	charter: pay
	scope: duty
	recover: bin/ac-spawn.sh dtab --crewdeputy --recover
INVALID	- caf$(printf '\303\251') - c - home: /h/caf$(printf '\303\251') - scope: s - projects: none (added x)	reason: bad id charset
registered: 2 (live 0, down 0, not-running 1, home-missing 0, invalid 1)" "3 (W3): a TAB in a VALID charter shifts the fields"
DLC=en_US.UTF-8; dsame list; DLC=C
assert_contains "$(dout)" "reason: bad id charset" "3: an e-acute id is bad id charset under UTF-8 too"
d3c() { dreg $'- b\351d - c - home: /h/b\351d - scope: s - projects: none (added x)'; }
dboth d3c
dsame list
assert_contains "$(dout)" "reason: bad id charset" "3: a 0xE9 byte under C"
DLC=en_US.UTF-8; dsame list; DLC=C
assert_eq "$DN_RC:$(dout)" "2:" "3 (W4): under UTF-8 the parse aborts and list exits 2 with nothing on stdout"
assert_contains "$(derr)" "towc: multibyte conversion failure" "3 (W4): awk's own line"

# 4. liveness: the fake herdr unreachable and herdr absent from PATH are
#    UNOBSERVABLE; a stale tmux meta is the route's ERROR then DOWN - in that
#    order on a merged stream, a UTF-8 name refused as its bytes, one that is
#    not UTF-8 as U+FFFD (named); an orca meta against the orca stub, connected
#    (LIVE), disconnected (DOWN), show failing with status answering (DOWN),
#    both failing (UNOBSERVABLE).
d4() {
  rm -f "$H/home/records/crewdeputies.md" "$H/home/state/"*.meta "$H/home/state/".pane-*
  ddep dh; ddep dt; ddep dorca
  dlive dh pH1
  printf 'backend=tmux\nkind=crewdeputy\n' >"$H/home/state/dt.meta"; printf 'pT tT\n' >"$H/home/state/.pane-dt"
  printf 'backend=orca\nkind=crewdeputy\n' >"$H/home/state/dorca.meta"; printf 'term-1 tab-1\n' >"$H/home/state/.pane-dorca"
  dreg '- dh - h - home: @H/home/crewdeputies/dh - scope: s - projects: none (added x)' \
    '- dt - t - home: @H/home/crewdeputies/dt - scope: s - projects: none (added x)' \
    '- dorca - o - home: @H/home/crewdeputies/dorca - scope: s - projects: none (added x)'
}
dboth d4
dsame list
assert_eq "$(dout | /usr/bin/grep -v '^	')" "LIVE	dh	home: @H/home/crewdeputies/dh	projects: none
DOWN	dt	home: @H/home/crewdeputies/dt	projects: none
DOWN	dorca	home: @H/home/crewdeputies/dorca	projects: none
registered: 3 (live 1, down 2, not-running 0, home-missing 0, invalid 0)" "4: herdr live, tmux stale, orca disconnected"
assert_eq "$(derr)" "$DBAD" "4: the stale meta's refusal reaches stderr"
merged() {  # merged <bin> <side root> - list with stdout and stderr on one stream
  (cd "$2" && env -u AC_HOME -u AC_BACKEND LC_ALL=C PATH="$DSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$2" FAKE_HERDR="$2/herdr" AC_HOME="$2/home" \
    "$1/ac-deputy.sh" list) </dev/null 2>&1 | dnorm /dev/stdin "$2" | /usr/bin/grep -v '^	'
}
dmn="$(merged "$BIN" "$DNH")"
assert_eq "$dmn" "$(merged "$dobin" "$DOH")" "4: the same merged stream"
assert_eq "$(printf '%s\n' "$dmn" | sed -n 2,3p)" "$DBAD
DOWN	dt	home: @H/home/crewdeputies/dt	projects: none" "4: the ERROR precedes its entry's line"
dboth dput home/state/dt.meta $'backend=caf\303\251\nkind=crewdeputy\n'
dsame list; assert_eq "$(derr)" "ERROR: unsupported backend 'caf$(printf '\303\251')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a meta's UTF-8 backend name is refused as its bytes"
dboth dput home/state/dt.meta $'backend=caf\351\nkind=crewdeputy\n'
dpair list; dsame_rc_out list; dsame_world list
assert_eq "$(doerr)" "ERROR: unsupported backend 'caf$(printf '\351')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= - the original's byte"
assert_eq "$(derr)" "ERROR: unsupported backend 'caf$(printf '\357\277\275')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= - the port's U+FFFD (named)"
dboth dput home/state/dt.meta $'backend=tmux\nkind=crewdeputy\n'
dboth touch @H/orca.connected
dsame list; assert_contains "$(dout)" "LIVE	dorca" "4: orca connected is LIVE"
dboth rm -f @H/orca.connected
dboth touch @H/orca.show-fail
dsame list; assert_contains "$(dout)" "DOWN	dorca" "4: orca show failing, status answering, is DOWN"
dboth touch @H/orca.status-fail
dsame list; assert_contains "$(dout)" "UNOBSERVABLE	dorca" "4: orca unreadable is UNOBSERVABLE"
dboth rm -f @H/orca.show-fail @H/orca.status-fail
dboth touch @H/herdr/.unreachable
dsame list; assert_contains "$(dout)" "UNOBSERVABLE	dh" "4: an unreachable herdr is UNOBSERVABLE"
dboth rm -f @H/herdr/.unreachable
DPATH="$DSTUBS:$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$DPATH" command -v herdr || true)" ]; then
  dsame list; assert_contains "$(dout)" "UNOBSERVABLE	dh" "4: herdr absent from PATH is UNOBSERVABLE"
else
  printf 'SKIP: row 4 herdr-absent - bun shares its directory with a herdr on this host\n'
fi
DPATH=""
# Named (D1): a driver that failed to LOAD is the oracle's 127, read as
# UNOBSERVABLE; the shim has no counterpart (N/A - its backend verbs are
# native, src/lib.ts backendCall), so the oracle alone runs this row, through
# its own lab copy with the herdr driver renamed.
mkdir -p "$TMP/dloadfail"
cp -R "$dobin" "$TMP/dloadfail/bin"; ln -s "$ROOT/src" "$TMP/dloadfail/src"
sed -i.bak 's/^backend_window_alive_herdr() {/backend_window_alive_herdr_MISSING_DRIVER() {/' "$TMP/dloadfail/bin/ac-backend.sh"
rm -f "$TMP/dloadfail/bin/ac-backend.sh.bak"
DO_RC=0; drun_side "$TMP/dloadfail/bin" "$DOH" o list || DO_RC=$?
dnorm "$TMP/o.raw" "$DOH" >"$TMP/o.out"; dnorm "$TMP/o.err" "$DOH" >"$TMP/o.err2"
assert_eq "$DO_RC" 0 "4: the oracle lists past a 127 driver"
assert_contains "$(cat "$TMP/o.out")" "UNOBSERVABLE	dh" "4: the oracle's 127 driver is UNOBSERVABLE"
assert_contains "$(doerr)" "backend_window_alive_herdr: command not found" "4: ...bash names the missing driver"
dboth rm -f @H/orca.log @H/herdr/log   # the oracle alone ran: both worlds' stub logs restart in step

# 5. validate: absent and a directory are silent 0; clean is silent 0; each
#    INVALID line is `INVALID <src>: <reason>`, exit 1; W3's TAB; a 0xE9 byte
#    under C, and under UTF-8 where the parse aborts inside the heredoc's
#    $(...) - errexit asleep - so validate passes silently (W4).
dboth rm -f @H/home/records/crewdeputies.md
dsame validate; assert_eq "$DN_RC:$(dout)" "0:" "5: absent"
dboth dreg '- ok - c - home: /h/ok - scope: s - projects: none (added x)'
dsame validate; assert_eq "$DN_RC:$(dout)" "0:" "5: clean"
dboth dreg '- ops2 - home /abs - no projects (added x)' $'- ta\tb - home /abs (added x)' '- '
dsame validate
assert_eq "$DN_RC:$(dout)" "1:INVALID - ops2 - home /abs - no projects (added x): missing \"home:\" field
INVALID - ta: $(printf '\037')missing \"home:\" field
INVALID - : missing \"(added ...)\"" "5: each INVALID line, W3's cut"
dboth d3c
dsame validate; assert_contains "$(dout)" "bad id charset" "5: 0xE9 under C"
DLC=en_US.UTF-8; dsame validate; DLC=C
assert_eq "$DN_RC:$(dout | cut -d: -f1)" "1:INVALID - ops2 - home /abs - no projects (added x)
INVALID - ta
INVALID - " "5 (W4): under UTF-8 the lines past the abort go unreported"
d5() { rm -f "$H/home/records/crewdeputies.md"; dreg '- ok - c - home: /h/ok - scope: s - projects: none (added x)'; d3c; }
dboth d5
DLC=en_US.UTF-8; dsame validate; DLC=C
assert_eq "$DN_RC:$(dout)" "0:" "5 (W4): a registry whose only fault is that byte passes silently under UTF-8"
dsame validate
assert_eq "$DN_RC:$(dout)" "1:INVALID - b$(printf '\351')d - c - home: /h/b$(printf '\351')d - scope: s - projects: none (added x): bad id charset" "5: ... and fails under C"

# 6. report from a deputy home: the parent's status line (raw, W6) and ONE
#    spool record (TAB and LF folded); --doc; % and backslashes raw; a home
#    named 07 found as registry id 7 (awk's numeric ==, W5 - no WARN); an
#    unregistered deputy and an absent registry WARN and still deliver.
d6() {
  rm -f "$H/home/records/crewdeputies.md"; ddep pay; ddep 07; ddep 7
  dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)' \
    '- 7 - seven - home: @H/home/crewdeputies/7 - scope: s - projects: none (added x)'
}
dboth d6
DHOME=home/crewdeputies/pay
dsame report 'done: interest rounding fixed'
assert_eq "$(dout)" "reported pay to @H/home" "6: the report line"
assert_eq "$(cat "$DNH/home/state/pay.status")" "$DTS report: done: interest rounding fixed" "6: the parent's status line"
assert_eq "$(cat "$DNH"/home/state/.wake-spool/*)" "1767225600	deputy	pay	done: interest rounding fixed" "6: one spool record"
dsame report 'done: audit' --doc @H/home/crewdeputies/pay/data/r.md
assert_eq "$(tail -n1 "$DNH/home/state/pay.status")" "$DTS report: done: audit doc: $DNH/home/crewdeputies/pay/data/r.md" "6: --doc rides the line"
dsame report $'blocked: needs\ta decision\non rounding'
assert_eq "$(tail -n2 "$DNH/home/state/pay.status")" "$DTS report: blocked: needs	a decision
on rounding" "6 (W6): the status line keeps TAB and LF raw"
dsame report 'done: 100% \n \\ %s done'
dsame report 'x' --doc '' --doc @H/a --doc @H/b
assert_eq "$(tail -n1 "$DNH/home/state/pay.status")" "$DTS report: x doc: $DNH/b" "6 (W9): the last --doc wins"
dsame report 'y' --doc ''
assert_eq "$(tail -n1 "$DNH/home/state/pay.status")" "$DTS report: y" "6 (W9): --doc '' is no doc"
DHOME=home/crewdeputies/07
dsame report 'done: seven'
assert_eq "$(derr)" "" "6 (W5): 07 finds registry id 7 - no WARN"
DHOME=home/crewdeputies/pay
dboth dput home/records/crewdeputies.md $'# Crewdeputies\n'
dsame report 'done: unregistered'
assert_eq "$(derr)" "WARN: no registry entry for pay in the parent's routing table - delivering the return anyway" "6: unregistered warns"
dboth rm -f @H/home/records/crewdeputies.md
dsame report 'done: no registry'
assert_contains "$(derr)" "no registry entry for pay" "6: an absent registry warns"
dboth touch @H/date.fail
dsame report 'done: no stamp'
assert_eq "$(tail -n1 "$DNH/home/state/pay.status")" " report: done: no stamp" "6: a failing date leaves the stamp empty"
dboth rm -f @H/date.fail
dboth touch @H/date.fail-ns
dsame report 'done: no clock'
assert_eq "$DN_RC" 4 "6: a failing ns date ends the unguarded publish with its status"
dboth rm -f @H/date.fail-ns

# 7. report refusals, each minting nothing: from the parent, empty text, no
#    text, a relative --doc, --doc with no value, --doc as the text (W9), an
#    extra positional; an orphan with no state/ two levels up; a grandparent
#    that is not crewdeputies/ still receives (W10); a symlinked deputy home
#    resolves physically.
DHOME=home; dsame report x
assert_eq "$(derr)" "ERROR: report runs INSIDE a crewdeputy home (no .ac-crewdeputy-home marker here)" "7: from the parent"
DHOME=home/crewdeputies/pay
dsame report ''; assert_eq "$(derr)" "ERROR: usage: ac-deputy.sh report '<text>' [--doc <abs-path>]" "7: empty text"
dsame report; assert_eq "$(derr)" "ERROR: usage: ac-deputy.sh report '<text>' [--doc <abs-path>]" "7: no text"
dsame report x --doc rel/p; assert_eq "$(derr)" "ERROR: --doc must be an absolute path (the parent resolves it from its own home): rel/p" "7: relative --doc"
dsame report x --doc; assert_eq "$(derr)" "ERROR: --doc needs a value" "7: --doc alone"
dsame report --doc @H/x; assert_eq "$(derr)" "ERROR: unknown argument: @H/x" "7 (W9): --doc as the text"
dsame report x y; assert_eq "$(derr)" "ERROR: unknown argument: y" "7: an extra positional"
dsame report '' bogus; assert_eq "$(derr)" "ERROR: unknown argument: bogus" "7: arguments are read before the text"
dorphan() { mkdir -p "$H/orphan/crewdeputies/px/state"; : >"$H/orphan/crewdeputies/px/.ac-crewdeputy-home"; }
dboth dorphan
DHOME=orphan/crewdeputies/px; dsame report x
assert_eq "$(derr)" "ERROR: cannot resolve a parent fleet above @H/orphan/crewdeputies/px - refusing to write a return with nowhere to land" "7: an orphan"
[ ! -e "$DNH/orphan/state" ] || fail "7: a refused report mints nothing above"
dboth ddep px other
DHOME=home/other/px; dsame report 'done: odd parent'
assert_eq "$(dout)" "reported px to @H/home" "7 (W10): any grandparent holding state/ receives"
dboth ln -s @H/home/crewdeputies/pay @H/paylink
DHOME=paylink; dsame report 'done: via link'
assert_eq "$(dout)" "reported pay to @H/home" "7: a symlinked home resolves physically"
DHOME=home

# 8. report failures: an unwritable parent status log ends it 1 with no wake
#    (the shell's own redirection line not reproduced); a spool directory that
#    refuses the link ends it 1 with no line and the .wake-tmp. litter (W8);
#    a text byte that is not UTF-8 arrives as U+FFFD (argv is decoded) - the
#    original wrote 0xE9, and under UTF-8 its tr aborted (W7: exit 1, status
#    appended, no wake) where the port publishes.
if [ "$(id -u)" != 0 ]; then
  dboth dseed; dboth d6
  dboth dput home/state/pay.status $'old\n'; dboth chmod 444 @H/home/state/pay.status
  DHOME=home/crewdeputies/pay; dpair report 'done: x'; dsame_rc_out report; dsame_world report
  assert_eq "$DN_RC:$(derr)" "1:" "8: an unwritable status log ends it 1, silently in the port"
  assert_contains "$(doerr)" "Permission denied" "8: the original's line is the shell's own (named)"
  dboth chmod 644 @H/home/state/pay.status
  dboth mkdir -p @H/home/state/.wake-spool; dboth chmod 555 @H/home/state/.wake-spool
  dsame report 'done: spool refuses'
  assert_eq "$DN_RC:$(dout)" "1:" "8 (W8): a refused publish is exit 1, no line"
  [ -n "$(ls -a "$DNH/home/state" | /usr/bin/grep '^\.wake-tmp\.' || true)" ] || fail "8 (W8): the temp is left"
  dboth chmod 755 @H/home/state/.wake-spool
  DHOME=home
fi
dboth dseed; dboth d6
DHOME=home/crewdeputies/pay
dpair report $'done: caf\351'
dsame_rc_out report
assert_eq "$(tail -c 5 "$DOH/home/state/pay.status" | od -An -tx1 | tr -d ' \n')" "636166e90a" "8: the original wrote the byte"
assert_eq "$(tail -c 7 "$DNH/home/state/pay.status" | od -An -tx1 | tr -d ' \n')" "636166efbfbd0a" "8: the port's argv was decoded (named)"
DLC=en_US.UTF-8; dpair report $'done: caf\351'; DLC=C
assert_eq "$DO_RC:$DN_RC" "1:0" "8 (W7): under UTF-8 the original's tr aborted where the port publishes (named)"
assert_contains "$(doerr)" "tr: Illegal byte sequence" "8 (W7): tr's own line"
# No date on PATH: the stamp's capture read "" and the line was still
# written; the unguarded publish then died on date's 127 - no wake. A PATH of
# links holding only what each side runs; the shell's own `command not
# found` lines are not reproduced.
dnodate="$TMP/dnodate"; mkdir -p "$dnodate"
for c in bash bun awk tr basename mkdir mkfifo dirname; do ln -sf "$(command -v "$c")" "$dnodate/$c"; done
dboth dseed; dboth d6
DPATH="$dnodate"; dpair report 'done: clock absent'; DPATH=""
dsame_rc_out report; dsame_world report
assert_eq "$DN_RC:$(cat "$DNH/home/state/pay.status")" "127: report: done: clock absent" "8: no date - an empty stamp, the line written, exit 127"
assert_eq "$(ls -A "$DNH/home/state")" "pay.status" "8: no date - no wake record, no temp"
assert_contains "$(doerr)" "date: command not found" "8: the original's lines are the shell's own (named)"
assert_eq "$(derr)" "" "8: the port prints none"
DHOME=home

# 9. handoff: one id, two (argv order), a [x] row under Queued, local-only,
#    unpinned and repo-less rows; the deputy's own queued work stays AHEAD
#    and rows land after the Queued block's blank line (W15); Queued last
#    appends at EOF; an unterminated deputy line gains its LF; the timeline
#    mirror only for a deputy with a meta (12).
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
dboth dseed; dboth d9
dsame handoff pay qmove
assert_eq "$(dout)" "backup: @H/home/state/backups/deputy-handoff-1767225600.tar.gz
- [ ] qmove [mode:direct-pr] - move me (repo: alpha)
handed qmove to pay" "9: one id"
assert_eq "$(cat "$DNH/home/crewdeputies/pay/records/backlog.md")" "# Backlog

## In flight

## Queued
- [ ] own1 - the deputy own queued work (repo: alpha)

- [ ] qmove [mode:direct-pr] - move me (repo: alpha)
## Done" "9 (W15): behind the deputy's own, after the blank line"
dsame handoff pay qnopin qlocal qnorepo qx
assert_eq "$(dout | sed -n 2,5p | cut -c1-12)" "- [ ] qnopin
- [ ] qlocal
- [ ] qnorep
- [x] qx - c" "9: argv order"
assert_eq "$(ls "$DNH/home/state/backups")" "deputy-handoff-1767225600-1.tar.gz
deputy-handoff-1767225600.tar.gz" "9: a second backup in the same second steps to -1"
[ ! -e "$DNH/home/data/pay" ] || fail "12: no timeline for a deputy without a meta"
d9b() { printf '# Backlog\n\n## In flight\n\n## Done\n\n## Queued\n- [ ] own1 - unterminated' >"$H/home/crewdeputies/pay/records/backlog.md"; printf 'kind=crewdeputy\n' >"$H/home/state/pay.meta"; }
dboth d9b
dsame handoff pay qkeep
assert_eq "$(tail -n 2 "$DNH/home/crewdeputies/pay/records/backlog.md")" "- [ ] own1 - unterminated
- [ ] qkeep [mode:direct-pr] - keep me (repo: alpha)" "9: Queued last appends at EOF, the unterminated line gains its LF"
assert_eq "$(cat "$DNH/home/data/pay/timeline.log")" "$DTS handoff: qkeep" "12: the timeline mirror for a deputy with a meta"

# Named (W8, fixed): handoff takes the PARENT ledger's
# lock and then the DEPUTY's, as ac-task.sh takes each, and a live writer
# holding either one is waited out (AC_TASK_LOCK_TIMEOUT) and refused with
# nothing moved; the original took neither. Port-only rows - row 10 reseeds.
dboth dseed; dboth d9
dlockrow() {  # dlockrow <lock dir under the side> <refusal> - a live holder there refuses handoff
  mkdir "$DNH/$1"; printf '%s\n' "$$" >"$DNH/$1/pid"
  local before; before="$(cat "$DNH/home/records/backlog.md" "$DNH/home/crewdeputies/pay/records/backlog.md")"
  DN_RC=0; DENV=(AC_TASK_LOCK_TIMEOUT=1); drun_side "$BIN" "$DNH" n handoff pay qmove || DN_RC=$?; DENV=()
  assert_eq "$DN_RC:$(cat "$TMP/n.raw"):$(cat "$TMP/n.err")" "1::ERROR: $2" "9 (W8): a live holder of $1 refuses handoff"
  assert_eq "$(cat "$DNH/home/records/backlog.md" "$DNH/home/crewdeputies/pay/records/backlog.md")" "$before" "9 (W8): ... with nothing moved"
  assert_eq "$(cat "$DNH/$1/pid")" "$$" "9 (W8): ... and the holder's lock left as it was"
  [ -z "$(ls "$DNH/home/state/backups" 2>/dev/null)" ] || fail "9 (W8): ... and no backup taken"
  rm -rf "${DNH:?}/$1"
}
dlockrow home/records/.backlog.md.lock "records/backlog.md is locked by another writer - nothing written"
dlockrow home/crewdeputies/pay/records/.backlog.md.lock "crewdeputy pay's records/backlog.md is locked by another writer - nothing written"
[ ! -e "$DNH/home/records/.backlog.md.lock" ] || fail "9 (W8): a refusal on the deputy's lock releases the parent's it took"
# The point of the lock: a commit the deputy ledger's holder makes before it
# releases survives the handoff, which reads and rewrites inside the lock.
mkdir "$DNH/home/crewdeputies/pay/records/.backlog.md.lock"; printf '%s\n' "$$" >"$DNH/home/crewdeputies/pay/records/.backlog.md.lock/pid"
DENV=(AC_TASK_LOCK_TIMEOUT=30); drun_side "$BIN" "$DNH" n handoff pay qmove & dlpid=$!; DENV=()
# A checkpoint, not a timer: holding the parent's lock, the handoff is now
# waiting on the deputy's - only then does the holder commit and release.
for _ in $(seq 1 150); do [ ! -s "$DNH/home/records/.backlog.md.lock/pid" ] || break; /bin/sleep 0.2; done
[ -s "$DNH/home/records/.backlog.md.lock/pid" ] || fail "9 (W8): the waiting handoff never took the parent's lock"
case "$(cat "$DNH/home/records/backlog.md" "$DNH/home/crewdeputies/pay/records/backlog.md")" in
  *"own1"*"qmove"*) fail "9 (W8): handoff moved a row while another writer held the deputy's lock" ;;
esac
printf -- '- [ ] held1 - committed by the lock holder\n' >>"$DNH/home/crewdeputies/pay/records/backlog.md"
rm -rf "$DNH/home/crewdeputies/pay/records/.backlog.md.lock"
wait "$dlpid" || fail "9 (W8): the waiting handoff failed: $(cat "$TMP/n.err")"
assert_contains "$(cat "$DNH/home/crewdeputies/pay/records/backlog.md")" "- [ ] held1 - committed by the lock holder" "9 (W8): the holder's commit survives"
assert_contains "$(cat "$DNH/home/crewdeputies/pay/records/backlog.md")" "- [ ] qmove [mode:direct-pr] - move me (repo: alpha)" "9 (W8): ... and the moved row lands after the release"
[ ! -e "$DNH/home/records/.backlog.md.lock" ] && [ ! -e "$DNH/home/crewdeputies/pay/records/.backlog.md.lock" ] || fail "9 (W8): handoff releases both locks"
assert_contains "$(for xf in "$DNH"/home/state/backups/*; do tar -tzf "$xf"; done)" "records/.backlog.md.lock/pid" "9 (W8, named): the port's backup, taken under the parent's lock, carries the lock dir"

# 10. handoff refusals, the parent ledger byte-unchanged: usage x3, inside a
#     deputy home, an unknown deputy, its home gone, no deputy backlog, no
#     Queued section, no parent backlog, In flight, Done, a row before any
#     heading, an epic: token and prose epic: (W13), blocked-by exact, a
#     blocked-by with no ` - `, a malformed one naming the id as a substring
#     (W13), no such id, a good id then a missing one, and an id that is a
#     regex matching two rows.
dboth dseed; dboth d9
drefuse() {  # drefuse <needle> <args...> - both sides refuse alike, nothing moved
  local needle="$1"; shift
  local before; before="$(cat "$DNH/home/records/backlog.md" 2>/dev/null || true)"
  dsame handoff "$@"
  assert_eq "$DN_RC" 1 "10: handoff $* is refused"
  assert_contains "$(derr)" "$needle" "10: handoff $* names its ground"
  assert_eq "$(cat "$DNH/home/records/backlog.md" 2>/dev/null || true)" "$before" "10: handoff $* moves nothing"
}
drefuse "usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..."
drefuse "usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..." pay
drefuse "usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..." '' qmove
DHOME=home/crewdeputies/pay; drefuse "handoff runs in the PARENT fleet home" pay qmove; DHOME=home
drefuse "ERROR: no crewdeputy 'nosuch' in @H/home/records/crewdeputies.md" nosuch qmove
dboth dreg '- gone - g - home: @H/home/crewdeputies/gone - scope: s - projects: none (added x)'
drefuse "ERROR: crewdeputy home is gone: @H/home/crewdeputies/gone" gone qmove
dboth ddep nobl; dboth rm @H/home/crewdeputies/nobl/records/backlog.md
dboth dreg '- nobl - n - home: @H/home/crewdeputies/nobl - scope: s - projects: none (added x)'
drefuse "crewdeputy nobl has no records/backlog.md to hand work into" nobl qmove
dboth ddep noq; dboth dput home/crewdeputies/noq/records/backlog.md $'# Backlog\n\n## Done\n'
dboth dreg '- noq - n - home: @H/home/crewdeputies/noq - scope: s - projects: none (added x)'
drefuse "crewdeputy noq has no '## Queued' section in its backlog" noq qmove
drefuse "sits under '## In flight', not '## Queued'" pay flying
drefuse "sits under '## Done', not '## Queued'" pay donetask
drefuse "'qepic' belongs to an epic" pay qepic
drefuse "'qprose' belongs to an epic" pay qprose
drefuse "'q1' is named in another line's blocked-by:" pay q1
drefuse "no line (or more than one) for 'nosuchitem'" pay nosuchitem
drefuse "no line (or more than one) for 'nosuchitem'" pay qkeep nosuchitem
drefuse "no line (or more than one) for 'q[12]'" pay 'q[12]'
dtop() { printf '%s\n%s' '- [ ] qtop - before any heading (repo: alpha)' "$(cat "$H/home/records/backlog.md")" >"$H/home/records/backlog.md"; }
dboth dtop
drefuse "'qtop' sits under '## ', not '## Queued'" pay qtop
dboth d9
dq3() { perl -0pi -e 's/(## Queued\n)/$1- [ ] q3 - a dependent (repo: alpha) blocked-by: qkeep until the schema lands\n/' "$H/home/records/backlog.md"; }
dboth dq3
drefuse "'qkeep' is named in another line's blocked-by:" pay qkeep
dboth d9
dq4() { perl -0pi -e 's/(## Queued\n)/$1- [ ] q4 - unreadable (repo: alpha) blocked-by: qkeep2, zz - spaced\n/' "$H/home/records/backlog.md"; }
dboth dq4
drefuse "'qkeep' may be named in a malformed blocked-by:" pay qkeep
dboth rm @H/home/records/backlog.md
drefuse "no parent backlog at @H/home/records/backlog.md" pay qmove

# 11. handoff warts: a repeated id doubles the row in the deputy (W11); the
#     id is a regex (W12); 07 resolves registry 7's home (W5); `## Queued-
#     later` is a Queued section (W14); a chmod-000 parent ledger is awk's
#     own error, exit 2 (W18); a backup directory that refuses the claim
#     WARNs and moves nothing; a deputy records/ that refuses the temp AFTER
#     the parent rewrite strands the row in neither ledger and leaves the
#     .moving. temp (W17); a registry past the pipe's capacity with the
#     deputy first ends the lookup's writer with SIGPIPE - exit 141, silent
#     (W19).
dboth dseed; dboth d9
dsame handoff pay qmove qmove
assert_eq "$(dout | tail -n1)" "handed qmove,qmove to pay" "11 (W11): the repeated id is recorded twice"
assert_eq "$(/usr/bin/grep -c qmove "$DNH/home/crewdeputies/pay/records/backlog.md")" 2 "11 (W11): the row lands twice"
dsame handoff pay q.eep
assert_eq "$(dout | tail -n1)" "handed q.eep to pay" "11 (W12): q.eep moved qkeep"
dw5() { ddep 7; dreg '- 7 - seven - home: @H/home/crewdeputies/7 - scope: s - projects: none (added x)'; }
dboth dw5
dsame handoff 07 qnopin
assert_eq "$(dout | tail -n1)" "handed qnopin to 07" "11 (W5): 07 resolves registry 7"
/usr/bin/grep -q qnopin "$DNH/home/crewdeputies/7/records/backlog.md" || fail "11 (W5): into 7's ledger"
assert_eq "$(cat "$DNH/home/state/07.status")" "$DTS handoff: qnopin" "11 (W5): the status under the typed id"
dw14() { dput home/crewdeputies/7/records/backlog.md $'# Backlog\n\n## Queued-later\n\n## Done\n'; }
dboth dw14
dsame handoff 7 qlocal
assert_eq "$(cat "$DNH/home/crewdeputies/7/records/backlog.md")" "# Backlog

## Queued-later

- [ ] qlocal [mode:local-only] - land it locally (repo: locrepo)
## Done" "11 (W14): Queued-later takes the row"
# An id's own row is never its dependent: a malformed blocked-by on it that
# names the id moves with it.
dself() { perl -0pi -e 's/(## Queued\n)/$1- [ ] qself - mine (repo: alpha) blocked-by: qself, zz - spaced\n/' "$H/home/records/backlog.md"; }
dboth dself
dsame handoff pay qself
assert_eq "$(dout | tail -n1)" "handed qself to pay" "11: the own row's malformed blocked-by never refuses it"
if [ "$(id -u)" != 0 ]; then
  dboth chmod 000 @H/home/records/backlog.md
  dsame handoff pay qnorepo
  assert_eq "$DN_RC" 2 "11 (W18): awk's own status"
  assert_contains "$(derr)" "can't open file" "11 (W18): awk's own line"
  dboth chmod 644 @H/home/records/backlog.md
  dboth chmod 555 @H/home/state/backups
  dsame handoff pay qnorepo
  assert_eq "$DN_RC" 1 "11: a backup that cannot be claimed ends it 1"
  assert_contains "$(derr)" "WARN: records backup: could not create @H/home/state/backups/deputy-handoff-1767225600-" "11: the claim's WARN"
  assert_contains "$(derr)" ".tar.gz (is @H/home/state/backups writable?) - no backup archive was taken" "11: ... naming the directory"
  assert_eq "$(dout)" "" "11: nothing moved, no backup line"
  dboth chmod 755 @H/home/state/backups
  dboth dput home/state/pay.status $'old\n'; dboth chmod 444 @H/home/state/pay.status
  dpair handoff pay qx; dsame_rc_out handoff; dsame_world handoff
  assert_eq "$DN_RC:$(dout | tail -n1)" "1:- [x] qx - checked but queued (repo: alpha)" "11: an unwritable status log ends handoff 1 after the move, no handed line"
  assert_contains "$(doerr)" "Permission denied" "11: the original's line is the shell's own (named)"
  dboth chmod 644 @H/home/state/pay.status
  # Named (W17 for this cause): a deputy records/ that cannot be written. The
  # original rewrote the parent, then failed on the deputy's temp, stranding
  # the row in neither ledger; the port cannot make the deputy's ledger lock
  # there, so it refuses before any write. Last in the block - the sides part.
  dboth chmod 555 @H/home/crewdeputies/pay/records
  dpair handoff pay qnorepo
  dboth chmod 755 @H/home/crewdeputies/pay/records
  assert_eq "$DO_RC" 1 "11 (W17): the original's deputy temp refused"
  assert_contains "$(doerr)" "Permission denied" "11 (W17): ... with the shell's own line"
  /usr/bin/grep -q qnorepo "$DOH/home/records/backlog.md" && fail "11 (W17): the original had already rewritten the parent"
  [ -n "$(ls "$DOH/home/records" | /usr/bin/grep '\.moving\.' || true)" ] || fail "11 (W17): ... and left its .moving. temp"
  assert_eq "$DN_RC:$(dout):$(derr)" "1::ERROR: crewdeputy pay's records/backlog.md cannot be locked - its directory is not writable - nothing written" \
    "11 (W17, named): the port refuses before any write"
  /usr/bin/grep -q qnorepo "$DNH/home/records/backlog.md" || fail "11 (W17, named): ... the row stays in the parent"
  [ -z "$(ls "$DNH/home/records" | /usr/bin/grep '\.moving\.' || true)" ] || fail "11 (W17, named): ... with no .moving. temp"
fi
dw19() {
  dseed; d9
  rm -f "$H/home/records/crewdeputies.md"
  dreg '- pay - duty - home: @H/home/crewdeputies/pay - scope: payments - projects: alpha (added x)'
  awk 'BEGIN { for (i = 0; i < 4000; i++) printf "- junk%d - home /abs - no projects, a line long enough to fill the pipe quickly (added x)\n", i }' >>"$H/home/records/crewdeputies.md"
}
dboth dw19
dsame handoff pay qmove
assert_eq "$DN_RC:$(dout):$(derr)" "141::" "11 (W19): the lookup's early exit SIGPIPEs the parse - 141, silent"
DPATH="$DSTUBS:$TMP/stubbin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$DPATH" command -v bun || true)" ]; then
  dboth dseed; dboth d9
  dpair handoff pay qmove
  assert_eq "$DO_RC:$DN_RC" "1:1" "11: bun absent ends both 1"
  assert_eq "$(doerr)" "ERROR: required tool not found: bun
ERROR: the backlog parser failed on @H/home/records/backlog.md
ERROR: cannot read @H/home/records/backlog.md to check 'qmove' for dependents - nothing moved" "11: the original's parser-failure arm"
  assert_eq "$(derr)" "ERROR: required tool not found: bun" "11: the port never starts - that arm is unreachable in-process (named)"
else
  printf 'SKIP: row 11 bun-absent - bun shares a system directory on this host\n'
fi
DPATH=""

# 13. the ledger's mode and the temp name, EXCLUSIVE TEMP (named, W16): a
#     0600 parent ledger came back 0644 from the original's fresh temp; the
#     port keeps 0600. A symlink planted at `<ledger>.tmp.<pid>`: the original
#     wrote the new ledger THROUGH it and then renamed the link over the
#     ledger; the port claims the next name and leaves both alone. Each side
#     starts behind a fifo gate and execs into its entry as the pid the name
#     is planted for.
dboth dseed; dboth d9
dboth chmod 600 @H/home/records/backlog.md
dsame handoff pay qmove
assert_eq "$(ls -l "$DOH/home/records/backlog.md" | cut -c1-10)" "-rw-r--r--" "13 (W16): the original's ledger took the temp's mode"
assert_eq "$(ls -l "$DNH/home/records/backlog.md" | cut -c1-10)" "-rw-------" "13 (W16): the port keeps the ledger's mode (named)"
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
dplant() {  # dplant <bin> <side root> <out> - the row on one side
  local b="$1" h="$2" o="$3" gate pid
  gate="$h/gate.fifo"; mkfifo "$gate"
  printf 'victim bytes\n' >"$h/victim"
  env -u AC_BACKEND LC_ALL=C AC_HOME="$h/home" PATH="$DSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$h" FAKE_HERDR="$h/herdr" \
    "$TMP/dgate.sh" "$gate" "$b" </dev/null >"$o" 2>&1 &
  pid=$!
  ln -s "$h/victim" "$h/home/records/backlog.md.tmp.$pid"
  printf x >"$gate"
  wait "$pid" || fail "13: handoff under $b failed: $(cat "$o")"
  rm -f "$gate"
}
dplant "$dobin" "$DOH" "$TMP/dpo.raw"
dplant "$BIN" "$DNH" "$TMP/dpn.raw"
assert_eq "$(dnorm "$TMP/dpn.raw" "$DNH")" "$(dnorm "$TMP/dpo.raw" "$DOH")" "13: the same output"
[ -L "$DOH/home/records/backlog.md" ] || fail "13: the original renamed the planted link over the ledger (the divergence's bash side)"
assert_contains "$(cat "$DOH/victim")" "qnorepo" "13: ... after writing the ledger through it"
case "$(cat "$DOH/victim")" in *qkeep*) fail "13: the ledger written through the link lost qkeep" ;; esac
[ ! -L "$DNH/home/records/backlog.md" ] || fail "13: the port's ledger stays a regular file"
assert_eq "$(cat "$DNH/victim")" "victim bytes" "13: the port never writes through a planted temp name"
assert_eq "$(cat "$DNH/home/records/backlog.md")" "$(cat "$DOH/victim")" "13: the same ledger bytes"
[ -L "$(ls -d "$DNH"/home/records/backlog.md.tmp.* | head -n1)" ] || fail "13: the planted link is left where it was"

pass
