#!/usr/bin/env bash
# ac-epic-ship.test.sh - the epic gate + 2-PR exit (bin/ac-epic-ship.sh, spec
# in the header of src/epic-ship.ts): usage,
# the fence, the record parse, verify's delegate, story terminality and the
# partial-epic receipts, the review round at origin's tip, the qa pin, and
# the exit - dry-run and real, against scratch bare origins and a PATH gh
# stub only. tests/sh/ac-epic-branch.test.sh holds more black-box rows.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# One side root $H: a home at $H/home whose projects/ clones fetch from bare
# origins under $H/remotes, every commit stamped with one fixed date. Each run
# starts at $H under LC_ALL=C with stdin /dev/null (unless a row feeds a file)
# and PATH stubs: `gh` (logs its argv and cwd; `pr view` prints $H/gh.state;
# `pr create` prints GH_URL or refuses on $H/gh.fail), `date` (one fixed
# instant), `herdr`/`orca` (log, exit 1). `HOME` in an argument or an env value
# is $H, and stdout and stderr are read with $H spelled HOME.
H="$TMP/eside"
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
run() {  # run <args...> - sets rc; stdout in $TMP/n.out, stderr in $TMP/n.err2
  local x v
  local a=() e=(LC_ALL=C "PATH=${ES_PATH:-$ESTUBS:$PATH}" "GH_LOG=$H/gh.log" "GH_FAIL=$H/gh.fail" "GH_STATE=$H/gh.state")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$H/home")
  for x in ${ES_ENV[@]+"${ES_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  rc=0
  (cd "$H" && env -u AC_HOME "${e[@]}" "$BIN/ac-epic-ship.sh" ${a[@]+"${a[@]}"}) <"${ES_STDIN:-/dev/null}" >"$TMP/n.raw" 2>"$TMP/n.err" || rc=$?
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.err" >"$TMP/n.err2"
}
norm() { LC_ALL=C sed -e "s#$H#HOME#g" "$1"; }
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
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
eseed
origin_repo proj
local_repo loc
led ''

# 1. usage, exit 1, before the home: no argument, one, an empty repo or epic;
#    git and jq are required, and a jq that is not executable is no jq
run; assert_eq "$rc" 1 "1: usage exits 1"; assert_eq "$(shim_err)" "$USAGE" "1: no argument"
run e1; assert_eq "$(shim_err)" "$USAGE" "1: one argument"
run e1 ''; assert_eq "$(shim_err)" "$USAGE" "1: an empty repo"
run '' proj; assert_eq "$(shim_err)" "$USAGE" "1: an empty epic"
HOMELESS=1; run; HOMELESS=0
assert_eq "$(shim_err)" "$USAGE" "1: usage precedes the home"
nopath "$TMP/nojq" jq
ES_PATH="$ESTUBS:$TMP/nojq"; run e1 proj --dry-run
assert_eq "$rc" 1 "1: no jq exits 1"
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "1: no jq"
nopath "$TMP/nogit" git
ES_PATH="$ESTUBS:$TMP/nogit"; run e1 proj
assert_eq "$(shim_err)" "ERROR: required tool not found: git" "1: git first"
cp -R "$TMP/nojq" "$TMP/nxjq"; printf 'exit 0\n' >"$TMP/nxjq/jq"; chmod 644 "$TMP/nxjq/jq"
ES_PATH="$ESTUBS:$TMP/nxjq"; run e1 proj; ES_PATH=""
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "1: a non-executable jq is refused as missing"

# 2. homeless: one refusal, exit 1, nothing on stdout - for an epic outside
#    [a-zA-Z0-9_-] too; an AC_HOME cd cannot enter is named once
HOMELESS=1
for e in e1 a.b; do
  run "$e" proj
  assert_eq "$rc" 1 "2: homeless $e exits 1"
  assert_eq "$(shim_out)" "" "2: homeless $e prints nothing on stdout"
  assert_eq "$(shim_err)" "$NOHOME" "2: homeless $e refuses once"
done
ES_ENV=(AC_HOME=HOME/missing)
run e1 proj
assert_eq "$rc" 1 "2: an unenterable home exits 1"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: HOME/missing" "2: an unenterable home is named once"
ES_ENV=()
HOMELESS=0

# 3. the fence: AC_SCOPE refuses before the home is read; an empty AC_SCOPE
#    is no scope
ES_ENV=(AC_SCOPE=x)
run e1 proj --dry-run; assert_eq "$rc" 1 "3: scoped exits 1"; assert_eq "$(shim_err)" "$FENCE" "3: scoped"
HOMELESS=1; run e1 proj; HOMELESS=0
assert_eq "$(shim_err)" "$FENCE" "3: the fence precedes the home"
ES_ENV=(AC_SCOPE=)
run e1 proj --dry-run; assert_eq "$(shim_err)" "$(noentry e1 proj)" "3: an empty AC_SCOPE is unscoped"
ES_ENV=()

# 4. the record: none; retired on its FIRST line only; no entry for the
#    repo; the parse - TAB-separated fields, the first of two staging= keys,
#    `staging=a=b`, push only as the whole token push=yes; an archived record
seed4() {
  rec ret '# retired 2026-01-01T00:00:00Z\nproj epic/ret\n'
  ready ret2 proj epic/ret2 'proj epic/ret2\n# retired 2026-01-01T00:00:00Z\n'
  rec noent 'other epic/noent\n'
  ready tab proj epic/tab 'proj\tepic/tab\tstaging=st-tab\t push=yes\n'
  ready dup proj epic/dup 'proj epic/dup staging=s1 staging=s2\n'
  ready sab proj epic/sab 'proj epic/sab staging=a=b\n'
  ready pyes proj epic/pyes 'proj epic/pyes push=YES\n'
  ready pyn proj epic/pyn 'proj epic/pyn push=yesno xpush=yes\n'
  on_origin proj epic/arc; mkdir -p "$H/home/data/archive/2026/arc"; printf 'proj epic/arc\n' >"$H/home/data/archive/2026/arc/branches"; review arc proj epic/arc
}
seed4
run nosuch proj --dry-run; assert_eq "$(shim_err)" "$(noentry nosuch proj)" "4: no record"
run ret proj --dry-run; assert_eq "$(shim_err)" "ERROR: the ret record is retired - a retired epic has no exit to run" "4: retired"
run ret2 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create --base main --head epic/ret2" "4: a marker on line 2 retires nothing"
run noent proj --dry-run; assert_eq "$(shim_err)" "$(noentry noent proj)" "4: no entry for the repo"
run tab proj --dry-run
assert_eq "$rc" 0 "4: a dry run exits 0"
assert_eq "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/tab:refs/heads/epic/tab
DRY-RUN: gh pr create --base st-tab --head epic/tab --title \"epic(tab): integration -> st-tab\" (in HOME/home/projects/proj)
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "4: TAB-separated fields - push, then PR-1"
run dup proj --dry-run; assert_contains "$(shim_out)" "--base s1 --head epic/dup" "4: the first staging= wins"
run sab proj --dry-run; assert_contains "$(shim_out)" "--base a=b --head epic/sab" "4: staging=a=b"
for e in pyes pyn; do
  run "$e" proj --dry-run
  case "$(shim_out)" in *"DRY-RUN: git"*) fail "4: $e is no push=yes" ;; esac
  assert_contains "$(shim_out)" "DRY-RUN: gh pr create --base main --head epic/$e" "4: $e opens its PR"
