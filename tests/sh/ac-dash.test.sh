#!/usr/bin/env bash
# ac-dash.test.sh - the captain dashboard: sections render, crew and
# pending rooms appear, backlog counts add up, colors off when piped.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Empty fleet renders every section with placeholders.
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "⚓ home" "header shows the fleet"
assert_contains "$out" "no crewmates in flight" "empty crew"
assert_contains "$out" "no rooms yet" "empty rooms"
assert_contains "$out" "no worktree pools yet" "empty pools"
case "$out" in *$'\033'*) fail "colors must be off when piped" ;; esac

# Crew, rooms, backlog and pools all show up.
printf 'kind=ship\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/t1.meta"
printf '%s done: shipped\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/t1.status"
"$BIN/ac-room.sh" post t1 crewchief "GATE: awaiting captain" >/dev/null
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] t1 - thing (repo: alpha)

## Queued
- [ ] t2 - other
- [ ] t3 - more

## Done
- [x] t0 - past
EOF
mkdir -p "$AC_HOME/projects/alpha/.crew/slots"
printf 'leased=1\n' >"$AC_HOME/projects/alpha/.crew/slots/1.meta"
printf 'leased=0\n' >"$AC_HOME/projects/alpha/.crew/slots/2.meta"

out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "t1" "crew row"
assert_contains "$out" "PENDING-CAPTAIN(1)" "pending room"
assert_contains "$out" "in-flight:1  queued:2  done:1" "backlog counts"
# A byte that is not UTF-8 in row prose is prose: under a UTF-8 locale it
# aborted the count walk and the section read "backlog unavailable".
cp "$AC_HOME/records/backlog.md" "$TMP/dash-backlog.keep"
printf -- '- [ ] t4 - caf\351 menu\n' >>"$AC_HOME/records/backlog.md"
assert_contains "$(LC_ALL=en_US.UTF-8 "$BIN/ac-dash.sh")" "in-flight:1  queued:2" "a non-UTF-8 byte never costs the backlog counts"
cp "$TMP/dash-backlog.keep" "$AC_HOME/records/backlog.md"
assert_contains "$out" "leased:1 avail:1" "pool counts"

# Verifier-only fleet: CREW says empty, the verify row shows under its own
# heading (ac_meta_is_verify is the predicate, never a verify-* re-match).
rm -f "$AC_HOME"/state/t1.meta "$AC_HOME"/state/t1.status
printf 'kind=verify-codereview\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/v1.meta"
printf '%s done: reviewed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/v1.status"
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "no crewmates in flight" "verifier-only: CREW section stays empty"
assert_contains "$out" "v1" "verifier-only: verify row shows"
assert_contains "$out" "verification agents, not crew" "verifier-only: wording marks it as verify"

# Mixed fleet: a crew meta and a verify meta both in flight - the verify id
# must never land in the CREW section.
printf 'kind=ship\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/t1.meta"
printf '%s done: shipped\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/t1.status"
out="$("$BIN/ac-dash.sh")"
crew_section="$(awk '/^CREW$/{c=1;next} /^$/{c=0} c' <<<"$out")"
assert_contains "$crew_section" "t1" "mixed: crew section lists t1"
case "$crew_section" in *v1*) fail "mixed: verify id v1 leaked into the crew section" ;; esac
assert_contains "$out" "v1" "mixed: verify row still shown"

# Crew-only fleet: no verify section at all.
rm -f "$AC_HOME/state/v1.meta" "$AC_HOME/state/v1.status"
out="$("$BIN/ac-dash.sh")"
case "$out" in *"verification agents, not crew"*) fail "crew-only: no verify section should print" ;; esac

assert_fails "$BIN/ac-dash.sh" --bogus

# --- same-done-miscount-in-three-more-surfaces: BACKLOG done means real done -
# two-dashboards lead (ac-dash-crew-heading-swallows-verifiers): the last bug of
# this shape had to be fixed in both dashboards, so this terminal one gets its
# own fixture rather than assuming the bun-side fix covers it.
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
- [x] fx-done - real success (merged 2026-08-03)
- [x] fx-failed [failed] - did not land (2026-08-03)
- [x] fx-abandoned [abandoned] - dropped (2026-08-03)
EOF
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "in-flight:0  queued:0  done:1" \
  "a [failed]/[abandoned] Done row must not count toward the terminal backlog's done tally"

