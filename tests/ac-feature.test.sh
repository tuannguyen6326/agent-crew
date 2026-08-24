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
