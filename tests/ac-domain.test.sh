#!/usr/bin/env bash
# ac-domain.test.sh - the crewdomain verb layer (bin/ac-domain.sh). Colocated
# with the script so tests/run-suite.sh --changed maps a change here to exactly
# this file; without it the new script is an unmapped owned file and --changed
# widens to the whole suite.
#
# The registry GRAMMAR is owned by ac-lib.sh's `crewdomain routing table` block
# and tested in tests/ac-lib.test.sh; this file owns the VERBS - what `new`
# creates, what it refuses, and what a mutating verb backs up first.
#
# COEXISTENCE is a property under test here, not a background assumption: a
# crewdomain and a crewdeputy may not share a name, and nothing this script
# writes or backs up ever reaches $AC_HOME/crewdeputies/.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

make_home

dom="$BIN/ac-domain.sh"
dreg="$AC_HOME/records/crewdomains.md"
kreg="$AC_HOME/records/crewdeputies.md"
pkg() { printf '%s/crewdomains/%s\n' "$AC_HOME" "$1"; }

make_clone() {  # make_clone <name> [--no-yaml] - a fleet clone plus its config
  local n="$1"
  git init -q -b main "$AC_HOME/projects/$n"
  [ "${2:-}" = --no-yaml ] || printf 'test: {}\n' >"$AC_HOME/projects/$n.yaml"
}

# The listing of a package, one relative path per line, sorted - the shape
# AC-1.1 pins. `-print` order is filesystem order, so sort is what makes the
# assertion about CONTENT rather than about inode layout.
listing() { (cd "$(pkg "$1")" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort); }

make_clone alpha
make_clone beta

# --- new: the package tree, whole or nothing (AC-1.1, AC-1.5, AC-1.6) --------

"$dom" new payments --scope 'money movement' --charter 'the payments domain' --projects alpha,beta >/dev/null

# THREE members: records/projects.md, CREWMATE.md, projects/. No backlog.md
# (crewdomain-token: rows live in the ONE fleet ledger, stamped), no
# captain.md (P6-v2 - domain standing rules are STANDING (domain:<name>): lines
# in the FLEET records/captain.md) and no learnings.md (P8-v2 - a domainchief
# notes to the fleet ledger with a (domain:<name>) prefix).
assert_eq "$(listing payments)" "$(printf 'CREWMATE.md\nprojects\nprojects/alpha\nprojects/alpha.yaml\nprojects/beta\nprojects/beta.yaml\nrecords\nrecords/projects.md')" \
  "AC-1.1: the package holds exactly its three members - no backlog.md, no captain.md, no learnings.md"

assert_contains "$(cat "$dreg")" "- payments - the payments domain - scope: money movement (added " \
  "new writes the routing line in the three-field grammar"
assert_eq "$(ac_domain_parse "$dreg" | cut -f1)" "VALID" "and the line it writes parses VALID"

# AC-1.6 - the DETAIL file is the domain's view of its projects. `[mode]` and
# the fleet description resolve from records/projects.md and nowhere else.
assert_file "$(pkg payments)/records/projects.md" "AC-1.6: the projects detail file is seeded"
assert_eq "$(grep -c '\[mode\]' "$(pkg payments)/records/projects.md" || true)" "0" \
  "AC-1.6: the detail file carries no [mode] token"

# AC-1.5 - two symlinks per project, and the invariant is RESOLUTION, not the
# link text: a relative link of the wrong depth resolves nowhere, and an
# absolute one is equally valid.
# BSD readlink has no -f, so resolution is measured the way the shell can:
# a directory by cd+pwd -P, a file by python3's realpath (helpers.sh already
# depends on python3 for run_on_tty).
realpath_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
for p in alpha beta; do
  [ -L "$(pkg payments)/projects/$p" ] || fail "AC-1.5: projects/$p is a symlink"
  [ -L "$(pkg payments)/projects/$p.yaml" ] || fail "AC-1.5: projects/$p.yaml is a symlink"
  assert_eq "$(cd "$(pkg payments)/projects/$p" && pwd -P)" \
    "$(cd "$AC_HOME/projects/$p" && pwd -P)" "AC-1.5: projects/$p resolves into the fleet clone"
  assert_eq "$(realpath_of "$(pkg payments)/projects/$p.yaml")" \
    "$(realpath_of "$AC_HOME/projects/$p.yaml")" \
    "AC-1.5: projects/$p.yaml resolves to the fleet pipeline config"
done

# A project the fleet lacks refuses the WHOLE command before any write - the
# fail-closed shape bin/ac-home-seed.sh:47-65 already gives the operator.
assert_fails_with "no clone" -- "$dom" new ghosts --scope s --charter c --projects alpha,nosuch
assert_no_file "$(pkg ghosts)" "AC-1.5: an unknown project leaves no partial package"
assert_eq "$(grep -c 'ghosts' "$dreg" || true)" "0" "and mints no registry line"