# A backlog the parser could not read costs its own line, never the render:
# --watch runs render under set -e and would die on the first bad frame.
# MECHANICS ONLY changed with the port, the three assertions byte-identical: a
# PATH `bun` that exits 1 now kills the shim before src/dash.ts runs
# (bin/ac-bun.sh resolves bun on PATH), so the unreadable backlog is a
# mode-000 file - the frozen original answered it with the same `exited 2`
# line (awk's status on a file it cannot open). Skipped under root, who can
# read a 000 file.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0
  out="$("$BIN/ac-dash.sh" 2>/dev/null)" || rc=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  assert_eq "$rc" "0" "an unreadable backlog leaves the render's exit status alone"
  assert_contains "$out" "WARN   backlog unavailable: the parser exited 2" "an unreadable backlog is named in its section"
  assert_contains "$out" "leased:1 avail:1" "the sections after an unreadable backlog still render"
fi

# --- differential leg: the frozen bash original (tests/fixtures/ac-dash.sh,
# run from an oracle bin beside the live ac-crew-state.sh / ac-room.sh /
# ac-backlog.sh) and the shim answer every fixture byte-identically on stdout,
# stderr and exit, both piped (no colors), TERM fixed, the backends stubbed
# (the fake herdr/orca of helpers.sh; claude and gh refuse). A divergence the
# port keeps on purpose is compared by hand and named where it is.
make_fake_herdr
make_fake_orca
for t in claude gh; do printf '#!/bin/sh\nexit 1\n' >"$TMP/stubbin/$t"; chmod +x "$TMP/stubbin/$t"; done
export TERM=xterm
unset NO_COLOR
obin="$(make_oracle_bin ac-dash)"
SAME_ENV=
SAME_PRE=:
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  eval "$SAME_PRE"
  env $SAME_ENV "$obin/ac-dash.sh" "$@" >"$TMP/o.out" 2>"$TMP/o.err" </dev/null || o_rc=$?
  eval "$SAME_PRE"
  env $SAME_ENV "$BIN/ac-dash.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*' ($SAME_ENV)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*' ($SAME_ENV): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*' ($SAME_ENV): $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
nout() { cat "$TMP/n.out"; }
fresh_home() {  # fresh_home <name> - a new five-dir home, exported as AC_HOME
  AC_HOME="$TMP/$1"; export AC_HOME
  mkdir -p "$AC_HOME/state" "$AC_HOME/data" "$AC_HOME/records" "$AC_HOME/config" "$AC_HOME/projects"
}
# A live crewmate under the fake herdr: handle + tab + pane buffer (the
# buffer's text decides busy); without a handle the state is gone/detached.
mk_live() { printf '%s %s\n' "p$1" "t$1" >"$AC_HOME/state/.pane-$1"; printf 'p%s\n' "$1" >"$FAKE_HERDR/tabs/t$1"; printf '%s\n' "${2:-\$ }" >"$FAKE_HERDR/panes/p$1.buf"; }

# 1. the five placeholders; a home with ONLY config/ mints state/ records/
#    projects/ on both sides (a read-only view that writes - reproduced).
fresh_home h1; same
assert_contains "$(nout)" "⚓ h1  captain: captain  backend: herdr  flow: auto" "the header line, byte for byte"
mkdir -p "$TMP/h1b/config"; AC_HOME="$TMP/h1b" "$BIN/ac-dash.sh" >/dev/null
for d in state records projects; do [ -d "$TMP/h1b/$d" ] || fail "the shim mints $d/ as the original did"; done
[ ! -e "$TMP/h1b/data" ] || fail "data/ is never minted"
rm -rf "$TMP/h1b"; mkdir -p "$TMP/h1b/config"; AC_HOME="$TMP/h1b" same

# 2. the populated fixture of the legs above (herdr backend, no pane: gone).
fresh_home h2
printf 'kind=ship\nproject=alpha\nbackend=herdr\n' >"$AC_HOME/state/t1.meta"
printf '2026-01-01T00:00:00Z done: shipped\n' >"$AC_HOME/state/t1.status"
"$BIN/ac-room.sh" post t1 crewchief "GATE: awaiting captain" >/dev/null
printf '# Backlog\n\n## In flight\n- [ ] t1 - thing (repo: alpha)\n\n## Queued\n- [ ] t2 - other\n- [ ] t3 - more\n\n## Done\n- [x] t0 - past\n' >"$AC_HOME/records/backlog.md"
mkdir -p "$AC_HOME/projects/alpha/.crew/slots"
printf 'leased=1\n' >"$AC_HOME/projects/alpha/.crew/slots/1.meta"
printf 'leased=0\n' >"$AC_HOME/projects/alpha/.crew/slots/2.meta"
same
assert_contains "$(nout)" "
BACKLOG  in-flight:1  queued:2  done:1
" "the count line follows BACKLOG on the SAME line"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' t1 ship alpha gone)" "a crew row: 16/10/14 byte columns"

