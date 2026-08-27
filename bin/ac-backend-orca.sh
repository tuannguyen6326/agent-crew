#!/usr/bin/env bash
# ac-backend-orca.sh - the orca driver of the session-backend contract.
# Sourced by ac-backend.sh (never an entrypoint); every backend_*_orca here
# implements the surface ac-backend.sh's header documents, same names, same
# three-state return codes. The herdr driver is the contract's reference
# implementation; where orca has no counterpart the divergence is stated at
# the function, not silently absorbed:
# - GROUPING (orca_place_pane): chief-kind panes (cwd = the home) sit under
#   the HOME node, one FAMILY TAB per room (AC_WINDOW_FAMILY, same ladder as
#   the herdr driver; the tab clears with its last pane); crewmate and
#   verifier panes (cwd = a project/lease worktree) sit under THAT
#   worktree's own node, one tab each.
# - No agent-report API: the captain-wait stamp is the FILE alone; Orca's own
#   agentWait detection keeps surfacing waits in its UI (see backend_mark_wait_orca).
# - No process-info verb: the came-up probe reads the terminal TITLE, which
#   tracks the foreground process (measured on orca CLI 1.4.188: a bare shell
#   reports its own name, harness TUIs set an OSC title of their own).
# - Reads never prove liveness: a CLOSED terminal still serves `terminal read`
#   from retained scrollback (measured) - liveness comes from `terminal show`
#   `.connected`, with `status` as the control call.
# Handles are runtime-issued UUIDs and never recycled (measured), so the kill
# ownership proof needs no creation-label round-trip: the recorded handle can
# only be this task's terminal.

