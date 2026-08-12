#!/usr/bin/env bash
# ac-backend.sh - session backend primitives over herdr (the ONLY supported
# backend). Sourced, not an entrypoint.
#
# Backend selection: $AC_BACKEND (consumers export it from the task meta's
# `backend=` key), else config/backend, else herdr - and every value other
# than `herdr` is refused. tmux and wezterm support was removed 2026-07-17
# by captain order: one backend, one contract, one test surface.
#
# Surface (all keyed by crewmate id):
#   backend_window_new <id> <dir>     create the pane/window, default shell
#   backend_window_alive <id>         does the pane exist? Three-state, like the
#                                     submit verifier and the came-up probe and
#                                     for the same reason (see WINDOW LIVENESS
#                                     below): a backend that could not be READ is
#                                     not reported as a dead pane
#   backend_send_line <id> <text>     type literally, then submit VERIFIED
#                                     (see delivery verification below); one
#                                     focused retry, then non-zero + stderr -
#                                     exit 1 the text is stranded in the
#                                     composer, exit 2 the pane could not be
#                                     READ so nothing was observed; the CALLER
#                                     decides what each of the two means
#   backend_submit_verified <id>      press Enter, ack by capture-change; the
#                                     resubmit primitive for callers retrying
#                                     a stranded line (re-TYPING would append
#                                     to the composer and garble it). Same
#                                     three-state status: 0 accepted, 1
#                                     strand, 2 unobservable
#   backend_send_key <id> <Enter|Escape|C-c>
#                                     focus the tab, then press the key -
#                                     delivery is UNVERIFIED (see below): a
#                                     bare key has no guaranteed observable
#   backend_capture <id> [lines=40]
#   backend_capture_pane <pane-id> [lines=40]
#                                     the same read addressed by RAW herdr pane
#                                     id, for a pane with NO state/.pane-<id>
#                                     handle - a pane agent (ac-pane-agent.sh)
#                                     holds only the raw id herdr handed it, so
#                                     the id-keyed verbs cannot reach it. Fails
#                                     closed on an empty pane id.
#   backend_send_line_pane <pane-id> <text>
#                                     send_line in that same raw-pane
#                                     addressing, with the SAME verified-submit
#                                     semantics: probe for the render to react,
#                                     focus the pane's own tab (resolved from
#                                     herdr, since there is no handle to read it
#                                     from) and retry ONCE, then return the same
#                                     three-state status (1 stranded, 2
#                                     unobservable). It prints nothing: the
#                                     caller owns the message, because only the
#                                     caller knows what to call the pane
#                                     (ac-pane-agent.sh steer names the handle),
#                                     and the status is how it tells the two
#                                     failures apart. Fails closed on an empty
#                                     pane id.
#   backend_send_key_pane <pane-id> <Enter|Escape|C-c>
#                                     send_key in that same raw-pane addressing
#                                     (the pane agent's crewmate arm answers a
#                                     codex startup dialog with it, exactly as
#                                     ac-spawn.sh does for a crewmate). Delivery
#                                     stays UNVERIFIED for the same reason.
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
#                                     true only when herdr identifies the
#                                     agent's input surface as idle. A live
#                                     foreground process alone does not prove
#                                     that a TUI composer exists yet.
#   backend_kill_window <id>          close the task's tab - only with the
#                                     OWNERSHIP PROOF below
#   backend_target <id>               display label for humans/logs
#   backend_mark_wait <id> [<msg>]    stamp the pane BLOCKED in the UI (below)
#   backend_clear_wait <id>           release the stamp (no-op when absent)
#
# Beside the backend surface, this file owns the SHARED LAUNCH MOTE - what any
# mechanism types into a pane to start an agent (ac_build_launch) and the
# crew-dispatch resolution behind it (ac_resolve_profile). Its contract sits
# above those two functions. It also owns the two herdr-specific pane-agent
# workspace/tab helpers (ac_herdr_agents_workspace, ac_herdr_tab_open, moved
# from ac-lib.sh by audit-f3, codebase-audit-2026-07-29 finding 3 - they are
# inline python3 herdr wire parsing that never belonged in a general lib);
# their own comments sit above them, right after backend_window_alive.
#
# CAPTAIN-WAIT STAMP (the authoritative contract): a pane whose task waits on
# a captain ACTION (an AC_DECISION_RE marker: needs-decision:/blocked:, plus
# the crew-ship delivery marker awaiting the captain's merge - checks-passed:)
# shows agent status BLOCKED in the herdr UI - captain order
# 2026-07-17. The
# stamp is `pane report-agent --source ac-fleet --state blocked`; verified
# behavior (2026-07-17): an external report MASKS herdr's built-in agent
# detection until released, and a release leaves the pane carrying NO `agent`
# key at all (`agent_status: unknown`) until the agent's next state TRANSITION
# re-asserts it. Re-measured 2026-08-03, and the bound is what matters: only a
# TRANSITION re-adopts. Screen churn does not (a pane released mid-turn stayed
# dark 9m43s with its braille title animating), elapsed time does not (80s and
# 4.5min held at working), and merely BEING idle does not (30s idle after a
# release, still no identity) - a claude-shaped prompt box in a bare shell is
# never adopted at all, so identity comes from the PROCESS and the screen
# manifest only drives STATE. Therefore:
# - state/.captain-wait-<id> records that the fleet owns the blocked state;
# - backend_agent_blocked returns FALSE while the stamp file exists (pane get
#   can only echo our own report there), keeping ask: wakes and ac-send's
#   blocked-pane refusal meaning REAL interactive prompts only. While
#   stamped, a real dialog would be masked too - accepted: a stamped pane
#   sits idle after its marker, and the next activity is the answering steer.
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
#   successful delivery (the steer IS the answer, and it is well-timed for the
#   one reason that matters here: the steer itself supplies the idle->working
#   transition that re-adopts the pane); kill_window removes the stamp file
#   with the pane.
#
# HARNESS CAME-UP PROBE (the authoritative contract). backend_harness_up asks
# ONE question about a pane: is a harness running in it, or has it fallen back
# to a bare shell prompt? The evidence is herdr's `pane process-info`, which
# lists the pane's FOREGROUND processes: a pane at its prompt reports exactly
# its shell (argv0 `-zsh`), a pane running a harness reports the harness (and
# its children) there instead. The verdict is by process NAME rather than by
# comparing foreground_process_group_id against shell_pid, because a custom
# config/launch-<h> template that `exec`s its harness KEEPS the shell's pid -
# the pid comparison alone would call that healthy pane dead.
#   0  UP           - a non-shell process holds the foreground
#   1  SHELL        - every foreground process is a shell: the harness exited
#                     (or never started) and the pane sits at a prompt
#   2  UNOBSERVABLE - no handle, no process info, or an empty foreground list
# Callers must not collapse 2 into 1 (the send-verifier rule, same reason): a
# pane that could not be READ is no evidence the harness died, and refusing on
# it would ground the fleet over a herdr hiccup. ac-spawn.sh is the caller this
# exists for - it withholds the kickoff prompt on 1 (its header owns why).
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
# A single `pane get` collapsed 1 and 2, and that cost a fleet: brew upgraded the
# herdr CLI to protocol 17 against a still-running protocol-16 server, every
# socket call returned protocol_mismatch exit 1, and within 50s BOTH live agents
# of a family were stamped `failed: window gone` while their processes ran on -
# one of them committed its fix through the same blind transport (2026-07-25).
# The discriminator carries NO version knowledge, by captain rule (2026-07-22:
# runtime-robust over probe-established constants, fail closed on anything
# unrecognised). It classifies toward UNOBSERVABLE: only a DEFINITE answer from a
# reachable backend may become `gone`. A failing `pane get` is followed by ONE
# control call on the SAME api surface, `pane list` - its success proves the
# backend is answering that class of question at all, and the list it returns IS
# the definite answer about this pane (present = alive, absent = gone). An
# unreachable, refusing or unparseable answer is UNOBSERVABLE. Deliberately NOT a
# table of herdr error codes: naming `protocol_mismatch` the definition of
# unobservable would restore this bug the day herdr renames it. The control call
# runs ONLY after a failure, so the healthy poll costs exactly what it always did.
# Every caller that merely tests truthiness keeps its behaviour unchanged (2 is
# non-zero); the three callers the incident named must not collapse 2 into 1 -
# ac-watch.sh records `unobservable:` and stamps NO failure, ac-peek.sh and
# ac-send.sh blame the backend rather than the pane.
#
# herdr keys panes by ids handed out at creation, persisted in
# state/.pane-<id> ("<pane_id> <tab_id>").
#
# KILL OWNERSHIP PROOF (the authoritative contract): backend_kill_window closes
# the recorded tab only while `tab get` still reports its creation label
# crew:<id>; a mismatched or unreadable label REFUSES the close and warns,
# naming both the id and the tab. Without that proof the kill is a co-tenant
# hazard: state/.pane-<id> can outlive its tab (ac-spawn.sh --recover
# deliberately leaves it behind) and herdr recycles tab ids, a family's panes
# co-tenant their family workspace, and herdr drops a workspace whose last tab
# dies - so a stale handle has closed a FOREIGN chief tab and taken a whole
# shared workspace with it (three observed deaths, under the retired per-role
# grouping).
# A refusal is NOT fatal: teardown's kill step is best-effort, so it warns and
# returns 0, and the fleet-local files (state/.pane-<id>, the wait stamp) are
# swept either way - a handle just PROVEN stale is exactly what must not
# survive to aim a later kill.
# LAST-TAB FALLBACK: herdr refuses `tab close` on a workspace's last tab, and
# a family workspace (its default "1" tab closed at birth - see FAMILY
# WORKSPACE GROUPING) ends exactly there. A refused close on a PROVEN-owned
# tab therefore retries as `workspace close` - but only when the workspace
# provably holds nothing else real (this tab and default "1" tabs alone);
# a workspace holding another labelled tab, or one whose tab list cannot be
# read, is warned about and left open. Fail closed: an unknown answer never
# authorizes a close.
#
# Delivery verification: herdr's `pane send-keys enter` needs FOCUS - on an
# unfocused pane it exits 0 and does NOTHING, so a blind send strands its text
# in the composer while the sender reports success (live incident 2026-07-17,
# the backend-retry-enter room). The acknowledgement observable is a
# RENDER-CHANGE probe: byte-compare `pane read` from just before the Enter
# against re-reads taken after it. A dropped Enter leaves the render
# byte-identical; an accepted one clears the composer and redraws. Content
# matching cannot do this job: an accepted line is echoed into the transcript
# and persists there at no fixed depth (the refuted retry-Enter design, same
# room). The probe is ADAPTIVE, not one fixed pause: after the Enter the render
# is re-read every AC_SEND_SETTLE seconds for up to 7 probes, returning ACCEPTED
# the INSTANT it reacts. This keeps the common unloaded case fast (returns after
# one interval) while tolerating a redraw that lands late under host load - a
# single fixed 0.4s window misread an ALREADY-accepted submit as a strand when
# the redraw arrived after it (the kickoff-strand incident: 3 stranded spawns in
# a row, every later spawn hand-settled 3-4s). On a strand (no reaction within
# the budget) send_line focuses the tab and retries ONCE, verified again -
# never blind.
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
# AC_SEND_SETTLE (default 0.4) is the pause after typing, and the interval
# between submit-verify probes; the total verify budget is 7 probes (~2.8s at
# the default), inside the captain's sanctioned ~2-3s envelope.
# The probe covers SUBMITS only. send_key presses a bare key, whose effect may
# legitimately redraw nothing (Escape with no dialog open, C-c on an idle pane,
# a key the TUI absorbs), so an identical render there is NOT the dropped-key
# signature and probing it would fake a verdict either way. send_key therefore
# FOCUSES the tab first - the focus quirk is the same one, and closing it is
# the whole guarantee the key path has - and delivery stays UNVERIFIED, which
# ac-send.sh reports in those words (contract: its header).
#
# herdr knobs: AC_HERDR_SESSION > config/herdr-session (adds --session <name>;
# neither set = the default herdr session, addressed with no --session flag).
#
# FAMILY WORKSPACE GROUPING (the authoritative contract; captain order
# 2026-08-06, mirroring the dashboard's home -> family -> panes tree):
# every pane of one task family shares ONE workspace labelled
# "<fleet> · <family>" - the family's chief, its crewmates, its verification
# panes and its ship/qa watch tabs all land there, so the herdr sidebar reads
# home -> task and one workspace shows a family's whole crew. Fleet-level
# panes with no family (crewdeputies, self-task tabs, the learning scout)
# share the ROOT workspace "<fleet>". <fleet> is ac_fleet_name (ac-lib.sh).
# - AC_WINDOW_FAMILY names the family: set non-empty = that family's
#   workspace; set EMPTY = deliberately the root workspace; UNSET =
#   backend_window_new derives it with ac_window_family (ac-lib.sh:
#   AC_SCOPE > AC_FLEET_SCOPE > ac_family_of_id). ac_herdr_agents_workspace
#   reads only the env var - a verifier pane opener exports it.
# - Resolution is ADOPT-BY-LABEL, always: the busiest workspace carrying the
#   label wins, provably-empty twins are swept (emptiness proof below), none
#   found = create. The former config/herdr-workspace{,-chiefs,-agents} knobs
#   are RETIRED - never read, never written; a leftover knob file is inert.
#   The retired per-ROLE groups "<fleet> (crewchief|crewmate|pane-agent)" are
#   swept the same way once provably empty (herdr keeps a workspace alive on
#   its default tab alone, so they never die by themselves).
# - LIFECYCLE: a fresh workspace is born with herdr's default tab "1";
#   backend_window_new and ac_herdr_tab_open close it right after creating
#   their own tab, so a family workspace lives exactly as long as its REAL
#   tabs and vanishes from the sidebar when the family's last pane dies
#   (pane close cascades tab -> workspace). The API path cannot cascade -
#   herdr refuses to close a last tab - which is what the kill contract's
#   LAST-TAB FALLBACK above is for.
# - EMPTINESS PROOF (what authorizes closing a workspace): every tab it
#   holds is herdr's default tab (label "1"). A `crew:*`, `ac-*`, or any
#   human-named tab keeps it open; an unreadable tab list keeps it open too -
#   `tab list` on a bad workspace id exits non-zero with nothing on stdout,
#   which looks identical to a genuinely empty `.result.tabs: []` to a naive
#   jq, so the discriminator is the exit code, never absent labels.
#
# Tests drive this file through a fake `herdr` CLI on PATH
# (tests/helpers.sh ships it) - no live server needed.

