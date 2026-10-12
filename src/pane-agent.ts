// pane-agent.ts - run ONE agent turn in a backend pane, for the mechanisms
// that verify: the ship pipeline's reviewer, qa, the learning scout, the gate
// judge. The entry is bin/ac-pane-agent.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-pane-agent.sh as the
// oracle the differential leg of tests/sh/ac-pane-agent.test.sh holds this
// module to. THREE ARMS, chosen by the caller's mode and the resolved
// harness: the SESSION arm (default, claude) runs a claude session - visible,
// steerable, real permission prompts answerable by a human; the CREWMATE arm
// (default mode, codex/opencode/pi/cursor) runs the harness's own TUI under
// the crewmate contract - the agent WRITES its final message to a file and
// ANNOUNCES its own completion; and the ONE-SHOT COMMAND arm (`--exec`) runs a
// harness's non-interactive form, where the process EXIT is the turn end and
// its STDOUT is the final message. Only the first is a resumable session.
//
//   ac-pane-agent.sh run --cwd DIR --prompt-file F [--resume SID] [--label L]
//                        [--kind K] [--timeout SECS] [--replace-pane ID]
//                        [--pane-file PATH] [--model M] [--deliverable PATH]
//                        [--effort E] [--harness H] [--exec] [--observe PATH]
//                        [--await-file PATH]
//     --observe PATH: (--exec ONLY) publish a read-only observation descriptor
//       (pane/tab + the real prompt/stdout/stderr paths) BEFORE launch, so an
//       observer like ac-gate-watch can tail the ACTIVE one-shot run; the CALLER
//       removes it. Refused without --exec (a normal harvest has no such streams).
//   ac-pane-agent.sh close --pane ID
//   ac-pane-agent.sh reap-pane --pane ID  # close ONE known pane + tidy its tab/workspace
//   ac-pane-agent.sh reap [--dry-run]   # close ac-*-agent panes whose cwd is gone
//   ac-pane-agent.sh steer --agent HANDLE '<text>' [--pane ID]  # steer a live one
//   ac-pane-agent.sh seed-trust|stop-hook|wrap-transcript|has-final-text|iso-epoch ...
//     the five JSON helper subcommands (HELPER SUBCOMMANDS below)
//
// --kind K names the CALLER on every herdr surface (tab ac-<kind>-agent-
// <branch>, pane ac-<kind>-agent:<label>); default `ship`. Known callers:
// codereview (the crew-ship reviewer, through ac-verify.sh), qa (ac-qa.sh
// agent), learning (ac-learn.sh), gate (src/gate.ts, an --exec caller).
//
// --harness H names the harness EXPLICITLY, and with it the caller takes
// ownership of the WHOLE triple: no profile model/effort and no model/effort
// ladder apply, so anything not passed as a flag stays empty = that harness's
// own default. That is item 3 of the CREWMATE arm's list discharged at its only
// entry point - a profile's model was authored FOR the profile's harness, and
// this is the one place another harness could otherwise inherit it. The gate
// needs it because its one engine can come from AC_GATE_AGENT or
// config/gate-agent, which a profile did not name.
//
// PANE PROFILE (the authoritative contract): which harness+model+effort a pane
// agent runs is DISPATCHED per --kind, from config/crew-dispatch.json's `panes`
// block - `"panes": {"codereview": {"harness","model","effort"}, "qa": {...}}`,
// the same object shape as a rule's `use`. Keyed, because a pane agent cannot
// do what rules[] asks of a reader: a `when` clause is prose a chief JUDGES, and
// a rule's identity is its POSITION, so inserting one would silently repoint a
// pinned reviewer at another profile. `panes` is `.default` generalized from one
// fallback slot to a set keyed by kind (ac-dispatch-select.sh --pane owns the
// lookup; ac-backend.sh ac_pane_profile is the shared rung both callers use).
//
// Resolved on TWO rungs, the model knob's below and for the same reason:
// AC_FLEET_PROFILE_<KIND> env (threaded by ac-spawn.sh, the only place AC_HOME
// is real for a homeless caller) > the `panes` block read first-hand (a homed
// caller: ac-learn.sh's scout). One scalar carries the whole triple, never three
// variables - see ATOMIC below.
//
// Resolved ONLY when something will read it, i.e. when the caller passed no
// --harness: that flag takes the whole triple, leaving a profile unread. The
// distinction is load-bearing, not an optimization - a LANES-shaped kind
// (`panes.codereview-scout.lanes[]`, one profile PER LANE) has no single
// profile to resolve, and every lane launch names its own harness, so
// resolving for a lane turned the resolver's correct refusal into a fatal
// misconfiguration. A kind with no --harness still refuses: nothing names an
// engine, so there is no run to degrade into.
//
// A profile is ATOMIC. When one resolves it supplies harness, model and effort
// TOGETHER and supersedes the per-role model knob for that kind, and its model
// and effort are used AS-IS, INCLUDING EMPTY: empty means the harness's own
// default, never a fall-through to the ladder below. That single rule is what
// keeps the triple coherent - a fall-through would compose a claude model name
// onto a non-claude harness (`codex -m opus`), which is exactly what putting
// harness+model+effort in ONE authored object exists to prevent. When NO profile
// resolves, everything below applies BYTE-FOR-BYTE unchanged: a fleet that
// configures no `panes` block behaves exactly as it did before this rung existed,
// and a fleet that dispatches its CREWMATES through rules[] does too - those
// rules are never borrowed for a verification pane.
//
// Model/effort ladder, per knob: the --model / --effort flag wins. For the
// VERIFICATION panes (--kind codereview | qa) the model then reads the per-role
// knob and DEFAULTS to claude opus: AC_FLEET_MODEL_<KIND> env (threaded by
// ac-spawn from config/<kind>-model) > config/<kind>-model > opus - verification
// runs on the strongest model, decoupled from the fleet crewmate model, unless
// the captain pins config/<kind>-model. The harness reads AC_FLEET_AGENT_<KIND>
// > config/<kind>-agent > claude, and effort AC_FLEET_EFFORT_<KIND> >
// config/<kind>-effort, on the same rung as the model, so an agent pin and its
// model/effort siblings are chosen together. Every other kind (and effort for
// all kinds, below the per-role rung) keeps the plain fleet ladder: the
// inherited fleet scalar AC_FLEET_MODEL / AC_FLEET_EFFORT; then config/model /
// config/effort; nothing anywhere = claude's own default. The point of the
// whole ladder is that an independent judge is never quietly a weaker model, or
// a shallower thinking tier, than the fleet pinned - it was, measurably: with a
// fleet pinned to config/model=opus its reviewer panes ran on claude-fable-5
// (pool-worktree transcripts, 2026-07-15). The config rung alone could not fix
// that, because it resolves through the home: only a chief-run caller
// (ac-learn.sh's scout) has AC_HOME, while the reviewer and ac-qa.sh agent run
// from crewmate panes that have none. Hence the env rung, fed by ac-spawn.sh's
// crewmate launch line - two narrow scalars rather than the fleet home, which
// this module refuses to fabricate (ENVPIN below).
// --effort takes low|medium|high|xhigh|max|ultracode, and anything else is
// REFUSED before a pane is placed. The FLAG is claude-only on the interactive
// arm; on the one-shot arm the VALUE reaches every engine in that engine's own
// shape (codex `-c model_reasoning_effort=<e>`, claude `--effort <e>`, opencode
// `--variant <e>`, pi `--thinking <e>` - ONESHOT). ultracode maps to xhigh and
// NOTHING else: the '/effort ultracode' TUI line is ac-spawn's kickoff
// mechanism, and a one-turn pane has no counterpart for it.
//
// HARNESS ARMS (the authoritative contract): a resolved harness is REFUSED,
// through the NDJSON error protocol and BEFORE a pane is placed, unless this
// module has an implemented arm for it IN THE MODE ASKED FOR:
//   SESSION (no --exec, harness claude): claude, and only claude.
//   CREWMATE (no --exec, harness codex | opencode | pi | cursor): the crewmate
//     contract (harnessPaneArm, the twin of bin/ac-harness.sh's arm map).
//   ONE-SHOT (--exec): codex, claude, opencode, pi, cursor, agy - the forms of
//     ONESHOT below, which also owns the safety boundary each one does NOT
//     have.
// The modes arm SEPARATELY, because a working one-shot form proves nothing about
// the same harness's TUI (and the reverse). Refusing beats placing: a pane whose
// harness never came up still burns the caller's whole timeout (AC_VERIFY_TIMEOUT,
// default 7200s, per fix round) and then reports status:timeout, which reads like
// a slow reviewer rather than a misconfiguration.
// The launch line itself is built in TWO places: ONESHOT composes the ONE-SHOT
// arm's command, while buildLaunch (src/lib.ts, the twin of bin/ac-backend.sh's
// ac_build_launch) composes the SESSION/CREWMATE arms' interactive line.
//
// A ONE-SHOT PLACES NO PANE and needs no backend. It runs as a BACKGROUND
// process: its exit ends the turn (the marker touch the wait loop polls) and its
// stdout is the final message, both of which the caller captures directly - so a
// pane held nothing the turn depended on, took no part in observing it, and had
// to be reaped by somebody. It also could not be placed correctly: a one-shot's
// callers were PANES (the gate judge, and review scout lanes the reviewer ran),
// and a pane carries no AC_HOME, so the backend resolved to the herdr default
// and opened herdr panes for an ORCA fleet, one per lane per round, owned by
// nobody. `--pane-file` is therefore refused with `--exec`, and the `done`
// event's `pane` is empty. The SESSION and CREWMATE arms are unchanged: their
// turn IS a pane, and they place one on the fleet's own backend.
//
// WHY THE SESSION ARM IS CLAUDE-ONLY - it is the DESIGN, not a gap awaiting an
// implementer: the pane-agent session is for claude only, and codex and
// opencode run the crewmate arm instead.
// A claude SESSION here is worth its machinery: it resumes across fix rounds, a
// human can steer it mid-turn, and its transcript is the harvest. All of that is
// claude-specific, and reproducing it per harness is what this arm will not do:
//   - TURN-END. claude's is the Stop-hook marker below. herdr agent_status:idle
//     is proven insufficient on its own - codex-cli 0.144.6 blocked on its own
//     interactive TRUST DIALOG while herdr reported `idle`, the SAME value it
//     reports for a finished turn (probe 2026-07-21, two throwaway panes). For
//     claude the ambiguity is broken by a second, claude-specific observable (the
//     transcript's mtime idling past 120s); a harness with no transcript has
//     nothing to break it with, and would harvest the dialog as its verdict.
//   - FINAL-MESSAGE HARVEST. claude's is a transcript locator ($PROJ/*.jsonl)
//     that ac_transcript_final parses. The pane-scrollback fallback stays the
//     shared floor - but it is a floor: TUI chrome and a width-elided render,
//     fine for a one-line verdict, not for the reviewer's JSON-object contract.
// The CREWMATE arm needs NEITHER: the agent writes its answer to a FILE and
// announces its own completion, so file exists = turn ended and file contents
// = the final message. Both codex and opencode are VERIFIED to do exactly that
// on the brief alone, with no harness-specific mechanism (harness-facts.md,
// `codex` and `opencode` Completion bullets; the observations are in
// `data/codex-crewmate/room.md` and `data/opencode-crewmate/room.md`). What the
// crewmate arm gives up is the session: no resume, no session id, nothing to
// steer - `steer` needs a live composer, and neither harness pins a
// caller-minted session id (harness-facts.md Resume bullets), so `--resume` is
// REFUSED here exactly as under --exec.
//
// What the CREWMATE arm still owes, and how it discharges it:
//   1. PROMPT DELIVERY - as its OWN TYPED LINE after the harness comes up, never
//      argv. The positional-prompt convention the other two arms use is
//      claude/codex-shaped, not universal: opencode 1.18.4's positional argument
//      is a project DIRECTORY, so an appended prompt became a cd target and the
//      pane fell back to a shell (probe 2026-07-21). The typed line is the
//      delivery every crewmate already uses, verified for both harnesses.
//      The harness must read idle AND show a non-empty pane render stable
//      across three one-second observations before any text is typed.
//      Process-up and `idle` alone are not enough: both can arrive while the
//      TUI is still booting, and an unrelated boot redraw can otherwise make
//      verified submit report a false acceptance.
//   2. STARTUP DIALOG - the same answer the crewmate path gives, and the same
//      one only: the startup-dialog sequence (backendStartupDialogsPane) - a
//      dialog the backend can NAME gets the key safe on it, an unnamed one the
//      registry's blind key once (a bare Enter at a codex pane before any text,
//      because an `n` or a `2` anywhere in typed text picks "2. No, quit" -
//      harness-facts.md, codex STARTUP TRUST DIALOG). NOT SAFE IN GENERAL, and
//      stated rather than hidden: on a pane showing some OTHER unnamed startup
//      dialog that Enter selects that dialog's default. That residual is
//      accepted on the crewmate path (`data/codex-pane-tui-arm/room.md`); this
//      arm inherits the acceptance because it inherits the step, and
//      classifying dialogs here would rebuild the machinery that was deleted.
//   3. FLAG-VS-PROFILE MODEL COHERENCE - an explicit --model (carrying the
//      caller's codereview/qa model ladder) outranks a profile's model by
//      design, so a fleet dispatching this kind to a non-claude harness while
//      pinning a claude model name would compose that name onto it. It is
//      discharged exactly as --exec discharges it: --harness takes the WHOLE
//      triple with it, so nothing a profile authored for another harness can
//      travel, and without the flag the profile is atomic, so its model was
//      authored FOR its own harness.
//
// A ONE-SHOT arm owes a shorter list still, and that is the point of it: prompt
// delivery is the harness's own non-interactive command, turn-end is the
// process exiting, the final message is its stdout, and there is no dialog to
// pre-seed because no session is opened.
//
// THE CREWMATE-ARM CONTRACT (the authoritative statement of it):
//   - The harness launches BARE - buildLaunch's interactive line, no
//     positional prompt - with `; printf %s $? >RC; touch EXITMARK` appended, so
//     the harness's own EXIT is observable throughout the turn.
//   - The typed line names three absolute paths: the caller's prompt file (what
//     to do), the VERDICT file (where the final message goes), and the marker to
//     `touch` (how completion is announced). All three live in state/, next to
//     the Stop-hook marker - the mode that opens no session leaves no trace in
//     the directory it merely ran in, exactly as --exec does not. Absolute paths
//     in the PROMPT is also how the fleet home reaches an AC_HOME-less caller
//     (bin/ac-qa.sh, HOW THE PATH TRAVELS: "not the environment").
//   - TURN END = the marker exists. FINAL MESSAGE = the verdict file's bytes,
//     wrapped by wrapTranscript into the one-message jsonl shape
//     ac_transcript_final already parses, so every caller reads its verdict from
//     the same `transcript` path and the findings wire (findingsNormalize,
//     src/lib.ts) is reached completely unchanged - the file
//     replaces the HARVEST, never the payload schema.
//   - FAIL CLOSED, in all four directions: a marker with a missing or EMPTY
//     verdict file is a FAILED turn (never ok with an empty payload, the same
//     rule the scrollback floor is held to); the harness exiting before the
//     marker is refused at once, naming its exit status, instead of burning the
//     caller's timeout; a prompt the pane STRANDED unsubmitted is refused before
//     any wait, since no turn will ever start; and a harness that never comes up
//     is refused rather than waited out. A pane that could not be READ is never
//     collapsed into either verdict - it is a note, and the turn proceeds.
//   - PARTIAL WRITES are the agent's ordering to keep: it is told to announce
//     only once the file is written. This arm can only see the bytes that are
//     there when the marker fires; the payload's own shape is checked where it
//     always was, by the caller (the reviewer schema-checks the object envelope,
//     ac-qa.sh requires the verdict line), so a truncated write fails there with
//     the caller's own message rather than being re-validated here from a schema
//     this module would have to duplicate.
//
// Protocol on stdout (NDJSON, consumed by ac-verify.sh, ac-learn.sh and
// src/gate.ts):
//   {"event":"transcript","path":"...","session_id":"...","source":"scrollback|command|file"?}
//   {"event":"replace-pane","pane":"...","closed":true|false}   # --replace-pane only
//   {"event":"warning","reason":"...","message":"..."}   # a report, never a
//     refusal; emitted BEFORE any pane places - "codereview-agent-mismatch"
//     (CONTRADICTION CHECK below), and agy's dropped effort (no reason key).
//     `reason` is deliberately not named `kind` - this module's own --kind
//     (codereview/qa) is a different axis and the two must never be confused
//     on the wire.
//   {"event":"note","path":"..."}   # the unreadable came-up and delivery
//     reads, the AWAIT holds, the idle fallback's use
//   {"event":"done","status":"ok|timeout|pane_closed|error","session_id":"...",
//    "transcript":"...","source":"transcript|scrollback|command|file","pane":"...","error":"..."}
// `session_id` is EMPTY for a one-shot AND a crewmate turn - neither opens a
// session this fleet can resume - which the callers that store one already
// guard for. Every event is built by raw interpolation (W3 below) but the
// refusals of fail(), which jq encodes as {"event":"done","status":"error",
// "error":<text>}.
//
// REAP OUTCOME (the authoritative contract): a retirement here is best-effort
// and NEVER changes an exit status - `reap-pane` exits 0 by contract so it is
// trap-safe, and `--replace-pane` must not fail a turn whose new pane is already
// placed. That is why both VERIFY the close afterwards (herdr `pane get`, orca
// `terminal show`'s connected) and publish `"closed":true|false` on their
// event. The helper reports; the CALLER surfaces - a `"closed":false` a caller
// swallows is an orphaned agent nobody was ever told about, which is exactly
// how pane agents accumulated in the shared workspace (ac-learn.sh
// reap_scout_panes, ac-qa.sh qa_reap_agent_pane and src/teardown.ts
// reapPaneFile all warn on it).
//
// FAIL-CLOSED HARVEST (the authoritative contract): a status:ok done event
// ALWAYS carries a non-empty transcript, and `source` says which harvest
// produced it. Under the CREWMATE arm that is the verdict FILE, and only a
// non-empty one (source=file; the contract block above owns the four failure
// directions). Under the ONE-SHOT arm the rung's own EXIT STATUS decides
// first: only a zero status with non-empty stdout is a turn (source=command,
// the stdout wrapped by the same one-message writer the scrollback harvest
// uses). A rung that died, or judged nothing, FAILED - reported through fail()
// and NEVER falling through to the scrollback floor, which returns TUI chrome
// and would hand a caller expecting a JSON object a width-elided render. That
// is stricter than the interactive arm can be: there, failure is inferred from
// the harvest alone - either nothing resolved, or what resolved carries no
// FINAL MESSAGE, the payload transcriptFinal (src/lib.ts) reads in
// every caller. A turn that stopped after a completed tool call leaves a last
// assistant message holding only tool_use, and is refused on BOTH interactive
// endings - the Stop-hook marker and the idle fallback - rather than reported
// ok for the caller to die on later. The turn ends on the Stop-hook marker
// whether or not $PROJ/*.jsonl resolved - and a session dir holding only
// subagents/ + tool-results/ has no jsonl to resolve at all - so an unresolved
// transcript there falls back to a PANE SCROLLBACK harvest (the raw-pane read
// backendCapturePane, AC_PANE_SCROLLBACK_LINES lines, default 400), written as
// a one-message jsonl in the shape ac_transcript_final already parses so the
// caller reads its verdict from the same `transcript` path. When even the
// scrollback is empty the turn is REFUSED through fail() - status error, exit
// non-zero - never ok with "transcript":"", which overwrote the caller's
// durable per-run session pointer with an empty string and then died late on an
// empty path. `source` is emitted on the ok events only: the non-ok statuses
// assert no usable payload.
//
// STEER (the authoritative contract): a chief steers a LIVE pane agent through
// `steer`, never by hand-crafting herdr commands. INTERACTIVE arm only - a
// one-shot runs a command, not a composer, so there is nothing to steer. The
// stable HANDLE is the pane NAME this module writes at creation -
// ac-<kind>-agent:<label>, the `pane rename` of the herdr placement - and herdr
// is where it is looked up again. HERDR ONLY: the orca arm names no pane that
// way (orcaPlacePane titles it crew:<fleet>/...), so on an orca fleet the verb
// refuses rather than resolve a same-named pane in herdr's default session -
// another fleet's. That is deliberate: a handle file could not be found by both
// sides, because the home forks (a crewmate-run caller - the ship reviewer, qa
// - has no AC_HOME, so it resolves no state/ at all, while the steering chief's
// is its fleet home's), whereas herdr's pane list is the ONE registry both
// already share, and a chief that never launched the pane reads the same name
// off the herdr sidebar. Ownership is PROVEN before delivery, the way the kill
// proves a tab (ac-backend.sh KILL OWNERSHIP PROOF): the handle must resolve to
// exactly ONE live pane still carrying an ac-<kind>-agent:<label> name, so a
// dead or recycled pane refuses instead of steering a stranger. Two live panes
// on one handle (two repos at ship-review-r1) is AMBIGUOUS and also refuses,
// naming --pane <pane-id> as the way through; --pane takes the same ownership
// proof, so it disambiguates without becoming a backdoor into a crewmate's
// pane. Delivery is VERIFIED (backendSendLinePane): unacknowledged means a loud
// non-zero refusal naming the pane, never a silent strand - and since that twin
// prints nothing, its status is what the refusal reads: 2 means the pane could
// not be READ (submit neither confirmed nor refuted, read it before resending),
// anything else means the text is stranded in its composer (resubmit the
// Enter). Unlike the pane a crewmate owns, this one is addressed by NOTHING the
// caller had to hoard - the reviewer's review.pane and ac-qa.sh's
// agent-<task>.pane stay their own business.
//
// GATE INDEPENDENCE GUARD, stated with its RESIDUAL in the same breath because
// the two are one contract: a steer into an ac-gate-agent:<family>-<stage> pane
// is REFUSED unless the caller declares --captain. The gate judge is the one
// pane agent whose whole value is that the chief whose stage it judges did not
// shape its turn, and what this refuses is the ACCIDENTAL steer - a chief
// reaching for this helper without noticing that the handle names the judge
// about to rule on its own work. Every OTHER pane agent steers unchanged: this
// guards a judge, not every verification pane. WHO is steering is DECLARED by
// the caller and never inferred from the environment - no tty sniffing, no
// parent-process inspection, no AC_SCOPE reading; the precedent is ac-spawn.sh's
// --captain-initiated. An inferred distinction would misfire in both directions
// while READING as non-bypassable, which is worse than a guard that says what it
// is. THE GUARD IS ADVISORY, AND A DETERMINED CHIEF CAN BYPASS IT: any chief may
// invoke this with --captain, and a chief can write straight to the backend pane
// without coming near it at all. It stops the accidental steer, not the
// deliberate one. A later reader who finds a bypass has found DOCUMENTED
// BEHAVIOUR, not a defect - so do not "harden" this into a proof it was never
// ruled to be.
//
// Turn-end (SESSION arm): a Stop hook in DIR/.claude/settings.local.json touches
// a per-invocation marker.
//
// TURN-END ISOLATION (the authoritative contract): that hook is MERGED into the
// file, never written over it. Two pane agents can share ONE worktree, and the
// old whole-file truncate deleted whichever hook was already there, so the
// agent mid-turn lost its turn-end and degraded to the 120s idle fallback below,
// or timed out; it also deleted any permission grant claude itself had written
// into that same file under --permission-mode auto. So: read, append our own
// entry to hooks.Stop, publish by atomic replace - all under a mkdir lock
// (.claude/.ac-pane-agent.lock, git-excluded like the settings file it guards)
// so two overlapping read-modify-write cycles cannot lose an entry. Only OUR
// OWN entries are ever dropped, and only when the pid in their marker path is
// gone: a live agent's hook always survives, while the array still cannot grow
// without bound across many runs. A malformed or hand-edited file fails SOFT to
// a fresh one rather than killing the launch.
//
// AWAIT (the authoritative contract): `--await-file <path>` says a turn end is
// NOT the end of the turn while that file is absent. The recorded reason: a
// reviewer that fanned its scout lanes out as subagents ended its turn at once,
// because the Agent tool launched asynchronously and took no flag to wait -
// so the Stop-hook marker fired, the round was harvested and the pane reaped
// with three lanes still running and nobody left to read them. While the file
// is absent a marker is CONSUMED and the poll continues, and the idle fallback
// holds the same way; an agent still waiting on that work (a collector call,
// a background task) resumes when it lands, finishes with its evidence, and
// the marker it fires then ends the turn. A final message written BEFORE the
// file appeared (its mtime, read once when first seen) holds a turn end the
// same way: only a turn end whose final message postdates it counts. An agent
// that ended its turn with nothing pending is held until --timeout: nothing
// here wakes it. The caller owns the file and writes it when the awaited work
// is done (ac-verify.sh writes the fan-out ledger there). --timeout still
// bounds the whole wait.
//
// IDLE FALLBACK (the authoritative contract): transcript idle >120s with a final
// assistant message AND an idle agent_status (herdr idle|done; orca idle) also
// ends the turn, in case project hooks fail to load. It EXISTS for a recorded
// reason and is not to be tightened into uselessness: the Stop hook can fail to
// fire, and long xhigh-thinking stretches write nothing to the transcript for
// minutes, which is why transcript mtime alone once declared turns finished
// early (the root cause of truncated reviews on large repos). SESSION ARM ONLY,
// structurally: inside the wait loop the transcript is resolved for the session
// arm alone, and the fallback is gated on a resolved transcript - the other two
// arms fail closed at their own turn-end harvest. It is consulted after more
// than 45 polls. Its three questions - pane idle, transcript stale, any final
// text - ask NOTHING about whether the agent's WORK was produced, and the
// any-final-text check is satisfied by any assistant text anywhere, an aborted
// turn's last message included. That is how a learning scout which hit the org
// monthly spend limit after 23 Reads reported status ok having written no
// report, and its caller then consumed the retro window on it
// (data/learning/room.md 13:36:13Z). So a caller MAY DECLARE the artifact its
// prompt demanded, with --deliverable <path>, and this exit then refuses a pane
// that idled without it - status error, carrying the pane so the caller can
// still reap the agent, rather than burning the caller's whole timeout. Absent
// or EMPTY is no deliverable, the same rule the crewmate arm's verdict file is
// held to. The declaration is OPTIONAL and consulted NOWHERE ELSE: a caller that
// declares nothing keeps this exit as it was - right for the verification
// panes, whose deliverable IS the transcript their caller then schema-checks.
// Its last question is the caller's: the LAST assistant message must settle to
// text, or the exit refuses as the marker's does.
//
// BUSY-STALL BOUND (any arm with a resolved transcript - the session arm): the
// idle fallback above is gated on an idle/done agent_status, so a pane hung
// INSIDE one tool call behind a busy status - static transcript, static footer -
// was unbounded: nothing fired until the caller's whole timeout burned, reading
// as a slow reviewer (the known worst case of this class: a catastrophic-
// backtracking regex hung one bash call for a full day behind "Working...").
// A transcript static past AC_PANE_STALL_MAX seconds (default 2700, 0 disables)
// escalates status error carrying the pane - the clock runs from the LATER of
// the last transcript write and the wait's own start, so a resumed session's
// prior-turn mtime never counts - whatever agent_status claims: busy is
// evidence of a process, never of progress; an UNREADABLE status rides along
// for diagnosis and never vetoes the escalation. The default sits an order of
// magnitude past the longest xhigh no-write thinking stretch the idle
// fallback's 120s floor was built around, so the bound cannot re-introduce the
// truncated-review defect that floor exists to prevent.
//
// Trust: the worktree is pre-seeded as trusted in ~/.claude.json so the session
// starts undialoged. Placement: the pane lands in its FAMILY's workspace
// (ac-backend.sh FAMILY WORKSPACE GROUPING) - the caller (ac-verify.sh, the
// gate) exports AC_WINDOW_FAMILY, and the "<fleet> · <family>" workspace is
// resolved from it; absent/empty = the fleet ROOT workspace (the ac-self-task
// case). Session: AC_HERDR_SESSION > config/herdr-session > default.
//
// MECHANICS, in code order. Every verb first: an invalid backend
// (AC_BACKEND > config/backend > the AC_FLEET_STATE/../config/backend rung)
// refuses with `ERROR: unsupported backend '<b>' (valid backends: herdr, orca;
// tmux/wezterm were removed 2026-07-17)`, exit 1; HOME unset refuses with
// `ERROR: HOME is not set`, exit 1; PATH gains `:/opt/homebrew/bin:$HOME/.local/bin`
// (callers may start from launchd with a minimal environment) for every child;
// the session is read. A value flag with no value or an empty one, on every
// verb, is `ERROR: <flag> needs a value`, exit 1. No verb, or an unknown one, is
// the done error `usage: ac-pane-agent.sh run --cwd DIR --prompt-file F`.
//   close: the last `--pane` value (any other word skipped) closed, best-effort
//     and silent - orca `terminal close`, herdr raw `pane close`; exit 0.
//   steer: `--agent H`, `--pane P`, `--captain`, one text; refusals on stderr
//     (`ERROR: <text>`), exit 1, in order: `unknown arg <w>` for any `-*` word
//     (a text starting with `-` included); `steer takes ONE line of text`;
//     the usage line when neither --agent nor --pane names a pane; `refusing
//     to steer with an empty message`; `steer is herdr-only: ...` on orca;
//     `herdr not on PATH`. The handle resolves against herdr's raw `pane list`
//     through jq: with --pane, that id's ownership (OK/NOTAGENT, --agent
//     ignored); else the exact label (NONE/AMBIG/OK); the live agents' labels
//     in herdr's order, joined `, `, name every refusal's list. Then the gate
//     guard, the delivery (stdout `steered <label> (pane <id>)`, exit 0), or
//     its UNVERIFIED (2) / NOT confirmed refusal.
//   reap-pane: no id is `{"event":"reap-pane","note":"no pane id"}`; orca
//     closes, polls `terminal show` up to eight times 0.25 s apart while the
//     terminal stays connected, and reports `{"event":"reap-pane-done",
//     "pane":"<id>","closed":true|false}`; without herdr on PATH
//     `{"event":"reap-pane","note":"herdr not on PATH"}`; herdr plans from its
//     raw tab and pane lists (one jq over both, split at ===AC-SPLIT===): the
//     pane, then its tab when no sibling pane shares it and another tab lives
//     in its workspace, or the workspace when the tab was its last; each close
//     best-effort; `closed` is `pane get` failing. Exit 0.
//   reap: orca answers `{"event":"reap","note":"dead-cwd sweep is herdr-only;
//     orca panes reap by handle"}` before reading a word; `--dry-run` or an
//     unknown arg's done error; no herdr is `{"event":"reap","panes":0,
//     "tabs":0,"note":"herdr not on PATH"}`; else the panes of tabs labelled
//     `\Aac-[a-z0-9-]+-agent(-|\Z)` whose cwd is no directory, each
//     `{"event":"reap","pane":"<id>","cwd":"<cwd>","dry_run":0|1}` and closed
//     unless dry, a tab left with no live pane closed, then
//     `{"event":"reap-done","panes":<n>,"tabs":<n>,"dry_run":<d>}`. Exit 0.
//   run: every flag above (repeats: the last wins; any other word the done
//     error `unknown arg <w>`). Refusals in order, each a done error and
//     exit 1, BEFORE any pane or rung: `--exec runs a one-shot command: there
//     is no session to --resume`; `--exec places no pane: there is no
//     identity to write to --pane-file`; `--observe is only valid with --exec
//     (the one-shot arm)`; `kind must be [a-z0-9-]: <k>`; `timeout must be a
//     whole number of seconds: <t>` (a sign and decimal digits; a leading 0
//     is octal, so `010` is 8 s and `08` is no number - the wait ends exit 1,
//     nothing printed, once the pane or rung is placed, W4); the profile (no
//     --harness only: AC_FLEET_PROFILE_<KIND, upper, - as _>, a legacy
//     space-separated value split at ` model=`/` effort=`, else
//     `<bin>/ac-dispatch-select.sh --pane <kind>`, whose failure is `could not
//     resolve a pane profile for kind '<k>' (<its first stderr line, asked a
//     second time>) - see bin/ac-dispatch-select.sh --pane <k>`); the
//     CONTRADICTION CHECK (codereview, a profile resolved, no --harness:
//     AC_FLEET_AGENT_CODEREVIEW > config/codereview-agent naming another
//     harness than the profile's is the codereview-agent-mismatch warning -
//     WARN, never refuse, the caller surfaces it); the ladder; `invalid effort:
//     <e> (expected low|medium|high|xhigh|max|ultracode)`; the arm's refusals
//     (`... see HARNESS ARMS in bin/ac-pane-agent.sh`) and agy's effort
//     warning; `the crewmate arm runs '<h>', which Agent Crew cannot resume:
//     there is no session to --resume`; `cwd missing: <cwd>`; `prompt file
//     missing: <pf>`; for the interactive arms `orca not on PATH` / `herdr not
//     on PATH`.
//     PREPARATION: the transcript dir PROJ = claudeTranscriptRoot()/<cwd with
//     every / and . as ->. The SESSION arm seeds trust; the marker dir is
//     AC_FLEET_STATE/.pane-agent-tmp, else <home>/state/.pane-agent-tmp, else
//     /tmp (homeless is this module's NORMAL case, and its refusal is
//     swallowed: stdout and stderr are ONE stream to ac-verify, which
//     jq-parses it, so one stray diagnostic would fail every review round);
//     the marker is <dir>/ac-pane-turnend.<cwd basename>-<od's 4 random bytes
//     as hex>.<pid> (the random segment before the pid, so the dead-hook
//     pruner's `.<digits>` tail still matches); the one-shot files
//     ac-pane-exec.<b>.<pid>.{out,err,rc} and the crewmate files
//     ac-pane-verdict.<b>.<pid> and ac-pane-crew.<b>.<pid>.{exit,rc} are
//     removed first. The SESSION arm then makes <cwd>/.claude, appends any
//     missing `.claude/settings.local.json` and `.claude/.ac-pane-agent.lock`
//     line to the repo's info/exclude (git's absolute --git-path), takes the
//     lock (10 one-second PATH sleeps; never fatal), merges the Stop hook
//     (stop-hook below) and refuses `could not install the Stop hook into
//     <settings>` when that failed; the transcripts already there are noted.
//     The tab label is ac-<kind>-agent[-<AC_WINDOW_FAMILY>][-<branch, / as ->].
//     ENVPIN: `AC_HOME=<%q of the physical home> ` when AC_HOME is set, else
//     `AC_FLEET_NAME=<%q> ` when that is set, else nothing - a homeless caller
//     has no home to pin and never fabricates one - behind claudeConfigEnv.
//     LAUNCH LINE, by arm: ONE-SHOT `cd '<cwd>' && <envpin><form>
//     "$(cat '<pf>')" >'<out>' 2>'<err>'; printf %s $? >'<rc>'; touch
//     '<marker>'`; CREWMATE `cd '<cwd>' && <envpin><launch>; printf %s $?
//     >'<crew rc>'; touch '<exit>'`; SESSION `cd '<cwd>' && <envpin><launch,
//     --resume SID> "$(cat '<pf>')"`. The transcript root, the cwd basename,
//     the session id read off a transcript's name, the form and the launch
//     are each read as the original's `$(...)` read them, trailing LFs cut.
//     PLACEMENT: the ONE-SHOT rung is `sh -c <line>` in the background,
//     started through /bin/sh with SIGINT and SIGQUIT ignored as an async job
//     of a non-interactive shell was; ORCA is orcaPlacePane (`could not place
//     orca pane`); HERDR resolves the family workspace, adopts a tab carrying
//     the label in it (its first pane split right) or creates one there
//     (once more after re-resolving the workspace), refuses `could not create
//     herdr pane` / `could not resolve herdr tab for pane <p>`, renames the
//     pane ac-<kind>-agent:<label> and closes the workspace's default `1`
//     tabs. Then `--pane-file` (`<pane> <tab>` through an exclusive temp and
//     mv; `pane-file directory does not exist: <dir>` and `could not publish
//     pane identity: <file>`), `--observe` (the descriptor through an
//     exclusive temp and `mv -f`, failures silent), herdr's `pane run`, and
//     `--replace-pane` (close, verify, report). The deadline is the launch
//     time plus --timeout.
//     CREWMATE KICKOFF: came-up every 2 s up to 60 s (an exit marker refuses,
//     a bare shell refuses `did not come up`, an unreadable pane is a note),
//     the startup-dialog sequence, then the input-ready wait - per second a
//     dialog answer, idle AND a non-blank 40-line render byte-identical three
//     reads running, refused at 60 s or the deadline - then the typed line.
//     THE WAIT: every 2 s until the deadline - the session arm's transcript
//     announced once; a marker consumed (AWAIT may hold it) and harvested per
//     arm; a crewmate exit refused; every fifth poll the one-shot process or
//     the pane's liveness (`pane_closed`); the idle fallback; the stall bound;
//     at the deadline `{"event":"done","status":"timeout",...,"error":"turn
//     did not end within <t>s"}`.
// Exit: 0 an ok turn, close, reap-pane, reap, a steer delivered; 1 everything
// else; 128+n when a signal ends the process.
//
// HELPER SUBCOMMANDS - each replaced a python3 snippet the bash original
// started; the entry runs them in process, and bin/ac-lib.sh's
// ac_transcript_final_epoch still starts iso-epoch through bin/ac-bun.sh. They
// skip the entry's preamble above. A wrong word count is `ERROR: usage:
// pane-agent.ts seed-trust <cwd> | stop-hook <settings> <marker> |
// wrap-transcript | has-final-text <transcript> | iso-epoch <timestamp>`, exit 1.
// Started on their own, the caller's cwd arrives as the first argument and
// enterCaller (src/lib.ts) returns there, so a relative path is the caller's -
// and when that cwd has no name, a relative path can be neither read nor
// written.
//
//   seed-trust <cwd>
//     Marks <cwd> (the raw string, never normalized) trusted in ~/.claude.json
//     ($HOME with trailing slashes dropped, the passwd home when HOME is
//     unset). A file that cannot be read or parsed is left alone and never
//     created, and an entry whose hasTrustDialogAccepted and
//     hasCompletedProjectOnboarding are both truthy is left alone: exit 0.
//     Otherwise both become true - an existing key keeps its place, a new one
//     is appended - and the document is rewritten with a 2-space indent.
//     A document, `projects` or entry that is not an object: exit 1, nothing
//     written.
//   stop-hook <settings> <marker>
//     Merges {"hooks":[{"type":"command","command":"touch '<marker>'"}]} onto
//     the end of hooks.Stop in <settings> and rewrites it on one line. A file
//     that cannot be read, parsed, or is not an object starts from {}; a
//     `hooks` that is not an object is replaced in its place, a hooks.Stop
//     that is not an array starts empty. Of the existing groups, only OUR OWN
//     dead ones go: exactly one hook whose command is
//     touch '[<dir>/]ac-pane-turnend.<name>.<pid>', and whose pid answers
//     kill(pid, 0) with ESRCH (EPERM, and a pid past the C int range, keep it).
//     A write that fails: exit 1.
//   wrap-transcript
//     Prints stdin as the one-message transcript line
//     {"type": "assistant", "message": {"role": "assistant", "content":
//     [{"type": "text", "text": <stdin>}]}} and a newline. Stdin that is not
//     UTF-8 (a BOM is text): exit 1, nothing printed.
//   has-final-text <transcript>
//     Exit 0 when some line - split at \n, \r\n or \r, whitespace-stripped,
//     parsed - is an object of type "assistant" whose message.content text
//     parts join to non-blank text; exit 1 otherwise, and also whenever the
//     python reader this replaced raised: the file cannot be read or is not
//     UTF-8, a line parses to a non-object, a message is truthy but not an
//     object, content is truthy but not iterable, or a text part is not a
//     string.
//   iso-epoch <timestamp>
//     Prints the stamp's epoch second, truncated toward zero, and a newline.
//     Accepted: YYYY-MM-DD[(T| )HH:MM[:SS[(.|,)digits]][Z|(+|-)HH:MM]] naming
//     a real date and time, every Z read as +00:00; no offset is local time.
//     Anything else: exit 1, nothing printed.
//
// Two of the helpers rewrite the USER's files, so python's json module is the
// contract byte for byte, on both sides. Reading: strict UTF-8 (a BOM is not
// JSON), python's scanner grammar including NaN, Infinity and -Infinity,
// integers of any length, an object keeping a repeated key's first place and
// last value. Writing: json.dumps defaults - ", " and ": ", or "," and a newline
// under an indent; every character outside printable ASCII as \uXXXX
// (lowercase, an astral one as its surrogate pair); integers as read, floats as
// python's repr (1.0, 5e-05, 1e+16); key order kept; no trailing newline. A
// rewrite goes to <file>.ac-pane-agent (created 0666 less the umask; a stale
// one keeps its mode), which is then renamed over <file>, replacing a symlink
// rather than following it.
//
// Deliberate divergences of the helpers from the python:
//   - iso-epoch takes only the calendar form above, because every producer
//     (Claude Code's toISOString, date -u) writes it. python accepted a wider,
//     partly version-dependent set: every version also read an hour-only
//     time, any single character between date and time and an offset with
//     seconds; 3.11+ added basic, week-date, 24:00 and short offsets; 3.9
//     refused a comma and any fraction but 3 or 6 digits. A stamp with no
//     offset is local time as Bun resolves TZ: a POSIX rule string such as
//     UTC-7, which libc applied, reads as UTC.
//   - Input (stdin, ~/.claude.json, settings, a transcript) is decoded as
//     strict UTF-8 under every locale. python used the locale's encoding:
//     under ISO8859-1 it mojibaked non-ASCII text and rewrote the user's file
//     that way, and under C, POSIX or unset it let invalid stdin through with
//     surrogate escapes.
//   - An integer past 4300 digits is read here where python refused it.
//   - Nesting: python's writers failed past about 993 levels (its reads went
//     to about 116k on 3.14, 993 on 3.9); here a rewrite fails past about
//     10000 and a read past about 40000, so between those limits trust is
//     seeded and the hook installed where python failed. A read too deep to
//     parse fails the run and leaves the file as it was - never the {} an
//     unreadable file starts from, which would drop its content.
//
// The mechanics stay the original's by spawning what it ran at the same
// points: jq (fail()'s encoding and every read the original piped through jq,
// each program verbatim), raw `herdr --session <s>` for placement, liveness,
// the closes and steer's list (herdr_cli's bounded twin elsewhere), orca
// through orcaJson, git, grep -qxF, mkdir -p, mv, od, tr, sed-free readings of
// sed's own patterns, date(1) for every clock read and the PATH's sleep for
// every wait, so a suite's stubs bind both sides.
//
// ESCAPE HATCH. Every independent review (ac-verify codereview and qa, the
// solo session's slice reviews included), every staged and maintenance gate and
// the Learning scout is a turn of this module, so a broken land stops them all
// at once - and the slice that fixes it cannot get its own review. The frozen
// original starts src/pane-agent.ts's helpers and src/dispatch-select.ts, which
// import the live src/lib.ts, so a bin copy over the live src dies with the
// thing it escapes: run a FULL ARCHIVE of the pre-port tree instead -
//   o=$(cd "$(mktemp -d)" && pwd -P); git -C <repo> archive <pre-port sha> | tar -x -C "$o"
// then per call AC_VERIFY_PANE_BIN="$o/bin/ac-pane-agent.sh" for ac-verify and
// AC_PANE_AGENT="$o/bin/ac-pane-agent.sh" for the gate, ac-learn and ship's
// finish; when ac-verify itself cannot start, run "$o/bin/ac-verify.sh" (its
// default pane agent is the archive's). src/teardown.ts names
// <bin>/ac-pane-agent.sh with no override - its reap is a soft WARN; close the
// pane by hand or run the archive's teardown. Nothing a pane keeps bakes "$o"
// (the launch line names the cwd, the prompt and the marker dir; the Stop hook
// names the marker). The captain's revert of the land is the last resort.
//
// AT PARITY (each pinned in the leg until its own fix lands):
// - W1: ONE failed liveness read is a dead pane - every fifth poll one raw
//   `pane get` (orca `terminal show`'s connected) and ANY failure ends a live
//   turn `pane_closed`, against ac-backend.sh's WINDOW LIVENESS three states.
// - W2: the raw herdr calls (placement, liveness, --replace-pane, close,
//   reap-pane, reap, steer's list) carry no bound, so --timeout bounds nothing
//   they hang on; orca is unbounded by design.
// - W3: the NDJSON events are built by raw interpolation, so a `"`, `\` or a
//   control byte in a path, label, pane id or config value yields a line jq
//   cannot parse (fail()'s refusals are jq-encoded).
// - W4: the octal reading of a leading-0 --timeout (`010` is 8 s; `08` ends the
//   run exit 1, nothing printed, after the pane or rung is placed and left
//   running), and `0` or a negative one is an immediate timeout.
// - W5: a non-integer AC_PANE_STALL_MAX turns the stall bound off, a
//   non-integer AC_PANE_SETTLE_TRIES the settle re-reads (the test builtin's
//   own line is not printed - SHELL-OWN below).
// - W6: the info/exclude append glues onto an unterminated last line.
// - W8: raw calls name `--session <s>` with the literal `default` when nothing
//   is set, while the bounded herdr calls name no session then.
// - W9: the shell's [:space:] under the caller's locale decides a blank final
//   message (grep and tr are spawned), while the any-final-text check keeps
//   python's white space.
// - W10: the session arm has no came-up gate: a refused `pane run` waits out
//   the whole --timeout and reports `timeout`.
// - W13: `pane-file directory does not exist` refuses AFTER placement, leaving
//   the pane.
// - W14: .pane-agent-tmp is never pruned; a dead Stop hook stays until the
//   next merge in that cwd.
// - W15: the arm refusals point at `HARNESS ARMS in bin/ac-pane-agent.sh`.
// - Two same-label agents in one family workspace both adopt one tab; two
//   session agents sharing a cwd each adopt the NEWEST new transcript.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - BUN (W11): every verb needs bun on the CALLER's PATH (the shim's `ERROR:
//   required tool not found: bun`, exit 1, no NDJSON), where the original
//   found it after its own PATH hardening - and close, reap-pane, reap and
//   steer ran without it.
// - --timeout (Q3): anything but a sign and decimal digits - a name, an
//   expression, a radix prefix, a fraction, a unit - is refused before any
//   pane or rung, where bash evaluated it after placing (a name naming no
//   variable ended the run 0 with nothing printed, `1+1` was 2 s, `SECONDS`
//   about 0).
// - SHELL-OWN STDERR (W12) is not reproduced, the status kept: a value flag
//   with no value or an empty one is `ERROR: <flag> needs a value` where the
//   shell printed `line <n>: 2: parameter null or not set` (close and
//   reap-pane exit 1 there, against their always-0 contract, as before); HOME
//   unset is `ERROR: HOME is not set` for the shell's unbound line; the test
//   builtin's `integer expression expected`, the arithmetic and unbound lines
//   of W4, a redirection's own line (an unwritable exclude, wrap or descriptor
//   temp).
// - SIGINT (W7): no handler is registered, as the original set no trap: TERM
//   and HUP end the process at once (143, 129), the rung or pane left
//   running, and so does INT to the pid alone (130), where bash waited its
//   foreground sleep out and went on. An agent started as an async job of a
//   non-interactive shell (ac-verify's round, the Learning scout) inherits
//   SIGINT ignored, and the original then ignored INT outright - as this port
//   does, since bun keeps the inherited SIG_IGN; the 130 needs a foreground
//   start. The rung keeps the original's ignored SIGINT and SIGQUIT.
// - HOME RESOLUTION: an AC_HOME cd cannot enter pins `AC_HOME='' ` without
//   cd's own line, and a home whose name ends in LF is pinned whole.
// - EXCLUSIVE TEMP (W13): --pane-file and --observe write through
//   <path>.tmp.<pid> (then .<n>) created exclusively, where the original wrote
//   through whatever sat at the predictable name.
// - BYTES: argv and the environment arrive decoded, so a byte that is no UTF-8
//   in a flag or env value reaches the events, files and children as U+FFFD,
//   where the original wrote the byte (fail()'s jq already wrote U+FFFD);
//   BSD sed and tr no longer abort on such a byte (the empty slug, the cut
//   branch - FAIL-PATH).
// - The kind grammar is read per its text ([a-z0-9-]), where bash 3.2's range
//   under a UTF-8 locale also admitted accented letters.
// - The transcripts are ordered by mtime and, on a tie, by name's bytes, where
//   `ls -t` collated the tie under the caller's locale (uuid names agree).
// - LOCK GRACE: a pid-less Stop-hook lock's age is read from the clock, where
//   the original spawned `date +%s`.
// - The helper subcommands are verbs of this module and so reach through the
//   shim, where `ac-pane-agent.sh wrap-transcript` was the usage error; they
//   run in process, where the original started bun for each (whose own
//   failure was the harvest's).
// - A caller whose cwd has no name resolves no relative path the helpers read
//   or write (the Stop hook, a transcript), as the started helpers did not.
//
// CALLERS: bin/ac-verify.sh (`${AC_VERIFY_PANE_BIN:-<bin>/ac-pane-agent.sh}`:
// the codereview and qa round in the background with stdout and stderr in one
// file, the correction turn, the scout lanes of its generated run-lanes.sh,
// `reap-pane` requiring `closed:true`) - so src/ship.ts review-agent and
// bin/ac-qa.sh agent through it; src/gate.ts (`${AC_PANE_AGENT:-...} run --exec`,
// then reap-pane); bin/ac-learn.sh (the scout in the background with
// --deliverable and --pane-file, its EXIT-trap reap); src/ship.ts finish
// (close); src/teardown.ts (reap-pane, no override); chiefs (steer, reap). The
// pane file `<pane> <tab>` is read by ac-verify and ac-learn while the turn
// runs; the transcript by transcriptFinal (src/lib.ts). Each caller already
// treats a non-zero or done-less run as a failed turn, and each already needs
// bun.

