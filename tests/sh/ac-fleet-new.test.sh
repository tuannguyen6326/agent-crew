#!/usr/bin/env bash
# ac-fleet-new.test.sh - fleet home creation: answered knobs land in config/,
# an empty answer writes NO file (absence = the reader's default), enums re-ask
# instead of writing garbage, runtime workspace pins are never seeded, and every
# refusal happens before a single question is asked.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
container="$TMP/homes"

# --- every knob answered ------------------------------------------------------
home="$("$BIN/ac-fleet-new.sh" alpha --container "$container" 2>/dev/null <<'EOF'
TN
opus
ultracode
codex
gpt-5.6-sol
xhigh
always
staged
yes
EOF
)"

assert_eq "$home" "$container/alpha" "prints the home path on stdout"
for d in state data records config projects; do
  [ -d "$container/alpha/$d" ] || fail "missing $d/ in the seeded fleet"
done
assert_eq "$(cat "$container/alpha/config/backend")" "herdr" "backend seeded unasked - herdr is the default backend"

# Runtime symlinks: the chief runs with cwd = home (workspace = home, repo =
# code), so the seed links the distro runtime set into the new home.
for f in bin CLAUDE.md .claude AGENTS.md; do
  [ -L "$container/alpha/$f" ] || fail "runtime link missing: alpha/$f"
done
for f in docs tests; do
  [ ! -e "$container/alpha/$f" ] || fail "$f/ must not be seeded - repo material reads through ac_root"
done
assert_eq "$(cd "$container/alpha/bin" && pwd -P)" "$(cd "$BIN" && pwd -P)" \
  "the bin link resolves to the distro checkout's bin"
assert_eq "$(cat "$container/alpha/config/captain")" "TN" "captain knob"
assert_eq "$(cat "$container/alpha/config/model")" "opus" "model knob"
assert_eq "$(cat "$container/alpha/config/effort")" "ultracode" "effort knob"
assert_eq "$(cat "$container/alpha/config/gate-agent")" "codex" "gate-agent knob"
assert_eq "$(cat "$container/alpha/config/gate-model")" "gpt-5.6-sol" "gate-model knob"
assert_eq "$(cat "$container/alpha/config/gate-effort")" "xhigh" "gate-effort knob"
assert_eq "$(cat "$container/alpha/config/promote")" "always" "promote knob"
assert_eq "$(cat "$container/alpha/config/flow")" "staged" "flow knob"
assert_file "$container/alpha/CREWMATE.md" "per-fleet CREWMATE.md seeded on yes"
assert_contains "$(cat "$container/alpha/records/backlog.md")" "## In flight" "backlog skeleton"
assert_contains "$(cat "$container/alpha/records/projects.md")" "# Projects" "projects skeleton"
# The trap ac-home-seed.sh documents: a seeded workspace id would land this
# fleet's crew in whatever group that id names - another fleet's.
for k in herdr-workspace herdr-workspace-chiefs herdr-workspace-agents; do
  assert_no_file "$container/alpha/config/$k" "$k is a runtime pin - never seeded"
done

# --- every knob declined ------------------------------------------------------
printf '\n\n\n\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" beta --container "$container" >/dev/null 2>&1

assert_eq "$(cat "$container/beta/config/backend")" "herdr" "backend is written even when everything else is declined"
for k in captain model effort gate-agent gate-model gate-effort promote flow; do
  assert_no_file "$container/beta/config/$k" "an empty answer writes no $k file - absence IS the reader's default"
done
assert_no_file "$container/beta/CREWMATE.md" "declined: the container-wide .claude/CLAUDE.md keeps applying"
assert_file "$container/beta/records/backlog.md" "skeletons are seeded regardless"

