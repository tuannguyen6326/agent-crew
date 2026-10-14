// github.ts - the GitHub intake DETECTOR: `poll` records the open PRs and
// issues of a project clone's own `origin` remote and wakes the crewchief once
// per new item; `comment` posts a caller-authored verdict on a PR once per
// exact text. The entry is bin/ac-github.sh (a shim that starts this file
// through bin/ac-bun.sh); THIS header is the authoritative spec, and the bash
// original it replaced stays frozen at tests/fixtures/ac-github.sh as the
// oracle the differential leg of tests/sh/ac-github.test.sh holds this module
// to.
//
// It is a detector only - the intake-triage skill's GitHub-intake design
// constraints bind every call here:
//   L1 it never mints a records/backlog.md row (fold-or-mint needs judgement -
//      the crewchief does it on drain).
//   L2 it never verifies an item and never authors a verdict - `comment` posts
//      a verdict the caller already produced and owns only its idempotence.
//   L3 it never spawns a crewmate - the crewchief spawns the fix on its own
//      drain, under config/room-parallel.
//   L4 it never merges a PR - the captain always does.
//
// Usage:
//   ac-github.sh poll --repo <path>
//   ac-github.sh comment --repo <path> --pr <n> --body <text>
//
// VERBS: no verb, `-h` or `--help` prints on stdout, exit 0, the two lines
//   usage: ac-github.sh poll --repo <path>
//          ac-github.sh comment --repo <path> --pr <n> --body <text>
// (what the original printed - never its header); any other first word is
// `ERROR: unknown verb: <v>`, exit 1. stdin is never read here; every gh and
// git spawned inherits it.
//
// FLAGS, in any order, the last one wins, each taking the next word as its
// value: a flag with nothing after it is `ERROR: <flag> needs a value`; any
// other word is `ERROR: unknown flag: <w> (ac-github.sh poll takes --repo
// <path>)` - for comment `... (ac-github.sh comment takes --repo <path> --pr
// <n> --body <text>)`. Every refusal below is `ERROR: <msg>` on stderr, exit 1.
// A relative <path> is the caller's; from a caller cwd that has no name it
// names nothing, so it is `not a git repo: <path>`.
//
// poll --repo <path>, in this order:
//   1. empty <path>: `usage: ac-github.sh poll --repo <path>`
//   2. <path>/.git not a directory - a linked worktree's .git FILE included
//      (W1, kept): `not a git repo: <path>`
//   3. `gh not found on PATH - cannot poll GitHub`, then the same for jq (the
//      live PATH, an executable file)
//   4. no SLUG: `could not resolve the origin remote of <path>`
//   5. gh pr list, then gh issue list (GH); a non-zero status is `gh pr list
//      failed: <capture>` / `gh issue list failed: <capture>` - BEFORE the home
//      is consulted, so a homeless poll runs both and then refuses
//   6. the state dir (stateDir: ac_home's refusal when homeless, `AC_HOME is
//      not a readable directory: <h>` when it cannot be entered; state/ minted)
//   7. `mkdir -p` (spawned) of the STORE dir - its own line and status on failure
//   8. ITEMS of the PR list, then of the issue list (clause 2 of the captain's
//      pipeline before clause 3). Exit 0.
//
// ITEMS of one list <kind> (pr|issue): the original's three jq filters are
// SPAWNED over the capture, never emulated - jq's `tostring` spelling, its
// parse errors and its U+FFFD repair are the contract:
//   a. `jq -e 'type == "array"'` (output discarded) non-zero: `gh returned a
//      malformed <kind> list (not a JSON array) - refusing to poll`, the store
//      dir already minted
//   b. `jq length` (stderr passes through): non-zero - its LAST text's
//      status - ends the run with it; a count of plain digits >= 100 prints
//      on stderr `ac-github.sh poll: the <kind> list came back at exactly its
//      --limit 100 - there may be MORE open <kind>s than this poll saw; re-run
//      with a higher limit to be sure none are missed`
//   c. the extractor (stderr passes through, status ignored) prints one line
//      per item, `<number>RS<url>RS<login>RS<title>` (RS = 0x1e; url, login
//      and title stripped of codepoints below 32 and 127 inside jq, number as
//      `tostring` spells it), each LF-terminated line read as `IFS=$'\x1e'
//      read -r` reads it: cut at its first NUL, three fields up to each RS, the
//      last the rest - one trailing RS dropped, any more kept.
//   Per line: an empty number is skipped silently; a number holding a byte
//   outside 0-9 is, on stderr, `ac-github.sh poll: refusing an unattributable
//   <kind> (bad number <n>) - never guess` (`1.5`, `-1`, `1E+2`, `7.0`, `null`;
//   a JSON string "7" passes, 100000000000000000000 passes whole); an empty url
//   or login is `ac-github.sh poll: refusing <kind> #<n> - missing author or
//   url, never guess`; an existing seen-<kind>-<n> is silent; else the WAKE is
//   published, `<payload>\n` written to seen-<kind>-<n>, and stdout says
//   `ac-github.sh poll: recorded <kind>-<n> and woke the crewchief`.
//
// comment --repo <path> --pr <n> --body <text>, in this order:
//   1. any of the three empty: `usage: ac-github.sh comment --repo <path> --pr
//      <n> --body <text>`
//   2. <n> holding a byte outside 0-9: `refusing an unattributable PR number:
//      <n>` (`007` is kept as typed - in gh's argv, the file name, every line)
//   3. `not a git repo: <path>`, then `gh not found on PATH - cannot comment`
//   4. the body: `<text>\n` through redactPublish (src/lib.ts, the
//      ac_redact_publish twin - sed spawned), every trailing LF of the answer
//      dropped, so `a\nb\n\n` and `a\nb` are ONE verdict (W3, kept). HOME unset
//      is `HOME is not set` (W4); a sed that refuses (an empty HOME, a HOME
//      holding `|`) ends the run with its own line and status
//   5. no SLUG (as poll); 6. the state dir; 7. mkdir -p the STORE dir
//   8. commented-pr-<n>-<cksum> exists (<cksum> the POSIX cksum of the body,
//      cksumPosix): stdout `ac-github.sh comment: this exact verdict is already
//      posted on PR #<n> - no-op`, exit 0
//   9. `gh pr comment <n> --body <body>` (GH): non-zero is `gh pr comment
//      failed for PR #<n>: <capture>`
//   10. `<body>\n` written to that file; stdout `ac-github.sh comment: posted
//      verdict on PR #<n>`, exit 0.
//
// SLUG: `git -C <path> remote get-url origin` (stderr dropped; NULs and
// trailing LFs dropped as `$(...)` drops them); failing or empty is none. Then
// a `.git` suffix off, everything through the first `://` off, everything
// through the first `@` off, every `/` and `:` to `-`, then trailing LFs off
// as the substitution dropped them (`repo<LF>.git` is `repo`); empty is none.
// `git@github.com:acme/widgets.git`, `https://github.com/acme/widgets.git` and
// `ssh://git@github.com/acme/widgets` all give `github.com-acme-widgets`;
// `https://u:tok@host/o/r.git` gives `host-o-r`, `./x.git` `.-x`,
// `host:a/b.git/` `host-a-b.git-`. A slug holding a byte that is not UTF-8 is
// refused, `origin remote of <path> holds a byte that is not UTF-8: <slug>`.
//
// STORE, the idempotence key: state/.github/<slug>/ holds seen-<kind>-<n>
// (`<payload>\n`) and commented-pr-<n>-<cksum> (`<body>\n`), plain writes,
// nothing ever deleted - a second poll of the same open items writes nothing
// and wakes nobody, and byte-identical verdict text never posts twice. A write
// that fails is `cannot write <path>: <code>` (for a seen file, after its wake).
//
// WAKE: wakePublish (src/lib.ts, the ac_wake_publish twin) into the FLEET
// spool (scope ""), kind `github`, id `<kind>-<n>`, payload `<kind> #<n>:
// <title> (<login>) <url>` (an empty title leaves two spaces): the record
// `<ts10>\tgithub\t<kind>-<n>\t<payload>\n` named `<date +%s%N>.<pid>.<seq6>`,
// the sequence counting up through one poll. It is UNGUARDED, as the
// original's bare call under errexit was: a publish that fails exits 1 before
// the seen file exists; a `date` or AC_WAKE_SEAM_RUN hook that fails ends the
// run with ITS status.
//
// GH: `gh pr list --state open --limit 100 --json number,title,url,author`,
// `gh issue list` likewise, `gh pr comment <n> --body <body>` - from the live
// PATH, cwd <path>, stdin inherited, stdout and stderr MERGED into one capture
// in gh's write order (both fds share one temp file under TMPDIR, created
// O_EXCL and unlinked before gh starts), NULs and trailing LFs dropped. A
// list captures stderr in a second such file, read only when gh fails (then
// after stdout), because gh prints notices like its update check on stderr
// (`gh help environment`, GH_NO_UPDATE_NOTIFIER); a
// TMPDIR that cannot hold it is `cannot capture gh's output under <dir>:
// <code>` before gh runs. gh's own auth is gh's; nothing here reads a token.
//
// UNTRUSTED INPUT: title and login are cleaned inside jq; only a validated
// number ever names a file. Two holes of the original are KEPT as wire quirks:
// a JSON STRING number is not cleaned, so an RS inside it shifts the fields
// (its raw bytes, ESC included, reach the record), an LF splits the item in
// two, a NUL cuts the line and "" skips it silently (W6); and an item jq cannot
// index (an author that is a string) aborts jq for the REST of its list - jq's
// own line on stderr, no later item of that list seen (W7).
//
// DIVERGENCES from the original, named in the differential leg:
// - argv bytes: a byte that is not UTF-8 reaches Bun's argv as U+FFFD - a
//   body holding one posts U+FFFD where the original, under UTF-8, saw its sed
//   abort (W5: `RE error: illegal byte sequence`, exit 1, nothing posted) and,
//   under C, posted the byte (its cksum naming the file); a body sed leaves
//   holding such a byte (a C-locale `.` in HOME cutting a character) reaches
//   gh as U+FFFD while the file and cksum keep the byte.
// - the non-UTF-8 slug refusal above, before gh runs: the original kept the
//   byte in the store name under C (where the filesystem takes such a name -
//   APFS refuses it, so there its mkdir failed after gh ran) and cut the slug
//   at it under UTF-8 (tr's own line).
// - cd's grammar is gone from gh's cwd: a relative <path> the original's `cd`
//   found through an exported CDPATH (cd echoed it INTO the capture, so the
//   list read malformed) and a <path> starting with `-` (cd's option: `gh
//   <verb> failed: ` with cd's usage on stderr, gh never ran) are entered as
//   the directory named.
// - the home through physicalDir: an AC_HOME cd cannot enter is the ERROR
//   above where the original printed cd's own line.
// - shell-own stderr is not reproduced: `HOME: unbound variable` (now `HOME is
//   not set`), a failed redirection (now `cannot write`), `[: ...: integer
//   expression expected` for a multi-value count, and the shell's exec failure
//   text the original's `2>&1` put inside gh's capture.
// - a gh or jq on PATH that is not executable is `not found` here; the
//   original's `command -v` took it and failed running it.
// - the capture's TMPDIR refusal above: the original's pipe needed none.
// - a list is read from gh's stdout alone (GH below), so a stderr notice such
//   as `Warning: an update is available` no longer makes a good list
//   malformed (W2 in the original).
// - the extractor runs to its end before the first line is read, so jq's own
//   stderr precedes every item line; the original's loop could interleave once
//   jq's stdout passed one stdio buffer.
//
// CALLERS: nothing in bin/, src/, dashboard/, .agents/ or .claude/ runs this
// entry; the chief runs it by hand per the intake-triage skill, and a fleet
// hosts `poll` as a standing job (records/standing-jobs.md, src/standing-jobs.ts)
// whose CronCreate runs it in the chief's session. Without bun the shim prints
// `ERROR: required tool not found: bun`, exit 1, to that hand; no `set -e`
// caller dies silently, so nothing fails soft.
import { closeSync, existsSync, fstatSync, openSync, readSync, statSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { cksumPosix, die, enterCaller, redactPublish, shellStatus, spawnShellSync, stateDir, wakePublish } from "./lib.ts";

const PAGE = "100";
const EXTRACT = `
    def clean: explode | map(select(. > 31 and . != 127)) | implode;
    .[] | [
      (.number | tostring),
      ((.url // "") | clean),
      ((.author.login // "") | clean),
      ((.title // "") | clean)
    ] | join("\x1e")
  `;

// Lines are bytes: gh's and jq's output is read as latin1 and written back as
// the same bytes; an argv string joins them as its UTF-8 bytes.
const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const say = (fd: number, line: string): void => {
  writeSync(fd, b(`${line}\n`));
};
// `$(...)`: NULs dropped, trailing newlines stripped.
const captured = (s: string): string => s.replace(/\0/g, "").replace(/\n+$/, "");

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function flags(args: string[], known: string[], verb: string, takes: string): Map<string, string> {
  const m = new Map<string, string>();
  for (let i = 0; i < args.length; i += 2) {
    const f = args[i]!;
    if (!known.includes(f)) die(`unknown flag: ${f} (ac-github.sh ${verb} takes ${takes})`);
    if (i + 1 >= args.length) die(`${f} needs a value`);
    m.set(f, args[i + 1]!);
  }
  return m;
}

const callerCwd = process.argv[2] ?? "";
const { args, atCaller } = enterCaller(process.argv.slice(2));
// A caller cwd bun could not enter leaves this process in the distro root; a
// relative <path> is still the caller's, and a cwd with no name holds nothing.
const at = (p: string): string | null => (atCaller || p.startsWith("/") ? p : callerCwd === "" ? null : `${callerCwd}/${p}`);

function isRepo(repo: string): boolean {
  const dir = at(repo);
  return dir !== null && isDir(`${dir}/.git`);
}

function slugOf(repo: string): string {
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["git", "-C", at(repo)!, "remote", "get-url", "origin"], { stdin: "inherit", stdout: "pipe", stderr: "ignore" });
  } catch {}
  let url = shellStatus(r) === 0 ? captured(r!.stdout.toString("latin1")) : "";
  if (url.endsWith(".git")) url = url.slice(0, -4);
  const scheme = url.indexOf("://");
  if (scheme !== -1) url = url.slice(scheme + 3);
  const user = url.indexOf("@");
  if (user !== -1) url = url.slice(user + 1);
  // `$(printf '%s' "$url" | tr ...)`: the substitution strips trailing LFs
  // AFTER the suffix cuts, so `repo<LF>.git` keys the same store as `repo`.
  url = url.replace(/[/:]/g, "-").replace(/\n+$/, "");
  if (url === "") die(`could not resolve the origin remote of ${repo}`);
  // A path is a JS string, and a byte that is not UTF-8 has no spelling in one.
  const text = Buffer.from(url, "latin1").toString("utf8");
  if (bytes(text) !== url) die(b(`origin remote of ${bytes(repo)} holds a byte that is not UTF-8: ${url}`));
  return text;
}