done
run arc proj --dry-run; assert_contains "$(shim_out)" "--head epic/arc" "4: an archived record"

# 5. verify: src/epic-branch.ts's refusals and status pass through - the
#    branch absent on an origin repo, absent locally on a local-only repo, no
#    clone at all. The delegate gets this process's environment BYTES: a
#    value holding a byte that is not UTF-8 reaches verify's ls-remote
#    unchanged (a BUN_ name is dropped there, as ac-bun.sh drops it)
seed5() { rec nv 'proj epic/nv\nloc epic/nv\nghost epic/nv\n'; }
seed5
run nv proj --dry-run
assert_eq "$(shim_err)" "ERROR: verify: epic/nv is not on origin of proj - create it (ac-epic-branch.sh create nv proj) before any story spawns against it" "5: not on origin"
run nv loc --dry-run
assert_eq "$(shim_err)" "ERROR: verify: epic/nv does not exist in loc - create it (ac-epic-branch.sh create nv loc) before any story spawns against it" "5: not in a local-only repo"
run nv ghost --dry-run; assert_eq "$(shim_err)" "ERROR: no project clone at projects/ghost" "5: no clone"
REAL_GIT="$(command -v git)"
ENVSTUB="$TMP/eenvstub"; mkdir -p "$ENVSTUB"
cat >"$ENVSTUB/git" <<STUB
#!/bin/sh
case " \$* " in *" ls-remote "*) printf '%s' "\$ES_PROBE" | od -An -tx1 | tr -d ' \\n' >>"\$ES_PROBE_LOG"; printf ' bun=[%s]\\n' "\${BUN_ES_PROBE-unset}" >>"\$ES_PROBE_LOG" ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$ENVSTUB/git"
ES_PATH="$ENVSTUB:$ESTUBS:$PATH"; ES_ENV=("ES_PROBE=$(printf 'a\351b')" "ES_PROBE_LOG=HOME/probe.log" "BUN_ES_PROBE=1")
run ret2 proj --dry-run
ES_PATH=""; ES_ENV=()
assert_eq "$(cat "$H/probe.log")" "61e962 bun=[unset]" "5: the byte intact, the BUN_ name dropped"

