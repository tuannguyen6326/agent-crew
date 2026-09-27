// dispatch-select.ts - resolve a crew-dispatch profile for ac-spawn. The
// entry is bin/ac-dispatch-select.sh (a shim that execs this file); THIS
// header is the authoritative spec. The shim starts bun in the distro root
// with no BUN_*/JSC_* environment and no .env, and passes the caller's
// physical cwd as the first argument ("" when it has no name); the module
// returns there before reading any relative input (AC_HOME, a --propose
// brief) - or refuses such an input when it cannot - so nothing in a caller's
// cwd or environment configures bun itself.
//
// config/crew-dispatch.json (see docs/examples/crew-dispatch.json) maps
// natural-language `when` clauses to harness profiles. MATCHING a rule is the
// orchestrator's judgment call (the clauses are prose); this script owns the
// deterministic part: listing the rules and resolving one into spawn flags.
//
// Usage:
//   ac-dispatch-select.sh --list          # <n><TAB><when><TAB><profile summary>
//   ac-dispatch-select.sh [--rule <n>]    # resolve rule n (1-based);
//                                         # no --rule = the config's default
//   ac-dispatch-select.sh --pane <kind>   # resolve .panes[<kind>] by KEY
//   ac-dispatch-select.sh --pane <kind> --lanes   # one line per lane, in order
//   ac-dispatch-select.sh --pane <qa|gate|codereview|roomchief> --list
//   ac-dispatch-select.sh --pane <qa|gate|codereview|roomchief> --rule <number|default>
//   ac-dispatch-select.sh --pane qa --receipt <number|default>
//   ac-dispatch-select.sh --propose <brief-file>   # `propose: rule=<n> p=<p> state_sha=<sha>`
//
// --propose is the ONE place prose is judged by a MODEL, and it judges
// nothing: it asks bin/ac-jev.sh (config/jev - off by default, then shadow,
// then on) one choice question whose options are the rule numbers and whose
// criteria are the `when` clauses verbatim, with the brief as the state, and
// prints one `propose:` line only under `on`. The orchestrator still reads
// --list and passes --rule itself; a proposal is a hint beside the list,
// never a resolution, so the dispatcher's own contract (below) stands: it
// never evaluates prose. `state_sha` is the key `ac-jev.sh label` takes to
// record the rule the orchestrator actually chose.
//
// --pane without a trailing operation is the JUDGMENT-FREE half of this
// resolver: a caller with no selector to offer. Four kinds may be ROUTED
// (`rules` + `default`, the same shape a top-level rule's `use` takes) and
// support --list/--rule: qa, gate, codereview, roomchief. They differ in ONE
// way - whether `default` is MANDATORY:
//   - qa: `default` stays OPTIONAL, and a routed lookup with no --rule prints
//     NOTHING (exit 0) rather than resolve one - the execution caller reads
//     --list, judges the prose `when` clauses, and passes exactly one --rule
//     selector; caller judgment only, never pane judgment.
//   - gate, codereview, roomchief: `default` is MANDATORY once routed
//     (validation REFUSES a routed panes.<kind> with none), so a lookup with
//     no --rule resolves it deterministically instead of dying or going
//     absent - this is what a mechanism with no agent in the loop to judge a
//     `when` clause needs (e.g. the --system-initiated roomchief promote
//     ac-learn.sh makes, which passes no --harness and no selector). A
//     caller that DOES have an agent in the loop (ac-gate.sh's owning
//     roomchief; the execution crewmate via ac-verify codereview) may still
//     pass its own --rule to choose deliberately.
// Any other kind (a flat profile, or a kind outside this set of four) never
// takes an operation: only `--pane <kind>` with no trailing flag is valid.
// The dispatcher never evaluates prose, falls through, or combines fields from
// different rules. --receipt returns the same selection as durable JSON and is
// QA-ONLY (its frozen routing receipt has no consumer for the other kinds);
// `use` remains one atomic harness/model/effort object.
// ABSENT is not an error and must stay distinguishable from one: no config
// file, no `panes` block, or no entry for that kind all print NOTHING and exit
// 0 - that is the fall-through to the pane agent's own ladder, i.e. the
// behaviour of a fleet that configured nothing. An entry that EXISTS and names
// no harness (flat), or a routed entry that fails its schema (non-empty
// when/why, atomic use, and - for the three mandatory-default kinds - a valid
// `default`), dies rather than falling back: a misconfigured profile is not an
// absent one, and ignoring it would launch something other than what it says.
//
// THE THIRD PANE SHAPE - `lanes` (--lanes). A flat entry IS one profile and a
// routed entry PICKS one by judgment; a `lanes` entry says run EVERY profile it
// lists, in the order written, and --lanes prints one output line per lane. It
// is a separate key rather than the top level's `use[]` list form because that
// form means the OPPOSITE - round-robin, one profile per spawn - and a caller
// confusing them would run one reviewer where it asked for three. The two forms
// never meet: a lanes entry mixed with static or routed keys is refused, asking
// a lanes entry for a single profile is refused, and asking --lanes of a
// non-lanes entry is refused. Two lanes on the same harness AND model are
// refused by name: that is one perspective paid for twice. ABSENT keeps its
// meaning - a kind with no entry prints nothing and exits 0, so deleting the
// entry is how the caller's fan-out is switched off.
//
// Output: one line per profile, three TAB-separated fields -
// `harness=<h><TAB>model=<m><TAB>effort=<e>` (model/effort may be empty). TAB,
// not space, because a MODEL NAME MAY CONTAIN SPACES: some harnesses put the
// reasoning tier inside the name instead of on an --effort axis, and on a
// space-separated wire every caller's three-field read truncated such a name at
// its first word and launched a different model than the fleet declared. Each
// reader splits on TAB (`IFS=$'\t' read -r h m e`).
// A rule whose `use` is a LIST alternates round-robin between its profiles
// (persisted in state/.dispatch-rr-<n>, a decimal counter; anything else in it
// reads as 0); `select: quota-balanced` maps onto
// this until a quota source exists. Without a config file the fallback is
// config/crew-harness (default claude).
// Every refusal - and every unreadable or unwritable file - is `ERROR: <why>`
// on stderr with exit 1. The config is strict RFC 8259 JSON in UTF-8 (one
// leading BOM allowed). A blank file or a bare null is NO document: the default
// falls back and --rule finds no rule, while --list, --pane and --propose refuse
// it as invalid JSON; any other non-object document is refused in every mode,
// and so is a rule/pane selector that is not a decimal positive number.
//
// JQ SEMANTICS. This file replaced a jq program, and the wire kept jq's
// meaning where it differs from plain JS: `//` treats false like null (alt), an
// empty string is TRUE in a jq `if`, string interpolation renders a non-string
// as compact JSON (jqText) while raw output pretty-prints it (jqRaw), a
// negative index counts from the end (rrPick), blank means Oniguruma's \s
// (JQ_SPACE), duplicates sort by code point, JSON output escapes DEL, and a
// printed field is what $(...) captured (capture). One jq behavior is
// deliberately NOT kept: jq reprinted a number's literal text (`p=0.9000`),
// JSON.parse keeps only its value (`p=0.9`).

