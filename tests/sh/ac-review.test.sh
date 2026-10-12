#!/usr/bin/env bash
# ac-review.test.sh - the differential leg of the review CLI: src/review.ts
# through bin/ac-review.sh against the bash original frozen at
# tests/fixtures/ac-review.sh, over a stubbed curl (a replay queue that logs
# its argv) for every verb and wart, then over a REAL dashboard on an ephemeral
# port for reply and poll. The agent-facing contracts live in
# ac-review-auto-open, ac-review-poll and ac-review-reply.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || skip 'jq not installed'
command -v bun >/dev/null 2>&1 || skip 'bun not installed'

# --- differential: src/review.ts against the frozen bash original ------------
# DISPUTED: the implementation (tests/fixtures/ac-review.sh under bash vs src/review.ts through bin/ac-review.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home holding data/a.html, a TMPDIR at <side>/tmp, a curl replay queue at <side>/q seeded alike per row (one PATH curl stub both sides run, logging every argv element and the cksum of an @<file> body), one set of logging opener stubs on PATH (open, xdg-open, mybrowser - each writes its argv and the first line of its stdin to <side>/open.log, prints to stdout and stderr, exits 3), the real jq, argv and env (the side root spelled HOME), cwd <side>/home/data unless a row names another, stdin /dev/null unless a row names a file, LC_ALL=C, AC_DASH_PORT/BROWSER/CDPATH unset unless a row sets them; exit status, stdout and stderr compared whole, plus the curl argv log, the opener log and the TMPDIR listing - the side root spelled HOME, its jq @uri spelling too, and a mktemp spool's random suffix spelled XXXXXX.
obin="$(make_oracle_bin ac-review)"
OH="$TMP/side-o"; NH="$TMP/side-n"
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
seed() { mkdir -p "$H/home/data" "$H/home/config" "$H/home/state" "$H/tmp" "$H/q"; printf '<html></html>\n' >"$H/home/data/a.html"; }
both seed

mkdir -p "$TMP/stub" "$TMP/op"
cat >"$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
n=0
[ ! -f "$RESP_DIR/.count" ] || n="$(cat "$RESP_DIR/.count")"
n=$((n + 1))
printf '%s' "$n" >"$RESP_DIR/.count"
{
  printf 'call %s\n' "$n"
  prev=""
  for a in "$@"; do
    printf '[%s]\n' "$a"
    case "$prev:$a" in --data-binary:@*) printf 'body %s\n' "$(cksum <"${a#@}")" ;; esac
    prev="$a"
  done
} >>"$RESP_DIR/argv.log"
[ ! -f "$RESP_DIR/$n.out" ] || cat "$RESP_DIR/$n.out"
[ ! -f "$RESP_DIR/$n.err" ] || cat "$RESP_DIR/$n.err" >&2
[ ! -f "$RESP_DIR/$n.out2" ] || cat "$RESP_DIR/$n.out2"
[ ! -f "$RESP_DIR/$n.sig" ] || kill -"$(cat "$RESP_DIR/$n.sig")" $$
rc=0
[ ! -f "$RESP_DIR/$n.rc" ] || rc="$(cat "$RESP_DIR/$n.rc")"
exit "$rc"
EOF
for o in open xdg-open mybrowser; do
  cat >"$TMP/op/$o" <<'EOF'
