// tree.ts - pooled git worktrees INSIDE the target repo, the herdr fleets'
// lease mechanism. The entry is bin/ac-tree.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-tree.sh as the oracle
// the differential leg of tests/sh/ac-tree.test.sh holds this module to.
// Worktrees live at <repo>/.crew/worktrees/<n>, and /.crew/ is auto-ignored
// via .git/info/exclude. On the first lease, `get` also installs two shared
// guard hooks into the default git-common-dir/hooks: a pre-commit that refuses
// a crewmate/roomchief commit made in the PRIMARY checkout, and a commit-msg
// that refuses an agent co-author trailer (AGENTS.md section 13) - see GUARD
// HOOKS below.
//
// Worktrees are detached-HEAD, reset to the freshest default-branch ref on
// acquire, and REUSED - returning a worktree never deletes it, so dependency
// and build caches survive between crewmates.
//
// Usage:
//   ac-tree.sh get    --repo <path> [--id <task>] [--holder <label>]
//                     [--owner <pid>] [--prefer <path-or-slot-n>]
//   ac-tree.sh lease  <slot-name | worktree-path> --repo <path>
//                     [--id <task>] [--holder <label>]
//   ac-tree.sh list   --repo <path>
//   ac-tree.sh return <worktree-path | slot-name> [--repo <path>] [--force]
//                     [--if-lease-id <id>]
//   ac-tree.sh prune  --repo <path> [--yes]
//   ac-tree.sh remove <worktree-path> [--force] [--include-leased]
// No verb, '', or any other first word prints this header on stdout, exit 2.
// stdin is never read. Every ERROR/WARN line is on stderr and every ERROR
// exits 1. A value flag given as the LAST word exits 1 with nothing said;
// flags repeat last-wins and an empty value reads as absent.
//
// ESCAPE HATCH. This module is the solo session's write
// path and every spawn's, verifier's and teardown's lease. If a landed change
// breaks it, run the frozen original from a scratch bin/:
//   o=$(mktemp -d); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-tree.sh "$o/bin/ac-tree.sh"
// then "$o/bin/ac-self-task.sh" start ... (self-task, spawn and teardown
// resolve $bin_dir/ac-tree.sh from their own dir) and "$o/bin/ac-tree.sh"
// return <wt> for the leases it took. The captain's revert of the land is the
// last resort.
//
// get --prefer <path-or-slot-n>: slot affinity for session resumes (claude
// keys sessions by cwd). When the preferred slot - given as a pool worktree
// path or a bare slot number - is AVAILABLE (not leased, not
// available-but-dirty), it is leased exactly; any other state falls back to
// the normal selection and prints ONE warning line:
//   prefer: slot <n> unavailable (<why>) - leased slot <m> instead
//
// get --id, a SECOND time: when state/<id>.meta already exists for --id, get
// appends the newly leased path (and its lease_id) to that meta's leases=/
// lease_ids= (grammar: the LEASES block in src/spawn.ts) - the mechanism by
// which ac-teardown.sh later returns EVERY tree a task holds, not only the one
// taken at spawn. A task's own FIRST lease never triggers this: spawn and
// ac-self-task.sh write state/<id>.meta only after that first get returns, so
// the append stays a silent no-op until the meta exists - which also keeps a
// verifier's lease (a distinct id that never gets a crew meta) out of it, and
// never mints a stray meta file for one. The state dir is AC_FLEET_STATE (what
// a homeless crewmate pane carries), else the home's state/, else none.
//
// LEASE - a durable lease on an EXISTING pool worktree, state only. `get` is
// the other way to mint a lease and it always resets the tree (--prefer
// included), so a tree that must live on across tasks - QA infra, a parked
// investigation - could be kept from `get` and `prune` only by staying dirty,
// which ac-pool-health.sh then reports as stuck. `lease` stamps exactly the
// lease state `get` writes (stampLease is the one writer: task, holder, an
// empty owner_pid - i.e. durable - leased_at and a fresh lease_id, plus the
// crew-meta append when state/<id>.meta exists) and runs no fetch, reset,
// clean or checkout. Under the pool lock it refuses an unknown slot, a slot
// leased to a live holder (naming it), or an unreadable lease state; a lease
// whose owner pid is dead is reclaimed as everywhere else. `list` and pool
// health show it as any other lease, `get`/`prune` skip it, and `return`
// (with --if-lease-id) releases it exactly like a `get` lease - which DOES
// reset the tree, so a parked tree is returned only when it may be discarded.
//
// return <slot-name>: the slot id `list` and ac-pool-health.sh print (e.g.
// `3-repo`), resolved in the pool of --repo, else of the repo the cwd is in.
// The argument is tried as a path first; a bare name that is no directory is
// a slot lookup, and anything carrying a path separator stays path-only.
//
// return --if-lease-id <id>: bind the return to the acquisition that took the
// slot. A slot is identified by PATH, and a path is REUSED, so a return that
// arrives after the slot was released and re-leased would otherwise kill the
// processes and reset the tree of whichever task holds it NOW - work lost with
// no error addressed to its owner. With the flag, a mismatch REFUSES before
// anything destructive runs. --force does not cover this: it authorizes
// discarding the CALLER's leftovers, and by then the tree is not the caller's.
// The id is minted per acquisition (16 hex digits from `od -An -tx1 -N8
// /dev/urandom`, else <pid>-<epoch>), recorded as lease_id= in the slot meta,
// dies with the lease, and is threaded through the crew meta as lease_ids=
// (grammar: the LEASES block in src/spawn.ts). Omitting the flag keeps the old
// unconditional behavior, so a pool or a meta that predates the id needs no
// migration.
//
// WORKTREE INCLUDE - seeding project-ignored runtime files so slots are
// interchangeable. A slot's reset keeps ignored files (`git clean` runs
// without -x, deliberately: caches survive, and -x would destroy what a
// captain may want to keep), so a recycled slot carries its previous
// lessee's `.env`/`node_modules` while a fresh slot has none - the "boots only
// in slot 4" shape. A project that commits a `.worktreeinclude` at its root
// names, one relative path per line (`#` comments and blank lines ignored,
// [:space:] trimmed under the caller's locale, one trailing `/` dropped), the
// ignored files or directories `get` copies from the PRIMARY checkout into the
// slot after every reset. It is read from the slot's HEAD (`git show
// HEAD:.worktreeinclude`), never from a working tree, so an unreviewed edit
// cannot name arbitrary paths. Each entry, in order: absolute, holding a `..`
// component, `.crew` or under it: `WARN: worktreeinclude: refusing '<l>' (a
// relative path inside the repo, outside .crew)`; a symlink in the primary:
// `... refusing '<l>' (a symlink is never followed)`; absent there: `...
// skipping '<l>' (absent from the primary checkout)`; not ignored: `...
// skipping '<l>' (not ignored - it is project content, already in the tree)`.
// A directory is merged over the slot's copy (`mkdir -p` + `cp -RP <src>/.
// <dst>/`), a file overwrites it (`mkdir -p` + `cp -P`); nothing is deleted; a
// failed copy is `WARN: worktreeinclude: copy of '<l>' failed`. No manifest =
// no-op.
//
// Safety model:
// - every mutating operation holds the slot exclusively: pool state changes
//   run under the pool lock, and the one section that cannot (return's
//   proc-kill and tree reset would hold it across an lsof of the whole tree, a
//   kill grace of up to 4s and a full checkout/reset/clean, against the 30s
//   timeout every other caller waits on) CLAIMS the slot under that lock
//   first, which re-owns the lease to the returning process - see claimReturn;
// - a lease with a dead --owner pid self-heals to available;
// - dirty slots are never silently reset (return needs --force to discard);
// - every reset is PINNED to the state that authorized it: the HEAD and
//   porcelain read at check time are re-read immediately before the reset, and
//   a tree that moved in between is skipped, not destroyed - see
//   resetIfUnchanged. --force is pinned to nothing: its authority is the
//   caller's own word to discard whatever is there;
// - a return naming a lease id the slot no longer holds is refused;
// - a proc-kill waits, bounded, for the pids it SIGKILLed to leave the process
//   table before the next git command runs - see reapPids;
// - prune only removes clean, merged, unleased, process-free slots, refuses to
//   verify "merged" against a stale or unreachable origin, and refuses a slot
//   whose live processes it could not CHECK for at all (no lsof) - "could not
//   look" must never reach a destructive gate as "nobody is there";
// - remove refuses leased slots without --include-leased and refuses
//   dirty, clean-but-unmerged, or unreadable-because-broken work without
//   --force - it is the deliberate exit for a slot heal declines to touch;
// - a slot whose worktree DIR vanished, and an orphan dir from a partial
//   create, are healed (removed) by get/list/prune; a slot whose dir survives
//   with a broken gitdir is left alone and named instead - git can no longer
//   report what is in it, so it may be unlanded work.
// "Dirty" is worktreeStatus (src/lib.ts) non-empty: the porcelain, any edit,
// deletion or mode change an assume-unchanged or skip-worktree bit hides (a
// skip-worktree file the sparse rules exclude is absent by design), and any
// rebase, merge, cherry-pick, revert, bisect or sequencer git left in progress.
// "Broken" is a slot for which `git rev-parse --show-toplevel` is not the slot
// itself (a gone gitdir; a gone .git file lets git answer for the primary).
//
// Pool layout inside the target repo:
//   .crew/worktrees/<n>/   worktree working dirs; <n> is <number>-<repo-name>
//                          for newly minted slots (legacy bare numbers stay
//                          valid - the id is opaque everywhere but the
//                          highest-number scan, which reads the prefix)
//   .crew/slots/<n>.meta   per-slot state (key=value, atomic rewrite), incl.
//                          lease_id= - one opaque identity per acquisition;
//                          the stamp writes created_at leased task holder
//                          owner_pid leased_at lease_id in that order, a
//                          release rewrites leased, owner_pid, lease_id in
//                          one rename (a reader never sees half of it); one
//                          that cannot be read is a lease nobody can name -
//                          never available, pruned or removed without
//                          --include-leased
//   .crew/lock/            mkdir lock guarding slot state (its pid file names
//                          the holder; 30 waits one PATH `sleep 1` apart,
//                          then `ERROR: could not acquire pool lock: <dir>`)
//   .crew/config           optional: max_trees=<n> (default 8; AC_MAX_TREES
//                          wins over it)
//   .crew/<repo>.code-workspace  GENERATED active-task workspace FILE: the repo
//                          plus one folder per LEASED worktree, so VSCode/
//                          Cursor shows active task trees as their OWN
//                          repositories without filling the Git tab with idle
//                          pool slots. Folder names carry the lease
//                          (`wt<n> - <task>`; `wt<n>` for an unreadable meta,
//                          listed as a lease). Regenerated after every slot
//                          mutation - never hand-edit it; one that cannot be
//                          written is `WARN: cannot write <file> - the next
//                          pool change rewrites it`, never the verb's failure.
//                          This script updates the file; it does not control
//                          a live editor window.
//
// --- every verb, in order (AUTHORITATIVE) ---
// SHARED. A repo argument resolves to the MAIN root `dirname $(git -C <arg>
// rev-parse --path-format=absolute --git-common-dir)` - git's physical path,
// so a linked slot names its main pool - else `ERROR: not a git repository:
// <arg>`; a root inside `*/.crew/worktrees/*` (a clone nested in a slot) is
// `ERROR: refusing to manage a pool inside a pool worktree: <root>`. Slots
// are walked as `.crew/slots/*.meta` in byte order. HEAL (get, list, prune):
// a slot whose dir is gone is `WARN: healed slot <n> (worktree dir vanished)`
// and dropped (worktree remove --force, rm -rf, meta removed, worktree
// prune); a broken one is `WARN: slot <n>: worktree broken (gitdir
// unreadable) - NOT healed, its files may be unlanded work git can no longer
// report; reclaim it deliberately with: bin/ac-tree.sh remove --force[
// --include-leased] <wt>` (the second flag when it is leased, or its meta
// cannot be read).
//
// get: flags --repo --id --holder --owner --prefer, else `ERROR: get: unknown
// argument <a>`; `ERROR: get: --repo is required`; the repo. --prefer: a
// value holding `/` drops one trailing `/` and keeps its basename; then empty,
// or not a slot id (`<digit>...-...`) and not all digits, is `ERROR: get:
// --prefer expects a slot id/number or a pool worktree path`; a bare number
// names `<n>-<repo>` when only that meta exists. `ERROR: repository has no
// commits: <repo>`. The exclude: `/.crew/` appended to `git rev-parse
// --git-path info/exclude` (LF first when the file ends in neither LF nor
// NUL) unless it holds that exact line, `WARN: added /.crew/ to <exclude>`;
// and a regular .gitignore holding the exact line HEAD's .gitignore lacks has
// it dropped (an emptied untracked file removed) with `WARN: migrated: /.crew/
// ignore moved to .git/info/exclude`. GUARD HOOKS under the lock. `mkdir -p`
// worktrees/ and slots/. With an `origin` remote, `git fetch origin --quiet`
// bounded by the sync knob (src/lib.ts syncTimeout: AC_SYNC_TIMEOUT, else
// config/sync-timeout, else 60 seconds; runBounded kills the fetch's process
// group at the deadline) - past it `WARN: fetch origin timed out after <t>s;
// using local refs`, any other failure `WARN: fetch origin failed; using local
// refs`. THE FENCE, only with
// --id: epicBaseFor(<id>, <repo name>) (src/lib.ts) - rc 2 is `ERROR: get:
// cannot read the ledger to resolve the epic-branch fence for <id>`; rc 0
// names `<branch> [key=value ...]`: ` push=deferred ` among the rest needs
// refs/heads/<branch> (else `ERROR: get: feature branch <b> does not exist in
// <repo> - cut it first: ac-feature.sh create <feature> <repo>`) and bases on
// <b>; else with origin refs/remotes/origin/<b> (else `ERROR: get: epic branch
// <b> is not on origin of <repo> - cut it first: ac-epic-branch.sh create
// <epic> <repo>`) and bases on origin/<b>; else refs/heads/<b> (else `ERROR:
// get: epic branch <b> does not exist in <repo> - cut it first:
// ac-epic-branch.sh create <epic> <repo>`); then `<base>^{commit}` must
// resolve, else `ERROR: get: base ref <base> (named by the integration-branch
// record for <id> on <repo>) does not resolve to a commit - nothing was
// leased; fix the ref before retrying`. The ledger and the records are read
// in the home - AC_HOME, else the one a crewmate pane's AC_FLEET_STATE sits in
// (W1, fixed); with neither, or an AC_HOME that cannot be
// entered, the fence is OFF and the home's refusal is printed once.
// Then under the lock: worktree prune, heal, the preferred slot (whys: `no
// such slot`, `leased by task <task>`, `lease state unknown (half-written
// meta?)`, `dirty (unlanded work)`, `changed under the check (a process still
// alive in the slot?)`, `reset failed`; a dead owner is `WARN: reclaiming slot
// <n> from dead owner <pid>`), then the first slot in order that is unleased
// or reclaimable, clean, and resets (`WARN: skip slot <n>: lease state
// unknown (half-written meta?)`, `...: dirty (unlanded work; inspect or remove
// --force)`, `...: changed under the check (a process still alive in the
// slot?)`, `...: reset failed`). A reused legacy bare-number slot is `git
// worktree move`d to <n>-<repo> with its meta and its .codegraph dropped
// (`WARN: migrated slot <n> -> <new>`); `WARN: reusing worktree slot <n>`.
// Else a new slot <highest number + 1>-<repo> below max_trees (`ERROR: pool is
// full (<count>/<max>); raise max_trees in .crew/config or prune` - a max that
// is no integer is full too), an orphan dir there cleaned (`WARN: cleaning
// orphan worktree dir at slot <n>`), `WARN: creating worktree slot <n>`, `git
// worktree add --force --detach --quiet <wt> <base>` (else the slot dropped
// and `ERROR: git worktree add failed for slot <n>`). A reset or a new slot
// bases on the fence's ref, else freshestRef. `WARN: prefer: slot <p>
// unavailable (<why>) - leased slot <n> instead`; the STAMP. Unlocked: the
// WORKTREE INCLUDE seeding, the workspace, then stdout `<wt>\n` - the one line.
// The STAMP (get and lease) records a lease in full or not at all: the slot
// meta rewritten whole - one that cannot be written is `ERROR: cannot record
// the lease in <meta> - nothing leased` - then, for a SECOND lease of --id,
// the crew-meta append, read and renamed under the meta lock (src/lib.ts
// metaUpdate). A crew meta that cannot take it releases the stamp first:
// `ERROR: cannot record the lease of <wt> in <crew meta> - the slot is
// released, nothing leased`, or, when that release cannot be written either,
// `ERROR: cannot record the lease of <wt> in <crew meta>, nor release the
// slot - return it with: bin/ac-tree.sh return <wt>`.
//
// lease: --repo --id --holder take values, any other `-*` word is `ERROR:
// lease: unknown argument <a>`, the last other word is the slot; `ERROR:
// lease: slot name or worktree path required`; `ERROR: lease: --repo is
// required`; the repo; a slot holding `/` is its basename (one trailing `/`
// dropped). Under the lock: `ERROR: lease: no such slot <n> in the pool of
// <repo>`; leased and not reclaimable: `ERROR: lease: slot <n> is leased by
// task <task> (holder <holder>) - refusing`; reclaimable: the reclaim WARN;
// neither 0 nor 1: `ERROR: lease: slot <n> lease state unknown (half-written
// meta?) - refusing`; the stamp with no owner. Then the workspace, `WARN:
// worktree slot <slot> leased to <id or cli> (state only, tree untouched)`,
// stdout `<repo>/.crew/worktrees/<slot>`.
//
// list: --repo only (`ERROR: list: unknown argument <a>`, `ERROR: list:
// --repo is required`). Under the lock (so .crew/ and the lock are minted),
// heal, then per slot one TAB-separated row `<n> <state>[ dirty] <task or
// '-'> <wt> <leased_at> <owner_pid>` - state `leased` (the last two filled;
// for a meta that cannot be read, after its WARN, both empty), else
// `broken`, else `available`; ` dirty` unless broken. An empty task is
// the three bytes `'-'`, quotes included (W12). No slot: `WARN: no worktrees
// in pool`. Exit 0; the workspace is not written.
//
// return: --force, --if-lease-id <id>, --repo <p>, ANY other word the target
// (last wins); `ERROR: return: worktree path or slot name required`. Not a
// directory: with a `/` `ERROR: return: no such directory: <wt>`, else a slot
// of the pool of --repo or the cwd's repo, else `ERROR: return: no such slot
// <wt> in the pool of <repo>`. The physical path; its main root, else `ERROR:
// return: not a git worktree: <wt>`; not under <root>/.crew/worktrees/:
// `ERROR: return: not an agent-crew pool worktree: <wt>`; no meta: `ERROR:
// return: unmanaged slot: <wt>`. claimReturn under the lock: --if-lease-id
// against lease_id - `ERROR: return: slot <n> holds lease <id or none>, not
// <want> - refusing (the slot was re-leased; nothing was reset)`; without
// --force the verified state is pinned, then dirty is `ERROR: return: worktree
// is dirty; land the work or pass --force to discard: <wt>`; owner_pid is
// re-owned to this process (a write that fails ends the run, exit 1, before
// any reset). Unlocked: the proc-kill, then --force's reset (default ref) or
// the pinned one - moved is `ERROR: return: worktree changed after it was
// verified clean, so nothing was reset - inspect it, then return --force to
// discard: <wt>`, failed `ERROR: return: reset failed for <wt>` (the lease is
// left owned by a pid that dies). Under the lock: leased=0, owner_pid=,
// lease_id= in one rewrite - one that fails is `ERROR: return: cannot record
// the release in <meta> - slot <n> stays leased to this return until a get
// reclaims it`. The workspace, `WARN: worktree slot <n> returned to pool`,
// nothing on stdout.
// PROC-KILL: no lsof on PATH is `WARN: cannot enumerate processes inside <wt>
// (lsof unavailable) - none killed`; else the pids `lsof -t +D <wt>` names
// (byte order, unique) minus the caller's ancestry (`ps -o ppid= -p` walked
// to pid 1, at most 128 hops; a walk that fails is `WARN: could not walk the
// caller's ancestry (ps) - protecting only this process from the kill`);
// any: `WARN: terminating processes still inside <wt>`, SIGTERM, `sleep 2`,
// SIGKILL to the survivors, then up to 20 `sleep 0.1` waits for them to go,
// else `WARN: processes still present after SIGKILL: <pids> - continuing (git
// may contend on index.lock)`.
//
// prune: --repo, --yes (`ERROR: prune: unknown argument <a>`, `ERROR: prune:
// --repo is required`). Under the lock: heal; with origin, `git fetch origin
// --quiet` and then `git ls-remote origin refs/heads/<default>`, each bounded
// as get's fetch: a fetch past the deadline is reason `origin fetch timed out
// after <t>s (cannot verify)`, one failing `origin unreachable (cannot
// verify)`; an ls-remote past it `origin ls-remote timed out after <t>s
// (cannot verify)`, one failing `origin unreachable (cannot verify)`; a
// non-empty first field of its output that is not
// refs/remotes/origin/<default> is `origin/<default> stale vs remote (cannot
// verify)`. Per slot on stdout, the first that applies: `skip slot
// <n>: meta unreadable (treated as leased)` (after its WARN), `skip slot
// <n>: leased` (and not reclaimable), `skip slot <n>: worktree broken (git
// cannot read the slot itself)`, `skip slot <n>: dirty`, `skip slot <n>:
// cannot check for live processes (lsof unavailable)`, `skip slot <n>: in-use
// (live processes)`, `skip slot <n>: <reason>`, HEAD not an ancestor of
// defaultRef nor of the task's fence branch (refs/heads/<b> or
// refs/remotes/origin/<b>; rc 2 is `ERROR: prune: cannot read the ledger to
// resolve the epic-branch fence for <task>`, mid-loop) `skip slot <n>: HEAD
// not merged into <ref>`; then --yes drops it, `pruned slot <n>`, else `would
// prune slot <n>: <wt> (run with --yes)`. The workspace - written even for a
// pool that never leased (W9).
//
// remove: --force, --include-leased, ANY other word the path (last wins);
// `ERROR: remove: worktree path required`; `ERROR: remove: no such directory:
// <wt>` (no slot-name form); the physical path; its main root, else the root
// of the path cut at its last `/.crew/worktrees/` (a broken slot's only way
// out), else `ERROR: remove: not a git worktree: <wt>`; `ERROR: remove: not an
// agent-crew pool worktree: <wt>`. Under the lock: `ERROR: remove: unmanaged
// slot: <wt>`; without --include-leased, a meta that cannot be read (after
// its WARN) is `ERROR: remove: slot <n>'s meta cannot be read, so it is
// treated as leased; pass --include-leased to take it anyway`, and leased and
// live is `ERROR: remove: slot <n> is leased (task <task>); pass
// --include-leased to take it anyway`;
// without --force, broken is `ERROR: remove: slot <n> is broken (gitdir
// unreadable) so its contents cannot be checked; use --force to discard`,
// dirty `ERROR: remove: worktree is dirty; use --force to discard`, a HEAD in
// neither the default ref nor the task's fence branch `ERROR: remove: slot <n>
// holds commits not merged into the default branch; use --force to discard`
// (rc 2: `ERROR: remove: cannot read the ledger to resolve the epic-branch
// fence for <task>`); the proc-kill, the drop, `WARN: removed slot <n>`. The
// workspace.
//
// GUARD HOOKS (get, under the lock). A set core.hooksPath is `WARN:
// core.hooksPath is set; skipping commit-guard install (the guards cover only
// the default shared hooks)` and neither is installed: a relative value
// resolves per-worktree, a tracked dir would dirty the primary, /dev/null
// would abort the lease. Into `git rev-parse --path-format=absolute
// --git-path hooks` (none: silently skipped) go pre-commit (sentinel
// ac-crew-primary-commit-guard, label commit-guard) then commit-msg
// (ac-crew-agent-trailer-guard, agent-trailer-guard), each fail-open - a
// guard is a safety net, never a lease blocker: a symlink hook (a hook
// manager's) is `WARN: <hook> is a symlink (hook-manager managed); skipping
// <label> install to leave it untouched (<path>)`. The body is staged in
// <hook>.ac-crew-tmp.<pid> (`WARN: could not stage <label>; leaving any
// existing hook untouched (<path>)`) and `chmod +x`ed (umask applies; `...
// stage <label> (chmod); ...`). OURS (a regular file holding the sentinel):
// byte-identical is silent; else the old bytes are `cp -p`ed to
// <hook>.ac-crew-stale-<epoch> - never onto .ac-crew-prev, which a chained
// project hook owns and run_chained EXECs (a taken name or a failed copy:
// `WARN: could not preserve the outdated <label>; leaving it in place
// (<path>)`) - and the staged body renamed over it (`WARN: could not upgrade
// the outdated <label> (<path>)`; done: `WARN: upgraded the outdated <label>
// at <path> (previous bytes kept at <bak>)`). FOREIGN: chained, never
// clobbered - <hook>.ac-crew-prev taken is `WARN: <hook> present and
// <hook>.ac-crew-prev already taken; skipping <label> install to avoid
// clobbering a project hook (<path>)`, a failed `cp -p` to it `WARN: could
// not preserve existing <hook> hook; skipping <label> install to avoid
// clobbering it (<path>)`, else `WARN: chained existing <hook> hook aside to
// <hook>.ac-crew-prev`. Then the rename (`WARN: could not install <label>
// (<path>)`) and `WARN: installed <label> at <path>`. The two bodies are
// BASH, byte-identical to the frozen original's heredocs (a changed byte
// would upgrade every onboarded repo and leave a stale sidecar there) - the
// git-hook ruling (CONTRIBUTING.md) keeps them shell, never bun.
//
// LOCK SCOPE. Under the pool lock: the hook install, acquire, lease, list,
// return's claim and release, prune, remove. Not under it: the exclude and
// .gitignore writes (W8), get's bounded fetch, the fence, the include
// seeding, and the workspace regeneration (last writer wins, a stale view
// possible - W16). The claim, the release and the crew-meta append also hold
// their meta's own lock (src/lib.ts metaUpdate, the one ac_meta_set takes):
// the pool lock does not cover the crew meta's other writers - ac-spawn's
// keys, the same task leasing from a second pool - and every one of them
// waits on that lock, so the append lands whole, before or after it (short
// of the lock protocol's two-reclaimer residual, bin/ac-lib.sh). Prune's
// bounded fetch and ls-remote hold the pool lock for up to twice the sync
// knob (the lock is left as it is, and the sync knob
// bounds them), past the 30 seconds a waiter gives it at the default 60.
//
// AT PARITY: W9-W13, W15 (get --id mints the
// home's records/ and state/), W16, W18 (`--prefer ''` is ignored; `--prefer
// 1x-y` passes as an id).
//
// DIVERGENCES from the original, named in the differential leg:
// - USAGE HEADER: the usage is this header; the original printed its own.
// - FAIL-PATH ARTIFACTS: a refusal under the pool lock releases it - the
//   original's die left .crew/lock/ holding a dead pid (W7); and the
//   install never reads our own guard as foreign for want of grep (W14 is
//   unreachable in-process).
// - THE NETWORK IS BOUNDED (W3):
//   get's fetch and prune's fetch and ls-remote end at the sync knob's
//   deadline with the texts above, where the original waited a stalled
//   origin out; and an ls-remote that fails after a fetch that worked cannot
//   verify, where the original's `| awk` hid its status and pruned on the
//   fetched ref.
// - POOL METAS FAIL CLOSED:
//   a slot meta that cannot be read is a lease in list,
//   prune, remove and the workspace, where the original read it as unleased
//   (W5) or ended the verb after its mutation (W4); a stamp, release or
//   crew-meta append that cannot be written dies, where the original went on
//   (W6) or dropped a concurrent writer's append (W2); a workspace that
//   cannot be written is a WARN, where the original ended the verb. The texts
//   are the verbs' above.
// - EXCLUSIVE TEMPS: the slot meta's, the hook's, the workspace's, the
//   .gitignore's and every meta rewrite's <file>.<tag>.<pid> is created
//   exclusively (the next .<n> past a name already taken); the original
//   wrote through whatever sat at the predictable name, and reused it, where
//   a rewrite whose rename failed leaves its own temp each time.
// - SHELL-OWN STDERR is not reproduced: `$2: unbound variable`, `[: <v>:
//   integer expression expected`, a failed redirection's `Permission denied`,
//   an arithmetic expansion's error, `mv:`'s line after a meta rewrite whose
//   temp could not be written, `cd:`'s own line - the exit statuses are kept.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is named
//   (`ERROR: AC_HOME is not a readable directory: <h>`) wherever the original
//   printed cd's own line.
// - The fence reads the ledger in-process, so the original's bun-missing arm
//   (the backlog parser failing, rc 2) is unreachable - without bun the shim
//   never starts - and an unreadable ledger is the refusal alone, without
//   awk's `can't open file` pair before it.
// - The caller's cwd arrives physical: a `return <name>` with no --repo from a
//   symlinked cwd names the physical path in a refusal, a relative path is
//   resolved against it, and a caller whose cwd has no name resolves no
//   relative path at all (the original's stale $PWD).
// - Bytes: argv arrives decoded (U+FFFD for a byte that is not UTF-8), and a
//   path read back from git reaches a git argv the same way.
//
// CALLERS (all EXECUTE the entry): bin/ac-spawn.sh and bin/ac-self-task.sh
// `get --repo <project> --id <id> --holder <h> [--prefer <wt>]` bare under
// errexit (stdout compared byte for byte to the old worktree= on resume) and
// `return <wt> --force` in their EXIT traps, both reading the slot meta's
// lease_id themselves; bin/ac-teardown.sh `return <lease> --force
// [--if-lease-id <id>]` per lease and verifier, soft; src/verify.ts `get
// ... | tail -n 1` and `return <lease> --force`; src/pool-health.ts `list`.
// A crewmate's second lease and the skills' verbs are run by hand.

