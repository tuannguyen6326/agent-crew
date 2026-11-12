#!/usr/bin/env bash
# ac-compact-advise.test.sh - the System One compact adviser: a settled claude
# transcript is judged at the `compact` site with compact-adviser's two
# questions, scored and gated on a usage-sliding floor, and advised only under
# config/jev=on; below the token minimum, under off/shadow, and on any failure
# it prints nothing and always exits 0.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# 8e. Context only shrinks when the session was compacted: usage that falls
#     below the last advised step becomes the new baseline, unjudged, and the
#     next step up is advised instead of waiting for the old high-water step.
resp 0.96 0.1
low="$TMP/low.jsonl"; transcript "$low" 100000
p1low="$(jq -nc --arg p "$low" '{session_id: "s-1", transcript_path: $p, stop_hook_active: false}')"
before="$(hits)"
out="$(hook "$AC_HOME" "$p1low" AC_SOLO=)"
assert_eq "$out" "" "the first stop after a compaction only records the new baseline"
assert_eq "$(hits)" "$before" "the baseline stop asks nothing"
transcript "$low" 110000
out="$(hook "$AC_HOME" "$p1low" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "/compact" "a compacted session is advised again one step up"

# 8f. A mark that is not a number (a torn write) never silences a session.
mkdir -p "$AC_HOME/state/.compact-advise"
printf 'x\n' >"$AC_HOME/state/.compact-advise/s-12"
out="$(hook "$AC_HOME" "$(jq -c '.session_id = "s-12"' <<<"$payload")" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "/compact" "a corrupt mark reads as no mark"

# 10. config/compact-auto=on: a session that owns a meta (a roomchief) gets
#     /compact typed into its own pane once the pane is idle - detached, so
#     the Stop hook never waits on it. Everything else keeps the hint only.
make_fake_herdr
mk_chief() { # mk_chief <id> <session_id> <pane> <tab>
  printf 'backend=herdr\nkind=roomchief\nsession_id=%s\n' "$2" >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$3" "$4" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$3" >"$FAKE_HERDR/tabs/$4"
  : >"$FAKE_HERDR/panes/$3.buf"
}
sendlog="$AC_HOME/state/.compact-advise/send.log"
mk_chief rc-chief s-9 pC1 tC1
printf 'idle\n' >"$FAKE_HERDR/panes/pC1.status"
p9="$(jq -nc --arg p "$tx" '{session_id: "s-9", transcript_path: $p, stop_hook_active: false}')"

out="$(hook "$AC_HOME" "$p9" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "Run /compact" "without compact-auto the roomchief only gets the hint"
sleep 1
assert_no_file "$sendlog" "without compact-auto nothing is sent"

printf 'on\n' >"$AC_HOME/config/compact-auto"
rm -f "$AC_HOME/state/.compact-advise/s-9"
out="$(hook "$AC_HOME" "$p9" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "rc-chief" "the message names the pane /compact is sent to"
assert_contains "$(jq -r .systemMessage <<<"$out")" "otherwise run /compact" "the hint survives a send that gives up"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'rc-chief:' "$sendlog" 2>/dev/null && break; sleep 0.5; done
assert_contains "$(cat "$FAKE_HERDR/panes/pC1.buf")" "/compact" "the idle roomchief pane receives /compact"
assert_contains "$(cat "$sendlog")" "rc-chief: sent" "the send is logged"

out="$(hook "$AC_HOME" "$(jq -c '.session_id = "s-10"' <<<"$p9")" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "Run /compact" "a session with no meta keeps the hint"

# 10b. A pane that never goes idle inside the bound is left alone.
mk_chief busy-chief s-11 pC2 tC2
printf 'working\n' >"$FAKE_HERDR/panes/pC2.status"
AC_COMPACT_SEND_WAIT=1 "$ADV" --send busy-chief >>"$sendlog" 2>&1 || fail "--send must exit 0"
assert_eq "$(cat "$FAKE_HERDR/panes/pC2.buf")" "" "a busy pane is never typed into"
assert_contains "$(tail -n 1 "$sendlog")" "busy-chief: not idle" "the give-up is logged"