# 6. stories, in ledger order, every section: an open story; the epic's own
#    row is no story; open beats partial; partials without a room; a receipt
#    for one partial leaves the other named; the receipts in an archived room
#    pass; rows of another epic, in another case, past a NUL are no stories;
#    an unterminated last line is a row; a byte that is not UTF-8 in prose is
#    one more byte, also under UTF-8
ready s6 proj epic/s6 'proj epic/s6\n'
led '## In flight\n- [ ] s6 [EPIC] - the epic row is no story; epic:s6\n- [ ] s6-a - open; epic:s6\n## Done\n- [x] s6-b - landed; epic:s6\n- [ ] s6-c - open again; epic:s6\n'
run s6 proj --dry-run
assert_eq "$rc" 1 "6: open stories exit 1"
assert_eq "$(shim_err)" "ERROR: epic s6 has non-terminal stories: s6-a s6-c - every story lands (or is failed/abandoned by the captain) before the epic exits" "6: open stories in ledger order"
led '- [x] s6-g [failed] - dead; epic:s6\n- [ ] s6-h - open; epic:s6\n'
run s6 proj --dry-run; assert_contains "$(shim_err)" "non-terminal stories: s6-h -" "6: open beats partial"
PARTIAL="ERROR: partial epic: [failed]/[abandoned] stories need a captain revert-or-keep receipt in the room -"
PTAIL=" - post the GATE:, record the captain's answer as 'DECIDED: epic-ship partial - <story> revert|keep <words>', then re-run"
led '- [x] s6-g [failed] - dead; epic:s6\n- [x] s6-i [abandoned] - dead; epic:s6\n- [ ] s6-j - another epic; epic:s7\n- [ ] s6-k - case; epic:S6\n- [ ] s6-l - prose\0 epic:s6\n- [x] s6 - the epic row closed early; epic:s6\n'
run s6 proj --dry-run
assert_eq "$(shim_err)" "$PARTIAL s6-g s6-i$PTAIL" "6: partials without a room"
room s6 '# Room: s6\n\n- [2026-01-01T00:00:00Z] crewchief> DECIDED: epic-ship partial - s6-g keep (captain word)\n'
run s6 proj --dry-run; assert_eq "$(shim_err)" "$PARTIAL s6-i$PTAIL" "6: a receipt for one partial leaves the other named"
arch_room() { mkdir -p "$H/home/data/archive/2026/s6"; printf -- '- [x] crewchief> DECIDED: epic-ship partial - s6-g keep\n- [x] crewchief> DECIDED: epic-ship partial - s6-i revert\n' >"$H/home/data/archive/2026/s6/room.md"; rm "$H/home/data/s6/room.md"; }
arch_room
run s6 proj --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: the receipts in the archived room pass the gate"
led '- [x] s6-b - landed; epic:s6\n- [ ] s6-u - open, unterminated; epic:s6'
run s6 proj --dry-run; assert_contains "$(shim_err)" "non-terminal stories: s6-u -" "6: an unterminated last line is a row"
led '- [x] s6-b - landed; epic:s6\n> caf\351 reviewed\n'
ES_ENV=(LC_ALL=en_US.UTF-8); run s6 proj --dry-run; ES_ENV=()
assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "6: a byte that is not UTF-8 does not stop the walk under UTF-8"
led ''

