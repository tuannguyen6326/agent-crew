---
name: deputies-domains
description: Crewdeputies (persistent nested homes with their own clones and session) and crewdomains (knowledge + routed ledger slices inside this fleet): provisioning, the routing table, intake routing by scope, the marked order channel and return channel, recovery, the domain token cycle, domainchiefs, retire, and domain standing rules. Load before routing an order to a deputy or domain, provisioning either, assigning a domain token, or reconciling an ORPHAN-TOKEN.
---

# deputies-domains

Moved verbatim from `AGENTS.md`, which keeps the one-line summary and points here; "section N" below means that section of `AGENTS.md`.

## Crewdeputies and crewdomains

Crewdeputies are persistent domain supervisors: provision a home with
`bin/ac-home-seed.sh <name> --projects <p1,p2>` (config inherited, projects
cloned from yours, registered in `records/crewdeputies.md`), brief it, then
`bin/ac-spawn.sh <name> --crewdeputy`. It runs its own fleet under
`AC_HOME=$AC_HOME/crewdeputies/<name>`; teardown refuses while that fleet has
crew in flight.

`records/crewdeputies.md` is the fleet's ROUTING TABLE, not a note: one line per
deputy carrying its charter one-liner, absolute `home:`, free-text `scope:`, and
clone list (grammar owner: the `crewdeputy routing table` block in
`bin/ac-lib.sh`; `bin/ac-deputy.sh validate` is the strict check). The
session-start digest prints it IN FULL - `bin/ac-deputy.sh list`, contract in
that script's header - with one liveness state per entry
(`LIVE`/`DOWN`/`UNOBSERVABLE`/`NOT-RUNNING`/`HOME-MISSING`) and the exact
recover command on the recoverable ones, so routing knowledge and live
ownership are deterministic
after any restart, from disk alone. ABSENT and EMPTY are distinct states and
both mean the same thing: no crewdeputies, so all work stays with the parent
fleet - never a prompt to seed one.

INTAKE routing is part of your ordinary triage, in this order: (1) resolve the
PROJECT by section 4; (2) read each routable entry's `scope:` and compare it to
the NATURE of the order - scope is authoritative, a project's presence in a
`projects:` list never routes work by itself and its absence never blocks
routing (it surfaces as a `needs-decision:`: clone into the deputy, or keep the
order here); (3) route. Exactly one scope fits -> route it and say so; none fits
-> the order stays with the parent fleet; two or more fit -> AMBIGUOUS, which is
a captain select (section 8) with your lean first, never a "best guess" - a
misrouted order runs in the wrong home against the wrong clone. An entry with no
`scope:` (legacy or freshly seeded) or an INVALID one is never routable, and you
may not invent scope text for it. A captain redirect wins in both directions at
any time, except that a redirect naming an INVALID or HOME-MISSING deputy is
refused with its digest state - fail-closed outranks the redirect when the
target physically cannot receive work. `local-only` work follows the scope like
every other mode: a deputy's clone is where its own local landings belong, and
a landing the PARENT's clone must carry is routed by keeping the work with the
parent at intake - a judgment call, not a mode rule.

A routed order goes out on the MARKED channel: `bin/ac-send.sh <deputy-id>
'<order>'` prefixes it with the chief-order marker for `kind=crewdeputy` targets
only (contract: the `bin/ac-send.sh` header), refuses rather than delivering an
unmarked or misaddressed one, and records `routed:` on `state/<id>.status` - the
parent's durable index, since routed work opens NO parent backlog row (the
deputy records it in its own ledger). The deputy answers on the RETURN CHANNEL,
`bin/ac-deputy.sh report` - a parent status line plus one durable wake your
ordinary drain emits - never only in its chat; a pane line is a trigger, never
the payload. A crewdeputy is IDLE BY DEFAULT: it acts only on work routed to it
or already in its home, then waits, and never invents work; it is a scoped
crewchief, so it still does no project work itself. Recovery is explicit and
guarded (`bin/ac-spawn.sh <id> --crewdeputy --recover`), and already-queued
in-scope items follow the domain with `bin/ac-deputy.sh handoff <deputy-id>
<backlog-id>...` (queued items only, all-or-nothing, backed up first).

A CREWDOMAIN is the OTHER shape of the same idea and COEXISTS with the
crewdeputy above - it replaces nothing. A crewdeputy is a nested HOME with a
standing session and its OWN clones; a crewdomain is durable STATE inside THIS
fleet: a package plus one routing line, with no home, no session, no liveness
and no lifecycle. Pick by what the work needs - ISOLATION (separate clones,
credentials, budget, delegable to another operator) is a crewdeputy or a full
fleet; a KNOWLEDGE slice + a routed slice of the fleet ledger over the
fleet's own clones is a crewdomain. The two share no registry, no root, no
script and no verb, so nothing is ever ambiguous about which feature a line
belongs to.
Create one with `bin/ac-domain.sh new <name> --scope '<t>' --charter '<t>'
(--projects <csv> | --no-projects)`: it validates EIGHT namespaces before any
write - including a crewdeputy id and an existing deputy home, the only place
the two features touch - then builds the THREE-member package at
`$AC_HOME/crewdomains/<name>/` (section 2) and appends its line to
`records/crewdomains.md` (`- <id> - <charter> - scope: <text> (added <iso>)`;
`scope:` is the routing key you READ, never a script's).
The cycle (crewdomain-token): mint the row in `records/backlog.md` as
ordinary intake -> `bin/ac-domain.sh assign <name> <id>` STAMPS it with the
`domain:<name>` token in place - nothing moves, so an epic row is assignable
and every scheduler keeps reading it -> post the ORDER into
`data/<family>/room.md` -> `bin/ac-spawn.sh --roomchief <family>` promotes a
DOMAINCHIEF, whose binding is DERIVED from that token (no new flag; `kind`
stays `roomchief`, the domain rides as `domain=<name>` in the meta and
`AC_DOMAIN` on the launch line; a story row with no token of its own inherits
its epic row's - one family, one domain) -> it works the family, reading its
slice with `bin/ac-domain.sh queue <name>` and NEVER editing any ledger (the
crewchief moves the fleet row at promote and at handback, the ordinary
roomchief contract) -> at landing it hands back on the ordinary roomchief
channel and you demote it; the Done row KEEPS its token as durable per-domain
provenance. The domain persists; the session does not. A domain family is an
ordinary promote, so it consumes the FLEET's `config/room-parallel` (a deputy
home keeps its own budget - two regimes, one per feature, each coherent on
its own clone set). Retire with `bin/ac-domain.sh retire <name>` - fail-closed
(refuses while any OPEN tokened row or flying domainchief exists), removes
exactly the registry line, and never deletes the package.
`bin/ac-domain.sh list` rides the session-start digest and always exits 0; it
reports any ORPHAN-TOKEN - a row naming a domain with no VALID registry line -
which you reconcile by `unassign`-ing the token or re-`new`-ing the domain.

## Domain standing rules

A CREWDOMAIN's standing rules live in the FLEET `records/captain.md` under
the convention `STANDING (domain:<name>): ...` - never in the package. They
chiefly govern TRIAGE (flow, qa, mode), which happens at YOUR intake BEFORE
`assign`, so a file inside the package would be read by the domainchief only
afterwards, too late to change the decision it exists for; the fleet file also
puts them under `bin/ac-curate.sh`'s existing coverage for free. A scoped
session may not edit that file (`bin/ac-ledger-guard.sh` fences it) - it reads
those lines as its law.
