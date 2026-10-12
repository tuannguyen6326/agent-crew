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

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
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

# A ledger nobody can read shows no member terminal, so the ship stops at the
# member check instead of moving on to the review gate as if none were open.
# Skipped under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0; out="$("$FT" ship shipux proj2 --dry-run 2>&1)" || rc=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  [ "$rc" != 0 ] || fail "an unreadable ledger must refuse the ship"
  case "$out" in *"no feature review round"* | *DRY-RUN*) fail "an unreadable ledger must stop the ship at the member check, got: $out" ;; esac
fi

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
assert_contains "$out" "--base release" "the single PR targets the recorded target branch"

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
assert_contains "$out" "--base release" "the attestation at the tip satisfies the qa gate"

# A hand edit can leave the ledger without its final newline; the last row is
# still a row, so an open member there holds the ship like any other.
cp "$AC_HOME/records/backlog.md" "$TMP/backlog.keep"
printf -- '- [ ] shipux-s4 - open member, no trailing newline; feature:shipux (repo: proj2)' >>"$AC_HOME/records/backlog.md"
out="$("$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "non-terminal members: shipux-s4" "an open member on an unterminated last line refuses the ship"
mv "$TMP/backlog.keep" "$AC_HOME/records/backlog.md"

# A byte that is not UTF-8 in ledger prose is no row and must not stop the
# ship. The locale is forced: only a UTF-8 ctype makes awk die on a regex
# test against such a line, so under C this would pass on any filter.
cp "$AC_HOME/records/backlog.md" "$TMP/backlog.keep"
printf '> caf\351 reviewed\n' >>"$AC_HOME/records/backlog.md"
out="$(LC_ALL=en_US.UTF-8 "$FT" ship shipux proj2 --dry-run 2>&1 || true)"
assert_contains "$out" "--base release" "a non-UTF-8 byte in ledger prose does not stop the ship"
mv "$TMP/backlog.keep" "$AC_HOME/records/backlog.md"

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
# The key folds every non-alnum to _, so proj-3 and proj_3 share pr_url_proj_3:
# with one's PR recorded, the other read it as its own - "already recorded",
# rc 0, never pushed. A feature recording both is refused at the ship.
cp "$AC_HOME/data/shipux/branches" "$TMP/shipux-branches"
git clone -q "$up3" "$AC_HOME/projects/proj_3"
printf 'proj-3 feat/shipux target=release push=deferred\nproj_3 feat/shipux target=release push=deferred\n' \
  >>"$AC_HOME/data/shipux/branches"
"$FT" create shipux proj_3 >/dev/null
mkdir -p "$AC_HOME/projects/proj_3/.crew/qa/passed"
: >"$AC_HOME/projects/proj_3/.crew/qa/passed/$(git -C "$AC_HOME/projects/proj_3" rev-parse refs/heads/feat/shipux)"
printf 'pr_url_proj_3=https://example.test/pr/dash\n' >"$AC_HOME/data/shipux/gate/ships.env"
rc=0; out="$("$FT" ship shipux proj_3 --dry-run 2>&1)" || rc=$?
case "$out" in *"already recorded"*) fail "a colliding repo must never read a sibling's PR as its own: $out" ;; esac
[ "$rc" != 0 ] || fail "a ships.env key shared by two repos of one feature is refused: $out"
assert_contains "$out" "proj-3" "...naming the repo it collides with"
rm "$AC_HOME/data/shipux/gate/ships.env"
mv "$TMP/shipux-branches" "$AC_HOME/data/shipux/branches"

# The qa pin is read off the container's OWN row. awk's == compared
# numeric-looking ids as numbers, so an earlier row 07 stood in for feature 7
# and its empty contract let the ship skip the qa gate.
cat >>"$AC_HOME/records/backlog.md" <<'BEOF'
- [ ] 07 - an unrelated row that reads as the same number (repo: proj3)
- [ ] 7 [src:cap flow:direct mode:feature-pr rev:no qa:yes] - a numeric feature container (repo: proj3)
BEOF
mkdir -p "$AC_HOME/data/7/gate"
printf 'proj3 feat/7 target=release push=deferred\n' >"$AC_HOME/data/7/branches"
"$FT" create 7 proj3 >/dev/null
printf '{"findings":[],"reviewed_ref":"%s"}\n' "$(git -C "$AC_HOME/projects/proj3" rev-parse refs/heads/feat/7)" \
  >"$AC_HOME/data/7/gate/review.json"
rm -rf "$AC_HOME/projects/proj3/.crew/qa/passed"
out="$("$FT" ship 7 proj3 --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a numeric container's own qa:yes pin gates its ship"
# A TAB may join contract tokens (src/backlog.ts); the gate once matched the
# pin between spaces only, so a TAB before qa:yes skipped it.
perl -pi -e 's/rev:no qa:yes\] - a numeric feature/rev:no\tqa:yes] - a numeric feature/' "$AC_HOME/records/backlog.md"
out="$("$FT" ship 7 proj3 --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a TAB-joined qa:yes pin gates the ship"

