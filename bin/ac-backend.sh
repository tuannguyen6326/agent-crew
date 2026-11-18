#!/usr/bin/env bash
# ac-backend.sh - session backend primitives: ONE contract, implemented by
# the Orca driver (ac-backend-orca.sh), routed per call at the end of this
# file. Sourced, not an entrypoint.
#
# Backend selection: $AC_BACKEND (consumers export it from the task meta's
# `backend=` key), else config/backend, else the fleet's config/backend
# found through AC_FLEET_STATE (a homeless crewmate's channel), else orca -
# and every value other than `orca` is refused.
#
# Surface (all keyed by crewmate id):
#   backend_window_new <id> <dir>     create the pane/window, default shell
#   backend_window_alive <id>         does the pane exist? Three-state, like the
#                                     submit verifier and the came-up probe and
#                                     for the same reason (see WINDOW LIVENESS
#                                     below): a backend that could not be READ is
#                                     not reported as a dead pane
#   backend_send_line <id> <text>     send the text with its Enter as ONE
#                                     Orca prompt, submit VERIFIED (see
#                                     delivery verification below), then
#                                     non-zero + stderr - exit 1 the text is
#                                     stranded in the composer OR a dialog
#                                     owns the pane (its own stderr message
#                                     says which - an Enter into a dialog
#                                     would ANSWER it, never submit the
#                                     text), exit 2 Orca gave no delivery
#                                     receipt, so whether the text was
#                                     submitted is unknown; the CALLER
#                                     decides what each one means
#   backend_submit_verified <id>      press Enter, ack by capture-change; the
#                                     resubmit primitive for callers retrying
#                                     a stranded line (re-TYPING would append
#                                     to the composer and garble it). Same
#                                     three-state status: 0 accepted, 1
#                                     strand, 2 unobservable
#   backend_send_key <id> <Enter|Escape|Down|C-c>
#                                     focus the tab, then press the key -
#                                     delivery is UNVERIFIED (see below): a
#                                     bare key has no guaranteed observable
#   backend_capture <id> [lines=40]
#   backend_capture_pane <pane-id> [lines=40]
#                                     the same read addressed by a RAW pane
#                                     id, for a pane with NO state/.pane-<id>
#                                     handle - a pane agent (ac-pane-agent.sh)
#                                     holds only the raw id the backend handed
#                                     it, so the id-keyed verbs cannot reach
#                                     it. Fails
#                                     closed on an empty pane id. Its twin is
#                                     src/lib-verify.ts's backendCapturePane
#                                     (tests/ts/verify-twins.test.ts).
#   backend_send_line_pane <pane-id> <text>
#                                     send_line in that same raw-pane
#                                     addressing, with the SAME verified-submit
#                                     semantics and the same status (1
#                                     stranded or a dialog, 2 no receipt).
#                                     It prints nothing: the
#                                     caller owns the message, because only the
#                                     caller knows what to call the pane
#                                     (ac-pane-agent.sh steer names the handle),
#                                     and the status is how it tells the two
#                                     failures apart. Fails closed on an empty
#                                     pane id.
#   backend_send_key_pane <pane-id> <Enter|Escape|Down|C-c>
#                                     send_key in that same raw-pane addressing
#                                     (the pane agent's crewmate arm answers a
#                                     codex startup dialog with it, exactly as
#                                     ac-spawn.sh does for a crewmate). Delivery
#                                     stays UNVERIFIED for the same reason.
#   backend_dialog_answer <id>        answer the STARTUP DIALOG the pane is
#   backend_dialog_answer_pane <pane-id>
#                                     parked on, BY NAME (orca: agentWait.reason).
#                                     Four states: 0 answered one dialog
#                                     (another may follow - call again),
#                                     1 nothing pending, 2 a named dialog the
#                                     driver knows no MEASURED key for (the
#                                     caller falls back to the registry's
#                                     blind key), 3 unobservable - the pane
#                                     could not be classified at all, so the
#                                     blind key stays. Exists because the
#                                     blind key is WRONG on some dialogs:
#                                     codex's update prompt takes Enter as
#                                     "Update now" and runs the upgrade
#                                     (measured incident).
#   backend_startup_dialogs <id> <harness>
#   backend_startup_dialogs_pane <pane-id> <harness>
#                                     the startup sequence every launcher
#                                     runs before its composer-ready wait:
#                                     answer named dialogs as they appear,
#                                     press the registry's blind key once
#                                     for one the driver cannot answer by
#                                     name, stop once
#                                     the harness is observed up or down,
#                                     bounded by AC_STARTUP_DIALOG_BUDGET.
#   backend_harness_up <id>           did a harness actually COME UP in the
#                                     pane, or did it exit and leave a bare
#                                     shell? Three-state, like the submit
#                                     verifier and for the same reason (see the
#                                     CAME-UP PROBE below)
#   backend_harness_up_pane <pane-id> the same probe in raw-pane addressing,
#                                     with the SAME three states - never
#                                     collapsed, so a pane that could not be
#                                     READ is not reported as a dead harness.
#   backend_agent_idle_pane <pane-id> raw-pane twin of backend_agent_idle:
#                                     true only when the backend identifies the
#                                     agent's input surface as idle. A live
#                                     foreground process alone does not prove
#                                     that a TUI composer exists yet.
#   backend_kill_window <id>          close the task's tab - only with the
#                                     OWNERSHIP PROOF below; non-zero only
#                                     when OUR tab stayed open (same block)
#   backend_target <id>               display label for humans/logs
#   backend_mark_wait <id> [<msg>]    stamp the pane BLOCKED in the UI (below)
#   backend_clear_wait <id>           release the stamp (no-op when absent)
#
# Beside the backend surface, this file owns the SHARED LAUNCH MOTE - what any
# mechanism types into a pane to start an agent (ac_build_launch) and the
# crew-dispatch resolution behind it (ac_resolve_profile). Its contract sits
# above those two functions.
#
# CAPTAIN-WAIT STAMP (the authoritative contract): a pane whose task waits on
# a captain ACTION (an AC_DECISION_RE marker: needs-decision:/blocked:, plus
# the crew-ship delivery marker awaiting the captain's merge - checks-passed:)
# shows agent status BLOCKED in the UI. Orca carries no external agent-report
# API, so the stamp FILE (state/.captain-wait-<id>) is the contract's sole
# authority - backend_agent_blocked_orca short-circuits on it, and Orca's own
# agentWait detection keeps surfacing the wait in its UI alongside it (detail:
# backend_mark_wait_orca, ac-backend-orca.sh). Therefore:
# - state/.captain-wait-<id> records that the fleet owns the blocked state;
# - backend_agent_blocked returns FALSE while the stamp file exists, keeping
#   ask: wakes and ac-send's blocked-pane refusal meaning REAL interactive
#   prompts only. While stamped, a real dialog would be masked too -
#   accepted: a stamped pane sits idle after its marker, and the next
#   activity is the answering steer.
#   That idle precondition is now ENFORCED rather than assumed: a pane that
#   prints its marker and KEEPS WORKING is not stamped at all (below);
# - the watcher (ac-watch.sh) stamps on a NEW decision marker ONLY while the
#   pane reads non-busy, and DEFERS an otherwise-valid stamp to its Reconcile
#   branch, which takes it once the pane parks. A stamp taken while busy could
#   only be released by the STALE-STAMP SUPERSESSION, which itself fires only
#   while busy - so that release has no transition ahead of it and blanks the
#   pane out of the grouped agents panel for the rest of the turn (measured
#   ~20min once). It clears on any other captain marker, and on DEMONSTRATED
#   LATER PROGRESS - a pane busy under a standing stamp has moved on from what
#   parked it (that SUPERSESSION owns the rule); ac-send clears after a
#   successful delivery other than a slash command, which answers nothing
#   (the steer IS the answer, and it is well-timed for the
#   one reason that matters here: the steer itself supplies the idle->working
#   transition that re-adopts the pane); kill_window removes the stamp file
#   with the pane.
#
# HARNESS CAME-UP PROBE (the authoritative contract). backend_harness_up asks
# ONE question about a pane: is a harness running in it, or has it fallen back
# to a bare shell prompt? Three states, never two, for the same reason as
# WINDOW LIVENESS below - a pane that could not be READ is no evidence the
# harness died:
#   0  UP           - a non-shell process holds the foreground
#   1  SHELL        - every foreground process is a shell: the harness exited
#                     (or never started) and the pane sits at a prompt
#   2  UNOBSERVABLE - the pane could not be classified at all
# ac-spawn.sh is the caller this exists for - it withholds the kickoff prompt
# on 1 (its header owns why). The evidence and exact verdict ladder are the
# orca driver's own (backend_harness_up_pane_orca, ac-backend-orca.sh).
#
# WINDOW LIVENESS (the authoritative contract). backend_window_alive asks ONE
# question - does this task's pane still exist? - and answers it in three states,
# because "the pane is gone" and "the backend could not be read" are different
# facts with opposite consequences:
#   0  ALIVE        - the backend ANSWERED and the pane exists
#   1  GONE         - the backend ANSWERED and the pane does not exist (a task
#                     with NO recorded handle is this too: a LOCAL read, and a
#                     local fact is never an outage)
#   2  UNOBSERVABLE - the backend could not be reached or could not be understood;
#                     nothing was learned about the pane
# A single collapsed read here has cost a fleet before: a backend outage that
# answers every query the same uniform-failure way can read as "every pane just
# died" while every process still runs. Only a DEFINITE answer from a reachable
# backend may become `gone` - the ladder that proves it (a failing fast-path
# read followed by one control call on the same api surface, widening to GONE
# only on a backend that positively reports itself stopped) is the orca
# driver's own (backend_window_alive_orca, ac-backend-orca.sh).
# Every caller that merely tests truthiness keeps its behaviour unchanged (2 is
# non-zero); ac-watch.sh, ac-peek.sh and ac-send.sh must not collapse 2 into 1 -
# ac-watch.sh records `unobservable:` and stamps NO failure, ac-peek.sh and
# ac-send.sh blame the backend rather than the pane.
#
# KILL OWNERSHIP PROOF: backend_kill_window_orca needs no ownership round-trip
# (Orca's handles are runtime-issued and never recycled, so a recorded handle
# can only ever be this task's own pane - detail: ac-backend-orca.sh header)
# and never returns non-zero; the fleet-local files (state/.pane-<id>, the
# wait stamp) are swept either way.
#
# Delivery verification: send_line hands the text and its Enter to Orca as
# ONE prompt (`terminal send --text --enter --wait-submit 3`; probe
# 2026-11-17, Orca 1.4.259): a recognized agent gets it bracket-pasted - a
# 4871-byte, 62-line message arrived whole on claude, codex, opencode, pi and
# cursor - and the receipt's observation "supported" (claude, codex) is the
# acknowledgement, at input_accepted alone too, since a busy agent queues the
# prompt and runs it after its turn. Orca's agent_prompt_blocked refusal
# (nothing typed) and an agentWait read ahead of the send are the DIALOG
# verdict. An "unsupported" observation (a shell, opencode, pi, cursor) means
# Orca typed and pressed Enter blind: only a text PROVEN pending in the
# composer (the region between the screen's last two rules) buys a retry
# Enter, at most two, AC_SEND_SETTLE apart, then a strand. No parseable
# receipt is UNOBSERVABLE (2) and is never resent.
# The resubmit primitive, submit_verified, cannot ask Orca for a receipt (a
# bare Enter carries no prompt): a submit's Enter may be silently absorbed (an
# unfocused pane, a key the TUI ignores), so the sender must never trust its
# own exit code - the acknowledgement observable is a RENDER-CHANGE probe:
# byte-compare a capture from just before the Enter against re-reads taken
# after it. A dropped Enter leaves the render byte-identical; an accepted one
# clears the composer and redraws. Content matching cannot do this job: an
# accepted line is echoed into the transcript and persists there at no fixed
# depth. The probe is ADAPTIVE, not one fixed pause: after the Enter the render
# is re-read every AC_SEND_SETTLE seconds for up to 7 probes, returning ACCEPTED
# the INSTANT it reacts - fast in the common unloaded case, while still
# tolerating a redraw that lands late under host load.
# The probe has THREE outcomes, not two, because "the render did not change" and
# "the render could not be READ" are different facts: a failing `pane read`
# leaves pre and post both empty, which the byte-compare cannot tell apart from
# a dropped Enter - so an ACCEPTED submit was reported as a strand after 7
# wasted probes, and a partial outage yielding a non-empty post faked an
# ACCEPTED verdict. The verifier therefore stops swallowing the read's own
# failure (backend_capture_pane already returns 1 on it) and reports it:
#   0  ACCEPTED     - the render reacted; the submit went through
#   1  STRANDED     - the render was READ and did not react: dropped Enter
#   2  UNOBSERVABLE - the pane could not be read; the submit is neither
#                     confirmed nor refuted (the Enter is still pressed)
# Callers must not collapse 2 into 1: they say WHICH ("could not read the pane"
# vs "text stranded in the composer"), because the human's next move differs -
# a strand is resubmitted, an unreadable pane is peeked at first.
# AC_SEND_SETTLE (default 0.4) is the interval between submit-verify probes
# and the pause after a retry Enter; the total verify budget is 7 probes
# (~2.8s at the default), inside the captain's sanctioned ~2-3s envelope.
# The probe covers SUBMITS only. send_key presses a bare key, whose effect may
# legitimately redraw nothing (Escape with no dialog open, C-c on an idle pane,
# a key the TUI absorbs), so an identical render there is NOT the dropped-key
# signature and probing it would fake a verdict either way. send_key therefore
# FOCUSES the tab first - the focus quirk is the same one, and closing it is
# the whole guarantee the key path has - and delivery stays UNVERIFIED, which
# ac-send.sh reports in those words (contract: src/send.ts's header).
#
# HUNG RPC: the orca driver carries no RPC ceiling of its own - a wedged orca
# call blocks its caller for as long as the CLI does. WINDOW LIVENESS's
# two-call ladder is the one case that matters (it reads two failed calls as
# UNOBSERVABLE, so a wedge can never be mistaken for a dead pane); callers
# reaching backend_window_alive against their own budget (the Stop hooks'
# ac_wake_orphan_pending, 30s) rely on that, not on a ceiling here.
#
# FAMILY GROUPING: every pane of one task family lands in ONE place - the
# family's chief, its crewmates, its verification panes and its ship/qa watch
# tabs all group together, mirroring the dashboard's home -> family -> panes
# tree. AC_WINDOW_FAMILY names the family (set non-empty = that family's
# group; set EMPTY = deliberately the fleet's root group; UNSET =
# backend_window_new derives it with ac_window_family, ac-lib.sh: AC_SCOPE >
# AC_FLEET_SCOPE > ac_family_of_id). The orca driver's own grouping mechanism
# (one FAMILY TAB per room under the home's sidebar node, split rather than a
# new tab per pane) is documented at orca_place_pane (ac-backend-orca.sh).
#
# Tests drive this file through a fake `orca` CLI on PATH
# (tests/sh/helpers.sh ships it) - no live server needed.

