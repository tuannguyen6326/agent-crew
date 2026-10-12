#!/usr/bin/env bash
# ac-remote.test.sh - transport-agnostic remote-order core: poll no-op gate,
# stash+wake dedup (exactly-once per rid), rid slug-guard, ingest (the stdin
# push-gateway entrance sharing poll's per-line core - stash+wake+dedup with
# no poll hook, dedup across BOTH entrances, garbage tolerated), reply via
# env+stdin only, link/followup round-trip (live and archive meta), gc, and
# the untrusted-text contract ($(...) and backticks stay inert bytes end to end).

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
grep -qE "^[0-9]+	remote	captain	remote-order r1$" < <(fleet_wakes) \
  || fail "wake record must be queue_wake TSV shape: now<TAB>remote<TAB>captain<TAB>remote-order r1"

# A remote order is the captain SPEAKING, not waiting - they already get the
# ac-remote reply as confirmation. Notifying only on a block by the captain
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
grep -qE "^[0-9]+	remote	captain	remote-order rscoped$" < <(fleet_wakes) \
  || fail "a remote-order wake must reach the FLEET spool even when polled from a scoped session"
assert_no_file "$STATE/.wake-spool.fam1" "a remote-order wake is never filed under a family scope"

# ... and the same for the INGEST entrance, which is the one the Slack
# gateway drives (it queues no wake itself - its chief nudge is a UI latency
# shave, the durable wake is this write).
printf '{"rid":"iscoped","text":"approve widget","author":"TN","thread":"1712.44"}\n' \
  | AC_SCOPE=fam1 "$BIN/ac-remote.sh" ingest >/dev/null
grep -qE "^[0-9]+	remote	captain	remote-order iscoped$" < <(fleet_wakes) \
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
grep -qE "^[0-9]+	remote	captain	remote-order g1$" < <(fleet_wakes) \
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
# (tests/sh/ac-wake-drain.test.sh), which fires on an unambiguous sign instead.
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
# command=` for 'ac-watch'), the same fixture shape tests/sh/ac-done.test.sh uses
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
grep -qE "^[0-9]+	remote	captain	remote-order wpfail$" < <(fleet_wakes) \
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

# --- differential: src/remote.ts against the frozen bash original -------------
# DISPUTED: the implementation (tests/fixtures/ac-remote.sh under bash vs src/remote.ts through bin/ac-remote.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home whose config/ holds the row's fake hooks (each logging its argc, the AC_REMOTE_* names, whether it leads its process group and its stdin bytes to <side>/log/hooks), TMPDIR=<side>/tmp; a `date` stub answering every shape the entry runs (the stamps moved per row) FIRST on PATH; LC_ALL=C unless the row names a locale; argv, env and stdin (the side root spelled HOME); cwd (the side root); exit status, stdout and stderr compared whole, plus every entry under <side>/home/state (names, modes, link targets and bytes) and the hook log - the side root spelled HOME, each side's distro root ROOT, a pid PID.
obin="$(make_oracle_bin ac-remote)"
# The frozen entry calls two helpers retired from the live libraries with the
# port (it was their last caller); the oracle's own copies get them back.
cat >>"$obin/ac-lib.sh" <<'LIB'
ac_seed_root_pointer() {
  [ -n "${AC_HOME:-}" ] || return 0
  local ptr root
  ptr="$(ac_root_pointer_path)"; root="$(ac_root)"
  [ "$(cat "$ptr" 2>/dev/null || true)" = "$root" ] || printf '%s\n' "$root" >"$ptr"
}
LIB
cat >>"$obin/ac-wake-lib.sh" <<'LIB'
ac_room_pending_lines() {
  ac_room_scan '^- \[[^]]*\] [^>]*> (GATE|ASK|DECIDED)' '
    /^- \[[^]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { open[++n] = $0 }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { if (settled < n) settled++ }
    END { for (i = settled + 1; i <= n; i++) print open[i] }
  ' "$1"
}
LIB
OROOT="$(cd "$obin/.." && pwd -P)"
OH="$TMP/rside-o"; NH="$TMP/rside-n"
RSTUB="$TMP/rstub"; mkdir -p "$RSTUB"
cat >"$RSTUB/date" <<'STUB'
#!/bin/sh
# Every date(1) shape the entry runs, fixed per row; DATE_FAIL fails the
# order-stamp and epoch shapes with that status.
case "$*" in
  +%s) [ -z "${DATE_FAIL:-}" ] || exit "$DATE_FAIL"; printf '%s\n' "$((1700000000 + R_ROW))" ;;
  +%s%N) printf '%s123456789\n' "$((1700000000 + R_ROW))" ;;
  "-u +%Y%m%dT%H%M%SZ") [ -z "${DATE_FAIL:-}" ] || exit "$DATE_FAIL"; printf '2023%04dT000000Z\n' "$R_ROW" ;;
  "-u +%Y-%m-%dT%H:%M:%SZ") printf '2023-11-14T22:13:%02dZ\n' "$((R_ROW % 60))" ;;
  "+%Y-%m-%d %H:%M") printf '2023-11-15 05:13 TZ=%s\n' "${TZ-unset}" ;;
  *) exec /bin/date "$@" ;;