ac_backend() {
  local b="${AC_BACKEND:-$(ac_config_read backend herdr)}"
  case "$b" in
    herdr) printf '%s\n' "$b" ;;
    *) ac_die "unsupported backend '$b' (herdr is the only backend; tmux/wezterm were removed 2026-07-17)" ;;
  esac
}
# herdr is the only backend, so the backend_* primitives below ARE the herdr
# implementation - there is no per-call dispatch and no config re-read on every
# primitive. The backend name is validated TWICE, both for free: once here at
# source time (a bad config/backend or inherited AC_BACKEND refuses before any
# primitive runs), and per-RPC by the fork-free env case in herdr_cli, which
# catches a caller that flips AC_BACKEND per TASK after sourcing (ac-spawn.sh's
# --recover probe) - the one refusal the retired per-call dispatch provided
# that source-time validation cannot.
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
#   VERIFIED for the headless judge (bin/ac-pane-agent.sh:756, `codex exec`). The
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
#   triple `harness=<h> model=<m> effort=<e>` (ac-dispatch-select.sh's own
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
#   a MANDATORY `default`, captain ruling 2026-07-28,
#   routed-pane-rules-for-gate-codereview-roomchief), so this function always
#   resolves the mandatory default for them rather than dying when no
#   selector is at hand - exactly what a mechanism with no chief in the loop
#   needs (the system-initiated Learning promote, ac-learn.sh:1758, carries
#   no --harness and no agent to judge a `when` clause). WHO can bypass this
#   function to choose instead differs per kind, judged by WHERE an agent
#   with AC_HOME actually sits in each call chain (captain ruling
#   2026-07-28, same family, second round):
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

