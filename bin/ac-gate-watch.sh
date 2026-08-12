#!/usr/bin/env bash
# ac-gate-watch.sh - ACTIVE-run observer for the second-chief gate, modeled on
# nm-claude-watch (dashboard + --tail). It shows ONLY gates running RIGHT NOW;
# settled reviews (second-chief.md) are ordinary artifacts browsed elsewhere and
# never appear here.
#
#   ac-gate-watch.sh [SECS]        default: dashboard, one row per ACTIVE gate
#   ac-gate-watch.sh --tail        follow the newest active gate's live output,
#                                  auto-switching when it completes and another
#                                  becomes active
#     [--family F] [--stage S] [--round 1|2]
#                                     optional simple pins
#     [--self-pane ID]             DASHBOARD MODE ONLY: a pane to close on idle
#     [--interval SECS] [--once]
#
# Data sources - ACTIVE runs ONLY: data/<family>/.gate-running (the marker
# ac-gate stamps: family/stage/round/engine/model/at/observe/pid) plus the
# TRANSIENT observation descriptor named by `observe=` (pane/tab/harness + the real
# prompt/out/err file paths the one-shot run uses, published by
# `ac-pane-agent --observe`). It follows ONLY bytes the selected harness actually
# emitted to those streams - it never invents reasoning, claims hidden
# chain-of-thought, or turns missing output into synthetic progress (a
# final-answer-only harness shows the prompt, then its final output when it
# lands). A settled second-chief.md NEVER creates a row. Read-only, HOME-scoped.
#
# WHY A CODEX GATE HAD NO ACTIVITY TO SHOW (measured, historical): a real run
# once printed `reasoning effort: high` then `reasoning summaries: none` in its
# own banner, and its transcript carried exactly ONE event (the final answer) -
# the harness emitted no reasoning bytes to follow, by codex's own default. A
# knob to ask for them was verified LIVE (2026-07-26): `codex exec -c
# model_reasoning_summary=<auto|concise|detailed>` (enum confirmed via
# --strict-config; `detailed` measurably changed the banner and produced an
# actual reasoning-summary line before the final answer, on a prompt that
# required real reasoning). CAPTAIN DECISION (2026-07-26): run gate summaries
# at `auto` - the smallest footprint of the enabled options that still answers
# "what is it thinking" - wired into oneshot_launch's codex form
# (bin/ac-pane-agent.sh), unconditionally, since this table's one consumer is
# the gate. So a codex gate's activity now generally carries real
# reasoning-summary bytes when the model produces any; an empty section still
# means exactly what it always did - the model reasoned little enough that
# `auto` chose not to summarize, never a harness or board defect.
#
# Auto-open: ac-gate.sh opens a board pane PER RUN, ac-ship-watch style
# (captain 2026-08-06 "gate-watch theo family, nhu ac-ship-watch", superseding
# the 2026-07-26 always-open fleet board): label ac-gate-watch:<family>, in the
# FAMILY's workspace, IN --tail MODE pinned --family - the exact prompt plus
# the live emitted output, not the row dashboard. The board is retired WITH the
# run by ac-gate.sh's own EXIT trap; the tail loop itself still never
# self-closes and is still handed no --self-pane, so nothing here claims a
# close tail_loop cannot perform. Self-close is DASHBOARD-ONLY: run
# without --tail, it exits after AC_GATE_WATCH_IDLE secs (default 1800) with no
# active gate, closing the pane named by --self-pane when one was given.
# Session: AC_HERDR_SESSION > config/herdr-session > default.
set -u
. "$(dirname "$0")/ac-lib.sh"

MODE="dashboard"; INTERVAL=2; ONCE=0; SELF=""; PIN_FAM=""; PIN_STAGE=""; PIN_ROUND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tail) MODE="tail" ;;
    --family) PIN_FAM=${2:?}; shift ;;
    --stage) PIN_STAGE=${2:?}; shift ;;
    --round) PIN_ROUND=${2:?}; shift ;;
    --self-pane) SELF=${2:?}; shift ;;
    --interval) INTERVAL=${2:?}; shift ;;
    --once) ONCE=1 ;;
    [0-9]*) INTERVAL=$1 ;;
    *) ac_die "unknown arg: $1" ;;
  esac
  shift
done
case "$PIN_ROUND" in ''|1|2) ;; *) ac_die "--round must be 1 or 2" ;; esac
home="$(ac_home)"; data="$home/data"
SES="${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}"
command -v jq >/dev/null 2>&1 || ac_die "ac-gate-watch needs jq"

if [ -t 1 ]; then
  c_r=$'\033[0m'; c_b=$'\033[1m'; c_dim=$'\033[2m'; c_cyn=$'\033[36m'; c_grn=$'\033[32m'
else
  c_r=""; c_b=""; c_dim=""; c_cyn=""; c_grn=""
fi

fmt_mt() { stat -f %m "$1" 2>/dev/null || echo 0; }
fmt_size() { wc -c <"$1" 2>/dev/null | tr -d ' ' || echo 0; }
obs_field() { [ -f "$1" ] && jq -r --arg k "$2" '.[$k] // ""' "$1" 2>/dev/null || true; }

