// session.test.ts - the lib.ts twins src/session.ts introduced: metaGet held
// to the values ac_meta_get answered over the line shapes a meta can carry
// (captured once from bin/ac-lib.sh and fixed here, so the sweep spawns no
// shell), and its warn/throw against the bash original's. The CLI contract
// itself (every verb, stdout, stderr, exit) is tests/sh/ac-session.test.sh's.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { metaGet } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");

test("metaGet reads what ac_meta_get reads, over every line shape a meta carries", () => {
  const dir = mkdtempSync(join(tmpdir(), "ac-session-meta-"));
  try {
    // [body, the keys that read non-empty]; every other key reads "".
    const cases: Record<string, [string, Record<string, string>]> = {
      plain: ["harness=claude\nsession_id=abc\n", { harness: "claude", session_id: "abc" }],
      lastWins: ["worktree=/one\nworktree=/two\n", { worktree: "/two" }],
      emptyLastReadsAbsent: ["worktree=/one\nworktree=\n", {}],
      valueKeepsEquals: ["window=crew:x=y=z\n", { window: "crew:x=y=z" }],
      bareKeyLine: ["harness\nsession_id=s\n", { session_id: "s" }],
      prefixKeyNoMatch: ["harnessx=codex\nharness=claude\n", { harness: "claude", harnessx: "codex" }],
      crlf: ["harness=claude\r\nworktree=/wt\r\n", { harness: "claude\r", worktree: "/wt\r" }],
      noTrailingNewline: ["harness=claude\nsession_id=tail", { harness: "claude", session_id: "tail" }],
      // The fixture carries real UTF-8 bytes; the twin answers them as latin1.
      utf8Path: ["worktree=/tmp/đường/dẫn\n", { worktree: Buffer.from("/tmp/đường/dẫn", "utf8").toString("latin1") }],
      spaces: ["worktree= /with space \n", { worktree: " /with space " }],
    };
    for (const [name, [body, want]] of Object.entries(cases)) {
      const f = join(dir, `${name}.meta`);
      writeFileSync(f, body, "utf8");
      for (const key of ["harness", "session_id", "worktree", "window", "harnessx", "missing"])
        expect([name, key, metaGet(f, key)]).toEqual([name, key, want[key] ?? ""]);
    }
    // Absent at both instants, and a directory where a file was expected:
    // empty, no error - `[ -f ]` fails and the bash returns 0.
    expect(metaGet(join(dir, "gone.meta"), "harness")).toBe("");
    mkdirSync(join(dir, "adir.meta"));
    expect(metaGet(join(dir, "adir.meta"), "harness")).toBe("");
    // A FIFO with no writer: never opened (a read would wait), empty at once.
    const fifo = join(dir, "fifo.meta");
    expect(Bun.spawnSync(["mkfifo", fifo]).exitCode).toBe(0);
    const t0 = Date.now();
    expect(metaGet(fifo, "harness")).toBe("");
    expect(Date.now() - t0).toBeLessThan(1000);
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
