// spawn.ts - spawn a crewmate: lease an in-repo worktree, open a window on
// the session backend (a herdr tab), and launch
// the harness with the brief. Also spawns crewdeputies: persistent supervisors
// that run in their own seeded home instead of a project worktree. Refused in
// a solo session (AC_SOLO=1), whose one write path is ac-self-task.sh.
// The entry is bin/ac-spawn.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-spawn.sh as the oracle the
// differential leg of tests/sh/ac-spawn-differential.test.sh holds this module to.
//
// Usage: ac-spawn.sh <id> <project-name-or-dir> [--scout] [--mode <m>]
//                    [--harness <claude|codex|opencode|pi|cursor|custom>] [--model <name>]
//                    [--effort <low|medium|high|xhigh|max|ultracode>]
//                    [--backend <herdr|orca>]
//                    [--resume-from <old-task-id>]
//                    [--base-branch <b>]
//        ac-spawn.sh <id> <project> --recover        (reopen a destroyed pane)
//        ac-spawn.sh --roomchief <family> --recover  (same, for a roomchief)
//        ac-spawn.sh <id> --crewdeputy [--recover] [--harness <h>] [--backend <b>]
//        ac-spawn.sh --roomchief <family> [--solo] [--harness <h>] [--backend <b>]
//                    [--captain-initiated "<order ref>" | --system-initiated "<order ref>"
//                     | --over-cap "<sanction>"]
//
// --roomchief promotes a hot room: a dedicated claude session (id
// <family>-chief) that owns ONLY that family's stages and gates, talks to
// the captain in its own thread, posts everything to the family room, and
// never touches the backlog/registry (the crewchief keeps those). It runs
// in the agent-crew checkout (no worktree lease, no brief - the room IS
// the brief) with AC_SCOPE=<family> exported.
//
// --solo promotes a SOLO CHIEF (solo-session
// skill): the same roomchief session, for a family the crewchief judged too small
// to cost a crewmate, that WORKS ITS OWN SLICES through ac-self-task.sh under
// every other roomchief duty. Roomchief-only (refused on a crew spawn - a
// crewmate has no such mode). Its meta stays kind=roomchief and gains solo=1
// (what every other process reads), its launch line gains AC_CHIEF_SOLO=1
// beside AC_SCOPE (what the session and its hooks read; distinct from the
// captain's own AC_SOLO=1 pair-coding session, which drains no wakes and
// answers no gates - a solo chief does both for its family), its kickoff
// gains the solo section (the slice verb with the family prefix, the
// MANDATORY crew-verify review round, the LANDED: room receipt that stands in
// for the Done row the ledger guard fences from it, hands-not-subagents), and
// its PROMOTED: receipt says so. The cap, the watcher skip set, teardown and
// the chiefs accounting class cover it with no edit, exactly as a domainchief.
//
// A promote whose family row carries the domain:<name> token becomes a
// DOMAINCHIEF - the same session kind, carrying a domain. Its meta stays
// kind=roomchief and gains domain=<name>, its launch line gains AC_DOMAIN
// beside AC_SCOPE, and its kickoff gains the domain section. The binding is
// DERIVED from the assignment, so there is no flag. The "never touches the
// backlog" clause above is the FLEET ledgers only: a domainchief moves its
// family's row through crewdomains/<name>/records/backlog.md (it may never mint
// one there) and may enrich that package's records/projects.md, while
// bin/ac-ledger-guard.sh keeps both fleet ledgers and records/captain.md out of
// every scoped session's reach.
//
// THE ORDER GATE. Because the room IS the brief, the promote is gated on it: a
// family room holding no ENTRY - the `- [` line shape ac-room.sh's cmd_post
// writes, never the file's mere existence (post creates it with a `# Room:
// <family>` header before any entry) - refuses fail-CLOSED, naming the
// post-then-promote fix. Promote-then-ac-send left the new chief orienting on an
// empty room and re-triaging when the order landed, two sources of truth for one
// task; refusing costs one command, an orderless roomchief costs a wrong triage.
// ANY entry passes, so bin/ac-learn.sh's charter-first autoroom (charter posted,
// THEN promote) needs no exemption and the hot-room upgrade this flag was built
// for is unaffected. It fires with the cap - after it - and before any window,
// lease or meta, so the exit-status contract below holds.
//
// Promotion is CAPPED, fail-closed: at most config/room-parallel (default 5,
// captain-pinned) roomchiefs in flight at once. Five concurrent chiefs hit
// session limits, stalled, and let their scoped watchers die un-re-armed
// (2026-07-16) - the cap is the backstop. The population counted is the state
// metas named <family>-chief whose kind is roomchief (a crewdeputy never holds
// a room slot); PRESENCE of the meta is what holds one, matching how the rest
// of the fleet defines in flight, so a chief stops counting exactly when
// ac-teardown.sh archives its meta. Counting presence rather than probing the
// backend keeps the error fail-CLOSED: a chief whose window died but whose meta
// is unarchived still holds its slot, refusing a promote that would have fit -
// whereas a backend hiccup read as "not live" would let the 6th chief in, which
// is the failure the cap exists to prevent. Past the cap the promote refuses,
// naming the flying families, before any window or meta exists. A non-numeric
// knob clamps to the default (the config/epic-parallel idiom) - it never
// refuses on its own.
// ALSO counted: any OTHER family's live pre-meta claim (state/.meta-claims/
// <family>-chief/) not yet backed by a meta - a promote's own meta is not
// written until after deliverKickoff settles (AC_SPAWN_SETTLE, several
// seconds), so two concurrent promotes for DIFFERENT families would otherwise
// both claim, both read the SAME (empty) meta population, and both pass,
// landing cap+1 chiefs. An in-flight claim's eventual initiated_by is not
// knowable from outside, so it counts as non-exempt (fail-closed); a claim
// past the same staleness grace spawnMetaClaimAcquire itself uses (dead
// owner) does not count - it is an abandoned pre-meta window, not a live
// promote.
//
// ORIGIN + CAP-GATE. Every roomchief meta records who initiated the promote:
// initiated_by=chief (default), initiated_by=captain or initiated_by=system,
// written beside kind. The cap counts ONLY chief-initiated (non-exempt) chiefs -
// a meta whose initiated_by is EXACTLY captain or system is EXEMPT and consumes
// no slot, while an ABSENT field - or any near-miss value (systemic, System,
// " system") - counts as chief-initiated (fail-closed: a pre-origin or typo'd
// meta must never silently open a slot). THREE mutually-exclusive flags gate a
// promote against that cap - at most one per promote, since a promote has
// exactly ONE origin (the meta has one initiated_by) and an already-exempt
// promote makes a sanction to exceed the cap meaningless:
//   --captain-initiated "<order ref>"  a captain-ORDERED promote. Non-empty ref
//       required. Writes initiated_by=captain, is EXEMPT (promotes even at a
//       full cap, needs no sanction), and posts a DECIDED: receipt naming the
//       family, the order ref, and that it does not count toward the cap.
//   --system-initiated "<order ref>"  a promote the FLEET made by itself on a
//       STANDING captain rule - nobody decided it now. Non-empty ref required,
//       and it names that rule. Writes initiated_by=system, is EXEMPT exactly
//       like captain, and posts a DECIDED: receipt saying `standing order:` -
//       the word that tells the captain this promote rode a rule they wrote
//       once, not a request they made now. That distinction is the whole reason
//       it is a third value and not a borrow of =captain: a receipt that named
//       the captain would tell them they ordered a promote they did not order,
//       and a later revocation of the standing rule could not find the rooms
//       that rode it. EXACTLY ONE caller in the distro passes it (a one-line
//       grep): `ac-learn.sh autoroom`, the DISTILL auto-trigger, carrying
//       records/captain.md "Learning room is chief-created and CAP-EXEMPT".
//       Deliberately NOT authenticated - like both siblings it
//       is a string nobody verifies; the control is the receipt plus the
//       captain's post-hoc veto.
//   --over-cap "<sanction>" (or env AC_ROOM_OVERCAP_REASON)  the crewchief's
//       ask-to-bypass for ONE extra chief-initiated slot past a full cap. Non-
//       empty sanction required when at the cap. Writes initiated_by=chief,
//       promotes past the cap EXACTLY ONCE (this spawn only - no persistent
//       state, config/room-parallel is NEVER written), and posts a DECIDED:
//       receipt naming the family, that it is +1 past room-parallel=<cap>, and
//       the captain sanction. Under the cap it is a no-op (no bypass, no receipt).
// This RETIRES the bump-config-then-restore hack (racy, and briefly misstates
// the default cap on disk). Worked example (room-parallel=1): with
// dashboard-improve-chief marked captain-initiated (exempt), the single
// chief-initiated slot is FREE - a chief-initiated promote fits with no
// --over-cap sanction. That is why ask-to-bypass is the exception, not the
// baseline. All THREE DECIDED: receipts are IN ADDITION to the existing
// PROMOTED: post, and all of them are written AFTER the meta - which fixes the
// meaning of a --roomchief exit status: non-zero means NO meta was written and
// the promote can be retried, while a failure in the post-meta bookkeeping tail
// (status line, PROMOTED:, DECIDED:) WARNS by name and still exits 0, because
// past the meta the chief exists and teardown owns it. An automatic caller
// (ac-learn.sh autoroom) retries on non-zero, so a tail failure reported as a
// failed promote would strand a real room behind a "retrying" message.
//
// claude spawns pin a session id (`--session-id`, recorded as session_id=
// in the meta). --resume-from <old-id> reopens that recorded claude session
// (`claude --resume`) - for same-stage revisions where the old context is
// worth keeping. Role changes and code-review never resume.
// claude keys sessions by their cwd, so a resume asks the pool for the old
// task's exact worktree slot back (worktree= from its meta, passed as
// ac-tree.sh get --prefer); when that slot cannot be honored the spawn still
// proceeds but warns loudly:
//   resume may not find the old session (cwd changed: <old> -> <new>)
// Non-resume spawns lease exactly as before (no --prefer).
//
// LEASES (the authoritative grammar): the crew meta records
//   leases=<path>[:<path>...]
// every pooled worktree the task holds, colon-separated - and ac-teardown.sh
// returns EACH one, not just the primary tree. A spawn takes exactly one lease,
// so the list normally has a single entry equal to worktree=; anything that
// leases a SECOND tree for the same task (a qa e2e companion checkout, taken
// by calling `bin/ac-tree.sh get --id <this task's id> ...` again) has its path
// appended here automatically - `ac-tree.sh get` itself does the append, the
// moment it sees state/<id>.meta already on disk - and that append is the whole
// mechanism by which teardown gives it back. The task's OWN first lease never
// triggers it: spawn/self-task write state/<id>.meta only after that first
// `get` returns, so the append is silently a no-op until the meta exists (also
// why a verifier's distinct id, which never gets a crew meta at all, never has
// one minted for it either). worktree= keeps its own meaning - the
// PRIMARY tree, the crewmate's cwd, which every other script resolves - and a
// meta written before leases= existed carries only worktree=, which teardown
// reads as a one-entry list (back-compat, no migration). Chief and crewdeputy
// metas hold no pool lease and carry no leases=.
// lease_ids=<id>[:<id>...] runs ALONGSIDE leases=, one entry per path in the
// same order: the per-acquisition identity teardown hands back as `ac-tree.sh
// return --if-lease-id`, so a late return refuses instead of resetting a slot
// that has since been re-leased. Absent (old meta, or a pool that predates the
// id) means teardown returns unconditionally, as it always did.
//
// THE LEASE INSTALL (the authoritative contract; the runner is leaseInstall,
// src/lib.ts): when the project's home yaml declares commands.install, a crew
// spawn runs it in the fresh lease (herdr or orca) right after the lease and
// before the seed and the window - a scout, which never builds, skips it. It
// is a synchronous child bounded by AC_LEASE_INSTALL_TIMEOUT (default 300 s),
// so a signal held through it acts once it returns. It never refuses the
// spawn: a non-zero exit, a timeout or a tree it left dirty is one WARN naming
// the cause, deps=failed in the meta and one DEPENDENCIES sentence in the
// kickoff prompt; a success is deps=ok; with no command declared nothing runs
// and no deps= is written.
//
// Requires an existing brief, resolved with ac_task_dir: flat data/<id>/brief.md
// for direct tasks, nested data/<family>/<stage>/brief.md for staged flows,
// nested data/<family>/tasks/<slug>/brief.md for a scoped chief's fan-out
// sub-tasks (ac-brief.sh scaffolds it; src/brief.ts's header owns the layout).
// On success prints:
//   spawned <id> harness=<h> kind=<ship|scout|crewdeputy> mode=<mode> yolo=<on|off> backend=<b> window=<target> worktree=<path>
//
// The backend comes from --backend, else config/backend, else herdr, and is
// recorded in the task meta so every later script drives the same backend.
// An explicit --base-branch is recorded too (lease_base=), absent otherwise,
// so ac-teardown.sh can prove a 0-commit crew/<family> branch merged into
// THAT base when the primary's own HEAD/upstream never covers it.
// When config/crew-dispatch.json exists, crew spawns REFUSE to guess the
// harness: pick a profile with ac-dispatch-select.sh (--list / --rule) and
// pass --harness/--model/--effort explicitly.
// Model and effort are fleet-wide defaults: absent --model/--effort fall back
// to config/model and config/effort (like config/crew-harness). --model maps to
// claude --model / codex -m / pi --model; the --effort FLAG is claude-only, but
// the effort VALUE also reaches codex (-c model_reasoning_effort=<e>) and pi
// (--thinking <e>, verified pi 0.84.2); opencode ignores it. Effort is validated against
// low|medium|high|xhigh|max|ultracode before anything is spawned.
// effort=ultracode is the claude preset: the launch line gets --effort xhigh and,
// once the built-in claude TUI is up, '/effort ultracode' is typed in to add the
// workflow-orchestration layer (claude built-in only; codex/opencode and custom
// launch-claude templates get no slash line). AC_ULTRACODE_SETTLE (default 2)
// is the pause after that line before the kickoff prompt.
// PER-ROLE knobs (captain's call): the two VERIFICATION panes get their own
// defaults - claude opus - decoupled from the fleet crewmate model. Delivery stays
// with the execution crewmate; there is no separate ship-stage model lane. The reviewer (ac-ship.sh review-agent,
// --kind codereview) and qa (ac-qa.sh agent) run as homeless panes, so ac-spawn
// resolves config/<role>-{agent,model,effort} HERE and threads them as
// AC_FLEET_{AGENT,MODEL,EFFORT}_{CODEREVIEW,QA} (only when set; else ac-pane-agent
// applies its own per-role defaults: claude for agent, opus for model, and the
// shared fleet ladder for effort). The three are ONE rung in the pane's ladder,
// so an agent pin and its model/effort are chosen together - never a model
// composed onto a harness a different rung picked.
// On the same rung, and above those two: AC_FLEET_PROFILE_CODEREVIEW /
// AC_FLEET_PROFILE_QA, the DISPATCHED pane profile from config/crew-dispatch.json's
// `panes` block (contract: the PANE PROFILE block in ac-pane-agent.sh; resolver:
// ac-backend.sh ac_pane_profile). ONE scalar per kind carrying the whole
// `harness=<h> model=<m> effort=<e>` triple rather than three variables, so the
// profile stays ATOMIC on the wire and the pane can honour an empty model as the
// harness's own default. Only these two kinds: ac-learn.sh's scout is homed and
// reads the block first-hand. Emitted only when a profile resolves, so a fleet
// with no `panes` block leaves this launch line byte-identical.
// codereview's rung has ONE extra knob, --codereview-rule <number|default>
// (routed-pane-rules-for-gate-codereview-roomchief,
// second round): a routed panes.codereview's rules[] is otherwise unreachable
// forever - an execution crewmate never gets AC_HOME (see the AC_HOME pin
// below) and every codereview call chain (ac-verify.sh, ac-ship.sh's
// review-agent) passes ac_pane_profile's resolved value straight through with
// no selector of its own - so THIS is the one and only place any agent is
// ever in a position to judge a `when` clause, and it judges ONCE for the
// crewmate's whole life, not per round. With no flag this rung is
// byte-identical to before (ac_pane_profile, no --rule). With the flag, a
// selector that fails to resolve DIES here before any window/meta is opened -
// never a silent fall-through to a default the caller did not ask for.
// The resolved model/effort ALSO ride the crewmate launch line as the scalars
// AC_FLEET_MODEL / AC_FLEET_EFFORT (raw value - ultracode stays ultracode; each
// consumer maps it for its own surface). A crewmate gets no AC_HOME, so the pane
// agents it later starts (ac-pane-agent.sh: the codereview reviewer, ac-qa.sh
// agent) cannot read config/ at all and used to judge on claude's own default
// while the fleet was pinned elsewhere (live 2026-07-15: an opus-pinned fleet
// reviewed on claude-fable-5). Narrow scalars carry exactly that knowledge and
// nothing more - handing over AC_HOME instead would give every crewmate the whole
// fleet home, which ac-qa.sh's "the path travels in the brief, not the environment"
// block and ac-pane-agent.sh's refusal to fabricate a home both exist to prevent.
// On the same rung and for the same reason: AC_FLEET_NAME, the fleet token every
// herdr workspace label is built from (ac-lib.sh ac_fleet_name). Homeless, that
// helper can only answer its fixed fallback, so every observation tab a crewmate
// opens - ship watch, qa watch, the pane agents - landed in the ONE group shared
// by every fleet on the box instead of its own. Resolved HERE where AC_HOME is
// valid and threaded as the NAME alone.
// Prefixed OUTSIDE spawnLaunch so a verbatim custom launch-<h> template passes
// them on too. SHARP EDGE: config/model is harness-specific in VALUE, so a fleet
// pinned to a codex model hands that name to a claude pane agent - the same
// pre-existing hazard as the config/model fallback inside ac-pane-agent.sh. THE
// CREW PATH HALF of this is now guarded (below, where the harness rung
// finally resolves): a config-fallback model that does not match the resolved
// harness is dropped rather than composed onto it. The ac-pane-agent.sh half
// is untouched and stays open.
// On the same rung, but a KILL-SWITCH rather than a pin: CODEGRAPH_NO_PROMPT_HOOK
// rides EVERY crew launch line (crewmate, roomchief, scout, crewdeputy). Its
// value never varies, so it is the constant CODEGRAPH_ENV. codegraph's global
// UserPromptSubmit front-load hook up-walks up to 6 levels for an index, so every
// fleet cwd under a container-wide index queries that whole graph; a roomchief
// kickoff mandate trips codegraph's structural gate and measured 161.72s against
// Claude Code's 30s hook budget (diagnosis 2026-07-21), while a crewmate prompt
// short-circuits at the gate in 0.08s. The var makes the hook a 0.07s no-op. It
// disarms the front-load NUDGE only - the codegraph_explore MCP tool a pane calls
// deliberately stays available - and is scoped to the panes this module launches,
// touching no global codegraph or claude config.
// Fleet-wide crewmate instructions ($AC_HOME/CREWMATE.md) are copied into the
// instruction file the RESOLVED harness actually loads - AGENTS.md for codex and
// opencode, .claude/CLAUDE.md for everything else - and the fleet harness settings
// into the worktree's .claude/settings.json and .claude/settings.local.json. A
// copy the repo ships itself wins for all; the instructions then land at
// .claude/CREWMATE.md, a path NO harness
// loads, so ac_seed_crewmate_md prints it and the KICKOFF PROMPT below names it
// as required reading - the only channel left to that crewmate. A copy the SEED
// itself wrote is REFRESHED when the sources move on, so a long-lived pool
// lease stops running its crewmate on the rules of whenever it was first leased
// (resolution ladders, the ownership stamp and its evidence: ac-lib.sh
// ac_seed_crewmate_md / ac_seed_install / ac_seed_crew_settings).
// Crewdeputies run with AC_HOME pointed at their seeded home
// ($AC_HOME/crewdeputies/<id>, see ac-home-seed.sh) and never lease a worktree.
//
// GUARDED CREWDEPUTY RECOVERY (--recover, requires --crewdeputy). AUTHORITATIVE
// for how a dead crewdeputy comes back. It exists as a flag here rather than a
// separate verb because the refusal it must relax lives here, and because
// recovery ENDS in an ordinary crewdeputy spawn: teardown-then-spawn cannot do
// the job, since crewdeputy teardown refuses while the deputy's home holds crew
// in flight - precisely when the deputy is most needed back. Recovery is never
// automatic (a digest may run read-only, and a false-dead reading would double-
// spawn a live deputy); it is one deliberate command that dies at the first
// failure of this ladder:
//   1. the id has a parseable routing-table entry - else there is nothing to
//      recover (ac-lib.sh owns the grammar);
//   2. its home exists and carries .ac-crewdeputy-home - else HOME-MISSING,
//      which is a captain decision (repair or remove the line), not a recovery;
//   3. any existing window is CONFIDENTLY not alive - a live pane is never
//      double-spawned;
//   4. a stale meta and its status log are RETIRED to their own slot under
//      state/archive/<id>/<stamp>/, never deleted, so the routed-order history
//      of EVERY earlier epoch stays readable (a deputy is recovered repeatedly);
//   5. control falls through to the ordinary crewdeputy spawn path.
// The deputy's OWN home is never touched: its crew keeps running, its worktrees
// keep their leases, its backlog and rooms survive, and the restored deputy
// reconciles them at its own session start. Recovery is not a teardown bypass.
//
// GUARDED CREWMATE/ROOMCHIEF RECOVERY (--recover on <id> <project>, or on
// --roomchief <family>). AUTHORITATIVE for how a task whose pane or tab was
// DESTROYED gets its pane back without losing anything: a herdr server exit,
// a tab closed by hand, a stranded tab reaped as an orphan. It widens the
// crewdeputy guard above rather than adding a verb, because the refusal it
// relaxes (the duplicate-meta die) lives here and the window is opened the
// ordinary spawn way. It dies at the first failure of this ladder:
//   1. a meta exists for the id - else there is nothing to recover;
//   2. backend_window_alive answers a DEFINITE gone (1) on the task's OWN
//      backend - ALIVE (0) keeps the duplicate-agent refusal, UNOBSERVABLE (2)
//      refuses naming the backend (WINDOW LIVENESS, bin/ac-backend.sh);
//   3. the meta records kind ship|scout|roomchief, an existing worktree, and a
//      claude session_id - a session that cannot be resumed is a teardown and
//      a fresh spawn with the branch/report as inputs, never a blind relaunch.
// On accept: the RECORDED worktree is reused (no new lease, no reset, no
// branch change, uncommitted work and the brief untouched), one fresh pane is
// opened in the family workspace at that cwd, the recorded session is resumed
// on a launch line carrying the same env the first launch did (crewLaunchEnv
// for a crewmate; AC_HOME/AC_SCOPE/domain/solo for a roomchief, which is also
// told to re-arm its family watcher), the came-up gate closes a pane whose
// resume fell back to a shell, and only then are the meta's `window` field and
// state/.pane-<id> rewritten and a `recovered:` line appended to the status
// log. The meta is never archived: it is the live task's record.
// Harness launch commands come from config/launch-<harness> when present
// (placeholders __BRIEF__ and __ID__ are substituted); otherwise a built-in
// template per harness is used.
//
// Kickoff-prompt delivery: built-in templates launch the harness BARE (no
// positional prompt arg) because a positional "$AC_PROMPT" does NOT auto-submit
// in an interactive claude TUI - it left the crewmate idle until a manual steer.
// Instead every path (crew/crewdeputy/roomchief) sends the launch line, waits
// AC_SPAWN_SETTLE seconds (default 8) for the harness to come up, then delivers
// the prompt as its OWN line via backend_send_line.
// The CAME-UP GATE sits between those two, and it is FAIL CLOSED. A harness can
// die at launch - a --resume-from whose session id claude did not recognise
// printed "No conversation found with session ID ..." and EXITED, dropping the
// pane back to zsh (live incident 2026-07-21) - and the kickoff prompt was then
// typed into that SHELL: `zsh: command not found: You...`, after which the dead
// pane sat silent until a stale wake minutes later. So deliverKickoff first
// asks backend_harness_up (its three states and their evidence are
// ac-backend.sh's contract) and, when the pane is back at a bare shell,
// withholds the kickoff prompt and kills the spawn with die - naming the
// pane's last lines, so the harness's own error travels with the failure. A
// built-in codex pane may already have taken the single pre-gate
// startup-dialog Enter before this point (contract: THE CODEX STARTUP-DIALOG
// ANSWER below); every other pane got no keystroke at all. The ordinary
// cleanup trap then reaps the window and returns the lease, leaving no
// half-spawned task, and the refusal is appended to state/<id>.status. The
// chief sees it AT SPAWN TIME and
// recovers now. An UNOBSERVABLE probe (2) is NOT a dead pane: it warns and
// delivers exactly as before - refusing there would ground the fleet on a herdr
// hiccup. Auto-recovery is deliberately not attempted; the required property is
// only "never type a kickoff into a shell, never sit silent on a dead pane".
// The gate runs TWICE, because it answers "was the harness up BEFORE I typed"
// and a harness can die ON the kickoff itself. The POST-KICKOFF RE-CHECK is the
// same probe, run again after the prompt is delivered, refusing the spawn the
// same fail-closed way (status `failed:`, die, trap reaps the window) and
// warning-only on an UNOBSERVABLE 2. It exists because a spawn once reported
// SUCCESS - and ac-crew-state.sh said `working: spawned` - over a codex that was
// already dead at a zsh prompt (live incident 2026-07-21, the codex-crewmate
// probe): the pre-kickoff gate saw a healthy pane because the death came after
// it, and backend_send_line's render-change probe read the kickoff as ACCEPTED
// because the render changed - by the app DYING. A render-change probe cannot
// tell "the composer took my line" from "the app I typed into exited"; only
// re-asking whether a harness still holds the pane can. What that refusal may
// CLAIM is bounded by what the probe saw - non-shell at the gate, all-shell
// after - so it reports the harness as no longer up and names the kickoff as the
// LIKELY cause, never as an established one: the probe cannot show the prompt
// was accepted, nor exclude an unrelated exit in the interval.
//
// THE CODEX STARTUP-DIALOG ANSWER (the authoritative contract). codex opens on a
// TRUST DIALOG before its composer exists ("Do you trust the contents of this
// directory?", options `1. Yes, continue` / `2. No, quit`), and that dialog is a
// key-driven SELECT: an `n` or a `2` ANYWHERE in typed text picks "No, quit" and
// codex exits ~0.4s later. Every English kickoff prompt carries an `n`, so at a
// BUILT-IN codex pane the prompt is never the first thing typed - deliverKickoff
// sends a bare Enter first, which takes the highlighted "1. Yes, continue", then
// settles AC_SPAWN_SETTLE again so the TUI can draw. That Enter goes BEFORE the
// came-up gate, deliberately: the EXISTING gate then covers the Enter's
// aftermath, so no third probe is needed and the invariant holds without new
// machinery - and an Enter typed into a pane whose harness never came up is a
// bare newline at a shell prompt, which is inert. A CUSTOM config/launch-codex
// template gets NO Enter: its TUI is unknown, so a keystroke borrowed from the
// built-in codex TUI is the caller's business - the same rule the '/effort
// ultracode' line already follows for a custom launch-claude. On a host
// where the dialog does NOT appear (trust already persisted) that Enter lands on
// an empty composer, where the fix probe reported it a no-op - a reading marked
// NOT REPLAYABLE in harness-facts.md, and one nothing here depends on: an Enter
// that DID end the harness is caught by the gate it now precedes. Two
// consequences the fleet
// owns: answering PERSISTS `[projects."<repo-root>"] trust_level = "trusted"`
// into the host's ~/.codex/config.toml (so the fleet auto-trusts the repo it
// spawned into - the same posture as claude's --permission-mode auto), and a
// green codex spawn on a host that already carries that entry proves nothing
// about a fresh one. `-c projects."<root>".trust_level="trusted"` was tried
// first and REFUTED: codex's trust gate does not consult -c in either direction
// (evidence: .agents/skills/harness-operations/references/harness-facts.md).
//
// THE COMPOSER-READY OBSERVATION (the authoritative contract). Between the
// came-up gate above and the FIRST thing typed after it (the '/effort
// ultracode' line, or the kickoff prompt itself) sits kickoffWaitInputReady,
// the id-scoped twin of ac-pane-agent.sh's crewmate_wait_input_ready (that
// function's COMPOSER-READY OBSERVATION comment is the sibling contract this
// one mirrors). It requires the SAME two signals together - agent_status=idle
// (arrives too early alone: repo-knowledge by spawn-cameup-render-readiness
// measured claude reading idle at ~340ms while the pane still showed the
// pre-launch shell frame) AND a non-empty render that stays byte-identical
// across three one-second reads (a render alone false-greens on codex's trust
// dialog, which holds a byte-stable non-blank frame for 18+ ticks - same
// repo-knowledge entry) - using the ID-SCOPED twins backend_agent_idle and
// backend_capture, never the _pane variants: this arm holds a
// state/.pane-<id> handle throughout, unlike ac-pane-agent.sh's raw-pane
// callers. The spawn arm carries no EXITMARK/CRCF (cross-arm warning,
// repo-knowledge by codereview-verifier-pane-dies-mid-turn-and-never-returns-
// a-verdict: those belong only to the crewmate ARM ac-pane-agent.sh runs, and
// this module never touches that file) - its own death signal is
// backend_harness_up, so the loop re-polls it every tick and fails the SAME
// way the came-up gate above does (status failed, die, the EXIT trap reaps
// the window) the instant it reads SHELL (1), rather than waiting out the
// whole readiness budget on a pane that already died. A budget expiring on
// UNOBSERVABLE (2) is NOT a death - the same direction the came-up gate above
// preserves - so it warns and proceeds exactly as an unobservable came-up
// probe does, never refuses. Only a budget expiring while the harness is
// CONFIRMED up (0) - alive, but its input surface never stabilised - fails
// loud: that is the one case this gate exists for, because typing into it
// blind is exactly the silent-green kickoff this function used to produce.
// AC_KICKOFF_READY_BUDGET (default 60 seconds, 1s ticks - the sibling's own
// budget) bounds the wait and is validated up-front like $settle, so a bad
// value fails fast before any window is opened.
// This gate REPLACES only the first of the blind sleep's two jobs (repo-
// knowledge trap, by spawn-cameup-render-readiness: composer readiness AND
// letting a launch-time death settle before the came-up gate reads the pane).
// The existing `sleep "$settle"` calls above are UNCHANGED and still do their
// own job of letting a death settle before the came-up gate probes the pane -
// this gate never touches that job, only adds a real observation where a
// blind sleep used to stand in for one.
// RESIDUAL, stated not solved (the same non-goal the came-up gate's codex
// trust-dialog false-green already lives with): a render-stability signal
// alone cannot distinguish a ready composer from a modal dialog holding the
// same frame - the built-in codex path is covered because its dialog Enter
// already precedes this gate (same ordering as the sibling arm), but a CUSTOM
// config/launch-<harness> template gets no such Enter and inherits the same
// false-green class the came-up gate already carries.
//
// Delivery is ACKNOWLEDGED,
// never blind (the 2026-07-16 eaten-kickoff incident: a booting TUI dropped the
// first Enter, the next send-text APPENDED to the stranded line and garbled
// both into one bad /effort argument): backend_send_line verifies its own
// submit (capture-change probe + one focused retry - contract: ac-backend.sh);
// when it still reports a strand the text already SITS in the composer, so the
// retry re-SUBMITS - never re-types - at most 2 more times, AC_SPAWN_SETTLE
// apart (a booting TUI drops Enter until it is up), then warns LOUDLY naming
// bin/ac-send.sh as the manual fallback. The spawn itself never hangs or dies
// on kickoff delivery. A stranded '/effort ultracode' line additionally
// WITHHOLDS the kickoff prompt (typing it would append to the strand and
// garble both) with the same loud fallback warning. AC_PROMPT is still
// exported on the launch line for custom templates that reference it, but
// built-ins no longer consume it.
//
// ORPHAN-WINDOW SAFETY (the authoritative contract). Between window-create and
// the FIRST byte of state/<id>.meta a task exists only as a tab - and ac-send.sh
// and ac-teardown.sh both key off that meta, so a spawn dying in that gap leaves
// a window NOTHING can address. The gap is real and at least AC_SPAWN_SETTLE
// seconds wide: the launch line goes out through backend_send_line, which
// genuinely returns 1 on a strand, and a failed launch line ends the run. Three
// guards close it:
//   1. an ATOMIC PRE-META CLAIM (spawnMetaClaimAcquire, one dir per id under
//      state/.meta-claims/), taken before every window CREATE and every REAP on
//      every path - both reapOrphanWindow call sites included - and released
//      the instant the meta is COMPLETE. That is the exact ordering invariant,
//      and it is narrower than "before any window call": the crewdeputy
//      --recover ladder probes window liveness earlier, which is a READ that
//      creates and reaps nothing. The crewmate/roomchief --recover block goes on
//      to CREATE, so it takes the claim before its probe - a second recover
//      then reads the first one's pane alive. It is what makes the pre-meta
//      window single-occupancy: a contender blocks in the acquire and then dies
//      on the duplicate-meta check INSIDE the claim, so it never reaches a reap.
//      A dead owner is reclaimed after a grace through the shared PID-aware
//      primitive, so a killed spawn never disarms the id permanently - but the
//      claim's recorded pid is THIS process, a descendant of whoever called it,
//      so a spawn outliving a SIGKILLed caller still holds it. That
//      case is precisely what guard 3 below cannot reason about on its own.
//   2. a cleanup trap armed AT window-create and disarmed the moment the meta is
//      COMPLETE - never later: past that point the task is addressable and
//      teardown owns it, whereas a still-armed trap would reap a healthy chief
//      over a failed room post. It removes the partial meta and REAPS the window.
//      The crew path's trap (which already returned the lease) now reaps its
//      window too, and only its own: before it creates one, $window is empty and
//      the window-collision refusal below is left to stand exactly as it was.
//   3. reap-on-collision, on the roomchief and crewdeputy paths. A trap cannot
//      fire on SIGKILL, so a killed spawn still strands a tab - one with NO
//      meta, which the crewmate/roomchief --recover (meta required) cannot
//      reach either.
//      Reaching those window checks PROVES no meta exists for this id (the
//      duplicate-meta refusal above dies on one) AND that this spawn holds the
//      claim, so no other spawn for the id is inside its pre-meta window: a live
//      window there is by construction an orphan of exactly this race and is
//      reaped and recreated instead of refused. That premise rests on guard 1
//      and on nothing else - with the claim neutered it is FALSE, measured 5/5:
//      the live window belongs to a CONCURRENT spawn, and reaping it closes the
//      pane that spawn is about to record as its own meta.window. The KILL
//      OWNERSHIP PROOF (authoritative:
//      bin/ac-backend.sh's header) still decides whether the tab actually closes:
//      a tab no longer labelled crew:<id> is a co-tenant, and is refused and
//      warned about, never closed.
//      ONE EXCEPTION: --crewdeputy --recover keeps the REFUSAL. That ladder
//      deliberately leaves state/.pane-<id> behind so this very check can still
//      catch a LIVE deputy its own probe could not answer for (step 3), where
//      reaping would close a living deputy's tab and double-spawn onto its home.
//   Both guards that REFUSE - that one and the crew path's collision check - read
//   the probe's THREE states (authoritative: WINDOW LIVENESS in
//   bin/ac-backend.sh), because only a DEFINITE gone may proceed. ALIVE refuses
//   as "already exists"; a backend that could not be READ refuses too, in its own
//   words naming the BACKEND, since nothing was learned about the pane and
//   proceeding would open a second window beside a possibly live one. Truthiness
//   alone read that as gone, which made the --recover refusal blind to exactly
//   the case it exists for. The hazard predates the three-state probe (a failing
//   probe used to return 1); that probe is only what made it NAMEABLE.
//
// THE BRANCH COLLISION REFUSAL (the authoritative contract). An id is the
// fleet's primary key across meta, status, room, backlog AND branch; the
// duplicate-meta checks validate four of those five, and the one they skip is
// the only one that carries CODE. ac-teardown.sh deletes a crew branch only when
// it is MERGED, so a dead or --force'd task leaves crew/<family> behind (live
// 2026-07-27: crew/learning held 160 commits of pre-scrub history while
// `learning` is the id ac-learn.sh autoroom spawns on its own) - and spawn used
// to take that id anyway, putting the next crewmate's commits on a foreign
// history and making its landing diff nonsense. So the CREW PATH refuses when
// crew/<family> resolves in $project_dir and no in-flight task owns it. Three
// properties, each load-bearing:
//   - It sits in the crew path, AFTER $project_dir resolves, not at either
//     duplicate-meta check: both of those run long before the project is
//     resolved, so neither can name the repo the ref would live in. The
//     roomchief and crewdeputy paths exit before it (neither leases a worktree
//     nor holds a crew branch), and familyOwned skips those kinds when it
//     judges ownership - a <fam>-chief id reads as <fam> once data/<fam>/chief
//     exists, so counting the chief would disarm this refusal for its own crew,
//     every --recover exits before it (a recovery leases nothing and keeps the
//     task's branch as it is), and no verify-* meta is written by this module
//     at all (ac-verify.sh owns those panes).
//   - OWNERSHIP is the FAMILY, never the id, because ac_crew_branch collapses
//     every stage/revision id in a family onto ONE branch (ac-lib.sh). A live
//     sibling means the branch is being worked: the fresh-execution-crewmate
//     recovery of the delivery-review skill continues that exact branch, and refusing
//     it would tell the operator to delete a ref holding live unlanded work.
//     Membership is familyOwned (src/lib.ts), using ac_family_of_id -
//     the same derivation the branch name itself comes from, so owner and
//     branch can never disagree. familyOwned lives in the shared library,
//     not here, because bin/ac-self-task.sh carries the SAME hazard (it also
//     commits on crew/<id> and lands via ac-merge-local.sh) and calls it too -
//     one predicate, not a second copy that could drift.
//   - The ref is NEVER touched: no auto-delete, no auto-rename, ever. The
//     refusal names the ref, its tip, and BOTH commands (rename to keep the
//     history, -D to drop it), because which one is right is the operator's
//     call and only they know whether those commits matter. It fires before any
//     window, lease or meta, so nothing is left half-spawned.
//
// EXIT: 0 spawned, promoted or recovered (strands and unobservable probes
// included); 1 every ERROR, a value flag missing its value (W14) and a
// redirection the run could not open; a child's own status where the original's
// errexit adopted it - the herdr lease (bin/ac-tree.sh get), jq's in window_new
// (W5 and the legacy-group sweep's pipeline), sleep's (W6), the unguarded status
// append (W1a), a stdout closed under the crew or crewdeputy outcome line (W1b),
// sed's or cut's in the roomchief announce (W9), the skills seed's mkdir, ln or
// exclude append, a usage count bash's arithmetic refused; 143, 129 and 130 when
// TERM, HUP or INT ends the run (see SIGNALS).
// THE CLEANUP TRAP is the original's EXIT trap carried over: one cleanup per
// phase - the pre-meta claim from the moment it is taken, then (chief paths)
// the partial meta, the window and the claim from window-create, or (crew path)
// the lease, the partial meta, the window once opened and the claim from the
// lease - run at every exit while armed, and disarmed the moment the meta is
// complete. SIGNALS: TERM, HUP and INT are handled; each runs the armed cleanup
// and exits 128+n. The long waits (the settles, the claim's and the ready
// loop's ticks, the ultracode pause) are awaited, so a signal acts at once
// there; inside a child the original ran in `$(...)` (the herdr lease, the
// orca lease) the signal waits for the child to return, as the original's
// deferral did (W2). Every other child is synchronous, so the run also turns
// the loop once at each phase's edge - before the lease, before the crew
// path's status line, before each path's disarm, and before a recovery
// records its window - and a signal held through such a child acts there,
// under the cleanup the original would have run.
//
// ESCAPE HATCH. A broken port stops every crewmate spawn and roomchief promote
// on both fleets, crewdeputy spawns and every --recover, and the Learning
// autoroom - not the solo session's own write path (bin/ac-self-task.sh spawns
// nothing through it). If a landed change breaks this module, run the frozen
// original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   ln -s "$PWD/.agents" "$o/.agents"; cp tests/fixtures/ac-spawn.sh "$o/bin/ac-spawn.sh"
// then the chief runs AC_HOME=<home> "$o/bin/ac-spawn.sh" <args>. The copy bakes
// nothing of its own path into the pane (the prompts name bin/... relative to
// the home, the brief and the kickoff by data path), its siblings are the copy's
// shims over the live src/, and it writes the same meta, status and handle
// formats, so a task spawned by either side is torn down, recovered and
// supervised by the other. One path of the copy does land in a crew worktree:
// a built-in skill the container's .claude/skills lacks is linked from
// <copy>/.agents/skills (without that link it is not seeded at all), so keep
// the copy until those tasks are torn down. The Learning autoroom reaches the copy only when
// ac-learn.sh runs from it - its hatch is a by-hand `--roomchief learning
// --system-initiated <ref>` from the copy. The captain's revert of the land is
// the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1: the crew path's post-meta tail is not total - a status log the append
//   cannot write ends the spawn 1 with the cleanup still armed (the meta
//   removed, the lease returned, the live tab closed), and a closed stdout ends
//   it 1 after the meta is durable; the crewdeputy outcome line the same.
// - W2: the herdr lease is taken before its cleanup is armed - a signal inside
//   the lease leaves the slot leased with no meta, the claim released (one
//   before the lease ends the run with nothing leased, as the original did).
// - W3: an untrappable death strands the claim, the lease, the tab and the
//   handle; a re-spawn of the id leases another slot and refuses on the window.
// - W5: window_new ends the run with jq's status after the tab exists and
//   before its handle; the legacy-group sweep's pipeline ends it with herdr's
//   list status or jq's before any tab.
// - W6: AC_SPAWN_SETTLE=. passes the grammar and sleep refuses it after the
//   window and the launch line.
// - W7: an unreadable chief meta is warned and not counted toward the cap.
// - W8: a retired <home>/config/projects/<name>.yaml is swallowed - the launch
//   line carries AC_FLEET_HOME_CHECKED=1 and no AC_FLEET_PROJECT_CONFIG.
// - W9: the roomchief announce's sed or cut aborting on an invalid byte under
//   a UTF-8 locale ends a promote non-zero after its meta.
// - W11: a custom launch template starting with an env assignment is refused
//   `harness binary not found: NAME=value`.
// - W12: --resume-from forces claude over --harness; --mode and --resume-from
//   are accepted on the chief paths; --recover ignores --harness/--model/
//   --effort; a recovery dying between window_new and the meta leaves its pane;
//   a scout recovered without --scout meets the execution brief's Review gate.
// - W15: a failing pane profile (panes.codereview/qa) is dropped from the
//   launch line, the spawn going on.
// - The seed: a repo without .git/info makes ac_seed_install answer 1 after
//   installing (the fallback installed too, nothing named), the skills seed
//   ends the run on a failed exclude append, mkdir or ln, and a learned skill's
//   `seeded_count=0[89]...` ends it 1 (bash 3.2's arithmetic error).
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN: every path needs bun now (the shim's `ERROR: required tool not found:
//   bun`, exit 1, before anything), where a herdr spawn reached its lease and an
//   orca spawn ran whole without it.
// - SIGNALS: INT to the pid alone runs the cleanup and exits 130, where the
//   original swallowed it while a foreground child ran and completed (W4); a
//   TERM or HUP during a synchronous child other than the leases (a herdr RPC,
//   a room post, a dispatch-select) acts at the run's next wait - a settle, a
//   tick, a phase-edge turn (SIGNALS above) - so the run may go on past that
//   child to the end of its phase (a whole recovery notice where the original
//   left it unsubmitted, the kickoff file and pointer, the crew status line and
//   START post) and run that phase's cleanup, where the original acted at once
//   (inside `$(...)`, as the child returned). One after the disarm (the
//   bookkeeping tail and the outcome line) is not acted on: the run completes
//   with its own status, where the original ended 128+n there, the task whole
//   either way.
// - W10: AC_SCOPE's grammar (the fleet_scope, AC_FLEET_SCOPE, the domain
//   binding, the window family) is read per its text, [A-Za-z0-9_-] under any
//   locale, where bash 3.2's ranges admitted an accented letter under UTF-8.
// - W13: AC_SPAWN_META_CLAIM_TIMEOUT, AC_SPAWN_META_CLAIM_STALE_GRACE and
//   AC_STARTUP_DIALOG_BUDGET stay unvalidated with the original's outcomes,
//   without `[`'s `integer expression expected` lines.
// - W14 and SHELL-OWN STDERR are not reproduced, the status kept: a value flag
//   missing its value exits 1 silently (`$2: unbound variable`), and a
//   redirection the run cannot open (an unwritable handle, kickoff or status
//   file) exits with the status alone.
// - The ledger awk's own `can't open file` lines (the domain binding's read, the
//   epic fence's) are not reproduced, the refusal and its exit 1 are: the
//   doneline parser runs in this process.
// - EXCLUSIVE TEMP: the port-slot registry's temp is created exclusively (the
//   lib twin), where the original wrote through a planted `.tmp.$$`.
// - LEASE INSTALL: a declared commands.install runs in the lease (THE LEASE
//   INSTALL above), where the original installed nothing; with none declared
//   the spawn is the original's.
// - HOME RESOLUTION: an AC_HOME cd cannot enter is
//   `ERROR: AC_HOME is not a readable directory: <h>`.
// - BYTES: argv, the environment and every value read from a brief, a meta, a
//   room, a ledger or a child arrive decoded - a byte that is no UTF-8 reaches
//   the launch line, the prompts, the metas and the output as U+FFFD, and a
//   `printf %q` spelling that splits a UTF-8 sequence crosses the argv boundary
//   decoded.
// - The pre-meta claim's pid file holds this process's pid, where the original
//   asked a `sh` child for its parent; both name the process holding the claim.
// - The original's helpers whose stderr a caller dropped (the kickoff wake's
//   date and mkdir) keep it here.
// - A launch template's first word that only a shell function answers (the
//   original's own, its libraries', or one imported from the environment) is
//   refused `harness binary not found`; the launch check knows bash 3.2's
//   reserved words and builtins, then PATH.
//
// CALLERS: the chiefs by hand (crewchief, roomchiefs, domainchiefs, solo chiefs,
// a deputy's own chief - the task-lifecycle, rooms-threads, brainstorm,
// solo-session, deputies-domains, stuck-crewmate-recovery and staged-gates
// skills) reading the `spawned`/`recovered` line and the status; bin/ac-learn.sh
// autoroom (`--roomchief learning --system-initiated <ref>` inside an `if`, a
// non-zero read softly). What it writes is read by bin/ac-watch.sh,
// src/teardown.ts, ac-send, ac-peek, ac-crew-state, ac-relocate, ac-wake-drain,
// the fleet views, the guards, ac-self-task (family ownership) and the
// dashboard (state/<id>.meta, its status, state/.pane-<id>, the claims, the wake
// spool, kickoff.md, the room posts); the launch-line env is read crewmate-side
// by ac-ship, ac-pane-agent, ac-done, ac-qa, ac-primary-guard and
// ac-sessionstart-nudge.

import { accessSync, appendFileSync, constants as fsc, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename as pathBase, dirname } from "node:path";
import { acDoneline, records } from "./backlog.ts";
import {
  STARTED_BIN,
  arithValue,
  arrivalWait,
  backendAgentIdle,
  backendCall,
  backendDialogAnswer,
  backendKillWindow,
  backendName,
  backendStartupDialogs,
  backendSubmitVerified,
  backendWindowNew,
  buildLaunch,
  claudeConfigEnv,
  commandV,
  compactPctEnv,
  configDir,
  configReadSoft,
  crewBranch,
  dataDir,
  deputyParse,
  deputyRegistry,
  die,
  domainBinding,
  domainParse,
  domainViewEntry,
  enterCaller,
  envHome,
  epicBaseFor,
  familyOfId,
  familyOwned,
  fileMtime,
  fleetName,
  harnessKnown,
  harnessStartupKey,
  iso,
  leaseInstall,
  ledgerRead,
  metaGet,
  metaSet,
  nowRaw,
  orcaWorktreeLease,
  orcaWorktreeRelease,
  paneProfile,
  pidAlive,
  projectConfigFile,
  projectDir,
  recordLaunchOpts,
  recordsDir,
  resolveProfile,
  seedCrewSettings,
  seedCrewSkills,
  seedCrewmateMd,
  seedPortsEnv,
  shellQuote,
  shellStatus,
  spawnShell,
  spawnShellSync,
  stateDir,
  statusAppend,
  tabFields,
  taskBackend,
  taskDir,
  taskStatus,
  testInt,
  vnTs,
  wakePublish,
  wakeScopeOk,
  warn,
  writeAll,
} from "./lib.ts";

// Decoded strings throughout; the lib's byte (latin1) answers cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
// `$(...)`: NULs dropped, trailing newlines cut.
const cap = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");
const q = (s: string): string => u8(shellQuote(b8(s)));
const basename = (p: string, suffix = ""): string => {
  let b = pathBase(p);
  if (suffix !== "" && b !== suffix && b.endsWith(suffix)) b = b.slice(0, -suffix.length);
  return b;
};
const stat = (p: string, follow = true) => {
  try {
    return follow ? statSync(p) : lstatSync(p);
  } catch {
    return null;
  }
};
const isFile = (p: string): boolean => stat(p)?.isFile() ?? false;
const isDir = (p: string): boolean => stat(p)?.isDirectory() ?? false;
// `cat <f> 2>/dev/null || true` as `$(...)` read it.
const readCap = (p: string): string => {
  try {
    return cap(readFileSync(p).toString("utf8"));
  } catch {
    return "";
  }
};
// `cd -P <p> && pwd -P`, null when cd cannot enter.
const cdP = (p: string): string | null => {
  const here = process.cwd();
  try {
    process.chdir(p);
    return process.cwd();
  } catch {
    return null;
  } finally {
    process.chdir(here);
  }
};

type Exit = { exit: number };
const fatal = (status: number): never => {
  throw { exit: status } as Exit;
};
// errexit: a failed command ends the run with its status.
const ee = (status: number): void => {
  if (status !== 0) fatal(status);
};

type Io = "inherit" | "ignore" | "pipe";
type Ran = { status: number; out: string; raw: Buffer };
function run(argv: string[], o: { stdin?: "inherit" | "ignore" | Buffer; stdout?: Io; stderr?: "inherit" | "ignore"; cwd?: string } = {}): Ran {
  const stdout = o.stdout ?? "pipe";
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(argv, { stdin: o.stdin ?? "inherit", stdout, stderr: o.stderr ?? "inherit", ...(o.cwd === undefined ? {} : { cwd: o.cwd }) });
  } catch {}
  const raw = r && stdout === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0);
  return { status: shellStatus(r), out: raw.toString("utf8"), raw };
}
const rmF = (p: string): number => run(["rm", "-f", p], { stdout: "inherit" }).status;
// A wait the original's EXIT trap interrupted at once: awaited, so a TERM, HUP
// or INT handler runs while it waits. PATH's sleep, as the original ran it.
async function sleepFor(secs: string): Promise<number> {
  let p: ReturnType<typeof spawnShell>;
  try {
    p = spawnShell(["sleep", secs], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  } catch {
    return 127;
  }
  await p.exited;
  return shellStatus(p);
}
// One line on a stream the run must not fail on; false when it could not land.
const put = (fd: number, s: string): boolean => {
  try {
    writeAll(fd, Buffer.from(s, "utf8"));
    return true;
  } catch {
    return false;
  }
};
// `printf ... >&2` bare under errexit.
const tell = (s: string): void => {
  if (!put(2, s)) fatal(1);
};
const dieWith = (e: unknown): never => die((e as Error).message);

// The run's state, which the cleanup trap reads at exit.
const S = {
  id: "",
  meta: "",
  claimRoot: "",
  claim: "",
  claimHeld: false,
  claimOwner: "",
  // Empty until THIS spawn has opened its window - which is what lets the
  // cleanups reap only a window they created (ORPHAN-WINDOW SAFETY above).
  window: "",
  backend: "",
  worktree: "",
  trap: null as null | (() => void),
};
let binDir = "";
let settle = "8";
let ultracodeSettle = "2";
let readyBudget = "60";
let ultracode = false;
let resumeSid = "";
let launch = "";
let unverifiedWaked = false;

function metaSetHard(file: string, key: string, value: string): void {
  try {
    metaSet(file, key, b8(value));
  } catch (e) {
    fatal((e as { status?: number }).status ?? 1);
  }
}
// `x="$(ac_meta_get ...)"` bare: an unreadable meta (warned) ends the run.
function metaGetHard(file: string, key: string): string {
  try {
    return u8(metaGet(file, key));
  } catch {
    return fatal(1);
  }
}
const metaGetSoft = (file: string, key: string): string => {
  try {
    return u8(metaGet(file, key));
  } catch {
    return "";
  }
};
// ac_status_append bare under errexit: a date that failed or a primary
// append that did not land ends the run there.
function statusHard(id: string, line: string): void {
  let ok = false;
  try {
    ok = statusAppend(id, b8(line), true);
  } catch (e) {
    fatal((e as { status?: number }).status ?? 1);
  }
  if (!ok) fatal(1);
}
const statusSoft = (id: string, line: string): boolean => {
  try {
    return statusAppend(id, b8(line));
  } catch {
    return false;
  }
};
const taskDirOrDie = (id: string): string => {
  try {
    return taskDir(id);
  } catch (e) {
    return dieWith(e);
  }
};

// --- the backend verbs, as the original's top-level calls ran them ---------
const IO = { stdin: "inherit", stdout: "inherit", stderr: "inherit" } as const;
type Fn = Parameters<typeof backendCall>[0];
function bc(fn: Fn, args: string[], io: Parameters<typeof backendCall>[2] = IO): ReturnType<typeof backendCall> {
  const r = backendCall(fn, args, io);
  if (r.exited) fatal(r.status);
  return r;
}
const ended = (r: { status: number; exited: boolean }): number => (r.exited ? fatal(r.status) : r.status);
const target = (id: string): string => cap(bc("target", [id], { ...IO, stdout: "pipe" }).out.toString("utf8"));
const capture = (id: string, n: string, stderr: "inherit" | "ignore" = "inherit"): string => cap(bc("capture", [id, n], { stdin: "inherit", stdout: "pipe", stderr }).out.toString("utf8"));
const alive = (id: string): number => bc("window_alive", [id]).status;
const harnessUp = (id: string): number => bc("harness_up", [id]).status;
// `[AC_SEND_UNPROVEN=1] backend_send_line <id> <text>`.
function sendLine(id: string, text: string, unproven = false): number {
  const saved = process.env.AC_SEND_UNPROVEN;
  if (unproven) process.env.AC_SEND_UNPROVEN = "1";
  try {
    return bc("send_line", [id, text]).status;
  } finally {
    if (unproven) {
      if (saved === undefined) delete process.env.AC_SEND_UNPROVEN;
      else process.env.AC_SEND_UNPROVEN = saved;
    }
  }
}
const killWindow = (id: string): void => void ended(backendKillWindow(id));

// `command -v <first word of the launch>` under bash 3.2: a reserved word or a
// builtin answers before the PATH search (`compgen -k`, `enable -a` of
// /bin/bash 3.2.57), so a template may start `exec <harness>`.
const BASH_WORDS = new Set(
  ("if then else elif fi case esac for select while until do done in function time { } ! [[ ]] " +
    ". : [ alias bg bind break builtin caller cd command compgen complete continue declare dirs disown " +
    "echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout " +
    "popd printf pushd pwd read readonly return set shift shopt source suspend test times trap true type " +
    "typeset ulimit umask unalias unset wait").split(" "),
);
function launchable(name: string): boolean {
  if (!name.includes("/")) return BASH_WORDS.has(name) || commandV(name);
  try {
    accessSync(name, fsc.X_OK);
    return !isDir(name);
  } catch {
    return false;
  }
}

// --- the pre-meta claim ------------------------------------------------------

function claimRelease(): void {
  if (!S.claimHeld) return;
  const owner = readCap(`${S.claim}/pid`);
  if (owner !== "" && owner !== S.claimOwner) return;
  try {
    rmSync(S.claim, { recursive: true, force: true });
  } catch {}
  S.claimHeld = false;
}

// The duplicate-meta check alone cannot serialize the pre-meta window: two
// callers can both pass it, and the later one can reap the first caller's
// not-yet-addressable pane. Claim the id before any orphan-window action and
// hold it until the complete meta is durable; a dead owner is reclaimed past
// the grace.
async function spawnMetaClaimAcquire(recover: boolean): Promise<void> {
  const timeout = testInt(process.env.AC_SPAWN_META_CLAIM_TIMEOUT || "30");
  const grace = testInt(process.env.AC_SPAWN_META_CLAIM_STALE_GRACE || "15");
  ee(run(["mkdir", "-p", S.claimRoot], { stdout: "inherit" }).status);
  S.claimOwner = String(process.pid);
  let waited = 0n;
  for (;;) {
    try {
      mkdirSync(S.claim);
      break;
    } catch {}
    const owner = readCap(`${S.claim}/pid`);
    const mtime = fileMtime(S.claim) ?? "";
    let stale = false;
    if (/^[0-9]+$/.test(mtime) && grace !== null) {
      let age: bigint;
      try {
        age = arithValue(nowRaw()) - arithValue(mtime);
      } catch {
        return fatal(1);
      }
      // A pre-meta spawn can legitimately spend several seconds booting its
      // harness: never reclaim inside that publish window.
      if (age >= grace) stale = !(owner !== "" && pidAlive(owner));
    }
    if (stale) {
      try {
        rmSync(S.claim, { recursive: true, force: true });
      } catch {}
      if (!isDir(S.claim)) continue;
    }
    if (timeout !== null && waited >= timeout) die(`another spawn still owns the pre-meta claim for ${S.id}`);
    ee(await sleepFor("1"));
    waited++;
  }
  try {
    writeFileSync(`${S.claim}/pid`, `${S.claimOwner}\n`);
  } catch {
    fatal(1);
  }
  S.claimHeld = true;
  // A recovery claims an id whose meta is the very thing it recovers.
  if (!recover && existsSync(S.meta)) {
    claimRelease();
    die(`crewmate ${S.id} already exists (see ${S.meta}); tear it down first`);
  }
}

// --- the launch line ---------------------------------------------------------

// The codegraph front-load prompt-hook kill-switch, on every crew launch line
// (contract: the CODEGRAPH_NO_PROMPT_HOOK block above).
const CODEGRAPH_ENV = "CODEGRAPH_NO_PROMPT_HOOK=1 ";

// The AC_PROMPT= prefix, ONLY when a custom config/launch-<h> template exists:
// built-ins never consume it, and a %q-escaped prompt past a fresh shell's
// canonical buffer beheads the actual command.
const launchPromptEnv = (h: string, prompt: string): string => (isFile(`${configDir()}/launch-${h}`) ? `AC_PROMPT=${q(prompt)} ` : "");

// The claude session id a launch line pins (--session-id) or resumes
// (--resume), as the original's sed read it, and sed's status.
function launchSessionId(line: string): { status: number; out: string } {
  const r = run(["sed", "-n", "-e", "s/.*--session-id \\([0-9a-f-]\\{8,\\}\\).*/\\1/p", "-e", "s/.*--resume \\([0-9a-f-]\\{8,\\}\\).*/\\1/p"], { stdin: Buffer.from(`${line}\n`, "utf8") });
  const nl = r.out.indexOf("\n");
  return { status: r.status, out: cap(nl < 0 ? r.out : r.out.slice(0, nl)) };
}

// A random RFC 4122 v4 id for a host without uuidgen, from od's 16 bytes.
function uuidV4(): string {
  const h = run(["od", "-An", "-N16", "-tx1", "/dev/urandom"]).out.replace(/[ \n]/g, "");
  const v = (parseInt(h.slice(16, 17), 16) & 3) | 8;
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${v.toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}\n`;
}

// THIS spawn's launch command: a resume rides ac_build_launch; a custom
// config/launch-<h> template is emitted verbatim with __BRIEF__/__ID__
// substituted by sed (its own status never read); otherwise the built-in,
// claude pinning a fresh session id from uuidgen (od when it fails).
function spawnLaunch(h: string, model: string, effortFlag: string, brief: string, id: string): { status: number; out: string } {
  if (h === "claude" && resumeSid !== "") {
    const l = buildLaunch(h, model, effortFlag, resumeSid);
    return l === null ? { status: 1, out: "" } : { status: 0, out: l };
  }
  const lf = `${configDir()}/launch-${h}`;
  if (isFile(lf)) return { status: 0, out: cap(run(["sed", "-e", `s|__BRIEF__|${brief}|g`, "-e", `s|__ID__|${id}|g`, lf]).out) };
  let sid = "";
  if (h === "claude") {
    const g = run(["uuidgen"], { stderr: "ignore" });
    sid = cap((g.out + (g.status === 0 ? "" : uuidV4())).replace(/[A-Z]/g, (c) => c.toLowerCase()));
  }
  const l = buildLaunch(h, model, effortFlag, "", sid);
  return l === null ? { status: 1, out: "" } : { status: 0, out: l };
}

type CrewEnv = { id: string; review: string; model: string; effort: string; projectDir: string; rule: string; ruleSet: boolean };
// The env prefix of a CREWMATE launch line (the AC_FLEET_* contract above):
// one composer for the ordinary crew launch AND a --recover resume.
function crewLaunchEnv(c: CrewEnv): string {
  let e = "";
  if (c.id !== "") e = `AC_CREW_ID=${q(c.id)} `;
  if (c.review !== "-") e += `AC_FLEET_REVIEW=${q(c.review)} `;
  if (c.model !== "") e += `AC_FLEET_MODEL=${q(c.model)} `;
  if (c.effort !== "") e += `AC_FLEET_EFFORT=${q(c.effort)} `;
  e += "AC_FLEET_HOME_CHECKED=1 ";
  const cfg = projectConfigFile(c.projectDir, true);
  if (cfg !== null) e += `AC_FLEET_PROJECT_CONFIG=${q(u8(cfg))} `;
  for (const role of ["codereview", "qa"])
    for (const knob of ["agent", "model", "effort"]) {
      const kv = configReadSoft(`${role}-${knob}`, "");
      if (kv !== "") e += `AC_FLEET_${knob.toUpperCase()}_${role.toUpperCase()}=${q(kv)} `;
    }
  for (const kind of ["codereview", "qa"]) {
    let prof: string;
    if (kind === "codereview" && c.ruleSet) {
      const r = run([`${binDir}/ac-dispatch-select.sh`, "--pane", "codereview", "--rule", c.rule], { stderr: "ignore" });
      prof = cap(r.out);
      if (r.status !== 0 || prof === "") die(`--codereview-rule ${c.rule} did not resolve a profile (see bin/ac-dispatch-select.sh --pane codereview --rule ${c.rule})`);
    } else prof = u8(paneProfile(kind).out);
    if (prof !== "") e += `AC_FLEET_PROFILE_${kind.toUpperCase()}=${q(prof)} `;
  }
  e += `AC_FLEET_STATE=${q(stateDir())} `;
  e += `AC_FLEET_NAME=${q(fleetName())} `;
  const scope = process.env.AC_SCOPE ?? "";
  if (wakeScopeOk(scope)) e += `AC_FLEET_SCOPE=${q(scope)} `;
  e += `AGENTMEMORY_PROJECT_NAME=${q(basename(c.projectDir))} `;
  return e;
}

// --- the kickoff ---------------------------------------------------------------

// Deliver one kickoff line with a positive acknowledgement: a strand leaves
// the text in the composer, so the bounded retry re-SUBMITS - never re-types -
// at most twice, a settle apart (errexit asleep: the settle's status is unread).
async function kickoffAcked(id: string, text: string): Promise<boolean> {
  if (sendLine(id, text) === 0) return true;
  for (let t = 0; t < 2; t++) {
    await sleepFor(settle);
    if (ended(backendSubmitVerified(id, text, { stderr: "inherit" })) === 0) return true;
  }
  return false;
}

// The DURABLE half of a fail-open delivery: the status line with its own
// reason (best-effort), and ONE kickoff-unverified wake per spawn.
function kickoffUnverified(id: string, what: string): void {
  statusSoft(id, `warn: kickoff ${what} - delivery unverified; peek (bin/ac-peek.sh ${id}) and resubmit with bin/ac-send.sh ${id} --key Enter if the pane sits idle`);
  if (unverifiedWaked) return;
  unverifiedWaked = true;
  try {
    wakePublish(stateDir(), process.env.AC_SCOPE ?? "", "kickoff-unverified", b8(id), b8(`kickoff ${what} - delivery unverified`));
  } catch {}
}

// ARRIVAL beyond kickoffAcked's submit-only evidence: claude's transcript, the
// pinned session's last typed turn; every other harness unverifiable.
function kickoffArrivalCheck(id: string, h: string, sid: string, expected: string): void {
  if (h !== "claude") {
    kickoffUnverified(id, `arrival unverifiable (${h} writes no session transcript this fleet can read)`);
    return;
  }
  const arc = arrivalWait(b8(sid), expected).status;
  if (arc === 0) return;
  if (arc === 1) {
    warn(`the kickoff prompt ARRIVED WRONG at ${target(id)} - the session transcript's last typed turn does not match what was sent (peek it: bin/ac-peek.sh ${id})`);
    kickoffUnverified(id, "arrived wrong (the session transcript's last typed turn does not match what was sent)");
  } else kickoffUnverified(id, "arrival unverifiable (no session id, no resolvable transcript, or the transcript wrote no typed turn yet)");
}