ac_claude_config_env() {
  # ac_claude_config_env - the CLAUDE_CONFIG_DIR= prefix for a launch line,
  # only when the chief itself runs under one. Panes are created by the long-lived herdr daemon, which does
  # NOT inherit this process's environment: under a non-default config dir
  # (a work-vs-personal subscription split) a bare `claude` in the pane falls
  # back to ~/.claude and launches unauthenticated, blocking the agent before
  # it does any work. Harmless for other harnesses (an unused env var), so
  # callers prefix it unconditionally - outside ac_build_launch, like AC_HOME,
  # so a verbatim custom launch template passes it on too.
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || printf 'CLAUDE_CONFIG_DIR=%q ' "$CLAUDE_CONFIG_DIR"
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
      launch="codex"
      [ -n "$m" ] && launch="$launch -m $m"
      [ -n "$e" ] && launch="$launch -c model_reasoning_effort=$e" ;;
    opencode)
      launch="opencode"
      [ -n "$m" ] && launch="$launch -m $m" ;;
    *) ac_die "no launch template for harness '$h'; create $(ac_config_dir)/launch-$h" ;;
  esac
  printf '%s\n' "$launch"
}

ac_resolve_profile() {
  local rule="" h="" m="" e="" prof p_h p_m p_e
  while [ $# -gt 0 ]; do
    case "$1" in
      --rule) rule="${2:-}"; shift 2 ;;
      --harness) h="${2:-}"; shift 2 ;;
      --model) m="${2:-}"; shift 2 ;;
      --effort) e="${2:-}"; shift 2 ;;
      *) ac_die "ac_resolve_profile: unknown arg $1" ;;
    esac
  done
  if [ -n "$rule" ]; then
    prof="$("$(ac_root)/bin/ac-dispatch-select.sh" --rule "$rule")"
    read -r p_h p_m p_e <<EOF
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
  printf 'harness=%s model=%s effort=%s\n' "$h" "$m" "$e"
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

