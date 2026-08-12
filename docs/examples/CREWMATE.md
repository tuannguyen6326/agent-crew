<!--
Fleet-wide crewmate instructions. ac-spawn.sh copies this file into every
crew worktree, at the path the spawned harness actually loads - AGENTS.md for
codex, <worktree>/.claude/CLAUDE.md for everything else - where the harness
loads it alongside the repository's own instructions (it never overrides them).
Keep it short and general - repo-specific rules belong in the repo.
-->

# Crewmate instructions

## TDD is required for all implementation

When implementing or changing product code (features AND bug fixes), follow
strict test-driven development. Do NOT write implementation before its test.

1. **Red** - write a test that captures the expected behavior (for a bug: a
   test that reproduces it) and run it; confirm it FAILS for the right reason.
2. **Green** - write the minimal code to make that test pass; run and confirm.
3. **Refactor** - clean up with the test staying green.

Use the project's own test framework and conventions (read a neighboring
test first). If the change genuinely has no runtime surface to test, say so
explicitly instead of skipping silently. The validation pipeline's test step
is a gate, not a substitute for writing tests as you go.

## Do not over-engineer

Change only what the brief requires, update only what your change makes
stale, test only what your change puts at risk. The smallest diff that fully
solves the task wins - a bigger one is a defect, not diligence. No
speculative abstractions, no unasked-for features, no config knobs nobody
requested, no refactors riding along on a fix, no tests asserting the
obvious or re-testing untouched code. If a larger change looks warranted,
that is a `needs-decision:` for the captain, not a silent expansion.

## A 0-fix review verdict FREEZES the tree

A review round that returns ZERO `fix` findings is a PASS, and the run is
landable at that exact commit. Its advisory (`no-op`) findings are the
reviewer's notes for the PR body and the backlog - never a licence to commit.
Proceed straight to the remaining delivery steps and land.

Polishing an advisory after a pass costs a whole fresh review round: the
receipt binds the reviewed ref by bare SHA equality, so ANY commit after the
pass - documentation included - kills it. Four such rounds ran in one hour on
one live family, every verdict a PASS, every round pure waste. Fixing an
advisory worth fixing is a follow-up task your chief mints, not a follow-on
commit - and the runner refuses to re-open the round on your own post-pass
work. A genuine rebase still re-opens it.

## Every finding names its authority

This binds the moment a finding is WRITTEN, not when a fix is decided - a
review round can only judge what the words already claim.

**Every defect statement names the authority for its EXPECTED behavior, and
you have read it.**

- **(a)** If the expected behavior describes what an actor OUTSIDE this repository
  does - a partner, a broker, a database, a client library's runtime, the
  network, `herdr`, `git`, the `claude` CLI - the finding cites a document, an
  in-repo spec, or a prior captain ruling, or it is filed `needs-decision:` /
  `ask-user`, never as a defect. A stale cited doc is a doc bug, never a licence
  to ignore it, and a citation that CONTRADICTS the finding is that finding's
  refutation - re-read before you file.
- **(b)** A reproduction holds everything constant except the disputed variable.
  Declare that: an executable repro carries
  `# DISPUTED: <the one variable under dispute>` and
  `# HELD-CONSTANT: <everything the two legs share, named>`.

On the findings wire this is two flat keys per finding:

- `authority_class`: `internal` (the expected behavior is stated inside this
  repository or by the diff itself) | `external` (an actor outside it) |
  `none` (the fail-closed default, never a valid authoring choice).
- `authority`: one sentence naming WHO states the expected behavior and
  WHERE - a `file:line`, a URL, or `captain <date>`. A bare document NAME is
  not a citation.

An `action: fix` finding with no authority is DOWNGRADED to `ask-user` by the
pipeline's shared normalizer and marked `authority_downgraded` - so it reaches
the captain instead of a fixer. Naming the authority costs one sentence; not
naming it costs the run. A `severity: info` finding carrying `fix` is floored
to `no-op` (`severity_floored`) before that downgrade - info means no action
required. Reserve `fix` for findings that must block delivery; advisory
improvements ride as `no-op` with `suggested_fix`.

## Verify only what your change touches

For the edit cycle, verify scoped to your change - use your tools'
changed-only lint/test modes, not a whole-repo sweep. VERIFY GATE =
changed-file tests + do-not-break tests ONLY; NEVER run the project's
full test suite as your verify, at the edit cycle or at handoff - that
is never your per-change check. The full suite is not a landing gate,
and it runs only as its own periodic task immediately before each
Learning DISTILL run.
This is the same "test only what your change puts at risk" discipline
as the over-engineering rule above, applied to verification.

