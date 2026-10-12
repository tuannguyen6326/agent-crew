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
for f in bin CLAUDE.md .claude AGENTS.md; do
  [ -L "$AC_HOME/crewdeputies/mate-four/$f" ] || fail "runtime link missing: mate-four/$f"
done
for f in docs tests; do
  [ ! -e "$AC_HOME/crewdeputies/mate-four/$f" ] || fail "$f/ must not be seeded - repo material reads through ac_root"
done
assert_eq "$(cd "$AC_HOME/crewdeputies/mate-four/bin" && pwd -P)" "$(cd "$BIN" && pwd -P)" \
  "the deputy bin link resolves to the distro checkout's bin"

# --- differential: src/home-seed.ts against the frozen bash original ---------
# DISPUTED: the implementation (tests/fixtures/ac-home-seed.sh under bash vs src/home-seed.ts through bin/ac-home-seed.sh)
# HELD-CONSTANT: two parent homes built alike (one make_repo per project, cloned into each), argv, one PATH date stub;
#   stdout, stderr and exit status compared whole with each parent spelled HOME, then the two parents' whole trees
#   (names, kinds, modes, link basenames, file bytes; a clone's origin and HEAD stand in for its .git internals)
# The oracle runs under LC_ALL=C: bash 3.2's launch-* glob order follows libc collation, the port copies in byte
# order - unobservable here, every copy landing under its own basename. Link TARGETS differ by construction (the
# oracle's ac_root is its own copy of bin/, the port's is this checkout), so a link is compared by basename.
obin="$(make_oracle_bin ac-home-seed)"
# The frozen entry calls ac_seed_runtime_links, retired from bin/ac-lib.sh by
# the fleet-new port; the oracle's own lib copy gets the frozen helper back.
cat "$ROOT/tests/fixtures/ac-seed-runtime-links.sh" >>"$obin/ac-lib.sh"
O="$TMP/dh-o"; N="$TMP/dh-n"
mkdir -p "$TMP/stub"
printf '#!/bin/sh\nprintf "2026-01-02T03:04:05Z\\n"\n' >"$TMP/stub/date"
chmod +x "$TMP/stub/date"
DPATH="$TMP/stub:$PATH"
STAMP="2026-01-02T03:04:05Z"

both() { local h; for h in "$O" "$N"; do eval "$1"; done; }
fresh_parents() { rm -rf "$O" "$N"; mkdir -p "$O" "$N"; }
add_clone() {  # add_clone <p> <origin url|none> - one repo, cloned into both parents
  local r h
  r="$(make_repo "dh-$1")"
  for h in "$O" "$N"; do
    mkdir -p "$h/projects"
    git clone --quiet "$r" "$h/projects/$1"
    if [ "$2" = none ]; then git -C "$h/projects/$1" remote remove origin
    else git -C "$h/projects/$1" remote set-url origin "$2"; fi
  done
}
tree() { (cd "$1" && find . -name .git -prune -o -print | LC_ALL=C sort); }
spelled() { LC_ALL=C sed -e "s#$O#HOME#g" -e "s#$N#HOME#g" "$1"; }
same_parents() {  # same_parents <label> - the two parents are alike after a run
  local p o n
  tree "$O" >"$TMP/o.tree"; tree "$N" >"$TMP/n.tree"
  cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "differential tree differs after '$1': $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 6)"
  while IFS= read -r p; do
    if [ -L "$O/$p" ]; then
      assert_eq "$(basename "$(readlink "$N/$p")")" "$(basename "$(readlink "$O/$p")")" "differential link $p after '$1'"
      continue
    fi
    assert_eq "$(stat -f %Lp "$N/$p")" "$(stat -f %Lp "$O/$p")" "differential mode of $p after '$1'"
    [ -f "$O/$p" ] || continue
    # Bytes first; only a file that names its parent is compared spelled HOME.
    cmp -s "$O/$p" "$N/$p" && continue
    spelled "$O/$p" >"$TMP/o.f"; spelled "$N/$p" >"$TMP/n.f"
    cmp -s "$TMP/o.f" "$TMP/n.f" || fail "differential bytes differ at $p after '$1': $(diff "$TMP/o.f" "$TMP/n.f" | head -n 4)"
  done <"$TMP/o.tree"
  for p in $(cd "$O" && find . -type d -name .git | LC_ALL=C sort | sed 's#/\.git$##'); do
    o="$(git -C "$O/$p" remote get-url origin 2>/dev/null | LC_ALL=C sed "s#$O#HOME#g" || true)"
    n="$(git -C "$N/$p" remote get-url origin 2>/dev/null | LC_ALL=C sed "s#$N#HOME#g" || true)"
    assert_eq "$n" "$o" "differential origin of $p after '$1'"
    assert_eq "$(git -C "$N/$p" rev-parse HEAD)" "$(git -C "$O/$p" rev-parse HEAD)" "differential HEAD of $p after '$1'"
  done
}
same() {  # same <args...> - the oracle (parent $O) and the shim (parent $N) answer alike and leave alike parents
  local o_rc=0 n_rc=0
  AC_HOME="$O" PATH="$DPATH" LC_ALL=C "$obin/ac-home-seed.sh" "$@" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  AC_HOME="$N" PATH="$DPATH" "$BIN/ac-home-seed.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  spelled "$TMP/o.out" >"$TMP/o.out.h"; spelled "$TMP/n.out" >"$TMP/n.out.h"
  spelled "$TMP/o.err" >"$TMP/o.err.h"; spelled "$TMP/n.err" >"$TMP/n.err.h"
  cmp -s "$TMP/o.out.h" "$TMP/n.out.h" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out.h" "$TMP/n.out.h" | head -n 4)"
  cmp -s "$TMP/o.err.h" "$TMP/n.err.h" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err.h" "$TMP/n.err.h" | head -n 4)"
  same_parents "$*"
}