#!/usr/bin/env bash
{ printf '%s' "${0##*/}"; for a in "$@"; do printf ' [%s]' "$a"; done; IFS= read -r l && printf ' stdin=[%s]' "$l"; printf '\n'; } >>"$OPEN_LOG"
echo out-of-opener; echo err-of-opener >&2; exit 3
EOF
done
chmod +x "$TMP/stub/curl" "$TMP/op/"*
# A PATH with no opener at all: every host executable mirrored (first dir
# wins, as a PATH lookup) except open/xdg-open - the shape of a headless box.
mkdir -p "$TMP/mirror"
IFS=':' read -r -a pdirs <<<"$PATH"
for d in "${pdirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    case "${f##*/}" in open | xdg-open) continue ;; esac
    [ -e "$TMP/mirror/${f##*/}" ] || ln -s "$f" "$TMP/mirror/${f##*/}" 2>/dev/null || true
  done
done
mkdir -p "$TMP/xdg"; cp "$TMP/op/xdg-open" "$TMP/xdg/xdg-open"
# Opener names no host tool carries: a lookup that walks past the stub dir must
# find nothing real to run.
mkdir -p "$TMP/opx"; printf '#!/bin/sh\necho never\n' >"$TMP/opx/ac-review-noexec-opener"; chmod 644 "$TMP/opx/ac-review-noexec-opener"
# PATHs that lack one required tool and keep what both entries need to reach
# that refusal (bash for the shebang, dirname for the source line, bun for
# the shim).
mkdir -p "$TMP/nocurl" "$TMP/nojq"
for t in bash dirname bun jq; do ln -s "$(command -v "$t")" "$TMP/nocurl/$t"; done
for t in bash dirname bun; do ln -s "$(command -v "$t")" "$TMP/nojq/$t"; done
ln -s "$TMP/stub/curl" "$TMP/nojq/curl"

HOMELESS=0
RV_ENV=()
RV_CWD=home/data
RV_STDIN=/dev/null
# watch <pid> <secs> - kill -9 <pid> once <secs> pass (helpers.sh kill_after);
# `kill "$WD"` stands the watchdog down, its sleep included.
watch() {
  kill_after "$2" "$1"
  WD=$KILL_AFTER_PID
}
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root
  local bin="$1" h="$2" p="$3" x v pid rc=0; shift 3
  local a=() e=(LC_ALL=C "PATH=$TMP/stub:$TMP/op:$PATH" "TMPDIR=$h/tmp" "RESP_DIR=$h/q" "OPEN_LOG=$h/open.log")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${RV_ENV[@]+"${RV_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  # The poll loop has no bound of its own: a regression that loops must fail
  # the row (kill -9 -> 137), never hang the suite.
  ( cd "$h/$RV_CWD" && exec env -u AC_HOME -u AC_DASH_PORT -u BROWSER -u CDPATH "${e[@]}" "$bin/ac-review.sh" ${a[@]+"${a[@]}"} ) <"$RV_STDIN" >"$TMP/$p.raw" 2>"$TMP/$p.err" &
  pid=$!
  watch "$pid" 20
  wait "$pid" || rc=$?
  kill "$WD" 2>/dev/null || true
  wait "$WD" 2>/dev/null || true
  return "$rc"
}
norm() {  # norm <file> <side root> - the root and its @uri spelling as HOME, a spool suffix as XXXXXX
  local enc; enc="$(jq -rn --arg v "$2" '$v|@uri')"
  [ ! -e "$1" ] || LC_ALL=C sed -e "s#$enc#HOME#g" -e "s#$2#HOME#g" -e 's#ac-review-reply\.[A-Za-z0-9]\{6\}#ac-review-reply.XXXXXX#g' "$1"
}
# The bash test builtin's own complaint about a non-integer (W8) - a line, or
# two when the value holds an LF - is the shell's, never the port's.
ROW_NOISE=0
strip_noise() { NOISE="$obin/ac-review.sh" perl -0777 -pe 's{^\Q$ENV{NOISE}\E: line \d+: \[: .*?: integer expression expected\n}{}gms' "$1"; }
side_files() {  # side_files <side root> <prefix> - the argv log, opener log and TMPDIR listing, normalized
  norm "$1/q/argv.log" "$1" >"$TMP/$2.argv"
  norm "$1/open.log" "$1" >"$TMP/$2.open"
  ls -A "$1/tmp" >"$TMP/$2.tmpls"; norm "$TMP/$2.tmpls" "$1" >"$TMP/$2.tmp"
  cat "$1/q/.count" >"$TMP/$2.count" 2>/dev/null || printf 0 >"$TMP/$2.count"
}
compare() {  # compare <o_rc> <n_rc> <what>
  if [ "$ROW_NOISE" = 1 ]; then
    /usr/bin/grep -q 'integer expression expected' "$TMP/o.err" || fail "the oracle printed no test-builtin noise for $3 - the row does not reach W8"
    strip_noise "$TMP/o.err" >"$TMP/o.err1"; mv "$TMP/o.err1" "$TMP/o.err"
  fi
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
  side_files "$OH" o; side_files "$NH" n
  assert_eq "$2" "$1" "differential exit for $3"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for $3: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for $3: $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
  cmp -s "$TMP/o.argv" "$TMP/n.argv" || fail "differential curl argv differs for $3: $(diff "$TMP/o.argv" "$TMP/n.argv" | head -n 6)"
  cmp -s "$TMP/o.open" "$TMP/n.open" || fail "differential opener log differs for $3: $(diff "$TMP/o.open" "$TMP/n.open" | head -n 4)"
  cmp -s "$TMP/o.tmp" "$TMP/n.tmp" || fail "differential TMPDIR differs for $3: $(diff "$TMP/o.tmp" "$TMP/n.tmp" | head -n 4)"
}
reset_sides() {
  local h; for h in "$OH" "$NH"; do rm -rf "$h/q" "$h/open.log" "$h/tmp"; mkdir -p "$h/q" "$h/tmp"; done
}
run_both() {  # run_both <args...> - both sides, statuses in O_RC/N_RC, a hang failed
  O_RC=0; N_RC=0
  run_side "$obin" "$OH" o "$@" || O_RC=$?
  run_side "$BIN" "$NH" n "$@" || N_RC=$?
  [ "$O_RC" != 137 ] && [ "$N_RC" != 137 ] || fail "a side hung on '$*' (oracle $O_RC, shim $N_RC)"
}
same() {  # same <args...> - the oracle on $OH and the shim on $NH answer byte-identically
  run_both "$@"
  compare "$O_RC" "$N_RC" "'$*' (${RV_ENV[*]+${RV_ENV[*]}}) at line ${BASH_LINENO[0]}"
  reset_sides
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
shim_argv() { cat "$TMP/n.argv"; }
shim_open() { cat "$TMP/n.open"; }
shim_tmp() { cat "$TMP/n.tmp"; }
resp() {  # resp <n> <stdout printf format> [<rc>] [<stderr format>] [<signal>] [<stdout format after stderr>] - curl call n's answer, both sides
  local h; for h in "$OH" "$NH"; do
    printf "$2" >"$h/q/$1.out"; printf '%s' "${3:-0}" >"$h/q/$1.rc"
    [ -z "${4:-}" ] || printf "$4" >"$h/q/$1.err"
    [ -z "${5:-}" ] || printf '%s' "$5" >"$h/q/$1.sig"
    [ -z "${6:-}" ] || printf "$6" >"$h/q/$1.out2"
  done
}
calls() { cat "$TMP/n.count"; }
NO_HOME_LINE="ERROR: $(/usr/bin/grep -m1 -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh")"
REQ="[-sS]
[--connect-timeout]
[2]
[--max-time]
[40]
[-X]"
Q="path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fa.html"
VIEW="review open - captain viewer: http://127.0.0.1:8787/review?$Q"

# 1. the prelude, in the original's order: the tools before any argument, the
#    verb, the file, `[ -f ]` (a directory or a FIFO is no artifact), then the
#    home - unset is ac_home's refusal AND the entry's own line (two ERROR
#    lines, kept); a missing artifact is refused before the home is read.
same
assert_eq "$(shim_err)" "ERROR: usage: ac-review.sh open|poll|reply|end|url <file>.html [options]" "row 1: no verb"
same -h
same bogus a.html
same open
assert_eq "$(shim_err)" "ERROR: usage: ac-review.sh open <file>.html [options]" "row 1: no file"
same open missing.html
assert_eq "$(shim_err)" "ERROR: no such artifact: missing.html" "row 1: a missing artifact, as given"
same open HOME/home/data
assert_eq "$(shim_err)" "ERROR: no such artifact: HOME/home/data" "row 1: a directory is no artifact"
fifo() { mkfifo "$H/home/data/f.html"; }
both fifo
same url f.html
assert_eq "$(shim_err)" "ERROR: no such artifact: f.html" "row 1: a FIFO is no artifact (never opened)"
RV_ENV=("PATH=$TMP/nocurl")
same url a.html
assert_eq "$(shim_err)" "ERROR: required tool not found: curl" "row 1: curl off PATH"
same
RV_ENV=("PATH=$TMP/nojq")
same bogus
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "row 1: jq off PATH, before the verb"
RV_ENV=()
# A request over the SUFFICIENT minimal PATH: the curl stub, bash, dirname,
# basename, bun and jq, no `sh` - the capture's shell is /bin/sh by path
mkdir -p "$TMP/minpath"
for t in bash dirname basename bun jq cat; do ln -s "$(command -v "$t")" "$TMP/minpath/$t"; done  # cat: the curl stub's own need
ln -s "$TMP/stub/curl" "$TMP/minpath/curl"
resp 1 '{"ok":true}'; RV_ENV=("PATH=$TMP/minpath")
same open a.html
RV_ENV=()
assert_eq "$N_RC" 0 "row 1: a request needs no sh on PATH"
assert_contains "$(shim_out)" "review open - captain viewer:" "row 1: ... and answers"
# Executables the kernel refuses (no shebang) run under bash, as `command -v`
# resolved them and bash ran them: a jq wrapper and an opener
mkdir -p "$TMP/noshebang"
printf 'exec %s "$@"\n' "$(command -v jq)" >"$TMP/noshebang/jq"; chmod 755 "$TMP/noshebang/jq"
RV_ENV=("PATH=$TMP/noshebang:$TMP/stub:$TMP/op:$PATH")
same url a.html
RV_ENV=()
assert_eq "$N_RC" 0 "row 1: a shebang-less jq wrapper runs under bash"
assert_contains "$(shim_out)" "/review?path=" "row 1: ... and answers the url"
# ... with NO bash on PATH either: the entries started as `/bin/bash <entry>`
# (the shell runs the file with itself), over the minimal PATH plus the wrapper
mkdir -p "$TMP/nobash"
for t in dirname basename bun cat; do ln -s "$(command -v "$t")" "$TMP/nobash/$t"; done
ln -s "$TMP/stub/curl" "$TMP/nobash/curl"; ln -s "$TMP/noshebang/jq" "$TMP/nobash/jq"
nb() { (cd "$2/$RV_CWD" && env -u AC_HOME AC_HOME="$2/home" LC_ALL=C PATH="$TMP/nobash" TMPDIR="$2/tmp" RESP_DIR="$2/q" OPEN_LOG="$2/open.log" AC_DASH_PORT=8787 /bin/bash "$1/ac-review.sh" url a.html) 2>&1; echo "rc=$?"; }
nbn() { nb "$1" "$2" | sed -e "s#$2#HOME#g" -e "s#$(printf '%s' "$2" | sed 's#/#%2F#g')#HOME#g"; }  # the root, plain and %2F-encoded
assert_eq "$(nbn "$BIN" "$NH")" "$(nbn "$obin" "$OH")" "row 1: the ENOEXEC fallback needs no bash on PATH"
assert_contains "$(nb "$BIN" "$NH")" "rc=0" "row 1: ... and the url is answered"
HOMELESS=1
same url a.html
assert_eq "$(shim_err)" "$NO_HOME_LINE
ERROR: AC_HOME required: the review session belongs to a fleet home" "row 1: homeless is two ERROR lines"
same url missing.html
assert_eq "$(shim_err)" "ERROR: no such artifact: missing.html" "row 1: the artifact before the home"
HOMELESS=0
#    W1 (named): an AC_HOME cd cannot enter - the original printed cd's own
#    line before the entry's; the port prints the entry's line alone (the HOME
#    RESOLUTION ruling), exit 1 alike.
HOMELESS=1; RV_ENV=("AC_HOME=HOME/missing")
run_both url a.html
HOMELESS=0; RV_ENV=()
assert_eq "$O_RC $N_RC" "1 1" "row 1 W1: both exit 1"
norm "$TMP/o.err" "$OH" >"$TMP/o.err2"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
assert_contains "$(sed -n 1p "$TMP/o.err2")" "cd: HOME/missing: No such file or directory" "row 1 W1: the original's cd line"
assert_eq "$(sed 1d "$TMP/o.err2")" "ERROR: AC_HOME required: the review session belongs to a fleet home" "row 1 W1: then the entry's line"
assert_eq "$(shim_err)" "ERROR: AC_HOME required: the review session belongs to a fleet home" "row 1 W1: the port prints the entry's line alone"
assert_eq "$(cat "$TMP/n.raw" "$TMP/o.raw")" "" "row 1 W1: nothing on stdout"
reset_sides

# 2. url: no request, `<base>/review?<q>` - the port from AC_DASH_PORT, an
#    EMPTY one falling to config/dash-port's first line [:space:]-trimmed,
#    neither validated; the artifact's directory physical, its basename kept
#    (a symlinked file keeps its link name); both halves of q through jq @uri;
#    words after the file ignored.
same url a.html extra
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: the viewer url"
assert_eq "$(shim_argv)" "" "row 2: url makes no request"
RV_ENV=(AC_DASH_PORT=1)
same url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:1/review?$Q" "row 2: AC_DASH_PORT"
knob() { printf "$1" >"$H/home/config/dash-port"; }
both knob ' 9999 \r\nsecond\n'
RV_ENV=(AC_DASH_PORT=)
same url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:9999/review?$Q" "row 2: an empty AC_DASH_PORT reads the trimmed knob"
RV_ENV=("AC_DASH_PORT=a b")
same url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:a b/review?$Q" "row 2: the port is never validated"
RV_ENV=()
rmknob() { rm -f "$H/home/config/dash-port"; }
both rmknob
RV_ENV=(AC_DASH_PORT=)
same url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: an empty AC_DASH_PORT and no knob read 8787"
RV_ENV=()
same url HOME/home/data/a.html
same url ./a.html
same url ../data/a.html
RV_CWD=home
same url data/a.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: a path relative to the caller's cwd"
RV_CWD=home/data
links() { mkdir -p "$H/home/real"; printf 'r\n' >"$H/home/real/r.html"; ln -s "$H/home/real" "$H/home/ldir"; ln -s a.html "$H/home/data/link.html"; }
both links
same url ../ldir/r.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Freal%2Fr.html" "row 2: a symlinked directory resolves"
same url link.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Flink.html" "row 2: a symlinked file keeps its link name"
WEIRD="a b~!*'();:@&=+\$,?#[]$(printf '\303\251').md"
weird() { mkdir -p "$H/home/data/w"; printf 'w\n' >"$H/home/data/w/$WEIRD"; }
both weird
same url "w/$WEIRD"
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fw%2Fa%20b~%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%3F%23%5B%5D%C3%A9.md" "row 2: jq's @uri keeps only A-Za-z0-9-_.~"
#    A file argument starting with `-` is an option to dirname and basename:
#    their usage text, exit 1 (a file named `-` alone is an operand).
dashes() { mkdir -p "$H/home/data/-x"; printf 'd\n' >"$H/home/data/-x/a.html"; printf 'd\n' >"$H/home/data/-"; }
both dashes
same url -x/a.html
assert_contains "$(shim_err)" "dirname: illegal option -- x" "row 2: dirname's own refusal"
same url -
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2F-" "row 2: a file named -"
#    The knob unreadable: the port is "" (named: head's own line on the
#    original's stderr is not reproduced).
if [ "$(id -u)" != 0 ]; then
  locked() { printf '9999\n' >"$H/home/config/dash-port"; chmod 000 "$H/home/config/dash-port"; }
  both locked
  RV_ENV=(AC_DASH_PORT=)
  run_both url a.html
  RV_ENV=()
  unlock() { chmod 644 "$H/home/config/dash-port"; rm -f "$H/home/config/dash-port"; }
  both unlock
  assert_eq "$O_RC $N_RC" "0 0" "row 2: an unreadable knob still answers"
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/n.raw" "$NH" >"$TMP/n.out"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "row 2: stdout differs on an unreadable knob"
  assert_eq "$(shim_out)" "http://127.0.0.1:/review?$Q" "row 2: an unreadable knob reads empty"
  assert_contains "$(cat "$TMP/o.err")" "Permission denied" "row 2: head's own line on the original"
  assert_eq "$(cat "$TMP/n.err")" "" "row 2: not reproduced (named)"
  reset_sides
fi
#    W10 (named): an exported CDPATH redirected the original's `cd` of a
#    relative directory into the CDPATH match and captured cd's echo into the
#    path; the port never consults CDPATH and names the file it tested.
cdp() { mkdir -p "$H/cdp/sub" "$H/home/data/sub"; printf 'c\n' >"$H/cdp/sub/x.html"; printf 'h\n' >"$H/home/data/sub/x.html"; }
both cdp
RV_ENV=("CDPATH=HOME/cdp")
run_both url sub/x.html
RV_ENV=()
norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/n.raw" "$NH" >"$TMP/n.out"
assert_eq "$O_RC $N_RC" "0 0" "row 2 W10: both answer"
assert_eq "$(cat "$TMP/o.out")" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fcdp%2Fsub%0AHOME%2Fcdp%2Fsub%2Fx.html" "row 2 W10: the original named the CDPATH match, cd's echo inside"
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fsub%2Fx.html" "row 2 W10: the port names the file it tested"
reset_sides
#    A name ending in LF (named, the HOME RESOLUTION class): the original's
#    `$(basename)` dropped the LF and named a sibling; the port keeps it.
lfname() { printf 'n\n' >"$H/home/data/n.html
"; }
both lfname
run_both url "n.html
"
assert_eq "$O_RC $N_RC" "0 0" "row 2 LF: both answer"
norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/n.raw" "$NH" >"$TMP/n.out"
assert_eq "$(cat "$TMP/o.out")" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fn.html" "row 2 LF: the original named the sibling"
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fn.html%0A" "row 2 LF: the port names the file"
reset_sides

# 3. open: POST /api/review/end?<q>&reopen=1 - ok prints the viewer line; a
#    refusal names `.error`, else the whole body as jq pretty-prints it, with
#    a TRAILING SPACE (W2); a non-JSON body is jq's parse error from both of
#    the original's jq reads; req classifies curl's exit; curl's stdout and
#    stderr are ONE capture in write order (W4: a warning on a good answer
#    makes it unreadable), NULs dropped, trailing LFs stripped.
resp 1 '{"ok":true}\n\n'
same open a.html
assert_eq "$(shim_out)" "$VIEW" "row 3: the viewer line"
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[http://127.0.0.1:8787/api/review/end?$Q&reopen=1]" "row 3: the curl argv"
resp 1 '{"ok":false,"error":"human ended"}'
same open a.html
assert_eq "$(shim_err)" "ERROR: open refused: human ended " "row 3 W2: the trailing space"
resp 1 '{"ok":false}'
same open a.html
assert_eq "$(shim_err)" 'ERROR: open refused: {
  "ok": false
} ' "row 3 W2: the whole body, pretty-printed"
resp 1 '<html>\n'
same open a.html
assert_eq "$(shim_err)" "jq: parse error: Invalid numeric literal at line 2, column 0
jq: parse error: Invalid numeric literal at line 2, column 0
ERROR: open refused:  " "row 3 W2: a non-JSON body, jq's line from each read"
resp 1 '{"ok":\000tr\000ue}\n'
same open a.html
assert_eq "$(shim_out)" "$VIEW" "row 3: NULs dropped from the capture"
resp 1 '' 7 'curl: (7) Failed to connect\n'
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh" "row 3: curl 7"
resp 1 '' 28
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard on port 8787 timed out - it may be overloaded, retry" "row 3: curl 28"
resp 1 '' 52
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard on port 8787 dropped the connection (a transport hiccup, not a dead process) - retry" "row 3: curl 52"
resp 1 '' 56
same open a.html
resp 1 'part ' 6 'curl: (6) Could not resolve host: x\n' '' 'tail\n'
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 6): part curl: (6) Could not resolve host: x
tail" "row 3 W4: stdout and stderr in write order"
resp 1 '{"ok":true}\n' 0 'Warning: noise\n'
same open a.html
assert_contains "$(shim_err)" 'ERROR: open refused: {
  "ok": true
}' "row 3 W4: a curl warning makes a good answer unreadable"
resp 1 '' 0 '' TERM
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 143): " "row 3: a signalled curl is 128+signal"
resp 1 'half' 0 '' TERM
same open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 143): half" "row 3: what it wrote before the signal"

