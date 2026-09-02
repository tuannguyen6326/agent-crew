# In-repo worktree pool

A task's isolated checkout is leased per the fleet's session backend
(`config/backend`), and the two mechanisms are deliberately different shapes:

- **herdr fleets** lease from the POOL this document describes - reusable
  detached-HEAD worktrees inside the project repo, returned rather than
  deleted, so dependency and build caches survive between tasks.
- **orca fleets** lease an ORCA-MANAGED worktree per task instead, created
  and removed through the Orca CLI so every task tree is a first-class node
  in the Orca sidebar beside its diffs. `bin/ac-backend-orca.sh`
  (`orca_worktree_lease` / `orca_worktree_release`) is that half's
  authoritative spec: `crew/<id>` cut from the repo's LIVE CHECKOUT branch
  at its freshest tip (`ac_freshest_ref`, local vs origin) - or, when the
  checkout is DETACHED, from HEAD's exact commit, since a detached checkout
  can sit ahead of its own branch ref with no named ref to compare against -
  or from an explicit `--base-branch` override when `ac-self-task.sh start` /
  `ac-spawn.sh` name one, repo-defined setup hooks run, the primary
  checkout's `node_modules` carried over as a copy-on-write clone, and the
  whole worktree removed at teardown.

Verifier rounds (`ac-verify.sh` codereview and qa) follow the same rule as
crew leases - the isolated exact-ref checkout comes from whichever mechanism
the fleet's backend names, and on orca the CLI-minted branch is dropped right
after the detach, since a verifier branch is never a deliverable.

`bin/ac-tree.sh` pools reusable detached-HEAD git worktrees INSIDE each
project repo; its header comment is the authoritative spec.

## Layout

```
<repo>/.crew/
├── worktrees/<n>/      # worktree working dirs (numeric slots, detached HEAD)
├── slots/<n>.meta      # per-slot state (key=value, atomic rewrite)
├── lock/               # mkdir lock guarding slot state (stale-owner healing)
├── config              # optional: max_trees=<n> (default 8)
└── <repo>.code-workspace  # GENERATED active-task workspace file (see below)
```

Editors (VSCode/Cursor) do not auto-discover the nested worktrees as
repositories (default repository scan depth is 1, and `.crew/` is ignored).
Open the generated `<repo>/.crew/<repo>.code-workspace` instead: a multi-root
workspace listing the repo plus one folder per currently leased worktree, so
each active task tree shows up as its own repository in the source-control
panel without idle pool slots filling the Git tab. Folder names carry the lease
(`wt<n> - <task>`). Returning a slot removes it from the generated file; leasing
it again adds it back with the new task label. `ac-tree.sh` does not control a
live editor window, so an editor that does not reload external workspace-file
changes must reopen or reload the workspace to apply the new folder list.
It is regenerated after every slot mutation (get/return/prune/remove) - never
hand-edit it.

`/.crew/` is auto-appended to the repo's `.gitignore` on first use (with a
newline guard so an unterminated final line is never corrupted), so the pool
never shows up in the project's `git status` beyond that one line (commit it
to make the exclusion permanent for every clone).

## Invariants

- **Detached HEAD, no branches**: worktrees are created with `git worktree
  add --detach` and reset to the FRESHEST default-branch ref - whichever of
  local vs `origin/<branch>` is ahead; origin wins on true divergence.
  Crewmates create their own `crew/<id>` branches.
- **Reuse over recreate**: `return` resets (`checkout --detach --force` +
  `reset --hard` + `clean -fd`) and releases; it never deletes, so ignored
  files - dependency and build caches - survive between tasks.
- **Locked mutations**: get, prune, remove and list run under the pool lock;
  `return` CLAIMS its slot under that same lock first - re-owning the lease to
  the returning process - because its proc-kill and tree reset are too long to
  hold a 30s lock across (an `lsof` of the whole tree, a kill grace of up to
  4s, a full reset). Either way the slot is off limits to everything else:
  prune can never delete a slot a concurrent get just leased, and no acquire
  can re-lease a slot a return is resetting.