# --- differential: src/feature.ts against the frozen bash original -----------
# DISPUTED: the implementation (tests/fixtures/ac-feature.sh under bash vs src/feature.ts through bin/ac-feature.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home whose projects/ clones fetch from bare origins under <side>/remotes, every commit stamped with one fixed date so the shas agree - argv and env (the side root spelled HOME, substituted in values only), cwd (the side root), stdin (/dev/null unless a row feeds a file), LC_ALL=C, a PATH `gh` stub (logs its argv and cwd, prints a url, or refuses on <side>/gh.fail) and a PATH `date` stub (one fixed instant) on both sides; exit status, stdout and stderr (the side root spelled HOME) compared whole, then the world a row may touch: `git for-each-ref` of every clone and origin, every record, data/<f>/gate/* and room bytes (live and archived), and the stub logs.
obin="$(make_oracle_bin ac-feature)"
OH="$TMP/fside-o"; NH="$TMP/fside-n"
FSTUBS="$TMP/fstubs"; mkdir -p "$FSTUBS"
cat >"$FSTUBS/gh" <<'STUB'
#!/bin/sh
printf 'gh %s (cwd %s)\n' "$*" "$(pwd -P)" >>"$GH_LOG"
[ -z "${GH_STDIN:-}" ] || { printf 'stdin: '; cat; } >>"$GH_LOG"
[ ! -e "$GH_FAIL" ] || { printf 'gh: the stub refuses\n' >&2; exit 1; }
printf '%s\n\n' "${GH_URL:-https://example.test/pr/1}"
STUB
cat >"$FSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in *%s*) echo 1767225600 ;; *) echo 2026-01-01T00:00:00Z ;; esac
STUB
chmod +x "$FSTUBS/gh" "$FSTUBS/date"
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
fseed() { mkdir -p "$H/home/projects" "$H/home/records" "$H/home/data" "$H/remotes"; }
mkrepo() {  # mkrepo <dir> - main with one fixed-date commit, release beside it
  git init -q -b main "$1"
  git -C "$1" config user.email test@test; git -C "$1" config user.name test
  printf 'base\n' >"$1/f.txt"; git -C "$1" add -A; gitc -C "$1" commit -qm base
  git -C "$1" branch release
}
origin_repo() {  # origin_repo <name> - bare remotes/<name>.git fed from src-<name>, cloned to projects/<name>
  mkrepo "$H/src-$1"
  git clone -q --bare "$H/src-$1" "$H/remotes/$1.git"
  git clone -q "$H/remotes/$1.git" "$H/home/projects/$1"
  git -C "$H/home/projects/$1" config user.email test@test; git -C "$H/home/projects/$1" config user.name test
}
local_repo() { mkrepo "$H/home/projects/$1"; }
advance() {  # advance <name> <branch> - one more fixed-date commit on the origin's <branch>
  git -C "$H/src-$1" checkout -q "$2"
  printf '%s\n' "$2" >>"$H/src-$1/f.txt"; git -C "$H/src-$1" add -A; gitc -C "$H/src-$1" commit -qm "$2"
  git -C "$H/src-$1" push -q "$H/remotes/$1.git" "$2:$2"; git -C "$H/src-$1" checkout -q main
}
commit_on() {  # commit_on <repo> <branch> <msg> - one fixed-date commit on a local branch of a clone
  local p="$H/home/projects/$1"
  git -C "$p" checkout -q "$2"; printf '%s\n' "$3" >>"$p/f.txt"; git -C "$p" add -A; gitc -C "$p" commit -qm "$3"
  git -C "$p" checkout -q --detach
}
rec() { mkdir -p "$H/home/data/$1"; printf -- "$2" >"$H/home/data/$1/branches"; }
led() { printf -- "$1" >"$H/home/records/backlog.md"; }
room() { mkdir -p "$H/home/data/$1"; printf -- "$2" >"$H/home/data/$1/room.md"; }
cut_at() { git -C "$H/home/projects/$1" branch -q "$2" "$3"; }  # cut_at <repo> <branch> <start> - a feature branch cut by hand
review() {  # review <feature> <repo> [<json with TIP for the branch tip>] - the gate's review record
  local tip j="${3-}"
  tip="$(git -C "$H/home/projects/$2" rev-parse "refs/heads/feat/$1")"
  [ -n "$j" ] || j='{"findings":[],"reviewed_ref":"TIP"}'
  mkdir -p "$H/home/data/$1/gate"
  printf '%s\n' "${j//TIP/$tip}" >"$H/home/data/$1/gate/review.json"
}
ships() { mkdir -p "$H/home/data/$1/gate"; printf -- "$2" >"$H/home/data/$1/gate/ships.env"; }
HOMELESS=0
FT_ENV=()
FT_PATH=""
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root; cwd is the root
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C "PATH=${FT_PATH:-$FSTUBS:$PATH}" "GH_LOG=$h/gh.log" "GH_FAIL=$h/gh.fail")
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${FT_ENV[@]+"${FT_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h" && env -u AC_HOME "${e[@]}" "$bin/ac-feature.sh" ${a[@]+"${a[@]}"}) <"${FT_STDIN:-/dev/null}" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$2#HOME#g" "$1"; }
O_RC=0; N_RC=0
pair() {  # pair <args...> - both sides run, outputs normalised, nothing compared yet
  O_RC=0; N_RC=0
  run_side "$obin" "$OH" o "$@" || O_RC=$?
  run_side "$BIN" "$NH" n "$@" || N_RC=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
}
same_io() {
  assert_eq "$N_RC" "$O_RC" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
}
world() {  # world <side root> - what a row may change
  local h="$1" r f
  for r in "$h"/home/projects/* "$h"/remotes/*.git; do
    [ -d "$r" ] || continue
    printf '== %s\n' "$r"; git -C "$r" for-each-ref 2>/dev/null || printf 'no repo\n'
  done
  for f in "$h"/home/data/*/branches "$h"/home/data/*/room.md "$h"/home/data/*/gate/* \
    "$h"/home/data/archive/*/*/branches "$h"/home/data/archive/*/*/room.md "$h"/gh.log "$h"/push-stdin.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; cat "$f"; printf '\n'
  done
}
same_world() {
  world "$OH" >"$TMP/o.world"; world "$NH" >"$TMP/n.world"
  norm "$TMP/o.world" "$OH" >"$TMP/o.world2"; norm "$TMP/n.world" "$NH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "differential world differs after '$*': $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 8)"
}
same() { pair "$@"; same_io "$@"; same_world "$@"; }
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
oracle_err() { cat "$TMP/o.err2"; }
FUSAGE='ERROR: usage: ac-feature.sh create|verify <feature> <repo> | show|retire <feature> | ship <feature> <repo> [--dry-run]'
FNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
fence() { printf "ERROR: %s is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=x) - the feature branch is cut and shipped on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it" "$1"; }
noentry() { printf "ERROR: %s: no record entry for %s under feature %s - write data/%s/branches first (the captain's word, receipted DECIDED: to the room): '<repo> <branch> [target=<branch>] push=deferred'" "$1" "$3" "$2" "$2"; }
both fseed
both origin_repo p
both local_repo loc

# 1. arity before anything else, exit 1: no verb, an unknown or empty verb,
#    a wrong count for each verb, `--dry-run` misspelt or followed by more
#    (as $3 it is a repo name)
same
assert_eq "$(shim_err)" "$FUSAGE" "1: no verb"
for args in "bogus" "" ; do same "$args"; assert_eq "$(shim_err)" "$FUSAGE" "1: verb '$args'"; done
same create f; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh create <feature> <repo>" "1: create f"
same create f r x; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh create <feature> <repo>" "1: create f r x"
same verify f r x; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh verify <feature> <repo>" "1: verify f r x"
same show f r; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh show <feature>" "1: show f r"
same retire; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh retire <feature>" "1: retire"
for args in "ship f" "ship f r --dry-run x" "ship f r --dryrun"; do
  # shellcheck disable=SC2086
  same $args; assert_eq "$(shim_err)" "ERROR: usage: ac-feature.sh ship <feature> <repo> [--dry-run]" "1: $args"
  assert_eq "$N_RC" 1 "1: $args exits 1"
done
same ship f --dry-run
assert_eq "$(shim_err)" "$(noentry ship f --dry-run)" "1: --dry-run as \$3 is the repo"

