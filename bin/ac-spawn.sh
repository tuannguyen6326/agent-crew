#!/usr/bin/env bash
# ac-spawn.sh - spawn a crewmate: lease an in-repo worktree, open a window on
# the session backend (a herdr tab), and launch
# the harness with the brief. Also spawns crewdeputies: persistent supervisors
# that run in their own seeded home instead of a project worktree.
#
# Usage: ac-spawn.sh <id> <project-name-or-dir> [--scout] [--mode <m>]
#                    [--harness <claude|codex|opencode|pi|cursor|custom>] [--model <name>]
#                    [--effort <low|medium|high|xhigh|max|ultracode>]
#                    [--backend <herdr>]
#                    [--resume-from <old-task-id>]
#        ac-spawn.sh <id> --crewdeputy [--recover] [--harness <h>] [--backend <b>]
#        ac-spawn.sh --roomchief <family> [--harness <h>] [--backend <b>]
#                    [--captain-initiated "<order ref>" | --system-initiated "<order ref>"
#                     | --over-cap "<sanction>"]
#
# --roomchief promotes a hot room: a dedicated claude session (id
# <family>-chief) that owns ONLY that family's stages and gates, talks to
# the captain in its own thread, posts everything to the family room, and
# never touches the backlog/registry (the crewchief keeps those). It runs
# in the agent-crew checkout (no worktree lease, no brief - the room IS
# the brief) with AC_SCOPE=<family> exported.
#
# A promote whose family row carries the domain:<name> token becomes a
# DOMAINCHIEF - the same session kind, carrying a domain. Its meta stays
# kind=roomchief and gains domain=<name>, its launch line gains AC_DOMAIN
# beside AC_SCOPE, and its kickoff gains the domain section. The binding is
# DERIVED from the assignment, so there is no flag. The "never touches the
# backlog" clause above is the FLEET ledgers only: a domainchief moves its
# family's row through crewdomains/<name>/records/backlog.md (it may never mint
# one there) and may enrich that package's records/projects.md, while
# bin/ac-ledger-guard.sh keeps both fleet ledgers and records/captain.md out of
# every scoped session's reach.
#
# THE ORDER GATE. Because the room IS the brief, the promote is gated on it: a
# family room holding no ENTRY - the `- [` line shape ac-room.sh's cmd_post
# writes, never the file's mere existence (post creates it with a `# Room:
# <family>` header before any entry) - refuses fail-CLOSED, naming the
# post-then-promote fix. Promote-then-ac-send left the new chief orienting on an
# empty room and re-triaging when the order landed, two sources of truth for one
# task; refusing costs one command, an orderless roomchief costs a wrong triage.
# ANY entry passes, so bin/ac-learn.sh's charter-first autoroom (charter posted,
# THEN promote) needs no exemption and the hot-room upgrade this flag was built
# for is unaffected. It fires with the cap - after it - and before any window,
# lease or meta, so the exit-status contract below holds.
#
# Promotion is CAPPED, fail-closed: at most config/room-parallel (default 5,
# captain-pinned) roomchiefs in flight at once. Five concurrent chiefs hit
# session limits, stalled, and let their scoped watchers die un-re-armed
# (2026-07-16) - the cap is the backstop. The population counted is the state
# metas named <family>-chief whose kind is roomchief (a crewdeputy never holds
# a room slot); PRESENCE of the meta is what holds one, matching how the rest
# of the fleet defines in flight, so a chief stops counting exactly when
# ac-teardown.sh archives its meta. Counting presence rather than probing the
# backend keeps the error fail-CLOSED: a chief whose window died but whose meta
# is unarchived still holds its slot, refusing a promote that would have fit -
# whereas a backend hiccup read as "not live" would let the 6th chief in, which
# is the failure the cap exists to prevent. Past the cap the promote refuses,
# naming the flying families, before any window or meta exists. A non-numeric
# knob clamps to the default (the config/epic-parallel idiom) - it never
# refuses on its own.
# ALSO counted: any OTHER family's live pre-meta claim (state/.meta-claims/
# <family>-chief/) not yet backed by a meta - a promote's own meta is not
# written until after deliver_kickoff settles (AC_SPAWN_SETTLE, several
# seconds), so two concurrent promotes for DIFFERENT families would otherwise
# both claim, both read the SAME (empty) meta population, and both pass,
# landing cap+1 chiefs. An in-flight claim's eventual initiated_by is not
# knowable from outside, so it counts as non-exempt (fail-closed); a claim
# past the same staleness grace spawn_meta_claim_acquire itself uses (dead
# owner) does not count - it is an abandoned pre-meta window, not a live
# promote.
#
# ORIGIN + CAP-GATE. Every roomchief meta records who initiated the promote:
# initiated_by=chief (default), initiated_by=captain or initiated_by=system,
# written beside kind. The cap counts ONLY chief-initiated (non-exempt) chiefs -
# a meta whose initiated_by is EXACTLY captain or system is EXEMPT and consumes
# no slot, while an ABSENT field - or any near-miss value (systemic, System,
# " system") - counts as chief-initiated (fail-closed: a pre-origin or typo'd
# meta must never silently open a slot). THREE mutually-exclusive flags gate a
# promote against that cap - at most one per promote, since a promote has
# exactly ONE origin (the meta has one initiated_by) and an already-exempt
# promote makes a sanction to exceed the cap meaningless:
#   --captain-initiated "<order ref>"  a captain-ORDERED promote. Non-empty ref
#       required. Writes initiated_by=captain, is EXEMPT (promotes even at a
#       full cap, needs no sanction), and posts a DECIDED: receipt naming the
#       family, the order ref, and that it does not count toward the cap.
#   --system-initiated "<order ref>"  a promote the FLEET made by itself on a
#       STANDING captain rule - nobody decided it now. Non-empty ref required,
#       and it names that rule. Writes initiated_by=system, is EXEMPT exactly
#       like captain, and posts a DECIDED: receipt saying `standing order:` -
#       the word that tells the captain this promote rode a rule they wrote
#       once, not a request they made now. That distinction is the whole reason
#       it is a third value and not a borrow of =captain: a receipt that named
#       the captain would tell them they ordered a promote they did not order,
#       and a later revocation of the standing rule could not find the rooms
#       that rode it. EXACTLY ONE caller in the distro passes it (a one-line
#       grep): `ac-learn.sh autoroom`, the DISTILL auto-trigger, carrying
#       records/captain.md "Learning room is chief-created and CAP-EXEMPT
#       (2026-07-21)". Deliberately NOT authenticated - like both siblings it
#       is a string nobody verifies; the control is the receipt plus the
#       captain's post-hoc veto.
#   --over-cap "<sanction>" (or env AC_ROOM_OVERCAP_REASON)  the crewchief's
#       ask-to-bypass for ONE extra chief-initiated slot past a full cap. Non-
#       empty sanction required when at the cap. Writes initiated_by=chief,
#       promotes past the cap EXACTLY ONCE (this spawn only - no persistent
#       state, config/room-parallel is NEVER written), and posts a DECIDED:
#       receipt naming the family, that it is +1 past room-parallel=<cap>, and
#       the captain sanction. Under the cap it is a no-op (no bypass, no receipt).
# This RETIRES the bump-config-then-restore hack (racy, and briefly misstates
# the default cap on disk). Worked example (room-parallel=1): with
# dashboard-improve-chief marked captain-initiated (exempt), the single
# chief-initiated slot is FREE - a chief-initiated promote fits with no
# --over-cap sanction. That is why ask-to-bypass is the exception, not the
# baseline. All THREE DECIDED: receipts are IN ADDITION to the existing
# PROMOTED: post, and all of them are written AFTER the meta - which fixes the
# meaning of a --roomchief exit status: non-zero means NO meta was written and
# the promote can be retried, while a failure in the post-meta bookkeeping tail
# (status line, PROMOTED:, DECIDED:) WARNS by name and still exits 0, because
# past the meta the chief exists and teardown owns it. An automatic caller
# (ac-learn.sh autoroom) retries on non-zero, so a tail failure reported as a
# failed promote would strand a real room behind a "retrying" message.
#
# claude spawns pin a session id (`--session-id`, recorded as session_id=
# in the meta). --resume-from <old-id> reopens that recorded claude session
# (`claude --resume`) - for same-stage revisions where the old context is
# worth keeping. Role changes and code-review never resume.
# claude keys sessions by their cwd, so a resume asks the pool for the old
# task's exact worktree slot back (worktree= from its meta, passed as
# ac-tree.sh get --prefer); when that slot cannot be honored the spawn still
# proceeds but warns loudly:
#   resume may not find the old session (cwd changed: <old> -> <new>)
# Non-resume spawns lease exactly as before (no --prefer).
#
# LEASES (the authoritative grammar): the crew meta records
#   leases=<path>[:<path>...]
# every pooled worktree the task holds, colon-separated - and ac-teardown.sh
# returns EACH one, not just the primary tree. A spawn takes exactly one lease,
# so the list normally has a single entry equal to worktree=; anything that
# leases a SECOND tree for the same task (a qa e2e companion checkout, taken
# by calling `bin/ac-tree.sh get --id <this task's id> ...` again) has its path
# appended here automatically - `ac-tree.sh get` itself does the append, the
# moment it sees state/<id>.meta already on disk - and that append is the whole
# mechanism by which teardown gives it back. The task's OWN first lease never
# triggers it: spawn/self-task write state/<id>.meta only after that first
# `get` returns, so the append is silently a no-op until the meta exists (also
# why a verifier's distinct id, which never gets a crew meta at all, never has
# one minted for it either). worktree= keeps its own meaning - the
# PRIMARY tree, the crewmate's cwd, which every other script resolves - and a
# meta written before leases= existed carries only worktree=, which teardown
# reads as a one-entry list (back-compat, no migration). Chief and crewdeputy
# metas hold no pool lease and carry no leases=.
# lease_ids=<id>[:<id>...] runs ALONGSIDE leases=, one entry per path in the
# same order: the per-acquisition identity teardown hands back as `ac-tree.sh
# return --if-lease-id`, so a late return refuses instead of resetting a slot
# that has since been re-leased. Absent (old meta, or a pool that predates the
# id) means teardown returns unconditionally, as it always did.
#
# Requires an existing brief, resolved with ac_task_dir: flat data/<id>/brief.md
# for direct tasks, nested data/<family>/<stage>/brief.md for staged flows,
# nested data/<family>/tasks/<slug>/brief.md for a scoped chief's fan-out
# sub-tasks (ac-brief.sh scaffolds it and owns the layout contract).
# On success prints:
#   spawned <id> harness=<h> kind=<ship|scout|crewdeputy> mode=<mode> yolo=<on|off> backend=<b> window=<target> worktree=<path>
#
# The backend comes from --backend, else config/backend, else herdr, and is
# recorded in the task meta so every later script drives the same backend.
# When config/crew-dispatch.json exists, crew spawns REFUSE to guess the
# harness: pick a profile with ac-dispatch-select.sh (--list / --rule) and
# pass --harness/--model/--effort explicitly.
# Model and effort are fleet-wide defaults: absent --model/--effort fall back
# to config/model and config/effort (like config/crew-harness). --model maps to
# claude --model / codex -m / pi --model; the --effort FLAG is claude-only, but
# the effort VALUE also reaches codex (-c model_reasoning_effort=<e>) and pi
# (--thinking <e>, verified pi 0.84.2); opencode ignores it. Effort is validated against
# low|medium|high|xhigh|max|ultracode before anything is spawned.
# effort=ultracode is the claude preset: the launch line gets --effort xhigh and,
# once the built-in claude TUI is up, '/effort ultracode' is typed in to add the
# workflow-orchestration layer (claude built-in only; codex/opencode and custom
# launch-claude templates get no slash line). AC_ULTRACODE_SETTLE (default 2)
# is the pause after that line before the kickoff prompt.
# PER-ROLE knobs (captain's call): the two VERIFICATION panes get their own
# defaults - claude opus - decoupled from the fleet crewmate model. Delivery stays
# with the execution crewmate; there is no separate ship-stage model lane. The reviewer (ac-ship.sh review-agent,
# --kind codereview) and qa (ac-qa.sh agent) run as homeless panes, so ac-spawn
# resolves config/<role>-{agent,model,effort} HERE and threads them as
# AC_FLEET_{AGENT,MODEL,EFFORT}_{CODEREVIEW,QA} (only when set; else ac-pane-agent
# applies its own per-role defaults: claude for agent, opus for model, and the
# shared fleet ladder for effort). The three are ONE rung in the pane's ladder,
# so an agent pin and its model/effort are chosen together - never a model
# composed onto a harness a different rung picked.
# On the same rung, and above those two: AC_FLEET_PROFILE_CODEREVIEW /
# AC_FLEET_PROFILE_QA, the DISPATCHED pane profile from config/crew-dispatch.json's
# `panes` block (contract: the PANE PROFILE block in ac-pane-agent.sh; resolver:
# ac-backend.sh ac_pane_profile). ONE scalar per kind carrying the whole
# `harness=<h> model=<m> effort=<e>` triple rather than three variables, so the
# profile stays ATOMIC on the wire and the pane can honour an empty model as the
# harness's own default. Only these two kinds: ac-learn.sh's scout is homed and
# reads the block first-hand. Emitted only when a profile resolves, so a fleet
# with no `panes` block leaves this launch line byte-identical.
# codereview's rung has ONE extra knob, --codereview-rule <number|default>
# (captain ruling 2026-07-28, routed-pane-rules-for-gate-codereview-roomchief,
# second round): a routed panes.codereview's rules[] is otherwise unreachable
# forever - an execution crewmate never gets AC_HOME (see the AC_HOME pin
# below) and every codereview call chain (ac-verify.sh, ac-ship.sh's
# review-agent) passes ac_pane_profile's resolved value straight through with
# no selector of its own - so THIS is the one and only place any agent is
# ever in a position to judge a `when` clause, and it judges ONCE for the
# crewmate's whole life, not per round. With no flag this rung is
# byte-identical to before (ac_pane_profile, no --rule). With the flag, a
# selector that fails to resolve DIES here before any window/meta is opened -
# never a silent fall-through to a default the caller did not ask for.
# The resolved model/effort ALSO ride the crewmate launch line as the scalars
# AC_FLEET_MODEL / AC_FLEET_EFFORT (raw value - ultracode stays ultracode; each
# consumer maps it for its own surface). A crewmate gets no AC_HOME, so the pane
# agents it later starts (ac-pane-agent.sh: the codereview reviewer, ac-qa.sh
# agent) cannot read config/ at all and used to judge on claude's own default
# while the fleet was pinned elsewhere (live 2026-07-15: an opus-pinned fleet
# reviewed on claude-fable-5). Narrow scalars carry exactly that knowledge and
# nothing more - handing over AC_HOME instead would give every crewmate the whole
# fleet home, which ac-qa.sh's "the path travels in the brief, not the environment"
# block and ac-pane-agent.sh's refusal to fabricate a home both exist to prevent.
# On the same rung and for the same reason: AC_FLEET_NAME, the fleet token every
# herdr workspace label is built from (ac-lib.sh ac_fleet_name). Homeless, that
# helper can only answer its fixed fallback, so every observation tab a crewmate
# opens - ship watch, qa watch, the pane agents - landed in the ONE group shared
# by every fleet on the box instead of its own. Resolved HERE where AC_HOME is
# valid and threaded as the NAME alone.
# Prefixed OUTSIDE build_launch so a verbatim custom launch-<h> template passes
# them on too. SHARP EDGE: config/model is harness-specific in VALUE, so a fleet
# pinned to a codex model hands that name to a claude pane agent - the same
# pre-existing hazard as the config/model fallback inside ac-pane-agent.sh. THE
# CREW PATH HALF of this is now guarded (below, where the harness rung
# finally resolves): a config-fallback model that does not match the resolved
# harness is dropped rather than composed onto it. The ac-pane-agent.sh half
# is untouched and stays open.
# On the same rung, but a KILL-SWITCH rather than a pin: CODEGRAPH_NO_PROMPT_HOOK
# rides EVERY crew launch line (crewmate, roomchief, scout, crewdeputy). Its
# value never varies, so it is the constant $codegraph_env. codegraph's global
# UserPromptSubmit front-load hook up-walks up to 6 levels for an index, so every
# fleet cwd under a container-wide index queries that whole graph; a roomchief
# kickoff mandate trips codegraph's structural gate and measured 161.72s against
# Claude Code's 30s hook budget (diagnosis 2026-07-21), while a crewmate prompt
# short-circuits at the gate in 0.08s. The var makes the hook a 0.07s no-op. It
# disarms the front-load NUDGE only - the codegraph_explore MCP tool a pane calls
# deliberately stays available - and is scoped to the panes this script launches,
# touching no global codegraph or claude config.
# Fleet-wide crewmate instructions ($AC_HOME/CREWMATE.md) are copied into the
# instruction file the RESOLVED harness actually loads - AGENTS.md for codex and
# opencode, .claude/CLAUDE.md for everything else - and the fleet harness settings
# into the worktree's .claude/settings.json. A copy the repo ships itself wins
# for both; the instructions then land at .claude/CREWMATE.md, a path NO harness
# loads, so ac_seed_crewmate_md prints it and the KICKOFF PROMPT below names it
# as required reading - the only channel left to that crewmate. A copy the SEED
# itself wrote is REFRESHED when the sources move on, so a long-lived pool
# lease stops running its crewmate on the rules of whenever it was first leased
# (resolution ladders, the ownership stamp and its evidence: ac-lib.sh
# ac_seed_crewmate_md / ac_seed_install / ac_seed_crew_settings).
# Crewdeputies run with AC_HOME pointed at their seeded home
# ($AC_HOME/crewdeputies/<id>, see ac-home-seed.sh) and never lease a worktree.
#
# GUARDED CREWDEPUTY RECOVERY (--recover, requires --crewdeputy). AUTHORITATIVE
# for how a dead crewdeputy comes back. It exists as a flag here rather than a
# separate verb because the refusal it must relax lives here, and because
# recovery ENDS in an ordinary crewdeputy spawn: teardown-then-spawn cannot do
# the job, since crewdeputy teardown refuses while the deputy's home holds crew
# in flight - precisely when the deputy is most needed back. Recovery is never
# automatic (a digest may run read-only, and a false-dead reading would double-
# spawn a live deputy); it is one deliberate command that dies at the first
# failure of this ladder:
#   1. the id has a parseable routing-table entry - else there is nothing to
#      recover (ac-lib.sh owns the grammar);
#   2. its home exists and carries .ac-crewdeputy-home - else HOME-MISSING,
#      which is a captain decision (repair or remove the line), not a recovery;
#   3. any existing window is CONFIDENTLY not alive - a live pane is never
#      double-spawned;
#   4. a stale meta and its status log are RETIRED to their own slot under
#      state/archive/<id>/<stamp>/, never deleted, so the routed-order history
#      of EVERY earlier epoch stays readable (a deputy is recovered repeatedly,
#      unlike a crewmate id, which teardown archives exactly once);
#   5. control falls through to the ordinary crewdeputy spawn path.
# The deputy's OWN home is never touched: its crew keeps running, its worktrees
# keep their leases, its backlog and rooms survive, and the restored deputy
# reconciles them at its own session start. Recovery is not a teardown bypass.
# Harness launch commands come from config/launch-<harness> when present
# (placeholders __BRIEF__ and __ID__ are substituted); otherwise a built-in
# template per harness is used.
#
# Kickoff-prompt delivery: built-in templates launch the harness BARE (no
# positional prompt arg) because a positional "$AC_PROMPT" does NOT auto-submit
# in an interactive claude TUI - it left the crewmate idle until a manual steer.
# Instead every path (crew/crewdeputy/roomchief) sends the launch line, waits
# AC_SPAWN_SETTLE seconds (default 8) for the harness to come up, then delivers
# the prompt as its OWN line via backend_send_line.
# The CAME-UP GATE sits between those two, and it is FAIL CLOSED. A harness can
# die at launch - a --resume-from whose session id claude did not recognise
# printed "No conversation found with session ID ..." and EXITED, dropping the
# pane back to zsh (live incident 2026-07-21) - and the kickoff prompt was then
# typed into that SHELL: `zsh: command not found: You...`, after which the dead
# pane sat silent until a stale wake minutes later. So deliver_kickoff first
# asks backend_harness_up (its three states and their evidence are
# ac-backend.sh's contract) and, when the pane is back at a bare shell,
# withholds the kickoff prompt and kills the spawn with ac_die - naming the
# pane's last lines, so the harness's own error travels with the failure. A
# built-in codex pane may already have taken the single pre-gate
# startup-dialog Enter before this point (contract: THE CODEX STARTUP-DIALOG
# ANSWER below); every other pane got no keystroke at all. The ordinary
# cleanup trap then reaps the window and returns the lease, leaving no
# half-spawned task, and the refusal is appended to state/<id>.status. The
# chief sees it AT SPAWN TIME and
# recovers now. An UNOBSERVABLE probe (2) is NOT a dead pane: it warns and
# delivers exactly as before - refusing there would ground the fleet on a herdr
# hiccup. Auto-recovery is deliberately not attempted; the required property is
# only "never type a kickoff into a shell, never sit silent on a dead pane".
# The gate runs TWICE, because it answers "was the harness up BEFORE I typed"
# and a harness can die ON the kickoff itself. The POST-KICKOFF RE-CHECK is the
# same probe, run again after the prompt is delivered, refusing the spawn the
# same fail-closed way (status `failed:`, ac_die, trap reaps the window) and
# warning-only on an UNOBSERVABLE 2. It exists because a spawn once reported
# SUCCESS - and ac-crew-state.sh said `working: spawned` - over a codex that was
# already dead at a zsh prompt (live incident 2026-07-21, the codex-crewmate
# probe): the pre-kickoff gate saw a healthy pane because the death came after
# it, and backend_send_line's render-change probe read the kickoff as ACCEPTED
# because the render changed - by the app DYING. A render-change probe cannot
# tell "the composer took my line" from "the app I typed into exited"; only
# re-asking whether a harness still holds the pane can. What that refusal may
# CLAIM is bounded by what the probe saw - non-shell at the gate, all-shell
# after - so it reports the harness as no longer up and names the kickoff as the
# LIKELY cause, never as an established one: the probe cannot show the prompt
# was accepted, nor exclude an unrelated exit in the interval.
#
# THE CODEX STARTUP-DIALOG ANSWER (the authoritative contract). codex opens on a
# TRUST DIALOG before its composer exists ("Do you trust the contents of this
# directory?", options `1. Yes, continue` / `2. No, quit`), and that dialog is a
# key-driven SELECT: an `n` or a `2` ANYWHERE in typed text picks "No, quit" and
# codex exits ~0.4s later. Every English kickoff prompt carries an `n`, so at a
# BUILT-IN codex pane the prompt is never the first thing typed - deliver_kickoff
# sends a bare Enter first, which takes the highlighted "1. Yes, continue", then
# settles AC_SPAWN_SETTLE again so the TUI can draw. That Enter goes BEFORE the
# came-up gate, deliberately: the EXISTING gate then covers the Enter's
# aftermath, so no third probe is needed and the invariant holds without new
# machinery - and an Enter typed into a pane whose harness never came up is a
# bare newline at a shell prompt, which is inert. A CUSTOM config/launch-codex
# template gets NO Enter: its TUI is unknown, so a keystroke borrowed from the
# built-in codex TUI is the caller's business - the same rule the '/effort
# ultracode' line already follows for a custom launch-claude. On a host
# where the dialog does NOT appear (trust already persisted) that Enter lands on
# an empty composer, where the fix probe reported it a no-op - a reading marked
# NOT REPLAYABLE in harness-facts.md, and one nothing here depends on: an Enter
# that DID end the harness is caught by the gate it now precedes. Two
# consequences the fleet
# owns: answering PERSISTS `[projects."<repo-root>"] trust_level = "trusted"`
# into the host's ~/.codex/config.toml (so the fleet auto-trusts the repo it
# spawned into - the same posture as claude's --permission-mode auto), and a
# green codex spawn on a host that already carries that entry proves nothing
# about a fresh one. `-c projects."<root>".trust_level="trusted"` was tried
# first and REFUTED: codex's trust gate does not consult -c in either direction
# (evidence: .agents/skills/harness-operations/references/harness-facts.md).
#
# THE COMPOSER-READY OBSERVATION (the authoritative contract). Between the
# came-up gate above and the FIRST thing typed after it (the '/effort
# ultracode' line, or the kickoff prompt itself) sits kickoff_wait_input_ready,
# the id-scoped twin of ac-pane-agent.sh's crewmate_wait_input_ready (that
# function's COMPOSER-READY OBSERVATION comment is the sibling contract this
# one mirrors). It requires the SAME two signals together - agent_status=idle
# (arrives too early alone: repo-knowledge by spawn-cameup-render-readiness
# measured claude reading idle at ~340ms while the pane still showed the
# pre-launch shell frame) AND a non-empty render that stays byte-identical
# across three one-second reads (a render alone false-greens on codex's trust
# dialog, which holds a byte-stable non-blank frame for 18+ ticks - same
# repo-knowledge entry) - using the ID-SCOPED twins backend_agent_idle and
# backend_capture, never the _pane variants: this arm holds a
# state/.pane-<id> handle throughout, unlike ac-pane-agent.sh's raw-pane
# callers. The spawn arm carries no EXITMARK/CRCF (cross-arm warning,
# repo-knowledge by codereview-verifier-pane-dies-mid-turn-and-never-returns-
# a-verdict: those belong only to the crewmate ARM ac-pane-agent.sh runs, and
# bin/ac-spawn.sh never touches that file) - its own death signal is
# backend_harness_up, so the loop re-polls it every tick and fails the SAME
# way the came-up gate above does (status failed, ac_die, the EXIT trap reaps
# the window) the instant it reads SHELL (1), rather than waiting out the
# whole readiness budget on a pane that already died. A budget expiring on
# UNOBSERVABLE (2) is NOT a death - the same direction the came-up gate above
# preserves - so it warns and proceeds exactly as an unobservable came-up
# probe does, never refuses. Only a budget expiring while the harness is
# CONFIRMED up (0) - alive, but its input surface never stabilised - fails
# loud: that is the one case this gate exists for, because typing into it
# blind is exactly the silent-green kickoff this function used to produce.
# AC_KICKOFF_READY_BUDGET (default 60 seconds, 1s ticks - the sibling's own
# budget) bounds the wait and is validated up-front like $settle, so a bad
# value fails fast before any window is opened.
# This gate REPLACES only the first of the blind sleep's two jobs (repo-
# knowledge trap, by spawn-cameup-render-readiness: composer readiness AND
# letting a launch-time death settle before the came-up gate reads the pane).
# The existing `sleep "$settle"` calls above are UNCHANGED and still do their
# own job of letting a death settle before the came-up gate probes the pane -
# this gate never touches that job, only adds a real observation where a
# blind sleep used to stand in for one.
# RESIDUAL, stated not solved (the same non-goal the came-up gate's codex
# trust-dialog false-green already lives with): a render-stability signal
# alone cannot distinguish a ready composer from a modal dialog holding the
# same frame - the built-in codex path is covered because its dialog Enter
# already precedes this gate (same ordering as the sibling arm), but a CUSTOM
# config/launch-<harness> template gets no such Enter and inherits the same
# false-green class the came-up gate already carries.
#
# Delivery is ACKNOWLEDGED,
# never blind (the 2026-07-16 eaten-kickoff incident: a booting TUI dropped the
# first Enter, the next send-text APPENDED to the stranded line and garbled
# both into one bad /effort argument): backend_send_line verifies its own
# submit (capture-change probe + one focused retry - contract: ac-backend.sh);
# when it still reports a strand the text already SITS in the composer, so the
# retry re-SUBMITS - never re-types - at most 2 more times, AC_SPAWN_SETTLE
# apart (a booting TUI drops Enter until it is up), then warns LOUDLY naming
# bin/ac-send.sh as the manual fallback. The spawn itself never hangs or dies
# on kickoff delivery. A stranded '/effort ultracode' line additionally
# WITHHOLDS the kickoff prompt (typing it would append to the strand and
# garble both) with the same loud fallback warning. AC_PROMPT is still
# exported on the launch line for custom templates that reference it, but
# built-ins no longer consume it.
#
# ORPHAN-WINDOW SAFETY (the authoritative contract). Between window-create and
# the FIRST byte of state/<id>.meta a task exists only as a tab - and ac-send.sh
# and ac-teardown.sh both key off that meta, so a spawn dying in that gap leaves
# a window NOTHING can address. The gap is real and at least AC_SPAWN_SETTLE
# seconds wide: the launch line goes out through backend_send_line, which
# genuinely returns 1 on a strand, and this script runs under set -e. Three
# guards close it:
#   1. an ATOMIC PRE-META CLAIM (spawn_meta_claim_acquire, one dir per id under
#      state/.meta-claims/), taken before every window CREATE and every REAP on
#      every path - both reap_orphan_window call sites included - and released
#      the instant the meta is COMPLETE. That is the exact ordering invariant,
#      and it is narrower than "before any window call": the --recover ladder
#      probes window liveness earlier, which is a READ that creates and reaps
#      nothing. It is what makes the pre-meta
#      window single-occupancy: a contender blocks in the acquire and then dies
#      on the duplicate-meta check INSIDE the claim, so it never reaches a reap.
#      A dead owner is reclaimed after a grace through the shared PID-aware
#      primitive, so a killed spawn never disarms the id permanently - but the
#      claim's recorded pid is THIS shell, a descendant of whoever called it, so
#      an ac-spawn.sh child outliving a SIGKILLed caller still holds it. That
#      case is precisely what guard 3 below cannot reason about on its own.
#   2. a cleanup trap armed AT window-create and disarmed the moment the meta is
#      COMPLETE - never later: past that point the task is addressable and
#      teardown owns it, whereas a still-armed trap would reap a healthy chief
#      over a failed room post. It removes the partial meta and REAPS the window.
#      The crew path's trap (which already returned the lease) now reaps its
#      window too, and only its own: before it creates one, $window is empty and
#      the window-collision refusal below is left to stand exactly as it was.
#   3. reap-on-collision, on the roomchief and crewdeputy paths. A trap cannot
#      fire on SIGKILL, so a killed spawn still strands a tab - and --recover is
#      crewdeputy-only, so a stranded roomchief tab has no recovery verb at all.
#      Reaching those window checks PROVES no meta exists for this id (the
#      duplicate-meta refusal above dies on one) AND that this spawn holds the
#      claim, so no other spawn for the id is inside its pre-meta window: a live
#      window there is by construction an orphan of exactly this race and is
#      reaped and recreated instead of refused. That premise rests on guard 1
#      and on nothing else - with the claim neutered it is FALSE, measured 5/5:
#      the live window belongs to a CONCURRENT spawn, and reaping it closes the
#      pane that spawn is about to record as its own meta.window. The KILL
#      OWNERSHIP PROOF (authoritative:
#      bin/ac-backend.sh's header) still decides whether the tab actually closes:
#      a tab no longer labelled crew:<id> is a co-tenant, and is refused and
#      warned about, never closed.
#      ONE EXCEPTION: --crewdeputy --recover keeps the REFUSAL. That ladder
#      deliberately leaves state/.pane-<id> behind so this very check can still
#      catch a LIVE deputy its own probe could not answer for (step 3), where
#      reaping would close a living deputy's tab and double-spawn onto its home.
#   Both guards that REFUSE - that one and the crew path's collision check - read
#   the probe's THREE states (authoritative: WINDOW LIVENESS in
#   bin/ac-backend.sh), because only a DEFINITE gone may proceed. ALIVE refuses
#   as "already exists"; a backend that could not be READ refuses too, in its own
#   words naming the BACKEND, since nothing was learned about the pane and
#   proceeding would open a second window beside a possibly live one. Truthiness
#   alone read that as gone, which made the --recover refusal blind to exactly
#   the case it exists for. The hazard predates the three-state probe (a failing
#   probe used to return 1); that probe is only what made it NAMEABLE.
#
# THE BRANCH COLLISION REFUSAL (the authoritative contract). An id is the
# fleet's primary key across meta, status, room, backlog AND branch; the
# duplicate-meta checks validate four of those five, and the one they skip is
# the only one that carries CODE. ac-teardown.sh deletes a crew branch only when
# it is MERGED, so a dead or --force'd task leaves crew/<family> behind (live
# 2026-07-27: crew/learning held 160 commits of pre-scrub history while
# `learning` is the id ac-learn.sh autoroom spawns on its own) - and spawn used
# to take that id anyway, putting the next crewmate's commits on a foreign
# history and making its landing diff nonsense. So the CREW PATH refuses when
# crew/<family> resolves in $project_dir and no in-flight task owns it. Three
# properties, each load-bearing:
#   - It sits in the crew path, AFTER $project_dir resolves, not at either
#     duplicate-meta check: both of those run long before the project is
#     resolved, so neither can name the repo the ref would live in. The
#     roomchief and crewdeputy paths exit before it (neither leases a worktree
#     nor holds a crew branch, and a <fam>-chief id is its OWN family - a
#     roomchief could not collide with crew/<fam> even if it reached here),
#     --recover is crewdeputy-only, and no verify-* meta is written by this
#     script at all (ac-verify.sh owns those panes).
#   - OWNERSHIP is the FAMILY, never the id, because ac_crew_branch collapses
#     every stage/revision id in a family onto ONE branch (ac-lib.sh). A live
#     sibling means the branch is being worked: the fresh-execution-crewmate
#     recovery of AGENTS.md section 5 continues that exact branch, and refusing
#     it would tell the operator to delete a ref holding live unlanded work.
#     Membership is ac_family_owned (bin/ac-lib.sh), using ac_family_of_id -
#     the same derivation the branch name itself comes from, so owner and
#     branch can never disagree. ac_family_owned lives in the shared library,
#     not here, because bin/ac-self-task.sh carries the SAME hazard (it also
#     commits on crew/<id> and lands via ac-merge-local.sh) and calls it too -
#     one predicate, not a second copy that could drift.
#   - The ref is NEVER touched: no auto-delete, no auto-rename, ever. The
#     refusal names the ref, its tip, and BOTH commands (rename to keep the
#     history, -D to drop it), because which one is right is the operator's
#     call and only they know whether those commits matter. It fires before any
#     window, lease or meta, so nothing is left half-spawned.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
. "$(dirname "$0")/ac-wake-lib.sh"
[ ! -x "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true  # warn-only advisory
ac_require git

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

# Empty until THIS spawn has opened its window - which is what lets the cleanup
# traps reap only a window they created (contract: ORPHAN-WINDOW SAFETY above).
window=""
id=""; project=""; scout=0; crewdeputy=0; recover=0; roomchief_family=""; harness=""; harness_flag=""; mode_flag=""
model=""; effort=""; backend=""; resume_from=""; review="-"
captain_initiated=""; captain_initiated_set=0; over_cap=""; over_cap_set=0
system_initiated=""; system_initiated_set=0
codereview_rule=""; codereview_rule_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scout) scout=1; shift ;;
    --crewdeputy) crewdeputy=1; shift ;;
    --recover) recover=1; shift ;;
    --roomchief) roomchief_family="$2"; shift 2 ;;
    --captain-initiated) captain_initiated="$2"; captain_initiated_set=1; shift 2 ;;
    --system-initiated) system_initiated="$2"; system_initiated_set=1; shift 2 ;;
    --over-cap) over_cap="$2"; over_cap_set=1; shift 2 ;;
    --harness) harness_flag="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --effort) effort="$2"; shift 2 ;;
    --backend) backend="$2"; shift 2 ;;
    --resume-from) resume_from="$2"; shift 2 ;;
    --mode) mode_flag="$2"; shift 2 ;;
    --codereview-rule) codereview_rule="$2"; codereview_rule_set=1; shift 2 ;;
    -*) ac_die "unknown flag: $1" ;;
    *) if [ -z "$id" ]; then id="$1"; elif [ -z "$project" ]; then project="$1"; else ac_die "unexpected arg: $1"; fi; shift ;;
  esac