- **Leases with self-healing owners**: `get --id <task> --holder <label>`
  marks the slot leased; `--owner <pid>` optionally records a liveness token,
  and a lease whose owner pid is provably dead is reclaimed on the next
  acquire (dead crewmates cannot wedge the pool). Ownerless leases are
  durable and only cleared by `return`.
- **Lease identity**: each acquisition mints an opaque `lease_id` into the
  slot meta, and releasing clears it. `return --if-lease-id <id>` refuses
  before anything destructive runs when the slot no longer holds that id -
  a return arriving after the slot was re-leased would otherwise kill the
  processes and reset the tree of whichever task holds it now, which
  `--force` does not cover (it authorizes discarding the CALLER's leftovers).
  `ac-spawn.sh` records the ids as `lease_ids=` beside `leases=` and
  `ac-teardown.sh` pops the two in lockstep. Omitting the flag keeps the old
  unconditional behavior, so a pool predating the id needs no migration.
- **Fail closed on unknown state**: a slot meta with no readable lease state
  (a half-written file) is skipped, never handed out.
- **Dirty protection**: dirty slots are never silently reset - acquire skips
  them, prune skips them, `return` and `remove` demand `--force` to discard.
- **Resets pinned to the check that authorized them**: the HEAD and porcelain
  read at check time are re-read immediately before the reset, and a tree that
  moved in between is SKIPPED, not destroyed - so work written while a return
  is in its unlocked kill grace, or by a process still alive in a slot being
  reclaimed, survives. An un-forced `return` on such a tree refuses with
  `changed after it was verified clean` and resets nothing; `--force` is
  pinned to nothing, since its authority is the caller's own word to discard
  whatever is there.
- **Landed-work protection**: `remove` also refuses a LEASED slot without
  `--include-leased`, and without `--force` both a clean slot whose HEAD is
  not merged into the default branch and a broken slot whose contents git
  cannot check at all. `remove` is the deliberate exit for a slot the pool
  declines to heal, so it reaches a broken worktree that cannot answer
  `rev-parse` - the pool path names the repo, git still confirms it.
- **Verified prune**: `prune` is dry-run without `--yes` and only removes
  idle, clean, process-free slots whose HEAD is merged into the default ref
  as verified against the LIVE remote - a failed fetch or a stale
  `origin/<branch>` tracking ref means "cannot verify", and the slot is
  skipped rather than guessed at. The same rule covers the process check
  itself: `lsof` missing means prune cannot look, which is not the same answer
  as "nobody is there", so the slot is skipped instead of removed.
- **Process hygiene**: return, prune and remove terminate (or, for prune,
  refuse to touch) processes still running inside the worktree, so detached
  servers never keep working in a recycled tree. A kill then WAITS, bounded at
  2s, for the pids it SIGKILLed to leave the process table before the next git
  command runs - SIGKILL is asynchronous, and the next command takes
  `index.lock`.
- **Self-healing pool**: worktrees whose directory vanished, and orphan dirs
  from partial creates, are healed by get/list/prune, and `git worktree prune`
  keeps git's own bookkeeping in sync. A slot whose dir survives with a dead
  gitdir pointer is NOT healed: git can no longer report what is in it, so it
  may be unlanded work - the slot is named instead, with the exact `remove`
  that reclaims it.

## Command summary

| Command | Effect |
|---|---|
| `get --repo <p> [--id <task>] [--holder <l>] [--owner <pid>]` | Acquire (reuse or grow, cap `max_trees`/`AC_MAX_TREES`); prints ONLY the path on stdout. |
| `list --repo <p>` | `slot  state[ dirty]  task  path` per slot (heals vanished slots first). |
| `return <path> [--force]` | Reset to the freshest default ref + release; refuses without resetting when the tree changed after it was verified clean; `--force` discards dirty work and skips that check. |
| `prune --repo <p> [--yes]` | Remove idle, clean, merged (remote-verified), process-free slots (dry-run default). |
| `remove <path> [--force] [--include-leased]` | Deliberate removal of one slot; `--force` discards dirty/unmerged/broken work, `--include-leased` takes a leased slot. |