marker_live() {
  local marker="$1" pid
  pid="$(ac_meta_get "$marker" pid)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # The gate and its watcher run as the same fleet user, so kill -0 is a
  # permission-safe existence probe here and remains available in restricted
  # environments where process-table inspection is blocked.
  kill -0 "$pid" 2>/dev/null
}

self_close() {
  [ -n "$SELF" ] || exit 0
  command -v herdr >/dev/null 2>&1 && herdr --session "$SES" pane close "$SELF" >/dev/null 2>&1
  exit 0
}

# One TSV row per ACTIVE gate, newest-first:
#   <mtime>\t<family>\t<stage>\t<round>\t<engine>\t<model>\t<at>\t<observe>\t<pid>
active_rows() {
  local m fam stage round engine model at obs pid
  for m in "$data"/*/.gate-running; do
    [ -f "$m" ] || continue
    marker_live "$m" || continue
    fam="$(basename "$(dirname "$m")")"
    [ -n "$PIN_FAM" ] && [ "$PIN_FAM" != "$fam" ] && continue
    stage="$(ac_meta_get "$m" stage)"
    [ -n "$PIN_STAGE" ] && [ "$PIN_STAGE" != "$stage" ] && continue
    round="$(ac_meta_get "$m" round)"
    [ -n "$PIN_ROUND" ] && [ "$PIN_ROUND" != "$round" ] && continue
    engine="$(ac_meta_get "$m" engine)"; model="$(ac_meta_get "$m" model)"
    at="$(ac_meta_get "$m" at)"; obs="$(ac_meta_get "$m" observe)"; pid="$(ac_meta_get "$m" pid)"
    # model gets a `-` placeholder like the others: an EMPTY interior TSV field
    # collapses under `IFS=$'\t' read` (tab is IFS-whitespace), which would shift
    # every column after it - and an unset gate-model is the common case.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(fmt_mt "$m")" "$fam" "${stage:--}" "${round:--}" "${engine:--}" \
      "${model:--}" "${at:--}" "${obs:--}" "$pid"
  done | sort -rn
}

# The last emitted line of the active run's real output (stdout, else stderr).
last_activity() {
  local obs out err line f
  obs="$1"; [ -n "$obs" ] || return 0
  out="$(obs_field "$obs" out)"; err="$(obs_field "$obs" err)"
  for f in "$out" "$err"; do
    [ -n "$f" ] && [ -s "$f" ] || continue
    line="$(tail -n 1 "$f" 2>/dev/null)"
    [ -n "$line" ] && { printf '%s' "$line"; return 0; }
  done
}

# ============================ dashboard ============================
render() {
  local rows COLS fleet n fam stage round engine model at obs pid act eng when cut rlabel
  COLS="$( (tput cols 2>/dev/null || echo 200) | head -1)"
  fleet="$(ac_fleet_name)"
  rows="$(active_rows)"
  n=0; [ -n "$rows" ] && n=$(printf '%s\n' "$rows" | grep -c .)
  printf '%sac-gate%s %s%s%s  %s%s active%s\n\n' \
    "$c_b" "$c_r" "$c_cyn" "$fleet" "$c_r" "$c_dim" "$n" "$c_r"
  if [ -z "$rows" ]; then
    printf '%s(no gate running)%s\n' "$c_dim" "$c_r"
    return
  fi
  printf '%s  %-22s %-8s %-5s %-20s %s%s\n' \
    "$c_dim" "family" "stage" "round" "engine/model" "since | activity" "$c_r"
  cut=$((COLS > 80 ? COLS - 77 : 20))
  while IFS=$'\t' read -r _ fam stage round engine model at obs _; do
    [ -n "$fam" ] || continue
    eng="$engine"; [ -n "$model" ] && [ "$model" != - ] && eng="$engine/$model"
    rlabel="-"; [ "$round" != - ] && rlabel="r$round"
    act="$(last_activity "$obs")"
    when="${at##*T}"; when="${when%Z}"
    printf ' %s>%s %-22s %-8s %-5s %-20s %s%s%s %s\n' \
      "$c_cyn" "$c_r" "$fam" "$stage" "$rlabel" "$eng" "$c_dim" "$when" "$c_r" \
      "$(printf '%s' "$act" | cut -c1-"$cut")"
  done <<<"$rows"
  printf '\n%s--tail to follow the exact prompt + live emitted output of the active gate%s\n' "$c_dim" "$c_r"
}

# ============================ --tail ============================
# Follow the NEWEST active gate's real emitted output, auto-switching when the
# target changes. Print the exact prompt ONCE per target. Label the streams.
# When the followed gate SETTLES (no active gate remains), announce where its
# prompt is retained (data/<family>/<short>/gate-prompt.md, kept by ac-gate.sh
# after exit) - a settled gate has no live stream left to follow, but the board
# the captain runs should still say where its prompt landed.
tail_loop() {
  local cur="__none__" obs prompt="" out="" err="" fam stage round engine model
  local row off_out=0 off_err=0 so se target eng rlabel next_prompt next_out next_err
  local shown_prompt=0 stream_announced=0
  # Name the fleet home, exactly as the dashboard header does: a host runs
  # several homes and a tail board that names none leaves the operator unable to
  # tell WHICH fleet it is watching.
  printf '%sac-gate%s %s%s%s %s- following the active second-chief run (Ctrl-C to quit)%s\n' \
    "$c_b" "$c_r" "$c_cyn" "$(ac_fleet_name)" "$c_r" "$c_dim" "$c_r"
  while :; do
    row="$(active_rows | head -1)"
    if [ -z "$row" ]; then
      if [ "$cur" != "__wait__" ]; then
        [ -n "$prompt" ] && printf '%s  (settled - prompt retained at %s)%s\n' "$c_dim" "$prompt" "$c_r"
        printf '%s  ... waiting for an active gate ...%s\n' "$c_dim" "$c_r"
      fi
      cur="__wait__"; sleep "$INTERVAL"; continue
    fi
    IFS=$'\t' read -r _ fam stage round engine model _ obs _ <<<"$row"
    target="$fam/$stage/$round/$obs"
    if [ "$cur" != "$target" ]; then
      cur="$target"
      prompt=""; out=""; err=""; shown_prompt=0; stream_announced=0
      off_out=0; off_err=0
      eng="$engine"; [ -n "$model" ] && [ "$model" != - ] && eng="$engine/$model"
      rlabel="-"; [ "$round" != - ] && rlabel="r$round"
      printf '\n%s== %s / %s / %s  [%s] ==%s\n' \
        "$c_cyn" "$fam" "$stage" "$rlabel" "$eng" "$c_r"
    fi

    # The marker is published before pane-agent atomically publishes its
    # observation descriptor. Re-read until the descriptor is ready instead of
    # permanently pinning empty paths from that startup window.
    next_prompt="$(obs_field "$obs" prompt)"
    next_out="$(obs_field "$obs" out)"
    next_err="$(obs_field "$obs" err)"
    if [ -n "$next_prompt" ] && [ "$next_prompt" != "$prompt" ]; then
      prompt="$next_prompt"; shown_prompt=0
    fi
    if [ -n "$next_out" ] && [ "$next_out" != "$out" ]; then out="$next_out"; off_out=0; fi
    if [ -n "$next_err" ] && [ "$next_err" != "$err" ]; then err="$next_err"; off_err=0; fi

    if [ "$shown_prompt" = 0 ] && [ -n "$prompt" ] && [ -f "$prompt" ]; then
      printf '%s-- prompt --%s\n' "$c_dim" "$c_r"; cat "$prompt" 2>/dev/null; printf '\n'
      shown_prompt=1
    fi
    if [ "$stream_announced" = 0 ] && { [ -n "$out" ] || [ -n "$err" ]; }; then
      printf '%s-- activity/output (live emitted bytes) --%s\n' "$c_dim" "$c_r"
      stream_announced=1
    fi
    # follow newly emitted bytes of both streams (real harness output only)
    if [ -n "$err" ] && [ -f "$err" ]; then
      se="$(fmt_size "$err")"; [ "$se" -gt "$off_err" ] && { tail -c +$((off_err + 1)) "$err" 2>/dev/null; off_err="$se"; }
    fi
    if [ -n "$out" ] && [ -f "$out" ]; then
      so="$(fmt_size "$out")"; [ "$so" -gt "$off_out" ] && { printf '%s' "$c_grn"; tail -c +$((off_out + 1)) "$out" 2>/dev/null; printf '%s' "$c_r"; off_out="$so"; }
    fi
    sleep "$INTERVAL"
  done
}

idle_since() {
  local row
  row="$(active_rows | head -1)"
  [ -n "$row" ] && printf '%s\n' "${row%%$'\t'*}" || printf '0\n'
}

paint() { printf '\033[H%s\033[J\n' "$(printf '%s\n' "$1" | sed $'s/$/\033[K/')"; }

if [ "$MODE" = tail ]; then
  tail_loop
  exit 0
fi

# dashboard loop
last_frame=""; waited=0
if [ "$ONCE" = 0 ]; then printf '\033[2J\033[H\033[?25l'; trap 'printf "\033[?25h"' EXIT; fi
while :; do
  frame="$(render)"
  if [ "$ONCE" = 1 ]; then printf '%s\n' "$frame"; exit 0; fi
  [ "$frame" = "$last_frame" ] || { paint "$frame"; last_frame="$frame"; }
  newest="$(idle_since)"
  if [ "$newest" -gt 0 ]; then
    waited=0
    [ $(( $(ac_now) - newest )) -gt "${AC_GATE_WATCH_IDLE:-1800}" ] && { printf '\nno active gate - closing watch\n'; sleep 2; self_close; }
  else
    waited=$((waited + INTERVAL)); [ "$waited" -gt 300 ] && self_close
  fi
  sleep "$INTERVAL"
done