import { createHash } from "node:crypto";
import { constants } from "node:os";
import { existsSync, readFileSync, statSync, writeFileSync, writeSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { configRead, die, envHome, stateDir } from "./lib.ts";

type Json = any;

export class Refusal extends Error {}
const refuse = (msg: string): never => {
  throw new Refusal(msg);
};

export const alt = (v: Json, d: Json): Json => (v === null || v === false || v === undefined ? d : v);
const isObj = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
const has = (v: Json, k: string) => isObj(v) && Object.prototype.hasOwnProperty.call(v, k);
// Oniguruma's \s (jq's regex engine) is exactly Unicode White_Space: JS's \s
// plus U+0085, minus U+FEFF.
const JQ_SPACE = /^\p{White_Space}*$/u;
const nonBlank = (v: Json) => typeof v === "string" && !JQ_SPACE.test(v);
const optStr = (v: Json) => typeof alt(v, "") === "string";

const compact = (v: Json) => JSON.stringify(v ?? null).replace(/\u007f/g, "\\u007f");
export const jqText = (v: Json): string => (typeof v === "string" ? v : compact(v));
const jqRaw = (v: Json): string =>
  typeof v === "string" ? v : JSON.stringify(v ?? null, null, 2).replace(/\u007f/g, "\\u007f");
const byCodePoint = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const jqType = (v: Json) => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v);

