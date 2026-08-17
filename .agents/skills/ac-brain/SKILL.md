---
name: ac-brain
description: Query and maintain the per-home memory engine - recall (hybrid search over the home's records with citations and trust labels), remember/forget working-memory facts with provenance, entity cards, context_pack for session rehydrate, delta for cheap wakes, links-to reverse lookups, sync, doctor, and the one expensive synthesize verb. Use when hunting fleet context the tier reads did not answer, before minting a family (create_safety), on wakes, after compaction, or to record a durable session fact. Additive tool - the section-5 knowledge law is unchanged.
---

# ac-brain

The per-home memory engine: an index over what this home has already written, plus a small working-memory facts store.
`bin/ac-brain-engine.ts`'s header is the authoritative spec; `bin/ac-brain.sh` is the CLI; every verb prints one JSON value.
POSTURE: this is an AVAILABLE TOOL - the section-5 intake law (tier-ranked `ac-know recall` reads, cites, heat) is unchanged and stays first; reach here when those reads return empty or the question spans history they do not cover.

## When to reach for it

- Intake, after the law's tier reads: `ac-brain.sh recall --query '<the order's question>'` - a hit is CITED into the brief under `## Inputs` (path + quote) exactly like a knowledge hit; state its absence otherwise.
- Before minting a family or backlog row: read `create_safety` on the recall response - `exists`/`probable` means fold into the prior family instead of opening a twin.
- On a wake: `ac-brain.sh delta --agent <your-id> --session <room-or-session>` returns only what changed since your last wake (at-least-once, never repeats a delivered item).
- After compaction or a fresh session: `ac-brain.sh context_pack --entities <family,...> --budget-tokens <n>`.
- A durable session fact worth keeping but below the ledger bar: `ac-brain.sh remember '<fact>' --provenance '<source>' --agent <pane-id> [--entity <slug>] [--kind commitment|belief|preference|event|fact] [--ttl 30d]`.
- Reverse lookup: `ac-brain.sh links-to <repo path or slug fragment>` - "which families touched this file".

## Boundaries that bind every caller

- SPLIT THE REPO FACTS OUT FIRST (the same order every crewmate already carries): a VERIFIED repo fact belongs in `records/repo-knowledge/` via `ac-know.sh add`, a method lesson in the report's `## Lessons` - `remember` is WORKING memory, never the landing place for either, and never a bypass of the learning pipeline.
- Trust the labels: results carry `trust: L1-verified ...` only for repo-knowledge pages; everything else is `unverified working material` - never cite a room quote as a verified fact.
- `synthesize` is the ONE verb that costs LLM tokens (routed env > crew-dispatch `panes.brain` > `config/brain-agent`/`brain-model`/`brain-effort` > fleet defaults); never put it on a hot or automatic path.
- Deputy brains are their own: `recall --deputy <id>` is READ-ONLY, resolved from `records/crewdeputies.md`, and used only on the captain's word - never ambient.
- `sync` runs as a standing job (declare it in `records/standing-jobs.md` per that file's grammar) and on demand; `sync --rebuild` is safe by construction (markdown and the `state/facts.md` ledger are the truth; the DB is derived).
- Everything except `synthesize` is zero-LLM; the embedding lane is optional and keyless mode stays fully functional. Provider keys are configured on the dashboard's Config -> LLM providers panel (stored per-home in `config/providers.json`, 0600; an env var on the host overrides) - never in the repo, never in brain.json.

## Health

`ac-brain.sh doctor` (exit 1 only on fail) and `ac-brain.sh stats`; `sync --break-lease` clears a dead holder only.
The usage log (`state/brain-usage.jsonl`) is home-local evidence for later demand-signal work - never uploaded, never trimmed by hand.
