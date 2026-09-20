#!/usr/bin/env bash
# ac-brain-bench.test.sh - retrieval QUALITY on an AgentCrew-shaped corpus.
# The unit suite proves the verbs function; this suite proves the answers are
# GOOD: twelve realistic single-gold fleet questions (rooms, ledger, learnings,
# domain knowledge, Vietnamese with and without diacritics, duplicate
# basenames) scored as Recall@5 and MRR, four multi-gold questions scored as
# recall_all@5, all split into a TUNING half and a FROZEN half (the fence a
# ranking-knob change must carry a receipt against), plus citation correctness
# (every hit's path exists), a false-positive probe (absent topics return
# nothing), and forgotten-fact exclusion. Two lanes: keyless first - the BM25
# arm is the floor every home has - then the deterministic stub embedding,
# which exercises the fusion path the keyless lane cannot reach.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
BRAIN="$BIN/ac-brain.sh"
export AC_BRAIN_PATTERN_FILE="$TMP/no-such-pattern-file"

# --- corpus: the shape of a real fleet home -----------------------------------
mkdir -p "$AC_HOME/records/repo-knowledge" \
  "$AC_HOME/data/harbor-sync/spec" "$AC_HOME/data/ledger-guard" \
  "$AC_HOME/data/pane-resize" "$AC_HOME/data/old-worktree" \
  "$AC_HOME/crewdomains/b2c-shop/records"
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog
## In flight
- [ ] harbor-sync [EPIC] - synchronize the harbor manifests across fleets (repo: payproc)
- [ ] pane-resize - the watcher pane hangs on resize (repo: shipyard)
## Queued
- [ ] ledger-guard-hardening - tighten the scoped-edit refusal (repo: payproc)
## Done
- [x] old-worktree - retire the stale worktree lease path (merged 2026-08-01)
EOF
cat >"$AC_HOME/records/captain.md" <<'EOF'
# Captain
STANDING: the captain alone orders a public push, and every push runs the gate.
STANDING: never print full provider keys in any pane or report.
EOF
cat >"$AC_HOME/records/learnings.md" <<'EOF'
# Learnings
## Pending
### 2026-08-10 (family old-worktree)
- a second worktree lease never reaches the meta that teardown reads, so the lease leaks
EOF
printf '# payproc knowledge\n- the payment processor retries with exponential backoff capped at five attempts (by: harbor-sync)\n' \
  >"$AC_HOME/records/repo-knowledge/payproc.md"
printf '# shipyard knowledge\n- the shipyard build pipeline caches bun install artifacts per branch (by: pane-resize)\n' \
  >"$AC_HOME/records/repo-knowledge/shipyard.md"
cat >"$AC_HOME/data/harbor-sync/room.md" <<'EOF'
# Room: harbor-sync
TRIAGE: flow=staged - gate review required before implement.
Quy trình nghiệm thu bến cảng chạy sau khi gate review xong.
The harbor sync gate review opens once the spec lands.
EOF
printf '# Spec report\nAcceptance criteria for the harbor spec: manifests converge within one cycle and the report lists every skipped shard.\n' \
  >"$AC_HOME/data/harbor-sync/spec/report.md"
printf '# Room: ledger-guard\nThe ledger guard refuses a scoped edit on the fleet ledger and points the chief at handback instead.\n' \
  >"$AC_HOME/data/ledger-guard/room.md"
printf '# Guard report\nRefusal counts for the quarter grouped by scope and verb live in this quarterly summary.\n' \
  >"$AC_HOME/data/ledger-guard/report.md"
printf '# Room: pane-resize\nPane bị treo khi resize màn hình; watcher không nhận exit code, phải rearm thủ công.\n' \
  >"$AC_HOME/data/pane-resize/room.md"
printf '# Domain b2c-shop\nThe b2c shop domain charter covers checkout, catalog and promotions end to end.\n' \
  >"$AC_HOME/crewdomains/b2c-shop/CREWMATE.md"
printf '# Projects\n## payproc\nThe domain view of payproc focuses on the checkout path only.\n' \
  >"$AC_HOME/crewdomains/b2c-shop/records/projects.md"
