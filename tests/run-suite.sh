#!/usr/bin/env bash
# run-suite.sh - the ONE tested entry point for "is the bash test suite
# green". Selects <dir>/*.test.sh (default <repo>/tests/sh - the glob already
# excludes helpers.sh/stress.sh, which do not match *.test.sh, while still
# picking up helpers.test.sh/stress.test.sh, which are real tests), runs each
# with `bash <file>` - never a direct exec, so a lost exec bit can never read
# as a test failure - and reports a full PASS/FAIL count plus every failing
# name, never a truncating tail. Designed against the fake-failure shapes
# recorded in repo-knowledge/agent-crew.md and this family's room.md: EXEC
# BIT, a missing `timeout`/`gtimeout` misread as a failure, and a truncating
# tail hiding a real red.
#
# Before each test file runs, a `RUNNING <name>` line is printed - pure
# observability, no timeout/watchdog behind it - so a hang leaves the
# culprit's name as the last line printed instead of an unnamed silence
# (the 1h23m undiagnosable-hang gap). In parallel mode (--jobs N > 1) up to N
# RUNNING lines print together before that batch runs; that is correct, not a
# bug - all N are genuinely running concurrently.
#
# Usage: run-suite.sh [--jobs N] [--changed] [<tests-dir>]
#
# Exit: 0 all green; 1 one or more tests failed; 2 bad args / empty selection;
# 3 REFUSED - SIGINT is ignored in this context (an async invocation) and could
# not be repaired, so two tests would false-red. See the signal-delivery probe.
#   --jobs N     run up to N test files concurrently (default 1, sequential).
#                See the parallel-mode note below before raising it.
#   --changed    narrow the run to tests mapped from the changed set (staged +
#                unstaged + untracked vs HEAD, git diff --diff-filter=d HEAD
#                plus git ls-files --others --exclude-standard - the same
#                mechanism bin/ac-lint.sh uses). OPT-IN, unlike ac-lint's
#                --all: bare run-suite.sh keeps running the FULL suite
#                unchanged, because AGENTS.md section 13 names the periodic
#                task before each Learning DISTILL run as the one caller for
#                which a bare full run is correct, and a flipped default would
#                make every existing bare caller silently partial - a false
#                green.
#                Mapping: bin/<name>.sh <-> tests/sh/<name>.test.sh (a changed
#                tests/sh/<name>.test.sh selects itself). A ported script's
#                TypeScript maps the same way: src/<name>.ts selects
#                tests/sh/src.test.sh (the one wrapper running every Bun unit
#                test, tests/ts/*.test.ts - so a changed *.test.ts selects it
#                too) plus the mapped tests of every bin/*.sh STARTING it -
#                one with a non-comment line naming src/<name>.ts: its
#                bin/ac-<name>.sh entry, and any script running a mode of it
#                (bin/ac-qa.sh runs src/paths.ts) - each resolved by the same
#                mapping, one hop (bin/ac-lib.sh, a shared library starting
#                src/pane-agent.ts, adds its own test, not its sourcers'). A
#                src module other src files import is a shared library exactly
#                like a sourced one (clause 1 below). AGENTS.md section 13's
#                colocated-test-per-behavior rule makes this mechanical for
#                the ordinary case. A small DOCUMENTED exception (split_map)
#                covers the two highest-churn scripts the repo's own
#                convention splits across several concern-named files instead
#                of one exact-name file - bin/ac-spawn.sh maps LIVE to every
#                ac-spawn-*.test.sh file on disk (a glob, not a hand list, so
#                a new one joins on its own) plus the two roomchief suites
#                that execute it, bin/ac-teardown.sh maps to its
#                own ac-teardown.test.sh AND ac-spawn-teardown.test.sh (see
#                split_map's own comment for why that one arm stays manual) -
#                so a change to either narrows to its real tests instead of
#                widening (repo-deep-review F29).
#                WIDEN RULE - a change the mapping cannot confidently narrow
#                WIDENS to the full set and prints why, never silently
#                narrowing to nothing:
#                  1. a changed file that is ITSELF dot-sourced by any OTHER
#                     owned file (bin/*.sh or tests/sh/*.sh), or - a src/*.ts -
#                     imported by another src/*.ts (from "./<basename>") - a
#                     LIVE check (grep for a line of the shape
#                     "^\s*\.\s+.*<basename>\"", or that import, in every other
#                     owned file), not a hand-maintained list:
#                     a list silently rots the day a new shared file joins and
#                     nobody remembers to add it (gate-finding
#                     run-suite-changed-file-selection, 2026-07-25 - an
#                     earlier hand list of three files missed bin/ac-backend.sh,
#                     sourced by 14 scripts, which mapped cleanly onto its own
#                     colocated test and silently narrowed instead of
#                     widening). This does NOT blindly widen to the full set
#                     any more: it selects the UNION of its sourcers' own
#                     mapped tests (each sourcer resolved by the SAME
#                     colocated-test/split_map rule as any other changed
#                     file - one hop, not chased into a sourcer's own
#                     sourcers) plus the lib's own colocated test when it has
#                     one. Verified against the real dependency graph
#                     (family
#                     run-suite-changed-widens-on-any-shared-lib-so-the-ac-lib-split-buys-nothing-yet):
#                     no sourcer of any shared lib in this repo is itself a
#                     shared lib, so one hop already closes the graph here -
#                     a future lib-sourcing-a-lib would need the closure
#                     re-checked, not assumed. A sourcer with NO mapped test
#                     is still unknown blast radius (clause 2's own logic,
#                     reapplied per sourcer): ONE unmapped sourcer widens the
#                     WHOLE run, exactly like an unmapped changed file always
#                     has - narrowing never turns an unknown blast radius
#                     into silence. Measured today via this same live check,
#                     purely descriptive (the code derives, never lists):
#                     bin/ac-lib.sh (69 sourcers, incl. bin/ac-deputy.sh and
#                     6 others with no colocated test - so a core-lib change
#                     still widens today, a pre-existing test-coverage gap
#                     this task does not close), bin/ac-wake-lib.sh (14
#                     sourcers, incl. bin/ac-deputy.sh/bin/ac-turnend-guard.sh
#                     unmapped - also still widens), bin/ac-backend.sh (21,
#                     3 unmapped - still widens), bin/ac-maintenance-lib.sh
#                     (9, 2 unmapped - still widens), tests/sh/helpers.sh (88
#                     sourcers, 1 unmapped - tests/sh/stress.sh is neither a
#                     bin/*.sh nor a tests/sh/*.test.sh, so the mapping this
#                     rule reuses has no arm for it at all - still widens,
#                     legitimately near-full either way; do not special-case
#                     it). Two DO narrow cleanly, proving the
#                     mechanism: bin/ac-pipeline-lib.sh (7 sourcers, all
#                     mapped -> selects exactly 8 tests, not 88) and
#                     bin/ac-qa-lib.sh (5 sourcers, all mapped -> selects
#                     exactly 4 tests, not 88);
#                  2. a changed owned file (bin/*.sh or tests/sh/*.test.sh) with
#                     no exact colocated test, or a src/*.ts with a starter
#                     that has none - unmapped code is unknown blast radius,
#                     never read as "nothing to run".
#                Outside a git repo, or with no HEAD yet, --changed falls back
#                to the full set. A file outside this runner's owned set
#                (bin/*.sh, src/*.ts, tests/sh/*.sh, tests/ts/*.test.ts) is
#                ignored, like ac-lint ignoring a changed README.
#                EMPTY-SELECTION EXIT - NOT a widen: when the mapped selection
#                comes out EMPTY (e.g. a clean, fully-committed tree - nothing
#                uncommitted to read a changed set from), the runner exits 2
#                and runs NOTHING, rather than either of the two false
#                outcomes tried before it: exiting 0 having run zero tests (a
#                caller checking the exit code reads that as a pass), or
#                widening to the full set (the post-commit tree this fires on
#                is exactly the state a chief verifies in, which kept
#                re-running the full suite captain.md's NO BARE FULL-SUITE RUN
#                standing order forbids - see
#                run-suite-empty-selection-must-not-run-the-full-suite/room.md).
#                An empty selection means --changed found nothing it could
#                safely narrow on, so the runner itself cannot proceed - same
#                family as "no *.test.sh files found" below.
#   <tests-dir>  directory to scan for *.test.sh (default: this script's own
#                <repo>/tests/sh, resolved via BASH_SOURCE so it is independent
#                of the caller's cwd). The colocated run-suite.test.sh uses
#                this to point at disposable fixtures instead of tests/sh/.
#                --changed resolves the changed set from the git repo that
#                CONTAINS <tests-dir> (git -C <tests-dir> rev-parse
#                --show-toplevel), not from this script's own ROOT - so a
#                throwaway fixture repo under a test's <tests-dir> is fully
#                isolated from the real repo's git state.
#
# Exit: 0 all tests passed, 1 at least one test failed, 2 the runner itself
# could not proceed (bad arguments, no test files found, or --changed's
# mapped selection comes out empty).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
default_dir="$ROOT/tests/sh"

