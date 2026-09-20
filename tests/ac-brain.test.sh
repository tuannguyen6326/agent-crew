#!/usr/bin/env bash
# ac-brain.test.sh - the per-home memory engine's contracts: sync idempotence,
# deterministic dedup, the mass-delete valve, fleet link grammar, recall
# shapes + trust labels, the provenance gate, the facts ledger round-trip
# (markdown is the truth; --rebuild replays it), the delta insert-then-deliver
# proof, alias idempotence, budget packing, keyless degradation stamps, the
# stub embedding lane, the pattern floor, synthesize fallback boundaries, the
# MCP stdio surface, and a multi-process write smoke. Everything runs against
# an isolated temp home, never the operator's real fleet home.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
BRAIN="$BIN/ac-brain.sh"
export AC_BRAIN_PATTERN_FILE="$TMP/no-such-pattern-file"

j() { python3 -c "import sys, json; d=json.load(sys.stdin); print(d$1)"; }

# --- fixture home -------------------------------------------------------------
mkdir -p "$AC_HOME/records/repo-knowledge" "$AC_HOME/data/fam-one" "$AC_HOME/data/fam-two/spec" "$AC_HOME/crewdomains/dom-a/records"
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] fam-one - harden the widget locking path (repo: demo)
EOF
cat >"$AC_HOME/records/repo-knowledge/demo.md" <<'EOF'
# demo knowledge
- the widget lock is acquired in bin/ac-lock.sh before any write (by: fam-zero)
EOF
cat >"$AC_HOME/data/fam-one/room.md" <<'EOF'
# Room: fam-one
TRIAGE: flow=direct - widget locking hardening.
The failing path is [[records/backlog]] and the fix touches bin/ac-lock.sh.
See data/fam-two/room.md for the sibling investigation.
EOF
cat >"$AC_HOME/data/fam-two/room.md" <<'EOF'
---
title: Room fam-two
depends_on: fam-one
aliases: widget-probe
---
# Room: fam-two
A distinctive sentence about zanzibar quorum reconciliation lives here.
EOF
printf '# Spec\nThe fam-two spec covers quorum reconciliation acceptance in detail and length.\n' >"$AC_HOME/data/fam-two/spec/report.md"
printf '# Dom\nDomain dom-a owns the widget product line end to end for this fleet.\n' >"$AC_HOME/crewdomains/dom-a/CREWMATE.md"
printf '\n' >"$AC_HOME/data/fam-one/empty.md"
# exact duplicate at two depths: canonical must be the shallower slug
printf '# Dup\nThe duplicated verify snapshot content block sits here unchanged.\n' >"$AC_HOME/data/fam-one/snap.md"
mkdir -p "$AC_HOME/data/fam-one/verify/r1"
printf '# Dup\nThe duplicated verify snapshot content block sits here unchanged.\n' >"$AC_HOME/data/fam-one/verify/r1/snap.md"

# --- sync: counts, empty skip, dedup determinism ------------------------------
s1="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$s1" | j "['deduped']")" "1" "one duplicate demoted"
assert_eq "$(printf '%s' "$s1" | j "['refused_reconcile']")" "False" "no valve on first sync"
pages="$(printf '%s' "$s1" | j "['pages']")"
[ "$pages" -ge 6 ] || fail "expected >=6 pages, got $pages (empty page must be skipped, dup collapsed)"
# canonical is the SHALLOWER slug; the deep copy became an alias
canon="$("$BRAIN" recall --home "$AC_HOME" --query "duplicated verify snapshot" --limit 2 --compact | j "['results'][0]['slug']")"
assert_eq "$canon" "data/fam-one/snap" "canonical = fewest path segments"

# --- resync: mtime short-circuit covers dup files too -------------------------
s2="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$s2" | j "['changed']")" "0" "nothing changed on resync"
assert_eq "$(printf '%s' "$s2" | j "['skipped_hash']")" "0" "dup file rides the mtime index, not a re-read"

# --- alias idempotence --------------------------------------------------------
a1="$(sqlite3 "$AC_HOME/state/brain.sqlite" 'SELECT COUNT(*) FROM aliases')"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
a2="$(sqlite3 "$AC_HOME/state/brain.sqlite" 'SELECT COUNT(*) FROM aliases')"
assert_eq "$a2" "$a1" "aliases do not grow on an unchanged resync"

# --- fleet link grammar -------------------------------------------------------
lt="$("$BRAIN" links-to bin/ac-lock.sh --home "$AC_HOME" --compact)"
n="$(printf '%s' "$lt" | j "['referencing_pages']")"
[ "$n" -ge 2 ] || fail "cites_code reverse lookup finds both citing pages (got $n)"
assert_contains "$lt" "fam-one" "families are grouped on the reverse lookup"
dep="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT to_slug FROM links WHERE from_slug='data/fam-two/room' AND type='depends_on' AND resolved=1")"
assert_eq "$dep" "data/fam-one/room" "frontmatter depends_on resolves by basename"
wl="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT resolved FROM links WHERE from_slug='data/fam-one/room' AND type='wikilink'")"
assert_eq "$wl" "1" "[[records/backlog]] resolves directly"

