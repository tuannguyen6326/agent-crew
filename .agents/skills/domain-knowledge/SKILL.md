---
name: domain-knowledge
description: Onboard or update a CREWDOMAIN's whole knowledge surface in one idempotent flow - resolve or create the domain, then edit one surface (a project's detail heading, adding/removing a project from scope across its symlinks and heading together, the domain CREWMATE.md, or a STANDING line in the fleet records/captain.md), always closing on `bin/ac-domain.sh validate`. The captain invokes this as `/domain-knowledge <name> [project]`; it runs in the crewchief's own unscoped session, never handed to a roomchief. Load when the captain says onboard a domain, update domain knowledge, add or remove a project from a domain's scope, edit a domain's project detail, or edit a domain's standing rules.
---

# domain-knowledge

Owns the whole knowledge lifecycle of a CREWDOMAIN - onboarding and every later
update - as ONE idempotent flow. There is no onboard mode and no update mode:
onboarding IS this same flow running once on a domain that does not exist yet,
and every later invocation is the identical flow running again. Never split
this into two procedures, two sections, or an `if first-run` branch that forks
the steps - that is exactly the fork-risk shape the crewdomain design exists to
kill.

This skill is INSTRUCTIONS, not an engine. It calls `bin/ac-domain.sh`; it
never re-implements that script's logic, and it ships no `scripts/`. Do NOT
modify `bin/ac-domain.sh` to close a gap this skill hits - see Boundary below.

## When to load

The captain invokes this as `/domain-knowledge <name> [project]`. It runs in
the crewchief's own session - unscoped, never a roomchief's - because
`domain_chief_only` in `bin/ac-domain.sh` refuses every mutating verb when
`AC_SCOPE` is set, and `bin/ac-ledger-guard.sh` fences the fleet
`records/captain.md` in a scoped session. Neither guard fires here on purpose.

## The flow (run every time, in order)

### 1. Resolve the domain

`bin/ac-domain.sh list` is read-only and always exits 0 - run it first.

- Domain already registered (a `VALID` line for `<name>`): continue to step 2.
- Domain not registered: confirm the new domain with the captain (scope,
  charter, initial project set or `--no-projects`), then run
  `bin/ac-domain.sh new <name> --scope '<text>' --charter '<text>'
  (--projects <csv> | --no-projects)` and CONTINUE INTO THE SAME FLOW at step
  2. This is one branch that rejoins - never a second procedure.
- Idempotence here: never blindly re-run `new` on a name `list` already shows
  as `VALID`. `new` checks eight namespaces before any write and refuses on
  collision, so a blind re-run is a hard failure, not a no-op.

### 2. Apply the captain's chosen surface

The `[project]` argument jumps straight to surface (a). Otherwise ask which
surface the captain wants to touch:

**(a) DETAIL of one project** in the domain's own `records/projects.md`.
Read the current `## <project>` section, show it, and apply a SURGICAL edit -
add or amend the specific fact, constraint, or entry point the captain gave.
Never regenerate the section, never truncate it, never overwrite it blind:
that prose is the captain's/chief's own writing.

**(b) ADD or REMOVE a project from scope** - ONE action across BOTH surfaces
at once, never one without the other:

- ADD: create the clone symlink, the `.yaml` sibling symlink (when the fleet
  has one), and the `## <project>` heading, together.
- REMOVE: delete both symlinks and the heading section, together.

There is no verb in `bin/ac-domain.sh` for this - `cmd_new` is the only writer
of `projects/`, and there is no verb that adds or removes a project from an
EXISTING domain's view. That gap is exactly why this skill prescribes the
symlink work by hand and then gates it on `validate` (step 3) - see Boundary.

Symlink shape, copied from `cmd_new`, relative and at this exact depth
(written from inside `<pkg>/projects/`, where `../../../` is the fleet home):

    ln -s ../../../projects/<p>       <pkg>/projects/<p>
    ln -s ../../../projects/<p>.yaml  <pkg>/projects/<p>.yaml

A project with no `<p>.yaml` in the fleet gets the clone link alone - a
supported direct-pr case; `validate` reports it as `WARN` and never refuses.

Membership is link RESOLUTION, not link text (`ac_domain_view_entry` in
`bin/ac-lib.sh`, the one predicate shared by `validate` and `ac-spawn.sh`'s
pre-lease guard): an entry is `ok` only when it is a symlink, resolves (the
whole chain, <=16 hops) INSIDE `$AC_HOME/projects`, and resolves to ITS OWN
clone. Anything else - `not-symlink` / `dangling` / `outside` / `mismatch` -
REFUSES at `validate`. An absolute link is equally valid; the relative form
above just keeps the package relocatable with the home.

Idempotence here: re-adding an already-linked project changes nothing and
errors nothing - check the symlink and the heading exist before writing
either.

**(c) instructions in the domain's `CREWMATE.md`.** Append or amend a
section for what the captain asked; never truncate the file.

**(d) `STANDING (domain:<name>): ...` lines in the FLEET `records/captain.md`**
- never inside the package: domain standing rules drive TRIAGE at chief
intake, BEFORE `assign`, and a file inside the package would be read only
afterwards, too late to govern the decision it exists for. Amend an existing
`STANDING (domain:<name>): ` line in place; append a new one. Never write a
duplicate line.

### 3. Close every run on `validate`

Run `bin/ac-domain.sh validate` and report its output. It must exit 0 AND
print no `WARN <name>:` line for this domain - if it does, that is unfinished
work from step 2, go back and fix it before reporting done. `validate` never
repairs a divergence between the two surfaces in (b); this skill is what
keeps them in sync, and `validate` is how it proves it did.

## What `validate` warns on - leave this domain clean

- a `projects/<p>` symlink with no `## <p>` heading in `records/projects.md`;
- a `## <p>` heading with no `projects/<p>` symlink;
- the domain `records/projects.md` repeating the FLEET description of a
  project verbatim - the fleet description resolves from the FLEET
  `records/projects.md` alone;
- a delivery-mode token (`[crew-ship]` / `[direct-pr]` / `[local-only]` /
  `[mode]`) inside the domain `records/projects.md` - mode resolves from the
  FLEET `records/projects.md` alone; verified code facts belong in
  `records/repo-knowledge/<project>.md`, never here.

## Boundary

Do not modify `bin/ac-domain.sh` to add a verb that would close the
add/remove-project gap in step 2(b). If an acceptance check genuinely cannot
be satisfied without touching that script, that is a `needs-decision:` for
the chief - never a silent scope expansion. (`bin/ac-domain.sh` was just
repaired five times over one class of bug in the family that built this
feature - reopening it here is exactly the risk this boundary avoids.)

There is deliberately no `captain.md` inside a crewdomain package - see (d)
above - and this skill never creates one.
