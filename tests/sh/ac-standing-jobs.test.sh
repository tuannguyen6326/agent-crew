#!/usr/bin/env bash
# ac-standing-jobs.test.sh - the session-start standing-jobs digest block:
# reports each DECLARED job's state from records/standing-jobs.md, with the
# exact re-create action, and never claims a declared-OFF job needs one.
# CronCreate is session-only (no on-disk liveness signal), so an ON job gets
# an honest "unverifiable from disk, run CronList" caveat instead of a false
# PRESENT/MISSING claim.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# 1. No declaration on disk: header still prints (this is the one thing every
#    session runs), body says so plainly.
out="$("$BIN/ac-standing-jobs.sh")"
assert_contains "$out" "-- standing jobs --" "header always prints"
assert_contains "$out" "records/standing-jobs.md" "names the missing declaration file"

# 2. Two jobs as a fleet's captain.md declares them: the
#    cross-fleet monitor ON at :07/:37, the Slack STATUS job OFF with
#    a dated disable note.
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

# 4. --ids: the id list, for the ONE other reader of this grammar
#    (bin/ac-rig.sh's standing_jobs class). It exists so the grammar keeps
#    exactly one parser in the file AGENTS.md section 2 names as its owner -
#    the ac-pool-health.sh -> `ac-tree.sh list` shape, where the consumer
#    never re-derives what the owner already parses.
cat >"$AC_HOME/records/standing-jobs.md" <<'EOF'
# Standing jobs (fixture)

Prose that must be skipped, even with [brackets] in it.

- alpha-job [on] cadence::07/:37 recreate:CronCreate a job at :07 and :37
- beta-job [off] cadence:every 30 minutes recreate:CronCreate a 30-min job (disabled)
- gamma-job [maybe] cadence:hourly recreate:whatever
- delta-job [on] cadence:30m recreate:CronCreate "*/30 * * * *" -> bin/ac-brain.sh sync --home $AC_HOME --compact
EOF
ids="$("$BIN/ac-standing-jobs.sh" --ids)"
assert_eq "$ids" "alpha-job
beta-job
gamma-job
delta-job" "--ids prints every declared id in file order, prose lines skipped"

# A malformed STATE is still a declared job - --ids reports the id and leaves
# the grading to the digest, which already has a branch for it.
assert_contains "$ids" "gamma-job" "a job with an unknown state still has an id"

# --- 5. THE EXTRACTION CHANGED NOTHING THE DIGEST PRINTS ---------------------
# The id parser now has one caller more than it did; this pins the whole
# rendered block byte-for-byte against the output captured BEFORE the
# extraction, so a refactor can never quietly reword the digest.
want='-- standing jobs --
alpha-job: declared ON (cadence: :07/:37) - runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing: CronCreate a job at :07 and :37
beta-job: declared OFF - do not re-create (CronCreate a 30-min job (disabled))
gamma-job: unknown declared state [maybe] in records/standing-jobs.md - fix the line
delta-job: declared ON (cadence: 30m) - runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing: CronCreate "*/30 * * * *" -> bin/ac-brain.sh sync --home $AC_HOME --compact'
assert_eq "$("$BIN/ac-standing-jobs.sh")" "$want" "the rendered digest block is byte-identical to the pre-extraction output"

# 6. --ids on a home with no declaration: empty, exit 0 - the caller decides
#    what an empty set means, and a missing file is not this verb's error.
rm -f "$AC_HOME/records/standing-jobs.md"
assert_eq "$("$BIN/ac-standing-jobs.sh" --ids)" "" "--ids is empty with no declaration on disk"
"$BIN/ac-standing-jobs.sh" --ids >/dev/null || fail "--ids exits 0 with no declaration on disk"

# --- the CLI contract, byte for byte ------------------------------------------
run() {  # run <args...> - one call under RUN_ENV; sets rc, out, err
  rc=0
  out="$(env $RUN_ENV "$BIN/ac-standing-jobs.sh" "$@" 2>"$TMP/err")" || rc=$?
  err="$(cat "$TMP/err")"
}
RUN_ENV=
hdr="-- standing jobs --"
on_tail="runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing:"
usage="ERROR: usage: ac-standing-jobs.sh [--ids]"
sj="$AC_HOME/records/standing-jobs.md"
# a zero-byte file is no declaration; prose and blank lines are no job lines
: >"$sj"
run; assert_eq "$rc|$out|$err" "0|$hdr
(no standing-jobs declaration - records/standing-jobs.md)|" "a zero-byte file is no declaration"
run --ids; assert_eq "$rc|$out|$err" "0||" "--ids over a zero-byte file is empty"
printf '# Standing jobs\n\nProse [with] brackets\n - indented [x]\n\n- plain\n- x [no close\n' >"$sj"
run; assert_eq "$rc|$out|$err" "0|$hdr
(records/standing-jobs.md has no declared job lines)|" "a file with no job line says so"
run --ids; assert_eq "$rc|$out|$err" "0||" "--ids over a file with no job line is empty"
# edge job lines: no id (counted, never printed), a bracket id, a TAB in the
# id, repeated tokens, missing tokens, an empty state, two bracket groups, an
# empty action
TAB="$(printf '\t')"
SP=" "
printf '%s\n' '- noSpace[on]' '- [x] weird' "- tabbed${TAB}id [on] cadence:c recreate:r" \
  '- a [on] cadence:x recreate:y recreate:z' '- b [on] cadence:p cadence:q recreate:r' \
  '- c [on] cadence:only' '- d [off] recreate:r' '- e [] cadence:x recreate:y' \
  '- f [on] [off] cadence:x recreate:y' '- g [on] cadence:x recreate:' >"$sj"
