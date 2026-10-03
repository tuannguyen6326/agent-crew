// fleets.test.ts - the lib.ts twins src/fleets.ts introduced, held to their
// bash originals differentially: metaIsVerify against ac_meta_is_verify,
// watcherBeatRead against ac_watcher_beat_read, wakeScopeOk and
// wakeFamilySpools against ac_wake_scope_ok / ac_wake_family_spools
// (ac-wake-lib.sh), and configReadDir against the original's own cfg_read,
// lifted from the frozen oracle. The bash side runs under LC_ALL=C where a
// glob's ORDER is compared (the port lists in byte order; under a UTF-8 locale
// bash's glob follows libc collation) and under the operators' UTF-8 locale
// where the [:space:] CLASS is compared. The CLI contract itself is
// tests/sh/ac-fleets.test.sh's, whose differential leg runs the frozen
// original beside the shim.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configReadDir, metaIsVerify, wakeFamilySpools, wakeScopeOk, watcherBeatRead } from "../../src/lib.ts";

const root = join(import.meta.dir, "..", "..");
const binDir = join(root, "bin");
const oracle = join(root, "tests", "fixtures", "ac-fleets.sh");

function bash(body: string, locale: string, ...args: string[]) {
  const r = Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; . "$0/ac-wake-lib.sh"; ${body}`, binDir, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: locale },
  });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

test("metaIsVerify answers ac_meta_is_verify over every kind shape, silently on an unreadable meta", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-fleets-verify-"));
  try {
    const cases: Record<string, string> = {
      codereview: "kind=verify-codereview\nproject=x\n",
      bareDash: "kind=verify-\n",
      ship: "kind=ship\n",
      verifyNoDash: "kind=verify\n",
      kindless: "project=x\n",
      lastWins: "kind=ship\nkind=verify-qa\n",
      lastWinsEmpty: "kind=verify-qa\nkind=\n",
      prefixKey: "kindx=verify-qa\n",
      spaced: "kind= verify-qa\n",
    };
    for (const [name, body] of Object.entries(cases)) {
      const f = join(dir, `${name}.meta`);
      writeFileSync(f, body);
      const want = bash('ac_meta_is_verify "$1"; echo "rc=$?"', "C", f);
      expect([name, metaIsVerify(f)]).toEqual([name, want.out === "rc=0\n"]);
      expect(want.err).toBe("");
    }
    expect(metaIsVerify(join(dir, "gone.meta"))).toBe(false);
    mkdirSync(join(dir, "adir.meta"));
    expect(metaIsVerify(join(dir, "adir.meta"))).toBe(false);
    if (process.getuid?.() !== 0) {
      // The bash drops ac_meta_get's WARN (`2>/dev/null`) and reads the failure
      // as "not a verifier"; the twin must print nothing either.
      const locked = join(dir, "locked.meta");
      writeFileSync(locked, "kind=verify-qa\n", { mode: 0o000 });
      const want = bash('ac_meta_is_verify "$1"; echo "rc=$?"', "C", locked);
      expect(want).toEqual({ out: "rc=1\n", err: "", rc: 0 });
      const t = Bun.spawnSync(
        [process.execPath, "-e", 'import { metaIsVerify } from "./src/lib.ts"; process.exit(metaIsVerify(process.argv[1]) ? 0 : 1);', locked],
        { cwd: root, stdout: "pipe", stderr: "pipe" },
      );
      expect([t.exitCode, t.stderr.toString()]).toEqual([1, ""]);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("watcherBeatRead prints the `<beat> <note>` line ac_watcher_beat_read prints, scoped or not", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-fleets-beat-"));
  try {
    const sd = join(dir, "state");
    mkdirSync(sd);
    const contents: (string | null)[] = [null, "0\n", "0", "0009\n", "12\n34\n", "1700000000\n\n", "", "abc", "12 34", " 12", "\n", "123\r\n", "1700000000", "-5\n", "+5\n", "1e3\n"];
    for (const scope of ["", "fam", "bad.name", "a/b"]) {
      for (const c of contents) {
        const beacon = join(sd, wakeScopeOk(scope) ? `.last-watcher-beat.${scope}` : ".last-watcher-beat");
        rmSync(beacon, { force: true });
        if (c !== null) writeFileSync(beacon, c);
        const want = bash('ac_watcher_beat_read "$1" "$2"', "C", sd, scope);
        expect(want.rc).toBe(0);
        expect([scope, c, watcherBeatRead(sd, scope)]).toEqual([scope, c, want.out.replace(/\n$/, "")]);
      }
    }
    // A directory where the beacon should be: present, unreadable as a beat.
    rmSync(join(sd, ".last-watcher-beat"), { force: true });
    mkdirSync(join(sd, ".last-watcher-beat"));
    const want = bash('ac_watcher_beat_read "$1"', "C", sd);
    expect(watcherBeatRead(sd)).toBe(want.out.replace(/\n$/, ""));
    expect(watcherBeatRead(sd).startsWith("0 no beat on record (the beacon is unreadable)")).toBe(true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("wakeScopeOk refuses what ac_wake_scope_ok refuses under LC_ALL=C, and refuses per the text where bash's UTF-8 range does not", () => {
  const scopes = ["fam", "Fam_2", "a-b", "", "bad.name", "a/b", ".", "..", "a b", "-", "_", "0", "fam\n", "ét"];
  for (const s of scopes) {
    const want = bash('ac_wake_scope_ok "$1"; echo "rc=$?"', "C", s);
    expect([s, wakeScopeOk(s)]).toEqual([s, want.out === "rc=0\n"]);
  }
  // Under en_US.UTF-8 bash 3.2's `[!A-Za-z0-9_-]` collates `é` inside a range
  // and ACCEPTS it (program rule: every bash charset guard not wrapped in
  // LC_ALL=C is wider than its text); the twin refuses per the text.
  expect(bash('ac_wake_scope_ok "$1"; echo "rc=$?"', "en_US.UTF-8", "ét").out).toBe("rc=0\n");
  expect(wakeScopeOk("ét")).toBe(false);
});

test("wakeFamilySpools lists the dirs ac_wake_family_spools lists, in byte order", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-fleets-spools-"));
  try {
    const sd = join(dir, "state");
    mkdirSync(sd);
    for (const d of [".wake-spool", ".wake-spool.fam1", ".wake-spool.Fam_2", ".wake-spool.bad.name", ".wake-spool-draining.1", ".wake-spool.", ".wake-spool.a-b", ".wake-spool.ZZ", ".wake-spool.a1"]) mkdirSync(join(sd, d));
    writeFileSync(join(sd, ".wake-spool.afile"), "not a dir\n");
    symlinkSync(join(sd, ".wake-spool.fam1"), join(sd, ".wake-spool.link"));
    symlinkSync(join(sd, "nowhere"), join(sd, ".wake-spool.dangling"));
    const want = bash('ac_wake_family_spools "$1"', "C", sd);
    expect(want.rc).toBe(0);
    expect(wakeFamilySpools(sd)).toEqual(want.out.split("\n").slice(0, -1));
    expect(wakeFamilySpools(sd).map((p) => p.slice(sd.length + 1))).toEqual([".wake-spool.Fam_2", ".wake-spool.ZZ", ".wake-spool.a-b", ".wake-spool.a1", ".wake-spool.fam1", ".wake-spool.link"]);
    expect(wakeFamilySpools(join(dir, "nostate"))).toEqual([]);
    expect(bash('ac_wake_family_spools "$1"', "C", join(dir, "nostate")).out).toBe("");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("configReadDir reads what the original's cfg_read reads: first line, [:space:]-trimmed, default when absent", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-fleets-cfg-"));
  try {
    const cases: Record<string, string> = {
      plain: "codex\n",
      padded: "  codex \r\n",
      tabs: "\tx\ty\t\n",
      bom: "﻿direct\n",
      twoLines: "a\nb\n",
      noNewline: "tail",
      empty: "",
      blankLine: "\n",
      nbsp: " x \n",
      lineSep: " x \n",
      nel: "\u0085x\u0085\n",
      utf8: "đường\n",
      digits: " 8 \n",
    };
    for (const [name, body] of Object.entries(cases)) {
      writeFileSync(join(dir, name), body, "utf8");
      const want = bash('eval "$(sed -n "/^cfg_read()/,/^}/p" "$1")"; cfg_read "$2" "$3" "$4"', "en_US.UTF-8", oracle, dir, name, "dflt");
      expect(want.rc).toBe(0);
      expect([name, configReadDir(dir, name, "dflt")]).toEqual([name, want.out]);
    }
    mkdirSync(join(dir, "adir"));
    for (const name of ["absent", "adir"]) {
      const want = bash('eval "$(sed -n "/^cfg_read()/,/^}/p" "$1")"; cfg_read "$2" "$3" "$4"', "en_US.UTF-8", oracle, dir, name, "dflt");
      expect([name, configReadDir(dir, name, "dflt")]).toEqual([name, "dflt"]);
      expect(want.out).toBe("dflt");
    }
    expect(configReadDir(dir, "absent")).toBe("");
    // Bytes in, bytes out: the UTF-8 value is answered as its latin1 bytes.
    expect(configReadDir(dir, "utf8")).toBe(Buffer.from("đường", "utf8").toString("latin1"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
