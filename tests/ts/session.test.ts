// session.test.ts - the lib.ts twins src/session.ts introduced, held to their
// bash originals differentially: metaGet against ac_meta_get over the line
// shapes a meta can carry, and die/warn's byte form. The CLI contract itself
// (every verb, stdout, stderr, exit) is tests/sh/ac-session.test.sh's, whose
// differential leg runs the frozen bash original beside the shim.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { metaGet } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");

function bashMetaGet(file: string, key: string): { out: string; rc: number } {
  const r = Bun.spawnSync(
    ["bash", "-c", '. "$1/ac-lib.sh"; ac_meta_get "$2" "$3"', "--", binDir, file, key],
    { stdout: "pipe", stderr: "pipe" },
  );
  // The bash side is read in a command substitution by every caller, which
  // drops the trailing newline; the twin returns the bare value.
  return { out: r.stdout.toString("latin1").replace(/\n$/, ""), rc: r.exitCode ?? -1 };
}

test("metaGet reads what ac_meta_get reads, over every line shape a meta carries", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-session-meta-"));
  try {
    const cases: Record<string, string> = {
      plain: "harness=claude\nsession_id=abc\n",
      lastWins: "worktree=/one\nworktree=/two\n",
      emptyLastReadsAbsent: "worktree=/one\nworktree=\n",
      valueKeepsEquals: "window=crew:x=y=z\n",
      bareKeyLine: "harness\nsession_id=s\n",
      prefixKeyNoMatch: "harnessx=codex\nharness=claude\n",
      crlf: "harness=claude\r\nworktree=/wt\r\n",
      noTrailingNewline: "harness=claude\nsession_id=tail",
      utf8Path: "worktree=/tmp/đường/dẫn\n",
      spaces: "worktree= /with space \n",
    };
    for (const [name, body] of Object.entries(cases)) {
      const f = join(dir, `${name}.meta`);
      // utf8: the fixture carries real UTF-8 bytes; the twin reads them as latin1
      // and must answer the bytes bash answers.
      writeFileSync(f, body, "utf8");
      for (const key of ["harness", "session_id", "worktree", "window", "harnessx", "missing"]) {
        const want = bashMetaGet(f, key);
        expect(want.rc).toBe(0);
        expect(metaGet(f, key)).toBe(want.out);
      }
    }
    // Absent at both instants, and a directory where a file was expected:
    // empty, no error - `[ -f ]` fails and the bash returns 0.
    expect(metaGet(join(dir, "gone.meta"), "harness")).toBe("");
    mkdirSync(join(dir, "adir.meta"));
    expect(metaGet(join(dir, "adir.meta"), "harness")).toBe("");
    expect(bashMetaGet(join(dir, "adir.meta"), "harness")).toEqual({ out: "", rc: 0 });
    // A FIFO with no writer: never opened (a read would wait), empty at once.
    const fifo = join(dir, "fifo.meta");
    expect(Bun.spawnSync(["mkfifo", fifo]).exitCode).toBe(0);
    const t0 = Date.now();
    expect(metaGet(fifo, "harness")).toBe("");
    expect(Date.now() - t0).toBeLessThan(1000);
    expect(bashMetaGet(fifo, "harness")).toEqual({ out: "", rc: 0 });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("metaGet warns and throws where ac_meta_get warns and returns 1 (present, unreadable)", () => {
  if (process.getuid?.() === 0) return;
  const dir = mkdtempSync(join(tmpdir(), "ac-session-meta-"));
  const f = join(dir, "locked.meta");
  try {
    writeFileSync(f, "harness=claude\n", { mode: 0o000 });
    const r = Bun.spawnSync(
      ["bash", "-c", '. "$1/ac-lib.sh"; ac_meta_get "$2" harness', "--", binDir, f],
      { stdout: "pipe", stderr: "pipe" },
    );
    expect(r.exitCode).toBe(1);
    expect(r.stderr.toString()).toBe(`WARN: cannot read meta file ${f}\n`);
    // The twin's WARN bytes and its failure, read from a subprocess so the fd-2
    // write is captured, not only the throw.
    const t = Bun.spawnSync(
      [process.execPath, "-e", 'import { metaGet } from "./src/lib.ts"; try { metaGet(process.argv[1], "harness"); } catch { process.exit(3); }', f],
      { cwd: join(import.meta.dir, "..", ".."), stdout: "pipe", stderr: "pipe" },
    );
    expect(t.exitCode).toBe(3);
    expect(t.stderr.toString()).toBe(r.stderr.toString());
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
