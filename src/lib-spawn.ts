// lib-spawn.ts - the spawn twins src/lib.ts's fanout rule keeps beside their port
// (its header): the TypeScript twins at most two ports import, each keeping its
// bash original's observable contract as every twin in src/lib.ts does.

import { accessSync, appendFileSync, closeSync, constants, existsSync, ftruncateSync, lstatSync, openSync, readFileSync, readdirSync, readlinkSync, writeFileSync, writeSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { Ended, SpawnIo, VerbIo } from "./lib.ts";
import { shaSoft } from "./lib-curate.ts";
import {
  agentIdlePane,
  argvOf,
  arithValue,
  backendCall,
  backendRoute,
  backendStartupDialogsPane,
  capturedText,
  configReadSoft,
  dialogAnswerPane,
  die,
  exclusiveTemp,
  herdrCli,
  herdrVerb,
  isDir,
  isFile,
  isLink,
  iso,
  keyNamed,
  lat,
  latBuf,
  lockAcquire,
  lockRelease,
  metaGet,
  metaRewrite,
  metaSet,
  nowRaw,
  orcaSubmitVerified,
  orcaVerb,
  paneField,
  physicalDir,
  prefixed,
  projectConfigFile,
  shellQuote,
  shellStatus,
  SKILLS_ARCHIVE,
  sleepOne,
  softHome,
  softSubdir,
  spawnShellSync,
  stage,
  STARTED_BIN,
  startupDialogs,
  submitVerified,
  tabFields,
  testInt,
  wakeScopeOk,
  warn,
  yamlGet,
} from "./lib.ts";

const SEED_STAMPS = ".claude/.ac-seed";

const SEED_FALLBACK = ".claude/CREWMATE.md";

// ac_harness_instruction_file's twin as `$(...)` ran it: the file the harness
// loads, relative to its worktree ("" reads claude); a harness neither
// built-in nor given a config/launch-<h> template is the ERROR line and null -
// the die ended only the substitution.
export function harnessInstructionFile(h: string): string | null {
  const name = h || "claude";
  if (["codex", "opencode", "pi", "cursor"].includes(name)) return "AGENTS.md";
  if (name === "claude" || isFile(`${softHome(true)}/config/launch-${name}`)) return ".claude/CLAUDE.md";
  writeSync(2, prefixed("ERROR: ", `unknown harness '${name}': no registry entry (bin/ac-harness.sh) and no config/launch-${name} template - refusing to guess which instruction file it loads`));
  return null;
}

// ac_record_launch_opts' twin: only what the harness's built-in launch applies
// is written - model, then effort, one metaSet each (values decoded, written as
// their UTF-8 bytes); <applied> "" reads <effort>. A refused write throws as
// metaSet does: the errexit caller ended there.
export function recordLaunchOpts(meta: string, harness: string, model: string, effort: string, applied = ""): void {
  const set = (k: string, v: string): void => {
    if (v !== "") metaSet(meta, k, lat(v));
  };
  const eff = applied || effort;
  if (harness === "claude") {
    set("model", model);
    set("effort", effort);
  } else if (harness === "codex" || harness === "pi") {
    set("model", model);
    set("effort", eff);
  } else if (harness === "opencode" || harness === "cursor") set("model", model);
}

// ac_compact_pct_env's twin as `$(...)` ran it: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=<p> `
// for a config/compact-pct of 1-100 as `[ -ge ]` reads it (007 is 7), "" when
// unset; any other value is the reason line on stderr - no WARN prefix - and
// "". The digit grammar is read per the text (bash 3.2's [!0-9] collated
// under UTF-8 - named); past int64 `[`'s own line is not reproduced.
export function compactPctEnv(): string {
  const p = configReadSoft("compact-pct", "");
  if (p === "") return "";
  const n = /^[0-9]+$/.test(p) ? testInt(p) : null;
  if (n !== null && n >= 1n && n <= 100n) return `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=${p} `;
  writeSync(2, `config/compact-pct: ${p} is not 1-100 - claude keeps its default threshold\n`);
  return "";
}

// ac_claude_config_env's twin, bytes (latin1) out: `CLAUDE_CONFIG_DIR=<%q> `
// when the variable is set non-empty, then always
// `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 `.
export function claudeConfigEnv(): string {
  const d = process.env.CLAUDE_CONFIG_DIR;
  return `${d ? `CLAUDE_CONFIG_DIR=${shellQuote(lat(d))} ` : ""}CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 `;
}

// ac_build_launch's twin as `$(...)` ran it: the built-in launch command for
// <h>, its parts concatenated unquoted as given; a resume id wins over a
// session id. Any other harness is the ERROR line naming <config>/launch-<h>
// and null - config/ minted on the way, as ac_config_dir did.
export function buildLaunch(h: string, m = "", e = "", rsid = "", sid = ""): string | null {
  const opt = (flag: string, v: string): string => (v === "" ? "" : ` ${flag} ${v}`);
  switch (h) {
    case "claude":
      return `claude --permission-mode auto${rsid ? opt("--resume", rsid) : opt("--session-id", sid)}${opt("--model", m)}${opt("--effort", e)}`;
    case "codex":
      return `codex -c check_for_update_on_startup=false${opt("-m", m)}${e === "" ? "" : ` -c model_reasoning_effort=${e}`}`;
    case "opencode":
      return `opencode${opt("-m", m)}`;
    case "pi":
      return `pi --tui-mode regular${opt("--model", m)}${opt("--thinking", e)}`;
    case "cursor":
      return `cursor-agent --yolo${opt("--model", m)}`;
  }
  writeSync(2, prefixed("ERROR: ", `no launch template for harness '${h}'; create ${softSubdir("config", true)}/launch-${h}`));
  return null;
}

// ac_resolve_profile's twin as `$(...)` ran it, bytes (latin1) out: the argv
// parsed as the bash parsed it, then `harness=<h>\tmodel=<m>\teffort=<e>` (the
// capture's reading, no LF) and 0. --rule resolves through
// <ac_root>/bin/ac-dispatch-select.sh --rule <n> - its stderr the caller's,
// its failure the status - read as `IFS=$'\t' read -r` reads the first line,
// a knob named explicitly winning per knob; with no rule and no harness a
// config/crew-dispatch.json refuses and config/crew-harness (else claude)
// answers. A refusal is the ERROR line and status 1.
export function resolveProfile(args: string[]): { status: number; out: string } {
  const vals = new Map([["--rule", ""], ["--harness", ""], ["--model", ""], ["--effort", ""]]);
  const refuse = (msg: string): { status: number; out: string } => {
    writeSync(2, prefixed("ERROR: ", msg));
    return { status: 1, out: "" };
  };
  for (let i = 0; i < args.length; i += 2) {
    const a = args[i]!;
    if (!vals.has(a)) return refuse(`ac_resolve_profile: unknown arg ${a}`);
    if (i + 1 >= args.length) return refuse(`${a} needs a value`);
    vals.set(a, lat(args[i + 1]!));
  }
  let [h, m, e] = [vals.get("--harness")!, vals.get("--model")!, vals.get("--effort")!];
  const rule = vals.get("--rule")!;
  if (rule !== "") {
    const r = stage([`${STARTED_BIN}/ac-dispatch-select.sh`, "--rule", argvOf(rule)], "inherit", "pipe", "inherit");
    if (r.status !== 0) return { status: r.status, out: "" };
    const [ph, pm, pe] = tabFields(capturedText(r.out).split("\n")[0]!, 3) as [string, string, string];
    const strip = (v: string, k: string): string => (v.startsWith(k) ? v.slice(k.length) : v);
    h ||= strip(ph, "harness=");
    m ||= strip(pm, "model=");
    e ||= strip(pe, "effort=");
  } else if (h === "") {
    if (isFile(`${softSubdir("config", true)}/crew-dispatch.json`))
      return refuse("config/crew-dispatch.json is configured: pick a profile (bin/ac-dispatch-select.sh --list, then --rule <n>) and pass --harness/--model/--effort explicitly");
    h = lat(configReadSoft("crew-harness", "claude"));
  }
  return { status: 0, out: `harness=${h}\tmodel=${m}\teffort=${e}` };
}

// ac_pane_profile's twin as `$(...)` ran it: <ac_root>/bin/ac-dispatch-select.sh
// --pane <kind>, its stdout as the capture read it (latin1), its stderr where
// the call site sent it, its status.
export function paneProfile(kind: string, stderr: "inherit" | "ignore" = "inherit"): { status: number; out: string } {
  const r = stage([`${STARTED_BIN}/ac-dispatch-select.sh`, "--pane", kind], "inherit", "pipe", stderr);
  return { status: r.status, out: capturedText(r.out) };
}

// ac_domain_binding's twin, decoded: AC_DOMAIN when set non-empty, else - for
// an AC_SCOPE inside [A-Za-z0-9_-]+, read per the text (W10) - the domain= of
// state/<scope>-chief.meta, an unreadable one warned and read as none; ""
// when neither answers.
export function domainBinding(): string {
  if (process.env.AC_DOMAIN) return process.env.AC_DOMAIN;
  const scope = process.env.AC_SCOPE ?? "";
  if (!wakeScopeOk(scope)) return "";
  try {
    return argvOf(metaGet(`${softSubdir("state", true)}/${scope}-chief.meta`, "domain"));
  } catch {
    return "";
  }
}

// `cat <src> >[>]<dst>`: the shell's open of <dst> (a failure skips cat, its
// own line not reproduced), then cat spawned into it.
function catInto(src: string, dst: string, append = false): void {
  let fd: number;
  try {
    fd = openSync(dst, append ? "a" : "w");
  } catch {
    return;
  }
  try {
    spawnShellSync(["cat", src], { stdin: "inherit", stdout: fd, stderr: "inherit" });
  } catch {
  } finally {
    closeSync(fd);
  }
}

const rmF = (p: string): number => stage(["rm", "-f", p], "inherit", "inherit", "inherit").status;

const gitExclude = (wt: string): string | null => {
  const g = stage(["git", "-C", wt, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], "inherit", "pipe", "ignore");
  return g.status === 0 ? capturedText(g.out) : null;
};

// `grep -qxF <line> <excl> 2>/dev/null || printf '<line>\n' >>"$excl"`: 0 when
// the line is there or appended, 1 when the append failed.
function excludeLine(excl: string, line: string): number {
  if (stage(["grep", "-qxF", line, argvOf(excl)], "inherit", "ignore", "ignore").status === 0) return 0;
  try {
    appendFileSync(latBuf(excl), Buffer.from(`${line}\n`, "utf8"));
    return 0;
  } catch {
    return 1;
  }
}

// ac_seed_exclude's twin: `/<rel>` in the repo's info/exclude (git's absolute
// --git-path - a linked worktree's lands in its main repo); 0 when git names
// no exclude file, else excludeLine's answer.
function seedExclude(wt: string, rel: string): number {
  const excl = gitExclude(wt);
  return excl === null ? 0 : excludeLine(excl, `/${rel}`);
}

// ac_seed_disposable's twin: `$(head -n 1 <file>)` opens with ac-verify's
// neutralized mark.
function seedDisposable(file: string): boolean {
  return capturedText(stage(["head", "-n", "1", file], "inherit", "pipe", "ignore").out).startsWith("# Neutralized by ac-verify:");
}

// ac_seed_install's twin, errexit asleep as every caller ran it: <staged>
// installed as <wt>/<rel> when the seed owns that path - nothing there,
// ac-verify's neutralized stub, or a file still hashing to its stamp
// (.claude/.ac-seed/<rel, / as %>.sha256; a suffix-less legacy stamp migrated
// when it verifies, removed either way) - then the stamp rewritten and both
// exclude lines ensured. The answer is the bash's status: 0 when <rel> holds
// the staged bytes already, 1 for a path someone else owns (left as it is) or
// a hash that could not be taken, else the second exclude line's - 1 when the
// exclude file could not take it, though the file was installed (kept). The
// hash is in process; cat, mkdir -p and rm -f are spawned.
function seedInstall(wt: string, rel: string, staged: string): number {
  const dst = `${wt}/${rel}`;
  const legacy = `${wt}/${SEED_STAMPS}/${rel.replaceAll("/", "%")}`;
  const stamp = `${legacy}.sha256`;
  const want = shaSoft(staged);
  if (want === "") return 1;
  const catText = (f: string): string => capturedText(stage(["cat", f], "inherit", "pipe", "inherit").out);
  if (existsSync(dst) && !seedDisposable(dst)) {
    let have: string;
    if (isFile(stamp)) {
      have = shaSoft(dst);
      if (have === "" || have !== catText(stamp)) return 1;
    } else if (isFile(legacy)) {
      have = shaSoft(dst);
      if (have === "") return 1;
      if (have !== catText(legacy)) {
        rmF(legacy);
        return 1;
      }
      try {
        writeFileSync(stamp, `${have}\n`);
      } catch {}
      rmF(legacy);
    } else return 1;
    if (have === want) return 0;
  }
  stage(["mkdir", "-p", dirname(dst), `${wt}/${SEED_STAMPS}`], "inherit", "inherit", "inherit");
  catInto(staged, dst);
  try {
    writeFileSync(stamp, `${want}\n`);
  } catch {}
  rmF(legacy);
  seedExclude(wt, rel);
  return seedExclude(wt, `${SEED_STAMPS}/`);
}

// ac_seed_crewmate_md's twin as `$(...)` ran it (errexit asleep), paths
// decoded: the layers there are - <container>/.claude/CLAUDE.md,
// CREWMATE-learned.md, CREWMATE.md, crewdomains/<domainBinding>/CREWMATE.md,
// in that order - composed once in a spawned `mktemp ${TMPDIR:-/tmp}/ac-seed.XXXXXX`
// (one layer as is; several each behind `<!-- agent-crew seed: <label>
// <path> -->`, a blank line between), installed at the harness's instruction
// file or, when someone else owns that, at .claude/CREWMATE.md - whose path is
// then the answer. "" otherwise: no layer, mktemp failed, or neither install
// took. An unknown harness is harnessInstructionFile's ERROR line and an
// install at the worktree itself, which never takes (kept).
export function seedCrewmateMd(wt: string, harness = ""): string {
  const fleet = `${softHome(true)}/CREWMATE.md`;
  const cont = `${dirname(softHome(true))}/.claude/CLAUDE.md`;
  const learned = `${softHome(true)}/CREWMATE-learned.md`;
  const bound = domainBinding();
  const dom = bound === "" ? "" : `${softHome(true)}/crewdomains/${bound}/CREWMATE.md`;
  const rel = harnessInstructionFile(harness) ?? "";
  const layers = (
    [
      [cont, "container"],
      [learned, "fleet-learned"],
      [fleet, "fleet"],
      [dom, "crewdomain"],
    ] as [string, string][]
  ).filter(([f]) => f !== "" && isFile(f));
  if (layers.length === 0) return "";
  const made = stage(["mktemp", `${process.env.TMPDIR || "/tmp"}/ac-seed.XXXXXX`], "inherit", "pipe", "inherit");
  if (made.status !== 0) return "";
  const staged = argvOf(capturedText(made.out));
  if (layers.length === 1) catInto(layers[0]![0], staged);
  else
    layers.forEach(([src, label], i) => {
      try {
        appendFileSync(staged, `${i === 0 ? "" : "\n"}<!-- agent-crew seed: ${label} ${src} -->\n`);
      } catch {}
      catInto(src, staged, true);
    });
  let out = "";
  if (seedInstall(wt, rel, staged) !== 0 && seedInstall(wt, SEED_FALLBACK, staged) === 0) out = SEED_FALLBACK;
  rmF(staged);
  return out;
}

// ac_seed_crew_settings' twin: settings.json and settings.local.json each from
// <home>/.claude/<file> - unless that dir is the chief's runtime dir: it
// resolves into the distro checkout (the runtime link), or its settings.json
// is a link into it (the real dir src/home-carriers.ts makes) - and never a
// settings.local.json carrying `"AC_HOME"`, the home's carrier, which would
// make the crewmate chief-shaped; else from <container>/.claude/<file>, a
// source that is no file skipped; each through seedInstall, its answer
// ignored.
export function seedCrewSettings(wt: string): void {
  let homeDir = `${softHome(true)}/.claude`;
  const root = STARTED_BIN.slice(0, -"/bin".length);
  if (isDir(homeDir)) {
    const p = physicalDir(homeDir) ?? "";
    if (p === root || p.startsWith(`${root}/`)) homeDir = "";
  }
  if (homeDir !== "") {
    try {
      if (lstatSync(`${homeDir}/settings.json`).isSymbolicLink() && readlinkSync(`${homeDir}/settings.json`).startsWith(`${root}/`)) homeDir = "";
    } catch {}
  }
  for (const rel of ["settings.json", "settings.local.json"]) {
    let src = `${homeDir}/${rel}`;
    if (homeDir === "" || !isFile(src) || (rel === "settings.local.json" && readFileSync(src, "latin1").includes('"AC_HOME"')))
      src = `${dirname(softHome(true))}/.claude/${rel}`;
    if (isFile(src)) seedInstall(wt, `.claude/${rel}`, src);
  }
}

// ac_meta_set under a caller's `2>/dev/null`: metaSet's lock and rewrite with
// its refusal silent; false when nothing was written. A failed rename's mv
// line is not silenced (named).
function metaSetQuiet(file: string, key: string, value: string): boolean {
  const cut = file.lastIndexOf("/");
  const dir = cut < 0 ? "." : file.slice(0, cut);
  const lock = `${dir}/.${file.slice(cut + 1)}.lock`;
  try {
    accessSync(dir, constants.W_OK | constants.X_OK);
    if (!lockAcquire(lock, 10, sleepOne)) return false;
  } catch {
    return false;
  }
  try {
    metaRewrite(file, () => [[key, value]]);
    return true;
  } catch {
    return false;
  } finally {
    lockRelease(lock);
  }
}

// ac_skill_usage_bump's twin, silent: <dir>/.usage.meta's seeded_count + 1 (a
// count that is not digits reads 0, `$(( ))` reads a leading 0 as octal) and
// last_seeded = ac_now, a refused write ending the bump. A count the
// arithmetic refuses (a leading 0, then an 8 or 9) ENDED bash 3.2 itself,
// status 1, whatever guarded the call: false here.
function skillUsageBump(dir: string): boolean {
  if (dir === "" || !isDir(dir)) return true;
  const meta = `${dir}/.usage.meta`;
  let cur = "";
  try {
    accessSync(meta, constants.R_OK);
    cur = metaGet(meta, "seeded_count");
  } catch {}
  let next: bigint;
  try {
    next = BigInt.asIntN(64, arithValue(/^[0-9]+$/.test(cur) ? cur : "0") + 1n);
  } catch {
    return false;
  }
  if (metaSetQuiet(meta, "seeded_count", String(next))) metaSetQuiet(meta, "last_seeded", nowRaw());
  return true;
}

// The non-dot entries of <dir> as `"$dir"/*` lists them, in byte order (the
// glob collated under UTF-8 - named, the ORDER rule).
function globEntries(dir: string): string[] {
  let names: string[] = [];
  try {
    names = readdirSync(dir);
  } catch {}
  return names
    .filter((n) => !n.startsWith("."))
    .sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map((n) => `${dir}/${n}`);
}

// ac_seed_crew_skills' twin as an errexit caller (ac-spawn.sh, ac-self-task.sh)
// ran it: symlinks in .claude/skills (.agents/skills for codex) - a dangling
// link there removed first, then each AC_CREW_SKILLS name (split on blanks,
// never globbed - named) from the worktree's own .claude/skills when the
// harness scans another dir (codex) and that is a real directory there, else
// <container>/.claude/skills else <ac_root>/.agents/skills, then each
// directory of skills/ but the archive
// (every NEW one bumping its .usage.meta). A name a link or file already
// claims is skipped, except a LINK of a built-in whose target is no longer the
// selected source - relinked, since the pool reuses slots, unless git tracks
// that link at its physical path (the project shipped it); every link the seed
// owns gets its info/exclude line under
// the skills dir's physical path inside the worktree (/<skrel> before it
// exists, none when it resolves outside). The answer is 0, or the status the
// caller ended with: a spawned rm -f, mkdir -p or ln -s that failed, an
// exclude line not appended (1), a usage count bash's arithmetic refused (1).
export function seedCrewSkills(wt: string, harness = ""): number {
  const skrel = harness === "codex" ? ".agents/skills" : ".claude/skills";
  const skdir = `${wt}/${skrel}`;
  const excl = gitExclude(wt) ?? "";
  let pfx = `/${skrel}`;
  if (isDir(skdir)) {
    pfx = "";
    const root = physicalDir(wt) ?? "";
    const sk = physicalDir(skdir) ?? "";
    if (root !== "" && sk.startsWith(`${root}/`)) pfx = `/${sk.slice(root.length + 1)}`;
    for (const dst of globEntries(skdir)) {
      if (!isLink(dst) || existsSync(dst)) continue;
      const s = rmF(dst);
      if (s !== 0) return s;
    }
  }
  // One name: linked when nothing is there yet, then its exclude line.
  const seed = (src: string, name: string, bump: boolean): number => {
    const dst = `${skdir}/${name}`;
    if (!existsSync(dst) && !isLink(dst)) {
      for (const cmd of [["mkdir", "-p", skdir], ["ln", "-s", src, dst]]) {
        const s = stage(cmd, "inherit", "inherit", "inherit").status;
        if (s !== 0) return s;
      }
      if (bump && !skillUsageBump(src)) return 1;
    }
    return isLink(dst) && excl !== "" && pfx !== "" ? excludeLine(excl, `${pfx}/${name}`) : 0;
  };
  for (const name of (process.env.AC_CREW_SKILLS || "crew-ship crew-verify crew-qa domain-e2e document sdlc").split(/[ \t\n]+/)) {
    if (name === "") continue;
    // A repo-shipped skill is the SOURCE when the harness scans a different
    // dir than .claude/skills: the project's override must reach the harness
    // that never looks where the project put it.
    let src = `${wt}/.claude/skills/${name}`;
    if (!(skrel !== ".claude/skills" && isDir(src) && !isLink(src))) {
      src = `${dirname(softHome(true))}/.claude/skills/${name}`;
      if (!isDir(src)) src = `${STARTED_BIN.slice(0, -"/bin".length)}/.agents/skills/${name}`;
    }
    if (!isDir(src)) continue;
    // A link the seed owns follows the source precedence on EVERY seed: the
    // pool reuses worktrees, so a slot seeded before the project shipped (or
    // the container gained) the skill would otherwise keep the older source.
    // A real directory there is the project's own and is never touched, and
    // so is a link git tracks (the project shipped it) - ownership is git's
    // answer at the link's physical path, since a tracked skills dir may
    // itself be a link.
    const dst = `${skdir}/${name}`;
    const tracked = (): boolean => pfx !== "" && stage(["git", "-C", wt, "ls-files", "--error-unmatch", "--", `${pfx.slice(1)}/${name}`], "inherit", "ignore", "ignore").status === 0;
    if (isLink(dst) && readlinkSync(dst) !== src && !tracked()) {
      const r = rmF(dst);
      if (r !== 0) return r;
    }
    const s = seed(src, name, false);
    if (s !== 0) return s;
  }
  for (const src of globEntries(softSubdir("skills", true))) {
    const name = basename(src);
    if (!isDir(src) || name === SKILLS_ARCHIVE) continue;
    const s = seed(src, name, true);
    if (s !== 0) return s;
  }
  return 0;
}

// ac_port_slot_allocate's twin as `$(...)` ran it: under the registry lock (10
// PATH `sleep 1` waits) the rows whose worktree is no directory dropped by the
// bash's own awk (spawned, its `system("test -d ...")` and all) into an
// EXCLUSIVE <reg>.tmp.<pid> (named) that a spawned mv renames over the
// registry, then <wt>'s slot: its row's first field, else the lowest integer
// awk finds no row for, appended with ac_iso. null, nothing written, for a
// lock not taken - homeless too: the refusal printed, `/port-slots.tsv.lock`
// waited on, as ac_port_registry's printf went on with the empty state dir.
function portSlotAllocate(wt: string, proj: string): string | null {
  const reg = `${softSubdir("state", true)}/port-slots.tsv`;
  const lock = `${reg}.lock`;
  let held = false;
  try {
    held = lockAcquire(lock, 10, sleepOne);
  } catch {}
  if (!held) return null;
  try {
    if (!isFile(reg))
      try {
        writeFileSync(reg, "");
      } catch {}
    try {
      const t = exclusiveTemp(`${reg}.tmp`);
      let r: ReturnType<typeof Bun.spawnSync> | null = null;
      try {
        r = spawnShellSync(["awk", "-F\\t", '{ if ($2 != "" && system("test -d \\"" $2 "\\"") == 0) print }', reg], { stdin: "inherit", stdout: t.fd, stderr: "ignore" });
      } catch {}
      if (shellStatus(r) !== 0) ftruncateSync(t.fd, 0);
      closeSync(t.fd);
      stage(["mv", t.path, reg], "inherit", "inherit", "inherit");
    } catch {}
    let taken = capturedText(stage(["awk", "-F\\t", "-v", `w=${wt}`, "$2 == w { print $1; exit }", reg], "inherit", "pipe", "inherit").out);
    if (taken === "") {
      let slot = 1n;
      while (stage(["awk", "-F\\t", "-v", `s=${slot}`, "$1 == s { found = 1 } END { exit(found ? 0 : 1) }", reg], "inherit", "ignore", "inherit").status === 0) slot++;
      try {
        appendFileSync(reg, `${slot}\t${wt}\t${proj}\t${argvOf(iso())}\n`);
      } catch {}
      taken = String(slot);
    }
    return taken;
  } finally {
    lockRelease(lock);
  }
}

// ac_seed_ports_env's twin as `... >/dev/null || ac_warn` ran it:
// <wt>/.crew/ports.env for <wt>'s slot - AC_PORT_BASE (20000) + slot*100, a
// hundred ports, read by bash's arithmetic (arithValue THROWS where bash 3.2
// ended) - .crew/ excluded, and the range `<lo>-<hi>` as the answer; null for
// a worktree that is no directory or no slot. mkdir -p is spawned; a ports.env
// the shell could not write is skipped, as its redirect was.
export function seedPortsEnv(wt: string, proj = ""): string | null {
  if (!isDir(wt)) return null;
  const slot = portSlotAllocate(wt, proj);
  if (slot === null) return null;
  const lo = BigInt.asIntN(64, arithValue(process.env.AC_PORT_BASE || "20000") + arithValue(slot) * 100n);
  const hi = BigInt.asIntN(64, lo + 99n);
  stage(["mkdir", "-p", `${wt}/.crew`], "inherit", "inherit", "inherit");
  try {
    writeFileSync(
      `${wt}/.crew/ports.env`,
      latBuf(`# agent-crew port slot - one fleet-wide slot per leased worktree; every listener this worktree starts binds inside this range.\nAC_PORT_SLOT=${slot}\nAC_PORT_RANGE=${lo}-${hi}\nPORT=${lo}\n`),
    );
  } catch {}
  seedExclude(wt, ".crew/");
  return `${lo}-${hi}`;
}

// backend_dialog_answer's twin: the routed raw-pane answer for the pane the
// task's handle names.
export function backendDialogAnswer(id: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: dialogAnswerPane(b, argvOf(paneField(id, 1, io.stderr === "inherit")), io), exited: false };
}