# A project with no pipeline config is a SUPPORTED state (AGENTS.md section 4
# calls it a direct-pr case), so the clone link is created alone and said so -
# refusing would make the view un-buildable for it.
make_clone gamma --no-yaml
out="$("$dom" new infra --scope 'infra' --charter 'infra domain' --projects gamma)"
assert_contains "$out" "gamma.yaml" "AC-1.5: a .yaml-less project is called out by name"
[ -L "$(pkg infra)/projects/gamma" ] || fail "AC-1.5: the clone link is still created"
assert_no_file "$(pkg infra)/projects/gamma.yaml" "AC-1.5: and no dangling .yaml link is left behind"

# --no-projects is EXPLICIT - a silent empty view is the wrong default.
assert_fails_with "--projects" -- "$dom" new lonely --scope s --charter c
"$dom" new lonely --scope s --charter c --no-projects >/dev/null
assert_eq "$(listing lonely | grep -c '^projects/' || true)" "0" "--no-projects builds an empty view"

# --- AC-1.7: EIGHT namespaces, checked BEFORE any write ----------------------
# Each refusal names WHICH namespace collided and leaves nothing behind. Two of
# the eight exist only because of coexistence: the features share no file, but
# they share the operator's vocabulary and the chief's routing judgment, and a
# `payments` crewdomain beside a `payments` crewdeputy is a misroute waiting to
# happen.

state_hash() {  # every crewdomain/records file, by name AND content
  (cd "$AC_HOME" && find crewdomains records -type f -exec shasum -a 256 {} + 2>/dev/null \
    | LC_ALL=C sort | shasum -a 256) || true
}
refuses() {  # refuses <name> <needle> <why>
  local before after
  before="$(state_hash)"
  assert_fails_with "$2" -- "$dom" new "$1" --scope s --charter c --projects alpha
  after="$(state_hash)"
  assert_eq "$after" "$before" "AC-1.7: a refused new writes NOTHING ($3)"
}

refuses payments 'crewdomains.md' 'the crewdomain registry id'          # 1
printf '# Crewdeputies\n\n- billing - home: %s/crewdeputies/billing - no projects (added 2026-07-16T09:46:38Z)\n' "$AC_HOME" >"$kreg"
refuses billing 'crewdeputies.md' 'a crewdeputy registry id'            # 2
mkdir -p "$AC_HOME/crewdeputies/legacyhome"
refuses legacyhome 'crewdeputies/' 'an existing crewdeputy home'        # 3
mkdir -p "$(pkg orphanpkg)"
refuses orphanpkg 'crewdomains/' 'the package directory'                # 4
mkdir -p "$AC_HOME/data/taskname"
refuses taskname 'data/' 'a task data dir'                              # 5
printf 'kind=roomchief\n' >"$AC_HOME/state/famname-chief.meta"
refuses famname 'state/' 'a live chief meta'                            # 6
printf '# Backlog\n\n## Queued\n\n- [ ] rowname - a queued row (repo: alpha)\n' >"$AC_HOME/records/backlog.md"
refuses rowname 'backlog.md' 'a backlog id'                             # 7
refuses thing-plan 'reserved' 'a reserved stage suffix'                 # 8

# AC-1.4 (the package inside the reversibility floor) lives with the function it
# constrains, in tests/ac-maintenance-core.test.sh.

# --- assign / unassign: the token stamp, in place (crewdomain-token) ---------

fleet_backlog="$AC_HOME/records/backlog.md"
row_local='- [ ] pay-fix - a local-only row (repo: alpha)'
row_other='- [ ] other-row - untouched (repo: beta)'

reset_backlog() {
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n%s\n%s\n\n## Done\n' "$row_local" "$row_other" \
    >"$fleet_backlog"
}

# AC-5.1 - assign STAMPS the row where it stands: same file, same section,
# same position. Nothing moves - which is the whole refactor.
reset_backlog
out="$("$dom" assign payments pay-fix)"
assert_contains "$out" "backup:" "AC-5.3: assign writes a backup archive before mutating the ledger"
assert_contains "$(cat "$fleet_backlog")" "- [ ] pay-fix - a local-only row; domain:payments (repo: alpha)" \
  "AC-5.1: the row is stamped in place, token before the trailing (repo:) group"
assert_eq "$(grep -n 'pay-fix' "$fleet_backlog" | cut -d: -f1)" \
  "$(grep -n 'other-row' "$fleet_backlog" | cut -d: -f1 | awk '{print $1 - 1}')" \
  "AC-5.1: the row kept its queue position - nothing moved"
assert_contains "$(cat "$fleet_backlog")" "$row_other" "an unnamed row is untouched"

