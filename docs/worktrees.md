# In-repo worktree pool

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
  hold a 30s lock across (an `lsof` of the whole tree, a 2s kill grace, a full
  reset). Either way the slot is off limits to everything else: prune can never
  delete a slot a concurrent get just leased, and no acquire can re-lease a
  slot a return is resetting.
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
  skipped rather than guessed at.
- **Process hygiene**: return, prune and remove terminate (or, for prune,
  refuse to touch) processes still running inside the worktree, so detached
  servers never keep working in a recycled tree.
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
| `return <path> [--force]` | Reset to the freshest default ref + release; `--force` discards dirty work. |
| `prune --repo <p> [--yes]` | Remove idle, clean, merged (remote-verified), process-free slots (dry-run default). |
| `remove <path> [--force] [--include-leased]` | Deliberate removal of one slot; `--force` discards dirty/unmerged/broken work, `--include-leased` takes a leased slot. |