# --- recall: shapes, trust labels, evidence, keyless stamp --------------------
r="$("$BRAIN" recall --home "$AC_HOME" --query "zanzibar quorum reconciliation" --limit 3 --compact)"
assert_eq "$(printf '%s' "$r" | j "['results'][0]['slug']")" "data/fam-two/room" "content query finds the page"
assert_contains "$r" '"path":"data/fam-two/room.md"' "results carry the home-relative path"
assert_contains "$r" "unverified working material" "non-knowledge results carry the unverified trust label"
assert_contains "$r" "keyword_only_no_provider" "keyless mode stamps search_degraded"
rk="$("$BRAIN" recall --home "$AC_HOME" --query "widget lock acquired" --limit 5 --compact)"
assert_contains "$rk" "L1-verified" "knowledge-typed results carry the L1 trust label"
# an EMPTY query browses the store: newest-first page listing plus the count,
# so a surface with nothing typed yet (the dashboard's Brain page) can show
# what the brain holds instead of an empty result box
br="$("$BRAIN" recall --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$br" | j "['page_count']")" "$(sqlite3 "$AC_HOME/state/brain.sqlite" 'SELECT COUNT(*) FROM pages WHERE deleted_at IS NULL')" \
  "the empty query carries the live page count"
printf '%s' "$br" | python3 -c '
import sys, json; d = json.load(sys.stdin); ps = d["pages"]
assert len(ps) == min(50, d["page_count"]), "listing bounded at 50, else complete"
for p in ps: assert all(k in p for k in ("slug", "title", "path", "mtime", "size")), p
assert [p["mtime"] for p in ps] == sorted((p["mtime"] for p in ps), reverse=True), "newest first"
assert all(p["size"] > 0 for p in ps), "size is the file on disk"
' || fail "the empty-query page listing has the browse shape"
case "$("$BRAIN" recall --home "$AC_HOME" --query "widget" --compact)" in *'"pages":'*) fail "a query never carries the browse listing" ;; esac

# alias lookup reaches the aliased page
ra="$("$BRAIN" entity widget-probe --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$ra" | j "['card']['slug']")" "data/fam-two/room" "frontmatter alias resolves in entity()"

# --- facts: provenance gate, ledger truth, rebuild replay ---------------------
if outp="$("$BRAIN" remember "widget prefers the short path" --agent t1 --home "$AC_HOME" 2>&1)"; then
  fail "remember without provenance must exit 1 (got: $outp)"
fi
assert_contains "$outp" "provenance_required" "the refusal names its error code"
f1="$("$BRAIN" remember "the demo suite must run from the repo root" --provenance "test fixture" --agent t1 --entity data/fam-one/room --kind fact --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$f1" | j "['status']")" "inserted" "first remember inserts"
fid="$(printf '%s' "$f1" | j "['id']")"
f2="$("$BRAIN" remember "the demo suite must run from the repo root" --provenance "test fixture" --agent t2 --entity data/fam-one/room --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$f2" | j "['status']")" "duplicate" "exact re-remember is a duplicate"
assert_file "$AC_HOME/state/facts.md" "the ledger file exists"
assert_contains "$(cat "$AC_HOME/state/facts.md")" "the demo suite must run from the repo root" "the ledger holds the fact verbatim"
# rebuild drops the DB's derived tables AND replays facts from the ledger
"$BRAIN" sync --rebuild --home "$AC_HOME" --compact >/dev/null
fr="$("$BRAIN" recall --entity data/fam-one/room --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$fr" | j "['total']")" "1" "facts survive --rebuild via ledger replay"
# forget: audited, idempotent
fx="$("$BRAIN" forget "$fid" --reason done --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$fx" | j "['expired']")" "True" "forget expires"
fx2="$("$BRAIN" forget "$fid" --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$fx2" | j "['expired']")" "False" "re-forget is idempotent"
assert_contains "$(cat "$AC_HOME/state/facts.md")" "- x$fid" "the expiry landed in the ledger"

# --- ttl: a lapsed fact is hidden at READ time, not only after a sync sweep ---
# The sweep runs only inside sync; between syncs a lapsed fact was still
# recalled, packed, delivered - and stood as the dedup candidate that
# swallowed a correct re-remember. No sync runs in this block.
lt="$("$BRAIN" remember "the lapsed probe fact" --provenance "test" --agent t1 --entity data/fam-one/room --ttl 2020-01-01T00:00:00Z --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$lt" | j "['status']")" "inserted" "a past ttl is accepted (an asof record)"
lid="$(printf '%s' "$lt" | j "['id']")"
for probe in "recall --entity data/fam-one/room" "recall" "context_pack --entities data/fam-one/room" "entity fam-one" \
  "delta --agent ttlprobe --session t --since 2000-01-01T00:00:00Z"; do
  case "$("$BRAIN" $probe --home "$AC_HOME" --compact)" in
    *"lapsed probe"*) fail "$probe surfaced a lapsed fact before the sweep" ;;
  esac