# 2. homeless: show/retire answer src/epic-branch.ts's one refusal on both
#    sides; create/verify/ship are W6 - NAMED: the original printed the
#    refusal twice (the swallowed `$(ac_data_dir)` of the live rung, then the
#    archive glob) and then the no-entry remedy, the port refuses once; exit 1
HOMELESS=1
same show f; assert_eq "$(shim_err)" "$FNOHOME" "2: homeless show"
same retire f; assert_eq "$(shim_err)" "$FNOHOME" "2: homeless retire"
for verb in create verify ship; do
  pair "$verb" f p
  assert_eq "$O_RC $N_RC" "1 1" "2: homeless $verb exits 1 on both sides"
  assert_eq "$(cat "$TMP/o.out" "$TMP/n.out")" "" "2: homeless $verb prints nothing on stdout"
  assert_eq "$(oracle_err)" "$FNOHOME
$FNOHOME
$(noentry "$verb" f p)" "2: W6 - the original's three lines for $verb"
  assert_eq "$(shim_err)" "$FNOHOME" "2: W6 named - the port refuses once for $verb"
  same_world "homeless $verb"
done
#    ...and an AC_HOME cd cannot enter: the original printed cd's own line
#    twice and the remedy, the port names the variable once (W6, the HOME
#    RESOLUTION ruling)
FT_ENV=(AC_HOME=HOME/missing)
pair create f p
assert_eq "$O_RC $N_RC" "1 1" "2: an unenterable home exits 1 on both sides"
assert_contains "$(oracle_err)" "HOME/missing: No such file or directory" "2: cd's own line on the original"
assert_eq "$(tail -n 1 "$TMP/o.err2")" "$(noentry create f p)" "2: then the remedy"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: HOME/missing" "2: W6 named - the port names the variable once"
FT_ENV=()
HOMELESS=0

# 3. the fence: AC_SCOPE refuses create and ship before anything is read -
#    homeless too; verify is no mutation and passes the fence
FT_ENV=(AC_SCOPE=x)
same create f p; assert_eq "$(shim_err)" "$(fence create)" "3: scoped create"
same ship f p --dry-run; assert_eq "$(shim_err)" "$(fence ship)" "3: scoped ship"
HOMELESS=1
same create f p; assert_eq "$(shim_err)" "$(fence create)" "3: the fence precedes the home"
same ship f p; assert_eq "$(shim_err)" "$(fence ship)" "3: the fence precedes the home on ship"
HOMELESS=0
same verify f p; assert_eq "$(shim_err)" "$(noentry verify f p)" "3: verify carries no fence"
FT_ENV=()

# 4. record shapes, through create on the no-origin repo: none; retired on
#    its FIRST line only; no entry for the repo; no push=deferred (the branch
#    itself named push=deferred is no key); an EMPTY target= defaults (W4);
#    TAB-separated fields; the first of two entries for one repo; the first
#    of two target= keys; a numeric repo matching awk's `==` (`07` reads the
#    `7` entry); an archived record
same create nof loc; assert_eq "$(shim_err)" "$(noentry create nof loc)" "4: no record"
seed4() {
  rec ret '# retired 2026-01-01T00:00:00Z\nloc feat/ret push=deferred\n'
  rec ret2 'loc feat/ret2 push=deferred\n# retired 2026-01-01T00:00:00Z\n'
  rec noent 'other feat/noent push=deferred\n'
  rec epicish 'loc epic/x push=yes\n'
  rec pdname 'loc push=deferred\n'
  rec tgt 'loc feat/tgt target= push=deferred\n'
  rec tab 'loc\tfeat/tab\ttarget=release\t push=deferred\n'
  rec two 'loc feat/two1 push=deferred\nloc feat/two2 target=release push=deferred\n'
  rec tt 'loc feat/tt target=release target=nowhere push=deferred\n'
  rec num '7 feat/num push=deferred\n'
  local_repo 07
  mkdir -p "$H/home/data/archive/2026/arc"; printf 'loc feat/arc push=deferred\n' >"$H/home/data/archive/2026/arc/branches"
}
both seed4
for verb in create verify ship; do
  same "$verb" ret loc
  assert_eq "$(shim_err)" "ERROR: $verb: the ret record is retired (# retired 2026-01-01T00:00:00Z) - a retired feature has no integration branch; re-record on the captain's word if the feature truly reopens" "4: retired ($verb)"
done
same create ret2 loc; assert_eq "$(shim_out)" "created: feat/ret2 in loc at the tip of main (LOCAL - deferred push)" "4: a marker on line 2 retires nothing"
same create noent loc; assert_eq "$(shim_err)" "$(noentry create noent loc)" "4: no entry for the repo"
same create epicish loc
assert_eq "$(shim_err)" "ERROR: create: the epicish entry for loc carries no push=deferred key - that is an epic-shaped record, not a feature entry; a FEATURE branch stays local until ship (add push=deferred on the captain's word, or use ac-epic-branch.sh for an epic record)" "4: an epic-shaped entry"
same verify pdname loc; assert_contains "$(shim_err)" "carries no push=deferred key" "4: a branch NAMED push=deferred is no key"
same create tgt loc; assert_eq "$(shim_out)" "created: feat/tgt in loc at the tip of main (LOCAL - deferred push)" "4: W4 - an empty target= silently defaults"
same create tab loc; assert_eq "$(shim_out)" "created: feat/tab in loc at the tip of release (LOCAL - deferred push)" "4: TAB-separated fields"
same create two loc; assert_eq "$(shim_out)" "created: feat/two1 in loc at the tip of main (LOCAL - deferred push)" "4: the first entry wins"
same create tt loc; assert_eq "$(shim_out)" "created: feat/tt in loc at the tip of release (LOCAL - deferred push)" "4: the first target= wins"
same create num 07; assert_eq "$(shim_out)" "created: feat/num in 07 at the tip of main (LOCAL - deferred push)" "4: awk's numeric == - repo 07 reads the 7 entry"
same create arc loc; assert_eq "$(shim_out)" "created: feat/arc in loc at the tip of main (LOCAL - deferred push)" "4: an archived record"

# 5. the clone: projects/<repo> needs .git as a directory or a FILE (a linked
#    worktree); the refusal carries no verb prefix
seed5() {
  rec nc 'ghost feat/nc push=deferred\nplain feat/nc push=deferred\nwt feat/nc push=deferred\n'
  mkdir -p "$H/home/projects/plain"
  git -C "$H/home/projects/loc" worktree add -q "$H/home/projects/wt" -b wtb
}
both seed5
same create nc ghost; assert_eq "$(shim_err)" "ERROR: no project clone at projects/ghost" "5: no clone"
same ship nc plain --dry-run; assert_eq "$(shim_err)" "ERROR: no project clone at projects/plain" "5: a directory without .git"
same create nc wt; assert_eq "$(shim_out)" "created: feat/nc in wt at the tip of main (LOCAL - deferred push)" "5: a .git FILE is a clone"

