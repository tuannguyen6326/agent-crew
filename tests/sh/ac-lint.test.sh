#!/usr/bin/env bash
# ac-lint.test.sh - the lint runner's FILE SELECTION: `--all` lints the whole
# owned set, the default lints only CHANGED files (tracked-diff + untracked) in
# that set, a clean tree lints nothing, plus arg handling. Hermetic: the lint
# works on the checkout its bin/ sits in physically, so a copy of the entry
# with bin/ac-bun.sh beside it and src/ linked under a throwaway git repo lints
# THAT repo. One check reads the real tree instead: its `shellcheck source=`
# directives. The last leg holds src/lint.ts to the frozen bash original.
# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v git >/dev/null || skip 'git not available'

repo="$TMP/lintrepo"
mkdir -p "$repo/bin"
cp "$BIN/ac-lint.sh" "$BIN/ac-bun.sh" "$repo/bin/"
ln -s "$ROOT/src" "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t
lint() { (cd "$repo" && ./bin/ac-lint.sh "$@"); }

# --- arg handling ---
grep -q 'Usage: ac-lint.sh' < <(lint -h) || fail "-h prints usage"
# marker-bounded (repo-deep-review F38): -h must reach the end of its own
# header, not stop mid-list on a stale line-range pin.
grep -q 'AC_LINT_ALLOW_MISSING' < <(lint -h) || fail "-h must print the full header, not a stale line-pinned prefix"
rc=0; lint bogus >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 "an unknown arg exits 2"

# A committed CLEAN baseline (the entry, ac-bun.sh, the src link + one good script).
printf '#!/usr/bin/env bash\ntrue\n' >"$repo/bin/good.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm base

# Clean tree: the default lints nothing.
out="$(lint 2>&1)"
case "$out" in *"no changed lint targets"*) ;; *) fail "clean tree -> no changed targets (got: $out)" ;; esac

# An UNTRACKED bad script (unclosed `if` -> bash -n fails) is a CHANGE the
# default catches.
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/bin/bad.sh"
rc=0; lint >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the default must catch a changed (untracked) syntax error"

# Once that bad file is COMMITTED and unchanged, the default no longer lints it
# (clean tree) - but --all still reaches it.
git -C "$repo" add -A
git -C "$repo" commit -qm bad
rc=0; lint >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 0 "the default skips an unchanged committed file (even a broken one)"
rc=0; lint --all >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--all lints the whole set, incl. the committed bad file"

# The shell tests and their stress harness live under tests/sh.
mkdir -p "$repo/tests/sh"
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/tests/sh/stress.sh"
out="$(lint 2>&1)" || true
assert_contains "$out" "syntax error: tests/sh/stress.sh" "a changed tests/sh/stress.sh is a lint target"
rm "$repo/tests/sh/stress.sh"
printf '#!/usr/bin/env bash\nif true; then\n' >"$repo/tests/sh/bad.test.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm badtest
out="$(lint --all 2>&1)" || true
assert_contains "$out" "syntax error: tests/sh/bad.test.sh" "--all reaches every tests/sh/*.test.sh"

# ac-lint runs shellcheck with -P SCRIPTDIR, so a `source=` directive in the
# REAL owned set is read against its script's own dir; one a move left stale
# stops being followed and lints SC1091. The count keeps a moved glob from
# passing vacuously.
n=0
while IFS=: read -r f _ d; do
  n=$((n + 1))
  t="${d#*source=}"
  [ -e "$ROOT/$(dirname "$f")/$t" ] || fail "$f: 'shellcheck source=$t' does not resolve from its dir"
