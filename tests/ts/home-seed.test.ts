// home-seed.test.ts - the lib.ts twins src/home-seed.ts introduced, held to
// their bash originals differentially: seedRuntimeLinks against the frozen
// ac_seed_runtime_links over every entry state a home can hold, iso against
// ac_iso under one PATH date stub; and the module's two pure readers against
// the shell they replace (the `IFS=',' read -ra` + `tr -d ' '` split, the awk
// registry-line pick). The CLI contract itself is tests/sh/ac-home-seed.test.sh's,
// whose differential leg runs the frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { iso, seedRuntimeLinks } from "../../src/lib.ts";
import { registryLine, splitProjects } from "../../src/home-seed.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
// ac_seed_runtime_links left bin/ac-lib.sh with the fleet-new port (its last
// bash caller); the pin holds the twin to the frozen copy.
const retired = join(import.meta.dir, "..", "fixtures", "ac-seed-runtime-links.sh");
const LINKS = ["bin", "CLAUDE.md", ".claude", "AGENTS.md"];

function bashLib(fn: string, args: string[], env?: Record<string, string>) {
  return Bun.spawnSync(
    ["bash", "-c", `. "$1/ac-lib.sh"; . "$2"; shift 2; ${fn} "$@"`, "--", binDir, retired, ...args],
    { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env } },
  );
}

// Every entry's kind and, for a link, its target: what a chief session finds
// at cwd = home.
function shape(home: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of LINKS) {
    const p = join(home, f);
    try {
      const st = lstatSync(p);
      out[f] = st.isSymbolicLink() ? `link ${readlinkSync(p)}` : st.isDirectory() ? "dir" : `file ${readFileSync(p, "latin1")}`;
    } catch {
      out[f] = "absent";
    }
  }
  return out;
}

test("seedRuntimeLinks lays the same links ac_seed_runtime_links lays", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-home-seed-links-"));
  try {
    const stage = (home: string, state: string) => {
      mkdirSync(home);
      if (state === "real") {
        mkdirSync(join(home, "bin"));
        writeFileSync(join(home, "CLAUDE.md"), "per-home law\n");
      } else if (state === "link") {
        // Resolving links: a directory for bin, files for the rest, so ln's
        // no-dereference flag is what keeps the LINK the thing replaced.
        mkdirSync(join(dir, "elsewhere", "bin"), { recursive: true });
        for (const f of LINKS.filter((x) => x !== "bin")) writeFileSync(join(dir, "elsewhere", f), "x\n");
        for (const f of LINKS) symlinkSync(join(dir, "elsewhere", f), join(home, f));
      } else if (state === "dangling") {
        for (const f of LINKS) symlinkSync(join(dir, "gone", f), join(home, f));
      }
    };
    for (const state of ["fresh", "real", "link", "dangling"]) {
      const o = join(dir, `${state}-bash`);
      const n = join(dir, `${state}-ts`);
      stage(o, state);
      stage(n, state);
      const r = bashLib("ac_seed_runtime_links", [o]);
      expect(r.exitCode).toBe(0);
      expect(r.stderr.toString()).toBe("");
      seedRuntimeLinks(n);
      const want = shape(o);
      expect(shape(n)).toEqual(want);
      // The bash's links name the distro root ac_root resolves (bin/..,
      // physically); a port that pointed anywhere else would run a chief on
      // the wrong checkout.
      if (state !== "real") expect(want.bin).toBe(`link ${join(binDir)}`);
      else expect(want.bin).toBe("dir");
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("iso prints what ac_iso prints, through the one date on PATH", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-home-seed-date-"));
  const savedPath = process.env.PATH;
  try {
    writeFileSync(join(dir, "date"), "#!/bin/sh\nprintf '2026-01-02T03:04:05Z\\n'\n");
    chmodSync(join(dir, "date"), 0o755);
    const PATH = `${dir}:${process.env.PATH}`;
    const r = bashLib("ac_iso", [], { PATH });
    expect(r.exitCode).toBe(0);
    expect(r.stdout.toString()).toBe("2026-01-02T03:04:05Z\n");
    process.env.PATH = PATH;
    expect(iso()).toBe("2026-01-02T03:04:05Z");
    process.env.PATH = savedPath;
    expect(iso()).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  } finally {
    process.env.PATH = savedPath;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("splitProjects keeps the entries the read/tr pipeline kept", () => {
  // -r is set on the read, so a backslash before a byte, a comma, a newline
  // or a backslash is literal; these inputs pin that against the same bash.
  for (const projects of ["a, b ,,c", "x\ny,z", ",a,", "a,b,", " , ", "a\tb,c", "alpha,alpha", "alpha", "a b",
    "\\alpha", "a\\,b,c", "a\\\nb,c", "a\\\\b", "x\\", "\\,", "p\\ q"]) {
    const r = Bun.spawnSync(
      [
        "bash", "-c",
        'IFS="," read -ra reqs <<<"$1"; for p in "${reqs[@]}"; do p="$(printf "%s" "$p" | tr -d " ")"; [ -n "$p" ] || continue; printf "%s\\0" "$p"; done',
        "--", projects,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    expect(r.exitCode).toBe(0);
    const want = r.stdout.toString().split("\0").slice(0, -1);
    expect(splitProjects(projects)).toEqual(want);
  }
});

test("registryLine picks the line the awk picks, verbatim, and nothing when it has none", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-home-seed-reg-"));
  try {
    const f = join(dir, "projects.md");
    writeFileSync(
      f,
      "# Projects\n\n" +
        "- 7 [direct-pr] - seven (added x)\n" +
        "- 07 - oh-seven (added x)\n" +
        "- beta - bracketless (added 2026-07-13)\n" +
        "  - alpha - indented (added x)\n" +
        "-\tdelta\t[local-only] - tabbed (added x)\n" +
        "- gamma x - third field neither dash nor bracket\n" +
        "- gamma - second mention wins (added x)\n" +
        "- crlf - with a CR (added x)\r\n" +
        "- u\u00e9 - non-ascii name (added x)\n" +
        "- last - no trailing newline",
      "utf8",
    );
    const awk = (file: string, p: string) =>
      Bun.spawnSync(
        ["bash", "-c", 'LC_ALL=C awk -v p="$2" \'BEGIN { w[p] } $1 == "-" && ($2 in w) && ($3 == "-" || $3 ~ /^\\[/) { print; exit }\' "$1" 2>/dev/null || true', "--", file, p],
        { stdout: "pipe", stderr: "pipe" },
      ).stdout.toString("latin1").replace(/\n+$/, "");
    for (const p of ["7", "07", "beta", "alpha", "delta", "gamma", "crlf", "u\u00e9", "last", "none"]) {
      expect(registryLine(f, p)).toBe(awk(f, p));
    }
    expect(registryLine(f, "beta")).toBe("- beta - bracketless (added 2026-07-13)");
    expect(registryLine(f, "alpha")).toBe("  - alpha - indented (added x)");
    expect(registryLine(f, "crlf")).toBe("- crlf - with a CR (added x)\r");
    expect(registryLine(f, "none")).toBe("");
    expect(registryLine(join(dir, "absent.md"), "beta")).toBe(awk(join(dir, "absent.md"), "beta"));
    expect(registryLine(join(dir, "absent.md"), "beta")).toBe("");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
