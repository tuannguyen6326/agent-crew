#!/usr/bin/env bash
# ac-project-mode.test.sh - the registry answers YOLO ONLY
# (delivery mode is per-task, resolved from the backlog row's
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

# --- the read, row by row -----------------------------------------------------
# LC_ALL=C unless a row sets RUN_LC: the module spawns this host's grep and sed
# under the caller's locale.
run() {  # run <args...> - one call; sets rc, out, err
  rc=0
  out="$(LC_ALL="${RUN_LC:-C}" "$BIN/ac-project-mode.sh" "$@" 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
}
answer() {  # answer <on|off> <args...> - exit 0, that answer, a silent stderr
  local want="$1"
  shift
  run "$@"
  assert_eq "$rc|$out|$err" "0|yolo=$want|" "answer for '$*'"
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
  printf -- '- yoloword [notyolo] - +yolo in desc\n'
  printf -- '- two [a] [+yolo] - second bracket\n'
  printf -- '- nest [[+yolo]] - nested\n'
  printf -- '- YOLO [+YOLO] - case\n'
  printf -- '- sp2 [ +yolo ] - padded\n'
  printf -- '- uni [+yolo] - 日本\n'
}
{ r1_rows; printf -- '- last [+yolo] - eol'; } >"$reg"
# 1. first hit, first bracket, case-sensitive substring; exactly one space
# before `[`; a CR is an ordinary byte; an unterminated last row is a row.
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
# 2. names that match no row answer off, silently, whatever they spell.
for n in alph 'a.b ' 'alpha beta' '*' - --help -h 'a|gamma' 'a$' '(' 'foo+'; do
  answer off "$n"
done
# 3. usage refusal, exit 1, nothing on stdout; 4. extra args ignored.
usage="ERROR: usage: ac-project-mode.sh <project-name>"
run; assert_eq "$rc|$out|$err" "1||$usage" "no name is the usage refusal"
run ''; assert_eq "$rc|$out|$err" "1||$usage" "an empty name is the usage refusal"
answer on gamma junk more
# 5. a non-UTF-8 byte on the matched row answers under C; a clean row beside
# it answers under a UTF-8 locale too.
{ r1_rows; printf -- '- bad [+yolo] - d\xe9sc\n- badpre [+yolo \xe9] - x\n'; } >"$reg"
answer on bad
answer on badpre
RUN_LC=en_US.UTF-8 answer on gamma
# 6. no registry; no records/ dir (the read mints it).
rm -f "$reg"
answer off gamma
rm -rf "$AC_HOME/records"
answer off gamma
[ -d "$AC_HOME/records" ] || fail "records/ minted by the read"
# 7. registry a directory; unreadable; records/ a regular file (off, exit 0).
mkdir -p "$reg"
answer off gamma
rmdir "$reg"
rm -rf "$AC_HOME/records"; printf 'not a directory\n' >"$AC_HOME/records"
run gamma; assert_eq "$rc|$out" "0|yolo=off" "records a file: off"
rm -f "$AC_HOME/records"; mkdir -p "$AC_HOME/records"
# an existing records/ is never mkdir'd: a PATH mkdir that refuses changes nothing
mkdir -p "$TMP/nomkdir"; printf '#!/bin/sh\necho "mkdir ran" >&2; exit 1\n' >"$TMP/nomkdir/mkdir"; chmod +x "$TMP/nomkdir/mkdir"
{ r1_rows; } >"$reg"
PATH="$TMP/nomkdir:$PATH" answer on gamma
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$reg"
  answer off gamma
  chmod 644 "$reg"
fi
# 8. empty; CRLF-only.
: >"$reg"
answer off gamma
printf -- '- gamma [+yolo] - z\r\n' >"$reg"
answer on gamma
# 9. a home that is not there: off, silently.
AC_HOME=/nonexistent answer off gamma
# 10. AC_HOME through a symlink.
ln -s "$AC_HOME" "$TMP/homelink"
{ r1_rows; } >"$reg"
AC_HOME="$TMP/homelink" answer on gamma
AC_HOME="$TMP/homelink" answer off alpha
# 11. the home is the directory AC_HOME names: one whose name ends in LF is
# not its sibling without it, and a relative one is entered without CDPATH.
lfhome="$TMP/lf
"; mkdir -p "$lfhome/records" "$TMP/lf/records"
printf -- '- gamma [+yolo] - z\n' >"$lfhome/records/projects.md"
printf -- '- gamma [x] - z\n' >"$TMP/lf/records/projects.md"
AC_HOME="$lfhome" answer on gamma
mkdir -p "$TMP/cdp/home/records"; printf -- '- gamma [+yolo] - z\n' >"$TMP/cdp/home/records/projects.md"
assert_eq "$(cd "$TMP/cdp" && CDPATH="$TMP" AC_HOME=home LC_ALL=C "$BIN/ac-project-mode.sh" gamma 2>&1)" "yolo=on" "a relative AC_HOME is entered without CDPATH"
# 12. a NAME carrying a non-UTF-8 byte: Bun's argv decodes it to U+FFFD, so
# the pattern cannot carry the row's bytes and the answer is the default.
{ r1_rows; printf -- '- d\xe9sc [+yolo] - x\n'; } >"$reg"
answer off "$(printf 'd\xe9sc')"

pass
