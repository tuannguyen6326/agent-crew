---
name: harness-operations
description: Verified operational facts for the harnesses Agent Crew supports through bin/ac-spawn.sh - claude, codex, opencode, pi and cursor (both registered, partially verified), and an unverified captain custom launch command - over the herdr backend. Load before a harness-specific spawn, trust-dialog response, skill invocation, interrupt, exit, resume, recovery, or adapter verification. Read the target harness from the task meta; never guess from your own harness. An unknown or custom harness fails closed to natural-language steering, not borrowed keystrokes.
---

# harness-operations

The crewchief's verified operational facts for driving a crewmate's harness pane.
This skill owns ONLY the judgment and the short verified facts a crewchief needs; the mechanics live in their scripts and stay authoritative there.

## Scope

Covers only the harnesses Agent Crew currently supports through `bin/ac-spawn.sh`:

- `claude`;
- `codex`;
- `opencode`;
- `pi` (registered 2026-08-14, launch/effort/instruction facts verified from its own CLI; behavioural contract unproven - the references file owns the boundary);
- `cursor` (registered 2026-08-14; the agent CLI is `cursor-agent`, never bare `cursor`; instruction file LIVE-PROBED: AGENTS.md + root CLAUDE.md, never .claude/CLAUDE.md - the references file owns the boundary);
- a captain-provided custom launch command (`config/launch-<harness>`), which stays unverified unless separately validated.

The herdr session backend remains the only supported backend.

## When to load

Load before a harness-specific spawn, trust-dialog response, skill invocation, interrupt, exit, resume, recovery, or adapter verification.

## Source-of-truth split - do not restate the mechanics

- `bin/ac-spawn.sh` owns launch-command construction, model and effort flags, session metadata, kickoff delivery, and the supported harness names.
- `bin/ac-backend.sh` owns the herdr composer, submit-verification, focus, blocked-pane detection, and backend lifecycle.
- This skill owns only the verified crewchief-facing facts: busy vs idle evidence; trust and permission dialogs; safe interrupt behavior; exit behavior; resume support and limits; skill-invocation form; known popup or submit hazards; and the evidence required before claiming an operation landed.

## Two rules that apply to every harness

1. Read the target harness from the task meta (`harness=` in `state/<id>.meta`); never guess from your own harness - the crewchief and the crewmate may run different ones.
2. Unknown or custom harness behavior fails closed to natural-language steering or explicit validation, never borrowed keystrokes from another harness.

## Backend-general facts (herdr, every harness)

- Send a literal line with `bin/ac-send.sh <id> '<text>'`: it types, then submits VERIFIED (a render-change probe with one focused retry). A send whose submit is never acknowledged exits non-zero with the strand on stderr - that is NOT a landed operation.
- After a strand, resubmit with `bin/ac-send.sh <id> --key Enter`; never re-type the line (a re-type appends to the composer and garbles it). Confirm the resubmit landed by peeking - the key path is not probed (below), so its output is not evidence.
- A pane whose agent status is `blocked` sits on a real interactive dialog only a human can answer. `bin/ac-send.sh` REFUSES ordinary text into it (its trailing Enter would accept the highlighted option, up to a permanent grant). Peek first, then answer with `--key`, or pass `--force` deliberately.
- Read busy vs idle with `bin/ac-crew-state.sh <id>` (deterministic one-line state; `gone` once the window dies, `unobservable: ...` when the backend itself could not be read - never a death) and `bin/ac-peek.sh <id>` (bounded pane tail, each line prefixed `peek| ` so a crewmate's own captain marker cannot false-wake whichever pane is peeking).
- Interrupt with a named key through `bin/ac-send.sh <id> --key Escape` (soft) or `--key C-c` (hard); keys are the deliberate way to answer or interrupt, and never need `--force`. Every key is pressed on a FOCUSED tab but its delivery is UNVERIFIED - a bare key may legitimately redraw nothing, so no verdict is faked and `--key` reports `delivered (unverified)`. Treat the key as landed only once `bin/ac-peek.sh <id>` shows the effect.

## Per-harness facts - read the reference

The harness-specific facts (launch shape, resume support, effort, skill-invocation form, and their code provenance) live in `references/harness-facts.md`.
Read it before acting on a specific harness; it is kept out of the main file so it does not bloat every activation.

## Adding or trusting a new harness

- Every harness fact must be backed by current Agent Crew code, an existing regression test, or an empirical scratch validation recorded in task evidence. Facts for unsupported runtimes must not be imported.
- Adding a harness requires an isolated verification task that checks launch, busy detection, trust dialog, literal send, submit confirmation, interrupt, exit, resume, and skill invocation before the adapter is declared supported.
- Any new mechanic belongs in the owning script (`bin/ac-spawn.sh` or `bin/ac-backend.sh`) and its tests before the concise fact is added here.
