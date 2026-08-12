#!/usr/bin/env bash
# ac-primary-guard.test.sh - the PreToolUse fence that keeps a crewmate (or a
# roomchief) from EDITING a file that lives in the PRIMARY checkout but outside
# its own tree. The commit door was closed by the pre-commit guard
# (ac-commit-guard.test.sh); this is the EDIT door, walked through for a
# MEASURED second time 2026-07-27 (a crewmate Edited the primary's AGENTS.md
# from its own worktree, then verified in the worktree and saw an empty diff).
#
# TEST SAFETY: every repo here is a throwaway from helpers.sh make_repo / $TMP;
# the guard is a pure stdin->exit-code filter and writes nothing anywhere.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

guard="$BIN/ac-primary-guard.sh"

repo="$(make_repo)"
wt="$("$BIN/ac-tree.sh" get --repo "$repo" --id pg1 --holder crew:pg1 2>/dev/null)"
[ -d "$wt" ] || fail "fixture: a leased worktree is needed"

# hook <cwd> <who> <tool> <field> <path> -> the guard's exit code there.
# <who>: crew (AC_CREW_ID) | chief (AC_SCOPE) | captain (neither).
hook() {
  local cwd="$1" who="$2" tool="$3" field="$4" path="$5" rc=0 crew="" scope=""
  case "$who" in crew) crew=pg1 ;; chief) scope=fam1 ;; esac
  ( cd "$cwd" \
    && printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$tool" "$field" "$path" \
    | AC_CREW_ID="$crew" AC_SCOPE="$scope" "$guard" >/dev/null 2>&1 ) || rc=$?
  printf '%s\n' "$rc"
}

# --- the observed incident: a crewmate Edits the primary from its worktree ----

assert_eq "$(hook "$wt" crew Edit file_path "$repo/AGENTS.md")" "2" \
  "a crewmate editing the primary checkout from its worktree is refused"
assert_eq "$(hook "$wt" crew Write file_path "$repo/AGENTS.md")" "2" \
  "Write into the primary is refused too"
assert_eq "$(hook "$wt" crew NotebookEdit notebook_path "$repo/nb.ipynb")" "2" \
  "NotebookEdit uses notebook_path and is refused too"
assert_eq "$(hook "$wt" chief Edit file_path "$repo/AGENTS.md")" "2" \
  "a SCOPED session outside the primary is fenced by the same geometry"
# Resolution, not string prefixing: a relative path that climbs out of the
# worktree lands in the primary and is refused just the same.
assert_eq "$(hook "$wt" crew Edit file_path "../../../AGENTS.md")" "2" \
  "a relative path climbing out of the worktree resolves into the primary"

err="$(cd "$wt" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/AGENTS.md"}}' "$repo" \
  | AC_CREW_ID=pg1 "$guard" 2>&1 >/dev/null)" || true
assert_contains "$err" "$repo/AGENTS.md" "the refusal names the primary path it refused"
assert_contains "$err" "$wt/AGENTS.md" "the refusal names the worktree-relative path the crewmate meant"
assert_contains "$err" "STOP and REPORT" "the refusal teaches the sanctioned recovery"
assert_contains "$err" "git checkout --" "the refusal names git checkout -- as forbidden there"
assert_contains "$err" "git restore" "the refusal names git restore as forbidden there"
assert_contains "$err" "git reset --hard" "the refusal names git reset --hard as forbidden there"

# --- the crewmate's OWN tree is a subtree of the primary: never fenced --------

assert_eq "$(hook "$wt" crew Edit file_path "$wt/AGENTS.md")" "0" \
  "a crewmate editing its own worktree is allowed (own tree wins over the primary prefix)"
assert_eq "$(hook "$wt" crew Write file_path "$wt/new-thing.sh")" "0" \
  "a new file inside the crewmate's own tree is allowed"
