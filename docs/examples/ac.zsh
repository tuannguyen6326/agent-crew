# agent-crew fleet launcher: `ac <fleet>[/<deputy>] [--backend=<b>] [--harness=<h>] [--solo]`
#   ac                  -> list fleets (subdirs with state/)
#   ac lab              -> launch the chief on the lab fleet (harness claude)
#   ac lab/mobile         -> launch on the nested CREWDEPUTY home
#                          (crewdeputies/<name> under the fleet); NOTE this opens
#                          a plain chief session on that home - no deputy kickoff,
#                          no parent meta, so the registry still reads NOT-RUNNING
#   ac mobile             -> bare deputy name: resolved when exactly ONE fleet
#                          carries it; several fleets -> refused with the list
#   --harness=<h>       -> harness to run (default claude); the bare 2nd word
#                          form `ac lab codex` still works
#   --solo              -> a SOLO session beside the chief (AC_SOLO=1): runs
#                          inline in the CURRENT terminal, never takes the chief
#                          lock, codes one slice at a time via bin/ac-self-task.sh;
#                          session-start goes read-only under it
#   --backend=<b>       -> where the chief OPENS: herdr | orca. Default ladder
#                          (same as ac-spawn): flag > the home's config/backend
#                          > herdr. herdr attaches the fleet's root "<fleet>"
#                          workspace; orca runs the chief inline in the CURRENT
#                          terminal (Orca-native when launched from an Orca
#                          terminal - there is no herdr surface to attach)
#   ac dashboard [--port N]   -> the READ-ONLY web dashboard (bin/ac-dashboard.sh)
#   ac --dashboard [--port N] -> same, flag form; `dashboard`/`--dashboard` are
#                          reserved first words, not fleet names
#   inside herdr : run the harness in the current pane (any backend)
#   legacy       : `--deputy=<name>` (and the `--debuty=` spelling alias)
_ac_home() {
  emulate -L zsh
  local fleet="$1" harness="$2" deputy="${3:-}" backend="${4:-}" solo="${5:-}"
  local ach="$HOME/Work/ac-homes/$fleet"
  [[ -d "$ach" ]] || { print -u2 "ac: no fleet at $ach"; return 1 }
  if [[ -n "$deputy" ]]; then
    ach="$ach/crewdeputies/$deputy"
    [[ -d "$ach" ]] || { print -u2 "ac: no deputy home at $ach"; return 1 }
  fi
  # backend ladder: --backend flag > the home's config/backend > herdr
  [[ -n "$backend" ]] || backend="$(cat "$ach/config/backend" 2>/dev/null)"
  backend="${backend:-herdr}"
  case "$backend" in
    herdr|orca) ;;
    *) print -u2 "ac: unknown backend '$backend' (valid: herdr, orca)"; return 1 ;;
  esac
  # SOLO: a second session beside the chief - always inline in the current
  # terminal (it owns no workspace/tab), AC_SOLO=1 makes session-start
  # read-only and stands the supervision hooks down.
  if [[ -n "$solo" ]]; then
    cd "$ach" && AC_HOME="$ach" AC_SOLO=1 exec "$harness"
    return
  fi
  # orca home, or already inside herdr: run the chief inline right here.
  # cwd is the HOME (workspace = home, repo = code): the home symlinks the
  # executable core (bin/ CLAUDE.md .claude/ AGENTS.md) to the repo.
  if [[ "$backend" == orca || -n "$HERDR_ENV" ]]; then
    cd "$ach" && AC_HOME="$ach" exec "$harness"
    return
  fi
  # One herdr session for every call below, resolved the way bin/ac-backend.sh
  # herdr_cli does (AC_HERDR_SESSION > the home's config/herdr-session), so the
  # chief's tab and the workspace the backend resolves live on one server.
  local sess="${AC_HERDR_SESSION:-$(cat "$ach/config/herdr-session" 2>/dev/null)}"
  local -a sarg; [[ -n "$sess" ]] && sarg=(--session "$sess")
  herdr "${sarg[@]}" status server >/dev/null 2>&1 || { (herdr "${sarg[@]}" server >/dev/null 2>&1 &); sleep 1; }
  # The chief (and a deputy opened as <fleet>/<deputy>) is a fleet-level pane:
  # it joins the parent fleet's ROOT workspace "<fleet>" - a label the backend
  # shares, so it is resolved and tidied by the backend's own functions
  # (bin/ac-backend.sh FAMILY WORKSPACE GROUPING), never a second resolver.
  local bin="$HOME/Work/agent-crew/bin" ws
  ws=$(AC_HOME="$ach" AC_BACKEND=herdr AC_HERDR_SESSION="$sess" bash -c '. "$1/ac-lib.sh" && . "$1/ac-backend.sh" && herdr_resolve_workspace "$2"' _ "$bin" "$fleet")
  [[ -n "$ws" ]] || print -u2 "ac: could not resolve the '$fleet' workspace - opening the chief outside it"
  local -a wsarg; [[ -n "$ws" ]] && wsarg=(--workspace "$ws")
  local pane
  pane=$(herdr "${sarg[@]}" tab create "${wsarg[@]}" --label "ac-$fleet${deputy:+-$deputy}" --cwd "$ach" --focus 2>/dev/null | jq -r '.result.root_pane.pane_id // empty')
  [[ -n "$pane" ]] && herdr "${sarg[@]}" pane run "$pane" "cd $ach && AC_HOME=$ach exec $harness" >/dev/null 2>&1
  [[ -n "$ws" ]] && AC_HOME="$ach" AC_BACKEND=herdr AC_HERDR_SESSION="$sess" bash -c '. "$1/ac-lib.sh" && . "$1/ac-backend.sh" && herdr_close_default_tabs "$2"' _ "$bin" "$ws" >/dev/null 2>&1
  herdr "${sarg[@]}"
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
  local deputy="" backend="" harness="" solo="" arg
  local -a rest
  for arg in "$@"; do
    case "$arg" in
      --deputy=*|--debuty=*) deputy="${arg#*=}" ;;
      --backend=*) backend="${arg#*=}" ;;
      --harness=*) harness="${arg#*=}" ;;
      --solo) solo=1 ;;
      --*) print -u2 "ac: unknown flag $arg (known: --backend=<herdr|orca> --harness=<h> --deputy=<name> --solo)"; return 1 ;;
      *) rest+=("$arg") ;;
    esac
  done
  local target="${rest[1]:-}"
  if [[ -z "$target" ]]; then
    local -a fleets; fleets=($(_ac_fleets))
    if (( ${#fleets} )); then
      print -u2 "usage: ac <fleet>[/<deputy>] [--backend=<herdr|orca>] [--harness=<h>]   fleets: ${fleets[*]}"
    else
      print -u2 "usage: ac <fleet>[/<deputy>] [--backend=<herdr|orca>] [--harness=<h>]   (no fleets under ~/Work/ac-homes yet - see bin/ac-home-seed.sh)"
    fi
    return 1
  fi
  local fleet="$target"
  if [[ "$target" == */* ]]; then
    fleet="${target%%/*}"
    [[ -n "$deputy" ]] || deputy="${target#*/}"
  fi
  # A bare name that is not a fleet may be a DEPUTY: resolve it when exactly
  # one fleet carries it, refuse with the candidates when several do.
  if [[ ! -d "$HOME/Work/ac-homes/$fleet" && -z "$deputy" ]]; then
    local -a hits
    local d
    for d in "$HOME/Work/ac-homes"/*/crewdeputies/"$fleet"(N/); do hits+=("$d"); done
    if (( ${#hits} == 1 )); then
      deputy="$fleet"
      fleet="${hits[1]:h:h:t}"
    elif (( ${#hits} > 1 )); then
      print -u2 "ac: '$fleet' is a deputy in several fleets (${(j:, :)${(@)hits:h:h:t}}) - say ac <fleet>/$fleet"
      return 1
    fi
  fi
  [[ -n "$harness" ]] || harness="${rest[2]:-claude}"
  _ac_home "$fleet" "$harness" "$deputy" "$backend" "$solo"
}

# tab-complete fleet names, fleet/deputy, harnesses and the = flags
if (( $+functions[compdef] )); then
  _ac_complete() {
    local cur="${words[CURRENT]}"
    if [[ "$cur" == --deputy=* || "$cur" == --debuty=* ]]; then
      local d f="${words[2]%%/*}"
      local -a deps
      for d in "$HOME/Work/ac-homes/$f/crewdeputies"/*(N/); do deps+=("${d:t}"); done
      compadd -P "${cur%%=*}=" -- $deps
    elif [[ "$cur" == --backend=* ]]; then
      compadd -P "--backend=" -- herdr orca
    elif [[ "$cur" == --harness=* ]]; then
      compadd -P "--harness=" -- claude codex opencode pi cursor
    elif (( CURRENT == 2 )); then
      if [[ "$cur" == */* ]]; then
        local f="${cur%%/*}" d
        local -a deps
        for d in "$HOME/Work/ac-homes/$f/crewdeputies"/*(N/); do deps+=("$f/${d:t}"); done
        compadd -- $deps
      else
        local -a bdeps
        for d in "$HOME/Work/ac-homes"/*/crewdeputies/*(N/); do bdeps+=("${d:t}"); done
        compadd -- dashboard --dashboard $(_ac_fleets) $bdeps
      fi
    else
      compadd -- --backend= --harness= --deputy= claude codex opencode
    fi
  }
  compdef _ac_complete ac
fi
