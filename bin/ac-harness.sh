#!/usr/bin/env bash
# ac-harness.sh - the per-harness registry: the ONE place a supported
# harness's identity and scalar facets live (audit-f5). Sourced by ac-lib.sh,
# so every script that sources the lib has it; never an entrypoint.
#
# WHY: adding the 3rd harness (opencode) cost edits in 13 production files
# because eight mini-tables each carried a slice of this knowledge - and one
# of them, the instruction-file mapping, failed OPEN: an unknown harness
# silently received .claude/CLAUDE.md, a file it never reads, which is the
# exact failure the fleet hit when codex arrived. Every facet here fails
# CLOSED or answers a documented conservative default.
#
# WHAT LIVES HERE: the known-harness set (+ its ERE alternation), the TUI
# busy-regex, the seeded instruction file, the pane-agent arm map, the
# startup-dialog key, and the recorded-launch-opts policy.
# WHAT STAYS AT ITS ARM, deliberately: the two launch COMMAND tables -
# ac_build_launch (ac-backend.sh, the interactive line) and oneshot_launch
# (ac-pane-agent.sh, the --exec form) - whose own headers argue their
# locality: two different shapes for two different lifecycles, one consumer
# each, and both already fail closed on an unknown name. A 4th harness
# therefore edits THIS file plus those two arms (and its harness-facts.md
# entry), instead of thirteen files.
# A CUSTOM harness (a captain's config/launch-<h> template, emitted verbatim
# by ac-spawn.sh) is launchable without joining the registry; the facets it
# cannot answer fail closed where a wrong answer costs work (the instruction
# file requires the template to exist) and empty where absence is safe (no
# startup key, no pane arm).

# The known built-in set, and the same set as an ERE alternation for process
# matching (ac-lock.sh's holder-identity check).
# cursor's PROCESS name is cursor-agent (the bare `cursor` binary is the IDE
# launcher, a different program) - the RE matches command lines, so it
# carries the real process name while the harness ID stays `cursor`.
AC_HARNESS_RE='claude|codex|opencode|pi|cursor-agent'
ac_harness_known() {
  case "$1" in claude | codex | opencode | pi | cursor) return 0 ;; *) return 1 ;; esac
}

# TUI busy idioms: ONE alternation over every built-in harness's "working"
# render, grepped by the watcher against pane tails (busy = absorb, not wake).
# A new harness ORs its fragment in HERE. The fragments are deliberately not
# attributed per harness: the watcher only ever greps the combined regex, and
# no per-idiom attribution was ever verified - a false one would be worse
# than none.
AC_BUSY_RE="${AC_BUSY_RE:-esc (to )?interrupt|Working…|Working\.\.\.|Ctrl\+c:cancel|[Tt]hinking}"

ac_harness_instruction_file() {
  # ac_harness_instruction_file <harness> - the instruction file the SPAWNED
  # harness actually loads, relative to its worktree (verified per harness:
  # AGENTS.md for codex and opencode, .claude/CLAUDE.md for claude - the seed
  # block in AGENTS.md section 5 records the live verifications). FAIL-CLOSED
  # (audit-f5): the retired `*)` arm handed .claude/CLAUDE.md to anything
  # unknown, so a new harness silently received a file it never reads and its
  # crewmates ran without the fleet layer. A CUSTOM harness keeps
  # .claude/CLAUDE.md only when its config/launch-<h> template actually
  # exists - that path is the template owner's documented contract; a harness
  # that is neither built-in nor custom dies here, at seed time.
  local h="${1:-claude}"
  case "$h" in
    # pi joins the AGENTS.md group on its own CLI's word: pi 0.84.2 --help
    # (verified live on this host, 2026-08-14) names the discovery switch
    # "--no-context-files  Disable AGENTS.md and CLAUDE.md discovery and
    # loading" - so a bare pi launch discovers the worktree AGENTS.md itself;
    # the repo-shipped-wins rule is unchanged.
    codex | opencode | pi) printf 'AGENTS.md\n' ;;
    # cursor: LIVE-PROBED 2026-08-14 on cursor-agent 2026.05.05 (headless
    # -p --trust, all-tokens probe + swapped-marker control leg -
    # harness-facts.md cursor section owns the evidence): loads the worktree
    # AGENTS.md AND root CLAUDE.md, does NOT load .claude/CLAUDE.md, and the
    # control leg proved the loader follows the PATH, not the token.
    cursor) printf 'AGENTS.md\n' ;;
    claude) printf '.claude/CLAUDE.md\n' ;;
    *)
      if [ -f "$(ac_home)/config/launch-$h" ]; then
        printf '.claude/CLAUDE.md\n'
      else
        ac_die "unknown harness '$h': no registry entry (bin/ac-harness.sh) and no config/launch-$h template - refusing to guess which instruction file it loads"
      fi
      ;;
  esac
}

