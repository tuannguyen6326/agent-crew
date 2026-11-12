#!/usr/bin/env bash
# ac-home-seed.test.sh - crewdeputy home provisioning: structure, config
# inheritance, project clones with origin re-pointing, registry lines,
# duplicate/missing-project refusals.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Parent fleet: one project clone, some config, fleet CREWMATE.md.
repo="$(make_repo alpha)"
git -C "$repo" remote add origin https://example.test/alpha.git
git clone --quiet "$repo" "$AC_HOME/projects/alpha"
git -C "$AC_HOME/projects/alpha" remote set-url origin https://example.test/alpha.git
printf 'herdr\n' >"$AC_HOME/config/backend"
printf 'codex\n' >"$AC_HOME/config/crew-harness"
printf 'lab\n' >"$AC_HOME/config/herdr-session"
printf 'wPARENT\n' >"$AC_HOME/config/herdr-workspace"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
printf '# Projects\n\n- alpha [direct-pr] - a project (added 2026-07-13)\n' >"$AC_HOME/records/projects.md"

home="$("$BIN/ac-home-seed.sh" mate1 --projects alpha 2>/dev/null)"
assert_eq "$home" "$AC_HOME/crewdeputies/mate1" "prints the home path"
for d in state data config projects; do
  [ -d "$home/$d" ] || fail "missing $d/ in seeded home"
done
assert_eq "$(cat "$home/config/backend")" "herdr" "backend inherited"
assert_eq "$(cat "$home/config/crew-harness")" "codex" "crew-harness inherited"
assert_eq "$(cat "$home/config/herdr-session")" "lab" "herdr-session inherited (the herdr server session is shared)"
assert_no_file "$home/config/herdr-workspace" "herdr-workspace NOT inherited - a workspace id is fleet-specific, the crewdeputy owns its own group"
assert_eq "$(cat "$home/CREWMATE.md")" "FLEET RULES" "CREWMATE.md inherited"
assert_file "$home/.ac-crewdeputy-home" "crewdeputy marker for the turn-end guard"
[ -d "$home/projects/alpha/.git" ] || fail "project not cloned into home"
assert_eq "$(git -C "$home/projects/alpha" remote get-url origin)" "https://example.test/alpha.git" "origin re-pointed to real remote"
assert_contains "$(cat "$home/records/projects.md")" "- alpha [direct-pr]" "registry line carried over"
# Registered with the parent in the v2 routing-table grammar: the line its own
# parser accepts, carrying a charter placeholder and an EMPTY scope - seeding
# cannot know the scope, and a scopeless entry is never routable.
rec="$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_deputy_parse '$AC_HOME/records/crewdeputies.md'" \
  | awk -F'\t' '$2 == "mate1"')"
assert_eq "$(printf '%s\n' "$rec" | cut -f1)" "VALID" "the seeded line parses as VALID"
assert_eq "$(printf '%s\n' "$rec" | cut -f3)" "$home" "the seeded line records the home"
assert_eq "$(printf '%s\n' "$rec" | cut -f5)" "" "the seeded line has NO scope - not routable until the chief fills it in"
assert_eq "$(printf '%s\n' "$rec" | cut -f6)" "alpha" "the seeded line carries the clone list"
[ -n "$(printf '%s\n' "$rec" | cut -f4)" ] || fail "the seeded line needs a charter placeholder to be well-formed"
# The parent had no records/captain.md when mate1 was seeded, so mate1 gets
# none - a crewdeputy without recorded style starts clean, like a fresh fleet.
assert_no_file "$home/records/captain.md" "no captain.md seeded when the parent has none"

# Captain style IS seed-copied when the parent records it: the crewdeputy's
# captain-facing prose should match the fleet voice from turn one.
printf 'CAPTAIN: TN. Style: terse, no hedging.\n' >"$AC_HOME/records/captain.md"
caphome="$("$BIN/ac-home-seed.sh" mate-cap --no-projects 2>/dev/null)"
assert_eq "$(cat "$caphome/records/captain.md")" "CAPTAIN: TN. Style: terse, no hedging." \
  "parent captain.md seed-copied into the crewdeputy"

