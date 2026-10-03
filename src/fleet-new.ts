// fleet-new.ts - create a new top-level FLEET home under the homes container.
// The entry is bin/ac-fleet-new.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-fleet-new.sh as the oracle the
// differential leg of tests/sh/ac-fleet-new.test.sh holds this module to.
//
//   ac-fleet-new.sh [<name>] [--container <dir>]
//   ac-fleet-new.sh -h | --help
//
// A fleet home is what AC_HOME points at. This is the top-level sibling of
// bin/ac-home-seed.sh, which seeds a CREWDEPUTY home nested inside a parent
// fleet and INHERITS the parent's knobs. A fleet has no parent to inherit from,
// so every knob is asked here instead.
//
// INTERACTIVE by design - a CAPTAIN tool, not crew tooling: one line per knob.
// Answers are read from plain stdin, so a heredoc drives it unattended (that is
// how tests/sh/ac-fleet-new.test.sh drives it). stdin at EOF is an error, never a
// silent run on defaults: a fleet nobody described is worse than no fleet.
// Name, container and the already-exists refusal are all resolved BEFORE the
// first question, so a doomed run never spends the captain's answers.
//
// Arguments, scanned in order (the first hit decides): `-h`/`--help` prints
// this header on stdout, exit 0; `--container <dir>` (the last one wins; a
// missing or EMPTY value is `ERROR: --container needs a path`, exit 1 - the
// bash's `${2:?}` printed its own `<path>: line 59: 2: ...` there, shell-own
// stderr not reproduced); any other `-*` word is `ERROR: unknown argument: <w>`;
// a second bare word is `ERROR: unexpected argument: <w>`; exit 1 each. An
// empty bare word counts as no name.
//
// stdin is read as `IFS= read -r` read it: one line per answer, bytes kept as
// typed (a backslash, surrounding spaces and a trailing CR are value bytes; a
// NUL ends the value and the rest of that line is dropped), read one byte at a
// time from fd 0 so nothing past the answer is consumed. An UNTERMINATED last
// line is refused like EOF - its bytes are discarded, as `read` discarded them.
// Every prompt is `<prompt>: ` on STDERR with no newline, so a scripted run's
// prompts concatenate on one stderr line. EOF at any prompt: `\n` then
// `ERROR: stdin closed while asking: <prompt>` on stderr, exit 1, no home
// minted (every prompt precedes the seed).
//
// Before the first knob question, in order:
//   name   a given name must match [a-zA-Z0-9_-] per the TEXT, else `ERROR:
//          name must be [a-zA-Z0-9_-]: <name>` exit 1 (NAMED DIVERGENCE: bash
//          3.2's `[!a-zA-Z0-9_-]` under a UTF-8 locale accepts `é`, `ü`, `ñ`
//          by range collation and minted such a fleet; under LC_ALL=C both
//          refuse). No name: `fleet name` is asked until a valid one arrives -
//          `a fleet needs a name` for an empty answer, `name must be
//          [a-zA-Z0-9_-]: <answer>` for a bad one, each on stderr, then the
//          prompt again.
//   container  `--container`, else the answer to `homes container [<default>]`
//          where <default> is $AC_HOMES_CONTAINER when non-empty, else
//          $HOME/Work/ac-homes; an empty answer takes <default>. A leading `~`
//          is expanded against $HOME (`~` and `~/...` only; `~x` stays a
//          literal name under the cwd); no other shell expansion. HOME unset
//          where it is needed (the default, or a `~` form) is `ERROR: HOME is
//          not set` exit 1 (the bash died on `set -u`'s own line); HOME empty
//          is a value (`~/x` -> `/x`). Then `mkdir -p <container>` is spawned -
//          its own stderr and exit 1 when it fails (a FILE there: `mkdir:
//          <path>: File exists`) - and the container is bound PHYSICALLY (`cd
//          && pwd -P`; a relative path resolves against the caller's cwd; one
//          that cannot be entered is `ERROR: homes container is not a readable
//          directory: <c>` exit 1 where the bash printed cd's own line - the
//          HOME RESOLUTION ruling, LF-named and CDPATH artifacts included).
//   home   <container>/<name>; `ERROR: fleet home already exists: <home>` exit
//          1 when `[ -e ]` is true (a file counts; a DANGLING symlink does NOT
//          - the questions are then asked and the seed's `mkdir -p <home>`
//          fails with mkdir's own `No such file or directory`, exit 1, after
//          the captain's answers: the bash's wart, kept).
//
// Then `\n== <name>: config knobs (empty = keep the shown default) ==\n` on
// stderr and nine questions, each answered by one line (an enum re-asks until
// the answer is one of its values, exact and case-sensitive, or empty: `not
// one of: <v1 v2 ...> (or empty)\n` on stderr, then the prompt again):
//   captain name (empty: the crewchief just says "captain")              free text
//   crewmate model (empty: claude picks its own)                         free text
//   crewmate effort low|medium|high|xhigh|max|ultracode (empty: claude picks its own)
//                                                                        enum
//   design-gate judge codex|claude|off (empty: codex)                    enum
//   gate judge model (empty: the engine picks its own)                   free text
//   gate judge effort (empty: the engine picks its own)                  free text
//   roomchief promotion always|auto|never (empty: always)                enum
//   task flow auto|direct|staged (empty: auto)                           enum
//   seed a per-fleet CREWMATE.md yes|no (empty: no - inherit the container-wide .claude/CLAUDE.md)
//                                                                        enum
// Each knob's OWNER stays the authority on its meaning: captain (AGENTS.md
// section 1), model and effort (ac-spawn.sh), gate-agent/gate-model/gate-effort
// (ac-gate.sh), promote (rooms-threads skill), flow (AGENTS.md section 5).
//
// The seed, effects in order, no rollback (a spawned binary that fails ends the
// run with its own stderr and status, as `set -e` did):
//   a. `mkdir -p <home>` spawned
//   b. config/ records/ state/ data/ projects/ through the src/lib.ts twins of
//      ac-lib.sh's path helpers (configDir, recordsDir, stateDir, dataDir,
//      projectsDir, each run with AC_HOME=<home>; the caller's own AC_HOME is
//      never read) - the twins ARE the layout ac-lib.sh defines, so this file
//      cannot drift from it
//   c. config/backend := `herdr\n`, unasked - the default backend (orca is the
//      per-fleet opt-in)
//   d. a knob file `<value>\n` for captain model effort gate-agent gate-model
//      gate-effort promote flow ONLY when the answer was non-empty (a
//      whitespace-only answer IS written - the bash's `[ -n ]`, kept; readers
//      trim it to "" without falling back to their default). An absent file is
//      not a gap: every reader resolves `ac_config_read <knob> <default>`, so
//      absence IS that default and config/ holds exactly what was chosen.
//   e. records/projects.md := `# Projects\n\n`; records/backlog.md :=
//      `# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n`
//   f. seedRuntimeLinks: bin CLAUDE.md .claude AGENTS.md linked to the distro
//      root (`ln -sfn`; a REAL entry left alone) so the chief runs with cwd =
//      home. Its bash original ac_seed_runtime_links is RETIRED with this port
//      (this entry was its last caller) and frozen at
//      tests/fixtures/ac-seed-runtime-links.sh for the oracles.
//   g. <root>/docs/examples/CREWMATE.md copied to <home>/CREWMATE.md by `cp`
//      when the last answer was `yes` - a per-fleet CREWMATE.md WINS over the
//      container-wide .claude/CLAUDE.md (ac-spawn.sh owns that order), so it
//      is seeded only when asked for
//   h. stdout `<home>\n` (the run's ONLY stdout), then on stderr
//      `\nNEXT:\n  ac <name>                    # via the launcher (bin/ac-setup.sh installs it)\n`
//      `  AC_HOME=<home> claude   # or point a harness at it directly\n`
//      `\nThe crewchief clones projects into <home>/projects/ on your word - do not pre-clone.\n`
// Exit 0. No workspace ids are seeded: the retired herdr-workspace* knobs are
// never read - ac-backend.sh (FAMILY WORKSPACE GROUPING) resolves every
// workspace adopt-by-label per fleet at runtime.
//
// Container = --container > $AC_HOMES_CONTAINER > ~/Work/ac-homes, shown on the
// prompt for confirmation. Deliberately NOT derived from $AC_HOME's parent (the
// rung the read-only ac-fleets.sh survey does use): run from the repo checkout
// that resolves to ~/Work, and this script CREATES directories.
//
// Bytes: an answer is written as its bytes; the name echoed in a refusal is
// the argv word as Bun decodes it (a non-UTF-8 byte reads as U+FFFD - refused
// either way, echoed differently; named) or the answer's bytes. A container
// answer holding a byte that is not UTF-8 is refused before mkdir (`ERROR:
// homes container holds a byte that is not UTF-8: <bytes>`, exit 1, nothing
// made) where the bash handed mkdir the bytes and this filesystem refused
// them with mkdir's own `Illegal byte sequence` (exit 1, nothing made) - the
// same result, the entry's line for the tool's (named). A child ended by a
// signal is 128+signal, as the shell read it. `-h` prints THIS header where the bash printed its own
// (the USAGE HEADER ruling). Callers: no bin/, src/, dashboard/ or skill
// runs this entry (bin/ac-setup.sh names its path as text; README.md and
// docs/getting-started.md show it to humans), so no set -e caller needs a
// fail-soft arm for the bun dependency.
import { existsSync, readFileSync, readSync, writeFileSync, writeSync } from "node:fs";
import { constants as osConstants } from "node:os";
import { resolve } from "node:path";
import { configDir, dataDir, die, enterCaller, physicalDir, projectsDir, recordsDir, seedRuntimeLinks, stateDir } from "./lib.ts";

