#!/usr/bin/env bash
# ac-brain.test.sh - the per-home memory engine's contracts: sync idempotence,
# deterministic dedup, the mass-delete valve, fleet link grammar, recall
# shapes + trust labels, the provenance gate, the facts ledger round-trip
# (markdown is the truth; --rebuild replays it), the delta insert-then-deliver
# proof, alias idempotence, budget packing, keyless degradation stamps, the
# stub embedding lane, the pattern floor, synthesize fallback boundaries, the
# MCP stdio surface, and a multi-process write smoke. Everything runs against
# an isolated temp home, never the operator's real fleet home.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
mkdir -p "$AC_HOME/data/fam-one/r1"
printf '# Dup\nThe duplicated verify snapshot content block sits here unchanged.\n' >"$AC_HOME/data/fam-one/r1/snap.md"
# a review round's copy of the room is regenerated bulk, never memory
mkdir -p "$AC_HOME/data/fam-one/verify/codereview/r1"
printf '# Room snapshot\nA verbatim room copy the verifier reads, about obsidian lantern rulings.\n' >"$AC_HOME/data/fam-one/verify/codereview/r1/room-snapshot.md"

# --- sync: counts, empty skip, dedup determinism ------------------------------
s1="$("$BRAIN" sync --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$s1" | j "['deduped']")" "1" "one duplicate demoted"
assert_eq "$(printf '%s' "$s1" | j "['refused_reconcile']")" "False" "no valve on first sync"
pages="$(printf '%s' "$s1" | j "['pages']")"
[ "$pages" -ge 6 ] || fail "expected >=6 pages, got $pages (empty page must be skipped, dup collapsed)"
# canonical is the SHALLOWER slug; the deep copy became an alias
canon="$("$BRAIN" recall --home "$AC_HOME" --query "duplicated verify snapshot" --limit 2 --compact | j "['results'][0]['slug']")"
assert_eq "$canon" "data/fam-one/snap" "canonical = fewest path segments"
assert_eq "$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT (SELECT COUNT(*) FROM pages WHERE path LIKE '%/verify/%') + (SELECT COUNT(*) FROM shadows WHERE path LIKE '%/verify/%')")" "0" "a verify round dir is never walked"

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

# --- delta delivers in INDEX order, never by a file's mtime or a fact's stamp --
# A file the walk reaches after a later-written one, or one moved in with an
# old mtime, sat behind an mtime cursor forever; so did a fact whose writer
# stamped its time before waiting on the lock (simulated by an old created_at).
"$BRAIN" delta --agent order --session t --home "$AC_HOME" --compact >/dev/null
"$BRAIN" delta --agent order --session t --home "$AC_HOME" --compact >/dev/null
mkdir -p "$AC_HOME/data/fam-old"
printf '# Old mtime\nA page moved in with an old mtime.\n' >"$AC_HOME/data/fam-old/room.md"
touch -t 202001010000 "$AC_HOME/data/fam-old/room.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
sqlite3 "$AC_HOME/state/brain.sqlite" "INSERT INTO facts(id,fact,kind,provenance,agent,created_at) VALUES((SELECT MAX(id)+1 FROM facts),'a fact stamped before its lock wait','fact','t','t1','2020-01-01T00:00:00.000Z')"
do1="$("$BRAIN" delta --agent order --session t --home "$AC_HOME" --compact)"
sqlite3 "$AC_HOME/state/brain.sqlite" "DELETE FROM facts WHERE fact='a fact stamped before its lock wait'"
assert_contains "$do1" "data/fam-old/room" "a page indexed after the cursor is delivered whatever its mtime"
assert_contains "$do1" "stamped before its lock wait" "a fact committed after the cursor is delivered whatever its stamp"
rm -rf "$AC_HOME/data/fam-old"

# A brain written before the index sequence existed: each cursor resumes at
# the position its old (time, slug) keyset named - nothing re-delivered,
# nothing skipped. The engine's own columns are stripped to rebuild that shape.
MH="$TMP/migrate-home"
mkdir -p "$MH/data/mig" "$MH/state"
for p in a b c; do printf '# Page %s\nmigration page %s, long enough to be indexed.\n' "$p" "$p" >"$MH/data/mig/$p.md"; done
touch -t 202101010000 "$MH/data/mig/a.md"; touch -t 202101020000 "$MH/data/mig/b.md"; touch -t 202101030000 "$MH/data/mig/c.md"
"$BRAIN" sync --home "$MH" --compact >/dev/null
bstamp="$(sqlite3 "$MH/state/brain.sqlite" "SELECT updated_at FROM pages WHERE slug='data/mig/b'")"
sqlite3 "$MH/state/brain.sqlite" "DROP INDEX IF EXISTS idx_pages_seq; ALTER TABLE pages DROP COLUMN seq; ALTER TABLE cursors DROP COLUMN page_seq; ALTER TABLE cursors DROP COLUMN fact_seq;
  INSERT INTO cursors(agent,session,since_utc,since_slug,fact_since,fact_id,updated_at) VALUES('mig','t','$bstamp','data/mig/b','$bstamp',0,'$bstamp')"
