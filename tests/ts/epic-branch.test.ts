// epic-branch.test.ts - the lib.ts twins src/epic-branch.ts introduced, held to
// their bash originals differentially: epicBranchesFile against
// ac_epic_branches_file (live first, the charset guard, the archive glob),
// epicBranchEntry against ac_epic_branch_entry (the retired marker, awk's
// field rejoin and its numeric ==), defaultBranch / freshestRef against their
// arms over real repos, and pushControlPlane against ac_git_push_control_plane
// through a refusing pre-push hook. The CLI contract itself (every verb,
// stdout, stderr, exit) is tests/sh/ac-epic-branch.test.sh's, whose
// differential leg runs the frozen bash original beside the shim.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { defaultBranch, epicBranchEntry, epicBranchesFile, freshestRef, pushControlPlane } from "../../src/lib.ts";

const binDir = join(import.meta.dir, "..", "..", "bin");
const made: string[] = [];
afterAll(() => {
  delete process.env.AC_HOME;
  made.forEach((d) => rmSync(d, { recursive: true, force: true }));
});

function freshHome(): string {
  const h = realpathSync(mkdtempSync(join(tmpdir(), "ac-epic-branch-")));
  made.push(h);
  process.env.AC_HOME = h;
  return h;
}

function bashLib(fn: string, args: string[]): { out: string; rc: number } {
  const r = Bun.spawnSync(["bash", "-c", `. "$1/ac-lib.sh"; ${fn} "\${@:2}"`, "--", binDir, ...args], {
    env: { PATH: process.env.PATH!, AC_HOME: process.env.AC_HOME! },
    stdout: "pipe",
    stderr: "pipe",
  });
  // Every caller reads the bash side in a command substitution, which drops
  // the trailing newline; the twins return the bare value.
  return { out: r.stdout.toString("latin1").replace(/\n$/, ""), rc: r.exitCode ?? -1 };
}

function record(home: string, rel: string, body: string): void {
  mkdirSync(join(home, "data", rel), { recursive: true });
  writeFileSync(join(home, "data", rel, "branches"), body, "latin1");
}

