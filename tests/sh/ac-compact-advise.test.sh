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

# 9. Wiring: the claude Stop hooks include the adviser.
case "$(jq -r '[.hooks.Stop[].hooks[].command] | .[]' "$ROOT/.claude/settings.json")" in
  *ac-compact-advise.sh*) ;;
  *) fail "claude Stop wiring misses ac-compact-advise.sh" ;;
esac

# --- differential: src/compact-advise.ts against the frozen bash original ----
# DISPUTED: the implementation (tests/fixtures/ac-compact-advise.sh under bash vs src/compact-advise.ts through bin/ac-compact-advise.sh)
# HELD-CONSTANT: each row's home, copied whole for each side, and its cwd (the side's own home where a row says HOME); argv; the stdin bytes; the transcripts; the fake curl's canned answer and the fake herdr's panes; the environment (AC_SOLO, AC_COMPACT_WINDOW, AC_COMPACT_SEND_WAIT, a TMPDIR per side, PATH with a date stub frozen at one instant; LC_ALL=C unless a row says otherwise); both sides reach the same bin/ac-jev.sh and bin/ac-send.sh; stdout, stderr and exit status, the posted body and each side's home tree after the run (send.log once the detached sender wrote) compared whole
obin="$(make_oracle_bin ac-compact-advise)"
cmp -s "$obin/ac-compact-advise.sh" "$ROOT/tests/fixtures/ac-compact-advise.sh" \
  || fail "the oracle bin must hold the frozen original"
mkdir -p "$TMP/ca-date"
printf '#!/bin/sh\ncase "$*" in *%%s*) echo 1800000000 ;; *) echo 2027-01-15T08:00:00Z ;; esac\n' >"$TMP/ca-date/date"
chmod +x "$TMP/ca-date/date"
ch="$TMP/ca-home"
rm -rf "$ch"; mkdir -p "$ch/state" "$ch/config"
cp "$AC_HOME/config/providers.json" "$ch/config/"
printf 'on\n' >"$ch/config/jev"
: >"$TMP/ca.in"
ca_same() {  # ca_same <cwd|HOME> [VAR=VAL | SHELLERR ...] -- <args...> - each side on its own copy of $ch, stdin $TMP/ca.in; the port's status in ca_rc
  local cwd="$1" envs=() shellerr="" s rc dir
  shift
  while [ "$1" != -- ]; do
    if [ "$1" = SHELLERR ]; then shellerr=1; else envs+=("$1"); fi
    shift
  done
  shift
  for s in o n; do
    rm -rf "$ch.$s" "$TMP/ca-tmp.$s"
    cp -R "$ch" "$ch.$s"
    mkdir -p "$TMP/ca-tmp.$s"
    dir="$cwd"; [ "$cwd" != HOME ] || dir="$ch.$s"
    rc=0
    (cd "$dir" && env -u AC_SOLO AC_HOME="$ch.$s" ${envs[@]+"${envs[@]}"} TMPDIR="$TMP/ca-tmp.$s" FAKE_BODY="$TMP/ca.$s.body" \
      PATH="$TMP/ca-date:$PATH" LC_ALL="${DIFF_LC:-C}" \
      "$(if [ "$s" = o ]; then printf '%s' "$obin"; else printf '%s' "$BIN"; fi)/ac-compact-advise.sh" "$@" <"$TMP/ca.in") \
      >"$TMP/ca.$s.out" 2>"$TMP/ca.$s.err" || rc=$?
    printf '%s\n' "$rc" >"$TMP/ca.$s.rc"
  done
  ca_rc="$(cat "$TMP/ca.n.rc")"
  assert_eq "$ca_rc" "$(cat "$TMP/ca.o.rc")" "differential exit ($*)"
  assert_eq "$ca_rc" "0" "the adviser always exits 0 ($*)"
  cmp -s "$TMP/ca.o.out" "$TMP/ca.n.out" || fail "differential stdout differs ($*): $(diff "$TMP/ca.o.out" "$TMP/ca.n.out" | head -n 4)"
  # SHELL-OWN STDERR: where the original's arithmetic failed its line was the shell's
  if [ -n "$shellerr" ]; then
    assert_eq "$(cat "$TMP/ca.n.err")" "" "the port adds no line of its own ($*)"
  else
    cmp -s "$TMP/ca.o.err" "$TMP/ca.n.err" || fail "differential stderr differs ($*): $(diff "$TMP/ca.o.err" "$TMP/ca.n.err" | head -n 4)"
  fi
  cmp -s "$TMP/ca.o.body" "$TMP/ca.n.body" 2>/dev/null || [ ! -e "$TMP/ca.o.body" ] || fail "differential posted body differs ($*)"
  # a detached sender writes its line after the hook returned
  if grep -q 'is typed into' "$TMP/ca.o.out"; then
    for _ in $(seq 1 50); do
      [ -s "$ch.o/state/.compact-advise/send.log" ] && [ -s "$ch.n/state/.compact-advise/send.log" ] && break
      sleep 0.1
    done
  fi
  rm -f "$TMP/ca.o.body" "$TMP/ca.n.body"
  diff -r "$ch.o" "$ch.n" >"$TMP/ca.diff" 2>&1 || fail "differential home trees differ ($*): $(head -n 6 "$TMP/ca.diff")"
}
cap="$TMP/ca.jsonl"; transcript "$cap" 150000
resp 0.96 0.1