# 4. open --reopen: the forced reopen piped into `jq -e .ok` - a transport
#    failure prints req's line AND `reopen failed` (W3), a refusal only the
#    latter; options are checked before any request.
resp 1 '{"ok":true}'
same open a.html --reopen
assert_eq "$(shim_out)" "$VIEW" "row 4: reopen"
assert_contains "$(shim_argv)" "[http://127.0.0.1:8787/api/review/end?$Q&reopen=1&force=1]" "row 4: the forced reopen"
resp 1 '' 7
same open a.html --reopen
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh
ERROR: reopen failed" "row 4 W3: two ERROR lines"
resp 1 '{"ok":false}'
same open a.html --reopen
assert_eq "$(shim_err)" "ERROR: reopen failed" "row 4: a refusal"
resp 1 '<x>'
same open a.html --reopen
resp 1 '{"ok":true}'
same open a.html --reopen --reopen
assert_eq "$(calls)" 1 "row 4: one request"
same open a.html --auto-open --bogus
assert_eq "$(shim_err)" "ERROR: unknown open option: --bogus" "row 4: an unknown option"
assert_eq "$(shim_argv)$(shim_open)" "" "row 4: no request, no launch"

# 5. --auto-open, after the viewer line: $BROWSER when `command -v` resolves
#    it - a PATH executable, a path, a shell builtin or keyword (W12: those
#    launch nothing; `exit` ends the run 255), a PATH file that is not
#    executable (bash's last resort: resolved, nothing launched) - else open,
#    else xdg-open, else nothing; the opener's argv is [<url>], its stdin the
#    caller's, its output and status discarded.
URL="${VIEW#*viewer: }"
absop() { mkdir -p "$H/op-abs"; cp "$TMP/op/mybrowser" "$H/op-abs/mybrowser"; }
both absop
printf 'fed\n' >"$TMP/stdin5"
ao() {  # ao <expected opener log> <env...> - open --auto-open answered ok, under the env given
  local want="$1"; shift
  resp 1 '{"ok":true}'; RV_ENV=("$@")
  same open a.html --auto-open
  RV_ENV=()
  assert_eq "$(shim_out)" "$VIEW" "row 5 [$*]: the viewer line first"
  assert_eq "$(shim_open)" "$want" "row 5 [$*]: the opener"
}
ao "mybrowser [$URL]" BROWSER=mybrowser
ao "mybrowser [$URL]" BROWSER=HOME/op-abs/mybrowser
noshebang_op() { mkdir -p "$H/op-ns"; printf '{ printf "%%s" "${0##*/}"; for a in "$@"; do printf " [%%s]" "$a"; done; printf "\\n"; } >>"$OPEN_LOG"\n' >"$H/op-ns/nsbrowser"; chmod 755 "$H/op-ns/nsbrowser"; }
both noshebang_op
ao "nsbrowser [$URL]" BROWSER=HOME/op-ns/nsbrowser
ao "open [$URL]" "BROWSER=mybrowser --new"
ao "" BROWSER=:
ao "" BROWSER=true
ao "" BROWSER=echo
ao "" "BROWSER=[["
ao "" BROWSER=exit
assert_eq "$N_RC" 255 "row 5 W12: the builtin exit ends the run 255"
ao "" BROWSER=return
assert_eq "$N_RC" 255 "row 5 W12: return ends it 255 too"
ao "" BROWSER=shift
assert_eq "$N_RC" 1 "row 5 W12: shift ends it 1"
ao "" BROWSER=ac-review-noexec-opener "PATH=$TMP/opx:$TMP/stub:$TMP/op:$PATH"
ao "open [$URL]" BROWSER=ac-review-no-such-opener
ao "open [$URL]" BROWSER=/etc/passwd
RV_STDIN="$TMP/stdin5"
ao "open [$URL] stdin=[fed]" BROWSER=
RV_STDIN=/dev/null
ao "xdg-open [$URL]" "PATH=$TMP/stub:$TMP/xdg:$TMP/mirror"
ao "" "PATH=$TMP/stub:$TMP/mirror"
assert_eq "$(shim_err)" "" "row 5: no opener - silent"
resp 1 '' 7; RV_ENV=(BROWSER=mybrowser); same open a.html --auto-open
RV_ENV=()
assert_eq "$(shim_open)" "" "row 5: a failed request launches nothing"
#    Named: a BROWSER naming a function the original had defined (ac-lib.sh's
#    helpers, req, post_reply, ac_try_open) RAN it - ac_die ended the run 1,
#    nothing launched; the port has no such functions and looks the name up.
resp 1 '{"ok":true}'; RV_ENV=(BROWSER=ac_die)
run_both open a.html --auto-open
RV_ENV=()
side_files "$OH" o; side_files "$NH" n
assert_eq "$O_RC $N_RC" "1 0" "row 5 named: a function name ran in the original only"
assert_eq "$(cat "$TMP/o.open")" "" "row 5 named: the original launched nothing"
assert_eq "$(shim_open)" "open [$URL]" "row 5 named: the port falls through to open"
reset_sides