// jq's `.k`: null in, null out; any other non-object is a hard error, so a
// misshapen config fails closed exactly where jq used to abort.
function field(v: Json, k: string): Json {
  if (v === null || v === undefined) return null;
  if (!isObj(v)) refuse(`Cannot index ${jqType(v)} with "${k}"`);
  return has(v, k) ? v[k] : null;
}

function nth(v: Json, i: number): Json {
  if (v === null || v === undefined) return null;
  if (!Array.isArray(v)) refuse(`Cannot index ${jqType(v)} with number`);
  return v[i < 0 ? v.length + i : i] ?? null;
}

const suffix = (v: Json) => (alt(v, "") !== "" ? " " + jqText(v) : "");

// What the shell's $(jq -r ...) captured: NUL bytes and trailing newlines
// dropped - so a newline- or NUL-only harness is no harness, and a value ending
// in a newline adds no line to the TAB wire.
const capture = (s: string) => s.replace(/\u0000/g, "").replace(/\n+$/, "");
const captured = (v: Json) => capture(jqRaw(alt(v, "")));

export function profileLine(p: Json): string {
  const h = isObj(p) ? captured(p.harness) : "";
  if (h === "") refuse(`dispatch profile has no harness: ${compact(p)}`);
  return `harness=${h}\tmodel=${captured(p.model)}\teffort=${captured(p.effort)}`;
}

function entries(v: Json): Json[] {
  if (!Array.isArray(v)) refuse(`${jqType(v)} rules cannot be listed`);
  return v;
}

export function ruleListLines(cfg: Json): string[] {
  return entries(alt(field(cfg, "rules"), [])).map((r, i) => {
    const use = field(r, "use");
    const summary = Array.isArray(use)
      ? use.map((u) => { const h = field(u, "harness"); return h === null ? "" : jqText(h); }).join("/") + " (balanced)"
      : jqText(alt(field(use, "harness"), "?"))
        + (alt(field(use, "model"), null) !== null ? " " + jqText(use.model) : "")
        + (alt(field(use, "effort"), null) !== null ? " " + jqText(use.effort) : "");
    return `${i + 1}\t${jqText(field(r, "when"))}\t${summary}`;
  });
}

export function paneListLines(pane: Json): string[] {
  const rows = entries(field(pane, "rules")).map((r, i) =>
    `${i + 1}\t${jqText(r.when)}\t${jqText(r.use.harness)}${suffix(r.use.model)}${suffix(r.use.effort)}\t${jqText(r.why)}`);
  if (has(pane, "default")) {
    const d = pane.default;
    rows.push(`default\t\t${jqText(d.harness)}${suffix(d.model)}${suffix(d.effort)}\t`);
  }
  return rows;
}

const validProfile = (p: Json) => isObj(p) && nonBlank(p.harness) && optStr(p.model) && optStr(p.effort);
const validRules = (rs: Json) =>
  Array.isArray(rs) && rs.length > 0
  && rs.every((r) => isObj(r) && nonBlank(r.when) && validProfile(r.use) && nonBlank(r.why));
const hasStaticKeys = (p: Json) => has(p, "harness") || has(p, "model") || has(p, "effort");

export function validQaPane(q: Json): boolean {
  if (!isObj(q)) return false;
  if (has(q, "rules"))
    return !hasStaticKeys(q) && validRules(q.rules) && (!has(q, "default") || validProfile(q.default));
  return validProfile(q) && !has(q, "default");
}