# 1. the CLI judge: the knob, the roles, the argument shapes, the token readings.
ca_same "$TMP" -- "$cap" --role chief
assert_contains "$(cat "$TMP/ca.n.out")" "compact=advise score=0.96 floor=0.575 usage=0.75" "the chief line on both sides"
for a in "--role crew" "--role" "--role=chief" "chief" "--role bogus" "--role ''"; do
  # shellcheck disable=SC2086
  ca_same "$TMP" -- "$cap" $a
done
ca_same "$TMP" --
ca_same "$TMP" -- "$TMP/ca-none.jsonl" --role chief
ca_same "$TMP" -- "$TMP" --role chief
for k in off shadow; do
  printf '%s\n' "$k" >"$ch/config/jev"
  ca_same "$TMP" -- "$cap" --role chief
done
printf 'on\n' >"$ch/config/jev"
for f in 1 0.5 0.2; do
  for hh in 1 0.9 0.1 0; do
    resp "$f" "$hh"
    ca_same "$TMP" -- "$cap" --role crew
    ca_same "$TMP" -- "$cap" --role chief
  done
done
resp 0.96 0.9
for t in 39999 40000 45000 179999 180000 200000 260000; do
  transcript "$TMP/ca-t.jsonl" "$t"
  ca_same "$TMP" -- "$TMP/ca-t.jsonl" --role crew
done
transcript "$TMP/ca-t.jsonl" 150000
printf 'not json\n' >>"$TMP/ca-t.jsonl"
ca_same "$TMP" -- "$TMP/ca-t.jsonl" --role crew
jq -nc '{type: "assistant", message: {role: "assistant", usage: {input_tokens: "lots"}}}' >>"$TMP/ca-t.jsonl"
ca_same "$TMP" -- "$TMP/ca-t.jsonl" --role crew
{ jq -nc '{type: "assistant", message: {role: "assistant", content: "x", usage: {input_tokens: 150000}}}'; for _ in $(seq 1 400); do printf '{"type":"user","message":{"role":"user","content":"pad"}}\n'; done; } >"$TMP/ca-t.jsonl"
ca_same "$TMP" -- "$TMP/ca-t.jsonl" --role crew

# 2. the window: the environment, the config, the digit guard.
for w in 300000 0200000 08 abc 0 1000000; do
  printf '%s\n' "$w" >"$ch/config/compact-window"
  ca_same "$TMP" -- "$cap" --role chief
  ca_same "$TMP" AC_COMPACT_WINDOW="$w" -- "$cap" --role chief
done
rm -f "$ch/config/compact-window"

# 3. the state sent: the redactions, the clips, the byte cap.
sec="$TMP/ca-secret.jsonl"
transcript "$sec" 150000 'PASSWORD=hunter2hunter, token: abc}def ghp_abcdefghijklmnopqrstuv AKIAABCDEFGHIJKLMNOP xoxb-1234567890-ab AIzaabcdefghijklmnopqrstuvwxyz0123 -----BEGIN RSA PRIVATE KEY----- MIIE access_key = x,y'
ca_same "$TMP" -- "$sec" --role chief
{ jq -nc --arg t "$(head -c 600 /dev/zero | tr '\0' r)" '{type: "user", message: {role: "user", content: [{type: "tool_result", content: $t}]}}'
  jq -nc '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", name: "Bash"}], usage: {input_tokens: 150000}}}'
  for _ in $(seq 1 70); do jq -nc --arg t "caf$(printf '\303\251')$(head -c 400 /dev/zero | tr '\0' z)" '{type: "user", message: {role: "user", content: $t}}'; done
} >"$TMP/ca-big.jsonl"
ca_same "$TMP" -- "$TMP/ca-big.jsonl" --role chief

