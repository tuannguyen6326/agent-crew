// deputy.ts - the crewdeputy routing layer: render the routing table, check
// it strictly, answer a routed order back to the parent, and hand queued
// backlog items over to a deputy. The entry is bin/ac-deputy.sh (a shim that
// starts this file through bin/ac-bun.sh); THIS header is the authoritative
// spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-deputy.sh as the oracle the differential leg of
// tests/sh/ac-deputy.test.sh holds this module to.
//
// Usage: ac-deputy.sh list
//        ac-deputy.sh validate
//        ac-deputy.sh report '<text>' [--doc <abs-path>]
//        ac-deputy.sh handoff <deputy-id> <backlog-id>...
// Anything else (none, -h, LIST) is `ERROR: usage: ac-deputy.sh
// <list|validate|report|handoff>`, exit 1; extra arguments to list and
// validate are never read; stdin is never read. Every ERROR/WARN below is on
// stderr, an ERROR exit 1 unless noted. Output is written line by line, so a
// probe's stderr line precedes its entry's stdout line on a merged stream.
//
// BEFORE ANY VERB, usage included (W2), the fleet backend is resolved as
// sourcing ac-backend.sh resolved it (backendName, src/lib.ts): AC_BACKEND,
// config/backend, the first word of <AC_FLEET_STATE>/../config/backend, herdr;
// any other name is `ERROR: unsupported backend '<b>' (valid backends: herdr,
// orca; tmux/wezterm were removed 2026-07-17)`, exit 1.
//
// THE REGISTRY GRAMMAR is ac-lib.sh's `crewdeputy routing table` block,
// read through deputyParse (src/lib.ts): ac_deputy_parse's awk program,
// spawned byte for byte under the caller's locale - one TSV record per `- `
// line, `<class>\t<id>\t<home>\t<charter>\t<scope>\t<projects>\t<reason>`,
// classes VALID / LEGACY (charter `(none)`, scope "", `no projects` -> none,
// blank runs -> `,`) / INVALID (<id> the verbatim source line, <reason> the
// first failed check). Every reader below re-separates the records with US
// (`| tr '\t' '\037'`) and reads each line as `IFS=$'\037' read -r` over
// seven names: empty fields stay positional, the seventh takes the rest of
// the line, missing fields are empty.
//
// --- list: the session-start digest block (AUTHORITATIVE) ---
// <reg> is deputyRegistry() - <home>/records/crewdeputies.md, records/ minted.
// Three distinguishable states, because "no registry" and "an empty registry"
// are different facts about the fleet:
//   no regular file (absent, a directory):
//     ABSENT: records/crewdeputies.md - no crewdeputies registered
//   no record:
//     EMPTY: records/crewdeputies.md present, 0 entries - no crewdeputies registered
//   else the FULL table, never truncated - the chief routes against it.
// A parse that fails ends list with the pipeline's status (pipefail: tr's
// when non-zero, else awk's) before a line is printed - W4: under a UTF-8
// locale one byte that is not UTF-8 is awk's `towc: multibyte conversion
// failure`, exit 2, nothing on stdout; under C that line is INVALID `bad id
// charset`. Per record, a blank class skipped:
//   INVALID: `INVALID\t<source>\treason: <reason>` - W3: a TAB inside the
//     source line cuts it there and the reason gains the rest, led by a raw
//     US.
//   else the entry's STATE, first match wins:
//     HOME-MISSING  <home> is no directory, or <home>/.ac-crewdeputy-home is
//                   no regular file (a marker directory counts as missing).
//                   Registry and disk disagree: never routable, no recover
//                   hint - repairing a registry line is a captain-facing act.
//     NOT-RUNNING   no regular file at the PARENT's state/<id>.meta.
//     else the window probe: AC_BACKEND set to taskBackend(<id>) (the
//     meta's backend=, herdr without one; an unreadable meta WARNs as
//     ac_meta_get did and reads herdr) for that one call and restored after,
//     then backendCall("window_alive", [<id>]) (src/lib.ts, the twin of
//     bin/ac-backend.sh's driver) as the original's `( )` ran it - stdin
//     /dev/null, stdout captured, stderr passed through. Its status: 0 LIVE,
//     1 DOWN, anything else UNOBSERVABLE (2 an unreadable backend). A meta
//     naming an unsupported backend (backend=tmux) is refused by the route
//     with the ERROR line above, status 1: DOWN - a malformed meta, a
//     different variable from a backend the fleet cannot READ. The state is
//     the substitution's reading of the probe's stdout followed by the word.
//     The drivers: herdr `pane get <pane>` (alive), else `pane list` (a
//     parsed list answers present/absent), else `status server --json`
//     (`running:false` is gone) - each through herdr_rpc_bounded, with
//     `--session <s>` for a configured session; no .pane-<id> handle is 1;
//     herdr absent from PATH reads 2. orca `terminal show --terminal <h>
//     --json` (connected true 0, else 1), failing that `status --json` (1 if
//     it answers, else 2).
//     UNOBSERVABLE is NOT a verdict of down and earns no recover hint.
// Rendering, TAB-separated head line plus TAB-indented continuations:
//   <STATE>\t<id>\thome: <home>\tprojects: <projects>
//   \tcharter: <charter>
//   \tscope: <scope>   (empty: `\tscope: (unset - not routable until a scope: is added)`)
//   \trecover: bin/ac-spawn.sh <id> --crewdeputy --recover   (DOWN and NOT-RUNNING only)
// A TAB inside a VALID charter shifts charter, scope and projects (W3). The
// tally closes the block: `registered: <n> (live <l>, down <d>, not-running
// <r>, home-missing <m>, invalid <i>)`, UNOBSERVABLE counted in <n> only.
// list exits 0 but for a failed parse, and is read-only (parses a file,
// probes windows), so safe under the read-only session lock.
//
// --- validate: the strict twin ---
// <reg> no regular file: silent exit 0. Else each INVALID record prints
// `INVALID <source>: <reason>` (a space, not a TAB) and the exit is 1; none:
// silent 0. The parse ran inside a heredoc's $(...) with errexit asleep, so
// its failure is no exit of its own: under a UTF-8 locale the records past a
// byte that is not UTF-8 go unreported, and a registry whose only fault is
// that byte passes silently (W4).
//
// --- report: the deputy -> parent RETURN CHANNEL (AUTHORITATIVE) ---
// Runs INSIDE the deputy home (AC_HOME = the deputy home) and writes ACROSS
// homes. Arguments: <text> first, then `--doc <v>` pairs (the last wins, ""
// is no doc - W9) - `--doc` with no value is `ERROR: --doc needs a value`,
// anything else `ERROR: unknown argument: <a>` (`report --doc /x` takes
// `--doc` as the text, W9). Refusals in order: an empty text, `ERROR: usage:
// ac-deputy.sh report '<text>' [--doc <abs-path>]`; no marker
// (isCrewdeputyHome), `ERROR: report runs INSIDE a crewdeputy home (no
// .ac-crewdeputy-home marker here)`; then <home> is the physical home, <id>
// `basename <home>` (spawned), and <parent> `cd <home>/../.. && pwd -P` -
// ANY grandparent holding a state/ directory, crewdeputies/ or not (W10) -
// else `ERROR: cannot resolve a parent fleet above <home> - refusing to write
// a return with nowhere to land`, nothing minted; a --doc not led by `/`,
// `ERROR: --doc must be an absolute path (the parent resolves it from its
// own home): <doc>`. <body> is the text, plus ` doc: <doc>` with a doc. The
// parent's registry is looked up - deputyParse(<parent>/records/
// crewdeputies.md) piped to `awk -F'\t' -v i=<id> '$1 != "INVALID" && $2 ==
// i { found = 1 } END { exit !found }'` under the caller's locale, so `==` is
// numeric when both sides look numeric (W5: a home named 07 finds registry
// id 7) - and a failing pipeline is only `WARN: no registry entry for <id> in
// the parent's routing table - delivering the return anyway`: a stranded
// ANSWER is pure loss, where the send side fails closed. Then, in order:
//   1. `<iso> report: <body>` appended to <parent>/state/<id>.status, the
//      body RAW (W6: a TAB or LF in the text stays, the line can be two); a
//      date that fails or cannot start leaves <iso> empty and the line is
//      still written (the publish below then ends it with date's status, 127
//      for one not on PATH); a failed append ends it 1, no wake;
//   2. the payload `tr '\t\n' '  '` (spawned, the body on stdin) - its
//      failure ends it with tr's status, the status line already written;
//   3. ONE wake record, wakePublish(<parent>/state, "", deputy, <id>,
//      <payload>) UNGUARDED: a failing `date +%s%N` or seam hook ends it with
//      that status, an unpublished record ends it 1 with no line and the
//      .wake-tmp. temp left in <parent>/state (W8). The parent's ordinary
//      bin/ac-wake-drain.sh emits `deputy <id> <payload>`;
//   4. `reported <id> to <parent>`, exit 0.
// The deputy home itself records nothing. Only phase changes the parent must
// act on return here (done, blocked, needs-decision, failed, a declared
// paused, captain-facing escalations), never routine churn; an answer longer
// than a line travels as a document in the deputy's home, --doc its pointer.
//
// --- handoff: queued work follows the domain (AUTHORITATIVE) ---
// Runs in the PARENT home and moves named `## Queued` items into the deputy's
// own records/backlog.md, all or nothing - every check below passes for
// every id before the first write. Refusals in order:
//   1. no deputy id or no backlog id: `ERROR: usage: ac-deputy.sh handoff
//      <deputy-id> <backlog-id>...`; run inside a deputy home: `ERROR:
//      handoff runs in the PARENT fleet home, not inside a crewdeputy home`.
//   2. <dhome>: deputyParse() piped to `awk -F'\t' -v i=<dep> '$1 !=
//      "INVALID" && $2 == i { print $3; exit }'` - numeric `==` (W5: 07
//      resolves 7's home, while the status below is 07's); the early exit
//      ends a parse still writing with SIGPIPE, so a registry past the pipe's
//      capacity with the deputy early ends handoff 141, silently (W19); the
//      two run at once on one pipe for that reason. Empty: `ERROR: no
//      crewdeputy '<dep>' in <reg>`; no directory: `ERROR: crewdeputy home is
//      gone: <dhome>`; no regular <dhome>/records/backlog.md: `ERROR:
//      crewdeputy <dep> has no records/backlog.md to hand work into`; `grep -q
//      '^## Queued'` (spawned; a prefix - `## Queued-later` is one, W14)
//      failing: `ERROR: crewdeputy <dep> has no '## Queued' section in its
//      backlog`; no regular <home>/records/backlog.md: `ERROR: no parent
//      backlog at <path>`. Then THE LEDGER LOCKS, held to the exit
//      (ledgerLock, src/lib.ts - each records/.backlog.md.lock as ac-task.sh
//      takes it, AC_TASK_LOCK_TIMEOUT secs, default 10), the parent's first
//      and then the deputy's: a live holder past the wait is `ERROR:
//      records/backlog.md is locked by another writer - nothing written` /
//      `ERROR: crewdeputy <dep>'s records/backlog.md is locked by another
//      writer - nothing written`, a records/ the lock cannot be made in
//      `ERROR: <that ledger> cannot be locked - its directory is not writable
//      - nothing written`; every check and write below reads both ledgers
//      inside them.
//   3. per id in argv order: `LC_ALL=C awk -v id=<id> '<FOUND_AWK>' <backlog>`
//      - the id is interpolated into a DYNAMIC ERE (W12: q.eep moves qkeep;
//      q[12] matches two rows) and `[x]` rows count; awk's own failure ends
//      handoff with its status (W18: a mode-000 ledger is `awk: can't open
//      file`, exit 2). Not exactly one match: `ERROR: no line (or more than
//      one) for '<id>' in <backlog>`; its section (cut at the found text's
//      first TAB - a row before any heading has none) other than `Queued`:
//      `ERROR: '<id>' sits under '## <section>', not '## Queued' - only queued
//      work can follow a domain`; `epic:` ANYWHERE in the line (W13, prose
//      too): `ERROR: '<id>' belongs to an epic - moving it would strand its
//      dependents in a ledger that cannot see it satisfied`. Then the
//      dependents, read by the backlog grammar in-process (src/backlog.ts
//      records() + acDoneline(), the AC_DONELINE_AWK program's reading under
//      LC_ALL=C, <id> as awk's -v read it): another row (`- [ ] ` or `- [x] `,
//      its own skipped) whose blockers list holds <id> exactly: `ERROR:
//      '<id>' is named in another line's blocked-by: - moving it would strand
//      that dependent`; a row whose blocked-by the grammar cannot read and
//      whose line holds <id> as a SUBSTRING (W13): `ERROR: '<id>' may be
//      named in a malformed blocked-by: - fix that line first
//      (docs/backlog.md)`; a ledger that cannot be read: `ERROR: cannot read
//      <backlog> to check '<id>' for dependents - nothing moved`.
// Then the writes, any failure ending handoff with its status:
//   4. recordsBackup("deputy-handoff") (src/lib.ts - the reversibility floor
//      every mutating records path respects):
//      state/backups/deputy-handoff-<epoch>[-<n>].tar.gz, or its WARN and
//      exit 1 with nothing moved; stdout `backup: <arc>`.
//   5. the moved lines, each LF-ended, to the temp <backlog>.moving.<pid>;
//      `awk 'NR == FNR { drop[$0] = 1; next } !($0 in drop)' <moving>
//      <backlog>` (the caller's locale) into <backlog>.tmp.<pid>, and `mv`
//      over the ledger; `LC_ALL=C awk -v f=<moving> '<INSERT_AWK>' <dbacklog>`
//      into <dbacklog>.tmp.<pid>, and `mv` - the lines APPENDED BYTE-
//      IDENTICALLY at the END of the deputy's Queued section, behind its own
//      queued work since queue order is meaningful: flushed before the next
//      heading - after the block's trailing blank line (W15) - or at EOF when
//      Queued is last (an unterminated last line gains its LF); `rm -f
//      <moving>`. A repeated id is checked twice and lands twice (W11). A
//      failure after the parent's mv strands the rows in neither ledger and
//      leaves <moving> (W17).
//   6. stdout the moved lines, then statusAppend(<dep>, `handoff: <ids>`)
//      UNGUARDED (<ids> as typed, comma-joined; state/<dep>.status, mirrored
//      to the task timeline only for a deputy with a meta), then `handed <ids>
//      to <dep>`, exit 0.
//
// HOMELESS (W1, reproduced): every `$(ac_home)` the bash swallowed prints the
// refusal again and goes on with "" - list: the refusal, then ABSENT, exit
// 0; validate: the refusal, exit 0; report: the refusal and the marker
// refusal; handoff: the refusal three times, then `ERROR: no crewdeputy
// '<dep>' in /crewdeputies.md`.
//
// EXIT: 0; 1 for every refusal; a child's status where its failure ended the
// bash under errexit (awk's 2, tr's, date's, mv's, 141 for SIGPIPE, 128+n
// for a signal, 127 for a child that could not start).
//
// SPAWNED, with the original's argv (stdin the caller's unless noted, stderr
// passed through): awk for the parse (deputyParse), each lookup, the found,
// drop and insert programs (the last two with stdout into their temp);
// `tr '\t' '\037'` (the parse's reader), `tr '\t\n' '  '` (the body on
// stdin); basename; `grep -q '^## Queued'`; mv, rm -f; date through iso(),
// wakePublish and statusAppend; mkdir -p, tar and rm through recordsBackup;
// awk, herdr or orca, and jq per probed entry (backendCall); and mkfifo,
// for the one pipe each `<parse> | <reader>` pair runs on (a private temp
// dir; with none to be had the pair runs one after the other).
//
// DIVERGENCES from the original, named in the differential leg:
// - THE LEDGER LOCKS (W8 of the domain dossier, fixed): handoff holds the
//   parent's and then the deputy's
//   records/.backlog.md.lock to the exit; the original took neither. So a
//   deputy records/ that cannot be written refuses before any write, where
//   the original stranded the rows in neither ledger (W17, for that cause). A
//   backup taken inside the parent's lock carries the lock dir.
// - EXCLUSIVE TEMPS (W16): <file>.moving.<pid> and <file>.tmp.<pid> are
//   created exclusively (the next .<n> past a name already taken) and the
//   ledger temps take the ledger's mode; the original wrote through whatever
//   sat at the predictable name and left a 0600 ledger 0644.
// - Bytes: argv arrives decoded, so a text byte that is not UTF-8 is U+FFFD
//   in the status line and the payload - under UTF-8 the original's tr
//   aborted on it (W7: exit 1, the status line written, no wake) where the
//   port publishes. A registry path that is not UTF-8 reaches a spawned
//   child's argv as U+FFFD; such a byte of a probed meta's backend= is U+FFFD
//   in AC_BACKEND, and so in the route's refusal.
// - A DRIVER THAT FAILED TO LOAD: the original's probe returned bash's 127
//   (UNOBSERVABLE); the port's probe is native and has no driver to lose.
// - THE PROBE'S STDIN: the original's probe ran inside the read loop, its
//   stdin the registry heredoc - an orca CLI reading stdin would have
//   swallowed the records after it; the port's driver children read
//   /dev/null.
// - The dependents check runs in-process, so the original's parser-failure
//   arm (a bun that cannot start: `ERROR: required tool not found: bun`,
//   `ERROR: the backlog parser failed on <f>`, then the refusal) is
//   unreachable - without bun the shim never starts.
// - The HOME RESOLUTION ruling: an AC_HOME that cannot be entered names the
//   variable (`ERROR: AC_HOME is not a readable directory: <h>`) wherever the
//   shell printed cd's own lines; exits and stdout alike.
// - Shell-own stderr is not reproduced: a failed redirection's
//   `Permission denied` line (an unwritable status log), `command not
//   found` - the exit statuses are.
//
// CALLERS: bin/ac-session-start.sh prints `list` under `-- crewdeputies
// (routing table) --` and, since list needs bun, degrades to a WARN naming
// this entry when it fails (pinned in tests/sh/ac-session-start.test.sh);
// the deputies-domains skill runs validate, list and handoff by hand; a
// deputy's kickoff (bin/ac-spawn.sh) tells it to answer through `report`
// from its own pane, whose PATH needs bun for that. tests/sh/
// ac-deputy-registry.test.sh pins the head-line TAB layout, the
// continuations, the recover text and the tally; the wake wire is
// bin/ac-wake-drain.sh's; the moved lines are byte-identical by contract.
import { appendFileSync, chmodSync, closeSync, constants, mkdtempSync, openSync, readFileSync, rmSync, statSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { acDoneline, records } from "./backlog.ts";
import {
  awkAssign,
  backendCall,
  backendName,
  deputyParse,
  deputyRegistry,
  die,
  enterCaller,
  envHome,
  isCrewdeputyHome,
  iso,
  ledgerLock,
  physicalDir,
  recordsBackup,
  shellStatus,
  softSubdir,
  spawnShell,
  spawnShellSync,
  statusAppend,
  taskBackend,
  taskMeta,
  wakePublish,
  warn,
} from "./lib.ts";

const REGISTRY_LABEL = "records/crewdeputies.md";
const US = "\x1f";

// The spawned programs, byte for byte as tests/fixtures/ac-deputy.sh holds
// them (tests/ts/deputy.test.ts lifts each one out of it).
const REPORT_LOOKUP_AWK = `$1 != "INVALID" && $2 == i { found = 1 } END { exit !found }`;
const HANDOFF_LOOKUP_AWK = `$1 != "INVALID" && $2 == i { print $3; exit }`;
const FOUND_AWK = String.raw`
      /^## / { sec = substr($0, 4); next }
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
      END { if (n == 1) printf "%s\t%s\n", s, l }
    `;
const DROP_AWK = `NR == FNR { drop[$0] = 1; next } !($0 in drop)`;
const INSERT_AWK = `
    inq && /^## / { while ((getline l < f) > 0) print l; inq = 0 }
    { print }
    /^## Queued/ { inq = 1 }
    END { if (inq) while ((getline l < f) > 0) print l }
  `;

// Byte strings (latin1) carry what the bash held as bytes; argv and paths
// arrive as UTF-8 strings and cross over here.
const b8 = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const u8 = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const fsPath = (s: string): Buffer => Buffer.from(s, "latin1");
// `$(...)`: NULs dropped, trailing newlines cut.
const subst = (b: Uint8Array): string => Buffer.from(b).toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");

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

function run(cmd: string[], stdin: "inherit" | "ignore" | Buffer, stdout: "inherit" | "pipe" | number): { status: number; out: Buffer } {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(cmd, { stdin, stdout, stderr: "inherit" });
  } catch {}
  return { status: shellStatus(r), out: stdout === "pipe" && r ? Buffer.from(r.stdout) : Buffer.alloc(0) };
}

