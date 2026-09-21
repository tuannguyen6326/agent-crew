#!/usr/bin/env bash
# ac-watch-jev.test.sh - the System One net on the watcher's quiet arm: with
# config/jev absent the ended:/stale: wake payloads are byte-identical and no
# request is made; shadow makes one request per quiet episode and logs it with
# the pane tail as state, payload unchanged; on appends ` jev=<choice> p=<p>`
# to the payload while the exit reason token stays bare; an adapter failure
# leaves the payload exactly as under off.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"
make_fake_herdr

seed_pane() {
  printf '%s %s\n' "$2" "$3" >"$state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}
fleet_spool() { cat "$state"/.wake-spool/* 2>/dev/null || true; }

# The fake curl from ac-jev.test.sh: counts hits, records the body, answers canned.
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -d) data="$2"; shift ;; esac; shift; done
cat "${data#@}" >"$FAKE_BODY"
n="$(cat "$FAKE_HITS" 2>/dev/null || printf 0)"; printf '%s\n' "$((n + 1))" >"$FAKE_HITS"
cat "$FAKE_RESP" >"$out"
printf '%s' "${FAKE_CODE:-200}"
EOF
chmod +x "$TMP/stubbin/curl"
export PATH="$TMP/stubbin:$PATH"
export FAKE_BODY="$TMP/body" FAKE_HITS="$TMP/hits" FAKE_RESP="$TMP/resp"
hits() { cat "$FAKE_HITS" 2>/dev/null || printf 0; }
printf '%s\n' '{"model":"m","answers":{"done":{"type":"choice","choice":"finished","probabilities":{"finished":0.96,"not_finished":0.01,"unclear":0.03},"confidence":0.94}},"usage":{"input_tokens":1,"output_tokens":0}}' >"$FAKE_RESP"
printf '{"openrouter":{"api_key":"sk-or-TEST"}}\n' >"$AC_HOME/config/providers.json"

# quiet <id> <p> <t> <status> - a pane whose tail asks a prose question, settled
# once, then backdated past AC_STALE with the given backend agent status, so the
# next --once takes the quiet arm (ac-watch.test.sh's elw idiom).
quiet() {
  mkdir -p "$AC_HOME/data/$1"
  printf 'window=crew:%s\nbackend=herdr\n' "$1" >"$state/$1.meta"
  seed_pane "$1" "$2" "$3"
  printf 'summarising the change\nshould I also drop the legacy path?\n' >>"$FAKE_HERDR/panes/$2.buf"
  bash "$BIN/ac-watch.sh" --once >/dev/null
  rm -rf "$state"/.wake-spool*
  printf '%s\n' "$(( $(date +%s) - 1000 ))" >"$state/.change-$1"
  printf '%s\n' "$4" >"$FAKE_HERDR/panes/$2.status"
}
payload() { fleet_spool | grep -E "$1" | tail -n 1; }

# 1. Knob absent: the loud wake is exactly today's, no request.
quiet j1 pJ1 tJ1 idle
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:j1" "absent knob: ended wake"
p="$(payload j1)"
assert_contains "$p" "with no report line - read the pane, the ask may be prose" "absent knob: today's payload"
case "$p" in *jev=*) fail "absent knob: payload must carry no jev note" ;; esac
assert_eq "$(hits)" "0" "absent knob: no request"
rm -f "$state/j1.meta"

# 2. shadow: one request with the pane tail as state, payload unchanged, one record.
printf 'shadow\n' >"$AC_HOME/config/jev"
quiet j2 pJ2 tJ2 idle
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:j2" "shadow: ended wake"
p="$(payload j2)"
case "$p" in *jev=*) fail "shadow: payload must carry no jev note" ;; esac
assert_eq "$(hits)" "1" "shadow: exactly one request per quiet episode"
assert_contains "$(jq -r '.state' "$FAKE_BODY")" "should I also drop the legacy path?" "shadow: the pane tail is the state"
assert_contains "$(jq -r '.state' "$FAKE_BODY")" "status:" "shadow: the last status line rides along"
assert_eq "$(jq -r '.questions.done.type' "$FAKE_BODY")" "choice" "shadow: the done question"
assert_contains "$(jq -r '.questions.done.criteria.finished' "$FAKE_BODY")" "handed to whoever must act next" "shadow: compact-adviser's finished criterion"
rec="$(tail -n1 "$state/jev-shadow.jsonl")"
assert_eq "$(jq -r '.site' <<<"$rec")" "watch" "shadow: record site"
assert_eq "$(jq -r '.answers.done.choice' <<<"$rec")" "finished" "shadow: record answer"
rm -f "$state/j2.meta"

# 3. on, ended turn: the payload gains the note, the exit reason token stays bare.
printf 'on\n' >"$AC_HOME/config/jev"
quiet j3 pJ3 tJ3 idle
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_eq "$(grep -E '^ended:' <<<"$out")" "ended:j3" "on: the reason token is bare"
p="$(payload j3)"
assert_contains "$p" "the ask may be prose jev=finished p=0.96" "on: payload carries the note"
assert_eq "$(hits)" "2" "on: one request"
assert_contains "$(cat "$state/j3.status")" "ended its turn" "on: the status note is unchanged"
case "$(cat "$state/j3.status")" in *jev=*) fail "on: the status log never carries the note (declared_wait reads it)" ;; esac
rm -f "$state/j3.meta"

# 4. on, quiet-while-working: the soft stale payload gains the note too.
quiet j4 pJ4 tJ4 working
out="$(bash "$BIN/ac-watch.sh" --once)"
assert_eq "$(grep -E '^stale:' <<<"$out")" "stale:j4" "on: stale reason token is bare"
assert_contains "$(payload j4)" "with no report line jev=finished p=0.96" "on: stale payload carries the note"
rm -f "$state/j4.meta"

# 5. on, adapter failure: payload exactly as under off, the watcher still wakes.
quiet j5 pJ5 tJ5 idle
out="$(FAKE_CODE=500 bash "$BIN/ac-watch.sh" --once)"
assert_contains "$out" "ended:j5" "failure: still wakes"
p="$(payload j5)"
assert_contains "$p" "with no report line - read the pane, the ask may be prose" "failure: today's payload"
case "$p" in *jev=*) fail "failure: no note on a failed answer" ;; esac
assert_contains "$(cat "$state/.watcher-arm.log")" "jev: http 500" "failure: the adapter's reason reaches the arm log"

pass
