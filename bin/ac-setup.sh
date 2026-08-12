#!/usr/bin/env bash
# ac-setup.sh - one-off machine setup for agent-crew: toolchain doctor, the
# fleet homes container, and the `ac` shell launcher.
#
# Usage: ac-setup.sh
#        ac-setup.sh -h | --help
#
# INTERACTIVE by design - this is a CAPTAIN tool, not crew tooling: it asks one
# line per decision and an empty answer takes the shown default. Answers are
# read from plain stdin, so a heredoc drives it unattended (that is how
# tests/ac-setup.test.sh drives it). stdin at EOF is an error, never a silent
# run on defaults.
#
# Steps, in order:
#   1. toolchain - re-runs bin/ac-bootstrap.sh, which stays THE authority on
#      what agent-crew needs. Its MISSING lines are printed and become this
#      script's exit status, but they never abort the install: a container and
#      a launcher are useful with a half-ready toolchain, and the doctor is
#      re-runnable any time.
#   2. captain tools - herdr, wezterm: each probed, and offered for
#      install ONLY when absent, so nothing already there is ever reinstalled.
#      Every install is asked for and defaults to NO, so an unattended run
#      installs nothing and a declined tool still prints its exact command.
#      wezterm is checked HERE and not in the doctor:
#      ac-bootstrap.sh answers "can the FLEET run?" and gates every session
#      start (ac-session-start.sh runs it --quiet, where an OPTIONAL line still
#      prints), while this answers "can the CAPTAIN drive it?". No crew invokes
#      it, so reporting it every session would be noise about a
#      non-issue. Advisory: none of this changes the exit status.
#   3. homes container - mkdir -p. One subdir per fleet; fleets are created
#      afterwards by bin/ac-fleet-new.sh, never here.
#   4. launcher - copies docs/examples/ac.zsh to the chosen path, OVERWRITING
#      it: the repo copy is the source of truth, so re-running is how an
#      installed launcher is updated.
#
# It never edits ~/.zshrc or any other dotfile (captain's rule): the `source`
# line is PRINTED to paste. It creates no fleet and clones no project.
#
# docs/examples/ac.zsh hardcodes ~/Work/agent-crew and ~/Work/ac-homes. A
# checkout or container anywhere else is WARNED about rather than rewritten -
# the launcher is an example to own, not a generated file.
#
# Exit: the doctor's status - 0 when every required tool is present.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

case "${1:-}" in
  -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) ac_die "unknown argument: $1" ;;
esac

ask() {
  # ask <prompt> [<default>] -> the typed answer, or <default> when it is empty.
  # The prompt rides STDERR so the answer alone lands on stdout. Kept local to
  # this script instead of ac-lib.sh: every OTHER script there is run by crew,
  # and none of them may ever block on stdin.
  local prompt="$1" default="${2:-}" ans=""
  printf '%s%s: ' "$prompt" "${default:+ [$default]}" >&2
  if ! IFS= read -r ans; then
    printf '\n' >&2
    ac_die "stdin closed while asking: $prompt"
  fi
  printf '%s\n' "${ans:-$default}"
}

