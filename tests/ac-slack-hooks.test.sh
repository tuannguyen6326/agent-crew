#!/usr/bin/env bash
# ac-slack-hooks.test.sh - Slack transport hook pair (docs/examples/slack-remote):
# unconfigured poll is inert while unconfigured reply fails loudly, the bot
# token travels via a curl header file (never argv), only captain-authored
# plain messages are emitted (bots/others/subtypes dropped, oldest first),
# rid/thread shape, channel and per-thread cursor bookkeeping, thread_ts
# propagation on replies, thread registration files, and hostile text
# ($(...), backticks, quotes) arriving byte-identical through jq with no
# shell evaluation.
# shellcheck disable=SC2016  # the hostile text is deliberately unexpanded

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }

make_home

HOOKS="$ROOT/docs/examples/slack-remote"
CFG="$AC_HOME/config"
STATE="$AC_HOME/state"

# Install exactly as README step 5 does.
cp "$HOOKS/remote-poll" "$HOOKS/remote-reply" "$CFG/"
chmod +x "$CFG/remote-poll" "$CFG/remote-reply"

# Logging fake curl: records argv, header files (-H @file), and request
# bodies; answers with canned per-endpoint responses. Real jq stays on PATH.
mkdir -p "$TMP/stub" "$TMP/responses"
export CURL_LOG="$TMP/curl.log"
export CURL_HEADERS="$TMP/curl.headers"
export CURL_BODY="$TMP/curl.body"
export FAKE_RESPONSES="$TMP/responses"
# Per-call sequencing for conversations.replies only (F49: proving a LATER
# thread's failure doesn't lose an EARLIER thread's already-collected cursor
# needs the first call to succeed and the next to fail in the same poll).
# Counts every replies call; a numbered replies.<n>.json overrides the plain
# replies.json for that call only. Untouched by every other test, which never
# creates a numbered file, so this is a no-op everywhere else.
export CURL_REPLIES_SEQ="$TMP/curl.replies-seq"
cat >"$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="" prev="" ofile="" dfile="" wflag=""
for a in "$@"; do
  case "$a" in https://*) url="$a" ;; -w) wflag=1 ;; esac
  case "$prev" in
    -H)
      case "$a" in
        @*) cat "${a#@}" >>"${CURL_HEADERS:?}" ;;
        *) printf '%s\n' "$a" >>"${CURL_HEADERS:?}" ;;
      esac ;;
    --data-binary | --data | -d)
      case "$a" in
        @-) cat >"${CURL_BODY:?}" ;;
        @*) cat "${a#@}" >"${CURL_BODY:?}" ;;
        *) printf '%s' "$a" >"${CURL_BODY:?}" ;;
      esac ;;
    -o) ofile="$a" ;;
    -D) dfile="$a" ;;
  esac
  prev="$a"
done
printf 'ARGS %s\n' "$*" >>"${CURL_LOG:?}"

emit_body() {
  case "$url" in
    *conversations.history*) cat "${FAKE_RESPONSES:?}/history.json" ;;
    *conversations.replies*)
      n="$(( $(cat "${CURL_REPLIES_SEQ:?}" 2>/dev/null || printf 0) + 1 ))"
      printf '%s\n' "$n" >"${CURL_REPLIES_SEQ:?}"
      if [ -f "${FAKE_RESPONSES:?}/replies.$n.json" ]; then
        cat "${FAKE_RESPONSES:?}/replies.$n.json"
      else
        cat "${FAKE_RESPONSES:?}/replies.json"
      fi ;;
    *chat.postMessage*) cat "${FAKE_RESPONSES:?}/post.json" ;;
    *) printf '{"ok":false,"error":"unknown_url"}\n' ;;
  esac
}

# HTTP status + response headers, emulated ONLY when the caller asks for them
# (-D dumps headers, -o redirects the body off stdout, -w prints %{http_code}) -
# so the reply hook, which passes none of these, sees the legacy body-on-stdout.
# FAKE_HTTP_CODE (default 200) picks the status; FAKE_RETRY_AFTER seeds the
# Retry-After header - together they drive the 429-backoff cases below.
code="${FAKE_HTTP_CODE:-200}"
if [ -n "$dfile" ]; then
  { printf 'HTTP/1.1 %s test\r\n' "$code"
    [ -n "${FAKE_RETRY_AFTER:-}" ] && printf 'Retry-After: %s\r\n' "$FAKE_RETRY_AFTER"
    printf '\r\n'
  } >"$dfile"
fi
if [ -n "$ofile" ]; then emit_body >"$ofile"; else emit_body; fi
[ -n "$wflag" ] && printf '%s' "$code"
exit 0
EOF
chmod +x "$TMP/stub/curl"
export PATH="$TMP/stub:$PATH"

run_poll() { (cd "$ROOT" && "$CFG/remote-poll"); }

# Portable mtime setter: BSD `date -r <epoch>` / GNU `date -d @<epoch>` format an
# epoch to `touch -t CCYYMMDDhhmm.SS` (accepted by both), so files are aged
# RELATIVE to the real clock and mtimes round-trip through ac_file_mtime.
touch_at() { # touch_at <file> <epoch>
  local ts
  ts="$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "$1"
}

# Hostile text: command substitution, backticks, both quote kinds, backslash,
# a newline. If ANY shell evaluation happens, the marker file appears.
pwn="$TMP/pwned-marker"
evil='grave `touch MARKER` sub $(touch MARKER) dq " sq '\'' back \ semi ; amp &'
evil="${evil//MARKER/$pwn}"$'\n'"line two"