// backend_agent_idle_pane's twin, routed per call over a raw pane id.
export function backendAgentIdlePane(pane: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  return b === null ? { status: 1, exited: true } : { status: agentIdlePane(b, pane, io), exited: false };
}

// backend_submit_verified's twin (id-keyed), routed per call: one Enter whose
// render must react - 0 accepted, 1 stranded, 2 unreadable, and on orca 3 a
// dialog owns the pane; orca re-presses (at most twice) while <text> still
// sits in its composer, herdr ignores <text>.
export function backendSubmitVerified(id: string, text: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  const top = io.stdin ?? "inherit";
  if (b === "herdr") return { status: submitVerified(id, top, io.stderr), exited: false };
  return { status: orcaSubmitVerified(argvOf(paneField(id, 1, io.stderr === "inherit")), text, top, io.stderr), exited: false };
}

// backend_send_key under `|| true`, routed per call: herdr focuses the
// handle's tab and presses whatever the focus answered (backendCall's
// send_key stops at a failed focus, as an errexit caller did).
function keyPress(id: string, key: string, io: SpawnIo): Ended {
  const b = backendRoute(io.stderr);
  if (b === null) return { status: 1, exited: true };
  const vio: VerbIo = { stdin: io.stdin, stdout: "ignore", stderr: io.stderr };
  if (b === "orca") return { status: orcaVerb("send_key", [id, key], vio, () => {}), exited: false };
  herdrVerb("focus", [id], vio, () => {});
  const keyName = keyNamed(key) ?? key.replace(/\n+$/, "");
  return { status: herdrCli(["pane", "send-keys", argvOf(paneField(id, 1, io.stderr === "inherit")), keyName], io.stdin ?? "inherit", "ignore").status, exited: false };
}

