#!/usr/bin/env bash
# ac-lint.test.sh - the lint runner's FILE SELECTION: `--all` lints the whole
# owned set, the default lints only CHANGED files (tracked-diff + untracked) in
# that set, a clean tree lints nothing, plus arg handling. Hermetic: the lint
# works on the checkout its bin/ sits in physically, so a copy of the entry
# with bin/ac-bun.sh beside it and src/ linked under a throwaway git repo lints
# THAT repo. One check reads the real tree instead: its `shellcheck source=`
# directives.
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

# --- the selection and the checks, row by row ---------------------------------
# One throwaway repo ($H) holding bin/ac-lint.sh, bin/ac-bun.sh and the src
# link, the entry's own file committed; each run starts at $H with stdin
# /dev/null and LC_ALL=C. A stub that prints its argv stands in for the real
# linter unless a row says otherwise.
H="$TMP/lint-n"
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
LPATH="$lstub:$PATH"; LENV=(); LROOT="$H"
lrun() {  # lrun <args...> - $LROOT's bin/ac-lint.sh, run from $LROOT; sets L_RC
  L_RC=0
  (cd "$LROOT" && env LC_ALL=C PATH="$LPATH" ${LENV[@]+"${LENV[@]}"} ./bin/ac-lint.sh "$@") </dev/null >"$TMP/ln.out" 2>"$TMP/ln.err" || L_RC=$?
}
lout() { cat "$TMP/ln.out"; }
lerr() { cat "$TMP/ln.err"; }
lput() { mkdir -p "$H/$(dirname "$1")"; printf "$2" >"$H/$1"; }  # lput <path> <printf format>
lcommit() { git -C "$H" add -A; git -C "$H" commit -qm c; }
ldrop() { git -C "$H" rm -rqf "$@"; lcommit; }
mkdir -p "$H/bin"; cp "$BIN/ac-bun.sh" "$BIN/ac-lint.sh" "$H/bin/"; ln -s "$ROOT/src" "$H/src"
git init -q "$H"; git -C "$H" config user.email t@t; git -C "$H" config user.name t
lput bin/good.sh '#!/usr/bin/env bash\ntrue\n'
BAD='#!/usr/bin/env bash\nif true; then\n'
SC="shellcheck: [-x] [-P] [SCRIPTDIR]"
EMPTY_SET="ac-lint: no changed lint targets (use --all to lint everything)"

# 1. a fresh repo (no HEAD): the diff fails silently and every untracked
#    file in the set is linted
lrun
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 1: a fresh repo lints its untracked set"
lcommit

# 2. -h / --help (extras ignored): exit 0, nothing on stderr, the
#    src/lint.ts spec header on stdout
for a in -h --help '-h bogus'; do
  # shellcheck disable=SC2086
  lrun $a
  assert_eq "$L_RC:$(lerr)" "0:" "usage '$a': exit 0, nothing on stderr"
  assert_eq "$(lout)" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/lint.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$a': the src/lint.ts spec header"
done

# 3. an unknown FIRST argument: stderr, exit 2, nothing on stdout
for a in bogus -help --all=1 --ALL -; do
  lrun "$a"
  assert_eq "$L_RC" 2 "row 3: '$a' exits 2"
  assert_eq "$(lerr)" "ac-lint.sh: unknown arg: $a (use --all)" "row 3: '$a' is named"
  assert_eq "$(lout)" "" "row 3: '$a' prints nothing on stdout"
done

# 4. a clean committed tree lints nothing - an explicit "" too, and the line
#    never reaches the linter lookup
lrun
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: a clean tree"
lrun ""
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: an empty first argument is the default"
LPATH="$nosc"; lrun; LPATH="$lstub:$PATH"
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 4: no linter needed for an empty set"

# 5. --all: the whole set, ONE linter call over it, extra arguments ignored;
#    a failing linter fails the lint; no linter is a failure unless
#    AC_LINT_ALLOW_MISSING is exactly 1
lrun --all
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 5: --all"
lrun --all extra args
assert_eq "$L_RC $(lout)" "0 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh]" "row 5: extras ignored"
LENV=(SC_RC=1); lrun --all; LENV=()
assert_eq "$L_RC" 1 "row 5: the linter's failure is the lint's"
LPATH="$nosc"
lrun --all
assert_eq "$L_RC $(lerr)" "1 shellcheck not found (install it, or set AC_LINT_ALLOW_MISSING=1)" "row 5: no linter"
for v in 1 yes "" " 1"; do
  LENV=("AC_LINT_ALLOW_MISSING=$v"); lrun --all
  [ "$v" = 1 ] && want=0 || want=1
  assert_eq "$L_RC" "$want" "row 5: AC_LINT_ALLOW_MISSING='$v'"
