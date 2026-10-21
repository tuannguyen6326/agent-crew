// teardown.ts - fail-closed teardown of one finished task id. The entry is
// bin/ac-teardown.sh (a shim that starts this file through bin/ac-bun.sh);
// THIS header is the authoritative spec, and the bash original it replaced
// stays frozen at tests/fixtures/ac-teardown.sh as the oracle the
// differential leg of tests/sh/ac-teardown.test.sh holds this module to.
//
// Usage: ac-teardown.sh <id> [--force] [--pr-ready '<the captain acceptance>']
//                            [--no-lesson '<why>'] [--no-fact '<why>']
//
// It refuses to destroy evidence of unlanded work. Without --force it
// requires:
// - scout tasks: the report exists (report.md in the task's data dir - flat
//   data/<id>/ or the nested staged dir taskDir resolves; a merged `--stage
//   design` scout instead proves ANY of its sub-stage reports at
//   data/<family>/{spec,arch,plan}/report.md, since it keeps only ONE brief
//   at design/ and writes no design/report.md), AND any crew/<family> branch
//   the scout created is landed (the ship tasks' containment proof) - a scout
//   steered mid-flight into writing code cannot have its committed work
//   silently discarded; ac-promote.sh <id> converts it to a ship task instead
//   - and its worktree is clean, branch or not;
// - ship tasks (every other kind): the work is landed - the crew/<family>
//   branch head (crewBranch: a revision t12-r2 lands on crew/t12) is
//   contained in the default branch (local or origin), in the task's recorded
//   epic/feature integration branch, reachable from any remote branch but
//   crew/<family> itself (pushing a PR creates that one), or the recorded PR
//   was merged (pr_merged=1; when pr_merged_head is recorded, only a head it
//   contains) - and the worktree is clean.
// Both kinds also prove the worktree's OWN HEAD: pool slots start on a
// detached HEAD and the return is --force, so a commit no branch carries - or
// one made past crew/<family> - is refused unless something landed contains
// it. Every OTHER lease the task holds (leases=, e.g. an e2e companion
// checkout) is returned with --force too, so each must be clean and hold
// nothing unlanded either, judged in its own repository.
// --pr-ready '<words>' is the OTHER PR proof: done does not wait for the
// merge. When the recorded PR is ready to merge, the chief asks the captain,
// and the captain's acceptance - the flag's value, made durable on the task
// status - lands the task; the merge stays the captain's own act. It requires
// a recorded PR (ac-pr-check.sh), a clean worktree, a readable ledger, and no
// OPEN backlog row blocked-by this task: a dependent starts from the merged
// tree, so a depended-on task lands only by the real merge.
// --force means "the captain explicitly discards this work".
// A kind=self slice (a chief self task or a SOLO session's slice) also owes
// its KNOWLEDGE LOOP at landing, and the teardown is the machine behind that
// law because no chief lands a solo slice: after the landed proof it runs
// soloLandingCheck (src/lib.ts) and REFUSES - slice, lease and branch left in
// flight - while the lesson (a Pending heading `(solo <id>)` or a
// `(by: <id>,` line in records/learnings.md), the verified repo fact (a
// repo-knowledge line ending `| by: <id>`) or the `- [x] <id>` Done row (a
// scoped slice: its room's LANDED:/UNLANDABLE: receipt) is missing, printing
// the exact command for each. "Nothing new" is said, never inferred:
// --no-lesson '<why>' and --no-fact '<why>' waive those two and land the why
// on the task status - only once the check passes, so a refused landing
// records none; the Done row is never waived. Once the loop is complete the
// teardown runs the keyed `ac-learn.sh tick <id>` itself and records every
// line it prints, WARNing when it fails. --force skips all of it: a discarded
// slice owes nothing.
//
// ESCAPE HATCH. Every landing ends here - the solo
// session's slices, every crewmate, verifier and chief, on both fleets. If a
// landed change breaks this module, run the frozen original from a scratch
// bin/:
//   o=$(mktemp -d); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-teardown.sh "$o/bin/ac-teardown.sh"
// then "$o/bin/ac-teardown.sh" <id> [flags]: its bin dir is $o/bin, so it
// drives the copy's ac-tree shim (through the src link), ac-learn, ac-room,
// ac-qa and ac-pane-agent, and its hints name $o/bin. The captain's revert of
// the land is the last resort.
//
// --- the run, in order (AUTHORITATIVE) ---
// PREAMBLE. The ambient backend ladder is checked first, as sourcing
// ac-backend.sh did (backendName: an invalid AC_BACKEND or config/backend is
// `ERROR: unsupported backend '<b>' (valid backends: herdr, orca; tmux/wezterm
// were removed 2026-07-17)`, exit 1), then `ERROR: required tool not found:
// git`. The FIRST word is always the id: none or '' is `ERROR: usage:
// ac-teardown.sh <id> [--force] [--pr-ready '<the captain acceptance>']
// [--no-lesson '<why>'] [--no-fact '<why>']` (one line, exit 1; `-h` is an
// id). Then --force; --pr-ready/--no-lesson/--no-fact take the next word,
// whatever it is (W2), and refuse an absent or empty one: `ERROR: --pr-ready
// carries the captain's acceptance words - they are the proof, so an empty
// value is refused`, `ERROR: --no-lesson carries why the slice learned
// nothing new - it is the record, so an empty value is refused`, `ERROR:
// --no-fact carries why the slice verified no repo fact - it is the record,
// so an empty value is refused`; repeats last-wins; any other word is
// `ERROR: unknown argument: <a>`. Every argument refusal precedes any home
// read. No AC_HOME is the NO_HOME refusal (src/lib.ts), exit 1; the home is
// entered physically and state/ minted. No regular file state/<id>.meta is
// `ERROR: no crewmate meta for <id>`; an unreadable one is `WARN: cannot read
// meta file <meta>`, exit 1. Read: kind, worktree, worktree_backend, leases
// (empty: worktree= is the list), lease_ids, project_dir, lease_base. With
// worktree_backend=orca the orca worktree leaves leases (the whole list when
// it is the only one, else its `<wt>:` prefix) and its id slot is popped from
// lease_ids ONLY when both lists hold as many `:` (a legacy list is one id
// short and keeps every id). lease_base (spawn.ts: an explicit --base-branch)
// is absent on every meta that never named one - older tasks and herdr leases
// read exactly as before. The branch is crew/<family>. AC_BACKEND becomes
// the meta's backend= (herdr without one) for every child and backend call -
// validated only at the pane kill (W6). stdin is never read. Every ERROR is
// on stderr, exit 1; every WARN is on stderr.
//
// DIRECT VERIFIER (a kind=verify-* meta): no landed proof - --force,
// --pr-ready and the waivers are accepted and ignored. (1) An INCOMPLETE
// verify-qa (complete = evidence= non-empty, verdict.json and
// relay-report.md non-empty, run-state/ a dir) is preserved: the evidence
// dir is evidence=, else <data>/<family|unknown>/verification/<vid>-
// incomplete-<epoch>, `mkdir -p`ed (else `ERROR: cannot preserve incomplete
// QA verifier <vid> at <evidence>`); the meta `cp`ed to verifier.meta (else
// `ERROR: cannot preserve verifier meta for incomplete QA <vid>`); output= to
// verdict.partial.json and pane_result= to pane-result.ndjson when files (a
// failing cp ends the run with its status); the QA run (<worktree>/.crew/qa/
// current, a symlink resolved against .crew/qa, or a dir) `cp -R`ed to
// run-state/ unless that exists (else `ERROR: cannot preserve QA run state
// for incomplete verifier <vid>`); incomplete-run.md written (`# Incomplete
// QA verifier teardown`, ``Verifier: `<vid>` ``, ``Family: `<family>` ``,
// ``Preserved at: `<iso>` ``, the fixed sentence; else `ERROR: cannot write
// incomplete QA artifact for <vid>`). (2) The verifier ARCHIVE, the task's
// layout: a meta already at state/archive/<vid>/meta moves (with its
// status) into a fresh `mktemp -d <archive>/<epoch>.XXXXXX`, then the meta
// is `mv`ed to the fixed slot and state/<vid>.status beside it; its
// state/.pane-<vid> reaped (REAP below); each lease of the
// archived meta (leases=, else worktree=, popped on `:` in lockstep with
// lease_ids=; an empty entry silent) - gone is `WARN: skipping vanished
// verifier lease <l>: directory no longer exists`; on the verifier's own
// backend (backend=, else the route's), orca releases it (orcaWorktreeRelease,
// else `WARN: could not release orca verifier worktree <l>; inspect
// <archive>/meta`), herdr runs `ac-tree.sh return <l> --force [--if-lease-id
// <id>]` (else `WARN: could not return verifier worktree <l> (it may have
// been re-leased); inspect <archive>/meta`, or without an id `WARN: could not
// return verifier worktree <l>; inspect <archive>/meta`); then
// state/.verify-<caller>-<kind less verify->.lock.d is rmdir'ed, silently,
// and the verifier's watcher stamps (taskStamps, src/lib.ts) removed. (3)
// stdout `teardown <id> complete (verifier)`, exit 0.
//
// THE GATE, skipped by --force: a refused proof prints its reason on stderr,
// then `ERROR: refusing teardown of <id> (unlanded work); land it or pass
// --force to discard`.
// - roomchief: `family <fam> still has crew in flight: <member>` - <fam> is
//   <id> less `-chief`, a member is the first other non-verifier
//   state/*.meta (byte order) whose id's family (familyOfId) or fleet_scope=
//   is <fam> - membership is authoritative, never an id prefix: an open
//   `<fam>-*` glob made the distro's own `learning` room wait on an
//   unrelated `learning-curate-automation` epic, and the stuck demote cost a
//   --force on a family with nothing unlanded; fleet_scope still catches an
//   epic story whose id matches no suffix rule.
// - crewdeputy: `crewdeputy home still has crew in flight:
//   <worktree>/state/*.meta` while ls finds any there.
// - every other kind: a meta with no project_dir refuses first, `the meta of
//   <id> records no project_dir, so its landed work has no repository to be
//   proven in` (every proof would read the caller's cwd repo). A worktree git
//   cannot read (its status fails: a .git pointing nowhere, a dir no repo
//   holds) is `worktree <wt> cannot be read by git, so its contents cannot be
//   checked; repair it or --force to discard` wherever a dirty one refuses
//   below; one that is gone holds nothing. Then --pr-ready's preconditions,
//   each its own ERROR:
//   `--pr-ready with no recorded PR for <id> - record it first
//   (bin/ac-pr-check.sh <id> <url>)`; `--pr-ready refused: the worktree holds
//   uncommitted work the accepted PR cannot contain - commit and push it
//   (then re-record the PR head), or discard it deliberately, before the
//   acceptance lands:` and the status lines (`--pr-ready refused: <the
//   unreadable line above>` for a tree git cannot read); `--pr-ready
//   refused: cannot read <records>/backlog.md to prove no open row waits on
//   <id> - an unreadable ledger must not read as 'no dependent'`;
//   `--pr-ready refused: open row
//   <dep> still waits on <id> (blocked-by) - a dependent starts from the
//   merged tree, so this task lands only by the real merge` (an open `- [ ]`
//   row whose `blocked-by:` list, up to ` - `, split on commas AND white
//   space, holds the id exactly - awk's `in`, spawned under LC_ALL=C). Then
//   the extra leases: `lease <l> holds uncommitted or unlanded work and would
//   be returned with --force; land or move it, or --force to discard`, or
//   `lease <l> cannot be read by git, so its contents cannot be checked and
//   it would be returned with --force; repair it, or --force to discard`.
//   scout: an ambiguous task dir prints taskDir's ERROR and refuses (W21);
//   `scout report missing: no report.md at <dir> (nor merged-design sub-stage
//   reports)`; `scout created <branch> with unlanded work; promote it
//   (ac-promote.sh <id>) or --force to discard`; `worktree is dirty:
//   uncommitted changes that <branch> does not hold; commit them or --force
//   to discard`; `worktree HEAD <12> holds commits nothing landed contains;
//   put them on <branch> and promote it (ac-promote.sh <id>), or --force to
//   discard`. ship, with no branch head: `worktree is dirty and no <branch>
//   branch exists`; `worktree HEAD <12> holds commits no branch carries and
//   nothing landed contains; put them on <branch> (git -C <worktree> branch
//   <branch> <12>) and land it, or --force to discard`. With one, dirty
//   FIRST: `worktree is dirty: uncommitted changes that <branch> does not
//   hold; commit them or --force to discard`; `branch <branch> (<12>) is not
//   landed: not in <default branch> (local or origin), no containing remote
//   branch, no merged PR`; `worktree HEAD <12> is past the landed <branch>
//   (<12>) and nothing landed contains it; move <branch> to it and land that,
//   or --force to discard`. Each of the three dirty refusals whose porcelain
//   is all `??` lines adds `untracked only, no tracked edits: <path>, ...`,
//   at most ten paths then ` (+<n> more)` (UNTRACKED-ONLY, named: the
//   original said only that the tree is dirty). The branch head is
//   refs/heads/<branch> in project_dir, else in the worktree (git's own
//   stderr passes). "Landed", in
//   order: pr_merged=1 with no pr_merged_head, or a head it contains;
//   --pr-ready: a head past a recorded pr_head prints `--pr-ready refused:
//   HEAD <12> is newer than the recorded PR head (<pr_head>) - the captain
//   accepted the PR, not commits past it. Push and re-record
//   (bin/ac-pr-check.sh <id> <url>), then ask again` and is not landed, any
//   other is; the default branch, then defaultRef; the epic fence's branch
//   (epicBaseFor: refs/heads/<b>, then refs/remotes/origin/<b>; a ledger it
//   cannot read is `WARN: cannot read the ledger to resolve the epic-branch
//   fence for <id> - containment in an epic branch stays unproven`); a
//   remote branch but <branch> and HEAD.
//
// KNOWLEDGE LOOP, kind=self and not forced: soloLandingCheck (the line on
// the record and stdout, the hints), with `lesson waived: <why>` and `repo
// fact waived: <why>` appended to the status just ahead of its line when it
// passes, else
// `ERROR: solo landing refused: the knowledge loop above is incomplete -
// write what is missing (or waive the lesson/fact with --no-lesson/--no-fact
// '<why>'), then run the teardown again`.
// VERIFIER SWEEP, the preflight: every OTHER state/*.meta that is a verifier
// the task owns - caller=<id> exactly, or no caller and family= the id's
// family (a co-tenant naming another caller is never touched) - gets the
// incomplete-QA preservation above; its ERROR ends the run before anything
// is archived. Then, kind=self and not forced, `learning tick: <line>` on
// the status for each line of `ac-learn.sh tick <id>`, stdout and stderr
// merged; a tick that exits non-zero is `WARN: learning tick for <id> failed
// (exit <rc>) - this landing is not counted; re-run: <bin>/ac-learn.sh tick
// <id>`, and the teardown goes on.
//
// ORDER GUARANTEE - the state archive is the FIRST durable act after the
// gates, BEFORE the pane kill, which has ended runs on record (exit 144, no
// output): a death after it leaves only reclaimable residue - the lease
// (`leased <id>` in ac-tree.sh list, `ac-tree.sh return <wt> --force`), a
// merged crew/<family> branch (git branch -d) and a qa stack (`ac-qa.sh infra
// down --task <id>`) - and a re-run refuses with "no crewmate meta".
// 1. ARCHIVE: `mkdir -p state/archive/<id>`; a meta already there moves with
//    its status into a fresh `mktemp -d <archive>/<epoch>.XXXXXX` (the fixed
//    slot every reader resolves takes the LATEST); `done: captain accepted
//    the ready-to-merge PR - <words>` (--pr-ready, forced or not, W3) and
//    `resolved: teardown[ (forced)]` appended; meta and status `mv`ed in; the
//    watcher stamps removed. A status append that cannot be written ends the
//    run, exit 1, nothing moved.
// 2. PANE KILL (backendKillWindow, src/lib.ts), the handle read first: a
//    task backend the route refuses ends the run here, exit 1 (W6). A
//    failure is `WARN: pane close FAILED for <id> - a live pane may survive
//    this teardown (handle: <handle|none>); close it by hand: <cmd>` - herdr
//    tab close <field 2>[ --session <AC_HERDR_SESSION or
//    config/herdr-session>], orca `orca terminal close --terminal <field 1>`
//    (unreachable, W19) - and `<iso> warn: pane close failed - handle <h>;
//    close by hand: <cmd>` appended to the ARCHIVED status and the timeline.
//    TOKEN LEDGER (named: the original recorded no spend), then, for every
//    kind but self (no agent ran): rows appended to records/task-tokens.tsv
//    (a header line `at id kind harness model input cache_creation
//    cache_read output`, tab-separated, written first when the file is
//    new): one per model the claude session_id's transcript and its
//    subagents' used, sorted by model - found as <root>/*/<sid>.jsonl and
//    <root>/<that dir>/<sid>/subagents/*.jsonl, <root> being
//    AC_CLAUDE_TRANSCRIPT_ROOT, else $CLAUDE_CONFIG_DIR/projects, else
//    ~/.claude/projects (ac_claude_transcript_root's rule) - each message.id
//    counted once with each field's max, since a streamed message repeats
//    its usage line. Raw tokens, never dollars (a subscription has no
//    per-token price). No session_id, or not exactly one transcript, is one
//    row whose model reads `unknown: <why>` with the four counts empty -
//    never zeros. Best effort: a write that fails is `WARN: could not record
//    <id>'s token use in <file>: <error>` and the teardown goes on. Verifier
//    panes record no session id, so their use stays out.
// 3. The VERIFIER SWEEP's reap: every verifier the task owns archived and
//    reaped as above, its status and stamps included.
// 4. ROOMCHIEF DEMOTE: `ac-room.sh post <fam> crewchief "DEMOTED: roomchief
//    closed[ (forced)]"`, else `WARN: could not post DEMOTED to room <fam>:
//    <ac-room's stderr> - post it by hand: <bin>/ac-room.sh post <fam>
//    crewchief "<msg>"`.
// 5. LEASES (not a roomchief or crewdeputy): each of leases= (split on `:`,
//    trailing empties dropped, at least one) with its lease_ids= slot popped
//    first; empty silent; gone `WARN: skipping vanished lease <l>: directory
//    no longer exists`; then PANE-AGENT SWEEP, the port-slot release
//    (portSlotRelease, src/lib.ts) and `ac-tree.sh return <l> --force
//    [--if-lease-id <id>]`, else `WARN: could not return worktree <l> (it may
//    have been re-leased); check the pool with ac-tree.sh list`, or without
//    an id `WARN: could not return worktree <l>; check the pool with
//    ac-tree.sh list`.
// 6. ORCA WORKTREE (worktree_backend=orca, its dir there): the sweep, the
//    port-slot release, then orcaWorktreeRelease, else `WARN: could not
//    remove orca worktree <wt> (remove by hand: orca worktree rm --worktree
//    path:<wt> --force)`.
// 7. BRANCH DROP (the same kinds): with no project_dir recorded (only a forced
//    run gets here) `WARN: no project_dir recorded for <id> - <branch> was not
//    looked for; drop it by hand in the repository that holds it`; else only
//    while refs/heads/<branch> exists in project_dir: with
//    worktree_backend=orca and the orca worktree dir now gone, `git worktree
//    remove <wt>` first (best effort, ignored either way) - a stale
//    registration from a directory already gone must not survive to refuse the
//    drop below, whether orca's release raced git's deregistration or never
//    called it at all. Then: `git branch -d`, or -D when the epic fence names a
//    branch (heads, then origin) containing it, OR - only with NO fence
//    recorded at all (not even an unreadable ledger) and the meta's lease_base
//    (an explicit --base-branch) naming a DIFFERENT branch than <branch> itself
//    - lease_base containing it (heads, then origin): a 0-commit branch cut
//    from a base the primary's own HEAD never covers is proven merged there
//    instead, never when it carries a commit the base does not, and never when
//    the base IS the family's own branch (isAncestor(x,x) is always true, which
//    would -D a live sibling's unlanded work). A fence ledger it cannot read is
//    `WARN: cannot read the ledger to resolve the epic-branch fence for <id> -
//    <branch> is deleted only if -d proves it merged` (true even with a
//    recorded lease_base). A refusal is `WARN: kept <branch> in <project_dir>:
//    <git's whole text> - reclaim: <git branch -D <branch> | free it from that
//    worktree, then git branch -D <branch>>`, the second while `worktree list
//    --porcelain` holds `branch refs/heads/<branch>`.
// 8. QA-INFRA SWEEP, when docker is on PATH, in each sweep dir that is a
//    directory: the task's project_dir; for a roomchief, whose own is the
//    distro root, each distinct project_dir (byte order) recorded at
//    state/archive/<m>/meta by a member of its family as THE GATE reads one
//    (a verifier or a roomchief recorded none); for a crewdeputy, whose home
//    is no repo, none. In each, the task's stack and its family's
//    <family>-qa stack (none when that is the id) go down - unless another
//    family member is in flight, which is stdout `qa-infra: family stack
//    <stack> kept - <member> is still in flight and its qa run may hold it`
//    - through `<bin>/ac-qa.sh infra down --task <t>` in that dir, both
//    under one bound (AC_TEARDOWN_QA_TIMEOUT digits, else 30 - a test-only
//    shortener, not a knob; runBounded, src/lib.ts). A failure or the
//    bound's 124 is `WARN: qa-infra sweep for <id> did not complete (status
//    <rc>, bound <s>s) - docker is unusable or hung; any task stack
//    survives: (cd <dir> && <bin>/ac-qa.sh infra down --task <id>[ &&
//    <bin>/ac-qa.sh infra down --task <stack>])`. A roomchief's family is
//    its id less `-chief`. HUP, INT, TERM and URG are trapped for EVIDENCE
//    only: `WARN: teardown <id>: caught SIG<s> during the qa-infra sweep`,
//    then the default disposition re-raised - TERM ends the run 143, URG's
//    default is to go on.
// 9. stdout `teardown <id> complete[ (forced)]`, exit 0 whatever was warned.
//    A roomchief then prints `a chief slot is free - next queued family:
//    <next> (promote with bin/ac-spawn.sh --roomchief <next>)` when the first
//    line of `ac-ready.sh queued` names one - demoting a chief is the one
//    moment a room-parallel slot frees; advisory only, never a spawn.
//
// PANE-AGENT SWEEP (one leased tree): the qa agent's
// .crew/qa/agent-<task, lowered, every byte outside [a-z0-9_-] a `-`>.pane
// reaped; each .crew/qa/*/run.meta (the whole paths in byte order, a
// symlinked run dir skipped)
// attributed by its FIRST `task=` line through a spawned sed - <id> reaps
// watch.pane and ends serve.pid's process group, none WARNs `not reaping
// <content> - run <rd> is attributed to no task (<rd>/<f>)` for each of
// review.pane, watch.pane, serve.pid, another task's is left alone; then
// .crew/ship/*/run.meta by `branch=` = <branch> (review.pane, watch.pane). A
// run.meta sed cannot read is sed's own line and `WARN: could not read <m>:
// run <rd> was not swept - its panes and qa serve process, if any, may
// survive`, and the sweep goes on. REAP of a pane file: absent nothing; awk
// cannot read it `WARN: could not read <f>: the pane could not be
// identified, it may be orphaned`, kept; no first field, removed; no
// executable <bin>/ac-pane-agent.sh, or on PATH no binary of the backend
// reap-pane resolves for itself (backendRoute, which reads the AC_BACKEND
// pinned above; a bad name reads as herdr, as reap-pane's own fallback)
// `WARN: could not reap pane <p>
// (<f>): <backend> or ac-pane-agent.sh unavailable`, kept; else
// `ac-pane-agent.sh reap-pane --pane <p>`, whose
// `"closed":false` is `WARN: pane <p> (<f>) did not close - it is orphaned
// in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane
// --pane <p>`, and the file removed. SERVE.PID (killServePid): absent
// nothing; unreadable `WARN: could not read <f>: a qa serve process may still
// be running and could not be identified`, kept; anything but a decimal above
// 1 - the file sits in a tree its task can write, 0 names this process's own
// group and 1 negates to -1, every process of the user - is `WARN: not
// signalling qa serve pid '<pid>' (<f>): not a process id - a qa serve
// process may still be running and could not be identified`, kept; empty,
// removed silently; alive (`kill -0` - proof that the pid exists, not that
// it is still the server) is TERMed as a group, else as a pid, else `WARN:
// could not kill qa serve pid <pid> (<f>)`; gone `WARN: qa serve pid <pid>
// already gone (<f>)`; then removed. Every step of the sweep is best-effort -
// none of them changes the exit status or the gate.
//
// AT PARITY (each pinned in the leg): W6 the
// task backend validated only at the pane kill, after the archive.
// Reproduced too: W1 (the id is always the first word), W2 (a value flag
// swallows the next word), W3 (--force --pr-ready records both), W16 (the
// named member is the first in byte order), W18 (an unreachable herdr reads
// as a stale handle), W19 (the orca close never fails), W20 (a held registry
// lock leaves the row, silently), W21.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - READS FAIL CLOSED (the dossier's routed slice): a
//   worktree or lease git cannot read refuses at the gate, where the
//   original read it clean and an orca worktree rm then took its files
//   (W8); a meta with no project_dir refuses, and forced looks for the
//   branch nowhere, where the original read and dropped the caller's cwd
//   repo (W7); an unreadable run.meta leaves that run and the sweep goes on,
//   where the original ended mid-sweep, its lease held and its branch kept
//   (W13).
// - A VERIFIER'S WHOLE RECORD (the dossier's routed W11 and W12): a
//   verifier's status is archived beside its meta and its watcher stamps are
//   reaped, swept or direct, where the original left the status always and
//   a swept verifier's stamps too; and a re-archived verifier's LATEST takes
//   the fixed slot, the prior moved to its stamped dir, where the original
//   kept the oldest there.
// - THE REAP'S BACKEND (the dossier's routed W10): a pane file is reaped
//   when the binary of the backend reap-pane resolves is on PATH, where the
//   original asked for herdr whatever the backend - an orca task's teardown
//   without herdr kept every pane open and its record, and one with herdr
//   but no orca had reap-pane read the unreachable terminal as closed, so
//   the record was dropped.
// - THE QA SCOPE (the dossier's routed W14 and W15): a roomchief sweeps in
//   its family's own projects, where the original swept under the distro
//   root, a scope its family's stacks never carry, so none went down; and a
//   crewdeputy sweeps nothing, where the original swept its home and warned
//   a false docker failure.
// - THE LOOP'S RECORD (the dossier's routed W4 and W5): the waivers are
//   written only once the knowledge-loop check passes, where the original
//   wrote them at every refused attempt too; and the tick's every line is
//   recorded and its failure WARNed, where the original kept its last line
//   and dropped its status.
// - BUN: the shim refuses `ERROR: required tool not found: bun`, exit 1,
//   before anything durable, where the original archived, killed the pane
//   and completed with three WARNs (W22).
// - SHELL-OWN STDERR is not reproduced (`ac-lib.sh: line N: <status>:
//   Permission denied` and its kin); exit statuses are kept.
// - EXCLUSIVE TEMPS: incomplete-run.md.tmp.<pid> and port-slots.tsv.tmp.<pid>
//   are created exclusively (the next .<n> past a name taken) and keep the
//   record's mode; the original wrote through whatever sat at the name.
// - ORDER: state/*.meta and the run dirs are walked in byte order; under a
//   UTF-8 locale the original's glob followed collation (W16).
// - The epic fence reads the ledger in-process, so the original's bun-missing
//   arm of it is unreachable.
// - No eval: the qa sweep's signal evidence names the id as text, where the
//   original's trap string evaluated it (W17).
// - THE QA BOUND KILLS THE GROUP: past the bound the sweep's child and
//   everything it started (the docker client) are TERMed then KILLed, where
//   the original killed only its subshell and orphaned the grandchild.
// - stdin: every child reads the caller's stdin, where the original's
//   children inside its read loops read the loop's input (the remaining lease
//   list) and its qa subshell, a background job, read /dev/null.
// - HOME RESOLUTION: an AC_HOME that cannot be entered is `ERROR: AC_HOME is
//   not a readable directory: <h>`.
// - A caller whose cwd has no name resolves no relative path (an empty
//   project_dir included) and says nothing of it, where the original's gits
//   printed `fatal: Unable to read current working directory`.
// - Bytes: argv arrives decoded (U+FFFD for a byte that is not UTF-8), and a
//   meta value reaches a child's argv the same way.
// - date(1)'s own stderr on the knowledge-loop record append passes, where
//   the original dropped that append's stderr; only a date that fails says
//   anything.
//
// CALLERS: none executes it from code - the crewchief at landing (the
// task-lifecycle skill), roomchiefs and solo chiefs for their members and
// slices, solo sessions for their kind=self slices (the solo-session
// skill), and 12 tests/sh suites; ac-turnend-guard.sh, ac-spawn.sh and
// ac_self_tasks_in_flight (bin/ac-lib.sh) print commands naming it. Its
// stdout is read by people and agents, never parsed; the files it writes
// are: state/archive/<id>/{meta,status} and the stamped <epoch>.XXXXXX/
// priors (ac-spawn --resume-from, ac-follow, the dashboard, src/session.ts,
// src/remote.ts), the timeline lines, and the room line `crewchief>
// DEMOTED: roomchief closed[ (forced)]` (ac-watch.sh, ac-wake-lib.sh,
// src/room.ts, ac-turnend-guard.sh).