# SIGNAL-DELIVERY probe, and a self-repair when it fails - the same "capability
# probe, never a guess" discipline as the timeout check below, applied to the
# one environment property this suite's own assertions depend on.
#
# THE DEFECT IT CLOSES, measured 2026-08-10 with everything else held constant:
# run this runner as an ASYNC COMMAND (`run-suite.sh &`, a `nohup ... &`, a
# cron or standing-job invocation) and it reports two FALSE FAILURES -
# ac-watch.test.sh ("'signal:INT' not found in: heartbeat") and
# run-suite.test.sh ("the runner must deliver SIGINT normally") - while both
# pass standalone and the same tree is 107/107 green run in the foreground.
#
# WHY, and note this is NOT the TTY (a foreground run with no controlling
# terminal delivers INT fine - measured): bash forces SIGINT/SIGQUIT to SIG_IGN
# in an async command when job control is off, and that disposition SURVIVES
# fork and exec into every descendant. The `set -m` around each spawn below
# fixes the case where THIS runner is the one backgrounding - it cannot undo a
# disposition this process INHERITED. Neither can anything else in bash:
# measured, `set -m` alone, `trap - INT`, and `trap "" INT; trap - INT` all
# leave the child unable to see INT (child_exit 0 where 42 is expected), which
# is POSIX - a shell entered with a signal ignored may not re-arm it.
#
# So the probe RUNS the property rather than inferring it, and on failure the
# only thing that does work is used: re-exec through a helper that resets the
# disposition at the syscall layer. python3 is used ONLY on that already-broken
# path, never on the healthy one, so it is not a new dependency for an ordinary
# run - and if it is absent the runner REFUSES rather than reporting a red it
# caused itself. A verdict that gates Learning must never be a false red.
if [ "${AC_SUITE_INT_REPAIRED:-0}" != 1 ]; then
  int_probe() {
    set -m
    ( trap 'exit 42' INT; sleep 5 ) & local c=$!
    set +m
    sleep 0.3
    kill -INT "$c" 2>/dev/null || true
    wait "$c" 2>/dev/null
    [ "$?" = 42 ]
  }
  if ! int_probe; then
    if command -v python3 >/dev/null 2>&1; then
      printf 'run-suite: SIGINT is ignored in this context (an async/backgrounded invocation) - re-execing with the disposition reset, or two tests would false-red\n' >&2
      export AC_SUITE_INT_REPAIRED=1
      # QUIT is the other signal the async command was forced to ignore, and
      # python3 itself starts with PIPE and XFSZ ignored; execv carries every
      # ignore into each suite, where a writer to a closed pipe then fails on
      # EPIPE instead of dying 141.
      exec python3 -c 'import signal, os, sys; [signal.signal(s, signal.SIG_DFL) for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGPIPE, signal.SIGXFSZ)]; os.execv("/bin/bash", ["bash"] + sys.argv[1:])' \
        "${BASH_SOURCE[0]}" "$@"
    fi
    printf 'run-suite: REFUSING to run - SIGINT is ignored in this context, so ac-watch.test.sh and\n' >&2
    printf '  run-suite.test.sh would FALSE-RED (they assert a process dies from INT). bash cannot\n' >&2
    printf '  re-arm a signal it inherited as ignored, and python3 (the one repair) is absent here.\n' >&2
    printf '  Run it in the FOREGROUND: tests/run-suite.sh\n' >&2
    printf '  A false red on this suite gates every Learning DISTILL, so refusing beats reporting it.\n' >&2
    exit 3
  fi