import { appendFileSync, closeSync, lstatSync, openSync, readdirSync, readFileSync, statSync, unlinkSync, writeSync } from "node:fs";
import {
  arithValue,
  commandV,
  crewStateDir,
  defaultBranch,
  defaultRef,
  die,
  enterCaller,
  epicBaseFor,
  freshestRef,
  iso,
  lockAcquire,
  lockRelease,
  metaGet,
  metaUpdate,
  nowRaw,
  physicalDir,
  repoRoot,
  runBounded,
  shellStatus,
  softHome,
  spawnShellSync,
  syncTimeout,
  testInt,
  trimShellSpaceBytes,
  warn,
  worktreeStatus,
} from "./lib.ts";

// The original's two heredocs, line for line (tests/ts/tree.test.ts holds the
// installed bytes to the frozen fixture's). Not template literals: the bodies
// carry `${...}` and backquotes.
const PRE_COMMIT_GUARD = [
  "#!/usr/bin/env bash",
  "# ac-crew-primary-commit-guard - REFUSE a git commit made in the PRIMARY",
  "# checkout by a crewmate or roomchief. Installed once at lease time by",
  "# ac-tree.sh; shared across the primary checkout and every linked worktree.",
  "# D1 (WHERE): git-dir == git-common-dir  <=>  the PRIMARY checkout (a leased",
  "#   worktree's git-dir is <common>/worktrees/<n> and never equals common).",
  "# D2 (WHO):   AC_CREW_ID or AC_SCOPE set  <=>  a crewmate/roomchief. The captain",
  "#   carries neither, so a captain commit is never refused.",
  "# Fail-OPEN: any rev-parse error skips ONLY this guard, never fail-closed onto",
  "#   the captain and never suppressing a chained project hook. --no-verify remains",
  "#   a bypass, forbidden to crewmates by policy.",
  "run_chained() {",
  "  # Hand off to a preserved prior hook (E1) if present, else pass. Reached on",
  "  # EVERY non-refuse path, including a fail-open rev-parse error.",
  "  local prev; prev=\"$(dirname \"$0\")/pre-commit.ac-crew-prev\"",
  "  [ -x \"$prev\" ] && exec \"$prev\" \"$@\"",
  "  exit 0",
  "}",
  "gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || run_chained \"$@\"",
  "cm=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || run_chained \"$@\"",
  "if [ \"$gd\" = \"$cm\" ] && { [ -n \"${AC_CREW_ID:-}\" ] || [ -n \"${AC_SCOPE:-}\" ]; }; then",
  "  # D1 && D2: a crewmate/roomchief committing in the PRIMARY checkout. The",
  "  # primary root is the git-common-dir's PARENT (<primary>/.git -> <primary>),",
  "  # so no extra rev-parse is needed - and we are refusing regardless.",
  "  printf 'ac-crew: REFUSED a commit in the PRIMARY checkout (%s).\\n' \"${cm%/*}\" >&2",
  "  printf 'ac-crew: commit in YOUR leased worktree on crew/<id>, never in the primary checkout.\\n' >&2",
  "  printf 'ac-crew: leave the primary working tree ALONE - no checkout/restore/reset; report the edit.\\n' >&2",
  "  exit 1",
  "fi",
  "run_chained \"$@\"",
  "",
].join("\n");