# --- herdr -----------------------------------------------------------------------

herdr_cli() {
  # Route to the configured herdr session; default session when unset.
  # The ladder is every other herdr caller's: AC_HERDR_SESSION > the config
  # knob. Neither set keeps the default session addressed with NO --session
  # flag - the siblings name it `default` explicitly, this path never has.
  #
  # PER-CALL BACKEND GUARD: a caller may flip AC_BACKEND per TASK after this
  # file was sourced (ac-spawn.sh's --recover probe exports the meta's
  # backend inside a subshell), so the source-time validation above cannot
  # see it. Every RPC funnels through here, and this case on the env var
  # costs no fork and no config read - an unsupported per-task backend still
  # refuses at the primitive, exactly as the retired per-call dispatch did.
  case "${AC_BACKEND:-herdr}" in
    herdr) ;;
    *) ac_die "unsupported backend '${AC_BACKEND}' (herdr is the only backend; tmux/wezterm were removed 2026-07-17)" ;;
  esac
  local s
  s="${AC_HERDR_SESSION:-$(ac_config_read herdr-session "")}"
  if [ -n "$s" ]; then
    HERDR_SESSION="$s" herdr "$@" --session "$s"
  else
    herdr "$@"
  fi
}

herdr_pane() { ac_pane_field "$1" 1; }
herdr_tab() { ac_pane_field "$1" 2; }

backend_target() { printf 'herdr:pane-%s\n' "$(herdr_pane "$1")"; }

herdr_tab_create() {
  # herdr_tab_create <workspace-or-empty> <dir> <id>
  if [ -n "$1" ]; then
    herdr_cli tab create --workspace "$1" --cwd "$2" --label "crew:$3" --no-focus
  else
    herdr_cli tab create --cwd "$2" --label "crew:$3" --no-focus
  fi
}

herdr_ws_family_label() {
  # herdr_ws_family_label <family-or-empty> - the workspace label for a
  # family (FAMILY WORKSPACE GROUPING, header): "<fleet> · <family>", or the
  # fleet ROOT label "<fleet>" for an empty family.
  local fleet
  fleet="$(ac_fleet_name)"
  if [ -n "${1:-}" ]; then printf '%s · %s\n' "$fleet" "$1"
  else printf '%s\n' "$fleet"; fi
}

herdr_ws_tabs_state() {
  # herdr_ws_tabs_state <ws> - one word about <ws>'s tabs, the EMPTINESS
  # PROOF of the header contract: "empty" (only herdr's default "1" tabs -
  # closing the workspace takes nothing real), "nonempty" (a crew:*, ac-* or
  # human-named tab lives there), or "unreadable" (the query failed - an
  # unknown answer, which must never authorize a close). `tab list` on a bad
  # workspace id exits non-zero with nothing on stdout, identical to a
  # genuinely empty `.result.tabs: []` to a naive jq - discriminate on the
  # exit code, never on absent labels.
  local rc=0 out state
  out="$(herdr_cli tab list --workspace "$1" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then printf 'unreadable\n'; return 0; fi
  state="$(jq -r '
    if (.result.tabs | type) == "array"
    then (if ([.result.tabs[].label] | all(. == "1")) then "empty" else "nonempty" end)
    else "unreadable" end' <<<"$out" 2>/dev/null)" || true
  [ -n "$state" ] || state="unreadable"
  printf '%s\n' "$state"
}