// THE COMPOSER-READY OBSERVATION (above): idle AND a non-blank 40-line render
// byte-identical three reads in a row, the harness re-probed every tick.
async function kickoffWaitInputReady(id: string, h: string): Promise<void> {
  const budget = testInt(readyBudget);
  let same = 0;
  let render = "";
  for (let waited = 0n; ; waited++) {
    ended(backendDialogAnswer(id, { stderr: "ignore" }));
    const up = harnessUp(id);
    if (up === 1) {
      statusHard(id, `failed: ${h} NO LONGER UP while waiting for its input surface to become ready - kickoff withheld, spawn refused`);
      die(`${h} is NO LONGER UP in ${target(id)} while waiting for its input surface to become ready: nothing was typed after the launch line, and the spawn is REFUSED - nothing is in flight. Last lines of the pane:\n${capture(id, "15")}`);
    }
    if (up === 0 && ended(backendAgentIdle(id, { stderr: "inherit" })) === 0) {
      const next = capture(id, "40", "ignore");
      if (next.replace(/[ \t\n\v\f\r]/g, "") !== "") {
        if (next === render) same++;
        else {
          render = next;
          same = 1;
        }
        if (same >= 3) return;
      } else {
        render = "";
        same = 0;
      }
    } else {
      render = "";
      same = 0;
    }
    if (budget !== null && waited >= budget) {
      if (up === 2) {
        warn(`could not read ${target(id)} to verify ${h}'s input surface became ready - delivering the kickoff anyway (peek it: bin/ac-peek.sh ${id})`);
        kickoffUnverified(id, "input-surface readiness unverifiable (backend unreadable)");
        return;
      }
      statusHard(id, `failed: ${h}'s input surface never became ready - kickoff withheld, spawn refused`);
      die(`${h}'s input surface did NOT become ready in ${target(id)} within ${readyBudget}s: nothing was typed after the launch line, and the spawn is REFUSED - nothing is in flight. Last lines of the pane:\n${capture(id, "15")}`);
    }
    ee(await sleepFor("1"));
  }
}