# 7. the ledger: missing or unreadable ends the run with exit 2 and nothing
#    printed
w7() {
  run s6 proj --dry-run
  [ ! -f "$H/home/records/backlog.md" ] || chmod 644 "$H/home/records/backlog.md"
  assert_eq "$rc" 2 "7: $1 - exit 2"
  assert_eq "$(shim_out)$(shim_err)" "" "7: $1 - nothing printed"
}
rm -f "$H/home/records/backlog.md"
w7 missing
if [ "$(id -u)" != 0 ]; then
  led '- [ ] s6-a - open; epic:s6\n'
  chmod 000 "$H/home/records/backlog.md"
  w7 unreadable
fi
led ''

# 8. the tip, origin's first: a fetch that fails (a PATH git refusing fetch
#    only, so verify's ls-remote still answers) leaves a branch the clone
#    never saw resolving nowhere, and a local branch standing in for origin's
#    tip
seed8() {
  rec t8 'proj epic/t8\n'; on_origin proj epic/t8
  rec t8b 'proj epic/t8b\n'; on_origin proj epic/t8b 1; git -C "$H/home/projects/proj" branch -q epic/t8b main
  mkdir -p "$H/home/data/t8b/gate"; printf '{"reviewed_ref":"%s"}\n' "$(git -C "$H/home/projects/proj" rev-parse main)" >"$H/home/data/t8b/gate/review.json"
}
seed8
NOFETCH="$TMP/nofetch"; mkdir -p "$NOFETCH"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) exit 1 ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$NOFETCH/git"; chmod +x "$NOFETCH/git"
ES_PATH="$NOFETCH:$ESTUBS:$PATH"
run t8 proj --dry-run
assert_eq "$(shim_err)" "ERROR: branch epic/t8 resolves nowhere in the clone - fetch origin, or create it first" "8: resolves nowhere"
run t8b proj --dry-run; assert_contains "$(shim_out)" "--head epic/t8b" "8: the local branch is the tip when origin's is unknown"
ES_PATH=""
run t8b proj --dry-run; assert_contains "$(shim_err)" "the recorded review round is for ref" "8: once fetched, origin's tip is judged"

# 9. the review round at origin's tip: absent (the command printed whole); a
#    directory is absent; a stale ref; an unparseable record ships nothing;
#    two fixes beside an ask-user
ready r9 proj epic/r9 'proj epic/r9\n'
RTIP="$(git -C "$H/remotes/proj.git" rev-parse epic/r9)"
RCMD="bin/ac-verify.sh codereview --repo HOME/home/projects/proj --ref $RTIP --family r9 --caller <your AC_CREW_ID> --base $RTIP --intent HOME/home/data/r9/room.md --output HOME/home/data/r9/gate/review.json"
rm -f "$H/home/data/r9/gate/review.json"
run r9 proj --dry-run
assert_eq "$rc" 1 "9: no review exits 1"
assert_eq "$(shim_err)" "ERROR: no epic review round on record - run ONE independent round over the whole integration diff first: $RCMD" "9: no review"
mkdir -p "$H/home/data/r9/gate/review.json"
run r9 proj --dry-run; assert_contains "$(shim_err)" "no epic review round on record" "9: a directory is no record"
rmdir "$H/home/data/r9/gate/review.json"
review r9 proj epic/r9 '{"reviewed_ref":"deadbeef"}'
run r9 proj --dry-run
assert_eq "$(shim_err)" "ERROR: the recorded review round is for ref deadbeef, not the current tip $RTIP - the tip moved, run a fresh round: $RCMD" "9: a stale ref"
review r9 proj epic/r9 'not json'
run r9 proj --dry-run
assert_eq "$rc:$(shim_out)" "1:" "9: an unparseable record ships nothing"
review r9 proj epic/r9 '{"reviewed_ref":"TIP","findings":[{"action":"fix"},{"action":"ask-user"},{"action":"fix"}]}'
run r9 proj --dry-run
assert_eq "$(shim_err)" "ERROR: the epic review round left 2 open fix finding(s) - fix on the epic branch (the ref change invalidates the round) and run a fresh round: $RCMD" "9: two fixes beside an ask-user"

