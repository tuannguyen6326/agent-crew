#!/usr/bin/env bash
# ac-project-mode.test.sh - the registry answers YOLO ONLY (captain order
# 2026-08-10: delivery mode is per-task, resolved from the backlog row's
# contract pin / --mode by ac-brief.sh - never from records/projects.md).
# A legacy [<mode>] bracket is tolerated, ignored content: old registries
# keep resolving yolo without a migration, and a bogus legacy mode is not
# an error any more because the field carries no authority to misuse.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
cat >"$AC_HOME/records/projects.md" <<'REG'
- alpha [direct-pr] - legacy mode bracket, no yolo (added 2026-07-13)
- beta [local-only +yolo] - legacy mode bracket with yolo (added 2026-07-13)
- gamma [+yolo] - the new bracket shape (added 2026-08-10)
- delta [bogus-mode] - a legacy mode nobody validates now (added 2026-07-13)
- plain - no bracket at all (added 2026-08-10)
REG

assert_eq "$("$BIN/ac-project-mode.sh" alpha)" "yolo=off" "legacy mode bracket is ignored"
assert_eq "$("$BIN/ac-project-mode.sh" beta)" "yolo=on" "+yolo read out of a legacy bracket"
assert_eq "$("$BIN/ac-project-mode.sh" gamma)" "yolo=on" "the new [+yolo]-only bracket"
assert_eq "$("$BIN/ac-project-mode.sh" delta)" "yolo=off" "a bogus legacy mode is dead content, not an error"
assert_eq "$("$BIN/ac-project-mode.sh" plain)" "yolo=off" "a bracketless line defaults yolo off"
assert_eq "$("$BIN/ac-project-mode.sh" unregistered)" "yolo=off" "an unregistered project defaults yolo off"
out="$("$BIN/ac-project-mode.sh" alpha)"
case "$out" in *mode=*) fail "the registry must not answer mode any more (got: $out)" ;; esac

# The interim-layout migration is RETIRED (audit-f7): records/ is the ONE
# registry location - a record at the data/ root or data/records/ is never
# read, never moved, never overwrites the records/ copy.
rm -f "$AC_HOME/records/projects.md"
printf -- '- legacy [+yolo] - pre-split registry (added 2026-07-13)\n' >"$AC_HOME/data/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" legacy)" "yolo=off" "a data/-root registry is not read: the default answers"
assert_file "$AC_HOME/data/projects.md" "and it is not moved either - the migration is retired"

mkdir -p "$AC_HOME/data/records"
printf -- '- interim [+yolo] - interim-layout registry (added 2026-07-17)\n' >"$AC_HOME/data/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" interim)" "yolo=off" "an interim data/records/ registry is not read either"

printf -- '- realrow [+yolo] - the one live registry (added 2026-07-29)\n' >"$AC_HOME/records/projects.md"
assert_eq "$("$BIN/ac-project-mode.sh" realrow)" "yolo=on" "the records/ copy is the only one consulted"
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/data/records/projects.md"

# --- AC12: scope data never disturbs the registry parser ---------------------
# The repo-knowledge record is a SIDECAR file, so the registry line the yolo
# parser reads is byte-identical whether the project carries scope data or
# not. Vacuous today by construction - and that is exactly what it guards: the
# day someone moves scope data back onto a registry line, this reds.
rm -f "$AC_HOME/data/projects.md" "$AC_HOME/records/projects.md"
cat >"$AC_HOME/records/projects.md" <<'REG'
- scoped [+yolo] - a monorepo with scopes (added 2026-07-21)
- flat - a single-app repo (added 2026-07-21)
REG
before="$("$BIN/ac-project-mode.sh" scoped)"
mkdir -p "$AC_HOME/records/repo-knowledge"
cat >"$AC_HOME/records/repo-knowledge/scoped.md" <<'RK'
# Repo knowledge: scoped

- scope orchid = orchid-service, orchid-worker | src: cmd:true | at: deadbeef 2026-07-21 | by: fam
- scope cedar = cedar-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam

## Superseded
RK
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "$before" "scope data leaves the yolo answer untouched"
assert_eq "$("$BIN/ac-project-mode.sh" scoped)" "yolo=on" "the registry line still resolves in full"
assert_eq "$("$BIN/ac-project-mode.sh" flat)" "yolo=off" "a sibling project is unaffected"