# --- a bad enum re-asks -------------------------------------------------------
# Ten answers for ten reads: the rejected `bogus` costs an extra one. Feeding
# nine let the run die on EOF at the last prompt while this assertion still
# passed off the earlier writes - the heredoc has to outlast every prompt.
printf '\n\n\nbogus\ncodex\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" gamma --container "$container" >/dev/null 2>&1
assert_eq "$(cat "$container/gamma/config/gate-agent")" "codex" "a rejected enum re-asks rather than writing garbage into config/"

# --- refusals, all before the first question ----------------------------------
assert_fails "$BIN/ac-fleet-new.sh" alpha --container "$container"
assert_fails "$BIN/ac-fleet-new.sh" "bad name" --container "$container"
assert_fails "$BIN/ac-fleet-new.sh" delta --bogus-flag

# EOF on stdin must stop: taking the defaults would seed a fleet nobody
# described, and the run is unattended precisely when nobody is there to notice.
if "$BIN/ac-fleet-new.sh" delta --container "$container" </dev/null >/dev/null 2>&1; then
  fail "stdin at EOF must fail, not seed a fleet on silent defaults"
fi
assert_no_file "$container/delta" "a refused run leaves no half-seeded home behind"

# EOF landing on an ENUM prompt must fail exactly like EOF on a plain one.
# Separate case on purpose: errexit does not fire on a failing $()-assignment
# inside a function body running in a command substitution, so ask_enum has to
# propagate by hand. Without that it swallowed the EOF, read the empty result as
# "declined", and seeded the fleet anyway - green suite, silent defaults.
# Eight answers, so EOF lands on the LAST prompt, which is an enum. It has to be
# the last: EOF on an earlier enum is masked - the run dies moments later at the
# next PLAIN ask, where errexit does fire, so the exit code proves nothing.
if printf '\n\n\n\n\n\n\n\n' | "$BIN/ac-fleet-new.sh" epsilon --container "$container" >/dev/null 2>&1; then
  fail "EOF on an enum prompt must fail, not resolve to the declined default"
fi
assert_no_file "$container/epsilon" "the enum-EOF refusal leaves no home behind"

# A leading ~ must expand - a quoted --container never meets the caller shell's
# tilde expansion, and an unexpanded one seeds the fleet under a literal `~`
# directory in $PWD where nothing will ever look for it.
# shellcheck disable=SC2088  # passing an UNEXPANDED ~ is exactly what is under test
printf '\n\n\n\n\n\n\n\n\n' | HOME="$TMP" "$BIN/ac-fleet-new.sh" zeta --container '~/homes-tilde' >/dev/null 2>&1
[ -d "$TMP/homes-tilde/zeta" ] || fail "--container must expand a leading ~ against \$HOME"