ac_harness_pane_arm() {
  # ac_harness_pane_arm <harness> - the pane-agent INTERACTIVE arm: `session`
  # (claude - resume, live steering and the transcript harvest are all
  # claude-specific) or `crewmate` (codex/opencode - the two harnesses
  # VERIFIED to write their final message where the brief says and announce
  # their own completion; harness-facts.md, codex/opencode Completion).
  # Non-zero for anything else: a third harness is refused until somebody
  # verifies the same contract about it, because arming an unproven one costs
  # the caller its whole timeout and then reads like a slow reviewer
  # (HARNESS ARMS, bin/ac-pane-agent.sh header - the arm SEQUENCING and both
  # launch-command tables stay with that file).
  # pi and cursor ride the crewmate arm on the captain's own order
  # (captain 2026-08-14: "fix de codereview-agent / qa-agent / gate-agent
  # apply pi vs cursor") - their completion contract has NO live run yet, so
  # the FIRST real round is the verification: a pane that never writes its
  # verdict file surfaces as the caller's harvest timeout, visibly, and
  # harness-facts.md owns the UNPROVEN boundary until that round lands.
  case "$1" in
    claude) printf 'session\n' ;;
    codex | opencode | pi | cursor) printf 'crewmate\n' ;;
    *) return 1 ;;
  esac
}

ac_harness_startup_key() {
  # ac_harness_startup_key <harness> - the ONE bare key that answers the
  # harness's startup dialog before any text is typed, empty when there is no
  # dialog. codex: a bare Enter takes "1. Yes, continue"; an `n` or a `2`
  # anywhere in typed text would pick "2. No, quit" (harness-facts.md, codex
  # STARTUP TRUST DIALOG). Both senders - ac-spawn.sh's deliver_kickoff and
  # ac-pane-agent.sh's crewmate arm - read this instead of each keeping its
  # own codex conditional; the SPAWN side additionally suppresses the key for
  # a custom launch-codex template, whose TUI is unknown (that guard is the
  # caller's, not the registry's).
  case "$1" in
    codex) printf 'Enter\n' ;;
    *) printf '' ;;
  esac
}

ac_record_launch_opts() {
  # ac_record_launch_opts <meta> <harness> <model> <effort> [applied-effort] -
  # record ONLY the model/effort a harness's BUILT-IN launch template actually
  # applies, so the meta never claims a setting the launched process never
  # received:
  #   claude -> model + effort   codex -> model + APPLIED effort
  #   opencode -> model only (its TUI has no --variant)   others -> neither.
  # The two efforts differ for the ultracode preset alone. claude records the
  # RAW value: its launch line carries --effort xhigh AND deliver_kickoff types
  # '/effort ultracode' into the TUI, so the session really is in that mode.
  # That TUI half is claude-only, so a codex spawn at ultracode genuinely runs
  # at the tier ac_build_launch passed it as -c model_reasoning_effort=<e> -
  # the APPLIED effort, which callers hand in as the 5th argument (defaulting
  # to the 4th, so a caller with nothing to distinguish stays correct).
  # (A custom config/launch-<h> template is emitted verbatim and consumes no
  # model/effort; the meta may over-report for those, which is acceptable.)
  local meta="$1" harness="$2" model="$3" effort="$4" applied="${5:-$4}"
  case "$harness" in
    claude)
      [ -n "$model" ] && ac_meta_set "$meta" model "$model"
      [ -n "$effort" ] && ac_meta_set "$meta" effort "$effort" ;;
    codex)
      [ -n "$model" ] && ac_meta_set "$meta" model "$model"
      [ -n "$applied" ] && ac_meta_set "$meta" effort "$applied" ;;
    opencode)
      [ -n "$model" ] && ac_meta_set "$meta" model "$model" ;;
    pi)
      # pi's built-in line genuinely applies both flags (--model / --thinking),
      # and like codex it has no TUI '/effort' half - so ultracode records the
      # APPLIED tier, never the preset name.
      [ -n "$model" ] && ac_meta_set "$meta" model "$model"
      [ -n "$applied" ] && ac_meta_set "$meta" effort "$applied" ;;
    cursor)
      # cursor-agent has no effort flag at all (thinking rides model NAMES,
      # e.g. a -thinking suffix) - model only, the opencode shape.
      [ -n "$model" ] && ac_meta_set "$meta" model "$model" ;;
  esac
  return 0
}