done
# The cap-gate flags are roomchief-only (they gate the room-parallel cap); a
# crew/crewdeputy spawn that passes one is a mistake, not a silent no-op.
[ -n "$roomchief_family" ] \
  || { [ "$captain_initiated_set" = 0 ] && [ "$system_initiated_set" = 0 ] && [ "$over_cap_set" = 0 ]; } \
  || ac_die "--captain-initiated/--system-initiated/--over-cap require --roomchief (they gate the room-parallel cap)"
# --recover relaxes the crewdeputy meta refusal only; on any other spawn it is
# a mistake, not a silent no-op.
[ "$recover" = 0 ] || [ "$crewdeputy" = 1 ] \
  || ac_die "--recover requires --crewdeputy (it is the guarded crewdeputy recovery ladder)"
# --codereview-rule pins panes.codereview at CREWMATE SPAWN TIME (captain
# decision 2026-07-28, routed-pane-rules-for-gate-codereview-roomchief: the
# chief - the only actor ever in a position to judge, since an execution
# crewmate never gets AC_HOME - picks deliberately here, once, for the whole
# crewmate's life). Only a plain crew spawn resolves panes.codereview at all.
[ "$codereview_rule_set" = 0 ] \
  || { [ -z "$roomchief_family" ] && [ "$crewdeputy" = 0 ]; } \
  || ac_die "--codereview-rule requires a plain crew spawn (it resolves panes.codereview, which only threads to an execution crewmate)"