// The kickoff sequence on every path (above): settle, the built-in harness's
// startup dialogs, the came-up gate, the composer-ready observation, the
// ultracode line, the kickoff file and its pointer, the arrival check and the
// post-kickoff re-check.
async function deliverKickoff(id: string, h: string, prompt: string): Promise<void> {
  unverifiedWaked = false;
  ee(await sleepFor(settle));
  if (!isFile(`${configDir()}/launch-${h}`)) {
    ended(backendStartupDialogs(id, h, { stderr: "inherit" }));
    if (harnessStartupKey(h) !== "") ee(await sleepFor(settle));
  }
  let up = harnessUp(id);
  if (up === 1) {
    statusHard(id, `failed: ${h} did not come up at launch - kickoff withheld, spawn refused`);
    die(`${h} did NOT come up in ${target(id)}: the pane fell back to a bare shell, so the kickoff prompt is WITHHELD and the spawn is REFUSED - nothing is in flight, spawn again once the launch is fixed (a --resume-from carrying a session id the harness does not know is the recorded cause). Last lines of the pane:\n${capture(id, "15")}`);
  } else if (up === 2) {
    warn(`could not read ${target(id)} to verify ${h} came up - delivering the kickoff anyway (peek it: bin/ac-peek.sh ${id})`);
    kickoffUnverified(id, "came-up unverifiable (backend unreadable)");
  }
  await kickoffWaitInputReady(id, h);
  if (ultracode && h === "claude" && (resumeSid !== "" || !isFile(`${configDir()}/launch-claude`))) {
    if (!(await kickoffAcked(id, "/effort ultracode"))) {
      tell(`WARNING: '/effort ultracode' NOT acknowledged by ${target(id)} - kickoff prompt WITHHELD (typing it now would append to the stranded line and garble both); peek (bin/ac-peek.sh ${id}), resubmit with bin/ac-send.sh ${id} --key Enter, then deliver the brief prompt via bin/ac-send.sh ${id}\n`);
      return;
    }
    ee(await sleepFor(ultracodeSettle));
  }
  // FILE-DELIVERED KICKOFF: the full prompt lands on disk and the pane gets a
  // short pointer - a typed multi-KB prompt lost its head in transit.
  const kfile = `${taskDirOrDie(id)}/kickoff.md`;
  ee(run(["mkdir", "-p", dirname(kfile)], { stdout: "inherit" }).status);
  try {
    writeFileSync(kfile, `${prompt}\n`);
  } catch {
    fatal(1);
  }
  const pointer = `Read and follow your kickoff order at ${kfile} NOW - it is this session's contract. Start by reading that file in full.`;
  if (await kickoffAcked(id, pointer)) kickoffArrivalCheck(id, h, launchSessionId(launch).out, pointer);
  else {
    tell(`WARNING: kickoff pointer NOT acknowledged by ${target(id)} - it may sit unsubmitted in the composer; peek (bin/ac-peek.sh ${id}), then resubmit manually with bin/ac-send.sh ${id} --key Enter (the kickoff itself is durable at ${kfile})\n`);
    kickoffUnverified(id, "pointer not acknowledged (may sit unsubmitted in the composer)");
  }
  up = harnessUp(id);
  if (up === 1) {
    statusHard(id, `failed: ${h} NO LONGER UP after the kickoff attempt - spawn refused`);
    die(`${h} is NO LONGER UP in ${target(id)}: a non-shell foreground process held the pane at the gate before the kickoff, and after the kickoff attempt every foreground process in the pane is a shell - so NOTHING is in flight and the spawn is REFUSED. Those two observations are all this probe establishes: it cannot show the prompt was accepted, nor exclude an unrelated exit in between. LIKELY cause, named as a likelihood: the kickoff attempt itself (a startup dialog that read the prompt as an answer is one). Last lines of the pane:\n${capture(id, "15")}`);
  } else if (up === 2) {
    warn(`could not read ${target(id)} to verify ${h} survived the kickoff - the spawn stands (peek it: bin/ac-peek.sh ${id})`);
    kickoffUnverified(id, "post-delivery survival unverifiable (backend unreadable)");
  }
}

