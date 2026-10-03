#!/usr/bin/env bash
# ac-epic-branch.test.sh - the per-epic integration-branch record and verbs:
# the archive-aware record resolver (live -> data/archive/<year>/, never a
# silent fail-open after a family move), create (cuts at the freshest default
# tip, idempotent, never moves an existing branch), verify (quiet, gate-able,
# refuses a retired record), retire (chief-writes-the-end marker), and the
# chief-only fence on the mutating verbs (a scoped chief reads, the crewchief
# cuts - the domain_chief_only pattern, because a PreToolUse hook cannot see
# a bash verb).

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
EB="$BIN/ac-epic-branch.sh"

# --- fixtures: an origin-backed clone and a local-only repo -------------------
upstream="$(make_repo upstream)"
mkdir -p "$AC_HOME/projects"
git clone -q "$upstream" "$AC_HOME/projects/proj"
git -C "$AC_HOME/projects/proj" config user.email test@test
git -C "$AC_HOME/projects/proj" config user.name test
lo="$AC_HOME/projects/localonly"
git init -q -b main "$lo"
git -C "$lo" config user.email test@test
git -C "$lo" config user.name test
printf 'x\n' >"$lo/f"; git -C "$lo" add -A; git -C "$lo" commit -qm init

# The project's own pre-push hook REFUSES every push. A delivery push must
# still run it (ac-ship.sh keeps hooks on purpose); the control-plane pushes
# below (create's cut, the landing's push=yes) are bookkeeping and go through
# ac_git_push_control_plane, which skips it - a project hook running a full
# suite, or aborting on a sha that is no deliverable, must not wedge them.
printf '#!/bin/sh\necho "pre-push: refused" >&2\nexit 1\n' >"$AC_HOME/projects/proj/.git/hooks/pre-push"
chmod +x "$AC_HOME/projects/proj/.git/hooks/pre-push"
out="$(git -C "$AC_HOME/projects/proj" push origin main:refs/heads/hook-probe 2>&1 || true)"
assert_contains "$out" "pre-push: refused" "a plain (delivery-style) push is refused by the project hook"
assert_fails git -C "$upstream" rev-parse --verify refs/heads/hook-probe

mkdir -p "$AC_HOME/data/eppy"
printf 'proj epic/eppy push=yes\nlocalonly epic/eppy\n' >"$AC_HOME/data/eppy/branches"

# --- create: needs a record entry, cuts at the freshest ORIGIN tip ------------
out="$("$EB" create eppy nosuchrepo 2>&1 || true)"
assert_contains "$out" "no record entry" "create without a record entry refuses"

# advance upstream AFTER the clone: create must fetch and cut at origin's tip
printf 'more\n' >>"$upstream/file.txt"
git -C "$upstream" add -A; git -C "$upstream" commit -qm advance
up_tip="$(git -C "$upstream" rev-parse main)"
"$EB" create eppy proj >/dev/null
assert_eq "$(git -C "$upstream" rev-parse refs/heads/epic/eppy)" "$up_tip" \
  "create cuts the branch on origin at origin's freshest tip"

# idempotent + never-clobber: a second create leaves the branch untouched
printf 'even more\n' >>"$upstream/file.txt"
git -C "$upstream" add -A; git -C "$upstream" commit -qm advance2
"$EB" create eppy proj >/dev/null
assert_eq "$(git -C "$upstream" rev-parse refs/heads/epic/eppy)" "$up_tip" \
  "a second create never moves the existing branch"

# --- local-only repo: create makes a local branch, verify sees it -------------
"$EB" create eppy localonly >/dev/null
assert_eq "$(git -C "$lo" rev-parse epic/eppy)" "$(git -C "$lo" rev-parse main)" \
  "a no-origin repo gets a local branch at its default tip"
"$EB" verify eppy localonly || fail "verify green on the local-only branch"

# --- verify: green on origin, red when the branch is gone ---------------------
"$EB" verify eppy proj || fail "verify green when origin has the branch"
git -C "$upstream" branch -D epic/eppy -q
if "$EB" verify eppy proj 2>/dev/null; then fail "verify must fail once origin lost the branch"; fi

# --- chief-only fence on the mutating verbs -----------------------------------
out="$(AC_SCOPE=eppy "$EB" create eppy proj 2>&1 || true)"
assert_contains "$out" "CREWCHIEF" "a scoped chief cannot create"
out="$(AC_SCOPE=eppy "$EB" retire eppy 2>&1 || true)"
assert_contains "$out" "CREWCHIEF" "a scoped chief cannot retire"

# --- show: the resolved record ------------------------------------------------
out="$("$EB" show eppy)"
assert_contains "$out" "proj epic/eppy push=yes" "show prints the record verbatim"

# --- retire: verify refuses and names the retirement --------------------------
"$EB" retire eppy >/dev/null
if "$EB" verify eppy localonly 2>/dev/null; then fail "verify must refuse a retired record"; fi
out="$("$EB" verify eppy localonly 2>&1 || true)"
assert_contains "$out" "retired" "the refusal names the retirement"
"$EB" retire eppy >/dev/null  # idempotent
assert_eq "$(grep -c '# retired' "$AC_HOME/data/eppy/branches")" "1" "retire is idempotent"

# --- archive-aware resolver: the record still resolves after the family moves -
mkdir -p "$AC_HOME/data/eppy2"
printf 'proj epic/eppy2\n' >"$AC_HOME/data/eppy2/branches"
mkdir -p "$AC_HOME/data/archive/2026"
mv "$AC_HOME/data/eppy2" "$AC_HOME/data/archive/2026/eppy2"
out="$("$EB" show eppy2)"
assert_contains "$out" "proj epic/eppy2" "an archived family's record still resolves (never silent fail-open)"

# --- no record at all: distinct from moved - callers get a clean miss ---------
if "$EB" show never-was >/dev/null 2>&1; then fail "show on a never-recorded epic must fail"; fi