# --- differential: src/project-mode.ts against the frozen bash original ------
# DISPUTED: the implementation (tests/fixtures/ac-project-mode.sh under bash vs src/project-mode.ts through bin/ac-project-mode.sh)
# HELD-CONSTANT: the home and the registry bytes, argv, cwd, the locale (LC_ALL=C unless a case says otherwise - both sides spawn this host's grep and sed); stdout, stderr and exit status compared whole
obin="$(make_oracle_bin ac-project-mode)"
# The frozen entry wraps ac_project_mode, retired from bin/ac-lib.sh with the
# port (the entry was its last caller); the oracle's own ac-lib.sh copy gets
# the helper back verbatim, frozen here beside the entry.
cat >>"$obin/ac-lib.sh" <<'LIB'

ac_project_mode() {
  local name="$1" reg line
  reg="$(ac_records_dir)/projects.md"
  [ -f "$reg" ] || { printf '\n'; return 0; }
  line="$(grep -E "^- $name \[" "$reg" 2>/dev/null | head -n1 || true)"
  if [ -z "$line" ]; then printf '\n'; return 0; fi
  printf '%s\n' "$line" | sed -n 's/^- [^[]*\[\([^]]*\)\].*/\1/p'
}
LIB
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  LC_ALL="${DIFF_LC:-C}" "$obin/ac-project-mode.sh" "$@" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  LC_ALL="${DIFF_LC:-C}" "$BIN/ac-project-mode.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
answer() {  # answer <on|off> <args...> - same, and the answer itself pinned
  local want="$1"
  shift
  same "$@"
  assert_eq "$(cat "$TMP/n.out")" "yolo=$want" "answer for '$*'"
}
reg="$AC_HOME/records/projects.md"
r1_rows() {  # every R1 row but the unterminated last one
  printf -- '- alpha [direct-pr] - x (added d)\n'
  printf -- '- beta [local-only +yolo] - y\n'
  printf -- '- gamma [+yolo] - z\n'
  printf -- '- plain - no bracket\n'
  printf -- '- cr [+yolo]\r\n'
  printf -- '- crin [+yolo\r] - cr inside\n'
  printf -- '- twice [+yolo] - a\n'
  printf -- '- twice [off] - b\n'
  printf -- '- nobracket [+yolo - unclosed\n'
  printf -- '- tab\t[+yolo] - tabbed\n'
  printf -- '- sp  [+yolo] - two spaces\n'
  printf -- '- a.b [+yolo] - dot\n'
  printf -- '- aXb [x] - dotmatch\n'
  printf -- '- dXt [+yolo] - only the ERE spelling d.t reaches this row\n'
  printf -- '- yoloword [notyolo] - +yolo in desc\n'
  printf -- '- two [a] [+yolo] - second bracket\n'
  printf -- '- nest [[+yolo]] - nested\n'
  printf -- '- YOLO [+YOLO] - case\n'
  printf -- '- sp2 [ +yolo ] - padded\n'
  printf -- '- uni [+yolo] - 日本\n'
}
{ r1_rows; printf -- '- last [+yolo] - eol'; } >"$reg"
# 1. every R1 name: first hit, first bracket, case-sensitive substring.
answer off alpha
answer on beta
answer on gamma
answer off plain
answer on cr
answer on crin
answer on twice
answer off nobracket
answer off tab
answer off sp
answer on a.b
answer off aXb
answer off yoloword
answer off two
answer on nest
answer off YOLO
answer on sp2
answer on uni
answer on last
# W4, kept: the name is operator text in grep's ERE - `d.t` answers for dXt.
answer on d.t
# 2. names that match nothing, or an ERE grep refuses (rc 2, stderr dropped);
# `a|gamma` reads `^- a` OR `gamma \[` and alpha's bracket answers.
answer off alph
answer off 'a.b '
answer off 'alpha beta'
answer off '*'
answer off -
answer off --help
answer off -h
answer off 'a|gamma'
answer off 'a$'
answer off '('
answer off 'foo+'
# 3. usage refusal, exit 1, nothing on stdout; 4. extra args ignored.
same
same ''
assert_eq "$(cat "$TMP/n.err")" "ERROR: usage: ac-project-mode.sh <project-name>" "usage refusal bytes"
assert_eq "$(cat "$TMP/n.out")" "" "usage: no answer on stdout"
answer on gamma junk more
# 5. a non-UTF-8 byte on the MATCHED row: under C both answer; under the
# operator's UTF-8 locale BSD sed aborts (`sed: RE error: illegal byte
# sequence`) and the original exits 1 with NO answer (W2, kept: the port
# spawns the same sed, so stderr and exit are the original's under either
# locale - the row is still never answered there).
{ r1_rows; printf -- '- bad [+yolo] - d\xe9sc\n- badpre [+yolo \xe9] - x\n'; } >"$reg"
answer on bad
answer on badpre
answer on gamma
DIFF_LC=en_US.UTF-8 same bad
n_rc=0; LC_ALL=en_US.UTF-8 "$BIN/ac-project-mode.sh" bad >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "1" "W2: exit 1 under UTF-8, as the original"
assert_eq "$(cat "$TMP/n.out")" "" "W2: no answer under UTF-8"
assert_contains "$(cat "$TMP/n.err")" "illegal byte sequence" "W2: sed's own abort line"
DIFF_LC=en_US.UTF-8 answer on gamma
# 6. one NUL anywhere in the registry: grep says `Binary file ... matches`
# instead of the row, so EVERY project answers off (W3, kept).
{ r1_rows; printf -- '- nul [+yolo] - d\x00sc\n'; } >"$reg"
answer off gamma
answer off nul
# 7. no registry; no records/ dir (both sides mint it).
rm -f "$reg"
answer off gamma
rm -rf "$AC_HOME/records"
answer off gamma
[ -d "$AC_HOME/records" ] || fail "records/ minted by the read"
rm -rf "$AC_HOME/records"
LC_ALL=C "$BIN/ac-project-mode.sh" gamma >/dev/null
[ -d "$AC_HOME/records" ] || fail "records/ minted by the port's read"
# 8. registry a directory; unreadable (grep's stderr is dropped).
mkdir -p "$reg"
answer off gamma
rmdir "$reg"
{ r1_rows; } >"$reg"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$reg"
  answer off gamma
  assert_eq "$(cat "$TMP/n.err")" "" "unreadable registry: silent"
  chmod 644 "$reg"
fi
# 9. empty; CRLF-only.
: >"$reg"
answer off gamma
printf -- '- gamma [+yolo] - z\r\n' >"$reg"
answer on gamma
# 10. homeless (W1, kept): the refusal on stderr AND yolo=off, exit 0.
AC_HOME= same gamma
assert_eq "$(cat "$TMP/n.out")" "yolo=off" "W1: homeless still answers"
assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "W1: the swallowed refusal is printed"
# 11. a home that is not there: off, exit 0 on both; the original's stderr is
# bash's own `cd:` line, which the port does not reproduce (its stderr is empty).
o_rc=0; AC_HOME=/nonexistent LC_ALL=C "$obin/ac-project-mode.sh" gamma >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME=/nonexistent LC_ALL=C "$BIN/ac-project-mode.sh" gamma >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "missing home: both exit 0"
assert_eq "$(cat "$TMP/n.out")" "$(cat "$TMP/o.out")" "missing home: the same answer"
assert_eq "$(cat "$TMP/n.out")" "yolo=off" "missing home: off"
assert_contains "$(cat "$TMP/o.err")" "cd:" "missing home: the original's stderr is the shell's"
assert_eq "$(cat "$TMP/n.err")" "" "missing home: the port adds no line of its own"
# 12. AC_HOME through a symlink.
ln -s "$AC_HOME" "$TMP/homelink"
{ r1_rows; } >"$reg"
AC_HOME="$TMP/homelink" answer on gamma
AC_HOME="$TMP/homelink" answer off alpha
# 13. a NAME carrying a non-UTF-8 byte: Bun's argv decodes it to U+FFFD, so
# the port's grep never sees the row's bytes - the one divergence kept with
# no exact reproduction (oracle on, port off).
{ r1_rows; printf -- '- d\xe9sc [+yolo] - x\n'; } >"$reg"
bad_name="$(printf 'd\xe9sc')"
o_rc=0; LC_ALL=C "$obin/ac-project-mode.sh" "$bad_name" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; LC_ALL=C "$BIN/ac-project-mode.sh" "$bad_name" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "non-UTF-8 name: both exit 0"
assert_eq "$(cat "$TMP/o.out")" "yolo=on" "non-UTF-8 name: the original matches the row's bytes"
assert_eq "$(cat "$TMP/n.out")" "yolo=off" "non-UTF-8 name: the port's argv cannot carry the byte"

pass
