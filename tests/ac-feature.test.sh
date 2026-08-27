#!/usr/bin/env bash
# ac-feature.test.sh - feature-branch-mech: a LOCAL-until-ship integration
# branch accumulating several crew tasks, published ONCE at ship time as a
# single PR to a captain-recorded target branch. Covers, slice by slice:
#   - the `feature:<name>` arm of the shared row-to-branch resolver
#     (ac_epic_base_for) and the target arm of ac_freshest_ref;
#   - bin/ac-feature.sh record verbs (create cuts LOCALLY at the target's
#     freshest tip and never pushes; verify judges the LOCAL ref; show/retire
#     delegate to the record's own verbs);
#   - the push=deferred arm of the ac-tree.sh get fence and the merge-local
#     landing (local ff, no push, qa deferred to the feature ship gate);
#   - mode:feature-pr in ac-brief/ac-spawn (crewmate contract = local-only
#     shaped, landing target = the feature branch, review defaults no);
#   - ac-feature.sh ship (members terminal, partial receipts, review at the
#     LOCAL tip, target-drift refusal, deferred push + single PR, idempotent).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home

# --- slice 1: the feature: arm of the shared resolver ---------------------------
mkdir -p "$AC_HOME/records"
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
## In flight
- [ ] payux - feature container row (repo: proj)
- [ ] payux-s1 - story; feature:payux (repo: proj)
- [ ] both-s1 - defective row; epic:eppyx feature:payux (repo: proj)
EOF
mkdir -p "$AC_HOME/data/payux" "$AC_HOME/data/eppyx"
printf 'proj feat/payux target=release push=deferred\n' >"$AC_HOME/data/payux/branches"
printf 'proj epic/eppyx\n' >"$AC_HOME/data/eppyx/branches"

entry="$(ac_epic_base_for payux-s1 proj)" \
  || fail "a feature-tokened row must resolve its record through the shared resolver"
assert_eq "$entry" "feat/payux target=release push=deferred" \
  "the feature record entry is returned verbatim"
entry="$(ac_epic_base_for payux proj)" \
  || fail "the container row id resolves its own record (row-id arm)"
assert_eq "${entry%% *}" "feat/payux" "the container id resolves the branch"
entry="$(ac_epic_base_for both-s1 proj)" \
  || fail "a both-token row still resolves (deterministically)"
assert_eq "${entry%% *}" "epic/eppyx" \
  "epic outranks feature when a defective row carries both"

# --- slice 1: ac_freshest_ref takes an explicit branch (the target arm) ---------
up="$(make_repo up1)"
git -C "$up" branch release
clone="$TMP/cl1"
git clone -q "$up" "$clone"
git -C "$clone" config user.email test@test
git -C "$clone" config user.name test
git -C "$clone" fetch -q origin
assert_eq "$(ac_freshest_ref "$clone" release)" "origin/release" \
  "an origin-only target branch resolves to the origin ref"
assert_eq "$(ac_freshest_ref "$up" release)" "release" \
  "a no-origin repo's target resolves locally"
assert_eq "$(ac_freshest_ref "$up")" "main" \
  "the no-branch-argument arm still answers the default branch"

# --- slice 2: bin/ac-feature.sh record verbs -------------------------------------
FT="$BIN/ac-feature.sh"
up2="$(make_repo up2)"
git -C "$up2" branch release
mkdir -p "$AC_HOME/projects"
git clone -q "$up2" "$AC_HOME/projects/proj2"
git -C "$AC_HOME/projects/proj2" config user.email test@test
git -C "$AC_HOME/projects/proj2" config user.name test
mkdir -p "$AC_HOME/data/checkoutux"
printf 'proj2 feat/checkoutux target=release push=deferred\n' >"$AC_HOME/data/checkoutux/branches"

# advance origin's release AFTER the clone: create must fetch and cut at the
# TARGET's freshest tip, not the default's and not a stale mirror
git -C "$up2" checkout -q release
printf 'rel work\n' >>"$up2/file.txt"; git -C "$up2" add -A; git -C "$up2" commit -qm rel
git -C "$up2" checkout -q main
rel_tip="$(git -C "$up2" rev-parse release)"

"$FT" create checkoutux proj2 >/dev/null
assert_eq "$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/checkoutux)" "$rel_tip" \
  "create cuts a LOCAL branch at the TARGET's freshest tip"
if git -C "$up2" show-ref --verify --quiet refs/heads/feat/checkoutux; then
  fail "create must NOT publish the branch (deferred push is the mode)"
fi