# --- unconfigured: poll is silently inert, reply fails loudly ------------------
out="$(run_poll)"
assert_eq "$out" "" "unconfigured poll emits nothing"
assert_no_file "$CURL_LOG" "unconfigured poll never calls curl"
assert_no_file "$STATE/.slack-cursor" "unconfigured poll writes no cursor"
if printf 'x' | (cd "$ROOT" && "$CFG/remote-reply") >/dev/null 2>&1; then
  fail "unconfigured reply must exit non-zero"
fi

# --- configure ------------------------------------------------------------------
printf 'SLACK_BOT_TOKEN=xoxb-test-token-123\n' >"$AC_HOME/.env"
printf 'C0AA11\n' >"$CFG/slack-channel"
printf 'UCAPT\n' >"$CFG/slack-captain-id"

# --- history poll: captain filter, order, rid/thread shape, cursor -------------
jq -n --arg evil "$evil" '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700000005.000500",
   subtype: "channel_join", text: "joined"},
  {type: "message", user: "UBOT", bot_id: "B01", ts: "1700000004.000400",
   text: "bot noise"},
  {type: "message", user: "UEVE", ts: "1700000003.000300", text: "not you"},
  {type: "message", user: "UCAPT", ts: "1700000002.000200", text: $evil},
  {type: "message", user: "UCAPT", ts: "1700000001.000100",
   text: "approve greet2"}
]}' >"$FAKE_RESPONSES/history.json"

out="$(run_poll)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "captain messages only"
first="$(printf '%s\n' "$out" | head -n1)"
second="$(printf '%s\n' "$out" | tail -n1)"
assert_eq "$(printf '%s' "$first" | jq -r '.rid')" \
  "sl-C0AA11-1700000001-000100" "rid shape, oldest first"
assert_eq "$(printf '%s' "$first" | jq -r '.author')" "UCAPT" "author field"
assert_eq "$(printf '%s' "$first" | jq -r '.thread')" \
  "1700000001.000100" "top-level thread = own ts"
assert_eq "$(printf '%s' "$second" | jq -r '.text')" "$evil" \
  "hostile text byte-identical through poll"
assert_file "$STATE/.slack-cursor" "cursor persisted"
assert_eq "$(cat "$STATE/.slack-cursor")" "1700000005.000500" \
  "cursor = newest seen ts (even unemitted)"
assert_contains "$(cat "$CURL_LOG")" \
  "conversations.history?channel=C0AA11" "history URL"

# Multi-captain: several member ids in the config (one per line) are ALL
# co-captains; unlisted users stay dropped.
printf 'UCAPT\nUSECOND\n' >"$CFG/slack-captain-id"
rm -f "$STATE/.slack-cursor"
jq -n '{ok: true, messages: [
  {type: "message", user: "UEVE", ts: "1700000012.000200", text: "still not you"},
  {type: "message", user: "USECOND", ts: "1700000011.000100", text: "approve as co-captain"}
]}' >"$FAKE_RESPONSES/history.json"
out="$(run_poll)"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1" "only listed co-captain emitted"
assert_eq "$(printf '%s' "$out" | jq -r '.author')" "USECOND" "co-captain author recorded"
printf 'UCAPT\n' >"$CFG/slack-captain-id"
rm -f "$STATE/.slack-cursor"
jq -n --arg evil "$evil" '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700000005.000500",
   subtype: "channel_join", text: "joined"},
  {type: "message", user: "UBOT", bot_id: "B01", ts: "1700000004.000400",
   text: "bot noise"},
  {type: "message", user: "UEVE", ts: "1700000003.000300", text: "not you"},
  {type: "message", user: "UCAPT", ts: "1700000002.000200", text: $evil},
  {type: "message", user: "UCAPT", ts: "1700000001.000100",
   text: "approve greet2"}
]}' >"$FAKE_RESPONSES/history.json"
run_poll >/dev/null

# Token must never ride argv; it must arrive via the -H @file header file.
if grep -q 'xoxb-test-token-123' "$CURL_LOG"; then
  fail "token leaked into curl argv"
fi
assert_contains "$(cat "$CURL_HEADERS")" \
  "Authorization: Bearer xoxb-test-token-123" "token via header file"

# --- second poll resumes from the cursor ----------------------------------------
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
out="$(run_poll)"
assert_eq "$out" "" "empty history emits nothing"
assert_contains "$(cat "$CURL_LOG")" "oldest=1700000005.000500" \
  "second poll passes the cursor as oldest"
assert_eq "$(cat "$STATE/.slack-cursor")" "1700000005.000500" \
  "empty poll leaves the cursor alone"

# --- threaded reply: thread_ts propagation + thread registration ----------------
printf '{"ok":true,"ts":"1700000010.000100"}\n' >"$FAKE_RESPONSES/post.json"
rid="sl-C0AA11-1700000002-000200"
out="$(printf '%s' "$evil" | (cd "$ROOT" \
  && AC_REMOTE_THREAD="1700000002.000200" AC_REMOTE_RID="$rid" \
    "$CFG/remote-reply"))"
assert_eq "$out" "" "threaded reply prints nothing"
assert_eq "$(jq -r '.channel' "$CURL_BODY")" "C0AA11" "reply channel"
assert_eq "$(jq -r '.thread_ts' "$CURL_BODY")" "1700000002.000200" \
  "thread_ts propagated into the payload"