# 10c. Below config/compact-auto-min (default 50) percent usage the advice
#      stays a hint: a finished roomchief at 30% is not compacted for it.
mk_chief early-chief s-13 pC3 tC3
printf 'idle\n' >"$FAKE_HERDR/panes/pC3.status"
mid="$TMP/mid.jsonl"; transcript "$mid" 60000
p13="$(jq -nc --arg p "$mid" '{session_id: "s-13", transcript_path: $p, stop_hook_active: false}')"
resp 0.96 0.1
out="$(hook "$AC_HOME" "$p13" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "Run /compact" "under the auto minimum a roomchief only gets the hint"
printf '20\n' >"$AC_HOME/config/compact-auto-min"
transcript "$mid" 70000
out="$(hook "$AC_HOME" "$p13" AC_SOLO=)"
assert_contains "$(jq -r .systemMessage <<<"$out")" "early-chief" "a lowered minimum lets the same roomchief be compacted"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'early-chief:' "$sendlog" 2>/dev/null && break; sleep 0.5; done
rm -f "$AC_HOME/config/compact-auto-min"

# 10d. --auto <id>, the watcher's form for a crewmate (src/watch.ts COMPACT
#      NOTE): at or above the minimum under compact-auto=on the line reads
#      compact=auto and /compact is typed with NO idle wait - the watcher's
#      ended: arm has already stamped the pane captain-wait, which herdr reads
#      blocked for as long as the stamp stands. Anything short of that keeps
#      the hint and sends nothing.
mk_chief cm-ship s-20 pC4 tC4
printf 'backend=herdr\nkind=ship\nsession_id=s-20\n' >"$AC_HOME/state/cm-ship.meta"
printf 'blocked\n' >"$FAKE_HERDR/panes/pC4.status"
: >"$AC_HOME/state/.captain-wait-cm-ship"
resp 0.96 0.9
AC_COMPACT_SEND_WAIT=0 "$ADV" --send cm-ship >>"$sendlog" 2>&1 || fail "--send must exit 0"
assert_contains "$(tail -n 1 "$sendlog")" "cm-ship: not idle" "the waiting sender never reaches a stamped pane"
out="$("$ADV" "$mid" --role crew --auto cm-ship 2>/dev/null)"
assert_eq "$out" "compact=advise score=0.912 floor=0.775 usage=0.35" "under the auto minimum a crewmate keeps the hint"
out="$("$ADV" "$tx" --role crew --auto cm-ship 2>/dev/null)"
assert_eq "$out" "compact=auto score=0.912 floor=0.575 usage=0.75" "at the minimum the line says the fleet sends /compact itself"
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'cm-ship: sent' "$sendlog" 2>/dev/null && break; sleep 0.5; done
assert_contains "$(cat "$FAKE_HERDR/panes/pC4.buf")" "/compact" "the stamped crewmate pane receives /compact"
rm -f "$AC_HOME/config/compact-auto"
out="$("$ADV" "$tx" --role crew --auto cm-ship 2>/dev/null)"
assert_eq "$out" "compact=advise score=0.912 floor=0.575 usage=0.75" "without compact-auto --auto is only the hint"
sleep 1
assert_eq "$(grep -c 'cm-ship: sent' "$sendlog")" "1" "one send in all: the under-minimum and the knob-off calls sent nothing"

# 9. Wiring: the claude Stop hooks include the adviser.
case "$(jq -r '[.hooks.Stop[].hooks[].command] | .[]' "$ROOT/.claude/settings.json")" in
  *ac-compact-advise.sh*) ;;
  *) fail "claude Stop wiring misses ac-compact-advise.sh" ;;
esac

# --- the readings and the refusals, row by row --------------------------------
# Each run works on a fresh copy ($ch.n) of one seeded home ($ch) with jev=on,
# stdin $TMP/ca.in, LC_ALL=C, a TMPDIR of its own and a PATH `date` frozen at
# one instant; $TMP/ca.body exists after a run only when a request was made.
mkdir -p "$TMP/ca-date"
printf '#!/bin/sh\ncase "$*" in *%%s*) echo 1800000000 ;; *) echo 2027-01-15T08:00:00Z ;; esac\n' >"$TMP/ca-date/date"
chmod +x "$TMP/ca-date/date"
ch="$TMP/ca-home"
rm -rf "$ch"; mkdir -p "$ch/state" "$ch/config"
cp "$AC_HOME/config/providers.json" "$ch/config/"
printf 'on\n' >"$ch/config/jev"
: >"$TMP/ca.in"
ca_run() {  # ca_run <cwd|HOME> [VAR=VAL ...] -- <args...> - sets ca_out; stderr in $TMP/ca.err
  local cwd="$1" envs=() rc=0
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -rf "$ch.n" "$TMP/ca-tmp" "$TMP/ca.body"
  cp -R "$ch" "$ch.n"
  mkdir -p "$TMP/ca-tmp"
  [ "$cwd" != HOME ] || cwd="$ch.n"
  (cd "$cwd" && env -u AC_SOLO AC_HOME="$ch.n" ${envs[@]+"${envs[@]}"} TMPDIR="$TMP/ca-tmp" FAKE_BODY="$TMP/ca.body" \
    PATH="$TMP/ca-date:$PATH" LC_ALL=C "$ADV" "$@" <"$TMP/ca.in") >"$TMP/ca.out" 2>"$TMP/ca.err" || rc=$?
  assert_eq "$rc" "0" "the adviser always exits 0 ($*)"
  ca_out="$(cat "$TMP/ca.out")"
}
ca_silent() {  # ca_silent <what> - the last run printed nothing and asked nothing
  assert_eq "$ca_out" "" "$1: nothing advised"
  assert_no_file "$TMP/ca.body" "$1: no request made"
}
cap="$TMP/ca.jsonl"; transcript "$cap" 150000
CHIEF_LINE="compact=advise score=0.96 floor=0.575 usage=0.75"
CREW_LINE="compact=advise score=0.912 floor=0.575 usage=0.75"

