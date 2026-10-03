// fleet-new.test.ts - the lib.ts twins src/fleet-new.ts introduced, held to
// their bash originals in bin/ac-lib.sh differentially: configDir and
// projectsDir against ac_config_dir and ac_projects_dir (the path printed, the
// directory minted, the homeless refusal), and the module's untilde against
// the bash case it replaces. The CLI contract itself - stdin line semantics,
// prompts, refusals, the seeded tree - is tests/sh/ac-fleet-new.test.sh's,
// whose differential leg runs the frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configDir, projectsDir } from "../../src/lib.ts";
import { untilde } from "../../src/fleet-new.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");

function bashLib(fn: string, args: string[], env: Record<string, string | undefined>) {
  const e: Record<string, string> = {};
  for (const [k, v] of Object.entries({ ...process.env, ...env })) if (v !== undefined) e[k] = v;
  return Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; shift; ${fn} "$@"`, "--", binDir, ...args], { stdout: "pipe", stderr: "pipe", env: e });
}

function withHome<T>(home: string | undefined, f: () => T): T {
  const saved = process.env.AC_HOME;
  if (home === undefined) delete process.env.AC_HOME;
  else process.env.AC_HOME = home;
  try {
    return f();
  } finally {
    if (saved === undefined) delete process.env.AC_HOME;
    else process.env.AC_HOME = saved;
  }
}

test("configDir and projectsDir mint and name what ac_config_dir and ac_projects_dir do", () => {
  // Physical: ac_home answers `cd && pwd -P`, and so does the twin's envHome.
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "ac-fleet-new-dirs-")));
  try {
    for (const [fn, twin, sub] of [["ac_config_dir", configDir, "config"], ["ac_projects_dir", projectsDir, "projects"]] as const) {
      const o = join(dir, `${sub}-bash`);
      const n = join(dir, `${sub}-ts`);
      mkdirSync(o);
      mkdirSync(n);
      const r = bashLib(fn, [], { AC_HOME: o });
      expect(r.exitCode).toBe(0);
      expect(r.stderr.toString()).toBe("");
      expect(r.stdout.toString()).toBe(`${o}/${sub}\n`);
      expect(statSync(join(o, sub)).isDirectory()).toBe(true);
      expect(withHome(n, twin)).toBe(`${n}/${sub}`);
      expect(statSync(join(n, sub)).isDirectory()).toBe(true);
      // A second call on an existing dir is a no-op on both sides.
      expect(withHome(n, twin)).toBe(`${n}/${sub}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("configDir and projectsDir refuse a homeless caller as the bash helpers do", () => {
  for (const [fn, twin] of [["ac_config_dir", configDir], ["ac_projects_dir", projectsDir]] as const) {
    const r = bashLib(fn, [], { AC_HOME: undefined });
    expect(r.exitCode).toBe(1);
    expect(r.stdout.toString()).toBe("");
    const want = r.stderr.toString();
    expect(want).toMatch(/^ERROR: AC_HOME is not set/);
    const t = Bun.spawnSync(
      [process.execPath, "-e", `import { ${fn === "ac_config_dir" ? "configDir" : "projectsDir"} as f } from "${join(import.meta.dir, "..", "..", "src", "lib.ts")}"; f();`],
      { stdout: "pipe", stderr: "pipe", env: Object.fromEntries(Object.entries(process.env).filter(([k, v]) => k !== "AC_HOME" && v !== undefined)) as Record<string, string> },
    );
    expect(t.exitCode).toBe(1);
    expect(t.stdout.toString()).toBe("");
    expect(t.stderr.toString()).toBe(want);
    expect(typeof twin).toBe("function");
  }
});

test("untilde expands exactly the leading ~ forms the bash case expands", () => {
  const home = "/h/ome";
  const cases: [string, string][] = [
    ["~", home],
    ["~/", `${home}/`],
    ["~/x/y", `${home}/x/y`],
    ["~x", "~x"],
    ["~~", "~~"],
    [" ~/x", " ~/x"],
    ["/abs/~/x", "/abs/~/x"],
    ["", ""],
    ["rel/~", "rel/~"],
  ];
  for (const [input, want] of cases) {
    const r = Bun.spawnSync(
      ["bash", "-c", 'case "$1" in "~") printf "%s\\n" "$HOME" ;; "~/"*) printf "%s\\n" "$HOME/${1#\\~/}" ;; *) printf "%s\\n" "$1" ;; esac', "--", input],
      { stdout: "pipe", stderr: "pipe", env: { ...process.env, HOME: home } as Record<string, string> },
    );
    expect(r.stdout.toString()).toBe(`${want}\n`);
    expect(untilde(input, home)).toBe(want);
  }
  // An EMPTY HOME is a value for the bash (`~/x` -> `/x`); only an UNSET one
  // is refused, by the entry, before any directory is made.
  expect(untilde("~/x", "")).toBe("/x");
  expect(untilde("~", "")).toBe("");
  expect(existsSync("/h/ome")).toBe(false);
});