# --- the FENCE in ac-tree get (slice 2) ---------------------------------------
# A lease for an id whose epic records a branch for the repo is cut FROM that
# branch; the fence resolves by longest id-prefix so fan-out sub-tasks and the
# epic's own scouts ride it too, and a recorded-but-never-created branch
# REFUSES the lease instead of falling through to the default base.
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
## In flight
- [ ] eppy3 [EPIC] - integration test epic (repo: proj)
- [ ] eppy3-s1 - story one; epic:eppy3 (repo: proj)
- [ ] eppy4 [EPIC] - fence-refusal epic (repo: proj)
- [ ] eppy4-s1 - story; epic:eppy4 (repo: proj)
- [ ] freetask - no epic at all (repo: proj)
EOF
mkdir -p "$AC_HOME/data/eppy3" "$AC_HOME/data/eppy4"
printf 'proj epic/eppy3 push=yes\n' >"$AC_HOME/data/eppy3/branches"
printf 'proj epic/eppy4\n' >"$AC_HOME/data/eppy4/branches"
"$EB" create eppy3 proj >/dev/null
epic_tip="$(git -C "$upstream" rev-parse refs/heads/epic/eppy3)"
# advance the default AFTER the cut, so epic tip != default tip provably
printf 'post-cut\n' >>"$upstream/file.txt"
git -C "$upstream" add -A; git -C "$upstream" commit -qm post-cut
def_tip="$(git -C "$upstream" rev-parse main)"

wt="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-s1 --holder t 2>/dev/null)"
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$epic_tip" "a story lease is cut from the recorded epic branch, not the default"
"$BIN/ac-tree.sh" return "$wt" >/dev/null 2>&1

wt2="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-s1-fix --holder t 2>/dev/null)"
assert_eq "$(git -C "$wt2" rev-parse HEAD)" "$epic_tip" "a fan-out sub-id (no row) rides its story's fence via the prefix walk"
"$BIN/ac-tree.sh" return "$wt2" >/dev/null 2>&1

wt3="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-asbuilt --holder t 2>/dev/null)"
assert_eq "$(git -C "$wt3" rev-parse HEAD)" "$epic_tip" "the epic's OWN task id rides the fence too (row-id arm)"
"$BIN/ac-tree.sh" return "$wt3" >/dev/null 2>&1

out="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy4-s1 --holder t 2>&1 || true)"
assert_contains "$out" "cut it first" "a recorded-but-missing branch refuses the lease (never silent fall-through)"

wt4="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id freetask --holder t 2>/dev/null)"
assert_eq "$(git -C "$wt4" rev-parse HEAD)" "$def_tip" "an id with no epic record keeps today's default base"
"$BIN/ac-tree.sh" return "$wt4" >/dev/null 2>&1

# --- epic-target landing (slice 3): ref-only ff into the recorded branch ------
wt5="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-s1 --holder t 2>/dev/null)"
git -C "$wt5" checkout -q -b crew/eppy3-s1
printf 'story work\n' >"$wt5/story.txt"
git -C "$wt5" add -A; git -C "$wt5" commit -qm "story work"
story_head="$(git -C "$wt5" rev-parse HEAD)"
printf 'project_dir=%s\nworktree=%s\n' "$AC_HOME/projects/proj" "$wt5" >"$AC_HOME/state/eppy3-s1.meta"
clone_main_before="$(git -C "$AC_HOME/projects/proj" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" eppy3-s1)"
assert_contains "$out" "ref-only" "the epic landing is a ref-only ff, never a checkout merge"
assert_contains "$out" "deferred to the epic gate" "qa.require_for_ship defers to the epic gate on an epic landing"
assert_contains "$out" "pushed epic/eppy3" "the record's push=yes rides the landing"
assert_eq "$(git -C "$AC_HOME/projects/proj" rev-parse refs/heads/epic/eppy3)" "$story_head" \
  "the LOCAL epic branch fast-forwarded to the story head"
assert_eq "$(git -C "$upstream" rev-parse refs/heads/epic/eppy3)" "$story_head" \
  "and origin followed (push=yes)"
assert_eq "$(git -C "$AC_HOME/projects/proj" rev-parse main)" "$clone_main_before" \
  "the default branch is untouched by an epic landing"
# --no-ff refuses on an epic target (a merge commit belongs in a leased tree)
out="$("$BIN/ac-merge-local.sh" eppy3-s1 --no-ff 2>&1 || true)"
assert_contains "$out" "leased worktree" "--no-ff onto an epic target refuses with the remedy"
# no-op re-land lands truthfully
out="$("$BIN/ac-merge-local.sh" eppy3-s1)"
assert_contains "$out" "already contains" "a re-land is a truthful no-op"

# --- review derivation under the epic ruling (slice 4) ------------------------
# Captain ruling 2026-08-19: a branch-recorded epic's stories default to
# review=no (the epic gate owns the round); staged keeps its design gates but
# drops the code-review round; crew-ship KEEPS its pipeline round (story-sized
# via --target) until the epic-gate slice; a non-epic staged task still
# refuses --review no.
mkdir -p "$AC_HOME/records"
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] eppy3-s2 [src:cap flow:staged mode:local-only qa:no] - staged story; epic:eppy3 (repo: proj)
- [ ] eppy3-s3 [src:cap flow:direct mode:crew-ship rev:yes qa:no] - ship story; epic:eppy3 (repo: proj)
- [ ] eppy3-s4 [src:cap flow:direct mode:direct-pr rev:no qa:no] - pr story; epic:eppy3 (repo: proj)
- [ ] solo1 [src:cap flow:staged mode:local-only qa:no] - standalone staged (repo: proj)
EOF
"$BIN/ac-brief.sh" eppy3-s2 proj --stage implement >/dev/null
assert_contains "$(cat "$AC_HOME/data/eppy3-s2/implement/brief.md")" "epic gate owns the review round" \
  "a staged epic story's EXECUTION brief derives review=no with the ruling on record"
