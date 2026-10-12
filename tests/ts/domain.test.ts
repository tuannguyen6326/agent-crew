// domain.test.ts - what src/domain.ts brought into src/lib.ts, held to the
// bash it twins: domainParse's program against ac_domain_parse in the live
// bin/ac-lib.sh (lifted text and output, under C and UTF-8), domainRegistry,
// domainNameOk, backlogIdOk, domainViewEntry, domainQaRepo and domainTally
// against ac_domain_registry, ac_domain_name_ok, ac_backlog_id_ok,
// ac_domain_view_entry, ac_domain_qa_repo and ac_domain_tally; and the awk
// programs src/domain.ts spawns against the frozen tests/fixtures/ac-domain.sh.
// The CLI contract itself is tests/sh/ac-domain.test.sh's, whose differential
// leg runs the frozen bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-domain-ts-")));
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

test("domainParse spawns ac_domain_parse's program byte for byte, on the file it names, null for no regular file", () => {
  const src = readFileSync(join(BIN, "ac-lib.sh"), "latin1");
  const prog = quoted(src.slice(src.indexOf("ac_domain_parse() {")), "awk '");
  const reg = join(dir("parse"), "crewdomains.md");
  writeFileSync(reg, "x\n");
  const got = JSON.parse(twin(`say(JSON.stringify([L.domainParse(${JSON.stringify(reg)}), L.domainParse("/nonexistent/x"), L.domainParse(${JSON.stringify(W)})]))`, {}).out);
  expect(got).toEqual([["awk", prog, reg], null, null]);
});

test("domainParse's records are ac_domain_parse's, under C and under UTF-8 (where a byte that is not UTF-8 aborts both)", () => {
  const reg = join(dir("records"), "crewdomains.md");
  writeFileSync(
    reg,
    Buffer.concat([
      Buffer.from(
        "# Crewdomains\n\nprose\n- \n- pay - payments - scope: money - and more (added x)\n- ops - c - scope:  (added x)\n" +
          "- nodate - c - scope: s\n- bad - c - home: /x - scope: s (added x)\n- noscope - c (added x)\n- nocharter - scope: s (added x)\n" +
          "- Pay - c - scope: s (added x)\n- pay - again - scope: s (added x)\n- t\tab - c - scope: s (added x)\n- tab - a\tb - scope: s (added x)\n" +
          "- café - c - scope: s (added x)\n  - indented - c - scope: s (added x)\n- crlf - c - scope: s (added x)\r\n",
        "utf8",
      ),
      Buffer.from([0x2d, 0x20, 0x62, 0xe9, 0x64, 0x20, 0x2d, 0x20, 0x63, 0x20, 0x2d, 0x20, 0x73, 0x63, 0x6f, 0x70, 0x65, 0x3a, 0x20, 0x73, 0x20, 0x28, 0x61, 0x64, 0x64, 0x65, 0x64, 0x20, 0x78, 0x29, 0x0a]),
      Buffer.from("- after - c - scope: s (added x)\n"),
    ]),
  );
  for (const loc of ["C", "en_US.UTF-8"]) {
    const want = bash('. "$0/ac-lib.sh"; ac_domain_parse "$1"; printf "rc=%s" "$?"', { LC_ALL: loc }, [reg]);
    const got = twin(
      `const a = L.domainParse(${JSON.stringify(reg)}); const r = L.spawnShellSync(a, { stdin: "ignore", stdout: "pipe", stderr: "pipe" }); say(r.stdout.toString("latin1") + "rc=" + r.exitCode); process.stderr.write(r.stderr);`,
      { LC_ALL: loc },
    );
    expect({ loc, out: got.out, err: got.err }).toEqual({ loc, out: want.out, err: want.err });
  }
  expect(bash('. "$0/ac-lib.sh"; ac_domain_parse "$1" | cut -f1 | sort | uniq -c | tr -s " " | tr "\\n" ";"', {}, [reg]).out).toBe(" 11 INVALID; 4 VALID;");
});

test("domainParse with no file reads domainRegistry(), as ac_domain_parse with no argument reads ac_domain_registry", () => {
  const h = dir("home");
  mkdirSync(join(h, "records"));
  writeFileSync(join(h, "records", "crewdomains.md"), "- x - c - scope: s (added x)\n");
  expect(JSON.parse(twin("say(JSON.stringify(L.domainParse()))", { AC_HOME: h }).out)[2]).toBe(join(h, "records", "crewdomains.md"));
  const homeless = twin("say(JSON.stringify(L.domainParse()))", {});
  expect(homeless.out).toBe("null");
  expect(homeless.err).toBe(NO_HOME);
});

