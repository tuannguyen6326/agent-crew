#!/usr/bin/env bash
# ac-prompt-recall.test.sh - prompt-time fleet-memory recall for HUMAN-DRIVEN
# sessions (bin/ac-prompt-recall.sh): the hook runs between the captain's
# prompt and the model's first read, so a chief or solo session meets the
# home's history before it acts instead of remembering to ask. Contracts:
# session shape (solo or fleet-home cwd fires; a worktree is silent), the
# noise gates (short prompts, slash commands, zero hits), the config valve,
# the staleness line plus catch-up sync, usage attribution (solo names
# itself), the cursor adapter's JSON envelope, and the claude registration.
# Everything runs against an isolated temp home.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || skip 'bun not available'

make_home
# Composed at runtime: the literal shape trips GitHub push protection, and the
# gate under test reads the prompt, never this file.
SLACK_SHAPED="xoxb-$((1234567890))-$((1234567890))-abcdefghijklmnopqrstuvwx"
HOOK="$BIN/ac-prompt-recall.sh"
ADAPTER="$BIN/ac-prompt-recall-cursor.sh"
[ -x "$HOOK" ] || fail "missing or non-executable $HOOK"
[ -x "$ADAPTER" ] || fail "missing or non-executable $ADAPTER"

mtime() { bash -c '. "$0/ac-lib.sh"; ac_file_mtime "$1"' "$BIN" "$1" 2>/dev/null || echo 0; }
usage_by() { grep -o '"by":"[^"]*"' "$AC_HOME/state/brain-usage.jsonl" 2>/dev/null | tail -1; }

mkdir -p "$AC_HOME/data/fam-one" "$TMP/elsewhere"
cat >"$AC_HOME/data/fam-one/room.md" <<'EOF'
# Room: fam-one
A distinctive sentence about zanzibar quorum reconciliation lives here.
EOF
"$BIN/ac-brain.sh" sync --home "$AC_HOME" --compact >/dev/null 2>&1 \
  || fail "fixture brain sync failed"
marker="$AC_HOME/state/.brain-last-sync"
[ -f "$marker" ] || fail "fixture sync left no freshness marker"

hit='{"prompt":"what did zanzibar quorum reconciliation settle"}'
run_hook() { # run_hook <cwd> <payload> [env...]
  local cwd="$1" payload="$2"; shift 2
  (cd "$cwd" && printf '%s' "$payload" | env "$@" "$HOOK")
}

# --- 1. chief shape: cwd == fleet home fires, attributed crewchief ------------
out="$(run_hook "$AC_HOME" "$hit" AC_SOLO=)" || fail "hook must exit 0 on a hit"
assert_contains "$out" "data/fam-one/room.md" "a hit names the home-relative path"
assert_contains "$out" "unverified working material" "a hit carries its trust label"
assert_contains "$out" "cite" "the block tells the reader to cite what it uses"
assert_eq "$(usage_by)" '"by":"crewchief"' "a fleet-home session is attributed crewchief"

# --- 2. solo shape: AC_SOLO=1 fires from any cwd, attributed solo --------------
out="$(run_hook "$TMP/elsewhere" "$hit" AC_SOLO=1)"
assert_contains "$out" "data/fam-one/room.md" "a solo session recalls from outside the home"
assert_eq "$(usage_by)" '"by":"solo"' "a solo session names itself in the usage log"

# --- 3. worker shape: neither solo nor fleet-home cwd stays silent ------------
out="$(run_hook "$TMP/elsewhere" "$hit" AC_SOLO=)"
[ -z "$out" ] || fail "a worktree-shaped session must not recall per prompt: $out"

# --- 4. noise gates: short, slash, bang, zero hits ---------------------------
for p in '{"prompt":"ok"}' '{"prompt":"/compact now please"}' '{"prompt":"!git status here"}' \
         '{"prompt":"qqqxzv wwwqzx yyyqzx"}'; do
  out="$(run_hook "$AC_HOME" "$p")"
  [ -z "$out" ] || fail "gated prompt $p must emit nothing: $out"