const COMMIT_MSG_GUARD = [
  "#!/usr/bin/env bash",
  "# ac-crew-agent-trailer-guard - REFUSE a commit message carrying an AGENT",
  "# co-author trailer (AGENTS.md section 13). The harness instructs every session",
  "# to add one and repo law forbids it, and until this hook the only thing between",
  "# them was a reviewer remembering - one already reached a commit and was caught",
  "# by hand at verify.",
  "# WHY commit-msg AND NOT pre-commit: pre-commit runs before the message exists",
  "#   (COMMIT_EDITMSG still holds the PREVIOUS commit's text there), so this is",
  "#   the only git seam that can read what is being committed. And it has to be",
  "#   the earliest one: a refusal at landing time costs an amend or a rebase, and",
  "#   a trailer already in landed history costs a rewrite, which is a captain act.",
  "# WHO: everyone. The rule is about agent attribution in a public-source repo,",
  "#   not about who typed the commit.",
  "# NOT a human co-author: pairing attribution is legitimate and stays untouched,",
  "#   and that includes a human whose name or address carries a vendor word - the",
  "#   agent tokens are matched WHOLE, against the NAME, never the email domain.",
  "# THE TRAILERS GIT PARSES, never the raw file: a verbose commit (`git commit -v`,",
  "#   commit.verbose=true) leaves the diff below the scissors line in this file,",
  "#   and a diff CONTEXT line starts with one space, so a raw grep refused any",
  "#   commit whose diff merely MENTIONED the trailer - including commits to the",
  "#   test that proves this hook. `git interpret-trailers --parse` returns the",
  "#   message's real trailers and nothing else.",
  "# Fail-OPEN on an unreadable or unparseable message, and never suppressing a",
  "#   chained hook.",
  "run_chained() {",
  "  local prev; prev=\"$(dirname \"$0\")/commit-msg.ac-crew-prev\"",
  "  [ -x \"$prev\" ] && exec \"$prev\" \"$@\"",
  "  exit 0",
  "}",
  "msg=\"${1:-}\"",
  "[ -n \"$msg\" ] && [ -r \"$msg\" ] || run_chained \"$@\"",
  "trailers=\"$(git interpret-trailers --parse \"$msg\" 2>/dev/null)\" || run_chained \"$@\"",
  "if grep -qiE '^co-authored-by:[^<]*(^|[^[:alnum:]])(claude|anthropic|openai|chatgpt|gpt|copilot|cursor|codex|gemini|devin|amp|windsurf|codeium|aider|cline|junie|sourcegraph|cognition)([^[:alnum:]]|$)' <<<\"$trailers\"; then",
  "  printf 'ac-crew: REFUSED an agent co-author trailer in this commit message.\\n' >&2",
  "  printf 'ac-crew: AGENTS.md section 13 - never add an agent co-author line to a commit in a project repo.\\n' >&2",
  "  printf 'ac-crew: delete that trailer line and commit again. A HUMAN co-author is fine.\\n' >&2",
  "  exit 1",
  "fi",
  "run_chained \"$@\"",
  "",
].join("\n");

