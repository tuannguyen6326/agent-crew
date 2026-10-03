// rig.ts - the rig manifest and its drift check. The entry is bin/ac-rig.sh
// (a shim that starts this file through bin/ac-bun.sh); THIS header is the
// authoritative spec, and the bash original it replaced stays frozen at
// tests/fixtures/ac-rig.sh as the oracle the differential leg of
// tests/sh/ac-rig.test.sh holds this module to. The refusal and verdict texts
// below still say `the bin/ac-rig.sh header`: they are the original's bytes,
// and the entry's header points here.
//
// Usage: ac-rig.sh drift
//
// THE MANIFEST is records/rig.json, one JSON object per fleet home, written
// and maintained BY HAND. It is the DECLARED source for the entries below;
// `drift` compares it against the surfaces that hold that truth today and
// reports every divergence. Nothing else reads it - a manifest that decided
// behaviour would be a config file, and this is a record.
//
// JSON, not the records/*.md line grammar its neighbours use, for two reasons.
// jq is a hard dependency (bin/ac-bootstrap.sh has `need jq`, not `opt`), so
// parsing costs one `jq -r` and cannot drift; and the *.md grammars are
// hand-rolled sed that mis-parses free text - fed a value containing its own
// delimiter words, src/standing-jobs.ts's cadence/recreate parse returns the
// wrong cadence and the wrong action, silently. A manifest carrying paths and
// commands walks into that on day one. YAML was never a candidate: this distro
// has no yq, only ac_yaml_get (bin/ac-pipeline-lib.sh), which cannot read a
// list.
//
// GRAMMAR (this header is the authoritative spec):
//
//   {
//     "home":    { "name": "<fleet>", "path": "<absolute home path>" },
//     "wiring":  { "distro_checkout": "<absolute path>" },
//     "config":  { "knobs": [ {"name":"<knob>"}                       # present
//                           , {"name":"<knob>", "value":"<v>"}        # pinned
//                           , {"name":"<knob>", "state":"default"} ]  # absent
//                },
//     "standing_jobs": [ "<job id>", ... ]
//   }
//
// VERDICTS - three, never two. `OK` and `DRIFT` are the mechanical ones;
// `UNVERIFIABLE` is a first-class third answer for a fact no read-only command
// on this host can settle, and it is what keeps the manifest honest rather
// than confident. The vocabulary is not invented here: `ac-know.sh verify`
// already grades entries FRESH / SUSPECT / UNVERIFIABLE / MANUAL.
//
//   OK:           <class>/<id> - <what matched>
//   DRIFT:        <class>/<id> - declared <x>, reality <y>
//                   fix: <the exact command or edit>
//   UNVERIFIABLE: <class>/<id> - <why> - settle it with: <the act>
//   rig: <n> ok, <n> drift, <n> unverifiable
//
// EXIT: 0 clean (UNVERIFIABLE alone never fails), 1 any DRIFT, 2 usage or an
// unreadable manifest. FAIL DIRECTION, stated because the two errors are not
// symmetric: a FALSE OK is the unrecoverable one - it makes the verb
// decorative. So an absent, unparseable, wrong-shaped or wrong-home manifest
// REFUSES; it is never graded clean. This is the `validate` half of the
// distro's list/validate split (bin/ac-deputy.sh's `list` / `validate: the
// strict twin` header sections): a strict twin that exits non-zero, not a
// digest renderer that may never take session start down. No src/lib.ts twin
// decides this entry's status: the home is checked here, before any helper
// that would die 1 (envHome is no drop-in - it dies 1 on a set-but-unreadable
// home, which is refusal 1 below).
//
// DISPATCH on the first argument. `drift` with any further argument (an empty
// one included) is
//   ERROR: usage: ac-rig.sh drift                     stderr, exit 2
// before the home is touched; `-h` / `--help` print this header on stdout,
// exit 0; anything else, an empty or no argument, is
//   usage: ac-rig.sh drift                            stderr, exit 2
//
// REFUSALS, in check order, each `ERROR: <text>` on stderr and exit 2 with
// nothing graded (a partial report already on stdout stays):
//   1. AC_HOME is not set - name the fleet home whose records/rig.json to check
//      (AC_HOME unset or empty, or a path this process cannot enter)
//   2. no rig manifest at records/rig.json - the drift check has nothing to compare against (grammar: the bin/ac-rig.sh header)
//   3. records/rig.json does not parse as JSON - fix it; a manifest that cannot be read is never graded clean (grammar: the bin/ac-rig.sh header)
//   4. records/rig.json has the wrong shape - home, wiring and config are objects, config.knobs an array of objects, standing_jobs an array (grammar: the bin/ac-rig.sh header)
//   5. records/rig.json declares no home.path - the manifest must name the rig it describes
//   6. records/rig.json describes <declared> but AC_HOME is <home> - refusing to grade one rig against another
//   7. records/rig.json declares no home.name - the manifest must name the rig it describes
//   8. records/rig.json calls this fleet '<name>' but it is '<fleet>' - refusing to grade one rig against another
//   9. bin/ac-standing-jobs.sh --ids failed - the declared standing-job id set could not be read, and grading it as empty would report every declared job as drift
// <home> is the physical AC_HOME (`cd && pwd -P`); <fleet> its basename; a
// declared path binds when it canonicalizes to <home> (a `..` spelling, a
// symlink). Refusal 9 is raised mid-report, after the home, wiring and config
// lines.
//
// REPORT (stdout), in this order, then the tally line:
//   OK: home/<name> - manifest binds this home (<home>)
//   wiring, exactly one of
//     UNVERIFIABLE: wiring/distro_checkout - records/rig.json declares no wiring.distro_checkout, so there is nothing to compare the fleet's checkout against - settle it with: declare it in records/rig.json (grammar: the bin/ac-rig.sh header)
//     UNVERIFIABLE: wiring/distro_checkout - state/.ac-root is unseeded, and it is the only record of the tree this FLEET runs from (its one writer is ac_seed_root_pointer, called from bin/ac-remote.sh) - settle it with: run any bin/ac-remote.sh verb from the fleet's own checkout, then re-run this check
//                   (the pointer absent or empty)
//     DRIFT: wiring/distro_checkout - declared <d>, state/.ac-root says <a>
//       fix: correct records/rig.json, or repoint the checkout this fleet runs from
//                   (canon(<d>) != canon(<a>); <a> is the pointer's content with every trailing newline dropped)
//     DRIFT: wiring/distro_checkout - declared <d>, and the path is not a git repository
//       fix: restore the checkout at <a>, or correct records/rig.json
//                   (`git -C <a> rev-parse --git-dir` fails)
//     OK: wiring/distro_checkout - <a> (state/.ac-root)
//   config, direction A, one per knob in manifest order (an empty name skipped):
//     kind = pinned when the row HAS a `value` key (an empty value is a pin),
//     else default when `.state == "default"`, else present; f = <home>/config/<name>
//     default:  OK: config/<n> - declared absent - runs on the reader's default
//               DRIFT: config/<n> - declared absent (this fleet takes the reader's default), but config/<n> exists
//                 fix: remove <f>, or give the row a value in records/rig.json
//     no regular file at f (a directory counts as none):
//               DRIFT: config/<n> - declared present, but there is no config/<n>
//                 fix: create <f>, or declare the row "state": "default" in records/rig.json
//     pinned:   OK: config/<n> - pinned value '<v>'           (configRead, the first line trimmed, equals <v>)
//               DRIFT: config/<n> - declared '<v>', config/<n> reads '<a>'
//                 fix: printf '%s\n' '<v>' > <f>, or update records/rig.json
//     present:  OK: config/<n> - declared present
//   config, direction B, every regular file in <home>/config/ (byte order,
//   dotfiles and *.prev skipped) whose name is no declared `.name`:
//     DRIFT: config/<b> - present in config/, declared nowhere in records/rig.json
//       fix: add {"name": "<b>"} to records/rig.json, or remove <home>/config/<b>
//   standing jobs: the actual ids are `<bin>/ac-standing-jobs.sh --ids`
//   (stderr discarded), direction A per declared id in manifest order (an
//   empty id skipped), direction B per actual id in file order:
//     OK: standing_jobs/<id> - declared in records/standing-jobs.md
//     DRIFT: standing_jobs/<id> - declared in records/rig.json, absent from records/standing-jobs.md
//       fix: add the job line to records/standing-jobs.md, or drop the id from records/rig.json
//     DRIFT: standing_jobs/<id> - declared in records/standing-jobs.md, absent from records/rig.json
//       fix: add "<id>" to standing_jobs in records/rig.json
//   then, when at least one declared id holds a non-blank character:
//     UNVERIFIABLE: standing_jobs/liveness - <n> declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now - settle it with: CronList in the harness - no shell on this host can answer it
//   rig: <ok> ok, <drift> drift, <unver> unverifiable
//
// JQ: every read of the manifest is jq, spawned with the original's filters,
// so what the manifest means is jq's reading - a stream of values is
// accepted, a lone null or false fails `jq -e .` (refusal 3), `nan` parses,
// `//` reads false as absent - and a non-string name or value is spelled as
// `tostring` spells it: `7`, `1.0` kept, `1e2` as `1E+2`, `-0`, a big integer
// intact, `true`, `null` (a nameless knob is config/null), an object as
// compact JSON. The knob rows travel as name, kind, value joined by US (0x1f)
// and are read line by line as `read -r` read them, so a value holding a
// newline tears its row (not a contract). Pinned by the differential leg.
//
// BYTES AND ORDER: the pointer, the ids and jq's output are bytes written
// back as the same bytes; a pointer holding only newlines reads as "", and
// canon("") is the cwd, as `cd ""` was (physicalDir, pinned in
// tests/ts/rig.test.ts). The liveness count reads a blank as the C locale's
// [:space:] (ASCII). Direction B walks config/ in byte order, where bash's
// glob followed libc collation under a UTF-8 locale - named in the leg.
// `-h` prints this header where the original printed its own - the one
// deliberate non-identical leg.
//
// WHAT IS DELIBERATELY NOT DECLARED, so a reader does not add it back:
// - SERVICE LIVENESS (dashboard, remote poll, brain). Services start and stop
//   on demand - the dashboard daemon's pid file can outlive a crash until the
//   next start/stop reads it stale (bin/ac-dashboard.sh) - and the watcher
//   beacon is stood down to 0 on every normal exit (bin/ac-watch.sh
//   stand_down_beacon) - a declared expected liveness would be a false-drift
//   generator.
// - PROJECTS. records/projects.md is already its own single source; a copy
//   here would be a second one.
// - CREWDEPUTIES / CREWDOMAINS. Both already have a declared file plus a
//   strict checker (bin/ac-deputy.sh cmd_validate, bin/ac-domain.sh cmd_validate).
// - TOOLCHAIN BINARIES. bin/ac-bootstrap.sh's need/opt list is the source and
//   already gates.
//
// There is no verb that GENERATES the manifest from the live home: one
// regenerated from reality can never disagree with it, and generating the
// first one would silently bless whatever rot the home already carries.
import { existsSync, readdirSync, readFileSync, statSync, writeSync } from "node:fs";
import { basename, join } from "node:path";
import { configRead, enterCaller, physicalDir, recordsDir, stateDir } from "./lib.ts";

