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
# constrains, in tests/sh/ac-maintenance-core.test.sh.

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

# --- AC-2.3: list renders and ALWAYS exits 0 ---------------------------------
# A digest block may never take session start down - the rule src/deputy.ts
# states for its own list, adopted here for the same reason.
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

# --- differential: src/domain.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-domain.sh under bash vs src/domain.ts through bin/ac-domain.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home holding git clones alpha, beta and e2e under projects/ (alpha and beta with a .yaml), records/ and state/; argv and env (the side root spelled @H, substituted in values only); cwd (<side>/cwd, an EMPTY dir); TMPDIR (<side>/tmp); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - a date answering one fixed instant per format (or failing per sentinel) and an ln failing on the Nth call per sentinel; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT, pids PID, mktemp suffixes X), then the world a row may touch: every path under the home with each link's target, the mode and bytes of every registry, ledger, package member, status log and timeline, the spool records and temps, the backup listings (tar -tzf) and the TMPDIR listing - a fleet clone's working tree is in the path listing.
xobin="$(make_oracle_bin ac-domain)"
# The frozen entry calls ac_records_backup, retired from
# bin/ac-maintenance-lib.sh once src/learn.ts took its last caller; the
# oracle's own lib copy gets it back, frozen at
# tests/fixtures/ac-maintenance-retired.sh.
cat "$ROOT/tests/fixtures/ac-maintenance-retired.sh" >>"$xobin/ac-maintenance-lib.sh"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
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
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() {
  rm -rf "$H"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/projects" "$H/cwd" "$H/tmp"
  local p; for p in alpha beta e2e; do git init -q -b main "$H/home/projects/$p"; done
  printf 'test: {}\n' >"$H/home/projects/alpha.yaml"; printf 'test: {}\n' >"$H/home/projects/beta.yaml"
}
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xadd() { printf '%s' "${2//@H/$H}" >>"$H/$1"; }                                 # xadd <path under the side> <bytes>
XLC=C; XENV=(); XHOME=home; XHOMELESS=0; XPATH=""; XCWD=cwd
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=("LC_ALL=$XLC" "PATH=${XPATH:-$XSTUBS:$PATH}" "STUB_DIR=$h" "TMPDIR=$h/tmp")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$h/$XHOME")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h/$XCWD" && env -u AC_HOME -u AC_SCOPE -u AC_BACKEND -u TMPDIR -u EPOCHSECONDS -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN \
    "${e[@]}" "$bin/ac-domain.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
