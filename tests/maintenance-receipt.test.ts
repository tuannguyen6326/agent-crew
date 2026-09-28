// maintenance-receipt.test.ts - Bun unit tests for src/maintenance-receipt.ts,
// one per parser branch. The callers' contract stays owned by
// tests/ac-maintenance-core.test.sh, which drives the bash names. Run through
// tests/src.test.sh.

import { test, expect, afterAll } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sha256File } from "../src/lib.ts";
import { evidenceValue, readEvidence, receiptCheck, significance } from "../src/maintenance-receipt.ts";

const MODULE = join(import.meta.dir, "..", "src", "maintenance-receipt.ts");
const F = realpathSync(mkdtempSync(join(tmpdir(), "ac-maint-receipt-ts-")));
afterAll(() => rmSync(F, { recursive: true, force: true }));

const MANIFEST_LINE = "A candidate line that exists nowhere but inside this manifest.";
const put = (p: string, body: string | Buffer) => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, typeof body === "string" ? Buffer.from(body, "latin1") : body);
};

type Action = { staged: string; body: string };
let runs = 0;
// A run dir holding a manifest, staged payloads and a plan over them, laid out
// the way Learning writes one; `planDir` puts the plan under <run>/plans.
function mkRun(actions: Action[], opt: { planDir?: string; plan?: (p: Record<string, unknown>) => void } = {}) {
  const run = join(F, `run-${++runs}`);
  put(join(run, "manifest"), `kind: skill\nname: example\n===skill===\n${MANIFEST_LINE}\n`);
  const acts = actions.map((a, i) => {
    put(join(run, a.staged), a.body);
    return { op: "write-skill", target: `skills/s${i}/SKILL.md`, old_sha256: "-", new_sha256: sha256File(join(run, a.staged)), staged: a.staged };
  });
  const doc: Record<string, unknown> = {
    schema: "agentcrew.maintenance-plan/v1", mode: "learning", run_id: `learning-${runs}`, subject: "example",
    input_manifest_sha256: sha256File(join(run, "manifest")), actions: acts,
  };
  opt.plan?.(doc);
  const plan = join(run, opt.planDir ?? "", "plan.json");
  put(plan, JSON.stringify(doc));
  return { run, plan, manifest: join(run, "manifest"), shas: acts.map((a) => a.new_sha256) };
}

const evidence = (manifestQuote: string, sha: string, payload?: string) =>
  `## Inputs Read\n- INPUT MANIFEST QUOTE: ${manifestQuote}\n- ACTION PLAN NEW SHA-256: ${sha}\n` +
  (payload === undefined ? "" : `- STAGED PAYLOAD QUOTE: ${payload}\n`);

const SKILL = { staged: "staged/skills/example/SKILL.md", body: "skill\n" };

test("evidenceValue takes the one label line inside ## Inputs Read, trimmed of C whitespace only", () => {
  const body = "## Grounds\nx\n## Inputs Read\n- LABEL: \t\v\f value \xa0\r\n## Proposed Process\ny\n";
  expect(evidenceValue(body, "LABEL")).toBe("value \xa0");
  expect(evidenceValue("## Inputs Read\n- LABEL: \t \r\n", "LABEL")).toBe("");
  expect(evidenceValue("## Inputs Read\n##x\n- LABEL: v\n", "LABEL")).toBe("v");
});

test("evidenceValue refuses a label that is missing, outside the section, or given twice", () => {
  expect(evidenceValue("## Inputs Read\n- OTHER: v\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Grounds\n- LABEL: v\n## Inputs Read\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\n- LABEL: a\n- LABEL: b\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\n- LABEL: a\n## Other\n## Inputs Read\n- LABEL: b\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\n## Other\n- LABEL: a\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\n -LABEL: a\n- LABEL:a\n", "LABEL")).toBeNull();
});