if [ -n "$roomchief_family" ]; then
  # A locale whose collation interleaves case (en_US.UTF-8: a,A,b,B,...,z,Z)
  # makes a plain a-z range admit most uppercase letters through this glob -
  # force C collation for the comparison (LC_ALL=C sort is the same idiom
  # already used for `find`/`sort` elsewhere in this codebase).
  (LC_ALL=C; case "$roomchief_family" in *[!a-z0-9-]*) exit 1 ;; esac) \
    || ac_die "family must be [a-z0-9-]: $roomchief_family"
  [ "$scout" = 0 ] && [ "$crewdeputy" = 0 ] || ac_die "--roomchief excludes --scout/--crewdeputy"
  [ -z "$project" ] && [ -z "$id" ] || ac_die "usage: ac-spawn.sh --roomchief <family> (id is derived: <family>-chief)"
  id="${roomchief_family}-chief"
elif [ "$crewdeputy" = 1 ]; then
  [ -n "$id" ] || ac_die "usage: ac-spawn.sh <id> --crewdeputy [--harness <h>] [--backend <b>]"
  [ "$scout" = 0 ] || ac_die "--crewdeputy and --scout are mutually exclusive"
  [ -z "$project" ] || ac_die "crewdeputies run in their home, not a project (drop '$project')"
else
  [ -n "$id" ] && [ -n "$project" ] || ac_die "usage: ac-spawn.sh <id> <project> [--scout] [--harness <h>] [--model <m>] [--effort <e>] [--backend <b>]"
fi
(LC_ALL=C; case "$id" in *[!a-z0-9-]*) exit 1 ;; esac) || ac_die "id must be [a-z0-9-]: $id"

# Fleet-wide defaults: a missing flag falls back to config/model and
# config/effort so the whole home can pin a model/effort once. An explicit
# flag always wins. Resolved here (before any window/lease) so a bad effort
# value fails fast instead of leaking a half-spawned window.
# model_explicit remembers whether $model came from --model (kept verbatim
# below, whatever harness resolves later) or purely from this config fallback
# (a value the CREW PATH below may still drop - see the SHARP EDGE comment
# near the top of this header).
model_explicit=0; [ -n "$model" ] && model_explicit=1
model="${model:-$(ac_config_read model)}"
effort="${effort:-$(ac_config_read effort)}"
# effort=ultracode is the claude preset (xhigh reasoning + workflow
# orchestration). It cannot ride the --effort CLI flag (which tops out at
# 'max'), so the launch line gets --effort xhigh via $effort_flag and, once the
# TUI is up, deliver_kickoff types '/effort ultracode' into claude. $effort
# stays "ultracode" so the meta records the mode. Both vars are initialized
# unconditionally: an empty $effort must still leave them bound under set -u.
ultracode=0
effort_flag="$effort"
if [ -n "$effort" ]; then
  case "$effort" in
    low|medium|high|xhigh|max) ;;
    ultracode) effort_flag=xhigh; ultracode=1 ;;
    *) ac_die "invalid effort: $effort (expected low|medium|high|xhigh|max|ultracode)" ;;
  esac
fi

state_dir="$(ac_state_dir)"
meta="$state_dir/$id.meta"
meta_claim_root="$state_dir/.meta-claims"
meta_claim="$meta_claim_root/$id"
meta_claim_held=0
meta_claim_owner_subshell=0
meta_claim_owner_pid=""

spawn_meta_claim_release() {
  local owner
  [ "$meta_claim_held" = 1 ] || return 0
  # EXIT traps are visible inside command-substitution subshells. $$ is
  # inherited there, so the generic lock owner check cannot distinguish the
  # copy; BASH_SUBSHELL can, including on the macOS system bash. Only the shell
  # level that acquired the claim may release it.
  [ "${BASH_SUBSHELL:-0}" = "$meta_claim_owner_subshell" ] || return 0
  owner="$(cat "$meta_claim/pid" 2>/dev/null || true)"
  [ -z "$owner" ] || [ "$owner" = "$meta_claim_owner_pid" ] || return 0
  rm -rf "$meta_claim"
  meta_claim_held=0
}

spawn_meta_claim_acquire() {
  # The duplicate-meta check alone cannot serialize the pre-meta window: two
  # callers can both pass it, and the later one can reap the first caller's
  # not-yet-addressable pane. Claim the id before any orphan-window action and
  # hold it until the complete meta is durable. A dead owner is reclaimed by
  # the shared PID-aware lock primitive.
  local timeout="${AC_SPAWN_META_CLAIM_TIMEOUT:-30}" waited=0 owner mtime stale
  mkdir -p "$meta_claim_root"
  # In a shell invoked from command substitution, bash 3.2 can preserve $$ from
  # the caller rather than expose this process. Ask a tiny child for its PPID;
  # that is the actual shell holding the claim and remains probeable by ps.
  meta_claim_owner_pid="$(sh -c 'printf %s "$PPID"')"
  while ! mkdir "$meta_claim" 2>/dev/null; do
    owner="$(cat "$meta_claim/pid" 2>/dev/null || true)"
    mtime="$(ac_file_mtime "$meta_claim" 2>/dev/null || true)"
    stale=0
    case "$mtime" in
      ''|*[!0-9]*) ;;
      *)
        # A pre-meta spawn can legitimately spend several seconds booting its
        # harness. Never reclaim inside that publish window even when a shell
        # wrapper makes its recorded PID temporarily unprobeable.
        if [ "$(( $(ac_now) - mtime ))" -ge "${AC_SPAWN_META_CLAIM_STALE_GRACE:-15}" ]; then
          [ -n "$owner" ] && ac_pid_alive "$owner" || stale=1
        fi
        ;;
    esac
    if [ "$stale" = 1 ]; then
      rm -rf "$meta_claim" 2>/dev/null || true
      [ -d "$meta_claim" ] || continue
    fi
    [ "$waited" -ge "$timeout" ] \
      && ac_die "another spawn still owns the pre-meta claim for $id"
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$meta_claim_owner_pid" >"$meta_claim/pid"
  meta_claim_held=1
  meta_claim_owner_subshell="${BASH_SUBSHELL:-0}"
  if [ -e "$meta" ]; then
    spawn_meta_claim_release
    ac_die "crewmate $id already exists (see $meta); tear it down first"
  fi
}

