#!/usr/bin/env bash
# ac-domain.sh - the CREWDOMAIN verb layer: create a domain package and route
# work into it.
#
# Usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>'
#                                (--projects <p1,p2,...> | --no-projects)
#
# A crewdomain is durable STATE inside this fleet - a package plus one routing
# line - with no home, no session, no liveness and no lifecycle of its own. Work
# reaches it when the crewchief ASSIGNS a row into its backlog; work happens
# when the crewchief promotes a DOMAINCHIEF, an ordinary roomchief whose domain
# binding is derived from that assignment.
#
# COEXISTENCE with crewdeputy, which this script never touches. The two features
# share no registry, no root, no script and no verb - crewdeputy keeps
# bin/ac-deputy.sh, records/crewdeputies.md, $AC_HOME/crewdeputies/<name>/ and
# every verb it has. Choose by what the work needs: ISOLATION (separate clones,
# credentials, budget, delegable to another operator) -> a crewdeputy or a full
# fleet; a KNOWLEDGE and BACKLOG SLICE over the fleet's own clones -> a
# crewdomain. The one place the two meet is the NAME, and `new` refuses a
# collision rather than leaving the chief to disambiguate it forever.
#
# The registry GRAMMAR is owned by ac-lib.sh's `crewdomain routing table` block;
# this script owns the verbs.
#
# --- new: the package, whole or nothing ----------------------------------------
#
# AUTHORITATIVE for the package layout. FOUR members at
# $AC_HOME/crewdomains/<name>/:
#
#   records/backlog.md    the fleet ledger's sections and line grammar. `assign`
#                         creates rows; the domainchief moves them between
#                         sections and may never mint one.
#   records/projects.md   the domain's DETAIL about its in-scope projects - what
#                         part of each belongs to the domain, partner context,
#                         constraints, entry points. NEVER `[mode]` and never
#                         the fleet description: those resolve from the fleet
#                         records/projects.md alone. Verified CODEBASE facts
#                         belong in records/repo-knowledge/<project>.md.
#   CREWMATE.md           the domain instruction layer, appended last onto the
#                         container+fleet baseline by the seed chain.
#   projects/             one symlink per in-scope project plus its <proj>.yaml
#                         pipeline config, both resolving into $AC_HOME/projects.
#                         The domain works the FLEET's own clone through a
#                         different path, so a local-only landing reaches the
#                         working copy the crewchief reads and nothing can drift.
#
# There is deliberately NO captain.md: domain standing rules are lines in the
# FLEET records/captain.md prefixed `STANDING (domain:<name>): `, because those
# rules drive TRIAGE at chief intake - BEFORE assign - and a file inside the
# package would be read only afterwards, too late to govern the decision it
# exists for. And NO learnings.md: a domainchief notes to the fleet ledger with
# a `(domain:<name>)` prefix, so there is one ledger and one distill pipeline.
#
# EIGHT namespaces are checked BEFORE any write, and the first hit refuses the
# whole command naming which one collided: the crewdomain registry id; a
# crewdeputy registry id; an existing crewdeputy home; the package directory;
# data/<name>/; state/<name>-chief.meta; an id already in records/backlog.md;
# and the reserved stage suffixes ac-ready.sh already refuses. `new` creates the
# whole package or nothing - a half-built package is a domain that lists,
# routes, and then fails at the first verb that reads the member it lacks.
#
# The projects argument is EXPLICIT and has no default: the layout needs a
# project set at creation time, and a silent empty view is the wrong default. A
# project the fleet lacks refuses the whole command; a project whose .yaml the
# fleet lacks gets its clone link alone and is named on stdout, because a
# project with no pipeline config is a supported state (AGENTS.md section 4
# calls it a direct-pr case) and refusing would make the view un-buildable.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"
. "$(dirname "$0")/ac-maintenance-lib.sh"

REGISTRY_LABEL='records/crewdomains.md'
# ac_domain_parse emits TSV, but a TAB is IFS-WHITESPACE: `read` collapses runs
# of it, so an INVALID record (three empty fields) or an entry with an empty
# scope would silently SHIFT every later field. Re-separate with US (\037), a
# non-whitespace delimiter `read` keeps positional, before any loop.
FS_US=$'\037'

domain_pkg() {
  # domain_pkg <name> - the package root. Derived, never stored: a crewdomain
  # has no `home:` field precisely because there is nothing for it to disagree
  # with. Derivation by concatenation is exactly why the name is CHECKED here
  # rather than at each call site - an unchecked `../crewdeputies/demo` would
  # reach into a kept feature's own state, and `..` alone aliases the fleet's
  # records/. Every verb that takes a name reaches its package through this.
  ac_domain_name_ok "$1" \
    || ac_die "not a legal crewdomain name: '$1' (charset [a-z0-9-], no path separators) - refusing to derive a package path from it"
  printf '%s/crewdomains/%s\n' "$(ac_home)" "$1"
}

domain_require_name() {
  # domain_require_name <name> - the charset gate, called in the MAIN shell of
  # every name-taking verb. domain_pkg checks too, but it is almost always
  # reached inside a command substitution, where ac_die exits only the subshell
  # and the caller sails on with a truncated path - so the check that actually
  # REFUSES has to happen out here.
  ac_domain_name_ok "$1" \
    || ac_die "not a legal crewdomain name: '$1' (charset [a-z0-9-], no path separators) - refusing to derive a package path from it"
}

