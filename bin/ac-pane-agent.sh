#!/usr/bin/env bash
# ac-pane-agent.sh - run ONE agent turn in a herdr pane, for the mechanisms
# that verify: the ship pipeline's reviewer, qa, the learning scout, the gate
# judge. THREE ARMS, chosen by the caller's mode and the resolved harness: the
# SESSION arm (default, claude) runs a claude session - visible, steerable, real
# permission prompts answerable by a human; the CREWMATE arm (default mode,
# codex/opencode) runs the harness's own TUI under the crewmate contract - the
# agent WRITES its final message to a file and ANNOUNCES its own completion; and
# the ONE-SHOT COMMAND arm (`--exec`) runs a harness's non-interactive form,
# where the process EXIT is the turn end and its STDOUT is the final message.
# All three place a real pane; only the first is a resumable session.
#
#   ac-pane-agent.sh run --cwd DIR --prompt-file F [--resume SID] [--label L]
#                        [--kind K] [--timeout SECS] [--replace-pane ID]
#                        [--pane-file PATH] [--model M] [--deliverable PATH]
#                        [--effort E] [--harness H] [--exec] [--observe PATH]
#     --observe PATH: (--exec ONLY) publish a read-only observation descriptor
#       (pane/tab + the real prompt/stdout/stderr paths) BEFORE launch, so an
#       observer like ac-gate-watch can tail the ACTIVE one-shot run; the CALLER
#       removes it. Refused without --exec (a normal harvest has no such streams).
#   ac-pane-agent.sh close --pane ID
#   ac-pane-agent.sh reap-pane --pane ID  # close ONE known pane + tidy its tab/workspace
#   ac-pane-agent.sh reap [--dry-run]   # close ac-*-agent panes whose cwd is gone
#   ac-pane-agent.sh steer --agent HANDLE '<text>' [--pane ID]  # steer a live one
#
# --kind K names the CALLER on every herdr surface (tab ac-<kind>-agent-
# <branch>, pane ac-<kind>-agent:<label>); default `ship`. Known callers:
# codereview (the crew-ship reviewer, ac-ship.sh review-agent), qa (ac-qa.sh
# agent), learning (ac-learn.sh), gate (ac-gate.sh, the one --exec caller).
#
# --harness H names the harness EXPLICITLY, and with it the caller takes
# ownership of the WHOLE triple: no profile model/effort and no model/effort
# ladder apply, so anything not passed as a flag stays empty = that harness's
# own default. That is item 5 of HARNESS ARMS discharged at its only entry
# point - a profile's model was authored FOR the profile's harness, and this is
# the one place another harness could otherwise inherit it. The gate needs it
# because its FALLBACK rungs must name engines its profile did not.
#
# PANE PROFILE (the authoritative contract): which harness+model+effort a pane
# agent runs is DISPATCHED per --kind, from config/crew-dispatch.json's `panes`
# block - `"panes": {"codereview": {"harness","model","effort"}, "qa": {...}}`,
# the same object shape as a rule's `use`. Keyed, because a pane agent cannot
# do what rules[] asks of a reader: a `when` clause is prose a chief JUDGES, and
# a rule's identity is its POSITION, so inserting one would silently repoint a
# pinned reviewer at another profile. `panes` is `.default` generalized from one
# fallback slot to a set keyed by kind (ac-dispatch-select.sh --pane owns the
# lookup; ac-backend.sh ac_pane_profile is the shared rung both callers use).
#
# Resolved on TWO rungs, the model knob's below and for the same reason:
# AC_FLEET_PROFILE_<KIND> env (threaded by ac-spawn.sh, the only place AC_HOME
# is real for a homeless caller) > the `panes` block read first-hand (a homed
# caller: ac-learn.sh's scout). One scalar carries the whole triple, never three
# variables - see ATOMIC below.
#
# A profile is ATOMIC. When one resolves it supplies harness, model and effort
# TOGETHER and supersedes the per-role model knob for that kind, and its model
# and effort are used AS-IS, INCLUDING EMPTY: empty means the harness's own
# default, never a fall-through to the ladder below. That single rule is what
# keeps the triple coherent - a fall-through would compose a claude model name
# onto a non-claude harness (`codex -m opus`), which is exactly what putting
# harness+model+effort in ONE authored object exists to prevent. When NO profile
# resolves, everything below applies BYTE-FOR-BYTE unchanged: a fleet that
# configures no `panes` block behaves exactly as it did before this rung existed,
# and a fleet that dispatches its CREWMATES through rules[] does too - those
# rules are never borrowed for a verification pane.
#
# Model/effort ladder, per knob: the --model / --effort flag wins. For the
# VERIFICATION panes (--kind codereview | qa) the model then reads the per-role
# knob and DEFAULTS to claude opus: AC_FLEET_MODEL_<KIND> env (threaded by
# ac-spawn from config/model-<kind>) > config/model-<kind> > opus - verification
# runs on the strongest model, decoupled from the fleet crewmate model, unless
# the captain pins config/model-<kind>. Every other kind (and effort for all
# kinds) keeps the plain fleet ladder: the inherited fleet scalar AC_FLEET_MODEL
# / AC_FLEET_EFFORT; then config/model / config/effort; nothing anywhere =
# claude's own default. The point of the whole ladder is that an independent
# judge is never quietly a weaker model, or a
# shallower thinking tier, than the fleet pinned - it was, measurably: with a
# fleet pinned to config/model=opus its reviewer panes ran on claude-fable-5
# (pool-worktree transcripts, 2026-07-15). The config rung alone could not fix
# that, because it resolves through ac_home(): only a chief-run caller
# (ac-learn.sh's scout) has AC_HOME, while ac-ship.sh review-agent and ac-qa.sh
# agent run from crewmate panes that have none, where ac_home() REFUSES (and,
# before it refused, answered the config-less distro checkout). Hence the env
# rung, fed by ac-spawn.sh's crewmate
# launch line - two narrow scalars rather than the fleet home, which this script
# refuses to fabricate (see the AC_HOME pin below).
# --effort takes low|medium|high|xhigh|max|ultracode, and anything else is
# REFUSED before a pane is placed. The FLAG is claude-only on the interactive
# arm; on the one-shot arm the VALUE reaches every engine in that engine's own
# shape (codex `-c model_reasoning_effort=<e>`, claude `--effort <e>`, opencode
# `--variant <e>` - oneshot_launch). ultracode maps to xhigh and NOTHING else:
# the '/effort ultracode' TUI line is ac-spawn's kickoff mechanism, and a
# one-turn pane has no counterpart for it - the preset's orchestration half is
# simply not available here.
#
# HARNESS ARMS (the authoritative contract): a resolved harness is REFUSED,
# through the NDJSON error protocol and BEFORE a pane is placed, unless this
# script has an implemented arm for it IN THE MODE ASKED FOR:
#   SESSION (no --exec, harness claude): claude, and only claude.
#   CREWMATE (no --exec, harness codex | opencode): the crewmate contract.
#   ONE-SHOT (--exec): codex, claude, opencode - their `codex exec -s
#     read-only` / `claude -p` / `opencode run` forms (oneshot_launch below).
# The modes arm SEPARATELY, because a working one-shot form proves nothing about
# the same harness's TUI (and the reverse). Refusing beats placing: a pane whose
# harness never came up still burns the caller's whole timeout (AC_REVIEW_TIMEOUT
# default 3600s, per fix round) and then reports status:timeout, which reads like
# a slow reviewer rather than a misconfiguration.
# The launch line itself is built in TWO places: oneshot_launch (below, local to
# this file) composes the ONE-SHOT arm's command, while ac_build_launch
# (bin/ac-backend.sh) composes the SESSION/CREWMATE arms' interactive line.
#
# WHY THE SESSION ARM IS CLAUDE-ONLY - it is the DESIGN, not a gap awaiting an
# implementer (captain ruling 2026-07-22, `data/codex-pane-tui-arm/room.md`
# 04:20Z: "pane-agent chi dung cho claude" + "codex,opencode dung crewmate").
# A claude SESSION here is worth its machinery: it resumes across fix rounds, a
# human can steer it mid-turn, and its transcript is the harvest. All of that is
# claude-specific, and reproducing it per harness is what this arm will not do:
#   - TURN-END. claude's is the Stop-hook marker below. herdr agent_status:idle
#     is proven insufficient on its own - codex-cli 0.144.6 blocked on its own
#     interactive TRUST DIALOG while herdr reported `idle`, the SAME value it
#     reports for a finished turn (probe 2026-07-21, two throwaway panes). For
#     claude the ambiguity is broken by a second, claude-specific observable (the
#     transcript's mtime idling past 120s); a harness with no transcript has
#     nothing to break it with, and would harvest the dialog as its verdict.
#   - FINAL-MESSAGE HARVEST. claude's is a transcript locator ($PROJ/*.jsonl)
#     that ac_transcript_final parses. The backend_capture_pane scrollback
#     fallback stays the shared floor - but it is a floor: TUI chrome and a
#     width-elided render, fine for a one-line verdict, not for the reviewer's
#     JSON-object contract.
# The CREWMATE arm needs NEITHER, which is the whole point of the ruling: the
# agent writes its answer to a FILE and announces its own completion, so file
# exists = turn ended and file contents = the final message. Both codex and
# opencode are VERIFIED to do exactly that on the brief alone, with no
# harness-specific mechanism (harness-facts.md, `codex` and `opencode`
# Completion bullets; the observations are in `data/codex-crewmate/room.md` and
# `data/opencode-crewmate/room.md`). What the crewmate arm gives up is the
# session: no resume, no session id, nothing to steer - `steer` needs a live
# composer, and neither harness pins a caller-minted session id (harness-facts.md
# Resume bullets), so `--resume` is REFUSED here exactly as under --exec.
#
# What the CREWMATE arm still owes, and how it discharges it:
#   1. PROMPT DELIVERY - as its OWN TYPED LINE after the harness comes up, never
#      argv. The positional-prompt convention the other two arms use is
#      claude/codex-shaped, not universal: opencode 1.18.4's positional argument
#      is a project DIRECTORY, so an appended prompt became a cd target and the
#      pane fell back to a shell (probe 2026-07-21). The typed line is the
#      delivery every crewmate already uses, verified for both harnesses.
#      Both OpenCode and codex wait for BOTH herdr `idle` and a non-empty pane
#      render stable across three one-second observations before any text is
#      typed. Process-up and `idle` alone are not enough: both can arrive
#      while the TUI is still booting, and an unrelated boot redraw can
#      otherwise make verified submit report a false acceptance.
#   2. STARTUP DIALOG - the same answer the crewmate path gives, and the same
#      one only: a bare Enter at a codex pane before any text, because an `n` or
#      a `2` anywhere in typed text picks "2. No, quit" (harness-facts.md, codex
#      STARTUP TRUST DIALOG; the twin is bin/ac-spawn.sh deliver_kickoff). NOT
#      SAFE IN GENERAL, and stated rather than hidden: on a pane showing some
#      OTHER startup dialog that Enter selects that dialog's default, which for
#      the codex update prompt is "1. Update now (runs npm install -g)". The
#      captain accepted that residual on the crewmate path
#      (`data/codex-pane-tui-arm/room.md` 04:01Z, "chap nhan enter click nham
#      do"); this arm inherits the acceptance because it inherits the step, and
#      classifying dialogs here would rebuild the machinery the ruling deleted.
#   3. FLAG-VS-PROFILE MODEL COHERENCE - an explicit --model (carrying
#      review.model / AC_REVIEW_MODEL / AC_QA_MODEL) outranks a profile's model
#      by design, so a fleet dispatching this kind to a non-claude harness while
#      pinning a claude model name would compose that name onto it. This hazard
#      is LIVE on this arm - it was dormant while non-claude was refused here -
#      and is discharged exactly as --exec discharges it: --harness above takes
#      the WHOLE triple with it, so nothing a profile authored for another
#      harness can travel, and without the flag the profile is atomic, so its
#      model was authored FOR its own harness.
#
# A ONE-SHOT arm owes a shorter list still, and that is the point of it: prompt
# delivery is the harness's own non-interactive command (proven by the three
# forms this repo already ran headless), turn-end is the process exiting, the
# final message is its stdout, and there is no dialog to pre-seed because no
# session is opened.
#
# THE CREWMATE-ARM CONTRACT (the authoritative statement of it):
#   - The harness launches BARE - ac_build_launch's interactive line, no
#     positional prompt - with `; printf %s $? >RC; touch EXITMARK` appended, so
#     the harness's own EXIT is observable throughout the turn.
#   - The typed line names three absolute paths: the caller's prompt file (what
#     to do), the VERDICT file (where the final message goes), and the marker to
#     `touch` (how completion is announced). All three live in state/, next to
#     the Stop-hook marker - the mode that opens no session leaves no trace in
#     the directory it merely ran in, exactly as --exec does not. Absolute paths
#     in the PROMPT is also how the fleet home reaches an AC_HOME-less caller
#     (bin/ac-qa.sh, HOW THE PATH TRAVELS: "not the environment").
#   - TURN END = the marker exists. FINAL MESSAGE = the verdict file's bytes,
#     wrapped by wrap_transcript into the one-message jsonl shape
#     ac_transcript_final already parses, so every caller reads its verdict from
#     the same `transcript` path and the findings wire (ac_findings_normalize,
#     bin/ac-pipeline-lib.sh) is reached completely unchanged - the file
#     replaces the HARVEST, never the payload schema.
#   - FAIL CLOSED, in all four directions: a marker with a missing or EMPTY
#     verdict file is a FAILED turn (never ok with an empty payload, the same
#     rule the scrollback floor is held to); the harness exiting before the
#     marker is refused at once, naming its exit status, instead of burning the
#     caller's timeout; a prompt the pane STRANDED unsubmitted is refused before
#     any wait, since no turn will ever start; and a harness that never comes up
#     is refused rather than waited out. A pane that could not be READ is never
#     collapsed into either verdict - it is a note, and the turn proceeds.
#   - PARTIAL WRITES are the agent's ordering to keep: it is told to announce
#     only once the file is written. This arm can only see the bytes that are
#     there when the marker fires; the payload's own shape is checked where it
#     always was, by the caller (ac-ship.sh schema-checks the object envelope,
#     ac-qa.sh requires the verdict line), so a truncated write fails there with
#     the caller's own message rather than being re-validated here from a schema
#     this helper would have to duplicate.
#
# Protocol on stdout (NDJSON, consumed by ac-ship.sh review-agent, ac-qa.sh
# agent and ac-gate.sh):
#   {"event":"transcript","path":"...","session_id":"...","source":"scrollback|command|file"?}
#   {"event":"replace-pane","pane":"...","closed":true|false}   # --replace-pane only
#   {"event":"warning","reason":"...","message":"..."}   # a report, never a
#     refusal; emitted BEFORE any pane places - today only
#     "codereview-agent-mismatch" (CONTRADICTION CHECK below), when a
#     dispatched panes.codereview profile is about to silently outrank a
#     configured config/codereview-agent. `reason` is deliberately not
#     named `kind` - this file's own --kind (codereview/qa) is a different
#     axis and the two must never be confused on the wire.
#   {"event":"done","status":"ok|timeout|pane_closed|error","session_id":"...",
#    "transcript":"...","source":"transcript|scrollback|command|file","pane":"...","error":"..."}
# `session_id` is EMPTY for a one-shot AND a crewmate turn - neither opens a
# session this fleet can resume - which the callers that store one already
# guard for.
#
# REAP OUTCOME (the authoritative contract): a retirement here is best-effort
# and NEVER changes an exit status - `reap-pane` exits 0 by contract so it is
# trap-safe, and `--replace-pane` must not fail a turn whose new pane is already
# placed. That is why both VERIFY the close with `pane get` afterwards and
# publish `"closed":true|false` on their event. The helper reports; the CALLER
# surfaces - a `"closed":false` a caller swallows is an orphaned agent nobody
# was ever told about, which is exactly how pane agents accumulated in the
# shared workspace (ac-learn.sh reap_scout_panes, ac-qa.sh qa_reap_agent_pane
# and ac-teardown.sh reap_pane_file all ac_warn on it).
#
# FAIL-CLOSED HARVEST (the authoritative contract): a status:ok done event
# ALWAYS carries a non-empty transcript, and `source` says which harvest
# produced it. Under the CREWMATE arm that is the verdict FILE, and only a
# non-empty one (source=file; the contract block above owns the four failure
# directions). Under the ONE-SHOT arm the rung's own EXIT STATUS decides
# first: only a zero status with non-empty stdout is a turn (source=command,
# the stdout wrapped by the same one-message writer the scrollback harvest
# uses). A rung that died, or judged nothing, FAILED - reported through fail()
# and NEVER falling through to the scrollback floor, which returns TUI chrome
# and would hand a caller expecting a JSON object a width-elided render. That
# is stricter than the interactive arm can be: there, failure can only be
# inferred from an empty harvest. The turn ends on the Stop-hook marker whether or not
# $PROJ/*.jsonl resolved - and a session dir holding only subagents/ +
# tool-results/ has no jsonl to resolve at all - so an unresolved transcript
# there falls back to a PANE SCROLLBACK harvest (the raw-pane-id read
# backend_capture_pane, AC_PANE_SCROLLBACK_LINES lines, default 400), written
# as a one-message jsonl in the shape ac_transcript_final already parses so the
# caller reads its verdict from the same `transcript` path. When even the
# scrollback is empty the turn is REFUSED through fail() - status error, exit
# non-zero - never ok with "transcript":"", which overwrote the caller's
# durable per-run session pointer with an empty string and then died late on an
# empty path. `source` is emitted on the ok events only: the non-ok statuses
# assert no usable payload.
#
# STEER (the authoritative contract): a chief steers a LIVE pane agent through
# `steer`, never by hand-crafting herdr commands. INTERACTIVE arm only - a
# one-shot pane runs a command, not a composer, so there is nothing to steer
# and its pane is a VIEW of a turn already running to its own end. The stable HANDLE is the pane
# NAME this script writes at creation - ac-<kind>-agent:<label>, the `pane
# rename` below - and herdr is where it is looked up again. That is deliberate:
# a handle file could not be found by both sides, because ac_home() forks
# (a crewmate-run caller - the ship reviewer, qa - has no AC_HOME, so it
# resolves no state/ at all, and before ac_home refused it resolved the distro
# checkout's, while the steering chief's is its fleet
# home's), whereas herdr's pane list is the ONE registry both already share, and
# a chief that never launched the pane reads the same name off the herdr
# sidebar. Ownership is PROVEN before delivery, the way the kill proves a tab
# (ac-backend.sh KILL OWNERSHIP PROOF): the handle must resolve to exactly ONE
# live pane still carrying an ac-<kind>-agent:<label> name, so a dead or
# recycled pane refuses instead of steering a stranger. Two live panes on one
# handle (two repos at ship-review-r1) is AMBIGUOUS and also refuses, naming
# --pane <pane-id> as the way through; --pane takes the same ownership proof, so
# it disambiguates without becoming a backdoor into a crewmate's pane. Delivery
# is VERIFIED (backend_send_line_pane): unacknowledged means a loud non-zero
# refusal naming the pane, never a silent strand - and since that twin prints
# nothing, its exit status is what the refusal reads: 2 means the pane could
# not be READ (submit neither confirmed nor refuted, read it before resending),
# anything else means the text is stranded in its composer (resubmit the Enter).
# Unlike the pane a crewmate owns, this one is addressed by NOTHING the caller
# had to hoard - ac-ship.sh's <run>/review.pane and ac-qa.sh's
# agent-<task>.pane stay their own business.
#
# GATE INDEPENDENCE GUARD, stated with its RESIDUAL in the same breath because
# the two are one contract (captain ruling 2026-07-22): a steer into an
# ac-gate-agent:<family>-<stage> pane is REFUSED unless the caller declares
# --captain. The gate judge is the one pane agent whose whole value is that the
# chief whose stage it judges did not shape its turn, and what this refuses is
# the ACCIDENTAL steer - a chief reaching for this helper without noticing that
# the handle names the judge about to rule on its own work. Every OTHER pane
# agent steers unchanged: this guards a judge, not every verification pane.
# WHO is steering is DECLARED by the caller and never inferred from the
# environment - no tty sniffing, no parent-process inspection, no AC_SCOPE
# reading; the precedent is ac-spawn.sh's --captain-initiated. An inferred
# distinction would misfire in both directions while READING as
# non-bypassable, which is worse than a guard that says what it is.
# THE GUARD IS ADVISORY, AND A DETERMINED CHIEF CAN BYPASS IT. This script is
# an executable any chief may invoke with --captain, and a chief can write
# straight to the herdr pane without coming near it at all. That is the
# captain's decision rather than an oversight: it stops the accidental steer,
# not the deliberate one. A later reader who finds a bypass has found
# DOCUMENTED BEHAVIOUR, not a defect - so do not "harden" this into a
# proof it was never ruled to be.
#
# Turn-end (SESSION arm): a Stop hook in DIR/.claude/settings.local.json touches
# a per-invocation marker.
#
# TURN-END ISOLATION (the authoritative contract): that hook is MERGED into the
# file, never written over it. Two pane agents share ONE worktree in practice -
# the ship reviewer (ac-ship.sh review-agent) and the qa agent (ac-qa.sh agent)
# both run with --cwd the same crewmate worktree - and the old whole-file
# truncate deleted whichever hook was already there, so the agent mid-turn lost
# its turn-end and degraded to the 120s idle fallback below, or timed out; it
# also deleted any permission grant claude itself had written into that same
# file under --permission-mode auto. So: read, append our own entry to
# hooks.Stop, publish by atomic replace - all under a mkdir lock
# (.claude/.ac-pane-agent.lock, git-excluded like the settings file it guards)
# so two overlapping read-modify-write cycles cannot lose an entry. Only OUR
# OWN entries are ever dropped, and only when the pid in their marker path is
# gone: a live agent's hook always survives, while the array still cannot grow
# without bound across many runs. A malformed or hand-edited file fails SOFT to
# a fresh one rather than killing the launch.
#
# IDLE FALLBACK (the authoritative contract): transcript idle >120s with a final
# assistant message AND an idle herdr agent_status also ends the turn, in case
# project hooks fail to load. It EXISTS for a recorded reason and is not to be
# tightened into uselessness: the Stop hook can fail to fire, and long
# xhigh-thinking stretches write nothing to the transcript for minutes, which is
# why transcript mtime alone once declared turns finished early (the root cause
# of truncated reviews on large repos). SESSION ARM ONLY, structurally: inside
# the wait loop TRANSCRIPT is set by announce_transcript alone, which runs under
# `[ "$ARM" != session ] ||`, and the fallback is gated on a non-empty
# TRANSCRIPT - the other two arms fail closed at their own turn-end harvest.
# Its three questions - pane idle, transcript stale, any final text - ask
# NOTHING about whether the agent's WORK was produced, and has_final_text is
# satisfied by any assistant text anywhere, an aborted turn's last message
# included. That is how a learning scout which hit the org monthly spend limit
# after 23 Reads reported status ok having written no report, and its caller then
# consumed the retro window on it (data/learning/room.md 13:36:13Z).
# So a caller MAY DECLARE the artifact its prompt demanded, with --deliverable
# <path>, and this exit then refuses a pane that idled without it - status error,
# carrying the pane so the caller can still reap the agent, rather than burning
# the caller's whole timeout. Absent or EMPTY is no deliverable, the same rule
# the crewmate arm's verdict file is held to. The declaration is OPTIONAL and
# consulted NOWHERE ELSE: the turn-end exit already fails closed per arm, and a
# caller that declares nothing keeps this exit byte-for-byte as it was - which
# is right for the verification panes, whose deliverable IS the transcript their
# caller then schema-checks.
#
# BUSY-STALL BOUND (SESSION arm): the idle
# fallback above is gated on an idle/done agent_status, so a pane hung INSIDE
# one tool call behind a busy status - static transcript, static footer - was
# unbounded: nothing fired until the caller's whole timeout burned, reading as
# a slow reviewer (the known worst case of this class: a catastrophic-
# backtracking regex hung one bash call for a full day behind "Working..."). A transcript static past
# AC_PANE_STALL_MAX seconds (default 2700, 0 disables) now escalates status
# error carrying the pane - the clock runs from the LATER of the last
# transcript write and the wait's own start, so a resumed session's prior-turn
# mtime never counts - whatever agent_status claims: busy is evidence of
# a process, never of progress; an UNREADABLE status rides along for diagnosis
# and never vetoes the escalation. The default sits an order of magnitude past
# the longest xhigh no-write thinking stretch the idle fallback's 120s floor
# was built around, so the bound cannot re-introduce the truncated-review
# defect that floor exists to prevent.
#
# Trust: the worktree is
# pre-seeded as trusted in ~/.claude.json so the session starts undialoged.
# Placement: the pane lands in its FAMILY's workspace (ac-backend.sh FAMILY
# WORKSPACE GROUPING; captain order 2026-08-06) - the caller (ac-verify.sh,
# ac-gate.sh) exports AC_WINDOW_FAMILY, and ac_herdr_agents_workspace resolves
# the "<fleet> · <family>" workspace from it; absent/empty = the fleet ROOT
# workspace (the ac-self-task case). The former separate per-role
# '<fleet> (pane-agent)' group and its config/herdr-workspace-agents knob are
# retired. Session:
# AC_HERDR_SESSION > config/herdr-session > default.
# macOS-only bits: stat -f %m.
set -u
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"   # backend_capture_pane: the scrollback harvest
# Harden PATH: callers may start from launchd with a minimal environment.
PATH="$PATH:/opt/homebrew/bin:$HOME/.local/bin"
SES="${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}"
WS=""  # resolved lazily by agents_ws_create - resolving it HERE reached the
       # herdr server (workspace list/close-twins/create) on every invocation,
       # including `close` and a usage error. Only `run` places a pane.