assert_eq "$(jq -r '.text' "$CURL_BODY")" "$evil" \
  "hostile text byte-identical in the posted payload"
tf="$STATE/remote-threads/$rid.thread"
assert_file "$tf" "thread registration created"
assert_contains "$(cat "$tf")" "thread_ts=1700000002.000200" "thread root recorded"
assert_contains "$(cat "$tf")" "cursor=1700000002.000200" "cursor starts at root"

# --- thread poll: replies cursor, root exclusion, thread attribution ------------
evil2='thread answer `approve` $(approve) "ok"'
jq -n --arg evil "$evil2" '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700000002.000200",
   thread_ts: "1700000002.000200", text: "the root, already seen"},
  {type: "message", user: "UBOT", bot_id: "B01", ts: "1700000010.000100",
   thread_ts: "1700000002.000200", text: "our own gate ask"},
  {type: "message", user: "UCAPT", ts: "1700000012.000300",
   thread_ts: "1700000002.000200", text: $evil}
]}' >"$FAKE_RESPONSES/replies.json"

out="$(run_poll)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" \
  "thread poll emits only the captain reply (root and bot dropped)"
assert_eq "$(printf '%s' "$out" | jq -r '.rid')" \
  "sl-C0AA11-1700000012-000300" "thread reply rid"
assert_eq "$(printf '%s' "$out" | jq -r '.thread')" "1700000002.000200" \
  "reply attributed to its thread"
assert_eq "$(printf '%s' "$out" | jq -r '.text')" "$evil2" \
  "hostile text byte-identical through thread poll"
assert_contains "$(cat "$CURL_LOG")" \
  "conversations.replies?channel=C0AA11&ts=1700000002.000200" "replies URL"
assert_contains "$(cat "$CURL_LOG")" "oldest=1700000002.000200" \
  "thread poll passes the per-thread cursor"
assert_contains "$(cat "$tf")" "cursor=1700000012.000300" \
  "per-thread cursor advanced in the .thread file"

# --- top-level reply: new ts printed, registration seeded -----------------------
rid2="sl-new-order"
out="$(printf 'gate is yours, captain' | (cd "$ROOT" \
  && AC_REMOTE_RID="$rid2" "$CFG/remote-reply"))"
assert_eq "$out" "1700000010.000100" "top-level reply prints the new ts"
if jq -e 'has("thread_ts")' "$CURL_BODY" >/dev/null; then
  fail "top-level reply must not carry thread_ts"
fi
tf2="$STATE/remote-threads/$rid2.thread"
assert_file "$tf2" "top-level reply registers its new thread"
assert_contains "$(cat "$tf2")" "thread_ts=1700000010.000100" "new thread root"
assert_contains "$(cat "$tf2")" "cursor=1700000010.000100" \
  "new thread cursor = own first message"

# --- mention: AC_REMOTE_MENTION=captain prepends every captain id ----------------
printf 'U0AA\nU0BB\n' >"$CFG/slack-captain-id"
printf '{"ok":true,"ts":"1700000020.000100"}\n' >"$FAKE_RESPONSES/post.json"
printf 'GATE: cần captain approve' | (cd "$ROOT" \
  && AC_REMOTE_MENTION=captain AC_REMOTE_RID="sl-mention-test" "$CFG/remote-reply") >/dev/null
assert_eq "$(jq -r '.text' "$CURL_BODY")" "<@U0AA> <@U0BB> GATE: cần captain approve" \
  "mention prepends <@id> per captain id, text verbatim after"
printf 'DECIDED: quiet receipt' | (cd "$ROOT" \
  && AC_REMOTE_RID="sl-mention-test2" "$CFG/remote-reply") >/dev/null
assert_eq "$(jq -r '.text' "$CURL_BODY")" "DECIDED: quiet receipt" \
  "no mention env, no ping"
rm -f "$STATE/remote-threads/sl-mention-test.thread" "$STATE/remote-threads/sl-mention-test2.thread"

# --- stale thread registration: dropped loudly, poll survives -------------------
# A .thread file whose thread no longer exists in the configured channel
# (deleted message, or a channel switch left it behind) must not wedge the
# whole poll: thread_not_found drops THAT registration and the poll still
# exits 0; every other API error stays fatal (live incident 2026-07-18:
# a leftover registration blocked every drydock poll after the channel
# switch).
printf 'thread_ts=1700009999.000999\n' >"$STATE/remote-threads/stale-fam.thread"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
printf '{"ok":false,"error":"thread_not_found"}\n' >"$FAKE_RESPONSES/replies.json"
err="$(run_poll 2>&1 >/dev/null)" || fail "thread_not_found must not fail the poll"
assert_contains "$err" "dropping stale registration stale-fam.thread" "the drop is loud"
assert_no_file "$STATE/remote-threads/stale-fam.thread" "stale registration removed"
printf '{"ok":false,"error":"missing_scope"}\n' >"$FAKE_RESPONSES/replies.json"
printf 'thread_ts=1700009999.000999\n' >"$STATE/remote-threads/stale-fam.thread"
run_poll >/dev/null 2>&1 && fail "a non-thread_not_found replies error must stay fatal"
assert_file "$STATE/remote-threads/stale-fam.thread" "other errors never drop the registration"
rm -f "$STATE/remote-threads/stale-fam.thread"

