#!/usr/bin/env bash
# ac-tree.sh - pooled git worktrees INSIDE the target repo. Worktrees live at
# <repo>/.crew/worktrees/<n>, and /.crew/ is auto-ignored via
# .git/info/exclude. On the first lease, `get` also installs a shared
# pre-commit guard into the default git-common-dir/hooks that refuses a
# crewmate/roomchief commit made in the PRIMARY checkout - see
# ensure_commit_guard for its full contract.
#
# Worktrees are detached-HEAD, reset to the freshest default-branch ref on
# acquire, and REUSED - returning a worktree never deletes it, so dependency
# and build caches survive between crewmates.
#
# Usage:
#   ac-tree.sh get    --repo <path> [--id <task>] [--holder <label>]
#                     [--owner <pid>] [--prefer <path-or-slot-n>]
#   ac-tree.sh list   --repo <path>
#   ac-tree.sh return <worktree-path> [--force] [--if-lease-id <id>]
#   ac-tree.sh prune  --repo <path> [--yes]
#   ac-tree.sh remove <worktree-path> [--force] [--include-leased]
#
# get --prefer <path-or-slot-n>: slot affinity for session resumes (claude
# keys sessions by cwd). When the preferred slot - given as a pool worktree
# path or a bare slot number - is AVAILABLE (not leased, not
# available-but-dirty), it is leased exactly; any other state falls back to
# the normal selection and prints ONE warning line:
#   prefer: slot <n> unavailable (<why>) - leased slot <m> instead
#
# get --id, a SECOND time: when state/<id>.meta already exists for --id, get
# appends the newly leased path (and its lease_id) to that meta's leases=/
# lease_ids= (grammar: the LEASES block in ac-spawn.sh) - the mechanism by
# which ac-teardown.sh later returns EVERY tree a task holds, not only the one
# taken at spawn. A task's own FIRST lease never triggers this: spawn and
# ac-self-task.sh write state/<id>.meta only after that first get returns, so
# the append stays a silent no-op until the meta exists - which also keeps a
# verifier's lease (a distinct id that never gets a crew meta) out of it, and
# never mints a stray meta file for one.
#
# return --if-lease-id <id>: bind the return to the acquisition that took the
# slot. A slot is identified by PATH, and a path is REUSED, so a return that
# arrives after the slot was released and re-leased would otherwise kill the
# processes and reset the tree of whichever task holds it NOW - work lost with
# no error addressed to its owner. With the flag, a mismatch REFUSES before
# anything destructive runs. --force does not cover this: it authorizes
# discarding the CALLER's leftovers, and by then the tree is not the caller's.
# The id is minted per acquisition (mint_lease_id), recorded as lease_id= in
# the slot meta, dies with the lease, and is threaded through the crew meta as
# lease_ids= (grammar: the LEASES block in ac-spawn.sh). Omitting the flag
# keeps the old unconditional behavior, so a pool or a meta that predates the
# id needs no migration.
#
# Safety model:
# - every mutating operation holds the slot exclusively: pool state changes
#   run under the pool lock, and the one section that cannot (return's
#   proc-kill and tree reset would hold it across an lsof of the whole tree, a
#   2s kill grace and a full checkout/reset/clean, against the 30s timeout
#   every other caller waits on) CLAIMS the slot under that lock first, which
#   re-owns the lease to the returning process - see claim_return;
# - a lease with a dead --owner pid self-heals to available;
# - dirty slots are never silently reset (return needs --force to discard);
# - a return naming a lease id the slot no longer holds is refused;
# - prune only removes clean, merged, unleased, process-free slots, and
#   refuses to verify "merged" against a stale or unreachable origin;
# - remove refuses leased slots without --include-leased and refuses
#   dirty, clean-but-unmerged, or unreadable-because-broken work without
#   --force - it is the deliberate exit for a slot heal declines to touch;
# - a slot whose worktree DIR vanished, and an orphan dir from a partial
#   create, are healed (removed) by get/list/prune; a slot whose dir survives
#   with a broken gitdir is left alone and named instead - git can no longer
#   report what is in it, so it may be unlanded work.
#
# Pool layout inside the target repo:
#   .crew/worktrees/<n>/   worktree working dirs; <n> is <number>-<repo-name>
#                          for newly minted slots (legacy bare numbers stay
#                          valid - the id is opaque everywhere but the
#                          highest-number scan, which reads the prefix)
#   .crew/slots/<n>.meta   per-slot state (key=value, atomic rewrite), incl.
#                          lease_id= - one opaque identity per acquisition
#   .crew/lock/            mkdir lock guarding slot state
#   .crew/config           optional: max_trees=<n> (default 8)
#   .crew/<repo>.code-workspace  GENERATED active-task workspace FILE: the repo
#                          plus one folder per LEASED worktree, so VSCode/
#                          Cursor shows active task trees as their OWN
#                          repositories without filling the Git tab with idle
#                          pool slots. Folder names carry the lease
#                          (`wt<n> - <task>`). Regenerated after every slot
#                          mutation - never hand-edit it. This script updates
#                          the file; it does not control a live editor window.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ac-lib.sh"

pool_dir() { printf '%s/.crew\n' "$1"; }
slot_meta() { printf '%s/slots/%s.meta\n' "$(pool_dir "$1")" "$2"; }
slot_path() { printf '%s/worktrees/%s\n' "$(pool_dir "$1")" "$2"; }