herdr_resolve_workspace() {
  # herdr_resolve_workspace <label> - THE workspace carrying <label>, printed
  # as its id: adopt the busiest existing one, sweep provably-empty twins
  # (the label proves a twin is OURS, never that it is disposable - only the
  # emptiness proof authorizes the close; herdr keeps a workspace alive on
  # its default tab alone, so twins never die by themselves), create when
  # none exists. Two independent CREATE-healers minting twins is exactly why
  # adopt-by-label runs before any create. `|| true` on the list: no match /
  # non-JSON output is a normal outcome, not a failure to abort over.
  local label="$1" twins ws t out
  twins="$(herdr_cli workspace list 2>/dev/null | jq -r --arg lbl "$label" '
    [.result.workspaces[]? | select(.label == $lbl)]
    | sort_by(-(.tab_count // 0)) | .[].workspace_id' 2>/dev/null || true)"
  ws="$(printf '%s\n' "$twins" | head -n1)"
  while IFS= read -r t; do
    [ -n "$t" ] && [ "$t" != "$ws" ] || continue
    case "$(herdr_ws_tabs_state "$t")" in
      empty) herdr_cli workspace close "$t" >/dev/null 2>&1 ;;
      nonempty) ac_warn "twin workspace $t left open: it holds a tab other than herdr's default '1' - closing the workspace would take that tab with it" ;;
      *) ac_warn "twin workspace $t left open: its tab list could not be read - a close cannot be proven safe" ;;
    esac
  done <<<"$twins"
  if [ -z "$ws" ]; then
    out="$(herdr_cli workspace create --label "$label" --no-focus)" \
      || ac_die "herdr workspace create failed (is the herdr server running?)"
    ws="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")"
    [ -n "$ws" ] || ac_die "could not parse herdr workspace create output"
  fi
  printf '%s\n' "$ws"
}

herdr_close_default_tabs() {
  # herdr_close_default_tabs <ws> - close herdr's default "1" tabs so the
  # workspace lives exactly as long as its REAL tabs (FAMILY WORKSPACE
  # GROUPING lifecycle, header). Called only AFTER the caller created its own
  # tab in <ws>, so a "1" is never the last tab; every close is best-effort
  # (herdr refuses a last-tab close, and a vanished tab is already the goal).
  local out t
  out="$(herdr_cli tab list --workspace "$1" 2>/dev/null)" || return 0
  jq -r '.result.tabs[]? | select(.label == "1") | .tab_id' <<<"$out" 2>/dev/null |
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    herdr_cli tab close "$t" >/dev/null 2>&1 || true
  done
  return 0
}

herdr_sweep_legacy_groups() {
  # Sidebar migration aid for the retired per-ROLE grouping: close this
  # fleet's "<fleet> (crewchief|crewmate|pane-agent)" workspaces once
  # provably empty (their default "1" tab keeps them alive forever after
  # their real tabs die). Silent - a nonempty legacy group is expected while
  # pre-migration panes still live - and free once they are gone (no label
  # matches, no tab queries).
  local fleet="$1" t
  herdr_cli workspace list 2>/dev/null | jq -r --arg f "$fleet" '
    [.result.workspaces[]? | select(
      .label == ($f + " (crewchief)") or
      .label == ($f + " (crewmate)") or
      .label == ($f + " (pane-agent)"))] | .[].workspace_id' 2>/dev/null |
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$(herdr_ws_tabs_state "$t")" = "empty" ]; then
      herdr_cli workspace close "$t" >/dev/null 2>&1 || true
    fi
  done
  return 0
}

backend_window_new() {
  ac_require herdr jq
  # FAMILY WORKSPACE GROUPING (header contract): the new tab lands in its
  # family's workspace - AC_WINDOW_FAMILY set non-empty names the family, set
  # EMPTY deliberately targets the fleet ROOT workspace (the crewdeputy and
  # self-task call sites), UNSET derives the family from the task id via
  # ac_window_family (AC_SCOPE > AC_FLEET_SCOPE > ac_family_of_id, ac-lib.sh).
  local id="$1" dir="$2" fleet fam label ws out tab pane
  fleet="$(ac_fleet_name)"
  if [ "${AC_WINDOW_FAMILY+set}" = "set" ]; then fam="$AC_WINDOW_FAMILY"
  else fam="$(ac_window_family "$id")"; fi
  label="$(herdr_ws_family_label "$fam")"
  herdr_sweep_legacy_groups "$fleet"
  ws="$(herdr_resolve_workspace "$label")"
  [ -n "$ws" ] || ac_die "could not resolve herdr workspace '$label'"
  out="$(herdr_tab_create "$ws" "$dir" "$id")" \
    || ac_die "herdr tab create failed (workspace $ws)"
  tab="$(jq -r '.result.tab.tab_id // empty' <<<"$out")"
  pane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")"
  [ -n "$tab" ] && [ -n "$pane" ] || ac_die "could not parse herdr tab create output"
  herdr_close_default_tabs "$ws"
  printf '%s %s\n' "$pane" "$tab" >"$(ac_pane_file "$id")"
}

backend_window_alive() {
  # THREE-STATE (header: WINDOW LIVENESS, which owns why). The `pane get` fast
  # path answers ALIVE and costs one call; its FAILURE is not a verdict, so a
  # `gone` needs a definite answer from a reachable backend - one control call
  # on the SAME api surface, whose pane list is itself that answer.
  local pane out
  pane="$(herdr_pane "$1")"
  [ -n "$pane" ] || return 1            # no handle: a LOCAL fact, really gone
  herdr_cli pane get "$pane" >/dev/null 2>&1 && return 0
  out="$(herdr_cli pane list 2>/dev/null)" || return 2
  case "$(jq -r --arg p "$pane" '
        if (.result.panes | type) == "array"
        then (if any(.result.panes[]; .pane_id == $p) then "alive" else "gone" end)
        else "unreadable" end' <<<"$out" 2>/dev/null)" in
    alive) return 0 ;;                  # the definite answer overrides the hiccup
    gone) return 1 ;;
    *) return 2 ;;                      # unparseable is not an answer
  esac
}

