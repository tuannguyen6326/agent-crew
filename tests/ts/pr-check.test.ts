// pr-check.test.ts - the lib.ts twins src/pr-check.ts introduced, held to their
// bash originals in bin/ac-lib.sh differentially: require against ac_require,
// taskMeta / taskStatus against ac_task_meta / ac_task_status (the homeless
// double-ERROR included), metaSet against ac_meta_set on the BYTES of the
// rewritten meta (repeated keys, `=` in values, CRLF, a missing key, an absent
// file, an unterminated tail, a bare key line, a two-line value, a NUL - the
// one divergence the port keeps on purpose, both sides' bytes asserted),
// statusAppend against ac_status_append on the status line and its timeline
// mirror under one PATH `date` stub, metaIsVerify against ac_meta_is_verify,
// and stageDirForId / taskDir against ac_stage_dir_for_id / ac_task_dir over
// every shape of the bin/ac-brief.sh layout. The CLI contract itself is
// tests/sh/ac-pr-check.test.sh's, whose differential leg runs the frozen bash
// original beside the shim.
import { afterEach, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { metaIsVerify, metaSet, stageDirForId, statusAppend, taskDir, taskMeta, taskStatus } from "../../src/lib.ts";

const root = join(import.meta.dir, "..", "..");
const binDir = join(root, "bin");
const savedEnv = { ...process.env };
const dirs: string[] = [];
afterEach(() => {
  for (const k of Object.keys(process.env)) if (!(k in savedEnv)) delete process.env[k];
  Object.assign(process.env, savedEnv);
  for (const d of dirs.splice(0)) {
    // A 000 file is removable (its directory is ours); restore the mode anyway
    // so a failed run leaves nothing a human cannot read.
    for (const f of readdirSync(d, { recursive: true }) as string[]) {
      try {
        if (lstatSync(join(d, f)).isFile()) chmodSync(join(d, f), 0o644);
      } catch {}
    }
    rmSync(d, { recursive: true, force: true });
  }
});
const tmp = (tag: string): string => {
  const d = realpathSync(mkdtempSync(join(tmpdir(), `ac-pr-check-${tag}-`)));
  dirs.push(d);
  return d;
};
const isRoot = process.getuid?.() === 0;

// The bash side sources ac-lib.sh under LC_ALL=C (the leg's locale).
function bash(body: string, env: Record<string, string | undefined> = {}, ...args: string[]) {
  const e: Record<string, string> = { ...(process.env as Record<string, string>), LC_ALL: "C" };
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete e[k];
  else e[k] = v;
  const r = Bun.spawnSync(["bash", "-c", `. "$0/ac-lib.sh"; ${body}`, binDir, ...args], { stdout: "pipe", stderr: "pipe", env: e });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

// A twin that prints or exits runs in a fresh bun, as each `bash -c` does.
function ts(script: string, env: Record<string, string | undefined> = {}) {
  const e: Record<string, string> = { ...(process.env as Record<string, string>) };
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete e[k];
  else e[k] = v;
  const r = Bun.spawnSync([process.execPath, "--no-env-file", "-e", `import * as L from "./src/lib.ts"; ${script}`], { cwd: root, stdout: "pipe", stderr: "pipe", env: e });
  return { out: r.stdout.toString("latin1"), err: r.stderr.toString("latin1"), rc: r.exitCode ?? -1 };
}

// `date -u +%Y-%m-%dT%H:%M:%SZ` answers one instant to both sides.
function stubDate(): void {
  const d = tmp("date");
  writeFileSync(join(d, "date"), '#!/bin/sh\ncase "$*" in "-u +%Y-%m-%dT%H:%M:%SZ") echo 2026-01-01T00:00:00Z ;; *) exec /bin/date "$@" ;; esac\n', { mode: 0o755 });
  process.env.PATH = `${d}:${process.env.PATH}`;
}

// Every entry under a dir, byte order: `<name>/` for a directory, else the name,
// mode and bytes.
function snapshot(dir: string): string[] {
  const names = (readdirSync(dir, { recursive: true }) as string[]).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  return names.map((n) => {
    const p = join(dir, n);
    const st = lstatSync(p);
    if (st.isDirectory()) return `${n}/`;
    if (st.isSymbolicLink()) return `${n} -> link`;
    return `${n} ${(st.mode & 0o777).toString(8)} ${readFileSync(p, "latin1")}`;
  });
}

function seedHome(home: string, files: Record<string, string>): void {
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(join(home, "data"), { recursive: true });
  for (const [rel, body] of Object.entries(files)) {
    const p = join(home, rel);
    if (rel.endsWith("/")) mkdirSync(p, { recursive: true });
    else {
      mkdirSync(join(p, ".."), { recursive: true });
      writeFileSync(p, Buffer.from(body, "latin1"));
    }
  }
}

test("require refuses the first missing tool with ac_require's line, and is quiet when all are there", () => {
  const want = bash('ac_require ls nosuchtool-ac zz');
  expect([want.rc, want.err, want.out]).toEqual([1, "ERROR: required tool not found: nosuchtool-ac\n", ""]);
  expect(ts('L.require("ls", "nosuchtool-ac", "zz")')).toEqual({ rc: 1, err: "ERROR: required tool not found: nosuchtool-ac\n", out: "" });
  expect(bash("ac_require ls sh").rc).toBe(0);
  expect(ts('L.require("ls", "sh")')).toEqual({ rc: 0, err: "", out: "" });
});

test("taskMeta and taskStatus name the state files ac_task_meta and ac_task_status name, state/ minted, the id unvalidated", () => {
  for (const id of ["t1", "../t1", "a b", "fam-spec-r2"]) {
    const oh = tmp("oh"), nh = tmp("nh");
    const o = bash('ac_task_meta "$1"; ac_task_status "$1"', { AC_HOME: oh }, id);
    // -e has no argv slot: the id travels through the env.
    const n2 = ts(`process.stdout.write(L.taskMeta(process.env.ID) + "\\n" + L.taskStatus(process.env.ID) + "\\n")`, { AC_HOME: nh, ID: id });
    expect([id, o.rc, o.err]).toEqual([id, 0, ""]);
    expect([id, n2.rc, n2.err]).toEqual([id, 0, ""]);
    expect([id, n2.out.replaceAll(nh, "HOME")]).toEqual([id, o.out.replaceAll(oh, "HOME")]);
    expect(o.out).toBe(`${oh}/state/${id}.meta\n${oh}/state/${id}.status\n`);
    expect(statSync(join(oh, "state")).isDirectory()).toBe(true);
    expect(statSync(join(nh, "state")).isDirectory()).toBe(true);
  }
  // Homeless: the refusal is printed from inside the capture and the printf goes
  // on with "", so the path is `/<id>.meta` on both sides (the W1 wart kept).
  const o = bash("ac_task_meta t1", { AC_HOME: undefined });
  expect(o).toEqual({ rc: 0, out: "/t1.meta\n", err: "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n" });
  expect(ts('process.stdout.write(L.taskMeta("t1") + "\\n")', { AC_HOME: undefined })).toEqual(o);
  // Named divergence: an AC_HOME cd cannot enter is the shell's own `cd:` line
  // in the bash; the port names the variable. The path is the same `/<id>.meta`.
  const missing = join(tmp("gone"), "missing");
  const ob = bash("ac_task_meta t1", { AC_HOME: missing });
  expect([ob.rc, ob.out]).toEqual([0, "/t1.meta\n"]);
  expect(ob.err).toContain(`cd: ${missing}: No such file or directory`);
  expect(ts('process.stdout.write(L.taskMeta("t1") + "\\n")', { AC_HOME: missing })).toEqual({ rc: 0, out: "/t1.meta\n", err: `ERROR: AC_HOME is not a readable directory: ${missing}\n` });
});

const U = "https://github.com/acme/widget/pull/7";

// Both sides rewrite their own copy of one seeded meta; the directory left
// behind (the meta's bytes and mode, no temp sibling) is compared whole.
test("metaSet rewrites the bytes ac_meta_set writes", () => {
  const cases: { name: string; seed: string | null; key: string; value: string }[] = [
    { name: "repeated keys, one appended at the end", seed: "pr=a\nbackend=tmux\npr=b\nprx=keep\npr_head=h\n", key: "pr", value: U },
    { name: "= in the value", seed: "k=v\n", key: "pr", value: "a=b=c" },
    { name: "CRLF lines keep their CR", seed: "pr=a\r\nk=v\r\n", key: "pr", value: U },
    { name: "a missing key", seed: "backend=tmux\nkind=ship\n", key: "pr", value: U },
    { name: "an absent file", seed: null, key: "pr", value: U },
    { name: "an unterminated tail is newline-terminated", seed: "pr=old\nzz=1", key: "pr", value: U },
    { name: "an empty file", seed: "", key: "pr", value: U },
    { name: "a file of one empty line", seed: "\n", key: "pr", value: U },
    { name: "a bare key line is kept", seed: "pr\npr=x\n", key: "pr", value: U },
    { name: "a two-line value", seed: "backend=tmux\n", key: "pr_head", value: "aaa\nbbb" },
    { name: "an empty value", seed: "pr_head=old\n", key: "pr_head", value: "" },
    { name: "a kept line's byte that is not UTF-8 passes through", seed: "note=d\xe9\npr=old\n", key: "pr", value: U },
    { name: "printf-special bytes", seed: "k=v\n", key: "pr", value: "%s\\n%%" },
    { name: "a key with - and digits", seed: "x-1=a\nx-10=b\n", key: "x-1", value: "c" },
  ];
  for (const c of cases) {
    const od = tmp("o"), nd = tmp("n");
    for (const d of [od, nd]) if (c.seed !== null) writeFileSync(join(d, "t1.meta"), Buffer.from(c.seed, "latin1"));
    const o = bash('ac_meta_set "$1" "$2" "$3"', {}, join(od, "t1.meta"), c.key, c.value);
    expect([c.name, o.rc, o.err]).toEqual([c.name, 0, ""]);
    metaSet(join(nd, "t1.meta"), c.key, c.value);
    expect([c.name, snapshot(nd)]).toEqual([c.name, snapshot(od)]);
  }
  // The shape itself, once, so the comparison above is known to be of the
  // right bytes: every `pr=` gone, the rest in order, the new line last.
  const d = tmp("shape");
  writeFileSync(join(d, "t1.meta"), "pr=a\nbackend=tmux\npr=b\nprx=keep\npr_head=h");
  metaSet(join(d, "t1.meta"), "pr", U);
  expect(readFileSync(join(d, "t1.meta"), "latin1")).toBe(`backend=tmux\nprx=keep\npr_head=h\npr=${U}\n`);
  expect(readdirSync(d)).toEqual(["t1.meta"]);
});

// Named divergence W3: BSD grep -v on a meta holding a NUL prints `Binary file
// <path> matches` in place of the lines, so the bash's rewrite destroyed every
// other key (exit 0); the port keeps the bytes. Both results are pinned.
test("metaSet keeps a NUL-holding meta where ac_meta_set destroyed it", () => {
  const od = tmp("o"), nd = tmp("n");
  const seed = Buffer.from("note=a\0b\nbackend=tmux\npr=old\n", "latin1");
  writeFileSync(join(od, "t1.meta"), seed);
  writeFileSync(join(nd, "t1.meta"), seed);
  const o = bash('ac_meta_set "$1" pr "$2"', {}, join(od, "t1.meta"), U);
  expect([o.rc, o.err]).toEqual([0, ""]);
  expect(readFileSync(join(od, "t1.meta"), "latin1")).toBe(`Binary file ${od}/t1.meta matches\npr=${U}\n`);
  metaSet(join(nd, "t1.meta"), "pr", U);
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe(`note=a\0b\nbackend=tmux\npr=${U}\n`);
});

// Named divergence W4: a meta `[ -f ]` accepts but grep cannot read came back
// as the new line alone (grep's own noise on stderr, exit 0); the port throws
// and leaves the file as it was.
test.skipIf(isRoot)("metaSet refuses an unreadable meta where ac_meta_set truncated it", () => {
  const od = tmp("o"), nd = tmp("n");
  for (const d of [od, nd]) {
    writeFileSync(join(d, "t1.meta"), "backend=tmux\n");
    chmodSync(join(d, "t1.meta"), 0o000);
  }
  const o = bash('ac_meta_set "$1" pr "$2"', {}, join(od, "t1.meta"), U);
  expect([o.rc, o.err]).toEqual([0, `grep: ${od}/t1.meta: Permission denied\n`]);
  expect(readFileSync(join(od, "t1.meta"), "latin1")).toBe(`pr=${U}\n`);
  expect(() => metaSet(join(nd, "t1.meta"), "pr", U)).toThrow(/EACCES/);
  expect(statSync(join(nd, "t1.meta")).mode & 0o777).toBe(0);
  chmodSync(join(nd, "t1.meta"), 0o644);
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe("backend=tmux\n");
  expect(readdirSync(nd)).toEqual(["t1.meta"]);
});

// Named divergence: the bash's fresh temp left every meta umask-0644; the port
// keeps the file's mode (the EXCLUSIVE TEMP rule).
test("metaSet keeps the meta's mode where ac_meta_set reset it to 0644", () => {
  const od = tmp("o"), nd = tmp("n");
  for (const d of [od, nd]) writeFileSync(join(d, "t1.meta"), "k=v\n", { mode: 0o600 });
  expect(bash('ac_meta_set "$1" pr "$2"', {}, join(od, "t1.meta"), U).rc).toBe(0);
  expect(statSync(join(od, "t1.meta")).mode & 0o777).toBe(0o644);
  metaSet(join(nd, "t1.meta"), "pr", U);
  expect(statSync(join(nd, "t1.meta")).mode & 0o777).toBe(0o600);
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe(readFileSync(join(od, "t1.meta"), "latin1"));
});

// A symlinked meta: mv and rename alike replace the LINK with the rewritten
// regular file and leave its target as it was.
test("metaSet replaces a symlinked meta with a regular file like mv does", () => {
  const od = tmp("o"), nd = tmp("n");
  for (const d of [od, nd]) {
    writeFileSync(join(d, "real.meta"), "k=v\npr=old\n");
    symlinkSync("real.meta", join(d, "t1.meta"));
  }
  expect(bash('ac_meta_set "$1" pr "$2"', {}, join(od, "t1.meta"), U).rc).toBe(0);
  metaSet(join(nd, "t1.meta"), "pr", U);
  expect(snapshot(nd)).toEqual(snapshot(od));
  expect(lstatSync(join(nd, "t1.meta")).isSymbolicLink()).toBe(false);
  expect(readFileSync(join(nd, "real.meta"), "latin1")).toBe("k=v\npr=old\n");
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe(`k=v\npr=${U}\n`);
});

// Named divergence: a sibling planted at the temp's name. The bash wrote THROUGH
// a symlink there (the victim took the rewrite, and the link itself was then
// renamed over the meta); the port's exclusive create refuses it and takes the
// next name, so the victim and the planted link are untouched.
test("metaSet never writes through a planted temp sibling", () => {
  const od = tmp("o"), nd = tmp("n");
  for (const d of [od, nd]) {
    writeFileSync(join(d, "t1.meta"), "k=v\n");
    writeFileSync(join(d, "victim"), "precious\n");
  }
  const o = bash('ln -s "$1/victim" "$1/t1.meta.tmp.$$"; ac_meta_set "$1/t1.meta" pr "$2"', {}, od, U);
  expect(o.rc).toBe(0);
  expect(readFileSync(join(od, "victim"), "latin1")).toBe(`k=v\npr=${U}\n`);
  expect(lstatSync(join(od, "t1.meta")).isSymbolicLink()).toBe(true);
  symlinkSync(join(nd, "victim"), join(nd, `t1.meta.tmp.${process.pid}`));
  metaSet(join(nd, "t1.meta"), "pr", U);
  expect(readFileSync(join(nd, "victim"), "latin1")).toBe("precious\n");
  expect(lstatSync(join(nd, "t1.meta")).isFile()).toBe(true);
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe(`k=v\npr=${U}\n`);
  expect(readdirSync(nd).sort()).toEqual(["t1.meta", `t1.meta.tmp.${process.pid}`, "victim"]);
});

// Named divergence: the bash used the key as a BRE (`a.b` also drops `aXb=`);
// the port matches it literally. Every live caller's key is an identifier, so
// no reachable call differs; the theoretical one is pinned.
test("metaSet matches the key literally where ac_meta_set read it as a BRE", () => {
  const od = tmp("o"), nd = tmp("n");
  for (const d of [od, nd]) writeFileSync(join(d, "t1.meta"), "aXb=1\na.b=2\n");
  expect(bash('ac_meta_set "$1" a.b 3', {}, join(od, "t1.meta")).rc).toBe(0);
  expect(readFileSync(join(od, "t1.meta"), "latin1")).toBe("a.b=3\n");
  metaSet(join(nd, "t1.meta"), "a.b", "3");
  expect(readFileSync(join(nd, "t1.meta"), "latin1")).toBe("aXb=1\na.b=3\n");
});

test("metaIsVerify answers as ac_meta_is_verify, silent on an unreadable meta", () => {
  const d = tmp("v");
  const metas: Record<string, string | null> = {
    "verify.meta": "kind=verify-codereview\n",
    "verify-cr.meta": "kind=ship\nkind=verify-qa\r\n",
    "ship.meta": "kind=ship\n",
    "kindless.meta": "backend=tmux\n",
    "empty-kind.meta": "kind=verify-x\nkind=\n",
    "absent.meta": null,
  };
  for (const [name, body] of Object.entries(metas)) if (body !== null) writeFileSync(join(d, name), body);
  if (!isRoot) {
    writeFileSync(join(d, "unreadable.meta"), "kind=verify-codereview\n");
    chmodSync(join(d, "unreadable.meta"), 0o000);
    metas["unreadable.meta"] = "";
  }
  for (const name of Object.keys(metas)) {
    const o = bash('ac_meta_is_verify "$1"', {}, join(d, name));
    expect([name, o.err, o.out]).toEqual([name, "", ""]);
    expect([name, metaIsVerify(join(d, name))]).toEqual([name, o.rc === 0]);
  }
  expect(metaIsVerify(join(d, "verify.meta"))).toBe(true);
  expect(metaIsVerify(join(d, "ship.meta"))).toBe(false);
});

const STAGE_IDS = [
  "fam-spec", "fam-spec-r2", "fam-r3", "fam-r12", "fam-r123", "fam-chief", "t9", "fam-arch", "fam-plan", "fam-review", "fam-ship", "fam-design", "fam-qa",
  "-spec", "-r2", "x-r", "a-spec-r2-r3", "a/b-spec", "fam-slug", "fam-spec-arch", "fam-rx", "fam-r0", "spec", "r2", "a-chief-r1",
];

test("stageDirForId maps every suffix as ac_stage_dir_for_id does, with no disk check", () => {
  for (const id of STAGE_IDS) {
    const o = bash('ac_stage_dir_for_id "$1"', {}, id);
    expect([id, o.rc, o.err]).toEqual([id, 0, ""]);
    const got = stageDirForId(id);
    expect([id, got === "" ? "" : `${got}\n`]).toEqual([id, o.out]);
  }
  expect(stageDirForId("fam-spec-r2")).toBe("fam/spec-r2");
  expect(stageDirForId("fam-r3")).toBe("fam/implement-r3");
  expect(stageDirForId("t9")).toBe("");
});

// One home holding every layout shape of bin/ac-brief.sh: nested stage dirs,
// revisions, a brief-less chief under an existing family, data/<id>/implement,
// fan-out tasks/<slug> (longest prefix first), the flat dir, and the three
// ambiguities that die.
test("taskDir resolves every brief layout as ac_task_dir does, and throws its die text", () => {
  const home = tmp("home");
  seedHome(home, {
    "data/fam/spec/brief.md": "b",
    "data/fam/spec-r2/brief.md": "b",
    "data/fam/implement-r3/brief.md": "b",
    "data/fam2/": "",
    "data/t9/implement/brief.md": "b",
    "data/fam/tasks/slug/brief.md": "b",
    "data/wire/tasks/e34-fix/brief.md": "b",
    "data/wire-e34/tasks/fix/brief.md": "b",
    "data/t1/brief.md": "b",
    "data/amb/spec/brief.md": "b",
    "data/amb-spec/brief.md": "b",
    "data/amb2/implement/brief.md": "b",
    "data/amb2/brief.md": "b",
    "data/fam/tasks/dup/brief.md": "b",
    "data/fam-dup/brief.md": "b",
    "data/lonely-chief/": "",
  });
  process.env.AC_HOME = home;
  const ids = [
    "fam-spec", "fam-spec-r2", "fam-r3", "fam-r4", "fam-chief", "fam2-chief", "lonely-chief", "t9", "fam-slug", "wire-e34-fix", "wire-zz", "t1", "nothing",
    "amb-spec", "amb2", "fam-dup", "fam-spec-arch", "../t1", "a b-spec", "-spec", "fam-tasks-slug",
  ];
  for (const id of ids) {
    const o = bash('ac_task_dir "$1"', { AC_HOME: home }, id);
    let got: { out: string; err: string; rc: number };
    try {
      got = { out: `${taskDir(id)}\n`, err: "", rc: 0 };
    } catch (e) {
      got = { out: "", err: `ERROR: ${(e as Error).message}\n`, rc: 1 };
    }
    expect([id, got]).toEqual([id, o]);
  }
  expect(taskDir("fam-spec")).toBe(`${home}/data/fam/spec`);
  expect(taskDir("fam2-chief")).toBe(`${home}/data/fam2/chief`);
  expect(taskDir("lonely-chief")).toBe(`${home}/data/lonely-chief`);
  expect(taskDir("wire-e34-fix")).toBe(`${home}/data/wire-e34/tasks/fix`);
  expect(() => taskDir("amb-spec")).toThrow(`ambiguous task data for amb-spec: briefs at both ${home}/data/amb/spec and ${home}/data/amb-spec`);
  expect(() => taskDir("fam-dup")).toThrow(`ambiguous task data for fam-dup: briefs at both ${home}/data/fam/tasks/dup and ${home}/data/fam-dup`);
});

// Two homes seeded alike; the status line and the timeline mirror (created
// only for a real task, skipped for a verify-* meta, an ambiguous brief, or no
// task dir and no meta) are compared as the whole home tree left behind.
test("statusAppend writes the status line and timeline mirror ac_status_append writes", () => {
  stubDate();
  const shapes: { name: string; files: Record<string, string>; id: string; lines: string[] }[] = [
    { name: "flat task", files: { "state/t1.meta": "backend=tmux\nkind=ship\n" }, id: "t1", lines: ["PR ready: U (OPEN)"] },
    { name: "two appends", files: { "state/t1.meta": "backend=tmux\n" }, id: "t1", lines: ["working: a", "PR ready: U (OPEN)"] },
    { name: "a verify meta: no mirror", files: { "state/vf.meta": "kind=verify-codereview\n" }, id: "vf", lines: ["started review"] },
    { name: "no meta, no dir: no mirror", files: {}, id: "ghost", lines: ["poof"] },
    { name: "no meta, dir exists: mirrored", files: { "data/t2/": "" }, id: "t2", lines: ["poof"] },
    { name: "nested stage", files: { "state/fam-spec.meta": "kind=spec\n", "data/fam/spec/brief.md": "b" }, id: "fam-spec", lines: ["done: spec"] },
    { name: "brief-less chief", files: { "state/fam-chief.meta": "kind=chief\n", "data/fam/room.md": "r" }, id: "fam-chief", lines: ["working: promoted"] },
    { name: "fan-out slug", files: { "state/fam-slug.meta": "kind=ship\n", "data/fam/tasks/slug/brief.md": "b" }, id: "fam-slug", lines: ["x"] },
    { name: "ambiguous briefs: no mirror", files: { "state/amb-spec.meta": "kind=spec\n", "data/amb/spec/brief.md": "b", "data/amb-spec/brief.md": "b" }, id: "amb-spec", lines: ["x"] },
    // The bash line is a printf format so a byte that is not UTF-8 can reach it
    // (argv cannot carry one into either side).
    { name: "a line with a tab and a byte that is not UTF-8", files: { "state/t1.meta": "k=v\n" }, id: "t1", lines: ["a\\tb caf\\351 %%s"] },
    { name: "a traversing id", files: { "t1.meta": "k=v\n" }, id: "../t1", lines: ["x"] },
  ];
  for (const s of shapes) {
    const oh = tmp("oh"), nh = tmp("nh");
    seedHome(oh, s.files);
    seedHome(nh, s.files);
    for (const fmt of s.lines) {
      const o = bash('printf -v l -- "$2"; ac_status_append "$1" "$l"', { AC_HOME: oh }, s.id, fmt);
      expect([s.name, o]).toEqual([s.name, { rc: 0, out: "", err: "" }]);
      const line = fmt.replace("\\t", "\t").replace("\\351", "\xe9").replace("%%", "%");
      process.env.AC_HOME = nh;
      expect([s.name, statusAppend(s.id, line)]).toEqual([s.name, true]);
    }
    expect([s.name, snapshot(nh)]).toEqual([s.name, snapshot(oh)]);
  }
  // The bytes themselves, once.
  const h = tmp("bytes");
  seedHome(h, { "state/t1.meta": "k=v\n" });
  process.env.AC_HOME = h;
  expect(statusAppend("t1", "PR ready: U (OPEN)")).toBe(true);
  expect(readFileSync(join(h, "state/t1.status"), "latin1")).toBe("2026-01-01T00:00:00Z PR ready: U (OPEN)\n");
  expect(readFileSync(join(h, "data/t1/timeline.log"), "latin1")).toBe("2026-01-01T00:00:00Z PR ready: U (OPEN)\n");
  expect(existsSync(join(h, "data/t1/brief.md"))).toBe(false);
});

// The primary write's own failure is the return (`|| ...` callers are told);
// a homeless append fails at `/<id>.status`. The shell's own line for that
// failed redirection is not reproduced; the refusal before it is.
test("statusAppend returns false when the status file cannot be appended", () => {
  stubDate();
  delete process.env.AC_HOME;
  const o = bash('ac_status_append t1 x', { AC_HOME: undefined });
  expect([o.rc, o.out]).toEqual([1, ""]);
  expect(o.err).toContain("ERROR: AC_HOME is not set");
  const r = ts('process.stdout.write(String(L.statusAppend("t1", "x")))');
  expect(r.rc).toBe(0);
  expect(r.out).toBe("false");
  expect(r.err).toBe("ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n");
});