const bin = join(import.meta.dir, "..", "bin");
const US = "\x1f";
const b = (s: string): Buffer => Buffer.from(s, "latin1");
const bytes = (s: string): string => Buffer.from(s, "utf8").toString("latin1");
const native = (s: string): string => Buffer.from(s, "latin1").toString("utf8");
const isFile = (p: string): boolean => {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
};
const isDir = (p: string): boolean => {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
};

function refuse(msg: string): never {
  writeSync(2, b(`ERROR: ${msg}\n`));
  process.exit(2);
}

let ok = 0;
let drift = 0;
let unver = 0;
const sayOk = (id: string, what: string): void => {
  writeSync(1, b(`OK: ${id} - ${what}\n`));
  ok++;
};
const sayUnver = (id: string, why: string, act: string): void => {
  writeSync(1, b(`UNVERIFIABLE: ${id} - ${why} - settle it with: ${act}\n`));
  unver++;
};
const sayDrift = (id: string, what: string, fix: string): void => {
  writeSync(1, b(`DRIFT: ${id} - ${what}\n  fix: ${fix}\n`));
  drift++;
};

// jq's answer as bytes with every trailing newline dropped, as `$(...)`
// dropped them; null when jq failed.
function jq(args: string[], file: string): string | null {
  const r = Bun.spawnSync(["jq", ...args, file], { stdout: "pipe", stderr: "ignore" });
  if (r.exitCode !== 0) return null;
  return r.stdout.toString("latin1").replace(/\n+$/, "");
}