domain_require_ids() {
  # domain_require_ids <id>... - every backlog id is a LITERAL. These ids are
  # interpolated into awk REGEXES to find their rows; unvalidated, a `.` or `*`
  # stops being a literal and matches a DIFFERENT row, so the verb would move
  # work nobody named. Checked in the main shell, before any read or write.
  local i
  for i in "$@"; do
    ac_backlog_id_ok "$i" \
      || ac_die "not a legal backlog id: '$i' (charset [a-z0-9-]) - refusing rather than matching it as a regular expression against the ledger"
  done
}

domain_chief_only() {
  # domain_chief_only <verb> - the crewchief owns every mutating verb here.
  # The ledger guard covers Edit/Write/NotebookEdit and NOT the Bash tool, so
  # without this a scoped session could run the verb directly, move a fleet row
  # and STAMP it assigned:crewchief - after which the audit reads the forged
  # provenance as authorized and chief-only-add is defeated by its own token.
  [ -z "${AC_SCOPE:-}" ] \
    || ac_die "$1 is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=$AC_SCOPE) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it"
}

domain_dedupe() {
  # domain_dedupe <label> <item>... - echo the items, refusing an empty or
  # repeated one BEFORE any caller writes. A repeat is not harmless here: it
  # half-builds a package (the second `ln` fails after the first succeeded),
  # double-appends a stamped row, or returns one row twice - each breaking the
  # whole-or-nothing and reversibility properties the verbs promise.
  local label="$1" seen="" it; shift
  for it in "$@"; do
    [ -n "$it" ] || ac_die "empty $label in the argument list - refusing before any write"
    case " $seen " in
      *" $it "*) ac_die "duplicate $label \"$it\" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible" ;;
    esac
    seen="$seen $it"
    printf '%s\n' "$it"
  done
}

domain_row_tokened() {
  # domain_row_tokened <row> - 0 when the row carries the provenance token AT
  # its grammar position: immediately before the trailing `(repo: ...)` group,
  # or at end of line when the row has none.
  #
  # THE ONE definition. audit and unassign each had their own and they
  # disagreed - audit end-anchored, unassign a bare substring - so a row whose
  # prose merely MENTIONS the token read as UNAUTHORIZED to the audit and as
  # legitimate to unassign, which is precisely the laundering path. A predicate
  # with two implementations is a predicate with two answers.
  case "$1" in
    *"; assigned:crewchief") return 0 ;;
  esac
  printf '%s' "$1" | grep -qE '; assigned:crewchief \(repo: [^()]*\)$'
}

domain_token_re() {
  # domain_token_re - the provenance token AT ITS GRAMMAR POSITION, never
  # anywhere on the line. `assign` writes `; assigned:crewchief` immediately
  # before the trailing `(repo: ...)` group, or at end-of-line when a row has
  # none. Matching the bare phrase anywhere would let ordinary task prose that
  # merely QUOTES it pass the audit, and would make the strip delete that prose
  # while leaving the real token in place.
  printf '%s' '; assigned:crewchief\( (repo: \|$\)'
}