test("the section heading is exact up to trailing C whitespace", () => {
  expect(evidenceValue("## Inputs Read \t\r\n- LABEL: v\n", "LABEL")).toBe("v");
  expect(evidenceValue("## Inputs Read:\n- LABEL: v\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\xa0\n- LABEL: v\n", "LABEL")).toBeNull();
  expect(evidenceValue("## Inputs Read\n- LABEL: v", "LABEL")).toBe("v");
});

test("a NUL ends its line, as onetrue awk reads it", () => {
  expect(evidenceValue("## Inputs Read\n- LABEL: ab\0cd\n", "LABEL")).toBe("ab");
  expect(evidenceValue("## Inputs Read\0x\n- LABEL: v\n", "LABEL")).toBe("v");
});

test("significance counts bytes left once the run id, subject and mode are deleted, most specific first", () => {
  expect(significance("Ghi ch\xc3\xba: \xc4\x91\xc3\xa3 g\xe1\xbb\xa1.\n", "q1", "q2", "q3")).toBe(15);
  expect(significance("learning-x x learning ab\n", "learning-x", "x", "learning")).toBe(2);
  expect(significance("learning-q7\n", "learning-q7", "zz", "learning")).toBe(0);
  expect(significance("aabb\n", "ab", "zz", "zz")).toBe(2);
  expect(significance("! \"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ \t\v\f\r\xa0\n", "q1", "q2", "q3")).toBe(1);
  expect(significance("short\nthe longest line\n\nx", "q1", "q2", "q3")).toBe(14);
  expect(significance("", "q1", "q2", "q3")).toBe(0);
  expect(significance("ab\0cdefgh\n", "q1", "q2", "q3")).toBe(2);
});

test("readEvidence accepts the three proofs, fenced or bare", () => {
  const r = mkRun([SKILL]);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "skill"), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence("`" + MANIFEST_LINE + "`", "`" + r.shas[0] + "`", "`skill`"), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE.slice(2, 30), r.shas[0], "skill"), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence("candidate lin", r.shas[0], "skill"), 12)).toBe(true);
});

test("readEvidence refuses a quote the manifest does not hold or that is only prompt-supplied values", () => {
  const r = mkRun([SKILL]);
  expect(readEvidence(r.manifest, r.plan, evidence("A candidate line no reader ever saw.", r.shas[0], "skill"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence("name: example", r.shas[0], "skill"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "skill"), 99)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence("candidate li", r.shas[0], "skill"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, `## Inputs Read\n- ACTION PLAN NEW SHA-256: ${r.shas[0]}\n- STAGED PAYLOAD QUOTE: skill\n`, 12)).toBe(false);
});

test("readEvidence refuses an action hash the plan does not carry or the prompt printed", () => {
  const r = mkRun([SKILL]);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, "0".repeat(64), "skill"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, sha256File(r.plan), "skill"), 12)).toBe(false);
  const self = mkRun([{ staged: "staged/copy.md", body: `kind: skill\nname: example\n===skill===\n${MANIFEST_LINE}\n` }]);
  expect(self.shas[0]).toBe(sha256File(self.manifest));
  expect(readEvidence(self.manifest, self.plan, evidence(MANIFEST_LINE, self.shas[0], MANIFEST_LINE), 12)).toBe(false);
});

test("the payload quote is bound to the cited action and must reach the floor that payload bears", () => {
  const r = mkRun([
    { staged: "staged/records/learnings.md", body: "# Learning Ledger\n\n## Distilled\n" },
    { staged: "staged/skills/thin/SKILL.md", body: "thin\n" },
    { staged: "staged/records/empty.md", body: "" },
  ]);
  const [ledger, thin, empty] = r.shas;
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, ledger, "# Learning Ledger"), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, ledger), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, ledger, "thin"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, ledger, "## Distilled"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, thin, "thin"), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, thin, "hin"), 12)).toBe(false);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, empty), 12)).toBe(false);
});

test("the waiver needs every action's payload to bear nothing, and then asks for no payload quote", () => {
  const r = mkRun([
    { staged: "staged/records/empty.md", body: "" },
    { staged: "staged/records/punct.md", body: "---\n" },
    { staged: "staged/records/nul.md", body: "\0A long payload line hidden behind a NUL.\n" },
  ]);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0]), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[2]), 12)).toBe(true);
});