// A signal held through a synchronous child is delivered only when the loop
// turns: turning it at a phase's edge acts on it while that phase's cleanup is
// still the armed one, where the original acted as the child returned (W2 for
// the lease itself).
const turn = (): Promise<void> => new Promise((r) => setTimeout(r, 0));

// Reap a window an earlier spawn of this id left before writing any meta
// (ORPHAN-WINDOW SAFETY above), the probe's three states read.
function reapOrphanWindow(): void {
  const rc = alive(S.id);
  if (rc === 1) return;
  if (rc !== 0) die(`the BACKEND could not be READ for ${S.id} - whether ${target(S.id)} still exists is UNKNOWN, so this is REFUSED rather than open a second window beside a possibly LIVE one; check the backend itself (herdr status server), then try again`);
  warn(`reaping the orphan window of ${S.id} (${target(S.id)}): it carries no meta, so no fleet script could address it - an earlier spawn died before writing one`);
  killWindow(S.id);
}

// The cleanup on the chief paths, from window-create until a COMPLETE meta.
function spawnOrphanCleanup(): void {
  rmF(S.meta);
  killWindow(S.id);
  claimRelease();
}

// The cleanup on the crew path, from the lease until a COMPLETE meta.
function spawnFailedCleanup(): void {
  if (S.backend === "orca") orcaWorktreeRelease(S.worktree);
  else run([`${binDir}/ac-tree.sh`, "return", S.worktree, "--force"], { stdout: "ignore", stderr: "ignore" });
  rmF(S.meta);
  if (S.window !== "") killWindow(S.id);
  claimRelease();
}