export function validRoutedPane(p: Json): boolean {
  return isObj(p) && !hasStaticKeys(p) && validRules(p.rules) && has(p, "default") && validProfile(p.default);
}

export function duplicateLane(lanes: Json[]): string {
  const groups = new Map<string, { h: Json; m: Json }[]>();
  for (const l of lanes) {
    const e = { h: field(l, "harness"), m: alt(field(l, "model"), "") };
    const key = `${jqText(e.h)}\u0000${jqText(e.m)}`;
    groups.set(key, [...(groups.get(key) ?? []), e]);
  }
  const dup = [...groups.keys()].sort(byCodePoint).map((k) => groups.get(k)!).find((g) => g.length > 1);
  if (!dup) return "";
  const { h, m } = dup[0];
  return capture(jqText(h) + (m === "" ? "" : " model " + jqText(m)));
}

export const rrPick = (use: Json[], count: number): Json => nth(use, count % use.length);

// Bash arithmetic skipped only blanks and newlines around the counter.
export function counterValue(text: string): number {
  const t = text.replace(/^[ \t\n]+|[ \t\n]+$/g, "");
  return /^-?[0-9]+$/.test(t) ? Number(t) : 0;
}

export const childStatus = (p: { exitCode: number | null; signalCode?: string | null }): number =>
  p.signalCode ? 128 + (constants.signals[p.signalCode as keyof typeof constants.signals] ?? 0) : (p.exitCode ?? 1);

// Leading zeros read as decimal: the shell read them as OCTAL (010 -> rule 8)
// or refused them outright, and neither is what a caller typing 010 means.
function positive(sel: string): number | null {
  return /^[0-9]+$/.test(sel) && Number(sel) > 0 ? Number(sel) : null;
}

const receiptUse = (u: Json) => ({ harness: u.harness, model: alt(u.model, ""), effort: alt(u.effort, "") });

export function qaReceipt(cfg: Json, sel: string, sha: string): string {
  const qa = cfg.panes.qa;
  if (sel === "default")
    return compact({ kind: "qa", rule: "default", use: receiptUse(qa.default), dispatch_sha256: sha });
  const n = Number(sel);
  const r = qa.rules[n - 1];
  return compact({ kind: "qa", rule: n, when: r.when, use: receiptUse(r.use), why: r.why, dispatch_sha256: sha });
}

const say = (line: string) => writeSync(1, line + "\n");
const isFile = (f: string) => f !== "" && existsSync(f) && statSync(f).isFile();

