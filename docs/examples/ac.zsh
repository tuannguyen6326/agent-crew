# agent-crew fleet launcher: `ac <fleet> [harness]` for homes under ~/Work/ac-homes
#   ac              -> list fleets (subdirs with state/)
#   ac lab          -> launch claude on the lab fleet
#   ac lab codex    -> launch another harness on it
#   ac drydock --deputy=demo -> launch on a nested CREWDEPUTY home
#                  (crewdeputies/<name> under the fleet); NOTE this opens a
#                  plain chief session on that home - no deputy kickoff, no
#                  parent meta, so the registry still reads NOT-RUNNING.
#                  `--debuty=` is accepted as a spelling alias.
#   ac dashboard [--port N]   -> the READ-ONLY web dashboard (bin/ac-dashboard.sh)
#   ac --dashboard [--port N] -> same, flag form; `dashboard`/`--dashboard` are
#                  reserved first words, not fleet names
#   inside herdr : run the harness in the current pane
#   outside herdr: open the crewchief in the fleet's "<fleet> (crewchief)"
#                  herdr workspace (beside its roomchiefs), then attach
_ac_home() {
  emulate -L zsh
  local fleet="$1" harness="$2" deputy="${3:-}"
  local root="$HOME/Work/agent-crew" ach="$HOME/Work/ac-homes/$fleet"
  [[ -d "$ach" ]] || { print -u2 "ac: no fleet at $ach"; return 1 }
  if [[ -n "$deputy" ]]; then
    ach="$ach/crewdeputies/$deputy"
    [[ -d "$ach" ]] || { print -u2 "ac: no deputy home at $ach"; return 1 }
  fi
  if [[ -n "$HERDR_ENV" ]]; then
    cd "$root" && AC_HOME="$ach" exec "$harness"
    return
  fi
  herdr status server >/dev/null 2>&1 || { (herdr server >/dev/null 2>&1 &); sleep 1; }
  # the crewchief tab anchors the fleet ROOT workspace "<fleet>" (family
  # workspaces "<fleet> · <family>" sit beside it; ac-backend.sh FAMILY
  # WORKSPACE GROUPING)
  local label="$fleet" ws
  ws=$(herdr workspace list 2>/dev/null | jq -r --arg l "$label" '.result.workspaces[]? | select(.label==$l) | .workspace_id' | head -1)
  if [[ -z "$ws" ]]; then
    herdr workspace create --label "$label" --no-focus >/dev/null 2>&1
    ws=$(herdr workspace list 2>/dev/null | jq -r --arg l "$label" '.result.workspaces[]? | select(.label==$l) | .workspace_id' | head -1)
  fi
  # no knob pin: workspaces resolve adopt-by-label (ac-backend.sh FAMILY
  # WORKSPACE GROUPING); the captain tab just opens in the fleet root group
  local -a wsarg; [[ -n "$ws" ]] && wsarg=(--workspace "$ws")
  local pane
  pane=$(herdr tab create "${wsarg[@]}" --label "ac-$fleet${deputy:+-$deputy}" --cwd "$root" --focus 2>/dev/null | jq -r '.result.root_pane.pane_id // empty')
  [[ -n "$pane" ]] && herdr pane run "$pane" "cd $root && AC_HOME=$ach exec $harness" >/dev/null 2>&1
  herdr
}

_ac_fleets() {
  # fleet = a homes-container subdir that has state/
  local d
  for d in "$HOME/Work/ac-homes"/*(N/); do
    [[ -d "$d/state" ]] && print -r -- "${d:t}"
  done
}

ac() {
  emulate -L zsh
  if [[ "${1:-}" == "dashboard" || "${1:-}" == "--dashboard" ]]; then
    shift
    "$HOME/Work/agent-crew/bin/ac-dashboard.sh" "$@"
    return
  fi
  local deputy="" arg
  local -a rest
  for arg in "$@"; do
    case "$arg" in
      --deputy=*|--debuty=*) deputy="${arg#*=}" ;;
      --*) print -u2 "ac: unknown flag $arg (known: --deputy=<name>)"; return 1 ;;
      *) rest+=("$arg") ;;
    esac
  done
  if [[ -z "${rest[1]:-}" ]]; then
    local -a fleets; fleets=($(_ac_fleets))
    if (( ${#fleets} )); then
      print -u2 "usage: ac <fleet> [harness] [--deputy=<name>]   fleets: ${fleets[*]}"
    else
      print -u2 "usage: ac <fleet> [harness] [--deputy=<name>]   (no fleets under ~/Work/ac-homes yet - see bin/ac-home-seed.sh)"
    fi
    return 1
  fi
  _ac_home "${rest[1]}" "${rest[2]:-claude}" "$deputy"
}

# tab-complete fleet names (and harnesses on the 2nd word)
if (( $+functions[compdef] )); then
  _ac_complete() {
    if [[ "${words[CURRENT]}" == --deputy=* || "${words[CURRENT]}" == --debuty=* ]]; then
      local d f="${words[2]}"
      local -a deps
      for d in "$HOME/Work/ac-homes/$f/crewdeputies"/*(N/); do deps+=("${d:t}"); done
      compadd -P "${words[CURRENT]%%=*}=" -- $deps
    elif (( CURRENT == 2 )); then
      compadd -- dashboard --dashboard $(_ac_fleets)
    elif (( CURRENT == 3 )); then
      compadd -- claude codex opencode --deputy=
    fi
  }
  compdef _ac_complete ac
fi
