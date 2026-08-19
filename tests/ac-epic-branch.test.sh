#!/usr/bin/env bash
# ac-epic-branch.test.sh - the per-epic integration-branch record and verbs:
# the archive-aware record resolver (live -> data/archive/<year>/, never a
# silent fail-open after a family move), create (cuts at the freshest default
# tip, idempotent, never moves an existing branch), verify (quiet, gate-able,
# refuses a retired record), retire (chief-writes-the-end marker), and the
# chief-only fence on the mutating verbs (a scoped chief reads, the crewchief
# cuts - the domain_chief_only pattern, because a PreToolUse hook cannot see
# a bash verb).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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
out="$("$BIN/ac-brief.sh" solo1-spec proj --stage spec --review no 2>&1 || true)"
assert_contains "$out" "staged flow requires review=yes" \
  "a NON-epic staged task still refuses --review no"
"$BIN/ac-brief.sh" eppy3-s3 proj >/dev/null
s3b="$(cat "$AC_HOME/data/eppy3-s3/brief.md")"
assert_contains "$s3b" -- "--target epic/eppy3" "a crew-ship epic story's brief names the engine target"
assert_contains "$s3b" "Review: yes" "crew-ship keeps its pipeline round (story-sized via the target)"
"$BIN/ac-brief.sh" eppy3-s4 proj >/dev/null
assert_contains "$(cat "$AC_HOME/data/eppy3-s4/brief.md")" "epic integration branch" \
  "a direct-pr epic story's brief names the PR base"

pass