write_workspace() {
  # Regenerate <repo>/.crew/<repo>.code-workspace from ACTIVE leases only
  # (header: pool layout). Derived and regenerable, so it runs AFTER the locked
  # mutation, not under the lock: concurrent regens both render a fresh view
  # and the last writer wins. Slot ids and task ids are [a-z0-9-], so no JSON
  # escaping is needed.
  local repo="$1" ws meta n label task leased folders
  ws="$(pool_dir "$repo")/$(basename "$repo").code-workspace"
  folders="    { \"path\": \"..\", \"name\": \"$(basename "$repo") (main)\" }"
  for meta in "$(pool_dir "$repo")"/slots/*.meta; do
    [ -f "$meta" ] || continue
    n="$(basename "$meta" .meta)"
    [ -d "$(slot_path "$repo" "$n")" ] || continue
    leased="$(ac_meta_get "$meta" leased)"
    [ "$leased" = 1 ] || continue
    label="wt$n"
    task="$(ac_meta_get "$meta" task)"
    [ -n "$task" ] && label="wt$n - $task"
    folders="$folders,
    { \"path\": \"worktrees/$n\", \"name\": \"$label\" }"
  done
  printf '{\n  "folders": [\n%s\n  ]\n}\n' "$folders" >"$ws.tmp.$$"
  mv "$ws.tmp.$$" "$ws"
}

pool_max_trees() {
  # AC_MAX_TREES env > <repo>/.crew/config max_trees= > 8
  local repo="$1" cfg v
  if [ -n "${AC_MAX_TREES:-}" ]; then printf '%s\n' "$AC_MAX_TREES"; return 0; fi
  cfg="$(pool_dir "$repo")/config"
  if [ -f "$cfg" ]; then
    v="$(ac_meta_get "$cfg" max_trees)"
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  fi
  printf '8\n'
}

ensure_gitignore() {
  # Ignore /.crew/ per-clone via .git/info/exclude - never tracked, invisible
  # to the project, so the clone stays clean in `git status` and the rule can
  # never be committed upstream. The path is resolved with `git rev-parse
  # --git-path` so a linked worktree (where .git is a FILE pointing at the
  # real gitdir) lands the rule where git actually reads it. Guard against a
  # final exclude line with no trailing newline - blind appending would
  # corrupt it.
  # Self-heal: an exact '/.crew/' line an earlier version appended to the
  # TRACKED .gitignore is removed - and ONLY it - so previously-dirtied
  # clones come back clean; a line already committed in HEAD is project
  # content, not ours to strip. A .gitignore left empty by the removal is
  # deleted only when git does not track it (we created it from scratch).
  local repo="$1" gi="$1/.gitignore" ex
  ex="$(git -C "$repo" rev-parse --git-path info/exclude)"
  case "$ex" in /*) : ;; *) ex="$repo/$ex" ;; esac
  if ! grep -qxF '/.crew/' "$ex" 2>/dev/null; then
    mkdir -p "${ex%/*}"
    if [ -s "$ex" ] && [ -n "$(tail -c1 "$ex")" ]; then printf '\n' >>"$ex"; fi
    printf '/.crew/\n' >>"$ex"
    ac_warn "added /.crew/ to $ex"
  fi
  if [ -f "$gi" ] && grep -qxF '/.crew/' "$gi" \
    && ! git -C "$repo" show HEAD:.gitignore 2>/dev/null | grep -qxF '/.crew/'; then
    local tmp="$gi.tmp.$$"
    grep -vxF '/.crew/' "$gi" >"$tmp" || true
    if [ -s "$tmp" ] || git -C "$repo" ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
      mv "$tmp" "$gi"
    else
      rm -f "$tmp" "$gi"
    fi
    ac_warn "migrated: /.crew/ ignore moved to .git/info/exclude"
  fi
}

ensure_commit_guard() {
  # Install the shared pre-commit guard that REFUSES a commit made in the
  # PRIMARY checkout by a crewmate or roomchief (spec §5.2a, Q1=lease-time).
  # It lives in the DEFAULT shared git-common-dir/hooks, so ONE install at lease
  # time covers the primary checkout plus every existing and future linked
  # worktree (AC7). A custom core.hooksPath is SKIPPED fail-open (option A,
  # accepted): a relative value resolves per-worktree (not shared,
  # breaks AC7), a tracked dir would dirty the primary checkout, and /dev/null
  # (hooks disabled) would abort the lease - none worth handling for the observed
  # self-hosted failure. Provenance is BYTE-EXACT (the ensure_gitignore rule): an
  # installed hook of OURS that is byte-identical is left untouched, one that
  # DIFFERS (an older guard text, or a hand-edit) is replaced in place with its
  # previous bytes preserved in an epoch-stamped sidecar that is never executed
  # and never clobbers an earlier one, and a FOREIGN hook is CHAINED to
  # pre-commit.ac-crew-prev rather than clobbered (E1). Fail-open on any error -
  # the guard is a safety net, never a lease blocker.
  # Runs under the pool lock (cmd_get), so errexit is suppressed here: every
  # outcome that could clobber a project hook is checked explicitly.
  local repo="$1" hooksdir hook prev
  if git -C "$repo" config --get core.hooksPath >/dev/null 2>&1; then
    ac_warn "core.hooksPath is set; skipping commit-guard install (guard covers only the default shared hooks)"
    return 0
  fi
  hooksdir="$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)" || return 0
  [ -n "$hooksdir" ] || return 0
  hook="$hooksdir/pre-commit"
  # A symlink-managed hook (a hook manager's target) is left untouched: chaining
  # would dereference a live symlink into a static copy (severing updates through
  # the target) or clobber a dangling one. Skip fail-open, consistent with the
  # custom-core.hooksPath handling (option A). Our own guard is always a regular
  # file, so a symlink here is always someone else's.
  if [ -L "$hook" ]; then
    ac_warn "pre-commit is a symlink (hook-manager managed); skipping commit-guard install to leave it untouched ($hook)"
    return 0
  fi
  # The sentinel decides PROVENANCE only, never freshness: it cannot see the
  # heredoc below change, so a repo onboarded before an edit kept the old text
  # forever. The freshness compare needs the bytes we would write now, which the
  # staged $tmp holds - hence a flag here and the decision after staging.
  local ours=0
  if [ -f "$hook" ] && grep -q 'ac-crew-primary-commit-guard' "$hook" 2>/dev/null; then
    ours=1
  fi
  mkdir -p "$hooksdir"
  prev="$hooksdir/pre-commit.ac-crew-prev"
  # Failure-atomic install: stage the wrapper in a temp file, and only swap it
  # into place with an atomic rename AFTER a pre-existing foreign hook is
  # preserved. errexit is suppressed on the pool-lock callback path, so a failed
  # write/chmod/rename must never leave $hook empty, partial, or missing - that
  # would silently disable the project's own hook (the E1 invariant).
  local tmp="$hook.ac-crew-tmp.$$"
  if ! cat >"$tmp" <<'GUARD'
#!/usr/bin/env bash
# ac-crew-primary-commit-guard - REFUSE a git commit made in the PRIMARY
# checkout by a crewmate or roomchief. Installed once at lease time by
# ac-tree.sh; shared across the primary checkout and every linked worktree.
# D1 (WHERE): git-dir == git-common-dir  <=>  the PRIMARY checkout (a leased
#   worktree's git-dir is <common>/worktrees/<n> and never equals common).
# D2 (WHO):   AC_CREW_ID or AC_SCOPE set  <=>  a crewmate/roomchief. The captain
#   carries neither, so a captain commit is never refused.
# Fail-OPEN: any rev-parse error skips ONLY this guard, never fail-closed onto
#   the captain and never suppressing a chained project hook. --no-verify remains
#   a bypass, forbidden to crewmates by policy.
run_chained() {
  # Hand off to a preserved prior hook (E1) if present, else pass. Reached on
  # EVERY non-refuse path, including a fail-open rev-parse error.
  local prev; prev="$(dirname "$0")/pre-commit.ac-crew-prev"
  [ -x "$prev" ] && exec "$prev" "$@"
  exit 0
}
gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || run_chained "$@"
cm=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || run_chained "$@"
if [ "$gd" = "$cm" ] && { [ -n "${AC_CREW_ID:-}" ] || [ -n "${AC_SCOPE:-}" ]; }; then
  # D1 && D2: a crewmate/roomchief committing in the PRIMARY checkout. The
  # primary root is the git-common-dir's PARENT (<primary>/.git -> <primary>),
  # so no extra rev-parse is needed - and we are refusing regardless.
  printf 'ac-crew: REFUSED a commit in the PRIMARY checkout (%s).\n' "${cm%/*}" >&2
  printf 'ac-crew: commit in YOUR leased worktree on crew/<id>, never in the primary checkout.\n' >&2
  printf 'ac-crew: leave the primary working tree ALONE - no checkout/restore/reset; report the edit.\n' >&2
  exit 1
fi
run_chained "$@"
GUARD
  then
    rm -f "$tmp"
    ac_warn "could not stage commit guard; leaving any existing hook untouched ($hook)"
    return 0
  fi
  if ! chmod +x "$tmp"; then
    rm -f "$tmp"
    ac_warn "could not stage commit guard (chmod); leaving any existing hook untouched ($hook)"
    return 0
  fi
  if [ "$ours" = 1 ]; then
    # Ours and byte-identical: return silently, exactly as the sentinel check did.
    if cmp -s "$tmp" "$hook"; then
      rm -f "$tmp"
      return 0
    fi
    # Ours but DIFFERENT (an older guard text, or a hand-edit): replace in place,
    # preserving the previous bytes. The backup NEVER goes to
    # pre-commit.ac-crew-prev - that slot belongs to a chained project hook and
    # run_chained EXECs it, so our own old guard landing there would run as its
    # own chained hook. It is EPOCH-STAMPED, following ac_records_backup's
    # never-clobber convention (bin/ac-maintenance-lib.sh:189), not the single-slot
    # `<file>.prev` one (bin/ac-qa.sh:3051), which keeps ONE copy and would let a
    # second upgrade destroy a preserved hand-edit; git runs only the exact hook
    # names, so a stamped sidecar is never executed, and cp -p keeps the mode too
    # so a hand-edit is restorable as it was. An occupied $bak is NOT cleaned up
    # and must not be: it may hold an earlier hand-edit, and the next second's
    # stamp gets its own name anyway.
    local bak="$hook.ac-crew-stale-$(ac_now)"
    if [ -e "$bak" ] || ! cp -p "$hook" "$bak"; then
      rm -f "$tmp"
      ac_warn "could not preserve the outdated commit guard; leaving it in place ($hook)"
      return 0
    fi
    if ! mv "$tmp" "$hook"; then
      rm -f "$tmp"
      ac_warn "could not upgrade the outdated commit guard ($hook)"
      return 0
    fi
    ac_warn "upgraded the outdated primary-checkout commit guard at $hook (previous bytes kept at $bak)"
    return 0
  fi
  if [ -e "$hook" ]; then
    # Chain, never clobber (E1): preserve the foreign hook by COPYING it aside
    # (cp -p keeps its exec bit) - never move it, so $hook is never absent before
    # the swap. Sidecar already taken (a hook manager replaced our guard after an
    # earlier chain) -> skip fail-open, keeping the project's own pre-commit.
    if [ -e "$prev" ]; then
      rm -f "$tmp"
      ac_warn "pre-commit present and pre-commit.ac-crew-prev already taken; skipping commit-guard install to avoid clobbering a project hook ($hook)"
      return 0
    fi
    if ! cp -p "$hook" "$prev"; then
      rm -f "$tmp"
      ac_warn "could not preserve existing pre-commit hook; skipping commit-guard install to avoid clobbering it ($hook)"
      return 0
    fi
    ac_warn "chained existing pre-commit hook aside to pre-commit.ac-crew-prev"
  fi
  # Atomic swap: rename the staged wrapper over $hook (overwriting the foreign
  # copy just preserved, or creating it fresh) - $hook is never a partial file.
  if ! mv "$tmp" "$hook"; then
    rm -f "$tmp"
    ac_warn "could not install commit guard ($hook)"
    return 0
  fi
  ac_warn "installed primary-checkout commit guard at $hook"
}

resolve_repo() {
  local repo
  repo="$(ac_repo_root "$1")" || ac_die "not a git repository: $1"
  case "$repo" in
    */.crew/worktrees/*) ac_die "refusing to manage a pool inside a pool worktree: $repo" ;;
  esac
  printf '%s\n' "$repo"
}

freshest_ref() {
  # Freshest default-branch ref - delegates to THE shared resolver
  # (ac_freshest_ref, ac-lib.sh) so the pool and ac-epic-branch.sh can never
  # disagree about "the tip".
  ac_freshest_ref "$1"
}

reset_worktree() {
  # reset_worktree <repo> <wt> [<ref>] - detach onto <ref> (default: the
  # freshest default ref), drop local changes and untracked files (ignored
  # files survive: caches). The ref parameter is the epic-branch fence's
  # (cmd_get computes it); return/prune stay on the default - a released
  # slot's contract is the default base.
  # qa run state (.crew/qa) is swept explicitly - it is ignored, so clean
  # keeps it, and a stale ports.env/serve.pid must never leak to the next
  # lessee of the slot.
  # Explicit status checks: callers must handle failure, set -e may be off.
  local repo="$1" wt="$2" ref="${3:-}"
  rm -rf "$wt/.crew/qa" 2>/dev/null || true
  [ -n "$ref" ] || ref="$(freshest_ref "$repo")"
  git -C "$wt" checkout --detach --force --quiet "$ref" \
    && git -C "$wt" reset --hard --quiet "$ref" \
    && git -C "$wt" clean -fdq
}

fetch_origin() {
  # Best-effort for get; prune does its own verified fetch.
  local repo="$1"
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" fetch origin --quiet 2>/dev/null || ac_warn "fetch origin failed; using local refs"
  fi
}

is_dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

live_procs() {
  # live_procs <wt> - pids with cwd/open files under the worktree.
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -t +D "$1" 2>/dev/null | sort -u | grep -v "^$$\$" || true
}

kill_worktree_procs() {
  # SIGTERM, short grace, SIGKILL survivors (detached servers ignore SIGHUP).
  local wt="$1" pids
  pids="$(live_procs "$wt" || true)"
  [ -n "$pids" ] || return 0
  ac_warn "terminating processes still inside $wt"
  printf '%s\n' "$pids" | xargs kill 2>/dev/null || true
  sleep 2
  pids="$(live_procs "$wt" || true)"
  [ -n "$pids" ] && printf '%s\n' "$pids" | xargs kill -9 2>/dev/null || true
  return 0
}

drop_slot() {
  # drop_slot <repo> <n> - remove worktree dir + registration + meta.
  local repo="$1" n="$2" wt
  wt="$(slot_path "$repo" "$n")"
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$wt"
  rm -f "$(slot_meta "$repo" "$n")"
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
}

heal_slots() {
  # heal_slots <repo> - drop slots whose worktree DIRECTORY vanished: nothing
  # is left there to lose. A slot whose dir survives but whose gitdir pointer
  # is broken is NOT dropped - its files may be unlanded work, and the signal
  # that would prove otherwise is exactly the one a broken gitdir takes away:
  # is_dirty runs `git status --porcelain`, which fails EMPTY on such a tree
  # and so reports it CLEAN. heal runs automatically from get/list/prune, i.e.
  # at every spawn, so failing toward rm -rf there is silent and unrecoverable
  # while failing toward a skip costs a wedged slot - which the pool's own meta
  # (still readable when git is not) lets the warn name the exact reclaim for.
  # Run under the pool lock.
  local repo="$1" meta n wt flags
  for meta in "$(pool_dir "$repo")"/slots/*.meta; do
    [ -f "$meta" ] || continue
    n="$(basename "$meta" .meta)"
    wt="$(slot_path "$repo" "$n")"
    if [ ! -d "$wt" ]; then
      ac_warn "healed slot $n (worktree dir vanished)"
      drop_slot "$repo" "$n"
    elif ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
      flags="--force"
      if [ "$(ac_meta_get "$meta" leased)" = "1" ]; then flags="$flags --include-leased"; fi
      ac_warn "slot $n: worktree broken (gitdir unreadable) - NOT healed, its files may be unlanded work git can no longer report; reclaim it deliberately with: bin/ac-tree.sh remove $flags $wt"
    fi
  done
}

lease_reclaimable() {
  # lease_reclaimable <meta> - a lease whose recorded owner pid is provably
  # dead self-heals. No owner = durable.
  local meta="$1" owner
  owner="$(ac_meta_get "$meta" owner_pid)"
  [ -n "$owner" ] || return 1
  ! kill -0 "$owner" 2>/dev/null
}

with_pool_lock() {
  # with_pool_lock <repo> <fn> [args...] - run fn under the pool lock.
  local repo="$1" lock
  shift
  lock="$(pool_dir "$repo")/lock"
  mkdir -p "$(pool_dir "$repo")"
  ac_lock_acquire "$lock" 30 || ac_die "could not acquire pool lock: $lock"
  local rc=0
  "$@" || rc=$?
  ac_lock_release "$lock"
  return "$rc"
}

# --- get ---------------------------------------------------------------------

cmd_get() {
  local repo="" id="" holder="" owner="" prefer=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --id) id="$2"; shift 2 ;;
      --holder) holder="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --prefer) prefer="$2"; shift 2 ;;
      *) ac_die "get: unknown argument $1" ;;
    esac
  done
  [ -n "$repo" ] || ac_die "get: --repo is required"
  repo="$(resolve_repo "$repo")"
  if [ -n "$prefer" ]; then
    # Normalize a pool worktree path to its slot id.
    case "$prefer" in */*) prefer="${prefer%/}"; prefer="$(basename "$prefer")" ;; esac
    case "$prefer" in
      '') ac_die "get: --prefer expects a slot id/number or a pool worktree path" ;;
      [0-9]*-*) : ;; # already a full <number>-<repo> slot id
      *[!0-9]*) ac_die "get: --prefer expects a slot id/number or a pool worktree path" ;;
      *)
        # A bare number names the slot by its prefix (legacy call shape); a
        # legacy bare-numeric slot matches directly, a renamed slot by prefix.
        if [ ! -f "$(slot_meta "$repo" "$prefer")" ]           && [ -f "$(slot_meta "$repo" "$prefer-$(basename "$repo")")" ]; then
          prefer="$prefer-$(basename "$repo")"
        fi
        ;;
    esac
  fi
  git -C "$repo" rev-parse HEAD >/dev/null 2>&1 || ac_die "repository has no commits: $repo"
  ensure_gitignore "$repo"
  # Under the pool lock: the shared-hook install is a per-repo shared-state
  # mutation (sentinel-check/move/write), so two concurrent first leases must
  # not interleave it - an unlocked race can move our own fresh wrapper onto the
  # chained sidecar and self-exec forever.
  with_pool_lock "$repo" ensure_commit_guard "$repo"
  mkdir -p "$(pool_dir "$repo")/worktrees" "$(pool_dir "$repo")/slots"
  fetch_origin "$repo"
  # Epic-branch fence (epic-branch-mech): a lease for an id whose epic records
  # an integration branch for THIS repo is cut from that branch, and REFUSES
  # when the branch is missing - never a silent fall-through to the default
  # base. It lives HERE (not in ac-spawn) so the documented mid-task
  # second-lease path a crewmate takes itself, and the --prefer resume lease,
  # ride the same fence. ac_epic_base_for (ac-lib.sh) owns the resolution.
  local base_ref="" eb ebranch rname
  rname="$(basename "$repo")"
  if [ -n "$id" ] && eb="$(ac_epic_base_for "$id" "$rname")"; then
    ebranch="${eb%% *}"
    if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$ebranch" \
        || ac_die "get: epic branch $ebranch is not on origin of $rname - cut it first: ac-epic-branch.sh create <epic> $rname"
      base_ref="origin/$ebranch"
    else
      git -C "$repo" show-ref --verify --quiet "refs/heads/$ebranch" \
        || ac_die "get: epic branch $ebranch does not exist in $rname - cut it first: ac-epic-branch.sh create <epic> $rname"
      base_ref="$ebranch"
    fi
  fi
  with_pool_lock "$repo" acquire_slot "$repo" "$id" "$holder" "$owner" "$prefer" "$base_ref"
  write_workspace "$repo"
}