# idempotent + never-clobber
git -C "$up2" checkout -q release
printf 'more rel\n' >>"$up2/file.txt"; git -C "$up2" add -A; git -C "$up2" commit -qm rel2
git -C "$up2" checkout -q main
"$FT" create checkoutux proj2 >/dev/null
assert_eq "$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/checkoutux)" "$rel_tip" \
  "a second create never moves the existing branch"

# verify judges the LOCAL ref
"$FT" verify checkoutux proj2 || fail "verify green on the local branch"
git -C "$AC_HOME/projects/proj2" branch -q -D feat/checkoutux
if "$FT" verify checkoutux proj2 2>/dev/null; then
  fail "verify must fail once the LOCAL branch is gone"
fi
"$FT" create checkoutux proj2 >/dev/null

# target defaults to the repo default branch when the key is absent
mkdir -p "$AC_HOME/data/defux"
printf 'proj2 feat/defux push=deferred\n' >"$AC_HOME/data/defux/branches"
"$FT" create defux proj2 >/dev/null
assert_eq "$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/defux)" \
  "$(git -C "$AC_HOME/projects/proj2" rev-parse refs/remotes/origin/main)" \
  "an absent target= key cuts at the default branch's tip"

# an entry without push=deferred is an EPIC-shaped record, not a feature entry
mkdir -p "$AC_HOME/data/notfeat"
printf 'proj2 feat/notfeat target=release\n' >"$AC_HOME/data/notfeat/branches"
out="$("$FT" create notfeat proj2 2>&1 || true)"
assert_contains "$out" "push=deferred" "a non-deferred entry refuses the feature verbs"

# chief-only on the mutating verb; show/retire delegate to the record verbs
out="$(AC_SCOPE=checkoutux "$FT" create checkoutux proj2 2>&1 || true)"
assert_contains "$out" "CREWCHIEF" "a scoped chief cannot create"
out="$("$FT" show checkoutux)"
assert_contains "$out" "proj2 feat/checkoutux target=release push=deferred" \
  "show prints the record verbatim"
"$FT" retire checkoutux >/dev/null
if "$FT" verify checkoutux proj2 2>/dev/null; then
  fail "verify must refuse a retired record"
fi
# un-retire for the later slices (retire prepends one marker line)
sed -i '' '1d' "$AC_HOME/data/checkoutux/branches"

# --- slice 3: the push=deferred fence arm in ac-tree get -------------------------
# proj2 HAS an origin, but a feature branch lives only locally until ship: the
# fence must cut the lease from the LOCAL ref instead of demanding origin.
cat >>"$AC_HOME/records/backlog.md" <<'BEOF'
- [ ] checkoutux-s1 - story; feature:checkoutux (repo: proj2)
- [ ] ghostux-s1 - story; feature:ghostux (repo: proj2)
BEOF
feat_tip="$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/checkoutux)"
wt="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj2" --id checkoutux-s1 --holder t 2>/dev/null)"
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$feat_tip" \
  "a member lease is cut from the LOCAL feature branch (origin never consulted)"

# recorded-but-never-created refuses with the feature remedy, never fall-through
mkdir -p "$AC_HOME/data/ghostux"
printf 'proj2 feat/ghostux push=deferred\n' >"$AC_HOME/data/ghostux/branches"
out="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj2" --id ghostux-s1 --holder t 2>&1 || true)"
assert_contains "$out" "ac-feature.sh create" \
  "a recorded-but-missing feature branch refuses the lease with the feature remedy"

# --- slice 3: the landing - local ff, NO push, qa deferred to the ship gate -----
git -C "$wt" checkout -q -b crew/checkoutux-s1
printf 'member work\n' >"$wt/member.txt"
git -C "$wt" add -A; git -C "$wt" commit -qm "member work"
member_head="$(git -C "$wt" rev-parse HEAD)"
printf 'project_dir=%s\nworktree=%s\n' "$AC_HOME/projects/proj2" "$wt" >"$AC_HOME/state/checkoutux-s1.meta"
out="$("$BIN/ac-merge-local.sh" checkoutux-s1)"
assert_contains "$out" "ref-only" "the feature landing is a ref-only ff"
assert_contains "$out" "feature ship gate" \
  "qa.require_for_ship defers to the feature ship gate on a feature landing"
assert_eq "$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/checkoutux)" "$member_head" \
  "the LOCAL feature branch fast-forwarded to the member head"
if git -C "$up2" show-ref --verify --quiet refs/heads/feat/checkoutux; then
  fail "a feature landing must NOT push (push=deferred, publication happens at ship)"
fi
"$BIN/ac-tree.sh" return "$wt" --force >/dev/null 2>&1