# 3. meta shapes: the verify class, self (detached), kind-less, an empty kind,
#    a repeated key (last wins), a value holding `=`, a DIRECTORY d.meta (a row
#    reading unknown - `[ -e ]` admitted it), a hidden meta and an orphan status.
fresh_home h3
printf 'kind=ship\nproject=alpha\n' >"$AC_HOME/state/a1.meta"
printf 'kind=verify-codereview\nproject=alpha\n' >"$AC_HOME/state/v1.meta"
printf 'kind=self\nproject=p\n' >"$AC_HOME/state/s1.meta"
printf 'project=nokind\n' >"$AC_HOME/state/k0.meta"
printf 'kind=\nproject=x\n' >"$AC_HOME/state/k1.meta"
printf 'kind=ship\nproject=p1\nproject=a=b\n' >"$AC_HOME/state/r1.meta"
mkdir "$AC_HOME/state/d.meta"
printf 'kind=ship\n' >"$AC_HOME/state/.hidden.meta"
printf '2026 done: x\n' >"$AC_HOME/state/orphan.status"
same
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' d '' '' unknown)" "a directory x.meta is a crew row reading unknown"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' s1 self p detached)" "a self task without a pane is detached"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' r1 ship a=b gone)" "the LAST project= wins, with its ="
assert_contains "$(nout)" "VERIFY (verification agents, not crew)
$(printf '  %-16s %-10s %-14s %s' v1 verify-codereview alpha gone)" "the verify row sits under its own heading, its 17-byte kind overflowing"
case "$(nout)" in *hidden*|*orphan*) fail "a dot meta and an orphan status are never rows" ;; esac

# 4. byte padding under the operators' UTF-8 locale: a 3-byte id gets 13 pad
#    bytes, a 20-byte id and project overflow their columns.
fresh_home h4
printf 'kind=ship\nproject=héllo\n' >"$AC_HOME/state/é1.meta"
printf 'kind=ship\nproject=abcdefghijklmnopqrst\n' >"$AC_HOME/state/averyveryverylongid0.meta"
mkdir -p "$AC_HOME/projects/twentybyteprojectnam/.crew/slots"
SAME_ENV=LC_ALL=en_US.UTF-8 same
assert_contains "$(nout)" "  é1$(printf '%13s' '') ship       héllo$(printf '%8s' '') gone" "columns pad by BYTES"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' averyveryverylongid0 ship abcdefghijklmnopqrst gone)" "an id or project past its column overflows, never cut"
assert_contains "$(nout)" "$(printf '  %-20s leased:0 avail:0' twentybyteprojectnam)" "a 20-byte project fills its column exactly"

# 5. order: both sides under LC_ALL=C agree on byte order; under en_US.UTF-8
#    the original's glob followed libc collation (case folded, punctuation
#    ignored) - the one named ORDERING divergence of the port, asserted below.
fresh_home h5
for id in Zeta B ac-x ac_x ac.x a10 a2 2025 ä; do printf 'kind=ship\n' >"$AC_HOME/state/$id.meta"; done
SAME_ENV=LC_ALL=C same
order() { awk '/^CREW$/{c=1;next} /^$/{c=0} c{print $1}' | tr '\n' ' '; }
assert_eq "$(nout | order)" "2025 B Zeta a10 a2 ac-x ac.x ac_x ä " "metas are listed in BYTE order"
LC_ALL=en_US.UTF-8 "$obin/ac-dash.sh" >"$TMP/o5.out" 2>/dev/null
[ "$(order <"$TMP/o5.out")" != "$(nout | order)" ] || fail "the original's glob order under UTF-8 was collation order, not byte order (named divergence)"
assert_eq "$(LC_ALL=en_US.UTF-8 "$BIN/ac-dash.sh" 2>/dev/null | order)" "$(nout | order)" "the port's order does not follow the locale"
SAME_ENV=