printf '# Room: old-worktree\nThe stale worktree lease retirement landed; this room is a historical record.\n' \
  >"$AC_HOME/data/old-worktree/room.md"

"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null

# --- the question set ---------------------------------------------------------
# query|gold[,gold...] ; one line per case. A single gold scores Recall@5 and
# MRR; several golds score recall_all@5 - EVERY gold in the top 5 - which is
# what a fusion defect shows up in (a relaxed keyword row or a boosted hub
# crowding a second gold out) when "any gold" cannot see it. VN cases cover
# accented, accent-less and mixed; case 9 must beat the duplicate-basename
# sibling (guard report).
#
# TWO HALVES. The TUNING half is what a ranking change is allowed to be fitted
# against; the FROZEN half is the regression fence - a knob change (fusion
# weights, boosts, the relaxed-row rule, the metadata gate) must carry a
# receipt of the frozen half's numbers before and after, and never a query
# moved between halves to make a number pass.
cases_tuning() { cat <<'EOF'
harbor sync gate review|data/harbor-sync/room
pane treo khi resize|data/pane-resize/room
pane bị treo khi resize màn hình|data/pane-resize/room
payment processor retry backoff|records/repo-knowledge/payproc
ledger guard refuses scoped edit|data/ledger-guard/room
b2c shop domain charter|crewdomains/b2c-shop/CREWMATE
payproc|records/repo-knowledge/payproc,records/backlog,crewdomains/b2c-shop/records/projects
worktree lease|records/learnings,data/old-worktree/room,records/backlog
EOF
}
cases_frozen() { cat <<'EOF'
captain orders public push|records/captain
quy trình nghiệm thu bến cảng|data/harbor-sync/room
acceptance criteria harbor spec|data/harbor-sync/spec/report
worktree lease leaks teardown|records/learnings
shipyard build pipeline caches|records/repo-knowledge/shipyard
queued backlog epic manifests|records/backlog
pane resize watcher|data/pane-resize/room,records/backlog
harbor|data/harbor-sync/room,data/harbor-sync/spec/report,records/backlog
EOF
}

