#!/usr/bin/env bash
# ac-gate-watch.test.sh - the ACTIVE-run second-chief observer (bin/ac-gate-watch.sh).
# It shows ONLY gates running RIGHT NOW (the .gate-running marker + its observe
# descriptor); a SETTLED second-chief.md is an ordinary artifact and creates NO
# row. --once renders the active dashboard (newest-first, dot-dirs are not
# families) and never crashes on an empty home; --tail follows the newest active
# gate's REAL emitted bytes (the exact prompt once, then the harness's own
# output) - it never invents reasoning.
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# ac-gate-watch needs jq unconditionally (it reads the observe descriptor); a
# jq-less host can run nothing here.
command -v jq >/dev/null || { printf 'SKIP: jq not available\n'; exit 0; }

make_home
W="$BIN/ac-gate-watch.sh"

# mk_active <fam> <stage> <round> <engine> <mtime> <prompt> <out> [pid] - stamp
# ONE active gate:
# the .gate-running marker (ac-gate's live fields) + the transient observe
# descriptor the pane-agent arm publishes + its real prompt/out/err stream files.
mk_active() {
  local fam=$1 stage=$2 round=$3 eng=$4 mt=$5 pc=$6 oc=$7 pid=${8:-$$} d
  d="$AC_HOME/data/$fam"; mkdir -p "$d/$stage"
  printf '%s\n' "$pc" >"$d/.gate-prompt-r$round"
  printf '%s\n' "$oc" >"$d/.gate-out-r$round"
  : >"$d/.gate-err-r$round"
  printf '{"pane":"pX","tab":"tX","harness":"%s","prompt":"%s","out":"%s","err":"%s"}\n' \
    "$eng" "$d/.gate-prompt-r$round" "$d/.gate-out-r$round" "$d/.gate-err-r$round" \
    >"$d/.gate-observe-r$round"
  printf 'family=%s\nstage=%s\nround=%s\nengine=%s\nmodel=\nat=%s\nobserve=%s\npid=%s\n' \
    "$fam" "$stage" "$round" "$eng" "2026-07-23T09:0${mt}:00Z" \
    "$d/.gate-observe-r$round" "$pid" >"$d/.gate-running"
  touch -t "$(printf '2026072309%02d' "$mt")" "$d/.gate-running"
}

# 1. empty home: clean exit, "no gate running", zero active
out="$("$W" --once 2>&1)" || fail "watch --once must exit 0 on an empty home"
case "$out" in *"no gate running"*) ;; *) fail "empty home should say 'no gate running': $out" ;; esac
case "$out" in *"0 active"*) ;; *) fail "empty home should report 0 active: $out" ;; esac

# 2. a SETTLED second-chief.md alone creates NO row (the contract inversion vs the
#    old gate.json board: settled reviews are browsed elsewhere, never here)
mkdir -p "$AC_HOME/data/settled/spec"
printf -- '---\ndecision: continue\n---\n# Second-Chief Decision\n' >"$AC_HOME/data/settled/spec/second-chief.md"
out="$("$W" --once 2>&1)" || fail "watch must not crash on a settled review"
case "$out" in *settled*) fail "a settled second-chief.md must NOT appear on the active board: $out" ;; esac
case "$out" in *"no gate running"*) ;; *) fail "a settled-only home still has no ACTIVE gate: $out" ;; esac

# 3. one active gate: family, stage, engine, and the REAL last activity line show.
# The activity column is truncated to the terminal width, so its probe token is
# kept short; --tail (below) proves the full untruncated bytes are followed.
mk_active widget spec 1 codex 6 "PROMPT-WIDGET-SPEC contract" "emit-live-widget"
out="$("$W" --once 2>&1)" || fail "watch --once must exit 0 with an active gate"
case "$out" in *"1 active"*) ;; *) fail "one active gate should report 1 active: $out" ;; esac
case "$out" in *widget*) ;; *) fail "the active family is not shown: $out" ;; esac
case "$out" in *spec*) ;; *) fail "the active stage is not shown: $out" ;; esac
case "$out" in *codex*) ;; *) fail "the active engine is not shown: $out" ;; esac
case "$out" in *r1*) ;; *) fail "the active gate round is not shown: $out" ;; esac
case "$out" in *emit-live-widget*) ;; *) fail "the REAL emitted activity is not shown: $out" ;; esac