import { accessSync, appendFileSync, chmodSync, closeSync, constants, existsSync, lstatSync, readdirSync, readFileSync, rmdirSync, statSync, writeFileSync, writeSync } from "node:fs";
import { resolve } from "node:path";
import {
  NO_HOME,
  STARTED_BIN,
  backendKillWindow,
  backendName,
  backendRoute,
  commandV,
  configReadSoft,
  crewBranch,
  defaultBranch,
  defaultRef,
  die,
  enterCaller,
  epicBaseFor,
  exclusiveTemp,
  familyOfId,
  metaGet,
  metaIsVerify,
  nowRaw,
  orcaWorktreeRelease,
  physicalDir,
  portSlotRelease,
  require,
  runBounded,
  shellStatus,
  softSubdir,
  soloLandingCheck,
  spawnShellSync,
  statusAppend,
  statusTimelineMirror,
  taskBackend,
  taskDir,
  taskStamps,
  warn,
  worktreeStatus,
  writeAll,
} from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv and the lib's
// paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const byteOrder = (a: string, b: string): number => Buffer.compare(fsPath(a), fsPath(b));
// awk's C-string reading of a meta value.
const cutNul = (s: string): string => s.replace(/\0[\s\S]*$/, "");

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

function raw(msg: string): void {
  writeSync(2, fsPath(`${msg}\n`));
}

