#!/usr/bin/env bash
# ac-brain-rerank.test.sh - the reranker's relational pin, proven against a
# CONTROLLED cross-encoder (a local stub answering the rerank endpoint shape,
# scoring each document by query-term overlap on its snippet). The reranker
# only ever sees `title + "\n" + snippet`, so a hit that earned its fused rank
# from a signal outside that text - a slug match, a title phrase - loses it
# to a page whose snippet merely mentions the words.
#
# MEASUREMENT (2026-09-20, this corpus, snippet-overlap stub, no pin), gold
# rank fused -> reranked:
#   relational  harbor sync 1->4  pane resize 1->3  payproc 1->3
#               b2c shop 1->1 (2 hits, below the >=3 rerank gate)
#               ledger guard refusal 1->1 (title_phrase; the snippet itself
#               carries the words)   worktree lease 2->3 (500 backlinks,
#               evidence still `keyword`: the backlink boost at :848 is
#               +12% at 500 links, never enough to EARN a rank, so no hit
#               here is backlink-earned and the pin does not cover backlinks)
#   ordinary    exponential backoff retries 1->1  refusal counts quarter 1->1
#               captain orders public push 1->1  checkout catalog promotions
#               1->1  build pipeline caches 1->1  skipped shard report 1->2
# Three of five slug/title hits are buried; the pin below lifts them back.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
BRAIN="$BIN/ac-brain.sh"
export AC_BRAIN_PATTERN_FILE="$TMP/no-such-pattern-file"
j() { python3 -c "import sys, json; d=json.load(sys.stdin); print(d$1)"; }
rank_of() {  # rank_of <slug> - 1-based rank in results, MISS when absent
  python3 -c "import sys, json; s=[r['slug'] for r in json.load(sys.stdin)['results']]; print(s.index(sys.argv[1])+1 if sys.argv[1] in s else 'MISS')" "$1"
}

# --- corpus: the bench's fleet-home shape, with the relational pages' bodies
# sharing NO words with the query that names them ------------------------------
mkdir -p "$AC_HOME/records/repo-knowledge" "$AC_HOME/data/harbor-sync/spec" \
  "$AC_HOME/data/ledger-guard" "$AC_HOME/data/pane-resize" "$AC_HOME/crewdomains/b2c-shop/records"
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] harbor-sync [EPIC] - synchronize the harbor manifests across fleets (repo: payproc)
- [ ] pane-resize - the watcher pane hangs on resize (repo: shipyard)
## Queued
- [ ] ledger-guard-hardening - tighten the scoped-edit refusal for payproc (repo: payproc)
EOF
printf '# payproc knowledge\n- the payment processor retries with exponential backoff capped at five attempts (by: harbor-sync)\n' >"$AC_HOME/records/repo-knowledge/payproc.md"
printf '# shipyard knowledge\n- the shipyard build pipeline caches bun install artifacts per branch (by: pane-resize)\n' >"$AC_HOME/records/repo-knowledge/shipyard.md"
printf '# Room: harbor-sync\nTRIAGE: flow=staged - gate review required before implement.\nThe manifests converge inside one cycle and the report lists every skipped shard.\n' >"$AC_HOME/data/harbor-sync/room.md"
printf '# Spec report\nAcceptance criteria: the harbor sync manifests converge within one cycle, and the harbor sync report lists every skipped shard for review.\n' >"$AC_HOME/data/harbor-sync/spec/report.md"
printf '# Ledger guard refusal\nA scoped edit on the fleet ledger is turned away and the chief is pointed at handback instead.\n' >"$AC_HOME/data/ledger-guard/room.md"
printf '# Guard report\nThe ledger guard refusal counts for the quarter, grouped by scope and verb: every refusal the ledger guard made lives in this quarterly summary.\n' >"$AC_HOME/data/ledger-guard/report.md"
printf '# Room: pane-resize\nWatcher không nhận exit code khi màn hình đổi kích thước; phải rearm thủ công.\n' >"$AC_HOME/data/pane-resize/room.md"
printf '# Domain b2c-shop\nThe charter covers checkout, catalog and promotions end to end.\n' >"$AC_HOME/crewdomains/b2c-shop/CREWMATE.md"
printf '# Projects\n## payproc\nThe domain view of payproc focuses on the checkout path of payproc only; the b2c shop checkout is where payproc lands.\n' >"$AC_HOME/crewdomains/b2c-shop/records/projects.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null

