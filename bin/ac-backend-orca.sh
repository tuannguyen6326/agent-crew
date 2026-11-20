#!/usr/bin/env bash
# ac-backend-orca.sh - the orca driver of the session-backend contract.
# Sourced by ac-backend.sh (never an entrypoint); every backend_*_orca here
# implements the surface ac-backend.sh's header documents, same names, same
# three-state return codes:
# - GROUPING (orca_place_pane): chief-kind panes (cwd = the home) sit under
#   the HOME node - config/orca-node's full selector, auto-pinned by
#   orca_home_node from the entry named after the fleet when absent - one
#   FAMILY TAB per room (AC_WINDOW_FAMILY, the same family-resolution ladder
#   used fleet-wide; the tab clears with its last pane); crewmate and
#   verifier panes (cwd = a project/lease worktree) sit under THAT worktree's
#   own node, one tab each - except a dir strictly inside the home with
#   nothing registered between it and the home, which borrows the HOME node
#   too (same selector, still its own tab): a bare `path:` selector there
#   would otherwise be the home itself or its shared container, failing
#   create the same way `worktree show` fails when several entries share
#   that path (selector_ambiguous).
# - No agent-report API: the captain-wait stamp is the FILE alone; Orca's own
#   agentWait detection keeps surfacing waits in its UI (see backend_mark_wait_orca).
# - No process-info verb: the came-up probe reads Orca's OWN agent detection
#   (`terminal show` agentIdentity once a TUI owns the pane, agentWait while a
#   startup dialog holds it - every harness alike) and the terminal TITLE,
#   which tracks the foreground process (measured on orca CLI 1.4.188: a bare
#   shell reports its own name, harness TUIs set an OSC title of their own).
# - Idle vs working is Orca's hook-backed TURN state first (orca_turn_state:
#   the `worktree ps` row keyed by `terminal show`'s recordedPaneKey); the
#   title glyph, tui-idle and codex screen readings cover a pane with no row.
# - Startup dialogs are NAMED (agentWait.reason), so backend_dialog_answer
#   answers the known codex ones with the key safe on each instead of the
#   registry's blind Enter (which runs the upgrade on the update prompt).
# - Reads never prove liveness: a CLOSED terminal still serves `terminal read`
#   from retained scrollback (measured) - liveness comes from `terminal show`
#   `.connected`, with `status` as the control call.
# Handles are runtime-issued UUIDs and never recycled (measured), so the kill
# ownership proof needs no creation-label round-trip: the recorded handle can
# only be this task's terminal.
# orca_place_pane (with orca_resolve_group, orca_home_node and
# orca_tab_handles) and orca_worktree_lease have TypeScript twins in src/lib.ts that
# tests/ts/spawn-twins.test.ts holds to them.