function storeDir(slug: string): string {
  const store = `${stateDir()}/.github/${slug}`;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["mkdir", "-p", store], { stdin: "inherit", stdout: "inherit", stderr: "inherit" });
  } catch {}
  if (shellStatus(r) !== 0) process.exit(shellStatus(r));
  return store;
}

function captureFd(): number {
  for (let i = 0; ; i++) {
    const p = `${tmpdir()}/ac-github.${process.pid}.${i}`;
    let fd: number;
    try {
      fd = openSync(p, "wx+", 0o600);
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code !== "EEXIST") die(`cannot capture gh's output under ${tmpdir()}: ${code ?? "error"}`);
      continue;
    }
    try {
      unlinkSync(p);
    } catch {}
    return fd;
  }
}

function readFd(fd: number): string {
  const buf = Buffer.alloc(fstatSync(fd).size);
  readSync(fd, buf, 0, buf.length, 0);
  return buf.toString("latin1");
}

// `$(cd <path> && gh ... 2>&1)`: one fd behind both of gh's outputs keeps the
// order the bytes were written in, which two pipes would lose.
function gh(repo: string, argv: string[], stdoutOnly = false): { status: number; out: string } {
  const fd = captureFd();
  const errFd = stdoutOnly ? captureFd() : fd;
  try {
    let r: ReturnType<typeof Bun.spawnSync> | null = null;
    try {
      r = spawnShellSync(["gh", ...argv], { cwd: at(repo)!, stdin: "inherit", stdout: fd, stderr: errFd });
    } catch {}
    const status = shellStatus(r);
    const out = readFd(fd) + (stdoutOnly && status !== 0 ? readFd(errFd) : "");
    return { status, out: captured(out) };
  } finally {
    closeSync(fd);
    if (errFd !== fd) closeSync(errFd);
  }
}

