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
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
# A roomchief's cwd IS the primary checkout (ac-spawn.sh's roomchief path sets root=$(ac_root)),
# so own tree == primary and the geometry allows it - no special case needed.

assert_eq "$(hook "$repo" chief Edit file_path "$repo/AGENTS.md")" "0" \
  "a roomchief whose own tree IS the primary may write it"
# The captain carries neither crew scalar - D2 of the commit guard - so their
# own session is never fenced, even when it runs inside a leased worktree.
assert_eq "$(hook "$wt" captain Edit file_path "$repo/AGENTS.md")" "0" \
  "the captain (no AC_CREW_ID/AC_SCOPE) is never fenced"

# --- shapes this guard never classifies --------------------------------------
# ensure_gitignore (ac-tree.sh) legitimately writes the primary, and so do
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

# --- the verdicts, row by row -------------------------------------------------
# Each row is judged with CDPATH, AC_CREW_ID and AC_SCOPE unset unless it sets
# one, under LC_ALL=C.
pl() { printf "$1" >"$TMP/pg.pl"; }  # pl <printf format> - the payload bytes of the rows after it
verdict() {  # verdict <0|2> <cwd> [env words...] - the exit, a silent stdout, and a refusal on stderr exactly when denied
  local want="$1" cwd="$2" rc=0
  shift 2
  (cd "$cwd" && env -u CDPATH -u AC_CREW_ID -u AC_SCOPE "$@" LC_ALL=C "$BIN/ac-primary-guard.sh" <"$TMP/pg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || rc=$?
  assert_eq "$rc" "$want" "verdict in $cwd ($*): $(cat "$TMP/pg.pl")"
  assert_eq "$(cat "$TMP/n.out")" "" "nothing on stdout in $cwd ($*)"
  case "$want:$(cat "$TMP/n.err")" in
    2:*"REFUSED"*|0:) ;;
    *) fail "stderr for verdict $want in $cwd ($*): $(cat "$TMP/n.err")" ;;
  esac
}
edit() {  # edit <0|2> <cwd> <tool> <field> <path> [env words...] - one path, judged as crewmate pg1
  local want="$1" cwd="$2" tool="$3" field="$4" path="$5"
  shift 5
  printf '{"tool_name":"%s","tool_input":{"%s":"%s"}}' "$tool" "$field" "$path" >"$TMP/pg.pl"
  verdict "$want" "$cwd" AC_CREW_ID=pg1 "$@"
}
pgpath() {  # pgpath <dir> <tool...> - a PATH dir holding exactly these host tools
  local d="$1" t
  shift
  mkdir -p "$d"
  for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
}

# 1. who is fenced, and which tool shapes carry a path.
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\"}}"
verdict 0 "$wt" AC_CREW_ID= AC_SCOPE=
edit 0 "$wt" NotebookEdit file_path "$repo/nb.ipynb"
edit 0 "$wt" Edit notebook_path "$repo/AGENTS.md"
for t in MultiEdit edit; do
  edit 0 "$wt" "$t" file_path "$repo/AGENTS.md"
done

# 2. the geometry: own tree first, then the primary, every target physical.
mkdir -p "$repo/sub"
ln -s "$repo" "$TMP/pg-link"
for p in "$repo/sub/new.md" "$repo/sub/" "$repo/" "$repo/.crew/x.md" "$TMP/pg-link/AGENTS.md" \
         "$wt/../../AGENTS.md" ../../../sub/x "$repo//sub///x" "$repo/./sub/./x"; do
  edit 2 "$wt" Edit file_path "$p"
done
for p in AGENTS.md ./x.md "$repo" / "$wt/no/such/x" "$TMP/elsewhere.md"; do
  edit 0 "$wt" Edit file_path "$p"
done
edit 0 "$repo" Edit file_path "$repo/AGENTS.md"

# 3. the payload's reads: blank lines are no payload; a value printed before a
# parse error counts; NULs are dropped and trailing LFs stripped; a byte that
# is no UTF-8 stays a path byte.
pl '\n\n'
verdict 0 "$wt" AC_CREW_ID=pg1
for p in "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\"}} junk" \
         "{\"tool_name\":\"Ed\\\\u0000it\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\\\\n\"}}" \
         "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$repo/sub/\\351.md\"}}"; do
  pl "$p"
  verdict 2 "$wt" AC_CREW_ID=pg1
done