type Io = { stdin?: "inherit" | "ignore"; out?: "inherit" | "pipe" | "ignore"; err?: "inherit" | "pipe" | "ignore"; cwd?: string };

function run(cmd: string[], io: Io = {}): { status: number; out: Buffer; err: Buffer } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin: io.stdin ?? "inherit", stdout: io.out ?? "inherit", stderr: io.err ?? "inherit", cwd: io.cwd });
  } catch {}
  return { status: shellStatus(r), out: r && io.out === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0), err: r && io.err === "pipe" ? Buffer.from(r.stderr) : Buffer.alloc(0) };
}

// A caller whose cwd has no name resolves no relative path - bun sits in the
// distro root then, where `git -C ""` would name the distro's own repo.
let atCaller = true;
const reach = (p: string): boolean => atCaller || p.startsWith("/");

function git(dir: string, args: string[], io: Io = {}): { status: number; out: Buffer } {
  if (!reach(dir)) return { status: 128, out: Buffer.alloc(0) };
  return run(["git", "-C", u8(dir), ...args.map(u8)], io);
}

const quiet: Io = { out: "ignore", err: "ignore" };

// A spawned binary where errexit was awake: its failure ends the run with its
// status, its own line already on stderr.
function must(cmd: string[], io: Io = {}): Buffer {
  const r = run(cmd.map(u8), io);
  if (r.status !== 0) process.exit(r.status);
  return r.out;
}