# Raising it back is the captain's word, exactly as on a direct story: without a
# rev:yes pin or --captain-requested the raise is refused, nothing scaffolded.
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] eppy3-s5 [src:cap flow:staged mode:local-only qa:no] - staged story, no review pin; epic:eppy3 (repo: proj)
- [ ] eppy3-s6 [src:cap flow:staged mode:local-only rev:yes qa:no] - staged story, review pinned; epic:eppy3 (repo: proj)
EOF
out="$("$BIN/ac-brief.sh" eppy3-s5 proj --stage implement --review yes 2>&1)" \
  && fail "a staged epic story must not raise review without the captain's word: $out"
assert_contains "$out" "rev:yes" "...the refusal names the unconfirmed review"
assert_no_file "$AC_HOME/data/eppy3-s5/implement/brief.md" "...and scaffolds nothing"
"$BIN/ac-brief.sh" eppy3-s6 proj --stage implement --review yes >/dev/null \
  || fail "a rev:yes pin on the row authorizes the raise"
assert_contains "$(cat "$AC_HOME/data/eppy3-s6/implement/brief.md")" "Review: yes" "...and the brief carries it"
out="$("$BIN/ac-brief.sh" solo1-spec proj --stage spec --review no 2>&1 || true)"
assert_contains "$out" "staged flow requires review=yes" \
  "a NON-epic staged task still refuses --review no"
"$BIN/ac-brief.sh" eppy3-s3 proj >/dev/null
s3b="$(cat "$AC_HOME/data/eppy3-s3/brief.md")"
assert_contains "$s3b" "--target epic/eppy3" "a crew-ship epic story's brief names the engine target"
assert_contains "$s3b" "Review: yes" "crew-ship keeps its pipeline round (story-sized via the target)"
"$BIN/ac-brief.sh" eppy3-s4 proj >/dev/null
assert_contains "$(cat "$AC_HOME/data/eppy3-s4/brief.md")" "epic integration branch" \
  "a direct-pr epic story's brief names the PR base"

# --- review-diff against the EPIC base (slice 5) ------------------------------
# story.txt already LANDED into epic/eppy3; a new lease + one new commit must
# diff as ONLY the new commit - a default-based merge-base would render the
# landed sibling work as this story's diff.
"$BIN/ac-tree.sh" return "$wt5" --force >/dev/null 2>&1
wt6="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-s1 --holder t 2>/dev/null)"
git -C "$wt6" checkout -q -B crew/eppy3-s1
printf 'round two\n' >"$wt6/round2.txt"
git -C "$wt6" add -A; git -C "$wt6" commit -qm "round two"
printf 'project_dir=%s\nworktree=%s\nproject=proj\n' "$AC_HOME/projects/proj" "$wt6" >"$AC_HOME/state/eppy3-s1.meta"
rd="$("$BIN/ac-review-diff.sh" eppy3-s1 --stat)"
assert_contains "$rd" "round2.txt" "review-diff shows the story's own new work"
case "$rd" in *story.txt*) fail "review-diff must not render the LANDED sibling work as this story's diff" ;; esac
# A ledger nobody can read cannot prove the story has no epic branch, so the
# landing and the diff refuse rather than fall back to the default branch.
# Skipped under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  main_before="$(git -C "$AC_HOME/projects/proj" rev-parse main)"
  chmod 000 "$AC_HOME/records/backlog.md"
  out="$("$BIN/ac-merge-local.sh" eppy3-s1 2>&1 || true)"
  rd="$("$BIN/ac-review-diff.sh" eppy3-s1 --stat 2>&1 || true)"
  chmod 644 "$AC_HOME/records/backlog.md"
  assert_eq "$(git -C "$AC_HOME/projects/proj" rev-parse main)" "$main_before" "an unreadable ledger never lands a story on the default branch"
  assert_contains "$out" "cannot read the ledger" "merge-local names the unreadable ledger"
  assert_contains "$rd" "cannot read the ledger" "review-diff names the unreadable ledger"
fi
# A sibling that lands through a PR moves origin's epic branch while the local
# one stays behind; a new story's lease is cut from origin's tip (ac-tree.sh
# get), so its diff base must be that same ref - the stale local branch would
# render the sibling's landed file as this story's change.
git -C "$upstream" checkout -q epic/eppy3
printf 'sibling via PR\n' >"$upstream/sib.txt"
git -C "$upstream" add sib.txt; git -C "$upstream" commit -qm "sibling story landed by PR"
git -C "$upstream" checkout -q main
git -C "$AC_HOME/projects/proj" fetch -q origin
printf -- '- [ ] eppy3-s7 - story; epic:eppy3 (repo: proj)\n' >>"$AC_HOME/records/backlog.md"
wt7="$("$BIN/ac-tree.sh" get --repo "$AC_HOME/projects/proj" --id eppy3-s7 --holder t 2>/dev/null)"
git -C "$wt7" checkout -q -B crew/eppy3-s7
printf 'mine\n' >"$wt7/mine.txt"
git -C "$wt7" add -A; git -C "$wt7" commit -qm "story seven"
printf 'project_dir=%s\nworktree=%s\nproject=proj\n' "$AC_HOME/projects/proj" "$wt7" >"$AC_HOME/state/eppy3-s7.meta"
rd="$("$BIN/ac-review-diff.sh" eppy3-s7 --stat)"
assert_contains "$rd" "mine.txt" "review-diff shows the story's own work"
case "$rd" in *sib.txt*) fail "review-diff must take the base the lease was cut from, not a stale local epic branch: $rd" ;; esac
"$BIN/ac-tree.sh" return "$wt7" --force >/dev/null 2>&1; rm -f "$AC_HOME/state/eppy3-s7.meta"

