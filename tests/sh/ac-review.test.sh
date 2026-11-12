#!/usr/bin/env bash
# ac-review.test.sh - the review CLI (bin/ac-review.sh, spec in the header of
# src/review.ts) over a stubbed curl (a replay queue that logs its argv) for
# every verb, then over a REAL dashboard on an ephemeral port for reply and
# poll. The agent-facing contracts live in ac-review-auto-open, ac-review-poll
# and ac-review-reply.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || skip 'jq not installed'
command -v bun >/dev/null 2>&1 || skip 'bun not installed'

# One side root $H: a home at $H/home holding data/a.html, a TMPDIR at $H/tmp,
# a curl replay queue at $H/q seeded per row (a PATH curl stub logging every
# argv element and the cksum of an @<file> body), logging opener stubs on PATH
# (open, xdg-open, mybrowser - each writes its argv and the first line of its
# stdin to $H/open.log, prints to stdout and stderr, exits 3) and the real jq.
# Each run starts at $H/home/data (unless a row names another cwd) with stdin
# /dev/null (unless a row names a file), LC_ALL=C, and AC_DASH_PORT, BROWSER
# and CDPATH unset unless a row sets them. `HOME` in an argument or an env
# value is $H; stdout, stderr, the curl argv log, the opener log and the
# TMPDIR listing are read with $H spelled HOME - its jq @uri spelling too -
# and a mktemp spool's random suffix spelled XXXXXX.
H="$TMP/side"
seed() { mkdir -p "$H/home/data" "$H/home/config" "$H/home/state" "$H/tmp" "$H/q"; printf '<html></html>\n' >"$H/home/data/a.html"; }
seed

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
# PATHs that lack one required tool and keep what the entry needs to reach
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
norm() {  # norm <file> - the root and its @uri spelling as HOME, a spool suffix as XXXXXX
  local enc; enc="$(jq -rn --arg v "$H" '$v|@uri')"
  [ ! -e "$1" ] || LC_ALL=C sed -e "s#$enc#HOME#g" -e "s#$H#HOME#g" -e 's#ac-review-reply\.[A-Za-z0-9]\{6\}#ac-review-reply.XXXXXX#g' "$1"
}
reset_side() { rm -rf "$H/q" "$H/open.log" "$H/tmp"; mkdir -p "$H/q" "$H/tmp"; }
run() {  # run <args...> - sets rc; leaves stdout, stderr, the curl argv log, the opener log, the TMPDIR listing and the call count in $TMP/n.*, then empties the queue
  local x v pid
  local a=() e=(LC_ALL=C "PATH=$TMP/stub:$TMP/op:$PATH" "TMPDIR=$H/tmp" "RESP_DIR=$H/q" "OPEN_LOG=$H/open.log")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$H/home")
  for x in ${RV_ENV[@]+"${RV_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  # The poll loop has no bound of its own: a regression that loops must fail
  # the row (kill -9 -> 137), never hang the suite.
  ( cd "$H/$RV_CWD" && exec env -u AC_HOME -u AC_DASH_PORT -u BROWSER -u CDPATH "${e[@]}" "$BIN/ac-review.sh" ${a[@]+"${a[@]}"} ) <"$RV_STDIN" >"$TMP/n.raw" 2>"$TMP/n.err" &
  pid=$!
  watch "$pid" 20
  rc=0
  wait "$pid" || rc=$?
  kill "$WD" 2>/dev/null || true
  wait "$WD" 2>/dev/null || true
  [ "$rc" != 137 ] || fail "the run hung on '$*'"
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.err" >"$TMP/n.err2"
  norm "$H/q/argv.log" >"$TMP/n.argv"
  norm "$H/open.log" >"$TMP/n.open"
  ls -A "$H/tmp" >"$TMP/n.tmpls"; norm "$TMP/n.tmpls" >"$TMP/n.tmp"
  cat "$H/q/.count" >"$TMP/n.count" 2>/dev/null || printf 0 >"$TMP/n.count"
  reset_side
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
shim_argv() { cat "$TMP/n.argv"; }
shim_open() { cat "$TMP/n.open"; }
shim_tmp() { cat "$TMP/n.tmp"; }
resp() {  # resp <n> <stdout printf format> [<rc>] [<stderr format>] [<signal>] [<stdout format after stderr>] - curl call n's answer
  printf "$2" >"$H/q/$1.out"; printf '%s' "${3:-0}" >"$H/q/$1.rc"
  [ -z "${4:-}" ] || printf "$4" >"$H/q/$1.err"
  [ -z "${5:-}" ] || printf '%s' "$5" >"$H/q/$1.sig"
  [ -z "${6:-}" ] || printf "$6" >"$H/q/$1.out2"
}
calls() { cat "$TMP/n.count"; }
REQ="[-sS]
[--connect-timeout]
[2]
[--max-time]
[40]
[-X]"
Q="path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fa.html"
VIEW="review open - captain viewer: http://127.0.0.1:8787/review?$Q"

# 1. the prelude, in order: the tools before any argument, the verb, the file,
#    a regular file (a directory or a FIFO is no artifact), then the home; a
#    missing artifact is refused before the home is read.
for v in "" -h "bogus a.html"; do
  run $v
  assert_eq "$rc" 1 "row 1: '$v' exits 1"
  assert_eq "$(shim_err)" "ERROR: usage: ac-review.sh open|poll|reply|end|url <file>.html [options]" "row 1: no verb in '$v'"
done
run open
assert_eq "$(shim_err)" "ERROR: usage: ac-review.sh open <file>.html [options]" "row 1: no file"
run open missing.html
assert_eq "$(shim_err)" "ERROR: no such artifact: missing.html" "row 1: a missing artifact, as given"
run open HOME/home/data
assert_eq "$(shim_err)" "ERROR: no such artifact: HOME/home/data" "row 1: a directory is no artifact"
mkfifo "$H/home/data/f.html"
run url f.html
assert_eq "$(shim_err)" "ERROR: no such artifact: f.html" "row 1: a FIFO is no artifact (never opened)"
RV_ENV=("PATH=$TMP/nocurl")
run url a.html
assert_eq "$(shim_err)" "ERROR: required tool not found: curl" "row 1: curl off PATH"
run
assert_eq "$(shim_err)" "ERROR: required tool not found: curl" "row 1: ... before any argument is read"
RV_ENV=("PATH=$TMP/nojq")
run bogus
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "row 1: jq off PATH, before the verb"
RV_ENV=()
# A request over the SUFFICIENT minimal PATH: the curl stub, bash, dirname,
# basename, bun and jq, no `sh` - the capture's shell is /bin/sh by path
mkdir -p "$TMP/minpath"
for t in bash dirname basename bun jq cat; do ln -s "$(command -v "$t")" "$TMP/minpath/$t"; done  # cat: the curl stub's own need
ln -s "$TMP/stub/curl" "$TMP/minpath/curl"
resp 1 '{"ok":true}'; RV_ENV=("PATH=$TMP/minpath")
run open a.html
RV_ENV=()
assert_eq "$rc" 0 "row 1: a request needs no sh on PATH"
assert_contains "$(shim_out)" "review open - captain viewer:" "row 1: ... and answers"
# An executable the kernel refuses (no shebang) runs under bash: a jq wrapper
mkdir -p "$TMP/noshebang"
printf 'exec %s "$@"\n' "$(command -v jq)" >"$TMP/noshebang/jq"; chmod 755 "$TMP/noshebang/jq"
RV_ENV=("PATH=$TMP/noshebang:$TMP/stub:$TMP/op:$PATH")
run url a.html
RV_ENV=()
assert_eq "$rc" 0 "row 1: a shebang-less jq wrapper runs under bash"
assert_contains "$(shim_out)" "/review?path=" "row 1: ... and answers the url"
# ... with NO bash on PATH either: the entry started as `/bin/bash <entry>`,
# over the minimal PATH plus the wrapper
mkdir -p "$TMP/nobash"
for t in dirname basename bun cat; do ln -s "$(command -v "$t")" "$TMP/nobash/$t"; done
ln -s "$TMP/stub/curl" "$TMP/nobash/curl"; ln -s "$TMP/noshebang/jq" "$TMP/nobash/jq"
nb() { (cd "$H/$RV_CWD" && env -u AC_HOME AC_HOME="$H/home" LC_ALL=C PATH="$TMP/nobash" TMPDIR="$H/tmp" RESP_DIR="$H/q" OPEN_LOG="$H/open.log" AC_DASH_PORT=8787 /bin/bash "$BIN/ac-review.sh" url a.html) 2>&1; echo "rc=$?"; }
assert_contains "$(nb)" "rc=0" "row 1: the ENOEXEC fallback needs no bash on PATH"
HOMELESS=1
run url missing.html
assert_eq "$(shim_err)" "ERROR: no such artifact: missing.html" "row 1: the artifact before the home"
HOMELESS=0
#    An AC_HOME cd cannot enter: the entry's line alone, exit 1.
HOMELESS=1; RV_ENV=("AC_HOME=HOME/missing")
run url a.html
HOMELESS=0; RV_ENV=()
assert_eq "$rc:$(shim_out)" "1:" "row 1: an unenterable home exits 1 with nothing on stdout"
assert_eq "$(shim_err)" "ERROR: AC_HOME required: the review session belongs to a fleet home" "row 1: an unenterable home is the entry's line alone"

# 2. url: no request, `<base>/review?<q>` - the port from AC_DASH_PORT, an
#    EMPTY one falling to config/dash-port's first line [:space:]-trimmed,
#    neither validated; the artifact's directory physical, its basename kept
#    (a symlinked file keeps its link name); halves of q through jq @uri;
#    words after the file ignored.
run url a.html extra
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: the viewer url"
assert_eq "$(shim_argv)" "" "row 2: url makes no request"
RV_ENV=(AC_DASH_PORT=1)
run url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:1/review?$Q" "row 2: AC_DASH_PORT"
knob() { printf "$1" >"$H/home/config/dash-port"; }
knob ' 9999 \r\nsecond\n'
RV_ENV=(AC_DASH_PORT=)
run url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:9999/review?$Q" "row 2: an empty AC_DASH_PORT reads the trimmed knob"
RV_ENV=("AC_DASH_PORT=a b")
run url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:a b/review?$Q" "row 2: the port is never validated"
RV_ENV=()
rmknob() { rm -f "$H/home/config/dash-port"; }
rmknob
RV_ENV=(AC_DASH_PORT=)
run url a.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: an empty AC_DASH_PORT and no knob read 8787"
RV_ENV=()
for f in HOME/home/data/a.html ./a.html ../data/a.html; do
  run url "$f"
  assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: $f is made canonical"
done
RV_CWD=home
run url data/a.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?$Q" "row 2: a path relative to the caller's cwd"
RV_CWD=home/data
links() { mkdir -p "$H/home/real"; printf 'r\n' >"$H/home/real/r.html"; ln -s "$H/home/real" "$H/home/ldir"; ln -s a.html "$H/home/data/link.html"; }
links
run url ../ldir/r.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Freal%2Fr.html" "row 2: a symlinked directory resolves"
run url link.html
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Flink.html" "row 2: a symlinked file keeps its link name"
WEIRD="a b~!*'();:@&=+\$,?#[]$(printf '\303\251').md"
weird() { mkdir -p "$H/home/data/w"; printf 'w\n' >"$H/home/data/w/$WEIRD"; }
weird
run url "w/$WEIRD"
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fw%2Fa%20b~%21%2A%27%28%29%3B%3A%40%26%3D%2B%24%2C%3F%23%5B%5D%C3%A9.md" "row 2: jq's @uri keeps only A-Za-z0-9-_.~"
#    A file argument starting with `-` is an option to dirname and basename:
#    exit 1 (a file named `-` alone is an operand).
dashes() { mkdir -p "$H/home/data/-x"; printf 'd\n' >"$H/home/data/-x/a.html"; printf 'd\n' >"$H/home/data/-"; }
dashes
run url -x/a.html
assert_eq "$rc:$(shim_out)" "1:" "row 2: an option-shaped file is refused"
run url -
assert_eq "$(shim_out)" "http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2F-" "row 2: a file named -"
#    An exported CDPATH is never consulted: the file tested is the file named.
cdp() { mkdir -p "$H/cdp/sub" "$H/home/data/sub"; printf 'c\n' >"$H/cdp/sub/x.html"; printf 'h\n' >"$H/home/data/sub/x.html"; }
cdp
RV_ENV=("CDPATH=HOME/cdp")
run url sub/x.html
RV_ENV=()
assert_eq "$rc:$(shim_out)" "0:http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fsub%2Fx.html" "row 2: CDPATH does not redirect the artifact"
#    A name ending in LF is kept, never cut to its sibling's.
printf 'n\n' >"$H/home/data/n.html
"
run url "n.html
"
assert_eq "$rc:$(shim_out)" "0:http://127.0.0.1:8787/review?path=HOME%2Fhome&file=HOME%2Fhome%2Fdata%2Fn.html%0A" "row 2: a name ending in LF"

# 3. open: POST /api/review/end?<q>&reopen=1 - ok prints the viewer line; a
#    refusal names `.error`; curl's exit is classified; NULs are dropped from
#    the capture and trailing LFs stripped.
resp 1 '{"ok":true}\n\n'
run open a.html
assert_eq "$rc" 0 "row 3: open exits 0"
assert_eq "$(shim_out)" "$VIEW" "row 3: the viewer line"
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[http://127.0.0.1:8787/api/review/end?$Q&reopen=1]" "row 3: the curl argv"
resp 1 '{"ok":false,"error":"human ended"}'
run open a.html
assert_eq "$rc" 1 "row 3: a refusal exits 1"
assert_contains "$(shim_err)" "ERROR: open refused: human ended" "row 3: a refusal names .error"
resp 1 '{"ok":\000tr\000ue}\n'
run open a.html
assert_eq "$(shim_out)" "$VIEW" "row 3: NULs dropped from the capture"
resp 1 '' 7 'curl: (7) Failed to connect\n'
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh" "row 3: curl 7"
resp 1 '' 28
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard on port 8787 timed out - it may be overloaded, retry" "row 3: curl 28"
resp 1 '' 52
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard on port 8787 dropped the connection (a transport hiccup, not a dead process) - retry" "row 3: curl 52"
resp 1 '' 56
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard on port 8787 dropped the connection (a transport hiccup, not a dead process) - retry" "row 3: curl 56"
resp 1 'part' 6
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 6): part" "row 3: any other curl exit, with what it wrote"
resp 1 '' 0 '' TERM
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 143): " "row 3: a signalled curl is 128+signal"
resp 1 'half' 0 '' TERM
run open a.html
assert_eq "$(shim_err)" "ERROR: dashboard request on port 8787 failed (curl exit 143): half" "row 3: what it wrote before the signal"

# 4. open --reopen: the forced reopen - a refusal is `reopen failed`; options
#    are checked before any request.
resp 1 '{"ok":true}'
run open a.html --reopen
assert_eq "$(shim_out)" "$VIEW" "row 4: reopen"
assert_contains "$(shim_argv)" "[http://127.0.0.1:8787/api/review/end?$Q&reopen=1&force=1]" "row 4: the forced reopen"
resp 1 '{"ok":false}'
run open a.html --reopen
assert_eq "$rc:$(shim_err)" "1:ERROR: reopen failed" "row 4: a refusal"
resp 1 '<x>'
run open a.html --reopen
assert_eq "$rc" 1 "row 4: a body that is no JSON exits 1"
assert_contains "$(shim_err)" "ERROR: reopen failed" "row 4: ... as a refusal"
resp 1 '{"ok":true}'
run open a.html --reopen --reopen
assert_eq "$(calls)" 1 "row 4: one request"
run open a.html --auto-open --bogus
assert_eq "$(shim_err)" "ERROR: unknown open option: --bogus" "row 4: an unknown option"
assert_eq "$(shim_argv)$(shim_open)" "" "row 4: no request, no launch"

# 5. --auto-open, after the viewer line: $BROWSER when it resolves - a PATH
#    executable, a path, a PATH file that is not executable (resolved, nothing
#    launched) - else open, else xdg-open, else nothing; the opener's argv is
#    [<url>], its stdin the caller's, its output and status discarded.
URL="${VIEW#*viewer: }"
absop() { mkdir -p "$H/op-abs"; cp "$TMP/op/mybrowser" "$H/op-abs/mybrowser"; }
absop
printf 'fed\n' >"$TMP/stdin5"
ao() {  # ao <expected opener log> <env...> - open --auto-open answered ok, under the env given
  local want="$1"; shift
  resp 1 '{"ok":true}'; RV_ENV=("$@")
  run open a.html --auto-open
  RV_ENV=()
  assert_eq "$rc:$(shim_out)" "0:$VIEW" "row 5 [$*]: the viewer line first, the opener's status discarded"
  assert_eq "$(shim_open)" "$want" "row 5 [$*]: the opener"
}
ao "mybrowser [$URL]" BROWSER=mybrowser
ao "mybrowser [$URL]" BROWSER=HOME/op-abs/mybrowser
noshebang_op() { mkdir -p "$H/op-ns"; printf '{ printf "%%s" "${0##*/}"; for a in "$@"; do printf " [%%s]" "$a"; done; printf "\\n"; } >>"$OPEN_LOG"\n' >"$H/op-ns/nsbrowser"; chmod 755 "$H/op-ns/nsbrowser"; }
noshebang_op
ao "nsbrowser [$URL]" BROWSER=HOME/op-ns/nsbrowser
ao "" BROWSER=ac-review-noexec-opener "PATH=$TMP/opx:$TMP/stub:$TMP/op:$PATH"
ao "open [$URL]" BROWSER=ac-review-no-such-opener
ao "open [$URL]" BROWSER=/etc/passwd
RV_STDIN="$TMP/stdin5"
ao "open [$URL] stdin=[fed]" BROWSER=
RV_STDIN=/dev/null
ao "xdg-open [$URL]" "PATH=$TMP/stub:$TMP/xdg:$TMP/mirror"
ao "" "PATH=$TMP/stub:$TMP/mirror"
assert_eq "$(shim_err)" "" "row 5: no opener - silent"
resp 1 '' 7; RV_ENV=(BROWSER=mybrowser); run open a.html --auto-open
RV_ENV=()
assert_eq "$(shim_open)" "" "row 5: a failed request launches nothing"
#    A BROWSER spelled like a shell function name is a name like any other:
#    it resolves nothing and open launches.
ao "open [$URL]" BROWSER=ac_die

# 6. reply: the text itself as the body (uncapped), `@<path>` or `-` spooled
#    through mktemp in TMPDIR and sent as @<spool> (cap 1048576 bytes, checked
#    before sending; empty is refused), the spool removed after the request.
reply6() { printf 'para one\n\npara two\n' >"$H/home/data/r.md"; : >"$H/home/data/empty.md"; mkdir -p "$H/home/data/rdir"; }
reply6
R_CKSUM="$(cksum <"$H/home/data/r.md")"
resp 1 '{"ok":true}'
run reply a.html 'two  words * $USER' extra
assert_eq "$(shim_out)" "replied" "row 6: replied"
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[--data-binary]
[two  words * \$USER]
[http://127.0.0.1:8787/api/review/reply?$Q]" "row 6: the argv text, verbatim"
run reply a.html ''
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: an empty text"
run reply a.html
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: no text"
run reply a.html @
assert_eq "$(shim_err)" "ERROR: no such reply file: " "row 6: @ alone names an empty path"
run reply a.html @missing.md
assert_eq "$(shim_err)" "ERROR: no such reply file: missing.md" "row 6: a missing reply file"
run reply a.html @rdir
assert_eq "$(shim_err)" "ERROR: no such reply file: rdir" "row 6: a directory is no reply file"
resp 1 '{"ok":true}'
run reply a.html @r.md
assert_eq "$(shim_argv)" "call 1
$REQ
[POST]
[--data-binary]
[@HOME/tmp/ac-review-reply.XXXXXX]
body $R_CKSUM
[http://127.0.0.1:8787/api/review/reply?$Q]" "row 6: the spool, holding the file's bytes"
assert_eq "$(shim_tmp)" "" "row 6: the spool removed"
resp 1 '{"ok":true}'; RV_STDIN="$H/home/data/r.md"
run reply a.html -
RV_STDIN=/dev/null
assert_contains "$(shim_argv)" "body $R_CKSUM" "row 6: stdin spooled"
run reply a.html -
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: empty stdin"
assert_eq "$(shim_tmp)" "" "row 6: the empty spool removed"
run reply a.html @empty.md
assert_eq "$(shim_err)" "ERROR: reply text required" "row 6: an empty reply file"
caps() { head -c 1048576 /dev/zero | tr '\0' x >"$H/home/data/cap.md"; head -c 1048577 /dev/zero | tr '\0' x >"$H/home/data/cap1.md"; }
caps
resp 1 '{"ok":true}'
run reply a.html @cap.md
assert_eq "$(calls)" 1 "row 6: exactly the cap is sent"
run reply a.html @cap1.md
assert_eq "$(shim_err)" "ERROR: reply is 1048577 bytes, over the dashboard's 1048576-byte cap (dashboard/app.ts REVIEW_REPLY_MAX_BYTES) - shorten it" "row 6: over the cap"
assert_eq "$(shim_argv)$(shim_tmp)" "" "row 6: nothing sent, the spool removed"
RV_ENV=("TMPDIR=HOME/nodir")
run reply a.html @r.md
[ "$rc" -ne 0 ] || fail "row 6: a spool that cannot be made must end the run"
assert_eq "$(shim_argv)" "" "row 6: ... before any request"
RV_ENV=()
resp 1 '{"ok":false,"error":"too big"}'
run reply a.html hi
assert_eq "$(shim_err)" "ERROR: reply refused: too big" "row 6: a refusal, no trailing space"
resp 1 'nope'
run reply a.html hi
assert_eq "$rc" 1 "row 6: an answer that is no JSON exits 1"
assert_contains "$(shim_err)" "ERROR: reply refused:" "row 6: ... as a refusal"
resp 1 '' 7
run reply a.html @r.md
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh" "row 6: req's line alone"
assert_eq "$(shim_tmp)" "" "row 6: the spool removed after a failed request"
#    A TMPDIR that does not exist touches no request: curl's capture is a pipe.
resp 1 '{"ok":true}'; RV_ENV=("TMPDIR=HOME/nodir")
run open a.html
RV_ENV=()
assert_eq "$rc" 0 "row 6: a missing TMPDIR leaves open answering"
assert_eq "$(shim_out)" "$VIEW" "row 6: the viewer line under a missing TMPDIR"

# 7. end: POST ...&by=agent; a refusal is `end failed`.
resp 1 '{"ok":true}'
run end a.html extra
assert_eq "$rc:$(shim_out)" "0:session ended" "row 7: ended"
assert_contains "$(shim_argv)" "[http://127.0.0.1:8787/api/review/end?$Q&by=agent]" "row 7: by=agent"
resp 1 '{"ok":false}'
run end a.html
assert_eq "$rc:$(shim_err)" "1:ERROR: end failed" "row 7: a refusal"

# 8. poll options: a refused --agent-reply ends the run before the poll; any
#    other word is refused; a flag with no value, or an empty one, is refused
#    with no request.
resp 1 '{"ok":false,"error":"ended"}'
run poll a.html --agent-reply a
assert_eq "$(shim_err)" "ERROR: reply refused: ended" "row 8: a refused reply ends the run before the poll"
assert_eq "$(calls)" 1 "row 8: ... with no poll request"
run poll a.html extra
assert_eq "$(shim_err)$(shim_argv)" "ERROR: unknown poll option: extra" "row 8: a positional is an unknown option"
for args in "--after" "--after|" "--agent-reply" "--agent-reply|"; do
  IFS='|' read -r -a w <<<"$args"
  [ "${args%|}" = "$args" ] || w+=("")
  run poll a.html "${w[@]}"
  assert_eq "$rc:$(shim_err)" "1:ERROR: ${w[0]} needs a value" "row 8 [$args]: a flag needs a value"
  assert_eq "$(shim_out)$(shim_argv)" "" "row 8 [$args]: nothing sent"
done

# 9. poll bodies: GET .../poll?<q>&after=<n> in a loop with no sleep, until
#    the body has `items` and either `state` is ended or `.items | length` is
#    above 0 (stdout: the body, exit 0), or `.pending // 0` is (the stderr
#    hint, then the body, exit 0); a body without `items` is `poll failed:
#    <.error // .>`; jq's own failure ends the run.
resp 1 '{"state":"open","items":[{"n":1}]}\n\n\n'
run poll a.html
assert_eq "$rc" 0 "row 9: an item exits 0"
assert_eq "$(shim_out)" '{"state":"open","items":[{"n":1}]}' "row 9: an item, trailing LFs stripped"
assert_contains "$(shim_argv)" "[GET]
[http://127.0.0.1:8787/api/review/poll?$Q&after=0]" "row 9: the poll request"
resp 1 '{"state":"ended","items":[]}'
run poll a.html
assert_eq "$rc:$(shim_out)" '0:{"state":"ended","items":[]}' "row 9: an ended session answers with no item"
resp 1 '{"items":null}'; resp 2 '{"state":"ended","items":[]}'
run poll a.html
assert_eq "$(calls)" 2 "row 9: a null items loops"
resp 1 '{"items":true}'
run poll a.html
[ "$rc" -ne 0 ] || fail "row 9: an items jq cannot measure must end the run"
assert_eq "$(shim_out)" "" "row 9: ... before a byte is printed"
resp 1 '{"state":"ended","items":true}'
run poll a.html
assert_eq "$(shim_out)" "" "row 9: the length is read before the state decides"
resp 1 '{"state":"open","items":[],"pending":2}'
run poll a.html --after 7
assert_eq "$(shim_err)" "pending: 2 item(s) awaiting captain approval - stop and ask your chief; resume with: bin/ac-review.sh poll HOME/home/data/a.html --after 7" "row 9: the hint names the canonical path and the cursor"
assert_eq "$(shim_out)" '{"state":"open","items":[],"pending":2}' "row 9: then the body"
resp 1 '{"items":[],"pending":false}'; resp 2 '{"items":[],"pending":-1}'; resp 3 '{"items":[]}'; resp 4 '{"state":"ended","items":[]}'
run poll a.html
assert_eq "$(calls)" 4 "row 9: false, -1 and none are quiet rounds"
resp 1 '{"error":"forbidden"}'
run poll a.html
assert_eq "$rc:$(shim_err)" "1:ERROR: poll failed: forbidden" "row 9: a body without items"
resp 1 '{"items":[],"pending":0}'; resp 2 '' 7
run poll a.html
assert_eq "$(calls)" 2 "row 9: a transport failure on round 2"
assert_eq "$(shim_err)" "ERROR: dashboard unreachable on port 8787 - start it: bin/ac-dashboard.sh" "row 9: ... ends the run after its line"

# 10. every child inherits the caller's stdin: the opener above, and curl
#     (a stub that reads it) - reply's argv form leaves stdin to curl.
cat >"$TMP/stub2-curl" <<'EOF'
#!/usr/bin/env bash
IFS= read -r l; printf 'curl stdin=[%s]\n' "$l" >>"$RESP_DIR/argv.log"; printf '{"ok":true}\n'
EOF
mkdir -p "$TMP/stub2"; mv "$TMP/stub2-curl" "$TMP/stub2/curl"; chmod +x "$TMP/stub2/curl"
RV_ENV=("PATH=$TMP/stub2:$TMP/op:$PATH"); RV_STDIN="$TMP/stdin5"
run reply a.html hi
RV_ENV=(); RV_STDIN=/dev/null
assert_eq "$(shim_argv)" "curl stdin=[fed]" "row 10: curl read the caller's stdin"

# --- the same against a REAL dashboard (rows 6 and 9) ------------------------
# One home $RN, a dashboard on an ephemeral port serving it, the real curl; the
# session's stored replies are read back from its session file.
RN="$TMP/rd/n"
mkdir -p "$RN/data" "$RN/state" "$RN/config" "$RN/tmp"; printf '<html><body><h1>r</h1></body></html>\n' >"$RN/data/report.html"; printf 'First.\n\nSecond:\n- a\n\nThird.\n' >"$RN/data/body.md"
DB="$BIN/ac-dashboard.sh"
trap 'AC_HOME="$RN" "$DB" stop >/dev/null 2>&1 || true; cleanup' EXIT
port=$((20000 + RANDOM % 2000))
while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
AC_HOME="$RN" "$DB" start --port "$port" >/dev/null
rnorm() { LC_ALL=C sed -e "s#$(jq -rn --arg v "$RN" '$v|@uri')#HOME#g" -e "s#$RN#HOME#g" "$1"; }
real() {  # real <args...> - one run against the live dashboard; sets rc, stdout in $TMP/n.out, stderr in $TMP/n.err2
  rc=0
  ( cd "$RN/data" && exec env -u BROWSER -u CDPATH LC_ALL=C AC_HOME="$RN" AC_DASH_PORT="$port" TMPDIR="$RN/tmp" "$BIN/ac-review.sh" "$@" ) <"$RV_STDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || rc=$?
  rnorm "$TMP/n.raw" >"$TMP/n.out"; rnorm "$TMP/n.err" >"$TMP/n.err2"
  assert_eq "$(ls -A "$RN/tmp")" "" "real: no spool left after '$*'"
}
stored() { [ ! -f "$RN/data/report.html.session.json" ] || jq -c '[.state, (.replies // [] | map(.text))]' "$RN/data/report.html.session.json"; }
real open report.html
assert_eq "$(shim_out)" "review open - captain viewer: http://127.0.0.1:$port/review?path=HOME&file=HOME%2Fdata%2Freport.html" "real: open"
real reply report.html "one line"
real reply report.html "@body.md"
RV_STDIN="$RN/data/body.md"
real reply report.html -
RV_STDIN=/dev/null
assert_eq "$(stored)" '["open",["one line","First.\n\nSecond:\n- a\n\nThird.","First.\n\nSecond:\n- a\n\nThird."]]' "real: three replies stored, newlines intact"
head -c $((1024 * 1024 + 1)) /dev/zero | tr '\0' x >"$RN/data/big.md"
real reply report.html "@big.md"
assert_contains "$(shim_err)" "REVIEW_REPLY_MAX_BYTES" "real: the cap refused before sending"
real reply report.html ""
assert_eq "$rc:$(shim_err)" "1:ERROR: reply text required" "real: an empty reply"
#    poll --agent-reply: the reply lands before the poll holds, and `end`
#    releases it (bounded - a poll that never returns is killed and fails the
#    row).
( cd "$RN/data" && exec env -u BROWSER -u CDPATH LC_ALL=C AC_HOME="$RN" AC_DASH_PORT="$port" TMPDIR="$RN/tmp" "$BIN/ac-review.sh" poll report.html --after 0 --agent-reply "@body.md" ) </dev/null >"$TMP/p.raw" 2>"$TMP/p.err" &
poll_pid=$!
watch "$poll_pid" 30
for i in $(seq 1 80); do [ "$(jq '.replies | length' "$RN/data/report.html.session.json")" = 4 ] && break; sleep 0.25; done
real end report.html
poll_rc=0
wait "$poll_pid" || poll_rc=$?
kill "$WD" 2>/dev/null || true; wait "$WD" 2>/dev/null || true
[ "$poll_rc" != 137 ] || fail "real poll hung"
assert_eq "$poll_rc:$(cat "$TMP/p.err")" "0:" "real poll: released, exit 0, nothing on stderr"
assert_eq "$(jq -c .state "$TMP/p.raw")" '"ended"' "real poll: released by end"
assert_eq "$(stored | jq -c '.[1] | length')" 4 "real poll: its reply was stored first"
real open report.html
assert_contains "$(stored)" '["open",' "real: open reopens an agent-ended session"
#    a HUMAN-ended session: open is refused (409), --reopen forces it
curl -s -o /dev/null -X POST "http://127.0.0.1:$port/api/review/end?path=$(jq -rn --arg v "$RN" '$v|@uri')&file=$(jq -rn --arg v "$RN/data/report.html" '$v|@uri')&by=human"
real open report.html
assert_contains "$(shim_err)" "ERROR: open refused: " "real: a human-ended session refuses open"
real open report.html --reopen
assert_contains "$(stored)" '["open",' "real: --reopen forces it"
real end report.html
real poll report.html --after 0
assert_contains "$(shim_out)" '"state":"ended"' "real: an ended session answers at once"
#    a file the review page does not render never gets a session: a share of
#    one would hand a guest its raw bytes
printf 'k=v\n' >"$RN/data/notes.txt"
real open notes.txt
assert_contains "$(shim_err)" "ERROR: open refused: forbidden" "real: a non-html, non-md artifact is refused"
assert_eq "$(ls "$RN/data" | /usr/bin/grep -c 'notes.txt.session')" 0 "real: no session file for it"

pass