# 6. config: a padded CRLF captain, a two-line one, a BOM-led one, absent;
#    backend and flow shown as read.
fresh_home h6
printf 'orca\n' >"$AC_HOME/config/backend"; printf 'staged\n' >"$AC_HOME/config/flow"
printf ' TN \r\n' >"$AC_HOME/config/captain"; same
assert_contains "$(nout)" "⚓ h6  captain: TN  backend: orca  flow: staged" "captain trimmed of its padding and CR"
printf 'A\nB\n' >"$AC_HOME/config/captain"; same
assert_contains "$(nout)" "captain: A  backend" "the first line only"
printf '\357\273\277Bom\n' >"$AC_HOME/config/captain"; same
rm -f "$AC_HOME/config/captain"; same

# 7. rooms in every list shape, the 120-char cut of a 130-char last entry, a
#    TAB inside the entry; then (no rooms yet); then an unreadable room (the
#    WARN line, exit 0).
fresh_home h7
"$BIN/ac-room.sh" post okfam crewchief "spawned okfam" >/dev/null
"$BIN/ac-room.sh" post two crewchief "GATE: one" >/dev/null; "$BIN/ac-room.sh" post two crewchief "ASK: two" >/dev/null
"$BIN/ac-room.sh" post hb crewchief "spawned hb" >/dev/null; "$BIN/ac-room.sh" handback hb "landed: done" >/dev/null
"$BIN/ac-room.sh" post both crewchief "GATE: g" >/dev/null; "$BIN/ac-room.sh" handback both "landed: too" >/dev/null
long130="$(printf 'x%.0s' $(seq 1 130))"
"$BIN/ac-room.sh" post tabbed crewchief "a	tab $long130" >/dev/null
same
assert_contains "$(nout)" "  PENDING-CAPTAIN(2)  two" "a two-gate room"
assert_contains "$(nout)" "  HANDBACK            hb" "a hand-back"
assert_contains "$(nout)" "  PENDING-CAPTAIN(1)+HANDBACK  both" "both at once"
assert_contains "$(nout)" "  ok                  okfam" "a settled room"
fresh_home h7b; same
assert_contains "$(nout)" "  (no rooms yet)" "no rooms"
if [ "$(id -u)" != 0 ]; then
  fresh_home h7c
  "$BIN/ac-room.sh" post locked crewchief "GATE: g" >/dev/null
  chmod 000 "$AC_HOME/data/locked/room.md"
  same
  chmod 644 "$AC_HOME/data/locked/room.md"
  assert_contains "$(nout)" "  WARN   rooms unreadable - the inbox is UNKNOWN, not empty (bin/ac-room.sh list)" "an unreadable room set is UNKNOWN"
fi

# 8. the backlog count over every row shape; a `\351` byte in prose under the
#    UTF-8 locale; a NUL in a row (the record is cut there); an empty file; an
#    absent file; a directory named backlog.md.
fresh_home h8
bl="$AC_HOME/records/backlog.md"
printf -- '- [ ] before - counts nowhere\n# Backlog\n\n## In flight\n- [ ] a\n- [y] odd\n\n## Other\n- [ ] not counted\n\n## Queued\n- [ ] q1\n\n## Done (archive)\n- [x] d1 - ok\n- [x] d2 [failed] - no\n- [x] d3 [abandoned] - no\n- [x] d4 - caf\351 menu\n' >"$bl"
SAME_ENV=LC_ALL=en_US.UTF-8 same
assert_contains "$(nout)" "in-flight:2  queued:1  done:2" "any bracket row counts in its section; Done by prefix; failed/abandoned never done; a non-UTF-8 byte is prose"
SAME_ENV=
printf -- '## Done\n- [x] n1 - a\0b [failed]\n- [x] n2 [failed]\0 - x\n' >"$bl"; same
assert_contains "$(nout)" "in-flight:0  queued:0  done:1" "a record is cut at its NUL: the first row's [failed] is lost, the second's kept"
: >"$bl"; same
assert_contains "$(nout)" "in-flight:0  queued:0  done:0" "an empty ledger counts zero"
rm -f "$bl"; same
assert_contains "$(nout)" "BACKLOG  (no backlog yet)" "no ledger"
mkdir "$bl"; same
assert_contains "$(nout)" "BACKLOG  (no backlog yet)" "a directory is no ledger"
rmdir "$bl"