done
LENV=(); LPATH="$lstub:$PATH"

# 6. an untracked broken script: bash's own diagnostic, then the lint's line;
#    the linter still runs over the changed set
lput bin/bad.sh "$BAD"
lrun
assert_eq "$L_RC" 1 "row 6: a syntax error fails the lint"
assert_eq "$(lerr | tail -n 1)" "syntax error: bin/bad.sh" "row 6: the lint's line closes stderr"
assert_eq "$(lerr | wc -l | tr -d ' ')" 2 "row 6: ...after the child's own line"
assert_eq "$(lout)" "$SC [bin/bad.sh]" "row 6: the changed set only"
rm "$H/bin/bad.sh"

# 8. the set filter: `*` crosses `/` (bin/x/y.sh, tests/sh/sub/b.test.sh and a
#    file under a remote-* directory are IN by default), the rest is ignored;
#    --all's globs stay one level deep
for f in README.md bin/x/y.sh bin/x.txt tests/sh/helper.sh tests/sh/stress.sh tests/sh/a.test.sh tests/sh/sub/b.test.sh \
  docs/examples/slack-remote/remote-x docs/examples/slack-remote/README.md docs/examples/slack-remote/remote-d/y; do
  lput "$f" "$BAD"
done
lrun
assert_eq "$L_RC $(lout)" "1 $SC [bin/x/y.sh] [docs/examples/slack-remote/remote-d/y] [docs/examples/slack-remote/remote-x] [tests/sh/a.test.sh] [tests/sh/stress.sh] [tests/sh/sub/b.test.sh]" "row 8: the changed set filter"
assert_eq "$(lerr | grep '^syntax error:')" "syntax error: bin/x/y.sh
syntax error: docs/examples/slack-remote/remote-d/y
syntax error: docs/examples/slack-remote/remote-x
syntax error: tests/sh/a.test.sh
syntax error: tests/sh/stress.sh
syntax error: tests/sh/sub/b.test.sh" "row 8: one line per broken file, in order"
rm -rf "$H/docs/examples/slack-remote/remote-d"
lrun --all
assert_eq "$L_RC $(lout)" "1 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/good.sh] [tests/sh/a.test.sh] [tests/sh/stress.sh] [docs/examples/slack-remote/remote-x]" "row 8: --all in pattern order"
rm -rf "$H/README.md" "$H/bin/x" "$H/bin/x.txt" "$H/tests" "$H/docs"

# 9. a staged-only edit and a staged rename are linted under their (new)
#    names; a deleted tracked file is not
lput bin/gone.sh '#!/usr/bin/env bash\ntrue\n'; lput bin/old.sh '#!/usr/bin/env bash\ntrue\n'; lcommit
lput bin/good.sh "$BAD"; git -C "$H" add bin/good.sh
rm "$H/bin/gone.sh"
git -C "$H" mv bin/old.sh bin/new.sh
lrun
assert_eq "$L_RC $(lout)" "1 $SC [bin/good.sh] [bin/new.sh]" "row 9: staged edit and rename"
assert_eq "$(lerr | grep -c '^syntax error:')" 1 "row 9: only the staged edit is broken"
lreset() { git -C "$H" reset -q --hard; git -C "$H" clean -qfd; }
lreset
ldrop bin/gone.sh bin/old.sh
# a tracked script turned into a dangling symlink: git lists the change, but
# the name exists no more and is not linted
rm "$H/bin/good.sh"; ln -s nowhere "$H/bin/good.sh"
lrun
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 9: a dangling symlink is not linted"
lreset

# 10. a dot-named script is in the set: linted when changed
lput bin/.hidden.sh "$BAD"
lrun
assert_eq "$L_RC $(lout)" "1 $SC [bin/.hidden.sh]" "row 10: a changed hidden script is linted"
rm "$H/bin/.hidden.sh"

# 11. --all globs a non-ASCII name
E9="$(printf '\303\251')"
lput "bin/$E9.sh" "$BAD"
lrun --all
assert_eq "$L_RC" 1 "row 11: --all fails on the broken non-ASCII name"
assert_contains "$(lerr)" "syntax error: bin/$E9.sh" "row 11: ...naming it"
rm "$H/bin/$E9.sh"

# 12. a name with a space is one file
lput "bin/a b.sh" "$BAD"
lrun
assert_eq "$L_RC $(lout)" "1 $SC [bin/a b.sh]" "row 12: a spaced name"
assert_contains "$(lerr)" "syntax error: bin/a b.sh" "row 12: named whole"
rm -f "$H/bin/a b.sh"

