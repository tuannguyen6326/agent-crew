# Contributing to agent-crew

Thanks for your interest!
agent-crew is an agent distro - instructions, skills and bash tooling - so most contributions are edits to `bin/*.sh` scripts, `.agents/skills/` packages, `AGENTS.md`, `docs/`, or the Bun dashboard under `dashboard/`.
Read [`docs/concepts.md`](docs/concepts.md) first if you are new to the model.

## Ground rules

- **Never commit secrets or private data.**
  Client, company, internal project/service, personal identity, workstation and credential data stay out of this repository.
  Documentation and tests use neutral fixtures, and home paths are written as `~/`.
  Before pushing, run the scrub test and a secret sweep:

  ```bash
  bash tests/public-source-scrub.test.sh
  git grep -nIE 'sk-[a-z-]+[a-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}' || echo clean
  ```

- **The smallest diff that fully solves the task wins.**
  Change only what the task requires, update only what the change makes stale, and test only what the change puts at risk.
  No speculative abstractions, no unasked-for features or config knobs, no refactors riding along on a fix, no tests asserting the obvious.
  A larger change that looks warranted is a question to raise, not a silent expansion.

- **Comments explain WHY, never WHAT.**
  A comment states what the code cannot: the reason for a non-obvious choice, a real invariant, or why a workaround exists.
  Never narrate the next line, never decorate self-evident code, and never leave a note to the reviewer.
  An edit that invalidates a comment updates or deletes it in the same diff, and new comments match the file's existing density.

- **Test first.**
  Every behavior gets a colocated `tests/<name>.test.sh`.
  Write the failing test, watch it fail for the right reason, then make it pass.
  A change with no runtime surface (pure docs, comments) says so instead of skipping silently.

- **One authoritative file per contract.**
  Each script's header comment is its spec, each skill owns its procedure, and each doc section owns exactly one contract.
  Everything else points to the owner instead of restating it - a duplicated rule is a future contradiction.

- **Keep docs in sync.**
  A behavior change updates the owning header or skill, plus whatever it makes stale in `README.md`, `AGENTS.md`, `docs/` and `docs/overview.html`, in the same change.

- **Markdown shape.**
  Plain-dash lists.
  One sentence per line for a new document or section, and for a block already written that way.
  A block already hard-wrapped keeps its shape - edit it in the shape it is in.
  Never reflow a block as a side effect of an unrelated change, and never mix the two shapes inside one block.

## Know which file you are touching

| Surface | Owner | Notes |
| --- | --- | --- |
| Chief law (index) | `AGENTS.md` | The short muscle-memory index; `CLAUDE.md` symlinks to it. Keep it an index: detail belongs in a skill or a header. |
| Chief law (procedures) | `.agents/skills/<name>/SKILL.md` | `intake-triage`, `delivery-review`, `staged-gates`, `judgment-rules`, `task-lifecycle`, `solo-session`, `rooms-threads`, `deputies-domains` and the other chief skills hold the full text behind each `AGENTS.md` summary. |
| Script behavior | `bin/<script>.sh` header | The header comment IS the spec - change behavior, update the header. |
| Crew skills | `.agents/skills/<name>/` | Agent Skills spec packages; schema enforced by `tests/ac-skills-catalog.test.sh`. |
| Crewmate instructions | `docs/examples/CREWMATE.md` | The starter for a fleet's crewmate seed layer. |
| Backlog grammar | `docs/backlog.md` | `AC_DONELINE_AWK` in `bin/ac-lib.sh` is the one parser. |
| Config files and env knobs | `docs/configuration.md` | The environment table is the knob manifest, enforced by `tests/ac-config-surface.test.sh`. |
| Script index | `docs/scripts.md` | A map only; each row points to the owning header. |
| Web dashboard | `dashboard/app.ts`, `dashboard/lib.ts`, `dashboard/page.ts`, `dashboard/watch.ts` | Bun, no build step. `bin/dashboard.ts` is the launcher shim `bin/ac-dashboard.sh` execs. `app.ts`'s header owns the route and API contract; `lib.ts` is the pure layer. Tests: `dashboard/app.test.ts`, `dashboard/watch.test.ts`. |
| Tests | `tests/<name>.test.sh` | Colocated per behavior; `tests/run-suite.sh` is the only suite runner. |

## Dev loop

```bash
bash tests/<name>.test.sh          # one test file
tests/run-suite.sh --changed       # only the tests mapped from your changed files
tests/run-suite.sh                 # full bash suite (pass/fail count, every failing name)
tests/run-suite.sh --jobs 4        # opt-in parallel run; sequential by default
bash tests/dashboard.test.sh       # dashboard Bun tests (skips cleanly without bun)
bin/ac-lint.sh                     # opt-in: bash -n + shellcheck over changed files
```