# 9. an unreadable ledger: the WARN line with awk's status 2, exit 0, POOLS
#    still rendered. stderr by hand: the original's is awk's own `can't open
#    file` noise (tool-own, not reproduced); the port prints nothing there.
if [ "$(id -u)" != 0 ]; then
  printf '## Done\n- [x] d\n' >"$bl"; chmod 000 "$bl"
  mkdir -p "$AC_HOME/projects/p9/.crew/slots"
  o_rc=0; "$obin/ac-dash.sh" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-dash.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  chmod 644 "$bl"
  assert_eq "$o_rc" "0" "unreadable ledger: the original's exit"
  assert_eq "$n_rc" "0" "unreadable ledger: the port's exit"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "unreadable ledger: stdout differs: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  assert_contains "$(nout)" "BACKLOG  WARN   backlog unavailable: the parser exited 2 - rerun to see why" "the parser's status is awk's 2"
  assert_contains "$(nout)" "$(printf '  %-20s leased:0 avail:0' p9)" "POOLS still renders"
  assert_contains "$(cat "$TMP/o.err")" "can't open file" "the original's stderr was awk's own"
  assert_eq "$(cat "$TMP/n.err")" "" "the port does not reproduce awk's noise (named divergence)"
fi
# A parser that cannot finish: the ledger changes between the parse and the
# count is not reachable from outside, but a Done row the parser never saw is
# the binding's `changed between` line - here forced by a ledger whose Done
# row holds a CR-less duplicate; both sides agree it is counted (same bytes),
# so the shared `_dl_die` text is pinned on the readable path instead.
printf '## Done\n- [x] d1\n- [x] d1\n' >"$bl"; same
assert_contains "$(nout)" "done:2" "two identical Done rows both count"

# 10. pools: leased exactly `1`; `0`, `01`, a repeated key (last wins), an
#     unreadable meta (WARN, avail) all avail; slots as a FILE skipped; an
#     empty slots dir; a dotfile meta ignored; a directory x.meta ignored.
fresh_home h10
mkdir -p "$AC_HOME/projects/alpha/.crew/slots" "$AC_HOME/projects/beta/.crew/slots" "$AC_HOME/projects/gamma/.crew" "$AC_HOME/projects/delta/.crew/slots"
printf 'leased=1\n' >"$AC_HOME/projects/alpha/.crew/slots/1.meta"
printf 'leased=0\n' >"$AC_HOME/projects/alpha/.crew/slots/2.meta"
printf 'leased=1\nleased=0\n' >"$AC_HOME/projects/alpha/.crew/slots/3.meta"
printf 'leased=1\n' >"$AC_HOME/projects/alpha/.crew/slots/.dot.meta"
mkdir "$AC_HOME/projects/alpha/.crew/slots/dir.meta"
printf 'leased=01\n' >"$AC_HOME/projects/beta/.crew/slots/1.meta"
printf 'leased=1\n' >"$AC_HOME/projects/beta/.crew/slots/2.meta"
: >"$AC_HOME/projects/gamma/.crew/slots"
if [ "$(id -u)" != 0 ]; then chmod 000 "$AC_HOME/projects/beta/.crew/slots/2.meta"; fi
same
chmod 644 "$AC_HOME/projects/beta/.crew/slots/2.meta"
assert_contains "$(nout)" "$(printf '  %-20s leased:1 avail:2' alpha)" "only leased=1 exactly; the last key wins"
if [ "$(id -u)" != 0 ]; then
  assert_contains "$(nout)" "$(printf '  %-20s leased:0 avail:2' beta)" "01 and an unreadable meta are avail"
  assert_contains "$(cat "$TMP/n.err")" "WARN: cannot read meta file $AC_HOME/projects/beta/.crew/slots/2.meta" "the unreadable slot meta is warned, on both sides"
fi
assert_contains "$(nout)" "$(printf '  %-20s leased:0 avail:0' delta)" "an empty slots dir"
case "$(nout)" in *gamma*) fail "slots as a file is no pool" ;; esac

# 11. ONE unreadable task meta ends the run: the rows before it printed, the
#     WARN, exit 1, nothing after (the bare `kind=` assignment under errexit;
#     reproduced, a defect slice of its own).
if [ "$(id -u)" != 0 ]; then
  fresh_home h11
  printf 'kind=ship\n' >"$AC_HOME/state/a.meta"
  printf 'kind=ship\n' >"$AC_HOME/state/locked.meta"
  printf 'kind=ship\n' >"$AC_HOME/state/z.meta"
  chmod 000 "$AC_HOME/state/locked.meta"
  same
  chmod 644 "$AC_HOME/state/locked.meta"
  assert_eq "$(cat "$TMP/n.err")" "WARN: cannot read meta file $AC_HOME/state/locked.meta" "the one WARN"
  assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' a ship '' gone)" "the row before the unreadable meta is printed"
  case "$(nout)" in *ROOMS*|*"  z "*) fail "nothing renders after the unreadable meta" ;; esac