# 10. qa, when the epic's OWN row pins qa:yes: an attestation named by the tip
#     passes, one named by a shorter sha or the dot-prefixed in-flight temp
#     does not; a TAB-joined pin gates; the epic row is found by string
#     equality (epic 7 reads its own row, not 07's)
QAREF="ERROR: the epic row pins qa:yes and no crew-qa pass attestation exists for the tip $RTIP - run one behavioral round against the BUILT epic branch (crew-qa skill / bin/ac-qa.sh agent --target $RTIP ...). Note: a ut coverage row qualifies only against a ship TEST RECEIPT minted at this tip - no story run's SHA can stand in (epic-branch-mech M7)"
review r9 proj epic/r9
led '- [ ] r9 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:yes] - the epic (repo: proj)\n'
run r9 proj --dry-run; assert_eq "$(shim_err)" "$QAREF" "10: no attestation"
qa_row() {  # qa_row <name under passed/> <want: pass|refuse>
  mkdir -p "$H/home/projects/proj/.crew/qa/passed"; : >"$H/home/projects/proj/.crew/qa/passed/$1"
  run r9 proj --dry-run
  case "$2" in pass) assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "10: qa $1 passes" ;; *) assert_eq "$(shim_err)" "$QAREF" "10: qa $1 refuses" ;; esac
  rm -rf "$H/home/projects/proj/.crew"
}
qa_row "$RTIP" pass
qa_row "$RTIP.scope.app" pass
qa_row "${RTIP%?}" refuse
qa_row ".$RTIP.tmp" refuse
led '- [ ] r9 [EPIC] [src:cap flow:direct mode:direct-pr rev:no\tqa:yes] - the epic (repo: proj)\n'
run r9 proj --dry-run; assert_eq "$(shim_err)" "$QAREF" "10: a TAB-joined pin"
seed10() {
  ready 7 proj epic/7 'proj epic/7\n'; ready 07 proj epic/07 'proj epic/07\n'
  led '- [ ] 07 [src:cap qa:no] - an earlier row reading as the same number\n- [ ] 7 [src:cap qa:yes] - the numeric epic\n'
}
seed10
run 7 proj --dry-run; assert_contains "$(shim_err)" "no crew-qa pass attestation" "10: epic 7 reads its own row"
run 07 proj --dry-run; assert_contains "$(shim_out)" "--head epic/07" "10: epic 07 reads its own row"
led ''

