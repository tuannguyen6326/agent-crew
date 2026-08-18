#!/usr/bin/env bash
# ac-domain.sh - the CREWDOMAIN verb layer: create a domain package and route
# work to it by TOKEN.
#
# Usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>'
#                                (--projects <p1,p2,...> | --no-projects)
#        ac-domain.sh assign <name> <backlog-id>...     (stamp domain:<name>)
#        ac-domain.sh unassign <name> <backlog-id>...   (strip the token)
#        ac-domain.sh queue <name> [--ids]              (the domain's slice)
#        ac-domain.sh list | validate | retire <name>
#
# A crewdomain is durable STATE inside this fleet - a KNOWLEDGE package plus
# one routing line - with no home, no session, no liveness and no ledger of
# its own (crewdomain-token refactor, captain-ordered 2026-08-18). Work
# reaches it when the crewchief STAMPS a fleet backlog row with the
# `domain:<name>` token (grammar owner: AC_DONELINE_AWK's f["domain"] -
# position-pinned at the slot the retired assigned:crewchief defined); work
# happens when the crewchief promotes a DOMAINCHIEF, an ordinary roomchief
# whose domain binding is derived from that token. The row NEVER leaves
# records/backlog.md: ac-ready.sh keeps scheduling it, blocked-by edges stay
# resolvable, epic rollups keep counting it - which is why the old epic
# refusal is gone (an epic row is assignable; live fleet evidence showed
# epics ARE the domain workload). The domainchief never edits any
# ledger - the crewchief moves rows at the ordinary checkpoints (promote ->
# In flight, handback -> Done), the roomchief precedent made total. A Done
# row KEEPS its token as durable per-domain provenance (date-free, so
# ac_doneline's date/verb stay inert).
#
# The old per-domain records/backlog.md is GONE, and with it the whole
# UNAUTHORIZED defect class: there is no second ledger to mint a row into.
# What remains detectable is the ORPHAN-TOKEN (a token naming no VALID
# registry entry - `list` prints it, promote refuses it) and the malformed
# token (f["domain_malformed"], flagged by `validate`, fail-visible).
#
# COEXISTENCE with crewdeputy, which this script never touches. The two
# features share no registry, no root, no script and no verb - crewdeputy
# keeps bin/ac-deputy.sh, records/crewdeputies.md, $AC_HOME/crewdeputies/
# <name>/ and every verb it has. Choose by what the work needs: ISOLATION
# (separate clones, credentials, budget, delegable to another operator) -> a
# crewdeputy or a full fleet; a KNOWLEDGE slice + routed slice of the fleet
# ledger over the fleet's own clones -> a crewdomain. The one place the two
# meet is the NAME, and `new` refuses a collision rather than leaving the
# chief to disambiguate it forever.
#
# The registry GRAMMAR is owned by ac-lib.sh's `crewdomain routing table`
# block; the TOKEN grammar by AC_DONELINE_AWK; this script owns the verbs.
#
# --- new: the package, whole or nothing ----------------------------------------
#
# AUTHORITATIVE for the package layout. THREE members at
# $AC_HOME/crewdomains/<name>/:
#
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
  # without this a scoped session could run the verb directly and STAMP a
  # fleet row domain:<name> itself - forged authorization, and chief-only-add
  # defeated by its own token.
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


domain_row_of() {
  # domain_row_of <id> <ledger> - "<section>\t<line>" for the SINGLE row with
  # this id, empty when absent or ambiguous. The one row-finder every verb
  # shares (assign/unassign had private twins under the old two-file design).
  awk -v id="$1" '
    /^## / { sec = substr($0, 4); next }
    $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
    END { if (n == 1) printf "%s\t%s\n", s, l }
  ' "$2"
}

domain_of_row() {
  # domain_of_row <line> - the row's authoritative domain token, "" when none.
  # ONE parser: AC_DONELINE_AWK's f["domain"], never a private regex twin (the
  # measured two-parser lesson the retired domain_row_tokened carried).
  printf '%s\n' "$1" | awk "$AC_DONELINE_AWK"'
    { ac_doneline($0, o); print o["domain"] }
  '
}

