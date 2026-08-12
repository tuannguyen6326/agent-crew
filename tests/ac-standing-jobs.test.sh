#!/usr/bin/env bash
# ac-standing-jobs.test.sh - the session-start standing-jobs digest block:
# reports each DECLARED job's state from records/standing-jobs.md, with the
# exact re-create action, and never claims a declared-OFF job needs one.
# CronCreate is session-only (no on-disk liveness signal), so an ON job gets
# an honest "unverifiable from disk, run CronList" caveat instead of a false
# PRESENT/MISSING claim.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# 1. No declaration on disk: header still prints (this is the one thing every
#    session runs), body says so plainly.
out="$("$BIN/ac-standing-jobs.sh")"
assert_contains "$out" "-- standing jobs --" "header always prints"
assert_contains "$out" "records/standing-jobs.md" "names the missing declaration file"

# 2. Both jobs captain.md declares today (drydock, 2026-07-21/22): the
#    cross-fleet monitor ON at :07/:37, the Slack STATUS job OFF since
#    2026-07-22.
cat >"$AC_HOME/records/standing-jobs.md" <<'EOF'
- cross-fleet-monitor [on] cadence::07/:37 recreate:CronCreate a job at :07 and :37 past each hour running the cross-fleet sweep (bin/ac-fleets.sh), queueing findings into drydock's backlog
- slack-status-30min [off] cadence:every 30 minutes recreate:CronCreate a 30-min job posting fleet STATUS to Slack (disabled 2026-07-22 - do not re-create unless TN asks again)
EOF
out="$("$BIN/ac-standing-jobs.sh")"

# ON job: declared state, cadence, verbatim re-create action, and the
# honest disk-unverifiable caveat all appear.
assert_contains "$out" "cross-fleet-monitor: declared ON" "ON job reported"
assert_contains "$out" ":07/:37" "ON job cadence reported"
assert_contains "$out" "CronCreate a job at :07 and :37 past each hour running the cross-fleet sweep (bin/ac-fleets.sh), queueing findings into drydock's backlog" "ON job's exact re-create action reported verbatim"
assert_contains "$out" "unverifiable from disk" "ON job liveness caveat is honest, not a false PRESENT claim"
assert_contains "$out" "run CronList to confirm" "ON job tells the chief how to verify"

# OFF job: reported as OFF, never with the re-create nudge.
off_line="$(printf '%s\n' "$out" | grep '^slack-status-30min:')"
assert_contains "$off_line" "declared OFF" "OFF job reported as declared OFF"
assert_contains "$off_line" "do not re-create" "OFF job explicitly says not to re-create it"
case "$off_line" in
  *"run CronList to confirm"*) fail "an OFF job must never carry the re-create nudge (got: $off_line)" ;;
esac

# 3. A malformed state (neither on nor off) is reported, not silently
#    dropped - a hand-edited declaration is the only author here.
cat >"$AC_HOME/records/standing-jobs.md" <<'EOF'
- broken-job [maybe] cadence:hourly recreate:whatever
EOF
out="$("$BIN/ac-standing-jobs.sh")"
assert_contains "$out" "broken-job" "malformed line still names the job"
assert_contains "$out" "unknown declared state" "malformed state is flagged, not silently dropped"

pass