orca_json() {
  # orca_json <args...> - run the orca CLI with --json. Non-zero exit and an
  # ok:false envelope both fail (return 1): the caller's three-state logic
  # decides what a failed call means, exactly like a failed herdr_cli.
  local out
  out="$(orca "$@" --json 2>/dev/null)" || return 1
  jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

orca_pane() { ac_pane_field "$1" 1; }

backend_target_orca() { printf 'orca:%s\n' "$(orca_pane "$1")"; }

orca_fam_key() {
  # The herdr driver's FAMILY WORKSPACE GROUPING ladder, orca dialect
  # (family -> TAB): AC_WINDOW_FAMILY set non-empty names the family, set
  # EMPTY deliberately targets the fleet ROOT group, unset derives the
  # family from the task id via ac_window_family.
  local id="$1" fam
  if [ "${AC_WINDOW_FAMILY+set}" = "set" ]; then fam="$AC_WINDOW_FAMILY"
  else fam="$(ac_window_family "$id")"; fi
  printf '%s\n' "${fam:-_root}"
}

orca_fam_file() { printf '%s/.orca-fam-%s\n' "$(ac_state_dir)" "$1"; }

orca_tab_handles() {
  # Live handles of one tab, sorted - the discovery surface for split (the
  # real CLI returns NO handle from `terminal split`, measured).
  orca_json terminal list 2>/dev/null \
    | jq -r --arg t "$1" '[.result.terminals[] | select(.tabId==$t) | .handle] | sort | .[]'
}

orca_resolve_group() {
  # orca_resolve_group <path> - nearest ANCESTOR (self included) that Orca's
  # path selector resolves, probed cheaply via `worktree show` (a create with
  # an unmatched path fails selector_not_found - measured after a repo
  # registration was removed). Falls back to the path itself when nothing
  # matches, so the create's own error stays the one that names the fix.
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    if orca_json worktree show --worktree "path:$p" >/dev/null 2>&1; then
      printf '%s\n' "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done
  printf '%s\n' "$1"
}

orca_worktree_lease() {
  # orca_worktree_lease <id> <repo> - an Orca-managed worktree for an
  # orca-backend crewmate (orca fleets lease through the Orca CLI, one
  # worktree per task, sidebar-native; herdr fleets keep the crew-tree
  # pool). Created from the LOCAL default branch - the CLI's own default
  # base is origin/<default>, which lags local landings (measured) - with
  # repo-defined setup hooks running and no lineage parent (the CLI
  # otherwise infers the CALLER's active worktree as parent - measured).
  # The primary checkout's node_modules rides over as a clone when the
  # hooks have not already produced one: git carries only tracked files,
  # and a fresh install per task is the cost the clone removes. A COPY
  # (APFS clonefile when available), never a symlink - a crewmate's own
  # install must not mutate the primary's deps. The CLI names the
  # branch <git-user>/<name>; the crew contract owns crew/<id>, so the
  # checkout is switched there (adopting an existing crew/<id> on a
  # respawn) and the minted name dropped. Prints the path; 1 on failure.
  local id="$1" repo="$2" out path obranch def st
  def="$(ac_default_branch "$repo")"
  out="$(orca_json worktree create --repo "path:$repo" --name "crew-$id" \
      --base-branch "$def" --setup run --no-parent)" || return 1
  path="$(jq -r '.result.worktree.path // empty' <<<"$out")"
  [ -n "$path" ] && [ -d "$path" ] || return 1
  # The CLI opens the worktree WITH a first terminal (a bare shell), and the
  # create JSON carries no handle for it (measured 1.4.188). The crew pane
  # must BE the worktree's first tab, so every terminal already sitting on
  # the seconds-old worktree - all CLI-minted - is closed by discovery.
  for st in $(orca_json terminal list 2>/dev/null \
      | jq -r --arg p "$path" '.result.terminals[] | select(.worktreePath==$p) | .handle'); do
    orca_json terminal close --terminal "$st" >/dev/null 2>&1 || true
  done
  obranch="$(jq -r '.result.worktree.branch // empty' <<<"$out")"
  obranch="${obranch#refs/heads/}"
  if git -C "$path" show-ref --verify -q "refs/heads/crew/$id"; then
    git -C "$path" switch "crew/$id" >/dev/null 2>&1 || return 1
  else
    git -C "$path" switch -c "crew/$id" >/dev/null 2>&1 || return 1
  fi
  [ -z "$obranch" ] || git -C "$path" branch -D "$obranch" >/dev/null 2>&1 || true
  if [ -d "$repo/node_modules" ] && [ ! -e "$path/node_modules" ]; then
    cp -Rc "$repo/node_modules" "$path/node_modules" 2>/dev/null \
      || cp -R "$repo/node_modules" "$path/node_modules" 2>/dev/null \
      || ac_warn "node_modules carry failed for $id - crewmate installs fresh"
  fi
  printf '%s\n' "$path"
}

orca_worktree_release() {
  # orca_worktree_release <path> - remove an Orca-managed worktree (the rm
  # takes the dir and the CLI's bookkeeping with it - measured). Best-effort.
  orca_json worktree rm --worktree "path:$1" --force >/dev/null 2>&1
}

orca_place_pane() {
  # orca_place_pane <dir> [<command>] - the FAMILY TAB placement shared by
  # crewmate windows (backend_window_new) and verification panes
  # (ac-pane-agent's orca arm): create-or-split into the family tab and
  # print "<handle> <tab>". <command> defaults to the interactive shell; a
  # verification pane passes its RUNCMD so the agent starts WITH the pane -
  # nothing is ever typed into a booting surface. <id> feeds the family
  # ladder and the creation title. Returns 1 on failure (prints nothing,
  # warns) so callers own their own death message.
  local dir="$1" cmd="${2:-}" id="${3:-agent}" out handle tab fam famf base before lockdir i dir_p home_p node_sel
  [ -n "$cmd" ] || cmd="cd '$dir' && exec \${SHELL:-/bin/zsh}"
  # Creation titles carry the fleet token (crew:<fleet>/<id>) - display-only,
  # parsed by nothing: two fleets under one container (a deputy beside its
  # parent) render identical bare titles in mixed tab lists otherwise. The
  # harness overwrites the title once it boots; the prefix covers the gap.
  # GROUPING RULE: chief-kind panes (cwd = the HOME) group under the home's
  # sidebar node with one FAMILY TAB per room; crewmate and verifier panes
  # (cwd = a project/lease worktree) group under THAT worktree's own node,
  # one tab each - the Orca-native shape, sessions beside their diffs.
  dir_p="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
  # A homeless caller (a crewmate-invoked verifier) has no AC_HOME and never
  # places a chief-kind pane - resolve to empty so it takes the worker arm
  # quietly instead of ac_home's refusal leaking into the pane-result stream.
  home_p=""
  [ -z "${AC_HOME:-}" ] || home_p="$(cd "$AC_HOME" 2>/dev/null && pwd -P || true)"
  if [ "$dir_p" != "$home_p" ]; then
    out="$(orca_json terminal create --worktree "path:$(orca_resolve_group "$dir_p")" --title "crew:$(ac_fleet_name)/$id" \
        --command "$cmd")" || {
      ac_warn "orca terminal create failed for $dir (is the Orca runtime running - orca open / orca serve - and the repo registered: orca repo add --path <repo>?)"
      return 1
    }
    handle="$(jq -r '.result.terminal.handle // empty' <<<"$out")"
    tab="$(jq -r '.result.terminal.tabId // empty' <<<"$out")"
    if [ -z "$handle" ] || [ -z "$tab" ]; then
      ac_warn "could not parse orca terminal create output"; return 1
    fi
    printf '%s %s\n' "$handle" "$tab"
    return 0
  fi
  # HOME ARM (chief-kind panes). `terminal create` has no cwd flag and a cd
  # typed into the fresh shell races its boot (measured: eaten twice), so
  # the command IS the cwd control. FAMILY TABS under the home node: the
  # family's FIRST pane creates a tab and records it (state/.orca-fam-<fam>);
  # a later same-family home pane SPLITS into it, so every room is one tab
  # under the home. A dead tab (no live terminal) heals to a fresh create;
  # the tab clears itself when its last pane closes (measured; kill closes
  # panes, never tabs).
  fam="$(orca_fam_key "$id")"
  famf="$(orca_fam_file "$fam")"
  tab="$(cat "$famf" 2>/dev/null || true)"
  base=""
  [ -z "$tab" ] || base="$(orca_tab_handles "$tab" | head -n 1)"
  if [ -n "$base" ]; then
    # Split discovery is a before/after diff of the tab's handles, so two
    # concurrent spawns into one family must not interleave: a short mkdir
    # lock serializes them; on timeout proceed unlocked (best-effort).
    lockdir="$(ac_state_dir)/.orca-split.lock"
    i=0
    until mkdir "$lockdir" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 40 ] && break
      sleep 0.25
    done
    before="$(orca_tab_handles "$tab")"
    if ! orca_json terminal split --terminal "$base" --direction vertical \
        --command "$cmd" >/dev/null; then
      rmdir "$lockdir" 2>/dev/null || true
      ac_warn "orca terminal split failed (family tab $tab)"; return 1
    fi
    handle="$(comm -13 <(printf '%s\n' "$before") <(orca_tab_handles "$tab") | grep -v '^$' | head -n 1)"
    rmdir "$lockdir" 2>/dev/null || true
    if [ -z "$handle" ]; then
      ac_warn "could not identify the split pane in family tab $tab"; return 1
    fi
  else
    # config/orca-node pins the HOME node by FULL SELECTOR. Two Orca worktree
    # entries can share one path (a workspace-scoped entry rides an
    # `::workspace:` id suffix - measured), and a `path:` selector always
    # matches the main entry - so a deputy home living under the same
    # container as its parent fleet needs the id selector to keep its panes
    # on its own sidebar node.
    node_sel="$(ac_config_read orca-node '')"
    [ -n "$node_sel" ] || node_sel="path:$(orca_resolve_group "$home_p")"
    out="$(orca_json terminal create --worktree "$node_sel" --title "crew:$(ac_fleet_name)/$id" \
        --command "$cmd")" || {
      ac_warn "orca terminal create failed for $dir (is the Orca runtime running - orca open / orca serve - and the repo registered: orca repo add --path <repo>?)"
      return 1
    }
    handle="$(jq -r '.result.terminal.handle // empty' <<<"$out")"
    tab="$(jq -r '.result.terminal.tabId // empty' <<<"$out")"
    if [ -z "$handle" ] || [ -z "$tab" ]; then
      ac_warn "could not parse orca terminal create output"; return 1
    fi
    printf '%s\n' "$tab" >"$famf"
  fi
  printf '%s %s\n' "$handle" "$tab"
}