# 1. A full parent: clone, every knob, two launch templates, the retired
# workspace knob, CREWMATE.md, captain.md, a bracketed registry line.
fresh_parents
add_clone alpha https://example.test/alpha.git
both 'mkdir -p "$h/config" "$h/records"
  for k in backend crew-harness crew-dispatch.json herdr-session wedge-alarm captain flow promote launch-claude launch-codex herdr-workspace; do
    printf "%s value\n" "$k" >"$h/config/$k"
  done
  printf "FLEET RULES\n" >"$h/CREWMATE.md"
  printf "CAPTAIN: terse.\n" >"$h/records/captain.md"
  printf "# Projects\n\n- alpha [direct-pr] - a project (added 2026-07-13)\n" >"$h/records/projects.md"'
same mate1 --projects alpha
assert_eq "$(cat "$TMP/n.out")" "$N/crewdeputies/mate1" "differential 1: the home path on stdout"
assert_eq "$(cat "$TMP/n.err")" "WARN: seeded crewdeputy home mate1; spawn with: ac-spawn.sh mate1 --crewdeputy
WARN: fill in charter and scope: for mate1 in $N/records/crewdeputies.md - an entry with no scope: is never routed work" \
  "differential 1: both WARN lines"
assert_eq "$(cat "$N/records/crewdeputies.md")" "# Crewdeputies

- mate1 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate1 - scope: - projects: alpha (added $STAMP)" \
  "differential 1: the registry bytes"
assert_eq "$(cat "$N/crewdeputies/mate1/records/projects.md")" "# Projects

- alpha [direct-pr] - a project (added 2026-07-13)" "differential 1: the bracketed line carried"
assert_eq "$(cat "$N/crewdeputies/mate1/records/backlog.md")" "# Backlog

## In flight

## Queued

## Done" "differential 1: the backlog skeleton"
assert_eq "$(git -C "$N/crewdeputies/mate1/projects/alpha" remote get-url origin)" "https://example.test/alpha.git" "differential 1: origin re-pointed"
assert_no_file "$N/crewdeputies/mate1/config/herdr-workspace" "differential 1: the workspace knob is not inherited"
assert_file "$N/crewdeputies/mate1/config/launch-codex" "differential 1: a launch template is inherited"

# 2. The same home again: refused, nothing changed.
same mate1 --no-projects
assert_eq "$(cat "$TMP/n.err")" "ERROR: home already exists: $N/crewdeputies/mate1" "differential 2: the refusal"

# 3. Spaces deleted, empties skipped, order kept; a bracketless and an
# indented parent line are carried verbatim.
add_clone beta https://example.test/beta.git
both 'printf "# Projects\n\n- beta - bracketless (added 2026-07-13)\n  - alpha - indented (added x)\n" >"$h/records/projects.md"'
same mate2 --projects 'beta, alpha ,,'
assert_eq "$(cat "$N/crewdeputies/mate2/records/projects.md")" "# Projects

