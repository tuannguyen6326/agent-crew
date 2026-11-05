// home-carriers.ts - a fleet home NAMES ITSELF to every harness's hooks. The
// entry is bin/ac-home-carriers.sh (a shim that starts this file through
// bin/ac-bun.sh), run by bin/ac-session-start.sh on every writing session
// start; THIS header is the authoritative spec.
//
//   ac-home-carriers.sh            (no arguments; the home is $AC_HOME)
//
// WHY. A hook is spawned from the harness process's environment, and that
// environment carries AC_HOME only when the launch line put it there
// (`ac <fleet>`, a spawned roomchief's launch line). A hand-typed
// `claude --resume`, a harness reopened from its own session list, a pane
// relaunched by the backend: none of them carry it, and ac_home (bin/ac-lib.sh)
// refuses to guess - so every ac- hook of such a session exits 0 without a
// word, and nothing supervises it (the 2026-09-14 and 2026-11-02 incidents in
// the fleet's repo-knowledge). The name is not guessed here either: the seed
// below WRITES it into a file the home itself owns, which each harness reads
// from its project dir (cwd = home), so the hooks find the home from the
// home's own files whatever the launch line forgot.
//
// What one run does, per harness dir D in .claude .codex .cursor .opencode .pi:
//   1. <home>/D becomes a REAL directory: a symlink there (the runtime link
//      seedRuntimeLinks laid, src/lib.ts) is replaced; a real dir is kept; a
//      real non-directory is warned about and D is skipped.
//   2. every entry of <distro>/D whose name does not start with `.` and is
//      not D's carrier is linked at <home>/D/<name> (`ln -sfn` semantics: a
//      link, dangling or stale, is repointed; a REAL entry is a per-home
//      override and is left alone).
//   3. D's carrier, a home-owned file holding AC_HOME=<home> (the physical
//      home path):
//      - .claude/settings.local.json - `env.AC_HOME` (the `env` block applies
//        to the session and every subprocess, hooks included; the harness
//        writes a chief's "always allow" grants into this same file, so it is
//        SEEDED ONCE - from the distro's own settings.local.json when one
//        exists, else `{}` - and afterwards only its env.AC_HOME is pinned,
//        every other key kept). A file that is not JSON is kept as it is and
//        named on stderr. Shared no more: the distro's settings.local.json is
//        one file for every home, which is exactly what a per-home name
//        cannot live in.
//      - .codex/hooks.json, .cursor/hooks.json - the distro file with every
//        hook `command` prefixed `AC_HOME="${AC_HOME:-"<home>"}" ` (both
//        harnesses run the command as a shell string; shellDefault spells
//        the home so the shell reads it back verbatim). Absent in the distro,
//        absent here.
//      - .opencode/plugins/ac-home.js, .pi/extensions/ac-home.ts - a small
//        REAL module (a link would resolve to the distro path, and a module
//        named by `import.meta.url` would then name the wrong home) that
//        fills process.env.AC_HOME at load; opencode's also answers the
//        `shell.env` hook with that resolved value, so the chief's own shell
//        commands carry it.
//      A generated carrier (every one but claude's) is REWRITTEN whenever its
//      bytes differ from what the distro now yields, so the distro's hook set
//      moves on and the home follows at its next session start.
//   The carriers FILL a missing AC_HOME and keep a launch line's (`${AC_HOME:-}`,
//   `??=`); claude's env block has no such form, and the two agree for every
//   correctly launched session. Per-session words - AC_SCOPE, AC_SOLO,
//   AC_CHIEF_SOLO - stay on the launch line: a resumed session that carries
//   AC_HOME alone reads CHIEF-shaped, which the session-start nudge is the
//   place to name.
//
// Output: one `carried: D/<carrier>` line on stdout per carrier written this
// run (nothing on a converged home); warnings on stderr; exit 0. Refusals,
// `ERROR: <msg>` on stderr, exit 1: an argument given (`unknown argument:
// <w>`), AC_HOME unset (ac_home's own line), AC_HOME not enterable
// (envHome's). A link or mkdir that fails ends the run with its error.
import { existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, readlinkSync, symlinkSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { join, resolve } from "node:path";
import { die, enterCaller, envHome, warn } from "./lib.ts";

const ROOT = resolve(import.meta.dir, "..");

export const CARRIERS: Record<string, string> = {
  ".claude": "settings.local.json",
  ".codex": "hooks.json",
  ".cursor": "hooks.json",
  ".opencode": "plugins/ac-home.js",
  ".pi": "extensions/ac-home.ts",
};

// `AC_HOME="${AC_HOME:-"<home>"}"`: the default is its own double-quoted
// word (so a `}` in the home cannot close the expansion - measured on bash,
// sh and zsh), the home escaped for it: the four characters a shell still
// reads inside double quotes.
export function shellDefault(home: string): string {
  return `AC_HOME="\${AC_HOME:-"${home.replace(/[\\"$`]/g, (c) => `\\${c}`)}"}"`;
}

const lkind = (p: string): "absent" | "link" | "dir" | "other" => {
  try {
    const st = lstatSync(p);
    return st.isSymbolicLink() ? "link" : st.isDirectory() ? "dir" : "other";
  } catch {
    return "absent";
  }
};

function linkInto(target: string, dest: string): void {
  const k = lkind(dest);
  if (k === "dir" || k === "other") return;
  if (k === "link") {
    if (readlinkSync(dest) === target) return;
    unlinkSync(dest);
  }
  symlinkSync(target, dest);
}

// <dst> a real directory holding a link per entry of <src>, except the
// carrier's own path: a directory ON that path is materialised the same way
// (a linked `plugins/` would put the carrier inside the distro), the carrier
// itself is left to its writer. False when <dst> is a real non-directory.
function materialize(src: string, dst: string, carrier: string): boolean {
  const k = lkind(dst);
  if (k === "other") return false;
  if (k === "link") unlinkSync(dst);
  if (k !== "dir") mkdirSync(dst);
  const [head, ...rest] = carrier.split("/");
  for (const name of existsSync(src) ? readdirSync(src) : []) {
    if (name.startsWith(".")) continue;
    if (name === head) {
      if (rest.length > 0) materialize(join(src, name), join(dst, name), rest.join("/"));
      continue;
    }
    linkInto(join(src, name), join(dst, name));
  }
  return true;
}

// The distro hooks file with every command prefixed; codex nests its commands
// one level deeper than cursor.
function prefixedHooks(src: string, home: string): string {
  const obj = JSON.parse(readFileSync(src, "utf8"));
  const prefix = shellDefault(home);
  for (const groups of Object.values(obj.hooks ?? {}) as any[]) {
    for (const g of groups) {
      if (typeof g.command === "string") g.command = `${prefix} ${g.command}`;
      for (const h of g.hooks ?? []) if (typeof h.command === "string") h.command = `${prefix} ${h.command}`;
    }
  }
  return `${JSON.stringify(obj, null, 2)}\n`;
}

const GENERATED = "generated by bin/ac-home-carriers.sh - this home names itself to the fleet hooks; edit the distro, not this file";

// The shell.env hook hands the shell what the process resolved at load - a
// launch line's AC_HOME, else this home - never the embedded home on its own
// (the output map starts empty, so a `??=` there would override the launch
// line in every shell command).
function opencodePlugin(home: string): string {
  return `// ac-home.js - ${GENERATED}.