# 6. create on an origin repo: fetch first, so the cut is at origin's
#    ADVANCED target; git's own tracking line rides stdout first (W7); never
#    pushed (the world compares the origin's refs); idempotent; a target that
#    resolves nowhere; an origin the fetch cannot reach (git's lines, then the
#    refusal)
seed6() {
  advance p release
  rec fa 'p feat/fa target=release push=deferred\n'
  rec tn 'loc feat/tn target=nowhere push=deferred\n'
  origin_repo dead; git -C "$H/home/projects/dead" remote set-url origin "$H/remotes/missing.git"
  rec dd 'dead feat/dd push=deferred\n'
}
both seed6
same create fa p
assert_eq "$(shim_out)" "branch 'feat/fa' set up to track 'origin/release'.
created: feat/fa in p at the tip of release (LOCAL - deferred push)" "6: W7 - git's tracking line, then the cut"
assert_eq "$(git -C "$NH/home/projects/p" rev-parse feat/fa)" "$(git -C "$NH/remotes/p.git" rev-parse release)" "6: the cut is at origin's advanced target"
same create fa p; assert_eq "$(shim_out)" "exists: feat/fa in p (left untouched)" "6: idempotent"
same create tn loc
assert_eq "$(shim_err)" "ERROR: create: target branch nowhere resolves nowhere in loc - the record names a target that does not exist" "6: a target nowhere"
same create dd dead
assert_contains "$(shim_err)" "ERROR: create: fetch origin failed for dead - the branch must be cut at the target's real tip, not a stale mirror" "6: an unreachable origin"
assert_contains "$(shim_err)" "HOME/remotes/missing.git" "6: git's own lines precede the refusal"

# 7. verify: silent and 0 on the local branch (scoped too); the branch absent
same verify fa p; assert_eq "$N_RC:$(shim_out)$(shim_err)" "0:" "7: verify is quiet"
FT_ENV=(AC_SCOPE=x); same verify fa p; FT_ENV=()
assert_eq "$N_RC" 0 "7: scoped verify passes"
same verify dd dead
assert_eq "$(shim_err)" "ERROR: verify: feat/dd does not exist locally in dead - a feature branch lives LOCALLY until ship; create it (ac-feature.sh create dd dead) before any member spawns against it" "7: the branch absent"

# 8. show/retire are src/epic-branch.ts's bytes and status on both sides:
#    show live and archived, show nothing, retire (the stamp from the date
#    stub) then verify refuses the retired record, retire again, scoped retire
same show fa; assert_eq "$(shim_out)" "# HOME/home/data/fa/branches
p feat/fa target=release push=deferred" "8: show"
same show arc; assert_contains "$(shim_out)" "# HOME/home/data/archive/2026/arc/branches" "8: show an archived record"
same show nosuch; assert_contains "$(shim_err)" "ERROR: show: no branches record for epic nosuch" "8: show nothing"
same retire tgt; assert_eq "$(shim_out)" "retired: epic tgt record at HOME/home/data/tgt/branches" "8: retire"
same verify tgt loc; assert_contains "$(shim_err)" "(# retired 2026-01-01T00:00:00Z)" "8: verify after retire"
same retire tgt; assert_eq "$(shim_out)" "already retired: # retired 2026-01-01T00:00:00Z" "8: retire twice"
FT_ENV=(AC_SCOPE=x); same retire two; FT_ENV=()
assert_contains "$(shim_err)" "retire is the CREWCHIEF's verb" "8: the delegate's own fence"
# The delegate gets this process's environment BYTES: a value holding a byte
# that is not UTF-8 reaches the retire stamp's date child unchanged on both
# sides (a BUN_ name is dropped there, as ac-bun.sh dropped it)
ENVSTUB="$TMP/fenvstub"; mkdir -p "$ENVSTUB"
printf '#!/bin/sh\nprintf "%%s" "$FT_PROBE" | od -An -tx1 | tr -d " \\n" >>"$FT_PROBE_LOG"; printf " bun=[${BUN_FT_PROBE-unset}]\\n" >>"$FT_PROBE_LOG"\nexec %s "$@"\n' "$FSTUBS/date" >"$ENVSTUB/date"; chmod +x "$ENVSTUB/date"
seed8e() { rec env8 'loc feat/e8 push=deferred\n'; }
both seed8e
FT_PATH="$ENVSTUB:$FSTUBS:$PATH"; FT_ENV=("FT_PROBE=$(printf 'a\351b')" "FT_PROBE_LOG=HOME/probe.log" "BUN_FT_PROBE=1")
same retire env8
FT_PATH=""; FT_ENV=()
assert_eq "$(cat "$NH/probe.log")" "$(cat "$OH/probe.log")" "8: the delegate's date child saw the same environment bytes on both sides"
assert_eq "$(cat "$NH/probe.log")" "61e962 bun=[unset]" "8: the byte intact, the BUN_ name dropped"

# 9. ship's member gate, in ledger order: a missing ledger and an unreadable
#    one are W1 - NAMED: awk's own `can't open file` lines are not reproduced,
#    exit 2 is (the binding's `backlog parser failed` line never prints there:
#    awk opens the file before the binding runs); an open member; `- [X]` is
#    no checkbox (W14 - the parser reads its id as `-`); an epic-poisoned
#    member refuses at once, ahead of the open ones; members whose feature
#    differs in case or sits past a NUL are no members; partial members need a
#    receipt ending in a space after the id (W8), the room read through
#    roomFile (live, then archived); the receipt grep is a BRE over the id
#    (W15 - `fa.s9` finds `faXs9`'s receipt); an unterminated last line is a
#    row; a byte that is not UTF-8 in prose is one more byte, also under
#    UTF-8
w1() {
  pair ship fa p --dry-run
  [ ! -f "$OH/home/records/backlog.md" ] || chmod 644 "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
  assert_eq "$O_RC $N_RC" "2 2" "9: W1 $1 - exit 2 on both sides"
  assert_eq "$(cat "$TMP/o.out" "$TMP/n.out")" "" "9: W1 $1 - nothing on stdout"
  assert_contains "$(oracle_err)" "awk: can't open file HOME/home/records/backlog.md" "9: W1 $1 - awk's own line on the original"
  assert_eq "$(shim_err)" "" "9: W1 $1 named - not reproduced"
}
rm -f "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
w1 "missing"
same_world "a missing ledger"
both led '- [ ] fa - container\n'
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
  w1 "unreadable"
  same_world "an unreadable ledger"
