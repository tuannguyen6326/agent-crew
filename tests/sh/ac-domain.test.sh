#!/usr/bin/env bash
# ac-domain.test.sh - the crewdomain verb layer (bin/ac-domain.sh). Colocated
# with the script so tests/run-suite.sh --changed maps a change here to exactly
# this file; without it the new script is an unmapped owned file and --changed
# widens to the whole suite.
#
# The registry GRAMMAR is owned by ac-lib.sh's `crewdomain routing table` block
# and tested in tests/sh/ac-lib.test.sh; this file owns the VERBS - what `new`
# creates, what it refuses, and what a mutating verb backs up first.
#
# COEXISTENCE is a property under test here, not a background assumption: a
# crewdomain and a crewdeputy may not share a name, and nothing this script
# writes or backs up ever reaches $AC_HOME/crewdeputies/.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
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
# fail-closed shape bin/ac-home-seed.sh's validate-before-touching-disk checks already gives the operator.
assert_fails_with "no clone" -- "$dom" new ghosts --scope s --charter c --projects alpha,nosuch
assert_no_file "$(pkg ghosts)" "AC-1.5: an unknown project leaves no partial package"
assert_eq "$(grep -c 'ghosts' "$dreg" || true)" "0" "and mints no registry line"

# A project with no pipeline config is a SUPPORTED state (the intake-triage
# skill calls it a direct-pr case), so the clone link is created alone and said so -
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
# constrains: recordsBackup, in tests/ts/deputy.test.ts.

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
  printf '%s\n' "$1" >"$TMP/line.md"
  awk "$AC_DONELINE_AWK"'{ ac_doneline($0, f); printf "%s|%s|%s|%s|%s|%s\n", f["id"], f["terminal"], f["epic"], f["blockers"], f["date"], f["verb"] }' "$TMP/line.md"
}
assert_eq "$(fields "$(grep 'pay-fix' "$fleet_backlog")")" "$(fields "$row_local")" \
  "AC-7.3: id/terminal/epic/blockers/date/verb are identical with and without the token"
grep 'pay-fix' "$fleet_backlog" >"$TMP/line.md"
assert_eq "$(awk "$AC_DONELINE_AWK"'{ ac_doneline($0, f); print f["domain"] }' "$TMP/line.md")" \
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
# Names are text: awk compares two numeric-looking strings as numbers, so the
# tally and queue for 7 took domain:07 rows, and validate read a story on
# domain:7 under an epic on domain:07 as one domain.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] n7 - seven; domain:7 (repo: alpha)\n- [ ] n07 - oh-seven; domain:07 (repo: alpha)\n- [ ] e07 [EPIC] - epic; domain:07 (repo: alpha)\n- [ ] s7 - story; epic:e07; domain:7 (repo: alpha)\n\n## Done\n' >"$fleet_backlog"
read -r tq ti td <<EOF
$(ac_domain_tally 7)
EOF
assert_eq "$tq" "2" "tally 7 counts only the domain:7 rows"
assert_eq "$("$dom" queue 7 --ids | tr '\n' ' ')" "n7 s7 " "queue 7 never lists a domain:07 row"
assert_fails_with "one family, one domain" -- "$dom" validate
reset_backlog
"$dom" assign payments pay-fix >/dev/null
# A ledger the parser could not read is an INVALID line, never a clean one.
# A mode-000 ledger is that ledger (skipped under root, which reads it).
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$fleet_backlog"
  rc=0; out="$("$dom" validate 2>/dev/null)" || rc=$?
  chmod 644 "$fleet_backlog"
  assert_eq "$rc" "2" "validate over a ledger the parser could not read: exit status"
  assert_contains "$out" "INVALID ledger: cannot read $fleet_backlog" "validate names the ledger it could not read"
fi

# --- AC-2.3: list renders and exits 0 but for a failed registry parse -------
# A digest block may never take session start down: an unread ledger costs the
# tallies, never the exit (src/domain.ts list; a failed registry parse is W2),
# and bin/ac-session-start.sh degrades a failed list to a WARN, as it does
# src/deputy.ts's (W4).
# AC-12.3 second half - the deputy's local-only guard has exactly the sites the
# spec inventories, all inside the crewdeputy feature. A copy of it landing here
# later would be a mode branch on a verb that cannot need one, so the token is
# asserted ABSENT from this script rather than merely unused.
assert_eq "$(cat "$BIN/ac-domain.sh" "$ROOT/src/domain.ts" | grep -c 'AS1' || true)" "0" \
  "AC-12.3: bin/ac-domain.sh and the src/domain.ts it starts carry no AS1 site - not even a mention"

out="$("$dom" list)"
assert_contains "$out" "payments" "list names the domain"
assert_contains "$out" "scope: money movement" "list carries the scope the chief routes on"
assert_contains "$out" "projects: 2" "list carries the project count"
assert_contains "$out" "queued 1" "list carries the backlog tally"
cp "$AC_HOME/records/backlog.md" "$TMP/dom-backlog.keep"
printf -- '- [x] latin - caf\351 menu (merged 2026-08-01)\n' >>"$AC_HOME/records/backlog.md"
assert_contains "$(LC_ALL=en_US.UTF-8 "$dom" list)" "queued 1" "a non-UTF-8 byte in the ledger never costs the tally"
cp "$TMP/dom-backlog.keep" "$AC_HOME/records/backlog.md"
# Session start runs list under set -e: a ledger the parser could not read
# costs the tallies and the orphan scan, never the digest.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$fleet_backlog"
  rc=0; out="$("$dom" list 2>/dev/null)" || rc=$?
  chmod 644 "$fleet_backlog"
  assert_eq "$rc" "0" "list over a ledger the parser could not read: exit status"
  assert_contains "$out" "backlog: queued ?, in flight ?, done ?" "an unread tally is marked unknown, never blank"
  assert_contains "$out" "WARN"$'\t'"ledger unreadable" "an unread ledger is named in the digest"
  assert_contains "$out" "registered: " "list still renders to its last line"
  assert_eq "$(printf '%s' "$out" | grep -c 'home:' || true)" "0" "no home: field - a crewdomain has none"
fi
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
# in tests/sh/ac-spawn-teardown.test.sh - that is the file run-suite --changed maps
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

# R2-CR-005 - AC-1.6's warning: delivery mode is per task, never a registry
# property, so a domain file carrying any mode token is drift.
# Both the spec's placeholder AND a real token: fleet rows carry [crew-ship],
# never the literal [mode], so matching only the placeholder caught the spec's
# own notation and nothing an operator would actually paste (round-6 CR-003).
for tok in '[mode]' '[crew-ship]' '[local-only]' '[feature-pr]'; do
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
# The registry bracket is optional (bin/ac-project-mode.sh header), so a
# bracketless line's description is compared too.
printf '# Projects\n\n- alpha - the alpha service, payments edge (added 2026-08-02)\n' >"$AC_HOME/records/projects.md"
assert_contains "$("$dom" validate)" "repeats the FLEET description" "a bracketless registry line's description is checked too"
printf '# Projects\n\n- alpha [crew-ship] - the alpha service, payments edge (added 2026-08-02)\n' >"$AC_HOME/records/projects.md"

# R5-CR-010 - a colliding id on an INVALID registry line is still a collision:
# the parser puts the whole LINE in field 2 for INVALID records, so a field-2
# comparison missed exactly the half-typed duplicate this check exists for.
printf -- '- taken - charter - home: /x - scope: s (added 2026-08-02T00:00:00Z)\n' >"$dreg"
assert_eq "$(ac_domain_parse "$dreg" | cut -f1)" "INVALID" "R5-CR-010: the line is INVALID"
assert_fails_with "already registered" -- "$dom" new taken --scope s --charter c --projects alpha
printf -- '- payments - the payments domain - scope: money movement (added 2026-08-02T00:00:00Z)\n' >"$dreg"

printf 'this is not a registry line at all\n- broken\n' >"$dreg"
"$dom" list >/dev/null || fail "AC-2.3: list must exit 0 even on a corrupt registry"

# ---- in-flight assign: the captain-requested escape -------------------------
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

# ---- qa-repo: the domain's own e2e repository (the second QA route) --------
# A domain whose behavioural proof lives in ONE maintained e2e repository
# declares it HERE, by project name, and every QA of that domain goes there.
# The declaration is what makes REUSE mechanical: a second `--set` refuses
# rather than letting a fresh suite be stood up beside the one that exists.
make_clone e2e-suite
"$dom" new proof --scope 'the proof domain' --charter 'proof' --projects alpha,e2e-suite >/dev/null

# undeclared: prints nothing, exits non-zero, says how to declare it
rc=0; out="$("$dom" qa-repo proof 2>/dev/null)" || rc=$?
assert_eq "$rc" "1" "a domain with no e2e repository answers non-zero"
assert_eq "$out" "" "...and prints nothing on stdout, so a caller can test it"
assert_fails_with "qa-repo proof --set" -- "$dom" qa-repo proof

