// home-carriers.test.ts - src/home-carriers.ts: a fleet home names itself to
// every harness's hooks. Five real per-home dot-dirs, the distro content
// linked in, one home-owned carrier per harness holding AC_HOME=<home>; a
// second run writes nothing, a chief's own grants survive, a moved home is
// re-pinned, a real per-home entry is never touched.
import { expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CARRIERS, seedHomeCarriers, shellDefault } from "../../src/home-carriers.ts";

const ROOT = join(import.meta.dir, "..", "..");
const DIRS = [".claude", ".codex", ".cursor", ".opencode", ".pi"];

const kind = (p: string): string => {
  try {
    const st = lstatSync(p);
    return st.isSymbolicLink() ? `link ${readlinkSync(p)}` : st.isDirectory() ? "dir" : "file";
  } catch {
    return "absent";
  }
};
const json = (p: string) => JSON.parse(readFileSync(p, "utf8"));
const distroLocal = (): Record<string, unknown> => {
  try {
    return json(join(ROOT, ".claude", "settings.local.json"));
  } catch {
    return {};
  }
};
// Every command of a hooks file, whatever the event, in file order.
const commands = (obj: any, cursor: boolean): string[] =>
  Object.values(obj.hooks as Record<string, any[]>).flatMap((groups) =>
    cursor ? groups.map((g) => g.command) : groups.flatMap((g) => g.hooks.map((h: any) => h.command)),
  );