import { appendFileSync, closeSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import { userInfo } from "node:os";
import { dirname, isAbsolute } from "node:path";
import {
  STARTED_BIN,
  arithValue,
  backendAgentIdlePane,
  backendAgentStatusPane,
  backendCapturePane,
  backendDialogAnswerPane,
  backendHarnessUpPane,
  backendRoute,
  backendSendLinePane,
  backendStartupDialogsPane,
  buildLaunch,
  claudeConfigEnv,
  claudeTranscriptRoot,
  commandV,
  configReadSoft,
  die,
  enterCaller,
  exclusiveTemp,
  fileMtime,
  harnessPaneArm,
  herdrResolveWorkspace,
  herdrTabOpen,
  lockAcquire,
  lockRelease,
  orcaJson,
  orcaPlacePane,
  paneProfile,
  physicalDir,
  shellQuote,
  shellStatus,
  spawnShell,
  spawnShellSync,
  tabFields,
  testInt,
  transcriptFinalEpoch,
  writeAll,
  wsFamilyLabel,
} from "./lib.ts";

export type Py = null | boolean | bigint | number | string | Py[] | Map<string, Py>;

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

export function decodeStrict(bytes: Uint8Array): string {
  return UTF8.decode(bytes);
}

const NUMBER = /-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/y;
const ESCAPE: Record<string, string> = { '"': '"', "\\": "\\", "/": "/", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t" };
const LITERALS: [string, Py][] = [["null", null], ["true", true], ["false", false], ["NaN", NaN], ["Infinity", Infinity], ["-Infinity", -Infinity]];

export function loads(s: string): Py {
  let i = 0;
  const bad = (): never => {
    throw new SyntaxError(`not JSON at offset ${i}`);
  };
  const ws = () => {
    while (i < s.length && " \t\n\r".includes(s[i])) i++;
  };
  const string = (): string => {
    let out = "";
    let run = ++i;
    for (;;) {
      if (i >= s.length) bad();
      const c = s.charCodeAt(i);
      if (c === 0x22) {
        out += s.slice(run, i++);
        return out;
      }
      if (c === 0x5c) {
        out += s.slice(run, i);
        const e = s[i + 1];
        if (e === "u") {
          const hex = s.slice(i + 2, i + 6);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) bad();
          out += String.fromCharCode(parseInt(hex, 16));
          i += 6;
        } else if (e !== undefined && Object.hasOwn(ESCAPE, e)) {
          out += ESCAPE[e];
          i += 2;
        } else bad();
        run = i;
        continue;
      }
      if (c < 0x20) bad();
      i++;
    }
  };
  const value = (): Py => {
    if (s[i] === '"') return string();
    if (s[i] === "{") {
      const obj = new Map<string, Py>();
      i++;
      ws();
      if (s[i] === "}") {
        i++;
        return obj;
      }
      for (;;) {
        if (s[i] !== '"') bad();
        const key = string();
        ws();
        if (s[i] !== ":") bad();
        i++;
        ws();
        obj.set(key, value());
        ws();
        if (s[i] === "}") {
          i++;
          return obj;
        }
        if (s[i] !== ",") bad();
        i++;
        ws();
      }
    }
    if (s[i] === "[") {
      const arr: Py[] = [];
      i++;
      ws();
      if (s[i] === "]") {
        i++;
        return arr;
      }
      for (;;) {
        arr.push(value());
        ws();
        if (s[i] === "]") {
          i++;
          return arr;
        }
        if (s[i] !== ",") bad();
        i++;
        ws();
      }
    }
    for (const [literal, v] of LITERALS)
      if (s.startsWith(literal, i)) {
        i += literal.length;
        return v;
      }
    NUMBER.lastIndex = i;
    const m = NUMBER.exec(s) ?? bad();
    i = NUMBER.lastIndex;
    return m[1] === undefined && m[2] === undefined ? BigInt(m[0]) : Number(m[0]);
  };
  ws();
  const v = value();
  ws();
  if (i !== s.length) bad();
  return v;
}

function floatRepr(x: number): string {
  if (Number.isNaN(x)) return "NaN";
  if (x === Infinity) return "Infinity";
  if (x === -Infinity) return "-Infinity";
  if (x === 0) return Object.is(x, -0) ? "-0.0" : "0.0";
  const sign = x < 0 ? "-" : "";
  // toExponential() with no argument gives the shortest round-trip digits,
  // the same digits python's repr chooses; only the layout differs.
  const [mantissa, e] = Math.abs(x).toExponential().split("e");
  const digits = mantissa.replace(".", "");
  const exp = Number(e);
  const point = exp + 1;
  if (point <= -4 || point > 16)
    return `${sign}${digits[0]}${digits.length > 1 ? `.${digits.slice(1)}` : ""}e${exp < 0 ? "-" : "+"}${String(Math.abs(exp)).padStart(2, "0")}`;
  if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`;
  if (point >= digits.length) return `${sign}${digits}${"0".repeat(point - digits.length)}.0`;
  return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`;
}

const SHORT: Record<number, string> = { 0x08: "\\b", 0x09: "\\t", 0x0a: "\\n", 0x0c: "\\f", 0x0d: "\\r" };

function jsonString(s: string): string {
  let out = '"';
  for (let k = 0; k < s.length; k++) {
    const c = s.charCodeAt(k);
    if (c === 0x22) out += '\\"';
    else if (c === 0x5c) out += "\\\\";
    else if (c >= 0x20 && c <= 0x7e) out += s[k];
    else out += SHORT[c] ?? `\\u${c.toString(16).padStart(4, "0")}`;
  }
  return `${out}"`;
}

export function dumps(v: Py, indent?: number, level = 1): string {
  if (v === null) return "null";
  if (v === true) return "true";
  if (v === false) return "false";
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number") return floatRepr(v);
  if (typeof v === "string") return jsonString(v);
  const open = indent === undefined ? "" : `\n${" ".repeat(indent * level)}`;
  const close = indent === undefined ? "" : `\n${" ".repeat(indent * (level - 1))}`;
  const sep = indent === undefined ? ", " : `,${open}`;
  if (Array.isArray(v)) return v.length ? `[${open}${v.map((x) => dumps(x, indent, level + 1)).join(sep)}${close}]` : "[]";
  return v.size ? `{${open}${[...v].map(([k, x]) => `${jsonString(k)}: ${dumps(x, indent, level + 1)}`).join(sep)}${close}}` : "{}";
}

export function truthy(v: Py | undefined): boolean {
  if (v === undefined || v === null || v === false) return false;
  if (v === true) return true;
  if (typeof v === "bigint") return v !== 0n;
  if (typeof v === "number") return Number.isNaN(v) || v !== 0;
  if (typeof v === "string" || Array.isArray(v)) return v.length > 0;
  return v.size > 0;
}

// python's str.isspace(), which is neither JS \s (that takes U+FEFF and leaves
// U+001C-U+001F and U+0085) nor the shell's [:space:].
const PY_SPACE = "[\\t\\n\\v\\f\\r\\x1c-\\x20\\x85\\xa0\\u{1680}\\u{2000}-\\u{200a}\\u{2028}\\u{2029}\\u{202f}\\u{205f}\\u{3000}]";
const PY_STRIP = new RegExp(`^${PY_SPACE}+|${PY_SPACE}+$`, "gu");

export function strip(s: string): string {
  return s.replace(PY_STRIP, "");
}

function child(d: Py, key: string): Map<string, Py> {
  if (!(d instanceof Map)) throw new TypeError(`not an object where ${JSON.stringify(key)} belongs`);
  if (!d.has(key)) d.set(key, new Map());
  const v = d.get(key);
  if (!(v instanceof Map)) throw new TypeError(`${JSON.stringify(key)} is not an object`);
  return v;
}

export function seedTrust(doc: Py, cwd: string): boolean {
  const entry = child(child(doc, "projects"), cwd);
  if (truthy(entry.get("hasTrustDialogAccepted")) && truthy(entry.get("hasCompletedProjectOnboarding"))) return false;
  entry.set("hasTrustDialogAccepted", true);
  entry.set("hasCompletedProjectOnboarding", true);
  return true;
}

const OUR_HOOK = /^touch '(?:[^\n]*\/)?ac-pane-turnend\.[^/']*\.([0-9]+)'\n?$/;

