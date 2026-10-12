// tree.test.ts - what src/tree.ts brought into src/lib.ts, held to the bash it
// twins: worktreeStatus (and the sparse rung inside it) against
// ac_worktree_status in the live bin/ac-lib.sh (no entry calls it since
// src/teardown.ts), under C and UTF-8; defaultRef against ac_default_ref; crewStateDir
// against crew_state_dir lifted from the frozen tests/fixtures/ac-tree.sh; and
// the two git hook bodies the port installs, byte for byte and mode for mode,
// against what the frozen original installs. The CLI contract itself is
// tests/sh/ac-tree.test.sh's, whose differential leg runs the frozen original
// beside the shim.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin");
const LIB = join(ROOT, "src", "lib.ts");
const FIXTURE = join(ROOT, "tests", "fixtures", "ac-tree.sh");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-tree-ts-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

type Run = { code: number | null; out: string; err: string };

const GIT_ENV = { GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t", HOME: W };

function bash(script: string, env: Record<string, string>, args: string[] = []): Run {
  const r = Bun.spawnSync(["/bin/bash", "-c", script, BIN, ...args], {
    env: { PATH: process.env.PATH!, LC_ALL: "C", ...GIT_ENV, ...env },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

function twin(body: string, env: Record<string, string>): Run {
  const r = Bun.spawnSync(
    [process.execPath, "-e", `const L = await import(${JSON.stringify(LIB)}); const say = (s) => process.stdout.write(Buffer.from(String(s), "latin1")); ${body}`],
    { cwd: ROOT, env: { PATH: process.env.PATH!, LC_ALL: "C", ...GIT_ENV, ...env }, stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 30000 },
  );
  return { code: r.exitCode, out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1") };
}

function git(dir: string, ...args: string[]): string {
  const r = Bun.spawnSync(["git", "-C", dir, ...args], { env: { PATH: process.env.PATH!, ...GIT_ENV }, stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString()}`);
  return r.stdout.toString();
}

let n = 0;
function dir(name: string): string {
  const d = join(W, `${name}${n++}`);
  mkdirSync(d, { recursive: true });
  return d;
}

// A repo whose tree holds every entry kind the hidden-bit scan reads: a plain
// file, an executable, a symlink, a C-quoted name, a newline-only name and a
// gitlink - and a linked worktree of it, the shape a pool slot has.
function repo(): { main: string; wt: string } {
  const main = dir("repo");
  git(main, "init", "-q", "-b", "main");
  writeFileSync(join(main, "file.txt"), "hello\n");
  writeFileSync(join(main, "exec.sh"), "#!/bin/sh\n");
  chmodSync(join(main, "exec.sh"), 0o755);
  symlinkSync("file.txt", join(main, "link"));
  writeFileSync(join(main, "エ.txt"), "quoted\n");
  writeFileSync(join(main, "\n"), "nl\n");
  git(main, "add", "-A");
  git(main, "update-index", "--add", "--cacheinfo", "160000,0123456789012345678901234567890123456789,sub");
  git(main, "commit", "-qm", "init");
  const wt = join(main, ".crew", "worktrees", "1-repo");
  git(main, "worktree", "add", "-q", "--detach", wt);
  return { main, wt };
}

const STATUS_SH = '. "$0/ac-lib.sh"; ac_worktree_status "$1"; printf "rc=%s" "$?"';
const statusTwin = (wt: string): string => `const r = L.worktreeStatus(${JSON.stringify(wt)}); say(r.out + "rc=" + r.status);`;

// Each case mutates a fresh slot, then both sides read it under both locales.
const CASES: [string, (wt: string) => void][] = [
  ["clean", () => {}],
  ["porcelain", (wt) => {
    writeFileSync(join(wt, "file.txt"), "changed\n");
    writeFileSync(join(wt, "new.txt"), "untracked\n");
  }],
  ["assume-unchanged edit", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    writeFileSync(join(wt, "file.txt"), "hidden edit\n");
  }],
  ["assume-unchanged deletion", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    rmSync(join(wt, "file.txt"));
  }],
  ["assume-unchanged x-bit set", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    chmodSync(join(wt, "file.txt"), 0o755);
  }],
  ["x-bit set under core.fileMode=false", (wt) => {
    git(wt, "config", "core.fileMode", "false");
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    chmodSync(join(wt, "file.txt"), 0o755);
  }],
  ["assume-unchanged x-bit cleared", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "exec.sh");
    chmodSync(join(wt, "exec.sh"), 0o644);
  }],
  ["assume-unchanged file now a directory", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    rmSync(join(wt, "file.txt"));
    mkdirSync(join(wt, "file.txt"));
  }],
  ["assume-unchanged file now a symlink", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "file.txt");
    rmSync(join(wt, "file.txt"));
    symlinkSync("exec.sh", join(wt, "file.txt"));
  }],
  ["assume-unchanged symlink untouched", (wt) => git(wt, "update-index", "--assume-unchanged", "link")],
  ["assume-unchanged symlink retargeted", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "link");
    rmSync(join(wt, "link"));
    symlinkSync("exec.sh", join(wt, "link"));
  }],
  ["assume-unchanged symlink now a file", (wt) => {
    git(wt, "update-index", "--assume-unchanged", "link");
    rmSync(join(wt, "link"));
    writeFileSync(join(wt, "link"), "file.txt");
  }],
  ["skip-worktree deletion outside a sparse checkout", (wt) => {
    git(wt, "update-index", "--skip-worktree", "file.txt");
    rmSync(join(wt, "file.txt"));
  }],
  ["sparse rules exclude the absent files", (wt) => git(wt, "sparse-checkout", "set", "--no-cone", "/nothing-here/")],
  ["sparse rules include an absent skip-worktree file", (wt) => {
    git(wt, "sparse-checkout", "set", "--no-cone", "/*");
    git(wt, "update-index", "--skip-worktree", "file.txt");
    rmSync(join(wt, "file.txt"));
  }],
  ["newline-only name, skip-worktree, deleted", (wt) => {
    git(wt, "update-index", "--skip-worktree", "--", "\n");
    rmSync(join(wt, "\n"));
  }],
  ["quoted name flagged and clean", (wt) => git(wt, "update-index", "--assume-unchanged", "エ.txt")],
  ["quoted name flagged and edited", (wt) => {
    git(wt, "update-index", "--skip-worktree", "エ.txt");
    writeFileSync(join(wt, "エ.txt"), "edited\n");
  }],
  ["gitlink flagged", (wt) => git(wt, "update-index", "--assume-unchanged", "sub")],
  ["operations in progress", (wt) => {
    const gd = git(wt, "rev-parse", "--absolute-git-dir").trim();
    for (const f of ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]) writeFileSync(join(gd, f), "x\n");
    for (const d of ["rebase-merge", "rebase-apply", "sequencer"]) mkdirSync(join(gd, d));
  }],
  ["broken gitdir", (wt) => {
    const gd = git(wt, "rev-parse", "--absolute-git-dir").trim();
    rmSync(gd, { recursive: true, force: true });
  }],
];

for (const [name, mutate] of CASES) {
  test(`worktreeStatus is ac_worktree_status: ${name}, under C and UTF-8`, () => {
    const { main, wt } = repo();
    mutate(wt);
    for (const loc of ["C", "en_US.UTF-8"]) {
      for (const at of [wt, main]) {
        const want = bash(STATUS_SH, { LC_ALL: loc }, [at]);
        const got = twin(statusTwin(at), { LC_ALL: loc });
        expect({ name, loc, at, out: got.out, err: got.err }).toEqual({ name, loc, at, out: want.out, err: want.err });
      }
    }
  });
}

test("worktreeStatus is ac_worktree_status for a directory git cannot read and one that is gone", () => {
  for (const at of [dir("plain"), join(W, "gone")]) {
    const want = bash(STATUS_SH, {}, [at]);
    expect(twin(statusTwin(at), {}).out).toBe(want.out);
  }
});

// `ac-tree.sh list` reads LEASED slots too, and an index rewritten there takes
// index.lock out from under the crewmate's own git.
test("neither status reader rewrites the index of a tree whose stat info is stale", () => {
  const old = new Date("2020-01-01T00:00:00Z");
  const readers: [string, (wt: string) => Run][] = [
    ["ac_worktree_status", (wt) => bash(STATUS_SH, {}, [wt])],
    ["worktreeStatus", (wt) => twin(statusTwin(wt), {})],
  ];
  for (const [name, read] of readers) {
    const { wt } = repo();
    const index = join(git(wt, "rev-parse", "--absolute-git-dir").trim(), "index");
    utimesSync(join(wt, "file.txt"), old, old);
    utimesSync(index, old, old);
    read(wt);
    expect({ name, mtime: statSync(index).mtimeMs }).toEqual({ name, mtime: old.getTime() });
  }
});

// A git on PATH that answers check-rules itself: 129 is a git older than 2.41
// (the sparse flag alone decides), any other failure is no exclusion.
test("worktreeStatus asks the PATH's git for the sparse rules, and reads 129 as an old git", () => {
  for (const rc of [129, 128]) {
    const { wt } = repo();
    git(wt, "sparse-checkout", "set", "--no-cone", "/nothing-here/");
    const stub = dir("oldgit");
    writeFileSync(join(stub, "git"), `#!/bin/sh\ncase " $* " in *" check-rules "*) exit ${rc} ;; esac\nexec "${Bun.which("git")}" "$@"\n`);
    chmodSync(join(stub, "git"), 0o755);
    const env = { PATH: `${stub}:${process.env.PATH}` };
    const want = bash(STATUS_SH, env, [wt]);
    expect(twin(statusTwin(wt), env).out).toBe(want.out);
    expect(want.out.includes("H  file.txt")).toBe(rc !== 129);
  }
});

// Only a file whose hidden bit is set is re-hashed, whatever the locale - the
// PATH git counts every hash-object both sides spawn.
test("worktreeStatus hashes exactly the files ac_worktree_status hashes, through the PATH's git", () => {
  const { wt } = repo();
  git(wt, "update-index", "--assume-unchanged", "file.txt", "link");
  for (const loc of ["C", "en_US.UTF-8"]) {
    const stub = dir("countgit");
    const calls = join(stub, "calls");
    writeFileSync(calls, "");
    writeFileSync(join(stub, "git"), `#!/bin/sh\ncase " $* " in *" hash-object "*) printf x >>"${calls}" ;; esac\nexec "${Bun.which("git")}" "$@"\n`);
    chmodSync(join(stub, "git"), 0o755);
    const env = { PATH: `${stub}:${process.env.PATH}`, LC_ALL: loc };
    bash(STATUS_SH, env, [wt]);
    const bashCalls = readFileSync(calls, "latin1").length;
    writeFileSync(calls, "");
    twin(statusTwin(wt), env);
    expect({ loc, calls: readFileSync(calls, "latin1").length }).toEqual({ loc, calls: bashCalls });
    expect(bashCalls).toBe(2);
  }
});

test("defaultRef is ac_default_ref: origin's ref when origin has the default branch, else the branch", () => {
  const bare = dir("origin");
  git(bare, "init", "-q", "--bare", "-b", "main");
  const shapes: [string, (r: string) => void][] = [
    ["no origin", () => {}],
    ["origin with main", (r) => {
      git(r, "remote", "add", "origin", bare);
      git(r, "push", "-q", "origin", "main");
      git(r, "fetch", "-q", "origin");
    }],
    ["origin/HEAD naming another branch", (r) => {
      git(r, "remote", "add", "origin", bare);
      git(r, "push", "-q", "origin", "main:develop");
      git(r, "fetch", "-q", "origin");
      git(r, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop");
    }],
    ["origin/HEAD naming a branch origin lacks", (r) => {
      git(r, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone");
    }],
    ["master only", (r) => git(r, "branch", "-m", "main", "master")],
    ["detached, no main or master", (r) => {
      git(r, "branch", "-m", "main", "trunk");
      git(r, "checkout", "-q", "--detach");
    }],
  ];
  for (const [name, shape] of shapes) {
    const r = dir("dref");
    git(r, "init", "-q", "-b", "main");
    git(r, "commit", "-q", "--allow-empty", "-m", "init");
    shape(r);
    const want = bash('. "$0/ac-lib.sh"; ac_default_ref "$1"', {}, [r]);
    const got = twin(`say(L.defaultRef(${JSON.stringify(r)}))`, {});
    expect({ name, out: got.out, err: got.err }).toEqual({ name, out: want.out.replace(/\n$/, ""), err: want.err });
  }
});

// The function as the frozen original defines it, sourced after the live lib.
function crewStateDirSh(): string {
  const src = readFileSync(FIXTURE, "latin1");
  const start = src.indexOf("crew_state_dir() {");
  return src.slice(start, src.indexOf("\n}\n", start) + 3);
}

test("crewStateDir is crew_state_dir: AC_FLEET_STATE verbatim, else the home's state/ minted, else nothing", () => {
  const fn = crewStateDirSh();
  const h = dir("home");
  const bh = dir("bhome");
  const cases: [string, (home: string) => Record<string, string>][] = [
    ["fleet state, never checked", () => ({ AC_FLEET_STATE: "/nowhere/state/" })],
    ["fleet state beside a home", (home) => ({ AC_FLEET_STATE: "x y", AC_HOME: home })],
    ["home", (home) => ({ AC_HOME: home })],
    ["empty fleet state, home", (home) => ({ AC_FLEET_STATE: "", AC_HOME: home })],
    ["neither", () => ({})],
    ["both empty", () => ({ AC_FLEET_STATE: "", AC_HOME: "" })],
  ];
  for (const [name, env] of cases) {
    const want = bash(`. "$0/ac-lib.sh"; ${fn} crew_state_dir; printf "rc=%s" "$?"`, env(bh));
    const got = twin('const d = L.crewStateDir(); say((d === "" ? "" : d + "\\n") + "rc=0")', env(h));
    expect({ name, out: got.out.split(h).join("H"), err: got.err }).toEqual({ name, out: want.out.split(bh).join("H"), err: want.err });
  }
  expect(statSync(join(h, "state")).isDirectory()).toBe(true);
  // Named divergence (HOME RESOLUTION): an AC_HOME cd cannot enter is cd's own
  // line in the original and names the variable in the port; both print no dir.
  const want = bash(`. "$0/ac-lib.sh"; ${fn} crew_state_dir`, { AC_HOME: join(W, "missing") });
  const got = twin("say(L.crewStateDir())", { AC_HOME: join(W, "missing") });
  expect([want.out, got.out]).toEqual(["", ""]);
  expect(want.err).toContain(`cd: ${join(W, "missing")}: No such file or directory`);
  expect(got.err).toBe(`ERROR: AC_HOME is not a readable directory: ${join(W, "missing")}\n`);
});

// The hook bodies the frozen original installs from its two heredocs.
function heredoc(tag: string): string {
  const src = readFileSync(FIXTURE, "latin1");
  const start = src.indexOf(`<<'${tag}'\n`) + `<<'${tag}'\n`.length;
  return src.slice(start, src.indexOf(`\n${tag}\n`, start) + 1);
}

// A bin/ for the frozen original: the live scripts beside it, src/ and
// dashboard/ linked, as tests/sh/helpers.sh's make_oracle_bin builds one.
function oracleBin(): string {
  const d = dir("oracle");
  mkdirSync(join(d, "bin"));
  const r = Bun.spawnSync(["/bin/sh", "-c", 'cp "$0"/*.sh "$1/bin/" && cp "$2" "$1/bin/ac-tree.sh"', BIN, d, FIXTURE]);
  expect(r.exitCode).toBe(0);
  symlinkSync(join(ROOT, "src"), join(d, "src"));
  symlinkSync(join(ROOT, "dashboard"), join(d, "dashboard"));
  return join(d, "bin");
}

test("the two guard hooks the port installs are the frozen original's bytes and modes, under umask 022 and 077", () => {
  const obin = oracleBin();
  const want = { "pre-commit": heredoc("GUARD"), "commit-msg": heredoc("MSGGUARD") };
  expect(want["pre-commit"]).toStartWith("#!/usr/bin/env bash\n# ac-crew-primary-commit-guard ");
  expect(want["commit-msg"]).toStartWith("#!/usr/bin/env bash\n# ac-crew-agent-trailer-guard ");
  for (const mask of ["022", "077"]) {
    const installed: Record<string, { bytes: string; mode: number }>[] = [];
    for (const bin of [obin, BIN]) {
      const r = dir("hooks");
      git(r, "init", "-q", "-b", "main");
      git(r, "commit", "-q", "--allow-empty", "-m", "init");
      const run = Bun.spawnSync(["/bin/sh", "-c", `umask ${mask}; exec "$0" get --repo "$1"`, join(bin, "ac-tree.sh"), r], {
        env: { PATH: process.env.PATH!, LC_ALL: "C", ...GIT_ENV },
        stdin: "ignore",
        stdout: "pipe",
        stderr: "pipe",
      });
      expect({ bin, mask, code: run.exitCode, err: run.stderr.toString() }).toMatchObject({ bin, mask, code: 0 });
      const got: Record<string, { bytes: string; mode: number }> = {};
      for (const h of ["pre-commit", "commit-msg"]) {
        const f = join(r, ".git", "hooks", h);
        got[h] = { bytes: readFileSync(f, "latin1"), mode: statSync(f).mode & 0o7777 };
      }
      installed.push(got);
    }
    expect({ mask, port: installed[1] }).toEqual({ mask, port: installed[0] });
    expect(installed[1]!["pre-commit"]!.bytes).toBe(want["pre-commit"]);
    expect(installed[1]!["commit-msg"]!.bytes).toBe(want["commit-msg"]);
    expect(installed[1]!["pre-commit"]!.mode).toBe(mask === "022" ? 0o755 : 0o700);
  }
}, 60000);

test("epicBaseFor is ac_epic_base_for from a crewmate pane: no AC_HOME, the home AC_FLEET_STATE's parent names (a symlinked state dir by its target's), neither is no fence", () => {
  const h = dir("fh");
  for (const d of ["records", "state", "data/ep1", "data/archive/2026/ep9"]) mkdirSync(join(h, d), { recursive: true });
  writeFileSync(join(h, "records", "backlog.md"), "## Queued\n\n- [ ] ep1-s1 - story; epic:ep1\n- [ ] ep9-s1 - story; epic:ep9\n- [ ] plain - none\n");
  writeFileSync(join(h, "data", "ep1", "branches"), "rf epic/ep1 key=v\n");
  writeFileSync(join(h, "data", "archive", "2026", "ep9", "branches"), "rf epic/ep9\n");
  // `..` past a symlinked state dir is the kernel's, never a lexical cut.
  const ln = join(dir("fl"), "state-link");
  symlinkSync(join(h, "state"), ln);
  const cases: [string, Record<string, string>][] = [
    ["fleet state", { AC_FLEET_STATE: join(h, "state") }],
    ["trailing slash", { AC_FLEET_STATE: `${join(h, "state")}/` }],
    ["through a symlink", { AC_FLEET_STATE: ln }],
    ["neither", {}],
    ["AC_HOME first", { AC_HOME: h, AC_FLEET_STATE: "/nonexistent/state" }],
  ];
  for (const [label, env] of cases)
    for (const id of ["ep1-s1", "ep1-s1-verify", "ep9-s1", "plain", "nosuch"]) {
      const want = bash('. "$0/ac-lib.sh"; ac_epic_base_for "$1" rf; printf "rc=%s" "$?"', env, [id]);
      const got = twin(`const e = L.epicBaseFor(${JSON.stringify(id)}, "rf"); say((e.rc === 0 ? e.entry + "\\n" : "") + "rc=" + e.rc);`, env);
      expect({ label, id, out: got.out }).toEqual({ label, id, out: want.out });
    }
  expect(twin('const e = L.epicBaseFor("ep1-s1-verify", "rf"); say(e.rc === 0 ? e.entry : "rc=" + e.rc);', { AC_FLEET_STATE: ln }).out).toBe("epic/ep1 key=v");
  expect(bash('. "$0/ac-lib.sh"; ac_epic_base_for ep1-s1 rf', {}).err).toContain("AC_HOME is not set");
});