done
assert_eq "$("$BRAIN" stats --home "$AC_HOME" --compact | j "['facts_active']")" "0" "stats counts only facts still valid"
lt2="$("$BRAIN" remember "the lapsed probe fact" --provenance "test" --agent t1 --entity data/fam-one/room --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$lt2" | j "['status']")" "inserted" "the same subject re-remembered inserts fresh - a lapsed fact is no dedup candidate"
[ "$(printf '%s' "$lt2" | j "['id']")" != "$lid" ] || fail "the fresh fact must be a new row"
dl="$("$BRAIN" doctor --home "$AC_HOME" --compact)" || fail "doctor stays healthy with a lapsed fact awaiting sweep: $dl"
assert_contains "$dl" '"name":"validity_lapsed_facts","status":"ok","message":"1 lapsed' "doctor counts the lapsed fact the sweep has not reached"
"$BRAIN" forget "$(printf '%s' "$lt2" | j "['id']")" --reason probe --home "$AC_HOME" --compact >/dev/null

# --- delta: the insert-then-deliver proof (one timestamp format) --------------
d0="$("$BRAIN" delta --agent chief --session t --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$d0" | j "['first_wake']")" "True" "first wake stamps and returns empty"
"$BRAIN" remember "a fact recorded after the cursor" --provenance "test" --agent t1 --home "$AC_HOME" --compact >/dev/null
printf '\nA post-cursor line.\n' >>"$AC_HOME/records/backlog.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
d1="$("$BRAIN" delta --agent chief --session t --home "$AC_HOME" --compact)"
assert_contains "$d1" "a fact recorded after the cursor" "an inserted fact IS delivered on the next wake"
assert_contains "$d1" "records/backlog" "a changed page IS delivered on the next wake"
d2="$("$BRAIN" delta --agent chief --session t --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$d2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['pages']), len(d['facts']))")" "0 0" "delivered pages/facts do not repeat (deliver-before-advance)"

# --- budget packing -----------------------------------------------------------
rb="$("$BRAIN" recall --home "$AC_HOME" --query "widget" --limit 10 --budget-tokens 20 --compact)"
[ "$(printf '%s' "$rb" | j "['dropped_count']")" -ge 1 ] || fail "a tiny budget drops results and says so"

# --- mass-delete valve --------------------------------------------------------
mkdir -p "$AC_HOME/data/bulk"
for i in $(seq 1 25); do printf '# Bulk %s\nFiller page number %s with enough body to index for the valve test.\n' "$i" "$i" >"$AC_HOME/data/bulk/p$i.md"; done
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null

# --- reranker knob (stub) + autocut plumbing (needs >=3 hits: the bulk pages) --
mkdir -p "$AC_HOME/config"
printf '{"reranker":{"provider":"stub"}}\n' >"$AC_HOME/config/brain.json"
rr="$("$BRAIN" recall --home "$AC_HOME" --query "bulk filler page" --limit 10 --compact)"
assert_contains "$rr" '"reranked":true' "the stub reranker engages and stamps the response"
rm -f "$AC_HOME/config/brain.json"
rm -rf "$AC_HOME/data/bulk" "$AC_HOME/data/fam-one" "$AC_HOME/data/fam-two"
sv="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$sv" | j "['refused_reconcile']")" "True" "dropping >50% of pages refuses without --force-reconcile"
sf="$("$BRAIN" sync --force-reconcile --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$sf" | j "['refused_reconcile']")" "False" "--force-reconcile is the captain's override"
[ "$(printf '%s' "$sf" | j "['deleted']")" -ge 20 ] || fail "forced reconcile deletes the gone pages"

# --- pattern floor: flags, never drops ----------------------------------------
printf 'zzsecretmarker\n' >"$TMP/pat"
export AC_BRAIN_PATTERN_FILE="$TMP/pat"
mkdir -p "$AC_HOME/data/fam-three"
printf '# Leaky\nThis page contains zzsecretmarker inside an operational note.\n' >"$AC_HOME/data/fam-three/room.md"
sp="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$sp" | j "['flagged']")" "1" "a pattern hit is flagged"
fl="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT flags FROM pages WHERE slug='data/fam-three/room'")"
assert_eq "$fl" "pattern-hit" "the page is stamped, not dropped"
export AC_BRAIN_PATTERN_FILE="$TMP/no-such-pattern-file"