# Seeding SAYS the line is not routable yet - a silently scopeless deputy would
# just never be picked at intake, with nothing on screen explaining why.
err="$("$BIN/ac-home-seed.sh" mate-scope --no-projects 2>&1 >/dev/null)"
assert_contains "$err" "scope:" "seeding names the field the chief must fill in"
assert_eq "$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_deputy_parse '$AC_HOME/records/crewdeputies.md'" \
  | awk -F'\t' '$2 == "mate-scope" { print $6 }')" "none" "a clone-less deputy records projects: none"

# Refusals: duplicate home, unknown project, no explicit projects decision.
assert_fails "$BIN/ac-home-seed.sh" mate1 --no-projects
assert_fails "$BIN/ac-home-seed.sh" mate2 --projects nosuch
assert_fails "$BIN/ac-home-seed.sh" mate2

# The registry bracket is optional (bin/ac-project-mode.sh header): a
# bracketless parent line is carried as written, and a project the parent never
# registered gets a bracketless line - never a minted legacy mode.
for p in beta gamma; do
  git clone --quiet "$(make_repo "$p")" "$AC_HOME/projects/$p"
done
printf '# Projects\n\n- beta - a bracketless project (added 2026-07-13)\n' >"$AC_HOME/records/projects.md"
bhome="$("$BIN/ac-home-seed.sh" mate-bare --projects beta,gamma 2>/dev/null)"
breg="$(cat "$bhome/records/projects.md")"
assert_contains "$breg" "- beta - a bracketless project (added 2026-07-13)" "a bracketless parent line is carried as written"
assert_contains "$breg" "- gamma - inherited from parent" "an unregistered project gets a bracketless line"
case "$breg" in *"[crew-ship]"*) fail "seeding must never mint a legacy delivery mode" ;; esac

# --no-projects seeds an empty-projects home.
"$BIN/ac-home-seed.sh" mate3 --no-projects >/dev/null 2>&1
[ -d "$AC_HOME/crewdeputies/mate3/projects" ] || fail "mate3 projects dir missing"

# Mint-side grammar is [a-z0-9-] - a deputy name IS an ac-spawn id (spawned
# afterwards with `ac-spawn.sh <name> --crewdeputy`), so the same tightened
# charset as ac-brief.sh/ac-spawn.sh applies here: underscore and uppercase
# must die immediately, naming [a-z0-9-], with no home directory created.
err="$("$BIN/ac-home-seed.sh" my_deputy --no-projects 2>&1 || true)"
assert_contains "$err" "name must be [a-z0-9-]" "underscore name refused, naming the tightened charset"
assert_no_file "$AC_HOME/crewdeputies/my_deputy" "no home created for a refused name"
err="$("$BIN/ac-home-seed.sh" MyDeputy --no-projects 2>&1 || true)"
assert_contains "$err" "name must be [a-z0-9-]" "uppercase name refused, naming the tightened charset"
assert_no_file "$AC_HOME/crewdeputies/MyDeputy" "no home created for a refused name"

# A valid lowercase-hyphen name still seeds (no regression in the happy path).
"$BIN/ac-home-seed.sh" mate-four --no-projects >/dev/null 2>&1
[ -d "$AC_HOME/crewdeputies/mate-four" ] || fail "mate-four home missing"

# Runtime symlinks: a deputy chief also runs with cwd = its home, so the seed
# links the distro runtime set there too; the seeded CREWMATE.md copy (a real
# file) must never be replaced by a link.
for f in bin CLAUDE.md .claude AGENTS.md .agents; do
  [ -L "$AC_HOME/crewdeputies/mate-four/$f" ] || fail "runtime link missing: mate-four/$f"
done
for f in docs tests; do
  [ ! -e "$AC_HOME/crewdeputies/mate-four/$f" ] || fail "$f/ must not be seeded - repo material reads through ac_root"
done
assert_eq "$(cd "$AC_HOME/crewdeputies/mate-four/bin" && pwd -P)" "$(cd "$BIN" && pwd -P)" \
  "the deputy bin link resolves to the distro checkout's bin"