// The resolved path, or the literal when it does not exist: a declared path
// that is simply GONE must still print as declared, so the DRIFT line quotes
// both sides.
const canon = (p: string): string => {
  const d = physicalDir(native(p));
  return d === null ? p : bytes(d);
};

const SHAPE = `type == "object"
    and ([.home, .wiring, .config] | all(. == null or type == "object"))
    and ((.config.knobs // []) | type == "array" and all(.[]; type == "object"))
    and ((.standing_jobs // []) | type == "array")`;
// NOT @tsv: it escapes `\`, tab and newline, and the reader never un-escapes
// them - a knob whose value contains a backslash read as drift on a correct
// rig, and the `fix:` line then told the reader to write the ESCAPED bytes
// back. join emits the value raw. The row's KIND is decided here, by
// has("value"), not downstream by testing the value for emptiness: jq's `//`
// is falsy on `false` as well as null, and an intentionally pinned EMPTY value
// (config/gate-model is documented as "absent = the engine default") is a real
// declaration that an emptiness test silently downgrades to a presence-only
// check.
const ROWS = `.config.knobs // [] | .[]
                 | [ (.name | tostring)
                   , (if has("value") then "pinned"
                      elif (.state // "") == "default" then "default"
                      else "present" end)
                   , (if has("value") then (.value | tostring) else "" end) ]
                 | join("\\u001f")`;

