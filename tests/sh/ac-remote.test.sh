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

# --- the CLI contract, row by row ---------------------------------------------
# One side root ($NH): a home at $NH/home whose config/ holds the row's fake
# hooks (each logging its argc, the AC_REMOTE_* names, whether it leads its
# process group and its stdin bytes to $NH/log/hooks), TMPDIR=$NH/tmp; a
# `date` stub answering every shape the entry runs (the stamps moved per row)
# FIRST on PATH; LC_ALL=C unless the row names a locale; argv, env and stdin
# (the side root spelled HOME); cwd the side root. What a run printed, every
# entry under $NH/home/state (names, modes, link targets and bytes) and the
# hook log read the side root HOME, the distro root ROOT and a pid PID.
NH="$TMP/rside"
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
H="$NH"
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
RC=0
norm() {  # norm - stdin with the side root spelled HOME, the distro root ROOT, pids PID, temp suffixes RANDOM
  LC_ALL=C sed -e "s#$NH#HOME#g" -e "s#$ROOT#ROOT#g" \
    -e 's/local-\([0-9TZ]*\)-[0-9][0-9]*/local-\1-PID/g' -e 's/\.[0-9][0-9]*\.\([0-9]\{6\}\)/.PID.\1/g' \
    -e 's/\.wake-tmp\.[A-Za-z0-9]\{8\}/.wake-tmp.RANDOM/g' -e 's/\.tmp\.[0-9][0-9]*/.tmp.PID/g' \
    -e 's/ac-remote-poll-err\.[A-Za-z0-9]\{6\}/ac-remote-poll-err.RANDOM/g' -e 's/\(\.stash\..*\)\.[0-9][0-9]*:/\1.PID:/'
}
snap() {  # snap - every entry under home/state in byte order (name, mode, link, bytes), then the hook log
  [ ! -d "$NH/home/state" ] || (cd "$NH/home/state" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s %s\n' "$f" "$(ls -ld "$f" | cut -c1-10)"
    [ ! -L "$f" ] || printf -- '-> %s\n' "$(readlink "$f")"
    [ ! -f "$f" ] || [ ! -r "$f" ] || cat "$f"
  done)
  printf '== hooks\n'; cat "$NH/log/hooks" 2>/dev/null || true
}
rrun() {  # rrun <args...> - the shim at the side root; HOME in an arg or an env value is the side root; sets RC
  local x v a=() e=(LC_ALL="$DLC" TMPDIR="$NH/tmp" PATH="$RSTUB:$PATH" R_LOG="$NH/log/hooks" R_SIDE="$NH")
  ROW=$((ROW + 1))
  e+=(R_ROW="$ROW")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$NH/home")
  for x in ${R_ENV[@]+"${R_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$NH}"); done
  for x in "$@"; do a+=("${x//HOME/$NH}"); done
  RC=0
  (cd "$NH" && env -u AC_HOME -u AC_SCOPE -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET -u EPOCHSECONDS \
    -u AC_WAKE_SEAM_AT -u AC_WAKE_SEAM_RUN -u LANG -u LC_CTYPE -u TZ "${e[@]}" "$BIN/ac-remote.sh" ${a[@]+"${a[@]}"}) \
    <"$R_STDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || RC=$?
  norm <"$TMP/n.raw" >"$TMP/n.out"; norm <"$TMP/n.err" >"$TMP/n.err2"
  snap | norm >"$TMP/n.tree"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
shim_tree() { cat "$TMP/n.tree"; }
refused() {  # refused <stderr> <label> - the last run: exit 1, no stdout, exactly that stderr
  assert_eq "$RC|$(shim_out)|$(shim_err)" "1||$1" "$2"
}
rid_refused() { refused "ERROR: rid must be [A-Za-z0-9._-]+: '$1'" "$2"; }   # rid_refused <rid> <label>
NO_HOME_TEXT="$(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)"
SPEC_HEAD="$(sed -n '/^\/\//!q; s#^// \{0,1\}##p' "$ROOT/src/remote.ts")"
# The narrow PATH a jq-less row runs: what the entry needs before its jq check.
mkdir -p "$TMP/rnojq"
for t in bash dirname cat mkdir bun; do ln -s "$(command -v "$t")" "$TMP/rnojq/$t"; done
seed_side

# 1. usage: no verb, -h and an unknown verb print the module's spec header on
#    stdout, exit 2; homeless the preamble refuses first (NO_HOME, exit 1); a
#    PATH with no jq refuses every argv, homeless too
for v in "" -h bogus; do
  if [ -z "$v" ]; then rrun; else rrun "$v"; fi
  assert_eq "$RC" "2" "row 1: '$v' is usage, exit 2"
  assert_eq "$(cat "$TMP/n.raw")" "$SPEC_HEAD" "row 1: '$v' prints the module's spec header"
  assert_eq "$(shim_err)" "" "row 1: nothing on stderr"
done
HOMELESS=1
rrun
refused "ERROR: $NO_HOME_TEXT" "row 1: homeless usage is the home refusal"
R_ENV=("PATH=$TMP/rnojq")
rrun show r1
refused "ERROR: required tool not found: jq" "row 1: no jq, homeless"
HOMELESS=0
rm -rf "$H/home/state"
rrun show r1
refused "ERROR: required tool not found: jq" "row 1: no jq, homed"
R_ENV=()

# 2. the root pointer state/.ac-root: written when absent or different, left
#    alone when equal (trailing LFs read away), written THROUGH a symlink; a
#    pointer that cannot be written ends every verb, show included, the shim
#    naming the path and errno; an AC_HOME cd cannot enter is the physicalDir
#    refusal
seed_side
rrun show r1
refused "ERROR: no stashed remote order: r1" "row 2: show of an absent rid"
assert_contains "$(shim_tree)" "== ./.ac-root -rw-r--r--
ROOT" "row 2: a fresh pointer"
printf '%s\n\n\n' "$ROOT" >"$H/home/state/.ac-root"
chmod 444 "$H/home/state/.ac-root"
rrun show r1
assert_contains "$(shim_tree)" "== ./.ac-root -r--r--r--
ROOT


" "row 2: an equal pointer with trailing LFs is never rewritten"
chmod 644 "$H/home/state/.ac-root"
put home/state/.ac-root '/elsewhere\n'
rrun show r1
assert_contains "$(shim_tree)" "== ./.ac-root -rw-r--r--
ROOT" "row 2: a different pointer is rewritten"
rm -f "$H/home/state/.ac-root"
put home/state/target 'old\n'
ln -s "$H/home/state/target" "$H/home/state/.ac-root"
rrun show r1
assert_contains "$(shim_tree)" "== ./target -rw-r--r--
ROOT" "row 2: written through a symlink"
rm -f "$H/home/state/.ac-root" "$H/home/state/target"
mkdir -p "$H/home/state/.ac-root"
rrun show r1
refused "ERROR: cannot write HOME/home/state/.ac-root: EISDIR" "row 2: a pointer that is a directory ends show"
rmdir "$H/home/state/.ac-root"
chmod 555 "$H/home/state"
rrun show r1
refused "ERROR: cannot write HOME/home/state/.ac-root: EACCES" "row 2: a read-only state/ ends show"
chmod 755 "$H/home/state"
R_ENV=("AC_HOME=HOME/nope")
rrun show r1
refused "ERROR: AC_HOME is not a readable directory: HOME/nope" "row 2: an AC_HOME cd cannot enter"
R_ENV=()

# 15. show: usage, the rid guard (all-dot, slash, blank and non-ASCII rids
#     refused under C and UTF-8), absent, extra args ignored, the stash's raw
#     bytes, an unreadable stash (cat's status)
seed_side
stash r1 '"1.2"'
put home/state/remote-inbox/rb.json 'raw \351 \0 bytes'
rrun show
refused "ERROR: usage: ac-remote.sh show <rid>" "row 15: show usage"
for r in ../x . .. ... 'a b' 'caf\303\251'; do
  rrun show "$(printf "$r")"
  rid_refused "$(printf "$r")" "row 15: show refuses '$r'"
done
DLC=en_US.UTF-8
rrun show "$(printf 'caf\303\251')"
rid_refused "café" "row 15: the guard reads its text under UTF-8 too"
DLC=C
rrun show r1 extra args
assert_eq "$RC|$(shim_out)" '0|{"rid":"r1","text":"t","author":"a","thread":"1.2"}' "row 15: the stash printed"
rrun show rb
assert_eq "$RC" "0" "row 15: a raw stash shows"
cmp -s "$TMP/n.raw" "$H/home/state/remote-inbox/rb.json" || fail "row 15: show prints the stash's bytes as they are"
chmod 000 "$H/home/state/remote-inbox/r1.json"
rrun show r1
assert_eq "$RC|$(shim_out)" "1|" "row 15: an unreadable stash is cat's status"
chmod 644 "$H/home/state/remote-inbox/r1.json"

# 20. done-stamp: usage, the guard, a new family, a failing date stamping an
#     empty value; a stamp the rewrite cannot read is a refusal
seed_side
rrun done-stamp
refused "ERROR: usage: ac-remote.sh done-stamp <family>" "row 20: done-stamp usage"
rrun done-stamp ../evil
rid_refused "../evil" "row 20: the guard"
rrun done-stamp famz
assert_eq "$RC|$(shim_out)" "0|done-stamped famz" "row 20: done-stamp's line"
assert_eq "$(cat "$H/home/state/.landing-receipt-stamp")" "famz=$((1700000000 + ROW))" "row 20: the stamp"
R_ENV=("DATE_FAIL=3")
rrun done-stamp famq
assert_contains "$(shim_tree)" "famq=
" "row 20: a failing date stamps an empty value"
R_ENV=()
chmod 000 "$H/home/state/.landing-receipt-stamp"
rrun done-stamp famz
refused "ERROR: cannot rewrite HOME/home/state/.landing-receipt-stamp: EACCES" "row 20: an unreadable stamp is refused"
rm -f "$H/home/state/.landing-receipt-stamp"

# W28: the META SET key match is a LITERAL "<key>=" prefix, never a BRE - a
# dotted family's own stamp must never drop an unrelated "aXb=" line.
printf 'aXb=999\n' >"$H/home/state/.landing-receipt-stamp"
rrun done-stamp 'a.b'
assert_eq "$RC|$(shim_out)" "0|done-stamped a.b" "row 20: W28 a dotted family stamps"
assert_eq "$(cat "$H/home/state/.landing-receipt-stamp")" "aXb=999
a.b=$((1700000000 + ROW))" "row 20: W28 an unrelated aXb= stamp survives a.b's own write"
rm -f "$H/home/state/.landing-receipt-stamp"

# 22. gc: --days missing / not digits / an unknown option (its first line
#     quoted); ages either side of the 14-day default (find's -mtime +N is
#     floor(age/86400) > N); links in a live meta and an archive meta protect;
#     a 20-digit window makes find fail and nothing prunes; 08 is eight days
seed_side
rrun gc --days
refused "ERROR: --days needs a number" "row 22: --days needs a value"
for d in 1x -1; do
  rrun gc --days "$d"
  refused "ERROR: --days must be a whole number: $d" "row 22: --days $d"
done
rrun gc --bogus
refused "ERROR: unknown gc option: --bogus" "row 22: an unknown option"
rrun gc "$(printf 'a\nb')"
refused "ERROR: unknown gc option: a..." "row 22: a multi-line option, its first line"
rrun gc
assert_eq "$RC|$(shim_out)" "0|" "row 22: no inbox"
aged() {  # aged <rid> <age as -v args to date>
  stash "$1" '"1"'; touch -t "$(date -v"$2" -v"$3" +%Y%m%d%H%M.%S)" "$H/home/state/remote-inbox/$1.json"
}
gc_world() {
  aged young -13d -23H; aged edge -14d -1H; aged old -15d -1H; aged olda -15d -1H; aged oldb -15d -1H
  put home/state/t1.meta 'remote_request=olda\n'
  put home/state/archive/t2/meta 'remote_request=oldb\n'
}
gc_world
rrun gc --days 99999999999999999999
assert_eq "$RC|$(shim_out)" "0|" "row 22: a 20-digit window prunes nothing"
rrun gc --days 08
assert_contains "$(shim_out)" "pruned old" "row 22: 08 is eight days"
gc_world
rrun gc
assert_eq "$RC|$(shim_out)" "0|pruned old" "row 22: the default prunes only the unlinked order past 14 days"
for r in young edge olda oldb; do assert_contains "$(shim_tree)" "== ./remote-inbox/$r.json" "row 22: $r survives"; done

# 10. the lifecycle-ack hook, through `ack`: absent; its argc, env, stdin
#     (/dev/null), stdout (discarded) and its OWN process group; failing,
#     KILLed; a DIRECTORY passes `[ -x ]` and fails to run; a shebang-less hook
#     runs as a script; budget 0 warns at the first edge; timeout 0 reaps at
#     once; timeout 02 is kept as written; a hung hook is reaped at the timeout
#     with its own stderr passing; the timeout is clamped to the budget left
seed_side
stash r1 '"1712.99"'
rrun ack r1 working
assert_eq "$RC|$(shim_out)" "0|acked r1 (working)" "row 10: no hook"
hook remote-ack 'hlog ack $#; echo noise; exit 0'
rrun ack r1 working
assert_contains "$(shim_tree)" "ack argc=0 rid=[r1] thread=[1712.99] state=[working] mention=[unset] group=leader stdin=" "row 10: env, group leader, stdin empty"
assert_eq "$(shim_out)" "acked r1 (working)" "row 10: the hook's stdout is discarded"
hook remote-ack 'exit 1'
rrun ack r1 done
assert_eq "$RC|$(shim_out)|$(shim_err)" "0|acked r1 (done)|WARN: ack: remote-ack hook failed for r1 (done)" "row 10: a failing hook warns once"
hook remote-ack 'kill -KILL $$'
rrun ack r1 done
assert_eq "$(shim_err)" "WARN: ack: remote-ack hook failed for r1 (done)" "row 10: a KILLed hook failed"
unhook remote-ack; mkdir "$H/home/config/remote-ack"
rrun ack r1 done
assert_eq "$RC|$(shim_out)" "0|acked r1 (done)" "row 10: a directory hook"
assert_eq "$(tail -n 1 "$TMP/n.err2")" "WARN: ack: remote-ack hook failed for r1 (done)" "row 10: ... fails to run"
rmdir "$H/home/config/remote-ack"
printf '. "%s"; hlog noshebang $#\n' "$TMP/hooklog.sh" >"$H/home/config/remote-ack"; chmod +x "$H/home/config/remote-ack"
rrun ack r1 working
assert_contains "$(shim_tree)" "noshebang argc=0 rid=[r1]" "row 10: a shebang-less hook runs"
hook remote-ack 'hlog ack $#; printf "own hook stderr\n" >&2; sleep 30'
R_ENV=("AC_REMOTE_ACK_BUDGET=0")
rrun ack r1 working
assert_eq "$(shim_err)" "WARN: ack: remote-ack budget (0s) spent this round - skipping remaining acks" "row 10: budget 0"
# A hook reaped at once races its own first line, so this row's hook says
# nothing.
hook remote-ack 'sleep 30'
R_ENV=("AC_REMOTE_ACK_TIMEOUT=0")
rrun ack r1 working
assert_eq "$(shim_err)" "WARN: ack: remote-ack hook timed out after 0s for r1 (working)" "row 10: timeout 0"
hook remote-ack 'hlog ack $#; printf "own hook stderr\n" >&2; sleep 30'
R_ENV=("AC_REMOTE_ACK_TIMEOUT=02")
rrun ack r1 working
assert_contains "$(shim_err)" "own hook stderr
WARN: ack: remote-ack hook timed out after 02s for r1 (working)" "row 10: a hung hook, its own stderr, the timeout as written"
R_ENV=("AC_REMOTE_ACK_TIMEOUT=5" "AC_REMOTE_ACK_BUDGET=2")
rrun ack r1 working
assert_contains "$(shim_err)" "timed out after 2s for r1" "row 10: the timeout clamped to the budget"
R_ENV=()
unhook remote-ack

# 17. link and ack: usage shapes, the task guard (no all-dot rule), the rid
#     guard, an unstashed rid; link keeps a meta's other keys, stamps an empty
#     value when date fails, and reads "" as the thread of a stash jq cannot
#     parse; a NUL byte in a meta is kept; ack's state is checked before the
#     stash
seed_side
stash r1 '"1.2"'
put home/state/remote-inbox/bad.json 'not json\n'
hook remote-ack 'hlog ack $#'
for a in "" t; do
  if [ -z "$a" ]; then rrun link; else rrun link "$a"; fi
  refused "ERROR: usage: ac-remote.sh link <task-id> <rid>" "row 17: link usage ('$a')"
done
rrun link '../t' r1
refused "ERROR: task id must be [A-Za-z0-9._-]+: '../t'" "row 17: the task guard"
rrun link ... r1
assert_eq "$RC|$(shim_out)" "0|linked ... -> r1" "row 17: an all-dot task id passes the task guard"
rrun link t ..
rid_refused ".." "row 17: the rid guard"
rrun link t nope
refused "ERROR: no stashed remote order: nope (poll first)" "row 17: unstashed"
put home/state/t2.meta 'kind=ship\nremote_request=old\nremote_request_ts=1\nx=y'
rrun link t2 r1
assert_eq "$(cat "$H/home/state/t2.meta")" "kind=ship
x=y
remote_request=r1
remote_request_ts=$((1700000000 + ROW))" "row 17: a meta's other keys kept, the link's keys set last"
put home/state/t4.meta 'kind=ship\n'
R_ENV=("DATE_FAIL=2")
rrun link t4 r1
R_ENV=()
assert_eq "$RC|$(cat "$H/home/state/t4.meta")" "0|kind=ship
remote_request=r1
remote_request_ts=" "row 17: a failing date stamps an empty value"
put home/state/t5.meta 'kind=ship\n'
rrun link t5 bad
assert_contains "$(shim_tree)" "ack argc=0 rid=[bad] thread=[] state=[working]" "row 17: an unparseable stash acks with no thread"
put home/state/t6.meta 'kind=ship\nnote=a\0b\n'
rrun link t6 r1
assert_eq "$RC" "0" "row 17: a meta holding a NUL"
assert_contains "$(shim_tree)" "$(printf 'kind=ship\nnote=a')" "row 17: ... keeps its bytes"
rm -f "$H/home/state/t6.meta"
for a in "" r1; do
  if [ -z "$a" ]; then rrun ack; else rrun ack "$a"; fi
  refused "ERROR: usage: ac-remote.sh ack <rid> <working|done>" "row 17: ack usage ('$a')"
done
rrun ack r1 bogus
refused "ERROR: ack state must be working|done: bogus" "row 17: the state guard"
rrun ack .. done
rid_refused ".." "row 17: ack's rid guard"
rrun ack nope done
refused "ERROR: no stashed remote order: nope" "row 17: ack of an unstashed rid"
rrun ack nope bogus
refused "ERROR: ack state must be working|done: bogus" "row 17: the state is checked before the stash"

# 16. reply: usage; --text-file with no value; a long option capped; a LOCAL
#     thread appends `## <iso>`, the text, LF to <rid>.replies.md - from stdin
#     or a file; a missing text file; a remote thread needs the reply hook
#     (absent / not executable refused), hands it the rid and thread in env
#     and the text on stdin, its stdout ahead of ours; a failing hook, and a
#     --text-file that cannot be opened, are `reply NOT delivered`
seed_side
# "local-t" (not the generic "loc") so the stash's rid itself carries
# order()'s own local-<...> namespace (W22: a THREAD of "local" alone is no
# longer enough to pick the local-write path below).
stash local-t '"local"'
stash r2 '"999.111"'
put t.txt 'answer\n'
put t2.txt 'no final LF'
rrun reply
refused "ERROR: usage: ac-remote.sh reply <rid> [--text-file <f>]" "row 16: reply usage"
rrun reply r2 --text-file
refused "ERROR: --text-file needs a path" "row 16: --text-file with no value"
rrun reply r2 "$(printf 'x%.0s' $(seq 1 70))"
refused "ERROR: unknown reply option: $(printf 'x%.0s' $(seq 1 60))..." "row 16: a long option is capped"
R_STDIN="$TMP/rstdin"; printf 'line one\nline two\n' >"$R_STDIN"
rrun reply local-t
assert_eq "$RC|$(shim_out)" "0|replied local-t (local thread: HOME/home/state/remote-inbox/local-t.replies.md)" "row 16: the local thread"
R_STDIN=/dev/null
rrun reply local-t --text-file HOME/t2.txt
assert_eq "$RC" "0" "row 16: a local reply from a file"
assert_eq "$(cat "$H/home/state/remote-inbox/local-t.replies.md")" "## 2023-11-14T22:13:$(printf '%02d' $(((ROW - 1) % 60)))Z
line one
line two

## 2023-11-14T22:13:$(printf '%02d' $((ROW % 60)))Z
no final LF" "row 16: one header, the text and an LF per reply"
rrun reply local-t --text-file HOME/missing.txt
refused "ERROR: text file not found: HOME/missing.txt" "row 16: a missing text file"
rrun reply r2
refused "ERROR: reply needs a config/remote-reply hook (transport not configured)" "row 16: no reply hook"
printf '#!/bin/sh\n' >"$H/home/config/remote-reply"
rrun reply r2
refused "ERROR: config/remote-reply is not executable (chmod +x it)" "row 16: a hook that is not executable"
hook remote-reply 'hlog reply $#; echo "hook stdout"'
R_STDIN="$TMP/rstdin"; printf 'stdin reply\n' >"$R_STDIN"
rrun reply r2
assert_eq "$RC|$(shim_out)" "0|hook stdout
replied r2" "row 16: the hook's stdout precedes ours"
R_STDIN=/dev/null
rrun reply r2 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "reply argc=0 rid=[r2] thread=[999.111] state=[unset] mention=[unset] group=member stdin=616e737765720a" "row 16: env and the text on stdin"
rrun reply r2 --text-file HOME/missing.txt
refused "ERROR: text file not found: HOME/missing.txt" "row 16: a missing text file at the hook"
chmod 000 "$H/t.txt"
rrun reply r2 --text-file HOME/t.txt
refused "ERROR: remote-reply hook failed for r2 (reply NOT delivered)" "row 16: an unreadable text file is no delivery"
chmod 644 "$H/t.txt"
hook remote-reply 'hlog reply $#; exit 3'
rrun reply r2 --text-file HOME/t.txt
refused "ERROR: remote-reply hook failed for r2 (reply NOT delivered)" "row 16: a failing hook"

# W22: a POLLED order's own transport-assigned thread can legitimately BE the
# text "local" - that is real data, not order()'s sentinel (whose rid always
# starts with local-), so reply must still reach the hook with it, never
# silently take the local-write path and never deliver the reply at all.
hook remote-reply 'hlog reply $#'
stash w22 '"local"'
rrun reply w22
assert_eq "$RC|$(shim_out)" "0|replied w22" "row 16: W22 a polled thread of exactly \"local\" still reaches the hook"
assert_contains "$(shim_tree)" "reply argc=0 rid=[w22] thread=[local]" "row 16: W22 the hook gets the real thread value"

# 18. followup: the LAST remote_request= wins; the live meta first, else the
#     archive meta; none is a WARN, exit 0; an unreadable live meta is
#     metaGet's WARN and exit 1; a stored rid the guard refuses; a failing
#     hook keeps the link; every line of the key is dropped; a local thread
#     appends
seed_side
stash r1 '"1712.42"'
stash local-t '"local"'
hook remote-reply 'hlog reply $#'
hook remote-ack 'hlog ack $#'
put t.txt 'landed\n'
rrun followup
refused "ERROR: usage: ac-remote.sh followup <task-id> [--text-file <f>]" "row 18: followup usage"
rrun followup t --nope
refused "ERROR: unknown followup option: --nope" "row 18: an unknown option"
rrun followup '../t'
refused "ERROR: task id must be [A-Za-z0-9._-]+: '../t'" "row 18: the task guard"
rrun followup none
assert_eq "$RC|$(shim_out)|$(shim_err)" "0||WARN: no remote order linked to none (already followed up, or never linked) - nothing sent" "row 18: nothing linked"
put home/state/t1.meta 'remote_request=gone\nkind=ship\nremote_request=r1\nremote_request_ts=9\nremote_request=r1\n'
rrun followup t1 --text-file HOME/t.txt
assert_eq "$RC|$(shim_out)" "0|followed up t1 -> r1 (link cleared)" "row 18: the followup line"
assert_contains "$(shim_tree)" "== ./t1.meta -rw-r--r--
kind=ship
== " "row 18: every remote_request line dropped"
rrun followup t1
assert_eq "$RC|$(shim_err)" "0|WARN: no remote order linked to t1 (already followed up, or never linked) - nothing sent" "row 18: one follow-up per link"
put home/state/archive/t2/meta 'kind=ship\nremote_request=r1\n'
R_STDIN="$TMP/rstdin"; printf 'from stdin\n' >"$R_STDIN"
rrun followup t2
R_STDIN=/dev/null
assert_eq "$RC|$(shim_out)|$(cat "$H/home/state/archive/t2/meta")" "0|followed up t2 -> r1 (link cleared)|kind=ship" "row 18: the archive meta, cleared"
put home/state/t3.meta 'remote_request=../x\n'
rrun followup t3
refused "ERROR: rid must be [A-Za-z0-9._-]+: '../x'" "row 18: a stored rid the guard refuses"
put home/state/t4.meta 'remote_request=r1\n'
chmod 000 "$H/home/state/t4.meta"
rrun followup t4
assert_eq "$RC|$(shim_err)" "1|WARN: cannot read meta file HOME/home/state/t4.meta" "row 18: an unreadable live meta"
chmod 644 "$H/home/state/t4.meta"
hook remote-reply 'exit 4'
rrun followup t4 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "== ./t4.meta -rw-r--r--
remote_request=r1" "row 18: a failed reply keeps the link"
put home/state/t5.meta 'remote_request=local-t\n'
rrun followup t5 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "== ./remote-inbox/local-t.replies.md" "row 18: a local-thread followup appends"

# 19. thread-post through the family send: usage, unknown options (capped),
#     the rid guard on the family (dots pass); no reply hook drains stdin and
#     warns (exit 0, nothing registered); a first post goes top-level with
#     AC_REMOTE_RID=<family> and registers thread_ts/cursor from the ts the
#     hook printed; a later post rides the thread and prints no ts; a first
#     line that is empty (`\n111.1`) is no ts and nothing is registered;
#     --mention-captain is AC_REMOTE_MENTION=captain, its absence the name set
#     EMPTY; a failing hook; a missing --text-file, and one that cannot be
#     opened, which reads as a hook failure
seed_side
put t.txt 'from a file\n'
rrun thread-post
refused "ERROR: usage: ac-remote.sh thread-post <family> [--text-file <f>] [--mention-captain]" "row 19: usage"
rrun thread-post fam --bogus
refused "ERROR: unknown thread-post option: --bogus" "row 19: an unknown option"
rrun thread-post fam "$(printf 'two\nlines')"
refused "ERROR: unknown thread-post option: two..." "row 19: a multi-line option is cut"
rrun thread-post '../f'
rid_refused "../f" "row 19: the family's guard"
R_STDIN="$TMP/rstdin"; printf 'hello thread\n' >"$R_STDIN"
rrun thread-post fam
assert_eq "$RC|$(shim_out)|$(shim_err)" "0||WARN: thread-post: no config/remote-reply hook - fam NOT delivered (transport not configured)" "row 19: no hook"
hook remote-reply 'hlog fs $#; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
rrun thread-post a.b
assert_eq "$(shim_out)" "posted a.b (1700.42)" "row 19: a dotted family passes, the first post's ts"
assert_contains "$(shim_tree)" "== ./remote-threads/a.b.thread -rw-r--r--
thread_ts=1700.42
cursor=1700.42" "row 19: the mapping registered"
rrun thread-post a.b --mention-captain
assert_eq "$(shim_out)" "posted a.b" "row 19: a later post"
assert_contains "$(shim_tree)" "rid=[a.b] thread=[1700.42] state=[unset] mention=[captain]" "row 19: the thread and the mention reach the hook"
assert_contains "$(shim_tree)" "rid=[a.b] thread=[] state=[unset] mention=[] group=member" "row 19: no mention is the name set empty"
hook remote-reply 'hlog fs $#; printf "\n111.1\n"'
rrun thread-post f2
assert_eq "$RC|$(shim_err)" "0|WARN: family thread: f2 posted top-level but the hook printed no ts - thread mapping not recorded" "row 19: an empty first line is no ts"
[ ! -e "$H/home/state/remote-threads/f2.thread" ] || fail "row 19: ... and nothing is registered"
R_STDIN=/dev/null
rrun thread-post f5 --text-file HOME/t.txt
assert_contains "$(shim_tree)" "fs argc=0 rid=[f5] thread=[] state=[unset] mention=[] group=member stdin=66726f6d20612066696c650a" "row 19: the file's text reaches the hook"
rrun thread-post f5 --text-file HOME/missing.txt
refused "ERROR: thread-post: no such file: HOME/missing.txt" "row 19: a missing text file"
chmod 000 "$H/t.txt"
rrun thread-post f5 --text-file HOME/t.txt
refused "ERROR: thread-post: remote-reply hook failed for f5 - text NOT delivered" "row 19: an unreadable text file reads as a hook failure"
chmod 644 "$H/t.txt"
hook remote-reply 'hlog fs $#; exit 2'
rrun thread-post f6
assert_eq "$RC|$(shim_out)" "1|" "row 19: a failing hook prints no confirmation"

# 13b. the reply hook's capture reads to EOF: a hook that exits at once while a
#      child it forked keeps stdout open and prints the ts a second later -
#      the send waits for it, registers it and prints it
hook remote-reply 'hlog fs $#; (sleep 1; printf "1800.1\n") & exit 0'
start=$SECONDS
rrun thread-post f7
assert_eq "$(shim_out)" "posted f7 (1800.1)" "row 13b: the ts an orphan printed after the hook exited"
[ $((SECONDS - start)) -ge 1 ] || fail "row 13b: the send waited for the orphan's EOF"

# 21. push-pending: no reply hook is silent; per family with a room, in byte
#     order, the unanswered GATE/ASK lines (DECIDED settles the oldest, a
#     quoted `> GATE:` is no item, a line cut at a NUL) go out in ONE message -
#     the header and bullet bytes, the TZ'd stamp - with
#     AC_REMOTE_MENTION=captain; an unsafe family name warns every run, a dot
#     dir and an unreadable room are skipped; the stamp dedups a rerun; a
#     failing hook warns and retries next push; the mapping registers on the
#     first post and later pushes ride it; an unreadable stamp is metaGet's
#     WARN and exit 1
seed_side
room() {  # room <family> <printf format> - a room file under data/
  put "home/data/$1/room.md" "$2"
}
rrun push-pending
room fam1 '- [2023-11-14T00:00:01Z] crewchief> GATE: approve the plan\n- [2023-11-14T00:00:02Z] crewchief> ASK (1 of 2): which store?\n'
room a.b '- [t] c> GATE: one\n- [t] c> DECIDED a.b: ok\n- [t] c> ASK: two\n- [t] c> relay > GATE: quoted\n'
room 'bad name' '- [t] c> GATE: x\n'
room .hid '- [t] c> GATE: hidden\n'
room settled '- [t] c> GATE: x\n- [t] c> DECIDED: y\n'
room nul '- [t] c> GATE: cut\0 after\n'
room older '- [t] c> GATE: first\n- [t] c> ASK: second\n- [t] c> DECIDED: settles the oldest\n'
room unread '- [t] c> GATE: x\n'
chmod 000 "$H/home/data/unread/room.md"
rrun push-pending
assert_eq "$RC|$(shim_out)" "0|" "row 21: no hook"
hook remote-reply 'hlog push $#; [ -n "$AC_REMOTE_THREAD" ] || printf "111.222\n"'
rrun push-pending
assert_eq "$(shim_out)" "pushed a.b (2 pending)
pushed fam1 (2 pending)
pushed nul (1 pending)
pushed older (1 pending)" "row 21: one line per pushed family, byte order - \`DECIDED a.b:\` settles nothing (the room grammar's word class has no dot)"
assert_contains "$(shim_tree)" "rid=[older] thread=[] state=[unset] mention=[captain] group=member stdin=$(printf '\342\217\263 *[2023-11-15 05:13 TZ=Asia/Ho_Chi_Minh] [\304\220ANG CH\341\273\234 captain] [older]* (1 m\341\273\245c)\n\342\200\242 c> ASK: second\n' | od -An -tx1 | tr -d ' \n')" "row 21: a DECIDED settles the OLDEST open item"
assert_eq "$(shim_err)" "WARN: push-pending: skipped family with unsafe name: bad name" "row 21: the unsafe name"
assert_contains "$(shim_tree)" "push argc=0 rid=[fam1] thread=[] state=[unset] mention=[captain] group=member stdin=$(printf '\342\217\263 *[2023-11-15 05:13 TZ=Asia/Ho_Chi_Minh] [\304\220ANG CH\341\273\234 captain] [fam1]* (2 m\341\273\245c)\n\342\200\242 crewchief> GATE: approve the plan\n\342\200\242 crewchief> ASK (1 of 2): which store?\n' | od -An -tx1 | tr -d ' \n')" "row 21: the message bytes"
rrun push-pending
assert_eq "$(shim_out)|$(shim_err)" "|WARN: push-pending: skipped family with unsafe name: bad name" "row 21: a rerun is deduped"
room fam1 '- [2023-11-14T00:00:01Z] crewchief> GATE: approve the plan\n- [2023-11-14T00:00:02Z] crewchief> ASK (1 of 2): which store?\n- [t] c> ASK (2 of 2): which region?\n'
hook remote-reply 'hlog push $#; exit 3'
rrun push-pending
assert_contains "$(shim_err)" "WARN: push-pending: remote-reply hook failed for fam1 - kept for the next push" "row 21: a failing hook"
hook remote-reply 'hlog push $#'
rrun push-pending
assert_eq "$(shim_out)" "pushed fam1 (3 pending)" "row 21: retried into the registered thread"
assert_contains "$(shim_tree)" "rid=[fam1] thread=[111.222]" "row 21: the later push rides the mapping"
chmod 000 "$H/home/state/.remote-push-stamp"
room fam9 '- [t] c> GATE: new\n'
rrun push-pending
assert_eq "$RC|$(shim_err)" "1|WARN: cannot read meta file HOME/home/state/.remote-push-stamp" "row 21: an unreadable stamp ends the run at the first family with pending lines"
chmod 644 "$H/home/state/.remote-push-stamp"; chmod 644 "$H/home/data/unread/room.md"
# A story's room at data/<epic>/<story>/, the dir marked .family (src/brief.ts's
# header owns the layout): the walk reaches the marked level and names the
# story by itself.
put home/data/ep/story/.family ''
room ep/story '- [t] c> GATE: nested\n'
rrun push-pending
assert_eq "$RC" "0" "row 21: NESTED STORY ROOM - exit 0"
assert_contains "$(shim_out)" "pushed story (1 pending)" "row 21: NESTED STORY ROOM - the story's room is pushed, named by the story"

# W37: the family-keyed stamp read is a literal string compare, never awk's
# numeric coercion. A stamp line keyed "7" misaligns, under the numeric
# bug, into something that LOOKS like family "07"'s own hash (the lookup
# slices at the QUERY key's length, not the matched line's), wrongly
# deduping - and so silently dropping - "07"'s very first, legitimate push.
# The hash below is sha256("- [t] c> GATE: w37") - the real pending-lines
# hash push-pending computes for the room seeded below.
seed_side
hook remote-reply 'hlog push $#; [ -n "$AC_REMOTE_THREAD" ] || printf "222.333\n"'
room 07 '- [t] c> GATE: w37\n'
printf '7=ze9e4bb2166c83fbafc673b91467b576dea069401c2fc323cc81e615ce4596be7\n' >"$H/home/state/.remote-push-stamp"
rrun push-pending
assert_eq "$(shim_out)" "pushed 07 (1 pending)" "row 21: W37 family 07's first push is never deduped by a numeric cross-read of family 7's stamp"

# 3. poll gates: no hook, a hook that is not executable, a DIRECTORY (`-f`
#    fails) and a symlink to an executable hook (followed)
seed_side
FEED="$TMP/rfeed"
printf '{"rid":"p1","text":"t","author":"a","thread":"1.1"}\n' >"$FEED"
rrun poll
assert_eq "$RC|$(shim_out)$(shim_err)" "0|" "row 3: no hook"
hook remote-poll "hlog poll \$#; cat '$FEED'"
chmod 644 "$H/home/config/remote-poll"
rrun poll
assert_eq "$RC|$(shim_out)$(shim_err)" "0|" "row 3: a hook that is not executable"
mv "$H/home/config/remote-poll" "$H/poll-hook"; chmod +x "$H/poll-hook"; mkdir "$H/home/config/remote-poll"
rrun poll
assert_eq "$RC|$(shim_out)$(shim_err)" "0|" "row 3: a directory"
rmdir "$H/home/config/remote-poll"; ln -s "$H/poll-hook" "$H/home/config/remote-poll"
rrun poll
assert_eq "$(shim_out)" "remote-order p1" "row 3: a symlinked hook runs"
assert_contains "$(shim_tree)" "poll argc=0 rid=[unset] thread=[unset] state=[unset] mention=[unset] group=member stdin=" "row 3: no args, no env, our process group, stdin /dev/null"

# 4. poll hook outcomes: a failing hook's stdout is never ingested and its
#    stderr's first line is quoted, capped at 60 BYTES under C and 60
#    CHARACTERS under UTF-8; empty stderr; a hook its own TERM ended (143); a
#    bad interpreter is the shell's 126 - a missing or a directory interpreter
#    under an exported SHELLOPTS too; a shebang-less hook runs as a script; a
#    successful hook's stderr is replayed after it ended, byte for byte
seed_side
hook remote-poll "echo '{\"rid\":\"pf\",\"text\":\"t\",\"author\":\"a\",\"thread\":\"1\"}'; exit 7"
rrun poll
assert_eq "$RC|$(shim_out)|$(shim_err)" "0||WARN: remote-poll hook failed (exit 7) - skipping this poll" "row 4: exit 7"
hook remote-poll 'echo "curl: (7) Failed to connect to slack.com port 443" >&2; exit 1'
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): curl: (7) Failed to connect to slack.com port 443 - skipping this poll" "row 4: its stderr quoted"
hook remote-poll "printf 'x%.0s' \$(seq 1 61) >&2; printf '\\n' >&2; exit 1"
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): $(printf 'x%.0s' $(seq 1 60))... - skipping this poll" "row 4: 61 bytes capped"
hook remote-poll "printf '\\303\\251%.0s' \$(seq 1 59) >&2; printf 'ab\\351c\\nsecond\\n' >&2; exit 1"
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): $(printf '\303\251%.0s' $(seq 1 30))... - skipping this poll" "row 4: 60 bytes under C"
DLC=en_US.UTF-8
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): $(printf '\303\251%.0s' $(seq 1 59))a... - skipping this poll" "row 4: 60 characters under UTF-8"
DLC=C
hook remote-poll 'printf "short\n" >&2; exit 1'
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1): short - skipping this poll" "row 4: a short line"
hook remote-poll 'exit 1'
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 1) - skipping this poll" "row 4: empty stderr"
hook remote-poll 'kill -TERM $$'
rrun poll
assert_eq "$(shim_err)" "WARN: remote-poll hook failed (exit 143) - skipping this poll" "row 4: a TERMed hook"
printf '#!%s/nointerp\n' "$TMP" >"$H/home/config/remote-poll"
rrun poll
assert_eq "$RC|$(shim_out)" "0|" "row 4: a bad interpreter"
assert_contains "$(shim_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: ... is the shell's 126"
# ... and with SHELLOPTS exported (the entry's errexit inherited by the
# launcher): an interpreter that is missing, and one that is a DIRECTORY, are
# 126 too
R_ENV=("SHELLOPTS=braceexpand:hashall:interactive-comments")
for interp in nointerp interpdir; do
  mkdir -p "$H/interpdir"; printf '#!%s/%s\n' "$H" "$interp" >"$H/home/config/remote-poll"
  rrun poll
  assert_eq "$RC|$(shim_out)" "0|" "row 4: interpreter $interp under an exported SHELLOPTS"
  assert_contains "$(shim_err)" "WARN: remote-poll hook failed (exit 126): " "row 4: the 126 ($interp)"
done
R_ENV=()
printf '. "%s"; hlog noshe $#; cat "%s"\n' "$TMP/hooklog.sh" "$FEED" >"$H/home/config/remote-poll"
rrun poll
assert_eq "$(shim_out)" "remote-order p1" "row 4: a shebang-less hook runs as a script"
rm -f "$H/home/state/remote-inbox/p1.json"
hook remote-poll "printf 'warn one\\nwarn \\351 two' >&2; cat '$FEED'; printf '{\"rid\":\"../x\",\"text\":\"t\",\"author\":\"a\",\"thread\":\"1\"}\\n'"
rrun poll
assert_eq "$(shim_err)" "$(printf 'warn one\nwarn \351 two')WARN: remote-poll: refused rid (must be [A-Za-z0-9._-]+): ../x" "row 4: the hook's stderr, then the core's"

# 5. the line grammar, through poll AND ingest: blank lines skipped; a
#    duplicate inside one batch; the rid guard; jq decides the rest - a number
#    rid, a bare number, an array, a missing thread are malformed; `1 {valid}`
#    is ingested; `{valid} 7` is malformed; an escaped rid stashes the raw
#    line; NaN text and a duplicate key pass (the last rid wins); an
#    unterminated last line is read
grammar() {
  printf '{"rid":"g1","text":"t","author":"a","thread":"1.1"}\n\n'
  printf '{"rid":"g1","text":"dup","author":"a","thread":"1.1"}\n'
  printf '{"rid":"%s","text":"t","author":"a","thread":"1"}\n' . .. ... 'a b' '../x' 'caf\303\251'
  printf '{"rid":5,"text":"t","author":"a","thread":"1"}\n3\n[1]\n'
  printf '1 {"rid":"g2","text":"t","author":"a","thread":"2"}\n'
  printf '{"rid":"g3","text":"t","author":"a","thread":"3"} 7\n'
  printf '{"rid":"g4","text":"t","author":"a"}\n'
  printf '{"rid":"\\u0071\\u0033","text":"t","author":"a","thread":"q"}\n'
  printf '{"rid":"g9","text":NaN,"author":"a","thread":"9"}\n'
  printf '{"rid":"x","rid":"g10","text":"t","author":"a","thread":"10"}\n'
  printf '{"rid":"g12","text":"t","author":"a","thread":"12"}'
}
grammar >"$FEED"
seed_side
hook remote-ack 'hlog ack $#'
hook remote-poll "cat '$FEED'"
rrun poll
assert_eq "$RC|$(shim_out)" "0|remote-order g1
remote-order g2
remote-order q3
remote-order g9
remote-order g10
remote-order g12" "row 5: the ingested rids, in order"
assert_eq "$(grep -c 'skipped a malformed line' "$TMP/n.err2")" "6" "row 5: an invalid JSON escape, a number rid, a bare number, an array, a trailing 7, a missing thread are malformed"
assert_contains "$(shim_tree)" '== ./remote-inbox/q3.json -rw-r--r--
{"rid":"\u0071\u0033","text":"t","author":"a","thread":"q"}' "row 5: an escaped rid stashes the raw line"
assert_eq "$(grep -c '^ack argc=0' "$H/log/hooks")" "6" "row 5: one ingested ack per new stash"
seed_side
hook remote-ack 'hlog ack $#'
R_STDIN="$FEED"
rrun ingest
assert_eq "$RC|$(shim_out)" "0|remote-order g1
remote-order g2
remote-order q3
remote-order g9
remote-order g10
remote-order g12" "row 5: ingest reads the same lines alike"
assert_contains "$(shim_err)" "WARN: ingest: skipped a malformed line (need JSON {rid,text,author,thread})" "row 5: ingest's label"
R_STDIN=/dev/null

# W5: nothing requires a separator between top-level JSON texts, so two full
# objects can share one line with no internal LF; jq's `.rid` then prints
# one line per value and the fused multi-line "rid" used to be refused as a
# single value - losing BOTH orders. Both must ingest on their own instead.
printf '{"rid":"m1","text":"t","author":"a","thread":"1"}{"rid":"m2","text":"t","author":"a","thread":"2"}\n' >"$FEED"
R_STDIN="$FEED"
rrun ingest
assert_eq "$RC|$(shim_out)" "0|remote-order m1
remote-order m2" "row 5: W5 two full objects fused on one line both ingest"
R_STDIN=/dev/null

# 7. the commit's failures: a spool path a file sits on (the stash rolled
#    back, exit 1); an inbox the stash temp cannot be written in (exit 1, the
#    shim naming the path and errno); a publish that fails on the 2nd rid of a
#    batch rolls that stash back and ends the run, naming the batch, the 1st
#    rid committed and printed
seed_side
put_feed() { printf "$@" >"$FEED"; }
put_feed '{"rid":"w1","text":"t","author":"a","thread":"1"}\n'
put home/state/.wake-spool 'a file\n'
R_STDIN="$FEED"
rrun ingest
assert_eq "$RC|$(shim_out)" "1|" "row 7: the publish failed"
assert_contains "$(shim_err)" "ERROR: ingest: no wake could be published for w1 - NOT ingested. Re-send it AND anything after it in the same batch: this exits before reading the rest" "row 7: the refusal"
[ ! -e "$H/home/state/remote-inbox/w1.json" ] || fail "row 7: the stash is rolled back"
rm -f "$H/home/state/.wake-spool" "$H"/home/state/.wake-tmp.*
chmod 555 "$H/home/state/remote-inbox"
rrun ingest
refused "ERROR: cannot write HOME/home/state/remote-inbox/.stash.w1.PID: EACCES" "row 7: an inbox the temp cannot be written in"
chmod 755 "$H/home/state/remote-inbox"
put_feed '{"rid":"s1","text":"t","author":"a","thread":"1"}\n{"rid":"s2","text":"t","author":"a","thread":"2"}\n{"rid":"s3","text":"t","author":"a","thread":"3"}\n'
cat >"$TMP/seam-nth" <<'SEAM'
#!/bin/sh
n=$(cat "$R_SIDE/seam-n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$R_SIDE/seam-n"
[ "$n" -lt 2 ] || chmod 500 "$R_SIDE/home/state/.wake-spool"
SEAM
chmod +x "$TMP/seam-nth"
R_ENV=("AC_WAKE_SEAM_AT=after-write" "AC_WAKE_SEAM_RUN=$TMP/seam-nth")
rrun ingest
assert_eq "$RC|$(shim_out)" "1|remote-order s1" "row 7: the first rid committed and printed"
assert_eq "$(shim_err)" "ERROR: ingest: no wake could be published for s2 - NOT ingested. Re-send it AND anything after it in the same batch: this exits before reading the rest" "row 7: the second rolled back"
R_ENV=()
R_STDIN=/dev/null
chmod 755 "$H/home/state/.wake-spool"

# W7: a DANGLING stash symlink blocks link(2) exactly like a real stash, but
# existsSync (which follows it) finds no live stash there - that rid must be
# reported every time, never skipped forever in silence.
seed_side
mkdir -p "$H/home/state/remote-inbox"
ln -s "$H/home/state/remote-inbox/w7-missing-target.json" "$H/home/state/remote-inbox/w7.json"
put_feed '{"rid":"w7","text":"t","author":"a","thread":"1"}\n'
R_STDIN="$FEED"
rrun ingest
assert_eq "$RC|$(shim_out)" "0|" "row 7: W7 a dangling stash symlink is not ingested, but not fatal either"
assert_contains "$(shim_err)" "WARN: ingest: w7 not ingested - a broken entry blocks" "row 7: W7 the broken entry is reported"
rrun ingest
assert_contains "$(shim_err)" "WARN: ingest: w7 not ingested - a broken entry blocks" "row 7: W7 reported again on a re-poll, never silently skipped"
R_STDIN=/dev/null

# W8: a rid too long for a file name must refuse ONLY that order - the rest
# of the batch still ingests, instead of dying and leaving every later line
# unread.
seed_side
w8rid="$(printf 'a%.0s' $(seq 1 300))"
put_feed '{"rid":"%s","text":"t","author":"a","thread":"1"}\n{"rid":"w8b","text":"t","author":"a","thread":"2"}\n' "$w8rid"
R_STDIN="$FEED"
rrun ingest
assert_eq "$RC|$(shim_out)" "0|remote-order w8b" "row 7: W8 the overlong rid is skipped, the rest of the batch still ingests"
assert_contains "$(shim_err)" "WARN: ingest: refused rid (too long for a file name):" "row 7: W8 the overlong rid is reported"
R_STDIN=/dev/null

# 10b. a batch at AC_REMOTE_ACK_BUDGET=2 against a hung ack hook: ONE call,
#      reaped at 2s, then ONE budget warning for the rest of the round
seed_side
hook remote-ack 'hlog ack $#; sleep 30'
put_feed '{"rid":"b%s","text":"t","author":"a","thread":"t"}\n' 1 2 3 4 5
R_STDIN="$FEED"
R_ENV=("AC_REMOTE_ACK_TIMEOUT=2" "AC_REMOTE_ACK_BUDGET=2")
rrun ingest
assert_eq "$(shim_err)" "WARN: ingest: remote-ack hook timed out after 2s for b1 (ingested)
WARN: ingest: remote-ack budget (2s) spent this round - skipping remaining acks" "row 10b: one call, one budget warning"
R_ENV=()
R_STDIN=/dev/null

# 8. order: the text from --text-file; --text-file with no value, a missing
#    file or a directory, a file cat cannot read (cat's status); whitespace-only
#    and empty text are refused; a text past ARG_MAX fails jq's exec, exit 1,
#    nothing stashed; a failing date ends the run with its status; argv
#    arrives decoded, a byte that is not UTF-8 one U+FFFD each
seed_side
put f/lf.txt 'line\n\n\n'
put f/ws.txt ' \t\n'
rrun order 'please harden the widget'
assert_eq "$RC|$(shim_out)" "0|remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID
no live fleet watcher right now - local-2023$(printf '%04d' "$ROW")T000000Z-PID waits in the spool until a chief session drains it (bin/ac-wake-drain.sh, or the next session-start)" "row 8: the two lines"
rrun order --text-file HOME/f/lf.txt
assert_contains "$(shim_tree)" '"text":"line","author":"captain","thread":"local"}' "row 8: a file's trailing LFs dropped"
for a in "" "''"; do
  if [ -z "$a" ]; then rrun order --text-file; else rrun order --text-file ''; fi
  refused "ERROR: --text-file needs a path" "row 8: --text-file with no value ($a)"
done
rrun order --text-file HOME/f
refused "ERROR: text file not found: HOME/f" "row 8: a directory"
rrun order --text-file HOME/missing
refused "ERROR: text file not found: HOME/missing" "row 8: a missing file"
chmod 000 "$H/f/lf.txt"
rrun order --text-file HOME/f/lf.txt
assert_eq "$RC|$(shim_out)" "1|" "row 8: an unreadable file is cat's status"
chmod 644 "$H/f/lf.txt"
for a in "" '   ' file; do
  if [ "$a" = file ]; then rrun order --text-file HOME/f/ws.txt; else rrun order "$a"; fi
  refused "ERROR: order needs its text: ac-remote.sh order [--text-file <f>] ['<text>']" "row 8: no text ('$a')"
done
head -c 2000000 /dev/zero | tr '\0' 'a' >"$TMP/big.txt"
stashes="$(ls "$H/home/state/remote-inbox")"
rrun order --text-file "$TMP/big.txt"
assert_eq "$RC|$(shim_out)" "1|" "row 8: a text past ARG_MAX"
assert_eq "$(ls "$H/home/state/remote-inbox")" "$stashes" "row 8: ... nothing stashed"
R_ENV=("DATE_FAIL=4")
rrun order x
assert_eq "$RC|$(shim_out)" "4|" "row 8: a failing date"
R_ENV=()
rrun order "$(printf 'a\355\240\200b')"
assert_contains "$(shim_tree)" "$(printf '"text":"a\357\277\275\357\277\275\357\277\275b"')" "row 8: argv arrives decoded - three U+FFFD"

# 9. order's watcher line: printed with no lock, a dead pid, a live pid that
#    is no watcher; not printed when the lock's pid runs an `ac-watch` command
seed_side
mkdir -p "$H/home/state/.watch.lock.d"; printf '999999\n' >"$H/home/state/.watch.lock.d/pid"
rrun order x
assert_contains "$(shim_out)" "no live fleet watcher" "row 9: a dead pid"
printf '%s\n' "$$" >"$H/home/state/.watch.lock.d/pid"
rrun order x
assert_contains "$(shim_out)" "no live fleet watcher" "row 9: a live pid that is no watcher"
bash -c 'exec -a ac-watch-standin sleep 30' &
standin=$!
printf '%s\n' "$standin" >"$H/home/state/.watch.lock.d/pid"
rrun order x
kill "$standin" 2>/dev/null || true; wait "$standin" 2>/dev/null || true
assert_eq "$(shim_out)" "remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID" "row 9: a live watcher - one line"
# The ported watcher's command line names /src/watch.ts, never ac-watch.
bash -c 'exec -a "bun --no-env-file /x/src/watch.ts /x" sleep 30' &
standin=$!
printf '%s\n' "$standin" >"$H/home/state/.watch.lock.d/pid"
rrun order x
kill "$standin" 2>/dev/null || true; wait "$standin" 2>/dev/null || true
assert_eq "$(shim_out)" "remote-order local-2023$(printf '%04d' "$ROW")T000000Z-PID" "row 9: a live ported watcher - one line"

# 13. the poll hook's capture reads to EOF: the hook exits at once and the
#     child it forked prints the order a second later - poll waits for it
#     and ingests it
seed_side
hook remote-poll "(sleep 1; cat '$FEED') & exit 0"
put_feed '{"rid":"e1","text":"t","author":"a","thread":"1"}\n'
start=$SECONDS
rrun poll
assert_eq "$(shim_out)" "remote-order e1" "row 13: the order an orphan printed after the hook exited"
[ $((SECONDS - start)) -ge 1 ] || fail "row 13: poll waited for the orphan's EOF"

# The mechanics rows run the entry by hand, every wait bounded.
wait_for() {  # wait_for <file> <secs> - until the file exists, at most secs
  local i=0; while [ ! -e "$1" ] && [ "$i" -lt $(($2 * 10)) ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]
}
reap_pidfile() { local p; p="$(cat "$1" 2>/dev/null || true)"; [ -z "$p" ] || kill -9 "$p" 2>/dev/null || true; }

# 11. the reap shape: a poll started in its own process group, its ack hook
#     hanging on the one rid - a TERM to the poll's GROUP (the watcher's reap)
#     kills the poll hook's group and the entry, never the ack hook, which
#     leads its own; the stash and wake are committed, the `remote-order` line
#     never printed
put_feed '{"rid":"e1","text":"t","author":"a","thread":"1"}\n'
seed_side
hook remote-poll "cat '$FEED'"
hook remote-ack "echo \$\$ >'$H/ack.pid'; sleep 30"
set -m
(cd "$H" && env -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET LC_ALL=C AC_HOME="$H/home" R_LOG="$H/log/hooks" \
  "$BIN/ac-remote.sh" poll >"$H/poll.out" 2>"$H/poll.err") &
rpid=$!
set +m
wait_for "$H/ack.pid" 15 || { kill -9 -"$rpid" 2>/dev/null || true; fail "row 11: the ack hook never started"; }
kill -TERM -"$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null || true
ack="$(cat "$H/ack.pid")"
kill -0 "$ack" 2>/dev/null || fail "row 11: the ack hook leads its own group and outlives the reap"
kill -9 "$ack" 2>/dev/null || true
assert_eq "$(cat "$H/poll.out")" "" "row 11: no remote-order line"
assert_file "$H/home/state/remote-inbox/e1.json" "row 11: the stash committed"
grep -q 'remote-order e1' "$H/home/state/.wake-spool"/* || fail "row 11: the wake committed"

# 12. SIGINT: inside the stash-to-wake window the entry and every child it
#     starts there ignore INT - a wake seam that sends a group-wide INT
#     survives it (it writes its marker after) and the order commits whole;
#     outside the window an INT ends the entry at once, its ack hook hanging
cat >"$TMP/seam-int" <<'SEAM'
#!/bin/sh
pgid=$(ps -o pgid= -p $$ | tr -d ' ')
kill -INT -"$pgid" 2>/dev/null || true
sleep 0.3
echo survived >"$R_SIDE/seam-survived"
SEAM
chmod +x "$TMP/seam-int"
seed_side
set -m
(cd "$H" && env AC_HOME="$H/home" R_SIDE="$H" AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$TMP/seam-int" \
  "$BIN/ac-remote.sh" order 'interrupted inside the window' >"$H/int.out" 2>&1) &
rpid=$!
set +m
wait "$rpid" 2>/dev/null || true
assert_file "$H/seam-survived" "row 12: a child started inside the window ignores INT"
rid="$(ls "$H/home/state/remote-inbox" | sed -n 's/^\(local-[^.]*\)\.json$/\1/p')"
[ -n "$rid" ] || fail "row 12: no stash"
grep -q "remote-order $rid" "$H/home/state/.wake-spool"/* || fail "row 12: the wake committed with the stash"
assert_contains "$(cat "$H/int.out")" "remote-order $rid" "row 12: the entry went on past the window"
hook remote-ack "echo \$\$ >'$H/ack.pid'; sleep 30"
set -m
(cd "$H" && env AC_HOME="$H/home" AC_REMOTE_ACK_TIMEOUT=8 "$BIN/ac-remote.sh" order 'interrupted in its ack' >"$H/int2.out" 2>&1) &
rpid=$!
set +m
wait_for "$H/ack.pid" 15 || { kill -9 -"$rpid" 2>/dev/null || true; fail "row 12: the ack never started"; }
began=$SECONDS
kill -INT -"$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null || true
[ $((SECONDS - began)) -lt 4 ] || fail "row 12: an INT outside the window ends the entry at once"
reap_pidfile "$H/ack.pid"

# 14. ingest reads each line as it arrives: a writer holding the pipe open
#     sends line 1, waits for its `remote-order` on the output, then sends
#     line 2 - an entrance that read to EOF first would starve the writer
seed_side
rm -f "$H/in"; mkfifo "$H/in"
(cd "$H" && env AC_HOME="$H/home" "$BIN/ac-remote.sh" ingest <"$H/in" >"$H/stream.out" 2>&1) &
rpid=$!
{
  printf '{"rid":"st1","text":"t","author":"a","thread":"1"}\n'
  i=0; until grep -q 'remote-order st1' "$H/stream.out" 2>/dev/null || [ "$i" -ge 100 ]; do sleep 0.1; i=$((i + 1)); done
  grep -q 'remote-order st1' "$H/stream.out" && printf '{"rid":"st2","text":"t","author":"a","thread":"1"}\n'
} >"$H/in"
wait "$rpid" 2>/dev/null || true
assert_eq "$(cat "$H/stream.out")" "remote-order st1
remote-order st2" "row 14: line 1 answered before line 2 was sent"

# 23. a symlinked AC_HOME: every path the entry prints is the physical one
seed_side
stash local-t '"local"'
ln -s "$H/home" "$H/homelink"
R_ENV=("AC_HOME=HOME/homelink")
rrun reply local-t
assert_eq "$(shim_out)" "replied local-t (local thread: HOME/home/state/remote-inbox/local-t.replies.md)" "row 23: the physical path"
R_ENV=()

# 24. a planted symlink at a predictable temp name (the EXCLUSIVE TEMP rule):
#     the stash temp `.stash.<rid>.<pid>` and the meta temp `<meta>.tmp.<pid>`
#     are created exclusively, the next name taken, and the planted link and
#     its target left alone. The entry is started with its pid known (sh's
#     `$$`, which the exec into bash and then bun keeps).
planted() {  # planted <args...> - the run with symlinks planted at its two temp names
  (cd "$H" && env -u AC_REMOTE_ACK_TIMEOUT -u AC_REMOTE_ACK_BUDGET AC_HOME="$H/home" LC_ALL=C PATH="$RSTUB:$PATH" R_ROW="$ROW" \
    /bin/sh -c 'ln -s "$0/victim" "$0/home/state/remote-inbox/.stash.pl1.$$"; ln -s "$0/victim2" "$0/home/state/t9.meta.tmp.$$"; exec "$@"' \
    "$H" "$BIN/ac-remote.sh" "$@") <"$FEED" >>"$H/planted.out" 2>&1
}
seed_side
mkdir -p "$H/home/state/remote-inbox"
put_feed '{"rid":"pl1","text":"t","author":"a","thread":"1"}\n'
ROW=$((ROW + 1))
planted ingest; planted link t9 pl1
assert_eq "$(cat "$H/planted.out")" "remote-order pl1
linked t9 -> pl1" "row 24: ingest and link go past the planted names"
[ ! -e "$H/victim" ] && [ ! -e "$H/victim2" ] || fail "row 24: nothing is written through a planted temp"
[ -f "$H/home/state/remote-inbox/pl1.json" ] && [ ! -L "$H/home/state/remote-inbox/pl1.json" ] || fail "row 24: the stash is a regular file"
[ -f "$H/home/state/t9.meta" ] && [ ! -L "$H/home/state/t9.meta" ] || fail "row 24: the meta is a regular file"
assert_eq "$(find "$H/home/state" -name '*.stash.*' -o -name '*.tmp.*' | while read -r f; do [ -L "$f" ] && echo link || echo file; done | sort | uniq -c | tr -s ' ')" " 4 link" "row 24: the four planted links are left as they were, no temp of the entry's own"

# 25. an inherited BASH_ENV (a file printing a line on stdout and on stderr):
#     the bash shim sources it once at start, and nothing between the entry
#     and a hook may source it again - the hook is started through a shell
#     that reads no startup file. A first family post registers the hook's ts
#     (never the file's line), a threaded post rides the mapping, poll
#     ingests exactly the hook's lines, an ack hook's stderr is its own, and
#     the hook still finds BASH_ENV. With SHELLOPTS exported too, a
#     #!/bin/bash hook gets it unchanged - the entry's own `set -euo pipefail`
#     in it, the ack's `monitor` from its launch under `set -m` - so it reads
#     its OWN BASH_ENV, which supplies a setting it requires; an exported
#     BASH_VERSION changes none of it
seed_side
put benv.sh 'printf "startup-noise\n"; printf "startup-noise-err\n" >&2\n'
R_ENV=("BASH_ENV=HOME/benv.sh")
hook remote-reply 'hlog fs $#; printf "benv=%s\n" "${BASH_ENV-unset}" >>"$R_LOG"; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
R_STDIN="$TMP/rstdin"; printf 'first post\n' >"$R_STDIN"
rrun thread-post famb
assert_eq "$(shim_out)" "startup-noise
posted famb (1700.42)" "row 25: the shim's own start sourced it once; the ts is the hook's"
assert_contains "$(shim_tree)" "== ./remote-threads/famb.thread -rw-r--r--
thread_ts=1700.42
cursor=1700.42" "row 25: the mapping is the hook's ts"
assert_contains "$(shim_tree)" "benv=HOME/benv.sh" "row 25: the hook still finds BASH_ENV"
rrun thread-post famb --mention-captain
assert_eq "$(shim_out)" "startup-noise
posted famb" "row 25: a threaded post"
R_STDIN=/dev/null
put_feed '{"rid":"bv1","text":"t","author":"a","thread":"7.7"}\n'
hook remote-poll "cat '$FEED'"
hook remote-ack 'hlog ack $#; printf "ack stderr\n" >&2'
rrun poll
assert_eq "$(shim_out)|$(shim_err)" "startup-noise
remote-order bv1|startup-noise-err
ack stderr" "row 25: poll ingests the hook's lines alone; the ack's stderr is its own"
put benv2.sh 'hook_setting=ready\n'
bhook() {  # bhook <name> <bash body> - a #!/bin/bash hook that requires its own BASH_ENV's setting
  printf '#!/bin/bash\n[ "${hook_setting-}" = ready ] || { echo "%s: no hook_setting" >&2; exit 9; }\nprintf "%%s so=%%s pid-leads=%%s\\n" "%s" "${SHELLOPTS-}" "$([ "$(ps -o pgid= -p $$ | tr -d " ")" = "$$" ] && echo y || echo n)" >>"$R_LOG"\n%s\n' "$1" "$1" "$2" >"$H/home/config/$1"
  chmod +x "$H/home/config/$1"
}
R_ENV=("BASH_ENV=HOME/benv2.sh" "SHELLOPTS=braceexpand:hashall:interactive-comments")
bhook remote-reply 'cat >/dev/null; [ -n "$AC_REMOTE_THREAD" ] || printf "1800.9\n"'
bhook remote-ack 'exit 0'
put_feed '{"rid":"bv2","text":"t","author":"a","thread":"8.8"}\n'
bhook remote-poll "cat '$FEED'"
R_STDIN="$TMP/rstdin"; printf 'post\n' >"$R_STDIN"
rrun thread-post famso
assert_eq "$(shim_out)" "posted famso (1800.9)" "row 25: a #!/bin/bash hook ran with its own setting"
R_STDIN=/dev/null
rrun poll
assert_eq "$(shim_out)" "remote-order bv2" "row 25: poll's and the ack's #!/bin/bash hooks ran"
assert_contains "$(shim_tree)" "remote-ack so=braceexpand:errexit:hashall:interactive-comments:monitor:nounset:pipefail pid-leads=y" "row 25: the ack's SHELLOPTS, and it leads its group"
assert_contains "$(shim_tree)" "remote-poll so=braceexpand:errexit:hashall:interactive-comments:nounset:pipefail pid-leads=n" "row 25: the poll hook's SHELLOPTS, in the entry's group"
R_ENV+=("BASH_VERSION=3.2.57(1)-release")
seed_side
put benv2.sh 'hook_setting=ready\n'
bhook remote-reply 'cat >/dev/null; [ -n "$AC_REMOTE_THREAD" ] || printf "1800.9\n"'
bhook remote-ack 'exit 0'
bhook remote-poll "cat '$FEED'"
R_STDIN="$TMP/rstdin"
rrun thread-post famso
assert_eq "$(shim_out)" "posted famso (1800.9)" "row 25: an exported BASH_VERSION too"
R_STDIN=/dev/null
rrun poll
assert_eq "$(shim_out)" "remote-order bv2" "row 25: poll and ack under an exported BASH_VERSION"
assert_contains "$(shim_tree)" "remote-ack so=braceexpand:errexit:hashall:interactive-comments:monitor:nounset:pipefail pid-leads=y" "row 25: the ack's SHELLOPTS and group, unchanged"
R_ENV=()

# 26. META SET runs under ac_meta_set's lock <dir>/.<file>.lock (10 PATH
#     `sleep 1` waits, counted by a stub): against a live holder, link,
#     done-stamp and push-pending's stamp warn `cannot lock meta file <f> -
#     nothing written` and end the run, exit 1; the family send's
#     registration warns once per key and still posts, exit 0; followup's
#     unset takes no lock and writes through a held one
seed_side
mkdir -p "$TMP/rsleep"
printf '#!/bin/sh\necho x >>"$R_SIDE/log/sleeps"\n' >"$TMP/rsleep/sleep"
chmod +x "$TMP/rsleep/sleep"
R_ENV=("PATH=$TMP/rsleep:$RSTUB:$PATH")
held() { mkdir -p "$H/home/state/$1"; printf '%s\n' "$$" >"$H/home/state/$1/pid"; }
sleeps() { assert_eq "$(cat "$H/log/sleeps" 2>/dev/null | wc -l | tr -d ' ')" "$1" "$2"; rm -f "$H/log/sleeps"; }
stash r1 '"1.2"'
put home/state/t1.meta 'pr=x\n'
held .t1.meta.lock
rrun link t1 r1
refused "WARN: cannot lock meta file HOME/home/state/t1.meta - nothing written" "row 26: link refuses a held meta lock"
assert_eq "$(cat "$H/home/state/t1.meta")" "pr=x" "row 26: ...with nothing written"
sleeps 10 "row 26: ...after ten waits"
put home/state/t1.meta 'remote_request=r1\nremote_request_ts=5\npr=x\n'
hook remote-reply 'hlog fs $#; [ -n "$AC_REMOTE_THREAD" ] || printf "1700.42\n"'
rrun followup t1
assert_eq "$RC|$(cat "$H/home/state/t1.meta")" "0|pr=x" "row 26: followup's unset writes through the held lock"
sleeps 0 "row 26: ...without waiting"
held ..landing-receipt-stamp.lock
rrun done-stamp famz
refused "WARN: cannot lock meta file HOME/home/state/.landing-receipt-stamp - nothing written" "row 26: done-stamp refuses a held stamp lock"
sleeps 10 "row 26: ...after ten waits"
held remote-threads/.f1.thread.lock
rrun thread-post f1
assert_eq "$RC|$(shim_out)|$(shim_err)" "0|posted f1 (1700.42)|WARN: cannot lock meta file HOME/home/state/remote-threads/f1.thread - nothing written
WARN: cannot lock meta file HOME/home/state/remote-threads/f1.thread - nothing written" "row 26: the registration warns per key and the post stands"
sleeps 20 "row 26: ...ten waits per key"
room fam1 '- [t] c> GATE: one\n'
held ..remote-push-stamp.lock
rrun push-pending
refused "WARN: cannot lock meta file HOME/home/state/.remote-push-stamp - nothing written" "row 26: push-pending's stamp refuses a held lock after the send"
sleeps 10 "row 26: ...after ten waits"
R_ENV=()

pass