test("domainRegistry is ac_domain_registry: records/ minted, homeless the refusal and /crewdomains.md", () => {
  const h = dir("reg");
  const bh = dir("regb");
  const got = twin("say(L.domainRegistry())", { AC_HOME: h });
  const want = bash('. "$0/ac-lib.sh"; ac_domain_registry', { AC_HOME: bh });
  expect(got.out).toBe(want.out.replace(bh, h).replace(/\n$/, ""));
  expect(got.err).toBe(want.err);
  expect(realpathSync(join(h, "records"))).toBe(join(h, "records"));
  const hl = twin("say(L.domainRegistry())", {});
  const wl = bash('. "$0/ac-lib.sh"; ac_domain_registry', {});
  expect({ out: hl.out, err: hl.err }).toEqual({ out: wl.out.replace(/\n$/, ""), err: wl.err });
});

test("domainNameOk and backlogIdOk are ac_domain_name_ok and ac_backlog_id_ok, under C and under UTF-8", () => {
  const names = ["", ".", "..", "a/b", "/", "pay", "07", "-x", "x-r1", "A", "Pay", "a_b", "a b", "a.b", "café", "a\n", "a\tb", "*", "a*", "[a]", "é"];
  for (const loc of ["C", "en_US.UTF-8"]) {
    for (const fn of [["domainNameOk", "ac_domain_name_ok"], ["backlogIdOk", "ac_backlog_id_ok"]] as const) {
      const want = bash(`. "$0/ac-lib.sh"; for x in "$@"; do if ${fn[1]} "$x"; then printf 1; else printf 0; fi; done`, { LC_ALL: loc }, names);
      const got = twin(`say(${JSON.stringify(names)}.map((x) => (L.${fn[0]}(x) ? 1 : 0)).join(""))`, { LC_ALL: loc });
      expect({ loc, fn: fn[0], out: got.out }).toEqual({ loc, fn: fn[0], out: want.out });
    }
  }
});

// A home with the view shapes ac_domain_view_entry classifies; built alike in
// a twin home and a bash home, so each answer can be compared with the home
// spelled H.
function seedViews(h: string): void {
  for (const p of ["alpha", "beta"]) mkdirSync(join(h, "projects", p), { recursive: true });
  writeFileSync(join(h, "projects", "alpha.yaml"), "");
  mkdirSync(join(h, "elsewhere", "beta"), { recursive: true });
  symlinkSync(join(h, "elsewhere", "beta"), join(h, "projects", "aliased"));
  const v = join(h, "crewdomains", "pay", "projects");
  mkdirSync(v, { recursive: true });
  symlinkSync("../../../projects/alpha", join(v, "alpha"));
  symlinkSync("../../../projects/alpha.yaml", join(v, "alpha.yaml"));
  symlinkSync(join(h, "projects", "beta"), join(v, "beta"));
  symlinkSync("../../../projects/nosuch", join(v, "dang"));
  mkdirSync(join(v, "copied"));
  writeFileSync(join(v, "file"), "");
  symlinkSync(join(h, "elsewhere"), join(v, "out"));
  symlinkSync("../../../projects/alpha", join(v, "wrongname"));
  symlinkSync("../../../projects/aliased", join(v, "aliased"));
  symlinkSync("../../../projects/aliased", join(v, "aliased-wrong"));
  symlinkSync("hop2", join(v, "hop1"));
  symlinkSync("../../../projects/beta", join(v, "hop2"));
  symlinkSync("loopb", join(v, "loopa"));
  symlinkSync("loopa", join(v, "loopb"));
  symlinkSync("../../../projects/alpha/", join(v, "slash"));
  symlinkSync("../../../projects/../projects/beta", join(v, "dotted"));
  symlinkSync("../../../projects/aliased/../beta", join(v, "throughlink"));
  for (const [from, to] of [["c1", "c2"], ["c2", "c3"], ["c3", "c4"], ["c4", "c5"], ["c5", "../../../projects/beta"]]) symlinkSync(to!, join(v, from!));
}

