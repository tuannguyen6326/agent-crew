#!/usr/bin/env bash
# ac-fleet-new.sh - create a new top-level FLEET home under the homes container.
#
# Usage: ac-fleet-new.sh [<name>] [--container <dir>]
#        ac-fleet-new.sh -h | --help
#
# A fleet home is what AC_HOME points at. This is the top-level sibling of
# bin/ac-home-seed.sh, which seeds a CREWDEPUTY home nested inside a parent
# fleet and INHERITS the parent's knobs. A fleet has no parent to inherit from,
# so every knob is asked here instead.
#
# INTERACTIVE by design - a CAPTAIN tool, not crew tooling: one line per knob.
# Answers are read from plain stdin, so a heredoc drives it unattended (that is
# how tests/ac-fleet-new.test.sh drives it). stdin at EOF is an error, never a
# silent run on defaults: a fleet nobody described is worse than no fleet.
# Name, container and the already-exists refusal are all resolved BEFORE the
# first question, so a doomed run never spends the captain's answers.
#
# A knob file is written ONLY when the captain typed a value. An absent file is
# not a gap - every reader resolves `ac_config_read <knob> <default>`, so
# absence IS that default, and a fleet's config/ therefore holds exactly what
# was chosen for it. Each prompt names the default it is declining; each knob's
# OWNER stays the authority on its meaning:
#   captain      who the crewchief addresses      (AGENTS.md section 1)
#   model        fleet-wide crewmate model        (ac-spawn.sh)
#   effort       fleet-wide claude effort         (ac-spawn.sh owns the enum)
#   gate-agent   design-gate judge engine         (ac-gate.sh)
#   gate-model   the judge's model                (ac-gate.sh)
#   gate-effort  the judge's reasoning effort     (ac-gate.sh)
#   promote      roomchief promotion policy       (AGENTS.md section 8)
#   flow         direct/staged pin                (AGENTS.md section 5)
# config/backend is written as `herdr` unasked - it is the fleet's only backend.
#
# No workspace ids are seeded: the retired herdr-workspace* knobs are never
# read - ac-backend.sh (FAMILY WORKSPACE GROUPING) resolves every workspace
# adopt-by-label per fleet at runtime.
#
# Directory layout is taken from ac-lib.sh's own path helpers (ac_state_dir,
# ac_records_dir, ...) rather than hardcoded here, so this script cannot drift
# from the layout they define - records/ moved out of data/ on 2026-07-17 and
# nothing here had to change.
#
# Container = --container > $AC_HOMES_CONTAINER > ~/Work/ac-homes, shown on the
# prompt for confirmation. Deliberately NOT derived from $AC_HOME's parent (the
# rung the read-only ac-fleets.sh survey does use): run from the repo checkout
# that resolves to ~/Work, and this script CREATES directories.
#
# Refuses to overwrite an existing home. Prints the home path on stdout.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

name=""
container=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --container) container="${2:?--container needs a path}"; shift 2 ;;
    -*) ac_die "unknown argument: $1" ;;
    *)
      [ -z "$name" ] || ac_die "unexpected argument: $1"
      name="$1"; shift ;;
  esac
done

ask() {
  # ask <prompt> -> the typed answer ("" when the captain just hits Enter).
  # The prompt rides STDERR so the answer alone lands on stdout. Kept local to
  # this script instead of ac-lib.sh: every OTHER script there is run by crew,
  # and none of them may ever block on stdin.
  local prompt="$1" ans=""
  printf '%s: ' "$prompt" >&2
  if ! IFS= read -r ans; then
    printf '\n' >&2
    ac_die "stdin closed while asking: $prompt"
  fi
  printf '%s\n' "$ans"
}

untilde() {
  # untilde <path> - expand a LEADING ~ against $HOME. Neither a typed answer
  # nor a quoted --container value passes through the shell's own tilde
  # expansion, so `~/Work/ac-homes` would otherwise mkdir a literal `~`
  # directory under $PWD and seed the fleet somewhere nothing looks for it. No
  # ~user form and no eval: this input is a path, not code.
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the whole job here
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

ask_enum() {
  # ask_enum <prompt> <valid>... - re-ask until the answer is one of <valid>.
  # Empty is always accepted and means "write no knob file" (the reader's own
  # default applies; the prompt text names it). Validating HERE is worth the
  # echo of the owner's enum: a typo written into config/ would otherwise stay
  # silent until the spawn or gate that reads the knob dies on it, long after
  # the captain who typed it has moved on.
  local prompt="$1"; shift
  local ans v
  while :; do
    # `|| exit 1` is load-bearing, not belt-and-braces: errexit does NOT fire on
    # a failing $()-assignment inside a function body that is itself running in
    # a command substitution (measured on bash 3.2 and 5.x). Without it ask's
    # ac_die on EOF would print its ERROR, hand back "", and this function would
    # read that as "the captain hit Enter" - seeding a fleet from silent
    # defaults, the exact thing the header promises never happens. The status IS
    # available here; only the automatic exit is missing.
    ans="$(ask "$prompt")" || exit 1
    if [ -z "$ans" ]; then printf '\n'; return 0; fi
    for v in "$@"; do
      if [ "$ans" = "$v" ]; then printf '%s\n' "$ans"; return 0; fi
    done
    printf 'not one of: %s (or empty)\n' "$*" >&2
  done
}

# --- name, container, refusals: everything that can fail, before any question --
case "$name" in
  "") ;;
  *[!a-zA-Z0-9_-]*) ac_die "name must be [a-zA-Z0-9_-]: $name" ;;
