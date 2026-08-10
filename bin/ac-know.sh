#!/usr/bin/env bash
# ac-know.sh - the per-project REPO-KNOWLEDGE record: what earlier families
# verified about a codebase, durable in the FLEET HOME and re-checkable.
#
# Usage:
#   ac-know.sh add    --home <abs> --repo <dir> --family <fam>
#                     (--src-file <path>:<line> | --src-cmd <command>)
#                     [--at <ref>] --fact <text>
#                     [--new | --supersede <text-quoted-from-the-entry>]
#   ac-know.sh retire --home <abs> --repo <dir> --family <fam>
#                     (--src-file <path>:<line> | --src-cmd <command>) [--at <ref>]
#                     --quote <text-quoted-from-the-entry> [--by <family>] --why <text>
#   ac-know.sh cite   --home <abs> --repo <dir>
#                     --quote <text-quoted-from-the-entry> [--by <family>]
#   ac-know.sh recall <question words>... --home <abs> --repo <dir>
#                     [--max <n>] [--bytes <n>]
#   ac-know.sh verify --home <abs> --repo <dir>   (leaves a digest stamp)
#   ac-know.sh scope-proposal --home <abs> --repo <dir> --family <fam>
#                     (--src-file <path>:<line> | --src-cmd <command>) [--at <ref>]
#                     ( --scope <name> --apps <a>,<b> [--replace]
#                     | --retire --scope <name> --why <text> ) [--id <id>]
#   ac-know.sh scope-install <id> --home <abs> --repo <dir>   (CHIEF)
#
# WHY IT EXISTS: a task's repo knowledge dies with its report.md, so the next
# family re-derives it - or contradicts it. This record is the durable place
# for it, and every entry carries PROVENANCE and a FRESHNESS MARKER because a
# stale fact stated confidently is worse than no fact.
#
# THE RECORD: $AC_HOME/records/repo-knowledge/<name>.md, derived by
# ac_knowledge_file (ac-lib.sh, which owns the key argument). One entry, one
# PHYSICAL line, four fields:
#
#   - <type> <subject> | src: <tagged provenance> | at: <sha> <date> | by: <family>
#
# Everything above the `## Superseded` marker is LIVE; everything below it is
# history and is never read by any consumer. Two entry types and no more:
#   fact <free text>            human-consumed repo knowledge; any crewmate
#                               may write one, directly, through `add --fact`.
#   scope <name> = <app>, <app> the CLOSED LIST governing qa profile
#                               resolution. `add` has NO --scope path at all.
#
# RETIRING A FACT: `add` only appends - there is no in-place edit verb, and
# never will be. Correcting a false fact is `retire` then `add`: two separate
# locked writes, so a reader sees NO claim on the subject between them, which
# is safe (a STALE claim is not). `retire` is crewmate-tier, same as `add` -
# NOT a draft/chief-install two-step like the scope map, because a false fact
# staying live while a proposal waits is the defect this verb exists to close.
# It addresses its target by a PHRASE QUOTED from the entry's own text,
# optionally narrowed by the entry's own `by:` family when the phrase alone is
# ambiguous - NEVER by line number or position. This record has no stable
# per-entry identity: every retire, this verb's or the sanctioned
# `scope-proposal --replace`/`--retire`, renumbers every line below the one it
# moves. For the same reason `add --fact` refuses a citation that points AT
# THIS RECORD by physical line (`repo-knowledge:<n>`, or a
# `.../repo-knowledge/<name>.md:<n>` pointer) - an ordinary code citation such
# as `bin/ac-tree.sh:405` is unaffected; that is the record's normal
# provenance shape and the whole point of `--src-file`.
#
# HOW THE PATH TRAVELS: not the environment. Crewmate panes carry no AC_HOME
# (bin/ac-pane-agent.sh states the contract - a homeless caller is handed a
# fleet NAME, never a path), so the actor that HAS AC_HOME bakes the whole
# command line into the brief and the crewmate runs it VERBATIM. The ladder is
# ac_home_resolve's, shared with ac-qa.sh THROUGH RUNG 2: --home > $AC_HOME
# tested directly > this checkout's own home. THAT THIRD RUNG IS GONE, and its
# removal is the point: it was the LAST silent path by which the distro
# checkout became a fleet home, it survived @bf8f656 only because it called
# ac_root directly rather than through ac_home, and the doctrine that justified
# it - running a harness in this directory IS the installation - is the one
# @bf8f656 withdrew from six user-facing places. The code had outlived its own
# justification.
#
# It also served no legitimate caller, which is what settled it rather than a
# preference for symmetry: a crewmate pane carries no AC_HOME BY DESIGN, so
# bin/ac-brief.sh already bakes a `--home`-carrying command line into every
# brief for exactly this verb (ac-brief.sh:256-257, whose own comment says the
# crewmate's ac-know.sh "would resolve a [wrong home]"). The rung therefore
# caught only calls that had lost their --home - and "caught" them by writing
# into whatever checkout owned the running bin/, which in a leased worktree is
# discarded on return. A refusal the caller can read beats a record that
# vanishes.
#
# So an unresolved ladder now REFUSES here and names both fixes. This process
# EXPORTS the resolved home, so every lib call downstream is right unchanged -
# one decision point per process, not one per call site.
#
# ac-qa.sh KEEPS ITS OWN THIRD RUNG, and the asymmetry is deliberate rather
# than an unfinished sweep: that script has a real homeless production path
# this one does not - a pane running `start --store <baked-absolute>`, where
# the actor holding AC_HOME baked the store and the pane genuinely cannot
# derive one (tests/ac-qa.test.sh pins it). Removing the rung there is a
# DESIGN question - what a run resolves its project config against when no
# home is named - not the mechanical deletion it is here, and it stays queued
# rather than guessed at.
#
# THE FALSE-FRESH CLASS (authoritative - every other mention points HERE): an
# entry is a false-FRESH generator whenever THE RECORDED `at` IS NOT THE STATE
# THE AUTHOR OBSERVED. Doors, and how each is closed:
#   A  dirty worktree      the evidence was never in any commit
#   B  clean tree, wrong   `--at` names a commit the tree does not match
#   G  moving symbolic ref `--at main` binds today and re-points tomorrow
#   E  abbreviated sha     a rendering, not an identity
#   C  what the author LOOKED at - observe dirty, `git stash`, then add:
#      the binding passes honestly and the entry records content that no
#      longer exists. UNCLOSABLE; no mechanism can know what a human read.
#      `verify` re-checking rather than trusting the write is the compensating
#      control, which is why it is a verb and not an afterthought.
#   U  UNTRACKED files under a `cmd:` provenance - ACCEPTED AND OPEN, not
#      closed. `git diff` does not report untracked paths, so a command whose
#      output counted one binds successfully to a commit that never held it,
#      and two contradictory facts can bind to the same sha. This is a
#      RECORDED, argued residual of the approved design, not an oversight:
#      untracked build artifacts are ubiquitous in a crew worktree and
#      widening the check would refuse nearly every real invocation. It is
#      named here because this block claims to be the single authority on the
#      class, and an authority missing a clause is how a reader concludes
#      door A is fully closed for `cmd:` when it is not. Do NOT close it here.
#   N  no worktree copy, AND <at> is not in this branch's own history
#      (ship-config-and-know-citation-blind-spots) - `file:` only, an app
#      tree that lives ONLY on an integration branch this clone never checked
#      out. `git diff <at> -- <path>` against a path absent from disk always
#      reports "differs" (nothing to match), which is a FALSE positive for
#      door A/B: there is no local edit to be dirty, and no worktree state to
#      be wrong about, because there is no worktree state at all. CLOSED for
#      exactly this door: skip the worktree diff and trust validate_src_file's
#      cat-file proof that the blob is real and addressable at `<at>` (already
#      run before this) ONLY when `<at>` is not an ancestor of HEAD - if it
#      IS an ancestor, the path once existed on THIS branch and was deleted
#      since, which is real staleness (door A/B), not a structural miss, and
#      still falls through to the ordinary diff and stays refused. This
#      extends door C's existing trust boundary one case further, not past
#      it - the tool has never verified `--fact` TEXT against cited CONTENT,
#      only that the citation is followable and (when a worktree copy exists)
#      unstale; a path with no worktree copy on an unrelated branch carries
#      the identical residual, no new one. A path that DOES exist on disk
#      (same branch, or a same-named file on both) is unaffected - it still
#      gets the full door A/B/G/E diff below.
# B, G and E collapse into ONE rule: resolve `--at` to a full 40-char sha and
# bind with `git diff --quiet <at>` - per-path for `file:` (the fact cites one
# file, so bind exactly that file), NO pathspec for `cmd:` (a command's output
# can depend on any part of the tree). Never `git status` in any form: it is
# HEAD-relative and proves nothing about <at>. Exit-status discipline is
# load-bearing - 0 proceeds, 1 differs, ANYTHING ABOVE 1 IS AN ERROR AND
# REFUSES, so an unreadable tree fails closed instead of reading as clean.
#
# ONE ENTRY, ONE LINE - MECHANICALLY. Every free-form field is validated
# single-line (no newline, no CR) and `|`-free, and --family against the
# canonical id grammar. This is not robustness dressing: one newline in
# --fact composes a SECOND physical line that forges a `scope` entry under
# another family's name, defeating the read-side integrity rules, the landing
# flag's `by:` grep and the section split at once. REJECT, never escape - an
# unescaping step in every reader is the same forgery with more code, and one
# reader forgetting it is all it takes. The invariant bought: this script's
# own printf is the ONLY source of physical lines in the record.
# The boundary, honestly: this binds what the WRITER can produce. A human
# hand-editing the record can still write anything; that is why the record
# lives in the fleet home rather than the repo.
#
# Serialization: every write is a read-modify-write, so it takes the record's
# own lock for the whole of it (the cmd_config_install idiom) and lands with
# tmp+mv. The lock's own non-atomic stale reclaim is inherited, not closed here
# (ac-lib.sh's lock block documents it).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
# ac_config_sha256 is the ONE owner of "stable content identity" for a
# proposal base; a second hasher here is exactly the hand-synced duplicate
# that library exists to have retired.
. "$(dirname "$0")/ac-pipeline-lib.sh"
ac_require git

