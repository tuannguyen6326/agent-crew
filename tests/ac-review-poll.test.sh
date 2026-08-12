#!/usr/bin/env bash
# ac-review-poll.test.sh - bin/ac-review.sh's req()/cmd_poll, two behaviours
# from the captain-hold-has-no-machine-representation-wake family, fold (a):
#
#   W3 (transport classification): req() must not misdiagnose every curl
#   failure as "dashboard unreachable ... start it" - a genuine connection
#   refusal (nothing listening) still says that, but a timeout or a dropped
#   connection mid-request says what actually happened, since a channel that
#   reports wrongly is exactly the moment an agent must stop, not go looking
#   for the answer in the session file.
#
#   W4 (pending truth reachable): cmd_poll looped forever printing nothing
#   whenever the server answered a quiet round with a non-zero `pending` (a
#   guest record awaiting the captain's approval) and an empty `items` -
#   the skill's own promise ("a non-zero pending with empty items means
#   WAIT") was structurally undeliverable. The fix returns as soon as
#   `pending` is non-zero, carrying the COUNT ONLY (never content, never a
#   `by`, never a pending item's text) - the ordinary quiet round (pending=0,
#   items=[]) still loops exactly as before.
#
# curl is stubbed from a numbered response queue (RESP_DIR/<n>.out + <n>.rc),
# so none of this needs a running dashboard.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { printf 'SKIP: jq not installed\n'; exit 0; }

make_home

artifact="$TMP/report.html"
printf '<html></html>\n' >"$artifact"

mkdir -p "$TMP/stub"
cat >"$TMP/stub/curl" <<'EOF'
#!/usr/bin/env bash
# Ignores every curl argument (method, url, timeouts) - it only replays the
# canned response queue at $RESP_DIR, one file pair per invocation, in order.
n=0
[ -f "$RESP_DIR/.count" ] && n="$(cat "$RESP_DIR/.count")"
n=$((n + 1))
printf '%s' "$n" >"$RESP_DIR/.count"
[ -f "$RESP_DIR/$n.out" ] && cat "$RESP_DIR/$n.out"
rc=0
[ -f "$RESP_DIR/$n.rc" ] && rc="$(cat "$RESP_DIR/$n.rc")"
exit "$rc"
EOF
chmod +x "$TMP/stub/curl"

run_poll() { # run_poll <resp-dir> [extra poll args...] -> sets $out $rc, uses $artifact
  # A 5s watchdog (no `timeout` binary on every host this suite runs on): a
  # regression that reopens the pending-truth hang (W4) must fail this test,
  # never wedge it - kill -9 leaves rc=137, distinct from every real exit code
  # below and from every real error() 1.
  local dir="$1" pid watchdog
  shift
  out=""
  rc=0
  RESP_DIR="$dir" PATH="$TMP/stub:$PATH" AC_HOME="$AC_HOME" \
    "$BIN/ac-review.sh" poll "$artifact" "$@" >"$TMP/poll.out" 2>&1 &
  pid=$!
  ( sleep 5; kill -9 "$pid" 2>/dev/null ) &
  watchdog=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  out="$(cat "$TMP/poll.out" 2>/dev/null)"
}

# ---- W3 case 1: connection refused (curl exit 7) -> "start it" stays ------
d="$TMP/respA"; mkdir -p "$d"
printf '7\n' >"$d/1.rc"
run_poll "$d"
assert_eq "$rc" 1 "connection refused: poll exits non-zero"
assert_contains "$out" "start it" "connection refused: still names the fix"
assert_contains "$out" "bin/ac-dashboard.sh" "connection refused: names the exact command"

# ---- W3 case 2: timeout (curl exit 28) -> distinct message, no wrong fix --
d="$TMP/respB"; mkdir -p "$d"
printf '28\n' >"$d/1.rc"
run_poll "$d"
assert_eq "$rc" 1 "timeout: poll exits non-zero"
assert_contains "$out" "timed out" "timeout: names what actually happened"
case "$out" in
  *"start it"*) fail "timeout must NOT say 'start it' - the dashboard is not down" ;;
esac

# ---- W3 case 3: dropped connection / empty reply (curl exit 52) -----------
d="$TMP/respC"; mkdir -p "$d"
printf '52\n' >"$d/1.rc"
run_poll "$d"
assert_eq "$rc" 1 "dropped connection: poll exits non-zero"
assert_contains "$out" "dropped the connection" "dropped connection: names what actually happened"
case "$out" in
  *"start it"*) fail "a dropped connection must NOT say 'start it' - the dashboard is not down" ;;
esac

# ---- W4 case 1: non-zero pending, empty items -> reachable, no hang -------
d="$TMP/respD"; mkdir -p "$d"
printf '{"state":"open","items":[],"pending":2}\n' >"$d/1.out"
printf '0\n' >"$d/1.rc"
run_poll "$d" --after 7
assert_eq "$rc" 0 "non-zero pending with empty items is not an error"
assert_contains "$out" '"pending":2' "the pending COUNT reaches the caller"
assert_contains "$out" '"items":[]' "never a pending item's content"
assert_eq "$(cat "$d/.count")" "1" "poll returns on the first pending-but-quiet round, never hangs"

# ---- fix round 1 finding: the ONE correct move is named, not left to a
# skill an agent may not have loaded - stop and ask, never re-poll in a
# tight loop for the same non-answer, and resume with the SAME cursor.
assert_contains "$out" "stop and ask" "pending hint names the correct move"
assert_contains "$out" "bin/ac-review.sh poll $artifact --after 7" \
  "pending hint names the exact resume command with the caller's own cursor"
case "$out" in
  *"pending: 2"*"stop and ask"*"resume with"*"--after 7"*) ;;
  *) fail "pending hint missing an expected clause: $out" ;;
esac

# ---- W4 case 2 (no regression): pending=0 quiet rounds keep looping --------
d="$TMP/respE"; mkdir -p "$d"
printf '{"state":"open","items":[],"pending":0}\n' >"$d/1.out"; printf '0\n' >"$d/1.rc"
printf '{"state":"open","items":[],"pending":0}\n' >"$d/2.out"; printf '0\n' >"$d/2.rc"
printf '{"state":"open","items":[{"n":1,"anchor":null,"text":"hi"}],"pending":0}\n' >"$d/3.out"
printf '0\n' >"$d/3.rc"
run_poll "$d"
assert_eq "$rc" 0 "an ordinary quiet round eventually delivers the real item"
assert_contains "$out" '"n":1' "the delivered item is the real one"
assert_eq "$(cat "$d/.count")" "3" "pending=0 quiet rounds still loop exactly as before (no regression)"

pass
