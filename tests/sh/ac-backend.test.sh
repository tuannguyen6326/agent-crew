#!/usr/bin/env bash
# ac-backend.test.sh - backend SELECTION and dispatch validation: the
# no-config default, and rejection of every name but orca (including the
# retired herdr and the removed tmux/wezterm/screen), plus the
# ac_startup_dialogs loop bound, which is backend-neutral (injected
# callbacks, never a real driver call). The orca driver's own behavior -
# handle persistence, liveness, capture, send, kill, dialogs, the wait
# stamp - is tests/sh/ac-backend-orca.test.sh; this file no longer carries
# a driver of its own to prove, since herdr's was the only one it ever held
# (GAP: every section that drove real herdr CLI calls - window placement,
# capture, send, kill, focus, startup-dialog naming, the captain-wait stamp,
# the three-state liveness ladder, the per-RPC hang ceiling, the launch-line
# env fixup, and the composer-text byte matcher - is deleted outright, not
# ported; orca's own versions of the ones that still apply are already
# proven in ac-backend-orca.test.sh).
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"

run_backend_routed() {
  # run_backend_routed <backend> <script> - source the libs with the stub
  # PATH and the given backend, the REAL ladder, no override: exercises
  # ac_backend itself (the cutover's own refusal).
  PATH="$stub:$PATH" AC_BACKEND="$1" AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    . '$BIN/ac-backend.sh'
    $2
  "
}

# --- no-config default: AC_BACKEND unset, no config/backend -> orca -----------------
rm -f "$AC_HOME/config/backend"
out="$(PATH="$stub:$PATH" AC_HOME="$AC_HOME" bash -c '
  unset AC_BACKEND AC_FLEET_STATE
  . "'"$BIN"'/ac-lib.sh"
  . "'"$BIN"'/ac-backend.sh"
  ac_backend
')"
assert_eq "$out" "orca" "an isolated home with no config/backend and AC_BACKEND unset selects orca"

# --- dispatch validation: orca is the only valid backend; herdr is refused too -----

# The cutover (T8) ends herdr's standing as a backend: tmux, wezterm, screen
# and now herdr itself are all refused, named, before any primitive runs.
assert_fails run_backend_routed herdr 'backend_target x1'
assert_fails run_backend_routed tmux 'backend_target x1'
assert_fails run_backend_routed wezterm 'backend_target x1'
err="$(run_backend_routed herdr 'backend_target x1' 2>&1 || true)"
assert_contains "$err" "ERROR: unsupported backend 'herdr' (valid backend: orca)" "herdr refuses with the exact cutover error"
err="$(run_backend_routed tmux 'backend_target x1' 2>&1 || true)"
assert_contains "$err" "valid backend: orca" "an unknown name's rejection names the sole valid backend"
assert_fails run_backend_routed screen 'backend_target x1'

# --- the startup sequence is bounded on EVERY arm -----------------------------
# A dialog the driver answers but that does not clear (a key the screen ignores,
# a prompt that redraws) used to spin the sequence forever: the answered arm
# jumped the budget check at the loop's foot. Backend-neutral: a(), k() and u()
# are injected stubs, never a real driver call, so this proves the LOOP's own
# bound regardless of which backend sourced it. A regression HANGS rather than
# fails, so this runs the sequence detached and kills it.
seqlog="$TMP/seq-answers"
: >"$seqlog"
( run_backend_routed orca '
    a() { printf "x\n" >>"'"$seqlog"'"; return 0; }   # answered, never clears
    k() { :; }
    u() { return 0; }
    ac_startup_dialogs a k u p1 codex
  ' >/dev/null 2>&1 ) &
seqpid=$!
waited=0
while kill -0 "$seqpid" 2>/dev/null && [ "$waited" -lt 8 ]; do sleep 1; waited=$((waited + 1)); done
if kill -0 "$seqpid" 2>/dev/null; then
  kill -9 "$seqpid" 2>/dev/null || true
  fail "an answered dialog that never clears must not loop past the budget"
fi
wait "$seqpid" 2>/dev/null || true
answers="$(wc -l <"$seqlog" | tr -d ' ')"
[ "$answers" -ge 1 ] || fail "the sequence must answer at least once before giving up"
[ "$answers" -le 4 ] \
  || fail "answers must be bounded by AC_STARTUP_DIALOG_BUDGET (2 here); got $answers"

pass