# The parent must EXIST, or this passes on the unresolvable-target fail-open
# below instead of on the containment test it is here to prove.
mkdir -p "$AC_HOME/data/pg1"
assert_eq "$(hook "$wt" crew Edit file_path "$AC_HOME/data/pg1/report.md")" "0" \
  "a path outside the primary checkout entirely (the fleet home) is not this guard's business"

# --- a CHIEF's legitimate primary writes keep working (hard constraint 2) -----
# A roomchief's cwd IS the primary checkout (ac-spawn.sh:973 root=$(ac_root)),
# so own tree == primary and the geometry allows it - no special case needed.

assert_eq "$(hook "$repo" chief Edit file_path "$repo/AGENTS.md")" "0" \
  "a roomchief whose own tree IS the primary may write it"
# The captain carries neither crew scalar - D2 of the commit guard - so their
# own session is never fenced, even when it runs inside a leased worktree.
assert_eq "$(hook "$wt" captain Edit file_path "$repo/AGENTS.md")" "0" \
  "the captain (no AC_CREW_ID/AC_SCOPE) is never fenced"

# --- shapes this guard never classifies --------------------------------------
# ensure_gitignore (ac-tree.sh:120) legitimately writes the primary, and so do
# the lease helpers - all SHELL writes, which never reach an Edit/Write hook.
# The same residual ac-ledger-guard.sh already accepts: Bash gets through.

assert_eq "$(hook "$wt" crew Bash command 'printf x >>"$repo/.gitignore"')" "0" \
  "Bash is not fenced by this guard (residual: a shell write still gets through)"
assert_eq "$(hook "$wt" crew Read file_path "$repo/AGENTS.md")" "0" \
  "reading the primary is never refused"
rc=0
( cd "$wt" && printf '{"tool_name":"mcp__thing__Edit","tool_input":{"file_path":"%s/AGENTS.md"}}' "$repo" \
  | AC_CREW_ID=pg1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an mcp__ name is never classified"

# --- fail OPEN, every way (hard constraint 3) --------------------------------

for payload in '' 'not json' '{"tool_input":{"file_path":"x"}}' '{"tool_name":"Edit","tool_input":{}}'; do
  rc=0
  ( cd "$wt" && printf '%s' "$payload" | AC_CREW_ID=pg1 "$guard" >/dev/null 2>&1 ) || rc=$?
  assert_eq "$rc" "0" "a payload that cannot be classified fails open: ${payload:-<empty>}"
done

# A git that errors on every call: the geometry is unknowable, so allow.
stub="$TMP/failgit"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 3\n' >"$stub/git"; chmod +x "$stub/git"
rc=0
( cd "$wt" && printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/AGENTS.md"}}' "$repo" \
  | PATH="$stub:$PATH" AC_CREW_ID=pg1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a rev-parse that errors fails OPEN, never wedging the harness"

# A session that is not in a git checkout at all (a chief in a seeded fleet home).
assert_eq "$(hook "$AC_HOME" chief Edit file_path "$repo/AGENTS.md")" "0" \
  "a cwd that is no git checkout fails open"

# A target whose parent directory does not exist cannot be resolved - fail open.
# NAMED RESIDUAL: a write creating a brand-new directory tree in the primary is
# not caught; the observed incident (a root file that exists) is.
assert_eq "$(hook "$wt" crew Write file_path "$repo/no/such/dir/x.md")" "0" \
  "an unresolvable target fails open (named residual)"

# --- wiring: the hook is registered like its three siblings ------------------

settings="$ROOT/.claude/settings.json"
jq -e '[.hooks.PreToolUse[].hooks[].command] | any(contains("ac-primary-guard.sh"))' \
  "$settings" >/dev/null || fail "PreToolUse hook not registered in .claude/settings.json"
jq -e '[.hooks.PreToolUse[].hooks[].command] | any(contains("ac-ledger-guard.sh"))' \
  "$settings" >/dev/null || fail "the sibling ledger guard must stay registered"

pass