usage() {
  # Printed from the header's own Usage block, by PATTERN: a hardcoded line
  # range silently drifts the moment a verb is added above it.
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- field validation ----------------------------------------------------------

reject() { ac_die "entry rejected: $*"; }

assert_single_line() {
  # assert_single_line <field-name> <value> - the one-entry-one-line invariant,
  # enforced per free-form field (see the header block).
  local name="$1" v="$2"
  case "$v" in
    *$'\n'*|*$'\r'*) reject "$name must be a single line (no newline or carriage return)" ;;
  esac
  case "$v" in
    *"|"*) reject "'|' is the field separator, so it cannot appear in $name" ;;
  esac
}

assert_no_line_pointer() {
  # assert_no_line_pointer <fact-text> - refuse a --fact that cites THIS
  # record by physical line number (see the header's RETIRING A FACT block):
  # the record has no stable per-entry identity, so a `repo-knowledge:<n>` or
  # a `.../repo-knowledge/<name>.md:<n>` pointer is misdirected by the very
  # next retire. An ordinary code citation such as `bin/ac-tree.sh:405` names
  # no repo-knowledge path and is unaffected - that is the record's normal
  # provenance shape and the whole point of `--src-file`.
  local fact="$1"
  case "$fact" in
    *repo-knowledge:[0-9]*|*repo-knowledge/*.md:[0-9]*)
      reject "--fact cites the repo-knowledge record by line number, which has no stable identity to point at (quote the entry's own text instead): $fact" ;;
  esac
}

# --- the record file -----------------------------------------------------------
#
# Read as three parts and rewritten from them on every write: the boilerplate
# is GENERATED, the entry lines are carried byte-identical. That is what makes
# `--replace`/`--retire` a MOVE between sections rather than a rewrite, and it
# keeps the layout deterministic no matter which verb last touched the file.

record_live() { awk '/^## Superseded/ { exit } /^- /' "$1"; }
record_superseded() { awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$1"; }

# shellcheck disable=SC2016  # the boilerplate below is MARKDOWN: backticks are
# code spans, not command substitution.
record_render() {
  # record_render <name> <live-file> <superseded-file> - the whole record on
  # stdout. Used both to WRITE the file and to compose a proposal's draft, so
  # a draft and its install can never render differently.
  local name="$1" live="$2" sup="$3"
  printf '# Repo knowledge: %s\n\n' "$name"
  printf '<!-- One entry per line. Grammar owner: bin/ac-know.sh. Write with `ac-know.sh add`; retire with `ac-know.sh retire`; record a read with `ac-know.sh cite` - it bumps the entry `heat:` usage counter in place, the one sanctioned in-place field. Never edit a line by hand; correct a fact by retire then add. -->\n\n'
  cat "$live"
  printf '\n## Superseded\n\n'
  printf '<!-- Moved here byte-identical by `ac-know.sh retire` / `scope-proposal --replace` / `--retire`. Never read. -->\n\n'
  cat "$sup"
}

record_write() {
  # record_write <record> <name> <live-file> <superseded-file> - atomic rewrite.
  local rec="$1" name="$2" live="$3" sup="$4" tmp
  mkdir -p "$(dirname "$rec")"
  tmp="$rec.tmp.$$"
  record_render "$name" "$live" "$sup" >"$tmp"
  mv "$tmp" "$rec"
}

# --- provenance ----------------------------------------------------------------

resolve_at() {
  # resolve_at <repo> <ref> - the FULL 40-char sha, or refuse. Doors G and E of
  # the false-FRESH class in one line: a branch name re-points and an
  # abbreviation is a repo-and-time-dependent rendering, so neither may survive
  # into the record.
  local repo="$1" ref="$2" sha
  sha="$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null)" \
    || reject "--at '$ref' does not resolve to a commit in this repo"
  printf '%s\n' "$sha"
}

assert_bound() {
  # assert_bound <repo> <at> <tag> <value> - the WRITE-TIME BINDING (header).
  # ONE primitive for both tags; they differ only by pathspec.
  local repo="$1" at="$2" tag="$3" value="$4" path rc=0
  if [ "$tag" = file ]; then
    path="${value%:*}"
    # Door N (header): no worktree copy, AND <at> is not even in this branch's
    # own history - an app tree that lives only on an integration branch, not
    # a file this branch once had and has since deleted (that case DOES fall
    # through to the ordinary diff below and stays refused, unchanged: <at>
    # would be an ancestor of HEAD there, so the absence is real staleness,
    # not a structural miss). Trust validate_src_file's already-run cat-file
    # proof instead of diffing a path with nothing local to compare against.
    if [ ! -e "$repo/$path" ] \
      && ! git -C "$repo" merge-base --is-ancestor "$at" HEAD 2>/dev/null; then
      return 0
    fi
    git -C "$repo" diff --quiet "$at" -- "$path" || rc=$?
    [ "$rc" -le 1 ] || reject "cannot compare $path against $at (git diff exited $rc) - failing closed; an unreadable tree is not evidence of an unchanged one"
    [ "$rc" -eq 0 ] || reject "$path differs between the worktree and ${at:0:12} - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw"
  else
    git -C "$repo" diff --quiet "$at" || rc=$?
    [ "$rc" -le 1 ] || reject "cannot compare the tracked tree against $at (git diff exited $rc) - failing closed; an unreadable tree is not evidence of an unchanged one"
    [ "$rc" -eq 0 ] || reject "the tracked tree differs from $at, so a cmd: provenance cannot be bound to it. Check out that commit with a clean tree, or cite the specific file with --src-file"
  fi
}

validate_src_file() {
  # validate_src_file <repo> <at> <value> - the guard class is PROVENANCE THAT
  # CANNOT BE FOLLOWED, and every door into it is closed here rather than the
  # one that was last reported. A citation the next family cannot follow is a
  # rumour with a freshness stamp on it, which is worse than no fact at all.
  #
  #   1 bad shape             the value does not end :<digits>
  #   2 escapes the repo      absolute, or containing ..
  #   3 no path at all        `--src-file :1` - <at>: is the ROOT TREE, which
  #                           passes an existence check and has "lines"
  #   4 not addressable       nothing at that path at <at> (this is also what
  #                           closes a SUBMODULE path: a gitlink does not
  #                           resolve through <at>:<path> - verified)
  #   5 NOT A FILE            a DIRECTORY passes `cat-file -e`, and `cat-file
  #                           -p` prints its LISTING, so `apps:2` means "line 2
  #                           of a directory" - it clears a line-bound check and
  #                           `verify` then stamps it FRESH. `apps/` is the same
  #                           door with a trailing slash. ONE type test closes
  #                           every shape of it: the object must be a BLOB.
  #                           (A symlink IS a blob - one line, its target - and
  #                           its citation is followable, so it stays legal.)
  #   6 line past EOF         the citation names a line the file does not have
  #
  local repo="$1" at="$2" value="$3" path line n kind
  assert_single_line "--src-file" "$value"
  case "$value" in
    *:[0-9]*) ;;
    *) reject "--src-file wants <path>:<line> (got '$value')" ;;
  esac
  path="${value%:*}"; line="${value##*:}"
  case "$line" in ''|*[!0-9]*) reject "--src-file wants <path>:<line> (got '$value')" ;; esac
  [ -n "$path" ] || reject "--src-file names no path (got '$value') - it wants <path>:<line>"
  # Textual, deliberately, and copied verbatim from the qa.mocks_compose guard:
  # rejecting `..` without normalizing first refuses a/../../etc/passwd with no
  # realpath step.
  case "$path" in
    /*|*..*) reject "--src-file must be repo-relative (no absolute path, no ..): $path" ;;
  esac
  kind="$(git -C "$repo" cat-file -t "$at:$path" 2>/dev/null)" \
    || reject "$path does not exist at ${at:0:12} - the citation cannot be followed"
  [ "$kind" = blob ] \
    || reject "$path is a $kind at ${at:0:12}, not a file - a <path>:<line> citation into it is not followable by any reader"
  n="$(git -C "$repo" cat-file -p "$at:$path" 2>/dev/null | awk 'END { print NR }')"
  [ "$line" -le "$n" ] 2>/dev/null \
    || reject "$path has $n lines at ${at:0:12}; the citation names line $line"
}

# --- the gates every entry-composing verb runs ----------------------------------

settle_repo() {
  # settle_repo <repo> - the project repo the entry is about.
  [ -n "${1:-}" ] || usage
  [ -d "$1" ] || ac_die "--repo is not a directory: $1"
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || ac_die "--repo is not a git repo: $1"
}

settle_home() {
  # settle_home <--home value> <repo> - the ladder, resolved ONCE per process
  # and EXPORTED (header). There is NO rung 3: an unresolved ladder REFUSES,
  # the same fail-closed direction ac_home itself took at @bf8f656.
  local home
  home="$(ac_home_resolve "${1:-}" "$2")"
  [ -n "$home" ] || ac_die "no fleet home: pass --home <abs>, or set AC_HOME. This checkout is NOT one - a record written here lands where no fleet reads it, and in a leased worktree it is discarded on return. A crewmate pane never carries AC_HOME by design, which is exactly why bin/ac-brief.sh bakes a --home-carrying command line into every brief (ac-brief.sh:256-257) - run the line the brief gave you."
  export AC_HOME="$home"
}

prov_src=""; prov_sha=""; prov_date=""
resolve_provenance() {
  # resolve_provenance <repo> <family> <src-file> <src-cmd> <at> - attribution,
  # provenance and the write-time binding, in one place, for every verb that
  # composes an entry. Sets prov_src / prov_sha / prov_date, or refuses.
  # The scope route runs it at DRAFT time, so what a chief reviews in a
  # proposal is already known well-formed.
  local repo="$1" family="$2" sf="$3" sc="$4" at="$5" tag
  [ -n "$family" ] || reject "no attribution - pass --family <family>"
  case "$family" in
    *[!a-z0-9-]*|"") reject "--family must match [a-z0-9-] (got '$family')" ;;
  esac
  if [ -n "$sf" ] && [ -n "$sc" ]; then reject "an entry has ONE provenance - pass --src-file or --src-cmd, not both"; fi
  if [ -z "$sf" ] && [ -z "$sc" ]; then reject "no provenance - pass --src-file <path>:<line> or --src-cmd <command>"; fi
  # The DATE is stamped here, never accepted from the caller: a date a caller
  # types is a date a caller can get wrong, and a wrong freshness marker is the
  # rumour this record exists to prevent. --at defaults to HEAD - a mechanical
  # reading of the tree the author is looking at, not an inference - and the
  # default is only safe BECAUSE assert_bound refuses a HEAD that does not hold
  # the evidence.
  prov_sha="$(resolve_at "$repo" "${at:-HEAD}")"
  prov_date="$(date -u +%F)"
  if [ -n "$sf" ]; then
    validate_src_file "$repo" "$prov_sha" "$sf"
    tag="file"; prov_src="file:$sf"
  else
    assert_single_line "--src-cmd" "$sc"
    tag="cmd"; prov_src="cmd:$sc"
  fi
  assert_bound "$repo" "$prov_sha" "$tag" "${sf:-$sc}"
}

# --- add -----------------------------------------------------------------------

cmd_add() {
  local home_flag="" repo="" family="" src_file="" src_cmd="" at="" fact=""
  local declared_new=0 supersede="" dups target n
  local rec name entry live sup lock
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --family) family="${2:-}"; shift 2 ;;
      --src-file) src_file="${2:-}"; shift 2 ;;
      --src-cmd) src_cmd="${2:-}"; shift 2 ;;
      --at) at="${2:-}"; shift 2 ;;
      --fact) fact="${2:-}"; shift 2 ;;
      # The duplicate guard's two exits. `--new` DECLARES the subject genuinely
      # distinct; `--supersede` retires the named entry and adds this one in the
      # SAME locked write, so a reader never sees two claims about one subject
      # and never sees none.
      --new) declared_new=1; shift ;;
      --supersede) supersede="${2:-}"; shift 2 ;;
      # An unknown flag is a REFUSAL, and it is what keeps the closed scope
      # list out of the crewmate-facing verb: `add --scope` cannot write it
      # even by accident, because there is no such path to take.
      *) ac_die "unknown flag: $1 (ac-know.sh add writes facts; the scope map is not writable here)" ;;
    esac
  done
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"

  [ -n "$fact" ] || reject "no subject - pass --fact <text>"
  assert_single_line "--fact" "$fact"
  assert_no_line_pointer "$fact"
  resolve_provenance "$repo" "$family" "$src_file" "$src_cmd" "$at"

  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"
  entry="$(printf -- '- fact %s | src: %s | at: %s %s | by: %s' "$fact" "$prov_src" "$prov_sha" "$prov_date" "$family")"

  lock="$rec.lock"
  mkdir -p "$(dirname "$rec")"
  ac_lock_acquire "$lock" 30 || ac_die "ac-know: lock timeout for $name"
  live="$(mktemp)"; sup="$(mktemp)"
  if [ -f "$rec" ]; then record_live "$rec" >"$live"; record_superseded "$rec" >"$sup"; fi

  # THE DUPLICATE GUARD. `add` appended unconditionally before this, so the same
  # subject landed twice whenever two families verified it - the normal case for
  # a record whose whole purpose is that the NEXT family does not re-derive what
  # an earlier one proved. (The learnings ledger does NOT have this problem:
  # measured 0.7% exact duplicates over 1677 bullets. This record does.) The
  # refusal is the ac-know idiom - name the candidates, hand over both exits -
  # and it never decides for the caller which one is right.
  if [ -n "$supersede" ]; then
    target="$(fact_live_candidates "$live" "$supersede" "")"
    n=0; [ -z "$target" ] || n="$(printf '%s\n' "$target" | wc -l | tr -d ' ')"
    if [ "$n" -eq 0 ]; then
      rm -f "$live" "$sup"; ac_lock_release "$lock"
      ac_die "--supersede matched nothing: no live fact contains '$supersede' (nothing written)"
    fi
    if [ "$n" -gt 1 ]; then
      rm -f "$live" "$sup"; ac_lock_release "$lock"
      ac_die "--supersede '$supersede' is ambiguous - $n live entries match, quote a longer phrase (nothing written):
$target"
    fi
    # A MOVE, byte-identical, exactly as cmd_retire does it - one locked write,
    # so no reader ever sees the record with both claims or with neither.
    printf '%s\n' "$target" >>"$sup"
    grep -vxF -- "$target" "$live" >"$live.keep" || : >"$live.keep"
    mv "$live.keep" "$live"
  elif [ "$declared_new" -eq 0 ]; then
    dups="$(fact_near_duplicates "$live" "$fact")"
    if [ -n "$dups" ]; then
      rm -f "$live" "$sup"; ac_lock_release "$lock"
      ac_die "this subject already has a live entry (nothing written) - two claims about one subject is the defect this guard exists to stop:
$dups

  correct the existing one:  --supersede '<phrase quoted from it>'   (retires it and adds yours in one write)
  genuinely distinct:        --new                                    (declares it, and the guard stands aside)"
    fi
  fi

  printf '%s\n' "$entry" >>"$live"
  record_write "$rec" "$name" "$live" "$sup"
  rm -f "$live" "$sup"
  ac_lock_release "$lock"
  printf 'recorded in %s\n' "$rec"
}

# --- retire --------------------------------------------------------------------
#
# The crewmate-facing INVERSE of `add` (see the header's RETIRING A FACT
# block): `add` only appends, and there is no in-place edit verb. This is
# NOT a draft/chief-install two-step like the scope map below - a false fact
# staying live while a proposal waits is exactly the defect this closes, and
# the scope map's two-step exists for a different reason (a closed list a
# crewmate must not write), not freshness.

fact_live_candidates() {
  # fact_live_candidates <live-file> <quote> <by> - full physical LIVE `fact`
  # lines whose subject text (the entry's own free-text, before ` | src:`)
  # contains <quote> as a substring, narrowed to the entry's own `by:` family
  # when <by> is non-empty. One candidate per output line.
  local live="$1" quote="$2" by="$3"
  awk -v q="$quote" -v by="$by" '
    /^- fact / {
      subj = $0
      sub(/^- fact /, "", subj)
      sub(/ \| src:.*$/, "", subj)
      entry_by = $0
      sub(/^.*\| by: /, "", entry_by)
      if (index(subj, q) == 0) next
      if (by != "" && entry_by != by) next
      print
    }
  ' "$live"
}

fact_near_duplicates() {
  # fact_near_duplicates <live-file> <fact-text> - live entries whose SUBJECT
  # text overlaps the new fact's enough to be about the same thing. Printed as
  # full physical lines, one per candidate, most-overlapping first.
  #
  # The measure is deliberately MECHANICAL, not semantic: distinctive tokens
  # (>=5 chars, so `the`/`with`/`when` never carry a match) intersected against
  # each live subject, scored as |shared| / |tokens of the shorter subject| -
  # the shorter side, because a one-line fact restating part of a long one IS
  # the duplicate case this exists to catch, and dividing by the longer side
  # would score it near zero. A candidate needs BOTH >=60% of the shorter
  # subject AND >=4 shared tokens, so two short facts sharing one rare word are
  # not paired.
  #
  # Calibrated against the real record rather than guessed: on drydock's 487
  # live agent-crew facts this flags 1.4% of pairs (7 of 487 entries have any
  # candidate at all), i.e. it fires on the shape that actually recurs - two
  # families verifying the same subject - and stays silent on the ordinary case
  # of many facts about one file.
  local live="$1" fact="$2"
  awk -v newfact="$fact" '
    function toks(s, out,   n, i, w, arr) {
      n = split(tolower(s), arr, /[^a-z0-9_.\/-]+/)
      for (i = 1; i <= n; i++) { w = arr[i]; if (length(w) >= 5) out[w] = 1 }
      return length(out)
    }
    BEGIN { nn = toks(newfact, NT) }
    /^- fact / {
      subj = $0
      sub(/^- fact /, "", subj)
      sub(/ \| src:.*$/, "", subj)
      delete ET
      en = toks(subj, ET)
      if (nn == 0 || en == 0) next
      shared = 0
      for (w in NT) if (w in ET) shared++
      denom = (nn < en ? nn : en)
      if (shared < 4) next
      if (shared / denom < 0.60) next
      printf "%d\t%s\n", shared, $0
    }
  ' "$live" | sort -rn | cut -f2-
}

cmd_retire() {
  local home_flag="" repo="" family="" src_file="" src_cmd="" at="" quote="" by="" why=""
  local rec name live sup lock matches n target entry
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --family) family="${2:-}"; shift 2 ;;
      --src-file) src_file="${2:-}"; shift 2 ;;
      --src-cmd) src_cmd="${2:-}"; shift 2 ;;
      --at) at="${2:-}"; shift 2 ;;
      --quote) quote="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      --why) why="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"

  [ -n "$quote" ] || reject "no target - pass --quote '<phrase from the entry's own text>'"
  [ -n "$why" ] || reject "a retirement records WHY - pass --why <text>"
  assert_single_line "--why" "$why"
  resolve_provenance "$repo" "$family" "$src_file" "$src_cmd" "$at"

  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"

  lock="$rec.lock"
  mkdir -p "$(dirname "$rec")"
  ac_lock_acquire "$lock" 30 || ac_die "ac-know: lock timeout for $name"
  live="$(mktemp)"; sup="$(mktemp)"
  if [ -f "$rec" ]; then record_live "$rec" >"$live"; record_superseded "$rec" >"$sup"; fi

  matches="$(fact_live_candidates "$live" "$quote" "$by")"
  n=0; [ -z "$matches" ] || n="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    rm -f "$live" "$sup"; ac_lock_release "$lock"
    ac_die "retire: nothing matched '$quote'${by:+ by family $by} - no live fact entry contains that phrase"
  fi
  if [ "$n" -gt 1 ]; then
    rm -f "$live" "$sup"; ac_lock_release "$lock"
    ac_die "retire: '$quote' is ambiguous - $n live entries match, narrow with --by <family>:
$matches"
  fi
  target="$matches"

  # Supersession is a MOVE, byte-identical - the cmd_scope_proposal retire/
  # replace idiom, reused rather than re-implemented (header, Serialization).
  printf '%s\n' "$target" >>"$sup"
  grep -vxF -- "$target" "$live" >"$live.keep" || : >"$live.keep"
  mv "$live.keep" "$live"

  entry="$(printf -- '- fact retired: %s | src: %s | at: %s %s | by: %s' \
    "$why" "$prov_src" "$prov_sha" "$prov_date" "$family")"
  printf '%s\n' "$entry" >>"$live"

  record_write "$rec" "$name" "$live" "$sup"
  rm -f "$live" "$sup"
  ac_lock_release "$lock"
  printf 'retired from %s\n' "$rec"
}

# --- cite: the mechanical usage counter -----------------------------------------
#
# (repo-knowledge-has-no-usage-signal) Measured before this verb existed: 415
# of the drydock record's 487 live facts graded SUSPECT with NO signal for
# which to re-verify or retire first - both decisions were re-argued from
# scratch every time, and a discipline-based counter ("bump it when you read
# it") dies because nothing enforces the bump. `cite` IS the enforcement path:
# intake reads a hit through this verb instead of bare grep - it PRINTS the
# matched entry (the read the caller came for) and increments the entry's
# `| heat: <n>` field in the same locked write, so the counter is a side
# effect of the read rather than a second act anyone can forget.
#
# The field is OPTIONAL and sits immediately BEFORE `| by:`:
#
#   - fact <text> | src: <prov> | at: <sha> <date> [| heat: <n>] | by: <family>
#
# Position is load-bearing, verified against both existing parsers: appending
# AFTER `| by:` corrupts fact_live_candidates (it takes the by-family as
# everything after the LAST `| by: `), while before it both that read and
# cmd_verify's `at` first-word read are unaffected. An absent field means
# NEVER CITED - the retire-priority floor. Addressing mirrors `retire`
# exactly: a phrase quoted from the entry's own text, `--by` narrowing,
# exactly-one match, loud refusals, the record's own lock. Unlike retire this
# is an IN-PLACE rewrite - the entry keeps its position, because a cite is a
# read receipt, not a supersession, and the record's no-in-place-edit rule
# (header) is about CLAIM TEXT: heat carries no claim, so bumping it moves no
# fact and re-orders nothing.
cmd_cite() {
  local home_flag="" repo="" quote="" by=""
  local rec name live sup lock matches n target prefix byval h base new
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --quote) quote="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"
  [ -n "$quote" ] || reject "no target - pass --quote '<phrase from the entry own text>'"

  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"
  [ -f "$rec" ] || ac_die "cite: no repo-knowledge record yet: $rec"

  lock="$rec.lock"
  ac_lock_acquire "$lock" 30 || ac_die "ac-know: lock timeout for $name"
  live="$(mktemp)"; sup="$(mktemp)"
  record_live "$rec" >"$live"; record_superseded "$rec" >"$sup"

  matches="$(fact_live_candidates "$live" "$quote" "$by")"
  n=0; [ -z "$matches" ] || n="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then
    rm -f "$live" "$sup"; ac_lock_release "$lock"
    ac_die "cite: nothing matched '$quote'${by:+ by family $by} - no live fact entry contains that phrase"
  fi
  if [ "$n" -gt 1 ]; then
    rm -f "$live" "$sup"; ac_lock_release "$lock"
    ac_die "cite: '$quote' is ambiguous - $n live entries match, narrow with --by <family>:
$matches"
  fi
  target="$matches"

  # Split at the LAST `| by:` (the family slug carries no pipe); bump an
  # existing heat or mint `heat: 1` in the slot before it.
  case "$target" in
    *" | by: "*) ;;
    *) rm -f "$live" "$sup"; ac_lock_release "$lock"
       ac_die "cite: matched entry carries no '| by:' field - not a grammar line this verb can bump: $target" ;;
  esac
  prefix="${target% | by: *}"; byval="${target##* | by: }"
  case "$prefix" in
    *" | heat: "*)
      h="${prefix##* | heat: }"; base="${prefix% | heat: *}"
      case "$h" in
        ''|*[!0-9]*) rm -f "$live" "$sup"; ac_lock_release "$lock"
                     ac_die "cite: malformed heat field on the matched entry (got: '| heat: $h'): $target" ;;
      esac
      new="$base | heat: $((h + 1)) | by: $byval" ;;
    *) new="$prefix | heat: 1 | by: $byval" ;;
  esac

  # IN-PLACE: replace the one matched line where it stands. ENVIRON, not -v:
  # awk -v cooks backslash escapes, and an entry's free text may carry them.
  OLD_LINE="$target" NEW_LINE="$new" awk '
    BEGIN { o = ENVIRON["OLD_LINE"]; nw = ENVIRON["NEW_LINE"] }
    $0 == o && !done { print nw; done = 1; next }
    { print }
  ' "$live" >"$live.new" && mv "$live.new" "$live"

  record_write "$rec" "$name" "$live" "$sup"
  rm -f "$live" "$sup"
  ac_lock_release "$lock"
  printf '%s\n' "$new"
  printf 'cited in %s\n' "$rec"
}

# --- recall: the TIERED read across the knowledge layers ------------------------
#
# (knowledge-read-has-no-tiered-recall) AGENTS.md section-5 intake says to grep
# records/repo-knowledge/<project>.md by the order's QUESTION. Measured on
# drydock 2026-08-09 that is a flat scan over 383KB / 487 entries with no
# ranking and no budget: a common term returns dozens of thousand-character
# lines, the whole reading cost lands on the chief, and nothing distinguishes a
# FRESH fact from one of the 415 the record's own `verify` grades SUSPECT.
#
# This is the retrieval half of the TencentDB port, degraded honestly to what
# 487 entries actually need. Their pipeline is vector recall -> FTS5 BM25 ->
# nothing; at this scale grep IS the FTS tier, so there is no embedding here and
# there should not be: their own code deletes the fallback below FTS rather than
# keep a ranking it cannot trust, and inventing a vector store to rank 487 lines
# would be the speculative abstraction the Karpathy rule forbids.
#
# WHAT IS PORTED is the part that matters: walk the layers IN ORDER, rank inside
# each, and CAP the output.
#
#   1. SCENES (L2)  - consolidated topic files; a hit here restores a whole
#                     subject in one read, which is why they come first.
#   2. FACTS  (L1)  - repo-knowledge entries, the verified specifics.
#
# The learnings ledger is deliberately NOT a tier: its Pending window is the
# DISTILL scout's input, not an intake read, and it carries no provenance a
# chief could cite.
#
# RANKING inside a tier: distinctive query terms (>=4 chars) matched against the
# entry, ordered by (terms matched, then `heat:`) - the usage counter `cite`
# maintains, so a fact the fleet actually reaches for outranks one nobody has
# opened. BUDGET: --max entries (default 8) and --bytes of printed body
# (default 8192), because an unbounded answer is the flat grep this replaces.
# Both are printed when they truncate - a silent cut reads as "that is all
# there is".
#
# It PRINTS, it does not cite: bumping heat on eight entries the caller merely
# skimmed would corrupt the very signal it ranks by. The caller cites the ONE
# it used, through `ac-know.sh cite` / `ac-scene.sh show --cite`, and the tail
# of the output says so.
cmd_recall() {
  local home_flag="" repo="" query="" max=8 bytes=8192
  local rec live n_scene=0 n_fact=0 printed=0 shown_bytes=0 truncated=0 floor
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --max) max="${2:-}"; shift 2 ;;
      --bytes) bytes="${2:-}"; shift 2 ;;
      -*) ac_die "unknown flag: $1" ;;
      *) query="${query:+$query }$1"; shift ;;
    esac
  done
  [ -n "$query" ] || reject "no question - pass the order's subject/mechanism/terms"
  case "$max" in ''|*[!0-9]*) ac_die "--max must be a count (got: '$max')" ;; esac
  case "$bytes" in ''|*[!0-9]*) ac_die "--bytes must be a byte count (got: '$bytes')" ;; esac
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"
  floor="$(recall_floor "$query")"

  # TIER 1: scenes. Ranked over the summary AND the body, because a scene's
  # whole value is the body - but only the summary is printed, so the answer
  # stays a pointer the caller opens rather than a wall of text.
  local sdir sf slug heat summary hits scene_tsv
  sdir="$(ac_records_dir)/scenes"
  scene_tsv="$(mktemp)"
  if [ -d "$sdir" ]; then
    for sf in "$sdir"/*.md; do
      [ -f "$sf" ] || continue
      slug="$(basename "$sf" .md)"
      heat="$(sed -n '2p' "$sf" | tr ' ' '\n' | sed -n 's/^heat=//p')"
      summary="$(sed -n '3s/^summary: //p' "$sf")"
      hits="$(recall_hits "$query" "$(cat "$sf")")"
      [ "$hits" -ge "$floor" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$hits" "${heat:-0}" "$slug" "$summary" >>"$scene_tsv"
    done
  fi
  if [ -s "$scene_tsv" ]; then
    printf '== scenes (L2 - a topic restored in one read) ==\n'
    while IFS="$(printf '\t')" read -r hits heat slug summary; do
      [ "$printed" -lt "$max" ] || { truncated=1; break; }
      printf '  %s  (hits %s, heat %s)\n    %s\n    open: ac-scene.sh show %s --cite\n' \
        "$slug" "$hits" "$heat" "$summary" "$slug"
      printed=$((printed + 1)); n_scene=$((n_scene + 1))
    done < <(sort -t"$(printf '\t')" -k1,1nr -k2,2nr "$scene_tsv")
    printf '\n'
  fi
  rm -f "$scene_tsv"

  # TIER 2: repo-knowledge facts. The BYTE budget applies here, because these
  # are the long lines - the measured 383KB the flat grep used to hand over.
  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  local fact_tsv fheat line subj quote
  fact_tsv="$(mktemp)"
  if [ -f "$rec" ]; then
    live="$(mktemp)"; record_live "$rec" >"$live"
    while IFS= read -r line; do
      case "$line" in '- fact '*) ;; *) continue ;; esac
      hits="$(recall_hits "$query" "$line")"
      [ "$hits" -ge "$floor" ] || continue
      fheat="${line% | by: *}"
      case "$fheat" in *" | heat: "*) fheat="${fheat##* | heat: }" ;; *) fheat=0 ;; esac
      case "$fheat" in ''|*[!0-9]*) fheat=0 ;; esac
      printf '%s\t%s\t%s\n' "$hits" "$fheat" "$line" >>"$fact_tsv"
    done <"$live"
    rm -f "$live"
  fi
  if [ -s "$fact_tsv" ]; then
    printf '== facts (L1 - repo-knowledge) ==\n'
    while IFS="$(printf '\t')" read -r hits fheat line; do
      if [ "$printed" -ge "$max" ] || [ "$shown_bytes" -ge "$bytes" ]; then truncated=1; break; fi
      subj="${line#- fact }"; subj="${subj%% | src:*}"
      printf '  (hits %s, heat %s) %s\n' "$hits" "$fheat" "$line"
      # The cite hand-over quotes a phrase from the entry's OWN text, which is
      # how ac-know.sh addresses an entry - never a line number.
      quote="$(printf '%s' "$subj" | cut -c1-60)"
      printf '    cite: ac-know.sh cite --repo <clone> --quote %s\n' "'$quote'"
      printed=$((printed + 1)); n_fact=$((n_fact + 1))
      shown_bytes=$((shown_bytes + ${#line}))
    done < <(sort -t"$(printf '\t')" -k1,1nr -k2,2nr "$fact_tsv")
    printf '\n'
  fi

  local total_f=0
  [ ! -s "$fact_tsv" ] || total_f="$(wc -l <"$fact_tsv" | tr -d ' ')"
  rm -f "$fact_tsv"

  if [ "$printed" -eq 0 ]; then
    printf 'no hit in any layer for: %s (needed %s of its distinctive terms)\n' "$query" "$floor"
    printf '(state the absence explicitly in the brief - AGENTS.md section 5)\n'
    return 0
  fi
  printf -- '-- %s scene(s), %s fact(s) shown' "$n_scene" "$n_fact"
  if [ "$truncated" -eq 1 ]; then
    printf '; TRUNCATED at --max %s / --bytes %s (%s fact hits total) --\n' \
      "$max" "$bytes" "$total_f"
  else
    printf ' (all hits) --\n'
  fi
  printf 'recall PRINTS; it never cites - bumping heat on what you only skimmed\n'
  printf 'would corrupt the ranking. Cite the ONE you use, with the line above it.\n'
}

recall_floor() {
  # recall_floor <query> - the minimum term-hits an entry needs to be OFFERED.
  # Measured, not guessed: with a floor of 1, the question "fifo hold gate
  # blocks on open not read" matched 304 of drydock's 454 live facts, because
  # ordinary words (`hold`, `gate`, `read`, `open`) each match something
  # somewhere - a truncation notice reading "304 hits total" tells the caller
  # the tool is guessing. The floor is 60% of the query's distinctive terms,
  # never below 2: one shared ordinary word is not a topic match, and a
  # single-term question still gets its literal grep.
  QQ="$1" awk '
    BEGIN {
      n = split(tolower(ENVIRON["QQ"]), arr, /[^a-z0-9_.\/-]+/)
      for (i = 1; i <= n; i++) if (length(arr[i]) >= 4) Q[arr[i]] = 1
      t = length(Q)
      f = int(t * 0.6 + 0.999)
      if (t <= 1) f = 1; else if (f < 2) f = 2
      print f
    }'
}

recall_hits() {
  # recall_hits <query> <text> - how many DISTINCTIVE query terms (>=4 chars,
  # deduped, case-folded) appear in the text. The same mechanical measure the
  # duplicate guard uses, so one idea of "these are about the same thing" is
  # implemented once in this file.
  QQ="$1" TT="$2" awk '
    function toks(s, out,   n, i, w, arr) {
      n = split(tolower(s), arr, /[^a-z0-9_.\/-]+/)
      for (i = 1; i <= n; i++) { w = arr[i]; if (length(w) >= 4) out[w] = 1 }
    }
    BEGIN {
      toks(ENVIRON["QQ"], Q)
      t = tolower(ENVIRON["TT"])
      for (w in Q) if (index(t, w) > 0) hits++
      print hits + 0
    }'
}

# --- the scope map: draft, then chief-install -----------------------------------
#
# The scope map is the CLOSED LIST that decides which scope+app profile a qa
# run may claim, so writing it is authority a CHIEF holds, not a crewmate. It
# therefore travels the same two-step route the fleet-home config already does
# - agent DRAFTS, chief INSTALLS, captain vetoes by restoring `.prev` - rather
# than getting a flag on the crewmate-facing verb.
#
# Enforcement level, stated precisely rather than overclaimed: `scope-install`
# is chief-tier by LAW, not by mechanics, exactly as `ac-qa.sh config-install`
# already is - an agent that can run bash can run any verb. What the mechanism
# guarantees is that (a) `add` has no scope path at all, so the crewmate-facing
# verb cannot write the list even by accident, (b) writing it requires a draft
# a chief reviews, and (c) no brief template ever names the install verb.
# Claiming more than that would be the same overclaim as a FRESH nobody
# verified.

scope_live_lines() {
  # scope_live_lines <live-file> <scope> - the LIVE entries for one scope name,
  # byte-identical. Matched on the PARSED name, never a prefix: `orchid` must not
  # match `orchid-legacy`.
  awk -v want="$2" '
    /^- scope / {
      subj = $0
      sub(/^- scope /, "", subj)
      sub(/ \| src: .*$/, "", subj)
      i = index(subj, " = ")
      if (i == 0) next
      if (substr(subj, 1, i - 1) == want) print
    }
  ' "$1"
}

scope_overlap_note() {
  # scope_overlap_note <live-file> <scope> <app>... - an app MAY belong to more
  # than one scope, so an overlap is never a refusal; it is printed for
  # VISIBILITY, so the author sees the overlap they just created and a chief
  # reviewing the draft sees it too.
  # The scan EXISTS - there is no other way to notice an overlap - it is
  # INFORMATIONAL, and it is NEVER authoritative for resolution: nothing reads
  # it, no exit status depends on it, and deleting it would leave every
  # resolution outcome byte-identical.
  local live="$1" scope="$2" app other members
  shift 2
  for app in "$@"; do
    while IFS=$'\t' read -r other members; do
      [ "$other" != "$scope" ] || continue
      case ",$members," in
        *",$app,"*) printf 'note: %s is also live in scope %s\n' "$app" "$other" >&2 ;;
      esac
    done < <(awk '
      /^- scope / {
        subj = $0
        sub(/^- scope /, "", subj); sub(/ \| src: .*$/, "", subj)
        i = index(subj, " = ")
        if (i == 0) next
        apps = substr(subj, i + 3); gsub(/[ \t]/, "", apps)
        printf "%s\t%s\n", substr(subj, 1, i - 1), apps
      }' "$live")
  done
}

cmd_scope_proposal() {
  local home_flag="" repo="" family="" src_file="" src_cmd="" at="" id=""
  local scope="" apps="" why="" replace=0 retire=0
  local rec name out base prop patch live sup existing entry base_sha a
  local -a app_list=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --family) family="${2:-}"; shift 2 ;;
      --src-file) src_file="${2:-}"; shift 2 ;;
      --src-cmd) src_cmd="${2:-}"; shift 2 ;;
      --at) at="${2:-}"; shift 2 ;;
      --scope) scope="${2:-}"; shift 2 ;;
      --apps) apps="${2:-}"; shift 2 ;;
      --why) why="${2:-}"; shift 2 ;;
      --id) id="${2:-}"; shift 2 ;;
      --replace) replace=1; shift ;;
      --retire) retire=1; shift ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"

  [ -n "$scope" ] || reject "no scope named - pass --scope <name>"
  case "$scope" in
    *[!A-Za-z0-9_-]*) reject "$scope is not addressable as a yaml path segment (--scope must match [A-Za-z0-9_-])" ;;
  esac
  if [ "$retire" = 1 ]; then
    [ -n "$why" ] || reject "a retirement records WHY - pass --why <text>"
    assert_single_line "--why" "$why"
    [ -z "$apps" ] || reject "--retire removes a scope from the list; it takes no --apps"
  else
    apps="${apps// /}"
    [ -n "$apps" ] || reject "a scope with no members - pass --apps <app>,<app>"
    IFS=',' read -r -a app_list <<<"$apps"
    for a in "${app_list[@]}"; do
      case "$a" in
        *[!A-Za-z0-9_-]*|"") reject "$a is not addressable as a yaml path segment (--apps must match [A-Za-z0-9_-])" ;;
      esac
    done
  fi
  resolve_provenance "$repo" "$family" "$src_file" "$src_cmd" "$at"

  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"
  [ -n "$id" ] || id="$(date +%Y%m%d-%H%M%S)-$$"
  case "$id" in *[!A-Za-z0-9._-]*|"") ac_die "invalid proposal id: $id" ;; esac
  out="$repo/.crew/knowledge-proposals/$id"
  mkdir -p "$repo/.crew/knowledge-proposals"
  mkdir "$out" 2>/dev/null || ac_die "scope-proposal: id already exists: $id"
  base="$out/base.md"; prop="$out/proposed.md"; patch="$out/proposal.patch"

  live="$(mktemp)"; sup="$(mktemp)"
  : >"$base"
  if [ -f "$rec" ]; then cp "$rec" "$base"; record_live "$rec" >"$live"; record_superseded "$rec" >"$sup"; fi

  existing="$(scope_live_lines "$live" "$scope")"
  if [ "$retire" = 1 ]; then
    [ -n "$existing" ] || { rm -f "$live" "$sup"; rm -rf "$out"; reject "no live entry for scope $scope - nothing to retire"; }
    # A retirement is a fact, not a fourth entry type: without it the closed
    # list could only ever grow, and a dead scope name would stay acceptable
    # to the resolver forever.
    entry="$(printf -- '- fact retired scope %s: %s | src: %s | at: %s %s | by: %s' \
      "$scope" "$why" "$prov_src" "$prov_sha" "$prov_date" "$family")"
  else
    if [ -n "$existing" ] && [ "$replace" = 0 ]; then
      rm -f "$live" "$sup"; rm -rf "$out"
      reject "scope $scope is already live - pass --replace to supersede it:
$existing"
    fi
    entry="$(printf -- '- scope %s = %s | src: %s | at: %s %s | by: %s' \
      "$scope" "${apps//,/, }" "$prov_src" "$prov_sha" "$prov_date" "$family")"
  fi
  # Supersession is a MOVE, byte-identical: a receipt is durable, so the old
  # line is never rewritten or summarized, only relocated below the marker.
  if [ -n "$existing" ]; then
    printf '%s\n' "$existing" >>"$sup"
    grep -vxF -- "$existing" "$live" >"$live.keep" || : >"$live.keep"
    mv "$live.keep" "$live"
  fi
  [ "$retire" = 1 ] || scope_overlap_note "$live" "$scope" "${app_list[@]}"
  printf '%s\n' "$entry" >>"$live"
  record_render "$name" "$live" "$sup" >"$prop"
  rm -f "$live" "$sup"

  base_sha="$(ac_config_sha256 "$base")"
  printf '%s\n' "$base_sha" >"$out/base.sha256"
  printf '%s\n' "$name" >"$out/project"
  if diff -u --label current --label proposed "$base" "$prop" >"$patch"; then
    rm -rf "$out"
    reject "the draft is identical to the installed record - nothing to propose"
  fi
  printf 'proposal_id: %s\nproposal written:\n  %s\n  %s\ntarget: %s\nbase_sha256: %s\ninstall (CHIEF, after review - never the drafting agent): %s/bin/ac-know.sh scope-install %s --home %s --repo %s\n' \
    "$id" "$patch" "$prop" "$rec" "$base_sha" "$(ac_root)" "$id" "$AC_HOME" "$repo"
}

cmd_scope_install() {
  # The CHIEF-TIER install: under the record's own lock, re-check the draft's
  # base hash against what is installed NOW and refuse a stale draft rather
  # than overwriting the winner, then replace atomically and keep one `.prev`
  # as the captain's veto net. Structure copied from ac-qa.sh config-install,
  # deliberately: a chief who has done one has done the other.
  local id="${1:-}" home_flag="" repo="" rec name out prop base_sha cur cur_sha tmp prev="" lock installed
  shift 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$id" ] || ac_die "usage: ac-know.sh scope-install <proposal-id> --home <abs> --repo <dir>"
  case "$id" in *[!A-Za-z0-9._-]*) ac_die "invalid proposal id: $id" ;; esac
  settle_repo "$repo"
  settle_home "$home_flag" "$repo"
  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"
  out="$repo/.crew/knowledge-proposals/$id"
  prop="$out/proposed.md"
  [ -f "$prop" ] || ac_die "scope-install: no staged proposal $id at $out"
  [ "$(cat "$out/project" 2>/dev/null || true)" = "$name" ] \
    || ac_die "scope-install: proposal $id does not target project $name"
  base_sha="$(cat "$out/base.sha256" 2>/dev/null || true)"
  [ -n "$base_sha" ] || ac_die "scope-install: proposal $id has no base hash"

  mkdir -p "$(dirname "$rec")"
  lock="$rec.lock"
  ac_lock_acquire "$lock" 30 || ac_die "scope-install: lock timeout for $name"
  cur="$(mktemp "$rec.current.XXXXXX")"
  if [ -f "$rec" ]; then cp "$rec" "$cur"; else : >"$cur"; fi
  cur_sha="$(ac_config_sha256 "$cur")"
  if [ "$cur_sha" != "$base_sha" ]; then
    rm -f "$cur"; ac_lock_release "$lock"
    ac_die "scope-install: proposal $id conflicts with a newer installed record (base=$base_sha current=$cur_sha); re-draft it"
  fi
  if [ -f "$rec" ] && ! diff -q "$rec" "$prop" >/dev/null 2>&1; then
    prev="$rec.prev"
    cp "$rec" "$prev"
  fi
  tmp="$(mktemp "$rec.install.XXXXXX")"
  cp "$prop" "$tmp"
  mv "$tmp" "$rec"
  installed="$(ac_config_sha256 "$rec")"
  rm -f "$cur"
  ac_lock_release "$lock"
  printf '%s\n' "$installed" >"$out/installed.sha256"
  printf 'installed proposal %s: %s -> %s%s\n' "$id" "$prop" "$rec" "${prev:+ (previous kept at $prev)}"
  printf 'receipt (post to the family room): KNOWLEDGE-INSTALLED: %s sha256=%s proposal=%s - drafted by the task agent, reviewed + installed by the chief; captain veto: restore %s\n' \
    "$rec" "$installed" "$id" "${prev:-"(no previous record)"}"
}

# --- verify --------------------------------------------------------------------

cmd_verify() {
  local home_flag="" repo="" home rec name line rest src at tag value path rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home_flag="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  [ -n "$repo" ] || usage
  [ -d "$repo" ] || ac_die "--repo is not a directory: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || ac_die "--repo is not a git repo: $repo"
  home="$(ac_home_resolve "$home_flag" "$repo")"
  [ -n "$home" ] || home="$(ac_root)"
  export AC_HOME="$home"
  rec="$(ac_knowledge_file "$repo")" || ac_die "cannot resolve the project name for $repo"
  name="$(ac_project_config_name "$repo")"
  [ -f "$rec" ] || { printf 'no repo-knowledge record yet: %s\n' "$rec"; return 0; }

  # LIVE entries only. `## Superseded` is history, and a stale line there is
  # not a claim anyone is being asked to trust.
  #
  # The whole pass is TEE'd through a counter so this run leaves a STAMP: an
  # 8-second git walk over 487 entries (measured) can never ride the
  # session-start digest, but its VERDICT can, and a digest that reads a stamp
  # stays O(1) in entries the way every other block is. The stamp records the
  # HEAD it ran against, so a reader is told "as of <sha>" and a moved tree
  # reads as stale rather than as a fresh green.
  local vout vhead
  vout="$(mktemp)"
  vhead="$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf -- '-')"
  while IFS= read -r line; do
    rest="${line#*| src: }"; src="${rest%% | at: *}"
    rest="${line#*| at: }"; at="${rest%% *}"
    tag="${src%%:*}"; value="${src#*:}"
    if [ "$tag" = cmd ]; then
      # A cmd: entry has nothing to diff, so it never reports FRESH at all -
      # it cannot manufacture a false one. MANUAL already carries the
      # strongest possible instruction, and a dirty-tree sub-token would
      # change no reader's action.
      printf 'MANUAL  %s  (re-run: %s)\n' "$line" "$value"
      continue
    fi
    path="${value%:*}"
    if ! git -C "$repo" rev-parse --verify --quiet "$at^{commit}" >/dev/null 2>&1; then
      printf 'UNVERIFIABLE %s  (%s does not resolve in this clone)\n' "$line" "${at:0:12}"
      continue
    fi
    if [ ! -e "$repo/$path" ]; then
      # Door N (assert_bound header): a path absent from disk is SUSPECT
      # (deleted since the fact was recorded) only when `<at>` is an ancestor
      # of HEAD - this branch once had the path and lost it. When `<at>` is
      # NOT an ancestor, the path was never expected to exist in this
      # worktree (an app tree recorded from an integration branch this clone
      # never checked out), and this clone has no live copy to compare
      # against either way.
      if git -C "$repo" merge-base --is-ancestor "$at" HEAD 2>/dev/null; then
        printf 'SUSPECT %s  (%s no longer exists)\n' "$line" "$path"
      else
        printf 'UNVERIFIABLE %s  (%s has no worktree copy in this clone to compare against %s)\n' \
          "$line" "$path" "${at:0:12}"
      fi
      continue
    fi
    # <at> vs the WORKING TREE, never <at>..HEAD: a commit-to-commit compare
    # sees neither the index nor the worktree, which is exactly how a fact
    # observed in an uncommitted tree came back FRESH.
    rc=0
    git -C "$repo" diff --quiet "$at" -- "$path" || rc=$?
    case "$rc" in
      0) printf 'FRESH   %s\n' "$line" ;;
      1) printf 'SUSPECT %s  (%s changed since %s)\n' "$line" "$path" "${at:0:12}" ;;
      *) printf 'UNVERIFIABLE %s  (cannot compare %s against %s)\n' "$line" "$path" "${at:0:12}" ;;
    esac
  done < <(record_live "$rec") | tee "$vout"

  # The stamp is DOT-PREFIXED under state/ for the same reason every learning
  # counter is: a bare <name>.meta there enumerates as a phantom crewmate.
  local stamp
  stamp="$(ac_state_dir)/.know-verify-$name.meta"
  {
    printf 'record=%s\n' "$(basename "$rec")"
    printf 'fresh=%s\n' "$(grep -c '^FRESH' "$vout" || true)"
    printf 'suspect=%s\n' "$(grep -c '^SUSPECT' "$vout" || true)"
    printf 'unverifiable=%s\n' "$(grep -c '^UNVERIFIABLE' "$vout" || true)"
    printf 'manual=%s\n' "$(grep -c '^MANUAL' "$vout" || true)"
    printf 'head=%s\n' "$vhead"
    printf 'ran=%s\n' "$(ac_iso)"
  } >"$stamp.tmp.$$"
  mv "$stamp.tmp.$$" "$stamp"
  rm -f "$vout"
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  cite) shift; cmd_cite "$@" ;;
  recall) shift; cmd_recall "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  scope-proposal) shift; cmd_scope_proposal "$@" ;;
  scope-install) shift; cmd_scope_install "$@" ;;
  -h|--help|"") usage ;;
  *) ac_die "unknown verb: $1" ;;
esac
