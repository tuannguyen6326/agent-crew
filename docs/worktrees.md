# Worktrees

Every task works in its own isolated checkout, never in the project's primary checkout.
How that checkout is leased depends on the fleet's session backend (`config/backend`, see [configuration.md](configuration.md)):

- **herdr fleets** lease from the in-repo worktree POOL: reusable detached-HEAD worktrees inside the project repo, returned rather than deleted, so dependency and build caches survive between tasks.
- **orca fleets** lease one Orca-managed worktree per task, created and removed through the Orca CLI, so each task tree is its own node in the Orca sidebar.

This page is a map; the specs are the header of `bin/ac-tree.sh` (the pool) and `orca_worktree_lease` / `orca_worktree_release` in `bin/ac-backend-orca.sh`.
See also [concepts.md](concepts.md), [architecture.md](architecture.md) and [scripts.md](scripts.md).

## The pool (herdr fleets)

### Layout

```
<repo>/.crew/
├── worktrees/<n>/           # slot working dirs, detached HEAD; <n> is <number>-<repo-name>
├── slots/<n>.meta           # per-slot state (key=value, atomic rewrite), incl. lease_id=
├── lock/                    # mkdir lock guarding slot state
├── config                   # optional: max_trees=<n>
└── <repo>.code-workspace    # GENERATED editor workspace (see below)
```

Legacy slots named by a bare number stay valid; new slots get `<number>-<repo-name>`.
The pool cap is `AC_MAX_TREES`, else `max_trees=` in `.crew/config`, else 8.

`/.crew/` is ignored per clone through `.git/info/exclude`, so the pool never appears in `git status` and the rule is never committed upstream.

### Commands

| Command | Effect |
|---|---|
| `get --repo <p> [--id <task>] [--holder <l>] [--owner <pid>] [--prefer <path-or-slot-n>]` | Lease a slot (reuse an available one or grow up to the cap), reset it to the freshest base ref, and print only its path. |
| `lease <slot-or-path> --repo <p> [--id <task>] [--holder <l>]` | Durably lease an EXISTING slot, state only: no fetch, reset, clean or checkout. |
| `list --repo <p>` | One row per slot: state (`leased`/`available`/`broken`, plus ` dirty`), task, path, lease age data. |
| `return <path-or-slot-name> [--repo <p>] [--force] [--if-lease-id <id>]` | Kill processes in the tree, reset it, release the lease. |
| `prune --repo <p> [--yes]` | Remove idle, clean, merged, process-free slots; a dry run without `--yes`. |
| `remove <path> [--force] [--include-leased]` | Deliberately remove one slot. |

`ac-spawn.sh` leases with `get --id <id> --holder crew:<id>`, `ac-self-task.sh` with `--holder self:<id>`, and a herdr verifier round with `--holder verify`.
A spawn that resumes an earlier session passes `--prefer` with the old slot, because claude keys sessions by working directory; if that slot is not available, `get` leases another one and prints one `prefer:` warning line.

### What `get` does

- Resets the slot to the FRESHEST default-branch ref: whichever of the local branch and `origin/<branch>` is ahead, origin winning on true divergence.
- Cuts the slot from a recorded integration branch instead when the task id belongs to an epic or feature that records one for this repo, and refuses outright when that branch is missing - never a silent fall back to the default branch.
- On the first lease, installs two shared guard hooks into the default git-common-dir `hooks/` directory, so one install covers the primary checkout and every linked worktree:
  - a `pre-commit` that refuses a commit in the PRIMARY checkout when `AC_CREW_ID` or `AC_SCOPE` is set (a crewmate or roomchief; the captain carries neither);
  - a `commit-msg` that refuses an agent `Co-authored-by:` trailer, read through `git interpret-trailers --parse` and matched against the trailer name only, so a human co-author passes.