fi

# 12. homeless and an AC_HOME that cannot be entered, by hand (named): the
#     original printed the refusal THREE times around a header/CREW/ROOMS render
#     and died at `BACKLOG`; the port refuses once with nothing on stdout. Bad
#     home: the shell's `cd:` lines there, the variable named here. Exit 1 all.
o_rc=0; env -u AC_HOME "$obin/ac-dash.sh" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; env -u AC_HOME "$BIN/ac-dash.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc:$n_rc" "1:1" "homeless: exit 1 on both sides"
assert_eq "$(grep -c 'ERROR: AC_HOME is not set' "$TMP/o.err")" "3" "homeless: the original refused three times"
assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "homeless: the port refuses once"
assert_contains "$(cat "$TMP/o.out")" "BACKLOG" "homeless: the original rendered down to BACKLOG"
assert_eq "$(nout)" "" "homeless: the port prints nothing (named divergence)"
o_rc=0; AC_HOME="$TMP/nowhere" "$obin/ac-dash.sh" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME="$TMP/nowhere" "$BIN/ac-dash.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc:$n_rc" "1:1" "bad home: exit 1 on both sides"
assert_contains "$(cat "$TMP/o.err")" "cd: $TMP/nowhere: No such file or directory" "bad home: the shell's own line"
assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not a readable directory: $TMP/nowhere" "bad home: the port names the variable (named divergence)"
assert_eq "$(nout)" "" "bad home: nothing on stdout"

# 13. args: usage exit 2 for -h/--help/--bogus; `"" extra` renders; --watch
#     with a `clear` stub that records its frames and either the real sleep
#     (abc / -1: sleep's own usage, exit 1 after ONE frame) or a `sleep` stub
#     that logs its argv and exits 1 (`--watch 0 x y`: argv `0`), one that
#     allows two frames before failing (the loop LOOPS inside one process), and
#     a `clear` that fails (exit 3, no frame).
fresh_home h13
printf 'kind=ship\n' >"$AC_HOME/state/w1.meta"
same -h; same --help; same --bogus
assert_eq "$(cat "$TMP/n.err")" "usage: ac-dash.sh [--watch [<seconds>]]" "usage on stderr, exit 2"
same "" extra
assert_contains "$(nout)" "⚓ h13" "an empty first argument renders"
wbin="$TMP/watchbin"; mkdir -p "$wbin"
printf '#!/bin/sh\nprintf "<clear>\\n"\n' >"$wbin/clear"; chmod +x "$wbin/clear"
SAME_ENV="PATH=$wbin:$PATH"
same --watch abc
assert_eq "$(grep -c '<clear>' "$TMP/n.out")" "1" "sleep failing ends --watch after one frame"
assert_contains "$(nout)" "
(refreshing every abcs - ctrl-c to stop)" "the trailer prints the interval as typed"
assert_contains "$(cat "$TMP/n.err")" "usage: sleep" "sleep's own usage line"
same --watch -1
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/sleep.log"\nexit 1\n' "$TMP" >"$wbin/sleep"; chmod +x "$wbin/sleep"
same --watch 0 x y
assert_eq "$(cat "$TMP/sleep.log")" "0
0" "sleep is spawned with the interval as typed, once per side"
assert_contains "$(nout)" "(refreshing every 0s - ctrl-c to stop)" "extra --watch words are ignored"
printf '#!/bin/sh\nn=$(cat "%s/sleeps" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"%s/sleeps"\n[ "$n" -lt 3 ]\n' "$TMP" "$TMP" >"$wbin/sleep"
SAME_PRE="rm -f $TMP/sleeps"
same --watch 2
SAME_PRE=:
assert_eq "$(grep -c '<clear>' "$TMP/n.out")" "3" "three frames from ONE process before the third sleep fails"
assert_eq "$(grep -c '^⚓ h13' "$TMP/n.out")" "3" "each frame renders"
printf '#!/bin/sh\nexit 3\n' >"$wbin/clear"
same --watch 1
assert_eq "$(nout)" "" "a clear that fails ends the run before any frame, with its status"
printf '#!/bin/sh\nprintf "<clear>\\n"\n' >"$wbin/clear"
SAME_ENV=