export function pidGone(pid: bigint): boolean {
  if (pid > 2147483647n) return false;
  try {
    process.kill(Number(pid), 0);
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ESRCH";
  }
  return false;
}

export function mergeStopHook(doc: Py | undefined, marker: string, gone: (pid: bigint) => boolean): Map<string, Py> {
  const d = doc instanceof Map ? doc : new Map<string, Py>();
  const h = d.get("hooks");
  const hooks = h instanceof Map ? h : new Map<string, Py>();
  const s = hooks.get("Stop");
  const stop = (Array.isArray(s) ? s : []).filter((group) => {
    if (!(group instanceof Map)) return true;
    const inner = group.get("hooks");
    if (!Array.isArray(inner) || inner.length !== 1 || !(inner[0] instanceof Map)) return true;
    const command = inner[0].get("command");
    const m = typeof command === "string" ? OUR_HOOK.exec(command) : null;
    return m === null || !gone(BigInt(m[1]));
  });
  stop.push(new Map([["hooks", [new Map<string, Py>([["type", "command"], ["command", `touch '${marker}'`]])]]]));
  hooks.set("Stop", stop);
  d.set("hooks", hooks);
  return d;
}

export function wrapTranscript(text: string): string {
  const part = new Map<string, Py>([["type", "text"], ["text", text]]);
  const message = new Map<string, Py>([["role", "assistant"], ["content", [part]]]);
  return `${dumps(new Map<string, Py>([["type", "assistant"], ["message", message]]))}\n`;
}