# 14. CRLF line ends and a raw non-UTF-8 byte in a string pass bash -n
lput bin/crlf.sh '#!/usr/bin/env bash\r\ntrue\r\n'
lput bin/raw.sh '#!/usr/bin/env bash\nx="\351"\n'
lrun
assert_eq "$L_RC $(lout)" "0 $SC [bin/crlf.sh] [bin/raw.sh]" "row 14: CRLF and a raw byte"
rm -f "$H/bin/crlf.sh" "$H/bin/raw.sh"

# 15. BYTE order for both selections
for n in ac_x AC Zeta ac-x ac.x a10 a2; do lput "bin/$n.sh" '#!/usr/bin/env bash\ntrue\n'; done
lrun
assert_eq "$L_RC $(lout)" "0 $SC [bin/AC.sh] [bin/Zeta.sh] [bin/a10.sh] [bin/a2.sh] [bin/ac-x.sh] [bin/ac.x.sh] [bin/ac_x.sh]" "row 15: the changed set in byte order"
lcommit
lrun --all
assert_eq "$L_RC $(lout)" "0 $SC [bin/AC.sh] [bin/Zeta.sh] [bin/a10.sh] [bin/a2.sh] [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/ac-x.sh] [bin/ac.x.sh] [bin/ac_x.sh] [bin/good.sh]" "row 15: the glob in byte order"
ldrop bin/ac_x.sh bin/AC.sh bin/Zeta.sh bin/ac-x.sh bin/ac.x.sh bin/a10.sh bin/a2.sh

# 16. not a git repo: the default is the whole set
mv "$H/.git" "$H/.git.off"; lput bin/bad.sh "$BAD"
LENV=("GIT_CEILING_DIRECTORIES=$TMP"); lrun; LENV=()
assert_eq "$L_RC $(lout)" "1 $SC [bin/ac-bun.sh] [bin/ac-lint.sh] [bin/bad.sh] [bin/good.sh]" "row 16: outside a repo"
rm "$H/bin/bad.sh"; mv "$H/.git.off" "$H/.git"

# 17. the real linter's own report passes through verbatim
if command -v shellcheck >/dev/null 2>&1; then
  realsc="$TMP/lint-realsc"; mkdir -p "$realsc"; ln -s "$(command -v shellcheck)" "$realsc/shellcheck"
  lput bin/warn.sh '#!/usr/bin/env bash\necho $1\n'
  LPATH="$realsc:$nosc"; lrun; LPATH="$lstub:$PATH"
  assert_eq "$L_RC" 1 "row 17: a finding fails the lint"
  assert_contains "$(lout)" "SC2086" "row 17: the report on stdout"
  rm -f "$H/bin/warn.sh"
fi

# 18. a PATH linter that is not executable is FOUND, as bash's `command -v`
#     finds it, and fails to run - exit 1 even under AC_LINT_ALLOW_MISSING=1,
#     and not the `shellcheck not found` line
nxsc="$TMP/lint-nxsc"; mkdir -p "$nxsc"; printf '#!/bin/sh\nexit 0\n' >"$nxsc/shellcheck"; chmod 644 "$nxsc/shellcheck"
LPATH="$nxsc:$nosc"; LENV=(AC_LINT_ALLOW_MISSING=1)
lrun --all
LPATH="$lstub:$PATH"; LENV=()
assert_eq "$L_RC:$(lout):$(lerr)" "1::" "row 18: a found linter that cannot run fails the lint"

# 19. ROOT: through a fleet home's symlinked bin/ the lint works on the
#     checkout the bin/ sits in physically, as bin/ac-bun.sh resolves it -
#     here a clean one whose committed broken file the default never reaches
lput bin/bad.sh "$BAD"; lcommit
LROOT="$TMP/lint-home-n"; mkdir -p "$LROOT"; ln -s "$H/bin" "$LROOT/bin"
LENV=("GIT_CEILING_DIRECTORIES=$TMP")
lrun
LENV=(); LROOT="$H"
assert_eq "$L_RC $(lout)" "0 $EMPTY_SET" "row 19: the physical checkout is linted"
ldrop bin/bad.sh

# 20. without bun the shim refuses
LPATH="$lstub:$nobun"
lrun --all
LPATH="$lstub:$PATH"
assert_eq "$L_RC $(lerr)" "1 ERROR: required tool not found: bun" "row 20: the shim refuses without bun"

pass