# --- stub embedding lane: vector arm + dims guard -----------------------------
mkdir -p "$AC_HOME/config"
printf '{"embedding":{"provider":"stub","model":"stub","dims":8}}\n' >"$AC_HOME/config/brain.json"
se="$("$BRAIN" sync --home "$AC_HOME" --compact)"
[ "$(printf '%s' "$se" | j "['embedded']")" -ge 1 ] || fail "stub provider embeds pending chunks"
rv="$("$BRAIN" recall --home "$AC_HOME" --query "domain widget product line" --limit 3 --compact)"
case "$rv" in *search_degraded*) fail "embedded index must not stamp search_degraded: $rv" ;; esac
printf '{"embedding":{"provider":"stub","model":"stub","dims":16}}\n' >"$AC_HOME/config/brain.json"
if sd="$("$BRAIN" sync --home "$AC_HOME" --compact 2>&1)"; then
  printf '%s' "$sd" | grep -q '"error"' || fail "a dims change must hard-error naming the fix (got: $sd)"
fi
assert_contains "$sd" "rebuild" "the dims error names the remedy"
rm -f "$AC_HOME/config/brain.json"

# --- sync soft-delete: gone pages hide, revive in the window, purge past it ---
mkdir -p "$AC_HOME/data/soft"
printf '# Ephemeral\nA page about the ephemeral lifecycle probe body.\n' >"$AC_HOME/data/soft/page.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
assert_contains "$("$BRAIN" recall --home "$AC_HOME" --query "ephemeral lifecycle probe" --limit 3 --compact)" \
  "data/soft/page" "the page is live before deletion"
rm "$AC_HOME/data/soft/page.md"
sd1="$("$BRAIN" sync --home "$AC_HOME" --compact)"
[ "$(printf '%s' "$sd1" | j "['deleted']")" -ge 1 ] || fail "the gone page counts as deleted"
case "$("$BRAIN" recall --home "$AC_HOME" --query "ephemeral lifecycle probe" --limit 5 --compact)" in
  *"data/soft/page"*) fail "a soft-deleted page must not surface in recall" ;;
esac
assert_eq "$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT COUNT(*) FROM pages WHERE slug='data/soft/page' AND deleted_at IS NOT NULL")" "1" \
  "the page row survives soft-deleted - the revive window"
printf '# Ephemeral\nA page about the ephemeral lifecycle probe body.\n' >"$AC_HOME/data/soft/page.md"
rv1="$("$BRAIN" sync --home "$AC_HOME" --compact)"
[ "$(printf '%s' "$rv1" | j "['revived']")" -ge 1 ] || fail "a returned file revives its page"
assert_contains "$("$BRAIN" recall --home "$AC_HOME" --query "ephemeral lifecycle probe" --limit 3 --compact)" \
  "data/soft/page" "the revived page surfaces again"
rm "$AC_HOME/data/soft/page.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
sqlite3 "$AC_HOME/state/brain.sqlite" "UPDATE pages SET deleted_at = deleted_at - 80*3600*1000 WHERE slug='data/soft/page'"
pg1="$("$BRAIN" sync --home "$AC_HOME" --compact)"
[ "$(printf '%s' "$pg1" | j "['purged']")" -ge 1 ] || fail "a page deleted past the window purges"
assert_eq "$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT COUNT(*) FROM pages WHERE slug='data/soft/page'")" "0" \
  "the purged page row is gone for good"
rm -rf "$AC_HOME/data/soft"

# --- vector evidence floor: a weak cosine never wears the vector label --------
# A fresh one-page home makes the case deterministic: the query shares no
# token with the page, so the keyword arm is empty and the single vector
# candidate carries a LOW stub cosine - labeling it "vector" is the
# blended-score dishonesty the floor closes.
VH="$TMP/vec-home"
mkdir -p "$VH/data/vec" "$VH/config" "$VH/state"
printf '{"embedding":{"provider":"stub","model":"stub","dims":8}}\n' >"$VH/config/brain.json"
printf '# Alpha Bravo\nalpha bravo tokens only in this page body.\n' >"$VH/data/vec/page.md"
"$BRAIN" sync --home "$VH" --compact >/dev/null
wk="$("$BRAIN" recall --home "$VH" --query "charlie delta echo foxtrot" --limit 5 --compact)"
case "$wk" in
  *'"evidence": "vector"'*|*'"evidence":"vector"'*) fail "a weak-cosine vector-only hit must not wear the vector label: $wk" ;;
esac
case "$wk" in
  *vector_weak*) ;;
  *) fail "the weak vector hit must still surface, honestly labeled vector_weak: $wk" ;;
esac