cmd_new() {
  local name="" scope="" charter="" projects="" no_projects=0
  local have_scope=0 have_charter=0 have_projects=0
  name="${1:-}"; [ -n "$name" ] || ac_die "usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>' (--projects <p1,p2,...> | --no-projects)"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --scope) scope="${2:-}"; have_scope=1; shift 2 ;;
      --charter) charter="${2:-}"; have_charter=1; shift 2 ;;
      --projects) projects="${2:-}"; have_projects=1; shift 2 ;;
      --no-projects) no_projects=1; shift ;;
      *) ac_die "unknown argument: $1" ;;
    esac
  done
  domain_chief_only new
  # PRESENCE, not value. Tracking only the value let `--scope ""` and an omitted
  # --scope look identical (both mint an unroutable entry silently), and let
  # `--projects '' --no-projects` slip past the exclusivity check.
  [ "$have_charter" = 1 ] && [ -n "$charter" ] \
    || ac_die "--charter '<one-liner>' is required and may not be empty: it is what the chief reads in the digest"
  [ "$have_scope" = 1 ] \
    || ac_die "--scope '<text>' is required: it is the routing key, and an entry without one is registered but never routable. Pass --scope '' deliberately if that is what you mean."
  [ "$have_projects" = 0 ] || [ "$no_projects" = 0 ] \
    || ac_die "--projects and --no-projects are mutually exclusive - refusing rather than silently building the empty view you did not ask for"
  [ "$no_projects" = 1 ] || [ "$have_projects" = 1 ] \
    || ac_die "pass --projects <p1,p2,...> or --no-projects explicitly - a silent empty project view is the wrong default"
  # A locale whose collation interleaves case makes a plain a-z range admit most
  # uppercase letters through this glob (the ac-home-seed.sh lesson).
  (LC_ALL=C; case "$name" in *[!a-z0-9-]*) exit 1 ;; esac) \
    || ac_die "name must be [a-z0-9-]: $name"

  local home records pkg
  home="$(ac_home)"
  records="$(ac_records_dir)"
  pkg="$(domain_pkg "$name")"

  # --- the eight namespaces, all before any write ---------------------------
  case "$name" in
    *-spec|*-arch|*-plan|*-review|*-ship|*-design|*-chief|*-r[0-9]|*-r[0-9][0-9])
      ac_die "name '$name' collides with a reserved stage suffix - a family id derives stage dirs from it" ;;
  esac
  # An INVALID record puts the VERBATIM LINE in field 2, not the id, so a
  # field-2 comparison silently misses a collision sitting on a malformed line -
  # and a malformed line is exactly where a half-typed duplicate lives. Read the
  # LEADING TOKEN of every `- ` line instead, which is the id in both classes.
  registry_holds_id() {  # registry_holds_id <file> <name>
    [ -f "$1" ] || return 1
    awk -v n="$2" '
      substr($0, 1, 2) != "- " { next }
      { line = substr($0, 3); sub(/ +- .*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == n) { found = 1 } }
      END { exit !found }
    ' "$1"
  }
  if registry_holds_id "$(ac_domain_registry)" "$name"; then
    ac_die "name '$name' is already registered in $REGISTRY_LABEL"
  fi
  if registry_holds_id "$records/crewdeputies.md" "$name"; then
    ac_die "name '$name' is already a crewdeputy in records/crewdeputies.md - the two features share no file, but they share the operator's vocabulary and the chief's routing judgment; pick a different name"
  fi
  [ ! -e "$home/crewdeputies/$name" ] \
    || ac_die "name '$name' collides with an existing crewdeputy home at crewdeputies/$name"
  [ ! -e "$pkg" ] \
    || ac_die "name '$name' collides with an existing directory at crewdomains/$name"
  [ ! -e "$home/data/$name" ] \
    || ac_die "name '$name' collides with a task data dir at data/$name"
  [ ! -e "$home/state/$name-chief.meta" ] \
    || ac_die "name '$name' collides with a live chief session at state/$name-chief.meta"
  if [ -f "$records/backlog.md" ] \
     && grep -qE "^- \[[ x]\] $name " "$records/backlog.md"; then
    ac_die "name '$name' is already a row id in records/backlog.md"
  fi

  # The routing line this command is ABOUT to write must itself parse VALID.
  # Otherwise a successful `new` can leave a package whose own registry entry is
  # INVALID - unroutable, un-promotable, and only discovered later by validate.
  # Checked against the real parser, so the grammar has exactly one definition.
  local candidate; candidate="$(printf -- '- %s - %s - scope: %s (added %s)' "$name" "$charter" "$scope" "$(ac_iso)")"
  # $'\n', not "$(printf '\n')": command substitution strips trailing newlines,
  # so the latter is the EMPTY string and the pattern would match everything.
  case "$candidate" in
    *$'\n'*) ac_die "--charter/--scope must be single-line: a newline would split the routing line in two" ;;
  esac
  # mktemp, not a path under the package: nothing has created that directory
  # yet, and this check runs BEFORE any write by design.
  local probe; probe="$(mktemp "${TMPDIR:-/tmp}/ac-domain-line.XXXXXX")"
  printf '%s\n' "$candidate" >"$probe"
  if ! ac_domain_parse "$probe" | grep -q '^VALID'; then
    local why; why="$(ac_domain_parse "$probe" | cut -f5)"
    rm -f "$probe"
    ac_die "the routing line these arguments would write does not parse VALID ($why) - refusing before any write. Check --charter and --scope for a ' - <word>:' token, which this grammar reads as an unknown field."
  fi
  rm -f "$probe"

  # --- projects, validated against the fleet's clones before any write ------
  local -a wanted=()
  if [ "$no_projects" = 0 ]; then
    # Validate the RAW CSV before splitting. Word-splitting silently drops empty
    # components, so `--projects ,` or `alpha,,beta` would build an empty or
    # short view while the caller believes they named projects - which is the
    # explicit-choice contract failing open. The charset check also has to
    # precede the split because the split is UNQUOTED: a glob character would
    # otherwise reach pathname expansion.
    case "$projects" in
      ,*|*,|*,,*) ac_die "malformed --projects list \"$projects\": leading, trailing or repeated commas - refusing before any write rather than silently building a shorter view" ;;
    esac
    # Reject only what breaks the SPLIT or the PATH - not the fleet's own naming.
    # An earlier cut narrowed names to [a-z0-9-] and would have refused a clone
    # the fleet legitimately holds; existence against $AC_HOME/projects is the
    # real contract, and globbing is disarmed below rather than legislated away.
    case "$projects" in
      */*) ac_die "--projects takes project NAMES, not paths: \"$projects\"" ;;
    esac
    # ASSIGN first, then loop. A `for p in $(domain_dedupe ...)` swallows the
    # refusal outright - ac_die exits the substitution's subshell and the loop
    # simply iterates fewer items - whereas a simple assignment's non-zero
    # substitution is what errexit actually checks.
    # set -f around the unquoted split: a project name is a literal, and without
    # this a `*` would reach pathname expansion and silently become a file list.
    local p plist
    set -f; plist="$(domain_dedupe "project" ${projects//,/ })"; set +f
    [ -n "$plist" ] || ac_die "--projects named no project - pass --no-projects if the empty view is what you meant"
    for p in $plist; do
      [ -d "$home/projects/$p/.git" ] \
        || ac_die "the fleet has no clone at projects/$p - a domain view links the fleet's own clones, it never makes one"
      wanted+=("$p")
    done
  fi

  # --- write ----------------------------------------------------------------
  # WHOLE OR NOTHING covers a failure DURING the write too, not only a refusal
  # before it: a dangling ln or a full disk halfway through used to leave a
  # package that lists and routes and then fails at the first verb reading the
  # member it lacks. The trap removes exactly what this command created, and is
  # cleared once the registry line - the last write - is down.
  domain_new_rollback() {
    [ -n "${_ac_new_pkg:-}" ] || return 0
    rm -rf "$_ac_new_pkg"
    printf 'rolled back the partial package at %s - nothing was created\n' "$_ac_new_pkg" >&2
  }
  _ac_new_pkg="$pkg"
  trap domain_new_rollback EXIT
  mkdir -p "$pkg/records" "$pkg/projects"
  printf '# Backlog: %s\n\n## In flight\n\n## Queued\n\n## Done\n' "$name" >"$pkg/records/backlog.md"
  # ONE `## <project-name>` heading per in-scope project (captain ruling
  # 2026-08-02). The file is free prose everywhere else; the heading is the only
  # machine-readable part, and it exists so `validate` can compare the DETAIL
  # set against the symlink set in BOTH directions. It stays ADVISORY - prose
  # may lag, the guard may not.
  {
    printf '# Projects: %s\n\nThe domain'"'"'s view of each in-scope project - which part belongs to this domain, partner context, constraints, entry points. Delivery mode and the fleet description live in records/projects.md; verified code facts live in records/repo-knowledge/<project>.md.\n' "$name"
    printf '\nOne `## <project-name>` heading per in-scope project - `validate` compares that set against the projects/ view.\n'
    local hp
    for hp in ${wanted+"${wanted[@]}"}; do printf '\n## %s\n' "$hp"; done
  } >"$pkg/records/projects.md"
  printf '# Crewmate instructions: %s\n\nThe domain instruction layer, seeded onto the fleet baseline.\n' \
    "$name" >"$pkg/CREWMATE.md"

  # Relative links, at the depth that resolves from projects/: `../` is the
  # package root, `../../` is crewdomains/, `../../../` is the home. Resolution
  # is what R12 validates, so an absolute link would be equally valid - this
  # keeps the package relocatable with the home.
  local yamlless=""
  if [ "${#wanted[@]}" -gt 0 ]; then
    local w
    for w in "${wanted[@]}"; do
      ln -s "../../../projects/$w" "$pkg/projects/$w"
      if [ -e "$home/projects/$w.yaml" ]; then
        ln -s "../../../projects/$w.yaml" "$pkg/projects/$w.yaml"
      else
        yamlless="$yamlless $w.yaml"
      fi
    done
  fi

  printf '%s\n' "$candidate" >>"$(ac_domain_registry)"
  _ac_new_pkg=""; trap - EXIT

  printf 'created crewdomain %s at crewdomains/%s (%s project link(s))\n' \
    "$name" "$name" "${#wanted[@]}"
  [ -z "$yamlless" ] \
    || printf 'no pipeline config in the fleet for:%s - linked the clone alone (a project with no <name>.yaml is a supported direct-pr case)\n' "$yamlless"
}

domain_valid_scope() {
  # domain_valid_scope <name> - print the scope of a VALID entry, or die. Both
  # `assign` and the promote-time derivation demand this, so a domain whose
  # registry line was removed while its package still holds rows cannot go on
  # being routed to.
  local name="$1" rec
  rec="$(ac_domain_parse | awk -F'\t' -v n="$name" '$1 == "VALID" && $2 == n { print $4; found = 1; exit } END { exit !found }')" \
    || ac_die "no VALID crewdomain '$name' in $REGISTRY_LABEL"
  [ -n "$rec" ] \
    || ac_die "crewdomain '$name' has an empty scope: - it is not routable, and the chief may not invent scope text for it"
  printf '%s\n' "$rec"
}

domain_backlog() {
  # domain_backlog <name> - the package backlog, or die.
  local f; f="$(domain_pkg "$1")/records/backlog.md"
  [ -f "$f" ] || ac_die "crewdomain '$1' has no records/backlog.md at $f"
  printf '%s\n' "$f"
}

domain_view_names() {
  # domain_view_names <name> - the project names the view links, one per line.
  # A glob rather than `ls | grep`: it keeps a name with a space or a newline
  # intact, and it is the same list `list` counts and `validate` compares the
  # detail file against - one reading, two consumers.
  local e
  for e in "$(domain_pkg "$1")"/projects/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    case "${e##*/}" in *.yaml) continue ;; esac
    printf '%s\n' "${e##*/}"
  done
}