run; assert_eq "$rc|$out|$err" "0|$hdr
[x]: unknown declared state [x] in records/standing-jobs.md - fix the line
tabbed${TAB}id: declared ON (cadence: c) - $on_tail r
a: declared ON (cadence: x recreate:y) - $on_tail z
b: declared ON (cadence: q) - $on_tail r
c: declared ON (cadence: ) - $on_tail$SP
d: declared OFF - do not re-create (r)
e: unknown declared state [] in records/standing-jobs.md - fix the line
f: declared ON (cadence: x) - $on_tail y
g: declared ON (cadence: x) - $on_tail |" "the digest over the edge lines"
run --ids; assert_eq "$rc|$out|$err" "0|[x]
tabbed${TAB}id
a
b
c
d
e
f
g|" "--ids over the edge lines"
# CRLF: the CR lands at the end of the action
printf -- '- a [on] cadence:1 recreate:r1\r\n- b [off] recreate:r2\r\n' >"$sj"
run; assert_eq "$rc|$out|$err" "0|$(printf '%s\na: declared ON (cadence: 1) - %s r1\r\nb: declared OFF - do not re-create (r2\r)' "$hdr" "$on_tail")|" "a CR stays inside the last field"
run --ids; assert_eq "$out" "a
b" "--ids is untouched by CRLF"
# a byte that is not valid UTF-8 (\351) is parsed as a byte whatever the locale
printf -- '- x [on] cadence:1 recreate:r1\n- caf\351 [on] cadence:x recreate:y\n- z [off] recreate:r3\n' >"$sj"
for loc in C en_US.UTF-8; do
  RUN_ENV="LC_ALL=$loc"
  run; assert_eq "$rc|$out|$err" "0|$(printf '%s\nx: declared ON (cadence: 1) - %s r1\ncaf\351: declared ON (cadence: x) - %s y\nz: declared OFF - do not re-create (r3)' "$hdr" "$on_tail" "$on_tail")|" "an invalid byte under $loc is carried through the digest"
  run --ids; assert_eq "$rc|$out|$err" "0|$(printf 'x\ncaf\351\nz')|" "an invalid byte under $loc is carried through --ids"
done
RUN_ENV=
# an unreadable file: --ids refuses, the digest renders it as a file with no
# job lines. Root reads a mode-000 file, so neither row holds there.
if [ "$(id -u)" -ne 0 ]; then
  printf -- '- a [on] cadence:1 recreate:r1\n' >"$sj"
  chmod 000 "$sj"
  run --ids; assert_eq "$rc|$out|$err" "1||ERROR: records/standing-jobs.md is not readable - refusing to report an empty id set" "--ids refuses an unreadable file"
  run; chmod 644 "$sj"
  assert_eq "$rc|$out|$err" "0|$hdr
(records/standing-jobs.md has no declared job lines)|" "the digest over an unreadable file is silent on stderr"
fi
# arguments: only the first is read, so `--ids extra` IS --ids; `-- ids` and
# `--bogus` are the usage refusal; an empty first argument is the digest
printf -- '- a [on] cadence:1 recreate:r1\n' >"$sj"
run --bogus; assert_eq "$rc|$out|$err" "1||$usage" "an unknown flag is the usage refusal"
run --ids extra; assert_eq "$rc|$out|$err" "0|a|" "a second argument is not read"
run -- ids; assert_eq "$rc|$out|$err" "1||$usage" "-- is not an option terminator"
run ''; assert_eq "$rc|$out|$err" "0|$hdr
a: declared ON (cadence: 1) - $on_tail r1|" "an empty first argument is the digest"
# no AC_HOME: the digest refuses under its header, --ids refuses bare
RUN_ENV='-u AC_HOME'
run; assert_eq "$rc|$out" "1|$hdr" "a homeless digest refuses under its header"
assert_contains "$err" "ERROR: AC_HOME is not set" "the homeless digest's refusal"
run --ids; assert_eq "$rc|$out" "1|" "a homeless --ids refuses bare"
assert_contains "$err" "ERROR: AC_HOME is not set" "the homeless --ids refusal"
RUN_ENV=
# 2000 valid jobs: every one rendered, in order
: >"$sj"
i=0
while [ "$i" -lt 2000 ]; do
  printf -- '- job-%d [on] cadence:%dm recreate:CronCreate job %d\n' "$i" "$i" "$i" >>"$sj"
  i=$((i + 1))
done
run; assert_eq "$rc|$(printf '%s\n' "$out" | wc -l | tr -d ' ')|$(printf '%s\n' "$out" | tail -n 1)" \
  "0|2001|job-1999: declared ON (cadence: 1999m) - $on_tail CronCreate job 1999" "2000 jobs: the digest renders each"
run --ids; assert_eq "$rc|$(printf '%s\n' "$out" | wc -l | tr -d ' ')|$(printf '%s\n' "$out" | tail -n 1)" "0|2000|job-1999" "2000 jobs: --ids lists each"
rm -f "$sj"

pass