# AC-7.3 - the token changes NO field ac_doneline extracts (and f[domain]
# reads it back - one parser, both directions).
fields() {
  awk "$AC_DONELINE_AWK"'{ ac_doneline($0, f); printf "%s|%s|%s|%s|%s|%s\n", f["id"], f["terminal"], f["epic"], f["blockers"], f["date"], f["verb"] }' <<<"$1"
}
assert_eq "$(fields "$(grep 'pay-fix' "$fleet_backlog")")" "$(fields "$row_local")" \
  "AC-7.3: id/terminal/epic/blockers/date/verb are identical with and without the token"
assert_eq "$(awk "$AC_DONELINE_AWK"'{ ac_doneline($0, f); print f["domain"] }' <<<"$(grep 'pay-fix' "$fleet_backlog")")" \
  "payments" "AC-7.3: and f[domain] reads the stamp back"

# Idempotent per id: a re-assign is a printed no-op, never an error.
before="$(shasum -a 256 <"$fleet_backlog")"
out="$("$dom" assign payments pay-fix)"
assert_contains "$out" "already assigned" "AC-5.5: a re-assign says so"
assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$before" "AC-5.5: and writes nothing"

# A row stamped for ANOTHER domain refuses the whole command - never a steal.
"$dom" new invoices --scope 'invoices' --charter 'the invoices domain' --no-projects >/dev/null
assert_fails_with "unassign it there first" -- "$dom" assign invoices pay-fix
assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$before" "a cross-domain steal writes nothing"

# AC-6.1 - unassign is the exact mirror: the row returns byte-identical, in
# place.
"$dom" unassign payments pay-fix >/dev/null
assert_contains "$(cat "$fleet_backlog")" "$row_local" "AC-6.1: the strip restores the row byte-identical"
assert_eq "$(grep -c 'domain:payments' "$fleet_backlog" || true)" "0" \
  "AC-6.1: a returned row is indistinguishable from one never assigned"

# AC-5.4 - a row carrying a delivery-contract group stamps and strips with the
# contract byte-identical.
row_pinned='- [ ] pin-fix [src:cap mode:direct-pr rev:no] - a pinned row (repo: alpha)'
printf '# Backlog\n\n## In flight\n\n## Queued\n\n%s\n%s\n%s\n\n## Done\n' \
  "$row_local" "$row_other" "$row_pinned" >"$fleet_backlog"
"$dom" assign payments pin-fix >/dev/null
assert_contains "$(cat "$fleet_backlog")" "[src:cap mode:direct-pr rev:no] - a pinned row; domain:payments (repo: alpha)" \
  "AC-5.4: contract untouched, token at position"
"$dom" unassign payments pin-fix >/dev/null
assert_contains "$(cat "$fleet_backlog")" "$row_pinned" "AC-5.4: the pinned row restores byte-identical"

# EPIC rows and blocked-by-named rows are now ASSIGNABLE - the two old
# refusals existed because assign MOVED the row out of the scheduler's file;
# a stamp moves nothing, so their whole ground is gone (live fleet evidence:
# the empty domain backlog was the epic refusal's artifact).
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] big-epic [EPIC] - the epic row (repo: alpha)\n- [ ] story-a - a story; epic:big-epic (repo: alpha)\n- [ ] dependent - waits (repo: alpha) blocked-by: pay-fix - needs it\n%s\n\n## Done\n' "$row_local" >"$fleet_backlog"
"$dom" assign payments big-epic >/dev/null
assert_contains "$(cat "$fleet_backlog")" "- [ ] big-epic [EPIC] - the epic row; domain:payments (repo: alpha)" \
  "the old epic refusal is GONE: an epic row stamps in place"
"$dom" assign payments pay-fix >/dev/null
assert_contains "$(cat "$fleet_backlog")" "a local-only row; domain:payments" \
  "the old blocked-by-dependent refusal is GONE: nothing is stranded because nothing moves"

# STORY INHERITANCE: a story with no token of its own belongs to its epic
# row's domain - queue shows it annotated, the tally counts it.
q="$("$dom" queue payments)"
assert_contains "$q" "big-epic" "queue: the epic row is in the slice"
assert_contains "$q" "story-a - a story; epic:big-epic (repo: alpha) (via epic:big-epic)" \
  "queue: a story INHERITS its epic row's domain, annotated"
assert_contains "$q" "## Queued" "queue: rows are grouped under their section header"
assert_contains "$("$dom" queue payments --ids)" "story-a" "queue --ids prints bare ids"
read -r tq ti td <<EOF
$(ac_domain_tally payments)
EOF
assert_eq "$tq" "3" "tally: epic + inherited story + direct row = 3 queued"