# 4. two active gates float NEWEST-first (by marker mtime)
mk_active gizmo plan 2 claude 8 "PROMPT-GIZMO-PLAN" "gizmo-activity"
out="$("$W" --once 2>&1)"
gline="$(printf '%s\n' "$out" | grep -n gizmo | head -1 | cut -d: -f1)"
wline="$(printf '%s\n' "$out" | grep -n widget | head -1 | cut -d: -f1)"
{ [ -n "$gline" ] && [ -n "$wline" ] && [ "$gline" -lt "$wline" ]; } \
  || fail "the newer active gate must sort first (gizmo=$gline widget=$wline)"
out="$("$W" --round 2 --once 2>&1)"
case "$out" in *gizmo*) ;; *) fail "--round 2 must retain the R2 gate: $out" ;; esac
case "$out" in *widget*) fail "--round 2 must filter out the R1 gate: $out" ;; esac
assert_fails "$W" --round 3 --once

# 5. a dot-prefixed dir is never treated as a family
mkdir -p "$AC_HOME/data/.hidden/spec"
printf 'family=.hidden\nstage=spec\nround=1\nengine=codex\nmodel=\nat=x\nobserve=-\npid=%s\n' \
  "$$" >"$AC_HOME/data/.hidden/.gate-running"
out="$("$W" --once 2>&1)" || fail "watch must not crash on a dot-prefixed dir"
case "$out" in *hidden*) fail "a dot-prefixed dir must not appear as a family: $out" ;; esac

# 6. --tail follows the newest active gate's EXACT prompt (once) + real output.
#    --tail is an endless follow loop (no --once), so bound it: run it briefly in
#    the background, then stop it and inspect what it emitted. No timeout(1) on
#    this host, so background+kill is the bounded harness.
tout="$TMP/tail.out"
# The whole background+kill+wait runs in a subshell whose stderr is discarded, so
# the shell's "Terminated" job-control notice never leaks into the suite output.
(
  "$W" --tail --interval 1 >"$tout" 2>&1 &
  tpid=$!
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap="$(cat "$tout" 2>/dev/null)"
case "$tcap" in *"-- prompt --"*) ;; *) fail "--tail must print the prompt block: $tcap" ;; esac
case "$tcap" in *"PROMPT-GIZMO-PLAN"*) ;; *) fail "--tail must show the newest gate's EXACT prompt: $tcap" ;; esac
case "$tcap" in *"gizmo"*) ;; *) fail "--tail must banner the active family/stage: $tcap" ;; esac
case "$tcap" in *"gizmo-activity"*) ;; *) fail "--tail must follow the REAL emitted output bytes: $tcap" ;; esac
# 7. --tail NAMES ITS FLEET HOME, like the dashboard header already does. The
#    auto-opened board is a tail board, and a fleet runs several homes: an
#    operator who cannot tell WHICH home is being watched cannot use the surface
#    to diagnose (it blocked a diagnosis on 2026-07-26).
case "$tcap" in *"$(basename "$AC_HOME")"*) ;; *) fail "--tail header must name the fleet home: $tcap" ;; esac