domain_unauthorized() {
  # domain_unauthorized <name> - one `<name> <id>` line per untokened row.
  # Read-only. `assign` stamps the token and is its ONLY writer, so a row
  # without one was not put there by the chief.
  local name="$1" f
  f="$(domain_pkg "$name")/records/backlog.md"
  [ -f "$f" ] || return 0
  awk -v n="$name" '
    /^- \[/ && $0 !~ /; assigned:crewchief \(repo: [^()]*\)$/ && $0 !~ /; assigned:crewchief$/ {
      line = $0; sub(/^- \[[ x]\] /, "", line); split(line, p, " ")
      printf "%s %s\n", n, p[1]
    }
  ' "$f"
}

domain_names() {
  # domain_names - every VALID registered id, in file order.
  ac_domain_parse | awk -F'\t' '$1 == "VALID" { print $2 }'
}

cmd_assign() {
  # cmd_assign <name> <backlog-id>... - move named fleet `## Queued` rows into
  # the domain backlog. Every precondition is checked BEFORE any write and any
  # failure aborts the WHOLE assign: a partial move splits a queue across two
  # ledgers with no record of the split.
  #
  # There is deliberately NO delivery-mode branch here, and no local-only
  # refusal. The deputy handoff has one because a deputy home holds its OWN
  # clone, so a local-only landing there never reaches the fleet's copy; a
  # crewdomain links the FLEET's clone, so that ground cannot arise. The
  # absence is by construction, not a veto - the deputy guard stays alive and
  # correct where it is (bin/ac-deputy.sh handoff, which owns the rule and every
  # mention of its name; this file deliberately carries none, so that guard's
  # site inventory stays exactly as long as it is).
  local name="${1:-}" backlog dom_backlog item found line section arc unauth
  shift 1 2>/dev/null || true
  [ -n "$name" ] && [ $# -gt 0 ] || ac_die "usage: ac-domain.sh assign <name> <backlog-id>..."
  domain_chief_only assign
  domain_require_name "$name"
  # `set -- $(...)` reports the BUILTIN's status, not the substitution's, so a
  # refusal inside it would be lost; assign to a variable, which errexit checks.
  local idlist; idlist="$(domain_dedupe "backlog id" "$@")"
  set -f; set -- $idlist; set +f
  domain_require_ids "$@"
  domain_valid_scope "$name" >/dev/null
  dom_backlog="$(domain_backlog "$name")"
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || ac_die "no fleet backlog at $backlog"

  unauth="$(domain_unauthorized "$name")"
  [ -z "$unauth" ] || ac_die "crewdomain '$name' is carrying an UNAUTHORIZED row and may not be given more work until it is reconciled:
$unauth
Either ADOPT it (mint it in records/backlog.md, then assign it - which stamps the provenance) or DELETE it, and tell the family room either way."

  local moving="" ids=""
  for item in "$@"; do
    found="$(awk -v id="$item" '
      /^## / { sec = substr($0, 4); next }
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
      END { if (n == 1) printf "%s\t%s\n", s, l }
    ' "$backlog")"
    [ -n "$found" ] || ac_die "no single '## Queued' line for '$item' in $backlog"
    section="${found%%	*}"
    line="${found#*	}"
    [ "$section" = "Queued" ] \
      || ac_die "'$item' sits under '## $section', not '## Queued' - a crewmate's supervision scope is baked into its launch env and meta at spawn and cannot change afterwards, and Done history stays where it was made"
    case "$line" in
      *epic:*) ac_die "'$item' belongs to an epic - moving it would strand its dependents in a ledger the scheduler never reads" ;;
    esac
    awk -v id="$item" '
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { next }
      /blocked-by:/ {
        bb = $0; sub(/.*blocked-by:[ ]*/, "", bb); sub(/ - .*/, "", bb)
        n = split(bb, a, ",")
        for (i = 1; i <= n; i++) if (a[i] == id) exit 1
      }
    ' "$backlog" || ac_die "'$item' is named in another line's blocked-by: - moving it would strand that dependent"
    moving="$moving$line
"
    ids="${ids:+$ids,}$item"
  done

  arc="$(ac_records_backup domain-assign)"
  printf 'backup: %s\n' "$arc"
  printf '%s' "$moving" >"$backlog.moving.$$"
  awk 'NR == FNR { drop[$0] = 1; next } !($0 in drop)' "$backlog.moving.$$" "$backlog" >"$backlog.tmp.$$"
  mv "$backlog.tmp.$$" "$backlog"
  # Stamp the provenance token where the grammar already puts `epic:<id>` -
  # before the trailing `(repo: ...)` group. DATE-FREE on purpose: ac_doneline's
  # fallback takes the LAST date anywhere on the line when that group carries
  # none, so a timestamped token would silently become the row's date and verb.
  # APPEND at the END of `## Queued` - queue order is meaningful, and inserting
  # at the head would reprioritize fleet rows above the domain's own work.
  awk '{ if (sub(/ \(repo: [^()]*\)$/, "; assigned:crewchief&")) print; else print $0 "; assigned:crewchief" }' \
    "$backlog.moving.$$" >"$backlog.stamped.$$"
  awk -v f="$backlog.stamped.$$" '
    inq && /^## / { while ((getline l < f) > 0) print l; inq = 0 }
    { print }
    /^## Queued/ { inq = 1 }
    END { if (inq) while ((getline l < f) > 0) print l }
  ' "$dom_backlog" >"$dom_backlog.tmp.$$"
  mv "$dom_backlog.tmp.$$" "$dom_backlog"
  cat "$backlog.stamped.$$"
  rm -f "$backlog.moving.$$" "$backlog.stamped.$$"
  ac_status_append "$name" "assign: $ids"
  # LOUD on failure. Suppressing it left the chief believing its drain would
  # report the assignment when nothing had been published - the success line
  # below prints either way, so silence here is indistinguishable from a wake.
  ac_wake_publish "$(ac_state_dir)" "" domain "$name" "assign: $ids" >/dev/null \
    || ac_warn "assign: the durable wake could not be published - the rows MOVED, but your drain will not announce it; check $(ac_state_dir)/.wake-spool"
  printf 'assigned %s to crewdomain %s\n' "$ids" "$name"
}

cmd_unassign() {
  # cmd_unassign <name> <id>... - the mirror, so a retirement, a re-route and a
  # mis-assignment all have a safe reverse rather than a hand edit. The row
  # returns with the token STRIPPED: the fleet ledger is read by ac-curate.sh
  # and ac-learn.sh, so a returned row must be indistinguishable from one that
  # never left.
  local name="${1:-}" backlog dom_backlog item found line section arc
  shift 1 2>/dev/null || true
  [ -n "$name" ] && [ $# -gt 0 ] || ac_die "usage: ac-domain.sh unassign <name> <id>..."
  local idlist; idlist="$(domain_dedupe "backlog id" "$@")"
  set -f; set -- $idlist; set +f
  domain_require_name "$name"
  domain_require_ids "$@"
  [ -z "${AC_SCOPE:-}" ] \
    || ac_die "unassign is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=$AC_SCOPE) - a domainchief moves its own rows between sections, it never returns work to the fleet"
  dom_backlog="$(domain_backlog "$name")"
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || ac_die "no fleet backlog at $backlog"

  local moving="" ids=""
  for item in "$@"; do
    found="$(awk -v id="$item" '
      /^## / { sec = substr($0, 4); next }
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
      END { if (n == 1) printf "%s\t%s\n", s, l }
    ' "$dom_backlog")"
    [ -n "$found" ] || ac_die "no single line for '$item' in $dom_backlog"
    section="${found%%	*}"
    line="${found#*	}"
    [ "$section" = "Queued" ] \
      || ac_die "'$item' sits under '## $section' in the domain backlog, not '## Queued' - an in-flight row's crewmate scope is baked at spawn and cannot follow the line back"
    # An UNTOKENED row was never assigned, so there is nothing to reverse: moving
    # it to the fleet ledger would LAUNDER invented work into a legitimate row
    # and strip the very evidence that it was unauthorized. R7's mandatory
    # response is adopt-or-delete, and neither of those is this verb.
    domain_row_tokened "$line" \
      || ac_die "'$item' carries no assigned:crewchief provenance at its grammar position - it is an UNAUTHORIZED row, not work to reverse. Either ADOPT it (mint it in records/backlog.md, then assign it) or DELETE it from the domain backlog, and tell the family room either way."
    moving="$moving$line
"
    ids="${ids:+$ids,}$item"
  done

  arc="$(ac_records_backup domain-unassign)"
  printf 'backup: %s\n' "$arc"
  printf '%s' "$moving" >"$dom_backlog.moving.$$"
  awk 'NR == FNR { drop[$0] = 1; next } !($0 in drop)' "$dom_backlog.moving.$$" "$dom_backlog" >"$dom_backlog.tmp.$$"
  mv "$dom_backlog.tmp.$$" "$dom_backlog"
  # BRE: the paren is LITERAL and must NOT be backslash-escaped (an escaped one
  # opens a group). Positional on both arms, mirroring the audit predicate.
  sed -E -e 's/; assigned:crewchief( \(repo: [^()]*\))$/\1/' -e 's/; assigned:crewchief$//' \
    "$dom_backlog.moving.$$" >"$dom_backlog.stripped.$$"
  awk -v f="$dom_backlog.stripped.$$" '
    inq && /^## / { while ((getline l < f) > 0) print l; inq = 0 }
    { print }
    /^## Queued/ { inq = 1 }
    END { if (inq) while ((getline l < f) > 0) print l }
  ' "$backlog" >"$backlog.tmp.$$"
  mv "$backlog.tmp.$$" "$backlog"
  cat "$dom_backlog.stripped.$$"
  rm -f "$dom_backlog.moving.$$" "$dom_backlog.stripped.$$"
  ac_status_append "$name" "unassign: $ids"
  printf 'unassigned %s from crewdomain %s\n' "$ids" "$name"
}

cmd_audit() {
  # cmd_audit [<name>] - read-only; non-zero when any domain backlog carries a
  # row `assign` did not stamp. `list` calls it and the session-start digest
  # prints `list` unconditionally, so detection costs no new discipline.
  local name="${1:-}" out=""
  local n
  [ -z "$name" ] || domain_require_name "$name"
  if [ -n "$name" ]; then
    out="$(domain_unauthorized "$name")"
  else
    # Every package on disk, not every REGISTERED id. Retirement is a manual
    # records act, so a package whose line was removed still holds rows - the
    # ghost shape - and keying this walk on the registry would hide exactly the
    # state the audit exists to report.
    local d
    for d in "$(ac_home)"/crewdomains/*/records/backlog.md; do
      [ -f "$d" ] || continue
      n="${d%/records/backlog.md}"; n="${n##*/}"
      ac_domain_name_ok "$n" || continue
      out="$out$(domain_unauthorized "$n")
"
    done
    out="$(printf '%s' "$out" | grep -v '^$' || true)"
  fi
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | while read -r d i; do
    [ -n "$d" ] || continue
    printf 'UNAUTHORIZED %s %s\n' "$d" "$i"
  done
  return 1
}

cmd_list() {
  # cmd_list - the session-start digest block. ALWAYS exits 0 and renders even
  # on a corrupt ledger: the rule bin/ac-deputy.sh:48-50 states for its own
  # list, adopted here for the same reason - a digest block may never take
  # session start down.
  local reg records cls id charter scope reason n=0 invalid=0
  reg="$(ac_domain_registry)"
  if [ ! -f "$reg" ]; then
    printf 'ABSENT: %s - no crewdomains registered\n' "$REGISTRY_LABEL"
    return 0
  fi
  records="$(ac_domain_parse "$reg" | tr '\t' "$FS_US")"
  if [ -z "$records" ]; then
    printf 'EMPTY: %s present, 0 entries - no crewdomains registered\n' "$REGISTRY_LABEL"
    return 0
  fi
  while IFS="$FS_US" read -r cls id charter scope reason; do
    [ -n "$cls" ] || continue
    n=$((n + 1))
    if [ "$cls" = INVALID ]; then
      invalid=$((invalid + 1))
      printf 'INVALID\t%s\treason: %s\n' "$id" "$reason"
      continue
    fi
    local tally q i d flying nproj
    read -r q i d <<EOF
$(ac_domain_tally "$id")
EOF
    tally="queued $q, in flight $i, done $d"
    nproj="$(domain_view_names "$id" | grep -c . || true)"
    printf 'VALID\t%s\tprojects: %s\n' "$id" "$nproj"
    printf '\tcharter: %s\n' "$charter"
    if [ -n "$scope" ]; then
      printf '\tscope: %s\n' "$scope"
    else
      printf '\tscope: (unset - not routable until a scope: is added)\n'
    fi
    printf '\tbacklog: %s\n' "$tally"
    flying="$(domain_flying "$id")"
    [ -z "$flying" ] || printf '\tin flight: %s\n' "$flying"
    domain_unauthorized "$id" | while read -r _ row; do
      [ -n "$row" ] || continue
      printf '\tUNAUTHORIZED: %s - DELETE it from the domain backlog, or ADOPT it (delete it here, mint it in records/backlog.md, then assign)\n' "$row"
    done
  done <<EOF
$records
EOF
  # GHOST PACKAGES too. Rendering only REGISTERED entries hid the one shape the
  # audit was widened to catch: a package whose registry line was removed while
  # its rows remain. The digest is where detection happens, so a row invisible
  # here is a row nobody ever sees.
  local gd gn
  for gd in "$(ac_home)"/crewdomains/*/records/backlog.md; do
    [ -f "$gd" ] || continue
    gn="${gd%/records/backlog.md}"; gn="${gn##*/}"
    ac_domain_name_ok "$gn" || continue
    printf '%s\n' "$records" | grep -q "VALID${FS_US}${gn}${FS_US}" && continue
    printf 'UNREGISTERED\t%s\tpackage on disk with no VALID registry line - restore its line in %s, or unassign its rows and clean the package\n' \
      "$gn" "$REGISTRY_LABEL"
    domain_unauthorized "$gn" | while read -r _ row; do
      [ -n "$row" ] || continue
      printf '\tUNAUTHORIZED: %s\n' "$row"
    done
  done
  printf 'registered: %s (invalid %s)\n' "$n" "$invalid"
  return 0
}