fi
#    ...while a ledger that is a DIRECTORY holds no record, as awk read it,
#    so no member and no container: the ship goes on
rm -f "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
mkdir "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
same ship fa p --dry-run
assert_contains "$(shim_err)" "ERROR: no feature review round on record" "9: a directory ledger reads empty"
rmdir "$OH/home/records/backlog.md" "$NH/home/records/backlog.md"
both led '- [ ] fa - container\n- [ ] fa-s1 - open; feature:fa\n- [X] fa-s2 - capital X; feature:fa\n- [x] fa-s0 - landed; feature:fa\n'
same ship fa p --dry-run
assert_eq "$(shim_err)" "ERROR: feature fa has non-terminal members: fa-s1 - - every member lands (or is failed/abandoned by the captain) before the feature ships" "9: open members, W14 named -"
both led '- [ ] fa-s1 - open; feature:fa\n- [x] fa-s3 [failed] - poisoned; epic:e1 feature:fa\n'
same ship fa p --dry-run
assert_eq "$(shim_err)" "ERROR: member fa-s3 carries epic:e1 BESIDE feature:fa - two integration targets on one row is a ledger defect; fix the row before the exit" "9: the poisoned member wins"
both led '## Done\n- [x] fa-s4 [failed] - x; feature:fa\n- [x] fa-s5 [abandoned] - y; feature:fa\n- [ ] fa-s7 - case; feature:FA\n- [ ] fa-s8 - prose\0 feature:fa\n- [ ] fa [src:cap] - the container is no member\n'
same ship fa p --dry-run
assert_eq "$(shim_err)" "ERROR: partial feature: [failed]/[abandoned] members need a captain revert-or-keep receipt in the room - fa-s4 fa-s5 - post the GATE:/ASK:, record the captain's answer as 'DECIDED: feature-ship partial - <id> revert|keep <words>', then re-run" "9: partials without a room"
both room fa '# Room: fa\n\n- [2026-01-01T00:00:00Z] crewchief> DECIDED: feature-ship partial - fa-s4 keep (captain word)\n- [2026-01-01T00:00:00Z] crewchief> DECIDED: feature-ship partial - fa-s5\n'
same ship fa p --dry-run
assert_contains "$(shim_err)" "in the room - fa-s5 - post" "9: W8 - a receipt ending at the id does not count"
arch_room() { mkdir -p "$H/home/data/archive/2026/fa"; printf -- '- [x] crewchief> DECIDED: feature-ship partial - fa-s4 keep\n- [x] crewchief> DECIDED: feature-ship partial - fa-s5 revert\n' >"$H/home/data/archive/2026/fa/room.md"; rm "$H/home/data/fa/room.md"; }
both arch_room
same ship fa p --dry-run
assert_contains "$(shim_err)" "ERROR: no feature review round on record" "9: the receipts in the archived room pass the gate"
both led '- [x] fa.s9 [failed] - a dot; feature:fa\n'
both room fa '- [x] crewchief> DECIDED: feature-ship partial - faXs9 keep\n'
same ship fa p --dry-run
assert_contains "$(shim_err)" "ERROR: no feature review round on record" "9: W15 - the BRE dot matches X"
both led '- [x] fa-s0 - landed; feature:fa\n- [ ] fa-s6 - open, unterminated; feature:fa'
same ship fa p --dry-run
assert_contains "$(shim_err)" "non-terminal members: fa-s6 -" "9: an unterminated last line is a row"
both led '- [x] fa-s0 - landed; feature:fa\n> caf\351 reviewed\n'
FT_ENV=(LC_ALL=en_US.UTF-8); same ship fa p --dry-run; FT_ENV=()
assert_contains "$(shim_err)" "ERROR: no feature review round on record" "9: a byte that is not UTF-8 does not stop the walk under UTF-8"
#    W16 - REPRODUCED: `for p in $partials` is unquoted, so a member id
#    holding a glob character is expanded against the caller's cwd by bash
#    itself - `fa*` is the side root's `fab fac` on both sides; a port bash
#    that dies there ends the run (143) and reaches no shipping command
both led '- [x] fa* [abandoned] - a glob; feature:fa\n'
touch "$OH/fab" "$OH/fac" "$NH/fab" "$NH/fac"
same ship fa p --dry-run
assert_eq "$N_RC" 1 "9: W16 - the expanded ids refuse"
assert_contains "$(shim_err)" "in the room - fab fac - post" "9: W16 - the cwd's files stand in for the pattern"
mkdir -p "$TMP/killbash"
printf '#!/bin/sh\ncase "$1" in -c) kill -TERM $$ ;; esac\nexec /bin/bash "$@"\n' >"$TMP/killbash/bash"; chmod +x "$TMP/killbash/bash"
FT_PATH="$TMP/killbash:$FSTUBS:$PATH"; pair ship fa p --dry-run; FT_PATH=""
assert_eq "$N_RC" 143 "9: W16 - a dying expansion bash ends the port's run"
case "$(cat "$TMP/n.out")" in *DRY-RUN*) fail "9: a dying expansion bash must reach no shipping command" ;; esac
rm -f "$OH/fab" "$OH/fac" "$NH/fab" "$NH/fac"
both led '- [ ] fa - container\n- [x] fa-s0 - landed; feature:fa\n'

# 10. drift, against the target's FRESHEST tip: behind origin's advanced
#     target; behind a local target that is ahead of origin; ahead (passes on
#     to the review gate); a target nowhere is git's own 128 at the rev-parse
seed10() {
  origin_repo pd; rec fd 'pd feat/fd target=release push=deferred\n'
  cut_at pd feat/fd origin/release; advance pd release
  rec tnw 'loc feat/tnw target=nowhere push=deferred\n'; cut_at loc feat/tnw main
}
both seed10
same ship fd pd --dry-run
assert_eq "$(shim_err)" "ERROR: feature feat/fd is behind its target release - rebase the branch onto release in a LEASED worktree on the captain's word (never the primary checkout, never automatic), re-run the review round at the new tip, then re-run the ship" "10: behind origin"
seed10b() { local p="$H/home/projects/pd"; git -C "$p" branch -q -f feat/fd origin/release; git -C "$p" branch -q release origin/release; commit_on pd release local-ahead; }
both seed10b
same ship fd pd --dry-run; assert_contains "$(shim_err)" "is behind its target release" "10: behind a local target ahead of origin"
seed10c() { git -C "$H/home/projects/pd" branch -q -f feat/fd release; commit_on pd feat/fd feature-work; }
both seed10c
same ship fd pd --dry-run; assert_contains "$(shim_err)" "no feature review round on record" "10: ahead passes"
same ship tnw loc --dry-run
assert_eq "$N_RC" 128 "10: a target nowhere is git's 128"
assert_contains "$(shim_err)" "fatal: ambiguous argument 'nowhere'" "10: git's own line"