emit() { printf '%s\n' "$1"; }
fail() { emit "{\"event\":\"done\",\"status\":\"error\",\"error\":\"$1\"}"; exit 1; }

# `close --pane ID` - retire a pane (ac-ship.sh finish calls this)
if [ "${1:-}" = close ]; then
  shift
  CP=""
  while [ $# -gt 0 ]; do case "$1" in --pane) CP=${2:?}; shift ;; esac; shift; done
  [ -n "$CP" ] && herdr --session "$SES" pane close "$CP" >/dev/null 2>&1
  exit 0
fi

# `steer --agent HANDLE '<text>'` - deliver ONE line to a LIVE pane agent
# (contract: the STEER block in the header). Human-facing like ac-send.sh, so it
# refuses on stderr and exits non-zero - it speaks no NDJSON.
if [ "${1:-}" = steer ]; then
  shift
  SH=""; SP=""; STEXT=""; SCAP=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) SH=${2:?}; shift ;;
      --pane) SP=${2:?}; shift ;;
      --captain) SCAP=1 ;;
      -*) ac_die "unknown arg $1" ;;
      *) [ -z "$STEXT" ] || ac_die "steer takes ONE line of text"; STEXT="$1" ;;
    esac
    shift
  done
  [ -n "$SH" ] || [ -n "$SP" ] \
    || ac_die "usage: ac-pane-agent.sh steer --agent <handle> '<text>' [--pane <pane-id>]"
  [ -n "$STEXT" ] || ac_die "refusing to steer with an empty message"
  command -v herdr >/dev/null 2>&1 || ac_die "herdr not on PATH"
  # Resolve the handle against herdr's LIVE panes - the registry both a homed
  # chief and a homeless caller share. A dead or recycled pane simply is not in
  # the list, so a stale handle can never steer a stranger.
  plan="$(herdr --session "$SES" pane list 2>/dev/null \
    | SH="$SH" SP="$SP" python3 -c '
