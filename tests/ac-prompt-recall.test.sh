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

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || { printf 'SKIP: bun not available\n'; exit 0; }

make_home
HOOK="$BIN/ac-prompt-recall.sh"
ADAPTER="$BIN/ac-prompt-recall-cursor.sh"
[ -x "$HOOK" ] || fail "missing or non-executable $HOOK"
[ -x "$ADAPTER" ] || fail "missing or non-executable $ADAPTER"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
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

pass