# Refusals leave the ledger byte-unchanged.
refuses_assign() {  # refuses_assign <needle> <why> <id>...
  local needle="$1" why="$2"; shift 2
  local fb
  fb="$(shasum -a 256 <"$fleet_backlog")"
  assert_fails_with "$needle" -- "$dom" assign payments "$@"
  assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$fb" "AC-5.2: ledger unchanged ($why)"
}
printf '# Backlog\n\n## In flight\n\n- [ ] flying - in flight (repo: alpha)\n\n## Queued\n\n%s\n\n## Done\n\n- [x] finished - done (merged 2026-08-01)\n' "$row_local" >"$fleet_backlog"
refuses_assign 'no single row' 'an unknown id' nosuch-row
refuses_assign 'In flight' 'an in-flight row - its crewmate scope is baked at spawn' flying
refuses_assign 'Done' 'a done row - provenance is stamped before, not after' finished
refuses_assign 'no single row' 'a MIXED set - the legal id must not slip through' pay-fix nosuch-row

# unassign refusals: a row not carrying the token, and an in-flight row.
reset_backlog
assert_fails_with "nothing to reverse" -- "$dom" unassign payments pay-fix
printf '# Backlog\n\n## In flight\n\n- [ ] flying2 - in flight; domain:payments (repo: alpha)\n\n## Queued\n\n## Done\n' >"$fleet_backlog"
assert_fails_with "In flight" -- "$dom" unassign payments flying2

# --- retire: fail-closed, one-line act, package kept -------------------------
reset_backlog
"$dom" assign payments pay-fix >/dev/null
assert_fails_with "OPEN tokened rows" -- "$dom" retire payments
"$dom" unassign payments pay-fix >/dev/null
printf 'kind=roomchief\ndomain=payments\n' >"$AC_HOME/state/payfam-chief.meta"
assert_fails_with "domainchief in flight" -- "$dom" retire payments
rm -f "$AC_HOME/state/payfam-chief.meta"
"$dom" retire payments >/dev/null
assert_eq "$(grep -c '^- payments ' "$dreg" || true)" "0" "retire removes exactly the registry line"
assert_file "$(pkg payments)/CREWMATE.md" "retire keeps the package - knowledge is never deleted by tooling"
assert_fails_with "nothing to retire" -- "$dom" retire payments
# A Done row's token survives a retire (history), and a QUEUED token naming a
# retired domain is the ORPHAN the digest must show.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] strayrow - stray; domain:payments (repo: alpha)\n\n## Done\n' >"$fleet_backlog"
assert_contains "$("$dom" list)" "ORPHAN-TOKEN" "list surfaces a token naming no VALID registry line"
assert_fails_with "orphan" -- "$dom" validate
# restore the domain for the sections below
printf -- '- payments - the payments domain - scope: money movement (added 2026-08-02T00:00:00Z)\n' >"$dreg"
reset_backlog
"$dom" assign payments pay-fix >/dev/null

# --- validate: token discipline over the one ledger --------------------------
printf '%s\n- [ ] prose-tok - mentions domain:payments in prose (repo: alpha)\n' "$(cat "$fleet_backlog")" >"$fleet_backlog"
assert_fails_with "grammar position" -- "$dom" validate
printf '%s\n' "$(grep -v 'prose-tok' "$fleet_backlog")" >"$fleet_backlog"
printf '%s\n- [ ] doc-tok - documents the `domain:payments` shape (repo: alpha)\n' "$(cat "$fleet_backlog")" >"$fleet_backlog"
"$dom" validate >/dev/null || fail "a backtick-quoted mention is inert to validate"
printf '%s\n' "$(grep -v 'doc-tok' "$fleet_backlog")" >"$fleet_backlog"
# story token disagreeing with its epic row's token - one family, one domain.
"$dom" new logistics --scope 'shipping' --charter 'the logistics domain' --no-projects >/dev/null
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] two-epic [EPIC] - epic; domain:payments (repo: alpha)\n- [ ] two-story - story; epic:two-epic; domain:logistics (repo: alpha)\n\n## Done\n' >"$fleet_backlog"
assert_fails_with "one family, one domain" -- "$dom" validate
"$dom" retire logistics >/dev/null 2>&1 || true
reset_backlog
"$dom" assign payments pay-fix >/dev/null

# --- AC-2.3: list renders and ALWAYS exits 0 ---------------------------------
# A digest block may never take session start down - the rule bin/ac-deputy.sh
# states for its own list, adopted here for the same reason.
# AC-12.3 second half - the deputy's local-only guard has exactly the sites the
# spec inventories, all inside the crewdeputy feature. A copy of it landing here
# later would be a mode branch on a verb that cannot need one, so the token is
# asserted ABSENT from this script rather than merely unused.
assert_eq "$(grep -c 'AS1' "$BIN/ac-domain.sh" || true)" "0" \
  "AC-12.3: bin/ac-domain.sh carries no AS1 site - not even a mention"