# --- checked-out epic target: the live practice lands in place ----------------
# The lab clones sit ON the epic branch; `git fetch . src:dst` refuses to move
# the current branch's ref, so this ff must be an in-place --ff-only merge.
git -C "$AC_HOME/projects/proj" checkout -q epic/eppy3
out="$("$BIN/ac-merge-local.sh" eppy3-s1)"
assert_contains "$out" "in place" "a checked-out epic target lands by in-place ff"
assert_eq "$(git -C "$AC_HOME/projects/proj" rev-parse HEAD)" "$(git -C "$wt6" rev-parse crew/eppy3-s1)" \
  "the checked-out target followed the story head"
git -C "$AC_HOME/projects/proj" checkout -q main
"$BIN/ac-tree.sh" return "$wt6" --force >/dev/null 2>&1

# --- the epic gate + 2-PR exit (ac-epic-ship, slice 6) ------------------------
ES="$BIN/ac-epic-ship.sh"
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] eppy5 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:no] - exit-test epic (repo: proj)
- [ ] eppy5-s1 - open story; epic:eppy5 (repo: proj)
EOF
mkdir -p "$AC_HOME/data/eppy5"
printf 'proj epic/eppy5 push=yes staging=stagebr\n' >"$AC_HOME/data/eppy5/branches"
"$EB" create eppy5 proj >/dev/null

out="$(AC_SCOPE=eppy5 "$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "CREWCHIEF" "epic-ship is chief-only"
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "non-terminal stories: eppy5-s1" "an open story refuses the exit and is named"

# stories terminal, one abandoned -> the partial-epic captain receipt gate
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("- [ ] eppy5-s1 - open story; epic:eppy5 (repo: proj)",
  "- [x] eppy5-s1 - landed story; epic:eppy5 (repo: proj)\n- [x] eppy5-s2 [abandoned] - died mid-epic; epic:eppy5 (repo: proj)")
open(p, "w").write(s)
PYEOF
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "partial epic" "an abandoned story without a captain receipt refuses"
assert_contains "$out" "eppy5-s2" "and names it"
printf -- '- [2026-08-19T12:00:00Z] crewchief> DECIDED: epic-ship partial - eppy5-s2 keep (captain: giu lai, cong viec da land van dung)\n' >>"$AC_HOME/data/eppy5/room.md"

# A ledger nobody can read shows no story terminal, so the exit stops at the
# story check instead of moving on to the review gate as if none were open.
# Skipped under root, which reads through chmod 000.
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$AC_HOME/records/backlog.md"
  rc=0; out="$("$ES" eppy5 proj --dry-run 2>&1)" || rc=$?
  chmod 644 "$AC_HOME/records/backlog.md"
  [ "$rc" != 0 ] || fail "an unreadable ledger must refuse the exit"
  case "$out" in *"no epic review round"* | *DRY-RUN*) fail "an unreadable ledger must stop the exit at the story check, got: $out" ;; esac
fi

# review round: absent -> refuse naming the exact command; stale ref -> refuse
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "no epic review round on record" "a missing review round refuses"
assert_contains "$out" "ac-verify.sh codereview" "and prints the exact round command"
tip5="$(git -C "$AC_HOME/projects/proj" rev-parse refs/remotes/origin/epic/eppy5)"
mkdir -p "$AC_HOME/data/eppy5/gate"
printf '{"findings":[{"action":"fix","summary":"x"}],"reviewed_ref":"%s"}\n' "$tip5" >"$AC_HOME/data/eppy5/gate/review.json"
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "open fix finding" "an open fix finding refuses the exit"
printf '{"findings":[],"reviewed_ref":"%s"}\n' "$tip5" >"$AC_HOME/data/eppy5/gate/review.json"

# gates green -> dry-run opens PR-1 to staging and HOLDS PR-2
out="$("$ES" eppy5 proj --dry-run)"
assert_contains "$out" "DRY-RUN: git -C" "push=yes rides the exit (dry-printed)"
assert_contains "$out" "--base stagebr" "PR-1 targets the recorded staging branch"
assert_contains "$out" "PR-2 (-> main) held" "PR-2 is held until PR-1 is proven merged"

# staging proven to CONTAIN the tip (ancestry arm) -> PR-2 opens
git -C "$upstream" branch stagebr epic/eppy5
git -C "$AC_HOME/projects/proj" fetch -q origin
out="$("$ES" eppy5 proj --dry-run)"
assert_contains "$out" "proven merged; opening PR-2" "the ancestry arm releases PR-2"
assert_contains "$out" "--base main" "PR-2 targets the default branch"

# qa pin on the epic row: no attestation at the tip -> refuse with the caveat
python3 - "$AC_HOME/records/backlog.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("- [ ] eppy5 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:no]",
              "- [ ] eppy5 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:yes]")
open(p, "w").write(s)
PYEOF
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a qa:yes epic refuses without an attestation at the tip"
mkdir -p "$AC_HOME/projects/proj/.crew/qa/passed"
: >"$AC_HOME/projects/proj/.crew/qa/passed/$tip5"
out="$("$ES" eppy5 proj --dry-run)"
assert_contains "$out" "proven merged; opening PR-2" "the attestation at the tip satisfies the qa gate"

# A hand edit can leave the ledger without its final newline; the last row is
# still a row, so an open story there holds the exit like any other.
cp "$AC_HOME/records/backlog.md" "$TMP/backlog.keep"
printf -- '- [ ] eppy5-s3 - open story, no trailing newline; epic:eppy5 (repo: proj)' >>"$AC_HOME/records/backlog.md"
out="$("$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "non-terminal stories: eppy5-s3" "an open story on an unterminated last line refuses the exit"
mv "$TMP/backlog.keep" "$AC_HOME/records/backlog.md"