orca_json() {
  # orca_json <args...> - run the orca CLI with --json. Non-zero exit and an
  # ok:false envelope both fail (return 1): the caller's three-state logic
  # decides what a failed call means.
  local out
  out="$(orca "$@" --json 2>/dev/null)" || return 1
  jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

orca_pane() { ac_pane_field "$1" 1; }

backend_target_orca() { printf 'orca:%s\n' "$(orca_pane "$1")"; }

orca_fam_key() {
  # The fleet-wide family-resolution ladder (header: ac-backend.sh FAMILY
  # GROUPING), orca dialect (family -> TAB): AC_WINDOW_FAMILY set non-empty
  # names the family, set EMPTY deliberately targets the fleet ROOT group,
  # unset derives the family from the task id via ac_window_family.
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
  # path selector resolves OR that `worktree show` reports selector_ambiguous
  # for (several entries share it - still a registered ancestor, so the walk
  # stops there instead of overshooting to the next one, also unresolvable,
  # on its way to a selector_not_found that names the wrong fix). Any other
  # failure (selector_not_found: measured after a repo registration was
  # removed) keeps walking. Falls back to the path itself when nothing
  # matches, so the create's own error stays the one that names the fix.
  local p="$1" out
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    out="$(orca worktree show --worktree "path:$p" --json 2>/dev/null)"
    if jq -e '.ok == true or .error.code == "selector_ambiguous"' <<<"$out" >/dev/null 2>&1; then
      printf '%s\n' "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done
  printf '%s\n' "$1"
}

# The entries sharing one path, and among them the one whose displayName ends
# with the fleet name as a token of its own ("ac example-fleet" for
# example-fleet, "ac example-fleet/ops" for the deputy ops): PIN <id> <name>
# when exactly one, AMBIG <all> <hits>
# <candidates> when several entries share the path and no single one is the
# fleet's, NONE otherwise. Shared with the src/lib.ts twin verbatim.
orca_node_jq='[.result.worktrees[]? | select(.path == $p)] as $all
  | ($all | map(select((.displayName // "") as $d | ($d | endswith($f))
      and (($d | length) == ($f | length) or ($d[:(($d | length) - ($f | length))] | .[-1:] | IN("/", " ")))))) as $hit
  | if ($hit | length) == 1 then "PIN\t" + $hit[0].id + "\t" + ($hit[0].displayName // "")
    elif ($all | length) > 1 then "AMBIG\t" + ($all | length | tostring) + "\t" + ($hit | length | tostring)
      + "\t" + ($all | map(.id + " (" + (.displayName // "") + ")") | join("; "))
    else "NONE" end'

orca_home_node() {
  # orca_home_node <home_p> - the selector a chief-kind pane is created at
  # when config/orca-node is absent. Two Orca entries can share one path (a
  # workspace-scoped entry rides an `::workspace:` id suffix - measured) and a
  # `path:` selector always matches the main entry, so a deputy home under
  # its parent's container landed on the parent's node until the captain
  # pinned the id selector by hand; the pin is derived here instead, from the
  # entry named after the fleet (orca_node_jq), and WRITTEN so it reads like a
  # hand pin from then on. No or several candidates keep the path selector:
  # warned when the path is shared (the very case the pin exists for), silent
  # when one entry owns it.
  local home_p="$1" anc fleet list kind a b c
  anc="$(orca_resolve_group "$home_p")"
  fleet="$(ac_fleet_name)"
  if ! list="$(orca_json worktree list)"; then
    ac_warn "orca-node not pinned - orca worktree list failed; the pane goes to path:$anc"
    printf 'path:%s\n' "$anc"; return 0
  fi
  IFS="$(printf '\t')" read -r kind a b c <<<"$(jq -r --arg p "$anc" --arg f "$fleet" "$orca_node_jq" <<<"$list")"
  case "$kind" in
    PIN)
      printf 'id:%s\n' "$a" >"$(ac_config_dir)/orca-node"
      printf 'orca-node: pinned id:%s (%s)\n' "$a" "$b" >&2
      printf 'id:%s\n' "$a" ;;
    AMBIG)
      ac_warn "orca-node not pinned - $a Orca entries share $anc, $b named '$fleet': $c - write config/orca-node by hand"
      printf 'path:%s\n' "$anc" ;;
    *) printf 'path:%s\n' "$anc" ;;
  esac
}

orca_worktree_lease() {
  # orca_worktree_lease <id> <repo> [<base-branch-override>] - an
  # Orca-managed worktree for a crewmate: one worktree per task, leased
  # through the Orca CLI, sidebar-native. Cut from the repo's LIVE CHECKOUT
  # branch, resolved to its FRESHEST tip via ac_freshest_ref (local vs
  # origin, origin wins on true divergence) - NEVER ac_default_branch,
  # which answers "what branch does this repo default to" and has no idea
  # which branch the live checkout is actually on
  # (orca-lease-cuts-from-wrong-branch: measured, a checkout on a
  # non-default branch leased out of main entirely, missing whole
  # directories). A DETACHED live checkout (no branch to read) is cut from
  # its exact HEAD commit instead - never ac_default_branch's fallback,
  # which would silently pick an unrelated branch, and never
  # ac_freshest_ref, which has no "local vs origin" question to answer for
  # a commit that is not on any branch. This is what a checkout can be
  # AHEAD of its own branch ref while detached (the branch ref and
  # origin's tracking ref both stay put) reconciles: the branch NAME
  # resolves "correctly" yet a name-based lookup still lands behind,
  # because neither ref moved - measured against one room's own
  # evidence (correct branch, 7 commits behind, no symptom). The optional
  # 3rd arg (ac-self-task.sh/ac-spawn.sh's own --base-branch) names the
  # branch explicitly and wins over the live checkout (detached or not),
  # but still resolves through ac_freshest_ref - an override names WHICH
  # branch, not which tip. EPIC-BRANCH FENCE (epic-branch-mech): an <id>
  # whose ledger row resolves an integration branch for this repo
  # (ac_epic_base_for) is cut from that branch as the override, under
  # ac-tree.sh get's own existence rule, and refused before anything is
  # created when that branch is missing, the ledger cannot be read, or an
  # override names another branch. It lives HERE too (duplicated from get,
  # not shared) so every orca lease path (crew spawn, self task, verifier)
  # rides it.
  # Like get it fetches origin first (best effort: a failed fetch warns and
  # judges local refs), so a predecessor merged into the epic branch on
  # origin is in the next story's base; an unfenced lease never fetches.
  # Measured against the real orca CLI (1.4.190,
  # `worktree create --base-branch`): a bare name resolves the LOCAL
  # branch tip, `origin/<name>` resolves the remote-tracking tip, and a
  # raw commit SHA resolves to exactly that commit - the first two are
  # ac_freshest_ref's own two return shapes, so its output is passed
  # straight through with no translation; the third is what the detached
  # arm below uses directly. Repo-defined setup hooks running and no
  # lineage parent (the CLI otherwise infers the CALLER's active worktree
  # as parent - measured). The primary checkout's node_modules rides over
  # as a clone when the hooks have not already produced one: git carries
  # only tracked files, and a fresh install per task is the cost the
  # clone removes. A COPY (APFS clonefile when available), never a
  # symlink - a crewmate's own install must not mutate the primary's
  # deps. The CLI names the branch <git-user>/<name>; the crew contract
  # owns the task's crew branch (ac_crew_branch: crew/<family>, the one the
  # brief names and merge-local lands), so the checkout is switched there
  # (adopting an existing one on a respawn or a revision) and the minted
  # name dropped; a switch git refuses gives the new worktree back. Prints
  # the path; 1 on failure, 2 when the fence refuses (warned, nothing
  # created).
  local id="$1" repo="$2" override="${3:-}" out path obranch base ref st cb
  local rname eb ebrc=0 ebranch ebref
  rname="$(basename "$repo")"
  eb="$(ac_epic_base_for "$id" "$rname" 2>/dev/null)" || ebrc=$?
  if [ "$ebrc" = 2 ]; then
    ac_warn "cannot read the ledger to resolve the epic-branch fence for $id - nothing was leased"
    return 2
  fi
  if [ "$ebrc" = 0 ]; then
    ebranch="${eb%% *}"
    if [ -n "$override" ] && [ "$override" != "$ebranch" ]; then
      ac_warn "--base-branch $override disagrees with the epic-branch fence for $id (recorded integration branch $ebranch in $rname) - nothing was leased; drop the flag or name $ebranch"
      return 2
    fi
    if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      git -C "$repo" fetch origin --quiet 2>/dev/null \
        || ac_warn "fetch origin failed; judging the epic-branch fence for $id on local refs"
    fi
    case " ${eb#"$ebranch"} " in
      *" push=deferred "*) ebref="refs/heads/$ebranch" ;;
      *) if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
           ebref="refs/remotes/origin/$ebranch"
         else
           ebref="refs/heads/$ebranch"
         fi ;;
    esac
    if ! git -C "$repo" show-ref --verify --quiet "$ebref"; then
      ac_warn "integration branch $ebranch for $id is missing ($ebref does not exist in $rname) - nothing was leased; cut it first: ac-epic-branch.sh create <epic> $rname (ac-feature.sh create <feature> $rname for a push=deferred entry)"
      return 2
    fi
    override="$ebranch"
  fi
  if [ -n "$override" ]; then
    ref="$(ac_freshest_ref "$repo" "$override")"
  elif base="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" && [ -n "$base" ]; then
    ref="$(ac_freshest_ref "$repo" "$base")"
  else
    ref="$(git -C "$repo" rev-parse HEAD)"
  fi
  # The create's path: selector resolves only a REGISTERED repo (measured:
  # selector_not_found after a registration was removed), so an unregistered
  # one is registered here instead of dying with a hand-typed fix. Show-then-
  # add, never a blind add: repo add on an already-registered path fails
  # runtime_error (measured 1.4.x). An add failure only warns - the create
  # below stays the error that names the fix.
  orca_json repo show --repo "path:$repo" >/dev/null 2>&1 \
    || orca_json repo add --path "$repo" >/dev/null 2>&1 \
    || ac_warn "orca repo add failed for $repo"
  out="$(orca_json worktree create --repo "path:$repo" --name "crew-$id" \
      --base-branch "$ref" --setup run --no-parent)" || return 1
  path="$(jq -r '.result.worktree.path // empty' <<<"$out")"
  if [ -z "$path" ] || [ ! -d "$path" ]; then
    # An ok answer with no usable path still REGISTERED a worktree in the
    # runtime - releasing it by id is the only cleanup a pathless create
    # allows (the rm takes any terminals with it). Best-effort: the lease
    # fails either way, but a leak nothing will ever clean must not be the
    # default outcome.
    wt_id="$(jq -r '.result.worktree.id // empty' <<<"$out")"
    [ -z "$wt_id" ] || orca_json worktree rm --worktree "id:$wt_id" --force >/dev/null 2>&1 || true
    return 1
  fi
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
  cb="$(ac_crew_branch "$id")"
  if git -C "$path" show-ref --verify -q "refs/heads/$cb"; then
    git -C "$path" switch "$cb" >/dev/null 2>&1 || { orca_worktree_release "$path"; return 1; }
  else
    git -C "$path" switch -c "$cb" >/dev/null 2>&1 || { orca_worktree_release "$path"; return 1; }
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
  # print "<handle> <tab>". A verification pane passes its RUNCMD as the
  # pane's --command so the agent starts WITH the pane; without one the pane
  # is moved to <dir> by a `cd '<dir>'` TYPED and submitted through the send
  # queue (orca_type_cd), never by --command: Orca types --command only once
  # the shell prompt is up (measured on Orca 1.4.244), and the caller's
  # launch line, typed right after placement, landed in FRONT of it on one
  # shell line. The typed cd shares that queue, so it runs first. <id> feeds
  # the family ladder and the creation title. Returns 1 on failure (prints
  # nothing, warns) so callers own their own death message.
  local dir="$1" cmd="${2:-}" id="${3:-agent}" out handle tab fam famf base before lockdir i dir_p home_p node_sel grp
  local -a cmd_args=()
  [ -z "$cmd" ] || cmd_args=(--command "$cmd")
  orca_type_cd() {
    [ -z "$cmd" ] || return 0
    orca_json terminal send --terminal "$1" --text "cd '$dir'" >/dev/null \
      && orca_json terminal send --terminal "$1" --enter >/dev/null \
      || ac_warn "could not type the cd into orca terminal $1 - the pane may sit at its node's root instead of $dir"
  }
  # Creation titles carry the fleet token (crew:<fleet>/<id>) - display-only,
  # parsed by nothing: two fleets under one container (a deputy beside its
  # parent) render identical bare titles in mixed tab lists otherwise. The
  # harness overwrites the title once it boots; the prefix covers the gap.
  # GROUPING RULE: chief-kind panes (cwd = the HOME) group under the home's
  # sidebar node with one FAMILY TAB per room; crewmate and verifier panes
  # (cwd = a project/lease worktree) group under THAT worktree's own node,
  # one tab each - the Orca-native shape, sessions beside their diffs. A dir
  # strictly inside the home with nothing registered between it and the home
  # groups under the HOME's node instead (still its own tab, no family
  # split): the walk's own group there lands AT OR ABOVE the home, so a bare
  # `path:` selector would be the home itself or its shared container -
  # possibly ambiguous, failing create the same way it fails `worktree show`.
  dir_p="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
  # A homeless caller (a crewmate-invoked verifier) has no AC_HOME and never
  # places a chief-kind pane - resolve to empty so it takes the worker arm
  # quietly instead of ac_home's refusal leaking into the pane-result stream.
  home_p=""
  [ -z "${AC_HOME:-}" ] || home_p="$(cd "$AC_HOME" 2>/dev/null && pwd -P || true)"
  if [ "$dir_p" != "$home_p" ]; then
    grp="$(orca_resolve_group "$dir_p")"
    node_sel="path:$grp"
    if [ -n "$home_p" ]; then
      case "$dir_p" in
        "$home_p"/*)
          case "$home_p" in
            "$grp"|"$grp"/*)
              node_sel="$(ac_config_read orca-node '')"
              [ -n "$node_sel" ] || node_sel="$(orca_home_node "$home_p")" ;;
          esac ;;
      esac
    fi
    out="$(orca_json terminal create --worktree "$node_sel" --title "crew:$(ac_fleet_name)/$id" \
        ${cmd_args[@]+"${cmd_args[@]}"})" || {
      ac_warn "orca terminal create failed for $dir (is the Orca runtime running - orca open / orca serve - and the repo registered: orca repo add --path <repo>?)"
      return 1
    }
    handle="$(jq -r '.result.terminal.handle // empty' <<<"$out")"
    tab="$(jq -r '.result.terminal.tabId // empty' <<<"$out")"
    if [ -z "$handle" ] || [ -z "$tab" ]; then
      ac_warn "could not parse orca terminal create output"; return 1
    fi
    orca_type_cd "$handle"
    printf '%s %s\n' "$handle" "$tab"
    return 0
  fi
  # HOME ARM (chief-kind panes). FAMILY TABS under the home node: the
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
        ${cmd_args[@]+"${cmd_args[@]}"} >/dev/null; then
      rmdir "$lockdir" 2>/dev/null || true
      ac_warn "orca terminal split failed (family tab $tab)"; return 1
    fi
    handle="$(comm -13 <(printf '%s\n' "$before") <(orca_tab_handles "$tab") | grep -v '^$' | head -n 1)"
    rmdir "$lockdir" 2>/dev/null || true
    if [ -z "$handle" ]; then
      ac_warn "could not identify the split pane in family tab $tab"; return 1
    fi
    orca_type_cd "$handle"
  else
    node_sel="$(ac_config_read orca-node '')"
    [ -n "$node_sel" ] || node_sel="$(orca_home_node "$home_p")"
    out="$(orca_json terminal create --worktree "$node_sel" --title "crew:$(ac_fleet_name)/$id" \
        ${cmd_args[@]+"${cmd_args[@]}"})" || {
      ac_warn "orca terminal create failed for $dir (is the Orca runtime running - orca open / orca serve - and the repo registered: orca repo add --path <repo>?)"
      return 1
    }
    handle="$(jq -r '.result.terminal.handle // empty' <<<"$out")"
    tab="$(jq -r '.result.terminal.tabId // empty' <<<"$out")"
    if [ -z "$handle" ] || [ -z "$tab" ]; then
      ac_warn "could not parse orca terminal create output"; return 1
    fi
    orca_type_cd "$handle"
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
  # Three-state (header: WINDOW LIVENESS): `terminal show` is the fast
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
  # --screen, never the default read: the CLI's default returns ACCUMULATED
  # output, so a full-screen TUI sitting still comes back EMPTY (its own help
  # calls that default unsuitable for verifying rendered output) and a
  # repainting one comes back as stacked fragments. Every caller of this verb
  # asks what the pane SHOWS - did the harness come up, did the submit land,
  # did a captain marker appear - which is the rendered screen.
  local pane="$1" lines="${2:-40}" out
  [ -n "$pane" ] || return 1
  out="$(orca_json terminal read --terminal "$pane" --limit "$lines" --screen)" || return 1
  jq -r '.result.terminal.tail[]?' <<<"$out"
}

backend_capture_orca() { backend_capture_pane_orca "$(orca_pane "$1")" "${2:-40}"; }

orca_submit_pane() { orca_json terminal send --terminal "$1" --enter >/dev/null 2>&1; }

orca_composer_pending() {
  # orca_composer_pending <pane> <text> - is <text> still sitting UNSUBMITTED
  # in the pane's composer? The composer is the region between the LAST TWO
  # horizontal rules of the rendered screen (measured live on a claude TUI:
  # the transcript echoes a submitted line with the SAME glyph the composer
  # uses, so text-anywhere is no verdict - only the between-rules region
  # tells pending from submitted). 0 = pending PROVEN; 1 = not proven - a
  # screen with no rule structure (another harness's shape, an unreadable
  # pane) never claims pending, so the caller keeps today's verdict.
  local pane="$1" text="$2" cap r1 r2 region want
  # </dev/null: a read never needs the caller's stdin, whatever the caller's
  # own send calls were asked to inherit.
  cap="$(backend_capture_pane_orca "$pane" 15 2>/dev/null </dev/null)" || return 1
  # LC_ALL=C + a GROUPED repeat: an interval over the bare 3-byte glyph binds
  # to its LAST byte under a C locale and never matches (measured on this
  # host) - a watcher or hook running with a minimal env would silently
  # revive the false-"sent" class this function closes. The group repeats
  # the whole byte sequence, which matches identically under any locale.
  r2="$(printf '%s\n' "$cap" | LC_ALL=C grep -n '\(─\)\{8,\}' | tail -1 | cut -d: -f1)"
  r1="$(printf '%s\n' "$cap" | LC_ALL=C grep -n '\(─\)\{8,\}' | tail -2 | head -1 | cut -d: -f1)"
  [ -n "$r1" ] && [ -n "$r2" ] && [ "$r1" -lt "$r2" ] || return 1
  # Normalize both sides (the composer soft-wraps long text) and compare a
  # bounded head - enough to identify the steer, immune to wrap points.
  region="$(printf '%s\n' "$cap" | sed -n "$((r1 + 1)),$((r2 - 1))p" | tr '\n' ' ' | tr -s ' ')"
  want="$(printf '%s' "$text" | tr '\n' ' ' | tr -s ' ' | cut -c1-60)"
  [ -n "$want" ] || return 1
  case "$region" in *"$want"*) return 0 ;; esac
  return 1
}

orca_submit_verified_pane() {
  # Delivery verification (header: ac-backend.sh): press Enter ONCE, require
  # the render to react, 0/1/2. The press is guarded (|| true) so an
  # unreachable runtime reaches the verdict path instead of aborting the
  # caller under errexit.
  # With <text> given, a reacted render alone is NOT a submit: a popup
  # closing on the Enter changes the render while the text sits pending
  # (measured class), so the composer region is checked and a proven-pending
  # text buys a bounded retry Enter - guarded per press by agentWait, so a
  # dialog that appeared mid-send is never blind-accepted by a retry.
  local pane="$1" text="${2:-}" pre post i=0 tries=7 retries=0
  local readable=1
  # A DIALOG-owned pane refuses BEFORE the first press, with its own verdict
  # (3): every Enter into a dialog answers it, and the digit options can
  # grant a permanent always-allow - a caller must never turn this verdict
  # into a focus-and-retry press.
  orca_pane_dialog "$pane" && return 3
  pre="$(backend_capture_pane_orca "$pane" 15 2>/dev/null </dev/null)" || readable=0
  orca_submit_pane "$pane" || true
  [ "$readable" = 1 ] || return 2
  while [ "$i" -lt "$tries" ]; do
    sleep "${AC_SEND_SETTLE:-0.4}"
    post="$(backend_capture_pane_orca "$pane" 15 2>/dev/null </dev/null)" || return 2
    [ "$post" != "$pre" ] && break
    i=$((i + 1))
  done
  [ "$i" -lt "$tries" ] || return 1
  [ -n "$text" ] || return 0
  while orca_composer_pending "$pane" "$text"; do
    [ "$retries" -lt 2 ] || return 1
    orca_pane_dialog "$pane" && return 3
    orca_submit_pane "$pane" || true
    sleep "${AC_SEND_SETTLE:-0.4}"
    retries=$((retries + 1))
  done
  return 0
}

orca_pane_dialog() {
  # 0 when the runtime reports the pane parked on a human-only prompt
  # (agentWait non-null); any unreadable answer is NOT a dialog verdict.
  # </dev/null: a read never needs the caller's stdin.
  orca_json terminal show --terminal "$1" 2>/dev/null </dev/null \
    | jq -e '.result.terminal.agentWait != null' >/dev/null 2>&1
}

backend_submit_verified_orca() { orca_submit_verified_pane "$(orca_pane "$1")" "${2:-}"; }

orca_focus_pane() { orca_json terminal switch --terminal "$1" >/dev/null 2>&1; }

orca_prompt_send_pane() {
  # One Orca prompt delivery (probe on Orca 1.4.259): a recognized
  # agent gets the text bracket-pasted with Enter and a receipt saying
  # whether Orca OBSERVED the submit; anything else gets the text and Enter
  # raw. 0 sent, 1 stranded, 2 no receipt (never resent - a resend could
  # deliver twice), 3 a dialog owns the pane.
  # The agentWait guard stays ahead of Orca's own agent_prompt_blocked
  # refusal: that refusal was measured on a trust prompt only, and an Enter
  # into any other dialog answers it.
  local pane="$1" text="$2" out verdict retries=0
  orca_pane_dialog "$pane" && return 3
  out="$(orca terminal send --terminal "$pane" --text "$text" --enter --wait-submit 3 --json 2>/dev/null)" || true
  verdict="$(jq -r 'if .ok == true then (if .result.send.prompt.observation == "supported" then "seen" else "blind" end)
    elif .error.code == "agent_prompt_blocked" then "blocked" else "failed" end' <<<"$out" 2>/dev/null)" || true
  case "$verdict" in
    seen) return 0 ;;
    blocked) return 3 ;;
    blind) ;;
    *) return 2 ;;
  esac
  # "seen" holds at input_accepted alone: mid-turn, Orca queues the prompt
  # and delivers it after the turn (probe above). Only an unobserved
  # send is checked here, and only a text PROVEN pending buys a retry Enter -
  # never a retype.
  while orca_composer_pending "$pane" "$text"; do
    [ "$retries" -lt 2 ] || return 1
    orca_pane_dialog "$pane" && return 3
    orca_submit_pane "$pane" || true
    sleep "${AC_SEND_SETTLE:-0.4}"
    retries=$((retries + 1))
  done
  return 0
}

backend_send_line_orca() {
  local id="$1"
  shift
  local text="$*" rc=0
  orca_prompt_send_pane "$(orca_pane "$id")" "$text" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 3 ]; then
    printf 'ac-backend: a DIALOG owns the pane of %s - the text was not submitted and no Enter was pressed into the dialog (an Enter would ACCEPT the highlighted option). Peek it (ac-peek.sh %s) and answer deliberately with ac-send.sh %s --key <key>\n' \
      "$(backend_target_orca "$id")" "$id" "$id" >&2
    return 1
  fi
  if [ "$rc" = 2 ]; then
    printf 'ac-backend: no delivery receipt from %s - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh %s)\n' \
      "$(backend_target_orca "$id")" "$id" >&2
    return 2
  fi
  printf 'ac-backend: submit not acknowledged by %s - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh %s --key Enter)\n' \
    "$(backend_target_orca "$id")" "$id" >&2
  return 1
}

backend_send_line_pane_orca() {
  [ -n "$1" ] || return 1
  local pane="$1" prc=0
  shift
  orca_prompt_send_pane "$pane" "$*" || prc=$?
  [ "$prc" = 3 ] && return 1
  return "$prc"
}

orca_send_key_pane() {
  # Key delivery goes straight to the PTY, no focus step. Enter is the bare
  # `--enter` flag (measured: submits the composer, empty or not); Escape is
  # the raw ESC byte as text (measured); C-c is `--interrupt` (measured);
  # Down is the raw ANSI down-arrow escape as text (measured: moves claude's
  # trust-dialog highlight - harness-facts.md, claude STARTUP TRUST DIALOG) -
  # every other name falls to the default and is typed as literal characters,
  # which a named arrow key must never do.
  local pane="$1" key="$2"
  case "$key" in
    Enter|enter) orca_json terminal send --terminal "$pane" --enter ;;
    Escape|escape|Esc|esc) orca_json terminal send --terminal "$pane" --text "$(printf '\033')" ;;
    Down|down) orca_json terminal send --terminal "$pane" --text "$(printf '\033[B')" ;;
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
  # Best-effort: always 0, always sweeps the files.
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
  # answer false here. The captain-wait stamp masks first (header: CAPTAIN-
  # WAIT STAMP, ac-backend.sh).
  local handle out
  [ -e "$(ac_wait_file "$1")" ] && return 1
  handle="$(orca_pane "$1")"
  [ -n "$handle" ] || return 1
  out="$(orca_json terminal show --terminal "$handle")" || return 1
  jq -e '.result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1
}

orca_turn_state() {
  # orca_turn_state <show-json> - the turn state Orca's agent hooks record
  # for this pane, empty when it has none (probe on orca 1.4.259):
  # `worktree ps` rows are keyed by the paneKey `terminal show` reports as
  # recordedPaneKey - never `terminal list`'s tabId/leafId, which differ for
  # a headless pane. mainAgent is the TURN: a claude whose turn ended under
  # a background task reads state working, mainAgent done; cursor and pi
  # report no mainAgent, so their row's own state stands in. A row without
  # a live PTY vouches for nothing, and neither does one in a pane where
  # Orca identifies no agent: a row that outlived its agent would read a
  # bare shell as idle, and harness_up would call that shell UP.
  local key
  key="$(jq -r 'if .result.terminal.agentIdentity == null then empty else .result.terminal.recordedPaneKey // empty end' <<<"$1" 2>/dev/null)"
  [ -n "$key" ] || return 0
  orca_json worktree ps 2>/dev/null | jq -r --arg k "$key" '
    first((.result.worktrees // [])[] | (.agents // [])[] | select(.paneKey == $k and .hasLivePty == true))
    | .mainAgent.state // .state // empty' 2>/dev/null || true
}

backend_agent_idle_pane_orca() {
  # Orca's hook-backed turn state decides first (orca_turn_state): done is
  # idle; working, blocked and waiting (its documented vocabulary) are not.
  # No row, an unreadable ps or any other value falls through to the
  # heuristics below, which predate it and still cover a pane Orca's hooks
  # never reached.
  # `wait --for tui-idle` returns the instant the TUI is idle and times out
  # otherwise; 1000ms bounds a working-TUI poll (orca answers by observing
  # the render rather than a status field - measured ~113ms on an idle TUI).
  # Two TUIs, two readings, both measured: for claude on a FLEET pane (TUI
  # launched from an exec'd shell rather than as the terminal's own command)
  # tui-idle NEVER satisfies (an idle "✳ Claude Code" timed out for 105s
  # straight), so the driver reads claude's OWN title glyph - a leading ✳
  # when idle, a spinner glyph mid-turn. For codex tui-idle satisfies under
  # its braille spinner too (0.150.1), so the spinner, not tui-idle, tells
  # working from idle - and on 0.159.2 (orca 1.4.215) tui-idle never
  # satisfied on a ready composer before the pane's first turn, so a
  # spinner-free codex also reads idle when its screen did not change across
  # the wait's timed-out window (a working codex repaints its elapsed-time
  # line every second). Only a TIMEOUT is a window: a wait that failed
  # outright observed nothing, and a dead terminal keeps serving its last
  # screen. A pane parked on a dialog (agentWait) is never idle: the
  # composer does not exist yet.
  local pane="$1" out t before="" waited
  [ -n "$pane" ] || return 1
  out="$(orca_json terminal show --terminal "$pane" 2>/dev/null)" || return 1
  jq -e '.result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1 && return 1
  case "$(orca_turn_state "$out")" in
    done) return 0 ;;
    working|blocked|waiting) return 1 ;;
  esac
  t="$(jq -r '.result.terminal.title // empty' <<<"$out")"
  orca_title_spinner "$t" && return 1
  case "$t" in "✳"*) return 0 ;; esac
  if jq -e '.result.terminal.agentIdentity == "codex"' <<<"$out" >/dev/null 2>&1; then
    before="$(backend_capture_pane_orca "$pane" 40 2>/dev/null)" || before=""
  fi
  # The envelope is {"result":{"wait":{"satisfied":..}}} (measured on orca
  # CLI 1.4.188 - an earlier reading assumed a `terminal` level that the
  # real CLI does not emit, which read every satisfied wait as unsatisfied).
  waited="$(orca terminal wait --terminal "$pane" --for tui-idle --timeout-ms 1000 --json 2>/dev/null)" || true
  jq -e '(.result.wait.satisfied // .result.terminal.wait.satisfied) == true' <<<"$waited" >/dev/null 2>&1 && return 0
  [ -n "$before" ] || return 1
  jq -e '.error.code == "timeout"' <<<"$waited" >/dev/null 2>&1 || return 1
  [ "$(backend_capture_pane_orca "$pane" 40 2>/dev/null)" = "$before" ]
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
  if orca_title_spinner "$t"; then printf 'working\n'; else printf 'unknown\n'; fi
}

backend_dialog_answer_orca() { backend_dialog_answer_pane_orca "$(orca_pane "$1")"; }

backend_dialog_answer_pane_orca() {
  # STARTUP DIALOGS BY NAME (contract: ac-backend.sh header, backend_dialog_answer).
  # Orca names the dialog a pane is parked on (agentWait.reason, from its
  # prompt-text detection - measured on codex 0.150.1: "codex-update-prompt",
  # then "codex-hooks-review-prompt" in a repo carrying .codex/hooks.json,
  # both BEFORE the composer exists). The driver answers the ones it knows
  # with the key that is safe on THAT dialog: a digit selects and confirms
  # (measured), and a bare Enter is exactly the wrong key on the update
  # prompt - its highlighted default is "Update now", which runs the
  # upgrade and left a crewmate mid-install and never booting. The hooks
  # prompt's "Trust all and continue" is the fleet's posture: the hooks are
  # the repo's own tracked files, run at the same trust as its scripts and
  # tests, and "continue without trusting" would silently disarm the fleet
  # guards on a codex primary. An unknown dialog gets NO keystroke - the
  # caller falls back to the registry's blind key (the trust dialog's
  # Enter) - and every read failure is unobservable, never "no dialog".
  #   0 answered one dialog (another may follow - call again)
  #   1 nothing pending
  #   2 a dialog the driver cannot name
  #   3 unobservable
  local pane="$1" out reason key
  [ -n "$pane" ] || return 3
  out="$(orca_json terminal show --terminal "$pane")" || return 3
  jq -e '.result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1 || return 1
  reason="$(jq -r '.result.terminal.agentWait.reason // empty' <<<"$out" 2>/dev/null)"
  case "$reason" in
    codex-update-prompt) key=2 ;;
    codex-hooks-review-prompt) key=2 ;;
    *) return 2 ;;
  esac
  orca_json terminal send --terminal "$pane" --text "$key" >/dev/null 2>&1 || return 3
  return 0
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
  # Orca's OWN harness detection, every harness alike (measured on codex
  # 0.150.1 in both pane shapes): agentIdentity names the TUI once it owns
  # the pane, and a startup dialog rides agentWait while the exec'd shell's
  # title still reads "cd" - a dialog IS a harness, parked, never a shell.
  jq -e '.result.terminal.agentIdentity != null or .result.terminal.agentWait != null' <<<"$out" >/dev/null 2>&1 && return 0
  # A leading harness glyph is the TUI's OWN asserted title (claude's
  # measured vocabulary: ✳ idle, ◐/✻/✽/✢/✶/·/⏺ spinner; codex: a braille
  # spinner while working); an ASCII non-shell title (a themed zsh titling
  # itself with the cwd, codex's idle cwd-basename title) proves nothing.
  case "$title" in "✳"*) return 0 ;; esac
  orca_title_spinner "$title" && return 0
  backend_agent_idle_pane_orca "$pane" && return 0
  return 2
}

orca_title_spinner() {
  # The working-turn title glyphs the TUIs assert themselves: claude's
  # spinner set, and codex's braille spinner (U+2800-28FF, UTF-8 E2 A0-A3
  # xx; measured "⠇ <cwd>" mid-turn on 0.150.1). The byte-range match is
  # deliberate: which braille cell shows is a frame of the animation.
  case "$1" in
    "◐"*|"◓"*|"◑"*|"◒"*|"✻"*|"✽"*|"✢"*|"✶"*|"·"*|"⏺"*) return 0 ;;
    $'\xe2\xa0'*|$'\xe2\xa1'*|$'\xe2\xa2'*|$'\xe2\xa3'*) return 0 ;;
  esac
  return 1
}

backend_mark_wait_orca() {
  # No external agent-report API in orca. The stamp FILE is the contract's authority -
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