import sys, json, os
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    panes = []
want, pid = os.environ["SH"], os.environ["SP"]
def label(p): return p.get("label") or ""
# A pane agent is exactly a pane THIS helper named at creation.
agents = [p for p in panes if label(p).startswith("ac-") and "-agent:" in label(p)]
if pid:
    m = [p for p in agents if p.get("pane_id") == pid]
    print("OK %s %s" % (m[0]["pane_id"], label(m[0])) if m else "NOTAGENT")
else:
    m = [p for p in agents if label(p) == want]
    if not m:
        print("NONE")
    elif len(m) > 1:
        print("AMBIG %d %s" % (len(m), " ".join(p["pane_id"] for p in m)))
    else:
        print("OK %s %s" % (m[0]["pane_id"], label(m[0])))
for p in agents:
    print("KNOWN", label(p), p["pane_id"])
')"
  KNOWN="$(printf '%s\n' "$plan" | sed -n 's/^KNOWN \(.*\) [^ ]*$/\1/p' | paste -sd, - | sed 's/,/, /g')"
  read -r VKIND VPANE VREST <<EOF
$(printf '%s\n' "$plan" | head -1)
EOF
  case "$VKIND" in
    OK) ;;
    AMBIG) ac_die "handle '$SH' matches $VPANE live panes ($VREST) - re-run with --pane <pane-id> to name the one you mean" ;;
    NOTAGENT) ac_die "pane '$SP' is not a live pane agent (no ac-<kind>-agent:<label> name) - refusing to steer a stranger's pane; live pane agents: ${KNOWN:-none}" ;;
    *) ac_die "no live pane agent named '$SH' - live pane agents: ${KNOWN:-none}" ;;
  esac
  # GATE INDEPENDENCE GUARD (contract: the STEER block in the header). Applied
  # after the pane RESOLVES, so --agent and --pane are guarded by the one check
  # and the refusal can name the pane it stopped.
  case "$VREST" in
    ac-gate-agent:*)
      GFAM="${VREST#ac-gate-agent:}"   # <family>-<stage>, the label ac-gate.sh mints
      [ "$SCAP" = 1 ] || ac_die "refusing to steer $VREST (pane $VPANE): it is the INDEPENDENT GATE JUDGE for family '${GFAM%-*}' - the chief whose stage it judges must not shape the turn that rules on it. If you are the captain, say so: --captain (the captain outranks this property)."
      ;;
  esac
  SRC=0
  backend_send_line_pane "$VPANE" "$STEXT" || SRC=$?
  case "$SRC" in
    0) ;;
    2) ac_die "delivery UNVERIFIED for $VREST (pane $VPANE) - could not read the pane, so the submit was neither confirmed nor refuted: read it with 'herdr pane read $VPANE' before resending" ;;
    *) ac_die "delivery NOT confirmed for $VREST (pane $VPANE) - the text likely sits stranded unsubmitted in its composer: read it with 'herdr pane read $VPANE', resubmit with 'herdr pane send-keys $VPANE enter'" ;;
  esac
  printf 'steered %s (pane %s)\n' "$VREST" "$VPANE"
  exit 0
fi

# `reap-pane --pane ID` - best-effort retire ONE known pane and tidy up after it.
#
# ac-learn.sh's `learning` scout leaves its pane OPEN when cmd_run returns.
# Unlike `reap` (keyed on a DEAD cwd, which never fires while the scout's run
# dir still exists) this targets a KNOWN pane id, and adds the last-tab-in-
# workspace close the crewchief had to do by hand. The pane-agent workspace is
# SHARED with concurrent ship/qa panes, so this closes ONLY pane ID: then its
# tab, but only if ID was alone there; and `workspace close`, but ONLY when that
# tab was the workspace's last one (a surviving co-tenant tab keeps the
# workspace alive). Every herdr step is best-effort and the verb always exits 0,
# so a caller can arm it as an EXIT trap without risking its own exit code.
# Because of that the exit status carries NO outcome, so the done event does:
# `closed` is VERIFIED with `pane get` after the attempt (true = the pane no
# longer resolves). Surfacing a `closed":false` is the CALLER's job - see
# REAP OUTCOME below.
if [ "${1:-}" = reap-pane ]; then
  shift
  RP=""
  while [ $# -gt 0 ]; do case "$1" in --pane) RP=${2:?}; shift ;; esac; shift; done
  [ -n "$RP" ] || { emit '{"event":"reap-pane","note":"no pane id"}'; exit 0; }
  command -v herdr >/dev/null 2>&1 || { emit '{"event":"reap-pane","note":"herdr not on PATH"}'; exit 0; }
  plan="$(printf '%s\n===AC-SPLIT===\n%s\n' \
      "$(herdr --session "$SES" tab list 2>/dev/null || true)" \
      "$(herdr --session "$SES" pane list 2>/dev/null || true)" \
    | RP="$RP" python3 -c '
import sys, json, os
raw = sys.stdin.read().split("===AC-SPLIT===")
def load(s):
    try: return json.loads(s)
    except Exception: return {}
tabs  = load(raw[0]).get("result", {}).get("tabs", [])  if len(raw) > 0 else []
panes = load(raw[1]).get("result", {}).get("panes", []) if len(raw) > 1 else []
target = os.environ["RP"]
tab_of = {p.get("pane_id"): p.get("tab_id") for p in panes}
ws_of  = {t.get("tab_id"): t.get("workspace_id") for t in tabs}
T  = tab_of.get(target)
WS = ws_of.get(T)
# A sibling pane in the same tab keeps the tab; another tab in the same
# workspace (a co-tenant reviewer/qa run, or the bare default "1" tab) keeps
# the workspace. Close the workspace ONLY when the target tab is its last.
siblings   = [p for p in panes if p.get("tab_id") == T and p.get("pane_id") != target]
other_tabs = [t for t in tabs if WS and t.get("workspace_id") == WS and t.get("tab_id") != T]
print("PANE", target)
if T and not siblings:
    if other_tabs:
        print("TAB", T)
    elif WS:
        print("WS", WS)
')"
  while read -r kind id; do
    [ -n "$kind" ] || continue
    case "$kind" in
      PANE) herdr --session "$SES" pane close "$id" >/dev/null 2>&1 || true ;;
      TAB)  herdr --session "$SES" tab close "$id" >/dev/null 2>&1 || true ;;
      WS)   herdr --session "$SES" workspace close "$id" >/dev/null 2>&1 || true ;;
    esac
  done <<EOF