# 11. the exit, dry: mkdir -p the gate dir, then no origin refuses; push=yes
#     prints its push; with staging, PR-1 opens and PR-2 is held; PR-1 is
#     proven merged by ancestry (origin's staging, or a local one); a
#     recorded pr1_url asks the forge, MERGED opening PR-2 and OPEN holding
#     it; a recorded pr2_url is reported on both paths; in ships.env the LAST
#     line of a key wins, a longer key is another key, a NUL ends the record
seed11() {
  rec lo 'loc epic/lo push=yes\n'; git -C "$H/home/projects/loc" branch -q epic/lo main; review lo loc epic/lo
  ready x11 proj epic/x11 'proj epic/x11 push=yes staging=st11\n'
  ready x11l proj epic/x11l 'proj epic/x11l staging=st11l\n'; git -C "$H/home/projects/proj" branch -q st11l main
  ready v11 proj epic/v11 'proj epic/v11 staging=st-v11\n'
  ready n11 proj epic/n11 'proj epic/n11\n'
}
seed11
run lo loc --dry-run
assert_eq "$(shim_err)" "ERROR: epic-ship needs an origin remote on loc - a local-only repo has no PR to open (land it by captain merge instead)" "11: no origin"
X11TIP="$(git -C "$H/remotes/proj.git" rev-parse epic/x11)"
run x11 proj --dry-run
assert_eq "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/x11:refs/heads/epic/x11
DRY-RUN: gh pr create --base st11 --head epic/x11 --title \"epic(x11): integration -> st11\" (in HOME/home/projects/proj)
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "11: PR-1 opens, PR-2 held"
on_origin proj st11
run x11 proj --dry-run
assert_eq "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/x11:refs/heads/epic/x11
PR-1 (epic/x11 -> st11) proven merged; opening PR-2
DRY-RUN: gh pr create --base main --head epic/x11 --title \"epic(x11): integration -> main\" (in HOME/home/projects/proj)" "11: ancestry on origin's staging"
run x11l proj --dry-run; assert_contains "$(shim_out)" "PR-1 (epic/x11l -> st11l) proven merged; opening PR-2" "11: ancestry on a local staging"
ships v11 'pr1_url=https://example.test/pr/1\n'
view_row() {  # view_row <gh state> <stdout line>
  printf -- "$1" >"$H/gh.state"
  run v11 proj --dry-run
  assert_contains "$(shim_out)" "$2" "11: gh state '$1'"
}
HELD="PR-1 already open, not merged yet: https://example.test/pr/1 - PR-2 held until it merges"
view_row 'OPEN\n' "$HELD"
view_row 'MERGED\n' "PR-1 (epic/v11 -> st-v11) proven merged; opening PR-2
DRY-RUN: gh pr create --base main --head epic/v11"
ships v11 'pr1_url=https://example.test/pr/1\npr2_url=https://example.test/pr/2\n'
run v11 proj --dry-run
assert_eq "$(shim_out)" "PR-1 (epic/v11 -> st-v11) proven merged; production PR already recorded: https://example.test/pr/2" "11: merged with PR-2 recorded"
rm -f "$H/gh.state" "$H/gh.log"
N11OPEN='DRY-RUN: gh pr create --base main --head epic/n11 --title "epic(n11): integration -> main" (in HOME/home/projects/proj)'
slot_row() {  # slot_row <ships.env bytes> <stdout>
  ships n11 "$1"
  run n11 proj --dry-run
  assert_eq "$(shim_out)" "$2" "11: ships.env '$1'"
}
slot_row 'pr2_url=https://example.test/pr/2\n' "production PR already recorded: https://example.test/pr/2"
slot_row 'pr2_url=https://a\npr2_url=https://b\n' "production PR already recorded: https://b"
slot_row 'pr1_url=https://one\npr2_url_x=https://x\n' "$N11OPEN"
slot_row 'pr2_url=https://a\0junk\n' "production PR already recorded: https://a"
rm -f "$H/home/data/n11/gate/ships.env"

# 12. a symlinked AC_HOME: the home is bound physically, so the DRY-RUN lines
#     and the review command's --repo name the physical clone
ln -s home "$H/link"
HOMELESS=1; ES_ENV=(AC_HOME=HOME/link)
run x11 proj --dry-run
assert_eq "$rc" 0 "12: the gate passes under a symlinked home"
assert_contains "$(shim_out)" "DRY-RUN: git -C HOME/home/projects/proj push origin refs/heads/epic/x11" "12: the push names the physical clone"
assert_contains "$(shim_out)" "(in HOME/home/projects/proj)" "12: so does the gh line"
rm -f "$H/home/data/r9/gate/review.json"
run r9 proj --dry-run
assert_eq "$(shim_err)" "ERROR: no epic review round on record - run ONE independent round over the whole integration diff first: $RCMD" "12: the review command is physical throughout"
HOMELESS=0; ES_ENV=()
rm -f "$H/link"