test("domainViewEntry is ac_domain_view_entry over every view class, and homeless", () => {
  const t = dir("vt");
  const b = dir("vb");
  seedViews(t);
  seedViews(b);
  const entries = ["alpha", "alpha.yaml", "beta", "dang", "copied", "file", "out", "wrongname", "aliased", "aliased-wrong", "hop1", "hop2", "loopa", "slash", "dotted", "throughlink", "c1", "absent"];
  const want = bash('. "$0/ac-lib.sh"; for e in "${@:2}"; do printf "%s=%s|" "$e" "$(ac_domain_view_entry "$1" "$e")"; done', { AC_HOME: b }, ["pay", ...entries]);
  const got = twin(`say(${JSON.stringify(entries)}.map((e) => e + "=" + L.domainViewEntry("pay", e) + "|").join(""))`, { AC_HOME: t });
  expect(got.out).toBe(want.out.replaceAll(b, t));
  expect(got.err).toBe(want.err);
  expect(got.out).toContain("alpha=ok|");
  expect(got.out).toContain(`out=outside ${t}/elsewhere|`);
  expect(got.out).toContain(`wrongname=mismatch ${t}/projects/alpha|`);
  expect(got.out).toContain("aliased=ok|");
  expect(got.out).toContain(`throughlink=outside ${t}/elsewhere/beta|`);
  expect(got.out).toContain(`c1=mismatch ${t}/projects/beta|`);
  const hl = twin('say(L.domainViewEntry("pay", "alpha"))', {});
  const wl = bash('. "$0/ac-lib.sh"; ac_domain_view_entry pay alpha', {});
  expect({ out: hl.out, err: hl.err }).toEqual({ out: wl.out.replace(/\n$/, ""), err: wl.err });
});

function seedQa(h: string, member: Buffer | null): void {
  rmSync(h, { recursive: true, force: true });
  mkdirSync(join(h, "projects"), { recursive: true });
  for (const p of ["e2e", "real"]) Bun.spawnSync(["git", "init", "-q", "-b", "main", join(h, p === "real" ? "real" : "projects/e2e")]);
  symlinkSync(join(h, "real"), join(h, "projects", "linked"));
  const v = join(h, "crewdomains", "pay", "projects");
  mkdirSync(v, { recursive: true });
  symlinkSync("../../../projects/e2e", join(v, "e2e"));
  symlinkSync("../../../projects/linked", join(v, "linked"));
  mkdirSync(join(v, "plain"));
  if (member !== null) writeFileSync(join(h, "crewdomains", "pay", "qa-repo"), member);
}

test("domainQaRepo is ac_domain_qa_repo: the member's first line, every [:space:] deleted (tr, under the caller's locale), resolved physically to the main root", () => {
  const t = dir("qt");
  const b = dir("qb");
  const members: (Buffer | null)[] = [
    null,
    Buffer.from("e2e\n"),
    Buffer.from(" e 2e \t\nignored\n"),
    Buffer.from("\ne2e\n"),
    Buffer.from("linked"),
    Buffer.from("plain\n"),
    Buffer.from("nosuch\n"),
    Buffer.from("e2e \n", "utf8"),
    Buffer.from([0x65, 0x32, 0x65, 0xe9, 0x0a]),
    Buffer.from("../../../projects/e2e\n"),
  ];
  for (const m of members) {
    for (const loc of ["C", "en_US.UTF-8"]) {
      seedQa(t, m);
      seedQa(b, m);
      const want = bash('. "$0/ac-lib.sh"; ac_domain_qa_repo pay; printf "rc=%s" "$?"', { AC_HOME: b, LC_ALL: loc });
      const got = twin('const p = L.domainQaRepo("pay"); say(p === null ? "rc=1" : p + "\\nrc=0")', { AC_HOME: t, LC_ALL: loc });
      expect({ m: String(m), loc, out: got.out, err: got.err }).toEqual({ m: String(m), loc, out: want.out.replaceAll(b, t), err: want.err.replaceAll(b, t) });
      const quiet = twin('const p = L.domainQaRepo("pay", "ignore"); say(p === null ? "rc=1" : p + "\\nrc=0")', { AC_HOME: t, LC_ALL: loc });
      expect({ out: quiet.out, err: quiet.err }).toEqual({ out: got.out, err: "" });
    }
  }
  seedQa(t, Buffer.from("linked\n"));
  expect(twin('say(L.domainQaRepo("pay"))', { AC_HOME: t }).out).toBe(join(t, "real"));
  expect(twin('say(String(L.domainQaRepo("../pay")))', { AC_HOME: t }).out).toBe("null");
  const hl = twin('say(String(L.domainQaRepo("pay")))', {});
  const wl = bash('. "$0/ac-lib.sh"; ac_domain_qa_repo pay; printf "rc=%s" "$?"', {});
  expect({ out: hl.out, err: hl.err }).toEqual({ out: "null", err: NO_HOME });
  expect(wl.out).toBe("rc=1");
  expect(wl.err).toBe(NO_HOME);
});