# A byte that is not UTF-8 in ledger prose is no row and must not stop the
# exit. The locale is forced: only a UTF-8 ctype makes awk die on a regex
# test against such a line, so under C this would pass on any filter.
cp "$AC_HOME/records/backlog.md" "$TMP/backlog.keep"
printf '> caf\351 reviewed\n' >>"$AC_HOME/records/backlog.md"
out="$(LC_ALL=en_US.UTF-8 "$ES" eppy5 proj --dry-run 2>&1 || true)"
assert_contains "$out" "proven merged; opening PR-2" "a non-UTF-8 byte in ledger prose does not stop the exit"
mv "$TMP/backlog.keep" "$AC_HOME/records/backlog.md"

# Re-runs are idempotent on the staging path too: once PR-2 is recorded, a
# re-run reports it instead of opening a second production PR.
printf 'pr2_url=https://forge.invalid/pr/2\n' >>"$AC_HOME/data/eppy5/gate/ships.env"
out="$("$ES" eppy5 proj --dry-run)"
assert_contains "$out" "already recorded: https://forge.invalid/pr/2" "a recorded PR-2 is reported on a re-run"
case "$out" in *"gh pr create"*) fail "a recorded PR-2 must never be opened again" ;; esac

# The qa pin is read off the epic's OWN row. awk's == compared numeric-looking
# ids as numbers, so an earlier row 07 stood in for epic 7 and its empty
# contract let the exit skip the qa gate.
cat >>"$AC_HOME/records/backlog.md" <<'EOF'
- [ ] 07 - an unrelated row that reads as the same number (repo: proj)
- [ ] 7 [EPIC] [src:cap flow:direct mode:direct-pr rev:no qa:yes] - a numeric epic (repo: proj)
EOF
mkdir -p "$AC_HOME/data/7/gate"
printf 'proj epic/7\n' >"$AC_HOME/data/7/branches"
"$EB" create 7 proj >/dev/null
printf '{"findings":[],"reviewed_ref":"%s"}\n' "$(git -C "$AC_HOME/projects/proj" rev-parse refs/remotes/origin/epic/7)" \
  >"$AC_HOME/data/7/gate/review.json"
rm -rf "$AC_HOME/projects/proj/.crew/qa/passed"
out="$("$ES" 7 proj --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a numeric epic's own qa:yes pin gates its exit"
# A TAB may join contract tokens (src/backlog.ts); the gate once matched the
# pin between spaces only, so a TAB before qa:yes skipped it.
perl -pi -e 's/rev:no qa:yes\] - a numeric epic/rev:no\tqa:yes] - a numeric epic/' "$AC_HOME/records/backlog.md"
out="$("$ES" 7 proj --dry-run 2>&1 || true)"
assert_contains "$out" "no crew-qa pass attestation" "a TAB-joined qa:yes pin gates the exit"

# --- differential: src/epic-branch.ts against the frozen bash original --------
# DISPUTED: the implementation (tests/fixtures/ac-epic-branch.sh under bash vs src/epic-branch.ts through bin/ac-epic-branch.sh)
# HELD-CONSTANT: two homes seeded alike ($OH for the oracle, $NH for the shim) - each with its own upstream, clone (refusing pre-push hook) and local-only repo, every commit stamped with one fixed date so the shas agree - argv, cwd, LC_ALL=C on both sides; exit status, stdout and stderr (the home path spelled HOME, a retire stamp spelled STAMP) compared whole, the record bytes after every mutating verb, and the branch tips git left behind.
obin="$(make_oracle_bin ac-epic-branch)"
OH="$TMP/oh"; NH="$TMP/nh"
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each home
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
mkrepo() {  # mkrepo <dir> <branch> - one fixed-date commit on <branch>
  git init -q -b "$2" "$1"
  git -C "$1" config user.email test@test; git -C "$1" config user.name test
  printf 'hello\n' >"$1/file.txt"; git -C "$1" add -A; gitc -C "$1" commit -qm init
}
mkclone() {  # mkclone <upstream> <dir>
  git clone -q "$1" "$2"
  git -C "$2" config user.email test@test; git -C "$2" config user.name test
}
seed_home() {  # the file's own fixture, rebuilt under $H
  mkdir -p "$H/projects" "$H/data/eppy"
  mkrepo "$H/upstream" main
  mkclone "$H/upstream" "$H/projects/proj"
  printf '#!/bin/sh\necho "pre-push: refused" >&2\nexit 1\n' >"$H/projects/proj/.git/hooks/pre-push"
  chmod +x "$H/projects/proj/.git/hooks/pre-push"
  mkrepo "$H/projects/localonly" main
  printf 'proj epic/eppy push=yes\nlocalonly epic/eppy\n' >"$H/data/eppy/branches"
}
advance() {  # advance <msg> - one more fixed-date commit on upstream main
  printf '%s\n' "$1" >>"$H/upstream/file.txt"; git -C "$H/upstream" add -A; gitc -C "$H/upstream" commit -qm "$1"
}
rec() {  # rec <epic> <printf-format> - a record written as bytes
  mkdir -p "$H/data/$1"; printf -- "$2" >"$H/data/$1/branches"
}
run_oracle() { (cd "$TMP" && AC_HOME="$OH" LC_ALL=C "$obin/ac-epic-branch.sh" "$@") >"$TMP/o.raw" 2>"$TMP/o.err"; }
run_shim() { (cd "$TMP" && AC_HOME="$NH" LC_ALL=C "$BIN/ac-epic-branch.sh" "$@") >"$TMP/n.raw" 2>"$TMP/n.err"; }
norm() {  # norm <file> <home> - the home spelled HOME, a retire stamp STAMP
  LC_ALL=C sed -e "s#$2#HOME#g" -e 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z/STAMP/g' "$1"
}
same() {  # same <args...> - oracle on $OH and shim on $NH answer byte-identically
  local o_rc=0 n_rc=0
  run_oracle "$@" || o_rc=$?
  run_shim "$@" || n_rc=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 4)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