$plan
EOF
  # Whether the close TOOK is verified and REPORTED, never assumed. Every herdr
  # step above is best-effort and this verb always exits 0 by contract, so its
  # exit status can never distinguish a retired pane from an orphaned one - and
  # that silence is precisely how pane agents accumulated unnoticed. `pane get`
  # is the same liveness probe the run loop uses: a pane that no longer resolves
  # is gone, one that still does was NOT closed. The caller surfaces it.
  closed=true
  herdr --session "$SES" pane get "$RP" >/dev/null 2>&1 && closed=false
  emit "{\"event\":\"reap-pane-done\",\"pane\":\"$RP\",\"closed\":$closed}"
  exit 0
fi

# `reap [--dry-run]` - close ac-*-agent panes whose launch cwd is gone.
#
# A pane rooted in a worktree that was later removed (qa-wt cleaned up, a pool
# slot pruned, a `git worktree remove` by hand) is dead weight: claude's process
# cwd no longer exists, so EVERY child spawn - each tool call, each Stop hook -
# fails `posix_spawn '/bin/sh' ENOENT` and the pane can do nothing but print
# those errors. ac-ship.sh finish closes its own pane; nothing closes one left by
# manual worktree removal, and no caller can (the removal happens outside them).
# Reaping by dead-cwd catches every source. Only OUR panes (tab label
# matching ac-<kind>-agent - every --kind this helper ever created) are
# touched, and only when the recorded cwd is truly absent - a live review's
# cwd exists, so it is never a candidate.
if [ "${1:-}" = reap ]; then
  shift
  dry=0
  while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=1 ;; *) fail "unknown arg $1" ;; esac; shift; done
  command -v herdr >/dev/null 2>&1 || { emit '{"event":"reap","panes":0,"tabs":0,"note":"herdr not on PATH"}'; exit 0; }
  plan="$(printf '%s\n===AC-SPLIT===\n%s\n' \
      "$(herdr --session "$SES" tab list 2>/dev/null || true)" \
      "$(herdr --session "$SES" pane list 2>/dev/null || true)" \
    | python3 -c '
import sys, json, os, re
from collections import defaultdict
raw = sys.stdin.read().split("===AC-SPLIT===")
def load(s):
    try: return json.loads(s)
    except Exception: return {}
tabs  = load(raw[0]).get("result", {}).get("tabs", [])  if len(raw) > 0 else []
panes = load(raw[1]).get("result", {}).get("panes", []) if len(raw) > 1 else []
ours  = {t.get("tab_id"): (t.get("label") or "") for t in tabs
         if re.match(r"ac-[a-z0-9-]+-agent(-|$)", t.get("label") or "")}
by_tab = defaultdict(list)
for p in panes:
    by_tab[p.get("tab_id")].append(p)
dead = set()
for tid in ours:
    for p in by_tab.get(tid, []):
        cwd = p.get("cwd") or ""
        if cwd and not os.path.isdir(cwd):
            print("PANE", p.get("pane_id"), cwd)
            dead.add(p.get("pane_id"))
# A tab whose every pane is being reaped is left empty; close it too so the
# sidebar does not fill with stubs. A tab with a surviving pane stays.
for tid in ours:
    ps = by_tab.get(tid, [])
    if ps and all(p.get("pane_id") in dead for p in ps):
        print("TAB", tid)
')"
  npane=0; ntab=0
  while read -r kind id rest; do
    [ -n "$kind" ] || continue
    case "$kind" in
      PANE)
        emit "{\"event\":\"reap\",\"pane\":\"$id\",\"cwd\":\"$rest\",\"dry_run\":$dry}"
        [ "$dry" = 1 ] || herdr --session "$SES" pane close "$id" >/dev/null 2>&1
        npane=$((npane + 1)) ;;
      TAB)
        [ "$dry" = 1 ] || herdr --session "$SES" tab close "$id" >/dev/null 2>&1
        ntab=$((ntab + 1)) ;;
    esac
  done <<EOF
$plan
EOF
  emit "{\"event\":\"reap-done\",\"panes\":$npane,\"tabs\":$ntab,\"dry_run\":$dry}"
  exit 0
fi

[ "${1:-}" = run ] || fail "usage: ac-pane-agent.sh run --cwd DIR --prompt-file F"
shift
CWD=""; PF=""; SID=""; LABEL=agent; TIMEOUT=7200; REPLACE=""; PANEFILE=""
MODEL=""; EFFORT=""; KIND=ship
HFLAG=""; EXEC=0; OBSERVE=""; DELIVERABLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD=${2:?}; shift ;;
    --prompt-file) PF=${2:?}; shift ;;
    --resume) SID=${2:?}; shift ;;
    --label) LABEL=${2:?}; shift ;;
    --kind) KIND=${2:?}; shift ;;
    --timeout) TIMEOUT=${2:?}; shift ;;
    --replace-pane) REPLACE=${2:?}; shift ;;
    --pane-file) PANEFILE=${2:?}; shift ;;
    --model) MODEL=${2:?}; shift ;;
    --effort) EFFORT=${2:?}; shift ;;
    --harness) HFLAG=${2:?}; shift ;;
    --exec) EXEC=1 ;;
    # --observe <path>: publish a read-only observation descriptor (pane/tab
    # identity + the real prompt/stdout/stderr file paths) BEFORE launching the
    # harness, so an observer (ac-gate-watch) can tail the ACTIVE one-shot run.
    # --exec ONLY; normal verdict harvest is unchanged; the CALLER removes it.
    --observe) OBSERVE=${2:?}; shift ;;
    # --deliverable <path>: the artifact the caller's prompt told the agent to
    # WRITE, consulted by the idle fallback alone (contract: IDLE FALLBACK in
    # the header). Optional - no declaration leaves that exit as it was. ABSOLUTE:
    # THIS process reads it, and its cwd is the caller's, never the pane's --cwd.
    --deliverable) DELIVERABLE=${2:?}; shift ;;
    *) fail "unknown arg $1" ;;
  esac
  shift
done
# --exec has no session to resume: the turn IS a process, and it ends by
# exiting. Refusing beats ignoring - a caller that passed --resume believes it
# is continuing a conversation. (The crewmate arm refuses it too, on the same
# grounds, once the harness is resolved below.)
[ "$EXEC" = 1 ] && [ -n "$SID" ] && fail "--exec runs a one-shot command: there is no session to --resume"
# --observe is an --exec-only observability seam (the one-shot run has private
# stdout/stderr an observer cannot otherwise discover).
[ -n "$OBSERVE" ] && [ "$EXEC" != 1 ] && fail "--observe is only valid with --exec (the one-shot arm)"
case "$KIND" in ''|*[!a-z0-9-]*) fail "kind must be [a-z0-9-]: $KIND" ;; esac
# No caller flag -> the fleet's. Callers split into two worlds: a chief-run
# caller (ac-learn.sh's scout) HAS AC_HOME and config/ resolves; a crewmate-run
# caller (ac-ship.sh review-agent, ac-qa.sh agent) has none, and for it
# ac-spawn.sh puts the resolved values on the crewmate launch line. The env rung
# is what stops a homeless judge from silently running at claude's own default.
#
# VERIFICATION panes (codereview, qa) get their OWN per-role knobs, all three
# decoupled from the fleet crewmate defaults (captain's call: verification runs
# on the strongest model, never a quieter judge than the fleet pinned):
#   MODEL:  flag > AC_FLEET_MODEL_<KIND> env (threaded by ac-spawn from
#           config/<kind>-model) > config/<kind>-model (AC_HOME callers) > opus.
#   AGENT:  flag(--harness) > AC_FLEET_AGENT_<KIND> env (from config/<kind>-agent)
#           > config/<kind>-agent (AC_HOME callers) > claude - the SAME rung the
#           MODEL knob occupies, so an --agent pin and its --model/--effort
#           siblings are chosen together, never composed across rungs.
#   EFFORT: flag > AC_FLEET_EFFORT_<KIND> env (from config/<kind>-effort) >
#           config/<kind>-effort (AC_HOME callers) > the plain fleet effort
#           ladder below (AC_FLEET_EFFORT > config/effort) - effort has no
#           natural "opus"-shaped terminal default, so an unset per-role knob
#           still falls through to the fleet's, exactly as it did before this
#           knob existed.
# Every OTHER kind keeps the plain fleet ladder (model/effort only - no per-kind
# agent knob exists outside codereview/qa).
#
# Above BOTH of those sits the DISPATCHED PANE PROFILE (contract: the PANE
# PROFILE block in the header) - harness+model+effort resolved together for
# this --kind. Two rungs, mirroring the model knob's for the same reason: the
# env scalar ac-spawn threads to a homeless caller, then config/ for a homed
# one. No profile leaves everything below EXACTLY as it was.
ku="$(printf '%s' "$KIND" | tr '[:lower:]-' '[:upper:]_')"
penv="AC_FLEET_PROFILE_$ku"
PROFILE="${!penv:-}"
if [ -z "$PROFILE" ]; then
  # Absent resolves to empty with exit 0 and falls through; a resolver ERROR
  # (a panes entry naming no harness, unreadable JSON, no jq) must NOT - a
  # misconfigured profile that quietly degraded to the ladder below would put
  # the fleet's judge back on the defaults without saying so, which is the
  # silent-wrong-answer failure this whole ladder exists to end.
  prc=0
  PROFILE="$(ac_pane_profile "$KIND" 2>/dev/null)" || prc=$?
  [ "$prc" = 0 ] \
    || fail "could not resolve a pane profile for kind '$KIND' - see bin/ac-dispatch-select.sh --pane $KIND"
fi
# CONTRADICTION CHECK (codereview only): config/codereview-agent (or its
# AC_FLEET_AGENT_CODEREVIEW env rung) is a real, working knob, and a
# DISPATCHED panes.codereview profile deliberately outranks it (the ATOMIC
# rule above) - correct by design, but nothing ever told a human when the
# two DISAGREE, so a fleet that pinned codex there kept reviewing on
# whatever panes.codereview's default names instead, silently (it fooled the
# reviewing agent too, not just a human reading the config). Both rungs are
# visible RIGHT HERE, before the branch below commits to the profile - the
# one point that needs no new config resolution to catch it (the config-only
# read mirrors the `else` branch's own two lines below, only hoisted so it
# runs even when a profile also resolved). WARN, never refuse: a refusal
# would break every fleet that already carries both knobs on its very next
# review. Only a REPORT here (`emit`, same NDJSON stream every other event
# already rides) - the CALLER surfaces it (REAP OUTCOME above: "the helper
# reports; the CALLER surfaces"; ac-verify.sh folds this into the verdict a
# chief actually reads).
if [ "$KIND" = codereview ] && [ -z "$HFLAG" ] && [ -n "$PROFILE" ]; then
  ku_agent_env="AC_FLEET_AGENT_$ku"
  ku_configured="${!ku_agent_env:-}"
  [ -n "$ku_configured" ] || ku_configured="$(ac_config_read "$KIND-agent" "")"
  if [ -n "$ku_configured" ]; then
    read -r ku_p_h _ _ <<EOF