test("a quote is a byte substring of the file, NUL, CR and invalid bytes included", () => {
  const r = mkRun([{ staged: "staged/records/octet.md", body: "x\0An octet \xff line\r with a CR.\n" }]);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "An octet \xff line\r with a CR."), 12)).toBe(true);
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "An octet \xfe line\r with a CR."), 12)).toBe(false);
  const long = "L".repeat(65537);
  const wide = mkRun([{ staged: "staged/records/wide.md", body: `${long}\n` }]);
  expect(readEvidence(wide.manifest, wide.plan, evidence(MANIFEST_LINE, wide.shas[0], long), 12)).toBe(true);
});

test("the receipt body loses its NULs before it is read, as $(cat) did", () => {
  const r = mkRun([SKILL]);
  const body = evidence("A\0 candidate line that exists nowhere but inside this manifest.", r.shas[0], "skill");
  expect(readEvidence(r.manifest, r.plan, body, 12)).toBe(true);
});

test("the staged file resolves under the run dir, one level above a plans dir", () => {
  const r = mkRun([SKILL], { planDir: "plans" });
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "skill"), 12)).toBe(true);
  const link = mkRun([SKILL]);
  rmSync(join(link.run, SKILL.staged));
  put(join(link.run, "elsewhere"), "skill\n");
  symlinkSync(join(link.run, "elsewhere"), join(link.run, SKILL.staged));
  expect(readEvidence(link.manifest, link.plan, evidence(MANIFEST_LINE, link.shas[0], "skill"), 12)).toBe(false);
});

// ac_maintenance_plan_validate's jq regexes let one trailing LF through, and
// the shell's $(jq -r ...) then dropped it: the field reads without it.
test("a plan field reads as $(jq -r) did, and a non-string one fails closed", () => {
  const r = mkRun([SKILL], { plan: (p) => {
    p.subject = "example\n";
    (p.actions as { staged: string }[])[0].staged += "\n";
  } });
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "skill"), 12)).toBe(true);
  const bad = mkRun([SKILL], { plan: (p) => { p.run_id = null; } });
  expect(readEvidence(bad.manifest, bad.plan, evidence(MANIFEST_LINE, bad.shas[0], "skill"), 12)).toBe(false);
});

const FRONT: [string, string][] = [
  ["schema", "agentcrew.maintenance-gate/v1"], ["mode", "learning"], ["subject", "example"],
  ["decision", "continue"], ["authority", "second-chief"], ["engine", "codex"], ["model", "gate-model"],
  ["input_manifest_sha256", ""], ["action_plan_sha256", ""], ["reviewed_at", "2026-07-26T00:00:00Z"],
];
function receipt(r: ReturnType<typeof mkRun>, edit: (lines: string[]) => string[] = (l) => l): string {
  const front = FRONT.map(([k, v]) => `${k}: "${
    k === "input_manifest_sha256" ? sha256File(r.manifest) : k === "action_plan_sha256" ? sha256File(r.plan) : v}"`);
  const lines = ["---", ...front, "---", "# Maintenance Gate Decision", "## Grounds", "Recoverable.",
    ...evidence(MANIFEST_LINE, r.shas[0], "skill").trimEnd().split("\n"), "## Proposed Process", "Apply the plan."];
  const p = join(r.run, `receipt-${Math.random().toString(36).slice(2)}.md`);
  put(p, edit(lines).join("\n") + "\n");
  return p;
}
const check = (r: ReturnType<typeof mkRun>, edit?: (lines: string[]) => string[]) =>
  receiptCheck(receipt(r, edit), r.plan, r.manifest, 12);
const setKey = (k: string, v: string) => (l: string[]) => l.map((x) => (x.startsWith(`${k}: `) ? `${k}: "${v}"` : x));

