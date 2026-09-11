#!/usr/bin/env bash
# ac-arrival.test.sh - the shared claude-transcript ARRIVAL primitives
# (ac-lib.sh): ac_arrival_capable (per-harness capability), ac_claude_transcript_path
# (glob-by-session-id resolution, injectable root), ac_claude_last_typed_turn
# (typed-human-turn extraction, tool-result/array content excluded, LAST turn
# wins for --resume), and ac_arrival_wait (the three-state contract these
# compose into: 0 CONFIRMED / 1 REFUTED / 2 UNOBSERVABLE, 2 never collapsed
# into 1 - contract: bin/ac-backend.sh WINDOW LIVENESS). These back both
# bin/ac-spawn.sh's kickoff delivery and bin/ac-send.sh's steer delivery;
# neither script's own suite re-derives this contract, they just exercise it.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
export AC_SEND_SETTLE=0

lib() {
  # lib <body> - run a body with ac-lib.sh sourced, an isolated transcript
  # root pinned via TROOT (set by the caller before invoking this).
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; export AC_CLAUDE_TRANSCRIPT_ROOT=\"\$TROOT\"; $1"
}

TROOT="$(mktemp -d)"
export TROOT
mkdir -p "$TROOT/proj-a"

mk_line() {
  # mk_line <type> <promptSource> <origin-kind> <content-json> - one raw
  # transcript JSONL line, content-json passed through VERBATIM so a caller
  # can hand a quoted string OR an array literal (the array-content shape a
  # tool-result turn actually has).
  printf '{"type":"%s","promptSource":"%s","origin":{"kind":"%s"},"message":{"role":"user","content":%s}}\n' \
    "$1" "$2" "$3" "$4"
}

# --- ac_arrival_capable: per-harness, never a universal law -----------------

assert_eq "$(lib 'ac_arrival_capable claude && echo yes || echo no')" "yes" \
  "claude is capable"
for h in codex opencode pi cursor made-up; do
  assert_eq "$(lib "ac_arrival_capable $h && echo yes || echo no")" "no" \
    "$h has no arrival capability (per-harness, not a universal law)"
done

# --- ac_claude_transcript_path: glob by session id, injectable root --------

sid1="11111111-1111-1111-1111-111111111111"
: >"$TROOT/proj-a/$sid1.jsonl"
assert_eq "$(lib "ac_claude_transcript_path $sid1")" "$TROOT/proj-a/$sid1.jsonl" \
  "exactly one match resolves, found by session id alone (no cwd slug)"

sid2="22222222-2222-2222-2222-222222222222"
err=""
lib "ac_claude_transcript_path $sid2" >/dev/null 2>&1 \
  && fail "an id with no matching file must refuse (rc 1)"

mkdir -p "$TROOT/proj-b"
: >"$TROOT/proj-b/$sid1.jsonl"
lib "ac_claude_transcript_path $sid1" >/dev/null 2>&1 \
  && fail "two matching files for one session id is ambiguous, must refuse"
rm -f "$TROOT/proj-b/$sid1.jsonl"

lib "ac_claude_transcript_path ''" >/dev/null 2>&1 \
  && fail "an empty session id must refuse, never glob the whole root"

# --- ac_claude_last_typed_turn: typed-human only, LAST wins, array-safe -----

sid3="33333333-3333-3333-3333-333333333333"
f3="$TROOT/proj-a/$sid3.jsonl"
{
  mk_line user typed human '"first typed turn"'
  mk_line user "" "" '"<local-command-caveat>ignore me</local-command-caveat>"'
  mk_line assistant "" "" '"an assistant line, never a typed human turn"'
  mk_line user typed human '[{"type":"tool_result","content":"array-shaped, must never false-match"}]'
  mk_line user typed human '"second typed turn - the one a --resume compare must pick"'
} >"$f3"
assert_eq "$(lib "ac_claude_last_typed_turn '$f3'")" "second typed turn - the one a --resume compare must pick" \
  "the LAST typed human turn wins, tool-result array content and non-typed lines excluded"

f4="$TROOT/proj-a/no-typed-turn.jsonl"
{
  mk_line user "" "" '"isMeta caveat, no promptSource"'
  mk_line assistant "" "" '"assistant text"'
} >"$f4"
lib "ac_claude_last_typed_turn '$f4'" >/dev/null 2>&1 \
  && fail "a transcript with no typed human turn must refuse (rc 1), not print empty success"

# --- ac_arrival_wait: the three-state contract, 2 never collapsed into 1 ---

sid5="55555555-5555-5555-5555-555555555555"
f5="$TROOT/proj-a/$sid5.jsonl"
mk_line user typed human '"exact expected text"' >"$f5"
assert_eq "$(lib "rc=0; ac_arrival_wait $sid5 'exact expected text' || rc=\$?; echo \$rc")" "0" \
  "CONFIRMED: the transcript's last typed turn equals the expected text"

sid6="66666666-6666-6666-6666-666666666666"
f6="$TROOT/proj-a/$sid6.jsonl"
mk_line user typed human '"the WRONG text arrived (truncated/garbled)"' >"$f6"
assert_eq "$(lib "rc=0; ac_arrival_wait $sid6 'the text that was actually sent' || rc=\$?; echo \$rc")" "1" \
  "REFUTED: a readable transcript whose last typed turn never matches, through the whole budget"

assert_eq "$(lib "rc=0; ac_arrival_wait '' 'anything' || rc=\$?; echo \$rc")" "2" \
  "UNOBSERVABLE: no session id at all"

# The measured incident this family exists to kill, its own numbers: a
# harness transcript held the TAIL of a ~2900-char kickoff prompt - 722
# characters, beginning mid-sentence - while kickoff_acked reported success.
words="kickoff prompt payload words repeated to build a realistic length "
sent=""
while [ "${#sent}" -lt 2900 ]; do sent="$sent$words"; done
sent="${sent:0:2900}"
arrived="${sent: -722}"
[ "${#sent}" = 2900 ] || fail "fixture bug: sent must be exactly 2900 chars, got ${#sent}"
[ "${#arrived}" = 722 ] || fail "fixture bug: arrived must be exactly 722 chars, got ${#arrived}"
sid9="99999999-9999-9999-9999-999999999999"
f9="$TROOT/proj-a/$sid9.jsonl"
mk_line user typed human "$(printf '%s' "$arrived" | jq -Rs .)" >"$f9"
assert_eq "$(lib "rc=0; ac_arrival_wait $sid9 '$sent' || rc=\$?; echo \$rc")" "1" \
  "REFUTED on the exact measured shape: only the last 722 of a 2900-char send arrived"

sid7="77777777-7777-7777-7777-777777777777"
assert_eq "$(lib "rc=0; ac_arrival_wait $sid7 'anything' || rc=\$?; echo \$rc")" "2" \
  "UNOBSERVABLE: session id has no resolvable transcript file"

sid8="88888888-8888-8888-8888-888888888888"
f8="$TROOT/proj-a/$sid8.jsonl"
mk_line assistant "" "" '"only assistant lines, never a typed human turn"' >"$f8"
assert_eq "$(lib "rc=0; ac_arrival_wait $sid8 'anything' || rc=\$?; echo \$rc")" "2" \
  "UNOBSERVABLE: a readable transcript that produced no typed turn is NOT the same fact as one that produced the wrong one"

pass