export function hasFinalText(text: string): boolean {
  let found = false;
  for (const raw of text.split(/\r\n|\r|\n/)) {
    const line = strip(raw);
    if (!line) continue;
    let d: Py;
    try {
      d = loads(line);
    } catch {
      continue;
    }
    if (!(d instanceof Map)) return false;
    if (d.get("type") !== "assistant") continue;
    const m = d.get("message");
    const message = truthy(m) ? m! : new Map<string, Py>();
    if (!(message instanceof Map)) return false;
    const c = message.get("content");
    const content = truthy(c) ? c! : [];
    const parts = Array.isArray(content) ? content : content instanceof Map ? [...content.keys()] : typeof content === "string" ? [...content] : null;
    if (parts === null) return false;
    let joined = "";
    for (const part of parts) {
      if (!(part instanceof Map) || part.get("type") !== "text") continue;
      const t = part.has("text") ? part.get("text") : "";
      if (typeof t !== "string") return false;
      joined += t;
    }
    if (strip(joined)) found = true;
  }
  return found;
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?(?:([+-])(\d{2}):(\d{2}))?)?$/;

export function isoEpoch(stamp: string): number | null {
  const m = ISO.exec(stamp.replaceAll("Z", "+00:00"));
  if (!m) return null;
  const [y, mo, d, h, mi, s] = m.slice(1, 7).map((x) => Number(x ?? 0));
  const micros = Number(`${m[7] ?? ""}000000`.slice(0, 6));
  const utc = new Date(0);
  utc.setUTCFullYear(y, mo - 1, d);
  // A day or month out of range rolls the date into another month.
  if (y < 1 || utc.getUTCMonth() !== mo - 1 || h > 23 || mi > 59 || s > 59) return null;
  let seconds: number;
  if (m[8] !== undefined) {
    const offset = (m[8] === "-" ? -1 : 1) * (Number(m[9]) * 3600 + Number(m[10]) * 60);
    if (Math.abs(offset) >= 86400) return null;
    utc.setUTCHours(h, mi, s, 0);
    seconds = utc.getTime() / 1000 - offset;
  } else {
    const local = new Date(0);
    local.setFullYear(y, mo - 1, d);
    local.setHours(h, mi, s, 0);
    seconds = local.getTime() / 1000;
  }
  const epoch = Math.trunc(seconds + micros / 1e6);
  return epoch === 0 ? 0 : epoch;
}