function main(args: string[]): void {
  const home = envHome();
  const cfg = home ? `${home}/config/crew-dispatch.json` : "";
  let raw = Buffer.alloc(0);
  // A blank file or a bare null is NO document to jq: lookups on it answer
  // absent (the default falls back, a rule is not there), and only the modes
  // that validated with `jq -e .` (strict) refuse it. jq also skips one
  // leading BOM.
  const load = (strict = true): Json => {
    raw = readFileSync(cfg);
    const text = raw.toString("utf8").replace(/^\ufeff/, "");
    let doc: Json = null;
    if (!/^[ \t\n\r]*$/.test(text)) {
      try {
        doc = JSON.parse(text);
      } catch {
        refuse(`invalid JSON: ${cfg}`);
      }
    }
    if (isObj(doc) || (doc === null && !strict)) return doc;
    return refuse(`invalid JSON: ${cfg}`);
  };
  const usage = (msg: string) => refuse(`usage: ${msg}`);

  const qaValidate = (c: Json) => validQaPane(field(field(c, "panes"), "qa"))
    || refuse("panes.qa must be either one static harness/model/effort profile or routed rules with non-empty when, atomic object use, non-empty why, and an optional bare default");
  const qaRuleUse = (c: Json, sel: string): Json => {
    qaValidate(c);
    const qa = c.panes.qa;
    if (!has(qa, "rules")) refuse("panes.qa is static and does not accept --rule");
    if (sel === "default") return alt(qa.default, null) ?? refuse("panes.qa has no default profile");
    const n = positive(sel) ?? refuse("qa rule must be a positive number or default");
    return alt(nth(qa.rules, n - 1), null)?.use ?? refuse(`no panes.qa rule ${sel} in ${cfg}`);
  };
  const routedValidate = (c: Json, k: string) => validRoutedPane(c.panes[k])
    || refuse(`panes.${k} routed rules require non-empty when, atomic object use, non-empty why on every rule, and a mandatory default profile`);
  const routedRuleUse = (c: Json, k: string, sel: string): Json => {
    routedValidate(c, k);
    if (sel === "default") return c.panes[k].default;
    const n = positive(sel) ?? refuse(`${k} rule must be a positive number or default`);
    return alt(nth(c.panes[k].rules, n - 1), null)?.use ?? refuse(`no panes.${k} rule ${sel} in ${cfg}`);
  };

  const [op = "", a2 = "", a3 = "", a4 = ""] = args;
  switch (op) {
    case "--list": {
      if (!isFile(cfg)) refuse(`no dispatch config at ${cfg}`);
      ruleListLines(load()).forEach(say);
      return;
    }
    case "--rule": {
      if (a2 === "") refuse("--rule needs an index (see --list)");
      const n = positive(a2) ?? refuse("rule must be a positive number");
      if (!isFile(cfg)) refuse(`no dispatch config at ${cfg}`);
      const rule = alt(nth(field(load(false), "rules"), n - 1), null) ?? refuse(`no rule ${a2} in ${cfg}`);
      const use = field(rule, "use");
      if (!Array.isArray(use)) return void say(profileLine(use));
      if (use.length === 0) refuse(`rule ${a2} has an empty use list`);
      const rr = join(stateDir(), `.dispatch-rr-${a2}`);
      let count = 0;
      try {
        count = counterValue(readFileSync(rr, "utf8"));
      } catch {}
      say(profileLine(rrPick(use, count)));
      writeFileSync(rr, `${count + 1}\n`);
      return;
    }
    case "--pane": {
      const k = a2;
      if (k === "") refuse("--pane needs a kind (e.g. codereview, qa)");
      if (!isFile(cfg)) return;
      const c = load();
      const pane = alt(field(field(c, "panes"), k), null);
      if (pane === null) return;
      const hasLanes = has(pane, "lanes");
      if (a3 === "--lanes") {
        if (args.length !== 3) usage("ac-dispatch-select.sh --pane <kind> --lanes");
        if (!hasLanes) refuse(`panes.${k} declares no lanes - --lanes is for a kind that runs EVERY profile it lists; this entry resolves as a single profile`);
        if (hasStaticKeys(pane) || has(pane, "rules")) refuse(`panes.${k} cannot mix lanes with static or routed keys`);
        const lanes = pane.lanes;
        if (!Array.isArray(lanes) || lanes.length === 0) refuse(`panes.${k}.lanes must be a non-empty array`);
        if (!lanes.every((l: Json) => isObj(l) && nonBlank(l.harness))) refuse(`every lane of panes.${k} needs a harness`);
        const dup = duplicateLane(lanes);
        if (dup) refuse(`panes.${k} has a duplicate lane (${dup}) - two lanes on the same harness and model buy one perspective twice`);
        lanes.forEach((l: Json) => say(profileLine(l)));
        return;
      }
      if (hasLanes) refuse(`panes.${k} declares lanes and has no single profile to resolve - ask for them with: ac-dispatch-select.sh --pane ${k} --lanes`);
      if (k === "qa") {
        qaValidate(c);
        switch (a3) {
          case "--list":
            if (args.length !== 3) usage("ac-dispatch-select.sh --pane qa --list");
            if (!has(pane, "rules")) refuse("panes.qa is static and does not accept --list");
            paneListLines(pane).forEach(say);
            return;
          case "--rule":
            if (args.length !== 4) usage("ac-dispatch-select.sh --pane qa --rule <number|default>");
            return void say(profileLine(qaRuleUse(c, a4)));
          case "--receipt": {
            if (args.length !== 4) usage("ac-dispatch-select.sh --pane qa --receipt <number|default>");
            qaRuleUse(c, a4);
            const sha = createHash("sha256").update(raw).digest("hex");
            return void say(qaReceipt(c, a4, sha));
          }
          case "":
            // Routed QA needs caller judgment, so an unselected lookup is
            // absent to downstream pane agents and ac-spawn.
            if (has(pane, "rules")) return;
            return void say(profileLine(pane));
          default:
            usage("ac-dispatch-select.sh --pane qa [--list | --rule <number|default> | --receipt <number|default>]");
        }
      }
      if (["gate", "codereview", "roomchief"].includes(k) && has(pane, "rules")) {
        routedValidate(c, k);
        switch (a3) {
          case "--list":
            if (args.length !== 3) usage(`ac-dispatch-select.sh --pane ${k} --list`);
            paneListLines(pane).forEach(say);
            return;
          case "--rule":
            if (args.length !== 4) usage(`ac-dispatch-select.sh --pane ${k} --rule <number|default>`);
            return void say(profileLine(routedRuleUse(c, k, a4)));
          case "":
            return void say(profileLine(routedRuleUse(c, k, "default")));
          default:
            usage(`ac-dispatch-select.sh --pane ${k} [--list | --rule <number|default>]`);
        }
      }
      if (args.length !== 2) refuse("--pane operations are supported only for routed qa/gate/codereview/roomchief");
      return void say(profileLine(pane));
    }
    case "": {
      const d = isFile(cfg) ? alt(field(load(false), "default"), null) : null;
      say(d !== null ? profileLine(d) : `harness=${configRead("crew-harness", "claude")}\tmodel=\teffort=`);
      return;
    }
    case "--propose": {
      const brief = a2;
      if (!isFile(brief)) usage("ac-dispatch-select.sh --propose <brief-file>");
      if (!isFile(cfg)) refuse(`no dispatch config at ${cfg}`);
      const crit = entries(alt(field(load(), "rules"), [])).map((r, i) => `${i + 1}=${jqText(field(r, "when"))}`);
      if (crit.length === 0) refuse(`no rules in ${cfg}`);
      const jev = join(import.meta.dir, "..", "bin", "ac-jev.sh");
      const ask = Bun.spawnSync([jev, "ask", "--site", "dispatch", "--state-file", brief, "--choice", "rule",
        "--instructions", "Which dispatch rule describes the task in the state? Each option is one rule's when clause.",
        "--criteria", ...crit], { stdin: "inherit", stderr: "inherit" });
      if (ask.exitCode !== 0) process.exit(childStatus(ask));
      const out = ask.stdout.toString().replace(/\n+$/, "");
      if (out === "") return;
      let rule: Json;
      try {
        rule = JSON.parse(out).rule;
      } catch {
        refuse(`ac-jev.sh ask printed unreadable JSON: ${out}`);
      }
      const sha = Bun.spawnSync([jev, "sha", "--state-file", brief], { stdin: "inherit", stderr: "inherit" });
      say(`propose: rule=${jqRaw(rule.choice)} p=${jqRaw(rule.p[rule.choice])} state_sha=${sha.stdout.toString().replace(/\n+$/, "")}`);
      return;
    }
    default:
      usage("ac-dispatch-select.sh [--list | --rule <n> | --propose <brief-file> | --pane <kind> [--list|--rule <selection>|--receipt <selection>]]");
  }
}

if (import.meta.main) {
  const [caller, ...args] = process.argv.slice(2);
  let atCaller = false;
  try {
    process.chdir(caller);
    atCaller = true;
  } catch {}
  // Without the caller's cwd a relative input would resolve inside the distro
  // checkout, whose gitignored config/ and state/ look like a fleet home.
  const relative = [process.env.AC_HOME ?? "", args[0] === "--propose" ? args[1] ?? "" : ""]
    .some((p) => p !== "" && !isAbsolute(p));
  if (!atCaller && relative)
    die("the current directory cannot be resolved, so a relative AC_HOME or --propose brief cannot be either");
  try {
    main(args);
  } catch (e) {
    die(e instanceof Error ? e.message : String(e));
  }
}