const ROOT = resolve(import.meta.dir, "..");
const NAME_OK = /^[a-zA-Z0-9_-]*$/;

// `IFS= read -r` from fd 0, byte by byte so the fd stays positioned right after
// the answer's LF. null is EOF - which an unterminated last line also is: read
// returned 1 with the bytes in hand and the caller discarded them. A NUL ends
// the value (a C string), the rest of the line is consumed and dropped.
function readLine(): string | null {
  const b = Buffer.alloc(1);
  const out: number[] = [];
  let cut = false;
  for (;;) {
    let n = 0;
    try {
      n = readSync(0, b, 0, 1, null);
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code === "EAGAIN") {
        Bun.sleepSync(2);
        continue;
      }
      if (code !== "EOF") throw e;
    }
    if (n === 0) return null;
    if (b[0] === 10) return Buffer.from(out).toString("latin1");
    if (b[0] === 0) cut = true;
    if (!cut) out.push(b[0]!);
  }
}

// The answer as bytes (latin1), "" when the captain just hits Enter.
function ask(prompt: string): string {
  writeSync(2, `${prompt}: `);
  const ans = readLine();
  if (ans === null) {
    writeSync(2, "\n");
    die(`stdin closed while asking: ${prompt}`);
  }
  return ans;
}

// Empty is always accepted and means "write no knob file". Validating here is
// worth the echo of the owner's enum: a typo written into config/ would stay
// silent until the spawn or gate that reads the knob dies on it.
function askEnum(prompt: string, ...valid: string[]): string {
  for (;;) {
    const ans = ask(prompt);
    if (ans === "" || valid.includes(ans)) return ans;
    writeSync(2, `not one of: ${valid.join(" ")} (or empty)\n`);
  }
}

