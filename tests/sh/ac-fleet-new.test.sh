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
for f in bin CLAUDE.md .claude AGENTS.md .agents; do
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

# --- the run's bytes, row by row -------------------------------------------------
# Each row runs the shim in a fresh WORLD ($WORLD/c the container, cwd/ the
# caller's cwd, h/ its HOME, other/ its own AC_HOME that must stay untouched),
# fed its stdin bytes from a file, LC_ALL=C unless the row says otherwise,
# AC_HOMES_CONTAINER unset unless the row sets it.
WORLD="$TMP/world"
feed() { printf -- "$1" >"$TMP/in"; }  # feed <printf-format> - the stdin bytes the rows after it read
LAST_RC=0
run() {  # run <args...> - the shim in a fresh world, from its cwd, fed $TMP/in; sets LAST_RC
  rm -rf "$WORLD"; mkdir -p "$WORLD/c" "$WORLD/cwd" "$WORLD/h" "$WORLD/other"; ${PLANT:-:}
  # env's -u options must precede its assignments.
  local -a envs=()
  if [ "${NOHOME-}" = 1 ]; then envs+=(-u HOME); else envs+=(HOME="${HOMEV-$WORLD/h}"); fi
  envs+=(AC_HOME="$WORLD/other" LC_ALL="${FN_LC:-C}")
  [ "${AHC+set}" != set ] || envs+=(AC_HOMES_CONTAINER="$AHC")
  LAST_RC=0
  (cd "$WORLD/cwd" && env -u AC_HOMES_CONTAINER "${envs[@]}" "$BIN/ac-fleet-new.sh" "$@") <"$TMP/in" >"$TMP/n.out" 2>"$TMP/n.err" || LAST_RC=$?
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
refused() {  # refused <stderr> <label> - exit 1, no stdout, exactly <stderr>, nothing made under the container
  assert_eq "$LAST_RC:$(shim_out):$(shim_err)" "1::$1" "$2"
  assert_eq "$(ls -A "$C")" "" "$2: nothing made"
}
knob_bytes() { od -An -tx1 "$WORLD/$1" | tr -d ' \n'; }  # hex of a knob file
C="$WORLD/c"
ALL9='TN\nopus\nultracode\ncodex\ngpt-5.6-sol\nxhigh\nalways\nstaged\nyes\n'
NONE9='\n\n\n\n\n\n\n\n\n'
LASTQ='seed a per-fleet CREWMATE.md yes|no (empty: no - inherit the container-wide .claude/CLAUDE.md): '

# 1. every knob answered: the transcript's frame, the links, CREWMATE.md
feed "$ALL9"
run alpha --container "$C"
assert_eq "$LAST_RC:$(shim_out)" "0:$C/alpha" "row 1: exit 0, the home path is the only stdout"
assert_contains "$(shim_err)" "
== alpha: config knobs (empty = keep the shown default) ==
captain name (empty: the crewchief just says \"captain\"): crewmate model (empty: claude picks its own): " "row 1: the banner, then the prompts on one stderr line"
assert_contains "$(shim_err)" "$LASTQ
NEXT:
  ac alpha                    # via the launcher (bin/ac-setup.sh installs it)
  AC_HOME=$C/alpha claude   # or point a harness at it directly

The crewchief clones projects into $C/alpha/projects/ on your word - do not pre-clone." "row 1: the NEXT block closes the transcript"
assert_eq "$(readlink "$C/alpha/bin")" "$ROOT/bin" "row 1: the links name THIS checkout"
cmp -s "$C/alpha/CREWMATE.md" "$ROOT/docs/examples/CREWMATE.md" || fail "row 1: CREWMATE.md is the example's bytes"
assert_eq "$(ls -A "$WORLD/other")" "" "row 1: the caller's own AC_HOME is never touched"
# 2. a rejected enum re-asks
feed '\n\n\nbogus\ncodex\n\n\n\n\n\n'; run gamma --container "$C"
assert_eq "$LAST_RC" 0 "row 2: the re-asked run seeds"
assert_contains "$(shim_err)" "not one of: codex claude off (or empty)" "row 2: the re-ask line"

# 3. EOF at every kind of prompt, and an unterminated last answer
feed ''
run; assert_eq "$LAST_RC:$(shim_out)" "1:" "row 3: EOF at the name prompt refuses"
assert_contains "$(shim_err)" "ERROR: stdin closed while asking: fleet name" "row 3: EOF on the name"
run delta; assert_eq "$LAST_RC:$(shim_out)" "1:" "row 3: EOF at the container prompt refuses"
assert_contains "$(shim_err)" "ERROR: stdin closed while asking: homes container [$WORLD/h/Work/ac-homes]" "row 3: EOF on the container"
run delta --container "$C"
assert_contains "$(shim_err)" "ERROR: stdin closed while asking: captain name" "row 3: EOF on the first knob"
assert_no_file "$C/delta" "row 3: no home from EOF on the first knob"
feed '\n\n\n\n\n\n\n\n'; run epsilon --container "$C"
assert_eq "$LAST_RC" 1 "row 3: EOF on the last enum refuses"
feed '\n\n\n\n'; run zeta --container "$C"
assert_contains "$(shim_err)" "stdin closed while asking: gate judge model" "row 3: EOF on a free-text prompt"
# A last line with no LF is discarded like EOF: the typed `yes` is lost and
# the run is refused.
feed '\n\n\n\n\n\n\n\nyes'; run eta --container "$C"
assert_eq "$LAST_RC" 1 "row 3: an unterminated last answer is refused"
assert_no_file "$C/eta" "row 3: no home from an unterminated answer"

# 4. CR is a value byte; a CR-suffixed enum never matches
feed 'TN\r\n\n\n\n\n\n\n\n\n'; run theta --container "$C"
assert_eq "$(knob_bytes c/theta/config/captain)" 544e0d0a "row 4: the CR is written with the value"
feed '\n\nhigh\r\n'; run iota --container "$C"
assert_eq "$LAST_RC" 1 "row 4: high<CR> re-asks until EOF"
assert_contains "$(shim_err)" "not one of: low medium high xhigh max ultracode (or empty)" "row 4: the CR enum was rejected"

# 5. odd values: spaces and a backslash kept, case and trailing space never
# match an enum, a leading dash is a value
feed ' TN\\x \n\nLOW\nlow\n\n\n\nalways \nalways\n\n\n'; run kappa --container "$C"
assert_eq "$(knob_bytes c/kappa/config/captain)" 20544e5c78200a "row 5: spaces and the backslash are value bytes"
assert_eq "$(cat "$C/kappa/config/effort")" low "row 5: LOW re-asked, low taken"
assert_eq "$(cat "$C/kappa/config/promote")" always "row 5: 'always ' re-asked, always taken"
feed '-x\n\n\n\n\n\n\n\n\n'; run lambda --container "$C"
assert_eq "$(cat "$C/lambda/config/captain")" "-x" "row 5: a leading dash is a value"
# a NUL ends the value; the rest of its line is dropped
feed 'a\000b\n\n\n\n\n\n\n\n\n'; run mu --container "$C"
assert_eq "$(knob_bytes c/mu/config/captain)" 610a "row 5: a NUL truncates the answer"

# 6. no name: the re-ask loop, then the container prompt and its default
feed 'bad name\n\nzeta\n\n'"$NONE9"; run
assert_contains "$(shim_err)" "fleet name: name must be [a-zA-Z0-9_-]: bad name" "row 6: a bad typed name re-asks"
assert_contains "$(shim_err)" "fleet name: a fleet needs a name" "row 6: an empty typed name re-asks"
assert_contains "$(shim_err)" "homes container [$WORLD/h/Work/ac-homes]: " "row 6: the HOME default on the prompt"
assert_eq "$(shim_out)" "$WORLD/h/Work/ac-homes/zeta" "row 6: an empty container answer takes the default"
AHC="$C/sub" run
assert_contains "$(shim_err)" "homes container [$C/sub]: " "row 6: AC_HOMES_CONTAINER on the prompt"
[ -d "$C/sub/zeta" ] || fail "row 6: the AC_HOMES_CONTAINER default is created"
AHC="" run
assert_eq "$(shim_out)" "$WORLD/h/Work/ac-homes/zeta" "row 6: an EMPTY AC_HOMES_CONTAINER is unset"
feed 'zeta\n'"$NONE9"; run "" --container "$C"
assert_eq "$(shim_out)" "$C/zeta" "row 6: an empty argv word is no name"

# 7. arguments
feed "$NONE9"
run nu --container ''; refused "ERROR: --container needs a path" "row 7: an empty --container"
run nu --container; refused "ERROR: --container needs a path" "row 7: a trailing --container"
run xi --container "$WORLD/nope" --container "$C"
assert_eq "$(shim_out)" "$C/xi" "row 7: the last --container wins"
assert_no_file "$WORLD/nope" "row 7: the losing --container is never made"
run a b; refused "ERROR: unexpected argument: b" "row 7: a second bare word"
run --bogus; refused "ERROR: unknown argument: --bogus" "row 7: an unknown flag"
run x y -h; refused "ERROR: unexpected argument: y" "row 7: the scan refuses before it reaches -h"
header="$(sed -n '/^\/\//!q; s#^// \{0,1\}##p' "$ROOT/src/fleet-new.ts")"
helped() {  # helped <label> - exit 0, the module header on stdout, nothing made
  assert_eq "$LAST_RC:$(shim_out):$(shim_err)" "0:$header:" "row 7: $1 prints the src/fleet-new.ts header"
  assert_eq "$(ls -A "$C")" "" "row 7: $1 makes nothing"
}
run -h; helped "-h"
run --help; helped "--help"
run x -h; helped "-h after a name"

# 8. names: the charset guard per the text, under every locale
run A-z_09 --container "$C"
assert_eq "$LAST_RC:$(shim_out)" "0:$C/A-z_09" "row 8: letters, digits, dash and underscore"
eacute="$(printf '\303\251')"
for bad in 'a b' a/b . .. "$eacute"; do
  run "$bad" --container "$C"; refused "ERROR: name must be [a-zA-Z0-9_-]: $bad" "row 8: '$bad' refused"
done
FN_LC=en_US.UTF-8 run "$eacute" --container "$C"; refused "ERROR: name must be [a-zA-Z0-9_-]: $eacute" "row 8: é refused under UTF-8 too"

# 9. what sits at the home path, and at the container
PLANT="mkdir -p $C/alpha" run alpha --container "$C"
assert_eq "$LAST_RC:$(shim_out):$(shim_err)" "1::ERROR: fleet home already exists: $C/alpha" "row 9: an existing dir refuses before any question"
PLANT="touch $C/alpha" run alpha --container "$C"
assert_eq "$LAST_RC:$(shim_out):$(shim_err)" "1::ERROR: fleet home already exists: $C/alpha" "row 9: a file at the home path refuses too"
PLANT="touch $WORLD/cf" run omicron --container "$WORLD/cf"
assert_eq "$LAST_RC:$(shim_out)" "1:" "row 9: a FILE as the container refuses"
case "$(shim_err)" in *"captain name"*) fail "row 9: a FILE as the container refuses before any question" ;; esac

# 10. container spellings: ~ forms, relative, trailing slash, missing parents
run pi --container '~/hh'
assert_eq "$(shim_out)" "$WORLD/h/hh/pi" "row 10: ~/x expands against HOME"
run rho --container '~'
assert_eq "$(shim_out)" "$WORLD/h/rho" "row 10: a bare ~ is HOME"
run sigma --container '~x'
assert_eq "$(shim_out)" "$WORLD/cwd/~x/sigma" "row 10: ~x is a literal name under the cwd"
run tau --container rel/path
assert_eq "$(shim_out)" "$WORLD/cwd/rel/path/tau" "row 10: a relative container resolves against the caller's cwd"
run upsilon --container "$C/"
assert_eq "$(shim_out)" "$C/upsilon" "row 10: a trailing slash is dropped by the physical bind"
run phi --container "$C/deep/er"
assert_eq "$(shim_out)" "$C/deep/er/phi" "row 10: mkdir -p creates missing parents"
feed 'zeta\n~/typed\n'"$NONE9"; run
assert_eq "$(shim_out)" "$WORLD/h/typed/zeta" "row 10: a typed ~/ container expands too"

# 11. HOME: unset where it is needed is refused; empty is a value.
feed "$NONE9"
NOHOME=1 run chi --container '~/x'; refused "ERROR: HOME is not set" "row 11: HOME unset with ~/x"
NOHOME=1 run chi; refused "ERROR: HOME is not set" "row 11: HOME unset with no container, before any prompt"
NOHOME=1 run chi --container "$C"
assert_eq "$LAST_RC:$(shim_out)" "0:$C/chi" "row 11: HOME unset is fine when nothing reads it"
HOMEV="" run psi --container "~/${WORLD#/}/pc"
assert_eq "$LAST_RC:$(shim_out)" "0:$WORLD/pc/psi" "row 11: an EMPTY HOME is a value - ~/<path> expands to /<path>"

# 12. a child ended by a signal is 128+signal: the mkdir stub dies on the
#     HOME's own mkdir, after the questions, and passes every other call to
#     the real mkdir (the test's world is made through PATH too)
mkdir -p "$TMP/killmkdir"; printf '#!/bin/sh\ncase "$*" in *"/c/sig") kill -TERM $$ ;; *) exec /bin/mkdir "$@" ;; esac\n' >"$TMP/killmkdir/mkdir"; chmod +x "$TMP/killmkdir/mkdir"
feed "$ALL9"
PATH="$TMP/killmkdir:$PATH" run sig --container "$C"
assert_eq "$LAST_RC:$(shim_out)" "143:" "row 12: 128+SIGTERM"
case "$(shim_err)" in
  *"$LASTQ") ;;
  *) fail "row 12: the questions were asked first, and no line is added after them: $(shim_err)" ;;
esac
assert_no_file "$C/sig" "row 12: nothing made"

# 13. a typed container holding a byte that is not UTF-8 is refused before
#     mkdir, the entry's line carrying the bytes
feed "$WORLD/c\377\n$ALL9"
run tau
assert_eq "$LAST_RC:$(shim_out)" "1:" "row 13: refused"
assert_contains "$(shim_err | od -An -c | tr -d ' \n')" "$(printf 'ERROR: homes container holds a byte that is not UTF-8: %s/c\377\n' "$WORLD" | od -An -c | tr -d ' \n')" "row 13: the line carries the bytes (after the prompt, on the same stderr line)"
assert_eq "$(ls "$WORLD/c")" "" "row 13: nothing made under the container"

pass