# 11. the review record at the local tip: absent (the command printed whole);
#     a directory is absent; a stale ref; a numeric ref (jq's -r spelling);
#     false and null read as none (W3); unparseable reads as none; unreadable
#     reads as none; two fixes; a findings element jq cannot index is `ERR`
#     and a second JSON value after a clean one is `0<LF>ERR` (W2); findings
#     that are no array count 0 and pass on
FTIP="$(git -C "$NH/home/projects/p" rev-parse feat/fa)"
FBASE="$(git -C "$NH/home/projects/p" merge-base feat/fa origin/release)"
FCMD="bin/ac-verify.sh codereview --repo HOME/home/projects/p --ref $FTIP --family fa --caller <your AC_CREW_ID> --base $FBASE --intent HOME/home/data/fa/room.md --output HOME/home/data/fa/gate/review.json"
same ship fa p --dry-run
assert_eq "$(shim_err)" "ERROR: no feature review round on record - run ONE independent round over the whole integration diff first: $FCMD" "11: no review"
mkdir -p "$OH/home/data/fa/gate/review.json" "$NH/home/data/fa/gate/review.json"
same ship fa p --dry-run; assert_contains "$(shim_err)" "no feature review round on record" "11: a directory is no record"
rmdir "$OH/home/data/fa/gate/review.json" "$NH/home/data/fa/gate/review.json"
ref_row() {  # ref_row <json> <the ref as printed>
  both review fa p "$1"
  same ship fa p --dry-run
  assert_eq "$(shim_err)" "ERROR: the recorded review round is for ref $2, not the current tip $FTIP - the tip moved, run a fresh round: $FCMD" "11: reviewed_ref $1"
}
ref_row '{"reviewed_ref":"deadbeef"}' deadbeef
ref_row '{"reviewed_ref":12}' 12
ref_row '{"reviewed_ref":false}' '<none>'
ref_row '{"reviewed_ref":null}' '<none>'
ref_row 'not json' '<none>'
ref_row '{"reviewed_ref":"TIP"} {"reviewed_ref":"x"}' "$FTIP
x"
if [ "$(id -u)" != 0 ]; then
  both review fa p
  chmod 000 "$OH/home/data/fa/gate/review.json" "$NH/home/data/fa/gate/review.json"
  pair ship fa p --dry-run
  chmod 644 "$OH/home/data/fa/gate/review.json" "$NH/home/data/fa/gate/review.json"
  same_io "unreadable review"
  assert_contains "$(shim_err)" "for ref <none>" "11: an unreadable record reads as none"
fi
fix_row() {  # fix_row <json> <n as printed>
  both review fa p "$1"
  same ship fa p --dry-run
  assert_eq "$(shim_err)" "ERROR: the feature review round left $2 open fix finding(s) - fix on the feature branch (the ref change invalidates the round) and run a fresh round: $FCMD" "11: findings $1"
}
fix_row '{"reviewed_ref":"TIP","findings":[{"action":"fix"},{"action":"keep"},{"action":"fix"}]}' 2
fix_row '{"reviewed_ref":"TIP","findings":["x"]}' ERR
fix_row '{"reviewed_ref":"TIP","findings":[]} garbage' "0
ERR"
both review fa p '{"reviewed_ref":"TIP","findings":"x"}'
same ship fa p --dry-run; assert_contains "$(shim_out)" "DRY-RUN: git -C" "11: findings that are no array count 0"
both review fa p

# 12. qa, when the container's OWN row pins qa:yes: the attestation is a
#     PREFIX glob (W10 - `<tip>junk` counts) handed to ls, so a match ls
#     cannot list (an unreadable directory) refuses; a TAB-joined pin gates;
#     the container is found by string equality (feature 7 reads its own row,
#     not 07's)
QAREF="ERROR: the container row pins qa:yes and no crew-qa pass attestation exists for the tip $FTIP - run one behavioral round against the BUILT feature branch (crew-qa skill / bin/ac-qa.sh agent --target $FTIP ...)"
both led '- [ ] fa [src:cap flow:direct mode:feature-pr rev:no qa:yes] - container\n- [x] fa-s0 - landed; feature:fa\n'
same ship fa p --dry-run; assert_eq "$(shim_err)" "$QAREF" "12: no attestation"
qa_row() {  # qa_row <name under passed/> <file|dir|dir000> <want: pass|refuse>
  mkdir -p "$OH/home/projects/p/.crew/qa/passed" "$NH/home/projects/p/.crew/qa/passed"
  local h; for h in "$OH" "$NH"; do
    case "$2" in file) : >"$h/home/projects/p/.crew/qa/passed/$1" ;; *) mkdir -p "$h/home/projects/p/.crew/qa/passed/$1" ;; esac
    [ "$2" != dir000 ] || chmod 000 "$h/home/projects/p/.crew/qa/passed/$1"
  done
  pair ship fa p --dry-run
  chmod -R 755 "$OH/home/projects/p/.crew" "$NH/home/projects/p/.crew"
  same_io "qa $1"
  case "$3" in pass) assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "12: qa $1 passes" ;; *) assert_eq "$(shim_err)" "$QAREF" "12: qa $1 refuses" ;; esac
  rm -rf "$OH/home/projects/p/.crew" "$NH/home/projects/p/.crew"
}
qa_row "$FTIP" file pass
qa_row "$FTIP.scope.app" file pass
qa_row "${FTIP}junk" file pass
qa_row "${FTIP%?}" file refuse
qa_row "$FTIP.d" dir pass
[ "$(id -u)" = 0 ] || qa_row "$FTIP.d" dir000 refuse
both led '- [ ] fa [src:cap flow:direct mode:feature-pr rev:no\tqa:yes] - container\n- [x] fa-s0 - landed; feature:fa\n'
same ship fa p --dry-run; assert_eq "$(shim_err)" "$QAREF" "12: a TAB-joined pin"
seed12() {
  rec 7 'p feat/7 target=release push=deferred\n'; cut_at p feat/7 feat/fa; review 7 p
  rec 07 'p feat/07 target=release push=deferred\n'; cut_at p feat/07 feat/fa; review 07 p
  led '- [ ] 07 [src:cap qa:no] - an earlier row reading as the same number\n- [ ] 7 [src:cap qa:yes] - the numeric container\n'
}
both seed12
same ship 7 p --dry-run; assert_contains "$(shim_err)" "no crew-qa pass attestation" "12: feature 7 reads its own row"
same ship 07 p --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create --base release --head feat/07" "12: feature 07 reads its own row"
both led '- [ ] fa - container\n- [x] fa-s0 - landed; feature:fa\n'