function write(path: string, data: string): void {
  try {
    writeFileSync(path, b(data));
  } catch (e) {
    die(b(`cannot write ${bytes(path)}: ${(e as { code?: string }).code ?? "error"}`));
  }
}

// `IFS=$'\x1e' read -r number url login title`: RS is no IFS white space, so an
// empty field stays in place; the last name takes the rest of the line, less
// one trailing RS when no other RS is left in it.
function readFields(line: string): [string, string, string, string] {
  let rest = line;
  const f: string[] = [];
  for (let i = 0; i < 3; i++) {
    const k = rest.indexOf("\x1e");
    f.push(k === -1 ? rest : rest.slice(0, k));
    rest = k === -1 ? "" : rest.slice(k + 1);
  }
  const k = rest.indexOf("\x1e");
  f.push(k === rest.length - 1 ? rest.slice(0, k) : rest);
  return f as [string, string, string, string];
}

function pollItems(store: string, kind: string, list: string): void {
  const json = b(list);
  const jq = (argv: string[], stdout: "pipe" | "ignore", stderr: "inherit" | "ignore"): ReturnType<typeof Bun.spawnSync> | null => {
    try {
      return spawnShellSync(["jq", ...argv], { stdin: json, stdout, stderr });
    } catch {
      return null;
    }
  };
  if (shellStatus(jq(["-e", 'type == "array"'], "ignore", "ignore")) !== 0) die(`gh returned a malformed ${kind} list (not a JSON array) - refusing to poll`);
  const length = jq(["length"], "pipe", "inherit");
  if (shellStatus(length) !== 0) process.exit(shellStatus(length));
  // `[ "$count" -ge 100 ]`: a count of several values (one per JSON text in
  // the capture) is no integer to the shell, so it never calls the page full.
  const count = captured(length!.stdout.toString("latin1"));
  if (/^[0-9]+$/.test(count) && Number(count) >= Number(PAGE)) {
    say(2, `ac-github.sh poll: the ${kind} list came back at exactly its --limit ${PAGE} - there may be MORE open ${kind}s than this poll saw; re-run with a higher limit to be sure none are missed`);
  }
  const lines = (jq(["-r", EXTRACT], "pipe", "inherit")?.stdout.toString("latin1") ?? "").split("\n");
  // `read` never returns an unterminated last line.
  lines.pop();
  for (const line of lines) {
    const [number, url, login, title] = readFields(line.replace(/\0[\s\S]*$/, ""));
    if (number === "") continue;
    if (/[^0-9]/.test(number)) {
      say(2, `ac-github.sh poll: refusing an unattributable ${kind} (bad number ${number}) - never guess`);
      continue;
    }
    if (url === "" || login === "") {
      say(2, `ac-github.sh poll: refusing ${kind} #${number} - missing author or url, never guess`);
      continue;
    }
    const key = `${kind}-${number}`;
    const seen = `${store}/seen-${key}`;
    if (existsSync(seen)) continue;
    const payload = `${kind} #${number}: ${title} (${login}) ${url}`;
    let published: boolean;
    try {
      published = wakePublish(stateDir(), "", "github", key, payload, true);
    } catch (e) {
      const { code, status } = e as { code?: string; status?: number };
      if (code !== "EDATE" && code !== "ESEAM") throw e;
      process.exit(status!);
    }
    if (!published) process.exit(1);
    write(seen, `${payload}\n`);
    say(1, `ac-github.sh poll: recorded ${key} and woke the crewchief`);
  }
}