// `<a> | <b>` under pipefail: both children at once on one kernel pipe (a FIFO
// in a private temp dir, unlinked once both ends are open), so a reader that
// exits early ends a writer still writing with SIGPIPE - 141 - as it ended
// the bash's; the status is b's when it is non-zero, else a's. A null writer
// (deputyParse's no-file arm) feeds b nothing. With no FIFO to be had the
// two run one after the other, which only a writer outliving its reader
// could tell apart.
async function pipeline(a: string[] | null, b: string[]): Promise<{ status: number; out: Buffer }> {
  if (a === null) return run(b, "ignore", "pipe");
  let dir = "";
  try {
    dir = mkdtempSync(`${tmpdir()}/.ac-deputy.`);
  } catch {}
  if (dir === "" || run(["mkfifo", `${dir}/pipe`], "ignore", "inherit").status !== 0) {
    if (dir !== "") rmSync(dir, { recursive: true, force: true });
    const w = run(a, "inherit", "pipe");
    const r = run(b, w.out, "pipe");
    return { status: r.status !== 0 ? r.status : w.status, out: r.out };
  }
  const fifo = `${dir}/pipe`;
  const nb = openSync(fifo, constants.O_RDONLY | constants.O_NONBLOCK);
  const wfd = openSync(fifo, constants.O_WRONLY);
  const rfd = openSync(fifo, constants.O_RDONLY);
  closeSync(nb);
  rmSync(dir, { recursive: true, force: true });
  let reader: ReturnType<typeof Bun.spawn> | null = null;
  let writer: ReturnType<typeof Bun.spawn> | null = null;
  try {
    reader = spawnShell(b, { stdin: rfd, stdout: "pipe", stderr: "inherit" });
  } catch {}
  try {
    writer = spawnShell(a, { stdin: "inherit", stdout: wfd, stderr: "inherit" });
  } catch {}
  closeSync(rfd);
  closeSync(wfd);
  const text = reader ? Buffer.from(await new Response(reader.stdout as ReadableStream).arrayBuffer()) : Buffer.alloc(0);
  if (reader) await reader.exited;
  if (writer) await writer.exited;
  const sb = shellStatus(reader);
  return { status: sb !== 0 ? sb : shellStatus(writer), out: text };
}

