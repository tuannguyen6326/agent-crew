#!/usr/bin/env bash
# ac-remote-wire.test.sh - integration wiring around the remote-order core:
# the watcher's lock-gated poll slot (fires ONLY for the lock-holding,
# unscoped fleet watcher), the wake-drain push-pending ride-along (only when
# the remote transport is configured), and push-pending itself (one message
# per NEW pending set per family, stamp dedup, thread mapping on first post,
# fail-closed stamp on hook failure).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
STATE="$AC_HOME/state"
CFG="$AC_HOME/config"
PLOG="$TMP/poll-hook.log"
RLOG="$TMP/reply-hook.log"
FEED="$TMP/feed.jsonl"
: >"$PLOG"
: >"$RLOG"
export AC_REMOTE_TEST_PLOG="$PLOG"
export AC_REMOTE_TEST_RLOG="$RLOG"
export AC_REMOTE_TEST_FEED="$FEED"

poll_calls() { wc -l <"$PLOG" | tr -d ' '; }
reply_calls() { grep -c 'BEGIN rid=' "$RLOG" || true; }

# Transport hook fixtures: the poll hook logs each invocation and emits the
# feed; the reply hook logs env + stdin and prints a ts for top-level posts
# (the remote-reply new-thread contract).
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$AC_REMOTE_TEST_PLOG"
cat "$AC_REMOTE_TEST_FEED" 2>/dev/null || true
EOF
chmod +x "$CFG/remote-poll"
printf '{"rid":"rw1","text":"approve greet","author":"TN","thread":"77.11"}\n' >"$FEED"

cat >"$TMP/reply-hook" <<'EOF'
#!/usr/bin/env bash
{ printf 'BEGIN rid=%s thread=%s\n' "${AC_REMOTE_RID:-}" "${AC_REMOTE_THREAD:-}"; cat; printf 'END\n'; } >>"$AC_REMOTE_TEST_RLOG"
if [ -z "${AC_REMOTE_THREAD:-}" ]; then printf '111.222\n'; fi
exit 0
EOF
chmod +x "$TMP/reply-hook"

# --- watcher slot: fires only for the lock-holding unscoped watcher ----------
# Fixture lock: watcher owner == session-lock holder (pure string compare).
printf 'pid=4242\nsince=now\n' >"$STATE/.session-lock"
printf '4242\n' >"$STATE/.watcher-owner"

out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "remote:rw1" "quiet --once pass polls and exits remote:<first-rid>"
assert_eq "$(poll_calls)" "1" "poll hook ran exactly once"
assert_file "$STATE/remote-inbox/rw1.json"
assert_contains "$(cat "$STATE/.wake-spool"/* 2>/dev/null)" "remote-order rw1" \
  "poll published the durable wake (fleet spool) before the watcher exited"

out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "already-stashed rid: quiet pass, no remote reason"
assert_eq "$(poll_calls)" "2" "slot still polls while gated in"

# Foreign lock (owner != holder) -> the slot never runs.
printf 'pid=9999\nsince=now\n' >"$STATE/.session-lock"
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "foreign lock: quiet exit"
assert_eq "$(poll_calls)" "2" "foreign lock: no poll"
printf 'pid=4242\nsince=now\n' >"$STATE/.session-lock"

# Scoped roomchief watcher -> the slot never runs, lock or no lock.
out="$(AC_WATCH_ONLY=greet bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "check:quiet" "scoped watcher: quiet exit"
assert_eq "$(poll_calls)" "2" "AC_WATCH_ONLY: no poll"

# AC_REMOTE_POLL=0 forces the slot off even for the lock holder.
out="$(AC_REMOTE_POLL=0 bash "$BIN/ac-watch.sh" --once)"
assert_eq "$(poll_calls)" "2" "AC_REMOTE_POLL=0: slot off"

# --- wake-drain ride-along: push-pending only when the transport exists ------
rm -rf "$STATE/.wake-spool"
rm -rf "$STATE/.wake-spool"
"$BIN/ac-room.sh" post greet crewchief "GATE: approve the plan" >/dev/null
cp "$TMP/reply-hook" "$CFG/remote-reply"
chmod +x "$CFG/remote-reply"