# 13. the exit's preconditions: no origin; the per-repo ships.env slot (own
#     key, LAST wins, an empty last value is none, a sibling's key and the
#     bare legacy key are not this repo's, an unreadable file reads none, a
#     CR is kept, a NUL in a key line cuts it to the bare key - W17, awk's
#     record); a record whose two repos fold to one key (an indented line
#     counts, a comment does not, an unterminated last line does - grep
#     terminated it); a repo name of bytes folded per BYTE (W5: the oracle
#     runs under C - `\303\251` keys pr_url___)
seed13() {
  rec lo 'loc feat/lo push=deferred\n'; cut_at loc feat/lo main; review lo loc
  origin_repo my-app; cut_at my-app feat/mx origin/main; review mx my-app
  rec mx 'my-app feat/mx push=deferred\nmy_app feat/mx push=deferred\n'
  origin_repo "$(printf '\303\251')"; cut_at "$(printf '\303\251')" feat/fe origin/main; review fe "$(printf '\303\251')"
  rec fe "$(printf '\303\251') feat/fe push=deferred\n"; ships fe 'pr_url___=https://example.test/pr/e\n'
}
both seed13
same ship lo loc --dry-run
assert_eq "$(shim_err)" "ERROR: feature-ship needs an origin remote on loc - a local-only repo has no PR to open (land it by captain merge instead)" "13: no origin"
DRY="DRY-RUN: git -C HOME/home/projects/p push origin refs/heads/feat/fa:refs/heads/feat/fa
DRY-RUN: gh pr create --base release --head feat/fa --title \"feature(fa): feat/fa -> release\" (in HOME/home/projects/p)"
slot_row() {  # slot_row <ships.env bytes> <stdout>
  both ships fa "$1"
  same ship fa p --dry-run
  assert_eq "$(shim_out)" "$2" "13: ships.env '$1'"
}
slot_row 'pr_url_p=https://example.test/pr/1\n' "PR already recorded: https://example.test/pr/1"
slot_row 'pr_url_p=https://a\npr_url_p=https://b\n' "PR already recorded: https://b"
slot_row 'pr_url_p=https://a\npr_url_p=\n' "$DRY"
slot_row 'pr_url_q=https://q\npr_url=https://legacy\n' "$DRY"
slot_row 'pr_url_p=https://a\npr_url_p\0junk\n' "$DRY"
slot_row 'pr_url_p=https://a\0junk\n' "PR already recorded: https://a"
slot_row 'pr_url_p=https://cr\r\n' "PR already recorded: https://cr$(printf '\r')"
if [ "$(id -u)" != 0 ]; then
  both ships fa 'pr_url_p=https://example.test/pr/1\n'
  chmod 000 "$OH/home/data/fa/gate/ships.env" "$NH/home/data/fa/gate/ships.env"
  pair ship fa p --dry-run
  chmod 644 "$OH/home/data/fa/gate/ships.env" "$NH/home/data/fa/gate/ships.env"
  same_io "unreadable ships.env"
  assert_eq "$(shim_out)" "$DRY" "13: an unreadable ships.env reads none"
fi
rm -f "$OH/home/data/fa/gate/ships.env" "$NH/home/data/fa/gate/ships.env"
same ship fa p --dry-run; assert_eq "$(shim_out)" "$DRY" "13: no ships.env - the dry-run bytes"
COLL="ERROR: ship: repos my-app and my_app of feature mx share the ships.env key pr_url_my_app - one url slot cannot tell their PRs apart; re-record one of them under a distinct name (the captain's word) before shipping"
same ship mx my-app --dry-run; assert_eq "$(shim_err)" "$COLL" "13: two repos, one key"
both rec mx 'my-app feat/mx push=deferred\n# my_app feat/mx push=deferred\n'
same ship mx my-app --dry-run; assert_contains "$(shim_out)" "DRY-RUN: gh pr create" "13: a comment line is no repo"
both rec mx 'my-app feat/mx push=deferred\n \tmy.app feat/mx push=deferred'
same ship mx my-app --dry-run
assert_eq "$(shim_err)" "${COLL//my_app of/my.app of}" "13: an indented, unterminated last line collides"
same ship fe "$(printf '\303\251')" --dry-run
assert_eq "$(shim_out)" "PR already recorded: https://example.test/pr/e" "13: W5 - the name folds per byte under C"