fi

jobs=1
changed=0
dir="$default_dir"
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs)
      [ $# -ge 2 ] || { printf 'run-suite: --jobs needs a value\n' >&2; exit 2; }
      jobs="$2"; shift 2 ;;
    --jobs=*) jobs="${1#--jobs=}"; shift ;;
    --changed) changed=1; shift ;;
    -h|--help) printf 'usage: %s [--jobs N] [--changed] [<tests-dir>]\n' "${0##*/}"; exit 0 ;;
    -*) printf 'run-suite: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) dir="$1"; shift ;;
  esac
done
case "$jobs" in *[!0-9]*|'') printf 'run-suite: --jobs must be a positive integer, got %s\n' "$jobs" >&2; exit 2 ;; esac
[ "$jobs" -ge 1 ] || { printf 'run-suite: --jobs must be >= 1\n' >&2; exit 2; }

# Capability probe, never a guess: this host has neither `timeout` nor
# `gtimeout` (re-verify with `command -v timeout gtimeout`; prints nothing as
# of 2026-07-22 - macOS ships neither without coreutils). Do without rather
# than fake it: a missing tool must never read as a test failure.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  printf 'run-suite: no timeout/gtimeout on this host - running with NO per-test timeout\n'
fi

tests=()
for f in "$dir"/*.test.sh; do
  [ -e "$f" ] || continue
  tests+=("$f")
done
[ "${#tests[@]}" -gt 0 ] || { printf 'run-suite: no *.test.sh files found under %s\n' "$dir" >&2; exit 2; }

# --changed: narrow `tests` in place to the mapped selection, or leave it (the
# full set) untouched when the mapping widens or falls back. See the header
# for the mapping + widen rule.

sourcers_of() {
  # sourcers_of <changed_root> <rel-path> - echoes, one per line, the
  # relpath of every OTHER bin/*.sh or tests/sh/*.sh under changed_root that
  # dot-sources this file - or, for a src/*.ts, every other src/*.ts that
  # imports it (tests/sh/*.sh, not just tests/sh/*.test.sh, so this also
  # catches tests/sh/helpers.sh and tests/sh/stress.sh, neither of which matches
  # the tests/sh/*.test.sh mapping case below). Empty output means the file is
  # not a shared library. LIVE, not a hand list: a list rots the day a new
  # shared file joins and nobody remembers to add it (gate-finding
  # run-suite-changed-file-selection, 2026-07-25 - a three-file hand list
  # missed bin/ac-backend.sh, sourced by 14 scripts). This used to answer
  # only true/false and throw the sourcer set away; the caller now needs the
  # set itself to select those sourcers' own tests instead of blindly
  # widening (family
  # run-suite-changed-widens-on-any-shared-lib-so-the-ac-lib-split-buys-nothing-yet).
  local root="$1" relpath="$2" base base_re f
  base="${relpath##*/}"
  case "$relpath" in
    src/*.ts)
      for f in "$root"/src/*.ts; do
        [ -e "$f" ] || continue
        case "$f" in */"$relpath") continue ;; esac
        grep -qF "from \"./$base\"" "$f" && printf '%s\n' "${f#"$root"/}"
      done
      return 0
      ;;
  esac
  base_re="$(printf '%s' "$base" | sed 's/[.[\*^$]/\\&/g')"
  for f in "$root"/bin/*.sh "$root"/tests/sh/*.sh; do
    [ -e "$f" ] || continue
    case "$f" in */"$relpath") continue ;; esac # skip the file itself
    grep -qE "^[[:space:]]*\.[[:space:]].*${base_re}\"" "$f" && printf '%s\n' "${f#"$root"/}"
  done
  # Explicit, not left to the loop's last exit status: called as
  # `x="$(sourcers_of ...)"` under set -e, and a "no match on the last file"
  # grep leaves the function - and so the command substitution - exiting
  # non-zero, which errexit reads as a failed assignment and aborts the
  # whole script (verified live building this fix).
  return 0
}

