#!/usr/bin/env bash
# ac-brain-vector.test.sh - the vector lane's fusion contracts, proven against
# a CONTROLLED embedding provider (a local OpenAI-shaped stub that answers a
# fixed vector per input text and counts every call): a relaxed OR-fallback
# keyword row never outvotes a healthy vector arm, metadata boosts wait for a
# lexical signal, and a rebuild re-attaches still-current vectors instead of
# re-embedding them. The hash-based `stub` provider cannot pin these - its
# cosines are bucket collisions, not a chosen order.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
BRAIN="$BIN/ac-brain.sh"
export AC_BRAIN_PATTERN_FILE="$TMP/no-such-pattern-file"
j() { python3 -c "import sys, json; d=json.load(sys.stdin); print(d$1)"; }

# --- the controlled provider ---------------------------------------------------
# EMBED_RULES: {"dims":n,"rules":[["substring",[vector]],...]} - the first rule
# whose substring the input carries wins, anything else embeds to zeros (a
# zero dot product, so it never competes). EMBED_COUNT: one line per request
# carrying the number of inputs embedded, the call-count evidence.
cat >"$TMP/embed-ctl.ts" <<'TS'
import { appendFileSync } from "fs";
const spec = JSON.parse(process.env.EMBED_RULES!);
const pick = (t: string) => {
  for (const [sub, vec] of spec.rules) if (t.includes(sub)) return [...vec, ...new Array(spec.dims - vec.length).fill(0)];
  return new Array(spec.dims).fill(0);
};
const s = Bun.serve({ port: 0, fetch: async req => {
  const j: any = await req.json();
  appendFileSync(process.env.EMBED_COUNT!, j.input.length + "\n");
  return Response.json({ data: j.input.map((t: string, i: number) => ({ index: i, embedding: pick(t) })) });
} });
console.log(s.port);
await new Promise(() => {});
TS
STUB_PID=""; STUB_PORT=""
stub_up() {  # stub_up <rules-json> <dims> - starts the provider, writes brain.json at it
  local portfile="$TMP/stub.port" i=0
  : >"$portfile"
  EMBED_RULES="$1" EMBED_COUNT="$TMP/embed.count" bun "$TMP/embed-ctl.ts" >"$portfile" 2>/dev/null &
  STUB_PID=$!
  while [ "$i" -lt 100 ]; do
    [ -s "$portfile" ] && { STUB_PORT="$(cat "$portfile")"; break; }
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$STUB_PORT" ] || { stub_down; fail "the controlled embedding stub never came up"; }
  printf '{"embedding":{"provider":"ollama","model":"ctl","dims":%s,"base_url":"http://127.0.0.1:%s/v1"}}\n' \
    "$2" "$STUB_PORT" >"$AC_HOME/config/brain.json"
}
stub_down() { [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }; STUB_PID=""; STUB_PORT=""; }
embed_calls() { { cat "$TMP/embed.count" 2>/dev/null || true; } | awk '{ s += $1 } END { print s + 0 }'; }
trap 'stub_down; cleanup' EXIT

# --- relaxed OR-fallback rows never outvote a healthy vector arm ---------------
# Two pages carry "harbor" and one does not; the query's second term matches
# nothing, so the strict AND arm is empty and the OR arm relaxes onto the
# harbor pages. The provider is told the query is ABOUT the beta page.
mkdir -p "$AC_HOME/data/alpha" "$AC_HOME/data/beta" "$AC_HOME/data/gamma"
printf '# Alpha room\nThe alpha harbor manifests converge inside one cycle here.\n' >"$AC_HOME/data/alpha/room.md"
printf '# Gamma room\nThe gamma harbor harbor shard list is longer and noisier still.\n' >"$AC_HOME/data/gamma/room.md"
printf '# Beta room\nThe beta shard report lists every skipped shard for review.\n' >"$AC_HOME/data/beta/room.md"

# keyless lane: the relaxed rows are the only voters and still come back
kl="$("$BRAIN" sync --home "$AC_HOME" --compact >/dev/null && "$BRAIN" recall --query "harbor zzzmissing" --home "$AC_HOME" --compact)"
assert_contains "$kl" "data/alpha/room" "keyless: an AND miss still returns the OR rows"
case "$kl" in *relaxed_dropped*|*keyword_relaxed_carried*) fail "keyless: relaxed rows are the whole answer, not a degradation: $kl" ;; esac

RULES='{"dims":8,"rules":[["zzzmissing",[1,0,0,0,0,0,0,0]],["beta shard",[0.98,0.2,0,0,0,0,0,0]],["harbor",[0,0,1,0,0,0,0,0]]]}'
stub_up "$RULES" 8
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
vl="$("$BRAIN" recall --query "harbor zzzmissing" --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$vl" | j "['results'][0]['slug']")" "data/beta/room" \
  "with a healthy vector arm the vector winner leads; relaxed keyword rows do not outvote it"
assert_eq "$(printf '%s' "$vl" | j "['relaxed_dropped']")" "2" "the dropped relaxed rows are counted"
case "$vl" in *'"evidence":"keyword"'*) fail "a relaxed row must not wear the keyword label once dropped: $vl" ;; esac
stub_down

# vector-enabled but the arm came back empty: the relaxed rows carry, and the
# degraded stamp says so next to the cause
printf '{"embedding":{"provider":"openai","model":"m","dims":8}}\n' >"$AC_HOME/config/brain.json"
cr="$(OPENAI_API_KEY= "$BRAIN" recall --query "harbor zzzmissing" --home "$AC_HOME" --compact)"
assert_contains "$cr" "keyword_only_no_api_key" "the vector arm's own cause is still stamped"
assert_contains "$cr" "keyword_relaxed_carried" "...and the carried relaxed rows are stamped beside it"
assert_contains "$cr" "data/alpha/room" "...while the relaxed rows still answer"
rm -f "$AC_HOME/config/brain.json"

pass