function checkWiring(manifest: string): void {
  const declared = jq(["-r", ".wiring.distro_checkout // empty"], manifest) ?? "";
  // An absent key is NOT a pass. Returning silently meant a one-character typo
  // in the key name disabled this whole class with no line and no tally entry -
  // the false OK this verb's fail direction calls the unrecoverable error.
  if (declared === "") {
    sayUnver(
      "wiring/distro_checkout",
      "records/rig.json declares no wiring.distro_checkout, so there is nothing to compare the fleet's checkout against",
      "declare it in records/rig.json (grammar: the bin/ac-rig.sh header)",
    );
    return;
  }
  // state/.ac-root ONLY, deliberately no ac_root() fallback. ac_root() is the
  // checkout that owns the INVOKED bin/, so from a leased pool worktree it
  // answers that worktree - falling back to it would grade WHO RAN THE VERB
  // instead of the rig, and every crewmate invocation and the whole test suite
  // would read as drift. An unseeded pointer is a thing this host cannot
  // settle, which is exactly what the third verdict is for.
  const ptr = join(stateDir(), ".ac-root");
  let size = 0;
  try {
    size = statSync(ptr).size;
  } catch {}
  if (size === 0) {
    sayUnver(
      "wiring/distro_checkout",
      "state/.ac-root is unseeded, and it is the only record of the tree this FLEET runs from (its one writer is ac_seed_root_pointer, called from bin/ac-remote.sh)",
      "run any bin/ac-remote.sh verb from the fleet's own checkout, then re-run this check",
    );
    return;
  }
  let actual = "";
  try {
    actual = readFileSync(ptr, "latin1").replace(/\n+$/, "");
  } catch {}
  if (canon(declared) !== canon(actual)) {
    sayDrift("wiring/distro_checkout", `declared ${declared}, state/.ac-root says ${actual}`, "correct records/rig.json, or repoint the checkout this fleet runs from");
    return;
  }
  const g = Bun.spawnSync(["git", "-C", native(actual), "rev-parse", "--git-dir"], { stdout: "ignore", stderr: "ignore" });
  if (g.exitCode !== 0) {
    sayDrift("wiring/distro_checkout", `declared ${declared}, and the path is not a git repository`, `restore the checkout at ${actual}, or correct records/rig.json`);
    return;
  }
  sayOk("wiring/distro_checkout", `${actual} (state/.ac-root)`);
}

