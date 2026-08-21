// dashboard.test.ts - Bun unit test for the dashboard's PURE parsers.
// Run: bun test bin/dashboard.test.ts   (importing dashboard.ts does NOT start
// the server - Bun.serve is guarded by import.meta.main).
//
// Only the two non-trivial pure functions are tested: the rest of dashboard.ts
// is thin IO/shell-out/render that a unit test would only re-assert the obvious
// for. parseRoomList in particular must READ ac-room.sh's status token, never
// re-count pending/handback (the no-second-bookkeeping rule).

import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, symlinkSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { reviewWakeParts, reviewWakeText, reviewWakeFamily, chiefPaneOf, ansiToHtml, CHIEF_KEYS, isChiefKey, isChiefChar, isChiefPaste, familyPaneIds, termSize, localHostOk, originOk, attachExt, extractMermaidSources, diagramSceneName, emptyReviewSession, reviewApply, pollSlice, mintShareToken, shareLinkUrl, sanitizeGuestName, shareViewersView, SHARE_VIEWER_FRESH_MS, hashSharePassword, basicAuthPassword, shareHashEq, normalizeAnnotation, isSceneName, normalizeScene, parseBacklog, parseRoomList, parseArtifactPath, artifactKind, groupArtifacts, isHtmlArtifact, reviewableArtifact, cadenceLabel, chiefFitPx, paneLayoutCols, renderMarkdown, RECORD_LEDGERS, isRecordLedger, matchBacklog, EDITABLE_CONFIG, CONFIG_KNOB_META, isEditableConfig, applyConfigWrite, applyDispatchWrite, readDispatch, verifyProcessRows, boardSystemPanes, parseLearningLedger, collectLearning, ttlMemo, HOME_PATHS_TTL_MS, wbfSceneSignature, wbfShouldSave, reviewSessionSummary, parseCrewdomains, domainProjectLinks, resolveAnnotationSnapshot, reviewSnapshotPath, decodePngSnapshot, whiteboardWakeParts, whiteboardWakeKey, redrawMessage, redrawReceipt, whiteboardWrite, whiteboardShow, parseBacklogLine, contractTokens, backlogFamilyIds, storyState, familyOfTaskId, taskFamilyOf, collectFamilyTasks, familyRepos, isRepoKnowledge, learningsCiteFamily, deriveProgress, composeFamily, familyStages, parseTimeline, stemRegroup, parseEpicBranches, resolveTheme, nextTheme, resolvePalette, nextPalette, normalizeBgColor, clampBgDim, reviewShouldRemount, collectArtifacts, readRoomEntries, crossHomeReviewRows, readerCss, buildReviewSrcdoc, mermaidDropParticipantBoxes, mermaidImportWithFallback, mermaidPass } from "./dashboard.ts";

// PNG signature (89 50 4E 47 0D 0A 1A 0A) - test-local copy of the same
// 8-byte magic decodePngSnapshot validates against.
const PNG_MAGIC_TEST = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

test("resolveTheme: stored choice wins over prefers-color-scheme", () => {
  expect(resolveTheme("light", false)).toBe("light");
  expect(resolveTheme("dark", true)).toBe("dark");
});

test("resolveTheme: no stored choice falls back to prefers-color-scheme", () => {
  expect(resolveTheme(null, true)).toBe("light");
  expect(resolveTheme(null, false)).toBe("dark");
});

test("resolveTheme: garbage/empty stored value is ignored, dark is the default", () => {
  expect(resolveTheme("", false)).toBe("dark");
  expect(resolveTheme("nonsense", false)).toBe("dark");
  expect(resolveTheme("nonsense", true)).toBe("light");
});

test("nextTheme cycles auto -> light -> dark -> auto", () => {
  expect(nextTheme("auto")).toBe("light");
  expect(nextTheme("light")).toBe("dark");
  expect(nextTheme("dark")).toBe("auto");
});

test("normalizeBgColor accepts only plain hex, clampBgDim bounds the dim", () => {
  expect(normalizeBgColor("#0b0f14")).toBe("#0b0f14");
  expect(normalizeBgColor("  #ABC ")).toBe("#abc");
  expect(normalizeBgColor(null)).toBeNull();
  expect(normalizeBgColor("")).toBeNull();
  expect(normalizeBgColor("red")).toBeNull();
  expect(normalizeBgColor("url(javascript:1)")).toBeNull();
  expect(normalizeBgColor("#12345")).toBeNull();
  expect(clampBgDim("55")).toBe(55);
  expect(clampBgDim(null)).toBe(55);
  expect(clampBgDim("nonsense")).toBe(55);
  expect(clampBgDim("-10")).toBe(0);
  expect(clampBgDim("400")).toBe(95);
  expect(clampBgDim("42.6")).toBe(43);
});

test("resolvePalette: only teal/navy are recognized, everything else is cyan", () => {
  expect(resolvePalette("teal")).toBe("teal");
  expect(resolvePalette("navy")).toBe("navy");
  expect(resolvePalette(null)).toBe("cyan");
  expect(resolvePalette("")).toBe("cyan");
  expect(resolvePalette("nonsense")).toBe("cyan");
});

test("nextPalette cycles cyan -> teal -> navy -> cyan", () => {
  expect(nextPalette("cyan")).toBe("teal");
  expect(nextPalette("teal")).toBe("navy");
  expect(nextPalette("navy")).toBe("cyan");
});

test("parseBacklog splits In flight / Queued / Done and keeps only task lines", () => {
  const md = [
    "# agent-crew backlog",
    "",
    "## In flight",
    "- [ ] a - one (repo: x, since 2026-01-01)",
    "- [ ] b [EPIC] - two stories: s1,s2",
    "",
    "## Queued",
    "- [ ] c - three (repo: x) blocked-by: a - waiting",
    "",
    "## Done",
    "- [x] d - four - local main (merged 2026-01-02)",
    "- [x] e [failed] - why (2026-01-03)",
    "notes that are not task lines",
  ].join("\n");
  const bl = parseBacklog(md);
  expect(bl.in_flight.length).toBe(2);
  expect(bl.queued.length).toBe(1);
  expect(bl.done.length).toBe(2);
  expect(bl.in_flight[0]).toContain("a - one");
  expect(bl.done[1]).toContain("[failed]");
});

test("parseLearningLedger separates Pending and canonical/legacy pointers", () => {
  const md = [
    "# Learning Ledger",
    "",
    "## Pending",
    "",
    "### 2026-07-25 - task (chief)",
    "- LESSON: preserve this raw record.",
    "",
    "## Distilled",
    "",
    "- [distilled -> stable-skill] sources=4 updated=2026-07-24 ([skill](../skills/stable-skill/SKILL.md); [evidence](learnings-archive/stable-skill.md))",
    "- 2026-07-23 [distilled -> legacy-local @fleet] old pointer",
    "- 2026-07-22 [distilled -> legacy-shared @container] old pointer",
  ].join("\n");
  const view = parseLearningLedger(md);
  expect(view.pending).toContain("LESSON: preserve this raw record.");
  expect(view.pending).not.toContain("stable-skill");
  expect(view.pointers).toEqual([
    { name: "stable-skill", sources: 4, updated: "2026-07-24", legacy: null },
    { name: "legacy-local", sources: 1, updated: "2026-07-23", legacy: "fleet" },
    { name: "legacy-shared", sources: 1, updated: "2026-07-22", legacy: "container" },
  ]);
});