# 6. reply: the text itself as the body (uncapped), `@<path>` or `-` spooled
#    through mktemp in TMPDIR and sent as @<spool> (cap 1048576 bytes, checked
#    before sending; empty is refused), the spool removed after the request;
#    an unreadable @file is cat's own line, exit 1, the spool LEFT (W9).
reply6() { printf 'para one\n\npara two\n' >"$H/home/data/r.md"; : >"$H/home/data/empty.md"; mkdir -p "$H/home/data/rdir"; }
both reply6
R_CKSUM="$(cksum <"$NH/home/data/r.md")"
resp 1 '{"ok":true}'
same reply a.html 'two  words * $USER' extra
assert_eq "$(shim_out)" "replied" "row 6: replied"
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[--data-binary]
[two  words * \$USER]
[http://127.0.0.1:8787/api/review/reply?$Q]" "row 6: the argv text, verbatim"
same reply a.html ''
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: an empty text"
same reply a.html
same reply a.html @
assert_eq "$(shim_err)" "ERROR: no such reply file: " "row 6: @ alone names an empty path"
same reply a.html @missing.md
same reply a.html @rdir
assert_eq "$(shim_err)" "ERROR: no such reply file: rdir" "row 6: a directory is no reply file"
resp 1 '{"ok":true}'
same reply a.html @r.md
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[--data-binary]
[@HOME/tmp/ac-review-reply.XXXXXX]
body $R_CKSUM
[http://127.0.0.1:8787/api/review/reply?$Q]" "row 6: the spool, holding the file's bytes"
assert_eq "$(shim_tmp)" "" "row 6: the spool removed"
resp 1 '{"ok":true}'; RV_STDIN="$NH/home/data/r.md"
same reply a.html -
RV_STDIN=/dev/null
assert_contains "$(shim_argv)" "body $R_CKSUM" "row 6: stdin spooled"
same reply a.html -
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: empty stdin"
assert_eq "$(shim_tmp)" "" "row 6: the empty spool removed"
same reply a.html @empty.md
caps() { head -c 1048576 /dev/zero | tr '\0' x >"$H/home/data/cap.md"; head -c 1048577 /dev/zero | tr '\0' x >"$H/home/data/cap1.md"; }
both caps
resp 1 '{"ok":true}'
same reply a.html @cap.md
assert_eq "$(calls)" 1 "row 6: exactly the cap is sent"
same reply a.html @cap1.md
assert_eq "$(shim_err)" "ERROR: reply is 1048577 bytes, over the dashboard's 1048576-byte cap (dashboard/app.ts REVIEW_REPLY_MAX_BYTES) - shorten it" "row 6: over the cap"
assert_eq "$(shim_argv)$(shim_tmp)" "" "row 6: nothing sent, the spool removed"
if [ "$(id -u)" != 0 ]; then
  unr() { printf 's\n' >"$H/home/data/unr.md"; chmod 000 "$H/home/data/unr.md"; }
  both unr
  same reply a.html @unr.md
  assert_eq "$(shim_err)" "cat: unr.md: Permission denied" "row 6 W9: cat's own line"
  assert_eq "$(shim_tmp)" "ac-review-reply.XXXXXX" "row 6 W9: the spool is left behind"
fi
RV_ENV=("TMPDIR=HOME/nodir")
same reply a.html @r.md
assert_eq "$(shim_err)" "mktemp: mkstemp failed on HOME/nodir/ac-review-reply.XXXXXX: No such file or directory" "row 6: mktemp's own line"
RV_ENV=()
resp 1 '{"ok":false,"error":"too big"}'
same reply a.html hi
assert_eq "$(shim_err)" "ERROR: reply refused: too big" "row 6: a refusal, no trailing space"
resp 1 'nope'
same reply a.html hi
resp 1 '' 7
same reply a.html @r.md
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh" "row 6: req's line alone"
assert_eq "$(shim_tmp)" "" "row 6: the spool removed after a failed request"
#    A TMPDIR that does not exist touches no request: curl's capture is a pipe.
resp 1 '{"ok":true}'; RV_ENV=("TMPDIR=HOME/nodir")
same open a.html
RV_ENV=()
assert_eq "$N_RC" 0 "row 6: a missing TMPDIR leaves open answering"
assert_eq "$(shim_out)" "$VIEW" "row 6: the viewer line under a missing TMPDIR"

# 7. end: POST ...&by=agent piped into `jq -e .ok` (W3 as row 4).
resp 1 '{"ok":true}'
same end a.html extra
assert_eq "$(shim_out)" "session ended" "row 7: ended"
assert_contains "$(shim_argv)" "[http://127.0.0.1:8787/api/review/end?$Q&by=agent]" "row 7: by=agent"
resp 1 '' 7
same end a.html
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh
ERROR: end failed" "row 7 W3: two ERROR lines"
resp 1 '{"ok":false}'
same end a.html
resp 1 '<x>'
same end a.html

# 8. poll options, in argv order: --after's value is neither validated nor
#    encoded (W7); --agent-reply POSTS when it is read (W6: before a later
#    option is refused; twice for two flags).
resp 1 '{"state":"ended","items":[]}'
same poll a.html --after 5 --after '1&x=2'
assert_contains "$(shim_argv)" "[http://127.0.0.1:8787/api/review/poll?$Q&after=1&x=2]" "row 8 W7: the cursor raw in the query"
resp 1 '{"ok":true}'
same poll a.html --agent-reply hi --bogus
assert_eq "$(shim_err)" "ERROR: unknown poll option: --bogus" "row 8 W6: refused"
assert_eq "$(calls)" 1 "row 8 W6: after the reply was posted"
resp 1 '{"ok":true}'; resp 2 '{"ok":true}'; resp 3 '{"state":"ended","items":[]}'
same poll a.html --agent-reply a --agent-reply b
assert_eq "$(calls)" 3 "row 8 W6: two replies, then the poll"
resp 1 '{"ok":false,"error":"ended"}'
same poll a.html --agent-reply a
assert_eq "$(shim_err)" "ERROR: reply refused: ended" "row 8: a refused reply ends the run before the poll"
same poll a.html extra
assert_eq "$(shim_err)$(shim_argv)" "ERROR: unknown poll option: extra" "row 8: a positional is an unknown option"
#    W5 (named): `${2:?}` - a flag with no value, or an empty one, ended the
#    original with bash's own `parameter null or not set` line, exit 1; the
#    port says `ERROR: <flag> needs a value`, exit 1, no request.
for args in "--after" "--after|" "--agent-reply" "--agent-reply|"; do
  IFS='|' read -r -a w <<<"$args"
  [ "${args%|}" = "$args" ] || w+=("")
  run_both poll a.html "${w[@]}"
  norm "$TMP/n.err" "$NH" >"$TMP/n.err2"; side_files "$OH" o; side_files "$NH" n
  assert_eq "$O_RC $N_RC" "1 1" "row 8 W5 [$args]: exit 1"
  assert_contains "$(cat "$TMP/o.err")" "2: parameter null or not set" "row 8 W5 [$args]: bash's own line on the original"
  assert_eq "$(shim_err)" "ERROR: ${w[0]} needs a value" "row 8 W5 [$args]: the port's line"
  assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw" "$TMP/o.argv" "$TMP/n.argv")" "" "row 8 W5 [$args]: nothing sent"
  reset_sides
done

# 9. poll bodies: GET .../poll?<q>&after=<n> in a loop with no sleep, until
#    the body has `items` and either `state` is ended or `.items | length` is
#    an integer > 0 (stdout: the body, exit 0), or `.pending // 0` is one (the
#    stderr hint, then the body, exit 0) - bash's integer grammar decides
#    (W8: `2.5`, `1.5`, `true`, a multi-value stream loop on, with the test
#    builtin's own noise on the original's stderr, not reproduced); a body
#    without `items` is `poll failed: <.error // .>`; jq's own failure ends the
#    run with its status.
resp 1 '{"state":"open","items":[{"n":1}]}\n\n\n'
same poll a.html
assert_eq "$(shim_out)" '{"state":"open","items":[{"n":1}]}' "row 9: an item, trailing LFs stripped"
assert_contains "$(shim_argv)" "[GET]
[http://127.0.0.1:8787/api/review/poll?$Q&after=0]" "row 9: the poll request"
resp 1 '{"state":"ended","items":[]}'
same poll a.html
resp 1 '{"state":"ended\\n","items":[]}'
same poll a.html
assert_eq "$(calls)" 1 "row 9: a state ending in LF reads ended"
resp 1 '{"items":"ab"}'
same poll a.html
resp 1 '{"items":{"a":1}}'
same poll a.html
resp 1 '{"items":-3}'
same poll a.html
resp 1 '{"items":null}'; resp 2 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 2 "row 9: a null items loops"
ROW_NOISE=1
resp 1 '{"items":2.5}'; resp 2 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 2 "row 9 W8: 2.5 is no integer - loop"
resp 1 '{"items":[],"pending":1.5}'; resp 2 '{"items":[],"pending":true}'; resp 3 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 3 "row 9 W8: a non-integer pending loops on"
resp 1 '{"items":[1]} {"items":[]}'; resp 2 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 2 "row 9 W8: a multi-value stream loops"
resp 1 '{"items":99999999999999999999}'; resp 2 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 2 "row 9 W8: past int64 is no integer"
ROW_NOISE=0
resp 1 '{"items":true}'
same poll a.html
assert_eq "$N_RC" 5 "row 9: jq's own status ends the run"
resp 1 '{"state":"ended","items":true}'
same poll a.html
assert_eq "$(shim_out)" "" "row 9: the length is read before the state decides"
resp 1 '{"state":"open","items":[],"pending":2}'
same poll a.html --after 7
assert_eq "$(shim_err)" "pending: 2 item(s) awaiting captain approval - stop and ask your chief; resume with: bin/ac-review.sh poll HOME/home/data/a.html --after 7" "row 9: the hint names the canonical path and the cursor"
assert_eq "$(shim_out)" '{"state":"open","items":[],"pending":2}' "row 9: then the body"
RV_CWD=home
resp 1 '{"items":[],"pending":"2"}'
same poll ./data/a.html --after '07'
RV_CWD=home/data
resp 1 '{"items":[],"pending":"\\n2"}'
same poll a.html
resp 1 '{"items":[],"pending":false}'; resp 2 '{"items":[],"pending":-1}'; resp 3 '{"items":[]}'; resp 4 '{"state":"ended","items":[]}'
same poll a.html
assert_eq "$(calls)" 4 "row 9: false, -1 and none are quiet rounds"
resp 1 '{"error":"forbidden"}'
same poll a.html
assert_eq "$(shim_err)" "ERROR: poll failed: forbidden" "row 9: a body without items"
resp 1 '[1]'
same poll a.html
resp 1 '{"items":[],"pending":0}'; resp 2 '' 7
same poll a.html
assert_eq "$(calls)" 2 "row 9: a transport failure on round 2"
resp 1 '{"items":[],"pending":0}'
same poll a.html
assert_eq "$(shim_err)" "ERROR: poll failed: " "row 9: an empty answer once the queue runs dry"

# 10. every child inherits the caller's stdin: the opener above, and curl
#     (a stub that reads it) - reply's argv form leaves stdin to curl.
cat >"$TMP/stub2-curl" <<'EOF'
#!/usr/bin/env bash
IFS= read -r l; printf 'curl stdin=[%s]\n' "$l" >>"$RESP_DIR/argv.log"; printf '{"ok":true}\n'
EOF
mkdir -p "$TMP/stub2"; mv "$TMP/stub2-curl" "$TMP/stub2/curl"; chmod +x "$TMP/stub2/curl"
RV_ENV=("PATH=$TMP/stub2:$TMP/op:$PATH"); RV_STDIN="$TMP/stdin5"
same reply a.html hi
RV_ENV=(); RV_STDIN=/dev/null
assert_eq "$(shim_argv)" "curl stdin=[fed]" "row 10: curl read the caller's stdin"

# --- the same against a REAL dashboard (rows 6 and 9) ------------------------
# HELD-CONSTANT as above, but the two side homes are siblings under one
# container (<container>/o for the oracle, <container>/n for the shim) so one
# dashboard on an ephemeral port serves both, the real curl, and the stored
# replies of each side's session compared too.
RD="$TMP/rd"; RO="$RD/o"; RN="$RD/n"
for h in "$RO" "$RN"; do mkdir -p "$h/data" "$h/state" "$h/config" "$h/tmp"; printf '<html><body><h1>r</h1></body></html>\n' >"$h/data/report.html"; printf 'First.\n\nSecond:\n- a\n\nThird.\n' >"$h/data/body.md"; done
DB="$BIN/ac-dashboard.sh"
trap 'AC_HOME="$RO" "$DB" stop >/dev/null 2>&1 || true; cleanup' EXIT
port=$((20000 + RANDOM % 2000))
while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
AC_HOME="$RO" "$DB" start --port "$port" >/dev/null
real_side() {  # real_side <bin> <home> <prefix> <args...> - HOME in an arg is that side's home
  local bin="$1" h="$2" p="$3" x; shift 3
  local a=()
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  ( cd "$h/data" && exec env -u BROWSER -u CDPATH LC_ALL=C AC_HOME="$h" AC_DASH_PORT="$port" TMPDIR="$h/tmp" "$bin/ac-review.sh" ${a[@]+"${a[@]}"} ) <"$RV_STDIN" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
stored() { [ ! -f "$1/data/report.html.session.json" ] || jq -c '[.state, (.replies // [] | map(.text))]' "$1/data/report.html.session.json"; }
real() {  # real <args...> - both sides against the live dashboard, byte-identical
  local o_rc=0 n_rc=0
  real_side "$obin" "$RO" o "$@" || o_rc=$?
  real_side "$BIN" "$RN" n "$@" || n_rc=$?
  norm "$TMP/o.raw" "$RO" >"$TMP/o.out"; norm "$TMP/o.err" "$RO" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$RN" >"$TMP/n.out"; norm "$TMP/n.err" "$RN" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "real exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "real stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "real stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
  assert_eq "$(stored "$RN")" "$(stored "$RO")" "real stored session for '$*'"
  assert_eq "$(ls -A "$RN/tmp")" "$(ls -A "$RO/tmp")" "real TMPDIR for '$*'"
}
real open report.html
assert_eq "$(shim_out)" "review open - captain viewer: http://127.0.0.1:$port/review?path=HOME&file=HOME%2Fdata%2Freport.html" "real: open"
real reply report.html "one line"
real reply report.html "@body.md"
RV_STDIN="$RN/data/body.md"
real reply report.html -
RV_STDIN=/dev/null
assert_eq "$(stored "$RN")" '["open",["one line","First.\n\nSecond:\n- a\n\nThird.","First.\n\nSecond:\n- a\n\nThird."]]' "real: three replies stored, newlines intact"
bigr() { head -c $((1024 * 1024 + 1)) /dev/zero | tr '\0' x >"$1/data/big.md"; }
bigr "$RO"; bigr "$RN"
real reply report.html "@big.md"
assert_contains "$(shim_err)" "REVIEW_REPLY_MAX_BYTES" "real: the cap refused before sending"
real reply report.html ""
#    poll --agent-reply on each side in turn: the reply lands before the poll
#    holds, and `end` releases it (bounded - a poll that never returns is
#    killed and fails the row).
real_poll() {  # real_poll <bin> <home> <prefix>
  local pid rc=0 i
  ( cd "$2/data" && exec env -u BROWSER -u CDPATH LC_ALL=C AC_HOME="$2" AC_DASH_PORT="$port" TMPDIR="$2/tmp" "$1/ac-review.sh" poll report.html --after 0 --agent-reply "@body.md" ) </dev/null >"$TMP/$3.raw" 2>"$TMP/$3.err" &
  pid=$!
  watch "$pid" 30
  for i in $(seq 1 80); do [ "$(jq '.replies | length' "$2/data/report.html.session.json")" = 4 ] && break; sleep 0.25; done
  real_side "$1" "$2" end end report.html
  wait "$pid" || rc=$?
  kill "$WD" 2>/dev/null || true; wait "$WD" 2>/dev/null || true
  [ "$rc" != 137 ] || fail "real poll hung on $2"
  printf '%s' "$rc" >"$TMP/$3.rc"
}
real_poll "$obin" "$RO" o
real_poll "$BIN" "$RN" n
assert_eq "$(cat "$TMP/n.rc") $(cat "$TMP/o.rc")" "0 0" "real poll: both released, exit 0"
assert_eq "$(cat "$TMP/n.err")$(cat "$TMP/o.err")" "" "real poll: nothing on stderr"
assert_eq "$(jq -c .state "$TMP/n.raw")" '"ended"' "real poll: released by end"
assert_eq "$(jq -c 'del(.. | .at?)' "$TMP/n.raw")" "$(jq -c 'del(.. | .at?)' "$TMP/o.raw")" "real poll: the released bodies agree"
assert_eq "$(stored "$RN")" "$(stored "$RO")" "real poll: the stored session"
real open report.html
assert_contains "$(stored "$RN")" '["open",' "real: open reopens an agent-ended session"
#    a HUMAN-ended session: open is refused verbatim (409), --reopen forces it
for h in "$RO" "$RN"; do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$port/api/review/end?path=$(jq -rn --arg v "$h" '$v|@uri')&file=$(jq -rn --arg v "$h/data/report.html" '$v|@uri')&by=human"
done
real open report.html
assert_contains "$(shim_err)" "ERROR: open refused: " "real: a human-ended session refuses open"
real open report.html --reopen
assert_eq "$(stored "$RN")" "$(stored "$RO")" "real: --reopen forces it"
real end report.html
real poll report.html --after 0
assert_contains "$(shim_out)" '"state":"ended"' "real: an ended session answers at once"
#    a file the review page does not render never gets a session: a share of
#    one would hand a guest its raw bytes
for h in "$RO" "$RN"; do printf 'k=v\n' >"$h/data/notes.txt"; done
real open notes.txt
assert_eq "$(shim_err)" "ERROR: open refused: forbidden " "real: a non-html, non-md artifact is refused"
assert_eq "$(ls "$RN/data" | /usr/bin/grep -c 'notes.txt.session')" 0 "real: no session file for it"

pass
