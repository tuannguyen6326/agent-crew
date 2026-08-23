#!/usr/bin/env bash
# ac-brain-bench.test.sh - retrieval QUALITY on an AgentCrew-shaped corpus.
# The unit suite proves the verbs function; this suite proves the answers are
# GOOD: twelve realistic fleet questions (rooms, ledger, learnings, domain
# knowledge, Vietnamese with and without diacritics, duplicate basenames)
# scored as Recall@5 and MRR against thresholds, plus citation correctness
# (every hit's path exists), a false-positive probe (absent topics return
# nothing), and forgotten-fact exclusion. Keyless lane on purpose - the BM25
# arm is the floor every home has; embedding arms only improve on it.

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
# query|expected-slug ; one line per case. VN cases cover accented, accent-less
# and mixed; case 9 must beat the duplicate-basename sibling (guard report).
cases() { cat <<'EOF'
harbor sync gate review|data/harbor-sync/room
pane treo khi resize|data/pane-resize/room
pane bị treo khi resize màn hình|data/pane-resize/room
payment processor retry backoff|records/repo-knowledge/payproc
ledger guard refuses scoped edit|data/ledger-guard/room
b2c shop domain charter|crewdomains/b2c-shop/CREWMATE
captain orders public push|records/captain
quy trình nghiệm thu bến cảng|data/harbor-sync/room
acceptance criteria harbor spec|data/harbor-sync/spec/report
worktree lease leaks teardown|records/learnings
shipyard build pipeline caches|records/repo-knowledge/shipyard
queued backlog epic manifests|records/backlog
EOF
}

i=0
while IFS='|' read -r q expect; do
  i=$((i + 1))
  "$BRAIN" recall --query "$q" --home "$AC_HOME" --compact >"$TMP/bench-$i.json" \
    || fail "recall exits 0 on bench query $i"
  printf '%s\n' "$expect" >"$TMP/bench-$i.expect"
done < <(cases)

# --- score: Recall@5 and MRR against thresholds -------------------------------
python3 - "$TMP" "$AC_HOME" <<'EOF' || fail "bench metrics under threshold"
import json, sys, os, glob
tmp, home = sys.argv[1], sys.argv[2]
hits5 = 0; mrr = 0.0; rows = []
files = sorted(glob.glob(os.path.join(tmp, "bench-*.json")),
               key=lambda p: int(p.split("-")[-1].split(".")[0]))
for f in files:
    n = f[:-5]
    expect = open(n + ".expect").read().strip()
    d = json.load(open(f))
    slugs = [r["slug"] for r in d.get("results", [])][:5]
    rank = slugs.index(expect) + 1 if expect in slugs else 0
    if rank: hits5 += 1; mrr += 1.0 / rank
    rows.append((os.path.basename(f), expect, rank))
    # citation correctness: every hit names a real file
    for r in d.get("results", [])[:5]:
        p = r.get("path")
        if p and not os.path.isabs(p): p = os.path.join(home, p)
        if p and not os.path.exists(p):
            print(f"BAD CITATION: {r['slug']} -> {p}"); sys.exit(1)
n = len(files); mrr = mrr / n if n else 0.0
for f, e, rank in rows:
    print(f"  {f}: expect {e} rank {rank if rank else 'MISS'}")
print(f"bench: n={n} recall@5={hits5}/{n} mrr={mrr:.3f}")
# thresholds: the keyless BM25 floor on a home-shaped corpus
sys.exit(0 if n == 12 and hits5 >= 10 and mrr >= 0.55 else 1)
EOF

# --- false positives: an absent topic returns nothing -------------------------
fp="$("$BRAIN" recall --query "kubernetes helm canary rollback" --home "$AC_HOME" --compact)"
assert_contains "$fp" '"total":0' "an absent topic returns zero hits, not confident noise"

# --- forgotten facts stay forgotten -------------------------------------------
rid="$("$BRAIN" remember "the pane resize fix is abandoned for now" --provenance bench --agent bench --entity data/pane-resize/room --home "$AC_HOME" --compact \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')"
"$BRAIN" forget "$rid" --reason bench --home "$AC_HOME" --compact >/dev/null
fq="$("$BRAIN" recall --query "pane resize abandoned" --home "$AC_HOME" --compact)"
case "$fq" in
  *"abandoned for now"*) fail "a forgotten fact resurfaced in recall" ;;
esac

pass