# run_lane <label> - every case through recall, then the scorer with the
# lane's floors. Floors are what a real run produced on the day the lane was
# added, minus the slack the keyless floors always carried - never a guess.
run_lane() {
  local lane="$1" half i=0 q expect
  rm -f "$TMP"/bench-*
  for half in tuning frozen; do
    while IFS='|' read -r q expect; do
      i=$((i + 1))
      "$BRAIN" recall --query "$q" --home "$AC_HOME" --compact >"$TMP/bench-$i.json" \
        || fail "$lane: recall exits 0 on bench query $i"
      printf '%s\n' "$expect" >"$TMP/bench-$i.expect"
      printf '%s\n' "$half" >"$TMP/bench-$i.half"
    done < <("cases_$half")
  done
  python3 - "$TMP" "$AC_HOME" "$lane" <<'EOF' || fail "$lane: bench metrics under threshold"
import json, sys, os, glob
tmp, home, lane = sys.argv[1], sys.argv[2], sys.argv[3]
files = sorted(glob.glob(os.path.join(tmp, "bench-*.json")),
               key=lambda p: int(p.split("-")[-1].split(".")[0]))
acc = {h: {"n1": 0, "hit": 0, "mrr": 0.0, "nm": 0, "all": 0} for h in ("tuning", "frozen")}
for f in files:
    n = f[:-5]
    golds = open(n + ".expect").read().strip().split(",")
    half = open(n + ".half").read().strip()
    d = json.load(open(f))
    slugs = [r["slug"] for r in d.get("results", [])][:5]
    a = acc[half]
    if len(golds) == 1:
        rank = slugs.index(golds[0]) + 1 if golds[0] in slugs else 0
        a["n1"] += 1
        if rank: a["hit"] += 1; a["mrr"] += 1.0 / rank
        print(f"  {lane} {half} {os.path.basename(f)}: expect {golds[0]} rank {rank if rank else 'MISS'}")
    else:
        missing = [g for g in golds if g not in slugs]
        a["nm"] += 1
        if not missing: a["all"] += 1
        print(f"  {lane} {half} {os.path.basename(f)}: expect all of {golds} {'ok' if not missing else 'MISSING ' + str(missing)}")
    # citation correctness: every hit names a real file
    for r in d.get("results", [])[:5]:
        p = r.get("path")
        if p and not os.path.isabs(p): p = os.path.join(home, p)
        if p and not os.path.exists(p):
            print(f"BAD CITATION: {r['slug']} -> {p}"); sys.exit(1)
t, fz = acc["tuning"], acc["frozen"]
n1 = t["n1"] + fz["n1"]; hit = t["hit"] + fz["hit"]; mrr = (t["mrr"] + fz["mrr"]) / n1
nm = t["nm"] + fz["nm"]; allk = t["all"] + fz["all"]
fmrr = fz["mrr"] / fz["n1"]
print(f"bench[{lane}]: single-gold n={n1} recall@5={hit}/{n1} mrr={mrr:.3f} | multi-gold n={nm} recall_all@5={allk}/{nm}")
print(f"bench[{lane}] frozen half: recall@5={fz['hit']}/{fz['n1']} mrr={fmrr:.3f} recall_all@5={fz['all']}/{fz['nm']}")
if os.environ.get("BENCH_PRINT_ONLY"): sys.exit(0)
# FLOORS, from the run that added the halves (2026-09-20):
#   keyless        single 12/12 mrr 1.000  multi 4/4  frozen 6/6 mrr 1.000 2/2
#   stub-embedded  single 12/12 mrr 0.944  multi 4/4  frozen 6/6 mrr 0.889 2/2
# The overall single-gold floor is the original keyless one and keeps its
# slack; multi-gold and the frozen half sit one miss / ~0.09 MRR below the
# measurement, so a single regression shows before two hide each other.
ok = (n1 == 12 and hit >= 10 and mrr >= 0.55
      and nm == 4 and allk >= 3
      and fz["hit"] >= 5 and fmrr >= 0.80 and fz["all"] >= 2)
sys.exit(0 if ok else 1)
EOF
}

run_lane keyless

# --- false positives: an absent topic returns nothing -------------------------
fp="$("$BRAIN" recall --query "kubernetes helm canary rollback" --home "$AC_HOME" --compact)"
assert_contains "$fp" '"results":[]' "an absent topic returns zero hits, not confident noise"

# --- the embedded lane: the same set through fusion --------------------------
# The `stub` provider is a deterministic hash-bucket bag of words, so this
# lane proves the FUSION path (vector arm present, relaxed rows dropped, the
# metadata gate live) holds the floors - not that embeddings understand the
# question. A real provider only improves on the BM25 arm it fuses with.
printf '{"embedding":{"provider":"stub","model":"stub","dims":64}}\n' >"$AC_HOME/config/brain.json"
"$BRAIN" sync --home "$AC_HOME" --compact >/dev/null
run_lane stub-embedded
# an absent topic still earns no CONFIDENT hit: a bucket collision surfaces
# only under the vector_weak label
fp2="$("$BRAIN" recall --query "kubernetes helm canary rollback" --home "$AC_HOME" --compact)"
case "$fp2" in *'"evidence":"vector"'*|*'"evidence":"keyword"'*) fail "an absent topic must not earn a confident label in the embedded lane: $fp2" ;; esac
rm -f "$AC_HOME/config/brain.json"

# --- forgotten facts stay forgotten -------------------------------------------
rid="$("$BRAIN" remember "the pane resize fix is abandoned for now" --provenance bench --agent bench --entity data/pane-resize/room --home "$AC_HOME" --compact \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')"
"$BRAIN" forget "$rid" --reason bench --home "$AC_HOME" --compact >/dev/null
fq="$("$BRAIN" recall --query "pane resize abandoned" --home "$AC_HOME" --compact)"
case "$fq" in
  *"abandoned for now"*) fail "a forgotten fact resurfaced in recall" ;;
esac

pass