# 8. once the followed gate SETTLES (its .gate-running goes away), --tail
#    announces where its prompt is retained - a settled gate has no live stream
#    left to follow, but the board the captain runs should still say where the
#    prompt landed (ac-gate.sh keeps it at gate-prompt.md, never deleted).
rm -f "$AC_HOME"/data/*/.gate-running
mk_active solo design 1 opencode 9 "PROMPT-SOLO-DESIGN" "solo-activity"
tout2="$TMP/tail2.out"
(
  "$W" --tail --interval 1 >"$tout2" 2>&1 &
  tpid=$!
  sleep 2
  rm -f "$AC_HOME/data/solo/.gate-running"
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap2="$(cat "$tout2" 2>/dev/null)"
case "$tcap2" in *"settled"*) ;; *) fail "--tail must announce the settled gate: $tcap2" ;; esac
case "$tcap2" in *"$AC_HOME/data/solo/.gate-prompt-r1"*) ;; *) fail "--tail must name where the settled prompt is retained: $tcap2" ;; esac

# 9. The marker intentionally lands before pane-agent publishes its observation
# descriptor. If --tail observes that startup window, it must keep probing the
# descriptor rather than pinning empty stream paths for the whole round.
rm -f "$AC_HOME"/data/*/.gate-running
lag="$AC_HOME/data/lag"; mkdir -p "$lag/spec"
: >"$lag/.gate-observe-r1"
printf 'family=lag\nstage=spec\nround=1\nengine=codex\nmodel=\nat=2026-07-23T09:10:00Z\nobserve=%s\npid=%s\n' \
  "$lag/.gate-observe-r1" "$$" >"$lag/.gate-running"
tout3="$TMP/tail3.out"
(
  "$W" --tail --interval 1 >"$tout3" 2>&1 &
  tpid=$!
  sleep 2
  printf '%s\n' "PROMPT-LATE-DESCRIPTOR" >"$lag/.gate-prompt-r1"
  printf '%s\n' "late-descriptor-activity" >"$lag/.gate-out-r1"
  : >"$lag/.gate-err-r1"
  printf '{"pane":"pL","tab":"tL","harness":"codex","prompt":"%s","out":"%s","err":"%s"}\n' \
    "$lag/.gate-prompt-r1" "$lag/.gate-out-r1" "$lag/.gate-err-r1" \
    >"$lag/.gate-observe-r1"
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap3="$(cat "$tout3" 2>/dev/null)"
case "$tcap3" in *PROMPT-LATE-DESCRIPTOR*) ;; *) fail "--tail must recover a descriptor published after the marker: $tcap3" ;; esac
case "$tcap3" in *late-descriptor-activity*) ;; *) fail "--tail must follow streams from the late descriptor: $tcap3" ;; esac

# 10. R1 and R2 share family/stage. A watcher that misses the brief marker-free
# interval must still switch because round + observe identify the run.
rm -f "$AC_HOME"/data/*/.gate-running
mk_active swap spec 1 codex 11 "PROMPT-SWAP-R1" "swap-r1-activity"
tout4="$TMP/tail4.out"
(
  "$W" --tail --interval 1 >"$tout4" 2>&1 &
  tpid=$!
  sleep 2
  mk_active swap spec 2 codex 12 "PROMPT-SWAP-R2" "swap-r2-activity"
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap4="$(cat "$tout4" 2>/dev/null)"
case "$tcap4" in *PROMPT-SWAP-R1*) ;; *) fail "--tail must show R1 before the switch: $tcap4" ;; esac
case "$tcap4" in *PROMPT-SWAP-R2*) ;; *) fail "--tail must switch to the R2 prompt: $tcap4" ;; esac
case "$tcap4" in *swap-r2-activity*) ;; *) fail "--tail must switch to the R2 stream: $tcap4" ;; esac
case "$tcap4" in *" / r1  "*"/ r2  "*) ;; *) fail "--tail must label both rounds: $tcap4" ;; esac

# 11. A SIGKILL cannot run ac-gate's EXIT trap. The watcher remains read-only
# but ignores a marker whose recorded owner pid is dead.
rm -f "$AC_HOME"/data/*/.gate-running
mk_active dead spec 1 codex 13 "PROMPT-DEAD" "dead-activity" 99999999
out="$("$W" --once 2>&1)" || fail "watch must tolerate a stale marker"
case "$out" in *"0 active"*) ;; *) fail "a dead-owner marker must not count as active: $out" ;; esac
case "$out" in *dead*) fail "a dead-owner marker must not render as a live gate: $out" ;; esac

pass