- An existing project hook is copied aside to `<hook>.ac-crew-prev` and chained, never clobbered; a symlinked hook or a set `core.hooksPath` skips the install fail-open.
- Seeds ignored runtime files from the primary checkout when the project commits a `.worktreeinclude` manifest (read from the slot's HEAD; absolute, escaping, `.crew` and symlink entries are refused).
- When `state/<id>.meta` already exists for `--id`, appends the new path and its `lease_id` to that meta's `leases=` / `lease_ids=`, which is how `ac-teardown.sh` later returns every tree a task holds.

### Invariants

- **Detached HEAD, reused.** The pool creates no branches (`crew/<id>` is the crewmate's own), and `return` resets and releases a tree, never deletes it; `git clean` runs without `-x`, so ignored caches survive.
- **Leases.** A lease with an `--owner` pid that is provably dead is reclaimed on the next acquire; a lease with no owner is durable and only `return` clears it.
  Spawn records no owner, so crew leases are durable.
- **Lease identity.** Every acquisition mints an opaque `lease_id`.
  `return --if-lease-id <id>` refuses before anything destructive when the slot no longer holds that id, so a late return cannot reset a slot another task now holds; `--force` does not override this.
  `ac-teardown.sh` passes it for every lease it recorded.
- **Dirty slots are never silently reset.** Acquire and prune skip them; `return` and `remove` need `--force` to discard.
- **Resets are pinned.** HEAD and porcelain read at check time are re-read just before the reset, and a tree that changed in between is skipped: an un-forced `return` then refuses with `changed after it was verified clean`.
  `--force` is pinned to nothing.
- **Locked mutations.** Pool state changes run under the pool lock; `return` claims its slot under it, then kills and resets unlocked.
- **Process hygiene.** `return` and `remove` kill processes still running in the tree; `prune` skips a slot with live processes, or when `lsof` is unavailable to check.
- **Verified prune.** `prune` removes only unleased, clean, process-free slots whose HEAD is merged into the default branch as verified against the live remote; a failed fetch or stale tracking ref skips the slot.
- **Deliberate remove.** `remove` refuses a leased slot without `--include-leased`, and without `--force` refuses a dirty slot, a clean slot with unmerged commits, and a broken slot git cannot read.
- **Self-healing, never over possible work.** Vanished slot directories and orphans from partial creates are healed by `get`, `list` and `prune`; a directory with an unreadable gitdir is only named, with the `remove` command that reclaims it.

### `lease`: keeping a tree alive across tasks

`get` always resets the tree; `lease` instead stamps the same durable lease state and touches nothing, for a tree that must outlive one task (QA infrastructure, a parked investigation).
It refuses an unknown slot, a slot leased to a live holder, or an unreadable lease state.
`get` and `prune` skip the leased slot; `return` releases it and DOES reset the tree, so return a parked tree only when it may be discarded.

### Pool health

`bin/ac-pool-health.sh` feeds the session-start digest a `-- pool (worktree health) --` block, read only through `ac-tree.sh list`.
It names slots that are dirty, broken, or durably leased past an age threshold, each with the exact `remove` command to run, and never reclaims anything itself.

### Editor workspace

Open the generated `<repo>/.crew/<repo>.code-workspace` in VSCode or Cursor: it lists the repo (`<repo> (main)`) plus one folder per LEASED slot, named `wt<n> - <task>`, so active task trees appear in source control without idle slots filling the Git tab.
It is regenerated after every slot mutation; never hand-edit it.
`ac-tree.sh` does not control a live editor window, so reload the workspace if your editor does not pick up external changes.

## Orca leases (orca fleets)

`orca_worktree_lease <id> <repo> [<base-branch>]` creates one worktree per task through `orca worktree create` with repo setup hooks run and no lineage parent, then:

- cuts it from the repo's LIVE CHECKOUT branch at its freshest tip (`ac_freshest_ref`, local vs origin), or from HEAD's exact commit when the checkout is detached;
- lets an explicit `--base-branch` (from `ac-spawn.sh` or `ac-self-task.sh start`) name the branch instead, still resolved to its freshest tip;
- switches the checkout to `crew/<id>` (adopting an existing one on a respawn) and deletes the branch name the CLI minted;
- copies the primary checkout's `node_modules` into the worktree (a clone where the filesystem supports it, never a symlink) when setup did not produce one.

`orca_worktree_release <path>` removes the worktree through the Orca CLI at teardown; unlike a pool slot, nothing is kept.

## Verifier rounds

`ac-verify.sh` codereview and qa rounds lease their isolated checkout the same way the fleet's crew does: from the pool with holder `verify` on herdr, or an Orca-managed worktree on orca.
The round then detaches to its exact ref, and on orca drops the `crew/<id>` branch at once, because a verifier branch is never a deliverable.
The lease is returned (herdr, `return --force`) or released (orca) when the round is harvested.

## For contributors

Never create worktrees by hand in a project repo.
Pool behavior changes go in `bin/ac-tree.sh`, with its header updated in the same diff and a colocated test under `tests/`.