# declare, then read back the absolute clone path
"$dom" qa-repo proof --set e2e-suite >/dev/null
assert_eq "$("$dom" qa-repo proof)" "$AC_HOME/projects/e2e-suite" \
  "the declared repository reads back as the fleet's own clone path"
assert_eq "$(cat "$(pkg proof)/qa-repo")" "e2e-suite" \
  "the package member holds the PROJECT NAME - the path is derived, never stored"

# the lib reader is what other scripts use
assert_eq "$(ac_domain_qa_repo proof)" "$AC_HOME/projects/e2e-suite" "ac_domain_qa_repo reads the same path"
rc=0; ac_domain_qa_repo payments >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "...and answers non-zero for a domain that declared none"

# REUSE, enforced: a second --set refuses and names what is already declared
assert_fails_with "already declares" -- "$dom" qa-repo proof --set alpha
assert_eq "$("$dom" qa-repo proof)" "$AC_HOME/projects/e2e-suite" "a refused --set changes nothing"
"$dom" qa-repo proof --set alpha --force >/dev/null
assert_eq "$("$dom" qa-repo proof)" "$AC_HOME/projects/alpha" "--force is the deliberate way to move it"

# the repository must be IN the domain - a fleet project the domain does not
# carry would point QA at a clone the domain's own view cannot reach
assert_fails_with "not a project of domain" -- "$dom" qa-repo proof --set beta
assert_fails_with "not a project of domain" -- "$dom" qa-repo proof --set nosuchproject

# clear, and the name gate every verb carries
"$dom" qa-repo proof --clear >/dev/null
rc=0; "$dom" qa-repo proof >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "--clear returns the domain to undeclared"
assert_fails_with "legal crewdomain name" -- "$dom" qa-repo ../escape
assert_fails_with "no such crewdomain" -- "$dom" qa-repo ghostdomain --set alpha

# --- the entry end to end, one scenario per row -------------------------------
# One side root ($H): a home at $H/home holding git clones alpha, beta and e2e
# under projects/ (alpha and beta with a .yaml), records/ and state/; cwd
# $H/cwd, an EMPTY dir; TMPDIR $H/tmp; stdin /dev/null; LC_ALL=C unless a row
# names en_US.UTF-8; PATH stubs - a date answering one fixed instant per format
# (or failing per sentinel) and an ln failing on the Nth call per sentinel. A
# row reads the run's exit status, stdout and stderr (the side root spelled
# @H) and what it left under the home.
H="$TMP/xside"
XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%N*) [ ! -e "$STUB_DIR/date.fail-ns" ] || exit 4
        echo 1767225600000000000 ;;
  *%S*) [ ! -e "$STUB_DIR/date.fail" ] || { echo 'date: the stub refuses' >&2; exit 3; }
        echo 2026-01-01T00:00:00Z ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/ln" <<'STUB'