ac_backend() {
  # AC_BACKEND (per-call/per-task pin) > $AC_HOME/config/backend > the fleet
  # config derived from AC_FLEET_STATE > orca. The third rung exists because
  # a crewmate pane deliberately carries NO AC_HOME - only the AC_FLEET_*
  # channel (ac-spawn fleet_env) - so a verifier it calls would otherwise
  # resolve the default on an orca fleet and lease from the wrong pool.
  local b="${AC_BACKEND:-$(ac_config_read backend '')}" f
  if [ -z "$b" ] && [ -n "${AC_FLEET_STATE:-}" ]; then
    f="${AC_FLEET_STATE%/}/../config/backend"
    [ ! -f "$f" ] || { b="$(head -n1 "$f")"; b="${b%%[[:space:]]*}"; }
  fi
  b="${b:-orca}"
  case "$b" in
    orca) printf '%s\n' "$b" ;;
    *) ac_die "unsupported backend '$b' (valid backend: orca)" ;;
  esac
}
# The dispatch block at the end of the file routes each public backend_* verb
# per call on AC_BACKEND, because a consumer may flip it per TASK after
# sourcing (ac_task_backend: one teardown/send/watch process can serve
# several tasks in one run). The name is still validated at source time too,
# so a bad config/backend or inherited AC_BACKEND refuses before any
# primitive runs.
ac_backend >/dev/null