# 13. the REAL exit, run last because it publishes (scratch origins and the
#     gh stub only). No staging: gh refusing is gh's line then the refusal,
#     exit 1, nothing recorded; then the PR opens - gh run in the clone, its
#     url's trailing blank lines dropped, ships.env appended, the SHIPS: line
#     posted through ac-room.sh (the date stub's stamp) - and the next run
#     reports it. With staging: PR-1 opens and PR-2 is held; the forge's OPEN
#     holds it; MERGED opens PR-2; the next run reports it. A gh not on PATH
#     is the refusal. A url gh printed that is not UTF-8 stays raw bytes in
#     stdout and ships.env and reaches the room as U+FFFD.
seed12() {
  ready e12 proj epic/e12 'proj epic/e12\n'
  ready e12s proj epic/e12s 'proj epic/e12s staging=st12\n'
  ready e12g proj epic/e12g 'proj epic/e12g\n'
  ready e12u proj epic/e12u 'proj epic/e12u\n'
  ready e12x proj epic/e12x 'proj epic/e12x\n'
}
seed12
E12TIP="$(git -C "$H/remotes/proj.git" rev-parse epic/e12)"
touch "$H/gh.fail"
run e12 proj
assert_eq "$rc" 1 "13: gh refusing exits 1"
assert_eq "$(shim_err)" "gh: the stub refuses
ERROR: gh pr create failed for epic/e12 -> main" "13: gh's line, then the refusal"
assert_no_file "$H/home/data/e12/gate/ships.env" "13: nothing recorded"
rm -f "$H/gh.fail"
run e12 proj
assert_eq "$rc" 0 "13: the exit exits 0"
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "13: the PR opened"
assert_eq "$(cat "$H/home/data/e12/gate/ships.env")" "pr2_url=https://example.test/pr/1" "13: the url recorded"
assert_eq "$(cat "$H/home/data/e12/room.md")" "# Room: e12