function checkConfig(manifest: string, home: string): void {
  const homeB = bytes(home);
  const rows = jq(["-r", ROWS], manifest) ?? "";
  const declaredNames = (jq(["-r", ".config.knobs // [] | .[] | .name"], manifest) ?? "").split("\n");

  // Direction A - every declared knob is what the manifest says it is.
  for (const row of rows.split("\n")) {
    const fields = row.split(US);
    const name = fields[0] ?? "";
    const kind = fields[1] ?? "";
    const value = fields.slice(2).join(US);
    if (name === "") continue;
    const f = `${home}/config/${native(name)}`;
    const fB = `${homeB}/config/${name}`;
    if (kind === "default") {
      if (existsSync(f)) {
        sayDrift(`config/${name}`, `declared absent (this fleet takes the reader's default), but config/${name} exists`, `remove ${fB}, or give the row a value in records/rig.json`);
      } else {
        sayOk(`config/${name}`, "declared absent - runs on the reader's default");
      }
      continue;
    }
    if (!isFile(f)) {
      sayDrift(`config/${name}`, `declared present, but there is no config/${name}`, `create ${fB}, or declare the row "state": "default" in records/rig.json`);
      continue;
    }
    if (kind === "pinned") {
      // configRead, never a byte compare: it trims whitespace and CR, so raw
      // bytes would report drift on a CRLF no reader in the fleet can see.
      const actual = bytes(configRead(native(name), ""));
      if (actual !== value) {
        sayDrift(`config/${name}`, `declared '${value}', config/${name} reads '${actual}'`, `printf '%s\\n' '${value}' > ${fB}, or update records/rig.json`);
      } else {
        sayOk(`config/${name}`, `pinned value '${value}'`);
      }
      continue;
    }
    sayOk(`config/${name}`, "declared present");
  }

  // Direction B - CLOSURE. Without it the manifest is a partial list that can
  // never notice what appeared beside it, which is how config/ grew three
  // retired herdr-workspace* knobs nothing reads.
  let entries: string[] = [];
  try {
    entries = readdirSync(join(home, "config"));
  } catch {}
  // Structural entries, not knobs: a directory, a dotted receipt log, and the
  // *.prev captain-veto sidecar (delivery-review skill). Reporting these would
  // train the reader to ignore the verb.
  for (const base of entries.map(bytes).sort()) {
    const entry = `${home}/config/${native(base)}`;
    if (base.startsWith(".") || base.endsWith(".prev")) continue;
    if (!existsSync(entry) || isDir(entry)) continue;
    if (declaredNames.includes(base)) continue;
    sayDrift(`config/${base}`, "present in config/, declared nowhere in records/rig.json", `add {"name": "${base}"} to records/rig.json, or remove ${homeB}/config/${base}`);
  }
}

function checkStandingJobs(manifest: string): void {
  const declared = (jq(["-r", ".standing_jobs // [] | .[]"], manifest) ?? "").split("\n");
  // The id list comes from the file that OWNS the grammar, never re-parsed
  // here: bin/ac-standing-jobs.sh --ids. One grammar, one parser (AGENTS.md
  // sections 2 and 13), the shape bin/ac-pool-health.sh already uses against
  // ac-tree.sh list. The child's failure is a refusal, never swallowed: an
  // empty id set is indistinguishable from "no jobs declared", so grading it
  // reported every declared job as drift with a fix naming a line already
  // sitting in the file. A verb that is fail-closed about its own manifest has
  // to be fail-closed about its inputs too.
  const r = Bun.spawnSync([join(bin, "ac-standing-jobs.sh"), "--ids"], { stdout: "pipe", stderr: "ignore" });
  if (r.exitCode !== 0)
    refuse("bin/ac-standing-jobs.sh --ids failed - the declared standing-job id set could not be read, and grading it as empty would report every declared job as drift");
  const actual = r.stdout.toString("latin1").replace(/\n+$/, "").split("\n");

  for (const id of declared) {
    if (id === "") continue;
    if (actual.includes(id)) sayOk(`standing_jobs/${id}`, "declared in records/standing-jobs.md");
    else
      sayDrift(`standing_jobs/${id}`, "declared in records/rig.json, absent from records/standing-jobs.md", "add the job line to records/standing-jobs.md, or drop the id from records/rig.json");
  }
  for (const id of actual) {
    if (id === "" || declared.includes(id)) continue;
    sayDrift(`standing_jobs/${id}`, "declared in records/standing-jobs.md, absent from records/rig.json", `add "${id}" to standing_jobs in records/rig.json`);
  }

  // LIVENESS, the half no read-only command settles. CronCreate is
  // session-only: the job lives in harness session memory, is never written
  // to disk, and dies with the session (src/standing-jobs.ts's header, which
  // refuses to claim PRESENT/MISSING for the same reason). Every on-disk
  // footprint was checked and none attributes a run to a job - the github
  // store is a de-dup key that writes nothing when a poll finds nothing new,
  // .brain-last-sync has three writers, and the monitor leaves no trace at
  // all. So this says unknown, and names the one act that would answer.
  const n = declared.filter((id) => /[^ \t\n\v\f\r]/.test(id)).length;
  if (n === 0) return;
  sayUnver(
    "standing_jobs/liveness",
    `${n} declared job(s); CronCreate is session-only, so no on-disk signal says whether any of them is scheduled right now`,
    "CronList in the harness - no shell on this host can answer it",
  );
}