function claudeJson(): string {
  return `${(process.env.HOME ?? userInfo().homedir).replace(/\/+$/, "")}/.claude.json`;
}

function helperFiles(atCaller: boolean) {
  const reachable = (path: string): string => {
    if (!atCaller && !isAbsolute(path)) throw new Error(`the caller's directory has no name, so ${path} cannot be resolved`);
    return path;
  };
  return {
    reachable,
    readJson: (path: string): Py => loads(decodeStrict(readFileSync(reachable(path)))),
    publish: (path: string, text: string): void => {
      const tmp = `${reachable(path)}.ac-pane-agent`;
      writeFileSync(tmp, text);
      renameSync(tmp, path);
    },
  };
}
type HelperFiles = ReturnType<typeof helperFiles>;

function seedTrustFile(cwd: string, files: HelperFiles): void {
  const file = claudeJson();
  let doc: Py;
  try {
    doc = files.readJson(file);
  } catch {
    return;
  }
  if (seedTrust(doc, cwd)) files.publish(file, dumps(doc, 2));
}

function stopHookFile(settings: string, marker: string, files: HelperFiles): void {
  let doc: Py | undefined;
  try {
    doc = files.readJson(settings);
  } catch (e) {
    // Too deep for the stack is not unreadable: starting from {} would
    // rewrite the file without its content.
    if (e instanceof RangeError) throw e;
  }
  files.publish(settings, dumps(mergeStopHook(doc, marker, pidGone)));
}

function hasFinalTextFile(transcript: string, files: HelperFiles): boolean {
  let text: string | null = null;
  try {
    text = decodeStrict(readFileSync(files.reachable(transcript)));
  } catch {}
  return text !== null && hasFinalText(text);
}

const HELPERS: Record<string, number> = { "seed-trust": 1, "stop-hook": 2, "wrap-transcript": 0, "has-final-text": 1, "iso-epoch": 1 };

function helper(args: string[], atCaller: boolean): void | Promise<void> {
  const files = helperFiles(atCaller);
  const [sub, ...rest] = args;
  if (sub === undefined || HELPERS[sub] !== rest.length)
    die("usage: pane-agent.ts seed-trust <cwd> | stop-hook <settings> <marker> | wrap-transcript | has-final-text <transcript> | iso-epoch <timestamp>");
  switch (sub) {
    case "seed-trust":
      return seedTrustFile(rest[0]!, files);
    case "stop-hook":
      return stopHookFile(rest[0]!, rest[1]!, files);
    case "wrap-transcript":
      return Bun.stdin.arrayBuffer().then(async (b) => {
        await Bun.write(Bun.stdout, wrapTranscript(decodeStrict(new Uint8Array(b))));
      });
    case "has-final-text":
      process.exitCode = hasFinalTextFile(rest[0]!, files) ? 0 : 1;
      return;
    case "iso-epoch": {
      const epoch = isoEpoch(rest[0]!);
      if (epoch === null) {
        process.exitCode = 1;
        return;
      }
      return Bun.write(Bun.stdout, `${epoch}\n`).then(() => {});
    }
  }
}

// --- the entry ---

// The one-shot forms, by harness: <model>, <effort> (already mapped by
// effortFlag) and the --timeout text, each composed only when set. Effort is
// per-harness in SHAPE as well as value: codex takes a config override, claude
// a flag, opencode a variant, pi a thinking tier; an unset knob passes
// NOTHING, leaving the engine's own default in charge, and a harness with no
// proven form here is refused, never guessed at. src/brain.ts's synthCommand
// keeps a twin of every registry harness's form that must print these bytes
// (tests/sh/ac-brain.test.sh). codex always carries `-c
// model_reasoning_summary=auto`: a real gate run emits no reasoning bytes by
// codex's own default (`none`), which the gate needs to show the captain.
// pi and cursor have their safety boundary NAMED rather than pretended:
// neither CLI has codex's kernel-level read-only sandbox - pi -p keeps its
// tools (the judge must READ context paths) and write-restraint is the judge
// prompt's law; cursor-agent -p --trust unlocks headless reads, and --yolo is
// deliberately ABSENT, so unapproved mutations deny by default.
// agy (Antigravity CLI), MEASURED 2026-09-12, differs in every clause:
//   - `-p` takes the NEXT token as its prompt, so it comes LAST (the prompt is
//     appended positionally; `-p --model x` read "--model" as the prompt);
//   - the model NAME carries spaces and its own effort tier ("Gemini 3.8 Flash
//     (Low)"), so it is quoted, and effort is dropped: agy refuses --effort
//     beside a model that names one (the run warns instead);
//   - `--mode plan` is a real read-only boundary (a turn told to write a file,
//     and one told to write it THROUGH bash, both left the cwd untouched);
//   - `--dangerously-skip-permissions` is required for the turn to read
//     anything at all - headless auto-DENIES the tool permission it cannot
//     prompt for; it removes the prompt, not the plan-mode boundary;
//   - `--print-timeout` is agy's OWN wait ceiling in print mode, default 5m0s
//     (`agy --help`, 2026-09-15), past which it exits 0 with an EMPTY stdout
//     ("printed nothing" here) - 11 of 36 agy scout lanes in one home died that
//     way under a 900s budget - so the run's --timeout text is handed over in
//     the Go duration form the CLI reads.
const opt = (flag: string, v: string): string => (v === "" ? "" : ` ${flag} ${v}`);
export const ONESHOT: Record<string, (m: string, e: string, timeout: string) => string> = {
  codex: (m, e) => `codex exec -s read-only --skip-git-repo-check${opt("-m", m)}${e === "" ? "" : ` -c model_reasoning_effort=${e}`} -c model_reasoning_summary=auto`,
  claude: (m, e) => `claude -p${opt("--model", m)}${opt("--effort", e)}`,
  opencode: (m, e) => `opencode run${opt("-m", m)}${opt("--variant", e)}`,
  pi: (m, e) => `pi -p${opt("--model", m)}${opt("--thinking", e)}`,
  cursor: (m) => `cursor-agent -p --trust${opt("--model", m)}`,
  agy: (m, _e, timeout) => `agy --mode plan --dangerously-skip-permissions${m === "" ? "" : ` --model "${m}"`} --print-timeout ${timeout}s -p`,
};

export function oneshotLaunch(h: string, m = "", e = "", timeout = ""): string | null {
  return Object.hasOwn(ONESHOT, h) ? ONESHOT[h]!(m, e, timeout) : null;
}

// The effort an engine receives: the five tiers and "" as given, ultracode as
// xhigh (the claude preset's reasoning tier only - its '/effort ultracode'
// slash line is ac-spawn's kickoff, with no counterpart in one turn); null for
// any other value, which the run refuses.
export function effortFlag(e: string): string | null {
  if (["", "low", "medium", "high", "xhigh", "max"].includes(e)) return e;
  return e === "ultracode" ? "xhigh" : null;
}

const FAIL_JQ = '{event:"done",status:"error",error:$e}';
const STEER_JQ = String.raw`
      # A pane agent is exactly a pane THIS helper named at creation.
      [(try fromjson catch null) | .result?.panes?[]? | objects
       | {id: .pane_id, label: (.label // "")}
       | select(.label | type == "string" and startswith("ac-") and contains("-agent:"))] as $agents
      | (if $pid != "" then
           ([$agents[] | select(.id == $pid)] | if length > 0 then "OK \(.[0].id) \(.[0].label)" else "NOTAGENT" end)
         else
           ([$agents[] | select(.label == $want)]
            | if length == 0 then "NONE"
              elif length > 1 then "AMBIG \(length) \(map(.id) | join(" "))"
              else "OK \(.[0].id) \(.[0].label)" end)
         end),
        ($agents[] | "KNOWN \(.label) \(.id)")`;
const REAP_PANE_JQ = String.raw`
      split("===AC-SPLIT===") as $raw
      | [$raw[0] | try fromjson catch null | .result?.tabs?[]? | objects] as $tabs
      | [$raw[1] // "" | try fromjson catch null | .result?.panes?[]? | objects] as $panes
      | ([$panes[] | select(.pane_id == $rp) | .tab_id] | last) as $tab
      | ([$tabs[] | select(.tab_id == $tab) | .workspace_id] | last) as $ws
      # A sibling pane in the same tab keeps the tab; another tab in the same
      # workspace (a co-tenant reviewer/qa run, or the bare default "1" tab) keeps
      # the workspace. Close the workspace ONLY when the target tab is its last.
      | "PANE \($rp)",
        if ($tab // "") == "" or any($panes[]; .tab_id == $tab and .pane_id != $rp) then empty
        elif ($ws // "") == "" then empty
        elif any($tabs[]; .workspace_id == $ws and .tab_id != $tab) then "TAB \($tab)"
        else "WS \($ws)" end`;
const REAP_OURS = String.raw`split("===AC-SPLIT===") as $raw
    | [$raw[1] // "" | try fromjson catch null | .result?.panes?[]? | objects] as $panes
    | [$raw[0] | try fromjson catch null | .result?.tabs?[]? | objects
       | select(.label // "" | type == "string" and test("\\Aac-[a-z0-9-]+-agent(-|\\Z)")) | .tab_id]
    | reduce .[] as $t ([]; if any(.[]; . == $t) then . else . + [$t] end)
    | map(. as $t | {tab: $t, panes: [$panes[] | select(.tab_id == $t)]})`;
const REAP_CWDS = ' | .[].panes[] | .cwd // empty | select(. != "")';
const REAP_PLAN = String.raw`
    | ($gone | split("\n")) as $gone
    | [.[].panes[] | select(.cwd // "" | . != "" and IN($gone[]))] as $dead
    | ($dead[] | "PANE \(.pane_id) \(.cwd)"),
      # A tab whose every pane is being reaped is left empty; close it too so the
      # sidebar does not fill with stubs. A tab with a surviving pane stays.
      (.[] | select(.panes != [] and all(.panes[]; .pane_id as $p | any($dead[]; .pane_id == $p))) | "TAB \(.tab)")`;
const ADOPT_JQ = 'first(.result.tabs[]? | select(.label == $tl and ($ws == "" or .workspace_id == $ws))) | .tab_id // empty';
const FIRST_PANE_JQ = "first(.result.panes[]? | select(.tab_id == $tab)) | .pane_id // empty";
const DEFAULT_TABS_JQ = '.result.tabs[]? | select(.workspace_id == $ws and .label == "1") | .tab_id';
const CONNECTED_JQ = ".result.terminal.connected == true";
const FINAL_TEXT_JQ = `[.[] | select(.type == "assistant")] | last
          | if . == null then "" else
              ([(.message.content // [])[] | select(.type == "text") | .text] | join(""))
            end`;

type Io = "inherit" | "ignore" | "pipe";

// One spawned child as a shell stage: its status, and its stdout and stderr
// when piped.
function sh(cmd: string[], stdin: "inherit" | "ignore" | Buffer, stdout: Io, stderr: Io): { status: number; out: Buffer; err: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0), err: stderr === "pipe" && r ? Buffer.from(r.stderr) : Buffer.alloc(0) };
}

// `$(...)`'s reading: NULs dropped, trailing LFs cut. Bytes the lib hands over
// as latin1 cross to text here.
const subst = (b: Buffer): string => b.toString("utf8").replace(/\0/g, "").replace(/\n+$/, "");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const lat = (s: string): string => Buffer.from(s, "utf8").toString("latin1");

const emit = (line: string): void => void writeSync(1, Buffer.from(`${line}\n`, "utf8"));

function fail(msg: string): never {
  emit(subst(sh(["jq", "-cn", "--arg", "e", msg, FAIL_JQ], "inherit", "pipe", "inherit").out));
  process.exit(1);
}

const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const nonEmpty = (p: string): boolean => {
  try {
    return statSync(p).size > 0;
  } catch {
    return false;
  }
};
const exists = (p: string): boolean => {
  try {
    statSync(p);
    return true;
  } catch {
    return false;
  }
};
const readText = (p: string): string | null => {
  try {
    return subst(readFileSync(p));
  } catch {
    return null;
  }
};

// `$(basename <p> [<suffix>])`.
function baseName(p: string, suffix = ""): string {
  const t = p.replace(/\/+$/, "");
  if (t === "") return p === "" ? "" : "/";
  const b = t.slice(t.lastIndexOf("/") + 1);
  return (suffix !== "" && b !== suffix && b.endsWith(suffix) ? b.slice(0, -suffix.length) : b).replace(/\n+$/, "");
}

// `read -r a b ... rest` with the default IFS: blanks around dropped, fields
// split at blank runs, the last name keeping the rest of the line.
function ifsRead(line: string, n: number): string[] {
  const out: string[] = [];
  let rest = line.replace(/^[ \t\n]+/, "");
  for (let i = 1; i < n && rest !== ""; i++) {
    const m = /[ \t\n]+/.exec(rest);
    if (!m) break;
    out.push(rest.slice(0, m.index));
    rest = rest.slice(m.index + m[0].length);
  }
  out.push(rest.replace(/[ \t\n]+$/, ""));
  while (out.length < n) out.push("");
  return out;
}

// The lines a `while read` loop reads: each LF-terminated one, an unterminated
// tail never.
const readLines = (b: Buffer): string[] => b.toString("utf8").split("\n").slice(0, -1);

// `[ <a> -lt|-ge|-gt <b> ]`: false whenever either side is no integer.
function test(a: string, op: "-lt" | "-ge" | "-gt", b: string): boolean {
  const x = testInt(a);
  const y = testInt(b);
  if (x === null || y === null) return false;
  return op === "-lt" ? x < y : op === "-ge" ? x >= y : x > y;
}

