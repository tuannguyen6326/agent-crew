// paths.ts - the QA scripts' path checks and free-port pick. bin/ac-qa.sh,
// bin/ac-qa-lib.sh and bin/ac-verify.sh start it through bin/ac-bun.sh, always
// inside a subshell because ac_bun_exec execs; THIS header is the
// authoritative spec.
//
// Usage (the caller's cwd arrives first, from ac_bun_exec):
//   paths.ts within <root> <candidate>
//       exit 0 when <candidate> - taken under <root> unless absolute - resolves
//       to an existing file or directory at or below resolved <root>, else 1.
//       Nothing guards an empty or `-` candidate: "" names the root itself.
//   paths.ts receipt-ok <run-dir> <case-id> <path>
//       exit 0 when every argument is non-empty, <path> is not `-`, is a
//       regular file and not a symlink, and its resolved parent IS resolved
//       os.path.join(<run-dir>, "boundaries", <case-id>), else 1. join's rule
//       holds: an absolute <case-id> replaces the run dir.
//   paths.ts realpath <path>    prints the resolved path and a newline
//   paths.ts free-port          prints a TCP port the kernel had free on
//                               127.0.0.1 and a newline
//
// "Resolved" is python's os.path.realpath (non-strict), step for step, because
// every verdict and recorded path downstream was written against it: an
// existing component is lstat'd and a symlink replaced by its target, `..`
// drops the last component resolved so far (physical, not lexical), a missing
// or unreadable component is kept as spelled - so `missing/..` cancels out -
// and a symlink loop is kept unresolved. fs.realpathSync is not that: it
// refuses a missing path and folds a case-insensitive volume's spelling to the
// on-disk case, which would change the path a ledger records.
//
// A relative path resolves against the caller's cwd. When that cwd has no name
// Bun can report, a check that needs it exits 1 with an ERROR line. A usage
// error exits 1.
//
// Deliberate divergence: Bun decodes argv and symlink targets as UTF-8 with
// replacement, so a path whose bytes are not UTF-8 cannot be named - and one
// spelled with them could name a different, real file whose name holds
// U+FFFD. within and receipt-ok therefore refuse any argument carrying U+FFFD
// (python judged the bytes as given).

import { lstatSync, readlinkSync, statSync, writeSync } from "node:fs";
import { die, enterCaller } from "./lib.ts";

export function pyRealpath(filename: string, cwd: () => string): string {
  const rest: (string | null)[] = filename.split("/").reverse();
  let parts = rest.length;
  let path = filename.startsWith("/") ? "/" : cwd();
  // A link maps to null while its target is being resolved, so meeting it
  // again inside that resolution is a loop.
  const seen = new Map<string, string | null>();
  while (parts) {
    const name = rest.pop() as string | null;
    if (name === null) {
      seen.set(rest.pop() as string, path);
      continue;
    }
    parts--;
    if (name === "" || name === ".") continue;
    if (name === "..") {
      path = path.slice(0, path.lastIndexOf("/")) || "/";
      continue;
    }
    const next = path === "/" ? path + name : `${path}/${name}`;
    let target: string;
    try {
      if (!lstatSync(next).isSymbolicLink()) {
        path = next;
        continue;
      }
      if (seen.has(next)) {
        path = seen.get(next) ?? next;
        continue;
      }
      target = readlinkSync(next);
    } catch {
      path = next;
      continue;
    }
    if (target.startsWith("/")) path = "/";
    seen.set(next, null);
    rest.push(next, null);
    const targetParts = target.split("/").reverse();
    rest.push(...targetParts);
    parts += targetParts.length;
  }
  return path;
}

export function pyJoin(a: string, ...p: string[]): string {
  let path = a;
  for (const b of p) {
    if (b.startsWith("/") || !path) path = b;
    else if (path.endsWith("/")) path += b;
    else path += `/${b}`;
  }
  return path;
}

export function pyDirname(p: string): string {
  const head = p.slice(0, p.lastIndexOf("/") + 1);
  return head && head !== "/".repeat(head.length) ? head.replace(/\/+$/, "") : head;
}

function kind(p: string, follow: boolean): "file" | "dir" | "link" | "other" | null {
  try {
    const s = follow ? statSync(p) : lstatSync(p);
    return s.isSymbolicLink() ? "link" : s.isFile() ? "file" : s.isDirectory() ? "dir" : "other";
  } catch {
    return null;
  }
}

export function within(root: string, candidate: string, cwd: () => string): boolean {
  const r = pyRealpath(root, cwd);
  const c = pyRealpath(candidate.startsWith("/") ? candidate : pyJoin(r, candidate), cwd);
  // realpath output is absolute with no empty, `.` or `..` component, so
  // commonpath((r, c)) == r is exactly a component-prefix test.
  const inside = c === r || c.startsWith(r === "/" ? "/" : `${r}/`);
  const k = kind(c, true);
  return inside && (k === "file" || k === "dir");
}

export function receiptOk(rd: string, caseId: string, path: string, cwd: () => string): boolean {
  if (!rd || !caseId || !path || path === "-") return false;
  const abs = path.startsWith("/") ? path : pyJoin(cwd(), path);
  if (kind(abs, false) === "link" || kind(abs, true) !== "file") return false;
  return pyRealpath(pyDirname(path), cwd) === pyRealpath(pyJoin(rd, "boundaries", caseId), cwd);
}

function freePort(): number {
  const s = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } });
  const port = s.port;
  s.stop(true);
  return port;
}

function main(args: string[], cwd: () => string): number {
  const [verb, ...a] = args;
  if ((verb === "within" || verb === "receipt-ok") && a.some((x) => x.includes("\ufffd"))) return 1;
  if (verb === "within" && a.length === 2) return within(a[0], a[1], cwd) ? 0 : 1;
  if (verb === "receipt-ok" && a.length === 3) return receiptOk(a[0], a[1], a[2], cwd) ? 0 : 1;
  if (verb === "realpath" && a.length === 1) {
    writeSync(1, `${pyRealpath(a[0], cwd)}\n`);
    return 0;
  }
  if (verb === "free-port" && a.length === 0) {
    writeSync(1, `${freePort()}\n`);
    return 0;
  }
  die("usage: paths.ts within <root> <candidate> | receipt-ok <run-dir> <case-id> <path> | realpath <path> | free-port");
}

if (import.meta.main) {
  const { args, atCaller } = enterCaller(process.argv.slice(2));
  process.exit(
    main(args, () => (atCaller ? process.cwd() : die("the current directory cannot be resolved, so a relative path cannot be either"))),
  );
}