out="$("$dom" list)"
assert_contains "$out" "payments" "list names the domain"
assert_contains "$out" "scope: money movement" "list carries the scope the chief routes on"
assert_contains "$out" "projects: 2" "list carries the project count"
assert_contains "$out" "queued 1" "list carries the backlog tally"
assert_eq "$(printf '%s' "$out" | grep -c 'home:' || true)" "0" "no home: field - a crewdomain has none"
# --- AC-12.1 / AC-12.5: validate checks the project VIEW by RESOLUTION -------
# Resolution, not a name comparison: it survives a rename, and it makes an
# absolute link exactly as valid as the relative one `new` writes. The DETAIL
# file gets the opposite failure mode on purpose - prose may lag reality, the
# membership guard may not.

vpkg="$(pkg payments)/projects"
"$dom" validate >/dev/null || fail "AC-12.1: a healthy view validates clean"

# An ABSOLUTE link is as valid as the relative one - the check is on the
# resolved path, so the link TEXT is never load-bearing.
rm -f "$vpkg/alpha"
ln -s "$AC_HOME/projects/alpha" "$vpkg/alpha"
"$dom" validate >/dev/null || fail "AC-12.1: an equivalent ABSOLUTE link is accepted"

# A DANGLING link resolves to nothing.
ln -s "../../../projects/nosuchclone" "$vpkg/nosuchclone"
assert_fails_with "dangles" -- "$dom" validate
rm -f "$vpkg/nosuchclone"

# A link resolving OUTSIDE the fleet clones is refused by target, not by name.
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$vpkg/outside"
assert_fails_with "OUTSIDE" -- "$dom" validate
rm -f "$vpkg/outside"

# A plain directory can never masquerade as a view entry.
mkdir -p "$vpkg/copied"
assert_fails_with "not a symlink" -- "$dom" validate
rmdir "$vpkg/copied"

# A .yaml-less project WARNS and does NOT refuse - a project with no pipeline
# config is a supported direct-pr case, and refusing would make the view
# un-buildable for it.
rm -f "$vpkg/beta.yaml"
out="$("$dom" validate)" || fail "AC-12.1: a missing .yaml sibling must WARN, never refuse"
assert_contains "$out" "WARN" "AC-12.1: ... and it says so"
ln -s "../../../projects/beta.yaml" "$vpkg/beta.yaml"

# AC-12.5 - detail-vs-view divergence WARNS with a ZERO exit.
printf '# Projects: payments\n\nalpha only.\n' >"$(pkg payments)/records/projects.md"
out="$("$dom" validate)" || fail "AC-12.5: divergence must not refuse"
assert_contains "$out" "beta" "AC-12.5: the lagging detail file is named"
assert_contains "$out" "WARN" "AC-12.5: as a warning, not a refusal"

# AC-12.2 (the crew-spawn view refusal) lives with the script that enforces it,
# in tests/ac-spawn-teardown.test.sh - that is the file run-suite --changed maps
# a bin/ac-spawn.sh change onto.

# --- review round 1 repairs: the bypasses the first tests missed -------------

# CR-001 - the package root is DERIVED by concatenation, so an unchecked name
# escapes crewdomains/ entirely. `../crewdeputies/demo` would let a crewdomain
# verb mutate a KEPT feature's state, and `..` alone aliases the fleet records.
mkdir -p "$AC_HOME/crewdeputies/demo/records"
printf '# Backlog: demo\n\n## Queued\n\n- [ ] deputy-row - deputy work (repo: alpha)\n' \
  >"$AC_HOME/crewdeputies/demo/records/backlog.md"
deputy_before="$(shasum -a 256 <"$AC_HOME/crewdeputies/demo/records/backlog.md")"
for bad in '../crewdeputies/demo' '..' 'has/slash' 'UPPER'; do
  assert_fails_with "legal crewdomain name" -- "$dom" unassign "$bad" deputy-row
  assert_fails_with "legal crewdomain name" -- "$dom" queue "$bad"
done
assert_eq "$(shasum -a 256 <"$AC_HOME/crewdeputies/demo/records/backlog.md")" "$deputy_before" \
  "CR-001: no traversal reached the crewdeputy ledger next door"

# CR-002 - chief-only-add binds the WRITER of the token. The ledger guard
# covers Edit/Write and NOT Bash, so without this a scoped session runs the
# verb and stamps domain:<name> itself - forged authorization.
reset_backlog
fb_before="$(shasum -a 256 <"$fleet_backlog")"
assert_fails_with "AC_SCOPE" -- env AC_SCOPE=somefamily "$dom" assign payments pay-fix
assert_fails_with "AC_SCOPE" -- env AC_SCOPE=somefamily "$dom" unassign payments pay-fix
assert_fails_with "AC_SCOPE" -- env AC_SCOPE=somefamily "$dom" retire payments
assert_fails_with "AC_SCOPE" -- env AC_SCOPE=somefamily "$dom" new scoped-new --scope s --charter c --no-projects
assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$fb_before" "CR-002: a scoped mutating verb leaves the ledger unchanged"
assert_no_file "$(pkg scoped-new)" "CR-002: a scoped new builds no package"
# ... while the READ verb stays open to a scoped session - a domainchief
# reads its slice here.
env AC_SCOPE=somefamily "$dom" queue payments >/dev/null \
  || fail "CR-002: queue is readable from a scoped session"