# --- shared harness launch -------------------------------------------------------
#
# THE SHARED LAUNCH MOTE (the authoritative contract). Two mechanisms start an
# agent in a pane - ac-spawn.sh (crewmates: leased worktree, durable meta,
# watcher-supervised) and ac-pane-agent.sh (verification panes: caller's cwd,
# ephemeral, NDJSON result) - and they stay DISTINCT roles. Only the launch
# COMMAND and the crew-dispatch RESOLUTION are shared, so a new harness or a
# dispatch wiring is added ONCE instead of per mechanism.
#
# ac_build_launch <harness> <model> <effort> [<resume-sid>] [<session-id>]
#   Prints the built-in launch command for <harness>. Per-harness conventions
#   live HERE and nowhere else: claude takes --permission-mode auto plus
#   --model/--effort; codex takes -m plus the effort as a CONFIG OVERRIDE,
#   `-c model_reasoning_effort=<e>` - codex has no --effort flag, and -c is its
#   global override mechanism (`codex --help`, codex-cli 0.144.6). The form is
#   VERIFIED for the headless judge (src/pane-agent.ts ONESHOT, `codex exec`). The
#   INTERACTIVE TUI reading - against a config default of xhigh, launching
#   with `-c model_reasoning_effort=low` rendered `low` in the TUI header
#   (2026-07-21, clean CODEX_HOME) - is the fix probe's reported result, NOT
#   REPLAYABLE (contract:
#   .agents/skills/harness-operations/references/harness-facts.md); every
#   fleet effort token low|medium|high|xhigh|max is passed through
#   unfiltered. `ultracode` never reaches here as a token - ac-spawn.sh maps
#   it to xhigh before the mote (its header owns why).
#   opencode takes `-m <model>` like codex (`-m, --model` in `opencode --help`,
#   opencode 1.18.4, VERIFIED honored: against a config default of one model,
#   launching the TUI with `--model <other>` rendered the other in the TUI
#   footer - 2026-07-22, clean temp HOME with a fake provider; command bodies in
#   the opencode-crewmate-probe report, contract:
#   .agents/skills/harness-operations/references/harness-facts.md). Its EFFORT
#   is dropped, and that is a GAP, not an omission: the interactive TUI a
#   crewmate is launched with has no `--variant` - the flag exists on the
#   `opencode run` subcommand only - so the fleet's effort knob has no route in.
#   An unknown harness is refused, naming the
#   config/launch-<h> template that would enable it - a CUSTOM template is the
#   caller's business (only ac-spawn.sh has the __BRIEF__/__ID__ substitutions
#   it needs), so callers try their own template first and fall through here.
#   The two optional session ids are mutually exclusive and a resume WINS: one
#   claude line never carries both. Both are the CALLER's to mint, because the
#   session id belongs to the lifecycle, not to the launch - ac-spawn pins one
#   it records in the meta and resumes later, while a one-shot pane turn pins
#   nothing and harvests its id from the transcript.
#
# ac_resolve_profile [--rule <n>] [--harness <h>] [--model <m>] [--effort <e>]
#   The crew-dispatch resolution, shared the same way. Prints the profile
#   triple `harness=<h><TAB>model=<m><TAB>effort=<e>` (ac-dispatch-select.sh's own
#   format). An explicitly named knob ALWAYS wins, per knob; the rest come from
#   --rule <n> resolved through ac-dispatch-select.sh. With no rule and no
#   harness named it REFUSES fail-closed while config/crew-dispatch.json exists
#   - a dispatch table means the harness is a judgment call the chief makes
#   (--list, then --rule), never a guess - and falls back to config/crew-harness
#   (default claude) when there is no table.
#
# ac_pane_profile <kind>
#   The KEYED half of that resolution, called with NO selector - for a
#   mechanism that passes none. ac_resolve_profile serves a chief who reads
#   prose `when` clauses and names a rule; this resolves
#   config/crew-dispatch.json's `panes.<kind>` by key with no selector
#   (ac-dispatch-select.sh --pane, which owns the lookup and its schema).
#   A roomchief promote (ac-spawn.sh --roomchief) is one such caller - a
#   durable session, not an ephemeral verification pane, but still passing no
#   selector - resolved via `panes.roomchief`; it has NO --rule mechanism at
#   all today.
#   Three kinds - gate, codereview, roomchief - may ALSO be ROUTED (`rules` +
#   a MANDATORY `default`,
#   routed-pane-rules-for-gate-codereview-roomchief), so this function always
#   resolves the mandatory default for them rather than dying when no
#   selector is at hand - exactly what a mechanism with no chief in the loop
#   needs (the system-initiated Learning promote, ac-learn.sh cmd_autoroom, carries
#   no --harness and no agent to judge a `when` clause). WHO can bypass this
#   function to choose instead differs per kind, judged by WHERE an agent
#   with AC_HOME actually sits in each call chain (same family, second
#   round):
#   - gate: ac-gate.sh runs PER ROUND with the owning roomchief's real
#     AC_HOME, so its own `--rule <n|default>` flag forwards straight to
#     ac-dispatch-select.sh --pane gate --rule, bypassing this function
#     entirely when a rule is chosen.
#   - codereview: an execution crewmate NEVER gets AC_HOME (ac-spawn.sh's
#     crew launch line omits it on purpose) and every codereview call chain
#     (ac-verify.sh, ac-ship.sh's review-agent step) passes this function's
#     ONE resolved value straight through with no selector of its own - so
#     per-round caller choice is not reachable at all. Instead ac-spawn.sh's
#     `--codereview-rule <n|default>` flag lets the SPAWNING chief - the only
#     agent ever in a position to judge - bypass this function ONCE, at
#     crewmate-spawn time, threading the chosen profile as
#     AC_FLEET_PROFILE_CODEREVIEW for that crewmate's entire life (every
#     round it runs reuses the same pin).
#   - roomchief: no caller passes a selector today; always resolves through
#     this function un-bypassed.
#   `panes.qa` stays the deliberate exception, untouched by any of this: its
#   `default` is optional and caller judgment is the ONLY path to a routed
#   selection (ac-qa.sh's own facade, via a scoped AC_HOME=$qa_home per call -
#   the captain explicitly declined that shape for codereview), so this
#   function returns NOTHING for a routed, unselected qa lookup - same as for
#   an unconfigured kind.
#   Prints the same triple, or NOTHING with exit 0 when no profile is
#   configured for that kind (or, qa only, when routed and unselected). Empty
#   is the load-bearing answer, not an afterthought: it is what a fleet that
#   configured nothing returns, and every caller falls through to its own
#   pre-existing ladder on it, so this function must never die or print a
#   word on the absent path.
#   Both rungs of the pane ladder are here rather than in each caller because
#   the answer must be reached from two different worlds - ac-spawn.sh resolves
#   it where AC_HOME is real and threads it to the homeless verification panes,
#   ac-pane-agent.sh reads it first-hand for the homed learning scout.
#
# ac_claude_config_env, ac_build_launch, ac_resolve_profile and ac_pane_profile
# have TypeScript twins in src/lib.ts that tests/ts/spawn-twins.test.ts holds
# to them, so the mote changes on both sides at once.