function poll(argv: string[]): void {
  const repo = flags(argv, ["--repo"], "poll", "--repo <path>").get("--repo") ?? "";
  if (repo === "") die("usage: ac-github.sh poll --repo <path>");
  if (!isRepo(repo)) die(`not a git repo: ${repo}`);
  if (!Bun.which("gh")) die("gh not found on PATH - cannot poll GitHub");
  if (!Bun.which("jq")) die("jq not found on PATH - cannot poll GitHub");
  const slug = slugOf(repo);
  const prs = gh(repo, ["pr", "list", "--state", "open", "--limit", PAGE, "--json", "number,title,url,author"], true);
  if (prs.status !== 0) die(b(`gh pr list failed: ${prs.out}`));
  const issues = gh(repo, ["issue", "list", "--state", "open", "--limit", PAGE, "--json", "number,title,url,author"], true);
  if (issues.status !== 0) die(b(`gh issue list failed: ${issues.out}`));
  const store = storeDir(slug);
  pollItems(store, "pr", prs.out);
  pollItems(store, "issue", issues.out);
}

function comment(argv: string[]): void {
  const f = flags(argv, ["--repo", "--pr", "--body"], "comment", "--repo <path> --pr <n> --body <text>");
  const repo = f.get("--repo") ?? "";
  const pr = f.get("--pr") ?? "";
  const text = f.get("--body") ?? "";
  if (repo === "" || pr === "" || text === "") die("usage: ac-github.sh comment --repo <path> --pr <n> --body <text>");
  if (/[^0-9]/.test(pr)) die(`refusing an unattributable PR number: ${pr}`);
  if (!isRepo(repo)) die(`not a git repo: ${repo}`);
  if (!Bun.which("gh")) die("gh not found on PATH - cannot comment");
  let body: string;
  try {
    body = captured(redactPublish(`${bytes(text)}\n`));
  } catch (e) {
    const { code, status } = e as { code?: string; status?: number };
    if (code === "ENOHOME") die("HOME is not set");
    if (code !== "ESED") throw e;
    process.exit(status!);
  }
  const store = storeDir(slugOf(repo));
  const done = `${store}/commented-pr-${pr}-${cksumPosix(b(body))}`;
  if (existsSync(done)) {
    say(1, `ac-github.sh comment: this exact verdict is already posted on PR #${pr} - no-op`);
    return;
  }
  const r = gh(repo, ["pr", "comment", pr, "--body", Buffer.from(body, "latin1").toString("utf8")]);
  if (r.status !== 0) die(b(`gh pr comment failed for PR #${pr}: ${r.out}`));
  write(done, `${body}\n`);
  say(1, `ac-github.sh comment: posted verdict on PR #${pr}`);
}

const verb = args[0] ?? "";
if (verb === "poll") poll(args.slice(1));
else if (verb === "comment") comment(args.slice(1));
else if (verb === "" || verb === "-h" || verb === "--help") {
  say(1, "usage: ac-github.sh poll --repo <path>");
  say(1, "       ac-github.sh comment --repo <path> --pr <n> --body <text>");
} else die(`unknown verb: ${verb}`);