# 4. the hook: the shapes it judges, the marks, the payload readings.
resp 0.96 0.1
ca_payload() { jq -nc --arg p "${2:-$cap}" --arg s "$1" '{session_id: $s, transcript_path: $p, stop_hook_active: false}' >"$TMP/ca.in"; }
ca_payload s-1
ca_same HOME -- --hook
assert_contains "$(cat "$TMP/ca.n.out")" "systemMessage" "the hook advises on both sides"
mkdir -p "$ch/state/.compact-advise"
for m in 15 14 16 x 08 ''; do
  printf '%s\n' "$m" >"$ch/state/.compact-advise/s-1"
  ca_same HOME -- --hook
done
rm -rf "$ch/state/.compact-advise"
ca_same "$TMP" -- --hook
ca_same "$TMP" AC_SOLO=1 -- --hook
for p in '{"stop_hook_active":true}' '{"stop_hook_active":"no","session_id":"s","transcript_path":"/x"}' 'not json' '' '{} 5'; do
  printf '%s' "$p" >"$TMP/ca.in"
  ca_same HOME -- --hook
done
for sid in 'a/b' '' 'ok_id-1'; do
  ca_payload "$sid"
  ca_same HOME -- --hook
done
ca_payload s-9 "$TMP/ca-none.jsonl"
ca_same HOME -- --hook
ca_payload s-1
transcript "$TMP/ca-low.jsonl" 100000
ca_payload s-5 "$TMP/ca-low.jsonl"
mkdir -p "$ch/state/.compact-advise"
printf '15\n' >"$ch/state/.compact-advise/s-5"
ca_same HOME -- --hook
rm -rf "$ch/state/.compact-advise"

# 5. AUTO: the owning meta, the minimum, the knob spellings; the detached
# sender's line once it lands (the fake herdr pane idle).
make_fake_herdr
printf 'backend=herdr\nkind=roomchief\nsession_id=s-9\n' >"$ch/state/zz-chief.meta"
printf 'backend=herdr\nkind=roomchief\nsession_id=s-9\n' >"$ch/state/aa-chief.meta"
printf 'session_id=s-9\r\n' >"$ch/state/crlf.meta"
for c in aa-chief zz-chief; do
  printf 'pA tA\n' >"$ch/state/.pane-$c"
done
printf 'pA\n' >"$FAKE_HERDR/tabs/tA"
printf 'working\n' >"$FAKE_HERDR/panes/pA.status"
: >"$FAKE_HERDR/panes/pA.buf"
ca_payload s-9
for auto in off ON on; do
  printf '%s\n' "$auto" >"$ch/config/compact-auto"
  ca_same HOME AC_COMPACT_SEND_WAIT=0 -- --hook
done
for min in 20 050 abc 150; do
  printf '%s\n' "$min" >"$ch/config/compact-auto-min"
  ca_same HOME AC_COMPACT_SEND_WAIT=0 -- --hook
done
# W2: `08` is no octal number - the original's ERR trap ended the hook there.
printf '08\n' >"$ch/config/compact-auto-min"
ca_same HOME SHELLERR AC_COMPACT_SEND_WAIT=0 -- --hook
assert_eq "$(cat "$TMP/ca.n.out")" "" "AT PARITY (W2): an octal-invalid minimum ends the hook silent"
rm -f "$ch/config/compact-auto-min" "$ch/config/compact-auto"

# 6. --send by hand: no id, a busy pane, an unknown id, the wait knob.
ca_same "$TMP" -- --send
ca_same "$TMP" AC_COMPACT_SEND_WAIT=0 -- --send aa-chief
ca_same "$TMP" AC_COMPACT_SEND_WAIT=0 -- --send no-such
ca_same "$TMP" SHELLERR AC_COMPACT_SEND_WAIT=abc -- --send aa-chief
ca_same "$TMP" AC_COMPACT_SEND_WAIT=1 -- --send aa-chief