# --- differential: src/fleet-new.ts against the frozen bash original ---------
# DISPUTED: the implementation (tests/fixtures/ac-fleet-new.sh under bash vs src/fleet-new.ts through bin/ac-fleet-new.sh)
# HELD-CONSTANT: one fresh WORLD per side ($WORLD/c the container, cwd/ the caller's cwd, h/ its HOME, other/ its own
#   AC_HOME that must stay untouched), the same stdin bytes from a file, argv, LC_ALL=C unless a row says otherwise,
#   AC_HOMES_CONTAINER unset unless a row sets it; exit status, stdout and stderr compared whole, then every entry of
#   the world - path, mode, link target, bytes - with each side's distro root spelled ROOT (the oracle's ac_root is
#   its own copy, the port's is this checkout, so link targets differ by construction and nothing else).
obin="$(make_oracle_bin ac-fleet-new)"
OROOT="${obin%/bin}"
# The frozen entry calls ac_seed_runtime_links, retired from bin/ac-lib.sh with
# this port (the entry was its last caller); the oracle's own lib copy gets the
# frozen helper back. Its ac_root must also hold docs/examples/CREWMATE.md, the
# file the `yes` arm copies, as the shim's root does.
cat "$ROOT/tests/fixtures/ac-seed-runtime-links.sh" >>"$obin/ac-lib.sh"
ln -s "$ROOT/docs" "$OROOT/docs"
WORLD="$TMP/world"
feed() { printf -- "$1" >"$TMP/in"; }  # feed <printf-format> - the stdin bytes both sides read
fresh_world() { rm -rf "$WORLD"; mkdir -p "$WORLD/c" "$WORLD/cwd" "$WORLD/h" "$WORLD/other"; ${PLANT:-:}; }
run_side() {  # run_side <bin> <out> <err> <args...> - one side, from the world's cwd, fed $TMP/in
  local b="$1" o="$2" e="$3"; shift 3
  # env's -u options must precede its assignments.
  local -a envs=()
  if [ "${NOHOME-}" = 1 ]; then envs+=(-u HOME); else envs+=(HOME="${HOMEV-$WORLD/h}"); fi
  envs+=(AC_HOME="$WORLD/other" LC_ALL="${DIFF_LC:-C}")
  [ "${AHC+set}" != set ] || envs+=(AC_HOMES_CONTAINER="$AHC")
  (cd "$WORLD/cwd" && env -u AC_HOMES_CONTAINER "${envs[@]}" "$b/ac-fleet-new.sh" "$@") <"$TMP/in" >"$o" 2>"$e"
}
norm() { LC_ALL=C sed -e "s#$OROOT#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"; }
snap() {  # snap <dir> <out> - every entry under <dir>, byte order: a dir, a link and its target, or a file with its mode and bytes
  : >"$2"
  (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -d "$f" ]; then printf '== %s/\n' "$f"
    else printf '== %s %s\n' "$f" "$(stat -f %Lp "$f")"; cat "$f"; printf '\n--\n'; fi
  done) >"$2"
}
oracle() { fresh_world; run_side "$obin" "$TMP/o.raw" "$TMP/o.rawerr" "$@"; }
shim() { fresh_world; run_side "$BIN" "$TMP/n.raw" "$TMP/n.rawerr" "$@"; }
LAST_RC=0
same() {  # same <args...> - oracle and shim, each on a fresh world fed the same stdin, answer and leave byte-identical worlds
  local o_rc=0 n_rc=0
  oracle "$@" || o_rc=$?
  snap "$WORLD" "$TMP/o.rawtree"
  shim "$@" || n_rc=$?
  snap "$WORLD" "$TMP/n.rawtree"
  norm "$TMP/o.raw" >"$TMP/o.out"; norm "$TMP/o.rawerr" >"$TMP/o.err"; norm "$TMP/o.rawtree" >"$TMP/o.tree"
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.rawerr" >"$TMP/n.err"; norm "$TMP/n.rawtree" >"$TMP/n.tree"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  LAST_RC=$n_rc
  [ "${OUT-}" = own ] || cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  [ "${ERR-}" = own ] || cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
  cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "differential world differs for '$*': $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 8)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
oracle_err() { cat "$TMP/o.err"; }
knob_bytes() { od -An -tx1 "$WORLD/$1" | tr -d ' \n'; }  # hex of a knob file in the shim's world, the one left standing
C="$WORLD/c"
ALL9='TN\nopus\nultracode\ncodex\ngpt-5.6-sol\nxhigh\nalways\nstaged\nyes\n'
NONE9='\n\n\n\n\n\n\n\n\n'

# 1. every knob answered: the whole transcript, the tree, the links, CREWMATE.md
feed "$ALL9"
same alpha --container "$C"
assert_eq "$LAST_RC" 0 "row 1 exits 0"
assert_eq "$(shim_out)" "$C/alpha" "row 1: the home path is the only stdout"
assert_eq "$(readlink "$C/alpha/bin")" "$ROOT/bin" "row 1: the port's links name THIS checkout"
cmp -s "$C/alpha/CREWMATE.md" "$ROOT/docs/examples/CREWMATE.md" || fail "row 1: CREWMATE.md is the example's bytes"
assert_eq "$(ls -A "$WORLD/other")" "" "row 14: the caller's own AC_HOME is never touched"
# 2. every knob declined; 3. a rejected enum re-asks
feed "$NONE9"; same beta --container "$C"
assert_no_file "$C/beta/config/captain" "row 2: no knob file for an empty answer"
feed '\n\n\nbogus\ncodex\n\n\n\n\n\n'; same gamma --container "$C"
assert_contains "$(shim_err)" "not one of: codex claude off (or empty)" "row 3: the re-ask line"

# 4. EOF at every kind of prompt, and an unterminated last answer
feed ''; same; same delta; same delta --container "$C"
assert_contains "$(shim_err)" "ERROR: stdin closed while asking: captain name" "row 4: EOF on the first knob"
feed '\n\n\n\n\n\n\n\n'; same epsilon --container "$C"
assert_eq "$LAST_RC" 1 "row 4: EOF on the last enum refuses"
feed '\n\n\n\n'; same zeta --container "$C"
assert_contains "$(shim_err)" "stdin closed while asking: gate judge model" "row 4: EOF on a free-text prompt"
# `read -r` returns 1 on a line with no LF and the caller discards its bytes:
# the typed `yes` is lost and the run is refused, both sides alike.
feed '\n\n\n\n\n\n\n\nyes'; same eta --container "$C"
assert_eq "$LAST_RC" 1 "row 4: an unterminated last answer is refused"
assert_no_file "$C/eta" "row 4: no home from an unterminated answer"

# 5. CR is a value byte (W4 - readers strip it); a CR-suffixed enum never matches
feed 'TN\r\n\n\n\n\n\n\n\n\n'; same theta --container "$C"
assert_eq "$(knob_bytes c/theta/config/captain)" 544e0d0a "row 5: the CR is written with the value (W4)"
feed '\n\nhigh\r\n'; same iota --container "$C"
assert_eq "$LAST_RC" 1 "row 5: high<CR> re-asks until EOF"
assert_contains "$(shim_err)" "not one of: low medium high xhigh max ultracode (or empty)" "row 5: the CR enum was rejected"

# 6. odd values: spaces and a backslash kept, a whitespace-only answer WRITTEN
# (W2 - every reader trims it to "" and does not fall back to its default),
# case and trailing space never match an enum, a leading dash is a value
feed ' TN\\x \n \nLOW\nlow\n\n\n\nalways \nalways\n\n\n'; same kappa --container "$C"
assert_eq "$(knob_bytes c/kappa/config/captain)" 20544e5c78200a "row 6: spaces and the backslash are value bytes"
assert_eq "$(knob_bytes c/kappa/config/model)" 200a "row 6: a whitespace-only answer writes a knob file (W2)"
assert_eq "$(cat "$C/kappa/config/effort")" low "row 6: LOW re-asked, low taken"
assert_eq "$(cat "$C/kappa/config/promote")" always "row 6: 'always ' re-asked, always taken"
feed '-x\n\n\n\n\n\n\n\n\n'; same lambda --container "$C"
assert_eq "$(cat "$C/lambda/config/captain")" "-x" "row 6: a leading dash is a value"
# a NUL ends the value; the rest of its line is dropped
feed 'a\000b\n\n\n\n\n\n\n\n\n'; same mu --container "$C"
assert_eq "$(knob_bytes c/mu/config/captain)" 610a "row 6: a NUL truncates the answer"

# 7. no name: the re-ask loop, then the container prompt and its default
feed 'bad name\n\nzeta\n\n'"$NONE9"; same
assert_contains "$(shim_err)" "fleet name: name must be [a-zA-Z0-9_-]: bad name" "row 7: a bad typed name re-asks"
assert_contains "$(shim_err)" "fleet name: a fleet needs a name" "row 7: an empty typed name re-asks"
assert_contains "$(shim_err)" "homes container [$WORLD/h/Work/ac-homes]: " "row 7: the HOME default on the prompt"
assert_eq "$(shim_out)" "$WORLD/h/Work/ac-homes/zeta" "row 7: an empty container answer takes the default"
AHC="$C/sub" same
assert_contains "$(shim_err)" "homes container [$C/sub]: " "row 7: AC_HOMES_CONTAINER on the prompt"
[ -d "$C/sub/zeta" ] || fail "row 7: the AC_HOMES_CONTAINER default is created"
AHC="" same
assert_eq "$(shim_out)" "$WORLD/h/Work/ac-homes/zeta" "row 7: an EMPTY AC_HOMES_CONTAINER is unset"
feed 'zeta\n'"$NONE9"; same "" --container "$C"
assert_eq "$(shim_out)" "$C/zeta" "row 9: an empty argv word is no name"

# 8. arguments. `${2:?}` is bash's own line (shell-own stderr, not reproduced):
# the port prints its own ERROR, exit 1 on both sides.
feed "$NONE9"
ERR=own same nu --container ''
assert_eq "$LAST_RC" 1 "row 8: --container '' refused"
assert_eq "$(shim_err)" "ERROR: --container needs a path" "row 8: the port's own line for an empty --container"
assert_contains "$(oracle_err)" "2: --container needs a path" "row 8: the oracle's shell-own line"
ERR=own same nu --container
assert_eq "$(shim_err)" "ERROR: --container needs a path" "row 8: the port's own line for a trailing --container"
same xi --container "$WORLD/nope" --container "$C"
assert_eq "$(shim_out)" "$C/xi" "row 8: the last --container wins"
assert_no_file "$WORLD/nope" "row 8: the losing --container is never made"
same a b
assert_eq "$(shim_err)" "ERROR: unexpected argument: b" "row 8: a second bare word"
same --bogus
assert_eq "$(shim_err)" "ERROR: unknown argument: --bogus" "row 8: an unknown flag"
same x y -h
assert_eq "$(shim_err)" "ERROR: unexpected argument: y" "row 8: the scan refuses before it reaches -h"
# -h prints the spec header: the module's own after the port (USAGE HEADER
# ruling), the bash's before - exit 0 and an untouched world on both sides.
header="$(sed -n '/^\/\//!q; s#^// \{0,1\}##p' "$ROOT/src/fleet-new.ts")"
for h in -h --help; do
  OUT=own same "$h"
  assert_eq "$LAST_RC" 0 "row 8: $h exits 0"
  assert_eq "$(shim_out)" "$header" "row 8: $h prints the src/fleet-new.ts header"
  assert_contains "$(cat "$TMP/o.out")" "Usage: ac-fleet-new.sh [<name>] [--container <dir>]" "row 8: the oracle printed its own header"
done
OUT=own same x -h
assert_eq "$(shim_out)" "$header" "row 8: help wins once seen"

# 9. names: the charset guard per the text
same A-z_09 --container "$C"
assert_eq "$LAST_RC" 0 "row 9: letters, digits, dash and underscore"
for bad in 'a b' a/b . ..; do
  same "$bad" --container "$C"
  assert_eq "$(shim_err)" "ERROR: name must be [a-zA-Z0-9_-]: $bad" "row 9: '$bad' refused"
done
eacute="$(printf '\303\251')"
same "$eacute" --container "$C"
assert_eq "$(shim_err)" "ERROR: name must be [a-zA-Z0-9_-]: $eacute" "row 9: é refused under LC_ALL=C on both sides"
# NAMED DIVERGENCE (W3): bash 3.2's `[!a-zA-Z0-9_-]` under a UTF-8 locale
# accepts é by range collation and the oracle mints the fleet; the port refuses
# per the text under every locale. The bash side is a filed defect of the class.
DIFF_LC=en_US.UTF-8 oracle "$eacute" --container "$C" && o_rc=0 || o_rc=$?
assert_eq "$o_rc" 0 "row 9: the oracle under UTF-8 accepts é (the bash defect)"
[ -d "$C/$eacute/config" ] || fail "row 9: the oracle minted the é fleet under UTF-8"
DIFF_LC=en_US.UTF-8 shim "$eacute" --container "$C" && n_rc=0 || n_rc=$?
assert_eq "$n_rc" 1 "row 9: the port refuses é under UTF-8 - the named divergence"
assert_eq "$(cat "$TMP/n.rawerr")" "ERROR: name must be [a-zA-Z0-9_-]: $eacute" "row 9: the port's refusal under UTF-8"
assert_no_file "$C/$eacute" "row 9: the port minted nothing"

# 10. what sits at the home path, and at the container
PLANT="mkdir -p $C/alpha" same alpha --container "$C"
assert_eq "$(shim_err)" "ERROR: fleet home already exists: $C/alpha" "row 10: an existing dir refuses before any question"
PLANT="touch $C/alpha" same alpha --container "$C"
assert_eq "$(shim_err)" "ERROR: fleet home already exists: $C/alpha" "row 10: a file at the home path refuses too"
# W1: a DANGLING symlink fails `[ -e ]`, so the nine questions are asked and the
# seed's `mkdir -p` fails with mkdir's own line - exit 1 after the captain's
# answers, on both sides (the header's promise broken; a filed defect).
PLANT="ln -s $WORLD/nope/gone $C/alpha" same alpha --container "$C"
assert_eq "$LAST_RC" 1 "row 10: a dangling symlink at the home path fails"
assert_contains "$(shim_err)" "seed a per-fleet CREWMATE.md yes|no (empty: no - inherit the container-wide .claude/CLAUDE.md): mkdir: $C/alpha: No such file or directory" "row 10: W1 - the questions were spent, then mkdir's own line"
PLANT="touch $WORLD/cf" same omicron --container "$WORLD/cf"
assert_eq "$(shim_err)" "mkdir: $WORLD/cf: File exists" "row 10: a FILE as the container is mkdir's own line, before any question"

# 11. container spellings: ~ forms, relative, trailing slash, missing parents
same pi --container '~/hh'
assert_eq "$(shim_out)" "$WORLD/h/hh/pi" "row 11: ~/x expands against HOME"
same rho --container '~'
assert_eq "$(shim_out)" "$WORLD/h/rho" "row 11: a bare ~ is HOME"
same sigma --container '~x'
assert_eq "$(shim_out)" "$WORLD/cwd/~x/sigma" "row 11: ~x is a literal name under the cwd"
same tau --container rel/path
assert_eq "$(shim_out)" "$WORLD/cwd/rel/path/tau" "row 11: a relative container resolves against the caller's cwd"
same upsilon --container "$C/"
assert_eq "$(shim_out)" "$C/upsilon" "row 11: a trailing slash is dropped by the physical bind"
same phi --container "$C/deep/er"
assert_eq "$(shim_out)" "$C/deep/er/phi" "row 11: mkdir -p creates missing parents"
feed 'zeta\n~/typed\n'"$NONE9"; same
assert_eq "$(shim_out)" "$WORLD/h/typed/zeta" "row 11: a typed ~/ container expands too"

# 12. HOME: unset where it is needed is bash's own `unbound variable` line (shell-own
# stderr, not reproduced; the port's own ERROR, exit 1 both); empty is a value.
feed "$NONE9"
NOHOME=1 ERR=own same chi --container '~/x'
assert_eq "$LAST_RC" 1 "row 12: HOME unset with ~/x refused"
assert_eq "$(shim_err)" "ERROR: HOME is not set" "row 12: the port's own line"
assert_contains "$(oracle_err)" "HOME: unbound variable" "row 12: the oracle's shell-own line"
NOHOME=1 ERR=own same chi
assert_eq "$(shim_err)" "ERROR: HOME is not set" "row 12: HOME unset with no container, before any prompt"
assert_eq "$(cat "$TMP/n.raw")" "" "row 12: nothing on stdout"
NOHOME=1 same chi --container "$C"
assert_eq "$LAST_RC" 0 "row 12: HOME unset is fine when nothing reads it"
HOMEV="" same psi --container "~/${WORLD#/}/pc"
assert_eq "$LAST_RC" 0 "row 12: an EMPTY HOME is a value - ~/<path> expands to /<path> on both sides"
assert_eq "$(shim_out)" "$WORLD/pc/psi" "row 12: the home sits under the expanded container"

# 13. the CREWMATE.md source missing from the root: cp's own line, exit 1, a
# half-seeded home left behind that the next run refuses. Reachable only for the
# oracle (its root is a copy): the shim's root is this checkout, which holds the
# file - asserted, so the arm cannot differ unseen.
assert_file "$ROOT/docs/examples/CREWMATE.md" "row 13: the shim's root holds the CREWMATE.md source"
rm "$OROOT/docs"
feed '\n\n\n\n\n\n\n\nyes\n'
oracle omega --container "$C" && o_rc=0 || o_rc=$?
assert_eq "$o_rc" 1 "row 13: the oracle fails on cp"
assert_contains "$(cat "$TMP/o.rawerr")" "cp: $OROOT/docs/examples/CREWMATE.md: No such file or directory" "row 13: cp's own line"
assert_file "$C/omega/config/backend" "row 13: the home is left half-seeded"
run_side "$obin" "$TMP/o.raw" "$TMP/o.rawerr" omega --container "$C" && o_rc=0 || o_rc=$?
assert_eq "$o_rc" 1 "row 13: the next run refuses the half-seeded home"
assert_eq "$(cat "$TMP/o.rawerr")" "ERROR: fleet home already exists: $C/omega" "row 13: as already existing"
ln -s "$ROOT/docs" "$OROOT/docs"

# 16. a child ended by a signal: 128+signal on both sides (bash's own
#     `Terminated: 15` line is shell-own stderr, not reproduced); the mkdir
#     stub dies on the HOME's own mkdir, after the questions, and passes every
#     other call to the real mkdir (the test's world is made through PATH too)
mkdir -p "$TMP/killmkdir"; printf '#!/bin/sh\ncase "$*" in *"/c/sig") kill -TERM $$ ;; *) exec /bin/mkdir "$@" ;; esac\n' >"$TMP/killmkdir/mkdir"; chmod +x "$TMP/killmkdir/mkdir"
feed "$ALL9"
PATH="$TMP/killmkdir:$PATH" ERR=own same sig --container "$C"
assert_eq "$LAST_RC" 143 "row 16: 128+SIGTERM on both sides"
assert_contains "$(shim_err)" "seed a per-fleet CREWMATE.md yes|no" "row 16: the questions were asked first"
assert_eq "$(shim_err | /usr/bin/grep -c -i 'terminated')" "0" "row 16: the port adds no line of its own"
assert_no_file "$C/sig" "row 16: nothing made"

# 17. a typed container holding a byte that is not UTF-8: the bash handed mkdir
#     the bytes and this filesystem refused them (`Illegal byte sequence`, exit
#     1, nothing made); the port refuses before mkdir with its own line - the
#     same result, the tool's line not reproduced (named)
feed "$WORLD/c\377\n$ALL9"
ERR=own same tau
assert_eq "$LAST_RC" 1 "row 17: both refuse"
assert_contains "$(oracle_err)" "Illegal byte sequence" "row 17: mkdir's own line on the original"
assert_contains "$(shim_err | od -An -c | tr -d ' \n')" "$(printf 'ERROR: homes container holds a byte that is not UTF-8: %s/c\377\n' "$WORLD" | od -An -c | tr -d ' \n')" "row 17: the port's line carries the bytes (after the prompt, on the same stderr line)"
assert_eq "$(ls "$WORLD/c")" "" "row 17: nothing made under the container"

pass
