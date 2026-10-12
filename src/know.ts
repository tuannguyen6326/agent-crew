// know.ts - the per-project REPO-KNOWLEDGE record: what earlier families
// verified about a codebase, durable in the FLEET HOME and re-checkable. The
// entry is bin/ac-know.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-know.sh as the
// oracle the differential leg of tests/sh/ac-know.test.sh holds this module
// to.
//
// Usage:
//   ac-know.sh add    --home <abs> --repo <dir> --family <fam>
//                     (--src-file <path>:<line> | --src-cmd <command>)
//                     [--at <ref>] --fact <text>
//                     [--new | --supersede <text-quoted-from-the-entry>]
//   ac-know.sh retire --home <abs> --repo <dir> --family <fam>
//                     (--src-file <path>:<line> | --src-cmd <command>) [--at <ref>]
//                     --quote <text-quoted-from-the-entry> [--by <family>] --why <text>
//   ac-know.sh cite   --home <abs> --repo <dir>
//                     --quote <text-quoted-from-the-entry> [--by <family>]
//   ac-know.sh recall <question words>... --home <abs> --repo <dir>
//                     [--max <n>] [--bytes <n>] [-- <question words>...]
//                     (a quoted multi-word question may start with -; a
//                     one-word question that does goes after --)
//   ac-know.sh verify --home <abs> --repo <dir>   (leaves a digest stamp)
//   ac-know.sh scope-proposal --home <abs> --repo <dir> --family <fam>
//                     (--src-file <path>:<line> | --src-cmd <command>) [--at <ref>]
//                     ( --scope <name> --apps <a>,<b> [--replace]
//                     | --retire --scope <name> --why <text> ) [--id <id>]
//   ac-know.sh scope-install <id> --home <abs> --repo <dir>   (CHIEF)
//
// No verb, `-h`, `--help`, '' - and every verb whose --repo is missing or
// empty - print the block above (from `Usage:` to the line holding only the
// comment mark, that mark and one space stripped) on stdout, exit 1.
//
// WHY IT EXISTS: a task's repo knowledge dies with its report.md, so the next
// family re-derives it - or contradicts it. This record is the durable place
// for it, and every entry carries PROVENANCE and a FRESHNESS MARKER because a
// stale fact stated confidently is worse than no fact.
//
// THE RECORD: <home>/records/repo-knowledge/<name>.md, <name> the basename of
// the MAIN repo dir git's common dir names (knowledgeFile, src/lib.ts, the
// twin of ac_knowledge_file, which owns the key argument; a linked worktree
// answers its main repo). One entry, one PHYSICAL line:
//
//   - <type> <subject> | src: <tagged provenance> | at: <sha> <date> [| heat: <n>] | by: <family>
//
// Every `- ` line above the first line starting `## Superseded` is LIVE;
// every `- ` line after it is history - never edited, never counted as a live
// match. add/retire/cite search it, but only to name a phrase that lives only
// there, or one that also lives there beside a live match; its content is
// never trusted or written back. `add`'s near-duplicate guard searches it on
// its own terms: a plain `add` whose subject near-duplicates a SUPERSEDED
// entry WARNS (naming the entry and its live successor when the record
// affords one) instead of refusing, because the same shape is the sanctioned
// retire-then-add correction, which always restates its subject. Every write
// regenerates the file whole: `# Repo knowledge: <name>`, a blank, the
// boilerplate comment, a blank, the live lines, a blank, `## Superseded`, a
// blank, the second comment, a blank, the superseded lines. Its comments name
// bin/ac-know.sh - the path every caller keeps - and any line that is no
// `- ` entry (a hand note) is dropped by the next write. Types:
//   fact <free text>            human-consumed repo knowledge; any crewmate
//                               may write one, directly, through `add --fact`
//                               (retire's receipt is `fact retired: <why>`).
//   scope <name> = <app>, <app> the CLOSED LIST governing qa profile
//                               resolution. `add` has NO --scope path at all.
// The readers' grammar: the SUBJECT is the text after `- fact ` up to the
// FIRST ` | src:`; the author family follows the LAST `| by: `; heat is what
// follows the LAST ` | heat: ` before the LAST ` | by: `; verify takes the
// provenance between the first `| src: ` and the next ` | at: `, and `at` as
// the first word after the first `| at: `.
//
// RETIRING A FACT: `add` only appends - there is no in-place edit verb, and
// never will be. Correcting a false fact is `retire` then `add` (or `add
// --supersede`, both in one write): a reader sees NO claim on the subject
// between two writes, which is safe (a STALE claim is not). `retire` is
// crewmate-tier, same as `add` - NOT a draft/chief-install two-step like the
// scope map, because a false fact staying live while a proposal waits is the
// defect this verb exists to close. It addresses its target by a PHRASE
// QUOTED from the entry's own subject, optionally narrowed by the entry's own
// `by:` family - NEVER by line number or position: every move renumbers every
// line below it. For the same reason `add --fact` refuses a citation that
// points AT THIS RECORD by physical line (`repo-knowledge:<n>`, or a
// `.../repo-knowledge/<name>.md:<n>` pointer); an ordinary code citation such
// as `bin/ac-tree.sh:405` is the record's normal provenance shape.
//
// HOW THE PATH TRAVELS: not the environment. Crewmate panes carry no AC_HOME
// (src/pane-agent.ts states the contract), so the actor that HAS AC_HOME
// bakes the whole command line into the brief (src/brief.ts) and the
// crewmate runs it VERBATIM. The ladder is ac_home_resolve's (homeResolve,
// src/lib.ts), shared with ac-qa.sh: --home > $AC_HOME > nothing. There is NO
// third rung: the distro checkout is no fleet home, a record written into it
// lands where no fleet reads it, and in a leased worktree it is discarded on
// return - so an unresolved ladder REFUSES, every verb alike. The resolved
// home is exported to every child, one decision per process.
//
// THE FALSE-FRESH CLASS (authoritative - every other mention points HERE): an
// entry is a false-FRESH generator whenever THE RECORDED `at` IS NOT THE STATE
// THE AUTHOR OBSERVED. Doors, and how each is closed:
//   A  dirty worktree      the evidence was never in any commit
//   B  clean tree, wrong   `--at` names a commit the tree does not match
//   G  moving symbolic ref `--at main` binds today and re-points tomorrow
//   E  abbreviated sha     a rendering, not an identity
//   C  what the author LOOKED at - observe dirty, `git stash`, then add:
//      the binding passes honestly and the entry records content that no
//      longer exists. UNCLOSABLE; no mechanism can know what a human read.
//      `verify` re-checking rather than trusting the write is the compensating
//      control, which is why it is a verb and not an afterthought.
//   U  UNTRACKED files under a `cmd:` provenance - ACCEPTED AND OPEN, not
//      closed. `git diff` does not report untracked paths, so a command whose
//      output counted one binds to a commit that never held it, and two
//      contradictory facts can bind to the same sha. An argued residual of the
//      approved design: untracked build artifacts are ubiquitous in a crew
//      worktree and widening the check would refuse nearly every real
//      invocation. Named here because this block is the single authority on
//      the class. Do NOT close it here.
//   N  no worktree copy, AND <at> is not in this branch's own history - `file:`
//      only, an app tree that lives ONLY on an integration branch this clone
//      never checked out. `git diff <at> -- <path>` against a path absent from
//      disk always reports "differs", a FALSE positive for A/B. CLOSED for
//      exactly this door: the worktree diff is skipped, trusting the cat-file
//      proof that the blob is real at <at>, ONLY when <at> is not an ancestor
//      of HEAD - when it is, the path once existed on THIS branch and was
//      deleted since, which is real staleness and stays refused. This extends
//      door C's trust boundary one case further, not past it: the text of a
//      --fact was never verified against cited content.
// B, G and E collapse into ONE rule: resolve `--at` to a full 40-char sha and
// bind with `git diff --quiet <at>` against the WORKTREE - per-path for
// `file:`, NO pathspec for `cmd:` (a command's output can depend on any part
// of the tree). Never `git status`: it is HEAD-relative and proves nothing
// about <at>. Exit-status discipline is load-bearing - 0 proceeds, 1 differs,
// ANYTHING ABOVE 1 IS AN ERROR AND REFUSES, so an unreadable tree fails closed
// instead of reading as clean.
//
// ONE ENTRY, ONE LINE - MECHANICALLY. Every free-form field is refused when
// it holds LF or CR or `|`, and --family must match [a-z0-9-]: one newline in
// --fact would compose a SECOND physical line forging a `scope` entry under
// another family's name. REJECT, never escape - an unescaping step in every
// reader is the same forgery with more code. The boundary, honestly: this
// binds what the WRITER produces from the fields it checks (--apps is not one
// - W18 below); a human hand-editing the record can write anything, which is
// why the record lives in the fleet home rather than the repo.
//
// Serialization: add, retire, cite and scope-install read-modify-write the
// whole record under <rec>.lock (the dir + pid protocol of ac_lock_acquire,
// lockAcquire in src/lib.ts, so bash and TypeScript writers exclude each
// other; 30 waits of a spawned `sleep 1`; a dead holder's lock is reclaimed,
// a pid-less one after AC_LOCK_STALE_GRACE seconds) and land it through an
// exclusive <rec>.tmp.<pid> renamed over it, the record's mode kept. recall,
// verify and scope-proposal take no lock (the install's base hash closes the
// draft race). The lock's own non-atomic stale reclaim is inherited.
//
// ESCAPE HATCH (captain 2026-10-09). This writer is fleet memory: every add,
// retire and cite rewrites the whole record, so a WRONG write loses verified
// knowledge (the slice still lands without it: teardown only READS the
// record, and `--no-fact '<why>'` waives the loop). If a landed change breaks
// this module, run the frozen original from a scratch bin/ at a physical path:
//   o=$(cd "$(mktemp -d)" && pwd -P); mkdir "$o/bin"; cp bin/*.sh "$o/bin/"
//   ln -s "$PWD/src" "$o/src"; ln -s "$PWD/dashboard" "$o/dashboard"
//   cp tests/fixtures/ac-know.sh "$o/bin/ac-know.sh"
//   cp tests/fixtures/ac-qa-lib.sh tests/fixtures/ac-pipeline-lib.sh "$o/bin/"
// then "$o/bin/ac-know.sh" <verb> --home <home> --repo <repo> ... - the record
// path descends from --home alone, so nothing needs rewriting; only
// scope-proposal's printed install line names "$o/bin" (install through the
// copy, or edit that path). The captain's revert of the land is the last
// resort.
//
// --- the run, in order (AUTHORITATIVE) ---
// stdin is never read (git children inherit it). Every refusal is one
// `ERROR: <text>` on stderr, exit 1; `reject` texts read `entry rejected:
// <text>`. git must be on PATH before the verb is read (`ERROR: required tool
// not found: git`); an unknown verb is `ERROR: unknown verb: <w>`.
// FLAGS, every verb, before anything else: a value flag takes the next word
// whatever it is, last wins, and as the last word is `ERROR: <flag> needs a
// value`; any other word is `ERROR: unknown flag: <w>`, spelled `... (ac-know.sh
// add writes facts; the scope map is not writable here)` in add and `... (a
// question word that starts with - goes after --)` in recall.
// SETTLE, every verb: --repo as given (relative to the caller's cwd): empty is
// the Usage block; `ERROR: --repo is not a directory: <r>`; `ERROR: --repo is
// not a git repo: <r>`. Then the home: --home not `/`-led is `ERROR: --home
// must be an ABSOLUTE path outside the project repo (got '<h>')`; one cd
// cannot enter is `ERROR: --home is not a readable directory: <h>`; its
// physical path inside the repo's MAIN root (else the repo's own physical
// dir) is `ERROR: --home must be an ABSOLUTE path outside the project repo:
// <h> resolves to <real>, inside <root>`. Else AC_HOME, physical, relative to
// the caller's cwd and unguarded (W16); one cd cannot enter is `ERROR:
// AC_HOME is not a readable directory: <h>`. Neither is `ERROR: no fleet home:
// pass --home <abs>, or set AC_HOME. This checkout is NOT one - a record
// written here lands where no fleet reads it, and in a leased worktree it is
// discarded on return. A crewmate pane never carries AC_HOME by design, which
// is exactly why bin/ac-brief.sh bakes a --home-carrying command line into
// every brief (ac-brief.sh knowledge()) - run the line the brief gave you.`
// Every path printed is physical. records/ is minted where the record is
// resolved; `ERROR: cannot resolve the project name for <repo>` when git
// cannot name it.
// PROVENANCE (add, retire, scope-proposal, after their own fields): `no
// attribution - pass --family <family>`; `--family must match [a-z0-9-] (got
// '<f>')`; `an entry has ONE provenance - pass --src-file or --src-cmd, not
// both`; `no provenance - pass --src-file <path>:<line> or --src-cmd
// <command>`; `--at '<ref>' does not resolve to a commit in this repo`
// (`rev-parse --verify --quiet <ref>^{commit}`, default HEAD, the full sha
// recorded); the date is a spawned `date -u +%F`. --src-file is single-line
// and `|`-free, then `--src-file wants <path>:<line> (got '<v>')` (no `:` and
// digit, or a last field not all digits); `--src-file names no path (got
// '<v>') - it wants <path>:<line>`; `--src-file must be repo-relative (no
// absolute path, no ..): <path>` (textual: `/`-led or holding `..`); `<path>
// does not exist at <sha12> - the citation cannot be followed` (cat-file -t
// <sha>:<path>, root-relative); `<path> is a <kind> at <sha12>, not a file - a
// <path>:<line> citation into it is not followable by any reader` (a symlink
// is a blob and stays legal); `<path> has <n> lines at <sha12>; the citation
// names line <l>` (line past the blob's lines, or past int64). --src-cmd is
// single-line and `|`-free. THE BINDING, then: `file:` skips door N as above,
// else `git -C <repo> diff --quiet <sha> -- <path>` (both <repo>/<path> and
// the pathspec read relative to --repo - W5): above 1 is `cannot compare
// <path> against <sha> (git diff exited <rc>) - failing closed; an unreadable
// tree is not evidence of an unchanged one`, 1 is `<path> differs between the
// worktree and <sha12> - the fact you observed is not what that ref holds.
// Commit the file first, or pass --at <ref> that contains what you saw`;
// `cmd:` diffs the whole tree: `cannot compare the tracked tree against <sha>
// (git diff exited <rc>) - failing closed; ...` / `the tracked tree differs
// from <sha>, so a cmd: provenance cannot be bound to it. Check out that
// commit with a clean tree, or cite the specific file with --src-file`. Every
// one of these is `entry rejected: `-prefixed; git's own stderr passes.
// ADD: `no subject - pass --fact <text>`; --fact single-line and `|`-free;
// `--fact cites the repo-knowledge record by line number, which has no stable
// identity to point at (quote the entry's own text instead): <fact>`;
// provenance; the lock (repo-knowledge/ minted; `ERROR: ac-know: lock timeout
// for <name>`). --supersede <q> (it wins over --new): the live `- fact `
// entries whose subject CONTAINS q; none live but some superseded is
// `--supersede '<q>' matches no LIVE fact, but matches a SUPERSEDED entry - a
// superseded entry cannot be corrected again; find the live entry that
// replaced it and quote that instead (nothing written):` and the lines, none
// at all `--supersede matched nothing: no live fact contains '<q>' (nothing
// written)`; several `--supersede '<q>' is ambiguous - <n> live entries match,
// quote a longer phrase (nothing written):` and the lines; one live AND a
// superseded hit `--supersede '<q>' matches one live entry AND a SUPERSEDED
// entry - ambiguous which the caller means; quote a longer, disambiguating
// phrase (nothing written):`, `  live: <line>` and the superseded lines; else
// the target MOVES byte-identical under Superseded (every live line equal to
// it leaves). Plain (no --new): THE NEAR-DUPLICATE GUARD - tokens are the
// ASCII-lowercased runs of [a-z0-9_./-] at least 5 long, deduped; an entry
// whose subject shares at least 4 of the new fact's AND at least 60% of the
// smaller set is a candidate, most shared first, ties by the whole
// `<shared>TAB<line>` row in DESCENDING byte order - `this subject already has
// a live entry (nothing written) - two claims about one subject is the defect
// this guard exists to stop:`, the lines, a blank, `  correct the existing
// one:  --supersede '<phrase quoted from it>'   (retires it and adds yours in
// one write)` and `  genuinely distinct:        --new
// (declares it, and the guard stands aside)` (column-padded); else the same
// measure over Superseded warns on stderr `add: warning - this subject
// near-duplicates a SUPERSEDED entry; the fleet already judged this wording
// wrong or stale once:`, each line, and - when that retired subject
// near-duplicates a live entry (the new one is not live yet) - `  replaced
// by:` and those lines indented four spaces; the write proceeds. --new skips
// the guard. Append, write, release; stdout `recorded in <rec>`. Every
// refusal past the lock releases it first.
// RETIRE: `no target - pass --quote '<phrase from the entry's own text>'`; `a
// retirement records WHY - pass --why <text>`; --why single-line and
// `|`-free; provenance; the lock; candidates narrowed to `--by` (the ENTRY's
// author family). None live: a superseded hit (narrowed alike) is `retire:
// '<q>'[ by family <by>] matches no LIVE fact, but matches a SUPERSEDED entry
// - a superseded entry cannot be retired again; find the live entry that
// replaced it and quote that instead:` and the lines; a --by that emptied real
// matches is `retire: '<q>' matches <n> live entr<y|ies>, none by family <by>
// - --by is the entry's author family, and these wrote the matches: <f> <f>
// (narrow with one of them, or a longer quote)` (the families unique, in byte
// order, each followed by a space); else `retire: nothing matched '<q>'[ by
// family <by>] - no live fact entry contains that phrase`. Several: `retire:
// '<q>' is ambiguous - <n> live entries match, narrow with --by <family>:`
// and the lines (byte-identical twins can never be narrowed - W12). One live
// AND a superseded hit: `retire: '<q>'[ by family <by>] matches one live entry
// AND a SUPERSEDED entry - ambiguous which the caller means; quote a longer,
// disambiguating phrase (nothing written):`, `  live: <line>`, the lines.
// Else the MOVE, then `- fact retired: <why> | src: <prov> | at: <sha> <date>
// | by: <family>` appended; stdout `retired from <rec>`.
// CITE (no provenance - a read receipt): `no target - pass --quote '<phrase
// from the entry own text>'`; `ERROR: cite: no repo-knowledge record yet:
// <rec>`; the lock (nothing minted); retire's zero/ambiguous refusals with
// the `cite:` prefix (the superseded-only one ends `- find the live entry that
// replaced it and quote that instead:`). One live AND a superseded hit WARNS
// on stderr `cite: warning - <q> also matches a SUPERSEDED entry; heat is
// bumped on the live match only:` and the lines, and goes on. No ` | by: ` in
// the target is `cite: matched entry carries no '| by:' field - not a grammar
// line this verb can bump: <line>`; a heat that is not all digits is `cite:
// malformed heat field on the matched entry (got: '| heat: <h>'): <line>`.
// The new line is `<before the last heat> | heat: <h+1> | by: <family>` - the
// sum is bash's `$((h + 1))` (W13: 010 is octal, 08 ends the run 1 with the
// lock held, int64 wraps) - or `<before the last by> | heat: 1 | by:
// <family>`; it replaces the FIRST equal live line where it stands. Stdout
// the new line, then `cited in <rec>`.
// RECALL: the words and the flags in any order; `--` ends the flags (the rest
// joined by spaces); a dash word holding a [:space:] of the caller's locale is
// a question word. `entry rejected: no question - pass the order's
// subject/mechanism/terms`; `--max must be a count (got: '<v>')` and
// `--bytes must be a byte count (got: '<v>')` (digits only - W14); settle.
// TERMS are the ASCII-lowercased question's runs of [a-z0-9_./-] at least 4
// long, deduped; the FLOOR is int(t * 0.6 + 0.999), at least 2, but 1 when t
// is 0 or 1 (a question with no 4-character term needs 1 and can never hit);
// an entry's HITS count the terms that are substrings of its lowercased text.
// Ranking inside a tier: hits, then heat (sort -n's reading of the field,
// descending), then the whole row in BYTE order. TIER 1 - SCENES (L2, a whole
// topic in one read): each regular records/scenes/*.md, its heat the
// `heat=` words of line 2 joined by LF (a second one breaks the row in two, as
// the original's did), its summary line 3 past `summary: `, hits over the
// whole file; `== scenes (L2 - a topic restored in one read) ==`, per scene
// `  <slug>  (hits <h>, heat <heat or 0>)`, `    <summary>`, `    open:
// ac-scene.sh show <slug> --cite` while fewer than --max were printed, then a
// blank. An unreadable scene ends the run 1. TIER 2 - FACTS (L1): the live
// `- fact ` lines (never scope), hits over the whole line, heat parsed as THE
// RECORD says (anything but digits reads 0); `== facts (L1 -
// repo-knowledge) ==`, and before each the cut when --max are printed or the
// budget is spent, `  (hits <h>, heat <heat>) <line>` and `    cite:
// ac-know.sh cite --repo <clone> --quote '<the subject's first 60 characters,
// each ' as '\''>'` (W4: no bin path, no --home), then a blank. The --bytes
// budget counts each offered entry line's own characters under a UTF-8 locale
// and its bytes under any other, and so does the quote's 60 (LC_ALL, else
// LC_CTYPE, else LANG - W3, reproduced). Headers print even when --max 0 lets
// nothing through. Tail: nothing printed and nothing cut is `no hit in any
// layer for: <query> (needed <floor> of its distinctive terms)` and `(state
// the absence explicitly in the brief - intake-triage skill)`; else `-- <s>
// scene(s), <f> fact(s) shown` plus `; TRUNCATED at --max <m> / --bytes <b>
// (<every fact hit> fact hits total) --` or ` (all hits) --`, then `recall
// PRINTS; it never cites - bumping heat on what you only skimmed` and `would
// corrupt the ranking. Cite the ONE you use, with the line above it.` Exit 0;
// no lock. It PRINTS and never cites: bumping heat on what a caller merely
// skimmed would corrupt the signal it ranks by. There is no embedding here and
// there should not be - at this scale substring hits ARE the full-text tier.
// VERIFY: no record is stdout `no repo-knowledge record yet: <rec>`, exit 0,
// no stamp. Per LIVE `- ` line in record order: `cmd:` is `MANUAL  <line>
// (re-run: <cmd>)` (nothing to diff, so never FRESH); an `at` that does not
// resolve `UNVERIFIABLE <line>  (<at12> does not resolve in this clone)`; a
// path absent from <repo>/<path> is `SUSPECT <line>  (<path> no longer
// exists)` when <at> is an ancestor of HEAD, else `UNVERIFIABLE <line>
// (<path> has no worktree copy in this clone to compare against <at12>)`;
// then <at> against the WORKTREE (never <at>..HEAD, which sees neither index
// nor worktree): `FRESH   <line>`, `SUSPECT <line>  (<path> changed since
// <at12>)`, else `UNVERIFIABLE <line>  (cannot compare <path> against
// <at12>)`. <at12> is the first 12 characters of the locale. Then the stamp
// state/.know-verify-<name>.meta (dot-prefixed, so no phantom crewmate):
// `record=<file>`, `fresh=`, `suspect=`, `unverifiable=`, `manual=`, `head=<git
// rev-parse HEAD's stdout, and `-` when it failed>`, `ran=<iso>`, through an
// exclusive temp. Exit 0, an unreadable record included (W9). No lock.
// SCOPE-PROPOSAL (the map is a CLOSED list a crewmate must not write: the
// agent DRAFTS, a chief INSTALLS, the captain vetoes by restoring `.prev` -
// chief-tier by law, not mechanics): `no scope named - pass --scope <name>`;
// `<s> is not addressable as a yaml path segment (--scope must match
// [A-Za-z0-9_-])`; --retire: `a retirement records WHY - pass --why <text>`,
// --why single-line and `|`-free, `--retire removes a scope from the list; it
// takes no --apps`; else spaces are dropped from --apps, `a scope with no
// members - pass --apps <app>,<app>`, and each comma field of its FIRST line
// (a trailing empty field dropped - W6) must match: `<a> is not addressable
// as a yaml path segment (--apps must match [A-Za-z0-9_-])` - a first line
// with no field at all ends the run 1; provenance; the id: --id or `<date
// +%Y%m%d-%H%M%S>-<pid>`, `ERROR: invalid proposal id: <id>` outside
// [A-Za-z0-9._-]; <repo>/.crew/knowledge-proposals/ minted and
// <id>/ made, else `ERROR: scope-proposal: id already exists: <id>`.
// base.md is the record as it stands (cp; empty when absent; no lock); the
// live `- scope ` entries whose parsed name equals <s>: --retire with none is
// `no live entry for scope <s> - nothing to retire`, some without --replace
// `scope <s> is already live - pass --replace to supersede it:` and the lines
// (both remove <id>/); they MOVE under Superseded; each app also live in
// another scope is a stderr `note: <app> is also live in scope <other>`; the
// entry `- scope <s> = <apps, comma-space joined> | ...` or `- fact retired
// scope <s>: <why> | ...` is appended; proposed.md is the record so rendered;
// base.sha256 and project written; `diff -u --label current --label proposed`
// into proposal.patch (identical is <id>/ removed and `the draft is
// identical to the installed record - nothing to propose`). Stdout
// `proposal_id: <id>`, `proposal written:`, `  <dir>/proposal.patch`, `
// <dir>/proposed.md`, `target: <rec>`, `base_sha256: <sha>`, `install (CHIEF,
// after review - never the drafting agent): <root>/bin/ac-know.sh
// scope-install <id> --home <home> --repo <repo as given>` (W15). The record
// is never written.
// SCOPE-INSTALL: the id is the FIRST word (flags first read the home as an
// unknown flag - W15); `ERROR: usage: ac-know.sh scope-install <proposal-id>
// --home <abs> --repo <dir>`; `ERROR: invalid proposal id: <id>`; settle;
// `scope-install: no staged proposal <id> at <dir>`; `scope-install: proposal
// <id> does not target project <name>`; `scope-install: proposal <id> has no
// base hash`; the lock (`scope-install: lock timeout for <name>`); the record
// as it stands hashed against base.sha256: `scope-install: proposal <id>
// conflicts with a newer installed record (base=<b> current=<c>); re-draft
// it`; a record that differs from proposed.md is cp'd to <rec>.prev; proposed.md
// lands through an exclusive temp, the record's mode kept; installed.sha256
// written; stdout `installed proposal <id>: <proposed.md> -> <rec>[ (previous
// kept at <rec>.prev)]` and `receipt (post to the family room):
// KNOWLEDGE-INSTALLED: <rec> sha256=<sha> proposal=<id> - drafted by the task
// agent, reviewed + installed by the chief; captain veto: restore <prev |
// (no previous record)>`.
//
// AT PARITY, BY RULING (captain 2026-10-09, each pinned in the leg): W4 (the
// hand-overs name no bin, a `<clone>` placeholder, no --home), W5 (a
// subdirectory --repo binds and grades relative to itself), W6 (a trailing
// comma in --apps is written, and the bash map reader then refuses the whole
// map), W9 (an unreadable record verifies nothing and stamps zeros; an unborn
// repo's head is `HEAD` and `-` on two lines), W10 (line 0 and `01` pass),
// W12 (byte-identical twins are unaddressable), W13, W14 (--max or --bytes
// past int64 pass the digits check: --max cuts every scene and no fact),
// W15, W16 (a --home inside a linked worktree outside the main dir, and any
// AC_HOME, pass). Reproduced too: W18 - a newline in --apps past its first
// line is written as a second physical line.
//
// DIVERGENCES from the original (the leg names each one a row can show):
// - W1 (FAIL-PATH): the record and the scenes are read as bytes, so a byte
//   that is no UTF-8 under a UTF-8 locale is processed like any other, where
//   the original's awk aborted (add/retire/cite exit 2 with the lock held,
//   recall exit 2 printing nothing, verify grading only what came before it).
// - W2 (captain 2026-10-09): every tie - recall's tiers, the near-duplicate
//   list, the families of a --by mismatch - is broken in BYTE order, where the
//   original's sort collated under the caller's locale (a different shown set
//   at the --max cut under en_US.UTF-8).
// - TOLOWER: terms and tokens fold ASCII only; under a UTF-8 locale the
//   original's awk also folded the few capitals whose lowercase is ASCII
//   (U+212A KELVIN SIGN, U+0130).
// - W11 (captain 2026-10-09): --family, --scope, --apps and --id are read per
//   their text under any locale, where bash's brackets under a UTF-8 locale
//   also took `Bad` or `café`; a dash-led family still passes.
// - BYTES: argv arrives decoded, so a --fact byte that is no UTF-8 is written
//   as U+FFFD; a name or path git or the filesystem hands back is decoded
//   alike.
// - EXCLUSIVE TEMPS (W7, W8): the record and the stamp land through a temp
//   created exclusively and given the file's mode, so a link planted at the
//   temp is never written through (the original wrote the record into its
//   target and left the record a link), and scope-install keeps the record's
//   mode where the original left it 0600. Nothing goes to TMPDIR at all, so a
//   run that ends early leaves no temp there.
// - SHELL-OWN and TOOL-OWN STDERR are not reproduced, their statuses kept:
//   bash's arithmetic (`08: value too great for base`), `[:` (`integer
//   expression expected`), `unbound variable` (an --apps with no first-line
//   field), awk's `can't open file` and `towc`, sed's unreadable scene; cd's
//   own line for an AC_HOME it cannot enter (the HOME RESOLUTION ruling
//   names the variable instead), and a relative AC_HOME under an exported
//   CDPATH stays the home, where cd's echo doubled it.
// - LOCK GRACE: a pid-less lock's age is read from the clock, where the
//   original spawned `date +%s` (so a stubbed date ages it differently).
// - BUN: without bun the shim refuses `ERROR: required tool not found: bun`.
// - A caller whose cwd has no name resolves no relative --repo or AC_HOME.
//
// CALLERS: nothing executes it from code. Crewmates run the recall, verify
// and add lines src/brief.ts bakes into every brief; chiefs, roomchiefs and
// solo sessions run recall and cite at intake and add at landing (the
// intake-triage, task-lifecycle and solo-session skills); the KNOWLEDGE-GAP
// and `repo fact:` hints (knowledgeWarn, soloLandingCheck in src/lib.ts) and
// the qa remedies name it. What it WRITES is read by teardown's knowledge loop
// and knowledgeWarn (a live line ending `| by: <family>`), the qa gate and
// ac-qa.sh (the scope map, knowledgeScopes / ac_knowledge_scopes), session
// start (the stamp and the live count), src/brain.ts and the dashboard.