# 15. jq is required on ship only, after the fence and before the home
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for d in /usr/bin /bin "$(dirname "$(command -v bun)")"; do
  for f in "$d"/*; do b="$(basename "$f")"; [ -x "$f" ] && [ "$b" != jq ] && [ ! -e "$NOJQ/$b" ] && ln -s "$f" "$NOJQ/$b"; done
done
FT_PATH="$FSTUBS:$NOJQ"
same ship fa p --dry-run; assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "15: no jq"
HOMELESS=1; same ship fa p --dry-run; HOMELESS=0
assert_eq "$(shim_err)" "ERROR: required tool not found: jq" "15: jq before the home"
FT_ENV=(AC_SCOPE=x); same ship fa p --dry-run; FT_ENV=()
assert_eq "$(shim_err)" "$(fence ship)" "15: the fence before jq"
same create fd pd; assert_eq "$(shim_out)" "exists: feat/fd in pd (left untouched)" "15: create needs no jq"
FT_PATH=""

# 16. a symlinked AC_HOME - W12, NAMED (the HOME RESOLUTION ruling): the
#     original joined projects/<repo> onto AC_HOME as spelled, so the clone
#     reads HOME/link in the dry-run lines and the review command; the port
#     binds the home physically; the data paths were physical on both sides
ln -s home "$OH/link"; ln -s home "$NH/link"
HOMELESS=1; FT_ENV=(AC_HOME=HOME/link)
pair ship fa p --dry-run
HOMELESS=0; FT_ENV=()
assert_eq "$O_RC $N_RC" "0 0" "16: W12 - both pass the gate"
assert_eq "$(cat "$TMP/o.out")" "${DRY//HOME\/home/HOME/link}" "16: W12 - the original prints the logical clone path"
assert_eq "$(shim_out)" "$DRY" "16: W12 named - the port prints the physical one"
rm -f "$OH/link" "$NH/link"

# 14. the REAL exit, run last because it pushes: the push lands on the scratch
#     origin even when gh then refuses (git's lines, gh's line, the refusal);
#     the next run opens the PR - gh run in the clone with the original's
#     argv, its url's trailing blank lines dropped, ships.env appended, the
#     SHIPS: line posted through ac-room.sh (the date stub's stamp) - and the
#     one after reports it; a pre-push hook's refusal is git's exit and lines,
#     with gh never run; a push a signal ends is 128+signal; the push and gh
#     inherit the caller's stdin; a gh not on PATH is the refusal (bash's own
#     `command not found` line is not reproduced - named); a ships.env that
#     is a directory reads none and the append fails after the PR opened,
#     exit 1 (bash's own redirection line not reproduced - named); a url gh
#     printed that is not UTF-8 stays raw bytes in stdout and ships.env while
#     both sides post the same U+FFFD spelling through the landed room entry
touch "$OH/gh.fail" "$NH/gh.fail"
same ship fa p
assert_eq "$N_RC" 1 "14: gh refusing exits 1"
assert_contains "$(shim_err)" "gh: the stub refuses
ERROR: gh pr create failed for feat/fa -> release" "14: gh's line, then the refusal"
assert_eq "$(git -C "$NH/remotes/p.git" rev-parse feat/fa)" "$FTIP" "14: the push landed before gh ran"
rm -f "$OH/gh.fail" "$NH/gh.fail"
same ship fa p
assert_eq "$(shim_out)" "opened pr: https://example.test/pr/1" "14: the PR opened"
assert_eq "$(cat "$NH/home/data/fa/gate/ships.env")" "pr_url_p=https://example.test/pr/1" "14: the url recorded under the repo's key"
assert_contains "$(cat "$NH/home/data/fa/room.md")" "- [2026-01-01T00:00:00Z] crewchief> SHIPS: pr https://example.test/pr/1 (p, feature-ship)" "14: the SHIPS: receipt"
assert_contains "$(norm "$NH/gh.log" "$NH")" "gh pr create --base release --head feat/fa --title feature(fa): feat/fa -> release --body Feature branch \`feat/fa\` of \`fa\` -> \`release\`. Opened by ac-feature.sh ship after the feature gate (members terminal, review round clean at $FTIP). The captain merges. (cwd HOME/home/projects/p)" "14: gh's argv and cwd"
same ship fa p; assert_eq "$(shim_out)" "PR already recorded: https://example.test/pr/1" "14: idempotent"
seed14() {
  origin_repo hk; cut_at hk feat/fh origin/main; review fh hk; rec fh 'hk feat/fh push=deferred\n'
  printf '#!/bin/sh\necho "pre-push: refused by the hook" >&2\nexit 1\n' >"$H/home/projects/hk/.git/hooks/pre-push"
  chmod +x "$H/home/projects/hk/.git/hooks/pre-push"
  origin_repo ps; cut_at ps feat/fs origin/main; review fs ps; rec fs 'ps feat/fs push=deferred\n'
  origin_repo pg; cut_at pg feat/fg origin/main; review fg pg; rec fg 'pg feat/fg push=deferred\n'
  origin_repo pz; cut_at pz feat/fz origin/main; review fz pz; rec fz 'pz feat/fz push=deferred\n'; mkdir -p "$H/home/data/fz/gate/ships.env"
  origin_repo pu; cut_at pu feat/fu origin/main; review fu pu; rec fu 'pu feat/fu push=deferred\n'
  led '- [ ] fa - container\n'
}
both seed14
same ship fh hk
assert_eq "$N_RC" 1 "14: the hook's refusal is git's exit"
assert_contains "$(shim_err)" "pre-push: refused by the hook" "14: the hook's own line"
case "$(shim_err)" in *"ERROR:"*) fail "14: a refused push prints no line of its own: $(shim_err)" ;; esac
[ ! -e "$NH/gh.log" ] || ! /usr/bin/grep -q feat/fh "$NH/gh.log" || fail "14: gh must not run after a refused push"
REAL_GIT="$(command -v git)"
SIGGIT="$TMP/siggit"; mkdir -p "$SIGGIT"
printf '#!/bin/sh\ncase " $* " in *" push "*) kill -TERM $$ ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$SIGGIT/git"; chmod +x "$SIGGIT/git"
FT_PATH="$FSTUBS:$SIGGIT:$PATH"; pair ship fs ps; FT_PATH=""
assert_eq "$O_RC $N_RC" "143 143" "14: a push ended by TERM is 128+15 on both sides"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "14: a signalled push - stdout differs"
assert_contains "$(oracle_err)" "Terminated: 15" "14: bash's own job line on the original"
assert_eq "$(shim_err)" "" "14: named, not reproduced"
same_world "a signalled push"
INGIT="$TMP/ingit"; mkdir -p "$INGIT"
cat >"$INGIT/git" <<STUB
#!/bin/sh
case " \$* " in *" push "*) IFS= read -r l; printf '%s\\n' "\$l" >>"\$PUSH_LOG" ;; esac
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$INGIT/git"
printf 'line one for the push\nline two for gh\n' >"$TMP/stdin14"
FT_PATH="$FSTUBS:$INGIT:$PATH"; FT_ENV=(GH_STDIN=1 PUSH_LOG=HOME/push-stdin.log); FT_STDIN="$TMP/stdin14"
same ship fs ps
FT_PATH=""; FT_ENV=(); unset FT_STDIN
assert_eq "$(cat "$NH/push-stdin.log")" "line one for the push" "14: the push read the caller's stdin"
assert_contains "$(cat "$NH/gh.log")" "stdin: line two for gh" "14: gh read the rest of it"
NOGH="$TMP/nogh"; mkdir -p "$NOGH"
for d in /usr/bin /bin "$(dirname "$(command -v bun)")"; do
  for f in "$d"/*; do b="$(basename "$f")"; [ -x "$f" ] && [ "$b" != gh ] && [ ! -e "$NOGH/$b" ] && ln -s "$f" "$NOGH/$b"; done
done
FT_PATH="$NOGH"; pair ship fg pg; FT_PATH=""
assert_eq "$O_RC $N_RC" "1 1" "14: no gh - both refuse"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "14: no gh - stdout differs"
assert_contains "$(oracle_err)" "gh: command not found" "14: no gh - bash's own line on the original"
assert_eq "$(tail -n 1 "$TMP/o.err2")" "ERROR: gh pr create failed for feat/fg -> main" "14: no gh - the original's refusal"
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: gh pr create failed for feat/fg -> main" "14: no gh - the port's refusal"
assert_eq "$(/usr/bin/grep -c 'command not found' "$TMP/n.err2")" 0 "14: no gh - named, not reproduced"
same_world "no gh"
pair ship fz pz
assert_eq "$O_RC $N_RC" "1 1" "14: an unwritable ships.env - exit 1 on both sides"
cmp -s "$TMP/o.out" "$TMP/n.out" || fail "14: an unwritable ships.env - stdout differs"
assert_contains "$(oracle_err)" "ships.env: Is a directory" "14: bash's own redirection line on the original"
case "$(shim_err)" in *"Is a directory"*) fail "14: named, not reproduced" ;; esac
same_world "an unwritable ships.env"
FT_ENV=("GH_URL=$(printf 'https://example.test/pr/\351')")
pair ship fu pu
FT_ENV=()
same_io "a url that is not UTF-8"
assert_eq "$(shim_out)" "opened pr: $(printf 'https://example.test/pr/\351')" "14: the url's bytes printed"
assert_eq "$(cat "$NH/home/data/fu/gate/ships.env")" "$(printf 'pr_url_pu=https://example.test/pr/\351')" "14: and recorded"
# the room entry is a module: its argv decoding spells the byte U+FFFD on both sides
assert_contains "$(cat "$OH/home/data/fu/room.md")" "$(printf 'SHIPS: pr https://example.test/pr/\357\277\275 (pu')" "14: the original's post reached the room decoded"
assert_eq "$(cat "$NH/home/data/fu/room.md")" "$(cat "$OH/home/data/fu/room.md")" "14: the port posted the same room line"

pass