backend_window_new_orca() {
  ac_require orca jq
  local id="$1" dir="$2" placed
  placed="$(orca_place_pane "$dir" "" "$id")" \
    || ac_die "orca pane placement failed for $id at $dir"
  printf '%s\n' "$placed" >"$(ac_pane_file "$id")"
}

backend_window_alive_orca() {
  # Same three-state shape as the herdr driver: `terminal show` is the fast
  # path, its failure is not a verdict - GONE needs the runtime itself to
  # answer (`status`, the control call on the same CLI surface).
  local handle out
  handle="$(orca_pane "$1")"
  [ -n "$handle" ] || return 1        # no handle: a LOCAL fact, really gone
  if out="$(orca_json terminal show --terminal "$handle")"; then
    jq -e '.result.terminal.connected == true' <<<"$out" >/dev/null 2>&1 && return 0
    return 1                          # the runtime answered: disconnected is gone
  fi
  orca_json status >/dev/null 2>&1 && return 1
  return 2
}

backend_capture_pane_orca() {
  local pane="$1" lines="${2:-40}" out
  [ -n "$pane" ] || return 1
  out="$(orca_json terminal read --terminal "$pane" --limit "$lines")" || return 1
  jq -r '.result.terminal.tail[]?' <<<"$out"
}

backend_capture_orca() { backend_capture_pane_orca "$(orca_pane "$1")" "${2:-40}"; }