# --- synthesize boundaries ----------------------------------------------------
export AC_BRAIN_SYNTH_CMD="echo synthetic-answer #"
sy="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$sy" | j "['synthesis_status']")" "ok" "a working command yields ok"
assert_contains "$sy" "synthetic-answer" "the answer is the command's output"
export AC_BRAIN_SYNTH_CMD="false #"
sy2="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact)"
assert_contains "$(printf '%s' "$sy2" | j "['synthesis_status']")" "extractive_fallback" "compose failure with a non-empty gather falls back to extraction"
if sy3="$("$BRAIN" synthesize "zzz-token-that-matches-nothing-anywhere" --home "$AC_HOME" --compact 2>&1)"; then
  fail "an empty gather must be the typed unavailable error (got: $sy3)"
fi
assert_contains "$sy3" "unavailable" "empty gather never fabricates"
unset AC_BRAIN_SYNTH_CMD

# --- MCP stdio surface --------------------------------------------------------
mcp="$(printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recall","arguments":{"query":"widget product line"}}}' \
  | "$BRAIN" serve --home "$AC_HOME")"
assert_contains "$mcp" '"name":"ac-brain"' "serve answers initialize"
assert_contains "$mcp" '"context_pack"' "the seven verbs are listed"
assert_contains "$mcp" "crewdomains/dom-a/CREWMATE" "tools/call recall returns real results"

# --- context_pack -------------------------------------------------------------
cp1="$("$BRAIN" context_pack --entities data/fam-three/room --budget-tokens 500 --home "$AC_HOME" --compact)"
assert_contains "$cp1" '"cards"' "context_pack returns cards"

# --- multi-process write smoke ------------------------------------------------
ok=0
for i in 1 2 3 4 5 6; do
  "$BRAIN" remember "smoke fact $i $$" --provenance smoke --agent "w$((i % 2))" --home "$AC_HOME" --compact >/dev/null &
done
wait
active="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT COUNT(*) FROM facts WHERE provenance='smoke'")"
assert_eq "$active" "6" "six concurrent remembers all land"
assert_eq "$(sqlite3 "$AC_HOME/state/brain.sqlite" 'PRAGMA integrity_check')" "ok" "integrity after concurrent writes"
ledger_smoke="$(grep -c 'smoke fact' "$AC_HOME/state/facts.md")"
assert_eq "$ledger_smoke" "6" "the ledger serialized all six appends"

# --- doctor -------------------------------------------------------------------
docout="$("$BRAIN" doctor --home "$AC_HOME" --compact)" || fail "doctor exits 0 on a healthy brain: $docout"
# self-retrieval probe (warn-only): sampled pages must find themselves via
# their own opening words - integrity_check cannot see broken retrieval.
assert_contains "$docout" '"name":"self_retrieval","status":"ok"' "doctor runs the self-retrieval probe: all-found is ok"
assert_contains "$docout" "find themselves" "and reports the found ratio"
# published scale ceiling: the cosine scan is linear - doctor states the
# embedded-chunk census against the supported budget instead of hiding a cliff
assert_contains "$docout" "vector_scan_scale" "doctor reports the linear-scan census"
assert_contains "$docout" "50000" "and names the supported ceiling"

# --- Unicode retrieval: Vietnamese survives the query tokenizer ---------------
# The index side always tokenized correctly (fts5 unicode61); the query-side
# term extractor was ASCII-only and shredded accented words before FTS ever
# saw them. Accented is the primary signal; the accent-less variant matches
# because unicode61 folds diacritics on BOTH sides at match time.
mkdir -p "$AC_HOME/data/fam-viet"
cat >"$AC_HOME/data/fam-viet/room.md" <<'EOF'
# Room: fam-viet
Điều phối bến cảng: phối hợp nghiệm thu giữa hai bến trước khi tàu rời cảng.
EOF
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
# Every content word is accented: the old ASCII extractor shredded this query
# to fragments ("ph", "ng") that match no FTS token, so BOTH arms went empty.
vn1="$("$BRAIN" recall --query "phối hợp nghiệm bến cảng" --home "$AC_HOME" --compact)"
assert_contains "$vn1" "fam-viet" "accented Vietnamese query reaches the page"
vn2="$("$BRAIN" recall --query "phoi hop nghiem ben cang" --home "$AC_HOME" --compact)"
assert_contains "$vn2" "fam-viet" "accent-less variant reaches the same page"

# --- sync lease: atomic claim -------------------------------------------------
# A live same-host holder refuses a second sync; a dead holder is reclaimed;
# and two syncs racing the claim serialize (the old read-check-write let both
# pass the check and interleave FTS delete+insert).
lease_set() { sqlite3 "$AC_HOME/state/brain.sqlite" \
  "INSERT OR REPLACE INTO meta(k,v) VALUES('sync_lease','{\"host\":\"$(hostname)\",\"pid\":$1,\"at\":\"2026-08-18T00:00:00Z\"}')"; }
