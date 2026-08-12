#!/usr/bin/env bash
# ac-config-surface.test.sh - the env-knob inventory contract (audit-f8).
# docs/configuration.md's environment table IS the knob manifest, and this
# test is what makes it one: every `AC_*` name read in bin/ must be either a
# documented row there, a declared INTERNAL variable, or a declared TEST
# SEAM - and every non-templated documented row must exist in code. Before
# this, the surface had drifted 46 undocumented vars and 3 phantom rows deep,
# because nothing diffed the two. (The check lives here and not in
# bin/ac-lint.sh on purpose: lint is opt-in by captain ruling 2026-07-21, and
# an invariant enforced by a skipped-by-default tool is decorative.)
#
# Adding a knob: give it a table row in docs/configuration.md.
# Adding an internal/wire variable or a test seam: declare it below WITH its
# one-line reason. An undeclared name fails this test either way.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

DOC="$ROOT/docs/configuration.md"

# INTERNAL: set and read by the tooling itself - wire between processes,
# exported constants, identity threading. Never a captain tunable.
internal="
AC_CAPTAIN_RE       exported marker regex constant (readers grep it)
AC_HARNESS_RE       exported registry constant (ac-harness.sh known set)
AC_DONELINE_AWK     exported shared awk program (backlog Done-line grammar)
AC_SEED_FALLBACK_REL   seed-layer constant (ac-lib.sh)
AC_SEED_STAMP_DIR_REL  seed-layer constant (ac-lib.sh)
AC_SEED_STAMP_SUFFIX   seed-layer constant (ac-lib.sh)
AC_SKILLS_ARCHIVE_BASENAME  skills-archive dirname constant (ac-lib.sh)
AC_QA_ATTESTATION_ERROR  out-param: qa attestation validator error carrier
AC_QA_BUNDLE_ERROR       out-param: qa bundle validator error carrier
AC_QA_MANIFEST_ERROR     out-param: qa manifest validator error carrier
AC_QA_RECEIPT_ERROR      out-param: qa receipt validator error carrier
AC_AUTOARM          intra-run wire: ac-watch-autoarm.sh exports it (=1) so the watcher it
                    starts records the arm as BOUNDED; never set by a human
AC_FINDINGS_ROUND   intra-run wire: ac-ship.sh -> ac_findings_normalize (review round)
AC_FINDINGS_DELTA   intra-run wire: ac-ship.sh -> ac_findings_normalize (fix delta)
AC_QA_RUN_ID        intra-run wire to spawned qa subprocesses
AC_QA_EVIDENCE      intra-run wire to spawned qa subprocesses
AC_QA_STEP_NOTE     env->awk ENVIRON wire (tab-safe note transport)
AC_NOTIFY_TITLE     wedge-alarm hook interface (ac-notify.sh -> hook)
AC_NOTIFY_MESSAGE   wedge-alarm hook interface (ac-notify.sh -> hook)
AC_REMOTE_ACK_STATE remote hook interface (ac-remote.sh <-> hooks)
AC_REMOTE_MENTION   remote hook interface
AC_REMOTE_RID       remote hook interface
AC_REMOTE_THREAD    remote hook interface
AC_PROMPT           custom launch-template interpolation variable
AC_CREW_ID          spawn->crewmate identity threading (launch line)
AC_FLEET_REVIEW     spawn->crewmate review-obligation threading
AC_PA_LABEL         pane-agent internal label threading
AC_LOCK_PID         lock-owner record wire (ac-lock.sh)
AC_PLIST            env->awk ENVIRON wire (ac-spawn.sh list transport)
AC_ROOM_PROMOTE_RECEIPT  spawn->ac-room.sh cap-gate exemption receipt declaration (one call site)
"

