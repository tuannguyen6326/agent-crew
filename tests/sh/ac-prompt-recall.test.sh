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
rm -rf "$spool" "$AC_HOME/state/.wake-spool.fam-one"

# --- differential: src/prompt-recall.ts against the frozen bash original -----
# DISPUTED: the implementation (tests/fixtures/ac-prompt-recall.sh under bash vs src/prompt-recall.ts through bin/ac-prompt-recall.sh)
# HELD-CONSTANT: each row's home, copied whole for each side, and its cwd (the side's own home where a row says HOME); the payload on stdin; a STUB brain in each side's bin/ answering $PR_OUT with status $PR_RC (no engine, no network); the environment (AC_SOLO, AC_SCOPE, AC_BRAIN_SYNC_IV, AC_PROMPT_RECALL_LIMIT, PATH with a date stub frozen at 1800000000, EPOCHSECONDS unset; LC_ALL=C unless a row says otherwise); stdout, stderr, exit status, the stub's recall argv and each side's home tree compared whole
obin="$(make_oracle_bin ac-prompt-recall)"
cmp -s "$obin/ac-prompt-recall.sh" "$ROOT/tests/fixtures/ac-prompt-recall.sh" \
  || fail "the oracle bin must hold the frozen original"
pport="$TMP/pr-port"
mkdir -p "$pport/bin"
cp "$BIN"/*.sh "$pport/bin/"
ln -s "$ROOT/src" "$pport/src"
for b in "$obin" "$pport/bin"; do
  cat >"$b/ac-brain.sh" <<'EOF'
#!/bin/sh
case "$1" in
  recall) printf '%s\n' "$*" >>"$PR_LOG"; [ -z "${PR_OUT:-}" ] || cat "$PR_OUT"; exit "${PR_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$b/ac-brain.sh"
done
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
{"results":[{"path":"data/fam-one/room.md","trust":"unverified working material","evidence":"room","snippet":"zanzibar quorum\nreconciliation settled the order of the replicas and then some more text that keeps going well past the one hundred and forty character cut so it is clipped"},{"path":null,"snippet":"dropped"},{"path":"records/x.md","snippet":"no trust or evidence"}]}
EOF
printf '{"prompt":"what did zanzibar quorum reconciliation settle"}' >"$TMP/pr.in"
PR_OUT="$TMP/pr-hits.json"
pr_same() {  # pr_same <cwd|HOME> [VAR=VAL ...] - each side on its own copy of $ph, stdin $TMP/pr.in; the port's status in pr_rc
  local cwd="$1" s rc dir
  shift
  for s in o n; do
    rm -rf "$ph.$s" "$TMP/pr.$s.log"
    cp -Rp "$ph" "$ph.$s"
    dir="$cwd"; [ "$cwd" != HOME ] || dir="$ph.$s"
    rc=0
    (cd "$dir" && env -u AC_SOLO -u AC_SCOPE -u EPOCHSECONDS AC_HOME="$ph.$s" PR_LOG="$TMP/pr.$s.log" PR_OUT="$PR_OUT" "$@" \
      PATH="$TMP/pr-date:$PATH" LC_ALL="${DIFF_LC:-C}" \
      "$(if [ "$s" = o ]; then printf '%s' "$obin"; else printf '%s' "$pport/bin"; fi)/ac-prompt-recall.sh" <"$TMP/pr.in") \
      >"$TMP/pr.$s.out" 2>"$TMP/pr.$s.err" || rc=$?
    printf '%s\n' "$rc" >"$TMP/pr.$s.rc"
  done
  pr_rc="$(cat "$TMP/pr.n.rc")"
  assert_eq "$pr_rc" "$(cat "$TMP/pr.o.rc")" "differential exit ($*)"
  assert_eq "$pr_rc" "0" "the recall always exits 0 ($*)"
  cmp -s "$TMP/pr.o.out" "$TMP/pr.n.out" || fail "differential stdout differs ($*): $(diff "$TMP/pr.o.out" "$TMP/pr.n.out" | head -n 4)"
  cmp -s "$TMP/pr.o.err" "$TMP/pr.n.err" || fail "differential stderr differs ($*): $(diff "$TMP/pr.o.err" "$TMP/pr.n.err" | head -n 4)"
  o_txt="$(cat "$TMP/pr.o.log" 2>/dev/null; printf x)"; n_txt="$(cat "$TMP/pr.n.log" 2>/dev/null; printf x)"
  assert_eq "${n_txt//"$ph.n"/HOME}" "${o_txt//"$ph.o"/HOME}" "differential recall argv ($*)"
  diff -r "$ph.o" "$ph.n" >"$TMP/pr.diff" 2>&1 || fail "differential home trees differ ($*): $(head -n 6 "$TMP/pr.diff")"
}

# 1. the shapes and their attribution.
pr_same HOME
assert_contains "$(cat "$TMP/pr.n.out")" "by crewchief; synced 29m ago" "the chief's block on both sides"
pr_same HOME AC_SCOPE=fam-one
pr_same "$TMP/pr-elsewhere" AC_SOLO=1
pr_same "$TMP/pr-elsewhere"
pr_same "$TMP/pr-elsewhere" AC_SCOPE=fam-one
pr_same HOME AC_HOME=

# 2. the pending wakes, the gates, the valve, the prompt readings.
mkdir -p "$ph/state/.wake-spool/adir" "$ph/state/.wake-spool.fam-one"
printf 'x\n' >"$ph/state/.wake-spool/1.1.000001"
printf 'x\n' >"$ph/state/.wake-spool/.hidden"
printf 'x\n' >"$ph/state/.wake-spool.fam-one/1.1.000002"
pr_same HOME
pr_same HOME AC_SCOPE=fam-one
pr_same "$TMP/pr-elsewhere" AC_SOLO=1
rm -rf "$ph/state/.wake-spool" "$ph/state/.wake-spool.fam-one"
for p in '{"prompt":"ok"}' '{"prompt":"/compact now please"}' '{"prompt":"!git status here"}' '{"prompt":"aa bb cc dd ee ff"}' \
         '{"prompt":"zanzibarquorumreconciliation"}' '{"user_message":"what did zanzibar quorum settle"}' '{"text":"what did zanzibar quorum settle"}' \
         '{"prompt":42}' '{"prompt":"  \tzanzibar quorum reconciliation\n  "}' '{"prompt":"café été zz"}' 'not json' '' \
         '{"prompt":"zanzibar quorum"} trailing junk'; do
  printf '%s' "$p" >"$TMP/pr.in"
  pr_same HOME
done
printf '{"prompt":"caf\\u00e9 \\u00e9t\\u00e9 \\u00e0\\u00e0"}' >"$TMP/pr.in"
pr_same HOME
DIFF_LC=en_US.UTF-8 pr_same HOME
printf '{"prompt":"what did zanzibar quorum reconciliation settle"}' >"$TMP/pr.in"
printf 'off\n' >"$ph/config/brain-prompt-recall"
pr_same HOME
rm -f "$ph/config/brain-prompt-recall"
mv "$ph/state/brain.sqlite" "$TMP/pr-brain.keep"
pr_same HOME
mv "$TMP/pr-brain.keep" "$ph/state/brain.sqlite"

# 3. the recall's answer and the limit.
for lim in 5 abc '' 0; do
  pr_same HOME AC_PROMPT_RECALL_LIMIT="$lim"
done
pr_same HOME PR_RC=1
printf '{"results":[]}\n' >"$TMP/pr-none.json"
PR_OUT="$TMP/pr-none.json"
pr_same HOME
printf 'not json\n' >"$TMP/pr-none.json"
pr_same HOME
PR_OUT="$TMP/pr-hits.json"

# 4. the freshness line: never synced, fresh, stale by hours and days, the
# interval knob, the catch-up throttle.
rm -f "$ph/state/.brain-last-sync"
pr_same HOME
: >"$ph/state/.brain-last-sync"
for t in 202701150759 202701150300 202701100800; do
  TZ=UTC touch -t "$t" "$ph/state/.brain-last-sync"
  pr_same HOME
  pr_same HOME AC_BRAIN_SYNC_IV=60
  pr_same HOME AC_BRAIN_SYNC_IV=999999
done
printf 'off\n' >"$ph/config/brain-auto-sync"
pr_same HOME AC_BRAIN_SYNC_IV=60
rm -f "$ph/config/brain-auto-sync"
: >"$ph/state/.brain-freshen-attempt"
TZ=UTC touch -t 202701150759 "$ph/state/.brain-freshen-attempt"
pr_same HOME AC_BRAIN_SYNC_IV=600
rm -f "$ph/state/.brain-freshen-attempt"

# --- named divergences: each row asserts both sides ---------------------------
# BUN: no bun on PATH - the shim exits 0 at once and says nothing; the original
# (bash, jq and the stub brain) recalled. Its home is a copy: the original's
# catch-up stamp would otherwise land in the home the rows below build on.
mkdir -p "$TMP/pr-nobun"
for t in bash env cat dirname jq sed awk tr wc head stat date basename; do ln -sf "$(command -v "$t")" "$TMP/pr-nobun/$t"; done
rm -rf "$ph.nb"; cp -Rp "$ph" "$ph.nb"
o_rc=0; (cd "$ph.nb" && AC_HOME="$ph.nb" PR_LOG=/dev/null PR_OUT="$PR_OUT" PATH="$TMP/pr-nobun" "$obin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/o.out" 2>/dev/null || o_rc=$?
n_rc=0; (cd "$ph.nb" && AC_HOME="$ph.nb" PR_LOG=/dev/null PR_OUT="$PR_OUT" PATH="$TMP/pr-nobun" "$pport/bin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "BUN: both exit 0"
assert_contains "$(cat "$TMP/o.out")" "ac-brain recall for this prompt" "BUN: the original recalled"
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err")" "" "BUN: the shim says nothing"
# BUN: a module that cannot load is the same silence.
pr_lf="$TMP/pr-loadfail"
mkdir -p "$pr_lf/bin" "$pr_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-prompt-recall.sh" "$pr_lf/bin/"
printf 'throw new Error("prompt recall cannot load");\n' >"$pr_lf/src/prompt-recall.ts"
n_rc=0; (cd "$ph" && AC_HOME="$ph" "$pr_lf/bin/ac-prompt-recall.sh" <"$TMP/pr.in") >"$TMP/n.out" 2>/dev/null || n_rc=$?
assert_eq "$n_rc" "0" "BUN: a module that cannot load exits 0"
assert_eq "$(cat "$TMP/n.out")" "" "BUN: a module that cannot load injects nothing"
# FRESHEN: an attempt stamp that cannot be written - the original's failed
# redirection still fired and said so; the port fires nothing.
TZ=UTC touch -t 202701100800 "$ph/state/.brain-last-sync"
mkdir -p "$ph/state/.brain-freshen-attempt"
o_out="$(cd "$ph" && AC_HOME="$ph" PR_LOG=/dev/null PR_OUT="$PR_OUT" PATH="$TMP/pr-date:$PATH" "$obin/ac-prompt-recall.sh" <"$TMP/pr.in" 2>/dev/null)" || true
n_out="$(cd "$ph" && AC_HOME="$ph" PR_LOG=/dev/null PR_OUT="$PR_OUT" PATH="$TMP/pr-date:$PATH" "$pport/bin/ac-prompt-recall.sh" <"$TMP/pr.in" 2>/dev/null)" || true
assert_contains "$o_out" "catch-up sync fired" "FRESHEN: the original fired past its failed stamp"
assert_contains "$n_out" "STALE - last sync 5d ago" "FRESHEN: the port reads the same staleness"
case "$n_out" in *"catch-up sync fired"*) fail "FRESHEN: the port fires nothing it could not stamp" ;; esac
rmdir "$ph/state/.brain-freshen-attempt"

pass