same_record() {  # same_record <path under data/> - the record bytes agree
  assert_eq "$(norm "$NH/data/$1/branches" "$NH")" "$(norm "$OH/data/$1/branches" "$OH")" "differential record $1"
}
same_tip() {  # same_tip <repo under the home> <ref> - the same tip in both homes, or none in both
  local o n
  o="$(git -C "$OH/$1" rev-parse --verify -q "$2" || printf none)"
  n="$(git -C "$NH/$1" rev-parse --verify -q "$2" || printf none)"
  assert_eq "$n" "$o" "differential tip $1 $2"
}
both seed_home

# 1. create cuts at origin's freshest tip (upstream advanced after the clone)
both advance more
same create eppy proj
assert_eq "$(shim_out)" "created: epic/eppy on origin of proj at $(git -C "$NH/upstream" rev-parse main)" "the created line names origin's tip"
same_tip upstream refs/heads/epic/eppy
# 2. a second create after another advance leaves it untouched
both advance "even more"
same create eppy proj
assert_eq "$(shim_out)" "exists: epic/eppy on origin of proj (left untouched)" "the exists line"
same_tip upstream refs/heads/epic/eppy
# 3. a local-only repo, twice
same create eppy localonly
assert_eq "$(shim_out)" "created: epic/eppy in localonly (local-only repo)" "the local-only created line"
same_tip projects/localonly refs/heads/epic/eppy
same create eppy localonly
assert_eq "$(shim_out)" "exists: epic/eppy in localonly (left untouched)" "the local-only exists line"
# 4. no entry; an entry whose clone is missing
same create eppy nosuchrepo
assert_eq "$(shim_err)" "ERROR: create: no record entry for nosuchrepo under epic eppy - write data/eppy/branches first (the captain's word, receipted DECIDED: to the room)" "no entry"
addghost() { printf 'ghost epic/g\n' >>"$H/data/eppy/branches"; }
both addghost
same create eppy ghost
assert_eq "$(shim_err)" "ERROR: no project clone at projects/ghost" "no clone"
same verify eppy ghost
# 5. verify: quiet green, red once the branch is gone, on origin and locally
same verify eppy proj
assert_eq "$(shim_out)$(shim_err)" "" "verify prints nothing on success"
delup() { git -C "$H/upstream" branch -D epic/eppy -q; }
both delup
same verify eppy proj
assert_eq "$(shim_err)" "ERROR: verify: epic/eppy is not on origin of proj - create it (ac-epic-branch.sh create eppy proj) before any story spawns against it" "verify red on origin"
same verify eppy localonly
dellocal() { git -C "$H/projects/localonly" branch -D epic/eppy -q; }
both dellocal
same verify eppy localonly
assert_eq "$(shim_err)" "ERROR: verify: epic/eppy does not exist in localonly - create it (ac-epic-branch.sh create eppy localonly) before any story spawns against it" "verify red locally"
# 6. the fence: create/retire refuse a scoped session, show/verify do not
AC_SCOPE=eppy same create eppy proj
assert_eq "$(shim_err)" "ERROR: create is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=eppy) - the integration branch is cut and retired on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it" "the create fence"
AC_SCOPE=eppy same retire eppy
assert_contains "$(shim_err)" "retire is the CREWCHIEF's verb" "the retire fence"
same show eppy
unscoped="$(shim_out)"
AC_SCOPE=eppy same show eppy
assert_eq "$(shim_out)" "$unscoped" "show is allowed scoped, the same output"
AC_SCOPE=eppy same verify eppy localonly
case "$(shim_err)" in *CREWCHIEF*) fail "verify must not be fenced" ;; esac
# 7. show: the path then the bytes; no trailing newline; TABs, runs and a comment line (resolved to the branch too)
same show eppy
assert_eq "$(shim_out)" "# HOME/data/eppy/branches
proj epic/eppy push=yes
localonly epic/eppy
ghost epic/g" "show prints the path and the record"
both rec nt 'proj epic/nt'
same show nt
printf '# HOME/data/nt/branches\nproj epic/nt' >"$TMP/want"
cmp -s "$TMP/want" "$TMP/n.out" || fail "show echoes a record with no trailing newline as is"
both rec tabs '# the record\nproj\tepic/t\tpush=yes\nlocalonly   epic/s   \n'
same show tabs
same verify tabs proj
assert_eq "$(shim_err)" "ERROR: verify: epic/t is not on origin of proj - create it (ac-epic-branch.sh create tabs proj) before any story spawns against it" "a TAB-separated entry resolves to its branch"
same create tabs localonly
assert_eq "$(shim_out)" "created: epic/s in localonly (local-only repo)" "runs and trailing blanks resolve to the branch"
# 8. retire: the marker, idempotent, then the rc-2 refusals; show still prints
mode_before="$(ls -l "$NH/data/eppy/branches" | cut -c1-10)"
same retire eppy
assert_eq "$(shim_out)" "retired: epic eppy record at HOME/data/eppy/branches" "the retired line"
same_record eppy
assert_eq "$(head -n 1 "$NH/data/eppy/branches" | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z/STAMP/')" "# retired STAMP" "the marker line"
# Named divergence: the original's mktemp+mv left the record with the temp
# file's 0600; the port rewrites it with the mode the record had.
assert_eq "$(ls -l "$OH/data/eppy/branches" | cut -c1-10)" "-rw-------" "the original leaves mktemp's mode on the record"
assert_eq "$(ls -l "$NH/data/eppy/branches" | cut -c1-10)" "$mode_before" "the port keeps the record's mode"
same retire eppy
assert_eq "$(shim_out)" "already retired: # retired STAMP" "the already-retired line"
same_record eppy
assert_eq "$(grep -c '^# retired' "$NH/data/eppy/branches")" "1" "one marker line"
same verify eppy localonly
assert_eq "$(shim_err)" "ERROR: verify: the eppy record is retired (# retired STAMP) - a retired epic has no integration branch; re-record on the captain's word if the epic truly reopens" "verify names the retirement"
same create eppy proj
assert_eq "$(shim_err)" "ERROR: create: the eppy record is retired (# retired STAMP) - a retired epic has no integration branch; re-record on the captain's word if the epic truly reopens" "create names the retirement"
same show eppy
assert_contains "$(shim_out)" "# retired STAMP" "show prints a retired record"
# 9. an archived record: show, verify, retire in place, show; the year glob in byte order
archive_eppy2() {
  rec eppy2 'proj epic/eppy2\n'
  mkdir -p "$H/data/archive/2026"; mv "$H/data/eppy2" "$H/data/archive/2026/eppy2"
}
both archive_eppy2
same show eppy2
assert_eq "$(shim_out)" "# HOME/data/archive/2026/eppy2/branches
proj epic/eppy2" "an archived record resolves"
same verify eppy2 proj
assert_eq "$(shim_err)" "ERROR: verify: epic/eppy2 is not on origin of proj - create it (ac-epic-branch.sh create eppy2 proj) before any story spawns against it" "verify reads the archived record"
same retire eppy2
assert_eq "$(shim_out)" "retired: epic eppy2 record at HOME/data/archive/2026/eppy2/branches" "retire rewrites it in place under archive/"
same_record archive/2026/eppy2
same show eppy2
years() {
  mkdir -p "$H/data/archive/10/yr" "$H/data/archive/9/yr"
  printf 'proj epic/ten\n' >"$H/data/archive/10/yr/branches"; printf 'proj epic/nine\n' >"$H/data/archive/9/yr/branches"
}
both years
same show yr
assert_eq "$(shim_out)" "# HOME/data/archive/10/yr/branches
proj epic/ten" "the first year in byte order (digits sort alike under every collation)"
# 10. never recorded: the two distinct refusals
same show never-was
assert_eq "$(shim_err)" "ERROR: show: no branches record for epic never-was (live or archived) - this epic was never branch-recorded" "show's miss"
same retire never-was
assert_eq "$(shim_err)" "ERROR: retire: no branches record for epic never-was - nothing to retire" "retire's miss"
# 11. arity first: no verb, a short create, a bare show, an unknown verb, too many
same
same create eppy
same show
same bogus eppy
same create a b c d
same show eppy extra
assert_eq "$(shim_err)" "ERROR: usage: ac-epic-branch.sh create|verify <epic> <repo> | show|retire <epic>" "the usage line"
# 12. the freshest-ref arms: local ahead, diverged, master with origin/HEAD gone, a trunk HEAD, a detached HEAD (git's own failure)
localcommit() {  # local main = origin's tip + one unpushed commit
  git -C "$H/projects/proj" fetch -q origin; git -C "$H/projects/proj" merge -q --ff-only origin/main
  printf 'local\n' >>"$H/projects/proj/file.txt"; git -C "$H/projects/proj" add -A; gitc -C "$H/projects/proj" commit -qm local
}
both localcommit
both rec ahead 'proj epic/ahead\n'
same create ahead proj
assert_eq "$(shim_out)" "created: epic/ahead on origin of proj at $(git -C "$NH/projects/proj" rev-parse main)" "a local main ahead of origin is the cut"
same_tip upstream refs/heads/epic/ahead
both advance diverge
both rec diverged 'proj epic/diverged\n'
same create diverged proj
assert_eq "$(shim_out)" "created: epic/diverged on origin of proj at $(git -C "$NH/upstream" rev-parse main)" "a diverged main cuts at origin's tip"
same_tip upstream refs/heads/epic/diverged
masterrepo() {
  mkrepo "$H/upstream-master" master
  mkclone "$H/upstream-master" "$H/projects/pm"
  git -C "$H/projects/pm" symbolic-ref --delete refs/remotes/origin/HEAD
  rec mast 'pm epic/m\n'
}
both masterrepo
same create mast pm
assert_eq "$(shim_out)" "created: epic/m on origin of pm at $(git -C "$NH/upstream-master" rev-parse master)" "no origin/HEAD, no main: the master arm"
same_tip upstream-master refs/heads/epic/m
trunkrepo() { mkrepo "$H/projects/trunky" trunk; rec trunk 'trunky epic/tr\n'; }
both trunkrepo
same create trunk trunky
assert_eq "$(shim_out)" "created: epic/tr in trunky (local-only repo)" "a trunk HEAD is the default"
same_tip projects/trunky refs/heads/epic/tr
detachedrepo() {
  mkrepo "$H/projects/det" trunk; git -C "$H/projects/det" checkout -q --detach; rec det 'det epic/d\n'
  mkrepo "$H/upstream-trunk" trunk
  mkclone "$H/upstream-trunk" "$H/projects/dtr"
  # create's fetch would put origin/HEAD back (git >= 2.48 follows the remote
  # HEAD) and the trunk arm would cut; the arm under test is `main` by default
  # with nothing to resolve it.
  git -C "$H/projects/dtr" config remote.origin.followRemoteHEAD never
  git -C "$H/projects/dtr" symbolic-ref --delete refs/remotes/origin/HEAD
  git -C "$H/projects/dtr" checkout -q --detach
  rec dtr 'dtr epic/dt\n'
}
both detachedrepo
same create det det
assert_contains "$(shim_err)" "not a valid object name" "a detached local-only repo: git branch's own refusal, its status the run's"
same create dtr dtr
assert_contains "$(shim_err)" "fatal: ambiguous argument 'main'" "a detached origin-backed repo: git rev-parse's own refusal, its status the run's"
# 13. awk's numeric ==: repo 7 takes the 07 entry
numrepo() { mkrepo "$H/projects/7" main; rec num '07 epic/a\n7 epic/b\n'; }
both numrepo
same create num 7
assert_eq "$(shim_out)" "created: epic/a in 7 (local-only repo)" "07 reads as 7 (the bash reader's awk, kept)"
same_tip projects/7 refs/heads/epic/a
same_tip projects/7 refs/heads/epic/b
# 14. is row 7's TAB and run records.
# 15. a push origin refuses, then an origin that cannot be fetched: git's own lines, then the refusal
refuse() { printf '#!/bin/sh\necho "pre-receive: refused" >&2\nexit 1\n' >"$H/upstream/.git/hooks/pre-receive"; chmod +x "$H/upstream/.git/hooks/pre-receive"; }
both refuse
both rec pushfail 'proj epic/pf\n'
same create pushfail proj
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: create: pushing epic/pf to origin of proj failed" "the push refusal"
assert_contains "$(shim_err)" "pre-receive: refused" "git's own stderr passed through"
unrefuse() { rm -f "$H/upstream/.git/hooks/pre-receive"; }
both unrefuse
nowhere() { git -C "$H/projects/proj" remote set-url origin "$H/nowhere"; }
both nowhere
same create pushfail proj
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: create: fetch origin failed for proj - the branch must be cut at origin's real tip, not a stale mirror" "the fetch refusal"
assert_contains "$(shim_err)" "does not appear to be a git repository" "git's own stderr passed through"
back() { git -C "$H/projects/proj" remote set-url origin "$H/upstream"; }
both back
# 16. homeless and an unreadable home
for args in "create eppy proj" "verify eppy proj" "show eppy" "retire eppy"; do
  o_rc=0; (cd "$TMP" && AC_HOME= LC_ALL=C "$obin/ac-epic-branch.sh" $args) >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && AC_HOME= LC_ALL=C "$BIN/ac-epic-branch.sh" $args) >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "1 1" "homeless '$args': both refuse"
  assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "homeless '$args': nothing on stdout"
  assert_eq "$(head -n 1 "$TMP/n.err")" "$(head -n 1 "$TMP/o.err")" "homeless '$args': the same refusal line"
  assert_contains "$(head -n 1 "$TMP/n.err")" "ERROR: AC_HOME is not set" "homeless '$args': names the variable"
  # Named divergence: the original printed the refusal twice (ac_data_dir ran
  # on both rungs of the resolver) and then the verb's own no-record line - the
  # resolver carried on after the refusal, reading /<epic>/branches. An
  # artifact; the port stops at the refusal.
  assert_eq "$(wc -l <"$TMP/o.err" | tr -d ' ')" "3" "homeless '$args': the original says it twice and goes on"
  assert_eq "$(wc -l <"$TMP/n.err" | tr -d ' ')" "1" "homeless '$args': the port says it once"
  o_rc=0; (cd "$TMP" && AC_HOME=/nonexistent/ac-eb LC_ALL=C "$obin/ac-epic-branch.sh" $args) >/dev/null 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && AC_HOME=/nonexistent/ac-eb LC_ALL=C "$BIN/ac-epic-branch.sh" $args) >/dev/null 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "1 1" "unreadable home '$args': both exit 1"
  assert_contains "$(cat "$TMP/o.err")" "No such file or directory" "unreadable home: the original fails in cd (shell-own stderr)"
  assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not a readable directory: /nonexistent/ac-eb" "unreadable home: the port names the variable"
