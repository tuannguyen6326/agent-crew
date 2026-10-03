// home-seed.ts - provision a persistent crewdeputy home. The entry is
// bin/ac-home-seed.sh (a shim that starts this file through bin/ac-bun.sh);
// THIS header is the authoritative spec, and the bash original it replaced
// stays frozen at tests/fixtures/ac-home-seed.sh as the oracle the differential
// leg of tests/sh/ac-home-seed.test.sh holds this module to.
//
//   ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)
//
// <name> is always the first word. The rest: `--projects <v>` (the last one
// wins), `--no-projects` (wins over a --projects given beside it, whose list
// is then ignored), anything else is refused. stdin is never read.
//
// Checks, in order; each refusal is `ERROR: <msg>` on stderr, exit 1, nothing
// written:
//   1. `required tool not found: git` (before any argument is looked at)
//   2. `unknown argument: <w>` (the words after the name, in order; a
//      `--projects` with no value is refused with the usage line of 3 - the
//      bash aborted on an unbound variable there, exit 1 with shell noise)
//   3. `usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)`
//      (empty name)
//   4. `name must be [a-z0-9-]: <name>` (ASCII classes; `--no-projects` as the
//      name passes this and fails 5)
//   5. `pass --projects <p1,p2,...> or --no-projects explicitly` (neither
//      given, or `--projects ''`)
//   6. `AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding
//      state/ data/ records/ config/ projects/); the distro checkout is not
//      one`; an AC_HOME that is set but cannot be entered is refused by envHome
//      (`AC_HOME is not a readable directory: <h>`), exit 1 - the bash printed
//      only cd's own noise there
//   7. `home already exists: <parent>/crewdeputies/<name>` (a file or a
//      resolving symlink counts, as `[ -e ]`)
//   8. per requested project, `parent has no clone at projects/<p>` unless
//      <parent>/projects/<p>/.git is a directory (a worktree's .git FILE is
//      refused). The list is the --projects value up to its first newline,
//      split on `,`, every SPACE deleted (tabs kept), empties skipped, order
//      and duplicates kept; a name carrying a tab or a glob character is taken
//      literally (the bash re-split and glob-expanded it unquoted).
//
// Effects, in order, no rollback (a failure midway leaves a partial home that
// check 7 then refuses to redo); a spawned binary that fails (git, cp, ln)
// ends the run with ITS status and stderr, as `set -e` did:
//   a. state/ data/ records/ config/ projects/ under the home, and the empty
//      .ac-crewdeputy-home marker (ac_is_crewdeputy_home reads it)
//   b. seedRuntimeLinks: bin CLAUDE.md .claude AGENTS.md linked to the distro
//      root so the chief runs with cwd = home (workspace = home, repo = code)
//   c. the parent's config knobs copied by basename with plain `cp` (content
//      and mode through umask; macOS cp carries xattrs/ACLs): backend
//      crew-harness crew-dispatch.json herdr-session wedge-alarm captain flow
//      promote, each when a regular file, then every regular config/launch-*
//      in byte order. Workspace ids are deliberately absent: the retired
//      herdr-workspace* knobs are never read (ac-backend.sh FAMILY WORKSPACE
//      GROUPING resolves workspaces adopt-by-label per fleet). herdr-session
//      IS inherited: the herdr server session is shared across homes.
//   d. the parent's CREWMATE.md copied when it is a regular file
//   e. records/projects.md := `# Projects\n\n`; records/backlog.md :=
//      `# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n`
//   f. the parent's records/captain.md copied when it is a regular file (the
//      parent's records/ is minted here, as ac_records_dir did). Config knobs
//      stay CONVERGED (parent wins every session, ac_config_converge_from_parent);
//      CREWMATE.md and captain.md are one-time SEED-COPIES the deputy owns
//      afterwards, so a later session never clobbers its local additions.
//   g. per project in list order: `git clone --quiet <parent>/projects/<p>
//      <home>/projects/<p>`; origin re-pointed at the parent clone's origin URL
//      when it has one (so the deputy pushes to the real remote); one line
//      appended to records/projects.md - the first line of the parent's
//      records/projects.md whose blank-separated fields read `-`, <p>, then
//      `-` or a `[`-led token, byte for byte, else `- <p> - inherited from
//      parent (added <iso>)` (bin/ac-project-mode.sh header: the bracket is
//      optional and a legacy mode is never minted). A duplicated <p> fails its
//      second clone (git exit 128).
//   h. the parent's records/crewdeputies.md, created as `# Crewdeputies\n\n`
//      when absent, gets `- <name> - (charter unset - one line on what this
//      crewdeputy is for) - home: <home> - scope: - projects: <p1,p2|none>
//      (added <iso>)` - the routing-table grammar of bin/ac-lib.sh's
//      `crewdeputy routing table` block. Seeding cannot know the SCOPE (what
//      work a deputy owns is the chief's judgment), so the field is EMPTY,
//      which is exactly what makes the entry non-routable.
//   i. stdout `<home>\n` (<parent> is the physical AC_HOME); stderr `WARN:
//      seeded crewdeputy home <name>; spawn with: ac-spawn.sh <name>
//      --crewdeputy` then `WARN: fill in charter and scope: for <name> in
//      <parent>/records/crewdeputies.md - an entry with no scope: is never
//      routed work`; exit 0.
//
// <iso> is date(1)'s `-u +%Y-%m-%dT%H:%M:%SZ`, read once per line that needs
// it. Lines carried from the parent's projects.md are read and written as
// bytes (latin1); the home path is printed as Bun names it.
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { die, enterCaller, envHome, iso, recordsDir, seedRuntimeLinks, warn } from "./lib.ts";