orca_submit_pane() { orca_json terminal send --terminal "$1" --enter >/dev/null 2>&1; }

orca_submit_verified_pane() {
  # The delivery-verification contract of herdr_submit_verified_pane, on orca
  # primitives: press Enter ONCE, require the render to react, 0/1/2. The
  # press is guarded (|| true) so an unreachable runtime reaches the verdict
  # path instead of aborting the caller under errexit.
  local pane="$1" pre post i=0 tries=7 readable=1
  pre="$(backend_capture_pane_orca "$pane" 15 2>/dev/null)" || readable=0
  orca_submit_pane "$pane" || true
  [ "$readable" = 1 ] || return 2
  while [ "$i" -lt "$tries" ]; do
    sleep "${AC_SEND_SETTLE:-0.4}"
    post="$(backend_capture_pane_orca "$pane" 15 2>/dev/null)" || return 2
    [ "$post" != "$pre" ] && return 0
    i=$((i + 1))
  done
  return 1
}

backend_submit_verified_orca() { orca_submit_verified_pane "$(orca_pane "$1")"; }

orca_type_pane() {
  # Type WITHOUT submitting (`--text` with no `--enter` stays in the
  # composer - measured). CHUNKED at 512 chars: one large --text write
  # measurably lost its head (a ~4.7KB kickoff arrived as its last 723
  # bytes - live, 2026-08-26). Best-effort per chunk: the verified submit
  # is the real check.
  local pane="$1" text="$2" off=0 len
  len=${#text}
  while [ "$off" -lt "$len" ]; do
    orca_json terminal send --terminal "$pane" --text "${text:$off:512}" >/dev/null 2>&1 || true
    off=$((off + 512))
    [ "$off" -lt "$len" ] && sleep 0.05
  done
  return 0
}

orca_focus_pane() { orca_json terminal switch --terminal "$1" >/dev/null 2>&1; }

backend_send_line_orca() {
  local id="$1"
  shift
  local text="$*" rc=0
  orca_type_pane "$(orca_pane "$id")" "$text"
  sleep "${AC_SEND_SETTLE:-0.4}"
  backend_submit_verified_orca "$id" && return 0
  backend_focus_orca "$id" || true
  backend_submit_verified_orca "$id" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 2 ]; then
    printf 'ac-backend: could not read the pane of %s - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh %s)\n' \
      "$(backend_target_orca "$id")" "$id" >&2
    return 2
  fi
  printf 'ac-backend: submit not acknowledged by %s - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh %s --key Enter)\n' \
    "$(backend_target_orca "$id")" "$id" >&2
  return 1
}