domain_stamp_line() {
  # domain_stamp_line <line> <name> - the line with `; domain:<name>` at its
  # grammar position: before a trailing (repo: ...) group, else end-of-line.
  # DATE-FREE on purpose: ac_doneline's fallback takes the LAST date anywhere
  # on the line, so a timestamped token would become the row's date and verb.
  printf '%s\n' "$1" | awk -v n="$2" \
    '{ if (sub(/ \(repo: [^()]*\)$/, "; domain:" n "&")) print; else print $0 "; domain:" n }'
}

domain_strip_line() {
  # domain_strip_line <line> <name> - the exact mirror of the stamp, both arms.
  printf '%s\n' "$1" | sed -E \
    -e "s/; domain:$2( \(repo: [^()]*\))\$/\1/" \
    -e "s/; domain:$2\$//"
}

domain_rewrite_row() {
  # domain_rewrite_row <ledger> <old-line> <new-line> - replace ONE exact line
  # in place (tmp+mv, the ledger's single-writer property is the lock). The
  # row keeps its section and its queue position - nothing moves, which is
  # the whole point of the token design.
  awk -v old="$2" -v new="$3" '
    !done && $0 == old { print new; done = 1; next }
    { print }
    END { exit done ? 0 : 1 }
  ' "$1" >"$1.tmp.$$" || { rm -f "$1.tmp.$$"; return 1; }
  mv "$1.tmp.$$" "$1"
}

domain_names() {
  # domain_names - every VALID registered id, in file order.
  ac_domain_parse | awk -F'\t' '$1 == "VALID" { print $2 }'
}

cmd_assign() {
  # cmd_assign <name> <backlog-id>... - STAMP the named fleet `## Queued` rows
  # with `domain:<name>`, in place. Nothing moves: the row keeps its section,
  # its queue position, its blocked-by edges and its epic membership - so the
  # old epic refusal and the dependent-stranding check have no ground and are
  # gone. Pass 1 judges EVERY id before pass 2 writes anything; any failure
  # aborts the WHOLE assign. Idempotent per id: an already-stamped row is a
  # printed no-op, never an error; a row stamped for ANOTHER domain refuses
  # the whole command (unassign there first - never a silent steal).
  local name="${1:-}" backlog item found line section cur tab captain_req=""
  tab="$(printf '\t')"
  shift 1 2>/dev/null || true
  # --captain-requested '<the captain's words>' unlocks stamping an IN FLIGHT
  # row (design open question 1, captain-approved 2026-08-18): a stamp changes
  # nothing in the flying crewmate's env - the baked-scope refusal is policy,
  # not physics - but adopting live work into a domain is the captain's call,
  # so the authority is REQUIRED and recorded on the status line. Done rows
  # stay refused with or without it: history keeps the provenance it was made
  # with.
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --captain-requested)
        captain_req="${2:-}"
        [ -n "$captain_req" ] || ac_die "--captain-requested needs the captain's words (the authority is the record)"
        shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  set -- ${rest+"${rest[@]}"}
  [ -n "$name" ] && [ $# -gt 0 ] || ac_die "usage: ac-domain.sh assign <name> <backlog-id>... [--captain-requested '<words>']"
  domain_chief_only assign
  domain_require_name "$name"
  local idlist; idlist="$(domain_dedupe "backlog id" "$@")"
  set -f; set -- $idlist; set +f
  domain_require_ids "$@"
  domain_valid_scope "$name" >/dev/null
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || ac_die "no fleet backlog at $backlog"

  # Pass 1: judge every id before any write.
  local todo="" already="" ids=""
  for item in "$@"; do
    found="$(domain_row_of "$item" "$backlog")"
    [ -n "$found" ] || ac_die "no single row for '$item' in $backlog"
    section="${found%%"$tab"*}"
    line="${found#*"$tab"}"
    cur="$(domain_of_row "$line")"
    if [ "$cur" = "$name" ]; then
      already="${already:+$already,}$item"
      continue
    fi
    [ -z "$cur" ] \
      || ac_die "'$item' is already assigned to crewdomain '$cur' - unassign it there first; a silent steal is how one row ends up claimed twice"
    case "$section" in
      Queued) ;;
      "In flight")
        [ -n "$captain_req" ] \
          || ac_die "'$item' sits under '## In flight' - adopting live work into a domain is the captain's call: re-run with --captain-requested '<the captain's words>' (a stamp changes nothing in the flying crewmate's env, but the authority must be on record)" ;;
      *)
        ac_die "'$item' sits under '## $section' - Done history keeps the provenance it was made with" ;;
    esac
    todo="${todo:+$todo }$item"
    ids="${ids:+$ids,}$item"
  done
  [ -z "$already" ] || printf 'already assigned to %s: %s\n' "$name" "$already"
  [ -n "$ids" ] || { printf 'nothing to do\n'; return 0; }

  local arc; arc="$(ac_records_backup domain-assign)"
  printf 'backup: %s\n' "$arc"
  # Pass 2: re-read each row at write time (main shell - ac_die aborts for
  # real) and rewrite it in place; the exact-line match in domain_rewrite_row
  # catches a ledger that changed between the passes.
  local stamped
  for item in $todo; do
    found="$(domain_row_of "$item" "$backlog")"
    [ -n "$found" ] || ac_die "the row for '$item' vanished mid-assign - the ledger changed under this command; re-run"
    line="${found#*"$tab"}"
    stamped="$(domain_stamp_line "$line" "$name")"
    domain_rewrite_row "$backlog" "$line" "$stamped" \
      || ac_die "could not rewrite the row for '$item' - the ledger changed under this command; re-run"
    printf '%s\n' "$stamped"
  done
  ac_status_append "$name" "assign: $ids${captain_req:+ [captain-requested: $captain_req]}"
  # LOUD on failure. Suppressing it left the chief believing its drain would
  # report the assignment when nothing had been published - the success line
  # below prints either way, so silence here is indistinguishable from a wake.
  ac_wake_publish "$(ac_state_dir)" "" domain "$name" "assign: $ids" >/dev/null \
    || ac_warn "assign: the durable wake could not be published - the rows are STAMPED, but your drain will not announce it; check $(ac_state_dir)/.wake-spool"
  printf 'assigned %s to crewdomain %s\n' "$ids" "$name"
}

