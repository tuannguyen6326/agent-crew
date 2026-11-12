// deputy.test.ts - what src/deputy.ts brought into src/lib.ts, held to the
// bash it twins: deputyParse's program against ac_deputy_parse in the live
// bin/ac-lib.sh (lifted text and output, under C and UTF-8), isCrewdeputyHome
// and deputyRegistry against ac_is_crewdeputy_home / ac_deputy_registry,
// and recordsBackup against its spec (the src/lib.ts comment above it). The
// CLI contract itself is tests/sh/ac-deputy*.test.sh's.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-deputy-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

type Run = { code: number | null; out: string; err: string };

function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, BIN, ...args], {
    env: { PATH: process.env.PATH!, LC_ALL: "C", ...env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(Buffer.from(String(s), "latin1")); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, LC_ALL: "C", ...env }, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 30000 },
  );
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

let n = 0;
function dir(name: string): string {
  const d = join(W, `${name}${n++}`);
  mkdirSync(d, { recursive: true });
  return d;
}

const NO_HOME = "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n";

// The single-quoted program that follows <anchor> in <text>.
function quoted(text: string, anchor: string): string {
  const a = text.indexOf(anchor);
  expect(a).toBeGreaterThanOrEqual(0);
  const start = a + anchor.length;
  return text.slice(start, text.indexOf("'", start));
}

test("deputyParse spawns ac_deputy_parse's program byte for byte, on the file it names, null for no regular file", () => {
  const src = readFileSync(join(BIN, "ac-lib.sh"), "latin1");
  const prog = quoted(src.slice(src.indexOf("ac_deputy_parse() {")), "awk '");
  const reg = join(dir("parse"), "crewdeputies.md");
  writeFileSync(reg, "x\n");
  const got = JSON.parse(twin(`say(JSON.stringify([L.deputyParse(${JSON.stringify(reg)}), L.deputyParse("/nonexistent/x"), L.deputyParse(${JSON.stringify(W)})]))`, {}).out);
  expect(got).toEqual([["awk", prog, reg], null, null]);
});

test("deputyParse's records are ac_deputy_parse's, under C and under UTF-8 (where a byte that is not UTF-8 aborts both)", () => {
  const reg = join(dir("records"), "crewdeputies.md");
  writeFileSync(
    reg,
    Buffer.concat([
      Buffer.from(
        "# Crewdeputies\n\nprose\n- \n- pay - payments - home: /h/my homes/crewdeputies/pay - scope: incidents - alert noise - projects: alpha,beta (added x)\n" +
          "- leg - home: /h/crewdeputies/leg - alpha  beta\tgamma (added x)\n- noq - home: /h/noq - no projects (added x)\n" +
          "- ops2 - home /abs (added x)\n- a - c - home: rel - scope: s - projects: p (added x)\n- b - c - home: /h/x - scope: s - projects: p (added x)\n" +
          "- c - c - home: /h/c - projects: p (added x)\n- d - home: /h/d - scope: s - projects: p (added x)\n- pay - again - home: /h/pay - scope: s - projects: p (added x)\n" +
          "- t\tab - home /abs (added x)\n- café - c - home: /h/café - scope: s - projects: none (added x)\n",
        "utf8",
      ),
      Buffer.from([0x2d, 0x20, 0x62, 0xe9, 0x64, 0x20, 0x2d, 0x20, 0x68, 0x6f, 0x6d, 0x65, 0x3a, 0x20, 0x2f, 0x68, 0x20, 0x28, 0x61, 0x64, 0x64, 0x65, 0x64, 0x20, 0x78, 0x29, 0x0a]),
      Buffer.from("- after - home: /h/after - no projects (added x)\n"),
    ]),
  );
  for (const loc of ["C", "en_US.UTF-8"]) {
    const want = bash('. "$0/ac-lib.sh"; ac_deputy_parse "$1"; printf "rc=%s" "$?"', { LC_ALL: loc }, [reg]);
    const got = twin(
      `const a = L.deputyParse(${JSON.stringify(reg)}); const r = L.spawnShellSync(a, { stdin: "ignore", stdout: "pipe", stderr: "pipe" }); say(r.stdout.toString("latin1") + "rc=" + r.exitCode); process.stderr.write(r.stderr);`,
      { LC_ALL: loc },
    );
    expect({ loc, out: got.out, err: got.err }).toEqual({ loc, out: want.out, err: want.err });
  }
  expect(bash('. "$0/ac-lib.sh"; ac_deputy_parse "$1" | cut -f1 | sort | uniq -c | tr -s " " | tr "\\n" ";"', {}, [reg]).out).toBe(" 10 INVALID; 3 LEGACY; 1 VALID;");
});