test("receiptCheck prints the decision of a closed, hash-bound receipt with read-evidence", () => {
  const r = mkRun([SKILL]);
  expect(check(r)).toBe("continue");
  expect(check(r, setKey("decision", "revise"))).toBe("revise");
  expect(check(r, setKey("decision", "ask-captain"))).toBe("ask-captain");
});

test("the frontmatter is closed: exact first line, known keys once each, quoted scalars, a closing line", () => {
  const r = mkRun([SKILL]);
  const bad: [string, (l: string[]) => string[]][] = [
    ["extra key", (l) => [...l.slice(0, 11), 'note: "x"', ...l.slice(11)]],
    ["duplicate key", (l) => [...l.slice(0, 11), l[7], ...l.slice(11)]],
    ["missing key", (l) => l.filter((x) => !x.startsWith("engine: "))],
    ["unclosed", (l) => l.filter((x, i) => i !== 11)],
    ["late opening", (l) => ["", ...l]],
    ["CR on the opening line", (l) => ["---\r", ...l.slice(1)]],
    ["CR after a value", (l) => l.map((x) => (x.startsWith("model: ") ? x + "\r" : x))],
    ["unquoted scalar", (l) => l.map((x) => (x.startsWith("model: ") ? "model: gate-model" : x))],
    ["two spaces", (l) => l.map((x) => (x.startsWith("model: ") ? 'model:  "gate-model"' : x))],
    ["blank line", (l) => [...l.slice(0, 5), "", ...l.slice(5)]],
    ["hyphenated key", (l) => l.map((x) => x.replace(/^reviewed_at:/, "reviewed-at:"))],
  ];
  for (const [name, edit] of bad) expect([name, check(r, edit)]).toEqual([name, null]);
});

test("a frontmatter value runs from the first to the last double quote, and a NUL ends its line", () => {
  const r = mkRun([SKILL]);
  expect(check(r, setKey("engine", 'co"dex'))).toBe("continue");
  expect(check(r, (l) => l.map((x) => (x.startsWith("decision: ") ? 'decision: "continue"\0junk' : x)))).toBe("continue");
  expect(check(r, (l) => l.map((x) => (x.startsWith("decision: ") ? 'decision: "cont\0inue"' : x)))).toBe(null);
  expect(check(r, setKey("model", "a\rb"))).toBe("continue");
});

test("schema, decision, mode, subject and both hashes are each checked", () => {
  const r = mkRun([SKILL]);
  for (const [k, v] of [
    ["schema", "agentcrew.captain-decision/v1"], ["decision", "environment-error"], ["decision", "chief-decide"],
    ["mode", "curate"], ["subject", "other"], ["input_manifest_sha256", sha256File(r.plan)], ["action_plan_sha256", "bad"],
  ]) expect([k, v, check(r, setKey(k, v))]).toEqual([k, v, null]);
  const drift = mkRun([SKILL], { plan: (p) => { p.input_manifest_sha256 = "f".repeat(64); } });
  expect(check(drift)).toBe(null);
});

test("## Grounds and ## Proposed Process must each hold a non-blank line", () => {
  const r = mkRun([SKILL]);
  const drop = (h: string) => (l: string[]) => {
    const i = l.indexOf(h);
    return [...l.slice(0, i), ...l.slice(i + 2)];
  };
  expect(check(r, drop("## Grounds"))).toBe(null);
  expect(check(r, drop("## Proposed Process"))).toBe(null);
  expect(check(r, (l) => l.map((x) => (x === "Recoverable." ? " \t\r" : x)))).toBe(null);
  expect(check(r, (l) => l.map((x) => (x === "Recoverable." ? "\0Recoverable." : x)))).toBe(null);
  expect(check(r, (l) => l.map((x) => (x === "## Grounds" ? "## Grounds \r" : x)))).toBe("continue");
  expect(check(r, (l) => l.map((x) => (x === "Recoverable." ? "\xa0" : x)))).toBe("continue");
});