untilde() {
  # untilde <path> - expand a LEADING ~ against $HOME. A typed answer never
  # passes through the shell's own tilde expansion, so `~/Work/ac-homes` would
  # otherwise mkdir a literal `~` directory under $PWD and report success for a
  # path the launcher will never look at. No ~user form and no eval: this input
  # is a path, not code.
  # shellcheck disable=SC2088  # matching a LITERAL leading ~ is the whole job here
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

root="$(ac_root)"

# --- 1. toolchain -------------------------------------------------------------
# Advisory here, not fatal: it rides out as the exit status (see the header).
printf '== toolchain ==\n'
rc=0
"$root/bin/ac-bootstrap.sh" || rc=$?

# --- 2. captain tools ---------------------------------------------------------
printf '\n== captain tools ==\n'

offer() {
  # offer <tool> <installer> <cmd>... - ONLY called for a tool already probed
  # ABSENT, so nothing present is ever reinstalled. Asks first and runs <cmd>
  # directly (never eval - the command is built here, not typed). Declining is
  # the default: setup must stay safe to run unattended, and a captain who says
  # no still gets the exact command to run later.
  local tool="$1" installer="$2"; shift 2
  if ! command -v "$installer" >/dev/null 2>&1; then
    printf '  no %s here - install %s first, then: %s\n' "$installer" "$installer" "$*"
    return 0
  fi
  local ans
  ans="$(ask "install $tool now? ($*) yes|no" no)"
  if [ "$ans" != yes ]; then
    printf '  skipped - run it yourself when you want it: %s\n' "$*"
    return 0
  fi
  # Foreground, sharing this terminal: an installer that needs a password must
  # be able to ask for it. A failure is reported, never fatal - the container
  # and launcher below are still worth creating.
  if "$@"; then
    printf 'OK: %s (installed)\n' "$tool"
  else
    ac_warn "$tool install failed - run: $*"
  fi
}

# herdr: the doctor above already reported it and said why. Re-probed here only
# to decide whether there is anything to offer, so a captain can fix the one
# REQUIRED tool without leaving the script.
if command -v herdr >/dev/null 2>&1; then
  printf 'OK: herdr\n'
else
  offer herdr brew brew install herdr
fi

# wezterm renders the herdr UI. herdr draws in any terminal, so this is a
# preference, not a requirement - but it is the terminal
# docs/examples/wezterm-agent-crew.lua wires the fleet statusline into.
if command -v wezterm >/dev/null 2>&1 || [ -d /Applications/WezTerm.app ]; then
  printf 'OK: wezterm\n'
else
  printf 'OPTIONAL: wezterm missing - it renders the herdr UI\n'
  offer wezterm brew brew install --cask wezterm
fi

# --- 3. homes container -------------------------------------------------------
printf '\n== fleet homes container ==\n'
container="$(ask 'container path' "${AC_HOMES_CONTAINER:-$HOME/Work/ac-homes}")"
# Expanded as its OWN statement, never `$(untilde "$(ask ...)")`: nesting would
# hand the outer substitution untilde's status and swallow ask's EOF exit - the
# same errexit trap ask_enum documents in ac-fleet-new.sh.
container="$(untilde "$container")"
[ -n "$container" ] || ac_die "container path must not be empty"
mkdir -p "$container"
container="$(cd "$container" && pwd -P)"
printf 'container: %s\n' "$container"

# --- 4. launcher --------------------------------------------------------------
printf '\n== ac launcher ==\n'
src="$root/docs/examples/ac.zsh"
[ -f "$src" ] || ac_die "launcher source missing: $src"
dest="$(ask 'install ac.zsh to' "$HOME/.config/zsh/ac.zsh")"
dest="$(untilde "$dest")"
[ -n "$dest" ] || ac_die "launcher path must not be empty"
mkdir -p "$(dirname "$dest")"
cp "$src" "$dest"
printf 'launcher: %s\n' "$dest"

# The launcher's two hardcoded paths are the whole reason it can find anything;
# a silently mismatched pair would fail later as "ac: no fleet at ...".
case "$container" in
  "$HOME/Work/ac-homes") ;;
  *) ac_warn "$dest hardcodes ~/Work/ac-homes but your container is $container - edit it, or \`ac\` will not find your fleets" ;;
esac
case "$root" in
  "$HOME/Work/agent-crew") ;;
  *) ac_warn "$dest hardcodes ~/Work/agent-crew but this checkout is $root - edit it, or \`ac\` will launch the wrong directory" ;;
esac

printf '\nNEXT:\n'
printf '  1. add to ~/.zshrc:  source %s\n' "$dest"
printf '  2. exec zsh\n'
printf '  3. create a fleet:   %s/bin/ac-fleet-new.sh\n' "$root"
if [ "$rc" != 0 ]; then
  printf '\n' >&2
  ac_warn "the toolchain doctor reported missing tools above - fix them, then re-run bin/ac-bootstrap.sh"
fi
exit "$rc"