test("deputyParse with no file reads deputyRegistry(), as ac_deputy_parse with no argument reads ac_deputy_registry", () => {
  const h = dir("home");
  mkdirSync(join(h, "records"));
  writeFileSync(join(h, "records", "crewdeputies.md"), "- x - home: /h/x - no projects (added x)\n");
  expect(JSON.parse(twin("say(JSON.stringify(L.deputyParse()))", { AC_HOME: h }).out)[2]).toBe(join(h, "records", "crewdeputies.md"));
  const homeless = twin("say(JSON.stringify(L.deputyParse()))", {});
  expect(homeless.out).toBe("null");
  expect(homeless.err).toBe(NO_HOME);
});

test("deputyRegistry is ac_deputy_registry: records/ minted, homeless the refusal and /crewdeputies.md", () => {
  const h = dir("reg");
  const bh = dir("regb");
  const got = twin("say(L.deputyRegistry())", { AC_HOME: h });
  const want = bash('. "$0/ac-lib.sh"; ac_deputy_registry', { AC_HOME: bh });
  expect(got.out).toBe(want.out.replace(bh, h).replace(/\n$/, ""));
  expect(got.err).toBe(want.err);
  expect(realpathSync(join(h, "records"))).toBe(join(h, "records"));
  const hl = twin("say(L.deputyRegistry())", {});
  const wl = bash('. "$0/ac-lib.sh"; ac_deputy_registry', {});
  expect({ out: hl.out, err: hl.err }).toEqual({ out: wl.out.replace(/\n$/, ""), err: wl.err });
});

test("isCrewdeputyHome is ac_is_crewdeputy_home: a regular marker, a symlink to one; never a directory or a dangling link; homeless false after the refusal", () => {
  const cases: [string, (h: string) => void][] = [
    ["file", (h) => writeFileSync(join(h, ".ac-crewdeputy-home"), "")],
    ["link", (h) => (writeFileSync(join(h, "m"), ""), symlinkSync("m", join(h, ".ac-crewdeputy-home")))],
    ["dir", (h) => mkdirSync(join(h, ".ac-crewdeputy-home"))],
    ["dangling", (h) => symlinkSync("nowhere", join(h, ".ac-crewdeputy-home"))],
    ["none", () => {}],
  ];
  for (const [name, seed] of cases) {
    const h = dir(name);
    seed(h);
    const want = bash('. "$0/ac-lib.sh"; if ac_is_crewdeputy_home; then printf yes; else printf no; fi', { AC_HOME: h });
    const got = twin('say(L.isCrewdeputyHome() ? "yes" : "no")', { AC_HOME: h });
    expect({ name, out: got.out, err: got.err }).toEqual({ name, out: want.out, err: want.err });
  }
  const want = bash('. "$0/ac-lib.sh"; if ac_is_crewdeputy_home; then printf yes; else printf no; fi', {});
  const got = twin('say(L.isCrewdeputyHome() ? "yes" : "no")', {});
  expect({ out: got.out, err: got.err }).toEqual({ out: want.out, err: want.err });
  expect(got.err).toBe(NO_HOME);
});

function seedHome(h: string): void {
  mkdirSync(join(h, "records"), { recursive: true });
  writeFileSync(join(h, "records", "backlog.md"), "# Backlog\n");
  for (const p of ["zeta", "Alpha", "_mid", ".hidden"]) {
    mkdirSync(join(h, "crewdomains", p, "records"), { recursive: true });
    writeFileSync(join(h, "crewdomains", p, "records", "r.md"), p);
  }
  writeFileSync(join(h, "crewdomains", "zeta", "CREWMATE.md"), "z");
  mkdirSync(join(h, "crewdomains", "zeta", "projects"));
  symlinkSync("/nonexistent/clone", join(h, "crewdomains", "zeta", "projects", "p1"));
  mkdirSync(join(h, "crewdomains", "Alpha", "CREWMATE.md"));
  writeFileSync(join(h, "crewdomains", "Alpha", "projects"), "not a dir");
  mkdirSync(join(h, "crewdomains", "norecords"));
  writeFileSync(join(h, "crewdomains", "filerecords"), "");
  mkdirSync(join(h, "state"));
  writeFileSync(join(h, "state", ".learn.meta"), "l");
  mkdirSync(join(h, "state", ".curate.meta"));
  writeFileSync(join(h, "CREWMATE-learned.md"), "c");
}

