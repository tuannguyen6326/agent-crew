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

pass