- [2026-01-01T00:00:00Z] crewchief> SHIPS: pr2 https://example.test/pr/1 (epic-ship)" "13: the SHIPS: receipt"
assert_contains "$(norm "$H/gh.log")" "gh pr create --base main --head epic/e12 --title epic(e12): integration -> main --body Integration branch \`epic/e12\` of epic \`e12\` -> \`main\`. Opened by ac-epic-ship.sh after the epic gate (stories terminal, review round clean at $E12TIP). The captain merges. (cwd HOME/home/projects/proj)" "13: gh's argv and cwd"
run e12 proj; assert_eq "$(shim_out)" "production PR already recorded: https://example.test/pr/1" "13: idempotent"
run e12s proj
assert_eq "$(shim_out)" "opened pr1: https://example.test/pr/1
PR-2 (-> main) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)" "13: PR-1 opened, PR-2 held"
printf 'OPEN\n' >"$H/gh.state"
run e12s proj; assert_eq "$(shim_out)" "PR-1 already open, not merged yet: https://example.test/pr/1 - PR-2 held until it merges" "13: the forge says OPEN"
printf 'MERGED\n' >"$H/gh.state"
ES_ENV=(GH_URL=https://example.test/pr/2)
run e12s proj
assert_eq "$(shim_out)" "PR-1 (epic/e12s -> st12) proven merged; opening PR-2
opened pr2: https://example.test/pr/2" "13: the forge says MERGED - PR-2 opens"
run e12s proj
assert_eq "$(shim_out)" "PR-1 (epic/e12s -> st12) proven merged; production PR already recorded: https://example.test/pr/2" "13: and is reported after"
ES_ENV=()
rm -f "$H/gh.state"
nopath "$TMP/nogh" gh
ES_PATH="$TMP/nogh"; run e12g proj; ES_PATH=""
assert_eq "$rc:$(shim_out)" "1:" "13: no gh exits 1 with nothing opened"
assert_eq "$(shim_err)" "ERROR: gh pr create failed for epic/e12g -> main" "13: no gh is the refusal alone"
ES_ENV=("GH_URL=$(printf 'https://example.test/pr/\351')")
run e12u proj
ES_ENV=()
assert_eq "$(shim_out)" "opened pr2: $(printf 'https://example.test/pr/\351')" "13: the url's bytes printed"
assert_eq "$(cat "$H/home/data/e12u/gate/ships.env")" "$(printf 'pr2_url=https://example.test/pr/\351')" "13: and recorded"
# the room entry decodes its argv, so the byte is spelled U+FFFD there
assert_contains "$(cat "$H/home/data/e12u/room.md")" "$(printf 'SHIPS: pr2 https://example.test/pr/\357\277\275 (epic-ship)')" "13: the post reached the room decoded"
#     An executable gh with no shebang runs under bash, as a shell runs it
NOBANG="$TMP/nobang"; mkdir -p "$NOBANG"
tail -n +2 "$ESTUBS/gh" >"$NOBANG/gh"; chmod +x "$NOBANG/gh"
ES_PATH="$NOBANG:$ESTUBS:$PATH"; run e12x proj; ES_PATH=""
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "13: a gh with no shebang runs under bash"

# 14. the real push (push=yes), with the project's pre-push hook: no local
#     branch is git's failure and exit, gh never run; the hook's refusal is
#     git's exit and lines, gh never run; local == origin pushes nothing new
#     and the PR opens; a push a signal ends is 128+signal; the push and gh
#     inherit the caller's stdin
seed13() {
  ready p13n proj epic/p13n 'proj epic/p13n push=yes\n'
  origin_repo hk; ready p13h hk epic/p13h 'hk epic/p13h push=yes\n'
  git -C "$H/home/projects/hk" fetch -q origin; git -C "$H/home/projects/hk" branch -q epic/p13h origin/epic/p13h
  printf '#!/bin/sh\necho "pre-push: refused by the hook" >&2\nexit 1\n' >"$H/home/projects/hk/.git/hooks/pre-push"
  chmod +x "$H/home/projects/hk/.git/hooks/pre-push"
  local p="$H/home/projects/proj" e
  for e in p13e p13s p13i; do ready "$e" proj "epic/$e" "proj epic/$e push=yes\n"; done
  git -C "$p" fetch -q origin
  for e in p13e p13s p13i; do git -C "$p" branch -q "epic/$e" "origin/epic/$e"; done
}
seed13
run p13n proj
assert_eq "$rc" 1 "14: no local branch - git's exit"
case "$(shim_err)" in *"ERROR:"*) fail "14: a failed push prints no line of its own: $(shim_err)" ;; esac
case "$(cat "$H/gh.log")" in *epic/p13n*) fail "14: gh must not run after a failed push" ;; esac
run p13h hk
assert_eq "$rc" 1 "14: the hook's refusal is git's exit"
assert_contains "$(shim_err)" "pre-push: refused by the hook" "14: the hook's own line"
case "$(shim_err)" in *"ERROR:"*) fail "14: a refused push prints no line of its own: $(shim_err)" ;; esac
case "$(cat "$H/gh.log")" in *epic/p13h*) fail "14: gh must not run after a refused push" ;; esac
run p13e proj
assert_eq "$(shim_out)" "opened pr2: https://example.test/pr/1" "14: local == origin - the PR opens"
SIGGIT="$TMP/siggit"; mkdir -p "$SIGGIT"
printf '#!/bin/sh\ncase " $* " in *" push "*) kill -TERM $$ ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$SIGGIT/git"; chmod +x "$SIGGIT/git"
ES_PATH="$ESTUBS:$SIGGIT:$PATH"; run p13s proj; ES_PATH=""
assert_eq "$rc" 143 "14: a push ended by TERM is 128+15"
assert_eq "$(shim_out)$(shim_err)" "" "14: a signalled push prints nothing"
INGIT="$TMP/ingit"; mkdir -p "$INGIT"
cat >"$INGIT/git" <<STUB
#!/bin/sh
case " \$* " in *" push "*) IFS= read -r l; printf '%s\\n' "\$l" >>"\$PUSH_LOG" ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$INGIT/git"
printf 'line one for the push\nline two for gh\n' >"$TMP/stdin13"
ES_PATH="$ESTUBS:$INGIT:$PATH"; ES_ENV=(GH_STDIN=1 PUSH_LOG=HOME/push-stdin.log); ES_STDIN="$TMP/stdin13"
run p13i proj
ES_PATH=""; ES_ENV=(); unset ES_STDIN
assert_eq "$(cat "$H/push-stdin.log")" "line one for the push" "14: the push read the caller's stdin"
assert_contains "$(cat "$H/gh.log")" "stdin: line two for gh" "14: gh read the rest of it"

pass