// `$(( <a> - <b> ))` over two operand texts; null where the shell's
// arithmetic refused them.
function minus(a: string, b: string): string | null {
  try {
    return String(BigInt.asIntN(64, arithValue(a) - arithValue(b)));
  } catch {
    return null;
  }
}

const dateS = (): string => subst(sh(["date", "+%s"], "inherit", "pipe", "inherit").out);
const pause = (secs: string): void => void sh(["sleep", secs], "inherit", "ignore", "inherit");

// The wait loop's sleep lets the event loop run, so the one-shot rung's exit
// is reaped and its pid reads gone, as bash reaped its background job.
async function pauseAsync(secs: string): Promise<void> {
  try {
    await spawnShell(["sleep", secs], { stdin: "inherit", stdout: "ignore", stderr: "inherit" }).exited;
  } catch {}
}

// `--flag ${2:?}`: the flag's value, or the refusal the shell's own
// `parameter null or not set` stood for.
function valueOf(args: string[], i: number): string {
  const v = args[i + 1];
  if (v === undefined || v === "") die(`${args[i]} needs a value`);
  return v;
}

let SES = "";
let AT_CALLER = true;

const herdr = (args: string[], stdout: Io = "ignore", stdin: "inherit" | "ignore" = "inherit"): { status: number; out: Buffer } =>
  sh(["herdr", "--session", SES, ...args], stdin, stdout, "ignore");
// `ac_backend 2>/dev/null || printf herdr`.
const backendSoft = (): string => backendRoute("ignore") ?? "herdr";
const orcaConnected = (h: string): boolean => {
  const out = orcaJson(["terminal", "show", "--terminal", h], "inherit");
  return out !== null && sh(["jq", "-e", CONNECTED_JQ], Buffer.from(`${out}\n`, "latin1"), "ignore", "ignore").status === 0;
};

function close(args: string[]): never {
  let cp = "";
  for (let i = 0; i < args.length; i++) if (args[i] === "--pane") cp = valueOf(args, i++);
  if (cp !== "") {
    if (backendSoft() === "orca") orcaJson(["terminal", "close", "--terminal", cp], "inherit");
    else herdr(["pane", "close", cp]);
  }
  process.exit(0);
}

function steer(args: string[]): never {
  let handle = "";
  let paneArg = "";
  let text = "";
  let captain = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--agent") handle = valueOf(args, i++);
    else if (a === "--pane") paneArg = valueOf(args, i++);
    else if (a === "--captain") captain = true;
    else if (a.startsWith("-")) die(`unknown arg ${a}`);
    else {
      if (text !== "") die("steer takes ONE line of text");
      text = a;
    }
  }
  if (handle === "" && paneArg === "") die("usage: ac-pane-agent.sh steer --agent <handle> '<text>' [--pane <pane-id>]");
  if (text === "") die("refusing to steer with an empty message");
  if (backendSoft() === "orca") die("steer is herdr-only: an orca pane agent carries no ac-<kind>-agent:<label> name to resolve - address it in Orca itself");
  if (!commandV("herdr")) die("herdr not on PATH");
  // A dead or recycled pane is simply not in herdr's live list, so a stale
  // handle can never steer a stranger.
  const plan = subst(sh(["jq", "-Rrs", "--arg", "want", handle, "--arg", "pid", paneArg, STEER_JQ], herdr(["pane", "list"], "pipe").out, "pipe", "inherit").out);
  const lines = plan.split("\n");
  const known = lines
    .flatMap((l) => {
      const m = /^KNOWN ([\s\S]*) [^ ]*$/.exec(l);
      return m ? [m[1]!] : [];
    })
    .join(",")
    .replaceAll(",", ", ");
  const [kind, pane, label] = ifsRead(lines[0]!, 3) as [string, string, string];
  if (kind === "AMBIG") die(`handle '${handle}' matches ${pane} live panes (${label}) - re-run with --pane <pane-id> to name the one you mean`);
  if (kind === "NOTAGENT") die(`pane '${paneArg}' is not a live pane agent (no ac-<kind>-agent:<label> name) - refusing to steer a stranger's pane; live pane agents: ${known || "none"}`);
  if (kind !== "OK") die(`no live pane agent named '${handle}' - live pane agents: ${known || "none"}`);
  // Applied after the pane RESOLVES, so --agent and --pane are guarded by the
  // one check and the refusal can name the pane it stopped.
  if (label.startsWith("ac-gate-agent:") && !captain) {
    const fam = label.slice("ac-gate-agent:".length);
    const cut = fam.lastIndexOf("-");
    die(
      `refusing to steer ${label} (pane ${pane}): it is the INDEPENDENT GATE JUDGE for family '${cut < 0 ? fam : fam.slice(0, cut)}' - the chief whose stage it judges must not shape the turn that rules on it. If you are the captain, say so: --captain (the captain outranks this property).`,
    );
  }
  const sent = backendSendLinePane(pane, text, { stderr: "inherit" });
  if (sent.exited) process.exit(sent.status);
  if (sent.status === 2) die(`delivery UNVERIFIED for ${label} (pane ${pane}) - could not read the pane, so the submit was neither confirmed nor refuted: read it with 'herdr pane read ${pane}' before resending`);
  if (sent.status !== 0) die(`delivery NOT confirmed for ${label} (pane ${pane}) - the text likely sits stranded unsubmitted in its composer: read it with 'herdr pane read ${pane}', resubmit with 'herdr pane send-keys ${pane} enter'`);
  writeSync(1, Buffer.from(`steered ${label} (pane ${pane})\n`, "utf8"));
  process.exit(0);
}

function reapPane(args: string[]): never {
  let rp = "";
  for (let i = 0; i < args.length; i++) if (args[i] === "--pane") rp = valueOf(args, i++);
  if (rp === "") {
    emit('{"event":"reap-pane","note":"no pane id"}');
    process.exit(0);
  }
  if (backendSoft() === "orca") {
    // An orca pane closes ALONE - the family tab dies with its last pane by
    // itself, so there is no tab/workspace cascade to plan.
    orcaJson(["terminal", "close", "--terminal", rp], "inherit");
    for (let i = 0; i < 8 && orcaConnected(rp); i++) pause("0.25");
    emit(`{"event":"reap-pane-done","pane":"${rp}","closed":${orcaConnected(rp) ? "false" : "true"}}`);
    process.exit(0);
  }
  if (!commandV("herdr")) {
    emit('{"event":"reap-pane","note":"herdr not on PATH"}');
    process.exit(0);
  }
  const tabs = herdr(["tab", "list"], "pipe").out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  const panes = herdr(["pane", "list"], "pipe").out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  const plan = sh(["jq", "-Rrs", "--arg", "rp", rp, REAP_PANE_JQ], Buffer.from(`${tabs}\n===AC-SPLIT===\n${panes}\n`, "latin1"), "pipe", "inherit");
  for (const line of `${subst(plan.out)}\n`.split("\n")) {
    const [kind, id] = ifsRead(line, 2) as [string, string];
    if (kind === "PANE") herdr(["pane", "close", id], "ignore", "ignore");
    else if (kind === "TAB") herdr(["tab", "close", id], "ignore", "ignore");
    else if (kind === "WS") herdr(["workspace", "close", id], "ignore", "ignore");
  }
  emit(`{"event":"reap-pane-done","pane":"${rp}","closed":${herdr(["pane", "get", rp]).status === 0 ? "false" : "true"}}`);
  process.exit(0);
}

function reap(args: string[]): never {
  if (backendSoft() === "orca") {
    emit('{"event":"reap","note":"dead-cwd sweep is herdr-only; orca panes reap by handle"}');
    process.exit(0);
  }
  let dry = 0;
  for (const a of args) {
    if (a === "--dry-run") dry = 1;
    else fail(`unknown arg ${a}`);
  }
  if (!commandV("herdr")) {
    emit('{"event":"reap","panes":0,"tabs":0,"note":"herdr not on PATH"}');
    process.exit(0);
  }
  const tabs = herdr(["tab", "list"], "pipe").out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  const panes = herdr(["pane", "list"], "pipe").out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
  const lists = Buffer.from(`${tabs}\n===AC-SPLIT===\n${panes}`, "latin1");
  // jq cannot stat, so our panes' cwds are checked here and the gone ones
  // handed back. A cwd holding a newline never matches one, so it is never
  // reaped.
  const gone = readLines(sh(["jq", "-Rrs", REAP_OURS + REAP_CWDS], lists, "pipe", "inherit").out)
    .filter((c) => !isDir(c))
    .join("\n");
  const plan = sh(["jq", "-Rrs", "--arg", "gone", gone, REAP_OURS + REAP_PLAN], lists, "pipe", "inherit");
  let np = 0;
  let nt = 0;
  for (const line of `${subst(plan.out)}\n`.split("\n")) {
    const [kind, id, rest] = ifsRead(line, 3) as [string, string, string];
    if (kind === "PANE") {
      emit(`{"event":"reap","pane":"${id}","cwd":"${rest}","dry_run":${dry}}`);
      if (!dry) herdr(["pane", "close", id], "ignore", "ignore");
      np++;
    } else if (kind === "TAB") {
      if (!dry) herdr(["tab", "close", id], "ignore", "ignore");
      nt++;
    }
  }
  emit(`{"event":"reap-done","panes":${np},"tabs":${nt},"dry_run":${dry}}`);
  process.exit(0);
}

const RUN_FLAGS = ["--cwd", "--prompt-file", "--resume", "--label", "--kind", "--timeout", "--replace-pane", "--pane-file", "--model", "--effort", "--harness", "--observe", "--deliverable", "--await-file"];

// `ac_state_dir 2>/dev/null`: <physical home>/state, minted when it can be;
// "" homeless or where cd cannot enter the home.
function stateDirQuiet(): string {
  const h = process.env.AC_HOME ? physicalDir(process.env.AC_HOME) : null;
  if (h === null) return "";
  try {
    mkdirSync(`${h}/state`, { recursive: true });
  } catch {}
  return `${h}/state`;
}