process.env.AC_HOME ??= ${JSON.stringify(home)};
export const AcHome = async () => ({
  "shell.env": async (_input, output) => {
    output.env.AC_HOME = process.env.AC_HOME;
  },
});
`;
}

function piExtension(home: string): string {
  return `// ac-home.ts - ${GENERATED}.
process.env.AC_HOME ??= ${JSON.stringify(home)};
export default function () {}
`;
}

function readText(p: string): string | null {
  try {
    return readFileSync(p, "utf8");
  } catch {
    return null;
  }
}

// Written only when the bytes differ; true when it was.
function converge(p: string, text: string): boolean {
  if (lkind(p) === "link") unlinkSync(p);
  if (readText(p) === text) return false;
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, text);
  return true;
}

function pinClaudeLocal(p: string, home: string, warnFn: (m: string) => void, rel: string): boolean {
  if (lkind(p) === "link") unlinkSync(p);
  const raw = readText(p);
  let obj: any;
  if (raw === null) {
    obj = {};
    const distro = readText(join(ROOT, ".claude", "settings.local.json"));
    if (distro !== null) {
      try {
        obj = JSON.parse(distro);
      } catch {}
    }
  } else {
    try {
      obj = JSON.parse(raw);
    } catch {
      warnFn(`${rel} is not JSON - AC_HOME not pinned there; fix the file or remove it and it is seeded again`);
      return false;
    }
    if (obj?.env?.AC_HOME === home) return false;
  }
  if (typeof obj !== "object" || obj === null || Array.isArray(obj)) obj = {};
  obj.env = { ...(typeof obj.env === "object" && obj.env !== null ? obj.env : {}), AC_HOME: home };
  writeFileSync(p, `${JSON.stringify(obj, null, 2)}\n`);
  return true;
}

export function seedHomeCarriers(home: string, warnFn: (m: string) => void = (m) => warn(m)): string[] {
  const written: string[] = [];
  for (const d of Object.keys(CARRIERS)) {
    const dir = join(home, d);
    const carrier = CARRIERS[d];
    const src = join(ROOT, d);
    if (!materialize(src, dir, carrier)) {
      warnFn(`${d} is a file, not a directory - no carrier written there`);
      continue;
    }
    const rel = `${d}/${carrier}`;
    const p = join(dir, carrier);
    let changed = false;
    if (d === ".claude") changed = pinClaudeLocal(p, home, warnFn, rel);
    else if (d === ".opencode") changed = converge(p, opencodePlugin(home));
    else if (d === ".pi") changed = converge(p, piExtension(home));
    else if (existsSync(join(src, carrier))) changed = converge(p, prefixedHooks(join(src, carrier), home));
    if (changed) written.push(rel);
  }
  return written;
}

function main(args: string[]): void {
  if (args.length > 0) die(`unknown argument: ${args[0]}`);
  if (!process.env.AC_HOME)
    die("AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one");
  for (const rel of seedHomeCarriers(envHome())) writeSync(1, `carried: ${rel}\n`);
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  const h = process.env.AC_HOME ?? "";
  if (!atCaller && h !== "" && !h.startsWith("/")) die("the current directory cannot be resolved, so a relative AC_HOME cannot be either");
  main(args);
}