spawn_meta_claim_cleanup() {
  spawn_meta_claim_release
}

if [ "$recover" = 1 ]; then
  # The guarded recovery ladder (contract: the RECOVERY block in this header).
  dep_home="$(ac_deputy_parse | awk -F'\t' -v i="$id" '$1 != "INVALID" && $2 == i { print $3; exit }')"
  [ -n "$dep_home" ] \
    || ac_die "--recover: no parseable entry for $id in $(ac_deputy_registry) - there is nothing to recover"
  { [ -d "$dep_home" ] && [ -f "$dep_home/.ac-crewdeputy-home" ]; } \
    || ac_die "--recover: HOME-MISSING for $id ($dep_home) - repairing or removing a registry line is a captain decision, not a recovery"
  if [ -e "$meta" ]; then
    # SUBSHELL so a stale meta naming an unsupported backend cannot kill the
    # recovery outright; a probe that cannot answer reads as not-alive, and the
    # ordinary spawn path below re-checks window collision anyway.
    if ( AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND; backend_window_alive "$id" ); then
      ac_die "--recover: $id is LIVE ($(AC_BACKEND="$(ac_task_backend "$id")" backend_target "$id")) - a live pane is never double-spawned"
    fi
    # Retire the stale meta, never delete it: the routed-order history stays
    # readable. Layout mirrors ac-teardown.sh's archive, which owns it, with ONE
    # difference the lifecycle forces: teardown archives an id exactly once, so
    # its fixed state/archive/<id>/ slot is safe, but a crewdeputy is a
    # LONG-LIVED identity recovered repeatedly - a fixed slot would let the
    # second retirement overwrite the first one's routed orders and break A2.
    # So each retirement gets its OWN slot under it, stamped and made unique by
    # mktemp (two recoveries can land in the same second).
    # state/.pane-<id> is deliberately NOT touched: it is what lets the
    # unconditional window-collision check on the crewdeputy path below still
    # resolve the old pane when this ladder's probe could not answer.
    mkdir -p "$state_dir/archive/$id"
    arch_dir="$(mktemp -d "$state_dir/archive/$id/$(ac_now).XXXXXX")"
    mv "$meta" "$arch_dir/meta"
    [ -f "$(ac_task_status "$id")" ] && mv "$(ac_task_status "$id")" "$arch_dir/status"
    ac_warn "--recover: archived the stale meta for $id to $arch_dir"
  fi
fi
[ -e "$meta" ] && ac_die "crewmate $id already exists (see $meta); tear it down first"

# Staged-flow briefs nest under their family (data/<family>/<stage>/brief.md),
# a scoped chief's fan-out sub-tasks under data/<family>/tasks/<slug>/;
# direct tasks stay flat. ac_task_dir resolves by what exists and dies on
# an ambiguous double-brief.
brief="$(ac_task_dir "$id")/brief.md"
if [ -z "$roomchief_family" ]; then
  [ -f "$brief" ] || ac_die "no brief at $brief; run ac-brief.sh first"
fi
if [ "$crewdeputy" = 0 ] && [ "$scout" = 0 ] && [ -z "$roomchief_family" ]; then
  review="$(sed -n 's/^Review: //p' "$brief" | head -n 1)"
  case "$review" in
    yes|no) ;;
    *) ac_die "execution brief must carry exactly one Review: yes|no obligation: $brief" ;;
  esac
fi

# Same-stage revision: reopen the old crewmate's claude session.
resume_sid=""
resume_wt=""
if [ -n "$resume_from" ]; then
  old_meta="$state_dir/$resume_from.meta"
  [ -f "$old_meta" ] || old_meta="$state_dir/archive/$resume_from/meta"
  [ -f "$old_meta" ] || ac_die "--resume-from: no meta for $resume_from"
  [ "$(ac_meta_get "$old_meta" harness)" = "claude" ] \
    || ac_die "--resume-from: $resume_from was not a claude session; spawn fresh with the old report as input"
  resume_sid="$(ac_meta_get "$old_meta" session_id)"
  [ -n "$resume_sid" ] \
    || ac_die "--resume-from: $resume_from has no recorded session_id; spawn fresh with the old report as input"
  # claude keys sessions by cwd: the resumed session only exists under the
  # OLD worktree path, so ask the pool for that exact slot back (--prefer).
  resume_wt="$(ac_meta_get "$old_meta" worktree)"
  harness_flag="claude"
fi

launch_prompt_env() {
  # launch_prompt_env <harness> <prompt> - the AC_PROMPT= prefix for the
  # launch line, ONLY when a custom config/launch-<h> template exists
  # (custom templates may reference $AC_PROMPT). Built-ins never consume
  # it, and the %q-escaped prompt is >1k chars - past the tty canonical
  # buffer of a fresh pane's shell, it TRUNCATES the launch line and
  # beheads the actual command (live incident: sample-family-chief).
  local h="$1" prompt="$2"
  if [ -f "$(ac_config_dir)/launch-$h" ]; then
    printf 'AC_PROMPT=%q ' "$prompt"
  fi
}

# The codegraph front-load prompt-hook kill-switch, on every crew launch line
# (contract: the CODEGRAPH_NO_PROMPT_HOOK block in this header). A constant, not
# a pin: nothing about the fleet or the task changes it.
codegraph_env="CODEGRAPH_NO_PROMPT_HOOK=1 "

launch_session_id() {
  # launch_session_id <launch-line> - the claude session id the line pins
  # (--session-id) or resumes (--resume); empty for other harnesses.
  printf '%s\n' "$1" | sed -n \
    -e 's/.*--session-id \([0-9a-f-]\{8,\}\).*/\1/p' \
    -e 's/.*--resume \([0-9a-f-]\{8,\}\).*/\1/p' | head -n1
}

build_launch() {
  # build_launch <harness> - compose THIS spawn's launch command; reads $model,
  # $effort_flag and $resume_sid. Runs in a subshell: the caller recovers the
  # pinned claude session id with launch_session_id, never via variables set here.
  # The per-harness command itself belongs to ac_build_launch (ac-backend.sh -
  # the shared launch mote, so a new harness is added once for crewmates AND
  # pane agents). What stays here is the SPAWN-only half:
  #   - a custom config/launch-<h> template, emitted verbatim with
  #     __BRIEF__/__ID__ substituted - it needs this spawn's brief and id, which
  #     no other mechanism has;
  #   - the fresh --session-id this spawn PINS, because a crewmate session must
  #     be resumable by id later (--resume-from) and the meta records it; a
  #     one-shot pane turn pins none.
  # $effort_flag is the effort VALUE this spawn resolved: ac_build_launch maps it
  # to claude's --effort flag and to codex's -c model_reasoning_effort override
  # (codex has no effort flag; opencode ignores it). For effort=ultracode it is
  # xhigh (the preset's reasoning tier - the '/effort ultracode' TUI line is
  # sent by deliver_kickoff).
  # Built-in templates start the harness BARE (no positional prompt arg): a
  # positional prompt does not auto-submit in an interactive claude TUI, so
  # the kickoff prompt is typed as its own line after the harness comes up
  # (see the delivery step in each path).
  local h="$1" launch_file sid=""
  if [ "$h" = "claude" ] && [ -n "$resume_sid" ]; then
    ac_build_launch "$h" "$model" "$effort_flag" "$resume_sid"
    return 0
  fi
  launch_file="$(ac_config_dir)/launch-$h"
  if [ -f "$launch_file" ]; then
    sed -e "s|__BRIEF__|$brief|g" -e "s|__ID__|$id|g" "$launch_file"
    return 0
  fi
  if [ "$h" = "claude" ]; then
    sid="$( (uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())') | tr '[:upper:]' '[:lower:]')"
  fi
  ac_build_launch "$h" "$model" "$effort_flag" "" "$sid"
}

# Pin the backend for this task; ac_backend validates the name and every
# backend_* call below (and in later scripts, via the meta) honors it.
AC_BACKEND="${backend:-$(ac_config_read backend herdr)}"
export AC_BACKEND
backend="$(ac_backend)"

# Seconds to wait after the launch line before typing the kickoff prompt as
# its own line. Validated here (before any window/lease is created) so a bad
# value fails fast instead of leaking a half-spawned window.
settle="${AC_SPAWN_SETTLE:-8}"
case "$settle" in
  ''|*[!0-9.]*|*.*.*) ac_die "AC_SPAWN_SETTLE must be a non-negative number: $settle" ;;
esac

# Seconds to wait after typing '/effort ultracode' before the kickoff prompt,
# so the claude TUI applies the preset first. Validated up-front (like settle)
# for every ultracode spawn - before any window/lease - so a bad value fails
# fast instead of orphaning a half-spawned window. codex/opencode and custom
# launch-claude spawns ignore ultracode, yet a malformed value still fails them
# (it surfaces the misconfiguration early); the default 2 and any number pass.
ultracode_settle="${AC_ULTRACODE_SETTLE:-2}"
if [ "$ultracode" = 1 ]; then
  case "$ultracode_settle" in
    ''|*[!0-9.]*|*.*.*) ac_die "AC_ULTRACODE_SETTLE must be a non-negative number: $ultracode_settle" ;;
  esac
fi

# Budget (seconds, 1s ticks) for the composer-ready observation between the
# came-up gate and the first thing typed after it (header: THE COMPOSER-READY
# OBSERVATION). Validated up-front like $settle - before any window/lease is
# created - so a bad value fails fast. Integer only: it bounds a tick counter,
# never a sleep duration by itself.
kickoff_ready_budget="${AC_KICKOFF_READY_BUDGET:-60}"
case "$kickoff_ready_budget" in
  ''|*[!0-9]*) ac_die "AC_KICKOFF_READY_BUDGET must be a non-negative integer: $kickoff_ready_budget" ;;
esac

kickoff_acked() {
  # kickoff_acked <id> <text> - deliver one kickoff line with a positive
  # acknowledgement (header: kickoff-prompt delivery). backend_send_line
  # already verifies its submit; when it reports a strand the text SITS in
  # the composer, so the bounded retry re-SUBMITS - never re-types - at most
  # 2 more times, $settle apart. Non-zero only when never acknowledged.
  local kid="$1" ktext="$2" ktry
  backend_send_line "$kid" "$ktext" && return 0
  # shellcheck disable=SC2034  # ktry is a counter, the loop body never reads it
  for ktry in 1 2; do
    sleep "$settle"
    backend_submit_verified "$kid" && return 0
  done
  return 1
}

kickoff_wait_input_ready() {
  # kickoff_wait_input_ready <id> <harness> - id-scoped twin of
  # ac-pane-agent.sh's crewmate_wait_input_ready (header: THE COMPOSER-READY
  # OBSERVATION). Requires BOTH agent_status=idle AND a non-empty render that
  # stays byte-identical across three one-second reads, via the ID-SCOPED
  # probes backend_agent_idle/backend_capture (never the _pane variants - this
  # arm holds a state/.pane-<id> handle). Re-polls backend_harness_up every
  # tick as its own death signal (this arm carries no EXITMARK) and fails the
  # same way the came-up gate does the instant it reads SHELL (1). A budget
  # expiring on UNOBSERVABLE (2) warns and proceeds, exactly as the came-up
  # gate's own unobservable case does - never a death; only a budget expiring
  # while the harness is CONFIRMED up (0) but never ready fails loud, the same
  # way (status failed, ac_die, the EXIT trap reaps the window).
  local wkid="$1" wharness="$2" w_up=0
  local ready_waited=0 ready_same=0 ready_render="" next_render
  while :; do
    w_up=0
    backend_harness_up "$wkid" || w_up=$?
    if [ "$w_up" = 1 ]; then
      ac_status_append "$wkid" "failed: $wharness NO LONGER UP while waiting for its input surface to become ready - kickoff withheld, spawn refused"
      ac_die "$wharness is NO LONGER UP in $(backend_target "$wkid") while waiting for its input surface to become ready: nothing was typed after the launch line, and the spawn is REFUSED - nothing is in flight. Last lines of the pane:
$(backend_capture "$wkid" 15)"
    fi
    if [ "$w_up" = 0 ] && backend_agent_idle "$wkid"; then
      next_render="$(backend_capture "$wkid" 40 2>/dev/null || true)"
      if [ -n "$(printf '%s' "$next_render" | tr -d '[:space:]')" ]; then
        if [ "$next_render" = "$ready_render" ]; then
          ready_same=$((ready_same + 1))
        else
          ready_render="$next_render"
          ready_same=1
        fi
        [ "$ready_same" -ge 3 ] && return 0
      else
        ready_render=""
        ready_same=0
      fi
    else
      ready_render=""
      ready_same=0
    fi
    if [ "$ready_waited" -ge "$kickoff_ready_budget" ]; then
      if [ "$w_up" = 2 ]; then
        ac_warn "could not read $(backend_target "$wkid") to verify $wharness's input surface became ready - delivering the kickoff anyway (peek it: bin/ac-peek.sh $wkid)"
        return 0
      fi
      ac_status_append "$wkid" "failed: $wharness's input surface never became ready - kickoff withheld, spawn refused"
      ac_die "$wharness's input surface did NOT become ready in $(backend_target "$wkid") within ${kickoff_ready_budget}s: nothing was typed after the launch line, and the spawn is REFUSED - nothing is in flight. Last lines of the pane:
$(backend_capture "$wkid" 15)"
    fi
    sleep 1
    ready_waited=$((ready_waited + 1))
  done
}