// Neither a typed answer nor a quoted --container value passes through the
// shell's own tilde expansion, so `~/Work/ac-homes` would otherwise mkdir a
// literal `~` under the cwd. No ~user form: this input is a path, not code.
export function untilde(p: string, home: string): string {
  if (p === "~") return home;
  if (p.startsWith("~/")) return `${home}/${p.slice(2)}`;
  return p;
}

function homeEnv(): string {
  return process.env.HOME ?? die("HOME is not set");
}

// The shell's status for a child: its exit, 128+signal when a signal ended it.
function run(cmd: string[]): void {
  const r = Bun.spawnSync(cmd, { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
  if (r.exitCode === 0) return;
  const sig = r.signalCode ? (osConstants.signals as Record<string, number>)[r.signalCode] ?? 0 : 0;
  process.exit(r.exitCode ?? 128 + sig);
}

function printHeader(): never {
  let out = "";
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    out += `${l.replace(/^\/\/ ?/, "")}\n`;
  }
  writeSync(1, out);
  process.exit(0);
}

function main(args: string[], atCaller: boolean): void {
  let name = "";
  let container = "";
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === "-h" || a === "--help") printHeader();
    else if (a === "--container") {
      const v = args[++i];
      if (v === undefined || v === "") die("--container needs a path");
      container = v;
    } else if (a.startsWith("-")) die(`unknown argument: ${a}`);
    else {
      if (name !== "") die(`unexpected argument: ${a}`);
      name = a;
    }
  }

  if (!NAME_OK.test(name)) die(`name must be [a-zA-Z0-9_-]: ${name}`);
  while (name === "") {
    const ans = ask("fleet name");
    if (ans === "") writeSync(2, "a fleet needs a name\n");
    else if (!NAME_OK.test(ans)) writeSync(2, Buffer.concat([Buffer.from("name must be [a-zA-Z0-9_-]: "), Buffer.from(ans, "latin1"), Buffer.from("\n")]));
    else name = ans;
  }

  if (container === "") {
    const dflt = process.env.AC_HOMES_CONTAINER || `${homeEnv()}/Work/ac-homes`;
    const raw = ask(`homes container [${dflt}]`);
    // The bash handed mkdir the bytes and this filesystem refused one that is
    // not UTF-8 (exit 1, nothing made); a spawn here carries text, so such an
    // answer is refused before mkdir rather than minted under U+FFFD.
    const text = Buffer.from(raw, "latin1").toString("utf8");
    if (Buffer.from(text, "utf8").toString("latin1") !== raw) die(Buffer.concat([Buffer.from("homes container holds a byte that is not UTF-8: "), Buffer.from(raw, "latin1")]));
    container = text || dflt;
  }
  if (container === "~" || container.startsWith("~/")) container = untilde(container, homeEnv());
  if (!atCaller && !container.startsWith("/")) die("the current directory cannot be resolved, so a relative container cannot be either");
  run(["mkdir", "-p", container]);
  const physical = physicalDir(container) ?? die(`homes container is not a readable directory: ${container}`);
  const home = `${physical}/${name}`;
  if (existsSync(home)) die(`fleet home already exists: ${home}`);

  writeSync(2, `\n== ${name}: config knobs (empty = keep the shown default) ==\n`);
  const captain = ask('captain name (empty: the crewchief just says "captain")');
  const model = ask("crewmate model (empty: claude picks its own)");
  const effort = askEnum("crewmate effort low|medium|high|xhigh|max|ultracode (empty: claude picks its own)", "low", "medium", "high", "xhigh", "max", "ultracode");
  const gateAgent = askEnum("design-gate judge codex|claude|off (empty: codex)", "codex", "claude", "off");
  const gateModel = ask("gate judge model (empty: the engine picks its own)");
  const gateEffort = ask("gate judge effort (empty: the engine picks its own)");
  const promote = askEnum("roomchief promotion always|auto|never (empty: always)", "always", "auto", "never");
  const flow = askEnum("task flow auto|direct|staged (empty: auto)", "auto", "direct", "staged");
  const crewmateMd = askEnum("seed a per-fleet CREWMATE.md yes|no (empty: no - inherit the container-wide .claude/CLAUDE.md)", "yes", "no");

  run(["mkdir", "-p", home]);
  const callerHome = process.env.AC_HOME;
  process.env.AC_HOME = home;
  const config = configDir();
  const records = recordsDir();
  stateDir();
  dataDir();
  projectsDir();
  if (callerHome === undefined) delete process.env.AC_HOME;
  else process.env.AC_HOME = callerHome;

  writeFileSync(`${config}/backend`, "herdr\n");
  const knobs: [string, string][] = [
    ["captain", captain], ["model", model], ["effort", effort], ["gate-agent", gateAgent],
    ["gate-model", gateModel], ["gate-effort", gateEffort], ["promote", promote], ["flow", flow],
  ];
  for (const [knob, value] of knobs) if (value !== "") writeFileSync(`${config}/${knob}`, Buffer.from(`${value}\n`, "latin1"));

  writeFileSync(`${records}/projects.md`, "# Projects\n\n");
  writeFileSync(`${records}/backlog.md`, "# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n");

  seedRuntimeLinks(home);

  if (crewmateMd === "yes") run(["cp", `${ROOT}/docs/examples/CREWMATE.md`, `${home}/CREWMATE.md`]);

  writeSync(1, `${home}\n`);
  writeSync(2, "\nNEXT:\n");
  writeSync(2, `  ac ${name}                    # via the launcher (bin/ac-setup.sh installs it)\n`);
  writeSync(2, `  AC_HOME=${home} claude   # or point a harness at it directly\n`);
  writeSync(2, `\nThe crewchief clones projects into ${home}/projects/ on your word - do not pre-clone.\n`);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  main(args, atCaller);
}