# --- the seed's bytes, parent by parent -----------------------------------------
# Each row seeds from a parent home built for it ($N), under one PATH date stub
# so every stamp is $STAMP.
N="$TMP/dh-n"
mkdir -p "$TMP/stub"
printf '#!/bin/sh\nprintf "2026-01-02T03:04:05Z\\n"\n' >"$TMP/stub/date"
chmod +x "$TMP/stub/date"
DPATH="$TMP/stub:$PATH"
STAMP="2026-01-02T03:04:05Z"
USAGE="ERROR: usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)"

fresh_parent() { rm -rf "$N"; mkdir -p "$N"; }
add_clone() {  # add_clone <p> <origin url|none> - one repo, cloned into the parent
  mkdir -p "$N/projects"
  git clone --quiet "$(make_repo "dh-$1")" "$N/projects/$1"
  if [ "$2" = none ]; then git -C "$N/projects/$1" remote remove origin
  else git -C "$N/projects/$1" remote set-url origin "$2"; fi
}
tree() { (cd "$N" && find . -name .git -prune -o -print | LC_ALL=C sort); }
S_RC=0
seed() {  # seed <args...> - the shim on parent $N; sets S_RC, keeps the parent's tree from before the run
  tree >"$TMP/n.before"
  S_RC=0
  AC_HOME="$N" PATH="$DPATH" "$BIN/ac-home-seed.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || S_RC=$?
}
refused() {  # refused <stderr> <label> - exit 1, no stdout, exactly <stderr>, the parent untouched
  assert_eq "$S_RC:$(cat "$TMP/n.out"):$(cat "$TMP/n.err")" "1::$1" "$2"
  assert_eq "$(tree)" "$(cat "$TMP/n.before")" "$2: nothing written"
}
seeded() {  # seeded <name> <label> - exit 0, the home path on stdout, both WARN lines
  assert_eq "$S_RC:$(cat "$TMP/n.out")" "0:$N/crewdeputies/$1" "$2: the home path on stdout"
  assert_eq "$(cat "$TMP/n.err")" "WARN: seeded crewdeputy home $1; spawn with: ac-spawn.sh $1 --crewdeputy
WARN: fill in charter and scope: for $1 in $N/records/crewdeputies.md - an entry with no scope: is never routed work" \
    "$2: both WARN lines"
}

# 1. A full parent: clone, every knob, two launch templates, the retired
# workspace knob, CREWMATE.md, captain.md, a bracketed registry line.
fresh_parent
add_clone alpha https://example.test/alpha.git
mkdir -p "$N/config" "$N/records"
KNOBS="backend crew-harness crew-dispatch.json herdr-session wedge-alarm captain flow promote launch-claude launch-codex"
for k in $KNOBS herdr-workspace; do
  printf "%s value\n" "$k" >"$N/config/$k"
done
printf "FLEET RULES\n" >"$N/CREWMATE.md"
printf "CAPTAIN: terse.\n" >"$N/records/captain.md"
printf "# Projects\n\n- alpha [direct-pr] - a project (added 2026-07-13)\n" >"$N/records/projects.md"
seed mate1 --projects alpha
seeded mate1 "seed 1"
assert_eq "$(cat "$N/records/crewdeputies.md")" "# Crewdeputies

- mate1 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate1 - scope: - projects: alpha (added $STAMP)" \
  "seed 1: the registry bytes"
assert_eq "$(cat "$N/crewdeputies/mate1/records/projects.md")" "# Projects

- alpha [direct-pr] - a project (added 2026-07-13)" "seed 1: the bracketed line carried"
assert_eq "$(cat "$N/crewdeputies/mate1/records/backlog.md")" "# Backlog

## In flight

## Queued