ac_claude_config_env() {
  # ac_claude_config_env - the CLAUDE_CONFIG_DIR= prefix for a launch line,
  # only when the chief itself runs under one. Panes are created by the
  # long-lived Orca runtime, which does NOT inherit this process's
  # environment: under a non-default config dir
  # (a work-vs-personal subscription split) a bare `claude` in the pane falls
  # back to ~/.claude and launches unauthenticated, blocking the agent before
  # it does any work. Harmless for other harnesses (an unused env var), so
  # callers prefix it unconditionally - outside ac_build_launch, like AC_HOME,
  # so a verbatim custom launch template passes it on too.
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || printf 'CLAUDE_CONFIG_DIR=%q ' "$CLAUDE_CONFIG_DIR"
  # Transcript persistence, UNCONDITIONAL: the Orca runtime may have been
  # (re)started from inside a claude session, and then every pane inherits
  # CLAUDE_CODE_CHILD_SESSION=1 - each fleet claude silently stops saving its
  # transcript, which breaks ac-follow and --resume-from (measured live,
  # fleet-wide). Forcing persistence on the launch line is the CLI's own
  # documented remedy, a no-op under a clean daemon, and an unused var for
  # every other harness.
  printf 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 '
}

ac_build_launch() {
  local h="$1" m="${2:-}" e="${3:-}" rsid="${4:-}" sid="${5:-}" launch
  case "$h" in
    claude)
      launch="claude --permission-mode auto"
      if [ -n "$rsid" ]; then
        launch="$launch --resume $rsid"
      elif [ -n "$sid" ]; then
        launch="$launch --session-id $sid"
      fi
      [ -n "$m" ] && launch="$launch --model $m"
      [ -n "$e" ] && launch="$launch --effort $e" ;;
    codex)
      # The startup update prompt takes typed keys as its options, and a
      # kickoff typed into it instead of a ready composer can select the
      # wrong one (harness-facts.md, codex UPDATE PROMPT); updating codex is
      # the captain's act, never a pane's.
      launch="codex -c check_for_update_on_startup=false"
      [ -n "$m" ] && launch="$launch -m $m"
      [ -n "$e" ] && launch="$launch -c model_reasoning_effort=$e" ;;
    opencode)
      launch="opencode"
      [ -n "$m" ] && launch="$launch -m $m" ;;
    pi)
      # pi 0.84.2 (verified on this host via --help): bare regular-TUI launch,
      # kickoff typed after the came-up gate like every built-in. --tui-mode
      # regular pins the pane-capturable TUI; --thinking takes the fleet effort
      # vocabulary directly (pi's extra off/minimal tiers sit below it and stay
      # unreachable). No permission flag exists or is needed - pi ships no
      # approval gate on its own tools.
      launch="pi --tui-mode regular"
      [ -n "$m" ] && launch="$launch --model $m"
      [ -n "$e" ] && launch="$launch --thinking $e" ;;
    cursor)
      # cursor-agent 2026.05.05 (verified on this host via --help): the agent
      # CLI is cursor-agent - bare `cursor` is the IDE launcher, a different
      # program. --yolo (alias of --force) is the autonomy an unattended
      # crewmate needs; --model rides when set; there is NO effort flag
      # (thinking rides model names), so effort is dropped - the opencode
      # shape. The pane opens in the worktree, which is cursor-agent's
      # default workspace; a possible first-launch trust dialog is UNPROVEN
      # (harness-facts.md owns the boundary).
      launch="cursor-agent --yolo"
      [ -n "$m" ] && launch="$launch --model $m" ;;
    *) ac_die "no launch template for harness '$h'; create $(ac_config_dir)/launch-$h" ;;
  esac
  printf '%s\n' "$launch"
}

