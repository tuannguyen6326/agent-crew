// domain.ts - the CREWDOMAIN verb layer: create a domain package and route
// work to it by TOKEN. The entry is bin/ac-domain.sh (a shim that starts this
// file through bin/ac-bun.sh); THIS header is the authoritative spec, and the
// bash original it replaced stays frozen at tests/fixtures/ac-domain.sh as the
// oracle the differential leg of tests/sh/ac-domain.test.sh holds this module
// to.
//
// Usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>'
//                         (--projects <p1,p2,...> | --no-projects)
//        ac-domain.sh assign <name> <backlog-id>... [--captain-requested '<words>']
//        ac-domain.sh unassign <name> <backlog-id>...
//        ac-domain.sh queue <name> [--ids]
//        ac-domain.sh qa-repo <name> [--set <project> [--force] | --clear]
//        ac-domain.sh retire <name>
//        ac-domain.sh list | validate
// Anything else (none, -h, LIST) is `ERROR: usage: ac-domain.sh
// <new|assign|unassign|queue|qa-repo|retire|list|validate>`, exit 1; extra
// arguments to list and validate are never read; stdin is never read. Every
// ERROR/WARN is on stderr, an ERROR exit 1 unless noted; list's and
// validate's findings are on stdout. Output is written line by line.
//
// A crewdomain is durable STATE inside this fleet - a KNOWLEDGE package plus
// one routing line - with no home, no session, no liveness and no ledger of
// its own (crewdomain-token refactor). Work
// reaches it when the crewchief STAMPS a fleet backlog row with the
// `domain:<name>` token (grammar owner: src/backlog.ts's domain field -
// position-pinned at the slot the retired assigned:crewchief defined); work
// happens when the crewchief promotes a DOMAINCHIEF, an ordinary roomchief
// whose domain binding is derived from that token. The row NEVER leaves
// records/backlog.md: ac-ready.sh keeps scheduling it, blocked-by edges stay
// resolvable, epic rollups keep counting it - which is why an epic row is
// assignable. The domainchief never edits any ledger - the crewchief moves
// rows at the ordinary checkpoints (promote -> In flight, handback -> Done).
// A Done row KEEPS its token as durable per-domain provenance (date-free, so
// the doneline date/verb stay inert). What stays detectable is the
// ORPHAN-TOKEN (an OPEN row's token naming no VALID registry entry - `list`
// prints it, promote refuses it) and the malformed token (domain_malformed, flagged by
// `validate`, fail-visible).
//
// COEXISTENCE with crewdeputy, which this module never touches: no registry,
// no root, no verb in common - crewdeputy keeps src/deputy.ts,
// records/crewdeputies.md and crewdeputies/<name>/. ISOLATION (separate
// clones, credentials, budget, another operator) is a crewdeputy or a full
// fleet; a KNOWLEDGE slice + a routed slice of the fleet ledger over the
// fleet's own clones is a crewdomain. The one place the two meet is the NAME,
// and `new` refuses a collision.
//
// THE REGISTRY GRAMMAR is ac-lib.sh's `crewdomain routing table` block, read
// through domainParse (src/lib.ts): ac_domain_parse's awk program, spawned
// byte for byte under the caller's locale - one TSV record per `- ` line,
// `<class>\t<id>\t<charter>\t<scope>\t<reason>`, VALID or INVALID (<id> the
// verbatim line, <reason> the first failed check). Under a UTF-8 locale one
// byte that is not UTF-8 aborts that awk (`towc: multibyte conversion
// failure`, exit 2) - every reader below inherits that (W2, W4). The TOKEN
// grammar is src/backlog.ts's. Every ledger reading below is that grammar
// in-process (records() + acDoneline(), the AC_DONELINE_AWK reading under
// LC_ALL=C).
//
// SHARED GATES. A NAME is legal by domainNameOk ([a-z0-9-]+, so `''`, `.`,
// `..` and any `/` are refused; a leading `-` is legal, W11), else `ERROR:
// not a legal crewdomain name: '<n>' (charset [a-z0-9-], no path separators)
// - refusing to derive a package path from it`. A backlog ID likewise
// (backlogIdOk), else `ERROR: not a legal backlog id: '<i>' (charset
// [a-z0-9-]) - refusing rather than matching it as a regular expression
// against the ledger`. new, assign, unassign and retire are the CREWCHIEF's:
// a non-empty AC_SCOPE is `ERROR: <verb> is the CREWCHIEF's verb and this
// session is scoped (AC_SCOPE=<s>) - only the crewchief creates domain rows,
// and the provenance token means nothing if a scoped session can stamp it`;
// qa-repo's --set and --clear are the crewchief's too, refused in their own
// words (below). A LIST of ids (assign, unassign) or projects (new) is deduplicated before
// any write: an empty item is `ERROR: empty <label> in the argument list -
// refusing before any write`, a repeat (`case " $seen " in *" $it "*`, so
// with spaces in it) `ERROR: duplicate <label> "<it>" - refusing before any
// write: a repeat would half-apply and leave state neither whole nor
// reversible`; the survivors are then split at blanks, tabs and LFs (W10:
// `qa 'qb qa'` passes as qa, qb, qa and double-stamps qa; a blank-only id
// leaves nothing - `nothing to do`).
//
// --- new: the package, whole or nothing (AUTHORITATIVE) ---
// THREE members at <home>/crewdomains/<name>/:
//   records/projects.md   the domain's DETAIL about its in-scope projects - what
//                         part of each belongs to the domain, partner context,
//                         constraints, entry points; never `[mode]` and never
//                         the fleet description (both resolve from the fleet
//                         records/projects.md alone); one `## <project>`
//                         heading per in-scope project, the only machine-read
//                         part, which validate compares with the
//                         view.
//   CREWMATE.md           the domain instruction layer, appended last onto the
//                         container+fleet baseline by the seed chain.
//   projects/             one RELATIVE symlink per in-scope project
//                         (../../../projects/<p>) plus its <p>.yaml when the
//                         fleet has one - the domain works the FLEET's clone
//                         through a second path, so nothing can drift.
// There is deliberately NO captain.md (domain standing rules are lines in the
// fleet records/captain.md prefixed `STANDING (domain:<name>): `, read at
// triage, before assign) and NO learnings.md (a domainchief notes to the
// fleet ledger with a `(domain:<name>)` prefix).
// In order: <name> is the FIRST argument, before any flag (`new --scope s`
// names the domain `--scope`); empty is `ERROR: usage: ac-domain.sh new
// <name> --scope '<text>' --charter '<text>' (--projects <p1,p2,...> |
// --no-projects)`. Flags, repeats last-wins: --scope/--charter/--projects
// <v> (the last word with no value: `ERROR: <flag> needs a value`),
// --no-projects, anything else `ERROR: unknown argument: <a>` - all before
// the scope gate. Then the chief gate; `ERROR: --charter '<one-liner>' is
// required and may not be empty: it is what the chief reads in the digest`;
// `ERROR: --scope '<text>' is required: it is the routing key, and an entry
// without one is registered but never routable. Pass --scope ''
// deliberately if that is what you mean.` (presence only); `ERROR:
// --projects and --no-projects are mutually exclusive - refusing rather than
// silently building the empty view you did not ask for` (presence: `--projects
// ''` too); `ERROR: pass --projects <p1,p2,...> or --no-projects explicitly -
// a silent empty project view is the wrong default`; a name outside
// [a-z0-9-] `ERROR: name must be [a-z0-9-]: <name>`. Then the home (homeless
// or unenterable: the refusal, exit 1) and records/ (minted). EIGHT
// namespaces, in this order, the first hit refusing:
//   a reserved stage suffix (-spec -arch -plan -review -ship -design -chief
//   -r<d> -r<dd>; x-r100 passes): `ERROR: name '<n>' collides with a
//   reserved stage suffix - a family id derives stage dirs from it`;
//   the LEADING TOKEN of any `- ` line of records/crewdomains.md, INVALID
//   lines included (a spawned awk under the caller's locale - a failure to
//   read is no collision, W4): `ERROR: name '<n>' is already registered in
//   records/crewdomains.md`; of records/crewdeputies.md: `ERROR: name '<n>'
//   is already a crewdeputy in records/crewdeputies.md - the two features
//   share no file, but they share the operator's vocabulary and the chief's
//   routing judgment; pick a different name`; anything at
//   crewdeputies/<n>: `ERROR: name '<n>' collides with an existing
//   crewdeputy home at crewdeputies/<n>`; at crewdomains/<n>, anything but a
//   KEPT package (CREWMATE.md, records/projects.md and a projects/ directory,
//   as retire leaves one): `ERROR: name '<n>' collides with an existing
//   directory at crewdomains/<n>` - a kept package is RE-ADOPTED
//   (below); at
//   data/<n>: `ERROR: name '<n>' collides with a task data dir at
//   data/<n>`; at state/<n>-chief.meta: `ERROR: name '<n>' collides with a
//   live chief session at state/<n>-chief.meta`; a row id in
//   records/backlog.md (`grep -qE "^- \[[ x]\] <n> "`, spawned - an
//   unreadable ledger is grep's line and no collision, W22): `ERROR: name
//   '<n>' is already a row id in records/backlog.md`.
// The routing line `- <n> - <charter> - scope: <scope> (added <iso>)` (a
// date that fails leaves `(added )`, still VALID - W21) must be one line -
// `ERROR: --charter/--scope must be single-line: a newline would split the
// routing line in two` (TAB and CR pass, W5) - and must parse VALID: it is
// written to a `mktemp ${TMPDIR:-/tmp}/ac-domain-line.XXXXXX` (mktemp's own
// failure ends new with its status) and parsed; no VALID record is `ERROR:
// the routing line these arguments would write does not parse VALID (<why>)
// - refusing before any write. Check --charter and --scope for a ' -
// <word>:' token, which this grammar reads as an unknown field.`, <why> a
// second parse's fifth field (a parse that fails there ends new with its
// status and leaves the temp, W4). Only the candidate is parsed, never the
// file it joins (W14: a registry with no final LF gets the line glued on).
// Projects (unless --no-projects): `ERROR: malformed --projects list "<v>":
// leading, trailing or repeated commas - refusing before any write rather
// than silently building a shorter view`; `ERROR: --projects takes project
// NAMES, not paths: "<v>"`; the commas become blanks and the list is split
// at blanks, tabs and LFs (W12: `alpha beta` is two), deduplicated; none
// left: `ERROR: --projects named no project - pass --no-projects if the
// empty view is what you meant`; each needs a DIRECTORY at
// projects/<p>/.git (a symlinked clone counts, a worktree's .git file does
// not): `ERROR: the fleet has no clone at projects/<p> - a domain view links
// the fleet's own clones, it never makes one`.
// WRITES, whole or nothing - any failure from here removes the package
// (`rm -rf`) and says `rolled back the partial package at <pkg> - nothing
// was created`, ending new with the failing step's status: `mkdir -p
// <pkg>/records <pkg>/projects`; records/projects.md (its two-paragraph
// preamble, then `\n## <p>\n` per project in argument order); CREWMATE.md;
// per project `ln -s ../../../projects/<p> <pkg>/projects/<p>` and, when
// projects/<p>.yaml exists, `ln -s ../../../projects/<p>.yaml
// <pkg>/projects/<p>.yaml` (ln from PATH - onto an existing symlink to a
// directory it links INSIDE it, so `alpha,ALPHA` on a case-insensitive
// filesystem leaves a link in the fleet clone, W13); LAST the routing line
// appended to records/crewdomains.md. stdout `created crewdomain <n> at
// crewdomains/<n> (<k> project link(s))` and, when a .yaml was missing, `no
// pipeline config in the fleet for: <p>.yaml[ <q>.yaml] - linked the clone
// alone (a project with no <name>.yaml is a supported direct-pr case)`. No
// backup, status line or wake; a rerun is refused by the registry.
// RE-ADOPTION of a kept package runs every check above and writes only what
// it lacks: no mkdir, no records/projects.md or CREWMATE.md (the kept
// knowledge is never touched), and for --projects a link (and its .yaml)
// only per project whose entry is not already in projects/ - nothing in the
// view is removed; LAST the routing line. A failure removes only the links
// this run made - `rolled back the re-adoption of the kept package at <pkg>
// - it is as it was, and nothing was registered`, the failing step's status.
// stdout `re-adopted crewdomain <n> at crewdomains/<n> (<k> project link(s)
// added; the kept package is otherwise unchanged)` and the .yaml line as
// new's, for the projects it linked.
//
// --- assign <name> <id>... [--captain-requested '<words>'] ---
// STAMP fleet rows with `domain:<name>` in place - nothing moves. The first
// word is the name; --captain-requested <words> anywhere after it (no words:
// `ERROR: --captain-requested needs the captain's words (the authority is
// the record)`; the last wins), every other word an id; no name or no id:
// `ERROR: usage: ac-domain.sh assign <name> <backlog-id>...
// [--captain-requested '<words>']`. Then the chief gate, the name, the ids.
// The domain must be VALID - the registry parse (its stderr passed through)
// read for the first VALID record named <name>, else, or when the parse
// failed, `ERROR: no VALID crewdomain '<n>' in records/crewdomains.md` - and
// have a scope: `ERROR: crewdomain '<n>' has an empty scope: - it is not
// routable, and the chief may not invent scope text for it`; its package is
// never checked (W3). No regular <records>/backlog.md: `ERROR: no fleet
// backlog at <path>`. Then THE LEDGER LOCK, held to the exit (ledgerLock,
// src/lib.ts - records/.backlog.md.lock as ac-task.sh takes it,
// AC_TASK_LOCK_TIMEOUT secs, default 10): a live holder past the wait is
// `ERROR: records/backlog.md is locked by another writer - nothing written`,
// a records/ the lock cannot be made in `ERROR: records/backlog.md cannot be
// locked - its directory is not writable - nothing written`; every check
// and rewrite below reads the ledger inside it. PASS 1, every id before any
// write, in argument order:
// the row is found by `LC_ALL=C awk -v id=<id>` (spawned; its failure - an
// unreadable ledger - ends assign with its status): the section after the
// last `## ` line ("" before any), and the ONE line matching `^- \[[ x]\]
// <id>( \[[^]]*\])* - `; not exactly one: `ERROR: no single row for '<id>'
// in <ledger>`. Its domain token (src/backlog.ts) is <name>: already
// assigned; another: `ERROR: '<id>' is already assigned to crewdomain
// '<cur>' - unassign it there first; a silent steal is how one row ends up
// claimed twice`; else its section must be exactly `Queued`, or `In flight`
// with the captain's words - without them `ERROR: '<id>' sits under '## In
// flight' - adopting live work into a domain is the captain's call: re-run
// with --captain-requested '<the captain's words>' (a stamp changes nothing
// in the flying crewmate's env, but the authority must be on record)` - and
// any other section (Done, `Queued (3)`, Parked, none) is `ERROR: '<id>'
// sits under '## <section>' - Done history keeps the provenance it was made
// with` (W24). An off-position token reads as none, and the row is stamped.
// stdout `already assigned to <n>: <id>[,<id>]` for the no-ops; none left:
// `nothing to do`, exit 0. Then recordsBackup("domain-assign") - its WARN
// and exit 1 with nothing written, else stdout `backup: <arc>`. PASS 2, per
// id: the row found again (gone: `ERROR: the row for '<id>' vanished
// mid-assign - the ledger changed under this command; re-run`), stamped by
// `awk -v n=<name> '{ if (sub(/ \(repo: [^()]*\)$/, "; domain:" n "&"))
// print; else print $0 "; domain:" n }'` (spawned, the line on stdin, the
// caller's locale - under UTF-8 a byte that is not UTF-8 ends assign with
// awk's 2, W7), and the FIRST ledger line equal to the found line, both as
// `awk -v` reads a value (backslash escapes interpreted, W6: a row holding a
// backslash matches only as its lone last byte, which the stamped line then
// loses), replaced by the stamped one (same reading) and the ledger written
// back as awk prints it (an unterminated last line gains its LF) through an
// exclusive temp and a spawned `mv`; no such line, or a temp or mv that
// fails: `ERROR: could not rewrite the row for '<id>' - the ledger changed
// under this command; re-run` - rows already rewritten stay rewritten (W7).
// stdout each stamped line. Then statusAppend(<name>, `assign:
// <ids>[ [captain-requested: <words>]]`) UNGUARDED (a failing date ends
// assign with its status, a failed append 1; the words raw, W25), ONE wake
// wakePublish(<state>, "", domain, <name>, `assign: <ids>`) - a record not
// published is `WARN: assign: the durable wake could not be published - the
// rows are STAMPED, but your drain will not announce it; check
// <state>/.wake-spool`, exit 0 - and `assigned <ids> to crewdomain <n>`.
// <ids> is the stamped ids, comma-joined in argument order.
//
// --- unassign <name> <id>... ---
// The exact mirror, without the flag, without the registry (a retired
// domain's tokens can be stripped - the ORPHAN remedy) and without a wake:
// `ERROR: usage: ac-domain.sh unassign <name> <id>...`; chief gate; name;
// ids; `ERROR: no fleet backlog at <path>`; the ledger lock as assign's.
// PASS 1: `no single row`; a token
// other than <name> at its position: `ERROR: '<id>' carries no
// domain:<name> token at its grammar position[ (it is assigned to '<cur>')]
// - nothing to reverse`; a section other than exactly Queued: `ERROR:
// '<id>' sits under '## <section>', not '## Queued' - an in-flight row's
// crewmate scope is baked at spawn, and a Done row's token is durable
// provenance`. `nothing to do` for a blank-only id list; backup
// `domain-unassign`; PASS 2 as assign's (`vanished mid-unassign`), the line
// stripped by `sed -E -e "s/; domain:<n>( \(repo: [^()]*\))\$/\1/" -e "s/;
// domain:<n>\$//"` (spawned, the line on stdin, the caller's locale - under
// UTF-8 BSD sed's 1 on such a byte); statusAppend(<name>, `unassign:
// <ids>`); `unassigned <ids> from crewdomain <n>`. A rerun is `nothing to
// reverse`, exit 1.
//
// --- queue <name> [--ids]: the domain's slice, read-only ---
// Scoped sessions may call it. `ERROR: usage: ac-domain.sh queue <name>
// [--ids]`; the name; no registry check. No ledger: stdout `no fleet
// backlog`, exit 0, even with --ids (W18). --ids iff the second word is
// exactly `--ids`; any other word is ignored (W18). A row (`- [`) is in the
// slice when its own domain is <name>, or it has none and its epic row's
// domain is <name> (suffix ` (via epic:<e>)`); names compare as strings (07
// is not 7). The full `## ...` line prints once before a section's first
// selected row (rows before any heading print headerless), then the row;
// --ids prints the id alone. A ledger that cannot be read: `ERROR: cannot
// read <ledger>`, exit 2, nothing on stdout.
//
// --- qa-repo: the domain's E2E REPOSITORY (AUTHORITATIVE) ---
// A domain whose behavioural proof lives in ONE maintained end-to-end
// repository - a suite that drives the domain's whole product line across
// every repo it spans, boots its own stack from those repos' sources, and is
// kept alive between campaigns - declares that repository here, by PROJECT
// NAME, in the optional fourth package member `qa-repo`. The declaration
// makes REUSE mechanical: `--set` on a domain that already declares a
// repository that resolves REFUSES and names it, and only `--force` moves it.
// The project must be one the DOMAIN carries (an entry of its own
// projects/), since QA works the domain's view of the clone. Which route a
// task takes is the intake-triage skill's to say; this verb only records the
// answer and mints no attestation - `ac-verify qa` stays the only producer
// of the pass marker `qa.require_for_ship` gates a merge on.
// Reading is open to every session; --set and --clear are the crewchief's
// alone. `ERROR: usage: ac-domain.sh qa-repo <name> [--set
// <project> [--force] | --clear]`; the name; then --set <p> (no value:
// `ERROR: --set needs a project name`), --clear, --force (alone: ignored),
// anything else `ERROR: unknown qa-repo argument: <a>`; the last of
// --set/--clear wins. A non-empty AC_SCOPE with --set or --clear: `ERROR:
// qa-repo --<set|clear> is the CREWCHIEF's verb and this session is scoped
// (AC_SCOPE=<s>) - which repository a domain's proof runs in is fleet
// routing, and only the crewchief sets it`; a --set value holding `/`:
// `ERROR: --set takes a project NAME, not a path: "<p>"`. No directory at
// <home>/crewdomains/<n> (the PACKAGE, not the registry - a retired kept
// package answers): `ERROR: no such crewdomain: <n> (package <pkg> does not
// exist)`.
//   read: domainQaRepo (src/lib.ts, ac_domain_qa_repo's twin: the member's
//     first line, every [:space:] deleted, `[ -e <pkg>/projects/<v> ]`, the
//     physical main repo root) printed, exit 0; else `ERROR: domain <n>
//     declares no e2e repository - declare it with: ac-domain.sh qa-repo <n>
//     --set <project>, or leave it undeclared and QA takes the profile-driven
//     route (ac-verify qa)`, stdout empty - a caller can branch on the exit.
//   --clear: `rm -f <pkg>/qa-repo` (its failure ends qa-repo with its
//     status); `qa-repo cleared for <n> - QA returns to the profile-driven
//     route`.
//   --set <p>: nothing at <pkg>/projects/<p>: `ERROR: <p> is not a project
//     of domain <n> - add it to the domain's projects/ view first (a
//     repository outside that view is one the domain's own sessions cannot
//     reach)`; no repository there: `ERROR: <p>
//     resolves to no git repository through <pkg>/projects/<p>`; a current
//     declaration that resolves, without --force (the same project too):
//     `ERROR: domain <n> already declares an e2e repository: <path> - reuse
//     it. Moving the declaration is deliberate: re-run with --force.`. Then
//     `<p>\n` to an exclusive temp and a spawned `mv` over qa-repo - a temp
//     that cannot be written skips the mv and goes on (W17), a failing mv
//     ends it with its status - and `qa-repo for <n>: <p> (<path>)`, <path>
//     the read answer ("" for none). No backup, status line or wake.
//
// --- retire <name>: one registry line, fail-closed ---
// `ERROR: usage: ac-domain.sh retire <name>`; chief gate; name; the registry
// parse (its stderr dropped) holding a VALID <name>, else, or when it failed,
// `ERROR: no VALID crewdomain '<n>' in records/crewdomains.md - nothing to
// retire`. With a ledger: the ids of tokened rows outside Done (`## Done` a
// PREFIX - `## Doneish` is Done; rows before any heading are open; a story
// inheriting its epic's domain is not counted, W16) refuse as `ERROR:
// crewdomain '<n>' still holds OPEN tokened rows - unassign them first:`
// followed by one id per line; a ledger that cannot be read: `ERROR: cannot
// read <ledger>`, exit 2. Then the families flying it - every
// state/*-chief.meta (byte order) whose last domain= is <name> (an
// unreadable meta: metaGet's `WARN: cannot read meta file <m>` and not
// flying) - refuse as `ERROR: crewdomain '<n>' has a domainchief in flight
// (<a>, <b>) - demote it first`. Then recordsBackup("domain-retire") (WARN,
// exit 1, or `backup: <arc>`); every `- ` line whose leading token is <name>
// dropped (INVALID twins too, W16) by a spawned awk under the caller's
// locale into an exclusive temp, `mv` over the registry (either failing ends
// retire with its status); statusAppend(<name>, `retire`) unguarded; stdout
// `retired crewdomain <n> - registry line removed; the package at
// crewdomains/<n> is kept (knowledge is never deleted by tooling)`. The
// package is never deleted: its Done rows keep the token as provenance (the
// orphan scans read open rows only), and a later `new` with the same name
// re-adopts the kept package (W15, fixed).
//
// --- list: the session-start digest block ---
// <reg> is domainRegistry() (records/ minted). No regular file (absent, a
// directory): `ABSENT: records/crewdomains.md - no crewdomains registered`,
// exit 0, and no scans (W3). The parse failing ends list with its status
// before a line is printed (W2: under UTF-8 one byte that is not UTF-8, or an
// unreadable registry, is exit 2). No record: `EMPTY: records/crewdomains.md
// present, 0 entries - no crewdomains registered`, exit 0, no scans. Each
// record is re-separated with US and read as `IFS=$'\037' read -r` over five
// names (a TAB in a line shifts its fields, and an INVALID reason gains a
// leading US, W5):
//   INVALID\t<verbatim line>\treason: <reason>
//   VALID\t<id>\tprojects: <k>
//   \tcharter: <charter>
//   \tscope: <scope>   (empty: `\tscope: (unset - not routable until a scope: is added)`)
//   \tbacklog: queued <q>, in flight <i>, done <d>   (domainTally; `?` each when the ledger cannot be read)
//   \tin flight: <fam>, <fam>   (only when a chief meta flies it)
// <k> counts the lines of the non-`.yaml` entry names of <pkg>/projects/ (a
// dangling link counts; 0 without a package, W3). Then UNREGISTERED: each
// directory crewdomains/<d>/ (byte order; a symlink to one counts; an illegal
// name is skipped) with no VALID record: `UNREGISTERED\t<d>\tpackage on disk
// with no VALID registry line - re-adopt it with `new`, restore its line in
// records/crewdomains.md, or leave it as kept knowledge`. Then, with a
// ledger, each tokened row outside Done (`## Done` a prefix, as retire reads
// it) in ledger order whose domain has no VALID record: `ORPHAN-TOKEN\t<domain>\t<id> - the row names a
// domain with no VALID registry line (unassign it, or re-`new` the domain)`;
// a ledger that cannot be read is `WARN\tledger unreadable - backlog tallies
// and the ORPHAN-TOKEN scan are unavailable` on stdout. Last `registered: <n>
// (invalid <i>)`, exit 0.
//
// --- validate: the strict twin, exit 0/1/2 ---
// No regular registry: silent exit 0 - the ledger is not scanned (W3). The
// parse's failure is no exit of its own (W3): each INVALID record it gave is
// `INVALID <verbatim line>: <reason>`, exit 1. For each VALID id (a second
// parse), its view, when <pkg>/projects is a directory: each entry (byte
// order) classified by domainViewEntry (src/lib.ts, ac_domain_view_entry's
// twin - the predicate bin/ac-spawn.sh's pre-lease guard runs too):
//   `INVALID <n>: projects/<e> is not a symlink - a domain view LINKS the fleet clones, it never holds a copy`
//   `INVALID <n>: projects/<e> dangles - it resolves to nothing`
//   `INVALID <n>: projects/<e> resolves OUTSIDE the fleet clones (<t>) - a view may only select from the fleet projects dir`
//   `INVALID <n>: projects/<e> resolves to <t>, not to its OWN clone - a view entry must name the project it links, or it authorizes work on a repository the domain never selected`
//   `INVALID <n>: projects/<e> - unrecognised view state "<cls>"`
// each exit 1; an ok non-`.yaml` entry with no <e>.yaml beside it: `WARN
// <n>: projects/<e> has no .yaml sibling - a project with no pipeline config
// is a supported direct-pr case, so this is not a refusal`. With a detail
// file <pkg>/records/projects.md (read as bytes): each fleet
// records/projects.md line `- <p> [<bracket>] - <desc> (added ...)` (the
// bracket optional; an unterminated last line is not read) whose <desc>, its
// trailing ` (added ...)` cut, is at least 12 BYTES and occurs in the
// detail: `WARN <n>: records/projects.md repeats the FLEET description of
// <p> verbatim - the description resolves from records/projects.md alone,
// and a copy here is the drift this file exists to avoid`; a
// `[mode|crew-ship|direct-pr|local-only|feature-pr]` token in it: `WARN <n>:
// records/projects.md carries a delivery-mode token - delivery mode is
// chosen per task on the backlog row, never a registry property, and a copy
// here is exactly the drift this file was designed not to have`; then the
// view names and the `## ` headings (each byte-sorted, then split at blanks
// - W19: `## Notes (2026)` is two words) compared both ways: `WARN <n>:
// projects/<p> is in the view but has no "## <p>" heading in
// records/projects.md - the detail prose has lagged the view` / `WARN <n>:
// records/projects.md documents "## <h>" but the view does not link it - the
// detail prose names a project this domain cannot work`. Then, with a
// ledger, per row in ledger order: `INVALID token: <id> carries a
// domain:-shaped run off its grammar position (backtick-quote a mention, or
// re-stamp with assign)`; `INVALID token: orphan domain token <domain> <id>`
// for a row outside Done when a fresh registry parse holds no VALID <domain>; `INVALID token: story
// <id> carries domain:<d> but its epic <e> carries domain:<ed> - one family,
// one domain` - each exit 1; a ledger that cannot be read: `ERROR: cannot
// read <ledger>` and `INVALID ledger: cannot read <ledger>`, exit 2.
//
// HOMELESS (W1, reproduced): every `$(ac_home)` the bash swallowed prints
// the refusal and goes on with "" - list: the refusal, then ABSENT, exit 0;
// validate: the refusal, exit 0; new, unassign, queue: the refusal, exit 1;
// assign: the refusal, then `no VALID crewdomain`; retire: the refusal, then
// `nothing to retire`; qa-repo: the refusal, then `no such crewdomain: <n>
// (package /crewdomains/<n> does not exist)`.
//
// EXIT: 0; 1 for every refusal; a child's status where its failure ended the
// bash under errexit (awk's 2, mktemp's, mkdir's, ln's, mv's, rm's, date's,
// sed's 1, 128+n for a signal, 127 for a child that could not start); 2 for
// a ledger that cannot be read.
//
// SPAWNED, with the original's argv: awk for the registry parse
// (domainParse), the registry collision, the row finder, the stamp, the
// retire rewrite; sed for the strip; grep for the row-id collision; mktemp
// and rm -f for the probe; mkdir -p, ln -s and rm -rf for the package; mv
// for every temp, rm -f for a ledger temp that matched nothing; rm -f for
// --clear; tr and git through domainQaRepo; date through iso(), statusAppend
// and wakePublish; mkdir -p, tar and rm through recordsBackup.
//
// DIVERGENCES from the original, named in the differential leg:
// - THE LEDGER LOCK (W8, fixed): assign and unassign
//   hold records/.backlog.md.lock from the first ledger read to the exit;
//   the original took none, wrote past a live holder and could erase a
//   commit made between its read and its mv. A backup taken inside the lock
//   carries the lock dir.
// - QA-REPO IS THE CHIEF'S, BY NAME (W17, fixed):
//   --set and --clear refuse a scoped session and --set refuses a value
//   holding `/`; the original let any session set or clear the declaration
//   and took a path through the view as the project.
// - DONE HISTORY AND KEPT PACKAGES (W15, fixed): the
//   orphan scans of list and validate skip Done rows, and new re-adopts a
//   kept package; the original read a retired domain's Done rows as
//   orphans (validate red for good) and refused the package it had kept.
// - EXCLUSIVE TEMPS (W9): the ledger's, the registry's and qa-repo's
//   <file>.tmp.<pid> are created exclusively (the next .<n> past a name
//   already taken), and the ledger and registry temps take their file's
//   mode; the original wrote through whatever sat at the predictable name
//   and left a 0600 ledger 0644.
// - The ledger is read in-process wherever the original ran the doneline awk
//   (queue, retire, list's tally and scan, validate's tokens), so its
//   parser-failure arm (a bun that cannot start: `ERROR: the backlog parser
//   failed on <f>`) and an assign whose token read could not run (W26) are
//   unreachable - without bun the shim never starts - and a ledger that
//   cannot be read is the parser's own `ERROR: cannot read <f>` where the
//   original printed awk's `can't open file` pair; stdout and exit alike.
// - The registry lookups read the parse's whole output, so a reader exiting
//   early never ends the parse with SIGPIPE (W23: a registry past the pipe's
//   capacity with the domain early made the original's assign refuse).
// - The detail file and the fleet descriptions are read as bytes (LC_ALL=C):
//   under a UTF-8 locale the original's ${#desc} counted characters (W20)
//   and its grep/awk/sed there ran under that locale; an unreadable detail
//   file reads as empty without their own lines.
// - No pathname expansion: the original split new's project list and
//   validate's names and headings unquoted with globbing on, so a `*` or `?`
//   in one became the caller's cwd entries (W19); here it stays a word - the
//   leg runs from an empty cwd, where the two agree.
// - Bytes: argv arrives decoded, so a byte that is not UTF-8 in a charter,
//   scope, captain's words or project is U+FFFD; a path that is not UTF-8
//   reaches a spawned child's argv as U+FFFD.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) wherever the
//   shell printed cd's own line; exits and stdout alike.
// - Shell-own stderr is not reproduced: a failed redirection's
//   `Permission denied` line (an unwritable registry, package member,
//   ledger temp or qa-repo temp), `command not found` - the exit statuses
//   are.
//
// CALLERS: bin/ac-session-start.sh prints `list` under `-- crewdomains
// (routing table) --` and, since list needs bun, degrades to a WARN naming
// this entry when it fails (pinned in tests/sh/ac-session-start.test.sh);
// the deputies-domains, domain-knowledge, domain-e2e and intake-triage skills
// run the verbs by hand; a domainchief's kickoff (bin/ac-spawn.sh) names
// `queue`. The files it writes are read elsewhere: the routing line by
// ac_domain_parse (bin/ac-spawn.sh's promote) and dashboard/app.ts, the
// stamp by src/backlog.ts, the package by bin/ac-spawn.sh's view guard, the
// seed chain and the dashboard, the wake by bin/ac-wake-drain.sh.
import { appendFileSync, chmodSync, closeSync, existsSync, lstatSync, openSync, readdirSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { acDoneline, records } from "./backlog.ts";
import {
  awkAssign,
  backlogIdOk,
  die,
  domainNameOk,
  domainParse,
  domainQaRepo,
  domainRegistry,
  domainTally,
  domainViewEntry,
  enterCaller,
  envHome,
  iso,
  ledgerLock,
  metaGet,
  NO_HOME,
  projectDir,
  recordsBackup,
  shellStatus,
  softHome,
  softSubdir,
  spawnShellSync,
  statusAppend,
  wakePublish,
  warn,
} from "./lib.ts";

const REGISTRY_LABEL = "records/crewdomains.md";
const US = "\x1f";

// The spawned programs, byte for byte as tests/fixtures/ac-domain.sh holds
// them (tests/ts/domain.test.ts lifts each one out of it).
const HOLDS_AWK = String.raw`
      substr($0, 1, 2) != "- " { next }
      { line = substr($0, 3); sub(/ +- .*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == n) { found = 1 } }
      END { exit !found }
    `;
const ROW_OF_AWK = String.raw`
    /^## / { sec = substr($0, 4); next }
    $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
    END { if (n == 1) printf "%s\t%s\n", s, l }
  `;
const STAMP_AWK = String.raw`{ if (sub(/ \(repo: [^()]*\)$/, "; domain:" n "&")) print; else print $0 "; domain:" n }`;
const RETIRE_AWK = String.raw`
    substr($0, 1, 2) == "- " {
      line = substr($0, 3); sub(/ +- .*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == n) next
    }
    { print }
  `;

// Byte strings (latin1) carry what the bash held as bytes; argv and paths
// arrive as UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const lines = (b: Uint8Array): string[] => {
  const l = Buffer.from(b).toString("latin1").split("\n");
  if (l[l.length - 1] === "") l.pop();
  return l;
};
// Unquoted word splitting under the default IFS.
const words = (s: string): string[] => s.split(/[ \t\n]+/).filter((w) => w !== "");
const byteOrder = (a: string, b: string): number => Buffer.compare(Buffer.from(a), Buffer.from(b));

