#!/usr/bin/env bash
# ac-epic-ship.test.sh - the epic gate + 2-PR exit (bin/ac-epic-ship.sh, spec
# in the header of src/epic-ship.ts) held to its frozen bash original: usage,
# the fence, the record parse, verify's delegate, story terminality and the
# partial-epic receipts, the review round at origin's tip, the qa pin, and
# the exit - dry-run and real, against scratch bare origins and a PATH gh
# stub only. The original's own black-box rows stay in
# tests/sh/ac-epic-branch.test.sh.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# --- differential: src/epic-ship.ts against the frozen bash original ---------
# DISPUTED: the implementation (tests/fixtures/ac-epic-ship.sh under bash vs src/epic-ship.ts through bin/ac-epic-ship.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home whose projects/ clones fetch from bare origins under <side>/remotes, every commit stamped with one fixed date so the shas agree - argv and env (the side root spelled HOME, substituted in values only), cwd (the side root), stdin (/dev/null unless a row feeds a file), LC_ALL=C, PATH stubs on both sides: `gh` (logs its argv and cwd; `pr view` prints <side>/gh.state; `pr create` prints GH_URL or refuses on <side>/gh.fail), `date` (one fixed instant), `herdr`/`orca` (log, exit 1); exit status, stdout and stderr (the side root spelled HOME) compared whole, then the world a row may touch: `git for-each-ref` of every clone and origin, every record, data/<e>/gate/* and room bytes (live and archived), and the stub logs.
obin="$(make_oracle_bin ac-epic-ship)"
OH="$TMP/eside-o"; NH="$TMP/eside-n"
ESTUBS="$TMP/estubs"; mkdir -p "$ESTUBS"
cat >"$ESTUBS/gh" <<'STUB'
#!/bin/sh
printf 'gh %s (cwd %s)\n' "$*" "$(pwd -P)" >>"$GH_LOG"
case "$1 $2" in "pr view") cat "$GH_STATE" 2>/dev/null; exit 0 ;; esac
[ -z "${GH_STDIN:-}" ] || { printf 'stdin: '; cat; } >>"$GH_LOG"
[ ! -e "$GH_FAIL" ] || { printf 'gh: the stub refuses\n' >&2; exit 1; }
printf '%s\n\n' "${GH_URL-https://example.test/pr/1}"
STUB
cat >"$ESTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in *%s*) echo 1767225600 ;; *) echo 2026-01-01T00:00:00Z ;; esac
STUB
for t in herdr orca; do printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$GH_LOG"\nexit 1\n' "$t" >"$ESTUBS/$t"; done
chmod +x "$ESTUBS"/*
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
eseed() { mkdir -p "$H/home/projects" "$H/home/records" "$H/home/data" "$H/remotes"; }
mkrepo() {  # mkrepo <dir> - main with one fixed-date commit
  git init -q -b main "$1"
  git -C "$1" config user.email test@test; git -C "$1" config user.name test
  printf 'base\n' >"$1/f.txt"; git -C "$1" add -A; gitc -C "$1" commit -qm base
}
origin_repo() {  # origin_repo <name> - bare remotes/<name>.git fed from src-<name>, cloned to projects/<name>
  mkrepo "$H/src-$1"
  git clone -q --bare "$H/src-$1" "$H/remotes/$1.git"
  git clone -q "$H/remotes/$1.git" "$H/home/projects/$1"
  git -C "$H/home/projects/$1" config user.email test@test; git -C "$H/home/projects/$1" config user.name test
}
local_repo() { mkrepo "$H/home/projects/$1"; }
on_origin() {  # on_origin <repo> <branch> [<commits ahead of main>] - a branch pushed to the origin only
  local s="$H/src-$1" i
  git -C "$s" checkout -q -b "$2" main
  for ((i = 0; i < ${3:-0}; i++)); do printf '%s %s\n' "$2" "$i" >>"$s/f.txt"; git -C "$s" add -A; gitc -C "$s" commit -qm "$2 $i"; done
  git -C "$s" push -q "$H/remotes/$1.git" "$2:$2"; git -C "$s" checkout -q main
}
commit_on() {  # commit_on <repo> <branch> <msg> - one fixed-date commit on a local branch of a clone
  local p="$H/home/projects/$1"
  git -C "$p" checkout -q "$2"; printf '%s\n' "$3" >>"$p/f.txt"; git -C "$p" add -A; gitc -C "$p" commit -qm "$3"
  git -C "$p" checkout -q --detach
}
rec() { mkdir -p "$H/home/data/$1"; printf -- "$2" >"$H/home/data/$1/branches"; }
led() { printf -- "$1" >"$H/home/records/backlog.md"; }
room() { mkdir -p "$H/home/data/$1"; printf -- "$2" >"$H/home/data/$1/room.md"; }
tip_of() {  # tip_of <repo> <branch> - origin's tip, else the clone's local branch
  if [ -d "$H/remotes/$1.git" ]; then git -C "$H/remotes/$1.git" rev-parse "$2"; else git -C "$H/home/projects/$1" rev-parse "refs/heads/$2"; fi
}
review() {  # review <epic> <repo> <branch> [<json with TIP for the branch tip>] - the gate's review record
  local tip j="${4-}"
  tip="$(tip_of "$2" "$3")"
  [ -n "$j" ] || j='{"findings":[],"reviewed_ref":"TIP"}'
  mkdir -p "$H/home/data/$1/gate"
  printf '%s\n' "${j//TIP/$tip}" >"$H/home/data/$1/gate/review.json"
}
ready() {  # ready <epic> <repo> <branch> <record bytes> - recorded, on origin at main, reviewed clean
  rec "$1" "$4"; on_origin "$2" "$3"; review "$1" "$2" "$3"
}
ships() { mkdir -p "$H/home/data/$1/gate"; printf -- "$2" >"$H/home/data/$1/gate/ships.env"; }
HOMELESS=0
ES_ENV=()
ES_PATH=""
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root; cwd is ES_CWD under the root, removed once entered under ES_GONE
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C "PATH=${ES_PATH:-$ESTUBS:$PATH}" "GH_LOG=$h/gh.log" "GH_FAIL=$h/gh.fail" "GH_STATE=$h/gh.state")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${ES_ENV[@]+"${ES_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h/${ES_CWD:-}" && { [ -z "${ES_GONE:-}" ] || rmdir "$h/$ES_CWD"; } && env -u AC_HOME "${e[@]}" "$bin/ac-epic-ship.sh" ${a[@]+"${a[@]}"}) <"${ES_STDIN:-/dev/null}" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$2#HOME#g" "$1"; }
O_RC=0; N_RC=0
pair() {  # pair <args...> - both sides run, outputs normalised, nothing compared yet
  O_RC=0; N_RC=0
  run_side "$obin" "$OH" o "$@" || O_RC=$?
  run_side "$BIN" "$NH" n "$@" || N_RC=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
}
same_io() {
  assert_eq "$N_RC" "$O_RC" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
}
world() {  # world <side root> - what a row may change
  local h="$1" r f
  for r in "$h"/home/projects/* "$h"/remotes/*.git; do
    [ -d "$r" ] || continue
    printf '== %s\n' "$r"; git -C "$r" for-each-ref 2>/dev/null || printf 'no repo\n'
  done
  for f in "$h"/home/data/*/branches "$h"/home/data/*/room.md "$h"/home/data/*/gate/* \
    "$h"/home/data/archive/*/*/branches "$h"/home/data/archive/*/*/room.md "$h"/gh.log "$h"/push-stdin.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; cat "$f"; printf '\n'
  done
}
same_world() {
  world "$OH" >"$TMP/o.world"; world "$NH" >"$TMP/n.world"
  norm "$TMP/o.world" "$OH" >"$TMP/o.world2"; norm "$TMP/n.world" "$NH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "differential world differs after '$*': $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 8)"
}
same() { pair "$@"; same_io "$@"; same_world "$@"; }
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
oracle_err() { cat "$TMP/o.err2"; }
nopath() {  # nopath <dir> <tool> - a PATH dir holding every host tool but <tool>
  mkdir -p "$1"
  local d f t
  for d in /usr/bin /bin "$(dirname "$(command -v bun)")" "$(dirname "$(command -v jq)")" "$(dirname "$(command -v git)")"; do
    for f in "$d"/*; do t="$(basename "$f")"; [ -x "$f" ] && [ "$t" != "$2" ] && [ ! -e "$1/$t" ] && ln -s "$f" "$1/$t"; done
  done
  return 0
}
USAGE='ERROR: usage: ac-epic-ship.sh <epic> <repo> [--dry-run]'
NOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
FENCE="ERROR: epic-ship is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=x) - the exit of an epic is the fleet chief's act on the captain's word"
noentry() { printf 'ERROR: no branches record entry for %s under epic %s - this epic is not branch-recorded' "$2" "$1"; }
both eseed
both origin_repo proj
both local_repo loc
both led ''

# 1. usage, exit 1, before the home: no argument, one, an empty repo; then
#    homeless. W17: git and jq are required BEFORE the arguments are read, so
#    a PATH without jq answers every argv - usage, homeless and scoped too
same; assert_eq "$(shim_err)" "$USAGE" "1: no argument"
same e1; assert_eq "$(shim_err)" "$USAGE" "1: one argument"
same e1 ''; assert_eq "$(shim_err)" "$USAGE" "1: an empty repo"
same '' proj; assert_eq "$(shim_err)" "$USAGE" "1: an empty epic"
HOMELESS=1; same; HOMELESS=0
assert_eq "$(shim_err)" "$USAGE" "1: usage precedes the home"
nopath "$TMP/nojq" jq
ES_PATH="$ESTUBS:$TMP/nojq"
for args in "" "e1 proj --dry-run"; do
  # shellcheck disable=SC2086
  same $args; assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "1: W17 - no jq answers '$args'"
done
ES_ENV=(AC_SCOPE=x); HOMELESS=1; same e1 proj; ES_ENV=(); HOMELESS=0
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "1: W17 - before the home and the fence"
nopath "$TMP/nogit" git
ES_PATH="$ESTUBS:$TMP/nogit"; same e1 proj
assert_eq "$(shim_err)" "ERROR: required tool not found: git" "1: git first"
ES_PATH=""
#    ...a jq on PATH that is not executable - NAMED: the original's `command
#    -v` took it and went on to the record, the port refuses it as missing
cp -R "$TMP/nojq" "$TMP/nxjq"; printf 'exit 0\n' >"$TMP/nxjq/jq"; chmod 644 "$TMP/nxjq/jq"
ES_PATH="$ESTUBS:$TMP/nxjq"; pair e1 proj; ES_PATH=""
assert_eq "$O_RC $N_RC" "1 1" "1: a non-executable jq exits 1 on both sides"
assert_eq "$(oracle_err)" "$(noentry e1 proj)" "1: the original took it and read the record"
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "1: named - the port refuses it"

# 2. homeless: W4 - NAMED: the original printed the refusal twice (the
#    swallowed `$(ac_data_dir)` of the live rung, then the archive glob) and
#    the no-entry remedy - once for an epic outside [a-zA-Z0-9_-], which skips
#    the glob; the port refuses once; exit 1, nothing on stdout. An AC_HOME
#    cd cannot enter: the original printed cd's own lines and the remedy, the
#    port names the variable once (the HOME RESOLUTION ruling)
HOMELESS=1
for row in "e1:2" "a.b:1"; do
  pair "${row%%:*}" proj
  assert_eq "$O_RC $N_RC" "1 1" "2: homeless ${row%%:*} exits 1 on both sides"
  assert_eq "$(cat "$TMP/o.out" "$TMP/n.out")" "" "2: homeless ${row%%:*} prints nothing on stdout"
  assert_eq "$(/usr/bin/grep -c 'AC_HOME is not set' "$TMP/o.err2")" "${row#*:}" "2: W4 - the original's refusal count for ${row%%:*}"
  assert_eq "$(tail -n 1 "$TMP/o.err2")" "$(noentry "${row%%:*}" proj)" "2: W4 - then the remedy for ${row%%:*}"
  assert_eq "$(shim_err)" "$NOHOME" "2: W4 named - the port refuses once for ${row%%:*}"
  same_world "homeless ${row%%:*}"
done
ES_ENV=(AC_HOME=HOME/missing)
pair e1 proj
assert_eq "$O_RC $N_RC" "1 1" "2: an unenterable home exits 1 on both sides"
assert_contains "$(oracle_err)" "HOME/missing: No such file or directory" "2: cd's own line on the original"
assert_eq "$(tail -n 1 "$TMP/o.err2")" "$(noentry e1 proj)" "2: then the remedy"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: HOME/missing" "2: W4 named - the port names the variable once"
ES_ENV=()
HOMELESS=0

# 3. the fence: AC_SCOPE refuses before the home is read; an empty AC_SCOPE
#    is no scope
ES_ENV=(AC_SCOPE=x)
same e1 proj --dry-run; assert_eq "$(shim_err)" "$FENCE" "3: scoped"
HOMELESS=1; same e1 proj; HOMELESS=0
assert_eq "$(shim_err)" "$FENCE" "3: the fence precedes the home"
ES_ENV=(AC_SCOPE=)
same e1 proj --dry-run; assert_eq "$(shim_err)" "$(noentry e1 proj)" "3: an empty AC_SCOPE is unscoped"
ES_ENV=()

# 4. the record: none; retired on its FIRST line only; no entry for the
#    repo; the parse - TAB-separated fields, an EMPTY staging= is no staging
#    (W5: one PR straight to the default branch), the first of two staging=
#    keys, `staging=a=b`, push only as the whole token push=yes; a numeric
#    repo read by awk's == (`07` reads the `7` line); an archived record;
#    `--dry-run` as the second argument is a repo name
seed4() {
  rec ret '# retired 2026-01-01T00:00:00Z\nproj epic/ret\n'
  ready ret2 proj epic/ret2 'proj epic/ret2\n# retired 2026-01-01T00:00:00Z\n'
  rec noent 'other epic/noent\n'
  ready tab proj epic/tab 'proj\tepic/tab\tstaging=st-tab\t push=yes\n'
  ready w5 proj epic/w5 'proj epic/w5 staging= push=yes\n'
  ready dup proj epic/dup 'proj epic/dup staging=s1 staging=s2\n'
  ready sab proj epic/sab 'proj epic/sab staging=a=b\n'
  ready pyes proj epic/pyes 'proj epic/pyes push=YES\n'
  ready pyn proj epic/pyn 'proj epic/pyn push=yesno xpush=yes\n'
  origin_repo 07; ready num 07 epic/num '7 epic/num\n'
  on_origin proj epic/arc; mkdir -p "$H/home/data/archive/2026/arc"; printf 'proj epic/arc\n' >"$H/home/data/archive/2026/arc/branches"; review arc proj epic/arc
}
both seed4
same nosuch proj --dry-run; assert_eq "$(shim_err)" "$(noentry nosuch proj)" "4: no record"
same ret proj --dry-run; assert_eq "$(shim_err)" "ERROR: the ret record is retired - a retired epic has no exit to run" "4: retired"
same ret2 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create --base main --head epic/ret2" "4: a marker on line 2 retires nothing"
same noent proj --dry-run; assert_eq "$(shim_err)" "$(noentry noent proj)" "4: no entry for the repo"
same e1 --dry-run; assert_eq "$(shim_err)" "$(noentry e1 --dry-run)" "4: --dry-run as the second argument is the repo"
DRYP='DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/tab:refs/heads/epic/tab'
same tab proj --dry-run
assert_eq "$(shim_out)" "$DRYP
DRY-RUN: gh pr create --base st-tab --head epic/tab --title \"epic(tab): integration -> st-tab\" (in HOME/home/projects/proj)
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "4: TAB-separated fields - push, then PR-1"
same w5 proj --dry-run
assert_eq "$(shim_out)" "${DRYP//tab/w5}
DRY-RUN: gh pr create --base main --head epic/w5 --title \"epic(w5): integration -> main\" (in HOME/home/projects/proj)" "4: W5 - an empty staging= is one PR to the default branch"
same dup proj --dry-run; assert_contains "$(shim_out)" "--base s1 --head epic/dup" "4: the first staging= wins"
same sab proj --dry-run; assert_contains "$(shim_out)" "--base a=b --head epic/sab" "4: staging=a=b"
for e in pyes pyn; do
  same "$e" proj --dry-run
  case "$(shim_out)" in *"DRY-RUN: git"*) fail "4: $e is no push=yes" ;; esac
  assert_contains "$(shim_out)" "DRY-RUN: gh pr create --base main --head epic/$e" "4: $e opens its PR"
done
same num 07 --dry-run; assert_contains "$(shim_out)" "--head epic/num" "4: awk's numeric == - repo 07 reads the 7 entry"
same arc proj --dry-run; assert_contains "$(shim_out)" "--head epic/arc" "4: an archived record"

# 5. verify: src/epic-branch.ts's refusals and status pass through - the
#    branch absent on an origin repo, absent locally on a local-only repo, no
#    clone at all. The delegate gets this process's environment BYTES: a
#    value holding a byte that is not UTF-8 reaches verify's ls-remote
#    unchanged on both sides (a BUN_ name is dropped there, as ac-bun.sh
#    dropped it)
seed5() { rec nv 'proj epic/nv\nloc epic/nv\nghost epic/nv\n'; }
both seed5
same nv proj --dry-run
assert_eq "$(shim_err)" "ERROR: verify: epic/nv is not on origin of proj - create it (ac-epic-branch.sh create nv proj) before any story spawns against it" "5: not on origin"
same nv loc --dry-run
assert_eq "$(shim_err)" "ERROR: verify: epic/nv does not exist in loc - create it (ac-epic-branch.sh create nv loc) before any story spawns against it" "5: not in a local-only repo"
same nv ghost --dry-run; assert_eq "$(shim_err)" "ERROR: no project clone at projects/ghost" "5: no clone"
REAL_GIT="$(command -v git)"
ENVSTUB="$TMP/eenvstub"; mkdir -p "$ENVSTUB"
cat >"$ENVSTUB/git" <<STUB
#!/bin/sh
case " \$* " in *" ls-remote "*) printf '%s' "\$ES_PROBE" | od -An -tx1 | tr -d ' \\n' >>"\$ES_PROBE_LOG"; printf ' bun=[%s]\\n' "\${BUN_ES_PROBE-unset}" >>"\$ES_PROBE_LOG" ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$ENVSTUB/git"
ES_PATH="$ENVSTUB:$ESTUBS:$PATH"; ES_ENV=("ES_PROBE=$(printf 'a\351b')" "ES_PROBE_LOG=HOME/probe.log" "BUN_ES_PROBE=1")
same ret2 proj --dry-run
ES_PATH=""; ES_ENV=()
assert_eq "$(cat "$NH/probe.log")" "$(cat "$OH/probe.log")" "5: verify's git saw the same environment bytes on both sides"
assert_eq "$(cat "$NH/probe.log")" "61e962 bun=[unset]" "5: the byte intact, the BUN_ name dropped"

# 6. stories, in ledger order, every section: an open story; the epic's own
#    row is no story; W1 - an off-grammar checkbox parses with the id `-`;
#    open beats partial; partials without a room; W3 - a receipt ending at
#    the id does not count; the receipts in an archived room pass; the
#    receipt grep is a BRE over the id (`s6.k` finds `s6Xk`'s receipt); rows
#    of another epic, in another case, past a NUL are no stories; an
#    unterminated last line is a row; a byte that is not UTF-8 in prose is
#    one more byte, also under UTF-8
both ready s6 proj epic/s6 'proj epic/s6\n'
both led '## In flight\n- [ ] s6 [EPIC] - the epic row is no story; epic:s6\n- [ ] s6-a - open; epic:s6\n## Done\n- [x] s6-b - landed; epic:s6\n- [ ] s6-c - open again; epic:s6\n'
same s6 proj --dry-run
assert_eq "$(shim_err)" "ERROR: epic s6 has non-terminal stories: s6-a s6-c - every story lands (or is failed/abandoned by the captain) before the epic exits" "6: open stories in ledger order"
both led '- [X] s6-d - capital; epic:s6\n- [~] s6-e - tilde; epic:s6\n- [ ]s6-f - no space; epic:s6\n'
same s6 proj --dry-run
assert_eq "$(shim_err)" "ERROR: epic s6 has non-terminal stories: - - - - every story lands (or is failed/abandoned by the captain) before the epic exits" "6: W1 - off-grammar checkboxes list as -"
both led '- [x] s6-g [failed] - dead; epic:s6\n- [ ] s6-h - open; epic:s6\n'
same s6 proj --dry-run; assert_contains "$(shim_err)" "non-terminal stories: s6-h -" "6: open beats partial"
PARTIAL="ERROR: partial epic: [failed]/[abandoned] stories need a captain revert-or-keep receipt in the room -"
PTAIL=" - post the GATE:, record the captain's answer as 'DECIDED: epic-ship partial - <story> revert|keep <words>', then re-run"
both led '- [x] s6-g [failed] - dead; epic:s6\n- [x] s6-i [abandoned] - dead; epic:s6\n- [ ] s6-j - another epic; epic:s7\n- [ ] s6-k - case; epic:S6\n- [ ] s6-l - prose\0 epic:s6\n- [x] s6 - the epic row closed early; epic:s6\n'
same s6 proj --dry-run
assert_eq "$(shim_err)" "$PARTIAL s6-g s6-i$PTAIL" "6: partials without a room"
both room s6 '# Room: s6\n\n- [2026-01-01T00:00:00Z] crewchief> DECIDED: epic-ship partial - s6-g keep (captain word)\n- [2026-01-01T00:00:00Z] crewchief> DECIDED: epic-ship partial - s6-i\n'
same s6 proj --dry-run; assert_eq "$(shim_err)" "$PARTIAL s6-i$PTAIL" "6: W3 - a receipt ending at the id does not count"
arch_room() { mkdir -p "$H/home/data/archive/2026/s6"; printf -- '- [x] crewchief> DECIDED: epic-ship partial - s6-g keep\n- [x] crewchief> DECIDED: epic-ship partial - s6-i revert\n' >"$H/home/data/archive/2026/s6/room.md"; rm "$H/home/data/s6/room.md"; }
both arch_room
same s6 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: the receipts in the archived room pass the gate"
both led '- [x] s6.k [failed] - a dot; epic:s6\n'
both room s6 '- [x] crewchief> DECIDED: epic-ship partial - s6Xk keep\n'
same s6 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: the BRE dot matches X"
both led '- [x] s6-b - landed; epic:s6\n- [ ] s6-u - open, unterminated; epic:s6'
same s6 proj --dry-run; assert_contains "$(shim_err)" "non-terminal stories: s6-u -" "6: an unterminated last line is a row"
both led '- [x] s6-b - landed; epic:s6\n> caf\351 reviewed\n'
ES_ENV=(LC_ALL=en_US.UTF-8); same s6 proj --dry-run; ES_ENV=()
assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: a byte that is not UTF-8 does not stop the walk under UTF-8"
#    W2 - REPRODUCED: `for p in $partials` is unquoted, so each partial id is
#    a pathname pattern against the caller's cwd - `s6*` names the side
#    root's `s6a s6b`, whose receipts then pass the gate; a pattern matching
#    nothing (`s6?x`, `s6-\*`) is kept as written; an id with no pattern
#    character is itself, bytes and all
both led '- [x] s6* [abandoned] - a glob; epic:s6\n- [x] s6?x [failed] - no match; epic:s6\n- [x] s6-\\* [failed] - escaped; epic:s6\n- [x] caf\351 [failed] - latin1; epic:s6\n'
touch "$OH/s6a" "$OH/s6b" "$NH/s6a" "$NH/s6b"
same s6 proj --dry-run
assert_eq "$(shim_err)" "$PARTIAL s6a s6b s6?x s6-\\* $(printf 'caf\351')$PTAIL" "6: W2 - the cwd's names stand in for the pattern"
both led '- [x] s6* [abandoned] - a glob; epic:s6\n'
both room s6 '- [x] crewchief> DECIDED: epic-ship partial - s6a keep\n- [x] crewchief> DECIDED: epic-ship partial - s6b keep\n'
same s6 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: W2 - receipts for the cwd's names pass the gate"
mkdir -p "$OH/empty" "$NH/empty"
ES_CWD=empty; same s6 proj --dry-run; ES_CWD=""
assert_eq "$(shim_err)" "$PARTIAL s6*$PTAIL" "6: W2 - an empty cwd keeps the pattern"
#    ...and a caller cwd with no name (removed once entered) globs nothing on
#    either side, where the port itself sits in the distro root; bash's own
#    `shell-init:`/`chdir:` lines about that cwd are not reproduced (named)
both led '- [x] * [abandoned] - a glob; epic:s6\n'
rm -rf "$OH/home/data/s6/room.md" "$NH/home/data/s6/room.md" "$OH/home/data/archive/2026/s6" "$NH/home/data/archive/2026/s6"
mkdir -p "$OH/gone" "$NH/gone"
ES_CWD=gone; ES_GONE=1; pair s6 proj --dry-run; ES_CWD=""; ES_GONE=""
assert_eq "$O_RC $N_RC" "1 1" "6: W2 - a nameless cwd refuses on both sides"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "6: a nameless cwd - stdout differs"
assert_contains "$(oracle_err)" "shell-init: error retrieving current directory" "6: bash's own cwd lines on the original"
assert_eq "$(tail -n 1 "$TMP/o.err2")" "$PARTIAL *$PTAIL" "6: W2 - the original kept the pattern"
assert_eq "$(tail -n 1 "$TMP/n.err2")" "$PARTIAL *$PTAIL" "6: W2 - so does the port"
same_world "a nameless cwd"
#    The port's expansion is a bash child the original never had: one that
#    dies there ends the run with its status (143) and reaches no gate step
#    after the receipts - the original, expanding in-process, refuses on the
#    missing receipt (1); neither side ships
mkdir -p "$TMP/killbash"
printf '#!/bin/sh\ncase "$1" in -c) kill -TERM $$ ;; esac\nexec /bin/bash "$@"\n' >"$TMP/killbash/bash"; chmod +x "$TMP/killbash/bash"
both led '- [x] s6* [abandoned] - a glob; epic:s6\n'
ES_PATH="$TMP/killbash:$ESTUBS:$PATH"; pair s6 proj --dry-run; ES_PATH=""
assert_eq "$O_RC" 1 "6: a dying expansion helper - the original refuses on the receipt"
assert_eq "$N_RC" 143 "6: a dying expansion helper - the port ends with the child's status"
case "$(cat "$TMP/o.out" "$TMP/n.out")" in *DRY-RUN*) fail "6: a dying expansion helper must reach no shipping command" ;; esac
rm -f "$OH/s6a" "$OH/s6b" "$NH/s6a" "$NH/s6b"
both led ''

# 7. the ledger: missing or unreadable ends the run with exit 2 - NAMED: awk's
#    own `can't open file` lines are not reproduced (the binding's `backlog
#    parser failed` line never prints there: awk opens the file before the
#    binding runs); W10 - a DIRECTORY holds no record, as awk read it, and
#    every gate passes on it
w7() {
  pair s6 proj --dry-run
  [ ! -f "$OH/home/records/backlog.md" ] || chmod 644 "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
  assert_eq "$O_RC $N_RC" "2 2" "7: $1 - exit 2 on both sides"
  assert_eq "$(cat "$TMP/o.out" "$TMP/n.out")" "" "7: $1 - nothing on stdout"
  assert_contains "$(oracle_err)" "awk: can't open file HOME/home/records/backlog.md" "7: $1 - awk's own line on the original"
  assert_eq "$(shim_err)" "" "7: $1 named - not reproduced"
  same_world "a $1 ledger"
}
rm -f "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
w7 missing
if [ "$(id -u)" != 0 ]; then
  both led '- [ ] s6-a - open; epic:s6\n'
  chmod 000 "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
  w7 unreadable
fi
rm -f "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
mkdir "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
same s6 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "7: W10 - a directory ledger passes every gate"
rmdir "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
both led ''

# 8. the tip, origin's first: a fetch that fails (a PATH git refusing fetch
#    only, so verify's ls-remote still answers) leaves a branch the clone
#    never saw resolving nowhere, and a local branch standing in for origin's
#    tip; W8 - no local default branch is git's own 128 at the merge-base,
#    unrelated histories a SILENT exit 1
seed8() {
  rec t8 'proj epic/t8\n'; on_origin proj epic/t8
  rec t8b 'proj epic/t8b\n'; on_origin proj epic/t8b 1; git -C "$H/home/projects/proj" branch -q epic/t8b main
  mkdir -p "$H/home/data/t8b/gate"; printf '{"reviewed_ref":"%s"}\n' "$(git -C "$H/home/projects/proj" rev-parse main)" >"$H/home/data/t8b/gate/review.json"
  origin_repo nomain; ready t8c nomain epic/t8c 'nomain epic/t8c\n'
  git -C "$H/home/projects/nomain" checkout -q --detach; git -C "$H/home/projects/nomain" branch -q -D main
  rec orph 'proj epic/orph\n'
  git -C "$H/src-proj" checkout -q --orphan epic/orph; printf 'orphan\n' >"$H/src-proj/f.txt"; git -C "$H/src-proj" add -A; gitc -C "$H/src-proj" commit -qm orphan
  git -C "$H/src-proj" push -q "$H/remotes/proj.git" epic/orph; git -C "$H/src-proj" checkout -q -f main
  review orph proj epic/orph
}
both seed8
NOFETCH="$TMP/nofetch"; mkdir -p "$NOFETCH"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$NOFETCH/git"; chmod +x "$NOFETCH/git"
ES_PATH="$NOFETCH:$ESTUBS:$PATH"
same t8 proj --dry-run
assert_eq "$(shim_err)" "ERROR: branch epic/t8 resolves nowhere in the clone - fetch origin, or create it first" "8: resolves nowhere"
same t8b proj --dry-run; assert_contains "$(shim_out)" "--head epic/t8b" "8: the local branch is the tip when origin's is unknown"
ES_PATH=""
same t8b proj --dry-run; assert_contains "$(shim_err)" "the recorded review round is for ref" "8: once fetched, origin's tip is judged"
same t8c nomain --dry-run
assert_eq "$N_RC" 128 "8: W8 - no local default branch is git's 128"
assert_contains "$(shim_err)" "fatal: Not a valid object name main" "8: W8 - git's own line"
same orph proj --dry-run
assert_eq "$N_RC:$(shim_out)$(shim_err)" "1:" "8: W8 - unrelated histories exit 1 silently"

# 9. the review round at origin's tip: absent (the command printed whole); a
#    directory is absent; W6 - a stale ref, a numeric ref in jq's spelling,
#    false/null/an array/unparseable read as none, two JSON values print two
#    lines, unreadable reads as none; W7 - two fixes beside an ask-user, an
#    object of fixes counts its values, an element jq cannot index is `ERR`,
#    a clean value before a broken one `0<LF>ERR`; findings absent or no
#    array count 0 and pass on
both ready r9 proj epic/r9 'proj epic/r9\n'
RTIP="$(git -C "$NH/remotes/proj.git" rev-parse epic/r9)"
RCMD="bin/ac-verify.sh codereview --repo HOME/home/projects/proj --ref $RTIP --family r9 --caller <your AC_CREW_ID> --base $RTIP --intent HOME/home/data/r9/room.md --output HOME/home/data/r9/gate/review.json"
rm -f "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
same r9 proj --dry-run
assert_eq "$(shim_err)" "ERROR: no epic review round on record - run ONE independent round over the whole integration diff first: $RCMD" "9: no review"
mkdir -p "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
same r9 proj --dry-run; assert_contains "$(shim_err)" "no epic review round on record" "9: a directory is no record"
rmdir "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
ref_row() {  # ref_row <json> <the ref as printed>
  both review r9 proj epic/r9 "$1"
  same r9 proj --dry-run
  assert_eq "$(shim_err)" "ERROR: the recorded review round is for ref $2, not the current tip $RTIP - the tip moved, run a fresh round: $RCMD" "9: reviewed_ref $1"
}
ref_row '{"reviewed_ref":"deadbeef"}' deadbeef
ref_row '{"reviewed_ref":12}' 12
ref_row '{"reviewed_ref":false}' '<none>'
ref_row '{"reviewed_ref":null}' '<none>'
ref_row '[]' '<none>'
ref_row 'not json' '<none>'
ref_row '{"reviewed_ref":"TIP"} {"reviewed_ref":"x"}' "$RTIP
x"
if [ "$(id -u)" != 0 ]; then
  both review r9 proj epic/r9
  chmod 000 "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
  pair r9 proj --dry-run
  chmod 644 "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
  same_io "unreadable review"
  assert_contains "$(shim_err)" "for ref <none>" "9: an unreadable record reads as none"
fi
fix_row() {  # fix_row <json> <n as printed>
  both review r9 proj epic/r9 "$1"
  same r9 proj --dry-run
  assert_eq "$(shim_err)" "ERROR: the epic review round left $2 open fix finding(s) - fix on the epic branch (the ref change invalidates the round) and run a fresh round: $RCMD" "9: findings $1"
}
fix_row '{"reviewed_ref":"TIP","findings":[{"action":"fix"},{"action":"ask-user"},{"action":"fix"}]}' 2
fix_row '{"reviewed_ref":"TIP","findings":{"a":{"action":"fix"},"b":{"action":"fix"}}}' 2
fix_row '{"reviewed_ref":"TIP","findings":["x"]}' ERR
fix_row '{"reviewed_ref":"TIP","findings":[]} trailing' "0
ERR"
for j in '{"reviewed_ref":"TIP"}' '{"reviewed_ref":"TIP","findings":"x"}'; do
  both review r9 proj epic/r9 "$j"
  same r9 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "9: W7 - $j passes"
done

# 10. qa, when the epic's OWN row pins qa:yes: the attestation is a PREFIX
#     glob handed to ls (W9 - `<tip>junk` counts, a match ls cannot list
#     refuses, the dot-prefixed in-flight temp never matches); a TAB-joined
#     pin gates; the epic row is found by string equality (epic 7 reads its
#     own row, not 07's)
QAREF="ERROR: the epic row pins qa:yes and no crew-qa pass attestation exists for the tip $RTIP - run one behavioral round against the BUILT epic branch (crew-qa skill / bin/ac-qa.sh agent --target $RTIP ...). Note: a ut coverage row qualifies only against a ship TEST RECEIPT minted at this tip - no story run's SHA can stand in (epic-branch-mech M7)"
both review r9 proj epic/r9
both led '- [ ] r9 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:yes] - the epic (repo: proj)\n'
same r9 proj --dry-run; assert_eq "$(shim_err)" "$QAREF" "10: no attestation"
qa_row() {  # qa_row <name under passed/> <file|dir|dir000> <want: pass|refuse>
  local h; for h in "$OH" "$NH"; do
    mkdir -p "$h/home/projects/proj/.crew/qa/passed"
    case "$2" in file) : >"$h/home/projects/proj/.crew/qa/passed/$1" ;; *) mkdir -p "$h/home/projects/proj/.crew/qa/passed/$1" ;; esac
    [ "$2" != dir000 ] || chmod 000 "$h/home/projects/proj/.crew/qa/passed/$1"
  done
  pair r9 proj --dry-run
  chmod -R 755 "$OH/home/projects/proj/.crew" "$NH/home/projects/proj/.crew"
  same_io "qa $1"
  case "$3" in pass) assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "10: qa $1 passes" ;; *) assert_eq "$(shim_err)" "$QAREF" "10: qa $1 refuses" ;; esac
  rm -rf "$OH/home/projects/proj/.crew" "$NH/home/projects/proj/.crew"
}
qa_row "$RTIP" file pass
qa_row "$RTIP.scope.app" file pass
qa_row "${RTIP}junk" file pass
qa_row "${RTIP%?}" file refuse
qa_row ".$RTIP.tmp" file refuse
qa_row "$RTIP.d" dir pass
[ "$(id -u)" = 0 ] || qa_row "$RTIP.d" dir000 refuse
both led '- [ ] r9 [EPIC] [src:cap flow:direct mode:direct-pr rev:no\tqa:yes] - the epic (repo: proj)\n'
same r9 proj --dry-run; assert_eq "$(shim_err)" "$QAREF" "10: a TAB-joined pin"
seed10() {
  ready 7 proj epic/7 'proj epic/7\n'; ready 07 proj epic/07 'proj epic/07\n'
  led '- [ ] 07 [src:cap qa:no] - an earlier row reading as the same number\n- [ ] 7 [src:cap qa:yes] - the numeric epic\n'
}
both seed10
same 7 proj --dry-run; assert_contains "$(shim_err)" "no crew-qa pass attestation" "10: epic 7 reads its own row"
same 07 proj --dry-run; assert_contains "$(shim_out)" "--head epic/07" "10: epic 07 reads its own row"
both led ''

# 11. the exit, dry: mkdir -p the gate dir, then no origin refuses; push=yes
#     prints its push; with staging, PR-1 opens and PR-2 is held; PR-1 is
#     proven merged by ancestry (origin's staging, or a local one); a
#     recorded pr1_url asks the forge, --dry-run too (W15 - the gh log shows
#     the view), MERGED opening PR-2 and OPEN, CLOSED, an empty answer or no
#     gh on PATH all holding it (W14); a recorded pr2_url is reported on both
#     paths; ships.env reads as ac_meta_get read it (LAST wins, an empty last
#     value is none, a NUL ends the record, unreadable and a directory read
#     none)
seed11() {
  rec lo 'loc epic/lo push=yes\n'; git -C "$H/home/projects/loc" branch -q epic/lo main; review lo loc epic/lo
  ready x11 proj epic/x11 'proj epic/x11 push=yes staging=st11\n'
  ready x11l proj epic/x11l 'proj epic/x11l staging=st11l\n'; git -C "$H/home/projects/proj" branch -q st11l main
  ready v11 proj epic/v11 'proj epic/v11 staging=st-v11\n'
  ready n11 proj epic/n11 'proj epic/n11\n'
}
both seed11
same lo loc --dry-run
assert_eq "$(shim_err)" "ERROR: epic-ship needs an origin remote on loc - a local-only repo has no PR to open (land it by captain merge instead)" "11: no origin"
X11TIP="$(git -C "$NH/remotes/proj.git" rev-parse epic/x11)"
same x11 proj --dry-run
assert_eq "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/x11:refs/heads/epic/x11
DRY-RUN: gh pr create --base st11 --head epic/x11 --title \"epic(x11): integration -> st11\" (in HOME/home/projects/proj)
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "11: PR-1 opens, PR-2 held"
both on_origin proj st11
same x11 proj --dry-run
assert_eq "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/x11:refs/heads/epic/x11
PR-1 (epic/x11 -> st11) proven merged; opening PR-2
DRY-RUN: gh pr create --base main --head epic/x11 --title \"epic(x11): integration -> main\" (in HOME/home/projects/proj)" "11: ancestry on origin's staging"
same x11l proj --dry-run; assert_contains "$(shim_out)" "PR-1 (epic/x11l -> st11l) proven merged; opening PR-2" "11: ancestry on a local staging"
both ships v11 'pr1_url=https://example.test/pr/1\n'
view_row() {  # view_row <gh state> <stdout line>
  local h; for h in "$OH" "$NH"; do printf -- "$1" >"$h/gh.state"; done
  same v11 proj --dry-run
  assert_contains "$(shim_out)" "$2" "11: gh state '$1'"
  assert_contains "$(norm "$NH/gh.log" "$NH")" "gh pr view https://example.test/pr/1 --json state --jq .state (cwd HOME/home/projects/proj)" "11: W15 - the forge is read in dry-run"
  rm -f "$OH/gh.log" "$NH/gh.log"
}
HELD="PR-1 already open, not merged yet: https://example.test/pr/1 - PR-2 held until it merges"
view_row 'OPEN\n' "$HELD"
view_row 'CLOSED\n' "$HELD"
view_row '' "$HELD"
view_row 'MERGED\n' "PR-1 (epic/v11 -> st-v11) proven merged; opening PR-2
DRY-RUN: gh pr create --base main --head epic/v11"
nopath "$TMP/nogh" gh
ES_PATH="$TMP/nogh"; same v11 proj --dry-run; ES_PATH=""
assert_eq "$(shim_out)" "$HELD" "11: W14 - no gh on PATH holds PR-2"
assert_no_file "$NH/gh.log" "11: no gh, no forge read"
both ships v11 'pr1_url=https://example.test/pr/1\npr2_url=https://example.test/pr/2\n'
same v11 proj --dry-run
assert_eq "$(shim_out)" "PR-1 (epic/v11 -> st-v11) proven merged; production PR already recorded: https://example.test/pr/2" "11: merged with PR-2 recorded"
rm -f "$OH/gh.state" "$NH/gh.state" "$OH/gh.log" "$NH/gh.log"
N11OPEN='DRY-RUN: gh pr create --base main --head epic/n11 --title "epic(n11): integration -> main" (in HOME/home/projects/proj)'
slot_row() {  # slot_row <ships.env bytes> <stdout>
  both ships n11 "$1"
  same n11 proj --dry-run
  assert_eq "$(shim_out)" "$2" "11: ships.env '$1'"
}
slot_row 'pr2_url=https://example.test/pr/2\n' "production PR already recorded: https://example.test/pr/2"
slot_row 'pr2_url=https://a\npr2_url=https://b\n' "production PR already recorded: https://b"
slot_row 'pr2_url=https://a\npr2_url=\n' "$N11OPEN"
slot_row 'pr1_url=https://one\npr2_url_x=https://x\n' "$N11OPEN"
slot_row 'pr2_url=https://a\0junk\n' "production PR already recorded: https://a"
slot_row 'pr2_url=https://a\npr2_url\0junk\n' "$N11OPEN"
slot_row 'pr2_url=https://cr\r\n' "production PR already recorded: https://cr$(printf '\r')"
if [ "$(id -u)" != 0 ]; then
  both ships n11 'pr2_url=https://example.test/pr/2\n'
  chmod 000 "$OH/home/data/n11/gate/ships.env" "$NH/home/data/n11/gate/ships.env"
  pair n11 proj --dry-run
  chmod 644 "$OH/home/data/n11/gate/ships.env" "$NH/home/data/n11/gate/ships.env"
  same_io "unreadable ships.env"
  assert_eq "$(shim_out)" "$N11OPEN" "11: W13 - an unreadable ships.env reads none"
fi
rm -f "$OH/home/data/n11/gate/ships.env" "$NH/home/data/n11/gate/ships.env"
mkdir "$OH/home/data/n11/gate/ships.env" "$NH/home/data/n11/gate/ships.env"
same n11 proj --dry-run; assert_eq "$(shim_out)" "$N11OPEN" "11: a ships.env directory reads none"
rmdir "$OH/home/data/n11/gate/ships.env" "$NH/home/data/n11/gate/ships.env"

# 15. a symlinked AC_HOME - W16, NAMED (the HOME RESOLUTION ruling): the
#     original joined projects/<repo> onto AC_HOME as spelled, so the clone
#     reads HOME/link in the DRY-RUN lines and the review command's --repo;
#     the port binds the home physically; the data paths were physical on
#     both sides
ln -s home "$OH/link"; ln -s home "$NH/link"
HOMELESS=1; ES_ENV=(AC_HOME=HOME/link)
pair x11 proj --dry-run
assert_eq "$O_RC $N_RC" "0 0" "15: W16 - both pass the gate"
assert_eq "$(cat "$TMP/o.out")" "$(sed 's#HOME/home/#HOME/link/#' "$TMP/n.out")" "15: W16 - the original prints the logical clone path"
assert_contains "$(shim_out)" "push origin refs/heads/epic/x11" "15: W16 named - the port prints the physical one"
assert_contains "$(shim_out)" "(in HOME/home/projects/proj)" "15: W16 named - the port's gh line"
rm -f "$OH/home/data/r9/gate/review.json" "$NH/home/data/r9/gate/review.json"
pair r9 proj --dry-run
assert_eq "$O_RC $N_RC" "1 1" "15: W16 - both refuse a missing review"
assert_contains "$(oracle_err)" "--repo HOME/link/projects/proj --ref" "15: W16 - the original's --repo is the logical path"
assert_contains "$(oracle_err)" "--intent HOME/home/data/r9/room.md --output HOME/home/data/r9/gate/review.json" "15: W16 - its data paths are physical"
assert_eq "$(shim_err)" "ERROR: no epic review round on record - run ONE independent round over the whole integration diff first: $RCMD" "15: W16 named - the port's command is physical throughout"
HOMELESS=0; ES_ENV=()
rm -f "$OH/link" "$NH/link"

# 12. the REAL exit, run last because it publishes (scratch origins and the
#     gh stub only). No staging: gh refusing is gh's line then the refusal,
#     exit 1, nothing recorded; then the PR opens - gh run in the clone with
#     the original's argv, its url's trailing blank lines dropped, ships.env
#     appended, the SHIPS: line posted through ac-room.sh (the date stub's
#     stamp) - and the next run reports it. With staging: PR-1 opens and PR-2
#     is held; the forge's OPEN holds it; MERGED opens PR-2; the next run
#     reports it. W12: an EMPTY url is recorded as `pr2_url=` and the next
#     run opens the PR again; a multi-line url is written raw. W13: a
#     ships.env that is a directory reads none and the append fails after the
#     PR opened, exit 1 (bash's own redirection line not reproduced - named).
#     A gh not on PATH is the refusal (bash's own `command not found` line
#     not reproduced - named). A url gh printed that is not UTF-8 stays raw
#     bytes in stdout and ships.env while both sides post the same U+FFFD
#     spelling through the landed room entry.
seed12() {
  ready e12 proj epic/e12 'proj epic/e12\n'
  ready e12s proj epic/e12s 'proj epic/e12s staging=st12\n'
  ready e12e proj epic/e12e 'proj epic/e12e\n'
  ready e12m proj epic/e12m 'proj epic/e12m\n'
  ready e12z proj epic/e12z 'proj epic/e12z\n'; mkdir -p "$H/home/data/e12z/gate/ships.env"
  ready e12g proj epic/e12g 'proj epic/e12g\n'
  ready e12u proj epic/e12u 'proj epic/e12u\n'
  ready e18 proj epic/e18 'proj epic/e18\n'
  ready e12x proj epic/e12x 'proj epic/e12x\n'
}
both seed12
E12TIP="$(git -C "$NH/remotes/proj.git" rev-parse epic/e12)"
touch "$OH/gh.fail" "$NH/gh.fail"
same e12 proj
assert_eq "$N_RC" 1 "12: gh refusing exits 1"
assert_eq "$(shim_err)" "gh: the stub refuses
ERROR: gh pr create failed for epic/e12 -> main" "12: gh's line, then the refusal"
assert_no_file "$NH/home/data/e12/gate/ships.env" "12: nothing recorded"
rm -f "$OH/gh.fail" "$NH/gh.fail"
same e12 proj
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "12: the PR opened"
assert_eq "$(cat "$NH/home/data/e12/gate/ships.env")" "pr2_url=https://example.test/pr/1" "12: the url recorded"
assert_eq "$(cat "$NH/home/data/e12/room.md")" "# Room: e12

- [2026-01-01T00:00:00Z] crewchief> SHIPS: pr2 https://example.test/pr/1 (epic-ship)" "12: the SHIPS: receipt"
assert_contains "$(norm "$NH/gh.log" "$NH")" "gh pr create --base main --head epic/e12 --title epic(e12): integration -> main --body Integration branch \`epic/e12\` of epic \`e12\` -> \`main\`. Opened by ac-epic-ship.sh after the epic gate (stories terminal, review round clean at $E12TIP). The captain merges. (cwd HOME/home/projects/proj)" "12: gh's argv and cwd"
same e12 proj; assert_eq "$(shim_out)" "production PR already recorded: https://example.test/pr/1" "12: idempotent"
same e12s proj
assert_eq "$(shim_out)" "opened pr1: https://example.test/pr/1
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "12: PR-1 opened, PR-2 held"
for h in "$OH" "$NH"; do printf 'OPEN\n' >"$h/gh.state"; done
same e12s proj; assert_eq "$(shim_out)" "PR-1 already open, not merged yet: https://example.test/pr/1 - PR-2 held until it merges" "12: the forge says OPEN"
for h in "$OH" "$NH"; do printf 'MERGED\n' >"$h/gh.state"; done
ES_ENV=(GH_URL=https://example.test/pr/2)
same e12s proj
assert_eq "$(shim_out)" "PR-1 (epic/e12s -> st12) proven merged; opening PR-2
opened pr2: https://example.test/pr/2" "12: the forge says MERGED - PR-2 opens"
same e12s proj
assert_eq "$(shim_out)" "PR-1 (epic/e12s -> st12) proven merged; production PR already recorded: https://example.test/pr/2" "12: and is reported after"
ES_ENV=()
rm -f "$OH/gh.state" "$NH/gh.state"
ES_ENV=(GH_URL=)
same e12e proj
assert_eq "$(shim_out)" "opened pr2: " "12: W12 - an empty url"
assert_eq "$(cat "$NH/home/data/e12e/gate/ships.env")" "pr2_url=" "12: W12 - recorded empty"
ES_ENV=()
same e12e proj
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "12: W12 - so the next run opens it again"
ES_ENV=("GH_URL=$(printf 'https://example.test/pr/a\nhttps://example.test/pr/b')")
same e12m proj
ES_ENV=()
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/a
https://example.test/pr/b" "12: W12 - a multi-line url"
assert_eq "$(cat "$NH/home/data/e12m/gate/ships.env")" "pr2_url=https://example.test/pr/a
https://example.test/pr/b" "12: W12 - written raw"
pair e12z proj
assert_eq "$O_RC $N_RC" "1 1" "12: W13 - an unwritable ships.env exits 1 on both sides"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "12: an unwritable ships.env - stdout differs"
assert_contains "$(oracle_err)" "ships.env: Is a directory" "12: bash's own redirection line on the original"
case "$(shim_err)" in *"Is a directory"*) fail "12: named, not reproduced" ;; esac
assert_contains "$(norm "$NH/gh.log" "$NH")" "--head epic/e12z" "12: W13 - the PR was opened first"
same_world "an unwritable ships.env"
ES_PATH="$TMP/nogh"; pair e12g proj; ES_PATH=""
assert_eq "$O_RC $N_RC" "1 1" "12: no gh - both refuse"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "12: no gh - stdout differs"
assert_contains "$(oracle_err)" "gh: command not found" "12: no gh - bash's own line on the original"
assert_eq "$(tail -n 1 "$TMP/o.err2")" "ERROR: gh pr create failed for epic/e12g -> main" "12: no gh - the original's refusal"
assert_eq "$(shim_err)" "ERROR: gh pr create failed for epic/e12g -> main" "12: no gh - named, the port's refusal alone"
same_world "no gh"
ES_ENV=("GH_URL=$(printf 'https://example.test/pr/\351')")
pair e12u proj
ES_ENV=()
same_io "a url that is not UTF-8"
assert_eq "$(shim_out)" "opened pr2: $(printf 'https://example.test/pr/\351')" "12: the url's bytes printed"
assert_eq "$(cat "$NH/home/data/e12u/gate/ships.env")" "$(printf 'pr2_url=https://example.test/pr/\351')" "12: and recorded"
# the room entry is a module: its argv decoding spells the byte U+FFFD on both sides
assert_contains "$(cat "$OH/home/data/e12u/room.md")" "$(printf 'SHIPS: pr2 https://example.test/pr/\357\277\275 (epic-ship)')" "12: the original's post reached the room decoded"
assert_eq "$(cat "$NH/home/data/e12u/room.md")" "$(cat "$OH/home/data/e12u/room.md")" "12: the port posted the same room line"
rm "$OH/home/data/e12u/room.md" "$NH/home/data/e12u/room.md"
#     An executable gh with no shebang runs under bash, as the shell ran it
NOBANG="$TMP/nobang"; mkdir -p "$NOBANG"
tail -n +2 "$ESTUBS/gh" >"$NOBANG/gh"; chmod +x "$NOBANG/gh"
ES_PATH="$NOBANG:$ESTUBS:$PATH"; same e12x proj; ES_PATH=""
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "12: a gh with no shebang runs under bash"

# 14. W18: --dry-run counts only as the third argument - as the fourth the
#     REAL exit runs
same e18 proj extra --dry-run
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "14: W18 - the real exit ran"

# 13. the real push (push=yes), with the project's pre-push hook: no local
#     branch is git's refspec error and exit; the hook's refusal is git's exit
#     and lines, gh never run; local == origin is `Everything up-to-date` and
#     the PR opens; W11 - a local branch AHEAD of origin publishes the
#     unreviewed commit while the PR body names the reviewed origin tip; a
#     push a signal ends is 128+signal (bash's job line not reproduced -
#     named); the push and gh inherit the caller's stdin
seed13() {
  ready p13n proj epic/p13n 'proj epic/p13n push=yes\n'
  origin_repo hk; ready p13h hk epic/p13h 'hk epic/p13h push=yes\n'
  git -C "$H/home/projects/hk" fetch -q origin; git -C "$H/home/projects/hk" branch -q epic/p13h origin/epic/p13h
  printf '#!/bin/sh\necho "pre-push: refused by the hook" >&2\nexit 1\n' >"$H/home/projects/hk/.git/hooks/pre-push"
  chmod +x "$H/home/projects/hk/.git/hooks/pre-push"
  local p="$H/home/projects/proj" e
  for e in p13e p13a p13s p13i; do ready "$e" proj "epic/$e" "proj epic/$e push=yes\n"; done
  git -C "$p" fetch -q origin
  for e in p13e p13a p13s p13i; do git -C "$p" branch -q "epic/$e" "origin/epic/$e"; done
  commit_on proj epic/p13a unreviewed
}
both seed13
same p13n proj
assert_eq "$N_RC" 1 "13: no local branch - git's exit"
assert_contains "$(shim_err)" "error: src refspec refs/heads/epic/p13n does not match any" "13: git's own line"
same p13h hk
assert_eq "$N_RC" 1 "13: the hook's refusal is git's exit"
assert_contains "$(shim_err)" "pre-push: refused by the hook" "13: the hook's own line"
case "$(shim_err)" in *"ERROR:"*) fail "13: a refused push prints no line of its own: $(shim_err)" ;; esac
[ ! -e "$NH/gh.log" ] || ! /usr/bin/grep -q 'epic/p13h' "$NH/gh.log" || fail "13: gh must not run after a refused push"
same p13e proj
assert_contains "$(shim_err)" "Everything up-to-date" "13: local == origin"
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "13: and the PR opens"
P13ATIP="$(git -C "$NH/remotes/proj.git" rev-parse epic/p13a)"
same p13a proj
assert_eq "$(git -C "$NH/remotes/proj.git" rev-parse epic/p13a)" "$(git -C "$NH/home/projects/proj" rev-parse refs/heads/epic/p13a)" "13: W11 - origin now holds the unreviewed local commit"
[ "$P13ATIP" != "$(git -C "$NH/remotes/proj.git" rev-parse epic/p13a)" ] || fail "13: W11 - the local commit must differ from the reviewed tip"
assert_contains "$(cat "$NH/gh.log")" "review round clean at $P13ATIP)" "13: W11 - the body names the reviewed tip"
SIGGIT="$TMP/siggit"; mkdir -p "$SIGGIT"
printf '#!/bin/sh\ncase " $* " in *" push "*) kill -TERM $$ ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$SIGGIT/git"; chmod +x "$SIGGIT/git"
ES_PATH="$ESTUBS:$SIGGIT:$PATH"; pair p13s proj; ES_PATH=""
assert_eq "$O_RC $N_RC" "143 143" "13: a push ended by TERM is 128+15 on both sides"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "13: a signalled push - stdout differs"
assert_contains "$(oracle_err)" "Terminated: 15" "13: bash's own job line on the original"
assert_eq "$(shim_err)" "" "13: named, not reproduced"
same_world "a signalled push"
INGIT="$TMP/ingit"; mkdir -p "$INGIT"
cat >"$INGIT/git" <<STUB
#!/bin/sh
case " \$* " in *" push "*) IFS= read -r l; printf '%s\\n' "\$l" >>"\$PUSH_LOG" ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$INGIT/git"
printf 'line one for the push\nline two for gh\n' >"$TMP/stdin13"
ES_PATH="$ESTUBS:$INGIT:$PATH"; ES_ENV=(GH_STDIN=1 PUSH_LOG=HOME/push-stdin.log); ES_STDIN="$TMP/stdin13"
same p13i proj
ES_PATH=""; ES_ENV=(); unset ES_STDIN
assert_eq "$(cat "$NH/push-stdin.log")" "line one for the push" "13: the push read the caller's stdin"
assert_contains "$(cat "$NH/gh.log")" "stdin: line two for gh" "13: gh read the rest of it"

pass