// `IFS=$'\037' read -r v1 ... vn`: fields split at each US, the last name
// taking the rest of the line, missing fields empty. bash 3.2 also drops one
// trailing US from that rest, which no field printed here can end in.
function readUS(line: string, n: number): string[] {
  const f = line.split(US);
  const v = [...f.slice(0, n - 1), f.slice(n - 1).join(US)];
  while (v.length < n) v.push("");
  return v;
}

// The parse re-separated with US before any read (`| tr '\t' '\037'`): a TAB
// is IFS whitespace and `read` would collapse the empty fields of an INVALID
// record into a shift of every later one.
function parsedRecords(file: string): Promise<{ status: number; out: Buffer }> {
  return pipeline(deputyParse(file), ["tr", "\\t", US]);
}

function deputyState(id: string, home: string): string {
  if (!isDir(fsPath(home)) || !isFile(fsPath(`${home}/.ac-crewdeputy-home`))) return "HOME-MISSING";
  if (!isFile(taskMeta(u8(id)))) return "NOT-RUNNING";
  const saved = process.env.AC_BACKEND;
  // taskBackend answers bytes; AC_BACKEND carries the text they spell, as the
  // shell's export did.
  process.env.AC_BACKEND = u8(taskBackend(u8(id)));
  const r = backendCall("window_alive", [u8(id)], { stdin: "ignore", stdout: "pipe", stderr: "inherit", subshell: true });
  if (saved === undefined) delete process.env.AC_BACKEND;
  else process.env.AC_BACKEND = saved;
  const word = r.status === 0 ? "LIVE" : r.status === 1 ? "DOWN" : "UNOBSERVABLE";
  return subst(Buffer.concat([r.out, Buffer.from(`${word}\n`)]));
}