ac_herdr_agents_workspace() {
  # Resolve the workspace a VERIFICATION pane (or a ship/qa watch tab) lands
  # in - its FAMILY's workspace, the same grouping as crew tabs (FAMILY
  # WORKSPACE GROUPING, header; captain order 2026-08-06, superseding the
  # 2026-07-22 "the label stays pane-agent" ruling: one workspace now shows a
  # family's whole crew, verification panes included, so the separate
  # per-role group this function used to own is retired along with the
  # config/herdr-workspace-agents knob).
  # The family arrives ONLY through AC_WINDOW_FAMILY - a verifier pane opener
  # (ac-verify.sh, ac-gate.sh, the ship/qa watch tabs) exports it; absent or
  # empty resolves to the fleet ROOT workspace (the learning scout's case).
  # Twins are swept only on PROOF of emptiness (herdr_resolve_workspace): the
  # old blind sweep was safe for a verifier-only group, but a family
  # workspace holds crew tabs. Returns 1 rather than dying - every caller
  # treats a missing workspace as degrade-to-default-group.
  # The subshell contains herdr_resolve_workspace's ac_die (an exit, not a
  # return) so a wedged server degrades instead of killing the caller.
  local label
  label="$(herdr_ws_family_label "${AC_WINDOW_FAMILY:-}")"
  ( herdr_resolve_workspace "$label" ) 2>/dev/null || return 1
}

ac_herdr_tab_open() {
  # ac_herdr_tab_open <session> <label> <cwd> [<workspace>] - create a
  # labelled herdr tab (in <workspace> when given, else the session's default
  # group) and print "<pane_id> <tab_id>" on success. Prints nothing and
  # returns 1 on ANY failure - no tab created, or no pane_id parsed back -
  # NEVER aborting the caller under errexit.
  #
  # This is the "workspace fallback, tab create, byte-identical pane-id sed"
  # idiom that was hand-copied into ac-ship.sh, ac-qa.sh, ac-gate.sh (each a
  # watch-dashboard opener) and ac-pane-agent.sh (a verifier pane opener) -
  # F26. Living here once means a caller can no longer drift out of sync the
  # way ac-qa.sh's copy did (its rename/run calls, right after this same
  # block, ran unguarded under `set -euo pipefail` after the ac-ship.sh copy
  # had already been fixed to guard them - a live start-abort hazard). The
  # degrade contract - never fail the caller - lives HERE, in the one place;
  # callers still decide for themselves whether a failed rename/run after a
  # successfully opened tab is fatal.
  local ses="$1" label="$2" cwd="$3" ws="${4:-}" out p tab t
  if [ -n "$ws" ]; then
    out=$(herdr --session "$ses" tab create --workspace "$ws" --label "$label" --cwd "$cwd" --no-focus 2>/dev/null) || return 1
  else
    out=$(herdr --session "$ses" tab create --label "$label" --cwd "$cwd" --no-focus 2>/dev/null) || return 1
  fi
  p=$(printf '%s' "$out" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)
  tab=$(printf '%s' "$out" | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$p" ] || return 1
  # Workspace lifecycle (FAMILY WORKSPACE GROUPING, header): our tab is in by
  # now, so the workspace's default "1" tabs are disposable - closing them
  # lets the workspace die with its last REAL tab. Best-effort, raw-session
  # idiom (this helper is addressed by explicit <session>, not herdr_cli).
  if [ -n "$ws" ]; then
    herdr --session "$ses" tab list --workspace "$ws" 2>/dev/null \
      | jq -r '.result.tabs[]? | select(.label == "1") | .tab_id' 2>/dev/null \
      | while IFS= read -r t; do
          [ -n "$t" ] || continue
          herdr --session "$ses" tab close "$t" >/dev/null 2>&1 || true
        done
  fi
  printf '%s %s\n' "$p" "$tab"
}

herdr_submit_pane() { herdr_cli pane send-keys "$1" enter >/dev/null 2>&1; }
herdr_submit() { herdr_submit_pane "$(herdr_pane "$1")"; }

herdr_submit_verified_pane() {
  # Press Enter and require the render to REACT (header: delivery
  # verification). Identical pre/post reads are the dropped-Enter signature.
  # ADAPTIVE probe: re-read the render every AC_SEND_SETTLE seconds and return
  # success the INSTANT it reacts, so a redraw that lands late under host load
  # is no longer misread as a strand. tries*AC_SEND_SETTLE is the total budget
  # (7 * 0.4 ~= 2.8s at the default), the sanctioned ~2-3s envelope; the enter
  # is pressed ONCE (only the read repeats), so real-strand detection is intact.
  # Addressed by RAW pane id so the id-keyed and pane-keyed sends share ONE
  # verifier - the id twin below just resolves its handle first.
  # A read that FAILS is reported as 2 (unobservable), never as the strand
  # verdict 1: an empty pre/post pair is not evidence of a dropped Enter
  # (header: delivery verification). The Enter is pressed either way, so an
  # unreadable pane loses no delivery attempt - only the verdict.
  local pane="$1" pre post i=0 tries=7 readable=1
  pre="$(backend_capture_pane "$pane" 15 2>/dev/null)" || readable=0
  herdr_submit_pane "$pane"
  [ "$readable" = 1 ] || return 2
  while [ "$i" -lt "$tries" ]; do
    sleep "${AC_SEND_SETTLE:-0.4}"
    post="$(backend_capture_pane "$pane" 15 2>/dev/null)" || return 2
    [ "$post" != "$pre" ] && return 0
    i=$((i + 1))
  done
  return 1
}

backend_submit_verified() { herdr_submit_verified_pane "$(herdr_pane "$1")"; }

backend_send_line() {
  # herdr's `pane send-text` does NOT auto-submit; Enter goes separately and
  # is VERIFIED (header: delivery verification). On a strand: focus the tab
  # (send-keys needs focus) and retry ONCE, verified again - never blind.
  # The retry's status is the verdict, and its two failure modes get their own
  # message: exit 1 says the text is stranded, exit 2 says the pane could not
  # be read at all - claiming a strand there is the very lie this verifies.
  local id="$1"
  shift
  local text="$*" rc=0
  herdr_cli pane send-text "$(herdr_pane "$id")" "$text" >/dev/null 2>&1
  sleep "${AC_SEND_SETTLE:-0.4}"
  backend_submit_verified "$id" && return 0
  backend_focus "$id"
  backend_submit_verified "$id" || rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 2 ]; then
    printf 'ac-backend: could not read the pane of %s - submit UNVERIFIED, so the text may or may not have gone through (peek it: ac-peek.sh %s)\n' \
      "$(backend_target "$id")" "$id" >&2
    return 2
  fi
  printf 'ac-backend: submit not acknowledged by %s - text likely stranded unsubmitted in the composer (peek, then resubmit: ac-send.sh %s --key Enter)\n' \
    "$(backend_target "$id")" "$id" >&2
  return 1
}