# CR-003 - the token is parsed AT ITS GRAMMAR POSITION by the ONE doneline
# parser: prose that merely quotes it never authorizes (covered as MALFORMED
# in the validate section above), and the positional strip restores prose
# exactly.
reset_backlog
"$dom" assign payments pay-fix >/dev/null
"$dom" unassign payments pay-fix >/dev/null
assert_contains "$(cat "$fleet_backlog")" "$row_local" "CR-003: the positional strip restores the row exactly"

# CR-008 - a repeated argument must be refused BEFORE any write: it half-builds
# a package (the second ln fails after the first succeeded) or double-appends a
# stamped row, breaking whole-or-nothing and reversibility alike.
assert_fails_with "duplicate" -- "$dom" new dupes --scope s --charter c --projects alpha,alpha
assert_no_file "$(pkg dupes)" "CR-008: a duplicate project name leaves no partial package"
reset_backlog
fb_before="$(shasum -a 256 <"$fleet_backlog")"
assert_fails_with "duplicate" -- "$dom" assign payments pay-fix pay-fix
assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$fb_before" "CR-008: a duplicate id writes nothing"

# CR-009 - the detail file carries one
# `## <project-name>` heading per in-scope project, and validate compares that
# set against the view in BOTH directions. Advisory in both: prose may lag, the
# guard may not.
"$dom" new headings --scope s --charter c --projects alpha,beta >/dev/null
for h in '## alpha' '## beta'; do
  assert_contains "$(cat "$(pkg headings)/records/projects.md")" "$h" \
    "CR-009: new seeds a $h heading for each linked project"
done
printf '# Projects: payments\n\n## alpha\n\n## ghostproject\n' >"$(pkg payments)/records/projects.md"
out="$("$dom" validate)" || fail "CR-009: divergence must never refuse"
assert_contains "$out" "ghostproject" "CR-009: a project documented but NOT linked warns (the direction a substring search could never find)"
assert_contains "$out" "projects/beta" "CR-009: and a project linked but not documented warns too"

# CR-011 - AC-12.4's property, tested at the level it actually lives: ONE clone
# reached by TWO paths, so a local-only landing through the domain view is
# visible in the fleet's own working copy. That is precisely the condition the
# deputy guard exists to prevent, and why a crewdomain needs no such guard.
( cd "$AC_HOME/projects/alpha" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'landed through the fleet clone' )
assert_eq "$(cd "$(pkg payments)/projects/alpha" && git log --oneline -1 | sed 's/^[0-9a-f]* //')" \
  "landed through the fleet clone" \
  "CR-011/AC-12.4: a commit in the fleet clone is visible through the domain view - one clone, two paths"

# --- review round 2 repairs --------------------------------------------------

# R2-CR-003 - the token is position-anchored, so token-shaped text sitting
# MID-line never authorizes: unassign sees "no token at position" (nothing
# to reverse) and validate flags the row MALFORMED - one parser, one answer,
# the R3-CR-001 laundering path has no second definition to disagree with.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] midline - see; domain:payments (repo: x) for context, then more (repo: alpha)\n\n## Done\n' >"$fleet_backlog"
assert_fails_with "nothing to reverse" -- "$dom" unassign payments midline
assert_fails_with "grammar position" -- "$dom" validate
# ... and the producer stamps before the LAST (repo: ...) group, not the first
# one a prose fragment happens to contain.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] proserepo - mentions (repo: other) inside prose (repo: alpha)\n\n## Done\n' >"$fleet_backlog"
"$dom" assign payments proserepo >/dev/null
assert_contains "$(cat "$fleet_backlog")" "inside prose; domain:payments (repo: alpha)" \
  "R2-CR-003: the stamp lands before the TRAILING group, not the first match"
"$dom" unassign payments proserepo >/dev/null
assert_contains "$(cat "$fleet_backlog")" "mentions (repo: other) inside prose (repo: alpha)" \
  "R2-CR-003: and the positional strip restores it exactly, prose intact"

# R2-CR-004 - a parser-VALID id that the path verbs refuse would take the
# always-exit-0 digest down. One charset, both ends.
printf -- '- Payments - charter - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_eq "$(ac_domain_parse "$dreg" | cut -f1)" "INVALID" "R2-CR-004: an uppercase id is INVALID, not VALID-then-fatal"
printf -- '- pay_ments - charter - scope: money (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_eq "$(ac_domain_parse "$dreg" | cut -f1)" "INVALID" "R2-CR-004: an underscore id too"
"$dom" list >/dev/null || fail "R2-CR-004: list must still exit 0 on such an entry"
printf -- '- payments - the payments domain - scope: money movement (added 2026-08-02T00:00:00Z)\n' >"$dreg"