# --- the controlled cross-encoder ---------------------------------------------
# Scores a document by the share of its SNIPPET's terms that the query carries:
# the part of the wire the fused signals cannot reach. RERANK_LOG records every
# request so a wrong document shape is evidence, not a guess.
cat >"$TMP/rerank-ctl.ts" <<'TS'
import { appendFileSync } from "fs";
const terms = (s: string) => [...s.toLowerCase().matchAll(/[\p{L}\p{N}]+/gu)].map(m => m[0]);
const s = Bun.serve({ port: 0, fetch: async req => {
  const j: any = await req.json();
  const qt = new Set(terms(j.query));
  const data = j.documents.map((d: string, index: number) => {
    const dt = terms(d.split("\n").slice(1).join("\n"));
    return { index, relevance_score: dt.length ? dt.filter(t => qt.has(t)).length / dt.length : 0 };
  });
  appendFileSync(process.env.RERANK_LOG!, JSON.stringify({ query: j.query, n: j.documents.length }) + "\n");
  return Response.json({ data });
} });
console.log(s.port);
await new Promise(() => {});
TS
STUB_PID=""; STUB_PORT=""
portfile="$TMP/rerank.port"; : >"$portfile"
RERANK_LOG="$TMP/rerank.log" bun "$TMP/rerank-ctl.ts" >"$portfile" 2>/dev/null &
STUB_PID=$!
i=0; while [ "$i" -lt 100 ]; do [ -s "$portfile" ] && { STUB_PORT="$(cat "$portfile")"; break; }; sleep 0.1; i=$((i + 1)); done
stub_down() { [ -z "$STUB_PID" ] || { kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; }; STUB_PID=""; }
trap 'stub_down; cleanup' EXIT
[ -n "$STUB_PORT" ] || fail "the controlled rerank stub never came up"
rerank_cfg() {  # rerank_cfg [<extra json fields>] - brain.json pointing at the stub
  printf '{"reranker":{"provider":"voyage","model":"m","base_url":"http://127.0.0.1:%s/v1"%s}}\n' \
    "$STUB_PORT" "${1:-}" >"$AC_HOME/config/brain.json"
}
export VOYAGE_API_KEY=x

# --- the shape: fused order puts the relational page first ---------------------
rm -f "$AC_HOME/config/brain.json"
for c in "harbor sync|data/harbor-sync/room|slug_match" "pane resize|data/pane-resize/room|slug_match" \
         "payproc|records/repo-knowledge/payproc|slug_match" "ledger guard refusal|data/ledger-guard/room|title_phrase"; do
  IFS='|' read -r q gold ev <<<"$c"
  f="$("$BRAIN" recall --query "$q" --home "$AC_HOME" --compact)"
  assert_eq "$(printf '%s' "$f" | rank_of "$gold")" "1" "fused: '$q' leads on its own evidence"
  assert_eq "$(printf '%s' "$f" | j "['results'][0]['evidence']")" "$ev" "...which the stamp names"
done

# --- unpinned, the cross-encoder buries it (the measurement, kept as the guard
# that the pin still has something to lift) ------------------------------------
rerank_cfg ',"pin":0'
u="$("$BRAIN" recall --query "harbor sync" --home "$AC_HOME" --compact)"
assert_contains "$u" '"reranked":true' "pin 0: the stub reranker engages"
[ "$(printf '%s' "$u" | rank_of data/harbor-sync/room)" -gt 1 ] \
  || fail "pin 0: the slug_match page must lose its rank to snippet overlap, or this test guards nothing: $u"

# --- pinned (the default), the relational hits ride above the reranked block --
rerank_cfg
for c in "harbor sync|data/harbor-sync/room" "pane resize|data/pane-resize/room" "payproc|records/repo-knowledge/payproc"; do
  IFS='|' read -r q gold <<<"$c"
  p="$("$BRAIN" recall --query "$q" --home "$AC_HOME" --compact)"
  assert_contains "$p" '"reranked":true' "pinned: '$q' is still reranked"
  assert_eq "$(printf '%s' "$p" | rank_of "$gold")" "1" "pinned: '$q' keeps the lead its evidence earned"
  [ "$(printf '%s' "$p" | j "['rerank_pinned']")" -ge 1 ] || fail "pinned: the response counts what was pinned: $p"
done
# two slug_match pages under one family: the cap holds the second to the rerank
# block, in fused order below the pinned one
c1="$(rerank_cfg ',"pin":1'; "$BRAIN" recall --query "harbor sync" --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$c1" | j "['rerank_pinned']")" "1" "pin 1: exactly one hit is pinned"
assert_eq "$(printf '%s' "$c1" | rank_of data/harbor-sync/room)" "1" "pin 1: ...the first in fused order"
# the reranked block excludes the pinned hits: the stub saw fewer documents
n_last="$(tail -n1 "$TMP/rerank.log" | python3 -c 'import sys, json; print(json.load(sys.stdin)["n"])')"
total="$(printf '%s' "$c1" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)["results"]))')"
assert_eq "$n_last" "$((total - 1))" "the pinned hit is not sent to the reranker"

# --- an ordinary text query pins nothing and reranks as before ----------------
rerank_cfg
o="$("$BRAIN" recall --query "skipped shard report" --home "$AC_HOME" --compact)"
assert_contains "$o" '"reranked":true' "ordinary query: reranked"
assert_eq "$(printf '%s' "$o" | j "['rerank_pinned']")" "0" "ordinary query: nothing carried relational evidence, nothing pinned"
assert_eq "$(printf '%s' "$o" | rank_of data/harbor-sync/spec/report)" "2" "ordinary query: the cross-encoder's order stands (measured 1->2)"

stub_down
rm -f "$AC_HOME/config/brain.json"
pass