const KNOBS = ["backend", "crew-harness", "crew-dispatch.json", "herdr-session", "wedge-alarm", "captain", "flow", "promote"];

const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

// `IFS=',' read -ra` WITHOUT -r: a backslash escapes the next byte (an escaped
// comma is no separator), a backslash-newline is a continuation, an unescaped
// newline ends the line; then `tr -d ' '` per entry, empties skipped.
export function splitProjects(projects: string): string[] {
  const entries: string[] = [];
  let cur = "";
  for (let i = 0; i < projects.length; i++) {
    const c = projects[i];
    if (c === "\\") {
      const n = projects[i + 1];
      if (n === undefined) break;
      i++;
      if (n !== "\n") cur += n;
    } else if (c === "\n") break;
    else if (c === ",") {
      entries.push(cur);
      cur = "";
    } else cur += c;
  }
  entries.push(cur);
  return entries.map((p) => p.replace(/ /g, "")).filter((p) => p !== "");
}

// A project name arrives native from Bun's argv; its bytes are what the file
// is compared with and what the default line carries.
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");

// The awk's default field splitting under LC_ALL=C: blanks are space and tab,
// a leading run is skipped, and the record is printed whole - a CR or leading
// indentation travels with it.
export function registryLine(file: string, p: string): string {
  let text: string;
  try {
    text = readFileSync(file, "latin1");
  } catch {
    return "";
  }
  const pB = bytes(p);
  for (const line of text.split("\n")) {
    const f = line.replace(/^[ \t]+/, "").split(/[ \t]+/);
    if (f[0] === "-" && f[1] === pB && (f[2] === "-" || (f[2] ?? "").startsWith("["))) return line;
  }
  return "";
}

// A spawned binary speaks for itself on stderr and, failing, ends the run
// with its status - `set -e` in the bash original.
function run(cmd: string[]): void {
  const r = Bun.spawnSync(cmd, { stdin: "ignore", stdout: "inherit", stderr: "inherit" });
  if (r.exitCode !== 0) process.exit(r.exitCode ?? 1);
}