# R2-CR-005 - AC-1.6's warning: delivery mode lives ONLY in the fleet registry.
# Both the spec's placeholder AND a real token: fleet rows carry [crew-ship],
# never the literal [mode], so matching only the placeholder caught the spec's
# own notation and nothing an operator would actually paste (round-6 CR-003).
for tok in '[mode]' '[crew-ship]' '[local-only]'; do
  printf '# Projects: payments\n\n## alpha\n\n## beta\n\nalpha %s\n' "$tok" \
    >"$(pkg payments)/records/projects.md"
  out="$("$dom" validate)" || fail "R2-CR-005: a $tok token warns, it does not refuse"
  assert_contains "$out" "delivery-mode token" "R2-CR-005: $tok is caught as a delivery-mode token"
done

# R2-CR-006, REVISED by captain ruling (select at the lab session,
# recorded in ac-homes/drydock/data/domain-view-symlinked-clones/room.md):
# resolution now STOPS at the fleet-clone level. A view link into
# $AC_HOME/projects/<p> is trusted the instant it lands there, even when <p>
# is ITSELF a symlink out to a captain checkout - the same trust ac-spawn.sh,
# ac-tree.sh and ac-merge-local.sh already extend to a symlinked clone, so a
# domain view onto it deserves no stricter a check. This is DELIBERATELY `ok`
# now - it is not the "canonicalize only the parent directory" bug the
# superseded comment warned against, because the stopping point is still
# checked to be EXACTLY $AC_HOME/projects/<entry> (see the mismatch case right
# after).
ln -s "$TMP/elsewhere" "$AC_HOME/projects/aliased"
ln -s "../../../projects/aliased" "$(pkg payments)/projects/aliased"
"$dom" validate >/dev/null \
  || fail "R2-CR-006: a fleet clone that is itself a symlink out is trusted at the fleet-clone boundary - deliberately ok"
rm -f "$(pkg payments)/projects/aliased"

# ... but the identity check still binds NAME, not merely the one-hop landing:
# a view entry named differently from the fleet-clone it stops at must still
# mismatch, even when that clone is itself symlinked out - otherwise stopping
# early would silently widen the mismatch hole the captain ordered kept intact.
ln -s "../../../projects/aliased" "$(pkg payments)/projects/aliased-wrong"
assert_fails_with "OWN clone" -- "$dom" validate
rm -f "$(pkg payments)/projects/aliased-wrong" "$AC_HOME/projects/aliased"

# R2-CR-007 - the routing line `new` is about to write must itself parse VALID,
# or a successful command leaves a package whose own entry is unroutable.
assert_fails_with "does not parse VALID" -- "$dom" new badline --scope s --charter 'has a - home: token' --projects alpha
assert_no_file "$(pkg badline)" "R2-CR-007: refused before any write"

# R4-CR-001 - the view binds IDENTITY, not merely containment: a link named
# `beta` pointing at projects/alpha resolves inside the clones, so a
# containment-only test authorized work on a repo the domain never linked.
ln -s "../../../projects/alpha" "$(pkg payments)/projects/beta-wrong"
assert_fails_with "OWN clone" -- "$dom" validate
rm -f "$(pkg payments)/projects/beta-wrong"

# R4-CR-003 - a malformed CSV must not silently build a shorter or empty view.
for bad in ',' ',alpha' 'alpha,' 'alpha,,beta' 'al*pha'; do
  assert_fails_with "projects" -- "$dom" new csvbad --scope s --charter c --projects "$bad"
  assert_no_file "$(pkg csvbad)" "R4-CR-003: '$bad' leaves no package"
done

# R2-CR-008 - the two project options are mutually exclusive, not last-wins.
assert_fails_with "mutually exclusive" -- "$dom" new bothopts --scope s --charter c --projects alpha --no-projects
assert_no_file "$(pkg bothopts)" "R2-CR-008: and nothing was written"

# --- review round 5 repairs --------------------------------------------------

# R5-CR-001 - a backlog id is a LITERAL. Unvalidated it reaches an awk regex,
# where `.` matches any character and moves a row nobody named.
reset_backlog
fb="$(shasum -a 256 <"$fleet_backlog")"
for badid in 'pay.fix' 'pay*' '../x'; do
  assert_fails_with "legal backlog id" -- "$dom" assign payments "$badid"
done
assert_eq "$(shasum -a 256 <"$fleet_backlog")" "$fb" "R5-CR-001: no regex-shaped id moved a row"