async function cmdList(): Promise<number> {
  const reg = deputyRegistry();
  if (!isFile(reg)) {
    out(`ABSENT: ${REGISTRY_LABEL} - no crewdeputies registered\n`);
    return 0;
  }
  const p = await parsedRecords(reg);
  if (p.status !== 0) return p.status;
  const recs = subst(p.out);
  if (recs === "") {
    out(`EMPTY: ${REGISTRY_LABEL} present, 0 entries - no crewdeputies registered\n`);
    return 0;
  }
  let n = 0;
  let live = 0;
  let down = 0;
  let notrun = 0;
  let missing = 0;
  let invalid = 0;
  for (const line of recs.split("\n")) {
    const [cls, id, home, charter, scope, projects, reason] = readUS(line, 7) as [string, string, string, string, string, string, string];
    if (cls === "") continue;
    n++;
    if (cls === "INVALID") {
      invalid++;
      out(`INVALID\t${id}\treason: ${reason}\n`);
      continue;
    }
    const state = deputyState(id, home);
    if (state === "LIVE") live++;
    else if (state === "DOWN") down++;
    else if (state === "NOT-RUNNING") notrun++;
    else if (state === "HOME-MISSING") missing++;
    out(`${state}\t${id}\thome: ${home}\tprojects: ${projects}\n`);
    out(`\tcharter: ${charter}\n`);
    out(scope !== "" ? `\tscope: ${scope}\n` : "\tscope: (unset - not routable until a scope: is added)\n");
    if (state === "DOWN" || state === "NOT-RUNNING") out(`\trecover: bin/ac-spawn.sh ${id} --crewdeputy --recover\n`);
  }
  out(`registered: ${n} (live ${live}, down ${down}, not-running ${notrun}, home-missing ${missing}, invalid ${invalid})\n`);
  return 0;
}

