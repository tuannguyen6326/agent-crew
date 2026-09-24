#!/usr/bin/env bash
# ac-compact-advise.test.sh - the System One compact adviser: a settled claude
# transcript is judged at the `compact` site with compact-adviser's two
# questions, scored and gated on a usage-sliding floor, and advised only under
# config/jev=on; below the token minimum, under off/shadow, and on any failure
# it prints nothing and always exits 0.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
ADV="$BIN/ac-compact-advise.sh"

# A fake curl on PATH (the ac-jev.test.sh shape): answers $FAKE_RESP, keeps
# the posted body, counts hits.
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -d) data="$2"; shift ;; esac
  shift
done
case "$data" in @*) cat "${data#@}" >"$FAKE_BODY" ;; *) printf '%s' "$data" >"$FAKE_BODY" ;; esac
n="$(cat "$FAKE_HITS" 2>/dev/null || printf 0)"; printf '%s\n' "$((n + 1))" >"$FAKE_HITS"
cat "$FAKE_RESP" >"$out"
printf '200'
EOF
chmod +x "$TMP/stubbin/curl"
export PATH="$TMP/stubbin:$PATH"
export FAKE_BODY="$TMP/body" FAKE_HITS="$TMP/hits" FAKE_RESP="$TMP/resp"
hits() { cat "$FAKE_HITS" 2>/dev/null || printf 0; }
printf '{"openrouter":{"api_key":"sk-or-TEST"}}\n' >"$AC_HOME/config/providers.json"

resp() { # resp <P(finished)> <P(hands_on)>
  local f="$1" h="$2"
  jq -nc --argjson f "$f" --argjson h "$h" '{
    model: "typesafe/jev-1.13",
    answers: {
      done: {type: "choice", choice: (if $f >= 0.5 then "finished" else "not_finished" end),
        probabilities: {finished: $f, not_finished: (1 - $f), unclear: 0}, confidence: 0.9},
      shape: {type: "choice", choice: (if $h >= 0.5 then "hands_on" else "coordinating" end),
        probabilities: {hands_on: $h, coordinating: (1 - $h), unclear: 0}, confidence: 0.9}},
    usage: {input_tokens: 400, output_tokens: 40}}' >"$FAKE_RESP"
}

transcript() { # transcript <file> <context tokens> [user text]
  {
    jq -nc --arg u "${3:-fix the flaky test}" '{type: "user", message: {role: "user", content: $u}}'
    jq -nc --argjson t "$2" '{type: "assistant", message: {role: "assistant", model: "claude-opus-5-5",
      content: [{type: "text", text: "Fixed and committed; the suite is green."}],
      usage: {input_tokens: 10, cache_read_input_tokens: ($t - 110), cache_creation_input_tokens: 100, output_tokens: 50}}}'
  } >"$1"
}

tx="$TMP/t.jsonl"
transcript "$tx" 150000   # 0.75 of the default 200000 window: floor 0.575
resp 0.96 0.1

# 1. Absent knob: silent, no request, exit 0.
out="$("$ADV" "$tx" --role crew 2>&1)" || fail "absent knob must exit 0"
assert_eq "$out" "" "absent knob is silent"
assert_eq "$(hits)" "0" "absent knob makes no request"

# 2. shadow: one request carrying both questions at the compact site, no output.
printf 'shadow\n' >"$AC_HOME/config/jev"
out="$("$ADV" "$tx" --role crew 2>/dev/null)"
assert_eq "$out" "" "shadow prints nothing"
assert_eq "$(hits)" "1" "shadow makes one request"
assert_eq "$(jq -r '.questions | keys | join(",")' "$FAKE_BODY")" "done,shape" "the request asks done and shape"
assert_contains "$(jq -r '.state' "$FAKE_BODY")" "fix the flaky test" "the state carries the conversation tail"
assert_eq "$(tail -n 1 "$AC_HOME/state/jev-shadow.jsonl" | jq -r .site)" "compact" "the record is filed under the compact site"

printf 'on\n' >"$AC_HOME/config/jev"

# 3. Below the 40k token minimum: no request at all.
small="$TMP/small.jsonl"; transcript "$small" 30000
before="$(hits)"
out="$("$ADV" "$small" --role crew 2>/dev/null)"
assert_eq "$out" "" "below the minimum nothing is advised"
assert_eq "$(hits)" "$before" "below the minimum no request is made"

# 4. A crewmate that mostly coordinated: 0.96 * (0.5 + 0.5*0.1) = 0.528 < 0.575.
out="$("$ADV" "$tx" --role crew 2>/dev/null)"
assert_eq "$out" "" "a coordinating crewmate under the floor is not advised"