mv "$CFG/remote-poll" "$TMP/remote-poll.saved"
out="$("$BIN/ac-wake-drain.sh")"
case "$out" in *pushed*) fail "drain must not push without config/remote-poll" ;; esac
[ ! -s "$RLOG" ] || fail "reply hook must not run without config/remote-poll"

mv "$TMP/remote-poll.saved" "$CFG/remote-poll"
out="$("$BIN/ac-wake-drain.sh")"
assert_contains "$out" "pushed greet (1 pending)" "drain rides push-pending along when the transport exists"
assert_eq "$(reply_calls)" "1" "exactly one message went out"
assert_contains "$(cat "$RLOG")" "BEGIN rid=greet thread=" "first post is top-level with rid=<family>"
assert_contains "$(cat "$RLOG")" "GATE: approve the plan" "message carries the pending line"
assert_contains "$(cat "$STATE/remote-threads/greet.thread")" "thread_ts=111.222" "mapping recorded from the hook's printed ts"

# --- push-pending: stamp dedup, threading, fail-closed stamp ------------------
out="$("$BIN/ac-remote.sh" push-pending)"
assert_eq "$out" "" "unchanged pending set: silent, nothing re-sent"
assert_eq "$(reply_calls)" "1" "stamp dedup: no duplicate message"

# A NEW pending item re-pushes the whole compact set, into the recorded thread.
# (The AUTO-mirror is opt-in and this home never opts in, so the room post
# itself sends nothing - only push-pending calls the hook.)
"$BIN/ac-room.sh" post greet crewchief "ASK: choose A or B" >/dev/null
assert_eq "$(reply_calls)" "1" "an un-opted room post never calls the hook"
out="$("$BIN/ac-remote.sh" push-pending)"
assert_contains "$out" "pushed greet (2 pending)" "new pending item triggers one push"
assert_eq "$(reply_calls)" "2" "one push message per new set"
last5="$(tail -n 5 "$RLOG")"
assert_contains "$last5" "thread=111.222" "later pushes reply into the recorded thread"
assert_contains "$last5" "GATE: approve the plan" "compact list carries all pending lines"
assert_contains "$last5" "ASK: choose A or B" "compact list carries the new line"

# A failing reply hook: warned, stamp NOT advanced, retried next push.
"$BIN/ac-room.sh" post other crewchief "GATE: ship it?" >/dev/null
printf '#!/usr/bin/env bash\nexit 3\n' >"$CFG/remote-reply"
chmod +x "$CFG/remote-reply"
out="$("$BIN/ac-remote.sh" push-pending 2>"$TMP/pp.err")" || fail "push-pending must exit 0 on hook failure"
assert_contains "$(cat "$TMP/pp.err")" "WARN" "failing hook is warned"
cp "$TMP/reply-hook" "$CFG/remote-reply"
chmod +x "$CFG/remote-reply"
out="$("$BIN/ac-remote.sh" push-pending)"
assert_contains "$out" "pushed other (1 pending)" "failed family retries on the next push"
assert_contains "$(cat "$STATE/remote-threads/other.thread")" "thread_ts=111.222" "second family gets its own mapping"

# A settled room (pending 0) never pushes, whatever the stamp says.
"$BIN/ac-room.sh" post other crewchief "DECIDED other: ship it" >/dev/null
sent_before="$(reply_calls)"
out="$("$BIN/ac-remote.sh" push-pending)"
assert_eq "$out" "" "pending 0: silent"
assert_eq "$(reply_calls)" "$sent_before" "pending 0: nothing sent"

# No reply hook at all: silent exit 0, even with pending items.
rm -f "$CFG/remote-reply"
"$BIN/ac-room.sh" post third crewchief "GATE: q" >/dev/null
out="$("$BIN/ac-remote.sh" push-pending)"
assert_eq "$out" "" "missing reply hook: silent no-op"

pass