ac_resolve_profile() {
  local rule="" h="" m="" e="" prof p_h p_m p_e
  while [ $# -gt 0 ]; do
    case "$1" in
      --rule) rule="${2:-}"; shift 2 || ac_die "$1 needs a value" ;;
      --harness) h="${2:-}"; shift 2 || ac_die "$1 needs a value" ;;
      --model) m="${2:-}"; shift 2 || ac_die "$1 needs a value" ;;
      --effort) e="${2:-}"; shift 2 || ac_die "$1 needs a value" ;;
      *) ac_die "ac_resolve_profile: unknown arg $1" ;;
    esac
  done
  if [ -n "$rule" ]; then
    prof="$("$(ac_root)/bin/ac-dispatch-select.sh" --rule "$rule")" || return
    IFS=$'\t' read -r p_h p_m p_e <<EOF
$prof
EOF
    [ -n "$h" ] || h="${p_h#harness=}"
    [ -n "$m" ] || m="${p_m#model=}"
    [ -n "$e" ] || e="${p_e#effort=}"
  elif [ -z "$h" ]; then
    [ ! -f "$(ac_config_dir)/crew-dispatch.json" ] \
      || ac_die "config/crew-dispatch.json is configured: pick a profile (bin/ac-dispatch-select.sh --list, then --rule <n>) and pass --harness/--model/--effort explicitly"
    h="$(ac_config_read crew-harness claude)"
  fi
  printf 'harness=%s\tmodel=%s\teffort=%s\n' "$h" "$m" "$e"
}

