# SDLC layout

Every path and file name the `sdlc` flow writes comes from this layout.
The skill, its templates and the chain order are the same for every fleet; only these values differ.

## Precedence

1. A repository that ships its own `sdlc` skill (`.claude/skills/sdlc/`) follows that skill's `references/layout.md`; nothing below applies to it.
2. Otherwise the fleet's `<fleet home>/sdlc.md`, when it exists, overrides the defaults key by key: a key it names wins, a key it omits keeps its default.
3. Otherwise the defaults below.

The brief of every `flow:sdlc` task names the fleet file when one exists.
The chief reads the same file at intake, before the SDLC clarify.

## Keys and defaults

Tokens: `<feature>`, `<change>`, `<live>` (the resolved `live` value), and in `change` only `<date>` (the intake date, `YYYY-MM-DD`), `<slug>` and `<record>`.

### Change id

| Key | Default | Meaning |
| --- | --- | --- |
| `change` | `<date>-<slug>` | The change id: the name of the snapshot directory and the `change:` line of every artifact. It is independent of the backlog family id. |
| `record` | `any, optional` | The external record `<record>` stands for: its form (e.g. `ABC-<n>`) and whether it is `required`. A required record that is missing is an open question of the SDLC clarify, never a guess. |
| `slug` | `kebab-case` | The rule a slug follows. |

### Repository paths

| Key | Default | Meaning |
| --- | --- | --- |
| `live` | `docs/features/<feature>` | The feature's live documents in the main repository. |
| `snapshot` | `<live>/changes/<change>` | The change's snapshot directory in the main repository. |
| `repo_plan` | `<live>/changes/<change>/plan.md` | The plan of a participating repository that is not the main repository, in that repository. |

### Artifacts, relative to `snapshot`

| Key | Default |
| --- | --- |
| `intent` | `intent.md` |
| `spec` | `spec.md` |
| `contracts` | `contracts/` |
| `plan` | `plan.md` |
| `test_plan` | `qa/test-plan.md` |
| `qa_report` | `qa/qa-report.md` |
| `release_notes` | `release-notes.md` |

### Live documents, relative to `live`

| Key | Default | Meaning |
| --- | --- | --- |
| `requirements` | `BRD.md, PRD.md` | Comma-separated globs; the document step updates every match. With no match yet, it creates the first pattern with `*` replaced by `<feature>`. |
| `tech` | `tech/` | The technical design. |
| `contracts_live` | `contracts/` | The live service contracts. |
| `regression` | `qa/regression.md` | The regression cases. |
| `incidents` | `incidents/` | Post-mortems. |

The set of artifacts and the order of the chain are fixed; a layout renames and moves them, never drops one.

## The fleet file

`<fleet home>/sdlc.md` holds a `## Layout` section of `- <key>: <value>` lines, only for the keys that differ, and an optional `## Gotchas` table of the fleet's own known failures.
A key that is not in the tables above is a `needs-decision:`, never ignored.
To start one, copy the lines you need from this file and change the values.

```markdown
# SDLC (fleet)

## Layout

- live: docs/product/<feature>
- snapshot: <live>/snapshots/<change>
- change: <record>-<slug>
- record: ABC-<n>, required
- slug: 2-5 lowercase words
- repo_plan: plans/<change>.md
- qa_report: qa/report-<change>.md
- requirements: req-*.md, design-*.md

## Gotchas

| Pattern | Why it fails | Fix |
| --- | --- | --- |
| <what goes wrong> | <why> | <what to do instead> |
```
