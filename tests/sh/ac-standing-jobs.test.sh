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

# --- differential: src/standing-jobs.ts against the frozen bash original -----
# DISPUTED: the implementation (tests/fixtures/ac-standing-jobs.sh under bash vs src/standing-jobs.ts through bin/ac-standing-jobs.sh)
# HELD-CONSTANT: the home, the bytes of records/standing-jobs.md, argv, the environment (SAME_ENV applies to both); stdout, stderr and exit status compared whole
obin="$(make_oracle_bin ac-standing-jobs)"
SAME_ENV=
same() {  # same <args...> - the oracle and the shim answer byte-identically
  local o_rc=0 n_rc=0
  env $SAME_ENV "$obin/ac-standing-jobs.sh" "$@" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  env $SAME_ENV "$BIN/ac-standing-jobs.sh" "$@" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*' ($SAME_ENV)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*' ($SAME_ENV): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*' ($SAME_ENV): $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
}
both() { same; same --ids; }
sj="$AC_HOME/records/standing-jobs.md"
# 1. no file  2. zero-byte file  3. prose and blank lines only
rm -f "$sj"; both
: >"$sj"; both
printf '# Standing jobs\n\nProse [with] brackets\n - indented [x]\n\n- plain\n- x [no close\n' >"$sj"; both
# 4. the four-job fixture of leg 4
cat >"$sj" <<'EOF'
# Standing jobs (fixture)

Prose that must be skipped, even with [brackets] in it.

- alpha-job [on] cadence::07/:37 recreate:CronCreate a job at :07 and :37
- beta-job [off] cadence:every 30 minutes recreate:CronCreate a 30-min job (disabled)
- gamma-job [maybe] cadence:hourly recreate:whatever
- delta-job [on] cadence:30m recreate:CronCreate "*/30 * * * *" -> bin/ac-brain.sh sync --home $AC_HOME --compact
EOF
both
# 5. edge job lines: no id, a bracket id, a TAB in the id, repeated tokens,
#    missing tokens, an empty state, two bracket groups, an empty action
printf '%s\n' '- noSpace[on]' '- [x] weird' "- tabbed${TAB:=$(printf '\t')}id [on] cadence:c recreate:r" \
  '- a [on] cadence:x recreate:y recreate:z' '- b [on] cadence:p cadence:q recreate:r' \
  '- c [on] cadence:only' '- d [off] recreate:r' '- e [] cadence:x recreate:y' \
  '- f [on] [off] cadence:x recreate:y' '- g [on] cadence:x recreate:' >"$sj"
both
# 6. CRLF: the CR lands at the end of the action
printf -- '- a [on] cadence:1 recreate:r1\r\n- b [off] recreate:r2\r\n' >"$sj"; both
# 7. no trailing newline: `read` never delivers an unterminated last line, so
#    the original lost the last job in both modes. That changes a RESULT, not
#    only noise, so the port REPRODUCES it (the wart is a separate slice).
printf -- '- a [on] cadence:1 recreate:r1\n- b [off] recreate:r2' >"$sj"; both
assert_eq "$("$BIN/ac-standing-jobs.sh" --ids)" "a" "an unterminated last line is not a line, as read -r had it"
# 8. a byte that is not valid UTF-8 (\351). Under LC_ALL=C both parse it as a
#    byte, so the differential runs there. Under a UTF-8 locale BSD sed refused
#    the byte (`RE error: illegal byte sequence`) and errexit aborted the
#    original mid-output - an artifact of an outside actor (libc's locale),
#    never a contract; the DECLARED DIVERGENCE: the port parses bytes whatever
#    the locale, prints the whole digest and exits 0.
printf -- '- x [on] cadence:1 recreate:r1\n- caf\351 [on] cadence:x recreate:y\n- z [off] recreate:r3\n' >"$sj"
SAME_ENV=LC_ALL=C both
SAME_ENV=
o_rc=0; LC_ALL=en_US.UTF-8 "$obin/ac-standing-jobs.sh" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; LC_ALL=en_US.UTF-8 "$BIN/ac-standing-jobs.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc" "1" "invalid byte under UTF-8: the original aborted"
assert_contains "$(cat "$TMP/o.err")" "illegal byte sequence" "invalid byte under UTF-8: the original's abort was sed's"
assert_eq "$(wc -l <"$TMP/o.out" | tr -d ' ')" "2" "invalid byte under UTF-8: the original stopped after the first job"
assert_eq "$n_rc" "0" "invalid byte under UTF-8: the port parses the byte and exits 0"
assert_eq "$(cat "$TMP/n.err")" "" "invalid byte under UTF-8: the port has nothing to say on stderr"
LC_ALL=C "$BIN/ac-standing-jobs.sh" >"$TMP/c.out"
cmp -s "$TMP/c.out" "$TMP/n.out" || fail "invalid byte: the port's UTF-8 answer is its LC_ALL=C answer"
assert_eq "$(wc -l <"$TMP/n.out" | tr -d ' ')" "4" "invalid byte under UTF-8: the port prints every job"
# 9. --ids on an unreadable file refuses (the entry's own line, so stderr is
#    compared whole); 10. the digest renders it as a file with no job lines,
#    exit 0 - the original's stderr there was bash's own `line 94: ...
#    Permission denied`, shell-own noise the port does not reproduce, so that
#    row compares stdout and exit and names the stderr divergence. Root reads
#    a mode-000 file, so neither row holds there.
if [ "$(id -u)" -ne 0 ]; then
  printf -- '- a [on] cadence:1 recreate:r1\n' >"$sj"
  chmod 000 "$sj"
  same --ids
  o_rc=0; "$obin/ac-standing-jobs.sh" >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; "$BIN/ac-standing-jobs.sh" >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
  chmod 644 "$sj"
  assert_eq "$n_rc $o_rc" "0 0" "unreadable digest: both exit 0"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "unreadable digest: stdout differs: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  assert_contains "$(cat "$TMP/o.err")" "Permission denied" "unreadable digest: the original's stderr was the shell's redirect error"
  assert_eq "$(cat "$TMP/n.err")" "" "unreadable digest: the port prints no shell-own stderr"
fi
# 11. arguments: only the first is read, so `--ids extra` IS --ids; `-- ids`
#     and `--bogus` are the usage refusal; an empty first argument is the digest
printf -- '- a [on] cadence:1 recreate:r1\n' >"$sj"
same --bogus
same --ids extra
same -- ids
same ''
# 12. no AC_HOME: the digest refuses under its header, --ids refuses bare
SAME_ENV='-u AC_HOME' both
SAME_ENV=
# 13. 2000 valid jobs: the same bytes
: >"$sj"
i=0
while [ "$i" -lt 2000 ]; do
  printf -- '- job-%d [on] cadence:%dm recreate:CronCreate job %d\n' "$i" "$i" "$i" >>"$sj"
  i=$((i + 1))
done
both
rm -f "$sj"

pass