done
# the fence and the arity check precede the home
for args in "create eppy proj" "retire eppy"; do
  o_rc=0; (cd "$TMP" && AC_HOME= AC_SCOPE=x LC_ALL=C "$obin/ac-epic-branch.sh" $args) 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && AC_HOME= AC_SCOPE=x LC_ALL=C "$BIN/ac-epic-branch.sh" $args) 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "1 1" "homeless scoped '$args': both refuse"
  assert_eq "$(cat "$TMP/n.err")" "$(cat "$TMP/o.err")" "homeless scoped '$args': the fence, whole"
  assert_contains "$(cat "$TMP/n.err")" "CREWCHIEF" "homeless scoped '$args': the fence first"
done
o_rc=0; (cd "$TMP" && AC_HOME= "$obin/ac-epic-branch.sh" create eppy) 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (cd "$TMP" && AC_HOME= "$BIN/ac-epic-branch.sh" create eppy) 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "1 1" "homeless usage: both exit 1"
assert_eq "$(cat "$TMP/n.err")" "$(cat "$TMP/o.err")" "homeless: usage is checked before the home"
# 17. a record this process cannot read: exit and stdout agree; the oracle's
#     stderr carries head/awk/cat's own lines before (or instead of) the
#     refusal, not reproduced. Root reads a mode-000 file, so unprivileged only.
if [ "$(id -u)" -ne 0 ]; then
  both rec locked 'proj epic/l\n'
  chmod 000 "$OH/data/locked/branches" "$NH/data/locked/branches"
  for args in "create locked proj" "show locked" "retire locked"; do
    o_rc=0; run_oracle $args || o_rc=$?
    n_rc=0; run_shim $args || n_rc=$?
    assert_eq "$n_rc $o_rc" "1 1" "unreadable record '$args': both exit 1"
    assert_eq "$(norm "$TMP/n.raw" "$NH")" "$(norm "$TMP/o.raw" "$OH")" "unreadable record '$args': the same stdout"
    assert_eq "$(tail -n 1 "$TMP/n.err")" "$(tail -n 1 "$TMP/o.err" | grep '^ERROR:' || true)" "unreadable record '$args': the port's stderr is the refusal alone"
  done
  chmod 644 "$OH/data/locked/branches" "$NH/data/locked/branches"
  assert_eq "$(cat "$NH/data/locked/branches")" "proj epic/l" "an unreadable record is left as it was"
fi

pass