ac_pane_profile() {
  "$(ac_root)/bin/ac-dispatch-select.sh" --pane "$1"
}

ac_wait_file() { printf '%s/.captain-wait-%s\n' "$(ac_state_dir)" "$1"; }

ac_pane_file() { printf '%s/.pane-%s\n' "$(ac_state_dir)" "$1"; }
ac_pane_field() {
  # ac_pane_field <id> <n> - nth field of the persisted pane handle. Empty
  # (exit 0) when the handle file is gone: kill/teardown paths run under
  # set -e and treat an already-gone pane as ignorable, so awk's exit 2 on
  # a missing file must not abort them.
  awk -v n="$2" '{print $n; exit}' "$(ac_pane_file "$1")" 2>/dev/null || true
}

# --- per-call dispatch -----------------------------------------------------------
# One contract, one driver. The route is decided PER CALL on AC_BACKEND,
# through the same validating ladder ac_backend uses at source time, because a
# consumer may flip it per task after sourcing (ac_task_backend: one
# teardown/send/watch process can serve several tasks in one run) - a stale
# resolution read once at source time could place a pane under one task's
# backend pin and then read it under another's.
# Unknown names refuse here with the same message ac_backend gives at source
# time. window_new, dialog_answer(_pane), agent_idle(_pane), submit_verified and
# ac_startup_dialogs have TypeScript twins in src/lib.ts that
# tests/ts/spawn-twins.test.ts holds to; send_line_pane,
# send_key_pane, capture_pane, harness_up_pane, agent_status_pane and
# backend_startup_dialogs_pane have theirs held by tests/ts/pane-agent-twins.test.ts.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ac-backend-orca.sh"