// backend_startup_dialogs' twin: the sequence over the id-keyed verbs - the
// task's handle answered, keyed and probed (the raw-pane sequence is
// backendStartupDialogsPane's).
export function backendStartupDialogs(id: string, harness: string, io: SpawnIo): Ended {
  const up = (h: string): Ended => {
    const r = backendCall("harness_up", [h], { stdin: io.stdin, stdout: "ignore", stderr: io.stderr });
    return { status: r.status, exited: r.exited };
  };
  return startupDialogs((h) => backendDialogAnswer(h, io), (h, k) => keyPress(h, k, io), up, id, harness);
}

// The lease install, shared by the crew spawn and the self task: the
// captain-owned commands.install of <repo>'s home yaml, run as `sh -c` in the
// fresh lease <wt> with AC_LEASE_PRIMARY=<repo> (so it can reuse the primary's
// caches), stdin closed, its output dropped, bounded by
// AC_LEASE_INSTALL_TIMEOUT (default 300 s) - past it the group is TERMed then
// KILLed, as herdrCli's ceiling does. "" when no command is declared; "ok"
// when it exits 0 and `git status --porcelain` is empty after it; else
// "failed", WARNed with the cause. The distro never refuses the lease and
// never restores what the command dirtied: a command that touches tracked
// files restores them itself.
export function leaseInstall(id: string, repo: string, wt: string): "" | "ok" | "failed" {
  const cf = projectConfigFile(repo, true);
  const cmd = cf === null ? "" : argvOf(yamlGet(cf, "commands.install", true).out.replace(/\n+$/, ""));
  if (cmd === "") return "";
  const t = process.env.AC_LEASE_INSTALL_TIMEOUT || "";
  const secs = /^[0-9]+$/.test(t) && Number(t) > 0 ? Number(t) : 300;
  let r: ReturnType<typeof Bun.spawnSync> | null = null;
  try {
    r = spawnShellSync(["/usr/bin/env", `AC_LEASE_PRIMARY=${repo}`, "sh", "-c", cmd], { cwd: wt, stdin: "ignore", stdout: "ignore", stderr: "ignore", detached: true, timeout: Math.min(secs * 1000, 2 ** 31 - 1) });
  } catch {}
  let cause = "";
  if (r?.exitedDueToTimeout) {
    for (const sig of ["SIGTERM", "SIGKILL"] as const)
      try {
        process.kill(-r.pid, sig);
      } catch {}
    cause = `timed out after ${secs}s`;
  } else if (shellStatus(r) !== 0) cause = `exit ${shellStatus(r)}`;
  else {
    const st = stage(["git", "-C", wt, "status", "--porcelain"], "ignore", "pipe", "ignore");
    const dirty = capturedText(st.out).split("\n").filter((l) => l !== "").map((l) => l.slice(3));
    if (st.status !== 0) cause = "its worktree state could not be read";
    else if (dirty.length > 0) cause = `it left the worktree dirty: ${dirty.join(", ")}`;
  }
  if (cause === "") return "ok";
  warn(latBuf(`commands.install failed for ${lat(id)} (${cause}) - the worktree's dependencies are not installed; install them before testing`));
  return "failed";
}