# --- F49: a failed later thread must not lose an order this run already saw ----
# remote-poll used to persist the history cursor right after emitting the
# order lines, before the registered-threads loop - so a later curl/API
# failure took the poll down under set -euo pipefail while the cursor had
# already moved past the order, and cmd_poll discards a failed run's stdout
# unread. Both cursor classes (history + per-thread) must now stay pending
# until this whole run reaches exit 0.
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"
printf 'UCAPT\n' >"$CFG/slack-captain-id"

# Case 1: history returns a captain order, one registered thread whose
# replies call fails -> the poll must fail, the history cursor must NOT
# advance, and the same order must be re-emitted on the next successful poll.
jq -n '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700006001.000001", text: "order one"}
]}' >"$FAKE_RESPONSES/history.json"
printf 'thread_ts=1700005999.000000\ncursor=1700005999.000000\n' \
  >"$STATE/remote-threads/sl-f49-a.thread"
printf '{"ok":false,"error":"internal_error"}\n' >"$FAKE_RESPONSES/replies.json"
err="$(run_poll 2>&1 >/dev/null)" && fail "F49: a non-thread_not_found replies failure must fail the poll"
assert_contains "$err" "conversations.replies" "F49: the failure is reported"
assert_no_file "$STATE/.slack-cursor" \
  "F49: the history cursor must not become durable when a later thread fails"

printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/replies.json"
out="$(run_poll)"
assert_eq "$(printf '%s\n' "$out" | jq -r '.rid')" "sl-C0AA11-1700006001-000001" \
  "F49: the order lost to the failed poll is re-emitted on the next successful one"
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"

# Case 2: two registered threads, the first succeeding and a later one
# failing -> the FIRST thread's own cursor must not advance either, since
# both cursor classes are collected during the run and committed together,
# never per-thread as the write happens. Relies on plain lexical glob order
# (aaa before zzz) to make "aaa" the thread the loop visits first.
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
printf 'thread_ts=1700007001.000001\ncursor=1700007001.000001\n' \
  >"$STATE/remote-threads/sl-f49-aaa.thread"
printf 'thread_ts=1700007002.000002\ncursor=1700007002.000002\n' \
  >"$STATE/remote-threads/sl-f49-zzz.thread"
rm -f "$CURL_REPLIES_SEQ"
jq -n '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700007005.000005",
   thread_ts: "1700007001.000001", text: "reply in aaa"}
]}' >"$FAKE_RESPONSES/replies.1.json"
printf '{"ok":false,"error":"internal_error"}\n' >"$FAKE_RESPONSES/replies.2.json"
run_poll >/dev/null 2>&1 && fail "F49: a later thread's failure must fail the poll"
assert_contains "$(cat "$STATE/remote-threads/sl-f49-aaa.thread")" "cursor=1700007001.000001" \
  "F49: the first (successful) thread's cursor must not advance when a later thread fails"
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor" "$CURL_REPLIES_SEQ" \
  "$FAKE_RESPONSES/replies.1.json" "$FAKE_RESPONSES/replies.2.json"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/replies.json"
printf 'U0AA\nU0BB\n' >"$CFG/slack-captain-id"

# --- F50: a quiet thread's cursor must not regress to the thread root -----------
# newest_ts is a max over EVERY message in a replies response, including the
# thread root - so a quiet thread (nothing but the root comes back) used to
# regress the cursor back to the root every poll, rewriting the file and
# refreshing mtime, defeating the roomless-GC predicate above ("mtime ...
# tracks the last captain activity"). The cursor now advances only on a
# strictly newer ts; a quiet thread must write nothing at all.
get_mtime() {
  local m
  m="$(stat -f %m "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[![:digit:]]*) m="$(stat -c %Y "$1" 2>/dev/null)" ;; esac
  printf '%s' "$m"
}
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
qf="$STATE/remote-threads/sl-f50-quiet.thread"
printf 'thread_ts=1700008001.000001\ncursor=1700008005.000005\n' >"$qf"
touch_at "$qf" "$(($(date +%s) - 100))"
before_content="$(cat "$qf")"
before_mtime="$(get_mtime "$qf")"
jq -n '{ok: true, messages: [
  {type: "message", user: "UCAPT", ts: "1700008001.000001",
   thread_ts: "1700008001.000001", text: "the root, already seen"}
]}' >"$FAKE_RESPONSES/replies.json"
run_poll >/dev/null
assert_eq "$(cat "$qf")" "$before_content" \
  "F50: a quiet thread (only the root comes back) leaves the cursor unchanged"
assert_eq "$(get_mtime "$qf")" "$before_mtime" \
  "F50: a quiet thread's .thread file is not rewritten (mtime preserved)"
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/replies.json"