function out(s: string): void {
  const b = Buffer.from(s, "latin1");
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

function fail(msg: string): never {
  die(Buffer.from(msg, "latin1"));
}

function isFile(p: string | Buffer): boolean {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function isDir(p: string | Buffer): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function run(
  cmd: string[],
  stdin: "inherit" | "ignore" | Buffer,
  stdout: "inherit" | "pipe" | number,
  stderr: "inherit" | "ignore" = "inherit",
): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// The registry parse as a whole: a null argv (no regular file) is the bash's
// empty, successful parse.
function parse(argv: string[] | null, stderr: "inherit" | "ignore" = "inherit"): { status: number; recs: string[][] } {
  if (argv === null) return { status: 0, recs: [] };
  const r = run(argv, "inherit", "pipe", stderr);
  return { status: r.status, recs: lines(r.out).map((l) => l.split("\t")) };
}

const isValid = (recs: string[][], name: string): boolean => recs.some((f) => f[0] === "VALID" && f[1] === name);

// `IFS=$'\037' read -r v1 ... vn`: fields split at each US, the last name
// taking the rest of the line, missing fields empty.
function readUS(line: string, n: number): string[] {
  const f = line.split(US);
  const v = [...f.slice(0, n - 1), f.slice(n - 1).join(US)];
  while (v.length < n) v.push("");
  return v;
}

// `$(ac_records_dir)` where the bash assigned it bare: homeless or
// unenterable, the refusal and exit 1.
function recordsHard(): string {
  const r = softSubdir("records", true);
  if (r === "") process.exit(1);
  return r;
}

function readLedger(f: string): string | null {
  try {
    return readFileSync(f, "latin1");
  } catch {
    writeSync(2, Buffer.from(`ERROR: cannot read ${b8(f)}\n`, "latin1"));
    return null;
  }
}

function rows(text: string): { rec: string; o: ReturnType<typeof acDoneline> | null }[] {
  return records(text).map((rec) => ({ rec, o: rec.startsWith("- [") ? acDoneline(rec) : null }));
}

function chiefOnly(verb: string): void {
  const scope = process.env.AC_SCOPE ?? "";
  if (scope !== "")
    fail(`${verb} is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=${b8(scope)}) - only the crewchief creates domain rows, and the provenance token means nothing if a scoped session can stamp it`);
}

function requireName(name: string): void {
  if (!domainNameOk(name)) fail(`not a legal crewdomain name: '${b8(name)}' (charset [a-z0-9-], no path separators) - refusing to derive a package path from it`);
}

function requireIds(ids: string[]): void {
  for (const id of ids)
    if (!backlogIdOk(id)) fail(`not a legal backlog id: '${b8(id)}' (charset [a-z0-9-]) - refusing rather than matching it as a regular expression against the ledger`);
}

function dedupe(label: string, items: string[]): string {
  let seen = "";
  for (const it of items) {
    if (it === "") fail(`empty ${label} in the argument list - refusing before any write`);
    if (` ${seen} `.includes(` ${it} `))
      fail(`duplicate ${label} "${b8(it)}" - refusing before any write: a repeat would half-apply and leave state neither whole nor reversible`);
    seen = `${seen} ${it}`;
  }
  return items.join("\n").replace(/\n+$/, "");
}

// The names a package's projects/ view links (the `.yaml` siblings left
// out), as its glob listed them.
function viewNames(name: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(`${softHome(true)}/crewdomains/${name}/projects`);
  } catch {}
  return names.filter((e) => !e.startsWith(".") && !e.endsWith(".yaml")).sort(byteOrder);
}

// The families whose chief meta flies <name>, as `<a>, <b>`.
function flyingFamilies(name: string): string {
  const sd = softSubdir("state", true);
  let metas: string[] = [];
  try {
    metas = readdirSync(sd);
  } catch {}
  const fams: string[] = [];
  for (const m of metas.filter((x) => !x.startsWith(".") && x.endsWith("-chief.meta")).sort(byteOrder)) {
    if (!isFile(`${sd}/${m}`)) continue;
    let d = "";
    try {
      d = metaGet(`${sd}/${m}`, "domain");
    } catch {}
    if (d === name) fams.push(b8(m.slice(0, -"-chief.meta".length)));
  }
  return fams.join(", ");
}

// <file>.<tag>.<pid>, or <file>.<tag>.<pid>.<n> past a name already taken:
// created EXCLUSIVELY, never written through what sat there, and given
// <mode> when one is named.
function claimTemp(file: string, tag: string, mode: number | null): { path: string; fd: number } {
  let path = `${file}.${tag}.${process.pid}`;
  for (let n = 1; ; n++) {
    try {
      const fd = openSync(fsPath(path), "wx");
      if (mode !== null) chmodSync(fsPath(path), mode);
      return { path, fd };
    } catch (e) {
      if ((e as { code?: string }).code !== "EEXIST") throw e;
      path = `${file}.${tag}.${process.pid}.${n}`;
    }
  }
}

function modeOf(file: string): number | null {
  try {
    return statSync(fsPath(file)).mode & 0o7777;
  } catch {
    return null;
  }
}

// One exact ledger line replaced in place as `awk -v old= -v new=` did it:
// both values read the way -v reads one (awkAssign), the FIRST equal line
// replaced, every line written back LF-ended. False when no line matched or
// the temp or the mv failed.
function rewriteRow(ledger: string, oldLine: string, newLine: string): boolean {
  const old = awkAssign(oldLine);
  const repl = awkAssign(newLine);
  let t: { path: string; fd: number };
  try {
    t = claimTemp(ledger, "tmp", modeOf(ledger));
  } catch {
    return false;
  }
  let body = "";
  let done = false;
  try {
    for (const rec of records(readFileSync(fsPath(ledger), "latin1"))) {
      if (!done && rec === old) {
        body += `${repl}\n`;
        done = true;
      } else body += `${rec}\n`;
    }
    writeSync(t.fd, Buffer.from(body, "latin1"));
  } catch {
    done = false;
  }
  closeSync(t.fd);
  if (!done) {
    run(["rm", "-f", u8(t.path)], "inherit", "inherit");
    return false;
  }
  return run(["mv", u8(t.path), u8(ledger)], "inherit", "inherit").status === 0;
}

// `found="$(LC_ALL=C awk -v id=<id> ...)"`: "<section>\t<line>" for the one
// row, "" for none or several; the awk failing ends the run with its status.
function rowOf(id: string, ledger: string): string {
  const r = run(["/usr/bin/env", "LC_ALL=C", "awk", "-v", `id=${id}`, ROW_OF_AWK, ledger], "inherit", "pipe");
  if (r.status !== 0) process.exit(r.status);
  return subst(r.out);
}

function splitFound(found: string): [string, string] {
  const tab = found.indexOf("\t");
  return tab < 0 ? [found, found] : [found.slice(0, tab), found.slice(tab + 1)];
}

// A filter over one line on stdin, as `x="$(printf '%s\n' <line> | <cmd>)"`
// ran bare under pipefail: the filter's failure ends the run with its status.
function filterLine(cmd: string[], line: string): string {
  const r = run(cmd, Buffer.from(`${line}\n`, "latin1"), "pipe");
  if (r.status !== 0) process.exit(r.status);
  return subst(r.out);
}

function cmdNew(a: string[]): number {
  const name = a[0] ?? "";
  if (name === "") fail("usage: ac-domain.sh new <name> --scope '<text>' --charter '<text>' (--projects <p1,p2,...> | --no-projects)");
  let scope = "";
  let charter = "";
  let projects = "";
  let noProjects = false;
  let haveScope = false;
  let haveCharter = false;
  let haveProjects = false;
  for (let i = 1; i < a.length; ) {
    const f = a[i]!;
    if (f === "--scope" || f === "--charter" || f === "--projects") {
      if (i + 1 >= a.length) fail(`${f} needs a value`);
      const v = a[i + 1]!;
      if (f === "--scope") [scope, haveScope] = [v, true];
      else if (f === "--charter") [charter, haveCharter] = [v, true];
      else [projects, haveProjects] = [v, true];
      i += 2;
    } else if (f === "--no-projects") {
      noProjects = true;
      i++;
    } else fail(`unknown argument: ${b8(f)}`);
  }
  chiefOnly("new");
  if (!haveCharter || charter === "") fail("--charter '<one-liner>' is required and may not be empty: it is what the chief reads in the digest");
  if (!haveScope)
    fail("--scope '<text>' is required: it is the routing key, and an entry without one is registered but never routable. Pass --scope '' deliberately if that is what you mean.");
  if (haveProjects && noProjects) fail("--projects and --no-projects are mutually exclusive - refusing rather than silently building the empty view you did not ask for");
  if (!noProjects && !haveProjects) fail("pass --projects <p1,p2,...> or --no-projects explicitly - a silent empty project view is the wrong default");
  if (/[^a-z0-9-]/.test(name)) fail(`name must be [a-z0-9-]: ${b8(name)}`);

  if (!process.env.AC_HOME) die(NO_HOME);
  const home = envHome();
  const recs = recordsHard();
  const pkg = `${home}/crewdomains/${name}`;

  if (/-(spec|arch|plan|review|ship|design|chief|r[0-9]|r[0-9][0-9])$/.test(name))
    fail(`name '${name}' collides with a reserved stage suffix - a family id derives stage dirs from it`);
  const holds = (file: string): boolean => isFile(file) && run(["awk", "-v", `n=${name}`, HOLDS_AWK, file], "inherit", "inherit").status === 0;
  if (holds(domainRegistry())) fail(`name '${name}' is already registered in ${REGISTRY_LABEL}`);
  if (holds(`${recs}/crewdeputies.md`))
    fail(`name '${name}' is already a crewdeputy in records/crewdeputies.md - the two features share no file, but they share the operator's vocabulary and the chief's routing judgment; pick a different name`);
  if (existsSync(`${home}/crewdeputies/${name}`)) fail(`name '${name}' collides with an existing crewdeputy home at crewdeputies/${name}`);
  // What retire leaves - all three members - is a KEPT package, re-adopted
  // here; anything else at that path is a collision.
  const readopt = isFile(`${pkg}/CREWMATE.md`) && isFile(`${pkg}/records/projects.md`) && isDir(`${pkg}/projects`);
  if (!readopt && existsSync(pkg)) fail(`name '${name}' collides with an existing directory at crewdomains/${name}`);
  if (existsSync(`${home}/data/${name}`)) fail(`name '${name}' collides with a task data dir at data/${name}`);
  if (existsSync(`${home}/state/${name}-chief.meta`)) fail(`name '${name}' collides with a live chief session at state/${name}-chief.meta`);
  if (isFile(`${recs}/backlog.md`) && run(["grep", "-qE", `^- \\[[ x]\\] ${name} `, `${recs}/backlog.md`], "inherit", "inherit").status === 0)
    fail(`name '${name}' is already a row id in records/backlog.md`);

  let stamp = "";
  try {
    stamp = iso();
  } catch {}
  const candidate = `- ${name} - ${b8(charter)} - scope: ${b8(scope)} (added ${stamp})`;
  if (candidate.includes("\n")) fail("--charter/--scope must be single-line: a newline would split the routing line in two");
  const mk = run(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-domain-line.XXXXXX`], "inherit", "pipe");
  if (mk.status !== 0) return mk.status;
  const probe = subst(mk.out);
  try {
    writeFileSync(fsPath(probe), Buffer.from(`${candidate}\n`, "latin1"));
  } catch {
    return 1;
  }
  const rmProbe = (): void => {
    const rm = run(["rm", "-f", u8(probe)], "inherit", "inherit");
    if (rm.status !== 0) process.exit(rm.status);
  };
  if (!parse(domainParse(u8(probe))).recs.some((f) => f.join("\t").startsWith("VALID"))) {
    const again = parse(domainParse(u8(probe)));
    if (again.status !== 0) return again.status;
    const why = again.recs.map((f) => (f.length > 1 ? (f[4] ?? "") : f[0]!)).join("\n").replace(/\n+$/, "");
    rmProbe();
    fail(`the routing line these arguments would write does not parse VALID (${why}) - refusing before any write. Check --charter and --scope for a ' - <word>:' token, which this grammar reads as an unknown field.`);
  }
  rmProbe();

  const wanted: string[] = [];
  if (!noProjects) {
    if (projects.startsWith(",") || projects.endsWith(",") || projects.includes(",,"))
      fail(`malformed --projects list "${b8(projects)}": leading, trailing or repeated commas - refusing before any write rather than silently building a shorter view`);
    if (projects.includes("/")) fail(`--projects takes project NAMES, not paths: "${b8(projects)}"`);
    const plist = dedupe("project", words(projects.replace(/,/g, " ")));
    if (plist === "") fail("--projects named no project - pass --no-projects if the empty view is what you meant");
    for (const p of words(plist)) {
      if (!isDir(`${home}/projects/${p}/.git`)) fail(`the fleet has no clone at projects/${b8(p)} - a domain view links the fleet's own clones, it never makes one`);
      wanted.push(p);
    }
  }

  // Whole or nothing covers a failure DURING the write too: everything this
  // command created goes, and the registry line - the last write - is what
  // makes the package a domain. A kept package is knowledge, so a failed
  // re-adoption removes only the links it made.
  const made: string[] = [];
  const rollback = (status: number): never => {
    if (readopt) {
      if (made.length > 0) run(["rm", "-f", ...made], "inherit", "inherit");
      writeSync(2, Buffer.from(`rolled back the re-adoption of the kept package at ${b8(pkg)} - it is as it was, and nothing was registered\n`, "latin1"));
    } else {
      run(["rm", "-rf", pkg], "inherit", "inherit");
      writeSync(2, Buffer.from(`rolled back the partial package at ${b8(pkg)} - nothing was created\n`, "latin1"));
    }
    process.exit(status);
  };
  const step = (cmd: string[]): void => {
    const r = run(cmd, "inherit", "inherit");
    if (r.status !== 0) rollback(r.status);
  };
  const present = (p: string): boolean => {
    try {
      lstatSync(p);
      return true;
    } catch {
      return false;
    }
  };
  const link = (target: string, at: string): void => {
    step(["ln", "-s", target, at]);
    made.push(at);
  };
  if (!readopt) step(["mkdir", "-p", `${pkg}/records`, `${pkg}/projects`]);
  const detail =
    `# Projects: ${name}\n\nThe domain's view of each in-scope project - which part belongs to this domain, partner context, constraints, entry points. The fleet description lives in records/projects.md, delivery mode on each backlog row; verified code facts live in records/repo-knowledge/<project>.md.\n` +
    "\nOne `## <project-name>` heading per in-scope project - `validate` compares that set against the projects/ view.\n" +
    wanted.map((p) => `\n## ${b8(p)}\n`).join("");
  if (!readopt)
    try {
      writeFileSync(`${pkg}/records/projects.md`, Buffer.from(detail, "latin1"));
      writeFileSync(`${pkg}/CREWMATE.md`, `# Crewmate instructions: ${name}\n\nThe domain instruction layer, seeded onto the fleet baseline.\n`);
    } catch {
      rollback(1);
    }
  let yamlless = "";
  let added = 0;
  for (const w of wanted) {
    if (readopt && present(`${pkg}/projects/${w}`)) continue;
    link(`../../../projects/${w}`, `${pkg}/projects/${w}`);
    added++;
    if (existsSync(`${home}/projects/${w}.yaml`)) {
      if (!(readopt && present(`${pkg}/projects/${w}.yaml`))) link(`../../../projects/${w}.yaml`, `${pkg}/projects/${w}.yaml`);
    } else yamlless += ` ${b8(w)}.yaml`;
  }
  try {
    appendFileSync(domainRegistry(), Buffer.from(`${candidate}\n`, "latin1"));
  } catch {
    rollback(1);
  }
  if (readopt) out(`re-adopted crewdomain ${name} at crewdomains/${name} (${added} project link(s) added; the kept package is otherwise unchanged)\n`);
  else out(`created crewdomain ${name} at crewdomains/${name} (${wanted.length} project link(s))\n`);
  if (yamlless !== "")
    out(`no pipeline config in the fleet for:${yamlless} - linked the clone alone (a project with no <name>.yaml is a supported direct-pr case)\n`);
  return 0;
}