const git = (dir: string, ...args: string[]): void => {
  const r = Bun.spawnSync(["git", "-C", dir, ...args], {
    env: { ...process.env, GIT_AUTHOR_DATE: "2026-01-01T00:00:00Z", GIT_COMMITTER_DATE: "2026-01-01T00:00:00Z" },
    stdout: "ignore",
    stderr: "pipe",
  });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString()}`);
};
function repo(dir: string, branch: string): string {
  git(tmpdir(), "init", "-q", "-b", branch, dir);
  git(dir, "config", "user.email", "test@test");
  git(dir, "config", "user.name", "test");
  writeFileSync(join(dir, "f"), "x\n");
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", "init");
  return dir;
}
function commit(dir: string, msg: string): void {
  writeFileSync(join(dir, "f"), `${msg}\n`, { flag: "a" });
  git(dir, "add", "-A");
  git(dir, "commit", "-qm", msg);
}

test("epicBranchesFile resolves where ac_epic_branches_file resolves: live first, then the archive years in byte order, behind the charset guard", () => {
  const h = freshHome();
  record(h, "live", "proj epic/live\n");
  record(h, "archive/2026/live", "proj epic/old\n");
  record(h, "archive/2026/arch", "proj epic/arch\n");
  record(h, "archive/10/yr", "proj epic/ten\n");
  record(h, "archive/9/yr", "proj epic/nine\n");
  record(h, "archive/2025/two", "proj epic/a\n");
  record(h, "archive/2026/two", "proj epic/b\n");
  record(h, "archive/.hid/hidden", "proj epic/h\n");
  record(h, "archive/2026/bad/name", "proj epic/slash\n");
  mkdirSync(join(h, "x"));
  writeFileSync(join(h, "x", "branches"), "proj epic/up\n");
  for (const epic of ["live", "arch", "yr", "two", "hidden", "bad/name", "../x", "never", "", "café"]) {
    const want = bashLib("ac_epic_branches_file", [epic]);
    expect(epicBranchesFile(epic) ?? "").toBe(want.out);
    expect(want.rc).toBe(epicBranchesFile(epic) === null ? 1 : 0);
  }
  expect(epicBranchesFile("live")).toBe(`${h}/data/live/branches`);
  expect(epicBranchesFile("yr")).toBe(`${h}/data/archive/10/yr/branches`);
  expect(epicBranchesFile("two")).toBe(`${h}/data/archive/2025/two/branches`);
  expect(epicBranchesFile("../x")).toBe(`${h}/data/../x/branches`);
  expect(epicBranchesFile("bad/name")).toBeNull();
  expect(epicBranchesFile("hidden")).toBeNull();
});

test("epicBranchEntry reads what ac_epic_branch_entry reads: first match, fields rejoined by single spaces, awk's numeric ==, the retired marker on the first line only", () => {
  const h = freshHome();
  record(h, "plain", "proj epic/eppy push=yes\nlocalonly epic/eppy\nproj epic/second\n");
  record(h, "blanks", "proj   epic/x\t push=yes  \n\tproj2\tepic/t\tpush=yes\n\nproj3 epic/cr\r\nbare\nbare2   \n");
  record(h, "comment", "# the record\nproj epic/c\n");
  record(h, "nonl", "proj epic/nt");
  record(h, "retired", "# retired 2026-01-01T00:00:00Z\nproj epic/r\n");
  record(h, "later", "# note\n# retired 2026-01-01T00:00:00Z\nproj epic/z\n");
  record(h, "numeric", "07 epic/a\n7 epic/b\n1e2 epic/c\n+7 epic/d\n.5 epic/g\ninf epic/i\n+inf epic/j\nnan epic/k\n7e epic/n\n0x7 epic/f\n");
  record(h, "archive/2026/arch", "proj epic/arch\n");
  const repos = ["proj", "localonly", "proj2", "proj3", "bare", "bare2", "#", "nosuch", "", "7", "07", "100", "1e2", " 7", "7 ", "7.0", "+7", "0.5", ".5", "0x7", "7.5e-1", "nan", "-nan", "inf", "+inf", "-inf", "Infinity", "7e", "1e", "1_0"];
  for (const epic of ["plain", "blanks", "comment", "nonl", "retired", "later", "numeric", "arch", "missing"]) {
    for (const repo of repos) {
      const want = bashLib("ac_epic_branch_entry", [epic, repo]);
      const got = epicBranchEntry(epic, repo);
      expect({ epic, repo, rc: got.rc, entry: got.rc === 0 ? got.entry : "" }).toEqual({ epic, repo, rc: want.rc, entry: want.out });
    }
  }
  expect(epicBranchEntry("plain", "proj")).toEqual({ rc: 0, entry: "epic/eppy push=yes" });
  expect(epicBranchEntry("blanks", "proj")).toEqual({ rc: 0, entry: "epic/x push=yes" });
  expect(epicBranchEntry("blanks", "proj2")).toEqual({ rc: 0, entry: "epic/t push=yes" });
  expect(epicBranchEntry("blanks", "bare")).toEqual({ rc: 1 });
  expect(epicBranchEntry("retired", "proj")).toEqual({ rc: 2 });
  expect(epicBranchEntry("later", "proj")).toEqual({ rc: 0, entry: "epic/z" });
  expect(epicBranchEntry("numeric", "7")).toEqual({ rc: 0, entry: "epic/a" });
  expect(epicBranchEntry("numeric", "1e2")).toEqual({ rc: 0, entry: "epic/c" });
  expect(epicBranchEntry("numeric", "0x7")).toEqual({ rc: 0, entry: "epic/a" });
  expect(epicBranchEntry("numeric", "nan")).toEqual({ rc: 0, entry: "epic/a" });
  expect(epicBranchEntry("numeric", "7.5e-1")).toEqual({ rc: 0, entry: "epic/k" });
  expect(epicBranchEntry("numeric", "+inf")).toEqual({ rc: 0, entry: "epic/j" });
  expect(epicBranchEntry("missing", "proj")).toEqual({ rc: 1 });
});

test("defaultBranch and freshestRef answer every arm ac_default_branch and ac_freshest_ref answer", () => {
  const h = freshHome();
  const up = repo(join(h, "upstream"), "main");
  const clone = join(h, "clone");
  git(h, "clone", "-q", up, clone);
  git(clone, "config", "user.email", "test@test");
  git(clone, "config", "user.name", "test");
  const master = repo(join(h, "master"), "master");
  const trunk = repo(join(h, "trunk"), "trunk");
  const detached = repo(join(h, "detached"), "trunk");
  git(detached, "checkout", "-q", "--detach");
  const upTrunk = repo(join(h, "upstream-trunk"), "trunk");
  const cloneTrunk = join(h, "clone-trunk");
  git(h, "clone", "-q", upTrunk, cloneTrunk);
  git(cloneTrunk, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD");
  git(cloneTrunk, "checkout", "-q", "--detach");
  const check = (dir: string, branch?: string): void => {
    const args = branch === undefined ? [dir] : [dir, branch];
    expect({ dir, def: defaultBranch(dir), fresh: freshestRef(dir, branch) }).toEqual({
      dir,
      def: bashLib("ac_default_branch", [dir]).out,
      fresh: bashLib("ac_freshest_ref", args).out,
    });
  };
  // origin/HEAD, in step with origin
  check(clone);
  expect(freshestRef(clone)).toBe("main");
  // local ahead: cut locally
  commit(clone, "local");
  check(clone);
  expect(freshestRef(clone)).toBe("main");
  // diverged: origin wins
  commit(up, "upstream");
  git(clone, "fetch", "-q", "origin");
  check(clone);
  expect(freshestRef(clone)).toBe("origin/main");
  // a named branch only origin has, and one neither has
  git(up, "branch", "feat");
  git(clone, "fetch", "-q", "origin");
  check(clone, "feat");
  expect(freshestRef(clone, "feat")).toBe("origin/feat");
  check(clone, "nope");
  expect(freshestRef(clone, "nope")).toBe("nope");
  // origin/HEAD gone: main by name
  git(clone, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD");
  check(clone);
  expect(defaultBranch(clone)).toBe("main");
  check(master);
  expect(defaultBranch(master)).toBe("master");
  check(trunk);
  expect(defaultBranch(trunk)).toBe("trunk");
  check(detached);
  expect(defaultBranch(detached)).toBe("main");
  check(cloneTrunk);
  expect(freshestRef(cloneTrunk)).toBe("main");
});

test("pushControlPlane pushes past a refusing pre-push hook as ac_git_push_control_plane does, with git's status", () => {
  const h = freshHome();
  const up = repo(join(h, "upstream"), "main");
  for (const side of ["bash", "ts"]) {
    const clone = join(h, side);
    git(h, "clone", "-q", up, clone);
    writeFileSync(join(clone, ".git", "hooks", "pre-push"), '#!/bin/sh\necho "pre-push: refused" >&2\nexit 1\n', { mode: 0o755 });
    const rc =
      side === "bash"
        ? bashLib("ac_git_push_control_plane", [clone, "--quiet", "origin", `main:refs/heads/${side}`]).rc
        : pushControlPlane(clone, ["--quiet", "origin", `main:refs/heads/${side}`]);
    expect(rc).toBe(0);
    expect(Bun.spawnSync(["git", "-C", up, "rev-parse", "--verify", "-q", `refs/heads/${side}`], { stdout: "ignore" }).exitCode).toBe(0);
    const bad =
      side === "bash"
        ? bashLib("ac_git_push_control_plane", [clone, "--quiet", join(h, "nowhere"), "main:refs/heads/x"]).rc
        : pushControlPlane(clone, ["--quiet", join(h, "nowhere"), "main:refs/heads/x"]);
    expect(bad).toBe(128);
  }
});