# 5. A chief carries no coordination penalty: 0.96 >= 0.575.
out="$("$ADV" "$tx" --role chief 2>/dev/null)"
assert_contains "$out" "compact=advise" "a finished chief turn is advised"
assert_contains "$out" "floor=0.575" "the floor slides with usage"
assert_contains "$out" "usage=0.75" "the usage fraction is over the window"

# 6. Hands-on crewmate: 0.96 * (0.5 + 0.5*0.9) = 0.912 - advised.
resp 0.96 0.9
out="$("$ADV" "$tx" --role crew 2>/dev/null)"
assert_contains "$out" "compact=advise score=0.912" "a hands-on finished crewmate is advised"

# 7. Unfinished work is never advised.
resp 0.2 0.9
out="$("$ADV" "$tx" --role chief 2>/dev/null)"
assert_eq "$out" "" "unfinished work is not advised"

# 8. --hook (the claude Stop hook): chief-shaped cwd, systemMessage for the
#    human, once per usage step; stop_hook_active and worker cwd stay silent.
resp 0.96 0.1
hook() { (cd "$1" && printf '%s' "$2" | env "${@:3}" "$ADV" --hook) }
payload="$(jq -nc --arg p "$tx" '{session_id: "s-1", transcript_path: $p, stop_hook_active: false}')"
out="$(hook "$AC_HOME" "$payload" AC_SOLO=)" || fail "the hook must exit 0"
assert_contains "$(jq -r .systemMessage <<<"$out")" "/compact" "the chief is told to /compact"
out="$(hook "$AC_HOME" "$payload" AC_SOLO=)"
assert_eq "$out" "" "the same usage step is not advised twice"
out="$(hook "$AC_HOME" "$(jq -c '.stop_hook_active = true' <<<"$payload")" AC_SOLO=)"
assert_eq "$out" "" "a Stop-hook continuation is never judged"
mkdir -p "$TMP/elsewhere"
out="$(hook "$TMP/elsewhere" "$(jq -c '.session_id = "s-2"' <<<"$payload")" AC_SOLO=)"
assert_eq "$out" "" "a worker-shaped session is left to the watcher"
out="$(hook "$AC_HOME" 'not json' AC_SOLO=)" || fail "garbage stdin must exit 0"
assert_eq "$out" "" "garbage stdin prints nothing"

# 8b. A solo session is judged from any cwd with the crew weight: the same
#     coordinating answer that advised the chief stays under the floor here.
out="$(hook "$TMP/elsewhere" "$(jq -c '.session_id = "s-3"' <<<"$payload")" AC_SOLO=1)"
assert_eq "$out" "" "a coordinating solo turn is under the crew floor"
resp 0.96 0.9
out="$(hook "$TMP/elsewhere" "$(jq -c '.session_id = "s-4"' <<<"$payload")" AC_SOLO=1)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "/compact" "a hands-on solo turn is advised"

# 8c. The window: AC_COMPACT_WINDOW beats config/compact-window beats 200000.
printf '1000000\n' >"$AC_HOME/config/compact-window"
out="$("$ADV" "$tx" --role chief 2>/dev/null)"
assert_contains "$out" "floor=0.875 usage=0.15" "config/compact-window sets the denominator"
out="$(AC_COMPACT_WINDOW=300000 "$ADV" "$tx" --role chief 2>/dev/null)"
assert_contains "$out" "floor=0.7 usage=0.5" "AC_COMPACT_WINDOW wins over the config file"
rm -f "$AC_HOME/config/compact-window"

# 8d. Secrets never leave the machine in the state.
sec="$TMP/secret.jsonl"
transcript "$sec" 150000 'cat .env gave PASSWORD=hunter2hunter and sk-abcdefghijklmnop and eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4f'
"$ADV" "$sec" --role chief >/dev/null 2>&1
st="$(jq -r .state "$FAKE_BODY")"
for leak in hunter2hunter sk-abcdefghijklmnop eyJhbGciOiJIUzI1; do
  case "$st" in *"$leak"*) fail "a secret reached the provider: $leak" ;; esac
done
assert_contains "$st" "[redacted]" "the redaction marker stands in for the secrets"

# 9. Wiring: the claude Stop hooks include the adviser.
case "$(jq -r '[.hooks.Stop[].hooks[].command] | .[]' "$ROOT/.claude/settings.json")" in
  *ac-compact-advise.sh*) ;;
  *) fail "claude Stop wiring misses ac-compact-advise.sh" ;;
esac

pass