# R5-CR-004 - whole-package-or-nothing must survive a failure DURING the write,
# not only a refusal before it. A pre-existing projects/<p> path makes the ln
# fail midway; nothing may survive.
# A pre-existing package dir would be caught by the AC-1.7 namespace check
# BEFORE any write, which is a different path - this has to fail MID-write, so
# `ln` is made to fail on its second call, after the first link is already down.
mkdir -p "$TMP/lnbin"
cat >"$TMP/lnbin/ln" <<'LNSTUB'
#!/usr/bin/env bash
n="$(cat "${AC_TEST_LN_COUNT}" 2>/dev/null || printf 0)"
n=$((n + 1)); printf '%s' "$n" >"${AC_TEST_LN_COUNT}"
[ "$n" -lt 2 ] || { printf 'ln: forced failure
' >&2; exit 1; }
exec /bin/ln "$@"
LNSTUB
chmod +x "$TMP/lnbin/ln"
: >"$TMP/ln-count"
if AC_TEST_LN_COUNT="$TMP/ln-count" PATH="$TMP/lnbin:$PATH" \
   "$dom" new rollback --scope s --charter c --projects alpha,beta >/dev/null 2>&1; then
  fail "R5-CR-004: a failing ln must not report success"
fi
assert_no_file "$AC_HOME/crewdomains/rollback" "R5-CR-004: the partial package is rolled back"
assert_eq "$(grep -c 'rollback' "$dreg" || true)" "0" "R5-CR-004: and no registry line was minted"

# R5-CR-005 - option PRESENCE, not value: an omitted --scope must not mint a
# registered-but-unroutable entry silently.
assert_fails_with "scope" -- "$dom" new noscope --charter c --projects alpha
assert_no_file "$(pkg noscope)" "R5-CR-005: and nothing was written"
assert_fails_with "mutually exclusive" -- "$dom" new bothempty --scope s --charter c --projects '' --no-projects

# R5-CR-007 (revised for crewdomain-token) - a package on disk with no VALID
# registry line still surfaces in the digest as UNREGISTERED kept knowledge;
# there is no ledger inside it for rows to hide in anymore.
mkdir -p "$AC_HOME/crewdomains/ghostpkg/records"
printf '# ghost knowledge\n' >"$AC_HOME/crewdomains/ghostpkg/CREWMATE.md"
assert_contains "$("$dom" list)" "UNREGISTERED" "a lineless package renders UNREGISTERED"
rm -rf "$AC_HOME/crewdomains/ghostpkg"

# R5-CR-008 - AC-1.6's other half: a fleet DESCRIPTION copied into the detail.
printf '# Projects\n\n- alpha [crew-ship] - the alpha service, payments edge (added 2026-08-02)\n' \
  >"$AC_HOME/records/projects.md"
printf '# Projects: payments\n\n## alpha\n\nthe alpha service, payments edge\n' >"$(pkg payments)/records/projects.md"
out="$("$dom" validate)" || fail "R5-CR-008: a copied description warns, it does not refuse"
assert_contains "$out" "repeats the FLEET description" "R5-CR-008: the second half of the boundary is enforced"

# R5-CR-010 - a colliding id on an INVALID registry line is still a collision:
# the parser puts the whole LINE in field 2 for INVALID records, so a field-2
# comparison missed exactly the half-typed duplicate this check exists for.
printf -- '- taken - charter - home: /x - scope: s (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_eq "$(ac_domain_parse "$dreg" | cut -f1)" "INVALID" "R5-CR-010: the line is INVALID"
assert_fails_with "already registered" -- "$dom" new taken --scope s --charter c --projects alpha
printf -- '- payments - the payments domain - scope: money movement (added 2026-08-02T00:00:00Z)\n' >"$dreg"

printf 'this is not a registry line at all\n- broken\n' >"$dreg"
"$dom" list >/dev/null || fail "AC-2.3: list must exit 0 even on a corrupt registry"

# ---- in-flight assign: the captain-requested escape (approved 2026-08-18) ---
# A stamp changes nothing in the flying crewmate's env - the refusal is
# policy, so the captain's word unlocks it and rides the status record. Done
# rows stay refused with or without the flag.
printf -- '- payments - the payments domain - scope: money movement (added 2026-08-02T00:00:00Z)\n' >"$dreg"
printf '# Backlog\n\n## In flight\n\n- [ ] flyfam - flying now (repo: alpha)\n\n## Queued\n\n## Done\n\n- [x] oldone - done (merged 2026-08-01)\n' >"$fleet_backlog"
assert_fails_with "captain-requested" -- "$dom" assign payments flyfam
"$dom" assign payments flyfam --captain-requested 'captain said 1, 2026-08-18' >/dev/null
assert_contains "$(cat "$fleet_backlog")" "- [ ] flyfam - flying now; domain:payments (repo: alpha)" \
  "the captain's word stamps an in-flight row in place"
assert_contains "$(cat "$AC_HOME/state/payments.status" 2>/dev/null || cat "$AC_HOME"/state/*.status 2>/dev/null)" "captain-requested" \
  "and the authority rides the durable status record"
assert_fails_with "Done history" -- "$dom" assign payments oldone --captain-requested 'even with the word'

pass