# TEST SEAMS: overrides that exist so the suite can stub a collaborator.
# The two arbitrary-exec HOOKS are double-keyed on AC_TEST_HOOKS (helpers.sh
# exports it; production without it never execs them - asserted below). The
# *_BIN/AC_GATE/AC_PANE_AGENT class keeps a SAFE same-dir sibling default and
# the env only redirects it - the fake-driver pattern the suite runs on.
seams="
AC_TEST_HOOKS       the double key itself (exported only by tests/helpers.sh)
AC_CURATE_SNAPSHOT_HOOK   mid-transaction injection hook (double-keyed)
AC_QA_PROFILE_RECHECK_HOOK  mid-preflight injection hook (double-keyed)
AC_QA_FIXTURE_PACK  qa fixture-pack selector for stubbed rounds
AC_WAKE_SEAM_AT     wake-publish fault-injection seam (ac-wake-lib.sh)
AC_WAKE_SEAM_RUN    wake-publish fault-injection seam
AC_VERIFY_BIN       sibling-path override: ac-verify.sh fake driver
AC_VERIFY_PANE_BIN  sibling-path override: pane-agent fake driver
AC_VERIFY_TREE_BIN  sibling-path override: ac-tree fake driver
AC_VERIFY_QA_RELAY_BIN  sibling-path override: qa relay fake driver
AC_GATE             sibling-path override: ac-gate.sh fake driver
AC_CURATE           sibling-path override: ac-curate.sh fake driver
AC_TEARDOWN_QA_TIMEOUT  test-only shortener (ac-teardown.sh header says so)
"

known_extra() {
  # known_extra <name> - internal or seam?
  printf '%s\n%s\n' "$internal" "$seams" | awk -v n="$1" '$1 == n { found=1 } END { exit !found }'
}

# --- every AC_* read in bin/ is documented or declared -----------------------
# Tokens are maximal [A-Z_]+ runs; a token ENDING in `_` is a dynamic-family
# prefix (AC_FLEET_MODEL_$ku and friends) and must match a templated doc row
# (`AC_X_<...>`), which documents the whole family.
code_tokens="$(grep -ohE 'AC_[A-Z_]+' "$BIN"/*.sh | sort -u)"
doc_names="$(awk -F'`' '/^\| `AC_/ {print $2}' "$DOC" | sort -u)"
doc_plain="$(printf '%s\n' "$doc_names" | grep -v '<' || true)"
doc_prefixes="$(printf '%s\n' "$doc_names" | sed -n 's/^\(AC_[A-Z_]*_\)<.*$/\1/p' | sort -u)"

undeclared=""
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  case "$tok" in
    *_)
      printf '%s\n' "$doc_prefixes" | grep -qxF "$tok" && continue
      # a dynamic construction may grep as a SHORTER root than the documented
      # family (AC_FLEET_$(tr ...)_$ru greps as AC_FLEET_) or as a LONGER
      # one; either containment direction against a templated row covers it.
      ok=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$tok" in "$p"*) ok=1 ;; esac
        case "$p" in "$tok"*) ok=1 ;; esac
      done <<EOF
$doc_prefixes
EOF
      [ "$ok" = 1 ] && continue
      ;;
    *)
      printf '%s\n' "$doc_plain" | grep -qxF "$tok" && continue
      known_extra "$tok" && continue
      # a constructed dynamic name may also appear with a literal suffix in
      # comments/examples (AC_FLEET_PROFILE_QA): the documented family covers it
      ok=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$tok" in "$p"*) ok=1 ;; esac
      done <<EOF
$doc_prefixes
EOF
      [ "$ok" = 1 ] && continue
      ;;
  esac
  undeclared="$undeclared $tok"
done <<EOF
$code_tokens
EOF
[ -z "$undeclared" ] || fail "undocumented and undeclared AC_ names in bin/:$undeclared - add a docs/configuration.md row (a tunable) or declare it in this test with a reason (internal wire / test seam)"

# --- every plain documented row exists in code (no phantom knobs) ------------
phantom=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' "$code_tokens" | grep -qxF "$name" || phantom="$phantom $name"
done <<EOF
$doc_plain
EOF
[ -z "$phantom" ] || fail "documented env rows with no reader in bin/:$phantom - a captain can set these to no effect; delete the row or restore the reader"

# --- the two exec hooks stay double-keyed ------------------------------------
grep -q 'AC_TEST_HOOKS.*AC_CURATE_SNAPSHOT_HOOK\|AC_CURATE_SNAPSHOT_HOOK' "$BIN/ac-curate.sh" || fail "curate snapshot hook site vanished - update this test"
grep -B2 '"${AC_CURATE_SNAPSHOT_HOOK}" "$records"' "$BIN/ac-curate.sh" | grep -q 'AC_TEST_HOOKS' \
  || fail "the curate snapshot hook must stay double-keyed on AC_TEST_HOOKS (audit-f8): an inherited env var alone must never make production exec an arbitrary file"
grep -B2 '"${AC_QA_PROFILE_RECHECK_HOOK}" "$cfg" "$know"' "$BIN/ac-qa.sh" | grep -q 'AC_TEST_HOOKS' \
  || fail "the qa profile-recheck hook must stay double-keyed on AC_TEST_HOOKS (audit-f8)"

pass