done
out="$(printf 'not json' | (cd "$AC_HOME" && "$HOOK"))" || fail "unparseable payload must exit 0"
[ -z "$out" ] || fail "unparseable payload must emit nothing: $out"

# A harness-injected turn - a background task's notification, another agent's
# message, a system reminder - reaches the prompt hook as if the captain had
# typed it; every watcher wake is one. It pays no recall: nothing printed, no
# ac-brain.sh call (the distinctive word would hit, and the usage log would grow).
usage_lines() { wc -l <"$AC_HOME/state/brain-usage.jsonl" 2>/dev/null | tr -d ' '; }
before="$(usage_lines)"
for p in \
  '{"prompt":"<task-notification>\n<task-id>abc</task-id>\n<summary>zanzibar quorum reconciliation finished</summary>\n</task-notification>"}' \
  '{"prompt":"  <teammate-message teammate_id=\"x\">zanzibar quorum reconciliation</teammate-message>"}' \
  '{"prompt":"<agent-message from=\"a1\">zanzibar quorum reconciliation report</agent-message>"}' \
  '{"prompt":"Another Claude session sent a message:\n<agent-message from=\"a1\">zanzibar quorum reconciliation</agent-message>"}' \
  '{"prompt":"[SYSTEM NOTIFICATION - NOT USER INPUT]\nzanzibar quorum reconciliation task finished"}' \
  '{"prompt":"<system-reminder>\nzanzibar quorum reconciliation background event\n</system-reminder>"}' \
; do
  out="$(run_hook "$AC_HOME" "$p")"
  [ -z "$out" ] || fail "a harness-injected prompt must emit nothing: $p -> $out"
done
assert_eq "$(usage_lines)" "$before" "a harness-injected prompt never reaches ac-brain.sh recall"
# ...while a captain who merely mentions one of those words still recalls.
out="$(run_hook "$AC_HOME" '{"prompt":"what did zanzibar quorum reconciliation settle about the task-notification wake shape"}')"
assert_contains "$out" "data/fam-one/room.md" "a prompt mentioning a notification still recalls"

# --- secret gate: a credential-shaped token skips recall even though its
# underscores/dashes split it into runs the word-count gate alone reads as
# ordinary multi-word prose (the bug this family fixes) --------------------
usage_lines() { wc -l <"$AC_HOME/state/brain-usage.jsonl" 2>/dev/null | tr -d ' '; }
before="$(usage_lines)"
for p in \
  '{"prompt":"sk-or-v1-abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef1234"}' \
  '{"prompt":"oc_sk_1234567890abcdef1234567890"}' \
  '{"prompt":"apikey_2269aaaa_e3bd1111e3bd2222e3bd3333"}' \
  '{"prompt":"ghp_1234567890abcdefghijklmnopqrstuvwx"}' \
  '{"prompt":"github_pat_11ABCDEFG0123456789012345_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX"}' \
  '{"prompt":"AKIAABCDEFGHIJKLMNOP"}' \
  '{"prompt":"'"$SLACK_SHAPED"'"}' \
  '{"prompt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' \
  '{"prompt":"here is my key sk-or-v1-abcdefabcdefabcdefabcdefabcdef1234 please use it"}' \
  '{"prompt":"zanzibar log line \\tAKIAABCDEFGHIJKLMNOP end of line"}' \
  '{"prompt":"zanzibar pasted {\"token\":\"\\n'"$SLACK_SHAPED"'\"} body"}' \
  '{"prompt":"zanzibar url ?token=%22ghp_1234567890abcdefghij_klmnopqrstuvwx%22 here"}' \
  '{"prompt":"zanzibar quoted \\u0022sk-proj-Ab3dEf7hIj-Kl2mNo5pQr_St8uVw1xYz\\u0022 value"}' \
; do
  out="$(run_hook "$AC_HOME" "$p")"
  [ -z "$out" ] || fail "a secret-shaped prompt must emit nothing: $p -> $out"