- beta - bracketless (added 2026-07-13)
  - alpha - indented (added x)" "differential 3: parent lines carried verbatim, in list order"
assert_contains "$(tail -n 1 "$N/records/crewdeputies.md")" "- projects: beta,alpha (added $STAMP)" "differential 3: the clone list"

# 10. --no-projects wins over a --projects beside it.
same mate9 --projects alpha --no-projects
assert_no_file "$N/crewdeputies/mate9/projects/alpha" "differential 10: no clone"
assert_contains "$(tail -n 1 "$N/records/crewdeputies.md")" "- projects: none (added" "differential 10: projects: none"

# 11. A duplicated project: the second clone fails with git's status, the
# home stays partial and unregistered.
same mate10 --projects alpha,alpha
assert_eq "$(cat "$TMP/n.out")|$(cat "$TMP/n.err" | head -c 6)" "|fatal:" "differential 11: empty stdout, git's own stderr"
[ -d "$N/crewdeputies/mate10/projects/alpha/.git" ] || fail "differential 11: the first clone stays"
case "$(cat "$N/records/crewdeputies.md")" in *mate10*) fail "differential 11: a failed seed must not register" ;; esac

# 9. Refusals before any write.
same ''
assert_eq "$(cat "$TMP/n.err")" "ERROR: usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)" "differential 9: empty name"
same
same My_Dep --no-projects
assert_eq "$(cat "$TMP/n.err")" "ERROR: name must be [a-z0-9-]: My_Dep" "differential 9: the charset"
same --no-projects
assert_eq "$(cat "$TMP/n.err")" "ERROR: pass --projects <p1,p2,...> or --no-projects explicitly" "differential 9: a flag as the name passes the charset and fails the decision"
same mate8
same mate8 --projects ''
same mate8 --bogus
assert_eq "$(cat "$TMP/n.err")" "ERROR: unknown argument: --bogus" "differential 9: an unknown word"
# A dangling --projects: the bash died on its own unbound-variable noise (exit
# 1, no ERROR line); the port refuses with the usage line. Exit compared only.
o_rc=0; AC_HOME="$O" PATH="$DPATH" "$obin/ac-home-seed.sh" mate8 --projects >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME="$N" PATH="$DPATH" "$BIN/ac-home-seed.sh" mate8 --projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "differential 9: a dangling --projects, both exit 1"
assert_contains "$(cat "$TMP/o.err")" "unbound variable" "differential 9: the oracle's refusal is bash's own"
assert_eq "$(cat "$TMP/n.err")" "ERROR: usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)" "differential 9: the port's refusal is the usage line"
same_parents "mate8 --projects"
assert_no_file "$N/crewdeputies/mate8" "differential 9: nothing written for a refused seed"

# 14. A knob's mode travels with cp; a launch-* that is a directory is skipped.
both 'chmod 600 "$h/config/backend"; mkdir -p "$h/config/launch-x"'
same mate13 --no-projects
assert_eq "$(stat -f %Lp "$N/crewdeputies/mate13/config/backend")" "600" "differential 14: the copied knob keeps its mode"
assert_no_file "$N/crewdeputies/mate13/config/launch-x" "differential 14: a launch directory is not a template"

# 6. A worktree (.git is a file) is not a clone.
both 'git -C "$h/projects/alpha" worktree add --quiet "$h/projects/wt" >/dev/null 2>&1'
same mate5 --projects wt
assert_eq "$(cat "$TMP/n.err")" "ERROR: parent has no clone at projects/wt" "differential 6: the refusal"
assert_no_file "$N/crewdeputies/mate5" "differential 6: nothing written"

# 6b. `read -ra` has -r: a backslash is literal, so `\alpha` names no clone
#     and both sides refuse it before any write.
same mateesc --projects '\alpha'
assert_eq "$(cat "$TMP/n.err")" 'ERROR: parent has no clone at projects/\alpha' "differential 6b: the backslash is literal, refused as spelled"
assert_no_file "$N/crewdeputies/mateesc" "differential 6b: nothing written"
# 6c. A path spelled with a missing component and `..` is refused by the OS
#     before any write - never folded to the clone it names lexically.
same matedots --projects missing/../alpha
assert_eq "$(cat "$TMP/n.err")" "ERROR: parent has no clone at projects/missing/../alpha" "differential 6c: refused as spelled"
assert_no_file "$N/crewdeputies/matedots" "differential 6c: nothing written"