lease_set $$
out="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_contains "$out" "already-running" "a live holder refuses a second sync"
sleep 0.01 & dead_pid=$!; wait "$dead_pid" 2>/dev/null
lease_set "$dead_pid"
out="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_contains "$out" '"pages"' "a dead holder is reclaimed and sync proceeds"
# foreign-host lease: NEVER overwritten while fresh (pids are unverifiable
# across hosts); an hour-old foreign lease is a dead host and is reclaimed.
lease_set_host() { sqlite3 "$AC_HOME/state/brain.sqlite" \
  "INSERT OR REPLACE INTO meta(k,v) VALUES('sync_lease','{\"host\":\"$1\",\"pid\":1,\"at\":\"$2\",\"token\":\"zz\"}')"; }
lease_set_host other-host "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_contains "$out" "already-running" "a fresh foreign-host lease refuses the claim"
assert_contains "$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT v FROM meta WHERE k='sync_lease'")" \
  "other-host" "and the foreign lease was NOT overwritten"
lease_set_host other-host "2026-08-17T00:00:00Z"
out="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_contains "$out" '"pages"' "a stale foreign-host lease is reclaimed"
printf '# Room: fam-viet\nMột dòng mới để sync có việc thật sự phải làm.\n' >"$AC_HOME/data/fam-viet/room.md"
"$BRAIN" sync --home "$AC_HOME" --compact >"$TMP/race1.json" &
"$BRAIN" sync --home "$AC_HOME" --compact >"$TMP/race2.json" &
wait
assert_eq "$(sqlite3 "$AC_HOME/state/brain.sqlite" 'PRAGMA integrity_check')" "ok" "integrity after racing syncs"
fts_n="$(sqlite3 "$AC_HOME/state/brain.sqlite" 'SELECT COUNT(*) FROM chunks_fts')"
# 1:1 against LIVE chunks: a soft-deleted page keeps its chunks (the revive
# window) while its FTS rows are hidden - that asymmetry is the design, so
# the invariant binds the searchable surface, not the raw table.
ch_n="$(sqlite3 "$AC_HOME/state/brain.sqlite" 'SELECT COUNT(*) FROM chunks WHERE slug IN (SELECT slug FROM pages WHERE deleted_at IS NULL)')"
assert_eq "$fts_n" "$ch_n" "FTS stays 1:1 with live chunks after racing syncs"

# --- protocol honesty: errors carry the dialect version too -------------------
# Every success shape stamps protocol_version: 1 (ac-brain's OWN dialect - the
# verb names are shared vocabulary, the shapes are not wire-conformant to any
# external protocol); an error is a response like any other and stamps it too.
perr="$("$BRAIN" remember "an unprovenance fact" --home "$AC_HOME" --compact || true)"
assert_contains "$perr" '"protocol_version":1' "error responses carry the dialect version"
assert_contains "$perr" '"error"' "and are still errors"

# --- ambiguous basename links: refuse to guess --------------------------------
# Two pages named report.md exist (fam-two/spec/report.md is in the fixture);
# a bare [[report]] link must stay UNRESOLVED - a silently-wrong edge poisons
# backlink boosts and links-to worse than a missing one - and doctor lists it.
mkdir -p "$AC_HOME/data/fam-one"
printf '# R1\nThe fam-one weekly report body differs from every sibling page.\n' >"$AC_HOME/data/fam-one/report.md"
printf '# R2\nThe fam-viet weekly report body is its own distinct thing too.\n' >"$AC_HOME/data/fam-viet/report.md"
printf '# Amb\nSee [[report]] for the weekly numbers rollup.\n' >"$AC_HOME/data/fam-viet/amb.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
amb_n="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT COUNT(*) FROM links WHERE from_slug='data/fam-viet/amb' AND to_slug='report' AND resolved=0")"
assert_eq "$amb_n" "1" "an ambiguous basename link stays unresolved"
docamb="$("$BRAIN" doctor --home "$AC_HOME" --compact)" || fail "doctor stays healthy with ambiguous links: $docamb"
assert_contains "$docamb" "ambiguous_links" "doctor carries the ambiguous-links census"
assert_contains "$docamb" "report" "and names the ambiguous target"