split_map() {
  # split_map <changed_root> <base> - echoes the mapped tests/sh/*.test.sh
  # basenames (space-separated) for a KNOWN split script, or nothing. The
  # repo's own convention splits a test by CONCERN rather than by
  # colocated-file-name for these two highest-churn scripts (AGENTS.md
  # section 13; repo-deep-review F29), so the exact-name mapping alone
  # widened every change to either to the full suite. Widening stays the
  # fallback for every other unmapped file - this is not a general
  # substitute for it.
  #
  # ac-spawn narrows LIVE, the same "not a hand list" spirit sourcers_of
  # states above this function: a glob over the shared
  # ac-spawn- prefix under changed_root/tests/sh, so a NEW
  # ac-spawn-<concern>.test.sh file joins the selection the moment it lands
  # on disk - nobody has to remember to add it here. ac-roomchief.test.sh and
  # ac-room-parallel-cap.test.sh execute the entry too (the promote and its
  # cap) outside that prefix, so they ride the arm by name.
  #
  # ac-teardown stays a documented hand list, not a live derivation, and
  # this is why a live glob cannot cover both arms: beside its own
  # ac-teardown.test.sh (the differential leg of src/teardown.ts), its
  # black-box test ac-spawn-teardown.test.sh carries the ac-spawn- prefix
  # instead of an ac-teardown- one (the repo groups spawn+teardown lifecycle
  # tests under one concern-named file), so nothing on disk distinguishes
  # "the teardown test" from the other three ac-spawn- files without also
  # pulling those three in (see tests/sh/run-suite.test.sh's ac-teardown.sh
  # scenario). The arm is consulted BEFORE the colocated name
  # (map_owned_file), or that name alone would drop the black-box test.
  # Maintenance duty this manual line carries: the live glob above fires
  # only for a bin/ac-spawn.sh change, so it never covers a NEW ac-teardown.sh
  # split test, whatever that file is named - an ac-spawn-<concern>.test.sh
  # name buys it coverage the day someone touches bin/ac-spawn.sh, never the
  # day someone touches bin/ac-teardown.sh, the script it actually tests.
  # There is effectively ONE option here: a new ac-teardown.sh split test
  # must be added to this arm by hand.
  local root="$1" base="$2" f
  case "$base" in
    ac-spawn)
      for f in "$root"/tests/sh/ac-spawn-*.test.sh; do
        [ -e "$f" ] || continue
        printf '%s ' "${f##*/}"
      done
      printf '%s' "ac-roomchief.test.sh ac-room-parallel-cap.test.sh"
      ;;
    ac-teardown) printf '%s' "ac-teardown.test.sh ac-spawn-teardown.test.sh" ;;
    # ac-brief's escalation gate is pinned in ac-contract.test.sh, beside the
    # delivery-contract grammar it reads.
    ac-brief) printf '%s' "ac-brief.test.sh ac-contract.test.sh" ;;
    # flag-values.test.sh executes ac-know's value-flag refusal; its static
    # grep stopped seeing the flag arms once they moved to src/know.ts.
    ac-know) printf '%s' "ac-know.test.sh flag-values.test.sh" ;;
    # ac-learn-loop.test.sh runs the real gate through `ac-learn.sh run` and
    # pins its refusal of the learning stage.
    ac-gate) printf '%s' "ac-gate.test.sh ac-learn-loop.test.sh" ;;
    # ac-gate.test.sh runs the board (`--once`) beside the gate runs it
    # counts, and ac-watch-dash.test.sh greps src/gate-watch.ts.
    ac-gate-watch) printf '%s' "ac-gate-watch.test.sh ac-gate.test.sh ac-watch-dash.test.sh" ;;
    # The two boards share one body (src/watch-dash.ts) whose leg is
    # ac-watch-dash.test.sh, and their openers' suites run them `--once`.
    ac-ship-watch) printf '%s' "ac-ship-watch.test.sh ac-watch-dash.test.sh ac-ship.test.sh" ;;
    ac-qa-watch) printf '%s' "ac-qa-watch.test.sh ac-watch-dash.test.sh ac-qa.test.sh" ;;
    # Three suites execute ac-curate besides its own (a keep-0 backlog pass,
    # Learning's cadence-due run, the loop's incidental runs), and
    # ac-config-surface.test.sh greps src/curate.ts for its double-keyed hook.
    ac-curate) printf '%s' "ac-curate.test.sh ac-backlog-sections.test.sh ac-learning-automation-e2e.test.sh ac-learn-loop.test.sh ac-config-surface.test.sh" ;;
    # No suite carries the entry's own name: the daemon suite holds its leg,
    # and the two review suites start and stop real dashboards through it.
    ac-dashboard) printf '%s' "ac-dashboard-daemon.test.sh ac-review.test.sh ac-review-reply.test.sh" ;;
    # Eight suites run its report, queued or watch-set besides its own leg,
    # directly or through the turn-end guard, session start and autoarm.
    ac-ready) printf '%s' "ac-ready.test.sh ac-backlog.test.sh ac-backlog-sections.test.sh ac-contract.test.sh ac-task.test.sh ac-watch.test.sh ac-watch-autoarm.test.sh ac-turnend-guard.test.sh ac-session-start.test.sh" ;;
    # Five suites execute ac-learn besides its own (the loop's runs and lands,
    # the room's autoroom and suite, the quote lands, the end-to-end runs, the
    # maintenance verbs), and ac-config-surface.test.sh greps src/learn.ts.
    ac-learn) printf '%s' "ac-learn.test.sh ac-learn-loop.test.sh ac-learn-autoroom.test.sh ac-learn-quote.test.sh ac-learning-automation-e2e.test.sh ac-maintenance-core.test.sh ac-config-surface.test.sh" ;;
    # Four suites execute the pane agent besides its own: the teardown legs'
    # reap-pane rows (src/teardown.ts and the frozen teardown), ac-lib's
    # ac_transcript_final_epoch (its iso-epoch verb), and ac-brain's one-shot
    # parity rows, which import its ONESHOT table.
    ac-pane-agent) printf '%s' "ac-pane-agent.test.sh ac-teardown.test.sh ac-spawn-teardown.test.sh ac-brain.test.sh ac-lib.test.sh" ;;
    # ac-qa-store.test.sh executes the store verbs, and ac-config-surface.test.sh
    # greps src/qa.ts for its double-keyed hook.
    ac-qa) printf '%s' "ac-qa.test.sh ac-qa-store.test.sh ac-config-surface.test.sh" ;;
    # Six suites execute ac-watch besides its own: the jev note, the brain
    # freshen slot, the owner gate, the remote slot's gate, a roomchief's
    # scoped arm and a self task's unpolled pane.
    ac-watch) printf '%s' "ac-watch.test.sh ac-watch-jev.test.sh ac-brain-freshen.test.sh ac-lock.test.sh ac-remote-wire.test.sh ac-roomchief.test.sh ac-self-task.test.sh" ;;
    # The watch policy hook's contract rows and its leg live in
    # ac-guard.test.sh, and ac-harness-hooks.test.sh runs it through the
    # cursor adapter.
    ac-watch-policy-hook) printf '%s' "ac-guard.test.sh ac-harness-hooks.test.sh" ;;
    # A sourced lib whose pins live in its one real consumer's test; without
    # this arm every src/ module it starts widened --changed to the full set.
    ac-qa-lib) printf '%s' "ac-qa.test.sh" ;;
    ac-maintenance-lib) printf '%s' "ac-maintenance-core.test.sh" ;;
  esac
}