## Done" "seed 1: the backlog skeleton"
assert_eq "$(git -C "$N/crewdeputies/mate1/projects/alpha" remote get-url origin)" "https://example.test/alpha.git" "seed 1: origin re-pointed"
assert_eq "$(git -C "$N/crewdeputies/mate1/projects/alpha" rev-parse HEAD)" "$(git -C "$N/projects/alpha" rev-parse HEAD)" "seed 1: the clone is at the parent's HEAD"
assert_eq "$(ls -A "$N/crewdeputies/mate1/config" | tr '\n' ' ')" "$(printf '%s\n' $KNOBS | LC_ALL=C sort | tr '\n' ' ')" "seed 1: every knob and launch template inherited, the workspace knob not"
for k in $KNOBS; do
  assert_eq "$(cat "$N/crewdeputies/mate1/config/$k")" "$k value" "seed 1: $k copied whole"
done
assert_eq "$(cat "$N/crewdeputies/mate1/CREWMATE.md"):$(cat "$N/crewdeputies/mate1/records/captain.md")" "FLEET RULES:CAPTAIN: terse." "seed 1: CREWMATE.md and captain.md seed-copied"

# 2. The same home again: refused, nothing changed.
seed mate1 --no-projects
refused "ERROR: home already exists: $N/crewdeputies/mate1" "seed 2: an existing home"

# 3. Spaces deleted, empties skipped, order kept; a bracketless and an
# indented parent line are carried verbatim.
add_clone beta https://example.test/beta.git
printf "# Projects\n\n- beta - bracketless (added 2026-07-13)\n  - alpha - indented (added x)\n" >"$N/records/projects.md"
seed mate2 --projects 'beta, alpha ,,'
seeded mate2 "seed 3"
assert_eq "$(cat "$N/crewdeputies/mate2/records/projects.md")" "# Projects

- beta - bracketless (added 2026-07-13)
  - alpha - indented (added x)" "seed 3: parent lines carried verbatim, in list order"
assert_contains "$(tail -n 1 "$N/records/crewdeputies.md")" "- projects: beta,alpha (added $STAMP)" "seed 3: the clone list"

# 4. --no-projects wins over a --projects beside it.
seed mate9 --projects alpha --no-projects
seeded mate9 "seed 4"
assert_no_file "$N/crewdeputies/mate9/projects/alpha" "seed 4: no clone"
assert_contains "$(tail -n 1 "$N/records/crewdeputies.md")" "- projects: none (added" "seed 4: projects: none"

# 5. A duplicated project: the second clone fails with git's status, the
# home stays partial and unregistered.
seed mate10 --projects alpha,alpha
assert_eq "$S_RC:$(cat "$TMP/n.out")" "128:" "seed 5: git's status, empty stdout"
[ -s "$TMP/n.err" ] || fail "seed 5: git's own stderr passes through"
[ -d "$N/crewdeputies/mate10/projects/alpha/.git" ] || fail "seed 5: the first clone stays"
case "$(cat "$N/records/crewdeputies.md")" in *mate10*) fail "seed 5: a failed seed must not register" ;; esac

# 6. Refusals before any write.
seed ''
refused "$USAGE" "seed 6: empty name"
seed
refused "$USAGE" "seed 6: no name"
seed My_Dep --no-projects
refused "ERROR: name must be [a-z0-9-]: My_Dep" "seed 6: the charset"
seed --no-projects
refused "ERROR: pass --projects <p1,p2,...> or --no-projects explicitly" "seed 6: a flag as the name passes the charset and fails the decision"
seed mate8
refused "ERROR: pass --projects <p1,p2,...> or --no-projects explicitly" "seed 6: no projects decision"
seed mate8 --projects ''
refused "ERROR: pass --projects <p1,p2,...> or --no-projects explicitly" "seed 6: an empty --projects"
seed mate8 --bogus
refused "ERROR: unknown argument: --bogus" "seed 6: an unknown word"
seed mate8 --projects
refused "$USAGE" "seed 6: a dangling --projects"

# 7. A knob's mode travels with cp; a launch-* that is a directory is skipped.
chmod 600 "$N/config/backend"; mkdir -p "$N/config/launch-x"
seed mate13 --no-projects
seeded mate13 "seed 7"
assert_eq "$(stat -f %Lp "$N/crewdeputies/mate13/config/backend")" "600" "seed 7: the copied knob keeps its mode"
assert_no_file "$N/crewdeputies/mate13/config/launch-x" "seed 7: a launch directory is not a template"

