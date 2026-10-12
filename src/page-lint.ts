// page-lint.ts - PAGE-SYNTAX LINT: catch a syntax error inside a served
// dashboard page's inline <script> content before it reaches the browser. The
// entry is bin/ac-page-lint.sh (a shim that starts this file through
// bin/ac-bun.sh); THIS header is the authoritative spec, and the bash original
// it replaced stays frozen at tests/fixtures/ac-page-lint.sh as the oracle the
// differential leg of tests/sh/ac-page-lint.test.sh holds this module to.
//
// WHY: dashboard/page.ts's PAGE constant (and dashboard/app.ts's other page
// builders) hold each page as a template-literal STRING. Everything after the
// opening backtick is plain text to tsc and unreachable to `bun test` - it
// exists as source only once interpolated into the served HTML - so a syntax
// error inside a page's inline <script> does not fail the build and is not
// caught by tsc. It fires at RENDER, in front of whoever opens the page. This
// is the one shared check instead of re-deriving it by hand at every landing
// that touches a dashboard page.
//
// Usage: ac-page-lint.sh
//   Starts its own dashboard on a free port, fetches every page in PAGES
//   below, extracts each inline <script>...</script> block (a block whose
//   opening tag carries a src= attribute is external - nothing to check), runs
//   `bun build --no-bundle` over each one, and stops the dashboard again.
//   Prints `OK <path> (<n> scripts)` per clean page, or one `SYNTAX ERROR
//   <path> script <i>: <bun stderr>` block per failing script.
//
// PAGES is a FIXED list, not derived from the route table: every route in
// dashboard/app.ts that unconditionally serves a full HTML document belongs in
// it (checked against source 2026-08-22 - dashboard/app.ts's Bun.serve fetch
// handler gates /term-frame and /attach-frame behind a ?path=<home> that must
// pass allowedHomePaths(), so those two are excluded). Adding a new
// unconditional HTML page route to dashboard/app.ts means adding it here too.
//
// THE DASHBOARD is <root>/dashboard/app.ts, <root> being the checkout the
// shim's bin/ sits in physically: bin/ac-bun.sh starts bun there and this
// module takes the root of the bin/ it was started in (STARTED_BIN,
// src/lib.ts) - so a copy of the shim with bin/ac-bun.sh beside it and src/
// linked boots the copy's own dashboard/. Booting the real one also opens its
// guest share listener on <port>+1, bound to every interface
// (dashboard/app.ts; W4 - the dashboard's, not the lint's).
//
// ARGUMENTS: only the first is read: `-h`/`--help` prints this header on
// stdout, exit 0; absent or "" runs; anything else is `ac-page-lint.sh:
// unknown arg: <arg>` on stderr, exit 2. stdin is never read: every child but
// the dashboard inherits it, the dashboard gets /dev/null.
//
// THE RUN, every refusal on stderr:
// 1. `command -v` finds curl, then perl (commandV, src/lib.ts, bash's own
//    PATH search: a found entry that is not executable counts, and then fails
//    to run) - else `ac-page-lint.sh: <tool> not found`, exit 3.
// 2. `mktemp -d` (spawned, its own stderr passing through; BSD mktemp with no
//    template ignores TMPDIR) - failing: `ac-page-lint.sh: mktemp failed`,
//    exit 3. The run then works INSIDE that directory, so bun build and curl
//    never see the caller's cwd (it may be gone or hold a bunfig.toml); a cd
//    that fails is exit 3 with no line. From here on every exit - and a
//    SIGHUP, SIGINT or SIGTERM, which then exits 128+<signal> - stops the
//    dashboard with a TERM and removes the directory.
// 3. a free port: up to 30 draws of (RANDOM % 20000) + 20000, RANDOM being
//    0-32767, each free when a connect to 127.0.0.1:<port> fails - else
//    `ac-page-lint.sh: could not find a free port`, exit 3.
// 4. the dashboard: `bun --no-env-file <root>/dashboard/app.ts <tmpdir>
//    --port <port>` started as bin/ac-bun.sh starts a module (in <root>,
//    BUN_*/JSC_* dropped), stdout and stderr into <tmpdir>/dashboard.log. Up
//    to 50 polls: the dashboard has exited -> stop polling; `curl -fsS -o
//    /dev/null http://127.0.0.1:<port>/` succeeds -> up; else a spawned
//    `sleep 0.2`. The curl has no time limit, so a dashboard that accepts `/`
//    and never answers holds the run for good (W5, kept). Not up:
//    `ac-page-lint.sh: dashboard did not come up on port <port>`, then the
//    log with every line prefixed by two spaces (a blank line becomes two
//    spaces, a last line without LF keeps none), exit 3.
// 5. per page, in list order: `curl -fsS <url> -o <tmpdir>/page.html`
//    failing -> `TOOLING ERROR <path>: could not fetch (<curl stderr>)`; the
//    extraction failing -> `TOOLING ERROR <path>: script extraction failed
//    (<perl stderr>)` - both on stderr, the page skipped; else per extracted
//    script `bun build --no-bundle <tmpdir>/scripts/<i>.js` (the PATH bun,
//    stdout dropped): failing -> `SYNTAX ERROR <path> script <i>: <bun
//    stderr>` on stdout; a page with none failing -> `OK <path> (<n>
//    scripts)` on stdout. Each <... stderr> is the child's whole text with
//    NULs dropped and trailing LFs stripped.
//
// EXTRACTION is the original's perl program, spawned verbatim: the page
// slurped, every `/<script\b([^>]*)>(.*?)<\/script>/gs` match walked, a block
// skipped when its attributes match `/\bsrc\s*=/i` or its body is only
// whitespace, the rest written to scripts/1.js, 2.js, ... and their count
// printed. A JS string inside a real inline script that embeds its own
// literal "<\/script>" (dashboard/app.ts's OVERLAY constant does) keeps its
// escaping backslash in the served page, so it never closes the block early;
// an unterminated last <script> is dropped. Kept warts:
//   W1 `\bsrc\s*=` also matches `data-src=` (any `*-src=`), so such an inline
//      script is skipped unchecked.
//   W2 bun's stderr is several lines and names the random tmpdir, so one
//      failing script's SYNTAX ERROR is a block, never byte-stable.
//   W3 the tag is case-sensitive: a `<SCRIPT>` block is never extracted.
//
// EXIT: 0 every script compiled clean; 1 at least one page has a confirmed
// syntax error; 2 usage; 3 no page had a syntax error, but tooling could not
// run for at least one (the dashboard failed to start, curl/perl missing, a
// page fetch or script extraction failed). A confirmed syntax error always
// exits 1, even when ANOTHER page's own check also failed for tooling
// reasons (that page's TOOLING ERROR line still prints to stderr) - a real
// defect outranks an unrelated page's coverage gap, but exit 1 alone does
// not promise every page was actually checked; read stderr for that.
//
// DIVERGENCES from the original, named in the differential leg: -h prints
// THIS header where the original printed its bash header; without bun the
// shim refuses every run - -h and a bad argument included - with `ERROR:
// required tool not found: bun`, exit 1, where the original checked bun
// itself (`ac-page-lint.sh: bun not found`, exit 3); a
// found curl or perl that cannot run leaves its TOOLING ERROR's parentheses
// empty where the original carried the shell's own `Permission denied` line;
// a signal ends the run with the status 128+<signal> where bash died by it;
// without seq(1) on PATH the original's counted loops ran zero times (`could
// not find a free port`, exit 3) where the port counts its own;
// the log dump prefixes every byte where BSD sed under a UTF-8 locale stopped
// at an invalid one (`sed: RE error: illegal byte sequence`); bun build no
// longer sees a caller's BUN_*/JSC_* names, which bin/ac-bun.sh drops before
// this module starts (no probed name changed a verdict); a SIGINT the
// caller's shell left ignored (an async job of a non-interactive shell) now
// ends the run where the original ran on. An argument that is not UTF-8
// reaches this module as U+FFFD, and the unknown-arg line prints that.
//
// CALLERS: humans after a dashboard page change (CONTRIBUTING.md); no `set -e`
// caller runs it, so nothing fails soft.
import { closeSync, mkdirSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";
import { createConnection } from "node:net";
import { dirname, join } from "node:path";
import { commandV, enterCaller, spawnShell, spawnShellSync, STARTED_BIN } from "./lib.ts";

const PAGES = ["/", "/term", "/whiteboard", "/whiteboard-frame", "/review"];

const EXTRACT = String.raw`
    my ($html, $outdir) = @ARGV;
    local $/;
    open(my $fh, "<", $html) or die "read $html: $!";
    my $doc = <$fh>;
    close $fh;
    my $i = 0;
    while ($doc =~ /<script\b([^>]*)>(.*?)<\/script>/gs) {
      my ($attrs, $body) = ($1, $2);
      next if $attrs =~ /\bsrc\s*=/i;
      next if $body =~ /^\s*$/s;
      $i++;
      open(my $out, ">", "$outdir/$i.js") or die "write $outdir/$i.js: $!";
      print $out $body;
      close $out;
    }
    print $i;
  `;

// Child text is bytes (latin1 in, latin1 out); an argument is UTF-8.
const say = (fd: number, text: string, enc: "latin1" | "utf8" = "latin1"): void => {
  writeSync(fd, Buffer.from(text, enc));
};
const captured = (b: Buffer): string => b.toString("latin1").replace(/\0/g, "").replace(/\n+$/, "");
const indented = (log: string): string => log.replace(/[^\n]*\n|[^\n]+$/g, (l) => `  ${l}`);

function usage(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(0);
}

// A child that cannot start reads as the shell's failed command: non-zero,
// nothing captured. Async, so a signal is handled while a child hangs.
async function child(argv: string[], stdout: "inherit" | "ignore" | "pipe", stderr: "inherit" | "ignore" | "pipe"): Promise<{ ok: boolean; out: Buffer; err: Buffer }> {
  try {
    const p = spawnShell(argv, { stdin: "inherit", stdout, stderr });
    const [out, err] = await Promise.all([
      stdout === "pipe" ? new Response(p.stdout as ReadableStream).arrayBuffer() : new ArrayBuffer(0),
      stderr === "pipe" ? new Response(p.stderr as ReadableStream).arrayBuffer() : new ArrayBuffer(0),
    ]);
    await p.exited;
    return { ok: p.exitCode === 0, out: Buffer.from(out), err: Buffer.from(err) };
  } catch {
    return { ok: false, out: Buffer.alloc(0), err: Buffer.alloc(0) };
  }
}

const busy = (port: number): Promise<boolean> =>
  new Promise((done) => {
    const s = createConnection({ host: "127.0.0.1", port });
    s.on("connect", () => {
      s.destroy();
      done(true);
    });
    s.on("error", () => done(false));
  });

const { args } = enterCaller(process.argv.slice(2));
const root = dirname(STARTED_BIN);
const arg = args[0] ?? "";
if (arg === "-h" || arg === "--help") usage();
if (arg !== "") {
  say(2, `ac-page-lint.sh: unknown arg: ${arg}\n`, "utf8");
  process.exit(2);
}

for (const t of ["curl", "perl"]) {
  if (!commandV(t)) {
    say(2, `ac-page-lint.sh: ${t} not found\n`);
    process.exit(3);
  }
}

let tmpdir = "";
let made = false;
try {
  const r = spawnShellSync(["mktemp", "-d"], { stdin: "inherit", stdout: "pipe", stderr: "inherit" });
  made = r.exitCode === 0;
  tmpdir = r.stdout.toString("utf8").replace(/\0/g, "").replace(/\n+$/, "");
} catch {}
if (!made) {
  say(2, "ac-page-lint.sh: mktemp failed\n");
  process.exit(3);
}
try {
  process.chdir(tmpdir);
} catch {
  process.exit(3);
}

let dash: ReturnType<typeof spawnShell> | undefined;
for (const [sig, n] of [["SIGHUP", 1], ["SIGINT", 2], ["SIGTERM", 15]] as const) {
  process.on(sig, () => {
    try {
      if (dash) process.kill(dash.pid, "SIGTERM");
    } catch {}
    rmSync(tmpdir, { recursive: true, force: true });
    process.exit(128 + n);
  });
}

async function lint(): Promise<number> {
  // Our own port, not ac-dashboard.sh's busy-port guard nor 0: the curls need
  // the number, and dashboardMain() reports the --port it was given, not the
  // one Bun.serve bound.
  let port = 0;
  for (let k = 0; k < 30 && port === 0; k++) {
    const p = (Math.floor(Math.random() * 32768) % 20000) + 20000;
    if (!(await busy(p))) port = p;
  }
  if (port === 0) {
    say(2, "ac-page-lint.sh: could not find a free port\n");
    return 3;
  }

  const log = openSync(`${tmpdir}/dashboard.log`, "w");
  const unset = Object.keys(process.env).filter((k) => /^(BUN_|JSC_)/.test(k)).flatMap((k) => ["-u", k]);
  dash = spawnShell(["/usr/bin/env", ...unset, process.execPath, "--no-env-file", join(root, "dashboard/app.ts"), process.cwd(), "--port", String(port)], {
    cwd: root,
    stdin: "ignore",
    stdout: log,
    stderr: log,
  });
  closeSync(log);
  let gone = false;
  void dash.exited.then(() => {
    gone = true;
  });

  let ready = false;
  for (let k = 0; k < 50 && !gone; k++) {
    if ((await child(["curl", "-fsS", "-o", "/dev/null", `http://127.0.0.1:${port}/`], "inherit", "ignore")).ok) {
      ready = true;
      break;
    }
    await child(["sleep", "0.2"], "inherit", "inherit");
  }
  if (!ready) {
    say(2, `ac-page-lint.sh: dashboard did not come up on port ${port}\n`);
    try {
      say(2, indented(readFileSync(`${tmpdir}/dashboard.log`, "latin1")));
    } catch {}
    return 3;
  }

  let tooling = false;
  let broken = false;
  for (const path of PAGES) {
    const html = `${tmpdir}/page.html`;
    const fetched = await child(["curl", "-fsS", `http://127.0.0.1:${port}${path}`, "-o", html], "inherit", "pipe");
    if (!fetched.ok) {
      say(2, `TOOLING ERROR ${path}: could not fetch (${captured(fetched.err)})\n`);
      tooling = true;
      continue;
    }
    const scripts = `${tmpdir}/scripts`;
    rmSync(scripts, { recursive: true, force: true });
    mkdirSync(scripts, { recursive: true });
    const x = await child(["perl", "-e", EXTRACT, html, scripts], "pipe", "pipe");
    if (!x.ok) {
      say(2, `TOOLING ERROR ${path}: script extraction failed (${captured(x.err)})\n`);
      tooling = true;
      continue;
    }
    const n = captured(x.out);
    let bad = false;
    for (let i = 1; i <= Number(n); i++) {
      const b = await child(["bun", "build", "--no-bundle", `${scripts}/${i}.js`], "ignore", "pipe");
      if (!b.ok) {
        say(1, `SYNTAX ERROR ${path} script ${i}: ${captured(b.err)}\n`);
        bad = broken = true;
      }
    }
    if (!bad) say(1, `OK ${path} (${n} scripts)\n`);
  }
  return broken ? 1 : tooling ? 3 : 0;
}

let code = 1;
try {
  code = await lint();
} finally {
  if (dash) {
    try {
      dash.kill("SIGTERM");
    } catch {}
    await dash.exited;
  }
  rmSync(tmpdir, { recursive: true, force: true });
}
process.exit(code);