map_owned_file() {
  # map_owned_file <changed_root> <relpath> - echoes the mapped
  # tests/sh/*.test.sh basename(s) (space-separated) for an owned file
  # (tests/sh/*.test.sh selects itself; bin/*.sh maps via split_map, else its
  # colocated test), or nothing when unmapped. ONE rule, shared by the direct
  # per-file case below and the shared-lib sourcer closure - a sourcer's own
  # test is found the SAME way a directly-changed file's is, never a second
  # mapping invented for the sourcer case.
  local root="$1" f="$2" base mapped s m
  case "$f" in
    tests/sh/*.test.sh) printf '%s' "${f#tests/sh/}" ;;
    tests/ts/*.test.ts) printf '%s' "src.test.sh" ;;
    src/*.ts)
      # A starter is any bin script with a NON-comment line naming this
      # module: a script that merely names it in a comment (bin/ac-lib.sh,
      # twin of src/lib.ts) starts nothing. awk, not grep -v | grep -q: under
      # pipefail an early grep -q exit can SIGPIPE the writer on a long
      # script and read as no match. An untested starter maps the whole
      # module to nothing, so the caller widens.
      mapped="src.test.sh"
      for s in "$root"/bin/*.sh; do
        [ -e "$s" ] || continue
        awk -v p="$f" '!/^[[:space:]]*#/ && index($0, p) { hit = 1; exit } END { exit !hit }' "$s" || continue
        m="$(map_owned_file "$root" "bin/${s##*/}")"
        [ -n "$m" ] || return 0
        mapped="$mapped $m"
      done
      printf '%s' "$mapped"
      ;;
    bin/*.sh)
      base="${f#bin/}"; base="${base%.sh}"
      mapped="$(split_map "$root" "$base")"
      if [ -n "$mapped" ]; then
        printf '%s' "$mapped"
      elif [ -e "$root/tests/sh/$base.test.sh" ]; then
        printf '%s' "$base.test.sh"
      fi
      ;;
  esac
  # Explicit, same reason sourcers_of ends on one: called as
  # `x="$(map_owned_file ...)"` under set -e, and an unmapped file's last
  # evaluated test (`[ -n "$mapped" ]`, false) would otherwise exit the
  # function non-zero and abort the whole script.
  return 0
}

select_changed() {
  local changed_root changed_files widen selected f mapped filtered t tname
  local sourcers s own lib_selected lib_unmapped m
  if ! changed_root="$(cd "$dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
     || [ -z "$changed_root" ]; then
    printf 'run-suite: --changed: not a git repo, falling back to the full set\n'
    return 0
  fi
  if ! git -C "$changed_root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf 'run-suite: --changed: no HEAD yet, falling back to the full set\n'
    return 0
  fi

  changed_files="$(
    { git -C "$changed_root" diff --name-only --diff-filter=d HEAD 2>/dev/null || true
      git -C "$changed_root" ls-files --others --exclude-standard 2>/dev/null || true
    } | sort -u
  )"

  widen=0
  selected=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Ahead of the shared-library branch, which reads an empty own mapping
    # as a bash lib with no test of its own and would narrow to importers.
    case "$f" in
      src/*.ts)
        if [ -z "$(map_owned_file "$changed_root" "$f")" ]; then
          printf 'run-suite: --changed widens to the full suite - %s is started by a bin script that has no colocated test\n' "$f"
          widen=1
          continue
        fi
        ;;
    esac
    sourcers="$(sourcers_of "$changed_root" "$f")"
    if [ -n "$sourcers" ]; then
      # Shared library: narrow to the UNION of its sourcers' own mapped
      # tests (one hop - each sourcer maps via the same rule as any other
      # changed file, never chased into ITS OWN sourcers) plus the lib's own
      # colocated test when it has one. Clause 2's "unmapped is unknown
      # blast radius" still governs each sourcer: one unmapped sourcer
      # widens the WHOLE run, same as an unmapped changed file always has.
      lib_selected=""
      lib_unmapped=0
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        m="$(map_owned_file "$changed_root" "$s")"
        if [ -n "$m" ]; then
          lib_selected="$lib_selected $m"
        else
          lib_unmapped=1
        fi
      done <<SOURCERS
$sourcers
SOURCERS
      if [ "$lib_unmapped" -eq 1 ]; then
        printf 'run-suite: --changed widens to the full suite - %s is a shared library with a sourcer that has no colocated test\n' "$f"
        widen=1
        continue
      fi
      own="$(map_owned_file "$changed_root" "$f")"
      [ -n "$own" ] && lib_selected="$lib_selected $own"
      printf 'run-suite: --changed narrows %s (a shared library) to its sourcers'"'"' tests:%s\n' "$f" "$lib_selected"
      selected="$selected $lib_selected"
      continue
    fi
    case "$f" in
      tests/sh/*.test.sh)
        selected="$selected ${f#tests/sh/}"
        ;;
      bin/*.sh | src/*.ts | tests/ts/*.test.ts)
        mapped="$(map_owned_file "$changed_root" "$f")"
        if [ -n "$mapped" ]; then
          selected="$selected $mapped"
        else
          printf 'run-suite: --changed widens to the full suite - %s has no colocated test\n' "$f"
          widen=1
        fi
        ;;
      *) ;; # not owned by this runner - ignored, like a changed README
    esac
  done <<CHANGED
$changed_files
CHANGED

  [ "$widen" -eq 0 ] || return 0 # widen: leave `tests` (the full set) as-is

  filtered=()
  for t in "${tests[@]}"; do
    tname="${t##*/}"
    case " $selected " in *" $tname "*) filtered+=("$t") ;; esac
  done
  # Guarded, not a direct `tests=("${filtered[@]}")`: this host's bash (3.2,
  # macOS) treats "${arr[@]}" on a genuinely EMPTY array as an unbound
  # variable under `set -u` - verified live - so a narrow-to-nothing result
  # would crash the runner instead of reaching the empty-selection exit
  # below.
  if [ "${#filtered[@]}" -gt 0 ]; then
    tests=("${filtered[@]}")
  else
    tests=()
  fi
}