backend_send_line_pane() {
  # RAW-pane twin of backend_send_line (header: backend_send_line_pane), for a
  # pane with no state/.pane-<id> handle. Same shape - type, settle, verified
  # Enter, focus + ONE verified retry - and silent: the caller prints the
  # failure, since only it can name the pane in the chief's own terms. The
  # retry's three-state status is returned VERBATIM (1 stranded, 2
  # unobservable), which is the only way a silent twin lets its caller say
  # WHICH of the two happened.
  local pane="$1"
  shift
  local text="$*"
  [ -n "$pane" ] || return 1
  herdr_cli pane send-text "$pane" "$text" >/dev/null 2>&1
  sleep "${AC_SEND_SETTLE:-0.4}"
  herdr_submit_verified_pane "$pane" && return 0
  herdr_focus_pane "$pane"
  herdr_submit_verified_pane "$pane"
}

herdr_focus_pane() {
  # Focus the tab a RAW pane sits in. The tab id comes from herdr itself
  # (`pane get`), because the handle file that carries it for a crewmate does
  # not exist for a pane agent.
  local tab
  tab="$(herdr_cli pane get "$1" 2>/dev/null | jq -r '.result.pane.tab_id // empty' 2>/dev/null || true)"
  [ -n "$tab" ] || return 1
  herdr_cli tab focus "$tab" >/dev/null 2>&1
}

herdr_key_name() {
  # The one place a fleet key name is translated to herdr's, shared by both
  # addressings below so they can never drift apart.
  case "$1" in
    Enter|enter) printf 'enter\n' ;;
    Escape|escape|Esc|esc) printf 'escape\n' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

backend_send_key() {
  # `pane send-keys` needs FOCUS (header: delivery verification), so focus the
  # tab FIRST - a blind key press no-ops on an unfocused pane at exit 0. The
  # press itself is NOT probed: a bare key may legitimately redraw nothing, so
  # an identical render is no evidence of a drop (header, same block).
  backend_focus "$1"
  herdr_cli pane send-keys "$(herdr_pane "$1")" "$(herdr_key_name "$2")" >/dev/null 2>&1
}

backend_send_key_pane() {
  # RAW-pane twin of backend_send_key (header: backend_send_key_pane), for a pane
  # with no state/.pane-<id> handle - the pane-agent mechanism's own panes. Same
  # focus-then-press shape, with the tab resolved from herdr itself; the focus is
  # best-effort so an unresolvable tab cannot abort the caller under set -e.
  [ -n "$1" ] || return 1
  herdr_focus_pane "$1" || true
  herdr_cli pane send-keys "$1" "$(herdr_key_name "$2")" >/dev/null 2>&1
}

backend_capture_pane() {
  # Read BY RAW PANE ID (header: the backend_capture_pane surface).
  # herdr quirk: `pane read --lines N` returns EMPTY when N is below the
  # viewport height; fetch generously and trim ourselves.
  local pane="$1" lines="${2:-40}" fetch out
  [ -n "$pane" ] || return 1
  fetch="$lines"
  [ "$fetch" -ge 200 ] 2>/dev/null || fetch=200
  out="$(herdr_cli pane read "$pane" --source recent --lines "$fetch" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | tail -n "$lines"
}

backend_capture() {
  # By crewmate id: resolve the persisted handle, then the raw-pane read above.
  backend_capture_pane "$(herdr_pane "$1")" "${2:-40}"
}