$PROFILE
EOF
    ku_p_h="${ku_p_h#harness=}"
    if [ -n "$ku_p_h" ] && [ "$ku_p_h" != "$ku_configured" ]; then
      emit "{\"event\":\"warning\",\"reason\":\"codereview-agent-mismatch\",\"message\":\"config/codereview-agent=$ku_configured but the dispatched panes.codereview profile resolved harness=$ku_p_h - the profile wins by design (ATOMIC-profile contract), so this round runs on $ku_p_h, not the configured engine\"}"
    fi
  fi
fi
HARNESS=claude
if [ -n "$HFLAG" ]; then
  # An explicit --harness means the CALLER owns the WHOLE triple: no profile
  # model/effort, no ladder below. This is the flag-vs-profile coherence item 5
  # of HARNESS ARMS demands, discharged at its only entry point - a profile's
  # model was authored FOR the profile's harness, so composing it onto a
  # different one is the `codex -m opus` incoherence the atomic rule exists to
  # prevent. Anything the caller did not pass stays EMPTY, i.e. that harness's
  # own default, exactly as an unset gate knob has always behaved.
  HARNESS="$HFLAG"
elif [ -n "$PROFILE" ]; then
  # A profile is ATOMIC: its model and effort are taken AS-IS, INCLUDING EMPTY.
  # Empty means the harness's own default, never the ladder below - falling
  # through would compose a claude model name onto a non-claude harness, which
  # is exactly the incoherence keeping the triple in one object prevents.
  read -r p_h p_m p_e <<EOF
$PROFILE
EOF
  HARNESS="${p_h#harness=}"
  [ -n "$MODEL" ] || MODEL="${p_m#model=}"
  [ -n "$EFFORT" ] || EFFORT="${p_e#effort=}"
else
  case "$KIND" in
    codereview|qa)
      kenv="AC_FLEET_MODEL_$ku"
      [ -n "$MODEL" ] || MODEL="${!kenv:-}"
      [ -n "$MODEL" ] || MODEL="$(ac_config_read "$KIND-model" "")"
      [ -n "$MODEL" ] || MODEL="opus"
      aenv="AC_FLEET_AGENT_$ku"
      # Unguarded, unlike its MODEL/EFFORT siblings above and below: reaching
      # this branch already means no --harness flag (that arm returned first),
      # so HARNESS still holds the bare `claude` initialiser and there is no
      # caller value here to preserve.
      HARNESS="${!aenv:-}"
      [ -n "$HARNESS" ] || HARNESS="$(ac_config_read "$KIND-agent" "")"
      [ -n "$HARNESS" ] || HARNESS="claude"
      eenv="AC_FLEET_EFFORT_$ku"
      [ -n "$EFFORT" ] || EFFORT="${!eenv:-}"
      [ -n "$EFFORT" ] || EFFORT="$(ac_config_read "$KIND-effort" "")"
      ;;
    *)
      [ -n "$MODEL" ] || MODEL="${AC_FLEET_MODEL:-}"
      [ -n "$MODEL" ] || MODEL="$(ac_config_read model "")"
      ;;
  esac
  [ -n "$EFFORT" ] || EFFORT="${AC_FLEET_EFFORT:-}"
  [ -n "$EFFORT" ] || EFFORT="$(ac_config_read effort "")"
fi
# Resolved and validated HERE - before the cwd/prompt checks and long before a
# pane is placed - so a bad knob fails through the NDJSON error protocol instead
# of leaking a live pane whose claude then refuses the flag. ultracode is the
# claude preset's reasoning tier only (see the header): xhigh, no slash line.
EFFORT_FLAG="$EFFORT"
case "$EFFORT" in
  '' | low | medium | high | xhigh | max) ;;
  ultracode) EFFORT_FLAG=xhigh ;;
  *) fail "invalid effort: $EFFORT (expected low|medium|high|xhigh|max|ultracode)" ;;
esac
oneshot_launch() {
  # oneshot_launch <harness> [model] [effort] - the NON-INTERACTIVE one-shot
  # command form of a harness, the ONE-SHOT ARM's prompt-delivery half. These
  # live HERE, next to the arm that needs them, while ac-backend.sh's
  # ac_build_launch owns the INTERACTIVE launch lines every long-lived agent
  # starts with: two different shapes for two different lifecycles, and the
  # one-shot table has exactly one consumer today (bin/ac-gate.sh), so sharing
  # it before a second appears would buy nothing. Effort is per-harness in
  # SHAPE as well as value: codex takes a config override, claude a flag,
  # opencode a variant. An unset knob passes NOTHING, leaving the engine's own
  # default in charge. Only the three forms that exist today - a harness with
  # no proven one-shot form is refused below, never guessed at.
  # codex also always carries `-c model_reasoning_summary=auto` (captain
  # decision 2026-07-26): a real gate run emits no reasoning bytes by codex's
  # own default (`none`), which this table's one consumer (the gate) needs to
  # show the captain - `auto` is the smallest footprint that still answers it.
  case "$1" in
    codex)    printf 'codex exec -s read-only --skip-git-repo-check%s%s -c model_reasoning_summary=auto\n' "${2:+ -m $2}" "${3:+ -c model_reasoning_effort=$3}" ;;
    claude)   printf 'claude -p%s%s\n' "${2:+ --model $2}" "${3:+ --effort $3}" ;;
    opencode) printf 'opencode run%s%s\n' "${2:+ -m $2}" "${3:+ --variant $3}" ;;
    *) return 1 ;;
  esac
}
# Refused on the same rung and for the same reason (contract: HARNESS ARMS in
# the header): a harness with no implemented arm FOR THE MODE ASKED FOR never
# gets a pane. Placing one is worse than refusing - it costs the caller a whole
# timeout per round and then reports status:timeout, which reads like a slow
# reviewer rather than a misconfiguration. The two modes arm SEPARATELY: a
# one-shot form proves nothing about the same harness's TUI, so arming codex
# for --exec leaves ship/qa refusing it on their interactive rung.
ARM=session
if [ "$EXEC" = 1 ]; then
  ARM=oneshot
  oneshot_launch "$HARNESS" >/dev/null \
    || fail "harness '$HARNESS' has no one-shot form here (armed for --exec: codex, claude, opencode) - a one-shot arm owes the command form whose process exit is the turn end and whose stdout is the final message; see HARNESS ARMS in bin/ac-pane-agent.sh"
else
  # The interactive arm map is the harness registry's (ac_harness_pane_arm,
  # bin/ac-harness.sh): claude as a pane SESSION, codex/opencode through the
  # CREWMATE contract - exactly the harnesses VERIFIED to complete under it
  # (harness-facts.md). A third harness is not guessed at: it is refused
  # until somebody verifies the same thing about it.
  ARM="$(ac_harness_pane_arm "$HARNESS")" \
    || fail "harness '$HARNESS' has no arm here for an interactive turn (armed: claude as a pane SESSION; codex and opencode through the CREWMATE contract) - arming another means VERIFYING that it writes its final message where its brief tells it to and announces its own completion; see HARNESS ARMS in bin/ac-pane-agent.sh"
fi
# Same refusal, same grounds as --exec above: neither codex nor opencode pins a
# caller-minted session id (harness-facts.md Resume bullets), so this arm opens
# nothing to continue and a caller that passed one believes otherwise.
[ "$ARM" = crewmate ] && [ -n "$SID" ] \
  && fail "the crewmate arm runs '$HARNESS', which Agent Crew cannot resume: there is no session to --resume"
[ -d "$CWD" ] || fail "cwd missing: $CWD"
[ -f "$PF" ] || fail "prompt file missing: $PF"
command -v herdr >/dev/null 2>&1 || fail "herdr not on PATH"

SLUG=$(printf '%s' "$CWD" | sed 's/[/.]/-/g')
PROJ="$HOME/.claude/projects/$SLUG"

# 1. pre-seed workspace trust so the claude session starts undialoged. SESSION
# arm only: the other two open no claude session, so there is no dialog to
# pre-empt - and the seed writes the CALLER'S cwd into ~/.claude.json, which a
# mode that needs no claude trust must not do as a side effect. (The crewmate
# arm's own startup dialog is codex's, answered at the pane - see the launch
# step below; nothing of the user's global state is written for it.)
[ "$ARM" != session ] || python3 - "$CWD" <<'PY' 2>/dev/null || true
import json, os, sys
p = os.path.expanduser('~/.claude.json')
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
e = d.setdefault('projects', {}).setdefault(sys.argv[1], {})
if e.get('hasTrustDialogAccepted') and e.get('hasCompletedProjectOnboarding'):
    sys.exit(0)
e['hasTrustDialogAccepted'] = True
e['hasCompletedProjectOnboarding'] = True
tmp = p + '.ac-pane-agent'
json.dump(d, open(tmp, 'w'), indent=2)
os.replace(tmp, p)
PY

# 2. Stop-hook marker (per invocation). DETERMINISTIC path (no mktemp: a
# launchd-minimal PATH can make mktemp resolve empty, yielding `touch ''` in
# the hook). The hook is MERGED into settings.local.json, never written over
# it - contract: TURN-END ISOLATION in the header.
# The fleet's state dir, on the same rung its siblings use: AC_FLEET_STATE
# (what ac-verify.sh:1082 exports onto this pane's launch) > ac_state_dir >
# /tmp. Homeless is this script's NORMAL case (header), and ac_state_dir
# refuses there, so its diagnostic is swallowed DELIBERATELY: stdout and stderr
# are ONE stream to the caller (ac-verify.sh runs `"$pane_bin" ... >"$result"
# 2>&1` and jq-parses that file), and jq emits nothing at all once a non-JSON
# line is in it - so one stray diagnostic would fail every review round.
MARKDIR="${AC_FLEET_STATE:-}"
[ -n "$MARKDIR" ] || MARKDIR="$(ac_state_dir 2>/dev/null || true)"
[ -n "$MARKDIR" ] && MARKDIR="$MARKDIR/.pane-agent-tmp" || MARKDIR="/tmp"
mkdir -p "$MARKDIR" 2>/dev/null || MARKDIR="/tmp"
MARKER="$MARKDIR/ac-pane-turnend.$(basename "$CWD").$$"
rm -f "$MARKER" 2>/dev/null
# ONE-SHOT ARM: the marker is touched by the LAUNCH LINE itself (below), so the
# whole Stop-hook install is skipped and NOTHING is written into the caller's
# cwd - no .claude/, no lock, no git-exclude entry. Its stdout and exit status
# land next to the marker, in state/, for the same reason: the mode that needs
# no session must leave no trace in the directory it merely ran in.
OUTF="$MARKDIR/ac-pane-exec.$(basename "$CWD").$$.out"
ERRF="$MARKDIR/ac-pane-exec.$(basename "$CWD").$$.err"
RCF="$MARKDIR/ac-pane-exec.$(basename "$CWD").$$.rc"
# CREWMATE ARM: the same reasoning, one step further out. The AGENT touches
# $MARKER when it is done, having written its final message to $VERDICT; the
# launch line records the harness's own exit status and touches $EXITMARK, so a
# harness that died is a positive signal rather than a silent wait. All three
# live here in state/, never in the caller's cwd, and their ABSOLUTE paths are
# what the typed line hands the agent (contract: THE CREWMATE-ARM CONTRACT).
VERDICT="$MARKDIR/ac-pane-verdict.$(basename "$CWD").$$"
EXITMARK="$MARKDIR/ac-pane-crew.$(basename "$CWD").$$.exit"
CRCF="$MARKDIR/ac-pane-crew.$(basename "$CWD").$$.rc"
if [ "$ARM" = oneshot ]; then
  rm -f "$OUTF" "$ERRF" "$RCF" 2>/dev/null