function cmdAssign(a: string[]): number {
  const name = a[0] ?? "";
  let captain = "";
  const rest: string[] = [];
  for (let i = 1; i < a.length; ) {
    if (a[i] === "--captain-requested") {
      captain = a[i + 1] ?? "";
      if (captain === "") fail("--captain-requested needs the captain's words (the authority is the record)");
      i += 2;
    } else rest.push(a[i++]!);
  }
  if (name === "" || rest.length === 0) fail("usage: ac-domain.sh assign <name> <backlog-id>... [--captain-requested '<words>']");
  chiefOnly("assign");
  requireName(name);
  const ids = words(dedupe("backlog id", rest));
  requireIds(ids);
  const reg = parse(domainParse());
  const rec = reg.recs.find((f) => f[0] === "VALID" && f[1] === name);
  if (reg.status !== 0 || rec === undefined) fail(`no VALID crewdomain '${name}' in ${REGISTRY_LABEL}`);
  if ((rec[3] ?? "") === "") fail(`crewdomain '${name}' has an empty scope: - it is not routable, and the chief may not invent scope text for it`);
  const recs = recordsHard();
  const backlog = `${recs}/backlog.md`;
  if (!isFile(backlog)) fail(`no fleet backlog at ${b8(backlog)}`);
  const locked = ledgerLock(`${recs}/.backlog.md.lock`, "records/backlog.md");
  if (locked !== null) fail(locked);

  const todo: string[] = [];
  const already: string[] = [];
  for (const item of ids) {
    const found = rowOf(item, backlog);
    if (found === "") fail(`no single row for '${item}' in ${b8(backlog)}`);
    const [section, line] = splitFound(found);
    const cur = acDoneline(line).domain;
    if (cur === name) {
      already.push(item);
      continue;
    }
    if (cur !== "") fail(`'${item}' is already assigned to crewdomain '${cur}' - unassign it there first; a silent steal is how one row ends up claimed twice`);
    if (section === "In flight") {
      if (captain === "")
        fail(`'${item}' sits under '## In flight' - adopting live work into a domain is the captain's call: re-run with --captain-requested '<the captain's words>' (a stamp changes nothing in the flying crewmate's env, but the authority must be on record)`);
    } else if (section !== "Queued") fail(`'${item}' sits under '## ${section}' - Done history keeps the provenance it was made with`);
    todo.push(item);
  }
  if (already.length) out(`already assigned to ${name}: ${already.join(",")}\n`);
  if (todo.length === 0) {
    out("nothing to do\n");
    return 0;
  }
  const ids2 = todo.join(",");
  const arc = recordsBackup("domain-assign");
  if (arc === null) return 1;
  out(`backup: ${arc}\n`);
  for (const item of todo) {
    const found = rowOf(item, backlog);
    if (found === "") fail(`the row for '${item}' vanished mid-assign - the ledger changed under this command; re-run`);
    const line = splitFound(found)[1];
    const stamped = filterLine(["awk", "-v", `n=${name}`, STAMP_AWK], line);
    if (!rewriteRow(b8(backlog), line, stamped)) fail(`could not rewrite the row for '${item}' - the ledger changed under this command; re-run`);
    out(`${stamped}\n`);
  }
  let appended = false;
  try {
    appended = statusAppend(name, `assign: ${ids2}${captain !== "" ? ` [captain-requested: ${b8(captain)}]` : ""}`, true);
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
  if (!appended) return 1;
  // Loud on failure: the success line prints either way, so a silent miss
  // would read as a wake the drain is about to announce.
  if (!wakePublish(softSubdir("state", true), "", "domain", name, `assign: ${ids2}`))
    warn(Buffer.from(`assign: the durable wake could not be published - the rows are STAMPED, but your drain will not announce it; check ${b8(softSubdir("state", true))}/.wake-spool`, "latin1"));
  out(`assigned ${ids2} to crewdomain ${name}\n`);
  return 0;
}

function cmdUnassign(a: string[]): number {
  const name = a[0] ?? "";
  const rest = a.slice(1);
  if (name === "" || rest.length === 0) fail("usage: ac-domain.sh unassign <name> <id>...");
  chiefOnly("unassign");
  requireName(name);
  const ids = words(dedupe("backlog id", rest));
  requireIds(ids);
  const recs = recordsHard();
  const backlog = `${recs}/backlog.md`;
  if (!isFile(backlog)) fail(`no fleet backlog at ${b8(backlog)}`);
  const locked = ledgerLock(`${recs}/.backlog.md.lock`, "records/backlog.md");
  if (locked !== null) fail(locked);

  for (const item of ids) {
    const found = rowOf(item, backlog);
    if (found === "") fail(`no single row for '${item}' in ${b8(backlog)}`);
    const [section, line] = splitFound(found);
    const cur = acDoneline(line).domain;
    if (cur !== name)
      fail(`'${item}' carries no domain:${name} token at its grammar position${cur !== "" ? ` (it is assigned to '${cur}')` : ""} - nothing to reverse`);
    if (section !== "Queued")
      fail(`'${item}' sits under '## ${section}', not '## Queued' - an in-flight row's crewmate scope is baked at spawn, and a Done row's token is durable provenance`);
  }
  if (ids.length === 0) {
    out("nothing to do\n");
    return 0;
  }
  const arc = recordsBackup("domain-unassign");
  if (arc === null) return 1;
  out(`backup: ${arc}\n`);
  for (const item of ids) {
    const found = rowOf(item, backlog);
    if (found === "") fail(`the row for '${item}' vanished mid-unassign - the ledger changed under this command; re-run`);
    const line = splitFound(found)[1];
    const stripped = filterLine(["sed", "-E", "-e", `s/; domain:${name}( \\(repo: [^()]*\\))$/\\1/`, "-e", `s/; domain:${name}$//`], line);
    if (!rewriteRow(b8(backlog), line, stripped)) fail(`could not rewrite the row for '${item}' - the ledger changed under this command; re-run`);
    out(`${stripped}\n`);
  }
  let appended = false;
  try {
    appended = statusAppend(name, `unassign: ${ids.join(",")}`, true);
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
  if (!appended) return 1;
  out(`unassigned ${ids.join(",")} from crewdomain ${name}\n`);
  return 0;
}

function cmdQueue(a: string[]): number {
  const name = a[0] ?? "";
  if (name === "") fail("usage: ac-domain.sh queue <name> [--ids]");
  requireName(name);
  const backlog = `${recordsHard()}/backlog.md`;
  if (!isFile(backlog)) {
    out("no fleet backlog\n");
    return 0;
  }
  const text = readLedger(backlog);
  if (text === null) return 2;
  const ledger = rows(text);
  const dom = new Map<string, string>();
  for (const { o } of ledger) if (o && o.domain !== "") dom.set(o.id, o.domain);
  let sec = "";
  let shown = false;
  for (const { rec, o } of ledger) {
    if (rec.startsWith("## ")) {
      sec = rec;
      shown = false;
      continue;
    }
    if (!o) continue;
    let via = "";
    if (o.domain === name) {
    } else if (o.domain === "" && o.epic !== "" && dom.get(o.epic) === name) via = ` (via epic:${o.epic})`;
    else continue;
    if (a[1] === "--ids") {
      out(`${o.id}\n`);
      continue;
    }
    if (!shown && sec !== "") {
      out(`${sec}\n`);
      shown = true;
    }
    out(`${rec}${via}\n`);
  }
  return 0;
}

function cmdQaRepo(a: string[]): number {
  const name = a[0] ?? "";
  if (name === "") fail("usage: ac-domain.sh qa-repo <name> [--set <project> [--force] | --clear]");
  requireName(name);
  let mode = "";
  let proj = "";
  let force = false;
  for (let i = 1; i < a.length; i++) {
    const f = a[i]!;
    if (f === "--set") {
      mode = "set";
      proj = a[++i] ?? "";
      if (proj === "") fail("--set needs a project name");
    } else if (f === "--clear") mode = "clear";
    else if (f === "--force") force = true;
    else fail(`unknown qa-repo argument: ${b8(f)}`);
  }
  // Which repository a domain's proof runs in is fleet routing, named by the
  // project and never by a path through the view.
  const scope = process.env.AC_SCOPE ?? "";
  if (mode !== "" && scope !== "")
    fail(`qa-repo --${mode} is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=${b8(scope)}) - which repository a domain's proof runs in is fleet routing, and only the crewchief sets it`);
  if (mode === "set" && proj.includes("/")) fail(`--set takes a project NAME, not a path: "${b8(proj)}"`);
  const pkg = `${softHome(true)}/crewdomains/${name}`;
  if (!isDir(pkg)) fail(`no such crewdomain: ${name} (package ${b8(pkg)} does not exist)`);

  if (mode === "") {
    const path = domainQaRepo(name);
    if (path === null)
      fail(`domain ${name} declares no e2e repository - declare it with: ac-domain.sh qa-repo ${name} --set <project>, or leave it undeclared and QA takes the profile-driven route (ac-verify qa)`);
    out(`${b8(path)}\n`);
    return 0;
  }
  if (mode === "clear") {
    const rm = run(["rm", "-f", `${pkg}/qa-repo`], "inherit", "inherit");
    if (rm.status !== 0) return rm.status;
    out(`qa-repo cleared for ${name} - QA returns to the profile-driven route\n`);
    return 0;
  }
  // SCOPE before POLICY: a project the domain could never carry is refused
  // by name whatever is declared, so the message names the caller's mistake.
  if (!existsSync(`${pkg}/projects/${proj}`))
    fail(`${b8(proj)} is not a project of domain ${name} - add it to the domain's projects/ view first (a repository outside that view is one the domain's own sessions cannot reach)`);
  if (projectDir(`${pkg}/projects/${proj}`) === null) fail(`${b8(proj)} resolves to no git repository through ${b8(pkg)}/projects/${b8(proj)}`);
  const current = domainQaRepo(name, "ignore");
  if (current !== null && !force)
    fail(`domain ${name} already declares an e2e repository: ${b8(current)} - reuse it. Moving the declaration is deliberate: re-run with --force.`);
  let t: { path: string; fd: number } | null = null;
  try {
    t = claimTemp(b8(`${pkg}/qa-repo`), "tmp", null);
    writeSync(t.fd, Buffer.from(`${b8(proj)}\n`, "latin1"));
  } catch {
    t = null;
  }
  if (t !== null) {
    closeSync(t.fd);
    const mv = run(["mv", u8(t.path), `${pkg}/qa-repo`], "inherit", "inherit");
    if (mv.status !== 0) return mv.status;
  }
  out(`qa-repo for ${name}: ${b8(proj)} (${b8(domainQaRepo(name) ?? "")})\n`);
  return 0;
}

function cmdRetire(a: string[]): number {
  const name = a[0] ?? "";
  if (name === "") fail("usage: ac-domain.sh retire <name>");
  chiefOnly("retire");
  requireName(name);
  const reg = domainRegistry();
  const p = parse(domainParse(reg), "ignore");
  if (p.status !== 0 || !isValid(p.recs, name)) fail(`no VALID crewdomain '${name}' in ${REGISTRY_LABEL} - nothing to retire`);
  const backlog = `${recordsHard()}/backlog.md`;
  if (isFile(backlog)) {
    const text = readLedger(backlog);
    if (text === null) return 2;
    let done = false;
    let open = "";
    for (const { rec, o } of rows(text)) {
      if (rec.startsWith("## ")) done = rec.startsWith("## Done");
      if (o && !done && o.domain === name) open += `${o.id}\n`;
    }
    open = open.replace(/\n+$/, "");
    if (open !== "") fail(`crewdomain '${name}' still holds OPEN tokened rows - unassign them first:\n${open}`);
  }
  const flying = flyingFamilies(name);
  if (flying !== "") fail(`crewdomain '${name}' has a domainchief in flight (${flying}) - demote it first`);
  const arc = recordsBackup("domain-retire");
  if (arc === null) return 1;
  out(`backup: ${arc}\n`);
  let t: { path: string; fd: number };
  try {
    t = claimTemp(b8(reg), "tmp", modeOf(b8(reg)));
  } catch {
    return 1;
  }
  const r = run(["awk", "-v", `n=${name}`, RETIRE_AWK, reg], "inherit", t.fd);
  closeSync(t.fd);
  if (r.status !== 0) return r.status;
  const mv = run(["mv", u8(t.path), reg], "inherit", "inherit");
  if (mv.status !== 0) return mv.status;
  let appended = false;
  try {
    appended = statusAppend(name, "retire", true);
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
  if (!appended) return 1;
  out(`retired crewdomain ${name} - registry line removed; the package at crewdomains/${name} is kept (knowledge is never deleted by tooling)\n`);
  return 0;
}

function cmdList(): number {
  const reg = domainRegistry();
  if (!isFile(reg)) {
    out(`ABSENT: ${REGISTRY_LABEL} - no crewdomains registered\n`);
    return 0;
  }
  const p = parse(domainParse(reg));
  if (p.status !== 0) return p.status;
  const recs = subst(Buffer.from(p.recs.map((f) => `${f.join(US)}\n`).join(""), "latin1"));
  if (recs === "") {
    out(`EMPTY: ${REGISTRY_LABEL} present, 0 entries - no crewdomains registered\n`);
    return 0;
  }
  const registered = (d: string): boolean => recs.includes(`VALID${US}${d}${US}`);
  let n = 0;
  let invalid = 0;
  for (const line of recs.split("\n")) {
    const [cls, id, charter, scope, reason] = readUS(line, 5) as [string, string, string, string, string];
    if (cls === "") continue;
    n++;
    if (cls === "INVALID") {
      invalid++;
      out(`INVALID\t${id}\treason: ${reason}\n`);
      continue;
    }
    const [q = "", i = "", d = ""] = words(domainTally(id) ?? "? ? ?");
    const k = viewNames(id).map((e) => `${b8(e)}\n`).join("").split("\n").filter((l) => l !== "").length;
    out(`VALID\t${id}\tprojects: ${k}\n`);
    out(`\tcharter: ${charter}\n`);
    out(scope !== "" ? `\tscope: ${scope}\n` : "\tscope: (unset - not routable until a scope: is added)\n");
    out(`\tbacklog: queued ${q}, in flight ${i}, done ${d}\n`);
    const flying = flyingFamilies(id);
    if (flying !== "") out(`\tin flight: ${flying}\n`);
  }
  // Retired-but-present packages and tokens naming no VALID line: the
  // digest is where detection happens.
  const home = softHome(true);
  let pkgs: string[] = [];
  try {
    pkgs = readdirSync(`${home}/crewdomains`);
  } catch {}
  for (const g of pkgs.filter((x) => !x.startsWith(".")).sort(byteOrder)) {
    if (!isDir(`${home}/crewdomains/${g}`) || !domainNameOk(g) || registered(g)) continue;
    out(`UNREGISTERED\t${g}\tpackage on disk with no VALID registry line - re-adopt it with \`new\`, restore its line in ${REGISTRY_LABEL}, or leave it as kept knowledge\n`);
  }
  const ob = `${softSubdir("records", true)}/backlog.md`;
  if (isFile(ob)) {
    const text = readLedger(ob);
    if (text === null) out("WARN\tledger unreadable - backlog tallies and the ORPHAN-TOKEN scan are unavailable\n");
    else {
      // Done history keeps the token it was made with as provenance, so only
      // an open row can name a domain that is gone.
      let done = false;
      for (const { rec, o } of rows(text)) {
        if (rec.startsWith("## ")) done = rec.startsWith("## Done");
        if (o && !done && o.domain !== "" && !registered(o.domain))
          out(`ORPHAN-TOKEN\t${o.domain}\t${o.id} - the row names a domain with no VALID registry line (unassign it, or re-\`new\` the domain)\n`);
      }
    }
  }
  out(`registered: ${n} (invalid ${invalid})\n`);
  return 0;
}

// `for n in $(domain_names)`: every VALID id of a fresh registry parse.
function domainNames(): string[] {
  return parse(domainParse()).recs.filter((f) => f[0] === "VALID").map((f) => f[1] ?? "");
}

function validateProjects(name: string): number {
  const pkg = `${softHome(true)}/crewdomains/${name}`;
  if (!isDir(`${pkg}/projects`)) return 0;
  let rc = 0;
  let entries: string[] = [];
  try {
    entries = readdirSync(`${pkg}/projects`);
  } catch {}
  for (const e of entries.filter((x) => !x.startsWith(".")).sort(byteOrder)) {
    const cls = domainViewEntry(name, e);
    const at = `INVALID ${name}: projects/${b8(e)}`;
    if (cls === "not-symlink") out(`${at} is not a symlink - a domain view LINKS the fleet clones, it never holds a copy\n`);
    else if (cls === "dangling") out(`${at} dangles - it resolves to nothing\n`);
    else if (cls.startsWith("outside"))
      out(`${at} resolves OUTSIDE the fleet clones (${b8(cls.replace(/^outside /, ""))}) - a view may only select from the fleet projects dir\n`);
    else if (cls.startsWith("mismatch"))
      out(`${at} resolves to ${b8(cls.replace(/^mismatch /, ""))}, not to its OWN clone - a view entry must name the project it links, or it authorizes work on a repository the domain never selected\n`);
    else if (cls !== "ok") out(`${at} - unrecognised view state "${b8(cls)}"\n`);
    if (cls !== "ok") {
      rc = 1;
      continue;
    }
    if (!e.endsWith(".yaml") && !existsSync(`${pkg}/projects/${e}.yaml`))
      out(`WARN ${name}: projects/${b8(e)} has no .yaml sibling - a project with no pipeline config is a supported direct-pr case, so this is not a refusal\n`);
  }

  // The detail file is prose, never a guard - but its `## <project>` headings
  // are machine-read, giving BOTH divergence directions, and a fleet
  // description or a mode token copied in is the drift it must not carry.
  if (!isFile(`${pkg}/records/projects.md`)) return rc;
  let detail = "";
  try {
    detail = readFileSync(`${pkg}/records/projects.md`, "latin1");
  } catch {}
  const freg = `${softSubdir("records", true)}/projects.md`;
  if (isFile(freg)) {
    let fleet: string[] = [];
    try {
      fleet = readFileSync(freg, "latin1").split("\n").slice(0, -1);
    } catch {}
    for (const fline of fleet) {
      if (!fline.startsWith("- ")) continue;
      const fname = fline.slice(2).split(" ", 1)[0]!;
      const frest = fline.startsWith(`- ${fname} `) ? fline.slice(fname.length + 3) : fline;
      let fdesc: string;
      if (frest.startsWith("[") && frest.includes("] - ")) fdesc = frest.slice(frest.indexOf("] - ") + 4);
      else if (frest.startsWith("- ")) fdesc = frest.slice(2);
      else continue;
      fdesc = fdesc.replace(/ *\(added [^)]*\)$/, "");
      if (fdesc.length >= 12 && detail.includes(fdesc))
        out(`WARN ${name}: records/projects.md repeats the FLEET description of ${fname} verbatim - the description resolves from records/projects.md alone, and a copy here is the drift this file exists to avoid\n`);
    }
  }
  if (/\[(mode|crew-ship|direct-pr|local-only|feature-pr)\]/.test(detail))
    out(`WARN ${name}: records/projects.md carries a delivery-mode token - delivery mode is chosen per task on the backlog row, never a registry property, and a copy here is exactly the drift this file was designed not to have\n`);
  const sorted = (l: string[]): string[] => l.sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
  const links = sorted(viewNames(name).map(b8).join("\n").split("\n"));
  const headings = sorted(records(detail).filter((r) => r.startsWith("## ")).map((r) => r.slice(3)));
  for (const l of words(links.join("\n")))
    if (!headings.includes(l))
      out(`WARN ${name}: projects/${l} is in the view but has no "## ${l}" heading in records/projects.md - the detail prose has lagged the view\n`);
  for (const h of words(headings.join("\n")))
    if (!links.includes(h))
      out(`WARN ${name}: records/projects.md documents "## ${h}" but the view does not link it - the detail prose names a project this domain cannot work\n`);
  return rc;
}

function cmdValidate(): number {
  const reg = domainRegistry();
  if (!isFile(reg)) return 0;
  let rc = 0;
  const recs = subst(Buffer.from(parse(domainParse(reg)).recs.map((f) => `${f.join(US)}\n`).join(""), "latin1"));
  for (const line of recs.split("\n")) {
    const [cls, id, , , reason] = readUS(line, 5);
    if (cls !== "INVALID") continue;
    out(`INVALID ${id}: ${reason}\n`);
    rc = 1;
  }
  for (const n of domainNames()) if (validateProjects(n) !== 0) rc = 1;
  const vb = `${softSubdir("records", true)}/backlog.md`;
  if (!isFile(vb)) return rc;
  const text = readLedger(vb);
  if (text === null) {
    out(`INVALID ledger: cannot read ${b8(vb)}\n`);
    return 2;
  }
  const ledger = rows(text);
  const dom = new Map<string, string>();
  for (const { o } of ledger) if (o && o.domain !== "") dom.set(o.id, o.domain);
  let done = false;
  for (const { rec, o } of ledger) {
    if (rec.startsWith("## ")) done = rec.startsWith("## Done");
    if (!o) continue;
    if (o.domain_malformed === "1") {
      out(`INVALID token: ${o.id} carries a domain:-shaped run off its grammar position (backtick-quote a mention, or re-stamp with assign)\n`);
      rc = 1;
    }
    if (!done && o.domain !== "" && !domainNames().includes(o.domain)) {
      out(`INVALID token: orphan domain token ${o.domain} ${o.id}\n`);
      rc = 1;
    }
    const ed = dom.get(o.epic) ?? "";
    if (o.domain !== "" && o.epic !== "" && ed !== "" && ed !== o.domain) {
      out(`INVALID token: story ${o.id} carries domain:${o.domain} but its epic ${o.epic} carries domain:${ed} - one family, one domain\n`);
      rc = 1;
    }
  }
  return rc;
}

const { args } = enterCaller(process.argv.slice(2));
const verb = args[0] ?? "";
const rest = args.slice(1);
const rc =
  verb === "new"
    ? cmdNew(rest)
    : verb === "assign"
      ? cmdAssign(rest)
      : verb === "unassign"
        ? cmdUnassign(rest)
        : verb === "queue"
          ? cmdQueue(rest)
          : verb === "qa-repo"
            ? cmdQaRepo(rest)
            : verb === "retire"
              ? cmdRetire(rest)
              : verb === "list"
                ? cmdList()
                : verb === "validate"
                  ? cmdValidate()
                  : die("usage: ac-domain.sh <new|assign|unassign|queue|qa-repo|retire|list|validate>");
process.exit(rc);