import { closeSync, fchmodSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from "node:fs";
import {
  STARTED_BIN,
  arithValue,
  die,
  enterCaller,
  exclusiveTemp,
  homeResolve,
  iso,
  knowledgeFile,
  lockAcquire,
  lockRelease,
  projectConfigName,
  require,
  shellLength,
  shellPrefix,
  shellSpaceClass,
  shellStatus,
  spawnShellSync,
  tabFields,
  testInt,
  writeAll,
} from "./lib.ts";

// Byte strings (latin1) carry what the bash held as bytes; argv and the lib's
// paths are UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array | string): string => (typeof b === "string" ? b : Buffer.from(b).toString("latin1")).replace(/\0/g, "").replace(/\n+$/, "");
const lines = (a: string[]): string => a.map((l) => `${l}\n`).join("");
const byteCmp = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

function out(s: string): void {
  const b = fsPath(s);
  try {
    for (let off = 0; off < b.length; ) off += writeSync(1, b, off, b.length - off);
  } catch (e) {
    if ((e as { code?: string }).code === "EPIPE") process.exit(141);
    throw e;
  }
}

const warnOut = (s: string): void => {
  writeSync(2, fsPath(s));
};

function fail(msg: string): never {
  die(fsPath(msg));
}

function reject(msg: string): never {
  fail(`entry rejected: ${msg}`);
}

type Io = { out?: "inherit" | "pipe" | "ignore"; err?: "inherit" | "pipe" | "ignore" };

function run(cmd: string[], io: Io = {}): { status: number; out: Buffer } {
  let r: ReturnType<typeof spawnShellSync> | null = null;
  try {
    r = spawnShellSync(cmd.map(u8), { stdin: "inherit", stdout: io.out ?? "inherit", stderr: io.err ?? "inherit" });
  } catch {}
  return { status: shellStatus(r), out: r && io.out === "pipe" ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// `x="$(cmd)"` where errexit was awake: the command's failure ends the run
// with its status.
function capture(cmd: string[]): string {
  const r = run(cmd, { out: "pipe" });
  if (r.status !== 0) process.exit(r.status);
  return subst(r.out);
}

function spawnOrExit(cmd: string[]): void {
  const r = run(cmd);
  if (r.status !== 0) process.exit(r.status);
}

const stat = (p: string): ReturnType<typeof statSync> | null => {
  try {
    return statSync(fsPath(p));
  } catch {
    return null;
  }
};
const isDir = (p: string): boolean => stat(p)?.isDirectory() ?? false;
const isFile = (p: string): boolean => stat(p)?.isFile() ?? false;
const dirOf = (p: string): string => p.slice(0, p.lastIndexOf("/"));

let atCaller = false;

function usage(): never {
  let o = "";
  let on = false;
  for (const l of readFileSync(import.meta.path, "latin1").split("\n")) {
    if (on) {
      o += `${l.replace(/^\/\/ ?/, "")}\n`;
      if (l === "//") on = false;
    } else if (l.startsWith("// Usage:")) {
      on = true;
      o += `${l.replace(/^\/\/ ?/, "")}\n`;
    }
  }
  out(o);
  process.exit(1);
}

// One loop per verb's flags: a value flag takes the next word whatever it
// is, a switch none, anything else is <unknown>'s refusal.
function flags(args: string[], values: string[], switches: string[], unknown: (a: string) => string): Record<string, string> {
  const v: Record<string, string> = {};
  for (let i = 0; i < args.length; ) {
    const a = args[i]!;
    if (values.includes(a)) {
      if (i + 1 >= args.length) fail(`${a} needs a value`);
      v[a] = args[i + 1]!;
      i += 2;
    } else if (switches.includes(a)) {
      v[a] = "1";
      i++;
    } else fail(unknown(a));
  }
  return v;
}

const plainUnknown = (a: string): string => `unknown flag: ${a}`;

function assertSingleLine(name: string, v: string): void {
  if (/[\n\r]/.test(v)) reject(`${name} must be a single line (no newline or carriage return)`);
  if (v.includes("|")) reject(`'|' is the field separator, so it cannot appear in ${name}`);
}

function settleRepo(repo: string): void {
  if (repo === "") usage();
  if ((!atCaller && !repo.startsWith("/")) || !isDir(repo)) fail(`--repo is not a directory: ${repo}`);
  if (run(["git", "-C", repo, "rev-parse", "--git-dir"], { out: "ignore", err: "ignore" }).status !== 0) fail(`--repo is not a git repo: ${repo}`);
}

const NO_FLEET_HOME =
  "no fleet home: pass --home <abs>, or set AC_HOME. This checkout is NOT one - a record written here lands where no fleet reads it, and in a leased worktree it is discarded on return. A crewmate pane never carries AC_HOME by design, which is exactly why bin/ac-brief.sh bakes a --home-carrying command line into every brief (ac-brief.sh knowledge()) - run the line the brief gave you.";

function settleHome(flag: string, repo: string): string {
  const home = homeResolve(u8(flag), u8(repo));
  if (home === "") fail(NO_FLEET_HOME);
  process.env.AC_HOME = home;
  return b8(home);
}

function settle(v: Record<string, string>): { repo: string; home: string } {
  const repo = v["--repo"] ?? "";
  settleRepo(repo);
  return { repo, home: settleHome(v["--home"] ?? "", repo) };
}

function recordOf(repo: string): { rec: string; name: string } {
  const rec = knowledgeFile(u8(repo));
  if (rec === null) fail(`cannot resolve the project name for ${repo}`);
  return { rec: b8(rec), name: b8(projectConfigName(u8(repo)) ?? "") };
}

// --- the record file ---

const BOILER_LIVE =
  "<!-- One entry per line. Grammar owner: bin/ac-know.sh. Write with `ac-know.sh add`; retire with `ac-know.sh retire`; record a read with `ac-know.sh cite` - it bumps the entry `heat:` usage counter in place, the one sanctioned in-place field. Never edit a line by hand; correct a fact by retire then add. -->";
const BOILER_SUPERSEDED =
  "<!-- Moved here byte-identical by `ac-know.sh retire` / `scope-proposal --replace` / `--retire`. add/retire/cite search it to name a superseded-only or double match; never edited, never trusted as live. -->";

// awk's records: LF-separated, an unterminated last line one more.
const records = (text: string): string[] => {
  const r = text.split("\n");
  if (r[r.length - 1] === "") r.pop();
  return r;
};

type Sections = { live: string[]; sup: string[] };

// The live and superseded `- ` lines of a record read as bytes; one that
// cannot be read ends the run 2, as the original's awk did, any lock still
// held - except to verify, which goes on with none (W9).
function readSections(rec: string, soft = false): Sections {
  let text: string;
  try {
    text = readFileSync(fsPath(rec), "latin1");
  } catch {
    if (soft) return { live: [], sup: [] };
    process.exit(2);
  }
  const live: string[] = [];
  const sup: string[] = [];
  let seen = false;
  for (const l of records(text)) {
    if (seen) {
      if (l.startsWith("- ")) sup.push(l);
    } else if (l.startsWith("## Superseded")) seen = true;
    else if (l.startsWith("- ")) live.push(l);
  }
  return { live, sup };
}

function render(name: string, s: Sections): string {
  return `# Repo knowledge: ${name}\n\n${BOILER_LIVE}\n\n${lines(s.live)}\n## Superseded\n\n${BOILER_SUPERSEDED}\n\n${lines(s.sup)}`;
}

// <file> replaced by <body> through an exclusive <base>.<pid> given the
// file's mode: a predictable temp written through a planted link is data
// loss. A temp that cannot be made or filled ends the run 1, the file whole.
function replaceFile(file: string, body: string, base: string): void {
  let t: { path: string; fd: number };
  try {
    t = exclusiveTemp(u8(base));
  } catch {
    process.exit(1);
  }
  try {
    const st = stat(file);
    if (st?.isFile()) fchmodSync(t.fd, Number(st.mode) & 0o7777);
    writeAll(t.fd, fsPath(body));
    closeSync(t.fd);
    renameSync(t.path, fsPath(file));
  } catch {
    rmSync(t.path, { force: true });
    process.exit(1);
  }
}

function writeRecord(rec: string, name: string, s: Sections): void {
  spawnOrExit(["mkdir", "-p", dirOf(rec)]);
  replaceFile(rec, render(name, s), `${rec}.tmp`);
}

// The PATH's sleep, so a test's stub fast-forwards the wait on both sides.
const sleepOne = (): void => {
  try {
    spawnShellSync(["sleep", "1"], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  } catch {}
};

function lock(rec: string, timeout: string): string {
  const l = `${rec}.lock`;
  if (!lockAcquire(u8(l), 30, sleepOne)) fail(timeout);
  return l;
}

const unlock = (l: string): void => lockRelease(u8(l));

// --- provenance ---

type Prov = { src: string; sha: string; date: string };

const at12 = (at: string): string => shellPrefix(at, 12);

function validateSrcFile(repo: string, at: string, value: string): void {
  assertSingleLine("--src-file", value);
  if (!/:[0-9]/.test(value)) reject(`--src-file wants <path>:<line> (got '${value}')`);
  const c = value.lastIndexOf(":");
  const path = value.slice(0, c);
  const line = value.slice(c + 1);
  if (line === "" || /[^0-9]/.test(line)) reject(`--src-file wants <path>:<line> (got '${value}')`);
  if (path === "") reject(`--src-file names no path (got '${value}') - it wants <path>:<line>`);
  if (path.startsWith("/") || path.includes("..")) reject(`--src-file must be repo-relative (no absolute path, no ..): ${path}`);
  const k = run(["git", "-C", repo, "cat-file", "-t", `${at}:${path}`], { out: "pipe", err: "ignore" });
  if (k.status !== 0) reject(`${path} does not exist at ${at12(at)} - the citation cannot be followed`);
  const kind = subst(k.out);
  if (kind !== "blob") reject(`${path} is a ${kind} at ${at12(at)}, not a file - a <path>:<line> citation into it is not followable by any reader`);
  const blob = run(["git", "-C", repo, "cat-file", "-p", `${at}:${path}`], { out: "pipe", err: "ignore" });
  if (blob.status !== 0) process.exit(blob.status);
  const n = records(blob.out.toString("latin1")).length;
  const l = testInt(line);
  if (l === null || l > BigInt(n)) reject(`${path} has ${n} lines at ${at12(at)}; the citation names line ${line}`);
}

function assertBound(repo: string, at: string, tag: string, value: string): void {
  if (tag === "file") {
    const path = value.slice(0, value.lastIndexOf(":"));
    if (!stat(`${repo}/${path}`) && run(["git", "-C", repo, "merge-base", "--is-ancestor", at, "HEAD"], { err: "ignore" }).status !== 0) return;
    const rc = run(["git", "-C", repo, "diff", "--quiet", at, "--", path]).status;
    if (rc > 1) reject(`cannot compare ${path} against ${at} (git diff exited ${rc}) - failing closed; an unreadable tree is not evidence of an unchanged one`);
    if (rc !== 0) reject(`${path} differs between the worktree and ${at12(at)} - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw`);
  } else {
    const rc = run(["git", "-C", repo, "diff", "--quiet", at]).status;
    if (rc > 1) reject(`cannot compare the tracked tree against ${at} (git diff exited ${rc}) - failing closed; an unreadable tree is not evidence of an unchanged one`);
    if (rc !== 0) reject(`the tracked tree differs from ${at}, so a cmd: provenance cannot be bound to it. Check out that commit with a clean tree, or cite the specific file with --src-file`);
  }
}

function provenance(repo: string, v: Record<string, string>): Prov & { family: string } {
  const family = v["--family"] ?? "";
  const sf = v["--src-file"] ?? "";
  const sc = v["--src-cmd"] ?? "";
  if (family === "") reject("no attribution - pass --family <family>");
  if (/[^a-z0-9-]/.test(family)) reject(`--family must match [a-z0-9-] (got '${family}')`);
  if (sf !== "" && sc !== "") reject("an entry has ONE provenance - pass --src-file or --src-cmd, not both");
  if (sf === "" && sc === "") reject("no provenance - pass --src-file <path>:<line> or --src-cmd <command>");
  const ref = v["--at"] || "HEAD";
  const r = run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", `${ref}^{commit}`], { out: "pipe", err: "ignore" });
  if (r.status !== 0) reject(`--at '${ref}' does not resolve to a commit in this repo`);
  const sha = subst(r.out);
  const date = capture(["date", "-u", "+%F"]);
  let src: string;
  if (sf !== "") {
    validateSrcFile(repo, sha, sf);
    src = `file:${sf}`;
  } else {
    assertSingleLine("--src-cmd", sc);
    src = `cmd:${sc}`;
  }
  assertBound(repo, sha, sf !== "" ? "file" : "cmd", sf || sc);
  return { family, src, sha, date };
}

const tail = (p: Prov & { family: string }): string => `| src: ${p.src} | at: ${p.sha} ${p.date} | by: ${p.family}`;

// --- addressing and the near-duplicate measure ---

// `${l#<prefix>}` then `${..%% <sep>*}`: past the prefix, up to the first sep.
function subjectOf(l: string, prefix: string, sep: string): string {
  const s = l.startsWith(prefix) ? l.slice(prefix.length) : l;
  const i = s.indexOf(sep);
  return i < 0 ? s : s.slice(0, i);
}

const familyOf = (l: string): string => {
  const i = l.lastIndexOf("| by: ");
  return i < 0 ? l : l.slice(i + 6);
};

// The `- fact ` lines whose subject contains <q>, narrowed to the entry's own
// family when <by> is given; the quote is matched as given (no escapes cooked).
function candidates(set: string[], q: string, by: string): string[] {
  return set.filter((l) => l.startsWith("- fact ") && subjectOf(l, "- fact ", " | src:").includes(q) && (by === "" || familyOf(l) === by));
}

function byMismatch(live: string[], q: string, by: string): string {
  if (by === "") return "";
  const hits = candidates(live, q, "");
  if (hits.length === 0) return "";
  const fams = [...new Set(hits.map(familyOf))].sort(byteCmp);
  return `matches ${hits.length} live entr${hits.length === 1 ? "y" : "ies"}, none by family ${by} - --by is the entry's author family, and these wrote the matches: ${fams.map((f) => `${f} `).join("")}(narrow with one of them, or a longer quote)`;
}

const asciiLower = (s: string): string => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

function terms(s: string, min: number): Set<string> {
  const t = new Set<string>();
  for (const w of asciiLower(s).split(/[^a-z0-9_./-]+/)) if (w.length >= min) t.add(w);
  return t;
}

// Entries of <set> whose subject shares >= 4 of <text>'s distinctive tokens
// AND >= 60% of the smaller token set, most shared first; `sort -rn` breaks a
// tie on the whole row, descending.
function nearDuplicates(set: string[], text: string): string[] {
  const nt = terms(text, 5);
  const rows: [number, string][] = [];
  for (const l of set) {
    if (!l.startsWith("- fact ")) continue;
    const et = terms(subjectOf(l, "- fact ", " | src:"), 5);
    if (nt.size === 0 || et.size === 0) continue;
    let shared = 0;
    for (const w of nt) if (et.has(w)) shared++;
    if (shared < 4 || shared / Math.min(nt.size, et.size) < 0.6) continue;
    rows.push([shared, `${shared}\t${l}`]);
  }
  return rows.sort((a, b) => b[0] - a[0] || byteCmp(b[1], a[1])).map(([, r]) => r.slice(r.indexOf("\t") + 1));
}

// --- add ---

function cmdAdd(args: string[]): void {
  const v = flags(args, ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--fact", "--supersede"], ["--new"], (a) => `unknown flag: ${a} (ac-know.sh add writes facts; the scope map is not writable here)`);
  const { repo } = settle(v);
  const fact = v["--fact"] ?? "";
  const supersede = v["--supersede"] ?? "";
  if (fact === "") reject("no subject - pass --fact <text>");
  assertSingleLine("--fact", fact);
  if (/repo-knowledge:[0-9]|repo-knowledge\/.*\.md:[0-9]/.test(fact)) reject(`--fact cites the repo-knowledge record by line number, which has no stable identity to point at (quote the entry's own text instead): ${fact}`);
  const p = provenance(repo, v);
  const { rec, name } = recordOf(repo);
  const entry = `- fact ${fact} ${tail(p)}`;
  spawnOrExit(["mkdir", "-p", dirOf(rec)]);
  const l = lock(rec, `ac-know: lock timeout for ${name}`);
  const s: Sections = isFile(rec) ? readSections(rec) : { live: [], sup: [] };
  const refuse = (msg: string): never => {
    unlock(l);
    fail(msg);
  };
  if (supersede !== "") {
    const target = candidates(s.live, supersede, "");
    if (target.length === 0) {
      const supHit = candidates(s.sup, supersede, "");
      if (supHit.length > 0) refuse(`--supersede '${supersede}' matches no LIVE fact, but matches a SUPERSEDED entry - a superseded entry cannot be corrected again; find the live entry that replaced it and quote that instead (nothing written):\n${supHit.join("\n")}`);
      refuse(`--supersede matched nothing: no live fact contains '${supersede}' (nothing written)`);
    }
    if (target.length > 1) refuse(`--supersede '${supersede}' is ambiguous - ${target.length} live entries match, quote a longer phrase (nothing written):\n${target.join("\n")}`);
    const supHit = candidates(s.sup, supersede, "");
    if (supHit.length > 0) refuse(`--supersede '${supersede}' matches one live entry AND a SUPERSEDED entry - ambiguous which the caller means; quote a longer, disambiguating phrase (nothing written):\n  live: ${target[0]}\n${supHit.join("\n")}`);
    s.sup.push(target[0]!);
    s.live = s.live.filter((x) => x !== target[0]);
  } else if (v["--new"] === undefined) {
    const dups = nearDuplicates(s.live, fact);
    if (dups.length > 0)
      refuse(
        `this subject already has a live entry (nothing written) - two claims about one subject is the defect this guard exists to stop:\n${dups.join("\n")}\n\n  correct the existing one:  --supersede '<phrase quoted from it>'   (retires it and adds yours in one write)\n  genuinely distinct:        --new                                    (declares it, and the guard stands aside)`,
      );
    const supDups = nearDuplicates(s.sup, fact);
    if (supDups.length > 0) {
      let w = "add: warning - this subject near-duplicates a SUPERSEDED entry; the fleet already judged this wording wrong or stale once:\n";
      for (const d of supDups) {
        w += `${d}\n`;
        const succ = nearDuplicates(s.live, subjectOf(d, "- fact ", " | src:"));
        if (succ.length > 0) w += `  replaced by:\n${succ.map((x) => `    ${x}\n`).join("")}`;
      }
      warnOut(w);
    }
  }
  s.live.push(entry);
  writeRecord(rec, name, s);
  unlock(l);
  out(`recorded in ${rec}\n`);
}

// --- retire and cite: the one addressing contract ---

type Addressed = { l: string; s: Sections; target: string; supHit: string[] };

// The record locked and read, <q> resolved to exactly ONE live entry, or
// refused in <verb>'s words with the lock released.
function address(verb: "retire" | "cite", q: string, by: string, rec: string, name: string): Addressed {
  const l = lock(rec, `ac-know: lock timeout for ${name}`);
  const s: Sections = isFile(rec) ? readSections(rec) : { live: [], sup: [] };
  const refuse = (msg: string): never => {
    unlock(l);
    fail(msg);
  };
  const byText = by ? ` by family ${by}` : "";
  const matches = candidates(s.live, q, by);
  if (matches.length === 0) {
    const supHit = candidates(s.sup, q, by);
    if (supHit.length > 0)
      refuse(
        verb === "retire"
          ? `retire: '${q}'${byText} matches no LIVE fact, but matches a SUPERSEDED entry - a superseded entry cannot be retired again; find the live entry that replaced it and quote that instead:\n${supHit.join("\n")}`
          : `cite: '${q}'${byText} matches no LIVE fact, but matches a SUPERSEDED entry - find the live entry that replaced it and quote that instead:\n${supHit.join("\n")}`,
      );
    const hint = byMismatch(s.live, q, by);
    if (hint !== "") refuse(`${verb}: '${q}' ${hint}`);
    refuse(`${verb}: nothing matched '${q}'${byText} - no live fact entry contains that phrase`);
  }
  if (matches.length > 1) refuse(`${verb}: '${q}' is ambiguous - ${matches.length} live entries match, narrow with --by <family>:\n${matches.join("\n")}`);
  return { l, s, target: matches[0]!, supHit: candidates(s.sup, q, by) };
}

function cmdRetire(args: string[]): void {
  const v = flags(args, ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--quote", "--by", "--why"], [], plainUnknown);
  const { repo } = settle(v);
  const q = v["--quote"] ?? "";
  const why = v["--why"] ?? "";
  if (q === "") reject("no target - pass --quote '<phrase from the entry's own text>'");
  if (why === "") reject("a retirement records WHY - pass --why <text>");
  assertSingleLine("--why", why);
  const p = provenance(repo, v);
  const { rec, name } = recordOf(repo);
  spawnOrExit(["mkdir", "-p", dirOf(rec)]);
  const by = v["--by"] ?? "";
  const a = address("retire", q, by, rec, name);
  if (a.supHit.length > 0) {
    unlock(a.l);
    fail(`retire: '${q}'${by ? ` by family ${by}` : ""} matches one live entry AND a SUPERSEDED entry - ambiguous which the caller means; quote a longer, disambiguating phrase (nothing written):\n  live: ${a.target}\n${a.supHit.join("\n")}`);
  }
  a.s.sup.push(a.target);
  a.s.live = a.s.live.filter((x) => x !== a.target);
  a.s.live.push(`- fact retired: ${why} ${tail(p)}`);
  writeRecord(rec, name, a.s);
  unlock(a.l);
  out(`retired from ${rec}\n`);
}

function cmdCite(args: string[]): void {
  const v = flags(args, ["--home", "--repo", "--quote", "--by"], [], plainUnknown);
  const { repo } = settle(v);
  const q = v["--quote"] ?? "";
  if (q === "") reject("no target - pass --quote '<phrase from the entry own text>'");
  const { rec, name } = recordOf(repo);
  if (!isFile(rec)) fail(`cite: no repo-knowledge record yet: ${rec}`);
  const a = address("cite", q, v["--by"] ?? "", rec, name);
  // A read receipt is no supersession: a double match only warns.
  if (a.supHit.length > 0) warnOut(`cite: warning - ${q} also matches a SUPERSEDED entry; heat is bumped on the live match only:\n${a.supHit.join("\n")}\n`);
  const t = a.target;
  const bi = t.lastIndexOf(" | by: ");
  if (bi < 0) {
    unlock(a.l);
    fail(`cite: matched entry carries no '| by:' field - not a grammar line this verb can bump: ${t}`);
  }
  const prefix = t.slice(0, bi);
  const byval = t.slice(bi + 7);
  let line: string;
  const hi = prefix.lastIndexOf(" | heat: ");
  if (hi >= 0) {
    const h = prefix.slice(hi + 9);
    if (h === "" || /[^0-9]/.test(h)) {
      unlock(a.l);
      fail(`cite: malformed heat field on the matched entry (got: '| heat: ${h}'): ${t}`);
    }
    let n: bigint;
    try {
      n = arithValue(h);
    } catch {
      // bash's arithmetic error ended the run here, the lock still held.
      process.exit(1);
    }
    line = `${prefix.slice(0, hi)} | heat: ${BigInt.asIntN(64, n + 1n)} | by: ${byval}`;
  } else line = `${prefix} | heat: 1 | by: ${byval}`;
  a.s.live[a.s.live.indexOf(t)] = line;
  writeRecord(rec, name, a.s);
  unlock(a.l);
  out(`${line}\ncited in ${rec}\n`);
}

// --- recall ---

// sort -n's reading of a field: blanks, an optional `-`, digits, an optional
// fraction; anything else is 0.
function sortNum(f: string): { sign: number; int: string; frac: string } {
  const m = /^[ \t]*(-?)([0-9]*)(?:\.([0-9]*))?/.exec(f)!;
  const int = m[2]!.replace(/^0+/, "");
  const frac = (m[3] ?? "").replace(/0+$/, "");
  return { sign: int === "" && frac === "" ? 0 : m[1] ? -1 : 1, int, frac };
}

function cmpNum(x: string, y: string): number {
  const a = sortNum(x);
  const b = sortNum(y);
  if (a.sign !== b.sign) return a.sign - b.sign;
  if (a.sign === 0) return 0;
  let c = a.int.length - b.int.length || byteCmp(a.int, b.int);
  if (c === 0) {
    const n = Math.max(a.frac.length, b.frac.length);
    c = byteCmp(a.frac.padEnd(n, "0"), b.frac.padEnd(n, "0"));
  }
  return a.sign * Math.sign(c);
}

// `sort -t TAB -k1,1nr -k2,2nr`: hits, then heat, both descending, then the
// whole row ascending in BYTE order.
function ranked(rows: string[]): string[] {
  const f = (r: string, i: number): string => r.split("\t")[i] ?? "";
  return [...rows].sort((a, b) => cmpNum(f(b, 0), f(a, 0)) || cmpNum(f(b, 1), f(a, 1)) || byteCmp(a, b));
}

// `[ a -lt b ]` / `[ a -ge b ]`: an operand that is no int64 is the test's
// error, which reads as false either way.
const testLt = (a: number, b: string): boolean => {
  const y = testInt(b);
  return y !== null && BigInt(a) < y;
};
const testGe = (a: number, b: string): boolean => {
  const y = testInt(b);
  return y !== null && BigInt(a) >= y;
};

const hitsIn = (q: Set<string>, text: string): number => {
  const t = asciiLower(text);
  let h = 0;
  for (const w of q) if (t.includes(w)) h++;
  return h;
};

function cmdRecall(args: string[]): void {
  const v: Record<string, string> = {};
  let query = "";
  const space = new RegExp(shellSpaceClass().source, "u");
  const word = (w: string): void => {
    query = query ? `${query} ${w}` : w;
  };
  let i = 0;
  while (i < args.length) {
    const a = args[i]!;
    if (["--home", "--repo", "--max", "--bytes"].includes(a)) {
      if (i + 1 >= args.length) fail(`${a} needs a value`);
      v[a] = args[i + 1]!;
      i += 2;
    } else if (a === "--") {
      i++;
      break;
    } else if (a.startsWith("-") && space.test(u8(a.slice(1)))) {
      word(a);
      i++;
    } else if (a.startsWith("-")) fail(`unknown flag: ${a} (a question word that starts with - goes after --)`);
    else {
      word(a);
      i++;
    }
  }
  if (i < args.length) query = `${query ? `${query} ` : ""}${args.slice(i).join(" ")}`;
  const max = v["--max"] ?? "8";
  const bytes = v["--bytes"] ?? "8192";
  if (query === "") reject("no question - pass the order's subject/mechanism/terms");
  if (!/^[0-9]+$/.test(max)) fail(`--max must be a count (got: '${max}')`);
  if (!/^[0-9]+$/.test(bytes)) fail(`--bytes must be a byte count (got: '${bytes}')`);
  const { repo, home } = settle(v);
  const q = terms(query, 4);
  const floor = q.size <= 1 ? 1 : Math.max(2, Math.trunc(q.size * 0.6 + 0.999));

  const recordsDir = `${home}/records`;
  try {
    mkdirSync(fsPath(recordsDir), { recursive: true });
  } catch {}
  const sdir = `${recordsDir}/scenes`;
  let tsv = "";
  if (isDir(sdir)) {
    const names = (readdirSync(fsPath(sdir), { encoding: "buffer" }) as Uint8Array[]).map((n) => Buffer.from(n).toString("latin1"));
    for (const n of names.filter((x) => x.endsWith(".md") && !x.startsWith(".")).sort(byteCmp)) {
      const sf = `${sdir}/${n}`;
      if (!isFile(sf)) continue;
      let text: string;
      try {
        text = readFileSync(fsPath(sf), "latin1");
      } catch {
        process.exit(1);
      }
      const ls = records(text);
      const heat = ls[1] === undefined ? "" : subst(ls[1].split(" ").filter((t) => t.startsWith("heat=")).map((t) => `${t.slice(5)}\n`).join(""));
      const summary = ls[2]?.startsWith("summary: ") ? subst(ls[2].slice(9)) : "";
      const hits = hitsIn(q, subst(text));
      if (hits < floor) continue;
      tsv += `${hits}\t${heat || "0"}\t${n.slice(0, -3)}\t${summary}\n`;
    }
  }
  let printed = 0;
  let nScene = 0;
  let nFact = 0;
  let shown = 0;
  let truncated = false;
  if (tsv !== "") {
    out("== scenes (L2 - a topic restored in one read) ==\n");
    for (const row of ranked(records(tsv))) {
      if (!testLt(printed, max)) {
        truncated = true;
        break;
      }
      const [hits, heat, slug, summary] = tabFields(row, 4);
      out(`  ${slug}  (hits ${hits}, heat ${heat})\n    ${summary}\n    open: ac-scene.sh show ${slug} --cite\n`);
      printed++;
      nScene++;
    }
    out("\n");
  }

  const { rec } = recordOf(repo);
  const rows: string[] = [];
  if (isFile(rec)) {
    for (const l of readSections(rec).live) {
      if (!l.startsWith("- fact ")) continue;
      const h = hitsIn(q, l);
      if (h < floor) continue;
      const bi = l.lastIndexOf(" | by: ");
      const p = bi < 0 ? l : l.slice(0, bi);
      const hi = p.lastIndexOf(" | heat: ");
      let heat = hi < 0 ? "0" : p.slice(hi + 9);
      if (heat === "" || /[^0-9]/.test(heat)) heat = "0";
      rows.push(`${h}\t${heat}\t${l}`);
    }
  }
  if (rows.length > 0) {
    out("== facts (L1 - repo-knowledge) ==\n");
    for (const row of ranked(rows)) {
      if (testGe(printed, max) || testGe(shown, bytes)) {
        truncated = true;
        break;
      }
      const [hits, heat, line] = tabFields(row, 3);
      out(`  (hits ${hits}, heat ${heat}) ${line}\n`);
      // The hand-over quotes the entry's own text - how this record addresses
      // an entry - with each ' escaped, or the phrase ends at an apostrophe.
      out(`    cite: ac-know.sh cite --repo <clone> --quote '${shellPrefix(subjectOf(line!, "- fact ", " | src:"), 60).replace(/'/g, "'\\''")}'\n`);
      printed++;
      nFact++;
      shown += shellLength(line!);
    }
    out("\n");
  }

  // Every hit is printed or cut, so only "neither" is an absence: a zero
  // budget that cut them all is a truncation, stated like any other.
  if (printed === 0 && !truncated) {
    out(`no hit in any layer for: ${query} (needed ${floor} of its distinctive terms)\n(state the absence explicitly in the brief - intake-triage skill)\n`);
    return;
  }
  out(`-- ${nScene} scene(s), ${nFact} fact(s) shown`);
  out(truncated ? `; TRUNCATED at --max ${max} / --bytes ${bytes} (${rows.length} fact hits total) --\n` : " (all hits) --\n");
  out("recall PRINTS; it never cites - bumping heat on what you only skimmed\nwould corrupt the ranking. Cite the ONE you use, with the line above it.\n");
}

// --- verify ---

// `${x#*<sep>}`: past the first <sep>, or x whole.
const after = (x: string, sep: string): string => {
  const i = x.indexOf(sep);
  return i < 0 ? x : x.slice(i + sep.length);
};
// `${x%%<sep>*}`: up to the first <sep>, or x whole.
const before = (x: string, sep: string): string => {
  const i = x.indexOf(sep);
  return i < 0 ? x : x.slice(0, i);
};

function cmdVerify(args: string[]): void {
  const v = flags(args, ["--home", "--repo"], [], plainUnknown);
  const { repo, home } = settle(v);
  const { rec, name } = recordOf(repo);
  if (!isFile(rec)) {
    out(`no repo-knowledge record yet: ${rec}\n`);
    return;
  }
  const h = run(["git", "-C", repo, "rev-parse", "HEAD"], { out: "pipe", err: "ignore" });
  const head = subst(Buffer.concat([h.out, Buffer.from(h.status === 0 ? "" : "-")]));
  const live = readSections(rec, true).live;
  const n = { FRESH: 0, SUSPECT: 0, UNVERIFIABLE: 0, MANUAL: 0 };
  const say = (state: keyof typeof n, text: string): void => {
    n[state]++;
    out(`${text}\n`);
  };
  for (const line of live) {
    const src = before(after(line, "| src: "), " | at: ");
    const at = before(after(line, "| at: "), " ");
    const tag = before(src, ":");
    const value = after(src, ":");
    if (tag === "cmd") {
      say("MANUAL", `MANUAL  ${line}  (re-run: ${value})`);
      continue;
    }
    const ci = value.lastIndexOf(":");
    const path = ci < 0 ? value : value.slice(0, ci);
    if (run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", `${at}^{commit}`], { out: "ignore", err: "ignore" }).status !== 0) {
      say("UNVERIFIABLE", `UNVERIFIABLE ${line}  (${at12(at)} does not resolve in this clone)`);
      continue;
    }
    if (!stat(`${repo}/${path}`)) {
      if (run(["git", "-C", repo, "merge-base", "--is-ancestor", at, "HEAD"], { err: "ignore" }).status === 0) say("SUSPECT", `SUSPECT ${line}  (${path} no longer exists)`);
      else say("UNVERIFIABLE", `UNVERIFIABLE ${line}  (${path} has no worktree copy in this clone to compare against ${at12(at)})`);
      continue;
    }
    const rc = run(["git", "-C", repo, "diff", "--quiet", at, "--", path]).status;
    if (rc === 0) say("FRESH", `FRESH   ${line}`);
    else if (rc === 1) say("SUSPECT", `SUSPECT ${line}  (${path} changed since ${at12(at)})`);
    else say("UNVERIFIABLE", `UNVERIFIABLE ${line}  (cannot compare ${path} against ${at12(at)})`);
  }
  const state = `${home}/state`;
  spawnOrExit(["mkdir", "-p", state]);
  const stamp = `${state}/.know-verify-${name}.meta`;
  replaceFile(stamp, `record=${rec.slice(rec.lastIndexOf("/") + 1)}\nfresh=${n.FRESH}\nsuspect=${n.SUSPECT}\nunverifiable=${n.UNVERIFIABLE}\nmanual=${n.MANUAL}\nhead=${head}\nran=${b8(iso())}\n`, `${stamp}.tmp`);
}

// --- the scope map: draft, then chief-install ---

function scopeLive(live: string[], scope: string): string[] {
  return live.filter((l) => {
    if (!l.startsWith("- scope ")) return false;
    const subj = before(l.slice(8), " | src: ");
    const i = subj.indexOf(" = ");
    return i >= 0 && subj.slice(0, i) === scope;
  });
}

// An app MAY belong to several scopes: an overlap is a note for the author
// and the reviewing chief, never a refusal, and nothing reads it.
function overlapNotes(live: string[], scope: string, apps: string[]): void {
  const map: string[] = [];
  for (const l of live) {
    if (!l.startsWith("- scope ")) continue;
    const subj = before(l.slice(8), " | src: ");
    const i = subj.indexOf(" = ");
    if (i < 0) continue;
    map.push(`${subj.slice(0, i)}\t${subj.slice(i + 3).replace(/[ \t]/g, "")}`);
  }
  for (const app of apps)
    for (const row of map) {
      const [other, members] = tabFields(row, 2);
      if (other !== scope && `,${members},`.includes(`,${app},`)) warnOut(`note: ${app} is also live in scope ${other}\n`);
    }
}

const ID_CHARS = /[^A-Za-z0-9._-]/;

// ac_config_sha256's identity, in-process.
const sha256 = (b: Buffer): string => new Bun.CryptoHasher("sha256").update(b).digest("hex");

function cmdScopeProposal(args: string[]): void {
  const v = flags(args, ["--home", "--repo", "--family", "--src-file", "--src-cmd", "--at", "--scope", "--apps", "--why", "--id"], ["--replace", "--retire"], plainUnknown);
  const { repo, home } = settle(v);
  const scope = v["--scope"] ?? "";
  const why = v["--why"] ?? "";
  const retire = v["--retire"] !== undefined;
  let apps = v["--apps"] ?? "";
  let appList: string[] = [];
  if (scope === "") reject("no scope named - pass --scope <name>");
  if (/[^A-Za-z0-9_-]/.test(scope)) reject(`${scope} is not addressable as a yaml path segment (--scope must match [A-Za-z0-9_-])`);
  if (retire) {
    if (why === "") reject("a retirement records WHY - pass --why <text>");
    assertSingleLine("--why", why);
    if (apps !== "") reject("--retire removes a scope from the list; it takes no --apps");
  } else {
    apps = apps.replace(/ /g, "");
    if (apps === "") reject("a scope with no members - pass --apps <app>,<app>");
    // `IFS=, read -a` reads the first line only and drops one trailing empty
    // field; a first line with no field left bash's array unbound (set -u).
    appList = before(apps, "\n").split(",");
    if (appList[appList.length - 1] === "") appList.pop();
    if (appList.length === 0) process.exit(1);
    for (const a of appList) if (a === "" || /[^A-Za-z0-9_-]/.test(a)) reject(`${a} is not addressable as a yaml path segment (--apps must match [A-Za-z0-9_-])`);
  }
  const p = provenance(repo, v);
  const { rec, name } = recordOf(repo);
  const id = v["--id"] || `${capture(["date", "+%Y%m%d-%H%M%S"])}-${process.pid}`;
  if (ID_CHARS.test(id)) fail(`invalid proposal id: ${id}`);
  const dir = `${repo}/.crew/knowledge-proposals/${id}`;
  spawnOrExit(["mkdir", "-p", `${repo}/.crew/knowledge-proposals`]);
  try {
    mkdirSync(fsPath(dir));
  } catch {
    fail(`scope-proposal: id already exists: ${id}`);
  }
  const base = `${dir}/base.md`;
  const prop = `${dir}/proposed.md`;
  writeFileSync(fsPath(base), "");
  let s: Sections = { live: [], sup: [] };
  if (isFile(rec)) {
    spawnOrExit(["cp", rec, base]);
    s = readSections(rec);
  }
  const existing = scopeLive(s.live, scope);
  let entry: string;
  if (retire) {
    if (existing.length === 0) {
      rmSync(fsPath(dir), { recursive: true, force: true });
      reject(`no live entry for scope ${scope} - nothing to retire`);
    }
    entry = `- fact retired scope ${scope}: ${why} ${tail(p)}`;
  } else {
    if (existing.length > 0 && v["--replace"] === undefined) {
      rmSync(fsPath(dir), { recursive: true, force: true });
      reject(`scope ${scope} is already live - pass --replace to supersede it:\n${existing.join("\n")}`);
    }
    entry = `- scope ${scope} = ${apps.replace(/,/g, ", ")} ${tail(p)}`;
  }
  // A MOVE, byte-identical: a receipt is durable, never rewritten.
  if (existing.length > 0) {
    s.sup.push(...existing);
    s.live = s.live.filter((x) => !existing.includes(x));
  }
  if (!retire) overlapNotes(s.live, scope, appList);
  s.live.push(entry);
  writeFileSync(fsPath(prop), fsPath(render(name, s)));
  const baseSha = sha256(readFileSync(fsPath(base)));
  writeFileSync(fsPath(`${dir}/base.sha256`), `${baseSha}\n`);
  writeFileSync(fsPath(`${dir}/project`), fsPath(`${name}\n`));
  const d = run(["diff", "-u", "--label", "current", "--label", "proposed", base, prop], { out: "pipe" });
  writeFileSync(fsPath(`${dir}/proposal.patch`), d.out);
  if (d.status === 0) {
    rmSync(fsPath(dir), { recursive: true, force: true });
    reject("the draft is identical to the installed record - nothing to propose");
  }
  const root = b8(STARTED_BIN.slice(0, -"/bin".length));
  out(
    `proposal_id: ${id}\nproposal written:\n  ${dir}/proposal.patch\n  ${prop}\ntarget: ${rec}\nbase_sha256: ${baseSha}\ninstall (CHIEF, after review - never the drafting agent): ${root}/bin/ac-know.sh scope-install ${id} --home ${home} --repo ${repo}\n`,
  );
}

// `$(cat <f> 2>/dev/null || true)`: the bytes, "" when they cannot be read.
const catSoft = (f: string): string => {
  try {
    return subst(readFileSync(fsPath(f), "latin1"));
  } catch {
    return "";
  }
};

function cmdScopeInstall(args: string[]): void {
  const id = args[0] ?? "";
  const v = flags(args.slice(1), ["--home", "--repo"], [], plainUnknown);
  if (id === "") fail("usage: ac-know.sh scope-install <proposal-id> --home <abs> --repo <dir>");
  if (ID_CHARS.test(id)) fail(`invalid proposal id: ${id}`);
  const { repo } = settle(v);
  const { rec, name } = recordOf(repo);
  const dir = `${repo}/.crew/knowledge-proposals/${id}`;
  const prop = `${dir}/proposed.md`;
  if (!isFile(prop)) fail(`scope-install: no staged proposal ${id} at ${dir}`);
  if (catSoft(`${dir}/project`) !== name) fail(`scope-install: proposal ${id} does not target project ${name}`);
  const baseSha = catSoft(`${dir}/base.sha256`);
  if (baseSha === "") fail(`scope-install: proposal ${id} has no base hash`);
  spawnOrExit(["mkdir", "-p", dirOf(rec)]);
  const l = lock(rec, `scope-install: lock timeout for ${name}`);
  let cur = Buffer.alloc(0);
  if (isFile(rec)) {
    try {
      cur = readFileSync(fsPath(rec));
    } catch {
      process.exit(1);
    }
  }
  const curSha = sha256(cur);
  if (curSha !== baseSha) {
    unlock(l);
    fail(`scope-install: proposal ${id} conflicts with a newer installed record (base=${baseSha} current=${curSha}); re-draft it`);
  }
  let proposed: Buffer;
  try {
    proposed = readFileSync(fsPath(prop));
  } catch {
    process.exit(1);
  }
  let prev = "";
  if (isFile(rec) && !cur.equals(proposed)) {
    prev = `${rec}.prev`;
    spawnOrExit(["cp", rec, prev]);
  }
  replaceFile(rec, proposed.toString("latin1"), `${rec}.install`);
  const installed = sha256(proposed);
  unlock(l);
  writeFileSync(fsPath(`${dir}/installed.sha256`), `${installed}\n`);
  out(`installed proposal ${id}: ${prop} -> ${rec}${prev ? ` (previous kept at ${prev})` : ""}\n`);
  out(`receipt (post to the family room): KNOWLEDGE-INSTALLED: ${rec} sha256=${installed} proposal=${id} - drafted by the task agent, reviewed + installed by the chief; captain veto: restore ${prev || "(no previous record)"}\n`);
}

function main(): void {
  const entered = enterCaller(process.argv.slice(2));
  atCaller = entered.atCaller;
  const argv = entered.args.map(b8);
  require("git");
  const rest = argv.slice(1);
  switch (argv[0] ?? "") {
    case "add":
      return cmdAdd(rest);
    case "retire":
      return cmdRetire(rest);
    case "cite":
      return cmdCite(rest);
    case "recall":
      return cmdRecall(rest);
    case "verify":
      return cmdVerify(rest);
    case "scope-proposal":
      return cmdScopeProposal(rest);
    case "scope-install":
      return cmdScopeInstall(rest);
    case "-h":
    case "--help":
    case "":
      return usage();
    default:
      fail(`unknown verb: ${argv[0]}`);
  }
}

main();