- `tests/run-suite.sh` exits 0 when all pass, 1 when any test fails, 2 when it cannot proceed (bad arguments, no test files, or an empty `--changed` selection), and 3 when it refuses to run because SIGINT is ignored in an async invocation it cannot reset.
- `--changed` maps `bin/<name>.sh` to `tests/<name>.test.sh` over staged, unstaged and untracked changes; a changed shared library narrows to its sourcers' tests, and anything it cannot map confidently widens to the full set and says why.
- `--changed` ignores files outside `bin/*.sh` and `tests/*.sh`, so a change to `dashboard/*.ts`, `bin/*.ts`, docs or skills selects nothing on its own; run the relevant test file directly.
- On a clean, fully committed tree `--changed` has nothing to read and exits 2 without running anything.
- The suite is not a per-change gate: per-change verification is the changed-file tests plus any do-not-break tests; the bare full run is a periodic task.
- `bin/ac-lint.sh` is opt-in; `--all` lints the whole set, and `AC_LINT_ALLOW_MISSING=1` tolerates a missing shellcheck.
  It assumes shellcheck 0.11 or newer.
- For dashboard page changes, also run `bin/ac-page-lint.sh`, which lints every served page's inline scripts.

The script headers of `tests/run-suite.sh` and `bin/ac-lint.sh` are the authoritative specs for these flags.

## Adding a script

- Put it in `bin/` as `ac-<name>.sh` and write its header comment first: purpose, usage, exit codes, and the contract other files will point to.
- Add `tests/ac-<name>.test.sh`, which `--changed` maps to it automatically.
- Start the test by sourcing the helpers with the repo's fail-closed line, so a stray run can never touch a real fleet home:

  ```bash
  . "$(dirname "$0")/helpers.sh" \
    || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }
  ```

- `tests/helpers.sh` gives every test a throwaway `AC_HOME`, disposable repos, and asserts such as `assert_eq`, `assert_contains` and `assert_fails`; end a passing file with `pass`.
- Any new `AC_*` variable the script reads needs a row in the `docs/configuration.md` environment table, or a declaration with a reason inside `tests/ac-config-surface.test.sh` if it is an internal wire or test seam.
- Add a row to `docs/scripts.md` that points to the header.

## Adding a skill

- Create `.agents/skills/<name>/SKILL.md` following the [Agent Skills specification](https://agentskills.io/specification); `tests/ac-skills-catalog.test.sh` enforces it on every tracked package.
- The directory name equals the frontmatter `name` (portable lowercase, at most 64 characters), and `description` is non-empty, trigger-rich and at most 1024 characters.
- The frontmatter carries only standard keys - never `user-invocable` - and any `metadata:` values are strings.
- Keep `SKILL.md` under 500 lines; move executables to `scripts/`, docs the agent reads to `references/`, and runtime artifacts to `assets/`.
- Only the skills named in `AC_CREW_SKILLS` (`bin/ac-lib.sh`) are seeded into crew worktrees, alongside the fleet's learned skills; every other skill is chief-only.
  Add a crew-facing skill to that list.
- A chief skill that carries law also gets a row in the `AGENTS.md` section-12 table naming when to load it.

## Touching docs

- Some tests pin exact phrases in `AGENTS.md`, skills and `docs/`.
  Before rewording, search for the phrase: `git grep -n -F '<phrase>' tests/`.
- `tests/public-source-scrub.test.sh` fails on private identifiers anywhere in tracked text; keep examples neutral.
- The `docs/configuration.md` environment table is machine-read: each row starts with `` | `AC_NAME` | ``, and a family of dynamic names is documented as one templated row such as `` `AC_X_<...>` ``.
  Every plain row must have a reader in `bin/`, and every `AC_*` name read in `bin/` must have a row or a declaration.
- Link to the owning header or skill instead of copying tables or procedures.

## Commits and pushes

- Never add an agent co-author line to a commit.
  In project repos, the `commit-msg` guard that `bin/ac-tree.sh` installs on first lease refuses one; a human co-author is fine.
- Every push out of this repo goes through the pre-push privacy gate, `bin/ac-push-gate.sh`.
  Run it as a pre-push hook (`bin/ac-push-gate.sh hook`) or manually (`bin/ac-push-gate.sh check <range>`).
- The gate reads its patterns from a file outside the repo (`AC_PUSH_GATE_PATTERNS`, default `~/.config/agent-crew/push-gate.patterns`), because the patterns are themselves the private identifiers.
  With no pattern file it passes with a note, unless `AC_PUSH_GATE_REQUIRE=1`.
- A scan is a floor, never proof of absence: read your outgoing diff too.

## Pull requests

- Branch from `main`; keep one logical change per PR.
- Say what the change does and which contract owner (script header, skill or doc section) it updates.
- Run the relevant tests, the scrub test and the secret sweep before pushing.