# 1. the CLI's argument shapes: the role is read only after an exact `--role`,
#    crew otherwise; a role that is neither is silence; so is no transcript, a
#    missing one and a directory.
resp 0.96 0.9
ca_run "$TMP" -- "$cap" --role chief
assert_eq "$ca_out" "$CHIEF_LINE" "1: the chief line"
for a in "--role crew" "--role" "--role=chief" "chief"; do
  # shellcheck disable=SC2086
  ca_run "$TMP" -- "$cap" $a
  assert_eq "$ca_out" "$CREW_LINE" "1: '$a' is judged with the crew weight"
done
ca_run "$TMP" -- "$cap" --role bogus
ca_silent "1: a role that is neither chief nor crew"
ca_run "$TMP" --
ca_silent "1: no argument"
ca_run "$TMP" -- "$TMP/ca-none.jsonl" --role chief
ca_silent "1: a missing transcript"
ca_run "$TMP" -- "$TMP" --role chief
ca_silent "1: a directory for a transcript"
printf 'off\n' >"$ch/config/jev"
ca_run "$TMP" -- "$cap" --role chief
ca_silent "1: jev=off"
# Under jev=off the adapter writes nothing, so an unarmed --auto must leave a
# home without state/ as it was.
rmdir "$ch/state"
ca_run "$TMP" -- "$cap" --role chief --auto aa-chief
ca_silent "1: an unarmed --auto under jev=off"
[ ! -e "$ch.n/state" ] || fail "an unarmed --auto must not create state/"
printf 'on\n' >"$ch/config/jev"; mkdir -p "$ch/state"

# 2. the score and the floor at their edges: a certain hands-on crewmate
#    scores 1, a certain coordinating one 0.5; 40000 tokens is the first
#    judged reading; the floor stops sliding at 0.5 from usage 0.9 up.
resp 1 1
ca_run "$TMP" -- "$cap" --role crew
assert_eq "$ca_out" "compact=advise score=1 floor=0.575 usage=0.75" "2: P(finished)=1, P(hands_on)=1"
resp 1 0
ca_run "$TMP" -- "$cap" --role crew
assert_eq "$ca_out" "" "2: 1 * (0.5 + 0.5*0) = 0.5 is under the 0.575 floor"
resp 0.96 0.9
transcript "$TMP/ca-t.jsonl" 39999
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
ca_silent "2: 39999 tokens"
transcript "$TMP/ca-t.jsonl" 40000
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
assert_eq "$ca_out" "compact=advise score=0.912 floor=0.85 usage=0.2" "2: 40000 tokens is judged - floor 0.9 - (0.2 - 0.1) / 0.8 * 0.4"
transcript "$TMP/ca-t.jsonl" 180000
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
assert_eq "$ca_out" "compact=advise score=0.912 floor=0.5 usage=0.9" "2: the floor reaches 0.5 at usage 0.9"
transcript "$TMP/ca-t.jsonl" 260000
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
assert_eq "$ca_out" "compact=advise score=0.912 floor=0.5 usage=1.3" "2: ...and stays there past a full window"

# 3. the token reading: a line jq cannot parse ends it, the lines before still
#    count; a usage that is no number is no reading; neither is an assistant
#    message further back than the last 400 lines.
transcript "$TMP/ca-t.jsonl" 150000
printf 'not json\n' >>"$TMP/ca-t.jsonl"
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
assert_eq "$ca_out" "$CREW_LINE" "3: the reading before an unparsable line counts"
jq -nc '{type: "assistant", message: {role: "assistant", usage: {input_tokens: "lots"}}}' >"$TMP/ca-t.jsonl"
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
ca_silent "3: a usage that is no number"
{ jq -nc '{type: "assistant", message: {role: "assistant", content: "x", usage: {input_tokens: 150000}}}'; for _ in $(seq 1 400); do printf '{"type":"user","message":{"role":"user","content":"pad"}}\n'; done; } >"$TMP/ca-t.jsonl"
ca_run "$TMP" -- "$TMP/ca-t.jsonl" --role crew
ca_silent "3: an assistant message beyond the last 400 lines"