done
after="$(usage_lines)"
[ "$before" = "$after" ] || fail "a secret-shaped prompt must never reach ac-brain.sh recall (usage log grew $before -> $after)"

# a prompt that merely mentions "key" in prose still recalls
out="$(run_hook "$AC_HOME" '{"prompt":"what did zanzibar quorum reconciliation settle - also what is the api key policy"}')"
assert_contains "$out" "data/fam-one/room.md" "a prompt merely mentioning 'key' still recalls"

# a fleet-hyphenated name (sk- as a mid-word substring, not a prefix) must
# not false-positive the secret gate - this fleet names families and skills
# exactly like task-lifecycle-skill and ask-user-relay-dropped
out="$(run_hook "$AC_HOME" '{"prompt":"what did zanzibar quorum reconciliation settle - status of task-lifecycle-skill and ask-user-relay-dropped"}')"
assert_contains "$out" "data/fam-one/room.md" "a hyphenated fleet name must not false-positive the secret gate"

# --- 5. valve ---------------------------------------------------------------
printf 'off\n' >"$AC_HOME/config/brain-prompt-recall"
out="$(run_hook "$AC_HOME" "$hit")"
[ -z "$out" ] || fail "config/brain-prompt-recall=off must silence the hook: $out"
rm -f "$AC_HOME/config/brain-prompt-recall"

# --- 6. staleness: a stale marker is named and a catch-up sync fires ---------
touch -t 202601010000 "$marker"
old="$(mtime "$marker")"
rm -f "$AC_HOME/state/.brain-freshen-attempt"
out="$(run_hook "$AC_HOME" "$hit" AC_BRAIN_SYNC_IV=60)"
assert_contains "$(printf '%s\n' "$out" | head -1)" "STALE" "a marker past the interval is called out in the header"
i=0
while [ "$i" -lt 150 ]; do
  [ "$(mtime "$marker")" -gt "$old" ] && break
  sleep 0.1; i=$((i + 1))
done
[ "$(mtime "$marker")" -gt "$old" ] || fail "a stale marker fires a catch-up sync from the hook"
out="$(run_hook "$AC_HOME" "$hit" AC_BRAIN_SYNC_IV=86400)"
case "$(printf '%s\n' "$out" | head -1)" in *STALE*) fail "a fresh marker must not be called stale: $out" ;; esac

# --- 7. no brain -> silent (DB existence is the opt-in) ----------------------
mv "$AC_HOME/state/brain.sqlite" "$TMP/brain.bak"
out="$(run_hook "$AC_HOME" "$hit")"
[ -z "$out" ] || fail "no brain.sqlite must mean no recall: $out"
mv "$TMP/brain.bak" "$AC_HOME/state/brain.sqlite"

# --- 8. cursor adapter: always a continue envelope, context only on a hit ----
out="$(cd "$AC_HOME" && printf '%s' "$hit" | "$ADAPTER")" || fail "adapter must exit 0"
assert_eq "$(jq -r '.continue' <<<"$out")" "true" "the adapter never blocks the prompt"
case "$(jq -r '.additional_context // empty' <<<"$out")" in
  *data/fam-one/room.md*) ;;
  *) fail "a hit must ride additional_context: $out" ;;
esac
out="$(cd "$AC_HOME" && printf '{"prompt":"ok"}' | "$ADAPTER")"
assert_eq "$(jq -r '.continue' <<<"$out")" "true" "a gated prompt still continues"
[ "$(jq -r '.additional_context // empty' <<<"$out")" = "" ] \
  || fail "a gated prompt must carry no additional_context: $out"

# --- 9. engine attribution: a solo session's own brain calls say so ----------
(cd "$AC_HOME" && AC_SOLO=1 "$BIN/ac-brain.sh" recall --home "$AC_HOME" --query "zanzibar quorum" --compact >/dev/null)
assert_eq "$(usage_by)" '"by":"solo"' "AC_SOLO=1 attributes a bare recall to solo"
(cd "$AC_HOME" && AC_SOLO=1 AC_SCOPE=fam-one "$BIN/ac-brain.sh" recall --home "$AC_HOME" --query "zanzibar quorum" --compact >/dev/null)
assert_eq "$(usage_by)" '"by":"solo"' "solo wins over an inherited AC_SCOPE"