# --- context_pack: entity-scoped facts, not the latest-30 home-wide -----------
# Tier 1: facts on the requested entity. Tier 2: facts one resolved link hop
# away. Tier 3: entity-less commitments (the one labeled global tail).
# Anything else stays OUT - that was the pollution.
"$BRAIN" remember "the fam-viet berth checklist is frozen" --provenance t --agent tester --entity data/fam-viet/room --home "$AC_HOME" --compact >/dev/null
"$BRAIN" remember "the dom-a zebra cadence is quarterly" --provenance t --agent tester --entity crewdomains/dom-a/CREWMATE --home "$AC_HOME" --compact >/dev/null
"$BRAIN" remember "always run the push gate before any release" --provenance t --agent tester --kind commitment --home "$AC_HOME" --compact >/dev/null
cp2="$("$BRAIN" context_pack --entities data/fam-viet/room --home "$AC_HOME" --compact)"
assert_contains "$cp2" "berth checklist" "the requested entity's facts ride the pack"
case "$cp2" in *zebra*) fail "an unrelated entity's fact leaked into the pack" ;; esac
assert_contains "$cp2" "push gate" "entity-less commitments are the labeled global tail"
assert_contains "$cp2" '"tier"' "facts carry their tier"
assert_contains "$cp2" '"provenance"' "packed facts keep provenance"
assert_contains "$cp2" 'checklist is frozen (t)' "the text render carries provenance too"
case "$cp2" in *'"open_threads"'*) fail "cards must not duplicate their facts inside the pack" ;; esac
# one-hop: fam-one mentions fam-two in its room, so fam-two facts are tier 2
mkdir -p "$AC_HOME/data/fam-one" "$AC_HOME/data/fam-two"
printf '# Room: fam-one\nThe locking work continues; see data/fam-two/room.md for the sibling.\n' >"$AC_HOME/data/fam-one/room.md"
printf '# Room: fam-two\nThe quorum reconciliation investigation record lives here now.\n' >"$AC_HOME/data/fam-two/room.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
"$BRAIN" remember "the fam-two quorum window is thirty seconds" --provenance t --agent tester --entity data/fam-two/room --home "$AC_HOME" --compact >/dev/null
cp3="$("$BRAIN" context_pack --entities fam-one --home "$AC_HOME" --compact)"
assert_contains "$cp3" "quorum window" "a one-hop neighbor's facts ride as tier 2"

# --- usage-log attribution: the by field --------------------------------------
# Every usage line carries who asked: --by wins, else AC_SCOPE names a scoped
# chief (<fam>-chief), else the unscoped default crewchief. The log is the only
# place usage forensics can read attribution from, so the field is a contract.
env -u AC_SCOPE "$BRAIN" recall --query "widget" --home "$AC_HOME" --compact >/dev/null
assert_contains "$(tail -1 "$AC_HOME/state/brain-usage.jsonl")" '"by":"crewchief"' "unscoped usage attributes to crewchief"
AC_SCOPE=fam-one "$BRAIN" recall --query "widget" --home "$AC_HOME" --compact >/dev/null
assert_contains "$(tail -1 "$AC_HOME/state/brain-usage.jsonl")" '"by":"fam-one-chief"' "AC_SCOPE attributes to the scoped chief"
"$BRAIN" recall --query "widget" --by dashboard --home "$AC_HOME" --compact >/dev/null
assert_contains "$(tail -1 "$AC_HOME/state/brain-usage.jsonl")" '"by":"dashboard"' "--by overrides the derived attribution"

# --- self-retrieval probe: a page that cannot find itself turns the check warn
# (never fail - quirky corpora must not unhealth a home). This page's opening
# words are all stopwords, so its self-query extracts zero terms and misses.
python3 - "$AC_HOME" <<'EOF'
import sys
words = "and are as at be by for from has have in is it its of on or that the this to was were will with you your not yes we our".split()
open(sys.argv[1] + "/data/fam-viet/stopword-page.md", "w").write("# S\n" + " ".join(words * 12) + "\n")
EOF
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
docwarn="$("$BRAIN" doctor --home "$AC_HOME" --compact)" || fail "a self-retrieval miss must not unhealth the home: $docwarn"
assert_contains "$docwarn" '"name":"self_retrieval","status":"warn"' "a missed page turns the probe warn"
assert_contains "$docwarn" "missed:" "and the miss is named"

