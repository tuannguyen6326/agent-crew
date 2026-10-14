#!/usr/bin/env bash
# ac-spawn-lease-install.test.sh - the captain-owned commands.install runs in a
# crew spawn's fresh lease before the crewmate starts (contract: THE LEASE
# INSTALL in src/spawn.ts's header):
#   - no key => nothing runs and the meta carries no deps= (the spawn as before),
#   - exit 0 on a clean tree => deps=ok, the command ran in the worktree with
#     AC_LEASE_PRIMARY naming the primary checkout,
#   - a non-zero exit, a timeout or a tree the command left dirty => the spawn
#     still succeeds, one WARN names the cause (the dirty paths), the meta
#     carries deps=failed and the kickoff tells the crewmate to install itself,
#   - a scout never installs; an orca lease installs the same way.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
export AC_SPAWN_SETTLE=0
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5
export AC_HERDR_RPC_TIMEOUT=10

make_home
repo="$(make_repo proj)"
printf 'node_modules/\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm ignore
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-fake"

meta_field() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"; }
set_install() { printf 'commands:\n  install: %s\n' "$1" >"$AC_HOME/projects/proj.yaml"; }
spawn() { # spawn <id> [flags...] -> stderr in $TMP/<id>.err
  local id="$1"; shift
  "$BIN/ac-brief.sh" "$id" proj --mode local-only >/dev/null
  "$BIN/ac-spawn.sh" "$id" "$repo" --harness fake --mode local-only "$@" >/dev/null 2>"$TMP/$id.err" \
    || fail "$id: the spawn must succeed whatever the install did ($(cat "$TMP/$id.err"))"
}
NOTE="install the project's dependencies yourself before running any test or build"

# --- no key: byte-for-byte the spawn as before ---------------------------------
spawn n1
assert_eq "$(meta_field "$AC_HOME/state/n1.meta" deps)" "" "no commands.install records no deps="
case "$(cat "$TMP/n1.err")" in *commands.install*) fail "no key must WARN nothing: $(cat "$TMP/n1.err")" ;; esac
case "$(cat "$AC_HOME/data/n1/kickoff.md")" in *"$NOTE"*) fail "no key must add nothing to the kickoff" ;; esac
"$BIN/ac-teardown.sh" n1 --force >/dev/null 2>&1

# --- success: run in the worktree, the primary named, deps=ok ------------------
set_install "'mkdir -p node_modules && pwd -P >node_modules/where && printf %s \"\$AC_LEASE_PRIMARY\" >node_modules/primary'"
spawn i1
wt="$(meta_field "$AC_HOME/state/i1.meta" worktree)"
assert_eq "$(cat "$wt/node_modules/where" 2>/dev/null)" "$(cd "$wt" && pwd -P)" "the install runs with the worktree as its cwd"
assert_eq "$(cat "$wt/node_modules/primary" 2>/dev/null)" "$repo" "AC_LEASE_PRIMARY names the primary checkout"
assert_eq "$(meta_field "$AC_HOME/state/i1.meta" deps)" "ok" "a clean successful install records deps=ok"
case "$(cat "$TMP/i1.err")" in *commands.install*) fail "a good install must WARN nothing: $(cat "$TMP/i1.err")" ;; esac
"$BIN/ac-teardown.sh" i1 --force >/dev/null 2>&1

# --- a failing command: WARN, deps=failed, the kickoff sentence ---------------
set_install '"exit 3"'
spawn f1
assert_contains "$(cat "$TMP/f1.err")" "WARN: commands.install failed for f1 (exit 3)" "a failed install is WARNed with its status"
assert_eq "$(meta_field "$AC_HOME/state/f1.meta" deps)" "failed" "a failed install records deps=failed"
assert_contains "$(cat "$AC_HOME/data/f1/kickoff.md")" "$NOTE" "the kickoff tells the crewmate the install failed"
"$BIN/ac-teardown.sh" f1 --force >/dev/null 2>&1

# --- a dirtied tracked file: failure, the path named, nothing restored ---------
# DISPUTED: whether the command leaves the tree dirty. HELD-CONSTANT: the same
# repo, exit status 0 and spawn flags as the success row above.
set_install '"printf changed >file.txt"'
spawn d1
wt="$(meta_field "$AC_HOME/state/d1.meta" worktree)"
assert_contains "$(cat "$TMP/d1.err")" "left the worktree dirty: file.txt" "a dirty tree is WARNed naming the path"
assert_eq "$(meta_field "$AC_HOME/state/d1.meta" deps)" "failed" "a dirty tree records deps=failed"
assert_eq "$(cat "$wt/file.txt")" "changed" "the distro restores nothing the command dirtied"
"$BIN/ac-teardown.sh" d1 --force >/dev/null 2>&1

# --- a hung command: the bound ends it, failure ----------------------------------
set_install '"sleep 30"'
t0=$SECONDS
AC_LEASE_INSTALL_TIMEOUT=1 spawn h1
[ $((SECONDS - t0)) -lt 20 ] || fail "the install bound must end a hung command (took $((SECONDS - t0))s)"
assert_contains "$(cat "$TMP/h1.err")" "timed out after 1s" "a timed-out install is WARNed as such"
assert_eq "$(meta_field "$AC_HOME/state/h1.meta" deps)" "failed" "a timed-out install records deps=failed"
"$BIN/ac-teardown.sh" h1 --force >/dev/null 2>&1

# --- a scout reads code and never builds: no install ------------------------------
set_install '"exit 3"'
"$BIN/ac-brief.sh" sc1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" sc1 "$repo" --harness fake --scout >/dev/null 2>"$TMP/sc1.err" || fail "the scout spawn must succeed"
assert_eq "$(meta_field "$AC_HOME/state/sc1.meta" deps)" "" "a scout records no deps="
"$BIN/ac-teardown.sh" sc1 --force >/dev/null 2>&1

# --- an orca lease installs the same way --------------------------------------------
make_fake_orca
printf '\342\234\263 fake\n' >"$FAKE_ORCA/.default-title"
printf 'orca\n' >"$AC_HOME/config/backend"
set_install "'mkdir -p node_modules && printf %s \"\$AC_LEASE_PRIMARY\" >node_modules/primary'"
spawn o1
owt="$(meta_field "$AC_HOME/state/o1.meta" worktree)"
case "$owt" in "$FAKE_ORCA/orca-wt/"*) ;; *) fail "fixture: the worktree must be orca-managed (got: $owt)" ;; esac
assert_eq "$(cat "$owt/node_modules/primary" 2>/dev/null)" "$repo" "the orca lease runs the install with the primary named"
assert_eq "$(meta_field "$AC_HOME/state/o1.meta" deps)" "ok" "the orca lease records deps=ok"
"$BIN/ac-teardown.sh" o1 --force >/dev/null 2>&1

pass
