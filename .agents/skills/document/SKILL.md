---
name: document
description: Judge whether a delivered change warrants documentation, author the missing docs in the project's own conventions (BMAD shapes into /docs when the project has none), and sync every existing doc the change makes stale. Use when delivering a change that may need docs - direct-flow delivery, the PR step of direct-pr mode, or crew-ship's document step - or when the user invokes /document.
---

# document

The doc-authoring METHOD for a delivered change, in fixed order: JUDGE -> CREATE -> SYNC.
Three call sites, one skill: direct-flow task delivery, the PR step of `direct-pr` mode, and the crew-ship pipeline's document step.
Inside the pipeline this skill AUGMENTS the document step's sync-only behavior with new-doc authoring; the `bin/ac-ship.sh` header stays authoritative for pipeline mechanics (hold-and-fix, findings, gating, `document.instructions`) - this skill owns only HOW docs are judged, written, and synced.

## 1. Judge first - does THIS change need documentation at all?

Documentation is skippable, and skipping is a first-class outcome - but the reason must be stated in the done line, never implied by silence.
Judge by the change's reader-facing surface, not its diff size:

- SKIP when the change leaves nothing for a reader to look up.
  Examples: a pure refactor (behavior unchanged), a test-only change, a revert, comment or typo fixes, dependency bumps with no user-visible effect.
- CREATE when the change adds surface a reader must discover: new user-facing behavior, a new command/endpoint/API, a new config key or env var, a changed default, a migration, a new subsystem.
- SYNC-only when the change alters surface that existing docs already describe and adds nothing new.

The fleet's HARD RULE against over-engineering binds here in full: no unasked-for doc suites, no speculative pages for things the change did not touch.

## 2. Discover the project's own conventions - before writing anything

Never impose a format on a project that already has one.
Read, in this order, and mirror what you find:

- Layout: where existing docs live (`docs/`, `documentation/`, wiki-style folders, or README-only) - new pages go where their siblings live.
- Style: heading depth, list style (plain-dash vs numbered), tone, code-fence conventions, frontmatter; write one sentence per line if the repo does it.
- Index files: any file that enumerates pages (`docs/README.md`, `mkdocs.yml`, `SUMMARY.md`, sidebar/TOC files) - a new page absent from its index is unfinished; update the index in the same pass.
- Naming: match sibling filenames (case, separators, suffixes).

## 3. No existing format? BMAD defaults (captain-pinned)

These defaults apply ONLY when the project has no docs format of its own:

- Location: `/docs` at the repo root when no docs folder structure exists.
- Format: BMAD (template source: https://github.com/bmad-code-org/BMAD-METHOD).
  Fetch the upstream templates only when you need more than the shapes below; the shapes below are the offline contract and suffice for normal use.
- BMAD shapes are a starting structure, not a script: keep only the sections the change earns, drop the rest, never emit empty headers.

Core BMAD doc shapes:

- Project brief (`docs/brief.md`) - the executive framing:
  Executive Summary (2-3 paragraphs that stand alone); The Problem; The Solution; What Makes This Different; Who This Serves; Success Criteria (measurable); Scope (explicit in AND out); Vision.
- PRD (`docs/prd.md`) - requirements with stable ids:
  Document Purpose; Vision; Target User (jobs-to-be-done plus key user journeys numbered `UJ-n`); Glossary (every domain noun defined once, used verbatim everywhere after); Features as subsections with globally numbered functional requirements `FR-n` (each: actor + capability + conditions, testable consequences, explicit out-of-scope); non-functional requirements `NFR-n`; inline `[ASSUMPTION: ...]` tags wherever you inferred without confirmation.
- Architecture doc (`docs/architecture.md`) - decisions, not narration:
  Design Paradigm (a named pattern mapped to real directories); Architecture Decisions `AD-n` (each: what it binds, what divergence it prevents, the rule downstream must follow); Consistency Conventions (naming, data formats, error shapes, cross-cutting state); Stack table (name + pinned version); Structural Seed (minimal source tree and the diagrams that convey shape).

## 4. Inputs - what the docs must carry

Docs describe intent and behavior; the diff alone is the floor, never the content.

- STAGED-flow tasks: the family stage reports are FIRST-CLASS inputs - read `data/<family>/spec/report.md` (intent, requirements, acceptance criteria), `data/<family>/arch/report.md` (design rationale, alternatives considered), and `data/<family>/plan/report.md` when they exist, so the docs carry intent + requirements + design rationale, not just a description of the diff.
- Direct tasks: the task brief (`data/<id>/brief.md`) is the intent source.
- The diff itself defines the change surface the SYNC pass sweeps (section 5).

## 5. Sync pass - every existing document the change affects

Always runs, even when the judge said no NEW docs are warranted:

- Grep the change surface against every existing doc: every name the diff touches (commands, flags, config keys, env vars, paths, endpoints, defaults) swept across README, the docs tree, and config samples.
- Update stale lines only - the repo's HARD RULE, verbatim: "update only what the change makes stale".
  No restyling, no rewrites-while-here, no reorganizing passages the change did not invalidate.
- Index/TOC files count as docs: a page you added, renamed, or removed must be reflected in every index that lists it.

## 6. Done line

Every call site reports the same contract:

`done: docs <created|synced|skipped: reason>`

- `created` - at least one new doc was authored (the sync pass ran too).
- `synced` - only existing docs were updated.
- `skipped: <reason>` - the judge found nothing to document; the reason is the receipt.

Inside the crew-ship pipeline this outcome feeds the document step's findings and commit (`agent-crew(document): ...`); the step's gating rules stay with the `bin/ac-ship.sh` contract.