elif [ "$ARM" = crewmate ]; then
  rm -f "$VERDICT" "$EXITMARK" "$CRCF" 2>/dev/null
else
mkdir -p "$CWD/.claude"
SETTINGS="$CWD/.claude/settings.local.json"
SLOCK="$CWD/.claude/.ac-pane-agent.lock"
# --path-format=absolute like ac_seed_crew_settings: --git-path alone answers a
# path relative to the CALLER's cwd, which is $CWD only by luck - from anywhere
# else the append silently missed the repo it was meant to cover.
EXCL=$(git -C "$CWD" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || true)
if [ -n "$EXCL" ]; then
  mkdir -p "$(dirname "$EXCL")" 2>/dev/null || true
  for pat in .claude/settings.local.json .claude/.ac-pane-agent.lock; do
    grep -qxF "$pat" "$EXCL" 2>/dev/null || echo "$pat" >> "$EXCL"
  done
fi
# Serialized: the two callers are seconds apart in practice, but two
# read-modify-write cycles that DO overlap would silently lose an entry - the
# very failure this merge exists to retire. A lock we could not take is never
# fatal (a wedged lock must not cost a turn); the atomic replace below still
# leaves a valid file either way.
LOCKED=0
ac_lock_acquire "$SLOCK" 10 && LOCKED=1
rc=0
python3 - "$SETTINGS" "$MARKER" <<'PY' || rc=$?
import json, os, re, sys

path, marker = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
    if not isinstance(d, dict):
        raise ValueError
except Exception:
    d = {}                      # malformed / hand-edited: fail soft, never crash
hooks = d.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
stop = hooks.get("Stop")
if not isinstance(stop, list):
    stop = []

# Drop OUR OWN entries whose pane agent is gone - matched on the marker path
# shape this script writes and keyed on the pid in it. A LIVE agent's hook
# always survives (its pid answers), so the concurrent case is safe; without
# this the array would grow by one entry per run, forever.
ours = re.compile(r"^touch '(?:.*/)?ac-pane-turnend\.[^/']*\.([0-9]+)'$")


def dead_of_ours(group):
    if not isinstance(group, dict):
        return False
    inner = group.get("hooks")
    if not isinstance(inner, list) or len(inner) != 1 or not isinstance(inner[0], dict):
        return False
    m = ours.match(str(inner[0].get("command", "")))
    if not m:
        return False
    try:
        os.kill(int(m.group(1)), 0)
    except ProcessLookupError:
        return True
    except Exception:
        return False            # EPERM and friends: assume alive, keep the hook
    return False


stop = [g for g in stop if not dead_of_ours(g)]
stop.append({"hooks": [{"type": "command", "command": "touch '%s'" % marker}]})
hooks["Stop"] = stop
d["hooks"] = hooks
tmp = path + ".ac-pane-agent"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, path)
PY
[ "$LOCKED" = 1 ] && ac_lock_release "$SLOCK"
[ "$rc" = 0 ] || fail "could not install the Stop hook into $SETTINGS"
fi

# 3. transcript before-set (new-session detection). Neither a one-shot command
# nor a crewmate-arm harness writes a claude transcript, and $PROJ for its cwd
# may well hold SOMEONE ELSE'S sessions (a chief runs claude in the fleet home),
# so the glob stays unread there - those arms harvest their own stdout / verdict
# file instead.
# shellcheck disable=SC2010  # transcript names are uuid.jsonl - glob-safe
BEFORE=$(ls "$PROJ" 2>/dev/null | grep '\.jsonl$' || true)

# 3b. tab label = ac-<kind>-agent[-<family>][-<branch>]; the kind names the
# CALLER (ship reviewer, qa, learning, ...) so the herdr sidebar says what
# the pane IS; branch comes straight from the worktree (no external state
# needed). The FAMILY rides the label because the reuse step below adopts
# by label SESSION-WIDE: a verifier lease sits on a detached exact-ref
# checkout, so BRANCH is empty and every codereview pane in the session
# used to share the bare label - the second family's verifier adopted the
# first family's tab and split into it, landing in the WRONG family
# workspace and bypassing AC_WINDOW_FAMILY entirely (FAMILY WORKSPACE
# GROUPING, captain order 2026-08-06). Family-scoping the label makes the
# session-wide adopt safe again: rounds of ONE task still stack (same
# family, same branch), cross-family adoption is impossible by name.
BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null || true)
TABLABEL="ac-$KIND-agent"
[ -n "${AC_WINDOW_FAMILY:-}" ] && TABLABEL="$TABLABEL-$AC_WINDOW_FAMILY"
[ -n "$BRANCH" ] && TABLABEL="$TABLABEL-$(printf '%s' "$BRANCH" | tr '/' '-')"

agents_ws_create() {
  # Re-resolve THE pane-agent group (adopt-by-label before create; ac-lib).
  WS="$(ac_herdr_agents_workspace 2>/dev/null || true)"
}
tab_create_in_ws() {
  # F26: the workspace-fallback tab create + pane-id sed shared with
  # ac-ship.sh/ac-qa.sh/ac-gate.sh now lives once in ac_herdr_tab_open
  # (ac-lib.sh); this caller always has a workspace by the time it is
  # called, so it always passes one.
  local created
  created="$(ac_herdr_tab_open "$SES" "$TABLABEL" "$CWD" "$WS")" || return 1
  P="${created%% *}"
  TAB="${created#* }"
  [ -n "$TAB" ] && [ -n "$P" ]
}