## Reap your background jobs - never orphan a busy loop

Every `&` you launch in a tool shell is YOURS to reap. The non-interactive
`zsh -c` shell that runs each tool call is not a login shell: `jobs -p`
returns EMPTY there, so a `kill $(jobs -p)` cleanup hits nothing and every
backgrounded job survives the call as an orphan (ppid=1). One afternoon of
that left 77 busy loops pinning ~760% CPU for ~48 minutes.

HARD RULE - reaping:
- Record each job's pid from `$!` the instant you background it.
- Reap those recorded pids in an EXIT trap (`trap 'kill $pids' EXIT`).
- `jobs -p` is FORBIDDEN as a cleanup mechanism - it is EMPTY in the tool
  shell, so the kill hits nothing.
- Kill only YOUR OWN recorded pids, never by pattern (`pkill`, `kill $(pgrep
  ...)`): a pattern also kills another agent's unrelated work.

HARD RULE - host-impact preflight (any load-generating run):
- Check the current load first and REFUSE to start when the host is already
  busy - leave core headroom for the box's real work.
- Hard-cap BOTH the hog COUNT and the total DURATION (a `timeout`/TTL each
  hog enforces on itself, so even a SIGKILL-orphaned run expires on its own -
  a trap cannot reap what SIGKILL removed).
- Run the load under `nice` so real work outruns the load you manufacture.

Do not re-derive any of this: `tests/helpers.sh` (the `load_hogs`/`reap_hogs`
harness) is the landed, sanctioned implementation - copy it, and read its
header for the measurements behind each layer.

## Use what the project provides

Before working, check the skills and plugins YOUR session provides
(project plugins first, then built-ins) and prefer a relevant existing
skill over improvising - for reviewing, running, verifying, researching,
whatever the stage needs. Never pre-assume which skills exist; discover
them at runtime. And never let a generic skill override your brief: the
brief is the contract, skills are tools.

## Repo knowledge

Your brief names the per-project repo-knowledge record - what earlier families
VERIFIED about this codebase. Read it before your first change, and re-verify
before you rely on any entry: a stale fact stated confidently is worse than no
fact, and re-checking one is a single command.

Run the `ac-know.sh` lines your brief names VERBATIM. They carry the `--home`
your pane cannot resolve, and a write without it lands in the wrong fleet's
record - knowledge silently lost, which is the one outcome the record exists to
prevent. Every write prints the path it used; read that line.

When your work verified something durable about the codebase, record it before
you hand back. An entry needs PROVENANCE (`--src-file <path>:<line>` or
`--src-cmd '<command>'`) and it gets its freshness marker stamped for you; an
entry without provenance is refused, and the refusal names what is missing.

## Lessons - end every report with them

End every task report with a `## Lessons` section: one line per durable
lesson, in YOUR OWN words, first-hand - what you would tell the next crewmate
before it repeats your path. No lessons => the section says `none`, so the
section is a contract, not a mood. A learned skill you found wrong or stale
during the task is a lesson line too, in the fixed shape
`skill-defect: <name> - <what is wrong, one line>` - report it, NEVER edit
the skill store yourself.

Write the section at every ending, not only the happy one: at `done:`, and
also when you pause on a re-route (`paused:`), report `failed:`, or go
`blocked:`. Capture belongs to the moment your session is about to die - a
lesson living only in a torn-down session is a lesson lost. Your chief folds
these lines verbatim into the fleet ledger at landing; the learning loop
reads them as first-hand evidence.

## Status discipline

Append every important event as ONE line to your status log (the brief names
the file): needs-decision, blocked, paused, resolved, done, failed. Emit
needs-decision only for choices that genuinely belong to the captain.

PUSH your completion, do not only print it. A printed line is the BACKUP
channel - a watcher finds it on its next poll, up to 15 seconds later. The
moment you print a `done:`, `blocked:`, `needs-decision:` or `failed:` line
(a roomchief: its hand-back), also RUN the push command your brief names
(`bin/ac-done.sh <id> '<the exact line you printed>'`) - it wakes your chief in
milliseconds. Both channels carry the same completion and it still wakes the
chief exactly once, so never drop the printed line either.

Keep marker verbs out of prose. Never write a bare AC_CAPTAIN_RE marker verb
immediately followed by a colon inside narrative text: drop the colon (e.g.
`a real needs-decision`), or backtick-wrap the token when you must show the
colon (e.g. `needs-decision:`, as the over-engineering rule above already
does). A bare marker-plus-colon at a line start - or a prose mention that
soft-wraps to visual column 0 - false-wakes the watcher, false-stamps the pane
BLOCKED, and trips the monitor.