deliver_kickoff() {
  # deliver_kickoff <id> <harness> <prompt> - wait for the harness to come up,
  # answer a built-in codex pane's startup dialog, VERIFY the harness is up,
  # wait for its input surface to become ready (kickoff_wait_input_ready),
  # optionally flip the claude session into the ultracode preset,
  # then type the kickoff prompt as its own line, acknowledgement-checked via
  # kickoff_acked, and VERIFY the harness survived it
  # (header: kickoff-prompt delivery; a lost line ends in a loud
  # warning naming the manual fallback, a DEAD pane kills the spawn - the
  # came-up gate below, the composer-ready gate after it, and the re-check
  # after the prompt). The '/effort ultracode'
  # line goes ONLY to a BUILT-IN claude launch: a custom config/launch-claude
  # template is emitted verbatim and gets neither --effort nor the slash line
  # (same contract as build_launch), while a --resume always uses the built-in
  # line so it still gets it. Reads globals $settle, $ultracode,
  # $ultracode_settle, $resume_sid.
  local kid="$1" kharness="$2" kprompt="$3" up=0
  sleep "$settle"
  # THE STARTUP-DIALOG ANSWER (header: kickoff-prompt delivery). The registry
  # names the key per harness (ac_harness_startup_key: codex's bare Enter,
  # never the prompt); it is the first thing typed at a BUILT-IN pane, and a
  # CUSTOM launch-<harness> template gets none, its TUI being unknown - that
  # suppression is this caller's, not the registry's. It runs BEFORE the
  # came-up gate on purpose: the gate below is then what stands between this
  # keystroke and the kickoff, and a bare keypress is all that can reach a
  # pane whose harness never came up. Best-effort: a failed press leaves the
  # dialog up, which the post-kickoff re-check below then reports as the dead
  # pane it becomes.
  k_startup_key="$(ac_harness_startup_key "$kharness")"
  if [ -n "$k_startup_key" ] && [ ! -f "$(ac_config_dir)/launch-$kharness" ]; then
    backend_send_key "$kid" "$k_startup_key" || true
    sleep "$settle"
  fi
  # The CAME-UP GATE (header: kickoff-prompt delivery). The kickoff prompt is
  # withheld from a pane whose harness is gone; a built-in codex pane may
  # already have taken the bare startup-dialog Enter just above, before this
  # gate - every other pane got no keystroke at all before it. The probe's
  # three states are ac-backend.sh's.
  backend_harness_up "$kid" || up=$?
  if [ "$up" = 1 ]; then
    ac_status_append "$kid" "failed: $kharness did not come up at launch - kickoff withheld, spawn refused"
    ac_die "$kharness did NOT come up in $(backend_target "$kid"): the pane fell back to a bare shell, so the kickoff prompt is WITHHELD and the spawn is REFUSED - nothing is in flight, spawn again once the launch is fixed (a --resume-from carrying a session id the harness does not know is the recorded cause). Last lines of the pane:
$(backend_capture "$kid" 15)"
  elif [ "$up" = 2 ]; then
    ac_warn "could not read $(backend_target "$kid") to verify $kharness came up - delivering the kickoff anyway (peek it: bin/ac-peek.sh $kid)"
  fi
  # THE COMPOSER-READY OBSERVATION (header: THE COMPOSER-READY OBSERVATION).
  # Runs for every harness/launch-template combination, mirroring the sibling
  # arm's unconditional application - the eaten-keystroke race is not
  # codex-specific (repo-knowledge, by: spawn-cameup-render-readiness,
  # measured on claude too).
  kickoff_wait_input_ready "$kid" "$kharness"
  if [ "$ultracode" = 1 ] && [ "$kharness" = claude ] \
     && { [ -n "$resume_sid" ] || [ ! -f "$(ac_config_dir)/launch-claude" ]; }; then
    if ! kickoff_acked "$kid" "/effort ultracode"; then
      printf "WARNING: '/effort ultracode' NOT acknowledged by %s - kickoff prompt WITHHELD (typing it now would append to the stranded line and garble both); peek (bin/ac-peek.sh %s), resubmit with bin/ac-send.sh %s --key Enter, then deliver the brief prompt via bin/ac-send.sh %s\n" \
        "$(backend_target "$kid")" "$kid" "$kid" "$kid" >&2
      return 0
    fi
    sleep "$ultracode_settle"
  fi
  kickoff_acked "$kid" "$kprompt" \
    || printf 'WARNING: kickoff prompt NOT acknowledged by %s - it may sit unsubmitted in the composer; peek (bin/ac-peek.sh %s), then resubmit manually with bin/ac-send.sh %s --key Enter\n' \
      "$(backend_target "$kid")" "$kid" "$kid" >&2
  # THE POST-KICKOFF RE-CHECK (header: kickoff-prompt delivery). The SAME probe
  # again, because the gate above answers "was the harness up before I typed"
  # and a harness can die ON the kickoff. Its three states keep their meanings -
  # 2 is never collapsed into 1.
  up=0
  backend_harness_up "$kid" || up=$?
  if [ "$up" = 1 ]; then
    ac_status_append "$kid" "failed: $kharness NO LONGER UP after the kickoff attempt - spawn refused"
    ac_die "$kharness is NO LONGER UP in $(backend_target "$kid"): a non-shell foreground process held the pane at the gate before the kickoff, and after the kickoff attempt every foreground process in the pane is a shell - so NOTHING is in flight and the spawn is REFUSED. Those two observations are all this probe establishes: it cannot show the prompt was accepted, nor exclude an unrelated exit in between. LIKELY cause, named as a likelihood: the kickoff attempt itself (a startup dialog that read the prompt as an answer is one). Last lines of the pane:
$(backend_capture "$kid" 15)"
  elif [ "$up" = 2 ]; then
    ac_warn "could not read $(backend_target "$kid") to verify $kharness survived the kickoff - the spawn stands (peek it: bin/ac-peek.sh $kid)"
  fi
}

reap_orphan_window() {
  # Reap a window left by an earlier spawn of this id that died before writing
  # any meta - the SIGKILL case no trap can cover (contract: ORPHAN-WINDOW
  # SAFETY in this header). No meta exists here (the duplicate-meta refusal
  # above dies on one), so a live window can only be that orphan; the KILL
  # OWNERSHIP PROOF still decides whether the tab really closes.
  backend_window_alive "$id" || return 0
  ac_warn "reaping the orphan window of $id ($(backend_target "$id")): it carries no meta, so no fleet script could address it - an earlier spawn died before writing one"
  backend_kill_window "$id" || true
}

spawn_orphan_cleanup() {
  # The EXIT trap covering window-create until a COMPLETE meta (contract:
  # ORPHAN-WINDOW SAFETY in this header) on the chief paths, which hold no
  # pool lease: drop the partial meta, then reap the window this spawn opened.
  rm -f "$meta"
  backend_kill_window "$id" || true
  spawn_meta_claim_release
}

spawn_meta_claim_acquire
trap spawn_meta_claim_cleanup EXIT

# --- roomchief path ------------------------------------------------------------