function withHome(stage: (home: string) => void, body: (home: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "ac-home-carriers-"));
  try {
    const home = join(dir, "fleet");
    mkdirSync(home);
    stage(home);
    body(home);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("shellDefault spells a home that bash, sh and zsh read back verbatim, and keep a launch line's", () => {
  expect(shellDefault("/home/me/ac-homes/lab")).toBe('AC_HOME="${AC_HOME:-"/home/me/ac-homes/lab"}"');
  // The expansion's own delimiter is the one a double-quoted word does not
  // protect; the rest are the characters a double-quoted word still reads.
  const odd = '/tmp/a}b "c" $d `e` \\f';
  for (const sh of ["bash", "sh", "zsh"]) {
    const r = Bun.spawnSync([sh, "-c", `${shellDefault(odd)}; printf '%s' "$AC_HOME"`], { env: { PATH: process.env.PATH ?? "" } });
    expect([sh, r.stdout.toString()]).toEqual([sh, odd]);
    const kept = Bun.spawnSync([sh, "-c", `${shellDefault(odd)}; printf '%s' "$AC_HOME"`], { env: { PATH: process.env.PATH ?? "", AC_HOME: "/launch/line" } });
    expect([sh, kept.stdout.toString()]).toEqual([sh, "/launch/line"]);
  }
});

test("a seeded home (every dot-dir a distro link) gets five real dirs, the distro content linked, one carrier each", () => {
  withHome(
    (home) => {
      for (const d of DIRS) symlinkSync(join(ROOT, d), join(home, d));
    },
    (home) => {
      const written = seedHomeCarriers(home);
      for (const d of DIRS) {
        expect(kind(join(home, d))).toBe("dir");
        // A directory on the carrier's own path is real too, its entries
        // linked one by one; everything else is one link per distro entry.
        const [head, ...rest] = CARRIERS[d].split("/");
        for (const name of readdirSync(join(ROOT, d))) {
          if (name.startsWith(".") || name === CARRIERS[d]) continue;
          if (name === head && rest.length > 0) {
            expect(kind(join(home, d, name))).toBe("dir");
            for (const inner of readdirSync(join(ROOT, d, name))) {
              if (inner.startsWith(".") || inner === rest.join("/")) continue;
              expect(kind(join(home, d, name, inner))).toBe(`link ${join(ROOT, d, name, inner)}`);
            }
            continue;
          }
          expect(kind(join(home, d, name))).toBe(`link ${join(ROOT, d, name)}`);
        }
        expect(kind(join(home, d, CARRIERS[d]))).toBe("file");
      }
      expect(kind(join(home, ".opencode", "plugins", "ac-primary-guards.js"))).toBe(`link ${join(ROOT, ".opencode", "plugins", "ac-primary-guards.js")}`);
      expect(existsSync(join(ROOT, ".opencode", "plugins", "ac-home.js"))).toBe(false);
      expect(existsSync(join(ROOT, ".pi", "extensions", "ac-home.ts"))).toBe(false);
      expect(written).toEqual(DIRS.map((d) => `${d}/${CARRIERS[d]}`));

      const local = json(join(home, ".claude", "settings.local.json"));
      expect(local.env.AC_HOME).toBe(home);
      const base = distroLocal() as any;
      for (const k of Object.keys(base)) if (k !== "env") expect(local[k]).toEqual(base[k]);
      for (const k of Object.keys(base.env ?? {})) expect(local.env[k]).toBe(base.env[k]);

      const want = shellDefault(home);
      const cx = json(join(home, ".codex", "hooks.json"));
      const cxSrc = json(join(ROOT, ".codex", "hooks.json"));
      expect(commands(cx, false)).toEqual(commands(cxSrc, false).map((c) => `${want} ${c}`));
      const cu = json(join(home, ".cursor", "hooks.json"));
      const cuSrc = json(join(ROOT, ".cursor", "hooks.json"));
      expect(commands(cu, true)).toEqual(commands(cuSrc, true).map((c) => `${want} ${c}`));
      // Everything but the command is carried as it was.
      expect(cx.hooks.Stop[0].hooks[0].timeout).toBe(cxSrc.hooks.Stop[0].hooks[0].timeout);
      expect(cu.version).toBe(cuSrc.version);

      for (const f of [".opencode/plugins/ac-home.js", ".pi/extensions/ac-home.ts"]) {
        const text = readFileSync(join(home, f), "utf8");
        expect(text).toContain(JSON.stringify(home));
        expect(Bun.spawnSync(["bun", "build", "--no-bundle", join(home, f)], { stdout: "ignore", stderr: "ignore" }).exitCode).toBe(0);
      }
      // The pi/opencode carriers fill a missing AC_HOME and keep a launch
      // line's: the two agree for every correctly launched session.
      const piProbe = `import "${join(home, ".pi/extensions/ac-home.ts")}"; console.log(process.env.AC_HOME)`;
      // opencode's shell.env output map starts empty: what it hands the shell
      // must be what the process resolved, launch line first.
      const ocProbe = `import { AcHome } from "${join(home, ".opencode/plugins/ac-home.js")}"; const o = { env: {} }; (await AcHome())["shell.env"]({}, o).then(() => console.log(process.env.AC_HOME, o.env.AC_HOME))`;
      for (const probe of [piProbe, ocProbe]) {
        const filled = Bun.spawnSync(["bun", "-e", probe], { env: { PATH: process.env.PATH ?? "" } });
        expect(filled.stdout.toString().trim().split(" ")).toEqual(probe === piProbe ? [home] : [home, home]);
        const kept = Bun.spawnSync(["bun", "-e", probe], { env: { PATH: process.env.PATH ?? "", AC_HOME: "/launch/line" } });
        expect(kept.stdout.toString().trim().split(" ")).toEqual(probe === piProbe ? ["/launch/line"] : ["/launch/line", "/launch/line"]);
      }
    },
  );
});

test("a second run writes nothing; a chief's own grants survive; a moved home is re-pinned", () => {
  withHome(
    () => {},
    (home) => {
      seedHomeCarriers(home);
      expect(seedHomeCarriers(home)).toEqual([]);

      const local = join(home, ".claude", "settings.local.json");
      const grown = json(local);
      grown.permissions = { allow: ["Bash(bin/ac-watch.sh:*)"] };
      grown.env.AC_HOME = "/old/spelling";
      writeFileSync(local, JSON.stringify(grown));
      expect(seedHomeCarriers(home)).toEqual([".claude/settings.local.json"]);
      const after = json(local);
      expect(after.env.AC_HOME).toBe(home);
      expect(after.permissions).toEqual({ allow: ["Bash(bin/ac-watch.sh:*)"] });

      // A generated carrier is regenerated when the distro source moves on
      // (here: a hand edit stands in for drift).
      writeFileSync(join(home, ".codex", "hooks.json"), "{}");
      expect(seedHomeCarriers(home)).toEqual([".codex/hooks.json"]);
    },
  );
});

test("a real per-home entry is left alone, a dangling link is repointed, a non-JSON local file is kept and named", () => {
  withHome(
    (home) => {
      mkdirSync(join(home, ".claude"));
      writeFileSync(join(home, ".claude", "CLAUDE.md"), "per-home law\n");
      symlinkSync("/gone/settings.json", join(home, ".claude", "settings.json"));
      writeFileSync(join(home, ".claude", "settings.local.json"), "{ not json");
    },
    (home) => {
      const warned: string[] = [];
      const written = seedHomeCarriers(home, (m) => warned.push(m));
      expect(readFileSync(join(home, ".claude", "CLAUDE.md"), "utf8")).toBe("per-home law\n");
      expect(kind(join(home, ".claude", "settings.json"))).toBe(`link ${join(ROOT, ".claude", "settings.json")}`);
      expect(readFileSync(join(home, ".claude", "settings.local.json"), "utf8")).toBe("{ not json");
      expect(written).not.toContain(".claude/settings.local.json");
      expect(warned.length).toBe(1);
      expect(warned[0]).toContain(".claude/settings.local.json");
      expect(warned[0]).toContain("AC_HOME");
      expect(existsSync(join(home, ".pi", "extensions", "ac-home.ts"))).toBe(true);
    },
  );
});