# 8. A worktree (.git is a file) is not a clone; a backslash is literal, so
# `\alpha` names no clone; a path spelled with a missing component and `..` is
# refused by the OS - never folded to the clone it names lexically.
git -C "$N/projects/alpha" worktree add --quiet "$N/projects/wt" >/dev/null 2>&1
seed mate5 --projects wt
refused "ERROR: parent has no clone at projects/wt" "seed 8: a worktree"
seed mateesc --projects '\alpha'
refused 'ERROR: parent has no clone at projects/\alpha' "seed 8: the backslash is literal, refused as spelled"
seed matedots --projects missing/../alpha
refused "ERROR: parent has no clone at projects/missing/../alpha" "seed 8: refused as spelled"

# 9. A parent clone with no origin: the deputy's clone keeps the parent path.
add_clone delta none
seed mate4 --projects delta
seeded mate4 "seed 9"
assert_eq "$(git -C "$N/crewdeputies/mate4/projects/delta" remote get-url origin)" "$N/projects/delta" "seed 9: origin stays the parent clone"

# 10. Homeless, and a home that cannot be entered.
n_rc=0; AC_HOME= PATH="$DPATH" "$BIN/ac-home-seed.sh" mate11 --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out"):$(cat "$TMP/n.err")" "1::ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" \
  "seed 10: the homeless refusal"
n_rc=0; AC_HOME=/nonexistent PATH="$DPATH" "$BIN/ac-home-seed.sh" mate11 --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out"):$(cat "$TMP/n.err")" "1::ERROR: AC_HOME is not a readable directory: /nonexistent" "seed 10: an unenterable home is named"

# 11. No git on PATH: refused before any argument is read (the name is bad too).
# Only what the entry needs up to that refusal is on the PATH.
mkdir -p "$TMP/nogit"
for t in bash dirname bun; do ln -s "$(command -v "$t")" "$TMP/nogit/$t"; done
tree >"$TMP/n.before"
S_RC=0; AC_HOME="$N" PATH="$TMP/stub:$TMP/nogit" "$BIN/ac-home-seed.sh" My_Dep --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || S_RC=$?
refused "ERROR: required tool not found: git" "seed 11: no git"

# 12. A parent with no records/ at all: minted, and the unregistered project
# gets the default line with the stubbed stamp.
fresh_parent
add_clone gamma none
seed mate3 --projects gamma
seeded mate3 "seed 12"
assert_eq "$(cat "$N/crewdeputies/mate3/records/projects.md")" "# Projects

- gamma - inherited from parent (added $STAMP)" "seed 12: the default line"
[ -d "$N/records" ] || fail "seed 12: records/ minted on the parent"

# 13. A bare parent: registry created with its header; nothing to inherit.
fresh_parent
seed mate6 --no-projects
seeded mate6 "seed 13"
assert_eq "$(cat "$N/records/crewdeputies.md")" "# Crewdeputies

- mate6 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate6 - scope: - projects: none (added $STAMP)" \
  "seed 13: header and line"
assert_no_file "$N/crewdeputies/mate6/CREWMATE.md" "seed 13: no CREWMATE.md to inherit"
assert_no_file "$N/crewdeputies/mate6/records/captain.md" "seed 13: no captain.md to inherit"
assert_eq "$(ls -A "$N/crewdeputies/mate6/config")" "" "seed 13: config/ empty"

# 14. An existing registry is appended to, its header never re-written.
printf -- "- other - charter - home: /x - scope: s - projects: none (added 2026-01-01)\n" >"$N/records/crewdeputies.md"
seed mate7 --no-projects
seeded mate7 "seed 14"
assert_eq "$(cat "$N/records/crewdeputies.md")" "- other - charter - home: /x - scope: s - projects: none (added 2026-01-01)
- mate7 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate7 - scope: - projects: none (added $STAMP)" \
  "seed 14: appended, no header"

pass