if [ "$changed" = 1 ]; then
  select_changed
  if [ "${#tests[@]}" -eq 0 ]; then
    printf 'run-suite: --changed: mapped selection is empty (e.g. a clean, fully-committed tree) - nothing selected, nothing ran\n' >&2
    exit 2
  fi
fi

total=${#tests[@]}

# Parallel-mode decision (brief tests-need-a-canonical-run-suite): read, not
# guessed. tests/sh/helpers.sh gives every test its OWN mktemp AC_HOME, so
# file/state collisions across concurrently-run tests are structurally ruled
# out. But tests/sh/helpers.test.sh calls load_hogs(4), spinning real CPU
# busy-loops, and over a dozen other files carry sleep-based timing
# assumptions (ac-lock, ac-watch, ac-pane-agent, ...) - running those
# alongside the hog test risks flaky timing under contention, which IS the
# cross-test-interference shape the brief warned against. So sequential
# (--jobs 1) stays the default; --jobs N is opt-in for a caller that needs
# the full suite inside a bounded window and accepts that risk.

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

pass_count=0
fail_count=0
failed_names=""

i=0
while [ "$i" -lt "$total" ]; do
  batch=0
  pids=""
  batch_names=""
  while [ "$batch" -lt "$jobs" ] && [ "$i" -lt "$total" ]; do
    f="${tests[$i]}"
    name="${f##*/}"
    printf 'RUNNING %s\n' "$name"
    # set +e is load-bearing: the parent script runs under errexit, and this
    # subshell inherits it - without disabling it here, a failing `bash "$f"`
    # would abort the subshell before the printf below ever wrote the .rc
    # file, silently losing the run instead of counting it as a failure
    # (precedent: tests/sh/stress.sh's identical run_stress wrapper).
    #
    # set -m (job control) around the spawn is NOT optional: without it, an
    # async `&` command has SIGINT/SIGQUIT forced to ignore in bash itself
    # (Bash manual, "Signals"), and that ignore disposition survives exec and
    # fork into every descendant - including a watcher a test backgrounds and
    # sends INT to, which then can never see it. Verified live: ac-watch.test.sh
    # passes 3/3 standalone but false-reds under this loop without `set -m`,
    # because its watcher silently ignores the INT it is asserted to die from.
    # tests/sh/stress.sh and tests/sh/ac-watch.test.sh itself already rely on the
    # same toggle for the same reason - this mirrors that precedent, not a
    # new technique. Toggled off again right after so it does not change how
    # the OUTER loop's own `wait`/pipeline behave.
    #
    # The same toggle makes each suite a BACKGROUND job of whatever terminal
    # this runner sits in (the Learning gate runs it in a pane), so a suite
    # that reads stdin from that terminal is stopped by SIGTTIN and the wait
    # below never returns; no suite needs a terminal, so stdin is /dev/null.
    set -m
    ( set +e; bash "$f" </dev/null >"$scratch/$name.log" 2>&1; printf '%s\n' "$?" >"$scratch/$name.rc" ) &
    pids="$pids $!"
    set +m
    batch_names="$batch_names $name"
    i=$((i + 1))
    batch=$((batch + 1))
  done
  for p in $pids; do wait "$p" 2>/dev/null || true; done
  for name in $batch_names; do
    rc="$(cat "$scratch/$name.rc" 2>/dev/null || printf 1)"
    if [ "$rc" = 0 ]; then
      pass_count=$((pass_count + 1))
      printf 'PASS %s\n' "$name"
    else
      fail_count=$((fail_count + 1))
      failed_names="$failed_names $name"
      printf 'FAIL %s (exit %s)\n' "$name" "$rc"
      printf -- '----- output: %s -----\n' "$name"
      cat "$scratch/$name.log" 2>/dev/null || true
      printf -- '----- end: %s -----\n' "$name"
    fi
  done
done

printf '\n=== %s/%s passed, %s failed ===\n' "$pass_count" "$total" "$fail_count"
if [ "$fail_count" -gt 0 ]; then
  printf 'FAILED:%s\n' "$failed_names"
fi

[ "$fail_count" -eq 0 ]