backend_send_line_pane_orca() {
  local pane="$1"
  shift
  local text="$*"
  [ -n "$pane" ] || return 1
  orca_type_pane "$pane" "$text"
  sleep "${AC_SEND_SETTLE:-0.4}"
  orca_submit_verified_pane "$pane" && return 0
  orca_focus_pane "$pane" || true
  orca_submit_verified_pane "$pane"
}

orca_send_key_pane() {
  # Key delivery goes straight to the PTY - the herdr unfocused-send-keys
  # quirk has no orca counterpart, so no focus step. Enter is the bare
  # `--enter` flag (measured: submits the composer, empty or not); Escape is
  # the raw ESC byte as text (measured); C-c is `--interrupt` (measured).
  local pane="$1" key="$2"
  case "$key" in
    Enter|enter) orca_json terminal send --terminal "$pane" --enter ;;
    Escape|escape|Esc|esc) orca_json terminal send --terminal "$pane" --text "$(printf '\033')" ;;
    C-c|c-c|ctrl+c|Ctrl+C) orca_json terminal send --terminal "$pane" --interrupt ;;
    *) orca_json terminal send --terminal "$pane" --text "$key" ;;
  esac >/dev/null 2>&1
}

backend_send_key_orca() { orca_send_key_pane "$(orca_pane "$1")" "$2"; }

backend_send_key_pane_orca() {
  [ -n "$1" ] || return 1
  orca_send_key_pane "$1" "$2"
}

backend_kill_window_orca() {
  # Handle uniqueness IS the ownership proof (header of this file), so the
  # close needs no label round-trip. Close the PANE alone - the family tab
  # is shared with siblings and dies by itself with its last pane
  # (measured) - then, when this pane WAS the last, retire the family
  # record so a later spawn creates fresh instead of splitting a corpse.
  # Best-effort like the herdr driver: always 0, always sweeps the files.
  local id="$1" handle tab i=0
  handle="$(orca_pane "$id")"
  tab="$(ac_pane_field "$id" 2)"
  if [ -n "$handle" ]; then
    orca_json terminal close --terminal "$handle" >/dev/null 2>&1 || true
    # The close is ASYNC in the runtime (measured: the pane still lists for a
    # beat) - wait, bounded, for our OWN handle to leave the tab before the
    # emptiness check below can mean anything.
    while [ -n "$tab" ] && [ "$i" -lt 8 ]; do
      case "$(orca_tab_handles "$tab")" in
        *"$handle"*) i=$((i + 1)); sleep 0.25 ;;
        *) break ;;
      esac
    done
  fi
  if [ -n "$tab" ] && [ -z "$(orca_tab_handles "$tab" | head -n 1)" ]; then
    for f in "$(ac_state_dir)"/.orca-fam-*; do
      [ -e "$f" ] || continue
      [ "$(cat "$f" 2>/dev/null)" = "$tab" ] && rm -f "$f"
    done
  fi
  rm -f "$(ac_pane_file "$id")" "$(ac_wait_file "$id")"
}

backend_focus_orca() { orca_focus_pane "$(orca_pane "$1")"; }

backend_agent_blocked_orca() {
  # agentWait names a worker parked on a human-only prompt; null means Orca
  # looked and found no wait, an ABSENT field means it never looked - both
  # answer false here, like herdr's unreadable pane. The captain-wait stamp
  # masks first, exactly as in the herdr driver.
  local handle out
  [ -e "$(ac_wait_file "$1")" ] && return 1
  handle="$(orca_pane "$1")"
  [ -n "$handle" ] || return 1
  out="$(orca_json terminal show --terminal "$handle")" || return 1
  jq -e '.result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1
}

backend_agent_idle_pane_orca() {
  # `wait --for tui-idle` returns the instant the TUI is idle and times out
  # otherwise; 1000ms bounds a working-TUI poll (herdr answers from a status
  # field, orca answers by observing - measured ~113ms on an idle TUI).
  # FLEET PANES: tui-idle NEVER satisfies for a TUI launched from an exec'd
  # shell rather than as the terminal's own command (measured live: an idle
  # claude titled "✳ Claude Code" timed out for 105s straight), so the
  # driver also reads the harness's OWN title glyph - claude settles on a
  # leading ✳ when idle, a working turn shows a spinner glyph instead.
  local pane="$1" t
  [ -n "$pane" ] || return 1
  if orca_json terminal wait --terminal "$pane" --for tui-idle --timeout-ms 1000 2>/dev/null \
    | jq -e '.result.terminal.wait.satisfied == true' >/dev/null 2>&1; then
    return 0
  fi
  t="$(orca_json terminal show --terminal "$pane" 2>/dev/null | jq -r '.result.terminal.title // empty')"
  case "$t" in "✳"*) return 0 ;; esac
  return 1
}