# 4. the window's guard: no digits, or 0, reads 200000 from either source.
for w in abc 0; do
  printf '%s\n' "$w" >"$ch/config/compact-window"
  ca_run "$TMP" -- "$cap" --role chief
  assert_eq "$ca_out" "$CHIEF_LINE" "4: config/compact-window '$w' reads 200000"
  rm -f "$ch/config/compact-window"
  ca_run "$TMP" AC_COMPACT_WINDOW="$w" -- "$cap" --role chief
  assert_eq "$ca_out" "$CHIEF_LINE" "4: AC_COMPACT_WINDOW '$w' reads 200000"
done

# 5. the state sent: every key shape redacted, a NAME=value secret cut at a
#    blank, comma or brace; a tool result clipped to 512 characters and a tool
#    call sent by name; the last 64 entries, capped at the last 20000 bytes.
sec="$TMP/ca-secret.jsonl"
transcript "$sec" 150000 'PASSWORD=hunter2hunter, token: abc}def ghp_abcdefghijklmnopqrstuv AKIAABCDEFGHIJKLMNOP xoxb-1234567890-ab AIzaabcdefghijklmnopqrstuvwxyz0123 access_key = x,y -----BEGIN RSA PRIVATE KEY----- MIIE'
ca_run "$TMP" -- "$sec" --role chief
assert_eq "$(jq -r .state "$TMP/ca.body" | head -n 1)" "user: PASSWORD=[redacted], token: [redacted]}def [redacted] [redacted] [redacted] [redacted] access_key = [redacted],y [redacted private key]" "5: the redactions"
{ jq -nc --arg t "$(head -c 600 /dev/zero | tr '\0' r)" '{type: "user", message: {role: "user", content: [{type: "tool_result", content: $t}]}}'
  jq -nc '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash"}], usage: {input_tokens: 150000}}}'
} >"$TMP/ca-big.jsonl"
ca_run "$TMP" -- "$TMP/ca-big.jsonl" --role chief
assert_eq "$(jq -r .state "$TMP/ca.body")" "tool result: $(head -c 512 /dev/zero | tr '\0' r)
assistant: [tool call Bash]" "5: a tool result clipped to 512, a tool call by name"
for _ in $(seq 1 70); do jq -nc --arg t "$(head -c 400 /dev/zero | tr '\0' z)" '{type: "user", message: {role: "user", content: $t}}'; done >>"$TMP/ca-big.jsonl"
ca_run "$TMP" -- "$TMP/ca-big.jsonl" --role chief
# The adapter reads the state file as `$(cat)`, so the cap's final LF is not sent.
assert_eq "$(jq -r '.state | utf8bytelength' "$TMP/ca.body")" "19999" "5: the state is capped at its last 20000 bytes"
case "$(jq -r .state "$TMP/ca.body")" in *"tool call"*) fail "5: the cap keeps the END of the conversation" ;; esac

# 6. the hook: a judgment writes its usage step as the mark; a mark above the
#    step is rewritten unjudged; the payload shapes that are never judged; the
#    session_id is [A-Za-z0-9_-] only.
resp 0.96 0.1
ca_payload() { jq -nc --arg p "${2:-$cap}" --arg s "$1" '{session_id: $s, transcript_path: $p, stop_hook_active: false}' >"$TMP/ca.in"; }
ca_payload ok_id-1
ca_run HOME -- --hook
assert_contains "$(jq -r .systemMessage <<<"$ca_out")" "($CHIEF_LINE). Run /compact to save context" "6: the hook's message carries the line"
assert_eq "$(cat "$ch.n/state/.compact-advise/ok_id-1")" "15" "6: the mark is the 5-point usage step"
mkdir -p "$ch/state/.compact-advise"
printf '14\n' >"$ch/state/.compact-advise/ok_id-1"
ca_run HOME -- --hook
assert_contains "$ca_out" "systemMessage" "6: one step above the mark is advised"
printf '16\n' >"$ch/state/.compact-advise/ok_id-1"
ca_run HOME -- --hook
ca_silent "6: usage under the mark"
assert_eq "$(cat "$ch.n/state/.compact-advise/ok_id-1")" "15" "6: ...becomes the new baseline"
rm -rf "$ch/state/.compact-advise"
for p in '{"stop_hook_active":"no","session_id":"s","transcript_path":"'"$cap"'"}' ''; do
  printf '%s' "$p" >"$TMP/ca.in"
  ca_run HOME -- --hook
  ca_silent "6: payload '$p'"