// Byte strings (latin1) carry what the bash held as bytes; argv and the lib's
// paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const byteOrder = (a: string, b: string): number => Buffer.compare(fsPath(a), fsPath(b));

let atCaller = true;
// The pool lock this process holds, released on any exit (a refusal under it
// included) - the original's die left it behind holding a dead pid.
let held: string | null = null;
process.on("exit", () => {
  if (held !== null) lockRelease(held);
});

function out(s: string): void {
  const b = fsPath(s);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function say(msg: string): void {
  warn(fsPath(msg));
}

function fail(msg: string): never {
  die(fsPath(msg));
}

// Inside get's `wt="$(... acquire ...)"` a child's stdout joined the path the
// substitution captured; elsewhere it is the caller's.
let capture: Buffer[] | null = null;

type Io = { stdin?: "inherit" | "ignore" | Buffer; out?: "inherit" | "pipe" | "ignore"; err?: "inherit" | "ignore" };

function run(cmd: string[], io: Io = {}): { status: number; out: Buffer } {
  const want = io.out ?? "inherit";
  const stdout = want === "inherit" && capture !== null ? "pipe" : want;
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: io.stdin ?? "inherit", stdout, stderr: io.err ?? "inherit" });
  } catch {}
  const o = r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0);
  if (want === "inherit" && capture !== null) capture.push(o);
  return { status: shellStatus(r), out: o };
}

function git(dir: string, args: string[], io: Io = {}): { status: number; out: Buffer } {
  return run(["git", "-C", u8(dir), ...args.map(u8)], io);
}

const quiet: Io = { out: "ignore", err: "ignore" };