backend_agent_idle_orca() { backend_agent_idle_pane_orca "$(orca_pane "$1")"; }

backend_agent_status_pane_orca() {
  # Raw status enum for callers that need the VALUE, not a boolean
  # (ac-pane-agent's turn-end fallback). Prints idle|working|blocked|unknown
  # and exits 0; unknown covers the unreadable pane and the empty id -
  # printing is the contract, the caller branches on the word.
  local pane="$1" out t
  [ -n "$pane" ] || { printf 'unknown\n'; return 0; }
  out="$(orca_json terminal show --terminal "$pane")" || { printf 'unknown\n'; return 0; }
  if jq -e '.result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1; then
    printf 'blocked\n'; return 0
  fi
  jq -e '.result.terminal.connected == true' <<<"$out" >/dev/null 2>&1 \
    || { printf 'unknown\n'; return 0; }
  if backend_agent_idle_pane_orca "$pane"; then
    printf 'idle\n'; return 0
  fi
  t="$(jq -r '.result.terminal.title // empty' <<<"$out")"
  case "$t" in
    "◐"*|"◓"*|"◑"*|"◒"*|"✻"*|"✽"*|"✢"*|"✶"*|"·"*|"⏺"*) printf 'working\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

backend_harness_up_orca() { backend_harness_up_pane_orca "$(orca_pane "$1")"; }

backend_harness_up_pane_orca() {
  # CAME-UP PROBE (header of this file). UP is only ever PROVEN, never
  # guessed: a title carrying a shell name is a definite SHELL (1), a
  # satisfied tui-idle is a definite TUI (0), and everything else is
  # UNOBSERVABLE (2) - measured live: a themed zsh titles itself with the
  # CWD, so "not a shell name" is no evidence of a harness, and a false UP
  # here would let a kickoff prompt be typed into a bare shell as commands.
  local pane="$1" out title
  [ -n "$pane" ] || return 2
  out="$(orca_json terminal show --terminal "$pane")" || return 2
  jq -e '.result.terminal.connected == true' <<<"$out" >/dev/null 2>&1 || return 2
  title="$(jq -r '.result.terminal.title // empty' <<<"$out")"
  title="${title##*/}"
  title="${title#-}"
  case "$title" in sh|bash|zsh|fish|dash|ksh|tcsh|csh) return 1 ;; esac
  # A leading harness glyph is the TUI's OWN asserted title (claude's
  # measured vocabulary: ✳ idle, ◐/✻/✽/✢/✶/·/⏺ spinner); an ASCII
  # non-shell title (a themed zsh titling itself with the cwd) proves
  # nothing.
  case "$title" in "✳"*|"◐"*|"◓"*|"◑"*|"◒"*|"✻"*|"✽"*|"✢"*|"✶"*|"·"*|"⏺"*) return 0 ;; esac
  backend_agent_idle_pane_orca "$pane" && return 0
  return 2
}

backend_mark_wait_orca() {
  # No external agent-report API in orca (herdr's report-agent/release-agent
  # masking has no counterpart). The stamp FILE is the contract's authority -
  # backend_agent_blocked_orca short-circuits on it - and Orca's own agentWait
  # detection keeps surfacing the wait in its UI; a rename would not stick
  # (the title field is OSC-driven, measured), so none is attempted.
  local id="$1"
  [ -n "$(orca_pane "$id")" ] || return 1
  touch "$(ac_wait_file "$id")"
}

backend_clear_wait_orca() {
  local wf
  wf="$(ac_wait_file "$1")"
  [ -e "$wf" ] || return 0
  rm -f "$wf"
}