// `rm -f <f>` where errexit was awake: only a path that is there can fail.
function rmF(f: string): void {
  try {
    lstatSync(fsPath(f));
  } catch {
    return;
  }
  must(["rm", "-f", f]);
}

const isFile = (p: string): boolean => {
  if (!reach(p)) return false;
  try {
    return statSync(fsPath(p)).isFile();
  } catch {
    return false;
  }
};

const isDir = (p: string): boolean => {
  if (!reach(p)) return false;
  try {
    return statSync(fsPath(p)).isDirectory();
  } catch {
    return false;
  }
};

const isLink = (p: string): boolean => {
  if (!reach(p)) return false;
  try {
    return lstatSync(fsPath(p)).isSymbolicLink();
  } catch {
    return false;
  }
};

const exists = (p: string): boolean => reach(p) && existsSync(fsPath(p));

const nonEmpty = (p: string): boolean => {
  if (!reach(p)) return false;
  try {
    const st = statSync(fsPath(p));
    return st.isFile() && st.size > 0;
  } catch {
    return false;
  }
};

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

// `<dir>/<glob>` as the shell listed it: the names matching (a dotfile only
// when the glob starts with the dot), byte order.
function listed(dir: string, match: (name: string) => boolean): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(fsPath(dir), { encoding: "buffer" }).map((b) => Buffer.from(b).toString("latin1"));
  } catch {}
  return names.filter(match).sort(byteOrder).map((n) => `${dir}/${n}`);
}

const metaFiles = (dir: string): string[] => listed(dir, (n) => !n.startsWith(".") && n.endsWith(".meta"));
// `<base>/*/run.meta`: the glob sorts the WHOLE paths (`a-b/` before `a/`).
const runMetas = (base: string): string[] =>
  listed(base, (n) => !n.startsWith("."))
    .map((d) => `${d}/run.meta`)
    .sort(byteOrder);
const metaId = (m: string): string => basename(m).slice(0, -".meta".length);

// ac_meta_get where errexit slept: an unreadable meta WARNs and reads "".
function mget(file: string, key: string): string {
  try {
    return cutNul(metaGet(u8(file), key));
  } catch {
    return "";
  }
}

// The shell's `kill -<sig> [--] <word>` over a decimal the serve.pid filter
// let through: a value past pid_t is refused before any signal (bash 3.2's
// `arguments must be process or job IDs`), and so is any kill that fails.
type Kill = (pid: number, sig: "SIGTERM" | 0) => unknown;
function killed(kill: Kill, word: string, sig: "SIGTERM" | 0, group = false): boolean {
  const v = BigInt(word);
  if (v > 2147483647n) return false;
  try {
    kill(group ? -Number(v) : Number(v), sig);
    return true;
  } catch {
    return false;
  }
}

// kill_serve_pid: <f>'s qa server ended as a PROCESS GROUP (serve runs under
// `set -m`, so its pgid is the recorded pid) - header: SERVE.PID. `kill` is
// the signal call, injectable so a test drives every arm with a spy.
export function killServePid(f: string, kill: Kill = (p, s) => process.kill(p, s)): void {
  if (!isFile(f)) return;
  let pid: string;
  try {
    pid = subst(readFileSync(fsPath(f)));
  } catch {
    say(`could not read ${f}: a qa serve process may still be running and could not be identified`);
    return;
  }
  if (/[^0-9]/.test(pid) || pid.startsWith("0") || pid === "1") {
    say(`not signalling qa serve pid '${pid}' (${f}): not a process id - a qa serve process may still be running and could not be identified`);
    return;
  }
  if (pid !== "") {
    if (killed(kill, pid, 0)) {
      if (!killed(kill, pid, "SIGTERM", true) && !killed(kill, pid, "SIGTERM")) say(`could not kill qa serve pid ${pid} (${f})`);
    } else say(`qa serve pid ${pid} already gone (${f})`);
  }
  rmF(f);
}