domain_flying() {
  # domain_flying <name> - family ids whose chief meta carries domain=<name>.
  # Read from durable state, never from a session's environment: every process
  # other than the domainchief itself learns the binding this way.
  local name="$1" m out=""
  for m in "$(ac_state_dir)"/*-chief.meta; do
    [ -f "$m" ] || continue
    [ "$(ac_meta_get "$m" domain)" = "$name" ] || continue
    # AC-2.3 asks for the in-flight FAMILIES; the meta is named <family>-chief.
    m="${m##*/}"; m="${m%.meta}"; out="${out:+$out, }${m%-chief}"
  done
  printf '%s\n' "$out"
}

domain_validate_projects() {
  # domain_validate_projects <name> - check the project VIEW. Prints findings;
  # returns non-zero only on a REFUSAL, never on a warning.
  #
  # The per-entry invariant is ac_domain_view_entry's - ONE predicate shared
  # with ac-spawn.sh's pre-lease guard, so the membership rule the spawn
  # enforces and the rule validate reports are literally the same code and
  # cannot drift apart.
  local name="$1" dir e rc=0 cls
  dir="$(domain_pkg "$name")/projects"
  [ -d "$dir" ] || return 0
  for e in "$dir"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    cls="$(ac_domain_view_entry "$name" "${e##*/}")" || true
    case "$cls" in
      ok) ;;
      not-symlink)
        printf 'INVALID %s: projects/%s is not a symlink - a domain view LINKS the fleet clones, it never holds a copy\n' "$name" "${e##*/}"; rc=1; continue ;;
      dangling)
        printf 'INVALID %s: projects/%s dangles - it resolves to nothing\n' "$name" "${e##*/}"; rc=1; continue ;;
      outside*)
        printf 'INVALID %s: projects/%s resolves OUTSIDE the fleet clones (%s) - a view may only select from the fleet projects dir\n' "$name" "${e##*/}" "${cls#outside }"; rc=1; continue ;;
      mismatch*)
        printf 'INVALID %s: projects/%s resolves to %s, not to its OWN clone - a view entry must name the project it links, or it authorizes work on a repository the domain never selected\n' "$name" "${e##*/}" "${cls#mismatch }"; rc=1; continue ;;
      *)
        # FAIL CLOSED on a class this renderer does not know: a new class added
        # to the predicate must never fall through here as if it were `ok`.
        printf 'INVALID %s: projects/%s - unrecognised view state "%s"\n' "$name" "${e##*/}" "$cls"; rc=1; continue ;;
    esac
    case "${e##*/}" in
      *.yaml) ;;
      *) [ -e "$e.yaml" ] \
           || printf 'WARN %s: projects/%s has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal\n' "$name" "${e##*/}" ;;
    esac
  done

  # The DETAIL file is prose and is never a guard, but ONE part of it is
  # machine-readable: a `## <project-name>` heading per in-scope project
  # (captain ruling 2026-08-02). Comparing that heading set against the view
  # gives BOTH divergence directions, which a substring search over free prose
  # could never do - it can neither find a project named ONLY in the detail
  # file, nor tell a real mention from the name appearing inside a sentence.
  # Both directions WARN and neither refuses: prose may lag, the guard may not.
  local detail links headings n
  detail="$(domain_pkg "$name")/records/projects.md"
  [ -f "$detail" ] || return "$rc"
  # The other half of AC-1.6: a fleet DESCRIPTION copied in. Both halves are the
  # same boundary - attributes resolve from the fleet registry, and a second
  # copy here is the drift this file was designed not to have.
  local freg fdesc fname
  freg="$(ac_records_dir)/projects.md"
  if [ -f "$freg" ]; then
    while IFS= read -r fline; do
      case "$fline" in '- '*) ;; *) continue ;; esac
      fname="${fline#- }"; fname="${fname%% *}"
      # The registry grammar is `- <name> [<mode>] - <description> (added ...)`,
      # so the description starts after `] - `. Stripping to the first `- `
      # would eat the line's own bullet and yield the whole row.
      case "$fline" in *'] - '*) fdesc="${fline#*'] - '}" ;; *) continue ;; esac
      fdesc="$(printf '%s' "$fdesc" | sed 's/ *(added [^)]*)$//')"
      [ ${#fdesc} -ge 12 ] || continue
      grep -qF -- "$fdesc" "$detail" \
        && printf 'WARN %s: records/projects.md repeats the FLEET description of %s verbatim - the description resolves from records/projects.md alone, and a copy here is the drift this file exists to avoid\n' "$name" "$fname"
    done <"$freg"
  fi
  # A REAL token, not the placeholder. Fleet rows carry `[crew-ship]`,
  # `[direct-pr]`, `[local-only]`; searching for the literal `[mode]` caught the
  # spec's own notation and nothing an operator would ever actually paste.
  grep -qE '\[(mode|crew-ship|direct-pr|local-only)\]' "$detail" \
    && printf 'WARN %s: records/projects.md carries a delivery-mode token - delivery mode lives ONLY in the fleet records/projects.md, and a second copy is exactly the drift this file was designed not to have\n' "$name"
  links="$(domain_view_names "$name" | LC_ALL=C sort)"
  headings="$(awk '/^## / { print substr($0, 4) }' "$detail" | LC_ALL=C sort)"
  for n in $links; do
    printf '%s\n' "$headings" | grep -qxF -- "$n" \
      || printf 'WARN %s: projects/%s is in the view but has no "## %s" heading in records/projects.md - the detail prose has lagged the view\n' "$name" "$n" "$n"
  done
  for n in $headings; do
    printf '%s\n' "$links" | grep -qxF -- "$n" \
      || printf 'WARN %s: records/projects.md documents "## %s" but the view does not link it - the detail prose names a project this domain cannot work\n' "$name" "$n"
  done
  return "$rc"
}

cmd_validate() {
  # cmd_validate - the strict twin of `list`: non-zero on any INVALID line or
  # any invalid project view. It never reads records/crewdeputies.md.
  local reg rc=0 cls id reason
  reg="$(ac_domain_registry)"
  [ -f "$reg" ] || return 0
  while IFS="$FS_US" read -r cls id _ _ reason; do
    [ "$cls" = INVALID ] || continue
    printf 'INVALID %s: %s\n' "$id" "$reason"
    rc=1
  done <<EOF
$(ac_domain_parse "$reg" | tr '\t' "$FS_US")
EOF
  local n
  for n in $(domain_names); do
    domain_validate_projects "$n" || rc=1
  done
  return "$rc"
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  assign) shift; cmd_assign "$@" ;;
  unassign) shift; cmd_unassign "$@" ;;
  audit) shift; cmd_audit "$@" ;;
  list) cmd_list ;;
  validate) cmd_validate ;;
  *) ac_die "usage: ac-domain.sh <new|assign|unassign|audit|list|validate>" ;;
esac