# a missing feature target at land time names the feature remedy
printf 'project_dir=%s\nworktree=%s\n' "$AC_HOME/projects/proj2" "$wt" >"$AC_HOME/state/ghostux-s1.meta"
out="$("$BIN/ac-merge-local.sh" ghostux-s1 2>&1 || true)"
assert_contains "$out" "ac-feature.sh create" \
  "a landing onto a never-created feature branch names the feature remedy"

# --- slice 4: mode feature-pr in ac-brief -----------------------------------------
cat >>"$AC_HOME/records/backlog.md" <<'BEOF'
- [ ] checkoutux-s2 [src:cap flow:direct mode:feature-pr rev:no qa:no] - member two; feature:checkoutux (repo: proj2)
- [ ] loneworks [src:cap flow:direct mode:feature-pr rev:no qa:no] - tokenless feature-pr row (repo: proj2)
BEOF
"$BIN/ac-brief.sh" checkoutux-s2 proj2 >/dev/null
b2="$(cat "$AC_HOME/data/checkoutux-s2/brief.md")"
assert_contains "$b2" "Mode: feature-pr" "the brief records the mode"
assert_contains "$b2" "feat/checkoutux" "the delivery contract names the feature branch"
assert_contains "$b2" "Never push" "a feature-pr crewmate never publishes"
assert_contains "$b2" "Review: no" "feature-pr defaults review=no (the ship gate owns the round)"
out="$("$BIN/ac-brief.sh" loneworks proj2 2>&1 || true)"
assert_contains "$out" "no integration-branch record" \
  "feature-pr with no resolvable record refuses at scaffold time"

# --- slice 5: ac-feature.sh ship - the gated single-PR exit ----------------------
# a fresh feature cut at the CURRENT target tip (no drift), plus one open member
git -C "$AC_HOME/projects/proj2" fetch -q origin
cat >>"$AC_HOME/records/backlog.md" <<'BEOF'
- [ ] shipux - feature container (repo: proj2)
- [ ] shipux-s1 - open member; feature:shipux (repo: proj2)
BEOF
mkdir -p "$AC_HOME/data/shipux"
printf 'proj2 feat/shipux target=release push=deferred\n' >"$AC_HOME/data/shipux/branches"
"$FT" create shipux proj2 >/dev/null

out="$(AC_SCOPE=shipux "$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "CREWCHIEF" "ship is chief-only"
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "non-terminal members: shipux-s1" "an open member refuses the exit and is named"

# members terminal, one abandoned -> the partial receipt gate; an epic-poisoned
# member refuses outright (two integration targets is a ledger defect)
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("- [ ] shipux-s1 - open member; feature:shipux (repo: proj2)",
  "- [x] shipux-s1 - landed member; feature:shipux (repo: proj2)\n- [x] shipux-s2 [abandoned] - died mid-feature; feature:shipux (repo: proj2)\n- [x] shipux-s3 - poisoned member; epic:eppyx feature:shipux (repo: proj2)")
open(p, "w").write(s)
PYEOF
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "shipux-s3" "a member also carrying epic: refuses the exit"
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("\n- [x] shipux-s3 - poisoned member; epic:eppyx feature:shipux (repo: proj2)", "")
open(p, "w").write(s)
PYEOF
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "partial feature" "an abandoned member without a captain receipt refuses"
assert_contains "$out" "shipux-s2" "and names it"
printf -- '- [2026-08-24T12:00:00Z] crewchief> DECIDED: feature-ship partial - shipux-s2 keep (captain word)\n' >>"$AC_HOME/data/shipux/room.md"

# review round at the LOCAL tip: absent -> refuse with the exact command;
# stale ref and open fix findings refuse too
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "no feature review round on record" "a missing review round refuses"
assert_contains "$out" "ac-verify.sh codereview" "and prints the exact round command"
tipf="$(git -C "$AC_HOME/projects/proj2" rev-parse refs/heads/feat/shipux)"
mkdir -p "$AC_HOME/data/shipux/gate"
printf '{"findings":[{"action":"fix","summary":"x"}],"reviewed_ref":"%s"}\n' "$tipf" >"$AC_HOME/data/shipux/gate/review.json"
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "open fix finding" "an open fix finding refuses the exit"
printf '{"findings":[],"reviewed_ref":"%s"}\n' "$tipf" >"$AC_HOME/data/shipux/gate/review.json"

# gates green -> dry-run prints the deferred push and the SINGLE PR to target
out="$("$FT" ship shipux proj2 --dry-run)"
assert_contains "$out" "DRY-RUN: git -C" "the deferred push rides the ship (dry-printed)"
assert_contains "$out" -- "--base release" "the single PR targets the recorded target branch"