# --- the embedding call is BOUNDED, and names what went wrong -----------------
# LIVED 2026-09-16: a sync sat 40 minutes in state S at 0.0% CPU, asleep on an
# open TCP socket, while every other sync that session returned in 121-340ms -
# a hang on the remote call, not slowness. And every sync printed the single
# opaque token embed_degraded: "provider_error", so an operator could not tell
# a dead provider from a rejected key from a billing wall. The real cause,
# found only by probing the endpoint by hand, was HTTP 402: out of credits.
#
# Both halves are exercised against a local stub the config points at through
# base_url. `ollama` is the registry's keyless provider, so the lane opens with
# no key material anywhere in the test.
EMBED_STUB_PID=""; EMBED_STUB_PORT=""
embed_stub_up() {  # embed_stub_up <script> <portfile> - run it; sets the two globals
  # NOT through a command substitution: that runs in a subshell, so the pid it
  # backgrounds would never reach the reaper here.
  local i=0
  bun "$1" >"$2" 2>/dev/null &
  EMBED_STUB_PID=$!
  EMBED_STUB_PORT=""
  while [ "$i" -lt 100 ]; do
    [ -s "$2" ] && { EMBED_STUB_PORT="$(cat "$2")"; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
embed_stub_down() { [ -z "$EMBED_STUB_PID" ] || { kill "$EMBED_STUB_PID" 2>/dev/null || true; wait "$EMBED_STUB_PID" 2>/dev/null || true; }; }
embed_stub_config() {  # embed_stub_config <port>
  printf '{"embedding":{"provider":"ollama","model":"m","dims":8,"base_url":"http://127.0.0.1:%s/v1"}}\n' \
    "$1" >"$AC_HOME/config/brain.json"
}
mkdir -p "$AC_HOME/config"

# (a) a provider that ANSWERS an error: the status reaches the operator.
cat >"$TMP/embed-402.ts" <<'TS'
const s = Bun.serve({ port: 0, fetch: () => new Response(
  '{"error":{"message":"Insufficient credits. Add more using https://example.test/credits","code":402}}',
  { status: 402 }) });
console.log(s.port);
await new Promise(() => {});
TS
embed_stub_up "$TMP/embed-402.ts" "$TMP/embed-402.port" \
  || { embed_stub_down; fail "the 402 stub never came up"; }
embed_stub_config "$EMBED_STUB_PORT"
printf '# Bound probe\nA page that needs embedding for the bounded-call probe.\n' \
  >"$AC_HOME/data/fam-one/bound-probe.md"
eb="$("$BRAIN" sync --home "$AC_HOME" --compact)"
embed_stub_down
assert_contains "$eb" "402" \
  "a refused embedding names the HTTP status, not a single opaque provider_error"

# (b) a provider that ACCEPTS AND NEVER ANSWERS: the sync must still return.
# The bound is the whole point - a wedged sync holds its lease and its DB open
# for as long as the socket stays up, and nothing above it has a ceiling.
cat >"$TMP/embed-hang.ts" <<'TS'
const s = Bun.serve({ port: 0, fetch: async () => { await new Promise(() => {}); return new Response(""); } });
console.log(s.port);
await new Promise(() => {});
TS
embed_stub_up "$TMP/embed-hang.ts" "$TMP/embed-hang.port" \
  || { embed_stub_down; fail "the hanging stub never came up"; }
embed_stub_config "$EMBED_STUB_PORT"
began=$SECONDS
eh="$(AC_BRAIN_EMBED_TIMEOUT=2 "$BRAIN" sync --home "$AC_HOME" --compact)"
elapsed=$((SECONDS - began))
embed_stub_down
[ "$elapsed" -lt 30 ] || fail "a provider that never answers must not wedge the sync (took ${elapsed}s)"
assert_contains "$eh" "timeout" "...and the degraded token says the call timed out, not merely that it failed"

rm -f "$AC_HOME/config/brain.json" "$AC_HOME/data/fam-one/bound-probe.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null

# --- the rerank call is bounded too, and tighter: it sits on the RECALL path,
# which the prompt-submit hook runs on every prompt a human types. A provider
# that answers late must hand back the fused order at the ceiling, not a
# wedged prompt. The stub answers after 20s (not never - an unbounded engine
# would hang this file for ever instead of failing it), pointed at through
# reranker.base_url; three pages sharing one term give rerank its >=3 hits.
cat >"$TMP/rerank-slow.ts" <<'TS'
const s = Bun.serve({ port: 0, fetch: async () => { await new Promise(r => setTimeout(r, 20000)); return new Response('{"data":[]}'); } });
console.log(s.port);
await new Promise(() => {});
TS
mkdir -p "$AC_HOME/data/rr"
for n in 1 2 3; do printf '# rr %s\nA page about the quokka reranking probe number %s.\n' "$n" "$n" >"$AC_HOME/data/rr/p$n.md"; done
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
embed_stub_up "$TMP/rerank-slow.ts" "$TMP/rerank-slow.port" \
  || { embed_stub_down; fail "the slow rerank stub never came up"; }
printf '{"reranker":{"provider":"voyage","model":"m","base_url":"http://127.0.0.1:%s/v1"}}\n' \
  "$EMBED_STUB_PORT" >"$AC_HOME/config/brain.json"
began=$SECONDS
rr="$(AC_BRAIN_RERANK_TIMEOUT=2 VOYAGE_API_KEY=x "$BRAIN" recall --home "$AC_HOME" --query "quokka reranking probe" --limit 5 --compact)"
elapsed=$((SECONDS - began))
embed_stub_down
[ "$elapsed" -lt 15 ] || fail "a reranker that answers late must be cut at the ceiling, not waited for (took ${elapsed}s)"
case "$rr" in *'"reranked":true'*) fail "a cut rerank must not stamp reranked" ;; esac
assert_contains "$rr" "quokka" "...and the fused order still comes back"
rm -f "$AC_HOME/config/brain.json"; rm -rf "$AC_HOME/data/rr"

pass