# 14. colors: NO_COLOR= (empty) piped is no ESC; on a tty (run_on_tty) with
#     NO_COLOR unset the header and rows are colored per state class, with
#     NO_COLOR=1 none, with NO_COLOR= (empty) colored. The states come from the
#     real ac-crew-state.sh under the fake herdr.
fresh_home h14
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-done.meta";  mk_live c-done;  printf '2026 done: shipped\n' >"$AC_HOME/state/c-done.status"
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-block.meta"; mk_live c-block; printf '2026 blocked: y\n' >"$AC_HOME/state/c-block.status"
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-nd.meta";    mk_live c-nd;    printf '2026 needs-decision: z\n' >"$AC_HOME/state/c-nd.status"
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-busy.meta";  mk_live c-busy "Thinking..."
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-idle.meta";  mk_live c-idle
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/c-gone.meta"
printf 'kind=self\nproject=p\n' >"$AC_HOME/state/c-self.meta"
"$BIN/ac-room.sh" post h14 crewchief "GATE: g" >/dev/null
SAME_ENV="NO_COLOR=" same
case "$(nout)" in *$'\033'*) fail "NO_COLOR= (empty) piped: no ESC" ;; esac
SAME_ENV=
tty_same() {  # tty_same <env...> - both sides on a pty, output and exit alike
  local o_rc=0 n_rc=0
  run_on_tty env "$@" "$obin/ac-dash.sh" >"$TMP/o.tty" 2>&1 || o_rc=$?
  run_on_tty env "$@" "$BIN/ac-dash.sh" >"$TMP/n.tty" 2>&1 || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "tty differential exit ($*)"
  cmp -s "$TMP/o.tty" "$TMP/n.tty" || fail "tty differential output differs ($*): $(diff "$TMP/o.tty" "$TMP/n.tty" | head -n 8)"
}
tty_same TERM=xterm
ttyout="$(cat "$TMP/n.tty")"
assert_contains "$ttyout" $'\033[1;36m\xe2\x9a\x93 h14\033[0m  \033[2mcaptain:\033[0m captain' "the header is colored on a tty"
assert_contains "$ttyout" $'  \033[0mc-done          \033[0m ship       p              \033[32mstatus| done: shipped\033[0m' "done: is green, the id wrapped in two resets"
assert_contains "$ttyout" $'\033[1;31mstatus| blocked: y\033[0m' "blocked: is red"
assert_contains "$ttyout" $'\033[1;31mstatus| needs-decision: z\033[0m' "needs-decision: is red"
assert_contains "$ttyout" $'\033[1;31mgone\033[0m' "gone is red"
assert_contains "$ttyout" $'\033[33mbusy\033[0m' "busy is yellow"
assert_contains "$ttyout" $'\033[33midle\033[0m' "idle is yellow"
assert_contains "$ttyout" $'\033[33mdetached\033[0m' "detached is yellow"
assert_contains "$ttyout" $'  \033[1;31mPENDING-CAPTAIN(1)  h14' "a pending room is red"
tty_same TERM=xterm NO_COLOR=1
case "$(cat "$TMP/n.tty")" in *$'\033'*) fail "NO_COLOR=1 on a tty: no ESC" ;; esac
tty_same TERM=xterm NO_COLOR=
case "$(cat "$TMP/n.tty")" in *$'\033[1;36m'*) ;; *) fail "NO_COLOR= (empty) on a tty keeps colors" ;; esac