# idempotent: this repo's recorded PR is reported, never re-opened
printf 'pr_url_proj2=https://example.test/pr/1\n' >"$AC_HOME/data/shipux/gate/ships.env"
out="$("$FT" ship shipux proj2 --dry-run)"
assert_contains "$out" "already recorded" "a recorded PR is reported, not re-opened"
rm "$AC_HOME/data/shipux/gate/ships.env"

# qa pin on the CONTAINER row gates the tip
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("- [ ] shipux - feature container (repo: proj2)",
              "- [ ] shipux [src:cap flow:direct mode:feature-pr rev:no qa:yes] - feature container (repo: proj2)")
open(p, "w").write(s)
PYEOF
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a qa:yes feature refuses without an attestation at the tip"
mkdir -p "$AC_HOME/projects/proj2/.crew/qa/passed"
: >"$AC_HOME/projects/proj2/.crew/qa/passed/$tipf"
out="$("$FT" ship shipux proj2 --dry-run)"
assert_contains "$out" -- "--base release" "the attestation at the tip satisfies the qa gate"

# --- slice 5: target drift refuses the ship --------------------------------------
# advance checkoutux's target (release) PAST its cut - the ship refuses with
# the rebase advice instead of opening a conflict-bearing PR
git -C "$up2" checkout -q release
printf 'drift\n' >>"$up2/file.txt"; git -C "$up2" add -A; git -C "$up2" commit -qm drift
git -C "$up2" checkout -q main
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("- [ ] checkoutux-s1 - story; feature:checkoutux (repo: proj2)",
              "- [x] checkoutux-s1 - landed; feature:checkoutux (repo: proj2)")
s = s.replace("- [ ] checkoutux-s2 [src:cap flow:direct mode:feature-pr rev:no qa:no] - member two; feature:checkoutux (repo: proj2)",
              "- [x] checkoutux-s2 [src:cap flow:direct mode:feature-pr rev:no qa:no] - member two; feature:checkoutux (repo: proj2)")
open(p, "w").write(s)
PYEOF
out="$("$FT" ship checkoutux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "behind its target" "a drifted feature refuses the ship with the rebase advice"

# --- feature-ship-single-pr-slot (lab-measured defect): the PR record is ONE
# SLOT PER REPO. Repo one's recorded url short-circuited repo two's ship into
# "PR already recorded: <repo ONE's url>" + rc 0 - a silent success that opened
# nothing. The record key is now pr_url_<repo>; a pre-fix bare pr_url= is dead
# legacy the reader ignores (gh itself refuses a duplicate head PR loudly, so
# ignoring it can never silently double-open).
up3="$(make_repo up3)"
git -C "$up3" branch release
git clone -q "$up3" "$AC_HOME/projects/proj3"
git -C "$AC_HOME/projects/proj3" config user.email test@test
git -C "$AC_HOME/projects/proj3" config user.name test
printf 'proj3 feat/shipux target=release push=deferred\n' >>"$AC_HOME/data/shipux/branches"
"$FT" create shipux proj3 >/dev/null
tip3="$(git -C "$AC_HOME/projects/proj3" rev-parse refs/heads/feat/shipux)"
printf '{"findings":[],"reviewed_ref":"%s"}\n' "$tip3" >"$AC_HOME/data/shipux/gate/review.json"
mkdir -p "$AC_HOME/projects/proj3/.crew/qa/passed"
: >"$AC_HOME/projects/proj3/.crew/qa/passed/$tip3"
printf 'pr_url=https://example.test/pr/1\n' >"$AC_HOME/data/shipux/gate/ships.env"
out="$("$FT" ship shipux proj3 --dry-run)"
assert_contains "$out" "gh pr create" \
  "repo two still opens ITS OWN PR past repo one's bare legacy key"
printf 'pr_url_proj3=https://example.test/pr/3\n' >>"$AC_HOME/data/shipux/gate/ships.env"
out="$("$FT" ship shipux proj3 --dry-run)"
assert_contains "$out" "already recorded: https://example.test/pr/3" \
  "the repo's OWN key is what reports already-recorded, with its own url"
printf 'pr_url_proj2=https://example.test/pr/2\n' >"$AC_HOME/data/shipux/gate/ships.env"
out="$("$FT" ship shipux proj3 --dry-run)"
assert_contains "$out" "gh pr create" \
  "a sibling repo's key never records THIS repo's PR"
rm "$AC_HOME/data/shipux/gate/ships.env"