function cmdDrift(): number {
  // The home is checked HERE, with refusal 1 and exit 2: every lib twin dies
  // 1, which is this verb's DRIFT code, so a caller branching on the status
  // would read a missing AC_HOME as one drifted entry.
  const h = process.env.AC_HOME;
  const home = h ? physicalDir(h) : null;
  if (home === null) refuse("AC_HOME is not set - name the fleet home whose records/rig.json to check");
  const homeB = bytes(home);
  const manifest = join(recordsDir(), "rig.json");

  if (!isFile(manifest)) refuse("no rig manifest at records/rig.json - the drift check has nothing to compare against (grammar: the bin/ac-rig.sh header)");
  if (jq(["-e", "."], manifest) === null)
    refuse("records/rig.json does not parse as JSON - fix it; a manifest that cannot be read is never graded clean (grammar: the bin/ac-rig.sh header)");
  // Every container a check indexes, typed up front: a jq that cannot index
  // its input would otherwise end the report mid-way.
  if (jq(["-e", SHAPE], manifest) === null)
    refuse("records/rig.json has the wrong shape - home, wiring and config are objects, config.knobs an array of objects, standing_jobs an array (grammar: the bin/ac-rig.sh header)");

  // HOME BINDING FIRST, and it refuses rather than measuring. ac-home-seed.sh
  // copies a parent's config into a crewdeputy home, so a manifest can
  // physically arrive in the wrong one - and grading drydock's manifest
  // against another home's reality would print a wall of drift that is really
  // one mistake.
  const declaredHome = jq(["-r", ".home.path // empty"], manifest) ?? "";
  if (declaredHome === "") refuse("records/rig.json declares no home.path - the manifest must name the rig it describes");
  if (canon(declaredHome) !== canon(homeB)) refuse(`records/rig.json describes ${declaredHome} but AC_HOME is ${homeB} - refusing to grade one rig against another`);
  // The NAME is checked too, not merely echoed into the OK line. A field the
  // manifest declares and nothing compares is the seed of exactly the drift
  // this file exists to catch - and a manifest copied by ac-home-seed.sh into
  // another home, then path-corrected, keeps the old name.
  const declaredName = jq(["-r", ".home.name // empty"], manifest) ?? "";
  const fleet = bytes(basename(home));
  if (declaredName === "") refuse("records/rig.json declares no home.name - the manifest must name the rig it describes");
  if (declaredName !== fleet) refuse(`records/rig.json calls this fleet '${declaredName}' but it is '${fleet}' - refusing to grade one rig against another`);
  sayOk(`home/${declaredName}`, `manifest binds this home (${homeB})`);

  checkWiring(manifest);
  checkConfig(manifest, home);
  checkStandingJobs(manifest);

  writeSync(1, b(`rig: ${ok} ok, ${drift} drift, ${unver} unverifiable\n`));
  return drift === 0 ? 0 : 1;
}

function header(): never {
  const head: string[] = [];
  for (const l of readFileSync(import.meta.path, "utf8").split("\n")) {
    if (!l.startsWith("//")) break;
    head.push(l.replace(/^\/\/ ?/, ""));
  }
  writeSync(1, `${head.join("\n")}\n`);
  process.exit(0);
}

const { args } = enterCaller(process.argv.slice(2));
switch (args[0]) {
  case "drift":
    if (args.length > 1) refuse("usage: ac-rig.sh drift");
    process.exit(cmdDrift());
  case "-h":
  case "--help":
    header();
  default:
    writeSync(2, "usage: ac-rig.sh drift\n");
    process.exit(2);
}