# --- closed-room GC: a landed family's thread leaves the poll set ---------------
# A .thread keyed by a FAMILY rid whose room.md is CLOSED must be SKIPPED (no
# conversations.replies call) while its file survives for a possible reopen;
# a live family (open room) and a roomless order thread stay polled. This keeps
# the per-poll replies count tracking LIVE families instead of every thread
# ever registered (the ratelimit incident 2026-07-19).
rm -f "$STATE/remote-threads"/*.thread
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/replies.json"

# fam-closed: family room built by the REAL writer, then closed by ac-room.sh
# close - so the predicate is proved against the exact CLOSED: line it appends.
printf 'thread_ts=1700000200.000002\n' >"$STATE/remote-threads/fam-closed.thread"
"$BIN/ac-room.sh" post fam-closed crewchief 'TRIAGE: flow=direct' >/dev/null
"$BIN/ac-room.sh" close fam-closed landed >/dev/null
# fam-live: an OPEN family room (last entry is not CLOSED).
printf 'thread_ts=1700000100.000001\n' >"$STATE/remote-threads/fam-live.thread"
"$BIN/ac-room.sh" post fam-live crewchief 'GATE: needs captain' >/dev/null
# sl-order-xyz: a roomless order rid - no room.md, must pass straight through.
printf 'thread_ts=1700000300.000003\n' >"$STATE/remote-threads/sl-order-xyz.thread"

: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700000100.000001" "live family (open room) still polled"
assert_contains "$log" "ts=1700000300.000003" "roomless order thread still polled"
case "$log" in
  *"ts=1700000200.000002"*) fail "closed-room family must not be polled" ;;
esac
assert_file "$STATE/remote-threads/fam-closed.thread" \
  "closed-room .thread kept on disk (reply-binding history for a reopen)"

# Reopen: a fresh post AFTER the CLOSED: line re-enters the family - no explicit
# reopen verb, "CLOSED is the last entry" is the whole predicate.
"$BIN/ac-room.sh" post fam-closed crewchief 'work resumes' >/dev/null
: >"$CURL_LOG"
run_poll >/dev/null
assert_contains "$(cat "$CURL_LOG")" "ts=1700000200.000002" \
  "a reopened room (post after CLOSED) is polled again"
rm -f "$STATE/remote-threads"/*.thread

# --- family lifecycle: a TERMINAL backlog line inactivates like CLOSED does ----
# defect (1): a family that LANDED but whose room was never closed used to be
# polled forever. A family is now also INACTIVE when its backlog line is a
# terminal Done entry (including [failed]/[abandoned]) - checked against BOTH
# records/backlog.md and records/backlog-archive.md (ac-curate.sh moves older
# Done lines into the archive), matching the rid EXACTLY (no prefix collision).
mkdir -p "$AC_HOME/records"
export AC_REMOTE_POLL_MAX_AGE=100000

# fam-open-noterm: OPEN room, no terminal backlog line anywhere -> still polled.
printf 'thread_ts=1700005001.000001\n' >"$STATE/remote-threads/fam-open-noterm.thread"
"$BIN/ac-room.sh" post fam-open-noterm crewchief 'GATE: needs captain' >/dev/null
# fam-open-term: OPEN room BUT a terminal line in backlog.md -> NOT polled.
printf 'thread_ts=1700005002.000002\n' >"$STATE/remote-threads/fam-open-term.thread"
"$BIN/ac-room.sh" post fam-open-term crewchief 'GATE: needs captain' >/dev/null
# fam-archived: OPEN room BUT its terminal line lives ONLY in the archive -> also NOT polled.
printf 'thread_ts=1700005003.000003\n' >"$STATE/remote-threads/fam-archived.thread"
"$BIN/ac-room.sh" post fam-archived crewchief 'GATE: needs captain' >/dev/null
# fam-open-term-bar: rid PREFIX-COLLIDES with the terminal id fam-open-term -
# must NOT be silenced by fam-open-term's own terminal line.
printf 'thread_ts=1700005004.000004\n' >"$STATE/remote-threads/fam-open-term-bar.thread"
"$BIN/ac-room.sh" post fam-open-term-bar crewchief 'GATE: needs captain' >/dev/null

printf '## In flight\n\n## Queued\n\n## Done\n- [x] fam-open-term - shipped it (merged 2026-07-01)\n' \
  >"$AC_HOME/records/backlog.md"
printf '## Done\n- [x] fam-archived [failed] - abandoned old work (2026-06-01)\n' \
  >"$AC_HOME/records/backlog-archive.md"
NOW="$(date +%s)"
touch_at "$STATE/remote-threads/fam-open-term.thread" "$((NOW - 10))"      # fresh, still inactive
touch_at "$STATE/remote-threads/fam-archived.thread" "$((NOW - 10))"      # fresh, still inactive

: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700005001.000001" \
  "open room, no terminal backlog line: still polled"
case "$log" in
  *"ts=1700005002.000002"*) fail "open room but TERMINAL backlog.md line must not be polled" ;;
esac
case "$log" in
  *"ts=1700005003.000003"*) fail "open room but TERMINAL backlog-archive.md-only line must not be polled" ;;
esac
assert_contains "$log" "ts=1700005004.000004" \
  "rid prefix collision: fam-open-term-bar is not silenced by fam-open-term's terminal line"
assert_file "$STATE/remote-threads/fam-open-term.thread" \
  "inactive family (fresh mtime) kept on disk, just not polled"
assert_file "$STATE/remote-threads/fam-archived.thread" \
  "inactive archived family (fresh mtime) kept on disk, just not polled"

# Aged GC: an inactive family older than AC_REMOTE_POLL_MAX_AGE is deleted;
# one still within the window survives even though it is equally inactive.
touch_at "$STATE/remote-threads/fam-open-term.thread" "$((NOW - 200000))" # aged past the window
: >"$CURL_LOG"
run_poll >/dev/null
assert_no_file "$STATE/remote-threads/fam-open-term.thread" \
  "inactive family aged past AC_REMOTE_POLL_MAX_AGE is GC'd"
assert_file "$STATE/remote-threads/fam-archived.thread" \
  "inactive family within the age window is kept, just not polled"

# Reopen: a family CLOSED, landed (Done line migrated to the archive), and
# later REOPENED - a fresh OPEN backlog.md line (spawn moves it back to In
# flight, AGENTS.md section 9) - must win over the archived Done line. Without
# this, a reopened family whose Done line already reached the archive would
# stay terminal (unpolled) forever, since a chief can never move it back out.
printf 'thread_ts=1700005006.000006\n' >"$STATE/remote-threads/fam-reopened.thread"
"$BIN/ac-room.sh" post fam-reopened crewchief 'GATE: needs captain' >/dev/null
printf '## In flight\n- [ ] fam-reopened - resumed work (repo: agent-crew, since 2026-07-22)\n\n## Queued\n\n## Done\n' \
  >"$AC_HOME/records/backlog.md"
printf '## Done\n- [x] fam-reopened - shipped it (merged 2026-06-01)\n' \
  >"$AC_HOME/records/backlog-archive.md"
: >"$CURL_LOG"
run_poll >/dev/null
assert_contains "$(cat "$CURL_LOG")" "ts=1700005006.000006" \
  "reopened family (archived Done line + open backlog.md line) is still polled"

unset AC_REMOTE_POLL_MAX_AGE
rm -f "$AC_HOME/records/backlog.md" "$AC_HOME/records/backlog-archive.md" \
  "$STATE/remote-threads"/*.thread

# --- roomless-thread cap + aged GC (ratelimit incident 2026-07-19) --------------
# The roomless sl-<channel>-<ts> order threads (no room.md) are never pruned, so
# their per-poll conversations.replies calls grew without bound. Cap polling to
# the newest N by mtime and GC the aged tail; family threads stay OUT of scope
# (their CLOSED-room skip above is unchanged).
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/replies.json"

# Newest-N cap: N+2 roomless threads with distinct mtimes, all within the age
# window (GC out of play). Only the newest N poll; the 2 oldest are skipped but
# survive (within-window). Newest = largest mtime (i=1 is freshest).
export AC_REMOTE_POLL_CAP=3
export AC_REMOTE_POLL_MAX_AGE=100000
NOW="$(date +%s)"
for i in 1 2 3 4 5; do
  printf 'thread_ts=17000010%02d.0000%02d\n' "$i" "$i" \
    >"$STATE/remote-threads/sl-cap-$i.thread"
  touch_at "$STATE/remote-threads/sl-cap-$i.thread" "$((NOW - i * 10))"
done
: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700001001.000001" "cap: newest roomless polled"
assert_contains "$log" "ts=1700001002.000002" "cap: 2nd roomless polled"
assert_contains "$log" "ts=1700001003.000003" "cap: Nth roomless polled"
case "$log" in *"ts=1700001004.000004"*) fail "cap: beyond-N roomless must not poll (4)" ;; esac
case "$log" in *"ts=1700001005.000005"*) fail "cap: beyond-N roomless must not poll (5)" ;; esac
assert_file "$STATE/remote-threads/sl-cap-4.thread" "cap: within-window skip keeps the file"
assert_file "$STATE/remote-threads/sl-cap-5.thread" "cap: within-window skip keeps the file"

# Aged GC: beyond-cap + older than the window is DELETED; beyond-cap + within
# window survives; the newest N are kept regardless.
rm -f "$STATE/remote-threads"/*.thread
export AC_REMOTE_POLL_CAP=1
export AC_REMOTE_POLL_MAX_AGE=3600
NOW="$(date +%s)"
printf 'thread_ts=1700002001.000001\n' >"$STATE/remote-threads/sl-gc-fresh.thread"
touch_at "$STATE/remote-threads/sl-gc-fresh.thread" "$((NOW - 10))"       # rank1 (in cap)
printf 'thread_ts=1700002002.000002\n' >"$STATE/remote-threads/sl-gc-recent.thread"
touch_at "$STATE/remote-threads/sl-gc-recent.thread" "$((NOW - 100))"     # rank2, within window
printf 'thread_ts=1700002003.000003\n' >"$STATE/remote-threads/sl-gc-aged.thread"
touch_at "$STATE/remote-threads/sl-gc-aged.thread" "$((NOW - 100000))"    # rank3, aged out
: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700002001.000001" "gc: newest-N roomless polled"
case "$log" in *"ts=1700002002.000002"*) fail "gc: beyond-cap recent must not poll" ;; esac
case "$log" in *"ts=1700002003.000003"*) fail "gc: beyond-cap aged must not poll" ;; esac
assert_file "$STATE/remote-threads/sl-gc-fresh.thread" "gc: newest-N kept"
assert_file "$STATE/remote-threads/sl-gc-recent.thread" "gc: within-window skip survives"
assert_no_file "$STATE/remote-threads/sl-gc-aged.thread" "gc: aged beyond-cap thread deleted"

# Newest-N survive regardless of age: two aged roomless threads, cap covers both
# -> both polled AND kept even though each is older than the window.
rm -f "$STATE/remote-threads"/*.thread
export AC_REMOTE_POLL_CAP=2
export AC_REMOTE_POLL_MAX_AGE=3600
NOW="$(date +%s)"
printf 'thread_ts=1700003001.000001\n' >"$STATE/remote-threads/sl-old-a.thread"
touch_at "$STATE/remote-threads/sl-old-a.thread" "$((NOW - 100000))"
printf 'thread_ts=1700003002.000002\n' >"$STATE/remote-threads/sl-old-b.thread"
touch_at "$STATE/remote-threads/sl-old-b.thread" "$((NOW - 200000))"
: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700003001.000001" "cap>age: aged newest-N polled (a)"
assert_contains "$log" "ts=1700003002.000002" "cap>age: aged newest-N polled (b)"
assert_file "$STATE/remote-threads/sl-old-a.thread" "cap>age: newest-N kept despite age (a)"
assert_file "$STATE/remote-threads/sl-old-b.thread" "cap>age: newest-N kept despite age (b)"

# Family threads are OUT of the cap/GC scope: an OPEN family room is always
# polled even when it is older than every roomless thread and the cap is 1.
rm -f "$STATE/remote-threads"/*.thread
export AC_REMOTE_POLL_CAP=1
export AC_REMOTE_POLL_MAX_AGE=3600
NOW="$(date +%s)"
printf 'thread_ts=1700004001.000001\n' >"$STATE/remote-threads/fam-open-2.thread"
"$BIN/ac-room.sh" post fam-open-2 crewchief 'GATE: needs captain' >/dev/null
touch_at "$STATE/remote-threads/fam-open-2.thread" "$((NOW - 100000))"    # aged, but a family
printf 'thread_ts=1700004002.000002\n' >"$STATE/remote-threads/sl-fresh-2.thread"
touch_at "$STATE/remote-threads/sl-fresh-2.thread" "$((NOW - 10))"        # newest roomless (in cap)
: >"$CURL_LOG"
run_poll >/dev/null
log="$(cat "$CURL_LOG")"
assert_contains "$log" "ts=1700004001.000001" "family thread polled regardless of cap/age"
assert_file "$STATE/remote-threads/fam-open-2.thread" "family thread never GC'd by age"

# --- 429 backoff: a ratelimit backs off instead of failing the poll -------------
# A 429 records state/.slack-backoff (now + Retry-After, capped) and ENDS the
# poll gracefully (exit 0, never ac_die); while the marker is in the future the
# next poll makes NO API call; once it expires polling resumes.
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-backoff" "$STATE/.slack-cursor"
unset AC_REMOTE_POLL_CAP AC_REMOTE_POLL_MAX_AGE
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"

export FAKE_HTTP_CODE=429 FAKE_RETRY_AFTER=30
: >"$CURL_LOG"
NOW="$(date +%s)"
run_poll >/dev/null 2>&1 || fail "429 must not fail the poll (exit 0 expected)"
assert_file "$STATE/.slack-backoff" "429 writes the backoff marker"
deadline="$(cat "$STATE/.slack-backoff")"
[ "$deadline" -gt "$NOW" ] || fail "429: backoff marker must be in the future"
[ "$deadline" -le "$((NOW + 300))" ] || fail "429: backoff must be capped"

unset FAKE_HTTP_CODE FAKE_RETRY_AFTER
: >"$CURL_LOG"
run_poll >/dev/null 2>&1
assert_eq "$(cat "$CURL_LOG")" "" "backoff window: poll makes no API call"

printf '%s\n' "$(($(date +%s) - 5))" >"$STATE/.slack-backoff"
: >"$CURL_LOG"
run_poll >/dev/null 2>&1
assert_contains "$(cat "$CURL_LOG")" "conversations.history" "expired backoff: polling resumes"
rm -f "$STATE/.slack-backoff" "$STATE/remote-threads"/*.thread

# --- cwd-independent ac-lib.sh resolution (remote-reply-cwd-resolution) --------
# Every call above conveniently runs with cwd=$ROOT (run_poll cd's there, and
# the direct-invocation cases up top do too) - exactly the coincidence that
# hid this bug: a home hook has no fixed relative path back to the distro and
# cannot rely on the caller's cwd. Prove resolution from a cwd with NO
# relation to $ROOT, via BOTH real invocation paths: via bin/ac-remote.sh
# (what the fleet watcher's poll loop actually runs) FIRST - it self-heals
# state/.ac-root on every call, exactly like a home with a live watcher
# already has it seeded with no manual bootstrap - then the hook run directly
# (the captain's standing manual recipe, only AC_HOME in env), relying on
# that same self-healed pointer.
ELSEWHERE="$TMP/elsewhere"
mkdir -p "$ELSEWHERE"
cp "$HOOKS/remote-ack" "$CFG/remote-ack"
chmod +x "$CFG/remote-ack"
assert_no_file "$STATE/.ac-root" "no distro-root pointer before any ac-remote.sh run yet"

# via bin/ac-remote.sh: the hook subprocess must resolve even though its
# parent (the watcher's poll loop) runs from an unrelated cwd too - this call
# also self-heals state/.ac-root (the mechanism under test) and its
# ingest_stream fires the remote-ack hook (LIFECYCLE-ACK `ingested`), so one
# run proves all three hooks at once.
jq -n '{ok:true, messages: [{type:"message", user:"U0AA",
  ts:"1700000091.000001", text:"cwd via ac-remote.sh"}]}' \
  >"$FAKE_RESPONSES/history.json"
rm -f "$STATE/.slack-cursor"
: >"$CURL_LOG"
out="$(cd "$ELSEWHERE" && "$BIN/ac-remote.sh" poll 2>"$TMP/poll.err")"
assert_contains "$out" "remote-order sl-C0AA11-1700000091-000001" \
  "cwd-independent via ac-remote.sh: poll ingests from elsewhere"
assert_contains "$(cat "$CURL_LOG")" "conversations.history" \
  "cwd-independent via ac-remote.sh: the poll hook subprocess resolved ac-lib.sh"
case "$(cat "$TMP/poll.err")" in
  *"ac-lib.sh not found"*) fail "cwd-independent via ac-remote.sh: a hook lost ac-lib.sh from elsewhere" ;;
esac
assert_contains "$(cat "$STATE/.ac-root" 2>/dev/null)" "$ROOT" \
  "ac-remote.sh self-healed the state/.ac-root pointer to the distro root"
rm -f "$STATE/.slack-cursor" "$STATE/remote-threads"/*.thread

# direct: remote-poll, cwd unrelated to $ROOT, only AC_HOME in the recipe -
# must reach the Slack API instead of failing with "ac-lib.sh not found",
# relying solely on the pointer the ac-remote.sh call above just seeded.
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
: >"$CURL_LOG"
out="$(cd "$ELSEWHERE" && "$CFG/remote-poll")"
assert_eq "$out" "" "cwd-independent direct poll: clean run from elsewhere"
assert_contains "$(cat "$CURL_LOG")" "conversations.history" \
  "cwd-independent direct poll: ac-lib.sh resolved (API reached) from elsewhere"

# direct: remote-reply from elsewhere.
printf '{"ok":true,"ts":"1700000090.000001"}\n' >"$FAKE_RESPONSES/post.json"
out="$(cd "$ELSEWHERE" && printf 'cwd-independent reply' \
  | AC_REMOTE_RID="sl-cwd-direct" "$CFG/remote-reply")"
assert_eq "$out" "1700000090.000001" \
  "cwd-independent direct reply: posts and prints the new ts from elsewhere"
rm -f "$STATE/remote-threads/sl-cwd-direct.thread"

# direct: remote-ack from elsewhere must never choke on ac-lib.sh (stderr must
# not carry the not-found error; config is already set up so this is a real,
# successful reaction call).
err="$(cd "$ELSEWHERE" && AC_REMOTE_RID="sl-C0AA11-1700000090-000001" \
  AC_REMOTE_ACK_STATE=ingested "$CFG/remote-ack" 2>&1 >/dev/null)" || true
case "$err" in
  *"ac-lib.sh not found"*) fail "cwd-independent direct ack: lost ac-lib.sh from elsewhere" ;;
esac

# --- control-channel post registers a readable thread ---------------------------
# records/captain.md's prescribed done-report/BLOCKED/STUCK invocation
# (`printf '<msg>' | AC_HOME=... bash config/remote-reply`) sets NEITHER
# AC_REMOTE_RID NOR AC_REMOTE_THREAD - every ac-remote.sh path (reply,
# family_send) always sets AC_REMOTE_RID, so this bare top-level post is the
# ONLY caller shape that reaches here with both empty. Before the fix such a
# post registered no thread file at all, so a captain reply landing under it
# was never picked up by ANY poll path - conversations.history returns only
# top-level messages (remote-poll header) and conversations.replies is only
# called for a registered $STATE/remote-threads/<rid>.thread.
rm -f "$STATE/remote-threads"/*.thread
printf '{"ok":true,"ts":"1700000095.000001"}\n' >"$FAKE_RESPONSES/post.json"
out="$(printf 'landed: crew/foo merged' | (cd "$ROOT" && "$CFG/remote-reply"))"
assert_eq "$out" "1700000095.000001" \
  "control-channel post still prints the new ts (existing contract unchanged)"
ctlrid="sl-C0AA11-1700000095-000001"
ctlfile="$STATE/remote-threads/$ctlrid.thread"
assert_file "$ctlfile" \
  "a bare top-level post (no rid, no thread) now registers its own thread"
assert_contains "$(cat "$ctlfile")" "thread_ts=1700000095.000001" \
  "registered thread root is the post's own ts"
assert_contains "$(cat "$ctlfile")" "cursor=1700000095.000001" \
  "registered cursor starts at the post's own ts"
assert_no_file "$AC_HOME/data/$ctlrid/room.md" \
  "the generated id never collides with a real family rid (sl- prefix, roomless)"

# The registration must be READABLE: the next poll's registered-threads loop
# must call conversations.replies for it (roomless threads are polled, not
# skipped as an inactive family) and surface a captain reply posted under it.
jq -n '{ok: true, messages: [
  {type: "message", user: "U0AA", ts: "1700000095.000001",
   thread_ts: "1700000095.000001", text: "the root, already seen"},
  {type: "message", user: "U0AA", ts: "1700000096.000001",
   thread_ts: "1700000095.000001", text: "ack, well done"}
]}' >"$FAKE_RESPONSES/replies.json"
printf '{"ok":true,"messages":[]}\n' >"$FAKE_RESPONSES/history.json"
rm -f "$STATE/.slack-cursor"
: >"$CURL_LOG"
out="$(run_poll)"
assert_contains "$(cat "$CURL_LOG")" \
  "conversations.replies?channel=C0AA11&ts=1700000095.000001" \
  "the done-report thread is polled for replies (previously never registered, so never polled)"
assert_eq "$(printf '%s\n' "$out" | jq -r '.rid')" \
  "sl-C0AA11-1700000096-000001" "the captain's reply under the done-report surfaces as an order"
assert_eq "$(printf '%s' "$out" | jq -r '.thread')" "1700000095.000001" \
  "the reply is attributed to the done-report thread"
rm -f "$STATE/remote-threads"/*.thread "$STATE/.slack-cursor"

# --- no shell evaluation anywhere ------------------------------------------------
assert_no_file "$pwn" "hostile text was never shell-evaluated"

pass
