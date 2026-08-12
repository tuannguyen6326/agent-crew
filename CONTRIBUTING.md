# Contributing to agent-crew

Thanks for your interest!
agent-crew is an agent distro - instructions, skills, and bash tooling - so most contributions are edits to `bin/*.sh` scripts, `.agents/skills/` packages, `AGENTS.md`, or the Bun dashboard (`bin/dashboard.ts`).

## Ground rules

- **Never commit secrets or private data.**
  Client, company, internal project/service, personal identity, workstation, and credential data stay out of this repository.
  Documentation and tests use neutral fixtures.
  Before pushing, run the scrub test and a secret sweep:

  ```bash
  bash tests/public-source-scrub.test.sh
  git grep -nIE 'sk-[a-z-]+[a-z0-9]{20,}|ghp_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}' || echo clean
  ```

- **One authoritative file per contract.**
  Each script's header comment is its spec; each doc section owns exactly one contract.
  Everything else points to the owner instead of restating it - a duplicated rule is a future contradiction.

- **The smallest diff that fully solves the task wins.**
  This is the repo's standing rule (AGENTS.md section 1): no speculative abstractions, no unasked-for features, no refactors riding along on a fix, no tests asserting the obvious.

- **Keep docs in sync.**
  A behavior change updates the owning script header, plus whatever it makes stale in `README.md`, `AGENTS.md`, `docs/`, and `docs/overview.html` - in the same change.

- **Markdown conventions.**
  Plain-dash lists.
  One sentence per line for a new document or section; a block already hard-wrapped keeps its shape.
  Never reflow a block as a side effect of an unrelated change.

## Know which file you're touching

| Surface               | Owner                       | Notes                                                                                                                                                                                     |
| --------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crewchief behavior    | `AGENTS.md`                 | The operating manual; `CLAUDE.md` symlinks to it. Cross-reference, don't duplicate.                                                                                                       |
| Script behavior       | `bin/<script>.sh` header    | The header comment IS the spec - change behavior, update the header.                                                                                                                      |
| Skills                | `.agents/skills/<name>/`    | Agent Skills spec packages; schema enforced by `tests/ac-skills-catalog.test.sh`. Split big packages into `scripts/` / `references/` / `assets/`.                                         |
| Crewmate instructions | `docs/examples/CREWMATE.md` | The seed layer every crew worktree receives.                                                                                                                                              |
| Web dashboard         | `bin/dashboard.ts`          | Bun, zero build. Pure functions are exported and tested in `bin/dashboard.test.ts`; the header owns the route/API contract.                                                               |
| Tests                 | `tests/<name>.test.sh`      | Colocated per behavior; `tests/run-suite.sh` is the only runner.                                                                                                                          |

## Dev loop

```bash
tests/run-suite.sh                 # full bash suite (pass/fail count, no truncation)
tests/run-suite.sh --changed       # only the tests mapped from your changed files
bun test bin/dashboard.test.ts     # dashboard pure-function tests
bin/ac-lint.sh                     # opt-in: bash -n + shellcheck over changed files
```

Every behavior change lands with a colocated `tests/*.test.sh` (or an update to one).
For dashboard UI changes, also lint the served page's inline scripts: `curl` the page, extract the `<script>` blocks, and run `bun build --no-bundle` over them.

## Pull requests

- Branch from `main`; keep one logical change per PR.
- Say what the change does and which contract owner (script header / doc section) it updates.
- Run the suite and the secret sweep before pushing.