test("domainTally is ac_domain_tally: section prefixes, epic inheritance, failed/abandoned Done excluded, names as strings; no ledger is 0 0 0", () => {
  const t = dir("tt");
  const b = dir("tb");
  const ledger =
    "# Backlog\n- [ ] pre - before any heading; domain:pay\n\n## In flight\n\n- [ ] f1 - flying; domain:pay (repo: a)\n- [ ] f2 - story; epic:big\n\n" +
    "## In flightish\n- [ ] f3 - prefix; domain:pay\n\n## Queued\n\n- [ ] big [EPIC] - epic; domain:pay (repo: a)\n- [ ] q1 - q; domain:7\n- [ ] q2 - q; domain:07\n" +
    "- [ ] q3 - story of an untokened epic; epic:none\n- [ ] q4 - own token wins; epic:big; domain:other\n- [ ] q5 - prose domain:pay mention\n\n## Parked\n\n- [ ] p1 - parked; domain:pay\n\n" +
    "## Done (older)\n\n- [x] d0 - done under a prefix; domain:pay\n\n## Done\n\n- [x] d1 - done; domain:pay\n- [x] d2 [failed] - failed; domain:pay\n- [x] d3 [abandoned] - abandoned; domain:pay\n- [x] d4 - story; epic:big\n" +
    "- [x] d5 - crlf; domain:pay\r\n";
  for (const h of [t, b]) {
    mkdirSync(join(h, "records"), { recursive: true });
    writeFileSync(join(h, "records", "backlog.md"), ledger);
  }
  for (const name of ["pay", "7", "07", "other", "ghost"]) {
    const want = bash('. "$0/ac-lib.sh"; ac_domain_tally "$1"', { AC_HOME: b }, [name]);
    const got = twin(`say(L.domainTally(${JSON.stringify(name)}))`, { AC_HOME: t });
    expect({ name, out: got.out, err: got.err }).toEqual({ name, out: want.out.replace(/\n$/, ""), err: want.err });
  }
  expect(twin('say(L.domainTally("pay"))', { AC_HOME: t }).out).toBe("1 3 3");
  const e = dir("te");
  expect(twin('say(L.domainTally("pay"))', { AC_HOME: e }).out).toBe(bash('. "$0/ac-lib.sh"; ac_domain_tally pay', { AC_HOME: e }).out.replace(/\n$/, ""));
  expect(twin('say(L.domainTally("pay"))', { AC_HOME: e }).out).toBe("0 0 0");
});

test("domainTally over a ledger it cannot read is null with the parser's own refusal, where ac_domain_tally failed with awk's (named)", () => {
  if (process.getuid?.() === 0) return;
  const t = dir("tu");
  mkdirSync(join(t, "records"));
  writeFileSync(join(t, "records", "backlog.md"), "## Queued\n");
  chmodSync(join(t, "records", "backlog.md"), 0o000);
  const got = twin('say(String(L.domainTally("pay")))', { AC_HOME: t });
  const want = bash('. "$0/ac-lib.sh"; ac_domain_tally pay; printf "rc=%s" "$?"', { AC_HOME: t });
  chmodSync(join(t, "records", "backlog.md"), 0o644);
  expect(got.out).toBe("null");
  expect(got.err).toBe(`ERROR: cannot read ${t}/records/backlog.md\n`);
  expect(want.out).toBe("rc=2");
  expect(want.err).toContain("can't open file");
});

test("the awk programs src/domain.ts spawns are the frozen original's, byte for byte", () => {
  const fx = readFileSync(join(ROOT, "tests", "fixtures", "ac-domain.sh"), "latin1");
  const mod = readFileSync(join(ROOT, "src", "domain.ts"), "latin1");
  const constant = (name: string): string => {
    const m = new RegExp(`const ${name} = (?:String\\.raw)?\`([^\`]*)\`;`).exec(mod);
    expect(m).not.toBeNull();
    expect(m![1]).not.toContain("${");
    if (!mod.includes(`const ${name} = String.raw`)) expect(m![1]).not.toContain("\\");
    return m![1]!;
  };
  expect(constant("HOLDS_AWK")).toBe(quoted(fx, `awk -v n="$2" '`));
  expect(constant("ROW_OF_AWK")).toBe(quoted(fx, `LC_ALL=C awk -v id="$1" '`));
  expect(constant("STAMP_AWK")).toBe(quoted(fx, `awk -v n="$2" \\\n    '`));
  expect(constant("RETIRE_AWK")).toBe(quoted(fx, `  awk -v n="$name" '`));
});