function main(args: string[]): void {
  if (!Bun.which("git")) die("required tool not found: git");
  const name = args[0] ?? "";
  let projects = "";
  let noProjects = false;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--projects") {
      if (i + 1 >= args.length) die("usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)");
      projects = args[++i];
    } else if (args[i] === "--no-projects") noProjects = true;
    else die(`unknown argument: ${args[i]}`);
  }
  if (!name) die("usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)");
  if (!/^[a-z0-9-]*$/.test(name)) die(`name must be [a-z0-9-]: ${name}`);
  if (!noProjects && projects === "") die("pass --projects <p1,p2,...> or --no-projects explicitly");

  if (!process.env.AC_HOME)
    die("AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one");
  const parent = envHome();
  const home = join(parent, "crewdeputies", name);
  if (existsSync(home)) die(`home already exists: ${home}`);

  const requested = noProjects ? [] : splitProjects(projects);
  for (const p of requested) {
    // The spelling is the caller's: `missing/../alpha` must fail at the OS, as
    // `[ -d ]` had it, not be folded to `alpha` first.
    if (!isDir(`${parent}/projects/${p}/.git`)) die(`parent has no clone at projects/${p}`);
  }

  for (const d of ["state", "data", "records", "config", "projects"]) mkdirSync(join(home, d), { recursive: true });
  writeFileSync(join(home, ".ac-crewdeputy-home"), "");
  seedRuntimeLinks(home);

  let launches: string[] = [];
  try {
    launches = readdirSync(join(parent, "config"))
      .filter((n) => n.startsWith("launch-"))
      .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  } catch {}
  for (const knob of [...KNOBS, ...launches]) {
    const src = join(parent, "config", knob);
    if (isFile(src)) run(["cp", src, join(home, "config", knob)]);
  }
  if (isFile(join(parent, "CREWMATE.md"))) run(["cp", join(parent, "CREWMATE.md"), join(home, "CREWMATE.md")]);

  writeFileSync(join(home, "records", "projects.md"), "# Projects\n\n");
  writeFileSync(join(home, "records", "backlog.md"), "# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n");

  const pcaptain = join(recordsDir(), "captain.md");
  if (isFile(pcaptain)) run(["cp", pcaptain, join(home, "records", "captain.md")]);

  const cloned: string[] = [];
  for (const p of requested) {
    const src = `${parent}/projects/${p}`;
    const dst = `${home}/projects/${p}`;
    run(["git", "clone", "--quiet", src, dst]);
    const origin = Bun.spawnSync(["git", "-C", src, "remote", "get-url", "origin"], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
      .stdout.toString().replace(/\n+$/, "");
    if (origin !== "") run(["git", "-C", dst, "remote", "set-url", "origin", origin]);
    const line = registryLine(join(recordsDir(), "projects.md"), p) || `- ${bytes(p)} - inherited from parent (added ${iso()})`;
    appendFileSync(join(home, "records", "projects.md"), Buffer.from(`${line}\n`, "latin1"));
    cloned.push(p);
  }

  const reg = join(recordsDir(), "crewdeputies.md");
  if (!isFile(reg)) writeFileSync(reg, "# Crewdeputies\n\n");
  appendFileSync(
    reg,
    `- ${name} - (charter unset - one line on what this crewdeputy is for) - home: ${home} - scope: - projects: ${cloned.join(",") || "none"} (added ${iso()})\n`,
  );

  writeSync(1, `${home}\n`);
  warn(`seeded crewdeputy home ${name}; spawn with: ac-spawn.sh ${name} --crewdeputy`);
  warn(`fill in charter and scope: for ${name} in ${reg} - an entry with no scope: is never routed work`);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  // Without the caller's cwd a relative AC_HOME would resolve inside the
  // distro checkout, and the home would be seeded there.
  const h = process.env.AC_HOME ?? "";
  if (!atCaller && h !== "" && !h.startsWith("/")) die("the current directory cannot be resolved, so a relative AC_HOME cannot be either");
  main(args);
}