xnorm() {
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-domain#ROOT#g" -e "s#$ROOT#ROOT#g" -e 's/\.tmp\.[0-9]+/.tmp.PID/g' \
    -e 's/(1767225600000000000)\.[0-9]+\./\1.PID./g' -e 's/\.wake-tmp\.[A-Za-z0-9]{8}/.wake-tmp.XXXXXXXX/g' \
    -e 's/ac-domain-line\.[A-Za-z0-9]{6}/ac-domain-line.XXXXXX/g' "$1"
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$xobin" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$BIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "domain differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "domain differential stdout differs for '$*' at line $(xrow): $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_io() {
  xsame_rc_out "$@"
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "domain differential stderr differs for '$*' at line $(xrow): $(diff "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - what a row may change
  local h="$1" f p
  (cd "$h/home" && find . -path './projects/*/.git' -prune -o -print 2>/dev/null | sed -E -e 's/\.tmp\.[0-9]+/.tmp.PID/g' \
    -e 's/(1767225600000000000)\.[0-9]+\./\1.PID./g' -e 's/\.wake-tmp\.[A-Za-z0-9]{8}/.wake-tmp.XXXXXXXX/g' | LC_ALL=C sort)
  printf '== links\n'
  (cd "$h/home" && find . -path './projects/*/.git' -prune -o -type l -exec stat -f '%N -> %Y' {} + 2>/dev/null | LC_ALL=C sort)
  printf '== spool\n'
  for f in "$h"/home/state/.wake-spool/* "$h"/home/state/.wake-tmp.*; do [ ! -f "$f" ] || cat "$f"; done | LC_ALL=C sort
  for f in "$h"/home/records/* "$h"/home/crewdomains/*/records/* "$h"/home/crewdomains/*/CREWMATE.md "$h"/home/crewdomains/*/qa-repo \
    "$h"/home/state/*.status "$h"/home/data/*/timeline.log; do
    [ -f "$f" ] || continue
    printf '== %s %s\n' "$f" "$(ls -l "$f" | cut -c1-10)"; cat "$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  # A backup the port takes under the ledger lock carries the lock dir, one
  # the original took with no lock does not (named in row 5).
  for f in "$h"/home/state/backups/*; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; tar -tzf "$f" 2>&1 | grep -v '^records/\.backlog\.md\.lock' | LC_ALL=C sort
  done
  printf '== tmp\n'; ls -A "$h/tmp" | sed -E 's/ac-domain-line\.[A-Za-z0-9]{6}/ac-domain-line.XXXXXX/'
}
xsame_world() {
  xworld "$XOH" >"$TMP/xo.world"; xworld "$XNH" >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "domain differential world differs after '$*' at line $(xrow): $(diff "$TMP/xo.world2" "$TMP/xn.world2" | head -n 10)"
}
xsame() { xpair "$@"; xsame_io "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoerr() { cat "$TMP/xo.err2"; }
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "domain refusal for '$*' at line $(xrow)"
}
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XUSAGE='ERROR: usage: ac-domain.sh <new|assign|unassign|queue|qa-repo|retire|list|validate>'
XTS='2026-01-01T00:00:00Z'
XABSENT='ABSENT: records/crewdomains.md - no crewdomains registered'
xboth xseed

# 1. usage: none, -h, LIST and an unknown verb; extra arguments to list and
#    validate are never read; no backend is resolved (config and env tmux).
for xv in "" -h LIST bogus; do
  # shellcheck disable=SC2086
  xsame $xv
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$XUSAGE" "1: '$xv' is the usage line, exit 1"
done
xsame list extra args; assert_eq "$XN_RC:$(xout)" "0:$XABSENT" "1: extra arguments to list are never read"
xsame validate extra; assert_eq "$XN_RC:$(xout)" "0:" "1: nor to validate"
xboth xput home/config/backend $'tmux\n'
XENV=(AC_BACKEND=tmux); xsame list; XENV=()
assert_eq "$XN_RC:$(xout)" "0:$XABSENT" "1: no backend is resolved - tmux in config and env changes nothing"
xboth rm -rf @H/home/config

# 2. homeless (W1, reproduced): the refusal once per swallowed $(ac_home),
#    each verb's own answer after it. An AC_HOME that cannot be entered: the
#    same lines with cd's own named by the port (HOME RESOLUTION).
XHOMELESS=1
xsame list; assert_eq "$XN_RC:$(xerr)|$(xout)" "0:$XNOHOME|$XABSENT" "2 (W1): homeless list"
xsame validate; assert_eq "$XN_RC:$(xerr)|$(xout)" "0:$XNOHOME|" "2 (W1): homeless validate"
for xv in "new x --scope s --charter c --no-projects" "unassign x y" "queue x"; do
  # shellcheck disable=SC2086
  xsame $xv; assert_eq "$XN_RC:$(xerr)" "1:$XNOHOME" "2 (W1): homeless '$xv' - one refusal, exit 1"
done
xsame assign x y; assert_eq "$XN_RC:$(xerr)" "1:$XNOHOME
ERROR: no VALID crewdomain 'x' in records/crewdomains.md" "2 (W1): homeless assign"
xsame retire x; assert_eq "$XN_RC:$(xerr)" "1:$XNOHOME
ERROR: no VALID crewdomain 'x' in records/crewdomains.md - nothing to retire" "2 (W1): homeless retire"
xsame qa-repo x; assert_eq "$XN_RC:$(xerr)" "1:$XNOHOME
ERROR: no such crewdomain: x (package /crewdomains/x does not exist)" "2 (W1): homeless qa-repo"
XHOMELESS=0
XHOME=missing
for xv in list validate "new x --scope s --charter c --no-projects" "assign x y" "unassign x y" "queue x" "retire x" "qa-repo x"; do
  # shellcheck disable=SC2086
  xpair $xv; xsame_rc_out $xv; xsame_world $xv
  assert_contains "$(xoerr)" "No such file or directory" "2: the original's line for an unenterable AC_HOME is cd's own ('$xv')"
  assert_eq "$(xerr | sed 's/^ERROR: AC_HOME is not a readable directory: @H\/missing$/CD/')" "$(xoerr | sed 's/^.*: cd: @H\/missing: No such file or directory$/CD/')" \
    "2: the port names the variable where cd spoke, once per line ('$xv', named)"
done
XHOME=home

# 3. new: the parser, every refusal in code order, the eight namespaces, the
#    routing line's checks, the projects list, the whole-or-nothing write.
XNEWU="ERROR: usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>' (--projects <p1,p2,...> | --no-projects)"
XCHART="ERROR: --charter '<one-liner>' is required and may not be empty: it is what the chief reads in the digest"
XEXCL="ERROR: --projects and --no-projects are mutually exclusive - refusing rather than silently building the empty view you did not ask for"
xrefuse "$XNEWU" new
xrefuse "ERROR: unknown argument: s" new --scope s --charter c --no-projects
for xf in --scope --charter --projects; do xrefuse "ERROR: $xf needs a value" new x --scope s "$xf"; done
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: unknown argument: --bogus" new x --bogus
xrefuse "ERROR: new is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it" \
  new x --scope s --charter c --no-projects
XENV=(AC_SCOPE=)
xsame new scopeless --scope s --charter c --no-projects
assert_eq "$XN_RC:$(xout)" "0:created crewdomain scopeless at crewdomains/scopeless (0 project link(s))" "3: an empty AC_SCOPE is unscoped"
XENV=()
xrefuse "$XCHART" new x --scope s --no-projects
xrefuse "$XCHART" new x --scope s --charter '' --no-projects
xrefuse "ERROR: --scope '<text>' is required: it is the routing key, and an entry without one is registered but never routable. Pass --scope '' deliberately if that is what you mean." \
  new x --charter c --no-projects
xrefuse "$XEXCL" new x --scope s --charter c --projects alpha --no-projects
xrefuse "$XEXCL" new x --scope s --charter c --projects '' --no-projects
xrefuse "ERROR: pass --projects <p1,p2,...> or --no-projects explicitly - a silent empty project view is the wrong default" new x --scope s --charter c
for xn in X . a_b 'caf'$'\303\251' 'a b'; do xrefuse "ERROR: name must be [a-z0-9-]: $xn" new "$xn" --scope s --charter c --no-projects; done
xrefuse "$XCHART" new X --scope s --no-projects
xsame new pay --scope 'money movement' --charter 'the payments domain' --projects alpha,beta
assert_eq "$XN_RC:$(xout)" "0:created crewdomain pay at crewdomains/pay (2 project link(s))" "3: a domain over two clones"
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md")" "- pay - the payments domain - scope: money movement (added $XTS)" "3: the routing line"
assert_eq "$(readlink "$XNH/home/crewdomains/pay/projects/beta.yaml")" "../../../projects/beta.yaml" "3: relative links"
xsame new infra --scope infra --charter 'infra domain' --projects e2e
assert_eq "$(xout)" "created crewdomain infra at crewdomains/infra (1 project link(s))
no pipeline config in the fleet for: e2e.yaml - linked the clone alone (a project with no <name>.yaml is a supported direct-pr case)" "3: a .yaml-less project is named"
xsame new rep --scope a --scope b --charter c --charter d --projects alpha --projects beta
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md")" "- rep - d - scope: b (added $XTS)" "3: repeated flags, the last wins"
xsame new lonely --scope '' --charter c --no-projects
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md")" "- lonely - c - scope:  (added $XTS)" "3: --scope '' mints an unroutable entry"
xsame new --no-projects --scope s --charter c --no-projects
assert_eq "$XN_RC" 0 "3 (W11): an option-like name passes the charset"
xsame new pct --scope 's %s \n' --charter '100% \t' --no-projects
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md")" "- pct - 100% \\t - scope: s %s \\n (added $XTS)" "3: % and backslashes stay literal"
xsame new tabbed --scope s --charter $'a\tb' --no-projects
xsame new crd --scope s --charter $'c\r' --no-projects
assert_eq "$XN_RC" 0 "3 (W5): TAB and CR pass"
xsame new x-r100 --scope s --charter c --no-projects
assert_eq "$XN_RC" 0 "3: x-r100 is no reserved suffix"
for xs in spec arch plan review ship design chief r1 r10; do
  xrefuse "ERROR: name 'x-$xs' collides with a reserved stage suffix - a family id derives stage dirs from it" new "x-$xs" --scope s --charter c --no-projects
done
x3ns() {
  xadd home/records/crewdomains.md $'- taken - charter - home: /x - scope: s (added x)\n'
  xput home/records/crewdeputies.md $'# Crewdeputies\n\n- billing - home: /h/billing - no projects (added x)\n- Odd - home: /h/Odd - no projects (added x)\n'
  mkdir -p "$H/home/crewdeputies/legacy" "$H/home/crewdomains/orphanpkg" "$H/home/data/taskname"
  xput home/state/famname-chief.meta $'kind=roomchief\n'
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] rowname - a row\n- [x] rowdone - done\n- [ ] rowtail\n'
}
xboth x3ns
xrefuse "ERROR: name 'pay' is already registered in records/crewdomains.md" new pay --scope s --charter c --no-projects
xrefuse "ERROR: name 'taken' is already registered in records/crewdomains.md" new taken --scope s --charter c --no-projects
xrefuse "ERROR: name 'billing' is already a crewdeputy in records/crewdeputies.md - the two features share no file, but they share the operator's vocabulary and the chief's routing judgment; pick a different name" \
  new billing --scope s --charter c --no-projects
xrefuse "ERROR: name 'legacy' collides with an existing crewdeputy home at crewdeputies/legacy" new legacy --scope s --charter c --no-projects
xrefuse "ERROR: name 'orphanpkg' collides with an existing directory at crewdomains/orphanpkg" new orphanpkg --scope s --charter c --no-projects
xrefuse "ERROR: name 'taskname' collides with a task data dir at data/taskname" new taskname --scope s --charter c --no-projects
xrefuse "ERROR: name 'famname' collides with a live chief session at state/famname-chief.meta" new famname --scope s --charter c --no-projects
xrefuse "ERROR: name 'rowname' is already a row id in records/backlog.md" new rowname --scope s --charter c --no-projects
xrefuse "ERROR: name 'rowdone' is already a row id in records/backlog.md" new rowdone --scope s --charter c --no-projects
xsame new rowtail --scope s --charter c --no-projects
assert_eq "$XN_RC" 0 "3: a row id the line ends on is no collision (the grep wants a blank after it)"
xboth mkdir -p @H/home/data/pay-plan @H/home/data/billing
xrefuse "ERROR: name 'pay-plan' collides with a reserved stage suffix - a family id derives stage dirs from it" new pay-plan --scope s --charter c --no-projects
xrefuse "ERROR: name 'billing' is already a crewdeputy in records/crewdeputies.md - the two features share no file, but they share the operator's vocabulary and the chief's routing judgment; pick a different name" \
  new billing --scope s --charter c --no-projects
xrefuse "ERROR: --charter/--scope must be single-line: a newline would split the routing line in two" new nl --scope s --charter $'a\nb' --no-projects
xrefuse "ERROR: --charter/--scope must be single-line: a newline would split the routing line in two" new nl --scope $'s\n' --charter c --no-projects
xrefuse "ERROR: the routing line these arguments would write does not parse VALID (unknown field \"home:\") - refusing before any write. Check --charter and --scope for a ' - <word>:' token, which this grammar reads as an unknown field." \
  new badline --scope s --charter 'has a - home: token' --no-projects
xrefuse "ERROR: the routing line these arguments would write does not parse VALID (unknown field \"x:\") - refusing before any write. Check --charter and --scope for a ' - <word>:' token, which this grammar reads as an unknown field." \
  new badline --scope 'a - x: b' --charter c --no-projects
XMAL='leading, trailing or repeated commas - refusing before any write rather than silently building a shorter view'
for xp in , ,alpha alpha, alpha,,beta; do xrefuse "ERROR: malformed --projects list \"$xp\": $XMAL" new csv --scope s --charter c --projects "$xp"; done
xrefuse 'ERROR: --projects takes project NAMES, not paths: "a/b"' new csv --scope s --charter c --projects a/b
xrefuse 'ERROR: duplicate project "alpha" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' new csv --scope s --charter c --projects alpha,beta,alpha
for xp in '' ' ' $'\t'; do
  xrefuse "ERROR: --projects named no project - pass --no-projects if the empty view is what you meant" new csv --scope s --charter c --projects "$xp"
done
xrefuse "ERROR: the fleet has no clone at projects/nosuch - a domain view links the fleet's own clones, it never makes one" new csv --scope s --charter c --projects alpha,nosuch
xrefuse "ERROR: the fleet has no clone at projects/al*pha - a domain view links the fleet's own clones, it never makes one" new csv --scope s --charter c --projects 'al*pha'
xsame new spaced --scope s --charter c --projects 'alpha beta'
assert_eq "$(xout)" "created crewdomain spaced at crewdomains/spaced (2 project link(s))" "3 (W12): blanks split the list too"
xsame new tabsplit --scope s --charter c --projects $'alpha\tbeta'
xsame new lead --scope s --charter c --projects ' alpha'
xsame new comma --scope s --charter c --projects 'alpha, beta'
assert_eq "$(xout)" "created crewdomain comma at crewdomains/comma (2 project link(s))" "3 (W12): a comma and a blank"
x3wt() {
  mkdir -p "$H/home/projects/wt"; xput home/projects/wt/.git $'gitdir: /nowhere\n'
  git init -q -b main "$H/real"; ln -s "$H/real" "$H/home/projects/sym"
}
xboth x3wt
xrefuse "ERROR: the fleet has no clone at projects/wt - a domain view links the fleet's own clones, it never makes one" new wtd --scope s --charter c --projects wt
xsame new symd --scope s --charter c --projects sym
assert_eq "$(xout)" "created crewdomain symd at crewdomains/symd (1 project link(s))
no pipeline config in the fleet for: sym.yaml - linked the clone alone (a project with no <name>.yaml is a supported direct-pr case)" "3: a symlinked clone is a clone"
xboth touch @H/date.fail
xsame new nodate --scope s --charter c --no-projects
xboth rm -f @H/date.fail
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md"):$(xerr)" "- nodate - c - scope: s (added ):date: the stub refuses" "3 (W21): a failing date writes (added ) and goes on"
XENV=(TMPDIR=@H/notmp)
xsame new notmp --scope s --charter c --no-projects
XENV=()
assert_eq "$XN_RC" 1 "3: an unwritable TMPDIR ends new with mktemp's status"
assert_contains "$(xerr)" "mktemp" "3: ... and mktemp's own line"
xboth sh -c 'printf %s "- glued - c - scope: s (added x)" >>"$0/home/records/crewdomains.md"' @H
xsame new afterglue --scope s --charter c --no-projects
assert_contains "$(cat "$XNH/home/records/crewdomains.md")" "(added x)- afterglue - c" "3 (W14): a registry without a final LF gets the line glued on"
xboth sh -c 'printf "\n" >>"$0/home/records/crewdomains.md"' @H
xboth sh -c 'echo 2 >"$0/ln.fail-at"; rm -f "$0/ln.count"' @H
xsame new lnfail --scope s --charter c --projects alpha,beta
xboth rm -f @H/ln.fail-at @H/ln.count
assert_eq "$XN_RC:$(xerr)" "1:ln: the stub refuses
rolled back the partial package at @H/home/crewdomains/lnfail - nothing was created" "3: an ln failing mid-write rolls the package back, exit ln's"
xboth mkdir -p @H/home/crewdomains/mkfail
xboth chmod 555 @H/home/crewdomains
if [ "$(id -u)" != 0 ]; then
  xsame new mkfail2 --scope s --charter c --no-projects
  assert_eq "$XN_RC" 1 "3: a package dir mkdir cannot make ends new with mkdir's status"
  assert_contains "$(xerr)" "rolled back the partial package at @H/home/crewdomains/mkfail2" "3: ... rolled back"
fi
xboth chmod 755 @H/home/crewdomains
xboth rmdir @H/home/crewdomains/mkfail
if [ "$(id -u)" != 0 ]; then
  xboth chmod 444 @H/home/records/crewdomains.md
  xpair new ro --scope s --charter c --projects alpha; xsame_rc_out new ro; xsame_world new ro
  xboth chmod 644 @H/home/records/crewdomains.md
  assert_eq "$XN_RC:$(xerr)" "1:rolled back the partial package at @H/home/crewdomains/ro - nothing was created" "3: an unwritable registry rolls back - the port without the shell's line (named)"
  assert_contains "$(xoerr)" "Permission denied" "3: ... the original's own line is the shell's"
  assert_contains "$(xoerr)" "rolled back the partial package at @H/home/crewdomains/ro - nothing was created" "3: ... and its rollback line"
fi
if [ -d "$XOH/home/projects/ALPHA" ]; then
  xsame new casefold --scope s --charter c --projects alpha,ALPHA
  assert_eq "$XN_RC" 1 "3 (W13): alpha,ALPHA on a case-insensitive filesystem fails on the second .yaml link"
  assert_eq "$(git -C "$XNH/home/projects/alpha" status --porcelain)" "?? ALPHA" "3 (W13): ... after linking INTO the fleet clone, which the rollback leaves"
  xboth rm -f @H/home/projects/alpha/ALPHA
else
  printf 'SKIP: row 3 W13 - the filesystem is case-sensitive\n'
fi
# W4: one byte that is not UTF-8 in the registry, under UTF-8 - the
# collision awk aborts, reads "no collision", and new appends a duplicate.
xboth xadd home/records/crewdomains.md $'- dup - c - scope: s (added x)\n- b\351d - c - scope: s (added x)\n'
XLC=en_US.UTF-8; xsame new dup --scope s --charter c --no-projects; XLC=C
assert_eq "$XN_RC:$(grep -c '^- dup ' "$XNH/home/records/crewdomains.md")" "0:2" "3 (W4): under UTF-8 the collision read fails open and the id lands twice"
assert_contains "$(xerr)" "towc" "3 (W4): awk's own line"
# Named: pathname expansion. From a cwd holding alpha the original's unquoted
# loop made 'alph?' alpha; the port keeps the word.
xboth mkdir -p @H/globcwd/alpha
XCWD=globcwd; xpair new globby --scope s --charter c --projects 'alph?'; XCWD=cwd
assert_eq "$XO_RC:$XN_RC" "0:1" "3 (named): the original globbed the project list against its cwd, the port does not"
assert_contains "$(xerr)" "no clone at projects/alph?" "3 (named): ... the port refuses the word"
# Named: argv arrives decoded - a charter byte that is not UTF-8.
xpair new latin --scope s --charter $'caf\351' --no-projects
xsame_rc_out new latin
assert_eq "$(tail -n1 "$XOH/home/records/crewdomains.md" | od -An -tx1 | tr -d ' \n' | cut -c1-24)" "2d206c6174696e202d206361" "3: the registry line"
assert_contains "$(tail -n1 "$XOH/home/records/crewdomains.md" | od -An -tx1 | tr -d ' \n')" "636166e9" "3 (named): the original wrote the byte"
assert_contains "$(tail -n1 "$XNH/home/records/crewdomains.md" | od -An -tx1 | tr -d ' \n')" "636166efbfbd" "3 (named): the port's argv was decoded"

# 4. assign: stamps in place, both arms, idempotent, the status line, the
#    spool record, the timeline mirror, the captain's words (raw, W25), a
#    wake that cannot publish (WARN), a backup that cannot be claimed.
x4() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/data" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state"
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- noscope - c - scope:  (added x)\n'
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - before any heading (repo: alpha)\n\n## In flight\n\n- [ ] fly - in flight (repo: alpha)\n- [ ] fly2 - in flight too\n\n## Queued\n\n- [ ] qa - row a (repo: alpha)\n- [ ] qb - row b\n- [ ] qc - mid (repo: x) prose (repo: alpha)\n- [ ] pin [src:cap mode:direct-pr rev:no] - pinned (repo: alpha)\n- [ ] big [EPIC] - the epic (repo: alpha)\n- [ ] story - a story; epic:big (repo: alpha)\n- [ ] dep - waits (repo: alpha) blocked-by: qa - needs it\n- [ ] other - other; domain:inv (repo: alpha)\n- [ ] mal - a domain:pay mention (repo: alpha)\n- [ ] dup - one\n- [ ] dup - two\n- [ ] nodash\n- [ ] qd - d\n- [ ] qe - e\n- [ ] wa - w a\n- [ ] wb - w b\n- [ ] wc - w c\n- [ ] wd - w d\n- [ ] wf - w f\n- [ ] wg - w g\n- [ ] wh - w h\n- [ ] wi - w i\n- [ ] latu - caf\351 u\n- [ ] bs - C:\\new path (repo: alpha)\n- [ ] bs2 - a \\d+ regex\n- [ ] tail - ends in a backslash \\\n- [ ] lat - caf\351 (repo: alpha)\n- [ ] crlf - windows (repo: alpha)\r\n\n## Queued (3)\n\n- [ ] q3 - counted\n\n## Parked\n\n- [ ] park - parked\n\n## Done\n\n- [x] fin - done (merged 2026-08-01)\n'
}
xboth x4
xsame assign pay qa
assert_eq "$(xout)" "backup: @H/home/state/backups/domain-assign-1767225600.tar.gz
- [ ] qa - row a; domain:pay (repo: alpha)
assigned qa to crewdomain pay" "4: one row stamped before its trailing repo group"
assert_eq "$(cat "$XNH/home/state/pay.status")" "$XTS assign: qa" "4: the status line"
assert_eq "$(cat "$XNH"/home/state/.wake-spool/*)" "1767225600	domain	pay	assign: qa" "4: one spool record"
xsame assign pay qb qc big story dep pin crlf
assert_contains "$(xout)" "- [ ] qb - row b; domain:pay" "4: the end-of-line arm"
assert_contains "$(xout)" "- [ ] qc - mid (repo: x) prose; domain:pay (repo: alpha)" "4: before the TRAILING group"
assert_contains "$(xout)" $'- [ ] crlf - windows (repo: alpha)\r; domain:pay' "4: a CR ends the line, so the EOL arm"
xsame assign pay qa qb mal
assert_contains "$(xout)" "already assigned to pay: qa,qb" "4: the no-ops named"
assert_contains "$(xout)" "- [ ] mal - a domain:pay mention; domain:pay (repo: alpha)" "4: an off-position token reads as none and is stamped over"
xsame assign pay qa qb
assert_eq "$XN_RC:$(xout)" "0:already assigned to pay: qa,qb
nothing to do" "4: all already - nothing to do, no backup"
xsame assign pay ' '
assert_eq "$XN_RC:$(xout)" "0:nothing to do" "4: a blank-only id leaves no id"
xsame assign pay fly --captain-requested $'cap\tsaid\nyes'
assert_eq "$(tail -n2 "$XNH/home/state/pay.status")" "$XTS assign: fly [captain-requested: cap	said
yes]" "4 (W25): the captain's words raw in the status line"
xsame assign inv qd --captain-requested first --captain-requested second
assert_eq "$(tail -n1 "$XNH/home/state/inv.status")" "$XTS assign: qd [captain-requested: second]" "4: the last --captain-requested wins, and its words ride any assign"
xboth xput home/state/pay.meta $'kind=roomchief\n'
xsame assign pay lat
assert_eq "$(cat "$XNH/home/data/pay/timeline.log")" "$XTS assign: lat" "4: a task with a meta gets the line in its timeline too"
xboth rm -f @H/home/state/pay.meta
xboth rm -rf @H/home/state/.wake-spool
xboth xput home/state/.wake-spool 'not a dir'
xsame assign pay qe
assert_eq "$XN_RC:$(xerr)" "0:mkdir: @H/home/state/.wake-spool: File exists
WARN: assign: the durable wake could not be published - the rows are STAMPED, but your drain will not announce it; check @H/home/state/.wake-spool" "4: a wake that cannot publish is a WARN, exit 0"
[ -n "$(ls -A "$XNH/home/state" | grep '^\.wake-tmp\.' || true)" ] || fail "4: ... the temp is left as litter"
xboth rm -f @H/home/state/.wake-spool @H/home/state/.wake-tmp.*
if [ "$(id -u)" != 0 ]; then
  xboth chmod 555 @H/home/state/backups
  xsame assign pay wi
  xboth chmod 755 @H/home/state/backups
  assert_eq "$XN_RC:$(xerr)" "1:WARN: records backup: could not create @H/home/state/backups/domain-assign-1767225600-7.tar.gz (is @H/home/state/backups writable?) - no backup archive was taken" \
    "4: a backup that cannot be claimed ends assign 1 before any write"
fi

# 5. assign refusals, the ledger byte-unchanged (the world), and the warts.
XAU="ERROR: usage: ac-domain.sh assign <name> <backlog-id>... [--captain-requested '<words>']"
XNAME="(charset [a-z0-9-], no path separators) - refusing to derive a package path from it"
xrefuse "$XAU" assign
xrefuse "$XAU" assign pay
xrefuse "$XAU" assign '' wi
xrefuse "$XAU" assign pay --captain-requested words
xrefuse "ERROR: --captain-requested needs the captain's words (the authority is the record)" assign pay wi --captain-requested
xrefuse "ERROR: --captain-requested needs the captain's words (the authority is the record)" assign pay wi --captain-requested ''
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: assign is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it" assign pay wi
XENV=()
xrefuse "ERROR: not a legal crewdomain name: '../x' $XNAME" assign ../x wi
xrefuse "ERROR: not a legal crewdomain name: 'UPPER' $XNAME" assign UPPER wi
for xb in pay.fix 'pay*' ../x; do
  xrefuse "ERROR: not a legal backlog id: '$xb' (charset [a-z0-9-]) - refusing rather than matching it as a regular expression against the ledger" assign pay wi "$xb"
done
xrefuse 'ERROR: duplicate backlog id "wi" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' assign pay wi wi
xrefuse 'ERROR: duplicate backlog id "wi wb" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' assign pay 'wi wb' 'wi wb'
xrefuse "ERROR: empty backlog id in the argument list - refusing before any write" assign pay wi ''
xrefuse "ERROR: no VALID crewdomain 'ghost' in records/crewdomains.md" assign ghost wi
xrefuse "ERROR: crewdomain 'noscope' has an empty scope: - it is not routable, and the chief may not invent scope text for it" assign noscope wi
for xi in nosuch dup nodash; do xrefuse "ERROR: no single row for '$xi' in @H/home/records/backlog.md" assign pay wi "$xi"; done
xrefuse "ERROR: 'other' is already assigned to crewdomain 'inv' - unassign it there first; a silent steal is how one row ends up claimed twice" assign pay wi other
xrefuse "ERROR: 'fly2' sits under '## In flight' - adopting live work into a domain is the captain's call: re-run with --captain-requested '<the captain's words>' (a stamp changes nothing in the flying crewmate's env, but the authority must be on record)" assign pay fly2
xrefuse "ERROR: 'fin' sits under '## Done' - Done history keeps the provenance it was made with" assign pay fin --captain-requested 'even so'
xrefuse "ERROR: 'q3' sits under '## Queued (3)' - Done history keeps the provenance it was made with" assign pay q3
xrefuse "ERROR: 'park' sits under '## Parked' - Done history keeps the provenance it was made with" assign pay park
xrefuse "ERROR: 'pre' sits under '## ' - Done history keeps the provenance it was made with" assign pay pre
xboth mv @H/home/records/backlog.md @H/home/records/backlog.keep
xrefuse "ERROR: no fleet backlog at @H/home/records/backlog.md" assign pay wi
xboth mv @H/home/records/backlog.keep @H/home/records/backlog.md
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xsame assign pay wi
  xboth chmod 644 @H/home/records/backlog.md
  assert_eq "$XN_RC" 2 "5: an unreadable ledger ends assign with the row finder's status"
  assert_contains "$(xerr)" "can't open file" "5: ... and awk's own line"
fi
xsame assign pay wa 'wb wa'
assert_eq "$(tail -n1 "$XNH/home/state/pay.status")" "$XTS assign: wa,wb,wa" "5 (W10): an id with a blank splits after the duplicate check"
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] wa - w a; domain:pay; domain:pay" "5 (W10): ... and double-stamps"
xsame assign pay wc bs
assert_eq "$XN_RC:$(xerr)" "1:ERROR: could not rewrite the row for 'bs' - the ledger changed under this command; re-run" "5 (W6): a row holding a backslash cannot be rewritten"
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] wc - w c; domain:pay" "5 (W7): the id before it stays stamped"
assert_eq "$(tail -n1 "$XNH/home/state/pay.status")" "$XTS assign: wa,wb,wa" "5 (W7): ... with no status line"
xsame assign pay bs2
assert_eq "$XN_RC" 1 "5 (W6): \\d too"
xsame assign pay tail
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] tail - ends in a backslash ; domain:pay" "5 (W6): a lone final backslash matches, and the stamped line loses it as -v reads it"
assert_contains "$(xout)" "- [ ] tail - ends in a backslash \; domain:pay" "5 (W6): ... while stdout shows the line computed"
XLC=en_US.UTF-8; xsame assign pay wf latu; XLC=C
assert_eq "$XN_RC" 2 "5 (W7): under UTF-8 the stamp awk aborts on a byte that is not UTF-8"
assert_contains "$(xerr)" "towc" "5 (W7): awk's own line"
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] wf - w f; domain:pay" "5 (W7): the id before it stays stamped"
if [ "$(id -u)" != 0 ]; then
  xboth rm -f @H/home/state/pay.status
  xboth mkdir @H/home/state/pay.status
  xpair assign pay wd; xsame_rc_out assign pay wd; xsame_world assign pay wd
  assert_eq "$XN_RC:$(xerr)" "1:" "5 (W7): a status append that fails ends assign 1 after the stamp - the port without the shell's line (named)"
  assert_contains "$(xoerr)" "Is a directory" "5: ... the original's own line is the shell's"
  assert_eq "$(ls -A "$XNH/home/state/.wake-spool" | wc -l | tr -d ' ')" "2" "5 (W7): ... and no wake"
  xboth rmdir @H/home/state/pay.status
fi
# Named (W8, fixed): a LIVE writer holds the ledger lock.
# The original wrote past it; the port waits AC_TASK_LOCK_TIMEOUT out and
# refuses with nothing written, as ac-task.sh does. Then the port runs the
# same assign unlocked, so the two sides are level again.
xboth mkdir @H/home/records/.backlog.md.lock
xboth sh -c 'printf "%s\n" "$1" >"$0"' @H/home/records/.backlog.md.lock/pid "$$"
XENV=(AC_TASK_LOCK_TIMEOUT=1); xpair assign pay wg; XENV=()
assert_eq "$XO_RC" 0 "5 (W8, named): the original stamped past a live holder"
assert_contains "$(cat "$XOH/home/records/backlog.md")" "- [ ] wg - w g; domain:pay" "5 (W8, named): ... the row it wrote"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: records/backlog.md is locked by another writer - nothing written" "5 (W8): the port refuses a live holder's lock"
case "$(cat "$XNH/home/records/backlog.md")" in *"wg - w g; domain"*) fail "5 (W8): ... with nothing written" ;; esac
assert_eq "$(cat "$XNH/home/records/.backlog.md.lock/pid")" "$$" "5 (W8): ... and the holder's lock left as it was"
xboth rm -rf @H/home/records/.backlog.md.lock
xrun_side "$BIN" "$XNH" xn assign pay wg || fail "5: the unlocked assign: $(cat "$TMP/xn.err")"
xsame_world assign pay wg
assert_contains "$(for xf in "$XNH"/home/state/backups/*; do tar -tzf "$xf"; done)" "records/.backlog.md.lock/pid" "5 (W8, named): the port's backup, taken under its lock, carries the lock dir"
xboth chmod 600 @H/home/records/backlog.md
xpair assign pay wh; xsame_io assign pay wh
assert_eq "$(ls -l "$XOH/home/records/backlog.md" | cut -c1-10)" "-rw-r--r--" "5 (W9): the original's ledger took its temp's mode"
assert_eq "$(ls -l "$XNH/home/records/backlog.md" | cut -c1-10)" "-rw-------" "5 (W9): the port keeps the ledger's mode (named)"
xboth chmod 644 @H/home/records/backlog.md
xsame_world assign pay wh
# Named (W23): a registry past the pipe's capacity with the domain first -
# the original's lookup exited early and the parse died of SIGPIPE.
x5big() { awk 'BEGIN { print "- pay - payments - scope: money (added x)"; for (i = 0; i < 20000; i++) printf "- d%d - charter text - scope: some scope (added x)\n", i }' >"$H/home/records/crewdomains.md"; }
xboth x5big
xpair assign pay wi
assert_eq "$XO_RC:$(xoerr)" "1:ERROR: no VALID crewdomain 'pay' in records/crewdomains.md" "5 (W23): the original refuses a domain its SIGPIPEd parse held"
assert_eq "$XN_RC" 0 "5 (W23): the port reads the whole parse (named): $(xerr)"
# The point of the lock (W8): the port reads and rewrites the ledger inside it,
# so a commit its holder makes before releasing survives the stamp - the
# original read early and renamed late, and erased such a commit. The holder
# acts on a checkpoint, never a timer: an awk stub marks the END of the
# registry parse, after which assign runs only in-process checks before it
# takes the lock, so a slow start cannot let the release come first and the
# row pass without a waiting writer.
xboth x4
xrealawk="$(command -v awk)"; mkdir -p "$TMP/xawkstub"
printf '#!/bin/sh\n%s "$@"; rc=$?\n: >"$STUB_DIR/awk.seen"\nexit $rc\n' "$xrealawk" >"$TMP/xawkstub/awk"; chmod +x "$TMP/xawkstub/awk"
xatlock() {  # the waiting assign has parsed the registry - it is at the lock
  local i; for i in $(seq 1 150); do [ ! -e "$XNH/awk.seen" ] || { /bin/sleep 0.5; return 0; }; /bin/sleep 0.2; done
  fail "5 (W8): the waiting assign never reached the lock"
}
mkdir "$XNH/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$XNH/home/records/.backlog.md.lock/pid"
rm -f "$XNH/awk.seen"
XPATH="$TMP/xawkstub:$XSTUBS:$PATH"; XENV=(AC_TASK_LOCK_TIMEOUT=30); xrun_side "$BIN" "$XNH" xl assign pay qb & xlpid=$!; XENV=(); XPATH=""
xatlock
case "$(cat "$XNH/home/records/backlog.md")" in *"qb - row b; domain"*) fail "5 (W8): the port wrote while another writer held the ledger lock" ;; esac
printf -- '- [ ] heldrow - committed by the lock holder\n' >>"$XNH/home/records/backlog.md"
rm -rf "$XNH/home/records/.backlog.md.lock"
wait "$xlpid" || fail "5 (W8): the waiting assign failed: $(cat "$TMP/xl.err")"
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] heldrow - committed by the lock holder" "5 (W8): the holder's commit survives"
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [ ] qb - row b; domain:pay" "5 (W8): ... and the stamp lands after the release"
[ ! -e "$XNH/home/records/.backlog.md.lock" ] || fail "5 (W8): the port releases the lock it took"
# ... and its CHECKS run inside the lock too: a row the holder moves to In
# flight before releasing is refused, never stamped on a reading taken before.
mkdir "$XNH/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$XNH/home/records/.backlog.md.lock/pid"
rm -f "$XNH/awk.seen"
XPATH="$TMP/xawkstub:$XSTUBS:$PATH"; XENV=(AC_TASK_LOCK_TIMEOUT=30); xrun_side "$BIN" "$XNH" xl assign pay qd & xlpid=$!; XENV=(); XPATH=""
xatlock
awk '$0 == "- [ ] qd - d" { next } { print } $0 == "## In flight" { print "- [ ] qd - d" }' "$XNH/home/records/backlog.md" >"$TMP/xmoved"
cat "$TMP/xmoved" >"$XNH/home/records/backlog.md"
rm -rf "$XNH/home/records/.backlog.md.lock"
xlrc=0; wait "$xlpid" || xlrc=$?
assert_eq "$xlrc:$(cat "$TMP/xl.err")" "1:ERROR: 'qd' sits under '## In flight' - adopting live work into a domain is the captain's call: re-run with --captain-requested '<the captain's words>' (a stamp changes nothing in the flying crewmate's env, but the authority must be on record)" \
  "5 (W8): the row the holder moved is judged as it now stands"
case "$(cat "$XNH/home/records/backlog.md")" in *"qd - d; domain"*) fail "5 (W8): ... and never stamped" ;; esac
# EXCLUSIVE TEMP (named, W9): a symlink planted at `<ledger>.tmp.<pid>` - the
# original wrote the ledger THROUGH it and renamed the link over the ledger;
# the port claims the next name. Each side starts behind a fifo gate and
# execs into its entry as the pid the name is planted for. The watchdog is
# started from a substitution, so it is no job of the gate's: killing a job
# made bash print its `Terminated` notice into the row's output, or not, by
# timing.
xboth x4
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
xplant() {  # xplant <bin> <side root> <out> <temp under the home> <args...> - the row on one side
  local b="$1" h="$2" o="$3" t="$4" gate pid; shift 4
  gate="$h/gate.fifo"; mkfifo "$gate"
  printf 'victim bytes\n' >"$h/victim"
  env -u AC_SCOPE LC_ALL=C AC_HOME="$h/home" TMPDIR="$h/tmp" PATH="$XSTUBS:$PATH" STUB_DIR="$h" \
    "$TMP/xgate.sh" "$gate" "$h/cwd" "$b" "$@" </dev/null >"$o" 2>&1 &
  pid=$!
  ln -s "$h/victim" "$h/home/$t.tmp.$pid"
  printf x >"$gate"
  wait "$pid" || fail "5: the planted row under $b failed: $(cat "$o")"
  rm -f "$gate"
}
xplant "$xobin" "$XOH" "$TMP/xpo.raw" records/backlog.md assign pay qa
xplant "$BIN" "$XNH" "$TMP/xpn.raw" records/backlog.md assign pay qa
assert_eq "$(xnorm "$TMP/xpn.raw" "$XNH")" "$(xnorm "$TMP/xpo.raw" "$XOH")" "5: the planted row's output"
[ -L "$XOH/home/records/backlog.md" ] || fail "5 (W9): the original renamed the planted link over the ledger (the divergence's bash side)"
[ ! -L "$XNH/home/records/backlog.md" ] || fail "5 (W9): the port's ledger stays a regular file"
assert_eq "$(cat "$XNH/victim")" "victim bytes" "5 (W9): the port never writes through a planted temp name"
assert_eq "$(cat "$XNH/home/records/backlog.md")" "$(cat "$XOH/victim")" "5: the same ledger bytes"
[ -L "$(ls -d "$XNH"/home/records/backlog.md.tmp.* | head -n1)" ] || fail "5 (W9): the planted link is left where it was"

# 6. unassign: the byte-identical restore, both arms; every refusal; a
#    retired domain's token (the ORPHAN remedy); not idempotent; bytes that
#    are not UTF-8 under C (stripped) and under UTF-8 (sed's 1).
x6() {
  x4
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - before; domain:pay\n\n## In flight\n\n- [ ] fly - in flight; domain:pay (repo: alpha)\n\n## Queued\n\n- [ ] ua - row a; domain:pay (repo: alpha)\n- [ ] ub - row b; domain:pay\n- [ ] uc - mid (repo: x) prose; domain:pay (repo: alpha)\n- [ ] other - other; domain:inv (repo: alpha)\n- [ ] plain - untokened\n- [ ] mid - see; domain:pay (repo: x) for context (repo: alpha)\n- [ ] gonerow - retired; domain:gone\n- [ ] lat - caf\351; domain:pay (repo: alpha)\n- [ ] latu - caf\351 u; domain:pay\n- [ ] bs - C:\\new; domain:pay\n\n## Done\n\n- [x] fintok - done; domain:pay\n'
}
xboth x6
mkdir "$XNH/home/records/.backlog.md.lock"; printf '%s\n' "$$" >"$XNH/home/records/.backlog.md.lock/pid"
XENV=(AC_TASK_LOCK_TIMEOUT=1); xrun_side "$BIN" "$XNH" xn unassign pay ua && fail "6 (W8): unassign wrote past a live holder"; XENV=()
assert_eq "$(cat "$TMP/xn.err")" "ERROR: records/backlog.md is locked by another writer - nothing written" "6 (W8): unassign refuses a live holder's lock"
rm -rf "$XNH/home/records/.backlog.md.lock"
xsame_world unassign pay ua
xsame unassign pay ua ub uc
assert_eq "$(xout)" "backup: @H/home/state/backups/domain-unassign-1767225600.tar.gz
- [ ] ua - row a (repo: alpha)
- [ ] ub - row b
- [ ] uc - mid (repo: x) prose (repo: alpha)
unassigned ua,ub,uc from crewdomain pay" "6: the strip restores each row, both arms"
assert_eq "$(tail -n1 "$XNH/home/state/pay.status")" "$XTS unassign: ua,ub,uc" "6: the status line"
[ ! -e "$XNH/home/state/.wake-spool" ] || fail "6: unassign publishes no wake"
xrefuse "ERROR: 'ua' carries no domain:pay token at its grammar position - nothing to reverse" unassign pay ua
xrefuse "ERROR: 'other' carries no domain:pay token at its grammar position (it is assigned to 'inv') - nothing to reverse" unassign pay other
xrefuse "ERROR: 'mid' carries no domain:pay token at its grammar position - nothing to reverse" unassign pay mid
xrefuse "ERROR: 'fly' sits under '## In flight', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay fly
xrefuse "ERROR: 'fintok' sits under '## Done', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay fintok
xrefuse "ERROR: 'pre' sits under '## ', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay pre
xrefuse "ERROR: usage: ac-domain.sh unassign <name> <id>..." unassign
xrefuse "ERROR: usage: ac-domain.sh unassign <name> <id>..." unassign pay
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: unassign is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it" unassign pay ua
XENV=()
xrefuse "ERROR: not a legal crewdomain name: '..' $XNAME" unassign .. ua
xrefuse "ERROR: no single row for 'nosuch' in @H/home/records/backlog.md" unassign pay nosuch
xrefuse 'ERROR: duplicate backlog id "ua" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible' unassign pay ua ua
xsame unassign pay ' '
assert_eq "$XN_RC:$(xout)" "0:nothing to do" "6: a blank-only id list is nothing to do"
xsame unassign gone gonerow
assert_eq "$XN_RC:$(grep -c "gonerow - retired$" "$XNH/home/records/backlog.md")" "0:1" "6: a domain no registry knows can still be stripped"
xsame unassign pay lat
assert_eq "$XN_RC" 0 "6: a byte that is not UTF-8 strips under C"
XLC=en_US.UTF-8; xsame unassign pay latu; XLC=C
assert_eq "$XN_RC" 1 "6 (W7): under UTF-8 the strip's sed refuses the byte"
assert_contains "$(xerr)" "sed" "6 (W7): ... sed's own line"
xsame unassign pay bs
assert_eq "$XN_RC:$(xerr)" "1:ERROR: could not rewrite the row for 'bs' - the ledger changed under this command; re-run" "6 (W6): a backslash row cannot be stripped either"
xboth mv @H/home/records/backlog.md @H/home/records/backlog.keep
xrefuse "ERROR: no fleet backlog at @H/home/records/backlog.md" unassign pay ua
xboth mv @H/home/records/backlog.keep @H/home/records/backlog.md

# 7. queue: the slice with epic inheritance, headers once per section, rows
#    before a heading headerless, indented lines never, names as strings;
#    --ids only as the exact second word (W18); no ledger (W18); unreadable.
x7() {
  xput home/records/backlog.md $'# Backlog\n- [ ] pre - pre; domain:pay\n\n## In flight\n\n- [ ] f1 - flying; domain:pay (repo: a)\n\n## Queued\n\n- [ ] big [EPIC] - epic; domain:pay (repo: a)\n- [ ] s1 - story; epic:big\n- [ ] ie [EPIC] - inv epic; domain:inv\n- [ ] s2 - own token under another epic; epic:ie; domain:pay\n- [ ] s3 - story of inv; epic:ie\n- [ ] m1 - a domain:pay mention\n- [ ] n7 - seven; domain:7\n- [ ] n07 - oh-seven; domain:07\n  - [ ] indented; domain:pay\n\n## Parked\n\n- [ ] p1 - other domain; domain:inv\n\n## Done\n\n- [x] d1 - done; domain:pay\n- [x] d2 - story of a done epic; epic:big\n'
}
xboth x7
xsame queue pay
assert_eq "$(xout)" "- [ ] pre - pre; domain:pay
## In flight
- [ ] f1 - flying; domain:pay (repo: a)
## Queued
- [ ] big [EPIC] - epic; domain:pay (repo: a)
- [ ] s1 - story; epic:big (via epic:big)
- [ ] s2 - own token under another epic; epic:ie; domain:pay
## Done
- [x] d1 - done; domain:pay
- [x] d2 - story of a done epic; epic:big (via epic:big)" "7: the slice"
xsame queue pay --ids
assert_eq "$(xout | tr '\n' ' ')" "pre f1 big s1 s2 d1 d2 " "7: --ids"
xsame queue 7 --ids; assert_eq "$(xout)" "n7" "7: 7 is not 07"
xsame queue 07; assert_eq "$(xout)" "## Queued
- [ ] n07 - oh-seven; domain:07" "7: 07 is not 7"
xsame queue inv
xsame queue ghost; assert_eq "$XN_RC:$(xout)" "0:" "7: an unregistered name is an empty slice"
xsame queue pay --id; assert_contains "$(xout)" "## Queued" "7 (W18): any other second word is the full form"
xsame queue pay extra --ids; assert_contains "$(xout)" "## Queued" "7 (W18): --ids counts only as the second word"
xsame queue pay --ids extra; assert_eq "$(xout | head -n1)" "pre" "7 (W18): later words are ignored"
XENV=(AC_SCOPE=fam); xsame queue pay --ids; XENV=()
assert_eq "$XN_RC" 0 "7: a scoped session may read its slice"
xrefuse "ERROR: usage: ac-domain.sh queue <name> [--ids]" queue
xrefuse "ERROR: not a legal crewdomain name: 'UPPER' $XNAME" queue UPPER
xboth rm -f @H/home/records/backlog.md
xsame queue pay --ids; assert_eq "$XN_RC:$(xout)" "0:no fleet backlog" "7 (W18): no ledger is a stdout line, --ids or not"
xboth x7
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xpair queue pay; xsame_rc_out queue pay
  xboth chmod 644 @H/home/records/backlog.md
  xsame_world queue pay
  assert_eq "$XN_RC:$(xout)" "2:" "7: an unreadable ledger is exit 2, nothing on stdout"
  assert_contains "$(xoerr)" "can't open file @H/home/records/backlog.md" "7: the original's line is awk's"
  assert_eq "$(xerr)" "ERROR: cannot read @H/home/records/backlog.md" "7: the port's is the parser's own (named)"
fi

# 8. qa-repo: every argument form, read/set/force/clear, REUSE, a path the
#    view admits (W17a), a package it cannot write (W17b), a scoped session
#    (W17c), the member's [:space:], a symlinked clone's physical path.
x8() {
  rm -rf "$H/home/crewdomains"
  mkdir -p "$H/home/crewdomains/proof/projects"
  local p; for p in alpha e2e sym; do ln -s "../../../projects/$p" "$H/home/crewdomains/proof/projects/$p"; done
  mkdir "$H/home/crewdomains/proof/projects/plain"
}
xboth x8
XQU="ERROR: usage: ac-domain.sh qa-repo <name> [--set <project> [--force] | --clear]"
XQNONE="ERROR: domain proof declares no e2e repository - declare it with: ac-domain.sh qa-repo proof --set <project>, or leave it undeclared and QA takes the profile-driven route (ac-verify qa)"
xrefuse "$XQU" qa-repo
xrefuse "ERROR: not a legal crewdomain name: '../escape' $XNAME" qa-repo ../escape
xrefuse "ERROR: --set needs a project name" qa-repo proof --set
xrefuse "ERROR: --set needs a project name" qa-repo proof --set ''
xrefuse "ERROR: unknown qa-repo argument: bogus" qa-repo proof bogus
xrefuse "ERROR: unknown qa-repo argument: e2e" qa-repo proof --clear e2e
xrefuse "ERROR: no such crewdomain: ghost (package @H/home/crewdomains/ghost does not exist)" qa-repo ghost --set alpha
xrefuse "$XQNONE" qa-repo proof
xrefuse "$XQNONE" qa-repo proof --force
xsame qa-repo proof --set e2e
assert_eq "$XN_RC:$(xout)" "0:qa-repo for proof: e2e (@H/home/projects/e2e)" "8: set"
assert_eq "$(cat "$XNH/home/crewdomains/proof/qa-repo")" "e2e" "8: the member holds the NAME"
xsame qa-repo proof; assert_eq "$XN_RC:$(xout)" "0:@H/home/projects/e2e" "8: read"
XREUSE="ERROR: domain proof already declares an e2e repository: @H/home/projects/e2e - reuse it. Moving the declaration is deliberate: re-run with --force."
xrefuse "$XREUSE" qa-repo proof --set alpha
xrefuse "$XREUSE" qa-repo proof --set e2e
xrefuse "ERROR: beta is not a project of domain proof - add it to the domain's projects/ view first (a repository outside that view is one the domain's own sessions cannot reach)" qa-repo proof --set beta
xrefuse "ERROR: plain resolves to no git repository through @H/home/crewdomains/proof/projects/plain" qa-repo proof --set plain
xsame qa-repo proof --set alpha --force; assert_eq "$(xout)" "qa-repo for proof: alpha (@H/home/projects/alpha)" "8: --force moves it"
xsame qa-repo proof --force --set sym; assert_eq "$(xout)" "qa-repo for proof: sym (@H/real)" "8: a symlinked clone reads physically"
xsame qa-repo proof --clear; assert_eq "$XN_RC:$(xout)" "0:qa-repo cleared for proof - QA returns to the profile-driven route" "8: clear"
xsame qa-repo proof --clear; assert_eq "$XN_RC" 0 "8: clear is idempotent"
xsame qa-repo proof --set e2e --clear; assert_contains "$(xout)" "cleared" "8: the last of --set/--clear wins"
xsame qa-repo proof --clear --set e2e; assert_contains "$(xout)" "qa-repo for proof: e2e" "8: ... either way round"
xboth xput home/crewdomains/proof/qa-repo $'nosuch\n'
xsame qa-repo proof --set alpha; assert_eq "$XN_RC" 0 "8: a stale declaration is replaced without --force"
xboth xput home/crewdomains/proof/qa-repo $' e 2e \t\nignored\n'
xsame qa-repo proof; assert_eq "$(xout)" "@H/home/projects/e2e" "8: every blank of the first line is deleted"
xboth xput home/crewdomains/proof/qa-repo $'\ne2e\n'
xrefuse "$XQNONE" qa-repo proof
xboth rm -f @H/home/crewdomains/proof/qa-repo
# Named (W17, fixed): --set takes a project NAME - a
# value holding `/` is refused - and --set and --clear are the crewchief's,
# while reading stays open to every session. The original took a path through
# the view and let a scoped session set or clear the declaration. After each
# row the original's write is undone or matched, so the sides stay level.
xpair qa-repo proof --set ../../../projects/e2e
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:qa-repo for proof: ../../../projects/e2e (@H/home/projects/e2e)" "8 (W17a, named): the original took a path through the view"
assert_eq "$XN_RC:$(xout):$(xerr)" '1::ERROR: --set takes a project NAME, not a path: "../../../projects/e2e"' "8 (W17a): the port refuses it"
xpair qa-repo proof --set alpha/.git --force
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:qa-repo for proof: alpha/.git (@H/home/projects/alpha)" "8 (W17a, named): ... alpha/.git too"
assert_eq "$XN_RC:$(xout):$(xerr)" '1::ERROR: --set takes a project NAME, not a path: "alpha/.git"' "8 (W17a): ... and the port refuses that too"
xboth rm -f @H/home/crewdomains/proof/qa-repo
xsame_world qa-repo proof
XENV=(AC_SCOPE=fam); xpair qa-repo proof --set e2e; XENV=()
assert_eq "$XO_RC" 0 "8 (W17c, named): the original let a scoped session --set"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: qa-repo --set is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - which repository a domain's proof runs in is fleet routing, and only the crewchief sets it" "8 (W17c): the port refuses a scoped --set"
[ ! -e "$XNH/home/crewdomains/proof/qa-repo" ] || fail "8 (W17c): ... with nothing written"
xboth rm -f @H/home/crewdomains/proof/qa-repo
xsame qa-repo proof --set e2e
XENV=(AC_SCOPE=fam); xpair qa-repo proof --clear; XENV=()
assert_eq "$XO_RC" 0 "8 (W17c, named): the original let a scoped session --clear"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: qa-repo --clear is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - which repository a domain's proof runs in is fleet routing, and only the crewchief sets it" "8 (W17c): the port refuses a scoped --clear"
assert_eq "$(cat "$XNH/home/crewdomains/proof/qa-repo")" "e2e" "8 (W17c): ... and the declaration stays"
xboth xput home/crewdomains/proof/qa-repo $'e2e\n'
XENV=(AC_SCOPE=fam); xsame qa-repo proof; XENV=()
assert_eq "$XN_RC:$(xout)" "0:@H/home/projects/e2e" "8: a scoped session still reads the declaration"
XENV=(AC_SCOPE=); xsame qa-repo proof --set alpha --force; XENV=()
assert_eq "$XN_RC" 0 "8: an empty AC_SCOPE is unscoped"
xboth xput home/crewdomains/proof/qa-repo $'e2e\n'
if [ "$(id -u)" != 0 ]; then
  xboth chmod 555 @H/home/crewdomains/proof
  xpair qa-repo proof --set alpha --force; xsame_rc_out qa-repo proof; xsame_world qa-repo proof
  xboth chmod 755 @H/home/crewdomains/proof
  assert_eq "$XN_RC:$(xout):$(xerr)" "0:qa-repo for proof: alpha (@H/home/projects/e2e):" "8 (W17b): a temp that cannot be written skips the mv and still reports, exit 0 (the shell's own line named)"
  assert_contains "$(xoerr)" "Permission denied" "8 (W17b): ... the original's line is the shell's"
fi
x8u() { mkdir -p "$H/home/crewdomains/proof/qa-repo"; }
xboth rm -f @H/home/crewdomains/proof/qa-repo
xboth x8u
xsame qa-repo proof --clear
assert_eq "$XN_RC" 1 "8: an rm that fails ends --clear with its status"
xboth rmdir @H/home/crewdomains/proof/qa-repo
XLC=en_US.UTF-8
xboth xput home/crewdomains/proof/qa-repo $'e2e\302\240\n'
xsame qa-repo proof; assert_eq "$(xout)" "@H/home/projects/e2e" "8: under UTF-8 tr deletes a no-break space too"
xboth xput home/crewdomains/proof/qa-repo $'e2e\351\n'
xsame qa-repo proof; assert_contains "$(xerr)" "Illegal byte sequence" "8: ... and stops at a byte that is not UTF-8, with its own line"
XLC=C
xsame qa-repo proof; assert_eq "$XN_RC" 1 "8: under C the byte stays and nothing resolves"

# 9. retire: the refusals, OPEN rows (`## Done` a prefix, rows before any
#    heading open, a story of a Done epic not counted - W16), the flying
#    chiefs, an unreadable meta (WARN, not flying), every line led by the
#    name removed (W16), then the Done history it leaves (W15).
x9() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/crewdomains/pay/records"
  xput home/crewdomains/pay/CREWMATE.md $'# Crewmate instructions: pay\n'
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- pay - again - home: /x - scope: s (added x)\n-  pay   -   spaced twin (added x)\n- Bad - c - scope: s (added x)\n'
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] q1 - queued; domain:pay\n- [ ] st - story of a done epic; epic:e1\n\n## Doneish\n\n- [x] dish - under a prefix; domain:pay\n\n## Done\n\n- [x] e1 [EPIC] - done epic; domain:pay\n- [x] dd - done; domain:pay\n'
}
xboth x9
xrefuse "ERROR: usage: ac-domain.sh retire <name>" retire
XENV=(AC_SCOPE=fam)
xrefuse "ERROR: retire is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=fam) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it" retire pay
XENV=()
xrefuse "ERROR: not a legal crewdomain name: 'Bad' $XNAME" retire Bad
xrefuse "ERROR: no VALID crewdomain 'ghost' in records/crewdomains.md - nothing to retire" retire ghost
xrefuse "ERROR: crewdomain 'pay' still holds OPEN tokened rows - unassign them first:
q1" retire pay
xboth xput home/records/backlog.md $'# Backlog\n- [ ] p0 - before any heading; domain:pay\n\n## Queued\n\n- [ ] q1 - queued; domain:pay\n- [ ] st - story of a done epic; epic:e1\n\n## Doneish\n\n- [x] dish - under a prefix; domain:pay\n\n## Done\n\n- [x] e1 [EPIC] - done epic; domain:pay\n- [x] dd - done; domain:pay\n'
xrefuse "ERROR: crewdomain 'pay' still holds OPEN tokened rows - unassign them first:
p0
q1" retire pay
xboth xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] st - story of a done epic; epic:e1\n\n## Doneish\n\n- [x] dish - under a prefix; domain:pay\n\n## Done\n\n- [x] e1 [EPIC] - done epic; domain:pay\n- [x] dd - done; domain:pay\n'
xboth xput home/state/b-chief.meta $'kind=roomchief\ndomain=inv\ndomain=pay\n'
xboth xput home/state/A-chief.meta $'domain=pay\n'
xboth xput home/state/c-chief.meta $'domain=inv\n'
xboth mkdir @H/home/state/d-chief.meta
xrefuse "ERROR: crewdomain 'pay' has a domainchief in flight (A, b) - demote it first" retire pay
xboth rm -f @H/home/state/A-chief.meta @H/home/state/b-chief.meta
if [ "$(id -u)" != 0 ]; then
  xboth xput home/state/u-chief.meta $'domain=pay\n'
  xboth chmod 000 @H/home/state/u-chief.meta
fi
xsame retire pay
if [ "$(id -u)" != 0 ]; then
  xboth chmod 644 @H/home/state/u-chief.meta
  assert_eq "$(xerr)" "WARN: cannot read meta file @H/home/state/u-chief.meta" "9 (W16): an unreadable chief meta WARNs and is not flying"
fi
assert_eq "$XN_RC:$(xout)" "0:backup: @H/home/state/backups/domain-retire-1767225600.tar.gz
retired crewdomain pay - registry line removed; the package at crewdomains/pay is kept (knowledge is never deleted by tooling)" "9: retire"
assert_eq "$(cat "$XNH/home/records/crewdomains.md")" "# Crewdomains

- inv - invoices - scope: bills (added x)
- Bad - c - scope: s (added x)" "9 (W16): every line led by the name goes, INVALID twins too"
assert_eq "$(cat "$XNH/home/state/pay.status")" "$XTS retire" "9: the status line"
xrefuse "ERROR: no VALID crewdomain 'pay' in records/crewdomains.md - nothing to retire" retire pay
# Named (W15, fixed): the orphan scans read OPEN rows
# only - a retired domain's Done rows (`## Done` a prefix, the Done epic too)
# are its kept provenance. The original read them as orphans, and validate
# stayed red for good.
xpair list; xsame_world list
assert_contains "$(cat "$TMP/xo.out")" "ORPHAN-TOKEN	pay	dd - the row names a domain with no VALID registry line (unassign it, or re-\`new\` the domain)" "9 (W15, named): the original read a retired domain's Done row as an ORPHAN-TOKEN"
case "$(xout)" in *ORPHAN-TOKEN*) fail "9 (W15): the port reads Done history as provenance, never as an orphan: $(xout)" ;; esac
assert_contains "$(xout)" "UNREGISTERED	pay	" "9: the kept package is UNREGISTERED"
xpair validate; xsame_world validate
assert_contains "$(cat "$TMP/xo.out")" "INVALID token: orphan domain token pay dd" "9 (W15, named): the original's validate stayed red on Done history"
assert_eq "$XN_RC:$(xout)" "1:INVALID - Bad - c - scope: s (added x): bad id charset" "9 (W15): the port's validate names only the INVALID registry line"
xrefuse "ERROR: 'dd' sits under '## Done', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance" unassign pay dd
# A directory without the package's three members is no kept package: still a collision.
xrefuse "ERROR: name 'pay' collides with an existing directory at crewdomains/pay" new pay --scope s --charter c --no-projects
# Named (W15, fixed): a KEPT package - CREWMATE.md,
# records/projects.md and projects/ - is RE-ADOPTED by `new`: the routing line
# is written again, the kept knowledge is not touched, and --projects adds
# only the links the view lacks. The original refused it.
x9r() {
  mkdir -p "$H/home/crewdomains/pay/projects"
  xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\nkept prose\n\n## beta\n'
  ln -s ../../../projects/beta "$H/home/crewdomains/pay/projects/beta"
}
xboth x9r
cp "$XNH/home/crewdomains/pay/CREWMATE.md" "$TMP/xkept.crewmate"; cp "$XNH/home/crewdomains/pay/records/projects.md" "$TMP/xkept.detail"
xpair new pay --scope money --charter payments --projects alpha,beta
assert_eq "$XO_RC:$(xoerr)" "1:ERROR: name 'pay' collides with an existing directory at crewdomains/pay" "9 (W15, named): the original refused the kept package"
assert_eq "$XN_RC:$(xout):$(xerr)" "0:re-adopted crewdomain pay at crewdomains/pay (1 project link(s) added; the kept package is otherwise unchanged):" "9 (W15): the port re-adopts it"
assert_eq "$(tail -n1 "$XNH/home/records/crewdomains.md")" "- pay - payments - scope: money (added $XTS)" "9 (W15): the routing line written again"
cmp -s "$XNH/home/crewdomains/pay/CREWMATE.md" "$TMP/xkept.crewmate" || fail "9 (W15): CREWMATE.md byte-unchanged"
cmp -s "$XNH/home/crewdomains/pay/records/projects.md" "$TMP/xkept.detail" || fail "9 (W15): the kept detail byte-unchanged"
assert_eq "$(readlink "$XNH/home/crewdomains/pay/projects/beta")" "../../../projects/beta" "9 (W15): the view's own beta link as it was"
assert_eq "$(readlink "$XNH/home/crewdomains/pay/projects/alpha"):$(readlink "$XNH/home/crewdomains/pay/projects/alpha.yaml")" "../../../projects/alpha:../../../projects/alpha.yaml" "9 (W15): the missing project linked, with its .yaml"
[ ! -e "$XNH/home/crewdomains/pay/projects/beta.yaml" ] || fail "9 (W15): a project already in the view is left as it is"
xrun_side "$BIN" "$XNH" xn list || true
assert_contains "$(cat "$TMP/xn.raw")" "VALID	pay	projects: 2" "9 (W15): the domain is VALID again"
case "$(cat "$TMP/xn.raw")" in *"UNREGISTERED	pay"*) fail "9 (W15): ... and no longer UNREGISTERED" ;; esac
# A re-adoption that fails mid-write undoes only what it made: the kept
# package stays whole, and the registry is not written.
mkdir -p "$XNH/home/crewdomains/keep2/records" "$XNH/home/crewdomains/keep2/projects"
printf '# Crewmate instructions: keep2\n' >"$XNH/home/crewdomains/keep2/CREWMATE.md"; printf '# Projects: keep2\n' >"$XNH/home/crewdomains/keep2/records/projects.md"
cp "$XNH/home/crewdomains/keep2/CREWMATE.md" "$TMP/xkeep2.crewmate"; cp "$XNH/home/crewdomains/keep2/records/projects.md" "$TMP/xkeep2.detail"
echo 2 >"$XNH/ln.fail-at"; rm -f "$XNH/ln.count"
xrun_side "$BIN" "$XNH" xn new keep2 --scope s --charter c --projects alpha && fail "9 (W15): the failing re-adoption must fail"
rm -f "$XNH/ln.fail-at" "$XNH/ln.count"
assert_eq "$(cat "$TMP/xn.err")" "ln: the stub refuses
rolled back the re-adoption of the kept package at $XNH/home/crewdomains/keep2 - it is as it was, and nothing was registered" "9 (W15): the rollback names what it did"
assert_eq "$(ls -A "$XNH/home/crewdomains/keep2/projects")" "" "9 (W15): ... the link it made gone"
cmp -s "$XNH/home/crewdomains/keep2/CREWMATE.md" "$TMP/xkeep2.crewmate" && cmp -s "$XNH/home/crewdomains/keep2/records/projects.md" "$TMP/xkeep2.detail" \
  || fail "9 (W15): ... and the kept package's knowledge byte-unchanged"
case "$(cat "$XNH/home/records/crewdomains.md")" in *"keep2"*) fail "9 (W15): ... and nothing registered" ;; esac
xboth x9
xboth xput home/records/backlog.md $'## Done\n'
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xpair retire pay; xsame_rc_out retire pay
  xboth chmod 644 @H/home/records/backlog.md
  xsame_world retire pay
  assert_eq "$XN_RC:$(xerr)" "2:ERROR: cannot read @H/home/records/backlog.md" "9: an unreadable ledger is exit 2 - the parser's own line (named)"
fi
xplant "$xobin" "$XOH" "$TMP/xpo.raw" records/crewdomains.md retire pay
xplant "$BIN" "$XNH" "$TMP/xpn.raw" records/crewdomains.md retire pay
assert_eq "$(xnorm "$TMP/xpn.raw" "$XNH")" "$(xnorm "$TMP/xpo.raw" "$XOH")" "9: the planted row's output"
[ -L "$XOH/home/records/crewdomains.md" ] || fail "9 (W9): the original renamed the planted link over the registry"
[ ! -L "$XNH/home/records/crewdomains.md" ] || fail "9 (W9): the port's registry stays a regular file"
assert_eq "$(cat "$XNH/victim")" "victim bytes" "9 (W9): the port never writes through a planted temp name"
assert_eq "$(cat "$XNH/home/records/crewdomains.md")" "$(cat "$XOH/victim")" "9: the same registry bytes"

# 10. list: ABSENT (absent, a directory), EMPTY - neither scans (W3); the
#     table: every INVALID reason, a TAB (W5), a lone `- `, unset scope, no
#     package (W3), dangling and .yaml entries, the in-flight line,
#     UNREGISTERED (legal, illegal and symlinked dirs), an ORPHAN-TOKEN on an
#     open row (Done history is row 9's); an unreadable ledger; a 0xE9 registry byte under C and UTF-8
#     (W2); an unreadable registry (W2).
x10() {
  rm -rf "$H/home/crewdomains" "$H/home/state" "$H/home/records"; mkdir -p "$H/home/records" "$H/home/state"
  xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] stray - names a ghost; domain:ghost\n- [ ] m1 - a domain:ghost mention\n'
}
xboth x10
xsame list; assert_eq "$(xout)" "$XABSENT" "10 (W3): absent - no scan of the stray token"
xboth mkdir @H/home/records/crewdomains.md
xsame list; assert_eq "$(xout)" "$XABSENT" "10: a directory is ABSENT"
xboth rmdir @H/home/records/crewdomains.md
xboth xput home/records/crewdomains.md $'# Crewdomains\n\nprose\n'
xsame list; assert_eq "$(xout)" "EMPTY: records/crewdomains.md present, 0 entries - no crewdomains registered" "10 (W3): EMPTY - no scan either"
x10t() {
  x10; rm -rf "$H/elsewhere"
  xput home/records/crewdomains.md $'# Crewdomains\n\n- pay - payments - scope: money - and more (added x)\n- \n- nodate - c - scope: s\n- bad - c - home: /x - scope: s (added x)\n- noscope - c (added x)\n- nocharter - scope: s (added x)\n- Pay - c - scope: s (added x)\n- pay - again - scope: s (added x)\n- t\tab - c - scope: s (added x)\n- tab - a\tb - scope: s (added x)\n- unset - c - scope:  (added x)\n- nopkg - c - scope: s (added x)\n- crlf - c - scope: s (added x)\r\n'
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
xboth x10t
xsame list
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
INVALID	- t	reason: $(printf '\037')bad id charset
VALID	tab	projects: 0
	charter: a
	scope: b
	backlog: queued 0, in flight 0, done 0
VALID	unset	projects: 0
	charter: c
	scope: (unset - not routable until a scope: is added)
	backlog: queued 0, in flight 0, done 0
VALID	nopkg	projects: 0
	charter: c
	scope: s
	backlog: queued 0, in flight 0, done 0
INVALID	- crlf - c - scope: s (added x)$(printf '\r')	reason: missing \"(added ...)\"
UNREGISTERED	kept	package on disk with no VALID registry line - re-adopt it with \`new\`, restore its line in records/crewdomains.md, or leave it as kept knowledge
UNREGISTERED	linkd	package on disk with no VALID registry line - re-adopt it with \`new\`, restore its line in records/crewdomains.md, or leave it as kept knowledge
ORPHAN-TOKEN	ghost	stray - the row names a domain with no VALID registry line (unassign it, or re-\`new\` the domain)
registered: 13 (invalid 9)" "10: the table, W5's TAB shifts, W3's package-less VALID"
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xpair list; xsame_rc_out list
  xboth chmod 644 @H/home/records/backlog.md
  xsame_world list
  assert_contains "$(xout)" "WARN	ledger unreadable - backlog tallies and the ORPHAN-TOKEN scan are unavailable" "10: an unreadable ledger is named"
  assert_eq "$(xerr | sort -u)" "ERROR: cannot read @H/home/records/backlog.md" "10: the port's line per read is the parser's own (named)"
  assert_eq "$(xerr | wc -l | tr -d " ")" "$(xoerr | grep -c "can.t open file")" "10: ... one per read, as the original's awk"
fi
xboth xadd home/records/crewdomains.md $'- b\351d - c - scope: s (added x)\n'
xsame list; assert_contains "$(xout)" "reason: bad id charset" "10: a 0xE9 registry byte under C"
XLC=en_US.UTF-8; xsame list; XLC=C
assert_eq "$XN_RC:$(xout)" "2:" "10 (W2): under UTF-8 the parse aborts and list exits 2 with nothing on stdout"
assert_contains "$(xerr)" "towc" "10 (W2): awk's own line"
xboth x10t
xboth xadd home/records/backlog.md $'- [x] latin2 - caf\351 menu (merged 2026-08-01)\n'
XLC=en_US.UTF-8; xsame list; XLC=C
assert_contains "$(xout)" "backlog: queued 2, in flight 1, done 1" "10: a ledger byte that is not UTF-8 never costs the tally"
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/crewdomains.md
  xsame list
  xboth chmod 644 @H/home/records/crewdomains.md
  assert_eq "$XN_RC:$(xout)" "2:" "10 (W2): an unreadable registry is exit 2, nothing on stdout"
fi

# 11. validate: no registry with stray and malformed tokens (W3, silent 0);
#     an unreadable registry (W3); INVALID lines; every view class; the
#     detail checks; W19's word split (from an empty cwd); W20 under C; the
#     token discipline; an unreadable ledger.
xboth x10
xsame validate; assert_eq "$XN_RC:$(xout)" "0:" "11 (W3): no registry - the ledger is not scanned"
x11() {
  x10
  xput home/records/crewdomains.md $'- pay - payments - scope: money (added x)\n- inv - invoices - scope: bills (added x)\n- ops - ops - scope: o (added x)\n- t\tab - c - scope: s (added x)\n- \n'
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
xboth x11
xsame validate
assert_eq "$XN_RC:$(xout)" "1:INVALID - t: $(printf '\037')bad id charset
INVALID - : missing \"(added ...)\"
WARN pay: projects/aliased has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal
WARN pay: projects/e2e has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal
INVALID inv: projects/copied is not a symlink - a domain view LINKS the fleet clones, it never holds a copy
INVALID inv: projects/gone dangles - it resolves to nothing
INVALID inv: projects/out resolves OUTSIDE the fleet clones (@H/elsewhere) - a view may only select from the fleet projects dir
INVALID inv: projects/wrong resolves to @H/home/projects/alpha, not to its OWN clone - a view entry must name the project it links, or it authorizes work on a repository the domain never selected
INVALID token: orphan domain token ghost stray
INVALID token: m1 carries a domain:-shaped run off its grammar position (backtick-quote a mention, or re-stamp with assign)" "11: INVALID lines (W5's cut), every view class, the .yaml WARN, the tokens"
x11d() {
  xput home/records/projects.md $'# Projects\n\n- alpha [crew-ship] - the alpha service, payments edge (added 2026-08-02)\n- beta - the beta service and its queue (added 2026-08-02)\n- e2e - short (added x)\n- vn - \304\221\341\272\267t h\303\240ng (added x)\n- tail - the unterminated last line here'
  xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\n## alpha\n\nthe alpha service, payments edge\n\nthe beta service and its queue\n\nshort\n\n\304\221\341\272\267t h\303\240ng\n\nthe unterminated last line here\n\n## beta\n\n## e2e\n\n## aliased\n\nuses [direct-pr] here\n'
}
xboth x11d
xsame validate
assert_contains "$(xout)" "WARN pay: records/projects.md repeats the FLEET description of alpha verbatim" "11: a bracketed fleet description copied in"
assert_contains "$(xout)" "WARN pay: records/projects.md repeats the FLEET description of beta verbatim" "11: ... and a bracketless one"
assert_contains "$(xout)" "WARN pay: records/projects.md repeats the FLEET description of vn verbatim" "11 (W20): 8 characters, 12 bytes - under C it counts"
case "$(xout)" in *"description of e2e"*|*"description of tail"*) fail "11: a short description and an unterminated last line are never compared" ;; esac
assert_contains "$(xout)" "WARN pay: records/projects.md carries a delivery-mode token" "11: a mode token"
# Named (W20): under UTF-8 the original counted characters - 8 < 12.
XLC=en_US.UTF-8; xpair validate; XLC=C
case "$(cat "$TMP/xo.out")" in *"description of vn"*) fail "11 (W20): the original under UTF-8 counts characters" ;; esac
assert_contains "$(xout)" "description of vn" "11 (W20): the port counts bytes under any locale (named)"
x11h() {
  xput home/crewdomains/pay/records/projects.md $'# Projects: pay\n\n## alpha\n\n## ghostproject\n\n## *\n\n## Notes (2026)\n\n##\n\n## \n'
  ln -s ../../../projects/beta "$H/home/crewdomains/pay/projects/be ta"
}
xboth x11h
xsame validate
assert_contains "$(xout)" 'WARN pay: projects/beta is in the view but has no "## beta" heading in records/projects.md - the detail prose has lagged the view' "11: view without heading"
assert_contains "$(xout)" 'WARN pay: records/projects.md documents "## ghostproject" but the view does not link it - the detail prose names a project this domain cannot work' "11: heading without view"
assert_contains "$(xout)" 'WARN pay: records/projects.md documents "## *" but the view does not link it' "11 (W19): a glob heading stays a word from an empty cwd"
assert_contains "$(xout)" 'WARN pay: records/projects.md documents "## (2026)" but the view does not link it' "11 (W19): a spaced heading is two words"
assert_contains "$(xout)" 'WARN pay: projects/be is in the view but has no "## be" heading' "11 (W19): a spaced view entry is two words too"
assert_contains "$(xout)" "INVALID pay: projects/be ta resolves to @H/home/projects/beta, not to its OWN clone" "11: ... and its own mismatch"
# Named: pathname expansion. From a cwd holding a file the original's
# unquoted loop turned `## *` into that name; the port keeps the word.
xboth mkdir -p @H/globcwd2; xboth touch @H/globcwd2/zfile
XCWD=globcwd2; xpair validate; XCWD=cwd
assert_contains "$(cat "$TMP/xo.out")" '"## zfile"' "11 (W19, named): the original expanded the heading against its cwd"
assert_contains "$(xout)" '"## *"' "11 (W19, named): the port keeps the word"
xboth rm -f "@H/home/crewdomains/pay/projects/be ta"
xboth rm -f @H/home/crewdomains/pay/records/projects.md
xsame validate
case "$(xout)" in *"WARN pay: records"*|*"heading"*) fail "11: no detail file - the detail checks stop" ;; esac
xboth xput home/records/backlog.md $'# Backlog\n\n## Queued\n\n- [ ] e [EPIC] - epic; domain:pay\n- [ ] s - story; epic:e; domain:inv\n- [ ] s2 - story; epic:e\n- [ ] e2 [EPIC] - an untokened epic\n- [ ] s3 - story; epic:e2; domain:inv\n- [ ] n - names; domain:ghost\n- [ ] m - a domain:pay mention; domain:pay\n- [ ] doc - a `domain:pay` mention\n'
xsame validate
case "$(xout)" in *"story s3"*) fail "11: a tokened story under an untokened epic disagrees with nothing" ;; esac
assert_contains "$(xout)" "INVALID token: story s carries domain:inv but its epic e carries domain:pay - one family, one domain" "11: DISAGREE"
assert_contains "$(xout)" "INVALID token: orphan domain token ghost n" "11: ORPHAN"
assert_contains "$(xout)" "INVALID token: m carries a domain:-shaped run off its grammar position" "11: MALFORMED"
case "$(xout)" in *"doc carries"*) fail "11: a backtick-quoted mention is inert" ;; esac
if [ "$(id -u)" != 0 ]; then
  xboth chmod 000 @H/home/records/backlog.md
  xpair validate; xsame_rc_out validate
  xboth chmod 644 @H/home/records/backlog.md
  xsame_world validate
  assert_contains "$(xout)" "INVALID ledger: cannot read @H/home/records/backlog.md" "11: an unreadable ledger is named on stdout"
  assert_eq "$XN_RC:$(xerr)" "2:ERROR: cannot read @H/home/records/backlog.md" "11: ... exit 2, the parser's own line (named)"
  assert_contains "$(xoerr)" "can't open file" "11: the original's line was awk's"
  xboth chmod 000 @H/home/records/crewdomains.md
  xsame validate
  xboth chmod 644 @H/home/records/crewdomains.md
  assert_eq "$XN_RC" 1 "11 (W3): an unreadable registry passes its own lines silently - only the tokens then read as orphans"
  assert_contains "$(xout)" "INVALID token: orphan domain token pay e" "11 (W3): ... every token an orphan"
  assert_contains "$(xerr)" "can't open file" "11 (W3): awk's own line, once per parse"
fi
xboth xput home/records/crewdomains.md $'- pay - c - scope: s (added x)\n- b\351d - c - scope: s (added x)\n'
xboth xput home/records/backlog.md $'# Backlog\n'
xboth rm -rf @H/home/crewdomains
XLC=en_US.UTF-8; xsame validate; XLC=C
assert_eq "$XN_RC:$(xout)" "0:" "11 (W3/W4): under UTF-8 a registry whose only fault is a byte that is not UTF-8 passes silently"
xsame validate
assert_eq "$XN_RC" 1 "11: ... and fails under C"

pass