test("collectLearning stays fleet-local, excludes skills-archive, and refuses escaping skill symlinks", () => {
  const root = mkdtempSync(`${tmpdir()}/ac-dash-learning-`);
  const other = `${root}/other`;
  const home = `${root}/fleet`;
  try {
    mkdirSync(`${home}/skills/local-skill`, { recursive: true });
    mkdirSync(`${home}/skills/skills-archive/retired-skill`, { recursive: true });
    mkdirSync(`${home}/records/learnings-archive`, { recursive: true });
    mkdirSync(`${home}/data/learning-run/gates/local-skill`, { recursive: true });
    mkdirSync(`${home}/data/learning-open/gates/needs-captain`, { recursive: true });
    mkdirSync(`${other}/foreign-skill`, { recursive: true });
    writeFileSync(`${home}/skills/local-skill/SKILL.md`, [
      "---",
      "name: local-skill",
      "description: Fleet-owned skill.",
      "metadata:",
      '  landed: "100"',
      "---",
      "",
      "# Local",
    ].join("\n"));
    writeFileSync(`${home}/skills/local-skill/.usage.meta`, "seeded_count=3\nlast_seeded=200\n");
    writeFileSync(`${home}/skills/skills-archive/retired-skill/SKILL.md`, "---\nname: retired-skill\ndescription: Retired.\n---\n");
    writeFileSync(`${other}/foreign-skill/SKILL.md`, "---\nname: foreign-skill\ndescription: Foreign.\n---\n");
    Bun.spawnSync(["ln", "-s", `${other}/foreign-skill`, `${home}/skills/escape-skill`]);
    writeFileSync(`${home}/records/learnings.md`, [
      "# Learning Ledger",
      "",
      "## Pending",
      "",
      "- LESSON: still waiting.",
      "",
      "## Distilled",
      "",
      "- [distilled -> local-skill] sources=2 updated=2026-07-25 ([skill](../skills/local-skill/SKILL.md); [evidence](learnings-archive/local-skill.md))",
      "- 2026-07-24 [distilled -> legacy-shared @container] migrate this",
    ].join("\n"));
    writeFileSync(`${home}/records/learnings-archive/local-skill.md`, "# Evidence\n");
    writeFileSync(`${home}/data/learning-run/report.md`, "# Report\n\nstatus: ok\n");
    writeFileSync(`${home}/data/learning-run/retro.md`, "# Retro\n");
    writeFileSync(`${home}/data/learning-run/gates/local-skill/decision.md`, [
      "---",
      'schema: "agentcrew.maintenance-gate/v1"',
      'mode: "learning"',
      'subject: "local-skill"',
      'decision: "continue"',
      'authority: "second-chief"',
      'engine: "codex"',
      'model: "gpt-test"',
      'reviewed_at: "2026-07-25T00:00:00Z"',
      "---",
      "",
      "## Grounds",
      "",
      "Safe.",
    ].join("\n"));
    writeFileSync(`${home}/data/learning-open/report.md`, "# Report\n\nstatus: ok\n");
    writeFileSync(`${home}/data/learning-open/retro.md`, "# Retro\n");
    writeFileSync(`${home}/data/learning-open/candidate-needs-captain.md`, "kind: skill\nname: needs-captain\n");
    writeFileSync(`${home}/data/learning-open/gates/needs-captain/decision.md`, [
      "---",
      'schema: "agentcrew.maintenance-gate/v1"',
      'mode: "learning"',
      'subject: "needs-captain"',
      'decision: "ask-captain"',
      'authority: "second-chief"',
      'engine: "codex"',
      'model: "gpt-test"',
      'reviewed_at: "2026-07-25T01:00:00Z"',
      "---",
      "",
      "## Grounds",
      "",
      "Needs policy.",
    ].join("\n"));

    const learning = collectLearning(home);
    expect(learning.skills.map((s) => s.name)).toEqual(["local-skill"]);
    expect(learning.skills[0].sources).toBe(2);
    expect(learning.skills[0].seeded_count).toBe(3);
    expect(learning.skills[0].latest_decision?.decision).toBe("continue");
    expect(learning.archives.some((a) => a.name === "retired-skill" && a.kind === "skill")).toBe(true);
    expect(learning.pending.migration.map((p) => p.name)).toEqual(["legacy-shared"]);
    expect(learning.pending.active_run).toBe("learning-open");
    expect(learning.pending.waiting.map((d) => d.subject)).toEqual(["needs-captain"]);
    expect(learning.pending.waiting_gate).toEqual([]);
    expect(learning.skills.some((s) => s.name === "foreign-skill" || s.name === "escape-skill")).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("readRoomEntries and collectArtifacts resolve an ARCHIVED family (data/archive/<year>/<family>/) the same as a live one", async () => {
  const root = mkdtempSync(`${tmpdir()}/ac-dash-archive-`);
  const home = `${root}/fleet`;
  try {
    // Live family: data/<fam-live>/room.md + a report artifact.
    mkdirSync(`${home}/data/fam-live`, { recursive: true });
    writeFileSync(`${home}/data/fam-live/room.md`, [
      "# Room: fam-live",
      "",
      "- [2026-08-03T00:00:00Z] chief> ORDER: do the thing.",
    ].join("\n"));
    writeFileSync(`${home}/data/fam-live/report.md`, "# Report\n\nlive.\n");

    // Archived family: data/archive/2026/<fam-archived>/room.md, moved there
    // verbatim by bin/ac-archive.sh (its header owns the layout) - carrying
    // its own report.md and a nested stage dir the same way a live family does.
    mkdirSync(`${home}/data/archive/2026/fam-archived/spec`, { recursive: true });
    writeFileSync(`${home}/data/archive/2026/fam-archived/room.md`, [
      "# Room: fam-archived",
      "",
      "- [2026-01-05T00:00:00Z] chief> ORDER: do the archived thing.",
      "- [2026-01-06T00:00:00Z] chief> CLOSED: landed.",
    ].join("\n"));
    writeFileSync(`${home}/data/archive/2026/fam-archived/report.md`, "# Report\n\narchived.\n");
    writeFileSync(`${home}/data/archive/2026/fam-archived/spec/report.md`, "# Spec\n\narchived spec.\n");

    const liveEntries = await readRoomEntries(home, "fam-live");
    expect(liveEntries.length).toBeGreaterThan(0);
    expect(liveEntries[0]).toContain("do the thing");

    // The bug this guards: readRoomEntries used to existsSync() only the
    // live path and return [] for an archived family even though
    // `ac-room.sh show` (ac_room_file) already resolves the archived copy.
    const archivedEntries = await readRoomEntries(home, "fam-archived");
    expect(archivedEntries.length).toBeGreaterThan(0);
    expect(archivedEntries.some((l) => l.includes("do the archived thing"))).toBe(true);

    expect(await readRoomEntries(home, "no-such-family")).toEqual([]);

    const artifacts = collectArtifacts(home);
    const live = artifacts.find((a) => a.path.endsWith("data/fam-live/report.md"));
    expect(live?.family).toBe("fam-live");
    expect(live?.stage).toBe("report.md");

    // The bug this guards: the old rel computation stripped only `data/`,
    // so an archived path parsed as family="archive" stage="2026/...".
    const archivedTop = artifacts.find((a) => a.path.endsWith("archive/2026/fam-archived/report.md"));
    expect(archivedTop?.family).toBe("fam-archived");
    expect(archivedTop?.stage).toBe("report.md");
    expect(archivedTop?.id).toBe("fam-archived/report.md");

    const archivedNested = artifacts.find((a) =>
      a.path.endsWith("archive/2026/fam-archived/spec/report.md"),
    );
    expect(archivedNested?.family).toBe("fam-archived");
    expect(archivedNested?.stage).toBe("spec/report.md");

    expect(artifacts.some((a) => a.family === "archive")).toBe(false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("parseRoomList reads the status token ac-room.sh emitted (never a re-count)", () => {
  const out = [
    "PENDING-CAPTAIN(2)  greet2\t- [t] chief> GATE: pre-implement",
    "PENDING-CAPTAIN(1)+HANDBACK  both\t- [t] chief> HANDBACK: landed",
    "HANDBACK            migrate\t- [t] chief> HANDBACK: map done",
    "ok                  acfleets\t- [t] chief> CLOSED: landed",
  ].join("\n");
  const rows = parseRoomList(out);
  expect(rows.length).toBe(4);

  const g = rows.find((r) => r.family === "greet2")!;
  expect(g.pending).toBe(true);
  expect(g.handback).toBe(false);
  expect(g.status).toBe("PENDING-CAPTAIN(2)");

  const b = rows.find((r) => r.family === "both")!;
  expect(b.pending).toBe(true);
  expect(b.handback).toBe(true);

  const m = rows.find((r) => r.family === "migrate")!;
  expect(m.pending).toBe(false);
  expect(m.handback).toBe(true);

  const o = rows.find((r) => r.family === "acfleets")!;
  expect(o.pending).toBe(false);
  expect(o.handback).toBe(false);
  expect(o.last).toContain("CLOSED: landed");
});

test("parseRoomList sorts rooms newest-first, unparseable stamps last", () => {
  const out = [
    "ok                  older\t- [2026-07-18T09:00:00Z] chief> CLOSED: landed",
    "ok                  nostamp-a\t- [t] chief> CLOSED: landed",
    "PENDING-CAPTAIN(1)  newest\t- [2026-07-20T11:30:00Z] chief> GATE: pre-implement",
    "ok                  middle\t- [2026-07-19T14:42:48Z] chief> CLOSED: landed",
    "ok                  nostamp-b\t",
  ].join("\n");
  const rows = parseRoomList(out);
  expect(rows.map((r) => r.family)).toEqual(["newest", "middle", "older", "nostamp-a", "nostamp-b"]);
  expect(rows[0].lastTs).toBe(Date.parse("2026-07-20T11:30:00Z"));
  expect(rows[3].lastTs).toBe(0);
  expect(rows[4].lastTs).toBe(0);

  // the split roomInbox does (active first, then closed) preserves input order,
  // so each group stays newest-first without its own sort.
  const active = rows.filter((r) => r.pending || r.handback).map((r) => r.family);
  const closed = rows.filter((r) => !(r.pending || r.handback)).map((r) => r.family);
  expect(active).toEqual(["newest"]);
  expect(closed).toEqual(["middle", "older", "nostamp-a", "nostamp-b"]);
});

test("parseRoomList ignores the empty-rooms notice", () => {
  expect(parseRoomList("(no rooms yet)\n").length).toBe(0);
  expect(parseRoomList("").length).toBe(0);
});

// --- Slice 3a: artifact-path/stage parser --------------------------------

test("parseArtifactPath names family + full sub-path + kind for ANY file (no allowlist)", () => {
  // stage is the path WITHIN the family (dirs + basename), so two files in one dir never collide
  expect(parseArtifactPath("greet/report.md")).toEqual({ family: "greet", stage: "report.md", kind: "md" });
  expect(parseArtifactPath("wake-queue-scope/plan/report.md")).toEqual({
    family: "wake-queue-scope",
    stage: "plan/report.md",
    kind: "md",
  });
  expect(parseArtifactPath("greet2/spec-r2/report.md")).toEqual({
    family: "greet2",
    stage: "spec-r2/report.md",
    kind: "md",
  });
  expect(parseArtifactPath("dashboard-design/review.html")).toEqual({
    family: "dashboard-design",
    stage: "review.html",
    kind: "html",
  });
});

test("parseArtifactPath now surfaces the files the old allowlist hid", () => {
  // arbitrary md / json / log / patch / png that used to return null
  expect(parseArtifactPath("greet/spec/notes.md")).toEqual({ family: "greet", stage: "spec/notes.md", kind: "md" });
  expect(parseArtifactPath("shp/review-r3/ship-review.abc.json")).toEqual({
    family: "shp",
    stage: "review-r3/ship-review.abc.json",
    kind: "text",
  });
  expect(parseArtifactPath("shp/evidence/qa-ledger.png")).toEqual({
    family: "shp",
    stage: "evidence/qa-ledger.png",
    kind: "image",
  });
  expect(parseArtifactPath("greet/qa/cases/TC-1/evidence.md")).toEqual({
    family: "greet",
    stage: "qa/cases/TC-1/evidence.md",
    kind: "md",
  });
});

test("parseArtifactPath rejects only a bare family and a traversing/bad family token", () => {
  expect(parseArtifactPath("greet")).toBeNull();
  expect(parseArtifactPath("../etc/report.md")).toBeNull();
});

test("artifactKind classifies by extension (text is the optimistic default)", () => {
  expect(artifactKind("report.md")).toBe("md");
  expect(artifactKind("page.HTML")).toBe("html");
  expect(artifactKind("shot.PNG")).toBe("image");
  expect(artifactKind("evidence.svg")).toBe("image");
  expect(artifactKind("gate.json")).toBe("text");
  expect(artifactKind("run.meta")).toBe("text");
  expect(artifactKind("noext")).toBe("text");
});

// --- Reports folder tree: the pure grouper the client renders ------------

// The grouper only reads {id, mtime}; the rest of the Artifact rides along.
const art = (id: string, mtime: number) => ({ id, mtime, kind: "md" as const });

test("stemRegroup nests a fan-out sub-family under its base, transitively, nav id untouched", () => {
  const list = [
    { id: "pviam-wire/room.md", mtime: 1 },
    { id: "pviam-wire-a/report.md", mtime: 2 },
    { id: "pviam-wire-e34/brief.md", mtime: 3 },
    { id: "pviam-wire-e34-r2/wip.patch", mtime: 4 },
    { id: "other-fam/report.md", mtime: 5 },
  ];
  const out = stemRegroup(list) as any[];
  expect(out[0].gid).toBeUndefined(); // the base itself stays put
  expect(out[1].gid).toBe("pviam-wire/-a/report.md");
  expect(out[1].id).toBe("pviam-wire-a/report.md"); // navigation id untouched
  expect(out[2].gid).toBe("pviam-wire/-e34/brief.md");
  expect(out[3].gid).toBe("pviam-wire/-e34/-r2/wip.patch"); // chains follow their parent
  expect(out[4].gid).toBeUndefined(); // no base present - stays top-level
  const root = groupArtifacts(out);
  expect(root.dirs.length).toBe(2); // pviam-wire + other-fam, not 5 folders
});

test("parseEpicBranches reads the record grammar incl. retirement", () => {
  const rows = parseEpicBranches("repo-a epic/x push=yes staging=rel\nrepo-b crew/x\n");
  expect(rows).toEqual([
    { repo: "repo-a", branch: "epic/x", staging: "rel", push: true, retired: false },
    { repo: "repo-b", branch: "crew/x", staging: "", push: false, retired: false },
  ]);
  const ret = parseEpicBranches("# retired 2026-08-19T00:00:00Z\nrepo-a epic/x\n");
  expect(ret[0].retired).toBe(true);
  expect(parseEpicBranches("")).toEqual([]);
});

test("groupArtifacts nests family -> each sub-dir -> files, keyed by path prefix", () => {
  const root = groupArtifacts([
    art("shp/review-r2/qa/testplan.md", 300),
    art("shp/report.md", 100),
  ]);
  expect(root.dirs.length).toBe(1);
  const fam = root.dirs[0];
  expect(fam.name).toBe("shp");
  expect(fam.key).toBe("shp");
  expect(fam.count).toBe(2);
  // the family's own file stays a leaf of the family node
  expect(fam.files.map((f) => f.name)).toEqual(["report.md"]);
  const rev = fam.dirs[0];
  expect(rev.name).toBe("review-r2");
  expect(rev.key).toBe("shp/review-r2");
  expect(rev.files.length).toBe(0);
  const qa = rev.dirs[0];
  expect(qa.name).toBe("qa");
  expect(qa.key).toBe("shp/review-r2/qa");
  // the leaf label is the file's OWN basename - the dirs are its ancestors
  expect(qa.files.map((f) => f.name)).toEqual(["testplan.md"]);
  expect(qa.files[0].art.id).toBe("shp/review-r2/qa/testplan.md");
});

test("groupArtifacts orders newest-first at BOTH levels (files, and dirs by newest contained)", () => {
  // deliberately scrambled input: the grouper must not depend on arrival order
  const root = groupArtifacts([
    art("f/old/report.md", 100),
    art("f/b.md", 500),
    art("g/report.md", 950),
    art("f/new/report.md", 900),
    art("f/a.md", 700),
  ]);
  // families: g (950) before f (900)
  expect(root.dirs.map((d) => d.name)).toEqual(["g", "f"]);
  const f = root.dirs[1];
  // a node carries the newest mtime it contains, anywhere in its subtree
  expect(f.mtime).toBe(900);
  expect(f.dirs.map((d) => d.name)).toEqual(["new", "old"]);
  expect(f.files.map((x) => x.name)).toEqual(["a.md", "b.md"]);
});

test("groupArtifacts files a pooled lavish page under lavish/<task>", () => {
  const root = groupArtifacts([art("lavish/greet2/review.html", 42)]);
  expect(root.dirs.map((d) => d.name)).toEqual(["lavish"]);
  const task = root.dirs[0].dirs[0];
  expect(task.name).toBe("greet2");
  expect(task.key).toBe("lavish/greet2");
  expect(task.files.map((f) => f.name)).toEqual(["review.html"]);
});

test("groupArtifacts handles a single-file family", () => {
  const root = groupArtifacts([art("solo/report.md", 7)]);
  expect(root.dirs.length).toBe(1);
  expect(root.dirs[0].dirs.length).toBe(0);
  expect(root.dirs[0].files.length).toBe(1);
  expect(root.dirs[0].count).toBe(1);
  expect(root.dirs[0].mtime).toBe(7);
});

// --- html-artifact gate: the ONE rule the client Review button keys on ---

test("isHtmlArtifact accepts an html artifact whatever the case of its extension", () => {
  expect(isHtmlArtifact("/home/data/dashboard-design/review.html")).toBe(true);
  expect(isHtmlArtifact("shp/qa/evidence/index.HTML")).toBe(true);
  expect(isHtmlArtifact("greet/Review.Html")).toBe(true);
});

test("isHtmlArtifact rejects markdown, an extensionless path, and a missing one", () => {
  expect(isHtmlArtifact("/home/data/greet/report.md")).toBe(false);
  expect(isHtmlArtifact("shp/review-r2/qa/testplan.md")).toBe(false);
  // ".html" must be the EXTENSION, not just present somewhere in the path
  expect(isHtmlArtifact("/home/data/html/report.md")).toBe(false);
  expect(isHtmlArtifact("greet/review.html.md")).toBe(false);
  // extensionless, empty, and the unselected-viewer case the client passes
  expect(isHtmlArtifact("/home/data/greet/report")).toBe(false);
  expect(isHtmlArtifact("")).toBe(false);
  expect(isHtmlArtifact(undefined as unknown as string)).toBe(false);
});

// --- reviewable-artifact gate: html or markdown, the same rule the Reports
// viewer's Review button and the Board detail viewer's Review button share ---

test("reviewableArtifact accepts html and markdown, case-insensitively", () => {
  expect(reviewableArtifact("shp/qa/evidence/index.HTML")).toBe(true);
  expect(reviewableArtifact("greet/report.md")).toBe(true);
  expect(reviewableArtifact("greet/report.MD")).toBe(true);
});

test("reviewableArtifact rejects a non-reviewable kind, an extensionless path, and a missing one", () => {
  expect(reviewableArtifact("greet/qa/evidence.png")).toBe(false);
  expect(reviewableArtifact("greet/review/gate.json")).toBe(false);
  expect(reviewableArtifact("greet/implement/build.log")).toBe(false);
  expect(reviewableArtifact("/home/data/greet/report")).toBe(false);
  expect(reviewableArtifact("")).toBe(false);
  expect(reviewableArtifact(undefined as unknown as string)).toBe(false);
});

// --- per-fleet learning cadence: the ONE label both render sites share ---

test("cadenceLabel reads the counters below threshold and does not warn", () => {
  // lab, live on this container: 2 debriefs of 5, curate untouched
  expect(cadenceLabel({ learn: { count: 2, every: 5, due: false }, curate: { count: 0, every: 2, due: false } }))
    .toEqual({ text: "learn 2/5 · curate 0/2", due: false });
});

test("cadenceLabel warns on the DUE flag bash computed, never on its own >=", () => {
  // drydock, live on this container: learn is due, curate is not - one warn line
  expect(cadenceLabel({ learn: { count: 35, every: 5, due: true, last_run: 1784426868 }, curate: { count: 1, every: 2, due: false } }))
    .toEqual({ text: "learn 35/5 · curate 1/2", due: true });
  // curate alone is enough to warn
  expect(cadenceLabel({ learn: { count: 0, every: 5, due: false }, curate: { count: 4, every: 2, due: true } })!.due).toBe(true);
  // the threshold is BASH's: a count at/over `every` with due:false stays quiet,
  // and a count under it with due:true still warns. TS re-derives nothing.
  expect(cadenceLabel({ learn: { count: 9, every: 5, due: false }, curate: { count: 9, every: 2, due: false } })!.due).toBe(false);
  expect(cadenceLabel({ learn: { count: 1, every: 5, due: true }, curate: { count: 0, every: 2, due: false } })!.due).toBe(true);
});

test("cadenceLabel renders NOTHING for an absent or half-formed cadence", () => {
  // an older survey, or a home whose read failed: no line at all, never "0/0"
  expect(cadenceLabel(undefined)).toBeNull();
  expect(cadenceLabel(null)).toBeNull();
  expect(cadenceLabel({})).toBeNull();
  // half a block is still nothing - no "learn 2/5 · curate undefined/undefined"
  expect(cadenceLabel({ learn: { count: 2, every: 5, due: false } })).toBeNull();
  expect(cadenceLabel({ curate: { count: 0, every: 2, due: false } })).toBeNull();
  // a block missing its threshold would have rendered "learn 2/undefined"
  expect(cadenceLabel({ learn: { count: 2 }, curate: { count: 0, every: 2 } })).toBeNull();
});

// --- chief-panel pane auto-fit (font math + true-cols extraction) --------

test("chiefFitPx never exceeds the 15px ceiling", () => {
  expect(chiefFitPx(10, 2000)).toBe(15);
});

test("chiefFitPx never drops below the 9.5px floor", () => {
  expect(chiefFitPx(500, 300)).toBe(9.5);
});

test("chiefFitPx: the true column count yields a LARGER font than the old inflated heuristic (the bug this fixes)", () => {
  // Real pane measured at 232 cols (`herdr pane layout`); the old client
  // heuristic inferred 240 (its hard cap) from a box-drawing run "recent-unwrapped"
  // rejoined across several stacked separator lines - see report.md MEASUREMENT.
  // A bigger cols-than-real means the font is shrunk more than the pane needs,
  // leaving the "half-empty" gap the captain reported.
  const w = 1600; // a realistic chief-panel pixel width
  expect(chiefFitPx(232, w)).toBeGreaterThan(chiefFitPx(240, w));
});

test("paneLayoutCols reads the queried pane's real column count from herdr pane layout JSON", () => {
  const out = JSON.stringify({ result: { layout: { panes: [{ pane_id: "w7X:p3", rect: { width: 232, height: 63 } }] } } });
  expect(paneLayoutCols(out, "w7X:p3")).toBe(232);
});

test("paneLayoutCols picks the QUERIED pane out of a multi-pane layout, never panes[0]", () => {
  const out = JSON.stringify({
    result: { layout: { panes: [{ pane_id: "w7T:p2", rect: { width: 100 } }, { pane_id: "w7T:pB", rect: { width: 232 } }] } },
  });
  expect(paneLayoutCols(out, "w7T:pB")).toBe(232);
});

test("paneLayoutCols returns undefined on malformed JSON, a missing pane, or no width", () => {
  expect(paneLayoutCols("not json", "w7X:p3")).toBeUndefined();
  expect(paneLayoutCols(JSON.stringify({ result: {} }), "w7X:p3")).toBeUndefined();
  expect(paneLayoutCols(JSON.stringify({ result: { layout: { panes: [{ pane_id: "other", rect: { width: 5 } }] } } }), "w7X:p3")).toBeUndefined();
  expect(paneLayoutCols(JSON.stringify({ result: { layout: { panes: [{ pane_id: "w7X:p3", rect: {} }] } } }), "w7X:p3")).toBeUndefined();
});

// --- Slice 3a: markdown -> readable HTML renderer ------------------------

test("renderMarkdown emits headings, paragraphs with hard breaks, and lists", () => {
  const out = renderMarkdown("# Title\n\nline one\nline two\n\n- a\n- b\n\n1. first\n2. second");
  expect(out).toContain("<h1>Title</h1>");
  expect(out).toContain("<p>line one<br>line two</p>");
  expect(out).toContain("<ul><li>a</li><li>b</li></ul>");
  expect(out).toContain("<ol><li>first</li><li>second</li></ol>");
});

test("renderMarkdown keeps fenced code verbatim and escaped", () => {
  const out = renderMarkdown("```ts\nconst x = a < b && c > d;\n```");
  expect(out).toContain('<pre><code class="language-ts">const x = a &lt; b &amp;&amp; c &gt; d;</code></pre>');
  // An info-less fence keeps the bare <code>.
  expect(renderMarkdown("```\nplain\n```")).toContain("<pre><code>plain</code></pre>");
});

test("renderMarkdown formats inline code, bold, italic, and links", () => {
  expect(renderMarkdown("call `parseBacklog(md)` now")).toContain("<code>parseBacklog(md)</code>");
  expect(renderMarkdown("**bold** and *italic*")).toContain("<strong>bold</strong>");
  expect(renderMarkdown("**bold** and *italic*")).toContain("<em>italic</em>");
  const link = renderMarkdown("see [the report](https://example.com/r)");
  expect(link).toContain('<a href="https://example.com/r" rel="noopener">the report</a>');
});

test("renderMarkdown renders a GFM pipe table as thead + tbody", () => {
  const out = renderMarkdown(
    "| # | Sev | Finding |\n|---|:---:|---|\n| 1 | high | leaks |\n| 2 | low | typo |",
  );
  expect(out).toContain("<table>");
  expect(out).toContain("<thead>");
  expect(out).toContain("<tbody>");
  // 3 header cells, 2 rows x 3 body cells
  expect(out.match(/<th\b/g)!.length).toBe(3);
  expect(out.match(/<td\b/g)!.length).toBe(6);
  expect(out).toContain("Finding");
  expect(out).toContain("leaks");
  // alignment comes from the separator, and a wide table scrolls in its own box
  expect(out).toContain('style="text-align:center"');
  expect(out).toContain('class="tablewrap"');
});

test("renderMarkdown runs table cells through the normal escape + inline pipeline", () => {
  const out = renderMarkdown(
    "| what | how |\n| --- | --- |\n| `ac-qa.sh` | **bold** |\n| <script> | a & b |",
  );
  expect(out).toMatch(/<td[^>]*><code>ac-qa\.sh<\/code><\/td>/);
  expect(out).toMatch(/<td[^>]*><strong>bold<\/strong><\/td>/);
  // no second escape path: source HTML stays inert, entities stay entities
  expect(out).toContain("&lt;script&gt;");
  expect(out).not.toContain("<script>");
  expect(out).toContain("a &amp; b");
});

test("renderMarkdown does not mistake a piped paragraph for a table", () => {
  // pipes but NO separator row -> still a paragraph
  const out = renderMarkdown("run a | b | c in the shell\nand then | keep going");
  expect(out).not.toContain("<table>");
  expect(out).toContain("<p>");
  // a bare horizontal rule under a piped line is not a separator either
  expect(renderMarkdown("a | b\n---")).not.toContain("<table>");
});

test("renderMarkdown pads and truncates ragged table rows to the header width", () => {
  const out = renderMarkdown(
    "| a | b | c |\n| --- | --- | --- |\n| only-one |\n| 1 | 2 | 3 | 4 |",
  );
  // both ragged rows land on exactly the header's 3 columns, no throw
  expect(out.match(/<td\b/g)!.length).toBe(6);
  expect(out).toContain("only-one");
  expect(out).not.toContain(">4<");
});

test("renderMarkdown continues a list item across a hard-wrapped continuation line (CommonMark lazy continuation)", () => {
  // Indented to the content column - the diagram.md reproducer shape.
  const indented = renderMarkdown(
    "- not a crewmate: it never does project work itself. It is a crewchief with\n  a narrower domain, so every change still goes to a crewmate it briefs.",
  );
  expect(indented).toBe(
    "<ul><li>not a crewmate: it never does project work itself. It is a crewchief with<br>a narrower domain, so every change still goes to a crewmate it briefs.</li></ul>",
  );
  // Not indented at all - true "lazy" continuation.
  const lazy = renderMarkdown("- first line of the item\nsecond line, flush left");
  expect(lazy).toBe(
    "<ul><li>first line of the item<br>second line, flush left</li></ul>",
  );
  // A second item still starts its own <li> - continuation never bleeds across items.
  const twoItems = renderMarkdown("- a\n  still a\n- b");
  expect(twoItems).toBe("<ul><li>a<br>still a</li><li>b</li></ul>");
});

test("renderMarkdown does not let a list item continuation swallow a real block start", () => {
  expect(renderMarkdown("- item one\n# Heading")).toBe(
    "<ul><li>item one</li></ul>\n<h1>Heading</h1>",
  );
  expect(renderMarkdown("- item one\n```\ncode\n```")).toBe(
    "<ul><li>item one</li></ul>\n<pre><code>code</code></pre>",
  );
  const withTable = renderMarkdown("- item one\n| a | b |\n| --- | --- |\n| 1 | 2 |");
  expect(withTable).toContain("<ul><li>item one</li></ul>");
  expect(withTable).toContain("<table>");
  // A blank line still ends the item's continuation exactly as before.
  expect(renderMarkdown("- item one\n\npara after")).toBe(
    "<ul><li>item one</li></ul>\n<p>para after</p>",
  );
});

test("renderMarkdown ends a list run when the marker kind changes (bullet vs ordered)", () => {
  // A bullet item directly followed by a numbered item is two sibling lists,
  // not one <ul> absorbing a stripped "1." into a second <li>.
  expect(renderMarkdown("- a\n1. b")).toBe(
    "<ul><li>a</li></ul>\n<ol><li>b</li></ol>",
  );
  // The reverse order fails the same way with the roles swapped.
  expect(renderMarkdown("1. a\n- b")).toBe(
    "<ol><li>a</li></ol>\n<ul><li>b</li></ul>",
  );
  // Same-kind runs are unaffected: still one container.
  expect(renderMarkdown("- a\n- b\n1. c\n2. d")).toBe(
    "<ul><li>a</li><li>b</li></ul>\n<ol><li>c</li><li>d</li></ol>",
  );
});

// --- dash-records: ledger-name allowlist guard ---------------------------

test("isRecordLedger passes exactly the five ledgers and rejects everything else", () => {
  // the five fixed records/ ledgers all pass
  for (const name of RECORD_LEDGERS) expect(isRecordLedger(name)).toBe(true);
  // a real fleet file that is NOT a records ledger (mirrors dash-reports scope split)
  expect(isRecordLedger("room.md")).toBe(false);
  expect(isRecordLedger("brief.md")).toBe(false);
  // path escape via the records route is retired: traversal / absolute / nested
  // never pass the name guard (the security boundary, before any path is joined)
  expect(isRecordLedger("../captain.md")).toBe(false);
  expect(isRecordLedger("/etc/passwd")).toBe(false);
  expect(isRecordLedger("records/captain.md")).toBe(false);
  expect(isRecordLedger("")).toBe(false);
});

// --- dash-search: cross-fleet backlog-line matcher ----------------------

test("matchBacklog matches by id + text (case-insensitive) with family + section", () => {
  const md = [
    "# backlog",
    "## In flight",
    "- [ ] dash-search - cross-fleet search box (repo: agent-crew, since 2026-07-19)",
    "- [ ] ep1 [EPIC] - epic order stories: s1,s2",
    "## Queued",
    "- [ ] story-a - alpha work; epic:ep1 (repo: agent-crew)",
    "## Done",
    "- [x] greet - say HELLO to the world - local main (merged 2026-07-01)",
  ].join("\n");

  // by id substring (the line's leading token); family is that id, section its bucket
  const byId = matchBacklog(md, "dash-sea");
  expect(byId.length).toBe(1);
  expect(byId[0].family).toBe("dash-search");
  expect(byId[0].section).toBe("in flight");

  // by text substring (the needle is not in the id)
  const byText = matchBacklog(md, "alpha");
  expect(byText.length).toBe(1);
  expect(byText[0].family).toBe("story-a");
  expect(byText[0].section).toBe("queued");

  // case-insensitive: a lowercase query hits an uppercase line
  const ci = matchBacklog(md, "hello");
  expect(ci.length).toBe(1);
  expect(ci[0].family).toBe("greet");
  expect(ci[0].section).toBe("done");

  // epic line: the family is the epic id, even with the [EPIC] marker present
  const epic = matchBacklog(md, "epic order");
  expect(epic.length).toBe(1);
  expect(epic[0].family).toBe("ep1");
  expect(epic[0].line).toContain("[EPIC]");

  // empty / whitespace query -> [] (no match-everything on a blank box)
  expect(matchBacklog(md, "").length).toBe(0);
  expect(matchBacklog(md, "   ").length).toBe(0);
});

// --- dash-domain-records: crewdomain registry + package records -------------

test("parseCrewdomains reads VALID entries and rejects each INVALID grammar violation with its reason", () => {
  const md = [
    "# Crewdomains",
    "",
    "- payments - billing and invoicing - scope: payment gateway work (added 2026-08-01)",
    "- no-added-suffix - charter - scope: text",
    "- Bad-Charset - charter text - scope: text (added 2026-08-01)",
    "- missing-scope-field just a charter (added 2026-08-01)",
    "- onlyid - scope: text (added 2026-08-01)",
    "- payments - duplicate of the first id - scope: dup (added 2026-08-02)",
    "- has-home - charter - home: /x - scope: text (added 2026-08-01)",
    "not a `- ` entry line, ignored",
  ].join("\n");
  const rows = parseCrewdomains(md);
  expect(rows.length).toBe(7);

  expect(rows[0]).toEqual({
    cls: "VALID", id: "payments", charter: "billing and invoicing",
    scope: "payment gateway work", added: "2026-08-01", reason: "",
  });

  expect(rows[1].cls).toBe("INVALID");
  expect(rows[1].reason).toContain("(added ...)");

  expect(rows[2].cls).toBe("INVALID");
  expect(rows[2].reason).toBe("bad id charset");

  expect(rows[3].cls).toBe("INVALID");
  expect(rows[3].reason).toContain("scope:");

  expect(rows[4].cls).toBe("INVALID");
  expect(rows[4].reason).toBe("missing charter field");

  // second "payments" line: duplicate id
  expect(rows[5].cls).toBe("INVALID");
  expect(rows[5].reason).toBe("duplicate id");

  // an unknown keyed field (home:) invalidates the whole line
  expect(rows[6].cls).toBe("INVALID");
  expect(rows[6].reason).toContain("home:");

  // every INVALID row's id carries the VERBATIM source line (captain reads it as-is)
  expect(rows[1].id).toBe("- no-added-suffix - charter - scope: text");
});

test("parseCrewdomains: registry absent/empty both yield []", () => {
  expect(parseCrewdomains("")).toEqual([]);
  expect(parseCrewdomains("# Crewdomains\n\nno entries here\n")).toEqual([]);
});

// Differential test against the actual authority: parseCrewdomains claims to
// be a second READER of ac_domain_parse's grammar (bin/ac-lib.sh:497-550),
// never a second grammar - so its (cls, reason) sequence must match the real
// bash function's, byte-for-byte input included (a naive rstrip once made
// this diverge on trailing whitespace / CRLF, since ac_domain_parse anchors
// on the RAW line). Skips cleanly when bash is unavailable, same as
// tests/dashboard.test.sh's own bun-availability guard.
test.skipIf(!Bun.which("bash"))(
  "parseCrewdomains matches ac_domain_parse's (cls, reason) sequence over every reason class, including trailing-whitespace/CRLF lines",
  () => {
    const root = mkdtempSync(`${tmpdir()}/ac-dash-domain-authority-`);
    try {
      const fixture = [
        "# Crewdomains",
        "",
        "- payments - billing and invoicing - scope: payment gateway work (added 2026-08-01)",
        "- no-added-suffix - charter - scope: text",
        "- Bad-Charset - charter text - scope: text (added 2026-08-01)",
        "- missing-scope-field just a charter (added 2026-08-01)",
        "- onlyid - scope: text (added 2026-08-01)",
        "- payments - duplicate of the first id - scope: dup (added 2026-08-02)",
        "- has-home - charter - home: /x - scope: text (added 2026-08-01)",
        "- trailing-space - charter - scope: text (added 2026-08-01) ", // F1: one trailing space after ")"
        "- crlf-one - charter - scope: text (added 2026-08-01)\r", // F1: CRLF line ending
        "not a `- ` entry line, ignored",
      ].join("\n");
      const file = `${root}/crewdomains.md`;
      writeFileSync(file, fixture);
      const md = readFileSync(file, "utf8"); // byte-identical input to both parsers

      const binDir = import.meta.dir; // this test file lives in bin/, same as ac-lib.sh
      const proc = Bun.spawnSync(
        ["bash", "-c", '. "$1/ac-lib.sh"; ac_domain_parse "$2"', "--", binDir, file],
        { stdout: "pipe", stderr: "pipe" },
      );
      expect(proc.exitCode).toBe(0);
      const authority = proc.stdout.toString("utf8").split("\n")
        .filter((l) => l.length > 0)
        .map((l) => { const f = l.split("\t"); return { cls: f[0], reason: f[4] ?? "" }; });

      const mine = parseCrewdomains(md).map((r) => ({ cls: r.cls, reason: r.reason }));

      expect(authority.length).toBeGreaterThan(0); // the fixture must actually exercise the grammar
      expect(mine).toEqual(authority);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  },
);

test("domainProjectLinks reports each projects/ symlink's name, resolved target, and dangling state", () => {
  const root = mkdtempSync(`${tmpdir()}/ac-dash-domain-links-`);
  try {
    const clone = `${root}/projects/alpha`;
    mkdirSync(clone, { recursive: true });
    const pkg = `${root}/crewdomains/d1`;
    mkdirSync(`${pkg}/projects`, { recursive: true });
    symlinkSync(clone, `${pkg}/projects/alpha`);
    symlinkSync(`${root}/projects/alpha.yaml`, `${pkg}/projects/alpha.yaml`); // no real target -> dangling
    const links = domainProjectLinks(pkg).sort((a, b) => a.name.localeCompare(b.name));
    expect(links.length).toBe(2);
    // target is the fully-resolved canonical path (realpathSync) - compare
    // against that, not the raw temp-dir string, since /tmp itself may be a
    // symlink (macOS: /tmp -> /private/tmp).
    expect(links[0]).toEqual({ name: "alpha", target: realpathSync(clone), dangling: false });
    expect(links[1].name).toBe("alpha.yaml");
    expect(links[1].dangling).toBe(true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("domainProjectLinks: no projects/ dir -> []", () => {
  const root = mkdtempSync(`${tmpdir()}/ac-dash-domain-links-`);
  try {
    expect(domainProjectLinks(`${root}/crewdomains/nope`)).toEqual([]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});



// --- dash-config: editable-knob allowlist (the security boundary) ----------

test("isEditableConfig passes exactly the editable knobs and rejects everything else", () => {
  // every allowlisted knob passes
  for (const name of EDITABLE_CONFIG) expect(isEditableConfig(name)).toBe(true);
  // per-role verification knobs, renamed to the gate-* shape and completed with
  // agent+effort (captain ruling, routed-pane-rules-for-gate-codereview-
  // roomchief TASK 2): <role>-{agent,model,effort} for codereview and qa.
  for (const role of ["codereview", "qa"])
    for (const knob of ["agent", "model", "effort"])
      expect(isEditableConfig(`${role}-${knob}`)).toBe(true);
  // the PRE-RENAME names are gone - nothing resolves them any more, so the
  // editor must not offer a knob whose value no consumer would read.
  expect(isEditableConfig("model-codereview")).toBe(false);
  expect(isEditableConfig("model-qa")).toBe(false);
  expect(isEditableConfig("model-ship")).toBe(false);
  // the fleet's default crew harness is surfaced (captain: "model agent"); it is
  // the EXISTING crew-harness knob, never a new duplicate `agent` key.
  expect(isEditableConfig("crew-harness")).toBe(true);
  expect(isEditableConfig("agent")).toBe(false);
  // identity/transport scalars are now editable (captain widened the allowlist)
  expect(isEditableConfig("captain")).toBe(true);
  expect(isEditableConfig("slack-captain-id")).toBe(true);
  expect(isEditableConfig("slack-channel")).toBe(true);
  // the hook SCRIPTS are multi-line executables - never editable here
  expect(isEditableConfig("remote-poll")).toBe(false);
  expect(isEditableConfig("remote-ack")).toBe(false);
  expect(isEditableConfig("remote-reply")).toBe(false);
  // the editor can never edit its own receipt log
  expect(isEditableConfig(".dash-edits.log")).toBe(false);
  // path escape never passes the name guard (before any path is joined)
  expect(isEditableConfig("../flow")).toBe(false);
  expect(isEditableConfig("/etc/passwd")).toBe(false);
  expect(isEditableConfig("config/flow")).toBe(false);
  expect(isEditableConfig("")).toBe(false);
});

// --- dash-config: write path + durable receipt -----------------------------

function tmpHome(): string {
  const home = mkdtempSync(`${tmpdir()}/dash-config-`);
  mkdirSync(`${home}/config`, { recursive: true });
  return home;
}

test("applyConfigWrite writes an editable knob and appends a well-formed receipt", () => {
  const home = tmpHome();
  try {
    writeFileSync(`${home}/config/flow`, "staged\n");
    const res = applyConfigWrite(home, "flow", "direct");
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
    // the value file is now the new flat value
    expect(readFileSync(`${home}/config/flow`, "utf8").trim()).toBe("direct");
    // a single well-formed receipt line: <ISO-8601-UTC>\t<file>\t<old> -> <new>
    const log = readFileSync(`${home}/config/.dash-edits.log`, "utf8").split("\n").filter((l) => l.trim());
    expect(log.length).toBe(1);
    const parts = log[0].split("\t");
    expect(parts.length).toBe(3);
    expect(Number.isNaN(Date.parse(parts[0]))).toBe(false);
    expect(parts[1]).toBe("flow");
    expect(parts[2]).toBe("staged -> direct");
    // the POST response carries the receipt line the UI shows immediately
    expect(res.body.receipt).toBe(log[0]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("applyConfigWrite refuses a non-allowlisted name and writes NOTHING", () => {
  const home = tmpHome();
  try {
    // still-excluded: the hook SCRIPTS and the receipt log (captain is editable now)
    const hook = "#!/usr/bin/env bash\necho hi\n";
    writeFileSync(`${home}/config/remote-poll`, hook);
    for (const name of ["remote-poll", "remote-ack", ".dash-edits.log"]) {
      const res = applyConfigWrite(home, name, "hacked");
      expect(res.status).toBe(403);
    }
    // nothing was written: the excluded hook script is byte-identical, no receipt log created
    expect(readFileSync(`${home}/config/remote-poll`, "utf8")).toBe(hook);
    expect(existsSync(`${home}/config/.dash-edits.log`)).toBe(false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("CONFIG_KNOB_META covers every editable knob with a description", () => {
  for (const name of EDITABLE_CONFIG) {
    const meta = CONFIG_KNOB_META[name];
    expect(meta, name).toBeDefined();
    expect(meta.desc.length, name).toBeGreaterThan(10);
    if (meta.options) expect(meta.options.length, name).toBeGreaterThan(0);
  }
});

test("applyConfigWrite enforces the knob's closed value set and numeric shape, writing nothing on reject", () => {
  const home = tmpHome();
  try {
    // enum knob: a value outside the set is a 400 naming the set
    const bad = applyConfigWrite(home, "promote", "sometimes");
    expect(bad.status).toBe(400);
    expect(String(bad.body.error)).toContain("always | auto | never");
    expect(existsSync(`${home}/config/promote`)).toBe(false);
    // every declared option is accepted
    for (const v of ["always", "auto", "never"]) {
      expect(applyConfigWrite(home, "promote", v).status).toBe(200);
    }
    // numeric knob: digits only
    expect(applyConfigWrite(home, "room-parallel", "five").status).toBe(400);
    expect(applyConfigWrite(home, "room-parallel", "-1").status).toBe(400);
    expect(applyConfigWrite(home, "room-parallel", "7").status).toBe(200);
    // free-text knob stays free
    expect(applyConfigWrite(home, "model", "opus").status).toBe(200);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("applyConfigWrite enforces flat value integrity (non-empty, single-line) and writes nothing on reject", () => {
  const home = tmpHome();
  try {
    expect(applyConfigWrite(home, "flow", "   ").status).toBe(400); // empty after trim
    expect(applyConfigWrite(home, "flow", "a\nb").status).toBe(400); // newline forbidden
    // a rejected write leaves no file and no receipt behind
    expect(existsSync(`${home}/config/flow`)).toBe(false);
    expect(existsSync(`${home}/config/.dash-edits.log`)).toBe(false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("renderMarkdown is XSS-safe and does not mangle snake_case", () => {
  // raw HTML in source text is escaped, never emitted as a live tag
  const xss = renderMarkdown("<script>alert(1)</script>");
  expect(xss).toContain("&lt;script&gt;");
  expect(xss).not.toContain("<script>");
  // a javascript: link renders as plain text, never as an href
  const bad = renderMarkdown("[x](javascript:alert(1))");
  expect(bad).not.toContain("href");
  // snake_case identifiers must survive - underscores are not stray italics
  const snake = renderMarkdown("the field ac_room_pending and leased_at");
  expect(snake).toContain("ac_room_pending");
  expect(snake).not.toContain("<em>");
  // inline code content is not re-formatted (no bold inside a code span)
  const codespan = renderMarkdown("`a **b** c`");
  expect(codespan).toContain("<code>a **b** c</code>");
});

// --- dashboard-board: backlog-line field parser -----------------------------

test("parseBacklogLine pulls id/text/repo/pr/merged/epic from one raw line", () => {
  const done = "- [x] evidence-harness [EPIC->1 task] - P0 harness - https://github.com/o/r/pull/2 (merged 2026-08-02)";
  const f = parseBacklogLine(done);
  expect(f.id).toBe("evidence-harness");
  expect(f.text).toContain("P0 harness");
  expect(f.pr).toBe("https://github.com/o/r/pull/2");
  expect(f.merged).toBe("2026-08-02");
  expect(f.isEpic).toBe(true);
  expect(f.epic).toBe(""); // an epic line carries [EPIC], not an epic:<id> membership

  const story = "- [ ] story-a - alpha work; epic:ep1 (repo: agent-crew, since 2026-08-02)";
  const s = parseBacklogLine(story);
  expect(s.id).toBe("story-a");
  expect(s.repo).toBe("agent-crew");
  expect(s.epic).toBe("ep1");
  expect(s.isEpic).toBe(false);
  expect(s.pr).toBe("");
  expect(s.merged).toBe("");

  // a non-task line yields an empty id, never throws
  expect(parseBacklogLine("notes that are not a task line").id).toBe("");
  expect(parseBacklogLine("").id).toBe("");

  // the TEXT boundary is the first " - " AFTER the leading run: a prose
  // group carrying " - " inside (verbatim quote, dated provenance) used to
  // cut the text mid-bracket ("...append]" on the backlog page)
  const prose = '- [ ] t [NOTE 2026-08-08, verbatim "x -> y - z"] [src:cap rev:no] - the real text (repo: alpha)';
  expect(parseBacklogLine(prose).text).toBe("the real text (repo: alpha)");
  expect(parseBacklogLine(prose).contract).toBe("src:cap rev:no");
});

test("parseBacklogLine extracts the delivery-contract group (S1 grammar, awk-twin semantics)", () => {
  // the full group, coexisting with everything else on a real row
  const full = "- [ ] t1 [src:cap flow:direct mode:local-only rev:no qa:no] - do it (repo: alpha)";
  expect(parseBacklogLine(full).contract).toBe("src:cap flow:direct mode:local-only rev:no qa:no");
  expect(parseBacklogLine(full).repo).toBe("alpha"); // sibling fields undisturbed
  // coexists with [EPIC...] and [@held] groups - they keep their class
  expect(parseBacklogLine("- [ ] t2 [EPIC 3 stories] [src:cap] - x").contract).toBe("src:cap");
  expect(parseBacklogLine("- [ ] t3 [@held] [mode:direct-pr] - x").contract).toBe("mode:direct-pr");
  // provenance prose is not all-keyed - never the contract
  expect(parseBacklogLine("- [ ] t4 [CAPTAIN-ORDERED 2026-07-30] - x").contract).toBe("");
  // outside the leading run (past " - ") position denies authority
  expect(parseBacklogLine("- [ ] t5 - text mentions [mode:local-only] later").contract).toBe("");
  // a backtick-wrapped group is a documentation mention, never the token
  expect(parseBacklogLine("- [ ] t6 `[src:cap]` - quoted").contract).toBe("");
  // first all-keyed group wins
  expect(parseBacklogLine("- [ ] t7 [src:cap] [mode:crew-ship] - x").contract).toBe("src:cap");
  // an unknown key breaks the all-keyed discriminator for that group
  expect(parseBacklogLine("- [ ] t8 [src:cap bogus:v] - x").contract).toBe("");
  // a non-task line never yields a contract
  expect(parseBacklogLine("prose with [src:cap] inside").contract).toBe("");
});

test("contractTokens splits a group into ordered {k,v} chip pairs", () => {
  expect(contractTokens("src:cap mode:local-only")).toEqual([
    { k: "src", v: "cap" },
    { k: "mode", v: "local-only" },
  ]);
  expect(contractTokens("")).toEqual([]);
  expect(contractTokens("rev:no")).toEqual([{ k: "rev", v: "no" }]);
});

// --- dashboard-board: five-state story derivation (board-epic-story-legibility-v2) --

test("storyState reads in_flight/queued straight off the section", () => {
  expect(storyState("- [ ] a - alpha; epic:e", "in_flight")).toBe("in_flight");
  expect(storyState("- [ ] a - alpha; epic:e", "queued")).toBe("queued");
});

test("storyState distinguishes done/failed/abandoned within the done section", () => {
  expect(storyState("- [x] a - alpha; epic:e (merged 2026-08-02)", "done")).toBe("done");
  expect(storyState("- [x] a [failed] - alpha; epic:e - why (2026-08-02)", "done")).toBe("failed");
  expect(storyState("- [x] a [abandoned] - alpha; epic:e - why (2026-08-02)", "done")).toBe("abandoned");
  // case-insensitive marker, matching parseBacklog's own [ xX] tolerance
  expect(storyState("- [x] a [FAILED] - alpha; epic:e - why", "done")).toBe("failed");
});

test("storyState never false-positives on the marker word appearing in the description", () => {
  // the marker only counts BEFORE the first " - " (parseBacklogLine's own text
  // boundary, :443-444) - a description mentioning "failed" past that boundary
  // must not flip a real done story to failed
  expect(storyState("- [x] a - the retry failed once then abandoned the old plan; epic:e", "done")).toBe("done");
});

// --- dashboard-board: staged task-id -> bare family-id normalizer ------------

test("familyOfTaskId strips -chief and -<stage>(-r<n>) suffixes to the bare family", () => {
  expect(familyOfTaskId("evidence-harness-chief")).toBe("evidence-harness");
  expect(familyOfTaskId("evidence-harness-spec")).toBe("evidence-harness");
  expect(familyOfTaskId("greet2-spec-r2")).toBe("greet2"); // stage + review round
  // no recognized suffix -> unchanged
  expect(familyOfTaskId("dashboard-board")).toBe("dashboard-board");
  // -scout is NOT a suffix: a scout id is its own family
  expect(familyOfTaskId("dash-dataviz-scout")).toBe("dash-dataviz-scout");
});

test("familyOfTaskId with a known-family set refuses to mis-fold a real <x>-design family", () => {
  const known = ["plan-first", "plan-first-design", "evidence-harness"];
  // plan-first-design IS a family -> never stripped onto plan-first
  expect(familyOfTaskId("plan-first-design", known)).toBe("plan-first-design");
  // a real staged id strips only because the base is a known family
  expect(familyOfTaskId("evidence-harness-chief", known)).toBe("evidence-harness");
  // a suffixed id whose base is NOT a known family stays whole (no phantom fold)
  expect(familyOfTaskId("orphan-spec", known)).toBe("orphan-spec");
});

test("backlogFamilyIds collects every section's ids once, in ledger order", () => {
  const b = {
    in_flight: ["- [ ] shop - a line (repo: shop, since 2026-08-01)", "not a row"],
    queued: ["- [ ] signup-plan - a family whose NAME ends in a stage token (repo: web)"],
    done: ["- [x] shop - a line - local main (merged 2026-08-02)", "- [x] gateway - x (2026-08-02)"],
  };
  expect(backlogFamilyIds(b)).toEqual(["shop", "signup-plan", "gateway"]);
  expect(backlogFamilyIds({ in_flight: [], queued: [], done: [] })).toEqual([]);
});

test("backlogFamilyIds feeds familyOfTaskId the set that keeps a Processes task link honest", () => {
  // The defect this pair exists to close: with NO set the strip is unconditional,
  // so the real family signup-plan links at a signup that does not exist.
  expect(familyOfTaskId("signup-plan")).toBe("signup");
  const known = backlogFamilyIds({
    in_flight: ["- [ ] signup-plan - x (repo: web)"],
    queued: [],
    done: ["- [x] shop - x - local main (merged 2026-08-02)"],
  });
  expect(familyOfTaskId("signup-plan", known)).toBe("signup-plan"); // the family itself
  expect(familyOfTaskId("shop-chief", known)).toBe("shop"); // a real staged id still folds
  // A task whose family the ledger does not carry stays whole - the Processes row
  // then shows NO task link rather than one pointing at a family that is not there.
  expect(familyOfTaskId("gateway-spec", known)).toBe("gateway-spec");
  expect(known.indexOf("gateway-spec")).toBe(-1);
});

// --- dashboard-board: derived coarse progress (QD2) --------------------------

test("deriveProgress composes section + completed-stage count into a coarse bar", () => {
  expect(deriveProgress({ section: "queued" })).toEqual({ pct: 0, label: "queued" });
  expect(deriveProgress({ section: "done" })).toEqual({ pct: 100, label: "done" });
  expect(deriveProgress({ section: "done", merged: "2026-08-02" }))
    .toEqual({ pct: 100, label: "merged 2026-08-02" });
  // in flight climbs with completed stages, capped below 100
  expect(deriveProgress({ section: "in_flight", stagesDone: 0 })).toEqual({ pct: 10, label: "in flight" });
  expect(deriveProgress({ section: "in_flight", stagesDone: 3 })).toEqual({ pct: 70, label: "in flight" });
  expect(deriveProgress({ section: "in_flight", stagesDone: 9 }).pct).toBe(90);
  // an optional live status line becomes the in-flight label
  expect(deriveProgress({ section: "in_flight", stagesDone: 1, status: "working: spec" }).label)
    .toBe("working: spec");
  // absent/unknown section -> empty, never a stray bar
  expect(deriveProgress({ section: null })).toEqual({ pct: 0, label: "" });
  // same-done-miscount-in-three-more-surfaces: a terminal-but-not-done state
  // must never render as "done" (or a merged date), even though it sits in
  // the Done section - the state param, when given, overrides the section
  // default for exactly the failed/abandoned case.
  expect(deriveProgress({ section: "done", state: "failed", merged: "2026-08-02" }))
    .toEqual({ pct: 100, label: "failed" });
  expect(deriveProgress({ section: "done", state: "abandoned" }))
    .toEqual({ pct: 100, label: "abandoned" });
  // a real done row is unaffected by the new optional param
  expect(deriveProgress({ section: "done", state: "done", merged: "2026-08-02" }))
    .toEqual({ pct: 100, label: "merged 2026-08-02" });
});

// --- dashboard-board: pure family-detail composer (QD3) ----------------------

const artOf = (family: string, stage: string, kind: string) => ({
  family, stage, kind, path: "/home/data/" + family + "/" + stage, id: family + "/" + stage,
});

test("composeFamily joins stage timeline, design html, progress, and reused links", () => {
  const d = composeFamily({
    family: "evidence-harness",
    line: "- [x] evidence-harness [EPIC] - harness - https://github.com/o/r/pull/2 (merged 2026-08-02)",
    section: "done",
    project: "agent-crew",
    artifacts: [
      artOf("evidence-harness", "spec/report.md", "md"),
      artOf("evidence-harness", "arch/report.md", "md"),
      artOf("evidence-harness", "design/design.html", "html"),
      artOf("evidence-harness", "brief.md", "md"), // root file: grouped into the "report" stage
      artOf("other-family", "spec/report.md", "md"), // different family: ignored
    ],
    roomEntries: ["- [t] chief> HANDBACK: landed", "- [t] chief> LANDED: pr#2"],
    children: [
      { id: "eh-be", line: "- [x] eh-be - backend; epic:evidence-harness", section: "done" },
      { id: "eh-fe", line: "- [ ] eh-fe - frontend; epic:evidence-harness", section: "in_flight" },
    ],
    knowledgeRepos: ["agent-crew"],
    learningsCiteFamily: true,
  });

  // stage timeline = the family's subdirs in pipeline order; the design/ dir is a
  // real stage even with only an html (no report.md -> report:"" = incomplete)
  expect(d.stages.map((s) => s.stage)).toEqual(["spec", "arch", "design", "report"]);
  expect(d.stages[0].report).toBe("/home/data/evidence-harness/spec/report.md");
  expect(d.stages[0].id).toBe("evidence-harness/spec/report.md");
  expect(d.stages[2].report).toBe(""); // design stage has no report.md here
  // the same design html ALSO surfaces in the design-artifacts group (linkable)
  expect(d.designHtml.map((h) => h.id)).toEqual(["evidence-harness/design/design.html"]);
  // PR + merged linkified from the line (QD1 link-only, zero network)
  expect(d.pr).toBe("https://github.com/o/r/pull/2");
  expect(d.progress).toEqual({ pct: 100, label: "merged 2026-08-02" });
  // epic rollup from the children's sections
  expect(d.rollup).toEqual({ done: 1, total: 2 });
  expect(d.children.map((c) => c.done)).toEqual([true, false]);
  // room entries carried verbatim + counted
  expect(d.roomCount).toBe(2);
  // reused data is a pointer, never embedded
  expect(d.links).toEqual([
    { label: "repo-knowledge/agent-crew", kind: "knowledge", path: "records/repo-knowledge/agent-crew.md" },
    { label: "learnings ledger", kind: "learnings", path: "learnings.md" },
  ]);
});

test("composeFamily derives fan-out sub-tasks from metas + artifact dirs, excluding stories and the chief", () => {
  const d = composeFamily({
    family: "wire",
    line: "- [ ] wire - connect the app (repo: apps, since 2026-08-18)",
    section: "in_flight",
    project: "apps",
    artifacts: [
      artOf("wire", "room.md", "md"),
      artOf("wire-qa", "report.md", "md"), // artifact-only sub-task (meta pruned)
      artOf("wire", "tasks/n1/report.md", "md"), // tasks/-nested layout unit
      artOf("wire-story", "report.md", "md"), // a real story: excluded from sub-tasks
      artOf("wire-story-qa", "report.md", "md"), // a STORY's own unit: belongs to the story, not the epic
      artOf("wire-scout-chief", "timeline.log", "md"), // a chief dir is never a sub-task
    ],
    roomEntries: [],
    children: [{ id: "wire-story", line: "- [ ] wire-story - s; epic:wire (repo: apps)", section: "in_flight" }],
    knowledgeRepos: [],
    learningsCiteFamily: false,
    tasks: [
      { id: "wire-c", family: "wire", repo: "apps", pr: "https://github.com/o/r/pull/1", prMerged: true, kind: "ship", live: false },
      { id: "wire-e34", family: "wire", repo: "apps", pr: "", prMerged: false, kind: "ship", live: true },
      { id: "wire-chief", family: "wire", repo: "", pr: "https://github.com/o/r/pull/9", prMerged: false, kind: "roomchief", live: true },
      { id: "wire-story", family: "wire", repo: "apps", pr: "", prMerged: false, kind: "ship", live: true },
    ],
  });
  const ids = d.subtasks.map((s) => s.id);
  expect(ids).toEqual(["wire-c", "wire-e34", "wire-n1", "wire-qa"]); // sorted; no story, no story-owned unit, no chief
  const byId: any = {};
  for (const s of d.subtasks) byId[s.id] = s;
  expect(byId["wire-c"].prMerged).toBe(true);
  expect(byId["wire-c"].slug).toBe("c");
  expect(byId["wire-e34"].live).toBe(true);
  expect(byId["wire-qa"].hasReport).toBe(true);
  expect(byId["wire-qa"].live).toBe(false);
  expect(byId["wire-qa"].reportId).toBe("wire-qa/report.md"); // flat legacy path
  expect(byId["wire-n1"].hasReport).toBe(true);
  expect(byId["wire-n1"].reportId).toBe("wire/tasks/n1/report.md"); // nested path
  // and the nested unit never pollutes the stage timeline as a "tasks" stage
  expect(d.stages.some((s) => s.stage === "tasks")).toBe(false);
});

test("composeFamily's rollup counts only real done stories - a [failed]/[abandoned] Done-section story is NOT done (board-rollup-and-overlay-count-failed-as-done)", () => {
  const d = composeFamily({
    family: "fx-epic",
    line: "- [ ] fx-epic [EPIC] - synthetic five-state epic",
    section: "in_flight",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [
      { id: "fx-inflight", line: "- [ ] fx-inflight - a; epic:fx-epic", section: "in_flight" },
      { id: "fx-queued", line: "- [ ] fx-queued - b; epic:fx-epic", section: "queued" },
      { id: "fx-done", line: "- [x] fx-done - c; epic:fx-epic (merged 2026-08-02)", section: "done" },
      { id: "fx-failed", line: "- [x] fx-failed [failed] - d; epic:fx-epic - why (2026-08-02)", section: "done" },
      { id: "fx-abandoned", line: "- [x] fx-abandoned [abandoned] - e; epic:fx-epic - why (2026-08-02)", section: "done" },
    ],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  // only fx-done is a real success: the pre-fix rollup counted every
  // Done-section child (fx-done + fx-failed + fx-abandoned) as "done" -> 3/5.
  expect(d.rollup).toEqual({ done: 1, total: 5 });
  expect(d.children.map((c) => c.state)).toEqual([
    "in_flight", "queued", "done", "failed", "abandoned",
  ]);
  expect(d.children.map((c) => c.done)).toEqual([false, false, true, false, false]);
});

test("composeFamily's OWN progress never claims done for a standalone [failed]/[abandoned] family (same-done-miscount-in-three-more-surfaces)", () => {
  const failed = composeFamily({
    family: "fx-failed-standalone",
    line: "- [x] fx-failed-standalone [failed] - did not land - why (2026-08-03)",
    section: "done",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  // pre-fix this read {pct:100, label:"done"} - indistinguishable from a real
  // success, the exact defect this family fixes on the board's top level.
  expect(failed.progress).toEqual({ pct: 100, label: "failed" });

  const abandoned = composeFamily({
    family: "fx-abandoned-standalone",
    line: "- [x] fx-abandoned-standalone [abandoned] - dropped (2026-08-03)",
    section: "done",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  expect(abandoned.progress).toEqual({ pct: 100, label: "abandoned" });

  // a real done standalone family is unaffected
  const done = composeFamily({
    family: "fx-done-standalone",
    line: "- [x] fx-done-standalone - real success (merged 2026-08-03)",
    section: "done",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  expect(done.progress).toEqual({ pct: 100, label: "merged 2026-08-03" });
});

// --- dashboard-board-v2: plan stage ordering + per-stage artifact lists ------

test("familyStages ranks plan between design and implement (STAGE_ORDER)", () => {
  const { stages } = familyStages(
    [
      artOf("f", "implement/report.md", "md"),
      artOf("f", "design/report.md", "md"),
      artOf("f", "plan/report.md", "md"),
    ],
    "f",
  );
  expect(stages.map((s) => s.stage)).toEqual(["design", "plan", "implement"]);
});

test("familyStages groups every file under its stage (v2 detail tree), not just report.md", () => {
  const { stages, designHtml } = familyStages(
    [
      artOf("f", "design/final-design.html", "html"),
      artOf("f", "design/report.md", "md"),
      artOf("f", "spec/report.md", "md"),
      artOf("f", "brief.md", "md"), // root file: grouped into the "report" stage (board-detail-shows-every-artifact)
      artOf("other", "design/x.html", "html"), // other family: ignored
    ],
    "f",
  );
  expect(stages.map((s) => s.stage)).toEqual(["spec", "design", "report"]);
  const design = stages.find((s) => s.stage === "design")!;
  expect(design.artifacts.map((a) => a.name).sort()).toEqual(["final-design.html", "report.md"]);
  expect(design.report).toBe("/home/data/f/design/report.md"); // report.md still marks the stage complete
  const report = stages.find((s) => s.stage === "report")!;
  expect(report.artifacts.map((a) => a.name)).toEqual(["brief.md"]);
  expect(report.report).toBe(""); // no report.md at root here, so the stage stays "incomplete"
  expect(designHtml.map((h) => h.id)).toEqual(["f/design/final-design.html"]);
});

test("familyStages surfaces every family-root file under the report stage, excluding *.session.json review-loop sidecars (board-detail-shows-every-artifact)", () => {
  const { stages } = familyStages(
    [
      artOf("f", "report.md", "md"),
      artOf("f", "report.html", "html"),
      artOf("f", "room.md", "md"),
      artOf("f", "timeline.log", "text"),
      artOf("f", "report.md.session.json", "text"),
      artOf("f", "report.html.session.json", "text"),
    ],
    "f",
  );
  expect(stages.map((s) => s.stage)).toEqual(["report"]);
  const report = stages[0];
  expect(report.artifacts.map((a) => a.name).sort()).toEqual(
    ["report.html", "report.md", "room.md", "timeline.log"],
  );
  expect(report.report).toBe("/home/data/f/report.md"); // stagesDone still keys on report.md exactly
});

test("composeFamily enriches each epic child with its own repo, PR, and stages (multi-repo story tree)", () => {
  const d = composeFamily({
    family: "pin-auth",
    line: "- [x] pin-auth [EPIC] - PIN auth",
    section: "done",
    project: "agent-crew",
    artifacts: [
      artOf("pin-be", "plan/report.md", "md"),
      artOf("pin-be", "implement/report.md", "md"),
      artOf("pin-fe", "plan/report.md", "md"),
    ],
    roomEntries: [],
    children: [
      { id: "pin-be", line: "- [x] pin-be - BE; epic:pin-auth (repo: services, https://github.com/o/r/pull/266)", section: "done" },
      { id: "pin-fe", line: "- [ ] pin-fe - FE; epic:pin-auth (repo: webapp)", section: "in_flight" },
    ],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  const be = d.children[0];
  expect(be.repo).toBe("services");
  expect(be.pr).toBe("https://github.com/o/r/pull/266");
  expect(be.stages.map((s) => s.stage)).toEqual(["plan", "implement"]);
  const fe = d.children[1];
  expect(fe.repo).toBe("webapp");
  expect(fe.pr).toBe("");
  expect(fe.stages.map((s) => s.stage)).toEqual(["plan"]);
});

// --- board-detail-repos-prs: every repo, every PR --------------------------

test("familyRepos unions the line token, the member tasks and the stories - one list both callers share", () => {
  const repos = familyRepos(
    "multi",
    [{ repo: "gateway" }, { repo: "api-services" }, { repo: "api-services" }],
    [{ line: "- [ ] signup-web - FE; epic:signup (repo: webapp)" }, { line: "- [ ] signup-x - no repo token" }],
  );
  expect(repos).toEqual(["gateway", "api-services", "webapp"]); // deduped, `multi` dropped, token-less child skipped
  expect(familyRepos("multi", [], [])).toEqual([]); // the placeholder alone names nothing
});

test("isRepoKnowledge admits a per-project record and refuses every path that could climb out", () => {
  expect(isRepoKnowledge("repo-knowledge/api-services.md")).toBe(true);
  expect(isRepoKnowledge("repo-knowledge/a.b_c-1.md")).toBe(true);
  expect(isRepoKnowledge("repo-knowledge/../captain.md")).toBe(false); // a slash is what leaving needs
  expect(isRepoKnowledge("repo-knowledge/sub/x.md")).toBe(false);
  expect(isRepoKnowledge("repo-knowledge/.hidden.md")).toBe(false);
  expect(isRepoKnowledge("repo-knowledge/x.txt")).toBe(false);
  expect(isRepoKnowledge("../records/repo-knowledge/x.md")).toBe(false);
  expect(isRepoKnowledge("repo-knowledge/")).toBe(false);
  expect(isRepoKnowledge("captain.md")).toBe(false); // the five ledgers stay isRecordLedger's job
});

test("learningsCiteFamily matches a family as a whole token, so an epic id never matches inside its stories", () => {
  const ledger = "- lesson one (by: shop-checkout, first-hand)\n- prose naming shop-signup\n";
  expect(learningsCiteFamily(ledger, "shop-checkout")).toBe(true);
  expect(learningsCiteFamily(ledger, "shop-signup")).toBe(true); // cited in prose, not by the (by:) shape
  expect(learningsCiteFamily(ledger, "shop")).toBe(false); // the epic itself is never named
  expect(learningsCiteFamily(ledger, "checkout")).toBe(false); // a suffix is not a citation
  expect(learningsCiteFamily("", "shop")).toBe(false);
  expect(learningsCiteFamily(ledger, "")).toBe(false);
});

test("composeFamily links one knowledge record per repo and drops the learnings row when the ledger never names the family", () => {
  const base = {
    family: "signup",
    line: "- [ ] signup - sign-up flow (repo: multi, since 2026-08-05)",
    section: "in_flight",
    project: "",
    artifacts: [],
    roomEntries: [],
    children: [],
    tasks: [
      { id: "signup", family: "signup", repo: "gateway", pr: "", prMerged: false },
      { id: "signup-api", family: "signup", repo: "api-services", pr: "", prMerged: false },
    ],
  };
  const multi = composeFamily({ ...base, knowledgeRepos: ["gateway", "api-services"], learningsCiteFamily: false });
  expect(multi.links).toEqual([
    { label: "repo-knowledge/gateway", kind: "knowledge", path: "records/repo-knowledge/gateway.md" },
    { label: "repo-knowledge/api-services", kind: "knowledge", path: "records/repo-knowledge/api-services.md" },
  ]); // a `repo: multi` family used to link NONE of them
  const cited = composeFamily({ ...base, knowledgeRepos: [], learningsCiteFamily: true });
  expect(cited.links).toEqual([{ label: "learnings ledger", kind: "learnings", path: "learnings.md" }]);
});

test("taskFamilyOf resolves a per-repo sibling onto its family and never folds a story onto its epic", () => {
  const known = ["shop", "shop-signup", "shop-checkout"];
  expect(taskFamilyOf("shop-signup-api", known)).toBe("shop-signup"); // ad-hoc suffix, no stage list
  expect(taskFamilyOf("shop-signup", known)).toBe("shop-signup");
  expect(taskFamilyOf("shop-checkout", known)).toBe("shop-checkout"); // a story is its OWN family, never the epic's task
  expect(taskFamilyOf("shop-checkout-implement", known)).toBe("shop-checkout");
  expect(taskFamilyOf("unrelated-task", known)).toBe(""); // no known prefix: contributes nothing
});

test("composeFamily unions every repo the family touches and drops the `multi` placeholder", () => {
  const d = composeFamily({
    family: "signup",
    line: "- [ ] signup - sign-up flow (repo: multi, since 2026-08-05)",
    section: "in_flight",
    project: "",
    artifacts: [],
    roomEntries: [],
    children: [{ id: "signup-web", line: "- [ ] signup-web - FE; epic:signup (repo: webapp)", section: "in_flight" }],
    knowledgeRepos: [],
    learningsCiteFamily: false,
    tasks: [
      { id: "signup", family: "signup", repo: "gateway", pr: "", prMerged: false },
      { id: "signup-api", family: "signup", repo: "api-services", pr: "", prMerged: false },
      { id: "signup-api-r2", family: "signup", repo: "api-services", pr: "", prMerged: false },
    ],
  });
  expect(d.repos).toEqual(["gateway", "api-services", "webapp"]); // deduped, `multi` never listed
  expect(d.repo).toBe("multi"); // the raw token is untouched for the one-string surfaces
});

test("composeFamily lists every PR the crew raised - task metas plus the backlog lines, deduped", () => {
  const d = composeFamily({
    family: "signup",
    line: "- [x] signup - sign-up flow - https://github.com/o/gateway/pull/86 (merged 2026-08-04)",
    section: "done",
    project: "",
    artifacts: [],
    roomEntries: [],
    // the line's FIRST link is not the repo its own token names - the PR row must follow the URL
    children: [{ id: "signup-web", line: "- [x] signup-web - FE; epic:signup (repo: webapp) - https://github.com/o/webapp-legacy/pull/12 + https://github.com/o/webapp/pull/13 (merged 2026-08-04)", section: "done" }],
    knowledgeRepos: [],
    learningsCiteFamily: false,
    tasks: [
      { id: "signup", family: "signup", repo: "gateway", pr: "https://github.com/o/gateway/pull/86", prMerged: true },
      { id: "signup-api", family: "signup", repo: "api-services", pr: "https://github.com/o/api/pull/297", prMerged: true },
      { id: "signup-billing", family: "signup", repo: "billing", pr: "https://github.com/o/billing/pull/359", prMerged: false },
    ],
  });
  expect(d.prs.map((p) => p.url)).toEqual([
    "https://github.com/o/gateway/pull/86", // the meta wins over the identical line link - it knows the task + merged state
    "https://github.com/o/api/pull/297",
    "https://github.com/o/billing/pull/359",
    "https://github.com/o/webapp-legacy/pull/12",
  ]);
  expect(d.prs[0].task).toBe("signup");
  expect(d.prs[2].merged).toBe(false);
  expect(d.prs[3]).toEqual({ url: "https://github.com/o/webapp-legacy/pull/12", repo: "webapp-legacy", task: "", family: "signup-web", merged: true });
  expect(d.pr).toBe("https://github.com/o/gateway/pull/86"); // the single-link field is unchanged
});

test("collectFamilyTasks reads live + archived metas, prefers fleet_scope, and skips a chief's project (it names the family, not a repo)", () => {
  const home = tmpHome();
  try {
    mkdirSync(`${home}/state/archive/signup-api`, { recursive: true });
    mkdirSync(`${home}/state/archive/checkout`, { recursive: true });
    writeFileSync(`${home}/state/signup.meta`, "project=gateway\nfleet_scope=signup\npr=https://github.com/o/gateway/pull/86\n");
    writeFileSync(`${home}/state/signup-chief.meta`, "project=signup\nkind=roomchief\n"); // ac-spawn.sh:1126 - the FAMILY, never a repo
    writeFileSync(`${home}/state/archive/signup-api/meta`, "project=api-services\npr=https://github.com/o/api/pull/297\npr_merged=1\n"); // no fleet_scope -> prefix
    writeFileSync(`${home}/state/archive/checkout/meta`, "project=other\nfleet_scope=checkout\n"); // another family
    const rows = collectFamilyTasks(home, ["signup"], ["signup", "checkout"]);
    expect(rows).toEqual([
      { id: "signup", family: "signup", repo: "gateway", pr: "https://github.com/o/gateway/pull/86", prMerged: false, kind: "", live: true },
      { id: "signup-api", family: "signup", repo: "api-services", pr: "https://github.com/o/api/pull/297", prMerged: true, kind: "", live: false },
    ]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("composeFamily renders a flat in-flight family with no stored line", () => {
  const d = composeFamily({
    family: "dash-dataviz-scout",
    line: "- [x] dash-dataviz-scout - REPORTED map (reported 2026-08-02)",
    section: "done",
    project: "agent-crew",
    artifacts: [artOf("dash-dataviz-scout", "report.md", "md")],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  // a flat family surfaces its root report.md as the "report" stage
  expect(d.stages.map((s) => s.stage)).toEqual(["report"]);
  expect(d.stages[0].report).toBe("/home/data/dash-dataviz-scout/report.md");
  expect(d.rollup).toBeNull();
  expect(d.links).toEqual([]);
  expect(d.roomCount).toBe(0);
});

// --- task-timeline: the durable per-task lifecycle timeline ------------------

test("parseTimeline orders events and computes per-step deltas", () => {
  const evs = parseTimeline(
    "2026-08-02T10:00:00Z working: spawned\n" +
      "2026-08-02T10:01:30Z delivered\n" +
      "2026-08-02T10:01:40Z resolved: teardown\n",
  );
  expect(evs.map((e) => e.line)).toEqual([
    "working: spawned",
    "delivered",
    "resolved: teardown",
  ]);
  expect(evs[0].deltaMs).toBe(0); // first event has no prior step
  expect(evs[1].deltaMs).toBe(90000); // 90s
  expect(evs[2].deltaMs).toBe(10000); // 10s
});

test("parseTimeline dedupes the status/timeline mirror and sorts by timestamp", () => {
  const dup = "2026-08-02T10:00:00Z working: spawned";
  const evs = parseTimeline(
    "2026-08-02T10:02:00Z landed\n" + dup + "\n" + dup + "\n",
  );
  expect(evs.map((e) => e.line)).toEqual(["working: spawned", "landed"]); // deduped + sorted
});

test("parseTimeline ignores blank, timestamp-less, and space-only lines", () => {
  const evs = parseTimeline("\n   \nnospace\n2026-08-02T10:00:00Z ok\n");
  expect(evs.length).toBe(1);
  expect(evs[0].line).toBe("ok");
});

test("composeFamily surfaces the parsed timeline from timelineText", () => {
  const d = composeFamily({
    family: "task-timeline",
    line: "- [ ] task-timeline - durable timeline (repo: agent-crew, since 2026-08-02)",
    section: "in_flight",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
    timelineText:
      "2026-08-02T10:00:00Z working: spawned\n2026-08-02T10:05:00Z delivered\n",
  });
  expect(d.timeline.length).toBe(2);
  expect(d.timeline[1].deltaMs).toBe(300000); // 5m
});

test("composeFamily defaults timeline to [] when no timelineText is given", () => {
  const d = composeFamily({
    family: "x",
    line: null,
    section: "queued",
    project: "agent-crew",
    artifacts: [],
    roomEntries: [],
    children: [],
    knowledgeRepos: [],
    learningsCiteFamily: false,
  });
  expect(d.timeline).toEqual([]);
});

// --- gate-dash-monitor: per-family gate state for the Processes route --------

// --- dash-crew-dispatch: the structured crew-dispatch.json write --------------

test("applyDispatchWrite writes canonical JSON + a receipt for a valid document", () => {
  const home = tmpHome();
  try {
    const doc = {
      rules: [
        { when: "financial paths", use: { harness: "claude", model: "opus", effort: "ultracode" }, why: "rigor" },
        { when: "round-robin", use: [{ harness: "claude" }, { harness: "codex" }] },
      ],
      default: { harness: "claude" },
    };
    const res = applyDispatchWrite(home, JSON.stringify(doc));
    expect(res.status).toBe(200);
    const written = readFileSync(`${home}/config/crew-dispatch.json`, "utf8");
    expect(written.endsWith("\n")).toBe(true); // trailing newline
    expect(JSON.parse(written)).toEqual(doc); // round-trips exactly
    expect(written).toContain('\n  "rules"'); // canonical 2-space pretty-print
    const log = readFileSync(`${home}/config/.dash-edits.log`, "utf8").trim().split("\n");
    expect(log[log.length - 1]).toContain("crew-dispatch.json");
    expect(log[log.length - 1]).toContain("2 rules");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("readDispatch surfaces the `panes` block in file order (the UI's pane cards)", () => {
  const home = tmpHome();
  try {
    const doc = {
      rules: [{ when: "x", use: { harness: "claude" } }],
      default: { harness: "claude" },
      panes: {
        qa: { harness: "opencode", model: "openrouter/moonshotai/kimi-k3" },
        gate: { harness: "codex", model: "gpt-5.6-sol", effort: "xhigh" },
      },
    };
    writeFileSync(`${home}/config/crew-dispatch.json`, JSON.stringify(doc));
    const v = readDispatch(home);
    expect(v.exists).toBe(true);
    expect(v.panes.map((p) => p.kind)).toEqual(["qa", "gate"]); // object insertion order
    expect(v.panes[0].use).toEqual(doc.panes.qa);
    expect(v.panes[0].routed).toBe(false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("readDispatch derives routed QA rule cards and a separate bare default", () => {
  const home = tmpHome();
  try {
    const qa = {
      rules: [
        {
          when: "browser evidence",
          use: { harness: "opencode", model: "openrouter/qwen/qwen3.7-plus" },
          why: "image-capable QA",
        },
      ],
      default: { harness: "opencode", model: "openrouter/qwen/qwen3.7-plus" },
    };
    writeFileSync(`${home}/config/crew-dispatch.json`, JSON.stringify({
      rules: [{ when: "x", use: { harness: "claude" } }],
      panes: { qa },
    }));
    const pane = readDispatch(home).panes[0];
    expect(pane.kind).toBe("qa");
    expect(pane.routed).toBe(true);
    expect(pane.use).toBeNull();
    expect(pane.rules).toEqual(qa.rules);
    expect(pane.dflt).toEqual(qa.default);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("readDispatch derives routed cards for the mandatory-default kinds (gate/codereview/roomchief)", () => {
  const home = tmpHome();
  try {
    const gate = {
      rules: [
        { when: "financial or irreversible scope", use: { harness: "codex", model: "gpt-5.6-sol", effort: "xhigh" }, why: "terminal judgment" },
      ],
      default: { harness: "codex", model: "gpt-5.6-sol", effort: "high" },
    };
    const roomchief = {
      rules: [
        { when: "design-heavy family", use: { harness: "claude", model: "opus", effort: "xhigh" }, why: "gate stewardship" },
      ],
      default: { harness: "claude", model: "opus", effort: "high" },
    };
    writeFileSync(`${home}/config/crew-dispatch.json`, JSON.stringify({
      rules: [{ when: "x", use: { harness: "claude" } }],
      // `learning` is OUTSIDE the routable set: a rules-shaped entry there
      // must stay non-routed (the resolver treats it as a flat profile).
      panes: { gate, roomchief, learning: { rules: [{ when: "x", use: { harness: "claude" }, why: "x" }] } },
    }));
    const v = readDispatch(home);
    const byKind = Object.fromEntries(v.panes.map((p) => [p.kind, p]));
    expect(byKind.gate.routed).toBe(true);
    expect(byKind.gate.rules).toEqual(gate.rules);
    expect(byKind.gate.dflt).toEqual(gate.default);
    expect(byKind.roomchief.routed).toBe(true);
    expect(byKind.roomchief.dflt).toEqual(roomchief.default);
    expect(byKind.learning.routed).toBe(false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("applyDispatchWrite mirrors routed_pane_validate: gate/codereview/roomchief need a default", () => {
  const home = tmpHome();
  try {
    const rule = { when: "risky scope", use: { harness: "codex", model: "gpt-5.6-sol", effort: "xhigh" }, why: "depth" };
    const ok = JSON.stringify({
      rules: [{ when: "x", use: { harness: "claude" } }],
      panes: {
        gate: { rules: [rule], default: { harness: "codex", model: "gpt-5.6-sol", effort: "high" } },
        roomchief: { rules: [rule], default: { harness: "claude", model: "opus" } },
      },
    });
    expect(applyDispatchWrite(home, ok).status).toBe(200);
    const bad = [
      // routed gate with NO default (qa is the only optional-default kind)
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { gate: { rules: [rule] } } }),
      // routed roomchief mixing static keys
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { roomchief: { rules: [rule], default: { harness: "claude" }, harness: "claude" } } }),
      // routed codereview rule missing why
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { codereview: { rules: [{ when: "x", use: { harness: "codex" } }], default: { harness: "codex" } } } }),
    ];
    for (const raw of bad) expect(applyDispatchWrite(home, raw).status).toBe(400);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("readDispatch returns panes:[] when the block is absent or not a plain object", () => {
  const home = tmpHome();
  try {
    // absent block
    writeFileSync(`${home}/config/crew-dispatch.json`, JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }] }));
    expect(readDispatch(home).panes).toEqual([]);
    // panes is an array (malformed) -> [], never a crash
    writeFileSync(`${home}/config/crew-dispatch.json`, JSON.stringify({ rules: [], panes: [1, 2] }));
    expect(readDispatch(home).panes).toEqual([]);
    // missing file -> exists:false, panes:[]
    rmSync(`${home}/config/crew-dispatch.json`);
    const v = readDispatch(home);
    expect(v.exists).toBe(false);
    expect(v.panes).toEqual([]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("applyDispatchWrite rejects every malformed document and writes NOTHING", () => {
  const home = tmpHome();
  try {
    const bad = [
      "{not json", // invalid JSON
      JSON.stringify([1, 2]), // top level is not an object
      JSON.stringify({ rules: [] }), // empty rules
      JSON.stringify({ rules: [{ use: { harness: "claude" } }] }), // rule has no `when`
      JSON.stringify({ rules: [{ when: "x", use: { model: "opus" } }] }), // use names no harness
      JSON.stringify({ rules: [{ when: "x", use: [{ harness: "claude" }, { model: "x" }] }] }), // an array profile lacks a harness
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { qa: { rules: [] } } }),
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { qa: { rules: [{ when: "x", use: [{ harness: "opencode" }], why: "x" }] } } }),
      JSON.stringify({ rules: [{ when: "x", use: { harness: "claude" } }], panes: { qa: { rules: [{ when: "x", use: { harness: "opencode" }, why: "x" }], harness: "claude" } } }),
    ];
    for (const raw of bad) expect(applyDispatchWrite(home, raw).status).toBe(400);
    // no gate ever wrote the file or a receipt
    expect(existsSync(`${home}/config/crew-dispatch.json`)).toBe(false);
    expect(existsSync(`${home}/config/.dash-edits.log`)).toBe(false);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

// story 2.4 dashboard-verifier-kind-hardcode: the top-level verify[] array
// ac-fleets.sh --json emits (2.1) buckets into its OWN Processes row, never a
// crew one. verifyProcessRows is the one place that reads the bucket off the
// wire (no verify-* prefix matching in TypeScript). Everything downstream in
// pageProcesses keys off row.kind==='crew' (badge :2505 unchanged, backlog +
// reports links :2538 unchanged) or row.room (attention filter :2481
// unchanged) - so a `kind:'verify', room:null` row proven here is provably
// excluded from crew-only links without touching those branches because
// `row.kind==='crew'` short-circuits false. A verifier may carry its supervising
// family in `row.room` so attention can surface a blocked family. The expand
// key (`row.kind+':'+row.id`, :2503, also unchanged)
// therefore comes out `verify:<id>`, never `crew:<id>`.
test("verifyProcessRows buckets a verify[] wire entry as kind 'verify', never 'crew'", () => {
  const rows = verifyProcessRows([{ id: "v1", kind: "verify-codereview", project: "agent-crew", status: "running", caller: "flow-implement", family: "flow", ref: "abc123", worktree: "/tmp/v1" }]);
  expect(rows).toEqual([{
    kind: "verify", id: "v1", work: "verify-codereview", project: "agent-crew", state: "running",
    live: true, age: "", ageVal: -1, room: "flow", caller: "flow-implement", ref: "abc123", worktree: "/tmp/v1",
  }]);
});

test("verifyProcessRows shows the entry's own meta kind as `work`, not the bucket", () => {
  const [row] = verifyProcessRows([{ id: "v2", kind: "verify-plan", project: "p", status: "ok" }]);
  expect(row.kind).toBe("verify"); // the bucket
  expect(row.work).toBe("verify-plan"); // the meta kind - a different string
});

test("verifyProcessRows links a verifier to its supervising family without inventing lease age", () => {
  const [row] = verifyProcessRows([{ id: "v3", kind: "verify-review", project: "p", status: "blocked", family: "fam" }]);
  expect(row.age).toBe("");
  expect(row.ageVal).toBe(-1);
  expect(row.room).toBe("fam");
});

test("verifyProcessRows defaults work/project/state when the wire entry omits them", () => {
  const [row] = verifyProcessRows([{ id: "v4" }]);
  expect(row).toEqual({
    kind: "verify", id: "v4", work: "verify", project: "—", state: "",
    live: true, age: "", ageVal: -1, room: null, caller: "", ref: "", worktree: "",
  });
});

test("verifyProcessRows returns no rows for an absent verify[] array (pre-2.1 snapshot)", () => {
  expect(verifyProcessRows(undefined)).toEqual([]);
  expect(verifyProcessRows(null)).toEqual([]);
  expect(verifyProcessRows([])).toEqual([]);
});

// boardSystemPanes (board-live-panes): the In-Flight column's live-pane join -
// system/paned tasks that run with a live meta but mint NO backlog row must
// surface, deduped by family id against the In-flight backlog cards.
test("boardSystemPanes surfaces a verify pane and a self/roomchief crew pane with no backlog row", () => {
  const home = {
    crew: { tasks: [{ id: "chief-note", kind: "self", project: "agent-crew", status: "working: edit" },
                     { id: "learning-chief", kind: "roomchief", project: "agent-crew", status: "distilling" }] },
    verify: [{ id: "v-suite", kind: "verify-suite", project: "agent-crew", status: "running" }],
  };
  const out = boardSystemPanes(home, ["learning"], []);
  expect(out.map((p) => p.id).sort()).toEqual(["chief-note", "learning-chief", "v-suite"]);
  const suite = out.find((p) => p.id === "v-suite")!;
  expect(suite.kind).toBe("verify-suite");
  expect(suite.status).toBe("running");
});

test("boardSystemPanes dedupes a pane whose family already has an In-flight backlog card", () => {
  const known = ["board-live-panes", "greet2"];
  const home = {
    crew: { tasks: [{ id: "board-live-panes", kind: "ship", project: "agent-crew", status: "working" }, // exact id match
                     { id: "greet2-chief", kind: "roomchief", project: "agent-crew", status: "gating" }] }, // normalizes to greet2
  };
  // both greet2 and board-live-panes have an In-flight backlog card -> excluded
  expect(boardSystemPanes(home, known, ["board-live-panes", "greet2"])).toEqual([]);
});

test("boardSystemPanes defaults kind/project/status and tolerates absent crew/verify", () => {
  expect(boardSystemPanes(null, [], [])).toEqual([]);
  expect(boardSystemPanes({ crew: { tasks: [{ id: "x" }] } }, [], [])).toEqual([
    { id: "x", kind: "task", project: "—", status: "" },
  ]);
});

// ttlMemo backs allowedHomePaths(): every route gate (processes, reports, and
// the rest) calls it, so caching it once fixes the shell-out cost everywhere
// it is paid, not just on the two routes named in the task.
test("ttlMemo re-uses the loader's result for repeat calls inside the TTL window", async () => {
  let calls = 0;
  const load = ttlMemo(200, async () => { calls++; return calls; });
  expect(await load()).toBe(1);
  expect(await load()).toBe(1);
  expect(calls).toBe(1);
});

test("ttlMemo reloads once the TTL window has elapsed", async () => {
  let calls = 0;
  const load = ttlMemo(30, async () => { calls++; return calls; });
  expect(await load()).toBe(1);
  await new Promise((r) => setTimeout(r, 60));
  expect(await load()).toBe(2);
  expect(calls).toBe(2);
});

test("ttlMemo shares one in-flight call across concurrent callers", async () => {
  let calls = 0;
  const load = ttlMemo(200, async () => {
    calls++;
    await new Promise((r) => setTimeout(r, 10));
    return calls;
  });
  const [a, b] = await Promise.all([load(), load()]);
  expect(a).toBe(1);
  expect(b).toBe(1);
  expect(calls).toBe(1);
});

// The TTL clock starts when the value LANDS, not when the loader was invoked -
// otherwise a loader slower than ttlMs (ac-fleets.sh on a busy fleet routinely
// is) would never actually cache a sequential call fired right after the
// previous one finished, defeating the whole point of the cache.
test("ttlMemo's TTL window starts at resolution, so a slow loader still caches", async () => {
  let calls = 0;
  const load = ttlMemo(50, async () => {
    calls++;
    await new Promise((r) => setTimeout(r, 80)); // slower than the 50ms TTL
    return calls;
  });
  expect(await load()).toBe(1);
  expect(await load()).toBe(1); // fired right after the first resolved - still warm
  expect(calls).toBe(1);
});

// dashboard.ts:2592 sets the client poll interval POLL_MS = 5000, but that
// constant lives inside the `PAGE` template literal (bun test cannot import
// it - see the dashboard-verifier-kind-hardcode repo-knowledge entry), so the
// bound below is the known client value. Regression for the bug this task
// fixes: HOME_PATHS_TTL_MS (3000) used to be SHORTER than POLL_MS (5000), so
// the cache had always expired by the next steady-state poll and missed on
// every tick.
test("HOME_PATHS_TTL_MS exceeds the client's 5000ms poll interval, so a steady-state poll hits the cache", () => {
  expect(HOME_PATHS_TTL_MS).toBeGreaterThan(5000);
});

// The PAGE template literal EATS one escape level: a client-side string
// written `'...\\'...'` in source reaches the browser as `'...'...'` - a
// syntax error that blanks every route (the contract-chips title did exactly
// this; the server still answered 200, so nothing else caught it). bun test
// cannot import PAGE, but it can lint the SOURCE: inside the literal, a
// backslash-quote must always be doubled (`\\\\'` in the file), never single.
test("PAGE literal carries no single-escaped quote (the template eats one level and blanks the client)", () => {
  const src = require("fs").readFileSync(new URL("./dashboard.ts", import.meta.url), "utf8");
  const start = src.indexOf("const PAGE = `");
  expect(start).toBeGreaterThan(0);
  const page = src.slice(start);
  const bad: string[] = [];
  for (let i = 0; i < page.length - 1; i++) {
    if (page[i] !== "\\") continue;
    let j = i; // walk the backslash run
    while (j < page.length && page[j] === "\\") j++;
    const runLen = j - i;
    if (page[j] === "'" && runLen % 2 === 1)
      bad.push(page.slice(Math.max(0, i - 60), j + 1));
    i = j;
  }
  expect(bad).toEqual([]);
});

// --- whiteboard (dash-whiteboard slice 1) -----------------------------------
// isSceneName is the ONE gate between a query param and a filename under the
// whiteboards dir; normalizeScene is the ONE gate between a POST body and the
// disk. Both pure - the routes around them are thin IO.
test("isSceneName admits url/file-safe names and refuses traversal shapes", () => {
  expect(isSceneName("batch-drain")).toBe(true);
  expect(isSceneName("a")).toBe(true);
  expect(isSceneName("")).toBe(false);
  expect(isSceneName("-leading-dash")).toBe(false);
  expect(isSceneName("Has.Caps")).toBe(false);
  expect(isSceneName("dot.dot")).toBe(false);
  expect(isSceneName("../escape")).toBe(false);
  expect(isSceneName("a/b")).toBe(false);
  expect(isSceneName("x".repeat(65))).toBe(false);
  expect(isSceneName("x".repeat(64))).toBe(true);
});

test("normalizeScene canonicalizes a plausible scene and rejects junk", () => {
  const good = normalizeScene(JSON.stringify({
    elements: [{ type: "rectangle", id: "r1" }],
    appState: { viewBackgroundColor: "#fff", selectedElementIds: { r1: true } },
    files: {},
  }));
  expect(good).not.toBeNull();
  expect(good!.type).toBe("excalidraw");
  expect((good!.elements as unknown[]).length).toBe(1);
  // session-only appState is dropped; the one durable field survives.
  expect(good!.appState).toEqual({ viewBackgroundColor: "#fff" });

  expect(normalizeScene("not json")).toBeNull();
  expect(normalizeScene("42")).toBeNull();
  expect(normalizeScene(JSON.stringify({ appState: {} }))).toBeNull();          // no elements
  expect(normalizeScene(JSON.stringify({ elements: [1, 2] }))).toBeNull();      // non-object elements
  // an empty canvas IS a scene: creating one is just saving it.
  const empty = normalizeScene(JSON.stringify({ elements: [] }));
  expect(empty).not.toBeNull();
  expect(empty!.appState).toEqual({});
});

// --- whiteboard write path: version precondition ----------------------------
// (whiteboard-agent-write-clobbers-captain-edits) whiteboardWrite used to
// last-write-win unconditionally: no read-back, no version check, so a second
// writer silently erased whatever the first one had just saved with no
// signal of any kind. Every write now carries the version it read (an
// If-Match precondition); the server refuses a stale one instead of
// replacing the file.
function sceneBody(elements: { type: string; id: string }[]): string {
  return JSON.stringify({ elements, appState: {}, files: {} });
}

function wbHome(): string {
  return mkdtempSync(`${tmpdir()}/dash-wb-write-`);
}

test("whiteboardWrite refuses a stale write and the other writer's content survives on disk", async () => {
  const home = wbHome();
  try {
    // A reads scene (creating it - a fresh scene needs no precondition)
    const created = whiteboardWrite(home, "scene-a", sceneBody([{ type: "rectangle", id: "r1" }]), null);
    expect(created.status).toBe(200);
    const versionA = (await created.json()).version;
    expect(typeof versionA).toBe("string");

    // B reads the same version, then writes with it - succeeds, advances the version
    const wroteB = whiteboardWrite(
      home, "scene-a",
      sceneBody([{ type: "rectangle", id: "r1" }, { type: "ellipse", id: "e1" }]),
      versionA,
    );
    expect(wroteB.status).toBe(200);
    const versionB = (await wroteB.json()).version;
    expect(versionB).not.toBe(versionA);

    // A writes back using the version it originally read - now stale
    const refused = whiteboardWrite(
      home, "scene-a",
      sceneBody([{ type: "rectangle", id: "r1" }, { type: "text", id: "t1" }]),
      versionA,
    );
    expect(refused.status).toBe(412);
    const body = await refused.json();
    expect(typeof body.error).toBe("string");
    expect(body.error.length).toBeGreaterThan(10); // an actionable reason, not a bare code
    expect(body.version).toBe(versionB);

    // B's content is still intact on disk - the entire point of the fix
    const disk = readFileSync(`${home}/whiteboards/scene-a.excalidraw.json`, "utf8");
    expect((JSON.parse(disk).elements as { id: string }[]).map((e) => e.id)).toEqual(["r1", "e1"]);
    // the refusal body hands the agent the current scene - a merge needs no second GET
    expect(body.scene).toBe(disk);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("whiteboardWrite refuses an existing scene with no precondition at all (428)", async () => {
  const home = wbHome();
  try {
    whiteboardWrite(home, "scene-a", sceneBody([{ type: "rectangle", id: "r1" }]), null);
    const res = whiteboardWrite(
      home, "scene-a",
      sceneBody([{ type: "rectangle", id: "r1" }, { type: "ellipse", id: "e1" }]),
      null,
    );
    expect(res.status).toBe(428);
    const body = await res.json();
    expect(typeof body.error).toBe("string");
    // the missing-precondition write never landed - still just r1 on disk
    const disk = JSON.parse(readFileSync(`${home}/whiteboards/scene-a.excalidraw.json`, "utf8"));
    expect((disk.elements as { id: string }[]).map((e) => e.id)).toEqual(["r1"]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("whiteboardWrite: a matching precondition succeeds, and If-Match: * force-overwrites regardless", async () => {
  const home = wbHome();
  try {
    const created = whiteboardWrite(home, "scene-a", sceneBody([{ type: "rectangle", id: "r1" }]), null);
    const v1 = (await created.json()).version;

    // matching precondition succeeds
    const ok = whiteboardWrite(
      home, "scene-a",
      sceneBody([{ type: "rectangle", id: "r1" }, { type: "ellipse", id: "e1" }]),
      v1,
    );
    expect(ok.status).toBe(200);

    // that same (now stale) version is refused ...
    const refused = whiteboardWrite(home, "scene-a", sceneBody([{ type: "text", id: "t1" }]), v1);
    expect(refused.status).toBe(412);

    // ... but the captain's force escape hatch always wins
    const forced = whiteboardWrite(home, "scene-a", sceneBody([{ type: "text", id: "t1" }]), "*");
    expect(forced.status).toBe(200);
    const disk = JSON.parse(readFileSync(`${home}/whiteboards/scene-a.excalidraw.json`, "utf8"));
    expect((disk.elements as { id: string }[]).map((e) => e.id)).toEqual(["t1"]);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test("whiteboardShow serves an ETag matching the scene's current bytes, usable as the next write's precondition", async () => {
  const home = wbHome();
  try {
    whiteboardWrite(home, "scene-a", sceneBody([{ type: "rectangle", id: "r1" }]), null);
    const res = whiteboardShow(home, "scene-a");
    const etag = res.headers.get("etag");
    expect(typeof etag).toBe("string");
    const ok = whiteboardWrite(
      home, "scene-a",
      sceneBody([{ type: "rectangle", id: "r1" }, { type: "ellipse", id: "e1" }]),
      etag,
    );
    expect(ok.status).toBe(200);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

// --- review (dash-review) ---------------------------------------------------
// reviewApply is the session reducer every mutation goes through; pollSlice
// the cursor; normalizeAnnotation the body->store gate. The rule with teeth:
// a HUMAN-ended session refuses a plain reopen, --reopen (force) overrides.
test("reviewApply queues annotations with a monotonic seq and refuses when ended", () => {
  let s0 = emptyReviewSession("/a/b.html");
  const a1 = reviewApply(s0, { type: "annotate", anchor: null, text: "t1", at: "T1" });
  expect(typeof a1).not.toBe("string");
  const s1 = a1 as ReturnType<typeof emptyReviewSession>;
  expect(s1.seq).toBe(1);
  const s2 = reviewApply(s1, { type: "annotate", anchor: { selector: "#x", fingerprint: "f" }, text: "t2", at: "T2" }) as typeof s1;
  expect(s2.seq).toBe(2);
  expect(pollSlice(s2, 0).items.length).toBe(2);
  expect(pollSlice(s2, 1).items.map(i => i.n)).toEqual([2]);
  const ended = reviewApply(s2, { type: "end", by: "human" }) as typeof s1;
  expect(ended.state).toBe("ended");
  expect(typeof reviewApply(ended, { type: "annotate", anchor: null, text: "x", at: "T" })).toBe("string");
});

// REVIEW SHARE (dashboard.ts share block): the token lives in the session
// file, dies with the session, and reopen never resurrects it - a revoked or
// ended link must go dark durably, not merely until a restart.
test("reviewApply share/unshare set and clear the token; end kills it; reopen does not resurrect it", () => {
  const base = emptyReviewSession("/a/b.html");
  const shared = reviewApply(base, { type: "share", token: "a".repeat(32), at: "T" }) as typeof base;
  expect(shared.share!.token).toBe("a".repeat(32));
  expect((reviewApply(shared, { type: "unshare" }) as typeof base).share).toBeUndefined();
  const ended = reviewApply(shared, { type: "end", by: "agent" }) as typeof base;
  expect(ended.share).toBeUndefined();
  const reopened = reviewApply(ended, { type: "reopen", force: false }) as typeof base;
  expect(reopened.share).toBeUndefined();
  expect(typeof reviewApply(ended, { type: "share", token: "b".repeat(32), at: "T" })).toBe("string");
});

test("reviewApply stamps the guest author on annotations that carry one and never invents one", () => {
  const base = emptyReviewSession("/a/b.html");
  const g = reviewApply(base, { type: "annotate", anchor: null, text: "from guest", at: "T", by: "guest" }) as typeof base;
  expect(g.queue[0].by).toBe("guest");
  const c = reviewApply(g, { type: "annotate", anchor: null, text: "from captain", at: "T" }) as typeof base;
  expect(c.queue[1].by).toBeUndefined();
});

// THE MODERATION WALL (captain order: agents never read unapproved guest
// feedback): pollSlice is the one delivery path, so the wall lives there -
// a by-record is invisible until approved, and approval re-seqs it PAST any
// cursor an agent already advanced.
test("pollSlice never delivers pending or dismissed guest records; approve re-seqs into the stream", () => {
  const base = emptyReviewSession("/a/b.html");
  let s = reviewApply(base, { type: "annotate", anchor: null, text: "captain says", at: "T1" }) as typeof base;
  s = reviewApply(s, { type: "annotate", anchor: null, text: "guest asks", at: "T2", by: "an" }) as typeof base;
  // The agent sees only the captain's item; suppose it handled it (cursor 2).
  expect(pollSlice(s, 0).items.map((i) => i.text)).toEqual(["captain says"]);
  const dis = reviewApply(s, { type: "dismiss", n: 2 }) as typeof base;
  expect(pollSlice(dis, 0).items.map((i) => i.text)).toEqual(["captain says"]);
  const ap = reviewApply(s, { type: "approve", n: 2 }) as typeof base;
  // Fresh n=3: a cursor already past the original 2 still receives it.
  expect(pollSlice(ap, 2).items.map((i) => [i.n, i.text, i.by])).toEqual([[3, "guest asks", "an"]]);
});

test("approve/dismiss accept only a PENDING guest record and refuse when ended", () => {
  const base = emptyReviewSession("/a/b.html");
  let s = reviewApply(base, { type: "annotate", anchor: null, text: "captain", at: "T" }) as typeof base;
  s = reviewApply(s, { type: "annotate", anchor: null, text: "guest", at: "T", by: "guest" }) as typeof base;
  expect(typeof reviewApply(s, { type: "approve", n: 1 })).toBe("string");   // captain record
  expect(typeof reviewApply(s, { type: "approve", n: 99 })).toBe("string");  // unknown
  const ap = reviewApply(s, { type: "approve", n: 2 }) as typeof base;
  expect(typeof reviewApply(ap, { type: "approve", n: 3 })).toBe("string");  // already approved (new n)
  const dis = reviewApply(s, { type: "dismiss", n: 2 }) as typeof base;
  expect(typeof reviewApply(dis, { type: "approve", n: 2 })).toBe("string"); // dismissed stays retired
  const ended = reviewApply(s, { type: "end", by: "human" }) as typeof base;
  expect(typeof reviewApply(ended, { type: "approve", n: 2 })).toBe("string");
});

test("mintShareToken mints 32 lowercase hex chars, unique per call", () => {
  const t1 = mintShareToken(), t2 = mintShareToken();
  expect(t1).toMatch(/^[0-9a-f]{32}$/);
  expect(t2).toMatch(/^[0-9a-f]{32}$/);
  expect(t1).not.toBe(t2);
  expect(shareLinkUrl(8788, t1)).toBe(`http://localhost:8788/review/${t1}`);
});

test("a human-ended session refuses a plain reopen; force and agent-ended reopen freely", () => {
  const base = emptyReviewSession("/a/b.html");
  const human = reviewApply(base, { type: "end", by: "human" }) as typeof base;
  expect(typeof reviewApply(human, { type: "reopen", force: false })).toBe("string");
  expect((reviewApply(human, { type: "reopen", force: true }) as typeof base).state).toBe("open");
  const agent = reviewApply(base, { type: "end", by: "agent" }) as typeof base;
  expect((reviewApply(agent, { type: "reopen", force: false }) as typeof base).state).toBe("open");
});

test("normalizeAnnotation requires text and a well-shaped optional anchor", () => {
  expect(normalizeAnnotation(JSON.stringify({ text: "hi" }))!.anchor).toBeNull();
  const a = normalizeAnnotation(JSON.stringify({ text: "hi", anchor: { selector: "#x", fingerprint: "y".repeat(200) } }));
  expect(a!.anchor!.fingerprint.length).toBe(80);
  expect(normalizeAnnotation(JSON.stringify({ text: "  " }))).toBeNull();
  expect(normalizeAnnotation(JSON.stringify({ text: "hi", anchor: { selector: 1 } }))).toBeNull();
  expect(normalizeAnnotation("junk")).toBeNull();
});

// PRESENCE + share hygiene (REVIEW SHARE): names are stored sanitized, the
// viewer view prunes stale entries, and the Reviews rows flag a live share.
test("sanitizeGuestName strips control chars, trims, bounds at 24, and tolerates non-strings", () => {
  expect(sanitizeGuestName("  Minh Anh \n")).toBe("Minh Anh");
  expect(sanitizeGuestName("x".repeat(60)).length).toBe(24);
  expect(sanitizeGuestName(null)).toBe("");
  expect(sanitizeGuestName(42)).toBe("");
});

test("shareViewersView keeps fresh viewers newest-first and prunes the stale", () => {
  const now = 100_000;
  const m = new Map([
    ["10.0.0.5", { name: "an", last: now - 2_000 }],
    ["10.0.0.9", { name: "", last: now - 500 }],
    ["10.0.0.7", { name: "old", last: now - SHARE_VIEWER_FRESH_MS - 1 }],
  ]);
  const v = shareViewersView(m, now);
  expect(v.map((x) => x.ip)).toEqual(["10.0.0.9", "10.0.0.5"]);
  expect(v[1]).toEqual({ name: "an", ip: "10.0.0.5", ago: 2 });
  expect(m.has("10.0.0.7")).toBe(false); // pruned in place
  expect(shareViewersView(undefined, now)).toEqual([]);
});

test("reviewSessionSummary flags a live share and never on an ended session", () => {
  expect(reviewSessionSummary({ state: "open", seq: 0, queue: [], replies: [], share: { token: "a".repeat(32) } }).shared).toBe(true);
  expect(reviewSessionSummary({ state: "open", seq: 0, queue: [], replies: [] }).shared).toBe(false);
  expect(reviewSessionSummary({ state: "ended", seq: 0, queue: [], replies: [], share: { token: "a".repeat(32) } }).shared).toBe(false);
});


// Share password (HTTP Basic wall): the stored value is a salted digest -
// the session file is agent-readable, a hash there identifies nothing - and
// the header parser is fail-closed on every malformed shape.
test("hashSharePassword is salted and deterministic; shareHashEq compares safely", () => {
  const h1 = hashSharePassword("s3cret", "salt-a");
  expect(h1).toMatch(/^[0-9a-f]{64}$/);
  expect(hashSharePassword("s3cret", "salt-a")).toBe(h1);
  expect(hashSharePassword("s3cret", "salt-b")).not.toBe(h1);
  expect(shareHashEq(h1, h1)).toBe(true);
  expect(shareHashEq(h1, hashSharePassword("wrong", "salt-a"))).toBe(false);
  expect(shareHashEq("ab", "abc")).toBe(false);
});

test("basicAuthPassword extracts the Basic password and refuses malformed headers", () => {
  expect(basicAuthPassword("Basic " + btoa("guest:pw1"))).toBe("pw1");
  expect(basicAuthPassword("Basic " + btoa("any:pw:with:colons"))).toBe("pw:with:colons");
  expect(basicAuthPassword("Basic " + btoa("nocolon"))).toBe("");
  expect(basicAuthPassword("Bearer xyz")).toBe("");
  expect(basicAuthPassword("Basic !!!not-base64")).toBe("");
  expect(basicAuthPassword(null)).toBe("");
});

test("pollSlice reports the withheld-guest count as pending, content-free", () => {
  const base = emptyReviewSession("/a/b.html");
  let s = reviewApply(base, { type: "annotate", anchor: null, text: "g1", at: "T", by: "an" }) as typeof base;
  s = reviewApply(s, { type: "annotate", anchor: null, text: "g2", at: "T", by: "an" }) as typeof base;
  s = reviewApply(s, { type: "annotate", anchor: null, text: "cap", at: "T" }) as typeof base;
  const p0 = pollSlice(s, 0);
  expect(p0.items.map((i) => i.text)).toEqual(["cap"]);
  expect(p0.pending).toBe(2);
  const ap = reviewApply(s, { type: "approve", n: 1 }) as typeof base;
  expect(pollSlice(ap, 0).pending).toBe(1);
  const dis = reviewApply(ap, { type: "dismiss", n: 2 }) as typeof base;
  expect(pollSlice(dis, 0).pending).toBe(0);
});

// reviewSessionSummary feeds the Reviews route rows: pins = anchored queue
// items, messages = unanchored ones + agent replies; endedBy only on ended.
test("reviewSessionSummary counts pins vs messages and reports state", () => {
  const s = {
    state: "open",
    queue: [
      { n: 1, anchor: { selector: "#x", fingerprint: "f" }, text: "pin" },
      { n: 2, anchor: null, text: "chat" },
    ],
    replies: [{ at: "T", text: "agent reply" }],
  };
  expect(reviewSessionSummary(s)).toEqual({ state: "open", endedBy: undefined, pins: 1, messages: 2, shared: false });
  const ended = reviewSessionSummary({ state: "ended", endedBy: "human", queue: [], replies: [] });
  expect(ended.state).toBe("ended");
  expect(ended.endedBy).toBe("human");
});

test("reviewSessionSummary tolerates a malformed session file", () => {
  expect(reviewSessionSummary(null)).toEqual({ state: "open", endedBy: undefined, pins: 0, messages: 0, shared: false });
  expect(reviewSessionSummary({ state: "weird", queue: "no", replies: 7 }))
    .toEqual({ state: "open", endedBy: undefined, pins: 0, messages: 0, shared: false });
  // endedBy never leaks onto an open session even if present in the file
  expect(reviewSessionSummary({ state: "open", endedBy: "human" }).endedBy).toBeUndefined();
});

// dash-review-polish-xhome: the cross-home Reviews shaping - filter to OPEN
// sessions only (an ended one belongs to its own fleet's history, not a
// cross-home attention feed), tag each row with its OWN home (the open URL
// needs it), newest first. Pure - the per-home IO stays in
// reviewRowsForHome/reviewsAllHomes.
test("crossHomeReviewRows keeps only OPEN sessions, tags each with its own home, newest first", () => {
  const rowsA = [
    { id: "r1", path: "/a/1.html", family: "f1", mtime: 100, listening: false, state: "open" as const, pins: 1, messages: 2 },
    { id: "r2", path: "/a/2.html", family: "f2", mtime: 200, listening: true, state: "ended" as const, endedBy: "human", pins: 0, messages: 1 },
  ];
  const rowsB = [
    { id: "r3", path: "/b/3.html", family: "f3", mtime: 300, listening: false, state: "open" as const, pins: 0, messages: 0 },
  ];
  const out = crossHomeReviewRows([
    { home: "/homes/a", rows: rowsA },
    { home: "/homes/b", rows: rowsB },
  ]);
  // ended r2 dropped entirely; the two open rows sort newest mtime first
  expect(out.map((r) => r.id)).toEqual(["r3", "r1"]);
  expect(out[0].home).toBe("/homes/b");
  expect(out[1].home).toBe("/homes/a");
});

test("crossHomeReviewRows returns [] when every home has no open session", () => {
  expect(crossHomeReviewRows([{ home: "/homes/a", rows: [] }])).toEqual([]);
});

// --- diagram hand-off (dash-whiteboard phase 2) -----------------------------
test("extractMermaidSources finds class=mermaid blocks and language-mermaid fences, decoding entities", () => {
  const html = [
    '<pre class="mermaid">graph TD; A--&gt;B</pre>',
    '<div class="x mermaid y">flowchart LR; C--&gt;D</div>',
    '<pre><code class="language-mermaid">sequenceDiagram; E-&gt;&gt;F: hi</code></pre>',
    '<pre class="not-mermaid">nope</pre>',
    '<div class="mermaidish">nope</div>',
  ].join("\n");
  const got = extractMermaidSources(html);
  expect(got.length).toBe(3);
  expect(got[0].source).toBe("graph TD; A-->B");
  expect(got[0].kind).toBe("block");
  expect(got[2].source).toContain("E->>F: hi");
  expect(got[2].kind).toBe("fence");
});

test("diagramSceneName squeezes any basename into the scene-name grammar", () => {
  expect(diagramSceneName("/a/b/Gate Review (v2).html", 1)).toBe("gate-review-v2-d1");
  expect(diagramSceneName("/a/x.md", 3)).toBe("x-d3");
  expect(isSceneName(diagramSceneName("/weird/__##__.html", 2))).toBe(true);
  expect(isSceneName(diagramSceneName("/a/" + "Z".repeat(90) + ".html", 1))).toBe(true);
});

test("mermaidDropParticipantBoxes removes each box wrapper and its own closing end", () => {
  const src = [
    "sequenceDiagram",
    "  autonumber",
    "  box rgb(222,236,255) Trusted",
    "  participant GW",
    "  end",
    "  box Internal",
    "  participant FI",
    "  end",
    "  GW->>FI: hi",
    "  alt ok",
    "  FI-->>GW: yes",
    "  end",
  ].join("\n");
  expect(mermaidDropParticipantBoxes(src)).toBe([
    "sequenceDiagram",
    "  autonumber",
    "  participant GW",
    "  participant FI",
    "  GW->>FI: hi",
    "  alt ok",
    "  FI-->>GW: yes",
    "  end",
  ].join("\n"));
});

test("mermaidDropParticipantBoxes returns null when the source has no box to drop", () => {
  expect(mermaidDropParticipantBoxes("sequenceDiagram\n  A->>B: hi")).toBeNull();
  // a participant whose name merely starts with the keyword is not a box
  expect(mermaidDropParticipantBoxes("sequenceDiagram\n  participant boxer\n  boxer->>B: hi")).toBeNull();
});

test("mermaidImportWithFallback retries without boxes only after a real failure, and reports the drop", async () => {
  const boxed = "sequenceDiagram\n  box G\n  participant A\n  end\n  alt y\n  A->>B: hi\n  end";
  const calls: string[] = [];
  // the converter as measured: it throws on box + alt, succeeds once box is gone
  const parse = async (s: string) => {
    calls.push(s);
    if (/^\s*box\b/m.test(s)) throw new Error("Element attributes missing [object Object]");
    return { elements: [{ id: "e1" }], files: null };
  };
  const got = await mermaidImportWithFallback(parse, boxed);
  expect(got.dropped).toBe(true);
  expect(got.elements).toEqual([{ id: "e1" }]);
  expect(calls.length).toBe(2);

  const clean = await mermaidImportWithFallback(parse, "sequenceDiagram\n  A->>B: hi");
  expect(clean.dropped).toBe(false);
});

test("mermaidImportWithFallback surfaces the ORIGINAL error, never one about the source it invented", async () => {
  // no box to drop - the first error is the only one there is
  const plain = async () => { throw new Error("original failure"); };
  await expect(mermaidImportWithFallback(plain, "flowchart TD\n  A --> B"))
    .rejects.toThrow("original failure");
  // box dropped, retry ALSO fails: the box was not the cause, so the captain
  // must see the error for the diagram they wrote, not for the box-less rewrite
  const both = async (s: string) => { throw new Error(/box/.test(s) ? "original failure" : "rewrite failure"); };
  await expect(mermaidImportWithFallback(both, "sequenceDiagram\n  box G\n  participant A\n  end\n  A->>B: hi"))
    .rejects.toThrow("original failure");
});

// --- mermaid render pass, shared between /review and the SPA readers
// (reports-mermaid) - mermaidPass is DOM- and CDN-coupled (querySelectorAll,
// innerHTML, a dynamic import of the mermaid ESM build), so it has no pure
// input/output surface a bun test can drive without a browser; acceptance
// 1/2/5 are proved live (see the report). What IS a real, checkable claim
// about its SOURCE: it takes the CDN loader as a parameter rather than
// embedding a literal import() of its own - the same DI mermaidImportWithFallback
// already uses for its `parse` callback, so the shared function stays free of
// any live module resolution the two very different interpolation sites (the
// review iframe's own <script>, the SPA's page script) would otherwise have to
// agree on identically.
test("mermaidPass: takes an injected loader, no literal import() baked into the shared function", () => {
  const src = mermaidPass.toString();
  expect(src).not.toContain("import(");
  expect(src).toContain("loadMermaid");
});

// The review iframe's diagrams sit on a hardcoded white card regardless of
// theme (matching the auto-embedded whiteboard cards); the SPA's own readers
// (Reports/Records/Board) live inside the dashboard's live-themeable chrome
// and want the diagram to follow suit - theme/paperStyle stay parameters
// here for exactly that reason (a shared function that baked in ONE surface's
// presentation would regress the other's), the same DI shape as the loader.
test("mermaidPass: theme and paper background are parameters too, not one surface's hardcoded choice baked into the shared function", () => {
  const src = mermaidPass.toString();
  expect(src).toContain("theme");
  expect(src).not.toContain('"neutral"');
  expect(src).not.toContain("background:#fff");
});

test("mermaidPass: fence/foreign-block selectors and the data-mmd/data-processed guards survive toString() - the exact contract both interpolation sites rely on", () => {
  const src = mermaidPass.toString();
  expect(src).toContain("pre > code[class*=language-mermaid]");
  expect(src).toContain("pre.mermaid, div.mermaid");
  expect(src).toContain("data-acrv");
  expect(src).toContain("data-mmd");
  expect(src).toContain("data-processed");
});

// The .mmdview wrapper div was the SPA-only reader's OWN second render path
// (replaceWith a new div, vs. mermaidPass's in-place innerHTML on the
// existing element) - now retired in favor of the one shared implementation,
// so its dedicated CSS is dead weight readerCss must not still carry.
test("readerCss: no leftover .mmdview rule now that the SPA reader shares mermaidPass's in-place render", () => {
  expect(readerCss(".reader")).not.toContain("mmdview");
  expect(readerCss("")).not.toContain("mmdview");
});

test("reviewWakeParts squeezes the id to the record charset and folds the payload", () => {
  const w = reviewWakeParts("/a/b/Bao Cao (v2).html", "dòng 1\nдòng\t2  dài " + "x".repeat(300));
  expect(w.id).toBe("review-bao-cao-v2-html");
  expect(w.payload.includes("\n")).toBe(false);
  expect(w.payload.includes("\t")).toBe(false);
  expect(w.payload.length).toBeLessThanOrEqual(160);
  expect(reviewWakeParts("/x/____.html", "t").id.startsWith("review-")).toBe(true);
});

test("reviewWakeText names the legal poll channel and never the session file (captain-hold-has-no-machine-representation-wake W1)", () => {
  const full = reviewWakeText("/home/data/f/report.html", "captain left a note");
  expect(full.includes("session.json")).toBe(false);
  expect(full).toContain("bin/ac-review.sh poll");
  expect(full).toContain("/home/data/f/report.html");
  expect(full).toContain("captain left a note");
});

test("chiefPaneOf: only a roomchief meta with a herdr window yields a pane id", () => {
  expect(chiefPaneOf("backend=herdr\nwindow=herdr:pane-w1D:p3F\nkind=roomchief\n")).toBe("w1D:p3F");
  // a crewmate/ship meta is never readable through the chief panel
  expect(chiefPaneOf("window=herdr:tab:p1\nkind=ship\n")).toBeNull();
  expect(chiefPaneOf("kind=roomchief\n")).toBeNull(); // no window recorded
  expect(chiefPaneOf("kind=roomchief\nwindow=tmux:0:1\n")).toBeNull(); // not herdr
});

test("isChiefPaste: printable multi-char in, control bytes and runaway length out", () => {
  expect(isChiefPaste("xin chao thuyen truong \u1ec1")).toBe(true); // composed Vietnamese
  expect(isChiefPaste("line1\nline2\ttabbed")).toBe(true);          // newline and tab are typing
  expect(isChiefPaste("")).toBe(false);
  expect(isChiefPaste("\u001b[31mred")).toBe(false);                 // an escape can never ride the text path
  expect(isChiefPaste("a\u0000b")).toBe(false);
  expect(isChiefPaste("x".repeat(2001))).toBe(false);
  expect(isChiefPaste("x".repeat(2000))).toBe(true);
});

test("attachExt: only the four image types, extension is ours never the client's", () => {
  expect(attachExt("image/png")).toBe("png");
  expect(attachExt("IMAGE/JPEG")).toBe("jpg");
  expect(attachExt("image/webp")).toBe("webp");
  expect(attachExt("image/gif")).toBe("gif");
  expect(attachExt("image/svg+xml")).toBeNull();   // scriptable - never saved
  expect(attachExt("application/pdf")).toBeNull();
  expect(attachExt(null)).toBeNull();
});

test("termSize clamps garbage to safe integer pty dimensions", () => {
  expect(termSize("120", "40")).toEqual({ cols: 120, rows: 40 });
  expect(termSize(null, null)).toEqual({ cols: 80, rows: 24 });
  expect(termSize("nonsense", "-5")).toEqual({ cols: 80, rows: 5 });
  expect(termSize("99999", "99999")).toEqual({ cols: 500, rows: 200 });
  // never a float or an injection vector - these ride an stty command line
  expect(termSize("100.9", "30.2")).toEqual({ cols: 100, rows: 30 });
  expect(termSize("80; rm -rf /", "24")).toEqual({ cols: 80, rows: 24 });
});

test("localHostOk/originOk: only this server's own local names pass", () => {
  // Host: the three local spellings on the served port, nothing else
  expect(localHostOk("127.0.0.1:8787", 8787)).toBe(true);
  expect(localHostOk("localhost:8787", 8787)).toBe(true);
  expect(localHostOk("[::1]:8787", 8787)).toBe(true);
  expect(localHostOk("127.0.0.1:9999", 8787)).toBe(false); // wrong port
  expect(localHostOk("evil.example:8787", 8787)).toBe(false); // DNS rebinding
  expect(localHostOk("127.0.0.1", 8787)).toBe(false); // portless never matches
  expect(localHostOk(null, 8787)).toBe(false);
  // Origin: absent = non-browser client, else must be this server over http
  expect(originOk(null, 8787)).toBe(true);
  expect(originOk("http://127.0.0.1:8787", 8787)).toBe(true);
  expect(originOk("http://localhost:8787", 8787)).toBe(true);
  expect(originOk("http://evil.example", 8787)).toBe(false);
  expect(originOk("http://127.0.0.1:9999", 8787)).toBe(false);
  expect(originOk("https://127.0.0.1:8787", 8787)).toBe(false); // never served https
  // a sandboxed (opaque-origin) frame sends the literal string "null"
  expect(originOk("null", 8787)).toBe(false);
});

test("familyPaneIds: own tasks + verify panes in, chief/self/other families out", () => {
  const metas = [
    { id: "greet2-chief", text: "kind=roomchief\nwindow=herdr:pane-w1:p1\n" },
    { id: "greet2", text: "kind=ship\nwindow=herdr:pane-w1:p2\n" },
    { id: "greet2-design", text: "kind=scout\nwindow=herdr:pane-w1:p3\n" },
    // intra-family fan-out sub-deliverable (AGENTS.md section 5): a
    // <family>-<slug> id whose slug is not a reserved stage suffix.
    { id: "greet2-frontend", text: "kind=ship\nwindow=herdr:pane-w1:p4\n" },
    { id: "greet2-verify-codereview", text: "kind=verify-codereview\nfamily=greet2\n" },
    { id: "verify-qa-x", text: "kind=verify-qa\nfamily=greet2\n" },      // family field wins
    { id: "greet2-note", text: "kind=self\n" },                            // self pane: no agent
    { id: "other-task", text: "kind=ship\n" },
    { id: "greet2x", text: "kind=ship\n" },                                // prefix trap: not greet2-*
  ];
  const ids = familyPaneIds(metas, "greet2").map((x) => x.id);
  expect(ids).toEqual(["greet2", "greet2-design", "greet2-frontend", "greet2-verify-codereview", "verify-qa-x"]);
});

test("chief input surface: closed key allowlist, single printable chars only", () => {
  for (const k of CHIEF_KEYS) expect(isChiefKey(k), k).toBe(true);
  expect(isChiefKey("ctrl+d")).toBe(false);   // EOF - never from the browser
  expect(isChiefKey("f12")).toBe(false);
  expect(isChiefKey("")).toBe(false);
  expect(isChiefChar("a")).toBe(true);
  expect(isChiefChar("Đ")).toBe(true);        // Vietnamese input is one char too
  expect(isChiefChar("ab")).toBe(false);      // never a string smuggled as a char
  expect(isChiefChar("\u001b")).toBe(false);  // never a raw escape byte
  expect(isChiefChar("")).toBe(false);
});

test("ansiToHtml renders SGR colors, strips other escapes, and escapes markup", () => {
  const h = ansiToHtml("\x1b[31mred\x1b[0m plain \x1b[1;92mbold-green\x1b[m");
  expect(h).toContain(">red</span>");
  expect(h).toContain("plain");
  expect(h).toContain("font-weight:700");
  // cursor-move and OSC escapes vanish, content survives
  const s2 = ansiToHtml("\x1b[2Jclear\x1b]0;title\x07after");
  expect(s2).toBe("clearafter");
  // pane bytes can never become markup
  expect(ansiToHtml("<script>x</script>")).not.toContain("<script>");
  // 256-color foreground
  expect(ansiToHtml("\x1b[38;5;196mX\x1b[0m")).toContain("rgb(255,0,0)");
});

test("ansiToHtml linkifies http(s) URLs - and only them - as safe anchors", () => {
  const h = ansiToHtml("see https://github.com/x/y/pull/12 for the PR");
  expect(h).toContain('<a href="https://github.com/x/y/pull/12" target="_blank" rel="noopener">https://github.com/x/y/pull/12</a>');
  // trailing punctuation stays prose, not part of the link
  expect(ansiToHtml("done (https://a.io/p).")).toContain('href="https://a.io/p"');
  expect(ansiToHtml("done (https://a.io/p).")).not.toContain('href="https://a.io/p).');
  // query strings survive escaped - the entity stays inside href and text
  const q = ansiToHtml("https://a.io/?x=1&y=2");
  expect(q).toContain('href="https://a.io/?x=1&amp;y=2"');
  // a URL inside a colored span still links
  expect(ansiToHtml("\x1b[34mhttps://a.io/b\x1b[0m")).toContain('<a href="https://a.io/b"');
  // markup around a URL can never smuggle attributes or tags
  const evil = ansiToHtml('x https://a.io/"><script>1</script> y');
  expect(evil).not.toContain("<script>");
  // non-http schemes are never linkified
  expect(ansiToHtml("open file:///etc/passwd or javascript:alert(1)")).not.toContain("<a ");
});

test("reviewWakeFamily: data/<family> names the scope; pooled, archived, and off-home paths do not", () => {
  const h = "/home/fleet";
  expect(reviewWakeFamily(h, "/home/fleet/data/dash-review/spec/report.md")).toBe("dash-review");
  expect(reviewWakeFamily(h, "/home/fleet/data/greet2/report.html")).toBe("greet2");
  // archived family: closed, no roomchief - fleet spool
  expect(reviewWakeFamily(h, "/home/fleet/data/archive/old-fam/report.md")).toBeNull();
  // pooled worktree page: outside data/ entirely
  expect(reviewWakeFamily(h, "/repo/.crew/worktrees/1/.lavish/page.html")).toBeNull();
  // a file directly under data/ has no family dir (the dot fails the id charset)
  expect(reviewWakeFamily(h, "/home/fleet/data/loose.html")).toBeNull();
  // segment outside the id charset never becomes a spool name
  expect(reviewWakeFamily(h, "/home/fleet/data/we ird/x.html")).toBeNull();
});

// --- whiteboard Notify-crew wake (dash-wb-notify) ---------------------------
test("whiteboardWakeParts folds the scene path + message onto one line and derives the id from the scene basename", () => {
  const w = whiteboardWakeParts("/home/whiteboards/batch-drain.excalidraw.json", "line 1\nline\t2  dài " + "x".repeat(300));
  expect(w.id).toBe("whiteboard-batch-drain-excalidraw-json");
  expect(w.payload.includes("\n")).toBe(false);
  expect(w.payload.includes("\t")).toBe(false);
  expect(w.payload).toContain("/home/whiteboards/batch-drain.excalidraw.json");
  expect(w.payload.length).toBeLessThanOrEqual(200);
});

test("redrawMessage: the Make-presentable button speaks the fixed REDRAW: prefix, note optional", () => {
  const bare = redrawMessage("");
  expect(bare.startsWith("REDRAW:")).toBe(true);
  expect(bare).toContain("import-excalidraw");
  expect(redrawMessage("   ")).toBe(bare);
  const noted = redrawMessage("  for the seam-contract gate page, doc-inline  ");
  expect(noted).toBe(bare + " - for the seam-contract gate page, doc-inline");
});

test("redrawReceipt: a valid chief-written receipt reads back; garbage, traversal, and absolute paths read as absent", async () => {
  const home = mkdtempSync(`${tmpdir()}/wb-redraw-`);
  try {
    mkdirSync(`${home}/whiteboards`, { recursive: true });
    expect(redrawReceipt(home, "scene-a")).toBe(null);
    writeFileSync(`${home}/whiteboards/scene-a.redraw.json`,
      JSON.stringify({ artifact: "data/redraw-scene-a/diagram.html", at: "2026-08-13T01:00:00Z" }));
    expect(redrawReceipt(home, "scene-a")).toEqual({ artifact: "data/redraw-scene-a/diagram.html", at: "2026-08-13T01:00:00Z" });
    writeFileSync(`${home}/whiteboards/scene-a.redraw.json`, JSON.stringify({ artifact: "/etc/passwd", at: "x" }));
    expect(redrawReceipt(home, "scene-a")).toBe(null);
    writeFileSync(`${home}/whiteboards/scene-a.redraw.json`, JSON.stringify({ artifact: "data/../../../etc/passwd", at: "x" }));
    expect(redrawReceipt(home, "scene-a")).toBe(null);
    writeFileSync(`${home}/whiteboards/scene-a.redraw.json`, "not json at all");
    expect(redrawReceipt(home, "scene-a")).toBe(null);
    expect(redrawReceipt(home, "../scene-a")).toBe(null);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("whiteboardWakeKey: same scene+message+mtime -> same key (dedupe hit)", () => {
  const a = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "ship it", 12345);
  const b = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "ship it", 12345);
  expect(a).toBe(b);
});

test("whiteboardWakeKey: a different message on the SAME scene+mtime -> a different key", () => {
  const a = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "ship it", 12345);
  const b = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "hold off", 12345);
  expect(a).not.toBe(b);
});

test("whiteboardWakeKey: a new save (mtime moves) on the SAME scene+message -> a different key", () => {
  const a = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "ship it", 12345);
  const b = whiteboardWakeKey("/h/whiteboards/s1.excalidraw.json", "ship it", 67890);
  expect(a).not.toBe(b);
});

// --- md review (line anchors) ------------------------------------------------
test("renderMarkdown srcline mode stamps blocks with their 1-based source line", () => {
  const out = renderMarkdown("# T\n\npara here\n\n- item\n\n```ts\nx\n```", true);
  expect(out).toContain('<h1 data-srcline="1">');
  expect(out).toContain('<p data-srcline="3">');
  expect(out).toContain('<li data-srcline="5">');
  expect(out).toContain('<pre data-srcline="7">');
  // default mode stays attribute-free
  expect(renderMarkdown("# T")).toBe("<h1>T</h1>");
});

test("normalizeAnnotation carries a positive integer source line and drops junk lines", () => {
  const mk = (line) => normalizeAnnotation(JSON.stringify({ text: "t", anchor: { selector: "#x", fingerprint: "f", line } }));
  expect(mk(42)!.anchor!.line).toBe(42);
  expect(mk(9.9)!.anchor!.line).toBe(9);
  expect(mk(0)!.anchor!.line).toBeUndefined();
  expect(mk("42")!.anchor!.line).toBeUndefined();
  expect(mk(null)!.anchor!.line).toBeUndefined();
});

// --- whiteboard-frame autosave (dash-review-polish slice 1) -----------------
test("wbfSceneSignature is stable for structurally identical elements", () => {
  const a = [{ id: "e1", type: "rectangle", x: 1, y: 2, version: 3 }];
  const b = [{ id: "e1", type: "rectangle", x: 1, y: 2, version: 3 }];
  expect(wbfSceneSignature(a)).toBe(wbfSceneSignature(b));
});

test("wbfSceneSignature changes when element content actually changes", () => {
  const before = [{ id: "e1", type: "rectangle", x: 1, y: 2, version: 3 }];
  const after = [{ id: "e1", type: "rectangle", x: 5, y: 2, version: 4 }];
  expect(wbfSceneSignature(before)).not.toBe(wbfSceneSignature(after));
});

test("wbfSceneSignature never throws on a missing or empty elements array", () => {
  expect(wbfSceneSignature(null as any)).toBe(wbfSceneSignature([]));
  expect(wbfSceneSignature(undefined as any)).toBe(wbfSceneSignature([]));
});

test("wbfShouldSave: no real change and no force -> does not save (view-only actions stay quiet)", () => {
  expect(wbfShouldSave({ signature: "s1", lastSavedSignature: "s1", saving: false })).toBe(false);
});

test("wbfShouldSave: a real content change (no force) -> saves", () => {
  expect(wbfShouldSave({ signature: "s2", lastSavedSignature: "s1", saving: false })).toBe(true);
});

test("wbfShouldSave: a save already in flight blocks any trigger, even a forced one (no double-fire)", () => {
  expect(wbfShouldSave({ signature: "s2", lastSavedSignature: "s1", saving: true })).toBe(false);
  expect(wbfShouldSave({ signature: "s2", lastSavedSignature: "s1", saving: true, force: true })).toBe(false);
});

test("wbfShouldSave: force (button click / Ctrl-S) saves even with no change, once nothing is in flight", () => {
  expect(wbfShouldSave({ signature: "s1", lastSavedSignature: "s1", saving: false, force: true })).toBe(true);
});

test("wbfShouldSave: a failed save never advances the baseline, so the next check still sees it dirty", () => {
  // The caller only advances lastSavedSignature on a wbf:"saved" ack with ok:true;
  // after a failed save the baseline is unchanged, so the same signature still reads dirty.
  const state = { signature: "s2", lastSavedSignature: "s1", saving: false };
  expect(wbfShouldSave(state)).toBe(true);
  expect(wbfShouldSave(state)).toBe(true);
});

// --- review-page remount guard (dash-review-polish-scroll defect 1) --------
// mtime is only the trigger to go look; reviewShouldRemount is the actual
// gate, decided from the freshly fetched body against what is mounted.

test("reviewShouldRemount: the first mount (nothing mounted yet) always proceeds", () => {
  expect(reviewShouldRemount(undefined, "<p>a</p>")).toBe(true);
  expect(reviewShouldRemount(null, "<p>a</p>")).toBe(true);
});

test("reviewShouldRemount: byte-identical content does not remount", () => {
  expect(reviewShouldRemount("<p>a</p>", "<p>a</p>")).toBe(false);
});

test("reviewShouldRemount: genuinely changed content does remount", () => {
  expect(reviewShouldRemount("<p>a</p>", "<p>b</p>")).toBe(true);
});

// --- review-page iframe reader CSS (review-page-missing-markdown-table-css) -
// The /review iframe (srcdoc, an independent document) inherits nothing from
// the SPA's own .reader ruleset, so readerCss(scope) is the ONE authoritative
// source both surfaces pull from - PAGE calls readerCss(".reader"), the
// iframe calls readerCss("") - never a second hand-copied ruleset.

test("readerCss(\".reader\"): every selector is scoped under .reader, matching PAGE's existing SPA rules", () => {
  const css = readerCss(".reader");
  expect(css).toContain(".reader table{");
  expect(css).toContain(".reader th,.reader td{");
  expect(css).toContain(".reader thead th{");
  expect(css).toContain(".reader .tablewrap{ overflow-x:auto;");
  expect(css).toContain(".reader pre code{");
  expect(css).not.toContain("body{");
});

test("readerCss(\"\"): unscoped for the iframe body, no leading dot/space left over", () => {
  const css = readerCss("");
  expect(css).toContain("table{");
  expect(css).toContain("th,td{");
  expect(css).toContain("thead th{");
  expect(css).toContain(".tablewrap{ overflow-x:auto;");
  expect(css).toContain("pre code{");
  expect(css).not.toContain(".reader");
  expect(css).not.toContain(".table{"); // no stray leftover dot from an empty scope prefix
});

test("readerCss: both scopes carry the same table border/collapse rules (no second style invented)", () => {
  expect(readerCss(".reader")).toContain("border-collapse:collapse");
  expect(readerCss("")).toContain("border-collapse:collapse");
  expect(readerCss(".reader")).toContain("border:1px solid var(--border); padding:5px 10px");
  expect(readerCss("")).toContain("border:1px solid var(--border); padding:5px 10px");
});

// --- review-page srcdoc composition (review-page-missing-markdown-table-css)
// buildReviewSrcdoc is the ONE decision point for "does this artifact get the
// reader stylesheet + theme": kind:"md" gets styled, every other kind
// (kind:"html" above all - it carries its own stylesheet) passes through
// byte-identical, unstyled and unwrapped.

test("buildReviewSrcdoc: kind:md gets the style block + theme/palette attrs prepended, content untouched after it", () => {
  const out = buildReviewSrcdoc("md", "<h1>hi</h1>", "<style>x</style>", "light", "teal");
  expect(out).toBe('<html data-theme="light" data-palette="teal"><style>x</style><h1>hi</h1>');
});

test("buildReviewSrcdoc: kind:md with no stored theme/palette (auto) carries no data-theme/data-palette attribute", () => {
  const out = buildReviewSrcdoc("md", "<h1>hi</h1>", "<style>x</style>", "", "");
  expect(out).toBe("<html><style>x</style><h1>hi</h1>");
});

test("buildReviewSrcdoc: kind:html is returned byte-identical - no style, no <html> wrapper, real artifact untouched", () => {
  const htmlArtifact = "<!doctype html><html><head><style>.mine{color:red}</style></head><body>mine</body></html>";
  expect(buildReviewSrcdoc("html", htmlArtifact, "<style>x</style>", "dark", "")).toBe(htmlArtifact);
});

test("buildReviewSrcdoc: kind:image/bin/text also pass through untouched (only md is styled)", () => {
  expect(buildReviewSrcdoc("image", "", "<style>x</style>", "dark", "")).toBe("");
  expect(buildReviewSrcdoc("text", "raw text", "<style>x</style>", "dark", "")).toBe("raw text");
});

// --- queue-feedback snapshot (dash-review-polish slice 3) -------------------
// resolveAnnotationSnapshot is the ONE decision of "when is there an image":
// only when the scene was actually saved to disk (sceneFileExists) AND the
// client handed over PNG bytes. Neither alone is enough - an embedded but
// never-saved editor (seed only) must never produce a file or a path.
test("resolveAnnotationSnapshot: edited scene (file exists) + valid PNG bytes -> a path and buffer", () => {
  const png = Buffer.concat([PNG_MAGIC_TEST, Buffer.from("fake-body")]);
  const r = resolveAnnotationSnapshot("/a/b.html", 4, true, png.toString("base64"), false);
  expect(r).not.toBeNull();
  expect(r!.path).toBe("/a/b.html.review-5.png");
  expect(r!.buffer.equals(png)).toBe(true);
});

test("resolveAnnotationSnapshot: unedited scene (no file on disk) -> null even with PNG bytes offered", () => {
  const png = Buffer.concat([PNG_MAGIC_TEST, Buffer.from("fake-body")]);
  expect(resolveAnnotationSnapshot("/a/b.html", 4, false, png.toString("base64"), false)).toBeNull();
});

test("resolveAnnotationSnapshot: scene file exists but no snapshot bytes offered -> null (no dead path)", () => {
  expect(resolveAnnotationSnapshot("/a/b.html", 4, true, undefined, false)).toBeNull();
});

test("resolveAnnotationSnapshot: scene file exists but the offered bytes are not a real PNG -> null", () => {
  const junk = Buffer.from("not a png at all");
  expect(resolveAnnotationSnapshot("/a/b.html", 4, true, junk.toString("base64"), false)).toBeNull();
});

// roomchief r1 finding: writing the PNG before reviewApply's own ended-check
// left an orphan file no record ever pointed to (a live probe reproduced it -
// POST a valid scene+snapshot against an ended session, a .review-N.png
// still landed on disk under the 409). The ended check now lives INSIDE this
// same decision function, not a separate guard in the route.
test("resolveAnnotationSnapshot: session already ended -> null even with a real edited scene and valid bytes (no orphan file)", () => {
  const png = Buffer.concat([PNG_MAGIC_TEST, Buffer.from("fake-body")]);
  expect(resolveAnnotationSnapshot("/a/b.html", 4, true, png.toString("base64"), true)).toBeNull();
});

test("reviewSnapshotPath derives a numbered png beside the artifact id, same root as the session file", () => {
  expect(reviewSnapshotPath("/home/data/fam/e2e/sample.html", 1)).toBe("/home/data/fam/e2e/sample.html.review-1.png");
});

test("decodePngSnapshot accepts real PNG magic bytes and rejects non-PNG or junk base64", () => {
  const real = Buffer.concat([PNG_MAGIC_TEST, Buffer.from([1, 2, 3])]);
  const got = decodePngSnapshot(real.toString("base64"));
  expect(got).not.toBeNull();
  expect(got!.equals(real)).toBe(true);
  expect(decodePngSnapshot(Buffer.from("not a png").toString("base64"))).toBeNull();
  expect(decodePngSnapshot("")).toBeNull();
});

test("normalizeAnnotation carries an optional scene+snapshot pair for queue-feedback, dropping non-string/empty values", () => {
  const a = normalizeAnnotation(JSON.stringify({ text: "t", scene: "diagram-d1", snapshot: "QUJD" }));
  expect(a!.scene).toBe("diagram-d1");
  expect(a!.snapshot).toBe("QUJD");
  const b = normalizeAnnotation(JSON.stringify({ text: "t" }));
  expect(b!.scene).toBeUndefined();
  expect(b!.snapshot).toBeUndefined();
  const c = normalizeAnnotation(JSON.stringify({ text: "t", scene: "", snapshot: 7 }));
  expect(c!.scene).toBeUndefined();
  expect(c!.snapshot).toBeUndefined();
});

test("reviewApply attaches an image field to the queued record only when the action carries one", () => {
  const s0 = emptyReviewSession("/a/b.html");
  const withImage = reviewApply(s0, { type: "annotate", anchor: null, text: "t", at: "T", image: "/a/b.html.review-1.png" }) as ReturnType<typeof emptyReviewSession>;
  expect(withImage.queue[0].image).toBe("/a/b.html.review-1.png");
  const s1 = reviewApply(s0, { type: "annotate", anchor: null, text: "t", at: "T" }) as ReturnType<typeof emptyReviewSession>;
  expect("image" in s1.queue[0]).toBe(false);
});

// --- applyProviderLane: per-lane brain config writes (embedding | synthesize) ---
// The captain's real setup is a SPLIT - embeddings on one provider, synthesize
// on another - so a lane write must never touch the other lane's block.

import { applyProviderLane, PROVIDER_LANES } from "./dashboard.ts";

test("applyProviderLane embedding: writes key + embedding block only, synthesize untouched", () => {
  const bj = { synthesize: { api: { provider: "opencode-go", model: "kimi-k2.7-code" } } };
  const r = applyProviderLane(bj, {}, { lane: "embedding", provider: "openrouter", model: "openai/text-embedding-3-small", api_key: "sk-x" }) as any;
  expect(r.error).toBeUndefined();
  expect(r.bj.embedding).toEqual({ provider: "openrouter", model: "openai/text-embedding-3-small", dims: 1536 });
  expect(r.bj.synthesize.api.model).toBe("kimi-k2.7-code");
  expect(r.store.openrouter.api_key).toBe("sk-x");
});

test("applyProviderLane synthesize: free-model write leaves embedding untouched", () => {
  const bj = { embedding: { provider: "openrouter", model: "openai/text-embedding-3-small", dims: 1536 } };
  const r = applyProviderLane(bj, {}, { lane: "synthesize", provider: "opencode-go", model: "deepseek-v4-pro", api_key: "" }) as any;
  expect(r.error).toBeUndefined();
  expect(r.bj.synthesize.api).toEqual({ provider: "opencode-go", model: "deepseek-v4-pro" });
  expect(r.bj.embedding.dims).toBe(1536);
  expect(Object.keys(r.store).length).toBe(0);  // no key offered, none written
});

test("applyProviderLane: omitted model falls to the lane default for that provider", () => {
  const r1 = applyProviderLane({}, {}, { lane: "synthesize", provider: "opencode-go" }) as any;
  expect(r1.bj.synthesize.api.model).toBe("kimi-k2.7-code");
  const r2 = applyProviderLane({}, {}, { lane: "embedding", provider: "ollama" }) as any;
  expect(r2.bj.embedding).toEqual({ provider: "ollama", model: "nomic-embed-text", dims: 768 });
});

test("applyProviderLane embedding: model must be a KNOWN model (dims are load-bearing)", () => {
  const r = applyProviderLane({}, {}, { lane: "embedding", provider: "openrouter", model: "some/unknown-embed" }) as any;
  expect(r.error).toContain("unknown embedding model");
});

test("applyProviderLane: dims change carries the rebuild warning", () => {
  const bj = { embedding: { provider: "ollama", model: "nomic-embed-text", dims: 768 } };
  const r = applyProviderLane(bj, {}, { lane: "embedding", provider: "openai", model: "text-embedding-3-large" }) as any;
  expect(r.warn).toContain("sync --rebuild");
});

test("applyProviderLane: a provider outside its lane's set is refused", () => {
  const r = applyProviderLane({}, {}, { lane: "embedding", provider: "opencode-go" }) as any;
  expect(r.error).toBeTruthy();
  const r2 = applyProviderLane({}, {}, { lane: "nope", provider: "openai" }) as any;
  expect(r2.error).toBeTruthy();
});

test("PROVIDER_LANES: synthesize offers opencode-go, embedding does not", () => {
  expect(Object.keys(PROVIDER_LANES.synthesize)).toContain("opencode-go");
  expect(Object.keys(PROVIDER_LANES.embedding)).not.toContain("opencode-go");
});

// ---- fleetAttnItems (fleets-attn-queue) -----------------------------------
import { fleetAttnItems } from "./dashboard.ts";

const ATTN_SNAP = {
  homes: [
    {
      name: "drydock",
      watcher: { state: "armed" },
      inbox: { entries: [
        { status: "PENDING-CAPTAIN(1)", family: "payments", last: "GATE: plan awaiting captain" },
        { status: "HANDBACK", family: "docs-pass", last: "HANDBACK: landed" },
      ] },
      crewdeputies: [
        { name: "demo", watcher: { state: "down" }, inbox: { entries: [] } },
      ],
    },
    {
      name: "lab",
      watcher: { state: "down", detail: "no beacon" },
      inbox: { entries: [{ status: "PENDING-CAPTAIN(2)+HANDBACK", family: "fx", last: "combined" }] },
    },
  ],
};

test("fleetAttnItems: pending, then handback, then watcher-down", () => {
  const items = fleetAttnItems(ATTN_SNAP);
  expect(items.map((i) => i.kind)).toEqual(["pending", "pending", "handback", "handback", "watcher", "watcher"]);
  expect(items[0]).toMatchObject({ fleet: "drydock", family: "payments" });
});

test("fleetAttnItems: a combined PENDING+HANDBACK entry lands in both bands", () => {
  const items = fleetAttnItems(ATTN_SNAP).filter((i) => i.fleet === "lab" && i.family === "fx");
  expect(items.map((i) => i.kind).sort()).toEqual(["handback", "pending"]);
});

test("fleetAttnItems: walks one level of crewdeputies (demo's dead watcher shows)", () => {
  const w = fleetAttnItems(ATTN_SNAP).filter((i) => i.kind === "watcher").map((i) => i.fleet);
  expect(w).toEqual(["demo", "lab"]);
});

test("fleetAttnItems: empty/garbage snapshot never throws", () => {
  expect(fleetAttnItems(null)).toEqual([]);
  expect(fleetAttnItems({ homes: [{}] })).toEqual([]);
});

// ---- two-mode commenting: range anchors through the normalizer ------------
test("normalizeAnnotation: a range pin keeps quote/prefix/suffix, capped", () => {
  const a = normalizeAnnotation(JSON.stringify({
    text: "note",
    anchor: { selector: "#x", fingerprint: "f", quote: "q".repeat(300), prefix: "p".repeat(100), suffix: "s" },
  }))!;
  expect(a.anchor!.quote!.length).toBe(200);
  expect(a.anchor!.prefix!.length).toBe(64);
  expect(a.anchor!.suffix).toBe("s");
});

test("normalizeAnnotation: element pins carry no range fields; junk quote dropped", () => {
  const a = normalizeAnnotation(JSON.stringify({ text: "note", anchor: { selector: "#x", fingerprint: "f", quote: "   " } }))!;
  expect(a.anchor!.quote).toBeUndefined();
  const b = normalizeAnnotation(JSON.stringify({ text: "note", anchor: { selector: "#x", fingerprint: "f" } }))!;
  expect(b.anchor!.quote).toBeUndefined();
});

// ---- crewdomain-token on the client parser --------------------------------
test("parseBacklogLine: domain token is position-pinned, epic coexists, prose inert", () => {
  const a = parseBacklogLine("- [ ] payx - do it; domain:payments (repo: alpha)");
  expect(a.domain).toBe("payments");
  const b = parseBacklogLine("- [x] payx - done (merged 2026-08-18); domain:payments");
  expect(b.domain).toBe("payments");
  const c = parseBacklogLine("- [ ] s1 - story; epic:payx; domain:payments (repo: alpha)");
  expect(c.domain).toBe("payments");
  expect(c.epic).toBe("payx");
  const d = parseBacklogLine("- [ ] p - mentions domain:payments mid-prose (repo: alpha)");
  expect(d.domain).toBe("");
});