# --- 10. claude registration ------------------------------------------------
cl="$ROOT/.claude/settings.json"
case "$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | .[]' "$cl")" in
  *ac-prompt-recall.sh*) ;;
  *) fail "claude UserPromptSubmit wiring misses ac-prompt-recall.sh" ;;
esac

# --- 11. pending wakes: a chief meets its queue at the prompt, not at Stop -----
# The turn-end guard refuses a turn end while wakes are queued, so a chief that
# answered the captain first only learned of them after doing the work. The
# hook PEEKS - the drain consumes records, and a hook must never do that.
spool="$AC_HOME/state/.wake-spool"
mkdir -p "$spool"
printf '1\treport\tcrew-a\tdone: shipped\n' >"$spool/1.1.000001"
out="$(run_hook "$AC_HOME" '{"prompt":"ok"}' AC_SOLO=)"
assert_contains "$out" "1 queued wake" "a chief is told its queued wakes even on a prompt the recall gates skip"
assert_contains "$out" "ac-wake-drain.sh" "the line names the drain to run"
assert_eq "$(find "$spool" -type f | wc -l | tr -d ' ')" "1" "the peek never consumes a record"
out="$(run_hook "$TMP/elsewhere" '{"prompt":"ok"}' AC_SOLO=1)"
case "$out" in *"queued wake"*) fail "a solo session owns no wakes and must not be told to drain: $out" ;; esac
out="$(run_hook "$TMP/elsewhere" '{"prompt":"ok"}' AC_SOLO=)"
[ -z "$out" ] || fail "a worker-shaped session stays silent: $out"
out="$(run_hook "$AC_HOME" '{"prompt":"ok"}' AC_SOLO= AC_SCOPE=fam-one)"
case "$out" in *"queued wake"*) fail "a roomchief is not told of the FLEET spool: $out" ;; esac
mkdir -p "$AC_HOME/state/.wake-spool.fam-one"
printf '1\treport\tfam-one-x\tdone: y\n' >"$AC_HOME/state/.wake-spool.fam-one/1.1.000001"
out="$(run_hook "$AC_HOME" '{"prompt":"ok"}' AC_SOLO= AC_SCOPE=fam-one)"
assert_contains "$out" "1 queued wake" "a roomchief is told of its own family spool"
# a secret-shaped prompt stays silent even with a wake queued - it must leave
# no trace at all, not even the unrelated queued-wake notice
out="$(run_hook "$AC_HOME" '{"prompt":"sk-or-v1-abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef1234"}' AC_SOLO=)"
[ -z "$out" ] || fail "a secret-shaped prompt must stay silent even with a wake queued: $out"
rm -rf "$spool" "$AC_HOME/state/.wake-spool.fam-one"

