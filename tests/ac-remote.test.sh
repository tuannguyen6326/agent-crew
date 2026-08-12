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
# ac-remote reply as confirmation. Captain 2026-07-30 ("block boi captain")
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
assert_contains "$(cat "$TMP/gc.err")" "unwoken old-un" "young-window stash with no queued wake surfaced as advisory"
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

pass