done
for sid in 'a/b' '' "$(printf 's\303\251')"; do
  ca_payload "$sid"
  ca_run HOME -- --hook
  ca_silent "6: session_id '$sid'"
  assert_no_file "$ch.n/state/.compact-advise" "6: session_id '$sid' leaves no mark"
done
ca_payload s-9 "$TMP/ca-none.jsonl"
ca_run HOME -- --hook
ca_silent "6: a transcript_path that is no file"

# 7. AUTO: the knob is exactly `on`; the owning meta is the first in byte
#    order whose line is exactly session_id=<id>; the detached sender's line
#    lands in send.log (the fake herdr pane busy, the wait 0).
make_fake_herdr
printf 'session_id=s-9\r\n' >"$ch/state/aa-crlf.meta"
printf 'backend=herdr\nkind=roomchief\nsession_id=s-9\n' >"$ch/state/zz-chief.meta"
printf 'backend=herdr\nkind=roomchief\nsession_id=s-9\n' >"$ch/state/bb-chief.meta"
for c in bb-chief zz-chief; do
  printf 'pA tA\n' >"$ch/state/.pane-$c"
done
printf 'pA\n' >"$FAKE_HERDR/tabs/tA"
printf 'working\n' >"$FAKE_HERDR/panes/pA.status"
: >"$FAKE_HERDR/panes/pA.buf"
ca_payload s-9
for auto in off ON; do
  printf '%s\n' "$auto" >"$ch/config/compact-auto"
  ca_run HOME AC_COMPACT_SEND_WAIT=0 -- --hook
  assert_contains "$(jq -r .systemMessage <<<"$ca_out")" "Run /compact" "7: compact-auto '$auto' keeps the hint"
  assert_no_file "$ch.n/state/.compact-advise/send.log" "7: compact-auto '$auto' sends nothing"
done
printf 'on\n' >"$ch/config/compact-auto"
ca_run HOME AC_COMPACT_SEND_WAIT=0 -- --hook
assert_contains "$(jq -r .systemMessage <<<"$ca_out")" "/compact is typed into bb-chief if its pane goes idle" "7: the first owning meta in byte order is named"
for _ in $(seq 1 50); do [ -s "$ch.n/state/.compact-advise/send.log" ] && break; sleep 0.1; done
assert_eq "$(cat "$ch.n/state/.compact-advise/send.log")" "2027-01-15T08:00:00Z compact-auto bb-chief: not idle - left to the hint" "7: the sender's give-up line"
assert_eq "$(cat "$FAKE_HERDR/panes/pA.buf")" "" "7: a busy pane is never typed into"
rm -f "$ch/config/compact-auto"

# 8. --send by hand with no id is silence.
ca_run "$TMP" -- --send
assert_eq "$ca_out:$(cat "$TMP/ca.err")" ":" "8: --send with no id"

# 9. no bun on PATH: the shim exits 0 at once, saying so in one stderr line;
#    a module that cannot load is the same no-op, said the same way.
mkdir -p "$TMP/ca-nobun"
for t in bash env cat dirname jq sed awk head tail tr mktemp rm grep basename date mkdir; do ln -sf "$(command -v "$t")" "$TMP/ca-nobun/$t"; done
n_rc=0; (cd "$TMP" && AC_HOME="$ch" PATH="$TMP/ca-nobun" "$BIN/ac-compact-advise.sh" "$cap" --role chief) >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "0:" "9: without bun the shim exits 0 and advises nothing"
assert_eq "$(cat "$TMP/n.err")" "ac-compact-advise.sh: bun is not on PATH - this hook did nothing" "9: ...saying so in one stderr line"
ca_lf="$TMP/ca-loadfail"
mkdir -p "$ca_lf/bin" "$ca_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-compact-advise.sh" "$ca_lf/bin/"
printf 'throw new Error("compact adviser cannot load");\n' >"$ca_lf/src/compact-advise.ts"
n_rc=0; (cd "$TMP" && AC_HOME="$ch" "$ca_lf/bin/ac-compact-advise.sh" "$cap" --role chief) >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "0:" "9: a module that cannot load exits 0 and advises nothing"
assert_contains "$(cat "$TMP/n.err")" "ac-compact-advise.sh: src/compact-advise.ts exited 1 - this hook did nothing" "9: ...and the shim says it did nothing"

pass