# 15. ac-crew-state.sh outcomes: unobservable (the backend unreachable) and
#     unknown (a child that fails) through the real script; then a STUB
#     ac-crew-state.sh in both bins (a shim-side lab copy under its own name)
#     printing two lines (embedded raw) or printing and then failing (`xunknown`).
touch "$FAKE_HERDR/.unreachable"
same
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' c-idle ship p 'unobservable: backend could not be read for herdr:pane-pc-idle')" "an unreadable backend is unobservable"
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' c-gone ship p gone)" "no handle is gone whatever the backend"
lab="$TMP/lab-dash"; mkdir -p "$lab/bin"; cp "$BIN"/*.sh "$lab/bin/"; ln -s "$ROOT/src" "$lab/src"; ln -s "$ROOT/dashboard" "$lab/dashboard"
stub_state() { printf '%s\n' '#!/bin/sh' "$1" >"$obin/ac-crew-state.sh"; printf '%s\n' '#!/bin/sh' "$1" >"$lab/bin/ac-crew-state.sh"; }
lab_same() {
  local o_rc=0 n_rc=0
  "$obin/ac-dash.sh" >"$TMP/o.out" 2>"$TMP/o.err" </dev/null || o_rc=$?
  "$lab/bin/ac-dash.sh" >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "lab differential exit"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "lab differential stdout differs: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "lab differential stderr differs: $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
fresh_home h15
printf 'kind=ship\nproject=p\n' >"$AC_HOME/state/m1.meta"
stub_state 'printf "line one\nline two\n\n"'; lab_same
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' m1 ship p 'line one')
line two
" "a two-line state embeds its LF raw, trailing LFs stripped"
stub_state 'printf "x\n"; exit 1'; lab_same
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' m1 ship p x)
unknown" "a child that printed and then failed reads its text plus unknown"
stub_state 'printf "a\0b\n"; exit 0'; lab_same
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' m1 ship p ab)" "NULs in the state are dropped as \$(...) dropped them"
stub_state 'printf "a done: ok\n" >&2; exit 7'; lab_same
assert_contains "$(nout)" "$(printf '  %-16s %-10s %-14s %s' m1 ship p unknown)" "the child's stderr is dropped, its failure is unknown"
assert_eq "$(cat "$TMP/n.err")" "" "nothing of the child's stderr reaches the dash's"
cp "$BIN/ac-crew-state.sh" "$obin/ac-crew-state.sh"; cp "$BIN/ac-crew-state.sh" "$lab/bin/ac-crew-state.sh"
# The same for ac-room.sh list, through a stub: the WARN line joins an
# unterminated last line of a failing list; a list that exits 0 with an
# unterminated last line loses it (`read -r`); a line is cut at its NUL.
stub_room() { printf '%s\n' '#!/bin/sh' "$1" >"$obin/ac-room.sh"; printf '%s\n' '#!/bin/sh' "$1" >"$lab/bin/ac-room.sh"; }
stub_room 'printf "ok  fam\nabc"; exit 1'; lab_same
assert_contains "$(nout)" "  ok  fam
  abcWARN   rooms unreadable - the inbox is UNKNOWN, not empty (bin/ac-room.sh list)" "the WARN line is appended raw, joining an unterminated line (dim, as it no longer starts with WARN)"
stub_room 'printf "PENDING-CAPTAIN(9)  x\nlast"; exit 0'; lab_same
assert_contains "$(nout)" "  PENDING-CAPTAIN(9)  x
" "a terminated line is kept"
case "$(nout)" in *last*) fail "an unterminated last room line is dropped, as read -r dropped it" ;; esac
stub_room 'printf "a\0b\nc\n"'; lab_same
assert_contains "$(nout)" "ROOMS (captain inbox)
  a
  c
" "a room line is cut at its NUL"
cp "$BIN/ac-room.sh" "$obin/ac-room.sh"

# 16. --watch ends with exit 0 on ctrl-c, after the first frame, on both sides.
#     ctrl-c is SIGINT to the whole foreground group - the dash AND its sleep -
#     delivered here as INT to the pid and to its child: bash runs an INT trap
#     only when the foreground child died of the INT (a child that exits
#     normally is taken to have handled it); the port's handler fires on
#     either. A job a non-interactive shell backgrounds starts with INT
#     IGNORED (POSIX; bash cannot trap a signal ignored on entry), so each side
#     is exec'd with INT at its default first. Bounded: the sleep stub refuses
#     its third call, so a side that ignores the INT ends with 1, never hangs.
fresh_home h16
printf '#!/bin/sh\nn=$(cat "%s/sleeps16" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"%s/sleeps16"\n[ "$n" -lt 3 ] || exit 1\nexec /bin/sleep "$@"\n' "$TMP" "$TMP" >"$wbin/sleep"
sigint_default() { python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }
for side in "$obin" "$BIN"; do
  rm -f "$TMP/sleeps16"
  sigint_default env PATH="$wbin:$PATH" "$side/ac-dash.sh" --watch 1 >"$TMP/w.out" 2>"$TMP/w.err" </dev/null &
  wpid=$!
  sleep 0.5
  kill -INT "$wpid"; pkill -INT -P "$wpid" || true
  w_rc=0; wait "$wpid" || w_rc=$?
  assert_eq "$w_rc" "0" "--watch exits 0 on SIGINT ($side)"
  assert_eq "$(grep -c '<clear>' "$TMP/w.out")" "1" "one frame before the interrupt ($side)"
  assert_contains "$(cat "$TMP/w.out")" "(refreshing every 1s - ctrl-c to stop)" "the frame's trailer ($side)"
done

pass