async function cmdValidate(): Promise<number> {
  const reg = deputyRegistry();
  if (!isFile(reg)) return 0;
  let rc = 0;
  for (const line of subst((await parsedRecords(reg)).out).split("\n")) {
    const [cls, id, , , , , reason] = readUS(line, 7);
    if (cls !== "INVALID") continue;
    out(`INVALID ${id}: ${reason}\n`);
    rc = 1;
  }
  return rc;
}

async function cmdReport(args: string[]): Promise<number> {
  const text = b8(args[0] ?? "");
  let doc = "";
  for (let i = 1; i < args.length; ) {
    if (args[i] !== "--doc") fail(`unknown argument: ${b8(args[i]!)}`);
    if (i + 1 >= args.length) fail("--doc needs a value");
    doc = b8(args[i + 1]!);
    i += 2;
  }
  if (text === "") fail("usage: ac-deputy.sh report '<text>' [--doc <abs-path>]");
  if (!isCrewdeputyHome()) fail("report runs INSIDE a crewdeputy home (no .ac-crewdeputy-home marker here)");
  const home = envHome();
  const base = run(["basename", home], "inherit", "pipe");
  if (base.status !== 0) return base.status;
  const id = subst(base.out);
  const parent = physicalDir(`${home}/../..`) ?? "";
  if (parent === "" || !isDir(`${parent}/state`))
    fail(`cannot resolve a parent fleet above ${b8(home)} - refusing to write a return with nowhere to land`);
  if (doc !== "" && !doc.startsWith("/")) fail(`--doc must be an absolute path (the parent resolves it from its own home): ${doc}`);

  const body = doc !== "" ? `${text} doc: ${doc}` : text;
  const lookup = await pipeline(deputyParse(`${parent}/records/crewdeputies.md`), ["awk", "-F\\t", "-v", `i=${u8(id)}`, REPORT_LOOKUP_AWK]);
  if (lookup.status !== 0) warn(Buffer.from(`no registry entry for ${id} in the parent's routing table - delivering the return anyway`, "latin1"));
  // `$(ac_iso)` sat in printf's arguments: a date that could not start was an
  // empty stamp, never the end of the run.
  let stamp = "";
  try {
    stamp = iso();
  } catch {}
  try {
    appendFileSync(fsPath(`${b8(parent)}/state/${id}.status`), Buffer.from(`${stamp} report: ${body}\n`, "latin1"));
  } catch {
    return 1;
  }
  const folded = run(["tr", "\\t\\n", "  "], Buffer.from(body, "latin1"), "pipe");
  if (folded.status !== 0) return folded.status;
  let published = false;
  try {
    published = wakePublish(`${parent}/state`, "", "deputy", id, subst(folded.out), true);
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
  if (!published) return 1;
  out(`reported ${id} to ${b8(parent)}\n`);
  return 0;
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

// An awk whose stdout the bash redirected into <file>.tmp.$$: the temp is
// claimed with <file>'s mode, the awk's status ends the run as errexit did,
// and a spawned mv lands it.
function rewrite(file: string, awk: string[]): void {
  let t: { path: string; fd: number };
  try {
    t = claimTemp(file, "tmp", modeOf(file));
  } catch {
    process.exit(1);
  }
  const r = run(awk, "inherit", t.fd);
  closeSync(t.fd);
  if (r.status !== 0) process.exit(r.status);
  const mv = run(["mv", u8(t.path), u8(file)], "inherit", "inherit");
  if (mv.status !== 0) process.exit(mv.status);
}

async function cmdHandoff(args: string[]): Promise<number> {
  const dep = args[0] ?? "";
  const items = args.slice(1);
  if (dep === "" || items.length === 0) fail("usage: ac-deputy.sh handoff <deputy-id> <backlog-id>...");
  if (isCrewdeputyHome()) fail("handoff runs in the PARENT fleet home, not inside a crewdeputy home");

  const look = await pipeline(deputyParse(), ["awk", "-F\\t", "-v", `i=${dep}`, HANDOFF_LOOKUP_AWK]);
  if (look.status !== 0) return look.status;
  const home = subst(look.out);
  if (home === "") fail(`no crewdeputy '${b8(dep)}' in ${b8(deputyRegistry())}`);
  if (!isDir(fsPath(home))) fail(`crewdeputy home is gone: ${home}`);
  const depBacklog = `${home}/records/backlog.md`;
  if (!isFile(fsPath(depBacklog))) fail(`crewdeputy ${b8(dep)} has no records/backlog.md to hand work into`);
  if (run(["grep", "-q", "^## Queued", u8(depBacklog)], "inherit", "inherit").status !== 0)
    fail(`crewdeputy ${b8(dep)} has no '## Queued' section in its backlog`);
  const backlog = b8(`${softSubdir("records", true)}/backlog.md`);
  if (!isFile(fsPath(backlog))) fail(`no parent backlog at ${backlog}`);
  // Parent first, then the deputy: one order for every writer that takes both.
  for (const [dir, ledger] of [
    [`${softSubdir("records", true)}/.backlog.md.lock`, "records/backlog.md"],
    [u8(`${home}/records/.backlog.md.lock`), `crewdeputy ${b8(dep)}'s records/backlog.md`],
  ]) {
    const locked = ledgerLock(dir!, ledger!);
    if (locked !== null) fail(locked);
  }

  let moving = "";
  let ids = "";
  for (const arg of items) {
    const item = b8(arg);
    const f = run(["/usr/bin/env", "LC_ALL=C", "awk", "-v", `id=${arg}`, FOUND_AWK, u8(backlog)], "inherit", "pipe");
    if (f.status !== 0) return f.status;
    const found = subst(f.out);
    if (found === "") fail(`no line (or more than one) for '${item}' in ${backlog}`);
    const tab = found.indexOf("\t");
    const section = tab < 0 ? found : found.slice(0, tab);
    const line = tab < 0 ? found : found.slice(tab + 1);
    if (section !== "Queued") fail(`'${item}' sits under '## ${section}', not '## Queued' - only queued work can follow a domain`);
    if (line.includes("epic:"))
      fail(`'${item}' belongs to an epic - moving it would strand its dependents in a ledger that cannot see it satisfied`);
    switch (dependents(backlog, awkAssign(item))) {
      case 0:
        break;
      case 3:
        fail(`'${item}' is named in another line's blocked-by: - moving it would strand that dependent`);
      case 4:
        fail(`'${item}' may be named in a malformed blocked-by: - fix that line first (docs/backlog.md)`);
      default:
        fail(`cannot read ${backlog} to check '${item}' for dependents - nothing moved`);
    }
    moving += `${line}\n`;
    ids = ids === "" ? item : `${ids},${item}`;
  }

  const arc = recordsBackup("deputy-handoff");
  if (arc === null) return 1;
  out(`backup: ${arc}\n`);
  let mv: { path: string; fd: number };
  try {
    mv = claimTemp(backlog, "moving", null);
    writeSync(mv.fd, Buffer.from(moving, "latin1"));
    closeSync(mv.fd);
  } catch {
    return 1;
  }
  rewrite(backlog, ["awk", DROP_AWK, u8(mv.path), u8(backlog)]);
  rewrite(depBacklog, ["/usr/bin/env", "LC_ALL=C", "awk", "-v", `f=${u8(mv.path)}`, INSERT_AWK, u8(depBacklog)]);
  const rm = run(["rm", "-f", u8(mv.path)], "inherit", "inherit");
  if (rm.status !== 0) return rm.status;
  out(moving);
  let appended = false;
  try {
    appended = statusAppend(dep, `handoff: ${ids}`, true);
  } catch (e) {
    return (e as { status?: number }).status ?? 1;
  }
  if (!appended) return 1;
  out(`handed ${ids} to ${b8(dep)}\n`);
  return 0;
}

// The dependents read of the AC_DONELINE_AWK program, in-process on
// src/backlog.ts: a row (`- [ ] ` / `- [x] `) other than <id>'s own naming it
// in its blockers is 3; one whose blocked-by the grammar cannot read and
// whose line holds <id> anywhere is 4 - the first such row answers; a ledger
// that cannot be read is 2. <id> is awk's -v reading of the item.
function dependents(backlog: string, id: string): number {
  let text: string;
  try {
    text = readFileSync(fsPath(backlog), "latin1");
  } catch {
    return 2;
  }
  for (const rec of records(text)) {
    if (!/^- \[[ x]\] /.test(rec)) continue;
    const o = acDoneline(rec);
    if (o.id === id) continue;
    if (o.blockers !== "" && o.blockers.split(",").includes(id)) return 3;
    if (o.blockers_malformed !== "" && rec.includes(id)) return 4;
  }
  return 0;
}

const { args } = enterCaller(process.argv.slice(2));
backendName();
const verb = args[0] ?? "";
const rc =
  verb === "list"
    ? await cmdList()
    : verb === "validate"
      ? await cmdValidate()
      : verb === "report"
        ? await cmdReport(args.slice(1))
        : verb === "handoff"
          ? await cmdHandoff(args.slice(1))
          : die("usage: ac-deputy.sh <list|validate|report|handoff>");
process.exit(rc);