async function run(args: string[]): Promise<never> {
  const flags = new Map<string, string>([["--label", "agent"], ["--kind", "ship"], ["--timeout", "7200"]]);
  let execArm = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "--exec") execArm = true;
    else if (RUN_FLAGS.includes(a)) flags.set(a, valueOf(args, i++));
    else fail(`unknown arg ${a}`);
  }
  const flag = (f: string): string => flags.get(f) ?? "";
  const CWD = flag("--cwd");
  const PF = flag("--prompt-file");
  const SID = flag("--resume");
  const LABEL = flag("--label");
  const KIND = flag("--kind");
  const TIMEOUT = flag("--timeout");
  const REPLACE = flag("--replace-pane");
  const PANEFILE = flag("--pane-file");
  const HFLAG = flag("--harness");
  const OBSERVE = flag("--observe");
  const DELIVERABLE = flag("--deliverable");
  const AWAITFILE = flag("--await-file");
  let MODEL = flag("--model");
  let EFFORT = flag("--effort");

  // A caller that passed --resume believes it is continuing a conversation,
  // and one that passed --pane-file would later reap an empty handle: refusing
  // beats ignoring either.
  if (execArm && SID) fail("--exec runs a one-shot command: there is no session to --resume");
  if (execArm && PANEFILE) fail("--exec places no pane: there is no identity to write to --pane-file");
  if (OBSERVE && !execArm) fail("--observe is only valid with --exec (the one-shot arm)");
  if (KIND === "" || /[^a-z0-9-]/.test(KIND)) fail(`kind must be [a-z0-9-]: ${KIND}`);
  if (!/^[+-]?[0-9]+$/.test(TIMEOUT)) fail(`timeout must be a whole number of seconds: ${TIMEOUT}`);

  const ku = KIND.toUpperCase().replaceAll("-", "_");
  const env = (name: string): string => process.env[name] ?? "";
  let PROFILE = "";
  if (!HFLAG) {
    PROFILE = env(`AC_FLEET_PROFILE_${ku}`);
    // A crewmate spawned before the wire became TAB-separated still hands over
    // the old SPACE-separated triple for its whole life; splitting on the two
    // key boundaries accepts both, and keeps a legacy line's spaced model.
    if (PROFILE !== "" && !PROFILE.includes("\t"))
      PROFILE = PROFILE.split("\n")
        .map((l) => l.replace(" model=", "\tmodel=").replace(" effort=", "\teffort="))
        .join("\n")
        .replace(/\n+$/, "");
    if (PROFILE === "") {
      // Absent resolves empty and falls through; a resolver ERROR must not -
      // a misconfigured profile quietly degraded to the ladder would put the
      // judge back on the defaults without saying so.
      const r = paneProfile(KIND, "ignore");
      PROFILE = u8(r.out);
      if (r.status !== 0) {
        const why = sh([`${STARTED_BIN}/ac-dispatch-select.sh`, "--pane", KIND], "inherit", "ignore", "pipe");
        fail(`could not resolve a pane profile for kind '${KIND}' (${why.err.toString("utf8").replace(/\0/g, "").split("\n")[0]}) - see bin/ac-dispatch-select.sh --pane ${KIND}`);
      }
    }
  }
  const profileField = (k: number, key: string): string => {
    const v = tabFields(PROFILE.split("\n")[0]!, 3)[k]!;
    return v.startsWith(key) ? v.slice(key.length) : v;
  };
  if (KIND === "codereview" && !HFLAG && PROFILE) {
    const configured = env(`AC_FLEET_AGENT_${ku}`) || configReadSoft(`${KIND}-agent`, "");
    const ph = configured ? profileField(0, "harness=") : "";
    if (ph && ph !== configured)
      emit(
        `{"event":"warning","reason":"codereview-agent-mismatch","message":"config/codereview-agent=${configured} but the dispatched panes.codereview profile resolved harness=${ph} - the profile wins by design (ATOMIC-profile contract), so this round runs on ${ph}, not the configured engine"}`,
      );
  }
  let HARNESS = "claude";
  if (HFLAG) HARNESS = HFLAG;
  else if (PROFILE) {
    HARNESS = profileField(0, "harness=");
    MODEL ||= profileField(1, "model=");
    EFFORT ||= profileField(2, "effort=");
  } else {
    if (KIND === "codereview" || KIND === "qa") {
      MODEL = MODEL || env(`AC_FLEET_MODEL_${ku}`) || configReadSoft(`${KIND}-model`, "") || "opus";
      HARNESS = env(`AC_FLEET_AGENT_${ku}`) || configReadSoft(`${KIND}-agent`, "") || "claude";
      EFFORT = EFFORT || env(`AC_FLEET_EFFORT_${ku}`) || configReadSoft(`${KIND}-effort`, "");
    } else MODEL = MODEL || env("AC_FLEET_MODEL") || configReadSoft("model", "");
    EFFORT = EFFORT || env("AC_FLEET_EFFORT") || configReadSoft("effort", "");
  }
  // Validated before a pane is placed, so a bad knob fails through the NDJSON
  // protocol instead of leaking a live pane whose claude then refuses the flag.
  let EFFORT_FLAG = effortFlag(EFFORT) ?? fail(`invalid effort: ${EFFORT} (expected low|medium|high|xhigh|max|ultracode)`);

  let ARM: "session" | "crewmate" | "oneshot";
  if (execArm) {
    ARM = "oneshot";
    if (oneshotLaunch(HARNESS, "", "", TIMEOUT) === null)
      fail(
        `harness '${HARNESS}' has no one-shot form here (armed for --exec: codex, claude, opencode, pi, cursor, agy) - a one-shot arm owes the command form whose process exit is the turn end and whose stdout is the final message; see HARNESS ARMS in bin/ac-pane-agent.sh`,
      );
    // A caller that asked for a tier and got the model's own should hear it
    // from the run, not infer it from a bill.
    if (HARNESS === "agy" && EFFORT_FLAG) {
      emit(`{"event":"warning","message":"agy carries its effort tier inside the model name and refuses --effort; the configured effort '${EFFORT_FLAG}' was dropped - pick the model whose name states the tier you want"}`);
      EFFORT_FLAG = "";
    }
  } else
    ARM =
      harnessPaneArm(HARNESS) ??
      fail(
        `harness '${HARNESS}' has no arm here for an interactive turn (armed: claude as a pane SESSION; codex, opencode, pi and cursor through the CREWMATE contract) - arming another means VERIFYING that it writes its final message where its brief tells it to and announces its own completion; see HARNESS ARMS in bin/ac-pane-agent.sh`,
      );
  if (ARM === "crewmate" && SID) fail(`the crewmate arm runs '${HARNESS}', which Agent Crew cannot resume: there is no session to --resume`);
  if (!isDir(CWD)) fail(`cwd missing: ${CWD}`);
  if (!isFile(PF)) fail(`prompt file missing: ${PF}`);
  // A one-shot needs no backend at all: its callers were panes carrying no
  // AC_HOME, and resolving one here opened herdr panes for an orca fleet.
  let PA_BACKEND = "";
  if (ARM !== "oneshot") {
    PA_BACKEND = backendSoft();
    if (PA_BACKEND === "orca") {
      if (!commandV("orca")) fail("orca not on PATH");
    } else if (!commandV("herdr")) fail("herdr not on PATH");
  }

  const PROJ = `${(claudeTranscriptRoot() ?? "").replace(/\n+$/, "")}/${CWD.replace(/[/.]/g, "-").replace(/\n+$/, "")}`;
  const files = helperFiles(AT_CALLER);
  if (ARM === "session")
    try {
      seedTrustFile(CWD, files);
    } catch {}

  // Homeless is this module's normal case, and the state dir's refusal is
  // swallowed: ac-verify reads stdout and stderr as ONE stream it jq-parses.
  let MARKDIR = process.env.AC_FLEET_STATE || stateDirQuiet();
  MARKDIR = MARKDIR ? `${MARKDIR}/.pane-agent-tmp` : "/tmp";
  if (sh(["mkdir", "-p", MARKDIR], "inherit", "inherit", "ignore").status !== 0) MARKDIR = "/tmp";
  const b = baseName(CWD);
  const pid = process.pid;
  // The run's own name, not just its pid: every lane of a review round writes
  // into one marker dir, and the random segment sits before the pid so the
  // dead-hook pruner's `.<digits>` tail still matches.
  const MARKER = `${MARKDIR}/ac-pane-turnend.${b}-${sh(["od", "-An", "-N4", "-tx1", "/dev/urandom"], "inherit", "pipe", "ignore").out.toString("latin1").replace(/[ \n]/g, "")}.${pid}`;
  const rmF = (...ps: string[]): void => {
    for (const p of ps)
      try {
        rmSync(p, { force: true });
      } catch {}
  };
  rmF(MARKER);
  const OUTF = `${MARKDIR}/ac-pane-exec.${b}.${pid}.out`;
  const ERRF = `${MARKDIR}/ac-pane-exec.${b}.${pid}.err`;
  const RCF = `${MARKDIR}/ac-pane-exec.${b}.${pid}.rc`;
  const VERDICT = `${MARKDIR}/ac-pane-verdict.${b}.${pid}`;
  const EXITMARK = `${MARKDIR}/ac-pane-crew.${b}.${pid}.exit`;
  const CRCF = `${MARKDIR}/ac-pane-crew.${b}.${pid}.rc`;
  if (ARM === "oneshot") rmF(OUTF, ERRF, RCF);
  else if (ARM === "crewmate") rmF(VERDICT, EXITMARK, CRCF);
  else {
    sh(["mkdir", "-p", `${CWD}/.claude`], "inherit", "inherit", "inherit");
    const SETTINGS = `${CWD}/.claude/settings.local.json`;
    const SLOCK = `${CWD}/.claude/.ac-pane-agent.lock`;
    // --path-format=absolute: --git-path alone answers a path relative to the
    // CALLER's cwd, which is the worktree only by luck.
    const excl = subst(sh(["git", "-C", CWD, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], "inherit", "pipe", "ignore").out);
    if (excl) {
      sh(["mkdir", "-p", dirname(excl)], "inherit", "inherit", "ignore");
      for (const pat of [".claude/settings.local.json", ".claude/.ac-pane-agent.lock"])
        if (sh(["grep", "-qxF", pat, excl], "inherit", "inherit", "ignore").status !== 0)
          try {
            appendFileSync(excl, `${pat}\n`);
          } catch {}
    }
    // A lock not taken is never fatal: a wedged lock must not cost a turn, and
    // the atomic replace still leaves a valid file.
    let locked = false;
    try {
      locked = lockAcquire(SLOCK, 10, () => pause("1"));
    } catch {}
    let installed = true;
    try {
      stopHookFile(SETTINGS, MARKER, files);
    } catch (e) {
      writeSync(2, Buffer.from(`ERROR: ${e instanceof Error ? e.message : String(e)}\n`, "utf8"));
      installed = false;
    }
    if (locked) lockRelease(SLOCK);
    if (!installed) fail(`could not install the Stop hook into ${SETTINGS}`);
  }

  // The before-set of new-session detection. $PROJ may hold SOMEONE ELSE'S
  // sessions (a chief runs claude in the fleet home), so only the session arm
  // ever reads past it.
  const BEFORE = new Set<string>();
  try {
    for (const n of readdirSync(PROJ)) if (!n.startsWith(".") && n.endsWith(".jsonl")) BEFORE.add(n);
  } catch {}

  // The family rides the label because adoption is by label SESSION-WIDE: a
  // verifier lease sits on a detached checkout with no branch, and a second
  // family's verifier once adopted the first family's tab.
  const BRANCH = subst(sh(["git", "-C", CWD, "symbolic-ref", "--short", "HEAD"], "inherit", "pipe", "ignore").out);
  let TABLABEL = `ac-${KIND}-agent`;
  if (process.env.AC_WINDOW_FAMILY) TABLABEL += `-${process.env.AC_WINDOW_FAMILY}`;
  if (BRANCH) TABLABEL += `-${BRANCH.replaceAll("/", "-")}`;

  // A fresh pane inherits NOTHING. A homed caller pins its physical home; a
  // homeless one passes the fleet NAME alone when it was told one, so the
  // pane's own ac-*.sh calls land their tabs in the fleet's group - and
  // neither is ever fabricated.
  let ENVPIN = "";
  if (process.env.AC_HOME) ENVPIN = `AC_HOME=${u8(shellQuote(lat(physicalDir(process.env.AC_HOME) ?? "")))} `;
  else if (process.env.AC_FLEET_NAME) ENVPIN = `AC_FLEET_NAME=${u8(shellQuote(lat(process.env.AC_FLEET_NAME)))} `;
  ENVPIN = `${u8(claudeConfigEnv())}${ENVPIN}`;
  // `;` not `&&` before each record-and-touch: the marker must fire on a
  // failure too, or a dead engine would burn the caller's whole timeout.
  let RUNCMD: string;
  if (ARM === "oneshot") RUNCMD = `cd '${CWD}' && ${ENVPIN}${(oneshotLaunch(HARNESS, MODEL, EFFORT_FLAG, TIMEOUT) ?? "").replace(/\n+$/, "")} "$(cat '${PF}')" >'${OUTF}' 2>'${ERRF}'; printf %s $? >'${RCF}'; touch '${MARKER}'`;
  else if (ARM === "crewmate") RUNCMD = `cd '${CWD}' && ${ENVPIN}${(buildLaunch(HARNESS, MODEL, EFFORT_FLAG) ?? "").replace(/\n+$/, "")}; printf %s $? >'${CRCF}'; touch '${EXITMARK}'`;
  else RUNCMD = `cd '${CWD}' && ${ENVPIN}${(buildLaunch(HARNESS, MODEL, EFFORT_FLAG, SID) ?? "").replace(/\n+$/, "")} "$(cat '${PF}')"`;

  let P = "";
  let TAB = "";
  let rung: ReturnType<typeof spawnShell> | null = null;
  if (ARM === "oneshot") {
    // An async job of a non-interactive shell ran with SIGINT and SIGQUIT
    // ignored and stdin /dev/null, and every harness it execs inherits that.
    rung = spawnShell(["/bin/sh", "-c", 'trap "" INT QUIT; exec sh -c "$0"', RUNCMD], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
    rung.unref();
  } else if (PA_BACKEND === "orca") {
    const placed = orcaPlacePane(CWD, RUNCMD, `ac-${KIND}`);
    if (placed === null) fail("could not place orca pane");
    const at = u8(placed).indexOf(" ");
    P = at < 0 ? u8(placed) : u8(placed).slice(0, at);
    TAB = at < 0 ? u8(placed) : u8(placed).slice(at + 1);
  } else {
    // The workspace is resolved FIRST and scopes the adoption: a tab carrying
    // the right label in the WRONG workspace is never adopted. An unresolvable
    // workspace falls back to label-only adoption.
    let WS = "";
    const resolveWs = (): void => {
      WS = u8(herdrResolveWorkspace(wsFamilyLabel(lat(process.env.AC_WINDOW_FAMILY ?? "")).replace(/\n+$/, ""), true) ?? "");
    };
    const tabOpen = (): void => {
      const created = herdrTabOpen(lat(SES), lat(TABLABEL), lat(CWD), lat(WS));
      if (created === null) return;
      const c = u8(created);
      const at = c.indexOf(" ");
      P = at < 0 ? c : c.slice(0, at);
      TAB = at < 0 ? c : c.slice(at + 1);
    };
    resolveWs();
    TAB = subst(sh(["jq", "-r", "--arg", "tl", TABLABEL, "--arg", "ws", WS, ADOPT_JQ], herdr(["tab", "list"], "pipe").out, "pipe", "ignore").out);
    if (TAB) {
      const first = subst(sh(["jq", "-r", "--arg", "tab", TAB, FIRST_PANE_JQ], herdr(["pane", "list"], "pipe").out, "pipe", "ignore").out);
      const split = herdr(["pane", "split", first, "--direction", "right", "--no-focus"], "pipe").out.toString("utf8");
      P = split.split("\n").map((l) => /^[^\n]*"pane_id":"([^"]*)"[^\n]*$/.exec(l)?.[1]).find((id) => id !== undefined) ?? "";
    } else {
      if (WS) tabOpen();
      if (!P) {
        resolveWs();
        if (WS) tabOpen();
      }
    }
    if (!P) fail("could not create herdr pane");
    if (!TAB) fail(`could not resolve herdr tab for pane ${P}`);
    herdr(["pane", "rename", P, `ac-${KIND}-agent:${LABEL}`]);
    // herdr spawns a workspace with a default "1" tab that lingers as sidebar
    // junk once a real tab lives there.
    if (WS) for (const jt of readLines(sh(["jq", "-r", "--arg", "ws", WS, DEFAULT_TABS_JQ], herdr(["tab", "list"], "pipe").out, "pipe", "ignore").out)) herdr(["tab", "close", jt.replace(/^[ \t]+|[ \t]+$/g, "")], "ignore", "ignore");
  }

  // The live identity is published before the agent launches, so the
  // verifier facade registers supervision without racing a done event.
  if (PANEFILE) {
    const cut = PANEFILE.lastIndexOf("/");
    const paneDir = cut < 0 ? "." : PANEFILE.slice(0, cut);
    if (!isDir(paneDir)) fail(`pane-file directory does not exist: ${paneDir}`);
    let tmp = "";
    let ok = false;
    try {
      const t = exclusiveTemp(`${PANEFILE}.tmp`);
      tmp = t.path;
      try {
        writeAll(t.fd, Buffer.from(`${P} ${TAB}\n`, "utf8"));
      } finally {
        closeSync(t.fd);
      }
      ok = sh(["mv", tmp, PANEFILE], "inherit", "inherit", "inherit").status === 0;
    } catch {}
    if (!ok) {
      if (tmp) rmF(tmp);
      fail(`could not publish pane identity: ${PANEFILE}`);
    }
  }
  if (OBSERVE && ARM === "oneshot")
    try {
      const t = exclusiveTemp(`${OBSERVE}.tmp`);
      try {
        writeAll(t.fd, Buffer.from(`{"pane":"${P}","tab":"${TAB}","harness":"${HARNESS}","prompt":"${PF}","out":"${OUTF}","err":"${ERRF}"}\n`, "utf8"));
      } finally {
        closeSync(t.fd);
      }
      sh(["mv", "-f", t.path, OBSERVE], "inherit", "inherit", "ignore");
    } catch {}
  if (ARM !== "oneshot" && PA_BACKEND !== "orca") herdr(["pane", "run", P, RUNCMD]);

  // Best-effort and never fatal - the new pane is already placed - but the
  // outcome is REPORTED, as reap-pane reports its own.
  if (REPLACE) {
    let closed: boolean;
    if (PA_BACKEND === "orca") {
      orcaJson(["terminal", "close", "--terminal", REPLACE], "inherit");
      closed = !orcaConnected(REPLACE);
    } else {
      herdr(["pane", "close", REPLACE]);
      closed = herdr(["pane", "get", REPLACE]).status !== 0;
    }
    emit(`{"event":"replace-pane","pane":"${REPLACE}","closed":${closed}}`);
  }

  // The caller's timeout starts at the launch, so the crewmate arm's own
  // startup steps count against it, as the session arm's claude startup does.
  const waitStart = dateS();
  let deadline: string | null = null;
  try {
    deadline = String(BigInt.asIntN(64, arithValue(waitStart) + arithValue(TIMEOUT)));
  } catch {}
  // A deadline the shell's arithmetic refused (`08`) left it unset, and the
  // first read of it ended the run under set -u.
  const dl = (): string => deadline ?? process.exit(1);

  const crewRc = (): string => readText(CRCF) ?? "unrecorded";
  if (ARM === "crewmate") {
    // A backstop for a pane that never starts anything; a harness that starts
    // and then EXITS is caught by its exit marker in the first seconds.
    const upBudget = 60;
    let up = 0;
    let waited = 0;
    for (;;) {
      if (isFile(EXITMARK)) fail(`harness '${HARNESS}' exited (status ${crewRc()}) before its pane could take a prompt - nothing was delivered and no turn ran`);
      const r = backendHarnessUpPane(P, { stderr: "inherit" });
      if (r.exited) process.exit(r.status);
      up = r.status;
      if (up === 0 || waited >= upBudget) break;
      pause("2");
      waited += 2;
    }
    // An unreadable pane (2) is no evidence the harness died, so the prompt
    // still goes.
    if (up === 1) fail(`harness '${HARNESS}' did not come up in its pane within ${upBudget}s - every foreground process is a shell, so no prompt is delivered and the turn is REFUSED`);
    if (up !== 0) emit(`{"event":"note","path":"could not read the pane to verify ${HARNESS} came up - delivering the prompt anyway"}`);
    const dialogs = backendStartupDialogsPane(P, HARNESS, { stderr: "inherit" });
    if (dialogs.exited) process.exit(dialogs.status);
    // A crewmate takes the foreground before its composer exists, and idle
    // arrives too early: a boot redraw would fake the verified submit's
    // acceptance, so the render must also hold still three reads running.
    let readyWaited = 0;
    let same = 0;
    let render = "";
    for (;;) {
      if (isFile(EXITMARK)) fail(`harness '${HARNESS}' exited (status ${crewRc()}) before its input surface became ready - no prompt was delivered`);
      const answered = backendDialogAnswerPane(P, { stderr: "ignore" });
      if (answered.exited) process.exit(answered.status);
      const idle = backendAgentIdlePane(P, { stderr: "inherit" });
      if (idle.exited) process.exit(idle.status);
      if (idle.status === 0) {
        const cap = backendCapturePane(P, "40", { stdout: "pipe", stderr: "ignore" });
        const next = cap.exited ? "" : cap.out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
        if (subst(sh(["tr", "-d", "[:space:]"], Buffer.from(next, "latin1"), "pipe", "inherit").out) !== "") {
          if (next === render) same++;
          else {
            render = next;
            same = 1;
          }
          if (same >= 3) break;
        } else {
          render = "";
          same = 0;
        }
      } else {
        render = "";
        same = 0;
      }
      const now = dateS();
      if (readyWaited >= 60 || test(now, "-ge", dl())) fail(`harness '${HARNESS}' came up but its input surface did not become ready within ${readyWaited}s - no prompt was delivered`);
      pause("1");
      readyWaited++;
    }
    // ONE line, so it cannot half-submit into a composer; the marker path is
    // single-quoted so a state dir holding a space still yields a command.
    const kick = `Read and follow the instructions in ${PF}. Do NOT print your final message to the terminal: WRITE it to the file ${VERDICT} - that file's entire contents are your final message, and nothing else goes in it. Once it is written, announce your own completion by running this exact command: touch '${MARKER}'`;
    const sent = backendSendLinePane(P, kick, { stderr: "inherit" });
    if (sent.exited) process.exit(sent.status);
    if (sent.status === 2) emit('{"event":"note","path":"prompt delivery UNVERIFIED - the pane could not be read, so the submit is neither confirmed nor refuted"}');
    else if (sent.status !== 0)
      fail(`the verification prompt was NOT accepted by the pane: it sits unsubmitted in the composer of '${HARNESS}', so no turn will ever start - REFUSED rather than waited out`);
  }

  let TRANSCRIPT = "";
  let SOURCE = "transcript";
  let NEWSID = SID;
  const newestNew = (): string => {
    let names: string[] = [];
    try {
      names = readdirSync(PROJ);
    } catch {
      return "";
    }
    const rows: { p: string; n: string; t: bigint }[] = [];
    for (const n of names) {
      if (n.startsWith(".") || !n.endsWith(".jsonl")) continue;
      try {
        const st = statSync(`${PROJ}/${n}`, { bigint: true });
        if (!st.isDirectory()) rows.push({ p: `${PROJ}/${n}`, n, t: st.mtimeNs });
      } catch {}
    }
    rows.sort((x, y) => (x.t !== y.t ? (x.t > y.t ? -1 : 1) : Buffer.compare(Buffer.from(x.n), Buffer.from(y.n))));
    return rows.find((r) => !BEFORE.has(r.n))?.p ?? "";
  };
  const announce = (): boolean => {
    if (TRANSCRIPT) return true;
    const f = SID ? `${PROJ}/${SID}.jsonl` : newestNew();
    if (f === "" || (SID && !isFile(f))) return false;
    TRANSCRIPT = f;
    NEWSID = baseName(f, ".jsonl");
    emit(`{"event":"transcript","path":"${f}","session_id":"${NEWSID}"}`);
    return true;
  };
  // The one-message transcript wrap: the destination opened as the shell's
  // redirect opened it, the input UTF-8 or nothing, a written file non-empty.
  const wrapTo = (dest: string, input: Buffer): boolean => {
    let fd: number;
    try {
      fd = openSync(dest, "w");
    } catch {
      return false;
    }
    try {
      writeAll(fd, Buffer.from(wrapTranscript(decodeStrict(input)), "utf8"));
    } catch {
      return false;
    } finally {
      closeSync(fd);
    }
    return nonEmpty(dest);
  };
  const scrollback = (): boolean => {
    const cap = backendCapturePane(P, process.env.AC_PANE_SCROLLBACK_LINES || "400", { stdout: "pipe", stderr: "ignore" });
    if (cap.exited || cap.status !== 0) return false;
    const text = cap.out.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
    if (text === "") return false;
    const f = `${MARKDIR}/ac-pane-scrollback.${b}.${pid}.jsonl`;
    if (!wrapTo(f, Buffer.from(text, "latin1"))) return false;
    TRANSCRIPT = f;
    SOURCE = "scrollback";
    emit(`{"event":"transcript","path":"${f}","session_id":"${NEWSID}","source":"scrollback"}`);
    return true;
  };
  const harvestFrom = (src: string, dest: string, source: string): boolean => {
    let input: Buffer;
    try {
      input = readFileSync(src);
    } catch {
      return false;
    }
    if (!wrapTo(dest, input)) return false;
    TRANSCRIPT = dest;
    SOURCE = source;
    emit(`{"event":"transcript","path":"${dest}","session_id":"${NEWSID}","source":"${source}"}`);
    return true;
  };
  // The caller's own question: does the LAST assistant message carry text?
  // ac_transcript_final reads exactly this and returns empty when it does not.
  const finalHasText = (): boolean => {
    if (!TRANSCRIPT) return false;
    const final = sh(["jq", "-rs", FINAL_TEXT_JQ, TRANSCRIPT], "ignore", "pipe", "ignore").out;
    return sh(["grep", "-q", "[^[:space:]]"], final, "ignore", "inherit").status === 0;
  };
  // A verdict is written and THEN the Stop hook fires, but the file's last
  // flushed line can still be the tool_use before the text for a beat: re-read
  // a few times before believing the turn stopped without a final message.
  const finalSettles = (): boolean => {
    for (let i = 0n; ; i++) {
      const tries = testInt(process.env.AC_PANE_SETTLE_TRIES || "6");
      if (tries === null || i >= tries) break;
      if (finalHasText()) return true;
      pause(process.env.AC_PANE_SETTLE_SLEEP || "0.5");
      announce();
    }
    return finalHasText();
  };
  const agentStatus = (): string => {
    const r = backendAgentStatusPane(P, { stderr: "inherit" });
    return r.exited ? "" : subst(r.out);
  };
  const epochOf = (): string => {
    const r = transcriptFinalEpoch(TRANSCRIPT);
    return r.status === 0 ? r.out.replace(/\n+$/, "") : "";
  };
  const rungAlive = (): boolean => {
    if (rung === null || rung.exitCode !== null || rung.signalCode !== null) return false;
    try {
      process.kill(rung.pid, 0);
      return true;
    } catch {
      return false;
    }
  };
  const done = (status: string, error: string): never => {
    emit(`{"event":"done","status":"${status}","session_id":"${NEWSID}","transcript":"${TRANSCRIPT}","pane":"${P}","error":"${error}"}`);
    process.exit(1);
  };

  let awaitSeenAt = "";
  for (let i = 0; test(dateS(), "-lt", dl()); i++) {
    if (ARM === "session") announce();
    // The moment the awaited file APPEARED is the moment the fan-out finished.
    if (AWAITFILE && !awaitSeenAt && exists(AWAITFILE)) awaitSeenAt = fileMtime(AWAITFILE) ?? "";
    if (isFile(MARKER)) {
      // WHEN the turn-end signal arrived, kept before the marker is consumed:
      // a marker seconds old while the transcript still grows says the SIGNAL
      // fired early, not that the model stopped.
      const at = dateS();
      const markerAge = minus(at, fileMtime(MARKER) ?? dateS()) ?? "";
      rmF(MARKER);
      if (AWAITFILE && !exists(AWAITFILE)) {
        emit(`{"event":"note","path":"await: turn ended but ${AWAITFILE} is absent - holding for the next turn end"}`);
        await pauseAsync("2");
        continue;
      }
      if (awaitSeenAt) {
        const fin = epochOf();
        if (fin && test(fin, "-lt", awaitSeenAt)) {
          emit(`{"event":"note","path":"await: final message predates ${AWAITFILE} - holding for a turn end written after the fan-out"}`);
          await pauseAsync("2");
          continue;
        }
      }
      if (ARM === "oneshot") {
        // The rung's own exit status decides first; a rung that died, or
        // judged nothing, never falls through to the scrollback floor.
        const rc = readText(RCF) ?? "";
        if (rc !== "0") fail(`one-shot rung '${HARNESS}' produced no verdict: the one-shot rung exited ${rc || "with no recorded status"} (stderr: ${ERRF})`);
        if (!nonEmpty(OUTF)) fail(`one-shot rung '${HARNESS}' produced no verdict: the one-shot rung exited 0 but printed nothing (stderr: ${ERRF})`);
        if (!harvestFrom(OUTF, `${MARKDIR}/ac-pane-exec.${b}.${pid}.jsonl`, "command")) fail(`one-shot rung '${HARNESS}' produced no verdict: could not wrap the rung's stdout (${OUTF})`);
      } else if (ARM === "crewmate") {
        if (!nonEmpty(VERDICT)) fail(`verification agent '${HARNESS}' produced no verdict: the agent announced its turn but left no verdict at ${VERDICT}`);
        if (!harvestFrom(VERDICT, `${MARKDIR}/ac-pane-verdict.${b}.${pid}.jsonl`, "file")) fail(`verification agent '${HARNESS}' produced no verdict: could not wrap the verdict file (${VERDICT})`);
      } else {
        if (!TRANSCRIPT && !scrollback()) fail(`turn ended but no transcript could be harvested (no ${PROJ}/*.jsonl and the pane scrollback was empty)`);
        // A RESOLVED transcript is not a harvestable one: a session that
        // stopped after a completed tool call leaves a last message holding
        // only tool_use, which every caller would die on later.
        if (!finalSettles())
          done("error", `the turn-end signal arrived ${markerAge}s ago but the last assistant message carries no text - the turn stopped mid-pass and there is no final message to harvest, so it is NOT reported ok`);
      }
      emit(`{"event":"done","status":"ok","session_id":"${NEWSID}","transcript":"${TRANSCRIPT}","source":"${SOURCE}","pane":"${P}"}`);
      process.exit(0);
    }
    // A harness exiting without an announcement is a POSITIVE failure signal;
    // a verdict file left behind is named, the only trace of how far it got.
    if (ARM === "crewmate" && isFile(EXITMARK)) fail(`harness '${HARNESS}' exited (status ${crewRc()}) without announcing a verdict - ${nonEmpty(VERDICT) ? `it did leave one at ${VERDICT}` : "and wrote none"}`);
    if (i % 5 === 4 && ARM === "oneshot") {
      // A one-shot has no pane, so its liveness is the background process -
      // re-checked against the marker, which a finishing rung touches before
      // it exits.
      if (!rungAlive() && !isFile(MARKER)) {
        emit('{"event":"done","status":"error","session_id":"","transcript":"","pane":"","error":"the one-shot process died without ending its turn - no marker, no output to harvest"}');
        process.exit(1);
      }
    } else if (i % 5 === 4) {
      const live = PA_BACKEND === "orca" ? orcaConnected(P) : herdr(["pane", "get", P]).status === 0;
      if (!live) {
        emit(`{"event":"done","status":"pane_closed","session_id":"${NEWSID}","transcript":"${TRANSCRIPT}","pane":"${P}","error":"pane closed while turn in flight"}`);
        process.exit(1);
      }
    }
    if (TRANSCRIPT && i > 45) {
      const mt = fileMtime(TRANSCRIPT) ?? "0";
      if (test(minus(dateS(), mt) ?? "", "-gt", "120")) {
        const ag = agentStatus();
        if (
          (ag === "idle" || ag === "done") &&
          hasFinalTextFile(TRANSCRIPT, files) &&
          (!AWAITFILE || exists(AWAITFILE)) &&
          (!awaitSeenAt || test(epochOf() || "0", "-ge", awaitSeenAt))
        ) {
          // The three questions above ask nothing about whether the WORK was
          // produced: a declared deliverable that is absent or empty is a
          // turn that stopped mid-pass.
          if (DELIVERABLE && !nonEmpty(DELIVERABLE))
            done("error", `the pane went idle (agent_status=${ag}) without producing its deliverable ${DELIVERABLE} - the turn stopped mid-pass, so it is NOT reported ok`);
          if (!finalSettles())
            done("error", `the pane went idle (agent_status=${ag}) but its last assistant message carries no text - the turn stopped mid-pass and there is no final message to harvest, so it is NOT reported ok`);
          emit(`{"event":"note","path":"idle-fallback used (agent_status=${ag})"}`);
          emit(`{"event":"done","status":"ok","session_id":"${NEWSID}","transcript":"${TRANSCRIPT}","source":"${SOURCE}","pane":"${P}"}`);
          process.exit(0);
        }
      }
    }
    const stallMax = process.env.AC_PANE_STALL_MAX || "2700";
    if (TRANSCRIPT && test(stallMax, "-gt", "0")) {
      let mt = fileMtime(TRANSCRIPT) ?? "0";
      if (!test(mt, "-ge", waitStart)) mt = waitStart;
      if (test(minus(dateS(), mt) ?? "", "-gt", stallMax)) {
        const ag = agentStatus();
        done(
          "error",
          `no transcript progress for over ${stallMax}s (agent_status=${ag || "unreadable"}) - the turn is stalled inside a single call, escalating instead of burning the caller's timeout`,
        );
      }
    }
    await pauseAsync("2");
  }
  emit(`{"event":"done","status":"timeout","session_id":"${NEWSID}","transcript":"${TRANSCRIPT}","pane":"${P}","error":"turn did not end within ${TIMEOUT}s"}`);
  process.exit(1);
}

async function entry(args: string[]): Promise<never> {
  if (backendRoute("inherit") === null) process.exit(1);
  if (process.env.HOME === undefined) die("HOME is not set");
  process.env.PATH = `${process.env.PATH ?? ""}:/opt/homebrew/bin:${process.env.HOME}/.local/bin`;
  SES = process.env.AC_HERDR_SESSION || configReadSoft("herdr-session", "default");
  const [verb, ...rest] = args;
  if (verb === "close") close(rest);
  if (verb === "steer") steer(rest);
  if (verb === "reap-pane") reapPane(rest);
  if (verb === "reap") reap(rest);
  if (verb === "run") return run(rest);
  fail("usage: ac-pane-agent.sh run --cwd DIR --prompt-file F");
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  AT_CALLER = atCaller;
  try {
    if (args[0] !== undefined && Object.hasOwn(HELPERS, args[0])) await helper(args, atCaller);
    else await entry(args);
  } catch (e) {
    die(e instanceof Error ? e.message : String(e));
  }
}