test("only repository-policy is exempt from read-evidence", () => {
  const r = mkRun([SKILL]);
  const blind = (l: string[]) => l.filter((x) => !x.startsWith("- "));
  expect(check(r, (l) => setKey("authority", "repository-policy")(blind(l)))).toBe("continue");
  expect(check(r, blind)).toBe(null);
  expect(check(r, (l) => setKey("authority", "chief")(blind(l)))).toBe(null);
  expect(check(r, (l) => setKey("authority", "repository-policy ")(blind(l)))).toBe(null);
  expect(check(r, (l) => setKey("authority", "repository-policyx")(blind(l)))).toBe(null);
});

test("a plan behind one UTF-8 BOM reads as jq read it", () => {
  const r = mkRun([SKILL]);
  put(r.plan, Buffer.concat([Buffer.from("\xef\xbb\xbf", "latin1"), readFileSync(r.plan)]));
  expect(readEvidence(r.manifest, r.plan, evidence(MANIFEST_LINE, r.shas[0], "skill"), 12)).toBe(true);
  expect(check(r)).toBe("continue");
});

function cli(args: string[], stdin = "", cwd = F) {
  const p = Bun.spawnSync([process.execPath, "--no-env-file", MODULE, cwd, ...args], {
    stdin: Buffer.from(stdin, "latin1"),
    env: { PATH: process.env.PATH! },
  });
  return { code: p.exitCode, stdout: p.stdout.toString("latin1"), stderr: p.stderr.toString() };
}

test("the verbs print what the bash names printed, and nothing on a refusal", () => {
  expect(cli(["evidence-value", "LABEL"], "## Inputs Read\n- LABEL:  v\xff \n")).toEqual({ code: 0, stdout: "v\xff", stderr: "" });
  expect(cli(["evidence-value", "LABEL"], "- LABEL: v\n")).toEqual({ code: 1, stdout: "", stderr: "" });
  expect(cli(["evidence-value", "é"], "## Inputs Read\n- \xc3\xa9: v\n")).toEqual({ code: 0, stdout: "v", stderr: "" });
  const r = mkRun([SKILL]);
  expect(cli(["read-evidence", r.manifest, r.plan, "12"], evidence(MANIFEST_LINE, r.shas[0], "skill"))).toEqual({ code: 0, stdout: "", stderr: "" });
  expect(cli(["read-evidence", r.manifest, r.plan, "12"], evidence(MANIFEST_LINE, r.shas[0]))).toEqual({ code: 1, stdout: "", stderr: "" });
  expect(cli(["receipt-check", receipt(r), r.plan, r.manifest, "12"])).toEqual({ code: 0, stdout: "continue\n", stderr: "" });
  expect(cli(["receipt-check", receipt(r, setKey("mode", "curate")), r.plan, r.manifest, "12"])).toEqual({ code: 1, stdout: "", stderr: "" });
});

test("a usage error, or a relative path with no caller cwd, refuses with an ERROR line", () => {
  const r = mkRun([SKILL]);
  for (const args of [[], ["bogus"], ["evidence-value"], ["read-evidence", r.manifest, r.plan], ["read-evidence", r.manifest, r.plan, "x"],
    ["receipt-check", receipt(r), r.plan, r.manifest]]) {
    const out = cli(args);
    expect([args, out.code, out.stdout]).toEqual([args, 1, ""]);
    expect(out.stderr).toStartWith("ERROR: ");
  }
  const odd = join(F, "odd-�");
  symlinkSync(r.run, odd);
  expect(cli(["read-evidence", join(odd, "manifest"), join(odd, "plan.json"), "12"], evidence(MANIFEST_LINE, r.shas[0], "skill")))
    .toEqual({ code: 1, stdout: "", stderr: "" });
  const rel = cli(["read-evidence", "manifest", "plan.json", "12"], evidence(MANIFEST_LINE, r.shas[0], "skill"), "");
  expect([rel.code, rel.stdout]).toEqual([1, ""]);
  expect(rel.stderr).toStartWith("ERROR: ");
  const inRun = cli(["read-evidence", "manifest", "plan.json", "12"], evidence(MANIFEST_LINE, r.shas[0], "skill"), r.run);
  expect(inRun.code).toBe(0);
});