if [ -n "$roomchief_family" ]; then
  fam="$roomchief_family"

  # Origin + cap-gate flags (contract: this script's header). Resolve who
  # initiated this promote and any over-cap sanction BEFORE the cap check -
  # like the cap itself, so a bad flag fails before any window/lease/meta.
  # At most ONE of the three, and the two reasons stay distinct in the messages:
  # captain vs system is an ORIGIN conflict (one meta, one initiated_by), while
  # either against --over-cap is a sanction on a promote that is already exempt.
  [ "$captain_initiated_set" = 0 ] || [ "$system_initiated_set" = 0 ] \
    || ac_die "--captain-initiated and --system-initiated are mutually exclusive: a promote has exactly ONE origin, and the meta records exactly one initiated_by"
  [ "$captain_initiated_set" = 0 ] || [ "$over_cap_set" = 0 ] \
    || ac_die "--captain-initiated and --over-cap are mutually exclusive: a captain-initiated promote is already exempt from the cap, so an over-cap sanction on it is meaningless"
  [ "$system_initiated_set" = 0 ] || [ "$over_cap_set" = 0 ] \
    || ac_die "--system-initiated and --over-cap are mutually exclusive: a system-initiated promote is already exempt from the cap, so an over-cap sanction on it is meaningless"
  initiated_by=chief
  if [ "$captain_initiated_set" = 1 ]; then
    [ -n "$captain_initiated" ] \
      || ac_die "--captain-initiated needs a non-empty order ref: a captain-initiated promote must name the captain order it carries out"
    initiated_by=captain
  elif [ "$system_initiated_set" = 1 ]; then
    [ -n "$system_initiated" ] \
      || ac_die "--system-initiated needs a non-empty order ref: a system-initiated promote must name the STANDING captain order it carries out"
    initiated_by=system
  fi
  # --over-cap flag wins; the AC_ROOM_OVERCAP_REASON env is the same path.
  overcap_reason=""; overcap_given=0
  if [ "$over_cap_set" = 1 ]; then
    overcap_reason="$over_cap"; overcap_given=1
  elif [ -n "${AC_ROOM_OVERCAP_REASON:-}" ]; then
    overcap_reason="$AC_ROOM_OVERCAP_REASON"; overcap_given=1
  fi

  # The roomchief cap (contract: this script's header). Like both sibling
  # paths' refusals - and the flag resolution just above - it fires before any
  # window, lease or meta exists. The duplicate-meta refusal above already
  # rejects a re-promote of $fam, so every meta counted here is a DIFFERENT
  # family and this spawn would be one more. Counts only chief-initiated (non-exempt)
  # chiefs: initiated_by=captain and =system are EXEMPT and consume no slot; absent,
  # =chief, or any near-miss token counts (fail-closed - a pre-origin meta must
  # never open a slot, and a typo must never buy an exemption).
  cap="$(ac_config_read room-parallel 5)"
  case "$cap" in ''|*[!0-9]*) cap=5 ;; esac
  flying=""; n_chiefs=0
  for m in "$state_dir"/*-chief.meta; do
    [ -e "$m" ] || continue
    [ "$(ac_meta_get "$m" kind)" = roomchief ] || continue
    case "$(ac_meta_get "$m" initiated_by)" in captain | system) continue ;; esac
    other="$(basename "$m" .meta)"
    flying="$flying${flying:+, }${other%-chief}"
    n_chiefs=$((n_chiefs + 1))
  done
  # IN-FLIGHT promotes (the race this cap must also close): a promote's own
  # pre-meta claim (spawn_meta_claim_acquire, ABOVE this block) lands the
  # instant it starts, but its meta is not written until after deliver_kickoff
  # settles (AC_SPAWN_SETTLE, several seconds) - so two concurrent promotes
  # for DIFFERENT families both claim, both read the SAME meta population
  # (neither has one yet), and both pass. Counting metas alone serializes
  # nothing across families. Every OTHER live *-chief claim (this spawn's own,
  # $meta_claim, is excluded) not yet backed by a meta is counted here too -
  # fail-closed: its eventual initiated_by is not yet knowable from outside,
  # so it counts as non-exempt, the same direction an ambiguous exemption
  # already fails in. A claim already backed by a meta is skipped (the loop
  # above already counted it) - do_acquire's release happens right after the
  # meta write, so the two can briefly coexist. Staleness mirrors
  # spawn_meta_claim_acquire's own read exactly (same grace, same PID-aware
  # check) - this never reclaims, it only decides whether to count.
  for cd in "$meta_claim_root"/*-chief; do
    [ -d "$cd" ] || continue
    [ "$cd" != "$meta_claim" ] || continue
    cother="$(basename "$cd")"
    [ -e "$state_dir/$cother.meta" ] && continue
    cowner="$(cat "$cd/pid" 2>/dev/null || true)"
    cmtime="$(ac_file_mtime "$cd" 2>/dev/null || true)"
    case "$cmtime" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$(( $(ac_now) - cmtime ))" -ge "${AC_SPAWN_META_CLAIM_STALE_GRACE:-15}" ] \
           && { [ -z "$cowner" ] || ! ac_pid_alive "$cowner"; }; then
          continue
        fi
        ;;
    esac
    flying="$flying${flying:+, }${cother%-chief} (promoting)"
    n_chiefs=$((n_chiefs + 1))
  done

  # Cap gate. A captain- or system-initiated promote is exempt (never counts,
  # always fits, no sanction). Otherwise a chief-initiated promote fits under the cap;
  # AT the cap it needs an explicit captain sanction (--over-cap /
  # AC_ROOM_OVERCAP_REASON) to add ONE past it - this spawn only, config is
  # never written - else it refuses fail-closed.
  overcap_used=0
  if [ "$initiated_by" = captain ] || [ "$initiated_by" = system ]; then
    :
  elif [ "$n_chiefs" -lt "$cap" ]; then
    :
  elif [ "$overcap_given" = 1 ]; then
    [ -n "$overcap_reason" ] \
      || ac_die "over-cap promote needs the captain's explicit sanction: pass --over-cap '<why the captain approved exceeding room-parallel=$cap>' (the cap MAY be exceeded per-case only WITH the captain's permission)"
    overcap_used=1
  else
    ac_die "room-parallel cap reached: $n_chiefs/$cap roomchiefs in flight (${flying:-none}); demote a landed one (bin/ac-teardown.sh <family>-chief) before promoting $fam, or add one past the cap with the captain's sanction (--over-cap '<reason>')"
  fi

  # THE ORDER GATE (contract: this script's header). An ENTRY is the room
  # grammar ac-room.sh's cmd_post WRITES and cmd_show reads back - a line
  # opening `- [` - never the file's existence: post creates the file with a
  # `# Room: <family>` header and a blank line before any entry. Placed with the
  # cap and AFTER it, so the existing refusal order is unchanged, and before any
  # window, lease or meta, so the header's exit contract holds: non-zero here
  # means no meta was written and the promote is retryable.
  grep -q '^- \[' "$(ac_data_dir)/$fam/room.md" 2>/dev/null \
    || ac_die "room $fam holds no entry: --roomchief takes no brief - the room IS the brief - so this promote would hand the new chief nothing to read. Post the order into the room FIRST, then promote: bin/ac-room.sh post $fam crewchief 'ORDER: <the captain order, verbatim>' && bin/ac-spawn.sh --roomchief $fam"

  # THE DERIVED CREWDOMAIN BINDING (R3, crewdomain-token). A family whose fleet
  # row carries the `domain:<name>` token promotes a DOMAINCHIEF - an ordinary
  # roomchief carrying the domain. The binding is DERIVED from the token rather
  # than passed as a flag: the stamp IS the binding, only `ac-domain.sh assign`
  # (chief-only) writes it, and the ledger guard fences the file from scoped
  # sessions - chief-only-add stays structural at the session level. A STORY
  # row with no token of its own INHERITS its epic row's domain (one family,
  # one domain - validate refuses a disagreement). Parsed by the ONE doneline
  # parser, never a private regex twin; a malformed (off-position) token
  # creates no binding, exactly as it creates no slice membership.
  # Placed with the other pre-window refusals so a failure costs no window,
  # lease or meta and the promote stays retryable.
  dom_pair="$(awk "$AC_DONELINE_AWK"'
    NR == FNR { if (/^- \[/) { ac_doneline($0, o); if (o["domain"] != "") d[o["id"]] = o["domain"] } next }
    /^- \[/ {
      ac_doneline($0, o)
      if (o["id"] != f) next
      inh = (o["epic"] != "") ? d[o["epic"]] : ""
      printf "%s|%s\n", o["domain"], inh
      exit
    }
  ' f="$fam" "$(ac_records_dir)/backlog.md" "$(ac_records_dir)/backlog.md" 2>/dev/null || true)"
  dom_own="${dom_pair%%|*}"; dom_inh="${dom_pair#*|}"
  [ "$dom_pair" = "$dom_own" ] && dom_inh=""   # no row found: empty pair
  # ONE FAMILY, ONE DOMAIN: a story whose own token disagrees with its epic
  # row's is corrupt state, not a choice this promote may make - the AC-3.3
  # fail-closed direction, kept under the token grammar.
  if [ -n "$dom_own" ] && [ -n "$dom_inh" ] && [ "$dom_own" != "$dom_inh" ]; then
    ac_die "family $fam carries domain:$dom_own but its epic row carries domain:$dom_inh - one family, one domain; corrupt state, not a choice this promote may make. Strip the wrong token: bin/ac-domain.sh unassign <name> <id>"
  fi
  dom="${dom_own:-$dom_inh}"
  if [ -n "$dom" ]; then
    # A VALID registry entry is REQUIRED, not assumed: a token naming a retired
    # domain (the ORPHAN-TOKEN shape `ac-domain.sh list` reports) must not go
    # on minting domainchiefs - a ghost domain nothing routes to and nothing
    # lists. Symmetric with assign, which already demands one.
    ac_domain_parse | awk -F'\t' -v n="$dom" '$1 == "VALID" && $2 == n { f = 1 } END { exit !f }' \
      || ac_die "family $fam carries domain:$dom but '$dom' is not a VALID entry in records/crewdomains.md - refusing to promote a chief bound to a domain nothing routes to. Either restore its line in records/crewdomains.md, or strip the token: bin/ac-domain.sh unassign $dom $fam"
  fi

  root="$(ac_root)"
  # The harness comes from the SAME shared crew-dispatch resolution the
  # crewmate path uses (contract: ac-backend.sh's ac_pane_profile header) -
  # but the KEYED half, never ac_resolve_profile's `rules`: a roomchief
  # promote has no chief in the loop to judge a `when` clause (the
  # system-initiated learning promote calls with no --harness at all, and
  # ac_resolve_profile's rules ladder would die fail-closed on it). An
  # explicit --harness still wins outright; ABSENT panes.roomchief falls
  # through to today's config/crew-harness ladder unchanged; a
  # panes.roomchief entry that names no harness DIES rather than silently
  # falling back - mirrors bin/ac-gate.sh's panes.gate resolution
  # (bin/ac-gate.sh:622-623). panes.roomchief may ALSO be ROUTED (`rules` +
  # a MANDATORY `default`, captain ruling 2026-07-28,
  # routed-pane-rules-for-gate-codereview-roomchief): this call passes no
  # selector, so it resolves the mandatory default - exactly what this
  # no-chief-in-the-loop promote (including the system-initiated one) needs.
  # Only the harness rung is read: like the crew
  # path, no dispatch profile may set this promote's model/effort.
  if [ -n "$harness_flag" ]; then
    harness="$harness_flag"
  else
    prof=""; prc=0
    prof="$("$bin_dir/ac-dispatch-select.sh" --pane roomchief 2>/dev/null)" || prc=$?
    [ "$prc" = 0 ] \
      || ac_die "crew-dispatch panes.roomchief is present but unresolvable - refusing to fall back to config/crew-harness (see bin/ac-dispatch-select.sh --pane roomchief)"
    if [ -n "$prof" ]; then
      harness="${prof%% *}"; harness="${harness#harness=}"
    else
      harness="$(ac_config_read crew-harness claude)"
    fi
  fi
  launch="$(build_launch "$harness")"
  command -v "${launch%% *}" >/dev/null 2>&1 || ac_die "harness binary not found: ${launch%% *}"

  reap_orphan_window
  # The roomchief's tab anchors its FAMILY's workspace (FAMILY WORKSPACE
  # GROUPING, ac-backend.sh header) - every crewmate and verification pane
  # of the family lands beside it.
  export AC_WINDOW_FAMILY="$fam"
  backend_window_new "$id" "$root"
  unset AC_WINDOW_FAMILY
  window="$(backend_target "$id")"
  trap spawn_orphan_cleanup EXIT

  # Slack narrative duty rides the per-fleet flag (config/remote-mirror=
  # chief; default off - the captain opts a fleet in): only then does the
  # chief's charter include composing its family's thread posts.
  slack_duty=""
  if [ "$(ac_config_read remote-mirror off)" = "chief" ]; then
    slack_duty="You also WRITE this family's Slack thread yourself: after each captain-facing room post, compose the human-readable update and send it with bin/ac-remote.sh thread-post $fam (add --mention-captain on GATE/ASK); style per records/captain.md. After you post the LANDING done-report, run bin/ac-remote.sh done-stamp $fam so the turn-end guard knows it went out. "
  fi
  prompt="You are the ROOMCHIEF of family $fam. Read the room first: bin/ac-room.sh show $fam. You own ONLY this family's stages and gates: brief/spawn/supervise its crewmates, talk to the captain in THIS thread, post every event and gate to room $fam (GATE:/ASK:/DECIDED:). ${slack_duty}NEVER touch records/backlog.md or records/projects.md - the crewchief owns them (enforced: bin/ac-ledger-guard.sh refuses an Edit/Write/NotebookEdit on either while AC_SCOPE is set). MEMORY: the home brain is your cross-history recall. On EVERY wake run bin/ac-brain.sh delta --agent $fam-chief --session $fam - the first call registers your cursor, every later one returns only the pages and facts that changed since you last looked. After a compaction rebuild footing with bin/ac-brain.sh context_pack --entities data/$fam/room. When the room and the knowledge tiers leave a question open, ask the fleet's history: bin/ac-brain.sh recall '<question>'. Arm your watcher as the harness's OWN background task with AC_WATCH_ONLY=\$(bin/ac-ready.sh watch-set $fam) bin/ac-watch.sh - watch-set returns your family id plus your IN-FLIGHT story families (so an epic's scoped watcher also covers its story crewmate panes; a non-epic family is just your family id), so RECOMPUTE it every re-arm to track stories as they start and land. The harness runs it, tracks it, and is woken by its exit; NEVER nohup/&/disown it inside a tool call, which orphans it and wakes no one. When the family lands: FIRST debrief the family (append its durable lessons as dated one-liners with bin/ac-learn.sh note '### <date> (family $fam)' '- <lesson>' ... - it PLACES them under '## Pending' in records/learnings.md, the only section the next Learning transaction reads; appending at end-of-file instead puts them after '## Distilled', where that transaction deletes them. Your context dies with demotion, the lessons must not), THEN report back with bin/ac-room.sh handback $fam '<one-line outcome>' (it posts the room record AND queues a durable wake for the crewchief - never rely on a pane line alone), then print \`done:\` hand-back. Keep AC_CAPTAIN_RE marker verbs out of your room and pane prose - drop the trailing colon or backtick-wrap the token when you show one - so a narrative line never false-wakes the watcher or false-stamps a pane."
  # THE DOMAINCHIEF SECTION. Emitted ONLY when a domain resolved, so an ordinary
  # roomchief's prompt stays byte-identical. Everything here is a contract that
  # lives NOWHERE ELSE - there is no file on disk a domainchief would find it
  # in - which is why each clause is asserted against the pane buffer.
  if [ -n "$dom" ]; then
    prompt="$prompt

You are the DOMAINCHIEF of crewdomain $dom (an ordinary roomchief carrying a domain; your meta stays kind=roomchief with domain=$dom). Its package is crewdomains/$dom/. What that changes, and nothing else does:
STANDING RULES: read the FLEET records/captain.md exactly as any chief does - your domain has NO captain.md of its own, and its standing rules are the lines in that file prefixed 'STANDING (domain:$dom): '. Read them at intake, before you triage.
LEARNINGS: your domain has no learnings ledger. Note lessons to the FLEET records/learnings.md with bin/ac-learn.sh note as any roomchief does, prefixing each lesson '(domain:$dom)' so the domain's material stays filterable.
PROJECTS - MEMBERSHIP: your view is crewdomains/$dom/projects/, symlinks into the fleet's OWN clones. A crewmate spawn for a project outside that view is REFUSED, so brief only what the view holds.
PROJECTS - DETAIL: read crewdomains/$dom/records/projects.md - the domain's view of each in-scope project. The FLEET records/projects.md stays authoritative for [mode] and the description; verified CODE facts belong in records/repo-knowledge/<project>.md, never in the detail file.
BACKLOG: your family's row lives in the FLEET records/backlog.md, stamped domain:$dom - there is NO domain ledger. You NEVER edit that file (the ledger guard fences it; the crewchief moves rows at promote and at your handback, the ordinary roomchief contract). Read your domain's slice with bin/ac-domain.sh queue $dom.
OVERLAP: before starting work run bin/ac-ready.sh overlap on the order's file surface plus git status in every live lease, against EVERY in-flight family - your domain shares the fleet's clones, so an overlap is fleet-wide, never domain-local.
DISTIL BEFORE HANDBACK: raw lessons and curated knowledge are two classes and only the second is what your successor re-reads directly. Note the raw ones as above; fold DURABLE domain knowledge into the curated files - crewdomains/$dom/CREWMATE.md and the records/projects.md detail - before you hand back. With no domain ledger, that fold is the ONLY per-domain memory write path.
HANDBACK: the ordinary roomchief channel, bin/ac-room.sh handback $fam - there is no domain-specific return channel."
  fi

  # AC_HOME rides the launch line: the fresh pane shell does NOT inherit the
  # crewchief's environment, and without it a roomchief in a seeded home
  # resolves NO data/ at all - ac_home refuses with AC_HOME unset.
  # AC_DOMAIN rides beside AC_SCOPE, gated on a resolved domain so an ordinary
  # roomchief's launch line stays byte-identical - the same two-place shape the
  # scope pair already uses at :1372-1373/:1400, so no new pattern appears.
  dom_env=""
  [ -z "$dom" ] || dom_env="AC_DOMAIN=$(printf '%q' "$dom") "
  backend_send_line "$id" "$(launch_prompt_env "$harness" "$prompt")$(ac_claude_config_env)${codegraph_env}AC_HOME=$(printf '%q' "$(ac_home)") AC_SCOPE=$(printf '%q' "$fam") ${dom_env}$launch"
  deliver_kickoff "$id" "$harness" "$prompt"

  ac_meta_set "$meta" backend "$backend"
  ac_meta_set "$meta" window "$window"
  ac_meta_set "$meta" worktree "$root"
  ac_meta_set "$meta" project "$fam"
  ac_meta_set "$meta" project_dir "$root"
  ac_meta_set "$meta" harness "$harness"
  ac_record_launch_opts "$meta" "$harness" "$model" "$effort" "$effort_flag"
  ac_meta_set "$meta" kind "roomchief"
  # A domainchief IS a roomchief: kind stays roomchief and the domain rides as a
  # separate field, so the cap, the watcher skip set, teardown, relocate and the
  # `chiefs` accounting class all cover it with no edit.
  [ -z "$dom" ] || ac_meta_set "$meta" domain "$dom"
  ac_meta_set "$meta" initiated_by "$initiated_by"
  ac_meta_set "$meta" mode "-"
  ac_meta_set "$meta" yolo "off"
  sid="$(launch_session_id "$launch")"
  [ -n "$sid" ] && ac_meta_set "$meta" session_id "$sid"
  ac_meta_set "$meta" spawned_at "$(ac_iso)"
  spawn_meta_claim_release
  trap - EXIT   # the meta is complete: the chief is addressable, teardown owns it
  # PAST THIS LINE THE PROMOTE HAS HAPPENED, and it is not retryable: the meta
  # is what makes the chief addressable and what holds (or exempts) its cap
  # slot, and teardown - not this script - owns it now. So everything below is
  # BOOKKEEPING, and a failure in it must NOT be reported as a failed promote:
  # a caller that retries on non-zero (ac-learn.sh autoroom) would otherwise
  # announce "no meta written, the next checkpoint retries" over a chief that
  # exists and will never be retried. Each write therefore WARNS by name and the
  # spawn still succeeds - loudly, because a missing DECIDED: receipt is the
  # captain's only view of which exemption this room rode.
  ac_status_append "$id" "working: roomchief promoted" \
    || ac_warn "roomchief $id is promoted, but its status line could not be appended"
  "$bin_dir/ac-room.sh" post "$fam" crewchief "PROMOTED: đã mở phiên roomchief ($id) - trao đổi family này trong thread riêng của nó" >/dev/null \
    || ac_warn "roomchief $id is promoted, but the PROMOTED: post to room $fam failed"
  # The cap-gate receipt (IN ADDITION to PROMOTED): a DECIDED: line recording the
  # captain call this promote rode - captain-initiated (exempt), system-initiated
  # (exempt, on a STANDING rule) or over-cap (+1 past the cap with the captain's
  # sanction). Ordinary in-cap chief promotes get none. With three justifications
  # behind one exemption, the receipt is the ONLY place a captain sees which one a
  # given room rode. Header: the cap-gate contract.
  receipt=""
  if [ "$initiated_by" = captain ]; then
    receipt="DECIDED: $fam captain-initiated promote (order ref: $captain_initiated) - EXEMPT, does NOT count toward room-parallel=$cap"
  elif [ "$initiated_by" = system ]; then
    receipt="DECIDED: $fam system-initiated promote (standing order: $system_initiated) - EXEMPT, does NOT count toward room-parallel=$cap"
  elif [ "$overcap_used" = 1 ]; then
    receipt="DECIDED: $fam over-cap promote, +1 past room-parallel=$cap - captain sanction: $overcap_reason"
  fi
  # AC_ROOM_PROMOTE_RECEIPT=1 DECLARES this ONE post as the cap-gate exemption
  # receipt, not a real family decision - cmd_post's guard would otherwise
  # refuse it as an unscoped DECIDED: into a family whose roomchief is
  # already live (its meta+window are set above, before this line runs).
  [ -z "$receipt" ] \
    || AC_ROOM_PROMOTE_RECEIPT=1 "$bin_dir/ac-room.sh" post "$fam" crewchief "$receipt" >/dev/null \
    || ac_warn "roomchief $id is promoted, but its DECIDED: receipt could not be posted to room $fam - the captain has no record of which exemption it rode: $receipt"
  # Code-owned START announce (a hand announce was missed twice under
  # mirror=chief). The mirror=on auto-announce below never fires for chief and
  # the --roomchief path posts nothing, so NOBODY owned the family's Slack
  # BIRTH stamp. Under mirror=chief post ONE code-owned START that OPENS the
  # thread with the TASK CONTENT - the mechanical
  # skeleton is code-owned, the ongoing narrative stays chief-authored.
  # Idempotent on the thread file: family_send
  # self-registers state/remote-threads/<fam>.thread on the first post, so its
  # existence is the authoritative "already announced" marker (no double-post).
  # Best-effort like the mirror=on block: a spawn must NEVER fail on the mirror.
  if [ "$(ac_config_read remote-mirror off)" = "chief" ] \
     && [ ! -e "$state_dir/remote-threads/$fam.thread" ]; then
    # Open the thread with the TASK CONTENT, not a
    # bare placeholder. Snippet source, newest-first: the newest ORDER entry in
    # the family room, else the family's backlog line (the reliably-present
    # source at spawn time), else nothing (a minimal header-only body). VN
    # framing is preserved verbatim - it comes straight from the room/backlog.
    ann_snip=""
    ann_room="$(ac_data_dir)/$fam/room.md"
    [ -f "$ann_room" ] \
      && ann_snip="$(sed -n 's/^- \[[^]]*\] [^>]*> \(ORDER.*\)$/\1/p' "$ann_room" | tail -n 1)"
    if [ -z "$ann_snip" ]; then
      ann_bl="$(ac_records_dir)/backlog.md"
      [ -f "$ann_bl" ] \
        && ann_snip="$(sed -n "s/^- \[[ x]\] \($fam .*\)$/\1/p" "$ann_bl" | head -n 1)"
    fi
    # Bounded: cap the snippet, appending an ellipsis only when it was cut.
    if [ -n "$ann_snip" ]; then
      ann_cut="$(printf '%s' "$ann_snip" | cut -c1-320)"
      [ "$ann_cut" = "$ann_snip" ] || ann_snip="${ann_cut}…"
    fi
    {
      printf '🚀 *[%s] [START] [%s]* crewchief\n' "$(ac_vn_ts)" "$fam"
      if [ -n "$ann_snip" ]; then printf '• %s\n' "$ann_snip"; fi
    } | "$bin_dir/ac-remote.sh" thread-post "$fam" >/dev/null 2>&1 || true
  fi
  # The final outcome line is part of the post-meta tail, so it is TOTAL: a
  # closed output channel must not make an already-durable promote exit non-zero
  # and be reported as retryable. The trailing `|| true` is load-bearing - when
  # BOTH stdout and stderr are gone even ac_warn (which writes stderr) fails, and
  # without it that failure would trip set -e AFTER the meta is durable. So
  # neither the print nor its warning can fail the promote, and `exit 0` is
  # unconditional - the meta is written, the chief exists, and teardown owns it.
  printf 'spawned %s harness=%s kind=roomchief mode=- yolo=off backend=%s window=%s scope=%s\n' \
    "$id" "$harness" "$backend" "$window" "$fam" \
    || ac_warn "roomchief $id is promoted, but its outcome line could not be printed (output channel closed)" \
    || true
  exit 0
fi

# --- crewdeputy path -----------------------------------------------------------

if [ "$crewdeputy" = 1 ]; then
  home_dir="$(ac_home)/crewdeputies/$id"
  [ -d "$home_dir/state" ] || ac_die "crewdeputy home not seeded: run ac-home-seed.sh $id first"
  harness="${harness_flag:-$(ac_config_read crew-harness claude)}"
  launch="$(build_launch "$harness")"
  command -v "${launch%% *}" >/dev/null 2>&1 || ac_die "harness binary not found: ${launch%% *}"

  # A recovery keeps the REFUSAL here: its ladder leaves state/.pane-<id> behind
  # precisely so this check can still catch a LIVE deputy its own probe could not
  # answer for, where a reap would close a living deputy's tab (contract:
  # ORPHAN-WINDOW SAFETY in this header).
  if [ "$recover" = 1 ]; then
    alive_rc=0; backend_window_alive "$id" || alive_rc=$?
    case "$alive_rc" in
      0) ac_die "window $(backend_target "$id") already exists" ;;
      2) ac_die "the BACKEND could not be READ for $id - whether $(backend_target "$id") still exists is UNKNOWN, so this recovery is REFUSED rather than risk a second window on a LIVE deputy's home; check the backend itself (herdr status server), then recover again" ;;
    esac
  else
    reap_orphan_window
  fi
  # A crewdeputy is fleet-level, not a family: its tab lives in the fleet
  # ROOT workspace (AC_WINDOW_FAMILY set EMPTY = deliberately the root;
  # ac-backend.sh FAMILY WORKSPACE GROUPING).
  # The pane's CWD is the distro checkout (ac_root()), not the deputy home:
  # the home holds no bin/ (config CREWMATE.md data projects records state
  # only), while the charter below tells the pane to run a RELATIVE
  # bin/ac-session-start.sh - exactly the roomchief path's own resolution at
  # :1174/:1213. AC_HOME stays $home_dir on the launch line below and
  # ac_meta_set worktree stays $home_dir (teardown reads that) - only the
  # cwd moves.
  export AC_WINDOW_FAMILY=""
  backend_window_new "$id" "$(ac_root)"
  unset AC_WINDOW_FAMILY
  window="$(backend_target "$id")"
  trap spawn_orphan_cleanup EXIT

  # The idle and return-channel clauses ride inline (the roomchief prompt above
  # is the precedent) so both contracts travel with the LIVE deputy even when
  # its charter brief is thin. They are stated twice by design - here and in
  # AGENTS.md section 5 - and must stay in sync.
  prompt="You are agent-crew crewdeputy $id. Your home is $home_dir (AC_HOME). Read and follow the brief at $brief; run bin/ac-session-start.sh in your current directory first. You are IDLE BY DEFAULT: act only on work routed to you or already recorded in your own home, then WAIT - an empty queue is healthy, and you never invent work (no self-directed survey, audit or refactor sweep). Answer every routed order (a pane line prefixed [chief-order ...]) on the DURABLE return channel with bin/ac-deputy.sh report '<text>' [--doc <abs-path>], never only in chat, and return only phase changes the parent must act on - done, blocked, needs-decision, failed, paused - never your home's routine churn."
  backend_send_line "$id" "$(launch_prompt_env "$harness" "$prompt")$(ac_claude_config_env)${codegraph_env}AC_HOME=$(printf '%q' "$home_dir") $launch"
  deliver_kickoff "$id" "$harness" "$prompt"

  ac_meta_set "$meta" backend "$backend"
  ac_meta_set "$meta" window "$window"
  ac_meta_set "$meta" worktree "$home_dir"
  ac_meta_set "$meta" project "-"
  ac_meta_set "$meta" project_dir "$home_dir"
  ac_meta_set "$meta" harness "$harness"
  ac_record_launch_opts "$meta" "$harness" "$model" "$effort" "$effort_flag"
  ac_meta_set "$meta" kind "crewdeputy"
  ac_meta_set "$meta" mode "-"
  ac_meta_set "$meta" yolo "off"
  sid="$(launch_session_id "$launch")"
  [ -n "$sid" ] && ac_meta_set "$meta" session_id "$sid"
  ac_meta_set "$meta" spawned_at "$(ac_iso)"
  spawn_meta_claim_release
  trap - EXIT   # the meta is complete: the deputy is addressable, teardown owns it
  # PAST THIS LINE THE CREWDEPUTY SPAWN HAS HAPPENED and is not retryable - same
  # bookkeeping-tail shape as the roomchief promote above (:1143-1153): a failed
  # status write must WARN by name, never fail a spawn whose deputy already exists.
  ac_status_append "$id" "working: crewdeputy spawned" \
    || ac_warn "crewdeputy $id is spawned, but its status line could not be appended"
  printf 'spawned %s harness=%s kind=crewdeputy mode=- yolo=off backend=%s window=%s worktree=%s\n' \
    "$id" "$harness" "$backend" "$window" "$home_dir"
  exit 0
fi

# --- crew path -----------------------------------------------------------------

# Resolve project directory.
project_dir="$(ac_project_dir "$project")" \
  || ac_die "project not found: $project (clone it into projects/ first)"
project_name="$(basename "$project_dir")"

# THE DOMAIN VIEW REFUSAL (R12). A spawn under AC_DOMAIN may only work a project
# the domain's view links - a view nothing enforces is decoration. Placed HERE,
# immediately after the project resolves and BEFORE the lease, so a refused
# spawn costs no worktree slot. The decision reads the SYMLINK set only: the
# projects DETAIL file is prose and may lag, the membership guard may not, which
# is why the two have opposite failure modes.
if [ -n "${AC_DOMAIN:-}" ]; then
  # MEMBERSHIP, not mere existence: ac_domain_view_entry is the same predicate
  # `ac-domain.sh validate` reports with, so a plain directory or a link
  # resolving outside the fleet clones is refused here exactly as validate
  # classifies it. Testing `-e` alone left the domain scope fail-open unless an
  # operator happened to run validate first.
  dom_cls="$(ac_domain_view_entry "$AC_DOMAIN" "$project_name")" || true
  [ "$dom_cls" = ok ] \
    || ac_die "crewdomain $AC_DOMAIN has no valid '$project_name' in its project view (crewdomains/$AC_DOMAIN/projects/ - $dom_cls) - a domainchief may only brief work its domain links, and the view must be a symlink resolving into the fleet's own clones. Fix the view (bin/ac-domain.sh validate) or hand the order back to the crewchief."
  # The view entry is valid - but is it the repository THIS spawn will lease?
  # ac_project_dir accepts a PATH, so an external repo whose basename happens to
  # match a viewed project passed a basename-only check while the lease landed
  # somewhere the domain never linked. Compare the canonical paths.
  dom_want="$(cd -P "$(ac_home)/crewdomains/$AC_DOMAIN/projects/$project_name" 2>/dev/null && pwd -P)" || dom_want=""
  dom_have="$(cd -P "$project_dir" 2>/dev/null && pwd -P)" || dom_have="$project_dir"
  [ -n "$dom_want" ] && [ "$dom_want" = "$dom_have" ] \
    || ac_die "crewdomain $AC_DOMAIN links '$project_name' but this spawn would lease $dom_have, not $dom_want - a matching basename is not membership. Pass the fleet clone the domain actually links."
fi

# THE BRANCH COLLISION REFUSAL (contract: this script's header). The meta
# checks above validate four of the id's five namespaces; this is the fifth,
# and the only one that carries code. Resolved HERE because both meta checks
# run long before $project_dir exists - the repo the ref lives in is not
# knowable at either of them. ac_family_owned (bin/ac-lib.sh) is the shared
# predicate ac-self-task.sh's own refusal calls too.
crew_branch="$(ac_crew_branch "$id")"
crew_branch_sha="$(git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$crew_branch" || true)"
if [ -n "$crew_branch_sha" ] && ! ac_family_owned "$id" "$state_dir"; then
  ac_die "$crew_branch already exists in $project_dir (${crew_branch_sha:0:12}) and NO task is in flight to own it - it outlived a dead or torn-down task (teardown deletes a crew branch only when it is MERGED), so spawning $id would commit onto that foreign history and make its landing diff nonsense. Rename it or delete it - that is YOUR call, this spawn touches no ref:
  keep it:   git -C $project_dir branch -m $crew_branch $crew_branch-old
  drop it:   git -C $project_dir branch -D $crew_branch
then spawn again"
fi

# Delivery mode is PER-TASK ONLY (no registry mode
# any more), and the BRIEF is its record: ac-brief.sh resolved it through
# pin > flag > refuse and wrote the `Mode:` line, so spawn READS that record
# rather than re-deriving - two resolvers for one decision is how the brief
# said local-only while spawn re-derived crew-ship from a registry fallback
# (measured red in tests/ac-dispatch-select.test.sh the moment the fallback
# died). --mode here remains an override for the captain's late word, refused
# when it contradicts the brief rather than silently diverging from it.
mode="$(sed -n 's/^Mode: //p' "$brief" 2>/dev/null | head -n 1)"
if [ -n "$mode_flag" ]; then
  case "$mode_flag" in
    crew-ship|direct-pr|local-only) ;;
    *) ac_die "invalid --mode: $mode_flag (want crew-ship|direct-pr|local-only)" ;;
  esac
  if [ -n "$mode" ] && [ "$mode" != "$mode_flag" ]; then
    ac_die "--mode $mode_flag contradicts the brief's recorded Mode: $mode - re-scaffold the brief (the mode record) rather than spawning a different contract than the crewmate was briefed on"
  fi
  mode="$mode_flag"
fi
# A scout brief records no Mode - and spends none. Anything else with no
# recorded mode predates the per-task rule: re-scaffold it.
if [ -z "$mode" ] && [ "$scout" = 0 ]; then
  ac_die "no 'Mode:' line in $brief - re-scaffold with ac-brief.sh (mode is per-task now; the registry default is gone)"
fi
# yolo stays per-project - the ONE thing the registry still answers.
yolo_line="$("$bin_dir/ac-project-mode.sh" "$project_name" 2>/dev/null || printf 'yolo=off\n')"
yolo="${yolo_line##*yolo=}"
if [ "$scout" = 0 ]; then
  [ "$mode" != crew-ship ] || [ "$review" = yes ] \
    || ac_die "crew-ship execution requires review=yes in $brief"
fi

# The harness comes from the SHARED crew-dispatch resolution (ac-backend.sh
# ac_resolve_profile): an explicit --harness wins, a configured dispatch table
# with no flag REFUSES rather than guessing, and otherwise it is
# config/crew-harness. Only the harness rung is read here: model and effort are
# already resolved above by this script's own richer ladder (flag > config, plus
# the ship-stage default and the ultracode mapping), which no dispatch profile
# may quietly undo.
prof="$(ac_resolve_profile --harness "$harness_flag")"
harness="${prof%% *}"; harness="${harness#harness=}"
# SHARP EDGE, closed for the KNOWN built-ins: config/model is harness-specific
# in VALUE (an opus-style name for a claude-habituated fleet, a codex/opencode
# model name for one on those) - it carries no harness tag of its own, so once
# the resolved harness above lands on a KNOWN built-in (claude/codex/opencode,
# ac_harness_known) OTHER than the fleet's own (config/crew-harness), that
# value is no longer trustworthy: ac_build_launch composes it onto -m/--model
# unconditionally. Drop it ONLY when it also came from the config fallback
# (model_explicit=0): an explicit --model flag is the caller naming a model
# for THIS spawn's actual harness and always rides verbatim. An empty model
# lets the harness fall back to its own built-in default (`ac_build_launch`
# omits -m/--model entirely) - the same "empty means the harness's own
# default" rule ac-pane-agent.sh already applies to its ATOMIC pane profile
# (bin/ac-pane-agent.sh:56-64). A CUSTOM harness (config/launch-<h>) is exempt:
# its template is captain-authored and emitted verbatim, never composed by
# ac_build_launch, so there is no silent-composition risk to guard against -
# only the three known built-ins can. This IS a behaviour change for those
# three: a cross-harness spawn that relied on config/model silently reaching
# the wrong harness (crashing there, or the fleet never noticing) now gets
# that harness's own default model instead.
if ac_harness_known "$harness" && [ "$model_explicit" = 0 ] \
  && [ "$harness" != "$(ac_config_read crew-harness claude)" ]; then
  model=""
fi
kind=ship; [ "$scout" = 1 ] && kind=scout

launch="$(build_launch "$harness")"
command -v "${launch%% *}" >/dev/null 2>&1 || ac_die "harness binary not found: ${launch%% *}"

# Lease a pooled worktree inside the project repo. A resume asks for the
# old task's slot back (--prefer): the recorded claude session lives under
# that cwd, and any other slot breaks its transcript/project mapping - the
# spawn still proceeds, but the captain-visible warning below flags it.
# From here until the meta is fully written, any failure must give the
# lease back - a spawn that dies mid-way must not leak a leased slot with
# no crewmate meta.
if [ -n "$resume_wt" ]; then
  worktree="$("$bin_dir/ac-tree.sh" get --repo "$project_dir" --id "$id" --holder "crew:$id" --prefer "$resume_wt")"
  [ "$worktree" = "$resume_wt" ] \
    || ac_warn "resume may not find the old session (cwd changed: $resume_wt -> $worktree)"
else
  worktree="$("$bin_dir/ac-tree.sh" get --repo "$project_dir" --id "$id" --holder "crew:$id")"
fi
ac_codegraph_worktree "$project_dir" "$worktree"
spawn_failed_cleanup() {
  "$bin_dir/ac-tree.sh" return "$worktree" --force >/dev/null 2>&1 || true
  rm -f "$meta"
  # ...and the window, once this spawn has opened one ($window is set only then,
  # so the collision refusal below still dies on a window this spawn does not
  # own). Contract: ORPHAN-WINDOW SAFETY in this header.
  [ -z "$window" ] || backend_kill_window "$id" || true
  spawn_meta_claim_release
}
trap spawn_failed_cleanup EXIT

# Fleet-wide crewmate instructions, if the captain keeps any. The RESOLVED
# harness decides the target file: the one that harness actually loads.
# It prints a worktree-relative path when the repo ships its own instruction
# file, so the layer landed somewhere no harness loads (contract: FALLBACK in
# ac_seed_crewmate_md); the kickoff prompt below is then its only channel.
seed_fallback="$(ac_seed_crewmate_md "$worktree" "$harness")"
ac_seed_crew_settings "$worktree"
ac_seed_crew_skills "$worktree" "$harness"

# Open the crewmate's window (default shell; the harness launches into it).
alive_rc=0; backend_window_alive "$id" || alive_rc=$?
case "$alive_rc" in
  0) ac_die "window $(backend_target "$id") already exists" ;;
  2) ac_die "the BACKEND could not be READ for $id - whether $(backend_target "$id") still exists is UNKNOWN, so this spawn is REFUSED rather than open a second window beside a possibly LIVE one; check the backend itself (herdr status server), then spawn again" ;;
esac
backend_window_new "$id" "$worktree"
window="$(backend_target "$id")"

prompt="You are an agent-crew crewmate. Read and follow the brief at $brief. Work only inside this worktree."
[ -z "$seed_fallback" ] \
  || prompt="$prompt Read $worktree/$seed_fallback first - the fleet-wide crewmate instructions, which this repo's own instruction file does not carry."
# Epic-branch fence, the crewmate-facing half (epic-branch-mech): the lease
# itself was already cut from the recorded branch by ac-tree.sh's fence; this
# line makes the base and the LANDING TARGET explicit so the crewmate never
# re-derives them from room prose. Silent when the id has no record.
if eb_entry="$(ac_epic_base_for "$id" "$(basename "$project_dir")" 2>/dev/null)"; then
  eb_branch="${eb_entry%% *}"
  prompt="$prompt INTEGRATION BRANCH: this worktree is cut from $eb_branch and your work lands INTO $eb_branch, never the default branch - branch crew/$id from it as usual, and any PR you are told to open targets $eb_branch."
fi
# Carry the fleet's knobs forward to the pane agents this crewmate will start
# (contract: the AC_FLEET_MODEL/AC_FLEET_EFFORT block in this header). Each is
# emitted only when there is something to pass on, so a fleet that pins nothing
# leaves the launch line exactly as it was.
fleet_env=""
[ -z "$id" ] || fleet_env="AC_CREW_ID=$(printf '%q' "$id") "
[ "$review" = - ] || fleet_env="${fleet_env}AC_FLEET_REVIEW=$(printf '%q' "$review") "
[ -n "$model" ] && fleet_env="${fleet_env}AC_FLEET_MODEL=$(printf '%q' "$model") "
[ -n "$effort" ] && fleet_env="${fleet_env}AC_FLEET_EFFORT=$(printf '%q' "$effort") "
# The crew-ship pipeline config, resolved HERE where AC_HOME is valid, for the
# same reason as AC_FLEET_STATE below: a crewmate has no AC_HOME, so
# ac_project_config_file inside its own ac-ship.sh start would resolve against
# no home at all (ac_home() refuses with AC_HOME unset; before it refused it
# answered the config-less distro checkout) and could
# never tell that phantom miss apart from a project that genuinely has no
# installed config - silently dropping any key the captain pinned
# (ship-config-and-know-citation-blind-spots). AC_FLEET_HOME_CHECKED rides
# unconditionally: it is the positive signal that a real home ALREADY tried
# this resolution, so ac-ship.sh can trust an absent AC_FLEET_PROJECT_CONFIG as
# a verified "no config" rather than an unresolved home.
fleet_env="${fleet_env}AC_FLEET_HOME_CHECKED=1 "
proj_cfg="$(ac_project_config_file "$project_dir" 2>/dev/null || true)"
[ -z "$proj_cfg" ] || fleet_env="${fleet_env}AC_FLEET_PROJECT_CONFIG=$(printf '%q' "$proj_cfg") "
# Per-ROLE pane-agent knobs for the verification panes this crewmate will start
# (codereview reviewer, qa agent): resolved HERE where AC_HOME is valid, so those
# homeless panes get config/<role>-{agent,model,effort} via env (else
# ac-pane-agent falls back to its own per-role defaults). Threaded only when set,
# like AC_FLEET_MODEL. All THREE ride the same rung deliberately - the pane's
# ladder reads them together so an agent pin and its model/effort travel as one
# choice, never a model composed onto a harness some other rung picked.
for role in codereview qa; do
  ru="$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  for knob in agent model effort; do
    kv="$(ac_config_read "$role-$knob" "")"
    [ -n "$kv" ] || continue
    fleet_env="${fleet_env}AC_FLEET_$(printf '%s' "$knob" | tr '[:lower:]' '[:upper:]')_$ru=$(printf '%q' "$kv") "
  done
done
# The DISPATCHED pane profile for those same two panes, resolved HERE for the
# harder version of that reason: ac-ship.sh review-agent and ac-qa.sh agent are
# themselves homeless, so resolving it downstream would read the config-less
# distro checkout rather than this fleet. ONE scalar per kind carrying the whole
# `harness=<h> model=<m> effort=<e>` triple - not three variables - so the
# profile stays atomic on the wire and ac-pane-agent can honour an empty model
# as "the harness's own default" instead of re-deriving it. Only these two kinds:
# ac-learn.sh's scout is homed and reads the block first-hand. Threaded only when
# a profile resolves, so a fleet that configures none leaves this line unchanged.
# --codereview-rule is the ONE exception to "no selector, ever": with no flag
# this call is byte-identical to before (ac_pane_profile, no --rule - flat
# stays flat, an absent key threads nothing, a routed panes.codereview falls
# to its mandatory default). WITH the flag, a wrong selector DIES rather than
# silently threading nothing - the caller asked to choose deliberately, and a
# request that cannot be honored is a misconfiguration, not an absent profile.
for pane_kind in codereview qa; do
  if [ "$pane_kind" = codereview ] && [ "$codereview_rule_set" = 1 ]; then
    crc=0
    pane_prof="$("$bin_dir/ac-dispatch-select.sh" --pane codereview --rule "$codereview_rule" 2>/dev/null)" || crc=$?
    [ "$crc" = 0 ] && [ -n "$pane_prof" ] \
      || ac_die "--codereview-rule $codereview_rule did not resolve a profile (see bin/ac-dispatch-select.sh --pane codereview --rule $codereview_rule)"
  else
    pane_prof="$(ac_pane_profile "$pane_kind")"
  fi
  [ -n "$pane_prof" ] || continue
  fleet_env="${fleet_env}AC_FLEET_PROFILE_$(printf '%s' "$pane_kind" | tr '[:lower:]' '[:upper:]')=$(printf '%q' "$pane_prof") "
done
# The completion-push CHANNEL, on the same rung and for the same reason: a
# crewmate with no AC_HOME cannot resolve state/, so bin/ac-done.sh could
# neither publish its wake record nor find the watcher to nudge. AC_FLEET_STATE
# is the ONE path that answers both, and AC_FLEET_SCOPE names the family whose
# scoped watcher supervises this task (a roomchief's spawn - so the push files
# for the chief that drains it, exactly as the watcher's own wakes do); an
# unscoped spawn carries no scope and files for the fleet. Not a pin, so it
# rides every crewmate launch line; never AC_HOME.
fleet_env="${fleet_env}AC_FLEET_STATE=$(printf '%q' "$(ac_state_dir)") "
# The fleet NAME, same rung and same reason: ac_fleet_name builds every herdr
# workspace label, and a homeless crewmate could only fall back to the ONE group
# every fleet on the box shares - so every observation tab it opens (ship watch,
# qa watch, the pane agents) landed there instead of in its own fleet's. Also
# not a pin, so it rides every crewmate launch line; the NAME, never AC_HOME.
fleet_env="${fleet_env}AC_FLEET_NAME=$(printf '%q' "$(ac_fleet_name)") "
ac_wake_scope_ok "${AC_SCOPE:-}" \
  && fleet_env="${fleet_env}AC_FLEET_SCOPE=$(printf '%q' "$AC_SCOPE") "
# Memory-plugin project identity: inside a git WORKTREE, `git rev-parse
# --show-toplevel` answers the worktree dir itself, so cwd-derived project
# names collapse to the slot basename and one repo's memories file under
# another's (measured: crewmate sessions filed under "1"). The explicit env
# is the plugin's own documented override; the resolved PROJECT name is the
# truth whatever the slot is called.
fleet_env="${fleet_env}AGENTMEMORY_PROJECT_NAME=$(printf '%q' "$(basename "$project_dir")") "
backend_send_line "$id" "$(launch_prompt_env "$harness" "$prompt")$(ac_claude_config_env)$codegraph_env$fleet_env$launch"
deliver_kickoff "$id" "$harness" "$prompt"

# Record fleet state.
ac_meta_set "$meta" backend "$backend"
ac_meta_set "$meta" window "$window"
ac_meta_set "$meta" worktree "$worktree"
ac_meta_set "$meta" leases "$worktree"
# lease_ids: the per-ACQUISITION identity of each entry in leases=, same order.
# It is what teardown passes back as `ac-tree.sh return --if-lease-id`, so a
# LATE return cannot reset a slot the pool has since handed to another task.
# Read from the slot meta rather than returned by `get`, whose stdout contract
# (one bare path) is what this script consumes positionally. Empty when the
# pool predates lease ids - teardown then falls back to today's unconditional
# return, exactly as a meta written before this key does.
ac_meta_set "$meta" lease_ids \
  "$(ac_meta_get "$project_dir/.crew/slots/$(basename "$worktree").meta" lease_id)"
ac_meta_set "$meta" project "$project_name"
ac_meta_set "$meta" project_dir "$project_dir"
# fleet_scope: the family whose scoped watcher supervises this task (the
# spawning roomchief's AC_SCOPE - an epic, for a story crewmate). The launch
# env carries it too (AC_FLEET_SCOPE above), but the fleet watcher's skip logic
# needs it ON DISK to route a story pane's backup poll to the epic roomchief
# instead of the fleet, without reading the backlog in its hot poll loop
# (epic-roomchief-watch-only-omits-story-ids). An unscoped spawn records none,
# leaving a non-epic task's meta byte-identical to before.
ac_wake_scope_ok "${AC_SCOPE:-}" && ac_meta_set "$meta" fleet_scope "$AC_SCOPE"
ac_meta_set "$meta" harness "$harness"
ac_record_launch_opts "$meta" "$harness" "$model" "$effort" "$effort_flag"
ac_meta_set "$meta" kind "$kind"
ac_meta_set "$meta" mode "$mode"
ac_meta_set "$meta" review "$review"
ac_meta_set "$meta" yolo "$yolo"
sid="$(launch_session_id "$launch")"
[ -n "$sid" ] && ac_meta_set "$meta" session_id "$sid"
ac_meta_set "$meta" spawned_at "$(ac_iso)"
ac_status_append "$id" "working: spawned"
# Slack task thread: a starting task opens (or
# reuses) its family's remote thread with one announce line; every room post
# for the family lands in the same thread. THREAD FAMILY: a spawn from a
# SCOPED session (a roomchief - AC_SCOPE set) belongs to the chief's family
# thread, whatever the id looks like - slice ids like <fam>-s1 are flat by
# the stage grammar yet are that family's crewmates (captain ruling
# 2026-07-18: learning-loop-impl-s1 posts in the learning-loop-impl
# thread). Unscoped spawns fall back to the id's own family. Best-effort -
# spawn never fails on the mirror, config/remote-mirror=off silences it.
# Announce follows the captain's Slack rules (AGENTS.md section 8):
# `*[UTC+7 ts] [VERB] [<family>]*` header, Vietnamese framing, identifiers
# verbatim.
if [ "$(ac_config_read remote-mirror off)" = "on" ]; then
  announce_family="$(ac_family_of_id "$id")"
  ac_wake_scope_ok "${AC_SCOPE:-}" && announce_family="$AC_SCOPE"
  printf '🚀 *[%s] [START] [%s]*\n• bắt đầu task %s (%s) trên repo %s - mode=%s\n' \
    "$(ac_vn_ts)" "$announce_family" "$id" "$kind" "$project_name" "$mode" \
    | "$bin_dir/ac-remote.sh" thread-post "$announce_family" >/dev/null 2>&1 || true
fi
spawn_meta_claim_release
trap - EXIT

printf 'spawned %s harness=%s kind=%s mode=%s yolo=%s backend=%s window=%s worktree=%s\n' \
  "$id" "$harness" "$kind" "$mode" "$yolo" "$backend" "$window" "$worktree"