#!/bin/sh
if [ -e "$STUB_DIR/ln.fail-at" ]; then
  n=$(($(cat "$STUB_DIR/ln.count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_DIR/ln.count"
  [ "$n" -lt "$(cat "$STUB_DIR/ln.fail-at")" ] || { echo 'ln: the stub refuses' >&2; exit 1; }
fi
exec /bin/ln "$@"
STUB
chmod +x "$XSTUBS/date" "$XSTUBS/ln"
xat() {  # xat <cmd> <args...> - a seeding step; a literal @H in an argument is the side root
  local x a=(); for x in "$@"; do a+=("${x//@H/$H}"); done; "${a[@]}"
}
xseed() {
  rm -rf "$H"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/projects" "$H/cwd" "$H/tmp"
  local p; for p in alpha beta e2e; do git init -q -b main "$H/home/projects/$p"; done
  printf 'test: {}\n' >"$H/home/projects/alpha.yaml"; printf 'test: {}\n' >"$H/home/projects/beta.yaml"
}
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xadd() { printf '%s' "${2//@H/$H}" >>"$H/$1"; }                                 # xadd <path under the side> <bytes>
XLC=C; XENV=(); XHOME=home; XHOMELESS=0; XPATH=""; XCWD=cwd; XN_RC=0
xrun() {  # xrun <args...> - one run of the entry; @H in an argument or an XENV value is the side root
  local x v a=() e=("LC_ALL=$XLC" "PATH=${XPATH:-$XSTUBS:$PATH}" "STUB_DIR=$H" "TMPDIR=$H/tmp")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$H/$XHOME")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$H}"); done
  for x in "$@"; do a+=("${x//@H/$H}"); done
  XN_RC=0
  (cd "$H/$XCWD" && env -u AC_HOME -u AC_SCOPE -u AC_BACKEND -u TMPDIR -u EPOCHSECONDS -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN \
    "${e[@]}" "$BIN/ac-domain.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/x.raw" 2>"$TMP/x.rawerr" || XN_RC=$?
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/x.raw" >"$TMP/x.out"; LC_ALL=C sed -e "s#$H#@H#g" "$TMP/x.rawerr" >"$TMP/x.err"
}
xout() { cat "$TMP/x.out"; }
xerr() { cat "$TMP/x.err"; }
xworld() {  # every path under the home with each link's target, and the bytes of what a verb writes
  local f
  (cd "$H/home" && find . -path './projects/*/.git' -prune -o -print | LC_ALL=C sort)
  (cd "$H/home" && find . -path './projects/*/.git' -prune -o -type l -exec stat -f '%N -> %Y' {} + | LC_ALL=C sort)
  for f in "$H"/home/records/* "$H"/home/crewdomains/*/records/* "$H"/home/crewdomains/*/CREWMATE.md "$H"/home/crewdomains/*/qa-repo \
    "$H"/home/state/*.status "$H"/home/state/.wake-spool/*; do
    [ -f "$f" ] || continue
    printf '== %s %s\n' "$f" "$(ls -l "$f" | cut -c1-10)"; cat "$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  ls -A "$H/tmp"
}
xrefuse() {  # xrefuse <stderr> <args...> - exit 1, no stdout, exactly <stderr>, nothing written
  local want="$1" before; shift
  before="$(xworld)"
  xrun "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "domain refusal for '$*'"
  assert_eq "$(xworld)" "$before" "a refused '$*' writes nothing"
}
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XUSAGE='ERROR: usage: ac-domain.sh <new|assign|unassign|queue|qa-repo|retire|list|validate>'
XTS='2026-01-01T00:00:00Z'
XABSENT='ABSENT: records/crewdomains.md - no crewdomains registered'
xseed

# 1. usage: none, -h, LIST and an unknown verb; extra arguments to list and
#    validate are never read; no backend is resolved (config and env tmux).
for xv in "" -h LIST bogus; do
  # shellcheck disable=SC2086
  xrun $xv
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$XUSAGE" "1: '$xv' is the usage line, exit 1"
done
xrun list extra args; assert_eq "$XN_RC:$(xout)" "0:$XABSENT" "1: extra arguments to list are never read"
xrun validate extra; assert_eq "$XN_RC:$(xout)" "0:" "1: nor to validate"
xput home/config/backend $'tmux\n'
XENV=(AC_BACKEND=tmux); xrun list; XENV=()
assert_eq "$XN_RC:$(xout)" "0:$XABSENT" "1: no backend is resolved - tmux in config and env changes nothing"
rm -rf "$H/home/config"

# 2. homeless: new, unassign and queue are the refusal alone; assign, retire
#    and qa-repo lead with it. An AC_HOME that cannot be entered is named on
#    every verb.
XHOMELESS=1
for xv in "new x --scope s --charter c --no-projects" "unassign x y" "queue x"; do
  # shellcheck disable=SC2086
  xrun $xv; assert_eq "$XN_RC:$(xout):$(xerr)" "1::$XNOHOME" "2: homeless '$xv' - one refusal, exit 1"
done
for xv in "assign x y" "retire x" "qa-repo x"; do
  # shellcheck disable=SC2086
  xrun $xv; assert_eq "$XN_RC:$(xout):$(sed -n 1p "$TMP/x.err")" "1::$XNOHOME" "2: homeless '$xv' is refused on the AC_HOME line"
done
XHOMELESS=0
XHOME=missing
for xv in list validate "new x --scope s --charter c --no-projects" "assign x y" "unassign x y" "queue x" "retire x" "qa-repo x"; do
  # shellcheck disable=SC2086
  xrun $xv
  assert_contains "$(xerr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "2: an unenterable AC_HOME is named ('$xv')"
done
[ ! -e "$H/missing" ] || fail "2: an unenterable AC_HOME is never minted"
XHOME=home

# 3. new: the parser, the refusals in code order, the reserved suffixes, the
#    namespace order, the routing line's checks, the projects list, the
#    whole-or-nothing write.
XNEWU="ERROR: usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>' (--projects <p1,p2,...> | --no-projects)"
XCHART="ERROR: --charter '<one-liner>' is required and may not be empty: it is what the chief reads in the digest"
xrefuse "$XNEWU" new
xrefuse "ERROR: unknown argument: s" new --scope s --charter c --no-projects
for xf in --scope --charter --projects; do xrefuse "ERROR: $xf needs a value" new x --scope s "$xf"; done
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: unknown argument: --bogus" new x --bogus
XENV=(AC_SCOPE=)
xrun new scopeless --scope s --charter c --no-projects
assert_eq "$XN_RC:$(xout)" "0:created crewdomain scopeless at crewdomains/scopeless (0 project link(s))" "3: an empty AC_SCOPE is unscoped"
XENV=()
xrefuse "$XCHART" new x --scope s --no-projects
xrefuse "$XCHART" new x --scope s --charter '' --no-projects
for xn in X . a_b 'caf'$'\303\251' 'a b'; do xrefuse "ERROR: name must be [a-z0-9-]: $xn" new "$xn" --scope s --charter c --no-projects; done
xrefuse "$XCHART" new X --scope s --no-projects
xrun new pay --scope 'money movement' --charter 'the payments domain' --projects alpha,beta
assert_eq "$XN_RC:$(xout)" "0:created crewdomain pay at crewdomains/pay (2 project link(s))" "3: a domain over two clones"
assert_eq "$(tail -n1 "$H/home/records/crewdomains.md")" "- pay - the payments domain - scope: money movement (added $XTS)" "3: the routing line"
assert_eq "$(readlink "$H/home/crewdomains/pay/projects/beta.yaml")" "../../../projects/beta.yaml" "3: relative links"
xrun new rep --scope a --scope b --charter c --charter d --projects alpha --projects beta
assert_eq "$(tail -n1 "$H/home/records/crewdomains.md")" "- rep - d - scope: b (added $XTS)" "3: repeated flags, the last wins"
xrun new lonely --scope '' --charter c --no-projects
assert_eq "$(tail -n1 "$H/home/records/crewdomains.md")" "- lonely - c - scope:  (added $XTS)" "3: --scope '' mints an unroutable entry"
xrun new pct --scope 's %s \n' --charter '100% \t' --no-projects
assert_eq "$(tail -n1 "$H/home/records/crewdomains.md")" "- pct - 100% \\t - scope: s %s \\n (added $XTS)" "3: % and backslashes stay literal"
xrun new x-r100 --scope s --charter c --no-projects
assert_eq "$XN_RC" 0 "3: x-r100 is no reserved suffix"
for xs in spec arch plan review ship design chief r1 r10; do
  xrefuse "ERROR: name 'x-$xs' collides with a reserved stage suffix - a family id derives stage dirs from it" new "x-$xs" --scope s --charter c --no-projects
done
xput home/records/crewdeputies.md $'# Crewdeputies\n\n- billing - home: /h/billing - no projects (added x)\n'
xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] rowname - a row\n- [x] rowdone - done\n- [ ] rowtail\n'
xrefuse "ERROR: name 'rowdone' is already a row id in records/backlog.md" new rowdone --scope s --charter c --no-projects
xrun new rowtail --scope s --charter c --no-projects
assert_eq "$XN_RC" 0 "3: a row id the line ends on is no collision (the grep wants a blank after it)"
mkdir -p "$H/home/data/pay-plan" "$H/home/data/billing"
xrefuse "ERROR: name 'pay-plan' collides with a reserved stage suffix - a family id derives stage dirs from it" new pay-plan --scope s --charter c --no-projects
xrefuse "ERROR: name 'billing' is already a crewdeputy in records/crewdeputies.md - the two features share no file, but they share the operator's vocabulary and the chief's routing judgment; pick a different name" \
  new billing --scope s --charter c --no-projects
xrefuse "ERROR: --charter/--scope must be single-line: a newline would split the routing line in two" new nl --scope s --charter $'a\nb' --no-projects
xrefuse "ERROR: --charter/--scope must be single-line: a newline would split the routing line in two" new nl --scope $'s\n' --charter c --no-projects
xrefuse "ERROR: the routing line these arguments would write does not parse VALID (unknown field \"x:\") - refusing before any write. Check --charter and --scope for a ' - <word>:' token, which this grammar reads as an unknown field." \
  new badline --scope 'a - x: b' --charter c --no-projects
xrefuse 'ERROR: --projects takes project NAMES, not paths: "a/b"' new csv --scope s --charter c --projects a/b
for xp in '' ' ' $'\t'; do
  xrefuse "ERROR: --projects named no project - pass --no-projects if the empty view is what you meant" new csv --scope s --charter c --projects "$xp"
done
mkdir -p "$H/home/projects/wt"; xput home/projects/wt/.git $'gitdir: /nowhere\n'
git init -q -b main "$H/real"; ln -s "$H/real" "$H/home/projects/sym"
xrefuse "ERROR: the fleet has no clone at projects/wt - a domain view links the fleet's own clones, it never makes one" new wtd --scope s --charter c --projects wt
xrun new symd --scope s --charter c --projects sym
assert_eq "$XN_RC:$(xout)" "0:created crewdomain symd at crewdomains/symd (1 project link(s))
no pipeline config in the fleet for: sym.yaml - linked the clone alone (a project with no <name>.yaml is a supported direct-pr case)" "3: a symlinked clone is a clone"
XENV=(TMPDIR=@H/notmp)
xrun new notmp --scope s --charter c --no-projects
XENV=()
assert_eq "$XN_RC:$(xout)" "1:" "3: an unwritable TMPDIR ends new with mktemp's status"
[ ! -e "$H/home/crewdomains/notmp" ] || fail "3: ... before any write"
case "$(cat "$H/home/records/crewdomains.md")" in *notmp*) fail "3: ... and nothing registered" ;; esac
mkdir -p "$H/home/crewdomains/mkfail"
chmod 555 "$H/home/crewdomains"
if [ "$(id -u)" != 0 ]; then
  xrun new mkfail2 --scope s --charter c --no-projects
  assert_eq "$XN_RC" 1 "3: a package dir mkdir cannot make ends new with mkdir's status"
  assert_contains "$(xerr)" "rolled back the partial package at @H/home/crewdomains/mkfail2" "3: ... rolled back"
fi
chmod 755 "$H/home/crewdomains"
rmdir "$H/home/crewdomains/mkfail"
if [ "$(id -u)" != 0 ]; then
  chmod 444 "$H/home/records/crewdomains.md"
  xrun new ro --scope s --charter c --projects alpha
  chmod 644 "$H/home/records/crewdomains.md"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::rolled back the partial package at @H/home/crewdomains/ro - nothing was created" "3: an unwritable registry rolls back"
  [ ! -e "$H/home/crewdomains/ro" ] || fail "3: ... and the package is gone"
fi
# No pathname expansion: from a cwd holding alpha, 'alph?' stays a word.
mkdir -p "$H/globcwd/alpha"
XCWD=globcwd; xrun new globby --scope s --charter c --projects 'alph?'; XCWD=cwd
assert_eq "$XN_RC" 1 "3: the project list is never globbed against the cwd"
assert_contains "$(xerr)" "no clone at projects/alph?" "3: ... the word is refused as it is"
xrun new latin --scope s --charter $'caf\351' --no-projects
assert_contains "$(tail -n1 "$H/home/records/crewdomains.md" | od -An -tx1 | tr -d ' \n')" "2d206c6174696e202d20636166efbfbd" "3: argv arrives decoded - a charter byte that is not UTF-8 is U+FFFD"

# 4. assign: stamps in place, both arms, idempotent, the status line, the
#    spool record, the timeline mirror, the last captain's words, a wake that
#    cannot publish (WARN), a backup that cannot be claimed.
x4() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/data" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state"
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- noscope - c - scope:  (added x)\n'
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - before any heading (repo: alpha)\n\n## In flight\n\n- [ ] fly - in flight (repo: alpha)\n- [ ] fly2 - in flight too\n\n## Queued\n\n- [ ] qa - row a (repo: alpha)\n- [ ] qb - row b\n- [ ] qc - mid (repo: x) prose (repo: alpha)\n- [ ] pin [src:cap mode:direct-pr rev:no] - pinned (repo: alpha)\n- [ ] big [EPIC] - the epic (repo: alpha)\n- [ ] story - a story; epic:big (repo: alpha)\n- [ ] dep - waits (repo: alpha) blocked-by: qa - needs it\n- [ ] other - other; domain:inv (repo: alpha)\n- [ ] mal - a domain:pay mention (repo: alpha)\n- [ ] dup - one\n- [ ] dup - two\n- [ ] nodash\n- [ ] qd - d\n- [ ] qe - e\n- [ ] wa - w a\n- [ ] wb - w b\n- [ ] wc - w c\n- [ ] wd - w d\n- [ ] wf - w f\n- [ ] wg - w g\n- [ ] wh - w h\n- [ ] wi - w i\n- [ ] latu - caf\351 u\n- [ ] bs - C:\\new path (repo: alpha)\n- [ ] bs2 - a \\d+ regex\n- [ ] tail - ends in a backslash \\\n- [ ] lat - caf\351 (repo: alpha)\n- [ ] crlf - windows (repo: alpha)\r\n\n## Queued (3)\n\n- [ ] q3 - counted\n\n## Parked\n\n- [ ] park - parked\n\n## Done\n\n- [x] fin - done (merged 2026-08-01)\n'
}
x4
xrun assign pay qa
assert_eq "$XN_RC:$(xout)" "0:backup: @H/home/state/backups/domain-assign-1767225600.tar.gz
- [ ] qa - row a; domain:pay (repo: alpha)
assigned qa to crewdomain pay" "4: one row stamped before its trailing repo group"
assert_eq "$(cat "$H/home/state/pay.status")" "$XTS assign: qa" "4: the status line"
assert_eq "$(cat "$H"/home/state/.wake-spool/*)" "1767225600	domain	pay	assign: qa" "4: one spool record"
xrun assign pay qb qc big story dep pin crlf
assert_contains "$(xout)" "- [ ] qb - row b; domain:pay" "4: the end-of-line arm"
assert_contains "$(xout)" "- [ ] qc - mid (repo: x) prose; domain:pay (repo: alpha)" "4: before the TRAILING group"
assert_contains "$(xout)" $'- [ ] crlf - windows (repo: alpha)\r; domain:pay' "4: a CR ends the line, so the EOL arm"
assert_contains "$(cat "$H/home/records/backlog.md")" "- [ ] pin [src:cap mode:direct-pr rev:no] - pinned; domain:pay (repo: alpha)" "4: ... written in place"
xrun assign pay qa qb mal
assert_contains "$(xout)" "already assigned to pay: qa,qb" "4: the no-ops named"
assert_contains "$(xout)" "- [ ] mal - a domain:pay mention; domain:pay (repo: alpha)" "4: an off-position token reads as none and is stamped over"
xrun assign pay qa qb
assert_eq "$XN_RC:$(xout)" "0:already assigned to pay: qa,qb
nothing to do" "4: all already - nothing to do, no backup"
xrun assign inv qd --captain-requested first --captain-requested second
assert_eq "$(tail -n1 "$H/home/state/inv.status")" "$XTS assign: qd [captain-requested: second]" "4: the last --captain-requested wins, and its words ride any assign"
xput home/state/pay.meta $'kind=roomchief\n'
xrun assign pay lat
assert_eq "$(cat "$H/home/data/pay/timeline.log")" "$XTS assign: lat" "4: a task with a meta gets the line in its timeline too"
rm -f "$H/home/state/pay.meta"
rm -rf "$H/home/state/.wake-spool"
xput home/state/.wake-spool 'not a dir'
xrun assign pay qe
assert_eq "$XN_RC" 0 "4: a wake that cannot publish is no failure"
assert_contains "$(xerr)" "WARN: assign: the durable wake could not be published - the rows are STAMPED, but your drain will not announce it; check @H/home/state/.wake-spool" "4: ... it is a WARN"
assert_contains "$(cat "$H/home/records/backlog.md")" "- [ ] qe - e; domain:pay" "4: ... and the row is stamped"
rm -f "$H/home/state/.wake-spool" "$H"/home/state/.wake-tmp.*
if [ "$(id -u)" != 0 ]; then
  chmod 555 "$H/home/state/backups"
  xbefore="$(cat "$H/home/records/backlog.md")"
  xrun assign pay wi
  chmod 755 "$H/home/state/backups"
  assert_eq "$XN_RC:$(xout)" "1:" "4: a backup that cannot be claimed ends assign 1"
  assert_contains "$(xerr)" "WARN: records backup: could not create @H/home/state/backups/domain-assign-1767225600-" "4: ... its WARN"
  assert_contains "$(xerr)" ".tar.gz (is @H/home/state/backups writable?) - no backup archive was taken" "4: ... naming the directory"
  assert_eq "$(cat "$H/home/records/backlog.md")" "$xbefore" "4: ... before any write"
fi

# 5. assign refusals, nothing written; the ledger lock; the ledger's mode; a
#    registry past the pipe's capacity.
XAU="ERROR: usage: ac-domain.sh assign <name> <backlog-id>... [--captain-requested '<words>']"
XNAME="(charset [a-z0-9-], no path separators) - refusing to derive a package path from it"
xrefuse "$XAU" assign
xrefuse "$XAU" assign pay
xrefuse "$XAU" assign '' wi
xrefuse "$XAU" assign pay --captain-requested words
xrefuse "ERROR: --captain-requested needs the captain's words (the authority is the record)" assign pay wi --captain-requested
xrefuse "ERROR: --captain-requested needs the captain's words (the authority is the record)" assign pay wi --captain-requested ''
xrefuse "ERROR: not a legal crewdomain name: '../x' $XNAME" assign ../x wi
xrefuse "ERROR: not a legal crewdomain name: 'UPPER' $XNAME" assign UPPER wi
xrefuse 'ERROR: duplicate backlog id "wi wb" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' assign pay 'wi wb' 'wi wb'
xrefuse "ERROR: empty backlog id in the argument list - refusing before any write" assign pay wi ''
xrefuse "ERROR: no VALID crewdomain 'ghost' in records/crewdomains.md" assign ghost wi
xrefuse "ERROR: crewdomain 'noscope' has an empty scope: - it is not routable, and the chief may not invent scope text for it" assign noscope wi
for xi in dup nodash; do xrefuse "ERROR: no single row for '$xi' in @H/home/records/backlog.md" assign pay wi "$xi"; done
# A row under any section but Queued or In flight is refused.
for xi in q3:'Queued (3)' park:Parked pre:''; do
  xbefore="$(xworld)"
  xrun assign pay "${xi%%:*}"
  assert_eq "$XN_RC:$(xout):$(sed -n 1p "$TMP/x.err" | cut -d- -f1)" "1::ERROR: '${xi%%:*}' sits under '## ${xi#*:}' " "5: '${xi%%:*}' under '## ${xi#*:}' is refused"
  assert_eq "$(xworld)" "$xbefore" "5: ... with nothing written"
done
mv "$H/home/records/backlog.md" "$H/home/records/backlog.keep"
xrefuse "ERROR: no fleet backlog at @H/home/records/backlog.md" assign pay wi
mv "$H/home/records/backlog.keep" "$H/home/records/backlog.md"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/records/backlog.md"
  xrun assign pay wi
  chmod 644 "$H/home/records/backlog.md"
  assert_eq "$XN_RC:$(xout)" "2:" "5: an unreadable ledger ends assign with the row finder's status"
fi
# The ledger lock: a LIVE writer holding it is waited out
# (AC_TASK_LOCK_TIMEOUT) and refused with nothing written, as ac-task.sh does.
mkdir "$H/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$H/home/records/.backlog.md.lock/pid"
XENV=(AC_TASK_LOCK_TIMEOUT=1); xrun assign pay wg; XENV=()
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: records/backlog.md is locked by another writer - nothing written" "5: assign refuses a live holder's lock"
case "$(cat "$H/home/records/backlog.md")" in *"wg - w g; domain"*) fail "5: ... with nothing written" ;; esac
assert_eq "$(cat "$H/home/records/.backlog.md.lock/pid")" "$$" "5: ... and the holder's lock left as it was"
rm -rf "$H/home/records/.backlog.md.lock"
xrun assign pay wg
assert_contains "$XN_RC:$(cat "$H/home/records/backlog.md")" "- [ ] wg - w g; domain:pay" "5: the unlocked assign stamps"
assert_contains "$(for xf in "$H"/home/state/backups/*; do tar -tzf "$xf"; done)" "records/.backlog.md.lock/pid" "5: the backup, taken under the lock, carries the lock dir"
chmod 600 "$H/home/records/backlog.md"
xrun assign pay wh
assert_eq "$XN_RC:$(ls -l "$H/home/records/backlog.md" | cut -c1-10)" "0:-rw-------" "5: the ledger keeps its mode"
chmod 644 "$H/home/records/backlog.md"
# A registry past the pipe's capacity with the domain first: the lookup reads
# the whole parse.
awk 'BEGIN { print "- pay - payments - scope: money (added x)"; for (i = 0; i < 20000; i++) printf "- d%d - charter text - scope: some scope (added x)\n", i }' >"$H/home/records/crewdomains.md"
xrun assign pay wi
assert_eq "$XN_RC:$(xerr)" "0:" "5: a registry past the pipe's capacity holds the domain"
# The point of the lock: assign reads and rewrites the ledger inside it, so a
# commit its holder makes before releasing survives the stamp. The holder acts
# on a checkpoint, never a timer: an awk stub marks the END of the registry
# parse, after which assign runs only in-process checks before it takes the
# lock, so a slow start cannot let the release come first and the row pass
# without a waiting writer.
x4
xrealawk="$(command -v awk)"; mkdir -p "$TMP/xawkstub"
printf '#!/bin/sh\n%s "$@"; rc=$?\n: >"$STUB_DIR/awk.seen"\nexit $rc\n' "$xrealawk" >"$TMP/xawkstub/awk"; chmod +x "$TMP/xawkstub/awk"
xatlock() {  # the waiting assign has parsed the registry - it is at the lock
  local i; for i in $(seq 1 150); do [ ! -e "$H/awk.seen" ] || { /bin/sleep 0.5; return 0; }; /bin/sleep 0.2; done
  fail "5: the waiting assign never reached the lock"
}
mkdir "$H/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$H/home/records/.backlog.md.lock/pid"
rm -f "$H/awk.seen"
XPATH="$TMP/xawkstub:$XSTUBS:$PATH"; XENV=(AC_TASK_LOCK_TIMEOUT=30); (xrun assign pay qb; exit "$XN_RC") & xlpid=$!; XENV=(); XPATH=""
xatlock
case "$(cat "$H/home/records/backlog.md")" in *"qb - row b; domain"*) fail "5: assign wrote while another writer held the ledger lock" ;; esac
printf -- '- [ ] heldrow - committed by the lock holder\n' >>"$H/home/records/backlog.md"
rm -rf "$H/home/records/.backlog.md.lock"
wait "$xlpid" || fail "5: the waiting assign failed: $(xerr)"
assert_contains "$(cat "$H/home/records/backlog.md")" "- [ ] heldrow - committed by the lock holder" "5: the holder's commit survives"
assert_contains "$(cat "$H/home/records/backlog.md")" "- [ ] qb - row b; domain:pay" "5: ... and the stamp lands after the release"
[ ! -e "$H/home/records/.backlog.md.lock" ] || fail "5: assign releases the lock it took"
# ... and its CHECKS run inside the lock too: a row the holder moves to In
# flight before releasing is refused, never stamped on a reading taken before.
mkdir "$H/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$H/home/records/.backlog.md.lock/pid"
rm -f "$H/awk.seen"
XPATH="$TMP/xawkstub:$XSTUBS:$PATH"; XENV=(AC_TASK_LOCK_TIMEOUT=30); (xrun assign pay qd; exit "$XN_RC") & xlpid=$!; XENV=(); XPATH=""
xatlock
awk '$0 == "- [ ] qd - d" { next } { print } $0 == "## In flight" { print "- [ ] qd - d" }' "$H/home/records/backlog.md" >"$TMP/xmoved"
cat "$TMP/xmoved" >"$H/home/records/backlog.md"
rm -rf "$H/home/records/.backlog.md.lock"
xlrc=0; wait "$xlpid" || xlrc=$?
assert_eq "$xlrc:$(xerr)" "1:ERROR: 'qd' sits under '## In flight' - adopting live work into a domain is the captain's call: re-run with --captain-requested '<the captain's words>' (a stamp changes nothing in the flying crewmate's env, but the authority must be on record)" \
  "5: the row the holder moved is judged as it now stands"
case "$(cat "$H/home/records/backlog.md")" in *"qd - d; domain"*) fail "5: ... and never stamped" ;; esac
# EXCLUSIVE TEMP: a symlink planted at `<ledger>.tmp.<pid>` is left alone -
# the next name is claimed and nothing is written through it. The run starts
# behind a fifo gate and execs into the entry as the pid the name is planted
# for. The watchdog is started from a substitution, so it is no job of the
# gate's: killing a job made bash print its `Terminated` notice into the row's
# output, or not, by timing.
x4
cat >"$TMP/xgate.sh" <<'GATE'
#!/usr/bin/env bash
_id="$(/bin/ps -o lstart= -p $$)"
_wd="$( ( sleep 60; [ "$(/bin/ps -o lstart= -p $$)" != "$_id" ] || kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 & printf '%s' $! )"
read -r _ <"$1"
kill "$_wd" 2>/dev/null || true
cd "$2" || exit 1
b="$3"; shift 3
exec "$b/ac-domain.sh" "$@"
GATE
chmod +x "$TMP/xgate.sh"
xplant() {  # xplant <temp under the home> <args...> - the run, with a link planted at <temp>.tmp.<its pid>
  local t="$1" gate pid; shift
  gate="$H/gate.fifo"; mkfifo "$gate"
  printf 'victim bytes\n' >"$H/victim"
  env -u AC_SCOPE LC_ALL=C AC_HOME="$H/home" TMPDIR="$H/tmp" PATH="$XSTUBS:$PATH" STUB_DIR="$H" \
    "$TMP/xgate.sh" "$gate" "$H/cwd" "$BIN" "$@" </dev/null >"$TMP/xplant.out" 2>&1 &
  pid=$!
  ln -s "$H/victim" "$H/home/$t.tmp.$pid"
  printf x >"$gate"
  wait "$pid" || fail "the planted run failed: $(cat "$TMP/xplant.out")"
  rm -f "$gate"
  xplanted="$H/home/$t.tmp.$pid"
}
xplant records/backlog.md assign pay qa
assert_contains "$(cat "$TMP/xplant.out")" "assigned qa to crewdomain pay" "5: the planted run completes"
[ ! -L "$H/home/records/backlog.md" ] || fail "5: the ledger stays a regular file"
assert_eq "$(cat "$H/victim")" "victim bytes" "5: nothing is written through a planted temp name"
assert_contains "$(cat "$H/home/records/backlog.md")" "- [ ] qa - row a; domain:pay (repo: alpha)" "5: ... the ledger itself is stamped"
[ -L "$xplanted" ] || fail "5: the planted link is left where it was"

# 6. unassign: the lock; the byte-identical restore, both arms; the
#    refusals; a retired domain's token (the ORPHAN remedy); a byte that is
#    not UTF-8 under C.
x6() {
  x4
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - before; domain:pay\n\n## In flight\n\n- [ ] fly - in flight; domain:pay (repo: alpha)\n\n## Queued\n\n- [ ] ua - row a; domain:pay (repo: alpha)\n- [ ] ub - row b; domain:pay\n- [ ] uc - mid (repo: x) prose; domain:pay (repo: alpha)\n- [ ] other - other; domain:inv (repo: alpha)\n- [ ] plain - untokened\n- [ ] mid - see; domain:pay (repo: x) for context (repo: alpha)\n- [ ] gonerow - retired; domain:gone\n- [ ] lat - caf\351; domain:pay (repo: alpha)\n- [ ] latu - caf\351 u; domain:pay\n- [ ] bs - C:\\new; domain:pay\n\n## Done\n\n- [x] fintok - done; domain:pay\n'
}
x6
mkdir "$H/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$H/home/records/.backlog.md.lock/pid"
xbefore="$(cat "$H/home/records/backlog.md")"
XENV=(AC_TASK_LOCK_TIMEOUT=1); xrun unassign pay ua; XENV=()
assert_eq "$XN_RC:$(xerr)" "1:ERROR: records/backlog.md is locked by another writer - nothing written" "6: unassign refuses a live holder's lock"
assert_eq "$(cat "$H/home/records/backlog.md")" "$xbefore" "6: ... with nothing written"
rm -rf "$H/home/records/.backlog.md.lock"
xrun unassign pay ua ub uc
assert_eq "$XN_RC:$(xout)" "0:backup: @H/home/state/backups/domain-unassign-1767225600.tar.gz
- [ ] ua - row a (repo: alpha)
- [ ] ub - row b
- [ ] uc - mid (repo: x) prose (repo: alpha)
unassigned ua,ub,uc from crewdomain pay" "6: the strip restores each row, both arms"
assert_eq "$(tail -n1 "$H/home/state/pay.status")" "$XTS unassign: ua,ub,uc" "6: the status line"
[ ! -e "$H/home/state/.wake-spool" ] || fail "6: unassign publishes no wake"
xrefuse "ERROR: 'other' carries no domain:pay token at its grammar position (it is assigned to 'inv') - nothing to reverse" unassign pay other
xrefuse "ERROR: 'fintok' sits under '## Done', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay fintok
xrefuse "ERROR: 'pre' sits under '## ', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay pre
xrefuse "ERROR: usage: ac-domain.sh unassign <name> <id>..." unassign
xrefuse "ERROR: usage: ac-domain.sh unassign <name> <id>..." unassign pay
xrefuse "ERROR: no single row for 'nosuch' in @H/home/records/backlog.md" unassign pay nosuch
xrefuse 'ERROR: duplicate backlog id "ua" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' unassign pay ua ua
xrun unassign gone gonerow
assert_eq "$XN_RC:$(grep -c "gonerow - retired$" "$H/home/records/backlog.md")" "0:1" "6: a domain no registry knows can still be stripped"
xrun unassign pay lat
assert_eq "$XN_RC:$(LC_ALL=C grep -c '^- \[ \] lat - caf.* (repo: alpha)$' "$H/home/records/backlog.md")" "0:1" "6: a byte that is not UTF-8 strips under C"
mv "$H/home/records/backlog.md" "$H/home/records/backlog.keep"
xrefuse "ERROR: no fleet backlog at @H/home/records/backlog.md" unassign pay ua
mv "$H/home/records/backlog.keep" "$H/home/records/backlog.md"

# 7. queue: the slice with epic inheritance, headers once per section, rows
#    before a heading headerless, indented lines never, names as strings; an
#    unreadable ledger.
x7() {
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - pre; domain:pay\n\n## In flight\n\n- [ ] f1 - flying; domain:pay (repo: a)\n\n## Queued\n\n- [ ] big [EPIC] - epic; domain:pay (repo: a)\n- [ ] s1 - story; epic:big\n- [ ] ie [EPIC] - inv epic; domain:inv\n- [ ] s2 - own token under another epic; epic:ie; domain:pay\n- [ ] s3 - story of inv; epic:ie\n- [ ] m1 - a domain:pay mention\n- [ ] n7 - seven; domain:7\n- [ ] n07 - oh-seven; domain:07\n  - [ ] indented; domain:pay\n\n## Parked\n\n- [ ] p1 - other domain; domain:inv\n\n## Done\n\n- [x] d1 - done; domain:pay\n- [x] d2 - story of a done epic; epic:big\n'
}
x7
xrun queue pay
assert_eq "$XN_RC:$(xout)" "0:- [ ] pre - pre; domain:pay
## In flight
- [ ] f1 - flying; domain:pay (repo: a)
## Queued
- [ ] big [EPIC] - epic; domain:pay (repo: a)
- [ ] s1 - story; epic:big (via epic:big)
- [ ] s2 - own token under another epic; epic:ie; domain:pay
## Done
- [x] d1 - done; domain:pay
- [x] d2 - story of a done epic; epic:big (via epic:big)" "7: the slice"
xrun queue pay --ids
assert_eq "$(xout | tr '\n' ' ')" "pre f1 big s1 s2 d1 d2 " "7: --ids"
xrun queue 07; assert_eq "$(xout)" "## Queued
- [ ] n07 - oh-seven; domain:07" "7: 07 is not 7"
xrun queue inv
assert_eq "$XN_RC:$(xout)" "0:## Queued
- [ ] ie [EPIC] - inv epic; domain:inv
- [ ] s3 - story of inv; epic:ie (via epic:ie)
## Parked
- [ ] p1 - other domain; domain:inv" "7: a story with its own token is never inherited by the epic's domain"
xrun queue ghost; assert_eq "$XN_RC:$(xout)" "0:" "7: an unregistered name is an empty slice"
xrefuse "ERROR: usage: ac-domain.sh queue <name> [--ids]" queue
rm -f "$H/home/records/backlog.md"
xrun queue pay; assert_eq "$XN_RC:$(xout)" "0:no fleet backlog" "7: no ledger is a stdout line"
x7
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/records/backlog.md"
  xrun queue pay
  chmod 644 "$H/home/records/backlog.md"
  assert_eq "$XN_RC:$(xout):$(xerr)" "2::ERROR: cannot read @H/home/records/backlog.md" "7: an unreadable ledger is exit 2, nothing on stdout"
fi

# 8. qa-repo: every argument form, read/set/force/clear, REUSE of the same
#    project, the member's [:space:], a symlinked clone's physical path; --set
#    takes a NAME, and --set and --clear are the crewchief's.
rm -rf "$H/home/crewdomains"
mkdir -p "$H/home/crewdomains/proof/projects"
for xp in alpha e2e sym; do ln -s "../../../projects/$xp" "$H/home/crewdomains/proof/projects/$xp"; done
mkdir "$H/home/crewdomains/proof/projects/plain"
XQU="ERROR: usage: ac-domain.sh qa-repo <name> [--set <project> [--force] | --clear]"
XQNONE="ERROR: domain proof declares no e2e repository - declare it with: ac-domain.sh qa-repo proof --set <project>, or leave it undeclared and QA takes the profile-driven route (ac-verify qa)"
xrefuse "$XQU" qa-repo
xrefuse "ERROR: --set needs a project name" qa-repo proof --set
xrefuse "ERROR: --set needs a project name" qa-repo proof --set ''
xrefuse "ERROR: unknown qa-repo argument: bogus" qa-repo proof bogus
xrefuse "ERROR: unknown qa-repo argument: e2e" qa-repo proof --clear e2e
xrefuse "$XQNONE" qa-repo proof --force
xrun qa-repo proof --set e2e
assert_eq "$XN_RC:$(xout)" "0:qa-repo for proof: e2e (@H/home/projects/e2e)" "8: set"
xrefuse "ERROR: domain proof already declares an e2e repository: @H/home/projects/e2e - reuse it. Moving the declaration is deliberate: re-run with --force." qa-repo proof --set e2e
xrefuse "ERROR: plain resolves to no git repository through @H/home/crewdomains/proof/projects/plain" qa-repo proof --set plain
xrun qa-repo proof --force --set sym; assert_eq "$(xout)" "qa-repo for proof: sym (@H/real)" "8: a symlinked clone reads physically"
xrun qa-repo proof --clear; assert_eq "$XN_RC:$(xout)" "0:qa-repo cleared for proof - QA returns to the profile-driven route" "8: clear"
[ ! -e "$H/home/crewdomains/proof/qa-repo" ] || fail "8: ... the member is gone"
xrun qa-repo proof --clear; assert_eq "$XN_RC" 0 "8: clear is idempotent"
xrun qa-repo proof --set e2e --clear; assert_contains "$(xout)" "cleared" "8: the last of --set/--clear wins"
xrun qa-repo proof --clear --set e2e; assert_contains "$(xout)" "qa-repo for proof: e2e" "8: ... either way round"
xput home/crewdomains/proof/qa-repo $'nosuch\n'
xrun qa-repo proof --set alpha; assert_eq "$XN_RC:$(cat "$H/home/crewdomains/proof/qa-repo")" "0:alpha" "8: a stale declaration is replaced without --force"
xput home/crewdomains/proof/qa-repo $' e 2e \t\nignored\n'
xrun qa-repo proof; assert_eq "$XN_RC:$(xout)" "0:@H/home/projects/e2e" "8: every blank of the first line is deleted"
xput home/crewdomains/proof/qa-repo $'\ne2e\n'
xrefuse "$XQNONE" qa-repo proof
rm -f "$H/home/crewdomains/proof/qa-repo"
xrefuse 'ERROR: --set takes a project NAME, not a path: "../../../projects/e2e"' qa-repo proof --set ../../../projects/e2e
xrefuse 'ERROR: --set takes a project NAME, not a path: "alpha/.git"' qa-repo proof --set alpha/.git --force
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: qa-repo --set is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - which repository a domain's proof runs in is fleet routing, and only the crewchief sets it" qa-repo proof --set e2e
XENV=()
xrun qa-repo proof --set e2e
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: qa-repo --clear is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - which repository a domain's proof runs in is fleet routing, and only the crewchief sets it" qa-repo proof --clear
xrun qa-repo proof
XENV=()
assert_eq "$XN_RC:$(xout)" "0:@H/home/projects/e2e" "8: a scoped session still reads the declaration"
XENV=(AC_SCOPE=); xrun qa-repo proof --set alpha --force; XENV=()
assert_eq "$XN_RC:$(cat "$H/home/crewdomains/proof/qa-repo")" "0:alpha" "8: an empty AC_SCOPE is unscoped"
rm -f "$H/home/crewdomains/proof/qa-repo"
mkdir -p "$H/home/crewdomains/proof/qa-repo"
xrun qa-repo proof --clear
assert_eq "$XN_RC" 1 "8: an rm that fails ends --clear with its status"
rmdir "$H/home/crewdomains/proof/qa-repo"
XLC=en_US.UTF-8
xput home/crewdomains/proof/qa-repo $'e2e\302\240\n'
xrun qa-repo proof; assert_eq "$(xout)" "@H/home/projects/e2e" "8: under UTF-8 tr deletes a no-break space too"
XLC=C
xput home/crewdomains/proof/qa-repo $'e2e\351\n'
xrun qa-repo proof; assert_eq "$XN_RC:$(xout)" "1:" "8: under C a byte that is not UTF-8 stays and nothing resolves"

# 9. retire: the refusals, OPEN rows (rows before any heading open), the
#    flying chiefs, then the Done history it leaves - the kept package,
#    re-adopted by new.
x9() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/crewdomains/pay/records"
  xput home/crewdomains/pay/CREWMATE.md $'# Crewmate instructions: pay\n'
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- Bad - c - scope: s (added x)\n'
  xput home/records/backlog.md $'# Backlog\n- [ ] p0 - before any heading; domain:pay\n\n## Queued\n\n- [ ] q1 - queued; domain:pay\n\n## Done\n\n- [x] e1 [EPIC] - done epic; domain:pay\n- [x] dd - done; domain:pay\n'
}
x9
xrefuse "ERROR: usage: ac-domain.sh retire <name>" retire
xrefuse "ERROR: not a legal crewdomain name: 'Bad' $XNAME" retire Bad
xrefuse "ERROR: crewdomain 'pay' still holds OPEN tokened rows - unassign them first:
p0
q1" retire pay
xput home/records/backlog.md $'# Backlog\n\n## Done\n\n- [x] e1 [EPIC] - done epic; domain:pay\n- [x] dd - done; domain:pay\n'
xput home/state/b-chief.meta $'kind=roomchief\ndomain=inv\ndomain=pay\n'
xput home/state/A-chief.meta $'domain=pay\n'
xput home/state/c-chief.meta $'domain=inv\n'
mkdir "$H/home/state/d-chief.meta"
xrefuse "ERROR: crewdomain 'pay' has a domainchief in flight (A, b) - demote it first" retire pay
rm -f "$H/home/state/A-chief.meta" "$H/home/state/b-chief.meta"
xrun retire pay
assert_eq "$XN_RC:$(xout):$(xerr)" "0:backup: @H/home/state/backups/domain-retire-1767225600.tar.gz
retired crewdomain pay - registry line removed; the package at crewdomains/pay is kept (knowledge is never deleted by tooling):" "9: retire"
assert_eq "$(cat "$H/home/records/crewdomains.md")" "# Crewdomains

- inv - invoices - scope: bills (added x)
- Bad - c - scope: s (added x)" "9: the registry line removed"
assert_eq "$(cat "$H/home/state/pay.status")" "$XTS retire" "9: the status line"
[ -f "$H/home/crewdomains/pay/CREWMATE.md" ] || fail "9: the package is kept"
# The orphan scans read OPEN rows only - a retired domain's Done rows are its
# kept provenance.
xrun list
case "$(xout)" in *ORPHAN-TOKEN*) fail "9: Done history is provenance, never an orphan: $(xout)" ;; esac
assert_contains "$(xout)" "UNREGISTERED	pay	" "9: the kept package is UNREGISTERED"
xrun validate
assert_eq "$XN_RC:$(xout)" "1:INVALID - Bad - c - scope: s (added x): bad id charset" "9: validate names only the INVALID registry line"
# A directory without the package's three members is no kept package: still a collision.
xrefuse "ERROR: name 'pay' collides with an existing directory at crewdomains/pay" new pay --scope s --charter c --no-projects
# A KEPT package - CREWMATE.md, records/projects.md and projects/ - is
# RE-ADOPTED by `new`: the routing line is written again, the kept knowledge is
# not touched, and --projects adds only the links the view lacks.
mkdir -p "$H/home/crewdomains/pay/projects"
xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\nkept prose\n\n## beta\n'
ln -s ../../../projects/beta "$H/home/crewdomains/pay/projects/beta"
cp "$H/home/crewdomains/pay/CREWMATE.md" "$TMP/xkept.crewmate"; cp "$H/home/crewdomains/pay/records/projects.md" "$TMP/xkept.detail"
xrun new pay --scope money --charter payments --projects alpha,beta
assert_eq "$XN_RC:$(xout):$(xerr)" "0:re-adopted crewdomain pay at crewdomains/pay (1 project link(s) added; the kept package is otherwise unchanged):" "9: new re-adopts it"
assert_eq "$(tail -n1 "$H/home/records/crewdomains.md")" "- pay - payments - scope: money (added $XTS)" "9: the routing line written again"
cmp -s "$H/home/crewdomains/pay/CREWMATE.md" "$TMP/xkept.crewmate" || fail "9: CREWMATE.md byte-unchanged"
cmp -s "$H/home/crewdomains/pay/records/projects.md" "$TMP/xkept.detail" || fail "9: the kept detail byte-unchanged"
assert_eq "$(readlink "$H/home/crewdomains/pay/projects/beta")" "../../../projects/beta" "9: the view's own beta link as it was"
assert_eq "$(readlink "$H/home/crewdomains/pay/projects/alpha"):$(readlink "$H/home/crewdomains/pay/projects/alpha.yaml")" "../../../projects/alpha:../../../projects/alpha.yaml" "9: the missing project linked, with its .yaml"
[ ! -e "$H/home/crewdomains/pay/projects/beta.yaml" ] || fail "9: a project already in the view is left as it is"
xrun list
assert_contains "$(xout)" "VALID	pay	projects: 2" "9: the domain is VALID again"
case "$(xout)" in *"UNREGISTERED	pay"*) fail "9: ... and no longer UNREGISTERED" ;; esac
# A re-adoption that fails mid-write undoes only what it made: the kept
# package stays whole, and the registry is not written.
mkdir -p "$H/home/crewdomains/keep2/records" "$H/home/crewdomains/keep2/projects"
printf '# Crewmate instructions: keep2\n' >"$H/home/crewdomains/keep2/CREWMATE.md"; printf '# Projects: keep2\n' >"$H/home/crewdomains/keep2/records/projects.md"
cp "$H/home/crewdomains/keep2/CREWMATE.md" "$TMP/xkeep2.crewmate"; cp "$H/home/crewdomains/keep2/records/projects.md" "$TMP/xkeep2.detail"
echo 2 >"$H/ln.fail-at"; rm -f "$H/ln.count"
xrun new keep2 --scope s --charter c --projects alpha
rm -f "$H/ln.fail-at" "$H/ln.count"
assert_eq "$XN_RC:$(xerr)" "1:ln: the stub refuses
rolled back the re-adoption of the kept package at @H/home/crewdomains/keep2 - it is as it was, and nothing was registered" "9: the failing re-adoption names what it did"
assert_eq "$(ls -A "$H/home/crewdomains/keep2/projects")" "" "9: ... the link it made gone"
cmp -s "$H/home/crewdomains/keep2/CREWMATE.md" "$TMP/xkeep2.crewmate" && cmp -s "$H/home/crewdomains/keep2/records/projects.md" "$TMP/xkeep2.detail" \
  || fail "9: ... and the kept package's knowledge byte-unchanged"
case "$(cat "$H/home/records/crewdomains.md")" in *"keep2"*) fail "9: ... and nothing registered" ;; esac
x9
xput home/records/backlog.md $'## Done\n'
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/records/backlog.md"
  xrun retire pay
  chmod 644 "$H/home/records/backlog.md"
  assert_eq "$XN_RC:$(xout):$(xerr)" "2::ERROR: cannot read @H/home/records/backlog.md" "9: an unreadable ledger is exit 2"
  assert_contains "$(cat "$H/home/records/crewdomains.md")" "- pay - payments" "9: ... and retires nothing"
fi
xplant records/crewdomains.md retire pay
assert_contains "$(cat "$TMP/xplant.out")" "retired crewdomain pay" "9: the planted run completes"
[ ! -L "$H/home/records/crewdomains.md" ] || fail "9: the registry stays a regular file"
assert_eq "$(cat "$H/victim")" "victim bytes" "9: nothing is written through a planted temp name"
case "$(cat "$H/home/records/crewdomains.md")" in *"- pay -"*) fail "9: ... the registry itself loses the line" ;; *"- inv -"*) ;; *) fail "9: ... and keeps the others" ;; esac

# 10. list: ABSENT (absent, a directory), EMPTY; the table: every INVALID
#     reason, a lone `- `, unset scope, dangling and .yaml entries, the
#     in-flight line, UNREGISTERED (legal, illegal and symlinked dirs), an
#     ORPHAN-TOKEN on an open row; an unreadable ledger; a 0xE9 registry byte
#     under C.
x10() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state"
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] stray - names a ghost; domain:ghost\n- [ ] m1 - a domain:ghost mention\n'
}
x10
xrun list; assert_eq "$XN_RC:$(xout | head -n1)" "0:$XABSENT" "10: absent"
mkdir "$H/home/records/crewdomains.md"
xrun list; assert_eq "$XN_RC:$(xout | head -n1)" "0:$XABSENT" "10: a directory is ABSENT"
rmdir "$H/home/records/crewdomains.md"
xput home/records/crewdomains.md $'# Crewdomains\n\nprose\n'
xrun list; assert_eq "$XN_RC:$(xout | head -n1)" "0:EMPTY: records/crewdomains.md present, 0 entries - no crewdomains registered" "10: EMPTY"
x10t() {
  x10; rm -rf "$H/elsewhere"
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money - and more (added x)\n- \n- nodate - c - scope: s\n- bad - c - home: /x - scope: s (added x)\n- noscope - c (added x)\n- nocharter - scope: s (added x)\n- Pay - c - scope: s (added x)\n- pay - again - scope: s (added x)\n- unset - c - scope:  (added x)\n- crlf - c - scope: s (added x)\r\n'
  mkdir -p "$H/home/crewdomains/pay/projects" "$H/home/crewdomains/unset" "$H/home/crewdomains/kept/records" "$H/home/crewdomains/Upper" "$H/home/crewdomains/.dot" "$H/elsewhere/linkd"
  ln -s ../../../projects/alpha "$H/home/crewdomains/pay/projects/alpha"
  ln -s ../../../projects/alpha.yaml "$H/home/crewdomains/pay/projects/alpha.yaml"
  ln -s ../../../projects/gone "$H/home/crewdomains/pay/projects/gone"
  mkdir "$H/home/crewdomains/pay/projects/copied"
  ln -s "$H/elsewhere/linkd" "$H/home/crewdomains/linkd"
  : >"$H/home/crewdomains/afile"
  xput home/state/f1-chief.meta $'domain=pay\n'; xput home/state/f2-chief.meta $'domain=pay\n'
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] q1 - queued; domain:pay\n- [ ] s1 - story; epic:q1\n- [ ] stray - names a ghost; domain:ghost\n- [ ] latin - caf\351\n\n## In flight\n\n- [ ] f1 - flying; domain:pay\n\n## Done\n\n- [x] d1 - done; domain:pay\n- [x] d2 [failed] - failed; domain:pay\n'
}
x10t
xrun list
assert_eq "$XN_RC:$(xout)" "0:VALID	pay	projects: 3
	charter: payments
	scope: money - and more
	backlog: queued 2, in flight 1, done 1
	in flight: f1, f2
INVALID	- 	reason: missing \"(added ...)\"
INVALID	- nodate - c - scope: s	reason: missing \"(added ...)\"
INVALID	- bad - c - home: /x - scope: s (added x)	reason: unknown field \"home:\"
INVALID	- noscope - c (added x)	reason: missing \"scope:\" field
INVALID	- nocharter - scope: s (added x)	reason: missing charter field
INVALID	- Pay - c - scope: s (added x)	reason: bad id charset
INVALID	- pay - again - scope: s (added x)	reason: duplicate id
VALID	unset	projects: 0
	charter: c
	scope: (unset - not routable until a scope: is added)
	backlog: queued 0, in flight 0, done 0
INVALID	- crlf - c - scope: s (added x)$(printf '\r')	reason: missing \"(added ...)\"
UNREGISTERED	kept	package on disk with no VALID registry line - re-adopt it with \`new\`, restore its line in records/crewdomains.md, or leave it as kept knowledge
UNREGISTERED	linkd	package on disk with no VALID registry line - re-adopt it with \`new\`, restore its line in records/crewdomains.md, or leave it as kept knowledge
ORPHAN-TOKEN	ghost	stray - the row names a domain with no VALID registry line (unassign it, or re-\`new\` the domain)
registered: 10 (invalid 8)" "10: the table"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/records/backlog.md"
  xrun list
  chmod 644 "$H/home/records/backlog.md"
  assert_contains "$(xout)" "WARN	ledger unreadable - backlog tallies and the ORPHAN-TOKEN scan are unavailable" "10: an unreadable ledger is named"
  assert_eq "$XN_RC:$(xerr | sort -u)" "0:ERROR: cannot read @H/home/records/backlog.md" "10: ... and the parser's own line"
fi
xadd home/records/crewdomains.md $'- b\351d - c - scope: s (added x)\n'
xrun list; assert_contains "$(xout)" "INVALID	- b$(printf '\351')d - c - scope: s (added x)	reason: bad id charset" "10: a 0xE9 registry byte under C"

# 11. validate: INVALID lines; every view class; the .yaml WARN; the detail
#     checks; a glob stays a word; the token discipline; a 0xE9 registry byte
#     under C.
x11() {
  x10
  xput home/records/crewdomains.md $'- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- ops - ops - scope: o (added x)\n- \n'
  local v="$H/home/crewdomains/pay/projects"
  mkdir -p "$v" "$H/home/crewdomains/pay/records" "$H/home/crewdomains/inv/projects" "$H/elsewhere"
  ln -s ../../../projects/alpha "$v/alpha"; ln -s ../../../projects/alpha.yaml "$v/alpha.yaml"
  ln -s "$H/home/projects/beta" "$v/beta"; ln -s ../../../projects/beta.yaml "$v/beta.yaml"
  ln -s ../../../projects/e2e "$v/e2e"
  ln -s ../../../projects/aliased "$v/aliased"; ln -s "$H/real" "$H/home/projects/aliased"
  xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\n## alpha\n\n## beta\n\n## e2e\n\n## aliased\n'
  ln -s ../../../projects/gone "$H/home/crewdomains/inv/projects/gone"
  mkdir "$H/home/crewdomains/inv/projects/copied"
  ln -s "$H/elsewhere" "$H/home/crewdomains/inv/projects/out"
  ln -s ../../../projects/alpha "$H/home/crewdomains/inv/projects/wrong"
}
x11
xrun validate
assert_eq "$XN_RC:$(xout)" "1:INVALID - : missing \"(added ...)\"
WARN pay: projects/aliased has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal
WARN pay: projects/e2e has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal
INVALID inv: projects/copied is not a symlink - a domain view LINKS the fleet clones, it never holds a copy
INVALID inv: projects/gone dangles - it resolves to nothing
INVALID inv: projects/out resolves OUTSIDE the fleet clones (@H/elsewhere) - a view may only select from the fleet projects dir
INVALID inv: projects/wrong resolves to @H/home/projects/alpha, not to its OWN clone - a view entry must name the project it links, or it authorizes work on a repository the domain never selected
INVALID token: orphan domain token ghost stray
INVALID token: m1 carries a domain:-shaped run off its grammar position (backtick-quote a mention, or re-stamp with assign)" "11: INVALID lines, every view class, the .yaml WARN, the tokens"
xput home/records/projects.md $'# Projects\n\n- e2e - short (added x)\n- vn - \304\221\341\272\267t h\303\240ng (added x)\n- tail - the unterminated last line here'
xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\n## alpha\n\nshort\n\n\304\221\341\272\267t h\303\240ng\n\nthe unterminated last line here\n\n## beta\n\n## e2e\n\n## aliased\n'
xrun validate
assert_contains "$(xout)" "WARN pay: records/projects.md repeats the FLEET description of vn verbatim" "11: 8 characters, 12 bytes - the description is measured in bytes"
case "$(xout)" in *"description of e2e"*|*"description of tail"*) fail "11: a short description and an unterminated last line are never compared" ;; esac
XLC=en_US.UTF-8; xrun validate; XLC=C
assert_contains "$(xout)" "description of vn" "11: ... under any locale"
xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\n## alpha\n\n## *\n\n## e2e\n\n## aliased\n'
ln -s ../../../projects/beta "$H/home/crewdomains/pay/projects/be ta"
mkdir -p "$H/globcwd2"; touch "$H/globcwd2/zfile"
XCWD=globcwd2; xrun validate; XCWD=cwd
assert_contains "$(xout)" 'WARN pay: records/projects.md documents "## *" but the view does not link it' "11: a glob heading stays a word, whatever the cwd holds"
assert_contains "$(xout)" "INVALID pay: projects/be ta resolves to @H/home/projects/beta, not to its OWN clone" "11: a spaced view entry is checked by resolution"
rm -f "$H/home/crewdomains/pay/projects/be ta" "$H/home/crewdomains/pay/records/projects.md"
xrun validate
case "$(xout)" in *"WARN pay: records"*|*"heading"*) fail "11: no detail file - the detail checks stop" ;; esac
xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] e2 [EPIC] - an untokened epic\n- [ ] s3 - story; epic:e2; domain:inv\n'
xrun validate
case "$(xout)" in *"story s3"*) fail "11: a tokened story under an untokened epic disagrees with nothing" ;; esac
xput home/records/crewdomains.md $'- pay - c - scope: s (added x)\n- b\351d - c - scope: s (added x)\n'
xput home/records/backlog.md $'# Backlog\n'
rm -rf "$H/home/crewdomains"
xrun validate
assert_eq "$XN_RC" 1 "11: a 0xE9 registry byte under C fails validate"
assert_contains "$(xout)" "INVALID - b$(printf '\351')d - c - scope: s (added x): bad id charset" "11: ... on its INVALID line"

pass