// TOKEN LEDGER (header): a streamed message repeats its usage line under one
// message.id, so each field keeps its max per id - summing every line counts
// a message about twice. Model order is sorted so the rows are stable.
export function transcriptTokens(texts: string[]): Map<string, number[]> {
  const byId = new Map<string, { model: string; t: number[] }>();
  let anon = 0;
  for (const text of texts)
    for (const line of text.split("\n")) {
      let d: any;
      try {
        d = JSON.parse(line);
      } catch {
        continue;
      }
      const u = d?.message?.usage;
      if (!u || typeof u !== "object") continue;
      const t = [u.input_tokens, u.cache_creation_input_tokens, u.cache_read_input_tokens, u.output_tokens].map((v) => Number(v) || 0);
      const id = typeof d.message.id === "string" && d.message.id ? d.message.id : `anon-${anon++}`;
      const prev = byId.get(id);
      byId.set(id, { model: String(d.message.model || "unknown"), t: prev ? prev.t.map((v, i) => Math.max(v, t[i]!)) : t });
    }
  const out = new Map<string, number[]>();
  for (const { model, t } of byId.values()) out.set(model, (out.get(model) ?? [0, 0, 0, 0]).map((v, i) => v + t[i]!));
  return new Map([...out.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

function recordTokens(sd: string, id: string, kind: string, harness: string, sid: string): void {
  const file = `${sd.slice(0, sd.lastIndexOf("/"))}/records/task-tokens.tsv`;
  const date = run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", out: "pipe" });
  const head = [date.status === 0 ? subst(date.out) : "", id, kind, harness || "-"];
  const unknown = (why: string): string[][] => [[...head, `unknown: ${why}`, "", "", "", ""]];
  let rows: string[][];
  if (sid === "") rows = unknown("no session_id");
  else {
    const root = process.env.AC_CLAUDE_TRANSCRIPT_ROOT || `${process.env.CLAUDE_CONFIG_DIR || `${process.env.HOME}/.claude`}/projects`;
    let dirs: string[] = [];
    try {
      dirs = readdirSync(root).filter((d) => !d.startsWith(".") && existsSync(`${root}/${d}/${sid}.jsonl`));
    } catch {}
    if (dirs.length !== 1) rows = unknown(`${dirs.length ? `${dirs.length} transcripts` : "no transcript"} for session ${sid}`);
    else {
      const dir = `${root}/${dirs[0]}`;
      const texts: string[] = [];
      try {
        texts.push(readFileSync(`${dir}/${sid}.jsonl`, "utf8"));
        const subs = `${dir}/${sid}/subagents`;
        if (existsSync(subs)) for (const f of readdirSync(subs)) if (f.endsWith(".jsonl")) texts.push(readFileSync(`${subs}/${f}`, "utf8"));
      } catch (e) {
        say(`could not record ${id}'s token use in ${file}: ${e instanceof Error ? e.message : String(e)}`);
        return;
      }
      rows = [...transcriptTokens(texts).entries()].map(([model, t]) => [...head, model, ...t.map(String)]);
      if (!rows.length) rows = unknown(`no usage in the transcript of session ${sid}`);
    }
  }
  try {
    try {
      writeFileSync(fsPath(file), "at\tid\tkind\tharness\tmodel\tinput\tcache_creation\tcache_read\toutput\n", { flag: "wx" });
    } catch (e: any) {
      if (e?.code !== "EEXIST") throw e;
    }
    appendFileSync(fsPath(file), fsPath(`${rows.map((r) => r.join("\t")).join("\n")}\n`));
  } catch (e) {
    say(`could not record ${id}'s token use in ${file}: ${e instanceof Error ? e.message : String(e)}`);
  }
}

async function main(): Promise<void> {
  const entered = enterCaller(process.argv.slice(2));
  atCaller = entered.atCaller;
  backendName();
  require("git");
  const bin = b8(STARTED_BIN);

  const argv = entered.args.map(b8);
  const id = argv[0] ?? "";
  if (id === "") fail("usage: ac-teardown.sh <id> [--force] [--pr-ready '<the captain acceptance>'] [--no-lesson '<why>'] [--no-fact '<why>']");
  let force = false;
  let prReady = "";
  let noLesson = "";
  let noFact = "";
  for (let i = 1; i < argv.length; ) {
    const a = argv[i]!;
    if (a === "--force") {
      force = true;
      i++;
    } else if (a === "--pr-ready") {
      prReady = argv[i + 1] ?? "";
      if (prReady === "") fail("--pr-ready carries the captain's acceptance words - they are the proof, so an empty value is refused");
      i += 2;
    } else if (a === "--no-lesson") {
      noLesson = argv[i + 1] ?? "";
      if (noLesson === "") fail("--no-lesson carries why the slice learned nothing new - it is the record, so an empty value is refused");
      i += 2;
    } else if (a === "--no-fact") {
      noFact = argv[i + 1] ?? "";
      if (noFact === "") fail("--no-fact carries why the slice verified no repo fact - it is the record, so an empty value is refused");
      i += 2;
    } else fail(`unknown argument: ${a}`);
  }

  if (!process.env.AC_HOME) die(NO_HOME);
  const sdU = softSubdir("state", true);
  if (sdU === "") process.exit(1);
  const sd = b8(sdU);
  const meta = `${sd}/${id}.meta`;
  if (!isFile(meta)) fail(`no crewmate meta for ${id}`);

  const pget = (key: string): string => {
    try {
      return cutNul(metaGet(u8(meta), key));
    } catch {
      process.exit(1);
    }
  };
  const kind = pget("kind");
  const harness = pget("harness");
  const sessionId = pget("session_id");
  const worktree = pget("worktree");
  const wtBackend = pget("worktree_backend");
  let leases = pget("leases") || worktree;
  let leaseIds = pget("lease_ids");
  if (wtBackend === "orca") {
    if (leases === worktree) leases = "";
    else if (leases.startsWith(`${worktree}:`)) {
      const colons = (s: string): number => s.split(":").length - 1;
      if (colons(leaseIds) === colons(leases)) leaseIds = leaseIds.slice(leaseIds.indexOf(":") + 1);
      leases = leases.slice(worktree.length + 1);
    }
  }
  const projectDir = pget("project_dir");
  const leaseBase = pget("lease_base");
  const branch = b8(crewBranch(u8(id)));
  process.env.AC_BACKEND = u8(cutNul(taskBackend(u8(id)))) || "herdr";

  const recordsDir = (): string => b8(softSubdir("records", true));
  const short = (sha: string): string => sha.slice(0, 12);

  const crewBranchHead = (): string => {
    let h = subst(git(projectDir, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { out: "pipe" }).out);
    if (h === "" && isDir(worktree)) h = subst(git(worktree, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { out: "pipe" }).out);
    return h;
  };
  const isAncestor = (dir: string, a: string, b: string): boolean => git(dir, ["merge-base", "--is-ancestor", a, b], quiet).status === 0;
  // A tree git cannot read holds what nobody can check: null, which every gate
  // refuses. A tree that is gone holds nothing.
  const dirtyOf = (wt: string): string | null => {
    if (!isDir(wt)) return "";
    const st = worktreeStatus(u8(wt));
    return st.status === 0 ? st.out : null;
  };
  const unreadable = (wt: string): string => `worktree ${wt} cannot be read by git, so its contents cannot be checked; repair it or --force to discard`;
  // Untracked-only dirt is usually scratch the task left behind, which the
  // reader can move or discard on sight; a tracked edit needs its diff read.
  const dirty = (msg: string, status: string): void => {
    raw(msg);
    const lines = status.split("\n").filter((l) => l !== "");
    if (lines.some((l) => !l.startsWith("?? "))) return;
    const paths = lines.map((l) => l.slice(3));
    raw(`untracked only, no tracked edits: ${paths.slice(0, 10).join(", ")}${paths.length > 10 ? ` (+${paths.length - 10} more)` : ""}`);
  };

  const epicBranchContains = (repo: string, head: string): boolean => {
    const e = epicBaseFor(u8(id), u8(basename(repo)));
    if (e.rc === 2) say(`cannot read the ledger to resolve the epic-branch fence for ${id} - containment in an epic branch stays unproven`);
    if (e.rc !== 0) return false;
    const eb = e.entry.split(" ")[0]!;
    for (const ref of [`refs/heads/${eb}`, `refs/remotes/origin/${eb}`]) if (isAncestor(repo, head, ref)) return true;
    return false;
  };

  const remoteBranchContains = (repo: string, head: string): boolean => {
    const refs = git(repo, ["for-each-ref", "--contains", head, "--format=%(refname:lstrip=3)", "refs/remotes"], { out: "pipe", err: "ignore" }).out.toString("latin1").split("\n");
    if (refs[refs.length - 1] === "") refs.pop();
    return refs.some((r) => r !== "" && r !== branch && r !== "HEAD");
  };

  const headLanded = (head: string): boolean => {
    if (mget(meta, "pr_merged") === "1") {
      const merged = mget(meta, "pr_merged_head");
      if (merged === "") return true;
      if (isAncestor(projectDir, head, merged)) return true;
    }
    if (prReady !== "") {
      const prHead = mget(meta, "pr_head");
      if (prHead !== "" && !isAncestor(worktree, head, prHead)) {
        raw(`--pr-ready refused: HEAD ${short(head)} is newer than the recorded PR head (${prHead}) - the captain accepted the PR, not commits past it. Push and re-record (bin/ac-pr-check.sh ${id} <url>), then ask again`);
        return false;
      }
      return true;
    }
    for (const ref of [b8(defaultBranch(u8(projectDir), true)), b8(defaultRef(u8(projectDir), true))]) if (isAncestor(projectDir, head, ref)) return true;
    return epicBranchContains(projectDir, head) || remoteBranchContains(projectDir, head);
  };

  const worktreeHeadUnlanded = (covering = ""): string | null => {
    if (!isDir(worktree)) return null;
    const r = git(worktree, ["rev-parse", "--verify", "--quiet", "HEAD"], { out: "pipe", err: "ignore" });
    if (r.status !== 0) return null;
    const wtHead = subst(r.out);
    if (covering !== "" && isAncestor(worktree, wtHead, covering)) return null;
    return headLanded(wtHead) ? null : wtHead;
  };

  // The first OTHER non-verifier member of <fam>, by its id's family or its
  // fleet_scope - header: THE GATE.
  const familyMemberInFlight = (fam: string): string | null => {
    for (const m of metaFiles(sd)) {
      if (!exists(m) || metaIsVerify(u8(m))) continue;
      const other = metaId(m);
      if (other === id) continue;
      if (b8(familyOfId(u8(other))) === fam || mget(m, "fleet_scope") === fam) return other;
    }
    return null;
  };

  // The main checkout a tree belongs to: git's common dir entered from the
  // tree, then its parent, physically.
  const leaseRepo = (tree: string): string => {
    const r = git(tree, ["rev-parse", "--git-common-dir"], { out: "pipe", err: "ignore" });
    if (r.status !== 0) return "";
    const p = physicalDir(resolve(u8(tree), u8(subst(r.out)), ".."));
    return p === null ? "" : b8(p);
  };

  const extraLeaseAtRisk = (): { lease: string; why: string } | null => {
    const covering = crewBranchHead();
    const primary = leaseRepo(projectDir);
    for (const lease of leases.split(":")) {
      if (lease === "" || lease === worktree || !isDir(lease)) continue;
      const d = dirtyOf(lease);
      if (d === null) return { lease, why: `lease ${lease} cannot be read by git, so its contents cannot be checked and it would be returned with --force; repair it, or --force to discard` };
      if (d !== "") return { lease, why: "" };
      const r = git(lease, ["rev-parse", "--verify", "--quiet", "HEAD"], { out: "pipe", err: "ignore" });
      if (r.status !== 0) continue;
      const head = subst(r.out);
      const repo = leaseRepo(lease);
      let covered = covering !== "" && repo !== "" && repo === primary && isAncestor(lease, head, covering);
      if (!covered && repo !== "") {
        for (const ref of [b8(defaultBranch(u8(repo), true)), b8(defaultRef(u8(repo), true))])
          if (isAncestor(repo, head, ref)) {
            covered = true;
            break;
          }
        covered ||= epicBranchContains(repo, head) || remoteBranchContains(repo, head);
      }
      if (!covered) return { lease, why: "" };
    }
    return null;
  };

  const prReadyPreconditions = (): void => {
    if (mget(meta, "pr") === "") fail(`--pr-ready with no recorded PR for ${id} - record it first (bin/ac-pr-check.sh ${id} <url>)`);
    const status = dirtyOf(worktree);
    if (status === null) fail(`--pr-ready refused: ${unreadable(worktree)}`);
    const dirty = status.replace(/\n+$/, "");
    if (dirty !== "")
      fail(`--pr-ready refused: the worktree holds uncommitted work the accepted PR cannot contain - commit and push it (then re-record the PR head), or discard it deliberately, before the acceptance lands:\n${dirty}`);
    const ledger = `${recordsDir()}/backlog.md`;
    try {
      accessSync(fsPath(ledger), constants.R_OK);
    } catch {
      fail(`--pr-ready refused: cannot read ${ledger} to prove no open row waits on ${id} - an unreadable ledger must not read as 'no dependent'`);
    }
    const dep = subst(
      run(
        [
          "/usr/bin/env",
          "LC_ALL=C",
          "awk",
          "-v",
          u8(`id=${id}`),
          'BEGIN { w[id] }\n    /^- \\[ \\]/ && (i = index($0, "blocked-by:")) {\n      s = substr($0, i + 11)\n      if ((j = index(s, " - ")) > 0) s = substr(s, 1, j - 1)\n      n = split(s, a, /[,[:space:]]+/)\n      for (k = 1; k <= n; k++) if (a[k] in w) { print $4; exit }\n    }',
          u8(`${recordsDir()}/backlog.md`),
        ],
        { out: "pipe" },
      ).out,
    );
    if (dep !== "") fail(`--pr-ready refused: open row ${dep} still waits on ${id} (blocked-by) - a dependent starts from the merged tree, so this task lands only by the real merge`);
  };

  const scoutReportPresent = (dir: string): boolean => {
    if (isFile(`${dir}/report.md`)) return true;
    if (!/-design(-r[0-9]{1,2})?$/.test(id)) return false;
    const fam = dirname(dir);
    return ["spec", "arch", "plan"].some((s) => isFile(`${fam}/${s}/report.md`));
  };

  const landedProof = (): boolean => {
    if (kind === "roomchief") {
      const fam = id.replace(/-chief$/, "");
      const other = familyMemberInFlight(fam);
      if (other === null) return true;
      raw(`family ${fam} still has crew in flight: ${other}`);
      return false;
    }
    if (kind === "crewdeputy") {
      const found = metaFiles(`${worktree}/state`);
      if (run(["ls", ...(found.length > 0 ? found : [`${worktree}/state/*.meta`]).map(u8)], quiet).status !== 0) return true;
      raw(`crewdeputy home still has crew in flight: ${worktree}/state/*.meta`);
      return false;
    }
    if (projectDir === "") {
      raw(`the meta of ${id} records no project_dir, so its landed work has no repository to be proven in`);
      return false;
    }
    if (prReady !== "") prReadyPreconditions();
    const atRisk = extraLeaseAtRisk();
    if (atRisk !== null) {
      raw(atRisk.why || `lease ${atRisk.lease} holds uncommitted or unlanded work and would be returned with --force; land or move it, or --force to discard`);
      return false;
    }
    if (kind === "scout") {
      let dir: string;
      try {
        dir = b8(taskDir(u8(id)).replace(/\n+$/, ""));
      } catch (e) {
        raw(`ERROR: ${b8((e as Error).message)}`);
        return false;
      }
      if (!scoutReportPresent(dir)) {
        raw(`scout report missing: no report.md at ${dir} (nor merged-design sub-stage reports)`);
        return false;
      }
      const shead = crewBranchHead();
      if (shead !== "" && !headLanded(shead)) {
        raw(`scout created ${branch} with unlanded work; promote it (ac-promote.sh ${id}) or --force to discard`);
        return false;
      }
      const sd0 = dirtyOf(worktree);
      if (sd0 === null) {
        raw(unreadable(worktree));
        return false;
      }
      if (sd0 !== "") {
        dirty(`worktree is dirty: uncommitted changes that ${branch} does not hold; commit them or --force to discard`, sd0);
        return false;
      }
      const unlanded = worktreeHeadUnlanded(shead);
      if (unlanded !== null) {
        raw(`worktree HEAD ${short(unlanded)} holds commits nothing landed contains; put them on ${branch} and promote it (ac-promote.sh ${id}), or --force to discard`);
        return false;
      }
      return true;
    }
    const head = crewBranchHead();
    const wd = dirtyOf(worktree);
    if (wd === null) {
      raw(unreadable(worktree));
      return false;
    }
    if (head === "") {
      if (wd !== "") {
        dirty(`worktree is dirty and no ${branch} branch exists`, wd);
        return false;
      }
      const unlanded = worktreeHeadUnlanded();
      if (unlanded !== null) {
        raw(`worktree HEAD ${short(unlanded)} holds commits no branch carries and nothing landed contains; put them on ${branch} (git -C ${worktree} branch ${branch} ${short(unlanded)}) and land it, or --force to discard`);
        return false;
      }
      return true;
    }
    if (wd !== "") {
      dirty(`worktree is dirty: uncommitted changes that ${branch} does not hold; commit them or --force to discard`, wd);
      return false;
    }
    if (!headLanded(head)) {
      raw(`branch ${branch} (${short(head)}) is not landed: not in ${b8(defaultBranch(u8(projectDir), true))} (local or origin), no containing remote branch, no merged PR`);
      return false;
    }
    const unlanded = worktreeHeadUnlanded(head);
    if (unlanded !== null) {
      raw(`worktree HEAD ${short(unlanded)} is past the landed ${branch} (${short(head)}) and nothing landed contains it; move ${branch} to it and land that, or --force to discard`);
      return false;
    }
    return true;
  };

  // A status append where errexit was awake: date's failure ends the run with
  // its status, an append that cannot be written exit 1.
  const append = (line: string): void => {
    try {
      if (!statusAppend(u8(id), line, true)) process.exit(1);
    } catch (e) {
      process.exit((e as { status?: number }).status ?? 1);
    }
  };

  const reapWatcherStamps = (tid: string): void => {
    for (const s of taskStamps(sdU, u8(tid))) rmF(b8(s));
  };

  const reapPaneFile = (f: string): void => {
    if (!isFile(f)) return;
    const r = run(["awk", "NR == 1 { print $1 }", u8(f)], { out: "pipe", err: "ignore" });
    if (r.status !== 0) {
      say(`could not read ${f}: the pane could not be identified, it may be orphaned`);
      return;
    }
    const p = subst(r.out);
    if (p === "") {
      rmF(f);
      return;
    }
    let agent = false;
    try {
      accessSync(fsPath(`${bin}/ac-pane-agent.sh`), constants.X_OK);
      agent = true;
    } catch {}
    // reap-pane picks its arm through ac_backend, so by the pinned AC_BACKEND.
    const be = backendRoute("ignore") ?? "herdr";
    if (!agent || !commandV(be)) {
      say(`could not reap pane ${p} (${f}): ${be} or ac-pane-agent.sh unavailable`);
      return;
    }
    const answer = subst(run([u8(`${bin}/ac-pane-agent.sh`), "reap-pane", "--pane", u8(p)], { out: "pipe", err: "ignore" }).out);
    if (answer.includes('"closed":false')) say(`pane ${p} (${f}) did not close - it is orphaned in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane --pane ${p}`);
    rmF(f);
  };

  const warnUnattributed = (rd: string): void => {
    for (const f of ["review.pane", "watch.pane", "serve.pid"]) {
      if (!isFile(`${rd}/${f}`)) continue;
      let body = "";
      try {
        body = subst(readFileSync(fsPath(`${rd}/${f}`)));
      } catch {}
      say(`not reaping ${body} - run ${rd} is attributed to no task (${rd}/${f})`);
    }
  };

  // The first `<key>=` line of a run.meta through sed, as `$(sed | head -n1)`
  // read it; null when sed cannot read it (its own line already on stderr).
  const attribution = (m: string, key: string): string | null => {
    const r = run(["sed", "-n", `s/^${key}=//p`, u8(m)], { out: "pipe" });
    if (r.status !== 0) return null;
    return r.out.toString("latin1").split("\n")[0]!.replace(/\0/g, "");
  };
  const unswept = (m: string, rd: string): void => say(`could not read ${m}: run ${rd} was not swept - its panes and qa serve process, if any, may survive`);

  const sweepPaneAgents = (dir: string): void => {
    const sid = subst(run(["/bin/sh", "-c", 'printf "%s" "$0" | tr "[:upper:]" "[:lower:]" | tr -c "a-z0-9_-" "-"', u8(id)], { out: "pipe" }).out);
    reapPaneFile(`${dir}/.crew/qa/agent-${sid}.pane`);
    for (const m of runMetas(`${dir}/.crew/qa`)) {
      const rd = m.slice(0, -"/run.meta".length);
      if (!isFile(m) || isLink(rd)) continue;
      const attr = attribution(m, "task");
      if (attr === null) unswept(m, rd);
      else if (attr === id) {
        reapPaneFile(`${rd}/watch.pane`);
        killServePid(`${rd}/serve.pid`);
      } else if (attr === "") warnUnattributed(rd);
    }
    for (const m of runMetas(`${dir}/.crew/ship`)) {
      const rd = m.slice(0, -"/run.meta".length);
      if (!isFile(m) || isLink(rd)) continue;
      const attr = attribution(m, "branch");
      if (attr === null) unswept(m, rd);
      else if (attr === branch) {
        reapPaneFile(`${rd}/review.pane`);
        reapPaneFile(`${rd}/watch.pane`);
      } else if (attr === "") warnUnattributed(rd);
    }
  };

  const verifierOwnedByTask = (vm: string): boolean => {
    const caller = mget(vm, "caller");
    if (caller === id) return true;
    if (caller !== "") return false;
    const family = mget(vm, "family");
    return family !== "" && family === b8(familyOfId(u8(id)));
  };

  const evidenceComplete = (vm: string): boolean => {
    const ev = mget(vm, "evidence");
    return ev !== "" && nonEmpty(`${ev}/verdict.json`) && nonEmpty(`${ev}/relay-report.md`) && isDir(`${ev}/run-state`);
  };

  const preserveIncompleteQa = (vm: string, vid: string): void => {
    if (mget(vm, "kind") !== "verify-qa" || evidenceComplete(vm)) return;
    const family = mget(vm, "family");
    let evidence = mget(vm, "evidence");
    if (evidence === "") evidence = `${b8(softSubdir("data", true))}/${family || "unknown"}/verification/${vid}-incomplete-${b8(nowRaw())}`;
    if (run(["mkdir", "-p", u8(evidence)]).status !== 0) fail(`cannot preserve incomplete QA verifier ${vid} at ${evidence}`);
    if (run(["cp", u8(vm), u8(`${evidence}/verifier.meta`)]).status !== 0) fail(`cannot preserve verifier meta for incomplete QA ${vid}`);
    const output = mget(vm, "output");
    const paneResult = mget(vm, "pane_result");
    if (isFile(output)) must(["cp", output, `${evidence}/verdict.partial.json`]);
    if (isFile(paneResult)) must(["cp", paneResult, `${evidence}/pane-result.ndjson`]);
    const tree = mget(vm, "worktree");
    const current = `${tree}/.crew/qa/current`;
    let runDir = "";
    if (isLink(current)) runDir = `${tree}/.crew/qa/${subst(must(["readlink", current], { out: "pipe" }))}`;
    else if (isDir(current)) runDir = current;
    if (runDir !== "" && isDir(runDir) && !isDir(`${evidence}/run-state`)) {
      must(["mkdir", "-p", `${evidence}/run-state`]);
      if (run(["cp", "-R", u8(`${runDir}/.`), u8(`${evidence}/run-state/`)]).status !== 0) fail(`cannot preserve QA run state for incomplete verifier ${vid}`);
    }
    const rec = `${evidence}/incomplete-run.md`;
    let tmp: { path: string; fd: number };
    try {
      tmp = exclusiveTemp(u8(`${rec}.tmp`));
    } catch {
      fail(`cannot write incomplete QA artifact for ${vid}`);
    }
    try {
      writeAll(
        tmp.fd,
        fsPath(
          `# Incomplete QA verifier teardown\n\nVerifier: \`${vid}\`\n\nFamily: \`${family || "unknown"}\`\n\nPreserved at: \`${subst(run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", out: "pipe" }).out)}\`\n\nThis verifier was explicitly torn down before verdict, relay report, and run-state export were all complete. Inspect the preserved metadata and partial artifacts before retrying QA.\n`,
        ),
      );
    } catch {
      fail(`cannot write incomplete QA artifact for ${vid}`);
    } finally {
      closeSync(tmp.fd);
    }
    try {
      chmodSync(tmp.path, statSync(fsPath(rec)).mode & 0o7777);
    } catch {}
    must(["mv", b8(tmp.path), rec]);
  };

  // The task archive's layout (below), so a verifier's latest record is
  // where an operator looks first.
  const archiveAndReapVerifier = (vm: string): void => {
    const vid = metaId(vm);
    const varchive = `${sd}/archive/${vid}`;
    must(["mkdir", "-p", varchive]);
    if (exists(`${varchive}/meta`)) {
      const prior = subst(must(["mktemp", "-d", `${varchive}/${b8(nowRaw())}.XXXXXX`], { out: "pipe" }));
      must(["mv", `${varchive}/meta`, `${prior}/meta`]);
      if (isFile(`${varchive}/status`)) must(["mv", `${varchive}/status`, `${prior}/status`]);
    }
    must(["mv", vm, `${varchive}/meta`]);
    if (isFile(`${sd}/${vid}.status`)) must(["mv", `${sd}/${vid}.status`, `${varchive}/status`]);
    reapPaneFile(`${sd}/.pane-${vid}`);
    const archived = `${varchive}/meta`;
    let rest = mget(archived, "leases") || mget(archived, "worktree");
    let ids = mget(archived, "lease_ids");
    const backendV = mget(archived, "backend");
    while (rest !== "") {
      let lease: string;
      let leaseId: string;
      if (rest.includes(":")) [lease, rest] = [rest.slice(0, rest.indexOf(":")), rest.slice(rest.indexOf(":") + 1)];
      else [lease, rest] = [rest, ""];
      if (ids.includes(":")) [leaseId, ids] = [ids.slice(0, ids.indexOf(":")), ids.slice(ids.indexOf(":") + 1)];
      else [leaseId, ids] = [ids, ""];
      if (lease === "") continue;
      if (!isDir(lease)) {
        say(`skipping vanished verifier lease ${lease}: directory no longer exists`);
        continue;
      }
      if ((backendV || b8(backendRoute("inherit") ?? "")) === "orca") {
        if (!orcaWorktreeRelease(u8(lease))) say(`could not release orca verifier worktree ${lease}; inspect ${varchive}/meta`);
      } else if (leaseId !== "") {
        if (run([`${bin}/ac-tree.sh`, "return", lease, "--force", "--if-lease-id", leaseId].map(u8), quiet).status !== 0)
          say(`could not return verifier worktree ${lease} (it may have been re-leased); inspect ${varchive}/meta`);
      } else if (run([`${bin}/ac-tree.sh`, "return", lease, "--force"].map(u8), quiet).status !== 0) say(`could not return verifier worktree ${lease}; inspect ${varchive}/meta`);
    }
    const callerV = mget(archived, "caller");
    const kindV = mget(archived, "kind").replace(/^verify-/, "");
    try {
      rmdirSync(fsPath(`${sd}/.verify-${callerV}-${kindV}.lock.d`));
    } catch {}
    reapWatcherStamps(vid);
  };

  // `$(ac_iso)` where errexit was awake: a date that fails ends the run.
  function isoOrExit(): string {
    const r = run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], { stdin: "ignore", out: "pipe" });
    if (r.status !== 0) process.exit(r.status);
    return subst(r.out);
  }

  const ownedVerifier = (vm: string, skipOwn: boolean): boolean => isFile(vm) && !(skipOwn && vm === meta) && metaIsVerify(u8(vm)) && verifierOwnedByTask(vm);

  if (metaIsVerify(u8(meta))) {
    preserveIncompleteQa(meta, id);
    archiveAndReapVerifier(meta);
    out(`teardown ${id} complete (verifier)\n`);
    process.exit(0);
  }

  if (!force && !landedProof()) fail(`refusing teardown of ${id} (unlanded work); land it or pass --force to discard`);

  if (kind === "self" && !force) {
    // The waivers are records of a landing, so a refused one writes none.
    const waive = (pass: boolean): void => {
      if (!pass) return;
      if (noLesson !== "") append(`lesson waived: ${noLesson}`);
      if (noFact !== "") append(`repo fact waived: ${noFact}`);
    };
    if (!soloLandingCheck(u8(id), u8(projectDir), u8(noLesson), u8(noFact), u8(mget(meta, "fleet_scope")), waive))
      fail("solo landing refused: the knowledge loop above is incomplete - write what is missing (or waive the lesson/fact with --no-lesson/--no-fact '<why>'), then run the teardown again");
  }
  // The preflight is durable and says the verifier "was explicitly torn
  // down", so it runs only past both gates; the tick waits for it, because a
  // keyed tick dedupes for 24h only and a preflight death retried later
  // would count one landing twice.
  for (const vm of metaFiles(sd)) if (ownedVerifier(vm, true)) preserveIncompleteQa(vm, metaId(vm));
  if (kind === "self" && !force) {
    const tick = run(["/bin/sh", "-c", '"$0" tick "$1" 2>&1', u8(`${bin}/ac-learn.sh`), u8(id)], { out: "pipe" });
    for (const line of subst(tick.out).split("\n")) append(`learning tick: ${line}`);
    if (tick.status !== 0) say(`learning tick for ${id} failed (exit ${tick.status}) - this landing is not counted; re-run: ${bin}/ac-learn.sh tick ${id}`);
  }

  const archive = `${sd}/archive/${id}`;
  must(["mkdir", "-p", archive]);
  if (exists(`${archive}/meta`)) {
    const prior = subst(must(["mktemp", "-d", `${archive}/${b8(nowRaw())}.XXXXXX`], { out: "pipe" }));
    must(["mv", `${archive}/meta`, `${prior}/meta`]);
    if (isFile(`${archive}/status`)) must(["mv", `${archive}/status`, `${prior}/status`]);
  }
  if (prReady !== "") append(`done: captain accepted the ready-to-merge PR - ${prReady}`);
  append(`resolved: teardown${force ? " (forced)" : ""}`);
  must(["mv", meta, `${archive}/meta`]);
  if (isFile(`${sd}/${id}.status`)) must(["mv", `${sd}/${id}.status`, `${archive}/status`]);
  reapWatcherStamps(id);

  let handle = "";
  try {
    handle = subst(readFileSync(fsPath(`${sd}/.pane-${id}`)));
  } catch {}
  const killed_ = backendKillWindow(u8(id));
  if (killed_.exited) process.exit(killed_.status);
  if (killed_.status !== 0) {
    let cmd: string;
    if (backendRoute("inherit") === "orca") cmd = `orca terminal close --terminal ${handle.split(" ")[0]}`;
    else {
      const sess = b8(process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", ""));
      cmd = `herdr tab close ${handle.includes(" ") ? handle.slice(handle.indexOf(" ") + 1) : handle}${sess ? ` --session ${sess}` : ""}`;
    }
    say(`pane close FAILED for ${id} - a live pane may survive this teardown (handle: ${handle || "none"}); close it by hand: ${cmd}`);
    const ts = isoOrExit();
    const line = `warn: pane close failed - handle ${handle || "none"}; close by hand: ${cmd}`;
    try {
      appendFileSync(fsPath(`${archive}/status`), fsPath(`${ts} ${line}\n`));
    } catch {
      process.exit(1);
    }
    statusTimelineMirror(u8(id), fsPath(`${ts} ${line}\n`));
  }
  if (kind !== "self") recordTokens(sd, id, kind, harness, sessionId);
  for (const vm of metaFiles(sd)) if (ownedVerifier(vm, false)) archiveAndReapVerifier(vm);

  if (kind === "roomchief") {
    const fam = id.replace(/-chief$/, "");
    const msg = `DEMOTED: roomchief closed${force ? " (forced)" : ""}`;
    const r = run([`${bin}/ac-room.sh`, "post", fam, "crewchief", msg].map(u8), { out: "ignore", err: "pipe" });
    if (r.status !== 0) say(`could not post DEMOTED to room ${fam}: ${subst(r.err)} - post it by hand: ${bin}/ac-room.sh post ${fam} crewchief "${msg}"`);
  }

  if (kind !== "crewdeputy" && kind !== "roomchief") {
    let restIds = leaseIds;
    for (const lease of leases.replace(/:/g, "\n").replace(/\n+$/, "").split("\n")) {
      let leaseId: string;
      if (restIds.includes(":")) [leaseId, restIds] = [restIds.slice(0, restIds.indexOf(":")), restIds.slice(restIds.indexOf(":") + 1)];
      else [leaseId, restIds] = [restIds, ""];
      if (lease === "") continue;
      if (!isDir(lease)) {
        say(`skipping vanished lease ${lease}: directory no longer exists`);
        continue;
      }
      sweepPaneAgents(lease);
      portSlotRelease(u8(lease));
      if (leaseId !== "") {
        if (run([`${bin}/ac-tree.sh`, "return", lease, "--force", "--if-lease-id", leaseId].map(u8), quiet).status !== 0)
          say(`could not return worktree ${lease} (it may have been re-leased); check the pool with ac-tree.sh list`);
      } else if (run([`${bin}/ac-tree.sh`, "return", lease, "--force"].map(u8), quiet).status !== 0) say(`could not return worktree ${lease}; check the pool with ac-tree.sh list`);
    }

    if (wtBackend === "orca" && worktree !== "" && isDir(worktree)) {
      sweepPaneAgents(worktree);
      portSlotRelease(u8(worktree));
      if (!orcaWorktreeRelease(u8(worktree))) say(`could not remove orca worktree ${worktree} (remove by hand: orca worktree rm --worktree path:${worktree} --force)`);
    }

    if (projectDir === "") say(`no project_dir recorded for ${id} - ${branch} was not looked for; drop it by hand in the repository that holds it`);
    else if (git(projectDir, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], { out: "ignore" }).status === 0) {
      // Orca's own release can leave git's worktree registration stale for a
      // directory already gone (measured: `git branch -d` then refuses "used
      // by worktree" against the registration alone, with no live worktree
      // behind it) - whether that is a release/deregister race or orca never
      // calling `git worktree remove` for it. `git worktree remove <path>` on
      // an already-missing directory clears it with no race to time, so the
      // drop below never depends on which one happened.
      if (wtBackend === "orca" && worktree !== "" && !isDir(worktree)) git(projectDir, ["worktree", "remove", worktree], quiet);
      let flag = "-d";
      const e = epicBaseFor(u8(id), u8(basename(projectDir)));
      if (e.rc === 2) say(`cannot read the ledger to resolve the epic-branch fence for ${id} - ${branch} is deleted only if -d proves it merged`);
      if (e.rc === 0) {
        const eb = e.entry.split(" ")[0]!;
        if (isAncestor(projectDir, `refs/heads/${branch}`, `refs/heads/${eb}`) || isAncestor(projectDir, `refs/heads/${branch}`, `refs/remotes/origin/${eb}`)) flag = "-D";
      }
      // The recorded --base-branch lease base (spawn.ts: lease_base=): `-d`
      // proves containment only in the PRIMARY's own HEAD/upstream, so a
      // 0-commit branch cut from a base that is neither reads as "not fully
      // merged" with no commit of its own to lose. isAncestor fails the
      // moment the branch carries a commit the base does not, so a branch
      // with its own unlanded work is never escalated by this leg. Gated on
      // e.rc === 1 (no epic fence at all): an agreeing fence already proved
      // it above, and an UNREADABLE ledger must keep today's fail-closed -d
      // only, never a second path around it. leaseBase !== branch: a
      // --base-branch naming the task's OWN family branch (continuing a live
      // sibling, e.g. a revision) makes isAncestor(branch, branch) trivially
      // true - without this guard that would -D the WHOLE family branch,
      // including every commit a sibling has not landed yet.
      if (flag === "-d" && e.rc === 1 && leaseBase !== "" && leaseBase !== branch && (isAncestor(projectDir, `refs/heads/${branch}`, `refs/heads/${leaseBase}`) || isAncestor(projectDir, `refs/heads/${branch}`, `refs/remotes/origin/${leaseBase}`))) flag = "-D";
      const del = run(["/bin/sh", "-c", 'exec "$0" "$@" 2>&1', "git", "-C", u8(projectDir), "branch", flag, u8(branch)], { out: "pipe" });
      if (del.status !== 0) {
        const held = git(projectDir, ["worktree", "list", "--porcelain"], { out: "pipe" }).out.toString("latin1").split("\n").includes(`branch refs/heads/${branch}`);
        say(`kept ${branch} in ${projectDir}: ${subst(del.out)} - reclaim: ${held ? `free it from that worktree, then git branch -D ${branch}` : `git branch -D ${branch}`}`);
      }
    }
  }

  const qaFam = kind === "roomchief" ? id.replace(/-chief$/, "") : b8(familyOfId(u8(id)));
  // ac-qa.sh scopes a stack by the repo it ran in, and once every member is
  // torn down only the archive still names a family's repos.
  const familyProjects = (): string[] => {
    const dirs = new Set<string>();
    for (const a of listed(`${sd}/archive`, (n) => !n.startsWith("."))) {
      const m = `${a}/meta`;
      if (!isFile(m) || metaIsVerify(u8(m)) || mget(m, "kind") === "roomchief") continue;
      if (b8(familyOfId(u8(basename(a)))) !== qaFam && mget(m, "fleet_scope") !== qaFam) continue;
      dirs.add(mget(m, "project_dir"));
    }
    return [...dirs].sort(byteOrder);
  };
  const sweepDirs = !commandV("docker") || kind === "crewdeputy" ? [] : (kind === "roomchief" ? familyProjects() : [projectDir]).filter((d) => d !== "" && isDir(d));
  if (sweepDirs.length > 0) {
    const sigs = ["SIGHUP", "SIGINT", "SIGTERM", "SIGURG"] as const;
    const handlers = sigs.map((sig) => {
      const h = (): void => {
        say(`teardown ${id}: caught ${sig} during the qa-infra sweep`);
        process.removeListener(sig, h);
        process.kill(process.pid, sig);
      };
      process.on(sig, h);
      return [sig, h] as const;
    });
    let famStack = `${qaFam}-qa` === id ? "" : `${qaFam}-qa`;
    if (famStack !== "") {
      const holder = familyMemberInFlight(qaFam);
      if (holder !== null) {
        out(`qa-infra: family stack ${famStack} kept - ${holder} is still in flight and its qa run may hold it\n`);
        famStack = "";
      }
    }
    const t = process.env.AC_TEARDOWN_QA_TIMEOUT ?? "30";
    const secs = /^[0-9]+$/.test(t) ? t : "30";
    for (const dir of sweepDirs) {
      const rc =
        physicalDir(u8(dir)) === null
          ? 1
          : (
              await runBounded(
                ["/bin/sh", "-c", 'rc=0\n"$0" infra down --task "$1" >/dev/null 2>&1 || rc=$?\n[ -z "$2" ] || "$0" infra down --task "$2" >/dev/null 2>&1 || rc=$?\nexit "$rc"', u8(`${bin}/ac-qa.sh`), u8(id), u8(famStack)],
                secs,
                "ignore",
                u8(dir),
              )
            ).status;
      if (rc !== 0)
        say(`qa-infra sweep for ${id} did not complete (status ${rc}, bound ${secs}s) - docker is unusable or hung; any task stack survives: (cd ${dir} && ${bin}/ac-qa.sh infra down --task ${id}${famStack ? ` && ${bin}/ac-qa.sh infra down --task ${famStack}` : ""})`);
    }
    for (const [sig, h] of handlers) process.removeListener(sig, h);
  }

  out(`teardown ${id} complete${force ? " (forced)" : ""}\n`);

  if (kind === "roomchief") {
    const next = subst(run(["/bin/sh", "-c", '"$0" queued 2>/dev/null | head -n1', u8(`${bin}/ac-ready.sh`)], { out: "pipe" }).out);
    if (next !== "") out(`a chief slot is free - next queued family: ${next} (promote with bin/ac-spawn.sh --roomchief ${next})\n`);
  }
  process.exit(0);
}

if (import.meta.main) await main();