done < <(cd "$ROOT" && grep -Hn '^# shellcheck source=' bin/*.sh tests/sh/*.test.sh tests/sh/stress.sh)
[ "$n" -gt 0 ] || fail "no shellcheck source= directive found in the owned set"

# --- differential: src/lint.ts against the frozen bash original ---------------
# DISPUTED: the implementation (tests/fixtures/ac-lint.sh as <side>/bin/ac-lint.sh vs src/lint.ts through the bin/ac-lint.sh shim)
# HELD-CONSTANT: two throwaway repos seeded alike ($LO for the oracle, $LN for the shim) - the same bin/ac-bun.sh copy and src link, the same files, commits and changes, the entry's own file committed on both sides - argv, PATH and env per row, cwd (the side root), stdin /dev/null, LC_ALL=C on both sides; exit status, stdout and stderr compared whole. A stub that prints its argv stands in for the real linter unless a row says otherwise.
LO="$TMP/lint-o"; LN="$TMP/lint-n"
lstub="$TMP/lint-stub"; nosc="$TMP/lint-nosc"; nobun="$TMP/lint-nobun"
mkdir -p "$lstub" "$nosc" "$nobun"
cat >"$lstub/shellcheck" <<'EOF'
#!/bin/sh
printf 'shellcheck:'; printf ' [%s]' "$@"; printf '\n'
exit "${SC_RC:-0}"
EOF
chmod +x "$lstub/shellcheck"
for t in bash git sort dirname awk sed cat; do
  ln -s "$(command -v "$t")" "$nosc/$t"; ln -s "$(command -v "$t")" "$nobun/$t"
done
ln -s "$(command -v bun)" "$nosc/bun"
LPATH="$lstub:$PATH"; LENV=()
lrun() {  # lrun <side root> <prefix> <args...> - the side's own bin/ac-lint.sh, run from the side root
  local h="$1" p="$2"; shift 2
  (cd "$h" && env LC_ALL=C PATH="$LPATH" ${LENV[@]+"${LENV[@]}"} ./bin/ac-lint.sh "$@") </dev/null >"$TMP/$p.out" 2>"$TMP/$p.err"
}
lsame() {  # lsame <args...> - oracle on $LO and shim on $LN answer byte-identically; L_RC is the shared status
  local o_rc=0 n_rc=0
  lrun "$LO" lo "$@" || o_rc=$?
  lrun "$LN" ln "$@" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "lint differential exit for '$*'"
  cmp -s "$TMP/lo.out" "$TMP/ln.out" || fail "lint differential stdout differs for '$*': $(diff "$TMP/lo.out" "$TMP/ln.out" | head -n 6)"
  cmp -s "$TMP/lo.err" "$TMP/ln.err" || fail "lint differential stderr differs for '$*': $(diff "$TMP/lo.err" "$TMP/ln.err" | head -n 6)"
  L_RC="$n_rc"
}
lout() { cat "$TMP/ln.out"; }
lerr() { cat "$TMP/ln.err"; }
lboth() { local h; for h in "$LO" "$LN"; do H="$h"; "$@"; done; }
lput() { mkdir -p "$H/$(dirname "$1")"; printf "$2" >"$H/$1"; }  # lput <path> <printf format>
lcommit() { git -C "$H" add -A; git -C "$H" commit -qm c; }
ldrop() { git -C "$H" rm -rqf "$@"; lcommit; }
lseed() {
  mkdir -p "$H/bin"; cp "$BIN/ac-bun.sh" "$H/bin/"; ln -s "$ROOT/src" "$H/src"
  git init -q "$H"; git -C "$H" config user.email t@t; git -C "$H" config user.name t
  lput bin/good.sh '#!/usr/bin/env bash\ntrue\n'
}
lboth lseed
cp "$ROOT/tests/fixtures/ac-lint.sh" "$LO/bin/ac-lint.sh"; cp "$BIN/ac-lint.sh" "$LN/bin/ac-lint.sh"
BAD='#!/usr/bin/env bash\nif true; then\n'
SC="shellcheck: [-x] [-P] [SCRIPTDIR]"
EMPTY_SET="ac-lint: no changed lint targets (use --all to lint everything)"

# 1. a fresh repo (no HEAD): the diff fails silently and every untracked
#    file in the set is linted
lsame
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 1: a fresh repo lints its untracked set"
lboth lcommit

# 2. -h / --help (extras ignored): exit 0, nothing on stderr, each side's OWN
#    spec header on stdout - the named divergence (USAGE HEADER): the shim's
#    header is a pointer, so the port prints src/lint.ts's
lusage() {
  local o_rc=0 n_rc=0 w
  lrun "$LO" lo "$@" || o_rc=$?
  lrun "$LN" ln "$@" || n_rc=$?
  assert_eq "$o_rc $n_rc" "0 0" "usage '$*': both exit 0"
  assert_eq "$(cat "$TMP/lo.err" "$TMP/ln.err")" "" "usage '$*': nothing on stderr"
  assert_eq "$(cat "$TMP/lo.out")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-lint.sh" | sed 's/^# \{0,1\}//')" "usage '$*': the original prints its bash header"
  assert_eq "$(cat "$TMP/ln.out")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/lint.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$*': the port prints the src/lint.ts spec header"
  for w in 'Usage: ac-lint.sh' AC_LINT_ALLOW_MISSING; do
    assert_contains "$(cat "$TMP/lo.out")" "$w" "usage '$*': the original's header names $w"
    assert_contains "$(cat "$TMP/ln.out")" "$w" "usage '$*': the port's header names $w"
  done
}
lusage -h
lusage --help
lusage -h bogus

# 3. an unknown FIRST argument: stderr, exit 2, nothing on stdout
for a in bogus -help --all=1 --ALL -; do
  lsame "$a"
  assert_eq "$L_RC" 2 "row 3: '$a' exits 2"
  assert_eq "$(lerr)" "ac-lint.sh: unknown arg: $a (use --all)" "row 3: '$a' is named"
  assert_eq "$(lout)" "" "row 3: '$a' prints nothing on stdout"
done

# 4. a clean committed tree lints nothing - an explicit "" too, and the line
#    never reaches the linter lookup
lsame
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: a clean tree"
lsame ""
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: an empty first argument is the default"
LPATH="$nosc"; lsame; LPATH="$lstub:$PATH"
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: no linter needed for an empty set"

# 5. --all: the whole set, ONE linter call over it, extra arguments ignored;
#    a failing linter fails the lint; no linter is a failure unless
#    AC_LINT_ALLOW_MISSING is exactly 1
lsame --all
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 5: --all"
lsame --all extra args
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 5: extras ignored"
LENV=(SC_RC=1); lsame --all; LENV=()
assert_eq "$L_RC" 1 "row 5: the linter's failure is the lint's"
LPATH="$nosc"
lsame --all
assert_eq "$L_RC $(lerr)" "1 shellcheck not found (install it, or set AC_LINT_ALLOW_MISSING=1)" "row 5: no linter"
for v in 1 yes "" " 1"; do
  LENV=("AC_LINT_ALLOW_MISSING=$v"); lsame --all
  [ "$v" = 1 ] && want=0 || want=1
  assert_eq "$L_RC" "$want" "row 5: AC_LINT_ALLOW_MISSING='$v'"
done
LENV=(); LPATH="$lstub:$PATH"

# 6. an untracked broken script: bash's own diagnostic, then the lint's line;
#    the linter still runs over the changed set
lboth lput bin/bad.sh "$BAD"
lsame
assert_eq "$L_RC" 1 "row 6: a syntax error fails the lint"
assert_eq "$(lerr)" "bin/bad.sh: line 3: syntax error: unexpected end of file
syntax error: bin/bad.sh" "row 6: the child's line precedes the lint's"
assert_eq "$(lout)" "$SC [bin/bad.sh]" "row 6: the changed set only"

# 7. committed and unchanged: the default passes it, --all does not
lboth lcommit
lsame
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 7: an unchanged broken file is not linted by default"
lsame --all
assert_eq "$L_RC" 1 "row 7: --all reaches it"
lboth ldrop bin/bad.sh

# 8. the set filter is the original's `case`: `*` crosses `/` (bin/x/y.sh,
#    tests/sh/sub/b.test.sh and a file under a remote-* directory are IN by
#    default - the dossier's "a subdirectory does not match" is refuted), the
#    rest is ignored; --all's globs stay one level deep, and a DIRECTORY that
#    matches remote-* is handed to bash -n and reported (W3)
lfilter() {
  local f
  for f in README.md bin/x/y.sh bin/x.txt tests/sh/helper.sh tests/sh/stress.sh tests/sh/a.test.sh tests/sh/sub/b.test.sh \
    docs/examples/slack-remote/remote-x docs/examples/slack-remote/README.md docs/examples/slack-remote/remote-d/y; do
    lput "$f" "$BAD"
  done
}
lboth lfilter
lsame
assert_eq "$L_RC $(lout)" "1 $SC [bin/x/y.sh] [docs/examples/slack-remote/remote-d/y] [docs/examples/slack-remote/remote-x] [tests/sh/a.test.sh] [tests/sh/stress.sh] [tests/sh/sub/b.test.sh]" "row 8: the changed set filter"
assert_eq "$(lerr | grep '^syntax error:')" "syntax error: bin/x/y.sh
syntax error: docs/examples/slack-remote/remote-d/y
syntax error: docs/examples/slack-remote/remote-x
syntax error: tests/sh/a.test.sh
syntax error: tests/sh/stress.sh
syntax error: tests/sh/sub/b.test.sh" "row 8: one line per broken file, in order"
lsame --all
assert_eq "$L_RC $(lout)" "1 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh] [tests/sh/a.test.sh] [tests/sh/stress.sh] [docs/examples/slack-remote/remote-d] [docs/examples/slack-remote/remote-x]" "row 8: --all in pattern order"
assert_contains "$(lerr)" "syntax error: docs/examples/slack-remote/remote-d" "row 8: a directory is a 'syntax error' (W3)"
lclean() { rm -rf "$H/README.md" "$H/bin/x" "$H/bin/x.txt" "$H/tests" "$H/docs"; }
lboth lclean

# 9. a staged-only edit and a staged rename are linted under their (new)
#    names; a deleted tracked file is not
lstage() {
  lput bin/gone.sh '#!/usr/bin/env bash\ntrue\n'; lput bin/old.sh '#!/usr/bin/env bash\ntrue\n'; lcommit
  lput bin/good.sh "$BAD"; git -C "$H" add bin/good.sh
  rm "$H/bin/gone.sh"
  git -C "$H" mv bin/old.sh bin/new.sh
}
lboth lstage
lsame
assert_eq "$L_RC $(lout)" "1 $SC [bin/good.sh] [bin/new.sh]" "row 9: staged edit and rename"
assert_eq "$(lerr | grep -c '^syntax error:')" 1 "row 9: only the staged edit is broken"
lreset() { git -C "$H" reset -q --hard; git -C "$H" clean -qfd; }
lboth lreset
lboth ldrop bin/gone.sh bin/old.sh
# a tracked script turned into a dangling symlink: git lists the change, but
# the name exists no more and is not linted
ldangle() { rm "$H/bin/good.sh"; ln -s nowhere "$H/bin/good.sh"; }
lboth ldangle
lsame
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 9: a dangling symlink is not linted"
lboth lreset

# 10. W2: a dot-named script is in the `case` set (linted when changed) but
#     never globbed by --all
lboth lput bin/.hidden.sh "$BAD"
lsame
assert_eq "$L_RC $(lout)" "1 $SC [bin/.hidden.sh]" "row 10: a changed hidden script is linted"
lboth lcommit
lsame --all
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 10: --all never globs it (W2)"
lboth ldrop bin/.hidden.sh

# 11. W1: git QUOTES a non-ASCII path (core.quotePath pinned true in the
#     side repos), the quoted spelling names no file and the change is never
#     linted by default - untracked or committed-and-modified; --all globs it
E9="$(printf '\303\251')"
lqp() { git -C "$H" config core.quotePath true; lput "bin/$E9.sh" "$BAD"; }
lboth lqp
lsame
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 11: an untracked non-ASCII name is skipped (W1)"
lsame --all
assert_contains "$(lerr)" "syntax error: bin/$E9.sh" "row 11: --all lints it"
lboth lcommit
lmod() { lput "bin/$E9.sh" "$BAD\n"; }
lboth lmod
lsame
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 11: a modified non-ASCII name is skipped (W1)"
lboth ldrop "bin/$E9.sh"

# 12. a name with a space is one file
lboth lput "bin/a b.sh" "$BAD"
lsame
assert_eq "$L_RC $(lout)" "1 $SC [bin/a b.sh]" "row 12: a spaced name"
assert_contains "$(lerr)" "syntax error: bin/a b.sh" "row 12: named whole"
rm -f "$LO/bin/a b.sh" "$LN/bin/a b.sh"

# 13. W3: an unreadable script is a 'syntax error' too (bash's own line first)
if [ "$(id -u)" != 0 ]; then
  lunr() { lput bin/unr.sh '#!/usr/bin/env bash\ntrue\n'; chmod 000 "$H/bin/unr.sh"; }
  lboth lunr
  lsame
  assert_eq "$L_RC $(lout)" "1 $SC [bin/unr.sh]" "row 13: an unreadable changed file"
  assert_contains "$(lerr)" "syntax error: bin/unr.sh" "row 13: reported as a syntax error (W3)"
  rm -f "$LO/bin/unr.sh" "$LN/bin/unr.sh"
fi

# 14. CRLF line ends and a raw non-UTF-8 byte in a string pass bash -n
lboth lput bin/crlf.sh '#!/usr/bin/env bash\r\ntrue\r\n'
lboth lput bin/raw.sh '#!/usr/bin/env bash\nx="\351"\n'
lsame
assert_eq "$L_RC $(lout)" "0 $SC [bin/crlf.sh] [bin/raw.sh]" "row 14: CRLF and a raw byte"
rm -f "$LO/bin/crlf.sh" "$LO/bin/raw.sh" "$LN/bin/crlf.sh" "$LN/bin/raw.sh"

# 15. BYTE order for both selections (the oracle under LC_ALL=C; under a
#     UTF-8 locale the original's sort and glob follow collation - named)
lorder() { local n; for n in ac_x AC Zeta ac-x ac.x a10 a2; do lput "bin/$n.sh" '#!/usr/bin/env bash\ntrue\n'; done; }
lboth lorder
lsame
assert_eq "$L_RC $(lout)" "0 $SC [bin/AC.sh] [bin/Zeta.sh] [bin/a10.sh] [bin/a2.sh] [bin/ac-x.sh] [bin/ac.x.sh] [bin/ac_x.sh]" "row 15: the changed set in byte order"
lboth lcommit
lsame --all
assert_eq "$L_RC $(lout)" "0 $SC [bin/AC.sh] [bin/Zeta.sh] [bin/a10.sh] [bin/a2.sh] [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/ac-x.sh] [bin/ac.x.sh] [bin/ac_x.sh] [bin/good.sh]" "row 15: the glob in byte order"
lboth ldrop bin/ac_x.sh bin/AC.sh bin/Zeta.sh bin/ac-x.sh bin/ac.x.sh bin/a10.sh bin/a2.sh

# 16. not a git repo: the default is the whole set
loff() { mv "$H/.git" "$H/.git.off"; lput bin/bad.sh "$BAD"; }
lboth loff
LENV=("GIT_CEILING_DIRECTORIES=$TMP"); lsame; LENV=()
assert_eq "$L_RC $(lout)" "1 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/bad.sh] [bin/good.sh]" "row 16: outside a repo"
lon() { rm "$H/bin/bad.sh"; mv "$H/.git.off" "$H/.git"; }
lboth lon

# 17. the real linter's own report passes through verbatim
if command -v shellcheck >/dev/null 2>&1; then
  realsc="$TMP/lint-realsc"; mkdir -p "$realsc"; ln -s "$(command -v shellcheck)" "$realsc/shellcheck"
  lboth lput bin/warn.sh '#!/usr/bin/env bash\necho $1\n'
  LPATH="$realsc:$nosc"; lsame; LPATH="$lstub:$PATH"
  assert_eq "$L_RC" 1 "row 17: a finding fails the lint"
  assert_contains "$(lout)" "SC2086" "row 17: the report on stdout"
  rm -f "$LO/bin/warn.sh" "$LN/bin/warn.sh"
fi

# 18. a PATH linter that is not executable is FOUND, as bash's `command -v`
#     finds it, and fails to run (126) - exit 1 even under
#     AC_LINT_ALLOW_MISSING=1; the shell's own `Permission denied` line is not
#     reproduced (named: SHELL-OWN STDERR)
nxsc="$TMP/lint-nxsc"; mkdir -p "$nxsc"; printf '#!/bin/sh\nexit 0\n' >"$nxsc/shellcheck"; chmod 644 "$nxsc/shellcheck"
LPATH="$nxsc:$nosc"; LENV=(AC_LINT_ALLOW_MISSING=1)
o_rc=0; lrun "$LO" lo --all || o_rc=$?
n_rc=0; lrun "$LN" ln --all || n_rc=$?
LPATH="$lstub:$PATH"; LENV=()
assert_eq "$o_rc $n_rc" "1 1" "row 18: a found linter that cannot run fails the lint"
cmp -s "$TMP/lo.out" "$TMP/ln.out" || fail "row 18: stdout differs"
assert_contains "$(cat "$TMP/lo.err")" "Permission denied" "row 18: the shell's own line on the original"
assert_eq "$(cat "$TMP/ln.err")" "" "row 18: not reproduced (named)"

# 19. ROOT, a named divergence: through a fleet home's
#     symlinked bin/ the original cd's to the LOGICAL parent - the home, no
#     repo - and lints the whole set through the link; the port lints the
#     checkout the bin/ sits in physically, as bin/ac-bun.sh resolves it
lboth lput bin/bad.sh "$BAD"; lboth lcommit
HO="$TMP/lint-home-o"; HN="$TMP/lint-home-n"; mkdir -p "$HO" "$HN"; ln -s "$LO/bin" "$HO/bin"; ln -s "$LN/bin" "$HN/bin"
LENV=("GIT_CEILING_DIRECTORIES=$TMP")
o_rc=0; lrun "$HO" lo || o_rc=$?
n_rc=0; lrun "$HN" ln || n_rc=$?
LENV=()
assert_eq "$o_rc" 1 "row 19: the original lints the home's view of the set"
assert_contains "$(cat "$TMP/lo.err")" "syntax error: bin/bad.sh" "row 19: the committed broken file through the link"
assert_eq "$n_rc $(cat "$TMP/ln.out")" "0 $EMPTY_SET" "row 19: the port lints the clean physical checkout"
lboth ldrop bin/bad.sh

# 20. bun, a named divergence: the original needs none; the shim refuses
LPATH="$lstub:$nobun"
o_rc=0; lrun "$LO" lo --all || o_rc=$?
n_rc=0; lrun "$LN" ln --all || n_rc=$?
LPATH="$lstub:$PATH"
assert_eq "$o_rc" 0 "row 20: the original lints without bun"
assert_eq "$n_rc $(cat "$TMP/ln.err")" "1 ERROR: required tool not found: bun" "row 20: the shim refuses without bun"

# Named and not pinned here (the header lists them): under a UTF-8 locale the
# original's `sort -u` and globs follow collation where the port keeps byte
# order (this leg runs LC_ALL=C); a non-UTF-8 argument reaches the port as
# U+FFFD.

pass