dm="$("$BRAIN" delta --agent mig --session t --home "$MH" --compact)"
assert_eq "$(printf '%s' "$dm" | python3 -c "import sys,json; print(' '.join(p['slug'] for p in json.load(sys.stdin)['pages']))")" "data/mig/c" \
  "a pre-sequence cursor resumes exactly after the page its keyset named"

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
  grep -q '"error"' <<<"$sd" || fail "a dims change must hard-error naming the fix (got: $sd)"
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
# The prompt carries the question and gathered record text verbatim, so the
# shell must never evaluate it: it once rode inside the command string as a
# JSON-quoted (bash double-quoted) word, which ran $(...) and backticks from
# any record and handed the engine literal \n for every newline.
export AC_BRAIN_SYNTH_CMD="printf '%s'"
sy4="$("$BRAIN" synthesize "widget product line \$(touch $TMP/brain-pwned) \`touch $TMP/brain-pwned2\` \$HOME" --home "$AC_HOME" --compact)"
[ ! -e "$TMP/brain-pwned" ] && [ ! -e "$TMP/brain-pwned2" ] || fail "synthesize must never run shell syntax from its prompt"
sy4a="$(printf '%s' "$sy4" | j "['answer']")"
assert_contains "$sy4a" "widget product line \$(touch $TMP/brain-pwned) \`touch $TMP/brain-pwned2\` \$HOME" \
  "the engine receives the question verbatim"
assert_contains "$sy4a" "
QUESTION: " "the engine receives real newlines, not literal \\n"
unset AC_BRAIN_SYNTH_CMD
# A configured engine the brain cannot run is REFUSED out loud, the way the
# one-shot arm refuses it, never a silent extractive fallback: agy has no brain
# one-shot form. (An effort outside the arm's tiers is pinned by the parity
# rows below, which exec nothing - a synthesize leg would run the real CLI the
# moment that refusal regressed.)
printf 'agy\n' >"$AC_HOME/config/brain-agent"
sy5="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>"$TMP/sy5.err")"
assert_contains "$(printf '%s' "$sy5" | j "['synthesis_status']")" "harness_refused" "a harness with no brain form is a named refusal"
assert_contains "$(cat "$TMP/sy5.err")" "agy" "the refusal names the harness"
rm -f "$AC_HOME/config/brain-agent"

# --- synthesize's one-shot table IS the pane agent's ----------------------------
# src/brain.ts keeps its own one-shot table and it
# had drifted from the pane agent's (src/pane-agent.ts ONESHOT), so every registry
# harness must print the same bytes from both, with and without a model and an
# effort - the effort after the one-shot arm's own mapping, which is what its
# engines receive. brain.ts runs its CLI on import, so synthCommand is lifted
# out and fed the brain-agent/-model/-effort knobs directly; the arm's forms and
# effort mapping are imported from src/pane-agent.ts, and the registry's harness
# set is lifted, so a harness the registry gains is compared without anyone
# editing this list.
cat >"$TMP/arm-forms.ts" <<'EOF'
const [mod, ...combos] = process.argv.slice(2);
const { effortFlag, oneshotLaunch } = await import(mod);
for (const c of combos) {
  const [h, m, e] = c.split("|");
  const ae = effortFlag(e);
  console.log(ae === null ? "<refused>" : (oneshotLaunch(h, m, ae) ?? "<null>"));
}
EOF
harnesses="$(sed -n '/^ac_harness_known() {/,/^}/s/^ *case "\$1" in \(.*\)) return 0 ;;.*/\1/p' "$BIN/ac-harness.sh" | tr -d ' ' | tr '|' ' ')"
[ -n "$harnesses" ] || fail "no harness set lifted from ac_harness_known in bin/ac-harness.sh"
cat >"$TMP/synth-forms.ts" <<'EOF'
import { readFileSync } from "node:fs";
import { join } from "node:path";
const [brainTs, ...combos] = process.argv.slice(2);
const fn = readFileSync(brainTs, "utf8").match(/^function synthCommand\(\)[^\n]*\n[\s\S]*?\n\}\n/m);
if (!fn) throw new Error(`no synthCommand in ${brainTs}`);
const js = new Bun.Transpiler({ loader: "ts" }).transformSync(fn[0]);
const synth = new Function("HOME", "readFileSync", "join", "process", `${js}\nreturn synthCommand();`);
for (const c of combos) {
  const [h, m, e] = c.split("|");
  const knobs: Record<string, string> = { "brain-agent": h, "brain-model": m, "brain-effort": e };
  const read = (p: string) => {
    const k = p.split("/").pop()!;
    if (!(k in knobs)) throw new Error(`ENOENT ${p}`);
    return knobs[k];
  };
  try { console.log(synth("/no-home", read, join, { env: {} }) ?? "<null>"); }
  catch { console.log("<refused>"); }
}
EOF
combos=()
for h in $harnesses; do
  for m in "" m1; do for e in "" high ultracode bogus; do combos+=("$h|$m|$e"); done; done
done
brain_forms="$(bun "$TMP/synth-forms.ts" "$ROOT/src/brain.ts" "${combos[@]}")"
arm_forms=()
while IFS= read -r want; do arm_forms+=("$want"); done < <(bun "$TMP/arm-forms.ts" "$ROOT/src/pane-agent.ts" "${combos[@]}")
assert_eq "${#arm_forms[@]}" "${#combos[@]}" "the pane agent printed one form per combination"
drift="" i=0
while IFS= read -r got; do
  IFS='|' read -r h m e <<<"${combos[$i]}"
  want="${arm_forms[$i]}"
  [ "$got" = "$want" ] || drift="$drift
  $h model='$m' effort='$e': brain '$got' vs the pane agent '$want'"
  i=$((i + 1))
done <<<"$brain_forms"
assert_eq "$i" "${#combos[@]}" "the brain printed one form per combination"
[ -z "$drift" ] || fail "brain.ts's one-shot forms drifted from the pane agent's:$drift"
# No engine configured stays "no engine" (no_llm), even beside an orphan effort.
assert_eq "$(bun "$TMP/synth-forms.ts" "$ROOT/src/brain.ts" "||" "||bogus" | tr '\n' ' ')" "<null> <null> " \
  "an empty harness is no engine, never a refusal of its leftover effort"

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
# a soft-deleted page keeps its vectors for the revive window, but the scan
# skips them, so the census must too
DB="$AC_HOME/state/brain.sqlite"
gone="$(sqlite3 "$DB" "SELECT slug FROM chunks WHERE embedding IS NOT NULL AND slug IN (SELECT slug FROM pages WHERE deleted_at IS NULL) LIMIT 1")"
[ -n "$gone" ] || fail "the doctor census row needs an embedded live page"
sqlite3 "$DB" "UPDATE pages SET deleted_at='2099-01-01T00:00:00Z' WHERE slug='$gone'"
live="$(sqlite3 "$DB" "SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL AND slug IN (SELECT slug FROM pages WHERE deleted_at IS NULL)")"
docdel="$("$BRAIN" doctor --home "$AC_HOME" --compact)" || true
sqlite3 "$DB" "UPDATE pages SET deleted_at=NULL WHERE slug='$gone'"
assert_contains "$docdel" "\"$live embedded chunks (linear-scan budget 50000)" "the scale census counts only chunks of live pages"

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

# --- a harness refusal sits AFTER the earlier rungs, never over them ----------
# agy is refused at the harness rung only once the API rung failed: the status
# keeps that failure (llm_error;harness_refused), and an API rung that answers
# leaves no refusal on stderr. The API rung points at a local stub through
# synthesize.api.base_url, keyless as the ollama provider.
synth_api_stub() {  # synth_api_stub <status> <body>
  printf 'const s = Bun.serve({ port: 0, fetch: () => new Response(%s, { status: %s }) });\nconsole.log(s.port);\nawait new Promise(() => {});\n' \
    "$2" "$1" >"$TMP/synth-api.ts"
  rm -f "$TMP/synth-api.port"
  embed_stub_up "$TMP/synth-api.ts" "$TMP/synth-api.port" || { embed_stub_down; fail "the synthesize API stub never came up"; }
  printf '{"synthesize":{"api":{"provider":"ollama","model":"m","base_url":"http://127.0.0.1:%s/v1"}}}\n' \
    "$EMBED_STUB_PORT" >"$AC_HOME/config/brain.json"
}
printf 'agy\n' >"$AC_HOME/config/brain-agent"
synth_api_stub 500 "'{}'"
sa1="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>"$TMP/sa1.err")"
embed_stub_down
assert_eq "$(printf '%s' "$sa1" | j "['synthesis_status']")" "llm_error;harness_refused;extractive_fallback" \
  "a failed API rung then a refused harness keeps both in the status"
assert_contains "$(cat "$TMP/sa1.err")" "agy" "...and stderr names the refused harness"
synth_api_stub 200 "JSON.stringify({ choices: [{ message: { content: 'stub-api-answer' } }] })"
sa2="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>"$TMP/sa2.err")"
embed_stub_down
assert_eq "$(printf '%s' "$sa2" | j "['synthesis_status']")" "ok" "an API rung that answers settles it"
assert_contains "$sa2" "stub-api-answer" "...with its own answer"
case "$(cat "$TMP/sa2.err")" in *refus*|*"no ac-brain synthesize"*) fail "an answered synthesize must not report the unreached harness rung: $(cat "$TMP/sa2.err")" ;; esac
rm -f "$AC_HOME/config/brain.json" "$AC_HOME/config/brain-agent"

# The composer is told today's date and each source's own date - without them a
# "latest" or "still true" question cannot tell a superseded page from a current
# one. The stub answers with the prompt it was sent.
cat >"$TMP/synth-echo.ts" <<'TS'
const s = Bun.serve({ port: 0, fetch: async (r) => {
  const b = await r.json();
  return Response.json({ choices: [{ message: { content: b.messages[0].content } }] });
} });
console.log(s.port);
await new Promise(() => {});
TS
rm -f "$TMP/synth-api.port"
embed_stub_up "$TMP/synth-echo.ts" "$TMP/synth-api.port" || { embed_stub_down; fail "the synthesize echo stub never came up"; }
printf '{"synthesize":{"api":{"provider":"ollama","model":"m","base_url":"http://127.0.0.1:%s/v1"}}}\n' \
  "$EMBED_STUB_PORT" >"$AC_HOME/config/brain.json"
se="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>/dev/null)"
embed_stub_down
assert_contains "$se" "Today is $(date -u +%Y-%m-%d)" "the synthesize prompt states today's date"
assert_contains "$se" "written $(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT substr(updated_at,1,10) FROM pages WHERE slug LIKE '%widget%' LIMIT 1")" \
  "...and each source's own date"
# The index keeps a pattern-hit page whole (flags, never drops), but what
# synthesize sends to a model is outside the home: every match is redacted.
printf 'zzsecretmarker\n' >"$TMP/pat-redact"
mkdir -p "$AC_HOME/data/fam-redact"
printf '# Redaction probe\nThe redaction probe deploy token is zzsecretmarker for this page.\n' >"$AC_HOME/data/fam-redact/room.md"
AC_BRAIN_PATTERN_FILE="$TMP/pat-redact" "$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
rm -f "$TMP/synth-api.port"
embed_stub_up "$TMP/synth-echo.ts" "$TMP/synth-api.port" || { embed_stub_down; fail "the synthesize echo stub never came up"; }
printf '{"synthesize":{"api":{"provider":"ollama","model":"m","base_url":"http://127.0.0.1:%s/v1"}}}\n' \
  "$EMBED_STUB_PORT" >"$AC_HOME/config/brain.json"
sr="$(AC_BRAIN_PATTERN_FILE="$TMP/pat-redact" "$BRAIN" synthesize "redaction probe deploy token" --home "$AC_HOME" --compact 2>/dev/null)"
embed_stub_down
assert_contains "$sr" "Redaction probe" "the pattern-hit page still reaches the composer"
assert_contains "$sr" "deploy token is [redacted]" "...with the match redacted"
case "$sr" in *zzsecretmarker*) fail "a pattern match left the home inside a synthesize prompt" ;; esac
rm -f "$AC_HOME/config/brain.json"; rm -rf "$AC_HOME/data/fam-redact"

# --- the keyless local rung asks AC_BRAIN_OLLAMA_URL, and the suite asks nobody --
# With no synthesize api answering, a local ollama answers before the harness
# rung - so a daemon on the operator's default port would answer every leg
# here instead of the command under test. helpers.sh points the rung at a
# closed port; a listener at the URL the env names IS asked.
synth_api_stub 200 "JSON.stringify({ data: [{ id: 'local-model' }], choices: [{ message: { content: 'local-ollama-answer' } }] })"
rm -f "$AC_HOME/config/brain.json"
so1="$(AC_BRAIN_OLLAMA_URL="http://127.0.0.1:$EMBED_STUB_PORT/v1" "$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>/dev/null)"
so2="$("$BRAIN" synthesize "widget product line" --home "$AC_HOME" --compact 2>/dev/null)"
embed_stub_down
assert_contains "$so1" "local-ollama-answer" "the local rung asks the URL AC_BRAIN_OLLAMA_URL names"
case "$so2" in *local-ollama-answer*) fail "the suite's default must reach no local daemon: $so2" ;; esac

# --- entity(): an exact slug is the page itself ------------------------------
# A dedup leaves an alias from the duplicate's slug to its canonical page, and
# that alias outlives the duplicate diverging into a page of its own - it must
# never outrank the exact slug. A bare basename two pages share is ambiguous,
# and a guess between them is the one link resolution refuses.
mkdir -p "$AC_HOME/data/fam-tw/deep"
printf '# Twin probe\nThe twinned entity probe body stays byte-identical at first.\n' >"$AC_HOME/data/fam-tw/twin.md"
printf '# Twin probe\nThe twinned entity probe body stays byte-identical at first.\n' >"$AC_HOME/data/fam-tw/deep/twin.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
printf '# Deep twin\nThe deep twin has since diverged into a page of its own.\n' >"$AC_HOME/data/fam-tw/deep/twin.md"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
et="$("$BRAIN" entity data/fam-tw/deep/twin --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$et" | j "['card']['slug']")" "data/fam-tw/deep/twin" "a diverged duplicate resolves to itself, not its stale alias"
eb="$("$BRAIN" entity twin --home "$AC_HOME" --compact)"
assert_eq "$(printf '%s' "$eb" | j "['found']")" "False" "a basename two pages share resolves to neither"
rm -rf "$AC_HOME/data/fam-tw"

# --- recall --since is a TIME, not a string prefix ---------------------------
# created_at carries milliseconds while a fleet stamp (ac_iso) does not, so a
# raw text compare dropped a fact made in the same second as the bound, and a
# relative bound like 7d matched nothing at all.
"$BRAIN" remember "the since probe fact rides a millisecond stamp" --provenance t --agent since-probe --home "$AC_HOME" --compact >/dev/null
sec="$(sqlite3 "$AC_HOME/state/brain.sqlite" "SELECT substr(created_at,1,19) || 'Z' FROM facts WHERE agent='since-probe'")"
assert_contains "$("$BRAIN" recall --agent since-probe --since "$sec" --home "$AC_HOME" --compact)" "since probe fact" \
  "a bound without milliseconds keeps a fact from that same second"
assert_contains "$("$BRAIN" recall --agent since-probe --since 7d --home "$AC_HOME" --compact)" "since probe fact" \
  "a relative bound is a duration back from now"
if bad="$("$BRAIN" recall --since junk --home "$AC_HOME" --compact 2>&1)"; then fail "an unreadable --since must refuse (got: $bad)"; fi

# A malformed count or calendar date refuses: NaN sliced every hit away, a
# negative limit kept all but the last few, and the date parser rolls an
# impossible day over (2024-02-30 reads as 2024-03-01).
for bad_args in "recall --query fact --limit abc" "recall --query fact --limit -3" \
  "recall --query fact --budget-tokens abc" "context_pack --entities data/fam-one/room --budget-tokens -1" \
  "recall --since 2024-02-30" "recall --since 2026-02-31T08:00:00Z" \
  "remember x --provenance t --ttl 2024-02-30"; do
  # shellcheck disable=SC2086  # each case is a word list on purpose
  if bad="$("$BRAIN" $bad_args --home "$AC_HOME" --compact 2>&1)"; then fail "$bad_args must refuse (got: $bad)"; fi
  assert_contains "$bad" '"invalid_params"' "$bad_args refuses as invalid_params"
done
assert_contains "$("$BRAIN" recall --since 2024-02-29 --home "$AC_HOME" --compact)" '"facts"' "a leap day is a real date"

# --- the caller's cwd configures nothing -------------------------------------
# The prompt-recall hook runs the engine from a solo session's cwd, often a
# project worktree: its .env, bunfig.toml preload and tsconfig paths must not
# reach the engine - neither through the shim nor through serve's re-exec - and
# a relative --home still resolves against that cwd.
ctrap="$TMP/brain-cwd-trap"
mkdir -p "$ctrap"
printf 'console.log("PRELOAD-RAN");\n' >"$ctrap/p.ts"
printf 'preload = ["./p.ts"]\n' >"$ctrap/bunfig.toml"
printf '{"compilerOptions":{"paths":{"*":["./p.ts"]}}}\n' >"$ctrap/tsconfig.json"
st="$(cd "$ctrap" && "$BRAIN" stats --home "$AC_HOME" --compact 2>&1)"
case "$st" in *PRELOAD-RAN*) fail "a caller cwd's bun config ran inside the engine: $st" ;; esac
assert_contains "$st" '"pages"' "stats answers from a hostile cwd"
mcp2="$(printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recall","arguments":{"query":"widget product line"}}}' \
  | (cd "$ctrap" && "$BRAIN" serve --home "$AC_HOME") 2>&1)"
case "$mcp2" in *PRELOAD-RAN*) fail "serve's re-exec ran a caller cwd's bun config: $mcp2" ;; esac
assert_contains "$mcp2" "crewdomains/dom-a/CREWMATE" "serve's re-exec answers from a hostile cwd"
rel="$(cd "$(dirname "$AC_HOME")" && "$BRAIN" stats --home "$(basename "$AC_HOME")" --compact 2>&1)"
assert_contains "$rel" '"pages"' "a relative --home resolves against the caller's cwd"
# Bun cannot name a cwd that ends in a backslash; bash can, so only the engine
# sees the cwd as nameless there.
bnameless="$TMP/brain-cwd\\"
mkdir -p "$bnameless/relhome"
nameless="$(cd "$bnameless" && "$BRAIN" stats --home relhome --compact 2>/dev/null || true)"
assert_contains "$nameless" "current directory cannot be resolved" "a relative --home from a cwd bun cannot name is refused"
noverb="$("$BRAIN" --home "$AC_HOME" 2>&1 || true)"
assert_contains "$noverb" '"error"' "no verb still answers one JSON error"

# --- differential leg: the entry's resolution against the frozen bash original --
# The frozen original (tests/fixtures/ac-brain.sh) took every `--home <value>`
# pair out of argv, refused in its own JSON, and started the module with
# `--home <home>` appended - the module's direct form, which the port leaves as
# it was, so the oracle bin's linked src/ runs that original end to end.
# links-to is the verb: no network, no clock in its answer, the target echoed
# back. The world's tree and each usage log (its clock dropped) are compared
# too - they name the home a run used.
# DISPUTED: the implementation (tests/fixtures/ac-brain.sh under bash vs src/brain.ts through bin/ac-brain.sh)
# HELD-CONSTANT: one world path ($BXW: h/ the home, `s p/` a home with a space, l a link to h, f a regular file, an LF-ended home, cwd/ the caller cwd holding rel/ and a dir named --home, `n\` a cwd bun cannot name holding rel/) rebuilt before each side; argv; env (PATH the suite's unless the row names one, AC_HOME=$BXW/h unless the row unsets or names another, AC_BRAIN_PATTERN_FILE the suite's; AC_SOLO, AC_SCOPE, AC_FLEET_STATE and CDPATH unset); cwd ($BXW/cwd unless the row names one, deleted first where the row says); stdin (/dev/null unless the row names a file); exit status, stdout (serve's latency_ms dropped), stderr and the world compared whole.
bxobin="$(make_oracle_bin ac-brain)"
cmp -s "$bxobin/ac-brain.sh" "$ROOT/tests/fixtures/ac-brain.sh" || fail "the oracle bin holds the frozen original"
BXW="$TMP/bxw"
BXHOME="$BXW/h"; BXCWD="$BXW/cwd"; BXGONE=0; BXPATH="$PATH"; BXIN=/dev/null; BXRC=0
bxworld() {
  rm -rf "$BXW"
  mkdir -p "$BXW/h" "$BXW/s p" "$BXW/cwd/rel" "$BXW/cwd/--home" "$BXW/n\\/rel" "$BXW/lf"$'\n'
  : >"$BXW/f"
  ln -s h "$BXW/l"
}
bxsnap() {  # bxsnap <file> - the world's tree, then each usage log without its clock
  local f
  ( cd "$BXW" && find . | LC_ALL=C sort ) >"$1"
  for f in "$BXW"/*/state/brain-usage.jsonl "$BXW"/*/*/state/brain-usage.jsonl; do
    [ -f "$f" ] || continue
    printf '%s\n' "${f#"$BXW"/}"
    sed -e 's/"at":"[^"]*",//' -e 's/,"ms":[0-9.]*//' "$f"
  done >>"$1"
}
bxside() {  # bxside <bin> <prefix> <args...> - one side in a fresh world
  local bin="$1" p="$2" rc=0
  shift 2
  local e=("PATH=$BXPATH")
  [ "$BXHOME" = - ] || e+=("AC_HOME=$BXHOME")
  bxworld
  ( cd "$BXCWD" || exit 97
    [ "$BXGONE" = 0 ] || rm -rf "$BXCWD"
    exec env -u AC_HOME -u AC_SOLO -u AC_SCOPE -u AC_FLEET_STATE -u CDPATH "${e[@]}" "$bin/ac-brain.sh" ${@+"$@"}
  ) <"$BXIN" >"$TMP/$p.out" 2>"$TMP/$p.err" || rc=$?
  # From a deleted cwd bash prints its own getcwd lines, one per shell and cd
  # it runs (SHELL-OWN): both sides drop them.
  if [ "$BXGONE" = 1 ]; then
    grep -av -e '^shell-init: error retrieving current directory' -e '^chdir: error retrieving current directory' "$TMP/$p.err" >"$TMP/$p.err.kept" || true
    mv "$TMP/$p.err.kept" "$TMP/$p.err"
  fi
  sed 's/latency_ms[^,]*,//g' "$TMP/$p.out" >"$TMP/$p.cmp"
  bxsnap "$TMP/$p.snap"
  BXRC=$rc
}
BXO_RC=0; BXN_RC=0
bxpair() { bxside "$bxobin" bxo ${@+"$@"}; BXO_RC=$BXRC; bxside "$BIN" bxn ${@+"$@"}; BXN_RC=$BXRC; }
bxline() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }
bxsame() {  # bxsame <args...> - exit, stdout, stderr and the world alike
  local at; at="$(bxline)"
  bxpair ${@+"$@"}
  assert_eq "$BXN_RC" "$BXO_RC" "brain entry differential exit for '$*' at line $at"
  cmp -s "$TMP/bxo.cmp" "$TMP/bxn.cmp" || fail "brain entry differential stdout differs for '$*' at line $at: $(diff "$TMP/bxo.cmp" "$TMP/bxn.cmp" | head -n 8)"
  cmp -s "$TMP/bxo.err" "$TMP/bxn.err" || fail "brain entry differential stderr differs for '$*' at line $at: $(diff "$TMP/bxo.err" "$TMP/bxn.err" | head -n 6)"
  cmp -s "$TMP/bxo.snap" "$TMP/bxn.snap" || fail "brain entry differential world differs for '$*' at line $at: $(diff "$TMP/bxo.snap" "$TMP/bxn.snap" | head -n 8)"
}
bxrefuse() {  # bxrefuse <stdout> <args...> - both sides refuse alike: exit 1, exactly <stdout>, no stderr
  local want="$1"
  shift
  bxsame ${@+"$@"}
  assert_eq "$BXN_RC:$(cat "$TMP/bxn.out"):$(cat "$TMP/bxn.err")" "1:$want:" "brain entry refusal for '$*' at line $(bxline)"
}
bxout() { cat "$TMP/bxn.out"; }
bxused() {  # bxused <home relpath> <what> - the port's run (the world's last) opened that home's brain
  [ -f "$BXW/$1/state/brain.sqlite" ] || fail "$2: no brain under $1"
}
BXNOVAL='{"error":"invalid_params","message":"--home needs a value","suggestion":"pass --home <abs path> or set AC_HOME"}'
BXNOHOME='{"error":"invalid_params","message":"no fleet home","suggestion":"pass --home <abs path> or set AC_HOME"}'
BXNOBUN='{"error":"unavailable","message":"bun not on PATH","suggestion":"install bun (https://bun.sh) - the engine runs on it"}'
BXNONAME='{"protocol_version":1,"error":"invalid_params","message":"the current directory cannot be resolved, so a relative home cannot be either","suggestion":"pass --home <abs path>"}'

# 1. --home after, before and among the verb's words, the last pair winning;
#    a home with a space, a link, an LF-ended name; the words handed on as given.
bxsame links-to t --home "$BXW/h" --compact
assert_eq "$(bxout)" '{"target":"t","referencing_pages":0,"families":[],"top":[]}' "row 1: the verb answers"
bxused h "row 1: from the home --home names"
bxsame --home "$BXW/h" links-to t --compact
bxsame links-to --home "$BXW/h" t --compact
bxsame links-to --compact t --home "$BXW/f" --home "$BXW/s p"
bxused "s p" "row 1: the last --home wins"
bxsame links-to t --compact --home "$BXW/l"
bxsame links-to t --compact --home "$BXW/lf"$'\n'
bxused "lf"$'\n' "row 1: an LF-ended home is that directory"
bxsame links-to t --home=x --compact
bxused h "row 1: --home=x is a word of the verb's, the home AC_HOME's"
bxsame links-to 'a  b*?[x] $HOME' --compact
assert_contains "$(bxout)" '"target":"a  b*?[x] $HOME"' "row 1: the verb's words arrive untouched"
bxsame links-to "$(printf '\303\251\nz\351')" --compact
bxsame links-to --by me '' --compact
bxsame links-to

# 2. an empty --home falls back to AC_HOME; a value that is itself --home is a
#    home (a directory of that name in the cwd); a --home with no value refuses
#    wherever it stands, before the home is looked at.
bxsame links-to t --home '' --compact
bxused h "row 2: an empty --home is AC_HOME"
BXHOME=- bxrefuse "$BXNOHOME" links-to t --home '' --compact
bxsame links-to t --compact --home --home
bxused cwd/--home "row 2: --home --home names a directory called --home"
bxrefuse "$BXNOVAL" links-to t --home
bxrefuse "$BXNOVAL" --home
bxrefuse "$BXNOVAL" links-to --home "$BXW/h" t --home
BXHOME=- bxrefuse "$BXNOVAL" links-to t --home

# 3. AC_HOME: unset, empty, missing, a file, a link, a name with a space.
BXHOME=- bxrefuse "$BXNOHOME" links-to t --compact
BXHOME='' bxrefuse "$BXNOHOME" links-to t --compact
BXHOME="$BXW/nope" bxrefuse "$BXNOHOME" links-to t --compact
BXHOME="$BXW/f" bxrefuse "$BXNOHOME" links-to t --compact
bxrefuse "$BXNOHOME" links-to t --home "$BXW/f" --compact
BXHOME="$BXW/l" bxsame links-to t --compact
BXHOME="$BXW/s p" bxsame links-to t --compact
bxused "s p" "row 3: AC_HOME with a space"

# 4. a relative home is the caller's: from a named cwd, and from one bun cannot
#    name (the module's own refusal once the home is there, the entry's when not).
bxsame links-to t --home rel --compact
bxused cwd/rel "row 4: a relative --home under the caller's cwd"
BXHOME=rel bxsame links-to t --compact
bxrefuse "$BXNOHOME" links-to t --home nope --compact
BXCWD="$BXW/n\\" bxrefuse "$BXNONAME" links-to t --home rel --compact
BXCWD="$BXW/n\\" bxrefuse "$BXNOHOME" links-to t --home nope --compact
BXCWD="$BXW/n\\" bxsame links-to t --home "$BXW/h" --compact

# 5. a deleted cwd: an absolute home answers; `.` is there to both sides and
#    refused as relative. HOME RESOLUTION, named: the original's [ -d ] still
#    looked inside the deleted directory, which holds no other name, so `rel`
#    was no fleet home there; the port, started in the distro root, cannot
#    look, and refuses every relative home as the module does.
BXGONE=1 bxsame links-to t --home "$BXW/h" --compact
BXGONE=1 bxrefuse "$BXNONAME" links-to t --home . --compact
BXGONE=1 bxpair links-to t --home rel --compact
assert_eq "$BXO_RC:$(cat "$TMP/bxo.out"):$BXN_RC:$(bxout)" "1:$BXNOHOME:1:$BXNONAME" "HOME RESOLUTION: a relative home from a deleted cwd"

# 6. no verb: the module's unknown-command refusal, from both.
bxsame --home "$BXW/h"
assert_contains "$(bxout)" "unknown command '--home'" "row 6: no verb"

# 7. serve's per-call re-exec starts the module in its direct form, so a tool
#    argument named home never moves it off its home, and a trailing --home
#    word is a word.
printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"entity\",\"arguments\":{\"name\":\"x\",\"home\":\"$BXW/s p\"}}}" \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"entity","arguments":{"name":"--home"}}}' >"$TMP/bx-mcp.in"
BXIN="$TMP/bx-mcp.in" bxsame serve --home "$BXW/h"
assert_contains "$(bxout)" '\"found\":false' "row 7: the home argument is ignored"
assert_contains "$(bxout)" 'no name' "row 7: a trailing --home word is no refusal"
case "$(cat "$TMP/bxn.snap")" in *"./s p/state"*) fail "row 7: serve's re-exec opened the home a tool argument named" ;; esac

# 8. no bun on PATH: the shim's own JSON line, before any argument is read.
bxnobun="$TMP/bxnobun"
mkdir -p "$bxnobun"
for x in bash dirname; do ln -sf "$(command -v "$x")" "$bxnobun/$x"; done
BXPATH="$bxnobun" bxrefuse "$BXNOBUN" links-to t --compact
BXPATH="$bxnobun" bxrefuse "$BXNOBUN" links-to t --home
BXPATH="$bxnobun" BXHOME=- bxrefuse "$BXNOBUN" links-to t

pass
