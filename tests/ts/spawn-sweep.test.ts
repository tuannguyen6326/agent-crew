// spawn-sweep.test.ts - the spawn rules every src/ module keeps through
// src/lib.ts's spawnShellSync / spawnShell and bunChild: no env option (Bun
// re-encodes one as UTF-8, the environment this process started with keeps its
// bytes), a live process.env change reaches the child through env(1), and an
// executable the kernel refuses (no shebang, ENOEXEC) runs under /bin/bash as
// bash ran it. Each case runs in a bun child whose environment /bin/sh built,
// so X holds the raw byte 0xE9.
import { afterAll, expect, test } from "bun:test";
import { chmodSync, copyFileSync, linkSync, symlinkSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const LIB = join(ROOT, "src", "lib.ts");
const W = realpathSync(mkdtempSync(join(tmpdir(), "ac-spawn-sweep-")));
afterAll(() => rmSync(W, { recursive: true, force: true }));

const BIN = join(W, "bin");
mkdirSync(BIN);
writeFileSync(join(BIN, "noshe"), 'echo "$0|$*|$BASH"; exit 3\n');
chmodSync(join(BIN, "noshe"), 0o755);
const RAN = `3 ${BIN}/noshe|a 1 b2|/bin/bash`;

// env(1) reads an operand holding `=` as an assignment, wherever it stands.
const EQ = join(W, "a=b");
mkdirSync(EQ);
writeFileSync(join(EQ, "tool"), '#!/bin/sh\necho "ran $0 $*"\n');
chmodSync(join(EQ, "tool"), 0o755);
copyFileSync(join(BIN, "noshe"), join(EQ, "noshe"));
chmodSync(join(EQ, "noshe"), 0o755);
writeFileSync(join(W, "noexec"), "#!/bin/sh\necho ran\n");

// Off the child's starting PATH, so reaching them takes a process.env change.
const BAD = join(W, "bad");
mkdirSync(BAD);
// A UTF-8 interpreter path: the preflight must read it as the filesystem does.
const CAFE = join(W, "caf\u00e9");
mkdirSync(CAFE);
symlinkSync("/bin/sh", join(CAFE, "sh"));
for (const [name, body] of [
  ["date", "#!/nonexistent/interp\necho ran\n"],
  ["crdate", "#!/bin/sh\r\necho ran\n"],
  ["unidate", `#!${CAFE}/sh\necho 123\n`],
  ["envmissing", "#!/usr/bin/env no-such-interp-sweep\necho ran\n"],
  ["exit127", "#!/bin/sh\nexit 127\n"],
]) {
  writeFileSync(join(BAD, name!), body!);
  chmodSync(join(BAD, name!), 0o755);
}

const OD = 'printf %s "$X" | od -An -tx1';
const E9 = "61 e9 62";
// od pads its columns, and BSD od ends -An output with its empty final-address
// line, so lines are compared blank-squeezed with the empty ones dropped.
const squeeze = (s: string): string[] => s.split("\n").map((l) => l.trim().replace(/[ \t]+/g, " ")).filter((l) => l !== "");

let n = 0;
function child(body: string, bun = process.execPath): string[] {
  const script = join(W, `c${n++}.ts`);
  writeFileSync(script, `import * as L from ${JSON.stringify(LIB)};\nconst say = (s: string): void => void process.stdout.write(s + "\\n");\n${body}\n`);
  const r = Bun.spawnSync(
    ["/bin/sh", "-c", `X="$(printf 'a\\351b')" BUN_SWEEP_PIN=1 PATH="$1:$PATH" exec "$2" --no-env-file "$3"`, "sh", BIN, bun, script],
    { cwd: W, stdout: "pipe", stderr: "pipe" },
  );
  expect(r.stderr.toString()).toBe("");
  return squeeze(r.stdout.toString());
}

test("spawnShellSync runs a shebang-less executable under /bin/bash, by PATH name and by path", () => {
  const out = child(`
for (const a0 of ["noshe", ${JSON.stringify(join(BIN, "noshe"))}]) {
  const r = L.spawnShellSync([a0, "a 1", "b2"], { stdout: "pipe" });
  say(\`\${r.exitCode} \${r.stdout.toString().trim()}\`);
}`);
  expect(out).toEqual([RAN, RAN]);
}, 20000);

test("spawnShell runs a shebang-less executable under /bin/bash", () => {
  const out = child(`
const p = L.spawnShell(["noshe", "a 1", "b2"], { stdout: "pipe" });
const text = await new Response(p.stdout).text();
say(\`\${await p.exited} \${text.trim()}\`);`);
  expect(out).toEqual([RAN]);
}, 20000);

test("with a name changed, a shebang-less executable still runs under /bin/bash", () => {
  const out = child(`
process.env.SWEEP_SET = "on";
for (const a0 of ["noshe", ${JSON.stringify(join(BIN, "noshe"))}]) {
  const r = L.spawnShellSync([a0, "a 1", "b2"], { stdout: "pipe" });
  say(\`\${r.exitCode} \${r.stdout.toString().trim()}\`);
  const p = L.spawnShell([a0, "a 1", "b2"], { stdout: "pipe" });
  const text = await new Response(p.stdout).text();
  say(\`\${await p.exited} \${text.trim()}\`);
}`);
  expect(out).toEqual([RAN, RAN, RAN, RAN]);
}, 20000);

test("with a name changed, a command whose path holds = is still the command", () => {
  const out = child(`
process.env.SWEEP_SET = "on";
for (const a0 of [${JSON.stringify(join(EQ, "tool"))}, ${JSON.stringify(join(EQ, "noshe"))}]) {
  const r = L.spawnShellSync([a0, "a 1"], { stdout: "pipe" });
  say(\`\${r.exitCode} \${r.stdout.toString().trim()}\`);
  const p = L.spawnShell([a0, "a 1"], { stdout: "pipe" });
  const text = await new Response(p.stdout).text();
  say(\`\${await p.exited} \${text.trim()}\`);
}`);
  const tool = `0 ran ${EQ}/tool a 1`;
  const noshe = `3 ${EQ}/noshe|a 1|/bin/bash`;
  expect(out).toEqual([tool, tool, noshe, noshe]);
}, 20000);

// The shell's 126, which a caller reads off EACCES, never hangs on whether an
// unrelated name changed.
test("an existing command that cannot be executed throws EACCES, with or without a name changed", () => {
  const out = child(`
const code = (f: () => unknown): string => { try { f(); return "ran"; } catch (e) { return (e as { code?: string }).code ?? "?"; } };
for (const set of [false, true]) {
  if (set) process.env.SWEEP_SET = "on";
  for (const [a0, cwd] of [[${JSON.stringify(join(W, "noexec"))}, undefined], ["../noexec", ${JSON.stringify(BIN)}], [${JSON.stringify(BIN)}, undefined]] as const) {
    say(code(() => L.spawnShellSync([a0], { cwd, stdout: "pipe" })));
    say(code(() => L.spawnShell([a0], { cwd, stdout: "pipe" })));
  }
}`);
  expect(out).toEqual(Array(12).fill("EACCES"));
}, 20000);

test("a byte-valued variable reaches the child unchanged through both helpers", () => {
  const out = child(`
say(L.spawnShellSync(["/bin/sh", "-c", ${JSON.stringify(OD)}], { stdout: "pipe" }).stdout.toString());
const p = L.spawnShell(["/bin/sh", "-c", ${JSON.stringify(OD)}], { stdout: "pipe" });
say(await new Response(p.stdout).text());`);
  expect(out).toEqual([E9, E9]);
}, 20000);

test("a name set or deleted in process.env reaches the child, the untouched byte stays", () => {
  const out = child(`
process.env.SWEEP_SET = "on";
delete process.env.BUN_SWEEP_PIN;
const sh = ["/bin/sh", "-c", 'echo "$SWEEP_SET \${BUN_SWEEP_PIN-unset}"; ' + ${JSON.stringify(OD)}];
say(L.spawnShellSync(sh, { stdout: "pipe" }).stdout.toString());
const p = L.spawnShell(sh, { stdout: "pipe" });
say(await new Response(p.stdout).text());`);
  expect(out).toEqual(["on unset", E9, "on unset", E9]);
}, 20000);

test("with a name changed, a command whose #! interpreter is missing still throws ENOENT", () => {
  const out = child(`
process.env.PATH = ${JSON.stringify(BAD)} + ":" + process.env.PATH;
const code = (f: () => unknown): string => { try { f(); return "ran"; } catch (e) { return (e as { code?: string }).code ?? "?"; } };
say(code(() => L.spawnShellSync(["date"], { stdout: "pipe" })));
say(code(() => L.spawnShell(["date"], { stdout: "pipe" })));
say(String(L.now()));`);
  expect(out).toEqual(["ENOENT", "ENOENT", "NaN"]);
}, 20000);

// The kernel reads `/bin/sh<CR>` as the path: no such interpreter, ENOENT.
test("with a name changed, a CRLF shebang still throws ENOENT", () => {
  const out = child(`
process.env.PATH = ${JSON.stringify(BAD)} + ":" + process.env.PATH;
const code = (f: () => unknown): string => { try { f(); return "ran"; } catch (e) { return (e as { code?: string }).code ?? "?"; } };
say(code(() => L.spawnShellSync(["crdate"], { stdout: "pipe" })));
say(code(() => L.spawnShell(["crdate"], { stdout: "pipe" })));`);
  expect(out).toEqual(["ENOENT", "ENOENT"]);
}, 20000);

test("with a name changed, a valid UTF-8 #! interpreter path still runs", () => {
  const out = child(`
process.env.PATH = ${JSON.stringify(BAD)} + ":" + process.env.PATH;
say(L.spawnShellSync(["unidate"], { stdout: "pipe" }).stdout.toString().trim());
const p = L.spawnShell(["unidate"], { stdout: "pipe" }); await p.exited;
say((await new Response(p.stdout as ReadableStream).text()).trim());`);
  expect(out).toEqual(["123", "123"]);
}, 20000);

// env(1) as the #! interpreter starts, so Bun reports its 127 and never throws.
test("with a name changed, a child's own 127 is a status, never a throw", () => {
  const out = child(`
process.env.PATH = ${JSON.stringify(BAD)} + ":" + process.env.PATH;
for (const c of [["exit127"], ["envmissing"], ["/bin/sh", "-c", "exit 127"]]) {
  say(String(L.spawnShellSync(c, { stdout: "pipe", stderr: "ignore" }).exitCode));
  say(String(await L.spawnShell(c, { stdout: "pipe", stderr: "ignore" }).exited));
}`);
  expect(out).toEqual(["127", "127", "127", "127", "127", "127"]);
}, 20000);

test("bunChild's command drops a BUN_ name and keeps the bytes, with no env object", () => {
  const fixture = join(W, "fixture.ts");
  writeFileSync(fixture, `Bun.spawnSync(["/bin/sh", "-c", 'echo "\${BUN_SWEEP_PIN-unset}"; ' + ${JSON.stringify(OD)}], { stdout: "inherit" });\n`);
  const out = child(`
const c = L.bunChild(${JSON.stringify(relative(ROOT, fixture))}, []);
say(Object.keys(c).join(","));
say(Bun.spawnSync(c.cmd, { cwd: c.cwd, stdout: "pipe" }).stdout.toString());`);
  expect(out).toEqual(["cmd,cwd", "unset", E9]);
}, 20000);

test("bunChild's command runs a bun whose path holds =", () => {
  const bun = join(EQ, "bun");
  try {
    linkSync(process.execPath, bun);
  } catch {
    copyFileSync(process.execPath, bun);
    chmodSync(bun, 0o755);
  }
  const fixture = join(W, "fixture-eq.ts");
  writeFileSync(fixture, `console.log(process.argv.slice(2).join("|"));\n`);
  const out = child(`
const c = L.bunChild(${JSON.stringify(relative(ROOT, fixture))}, ["a 1"]);
const r = Bun.spawnSync(c.cmd, { cwd: c.cwd, stdout: "pipe", stderr: "pipe" });
say(\`\${r.exitCode} \${r.stdout.toString().trim()}\`);`, bun);
  expect(out).toEqual(["0 |a 1"]);
}, 20000);

test("every src/ spawn goes through lib.ts's helpers, none passes an env object", () => {
  const raw: string[] = [];
  for (const f of readdirSync(join(ROOT, "src")).filter((f) => f.endsWith(".ts")).sort()) {
    let lines = readFileSync(join(ROOT, "src", f), "latin1").split("\n");
    if (f === "lib.ts") lines = lines.slice(0, lines.indexOf("// --- spawn-sweep twins ---"));
    lines.forEach((l, i) => {
      if (/Bun\.spawn(Sync)?\(|node:child_process|env: process\.env|\.\.\.process\.env/.test(l)) raw.push(`${f}:${i + 1}: ${l.trim()}`);
    });
  }
  expect(raw).toEqual([]);
});