// ac_codegraph_worktree's reading: the leased worktree's own CodeGraph index,
// fire-and-forget, `.codegraph/` kept out of git status through the shared
// info/exclude; off without codegraph or with config/codegraph off.
function codegraphWorktree(repo: string, wt: string): void {
  if (!commandV("codegraph")) return;
  if (configReadSoft("codegraph", "on") !== "on") return;
  if (!isDir(wt)) return;
  if (isDir(`${repo}/.git`) || isFile(`${repo}/.git`)) {
    const g = run(["git", "-C", repo, "rev-parse", "--git-common-dir"], { stderr: "ignore" });
    ee(g.status);
    let excl = cap(g.out);
    if (excl !== "" && !excl.startsWith("/")) excl = `${repo}/${excl}`;
    excl = `${excl}/info/exclude`;
    if (run(["grep", "-qxF", ".codegraph/", excl], { stdout: "ignore", stderr: "ignore" }).status !== 0) {
      ee(run(["mkdir", "-p", dirname(excl)], { stdout: "inherit", stderr: "ignore" }).status);
      try {
        appendFileSync(excl, ".codegraph/\n");
      } catch {}
    }
  }
  try {
    spawnShell(["codegraph", isFile(`${wt}/.codegraph/codegraph.db`) ? "sync" : "init"], { cwd: wt, stdin: "ignore", stdout: "ignore", stderr: "ignore" }).unref();
  } catch {}
}