esac
while [ -z "$name" ]; do
  name="$(ask 'fleet name')"
  case "$name" in
    "") printf 'a fleet needs a name\n' >&2 ;;
    *[!a-zA-Z0-9_-]*) printf 'name must be [a-zA-Z0-9_-]: %s\n' "$name" >&2; name="" ;;
  esac
done

[ -n "$container" ] || container="$(ask "homes container [${AC_HOMES_CONTAINER:-$HOME/Work/ac-homes}]")"
[ -n "$container" ] || container="${AC_HOMES_CONTAINER:-$HOME/Work/ac-homes}"
# Own statement, never nested inside the ask above: that would swallow its EOF
# exit behind untilde's status (see ask_enum).
container="$(untilde "$container")"
mkdir -p "$container"
container="$(cd "$container" && pwd -P)"
home="$container/$name"
if [ -e "$home" ]; then
  ac_die "fleet home already exists: $home"
fi

# --- the knobs ----------------------------------------------------------------
printf '\n== %s: config knobs (empty = keep the shown default) ==\n' "$name" >&2
captain="$(ask 'captain name (empty: the crewchief just says "captain")')"
model="$(ask 'crewmate model (empty: claude picks its own)')"
effort="$(ask_enum 'crewmate effort low|medium|high|xhigh|max|ultracode (empty: claude picks its own)' \
  low medium high xhigh max ultracode)"
gate_agent="$(ask_enum 'design-gate judge codex|claude|off (empty: codex)' codex claude off)"
gate_model="$(ask 'gate judge model (empty: the engine picks its own)')"
gate_effort="$(ask 'gate judge effort (empty: the engine picks its own)')"
promote="$(ask_enum 'roomchief promotion always|auto|never (empty: always)' always auto never)"
flow="$(ask_enum 'task flow auto|direct|staged (empty: auto)' auto direct staged)"
crewmate_md="$(ask_enum 'seed a per-fleet CREWMATE.md yes|no (empty: no - inherit the container-wide .claude/CLAUDE.md)' yes no)"

# --- seed ---------------------------------------------------------------------
# Dirs via ac-lib's own helpers (each mkdir -p's its own path), so the layout
# contract lives in exactly one place - see the header.
mkdir -p "$home"
config="$(AC_HOME="$home" ac_config_dir)"
records="$(AC_HOME="$home" ac_records_dir)"
(AC_HOME="$home" ac_state_dir; AC_HOME="$home" ac_data_dir; AC_HOME="$home" ac_projects_dir) >/dev/null

printf 'herdr\n' >"$config/backend"

write_knob() {
  # write_knob <name> <value> - a file only when the captain gave a value;
  # absence is how this fleet takes the reader's default (see the header).
  [ -n "${2:-}" ] || return 0
  printf '%s\n' "$2" >"$config/$1"
}
write_knob captain "$captain"
write_knob model "$model"
write_knob effort "$effort"
write_knob gate-agent "$gate_agent"
write_knob gate-model "$gate_model"
write_knob gate-effort "$gate_effort"
write_knob promote "$promote"
write_knob flow "$flow"

printf '# Projects\n\n' >"$records/projects.md"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$records/backlog.md"

# A per-fleet CREWMATE.md WINS over the container-wide .claude/CLAUDE.md that
# every fleet otherwise shares (ac-spawn.sh owns that resolution order), so it
# is seeded only when asked for.
if [ "$crewmate_md" = yes ]; then
  cp "$(ac_root)/docs/examples/CREWMATE.md" "$home/CREWMATE.md"
fi

printf '%s\n' "$home"
printf '\nNEXT:\n' >&2
printf '  ac %s                    # via the launcher (bin/ac-setup.sh installs it)\n' "$name" >&2
printf '  AC_HOME=%s claude   # or point a harness at it directly\n' "$home" >&2
printf '\nThe crewchief clones projects into %s/projects/ on your word - do not pre-clone.\n' "$home" >&2