backend_kill_window() {
  # KILL OWNERSHIP PROOF (header contract): close the tab only while it still
  # carries this task's crew:<id> label. Refusal is a warning, never fatal.
  # LAST-TAB FALLBACK (header contract): herdr refuses to close a workspace's
  # last tab, and a family workspace ends exactly there - so a PROVEN-owned
  # tab whose close failed while it is still present retries as a close of
  # its whole workspace, but only on the emptiness proof (this tab + default
  # "1" tabs and nothing else).
  local id="$1" tab label ws tabs_left rc
  tab="$(herdr_tab "$id")"
  if [ -n "$tab" ]; then
    label="$(herdr_cli tab get "$tab" 2>/dev/null | jq -r '.result.tab.label // empty' 2>/dev/null || true)"
    if [ "$label" = "crew:$id" ]; then
      rc=0
      herdr_cli tab close "$tab" >/dev/null 2>&1 || rc=$?
      # The fallback fires only on a FAILED close whose tab is still present
      # (herdr's last-tab refusal exits 1, verified 2026-08-06); a close that
      # reported success is trusted.
      if [ "$rc" -ne 0 ] && herdr_cli tab get "$tab" >/dev/null 2>&1; then
        # Still there: last-tab refusal (or a hiccup). The tab id carries its
        # workspace ("<ws>:t<n>"); close the workspace only when NOTHING else
        # real lives in it - the proof reads the remaining tabs and demands
        # every one be this tab or a default "1". Unreadable = leave it.
        ws="${tab%%:*}"
        tabs_left="$(herdr_cli tab list --workspace "$ws" 2>/dev/null \
          | jq -r --arg t "$tab" '
            if (.result.tabs | type) == "array"
            then (if ([.result.tabs[] | select(.tab_id != $t) | .label] | all(. == "1"))
                  then "closeable" else "occupied" end)
            else "unreadable" end' 2>/dev/null || true)"
        case "$tabs_left" in
          closeable) herdr_cli workspace close "$ws" >/dev/null 2>&1 || true ;;
          occupied) ac_warn "tab $tab of $id refused to close and its workspace $ws holds other live tabs - close the tab by hand" ;;
          *) ac_warn "tab $tab of $id refused to close and workspace $ws could not be read - close the tab by hand" ;;
        esac
      fi
    else
      ac_warn "not closing tab $tab for $id: it is labelled '${label:-none}', not crew:$id - the handle is stale (close the tab by hand if it really is this task's)"
    fi
  fi
  rm -f "$(ac_pane_file "$id")" "$(ac_wait_file "$id")"
}

backend_focus() { herdr_cli tab focus "$(herdr_tab "$1")" >/dev/null 2>&1; }

backend_agent_blocked() {
  # True when the pane's agent sits BLOCKED on a prompt only a human can
  # answer - the human-prompt silent-stall signal.
  # A fleet CAPTAIN-WAIT STAMP masks the pane view with our own blocked
  # report (header contract), so while the stamp file exists this reader
  # answers false: no self-inflicted ask: wakes, and the answering ac-send
  # is not refused by its own stamp.
  local pane out status
  [ -e "$(ac_wait_file "$1")" ] && return 1
  pane="$(herdr_pane "$1")"
  [ -n "$pane" ] || return 1
  out="$(herdr_cli pane get "$pane" 2>/dev/null)" || return 1
  status="$(jq -r '[.. | .agent_status? // empty] | map(select(. != "")) | first // empty' <<<"$out")"
  [ "$status" = "blocked" ]
}

backend_agent_idle_pane() {
  # Raw-pane addressing for callers that own no state/.pane-<id> handle.
  # Herdr's status enum is idle|working|blocked|unknown. Only `idle` answers
  # true; an unreadable pane and every other status answer false. The meaning is
  # caller-relative: an id-keyed running task treats idle as turn-end, while an
  # OpenCode pane with no submitted turn treats it as positive evidence that
  # herdr recognises the input surface and no turn is running. It is not a
  # semantic completion verdict by itself; the caller owns the bounded wait and
  # the surrounding process/turn evidence.
  local pane="$1" out status
  [ -n "$pane" ] || return 1
  out="$(herdr_cli pane get "$pane" 2>/dev/null)" || return 1
  status="$(jq -r '[.. | .agent_status? // empty] | map(select(. != "")) | first // empty' <<<"$out")"
  [ "$status" = "idle" ]
}

backend_agent_idle() {
  # Existing id-keyed turn-end predicate; a captain-wait stamp reports blocked,
  # never idle, so it cannot be read back as a completed turn.
  backend_agent_idle_pane "$(herdr_pane "$1")"
}

backend_harness_up() { backend_harness_up_pane "$(herdr_pane "$1")"; }

backend_harness_up_pane() {
  # RAW-pane twin of backend_harness_up (header: backend_harness_up_pane).
  # Is a harness running in the pane, or is it back at a shell prompt?
  # (header: HARNESS CAME-UP PROBE, which owns the three states and why the
  # verdict reads process NAMES rather than comparing pids.)
  local pane out names n
  pane="$1"
  [ -n "$pane" ] || return 2
  out="$(herdr_cli pane process-info --pane "$pane" 2>/dev/null)" || return 2
  names="$(jq -r '.result.process_info.foreground_processes[]? | (.argv0 // .name // empty)' <<<"$out" 2>/dev/null || true)"
  [ -n "$names" ] || return 2
  while read -r n; do
    n="${n##*/}"          # a full path is still just its command
    n="${n#-}"            # a login shell is argv0 '-zsh'
    case "$n" in sh|bash|zsh|fish|dash|ksh|tcsh|csh) ;; *) return 0 ;; esac
  done <<<"$names"
  return 1
}

backend_mark_wait() {
  # backend_mark_wait <id> [<msg>] - CAPTAIN-WAIT STAMP (header contract): show
  # the pane BLOCKED in the herdr UI while its task waits on the captain.
  local id="$1" msg="${2:-awaiting captain decision}" pane
  pane="$(herdr_pane "$id")"
  [ -n "$pane" ] || return 1
  herdr_cli pane report-agent "$pane" --source ac-fleet --agent crew \
    --state blocked --message "$msg" >/dev/null 2>&1 || return 1
  touch "$(ac_wait_file "$id")"
}

backend_clear_wait() {
  # backend_clear_wait <id> - release the CAPTAIN-WAIT STAMP; no-op without one
  # (never releases a state the fleet does not own). herdr's own detection
  # re-asserts on the agent's next state-change event.
  local id="$1" pane wf
  wf="$(ac_wait_file "$id")"
  [ -e "$wf" ] || return 0
  pane="$(herdr_pane "$id")"
  [ -z "$pane" ] || herdr_cli pane release-agent "$pane" --source ac-fleet --agent crew >/dev/null 2>&1 || true
  rm -f "$wf"
}