async function main(argv: string[]): Promise<void> {
  backendName();
  if (process.env.AC_SOLO === "1") die("a solo session (AC_SOLO=1) never spawns crew or roomchiefs - its write path is bin/ac-self-task.sh, and crew work goes to the chief via bin/ac-remote.sh order (solo-session skill)");
  // The guard is warn-only advisory: its lines reach this run's stderr.
  const guard = `${STARTED_BIN}/ac-guard.sh`;
  try {
    accessSync(guard, fsc.X_OK);
    run([guard], { stdout: "inherit" });
  } catch {}
  if (!commandV("git")) die("required tool not found: git");
  binDir = STARTED_BIN;

  let id = "";
  let project = "";
  let scout = false;
  let crewdeputy = false;
  let recover = false;
  let roomchiefFamily = "";
  let harnessFlag = "";
  let modeFlag = "";
  let model = "";
  let effort = "";
  let backend = "";
  let resumeFrom = "";
  let review = "-";
  let baseBranch = "";
  let baseBranchSet = false;
  let captainInitiated = "";
  let captainInitiatedSet = false;
  let overCap = "";
  let overCapSet = false;
  let systemInitiated = "";
  let systemInitiatedSet = false;
  let codereviewRule = "";
  let codereviewRuleSet = false;
  let soloChief = false;
  // A value flag read `$2` raw: missing, the original died on `$2: unbound
  // variable` (W14), its status kept.
  const value = (i: number): string => (i + 1 < argv.length ? argv[i + 1]! : fatal(1));
  for (let i = 0; i < argv.length; ) {
    const a = argv[i]!;
    switch (a) {
      case "--scout":
        scout = true;
        i++;
        continue;
      case "--crewdeputy":
        crewdeputy = true;
        i++;
        continue;
      case "--recover":
        recover = true;
        i++;
        continue;
      case "--solo":
        soloChief = true;
        i++;
        continue;
      case "--roomchief":
        roomchiefFamily = value(i);
        break;
      case "--captain-initiated":
        captainInitiated = value(i);
        captainInitiatedSet = true;
        break;
      case "--system-initiated":
        systemInitiated = value(i);
        systemInitiatedSet = true;
        break;
      case "--over-cap":
        overCap = value(i);
        overCapSet = true;
        break;
      case "--harness":
        harnessFlag = value(i);
        break;
      case "--model":
        model = value(i);
        break;
      case "--effort":
        effort = value(i);
        break;
      case "--backend":
        backend = value(i);
        break;
      case "--resume-from":
        resumeFrom = value(i);
        break;
      case "--mode":
        modeFlag = value(i);
        break;
      case "--base-branch":
        baseBranch = argv[i + 1] ?? "";
        if (baseBranch === "") die("--base-branch names the branch the orca lease is cut from (wins over the live checkout; orca backend only)");
        baseBranchSet = true;
        break;
      case "--codereview-rule":
        codereviewRule = value(i);
        codereviewRuleSet = true;
        break;
      default:
        if (a.startsWith("-")) die(`unknown flag: ${a}`);
        if (id === "") id = a;
        else if (project === "") project = a;
        else die(`unexpected arg: ${a}`);
        i++;
        continue;
    }
    i += 2;
  }
  if (roomchiefFamily === "" && (captainInitiatedSet || systemInitiatedSet || overCapSet)) die("--captain-initiated/--system-initiated/--over-cap require --roomchief (they gate the room-parallel cap)");
  if (roomchiefFamily === "" && soloChief) die("--solo requires --roomchief (a SOLO CHIEF is a roomchief that works its family's slices itself; a crewmate has no such mode)");
  if (recover && resumeFrom !== "") die("--recover and --resume-from are mutually exclusive (a recovery resumes the task's OWN recorded session in its OWN worktree)");
  if (codereviewRuleSet && (roomchiefFamily !== "" || crewdeputy)) die("--codereview-rule requires a plain crew spawn (it resolves panes.codereview, which only threads to an execution crewmate)");
  if (baseBranchSet && (roomchiefFamily !== "" || crewdeputy)) die("--base-branch requires a plain crew spawn (it names the orca lease's base branch, which only the crew path leases)");
  // Both grammars are read in the C locale: a collation interleaving case
  // would admit uppercase through a-z.
  if (roomchiefFamily !== "") {
    if (/[^a-z0-9-]/.test(roomchiefFamily)) die(`family must be [a-z0-9-]: ${roomchiefFamily}`);
    if (scout || crewdeputy) die("--roomchief excludes --scout/--crewdeputy");
    if (project !== "" || id !== "") die("usage: ac-spawn.sh --roomchief <family> (id is derived: <family>-chief)");
    id = `${roomchiefFamily}-chief`;
  } else if (crewdeputy) {
    if (id === "") die("usage: ac-spawn.sh <id> --crewdeputy [--harness <h>] [--backend <b>]");
    if (scout) die("--crewdeputy and --scout are mutually exclusive");
    if (project !== "") die(`crewdeputies run in their home, not a project (drop '${project}')`);
  } else if (id === "" || project === "") die("usage: ac-spawn.sh <id> <project> [--scout] [--harness <h>] [--model <m>] [--effort <e>] [--backend <b>]");
  if (/[^a-z0-9-]/.test(id)) die(`id must be [a-z0-9-]: ${id}`);
  S.id = id;

  // Fleet-wide defaults (above): an explicit flag wins; a config-fallback
  // model is one the crew path may still drop (the SHARP EDGE).
  const modelExplicit = model !== "";
  if (model === "") model = configReadSoft("model", "");
  if (effort === "") effort = configReadSoft("effort", "");
  let effortFlag = effort;
  if (effort !== "") {
    if (effort === "ultracode") {
      effortFlag = "xhigh";
      ultracode = true;
    } else if (!["low", "medium", "high", "xhigh", "max"].includes(effort)) die(`invalid effort: ${effort} (expected low|medium|high|xhigh|max|ultracode)`);
  }

  const sd = stateDir();
  S.meta = `${sd}/${id}.meta`;
  S.claimRoot = `${sd}/.meta-claims`;
  S.claim = `${S.claimRoot}/${id}`;

  if (recover && crewdeputy) {
    // The guarded crewdeputy recovery ladder (above).
    const pargv = deputyParse();
    const parsed = pargv === null ? { status: 0, out: "", raw: Buffer.alloc(0) } : run(pargv);
    const sel = run(["awk", "-F\\t", "-v", `i=${id}`, '$1 != "INVALID" && $2 == i { print $3; exit }'], { stdin: parsed.raw });
    ee(sel.status !== 0 ? sel.status : parsed.status);
    const depHome = cap(sel.out);
    if (depHome === "") die(`--recover: no parseable entry for ${id} in ${deputyRegistry()} - there is nothing to recover`);
    if (!(isDir(depHome) && isFile(`${depHome}/.ac-crewdeputy-home`))) die(`--recover: HOME-MISSING for ${id} (${depHome}) - repairing or removing a registry line is a captain decision, not a recovery`);
    if (existsSync(S.meta)) {
      // A stale meta naming an unsupported backend reads as not-alive (its
      // refusal printed): the ordinary path below re-checks the collision.
      const saved = process.env.AC_BACKEND;
      process.env.AC_BACKEND = taskBackend(id);
      const probe = backendCall("window_alive", [id], { stdin: "inherit", stdout: "inherit", stderr: "inherit", subshell: true });
      if (!probe.exited && probe.status === 0) die(`--recover: ${id} is LIVE (${cap(backendCall("target", [id], { stdout: "pipe", stderr: "inherit" }).out.toString("utf8"))}) - a live pane is never double-spawned`);
      if (saved === undefined) delete process.env.AC_BACKEND;
      else process.env.AC_BACKEND = saved;
      // Retired, never deleted: each recovery gets its OWN stamped slot.
      ee(run(["mkdir", "-p", `${sd}/archive/${id}`], { stdout: "inherit" }).status);
      const mk = run(["mktemp", "-d", `${sd}/archive/${id}/${u8(nowRaw())}.XXXXXX`]);
      ee(mk.status);
      const archDir = cap(mk.out);
      ee(run(["mv", S.meta, `${archDir}/meta`], { stdout: "inherit" }).status);
      if (isFile(taskStatus(id))) ee(run(["mv", taskStatus(id), `${archDir}/status`], { stdout: "inherit" }).status);
      warn(`--recover: archived the stale meta for ${id} to ${archDir}`);
    }
  }
  if (recover && !crewdeputy) {
    if (!existsSync(S.meta)) die(`--recover: no meta for ${id} - there is nothing to recover (spawn it fresh)`);
  } else if (existsSync(S.meta)) die(`crewmate ${id} already exists (see ${S.meta}); tear it down first`);

  const brief = `${taskDirOrDie(id)}/brief.md`;
  if (roomchiefFamily === "" && !isFile(brief)) die(`no brief at ${brief}; run ac-brief.sh first`);
  if (!crewdeputy && !scout && roomchiefFamily === "") {
    // Only the bare first token of the Review: line is the obligation.
    const r = run(["sed", "-n", "s/^Review: //p", brief]);
    ee(r.status);
    const first = r.out.split("\n")[0]!;
    review = first.split(/[ \t]+/).filter((w) => w !== "")[0] ?? "";
    if (review !== "yes" && review !== "no") die(`execution brief must carry exactly one Review: yes|no obligation: ${brief}`);
  }

  // Same-stage revision: reopen the old crewmate's claude session, in its
  // OLD worktree (claude keys sessions by cwd).
  let resumeWt = "";
  if (resumeFrom !== "") {
    let oldMeta = `${sd}/${resumeFrom}.meta`;
    if (!isFile(oldMeta)) oldMeta = `${sd}/archive/${resumeFrom}/meta`;
    if (!isFile(oldMeta)) die(`--resume-from: no meta for ${resumeFrom}`);
    if (metaGetSoft(oldMeta, "harness") !== "claude") die(`--resume-from: ${resumeFrom} was not a claude session; spawn fresh with the old report as input`);
    resumeSid = metaGetHard(oldMeta, "session_id");
    if (resumeSid === "") die(`--resume-from: ${resumeFrom} has no recorded session_id; spawn fresh with the old report as input`);
    resumeWt = metaGetHard(oldMeta, "worktree");
    harnessFlag = "claude";
  }

  // Pin the backend for this task; every backend call below, and every later
  // script through the meta, honors it.
  process.env.AC_BACKEND = backend !== "" ? backend : configReadSoft("backend", "herdr");
  backend = backendName();
  S.backend = backend;
  if (baseBranchSet && backend !== "orca") die(`--base-branch requires an orca-backend fleet (config/backend=${backend} here) - a herdr fleet leases from its own worktree pool, which has no base-branch concept`);

  // Validated before any window or lease, so a bad value fails fast.
  const badNumber = (s: string): boolean => s === "" || /[^0-9.]/.test(s) || /\..*\./.test(s);
  settle = process.env.AC_SPAWN_SETTLE || "8";
  if (badNumber(settle)) die(`AC_SPAWN_SETTLE must be a non-negative number: ${settle}`);
  ultracodeSettle = process.env.AC_ULTRACODE_SETTLE || "2";
  if (ultracode && badNumber(ultracodeSettle)) die(`AC_ULTRACODE_SETTLE must be a non-negative number: ${ultracodeSettle}`);
  readyBudget = process.env.AC_KICKOFF_READY_BUDGET || "60";
  if (readyBudget === "" || /[^0-9]/.test(readyBudget)) die(`AC_KICKOFF_READY_BUDGET must be a non-negative integer: ${readyBudget}`);

  const crewEnv = (c: Partial<CrewEnv> = {}): string => crewLaunchEnv({ id, review, model, effort, projectDir: "", rule: codereviewRule, ruleSet: codereviewRuleSet, ...c });

  // --- crewmate / roomchief recovery ------------------------------------------
  if (recover && !crewdeputy) {
    // GUARDED RECOVERY (above): the task's OWN backend decides the probe.
    process.env.AC_BACKEND = taskBackend(id);
    backend = backendName();
    S.backend = backend;
    await spawnMetaClaimAcquire(true);
    S.trap = claimRelease;
    const rc = alive(id);
    if (rc === 0) die(`--recover: ${id} is LIVE (${target(id)}) - a live pane is never double-spawned`);
    if (rc !== 1) die(`--recover: the BACKEND could not be READ for ${id} - whether ${target(id)} still exists is UNKNOWN, so this recovery is REFUSED rather than open a second pane beside a possibly LIVE one; check the backend itself (herdr status server), then recover again`);
    const recKind = metaGetHard(S.meta, "kind");
    const recDir = metaGetHard(S.meta, "worktree");
    const recSid = metaGetHard(S.meta, "session_id");
    if (recKind === "crewdeputy") die(`--recover: ${id} is a crewdeputy - its ladder is ac-spawn.sh ${id} --crewdeputy --recover`);
    if (!["ship", "scout", "roomchief"].includes(recKind)) die(`--recover: kind=${recKind || "unknown"} has no recovery path (verify panes belong to ac-verify.sh, self tasks to ac-self-task.sh)`);
    if (recDir === "" || !isDir(recDir)) die(`--recover: the recorded worktree of ${id} is gone (${recDir || "none"}) - nothing to reopen a pane on; tear it down instead`);
    if (!(metaGetSoft(S.meta, "harness") === "claude" && recSid !== "")) die(`--recover: ${id} has no resumable claude session on record - tear it down and spawn fresh with its branch and report as inputs`);
    // The recorded model/effort ride the resume as the first launch carried
    // them.
    model = metaGetHard(S.meta, "model");
    effort = metaGetHard(S.meta, "effort");
    effortFlag = effort === "ultracode" ? "xhigh" : effort;
    resumeSid = recSid;
    const l = spawnLaunch("claude", model, effortFlag, brief, id);
    ee(l.status);
    launch = l.out;
    if (!commandV("claude")) die("harness binary not found: claude");
    let notice = "Notice: your pane was destroyed and has been RECOVERED - same session, same worktree, uncommitted work untouched. A command running when the pane died was killed mid-way: before continuing, check what it left (git status and log, the remote branch, any PR you were opening) and re-run it only if it did not finish.";
    let envPrefix: string;
    if (recKind === "roomchief") {
      const fam = metaGetHard(S.meta, "project");
      const dom = metaGetHard(S.meta, "domain");
      const domEnv = dom === "" ? "" : `AC_DOMAIN=${q(dom)} `;
      const soloEnv = metaGetSoft(S.meta, "solo") !== "1" ? "" : "AC_CHIEF_SOLO=1 ";
      envPrefix = `AC_HOME=${q(envHome())} AC_SCOPE=${q(fam)} ${domEnv}${soloEnv}${compactPctEnv()}`;
      notice += ` Your family watcher died with the old tab: re-arm it as a background task (AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set ${fam}) bin/ac-watch.sh - recompute the set each re-arm so an epic keeps covering its in-flight story panes), then continue.`;
      process.env.AC_WINDOW_FAMILY = fam;
    } else {
      const recReview = metaGetHard(S.meta, "review");
      review = recReview || "-";
      const projectDirRec = metaGetHard(S.meta, "project_dir");
      const recScope = metaGetHard(S.meta, "fleet_scope");
      if (recScope !== "") process.env.AC_SCOPE = recScope;
      envPrefix = crewEnv({ review, model, effort, projectDir: projectDirRec });
    }
    // One fresh pane the ordinary way, at the recorded cwd; a failed relaunch
    // takes it with it and leaves the task handle-less.
    ended(backendWindowNew(id, recDir));
    delete process.env.AC_WINDOW_FAMILY;
    S.window = target(id);
    if (sendLine(id, `${u8(claudeConfigEnv())}${CODEGRAPH_ENV}${envPrefix}${launch}`, true) !== 0) {
      killWindow(id);
      die(`--recover: resume line NOT delivered to ${id} (see stderr above) - the fresh pane was closed again; recover again once the backend answers`);
    }
    ee(await sleepFor(settle));
    const up = harnessUp(id);
    if (up === 1) {
      statusHard(id, `warn: recovery refused - claude did NOT come up on --resume ${recSid} (the pane fell back to a shell); the fresh pane was closed again`);
      const last = bc("capture", [id, "15"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" }).out;
      try {
        writeAll(2, last);
      } catch {}
      killWindow(id);
      die(`--recover: claude did NOT come up in ${S.window} on --resume ${recSid} (its last lines above) - the fresh pane was closed again and ${id} is as it was; a session claude no longer knows cannot be recovered, tear down and spawn fresh`);
    } else if (up === 2) warn(`could not read ${S.window} to verify claude came up - the recovery stands (peek it: bin/ac-peek.sh ${id})`);
    if (sendLine(id, notice) !== 0) warn(`recovery notice NOT delivered to ${id} (see stderr above) - the session IS resumed, so re-send it only if the agent looks confused: bin/ac-send.sh ${id} '${notice}'`);
    await turn();
    metaSetHard(S.meta, "window", S.window);
    claimRelease();
    statusHard(id, `recovered: pane reopened at ${S.window}, session ${recSid} resumed`);
    if (!put(1, `recovered ${id} kind=${recKind} backend=${backend} window=${S.window} worktree=${recDir}\n`)) fatal(1);
    return;
  }

  await spawnMetaClaimAcquire(false);
  S.trap = claimRelease;

  // --- roomchief path -------------------------------------------------------
  if (roomchiefFamily !== "") {
    const fam = roomchiefFamily;
    // Origin + cap-gate flags (above): at most ONE, resolved before the cap.
    if (captainInitiatedSet && systemInitiatedSet) die("--captain-initiated and --system-initiated are mutually exclusive: a promote has exactly ONE origin, and the meta records exactly one initiated_by");
    if (captainInitiatedSet && overCapSet) die("--captain-initiated and --over-cap are mutually exclusive: a captain-initiated promote is already exempt from the cap, so an over-cap sanction on it is meaningless");
    if (systemInitiatedSet && overCapSet) die("--system-initiated and --over-cap are mutually exclusive: a system-initiated promote is already exempt from the cap, so an over-cap sanction on it is meaningless");
    let initiatedBy = "chief";
    if (captainInitiatedSet) {
      if (captainInitiated === "") die("--captain-initiated needs a non-empty order ref: a captain-initiated promote must name the captain order it carries out");
      initiatedBy = "captain";
    } else if (systemInitiatedSet) {
      if (systemInitiated === "") die("--system-initiated needs a non-empty order ref: a system-initiated promote must name the STANDING captain order it carries out");
      initiatedBy = "system";
    }
    let overcapReason = "";
    let overcapGiven = false;
    if (overCapSet) {
      overcapReason = overCap;
      overcapGiven = true;
    } else if (process.env.AC_ROOM_OVERCAP_REASON) {
      overcapReason = process.env.AC_ROOM_OVERCAP_REASON;
      overcapGiven = true;
    }

    // The cap (above): chief-initiated metas present, plus every OTHER live
    // *-chief claim not yet backed by a meta, read in byte order.
    let capV = configReadSoft("room-parallel", "5");
    if (capV === "" || /[^0-9]/.test(capV)) capV = "5";
    const flying: string[] = [];
    const byBytes = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));
    const names = (dir: string): string[] => {
      try {
        return readdirSync(dir).sort(byBytes);
      } catch {
        return [];
      }
    };
    for (const n of names(sd)) {
      if (n.startsWith(".") || !n.endsWith("-chief.meta")) continue;
      const m = `${sd}/${n}`;
      if (!existsSync(m)) continue;
      if (metaGetSoft(m, "kind") !== "roomchief") continue;
      const by = metaGetSoft(m, "initiated_by");
      if (by === "captain" || by === "system") continue;
      flying.push(basename(m, ".meta").replace(/-chief$/, ""));
    }
    const grace = testInt(process.env.AC_SPAWN_META_CLAIM_STALE_GRACE || "15");
    for (const n of names(S.claimRoot)) {
      if (n.startsWith(".") || !n.endsWith("-chief")) continue;
      const cd = `${S.claimRoot}/${n}`;
      if (!isDir(cd) || cd === S.claim) continue;
      if (existsSync(`${sd}/${n}.meta`)) continue;
      const cowner = readCap(`${cd}/pid`);
      const cmtime = fileMtime(cd) ?? "";
      if (/^[0-9]+$/.test(cmtime) && grace !== null) {
        let age: bigint;
        try {
          age = arithValue(nowRaw()) - arithValue(cmtime);
        } catch {
          return fatal(1);
        }
        if (age >= grace && (cowner === "" || !pidAlive(cowner))) continue;
      }
      flying.push(`${n.replace(/-chief$/, "")} (promoting)`);
    }
    const nChiefs = BigInt(flying.length);
    const capN = testInt(capV);
    let overcapUsed = false;
    if (initiatedBy === "captain" || initiatedBy === "system") {
    } else if (capN !== null && nChiefs < capN) {
    } else if (overcapGiven) {
      if (overcapReason === "") die(`over-cap promote needs the captain's explicit sanction: pass --over-cap '<why the captain approved exceeding room-parallel=${capV}>' (the cap MAY be exceeded per-case only WITH the captain's permission)`);
      overcapUsed = true;
    } else die(`room-parallel cap reached: ${nChiefs}/${capV} roomchiefs in flight (${flying.join(", ") || "none"}); demote a landed one (bin/ac-teardown.sh <family>-chief) before promoting ${fam}, or add one past the cap with the captain's sanction (--over-cap '<reason>')`);

    // THE ORDER GATE (above): an entry in the room, never the file alone.
    if (run(["grep", "-q", "^- \\[", `${dataDir()}/${fam}/room.md`], { stdout: "ignore", stderr: "ignore" }).status !== 0)
      die(`room ${fam} holds no entry: --roomchief takes no brief - the room IS the brief - so this promote would hand the new chief nothing to read. Post the order into the room FIRST, then promote: bin/ac-room.sh post ${fam} crewchief 'ORDER: <the captain order, verbatim>' && bin/ac-spawn.sh --roomchief ${fam}`);

    // THE DERIVED CREWDOMAIN BINDING (above): the family row's own domain:
    // token, else its epic row's, read by the one doneline parser under C.
    let domOwn = "";
    let domInh = "";
    const ledger = `${recordsDir()}/backlog.md`;
    if (isFile(ledger)) {
      const L = ledgerRead(ledger);
      if (L.rc === 2) die(`cannot read the ledger for the domain binding of ${fam}`);
      if (L.rc === 0) {
        const rows = records(L.text)
          .filter((r) => r.startsWith("- ["))
          .map(acDoneline);
        const d = new Map<string, string>();
        for (const o of rows) if (o.domain !== "") d.set(o.id, o.domain);
        const own = rows.find((o) => o.id === fam);
        if (own) {
          domOwn = u8(own.domain);
          domInh = own.epic !== "" ? u8(d.get(own.epic) ?? "") : "";
        }
      }
    }
    if (domOwn !== "" && domInh !== "" && domOwn !== domInh) die(`family ${fam} carries domain:${domOwn} but its epic row carries domain:${domInh} - one family, one domain; corrupt state, not a choice this promote may make. Strip the wrong token: bin/ac-domain.sh unassign <name> <id>`);
    const dom = domOwn || domInh;
    if (dom !== "") {
      // A VALID registry entry is REQUIRED: a retired domain's token mints no
      // domainchief.
      const pargv = domainParse();
      const parsed = pargv === null ? { status: 0, out: "", raw: Buffer.alloc(0) } : run(pargv);
      const found = parsed.out.split("\n").some((l) => {
        const f = l.split("\t");
        return f[0] === "VALID" && f[1] === dom;
      });
      if (parsed.status !== 0 || !found) die(`family ${fam} carries domain:${dom} but '${dom}' is not a VALID entry in records/crewdomains.md - refusing to promote a chief bound to a domain nothing routes to. Either restore its line in records/crewdomains.md, or strip the token: bin/ac-domain.sh unassign ${dom} ${fam}`);
    }

    const root = STARTED_BIN.slice(0, -"/bin".length);
    // The harness: --harness, else the keyed panes.roomchief (no selector;
    // a routed one resolves its mandatory default; unresolvable DIES), else
    // config/crew-harness.
    let harness: string;
    if (harnessFlag !== "") harness = harnessFlag;
    else {
      const p = run([`${binDir}/ac-dispatch-select.sh`, "--pane", "roomchief"], { stderr: "ignore" });
      if (p.status !== 0) die("crew-dispatch panes.roomchief is present but unresolvable - refusing to fall back to config/crew-harness (see bin/ac-dispatch-select.sh --pane roomchief)");
      const prof = cap(p.out);
      if (prof !== "") {
        const ph = tabFields(prof.split("\n")[0]!, 3)[0]!;
        harness = ph.startsWith("harness=") ? ph.slice("harness=".length) : ph;
      } else harness = configReadSoft("crew-harness", "claude");
    }
    const l = spawnLaunch(harness, model, effortFlag, brief, id);
    ee(l.status);
    launch = l.out;
    const first = launch.split(" ")[0]!;
    if (!launchable(first)) die(`harness binary not found: ${first}`);

    reapOrphanWindow();
    // The roomchief's tab anchors its FAMILY's workspace, its cwd the home.
    process.env.AC_WINDOW_FAMILY = fam;
    ended(backendWindowNew(id, envHome()));
    delete process.env.AC_WINDOW_FAMILY;
    S.window = target(id);
    S.trap = spawnOrphanCleanup;

    const slackDuty =
      configReadSoft("remote-mirror", "off") === "chief"
        ? `You also WRITE this family's Slack thread yourself: after each captain-facing room post, compose the human-readable update and send it with bin/ac-remote.sh thread-post ${fam} (add --mention-captain on GATE/ASK); style per records/captain.md. After you post the LANDING done-report, run bin/ac-remote.sh done-stamp ${fam} so the turn-end guard knows it went out. `
        : "";
    let prompt = `You are the ROOMCHIEF of family ${fam}. Read the room first: bin/ac-room.sh show ${fam}. You own ONLY this family's stages and gates: brief/spawn/supervise its crewmates, talk to the captain in THIS thread, post every event and gate to room ${fam} (GATE:/ASK:/DECIDED:). ${slackDuty}NEVER touch records/backlog.md or records/projects.md - the crewchief owns them (enforced: bin/ac-ledger-guard.sh refuses an Edit/Write/NotebookEdit on either while AC_SCOPE is set). MEMORY: the home brain is your cross-history recall. EVERY wake-drain prints your brain delta (brain-delta: the pages and facts that changed since you last looked, on your ${fam}-chief cursor) - read it in the drain output; bin/ac-brain.sh delta --agent ${fam}-chief --session ${fam} replays the same cursor by hand, and every prompt the captain types is answered with the top recall hits before you read it. After a compaction rebuild footing with bin/ac-brain.sh context_pack --entities data/${fam}/room. When the room and the knowledge tiers leave a question open, ask the fleet's history: bin/ac-brain.sh recall '<question>'. Arm your watcher as the harness's OWN background task with AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set ${fam}) bin/ac-watch.sh - watch-set returns your family id plus your IN-FLIGHT story families (so an epic's scoped watcher also covers its story crewmate panes; a non-epic family is just your family id), so RECOMPUTE it every re-arm to track stories as they start and land. The harness runs it, tracks it, and is woken by its exit; NEVER nohup/&/disown it inside a tool call, which orphans it and wakes no one. When the family lands: FIRST debrief the family (append its durable lessons as dated one-liners with bin/ac-learn.sh note '### <date> (family ${fam})' '- <lesson>' ... - it PLACES them under '## Pending' in records/learnings.md, the only section the next Learning transaction reads; appending at end-of-file instead puts them after '## Distilled', where that transaction deletes them. Your context dies with demotion, the lessons must not), THEN report back with bin/ac-room.sh handback ${fam} '<one-line outcome>' (it posts the room record AND queues a durable wake for the crewchief - never rely on a pane line alone), then print \`done:\` hand-back. Keep AC_CAPTAIN_RE marker verbs out of your room and pane prose - drop the trailing colon or backtick-wrap the token when you show one - so a narrative line never false-wakes the watcher or false-stamps a pane.`;
    // THE DOMAINCHIEF SECTION, only when a domain resolved - an ordinary
    // roomchief's prompt stays byte-identical.
    if (dom !== "")
      prompt += `

You are the DOMAINCHIEF of crewdomain ${dom} (an ordinary roomchief carrying a domain; your meta stays kind=roomchief with domain=${dom}). Its package is crewdomains/${dom}/. What that changes, and nothing else does:
STANDING RULES: read the FLEET records/captain.md exactly as any chief does - your domain has NO captain.md of its own, and its standing rules are the lines in that file prefixed 'STANDING (domain:${dom}): '. Read them at intake, before you triage.
LEARNINGS: your domain has no learnings ledger. Note lessons to the FLEET records/learnings.md with bin/ac-learn.sh note as any roomchief does, prefixing each lesson '(domain:${dom})' so the domain's material stays filterable.
PROJECTS - MEMBERSHIP: your view is crewdomains/${dom}/projects/, symlinks into the fleet's OWN clones. A crewmate spawn for a project outside that view is REFUSED, so brief only what the view holds.
PROJECTS - DETAIL: read crewdomains/${dom}/records/projects.md - the domain's view of each in-scope project. The FLEET records/projects.md stays authoritative for [mode] and the description; verified CODE facts belong in records/repo-knowledge/<project>.md, never in the detail file.
BACKLOG: your family's row lives in the FLEET records/backlog.md, stamped domain:${dom} - there is NO domain ledger. You NEVER edit that file (the ledger guard fences it; the crewchief moves rows at promote and at your handback, the ordinary roomchief contract). Read your domain's slice with bin/ac-domain.sh queue ${dom}.
OVERLAP: before starting work run bin/ac-ready.sh overlap on the order's file surface plus git status in every live lease, against EVERY in-flight family - your domain shares the fleet's clones, so an overlap is fleet-wide, never domain-local.
DISTIL BEFORE HANDBACK: raw lessons and curated knowledge are two classes and only the second is what your successor re-reads directly. Note the raw ones as above; fold DURABLE domain knowledge into the curated files - crewdomains/${dom}/CREWMATE.md and the records/projects.md detail - before you hand back. With no domain ledger, that fold is the ONLY per-domain memory write path.
HANDBACK: the ordinary roomchief channel, bin/ac-room.sh handback ${fam} - there is no domain-specific return channel.`;
    const domEnv = dom === "" ? "" : `AC_DOMAIN=${q(dom)} `;
    // THE SOLO CHIEF SECTION (solo-session skill), only on --solo.
    let soloEnv = "";
    if (soloChief) {
      soloEnv = "AC_CHIEF_SOLO=1 ";
      prompt += `

You are the SOLO CHIEF of this family (a roomchief promoted --solo; your meta stays kind=roomchief with solo=1, your environment carries AC_CHIEF_SOLO=1). The captain judged this family too small to cost a crewmate, so you WORK ITS SLICES YOURSELF - every other roomchief duty above binds unchanged. What that changes, and nothing else does:
SLICES: open each slice with bin/ac-self-task.sh start ${fam}-<slug> <project> (it leases the worktree, seeds the crewmate layer and makes the slice visible), read the seeded crewmate instruction file inside that worktree before your first edit, work under the crewmate rules (TDD, comment discipline, the smallest diff), commit on crew/${fam}-<slug>, and log progress with bin/ac-self-task.sh log.
REVIEW IS MANDATORY: nobody else reads your code, so every slice gets ONE independent review round before it lands - the crew-verify skill (bin/ac-verify.sh codereview, run in the FOREGROUND) - and a pass at a reviewed_ref equal to HEAD is the receipt you land on. No slice of yours lands unreviewed, local-only included.
LANDING: land per the slice's mode (bin/ac-merge-local.sh, or a PR the captain merges), then post LANDED: ${fam}-<slug> - <outcome> to this room BEFORE bin/ac-teardown.sh ${fam}-<slug>: you may not write records/backlog.md (the ledger guard fences it), so that receipt is what the teardown gate reads where a Done row would be; the crewchief moves the family row at your hand-back. IF THE SLICE CANNOT LAND - main moved under it is the cheap way there, and ac-merge-local.sh withholds --no-ff from every scoped session on purpose - do NOT rebase to force it (a rebase changes the sha a review receipt binds by, so a clean one costs a whole extra review round): post UNLANDABLE: ${fam}-<slug> - <why>; crewchief to land (its OWN verb - HANDBACK: is this family's tenure-ending receipt and would flip the whole family), leave the slice IN FLIGHT, and tell the crewchief in your hand-back; the crewchief lands crew/${fam}-<slug> --no-ff, and only THEN does bin/ac-teardown.sh ${fam}-<slug> pass, reading UNLANDABLE where LANDED would be. The gate still owes a lesson (bin/ac-learn.sh note) and a verified repo fact (bin/ac-know.sh add), or --no-lesson/--no-fact '<why>'; the lesson is read by its (by: ${fam}-<slug>, first-hand) attribution, so file it under whichever heading your family uses.
HANDS, NOT SUBAGENTS: the delegation guard still fences harness subagents from this session - edit with your own hands, or spawn a real crewmate when a slice outgrows you; never both on one slice.`;
    }
    ee(sendLine(id, `${launchPromptEnv(harness, prompt)}${u8(claudeConfigEnv())}${CODEGRAPH_ENV}AC_HOME=${q(envHome())} AC_SCOPE=${q(fam)} ${domEnv}${soloEnv}${compactPctEnv()}${launch}`, true));
    await deliverKickoff(id, harness, prompt);

    metaSetHard(S.meta, "backend", backend);
    metaSetHard(S.meta, "window", S.window);
    metaSetHard(S.meta, "worktree", envHome());
    metaSetHard(S.meta, "project", fam);
    metaSetHard(S.meta, "project_dir", root);
    metaSetHard(S.meta, "harness", harness);
    recordOpts(harness, model, effort, effortFlag);
    metaSetHard(S.meta, "kind", "roomchief");
    if (dom !== "") metaSetHard(S.meta, "domain", dom);
    if (soloChief) metaSetHard(S.meta, "solo", "1");
    metaSetHard(S.meta, "initiated_by", initiatedBy);
    metaSetHard(S.meta, "mode", "-");
    metaSetHard(S.meta, "yolo", "off");
    recordSid();
    metaSetHard(S.meta, "spawned_at", iso());
    await turn();
    claimRelease();
    S.trap = null;
    // PAST THIS LINE THE PROMOTE HAS HAPPENED and is not retryable: every
    // bookkeeping failure below WARNS by name and the run still exits 0.
    if (!statusSoft(id, "working: roomchief promoted")) warn(`roomchief ${id} is promoted, but its status line could not be appended`);
    const soloNote = soloChief ? " - solo chief: tự làm các slice của family này qua ac-self-task.sh, không spawn crewmate (solo-session skill)" : "";
    if (run([`${binDir}/ac-room.sh`, "post", fam, "crewchief", `PROMOTED: đã mở phiên roomchief (${id}) - trao đổi family này trong thread riêng của nó${soloNote}`], { stdout: "ignore" }).status !== 0)
      warn(`roomchief ${id} is promoted, but the PROMOTED: post to room ${fam} failed`);
    let receipt = "";
    if (initiatedBy === "captain") receipt = `DECIDED: ${fam} captain-initiated promote (order ref: ${captainInitiated}) - EXEMPT, does NOT count toward room-parallel=${capV}`;
    else if (initiatedBy === "system") receipt = `DECIDED: ${fam} system-initiated promote (standing order: ${systemInitiated}) - EXEMPT, does NOT count toward room-parallel=${capV}`;
    else if (overcapUsed) receipt = `DECIDED: ${fam} over-cap promote, +1 past room-parallel=${capV} - captain sanction: ${overcapReason}`;
    if (receipt !== "") {
      // AC_ROOM_PROMOTE_RECEIPT=1 declares this ONE post the cap-gate receipt.
      process.env.AC_ROOM_PROMOTE_RECEIPT = "1";
      const posted = run([`${binDir}/ac-room.sh`, "post", fam, "crewchief", receipt], { stdout: "ignore" }).status;
      delete process.env.AC_ROOM_PROMOTE_RECEIPT;
      if (posted !== 0) warn(`roomchief ${id} is promoted, but its DECIDED: receipt could not be posted to room ${fam} - the captain has no record of which exemption it rode: ${receipt}`);
    }
    // The code-owned START announce under remote-mirror=chief, once per
    // family thread; its sed and cut stay the bytes' judges (W9).
    if (configReadSoft("remote-mirror", "off") === "chief" && !existsSync(`${sd}/remote-threads/${fam}.thread`)) {
      let snip = "";
      const room = `${dataDir()}/${fam}/room.md`;
      if (isFile(room)) {
        const r = run(["sed", "-n", "s/^- \\[[^]]*\\] [^>]*> \\(ORDER.*\\)$/\\1/p", room]);
        ee(r.status);
        const lines = r.out.replace(/\n$/, "").split("\n");
        snip = cap(r.out === "" ? "" : lines[lines.length - 1]!);
      }
      if (snip === "") {
        const bl = `${recordsDir()}/backlog.md`;
        if (isFile(bl)) {
          const r = run(["sed", "-n", `s/^- \\[[ x]\\] \\(${fam} .*\\)$/\\1/p`, bl]);
          ee(r.status);
          snip = cap(r.out.split("\n")[0]!);
        }
      }
      if (snip !== "") {
        const c = run(["cut", "-c1-320"], { stdin: Buffer.from(snip, "utf8") });
        ee(c.status);
        const cut = cap(c.out);
        if (cut !== snip) snip = `${cut}…`;
      }
      const body = `🚀 *[${u8(vnTs().stamp)}] [START] [${fam}]* crewchief\n${snip !== "" ? `• ${snip}\n` : ""}`;
      run([`${binDir}/ac-remote.sh`, "thread-post", fam], { stdin: Buffer.from(body, "utf8"), stdout: "ignore", stderr: "ignore" });
    }
    if (!put(1, `spawned ${id} harness=${harness} kind=roomchief mode=- yolo=off backend=${backend} window=${S.window} scope=${fam}\n`))
      put(2, `WARN: roomchief ${id} is promoted, but its outcome line could not be printed (output channel closed)\n`);
    return;
  }

  // --- crewdeputy path --------------------------------------------------------
  if (crewdeputy) {
    const homeDir = `${envHome()}/crewdeputies/${id}`;
    if (!isDir(`${homeDir}/state`)) die(`crewdeputy home not seeded: run ac-home-seed.sh ${id} first`);
    const harness = harnessFlag || configReadSoft("crew-harness", "claude");
    const l = spawnLaunch(harness, model, effortFlag, brief, id);
    ee(l.status);
    launch = l.out;
    const first = launch.split(" ")[0]!;
    if (!launchable(first)) die(`harness binary not found: ${first}`);
    // A recovery keeps the REFUSAL: its ladder left state/.pane-<id> so this
    // check still catches a LIVE deputy its own probe could not answer for.
    if (recover) {
      const rc = alive(id);
      if (rc === 0) die(`window ${target(id)} already exists`);
      if (rc !== 1) die(`the BACKEND could not be READ for ${id} - whether ${target(id)} still exists is UNKNOWN, so this recovery is REFUSED rather than risk a second window on a LIVE deputy's home; check the backend itself (herdr status server), then recover again`);
    } else reapOrphanWindow();
    // A crewdeputy's tab lives in the fleet ROOT workspace, its cwd the
    // deputy home.
    process.env.AC_WINDOW_FAMILY = "";
    ended(backendWindowNew(id, homeDir));
    delete process.env.AC_WINDOW_FAMILY;
    S.window = target(id);
    S.trap = spawnOrphanCleanup;
    const prompt = `You are agent-crew crewdeputy ${id}. Your home is ${homeDir} (AC_HOME). Read and follow the brief at ${brief}; run bin/ac-session-start.sh in your current directory first. You are IDLE BY DEFAULT: act only on work routed to you or already recorded in your own home, then WAIT - an empty queue is healthy, and you never invent work (no self-directed survey, audit or refactor sweep). Answer every routed order (a pane line prefixed [chief-order ...]) on the DURABLE return channel with bin/ac-deputy.sh report '<text>' [--doc <abs-path>], never only in chat, and return only phase changes the parent must act on - done, blocked, needs-decision, failed, paused - never your home's routine churn.`;
    ee(sendLine(id, `${launchPromptEnv(harness, prompt)}${u8(claudeConfigEnv())}${CODEGRAPH_ENV}AC_HOME=${q(homeDir)} ${launch}`, true));
    await deliverKickoff(id, harness, prompt);
    metaSetHard(S.meta, "backend", backend);
    metaSetHard(S.meta, "window", S.window);
    metaSetHard(S.meta, "worktree", homeDir);
    metaSetHard(S.meta, "project", "-");
    metaSetHard(S.meta, "project_dir", homeDir);
    metaSetHard(S.meta, "harness", harness);
    recordOpts(harness, model, effort, effortFlag);
    metaSetHard(S.meta, "kind", "crewdeputy");
    metaSetHard(S.meta, "mode", "-");
    metaSetHard(S.meta, "yolo", "off");
    recordSid();
    metaSetHard(S.meta, "spawned_at", iso());
    await turn();
    claimRelease();
    S.trap = null;
    if (!statusSoft(id, "working: crewdeputy spawned")) warn(`crewdeputy ${id} is spawned, but its status line could not be appended`);
    if (!put(1, `spawned ${id} harness=${harness} kind=crewdeputy mode=- yolo=off backend=${backend} window=${S.window} worktree=${homeDir}\n`)) fatal(1);
    return;
  }

  // --- crew path --------------------------------------------------------------
  const projectDirC = projectDir(project) ?? die(`project not found: ${project} (clone it into projects/ first)`);
  const projectName = basename(projectDirC);

  // THE DOMAIN VIEW REFUSAL (above): MEMBERSHIP of the bound domain's view,
  // and the very repository it links.
  const domBound = domainBinding();
  if (domBound !== "") {
    const cls = domainViewEntry(domBound, projectName);
    if (cls !== "ok") die(`crewdomain ${domBound} has no valid '${projectName}' in its project view (crewdomains/${domBound}/projects/ - ${cls}) - a domainchief may only brief work its domain links, and the view must be a symlink resolving into the fleet's own clones. Fix the view (bin/ac-domain.sh validate) or hand the order back to the crewchief.`);
    const want = cdP(`${envHome()}/crewdomains/${domBound}/projects/${projectName}`) ?? "";
    const have = cdP(projectDirC) ?? projectDirC;
    if (want === "" || want !== have) die(`crewdomain ${domBound} links '${projectName}' but this spawn would lease ${have}, not ${want} - a matching basename is not membership. Pass the fleet clone the domain actually links.`);
  }

  // THE BRANCH COLLISION REFUSAL (above).
  const branch = crewBranch(id);
  const branchSha = cap(run(["git", "-C", projectDirC, "rev-parse", "--verify", "--quiet", `refs/heads/${branch}`]).out);
  if (branchSha !== "" && !(await familyOwned(id, sd)))
    die(`${branch} already exists in ${projectDirC} (${branchSha.slice(0, 12)}) and NO task is in flight to own it - it outlived a dead or torn-down task (teardown deletes a crew branch only when it is MERGED), so spawning ${id} would commit onto that foreign history and make its landing diff nonsense. Rename it or delete it - that is YOUR call, this spawn touches no ref:
  keep it:   git -C ${projectDirC} branch -m ${branch} ${branch}-old
  drop it:   git -C ${projectDirC} branch -D ${branch}
then spawn again`);

  // The brief's Mode: line is the per-task mode record; --mode may only agree.
  const modeRead = run(["sed", "-n", "s/^Mode: //p", brief], { stderr: "ignore" });
  ee(modeRead.status);
  let mode = cap(modeRead.out.split("\n")[0]!);
  if (modeFlag !== "") {
    if (!["crew-ship", "direct-pr", "local-only", "feature-pr"].includes(modeFlag)) die(`invalid --mode: ${modeFlag} (want crew-ship|direct-pr|local-only|feature-pr)`);
    if (mode !== "" && mode !== modeFlag) die(`--mode ${modeFlag} contradicts the brief's recorded Mode: ${mode} - re-scaffold the brief (the mode record) rather than spawning a different contract than the crewmate was briefed on`);
    mode = modeFlag;
  }
  if (mode === "" && !scout) die(`no 'Mode:' line in ${brief} - re-scaffold with ac-brief.sh (mode is per-task now; the registry default is gone)`);
  // yolo stays per-project - the ONE thing the registry still answers.
  const pm = run([`${binDir}/ac-project-mode.sh`, projectName], { stderr: "ignore" });
  const yoloLine = cap(pm.status === 0 ? pm.out : `${pm.out}yolo=off\n`);
  const yi = yoloLine.lastIndexOf("yolo=");
  const yolo = yi < 0 ? yoloLine : yoloLine.slice(yi + "yolo=".length);
  if (!scout && mode === "crew-ship" && review !== "yes") die(`crew-ship execution requires review=yes in ${brief}`);

  // The harness: the shared crew-dispatch resolution, only its harness rung.
  const prof = resolveProfile(["--harness", harnessFlag]);
  ee(prof.status);
  const ph = tabFields(u8(prof.out), 3)[0]!;
  const harness = ph.startsWith("harness=") ? ph.slice("harness=".length) : ph;
  // SHARP EDGE (above): a config-fallback model is dropped on a KNOWN
  // built-in other than the fleet's own harness.
  if (harnessKnown(harness) && !modelExplicit && harness !== configReadSoft("crew-harness", "claude")) model = "";
  const kind = scout ? "scout" : "ship";
  const l = spawnLaunch(harness, model, effortFlag, brief, id);
  ee(l.status);
  launch = l.out;
  const first = launch.split(" ")[0]!;
  if (!launchable(first)) die(`harness binary not found: ${first}`);

  // The lease: an Orca-managed worktree on an orca fleet, the in-repo pool
  // otherwise (a resume asks for its old slot back).
  let worktree: string;
  await turn();
  if (backend === "orca") {
    const ls = orcaWorktreeLease(id, projectDirC, baseBranch);
    await turn();
    if (ls.status === 2) die(`the epic-branch fence refused the orca lease for ${id} (reason above)`);
    if (ls.status !== 0) die(`orca worktree create failed for ${id} (is the Orca runtime running, and the repo registered? orca repo add --path ${projectDirC})`);
    worktree = ls.out;
    if (resumeWt !== "" && worktree !== resumeWt) warn(`resume may not find the old session (cwd changed: ${resumeWt} -> ${worktree})`);
  } else {
    const get = run([`${binDir}/ac-tree.sh`, "get", "--repo", projectDirC, "--id", id, "--holder", `crew:${id}`, ...(resumeWt !== "" ? ["--prefer", resumeWt] : [])]);
    await turn();
    ee(get.status);
    worktree = cap(get.out);
    if (resumeWt !== "" && worktree !== resumeWt) warn(`resume may not find the old session (cwd changed: ${resumeWt} -> ${worktree})`);
  }
  S.worktree = worktree;
  codegraphWorktree(projectDirC, worktree);
  S.trap = spawnFailedCleanup;
  const deps = scout ? "" : leaseInstall(id, projectDirC, worktree);
  await turn();

  // The crewmate layer, settings, skills and port slot, where the RESOLVED
  // harness reads them; a fallback path is named in the kickoff prompt.
  const seedFallback = seedCrewmateMd(worktree, harness);
  seedCrewSettings(worktree);
  ee(seedCrewSkills(worktree, harness));
  if (seedPortsEnv(worktree, projectName) === null) warn(`could not seed a port slot for ${worktree} - listeners in this worktree may collide with a sibling's`);

  const rc = alive(id);
  if (rc === 0) die(`window ${target(id)} already exists`);
  if (rc !== 1) die(`the BACKEND could not be READ for ${id} - whether ${target(id)} still exists is UNKNOWN, so this spawn is REFUSED rather than open a second window beside a possibly LIVE one; check the backend itself (herdr status server), then spawn again`);
  ended(backendWindowNew(id, worktree));
  S.window = target(id);

  let prompt = `You are an agent-crew crewmate. Read and follow the brief at ${brief}. Work only inside this worktree.`;
  if (seedFallback !== "") prompt += ` Read ${worktree}/${seedFallback} first - the fleet-wide crewmate instructions, which this repo's own instruction file does not carry.`;
  // The epic-branch fence's crewmate-facing half: the base and the landing
  // target made explicit; silent without a record.
  const eb = epicBaseFor(id, projectName);
  if (eb.rc === 2) die(`cannot read the ledger to resolve the epic-branch fence for ${id}`);
  if (eb.rc === 0) {
    const ebBranch = u8(eb.entry.split(" ")[0]!);
    prompt += ` INTEGRATION BRANCH: this worktree is cut from ${ebBranch} and your work lands INTO ${ebBranch}, never the default branch - branch crew/${id} from it as usual, and any PR you are told to open targets ${ebBranch}.`;
  }
  if (deps === "failed") prompt += " DEPENDENCIES: the project's commands.install failed in this worktree - install the project's dependencies yourself before running any test or build, so a missing module is not read as a regression.";
  const fleetEnv = crewEnv({ projectDir: projectDirC });
  ee(sendLine(id, `${launchPromptEnv(harness, prompt)}${u8(claudeConfigEnv())}${CODEGRAPH_ENV}${fleetEnv}${launch}`, true));
  await deliverKickoff(id, harness, prompt);

  metaSetHard(S.meta, "backend", backend);
  metaSetHard(S.meta, "window", S.window);
  metaSetHard(S.meta, "worktree", worktree);
  if (backend === "orca") {
    metaSetHard(S.meta, "worktree_backend", "orca");
    if (baseBranchSet) metaSetHard(S.meta, "lease_base", baseBranch);
  }
  metaSetHard(S.meta, "leases", worktree);
  // lease_ids: the per-ACQUISITION identity of each leases= entry, read from
  // the slot meta (empty when the pool predates lease ids).
  metaSetHard(S.meta, "lease_ids", metaGetSoft(`${projectDirC}/.crew/slots/${basename(worktree)}.meta`, "lease_id"));
  metaSetHard(S.meta, "project", projectName);
  metaSetHard(S.meta, "project_dir", projectDirC);
  const scope = process.env.AC_SCOPE ?? "";
  if (wakeScopeOk(scope)) metaSetHard(S.meta, "fleet_scope", scope);
  metaSetHard(S.meta, "harness", harness);
  recordOpts(harness, model, effort, effortFlag);
  metaSetHard(S.meta, "kind", kind);
  metaSetHard(S.meta, "mode", mode);
  metaSetHard(S.meta, "review", review);
  metaSetHard(S.meta, "yolo", yolo);
  if (deps !== "") metaSetHard(S.meta, "deps", deps);
  recordSid();
  metaSetHard(S.meta, "spawned_at", iso());
  await turn();
  statusHard(id, "working: spawned");
  // The Slack task thread under remote-mirror=on: the scoped session's family
  // thread, else the id's own family. Best-effort.
  if (configReadSoft("remote-mirror", "off") === "on") {
    const fam = wakeScopeOk(scope) ? scope : familyOfId(id);
    const body = `🚀 *[${u8(vnTs().stamp)}] [START] [${fam}]*\n• bắt đầu task ${id} (${kind}) trên repo ${projectName} - mode=${mode}\n`;
    run([`${binDir}/ac-remote.sh`, "thread-post", fam], { stdin: Buffer.from(body, "utf8"), stdout: "ignore", stderr: "ignore" });
  }
  await turn();
  claimRelease();
  S.trap = null;
  if (!put(1, `spawned ${id} harness=${harness} kind=${kind} mode=${mode} yolo=${yolo} backend=${backend} window=${S.window} worktree=${worktree}\n`)) fatal(1);

  function recordOpts(h: string, m: string, e: string, applied: string): void {
    try {
      recordLaunchOpts(S.meta, h, m, e, applied);
    } catch (err) {
      fatal((err as { status?: number }).status ?? 1);
    }
  }
  function recordSid(): void {
    const sid = launchSessionId(launch);
    ee(sid.status);
    if (sid.out !== "") metaSetHard(S.meta, "session_id", sid.out);
  }
}

if (import.meta.main) {
  const { args } = enterCaller(process.argv.slice(2));
  // The cleanup trap runs at every exit while armed: a die, a refusal's
  // status, a signal.
  process.on("exit", () => {
    const t = S.trap;
    S.trap = null;
    if (t) t();
  });
  for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) process.on(sig, () => process.exit(128 + n));
  let rc = 0;
  try {
    await main(args);
  } catch (e) {
    if (typeof (e as Exit).exit !== "number") throw e;
    rc = (e as Exit).exit;
  }
  process.exit(rc);
}