cmd_unassign() {
  # cmd_unassign <name> <id>... - strip the token in place: the safe reverse
  # for a re-route or a mis-assignment. Queued rows only - an In flight row's
  # crewmate scope is baked at spawn, and a Done row's token is history (the
  # per-domain tally reads it; retiring a domain only requires its OPEN rows
  # unassigned). A row not carrying `domain:<name>` at position is simply not
  # assigned here - there is no UNAUTHORIZED third state anymore.
  local name="${1:-}" backlog item found line section cur tab
  tab="$(printf '\t')"
  shift 1 2>/dev/null || true
  [ -n "$name" ] && [ $# -gt 0 ] || ac_die "usage: ac-domain.sh unassign <name> <id>..."
  domain_chief_only unassign
  domain_require_name "$name"
  local idlist; idlist="$(domain_dedupe "backlog id" "$@")"
  set -f; set -- $idlist; set +f
  domain_require_ids "$@"
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || ac_die "no fleet backlog at $backlog"

  local todo="" ids=""
  for item in "$@"; do
    found="$(domain_row_of "$item" "$backlog")"
    [ -n "$found" ] || ac_die "no single row for '$item' in $backlog"
    section="${found%%"$tab"*}"
    line="${found#*"$tab"}"
    cur="$(domain_of_row "$line")"
    [ "$cur" = "$name" ] \
      || ac_die "'$item' carries no domain:$name token at its grammar position${cur:+ (it is assigned to '$cur')} - nothing to reverse"
    [ "$section" = "Queued" ] \
      || ac_die "'$item' sits under '## $section', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance"
    todo="${todo:+$todo }$item"
    ids="${ids:+$ids,}$item"
  done
  [ -n "$ids" ] || { printf 'nothing to do\n'; return 0; }

  local arc; arc="$(ac_records_backup domain-unassign)"
  printf 'backup: %s\n' "$arc"
  local stripped
  for item in $todo; do
    found="$(domain_row_of "$item" "$backlog")"
    [ -n "$found" ] || ac_die "the row for '$item' vanished mid-unassign - the ledger changed under this command; re-run"
    line="${found#*"$tab"}"
    stripped="$(domain_strip_line "$line" "$name")"
    domain_rewrite_row "$backlog" "$line" "$stripped" \
      || ac_die "could not rewrite the row for '$item' - the ledger changed under this command; re-run"
    printf '%s\n' "$stripped"
  done
  ac_status_append "$name" "unassign: $ids"
  printf 'unassigned %s from crewdomain %s\n' "$ids" "$name"
}

cmd_queue() {
  # cmd_queue <name> [--ids] - the domain's SLICE of the fleet ledger,
  # read-only and callable from a scoped session (a domainchief reads its
  # work here; it never reads a ledger of its own because there is none).
  # Prints tokened rows grouped under their section headers, plus rows
  # INHERITED via an epic: a story whose own row carries no domain token
  # belongs to its epic row's domain (annotated "(via epic:<e>)"). --ids
  # prints bare ids for piping. Always exits 0 on an empty slice.
  local name="${1:-}" mode="${2:-}" backlog
  [ -n "$name" ] || ac_die "usage: ac-domain.sh queue <name> [--ids]"
  domain_require_name "$name"
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || { printf 'no fleet backlog\n'; return 0; }
  awk "$AC_DONELINE_AWK"'
    # Pass 1 (NR==FNR): id -> authoritative domain, for epic inheritance.
    NR == FNR { if (/^- \[/) { ac_doneline($0, o); if (o["domain"] != "") dom[o["id"]] = o["domain"] } next }
    /^## /   { sec = $0; secshown = 0; next }
    /^- \[/ {
      ac_doneline($0, o)
      via = ""
      if (o["domain"] == n) { }
      else if (o["domain"] == "" && o["epic"] != "" && dom[o["epic"]] == n) via = " (via epic:" o["epic"] ")"
      else next
      if (ids) { print o["id"]; next }
      if (!secshown && sec != "") { print sec; secshown = 1 }
      print $0 via
    }
  ' n="$name" ids="$([ "$mode" = --ids ] && printf 1 || printf 0)" "$backlog" "$backlog"
  return 0
}

cmd_retire() {
  # cmd_retire <name> - remove the ONE registry line, fail-closed. The old
  # design could not mechanize this (it meant coordinating two files); one
  # ledger makes it a checkable one-line act. Refuses while any OPEN (non-
  # Done) row carries the token, while any chief meta flies domain=<name>,
  # or while the name is not VALID in the registry. The package is NEVER
  # deleted - it is the domain'"'"'s knowledge, and a later `new` with the same
  # name may re-adopt it.
  local name="${1:-}" backlog reg open flying
  [ -n "$name" ] || ac_die "usage: ac-domain.sh retire <name>"
  domain_chief_only retire
  domain_require_name "$name"
  reg="$(ac_domain_registry)"
  ac_domain_parse "$reg" 2>/dev/null | awk -F'\t' -v n="$name" '$1 == "VALID" && $2 == n { found = 1 } END { exit !found }' \
    || ac_die "no VALID crewdomain '$name' in $REGISTRY_LABEL - nothing to retire"
  backlog="$(ac_records_dir)/backlog.md"
  if [ -f "$backlog" ]; then
    open="$(awk "$AC_DONELINE_AWK"'
      /^## Done/ { done = 1 } /^## / && !/^## Done/ { done = 0 }
      /^- \[/ && !done { ac_doneline($0, o); if (o["domain"] == n) print o["id"] }
    ' n="$name" "$backlog")"
    [ -z "$open" ] \
      || ac_die "crewdomain '$name' still holds OPEN tokened rows - unassign them first:
$open"
  fi
  flying="$(domain_flying "$name")"
  [ -z "$flying" ] \
    || ac_die "crewdomain '$name' has a domainchief in flight ($flying) - demote it first"
  local arc; arc="$(ac_records_backup domain-retire)"
  printf 'backup: %s\n' "$arc"
  awk -v n="$name" '
    substr($0, 1, 2) == "- " {
      line = substr($0, 3); sub(/ +- .*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == n) next
    }
    { print }
  ' "$reg" >"$reg.tmp.$$"
  mv "$reg.tmp.$$" "$reg"
  ac_status_append "$name" "retire"
  printf 'retired crewdomain %s - registry line removed; the package at crewdomains/%s is kept (knowledge is never deleted by tooling)\n' "$name" "$name"
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
  done <<EOF
$records
EOF
  # RETIRED-BUT-PRESENT packages (knowledge kept, line gone) and ORPHAN
  # TOKENS (a ledger row naming a domain with no VALID line - the ghost shape
  # the promote also refuses). The digest is where detection happens.
  local gd gn
  for gd in "$(ac_home)"/crewdomains/*/; do
    [ -d "$gd" ] || continue
    gn="${gd%/}"; gn="${gn##*/}"
    ac_domain_name_ok "$gn" || continue
    printf '%s\n' "$records" | grep -q "VALID${FS_US}${gn}${FS_US}" && continue
    printf 'UNREGISTERED\t%s\tpackage on disk with no VALID registry line - re-adopt it with `new`, restore its line in %s, or leave it as kept knowledge\n' \
      "$gn" "$REGISTRY_LABEL"
  done
  local ob
  ob="$(ac_records_dir)/backlog.md"
  if [ -f "$ob" ]; then
    awk "$AC_DONELINE_AWK"'
      /^- \[/ { ac_doneline($0, o); if (o["domain"] != "") print o["domain"], o["id"] }
    ' "$ob" | while read -r gn gi; do
      [ -n "$gn" ] || continue
      printf '%s\n' "$records" | grep -q "VALID${FS_US}${gn}${FS_US}" && continue
      printf 'ORPHAN-TOKEN\t%s\t%s - the row names a domain with no VALID registry line (unassign it, or re-`new` the domain)\n' "$gn" "$gi"
    done
  fi
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
  #. Comparing that heading set against the view
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
  # Token discipline over the ONE ledger (crewdomain-token): a malformed
  # domain:-shaped run, an orphan token, or a story whose own token disagrees
  # with its epic row'"'"'s are each a refusal - fail-visible, like the doneline
  # hold/blockers malformed fields they ride on.
  local vb; vb="$(ac_records_dir)/backlog.md"
  if [ -f "$vb" ]; then
    local tok
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        MALFORMED*) printf 'INVALID token: %s\n' "${tok#MALFORMED }"; rc=1 ;;
        DISAGREE*)  printf 'INVALID token: %s\n' "${tok#DISAGREE }"; rc=1 ;;
        ORPHAN*)
          printf '%s\n' "$(domain_names)" | grep -qxF -- "$(printf '%s' "${tok#ORPHAN }" | awk "{print \$1}")" \
            || { printf 'INVALID token: orphan domain token %s\n' "${tok#ORPHAN }"; rc=1; } ;;
      esac
    done <<VEOF
$(awk "$AC_DONELINE_AWK"'
  NR == FNR { if (/^- \[/) { ac_doneline($0, o); if (o["domain"] != "") dom[o["id"]] = o["domain"] } next }
  /^- \[/ {
    ac_doneline($0, o)
    if (o["domain_malformed"] == "1")
      printf "MALFORMED %s carries a domain:-shaped run off its grammar position (backtick-quote a mention, or re-stamp with assign)\n", o["id"]
    if (o["domain"] != "")
      printf "ORPHAN %s %s\n", o["domain"], o["id"]
    if (o["domain"] != "" && o["epic"] != "" && dom[o["epic"]] != "" && dom[o["epic"]] != o["domain"])
      printf "DISAGREE story %s carries domain:%s but its epic %s carries domain:%s - one family, one domain\n", o["id"], o["domain"], o["epic"], dom[o["epic"]]
  }
' "$vb" "$vb")
VEOF
  fi
  return "$rc"
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  assign) shift; cmd_assign "$@" ;;
  unassign) shift; cmd_unassign "$@" ;;
  queue) shift; cmd_queue "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  list) cmd_list ;;
  validate) cmd_validate ;;
  *) ac_die "usage: ac-domain.sh <new|assign|unassign|queue|retire|list|validate>" ;;
esac