ac_backend_route() {
  # Resolution is ac_backend's full ladder (env pin > home config >
  # fleet-state config > orca) on every call, never a value cached at source
  # time. ac_backend validates the name, so no second arm is reachable here.
  local fn="$1" b
  shift
  # Capture the resolution BEFORE the case: ac_backend's die inside $() only
  # kills the substitution subshell, and an empty case matches no arm yet
  # returns 0 - an unsupported backend would read as a LIVE pane.
  b="$(ac_backend)" || exit 1
  case "$b" in
    orca) "backend_${fn}_orca" "$@" ;;
  esac
}

backend_target()          { ac_backend_route target "$@"; }
backend_window_new()      { ac_backend_route window_new "$@"; }
backend_window_alive()    { ac_backend_route window_alive "$@"; }
backend_submit_verified() { ac_backend_route submit_verified "$@"; }
backend_send_line()       { ac_backend_route send_line "$@"; }
backend_send_line_pane()  { ac_backend_route send_line_pane "$@"; }
backend_send_key()        { ac_backend_route send_key "$@"; }
backend_send_key_pane()   { ac_backend_route send_key_pane "$@"; }
backend_capture()         { ac_backend_route capture "$@"; }
backend_capture_pane()    { ac_backend_route capture_pane "$@"; }
backend_kill_window()     { ac_backend_route kill_window "$@"; }
backend_focus()           { ac_backend_route focus "$@"; }
backend_agent_blocked()   { ac_backend_route agent_blocked "$@"; }
backend_agent_idle()      { ac_backend_route agent_idle "$@"; }
backend_agent_idle_pane() { ac_backend_route agent_idle_pane "$@"; }
backend_agent_status_pane() { ac_backend_route agent_status_pane "$@"; }
backend_dialog_answer()   { ac_backend_route dialog_answer "$@"; }
backend_dialog_answer_pane() { ac_backend_route dialog_answer_pane "$@"; }
backend_harness_up()      { ac_backend_route harness_up "$@"; }
backend_harness_up_pane() { ac_backend_route harness_up_pane "$@"; }