# --- the block's bytes and the recall's argv, row by row ----------------------
# Each row runs the shim on a fresh copy of $ph ($ph.n; cwd there where a row
# says HOME) with the payload $TMP/pr.in on stdin. A STUB brain in the shim's
# bin/ answers $PR_OUT and logs its recall argv (no engine, no network); a date
# stub freezes the clock at 1800000000, EPOCHSECONDS unset; LC_ALL=C unless a
# row sets RUN_LC.
pport="$TMP/pr-port"
mkdir -p "$pport/bin"
cp "$BIN"/*.sh "$pport/bin/"
ln -s "$ROOT/src" "$pport/src"
cat >"$pport/bin/ac-brain.sh" <<'EOF'
#!/bin/sh
case "$1" in
  recall) printf '%s\n' "$*" >>"$PR_LOG"; [ -z "${PR_OUT:-}" ] || cat "$PR_OUT"; exit "${PR_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$pport/bin/ac-brain.sh"
mkdir -p "$TMP/pr-date"
printf '#!/bin/sh\ncase "$*" in *%%s*) echo 1800000000 ;; *) echo 2027-01-15T08:00:00Z ;; esac\n' >"$TMP/pr-date/date"
chmod +x "$TMP/pr-date/date"
ph="$TMP/pr-home"
rm -rf "$ph"; mkdir -p "$ph/state" "$ph/config" "$ph/records"
: >"$ph/state/brain.sqlite"
: >"$ph/state/.brain-last-sync"
TZ=UTC touch -t 202701150731 "$ph/state/.brain-last-sync"
mkdir -p "$TMP/pr-elsewhere"
cat >"$TMP/pr-hits.json" <<'EOF'
{"results":[{"path":"data/fam-one/room.md","trust":"unverified working material","evidence":"room","snippet":"zanzibar quorum\nreconciliation settled the order of the replicas and then some more text that keeps going well past the one hundred and forty character cut so it is clipped"},{"path":"records/x.md","snippet":"no trust or evidence"}]}
EOF
PR_HITS='- data/fam-one/room.md [unverified working material; room] zanzibar quorum reconciliation settled the order of the replicas and then some more text that keeps going well past the one hundred and fort
- records/x.md [?; ?] no trust or evidence
Use a hit only after reading its path; cite path + quote when it shapes the answer. A STALE brain is missing history after its last sync.'
PR_WAKES="wait in this session's spool - run bin/ac-wake-drain.sh and handle them before acting on this prompt."
PR_Q='what did zanzibar quorum reconciliation settle'
printf '{"prompt":"%s"}' "$PR_Q" >"$TMP/pr.in"
PR_OUT="$TMP/pr-hits.json"
pr_run() {  # pr_run <cwd|HOME> [VAR=VAL ...] - sets pr_rc, pr_out, pr_err and pr_log (the stub's recall argv, the home spelled HOME)
  local cwd="$1" dir
  shift
  rm -rf "$ph.n" "$TMP/pr.log"
  cp -Rp "$ph" "$ph.n"
  dir="$cwd"; [ "$cwd" != HOME ] || dir="$ph.n"
  pr_rc=0
  (cd "$dir" && env -u AC_SOLO -u AC_SCOPE -u EPOCHSECONDS AC_HOME="$ph.n" PR_LOG="$TMP/pr.log" PR_OUT="$PR_OUT" "$@" \
    PATH="$TMP/pr-date:$PATH" LC_ALL="${RUN_LC:-C}" "$pport/bin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/pr.out" 2>"$TMP/pr.err" || pr_rc=$?
  pr_out="$(cat "$TMP/pr.out")"; pr_err="$(cat "$TMP/pr.err")"
  pr_log="$(cat "$TMP/pr.log" 2>/dev/null || true)"; pr_log="${pr_log//"$ph.n"/HOME}"
}
pr_block() {  # pr_block <by> <freshness> <query> <limit> <label> - exit 0, exactly that block (PR_PRE ahead of it), one recall
  assert_eq "$pr_rc|$pr_err|$pr_out" "0||${PR_PRE:-}ac-brain recall for this prompt (fleet memory, by $1; $2):
$PR_HITS" "$5: the block"
  assert_eq "$pr_log" "recall --home HOME --query $3 --limit $4 --by $1 --compact" "$5: the recall's argv"
}
pr_silent() {  # pr_silent <label> - exit 0, nothing printed, the brain never asked
  assert_eq "$pr_rc|$pr_out|$pr_err|$pr_log" "0|||" "$1"
}
pr_stamped() { [ -e "$ph.n/state/.brain-freshen-attempt" ] && printf yes || printf no; }

# 1. the shapes and their attribution.
pr_run HOME; pr_block crewchief "synced 29m ago" "$PR_Q" 3 "a chief at its home"
pr_run HOME AC_SCOPE=fam-one; pr_block fam-one-chief "synced 29m ago" "$PR_Q" 3 "a roomchief at its home"
pr_run "$TMP/pr-elsewhere" AC_SOLO=1; pr_block solo "synced 29m ago" "$PR_Q" 3 "a solo session elsewhere"
pr_run "$TMP/pr-elsewhere" AC_SCOPE=fam-one; pr_silent "a scoped session outside the home is no chief"
pr_run HOME AC_HOME=; pr_silent "no AC_HOME is silence"

# 2. the pending wakes count regular, undotted files of the session's own
# spool; the word gate; the prompt's other keys and its trimming.
mkdir -p "$ph/state/.wake-spool/adir" "$ph/state/.wake-spool.fam-one"
printf 'x\n' >"$ph/state/.wake-spool/1.1.000001"
printf 'x\n' >"$ph/state/.wake-spool/.hidden"
printf 'x\n' >"$ph/state/.wake-spool.fam-one/1.1.000002"
printf 'x\n' >"$ph/state/.wake-spool.fam-one/1.1.000003"
PR_PRE="agent-crew: 1 queued wake(s) $PR_WAKES
"
pr_run HOME; pr_block crewchief "synced 29m ago" "$PR_Q" 3 "a chief with one queued wake"
PR_PRE="agent-crew: 2 queued wake(s) $PR_WAKES
"
pr_run HOME AC_SCOPE=fam-one; pr_block fam-one-chief "synced 29m ago" "$PR_Q" 3 "a roomchief with two in its family spool"
PR_PRE=""
pr_run "$TMP/pr-elsewhere" AC_SOLO=1; pr_block solo "synced 29m ago" "$PR_Q" 3 "a solo session is told of no wakes"
rm -rf "$ph/state/.wake-spool" "$ph/state/.wake-spool.fam-one"
for p in '{"prompt":"aa bb cc dd ee ff"}' '{"prompt":"zanzibarquorumreconciliation"}' '{"prompt":42}' ''; do
  printf '%s' "$p" >"$TMP/pr.in"
  pr_run HOME; pr_silent "under two content words: '$p'"
done
for k in user_message text; do
  printf '{"%s":"what did zanzibar quorum settle"}' "$k" >"$TMP/pr.in"
  pr_run HOME; pr_block crewchief "synced 29m ago" "what did zanzibar quorum settle" 3 "the prompt under .$k"
done
printf '%s' '{"prompt":"  \tzanzibar quorum reconciliation\n  "}' >"$TMP/pr.in"
pr_run HOME; pr_block crewchief "synced 29m ago" "zanzibar quorum reconciliation" 3 "a trimmed prompt"
# 15 bytes but 11 characters: two words short under C, under 12 characters
# in a UTF-8 locale.
printf '{"prompt":"caf\\u00e9 \\u00e9t\\u00e9 \\u00e0\\u00e0"}' >"$TMP/pr.in"
pr_run HOME; pr_silent "a short accented prompt under C"
RUN_LC=en_US.UTF-8 pr_run HOME; pr_silent "...and under a UTF-8 locale"
printf '{"prompt":"%s"}' "$PR_Q" >"$TMP/pr.in"

# 3. the limit, and a recall with no hits.
for lim in 5 0; do
  pr_run HOME AC_PROMPT_RECALL_LIMIT="$lim"; pr_block crewchief "synced 29m ago" "$PR_Q" "$lim" "limit $lim"
done
for lim in abc ''; do
  pr_run HOME AC_PROMPT_RECALL_LIMIT="$lim"; pr_block crewchief "synced 29m ago" "$PR_Q" 3 "limit '$lim' reads 3"
done
printf '{"results":[]}\n' >"$TMP/pr-none.json"
PR_OUT="$TMP/pr-none.json"
pr_run HOME
assert_eq "$pr_rc|$pr_out|$pr_err" "0||" "zero hits print nothing"
assert_eq "$pr_log" "recall --home HOME --query $PR_Q --limit 3 --by crewchief --compact" "...after the one recall"
PR_OUT="$TMP/pr-hits.json"

# 4. the freshness line: never synced, fresh, stale by hours and days, the
# interval knob, the catch-up's valve and throttle.
rm -f "$ph/state/.brain-last-sync"
pr_run HOME; pr_block crewchief "never synced" "$PR_Q" 3 "no marker"
: >"$ph/state/.brain-last-sync"
TZ=UTC touch -t 202701150759 "$ph/state/.brain-last-sync"
pr_run HOME; pr_block crewchief "synced 1m ago" "$PR_Q" 3 "a minute-old marker"
assert_eq "$(pr_stamped)" no "a fresh brain fires no catch-up"
pr_run HOME AC_BRAIN_SYNC_IV=60; pr_block crewchief "STALE - last sync 0h ago, catch-up sync fired" "$PR_Q" 3 "a minute-old marker at a 60s interval"
assert_eq "$(pr_stamped)" yes "a fired catch-up leaves its attempt stamp"
TZ=UTC touch -t 202701150300 "$ph/state/.brain-last-sync"
pr_run HOME; pr_block crewchief "STALE - last sync 5h ago, catch-up sync fired" "$PR_Q" 3 "five hours at the default interval"
pr_run HOME AC_BRAIN_SYNC_IV=999999; pr_block crewchief "synced 300m ago" "$PR_Q" 3 "five hours under a longer interval"
TZ=UTC touch -t 202701100800 "$ph/state/.brain-last-sync"
pr_run HOME; pr_block crewchief "STALE - last sync 5d ago, catch-up sync fired" "$PR_Q" 3 "five days"
printf 'off\n' >"$ph/config/brain-auto-sync"
pr_run HOME AC_BRAIN_SYNC_IV=60; pr_block crewchief "STALE - last sync 5d ago" "$PR_Q" 3 "config/brain-auto-sync=off"
assert_eq "$(pr_stamped)" no "the valve fires no catch-up"
rm -f "$ph/config/brain-auto-sync"
: >"$ph/state/.brain-freshen-attempt"
TZ=UTC touch -t 202701150759 "$ph/state/.brain-freshen-attempt"
pr_run HOME AC_BRAIN_SYNC_IV=600; pr_block crewchief "STALE - last sync 5d ago" "$PR_Q" 3 "an attempt inside the interval throttles the catch-up"
rm -f "$ph/state/.brain-freshen-attempt"
# an attempt stamp that cannot be written fires nothing
mkdir -p "$ph/state/.brain-freshen-attempt"
pr_run HOME; pr_block crewchief "STALE - last sync 5d ago" "$PR_Q" 3 "an unwritable attempt stamp"
rmdir "$ph/state/.brain-freshen-attempt"

# 5. no bun on PATH: the shim exits 0 at once, saying so in one stderr line;
# a module that cannot load is the same no-op, said the same way.
mkdir -p "$TMP/pr-nobun"
for t in bash env cat dirname jq sed awk tr wc head stat date basename; do ln -sf "$(command -v "$t")" "$TMP/pr-nobun/$t"; done
n_rc=0; (cd "$ph" && AC_HOME="$ph" PR_LOG=/dev/null PR_OUT="$PR_OUT" PATH="$TMP/pr-nobun" "$pport/bin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc|$(cat "$TMP/n.out")|$(cat "$TMP/n.err")" "0||ac-prompt-recall.sh: bun is not on PATH - this hook did nothing" "no bun: exit 0, nothing injected, one stderr line"
pr_lf="$TMP/pr-loadfail"
mkdir -p "$pr_lf/bin" "$pr_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-prompt-recall.sh" "$pr_lf/bin/"
printf 'throw new Error("prompt recall cannot load");\n' >"$pr_lf/src/prompt-recall.ts"
n_rc=0; (cd "$ph" && AC_HOME="$ph" "$pr_lf/bin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "0" "a module that cannot load exits 0"
assert_eq "$(cat "$TMP/n.out")" "" "a module that cannot load injects nothing"
assert_contains "$(cat "$TMP/n.err")" "ac-prompt-recall.sh: src/prompt-recall.ts exited 1 - this hook did nothing" "the shim says it did nothing"

pass