function isFile(p: string): boolean {
  try {
    return statSync(fsPath(p)).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string): boolean {
  try {
    return statSync(fsPath(p)).isDirectory();
  } catch {
    return false;
  }
}

function isLink(p: string): boolean {
  try {
    return lstatSync(fsPath(p)).isSymbolicLink();
  } catch {
    return false;
  }
}

const exists = (p: string): boolean => {
  try {
    statSync(fsPath(p));
    return true;
  } catch {
    return false;
  }
};

// A path argument as `[ -d ]` read it from the caller's cwd; a caller whose
// cwd has no name resolves no relative path.
const isDirArg = (p: string): boolean => (atCaller || p.startsWith("/")) && isDir(p);

function basename(p: string): string {
  if (p === "") return "";
  const s = p.replace(/\/+$/, "");
  return s === "" ? "/" : s.slice(s.lastIndexOf("/") + 1);
}

function dirname(p: string): string {
  let s = p.replace(/\/+$/, "");
  if (s === "") return p.startsWith("/") ? "/" : ".";
  const i = s.lastIndexOf("/");
  if (i < 0) return ".";
  s = s.slice(0, i).replace(/\/+$/, "");
  return s === "" ? "/" : s;
}

const slotMeta = (repo: string, n: string): string => `${repo}/.crew/slots/${n}.meta`;
const slotPath = (repo: string, n: string): string => `${repo}/.crew/worktrees/${n}`;

// `.crew/slots/*.meta` as the glob listed it (a dotfile never matches), in
// byte order; each caller still tests `[ -f ]` when it reaches one.
function slotMetas(repo: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(fsPath(`${repo}/.crew/slots`), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  return names.filter((x) => !x.startsWith(".") && x.endsWith(".meta")).sort(byteOrder).map((x) => `${repo}/.crew/slots/${x}`);
}

const metaName = (meta: string): string => basename(meta).slice(0, -".meta".length);

// A meta read that tells an unreadable file (its WARN printed) from an absent
// key: null, which every pool verb reads as a lease nobody can name.
function metaRead(file: string, key: string): string | null {
  try {
    return metaGet(u8(file), key);
  } catch {
    return null;
  }
}

const metaSoft = (file: string, key: string): string => metaRead(file, key) ?? "";

// A rewrite's status: mv's, 1 when the temp could not be written or the meta
// lock not taken.
function metaUpdateStatus(file: string, pairs: (get: (key: string) => string) => [string, string][]): number {
  try {
    metaUpdate(u8(file), pairs);
    return 0;
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
}

// <file>.<tag>.<pid>, or <file>.<tag>.<pid>.<n> past a name already taken:
// created EXCLUSIVELY, never written through what sat there.
function claimTemp(file: string, tag: string): { path: string; fd: number } {
  let path = `${file}.${tag}.${process.pid}`;
  for (let n = 1; ; n++) {
    try {
      return { path, fd: openSync(fsPath(path), "wx") };
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      path = `${file}.${tag}.${process.pid}.${n}`;
    }
  }
}

// The temp holding <body>, or null when it could not be written.
function stage(file: string, tag: string, body: string): string | null {
  let t: { path: string; fd: number };
  try {
    t = claimTemp(file, tag);
  } catch {
    return null;
  }
  try {
    writeSync(t.fd, fsPath(body));
  } catch {
    closeSync(t.fd);
    unlinkQuiet(t.path);
    return null;
  }
  closeSync(t.fd);
  return t.path;
}

function unlinkQuiet(p: string): void {
  try {
    unlinkSync(fsPath(p));
  } catch {}
}

// The shell's `kill -0 <word>`: the word read as a number the way the builtin
// reads one (else no such process), narrowed to a pid_t; a process this user
// may not signal reads as gone.
function kill0(word: string): boolean {
  const v = testInt(word);
  if (v === null) return false;
  try {
    process.kill(Number(BigInt.asIntN(32, v)), 0);
    return true;
  } catch {
    return false;
  }
}

// A lease whose recorded owner pid is provably dead self-heals. No owner =
// durable.
function leaseReclaimable(meta: string): boolean {
  const owner = metaSoft(meta, "owner_pid");
  return owner !== "" && !kill0(owner);
}

function hasOrigin(repo: string): boolean {
  return git(repo, ["remote", "get-url", "origin"], quiet).status === 0;
}

function resolveRepo(arg: string): string {
  const r = atCaller || arg.startsWith("/") ? repoRoot(u8(arg)) : null;
  if (r === null) fail(`not a git repository: ${arg}`);
  const repo = b8(r);
  if (repo.includes("/.crew/worktrees/")) fail(`refusing to manage a pool inside a pool worktree: ${repo}`);
  return repo;
}

// `mkdir -p` where errexit was awake: its failure ends the run with its status.
function mkdirOrExit(...dirs: string[]): void {
  const st = run(["mkdir", "-p", ...dirs.map(u8)]).status;
  if (st !== 0) process.exit(st);
}

const sleepFor = (s: string): void => {
  run(["sleep", s]);
};

function takePoolLock(repo: string): void {
  const lock = `${repo}/.crew/lock`;
  mkdirOrExit(`${repo}/.crew`);
  if (!lockAcquire(u8(lock), 30, () => sleepFor("1"))) fail(`could not acquire pool lock: ${lock}`);
  held = u8(lock);
}

function dropPoolLock(): void {
  lockRelease(held!);
  held = null;
}

// with_pool_lock: the callback's status, the lock released whatever it is.
function withPoolLock(repo: string, fn: () => number): number {
  takePoolLock(repo);
  const rc = fn();
  dropPoolLock();
  return rc;
}

// A callback's status where the original called with_pool_lock bare.
function locked(repo: string, fn: () => number): void {
  const rc = withPoolLock(repo, fn);
  if (rc !== 0) process.exit(rc);
}

// locked() for a callback that awaits the network (prune's bounded fetch).
async function lockedAsync(repo: string, fn: () => Promise<number>): Promise<void> {
  takePoolLock(repo);
  const rc = await fn();
  dropPoolLock();
  if (rc !== 0) process.exit(rc);
}

// git answers for the slot ITSELF. A slot whose .git file is gone still gets
// an answer: git walks up to the primary checkout around it, so a git-dir
// probe reads it healthy and every status, reset or merged check after it
// judges the primary instead.
function slotGitOk(wt: string): boolean {
  const r = git(wt, ["rev-parse", "--show-toplevel"], { out: "pipe", err: "ignore" });
  if (r.status !== 0) return false;
  return (physicalDir(u8(subst(r.out))) ?? "") === (physicalDir(u8(wt)) ?? "");
}

const isDirty = (wt: string): boolean => subst(fsPath(worktreeStatus(u8(wt)).out)) !== "";

// The tree state a destructive gate verifies, as one comparable blob: the
// HEAD a reset would move off, and the porcelain isDirty judged. A git
// failure contributes its own token rather than nothing, so a tree that went
// unreadable between two reads cannot compare equal to the clean one it was
// verified as.
function verifiedState(wt: string): string {
  const h = git(wt, ["rev-parse", "HEAD"], { out: "pipe", err: "ignore" });
  let s = h.out.toString("latin1") + (h.status === 0 ? "" : "head-unreadable\n");
  const st = worktreeStatus(u8(wt));
  s += st.out + (st.status === 0 ? "" : "status-unreadable\n");
  return subst(fsPath(s));
}

// Detach onto <ref> (the freshest default ref when none), drop local changes
// and untracked files (ignored files survive: caches). qa run state is swept
// explicitly - it is ignored, so clean keeps it, and a stale ports.env or
// serve.pid must never leak to the next lessee - and an interrupted rebase,
// cherry-pick or bisect survives checkout and reset, so each is quit first.
function resetWorktree(repo: string, wt: string, ref = ""): boolean {
  if (!slotGitOk(wt)) return false;
  run(["rm", "-rf", u8(`${wt}/.crew/qa`)], { err: "ignore" });
  for (const a of [["rebase", "--quit"], ["cherry-pick", "--quit"], ["bisect", "reset"]]) git(wt, a, quiet);
  if (ref === "") ref = b8(freshestRef(u8(repo)));
  return (
    git(wt, ["checkout", "--detach", "--force", "--quiet", ref]).status === 0 &&
    git(wt, ["reset", "--hard", "--quiet", ref]).status === 0 &&
    git(wt, ["clean", "-fdq"]).status === 0
  );
}

// Re-read the state the caller verified and REFUSE the reset (2) when it
// moved. return's dirty check runs under the pool lock while its reset runs
// outside it, across a whole-tree lsof and a kill grace; acquire's runs under
// a lock that excludes pool operations but not a process still alive in the
// slot. Widening a lock over either window is no alternative: the pool lock
// is not re-entrant. Refusing costs a wedged slot the pool can report;
// resetting live work is unrecoverable.
function resetIfUnchanged(repo: string, wt: string, ref: string, verified: string): number {
  if (verifiedState(wt) !== verified) return 2;
  return resetWorktree(repo, wt, ref) ? 0 : 1;
}

// This process and every ancestor up to pid 1, or null when the walk could
// not be completed (ps missing, or a ppid it could not read).
function callerAncestors(): string[] | null {
  const pids: string[] = [];
  let pid = process.pid;
  for (let hops = 0; pid > 1; hops++) {
    pids.push(String(pid));
    if (hops >= 128) return null;
    const r = run(["ps", "-o", "ppid=", "-p", String(pid)], { out: "pipe", err: "ignore" });
    const ppid = r.out.toString("latin1").replace(/[ \t\n\v\f\r]/g, "");
    if (r.status !== 0 || !/^[0-9]+$/.test(ppid)) return null;
    pid = Number(ppid);
  }
  pids.push("1");
  return pids;
}

// Pids with cwd or open files under <wt>, minus the caller's own ancestry - a
// chief or crewmate running `return` from INSIDE the slot has its shell, its
// pane and any pipeline sibling there. null means the walk COULD NOT BE MADE
// (no lsof - `lsof -t` exits 1 for "none" and for its own errors alike, so
// absence is the only failure it can name); "" means it found nobody.
function liveProcs(wt: string): string | null {
  if (!commandV("lsof")) return null;
  let keep = callerAncestors();
  if (keep === null) {
    say("could not walk the caller's ancestry (ps) - protecting only this process from the kill");
    keep = [String(process.pid)];
  }
  const lines = run(["lsof", "-t", "+D", u8(wt)], { out: "pipe", err: "ignore" }).out.toString("latin1").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return [...new Set(lines)].sort(byteOrder).filter((p) => !keep.includes(p)).join("\n").replace(/\n+$/, "");
}

function signal(pids: string, sig: NodeJS.Signals): void {
  for (const p of pids.split(/[ \t\n]+/)) {
    if (!/^[0-9]+$/.test(p)) continue;
    try {
      process.kill(Number(p), sig);
    } catch {}
  }
}

// Wait, BOUNDED, for SIGKILLed pids to leave the process table: both kill
// callers run a git command straight afterwards that takes index.lock, and a
// pid that will never go (a zombie whose parent lives) must not hang the pool.
function reapPids(pids: string): void {
  let left = "";
  for (let waited = 0; waited < 20; waited++) {
    left = "";
    for (const p of pids.split(/[ \t\n]+/)) if (p !== "" && kill0(p)) left += ` ${p}`;
    if (left === "") return;
    sleepFor("0.1");
  }
  say(`processes still present after SIGKILL:${left} - continuing (git may contend on index.lock)`);
}

// SIGTERM, a short grace, SIGKILL to the survivors (detached servers ignore
// SIGHUP), then reapPids.
function killWorktreeProcs(wt: string): void {
  let pids = liveProcs(wt);
  if (pids === null) {
    say(`cannot enumerate processes inside ${wt} (lsof unavailable) - none killed`);
    return;
  }
  if (pids === "") return;
  say(`terminating processes still inside ${wt}`);
  signal(pids, "SIGTERM");
  sleepFor("2");
  pids = liveProcs(wt) ?? "";
  if (pids !== "") {
    signal(pids, "SIGKILL");
    reapPids(pids);
  }
}

function dropSlot(repo: string, n: string): void {
  const wt = slotPath(repo, n);
  git(repo, ["worktree", "remove", "--force", wt], quiet);
  run(["rm", "-rf", u8(wt)]);
  run(["rm", "-f", u8(slotMeta(repo, n))]);
  git(repo, ["worktree", "prune"], quiet);
}

// Drop slots whose worktree DIRECTORY vanished: nothing is left there to lose.
// A slot whose dir survives with a broken gitdir is NOT dropped - its files may
// be unlanded work, and the signal that would prove otherwise is exactly the
// one a broken gitdir takes away (git status fails EMPTY there and reads
// clean). Heal runs at every spawn, so failing toward rm -rf would be silent
// and unrecoverable, while a skip costs a wedged slot the WARN names the exact
// reclaim for.
function healSlots(repo: string): void {
  for (const meta of slotMetas(repo)) {
    if (!isFile(meta)) continue;
    const n = metaName(meta);
    const wt = slotPath(repo, n);
    if (!isDir(wt)) {
      say(`healed slot ${n} (worktree dir vanished)`);
      dropSlot(repo, n);
    } else if (!slotGitOk(wt)) {
      const flags = (metaRead(meta, "leased") ?? "1") === "1" ? "--force --include-leased" : "--force";
      say(`slot ${n}: worktree broken (gitdir unreadable) - NOT healed, its files may be unlanded work git can no longer report; reclaim it deliberately with: bin/ac-tree.sh remove ${flags} ${wt}`);
    }
  }
}

function hasLine(text: string, line: string): boolean {
  return text.split("\n").includes(line);
}

function readText(p: string): string | null {
  try {
    return readFileSync(fsPath(p), "latin1");
  } catch {
    return null;
  }
}

// /.crew/ ignored per clone via info/exclude (never tracked, so it can never
// be committed upstream), resolved with --git-path so a linked worktree lands
// it where git reads it. Self-heal: an exact /.crew/ line an earlier version
// appended to the TRACKED .gitignore is removed - and only it - unless HEAD
// commits it (project content); a .gitignore it leaves empty and git does not
// track is deleted.
function ensureGitignore(repo: string): void {
  const r = git(repo, ["rev-parse", "--git-path", "info/exclude"], { out: "pipe" });
  if (r.status !== 0) process.exit(r.status);
  let ex = subst(r.out);
  if (!ex.startsWith("/")) ex = `${repo}/${ex}`;
  if (!hasLine(readText(ex) ?? "", "/.crew/")) {
    mkdirOrExit(ex.includes("/") ? ex.slice(0, ex.lastIndexOf("/")) : ex);
    const cur = readText(ex) ?? "";
    try {
      if (cur.length > 0 && !["\n", "\0"].includes(cur[cur.length - 1]!)) appendFileSync(fsPath(ex), "\n");
      appendFileSync(fsPath(ex), "/.crew/\n");
    } catch {
      process.exit(1);
    }
    say(`added /.crew/ to ${ex}`);
  }
  const gi = `${repo}/.gitignore`;
  if (!isFile(gi) || !hasLine(readText(gi) ?? "", "/.crew/")) return;
  if (hasLine(git(repo, ["show", "HEAD:.gitignore"], { out: "pipe", err: "ignore" }).out.toString("latin1"), "/.crew/")) return;
  const lines = (readText(gi) ?? "").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const kept = lines.filter((l) => l !== "/.crew/").map((l) => `${l}\n`).join("");
  const staged = stage(gi, "tmp", kept);
  const tmp = staged ?? `${gi}.tmp.${process.pid}`;
  let st: number;
  if ((staged !== null && kept !== "") || git(repo, ["ls-files", "--error-unmatch", ".gitignore"], quiet).status === 0) st = run(["mv", u8(tmp), u8(gi)]).status;
  else st = run(["rm", "-f", u8(tmp), u8(gi)]).status;
  if (st !== 0) process.exit(st);
  say("migrated: /.crew/ ignore moved to .git/info/exclude");
}

// One guard hook (header: GUARD HOOKS). The sentinel decides PROVENANCE only,
// never freshness - it cannot see the body change - so freshness is decided
// after staging, against the bytes we would write now. A failed write, chmod
// or rename must never leave the hook empty, partial or missing: that would
// silently disable the project's own hook.
function guardInstall(hook: string, sentinel: string, label: string, body: string): void {
  const name = basename(hook);
  if (isLink(hook)) {
    say(`${name} is a symlink (hook-manager managed); skipping ${label} install to leave it untouched (${hook})`);
    return;
  }
  const ours = isFile(hook) && (readText(hook) ?? "").includes(sentinel);
  run(["mkdir", "-p", u8(dirname(hook))]);
  const prev = `${hook}.ac-crew-prev`;
  const tmp = stage(hook, "ac-crew-tmp", body);
  if (tmp === null) {
    say(`could not stage ${label}; leaving any existing hook untouched (${hook})`);
    return;
  }
  if (run(["chmod", "+x", u8(tmp)]).status !== 0) {
    unlinkQuiet(tmp);
    say(`could not stage ${label} (chmod); leaving any existing hook untouched (${hook})`);
    return;
  }
  if (ours) {
    const now = readText(hook);
    if (now !== null && now === readText(tmp)) {
      unlinkQuiet(tmp);
      return;
    }
    // Never onto .ac-crew-prev: that name is a chained project hook's, and
    // run_chained EXECs it. Epoch-stamped and never clobbered, so a second
    // upgrade cannot destroy a preserved hand-edit; git runs only the exact
    // hook names, so a stamped sidecar never runs.
    const bak = `${hook}.ac-crew-stale-${nowRaw()}`;
    if (exists(bak) || run(["cp", "-p", u8(hook), u8(bak)]).status !== 0) {
      unlinkQuiet(tmp);
      say(`could not preserve the outdated ${label}; leaving it in place (${hook})`);
      return;
    }
    if (run(["mv", u8(tmp), u8(hook)]).status !== 0) {
      unlinkQuiet(tmp);
      say(`could not upgrade the outdated ${label} (${hook})`);
      return;
    }
    say(`upgraded the outdated ${label} at ${hook} (previous bytes kept at ${bak})`);
    return;
  }
  if (exists(hook)) {
    // Copied aside, never moved, so the hook is never absent before the swap;
    // a sidecar already taken (a hook manager replaced our guard after an
    // earlier chain) keeps the project's own hook.
    if (exists(prev)) {
      unlinkQuiet(tmp);
      say(`${name} present and ${basename(prev)} already taken; skipping ${label} install to avoid clobbering a project hook (${hook})`);
      return;
    }
    if (run(["cp", "-p", u8(hook), u8(prev)]).status !== 0) {
      unlinkQuiet(tmp);
      say(`could not preserve existing ${name} hook; skipping ${label} install to avoid clobbering it (${hook})`);
      return;
    }
    say(`chained existing ${name} hook aside to ${basename(prev)}`);
  }
  if (run(["mv", u8(tmp), u8(hook)]).status !== 0) {
    unlinkQuiet(tmp);
    say(`could not install ${label} (${hook})`);
    return;
  }
  say(`installed ${label} at ${hook}`);
}

// Under the pool lock: two concurrent first leases must not interleave the
// install, or one can move the other's fresh guard onto the chained sidecar
// and self-exec forever. One install in the default shared hooks dir covers
// the primary and every linked worktree.
function ensureCommitGuard(repo: string): number {
  if (git(repo, ["config", "--get", "core.hooksPath"], quiet).status === 0) {
    say("core.hooksPath is set; skipping commit-guard install (the guards cover only the default shared hooks)");
    return 0;
  }
  const r = git(repo, ["rev-parse", "--path-format=absolute", "--git-path", "hooks"], { out: "pipe", err: "ignore" });
  const hooks = subst(r.out);
  if (r.status !== 0 || hooks === "") return 0;
  guardInstall(`${hooks}/pre-commit`, "ac-crew-primary-commit-guard", "commit-guard", PRE_COMMIT_GUARD);
  guardInstall(`${hooks}/commit-msg`, "ac-crew-agent-trailer-guard", "agent-trailer-guard", COMMIT_MSG_GUARD);
  return 0;
}

function poolMaxTrees(repo: string): string {
  const env = process.env.AC_MAX_TREES;
  if (env) return b8(env).replace(/\n+$/, "");
  const cfg = `${repo}/.crew/config`;
  if (isFile(cfg)) {
    const v = metaSoft(cfg, "max_trees");
    if (v !== "") return v;
  }
  return "8";
}

function mintLeaseId(): string {
  const r = run(["od", "-An", "-tx1", "-N8", "/dev/urandom"], { out: "pipe", err: "ignore" });
  const id = r.status === 0 ? subst(r.out).replace(/[ \n]/g, "") : "";
  return id !== "" ? id : `${process.pid}-${subst(run(["date", "-u", "+%s"], { out: "pipe" }).out)}`;
}

// A SECOND (or later) lease for the same task folded into the crew meta
// ac-teardown.sh reads, so a task leasing several trees leaks none; never a
// mint (a first lease predates its meta, a verifier's id never gets one).
// Both keys are read and renamed under the meta lock, as one write, so another
// writer of that meta (a crewmate leasing from a second pool, ac-spawn's own
// keys) waits for it (header: LOCK SCOPE). The ids pair with leases= by
// POSITION, so the separator follows leases=: an orca first lease records no
// id. Returns the crew meta it could not write, "" otherwise.
function appendLeaseToCrewMeta(id: string, wt: string, leaseId: string): string {
  if (id === "") return "";
  const sdir = b8(crewStateDir());
  if (sdir === "") return "";
  const sm = `${sdir}/${id}.meta`;
  if (!isFile(sm)) return "";
  const rc = metaUpdateStatus(sm, (get) => {
    const cur = get("leases");
    return [
      ["leases", `${cur === "" ? "" : `${cur}:`}${wt}`],
      ["lease_ids", `${get("lease_ids")}${cur === "" ? "" : ":"}${leaseId}`],
    ];
  });
  return rc === 0 ? "" : sm;
}

// The ONE writer of a slot's lease state (get and lease both mint through it),
// one atomic meta write so a slot is never seen half-leased. A lease is
// recorded in full - the slot meta and the crew meta - or not made: a stamp
// that cannot be written dies with the meta as it was, and a crew meta that
// cannot take the append releases the stamp before dying, so no path is ever
// printed for a lease teardown would not find.
function stampLease(repo: string, n: string, id: string, holder: string, owner: string): void {
  const meta = slotMeta(repo, n);
  const wt = slotPath(repo, n);
  const created = metaSoft(meta, "created_at");
  const leaseId = mintLeaseId();
  const tmp = stage(meta, "tmp", `created_at=${created || iso()}\nleased=1\ntask=${id}\nholder=${holder || "cli"}\nowner_pid=${owner}\nleased_at=${iso()}\nlease_id=${leaseId}\n`);
  if (tmp === null || run(["mv", u8(tmp), u8(meta)]).status !== 0) fail(`cannot record the lease in ${meta} - nothing leased`);
  const sm = appendLeaseToCrewMeta(id, wt, leaseId);
  if (sm === "") return;
  if (releaseSlot(meta) === 0) fail(`cannot record the lease of ${wt} in ${sm} - the slot is released, nothing leased`);
  fail(`cannot record the lease of ${wt} in ${sm}, nor release the slot - return it with: bin/ac-tree.sh return ${wt}`);
}

function acquireSlot(repo: string, id: string, holder: string, owner: string, prefer: string, baseRef: string): number {
  git(repo, ["worktree", "prune"], quiet);
  healSlots(repo);
  let free = "";
  let why = "";
  let n = "";
  let wt = "";
  // A preferred slot is leased exactly when available (a dead owner
  // self-heals here as anywhere); any other state records WHY and falls
  // through, the one warning printed once the fallback is known.
  if (prefer !== "") {
    const meta = slotMeta(repo, prefer);
    wt = slotPath(repo, prefer);
    if (!isFile(meta)) why = "no such slot";
    else {
      const leased = metaSoft(meta, "leased");
      if (leased === "1") {
        if (leaseReclaimable(meta)) say(`reclaiming slot ${prefer} from dead owner ${metaSoft(meta, "owner_pid")}`);
        else why = `leased by task ${metaSoft(meta, "task")}`;
      } else if (leased !== "0") why = "lease state unknown (half-written meta?)";
      if (why === "") {
        // Pinned BEFORE the check it authorizes: a write landing between the
        // two would otherwise be read INTO the pin and blessed by it.
        const verified = verifiedState(wt);
        if (isDirty(wt)) why = "dirty (unlanded work)";
        else {
          const rc = resetIfUnchanged(repo, wt, baseRef, verified);
          if (rc === 0) free = prefer;
          else why = rc === 2 ? "changed under the check (a process still alive in the slot?)" : "reset failed";
        }
      }
    }
  }
  if (free === "") {
    for (const meta of slotMetas(repo)) {
      if (!isFile(meta)) continue;
      n = metaName(meta);
      wt = slotPath(repo, n);
      const leased = metaSoft(meta, "leased");
      if (leased === "1") {
        if (!leaseReclaimable(meta)) continue;
        say(`reclaiming slot ${n} from dead owner ${metaSoft(meta, "owner_pid")}`);
      } else if (leased !== "0") {
        say(`skip slot ${n}: lease state unknown (half-written meta?)`);
        continue;
      }
      const verified = verifiedState(wt);
      if (isDirty(wt)) {
        say(`skip slot ${n}: dirty (unlanded work; inspect or remove --force)`);
        continue;
      }
      const rc = resetIfUnchanged(repo, wt, baseRef, verified);
      if (rc !== 0) {
        say(rc === 2 ? `skip slot ${n}: changed under the check (a process still alive in the slot?)` : `skip slot ${n}: reset failed`);
        continue;
      }
      free = n;
      break;
    }
  }
  if (free !== "") {
    n = free;
    // A legacy bare-numeric slot takes its <n>-<repo> name on reuse; its
    // codegraph index stores absolute paths, so it goes. A refused move keeps
    // the legacy name.
    if (!n.includes("-")) {
      const newn = `${n}-${basename(repo)}`;
      const newwt = slotPath(repo, newn);
      if (git(repo, ["worktree", "move", slotPath(repo, n), newwt], quiet).status === 0) {
        run(["mv", u8(slotMeta(repo, n)), u8(slotMeta(repo, newn))], { err: "ignore" });
        run(["rm", "-rf", u8(`${newwt}/.codegraph`)]);
        say(`migrated slot ${n} -> ${newn}`);
        n = newn;
      }
    }
    wt = slotPath(repo, n);
    say(`reusing worktree slot ${n}`);
  } else {
    let count = 0;
    let highest = "0";
    for (const meta of slotMetas(repo)) {
      if (!isFile(meta)) continue;
      count++;
      const num = metaName(meta).split("-")[0]!;
      const a = testInt(num);
      if (a !== null && a > testInt(highest)!) highest = num;
    }
    const max = poolMaxTrees(repo);
    const cap = testInt(max);
    if (cap === null || !(BigInt(count) < cap)) fail(`pool is full (${count}/${max}); raise max_trees in .crew/config or prune`);
    let next: bigint;
    try {
      next = BigInt.asIntN(64, arithValue(highest) + 1n);
    } catch {
      process.exit(1);
    }
    n = `${next}-${basename(repo)}`;
    wt = slotPath(repo, n);
    // An orphan dir with no meta (a partial create) wedges the number.
    if (exists(wt)) {
      say(`cleaning orphan worktree dir at slot ${n}`);
      git(repo, ["worktree", "remove", "--force", wt], quiet);
      run(["rm", "-rf", u8(wt)]);
      git(repo, ["worktree", "prune"], quiet);
    }
    say(`creating worktree slot ${n}`);
    if (git(repo, ["worktree", "add", "--force", "--detach", "--quiet", wt, baseRef || b8(freshestRef(u8(repo)))]).status !== 0) {
      dropSlot(repo, n);
      fail(`git worktree add failed for slot ${n}`);
    }
  }
  if (why !== "") say(`prefer: slot ${prefer} unavailable (${why}) - leased slot ${n} instead`);
  stampLease(repo, n, id, holder, owner);
  capture!.push(fsPath(`${wt}\n`));
  return 0;
}

function seedWorktreeInclude(repo: string, wt: string): void {
  const r = git(wt, ["show", "HEAD:.worktreeinclude"], { out: "pipe", err: "ignore" });
  if (r.status !== 0) return;
  const lines = `${subst(r.out)}\n`.split("\n");
  lines.pop();
  for (let line of lines) {
    line = trimShellSpaceBytes(line.split("#")[0]!);
    if (line === "") continue;
    if (line.endsWith("/")) line = line.slice(0, -1);
    // .crew is ignored too, and holds this very pool: copying it into a slot
    // copies the pool into itself.
    if (line.startsWith("/") || line === ".." || line.startsWith("../") || line.endsWith("/..") || line.includes("/../") || line === ".crew" || line.startsWith(".crew/")) {
      say(`worktreeinclude: refusing '${line}' (a relative path inside the repo, outside .crew)`);
      continue;
    }
    const src = `${repo}/${line}`;
    const dst = `${wt}/${line}`;
    if (isLink(src)) {
      say(`worktreeinclude: refusing '${line}' (a symlink is never followed)`);
      continue;
    }
    if (!exists(src)) {
      say(`worktreeinclude: skipping '${line}' (absent from the primary checkout)`);
      continue;
    }
    if (git(repo, ["check-ignore", "-q", line], { err: "ignore" }).status !== 0) {
      say(`worktreeinclude: skipping '${line}' (not ignored - it is project content, already in the tree)`);
      continue;
    }
    const ok = isDir(src)
      ? run(["mkdir", "-p", u8(dst)]).status === 0 && run(["cp", "-RP", u8(`${src}/.`), u8(`${dst}/`)]).status === 0
      : run(["mkdir", "-p", u8(dirname(dst))]).status === 0 && run(["cp", "-P", u8(src), u8(dst)]).status === 0;
    if (!ok) say(`worktreeinclude: copy of '${line}' failed`);
  }
}

// <repo>/.crew/<repo>.code-workspace from ACTIVE leases only (header: pool
// layout). Derived and regenerable, so it runs after the locked mutation, the
// last writer wins, and it never fails the verb whose result it shows: an
// unreadable slot meta is listed as a lease with no name, and a file that
// cannot be written is a WARN. No JSON escaping (W11).
function writeWorkspace(repo: string): void {
  const base = basename(repo);
  const ws = `${repo}/.crew/${base}.code-workspace`;
  let folders = `    { "path": "..", "name": "${base} (main)" }`;
  for (const meta of slotMetas(repo)) {
    if (!isFile(meta)) continue;
    const n = metaName(meta);
    if (!isDir(slotPath(repo, n))) continue;
    const leased = metaRead(meta, "leased");
    if (leased !== null && leased !== "1") continue;
    const task = leased === null ? "" : metaSoft(meta, "task");
    folders += `,\n    { "path": "worktrees/${n}", "name": "${task === "" ? `wt${n}` : `wt${n} - ${task}`}" }`;
  }
  const tmp = stage(ws, "tmp", `{\n  "folders": [\n${folders}\n  ]\n}\n`);
  if (tmp === null || run(["mv", u8(tmp), u8(ws)]).status !== 0) say(`cannot write ${ws} - the next pool change rewrites it`);
}

// The value after a value flag; the original's `$2` past the last word was
// set -u's `unbound variable`, exit 1.
function value(a: string[], i: number): string {
  if (i + 1 >= a.length) process.exit(1);
  return b8(a[i + 1]!);
}

async function cmdGet(a: string[]): Promise<void> {
  let repo = "";
  let id = "";
  let holder = "";
  let owner = "";
  let prefer = "";
  for (let i = 0; i < a.length; i += 2) {
    const w = a[i]!;
    if (w === "--repo") repo = value(a, i);
    else if (w === "--id") id = value(a, i);
    else if (w === "--holder") holder = value(a, i);
    else if (w === "--owner") owner = value(a, i);
    else if (w === "--prefer") prefer = value(a, i);
    else fail(`get: unknown argument ${b8(w)}`);
  }
  if (repo === "") fail("get: --repo is required");
  repo = resolveRepo(repo);
  if (prefer !== "") {
    if (prefer.includes("/")) prefer = basename(prefer.endsWith("/") ? prefer.slice(0, -1) : prefer);
    if (prefer === "" || (!/^[0-9][\s\S]*-/.test(prefer) && /[^0-9]/.test(prefer))) fail("get: --prefer expects a slot id/number or a pool worktree path");
    // A bare number names the slot by its prefix (the legacy call shape).
    if (!/[^0-9]/.test(prefer) && !isFile(slotMeta(repo, prefer)) && isFile(slotMeta(repo, `${prefer}-${basename(repo)}`))) prefer = `${prefer}-${basename(repo)}`;
  }
  if (git(repo, ["rev-parse", "HEAD"], quiet).status !== 0) fail(`repository has no commits: ${repo}`);
  ensureGitignore(repo);
  locked(repo, () => ensureCommitGuard(repo));
  mkdirOrExit(`${repo}/.crew/worktrees`, `${repo}/.crew/slots`);
  if (hasOrigin(repo)) {
    const t = syncTimeout();
    const rc = (await runBounded(["git", "-C", u8(repo), "fetch", "origin", "--quiet"], t, "inherit")).status;
    if (rc === 124) say(`fetch origin timed out after ${t}s; using local refs`);
    else if (rc !== 0) say("fetch origin failed; using local refs");
  }
  // The epic/feature fence lives HERE, not in ac-spawn, so the crewmate's own
  // second lease and the --prefer resume lease ride it too. It proves the
  // branch by its FULL refname, but reset and worktree add resolve the SHORT
  // name through git's DWIM order, where a same-named tag wins - so the exact
  // string they will use is verified before any slot is touched.
  let baseRef = "";
  const rname = basename(repo);
  let eb: { rc: 0; entry: string } | { rc: 1 | 2 } = { rc: 1 };
  if (id !== "") {
    // With no home to read - neither AC_HOME nor a pane's AC_FLEET_STATE, or
    // an AC_HOME that cannot be entered - the original's `$(ac_records_dir)`
    // refused on stderr and the fence went on OFF: that line is the only sign
    // it was skipped.
    if (process.env.AC_HOME || !process.env.AC_FLEET_STATE) softHome(true);
    eb = epicBaseFor(u8(id), u8(rname));
  }
  if (eb.rc === 2) fail(`get: cannot read the ledger to resolve the epic-branch fence for ${id}`);
  if (eb.rc === 0) {
    const branch = eb.entry.split(" ")[0]!;
    const ref = (r: string): boolean => git(repo, ["show-ref", "--verify", "--quiet", r]).status === 0;
    if (` ${eb.entry.slice(branch.length)} `.includes(" push=deferred ")) {
      if (!ref(`refs/heads/${branch}`)) fail(`get: feature branch ${branch} does not exist in ${rname} - cut it first: ac-feature.sh create <feature> ${rname}`);
      baseRef = branch;
    } else if (hasOrigin(repo)) {
      if (!ref(`refs/remotes/origin/${branch}`)) fail(`get: epic branch ${branch} is not on origin of ${rname} - cut it first: ac-epic-branch.sh create <epic> ${rname}`);
      baseRef = `origin/${branch}`;
    } else {
      if (!ref(`refs/heads/${branch}`)) fail(`get: epic branch ${branch} does not exist in ${rname} - cut it first: ac-epic-branch.sh create <epic> ${rname}`);
      baseRef = branch;
    }
    if (git(repo, ["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`], { out: "ignore" }).status !== 0)
      fail(`get: base ref ${baseRef} (named by the integration-branch record for ${id} on ${rname}) does not resolve to a commit - nothing was leased; fix the ref before retrying`);
  }
  capture = [];
  locked(repo, () => acquireSlot(repo, id, holder, owner, prefer, baseRef));
  const wt = subst(Buffer.concat(capture));
  capture = null;
  // Outside the lock: a manifest can name a tree that takes longer to copy
  // than the 30s every other pool caller waits, and the slot is ours already.
  seedWorktreeInclude(repo, wt);
  writeWorkspace(repo);
  out(`${wt}\n`);
}

// Under the pool lock the ownership check and the stamp are ONE step, so a
// concurrent get cannot take the slot between them. Nothing here touches the
// tree - that is the verb's whole point.
function leaseSlot(repo: string, n: string, id: string, holder: string): number {
  const meta = slotMeta(repo, n);
  if (!isFile(meta)) fail(`lease: no such slot ${n} in the pool of ${repo}`);
  const leased = metaSoft(meta, "leased");
  if (leased === "1") {
    if (!leaseReclaimable(meta)) fail(`lease: slot ${n} is leased by task ${metaSoft(meta, "task")} (holder ${metaSoft(meta, "holder")}) - refusing`);
    say(`reclaiming slot ${n} from dead owner ${metaSoft(meta, "owner_pid")}`);
  } else if (leased !== "0") fail(`lease: slot ${n} lease state unknown (half-written meta?) - refusing`);
  stampLease(repo, n, id, holder, "");
  return 0;
}

function cmdLease(a: string[]): void {
  let slot = "";
  let repo = "";
  let id = "";
  let holder = "";
  for (let i = 0; i < a.length; ) {
    const w = a[i]!;
    if (w === "--repo" || w === "--id" || w === "--holder") {
      const v = value(a, i);
      if (w === "--repo") repo = v;
      else if (w === "--id") id = v;
      else holder = v;
      i += 2;
    } else if (w.startsWith("-")) fail(`lease: unknown argument ${b8(w)}`);
    else {
      slot = b8(w);
      i++;
    }
  }
  if (slot === "") fail("lease: slot name or worktree path required");
  if (repo === "") fail("lease: --repo is required");
  repo = resolveRepo(repo);
  if (slot.includes("/")) slot = basename(slot.endsWith("/") ? slot.slice(0, -1) : slot);
  locked(repo, () => leaseSlot(repo, slot, id, holder));
  writeWorkspace(repo);
  say(`worktree slot ${slot} leased to ${id || "cli"} (state only, tree untouched)`);
  out(`${slotPath(repo, slot)}\n`);
}

// The list wire (header: list); leased_at and owner_pid are filled only for a
// leased row, and an empty owner there is a durable lease.
function listSlots(repo: string): number {
  healSlots(repo);
  let found = false;
  for (const meta of slotMetas(repo)) {
    if (!isFile(meta)) continue;
    found = true;
    const n = metaName(meta);
    const wt = slotPath(repo, n);
    const task = metaSoft(meta, "task");
    let leasedAt = "";
    let owner = "";
    let state = "available";
    const leased = metaRead(meta, "leased");
    if (leased === null) state = "leased";
    else if (leased === "1") {
      state = "leased";
      leasedAt = metaSoft(meta, "leased_at");
      owner = metaSoft(meta, "owner_pid");
    } else if (!slotGitOk(wt)) state = "broken";
    // A broken slot's porcelain is no reading of the slot: empty when git
    // cannot read it, the PRIMARY's when its .git file is gone.
    const dirty = state !== "broken" && isDirty(wt) ? " dirty" : "";
    out(`${n}\t${state}${dirty}\t${task || "'-'"}\t${wt}\t${leasedAt}\t${owner}\n`);
  }
  if (!found) say("no worktrees in pool");
  return 0;
}

function cmdList(a: string[]): void {
  let repo = "";
  for (let i = 0; i < a.length; i += 2) {
    if (a[i] === "--repo") repo = value(a, i);
    else fail(`list: unknown argument ${b8(a[i]!)}`);
  }
  if (repo === "") fail("list: --repo is required");
  repo = resolveRepo(repo);
  locked(repo, () => listSlots(repo));
}

// Under the pool lock: decide whether this return may proceed AND take the
// slot over, as ONE step, before anything destructive runs. A late return
// (the slot re-leased since) would otherwise kill and reset whoever holds it
// NOW, and --force does not cover that. The lease is re-owned by THIS live
// process, which acquire, prune and remove all refuse to reclaim, so the
// destructive section after it runs unlocked with the slot off limits - the
// lock itself cannot span an lsof of the tree, a 4s kill grace and a full
// reset against the 30s every other caller waits. Dying mid-reset leaves the
// lease owned by a dead pid: the next acquire reclaims, re-checks and skips it
// if the reset left it dirty.
function claimReturn(meta: string, n: string, wt: string, want: string, force: boolean, pin: { state: string }): number {
  if (want !== "") {
    const have = metaSoft(meta, "lease_id");
    if (want !== have) fail(`return: slot ${n} holds lease ${have || "none"}, not ${want} - refusing (the slot was re-leased; nothing was reset)`);
  }
  // Pinned BEFORE the check it authorizes; --force is pinned to nothing.
  if (!force) {
    pin.state = verifiedState(wt);
    if (isDirty(wt)) fail(`return: worktree is dirty; land the work or pass --force to discard: ${wt}`);
  }
  return metaUpdateStatus(meta, () => [["owner_pid", String(process.pid)]]);
}

// The identity dies with the lease, so a SECOND return carrying the same id
// is refused instead of resetting a slot that has gone to someone else since.
// One rewrite: a reader never sees leased=0 beside the old lease_id, and a
// release that fails leaves the lease whole.
function releaseSlot(meta: string): number {
  return metaUpdateStatus(meta, () => [
    ["leased", "0"],
    ["owner_pid", ""],
    ["lease_id", ""],
  ]);
}

function cmdReturn(a: string[]): void {
  let wt = "";
  let force = false;
  let repo = "";
  let want = "";
  for (let i = 0; i < a.length; ) {
    const w = a[i]!;
    if (w === "--force") {
      force = true;
      i++;
    } else if (w === "--if-lease-id" || w === "--repo") {
      const v = value(a, i);
      if (w === "--repo") repo = v;
      else want = v;
      i += 2;
    } else {
      wt = b8(w);
      i++;
    }
  }
  if (wt === "") fail("return: worktree path or slot name required");
  if (!isDirArg(wt)) {
    if (wt.includes("/")) fail(`return: no such directory: ${wt}`);
    repo = resolveRepo(repo !== "" ? repo : atCaller ? b8(process.cwd()) : "");
    if (!isFile(slotMeta(repo, wt))) fail(`return: no such slot ${wt} in the pool of ${repo}`);
    wt = slotPath(repo, wt);
  }
  if (!isDirArg(wt)) fail(`return: no such directory: ${wt}`);
  const p = physicalDir(u8(wt));
  if (p === null) process.exit(1);
  wt = b8(p);
  const root = repoRoot(u8(wt));
  if (root === null) fail(`return: not a git worktree: ${wt}`);
  repo = b8(root);
  if (!wt.startsWith(`${repo}/.crew/worktrees/`)) fail(`return: not an agent-crew pool worktree: ${wt}`);
  const n = basename(wt);
  const meta = slotMeta(repo, n);
  if (!isFile(meta)) fail(`return: unmanaged slot: ${wt}`);
  const pin = { state: "" };
  locked(repo, () => claimReturn(meta, n, wt, want, force, pin));
  // Deliberately UNLOCKED (claimReturn says why), and pinned to the state it
  // verified, because this section is exactly the window that state can go
  // stale in.
  killWorktreeProcs(wt);
  const rc = force ? (resetWorktree(repo, wt) ? 0 : 1) : resetIfUnchanged(repo, wt, "", pin.state);
  if (rc === 2) fail(`return: worktree changed after it was verified clean, so nothing was reset - inspect it, then return --force to discard: ${wt}`);
  if (rc !== 0) fail(`return: reset failed for ${wt}`);
  locked(repo, () => (releaseSlot(meta) === 0 ? 0 : fail(`return: cannot record the release in ${meta} - slot ${n} stays leased to this return until a get reclaims it`)));
  writeWorkspace(repo);
  say(`worktree slot ${n} returned to pool`);
}

const isAncestor = (repo: string, a: string, b: string): boolean => git(repo, ["merge-base", "--is-ancestor", a, b], { err: "ignore" }).status === 0;
const headOf = (wt: string): string => subst(git(wt, ["rev-parse", "HEAD"], { out: "pipe" }).out);

// An epic-landed slot is merged too: its task may have landed into the
// epic's RECORDED branch, which the default-based check cannot see, and pool
// health would otherwise recommend the discard verb for landed work.
function fenceHolds(repo: string, task: string, head: () => string, verb: string): boolean {
  if (task === "") return false;
  const e = epicBaseFor(u8(task), u8(basename(repo)));
  if (e.rc === 2) fail(`${verb}: cannot read the ledger to resolve the epic-branch fence for ${task}`);
  if (e.rc !== 0) return false;
  const b = e.entry.split(" ")[0]!;
  return isAncestor(repo, head(), `refs/heads/${b}`) || isAncestor(repo, head(), `refs/remotes/origin/${b}`);
}

async function prunePass(repo: string, yes: boolean): Promise<number> {
  healSlots(repo);
  // Merged-proof must hold against the LIVE remote: a fetch or ls-remote that
  // fails or times out, or a stale tracking ref, means "cannot verify" -
  // skip, never guess.
  let reason = "";
  if (hasOrigin(repo)) {
    const branch = b8(defaultBranch(u8(repo)));
    const t = syncTimeout();
    const f = (await runBounded(["git", "-C", u8(repo), "fetch", "origin", "--quiet"], t, "inherit")).status;
    const r = f === 0 ? await runBounded(["git", "-C", u8(repo), "ls-remote", "origin", u8(`refs/heads/${branch}`)], t, "pipe") : null;
    if (f === 124) reason = `origin fetch timed out after ${t}s (cannot verify)`;
    else if (r === null) reason = "origin unreachable (cannot verify)";
    else if (r.status === 124) reason = `origin ls-remote timed out after ${t}s (cannot verify)`;
    else if (r.status !== 0) reason = "origin unreachable (cannot verify)";
    else {
      const ls = r.out.toString("latin1").split("\n");
      if (ls[ls.length - 1] === "") ls.pop();
      const remote = subst(fsPath(ls.map((l) => `${l.replace(/^[ \t]+/, "").split(/[ \t]+/)[0]}\n`).join("")));
      const local = subst(git(repo, ["rev-parse", "--verify", "--quiet", `refs/remotes/origin/${branch}`], { out: "pipe" }).out);
      if (remote !== "" && remote !== local) reason = `origin/${branch} stale vs remote (cannot verify)`;
    }
  }
  const ref = b8(defaultRef(u8(repo)));
  for (const meta of slotMetas(repo)) {
    if (!isFile(meta)) continue;
    const n = metaName(meta);
    const wt = slotPath(repo, n);
    const leased = metaRead(meta, "leased");
    if (leased === null) {
      out(`skip slot ${n}: meta unreadable (treated as leased)\n`);
      continue;
    }
    if (leased === "1" && !leaseReclaimable(meta)) {
      out(`skip slot ${n}: leased\n`);
      continue;
    }
    if (!slotGitOk(wt)) {
      out(`skip slot ${n}: worktree broken (git cannot read the slot itself)\n`);
      continue;
    }
    if (isDirty(wt)) {
      out(`skip slot ${n}: dirty\n`);
      continue;
    }
    // Skipping is the only safe answer when the walk could not be made: the
    // step past this guard is a drop of a tree someone may be working in.
    const procs = liveProcs(wt);
    if (procs === null) {
      out(`skip slot ${n}: cannot check for live processes (lsof unavailable)\n`);
      continue;
    }
    if (procs !== "") {
      out(`skip slot ${n}: in-use (live processes)\n`);
      continue;
    }
    if (reason !== "") {
      out(`skip slot ${n}: ${reason}\n`);
      continue;
    }
    if (!isAncestor(repo, headOf(wt), ref) && !fenceHolds(repo, metaSoft(meta, "task"), () => headOf(wt), "prune")) {
      out(`skip slot ${n}: HEAD not merged into ${ref}\n`);
      continue;
    }
    if (yes) {
      dropSlot(repo, n);
      out(`pruned slot ${n}\n`);
    } else out(`would prune slot ${n}: ${wt} (run with --yes)\n`);
  }
  return 0;
}

async function cmdPrune(a: string[]): Promise<void> {
  let repo = "";
  let yes = false;
  for (let i = 0; i < a.length; ) {
    if (a[i] === "--repo") {
      repo = value(a, i);
      i += 2;
    } else if (a[i] === "--yes") {
      yes = true;
      i++;
    } else fail(`prune: unknown argument ${b8(a[i]!)}`);
  }
  if (repo === "") fail("prune: --repo is required");
  repo = resolveRepo(repo);
  await lockedAsync(repo, () => prunePass(repo, yes));
  writeWorkspace(repo);
}

function removeSlot(repo: string, wt: string, force: boolean, includeLeased: boolean): number {
  const n = basename(wt);
  const meta = slotMeta(repo, n);
  if (!isFile(meta)) fail(`remove: unmanaged slot: ${wt}`);
  const leased = metaRead(meta, "leased");
  if (leased === null && !includeLeased) fail(`remove: slot ${n}'s meta cannot be read, so it is treated as leased; pass --include-leased to take it anyway`);
  if (leased === "1" && !leaseReclaimable(meta) && !includeLeased)
    fail(`remove: slot ${n} is leased (task ${metaSoft(meta, "task")}); pass --include-leased to take it anyway`);
  // A broken slot answers NO dirty or merged check, so the two gates below are
  // blind exactly where heal declines to act: it takes the same --force.
  if (!slotGitOk(wt) && !force) fail(`remove: slot ${n} is broken (gitdir unreadable) so its contents cannot be checked; use --force to discard`);
  if (isDirty(wt) && !force) fail("remove: worktree is dirty; use --force to discard");
  const head = subst(git(wt, ["rev-parse", "HEAD"], { out: "pipe", err: "ignore" }).out);
  if (head !== "" && !force && !isAncestor(repo, head, b8(defaultRef(u8(repo)))) && !fenceHolds(repo, metaSoft(meta, "task"), () => head, "remove"))
    fail(`remove: slot ${n} holds commits not merged into the default branch; use --force to discard`);
  killWorktreeProcs(wt);
  dropSlot(repo, n);
  say(`removed slot ${n}`);
  return 0;
}

function cmdRemove(a: string[]): void {
  let wt = "";
  let force = false;
  let includeLeased = false;
  for (const w of a) {
    if (w === "--force") force = true;
    else if (w === "--include-leased") includeLeased = true;
    else wt = b8(w);
  }
  if (wt === "") fail("remove: worktree path required");
  if (!isDirArg(wt)) fail(`remove: no such directory: ${wt}`);
  const p = physicalDir(u8(wt));
  if (p === null) process.exit(1);
  wt = b8(p);
  // A broken slot cannot answer repoRoot - and remove is its ONLY deliberate
  // exit, so the pool's own path shape names the candidate root, which git
  // still has to confirm.
  const cut = wt.lastIndexOf("/.crew/worktrees/");
  const root = repoRoot(u8(wt)) ?? repoRoot(u8(cut < 0 ? wt : wt.slice(0, cut)));
  if (root === null) fail(`remove: not a git worktree: ${wt}`);
  const repo = b8(root);
  if (!wt.startsWith(`${repo}/.crew/worktrees/`)) fail(`remove: not an agent-crew pool worktree: ${wt}`);
  locked(repo, () => removeSlot(repo, wt, force, includeLeased));
  writeWorkspace(repo);
}

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(2);
}

const entered = enterCaller(process.argv.slice(2));
atCaller = entered.atCaller;
const [verb = "", ...rest] = entered.args;
if (verb === "get") await cmdGet(rest);
else if (verb === "lease") cmdLease(rest);
else if (verb === "list") cmdList(rest);
else if (verb === "return") cmdReturn(rest);
else if (verb === "prune") await cmdPrune(rest);
else if (verb === "remove") cmdRemove(rest);
else usage();
process.exit(0);