# 5. A parent clone with no origin: the deputy's clone keeps the parent path.
add_clone delta none
same mate4 --projects delta
assert_eq "$(git -C "$N/crewdeputies/mate4/projects/delta" remote get-url origin)" "$N/projects/delta" "differential 5: origin stays the parent clone"

# 12. Homeless, and a home that cannot be entered. The ONE accepted
# divergence: on a set-but-unenterable AC_HOME the bash printed only cd's own
# noise (`cd: /nonexistent: No such file or directory`, exit 1); the port
# refuses with envHome's line. Exit compared, the port's line pinned.
o_rc=0; AC_HOME= PATH="$DPATH" "$obin/ac-home-seed.sh" mate11 --no-projects >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME= PATH="$DPATH" "$BIN/ac-home-seed.sh" mate11 --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "differential 12: homeless, both refuse"
cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential 12: homeless refusal differs: $(diff "$TMP/o.err" "$TMP/n.err")"
assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" \
  "differential 12: the homeless refusal bytes"
o_rc=0; AC_HOME=/nonexistent PATH="$DPATH" "$obin/ac-home-seed.sh" mate11 --no-projects >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME=/nonexistent PATH="$DPATH" "$BIN/ac-home-seed.sh" mate11 --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "differential 12: an unenterable home, both refuse"
assert_contains "$(cat "$TMP/o.err")" "cd: /nonexistent" "differential 12: the oracle's refusal is cd's own"
assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not a readable directory: /nonexistent" "differential 12: the port's refusal names the home"
assert_eq "$(cat "$TMP/o.out")$(cat "$TMP/n.out")" "" "differential 12: nothing on stdout"

# 13. No git on PATH: refused before any argument is read (the name is bad too).
# Only what the two entries need up to that refusal is on the PATH.
mkdir -p "$TMP/nogit"
for t in bash dirname bun; do ln -s "$(command -v "$t")" "$TMP/nogit/$t"; done
o_rc=0; AC_HOME="$O" PATH="$TMP/stub:$TMP/nogit" "$obin/ac-home-seed.sh" My_Dep --no-projects >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; AC_HOME="$N" PATH="$TMP/stub:$TMP/nogit" "$BIN/ac-home-seed.sh" My_Dep --no-projects >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "differential 13: no git, both refuse"
cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential 13: refusal differs: $(diff "$TMP/o.err" "$TMP/n.err")"
assert_eq "$(cat "$TMP/n.err")" "ERROR: required tool not found: git" "differential 13: the refusal bytes"
same_parents "no git"

# 4. A parent with no records/ at all: minted, and the unregistered project
# gets the default line with the stubbed stamp.
fresh_parents
add_clone gamma none
same mate3 --projects gamma
assert_eq "$(cat "$N/crewdeputies/mate3/records/projects.md")" "# Projects

- gamma - inherited from parent (added $STAMP)" "differential 4: the default line"
[ -d "$N/records" ] || fail "differential 4: records/ minted on the parent"

# 7. A bare parent: registry created with its header; nothing to inherit.
fresh_parents
same mate6 --no-projects
assert_eq "$(cat "$N/records/crewdeputies.md")" "# Crewdeputies

- mate6 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate6 - scope: - projects: none (added $STAMP)" \
  "differential 7: header and line"
assert_no_file "$N/crewdeputies/mate6/CREWMATE.md" "differential 7: no CREWMATE.md to inherit"
assert_no_file "$N/crewdeputies/mate6/records/captain.md" "differential 7: no captain.md to inherit"
assert_eq "$(ls -A "$N/crewdeputies/mate6/config")" "" "differential 7: config/ empty"

# 8. An existing registry is appended to, its header never re-written.
both 'printf -- "- other - charter - home: /x - scope: s - projects: none (added 2026-01-01)\n" >"$h/records/crewdeputies.md"'
same mate7 --no-projects
assert_eq "$(cat "$N/records/crewdeputies.md")" "- other - charter - home: /x - scope: s - projects: none (added 2026-01-01)
- mate7 - (charter unset - one line on what this crewdeputy is for) - home: $N/crewdeputies/mate7 - scope: - projects: none (added $STAMP)" \
  "differential 8: appended, no header"

pass