backend_startup_dialogs()      { ac_startup_dialogs backend_dialog_answer backend_send_key backend_harness_up "$@"; }
backend_startup_dialogs_pane() { ac_startup_dialogs backend_dialog_answer_pane backend_send_key_pane backend_harness_up_pane "$@"; }
ac_startup_dialogs() {
  # ac_startup_dialogs <answer-fn> <key-fn> <up-fn> <handle> <harness>
  # The one startup sequence both launchers (src/spawn.ts deliverKickoff,
  # ac-pane-agent.sh's crewmate arm) run between the launch line and their
  # composer-ready wait. Observation-driven where the backend observes:
  # a named dialog is answered and the loop looks again at once (codex's
  # update prompt is followed by its hooks-review prompt); an unnamed one
  # gets the registry's blind key(s) exactly once (ac_harness_startup_key -
  # codex's trust dialog wants Enter, claude's wants Down then Enter since
  # its default is the wrong option); nothing pending ends the sequence as
  # soon as the harness is observed UP or SHELL (the came-up and ready gates
  # own what follows). A pane neither backend can classify answers 3 on the
  # first call: the blind key(s), once, and out.
  # EVERY waiting arm spends the SAME budget, answered included: a dialog the
  # driver answers but that does not clear (a key the screen ignores, a prompt
  # that redraws) is not progress, and an unbounded answered arm would press
  # that key once a second for the life of the spawn.
  local answer="$1" send="$2" upfn="$3" h="$4" harness="$5"
  local key rc up i=0 pressed=0 tok budget="${AC_STARTUP_DIALOG_BUDGET:-15}"
  key="$(ac_harness_startup_key "$harness")"
  while :; do
    rc=0; "$answer" "$h" || rc=$?
    case "$rc" in
      0) [ "$i" -lt "$budget" ] || return 0   # answering is not progress on its own
         sleep 1; i=$((i + 1)); continue ;;
      1) up=0; "$upfn" "$h" || up=$?
         [ "$up" = 2 ] || return 0 ;;
      2) if [ -n "$key" ] && [ "$pressed" = 0 ]; then
           for tok in $key; do "$send" "$h" "$tok" || true; done
           pressed=1; sleep 1; continue
         fi
         return 0 ;;
      *) for tok in $key; do "$send" "$h" "$tok" || true; done
         return 0 ;;
    esac
    [ "$i" -lt "$budget" ] || return 0
    sleep 1; i=$((i + 1))
  done
}
backend_mark_wait()       { ac_backend_route mark_wait "$@"; }
backend_clear_wait()      { ac_backend_route clear_wait "$@"; }