function backupTwin(h: string, env: Record<string, string> = {}): Run {
  return twin('const a = L.recordsBackup("deputy-handoff"); say(a === null ? "null" : a)', { AC_HOME: h, EPOCHSECONDS: "1767225600", ...env });
}

// In archive order: the members are added in the order tar was handed them.
function listing(arc: string): string {
  return Bun.spawnSync(["tar", "-tzf", arc], { stdout: "pipe", stderr: "pipe" }).stdout.toString();
}

test("recordsBackup: the members and their order, the -<n> claim in one second, the printed path", () => {
  const t = dir("bt");
  seedHome(t);
  const members = [
    "records/",
    "records/backlog.md",
    "skills/",
    "crewdomains/Alpha/records/",
    "crewdomains/Alpha/records/r.md",
    "crewdomains/_mid/records/",
    "crewdomains/_mid/records/r.md",
    "crewdomains/zeta/records/",
    "crewdomains/zeta/records/r.md",
    "crewdomains/zeta/CREWMATE.md",
    "crewdomains/zeta/projects/",
    "crewdomains/zeta/projects/p1",
    "state/.learn.meta",
    "CREWMATE-learned.md",
  ];
  for (const suffix of ["", "-1", "-2"]) {
    const got = backupTwin(t);
    expect(got).toEqual({ code: 0, out: `${t}/state/backups/deputy-handoff-1767225600${suffix}.tar.gz`, err: "" });
    expect(listing(got.out)).toBe(`${members.join("\n")}\n`);
  }
  const verbose = Bun.spawnSync(["tar", "-tvzf", `${t}/state/backups/deputy-handoff-1767225600.tar.gz`], { stdout: "pipe" }).stdout.toString();
  expect(verbose).toMatch(/^l.*crewdomains\/zeta\/projects\/p1 -> \/nonexistent\/clone$/m);
});

test("recordsBackup mints records/, skills/ and state/backups/ on a bare home", () => {
  const t = dir("bare");
  const got = backupTwin(t);
  expect(got).toEqual({ code: 0, out: `${t}/state/backups/deputy-handoff-1767225600.tar.gz`, err: "" });
  expect(listing(got.out)).toBe("records/\nskills/\n");
});

test("recordsBackup's claim failing is the WARN and null; a name a dangling link holds is no step", () => {
  if (process.getuid?.() === 0) return;
  const t = dir("ro");
  mkdirSync(join(t, "state", "backups"), { recursive: true });
  chmodSync(join(t, "state", "backups"), 0o555);
  const got = backupTwin(t);
  chmodSync(join(t, "state", "backups"), 0o755);
  const warned = `WARN: records backup: could not create ${t}/state/backups/deputy-handoff-1767225600.tar.gz (is ${t}/state/backups writable?) - no backup archive was taken\n`;
  expect({ out: got.out, err: got.err }).toEqual({ out: "null", err: warned });
  symlinkSync("nowhere", join(t, "state", "backups", "deputy-handoff-1767225600.tar.gz"));
  const g2 = backupTwin(t);
  expect({ out: g2.out, err: g2.err }).toEqual({ out: "null", err: warned });
});

test("recordsBackup's tar failing removes the claim and is null, tar's own line passed through", () => {
  if (process.getuid?.() === 0) return;
  const t = dir("tf");
  mkdirSync(join(t, "records", "locked"), { recursive: true });
  chmodSync(join(t, "records", "locked"), 0o000);
  const got = backupTwin(t);
  chmodSync(join(t, "records", "locked"), 0o755);
  expect(got.out).toBe("null");
  expect(got.err).toContain("Permission denied");
  expect(Bun.spawnSync(["ls", "-A", join(t, "state", "backups")], { stdout: "pipe" }).stdout.toString()).toBe("");
});