acquire_slot() {
  # Runs under the pool lock; set -e may be suppressed by the caller, so
  # every git outcome is checked explicitly.
  local repo="$1" id="$2" holder="$3" owner="$4" prefer="${5:-}" base_ref="${6:-}" meta wt n free="" leased prefer_why=""
  git -C "$repo" worktree prune >/dev/null 2>&1 || true
  heal_slots "$repo"

  # Slot affinity: try the preferred slot first and lease exactly it when it
  # is available (a dead-owner lease self-heals here like anywhere else).
  # Any other state records WHY and falls through to normal selection; the
  # one warning line is printed once the fallback slot is known.
  if [ -n "$prefer" ]; then
    meta="$(slot_meta "$repo" "$prefer")"
    wt="$(slot_path "$repo" "$prefer")"
    if [ ! -f "$meta" ]; then
      prefer_why="no such slot"
    else
      leased="$(ac_meta_get "$meta" leased)"
      case "$leased" in
        0) : ;;
        1)
          if lease_reclaimable "$meta"; then
            ac_warn "reclaiming slot $prefer from dead owner $(ac_meta_get "$meta" owner_pid)"
          else
            prefer_why="leased by task $(ac_meta_get "$meta" task)"
          fi
          ;;
        *) prefer_why="lease state unknown (half-written meta?)" ;;
      esac
      if [ -z "$prefer_why" ]; then
        if is_dirty "$wt"; then
          prefer_why="dirty (unlanded work)"
        elif ! reset_worktree "$repo" "$wt" "$base_ref"; then
          prefer_why="reset failed"
        else
          free="$prefer"
        fi
      fi
    fi
  fi

  # Reuse a free, clean slot first. Fail closed on unknown lease state;
  # reclaim leases whose recorded owner pid is dead.
  if [ -z "$free" ]; then
    for meta in "$(pool_dir "$repo")"/slots/*.meta; do
      [ -f "$meta" ] || continue
      n="$(basename "$meta" .meta)"
      wt="$(slot_path "$repo" "$n")"
      leased="$(ac_meta_get "$meta" leased)"
      case "$leased" in
        0) : ;;
        1)
          if lease_reclaimable "$meta"; then
            ac_warn "reclaiming slot $n from dead owner $(ac_meta_get "$meta" owner_pid)"
          else
            continue
          fi
          ;;
        *) ac_warn "skip slot $n: lease state unknown (half-written meta?)"; continue ;;
      esac
      if is_dirty "$wt"; then
        ac_warn "skip slot $n: dirty (unlanded work; inspect or remove --force)"
        continue
      fi
      if ! reset_worktree "$repo" "$wt" "$base_ref"; then
        ac_warn "skip slot $n: reset failed"
        continue
      fi
      free="$n"
      break
    done
  fi

  if [ -n "$free" ]; then
    n="$free"
    # A legacy bare-numeric slot migrates to <n>-<repo> the moment it is
    # reused: git worktree move keeps the admin metadata coherent, the meta
    # file follows, and the slot's codegraph cache is dropped (its index
    # stores absolute paths, so the lease hook re-inits at the new path).
    # Fail-open: a refused move just keeps the legacy name.
    case "$n" in
      *-*) : ;;
      *)
        local newn newwt
        newn="$n-$(basename "$repo")"
        newwt="$(slot_path "$repo" "$newn")"
        if git -C "$repo" worktree move "$(slot_path "$repo" "$n")" "$newwt" >/dev/null 2>&1; then
          mv "$(slot_meta "$repo" "$n")" "$(slot_meta "$repo" "$newn")" 2>/dev/null || true
          rm -rf "$newwt/.codegraph"
          ac_warn "migrated slot $n -> $newn"
          n="$newn"
        fi
        ;;
    esac
    wt="$(slot_path "$repo" "$n")"
    ac_warn "reusing worktree slot $n"
  else
    # Allocate a new slot below the pool cap. Slot names are
    # <number>-<repo-basename> so a worktree path identifies its repo at a
    # glance (editor tabs, codegraph Project lines, ps output); legacy bare
    # numeric slots keep working - the number is the prefix either way, and
    # everything downstream treats the slot id as an opaque string.
    local count=0 highest=0 base num max
    for meta in "$(pool_dir "$repo")"/slots/*.meta; do
      [ -f "$meta" ] || continue
      count=$((count + 1))
      base="$(basename "$meta" .meta)"
      num="${base%%-*}"
      [ "$num" -gt "$highest" ] 2>/dev/null && highest="$num"
    done
    max="$(pool_max_trees "$repo")"
    [ "$count" -lt "$max" ] || ac_die "pool is full ($count/$max); raise max_trees in .crew/config or prune"
    n="$((highest + 1))-$(basename "$repo")"
    wt="$(slot_path "$repo" "$n")"
    # An orphan dir with no meta (partial create) wedges the number: clean it.
    if [ -e "$wt" ]; then
      ac_warn "cleaning orphan worktree dir at slot $n"
      git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
      rm -rf "$wt"
      git -C "$repo" worktree prune >/dev/null 2>&1 || true
    fi
    ac_warn "creating worktree slot $n"
    if ! git -C "$repo" worktree add --force --detach --quiet "$wt" "${base_ref:-$(freshest_ref "$repo")}"; then
      drop_slot "$repo" "$n"
      ac_die "git worktree add failed for slot $n"
    fi
  fi

  if [ -n "$prefer_why" ]; then
    ac_warn "prefer: slot $prefer unavailable ($prefer_why) - leased slot $n instead"
  fi

  # One atomic meta write: a slot is never observed half-leased.
  meta="$(slot_meta "$repo" "$n")"
  local tmp="$meta.tmp.$$" created lease_id
  created="$(ac_meta_get "$meta" created_at)"
  lease_id="$(mint_lease_id)"
  {
    printf 'created_at=%s\n' "${created:-$(ac_iso)}"
    printf 'leased=1\n'
    printf 'task=%s\n' "${id:-}"
    printf 'holder=%s\n' "${holder:-cli}"
    printf 'owner_pid=%s\n' "${owner:-}"
    printf 'leased_at=%s\n' "$(ac_iso)"
    printf 'lease_id=%s\n' "$lease_id"
  } >"$tmp"
  mv "$tmp" "$meta"
  append_lease_to_crew_meta "$id" "$wt" "$lease_id"
  printf '%s\n' "$wt"
}

append_lease_to_crew_meta() {
  # append_lease_to_crew_meta <id> <worktree> <lease_id> - fold a SECOND (or
  # later) lease for the same task into the durable crew/self-task meta that
  # ac-teardown.sh reads (grammar: the LEASES block in ac-spawn.sh), so a task
  # leasing more than one pooled worktree does not leak the extra slot
  # forever. Silent no-op, never a mint, when:
  # - no id was given (an unattributed CLI get);
  # - state/<id>.meta does not exist YET - the FIRST lease of a spawn or a
  #   self task always predates its own crew meta (ac-spawn.sh/
  #   ac-self-task.sh write worktree=/leases= only after this call returns),
  #   and a verifier's distinct id (`<family>-verify-<kind>[-e2e]`) never gets
  #   one at all - ac_meta_set would CREATE the file were it called
  #   unconditionally, minting a stray meta nothing ever tears down.
  # No pool lock: ac_meta_set is an unlocked atomic rewrite, but a spawn takes
  # exactly one lease and a crewmate's further leases run sequentially in its
  # one shell, so two appends for the same id never race in practice.
  local id="$1" wt="$2" lease_id="$3" sdir state_meta cur
  [ -n "$id" ] || return 0
  sdir="$(crew_state_dir)"
  [ -n "$sdir" ] || return 0
  state_meta="$sdir/$id.meta"
  [ -f "$state_meta" ] || return 0
  cur="$(ac_meta_get "$state_meta" leases)"
  ac_meta_set "$state_meta" leases "${cur:+$cur:}$wt"
  cur="$(ac_meta_get "$state_meta" lease_ids)"
  ac_meta_set "$state_meta" lease_ids "${cur:+$cur:}$lease_id"
}

crew_state_dir() {
  # The fleet state/ dir, resolved the same way ac-verify.sh's
  # resolve_state_dir does: AC_FLEET_STATE first (what a homeless crewmate
  # pane carries - AC_HOME never does), else ac_state_dir() when AC_HOME is
  # set (a chief-side caller: ac-spawn.sh, ac-self-task.sh). Prints nothing,
  # never dies, when neither is set - a bare CLI get (tests, a captain by
  # hand with no fleet) has no crew meta to append to either way.
  if [ -n "${AC_FLEET_STATE:-}" ]; then
    printf '%s\n' "$AC_FLEET_STATE"
  elif [ -n "${AC_HOME:-}" ]; then
    ac_state_dir
  fi
}

mint_lease_id() {
  # One opaque identity per ACQUISITION - re-leasing the same slot to the same
  # holder mints a new one. It is what `return --if-lease-id` compares against,
  # so the whole point is that it does NOT survive a release (see release_slot).
  # Falls back to pid+time when /dev/urandom is unreadable: a weaker id still
  # distinguishes two acquisitions, and a lease that cannot be minted at all
  # would be worse than one that is merely less random.
  local id=""
  id="$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n')" || id=""
  [ -n "$id" ] || id="$$-$(date -u +%s)"
  printf '%s\n' "$id"
}

# --- list --------------------------------------------------------------------

cmd_list() {
  local repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      *) ac_die "list: unknown argument $1" ;;
    esac
  done
  [ -n "$repo" ] || ac_die "list: --repo is required"
  repo="$(resolve_repo "$repo")"
  with_pool_lock "$repo" list_slots "$repo"
}

list_slots() {
  # Wire: n \t state[ dirty] \t task \t worktree \t leased_at \t owner_pid -
  # the last two are meaningful only when state is "leased" (empty
  # otherwise); a leased row with no owner_pid is a durable lease (comment
  # at lease_reclaimable), which is what makes its age worth reporting.
  local repo="$1" meta n wt state task dirty leased_at owner found=0
  heal_slots "$repo"
  for meta in "$(pool_dir "$repo")"/slots/*.meta; do
    [ -f "$meta" ] || continue
    found=1
    n="$(basename "$meta" .meta)"
    wt="$(slot_path "$repo" "$n")"
    task="$(ac_meta_get "$meta" task)"
    leased_at=""
    owner=""
    if [ "$(ac_meta_get "$meta" leased)" = "1" ]; then
      state="leased"
      leased_at="$(ac_meta_get "$meta" leased_at)"
      owner="$(ac_meta_get "$meta" owner_pid)"
    elif ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
      state="broken"
    else
      state="available"
    fi
    dirty=""
    is_dirty "$wt" && dirty=" dirty"
    printf '%s\t%s%s\t%s\t%s\t%s\t%s\n' "$n" "$state" "$dirty" "${task:-'-'}" "$wt" "$leased_at" "$owner"
  done
  [ "$found" = 1 ] || ac_warn "no worktrees in pool"
  return 0
}

# --- return ------------------------------------------------------------------

cmd_return() {
  local wt="" force=0 repo want_lease=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --if-lease-id) want_lease="$2"; shift 2 ;;
      *) wt="$1"; shift ;;
    esac
  done
  [ -n "$wt" ] || ac_die "return: worktree path required"
  [ -d "$wt" ] || ac_die "return: no such directory: $wt"
  wt="$(cd "$wt" && pwd -P)"
  repo="$(ac_repo_root "$wt")" || ac_die "return: not a git worktree: $wt"
  case "$wt" in
    "$repo"/.crew/worktrees/*) : ;;
    *) ac_die "return: not an agent-crew pool worktree: $wt" ;;
  esac
  local n meta
  n="$(basename "$wt")"
  meta="$(slot_meta "$repo" "$n")"
  [ -f "$meta" ] || ac_die "return: unmanaged slot: $wt"
  with_pool_lock "$repo" claim_return "$meta" "$n" "$wt" "$want_lease" "$force"
  # Destructive section, deliberately UNLOCKED - see claim_return for what
  # makes that safe, and why the lock cannot simply be held across it.
  kill_worktree_procs "$wt"
  reset_worktree "$repo" "$wt" || ac_die "return: reset failed for $wt"
  with_pool_lock "$repo" release_slot "$meta"
  write_workspace "$repo"
  ac_warn "worktree slot $n returned to pool"
}

claim_return() {
  # Runs under the pool lock: decide whether this return may proceed AND take
  # the slot over, as ONE atomic step, before anything destructive runs.
  #
  # Identity: a slot is identified by path, and a path is reused, so a LATE
  # return would otherwise kill the processes and reset the tree of whichever
  # task holds the slot NOW. --force does not cover this - it authorizes
  # discarding the CALLER's leftovers, and by this point the tree may not be
  # the caller's at all. Checking it unlocked was the same bug once removed: a
  # check that PASSED could still be overtaken by a locked acquire_slot
  # re-leasing the slot before the reset landed.
  #
  # Take-over: the lease is re-owned by THIS process. A lease whose owner pid
  # is alive is never reclaimed - acquire_slot, prune_pass and remove_slot all
  # gate on lease_reclaimable - so the section below runs unlocked with the
  # slot provably off limits to every other pool operation. Holding the lock
  # itself across that section is what we cannot do: it spans an `lsof +D` of
  # the whole tree, a 2s kill grace and a full checkout/reset/clean, and every
  # other caller waits on that lock for 30s before dying.
  # Dying mid-reset leaves the lease owned by a dead pid, which is the pool's
  # existing self-heal shape: the next acquire reclaims the slot, re-checks it
  # and skips it if the reset left it dirty.
  local meta="$1" n="$2" wt="$3" want_lease="$4" force="$5" have_lease
  if [ -n "$want_lease" ]; then
    have_lease="$(ac_meta_get "$meta" lease_id)"
    [ "$want_lease" = "$have_lease" ] \
      || ac_die "return: slot $n holds lease ${have_lease:-none}, not $want_lease - refusing (the slot was re-leased; nothing was reset)"
  fi
  if [ "$force" = 0 ] && is_dirty "$wt"; then
    ac_die "return: worktree is dirty; land the work or pass --force to discard: $wt"
  fi
  ac_meta_set "$meta" owner_pid "$$"
}

release_slot() {
  ac_meta_set "$1" leased 0
  ac_meta_set "$1" owner_pid ""
  # The identity dies with the lease, so a SECOND return carrying the same id
  # is refused instead of resetting a slot that has since gone to someone else.
  ac_meta_set "$1" lease_id ""
}

# --- prune -------------------------------------------------------------------

cmd_prune() {
  local repo="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) ac_die "prune: unknown argument $1" ;;
    esac
  done
  [ -n "$repo" ] || ac_die "prune: --repo is required"
  repo="$(resolve_repo "$repo")"
  with_pool_lock "$repo" prune_pass "$repo" "$yes"
  write_workspace "$repo"
}

prune_pass() {
  local repo="$1" yes="$2" meta n wt ref verify_ok=1 reason=""
  heal_slots "$repo"

  # Merged-proof must hold against the LIVE remote: a failed fetch or a
  # stale tracking ref means "cannot verify" - skip, never guess.
  if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    local branch remote_sha local_sha
    branch="$(ac_default_branch "$repo")"
    if ! git -C "$repo" fetch origin --quiet 2>/dev/null; then
      verify_ok=0; reason="origin unreachable (cannot verify)"
    else
      remote_sha="$(git -C "$repo" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{print $1}')"
      local_sha="$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" || true)"
      if [ -n "$remote_sha" ] && [ "$remote_sha" != "$local_sha" ]; then
        verify_ok=0; reason="origin/$branch stale vs remote (cannot verify)"
      fi
    fi
  fi
  ref="$(ac_default_ref "$repo")"

  for meta in "$(pool_dir "$repo")"/slots/*.meta; do
    [ -f "$meta" ] || continue
    n="$(basename "$meta" .meta)"
    wt="$(slot_path "$repo" "$n")"
    if [ "$(ac_meta_get "$meta" leased)" = "1" ] && ! lease_reclaimable "$meta"; then
      printf 'skip slot %s: leased\n' "$n"
      continue
    fi
    if is_dirty "$wt"; then
      printf 'skip slot %s: dirty\n' "$n"
      continue
    fi
    if [ -n "$(live_procs "$wt" || true)" ]; then
      printf 'skip slot %s: in-use (live processes)\n' "$n"
      continue
    fi
    if [ "$verify_ok" = 0 ]; then
      printf 'skip slot %s: %s\n' "$n" "$reason"
      continue
    fi
    if ! git -C "$repo" merge-base --is-ancestor "$(git -C "$wt" rev-parse HEAD)" "$ref" 2>/dev/null; then
      printf 'skip slot %s: HEAD not merged into %s\n' "$n" "$ref"
      continue
    fi
    if [ "$yes" = 1 ]; then
      drop_slot "$repo" "$n"
      printf 'pruned slot %s\n' "$n"
    else
      printf 'would prune slot %s: %s (run with --yes)\n' "$n" "$wt"
    fi
  done
  return 0
}

# --- remove ------------------------------------------------------------------

cmd_remove() {
  local wt="" force=0 include_leased=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --include-leased) include_leased=1; shift ;;
      *) wt="$1"; shift ;;
    esac
  done
  [ -n "$wt" ] || ac_die "remove: worktree path required"
  [ -d "$wt" ] || ac_die "remove: no such directory: $wt"
  wt="$(cd "$wt" && pwd -P)"
  local repo
  # A slot with a broken gitdir cannot answer ac_repo_root - and it is exactly
  # the slot heal_slots refuses to destroy on its own, so `remove` is its ONLY
  # deliberate exit and must stay reachable. Fall back to the pool's own path
  # shape: the path names the candidate root, git still has to confirm it.
  repo="$(ac_repo_root "$wt" 2>/dev/null)" \
    || repo="$(ac_repo_root "${wt%/.crew/worktrees/*}" 2>/dev/null)" \
    || ac_die "remove: not a git worktree: $wt"
  case "$wt" in
    "$repo"/.crew/worktrees/*) : ;;
    *) ac_die "remove: not an agent-crew pool worktree: $wt" ;;
  esac
  with_pool_lock "$repo" remove_slot "$repo" "$wt" "$force" "$include_leased"
  write_workspace "$repo"
}

remove_slot() {
  local repo="$1" wt="$2" force="$3" include_leased="$4" n meta head
  n="$(basename "$wt")"
  meta="$(slot_meta "$repo" "$n")"
  [ -f "$meta" ] || ac_die "remove: unmanaged slot: $wt"
  if [ "$(ac_meta_get "$meta" leased)" = "1" ] && ! lease_reclaimable "$meta"; then
    [ "$include_leased" = 1 ] \
      || ac_die "remove: slot $n is leased (task $(ac_meta_get "$meta" task)); pass --include-leased to take it anyway"
  fi
  # A broken slot answers NO dirty or merged check - git cannot read it - so the
  # two gates below are blind exactly where heal_slots now declines to act. Take
  # the same --force this reachable-only-here path already asks for elsewhere,
  # so nothing destroys unverifiable contents without being told to.
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 && [ "$force" != 1 ]; then
    ac_die "remove: slot $n is broken (gitdir unreadable) so its contents cannot be checked; use --force to discard"
  fi
  if is_dirty "$wt" && [ "$force" != 1 ]; then
    ac_die "remove: worktree is dirty; use --force to discard"
  fi
  head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$head" ] && [ "$force" != 1 ] \
    && ! git -C "$repo" merge-base --is-ancestor "$head" "$(ac_default_ref "$repo")" 2>/dev/null; then
    ac_die "remove: slot $n holds commits not merged into the default branch; use --force to discard"
  fi
  kill_worktree_procs "$wt"
  drop_slot "$repo" "$n"
  ac_warn "removed slot $n"
}

usage() {
  awk 'NR>1{if(!/^#/)exit; print}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift
case "$cmd" in
  get) cmd_get "$@" ;;
  list) cmd_list "$@" ;;
  return) cmd_return "$@" ;;
  prune) cmd_prune "$@" ;;
  remove) cmd_remove "$@" ;;
  *) usage ;;
esac
