#!/usr/bin/env bash
# ac-remote.test.sh - transport-agnostic remote-order core: poll no-op gate,
# stash+wake dedup (exactly-once per rid), rid slug-guard, ingest (the stdin
# push-gateway entrance sharing poll's per-line core - stash+wake+dedup with
# no poll hook, dedup across BOTH entrances, garbage tolerated), reply via
# env+stdin only, link/followup round-trip (live and archive meta), gc, and
# the untrusted-text contract ($(...) and backticks stay inert bytes end to end).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
STATE="$AC_HOME/state"
INBOX="$STATE/remote-inbox"

fleet_wakes() {
  # The fleet spool's records, concatenated ('' when none): ingest_stream
  # publishes one record per file (ac_wake_publish, hard-wired fleet), so
  # wake asserts read the spool.
  cat "$STATE/.wake-spool"/* 2>/dev/null || true
}
CFG="$AC_HOME/config"
FEED="$TMP/feed.jsonl"
RLOG="$TMP/reply.log"
export AC_REMOTE_TEST_FEED="$FEED"
export AC_REMOTE_TEST_LOG="$RLOG"

# --- poll: HARD no-op without an executable hook -----------------------------
out="$("$BIN/ac-remote.sh" poll)"
assert_eq "$out" "" "poll without hook prints nothing"

cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
cat "$AC_REMOTE_TEST_FEED"
EOF
out="$("$BIN/ac-remote.sh" poll)"                    # present but NOT executable
assert_eq "$out" "" "poll with non-executable hook prints nothing"
chmod +x "$CFG/remote-poll"

# --- poll: new order stashed + wake queued exactly once ----------------------
# The text carries $(...) and backticks aimed at side-effect files; they must
# survive as inert bytes (the printf format is single-quoted - the test shell
# never expands them either).
# shellcheck disable=SC2016  # non-expansion is the point: the text must stay inert
printf '{"rid":"r1","text":"approve widget $(touch %s/pwned-poll) `touch %s/pwned-poll2`","author":"TN","thread":"1712.42"}\n' \
  "$TMP" "$TMP" >"$FEED"
out="$("$BIN/ac-remote.sh" poll)"
assert_contains "$out" "remote-order r1" "poll prints one line per new order"
assert_file "$INBOX/r1.json"
# shellcheck disable=SC2016  # asserting the literal bytes, not expanding them
grep -qF 'approve widget $(touch' "$INBOX/r1.json" || fail "dollar-paren text must survive verbatim into the stash"
grep -qF '`touch' "$INBOX/r1.json" || fail "backtick text must survive verbatim into the stash"
assert_no_file "$TMP/pwned-poll"
assert_no_file "$TMP/pwned-poll2"
fleet_wakes | grep -qE "^[0-9]+	remote	captain	remote-order r1$" \
  || fail "wake record must be queue_wake TSV shape: now<TAB>remote<TAB>captain<TAB>remote-order r1"

# A remote order is the captain SPEAKING, not waiting - they already get the
# ac-remote reply as confirmation. A captain ruling ("block boi captain")
# moved the notification off this arrival entirely: only a room GATE:/ASK:
# pending on the captain (bin/ac-room.sh's cmd_post) rings ac-notify.sh now.
notify_log="$TMP/notify-remote.log"
notify_hook="$TMP/notify-remote-hook.sh"
cat >"$notify_hook" <<EOF2
#!/usr/bin/env bash
printf '%s|%s\n' "\$AC_NOTIFY_TITLE" "\$AC_NOTIFY_MESSAGE" >>"$notify_log"
EOF2
chmod +x "$notify_hook"
printf 'command:%s\n' "$notify_hook" >"$CFG/wedge-alarm"
: >"$notify_log"
printf '{"rid":"rnotify","text":"a second order","author":"TN","thread":"1712.43"}\n' >"$FEED"
out="$("$BIN/ac-remote.sh" poll)"
assert_contains "$out" "remote-order rnotify" "poll still ingests with wedge-alarm wired to a command hook"
assert_eq "$(wc -l <"$notify_log" | tr -d ' ')" "0" \
  "a remote-order arrival no longer notifies (captain speaking, not waiting)"
printf 'off\n' >"$CFG/wedge-alarm"
rm -f "$notify_log" "$notify_hook"
# shellcheck disable=SC2016  # non-expansion is the point: the text must stay inert
printf '{"rid":"r1","text":"approve widget $(touch %s/pwned-poll) `touch %s/pwned-poll2`","author":"TN","thread":"1712.42"}\n' \
  "$TMP" "$TMP" >"$FEED"

out="$("$BIN/ac-remote.sh" poll)"                    # re-poll, same rid
assert_eq "$out" "" "re-poll with a stashed rid prints nothing"
assert_eq "$(fleet_wakes | grep -c "remote-order r1")" "1" "no duplicate wake on re-poll"

# --- lifecycle-ack hook: ingested/working/done edges, never on re-poll,
# --- failure never blocks ------------------------------------------------------
ALOG="$TMP/ack.log"
export AC_REMOTE_TEST_ACK="$ALOG"
cat >"$CFG/remote-ack" <<'EOF'
#!/usr/bin/env bash
printf '%s %s %s\n' "$AC_REMOTE_ACK_STATE" "$AC_REMOTE_RID" "$AC_REMOTE_THREAD" >>"$AC_REMOTE_TEST_ACK"
EOF
chmod +x "$CFG/remote-ack"
printf '{"rid":"rack","text":"approve","author":"TN","thread":"1712.99"}\n' >"$FEED"
out="$("$BIN/ac-remote.sh" poll)"
assert_contains "$out" "remote-order rack" "order with an ack hook still ingests"
assert_eq "$(cat "$ALOG")" "ingested rack 1712.99" "ingest edge acked with state+rid+thread in env"
out="$("$BIN/ac-remote.sh" poll)"
assert_eq "$(grep -c ' rack ' "$ALOG")" "1" "a stashed rid is never re-acked"
"$BIN/ac-remote.sh" link tack rack >/dev/null
assert_eq "$(tail -n1 "$ALOG")" "working rack 1712.99" "link fires the working edge"
cat >"$CFG/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
chmod +x "$CFG/remote-reply"
printf 'answer\n' | "$BIN/ac-remote.sh" followup tack >/dev/null
assert_eq "$(tail -n1 "$ALOG")" "done rack 1712.99" "a delivered followup fires the done edge"
printf 'again\n' | "$BIN/ac-remote.sh" followup tack >/dev/null 2>&1
assert_eq "$(grep -c '^done ' "$ALOG")" "1" "a cleared link never re-fires done"
rm -f "$CFG/remote-reply" "$STATE/tack.meta"
# Inline-handled orders: the explicit `ack` verb fires an edge by hand
# (reply never infers one); bad states and unstashed rids are refused.
out="$("$BIN/ac-remote.sh" ack rack "done")"
assert_contains "$out" "acked rack (done)" "explicit ack fires for an inline-handled order"
assert_eq "$(tail -n1 "$ALOG")" "done rack 1712.99" "the done edge reached the hook with the thread"
assert_fails "$BIN/ac-remote.sh" ack rack bogus-state
assert_fails "$BIN/ac-remote.sh" ack never-stashed "done"
printf '#!/usr/bin/env bash\nexit 1\n' >"$CFG/remote-ack"
chmod +x "$CFG/remote-ack"
printf '{"rid":"rackfail","text":"x","author":"TN","thread":"1712.100"}\n' >"$FEED"
err="$("$BIN/ac-remote.sh" poll 2>&1)"
assert_contains "$err" "remote-order rackfail" "a failing ack hook never blocks ingest"
assert_contains "$err" "remote-ack hook failed" "the ack failure is warned"
assert_file "$INBOX/rackfail.json" "the failed-ack order is stashed anyway"
rm -f "$CFG/remote-ack"

# --- poll hook stdin: closed regardless of what the caller's own stdin holds --
# The poll hook's runtime contract is stdout+stderr, no stdin - a hook that
# reads stdin anyway must see EOF, never bytes the caller happened to be
# piping into `ac-remote.sh poll` for some unrelated reason.
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
if read -r line; then
  printf 'GOT:%s\n' "$line" >&2
else
  printf 'STDIN-EOF\n' >&2
fi
EOF
chmod +x "$CFG/remote-poll"
err="$(printf 'leaked-caller-stdin\n' | "$BIN/ac-remote.sh" poll 2>&1 1>/dev/null)"
assert_contains "$err" "STDIN-EOF" "poll hook sees EOF, never the caller's inherited stdin"
case "$err" in *GOT:*) fail "poll hook must never read bytes off the caller's own stdin" ;; esac
# Restore the feed-reading hook the rest of the suite depends on.
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
cat "$AC_REMOTE_TEST_FEED"
EOF
chmod +x "$CFG/remote-poll"

# --- lifecycle-ack hook: bounded per call, capped per round -------------------
# A dead ack hook must never turn one ingest batch into N x the hook's own
# hang, and the accumulated warn must fire once for the round, not once per
# skipped rid. `run_ack`'s own header states the contract it must now honour
# in full: best-effort, never blocks the caller - including the "never" part.
HANGLOG="$TMP/ack-hang-calls.log"
export AC_REMOTE_TEST_HANGLOG="$HANGLOG"

# One hung call: bounded at AC_REMOTE_ACK_TIMEOUT, the order still lands, the
# hook's OWN stderr still reaches the operator (unchanged contract), and
# nothing from bash's own job-control machinery leaks onto that same channel
# (measured risk: a non-interactive bash under `set -m` announces a
# signal-killed job on the real stderr the instant it notices, independent of
# any redirect on the reaping `wait` itself).
cat >"$CFG/remote-ack" <<'EOF'
#!/usr/bin/env bash
printf 'own hook stderr\n' >&2
sleep 30
EOF
chmod +x "$CFG/remote-ack"
: >"$HANGLOG"
printf '{"rid":"rhang","text":"x","author":"TN","thread":"1712.200"}\n' >"$FEED"
# AC_REMOTE_ACK_TIMEOUT=2, not 1: $SECONDS is whole-second granularity, so a
# 1s bound leaves no headroom against a `start` sample taken near a second
# boundary - measured flaky (the reap can fire before the hook's own first
# line ever runs). 2s leaves enough margin to stay deterministic while still
# running fast (HOST RULE: hard-cap every bound, leave headroom).
poll_start=$SECONDS
err="$(AC_REMOTE_ACK_TIMEOUT=2 AC_REMOTE_ACK_BUDGET=30 "$BIN/ac-remote.sh" poll 2>&1 1>/dev/null)"
poll_elapsed=$((SECONDS - poll_start))
[ "$poll_elapsed" -lt 6 ] || fail "a hung ack hook must be reaped near AC_REMOTE_ACK_TIMEOUT, not left to run (took ${poll_elapsed}s)"
assert_file "$INBOX/rhang.json" "a hung ack never blocks the order it acks from landing"
assert_contains "$err" "own hook stderr" "the hook's own stderr still reaches the operator (unchanged contract)"
assert_contains "$err" "remote-ack hook timed out after 2s" "the timeout is warned with its bound named"
case "$err" in *[Tt]erminated*) fail "bash's own job-control notice must never reach the warn channel" ;; esac
case "$err" in *'[1]'*) fail "bash's own job-control job-number line must never reach the warn channel" ;; esac
rm -f "$CFG/remote-ack"

# A batch that would cost N x the per-call timeout is capped at the per-round
# budget instead: enough new rids that N x AC_REMOTE_ACK_TIMEOUT would blow
# past AC_REMOTE_ACK_BUDGET, and the round still returns near the budget with
# the later acks skipped (never attempted - the hook is never even called for
# them) and EXACTLY ONE exhaustion warning, not one per skipped rid. Every rid
# still lands: the stash and its wake are committed before run_ack is ever
# reached, so a skipped ack costs a transport receipt, never an order.
cat >"$CFG/remote-ack" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$AC_REMOTE_RID" >>"$AC_REMOTE_TEST_HANGLOG"
sleep 30
EOF
chmod +x "$CFG/remote-ack"
: >"$HANGLOG"
{
  printf '{"rid":"rb1","text":"x","author":"TN","thread":"t"}\n'
  printf '{"rid":"rb2","text":"x","author":"TN","thread":"t"}\n'
  printf '{"rid":"rb3","text":"x","author":"TN","thread":"t"}\n'
  printf '{"rid":"rb4","text":"x","author":"TN","thread":"t"}\n'
  printf '{"rid":"rb5","text":"x","author":"TN","thread":"t"}\n'
} >"$FEED"
# Same headroom reasoning as above: 2s per call, 2s round budget - one call
# is affordable, the other four are not.
batch_start=$SECONDS
out="$(AC_REMOTE_ACK_TIMEOUT=2 AC_REMOTE_ACK_BUDGET=2 "$BIN/ac-remote.sh" poll 2>"$TMP/ack-budget.err")"
batch_elapsed=$((SECONDS - batch_start))
[ "$batch_elapsed" -lt 6 ] || fail "5 rids at 2s/call must not cost 10s once the 2s round budget is spent (took ${batch_elapsed}s)"
for r in rb1 rb2 rb3 rb4 rb5; do
  assert_contains "$out" "remote-order $r" "batch member $r still ingests once its ack is out of budget"
  assert_file "$INBOX/$r.json" "batch member $r is stashed regardless of its ack outcome"
done
assert_eq "$(wc -l <"$HANGLOG" | tr -d ' ')" "1" \
  "only the calls the budget could afford ever invoke the hook - the rest are skipped, not attempted"
assert_eq "$(grep -c 'budget.*spent this round' "$TMP/ack-budget.err")" "1" \
  "budget exhaustion is warned exactly once for the whole round, never once per skipped rid"
case "$(cat "$TMP/ack-budget.err")" in *[Tt]erminated*) fail "bash's own job-control notice must never reach the warn channel" ;; esac
rm -f "$CFG/remote-ack"

# The per-call timeout must be CLAMPED to what is left of the round budget,
# not just checked against it before starting: a call let through at
# spent=0 could otherwise run its own full nominal timeout and push the
# total past the budget by up to that whole timeout (a budget smaller than
# the nominal per-call timeout - AC_REMOTE_ACK_BUDGET=2 <
# AC_REMOTE_ACK_TIMEOUT=5 here - makes this concrete: the call must be cut
# at 2s, not 5s).
cat >"$CFG/remote-ack" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$CFG/remote-ack"
printf '{"rid":"rclamp","text":"x","author":"TN","thread":"t"}\n' >"$FEED"
clamp_start=$SECONDS
err="$(AC_REMOTE_ACK_TIMEOUT=5 AC_REMOTE_ACK_BUDGET=2 "$BIN/ac-remote.sh" poll 2>&1 1>/dev/null)"
clamp_elapsed=$((SECONDS - clamp_start))
[ "$clamp_elapsed" -lt 4 ] || fail "a call must be clamped to the remaining 2s budget, not run its full 5s nominal timeout (took ${clamp_elapsed}s)"
assert_contains "$err" "remote-ack hook timed out after 2s" "the warned bound is the clamped remainder, not the nominal per-call ceiling"
rm -f "$CFG/remote-ack"

# --- thread-post: the family-thread mirror verb --------------------------------
# A successful thread-post must print exactly one confirmation line naming
# the family, carrying the message ts when the hook printed one (LIVED
# 2026-07-25 twice in one day: a caller re-ran thread-post purely to read its
# exit code, duplicating a captain-facing message, because success and
# no-op were both totally silent).
TLOG="$TMP/tpost.log"
export AC_REMOTE_TEST_TLOG="$TLOG"
out="$(printf 'hello thread\n' | "$BIN/ac-remote.sh" thread-post famx 2>"$TMP/tp-nohook.err")"
assert_eq "$out" "" "no hook: no delivered confirmation on stdout"
assert_contains "$(cat "$TMP/tp-nohook.err")" "WARN" "no hook: a warning says nothing was delivered"
assert_no_file "$STATE/remote-threads/famx.thread" "no hook: silent no-op, no registration"
# The fixture matches the real remote-reply contract (docs/examples/slack-remote/
# remote-reply): a ts is printed ONLY for a top-level post (AC_REMOTE_THREAD
# empty) - a reply into an already-known thread prints nothing.
cat >"$CFG/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >>"$AC_REMOTE_TEST_TLOG"
printf 'rid=%s thread=%s\n' "$AC_REMOTE_RID" "$AC_REMOTE_THREAD" >>"$AC_REMOTE_TEST_TLOG"
if [ -z "$AC_REMOTE_THREAD" ]; then printf '1700.42\n'; fi
EOF
chmod +x "$CFG/remote-reply"
out="$(printf 'first post\n' | "$BIN/ac-remote.sh" thread-post famx)"
assert_contains "$(cat "$TLOG")" "first post" "text reached the hook on stdin"
grep -qx 'rid=famx thread=' "$TLOG" || fail "first post goes top-level (empty thread)"
assert_contains "$(cat "$STATE/remote-threads/famx.thread")" "thread_ts=1700.42" "thread registered from the printed ts"
assert_eq "$out" "posted famx (1700.42)" "first post's confirmation carries the ts"
out="$(printf 'second post\n' | "$BIN/ac-remote.sh" thread-post famx)"
assert_contains "$(cat "$TLOG")" "rid=famx thread=1700.42" "second post lands in the registered thread"
assert_eq "$out" "posted famx" "second post's confirmation omits the ts (hook printed none for an already-known thread)"
cat >"$CFG/remote-reply" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'mention=%s\n' "${AC_REMOTE_MENTION:-}" >>"$AC_REMOTE_TEST_TLOG"
EOF
chmod +x "$CFG/remote-reply"
out="$(printf 'cần approve\n' | "$BIN/ac-remote.sh" thread-post famx --mention-captain)"
assert_contains "$(cat "$TLOG")" "mention=captain" "--mention-captain rides to the hook env"
assert_eq "$out" "posted famx" "confirmation omits the ts when the hook prints none"
# The verb is the chief's OWN posting tool: config/remote-mirror gates only
# the AUTO-mirror callers (ac-room/ac-spawn), never a deliberate thread-post.
printf 'off\n' >"$CFG/remote-mirror"
: >"$TLOG"
printf 'deliberate\n' | "$BIN/ac-remote.sh" thread-post famx
[ -s "$TLOG" ] || fail "a deliberate thread-post must reach the hook whatever the mirror switch says"
rm -f "$CFG/remote-mirror"
printf '#!/usr/bin/env bash\nexit 1\n' >"$CFG/remote-reply"
chmod +x "$CFG/remote-reply"
out="$(printf 'x\n' | "$BIN/ac-remote.sh" thread-post famx 2>/dev/null)" \
  && fail "a failing reply hook must be a hard thread-post error"
assert_eq "$out" "" "a failing hook must not print a delivered confirmation"
rm -f "$CFG/remote-reply"

# --- done-stamp: the landing-receipt stamp (PART 2a) ---------------------------
# The chief calls this right after it posts a family's landing done-report so
# the turn-end guard's landing-receipt check stays silent for the family. A
# pure LOCAL stamp (family -> marker in state/.landing-receipt-stamp, the
# .remote-push-stamp single-file/per-family-key shape) - no transport hook
# needed, so the stamp lands even when Slack is down.
assert_no_file "$STATE/.landing-receipt-stamp" "no stamp before the first done-stamp"
out="$("$BIN/ac-remote.sh" done-stamp famz)"
assert_contains "$out" "done-stamped famz" "done-stamp reports the family"
grep -qE '^famz=[0-9]+$' "$STATE/.landing-receipt-stamp" || fail "done-stamp records famz=<epoch>"
# Per-family: stamping a second family keeps the first.
"$BIN/ac-remote.sh" done-stamp famw >/dev/null
grep -qE '^famz=' "$STATE/.landing-receipt-stamp" || fail "a second family's stamp keeps the first"
grep -qE '^famw=' "$STATE/.landing-receipt-stamp" || fail "the second family is stamped too"
# The family name is slug-guarded (no path traversal), and required.
assert_fails "$BIN/ac-remote.sh" done-stamp ../evil
assert_fails "$BIN/ac-remote.sh" done-stamp

# A remote order is addressed to the CAPTAIN's crewchief, so like a hand-back
# it is filed on the FLEET queue, never under a family - the single poller is
# the fleet watcher (ac-watch.sh gates the slot on an unscoped watcher that
# holds the home lock), and only the fleet chief drains what it queues.
# Both entrances are pinned under a scope, so the pins are load-bearing: they
# fail if anyone ever routes ingest_stream's write to a scoped spool.
printf '{"rid":"rscoped","text":"approve gizmo","author":"TN","thread":"1712.43"}\n' >"$FEED"
out="$(AC_SCOPE=fam1 "$BIN/ac-remote.sh" poll)"
assert_contains "$out" "remote-order rscoped" "a scoped poll still queues the order"
fleet_wakes | grep -qE "^[0-9]+	remote	captain	remote-order rscoped$" \
  || fail "a remote-order wake must reach the FLEET spool even when polled from a scoped session"
assert_no_file "$STATE/.wake-spool.fam1" "a remote-order wake is never filed under a family scope"

# ... and the same for the INGEST entrance, which is the one the Slack
# gateway drives (it queues no wake itself - its chief nudge is a UI latency
# shave, the durable wake is this write).
printf '{"rid":"iscoped","text":"approve widget","author":"TN","thread":"1712.44"}\n' \
  | AC_SCOPE=fam1 "$BIN/ac-remote.sh" ingest >/dev/null
fleet_wakes | grep -qE "^[0-9]+	remote	captain	remote-order iscoped$" \
  || fail "an ingested order must reach the FLEET spool even from a scoped session"
assert_no_file "$STATE/.wake-spool.fam1" "an ingested wake is never filed under a family scope"

# --- poll: slug-guard and malformed lines are skipped, valid ones still land -
{
  printf '{"rid":"../evil","text":"x","author":"TN","thread":"1.2"}\n'
  printf 'not json at all\n'
  printf '{"rid":"r-nokeys"}\n'
  printf '{"rid":"r2","text":"second order","author":"TN","thread":"999.111"}\n'
} >"$FEED"
out="$("$BIN/ac-remote.sh" poll 2>"$TMP/poll.err")"
assert_contains "$out" "remote-order r2" "valid order after refused lines still lands"
case "$out" in *evil*) fail "refused rid must not print an order line" ;; esac
assert_no_file "$STATE/evil.json"
[ -z "$(find "$INBOX" -name '*evil*')" ] || fail "refused rid must never name an inbox file"
case "$(fleet_wakes)" in *evil*) fail "refused rid must never queue a wake" ;; esac
assert_no_file "$INBOX/r-nokeys.json"
assert_contains "$(cat "$TMP/poll.err")" "WARN" "guard refusals are warned, not fatal"

# --- poll: hook failure = warn + exit 0, nothing processed -------------------
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
echo '{"rid":"r-fail","text":"t","author":"a","thread":"1"}'
exit 7
EOF
chmod +x "$CFG/remote-poll"
out="$("$BIN/ac-remote.sh" poll 2>"$TMP/pollfail.err")" || fail "poll must exit 0 on hook failure"
assert_eq "$out" "" "failed hook: no orders processed"
assert_contains "$(cat "$TMP/pollfail.err")" "WARN" "failed hook is warned"
assert_no_file "$INBOX/r-fail.json"

# --- poll: hook failure with stderr - the WHY reaches the warn ---------------
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect to slack.com port 443" >&2
exit 1
EOF
chmod +x "$CFG/remote-poll"
out="$("$BIN/ac-remote.sh" poll 2>"$TMP/pollstderr.err")" || fail "poll must exit 0 on hook failure"
assert_eq "$out" "" "failed hook: no orders processed"
grep -qE '^WARN: remote-poll hook failed \(exit 1\).*curl: \(7\) Failed to connect to slack\.com port 443' \
  "$TMP/pollstderr.err" \
  || fail "the hook's stderr must reach the WARN line: $(cat "$TMP/pollstderr.err")"

# --- poll: hook failure with EMPTY stderr still reads sensibly ---------------
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$CFG/remote-poll"
out="$("$BIN/ac-remote.sh" poll 2>"$TMP/pollempty.err")" || fail "poll must exit 0 on hook failure"
assert_eq "$out" "" "failed hook: no orders processed"
grep -qxF 'WARN: remote-poll hook failed (exit 1) - skipping this poll' "$TMP/pollempty.err" \
  || fail "empty stderr: warn must read sensibly, no dangling colon: $(cat "$TMP/pollempty.err")"

# --- poll: hook stderr on a SUCCESSFUL run still reaches the caller ---------
# A compliant hook (e.g. the shipped Slack template) DOES write stderr on
# rc=0 - a 429 backoff warn, a stale-thread drop warn - and that must keep
# reaching the caller byte-identically, not be swallowed by the new capture.
cat >"$CFG/remote-poll" <<'EOF'
#!/usr/bin/env bash
echo "remote-poll: Slack ratelimited (429) - backing off 45s" >&2
echo '{"rid":"r-ok-warn","text":"t","author":"a","thread":"1"}'
EOF
chmod +x "$CFG/remote-poll"
out="$("$BIN/ac-remote.sh" poll 2>"$TMP/pollokwarn.err")"
assert_contains "$out" "remote-order r-ok-warn" "a successful poll still ingests despite hook stderr"
assert_file "$INBOX/r-ok-warn.json"
grep -qxF "remote-poll: Slack ratelimited (429) - backing off 45s" "$TMP/pollokwarn.err" \
  || fail "a successful poll's hook stderr must still reach the caller: $(cat "$TMP/pollokwarn.err")"

# --- ingest: stdin entrance, works with NO poll hook ---------------------------
rm -f "$CFG/remote-poll"                 # a push gateway may be the ONLY transport
# shellcheck disable=SC2016  # non-expansion is the point: the text must stay inert
out="$(printf '{"rid":"g1","text":"gateway order $(touch %s/pwned-ingest)","author":"TN","thread":"55.1"}\n' "$TMP" \
  | "$BIN/ac-remote.sh" ingest)"
assert_contains "$out" "remote-order g1" "ingest prints one line per new order"
assert_file "$INBOX/g1.json"
# shellcheck disable=SC2016  # asserting the literal bytes, not expanding them
grep -qF 'order $(touch' "$INBOX/g1.json" || fail "ingest text must survive verbatim into the stash"
assert_no_file "$TMP/pwned-ingest"
fleet_wakes | grep -qE "^[0-9]+	remote	captain	remote-order g1$" \
  || fail "ingest wake record must be queue_wake TSV shape: now<TAB>remote<TAB>captain<TAB>remote-order g1"

# re-ingest of a stashed rid: nothing printed, no duplicate wake.
out="$(printf '{"rid":"g1","text":"again","author":"TN","thread":"55.1"}\n' | "$BIN/ac-remote.sh" ingest)"
assert_eq "$out" "" "re-ingest with a stashed rid prints nothing"
assert_eq "$(fleet_wakes | grep -c "remote-order g1")" "1" "no duplicate wake on re-ingest"

# dedup is shared ACROSS entrances: a rid poll already stashed stays deduped.
out="$(printf '{"rid":"r1","text":"replay through gateway","author":"TN","thread":"1712.42"}\n' | "$BIN/ac-remote.sh" ingest)"
assert_eq "$out" "" "ingest of a poll-stashed rid prints nothing"
assert_eq "$(fleet_wakes | grep -c "remote-order r1")" "1" "no duplicate wake across entrances"

# mixed garbage + valid stdin: refusals warned and skipped, valid order lands,
# exit stays 0 (bad input is never a hard failure).
out="$({
  printf '{"rid":"../evil2","text":"x","author":"TN","thread":"1.2"}\n'
  printf 'total garbage\n'
  printf '{"rid":"g-nokeys"}\n'
  printf '{"rid":"g2","text":"valid after garbage","author":"TN","thread":"77.3"}\n'
} | "$BIN/ac-remote.sh" ingest 2>"$TMP/ingest.err")" || fail "ingest must exit 0 on mixed garbage+valid stdin"
assert_contains "$out" "remote-order g2" "valid order after refused lines still lands"
case "$out" in *evil2*) fail "refused rid must not print an order line" ;; esac
[ -z "$(find "$INBOX" -name '*evil2*')" ] || fail "refused rid must never name an inbox file"
case "$(fleet_wakes)" in *evil2*) fail "refused rid must never queue a wake" ;; esac
assert_no_file "$INBOX/g-nokeys.json"
assert_contains "$(cat "$TMP/ingest.err")" "WARN" "ingest refusals are warned, not fatal"

# a final unterminated line (no trailing newline) still lands.
out="$(printf '{"rid":"g3","text":"no trailing newline","author":"TN","thread":"88.1"}' | "$BIN/ac-remote.sh" ingest)"
assert_contains "$out" "remote-order g3" "unterminated final line still ingested"
assert_file "$INBOX/g3.json"

# empty stdin: silent success.
out="$("$BIN/ac-remote.sh" ingest </dev/null)" || fail "ingest must exit 0 on empty stdin"
assert_eq "$out" "" "empty stdin ingests nothing"

# --- show: reads from disk; guard applies -------------------------------------
assert_contains "$("$BIN/ac-remote.sh" show r1)" '"rid":"r1"' "show prints the stashed JSON"
assert_fails "$BIN/ac-remote.sh" show no-such-rid
assert_fails "$BIN/ac-remote.sh" show ../evil

# --- reply: env identifiers + stdin text, never argv --------------------------
printf 'plain answer\n' >"$TMP/ans.txt"
assert_fails "$BIN/ac-remote.sh" reply r1 --text-file "$TMP/ans.txt"   # no hook yet
cat >"$CFG/remote-reply" <<'EOF'
#!/usr/bin/env bash
{ printf 'BEGIN rid=%s thread=%s\n' "$AC_REMOTE_RID" "$AC_REMOTE_THREAD"; cat; printf 'END\n'; } >>"$AC_REMOTE_TEST_LOG"
EOF
chmod +x "$CFG/remote-reply"
# shellcheck disable=SC2016  # non-expansion is the point: the text must stay inert
printf 'DECIDED widget: approve $(touch %s/pwned-reply) `touch %s/pwned-reply2`\n' \
  "$TMP" "$TMP" >"$TMP/ans.txt"
"$BIN/ac-remote.sh" reply r1 --text-file "$TMP/ans.txt" >/dev/null
assert_contains "$(cat "$RLOG")" "BEGIN rid=r1 thread=1712.42" "reply passes rid+thread via env"
# shellcheck disable=SC2016  # asserting the literal bytes, not expanding them
grep -qF 'approve $(touch' "$RLOG" || fail "reply text must reach the hook stdin verbatim"
assert_no_file "$TMP/pwned-reply"
assert_no_file "$TMP/pwned-reply2"

printf 'stdin reply body\n' | "$BIN/ac-remote.sh" reply r2 >/dev/null
assert_contains "$(cat "$RLOG")" "thread=999.111" "stdin reply reaches the right thread"
assert_contains "$(cat "$RLOG")" "stdin reply body" "stdin text forwarded"

# --- link / followup round-trip (live meta) -----------------------------------
"$BIN/ac-remote.sh" link mytask r1 >/dev/null
assert_contains "$(cat "$STATE/mytask.meta")" "remote_request=r1" "link writes remote_request"
grep -qE '^remote_request_ts=[0-9]+$' "$STATE/mytask.meta" || fail "link writes remote_request_ts"
assert_fails "$BIN/ac-remote.sh" link mytask no-such-rid    # rid must be stashed
assert_fails "$BIN/ac-remote.sh" link mytask ../evil        # guard on link too

# failed reply keeps the link (fail-closed) ...
mv "$CFG/remote-reply" "$TMP/remote-reply.ok"
printf '#!/usr/bin/env bash\nexit 3\n' >"$CFG/remote-reply"
chmod +x "$CFG/remote-reply"
assert_fails "$BIN/ac-remote.sh" followup mytask --text-file "$TMP/ans.txt"
assert_contains "$(cat "$STATE/mytask.meta")" "remote_request=r1" "failed reply keeps the link"
mv "$TMP/remote-reply.ok" "$CFG/remote-reply"

# ... then a working followup delivers and clears the link.
printf 'landed: PR merged\n' >"$TMP/fu.txt"
"$BIN/ac-remote.sh" followup mytask --text-file "$TMP/fu.txt" >/dev/null
assert_contains "$(cat "$RLOG")" "landed: PR merged" "followup replies into the linked thread"
case "$(cat "$STATE/mytask.meta")" in *remote_request*) fail "followup must clear the link" ;; esac

# second followup without a re-link: warns, exits 0, sends nothing.
sent_before="$(grep -c 'BEGIN rid=' "$RLOG")"
out="$("$BIN/ac-remote.sh" followup mytask --text-file "$TMP/fu.txt" 2>"$TMP/fu2.err")" \
  || fail "second followup must exit 0"
assert_contains "$(cat "$TMP/fu2.err")" "WARN" "second followup warns"
assert_eq "$(grep -c 'BEGIN rid=' "$RLOG")" "$sent_before" "second followup sends nothing"

# --- followup from ARCHIVE meta (torn-down task) -------------------------------
mkdir -p "$STATE/archive/donetask"
printf 'kind=ship\nremote_request=r2\nremote_request_ts=123\n' >"$STATE/archive/donetask/meta"
printf 'landed from archive\n' | "$BIN/ac-remote.sh" followup donetask >/dev/null
assert_contains "$(cat "$RLOG")" "landed from archive" "archive-linked followup delivers"
case "$(cat "$STATE/archive/donetask/meta")" in *remote_request*) fail "archive link must clear" ;; esac
assert_contains "$(cat "$STATE/archive/donetask/meta")" "kind=ship" "other archive meta keys survive the clear"

# --- gc: prunes old UNLINKED stashes only --------------------------------------
printf '{"rid":"old-un","text":"t","author":"a","thread":"1"}\n' >"$INBOX/old-un.json"
printf '{"rid":"old-ln","text":"t","author":"a","thread":"2"}\n' >"$INBOX/old-ln.json"
touch -t 202601010000 "$INBOX/old-un.json" "$INBOX/old-ln.json"
"$BIN/ac-remote.sh" link gctask old-ln >/dev/null
out="$("$BIN/ac-remote.sh" gc --days 400 2>"$TMP/gc.err")"
assert_eq "$out" "" "wider --days window prunes nothing"
# The "unwoken" advisory that used to live here is GONE (family
# remote-order-strands-silently-with-no-live-watcher, design decision 3): its
# own sign ("no wake in spool + unlinked") could never tell a genuine drain
# apart from a lost publish, and a pruning verb nobody runs routinely is not a
# signal anyway. The detector moved to bin/ac-wake-drain.sh's annotate_wakes
# (tests/ac-wake-drain.test.sh), which fires on an unambiguous sign instead.
assert_eq "$(cat "$TMP/gc.err")" "" "gc prints no advisory about undrained orders any more - that detector moved out of this pruning verb"
out="$("$BIN/ac-remote.sh" gc)"
assert_contains "$out" "pruned old-un" "old unlinked stash pruned"
assert_no_file "$INBOX/old-un.json"
assert_file "$INBOX/old-ln.json"       # linked survives regardless of age
assert_file "$INBOX/r1.json"           # fresh unlinked survives
assert_fails "$BIN/ac-remote.sh" gc --days notanumber

# --- error-message quoting: refusal survives `| tail -N` on multi-line input --
# LIVED 2026-07-25: a caller piping a refusal through `tail -N` saw only the
# offending multi-line argument's own tail line, not ERROR: - it looked like
# success. The four `unknown ... option` refusals must truncate the quoted
# argument so ERROR: always survives.
badarg=$'first line of bad input\nsecond line\nthird line that looked like success'
# pipefail makes the refusal's exit 1 the pipeline's status, so `out=$(...)`
# would trip `set -e` here; `|| true` keeps the capture (that IS the point -
# a caller piping through tail loses the exit code the same way).
out="$("$BIN/ac-remote.sh" reply somerid "$badarg" 2>&1 | tail -1)" || true
assert_contains "$out" "ERROR:" "reply refusal survives tail -1 on multi-line input"
out="$("$BIN/ac-remote.sh" followup sometask "$badarg" 2>&1 | tail -1)" || true
assert_contains "$out" "ERROR:" "followup refusal survives tail -1 on multi-line input"
out="$("$BIN/ac-remote.sh" thread-post somefamily "$badarg" 2>&1 | tail -1)" || true
assert_contains "$out" "ERROR:" "thread-post refusal survives tail -1 on multi-line input"
out="$("$BIN/ac-remote.sh" gc "$badarg" 2>&1 | tail -1)" || true
assert_contains "$out" "ERROR:" "gc refusal survives tail -1 on multi-line input"

# --- dispatcher ----------------------------------------------------------------
assert_fails "$BIN/ac-remote.sh" bogus
assert_fails "$BIN/ac-remote.sh"

# --- order: the LOCAL entrance (a solo session handing the captain's order to
# the chief) - same stash, same wake, same dedup as poll/ingest, thread
# "local"; and a reply on a local thread lands on DISK instead of dying for
# want of a transport hook, so the chief's remote-order protocol runs
# unchanged on a fleet with no remote transport at all.
rm -f "$CFG/remote-reply"
out="$("$BIN/ac-remote.sh" order 'please harden the widget lock in repo demo')"
# The machine-parseable confirmation is always line 1 (A2 below may append a
# second, human-facing line) - extract the rid from line 1 alone, never by
# stripping the whole (possibly multi-line) capture.
orid="$(printf '%s\n' "$out" | head -n1)"; orid="${orid#remote-order }"
case "$orid" in local-*) ;; *) fail "order must mint a local-<...> rid and print its wake line: $out" ;; esac
assert_file "$INBOX/$orid.json" "order stashes the JSON like any ingested order"
assert_eq "$(jq -r .thread "$INBOX/$orid.json")" "local" "the stash names the local thread"
assert_eq "$(jq -r .author "$INBOX/$orid.json")" "captain" "the order is the captain's word"
assert_eq "$(jq -r .text "$INBOX/$orid.json")" "please harden the widget lock in repo demo" "the text is stashed verbatim"
assert_contains "$(fleet_wakes)" "remote-order $orid" "order queues the chief's durable wake"
# A2 (family remote-order-strands-silently-with-no-live-watcher): with no live
# fleet watcher armed (the ordinary state in this suite), order must not let
# the solo session read a bare "remote-order <rid>" as proof anything is
# watching for it - decision 1 keeps publish itself unchanged (still stashed,
# still exit 0), the honesty is an ADDED line.
assert_contains "$out" "no live fleet watcher" "order tells the truth about delivery prospects when nothing is watching"
printf 'a multi-line order
with "quotes" and a second line
' >"$TMP/order.md"
out="$("$BIN/ac-remote.sh" order --text-file "$TMP/order.md")"
orid2="$(printf '%s\n' "$out" | head -n1)"; orid2="${orid2#remote-order }"
assert_eq "$(jq -r .text "$INBOX/$orid2.json")" "$(cat "$TMP/order.md")" "--text-file carries the text verbatim, quotes and lines intact"
[ "$orid" != "$orid2" ] || fail "two orders must mint two rids"
out="$("$BIN/ac-remote.sh" order '' 2>&1 || true)"
assert_contains "$out" "order needs" "an empty order is refused"
printf 'TRIAGE: flow=direct, queued as widget-lock
' | "$BIN/ac-remote.sh" reply "$orid" >/dev/null \
  || fail "reply on a local thread must not need a transport hook"
assert_contains "$(cat "$INBOX/$orid.replies.md")" "queued as widget-lock" "the reply lands beside the stash"
printf 'second
' >"$TMP/r2.txt"
"$BIN/ac-remote.sh" reply "$orid" --text-file "$TMP/r2.txt" >/dev/null
assert_eq "$(grep -c '^## ' "$INBOX/$orid.replies.md")" "2" "every reply appends one dated entry"

# --- A2 happy path: a LIVE fleet watcher -> exit 0, no extra line (A4) --------
# A stand-in whose command line IS a watcher's (ac_watcher_pid greps `ps
# command=` for 'ac-watch'), the same fixture shape tests/ac-done.test.sh uses
# for the real ac_watcher_pid/nudge contract.
mkdir -p "$TMP/fakewatch"
cat >"$TMP/fakewatch/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
sleep 30 &
wait $! 2>/dev/null || true
EOF
chmod +x "$TMP/fakewatch/ac-watch.sh"
# `set -m` makes the wrapper its own process-group leader, which is the only
# thing that lets the reap below reach the `sleep` it forks: without it the
# group is this runner's own, the reap can only name the wrapper pid, and the
# sleep is reparented to pid 1 on every run of this file. Same idiom as
# bin/ac-remote.sh run_ack and bin/ac-sync.sh fetch_bounded.
set -m
bash "$TMP/fakewatch/ac-watch.sh" >/dev/null 2>&1 &
watch_pid=$!
set +m
mkdir -p "$STATE/.watch.lock.d"
printf '%s\n' "$watch_pid" >"$STATE/.watch.lock.d/pid"
i=0
watch_child=""
while [ "$i" -lt 50 ]; do
  watch_child="$(pgrep -P "$watch_pid" 2>/dev/null || true)"
  [ -n "$watch_child" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$watch_child" ] || fail "fixture watcher never forked its sleep child"
out="$("$BIN/ac-remote.sh" order 'ship it with a live watcher armed')"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" \
  "a live fleet watcher means order prints ONLY the confirmation line - no regression on the happy path"
case "$out" in
  *"no live fleet watcher"*) fail "must not warn when a live fleet watcher is actually armed" ;;
esac
# Job control announces a signal-killed job on the real stderr the moment it
# notices, whatever the reaping `wait` redirects, so the segment owns that
# noise rather than the suite's output.
{ kill -TERM -"$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
} 2>/dev/null
i=0
while [ "$i" -lt 30 ] && kill -0 "$watch_child" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
kill -0 "$watch_child" 2>/dev/null \
  && fail "the fixture's sleep child outlived the reap - reparented to pid 1, one leak per run"
rm -rf "$STATE/.watch.lock.d"

# --- a failed wake publish must not leave the rid stashed ---------------------
# The stash `ln` and the wake publish are two commits into two DIFFERENT
# directories (state/remote-inbox/ and state/.wake-spool/), so they can never
# be one atomic act. What can be held is that a stash never OUTLIVES a publish
# that failed: the stash is also the dedup sign (`[ -e "$stash" ] && continue`),
# so one whose wake never existed reads as "already ingested" and burns that rid
# for every later re-delivery - the rid can never be ingested again.
#
# The fault is driven through the filesystem rather than a seam: with
# state/.wake-spool a regular FILE, ac_wake_publish's `[ -d "$spool" ] ||
# mkdir -p "$spool" || return 1` fails. That reaches the position EVERY one of
# its non-zero returns shares - strictly after the stash `ln` - with no crash
# and no signal, which is the whole point: this window is reachable by an
# ordinary error return, not only by a death.
rm -rf "$STATE/.wake-spool"
printf 'not a directory\n' >"$STATE/.wake-spool"
assert_fails "$BIN/ac-remote.sh" ingest <<'FEED'
{"rid":"wpfail","text":"the wake for this one cannot be published","author":"TN","thread":"77.1"}
FEED
assert_no_file "$INBOX/wpfail.json" \
  "a failed wake publish must roll its stash back - a stash with no wake burns the rid for good"

# ...and the proof that it is really free: the SAME rid ingests normally once
# the fault clears. Pre-fix this is a silent no-op (exit 0, nothing printed).
rm -f "$STATE/.wake-spool"
out="$(printf '{"rid":"wpfail","text":"re-delivered after the fault cleared","author":"TN","thread":"77.1"}\n' \
  | "$BIN/ac-remote.sh" ingest)"
assert_contains "$out" "remote-order wpfail" \
  "after a rolled-back publish the rid is free: re-delivering it ingests normally"
assert_file "$INBOX/wpfail.json"
fleet_wakes | grep -qE "^[0-9]+	remote	captain	remote-order wpfail$" \
  || fail "the re-delivered order must publish its wake record"

# --- a LOCAL order survives a Ctrl-C in the stash-then-wake window -----------
# The seam ac-remote.sh commits an order through is two steps, a stash then its
# wake, and the stash is ALSO the dedup sign - so an interrupt between them
# burns that rid for every later re-delivery. A POLLED order costs a
# re-delivery the transport can still supply; a LOCAL one has no such source -
# the rid exists only here and nothing in the tree ever re-offers it, so the
# loss is permanent rather than recoverable.
#
# MEASURED on this host: the window is ~11.7ms (five fork+execs) against a
# 62.6ms mean for the whole `order` command - about 19% of its lifetime, so an
# interrupt arriving at a uniformly random moment lands in the burn window
# roughly one time in five. The polled path's 1.18e-7 duty cycle was computed
# over a long-running watcher and does not carry here at all.
#
# Deterministic, not a race: AC_WAKE_SEAM_AT fires the hook exactly between the
# wake record's private write and its atomic link - the inside of the window -
# and the hook raises a real Ctrl-C, which is a group-wide INT and not one pid.
# ac-remote.sh is backgrounded under `set -m` so that group is ITS OWN: a group
# kill from a test file that shares the runner's group is suicide.
sigseam="$TMP/order-int-seam"
cat >"$sigseam" <<'SEAM'
#!/bin/sh
pgid=$(ps -o pgid= -p $$ | tr -d ' ')
kill -INT -"$pgid" 2>/dev/null || true
sleep 0.3
SEAM
chmod +x "$sigseam"

rm -rf "$STATE/.wake-spool"; mkdir -p "$STATE/.wake-spool"
set -m
AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$sigseam" \
  "$BIN/ac-remote.sh" order 'an order interrupted inside the commit window' \
  >"$TMP/order-int.out" 2>&1 &
int_pid=$!
set +m
wait "$int_pid" 2>/dev/null || true

int_rid="$(ls "$INBOX" 2>/dev/null | sed -n 's/^\(local-[^.]*\)\.json$/\1/p' | tail -n 1)"
[ -n "$int_rid" ] || fail "the interrupted order left no stash at all - the fixture never reached the window"
grep -rq "remote-order $int_rid" "$STATE/.wake-spool" 2>/dev/null \
  || fail "a local order's rid was BURNED: its stash survives with no wake, and nothing in the tree re-delivers it ($int_rid)"

rm -f "$INBOX/$int_rid.json"
rm -rf "$STATE/.wake-spool"; mkdir -p "$STATE/.wake-spool"

# ...and the ignore ends WITH the commit. A first cut ignored INT across the
# whole order pipeline, which spans the lifecycle-ack hook - measured 5.66s of
# a dead Ctrl-C against a hanging hook at a 6s ceiling, up to 20s at the
# default - over a gap that had already closed. With the order committed and
# the ack hook parked, a group-wide INT must end the command at once.
cat >"$CFG/remote-ack" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$CFG/remote-ack"
set -m
AC_REMOTE_ACK_TIMEOUT=8 "$BIN/ac-remote.sh" order 'an order interrupted during its ack' \
  >"$TMP/order-ack-int.out" 2>&1 &
ack_pid=$!
set +m
sleep 0.7
ack_began=$SECONDS
kill -INT -"$ack_pid" 2>/dev/null || true
wait "$ack_pid" 2>/dev/null || true
ack_elapsed=$((SECONDS - ack_began))
[ "$ack_elapsed" -lt 4 ] \
  || fail "a Ctrl-C during the ack hook must land at once - the ignore is the commit's, not the pipeline's (took ${ack_elapsed}s)"
ack_rid="$(ls "$INBOX" 2>/dev/null | sed -n 's/^\(local-[^.]*\)\.json$/\1/p' | tail -n 1)"
[ -n "$ack_rid" ] || fail "the order never committed before the ack"
grep -rq "remote-order $ack_rid" "$STATE/.wake-spool" 2>/dev/null \
  || fail "the commit itself stayed whole: stash and wake both on disk ($ack_rid)"
rm -f "$CFG/remote-ack" "$INBOX/$ack_rid.json"
rm -rf "$STATE/.wake-spool"; mkdir -p "$STATE/.wake-spool"

pass