# a file_path that is no JSON string is a TYPE, not a path judged by its JSON
# text - and a payload holding a second JSON value is multiple documents, not
# a wider tool name. Both deny, regardless of the own-tree cwd.
for p in "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":[\"$repo/AGENTS.md\"]}}" \
         '{"tool_name":"Edit","tool_input":{"file_path":{"a":1}}}' \
         '{"tool_name":"Edit","tool_input":{"file_path":5}}' \
         '{"tool_name":"Edit","tool_input":{"file_path":true}}' \
         '{"tool_name":"Edit","tool_input":{"file_path":false}}'; do
  pl "$p"
  verdict 2 "$wt" AC_CREW_ID=pg1
done
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\"}}{\"tool_name\":\"Edit\"}"
verdict 2 "$wt" AC_CREW_ID=pg1
# a second document with no tool_name of its own never shows up in the name
# check above (zero output for it), yet still joins the sentinel of a bad
# first value - caught on an exact match alone, it would slip through.
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":[\"$repo/AGENTS.md\"]}}{\"tool_input\":{\"file_path\":\"$TMP/x\"}}"
verdict 2 "$wt" AC_CREW_ID=pg1

# 4. a dependency that is missing, or a cwd with no name: allowed.
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\"}}"
pgpath "$TMP/pg-nojq" bash env cat dirname git bun
verdict 0 "$wt" AC_CREW_ID=pg1 PATH="$TMP/pg-nojq"
pgpath "$TMP/pg-nogit" bash env cat dirname jq bun
verdict 0 "$wt" AC_CREW_ID=pg1 PATH="$TMP/pg-nogit"
gone="$TMP/pg-gone"
mkdir -p "$gone"
rc=0
out="$(cd "$gone" && rmdir "$gone" && env AC_CREW_ID=pg1 LC_ALL=C "$guard" <"$TMP/pg.pl" 2>/dev/null)" || rc=$?
assert_eq "$rc:$out" "0:" "a cwd with no name allows"

# 5. the shim: no bun on PATH refuses at once, naming bun; a module that
# cannot load is a no-op, never a refusal.
pgpath "$TMP/pg-nobun" bash env cat dirname jq git
n_rc=0; (cd "$wt" && env AC_CREW_ID=pg1 PATH="$TMP/pg-nobun" LC_ALL=C "$guard" <"$TMP/pg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "2" "BUN: the shim refuses with no bun on PATH"
assert_eq "$(cat "$TMP/n.out")" "" "BUN: the shim's refusal writes nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "ac-primary-guard.sh: REFUSED - bun is not on PATH" "BUN: the shim's refusal names bun"
pg_lf="$TMP/pg-loadfail"
mkdir -p "$pg_lf/bin" "$pg_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-primary-guard.sh" "$pg_lf/bin/"
printf 'throw new Error("primary guard cannot load");\n' >"$pg_lf/src/primary-guard.ts"
n_rc=0; (cd "$wt" && AC_CREW_ID=pg1 LC_ALL=C "$pg_lf/bin/ac-primary-guard.sh" <"$TMP/pg.pl") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "0" "BUN: a module that cannot load allows"
assert_eq "$(cat "$TMP/n.out")" "" "BUN: a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "primary guard cannot load" "BUN: the load failure is bun's own diagnosis"
assert_contains "$(cat "$TMP/n.err")" "ac-primary-guard.sh: src/primary-guard.ts exited 1 - this hook did nothing" "BUN: the shim says it did nothing"
case "$(cat "$TMP/n.err")" in *"ac-primary-guard:"*) fail "BUN: a module that cannot load must never print the refusal" ;; esac

# 6. the target's directory: a relative one is entered without CDPATH (an
# exported CDPATH naming the primary must not send `sub/x` to its namesake);
# one whose name ends in LF is the directory it names, not its sibling the
# primary; `..` is walked from the physical cwd, so a cwd entered through a
# symlink climbs out of the worktree it really is.
printf '{"tool_name":"Edit","tool_input":{"file_path":"sub/x"}}' >"$TMP/pg.pl"
verdict 0 "$wt" AC_CREW_ID=pg1 CDPATH="$repo"
mkdir -p "$repo
"
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo\\\\n/x\"}}"
verdict 0 "$wt" AC_CREW_ID=pg1
ln -s "$wt" "$TMP/pg-wtlink"
printf '{"tool_name":"Edit","tool_input":{"file_path":"../AGENTS.md"}}' >"$TMP/pg.pl"
verdict 2 "$TMP/pg-wtlink" AC_CREW_ID=pg1
# A cwd whose name ends in a backslash (Bun before 1.4.4 could not enter it):
# an absolute and a relative target judge alike.
mkdir -p "$wt/bs\\"
pl "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$repo/AGENTS.md\"}}"
verdict 2 "$wt/bs\\" AC_CREW_ID=pg1
printf '{"tool_name":"Edit","tool_input":{"file_path":"../../../../AGENTS.md"}}' >"$TMP/pg.pl"
verdict 2 "$wt/bs\\" AC_CREW_ID=pg1

pass