# --- named divergences: each row asserts both sides ---------------------------
# BUN: no bun on PATH - the shim exits 0 at once, saying nothing; the original
# (bash and jq) reached its sibling bin/ac-jev.sh, whose shim refuses without
# bun, so its fail-soft ask read no answer and it advised nothing.
mkdir -p "$TMP/ca-nobun"
for t in bash env cat dirname jq sed awk head tail tr mktemp rm grep basename date mkdir; do ln -sf "$(command -v "$t")" "$TMP/ca-nobun/$t"; done
o_rc=0; (cd "$TMP" && AC_HOME="$ch" PATH="$TMP/ca-nobun" "$obin/ac-compact-advise.sh" "$cap" --role chief) >"$TMP/o.out" 2>"$TMP/o.err" </dev/null || o_rc=$?
n_rc=0; (cd "$TMP" && AC_HOME="$ch" PATH="$TMP/ca-nobun" "$BIN/ac-compact-advise.sh" "$cap" --role chief) >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "BUN: both exit 0"
assert_eq "$(cat "$TMP/o.out")" "" "BUN: the original advises nothing"
assert_eq "$(cat "$TMP/o.err")" "ERROR: required tool not found: bun" "BUN: the original's ask met the jev shim's refusal"
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err")" "" "BUN: the shim says nothing"
# BUN: a module that cannot load is the same silence.
ca_lf="$TMP/ca-loadfail"
mkdir -p "$ca_lf/bin" "$ca_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-compact-advise.sh" "$ca_lf/bin/"
printf 'throw new Error("compact adviser cannot load");\n' >"$ca_lf/src/compact-advise.ts"
n_rc=0; (cd "$TMP" && AC_HOME="$ch" "$ca_lf/bin/ac-compact-advise.sh" "$cap" --role chief) >"$TMP/n.out" 2>"$TMP/n.err" </dev/null || n_rc=$?
assert_eq "$n_rc" "0" "BUN: a module that cannot load exits 0"
assert_eq "$(cat "$TMP/n.out")" "" "BUN: a module that cannot load advises nothing"
# W4: a session_id holding `é` - bash's bracket under UTF-8 let it through.
ca_payload "$(printf 's\303\251')"
o_rc=0; (cd "$ch" && AC_HOME="$ch" TMPDIR="$TMP/ca-tmp.o" PATH="$TMP/ca-date:$PATH" LC_ALL=en_US.UTF-8 "$obin/ac-compact-advise.sh" --hook <"$TMP/ca.in") >"$TMP/o.out" 2>/dev/null || o_rc=$?
rm -rf "$ch/state/.compact-advise"
n_rc=0; (cd "$ch" && AC_HOME="$ch" TMPDIR="$TMP/ca-tmp.n" PATH="$TMP/ca-date:$PATH" LC_ALL=en_US.UTF-8 "$BIN/ac-compact-advise.sh" --hook <"$TMP/ca.in") >"$TMP/n.out" 2>/dev/null || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "W4: both exit 0"
assert_contains "$(cat "$TMP/o.out")" "systemMessage" "W4: the original judged the session"
assert_eq "$(cat "$TMP/n.out")" "" "W4: the port refuses the id per its text"
# W1: a meta naming no supported backend ended the sender 1; the shim folds it.
printf 'backend=tmux\nsession_id=s-w1\n' >"$ch/state/w1.meta"
o_rc=0; (cd "$TMP" && AC_HOME="$ch" AC_COMPACT_SEND_WAIT=0 "$obin/ac-compact-advise.sh" --send w1) >/dev/null 2>"$TMP/o.err" </dev/null || o_rc=$?
n_rc=0; (cd "$TMP" && AC_HOME="$ch" AC_COMPACT_SEND_WAIT=0 "$BIN/ac-compact-advise.sh" --send w1) >/dev/null 2>"$TMP/n.err" </dev/null || n_rc=$?
assert_eq "$o_rc $n_rc" "1 0" "W1: the original ended 1, the shim answers 0"
assert_contains "$(cat "$TMP/n.err")" "unsupported backend" "W1: the refusal is still said"
rm -f "$ch/state/w1.meta"

pass