esac
STUB
chmod +x "$RSTUB/date"
# The hooks' shared logger: one line per call.
cat >"$TMP/hooklog.sh" <<'LOGGER'
hlog() {
  grp=member; [ "$(ps -o pgid= -p $$ | tr -d ' ')" = "$$" ] && grp=leader
  printf '%s argc=%s rid=[%s] thread=[%s] state=[%s] mention=[%s] group=%s stdin=%s\n' "$1" "$2" \
    "${AC_REMOTE_RID-unset}" "${AC_REMOTE_THREAD-unset}" "${AC_REMOTE_ACK_STATE-unset}" \
    "${AC_REMOTE_MENTION-unset}" "$grp" "$(od -An -tx1 | tr -d ' \n')" >>"$R_LOG"
}
LOGGER
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
each() {  # each '<shell text>' - the text run with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; eval "$1"; done
}
seed_side() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/home/data" "$H/log" "$H/tmp"
  printf 'off\n' >"$H/home/config/wedge-alarm"
}
hook() {  # hook <name> <sh body> - an executable fake hook in config/; the body may call hlog
  printf '#!/bin/sh\n. "%s"\n%s\n' "$TMP/hooklog.sh" "$2" >"$H/home/config/$1"
  chmod +x "$H/home/config/$1"
}
unhook() { rm -rf "$H/home/config/$1"; }
put() {  # put <path under the side root> <printf format> [args] - a seeded file
  local f="$H/$1"; shift; mkdir -p "$(dirname "$f")"; printf -- "$@" >"$f"
}
stash() {  # stash <rid> <thread JSON> - a stashed order, as ingest writes one
  put "home/state/remote-inbox/$1.json" '{"rid":"%s","text":"t","author":"a","thread":%s}\n' "$1" "$2"
}
ROW=0
DLC=C
HOMELESS=0
R_ENV=()
R_STDIN=/dev/null
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL="$DLC" TMPDIR="$h/tmp" PATH="$RSTUB:$PATH" R_LOG="$h/log/hooks" R_SIDE="$h" R_ROW="$ROW")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${R_ENV[@]+"${R_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h" && env -u AC_HOME -u AC_SCOPE -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET -u EPOCHSECONDS \
    -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN -u LANG -u LC_CTYPE -u TZ "${e[@]}" "$bin/ac-remote.sh" ${a[@]+"${a[@]}"}) \
    <"$R_STDIN" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() {  # norm <side root> - stdin with the side root spelled HOME, the distro roots ROOT, pids PID, temp suffixes RANDOM
  LC_ALL=C sed -e "s#$1#HOME#g" -e "s#$OROOT#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's/local-\([0-9TZ]*\)-[0-9][0-9]*/local-\1-PID/g' -e 's/\.[0-9][0-9]*\.\([0-9]\{6\}\)/.PID.\1/g' \
    -e 's/\.wake-tmp\.[A-Za-z0-9]\{8\}/.wake-tmp.RANDOM/g' -e 's/\.tmp\.[0-9][0-9]*/.tmp.PID/g' \
    -e 's/ac-remote-poll-err\.[A-Za-z0-9]\{6\}/ac-remote-poll-err.RANDOM/g' -e 's/\(\.stash\..*\)\.[0-9][0-9]*:/\1.PID:/'
}
snap() {  # snap <side root> - every entry under home/state in byte order (name, mode, link, bytes), then the hook log
  [ ! -d "$1/home/state" ] || (cd "$1/home/state" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s %s\n' "$f" "$(ls -ld "$f" | cut -c1-10)"
    [ ! -L "$f" ] || printf -- '-> %s\n' "$(readlink "$f")"
    [ ! -f "$f" ] || [ ! -r "$f" ] || cat "$f"
  done)
  printf '== hooks\n'; cat "$1/log/hooks" 2>/dev/null || true
}
outs() {
  norm "$OH" <"$TMP/o.raw" >"$TMP/o.out"; norm "$OH" <"$TMP/o.err" >"$TMP/o.err2"
  norm "$NH" <"$TMP/n.raw" >"$TMP/n.out"; norm "$NH" <"$TMP/n.err" >"$TMP/n.err2"
  snap "$OH" | norm "$OH" >"$TMP/o.tree"; snap "$NH" | norm "$NH" >"$TMP/n.tree"
}
compare() {  # compare <label> - the two sides' last answers, state trees and hook logs
  outs
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$1': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
  [ "${ERR-}" = own ] || cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$1' (row step $ROW, env ${R_ENV[*]-}): $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 8)"
  [ "${TREE-}" = own ] || cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "differential state differs for '$1': $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 10)"
}
same() {  # same <args...> - oracle on $OH and shim on $NH answer alike and leave alike trees
  local o_rc=0 n_rc=0
  ROW=$((ROW + 1))
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$BIN" "$NH" n "$@" || n_rc=$?
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  SAME_RC=$n_rc
  compare "$*"
}
sides() {  # sides <args...> - both sides run, nothing compared: a named divergence's row asserts by hand
  O_RC=0; N_RC=0
  ROW=$((ROW + 1))
  run_side "$obin" "$OH" o "$@" || O_RC=$?
  run_side "$BIN" "$NH" n "$@" || N_RC=$?
  outs
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
oracle_err() { cat "$TMP/o.err2"; }
shim_tree() { cat "$TMP/n.tree"; }
NO_HOME_TEXT="$(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)"
SPEC_HEAD="$(sed -n '/^\/\//!q; s#^// \{0,1\}##p' "$ROOT/src/remote.ts")"
# The narrow PATH a jq-less row runs: what both entries need before their jq check.
mkdir -p "$TMP/rnojq"
for t in bash dirname cat mkdir bun; do ln -s "$(command -v "$t")" "$TMP/rnojq/$t"; done
both seed_side

# 1. usage: no verb, -h and an unknown verb print the header on stdout, exit 2
#    - the shim prints src/remote.ts's spec where the original printed its own
#    bash header (W4, named: the USAGE HEADER rule); homeless the preamble
#    refuses first (NO_HOME, exit 1); a PATH with no jq refuses every argv,
#    homeless too, and only after state/.ac-root is written (W1)
for v in "" -h bogus; do
  if [ -z "$v" ]; then sides; else sides "$v"; fi
  assert_eq "$O_RC $N_RC" "2 2" "row 1: '$v' is usage, exit 2"
  assert_eq "$(cat "$TMP/n.raw")" "$SPEC_HEAD" "row 1: '$v' prints the module's spec header"
  assert_contains "$(cat "$TMP/o.out")" "ac-remote.sh - transport-agnostic remote captain orders" "row 1: the oracle printed its own header"
  assert_eq "$(shim_err)" "" "row 1: nothing on stderr"
done
HOMELESS=1
same
assert_eq "$(shim_err)" "ERROR: $NO_HOME_TEXT" "row 1: homeless usage is the home refusal"
R_ENV=("PATH=$TMP/rnojq")
same show r1
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "row 1: no jq, homeless"
HOMELESS=0
each 'rm -rf "$H/home/state"'
same show r1
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "row 1: no jq, homed"
assert_eq "$(shim_tree | head -n 2)" "== ./.ac-root -rw-r--r--
ROOT" "row 1: the root pointer is written before the jq check (W1)"
R_ENV=()

# 2. the root pointer state/.ac-root: written when absent or different, left
#    alone when equal (trailing LFs and NULs read away), written THROUGH a
#    symlink; a pointer that cannot be written ends every verb, show included
#    (W2, exit 1 - the shell's own redirect line is not reproduced, the shim
#    names the path and errno); an AC_HOME cd cannot enter is the
#    physicalDir refusal where the original printed cd's line and then tried
#    the filesystem root's /.ac-root (W3, named)
both seed_side
same show r1
assert_eq "$(shim_err)" "ERROR: no stashed remote order: r1" "row 2: show of an absent rid"
assert_contains "$(shim_tree)" "== ./.ac-root -rw-r--r--
ROOT" "row 2: a fresh pointer"
pointer() { printf "$1" "$([ "$H" = "$OH" ] && printf '%s' "$OROOT" || printf '%s' "$ROOT")" >"$H/home/state/.ac-root"; }
both pointer '%s\n\n\n'
each 'chmod 444 "$H/home/state/.ac-root"'
same show r1
assert_contains "$(shim_tree)" "== ./.ac-root -r--r--r--
ROOT


" "row 2: an equal pointer with trailing LFs is never rewritten"
each 'chmod 644 "$H/home/state/.ac-root"'
both pointer '%s\0\n'
same show r1
both put home/state/.ac-root '/elsewhere\n'
same show r1
assert_contains "$(shim_tree)" "== ./.ac-root -rw-r--r--
ROOT" "row 2: a different pointer is rewritten"
each 'rm -f "$H/home/state/.ac-root"'
both put home/state/target 'old\n'
link_ptr() { ln -s "$H/home/state/target" "$H/home/state/.ac-root"; }
both link_ptr
same show r1
assert_contains "$(shim_tree)" "== ./target -rw-r--r--
ROOT" "row 2: written through a symlink"
each 'rm -f "$H/home/state/.ac-root" "$H/home/state/target"'
each 'mkdir -p "$H/home/state/.ac-root"'
sides show r1
assert_eq "$O_RC $N_RC" "1 1" "row 2: a pointer that is a directory ends show (W2)"
assert_contains "$(oracle_err)" "Is a directory" "row 2: the oracle's shell-own line"
assert_eq "$(shim_err)" "ERROR: cannot write HOME/home/state/.ac-root: EISDIR" "row 2: the shim's own line"
each 'rmdir "$H/home/state/.ac-root"'
each 'chmod 555 "$H/home/state"'
sides show r1
assert_eq "$O_RC $N_RC" "1 1" "row 2: a read-only state/ ends show (W2)"
assert_eq "$(shim_err)" "ERROR: cannot write HOME/home/state/.ac-root: EACCES" "row 2: the shim's own line"
each 'chmod 755 "$H/home/state"'
R_ENV=("AC_HOME=HOME/nope")
sides show r1
assert_eq "$O_RC $N_RC" "1 1" "row 2: an AC_HOME cd cannot enter (W3)"
assert_contains "$(oracle_err)" "cd: HOME/nope" "row 2: the oracle printed cd's line"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: HOME/nope" "row 2: the shim's physicalDir refusal (W3 named)"
R_ENV=()

# 15. show: usage, the rid guard (all-dot and slash rids refused), absent,
#     extra args ignored, the stash's raw bytes, an unreadable stash (cat's
#     own line and status)
both seed_side
both stash r1 '"1.2"'
both put home/state/remote-inbox/rb.json 'raw \351 \0 bytes'
same show
assert_eq "$(shim_err)" "ERROR: usage: ac-remote.sh show <rid>" "row 15: show usage"
for r in ../x . .. ... 'a b' 'caf\303\251'; do
  same show "$(printf "$r")"
done
assert_eq "$(shim_err)" "ERROR: rid must be [A-Za-z0-9._-]+: 'café'" "row 15: a multibyte rid refused, under C"
DLC=en_US.UTF-8
sides show "$(printf 'caf\303\251')"
assert_eq "$(oracle_err)|$(shim_err)" "ERROR: no stashed remote order: café|ERROR: rid must be [A-Za-z0-9._-]+: 'café'" "row 15: under UTF-8 bash 3.2's range let the rid through; the guard reads its text (named)"
DLC=C
same show r1 extra args
assert_eq "$(shim_out)" '{"rid":"r1","text":"t","author":"a","thread":"1.2"}' "row 15: the stash printed"
same show rb
each 'chmod 000 "$H/home/state/remote-inbox/r1.json"'
TREE=own same show r1
assert_contains "$(shim_err)" "Permission denied" "row 15: an unreadable stash is cat's own line"
each 'chmod 644 "$H/home/state/remote-inbox/r1.json"'

# 20. done-stamp: a new family, a second one, the BRE key - `a.b` drops the
#     `aXb=` stamp as grep -v "^a.b=" did (W28) -, EPOCHSECONDS winning over
#     date (W35), a failing date stamping an empty value, the guard; a stamp
#     the rewrite cannot read is a refusal here where the original's grep
#     failed and its mv replaced the file with the one new line, exit 0 (the
#     metaSet divergence, named)
both seed_side
same done-stamp
same done-stamp ../evil
same done-stamp famz
assert_eq "$(shim_out)" "done-stamped famz" "row 20: done-stamp's line"
same done-stamp aXb
same done-stamp a.b
assert_eq "$(cat "$NH/home/state/.landing-receipt-stamp")" "famz=$((1700000000 + ROW - 2))
a.b=$((1700000000 + ROW))" "row 20: a.b dropped the aXb stamp (W28)"
R_ENV=("EPOCHSECONDS=5")
same done-stamp famz
R_ENV=("DATE_FAIL=3")
same done-stamp famq
assert_contains "$(shim_tree)" "famq=
" "row 20: a failing date stamps an empty value"
R_ENV=()
DLC=en_US.UTF-8
both put home/state/.landing-receipt-stamp 'a\303\251b=1\na\351b=2\naXb=3\n'
same done-stamp a.b
assert_contains "$(shim_tree)" "$(printf 'a\351b=2\n')" "row 20: under UTF-8 the BRE dot never matches an invalid byte"
DLC=C
both put home/state/.landing-receipt-stamp 'a\303\251b=1\naXb=3\n'
same done-stamp a.b
assert_contains "$(shim_tree)" "$(printf 'a\303\251b=1\n')" "row 20: under C the BRE dot is one byte"
each 'chmod 000 "$H/home/state/.landing-receipt-stamp"'
sides done-stamp famz
assert_eq "$O_RC $N_RC" "0 1" "row 20: an unreadable stamp (named divergence)"
assert_eq "$(shim_err)" "ERROR: cannot rewrite HOME/home/state/.landing-receipt-stamp: EACCES" "row 20: the shim refuses"
each 'rm -f "$H/home/state/.landing-receipt-stamp"'

# 22. gc: --days missing / not digits / octal-looking / past 64 bits (find
#     fails silently, exit 0); ages either side of the 14-day default (find's
#     -mtime +N is floor(age/86400) > N); links in a live meta and an archive
#     meta protect, one in an older-epoch archive dir does not (W34); a dot
#     stash prunes as its rid; a replies file is never pruned (W34); the
#     output keeps find's own order, the spawned binary's
both seed_side
same gc --days
assert_eq "$(shim_err)" "ERROR: --days needs a number" "row 22: --days needs a value"
same gc --days 1x
same gc --days -1
same gc --bogus
same gc "$(printf 'a\nb')"
same gc
assert_eq "$(shim_out)" "" "row 22: no inbox"
aged() {  # aged <rid> <age as -v args to date>
  stash "$1" '"1"'; touch -t "$(date -v"$2" -v"$3" +%Y%m%d%H%M.%S)" "$H/home/state/remote-inbox/$1.json"
}
gc_world() {
  aged young -13d -23H; aged edge -14d -1H; aged old -15d -1H; aged olda -15d -1H; aged oldb -15d -1H; aged oldc -15d -1H
  aged .dot -15d -1H
  put home/state/remote-inbox/old.replies.md 'r\n'; touch -t 202001010000 "$H/home/state/remote-inbox/old.replies.md"
  put home/state/t1.meta 'remote_request=olda\n'
  put home/state/archive/t2/meta 'remote_request=oldb\n'
  put home/state/archive/t3/1700000000.AbCdEf/meta 'remote_request=oldc\n'
}
both gc_world
same gc --days 99999999999999999999
assert_eq "$(shim_out)" "" "row 22: a 20-digit window prunes nothing"
same gc --days 08
assert_contains "$(shim_out)" "pruned old" "row 22: 08 is eight days"
both gc_world
same gc
assert_contains "$(shim_out)" "pruned oldc" "row 22: an older-epoch archive link does not protect (W34)"
assert_contains "$(shim_tree)" "== ./remote-inbox/edge.json" "row 22: 14d1h survives the 14-day default"
assert_contains "$(shim_tree)" "== ./remote-inbox/old.replies.md" "row 22: a replies file is never pruned (W34)"

# 10. the lifecycle-ack hook (run_ack), through `ack`: absent; its argc, env,
#     stdin (/dev/null), stdout (discarded) and its OWN process group;
#     failing (1), exiting 124 - read as a timeout (W19) -, KILLed (137); a
#     DIRECTORY passes `[ -x ]` and fails to run (W20; bash's own line on each
#     side differs, named); a shebang-less hook runs as a script; budget 0
#     warns at the first edge; budget 08 dies in `$(( ))` before the acked
#     line (W18, exit 1; bash's base error is shell-own, named); a budget past
#     2^63 is no number to `[` (its noise shell-own, named) and wraps to a
#     negative remainder, so the call is reaped at once; timeout 0 reaps at
#     once; timeout 02 is kept as written (whole seconds, so not 01: the
#     reap could beat the hook's first line); a hung hook is reaped at the
#     timeout with its own stderr passing; the timeout is clamped to the
#     budget left
both seed_side
both stash r1 '"1712.99"'
same ack r1 working
assert_eq "$(shim_out)" "acked r1 (working)" "row 10: no hook"
both hook remote-ack 'hlog ack $#; echo noise; exit 0'
same ack r1 working
assert_contains "$(shim_tree)" "ack argc=0 rid=[r1] thread=[1712.99] state=[working] mention=[unset] group=leader stdin=" "row 10: env, group leader, stdin empty"
assert_eq "$(shim_out)" "acked r1 (working)" "row 10: the hook's stdout is discarded"
for rc in 1 124; do
  both hook remote-ack "exit $rc"
  same ack r1 done
done
assert_eq "$(shim_err)" "WARN: ack: remote-ack hook timed out after 20s for r1 (done)" "row 10: exit 124 reads as a timeout (W19)"
both hook remote-ack 'kill -KILL $$'
same ack r1 done
assert_eq "$(shim_err)" "WARN: ack: remote-ack hook failed for r1 (done)" "row 10: a KILLed hook failed"
each 'unhook remote-ack; mkdir "$H/home/config/remote-ack"'
sides ack r1 done
assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")" "0 0 acked r1 (done)" "row 10: a directory hook (W20)"
assert_eq "$(shim_out)" "acked r1 (done)" "row 10: the shim's line"
assert_eq "$(tail -n 1 "$TMP/o.err2")|$(tail -n 1 "$TMP/n.err2")" "WARN: ack: remote-ack hook failed for r1 (done)|WARN: ack: remote-ack hook failed for r1 (done)" "row 10: both warn failed after bash's own line"
each 'rmdir "$H/home/config/remote-ack"'
each 'printf ". \"%s\"; hlog noshebang \$#\n" "$TMP/hooklog.sh" >"$H/home/config/remote-ack"; chmod +x "$H/home/config/remote-ack"'
same ack r1 working
assert_contains "$(shim_tree)" "noshebang argc=0 rid=[r1]" "row 10: a shebang-less hook runs"
both hook remote-ack 'hlog ack $#; printf "own hook stderr\n" >&2; sleep 30'
R_ENV=("AC_REMOTE_ACK_BUDGET=0")
same ack r1 working
assert_eq "$(shim_err)" "WARN: ack: remote-ack budget (0s) spent this round - skipping remaining acks" "row 10: budget 0"
R_ENV=("AC_REMOTE_ACK_BUDGET=08")
sides ack r1 working
assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")$(shim_out)" "1 1 " "row 10: budget 08 dies before the acked line (W18)"
assert_contains "$(oracle_err)" "value too great for base" "row 10: the oracle's shell-own line"
assert_eq "$(shim_err)" "" "row 10: the shim says nothing of bash's (named)"
# A hook reaped at once races its own first line, so these two rows' hook
# says nothing.
both hook remote-ack 'sleep 30'
R_ENV=("AC_REMOTE_ACK_BUDGET=9223372036854775808")
sides ack r1 working
assert_eq "$O_RC $N_RC" "0 0" "row 10: a budget past 2^63"
assert_eq "$(tail -n 1 "$TMP/o.err2")|$(shim_err)" "WARN: ack: remote-ack hook timed out after -9223372036854775808s for r1 (working)|WARN: ack: remote-ack hook timed out after -9223372036854775808s for r1 (working)" "row 10: the wrapped remainder reaps at once"
assert_contains "$(oracle_err)" "integer expression expected" "row 10: the oracle's shell-own noise (named)"
R_ENV=("AC_REMOTE_ACK_TIMEOUT=0")
same ack r1 working
assert_eq "$(shim_err)" "WARN: ack: remote-ack hook timed out after 0s for r1 (working)" "row 10: timeout 0"
both hook remote-ack 'hlog ack $#; printf "own hook stderr\n" >&2; sleep 30'
R_ENV=("AC_REMOTE_ACK_TIMEOUT=02")
same ack r1 working
assert_contains "$(shim_err)" "own hook stderr
WARN: ack: remote-ack hook timed out after 02s for r1 (working)" "row 10: a hung hook, its own stderr, the timeout as written"
R_ENV=("AC_REMOTE_ACK_TIMEOUT=5" "AC_REMOTE_ACK_BUDGET=2")
same ack r1 working
assert_contains "$(shim_err)" "timed out after 2s for r1" "row 10: the timeout clamped to the budget"
R_ENV=()
both unhook remote-ack

# 17. link and ack: usage shapes, the task guard (no all-dot rule), the rid
#     guard, an unstashed rid; link mints a meta for ANY id (W29), keeps a
#     meta's other keys, stamps EPOCHSECONDS when exported (W35) or an empty
#     value when date fails, and reads "" as the thread of a stash jq cannot
#     parse; ack's state is checked before the stash
both seed_side
both stash r1 '"1.2"'
both put home/state/remote-inbox/bad.json 'not json\n'
both hook remote-ack 'hlog ack $#'
same link
same link t
assert_eq "$(shim_err)" "ERROR: usage: ac-remote.sh link <task-id> <rid>" "row 17: link usage"
same link '../t' r1
same link ... r1
assert_eq "$(shim_out)" "linked ... -> r1" "row 17: an all-dot task id passes the task guard"
same link t ..
same link t nope
assert_eq "$(shim_err)" "ERROR: no stashed remote order: nope (poll first)" "row 17: unstashed"
same link fresh r1
assert_contains "$(shim_tree)" "== ./fresh.meta -rw-r--r--
remote_request=r1
remote_request_ts=$((1700000000 + ROW))" "row 17: a phantom meta (W29)"
both put home/state/t2.meta 'kind=ship\nremote_request=old\nremote_request_ts=1\nx=y'
same link t2 r1
R_ENV=("EPOCHSECONDS=5")
same link t3 r1
R_ENV=("DATE_FAIL=2")
same link t4 r1
R_ENV=()
same link t5 bad
assert_contains "$(shim_tree)" "ack argc=0 rid=[bad] thread=[] state=[working]" "row 17: an unparseable stash acks with no thread"
both put home/state/t6.meta 'kind=ship\nnote=a\0b\n'
sides link t6 r1
assert_eq "$O_RC $N_RC" "0 0" "row 17: a meta holding a NUL"
assert_contains "$(cat "$TMP/o.tree")" "Binary file" "row 17: the original's grep -v wrote its binary notice into the meta"
assert_contains "$(shim_tree)" "$(printf 'kind=ship\nnote=a')" "row 17: the port keeps the bytes (the metaSet divergence, named)"
each 'rm -f "$H/home/state/t6.meta"'
same ack
same ack r1
same ack r1 bogus
assert_eq "$(shim_err)" "ERROR: ack state must be working|done: bogus" "row 17: the state guard"
same ack .. done
same ack nope done
assert_eq "$(shim_err)" "ERROR: no stashed remote order: nope" "row 17: ack of an unstashed rid"
same ack nope bogus
assert_eq "$(shim_err)" "ERROR: ack state must be working|done: bogus" "row 17: the state is checked before the stash"

# 16. reply: options are parsed before the rid guard (W25); a LOCAL thread
#     (an order's stash, or a polled one whose thread is the string "local" -
#     W22) appends `## <iso>`, the text, LF to <rid>.replies.md - empty stdin
#     still appends (W23), a text file that cannot be read leaves the header
#     and is cat's line and status (W23); a remote thread needs the reply hook
#     (absent / not executable refused), hands it the rid and thread in env
#     and the text on stdin, its stdout ahead of ours; a failing hook, and a
#     --text-file the redirect cannot open (W24: the shell's own line is not
#     reproduced), are `reply NOT delivered`; a stash jq cannot parse ends the
#     run with jq's own line and status (W26)
both seed_side
both stash loc '"local"'
both stash r2 '"999.111"'
both stash obj '{"a":[1,2]}'
both put home/state/remote-inbox/bad.json '{"rid":\n'
both put t.txt 'answer\n'
both put t2.txt 'no final LF'
same reply
assert_eq "$(shim_err)" "ERROR: usage: ac-remote.sh reply <rid> [--text-file <f>]" "row 16: reply usage"
same reply --text-file t.txt
assert_eq "$(shim_err)" "ERROR: unknown reply option: t.txt" "row 16: --text-file as the rid (W25)"
same reply ../x --bogus
assert_eq "$(shim_err)" "ERROR: unknown reply option: --bogus" "row 16: the option error comes first (W25)"
same reply r2 --text-file
same reply r2 "$(printf 'x%.0s' $(seq 1 70))"
assert_eq "$(shim_err)" "ERROR: unknown reply option: $(printf 'x%.0s' $(seq 1 60))..." "row 16: a long option is capped"
R_STDIN="$TMP/rstdin"; printf 'line one\nline two\n' >"$R_STDIN"
same reply loc
assert_eq "$(shim_out)" "replied loc (local thread: HOME/home/state/remote-inbox/loc.replies.md)" "row 16: the local thread"
printf 'no final LF' >"$R_STDIN"
same reply loc
: >"$R_STDIN"
same reply loc
R_STDIN=/dev/null
same reply loc --text-file HOME/t2.txt
same reply loc --text-file HOME/missing.txt
assert_eq "$(shim_err)" "ERROR: text file not found: HOME/missing.txt" "row 16: a missing text file"
each 'chmod 000 "$H/t.txt"'
same reply loc --text-file HOME/t.txt
assert_eq "$SAME_RC" "1" "row 16: an unreadable text file (W23)"
assert_contains "$(shim_tree)" "## 2023-11-14T22:13:$(printf '%02d' $((ROW % 60)))Z
== " "row 16: the dangling header (W23)"
each 'chmod 644 "$H/t.txt"'
assert_eq "$(grep -c '^## ' "$NH/home/state/remote-inbox/loc.replies.md")" "5" "row 16: one header per reply"
same reply r2
assert_eq "$(shim_err)" "ERROR: reply needs a config/remote-reply hook (transport not configured)" "row 16: no reply hook"
each 'printf "#!/bin/sh\n" >"$H/home/config/remote-reply"'
same reply r2
assert_eq "$(shim_err)" "ERROR: config/remote-reply is not executable (chmod +x it)" "row 16: a hook that is not executable"
both hook remote-reply 'hlog reply $#; echo "hook stdout"'
R_STDIN="$TMP/rstdin"; printf 'stdin reply\n' >"$R_STDIN"
same reply r2
assert_eq "$(shim_out)" "hook stdout
replied r2" "row 16: the hook's stdout precedes ours"
R_STDIN=/dev/null
same reply r2 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "reply argc=0 rid=[r2] thread=[999.111] state=[unset] mention=[unset] group=member stdin=616e737765720a" "row 16: env and the text on stdin"
same reply obj --text-file HOME/t.txt
same reply r2 --text-file HOME/missing.txt
each 'chmod 000 "$H/t.txt"'
sides reply r2 --text-file HOME/t.txt
assert_eq "$O_RC $N_RC" "1 1" "row 16: an unreadable text file at the hook (W24)"
assert_eq "$(tail -n 1 "$TMP/o.err2")|$(shim_err)" "ERROR: remote-reply hook failed for r2 (reply NOT delivered)|ERROR: remote-reply hook failed for r2 (reply NOT delivered)" "row 16: read as a hook failure, the shell's redirect line named"
each 'chmod 644 "$H/t.txt"'
both hook remote-reply 'hlog reply $#; exit 3'
same reply r2 --text-file HOME/t.txt
assert_eq "$(shim_err)" "ERROR: remote-reply hook failed for r2 (reply NOT delivered)" "row 16: a failing hook"
same reply bad
assert_eq "$SAME_RC" "5" "row 16: an unparseable stash is jq's status (W26)"
both stash pl '"local"'
both hook remote-reply 'hlog reply $#'
same reply pl --text-file HOME/t.txt
assert_contains "$(shim_tree)" "== ./remote-inbox/pl.replies.md" "row 16: a polled order whose thread is \"local\" never reaches the hook (W22)"

# 18. followup: the LAST remote_request= wins; the live meta first, else the
#     archive meta; none is a WARN, exit 0; an unreadable live meta is
#     metaGet's WARN and exit 1 (W30); a stored rid the guard refuses; a
#     failing hook keeps the link; every line of the key is dropped, a meta
#     link minted ends empty; a local thread appends
both seed_side
both stash r1 '"1712.42"'
both stash loc '"local"'
both hook remote-reply 'hlog reply $#'
both hook remote-ack 'hlog ack $#'
both put t.txt 'landed\n'
same followup
assert_eq "$(shim_err)" "ERROR: usage: ac-remote.sh followup <task-id> [--text-file <f>]" "row 18: followup usage"
same followup t --nope
same followup '../t'
same followup none
assert_eq "$(shim_err)" "WARN: no remote order linked to none (already followed up, or never linked) - nothing sent" "row 18: nothing linked"
both put home/state/t1.meta 'remote_request=gone\nkind=ship\nremote_request=r1\nremote_request_ts=9\nremote_request=r1\n'
same followup t1 --text-file HOME/t.txt
assert_eq "$(shim_out)" "followed up t1 -> r1 (link cleared)" "row 18: the followup line"
assert_contains "$(shim_tree)" "== ./t1.meta -rw-r--r--
kind=ship
== " "row 18: every remote_request line dropped"
same followup t1
both put home/state/archive/t2/meta 'kind=ship\nremote_request=r1\n'
R_STDIN="$TMP/rstdin"; printf 'from stdin\n' >"$R_STDIN"
same followup t2
R_STDIN=/dev/null
both put home/state/t3.meta 'remote_request=../x\n'
same followup t3
assert_eq "$(shim_err)" "ERROR: rid must be [A-Za-z0-9._-]+: '../x'" "row 18: a stored rid the guard refuses"
both put home/state/t4.meta 'remote_request=r1\n'
each 'chmod 000 "$H/home/state/t4.meta"'
same followup t4
assert_eq "$SAME_RC" "1" "row 18: an unreadable live meta (W30)"
each 'chmod 644 "$H/home/state/t4.meta"'
both hook remote-reply 'exit 4'
same followup t4 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "== ./t4.meta -rw-r--r--
remote_request=r1" "row 18: a failed reply keeps the link"
both put home/state/t5.meta 'remote_request=loc\n'
same followup t5 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "== ./remote-inbox/loc.replies.md" "row 18: a local-thread followup appends"

# 19. thread-post through family_send: usage, unknown options (capped), the
#     RID guard on the family (dots pass - W27); no reply hook drains stdin
#     and warns (exit 0, nothing registered); a first post goes top-level with
#     AC_REMOTE_RID=<family> and registers thread_ts/cursor from the ts the
#     hook printed; a later post rides the thread and prints no ts; a first
#     line that is empty (`\n111.1`) is no ts and nothing is registered; an
#     existing empty `.thread` never registers; an unreadable `.thread` is
#     metaGet's WARN and a TOP-LEVEL post, exit 0 (W31); any first line is
#     echoed, even into a known thread (W31); --mention-captain is
#     AC_REMOTE_MENTION=captain, its absence the name set EMPTY (W32); a failing
#     hook; a missing --text-file, and one the redirect cannot open, which
#     reads as a hook failure (W24, the shell's redirect line named)
both seed_side
both put t.txt 'from a file\n'
same thread-post
assert_eq "$(shim_err)" "ERROR: usage: ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]" "row 19: usage"
same thread-post fam --bogus
same thread-post fam "$(printf 'two\nlines')"
assert_eq "$(shim_err)" "ERROR: unknown thread-post option: two..." "row 19: a multi-line option is cut"
same thread-post '../f'
R_STDIN="$TMP/rstdin"; printf 'hello thread\n' >"$R_STDIN"
same thread-post fam
assert_eq "$(shim_out)|$(shim_err)" "|WARN: thread-post: no config/remote-reply hook - fam NOT delivered (transport not configured)" "row 19: no hook"
both hook remote-reply 'hlog fs $#; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
same thread-post a.b
assert_eq "$(shim_out)" "posted a.b (1700.42)" "row 19: a dotted family passes (W27), the first post's ts"
assert_contains "$(shim_tree)" "== ./remote-threads/a.b.thread -rw-r--r--
thread_ts=1700.42
cursor=1700.42" "row 19: the mapping registered"
same thread-post a.b --mention-captain
assert_eq "$(shim_out)" "posted a.b" "row 19: a later post"
assert_contains "$(shim_tree)" "rid=[a.b] thread=[1700.42] state=[unset] mention=[captain]" "row 19: the thread and the mention reach the hook"
assert_contains "$(shim_tree)" "rid=[a.b] thread=[] state=[unset] mention=[] group=member" "row 19: no mention is the name set empty (W32)"
both hook remote-reply 'hlog fs $#; printf "\n111.1\n"'
same thread-post f2
assert_eq "$(shim_err)" "WARN: family thread: f2 posted top-level but the hook printed no ts - thread mapping not recorded" "row 19: an empty first line is no ts"
both put home/state/remote-threads/f3.thread ''
both hook remote-reply 'hlog fs $#; printf "junk\n"'
same thread-post f3
assert_eq "$(shim_out)" "posted f3 (junk)" "row 19: any first line is echoed (W31)"
both put home/state/remote-threads/f4.thread 'thread_ts=9.9\n'
each 'chmod 000 "$H/home/state/remote-threads/f4.thread"'
same thread-post f4
assert_eq "$SAME_RC|$(shim_err)" "0|WARN: cannot read meta file HOME/home/state/remote-threads/f4.thread" "row 19: an unreadable .thread (W31)"
assert_contains "$(shim_tree)" "rid=[f4] thread=[] " "row 19: ... posts top-level"
each 'chmod 644 "$H/home/state/remote-threads/f4.thread"'
R_STDIN=/dev/null
same thread-post f5 --text-file HOME/t.txt
same thread-post f5 --text-file HOME/missing.txt
assert_eq "$(shim_err)" "ERROR: thread-post: no such file: HOME/missing.txt" "row 19: a missing text file"
each 'chmod 000 "$H/t.txt"'
sides thread-post f5 --text-file HOME/t.txt
assert_eq "$O_RC $N_RC" "1 1" "row 19: an unreadable text file (W24)"
assert_eq "$(tail -n 1 "$TMP/o.err2")|$(shim_err)" "ERROR: thread-post: remote-reply hook failed for f5 - text NOT delivered|ERROR: thread-post: remote-reply hook failed for f5 - text NOT delivered" "row 19: read as a hook failure"
each 'chmod 644 "$H/t.txt"'
both hook remote-reply 'hlog fs $#; exit 2'
same thread-post f6
assert_eq "$SAME_RC|$(shim_out)" "1|" "row 19: a failing hook prints no confirmation"

# 13b. the reply hook's capture reads to EOF: a hook that exits at once while a
#      child it forked keeps stdout open and prints the ts a second later -
#      both sides wait for it, register it and print it
both hook remote-reply 'hlog fs $#; (sleep 1; printf "1800.1\n") & exit 0'
start=$SECONDS
same thread-post f7
assert_eq "$(shim_out)" "posted f7 (1800.1)" "row 13b: the ts an orphan printed after the hook exited"
[ $((SECONDS - start)) -ge 2 ] || fail "row 13b: both sides waited for the orphan's EOF"

# 21. push-pending: no reply hook is silent; per family with a room, in byte
#     order (the leg runs C; the original's glob followed the caller's
#     collation - ORDER, named), the unanswered GATE/ASK lines (DECIDED
#     settles the oldest, a quoted `> GATE:` is no item, a line cut at a NUL)
#     go out in ONE message - the header and bullet bytes, the TZ'd stamp -
#     with AC_REMOTE_MENTION=captain; an unsafe family name warns every run, a
#     dot dir and an unreadable room are skipped; the stamp dedups a rerun; a
#     failing hook warns and retries next push; the mapping registers on the
#     first post and later pushes ride it; an unreadable stamp is metaGet's
#     WARN and exit 1 (W33); the stamp key is awk's `$1==k`, numeric when both
#     sides look like numbers (`07` reads the `7=` line from byte 4)
both seed_side
room() {  # room <family> <printf format> - a room file under data/
  put "home/data/$1/room.md" "$2"
}
same push-pending
both room fam1 '- [2023-11-14T00:00:01Z] crewchief> GATE: approve the plan\n- [2023-11-14T00:00:02Z] crewchief> ASK (1 of 2): which store?\n'
both room a.b '- [t] c> GATE: one\n- [t] c> DECIDED a.b: ok\n- [t] c> ASK: two\n- [t] c> relay > GATE: quoted\n'
both room 'bad name' '- [t] c> GATE: x\n'
both room .hid '- [t] c> GATE: hidden\n'
both room settled '- [t] c> GATE: x\n- [t] c> DECIDED: y\n'
both room nul '- [t] c> GATE: cut\0 after\n'
both room older '- [t] c> GATE: first\n- [t] c> ASK: second\n- [t] c> DECIDED: settles the oldest\n'
both room unread '- [t] c> GATE: x\n'
each 'chmod 000 "$H/home/data/unread/room.md"'
same push-pending
assert_eq "$(shim_out)" "" "row 21: no hook"
both hook remote-reply 'hlog push $#; [ -n "$AC_REMOTE_THREAD" ] || printf "111.222\n"'
same push-pending
assert_eq "$(shim_out)" "pushed a.b (2 pending)
pushed fam1 (2 pending)
pushed nul (1 pending)
pushed older (1 pending)" "row 21: one line per pushed family, byte order - \`DECIDED a.b:\` settles nothing (the room grammar's word class has no dot)"
assert_contains "$(shim_tree)" "rid=[older] thread=[] state=[unset] mention=[captain] group=member stdin=$(printf '\342\217\263 *[2023-11-15 05:13 TZ=Asia/Ho_Chi_Minh] [\304\220ANG CH\341\273\234 captain] [older]* (1 m\341\273\245c)\n\342\200\242 c> ASK: second\n' | od -An -tx1 | tr -d ' \n')" "row 21: a DECIDED settles the OLDEST open item"
assert_eq "$(shim_err)" "WARN: push-pending: skipped family with unsafe name: bad name" "row 21: the unsafe name"
assert_contains "$(shim_tree)" "push argc=0 rid=[fam1] thread=[] state=[unset] mention=[captain] group=member stdin=$(printf '\342\217\263 *[2023-11-15 05:13 TZ=Asia/Ho_Chi_Minh] [\304\220ANG CH\341\273\234 captain] [fam1]* (2 m\341\273\245c)\n\342\200\242 crewchief> GATE: approve the plan\n\342\200\242 crewchief> ASK (1 of 2): which store?\n' | od -An -tx1 | tr -d ' \n')" "row 21: the message bytes"
same push-pending
assert_eq "$(shim_out)|$(shim_err)" "|WARN: push-pending: skipped family with unsafe name: bad name" "row 21: a rerun is deduped"
both room fam1 '- [2023-11-14T00:00:01Z] crewchief> GATE: approve the plan\n- [2023-11-14T00:00:02Z] crewchief> ASK (1 of 2): which store?\n- [t] c> ASK (2 of 2): which region?\n'
both hook remote-reply 'hlog push $#; exit 3'
same push-pending
assert_contains "$(shim_err)" "WARN: push-pending: remote-reply hook failed for fam1 - kept for the next push" "row 21: a failing hook"
both hook remote-reply 'hlog push $#'
same push-pending
assert_eq "$(shim_out)" "pushed fam1 (3 pending)" "row 21: retried into the registered thread"
assert_contains "$(shim_tree)" "rid=[fam1] thread=[111.222]" "row 21: the later push rides the mapping"
DLC=en_US.UTF-8
both room loc '- [\351] c> GATE: a stamp holding an invalid byte\n'
same push-pending
DLC=C
both room 07 '- [t] c> GATE: seven-oh\n'
both room 7 '- [t] c> GATE: seven-oh\n'
same push-pending
assert_eq "$(shim_out)" "pushed 07 (1 pending)
pushed 7 (1 pending)" "row 21: 7 read 07's line from its 3rd byte (\`=<hash>\`) and pushed too"
same push-pending
assert_eq "$(shim_out)" "pushed 07 (1 pending)
pushed 7 (1 pending)" "row 21: each now reads the other's line, so neither is ever deduped"
each 'chmod 000 "$H/home/state/.remote-push-stamp"'
both room fam9 '- [t] c> GATE: new\n'
same push-pending
assert_eq "$SAME_RC|$(shim_err)" "1|WARN: cannot read meta file HOME/home/state/.remote-push-stamp" "row 21: an unreadable stamp ends the run at the first family with pending lines (W33)"
each 'chmod 644 "$H/home/state/.remote-push-stamp"; chmod 644 "$H/home/data/unread/room.md"'

# 3. poll gates: no hook, a hook that is not executable, a DIRECTORY (`-f`
#    fails) and a symlink to an executable hook (followed)
both seed_side
FEED="$TMP/rfeed"
printf '{"rid":"p1","text":"t","author":"a","thread":"1.1"}\n' >"$FEED"
same poll
assert_eq "$(shim_out)$(shim_err)" "" "row 3: no hook"
both hook remote-poll "hlog poll \$#; cat '$FEED'"
each 'chmod 644 "$H/home/config/remote-poll"'
same poll
each 'mv "$H/home/config/remote-poll" "$H/poll-hook"; chmod +x "$H/poll-hook"; mkdir "$H/home/config/remote-poll"'
same poll
each 'rmdir "$H/home/config/remote-poll"; ln -s "$H/poll-hook" "$H/home/config/remote-poll"'
same poll
assert_eq "$(shim_out)" "remote-order p1" "row 3: a symlinked hook runs"
assert_contains "$(shim_tree)" "poll argc=0 rid=[unset] thread=[unset] state=[unset] mention=[unset] group=member stdin=" "row 3: no args, no env, our process group, stdin /dev/null"

# 4. poll hook outcomes: a failing hook's stdout is never ingested and its
#    stderr's first line is quoted, capped at 60 BYTES under C and 60
#    CHARACTERS under UTF-8, an invalid byte one (W13); empty stderr; a hook
#    its own TERM ended (143); a bad interpreter is bash's 126 whose text is
#    each side's own shell (W12, named) - a missing or a directory interpreter
#    under an exported SHELLOPTS too; a shebang-less hook runs as a script;
#    a successful hook's stderr is replayed after it ended, byte for byte; a
#    TMPDIR mktemp cannot use ends poll with mktemp's own line (W11)
both seed_side
both hook remote-poll "echo '{\"rid\":\"pf\",\"text\":\"t\",\"author\":\"a\",\"thread\":\"1\"}'; exit 7"
same poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 7) - skipping this poll" "row 4: exit 7"
both hook remote-poll 'echo "curl: (7) Failed to connect to slack.com port 443" >&2; exit 1'
same poll
both hook remote-poll "printf 'x%.0s' \$(seq 1 61) >&2; printf '\\n' >&2; exit 1"
same poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): $(printf 'x%.0s' $(seq 1 60))... - skipping this poll" "row 4: 61 bytes capped"
both hook remote-poll "printf '\\303\\251%.0s' \$(seq 1 59) >&2; printf 'ab\\351c\\nsecond\\n' >&2; exit 1"
same poll
DLC=en_US.UTF-8
same poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): $(printf '\303\251%.0s' $(seq 1 59))a... - skipping this poll" "row 4: 60 characters under UTF-8 (W13)"
DLC=C
both hook remote-poll 'printf "short\n" >&2; exit 1'
same poll
both hook remote-poll 'exit 1'
same poll
both hook remote-poll 'kill -TERM $$'
same poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 143) - skipping this poll" "row 4: a TERMed hook"
each 'printf "#!%s/nointerp\n" "$TMP" >"$H/home/config/remote-poll"'
sides poll
assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")$(shim_out)" "0 0 " "row 4: a bad interpreter (W12)"
assert_contains "$(oracle_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: the oracle quotes its own shell"
assert_contains "$(shim_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: the shim quotes the bash it started"
# ... and with SHELLOPTS exported (the entry's errexit inherited by the
# launcher): an interpreter that is missing, and one that is a DIRECTORY, are
# 126 on both sides too
R_ENV=("SHELLOPTS=braceexpand:hashall:interactive-comments")
for interp in nointerp interpdir; do
  each 'mkdir -p "$H/interpdir"; printf "#!%s/%s\n" "$H" "'"$interp"'" >"$H/home/config/remote-poll"'
  sides poll
  assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")$(shim_out)" "0 0 " "row 4: interpreter $interp under an exported SHELLOPTS"
  assert_contains "$(oracle_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: the oracle's 126 ($interp)"
  assert_contains "$(shim_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: the shim's 126 ($interp)"
done
R_ENV=()
each 'printf ". \"%s\"; hlog noshe \$#; cat \"%s\"\n" "$TMP/hooklog.sh" "$FEED" >"$H/home/config/remote-poll"'
same poll
assert_eq "$(shim_out)" "remote-order p1" "row 4: a shebang-less hook runs as a script"
each 'rm -f "$H/home/state/remote-inbox/p1.json"'
both hook remote-poll "printf 'warn one\\nwarn \\351 two' >&2; cat '$FEED'; printf '{\"rid\":\"../x\",\"text\":\"t\",\"author\":\"a\",\"thread\":\"1\"}\\n'"
same poll
assert_eq "$(shim_err)" "$(printf 'warn one\nwarn \351 two')WARN: remote-poll: refused rid (must be [A-Za-z0-9._-]+): ../x" "row 4: the hook's stderr, then the core's"
R_ENV=("TMPDIR=HOME/nope")
same poll
assert_contains "$(shim_err)" "mktemp: mkstemp failed on HOME/nope/ac-remote-poll-err." "row 4: TMPDIR (W11)"
assert_eq "$SAME_RC" "1" "row 4: poll exits 1 there"
R_ENV=()

# 5. the line grammar, through poll AND ingest, an ack hook logging each
#    `ingested` edge: blank lines skipped; a duplicate inside one batch; the
#    rid guard (all dots, a blank, a slash, a non-ASCII rid - refused under C;
#    the original's bash range let it through under UTF-8, ORDER/charset
#    rule, named); jq decides the rest - a number rid, a bare number, an array,
#    a missing thread are malformed; two objects on one line are ONE rid
#    `m1<LF>m2` refused on two lines (W5); `1 {valid}` is ingested with jq's
#    error twice on stderr; `{valid} 7` is malformed; an escaped rid stashes
#    the raw line; NaN text and a duplicate key pass (the last rid wins);
#    thread 1.0, a bigint, false, an object reach the hook as jq prints them
#    (W6); a CRLF line keeps its CR (W10); an unterminated last line is read
grammar() {
  printf '{"rid":"g1","text":"t","author":"a","thread":"1.1"}\n\n'
  printf '{"rid":"g1","text":"dup","author":"a","thread":"1.1"}\n'
  printf '{"rid":"%s","text":"t","author":"a","thread":"1"}\n' . .. ... 'a b' '../x' 'caf\303\251'
  printf '{"rid":5,"text":"t","author":"a","thread":"1"}\n3\n[1]\n'
  printf '{"rid":"m1","text":"t","author":"a","thread":"1"} {"rid":"m2","text":"t","author":"a","thread":"1"}\n'
  printf '1 {"rid":"g2","text":"t","author":"a","thread":"2"}\n'
  printf '{"rid":"g3","text":"t","author":"a","thread":"3"} 7\n'
  printf '{"rid":"g4","text":"t","author":"a"}\n'
  printf '{"rid":"\\u0071\\u0033","text":"t","author":"a","thread":"q"}\n'
  printf '{"rid":"g5","text":"t","author":"a","thread":1.0}\n'
  printf '{"rid":"g6","text":"t","author":"a","thread":100000000000000000001}\n'
  printf '{"rid":"g7","text":"t","author":"a","thread":false}\n'
  printf '{"rid":"g8","text":"t","author":"a","thread":{"x":[1,2]}}\n'
  printf '{"rid":"g9","text":NaN,"author":"a","thread":"9"}\n'
  printf '{"rid":"x","rid":"g10","text":"t","author":"a","thread":"10"}\n'
  printf '{"rid":"g11","text":"t","author":"a","thread":"11"}\r\n'
  printf '{"rid":"g12","text":"t","author":"a","thread":"12"}'
}
grammar >"$FEED"
both seed_side
both hook remote-ack 'hlog ack $#'
both hook remote-poll "cat '$FEED'"
same poll
assert_eq "$(shim_out)" "remote-order g1
remote-order g2
remote-order q3
remote-order g5
remote-order g6
remote-order g7
remote-order g8
remote-order g9
remote-order g10
remote-order g11
remote-order g12" "row 5: the ingested rids, in order"
assert_contains "$(shim_tree)" "$(printf '== ./remote-inbox/g11.json -rw-r--r--\n{"rid":"g11","text":"t","author":"a","thread":"11"}\r')" "row 5: a CRLF line is stashed with its CR (W10)"
assert_contains "$(shim_err)" "WARN: remote-poll: refused rid (must be [A-Za-z0-9._-]+): m1
m2" "row 5: two objects on one line (W5)"
assert_contains "$(shim_tree)" "rid=[g8] thread=[{
  \"x\": [
    1,
    2
  ]
}]" "row 5: an object thread as jq prints it (W6)"
both seed_side
both hook remote-ack 'hlog ack $#'
R_STDIN="$FEED"
same ingest
assert_contains "$(shim_err)" "WARN: ingest: skipped a malformed line (need JSON {rid,text,author,thread})" "row 5: ingest's label"
R_STDIN=/dev/null

# 6. a NUL byte: `read` cut the line there, so ingest takes the order; poll's
#    capture dropped it, so the same bytes are malformed there (W9)
printf '{"rid":"n1","text":"t","author":"a","thread":"1"}\0junk\n' >"$FEED"
both seed_side
R_STDIN="$FEED"
same ingest
assert_eq "$(shim_out)" "remote-order n1" "row 6: ingest cuts at the NUL"
R_STDIN=/dev/null
both hook remote-poll "cat '$FEED'"
both seed_side
both hook remote-poll "cat '$FEED'"
same poll
assert_eq "$(shim_out)|$(shim_err)" "|WARN: remote-poll: skipped a malformed line (need JSON {rid,text,author,thread})" "row 6: poll's capture dropped it"

# 7. the commit's failures: a spool path a file sits on (mkdir's own line, the
#    stash rolled back, the record's temp left as litter, exit 1); an inbox
#    the stash temp cannot be written in (exit 1; the shell's redirect line
#    is not reproduced, the shim names the path and errno - named); a rid too
#    long for the temp's name ends the batch there, later lines unread (W8);
#    a DANGLING symlink at the stash is no stash to `-e` and blocks the link,
#    so that rid is silently skipped for ever (W7); a publish that fails on
#    the 2nd rid of a batch rolls that stash back and ends the run, naming
#    the batch, the 1st rid committed and printed
both seed_side
put_feed() { printf "$@" >"$FEED"; }
put_feed '{"rid":"w1","text":"t","author":"a","thread":"1"}\n'
both put home/state/.wake-spool 'a file\n'
R_STDIN="$FEED"
same ingest
assert_eq "$SAME_RC" "1" "row 7: the publish failed"
assert_contains "$(shim_err)" "File exists
ERROR: ingest: no wake could be published for w1 - NOT ingested. Re-send it AND anything after it in the same batch: this exits before reading the rest" "row 7: mkdir's line, then the refusal"
assert_contains "$(shim_tree)" "== ./.wake-tmp.RANDOM -rw-------" "row 7: the record's temp is litter"
each 'rm -f "$H/home/state/.wake-spool" "$H"/home/state/.wake-tmp.*'
each 'chmod 555 "$H/home/state/remote-inbox"'
sides ingest
assert_eq "$O_RC $N_RC" "1 1" "row 7: an inbox the temp cannot be written in"
assert_contains "$(oracle_err)" "Permission denied" "row 7: the oracle's shell-own line"
assert_eq "$(shim_err)" "ERROR: cannot write HOME/home/state/remote-inbox/.stash.w1.PID: EACCES" "row 7: the shim's own line"
each 'chmod 755 "$H/home/state/remote-inbox"'
long="$(printf 'L%.0s' $(seq 1 250))"
put_feed '{"rid":"%s","text":"t","author":"a","thread":"1"}\n{"rid":"after","text":"t","author":"a","thread":"1"}\n' "$long"
sides ingest
assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")$(shim_out)" "1 1 " "row 7: an overlong rid ends the batch (W8)"
[ ! -e "$NH/home/state/remote-inbox/after.json" ] && [ ! -e "$OH/home/state/remote-inbox/after.json" ] || fail "row 7: the line after it is never read"
assert_contains "$(shim_err)" "ENAMETOOLONG" "row 7: the shim names the errno"
each 'ln -s "$H/nowhere" "$H/home/state/remote-inbox/d1.json"'
put_feed '{"rid":"d1","text":"t","author":"a","thread":"1"}\n'
same ingest
assert_eq "$(shim_out)$(shim_err)" "" "row 7: a dangling stash link skips the rid silently (W7)"
put_feed '{"rid":"s1","text":"t","author":"a","thread":"1"}\n{"rid":"s2","text":"t","author":"a","thread":"2"}\n{"rid":"s3","text":"t","author":"a","thread":"3"}\n'
cat >"$TMP/seam-nth" <<'SEAM'
#!/bin/sh
n=$(cat "$R_SIDE/seam-n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$R_SIDE/seam-n"
[ "$n" -lt 2 ] || chmod 500 "$R_SIDE/home/state/.wake-spool"
SEAM
chmod +x "$TMP/seam-nth"
R_ENV=("AC_WAKE_SEAM_AT=after-write" "AC_WAKE_SEAM_RUN=$TMP/seam-nth")
same ingest
assert_eq "$SAME_RC|$(shim_out)" "1|remote-order s1" "row 7: the first rid committed and printed"
assert_eq "$(shim_err)" "ERROR: ingest: no wake could be published for s2 - NOT ingested. Re-send it AND anything after it in the same batch: this exits before reading the rest" "row 7: the second rolled back"
R_ENV=()
R_STDIN=/dev/null
each 'chmod 755 "$H/home/state/.wake-spool"'

# 10b. a batch at AC_REMOTE_ACK_BUDGET=2 against a hung ack hook: ONE call,
#      reaped at 2s, then ONE budget warning for the rest of the round
both seed_side
both hook remote-ack 'hlog ack $#; sleep 30'
put_feed '{"rid":"b%s","text":"t","author":"a","thread":"t"}\n' 1 2 3 4 5
R_STDIN="$FEED"
R_ENV=("AC_REMOTE_ACK_TIMEOUT=2" "AC_REMOTE_ACK_BUDGET=2")
same ingest
assert_eq "$(shim_err)" "WARN: ingest: remote-ack hook timed out after 2s for b1 (ingested)
WARN: ingest: remote-ack budget (2s) spent this round - skipping remaining acks" "row 10b: one call, one budget warning"
R_ENV=()
R_STDIN=/dev/null

# 8. order: the text is the LAST positional (W14) unless --text-file gives
#    one; --text-file with no value, a missing file or a directory, a file cat
#    cannot read (cat's line and status); whitespace-only and empty text are
#    refused by `tr -d '[:space:]'` under the caller's locale - NBSP is space
#    only under UTF-8, an invalid byte is tr's own `Illegal byte sequence`
#    there, refusing when nothing precedes it (W16); a file's trailing LFs
#    and NULs are dropped and its bytes reach jq as given - jq escapes
#    controls and DEL, keeps U+2028 raw and decodes an invalid sequence its
#    own way (W15); a text past ARG_MAX fails jq's exec, exit 1, nothing
#    stashed (W17 - each side's shell words that differently, named); a
#    failing date ends the run with its status
both seed_side
both put f/lf.txt 'line\n\n\n'
both put f/nul.txt 'a\0b\n'
both put f/e9.txt 'a\351b'
both put f/sur.txt 'a\355\240\200b'
both put f/c080.txt 'a\300\200b'
both put f/tail.txt 'a\342\202'
both put f/ctl.txt 'del\177 esc\033 cr\r tab\t ls\342\200\250 q" bs\\ u\001'
both put f/nbsp.txt '\302\240'
both put f/inv.txt '\351'
both put f/invtext.txt 'hello\351'
both put f/ws.txt ' \t\n'
same order 'please harden the widget'
assert_eq "$(shim_out)" "remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID
no live fleet watcher right now - local-2023$(printf '%04d' "$ROW")T000000Z-PID waits in the spool until a chief session drains it (bin/ac-wake-drain.sh, or the next session-start)" "row 8: the two lines"
same order a b
assert_contains "$(shim_tree)" '"text":"b",' "row 8: the last positional wins (W14)"
same order --text-file
same order --text-file ''
same order --text-file HOME/f
same order --text-file HOME/missing
each 'chmod 000 "$H/f/lf.txt"'
same order --text-file HOME/f/lf.txt
assert_eq "$SAME_RC" "1" "row 8: an unreadable file is cat's status"
each 'chmod 644 "$H/f/lf.txt"'
same order ''
assert_eq "$(shim_err)" "ERROR: order needs its text: ac-remote.sh order [--text-file <f>] ['<text>']" "row 8: empty text"
same order '   '
same order --text-file HOME/f/ws.txt
for f in lf nul e9 sur c080 tail ctl nbsp inv invtext; do same order positional --text-file "HOME/f/$f.txt"; done
DLC=en_US.UTF-8
for f in nbsp inv invtext e9; do same order --text-file "HOME/f/$f.txt"; done
assert_contains "$(shim_tree)" "$(printf '"text":"a\357\277\275b"')" "row 8: jq's replacement character"
DLC=C
head -c 2000000 /dev/zero | tr '\0' 'a' >"$TMP/big.txt"
sides order --text-file "$TMP/big.txt"
assert_eq "$O_RC $N_RC $(cat "$TMP/o.out")$(shim_out)" "1 1 " "row 8: a text past ARG_MAX (W17)"
assert_contains "$(oracle_err)$(shim_err)" "Argument list too long" "row 8: ... each side's shell says so"
R_ENV=("DATE_FAIL=4")
same order x
assert_eq "$SAME_RC" "4" "row 8: a failing date"
R_ENV=()
sides order "$(printf 'a\355\240\200b')"
assert_contains "$(shim_tree)" "$(printf '"text":"a\357\277\275\357\277\275\357\277\275b"')" "row 8: argv arrives decoded - three U+FFFD (named)"
assert_contains "$(cat "$TMP/o.tree")" "$(printf '"text":"a\357\277\275b"')" "row 8: the original's jq made one"

# 9. order's watcher line: printed with no lock, a dead pid, a live pid that
#    is no watcher; not printed when the lock's pid runs an `ac-watch` command
both seed_side
each 'mkdir -p "$H/home/state/.watch.lock.d"; printf "999999\n" >"$H/home/state/.watch.lock.d/pid"'
same order x
assert_contains "$(shim_out)" "no live fleet watcher" "row 9: a dead pid"
each 'printf "%s\n" "$$" >"$H/home/state/.watch.lock.d/pid"'
same order x
assert_contains "$(shim_out)" "no live fleet watcher" "row 9: a live pid that is no watcher"
bash -c 'exec -a ac-watch-standin sleep 30' &
standin=$!
each 'printf "%s\n" "$standin" >"$H/home/state/.watch.lock.d/pid"'
same order x
kill "$standin" 2>/dev/null || true; wait "$standin" 2>/dev/null || true
assert_eq "$(shim_out)" "remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID" "row 9: a live watcher - one line"
# The ported watcher's command line names /src/watch.ts, never ac-watch.
bash -c 'exec -a "bun --no-env-file /x/src/watch.ts /x" sleep 30' &
standin=$!
each 'printf "%s\n" "$standin" >"$H/home/state/.watch.lock.d/pid"'
same order x
kill "$standin" 2>/dev/null || true; wait "$standin" 2>/dev/null || true
assert_eq "$(shim_out)" "remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID" "row 9: a live ported watcher - one line"

# 13. the poll hook's capture reads to EOF: the hook exits at once and the
#     child it forked prints the order a second later - both sides wait for
#     it and ingest it
both seed_side
both hook remote-poll "(sleep 1; cat '$FEED') & exit 0"
put_feed '{"rid":"e1","text":"t","author":"a","thread":"1"}\n'
start=$SECONDS
same poll
assert_eq "$(shim_out)" "remote-order e1" "row 13: the order an orphan printed after the hook exited"
[ $((SECONDS - start)) -ge 2 ] || fail "row 13: both sides waited for the orphan's EOF"

# The mechanics rows run each side by hand, every wait bounded.
side_bin() { [ "$1" = "$OH" ] && printf '%s' "$obin" || printf '%s' "$BIN"; }
wait_for() {  # wait_for <file> <secs> - until the file exists, at most secs
  local i=0; while [ ! -e "$1" ] && [ "$i" -lt $(($2 * 10)) ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]
}
reap_pidfile() { local p; p="$(cat "$1" 2>/dev/null || true)"; [ -z "$p" ] || kill -9 "$p" 2>/dev/null || true; }

# 11. the reap shape (W21): a poll started in its own process group, its ack
#     hook hanging on the one rid - a TERM to the poll's GROUP (the watcher's
#     reap) kills the poll hook's group and the entry, never the ack hook,
#     which leads its own; the stash and wake are committed, the
#     `remote-order` line never printed - on both sides
put_feed '{"rid":"e1","text":"t","author":"a","thread":"1"}\n'
for h in "$OH" "$NH"; do
  H="$h"; seed_side
  hook remote-poll "cat '$FEED'"
  hook remote-ack "echo \$\$ >'$h/ack.pid'; sleep 30"
  set -m
  (cd "$h" && env -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET LC_ALL=C AC_HOME="$h/home" R_LOG="$h/log/hooks" \
    "$(side_bin "$h")/ac-remote.sh" poll >"$h/poll.out" 2>"$h/poll.err") &
  rpid=$!
  set +m
  wait_for "$h/ack.pid" 15 || { kill -9 -"$rpid" 2>/dev/null || true; fail "row 11: the ack hook never started on $h"; }
  kill -TERM -"$rpid" 2>/dev/null || true
  wait "$rpid" 2>/dev/null || true
  ack="$(cat "$h/ack.pid")"
  kill -0 "$ack" 2>/dev/null || fail "row 11: the ack hook leads its own group and outlives the reap (W21) on $h"
  kill -9 "$ack" 2>/dev/null || true
  assert_eq "$(cat "$h/poll.out")" "" "row 11: no remote-order line on $h"
  assert_file "$h/home/state/remote-inbox/e1.json" "row 11: the stash committed on $h"
  grep -q 'remote-order e1' "$h/home/state/.wake-spool"/* || fail "row 11: the wake committed on $h"
done

# 12. SIGINT: inside the stash-to-wake window the entry and every child it
#     starts there ignore INT - a wake seam that sends a group-wide INT
#     survives it (it writes its marker after) and the order commits whole;
#     outside the window an INT ends the entry at once, its ack hook hanging -
#     on both sides
cat >"$TMP/seam-int" <<'SEAM'
#!/bin/sh
pgid=$(ps -o pgid= -p $$ | tr -d ' ')
kill -INT -"$pgid" 2>/dev/null || true
sleep 0.3
echo survived >"$R_SIDE/seam-survived"
SEAM
chmod +x "$TMP/seam-int"
for h in "$OH" "$NH"; do
  H="$h"; seed_side
  set -m
  (cd "$h" && env AC_HOME="$h/home" R_SIDE="$h" AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$TMP/seam-int" \
    "$(side_bin "$h")/ac-remote.sh" order 'interrupted inside the window' >"$h/int.out" 2>&1) &
  rpid=$!
  set +m
  wait "$rpid" 2>/dev/null || true
  assert_file "$h/seam-survived" "row 12: a child started inside the window ignores INT on $h"
  rid="$(ls "$h/home/state/remote-inbox" | sed -n 's/^\(local-[^.]*\)\.json$/\1/p')"
  [ -n "$rid" ] || fail "row 12: no stash on $h"
  grep -q "remote-order $rid" "$h/home/state/.wake-spool"/* || fail "row 12: the wake committed with the stash on $h"
  assert_contains "$(cat "$h/int.out")" "remote-order $rid" "row 12: the entry went on past the window on $h"
  hook remote-ack "echo \$\$ >'$h/ack.pid'; sleep 30"
  set -m
  (cd "$h" && env AC_HOME="$h/home" AC_REMOTE_ACK_TIMEOUT=8 "$(side_bin "$h")/ac-remote.sh" order 'interrupted in its ack' >"$h/int2.out" 2>&1) &
  rpid=$!
  set +m
  wait_for "$h/ack.pid" 15 || { kill -9 -"$rpid" 2>/dev/null || true; fail "row 12: the ack never started on $h"; }
  began=$SECONDS
  kill -INT -"$rpid" 2>/dev/null || true
  wait "$rpid" 2>/dev/null || true
  [ $((SECONDS - began)) -lt 4 ] || fail "row 12: an INT outside the window ends the entry at once on $h"
  reap_pidfile "$h/ack.pid"
done

# 14. ingest reads each line as it arrives: a writer holding the pipe open
#     sends line 1, waits for its `remote-order` on the output, then sends
#     line 2 - an entrance that read to EOF first would starve the writer
for h in "$OH" "$NH"; do
  H="$h"; seed_side
  rm -f "$h/in"; mkfifo "$h/in"
  (cd "$h" && env AC_HOME="$h/home" "$(side_bin "$h")/ac-remote.sh" ingest <"$h/in" >"$h/stream.out" 2>&1) &
  rpid=$!
  {
    printf '{"rid":"st1","text":"t","author":"a","thread":"1"}\n'
    i=0; until grep -q 'remote-order st1' "$h/stream.out" 2>/dev/null || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
    grep -q 'remote-order st1' "$h/stream.out" && printf '{"rid":"st2","text":"t","author":"a","thread":"1"}\n'
  } >"$h/in"
  wait "$rpid" 2>/dev/null || true
  assert_eq "$(cat "$h/stream.out")" "remote-order st1
remote-order st2" "row 14: line 1 answered before line 2 was sent on $h"
done

# 23. a symlinked AC_HOME: every path the entry prints is the physical one
#     (cd && pwd -P on both sides)
both seed_side
both stash loc '"local"'
each 'ln -s "$H/home" "$H/homelink"'
R_ENV=("AC_HOME=HOME/homelink")
same reply loc
assert_eq "$(shim_out)" "replied loc (local thread: HOME/home/state/remote-inbox/loc.replies.md)" "row 23: the physical path"
R_ENV=()

# 24. a planted symlink at a predictable temp name (W36, the EXCLUSIVE TEMP
#     rule, named): the original wrote its stash temp `.stash.<rid>.<$$>` and
#     its meta temp `<meta>.tmp.<$$>` THROUGH it; the port creates each temp
#     exclusively, moves to the next name, and leaves the planted link and its
#     target alone. The entry is started with its pid known (sh's `$$`, which
#     the exec into bash and then bun keeps).
planted() {  # planted <bin> <side> <args...> - the run with symlinks planted at its two temp names
  local bin="$1" h="$2"; shift 2
  (cd "$h" && env -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET AC_HOME="$h/home" LC_ALL=C PATH="$RSTUB:$PATH" R_ROW="$ROW" \
    /bin/sh -c 'ln -s "$0/victim" "$0/home/state/remote-inbox/.stash.pl1.$$"; ln -s "$0/victim2" "$0/home/state/t9.meta.tmp.$$"; exec "$@"' \
    "$h" "$bin/ac-remote.sh" "$@") <"$FEED" >>"$h/planted.out" 2>&1
}
both seed_side
each 'mkdir -p "$H/home/state/remote-inbox"'
put_feed '{"rid":"pl1","text":"t","author":"a","thread":"1"}\n'
ROW=$((ROW + 1))
for h in "$OH" "$NH"; do planted "$(side_bin "$h")" "$h" ingest; planted "$(side_bin "$h")" "$h" link t9 pl1; done
assert_eq "$(cat "$NH/planted.out")" "remote-order pl1
linked t9 -> pl1" "row 24: the shim ingests and links past the planted names"
[ ! -e "$NH/victim" ] && [ ! -e "$NH/victim2" ] || fail "row 24: the shim never writes through a planted temp"
[ -f "$NH/home/state/remote-inbox/pl1.json" ] && [ ! -L "$NH/home/state/remote-inbox/pl1.json" ] || fail "row 24: the stash is a regular file"
[ -f "$NH/home/state/t9.meta" ] && [ ! -L "$NH/home/state/t9.meta" ] || fail "row 24: the meta is a regular file"
assert_eq "$(find "$NH/home/state" -name '*.stash.*' -o -name '*.tmp.*' | while read -r f; do [ -L "$f" ] && echo link || echo file; done | sort | uniq -c | tr -s ' ')" " 4 link" "row 24: the four planted links are left as they were, no temp of the shim's own"
assert_eq "$(cat "$OH/victim")" '{"rid":"pl1","text":"t","author":"a","thread":"1"}' "row 24: the original wrote the stash temp through the link (W36)"
assert_contains "$(cat "$OH/victim2")" "remote_request=pl1" "row 24: and the meta temp (W36)"

# 25. an inherited BASH_ENV (a file printing a line on stdout and on stderr):
#     each side's own bash entry sources it once at start, and nothing between
#     the entry and a hook may source it again - the hook is started through a
#     shell that reads no startup file, as the original's `"$hook"` was. A
#     first family post registers the hook's ts (never the file's line), a
#     threaded post rides the mapping, poll ingests exactly the hook's lines,
#     an ack hook's stderr is its own, and the hook still finds BASH_ENV. With
#     SHELLOPTS exported too, a #!/bin/bash hook gets it unchanged - the
#     entry's own `set -euo pipefail` in it, the ack's `monitor` from its
#     launch under `set -m` - so it reads its OWN BASH_ENV, which supplies a
#     setting it requires, on both sides; an exported BASH_VERSION changes
#     none of it
both seed_side
both put benv.sh 'printf "startup-noise\n"; printf "startup-noise-err\n" >&2\n'
R_ENV=("BASH_ENV=HOME/benv.sh")
both hook remote-reply 'hlog fs $#; printf "benv=%s\n" "${BASH_ENV-unset}" >>"$R_LOG"; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
R_STDIN="$TMP/rstdin"; printf 'first post\n' >"$R_STDIN"
same thread-post famb
assert_eq "$(shim_out)" "startup-noise
posted famb (1700.42)" "row 25: the entry's own start sourced it once; the ts is the hook's"
assert_contains "$(shim_tree)" "== ./remote-threads/famb.thread -rw-r--r--
thread_ts=1700.42
cursor=1700.42" "row 25: the mapping is the hook's ts"
assert_contains "$(shim_tree)" "benv=HOME/benv.sh" "row 25: the hook still finds BASH_ENV"
same thread-post famb --mention-captain
assert_eq "$(shim_out)" "startup-noise
posted famb" "row 25: a threaded post"
R_STDIN=/dev/null
put_feed '{"rid":"bv1","text":"t","author":"a","thread":"7.7"}\n'
both hook remote-poll "cat '$FEED'"
both hook remote-ack 'hlog ack $#; printf "ack stderr\n" >&2'
same poll
assert_eq "$(shim_out)|$(shim_err)" "startup-noise
remote-order bv1|startup-noise-err
ack stderr" "row 25: poll ingests the hook's lines alone; the ack's stderr is its own"
both put benv2.sh 'hook_setting=ready\n'
bhook() {  # bhook <name> <bash body> - a #!/bin/bash hook that requires its own BASH_ENV's setting
  printf '#!/bin/bash\n[ "${hook_setting-}" = ready ] || { echo "%s: no hook_setting" >&2; exit 9; }\nprintf "%%s so=%%s pid-leads=%%s\\n" "%s" "${SHELLOPTS-}" "$([ "$(ps -o pgid= -p $$ | tr -d " ")" = "$$" ] && echo y || echo n)" >>"$R_LOG"\n%s\n' "$1" "$1" "$2" >"$H/home/config/$1"
  chmod +x "$H/home/config/$1"
}
R_ENV=("BASH_ENV=HOME/benv2.sh" "SHELLOPTS=braceexpand:hashall:interactive-comments")
both bhook remote-reply 'cat >/dev/null; [ -n "$AC_REMOTE_THREAD" ] || printf "1800.9\n"'
both bhook remote-ack 'exit 0'
put_feed '{"rid":"bv2","text":"t","author":"a","thread":"8.8"}\n'
both bhook remote-poll "cat '$FEED'"
R_STDIN="$TMP/rstdin"; printf 'post\n' >"$R_STDIN"
same thread-post famso
assert_eq "$(shim_out)" "posted famso (1800.9)" "row 25: a #!/bin/bash hook ran with its own setting"
same thread-post famso
R_STDIN=/dev/null
same poll
assert_eq "$(shim_out)" "remote-order bv2" "row 25: poll's and the ack's #!/bin/bash hooks ran"
assert_contains "$(shim_tree)" "remote-ack so=braceexpand:errexit:hashall:interactive-comments:monitor:nounset:pipefail pid-leads=y" "row 25: the ack's SHELLOPTS as the original's, and it leads its group"
assert_contains "$(shim_tree)" "remote-poll so=braceexpand:errexit:hashall:interactive-comments:nounset:pipefail pid-leads=n" "row 25: the poll hook's SHELLOPTS, in the entry's group"
R_ENV+=("BASH_VERSION=3.2.57(1)-release")
both seed_side
both put benv2.sh 'hook_setting=ready\n'
both bhook remote-reply 'cat >/dev/null; [ -n "$AC_REMOTE_THREAD" ] || printf "1800.9\n"'
both bhook remote-ack 'exit 0'
both bhook remote-poll "cat '$FEED'"
R_STDIN="$TMP/rstdin"
same thread-post famso
assert_eq "$(shim_out)" "posted famso (1800.9)" "row 25: an exported BASH_VERSION too"
R_STDIN=/dev/null
same poll
assert_eq "$(shim_out)" "remote-order bv2" "row 25: poll and ack under an exported BASH_VERSION"
assert_contains "$(shim_tree)" "remote-ack so=braceexpand:errexit:hashall:interactive-comments:monitor:nounset:pipefail pid-leads=y" "row 25: the ack's SHELLOPTS and group, unchanged"
R_ENV=()

# 26. META SET runs under ac_meta_set's lock <dir>/.<file>.lock (10 PATH
#     `sleep 1` waits, counted by a stub): against a live holder, link,
#     done-stamp and push-pending's stamp warn `cannot lock meta file <f> -
#     nothing written` and end the run, exit 1; the family send's
#     registration warns once per key and still posts, exit 0; followup's
#     unset took no lock in the original and writes through a held one
both seed_side
mkdir -p "$TMP/rsleep"
printf '#!/bin/sh\necho x >>"$R_SIDE/log/sleeps"\n' >"$TMP/rsleep/sleep"
chmod +x "$TMP/rsleep/sleep"
R_ENV=("PATH=$TMP/rsleep:$RSTUB:$PATH")
held() { mkdir -p "$H/home/state/$1"; printf '%s\n' "$$" >"$H/home/state/$1/pid"; }
sleeps() { assert_eq "$(cat "$OH/log/sleeps" 2>/dev/null | wc -l | tr -d ' ') $(cat "$NH/log/sleeps" 2>/dev/null | wc -l | tr -d ' ')" "$1 $1" "$2"; each 'rm -f "$H/log/sleeps"'; }
both stash r1 '"1.2"'
both put home/state/t1.meta 'pr=x\n'
each 'held .t1.meta.lock'
same link t1 r1
assert_eq "$SAME_RC|$(shim_out)|$(shim_err)" "1||WARN: cannot lock meta file HOME/home/state/t1.meta - nothing written" "row 26: link refuses a held meta lock"
assert_eq "$(cat "$NH/home/state/t1.meta")" "pr=x" "row 26: ...with nothing written"
sleeps 10 "row 26: ...after ten waits"
both put home/state/t1.meta 'remote_request=r1\nremote_request_ts=5\npr=x\n'
both hook remote-reply 'hlog fs $#; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
same followup t1
assert_eq "$SAME_RC|$(cat "$NH/home/state/t1.meta")" "0|pr=x" "row 26: followup's unset writes through the held lock"
sleeps 0 "row 26: ...without waiting"
each 'held ..landing-receipt-stamp.lock'
same done-stamp famz
assert_eq "$SAME_RC|$(shim_out)|$(shim_err)" "1||WARN: cannot lock meta file HOME/home/state/.landing-receipt-stamp - nothing written" "row 26: done-stamp refuses a held stamp lock"
sleeps 10 "row 26: ...after ten waits"
each 'held remote-threads/.f1.thread.lock'
same thread-post f1
assert_eq "$SAME_RC|$(shim_out)|$(shim_err)" "0|posted f1 (1700.42)|WARN: cannot lock meta file HOME/home/state/remote-threads/f1.thread - nothing written
WARN: cannot lock meta file HOME/home/state/remote-threads/f1.thread - nothing written" "row 26: the registration warns per key and the post stands"
sleeps 20 "row 26: ...ten waits per key"
both room fam1 '- [t] c> GATE: one\n'
each 'held ..remote-push-stamp.lock'
same push-pending
assert_eq "$SAME_RC|$(shim_out)|$(shim_err)" "1||WARN: cannot lock meta file HOME/home/state/.remote-push-stamp - nothing written" "row 26: push-pending's stamp refuses a held lock after the send"
sleeps 10 "row 26: ...after ten waits"
R_ENV=()

pass