# 4. pane: adopt this family+branch's agent tab IN THE FAMILY WORKSPACE, else
# create it there. The workspace is resolved FIRST and scopes the adoption:
# a tab carrying the right label in the WRONG workspace (a pre-family-label
# leftover, a label collision) is never adopted, so the pane PROVABLY lands
# in its family's group (captain order 2026-08-11: the codereview pane must
# sit with its family - the label fix alone only made collisions unlikely,
# this makes placement structural). WS unresolvable (herdr degraded) falls
# back to label-only adoption - the same degrade direction the create path
# already takes.
agents_ws_create
TAB=$(herdr --session "$SES" tab list 2>/dev/null | TL="$TABLABEL" WSID="${WS:-}" python3 -c "
import sys, json, os
try:
    for t in json.load(sys.stdin)['result']['tabs']:
        if t.get('label') != os.environ['TL']: continue
        if os.environ['WSID'] and t.get('workspace_id') != os.environ['WSID']: continue
        print(t['tab_id']); break
except Exception:
    pass
" 2>/dev/null)
if [ -n "$TAB" ]; then
  OUT=$(herdr --session "$SES" pane list 2>/dev/null | TB="$TAB" python3 -c "
import sys, json, os
try:
    for p in json.load(sys.stdin)['result']['panes']:
        if p.get('tab_id') == os.environ['TB']:
            print(p['pane_id']); break
except Exception:
    pass
" 2>/dev/null)
  P=$(herdr --session "$SES" pane split "${OUT:-}" --direction right --no-focus 2>/dev/null \
      | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' | head -1)
else
  P=""
  [ -z "$WS" ] || tab_create_in_ws || true
  if [ -z "$P" ]; then
    agents_ws_create
    [ -z "$WS" ] || tab_create_in_ws || true
  fi
fi
[ -n "$P" ] || fail "could not create herdr pane"
[ -n "$TAB" ] || fail "could not resolve herdr tab for pane $P"
herdr --session "$SES" pane rename "$P" "ac-$KIND-agent:$LABEL" >/dev/null 2>&1
# Retire the workspace's default "1" tab once a real tab lives there -
# herdr spawns it with the workspace and it lingers as sidebar junk.
[ -n "$WS" ] && herdr --session "$SES" tab list 2>/dev/null | WSID="$WS" python3 -c "
import sys, json, os
try:
    for t in json.load(sys.stdin)['result']['tabs']:
        if t.get('workspace_id') == os.environ['WSID'] and t.get('label') == '1':
            print(t['tab_id'])
except Exception:
    pass
" 2>/dev/null | while read -r jt; do
  herdr --session "$SES" tab close "$jt" >/dev/null 2>&1
done

# Publish the live backend identity before the agent is launched. The verifier
# facade uses this to register supervision without racing a terminal done
# event; existing callers observe no new file or protocol event.
if [ -n "$PANEFILE" ]; then
  pane_dir=${PANEFILE%/*}
  [ "$pane_dir" != "$PANEFILE" ] || pane_dir=.
  [ -d "$pane_dir" ] || fail "pane-file directory does not exist: $pane_dir"
  pane_tmp="$PANEFILE.tmp.$$"
  if ! printf '%s %s\n' "$P" "$TAB" >"$pane_tmp" || ! mv "$pane_tmp" "$PANEFILE"; then
    rm -f "$pane_tmp"
    fail "could not publish pane identity: $PANEFILE"
  fi
fi

# 5. launch: prompt via argv from the prompt file (pane shell expands the cat)
# Pin the caller's fleet home onto the pane shell: a fresh pane inherits
# NOTHING, so without this every ac-*.sh the pane claude runs (qa start's
# watch_open, store resolution, room posts) had ac_home resolve to the DISTRO
# CHECKOUT - live symptom 2026-07-20 (under the retired per-role grouping):
# the qa-watch tab landed in a stray distro-named workspace instead of the
# fleet's own group.
# CONDITIONAL, and only on a REAL home: with no AC_HOME the caller has no
# home to pass on - ac_home() REFUSES rather than answering ac_root, so there
# is no FAKE home left to pin (a pool worktree that evaporates with the lease,
# or the distro checkout - the very collapse ac-qa.sh's header warns about)
# and contradict the documented design that the path travels in the brief,
# not the environment.
# The fleet NAME is the homeless arm of that same rung, and it IS passed on:
# what a caller cannot DERIVE it can still have been TOLD (ac-lib.sh
# ac_fleet_name, ac-spawn.sh's AC_FLEET_* contract). A homed caller needs
# nothing - the pane resolves the name first-hand off AC_HOME. A homeless one
# passes the name alone, never a path, so the pane's OWN ac-*.sh calls (qa
# start's watch_open) land their tabs in the fleet's group instead of the one
# every fleet on the box shares - a half fix would put the agent's tab in the
# right group and the tab IT opens in the shared one. Told nothing, it pins
# nothing: the name is never fabricated either, and ac_fleet_name lands the
# pane's resolve in one deliberate group instead.
#
# The claude command itself is NOT composed here: ac_build_launch (ac-backend.sh
# - the shared launch mote) owns the per-harness flags for every mechanism that
# starts an agent, so a crewmate pane and a verification pane launch the same
# way. This pane pins NO --session-id: a one-shot turn harvests its session id
# from the transcript (announce_transcript below), while a crewmate's must be
# resumable by id later. Only the env prefix and the positional prompt are this
# mechanism's own.
ENVPIN=""
if [ -n "${AC_HOME:-}" ]; then
  ENVPIN="AC_HOME=$(printf '%q' "$(ac_home)") "
elif [ -n "${AC_FLEET_NAME:-}" ]; then
  ENVPIN="AC_FLEET_NAME=$(printf '%q' "$AC_FLEET_NAME") "
fi
# The daemon-spawned pane does not inherit this process's env: forward a
# non-default claude config dir or the pane launches unauthenticated
# (contract: ac_claude_config_env, ac-backend.sh).
ENVPIN="$(ac_claude_config_env)$ENVPIN"
case "$ARM" in
  oneshot)
    # ONE-SHOT ARM. The turn is a PROCESS: its exit ends the turn (the trailing
    # touch, which is why no Stop hook is needed) and its stdout is the final
    # message. The exit status is RECORDED rather than inferred - a rung that
    # died is a positive signal here, where an interactive turn can only notice
    # that its harvest came back empty. `;` not `&&` on purpose: the marker must
    # fire on FAILURE too, or a dead engine would burn the caller's whole timeout
    # instead of failing in the seconds it actually took.
    RUNCMD="cd '$CWD' && ${ENVPIN}$(oneshot_launch "$HARNESS" "$MODEL" "$EFFORT_FLAG") \"\$(cat '$PF')\" >'$OUTF' 2>'$ERRF'; printf %s \$? >'$RCF'; touch '$MARKER'" ;;
  crewmate)
    # CREWMATE ARM. The harness launches BARE - no positional prompt, because
    # that convention is claude/codex-shaped and opencode reads its positional
    # as a project directory (HARNESS ARMS item 1). The prompt is typed in
    # below. The trailing record-and-touch is the one-shot arm's, kept for the
    # same reason and only for the same reason: the harness's own EXIT must be
    # observable, so a codex that refused its cwd or died on the startup dialog
    # is refused in seconds instead of waited out.
    RUNCMD="cd '$CWD' && ${ENVPIN}$(ac_build_launch "$HARNESS" "$MODEL" "$EFFORT_FLAG"); printf %s \$? >'$CRCF'; touch '$EXITMARK'" ;;
  *)
    RUNCMD="cd '$CWD' && ${ENVPIN}$(ac_build_launch "$HARNESS" "$MODEL" "$EFFORT_FLAG" "$SID") \"\$(cat '$PF')\"" ;;
esac
# --observe seam (oneshot ONLY): publish the read-only observation descriptor -
# pane/tab identity + the real prompt/stdout/stderr paths this run uses - BEFORE
# launching the harness, so ac-gate-watch can tail the ACTIVE run. Atomic
# (tmp+mv) so an observer never reads a half-written descriptor. The caller owns
# removal (on its own exit); harvest is untouched by its presence.
if [ -n "$OBSERVE" ] && [ "$ARM" = oneshot ]; then
  _obs_tmp="$OBSERVE.tmp.$$"
  printf '{"pane":"%s","tab":"%s","harness":"%s","prompt":"%s","out":"%s","err":"%s"}\n' \
    "$P" "$TAB" "$HARNESS" "$PF" "$OUTF" "$ERRF" >"$_obs_tmp" 2>/dev/null \
    && mv -f "$_obs_tmp" "$OBSERVE" 2>/dev/null || true
fi
herdr --session "$SES" pane run "$P" "$RUNCMD" >/dev/null 2>&1

# 6. retire the previous turn's pane once the new one is up. Best-effort and
# never fatal - the new pane is already placed - but the outcome is REPORTED the
# same way reap-pane reports its own, so a supersede that quietly left the old
# agent alive against the same task-scoped resources is visible to the caller
# instead of vanishing into the redirect.
if [ -n "$REPLACE" ]; then
  herdr --session "$SES" pane close "$REPLACE" >/dev/null 2>&1
  rclosed=true
  herdr --session "$SES" pane get "$REPLACE" >/dev/null 2>&1 && rclosed=false
  emit "{\"event\":\"replace-pane\",\"pane\":\"$REPLACE\",\"closed\":$rclosed}"
fi

# The caller's timeout starts HERE, at the launch - so the crewmate arm's own
# startup steps below are inside it, the way the session arm's claude startup
# always has been. A --timeout is the caller's whole budget, not the budget of
# the part after we finished setting up.
wait_start="$(date +%s)"
deadline=$(( wait_start + TIMEOUT ))

# 6b. CREWMATE ARM kickoff (contract: THE CREWMATE-ARM CONTRACT in the header).
# Wait for the harness, answer codex's startup dialog, then TYPE the prompt as
# its own verified line - the delivery every crewmate already uses.
if [ "$ARM" = crewmate ]; then
  # A generous backstop for a pane that never starts anything at all. It is not
  # a claim about any harness's startup time: the failure that actually happens -
  # the harness starting and then EXITING - is caught by $EXITMARK in the first
  # seconds, whatever this number is.
  crew_up_budget=60
  crew_up=0; crew_waited=0
  while :; do
    if [ -f "$EXITMARK" ]; then
      fail "harness '$HARNESS' exited (status $(cat "$CRCF" 2>/dev/null || printf 'unrecorded')) before its pane could take a prompt - nothing was delivered and no turn ran"
    fi
    crew_up=0
    backend_harness_up_pane "$P" || crew_up=$?
    [ "$crew_up" = 0 ] && break
    [ "$crew_waited" -ge "$crew_up_budget" ] && break
    sleep 2; crew_waited=$((crew_waited + 2))
  done
  # The probe's three states keep their meanings - 2 is never collapsed into 1
  # (ac-backend.sh, HARNESS CAME-UP PROBE): a pane that could not be READ is no
  # evidence the harness died, so the prompt still goes.
  case "$crew_up" in
    0) ;;
    1) fail "harness '$HARNESS' did not come up in its pane within ${crew_up_budget}s - every foreground process is a shell, so no prompt is delivered and the turn is REFUSED" ;;
    *) emit "{\"event\":\"note\",\"path\":\"could not read the pane to verify $HARNESS came up - delivering the prompt anyway\"}" ;;
  esac
  # COMPOSER-READY OBSERVATION, shared by both crewmate harnesses (the twin
  # copies this replaces had drifted into byte-identical 35-line loops,
  # audit-f5). A crewmate process takes the foreground before its TUI
  # composer exists, and `backend_send_line_pane` can only prove the render
  # REACTED after Enter - while the TUI is booting, an unrelated redraw
  # satisfies that observable and fakes acceptance even though send-text was
  # dropped. `agent_status=idle` also arrives too early (live OpenCode 1.18.4
  # path), so require BOTH it and a non-empty render that stays
  # byte-identical across three one-second observations. For codex this
  # replaces the fixed `${AC_SEND_SETTLE:-0.4}` sleep that once stood here: a
  # single-variable A/B proved the sleep itself was the strand - 0.4s
  # stranded the codex arm twice, 10s ran three clean rounds with nothing
  # else changed (data/atomic-e2-meta-claim/room.md) - the tell that a
  # constant, not an observation, was standing in for readiness.
  crewmate_wait_input_ready() {
    local ready_waited=0 ready_budget=60 ready_same=0 ready_render="" next_render now
    while :; do
      if [ -f "$EXITMARK" ]; then
        fail "harness '$HARNESS' exited (status $(cat "$CRCF" 2>/dev/null || printf 'unrecorded')) before its input surface became ready - no prompt was delivered"
      fi
      if backend_agent_idle_pane "$P"; then
        next_render="$(backend_capture_pane "$P" 40 2>/dev/null || true)"
        if [ -n "$(printf '%s' "$next_render" | tr -d '[:space:]')" ]; then
          if [ "$next_render" = "$ready_render" ]; then
            ready_same=$((ready_same + 1))
          else
            ready_render="$next_render"
            ready_same=1
          fi
          [ "$ready_same" -ge 3 ] && break
        else
          ready_render=""
          ready_same=0
        fi
      else
        ready_render=""
        ready_same=0
      fi
      now="$(date +%s)"
      if [ "$ready_waited" -ge "$ready_budget" ] || [ "$now" -ge "$deadline" ]; then
        fail "harness '$HARNESS' came up but its input surface did not become ready within ${ready_waited}s - no prompt was delivered"
      fi
      sleep 1
      ready_waited=$((ready_waited + 1))
    done
  }
  # THE STARTUP-DIALOG ANSWER first, when the registry names a key
  # (ac_harness_startup_key: codex's bare Enter, NEVER the prompt - an `n` or
  # a `2` anywhere in typed text picks "2. No, quit"; harness-facts.md, codex
  # STARTUP TRUST DIALOG). Best-effort: a failed press leaves the dialog up,
  # which then shows as a turn that never announces. Residual, stated not
  # hidden: HARNESS ARMS item 2 owns it and names the captain's acceptance.
  # Then the composer-ready wait, for EVERY crewmate harness: opencode boots
  # its TUI late, and codex's composer only exists once the dialog Enter is
  # answered - the same observation gates both.
  startup_key="$(ac_harness_startup_key "$HARNESS")"
  if [ -n "$startup_key" ]; then
    backend_send_key_pane "$P" "$startup_key" || true
  fi
  crewmate_wait_input_ready
  # ONE line, so it cannot half-submit into a composer: the BRIEF stays on disk
  # and the line points at it, exactly as a crewmate kickoff does.
  # The announcement path is SINGLE-QUOTED in the line the agent is told to run,
  # so a state dir containing a space still yields a runnable command.
  KICKLINE="Read and follow the instructions in $PF. Do NOT print your final message to the terminal: WRITE it to the file $VERDICT - that file's entire contents are your final message, and nothing else goes in it. Once it is written, announce your own completion by running this exact command: touch '$MARKER'"
  crew_drc=0
  backend_send_line_pane "$P" "$KICKLINE" || crew_drc=$?
  case "$crew_drc" in
    0) ;;
    2) emit "{\"event\":\"note\",\"path\":\"prompt delivery UNVERIFIED - the pane could not be read, so the submit is neither confirmed nor refuted\"}" ;;
    *) fail "the verification prompt was NOT accepted by the pane: it sits unsubmitted in the composer of '$HARNESS', so no turn will ever start - REFUSED rather than waited out" ;;
  esac
fi

# 7. wait: marker (primary) | idle fallback | pane death | timeout ($deadline
# was stamped at the launch above, so every arm's startup counts against it)
TRANSCRIPT=""; SOURCE=transcript; NEWSID="$SID"
announce_transcript() {
  [ -n "$TRANSCRIPT" ] && return 0
  local f
  if [ -n "$SID" ]; then
    f="$PROJ/$SID.jsonl"; [ -f "$f" ] || return 1
  else
    # shellcheck disable=SC2012  # newest-first ordering; names are uuid-safe
    f=$(ls -t "$PROJ"/*.jsonl 2>/dev/null | while read -r c; do
          b=$(basename "$c")
          printf '%s\n' "$BEFORE" | grep -qxF "$b" || { echo "$c"; break; }
        done | head -1)
    [ -n "$f" ] || return 1
  fi
  TRANSCRIPT="$f"; NEWSID=$(basename "$f" .jsonl)
  emit "{\"event\":\"transcript\",\"path\":\"$f\",\"session_id\":\"$NEWSID\"}"
}
wrap_transcript() {
  # wrap_transcript <dest> - stdin (plain text) written as a ONE-MESSAGE
  # transcript in the exact jsonl shape ac_transcript_final (ac-pipeline-lib.sh)
  # already parses, so every caller reads its payload from the `transcript`
  # path whichever harvest produced it. Shared by the two text harvests below.
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant",
                  "message": {"role": "assistant",
                              "content": [{"type": "text", "text": sys.stdin.read()}]}}))
' >"$1" 2>/dev/null || return 1
  [ -s "$1" ] || return 1
}
scrollback_transcript() {
  # FALLBACK HARVEST (header: the fail-closed harvest). With no jsonl to
  # resolve - a session dir holding only subagents/+tool-results/ has none -
  # the pane's own scrollback is the only source left; the done event says
  # source=scrollback. SESSION arm only: on the other two an empty or failed
  # payload is a failed turn, and scrollback there would hand a JSON-object
  # contract a width-elided TUI render.
  local cap f
  cap="$(backend_capture_pane "$P" "${AC_PANE_SCROLLBACK_LINES:-400}" 2>/dev/null)" || return 1
  [ -n "$cap" ] || return 1
  f="$MARKDIR/ac-pane-scrollback.$(basename "$CWD").$$.jsonl"
  printf '%s' "$cap" | wrap_transcript "$f" || return 1
  TRANSCRIPT="$f"; SOURCE=scrollback
  emit "{\"event\":\"transcript\",\"path\":\"$f\",\"session_id\":\"$NEWSID\",\"source\":\"scrollback\"}"
}
exec_harvest() {
  # ONE-SHOT HARVEST (contract: FAIL-CLOSED HARVEST in the header). The rung's
  # own exit status decides first, and only a zero status with non-empty stdout
  # is a turn: a rung that died, or judged nothing, FAILED - it is never
  # reported ok, and never falls through to the scrollback floor.
  local rc f
  rc="$(cat "$RCF" 2>/dev/null || true)"
  [ "$rc" = 0 ] || { EXEC_ERR="the one-shot rung exited ${rc:-with no recorded status} (stderr: $ERRF)"; return 1; }
  [ -s "$OUTF" ] || { EXEC_ERR="the one-shot rung exited 0 but printed nothing (stderr: $ERRF)"; return 1; }
  f="$MARKDIR/ac-pane-exec.$(basename "$CWD").$$.jsonl"
  wrap_transcript "$f" <"$OUTF" || { EXEC_ERR="could not wrap the rung's stdout ($OUTF)"; return 1; }
  TRANSCRIPT="$f"; SOURCE=command
  emit "{\"event\":\"transcript\",\"path\":\"$f\",\"session_id\":\"$NEWSID\",\"source\":\"command\"}"
}
file_harvest() {
  # CREWMATE HARVEST (contract: THE CREWMATE-ARM CONTRACT in the header). The
  # agent announced its turn, so a payload is owed: the verdict file's bytes,
  # and only a NON-EMPTY file is a turn. An announced turn with nothing to read
  # is a FAILED turn - never ok with an empty payload, and never a fall-through
  # to the scrollback floor, which would hand the caller TUI chrome.
  local f
  [ -s "$VERDICT" ] || { FILE_ERR="the agent announced its turn but left no verdict at $VERDICT"; return 1; }
  f="$MARKDIR/ac-pane-verdict.$(basename "$CWD").$$.jsonl"
  wrap_transcript "$f" <"$VERDICT" || { FILE_ERR="could not wrap the verdict file ($VERDICT)"; return 1; }
  TRANSCRIPT="$f"; SOURCE=file
  emit "{\"event\":\"transcript\",\"path\":\"$f\",\"session_id\":\"$NEWSID\",\"source\":\"file\"}"
}
has_final_text() {
  [ -n "$TRANSCRIPT" ] || return 1
  python3 - "$TRANSCRIPT" <<'PY' 2>/dev/null
import json, sys
final = ""
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") != "assistant": continue
    msg = d.get("message") or {}
    t = "".join(c.get("text", "") for c in (msg.get("content") or []) if isinstance(c, dict) and c.get("type") == "text")
    if t.strip(): final = t
sys.exit(0 if final else 1)
PY
}
i=0
EXEC_ERR=""
FILE_ERR=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  [ "$ARM" != session ] || announce_transcript || true
  if [ -f "$MARKER" ]; then
    rm -f "$MARKER"
    # FAIL CLOSED: the turn ended, so a payload is owed. An empty TRANSCRIPT
    # here means the glob resolved nothing - report ok with it and the caller
    # overwrites its durable session pointer with "" and dies late on an empty
    # path. Harvest the scrollback instead, and refuse the turn when even that
    # is empty (the idle fallback below has always been guarded this way).
    case "$ARM" in
      oneshot)  exec_harvest || fail "one-shot rung '$HARNESS' produced no verdict: $EXEC_ERR" ;;
      crewmate) file_harvest || fail "verification agent '$HARNESS' produced no verdict: $FILE_ERR" ;;
      *) [ -n "$TRANSCRIPT" ] || scrollback_transcript \
           || fail "turn ended but no transcript could be harvested (no $PROJ/*.jsonl and the pane scrollback was empty)" ;;
    esac
    emit "{\"event\":\"done\",\"status\":\"ok\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"source\":\"$SOURCE\",\"pane\":\"$P\"}"
    exit 0
  fi
  # CREWMATE ARM: the harness exiting without an announcement is a POSITIVE
  # failure signal - refuse in the seconds it took rather than reporting the
  # caller's full timeout, which reads like a slow reviewer. A verdict file left
  # behind is named, because it is the only trace of how far the turn got.
  if [ "$ARM" = crewmate ] && [ -f "$EXITMARK" ]; then
    fail "harness '$HARNESS' exited (status $(cat "$CRCF" 2>/dev/null || printf 'unrecorded')) without announcing a verdict - $( [ -s "$VERDICT" ] && printf 'it did leave one at %s' "$VERDICT" || printf 'and wrote none' )"
  fi
  if [ $((i % 5)) -eq 4 ] && ! herdr --session "$SES" pane get "$P" >/dev/null 2>&1; then
    emit "{\"event\":\"done\",\"status\":\"pane_closed\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"pane\":\"$P\",\"error\":\"pane closed while turn in flight\"}"
    exit 1
  fi
  # idle fallback (Stop hook failed to fire): ONLY when herdr also reports the
  # pane's agent as idle/done - long xhigh-thinking stretches write nothing to
  # the transcript for minutes, so transcript mtime alone declared turns done
  # prematurely (root cause of truncated reviews on large repos).
  if [ -n "$TRANSCRIPT" ] && [ $i -gt 45 ]; then
    mt=$(stat -f %m "$TRANSCRIPT" 2>/dev/null || echo 0)
    if [ $(( $(date +%s) - mt )) -gt 120 ]; then
      ag=$(herdr --session "$SES" pane get "$P" 2>/dev/null | sed -n 's/.*"agent_status":"\([^"]*\)".*/\1/p' | head -1)
      if { [ "$ag" = idle ] || [ "$ag" = "done" ]; } && has_final_text; then
        # DELIVERABLE GATE (contract: IDLE FALLBACK in the header). None of the
        # three questions above asks whether the agent's WORK was produced, and
        # has_final_text is satisfied by any assistant text anywhere - including
        # an aborted turn's last message. When the caller DECLARED the artifact
        # its prompt demanded, an idle pane without it is a turn that stopped
        # mid-pass, and reporting it ok is what let a run exit 0 having written
        # nothing. Refuse in the seconds it took, the way the crewmate arm
        # refuses an exited harness, rather than burning the caller's whole
        # timeout - and carry the pane, like the pane_closed exit above, so the
        # caller can still reap the agent it opened.
        if [ -n "$DELIVERABLE" ] && [ ! -s "$DELIVERABLE" ]; then
          emit "{\"event\":\"done\",\"status\":\"error\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"pane\":\"$P\",\"error\":\"the pane went idle (agent_status=$ag) without producing its deliverable $DELIVERABLE - the turn stopped mid-pass, so it is NOT reported ok\"}"
          exit 1
        fi
        emit "{\"event\":\"note\",\"path\":\"idle-fallback used (agent_status=$ag)\"}"
        emit "{\"event\":\"done\",\"status\":\"ok\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"source\":\"$SOURCE\",\"pane\":\"$P\"}"
        exit 0
      fi
    fi
  fi
  # BUSY-STALL BOUND (contract: the header block of the same name): a busy
  # signal is NOT unbounded proof of liveness. A tool call hung behind a
  # static "Working..." footer (worst observed case: a catastrophic-
  # backtracking regex ran a full day) writes nothing while the backend keeps reporting busy, so the
  # marker, the idle fallback (gated on idle/done), and pane death never fire
  # and the caller burns its WHOLE timeout on a dead turn. When the transcript
  # has not moved for AC_PANE_STALL_MAX seconds (default 2700 - an order of
  # magnitude past the longest observed xhigh no-write thinking stretch; 0
  # disables), escalate as an error CARRYING the pane, whatever agent_status
  # claims: at this age a pane is a hung call or a wedged prompt alike, and a
  # synchronous verifier caller can answer neither. agent_status rides along
  # for diagnosis only - an unreadable status must never veto the escalation.
  # The clock runs from the LATER of the last transcript write and this wait's
  # start: a resumed session's transcript legitimately carries the previous
  # turn's mtime at i=0, and that history is not THIS turn's stall.
  if [ -n "$TRANSCRIPT" ] && [ "${AC_PANE_STALL_MAX:-2700}" -gt 0 ]; then
    mt=$(stat -f %m "$TRANSCRIPT" 2>/dev/null || echo 0)
    [ "$mt" -ge "$wait_start" ] || mt=$wait_start
    if [ $(( $(date +%s) - mt )) -gt "${AC_PANE_STALL_MAX:-2700}" ]; then
      ag=$(herdr --session "$SES" pane get "$P" 2>/dev/null | sed -n 's/.*"agent_status":"\([^"]*\)".*/\1/p' | head -1)
      emit "{\"event\":\"done\",\"status\":\"error\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"pane\":\"$P\",\"error\":\"no transcript progress for over ${AC_PANE_STALL_MAX:-2700}s (agent_status=${ag:-unreadable}) - the turn is stalled inside a single call, escalating instead of burning the caller's timeout\"}"
      exit 1
    fi
  fi
  sleep 2; i=$((i + 1))
done
emit "{\"event\":\"done\",\"status\":\"timeout\",\"session_id\":\"$NEWSID\",\"transcript\":\"$TRANSCRIPT\",\"pane\":\"$P\",\"error\":\"turn did not end within ${TIMEOUT}s\"}"
exit 1
