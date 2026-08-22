// app.ts - agent-crew local web dashboard (Bun runtime, no build step).
//
// Launched by bin/ac-dashboard.sh via the bin/dashboard.ts shim, which imports
// this module and calls dashboardMain().
// Serves ONE self-contained SPA shell (inline CSS + inline vanilla JS, no
// framework, no CDN, no external asset) over 127.0.0.1 only. The shell hosts a
// real-route desktop web app (guide §4): every non-/api GET path returns the
// same shell so a deep link or reload of a client route is refresh-safe, and the
// client History-API router resolves the path (unknown -> in-app not-found, never
// a reload loop). Each primary route fetches/polls ONLY its own narrow endpoint.
//
// READ-ONLY except the sanctioned actions: the config-editor (dash-config, A2)
// POST /api/config writes ONE allowlisted flat value-file under <home>/config/
// (name allowlist -> realpathSync gate -> value-integrity -> write + a durable
// receipt line); the dispatch-editor (dash-crew-dispatch) POST /api/dispatch
// validates and atomic-writes the FIXED-name config/crew-dispatch.json (JSON +
// shape validation -> realpathSync gate -> tmp+rename -> receipt); plus the
// whiteboard scene writes and the review-session writes documented at their
// routes below. Otherwise the
// server writes nothing, locks nothing, drives no backend (each write is a
// security boundary, not a general write). Its data layer shells
// out ONLY to the fixed read-only survey scripts (ac-fleets.sh --json,
// ac-room.sh list/show, ac-lib.sh's ac_domain_tally for the Domains route)
// and reads ONLY the fixed config/state/records/slots
// paths named in the design's §2 data-source map, plus discovered artifact files
// under a home's data/ or a leased worktree's .lavish/ (Slice 3a). It
// re-implements NO accounting: the inbox/handback counts, the home walk and the
// pending grammar all come from the bash scripts; TS parses their output for
// display, it never re-derives a field (the single most important rule).
//
// Routes:
//   GET  /* (non-/api)         -> the SPA shell page (deep-link / reload safe)
//   GET  /attach-frame?path=<home>&(fleet=1|family=<fam>)[&watch=<id>] -> standalone xterm page over the attach ws below: ONE task pane, full width, typed input via roomInput (chief-pane-native-attach, re-landed as its own URL - the chief panel stays on the snapshot stream)
//   WS   /api/room/attach-ws?path=<home>&(fleet=1|family=<fam>)[&watch=<id>] -> native byte-stream of that pane (`herdr agent attach` on a server pty at the PANE's own geometry, reattached when the pane resizes; output-only - the attach pty is a pure viewer, measured)
//   GET  /api/snapshot.json    -> ac-fleets.sh --json, passed through (Fleets route + shell health)
//   GET  /api/processes?path=<home> -> {rooms,pools,remote} for the Processes route
//   GET  /api/backlog?path=<home>   -> {backlog:{in_flight,queued,done}} for the Backlog route
//   GET  /api/reports?path=<home>   -> {artifacts:[...]} master list for the Reports route
//   GET  /api/ledgers?path=<home>   -> {records:[...]} ledger list for the Records route
//   GET  /api/domains?path=<home>   -> {domains:[...]} crewdomain registry + package detail for the Domains route (dash-domain-records)
//   GET  /api/learning?path=<home>  -> normalized fleet-local learning metadata and safe rendered content
//   GET  /api/config-list?path=<home> -> {editable,log,dispatch} for the Config route (dispatch = crew-dispatch.json view)
//   GET  /api/room?path=<home>&family=<fam> -> full room narrative (viewer detail)
//   GET  /api/family?path=<home>&family=<fam> -> composed per-family detail: backlog line + stages + design html + progress + PR link + room + epic rollup + reused-data pointers (Board drill-down, dashboard-board)
//   GET  /api/diff?path=<home>&id=<task>[&mode=live|committed|uncommitted|untracked|graph|commit][&tree=<worktree>][&ref=<branch>][&sha=<sha>] -> that task's unified diff / graph data via bin/ac-review-diff.sh (mode default live; tree must be pool-listed or a project root; ref must be a local branch - the Worktrees tab)
//   POST /api/repo/pull?path=<home>&repo=<name> -> fetch + FF-ONLY sync of that project clone via bin/ac-repo-pull.sh (captain-ordered; the one repo-mutating control)
//   GET  /api/artifact?path=<home>&file=<f> -> ONE artifact rendered read-only (viewer detail)
//   POST /api/reveal?path=<home>&file=<f> -> reveal the artifact in Finder (`open -R`, same path gate as /api/artifact; Reports viewer button)
//   GET  /api/records?path=<home>&file=<ledger> -> ONE records/ ledger rendered read-only (viewer detail)
//   GET  /api/config?path=<home>&file=<knob> -> current value of ONE editable config knob (dash-config)
//   GET  /api/search?q=<query> -> cross-fleet backlog-line hits {home,family,line,section} (dash-search)
//   POST /api/config?path=<home>&file=<knob> (body: new value) -> write ONE editable knob + receipt (dash-config)
//   POST /api/dispatch?path=<home> (body: full JSON) -> validate + atomic-write config/crew-dispatch.json + receipt (dash-crew-dispatch)
//   GET  /api/whiteboard?path=<home>[&scene=<name>] -> scene JSON, or the scene list (dash-whiteboard)
//   POST /api/whiteboard?path=<home>&scene=<name> (body: scene) -> normalize + atomic-write ONE scene file, guarded by an If-Match precondition: send the version you read (from the GET's ETag), or 428/412 with {error,version,scene} (whiteboard-agent-write-clobbers-captain-edits). If-Match: * force-overwrites - captain-only, never for an agent. A scene that does not exist yet needs no precondition.
//   POST /api/whiteboard?path=<home>&scene=<name>&notify=1 (body: message) -> publish ONE deduped kind=whiteboard fleet wake carrying the scene path + message (dash-wb-notify). The Make-presentable button rides this same endpoint with the fixed redrawMessage() REDRAW: message - no separate API.
//   GET  /api/whiteboard?path=<home>&scene=<name>&redraw=1 -> the scene's redraw RECEIPT ({artifact,at}, or {} while none) written by the chief at <home>/whiteboards/<scene>.redraw.json; the page polls it and shows an open-in-review link, closing the click -> artifact loop for the captain.
//   GET  /whiteboard?path=<home>&scene=<name>[&seed=<mermaid>] -> standalone Excalidraw editor page; seed imports onto an EMPTY scene only (dash-whiteboard)
//   GET  /api/review/diagrams?path=<home>&file=<f> -> the artifact's mermaid sources + their hand-off scene names (dash-whiteboard phase 2)
//   GET  /api/reviews?path=<home> -> every review session of the home {reviews:[{id,path,family,state,endedBy,pins,messages,mtime,listening}]} (Reviews route)
//   GET  /api/reviews?all=1 -> every OPEN review session of EVERY home, each row also carrying `home` {reviews:[{...,home}]} (dash-review-polish-xhome)
//   POST /api/review/share?path=<home>&file=<f>[&stop=1] -> mint-or-return (or revoke) the session's guest token link; the token-gated SECOND listener on port+1 (0.0.0.0) serves GET /review/<token> + the guest API subset and 404s everything else (REVIEW SHARE block)

import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { Database as BrainDb } from "bun:sqlite";

const BIN = new URL("../bin", import.meta.url).pathname; // the fleet's bin/ (this module lives in dashboard/)
const AC_HOME = process.env.AC_HOME ?? "";


// The pure layer and the SPA shell live beside this file; the shim
// (bin/dashboard.ts) re-exports this module, so re-exporting lib.ts here keeps
// the historical single-module import surface (tests, ac-contract differential).
import {
  ANSI_DARK, ANSI_LIGHT, ArtifactKind, ArtifactMeta, ArtifactNode, BacklogHit, 
  BacklogLineFields, BacklogView, FamilyDetail, FamilyPr, FamilyStage, FamilySubtask, 
  LearningLedgerView, LearningPointer, Progress, RoomRow, StageArtifact, THEME_INIT, THEME_VARS, 
  TimelineEvent, UX_BASE, artifactKind, artifactPainted, backlogFamilyIds, boardSystemPanes, buildReviewSrcdoc, 
  cadenceLabel, chiefFitPx, clampBgDim, composeFamily, contractTokens, deriveProgress, 
  familyOfTaskId, familyRepos, familyStages, fleetAttnItems, groupArtifacts, isHtmlArtifact, 
  matchBacklog, mermaidPass, nextPalette, nextTheme, normalizeBgColor, parseArtifactPath, 
  parseBacklog, parseBacklogLine, parseLearningLedger, parseRoomList, parseTimeline, readerCss, 
  renderMarkdown, resolvePalette, resolveTheme, reviewableArtifact, stemRegroup, storyState, 
  termThemeCore, verifyProcessRows, escapeHtml,
} from "./lib.ts";
export * from "./lib.ts";
import { PAGE } from "./page.ts";
// ---------------------------------------------------------------------------
// Records ledgers (dash-records): the fleet's records/ markdown ledgers, read
// read-only via the shared renderMarkdown. The name allowlist below is the
// security boundary - ONLY these five exact names pass, so any other name, any
// `../`, any absolute or nested path is rejected before a path is ever joined.
// ---------------------------------------------------------------------------

/** The fixed records/ ledgers dash-records surfaces, in listing order. */
export const RECORD_LEDGERS = [
  "backlog.md",
  "projects.md",
  "captain.md",
  "learnings.md",
  "crewdeputies.md",
] as const;

/** True iff `name` is exactly one of the five records ledgers (no path, no traversal). */
export function isRecordLedger(name: string): boolean {
  return (RECORD_LEDGERS as readonly string[]).includes(name);
}

/**
 * True iff `name` is a per-project knowledge record - `repo-knowledge/<repo>.md`,
 * the ONE subdirectory of records/ the reader serves besides the five ledgers.
 * The board detail links these (a family's intake is obliged to read them,
 * AGENTS.md section 5), and a link nothing serves is a link that does nothing.
 * The prefix is a FIXED literal and the name may not contain `/` or start with
 * `.`, so no user-controlled segment can climb: `..` needs a slash to leave the
 * directory, and recordsShow's realpath-under-<home>/records gate is still the
 * second wall behind this one.
 */
export function isRepoKnowledge(name: string): boolean {
  return /^repo-knowledge\/[A-Za-z0-9][A-Za-z0-9._-]*\.md$/.test(String(name || ""));
}

/**
 * True iff the learnings ledger names `family` - the test behind the detail's
 * "learnings ledger" row. A lesson is cited `(by: <task-id>, first-hand)` and
 * older ones name the family in prose, so this matches the id as a WHOLE token
 * rather than the citation shape alone: the surrounding char may not be
 * `[a-z0-9-]`, which is what stops an epic id from matching inside every one of
 * its stories' ids (measured on a live ledger: `<epic>` 5 hits, not the 20+ a
 * naive substring match would claim).
 */
export function learningsCiteFamily(text: string, family: string): boolean {
  const f = String(family || "");
  if (!f) return false;
  return new RegExp("(^|[^a-z0-9-])" + f.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "([^a-z0-9-]|$)").test(String(text || ""));
}

// ---------------------------------------------------------------------------
// Crewdomains (dash-domain-records): read-only render of records/crewdomains.md
// (the routing table, bin/ac-lib.sh:461-550) and each registered package at
// crewdomains/<name>/ (the four-member shape, bin/ac-domain.sh's `new` header).
// The tally is the ONE piece of accounting this file never re-derives: it
// shells out to the fleet's own ac_domain_tally (bin/ac-lib.sh:625) instead of
// counting backlog lines a second way.
// ---------------------------------------------------------------------------

export interface DomainRegistryRow {
  cls: "VALID" | "INVALID";
  id: string; // VALID: the domain id. INVALID: the verbatim source line.
  charter: string;
  scope: string;
  added: string; // VALID only
  reason: string; // INVALID only
}

/** Parse records/crewdomains.md (the "crewdomain routing table" grammar owned
 *  by bin/ac-lib.sh:461-550 / ac_domain_parse) read-only for display. Mirrors
 *  that awk's field order and failure reasons exactly, so this table and the
 *  session-start digest never disagree about which line is valid - it is a
 *  second READER of the one grammar, not a second grammar, and it exists only
 *  because ac_domain_parse has no --json form and this task may not touch
 *  ac-domain.sh/ac-lib.sh to add one. */
export function parseCrewdomains(md: string): DomainRegistryRow[] {
  const out: DomainRegistryRow[] = [];
  const seen = new Set<string>();
  const bad = (line: string, reason: string): DomainRegistryRow => ({
    cls: "INVALID", id: line, charter: "", scope: "", added: "", reason,
  });
  for (const line of md.split("\n")) {
    // NO rstrip: ac_domain_parse anchors ` \(added [^)]*\)$` on the RAW line
    // (bin/ac-lib.sh:496), so trailing whitespace or a CRLF '\r' here must
    // fail the added-suffix check exactly like the awk does - trimming it
    // first would accept a line the CLI's own `list` refuses.
    if (line.slice(0, 2) !== "- ") continue; // heading/blank/prose - never parsed
    const full = line;
    let rest = line.slice(2);
    const addedMatch = rest.match(/ \(added ([^)]*)\)$/);
    if (!addedMatch) { out.push(bad(full, 'missing "(added ...)"')); continue; }
    const added = addedMatch[1];
    rest = rest.slice(0, addedMatch.index);
    // Drop the one legitimate keyed field, then any keyed token left over is a
    // field this grammar does not have (checked before the scope split, so a
    // `home:` line is refused by name rather than a downstream symptom).
    const probe = rest.replace(" - scope:", "");
    const unknown = probe.match(/ - [a-zA-Z][a-zA-Z0-9_-]*:/);
    if (unknown) { out.push(bad(full, `unknown field "${unknown[0].slice(3)}"`)); continue; }
    const p = rest.indexOf(" - scope:");
    if (p < 0) { out.push(bad(full, 'missing "scope:" field')); continue; }
    const head = rest.slice(0, p);
    const scope = rest.slice(p + 9).trim();
    const q = head.indexOf(" - ");
    let id: string, charter: string;
    if (q > 0) { id = head.slice(0, q).trim(); charter = head.slice(q + 3).trim(); }
    else { id = head.trim(); charter = ""; }
    if (!charter) { out.push(bad(full, "missing charter field")); continue; }
    if (!/^[a-z0-9-]+$/.test(id)) { out.push(bad(full, "bad id charset")); continue; }
    if (seen.has(id)) { out.push(bad(full, "duplicate id")); continue; }
    seen.add(id);
    out.push({ cls: "VALID", id, charter, scope, added, reason: "" });
  }
  return out;
}

export interface DomainProjectLink {
  name: string;
  target: string; // resolved absolute path when linked ok; raw readlink text when dangling
  dangling: boolean;
}

/** One entry per item in a domain package's projects/ view - name, resolved
 *  target, and whether it dangles. Display only (no membership/mismatch
 *  guard - that is ac-domain.sh's write-side job); missing projects/ -> []. */
export function domainProjectLinks(pkg: string): DomainProjectLink[] {
  const dir = `${pkg}/projects`;
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const out: DomainProjectLink[] = [];
  for (const name of names) {
    const entry = `${dir}/${name}`;
    try {
      out.push({ name, target: realpathSync(entry), dangling: false });
    } catch {
      let raw = "";
      try { raw = readlinkSync(entry); } catch { /* not even a symlink - report it dangling with no target */ }
      out.push({ name, target: raw, dangling: true });
    }
  }
  return out;
}




export interface DomainTally {
  queued: number;
  inFlight: number;
  done: number;
}

/** ac_domain_tally (fleet-ledger token census since crewdomain-token), run for every VALID id in ONE sourced
 *  bash invocation - not one shell-out per domain - so this route never grows
 *  the unbounded per-domain process-spawn loop the performance guard warns
 *  against (the ac-room.sh fork-per-room fix this same month is the fleet's
 *  own example of that cost). Absence from the returned map (spawn failure)
 *  is the caller's null-backlog case. */
async function domainTallies(homePath: string, ids: string[]): Promise<Map<string, DomainTally>> {
  const out = new Map<string, DomainTally>();
  if (!ids.length) return out;
  const { code, out: text } = await run(
    ["bash", "-c",
     `. "$1/ac-lib.sh" || exit 1; shift; for id in "$@"; do printf '%s\\t' "$id"; ac_domain_tally "$id"; done`,
     "--", BIN, ...ids],
    { AC_HOME: homePath },
  );
  if (code !== 0) return out;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    const id = line.slice(0, tab);
    const [q, i, d] = line.slice(tab + 1).trim().split(/\s+/).map((n) => Number(n) || 0);
    out.set(id, { queued: q, inFlight: i, done: d });
  }
  return out;
}

export interface DomainMembers {
  projectsDoc: boolean;
  crewmate: boolean;
}

export interface DomainEntry extends DomainRegistryRow {
  backlog: DomainTally | null;
  members: DomainMembers | null;
  projectsHtml: string | null;
  crewmateHtml: string | null;
  projects: DomainProjectLink[];
}

/** Domains route (dash-domain-records): the registry table (surface a) plus,
 *  per VALID entry, its package's tally + detail members (surface b). The
 *  backlog.md member is a TALLY only (ac_domain_tally, shelled out once for
 *  every id above); records/projects.md and CREWMATE.md are rendered in full
 *  like a Records ledger, and eagerly - the same eager-render shape
 *  collectLearning already uses for every skill's SKILL.md/evidence, sized the
 *  same way (a small, bounded number of domains, not the room-count-sized
 *  loop the performance guard is about). */
async function domainsDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const registryFile = `${homePath}/records/crewdomains.md`;
  let rows: DomainRegistryRow[] = [];
  if (existsSync(registryFile)) {
    try { rows = parseCrewdomains(readFileSync(registryFile, "utf8")); } catch { rows = []; }
  }
  const validIds = rows.filter((r) => r.cls === "VALID").map((r) => r.id);
  const tallies = await domainTallies(homePath, validIds);
  const domains: DomainEntry[] = rows.map((r) => {
    if (r.cls === "INVALID")
      return { ...r, backlog: null, members: null, projectsHtml: null, crewmateHtml: null, projects: [] };
    const pkg = `${homePath}/crewdomains/${r.id}`;
    let projectsHtml: string | null = null;
    let crewmateHtml: string | null = null;
    try { projectsHtml = renderMarkdown(readFileSync(`${pkg}/records/projects.md`, "utf8")); } catch { /* missing member */ }
    try { crewmateHtml = renderMarkdown(readFileSync(`${pkg}/CREWMATE.md`, "utf8")); } catch { /* missing member */ }
    return {
      ...r,
      backlog: tallies.get(r.id) ?? null,
      members: {
        projectsDoc: projectsHtml !== null,
        crewmate: crewmateHtml !== null,
      },
      projectsHtml,
      crewmateHtml,
      projects: domainProjectLinks(pkg),
    };
  });
  return json({ domains });
}

// ---------------------------------------------------------------------------
// Small file readers (flat value-files only; §2.4/§2.5). Every path is under a
// home resolved from the snapshot's allowlist - nothing walks arbitrary paths.
// ---------------------------------------------------------------------------

/** Human-readable byte size for the binary/oversize viewer notes. */
function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function firstLine(path: string): string {
  try {
    return readFileSync(path, "utf8").split("\n")[0].trim();
  } catch {
    return "";
  }
}

function metaGet(path: string, key: string): string {
  try {
    let v = "";
    for (const line of readFileSync(path, "utf8").split("\n")) {
      if (line.startsWith(key + "=")) v = line.slice(key.length + 1);
    }
    return v.trim();
  } catch {
    return "";
  }
}

type LearningStatus = "active" | "stale" | "shadowed";

export interface LearningDecisionView {
  mode: string;
  subject: string;
  decision: string;
  authority: string;
  engine: string;
  model: string;
  reviewed_at: string;
  grounds: string;
  apply_state: string;
  mtime: number;
  html: string;
}

export interface LearningSkillView {
  name: string;
  description: string;
  landed: string;
  updated: string;
  mtime: number;
  sources: number;
  seeded_count: number;
  last_seeded: string;
  status: LearningStatus;
  latest_decision: LearningDecisionView | null;
  skill_html: string;
  evidence_html: string | null;
}

export interface LearningArchiveView {
  kind: "evidence" | "skill" | "captain" | "backlog" | "index";
  name: string;
  mtime: number;
  html: string;
}

export interface LearningView {
  skills: LearningSkillView[];
  pending: {
    html: string;
    raw_count: number;
    active_run: string | null;
    waiting: LearningDecisionView[];
    waiting_gate: { subject: string; state: string }[];
    migration: LearningPointer[];
  };
  archives: LearningArchiveView[];
  decisions: LearningDecisionView[];
}

function learningSlug(name: string): boolean {
  return (
    name.length <= 64 &&
    /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)
  );
}

function unquoteScalar(value: string): string {
  const v = value.trim();
  if (
    v.length >= 2 &&
    ((v.startsWith('"') && v.endsWith('"')) ||
      (v.startsWith("'") && v.endsWith("'")))
  )
    return v.slice(1, -1);
  return v;
}

/** Read one scalar from the first YAML frontmatter block. Nested metadata keys
 * are intentionally flattened because learned skills keep `landed` beneath
 * `metadata:` while gate receipts keep every field at the root. */
function frontmatterField(md: string, key: string): string {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  if (lines[0] !== "---") return "";
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === "---") break;
    const trimmed = lines[i].trimStart();
    if (!trimmed.startsWith(key + ":")) continue;
    return unquoteScalar(trimmed.slice(key.length + 1));
  }
  return "";
}

function epochDisplay(value: string): string {
  if (!/^\d+$/.test(value)) return value;
  const n = Number(value);
  if (!Number.isFinite(n)) return value;
  return new Date(n * 1000).toISOString();
}

/**
 * Resolve a server-chosen relative path beneath one fixed root. Every existing
 * component is resolved before the containment check, so a symlink escape
 * returns null. Callers never pass a client-provided root or relative path.
 */
function learningFile(
  rootPath: string,
  rel: string,
): { real: string; text: string; mtime: number } | null {
  if (
    !rel ||
    rel.startsWith("/") ||
    rel.split("/").some((part) => !part || part === "." || part === "..")
  )
    return null;
  let root: string;
  let real: string;
  try {
    root = realpathSync(rootPath);
    real = realpathSync(`${rootPath}/${rel}`);
  } catch {
    return null;
  }
  if (!real.startsWith(root + "/")) return null;
  try {
    const st = statSync(real);
    if (!st.isFile()) return null;
    return { real, text: readFileSync(real, "utf8"), mtime: st.mtimeMs };
  } catch {
    return null;
  }
}

function learningWalk(
  rootPath: string,
  accept: (rel: string) => boolean,
): { rel: string; text: string; mtime: number }[] {
  const out: { rel: string; text: string; mtime: number }[] = [];
  let root: string;
  try {
    root = realpathSync(rootPath);
  } catch {
    return out;
  }
  const walk = (dir: string, relDir: string, depth: number) => {
    if (depth > 8) return;
    let entries: import("node:fs").Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".") || entry.isSymbolicLink()) continue;
      const rel = relDir ? `${relDir}/${entry.name}` : entry.name;
      const full = `${dir}/${entry.name}`;
      if (entry.isDirectory()) {
        walk(full, rel, depth + 1);
      } else if (entry.isFile() && accept(rel)) {
        let real: string;
        try {
          real = realpathSync(full);
        } catch {
          continue;
        }
        if (!real.startsWith(root + "/")) continue;
        try {
          const st = statSync(real);
          out.push({
            rel,
            text: readFileSync(real, "utf8"),
            mtime: st.mtimeMs,
          });
        } catch {
          /* unreadable files are absent from the normalized API */
        }
      }
    }
  };
  walk(root, "", 0);
  return out;
}

function learningApplyState(homePath: string, subject: string): string {
  const root = `${homePath}/state/.maintenance-transactions`;
  const journals = learningWalk(
    root,
    (rel) => rel.endsWith(`-${subject}/journal`) && rel.split("/").length === 2,
  ).sort((a, b) => b.mtime - a.mtime);
  return journals.length ? metaValue(journals[0].text, "status") || "unknown" : "not-applied";
}

function metaValue(text: string, key: string): string {
  let value = "";
  for (const line of text.split("\n")) {
    if (line.startsWith(key + "=")) value = line.slice(key.length + 1).trim();
  }
  return value;
}

function collectLearningDecisions(homePath: string): LearningDecisionView[] {
  const files = learningWalk(
    `${homePath}/data`,
    (rel) =>
      /(?:^|\/)gates\/[a-z0-9]+(?:-[a-z0-9]+)*\/decision\.md$/.test(rel),
  );
  const out: LearningDecisionView[] = [];
  for (const file of files) {
    const schema = frontmatterField(file.text, "schema");
    const subject = frontmatterField(file.text, "subject");
    const decision = frontmatterField(file.text, "decision");
    if (
      schema !== "agentcrew.maintenance-gate/v1" ||
      !learningSlug(subject) ||
      !["continue", "revise", "ask-captain"].includes(decision)
    )
      continue;
    const grounds = file.text.match(
      /(?:^|\n)## Grounds\s*\n+([\s\S]*?)(?=\n## |\s*$)/,
    );
    out.push({
      mode: frontmatterField(file.text, "mode"),
      subject,
      decision,
      authority: frontmatterField(file.text, "authority"),
      engine: frontmatterField(file.text, "engine"),
      model: frontmatterField(file.text, "model"),
      reviewed_at: frontmatterField(file.text, "reviewed_at"),
      grounds: grounds ? grounds[1].trim() : "",
      apply_state: learningApplyState(homePath, subject),
      mtime: file.mtime,
      html: renderMarkdown(file.text),
    });
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

function learningRunPending(
  homePath: string,
  runName: string,
): { active: boolean; waiting: { subject: string; state: string }[] } {
  const root = `${homePath}/data/${runName}`;
  if (
    !learningFile(`${homePath}/data`, `${runName}/report.md`) ||
    !learningFile(`${homePath}/data`, `${runName}/retro.md`)
  )
    return { active: true, waiting: [] };
  const candidates = learningWalk(
    root,
    (rel) => /(?:^|\/)candidate-[^/]+\.md$/.test(rel),
  );
  const waiting: { subject: string; state: string }[] = [];
  for (const candidate of candidates) {
    const name = candidate.text
      .split("\n")
      .find((line) => line.startsWith("name: "))
      ?.slice(6)
      .trim();
    const kind = candidate.text
      .split("\n")
      .find((line) => line.startsWith("kind: "))
      ?.slice(6)
      .trim();
    if (!name || !learningSlug(name)) continue;
    if (kind === "rule") {
      waiting.push({ subject: name, state: "policy-reserved" });
      continue;
    }
    const receipt = learningFile(root, `gates/${name}/decision.md`);
    if (!receipt) {
      waiting.push({ subject: name, state: "awaiting-gate" });
      continue;
    }
    const decision = frontmatterField(receipt.text, "decision");
    if (decision === "ask-captain")
      waiting.push({ subject: name, state: "ask-captain" });
    else if (decision !== "continue" && decision !== "revise")
      waiting.push({ subject: name, state: "invalid-receipt" });
  }
  return { active: waiting.length > 0, waiting };
}

function activeSkillDependency(homePath: string, name: string, skillDir: string): boolean {
  for (const slot of readPools(homePath)) {
    if (!slot.worktree) continue;
    try {
      if (
        realpathSync(`${slot.worktree}/.claude/skills/${name}`) ===
        realpathSync(skillDir)
      )
        return true;
    } catch {
      /* this worktree does not seed the skill */
    }
  }
  return false;
}

/**
 * Collect the complete read-only Learning surface for one already-authorized
 * fleet home. The route applies `allowedHomePaths()` before calling this
 * function; all subpaths below are fixed or filesystem-discovered and every
 * content read is containment-checked.
 */
export function collectLearning(homePath: string): LearningView {
  const ledgerFile = learningFile(`${homePath}/records`, "learnings.md");
  const ledger = parseLearningLedger(ledgerFile?.text || "");
  const decisions = collectLearningDecisions(homePath);
  const latestBySubject = new Map<string, LearningDecisionView>();
  for (const decision of decisions)
    if (!latestBySubject.has(decision.subject))
      latestBySubject.set(decision.subject, decision);

  const pointerByName = new Map<string, LearningPointer>();
  for (const pointer of ledger.pointers) {
    const current = pointerByName.get(pointer.name);
    if (!current || (!pointer.legacy && current.legacy)) {
      pointerByName.set(pointer.name, { ...pointer });
    } else if (current.legacy && pointer.legacy) {
      current.sources += pointer.sources;
      if (pointer.updated > current.updated) current.updated = pointer.updated;
      if (pointer.legacy === "container") current.legacy = "container";
    }
  }

  const candidateTargets = new Set<string>();
  const learningRuns = learningWalk(
    `${homePath}/data`,
    (rel) => /(?:^|\/)candidate-[^/]+\.md$/.test(rel),
  );
  for (const candidate of learningRuns) {
    const name = candidate.text
      .split("\n")
      .find((line) => line.startsWith("name: "))
      ?.slice(6)
      .trim();
    if (name && learningSlug(name)) candidateTargets.add(name);
  }

  const archivedSkillFiles = learningWalk(
    `${homePath}/skills/skills-archive`,
    (rel) =>
      rel.split("/").length === 2 &&
      rel.endsWith("/SKILL.md") &&
      learningSlug(rel.split("/")[0]),
  );
  const archivedNames = new Set(
    archivedSkillFiles.map((file) => file.rel.split("/")[0]),
  );

  const evidenceByName = new Map<
    string,
    { text: string; mtime: number }
  >();
  for (const evidence of learningWalk(
    `${homePath}/records/learnings-archive`,
    (rel) => /^[a-z0-9]+(?:-[a-z0-9]+)*\.md$/.test(rel),
  )) {
    evidenceByName.set(evidence.rel.replace(/\.md$/, ""), evidence);
  }

  const skills: LearningSkillView[] = [];
  let skillEntries: import("node:fs").Dirent[] = [];
  try {
    skillEntries = readdirSync(`${homePath}/skills`, { withFileTypes: true });
  } catch {
    /* no fleet-local skills */
  }
  const staleBefore = Date.now() - 90 * 24 * 60 * 60 * 1000;
  for (const entry of skillEntries) {
    if (
      !entry.isDirectory() ||
      entry.isSymbolicLink() ||
      entry.name === "skills-archive" ||
      !learningSlug(entry.name)
    )
      continue;
    const skill = learningFile(
      `${homePath}/skills`,
      `${entry.name}/SKILL.md`,
    );
    if (!skill) continue;
    const pointer = pointerByName.get(entry.name);
    const evidence = evidenceByName.get(entry.name);
    const landedRaw = frontmatterField(skill.text, "landed");
    const landedMs = /^\d+$/.test(landedRaw)
      ? Number(landedRaw) * 1000
      : Date.parse(landedRaw);
    const lastSeededRaw = metaGet(
      `${homePath}/skills/${entry.name}/.usage.meta`,
      "last_seeded",
    );
    const lastSeededMs = /^\d+$/.test(lastSeededRaw)
      ? Number(lastSeededRaw) * 1000
      : Date.parse(lastSeededRaw);
    const stale =
      Number.isFinite(landedMs) &&
      landedMs < staleBefore &&
      (!Number.isFinite(lastSeededMs) || lastSeededMs < staleBefore) &&
      (!evidence || evidence.mtime < staleBefore) &&
      !candidateTargets.has(entry.name) &&
      !activeSkillDependency(
        homePath,
        entry.name,
        `${homePath}/skills/${entry.name}`,
      );
    const status: LearningStatus = archivedNames.has(entry.name)
      ? "shadowed"
      : stale
        ? "stale"
        : "active";
    skills.push({
      name: entry.name,
      description: frontmatterField(skill.text, "description"),
      landed: epochDisplay(landedRaw),
      updated: new Date(skill.mtime).toISOString(),
      mtime: skill.mtime,
      sources: pointer?.sources || 0,
      seeded_count:
        Number(
          metaGet(
            `${homePath}/skills/${entry.name}/.usage.meta`,
            "seeded_count",
          ),
        ) || 0,
      last_seeded: epochDisplay(lastSeededRaw),
      status,
      latest_decision: latestBySubject.get(entry.name) || null,
      skill_html: renderMarkdown(skill.text),
      evidence_html: evidence ? renderMarkdown(evidence.text) : null,
    });
  }
  skills.sort((a, b) => a.name.localeCompare(b.name));

  const archives: LearningArchiveView[] = [];
  for (const [name, evidence] of evidenceByName) {
    archives.push({
      kind: name === "index" ? "index" : "evidence",
      name,
      mtime: evidence.mtime,
      html: renderMarkdown(evidence.text),
    });
  }
  for (const archived of archivedSkillFiles) {
    archives.push({
      kind: "skill",
      name: archived.rel.split("/")[0],
      mtime: archived.mtime,
      html: renderMarkdown(archived.text),
    });
  }
  for (const fixed of [
    { file: "captain-archive.md", kind: "captain" as const, name: "captain" },
    { file: "backlog-archive.md", kind: "backlog" as const, name: "backlog" },
  ]) {
    const archive = learningFile(`${homePath}/records`, fixed.file);
    if (archive)
      archives.push({
        kind: fixed.kind,
        name: fixed.name,
        mtime: archive.mtime,
        html: renderMarkdown(archive.text),
      });
  }
  archives.sort((a, b) => b.mtime - a.mtime);

  let activeRun: string | null = null;
  let waitingGate: { subject: string; state: string }[] = [];
  try {
    const runs = readdirSync(`${homePath}/data`, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isDirectory() &&
          !entry.isSymbolicLink() &&
          /^learning(?:-|$)/.test(entry.name),
      )
      .map((entry) => {
        try {
          return {
            name: entry.name,
            mtime: statSync(`${homePath}/data/${entry.name}`).mtimeMs,
          };
        } catch {
          return { name: entry.name, mtime: 0 };
        }
      })
      .sort((a, b) => b.mtime - a.mtime);
    for (const run of runs) {
      const pending = learningRunPending(homePath, run.name);
      if (!pending.active) continue;
      activeRun = run.name;
      waitingGate = pending.waiting.filter(
        (item) => item.state !== "ask-captain",
      );
      break;
    }
  } catch {
    /* no Learning runs */
  }

  const migration = ledger.pointers
    .filter((pointer) => pointer.legacy === "container")
    .filter(
      (pointer, index, all) =>
        all.findIndex((other) => other.name === pointer.name) === index,
    );
  return {
    skills,
    pending: {
      html: ledger.pending
        ? renderMarkdown(`## Pending\n\n${ledger.pending}`)
        : "",
      raw_count: ledger.pending
        .split("\n")
        .filter((line) => /^\s*-\s+/.test(line)).length,
      active_run: activeRun,
      waiting: decisions.filter(
        (decision) => decision.decision === "ask-captain",
      ),
      waiting_gate: waitingGate,
      migration,
    },
    archives,
    decisions,
  };
}

export interface PoolSlot {
  repo: string;
  slot: string;
  state: "leased" | "available";
  task: string | null;
  holder: string | null;
  leased_at: string | null;
  worktree: string | null;
  head: string | null;   // "<branch>" | "detached @ <sha7>" | null (no tree)
  used_at: number;       // slot-meta mtime (ms) - every lease/return touches it
}

/**
 * Worktree pool for a home (§2.4): each projects/<repo>/.crew/slots/<n>.meta,
 * joined to state/<task>.meta `worktree=`. The projects/<repo> entry may be a
 * SYMLINK out of the container (drydock/projects/agent-crew -> ~/Work/agent-crew),
 * so the real repo root is resolved before reading .crew/slots.
 */
/** Every LOCAL branch across the home's project clones: the crew/* subset is
 * code a finished task parked in the repo (the pool resets trees on return),
 * and the full set feeds the graph's branch picker. FILE reads only (loose
 * refs win over a stale packed-refs copy), never a git spawn - this rides
 * the poll path. */
export function readLocalBranches(homePath: string): { repo: string; root: string; branch: string; sha: string; def?: boolean }[] {
  const out: { repo: string; root: string; branch: string; sha: string; def?: boolean }[] = [];
  let repos: string[];
  try { repos = readdirSync(`${homePath}/projects`); } catch { return out; }
  for (const repo of repos.sort()) {
    let root: string;
    try { root = realpathSync(`${homePath}/projects/${repo}`); } catch { continue; }
    const seen: Record<string, string> = {};
    try {
      const packed = readFileSync(`${root}/.git/packed-refs`, "utf8");
      for (const line of packed.split("\n")) {
        const m = /^([0-9a-f]{40}) refs\/heads\/(.+)$/.exec(line);
        if (m) seen[m[2]] = m[1];
      }
    } catch { /* no packed-refs */ }
    const walk = (dir: string, prefix: string): void => {
      let names: string[];
      try { names = readdirSync(`${dir}`); } catch { return; }
      for (const f of names) {
        const p = `${dir}/${f}`;
        try {
          if (statSync(p).isDirectory()) { walk(p, `${prefix}${f}/`); continue; }
          seen[`${prefix}${f}`] = readFileSync(p, "utf8").trim();
        } catch { /* raced */ }
      }
    };
    walk(`${root}/.git/refs/heads`, "");
    // The clone's own HEAD names the default branch - the picker's default.
    let def = "";
    try {
      const hm = /^ref: refs\/heads\/(.+)$/m.exec(readFileSync(`${root}/.git/HEAD`, "utf8"));
      if (hm) def = hm[1].trim();
    } catch { /* detached or unreadable - no default flagged */ }
    for (const branch of Object.keys(seen).sort())
      out.push({ repo, root, branch, sha: seen[branch], ...(branch === def ? { def: true } : {}) });
  }
  return out;
}

function readPools(homePath: string): PoolSlot[] {
  const pools: PoolSlot[] = [];
  const projectsDir = `${homePath}/projects`;
  let repos: string[];
  try {
    repos = readdirSync(projectsDir);
  } catch {
    return pools;
  }
  for (const repo of repos.sort()) {
    let root: string;
    try {
      root = realpathSync(`${projectsDir}/${repo}`); // resolves the symlink
    } catch {
      continue;
    }
    const slotsDir = `${root}/.crew/slots`;
    let slotFiles: string[];
    try {
      slotFiles = readdirSync(slotsDir).filter((f) => f.endsWith(".meta"));
    } catch {
      continue;
    }
    for (const f of slotFiles.sort((a, b) =>
      a.localeCompare(b, undefined, { numeric: true }),
    )) {
      const meta = `${slotsDir}/${f}`;
      const leased = metaGet(meta, "leased") === "1";
      const task = metaGet(meta, "task");
      // The slot's OWN tree: slots/<n>.meta <-> worktrees/<n> is the pool
      // mapping (ac-tree.sh). Joining the task meta here was wrong twice
      // over - a second lease showed the task's FIRST tree, and an archived
      // task showed none at all.
      const slot = f.replace(/\.meta$/, "");
      const slotTree = `${root}/.crew/worktrees/${slot}`;
      // HEAD state from FILES, never a git spawn - this runs on every
      // /api/processes poll. A worktree's .git is a "gitdir: <path>" pointer;
      // its HEAD is either "ref: refs/heads/<branch>" or a bare sha.
      let head: string | null = null;
      try {
        const gitFile = readFileSync(`${slotTree}/.git`, "utf8");
        const gm = /^gitdir: (.+)$/m.exec(gitFile);
        if (gm) {
          const gdir = gm[1].startsWith("/") ? gm[1] : `${slotTree}/${gm[1]}`;
          const h = readFileSync(`${gdir.trim()}/HEAD`, "utf8").trim();
          head = h.startsWith("ref: refs/heads/") ? h.slice(16) : `detached @ ${h.slice(0, 7)}`;
        }
      } catch { /* no tree, or a plain repo dir - the chip just stays off */ }
      pools.push({
        repo,
        slot,
        state: leased ? "leased" : "available",
        // An available slot keeps its LAST task and its tree on purpose -
        // ac-tree.sh list shows both, and an available-but-dirty tree is
        // exactly what the Worktrees tab exists to surface.
        task: task || null,
        holder: leased ? metaGet(meta, "holder") || null : null,
        leased_at: leased ? metaGet(meta, "leased_at") || null : null,
        worktree: existsSync(slotTree) ? slotTree : null,
        head,
        used_at: (() => { try { return statSync(meta).mtimeMs; } catch { return 0; } })(),
      });
    }
  }
  return pools;
}

export interface RemoteState {
  mirror: string;
  channel: string | null;
  threads: {
    family: string;
    thread_ts: string | null;
    cursor: string | null;
  }[];
}

/** Remote-thread state for a home (§2.5): flat config reads + a .thread glob. */
function readRemote(homePath: string): RemoteState {
  const threads: RemoteState["threads"] = [];
  const tdir = `${homePath}/state/remote-threads`;
  let files: string[] = [];
  try {
    files = readdirSync(tdir).filter((f) => f.endsWith(".thread"));
  } catch {
    /* no threads */
  }
  for (const f of files.sort()) {
    const p = `${tdir}/${f}`;
    threads.push({
      family: f.replace(/\.thread$/, ""),
      thread_ts: metaGet(p, "thread_ts") || null,
      cursor: metaGet(p, "cursor") || null,
    });
  }
  const channel = firstLine(`${homePath}/config/slack-channel`);
  return {
    mirror: firstLine(`${homePath}/config/remote-mirror`) || "off",
    channel: channel || null,
    threads,
  };
}

// ---------------------------------------------------------------------------
// Artifact discovery + read-only render (Slice 3a). Listing the filesystem is
// not re-deriving an accounting - it is naming files. Every path stays inside a
// home's data/ or a leased worktree's .lavish/; the render route re-validates
// with realpathSync so a traversing/symlinked path never reaches the file.
// ---------------------------------------------------------------------------

export interface Artifact {
  family: string;
  stage: string;
  kind: ArtifactKind;
  id: string; // stable URL-safe key for deep-linking (data-rel path, or lavish/<task>/<file>)
  path: string; // as discovered (the render route resolves + gates it again)
  mtime: number; // epoch ms; 0 if unstattable
}

/** EVERY file under data/<family>/ (no allowlist - parseArtifactPath only names
 * family/stage/kind) + the pooled worktrees' .lavish/ review pages. */
export function collectArtifacts(homePath: string): Artifact[] {
  const out: Artifact[] = [];
  const dataDir = `${homePath}/data`;
  const archiveDir = `${dataDir}/archive`;
  // A file under data/archive/<year>/<family>/... must parse to the same
  // family/stage its live counterpart would (bin/ac-archive.sh relocates a
  // family's dir verbatim under one extra <year> segment) - strip that
  // segment before parseArtifactPath ever sees the path, so archive/<year>/
  // is never mistaken for the family itself.
  const relForParse = (full: string): string => {
    if (full.startsWith(`${archiveDir}/`)) {
      const afterYear = full.slice(archiveDir.length + 1).split("/");
      if (afterYear.length > 2) return afterYear.slice(1).join("/");
    }
    return full.slice(dataDir.length + 1);
  };
  const push = (
    full: string,
    family: string,
    stage: string,
    kind: ArtifactKind,
    id: string,
  ) => {
    let mtime = 0;
    try {
      mtime = statSync(full).mtimeMs;
    } catch {
      /* unstattable -> mtime 0 */
    }
    out.push({ family, stage, kind, id, path: full, mtime });
  };
  // Walk data/ for every file and let parseArtifactPath name it (only a < 2-segment
  // or bad-family path is dropped). Dot-entries (.DS_Store, .git, ...) are skipped;
  // symlinked dirs are not recursed (Dirent.isDirectory() is false for a symlink),
  // which keeps the walk inside the tree. Depth 8 covers the deepest real nesting
  // (qa evidence dirs) with a runaway guard.
  const walk = (dir: string, depth: number) => {
    if (depth > 8) return;
    let entries: import("node:fs").Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name.startsWith(".")) continue; // hidden (.DS_Store, .git, ...)
      const full = `${dir}/${e.name}`;
      if (e.isDirectory()) {
        walk(full, depth + 1);
        continue;
      }
      if (!e.isFile()) continue;
      const rel = relForParse(full);
      const meta = parseArtifactPath(rel);
      if (meta) push(full, meta.family, meta.stage, meta.kind, rel);
    }
  };
  walk(dataDir, 1);
  // Pooled worktrees: the .lavish/ review pages the annotate loop leaves behind.
  for (const slot of readPools(homePath)) {
    if (!slot.worktree) continue;
    const lav = `${slot.worktree}/.lavish`;
    let files: import("node:fs").Dirent[];
    try {
      files = readdirSync(lav, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const f of files) {
      if (f.isFile() && f.name.endsWith(".html")) {
        const fam = slot.task || slot.repo;
        push(`${lav}/${f.name}`, fam, "lavish", "html", `lavish/${fam}/${f.name}`);
      }
    }
  }
  // Newest first, flat across all families (Reports route: time-sorted list).
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

/** The real dirs an artifact of this home may live under: data/ + each leased .lavish/. */
function artifactRoots(homePath: string): string[] {
  const roots: string[] = [];
  try {
    roots.push(realpathSync(`${homePath}/data`));
  } catch {
    /* no data dir */
  }
  for (const slot of readPools(homePath)) {
    if (!slot.worktree) continue;
    try {
      roots.push(realpathSync(`${slot.worktree}/.lavish`));
    } catch {
      /* no .lavish */
    }
  }
  return roots;
}

/** True iff an already-realpath'd path lives under one of the home's artifact
 * roots. The single path-safety predicate shared by the render + launch routes. */
function underArtifactRoot(homePath: string, real: string): boolean {
  return artifactRoots(homePath).some(
    (r) => real === r || real.startsWith(r + "/"),
  );
}

/**
 * Render ONE artifact read-only. The requested file is resolved with
 * realpathSync and must live under one of this home's artifact roots - a
 * traversing or symlinked-out path returns 403, never the file (path safety).
 * md -> renderMarkdown; html -> raw content for a sandboxed <iframe srcdoc>;
 * image -> a data: URL; other text -> raw text; truly-binary -> a size note.
 */
async function artifactShow(homePath: string, file: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  let real: string;
  try {
    real = realpathSync(file);
  } catch {
    return json({ error: "not found" }, 404);
  }
  if (!underArtifactRoot(homePath, real))
    return json({ error: "forbidden" }, 403);
  let st;
  try {
    st = statSync(real);
  } catch {
    return json({ error: "not found" }, 404);
  }
  if (!st.isFile()) return json({ error: "not a file" }, 400);
  const lower = real.toLowerCase();
  if (lower.endsWith(".md") || lower.endsWith(".markdown"))
    return json({ kind: "md", html: renderMarkdown(readFileSync(real, "utf8"), true) });
  if (lower.endsWith(".html") || lower.endsWith(".htm"))
    return json({ kind: "html", content: readFileSync(real, "utf8") });
  // No allowlist: preview images inline (data URL), textual files as raw text,
  // and truly-binary files as a size note. The binary sniff is a NUL byte in the
  // head - cheaper and more robust than an extension list.
  const dot = lower.lastIndexOf(".");
  const ext = dot >= 0 ? lower.slice(dot + 1) : "";
  const IMG: Record<string, string> = {
    png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
    webp: "image/webp", svg: "image/svg+xml", bmp: "image/bmp",
    ico: "image/x-icon", avif: "image/avif",
  };
  if (IMG[ext]) {
    if (st.size > 8 * 1024 * 1024)
      return json({ kind: "bin", note: `image too large to preview (${fmtBytes(st.size)})` });
    return json({
      kind: "image",
      src: `data:${IMG[ext]};base64,${readFileSync(real).toString("base64")}`,
    });
  }
  const buf = readFileSync(real);
  if (buf.subarray(0, Math.min(buf.length, 8192)).includes(0))
    return json({ kind: "bin", note: `binary file (${fmtBytes(st.size)})` });
  const TEXT_CAP = 1024 * 1024;
  const truncated = buf.length > TEXT_CAP;
  return json({
    kind: "text",
    text: buf.toString("utf8", 0, Math.min(buf.length, TEXT_CAP)),
    truncated,
  });
}

export interface RecordLedger {
  name: string; // one of RECORD_LEDGERS
  mtime: number; // epoch ms; 0 if unstattable
}

/** The records/ ledgers that exist for a home, in RECORD_LEDGERS order (thin IO,
 * like collectArtifacts - a missing ledger is simply omitted). */
function collectRecords(homePath: string): RecordLedger[] {
  const out: RecordLedger[] = [];
  const dir = `${homePath}/records`;
  for (const name of RECORD_LEDGERS) {
    let st;
    try {
      st = statSync(`${dir}/${name}`);
    } catch {
      continue; // missing ledger -> omitted
    }
    if (st.isFile()) out.push({ name, mtime: st.mtimeMs });
  }
  return out;
}

/**
 * Render ONE records/ file read-only (dash-records). `file` must pass
 * isRecordLedger or isRepoKnowledge (the name allowlist is the security
 * boundary); the resolved path is then confirmed under
 * realpathSync(<home>/records) as defense-in-depth (mirroring
 * underArtifactRoot), so a symlinked-out record never reaches the reader.
 * Records are markdown only -> renderMarkdown; missing -> 404.
 */
async function recordsShow(homePath: string, file: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!isRecordLedger(file) && !isRepoKnowledge(file)) return json({ error: "forbidden" }, 403);
  let root: string;
  try {
    root = realpathSync(`${homePath}/records`);
  } catch {
    return json({ error: "not found" }, 404);
  }
  let real: string;
  try {
    real = realpathSync(`${homePath}/records/${file}`);
  } catch {
    return json({ error: "not found" }, 404);
  }
  if (!real.startsWith(root + "/")) return json({ error: "forbidden" }, 403);
  let st;
  try {
    st = statSync(real);
  } catch {
    return json({ error: "not found" }, 404);
  }
  if (!st.isFile()) return json({ error: "not a file" }, 400);
  return json({ kind: "md", html: renderMarkdown(readFileSync(real, "utf8")) });
}

// ---------------------------------------------------------------------------
// Config editor (dash-config): the ONE sanctioned MUTATION surface. Only the
// flat value-files under <home>/config/ named in EDITABLE_CONFIG are editable;
// the name allowlist is the security boundary (mirrors RECORD_LEDGERS/
// isRecordLedger) - it is enforced BEFORE any user-controlled segment is joined,
// then a realpathSync-under-<home>/config gate confirms the resolved path
// (mirrors recordsShow). Deliberately NOT editable here: the hook SCRIPTS
// (remote-ack/-poll/-reply, multi-line executables - editing them here is
// dangerous) and .dash-edits.log itself (so the editor can never edit its own
// receipt log). Add a new knob later by extending EDITABLE_CONFIG, exactly like
// RECORD_LEDGERS - no other change is needed.
// ---------------------------------------------------------------------------

/** The flat config knobs this UI may edit, in listing order. The allowlist IS
 * the security boundary: any other name (a hook script, the .dash-edits.log
 * itself, any ../ or absolute path) is rejected before a path is ever joined.
 * Extend this to add a knob; nothing else changes. */
export const EDITABLE_CONFIG = [
  "flow",
  "effort",
  "crew-harness",
  "model",
  "codereview-agent",
  "codereview-model",
  "codereview-effort",
  "qa-agent",
  "qa-model",
  "qa-effort",
  "promote",
  "room-parallel",
  "learn-every",
  "curate-every",
  "remote-mirror",
  "gate-agent",
  "gate-effort",
  "gate-model",
  "backend",
  "remote-poll-interval",
  "captain",
  "slack-captain-id",
  "slack-channel",
] as const;

/** True iff `name` is exactly one editable knob (no path, no traversal; never a
 * hook script or the receipt log). */
export function isEditableConfig(name: string): boolean {
  return (EDITABLE_CONFIG as readonly string[]).includes(name);
}

const EFFORTS = ["low", "medium", "high", "xhigh", "max", "ultracode"] as const;
// One set again: every registry harness is offerable on every knob;
// the pane arm and one-shot forms carry the per-harness boundaries.
const CREW_HARNESSES = ["claude", "codex", "opencode", "pi", "cursor"] as const;
const PANE_HARNESSES = CREW_HARNESSES;

export interface KnobMeta {
  desc: string; // one line: what the knob does (distilled from docs/configuration.md)
  options?: readonly string[]; // closed value set -> the UI offers a select, the write validates
  numeric?: boolean; // non-negative integer -> the write validates
}

/** Per-knob function + value set, keyed by EDITABLE_CONFIG name. The UI renders
 * the desc under each knob and a select for a closed set; applyConfigWrite
 * enforces options/numeric so the editor can never write a value the reading
 * script would die on. docs/configuration.md stays the long-form authority. */
export const CONFIG_KNOB_META: Record<(typeof EDITABLE_CONFIG)[number], KnobMeta> = {
  flow: { desc: "Task flow default: auto = the crewchief triages each order; direct = one execution crewmate; staged = design then execution.", options: ["auto", "direct", "staged"] },
  effort: { desc: "Fleet-wide default reasoning effort for crewmates when --effort is absent.", options: EFFORTS },
  "crew-harness": { desc: "Default crewmate harness when a spawn names none.", options: CREW_HARNESSES },
  model: { desc: "Fleet-wide default model for crewmates when --model is absent (alias or full name); empty = the harness default." },
  "codereview-agent": { desc: "Harness for the independent code-review pane; a dispatched panes.codereview profile supersedes it.", options: PANE_HARNESSES },
  "codereview-model": { desc: "Model for the code-review pane (default opus) - decoupled from config/model." },
  "codereview-effort": { desc: "Reasoning effort for the code-review pane; unset falls through to the fleet effort ladder.", options: EFFORTS },
  "qa-agent": { desc: "Harness for the qa pane; a routed panes.qa profile supersedes it.", options: PANE_HARNESSES },
  "qa-model": { desc: "Static fallback model for an unrouted qa pane (default opus)." },
  "qa-effort": { desc: "Reasoning effort for the qa pane; unset falls through to the fleet effort ladder.", options: EFFORTS },
  promote: { desc: "Room promotion policy. Default always: a thread per task - every family gets a roomchief at intake up to room-parallel. auto = per-family triage; never = rooms stay records.", options: ["always", "auto", "never"] },
  "room-parallel": { desc: "Max roomchiefs in flight at once (default 5); ac-spawn.sh --roomchief refuses past it.", numeric: true },
  "learn-every": { desc: "Learning distill cadence: debriefs-with-lessons before the distill room auto-opens (default 8).", numeric: true },
  "curate-every": { desc: "Curate cadence: settled Learning runs before the records-wide curate fires (default 5).", numeric: true },
  "remote-mirror": { desc: "Task-thread narrative on the remote channel: off (default); chief = the owning chief composes its thread posts; on = machine auto-mirror of every room post.", options: ["off", "chief", "on"] },
  "gate-agent": { desc: "Second-chief engine for design gates - one engine, no fallback; off = the chief self-judges (receipted).", options: ["codex", "claude", "opencode", "pi", "cursor", "off"] },
  "gate-effort": { desc: "Reasoning effort for the gate judge; empty = the engine's own default.", options: EFFORTS },
  "gate-model": { desc: "Model for the gate judge; empty = the engine's own default." },
  backend: { desc: "Session backend for new crewmates; herdr is the only supported value.", options: ["herdr"] },
  "remote-poll-interval": { desc: "Seconds between the fleet watcher's remote-order polls (default 300; 0 = slot off).", numeric: true },
  captain: { desc: "How the fleet addresses the human (e.g. TN); absent = captain." },
  "slack-captain-id": { desc: "Slack member id the remote channel treats as the captain." },
  "slack-channel": { desc: "Slack channel id remote orders are read from." },
};

export interface ConfigKnob {
  name: string;
  value: string; // flat firstLine read; "" when the knob is unset (uses a default)
  desc: string;
  options?: readonly string[];
  numeric?: boolean;
}

/** Current value of every editable knob for a home (flat firstLine read, the same
 * helper readRemote uses; an unset knob -> "" so the captain can set it), plus its
 * meta so the UI can explain and constrain it. Thin IO, like collectRecords. */
function collectConfig(homePath: string): ConfigKnob[] {
  const dir = `${homePath}/config`;
  return EDITABLE_CONFIG.map((name) => {
    const meta = CONFIG_KNOB_META[name];
    return {
      name,
      value: firstLine(`${dir}/${name}`),
      desc: meta.desc,
      ...(meta.options ? { options: meta.options } : {}),
      ...(meta.numeric ? { numeric: true } : {}),
    };
  });
}

/** The most recent .dash-edits.log receipt lines (oldest first), so a write's
 * receipt survives a reload. Missing log -> []. */
function readConfigLog(homePath: string, limit = 20): string[] {
  try {
    const lines = readFileSync(`${homePath}/config/.dash-edits.log`, "utf8")
      .split("\n")
      .filter((l) => l.trim());
    return lines.slice(-limit);
  } catch {
    return [];
  }
}

export interface ConfigWriteResult {
  status: number;
  body: Record<string, unknown>;
}

/**
 * Apply ONE config write - the testable core (no survey gate; the route adds
 * allowedHomePaths in front). Order mirrors recordsShow's security shape: the
 * name allowlist (the boundary) FIRST, before any path is joined; then value
 * integrity (trim, require non-empty, reject a newline - a flat value-file is one
 * line - and, per CONFIG_KNOB_META, membership for a closed value set and digits
 * for a numeric knob, so the editor can never write what the reading script dies
 * on); then a realpathSync-under-<home>/config confirmation so an existing
 * symlink can never escape; then the write + a durable receipt line appended to
 * .dash-edits.log. ANY gate failure writes NOTHING.
 */
export function applyConfigWrite(
  homePath: string,
  file: string,
  raw: string,
): ConfigWriteResult {
  if (!isEditableConfig(file))
    return { status: 403, body: { error: "forbidden" } };
  const value = raw.trim();
  if (!value) return { status: 400, body: { error: "value must be non-empty" } };
  if (/[\r\n]/.test(value))
    return { status: 400, body: { error: "value must be a single line" } };
  const meta = CONFIG_KNOB_META[file as (typeof EDITABLE_CONFIG)[number]];
  if (meta?.options && !meta.options.includes(value))
    return { status: 400, body: { error: `value must be one of: ${meta.options.join(" | ")}` } };
  if (meta?.numeric && !/^[0-9]+$/.test(value))
    return { status: 400, body: { error: "value must be a non-negative integer" } };
  let root: string;
  try {
    root = realpathSync(`${homePath}/config`);
  } catch {
    return { status: 404, body: { error: "not found" } };
  }
  let target = `${root}/${file}`;
  if (existsSync(target)) {
    let real: string;
    try {
      real = realpathSync(target);
    } catch {
      return { status: 404, body: { error: "not found" } };
    }
    if (!real.startsWith(root + "/"))
      return { status: 403, body: { error: "forbidden" } };
    target = real; // write the resolved path (still under config/), never an escape
  }
  const old = firstLine(target);
  try {
    writeFileSync(target, value + "\n");
    const receipt = `${new Date().toISOString()}\t${file}\t${old} -> ${value}`;
    appendFileSync(`${root}/.dash-edits.log`, receipt + "\n");
    return { status: 200, body: { ok: true, file, old, value, receipt } };
  } catch {
    return { status: 500, body: { error: "write failed" } };
  }
}

// ---------------------------------------------------------------------------
// Crew dispatch (dash-crew-dispatch): config/crew-dispatch.json is the spawn
// dispatch table - a prose `when` clause -> a harness/model/effort `use` profile
// (ac-dispatch-select.sh resolves it). It is STRUCTURED multi-line JSON, so it
// cannot ride the flat-value editor (EDITABLE_CONFIG rejects newlines); it gets
// its own read (folded into /api/config-list) and its own jq-style validated
// write (POST /api/dispatch). The filename is FIXED, never user-controlled.
// ---------------------------------------------------------------------------

export interface DispatchRuleView {
  when: string;
  use: unknown; // a profile object {harness,model?,effort?} or an array of them
  why: string;
}
export interface DispatchPaneView {
  kind: string; // the pane key (qa, gate, codereview, learning, ...)
  use: unknown; // the static profile object, or null for routed QA
  rules: DispatchRuleView[]; // caller-judged QA rules, otherwise []
  dflt: unknown; // routed QA's bare default, otherwise null
  routed: boolean;
}
export interface DispatchView {
  exists: boolean;
  raw: string; // the file's raw text ("" when missing) - the editor's initial buffer
  rules: DispatchRuleView[]; // parsed rules ([] when missing or malformed)
  dflt: unknown; // the `default` field if present, else null
  panes: DispatchPaneView[]; // parsed `panes` entries in file order ([] when absent or malformed)
  error: string | null; // parse error message, or null
}

/** The pane kinds ac-dispatch-select.sh accepts in ROUTED shape (rules[] +
 * default). Mirrors its qa_pane_validate/routed_pane_validate split: qa's
 * default is optional (caller judgment only), the other three REQUIRE one so
 * a selector-less lookup resolves deterministically. */
export const ROUTED_PANE_KINDS = new Set(["qa", "gate", "codereview", "roomchief"]);

/** Read config/crew-dispatch.json for the Config route (folded into config-list).
 * Missing -> exists:false; malformed -> exists:true with the raw text + an error
 * (so the editor can still show and fix it), never a crash. */
export function readDispatch(homePath: string): DispatchView {
  let raw: string;
  try {
    raw = readFileSync(`${homePath}/config/crew-dispatch.json`, "utf8");
  } catch {
    return { exists: false, raw: "", rules: [], dflt: null, panes: [], error: null };
  }
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { exists: true, raw, rules: [], dflt: null, panes: [], error: "invalid JSON" };
  }
  const rules = Array.isArray(parsed?.rules)
    ? parsed.rules.map((r: any) => ({
        when: String(r?.when ?? ""),
        use: r?.use ?? null,
        why: String(r?.why ?? ""),
      }))
    : [];
  // `panes` is a by-kind object (qa/gate/codereview/roomchief/learning);
  // render it in file order. A ROUTED pane (rules + default, the four kinds
  // ac-dispatch-select.sh routes: qa/gate/codereview/roomchief) reuses the
  // ordinary rule-card shape and keeps its bare default separate. The UI
  // derives labels from array position and stores no kind-specific schema.
  const panes =
    parsed?.panes && typeof parsed.panes === "object" && !Array.isArray(parsed.panes)
      ? Object.entries(parsed.panes).map(([kind, use]: [string, any]) => {
          const routed = ROUTED_PANE_KINDS.has(kind) && use && typeof use === "object"
            && !Array.isArray(use) && Array.isArray(use.rules);
          return {
            kind,
            use: routed ? null : use,
            rules: routed
              ? use.rules.map((r: any) => ({
                  when: String(r?.when ?? ""),
                  use: r?.use ?? null,
                  why: String(r?.why ?? ""),
                }))
              : [],
            dflt: routed ? (use.default ?? null) : null,
            routed,
          };
        })
      : [];
  return { exists: true, raw, rules, dflt: parsed?.default ?? null, panes, error: null };
}

/**
 * Apply a crew-dispatch.json write - the testable core (the route adds the
 * allowedHomePaths gate in front). VALIDATE THE WHOLE DOCUMENT before touching
 * disk: valid JSON, a non-empty ordinary `rules` array, and profiles that match
 * ac-dispatch-select.sh. The four routable pane kinds (ROUTED_PANE_KINDS)
 * additionally accept routed rules with prose when, one atomic object use, and
 * prose why; qa's bare default stays optional while gate/codereview/roomchief
 * REQUIRE one (routed_pane_validate). Then realpath-confirm under <home>/config, write via a
 * tmp+rename (atomic replace), and append a .dash-edits.log receipt. Any gate
 * failure writes NOTHING. Canonicalised to 2-space JSON so the file stays diffable.
 */
export function applyDispatchWrite(homePath: string, raw: string): ConfigWriteResult {
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { status: 400, body: { error: "invalid JSON" } };
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return { status: 400, body: { error: "top level must be a JSON object" } };
  if (!Array.isArray(parsed.rules) || parsed.rules.length === 0)
    return { status: 400, body: { error: "`rules` must be a non-empty array" } };
  for (let i = 0; i < parsed.rules.length; i++) {
    const r = parsed.rules[i];
    if (!r || typeof r !== "object" || Array.isArray(r))
      return { status: 400, body: { error: `rule ${i + 1} must be an object` } };
    if (typeof r.when !== "string" || !r.when.trim())
      return { status: 400, body: { error: `rule ${i + 1} needs a non-empty \`when\`` } };
    const uses = Array.isArray(r.use) ? r.use : [r.use];
    if (!uses.length)
      return { status: 400, body: { error: `rule ${i + 1} \`use\` is empty` } };
    for (const u of uses) {
      if (!u || typeof u !== "object" || typeof u.harness !== "string" || !u.harness.trim())
        return { status: 400, body: { error: `rule ${i + 1} \`use\` needs a harness` } };
    }
  }
  const profileError = (value: any, label: string): string | null => {
    if (!value || typeof value !== "object" || Array.isArray(value)
        || typeof value.harness !== "string" || !value.harness.trim())
      return `${label} needs a harness`;
    if ("model" in value && typeof value.model !== "string")
      return `${label} model must be a string`;
    if ("effort" in value && typeof value.effort !== "string")
      return `${label} effort must be a string`;
    return null;
  };
  if ("panes" in parsed) {
    if (!parsed.panes || typeof parsed.panes !== "object" || Array.isArray(parsed.panes))
      return { status: 400, body: { error: "`panes` must be an object" } };
    for (const [kind, value] of Object.entries(parsed.panes) as [string, any][]) {
      if (ROUTED_PANE_KINDS.has(kind) && value && typeof value === "object" && !Array.isArray(value)
          && Object.prototype.hasOwnProperty.call(value, "rules")) {
        if ("harness" in value || "model" in value || "effort" in value)
          return { status: 400, body: { error: `panes.${kind} cannot mix static and routed keys` } };
        if (!Array.isArray(value.rules) || value.rules.length === 0)
          return { status: 400, body: { error: `panes.${kind}.rules must be a non-empty array` } };
        for (let i = 0; i < value.rules.length; i++) {
          const rule = value.rules[i];
          if (!rule || typeof rule !== "object" || Array.isArray(rule)
              || typeof rule.when !== "string" || !rule.when.trim()
              || typeof rule.why !== "string" || !rule.why.trim())
            return { status: 400, body: { error: `panes.${kind} rule ${i + 1} needs non-empty when and why` } };
          const err = profileError(rule.use, `panes.${kind} rule ${i + 1} use`);
          if (err) return { status: 400, body: { error: err } };
        }
        if (kind === "qa") {
          if ("default" in value) {
            const err = profileError(value.default, "panes.qa default");
            if (err) return { status: 400, body: { error: err } };
          }
        } else {
          // gate/codereview/roomchief: default is MANDATORY once routed, so a
          // selector-less caller (e.g. the system-initiated roomchief promote)
          // resolves deterministically (routed_pane_validate's contract).
          if (!("default" in value))
            return { status: 400, body: { error: `panes.${kind} routed rules require a default profile` } };
          const err = profileError(value.default, `panes.${kind} default`);
          if (err) return { status: 400, body: { error: err } };
        }
      } else {
        if (kind === "qa" && value && typeof value === "object"
            && Object.prototype.hasOwnProperty.call(value, "default"))
          return { status: 400, body: { error: "static panes.qa cannot carry a default" } };
        const err = profileError(value, `panes.${kind}`);
        if (err) return { status: 400, body: { error: err } };
      }
    }
  }
  let root: string;
  try {
    root = realpathSync(`${homePath}/config`);
  } catch {
    return { status: 404, body: { error: "no config dir" } };
  }
  let target = `${root}/crew-dispatch.json`;
  let oldRules = 0;
  if (existsSync(target)) {
    let real: string;
    try {
      real = realpathSync(target);
    } catch {
      return { status: 404, body: { error: "not found" } };
    }
    if (!real.startsWith(root + "/")) return { status: 403, body: { error: "forbidden" } };
    target = real;
    try {
      const prev = JSON.parse(readFileSync(target, "utf8"));
      oldRules = Array.isArray(prev?.rules) ? prev.rules.length : 0;
    } catch {
      oldRules = 0;
    }
  }
  const text = JSON.stringify(parsed, null, 2) + "\n";
  try {
    const tmp = `${target}.tmp.${process.pid}`;
    writeFileSync(tmp, text);
    renameSync(tmp, target); // atomic replace
    const receipt = `${new Date().toISOString()}\tcrew-dispatch.json\t${oldRules} rules -> ${parsed.rules.length} rules`;
    appendFileSync(`${root}/.dash-edits.log`, receipt + "\n");
    return { status: 200, body: { ok: true, rules: parsed.rules.length, receipt } };
  } catch {
    return { status: 500, body: { error: "write failed" } };
  }
}

/** POST the whole crew-dispatch.json: allowedHomePaths gate, then the testable
 * applyDispatchWrite core (validate + atomic write + receipt). */
async function dispatchWrite(homePath: string, raw: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const res = applyDispatchWrite(homePath, raw);
  return json(res.body, res.status);
}

/**
 * GET the current value of ONE editable knob (dash-config): allowedHomePaths gate,
 * then the name allowlist (403), then realpathSync-confirmed under <home>/config
 * (mirrors recordsShow); a missing knob file -> 404.
 */
async function configShow(homePath: string, file: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!isEditableConfig(file)) return json({ error: "forbidden" }, 403);
  let root: string;
  try {
    root = realpathSync(`${homePath}/config`);
  } catch {
    return json({ error: "not found" }, 404);
  }
  const target = `${root}/${file}`;
  if (!existsSync(target)) return json({ error: "not found" }, 404);
  let real: string;
  try {
    real = realpathSync(target);
  } catch {
    return json({ error: "not found" }, 404);
  }
  if (!real.startsWith(root + "/")) return json({ error: "forbidden" }, 403);
  return json({ file, value: firstLine(real) });
}

/** POST a new value to ONE editable knob: the allowedHomePaths gate, then the
 * testable applyConfigWrite core (allowlist + integrity + write + receipt). */
async function configWrite(
  homePath: string,
  file: string,
  raw: string,
): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const res = applyConfigWrite(homePath, file, raw);
  return json(res.body, res.status);
}

// ---------------------------------------------------------------------------
// Shell-outs to the owning scripts (the accounting stays in bash).
// ---------------------------------------------------------------------------

async function run(
  cmd: string[],
  env: Record<string, string>,
): Promise<{ code: number; out: string }> {
  const proc = Bun.spawn(cmd, {
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = await new Response(proc.stdout).text();
  const code = await proc.exited;
  return { code, out };
}

/** Cross-fleet survey as one JSON document - passed through untouched. */
async function snapshot(): Promise<Response> {
  const { code, out } = await snapshotResult();
  if (code !== 0)
    return json({ error: "ac-fleets.sh --json failed", code }, 502);
  return new Response(out, { headers: { "content-type": "application/json" } });
}

/** Memoizes an async loader for `ttlMs`: repeat calls inside the window reuse
 *  the same (possibly in-flight) result instead of re-invoking the loader.
 *  The TTL clock starts when the value LANDS, not when the loader was
 *  invoked - a loader slower than ttlMs still caches once it resolves,
 *  and concurrent callers share the one in-flight promise regardless. */
export function ttlMemo<T>(ttlMs: number, loader: () => Promise<T>): () => Promise<T> {
  let cached: { until: number; value: Promise<T> } | null = null;
  return () => {
    const now = Date.now();
    if (!cached || now >= cached.until) {
      const entry = { until: Infinity, value: loader() };
      entry.value.then(
        () => { entry.until = Date.now() + ttlMs; },
        () => { entry.until = Date.now() + ttlMs; },
      );
      cached = entry;
    }
    return cached.value;
  };
}

/** Every home path the current survey knows about, crewdeputies included.
 *  Every route below gates on this, so it is the ONE shell-out to
 *  ac-fleets.sh --paths paid per request across the whole API surface -
 *  cached for a few seconds (HOME_PATHS_TTL_MS) rather than threading a
 *  snapshot through every route signature. The only staleness this can
 *  cause: a home added or removed in the last TTL_MS gets 404/200'd on the
 *  stale answer for up to that long - it never affects the LIVE crew/room
 *  data each route reads fresh (roomList, readPools, collectArtifacts, ...
 *  none of those go through this cache). --paths is the paths-only sibling
 *  of --json (bin/ac-fleets.sh): this walk() reads only h.path/h.crewdeputies,
 *  so the per-home crew/inbox/watcher/wakes/lock/cadence accounting --json
 *  computes for every home was calculated here and thrown away every time
 *  this cache expired. */
// Must stay comfortably ABOVE the client's POLL_MS (dashboard.ts:3939, 5000)
// or a steady-state poll always lands after the cache has expired and misses
// every tick - the bug this constant used to have at 3000. Do not "tidy" it
// back down without also raising POLL_MS.
export const HOME_PATHS_TTL_MS = 12000;
const allowedHomePaths = ttlMemo(HOME_PATHS_TTL_MS, async (): Promise<Set<string>> => {
  const { code, out } = await run([`${BIN}/ac-fleets.sh`, "--paths"], {
    AC_HOME,
  });
  const set = new Set<string>();
  if (code !== 0) return set;
  try {
    const walk = (homes: any[]) => {
      for (const h of homes ?? []) {
        if (h?.path) set.add(h.path);
        walk(h?.crewdeputies ?? []);
      }
    };
    walk(JSON.parse(out).homes);
  } catch {
    /* empty allowlist -> every drill-down 404s, which is the safe failure */
  }
  return set;
});

/** The raw `ac-fleets.sh --json` shell-out `snapshot()` passes through - its
 *  own ttlMemo cache, separate from allowedHomePaths' (each is a distinct
 *  full multi-home walk), so a steady-state poll hits both instead of
 *  neither. */
const snapshotResult = ttlMemo(HOME_PATHS_TTL_MS, () =>
  run([`${BIN}/ac-fleets.sh`, "--json"], { AC_HOME }),
);

/** ac-room.sh list for one home, gated on an existing data/ (no dir creation). */
async function roomList(homePath: string): Promise<RoomRow[]> {
  if (!existsSync(`${homePath}/data`)) return [];
  const { code, out } = await run([`${BIN}/ac-room.sh`, "list"], {
    AC_HOME: homePath,
  });
  if (code !== 0) return [];
  return parseRoomList(out);
}

// ---------------------------------------------------------------------------
// Route-scoped read endpoints (guide §9): each primary route fetches and polls
// ONLY the data it renders. Every one is a thin composition of the existing
// pure parsers + IO helpers - none re-derives an accounting the scripts own.
// The old monolithic /api/home is retired: a route that shows only the backlog
// must not fetch pools, artifacts, config, and rooms it never renders.
// ---------------------------------------------------------------------------

/** Processes route (§7.2): the selected fleet's rooms, worktree pool, remote
 *  threads, and per-family gate state (gate-dash-monitor). Crew rows + watcher
 *  come from the shell's snapshot poll, not here. */
// LLM PROVIDER KEYS (admin) - per-home secret store <home>/config/providers.json
// (0600, gitignored with config/). bin/ac-brain-engine.ts's PROVIDERS registry
// is the authority for names/endpoints; this mirror exists because importing
// the engine would execute its CLI dispatch. The API never returns a full key:
// GET reports configured/masked/source only, POST sets or removes one entry.
// Reachable only on the captain listener - the guest share listener 404s
// every non-review path by construction.
const LLM_PROVIDERS: Array<{ name: string; base_url: string; env: string; noKey?: boolean; caps: string }> = [
  { name: "openrouter", base_url: "https://openrouter.ai/api/v1", env: "OPENROUTER_API_KEY", caps: "semantic search + synthesize" },
  { name: "openai", base_url: "https://api.openai.com/v1", env: "OPENAI_API_KEY", caps: "semantic search + synthesize" },
  { name: "voyage", base_url: "https://api.voyageai.com/v1", env: "VOYAGE_API_KEY", caps: "embeddings + rerank" },
  { name: "opencode-go", base_url: "https://opencode.ai/zen/go/v1", env: "OPENCODE_API_KEY", caps: "chat" },
  { name: "anthropic", base_url: "https://api.anthropic.com/v1", env: "ANTHROPIC_API_KEY", caps: "chat" },
  { name: "ollama", base_url: "http://127.0.0.1:11434/v1", env: "", noKey: true, caps: "local model, no key - semantic search + synthesize" },
  // CLIProxyAPI: a local OpenAI-compatible proxy over CLI-plan auth (claude
  // /gemini/codex subscriptions). The key is whatever its own config lists
  // under api-keys - store any matching string here.
  { name: "cliproxy", base_url: "http://127.0.0.1:8317/v1", env: "CLIPROXY_API_KEY", caps: "local proxy over CLI subscriptions - synthesize" },
];
function providersFile(home: string) { return home + "/config/providers.json"; }
function providersRead(home: string): Record<string, { api_key?: string }> {
  try { return JSON.parse(readFileSync(providersFile(home), "utf8")); } catch { return {}; }
}
// PER-LANE provider model (supersedes the one-provider table): the captain's
// real deployment SPLITS the brain - embeddings on one credential, synthesize
// on another - so each lane carries its own provider set and defaults, and a
// lane write never touches the other lane's block. Embedding models form a
// CLOSED set because dims are load-bearing (a width change forces a rebuild);
// synthesize models are free text over the provider's own catalog.
export const PROVIDER_LANES: {
  embedding: Record<string, { models: Record<string, number>; dflt: string }>;
  synthesize: Record<string, { dflt: string }>;
} = {
  embedding: {
    openrouter: { models: { "openai/text-embedding-3-small": 1536, "openai/text-embedding-3-large": 3072 }, dflt: "openai/text-embedding-3-small" },
    openai: { models: { "text-embedding-3-small": 1536, "text-embedding-3-large": 3072 }, dflt: "text-embedding-3-small" },
    ollama: { models: { "nomic-embed-text": 768, "mxbai-embed-large": 1024 }, dflt: "nomic-embed-text" },
  },
  synthesize: {
    openrouter: { dflt: "openai/gpt-4o-mini" },
    openai: { dflt: "gpt-4o-mini" },
    ollama: { dflt: "llama3.1" },
    "opencode-go": { dflt: "kimi-k2.7-code" },
    // Synthesize-only: CLIProxyAPI fronts chat models from CLI-plan auth;
    // it serves no embedding surface, and embedding dims are load-bearing.
    cliproxy: { dflt: "gpt-5.6" },
  },
};
export function applyProviderLane(
  bj: any, store: Record<string, { api_key?: string }>, req: any,
): { error: string } | { bj: any; store: Record<string, { api_key?: string }>; warn?: string } {
  const lane = String(req.lane || "");
  const provider = String(req.provider || "");
  const laneSet: any = (PROVIDER_LANES as any)[lane];
  if (!laneSet) return { error: "unknown lane " + (lane || "(none)") };
  const pv = laneSet[provider];
  if (!pv) return { error: "provider " + (provider || "(none)") + " is not in the " + lane + " set" };
  const out = { ...bj };
  const st = { ...store };
  const key = typeof req.api_key === "string" ? req.api_key.trim() : "";
  if (key) st[provider] = { api_key: key };
  else if (req.remove) delete st[provider];
  const model = typeof req.model === "string" && req.model.trim() ? req.model.trim() : pv.dflt;
  let warn: string | undefined;
  if (lane === "embedding") {
    const dims = pv.models[model];
    if (!dims) return { error: "unknown embedding model " + model + " - dims must be known (" + Object.keys(pv.models).join(", ") + ")" };
    const prevDims = bj.embedding?.dims;
    out.embedding = { provider, model, dims };
    if (prevDims && prevDims !== dims) warn = "embedding width changed - run: bin/ac-brain.sh sync --rebuild";
  } else {
    out.synthesize = { ...(bj.synthesize || {}), api: { provider, model } };
  }
  return { bj: out, store: st, warn };
}
function providersDetail(home: string, warn?: string) {
  const store = providersRead(home);
  const bj = brainJsonRead(home);
  const mask = (k: string) => (k.length > 10 ? k.slice(0, 6) + "…" + k.slice(-4) : "…");
  const keyState = (name: string) => {
    const meta = LLM_PROVIDERS.find(p => p.name === name);
    const envSet = meta?.env && !!process.env[meta.env];
    const fileKey = store[name]?.api_key;
    return { no_key: !!meta?.noKey, env: meta?.env ?? "",
      source: meta?.noKey ? "none-needed" : envSet ? "env" : fileKey ? "file" : null,
      masked: fileKey ? mask(fileKey) : null };
  };
  return json({
    warn,
    active: bj.embedding?.provider ?? null,
    embedding: bj.embedding ?? null,
    synthesize: bj.synthesize?.api ?? null,
    lanes: {
      embedding: Object.entries(PROVIDER_LANES.embedding).map(([name, v]) =>
        ({ name, models: Object.keys(v.models), dflt: v.dflt, ...keyState(name) })),
      synthesize: Object.entries(PROVIDER_LANES.synthesize).map(([name, v]) =>
        ({ name, dflt: v.dflt, ...keyState(name) })),
    },
  });
}
function brainJsonRead(home: string): any {
  try { return JSON.parse(readFileSync(home + "/config/brain.json", "utf8")); } catch { return {}; }
}
function providersSet(home: string, body: string) {
  let b: any;
  try { b = JSON.parse(body); } catch { return json({ error: "bad json" }, 400); }
  const r = applyProviderLane(brainJsonRead(home), providersRead(home), b);
  if ("error" in r) return json({ error: r.error }, 400);
  try {
    mkdirSync(home + "/config", { recursive: true });
    writeFileSync(providersFile(home), JSON.stringify(r.store, null, 1), { mode: 0o600 });
    try { require("node:fs").chmodSync(providersFile(home), 0o600); } catch {}
    writeFileSync(home + "/config/brain.json", JSON.stringify(r.bj, null, 1));
  } catch (e) { return json({ error: String(e) }, 500); }
  return providersDetail(home, r.warn ? r.warn + " --home " + home : undefined);
}
// Live model catalog for the synthesize lane's picker: proxy the provider's
// own /models with the resolved key (env > file), server-side so the key
// never reaches the page. Fail-open to an empty list - the input stays free
// text either way.
async function providerModels(home: string, provider: string): Promise<Response> {
  const meta = LLM_PROVIDERS.find(x => x.name === provider);
  if (!meta) return json({ models: [] });
  const key = (meta.env && process.env[meta.env]) || providersRead(home)[provider]?.api_key || "";
  try {
    const res = await fetch(meta.base_url + "/models", {
      headers: key ? { authorization: "Bearer " + key } : {},
      signal: AbortSignal.timeout(6000),
    });
    const d: any = await res.json();
    const ids = Array.isArray(d?.data) ? d.data.map((m: any) => String(m.id)).filter(Boolean) : [];
    return json({ models: ids.slice(0, 200) });
  } catch { return json({ models: [] }); }
}

// Read-only KPI over the home's memory engine (bin/ac-brain-engine.ts owns
// the schema); absent or unreadable reads as {present:false}, never an error.
function brainStat(home: string) {
  const p = home + "/state/brain.sqlite";
  try {
    if (!existsSync(p)) return json({ present: false });
    const db = new BrainDb(p, { readonly: true });
    db.run("PRAGMA busy_timeout=2000");
    const g = (q: string) => { try { return (db.query(q).get() as any).c; } catch { return 0; } };
    const r = {
      present: true,
      pages: g("SELECT COUNT(*) c FROM pages"),
      facts: g("SELECT COUNT(*) c FROM facts WHERE expired_at IS NULL"),
      last_sync: (db.query("SELECT v FROM meta WHERE k='last_sync'").get() as any)?.v ?? null,
    };
    db.close();
    return json(r);
  } catch { return json({ present: false }); }
}

async function processesDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const backlogFile = `${homePath}/records/backlog.md`;
  return json({
    rooms: await roomList(homePath),
    pools: readPools(homePath),
    branches: readLocalBranches(homePath),
    remote: readRemote(homePath),
    // The KNOWN-FAMILY set for this route's task links, and the reason it is
    // served here rather than derived client-side: `familyOfTaskId` strips a
    // stage suffix only when the base is a real family, so an INCOMPLETE set
    // silently links a crew row at its own task id. `roomOf` - the only
    // family-ish index this route already held - lists families with a
    // room.md, which is a SUBSET (a room opens on a family's first
    // captain-facing event), so it would have broken more links than the
    // unconditional strip it replaced.
    // crewdomain-token: domain rows live IN the fleet ledger (stamped), so the
    // one parse covers them - the old per-package merge had nothing left to add.
    families: backlogFamilyIds(
      existsSync(backlogFile)
        ? parseBacklog(readFileSync(backlogFile, "utf8"))
        : { in_flight: [], queued: [], done: [] },
    ),
  });
}

/** Backlog route (§7.3): the fleet's ledger, parsed into its three sections,
 *  plus every crewdomain package's own backlog.md merged in and labelled
 *  (dash-domain-records surface c) - otherwise a row assigned into a domain
 *  leaves this ledger and vanishes from the UI entirely. */
async function backlogDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const backlogFile = `${homePath}/records/backlog.md`;
  // crewdomain-token: domain rows live IN the fleet ledger (stamped), so the
  // one parse covers them - the old per-package merge had nothing left to add.
  const own = existsSync(backlogFile)
    ? parseBacklog(readFileSync(backlogFile, "utf8"))
    : { in_flight: [], queued: [], done: [] };
  return json({ backlog: own });
}

/** Reports route (§7.4): the discovered artifact master list (viewer bodies load
 *  lazily via /api/artifact on selection - the list is the only polled island). */
async function reportsDetail(homePath: string, limit = 0): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  // Paging BY FOLDER: the unit is the family
  // dir, not the file - a slice of the newest 20 FILES scattered arbitrary
  // fragments of many folders into the tree. limit = how many of the
  // newest-first folders ship complete; 0 is everything (search and
  // Show-all refetch with it). total/totalFolders always report the real
  // counts so the client knows what it has not seen.
  const all = collectArtifacts(homePath);
  if (limit <= 0) return json({ artifacts: all, total: all.length, folders: 0, totalFolders: 0 });
  const order: string[] = [];
  for (const a of all) if (!order.includes(a.family)) order.push(a.family); // newest-first already
  const keep = new Set(order.slice(0, limit));
  return json({
    artifacts: all.filter((a) => keep.has(a.family)),
    total: all.length,
    folders: keep.size,
    totalFolders: order.length,
  });
}

/** Records route (§7.4): the fleet's records/ ledger list (bodies load lazily
 *  via /api/records on selection, sharing the Reports viewer contract). */
async function ledgersDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  return json({ records: collectRecords(homePath) });
}

/** Learning route: normalized fleet-local skills, Pending records, archives,
 * and maintenance receipts. This is read-only; all content is rendered through
 * the safe Markdown renderer before it reaches the client. */
async function learningDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  return json(collectLearning(homePath));
}

/** Config route (§7.6): the editable knobs + their current values + the durable
 *  receipt log. Writes stay on POST /api/config (the one mutation surface). */
async function configList(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  return json({
    editable: collectConfig(homePath),
    log: readConfigLog(homePath),
    dispatch: readDispatch(homePath),
  });
}

/** Mirrors ac_room_file (bin/ac-lib.sh): a HISTORY read's family dir - the
 *  live data/<family>/ when it exists, else the data/archive/<year>/<family>/
 *  copy bin/ac-archive.sh moved it to. Neither existing returns the live path,
 *  same fallback ac_room_file uses. `family` is charset-validated by every
 *  caller's route guard before it reaches here. */
function familyDataDir(homePath: string, family: string): string {
  const live = `${homePath}/data/${family}`;
  if (existsSync(live)) return live;
  let years: string[] = [];
  try {
    years = readdirSync(`${homePath}/data/archive`, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return live;
  }
  for (const year of years) {
    const archived = `${homePath}/data/archive/${year}/${family}`;
    if (existsSync(archived)) return archived;
  }
  return live;
}

/** The family's room.md entries (raw `- [...]` lines), or [] when it has no
 *  room / the shell-out fails. Shared by roomShow and familyDetail. */
export async function readRoomEntries(homePath: string, family: string): Promise<string[]> {
  if (!existsSync(`${familyDataDir(homePath, family)}/room.md`)) return [];
  const { code, out } = await run([`${BIN}/ac-room.sh`, "show", family], {
    AC_HOME: homePath,
  });
  if (code !== 0) return [];
  return out.split("\n").filter((l) => l.startsWith("- ["));
}

/** Keys the browser may press into a chief pane (chief panel, slice B). A
 * closed allowlist, not a passthrough: navigation/answer keys for TUI prompts
 * plus the interrupt - never a way to type arbitrary control sequences. */
export const CHIEF_KEYS = [
  "up", "down", "left", "right", "enter", "esc", "tab", "shift+tab",
  "backspace", "space", "pageup", "pagedown", "ctrl+c", "ctrl+v", "ctrl+u",
] as const;
export function isChiefKey(k: string): boolean {
  // Web-terminal parity: the attach page types like
  // the web terminal, so the whole ctrl+<letter> range passes - the full-shell
  // /api/term/ws on this same listener already grants strictly more.
  return (CHIEF_KEYS as readonly string[]).includes(k) || /^ctrl\+[a-z]$/.test(k);
}

/** Text a type-through keystroke may carry: one printable character. The
 * composer path (whole messages) goes through ac-send.sh instead - this is
 * only for live typing into a TUI prompt. */
export function isChiefChar(t: string): boolean {
  return t.length === 1 && t >= " " && t !== "";
}

/** Image attachment content types the chat panel accepts; the extension is
 * derived HERE (never from a client filename), so the saved name is always
 * ours. */
export function attachExt(contentType: string | null): string | null {
  const m: Record<string, string> = {
    "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif",
  };
  return m[(contentType ?? "").toLowerCase()] ?? null;
}

/** Type-through text beyond one keystroke: an IME composition (Vietnamese
 * telex commits "\u1ec1" as one input event) or a clipboard paste. Printable
 * only - control bytes except \n and \t are rejected, so an escape sequence
 * can never ride the text path; the length cap keeps a runaway paste out of
 * the pane. */
export function isChiefPaste(t: string): boolean {
  if (!t || t.length > 2000) return false;
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(t);
}

/** The chief pane + tab for a family: the .pane-<id> handle file's two tokens
 * (what the backend itself reads - survives pane re-creation), falling back to
 * the meta's window= echo for the pane with no tab (focus becomes best-effort
 * a no-op). Gated on the SAME kind=roomchief meta check as chiefPaneOf. */
function chiefHandleOf(homePath: string, family: string): { pane: string; tab: string | null } | null {
  let metaText = "";
  try {
    metaText = readFileSync(`${homePath}/state/${family}-chief.meta`, "utf8");
  } catch {
    return null;
  }
  const metaPane = chiefPaneOf(metaText);
  if (!metaPane) return null;
  try {
    const toks = readFileSync(`${homePath}/state/.pane-${family}-chief`, "utf8").trim().split(/\s+/);
    if (toks[0] && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(toks[0]))
      return { pane: toks[0], tab: toks[1] && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(toks[1]) ? toks[1] : null };
  } catch { /* no handle file */ }
  return { pane: metaPane, tab: null };
}

/** Handle for ANY task pane by id (linked terminals): the .pane-<id> handle
 * file's tokens first (what the backend itself reads), else the meta's
 * window= echo. READ-ONLY consumers only - input stays chief-gated. */
function paneHandleByMeta(homePath: string, id: string, metaText: string): { pane: string; tab: string | null } | null {
  const m = /^window=herdr:pane-([^:\n]+):([^\s:]+)$/m.exec(metaText);
  const metaPane = m ? `${m[1]}:${m[2]}` : null;
  try {
    const toks = readFileSync(`${homePath}/state/.pane-${id}`, "utf8").trim().split(/\s+/);
    if (toks[0] && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(toks[0]))
      return { pane: toks[0], tab: toks[1] && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(toks[1]) ? toks[1] : null };
  } catch { /* no handle file */ }
  return metaPane ? { pane: metaPane, tab: null } : null;
}

/** Every pane BELONGING to a family, for the linked-terminal chips: the
 * family's own tasks (id == family or family-<stage>) plus verify panes whose
 * meta names the family. Membership is derived HERE from state/ metas - the
 * client can only pick from what this returns, never name an arbitrary id.
 * kind=self is skipped (a tail -f pane holds no agent worth watching). */
export function familyPaneIds(metas: { id: string; text: string }[], family: string): { id: string; kind: string }[] {
  const out: { id: string; kind: string }[] = [];
  for (const m of metas) {
    if (m.id === `${family}-chief`) continue; // the chief is the panel's own target
    const kind = (/^kind=([^\n]+)$/m.exec(m.text) ?? [])[1] ?? "";
    const metaFam = (/^family=([^\n]+)$/m.exec(m.text) ?? [])[1] ?? "";
    const mine = m.id === family || m.id.startsWith(`${family}-`) || metaFam === family;
    if (!mine) continue;
    if (kind === "self") continue;
    out.push({ id: m.id, kind: kind || "task" });
  }
  out.sort((a, b) => a.id.localeCompare(b.id));
  return out;
}

async function roomPanes(homePath: string, family: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  const metas: { id: string; text: string }[] = [];
  try {
    for (const f of readdirSync(`${homePath}/state`)) {
      if (!f.endsWith(".meta")) continue;
      try { metas.push({ id: f.slice(0, -5), text: readFileSync(`${homePath}/state/${f}`, "utf8") }); } catch {}
    }
  } catch { /* no state dir */ }
  return json({ panes: familyPaneIds(metas, family) });
}

// ---------------------------------------------------------------------------
// Web terminal: a NATIVE full herdr terminal in the browser - no ttyd, no
// node-pty, no CDN. Each websocket at /api/term/ws spawns herdr on a PTY -
// keystrokes flow ws -> pty, frames flow pty -> ws - and the VENDORED
// xterm.js (served at /assets/xterm/, provenance in dashboard/assets/)
// renders in /term-frame, which the Terminal page iframes. Same trust model
// as the dashboard (127.0.0.1). Each socket is one herdr client attaching
// the shared session; killing the bridge detaches it.
// The Terminal page ships enabled: the terminal is native and dependency-free,
// and the chat panel already types into panes with no knob - gating this page
// protected a ttyd install that no longer exists. Same trust model as every
// surface here: 127.0.0.1 only.
function webtermEnabled(_homePath: string): boolean {
  return true;
}

/** Clamp the client-reported terminal size to something a pty can hold; the
 * values are interpolated into an stty command line, so they must come out of
 * here as INTEGERS no matter what the query string carried. */
export function termSize(colsRaw: string | null, rowsRaw: string | null): { cols: number; rows: number } {
  const cols = Math.min(500, Math.max(20, Math.floor(Number(colsRaw)) || 80));
  const rows = Math.min(200, Math.max(5, Math.floor(Number(rowsRaw)) || 24));
  return { cols, rows };
}

async function termStatus(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  return json({ enabled: true, running: true, url: "/term-frame?path=" + encodeURIComponent(homePath) });
}

/** Vendored terminal renderer (dashboard/assets/xterm/, provenance in its
 * README): a page whose script can type into a live PTY must not trust a CDN
 * at runtime, so xterm.js is served by this process - a CLOSED name->type map,
 * never a directory read, so the route cannot traverse. */
const TERM_ASSETS: Record<string, string> = {
  "xterm.js": "text/javascript; charset=utf-8",
  "addon-fit.js": "text/javascript; charset=utf-8",
  "addon-unicode11.js": "text/javascript; charset=utf-8",
  "addon-web-links.js": "text/javascript; charset=utf-8",
  "xterm.css": "text/css; charset=utf-8",
};
function termAsset(name: string): Response {
  const ct = TERM_ASSETS[name];
  if (!ct) return new Response("not found", { status: 404 });
  return new Response(Bun.file(import.meta.dir + "/assets/xterm/" + name), {
    headers: { "content-type": ct, "cache-control": "public, max-age=86400" },
  });
}

function termFramePage(): Response {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>agent-crew terminal</title>
<link rel="stylesheet" href="/assets/xterm/xterm.css">
<style>
/* overflow:hidden on BOTH: this document lives in an iframe, so a transient
   few-px overshoot while the fit addon resizes would otherwise flash the
   iframe's own UA scrollbars - the outer page hiding ITS scrollbars can't
   reach these. */
html,body{margin:0;height:100%;overflow:hidden;background:#0c252d}#t{height:100%;padding:4px 0 0 6px;box-sizing:border-box}
/* Kill xterm's viewport scrollbar: the UA paints it a light track that reads as
   a white stripe down the right edge of a dark terminal. Scrollback is reached
   by wheel and by the pane's own keys, so the bar carries no function here. */
.xterm-viewport{scrollbar-width:none;-ms-overflow-style:none}
.xterm-viewport::-webkit-scrollbar{width:0;height:0}</style>
<!-- The #0b0f14 above is only the pre-theme default: the parent paints its own
     canvas colour in through acSetTheme the moment the frame is up, so the
     terminal stops being a black rectangle pasted onto a themed page. -->
<script src="/assets/xterm/xterm.js"></script>
<script src="/assets/xterm/addon-fit.js"></script>
<script src="/assets/xterm/addon-unicode11.js"></script>
<script src="/assets/xterm/addon-web-links.js"></script>
</head><body><div id="t"></div>
<script>
const q = new URLSearchParams(location.search);
const path = q.get("path") ?? "";
// Font + width tables both matter here: xterm's defaults are courier-new and
// Unicode 6 widths, while herdr lays panes out with modern (Unicode 11+)
// widths - on glyphs like the TUI's status arrows the two disagree, so
// redraw-in-place left misaligned residue (reported as a font glitch).
// Font size is captain-adjustable (the page chrome's A-/A+) and persists per
// browser under one key, so every mount comes back at the chosen size.
const FKEY = "ac_term_font";
const fclamp = (v) => Math.max(8, Math.min(24, Math.round((v || 12) * 2) / 2));
let fpx = 12;
try { fpx = fclamp(parseFloat(localStorage.getItem(FKEY) || "12")); } catch { }
const term = new Terminal({
  fontSize: fpx, scrollback: 5000, theme: { background: "#0c252d" },
  // WezTerm parity: JetBrains Mono is what the operator's WezTerm renders,
  // so the web terminal leads with it; Hack Nerd
  // Font Mono next supplies the nerd/powerline glyphs JetBrains Mono lacks -
  // the same shape as WezTerm's own built-in Symbols Nerd Font fallback.
  fontFamily: "'JetBrains Mono', 'Hack Nerd Font Mono', Menlo, Monaco, 'SF Mono', 'DejaVu Sans Mono', monospace",
  allowProposedApi: true,  // the unicode-version switch is behind this flag
});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.loadAddon(new Unicode11Addon.Unicode11Addon());
term.unicode.activeVersion = "11";
// Clickable URLs (vendored addon-web-links). Pane content is UNTRUSTED - an
// agent or escape sequence can print any URL - so the handler re-validates
// the scheme and opens with no opener; nothing navigates this frame.
term.loadAddon(new WebLinksAddon.WebLinksAddon((e, uri) => {
  if (/^https?:$/i.test(uri.split("//")[0])) { const w = window.open(uri, "_blank"); if (w) w.opener = null; }
}));
term.open(document.getElementById("t"));
fit.fit(); term.focus();
let ws = null, gen = 0, rt = null, sentCols = 0, sentRows = 0;
function connect() {
  const g = ++gen;
  fit.fit();
  // The spawn query IS a size send, so record it as one - else the dedupe below
  // would suppress the first real change back to whatever we opened with.
  sentCols = term.cols; sentRows = term.rows;
  // fleet=1 / family=<fam> ride through: the server resolves the target's
  // workspace and steers THIS client onto it right after spawn - a full
  // herdr client opened at the pane the URL names.
  const scope = (q.get("fleet") === "1" ? "&fleet=1" : "") + (q.get("family") ? "&family=" + encodeURIComponent(q.get("family")) : "");
  ws = new WebSocket("ws://" + location.host + "/api/term/ws?path=" + encodeURIComponent(path) + scope
    + "&cols=" + term.cols + "&rows=" + term.rows);
  ws.binaryType = "arraybuffer";
  // Reset only when a connection actually OPENS (fresh stream, fresh screen).
  // Resetting before each RETRY blanked the screen every 1.2s, so a capped
  // server (429 handshake) showed an empty terminal instead of the message.
  ws.onopen = () => { if (g === gen) term.reset(); };
  // First-byte watchdog (the dock once opened onto a silent blank): a
  // connection that OPENS but
  // never streams is a dead pty wearing a live socket - no close event ever
  // fires, so the reconnect loop below never runs. Say so and force the
  // reconnect; on first output tell the embedding parent (the dock drops its
  // connecting overlay on this signal - same-origin direct call, the
  // parent.termTheme precedent).
  let gotByte = false;
  const wd = setTimeout(() => {
    if (g !== gen || gotByte) return;
    term.write("\\x1b[33m[no output - respawning…]\\x1b[0m\\r\\n");
    try { ws.close(); } catch { }
  }, 4000);
  ws.onmessage = (e) => {
    if (g !== gen) return;
    if (!gotByte) { gotByte = true; clearTimeout(wd); try { if (parent !== window && typeof parent.acTermLive === "function") parent.acTermLive(); } catch { } }
    term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data));
  };
  ws.onclose = (e) => {
    if (g !== gen) return;
    clearTimeout(wd);
    term.write("\\r\\n\\x1b[33m[" + (e.reason || "disconnected") + " - reconnecting…]\\x1b[0m\\r\\n");
    setTimeout(() => { if (g === gen) connect(); }, 1200);
  };
}
// Keystrokes ride BINARY frames; TEXT frames carry control JSON (resize).
const enc = new TextEncoder();
term.onData((d) => { if (ws && ws.readyState === 1) ws.send(enc.encode(d)); });
// The PTY must follow the FRAME, and window.resize alone does not see that.
// Measured: mount is always correct (fit runs at the real size), but every
// LATER change to the iframe's box made by the PARENT - collapsing the nav,
// termFit's height pass, switching back to this tab - resized the frame
// WITHOUT firing resize in here, so xterm re-fit on its own to 233 cols while
// the pty stayed at the 129 it was spawned with, and herdr painted 129 columns
// into a 233-column frame: the captain's black band down the right. A
// ResizeObserver on the holder sees the box change whatever caused it. The
// guard is the point of the dedupe: only a real cols/rows CHANGE crosses the
// wire, so the observer's own layout churn never floods the pty with SIGWINCH.
// Oscillation damper: a scrollbar (or any layout feedback) can flip the box
// between two sizes forever - A/B alternation slips the equality dedupe every
// time and, at the 200ms debounce, storms the server with ~5 resizes/s that
// reflow every shared pty (measured live: 272 resize events/min, two sizes
// alternating). Remember the previous send; when the new size equals it
// (A->B->A), hold that send until the size stays put for 1.5s.
let prevCols = 0, prevRows = 0;
function syncSize() {
  clearTimeout(rt);
  const doSend = () => {
    fit.fit();
    if (term.cols === sentCols && term.rows === sentRows) return;
    if (term.cols === prevCols && term.rows === prevRows) { rt = setTimeout(doSend, 1500); return; }
    prevCols = sentCols; prevRows = sentRows;
    sentCols = term.cols; sentRows = term.rows;
    if (ws && ws.readyState === 1) ws.send(JSON.stringify({ resize: { cols: term.cols, rows: term.rows } }));
  };
  rt = setTimeout(doSend, 200);
}
addEventListener("resize", syncSize);
new ResizeObserver(syncSize).observe(document.getElementById("t"));
// Font-metrics refit: cols were measured at mount, possibly against the
// fallback font (JetBrains Mono is local but canvas measurement can run
// before it is applied). A glyph-width change re-fits NOTHING by itself -
// the box never changed - so re-fit when the font set settles.
if (document.fonts && document.fonts.ready) {
  document.fonts.load("12px 'JetBrains Mono'").catch(() => {});
  document.fonts.ready.then(() => { fit.fit(); syncSize(); });
}
// Theme, pushed IN by the parent (same-origin, so a plain function call - no
// postMessage handshake to get wrong). Called on mount and on every theme or
// palette change; it repaints the live terminal in place, because remounting
// the iframe would kill the herdr client attached to the captain's session.
window.acSetTheme = (t) => {
  if (!t || !t.background) return;
  document.body.style.background = t.background;
  term.options.theme = { ...(term.options.theme || {}), ...t };
};
// Font controls, driven by the parent chrome (same-origin direct calls like
// acSetTheme): step the size, persist it, refit, tell the pty. Returns the
// applied size so the chrome's label never guesses.
window.acGetFont = () => term.options.fontSize || 12;
window.acSetFont = (d) => {
  const v = fclamp((term.options.fontSize || 12) + d);
  term.options.fontSize = v;
  try { localStorage.setItem(FKEY, String(v)); } catch { }
  fit.fit(); syncSize();
  return v;
};
// Ask for it now rather than waiting for the parent's next poll render - the
// frame knows when it is ready, the parent does not.
try { if (parent !== window && typeof parent.termTheme === "function") parent.termTheme(); } catch { /* no parent - opened directly */ }
connect();
</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/** Standalone native pane view (chief-pane-native-attach, re-landed as its
 * own URL after the panel reverted to the snapshot): xterm.js over
 * /api/room/attach-ws - a real byte-stream of ONE task pane. The grid is
 * FIXED at the pane's real geometry (the server's {geometry} frame); the
 * FONT fills the width and the bottom anchors (the pane's aspect never
 * matches the window's). Typing translates xterm.onData into the gated
 * roomInput route - the attach pty itself is a pure viewer (measured). */
function attachFramePage(): Response {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>agent-crew pane mirror</title>
<link rel="stylesheet" href="/assets/xterm/xterm.css">
<style>
html,body{margin:0;height:100%;overflow:hidden;background:#0c252d}
/* Bottom-anchored: the pane grid rarely shares the panel's aspect ratio, so a
 * width-filling font can overflow the height - a terminal lives at its bottom
 * (prompt, newest output), so the top is what crops, and the wheel (xterm
 * scrollback) still reaches everything above. */
#t{height:100%;padding:4px 0 0 6px;box-sizing:border-box;display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden}
/* WRAP mode (re-wrap to the viewer's font): the byte mirror can only zoom -
 * its grid belongs to the real pane - so rewrap-on-font rides the snapshot
 * HTML instead, where soft-wrap is free. Reading surface: typing needs the
 * mirror, so the toggle swaps whole surfaces. */
:root{${ANSI_DARK}}
#w{display:none;height:100%;overflow-y:auto;padding:6px 12px;box-sizing:border-box;white-space:pre-wrap;word-break:break-word;font:13px 'JetBrains Mono','Hack Nerd Font Mono',Menlo,Monaco,monospace;line-height:1.4;color:var(--ansi-7)}
body.wrapmode #t{display:none}
body.wrapmode #w{display:block}
/* Box-drawing rules are drawn at the pane's own width - wrapped they leave a
 * stub line under every rule, so each run stays on one clipped line. */
#w .wsep{display:inline-block;max-width:100%;white-space:nowrap;overflow:hidden;vertical-align:bottom}
/* Font controls: hover-dim so the bar never competes with pane content; the
 * size label doubles as the back-to-auto-fit reset. */
#bar{position:fixed;top:6px;right:10px;z-index:2;display:flex;gap:4px;align-items:center;opacity:.35;transition:opacity .15s;font:11px 'JetBrains Mono',Menlo,monospace}
#bar:hover{opacity:1}
#bar button,#bar span{background:#16323c;color:#9fb6bd;border:1px solid #24444f;border-radius:4px;padding:2px 7px;cursor:pointer;font:inherit}
.xterm-viewport{scrollbar-width:none;-ms-overflow-style:none}
.xterm-viewport::-webkit-scrollbar{width:0;height:0}</style>
<script src="/assets/xterm/xterm.js"></script>
<script src="/assets/xterm/addon-unicode11.js"></script>
<script src="/assets/xterm/addon-web-links.js"></script>
</head><body><div id="t"></div>
<pre id="w"></pre>
<div id="bar"><button id="fm" title="Smaller font">A-</button><span id="fs" title="Click: back to auto-fit">auto</span><button id="fp" title="Larger font">A+</button><button id="wr" title="Wrap: re-wrap the pane text to this window and font (reading view; typing needs the mirror)">wrap</button></div>
<script>
const q = new URLSearchParams(location.search);
const path = q.get("path") ?? "";
const tq = q.get("fleet") === "1" ? "&fleet=1" : "&family=" + encodeURIComponent(q.get("family") ?? "");
const watch = q.get("watch") ?? "";
const term = new Terminal({
  fontSize: 12, scrollback: 2000, theme: { background: "#0c252d" },
  // Same stack as the term page: WezTerm parity (see the note there).
  fontFamily: "'JetBrains Mono', 'Hack Nerd Font Mono', Menlo, Monaco, 'SF Mono', 'DejaVu Sans Mono', monospace",
  allowProposedApi: true,
});
term.loadAddon(new Unicode11Addon.Unicode11Addon());
term.unicode.activeVersion = "11";
term.loadAddon(new WebLinksAddon.WebLinksAddon((e, uri) => {
  if (/^https?:$/i.test(uri.split("//")[0])) { const w = window.open(uri, "_blank"); if (w) w.opener = null; }
}));
term.open(document.getElementById("t"));
// Typing types into the pane, web-terminal style. The attach pty itself
// never forwards input (measured: \`herdr agent attach\` is a pure viewer)
// and the ws stays output-only - xterm.onData (composed text, Vietnamese IME
// included, or an encoded control sequence) is translated to the roomInput
// shapes, the same gated path every other typing surface uses.
const ATT_KEYS = { "\\r": "enter", "\\x7f": "backspace", "\\t": "tab", "\\x1b": "esc", "\\x1b[A": "up", "\\x1b[B": "down", "\\x1b[C": "right", "\\x1b[D": "left", "\\x1b[Z": "shift+tab", "\\x1b[5~": "pageup", "\\x1b[6~": "pagedown" };
function sendInput(body) {
  fetch("/api/room/input?path=" + encodeURIComponent(path) + tq + (watch ? "&watch=" + encodeURIComponent(watch) : ""),
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }).catch(() => { });
}
term.onData((d) => {
  if (ATT_KEYS[d] !== undefined) { sendInput({ key: ATT_KEYS[d] }); return; }
  if (d.length === 1) {
    const c = d.charCodeAt(0);
    if (c < 32 || c === 127) { if (c >= 1 && c <= 26) sendInput({ key: "ctrl+" + String.fromCharCode(96 + c) }); return; }
    sendInput({ text: d }); return;
  }
  if (d.charCodeAt(0) === 27) return;   // unmapped escape sequence - dropped
  sendInput({ paste: d });
});
term.focus();
// Font-fit: grid is the pane's, so scale the font until the pane's COLUMNS
// span the box - full width, no dead right margin; height crops at the TOP
// via the bottom-anchored holder. One
// proportional step off the rendered screen size, then ONE settle pass that
// may only SHRINK: xterm cell sizes round to whole pixels, so the exact fit
// can sit between two font steps and a symmetric epsilon loop oscillates
// between them forever (measured: the whole pane shimmered between two
// sizes). Shrink-only settling terminates by construction.
let grid = null, fitT = null;
// Manual font override (the A-/A+ header, web-terminal parity): a chosen size
// wins over auto-fit until reset to auto; persisted per browser like the web
// terminal's own FKEY.
const AFK = "ac_attach_font";
let manualFont = 0;
try { manualFont = parseInt(localStorage.getItem(AFK) || "0", 10) || 0; } catch { }
window.acGetFont = () => term.options.fontSize || 12;
window.acSetFont = (d) => {
  if (d === 0) { manualFont = 0; try { localStorage.removeItem(AFK); } catch { } fitFont(); return window.acGetFont(); }
  manualFont = Math.max(6, Math.min(24, Math.round((term.options.fontSize || 12) + d)));
  try { localStorage.setItem(AFK, String(manualFont)); } catch { }
  term.options.fontSize = manualFont;
  return manualFont;
};
function fitFont(settle) {
  if (!grid) return;
  if (manualFont) { if (term.options.fontSize !== manualFont) term.options.fontSize = manualFont; return; }
  const holder = document.getElementById("t");
  const screen = document.querySelector(".xterm-screen");
  if (!holder || !screen || !screen.clientWidth || !screen.clientHeight) return;
  const f = term.options.fontSize || 12;
  const scale = (holder.clientWidth - 10) / screen.clientWidth;
  const nf = Math.max(6, Math.min(20, Math.floor(f * scale * 100) / 100));
  if (Math.abs(nf - f) > 0.15 && (!settle || nf < f)) {
    term.options.fontSize = nf;
    if (!settle) { clearTimeout(fitT); fitT = setTimeout(() => fitFont(true), 60); }
  }
}
new ResizeObserver(() => { clearTimeout(fitT); fitT = setTimeout(fitFont, 120); }).observe(document.getElementById("t"));
// A pane that cannot be mirrored: tell the parent when embedded, else say so
// inline - a standalone tab has nobody else to fall back to.
function attachGone(why) {
  try { if (parent !== window && parent.acAttachDead) { parent.acAttachDead(why); return; } } catch { }
  term.write("\\r\\n\\x1b[33m[" + why + " - reload to retry]\\x1b[0m\\r\\n");
}
let ws = null, gen = 0, dead = false, retries = 0, carry = "";
// NOT TextDecoder("latin1"): that label is windows-1252, which remaps bytes
// 0x80-0x9f onto punctuation code points - exactly the range Vietnamese
// UTF-8 continuation bytes live in (measured: every "đ" vanished). A manual
// byte->char map is the only true 1:1 round-trip.
const b2s = (buf) => { const u = new Uint8Array(buf); let out = ""; for (let i = 0; i < u.length; i++) out += String.fromCharCode(u[i]); return out; };
function connect() {
  const g = ++gen;
  carry = "";
  ws = new WebSocket("ws://" + location.host + "/api/room/attach-ws?path=" + encodeURIComponent(path)
    + tq + (watch ? "&watch=" + encodeURIComponent(watch) : ""));
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { if (g === gen) { retries = 0; term.reset(); } };
  ws.onmessage = (e) => {
    if (g !== gen) return;
    if (typeof e.data === "string") {
      // TEXT frames are server control: {closed,why} latches pane-gone (no
      // reconnect loop on a dead pane); {geometry} fixes the grid.
      try {
        const c = JSON.parse(e.data);
        if (c.closed) { dead = true; attachGone(c.why || "pane gone"); return; }
        if (c.geometry) { grid = c.geometry; term.resize(grid.cols, grid.rows); requestAnimationFrame(fitFont); }
      } catch { }
      return;
    }
    // The pane paints on the ALTERNATE screen (no xterm scrollback) and
    // enables MOUSE TRACKING (the wheel reports to the app instead of
    // scrolling - measured: 1000h/1002h/1003h/1006h ride the live stream).
    // Strip both families of switches: the paint lands on the normal buffer
    // where the preloaded history accumulates, and the wheel scrolls it
    // locally. Bytes ride a manual 1:1 char map and re-encode, so UTF-8 text
    // is never mangled; the carry holds an escape split across chunks.
    let s = carry + b2s(e.data);
    carry = "";
    const tail = s.match(/\\x1b(?:\\[\\??[0-9]{0,4})?$/);
    if (tail) { carry = tail[0]; s = s.slice(0, s.length - tail[0].length); }
    s = s.replace(/\\x1b\\[\\?(?:1049|1047|47|100[0-6]|101[56])[hl]/g, "");
    if (s) term.write(Uint8Array.from(s, (ch) => ch.charCodeAt(0)));
  };
  ws.onclose = (e) => {
    if (g !== gen || dead) return;
    retries++;
    if (retries > 3) { attachGone(e.reason || "attach unavailable"); return; }
    term.write("\\r\\n\\x1b[33m[reconnecting…]\\x1b[0m\\r\\n");
    setTimeout(() => { if (g === gen) connect(); }, 1200);
  };
}
// Theme: pull the parent's live palette at load (same-origin), then follow
// pushes - the parent's termTheme() covers every later theme/palette change.
window.acSetTheme = (t) => {
  if (!t || !t.background) return;
  document.body.style.background = t.background;
  term.options.theme = { ...(term.options.theme || {}), ...t };
};
try {
  if (parent !== window && typeof parent.termThemeCore === "function") {
    const r = parent.termThemeCore(parent.getComputedStyle(parent.document.documentElement));
    if (r) window.acSetTheme(r.theme);
  }
} catch { /* opened directly - keep the default */ }
// WRAP mode: 1s snapshot poll into the pre-wrap surface; the mirror ws stays
// connected underneath so switching back is instant.
const wEl = document.getElementById("w");
let wrapMode = false, wrapT = null, wrapFont = 13;
try { wrapFont = parseInt(localStorage.getItem("ac_wrap_font") || "13", 10) || 13; } catch { }
wEl.style.fontSize = wrapFont + "px";
function wrapTick() {
  fetch("/api/room/pane?path=" + encodeURIComponent(path) + tq + (watch ? "&watch=" + encodeURIComponent(watch) : "") + "&lines=1200")
    .then((r) => r.json()).then((j) => {
      if (!wrapMode || j.html === undefined || wEl._h === j.html) return;
      const pinned = wEl.scrollTop + wEl.clientHeight >= wEl.scrollHeight - 8;
      wEl._h = j.html;
      // Pane lines are padded to the pane's full width - the trailing space
      // runs wrap into phantom blank fragments, so they go before render.
      wEl.innerHTML = j.html.replace(/ +(?=\\n|$)/gm, "").replace(/─{20,}/g, '<span class="wsep">$&</span>');
      if (pinned) wEl.scrollTop = wEl.scrollHeight;
    }).catch(() => { });
}
function setWrap(on) {
  wrapMode = on;
  document.body.classList.toggle("wrapmode", on);
  document.getElementById("wr").style.color = on ? "#b4fa72" : "";
  try { localStorage.setItem("ac_attach_wrap", on ? "1" : "0"); } catch { }
  if (on) { wEl._h = undefined; wrapTick(); wrapT = setInterval(wrapTick, 1000); }
  else { clearInterval(wrapT); wrapT = null; term.focus(); }
  fsLabel();
}
// The bar drives whichever surface is up: mirror font is the acSetFont
// manual-override (label resets to auto-fit), wrap font is its own persisted
// size (label resets to 13).
const fsEl = document.getElementById("fs");
const fsLabel = () => { fsEl.textContent = wrapMode ? String(wrapFont) : (manualFont ? String(manualFont) : "auto"); };
const bump = (d) => {
  if (wrapMode) {
    wrapFont = d === 0 ? 13 : Math.max(8, Math.min(28, wrapFont + d));
    try { localStorage.setItem("ac_wrap_font", String(wrapFont)); } catch { }
    wEl.style.fontSize = wrapFont + "px";
  } else window.acSetFont(d);
  fsLabel();
};
document.getElementById("fm").onclick = () => bump(-1);
document.getElementById("fp").onclick = () => bump(1);
fsEl.onclick = () => bump(0);
document.getElementById("wr").onclick = () => setWrap(!wrapMode);
fsLabel();
connect();
try { if (localStorage.getItem("ac_attach_wrap") === "1") setWrap(true); } catch { }
</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/** Standalone terminal page (GET /term?path=<home>) - the captain opens the
 * fleet terminal in its OWN browser tab, the same shape /review gives an
 * artifact: no SPA shell, a minimal bar, a full-viewport /term-frame iframe.
 * The frame calls parent.termTheme() when ready, so this page carries its own
 * copy of the SPA's theme push (same --term-bg/--term-fg + --ansi-N pipeline
 * into acSetTheme); /api/term/status still gates the home path, and an
 * unavailable terminal retries rather than dying on a blank frame. */
async function termStandalonePage(): Promise<Response> {
  // The terminal does not FOLLOW a home: herdr is one
  // session machine-wide, so ?path is only the API gate's ticket - absent it,
  // any known home is embedded as the fallback and the URL stays a bare /term.
  const fallbackHome: string = (await allowedHomePaths()).values().next().value ?? "";
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>agent-crew terminal</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
${THEME_INIT}
<style>
${THEME_VARS}
${UX_BASE}
  :root{ --ui: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }
  html,body{margin:0;height:100%}
  body{background:var(--canvas);color:var(--fg);font:14px/1.5 var(--ui);display:flex;flex-direction:column;height:100dvh;overflow:hidden}
  #bar{display:flex;gap:10px;align-items:center;padding:7px 12px;border-bottom:1px solid var(--border);background:var(--surface)}
  #bar .name{font-weight:600;font-size:14px}
  #bar #status{color:var(--fg2);font-size:12px}
  #frame{flex:1;min-height:0}
  #frame iframe{width:100%;height:100%;border:0;background:var(--term-bg, var(--canvas))}
  .cdead{padding:16px;color:var(--fg2)}
</style></head><body>
<div id="bar"><span class="name">terminal</span><span id="status"></span></div>
<div id="frame"></div>
<script>
const q = new URLSearchParams(location.search);
const home = q.get("path") || ${JSON.stringify(fallbackHome)};
${termThemeCore.toString()}
let lastSig = "";
window.termTheme = () => {
  const f = document.querySelector("#frame iframe"); if (!f) return;
  const r = termThemeCore(getComputedStyle(document.documentElement));
  if (!r || r.sig === lastSig) return;
  const w = f.contentWindow;
  if (w && typeof w.acSetTheme === "function") { w.acSetTheme(r.theme); lastSig = r.sig; }
};
function boot(){
  const fr=document.getElementById("frame"), st=document.getElementById("status");
  if(!home){ fr.innerHTML="<div class=cdead>no fleet home is registered - the API gate has no ticket</div>"; return; }
  st.textContent = "";
  fetch("/api/term/status?path="+encodeURIComponent(home)).then((r)=>r.json()).then((j)=>{
    if(j && j.running && j.url){ const f=document.createElement("iframe"); f.src=j.url; f.title="herdr terminal"; fr.replaceChildren(f); }
    else { fr.innerHTML="<div class=cdead>terminal unavailable - retrying</div>"; setTimeout(boot, 3000); }
  }).catch(()=>{ st.textContent="retrying"; setTimeout(boot, 3000); });
}
boot();
</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/** The CREWCHIEF pane for a home (chief panel, slice C): the fleet session is
 * not a spawned task (no meta), so it is found the way the fleet's own tooling
 * proves liveness - state/.session-lock names the harness pid, and the pane
 * whose foreground process group IS that pid is the chief's. The scan is one
 * pane-list plus at most a handful of process-info calls, memoized 30s. */
const fleetChiefCache = new Map<string, { at: number; h: { pane: string; tab: string | null } | null }>();
async function fleetChiefHandle(homePath: string): Promise<{ pane: string; tab: string | null } | null> {
  const hit = fleetChiefCache.get(homePath);
  if (hit && Date.now() - hit.at < 30_000) return hit.h;
  let pid = 0;
  try {
    const m = /^pid=(\d+)$/m.exec(readFileSync(`${homePath}/state/.session-lock`, "utf8"));
    pid = m ? Number(m[1]) : 0;
  } catch { /* no lock - no chief session */ }
  let h: { pane: string; tab: string | null } | null = null;
  if (pid) {
    const ls = await run(["herdr", "pane", "list"], { AC_HOME: homePath });
    if (ls.code === 0) {
      try {
        const panes: { pane_id: string; tab_id: string; agent?: string }[] =
          JSON.parse(ls.out).result?.panes ?? [];
        for (const p of panes) {
          if (!p.agent) continue; // a bare shell can never be the chief harness
          const pi = await run(["herdr", "pane", "process-info", "--pane", p.pane_id], { AC_HOME: homePath });
          if (pi.code !== 0) continue;
          try {
            if (JSON.parse(pi.out).result?.process_info?.foreground_process_group_id === pid) {
              h = { pane: p.pane_id, tab: p.tab_id ?? null };
              break;
            }
          } catch { /* unparseable - skip */ }
        }
      } catch { /* unparseable list */ }
    }
  }
  fleetChiefCache.set(homePath, { at: Date.now(), h });
  return h;
}

/** POST /api/room/send (chief panel, slice B): one whole message into the
 * family's roomchief session, through bin/ac-send.sh - the SAME verified
 * typed-then-submitted path the crewchief itself steers with, so delivery
 * failures surface here instead of vanishing. Chief-only by construction:
 * the id sent is always `<family>-chief` and the meta kind was checked. */
/** Membership gate shared by send/input for a watched pane: the id counts
 * only if familyPaneIds derives it from this family's own metas. Returns the
 * pane handle, or null. */
function watchedHandle(homePath: string, family: string, watchId: string): { pane: string; tab: string | null } | null {
  let metas: { id: string; text: string }[] = [];
  try {
    metas = readdirSync(`${homePath}/state`).filter((f) => f.endsWith(".meta"))
      .map((f) => { try { return { id: f.slice(0, -5), text: readFileSync(`${homePath}/state/${f}`, "utf8") }; } catch { return null; } })
      .filter((x): x is { id: string; text: string } => !!x);
  } catch { return null; }
  if (!familyPaneIds(metas, family).some((x) => x.id === watchId)) return null;
  const meta = metas.find((x) => x.id === watchId);
  return paneHandleByMeta(homePath, watchId, meta ? meta.text : "");
}

async function roomSend(homePath: string, family: string, text: string, watchId = ""): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  const fleet = family === "";
  if (!fleet && !/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  const msg = text.replace(/\r/g, "").trim();
  if (!msg) return json({ error: "message required" }, 400);
  if (msg.length > 4000) return json({ error: "message too long (4000 max)" }, 400);
  if (fleet) {
    // Crewchief (slice C): not a task id, so ac-send cannot address it - the
    // message goes in the way the captain's own keyboard would: focus, type,
    // Enter. Single-line only; a multi-line paste would submit line one.
    if (/\n/.test(msg)) return json({ error: "crewchief messages are one line" }, 400);
    const h = await fleetChiefHandle(homePath);
    if (!h) return json({ error: "no live crewchief session for this fleet" }, 409);
    if (h.tab) await run(["herdr", "tab", "focus", h.tab], { AC_HOME: homePath });
    const t1 = await run(["herdr", "pane", "send-text", h.pane, msg], { AC_HOME: homePath });
    if (t1.code !== 0) return json({ error: "send failed" }, 502);
    const t2 = await run(["herdr", "pane", "send-keys", h.pane, "enter"], { AC_HOME: homePath });
    return t2.code === 0 ? json({ ok: true }) : json({ error: "typed but not submitted - press Enter in the pane" }, 502);
  }
  if (watchId) {
    if (!/^[a-zA-Z0-9_.-]+$/.test(watchId)) return json({ error: "bad watch id" }, 400);
    if (!watchedHandle(homePath, family, watchId))
      return json({ error: "not a pane of this family" }, 409);
    const r = await run([`${BIN}/ac-send.sh`, watchId, msg], { AC_HOME: homePath });
    return r.code === 0 ? json({ ok: true })
      : json({ error: "send failed", detail: r.out.split("\n").slice(-3).join(" ").slice(0, 300) }, 502);
  }
  if (!chiefHandleOf(homePath, family))
    return json({ error: "no live roomchief for this family" }, 409);
  // Multi-line is legal for ac-send (one submitted message); \r never is.
  const { code, out } = await run(
    [`${BIN}/ac-send.sh`, `${family}-chief`, msg],
    { AC_HOME: homePath },
  );
  if (code !== 0)
    return json({ error: "send failed", detail: out.split("\n").slice(-3).join(" ").slice(0, 300) }, 502);
  return json({ ok: true });
}

/** POST /api/room/input (chief panel, slice B): ONE keystroke into the chief
 * pane - a named key from the closed CHIEF_KEYS list (herdr send-keys) or one
 * printable character (herdr send-text). Focus-first, mirroring
 * backend_send_key: an unfocused pane no-ops key presses at exit 0. */
async function roomInput(homePath: string, family: string, body: { key?: string; text?: string; paste?: string }, watchId = ""): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (family !== "" && !/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  let h: { pane: string; tab: string | null } | null;
  if (watchId) {
    if (family === "" || !/^[a-zA-Z0-9_.-]+$/.test(watchId)) return json({ error: "bad watch id" }, 400);
    h = watchedHandle(homePath, family, watchId);
    if (!h) return json({ error: "not a pane of this family" }, 409);
  } else {
    h = family === "" ? await fleetChiefHandle(homePath) : chiefHandleOf(homePath, family);
    if (!h) return json({ error: family === "" ? "no live crewchief session" : "no live roomchief for this family" }, 409);
  }
  const key = (body.key ?? "").toLowerCase();
  const paste = (body.paste ?? "").replace(/\r/g, "");
  const text = body.text ?? "";
  if (key && !isChiefKey(key)) return json({ error: "key not allowed" }, 400);
  if (!key && paste && !isChiefPaste(paste)) return json({ error: "paste must be printable, 2000 chars max" }, 400);
  if (!key && !paste && !isChiefChar(text)) return json({ error: "one printable character or an allowed key" }, 400);
  if (h.tab) await run(["herdr", "tab", "focus", h.tab], { AC_HOME: homePath });
  const { code } = key
    ? await run(["herdr", "pane", "send-keys", h.pane, key], { AC_HOME: homePath })
    : await run(["herdr", "pane", "send-text", h.pane, paste || text], { AC_HOME: homePath });
  return code === 0 ? json({ ok: true }) : json({ error: "input failed" }, 502);
}

/** POST /api/room/attach (image paste): save the pasted image under the
 * family's data dir (data/<family>/attachments/, or data/attachments for the
 * fleet chief) and TYPE its absolute path into the target pane - no Enter,
 * the captain finishes the message around it. Claude harnesses read image
 * paths from the prompt, so the pane gets exactly what typing the path by
 * hand would. Target resolution shares the chat gates verbatim. */
async function roomAttach(homePath: string, family: string, watchId: string, contentType: string | null, bytes: Uint8Array): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (family !== "" && !/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  const ext = attachExt(contentType);
  if (!ext) return json({ error: "png, jpeg, webp or gif only" }, 415);
  if (!bytes.length || bytes.length > 8 * 1024 * 1024)
    return json({ error: "image must be 1 byte .. 8MB" }, 413);
  let h: { pane: string; tab: string | null } | null;
  if (watchId) {
    if (family === "" || !/^[a-zA-Z0-9_.-]+$/.test(watchId)) return json({ error: "bad watch id" }, 400);
    h = watchedHandle(homePath, family, watchId);
  } else {
    h = family === "" ? await fleetChiefHandle(homePath) : chiefHandleOf(homePath, family);
  }
  if (!h) return json({ error: "no live target pane" }, 409);
  const dir = family === "" ? `${homePath}/data/attachments` : `${familyDataDir(homePath, family)}/attachments`;
  mkdirSync(dir, { recursive: true });
  const file = `${dir}/paste-${Date.now()}.${ext}`;
  writeFileSync(file, bytes);
  if (h.tab) await run(["herdr", "tab", "focus", h.tab], { AC_HOME: homePath });
  const typed = await run(["herdr", "pane", "send-text", h.pane, `${file} `], { AC_HOME: homePath });
  return json({ ok: typed.code === 0, file, typed: typed.code === 0 });
}

/**
 * The queried pane's real column count out of `herdr pane layout --pane
 * <id>`'s JSON stdout. The client used to INFER columns from the pane's own
 * box-drawing separator runs, but a TUI that draws a separator wider than its
 * own pty (or "recent-unwrapped" rejoining several stacked separator lines
 * into one) inflates that guess past the true width - this reads the pty's
 * actual size instead. `undefined` on anything unparseable, so the caller can
 * fall back to the old heuristic rather than fail the frame.
 */
export function paneLayoutCols(out: string, pane: string): number | undefined {
  try {
    const j = JSON.parse(out) as { result?: { layout?: { panes?: { pane_id?: string; rect?: { width?: number } }[] } } };
    const p = (j.result?.layout?.panes || []).find((x) => x.pane_id === pane);
    const w = p?.rect?.width;
    return typeof w === "number" && w > 0 ? w : undefined;
  } catch {
    return undefined;
  }
}

// True column count per pane, cached: the pane stream ticks every 250ms, and
// a pane's width only changes when someone resizes the herdr workspace, so
// re-shelling `herdr pane layout` on every tick would double this hot path's
// subprocess cost for a value that is almost always unchanged.
const paneColsCache = new Map<string, { cols: number; at: number }>();
const PANE_COLS_TTL_MS = 5000;
async function paneCols(homePath: string, pane: string): Promise<number | undefined> {
  const cached = paneColsCache.get(pane);
  const now = Date.now();
  if (cached && now - cached.at < PANE_COLS_TTL_MS) return cached.cols;
  const { code, out } = await run(["herdr", "pane", "layout", "--pane", pane], { AC_HOME: homePath });
  if (code !== 0) return cached?.cols;
  const cols = paneLayoutCols(out, pane);
  if (cols === undefined) return cached?.cols;
  // Panes churn (worktree pool leases, task teardown) - drop entries nobody
  // has refreshed in a while so the cache does not grow for the process's
  // whole lifetime.
  for (const [id, e] of paneColsCache) if (now - e.at > PANE_COLS_TTL_MS * 4) paneColsCache.delete(id);
  paneColsCache.set(pane, { cols, at: now });
  return cols;
}

/** Resolve the pane the chief panel points at - the family's roomchief, the
 * fleet crewchief (family ""), or a watched member pane. ONE resolver shared
 * by the snapshot read (roomPane) and the native attach ws, so both surfaces
 * hold the same membership gate: a watch id only counts when the family
 * really owns it, and a crewmate id can never be read as a chief. */
async function panelPaneOf(homePath: string, family: string, watchId: string): Promise<{ pane: string; readonly: boolean } | { why: string }> {
  if (watchId) {
    let metas: { id: string; text: string }[] = [];
    try {
      metas = readdirSync(`${homePath}/state`).filter((f) => f.endsWith(".meta"))
        .map((f) => { try { return { id: f.slice(0, -5), text: readFileSync(`${homePath}/state/${f}`, "utf8") }; } catch { return null; } })
        .filter((x): x is { id: string; text: string } => !!x);
    } catch { /* no state dir */ }
    const member = familyPaneIds(metas, family).find((x) => x.id === watchId);
    if (!member) return { why: "not a pane of this family" };
    const meta = metas.find((x) => x.id === watchId);
    const h = paneHandleByMeta(homePath, watchId, meta ? meta.text : "");
    if (!h) return { why: "pane handle unresolvable" };
    return { pane: h.pane, readonly: true };
  }
  if (family === "") {
    // Crewchief target (slice C): resolved via the session lock, not a meta.
    const h = await fleetChiefHandle(homePath);
    if (!h) return { why: "no live crewchief session" };
    return { pane: h.pane, readonly: false };
  }
  let metaText = "";
  try {
    metaText = readFileSync(`${homePath}/state/${family}-chief.meta`, "utf8");
  } catch {
    return { why: "no roomchief for this family" };
  }
  let pane = chiefPaneOf(metaText);
  if (!pane) return { why: "chief meta carries no readable pane" };
  // The handle FILE is what the backend itself reads (backend_capture): panes
  // can be re-created after spawn, so its first token outranks the meta echo.
  try {
    const tok = readFileSync(`${homePath}/state/.pane-${family}-chief`, "utf8").trim().split(/\s+/)[0];
    if (tok && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(tok)) pane = tok;
  } catch { /* no handle file - keep the meta-derived pane */ }
  return { pane, readonly: false };
}

/** Live capture of a family's ROOMCHIEF pane (chief panel, slice A): resolves
 * the pane strictly from state/<family>-chief.meta via chiefPaneOf (kind gate
 * included - a crewmate id can never be read through here), fetches an ANSI
 * frame from herdr (>=200 lines - the read returns EMPTY below the viewport
 * height, ac-backend.sh's documented quirk - then trims), and returns it
 * pre-rendered by ansiToHtml so the client only ever innerHTMLs escaped spans. */
async function roomPane(homePath: string, family: string, watchId = "", lines = 400): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (family !== "" && !/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  if (watchId && (family === "" || !/^[a-zA-Z0-9_.-]+$/.test(watchId)))
    return json({ error: "bad watch id" }, 400);
  const t = await panelPaneOf(homePath, family, watchId);
  if ("why" in t) return json({ live: false, why: t.why });
  const r = await run(
    ["herdr", "pane", "read", t.pane, "--source", "recent-unwrapped", "--format", "ansi", "--lines", String(Math.max(lines, 200))],
    { AC_HOME: homePath },
  );
  if (r.code !== 0) return json({ live: false, why: "pane unreadable (backend down or pane gone)" });
  const body: Record<string, unknown> = { live: true, pane: t.pane, cols: await paneCols(homePath, t.pane), html: ansiToHtml(r.out.split("\n").slice(-lines).join("\n")) };
  if (t.readonly) body.readonly = true;
  return json(body);
}

/** herdr argv for the chief panel's native mirror: `agent attach` shares the
 * pane's real pty non-disruptively (proven in the field by the distro peer's
 * dash-server). Pure - unit-tested. */
export function attachArgv(pane: string): string[] {
  return ["herdr", "agent", "attach", pane];
}

/** Rows for a native attach, from `herdr pane get` scroll.viewport_rows: the
 * mirror must spawn at the pane's OWN grid (passive-size), because herdr
 * sizes a shared pane to the last writer - a viewer-sized attach would
 * reflow the pane under the working agent. Pure - unit-tested. */
export function paneViewportRows(out: string, dflt: number): number {
  try {
    const r = (JSON.parse(out) as { result?: { pane?: { scroll?: { viewport_rows?: number } } } }).result?.pane?.scroll?.viewport_rows;
    return typeof r === "number" && Number.isFinite(r) && r >= 1 ? Math.min(Math.floor(r), 200) : dflt;
  } catch {
    return dflt;
  }
}
async function paneRows(homePath: string, pane: string): Promise<number> {
  const { code, out } = await run(["herdr", "pane", "get", pane], { AC_HOME: homePath });
  return code === 0 ? paneViewportRows(out, 40) : 40;
}

/** Full room narrative for one family (§2.3). */
async function roomShow(homePath: string, family: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);
  return json({ family, entries: await readRoomEntries(homePath, family) });
}

/**
 * The family a task id belongs to, by LONGEST KNOWN-FAMILY PREFIX: cut the id at
 * its last `-` until what remains is a family the backlog actually carries.
 * familyOfTaskId answers the same question off a FIXED stage-suffix list, which
 * is right for the snapshot join (its ids are stage panes) and wrong here: a
 * family's per-repo siblings suffix freely (`-api`, `-web`, `-impl`, `-e2e` -
 * verified across a live home's state/archive), and only the known-family set
 * can tell `signup-api` (a sibling of the `signup` family) from `checkout` (a
 * family of its own, never folded onto the epic it is a story of).
 * "" when no prefix is a known family - an archived task whose row is gone.
 */
/** Parse a data/<epic>/branches record (epic-branch-mech): one `<repo>
 *  <branch> [key=value ...]` per line; a `# retired <iso>` first line marks
 *  the deliberate end of the fence. Pure - familyDetail feeds it the file. */
export function parseEpicBranches(text: string): { repo: string; branch: string; staging: string; push: boolean; retired: boolean }[] {
  const lines = String(text || "").split("\n");
  const retired = /^# retired /.test(lines[0] || "");
  const out: { repo: string; branch: string; staging: string; push: boolean; retired: boolean }[] = [];
  for (const ln of lines) {
    const t = ln.trim();
    if (!t || t.startsWith("#")) continue;
    const parts = t.split(/\s+/);
    if (parts.length < 2) continue;
    let staging = "", push = false;
    for (const kv of parts.slice(2)) {
      if (kv.startsWith("staging=")) staging = kv.slice(8);
      if (kv === "push=yes") push = true;
    }
    out.push({ repo: parts[0], branch: parts[1], staging, push, retired });
  }
  return out;
}

export function taskFamilyOf(id: string, known: string[]): string {
  let s = String(id || "");
  while (s) {
    if (known.indexOf(s) >= 0) return s;
    const cut = s.lastIndexOf("-");
    if (cut <= 0) return "";
    s = s.slice(0, cut);
  }
  return "";
}

/**
 * Every task meta belonging to one of `families` - live `state/<id>.meta` plus
 * archived `state/archive/<id>/meta` - reduced to the two fields the board
 * detail joins on: the repo it leased (`project=`) and the PR it raised
 * (`pr=`/`pr_merged=`, written by ac-pr-check.sh / ac-pr-merge.sh). This is the
 * ONLY record of a per-repo sibling's repo and PR: the family's backlog line
 * carries one `repo:` token and at most one PR link, so a family that landed
 * four PRs across four repos showed exactly one of each before this.
 * Membership is `fleet_scope=` when the meta carries it (ac-spawn.sh writes it
 * for scoped work), else taskFamilyOf - older metas and every chief meta have no
 * fleet_scope. A CHIEF's `project=` is NOT a repo and is skipped: ac-spawn.sh
 * writes the FAMILY there for a roomchief (:1126) and a literal `-` for a
 * crewdeputy (:1266), both of which ran in the fleet home, not a project clone.
 * Metas left with neither a repo nor a PR are dropped: they add nothing either
 * list can render.
 */
export function collectFamilyTasks(
  homePath: string,
  families: string[],
  known: string[],
): { id: string; family: string; repo: string; pr: string; prMerged: boolean; kind: string; live: boolean }[] {
  const out: { id: string; family: string; repo: string; pr: string; prMerged: boolean; kind: string; live: boolean }[] = [];
  const take = (id: string, text: string, live: boolean) => {
    const family = metaValue(text, "fleet_scope") || taskFamilyOf(id, known);
    // exact-id match rides beside the family match so a SUB-TASK detail
    // (families=[<sub-id>]) finds its own meta even though the meta's scope
    // names the parent family
    if (families.indexOf(family) < 0 && families.indexOf(id) < 0) return;
    const kind = metaValue(text, "kind");
    const repo = kind === "roomchief" || kind === "crewdeputy" ? "" : metaValue(text, "project");
    const pr = metaValue(text, "pr");
    if (!repo && !pr) return;
    out.push({ id, family, repo, pr, prMerged: metaValue(text, "pr_merged") === "1", kind, live });
  };
  const read = (file: string, id: string, live: boolean) => {
    try {
      take(id, readFileSync(file, "utf8"), live);
    } catch { /* unreadable meta - the task simply contributes nothing */ }
  };
  try {
    for (const f of readdirSync(`${homePath}/state`))
      if (f.endsWith(".meta")) read(`${homePath}/state/${f}`, f.slice(0, -5), true);
  } catch { /* no state dir */ }
  // ac-teardown.sh relocates a finished task's state to state/archive/<id>/ -
  // where a LANDED family's PRs live, since the meta is archived at teardown.
  try {
    for (const d of readdirSync(`${homePath}/state/archive`))
      read(`${homePath}/state/archive/${d}/meta`, d, false);
  } catch { /* no archive dir */ }
  out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return out;
}

/**
 * Board task-detail (dashboard-board, QĐ3): the ONE aggregator route. Composes a
 * family's slices by LINKING data that already exists on disk - its backlog line
 * + section, its epic stories (lines carrying `epic:<family>`), its artifact list
 * (collectArtifacts), its room (readRoomEntries), its member task metas
 * (collectFamilyTasks - the repos and PRs), and a reused-data pointer - all
 * joined by the family id. ZERO new stored fields; composeFamily is the pure
 * joiner. Every PR is read off disk (a meta field or a regex-linkified backlog
 * line): no `gh`, no network.
 */
/** A live task's change as a unified diff (worktree diff-review): shells out
 * to bin/ac-review-diff.sh, the one authority on the diff base (merge-base
 * with the LOCAL-ONLY-aware default branch, epic-branch aware). The id gate +
 * home allowlist are the whole surface - the script itself refuses an id with
 * no meta or a gone worktree, which the client renders as the empty state. */
const DIFF_MODES: Record<string, string> = {
  live: "--live", committed: "", uncommitted: "--uncommitted", untracked: "--untracked",
  // graph serves the machine-readable rows; the client draws the lane SVG
  // from them (graphHtml). commit is one commit's own change - the graph's
  // click-through (its sha rides the `sha` param).
  graph: "--graph-data", commit: "",
};
async function diffShow(homePath: string, id: string, mode: string, tree: string, sha: string, ref: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!/^[a-zA-Z0-9_-]+$/.test(id))
    return json({ error: "bad id" }, 400);
  if (!(mode in DIFF_MODES)) return json({ error: "bad mode" }, 400);
  // A client-supplied tree must be one the ac-tree pool lists for this home,
  // OR a project clone's own root (the crew-branch sections diff parked
  // branches there) - this gate is what lets the script itself stay
  // path-trusting for its CLI operator.
  if (tree && !readPools(homePath).some((p) => p.worktree === tree)
    && !readLocalBranches(homePath).some((b) => b.root === tree))
    return json({ error: "worktree not in this home's pool" }, 404);
  // The branch picker: a ref must be a branch this home's clones actually
  // carry - never a free-form rev expression.
  if (ref && !readLocalBranches(homePath).some((b) => b.branch === ref))
    return json({ error: "unknown branch" }, 404);
  const args = [`${BIN}/ac-review-diff.sh`, id];
  if (mode === "commit") {
    if (!/^[0-9a-f]{4,40}$/.test(sha)) return json({ error: "bad sha" }, 400);
    args.push("--commit", sha);
  } else if (DIFF_MODES[mode]) args.push(DIFF_MODES[mode]);
  if (tree) args.push("--tree", tree);
  if (ref) args.push("--ref", ref);
  const { code, out } = await run(args, { AC_HOME: homePath });
  if (code !== 0)
    return json({ error: `no diff for ${id} - no live worktree (torn down, or a stage id?)` }, 404);
  // 400KB keeps a runaway diff from freezing the viewer; the cut is stated.
  const MAX = 400 * 1024;
  return json({ id, mode, diff: out.slice(0, MAX), truncated: out.length > MAX });
}

async function familyDetail(homePath: string, family: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  if (!/^[a-zA-Z0-9_-]+$/.test(family))
    return json({ error: "bad family" }, 400);

  const backlogFile = `${homePath}/records/backlog.md`;
  const bl = existsSync(backlogFile)
    ? parseBacklog(readFileSync(backlogFile, "utf8"))
    : { in_flight: [], queued: [], done: [] };
  // Find this family's own line + section, and gather any epic stories that name
  // it (`epic:<family>`), each with its own section for the rollup.
  let line: string | null = null;
  let section: string | null = null;
  const children: { id: string; line: string; section: string }[] = [];
  const known: string[] = []; // every family the ledger carries - taskFamilyOf's set
  const buckets: [keyof BacklogView, string][] = [
    ["in_flight", "in_flight"],
    ["queued", "queued"],
    ["done", "done"],
  ];
  for (const [key, name] of buckets) {
    for (const raw of bl[key]) {
      const f = parseBacklogLine(raw);
      if (f.id) known.push(f.id);
      if (f.id === family && line === null) {
        line = raw;
        section = name;
      }
      if (f.epic === family) children.push({ id: f.id, line: raw, section: name });
    }
  }

  const project = parseBacklogLine(line || "").repo;
  // SUB-TASK DETAIL: a family arg with NO ledger row that extends a known
  // family is a section-8 fan-out unit - compose it from its OWN material. A
  // tasks/-nested unit's artifacts are remapped to the sub id (grouping only,
  // nav ids stay); the flat legacy layout already composes as-is. `parent`
  // rides the response so the client links back to the owning family.
  const parent = line === null ? taskFamilyOf(family, known) : "";
  const isSub = !!parent && parent !== family;
  const subPfx = isSub ? "tasks/" + family.slice(parent.length + 1) + "/" : "";
  let artifacts = collectArtifacts(homePath);
  if (isSub)
    artifacts = artifacts.map((a) =>
      a.family === parent && a.stage.indexOf(subPfx) === 0
        ? { ...a, family, stage: a.stage.slice(subPfx.length) }
        : a,
    );
  // An epic's repos and PRs are its STORIES', so its own metas are not enough:
  // the member set is the family plus every story line that named it.
  const tasks = collectFamilyTasks(
    homePath,
    [family].concat(children.map((c) => c.id)),
    known,
  );
  const roomEntries = await readRoomEntries(homePath, family);
  // Linked (reused): a knowledge record for EVERY repo the family touches (the
  // same familyRepos list composeFamily derives, so the two never disagree), and
  // the learnings ledger only when it actually names this family.
  const knowledgeRepos = familyRepos(project, tasks, children).filter((repo) =>
    existsSync(`${homePath}/records/repo-knowledge/${repo}.md`),
  );
  let learnings = "";
  try { learnings = readFileSync(`${homePath}/records/learnings.md`, "utf8"); } catch { /* no ledger */ }
  const citesFamily = learningsCiteFamily(learnings, family);

  // Durable per-task timeline (task-timeline): the family's teardown-surviving
  // timeline.log, merged with its live state/<family>.status tail when the task
  // is still running (parseTimeline dedupes the mirror). family is validated
  // `^[a-zA-Z0-9_-]+$` above, so neither path can escape the home. A history
  // read: resolve the archived copy too, same as readRoomEntries.
  let timelineText = "";
  let tdir = familyDataDir(homePath, family);
  if (isSub && !existsSync(tdir)) tdir = `${homePath}/data/${parent}/${subPfx}`.replace(/\/$/, "");
  const timelineFile = `${tdir}/timeline.log`;
  if (existsSync(timelineFile)) {
    try { timelineText += readFileSync(timelineFile, "utf8"); } catch {}
  }
  const statusFile = `${homePath}/state/${family}.status`;
  if (existsSync(statusFile)) {
    try { timelineText += "\n" + readFileSync(statusFile, "utf8"); } catch {}
  }

  // Chief panel (room-chat slice A): tell the client whether this family has a
  // live roomchief pane worth mounting the panel for - existence + kind gate
  // only; the pane itself is resolved per-read by /api/room/pane.
  let chiefLive = false;
  try {
    chiefLive = chiefPaneOf(readFileSync(`${homePath}/state/${family}-chief.meta`, "utf8")) !== null;
  } catch { /* no chief meta - unpromoted or demoted family */ }

  // Epic-branch record + recorded ship PRs (epic-branch-mech), live else
  // archived - display only, the CLI verbs own the truth.
  let epicBranches: ReturnType<typeof parseEpicBranches> = [];
  let shipPrs: string[] = [];
  for (const cand of [`${homePath}/data/${family}/branches`, ...(function () {
    try {
      return readdirSync(`${homePath}/data/archive`).map((y) => `${homePath}/data/archive/${y}/${family}/branches`);
    } catch { return [] as string[]; }
  })()]) {
    if (!existsSync(cand)) continue;
    try { epicBranches = parseEpicBranches(readFileSync(cand, "utf8")); } catch { /* unreadable record renders nothing */ }
    break;
  }
  try {
    const sh = readFileSync(`${homePath}/data/${family}/gate/ships.env`, "utf8");
    for (const m of sh.matchAll(/^pr[12]_url=(\S+)$/gm)) shipPrs.push(m[1]);
  } catch { /* no ships yet */ }

  return json({
    ...composeFamily({
      family,
      line,
      section,
      project,
      artifacts,
      roomEntries,
      children,
      knowledgeRepos,
      learningsCiteFamily: citesFamily,
      timelineText,
      tasks,
    }),
    parent: isSub ? parent : "",
    epicBranches,
    shipPrs,
    chiefLive,
  });
}

/**
 * Cross-fleet backlog search (dash-search): run matchBacklog over EVERY allowed
 * home's records/backlog.md AND every crewdomain package's own backlog.md
 * (dash-domain-records surface c, tagged like backlogDetail), returning a flat,
 * capped list of hits {home, family, line, section} - `home` is the home PATH
 * (the client names it via findHome). Reuses allowedHomePaths (crewdeputies
 * included -> cross-fleet for free) and parseBacklog through matchBacklog; the
 * only files read are each home's records/backlog.md and its crewdomain
 * packages' backlog.md, so no user-controlled path ever reaches the FS.
 * The CAP stops a 1-char query returning everything; empty `q` -> [], 200.
 */
async function search(q: string): Promise<Response> {
  if (!q.trim()) return json([]);
  const CAP = 50;
  const hits: {
    home: string;
    family: string;
    line: string;
    section: string;
  }[] = [];
  for (const home of await allowedHomePaths()) {
    if (hits.length >= CAP) break;
    const file = `${home}/records/backlog.md`;
    if (existsSync(file)) {
      let md: string | null = null;
      try {
        md = readFileSync(file, "utf8");
      } catch {
        md = null;
      }
      if (md !== null) {
        for (const h of matchBacklog(md, q)) {
          hits.push({ home, ...h });
          if (hits.length >= CAP) break;
        }
      }
    }
    if (hits.length >= CAP) break;
    for (const { name, file: dfile } of domainBacklogFiles(home)) {
      if (hits.length >= CAP) break;
      let dmd: string;
      try {
        dmd = readFileSync(dfile, "utf8");
      } catch {
        continue;
      }
      for (const h of matchBacklog(dmd, q)) {
        hits.push({ home, ...h, line: tagDomainLine(h.line, name) });
        if (hits.length >= CAP) break;
      }
    }
  }
  return json(hits);
}

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Whiteboard (dash-whiteboard slice 1: standalone)
// ---------------------------------------------------------------------------
// A captain-facing Excalidraw canvas served as its OWN page (GET /whiteboard),
// deliberately outside the SPA shell: the editor is a full-viewport tool, not
// a dashboard panel. Scenes persist as excalidraw JSON files under
// <home>/data/whiteboards/<name>.excalidraw.json - durable, agent-readable
// (an agent consumes the SCENE JSON as design input; excalidraw->mermaid
// conversion does not exist, so the agent interprets the scene and rewrites
// any mermaid source itself). Editor runtime (React, Excalidraw, the one-way
// mermaid->excalidraw converter) loads from esm.sh CDN pinned below - the
// zero-build contract of ac-dashboard.sh holds, traded for needing network
// when the EDITOR opens; the API and stored scenes stay fully local.
// Write surface: POST /api/whiteboard atomic-writes ONE normalized scene file
// under the fixed whiteboards dir - name validated by isSceneName, body by
// normalizeScene, both pure and unit-tested. Every write to an EXISTING scene
// carries an If-Match precondition (the sceneEtag of the bytes the caller
// read) or is refused 428/412 - both callers, the captain's browser and any
// agent, go through this ONE door, and a stale write no longer silently
// replaces what the other side just saved (whiteboard-agent-write-clobbers-
// captain-edits). If-Match: * force-overwrites regardless - wired ONLY into
// the two editor pages' "keep mine" button, never advertised to an agent.
// The only other reachable POST action is ?notify=1 (dash-wb-notify): it
// writes NOTHING to the scene file, it only shells out one deduped
// kind=whiteboard fleet wake via publishWhiteboardWake/ac_wake_publish.

export const WHITEBOARD_CDN = {
  react: "https://esm.sh/react@19.1.0",
  reactDomClient: "https://esm.sh/react-dom@19.1.0/client",
  excalidraw: "https://esm.sh/@excalidraw/excalidraw@0.18.0?deps=react@19.1.0,react-dom@19.1.0",
  excalidrawCss: "https://esm.sh/@excalidraw/excalidraw@0.18.0/dist/prod/index.css",
  excalidrawAssets: "https://esm.sh/@excalidraw/excalidraw@0.18.0/dist/prod/",
  mermaidToExcalidraw: "https://esm.sh/@excalidraw/mermaid-to-excalidraw@1.1.2?deps=react@19.1.0,react-dom@19.1.0",
} as const;

/** URL- and file-safe scene name: the ONE gate between a query param and a
 * filename under the whiteboards dir (no dots, no slashes, no traversal). */
export function isSceneName(name: string): boolean {
  return /^[a-z0-9][a-z0-9-]{0,63}$/.test(name);
}

/** Validate + canonicalize a scene payload for durable storage. Accepts what
 * the editor posts ({elements, appState?, files?}) and returns the excalidraw
 * file shape, or null when the body is not a plausible scene - junk, however
 * authenticated, never lands on disk. appState is reduced to the one durable
 * field (viewBackgroundColor): collaborator cursors, selections and viewport
 * are session state, and excalidraw's own restore() rejects/repairs the rest. */
export function normalizeScene(text: string): Record<string, unknown> | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null) return null;
  const o = raw as Record<string, unknown>;
  if (!Array.isArray(o.elements)) return null;
  if (!o.elements.every((e) => typeof e === "object" && e !== null)) return null;
  const appState =
    typeof o.appState === "object" && o.appState !== null
      ? (o.appState as Record<string, unknown>)
      : {};
  const files =
    typeof o.files === "object" && o.files !== null ? o.files : {};
  const bg = appState.viewBackgroundColor;
  return {
    type: "excalidraw",
    version: 2,
    source: "agent-crew-dashboard",
    elements: o.elements,
    appState: typeof bg === "string" ? { viewBackgroundColor: bg } : {},
    files,
  };
}

/** Mermaid sources inside an artifact's HTML: <pre|div class="mermaid"> blocks
 * (the design.md CDN snippet's shape) and language-mermaid code fences as
 * renderMarkdown emits them. Pure - the /review viewer offers each hit an
 * "edit as whiteboard" hand-off instead of embedding an editor inside the
 * sandboxed artifact iframe (an opaque-origin frame cannot reach the API). */
export function extractMermaidSources(html: string): { source: string; kind: "block" | "fence" }[] {
  const out: { source: string; kind: "block" | "fence" }[] = [];
  const decode = (t: string) =>
    t.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  let kind: "block" | "fence" = "block";
  const push = (t: string) => {
    const src = decode(t).trim();
    if (src) out.push({ source: src, kind });
  };
  const block = /<(?:pre|div)[^>]*class="(?:[^"]*\s)?mermaid(?:\s[^"]*)?"[^>]*>([\s\S]*?)<\/(?:pre|div)>/g;
  const fence = /<code[^>]*class="[^"]*language-mermaid[^"]*"[^>]*>([\s\S]*?)<\/code>/g;
  for (const m of html.matchAll(block)) push(m[1]);
  kind = "fence";
  for (const m of html.matchAll(fence)) push(m[1]);
  return out;
}

/** What the captain is told when the box fallback below actually fired. One
 * copy, interpolated into all three import sites across the two editor pages
 * (the THEME_VARS pattern) - a captain-facing sentence that drifts between
 * pages is how one of them starts lying. */
const BOX_DROPPED_NOTE =
  "WITHOUT its box grouping (the converter cannot pair box with autonumber, or with any alt/loop/opt/par/critical/break block)";

/** Drop `box ... end` participant grouping from a mermaid sequence source;
 * null when there is none to drop.
 *
 * WHY it must be droppable at all: `box` is the ONLY construct that populates
 * the converter's group pass, and that pass walks EVERY already-converted
 * element demanding x/y/width/height, throwing "Element attributes missing
 * [object Object]" on the first one without them (mermaid-to-excalidraw@1.1.2,
 * the groups branch of its sequence converter). autonumber and every block
 * frame - alt/else, loop, opt, par/and, critical, break - each contribute
 * exactly one geometry-less `rectangle` skeleton, so a sequence diagram
 * pairing `box` with any of them cannot convert, while the same diagram
 * without `box` converts fine (measured in a browser on all eight diagrams of
 * the artifact that reported this). `rect`, `Note over` and activation add no
 * such skeleton and stay compatible with `box`.
 *
 * A box block holds only participant declarations and never nests, so the next
 * bare `end` is always its own. Pure, and interpolated into both editor pages
 * via toString(). */
export function mermaidDropParticipantBoxes(src: string): string | null {
  const out: string[] = [];
  let inBox = false;
  let found = false;
  for (const line of src.split("\n")) {
    const t = line.trim();
    if (/^box(\s|$)/.test(t)) { inBox = true; found = true; continue; }
    if (inBox && t === "end") { inBox = false; continue; }
    out.push(line);
  }
  return found ? out.join("\n") : null;
}

/** One mermaid import, with the box fallback the converter's limitation forces
 * (see mermaidDropParticipantBoxes). Retries ONLY after a real failure and
 * only when there is a box to drop, so a diagram that converts as written is
 * never silently altered. Whenever the box turns out NOT to be the cause - no
 * box to drop, or the box-less retry failing too - the caller gets the
 * ORIGINAL error, never one describing a source this function invented.
 * `dropped` is what the caller owes the captain in its status line: the
 * diagram lands, minus its participant grouping, and says so. Interpolated
 * into both editor pages. */
export async function mermaidImportWithFallback(
  parse: (src: string) => Promise<{ elements: any[]; files?: any }>,
  src: string,
): Promise<{ elements: any[]; files?: any; dropped: boolean }> {
  try {
    const r = await parse(src);
    return { elements: r.elements, files: r.files, dropped: false };
  } catch (e) {
    const alt = mermaidDropParticipantBoxes(src);
    if (!alt) throw e;
    let retried;
    try { retried = await parse(alt); } catch { throw e; }
    return { elements: retried.elements, files: retried.files, dropped: true };
  }
}

/** Scene name for an artifact's Nth diagram: derived from the basename,
 * squeezed into isSceneName's grammar so the hand-off URL is always valid. */
export function diagramSceneName(file: string, n: number): string {
  const base = (file.split("/").pop() ?? "artifact")
    .toLowerCase().replace(/\.[a-z0-9]+$/, "").replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "").replace(/-{2,}/g, "-").slice(0, 55) || "artifact";
  return `${base.replace(/^[^a-z0-9]+/, "") || "artifact"}-d${n}`;
}

function whiteboardDir(homePath: string): string {
  // <home>/whiteboards/ - a captain-facing store of its own, NOT under
  // data/: scenes are not task artifacts, and under
  // data/ they leaked into artifact discovery as a phantom "whiteboards"
  // family. Legacy scenes migrate by rename on first touch, idempotently.
  const dir = `${homePath}/whiteboards`;
  const legacy = `${homePath}/data/whiteboards`;
  try {
    for (const f of readdirSync(legacy)) {
      if (!f.endsWith(".excalidraw.json")) continue;
      mkdirSync(dir, { recursive: true });
      try { renameSync(`${legacy}/${f}`, `${dir}/${f}`); } catch { /* exists/raced: keep the new copy */ }
    }
  } catch { /* no legacy dir - nothing to migrate */ }
  return dir;
}

/** Content-addressed version of a scene's on-disk bytes, used as the write
 * precondition (HTTP ETag / If-Match) below. A pure function of the bytes,
 * never a clock: statSync().mtimeMs is float milliseconds, so two writes
 * inside the same millisecond share the SAME mtime and a guard built on it
 * would silently pass a real conflict. A hash makes an identical re-write a
 * no-op match instead of a false conflict, and needs no second GET to prove
 * "is what I hold still current". */
export function sceneEtag(bytes: string): string {
  return new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
}

function whiteboardScenes(homePath: string): { name: string; mtime: number }[] {
  const dir = whiteboardDir(homePath);
  try {
    return readdirSync(dir)
      .filter((f) => f.endsWith(".excalidraw.json"))
      .map((f) => f.slice(0, -".excalidraw.json".length))
      .filter(isSceneName)
      .sort()
      .map((name) => {
        let mtime = 0;
        try { mtime = statSync(`${dir}/${name}.excalidraw.json`).mtimeMs; } catch { /* raced away */ }
        return { name, mtime };
      });
  } catch {
    return []; /* no whiteboards yet */
  }
}

function whiteboardList(homePath: string): Response {
  return json({ scenes: whiteboardScenes(homePath) });
}

function whiteboardRename(homePath: string, scene: string, to: string): Response {
  if (!isSceneName(scene) || !isSceneName(to)) return json({ error: "invalid scene name" }, 400);
  const dir = whiteboardDir(homePath);
  if (existsSync(`${dir}/${to}.excalidraw.json`))
    return json({ error: `scene '${to}' already exists` }, 409);
  try {
    renameSync(`${dir}/${scene}.excalidraw.json`, `${dir}/${to}.excalidraw.json`);
    return json({ ok: true, scene: to });
  } catch (e) {
    return json({ error: String(e) }, 404);
  }
}

function whiteboardDelete(homePath: string, scene: string): Response {
  if (!isSceneName(scene)) return json({ error: "invalid scene name" }, 400);
  try {
    rmSync(`${whiteboardDir(homePath)}/${scene}.excalidraw.json`);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 404);
  }
}

export function whiteboardShow(homePath: string, scene: string): Response {
  if (!isSceneName(scene)) return json({ error: "invalid scene name" }, 400);
  try {
    const text = readFileSync(
      `${whiteboardDir(homePath)}/${scene}.excalidraw.json`,
      "utf8",
    );
    return new Response(text, {
      headers: { "content-type": "application/json", "etag": sceneEtag(text) },
    });
  } catch {
    // A scene that does not exist yet opens as an EMPTY canvas, not an error:
    // creating one is just saving it. No ETag - there is nothing on disk yet
    // to hold a writer to, matching the no-precondition-on-create rule below.
    return json({ type: "excalidraw", version: 2, elements: [], appState: {}, files: {} });
  }
}

/** The Make-presentable RESULT receipt: `<home>/whiteboards/<scene>.redraw.json`,
 * written by the CHIEF when a REDRAW wake's artifact lands (AGENTS.md section
 * 11 owns the obligation) - `{"artifact":"<home-relative path>","at":"<iso>"}`.
 * The whiteboard page polls GET ?redraw=1 and shows the artifact as an
 * open-in-review link, so the captain who clicked LEARNS where the result is
 * without asking. The sibling file is invisible to the scene lister (which
 * filters .excalidraw.json), and it is metadata, not a scene - the If-Match
 * contract does not govern it. `artifact` must be home-relative and
 * traversal-free or the receipt reads as absent (a garbage receipt must not
 * mint a link). */
export function redrawReceipt(homePath: string, scene: string): { artifact: string; at: string } | null {
  if (!isSceneName(scene)) return null;
  try {
    const raw = JSON.parse(readFileSync(`${whiteboardDir(homePath)}/${scene}.redraw.json`, "utf8"));
    const artifact = typeof raw?.artifact === "string" ? raw.artifact : "";
    if (!artifact || artifact.startsWith("/") || artifact.split("/").includes("..")) return null;
    return { artifact, at: typeof raw?.at === "string" ? raw.at : "" };
  } catch {
    return null;
  }
}

/** Atomic-writes ONE normalized scene file, guarded by an If-Match
 * precondition (requirement 1: the writer sends the version it read, the
 * server refuses a stale write and says why). `ifMatch`:
 *  - null/missing on a scene that already exists on disk -> 428: the writer
 *    never read a version at all, which is exactly the shape that caused the
 *    silent-clobber defect.
 *  - "*" -> the ONE force escape hatch (requirement 3), wired only into the
 *    two editor pages' "keep mine" button - documented captain-only, never
 *    advertised to an agent.
 *  - any other value on an existing scene -> must equal sceneEtag(current)
 *    or the write is refused 412.
 *  - a scene that does NOT exist yet needs no precondition at all: creating
 *    is not clobbering.
 * A refusal (428/412) carries {error, version, scene} - version and scene
 * are the CURRENT on-disk state, so the refused caller can merge and re-POST
 * in one round trip with no second GET (requirement 2). A success carries
 * {ok, scene, version} so the caller can hold the new version for its next
 * write without re-reading. */
export function whiteboardWrite(homePath: string, scene: string, body: string, ifMatch: string | null): Response {
  if (!isSceneName(scene)) return json({ error: "invalid scene name" }, 400);
  const normalized = normalizeScene(body);
  if (!normalized) return json({ error: "not an excalidraw scene" }, 400);
  const dir = whiteboardDir(homePath);
  const target = `${dir}/${scene}.excalidraw.json`;
  let current: string | null = null;
  try { current = readFileSync(target, "utf8"); } catch { /* no scene yet - creating needs no precondition */ }
  if (current !== null && ifMatch !== "*") {
    const currentVersion = sceneEtag(current);
    if (ifMatch === null) {
      return json({
        error: "scene already exists and no version was sent - GET it, merge your change into the returned `scene`, and re-POST with If-Match: <version>. Never write without reading first.",
        version: currentVersion,
        scene: current,
      }, 428);
    }
    if (ifMatch !== currentVersion) {
      return json({
        error: "stale write refused - someone else saved this scene since you read it. Merge your change into the returned `scene` and re-POST with If-Match: <version> from this response. Never force (If-Match: *) - that is captain-only.",
        version: currentVersion,
        scene: current,
      }, 412);
    }
  }
  try {
    mkdirSync(dir, { recursive: true });
    const tmp = `${target}.tmp.${process.pid}`;
    const text = JSON.stringify(normalized, null, 2) + "\n";
    writeFileSync(tmp, text);
    renameSync(tmp, target); // atomic replace
    return json({ ok: true, scene, version: sceneEtag(text) });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
}

// ---------------------------------------------------------------------------
// Chief panel (room-chat slice A): watch a chief's live pane from the family
// detail. Read-only in this slice - the pane is CAPTURED (herdr pane read
// --format ansi), never driven. Only chief panes are ever resolved: the
// crewchief and each family's roomchief; crewmate panes are deliberately not
// reachable from the browser.
// ---------------------------------------------------------------------------

/** The roomchief pane id for a family, from state/<family>-chief.meta text:
 * requires kind=roomchief (never a crewmate/verify pane) and parses
 * `window=herdr:<tab>:<pane>`. Null on anything else - the caller renders
 * "no live chief" instead of a stale terminal. */
export function chiefPaneOf(metaText: string): string | null {
  if (!/^kind=roomchief$/m.test(metaText)) return null;
  // window=herdr:pane-<workspace>:<pane> - herdr's CLI wants "<workspace>:<pane>"
  // (verified live: `pane read w1W:pH` reads, `pane read pH` is pane_not_found).
  const m = /^window=herdr:pane-([^:\n]+):([^\s:]+)$/m.exec(metaText);
  return m ? `${m[1]}:${m[2]}` : null;
}

/** Minimal ANSI-SGR -> HTML for the pane view: 16/bright colors, 256-color
 * (38;5/48;5), bold/dim/italic/underline/inverse, reset. Every other escape
 * (cursor moves, OSC titles) is STRIPPED - the capture is a finished frame,
 * not a stream to replay. Text nodes are esc()-escaped, so pane bytes can
 * never become markup. */
export function ansiToHtml(text: string): string {
  // TOKENS, not hex: this runs on the SERVER and cannot know the viewer's theme,
  // so it emits the slot and the page resolves it (ANSI_DARK/ANSI_LIGHT in
  // THEME_VARS). Switching theme therefore recolours pane history already in the
  // DOM, with no re-fetch and no second palette to keep in step.
  const PAL = Array.from({ length: 16 }, (_, i) => `var(--ansi-${i})`);
  const c256 = (n: number): string => {
    if (n < 16) return PAL[n] ?? PAL[7];
    if (n < 232) { // 6x6x6 cube
      const v = (i: number) => (i === 0 ? 0 : 55 + i * 40);
      const i = n - 16;
      return `rgb(${v(Math.floor(i / 36))},${v(Math.floor(i / 6) % 6)},${v(i % 6)})`;
    }
    const g = 8 + (n - 232) * 10;
    return `rgb(${g},${g},${g})`;
  };
  let out = "";
  let open = false;
  const st = { fg: "", bg: "", b: false, d: false, i: false, u: false, inv: false };
  const flush = () => { if (open) { out += "</span>"; open = false; } };
  const apply = () => {
    flush();
    const css: string[] = [];
    let fg = st.fg, bg = st.bg;
    if (st.inv) { const t = fg || "#c9d1d9"; fg = bg || "#0b0f14"; bg = t; }
    if (fg) css.push(`color:${fg}`);
    if (bg) css.push(`background:${bg}`);
    if (st.b) css.push("font-weight:700");
    if (st.d) css.push("opacity:.6");
    if (st.i) css.push("font-style:italic");
    if (st.u) css.push("text-decoration:underline");
    if (css.length) { out += `<span style="${css.join(";")}">`; open = true; }
  };
  // Linkify AFTER escaping, on the escaped text only: http(s) runs become
  // anchors, trailing punctuation/entities stay prose, and no other scheme
  // ever links - pane bytes are untrusted, so the href is always the escaped
  // text itself, never decoded markup.
  const trailRe = /(?:&(?:quot|gt|lt|#39);|[.,;:!?)\]}>'"])+$/;
  const emitText = (raw: string): string =>
    escapeHtml(raw).replace(/https?:\/\/[^\s]+/g, (u0) => {
      let u = u0, trail = "";
      const t = u.match(trailRe);
      if (t) { trail = t[0]; u = u.slice(0, u.length - trail.length); }
      return `<a href="${u}" target="_blank" rel="noopener">${u}</a>${trail}`;
    });
  // Tokenize: SGR sequences we honor, all other ESC sequences dropped.
  const re = /\x1b\[([0-9;]*)m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[\[()][0-9;?]*[A-Za-z]|\x1b./g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out += emitText(text.slice(last, m.index));
    last = m.index + m[0].length;
    if (m[1] === undefined) continue; // non-SGR escape: stripped
    const codes = (m[1] === "" ? "0" : m[1]).split(";").map(Number);
    for (let k = 0; k < codes.length; k++) {
      const n = codes[k];
      if (n === 0) { st.fg = ""; st.bg = ""; st.b = st.d = st.i = st.u = st.inv = false; }
      else if (n === 1) st.b = true;
      else if (n === 2) st.d = true;
      else if (n === 3) st.i = true;
      else if (n === 4) st.u = true;
      else if (n === 7) st.inv = true;
      else if (n === 22) { st.b = false; st.d = false; }
      else if (n === 23) st.i = false;
      else if (n === 24) st.u = false;
      else if (n === 27) st.inv = false;
      else if (n >= 30 && n <= 37) st.fg = PAL[n - 30];
      else if (n === 39) st.fg = "";
      else if (n >= 40 && n <= 47) st.bg = PAL[n - 40];
      else if (n === 49) st.bg = "";
      else if (n >= 90 && n <= 97) st.fg = PAL[n - 90 + 8];
      else if (n >= 100 && n <= 107) st.bg = PAL[n - 100 + 8];
      else if ((n === 38 || n === 48) && codes[k + 1] === 5) {
        const col = c256(codes[k + 2] ?? 7);
        if (n === 38) st.fg = col; else st.bg = col;
        k += 2;
      } else if ((n === 38 || n === 48) && codes[k + 1] === 2) {
        const col = `rgb(${codes[k + 2] ?? 0},${codes[k + 3] ?? 0},${codes[k + 4] ?? 0})`;
        if (n === 38) st.fg = col; else st.bg = col;
        k += 4;
      }
    }
    apply();
  }
  if (last < text.length) out += emitText(text.slice(last));
  flush();
  return out;
}

/** Wake payload for the fleet spool: id derived from the scene's basename
 * (mirrors reviewWakeParts' charset squeeze), payload the scene path plus the
 * captain's message folded to one line. Pure - publishWhiteboardWake shells
 * out to ac_wake_publish (bin/ac-wake-lib.sh), the ONE producer chokepoint,
 * exactly like publishReviewWake does for kind=review. */
export function whiteboardWakeParts(scenePath: string, message: string): { id: string; payload: string } {
  const base = (scenePath.split("/").pop() ?? "scene").toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "scene";
  const folded = `${scenePath} - ${message}`.replace(/[\t\n]+/g, " ").slice(0, 200);
  return { id: "whiteboard-" + base, payload: folded };
}

/** Dedupe key for a Notify-crew click: scene + message + the scene file's
 * mtime (the row's exact spec, not invented here). Pressing the button again
 * on the SAME scene with the SAME message and no new save (mtime unchanged)
 * yields the SAME key, so the caller's Set already holds it -> no second
 * wake. A different message, or a new save (mtime moves), is a different key
 * -> a wake is allowed through. Pure. */
export function whiteboardWakeKey(scenePath: string, message: string, mtime: number): string {
  return JSON.stringify([scenePath, message, mtime]);
}

/** The Make-presentable button's wake message. Same transport as Notify crew
 * (POST ?notify=1 -> ONE deduped kind=whiteboard wake); only the message is
 * fixed, so the chief recognizes the order mechanically and routes it to the
 * diagram-design skill (references/import-excalidraw.md names this REDRAW:
 * prefix as a trigger). The optional note carries the captain's destination
 * or sizing hint; it rides after a dash, folded by whiteboardWakeParts like
 * any other message. Pure. */
export function redrawMessage(note: string): string {
  const base = "REDRAW: make this scene presentable (diagram-design import-excalidraw)";
  const n = note.trim();
  return n ? base + " - " + n : base;
}

const wbWaked = new Set<string>();

function publishWhiteboardWake(homePath: string, scenePath: string, message: string): void {
  const { id, payload } = whiteboardWakeParts(scenePath, message);
  const binDir = new URL("../bin/", import.meta.url).pathname;
  // Same double-keyed test seam as publishReviewWake (audit-f8): an inherited
  // env var alone must never make production exec an arbitrary file.
  const hook = process.env.AC_TEST_HOOKS ? process.env.AC_DASH_WAKE_HOOK : "";
  // Fire-and-forget: a wake that cannot publish must never fail the
  // captain's click.
  Bun.spawn(
    hook
      ? [hook, `${homePath}/state`, id, payload]
      : ["bash", "-c",
         `. "$1/ac-lib.sh" && . "$1/ac-wake-lib.sh" && ac_wake_publish "$2" "" whiteboard "$3" "$4"`,
         "--", binDir, `${homePath}/state`, id, payload],
    { env: { ...process.env, AC_HOME: homePath }, stdout: "ignore", stderr: "ignore" },
  );
}

/** POST ?notify=1: publishes ONE deduped fleet wake of kind `whiteboard`
 * carrying the scene path + the captain's message - the message IS the
 * order, so an empty one is refused instead of silently substituted with a
 * generic "scene updated". The scene path is DERIVED from whiteboardDir(home)
 * + scene, never taken from user input. mtime falls back to 0 when the scene
 * has never been saved yet, the same convention whiteboardScenes already
 * uses for an unreadable stat. Gated on allowedHomePaths (its siblings here
 * do not re-check it per-call, but a call that shells a process out via
 * ac_wake_publish gets the gate regardless - see report.md for the note on
 * that pre-existing gap). */
async function whiteboardNotify(homePath: string, scene: string, body: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath)) return json({ error: "unknown home" }, 404);
  if (!isSceneName(scene)) return json({ error: "invalid scene name" }, 400);
  const message = body.trim();
  if (!message) return json({ error: "message required" }, 400);
  const scenePath = `${whiteboardDir(homePath)}/${scene}.excalidraw.json`;
  let mtime = 0;
  try { mtime = statSync(scenePath).mtimeMs; } catch { /* never saved yet */ }
  const key = whiteboardWakeKey(scenePath, message, mtime);
  if (wbWaked.has(key)) return json({ ok: true, deduped: true });
  wbWaked.add(key);
  publishWhiteboardWake(homePath, scenePath, message);
  return json({ ok: true, deduped: false });
}

/** The standalone editor page. Self-contained: pinned CDN imports, scene
 * loaded from and saved to /api/whiteboard, mermaid paste-to-import via the
 * one-way official converter with regenerateIds:false so imported node ids
 * stay stable across an agent's later reads of the scene. */
function whiteboardPage(): Response {
  const c = WHITEBOARD_CDN;
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>agent-crew whiteboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="${c.excalidrawCss}">
${THEME_INIT}
<style>
${THEME_VARS}
${UX_BASE}
  html,body{margin:0;height:100%;font-family:system-ui,sans-serif}
  body{background:var(--canvas);color:var(--fg)}
  /* Chrome themes with the shared tokens (theme-revamp); the Excalidraw canvas
     itself owns its own look and is left untouched. */
  #bar{display:flex;gap:8px;align-items:center;padding:7px 12px;border-bottom:1px solid var(--border);background:var(--surface);color:var(--fg)}
  #bar .name{font-weight:600;font-size:14px;margin-right:4px}
  #bar button{font:600 12px system-ui;padding:5px 14px;border-radius:6px;border:none;cursor:pointer;background:var(--elev);color:var(--fg);box-shadow:inset 0 0 0 1px var(--border)}
  #bar button:hover{box-shadow:inset 0 0 0 1px var(--border-strong)}
  #bar #save{background:var(--accent);color:var(--accent-ink);box-shadow:none}
  #bar #save:hover{filter:brightness(1.08);box-shadow:none}
  #bar #save:hover{filter:brightness(1.08)}
  #bar #status{color:var(--fg2);font-size:12px}
  #board{height:calc(100% - 45px)}
  #mermaid-panel{display:none;position:absolute;top:50px;right:12px;z-index:10;background:var(--surface);color:var(--fg);border:1px solid var(--border);border-radius:6px;padding:10px;width:380px;box-shadow:0 4px 14px rgba(0,0,0,.15)}
  #mermaid-panel textarea{width:100%;height:160px;font-family:monospace;font-size:12px;background:var(--canvas);color:var(--fg);border:1px solid var(--border);border-radius:4px}
  #notify-panel{display:none;position:absolute;top:50px;left:12px;z-index:10;background:var(--surface);color:var(--fg);border:1px solid var(--border);border-radius:6px;padding:10px;width:320px;box-shadow:0 4px 14px rgba(0,0,0,.15)}
  #notify-panel input{width:100%;font:13px system-ui;padding:5px 7px;box-sizing:border-box;background:var(--canvas);color:var(--fg);border:1px solid var(--border);border-radius:4px}
  #conflict-banner{display:none;align-items:center;gap:12px;padding:9px 14px;background:#b00020;color:#fff;font:600 13px system-ui}
  #conflict-banner button{font:600 12px system-ui;padding:5px 14px;border-radius:6px;border:none;cursor:pointer;background:#fff;color:#b00020}
</style></head><body>
<div id="bar">
  <span class="name" id="scene-name"></span>
  <button id="save">Save</button>
  <button id="mermaid-toggle">Import mermaid</button>
  <button id="notify-toggle">Notify crew</button>
  <button id="redraw-toggle">Make presentable</button>
  <a id="redraw-open" target="_blank" rel="noopener" style="display:none;font:600 12px system-ui;color:var(--fg);background:var(--surface);border:1px solid var(--border);border-radius:6px;padding:5px 10px;text-decoration:none">Open redraw</a>
  <span id="status"></span>
  <button id="embed-close" style="margin-left:auto;display:none">Close</button>
</div>
<div id="conflict-banner">
  <span id="conflict-msg" style="flex:1"></span>
  <button id="conflict-keep-mine">Keep mine</button>
</div>
<div id="mermaid-panel">
  <textarea id="mermaid-src" placeholder="graph TD; A-->B"></textarea>
  <div style="margin-top:6px;display:flex;gap:8px">
    <button id="mermaid-import">Add to canvas</button>
    <span id="mermaid-err" style="color:var(--error);font-size:12px"></span>
  </div>
</div>
<div id="notify-panel">
  <input id="notify-msg" type="text" placeholder="message for the crew (required)">
  <div style="margin-top:6px;display:flex;gap:8px;align-items:center">
    <button id="notify-send">Send</button>
    <span id="notify-err" style="color:#b00;font-size:12px"></span>
  </div>
</div>
<div id="board"></div>
<script>window.EXCALIDRAW_ASSET_PATH = ${JSON.stringify(c.excalidrawAssets)};</script>
<script type="module">
import React from "${c.react}";
import { createRoot } from "${c.reactDomClient}";
import * as EX from "${c.excalidraw}";
${mermaidDropParticipantBoxes.toString()}
${mermaidImportWithFallback.toString()}

const q = new URLSearchParams(location.search);
const home = q.get("path") ?? "";
const scene = q.get("scene") ?? "";
document.getElementById("scene-name").textContent = scene || "(no scene)";
// Embedded in the review overlay: the page carries the ONE header, so it owns
// the Close button too - the host just listens for the message.
if (q.get("embed") === "1") {
  const ec = document.getElementById("embed-close");
  ec.style.display = "";
  ec.addEventListener("click", () => parent.postMessage({ wbo: "close" }, "*"));
}
const status = (t) => { document.getElementById("status").textContent = t; };
if (!home || !scene) {
  status("missing ?path=<home>&scene=<name>");
  throw new Error("missing path/scene");
}
const api = { current: null };
const initialRes = await fetch(
  "/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(scene),
);
let version = initialRes.headers.get("etag"); // held across saves - null for a scene that does not exist yet
const initial = await initialRes.json();

createRoot(document.getElementById("board")).render(
  React.createElement(EX.Excalidraw, {
    initialData: { elements: initial.elements ?? [], appState: initial.appState ?? {}, files: initial.files ?? {} },
    excalidrawAPI: (a) => { api.current = a; },
  }),
);

// Hand-off seeding (dash-whiteboard phase 2): a ?seed=<mermaid> arriving on an
// EMPTY scene auto-imports it - the /review viewer links each detected diagram
// here. A scene that already has elements ignores the seed: the saved edit is
// the truth, re-following the link must not duplicate or clobber it.
const seed = q.get("seed");
if (seed && (initial.elements ?? []).length === 0) {
  (async () => {
    try {
      status("importing seed diagram...");
      const { parseMermaidToExcalidraw } = await import("${c.mermaidToExcalidraw}");
      const { elements, files, dropped } = await mermaidImportWithFallback(parseMermaidToExcalidraw, seed);
      const wait = () => new Promise((r) => api.current ? r() : setTimeout(() => wait().then(r), 200));
      await wait();
      const converted = EX.convertToExcalidrawElements(elements, { regenerateIds: false });
      api.current.updateScene({ elements: converted });
      if (files) api.current.addFiles(Object.values(files));
      // Center the import: without this the seed lands at the canvas origin,
      // under Excalidraw's own top-left menu (seen in the visual smoke test).
      api.current.scrollToContent(converted, { fitToViewport: true, viewportZoomFactor: 0.8 });
      status(dropped ? "seed imported ${BOX_DROPPED_NOTE} - Save to keep it" : "seed imported - Save to keep it");
    } catch (e) { status("seed import failed: " + (e && e.message ? e.message : e)); }
  })();
}

// Conflict banner (requirement 3): a refusal never reloads the canvas and
// never silently discards the captain's drawing - it stays exactly where it
// was, in the browser, until the captain acts. "Keep mine" is the ONLY other
// button - the banner's own text names the other way out (reload, which
// discards what is on screen), so a second button would buy nothing.
function showConflict(msg) {
  document.getElementById("conflict-msg").textContent = msg;
  document.getElementById("conflict-banner").style.display = "flex";
}
function hideConflict() {
  document.getElementById("conflict-banner").style.display = "none";
}
async function save(force) {
  if (!api.current) return;
  const body = JSON.stringify({
    elements: api.current.getSceneElements(),
    appState: api.current.getAppState(),
    files: api.current.getFiles(),
  });
  const headers = force ? { "if-match": "*" } : (version ? { "if-match": version } : {});
  const res = await fetch(
    "/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(scene),
    { method: "POST", body, headers },
  );
  if (res.status === 428 || res.status === 412) {
    const data = await res.json().catch(() => ({}));
    version = data.version ?? version; // resync so a future normal save has a fighting chance
    status("save FAILED - conflict");
    showConflict("Someone else saved this scene since you last read it. Your drawing is still here - click Keep mine to overwrite theirs, or reload this page to see their version instead (that discards yours).");
    return;
  }
  if (!res.ok) { status("save FAILED"); return; }
  const data = await res.json();
  version = data.version ?? version;
  hideConflict();
  status("saved " + new Date().toLocaleTimeString());
}
document.getElementById("save").addEventListener("click", () => save(false));
document.getElementById("conflict-keep-mine").addEventListener("click", () => save(true));
addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "s") { e.preventDefault(); save(false); }
});

document.getElementById("mermaid-toggle").addEventListener("click", () => {
  const p = document.getElementById("mermaid-panel");
  p.style.display = p.style.display === "block" ? "none" : "block";
});
document.getElementById("mermaid-import").addEventListener("click", async () => {
  const err = document.getElementById("mermaid-err");
  err.textContent = "";
  try {
    const { parseMermaidToExcalidraw } = await import("${c.mermaidToExcalidraw}");
    const src = document.getElementById("mermaid-src").value;
    const { elements, files, dropped } = await mermaidImportWithFallback(parseMermaidToExcalidraw, src);
    // regenerateIds:false keeps imported node ids stable, so an agent reading
    // the saved scene later can still correlate nodes across edits.
    const converted = EX.convertToExcalidrawElements(elements, { regenerateIds: false });
    api.current.updateScene({ elements: [...api.current.getSceneElements(), ...converted] });
    if (files) api.current.addFiles(Object.values(files));
    document.getElementById("mermaid-panel").style.display = "none";
    if (dropped) status("imported ${BOX_DROPPED_NOTE}");
  } catch (e) { err.textContent = e && e.message ? e.message : String(e); }
});

document.getElementById("notify-toggle").addEventListener("click", () => {
  const p = document.getElementById("notify-panel");
  p.style.display = p.style.display === "block" ? "none" : "block";
});
${redrawMessage.toString()}
let redrawSeenAt = null, redrawTimer = null;
async function pollRedraw() {
  try {
    const r = await fetch("/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(scene) + "&redraw=1");
    if (!r.ok) return;
    const rec = await r.json();
    if (!rec || !rec.artifact) return;
    const a = document.getElementById("redraw-open");
    a.href = "/review?path=" + encodeURIComponent(home) + "&file=" + encodeURIComponent(home + "/" + rec.artifact);
    a.style.display = "inline-block";
    if (redrawSeenAt !== null && rec.at !== redrawSeenAt) {
      status("redraw ready");
      if (redrawTimer) { clearInterval(redrawTimer); redrawTimer = null; }
    }
    redrawSeenAt = rec.at;
  } catch { /* transient - next poll retries */ }
}
pollRedraw();
document.getElementById("redraw-toggle").addEventListener("click", async () => {
  const res = await fetch(
    "/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(scene) + "&notify=1",
    { method: "POST", body: redrawMessage("") },
  );
  if (!res.ok) { status("redraw request failed"); return; }
  const data = await res.json();
  status(data.deduped ? "already requested (no new save)" : "redraw requested");
  if (!redrawTimer) redrawTimer = setInterval(pollRedraw, 8000);
});
document.getElementById("notify-send").addEventListener("click", async () => {
  const err = document.getElementById("notify-err");
  err.textContent = "";
  const msg = document.getElementById("notify-msg").value.trim();
  if (!msg) { err.textContent = "message required"; return; }
  const res = await fetch(
    "/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(scene) + "&notify=1",
    { method: "POST", body: msg },
  );
  if (!res.ok) { err.textContent = "notify failed"; return; }
  const data = await res.json();
  err.textContent = data.deduped ? "already notified (no new save)" : "notified";
  document.getElementById("notify-msg").value = "";
});
</script></body></html>`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

/**
 * The whiteboard-frame's dirty-check: a cheap content signature of the
 * scene, deliberately built from `elements` alone. Excalidraw's onChange
 * fires for pure view actions too (pan/zoom/selection/cursor), but every one
 * of those lives in `appState`, never in `elements` - so signing elements
 * alone already excludes them, with no field-by-field appState filtering
 * needed. Pure, and its body carries no template literal or backslash: the
 * frame page interpolates its toString() the same way PAGE does for
 * groupArtifacts et al (repo-knowledge `dashboard-verifier-kind-hardcode`),
 * so the bun test proves the byte-same code the browser runs.
 */
export function wbfSceneSignature(elements: any[]): string {
  return JSON.stringify(elements || []);
}

/**
 * The whiteboard-frame's one save-or-not decision, shared by the idle
 * debounce, the Save button, and Ctrl/Cmd-S - "one surface, one
 * authoritative implementation" (the row's guardrail). A save already in
 * flight always wins first (never double-fire, forced or not). Otherwise a
 * forced trigger (a click or a keyboard shortcut) always proceeds, matching
 * the Save button's pre-existing unconditional behavior; an idle-triggered
 * autosave (force falsy) proceeds only when the live signature actually
 * differs from the last CONFIRMED save - the caller advances
 * lastSavedSignature only on a wbf:"saved" ack with ok:true, so a failed
 * save leaves the baseline behind and the same signature still reads dirty
 * on the next check. Pure.
 */
export function wbfShouldSave(state: { signature: string; lastSavedSignature: string; saving: boolean; force?: boolean }): boolean {
  if (state.saving) return false;
  if (state.force) return true;
  return state.signature !== state.lastSavedSignature;
}

/** The BRIDGE editor: this page is loaded inside the
 * sandboxed artifact frame, where the inherited sandbox makes it an opaque
 * origin - so it holds NO server access at all. It announces itself to
 * window.top ({wbf:"ready"}), receives its scene over postMessage, and saves
 * by sending the payload up; the review page is the chrome that owns the
 * API. Scripts and CDN loads work fine under allow-scripts - only
 * same-origin fetch is what the sandbox denies, and this page never tries. */
function whiteboardFramePage(): Response {
  const c = WHITEBOARD_CDN;
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>whiteboard frame</title>
<link rel="stylesheet" href="${c.excalidrawCss}">
${THEME_INIT}
<style>
${THEME_VARS}
${UX_BASE}
  html,body{margin:0;height:100%;background:var(--canvas);font-family:system-ui,sans-serif}
  #bar{display:flex;gap:8px;align-items:center;padding:5px 10px;background:var(--surface);border-bottom:1px solid var(--border)}
  #bar .nm{color:var(--fg);font:600 12px system-ui}
  #bar button{font:600 12px system-ui;padding:4px 12px;border-radius:6px;border:none;background:var(--accent);color:var(--accent-ink);cursor:pointer}
  #status{color:var(--fg2);font-size:11px;margin-left:auto}
  #board{height:calc(100% - 34px)}
  #wbf-conflict{display:none;align-items:center;gap:8px;padding:6px 10px;background:#b00020;color:#fff;font:600 11px system-ui}
  #wbf-conflict button{font:600 11px system-ui;padding:4px 10px;border-radius:6px;border:none;cursor:pointer;background:#fff;color:#b00020}
</style></head><body>
<div id="bar"><span class="nm" id="nm"></span><button id="save">Save</button><span id="status">connecting...</span></div>
<div id="wbf-conflict"><span id="wbf-conflict-msg" style="flex:1"></span><button id="wbf-keep-mine">Keep mine</button></div>
<div id="board"></div>
<script>window.EXCALIDRAW_ASSET_PATH = ${JSON.stringify(c.excalidrawAssets)};</script>
<script>
// Classic bootstrap, runs BEFORE any CDN byte arrives: announce ready and
// buffer the parent's init so a slow editor load never reads as a dead
// bridge ("connecting..." forever was exactly that - captain screenshot).
window.__wbfInit = null;
window.__wbfStatus = function (t) { document.getElementById("status").textContent = t; };
const __wbfScene = new URLSearchParams(location.search).get("scene") ?? "";
addEventListener("message", (e) => {
  const d = e.data || {};
  if (d.scene && d.scene !== __wbfScene) return; // sibling editor's traffic
  if (d.wbf === "init" && !window.__wbfInit) { window.__wbfInit = d.data || {}; window.__wbfVersion = d.version || null; window.__wbfStatus("scene received - loading editor..."); if (window.__wbfBoot) window.__wbfBoot(); }
  if (d.wbf === "saved") window.__wbfStatus(d.ok ? "saved " + new Date().toLocaleTimeString() : "save FAILED: " + (d.error ?? ""));
});
parent.postMessage({ wbf: "ready", scene: new URLSearchParams(location.search).get("scene") ?? "" }, "*");
window.__wbfStatus("loading editor from CDN...");
setTimeout(() => { if (!window.__wbfReady) window.__wbfStatus("still loading the editor - CDN needs network; check the connection if this persists"); }, 15000);
</script>
<script type="module">
const q = new URLSearchParams(location.search);
const scene = q.get("scene") ?? "", seed = q.get("seed") ?? "";
document.getElementById("nm").textContent = scene;
const status = window.__wbfStatus;
const api = { current: null };
let EX, React, createRoot;
${wbfSceneSignature.toString()}
${wbfShouldSave.toString()}
${mermaidDropParticipantBoxes.toString()}
${mermaidImportWithFallback.toString()}
// Autosave state (dash-review-polish slice 1): one save path funnels the
// idle debounce, the Save button and Ctrl/Cmd-S through doSave() so there is
// exactly one authoritative save implementation, per the row's guardrail.
const AUTOSAVE_IDLE_MS = 1500; // long enough that normal typing/dragging never fires mid-edit, short enough the captain never wonders if it saved
let saving = false;
let lastSavedSig = wbfSceneSignature([]);
let pendingSig = null;
let idleTimer = null;
let seeding = false; // true while a mermaid seed import is landing - see the seed block below
let version = null; // ETag of the scene bytes this frame last held as current
let conflicted = false; // true after a refusal - stops the autosave loop from hammering a write it will never win
function scheduleAutosave() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = setTimeout(() => doSave(false), AUTOSAVE_IDLE_MS);
}
// force: skip the dirty check (pre-existing - the Save button and Ctrl/Cmd-S
// always attempt a save even when nothing changed). overwrite: skip the
// version precondition entirely - the captain's "Keep mine" button ONLY, a
// distinct concept from force (a plain manual Save must still be refused if
// stale, that is the whole point of the fix).
function doSave(force, overwrite) {
  if (!api.current) return;
  if (conflicted && !overwrite) return; // stop hammering a write that will never win until the captain acts
  const els = api.current.getSceneElements();
  const sig = wbfSceneSignature(els);
  if (!wbfShouldSave({ signature: sig, lastSavedSignature: lastSavedSig, saving, force: !!force })) return;
  if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
  saving = true;
  pendingSig = sig;
  status("saving...");
  parent.postMessage({ wbf: "save", scene, version, overwrite: !!overwrite, payload: {
    elements: els,
    appState: api.current.getAppState(),
    files: api.current.getFiles(),
  } }, "*");
}
function onEditorChange(elements) {
  if (!api.current || seeding) return;
  const sig = wbfSceneSignature(elements);
  if (sig === lastSavedSig) return; // pure view action (pan/zoom/selection/cursor) - not a real change
  status("unsaved changes");
  scheduleAutosave();
}
// Ctrl/Cmd-S: the keydown fires in THIS document (the frame), so the parent
// never sees it - own the handler here, capture phase so it runs even if
// Excalidraw binds its own listener, and bypass the debounce entirely.
addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === "s") {
    e.preventDefault();
    doSave(true);
  }
}, true);
addEventListener("message", (e) => {
  const d = e.data || {};
  if (d.scene && d.scene !== scene) return;
  if (d.wbf !== "saved") return;
  saving = false;
  if (d.conflict) {
    conflicted = true;
    if (d.version) version = d.version; // resync so "Keep mine" has a fighting chance
    status("CONFLICT: someone else changed this scene");
    document.getElementById("wbf-conflict-msg").textContent =
      "Someone else changed this scene. Your edits are still here on screen - click Keep mine to overwrite theirs, or reload this page to see their version instead (that discards yours).";
    document.getElementById("wbf-conflict").style.display = "flex";
    return; // do not scheduleAutosave - the debounce would just get refused again
  }
  conflicted = false;
  document.getElementById("wbf-conflict").style.display = "none";
  if (d.ok) { lastSavedSig = pendingSig; if (d.version) version = d.version; }
  if (api.current && wbfSceneSignature(api.current.getSceneElements()) !== lastSavedSig) {
    status("unsaved changes");
    scheduleAutosave();
  }
});
// Queue-feedback snapshot (dash-review-polish slice 3): a separate message
// kind, never a second save path - taking a snapshot never touches
// lastSavedSig/idleTimer and never writes the scene. Chunked base64 avoids
// blowing the call stack on String.fromCharCode for a large PNG.
function wbfBufToBase64(buf) {
  const bytes = new Uint8Array(buf);
  let binary = "";
  const chunk = 32768;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
addEventListener("message", (e) => {
  const d = e.data || {};
  if (d.scene && d.scene !== scene) return;
  if (d.wbf !== "snapshot") return;
  if (!api.current || !EX || !EX.exportToBlob) {
    parent.postMessage({ wbf: "snapshotResult", scene, ok: false }, "*");
    return;
  }
  EX.exportToBlob({
    elements: api.current.getSceneElements(),
    appState: api.current.getAppState(),
    files: api.current.getFiles(),
    mimeType: "image/png",
  }).then((blob) => blob.arrayBuffer()).then((buf) => {
    parent.postMessage({ wbf: "snapshotResult", scene, ok: true, data: wbfBufToBase64(buf) }, "*");
  }).catch(() => {
    parent.postMessage({ wbf: "snapshotResult", scene, ok: false }, "*");
  });
});
try {
  React = (await import("${c.react}")).default;
  ({ createRoot } = await import("${c.reactDomClient}"));
  EX = await import("${c.excalidraw}");
} catch (err) {
  status("editor failed to load from CDN: " + err);
  throw err;
}
window.__wbfReady = true;
async function boot() {
  const data = window.__wbfInit;
  if (!data) { status("waiting for the scene from the review page..."); return; }
  version = window.__wbfVersion || null;
  lastSavedSig = wbfSceneSignature(data.elements ?? []);
  createRoot(document.getElementById("board")).render(
    React.createElement(EX.Excalidraw, {
      initialData: { elements: data.elements ?? [], appState: data.appState ?? {}, files: data.files ?? {} },
      excalidrawAPI: (a) => { api.current = a; },
      onChange: onEditorChange,
    }),
  );
  status("");
  if (seed && (data.elements ?? []).length === 0) {
    seeding = true;
    try {
      // The converter measures SVG in the render tree: importing while this
      // iframe is display:none (Diagram view is the default) throws "svg
      // element not in render tree". Wait for first visibility instead.
      if (!document.body.offsetWidth) {
        status("seed ready - waiting for the editor view...");
        await new Promise((r) => { const t = () => (document.body.offsetWidth ? r() : setTimeout(t, 300)); t(); });
      }
      status("importing seed...");
      const { parseMermaidToExcalidraw } = await import("${c.mermaidToExcalidraw}");
      const { elements, files, dropped } = await mermaidImportWithFallback(parseMermaidToExcalidraw, seed);
      const wait = () => new Promise((r) => api.current ? r() : setTimeout(() => wait().then(r), 200));
      await wait();
      const conv = EX.convertToExcalidrawElements(elements, { regenerateIds: false });
      api.current.updateScene({ elements: conv });
      if (files) api.current.addFiles(Object.values(files));
      api.current.scrollToContent(conv, { fitToViewport: true, viewportZoomFactor: 0.8 });
      // A machine-generated seed is not a captain edit (autosave is scoped to
      // the captain's own edits) - treat it as the clean baseline so it is
      // never auto-written, matching this status line's pre-existing
      // "Save to keep it" contract. The seeding flag also blocks
      // onEditorChange for the duration above in case updateScene/addFiles/
      // scrollToContent fire onChange synchronously; the baseline reset
      // below covers a fire that lands asynchronously after this line too,
      // since it will find the live scene already matching lastSavedSig.
      if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
      lastSavedSig = wbfSceneSignature(api.current.getSceneElements());
      status(dropped ? "seed imported ${BOX_DROPPED_NOTE} - Save to keep it" : "seed imported - Save to keep it");
    } catch (err) { status("seed import failed: " + (err && err.message ? err.message : err)); } finally { seeding = false; }
  }
}
window.__wbfBoot = boot;
boot();
document.getElementById("save").addEventListener("click", () => { doSave(true); });
document.getElementById("wbf-keep-mine").addEventListener("click", () => { doSave(true, true); });
</script></body></html>`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

// ---------------------------------------------------------------------------
// Review (dash-review: the native annotate loop, spec data/dash-review/spec)
// ---------------------------------------------------------------------------
// The captain opens an artifact at GET /review?path&file (own page, like
// /whiteboard, themed to the SPA palette), pins comments to elements through
// an overlay injected into the render iframe, and talks to the working agent
// in a chat pane (general comments and agent replies, one thread); the agent
// receives everything over a BLOCKING poll, replies, and ends the session -
// the review verb set (open / poll / reply / end / --reopen), served
// natively. The viewer auto-reloads when the artifact's mtime moves (the
// session endpoint carries it), re-checks every pinned anchor after a reload
// and badges it moved/missing - stale, never lost - and a click on a pinned
// note scrolls-and-flashes its element in the frame. Sessions are file-backed and
// atomic-written, so they survive a dashboard restart; a human-ended session
// refuses a plain reopen. Anchors are {selector, fingerprint} - after the
// agent edits the HTML a moved anchor re-attaches by fingerprint or renders
// STALE in the panel, never lost. The pure gates below (reviewApply,
// pollSlice, normalizeAnnotation, reviewSessionRel) are exported + bun-tested;
// the routes around them are thin IO like every other write surface here.

export interface ReviewAnnotation {
  n: number;
  at: string;
  anchor: { selector: string; fingerprint: string; line?: number | null } | null;
  text: string;
  /** Absolute path to a PNG snapshot of the edited scene, when queue-feedback
   * captured one (dash-review-polish slice 3). Set only when the scene was
   * actually saved to disk - see resolveAnnotationSnapshot. */
  image?: string;
  /** Author when NOT the captain: the share listener stamps the guest's
   * given name ("guest" when anonymous) on every annotation a token link
   * delivers, so the crew and the captain can tell whose feedback each
   * record is. Absent = the captain (every pre-share record, and everything
   * from the local page). */
  by?: string;
  /** MODERATION (guest feedback reaches the crew only after the captain
   * approves it): a by-carrying record is born PENDING - pollSlice
   * never delivers it, so the crew structurally cannot read unapproved
   * guest feedback. The captain's Approve re-seqs it into the stream
   * (approved: true + a fresh n so the agent's cursor cannot have passed
   * it); Dismiss keeps the record but retires it forever. Captain records
   * carry neither flag. */
  approved?: boolean;
  dismissed?: boolean;
}
export interface ReviewSession {
  artifact: string;
  state: "open" | "ended";
  endedBy?: "human" | "agent";
  seq: number;
  queue: ReviewAnnotation[];
  replies: { at: string; text: string }[];
  /** Live share token (REVIEW SHARE below): its presence IS the share - the
   * guest listener resolves tokens against this field, so dropping it (Stop,
   * or end) revokes the link durably. Never returned to a guest.
   * pw: optional HTTP Basic gate (salted sha256, never plaintext) - with it
   * set, a leaked URL alone no longer opens the review. */
  share?: { token: string; at: string; pw?: { salt: string; hash: string } };
}

export function emptyReviewSession(artifact: string): ReviewSession {
  return { artifact, state: "open", seq: 0, queue: [], replies: [] };
}

/** Validate one incoming annotation body from the viewer: text required,
 * anchor optional but well-shaped when present. The one gate body->store.
 * scene/snapshot are optional (dash-review-polish slice 3 queue-feedback):
 * scene names the diagram's whiteboard scene, snapshot is raw base64 PNG
 * bytes the frame captured - neither is trusted yet, only carried through to
 * the route handler, which is the one place that can check the scene file on
 * disk (see resolveAnnotationSnapshot). */
export function normalizeAnnotation(
  text: string,
): { anchor: ReviewAnnotation["anchor"]; text: string; scene?: string; snapshot?: string } | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof raw !== "object" || raw === null) return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.text !== "string" || o.text.trim() === "") return null;
  let anchor: ReviewAnnotation["anchor"] = null;
  if (typeof o.anchor === "object" && o.anchor !== null) {
    const a = o.anchor as Record<string, unknown>;
    if (typeof a.selector !== "string" || typeof a.fingerprint !== "string") return null;
    anchor = { selector: a.selector, fingerprint: a.fingerprint.slice(0, 80) };
    if (typeof a.line === "number" && Number.isFinite(a.line) && a.line > 0) anchor.line = Math.floor(a.line);
    // Range mode (two-mode commenting): a text-selection pin carries the
    // selected QUOTE plus its immediate context; the element selector stays
    // as the fallback anchor. All three are display/re-anchor data - capped,
    // optional, and absent on element pins.
    if (typeof a.quote === "string" && a.quote.trim()) {
      anchor.quote = a.quote.slice(0, 200);
      if (typeof a.prefix === "string") anchor.prefix = a.prefix.slice(0, 64);
      if (typeof a.suffix === "string") anchor.suffix = a.suffix.slice(0, 64);
    }
  }
  const scene = typeof o.scene === "string" && o.scene ? o.scene : undefined;
  const snapshot = typeof o.snapshot === "string" && o.snapshot ? o.snapshot : undefined;
  return { anchor, text: o.text.trim(), scene, snapshot };
}

export type ReviewAction =
  | { type: "annotate"; anchor: ReviewAnnotation["anchor"]; text: string; at: string; image?: string; by?: string }
  | { type: "reply"; text: string; at: string }
  | { type: "end"; by: "human" | "agent" }
  | { type: "reopen"; force: boolean }
  | { type: "share"; token: string; at: string; pw?: { salt: string; hash: string } }
  | { type: "unshare" }
  | { type: "approve"; n: number }
  | { type: "dismiss"; n: number };

/** The PNG signature (89 50 4E 47 0D 0A 1A 0A) every accepted snapshot must
 * start with - a cheap defense against a client sending non-image bytes
 * under the image field. */
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Decode a queue-feedback snapshot's base64 payload, rejecting anything
 * that does not start with a real PNG signature. */
export function decodePngSnapshot(base64: string): Buffer | null {
  if (!base64) return null;
  const buf = Buffer.from(base64, "base64");
  if (buf.length < PNG_MAGIC.length || !buf.subarray(0, PNG_MAGIC.length).equals(PNG_MAGIC)) return null;
  return buf;
}

/** Same root the session file already uses (`${id}.session.json`), numbered
 * by the reducer-assigned seq so the client never chooses the output name. */
export function reviewSnapshotPath(id: string, n: number): string {
  return `${id}.review-${n}.png`;
}

/** The one decision of "WHEN is there an image" (dash-review-polish slice 3):
 * a snapshot is only ever attached when the scene was actually saved to disk
 * (sceneFileExists - proven by the caller stat-ing the scene file under
 * whiteboards/, never by trusting the client's claim) AND the client handed
 * over bytes that decode to a real PNG. An embedded-but-never-saved editor
 * (seed import only, or opened-and-untouched) has no scene file, so this
 * returns null even if the client sent bytes - no junk image, no dead path. */
export function resolveAnnotationSnapshot(
  id: string,
  seq: number,
  sceneFileExists: boolean,
  snapshotBase64: string | undefined,
  sessionEnded: boolean,
): { path: string; buffer: Buffer } | null {
  // reviewApply's own annotate case refuses an ended session (409) - writing
  // the PNG before that check would leave an orphan file no record ever
  // points to, so the ended-check lives HERE, in the same one decision of
  // "when is there an image", not as a separate guard in the route.
  if (sessionEnded || !sceneFileExists || !snapshotBase64) return null;
  const buffer = decodePngSnapshot(snapshotBase64);
  if (!buffer) return null;
  return { path: reviewSnapshotPath(id, seq + 1), buffer };
}

/** The session reducer - every mutation goes through here. Returns the next
 * session, or a string refusal (the caller turns it into a 409). The one
 * rule with teeth: a HUMAN-ended session refuses a plain reopen; --reopen
 * (force) is the deliberate override, agent-ended sessions reopen freely. */
export function reviewApply(
  s: ReviewSession,
  action: ReviewAction,
): ReviewSession | string {
  switch (action.type) {
    case "annotate": {
      if (s.state === "ended") return "session ended - reopen it first";
      const n = s.seq + 1;
      const rec: ReviewAnnotation = { n, at: action.at, anchor: action.anchor, text: action.text };
      if (action.image) rec.image = action.image;
      if (action.by) rec.by = action.by;
      return { ...s, seq: n, queue: [...s.queue, rec] };
    }
    case "reply":
      if (s.state === "ended") return "session ended - reopen it first";
      return { ...s, replies: [...s.replies, { at: action.at, text: action.text }] };
    case "end":
      // The share token dies WITH the session: an ended review must never
      // stay reachable through an old link, and reopen does not resurrect it
      // (re-sharing is a fresh deliberate act minting a fresh token).
      return { ...s, state: "ended", endedBy: action.by, share: undefined };
    case "reopen":
      if (s.state === "open") return s;
      if (s.endedBy === "human" && !action.force)
        return "the human ended this session - reopen deliberately (--reopen)";
      return { ...s, state: "open", endedBy: undefined };
    case "share":
      if (s.state === "ended") return "session ended - reopen it first";
      return { ...s, share: { token: action.token, at: action.at, ...(action.pw ? { pw: action.pw } : {}) } };
    case "unshare":
      return { ...s, share: undefined };
    case "approve": {
      // Approve = the captain turns ONE pending guest record into work: it
      // takes a FRESH n (seq+1) so an agent whose poll cursor already passed
      // the original number still receives it, and approved: true is what
      // pollSlice keys delivery on. Only a pending by-record qualifies -
      // approving a captain record, a dismissed one, or one already
      // approved is a caller error, refused.
      if (s.state === "ended") return "session ended - reopen it first";
      const i = s.queue.findIndex((a) => a.n === action.n);
      if (i < 0) return `no annotation #${action.n}`;
      const rec = s.queue[i];
      if (!rec.by || rec.approved || rec.dismissed) return `annotation #${action.n} is not pending guest feedback`;
      const n = s.seq + 1;
      const queue = [...s.queue];
      queue[i] = { ...rec, n, approved: true };
      return { ...s, seq: n, queue };
    }
    case "dismiss": {
      if (s.state === "ended") return "session ended - reopen it first";
      const i = s.queue.findIndex((a) => a.n === action.n);
      if (i < 0) return `no annotation #${action.n}`;
      const rec = s.queue[i];
      if (!rec.by || rec.approved || rec.dismissed) return `annotation #${action.n} is not pending guest feedback`;
      const queue = [...s.queue];
      queue[i] = { ...rec, dismissed: true };
      return { ...s, queue };
    }
  }
}

/** Annotations newer than the poll cursor, plus the state the agent acts on.
 * THE MODERATION WALL (wire-enforced, not prose): a by-carrying record is
 * delivered ONLY once the captain approved it - every consumer of guest
 * feedback goes through this one slice, so an agent structurally cannot
 * read a pending or dismissed guest record, whatever its prompt says.
 * `pending` is the COUNT of withheld guest records (never their content):
 * without it an empty poll LIES to an agent that knows a guest is reviewing,
 * and the live incident answer to that lie was reading the session file
 * directly - the number gives the agent the truth ("N items await the
 * captain") with nothing to act on and no reason to bypass. */
export function pollSlice(
  s: ReviewSession,
  after: number,
): { state: ReviewSession["state"]; items: ReviewAnnotation[]; pending: number } {
  return {
    state: s.state,
    items: s.queue.filter((a) => a.n > after && (!a.by || a.approved === true)),
    pending: s.queue.filter((a) => a.by && !a.approved && !a.dismissed).length,
  };
}

/** Sessions are keyed by the ARTIFACT FILE and stored beside it as
 * <file>.session.json - discovery-independent, found by agent and chief next
 * to the artifact, valid for data/ artifacts and pooled .lavish/ pages alike.
 * reviewTarget is the one gate: same realpath + artifact-root validation the
 * render route uses, so a session can never be written outside a home's
 * artifact roots. */
function reviewTarget(homePath: string, file: string): string | null {
  let real: string;
  try {
    real = realpathSync(file);
  } catch {
    return null;
  }
  return underArtifactRoot(homePath, real) ? real : null;
}

function reviewLoad(homePath: string, id: string): ReviewSession {
  try {
    const s = JSON.parse(readFileSync(`${id}.session.json`, "utf8"));
    if (s && Array.isArray(s.queue) && typeof s.seq === "number") return s as ReviewSession;
  } catch {
    /* fresh session */
  }
  return emptyReviewSession(id);
}

function reviewSave(homePath: string, id: string, s: ReviewSession): void {
  const target = `${id}.session.json`;
  const tmp = `${target}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(s, null, 2) + "\n");
  renameSync(tmp, target); // atomic replace
}

function reviewMutate(homePath: string, id: string, action: ReviewAction): Response {
  const next = reviewApply(reviewLoad(homePath, id), action);
  if (typeof next === "string") return json({ error: next }, 409);
  try {
    reviewSave(homePath, id, next);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
  return json({ ok: true, seq: next.seq, state: next.state });
}

/** BLOCKING long-poll: hold up to 25s for an annotation newer than `after`
 * (or an ended state), then answer with whatever exists - an empty items
 * array tells the shim to re-poll. 1s file re-reads, not watchers: the
 * session is atomic-replaced so a read never sees a half write. */
async function reviewPoll(homePath: string, id: string, after: number): Promise<Response> {
  reviewWaked.delete(id);
  reviewPollers.set(id, (reviewPollers.get(id) ?? 0) + 1);
  try {
    return await reviewPollHold(homePath, id, after);
  } finally {
    const n = (reviewPollers.get(id) ?? 1) - 1;
    if (n <= 0) reviewPollers.delete(id); else reviewPollers.set(id, n);
  }
}

async function reviewPollHold(homePath: string, id: string, after: number): Promise<Response> {
  for (let i = 0; i < 25; i++) {
    const s = reviewLoad(homePath, id);
    const slice = pollSlice(s, after);
    if (slice.items.length > 0 || slice.state === "ended") return json(slice);
    await new Promise((r) => setTimeout(r, 1000));
  }
  return json(pollSlice(reviewLoad(homePath, id), after));
}

/** Wake payload for the fleet spool: id is the artifact basename squeezed to
 * the record charset, payload one folded line. Pure - the publisher shells
 * out to ac_wake_publish (bin/ac-wake-lib.sh), the ONE producer chokepoint,
 * so the dashboard never re-implements the spool grammar. */
export function reviewWakeParts(file: string, text: string): { id: string; payload: string } {
  const base = (file.split("/").pop() ?? "artifact").toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "artifact";
  return { id: "review-" + base, payload: text.replace(/[\t\n]+/g, " ").slice(0, 160) };
}

/** The wake TEXT itself (captain-hold-has-no-machine-representation-wake W1):
 * names the LEGAL channel, `bin/ac-review.sh poll <file>`, and never the
 * session file. Naming `<file>.session.json` here taught every agent in
 * every fleet to walk around the moderation wall pollSlice enforces - a
 * pending/dismissed guest record never reaches the poll no matter what the
 * wake says, but a wake IS a prompt, and a prompt pointing at storage is the
 * bypass written down in the tooling itself. */
export function reviewWakeText(file: string, payload: string): string {
  return `${payload} - captain feedback on ${file} (dashboard review; run: bin/ac-review.sh poll ${file})`;
}

/** The family a review artifact belongs to: <home>/data/<family>/... names the
 * family whose spool should get the wake when that family is promoted (its
 * roomchief drains state/.wake-spool.<family>/ - routing straight there skips
 * the crewchief-forward hop AGENTS.md section 8 would otherwise require).
 * Pooled .lavish worktree pages and anything outside data/ have no family.
 * Archived families (data/archive/<fam>) return null: a closed family has no
 * roomchief, so its feedback belongs to the fleet chief. */
export function reviewWakeFamily(homePath: string, file: string): string | null {
  const prefix = `${homePath}/data/`;
  if (!file.startsWith(prefix)) return null;
  const seg = file.slice(prefix.length).split("/")[0] ?? "";
  if (!seg || seg === "archive") return null;
  return /^[a-zA-Z0-9_-]+$/.test(seg) ? seg : null;
}

// Live long-polls per artifact file and the dedupe set for published wakes.
// A message that lands while a poller holds the line needs NO wake (the poll
// delivers it); with nobody listening the FIRST message publishes ONE wake -
// to the owning roomchief's family spool when the artifact's family is
// promoted, else to the fleet - and further ones stay quiet until a poller
// shows up again.
const reviewPollers = new Map<string, number>();
const reviewWaked = new Set<string>();

/** Counts a session file's captain-facing shape - pins are anchored queue
 * items, messages the unanchored ones plus every agent reply. Tolerant of a
 * malformed file: anything non-array counts zero, an unknown state reads as
 * open (matching reviewLoad's normalization direction). */
export function reviewSessionSummary(s: unknown): {
  state: "open" | "ended";
  endedBy?: string;
  pins: number;
  messages: number;
  shared: boolean;
} {
  const o = (s ?? {}) as Record<string, unknown>;
  const q = Array.isArray(o.queue) ? o.queue : [];
  const r = Array.isArray(o.replies) ? o.replies : [];
  const share = (o.share ?? null) as { token?: unknown } | null;
  return {
    state: o.state === "ended" ? "ended" : "open",
    endedBy: o.state === "ended" && typeof o.endedBy === "string" ? o.endedBy : undefined,
    pins: q.filter((a) => a && (a as Record<string, unknown>).anchor).length,
    messages: q.filter((a) => a && !(a as Record<string, unknown>).anchor).length + r.length,
    // A live guest link exists (REVIEW SHARE) - the Reviews list badges it
    // and offers Stop, the turned-it-on-and-forgot remedy. An ended session
    // never reads shared (end drops the token durably).
    shared: o.state !== "ended" && typeof share?.token === "string" && share.token !== "",
  };
}

export interface ReviewRow {
  id: string;
  path: string;
  family: string;
  mtime: number;
  listening: boolean;
  state: "open" | "ended";
  endedBy?: string;
  pins: number;
  messages: number;
  shared: boolean;
}

/** Every review session of ONE home: the artifact walk already lists the
 * `<file>.session.json` companions, so this is a filter + parse over it, never
 * a second discovery. `listening` reads the live poller map by the same
 * realpath key reviewPoll registers under. Sync (collectArtifacts/readFileSync
 * are both sync) so reviewsDetail and reviewsAllHomes share ONE reader. */
function reviewRowsForHome(homePath: string): ReviewRow[] {
  const suffix = ".session.json";
  const rows: ReviewRow[] = [];
  for (const a of collectArtifacts(homePath)) {
    if (!a.path.endsWith(suffix)) continue;
    let s: unknown;
    try {
      s = JSON.parse(readFileSync(a.path, "utf8"));
    } catch {
      continue; /* unreadable or malformed - not a session */
    }
    const target = a.path.slice(0, -suffix.length);
    let real = target;
    try {
      real = realpathSync(target);
    } catch {
      /* artifact gone - the session row still shows, nobody can be polling */
    }
    rows.push({
      id: a.id.slice(0, -suffix.length),
      path: target,
      family: a.family,
      mtime: a.mtime,
      listening: !!reviewPollers.get(real),
      ...reviewSessionSummary(s),
    });
  }
  return rows; // collectArtifacts is already newest-first
}

async function reviewsDetail(homePath: string): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  return json({ reviews: reviewRowsForHome(homePath) });
}

/**
 * Shape rows already read per-home into ONE cross-home view (dash-review-polish
 * slice 5, "all open reviews ACROSS homes"): keep only OPEN sessions - an ended
 * one is history that belongs to its own fleet, not a cross-home attention feed
 * - tag each with its OWN home (the open URL needs the RIGHT home, never the
 * currently-selected fleet's), newest first. Pure: the IO stays in
 * reviewRowsForHome/reviewsAllHomes, so this shaping is unit-tested with no FS.
 */
export function crossHomeReviewRows(perHome: { home: string; rows: ReviewRow[] }[]): (ReviewRow & { home: string })[] {
  const out: (ReviewRow & { home: string })[] = [];
  for (const { home, rows } of perHome) {
    for (const row of rows) {
      if (row.state !== "open") continue;
      out.push({ ...row, home });
    }
  }
  out.sort((a, b) => b.mtime - a.mtime);
  return out;
}

/** Every OPEN review session of EVERY home (dash-review-polish slice 5). The
 * home list comes from the SAME allowedHomePaths() gate every other cross-home
 * read uses - never a fresh directory walk. */
async function reviewsAllHomes(): Promise<Response> {
  const homes = await allowedHomePaths();
  const perHome = Array.from(homes).map((home) => ({ home, rows: reviewRowsForHome(home) }));
  return json({ reviews: crossHomeReviewRows(perHome) });
}

function publishReviewWake(homePath: string, file: string, text: string): void {
  const { id, payload } = reviewWakeParts(file, text);
  const binDir = new URL("../bin/", import.meta.url).pathname;
  const full = reviewWakeText(file, payload);
  // Scope routing: a PROMOTED family's artifact wakes its own roomchief
  // directly (the family spool only that chief drains); everything else -
  // unpromoted families, pooled .lavish pages, archived families - wakes the
  // fleet. The chief-pane meta is the promotion predicate teardown archives,
  // so a demoted family falls back to the fleet spool by itself.
  const fam = reviewWakeFamily(homePath, file);
  const scope = fam && existsSync(`${homePath}/state/${fam}-chief.meta`) ? fam : "";
  // Test seam, DOUBLE-KEYED like every exec hook here (audit-f8): an
  // inherited env var alone must never make production exec an arbitrary
  // file. Live fleets drain the spool within seconds, so an e2e that
  // published real wakes would both race its own assertion and page the
  // real crewchief with noise.
  const hook = process.env.AC_TEST_HOOKS ? process.env.AC_DASH_WAKE_HOOK : "";
  // Fire-and-forget: a wake that cannot publish must never fail the captain's
  // request - the message itself is already durable in the session file.
  Bun.spawn(
    hook
      ? [hook, `${homePath}/state`, id, full, scope]
      : ["bash", "-c",
         `. "$1/ac-lib.sh" && . "$1/ac-wake-lib.sh" && ac_wake_publish "$2" "$5" review "$3" "$4"`,
         "--", binDir, `${homePath}/state`, id, full, scope],
    { env: { ...process.env, AC_HOME: homePath }, stdout: "ignore", stderr: "ignore" },
  );
}

// ---------------------------------------------------------------------------
// REVIEW SHARE (the authoritative contract): the
// captain shares ONE review page to a teammate on the same VPN. Click Share
// on the review page -> a capability token is minted into that session file
// and a SECOND listener starts on port+1, bound 0.0.0.0 so the captain can
// hand out the printed link with localhost swapped for their VPN IP. Click
// Stop (or end the session) -> the token dies and the link is a 404.
// - The guest surface is an ALLOWLIST, everything else 404: GET
//   /review/<token> (the review page, guest variant), and the token-keyed
//   API subset the page needs - artifact body, session (share token
//   stripped), diagrams, and annotate POST. No end/reopen, no share
//   management, no whiteboard writes (guest annotate ignores
//   scene/snapshot), no SPA, no config, no terminal.
// - The token IS the auth: 32 hex chars from the CSPRNG, per session,
//   resolved against the session file on EVERY request (shareResolve), so a
//   revoked or ended share 404s immediately even while cached in the index.
//   No Host check on this listener - it is reached by VPN IP by design, and
//   a DNS-rebinding page without the token reaches only 404s. A browser
//   POST must still originate from this listener itself (cross-site POSTs
//   carry a foreign Origin and are refused).
// - Guest annotations are stamped by:"guest" so captain and crew can tell
//   whose feedback each record is; wakes publish exactly like captain
//   feedback (a message into an unpolled session never falls silent).
// - LIFECYCLE: the listener starts on the first live share (boot rescan
//   included - tokens survive a dashboard restart) and stops when the last
//   share is revoked. No share = nothing listens beyond loopback.

const shareIndex = new Map<string, { home: string; file: string }>();
let shareServer: { stop: (closeActive?: boolean) => void; requestIP?: (req: Request) => { address: string } | null } | null = null;
let mainPort = 8787;

// PRESENCE: every
// guest request stamps token -> viewer (keyed by VPN IP, carrying the name
// the guest chose to give). In-memory only - presence is a live signal, not
// a log - and read through shareViewersView, which prunes anything older
// than the freshness window (the guest page polls every 2s, so 10s of
// silence means the tab is gone).
const shareViewers = new Map<string, Map<string, { name: string; last: number }>>();
export const SHARE_VIEWER_FRESH_MS = 10_000;

/** One safe display token from a guest-supplied name: trimmed, control chars
 * out, bounded - or "" for anonymous (the IP then identifies the machine).
 * Rendering still escapes; this only keeps the STORED value sane. */
export function sanitizeGuestName(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/[\u0000-\u001F\u007F]/g, "").trim().slice(0, 24);
}

/** The captain-facing view of one token's viewers: fresh entries only,
 * pruned in place, newest-seen first. Pure over (map, now) - bun-tested. */
export function shareViewersView(
  viewers: Map<string, { name: string; last: number }> | undefined,
  now: number,
): { name: string; ip: string; ago: number }[] {
  if (!viewers) return [];
  const out: { name: string; ip: string; ago: number }[] = [];
  for (const [ip, v] of viewers) {
    if (now - v.last > SHARE_VIEWER_FRESH_MS) { viewers.delete(ip); continue; }
    out.push({ name: v.name, ip, ago: Math.max(0, Math.round((now - v.last) / 1000)) });
  }
  out.sort((a, b) => a.ago - b.ago);
  return out;
}

function shareViewerSeen(token: string, ip: string, name: string): void {
  if (!ip) return;
  let m = shareViewers.get(token);
  if (!m) { m = new Map(); shareViewers.set(token, m); }
  const prev = m.get(ip);
  // A blank name never overwrites a given one - the guest names themself
  // once, then every later poll without &who keeps it.
  m.set(ip, { name: name || prev?.name || "", last: Date.now() });
}

/** 32 hex chars from the CSPRNG - the whole credential of one shared review. */
export function mintShareToken(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** The link the captain hands out: localhost is deliberate - they swap it for
 * their own VPN IP (the listener binds every interface, the token gates). */
export function shareLinkUrl(sharePort: number, token: string): string {
  return `http://localhost:${sharePort}/review/${token}`;
}

/** Salted sha256 of a share password - never the plaintext - stored in the
 * session file, which agents can read: a hash there identifies nothing. */
export function hashSharePassword(pw: string, salt: string): string {
  return new Bun.CryptoHasher("sha256").update(`${salt}:${pw}`).digest("hex");
}

/** The password out of an HTTP Basic Authorization header ("" when absent or
 * malformed). The username is deliberately ignored - the guest's name comes
 * from &who; Basic is only carrying the shared secret. */
export function basicAuthPassword(header: string | null): string {
  if (!header || !/^Basic /i.test(header)) return "";
  try {
    const dec = atob(header.slice(6).trim());
    const i = dec.indexOf(":");
    return i < 0 ? "" : dec.slice(i + 1);
  } catch {
    return "";
  }
}

/** Timing-safe-enough equality for two hex digests of fixed length. */
export function shareHashEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Token -> live target, fail-closed: unknown shape, unknown token, token no
 * longer in the session file, or an ended session all answer null (and drop
 * the dead index entry). The session file is re-read every time - the file
 * is the authority, the index only a locator. */
function shareResolve(token: string): { home: string; file: string; pw?: { salt: string; hash: string } } | null {
  if (!/^[0-9a-f]{32}$/.test(token)) return null;
  const hit = shareIndex.get(token);
  if (!hit) return null;
  const s = reviewLoad(hit.home, hit.file);
  if (s.state === "ended" || !s.share || s.share.token !== token) {
    shareIndex.delete(token);
    stopShareServerIfIdle();
    return null;
  }
  return { ...hit, pw: s.share.pw };
}

/** The Basic-auth wall of a password-protected share: true when no password
 * is set, or when the request's Basic credential hashes to the stored
 * digest. The 401 challenge is the browser's own native prompt - no custom
 * login page to build or to get wrong. */
function shareAuthOk(req: Request, pw?: { salt: string; hash: string }): boolean {
  if (!pw) return true;
  const given = basicAuthPassword(req.headers.get("authorization"));
  if (!given) return false;
  return shareHashEq(hashSharePassword(given, pw.salt), pw.hash);
}

function shareAuthChallenge(): Response {
  return new Response("password required", {
    status: 401,
    headers: { "www-authenticate": 'Basic realm="agent-crew review", charset="UTF-8"' },
  });
}

function startShareServer(): void {
  if (shareServer) return;
  const sharePort = mainPort + 1;
  // idleTimeout > the 25s review long-poll hold: Bun's 10s default silently
  // drops a held connection (empty reply), which reads as a failed poll.
  shareServer = Bun.serve({ hostname: "0.0.0.0", port: sharePort, idleTimeout: 40, fetch: shareFetch });
  console.log(`review share listening on 0.0.0.0:${sharePort} (token-gated /review/<token> only)`);
}

function stopShareServerIfIdle(): void {
  if (shareServer && shareIndex.size === 0) {
    shareServer.stop();
    shareServer = null;
    console.log("review share listener stopped (no live shares)");
  }
}

/** Boot rescan: shares are durable in their session files, so a dashboard
 * restart re-arms the listener for every still-open shared session. */
function scanShares(): void {
  allowedHomePaths().then((homes) => {
    for (const home of homes) {
      for (const a of collectArtifacts(home)) {
        if (!a.path.endsWith(".session.json")) continue;
        try {
          const s = JSON.parse(readFileSync(a.path, "utf8"));
          if (s?.share?.token && s.state !== "ended" && /^[0-9a-f]{32}$/.test(s.share.token))
            shareIndex.set(s.share.token, { home, file: a.path.slice(0, -".session.json".length) });
        } catch { /* not a session */ }
      }
    }
    if (shareIndex.size > 0) startShareServer();
  }).catch(() => { /* homes unreadable - shares re-arm on the next Share click */ });
}

/** The diagrams payload both listeners serve (captain route + guest route). */
function reviewDiagramsBody(id: string): Response {
  let html = "";
  try {
    html = readFileSync(id, "utf8");
  } catch {
    return json({ diagrams: [] });
  }
  if (id.toLowerCase().endsWith(".md")) html = renderMarkdown(html, true);
  return json({
    diagrams: extractMermaidSources(html).map((m, n) => ({
      n, source: m.source, kind: m.kind, scene: diagramSceneName(id, n + 1),
    })),
  });
}

async function shareFetch(req: Request, server?: { requestIP?: (r: Request) => { address: string } | null }): Promise<Response> {
  const url = new URL(req.url);
  // Cross-site POST wall: the guest page's own POSTs carry this listener's
  // host as Origin; a hostile page's carry its own. No Origin (curl) passes -
  // the token is still required below.
  if (req.method === "POST") {
    const origin = req.headers.get("origin");
    if (origin) {
      let oh = "";
      try { oh = new URL(origin).host; } catch { /* unparseable = foreign */ }
      if (oh !== (req.headers.get("host") ?? "")) return new Response("forbidden", { status: 403 });
    }
  }
  if (url.pathname.startsWith("/review/")) {
    const token = url.pathname.slice("/review/".length);
    const page = shareResolve(token);
    if (!page) return new Response("not found", { status: 404 });
    if (!shareAuthOk(req, page.pw)) return shareAuthChallenge();
    return reviewPage(true);
  }
  const token = url.searchParams.get("t") ?? "";
  const hit = shareResolve(token);
  if (!hit) return new Response("not found", { status: 404 });
  if (!shareAuthOk(req, hit.pw)) return shareAuthChallenge();
  const { home: p, file: id } = hit;
  // PRESENCE: every authenticated guest request stamps the viewer - the VPN
  // IP from the socket, plus whatever name the page sent as &who.
  const ip = server?.requestIP?.(req)?.address ?? "";
  const who = sanitizeGuestName(url.searchParams.get("who"));
  shareViewerSeen(token, ip, who);
  switch (url.pathname) {
    case "/api/artifact":
      return artifactShow(p, id);
    case "/api/review/session": {
      let mt = 0;
      try { mt = statSync(id).mtimeMs; } catch { /* gone mid-review */ }
      // share stripped: the token never rides a guest response.
      return json({ ...reviewLoad(p, id), share: undefined, artifactMtime: mt, polling: !!reviewPollers.get(id) });
    }
    case "/api/review/diagrams":
      return reviewDiagramsBody(id);
    case "/api/review/annotate": {
      if (req.method !== "POST") return json({ error: "POST required" }, 405);
      const a = normalizeAnnotation(await req.text());
      if (!a) return json({ error: "text required; anchor needs selector+fingerprint" }, 400);
      // scene/snapshot deliberately ignored: a guest never writes whiteboard
      // artifacts - their feedback is pins and words. The author is the name
      // the guest gave, "guest" when they stayed anonymous - and the by is
      // what pollSlice's moderation wall keys on: the record is born PENDING
      // in the captain's approval queue. Deliberately NO fleet wake here -
      // the crew has nothing to act on until the captain approves, and the
      // approve route is what wakes them.
      return reviewMutate(p, id, { type: "annotate", anchor: a.anchor, text: a.text, at: new Date().toISOString(), by: who || "guest" });
    }
  }
  return new Response("not found", { status: 404 });
}

/**
 * The review page's remount guard (dash-review-polish-scroll defect 1): the
 * 2s poll's mtime compare is only the cheap TRIGGER to go look, never the
 * gate - an agent that rewrites the artifact with byte-identical content
 * still bumps mtime, and remounting on mtime alone cost the captain their
 * scroll position for no real change. The gate is the freshly fetched body
 * itself. Whole-string compare, not a hash: these bodies are review
 * documents (KB-scale), never large enough to make a hash's collision risk
 * worth paying for. mountedContent is undefined/null on the very first
 * mount, so it never equals a real fetched string and the first load always
 * proceeds. Pure.
 */
export function reviewShouldRemount(mountedContent: string | null | undefined, freshContent: string): boolean {
  return mountedContent !== freshContent;
}

/** The review page: artifact in a sandboxed srcdoc iframe (content via the
 * existing path-safe /api/artifact route) with an injected overlay - hover
 * highlight, click-to-pin - and a side panel fed from the session file.
 * guest=true is the SHARE variant (REVIEW SHARE contract above): served only
 * by the token listener, addressed by token instead of path+file, with the
 * captain-only chrome (End/Reopen, Send & End, Share) not rendered at all -
 * the guest's verbs are pin and comment, and the endpoints behind the
 * missing buttons do not exist on that listener anyway. */
function reviewPage(guest = false): Response {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>agent-crew review</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
${THEME_INIT}
<style>
${THEME_VARS}
${UX_BASE}
  :root{ --ui: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  html{height:100%;background:var(--canvas)}
  body{margin:0;height:100dvh;overflow:hidden;background:var(--canvas);color:var(--fg);font:14px/1.5 var(--ui);display:flex;flex-direction:column}
  #bar{display:flex;gap:10px;align-items:center;padding:8px 14px;border-bottom:1px solid var(--border);background:var(--surface)}
  #bar .name{font-weight:700;letter-spacing:.02em}
  #bar a{color:var(--accent);text-decoration:none;font-size:12px}
  #bar button{font:inherit;color:var(--fg);background:var(--elev);border:1px solid var(--border);border-radius:5px;padding:4px 12px;cursor:pointer}
  #bar button:hover{border-color:var(--border-strong)}
  #bar button:disabled{opacity:.45;cursor:default}
  #bar button:disabled:hover{border-color:var(--border)}
  #annotate-toggle{font-size:12px}
  #annotate-toggle.on{border-color:var(--accent);color:var(--accent)}
  #status{margin-left:auto;color:var(--fg2);font-size:12px;display:flex;align-items:center;gap:6px}
  #dot{width:8px;height:8px;border-radius:50%;background:var(--success)}
  #dot.ended{background:var(--stale)}
  #paintguard{display:none;padding:8px 14px;background:var(--error);color:#fff;font:700 13px var(--ui);text-align:center}
  #main{flex:1;display:flex;min-height:0}
  #frame{flex:1;border:0;background:#fff}
  #panel{width:min(380px,42vw);border-left:1px solid var(--border);background:var(--surface);display:flex;flex-direction:column;min-height:0}
  @media (max-width:900px){
    #main{flex-direction:column}
    #frame{min-height:45dvh}
    #panel{width:auto;border-left:none;border-top:1px solid var(--border);flex:1;min-height:0}
    #pins{max-height:30%}
  }
  #panel h3{margin:0;padding:10px 12px 6px;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--fg2);font-weight:600}
  #pins{overflow:auto;padding:0 10px 8px;max-height:45%}
  .note{border:1px solid var(--border);background:var(--elev);border-radius:6px;padding:8px 10px;margin-bottom:8px;cursor:pointer}
  .note:hover{border-color:var(--accent)}
  .note .head{display:flex;gap:6px;align-items:center;margin-bottom:3px}
  .nnum{color:var(--accent);font:600 11px var(--mono)}
  .nsel{font:11px var(--mono);color:var(--fg2);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
  .nbadge{font-size:10px;border-radius:4px;padding:0 6px;border:1px solid var(--border)}
  .nbadge.moved,.nbadge.missing{color:var(--stale);border-color:var(--stale)}
  #chat{flex:1;display:flex;flex-direction:column;min-height:0;border-top:1px solid var(--border)}
  .chathead{display:flex;align-items:center;justify-content:space-between;padding-right:10px}
  .chathead button{font:12px var(--ui);color:var(--fg2);background:var(--elev);border:1px solid var(--border);border-radius:5px;padding:2px 10px;cursor:pointer}
  .chathead button:hover{color:var(--fg);border-color:var(--border-strong)}
  #thread{flex:1;overflow:auto;padding:8px 10px;display:flex;flex-direction:column;gap:6px}
  .msg{max-width:88%;border-radius:8px;padding:6px 10px;font-size:13px;white-space:pre-wrap;word-break:break-word}
  .msg.you{align-self:flex-end;background:var(--accent-soft);border:1px solid var(--accent)}
  .msg.peer{align-self:flex-start;background:var(--accent-soft);border:1px dashed var(--accent)}
  .msg.agent{align-self:flex-start;background:var(--elev);border:1px solid var(--border)}
  #sharelnk{font:11px var(--mono);color:var(--fg2);max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;cursor:pointer}
  #sharelnk:hover{color:var(--accent)}
  #sharewrap{position:relative;display:inline-flex}
  #sharepop{display:none;position:absolute;top:calc(100% + 6px);left:0;z-index:25;background:var(--surface);border:1px solid var(--border-strong);border-radius:8px;padding:10px;box-shadow:0 8px 24px rgba(0,0,0,.5);gap:8px;align-items:center;white-space:nowrap}
  #sharepop.open{display:flex}
  #sharepop input{width:220px;background:var(--canvas);color:var(--fg);border:1px solid var(--border);border-radius:6px;padding:6px 8px;font:13px var(--ui)}
  #sharepop input:focus{outline:none;border-color:var(--accent)}
  #sharepop button{font:inherit;border-radius:5px;padding:4px 12px;cursor:pointer;border:1px solid var(--border);background:var(--elev);color:var(--fg)}
  #sharepop button.primary{background:var(--accent);color:var(--accent-ink);border:none;font-weight:600}
  #viewers{font-size:11px;color:var(--success);white-space:nowrap}
  .modrow{margin-top:6px;display:flex;gap:8px;align-items:center;justify-content:flex-end}
  .modrow .muted{margin-right:auto;font-size:11px}
  button.mod{font:12px var(--ui);border-radius:5px;padding:2px 10px;cursor:pointer;border:1px solid var(--border);background:var(--elev);color:var(--fg)}
  button.mod.ok{border-color:var(--success);color:var(--success)}
  button.mod.no{border-color:var(--border);color:var(--fg2)}
  button.mod:hover{filter:brightness(1.15)}
  .msg .who{display:block;font-size:10px;color:var(--fg2);margin-bottom:2px;text-transform:uppercase;letter-spacing:.05em}
  #nolisten{display:none;margin:8px 10px 0;padding:8px 10px;border:1px solid var(--border);border-radius:8px;background:var(--elev);color:var(--fg2);font-size:12px}
  #nolisten .mono{font-family:var(--mono);color:var(--fg)}
  #chatin{display:flex;flex-direction:column;gap:8px;padding:10px;border-top:1px solid var(--border)}
  #chatin textarea{resize:vertical;height:64px;background:var(--canvas);color:var(--fg);border:1px solid var(--border);border-radius:8px;padding:8px 10px;font:13px var(--ui)}
  #chatin textarea:focus{outline:none;border-color:var(--accent)}
  .crow{display:flex;justify-content:flex-end;gap:14px;align-items:center}
  #csendend{background:none;border:none;color:var(--error);font:600 13px var(--ui);cursor:pointer;padding:6px 4px}
  #csendend:hover{text-decoration:underline}
  #csendmsg{background:var(--accent);color:var(--accent-ink);border:none;border-radius:8px;padding:8px 16px;font:600 13px var(--ui);cursor:pointer}
  #csendmsg:hover{filter:brightness(1.08)}
  #wboverlay{position:fixed;inset:0;z-index:30;display:none;flex-direction:column;background:var(--canvas)}
  #wboverlay iframe{flex:1;border:0}
  #composer{position:fixed;z-index:20;display:none;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:12px 12px 10px;box-shadow:0 10px 28px rgba(0,0,0,.35);width:300px}
  #composer .chead{display:flex;align-items:center;gap:8px;margin-bottom:8px}
  #composer .cava{width:22px;height:22px;border-radius:50%;background:var(--accent);color:var(--accent-ink);font:700 11px/22px var(--ui);text-align:center}
  #composer .cwho{font-weight:600;font-size:12.5px}
  #composer textarea{width:100%;box-sizing:border-box;min-height:56px;background:transparent;color:var(--fg);border:none;border-bottom:1px solid var(--border);border-radius:0;padding:2px 0 6px;font:13px/1.45 var(--ui);resize:vertical;outline:none}
  #composer textarea:focus{border-bottom-color:var(--accent)}
  #composer .row{margin-top:10px;display:flex;gap:8px;justify-content:flex-end}
  #composer button{font:inherit;font-size:12.5px;border-radius:15px;padding:4px 14px;cursor:pointer;border:none;background:transparent;color:var(--fg2)}
  #composer button:hover{background:var(--elev);color:var(--fg)}
  #composer button.primary{background:var(--accent);color:var(--accent-ink);font-weight:600}
  #composer button.primary:hover{filter:brightness(1.08);color:var(--accent-ink)}
  #composer .ckey{font-size:10.5px;color:var(--fg2);margin-right:auto;align-self:center}
  .muted{color:var(--fg2);font-size:12px;padding:4px 12px}
</style></head><body>
<div id="bar">
  ${guest ? "" : `<a id="backlink" target="_top" title="Back to this fleet's Reviews">&larr; Reviews</a>`}
  <span class="name" id="art-name"></span>
  ${guest ? "" : `<a id="famlink" target="_top" class="mono" style="font-size:12px" title="Open this family on the Board"></a>`}
  <span id="dlinks"></span>
  <button id="annotate-toggle" class="on" title="Annotate ON: clicking any element pins a note. Turn OFF to use the page normally - links click, text selects.">&#9999;&#65039; Annotate: On</button>
  ${guest ? "" : `<span id="sharewrap"><button id="sharebtn" title="Mint a token link a VPN teammate can open (pin + comment only). Stop revokes it.">Share</button><span id="sharepop"><input id="sharepw" type="password" placeholder="Password (empty = open link)" autocomplete="new-password"><button id="sharego" class="primary">Share</button><button id="sharecancel">Cancel</button></span></span><span id="sharelnk"></span><span id="viewers"></span>`}
  <span id="status"><span id="dot"></span><span id="stxt"></span></span>
</div>
<div id="paintguard">&#9888;&#65039; No visible content detected in this artifact &mdash; the page may be blank or broken.</div>
<div id="main">
  <iframe id="frame" sandbox="allow-scripts"></iframe>
  <div id="panel">
    <h3>Pinned notes</h3>
    <div id="pins"><div class="muted">click any element in the page to pin a note</div></div>
    <div id="chat">
      <div class="chathead"><h3>Chat with the crew</h3>${guest ? "" : `<button id="endbtn">End session</button>`}</div>
      <div id="thread"></div>
      <div id="nolisten">No agent is polling this review - your message is saved and the owning
      chief is waked; the crew resumes with <span class="mono">ac-review.sh poll</span>.</div>
      <div id="chatin"><textarea id="cmsg" placeholder="Write a message for the agent..."></textarea>
      <div class="crow">${guest ? "" : `<button id="csendend">&#8594; Send &amp; End</button>`}<button id="csendmsg">Send to Agent</button></div></div>
    </div>
  </div>
</div>
<div id="wboverlay"><iframe id="wbo-frame"></iframe></div>
<div id="composer"><div class="chead"><span class="cava">${guest ? "G" : "C"}</span><span class="cwho">${guest ? "Guest" : "Captain"}</span></div><textarea id="ctext" placeholder="Add a comment\u2026"></textarea><div class="row"><span class="ckey">\u2318\u23ce to comment</span><button id="ccancel">Cancel</button><button class="primary" id="csend">Comment</button></div></div>
<script>
const GUEST = ${guest ? "true" : "false"};
const q = new URLSearchParams(location.search);
const home = q.get("path") ?? "", file = q.get("file") ?? "";
// Guest addressing: the token in the page URL is the ONLY key - the guest
// listener resolves it server-side, so no home path or file path ever
// appears in a guest URL or request.
const TOKEN = GUEST ? (location.pathname.split("/").pop() ?? "") : "";
document.getElementById("art-name").textContent = GUEST ? "shared review" : (file.split("/").pop() ?? file);
// Context links (rich-review-nav): the page was a dead end - no way back to
// the dashboard or the owning family. Fleet name = the home dir's basename;
// family = the data/<family>/ segment of the artifact path.
if (!GUEST) {
  const fleetNm = (home.split("/").pop() || "");
  const bl = document.getElementById("backlink");
  if (bl && fleetNm) bl.href = "/fleets/" + encodeURIComponent(fleetNm) + "/reviews";
  // Embedded in the tool overlay the back link is redundant chrome (the
  // overlay's own Close returns to the page you were on) and clicking it
  // yanks the top window away - full-tab only.
  if (bl && window.self !== window.top) bl.style.display = "none";
  const fm = /\\/data\\/([^/]+)\\//.exec(file);
  const fl = document.getElementById("famlink");
  if (fl && fm && fleetNm) { fl.textContent = fm[1]; fl.href = "/fleets/" + encodeURIComponent(fleetNm) + "/board/" + encodeURIComponent(fm[1]); }
}
// Guest identity: asked ONCE (stored locally), rides every request as &who -
// presence shows it to the captain, and each pin/comment is stamped with it.
// Skipping the prompt is fine: presence then shows the VPN IP alone and
// records stamp "guest".
let WHO = "";
if (GUEST) {
  WHO = localStorage.getItem("acShareName") ?? "";
  if (!WHO) {
    WHO = (window.prompt("Your name (shown to the review owner):") || "").trim().slice(0, 24);
    if (WHO) localStorage.setItem("acShareName", WHO);
  }
}
const api = (p, opt) => fetch(p + (GUEST ? "?t=" + encodeURIComponent(TOKEN) + (WHO ? "&who=" + encodeURIComponent(WHO) : "") : "?path=" + encodeURIComponent(home) + "&file=" + encodeURIComponent(file)) + (opt && opt.extra ? opt.extra : ""), opt);
let pendingAnchor = null, lastMtime = 0, anchorState = {}, lastSig = "", DIAGRAMS = [], lastScrollY = 0, pendingScrollRestore = null, frameReady = false, embedRoundDone = true, diagramsReady = false;
${reviewShouldRemount.toString()}
${buildReviewSrcdoc.toString()}
// The iframe's own reader stylesheet, baked once server-side (review-page-missing-markdown-table-css):
// THEME_VARS for the color tokens, a base body reset mirroring PAGE's own
// plain body rule (the iframe has no ancestor document to inherit one from),
// then readerCss("") for the typography/table rules - unscoped, since this
// document is nothing but reader content, unlike PAGE where .reader must not
// leak into the rest of the SPA chrome. padding:18px 22px matches PAGE's own
// .viewer .vbody{padding:18px 22px} (the SPA reader's actual breathing room)
// - margin:0 alone would strip the UA default 8px body margin with nothing
// to replace it, since this document has no ancestor container to supply
// padding the way .viewer .vbody does for the SPA (roomchief verify r2).
const IFRAME_STYLE = \`<style>${THEME_VARS}
  :root{ --ui: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  body{ margin:0; padding:18px 22px; background:var(--canvas); color:var(--fg); font:14px/1.5 var(--ui); }
  ${readerCss("")}
</style>\`;
// Scroll restore fires only once BOTH the frame's own layout-affecting async
// work (mermaid rendering, gated by "ready" below) AND this page's own
// diagram auto-embed round (maybeEmbedRound(), which also mutates the frame's
// DOM by removing the lazy-load footer once an editor embeds) have settled -
// dash-review-polish-scroll r1: mermaid alone is not the only async layout
// mutation racing the restore.
function maybeSendRestore(){
  if (pendingScrollRestore == null) return;
  if (!frameReady || !embedRoundDone) return;
  document.getElementById("frame").contentWindow.postMessage({ lavishScrollRestore: pendingScrollRestore }, "*");
  pendingScrollRestore = null;
}
// The auto-embed round is a RENDEZVOUS of two independent arrivals, never a
// fixed delay: the frame's cards exist only once its OVERLAY boot() has run
// (it announces that with the same "ready" ping the restore waits on), and
// DIAGRAMS is only filled when /api/review/diagrams returns. Whichever lands
// second runs the round. The 700ms timer this replaced lost that race on any
// artifact whose own deferred <script type="module"> pulls a library over the
// network before DOMContentLoaded - measured at 1355ms on the eight-diagram
// artifact that reported it - and the overlay's "card must exist" guard then
// dropped all three messages in silence, so NO diagram got its eager editor.
function maybeEmbedRound(){
  if (!frameReady || !diagramsReady || embedRoundDone) return;
  const fw = document.getElementById("frame").contentWindow;
  // The first 3 embed eagerly (locked); the rest keep the lazy click-to-load
  // footer - a many-diagram page never pays N editor loads up front.
  DIAGRAMS.slice(0, 3).forEach((g, gi) => {
    const idx = DIAGRAMS.filter((x, xi) => x.kind === g.kind && xi < gi).length;
    const url = "/whiteboard-frame?scene=" + encodeURIComponent(g.scene) + "&seed=" + encodeURIComponent(g.source);
    fw.postMessage({ lavishInline: { kind: g.kind, idx, url, locked: true } }, "*");
  });
  embedRoundDone = true;
  maybeSendRestore();
}

const OVERLAY = \`<script data-acrv>
(function(){
  let hl = null;
  // Annotate toggle: ON = every click pins a note (links and
  // buttons in the artifact are deliberately inert); OFF = the page behaves
  // like a normal document - links navigate the frame, text selects, nothing
  // pins. The review chrome owns the state and pushes it down.
  let annotateOn = true;
  // Queue-feedback snapshot (dash-review-polish slice 3): keyed by scene
  // name, one outstanding snapshot request per card. Populated by
  // requestQueueFeedback, drained by the wbf:"snapshotResult" handler below
  // or its own timeout - either way feedback still queues, image or not.
  const pendingSnap = {};
  function requestQueueFeedback(kind, idx, text, card){
    const iframe = card.querySelector("iframe");
    let scene = "";
    if (iframe && iframe.src) {
      try { scene = new URL(iframe.src, location.href).searchParams.get("scene") || ""; } catch (err) { scene = ""; }
    }
    if (!iframe || !scene) { sendQueueFeedback(kind, idx, text, null); return; }
    let done = false;
    const finish = (snapshot) => {
      if (done) return;
      done = true;
      delete pendingSnap[scene];
      sendQueueFeedback(kind, idx, text, snapshot);
    };
    pendingSnap[scene] = finish;
    iframe.contentWindow.postMessage({ wbf: "snapshot", scene }, "*");
    setTimeout(() => finish(null), 4000);
  }
  function sendQueueFeedback(kind, idx, text, snapshot){
    const note = { kind, idx, text };
    if (snapshot) { note.scene = snapshot.scene; note.snapshot = snapshot.data; }
    parent.postMessage({ lavishNative: true, diagramNote: note }, "*");
  }
  function selectorOf(el){
    if (el.id) return "#" + CSS.escape(el.id);
    const parts = [];
    while (el && el.tagName && el.tagName !== "BODY" && parts.length < 8) {
      let i = 1, sib = el;
      while ((sib = sib.previousElementSibling)) if (sib.tagName === el.tagName) i++;
      parts.unshift(el.tagName.toLowerCase() + ":nth-of-type(" + i + ")");
      el = el.parentElement;
    }
    return parts.join(" > ");
  }
  addEventListener("mouseover", (e) => {
    if (!annotateOn) return;
    if (e.target.closest && e.target.closest(".__wbui")) return;
    if (hl) hl.style.outline = "";
    hl = e.target; hl.style.outline = "2px solid #2dd4bf";
  }, true);
  addEventListener("mouseout", () => { if (hl) { hl.style.outline = ""; hl = null; } }, true);
  addEventListener("click", (e) => {
    if (!annotateOn) return;
    if (e.target.closest && e.target.closest(".__wbui")) return;
    // Two-mode commenting: a live text selection owns this gesture - the
    // mouseup handler below already posted the range pin.
    const sel0 = window.getSelection();
    if (sel0 && !sel0.isCollapsed) { e.preventDefault(); e.stopPropagation(); return; }
    e.preventDefault(); e.stopPropagation();
    const t = e.target;
    const lineEl = t.closest ? t.closest("[data-srcline]") : null;
    parent.postMessage({ lavishNative: true, anchor: {
      selector: selectorOf(t),
      fingerprint: (t.textContent || "").trim().slice(0, 80),
      line: lineEl ? Number(lineEl.getAttribute("data-srcline")) : null,
    }, x: e.clientX, y: e.clientY }, "*");
  }, true);
  // Mode 2 (docs-style): select text -> comment on that RANGE. The anchor
  // carries the quote + ~32 chars of context each side; the enclosing
  // element's selector/fingerprint stay as the re-anchor fallback.
  addEventListener("mouseup", (e) => {
    if (!annotateOn) return;
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) return;
    const quote = sel.toString().trim();
    if (quote.length < 3) return;
    // Anchor on the element the selection STARTS in - a triple-click's
    // trailing newline drags commonAncestorContainer up to <body>, whose
    // selector is empty and useless as a fallback.
    let el = sel.getRangeAt(0).startContainer;
    if (el.nodeType !== 1) el = el.parentElement;
    if (!el || (el.closest && el.closest(".__wbui"))) return;
    const full = el.textContent || "";
    const idx = full.indexOf(quote);
    const lineEl = el.closest ? el.closest("[data-srcline]") : null;
    parent.postMessage({ lavishNative: true, anchor: {
      selector: selectorOf(el),
      fingerprint: quote.slice(0, 80),
      quote: quote.slice(0, 200),
      prefix: idx > 0 ? full.slice(Math.max(0, idx - 32), idx) : "",
      suffix: idx >= 0 ? full.slice(idx + quote.length, idx + quote.length + 32) : "",
      line: lineEl ? Number(lineEl.getAttribute("data-srcline")) : null,
    }, x: e.clientX, y: e.clientY }, "*");
  }, true);
  // Continuous scroll report (dash-review-polish-scroll defect 2): pushed on
  // every scroll rather than pulled on demand, so the review page always
  // holds a value captured from THIS document from before a content change
  // ever replaces it - no query/response round trip that could race the
  // teardown of the old document.
  addEventListener("scroll", () => {
    parent.postMessage({ lavishNative: true, scrollY: window.scrollY }, "*");
  }, { passive: true });
  { const hs = document.createElement("style");
    hs.textContent = "::highlight(lavishq){background:#f5b54266;color:inherit}";
    document.head.appendChild(hs); }
  // Inline whiteboard CARDS, one per rendered diagram (the card shape:
  // header "Whiteboard . diagram N" + note + Queue feedback + Fullscreen,
  // preview in place, Click to edit below). Editing itself happens in the
  // parent overlay - a sandboxed frame cannot host the editor (nested
  // browsing contexts inherit the sandbox, which would cut the editor off
  // from the save API), so both edit buttons open the same overlay.
  function tagDiagrams(){
    const st = document.createElement("style");
    st.textContent = [
      // Injected INTO the sandboxed artifact iframe, which cannot read the
      // parent's CSS tokens - so these stay literal, refreshed to the new dark
      // palette (theme-revamp). Dark card chrome wrapping the white diagram
      // paper, the same in either parent theme (artifact internals stay put).
      ".__wbcard{border:1px solid #2a333f;border-radius:10px;margin:14px 0;overflow:hidden;background:#0e1116}",
      ".__wbhdr{display:flex;gap:10px;align-items:center;padding:8px 12px;background:#161b22}",
      ".__wbhdr .t{color:#e6edf3;font:600 13px system-ui,sans-serif;white-space:nowrap}",
      ".__wbhdr input{flex:1;min-width:120px;background:#0e1116;color:#e6edf3;border:1px solid #2a333f;border-radius:7px;padding:6px 9px;font:12px system-ui,sans-serif}",
      ".__wbhdr input:focus{outline:none;border-color:#2dd4bf}",
      ".__wbbtn{font:600 12px system-ui,sans-serif;padding:6px 12px;border-radius:7px;border:none;background:#2dd4bf;color:#04231f;cursor:pointer;white-space:nowrap}",
      ".__wbbtn:hover{filter:brightness(1.08)}",
      ".__wbbody{background:#fff;padding:6px}",
      ".__wbftr{display:flex;justify-content:center;padding:7px;background:#161b22}",
      ".__wbftr button{font:600 12px system-ui,sans-serif;padding:6px 18px;border-radius:999px;border:1px solid #2dd4bf;background:transparent;color:#2dd4bf;cursor:pointer}",
      ".__wbftr button:hover{background:#2dd4bf;color:#04231f}",
    ].join("");
    document.head.appendChild(st);
    const attach = (el, kind, idx, n) => {
      const host = el.tagName === "CODE" ? (el.closest("pre") || el) : el;
      if (host.closest(".__wbcard")) return;
      const openMsg = (ev) => {
        ev.stopPropagation();
        parent.postMessage({ lavishNative: true, diagram: { kind, idx } }, "*");
      };
      const card = document.createElement("div");
      card.className = "__wbcard";
      card.setAttribute("data-wbcard", kind + ":" + idx);
      const hdr = document.createElement("div");
      hdr.className = "__wbhdr __wbui";
      const t = document.createElement("span");
      t.className = "t"; t.textContent = "Whiteboard · diagram " + n;
      const note = document.createElement("input");
      note.placeholder = "Optional note for the agent about these edits...";
      const q = document.createElement("button");
      q.className = "__wbbtn"; q.textContent = "Queue feedback";
      q.addEventListener("click", (ev) => {
        ev.stopPropagation();
        requestQueueFeedback(kind, idx, note.value.trim(), card);
        note.value = ""; note.placeholder = "queued - the agent will see it";
      });
      const fs = document.createElement("button");
      fs.className = "__wbbtn"; fs.textContent = "Fullscreen";
      fs.addEventListener("click", openMsg);
      hdr.append(t, note, q, fs);
      const ftr = document.createElement("div");
      ftr.className = "__wbftr __wbui";
      const eb = document.createElement("button");
      eb.textContent = "Click to edit";
      eb.addEventListener("click", (ev) => {
        ev.stopPropagation();
        const lock = card.querySelector(".__wbbody > div");
        if (lock && lock.className.indexOf("__wbui") >= 0) { lock.click(); return; }
        parent.postMessage({ lavishNative: true, diagramInline: { kind, idx } }, "*");
      });
      ftr.appendChild(eb);
      const body = document.createElement("div");
      body.className = "__wbbody";
      host.parentNode.insertBefore(card, host);
      card.append(hdr, body, ftr);
      body.appendChild(host);
    };
    let n = 0;
    document.querySelectorAll("pre.mermaid, div.mermaid").forEach((el, i) => attach(el, "block", i, ++n));
    document.querySelectorAll("code[class*=language-mermaid]").forEach((el, i) => attach(el, "fence", i, ++n));
  }
  // Mermaid render pass - reports-mermaid: extracted top-level (mermaidPass,
  // above THEME_INIT/readerCss) and interpolated here verbatim, the same
  // toString() sharing readerCss itself established, so this overlay and the
  // SPA's markdown readers (Reports/Records/Board) run the one implementation
  // instead of two independently-maintained copies.
${mermaidPass.toString()}
${artifactPainted.toString()}
  function boot(){
    tagDiagrams();
    // Scroll-restore readiness (dash-review-polish-scroll defect 2, r1 fix):
    // fires only once mermaidPass()'s own layout-affecting async work has
    // actually settled, so the review page never restores a scroll position
    // into a document whose diagrams have not finished rendering yet. The
    // paint guard measures on the same "ready" edge (dash-review-polish-
    // paint) - measuring any earlier would catch mermaid's async layout
    // mid-render and manufacture a false blank verdict.
    mermaidPass(() => import("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs").then((m) => m.default), "neutral", "background:#fff;border:0;margin:0;padding:10px;overflow-x:auto").then(() => {
      parent.postMessage({ lavishNative: true, ready: true, painted: artifactPainted(document) }, "*");
    });
  }
  if (document.readyState === "loading") addEventListener("DOMContentLoaded", boot);
  else boot();
  const wbfMap = {};
  addEventListener("message", (e) => {
    const d = e.data || {};
    if (typeof d.lavishScrollRestore === "number") {
      window.scrollTo(0, d.lavishScrollRestore);
      return;
    }
    if ("lavishAnnotate" in d) {
      annotateOn = !!d.lavishAnnotate;
      if (!annotateOn && hl) { hl.style.outline = ""; hl = null; }
      return;
    }
    if (d.wbf === "ready" || d.wbf === "save") {
      if (d.scene) wbfMap[d.scene] = e.source;
      parent.postMessage(d, "*");
      return;
    }
    if ((d.wbf === "init" || d.wbf === "saved") && d.scene && wbfMap[d.scene]) {
      wbfMap[d.scene].postMessage(d, "*");
      return;
    }
    if (d.wbf === "snapshotResult" && d.scene) {
      const finish = pendingSnap[d.scene];
      if (finish) finish(d.ok && d.data ? { scene: d.scene, data: d.data } : null);
      return;
    }
    if (d.lavishInline) {
      // Look up by the identity stamped at tag time: an earlier swap removes
      // its host from the DOM, so a live element query would mis-index every
      // later card (found by e2e - only the first of two diagrams embedded).
      const card = document.querySelector('.__wbcard[data-wbcard="' + d.lavishInline.kind + ":" + d.lavishInline.idx + '"]');
      if (card && !card.querySelector("iframe")) {
        const body = card.querySelector(".__wbbody");
        const host = body.firstElementChild; // the original mermaid render
        body.style.cssText = "position:relative;padding:0;background:#0e1116";
        const fr = document.createElement("iframe");
        fr.src = d.lavishInline.url;
        fr.style.cssText = "width:100%;height:480px;border:0;display:block";
        const ftr = card.querySelector(".__wbftr");
        const lock = document.createElement("div");
        lock.className = "__wbui";
        lock.style.cssText = "position:absolute;inset:0;z-index:6;display:flex;align-items:center;justify-content:center;cursor:pointer;background:rgba(11,15,20,.14)";
        const lbl = document.createElement("span");
        lbl.textContent = "Click to edit";
        lbl.style.cssText = "font:600 12px system-ui,sans-serif;padding:6px 18px;border-radius:999px;border:1px solid #2dd4bf;background:#0e1116;color:#2dd4bf";
        lock.appendChild(lbl);
        lock.addEventListener("click", (ev) => { ev.stopPropagation(); lock.style.display = "none"; lock.setAttribute("data-unlocked", "1"); });
        // DEFAULT = the ORIGINAL render, exactly as before the editor existed
        //: it is the artifact's own DOM, so notes pin on
        // diagram nodes and md fences keep their source-line anchors. The
        // editor PRELOADS hidden so the header Switch shows it instantly;
        // switching back never unmounts it (edits in progress survive).
        fr.style.display = "none";
        lock.style.display = "none";
        body.append(fr);
        if (d.lavishInline.locked) body.append(lock);
        if (host) { body.insertBefore(host, fr); host.style.display = ""; }
        // One unlock affordance only (captain screenshot): once the editor is
        // embedded the lock pill owns it - the footer pill was the lazy-load
        // path and turns redundant the moment the embed lands.
        if (ftr) ftr.remove();
        body.style.background = "#fff";
        const hdr = card.querySelector(".__wbhdr");
        const sw = document.createElement("button");
        sw.className = "__wbbtn"; sw.textContent = "Editor";
        sw.title = "switch between the pinnable diagram render and the Excalidraw editor";
        sw.addEventListener("click", (ev) => {
          ev.stopPropagation();
          const showingEditor = fr.style.display !== "none";
          if (showingEditor) {
            fr.style.display = "none"; lock.style.display = "none";
            if (host) host.style.display = "";
            body.style.background = "#fff";
            sw.textContent = "Editor";
          } else {
            if (host) host.style.display = "none";
            fr.style.display = "block";
            body.style.background = "#0e1116";
            if (lock.parentNode && lock.getAttribute("data-unlocked") !== "1") lock.style.display = "flex";
            sw.textContent = "Diagram";
          }
        });
        if (hdr) hdr.insertBefore(sw, hdr.querySelector("input"));
      }
    }
    if (d.lavishHighlight) {
      let el = null;
      try { el = document.querySelector(d.lavishHighlight); } catch {}
      let ranged = false;
      if (d.lavishQuote && window.Highlight && CSS.highlights) {
        // Find the quote's text range (within the element when it resolves,
        // else the whole document) and light exactly those words.
        const root = el || document.body;
        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = w.nextNode())) {
          const i = (node.textContent || "").indexOf(d.lavishQuote);
          if (i >= 0) {
            const rng = document.createRange();
            rng.setStart(node, i); rng.setEnd(node, i + d.lavishQuote.length);
            CSS.highlights.set("lavishq", new Highlight(rng));
            (node.parentElement || root).scrollIntoView({ block: "center", behavior: "smooth" });
            setTimeout(() => CSS.highlights.delete("lavishq"), 2200);
            ranged = true; break;
          }
        }
      }
      if (!ranged && el) {
        el.scrollIntoView({ block: "center", behavior: "smooth" });
        const old = el.style.outline;
        el.style.outline = "3px solid #d29922";
        setTimeout(() => { el.style.outline = old; }, 1600);
      }
    }
    if (d.lavishCheck) {
      const res = {};
      for (const a of d.lavishCheck) {
        let el = null;
        try { el = document.querySelector(a.selector); } catch {}
        if (a.quote) {
          // Range pin: the quote decides. In-element = ok; anywhere else in
          // the document = moved; nowhere = missing.
          if (el && (el.textContent || "").indexOf(a.quote) >= 0) res[a.n] = "ok";
          else if ((document.body.textContent || "").indexOf(a.quote) >= 0) res[a.n] = "moved";
          else res[a.n] = "missing";
        }
        else if (!el) res[a.n] = "missing";
        else res[a.n] = ((el.textContent || "").trim().slice(0, 80) === a.fingerprint) ? "ok" : "moved";
      }
      parent.postMessage({ lavishNative: true, check: res }, "*");
    }
  });
})();
<\\/script>\`;

async function loadArtifact(){
  const res = await api("/api/artifact");
  const body = await res.json();
  const content = body.html ?? body.content ?? "";
  const frame = document.getElementById("frame");
  // Content is the gate, mtime was only the trigger that got refresh() to
  // look (dash-review-polish-scroll defect 1): a rewrite with the same bytes
  // still bumps mtime and must NOT remount, or the captain loses their place
  // for no real change. The signature of what is mounted lives ON the
  // element, mirroring the board view's f._loaded (:6936 house pattern) -
  // just derived from content here instead of a fetch generation counter.
  if (!reviewShouldRemount(frame._mountedContent, content)) return;
  // Scroll capture (defect 2): lastScrollY is pushed continuously by the
  // OVERLAY's own scroll listener, so the value here was already captured
  // from the OLD document before srcdoc below tears it down - no
  // request/response round trip that could race that teardown.
  pendingScrollRestore = lastScrollY;
  // Pessimistic until proven otherwise (r1): srcdoc below can start running
  // the new document's boot() before this function's own await resolves, so
  // every gate must already read false the instant a "ready"/embed-done
  // signal could possibly arrive.
  frameReady = false;
  embedRoundDone = false;
  diagramsReady = false;
  document.getElementById("paintguard").style.display = "none";
  frame._mountedContent = content;
  frame.srcdoc = buildReviewSrcdoc(body.kind, content, IFRAME_STYLE, document.documentElement.getAttribute("data-theme") || "", document.documentElement.getAttribute("data-palette") || "") + OVERLAY;
  const dres = await api("/api/review/diagrams");
  const d = await dres.json();
  DIAGRAMS = d.diagrams ?? [];
  // Auto-embed: every diagram card hosts its live editor
  // from the start, LOCKED under a click-to-edit layer - no first-click load
  // wait. This is the second of maybeEmbedRound()'s two arrivals; the frame's
  // own "ready" ping is the other.
  diagramsReady = true;
  maybeEmbedRound();
  const dl = document.getElementById("dlinks");
  dl.textContent = DIAGRAMS.length
    ? DIAGRAMS.length + " diagram" + (DIAGRAMS.length > 1 ? "s" : "") + " - use the \u270E button on each"
    : "";
}

function openDiagramOverlay(g){
  document.getElementById("wbo-frame").src =
    "/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(g.scene) + "&seed=" + encodeURIComponent(g.source) + "&embed=1";
  document.getElementById("wboverlay").style.display = "flex";
}

const composer = document.getElementById("composer");
addEventListener("message", (e) => {
  const d = e.data || {};
  if (!d.lavishNative && !d.wbf && !d.wbo) return;
  if (typeof d.scrollY === "number") { lastScrollY = d.scrollY; return; }
  if (d.ready) {
    // Fires once per new document, after the frame's OVERLAY boot() has built
    // the diagram cards and its layout-affecting async work (mermaid
    // rendering) has settled. ONE signal, two consumers: it is the gate that
    // the cards maybeEmbedRound() addresses now exist, and one of the two
    // gates before a captured scroll position is restored
    // (dash-review-polish-scroll r1: the embed round is the other). The
    // restore therefore rides maybeEmbedRound()'s own tail call - a second
    // maybeSendRestore() here could never post, since embedRoundDone only
    // turns true inside that round.
    frameReady = true;
    maybeEmbedRound();
    document.getElementById("paintguard").style.display = d.painted ? "none" : "block";
    return;
  }
  if (d.wbo === "close") {
    document.getElementById("wboverlay").style.display = "none";
    document.getElementById("wbo-frame").src = "about:blank";
    return;
  }
  if (d.anchor) {
    pendingAnchor = d.anchor;
    composer.style.display = "block";
    composer.style.left = Math.min(d.x + 60, innerWidth - 330) + "px";
    composer.style.top = Math.min(d.y + 60, innerHeight - 160) + "px";
    document.getElementById("ctext").focus();
  }
  if (d.check) { anchorState = d.check; lastSig = ""; refresh(); }
  if (d.diagram) {
    const g = DIAGRAMS.filter((x) => x.kind === d.diagram.kind)[d.diagram.idx];
    if (g) openDiagramOverlay(g);
  }
  if (d.diagramInline) {
    const g = DIAGRAMS.filter((x) => x.kind === d.diagramInline.kind)[d.diagramInline.idx];
    if (g) {
      const url = "/whiteboard-frame?scene=" + encodeURIComponent(g.scene) + "&seed=" + encodeURIComponent(g.source);
      document.getElementById("frame").contentWindow.postMessage(
        { lavishInline: { kind: d.diagramInline.kind, idx: d.diagramInline.idx, url } }, "*");
    }
  }
  // wbf bridge (the chrome relay role): the inline editor is an opaque-origin
  // frame with no API access - it announces ready, we feed it the scene; it
  // sends a save payload, we POST it. Only scenes this review DISCOVERED are
  // honored, so the reviewed artifact cannot forge writes to arbitrary names.
  if (d.wbf === "ready" && e.source) {
    const g = DIAGRAMS.find((x) => x.scene === d.scene);
    if (!g) return;
    const src = e.source;
    // version rides down inside the existing wbf:"init" message - no new
    // message kind, the overlay's blind relay already forwards it whole.
    api("/api/whiteboard", { extra: "&scene=" + encodeURIComponent(d.scene) })
      .then(async (r) => ({ data: await r.json(), version: r.headers.get("etag") }))
      .then(({ data, version }) => src.postMessage({ wbf: "init", scene: d.scene, data, version }, "*"));
  }
  if (d.wbf === "save" && e.source) {
    const g = DIAGRAMS.find((x) => x.scene === d.scene);
    const src = e.source;
    if (!g) { src.postMessage({ wbf: "saved", scene: d.scene, ok: false, error: "unknown scene" }, "*"); return; }
    // d.overwrite is the captain's "Keep mine" only - honoring it here would
    // let ANY frame skip the version check, but this bridge only ever relays
    // what the frame itself set, and only the frame's own Keep-mine button
    // sets it true.
    const headers = d.overwrite ? { "if-match": "*" } : (d.version ? { "if-match": d.version } : {});
    fetch("/api/whiteboard?path=" + encodeURIComponent(home) + "&scene=" + encodeURIComponent(d.scene), {
      method: "POST", headers, body: JSON.stringify(d.payload ?? {}),
    }).then(async (r) => {
      const j = await r.json().catch(() => ({}));
      const conflict = r.status === 428 || r.status === 412;
      src.postMessage({ wbf: "saved", scene: d.scene, ok: r.ok, conflict, error: r.ok ? "" : (j.error || ""), version: j.version }, "*");
    });
  }
  if (d.diagramNote) {
    const g = DIAGRAMS.filter((x) => x.kind === d.diagramNote.kind)[d.diagramNote.idx];
    const scenePath = g ? home + "/whiteboards/" + g.scene + ".excalidraw.json" : "(unknown scene)";
    const text = (d.diagramNote.text ? d.diagramNote.text + "\\n\\n" : "")
      + "Whiteboard edits to diagram " + (g ? g.n + 1 : "?")
      + ":\\nEdited scene JSON: " + scenePath;
    const body = { anchor: null, text };
    // The overlay only offers a snapshot when it captured one from a
    // mounted editor for THIS scene - the server is what actually decides
    // whether it gets kept (dash-review-polish slice 3: it only survives
    // when the scene file exists on disk).
    if (g && d.diagramNote.scene === g.scene && d.diagramNote.snapshot) {
      body.scene = g.scene;
      body.snapshot = d.diagramNote.snapshot;
    }
    api("/api/review/annotate", { method: "POST", body: JSON.stringify(body) })
      .then(() => refresh(true));
  }
});
document.getElementById("ccancel").addEventListener("click", () => { composer.style.display = "none"; });
document.getElementById("ctext").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); document.getElementById("csend").click(); }
  if (e.key === "Escape") composer.style.display = "none";
});
document.getElementById("csend").addEventListener("click", async () => {
  const text = document.getElementById("ctext").value.trim();
  if (text) await api("/api/review/annotate", { method: "POST", body: JSON.stringify({ anchor: pendingAnchor, text }) });
  document.getElementById("ctext").value = ""; composer.style.display = "none"; refresh(true);
});
async function sendChat(){
  const box = document.getElementById("cmsg");
  const text = box.value.trim();
  if (!text) return;
  const res = await api("/api/review/annotate", { method: "POST", body: JSON.stringify({ anchor: null, text }) });
  if (!res.ok) {
    const b = await res.json().catch(() => ({}));
    document.getElementById("stxt").textContent = "send refused: " + (b.error ?? res.status);
    return; // keep the text in the box - nothing is lost
  }
  box.value = "";
  refresh(true);
}
document.getElementById("csendmsg").addEventListener("click", sendChat);
// Captain-only chrome: these elements are not rendered on the guest variant,
// and the endpoints behind them do not exist on the guest listener.
const csendend = document.getElementById("csendend");
if (csendend) csendend.addEventListener("click", async () => {
  const box = document.getElementById("cmsg");
  if (box.value.trim()) await sendChat();
  await api("/api/review/end", { method: "POST", extra: "&by=human" });
  refresh(true);
});
document.getElementById("cmsg").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendChat(); }
});
const endbtn = document.getElementById("endbtn");
if (endbtn) endbtn.addEventListener("click", async () => {
  const ended = document.getElementById("dot").classList.contains("ended");
  if (ended) await api("/api/review/end", { method: "POST", extra: "&reopen=1&force=1" });
  else await api("/api/review/end", { method: "POST", extra: "&by=human" });
  refresh(true);
});
// Share (captain only): one click mints the token link (copied to the
// clipboard when the browser allows), one click revokes it. The rendered
// state follows the SESSION (refresh() syncs shareUrl every tick), so a
// share made in another tab or revoked by an end shows up here too.
let shareUrl = null;
const sharebtn = document.getElementById("sharebtn");
function shareRender(){
  if (!sharebtn) return;
  sharebtn.textContent = shareUrl ? "Stop sharing" : "Share";
  const lnk = document.getElementById("sharelnk");
  // Keep a "copied" flash; only rewrite when the URL itself changed.
  if (lnk._url !== shareUrl) {
    lnk._url = shareUrl;
    lnk.textContent = shareUrl ?? "";
    lnk.title = shareUrl ? "Click to copy the full link" : "";
  }
}
// The rendered link truncates (ellipsis), so CLICK IS COPY - the one way to
// get the full URL back after a reload, when the mint-time copy is long gone.
document.getElementById("sharelnk")?.addEventListener("click", async () => {
  const lnk = document.getElementById("sharelnk");
  if (!lnk._url) return;
  try {
    await navigator.clipboard.writeText(lnk._url);
    const u = lnk._url;
    lnk.textContent = "copied ✓";
    setTimeout(() => { if (lnk._url === u) lnk.textContent = u; }, 1200);
  } catch {}
});
// Share flow: the button toggles a small popover anchored under it (never
// the browser's native prompt) - password optional, Enter shares, Escape
// cancels. Stop sharing stays a single click, no popover.
const sharepop = document.getElementById("sharepop");
function sharePopShow(on){
  if (!sharepop) return;
  sharepop.classList.toggle("open", on);
  if (on) { const i = document.getElementById("sharepw"); i.value = ""; i.focus(); }
}
async function shareGo(){
  const pw = document.getElementById("sharepw").value.trim();
  sharePopShow(false);
  // Optional basic-auth gate: with a password set, a leaked URL alone no
  // longer opens the review - hand the password over a separate channel.
  const j = await (await api("/api/review/share", { method: "POST", body: pw })).json().catch(() => ({}));
  if (j.url) { shareUrl = j.url; try { await navigator.clipboard.writeText(j.url); } catch {} }
  else document.getElementById("stxt").textContent = "share refused: " + (j.error ?? "?");
  shareRender();
  refresh(true);
}
if (sharebtn) sharebtn.addEventListener("click", async () => {
  if (shareUrl) {
    await api("/api/review/share", { method: "POST", extra: "&stop=1" });
    shareUrl = null;
    shareRender();
    refresh(true);
  } else sharePopShow(!sharepop.classList.contains("open"));
});
if (sharepop) {
  document.getElementById("sharego").addEventListener("click", shareGo);
  document.getElementById("sharecancel").addEventListener("click", () => sharePopShow(false));
  document.getElementById("sharepw").addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); shareGo(); }
    if (e.key === "Escape") sharePopShow(false);
  });
}

function esc(t){ const d = document.createElement("div"); d.textContent = t; return d.innerHTML; }
// The captain's verdict on one pending guest record (captain page only -
// the guest listener has no moderate route).
function moderate(n, verdict){
  api("/api/review/moderate", { method: "POST", extra: "&n=" + n + "&verdict=" + verdict }).then(() => refresh(true));
}
async function refresh(force){
  const s = await (await api("/api/review/session")).json();
  if (s.artifactMtime && lastMtime && s.artifactMtime !== lastMtime) {
    await loadArtifact();
    setTimeout(checkAnchors, 400);
  }
  if (s.artifactMtime) lastMtime = s.artifactMtime;
  if (GUEST && s.artifact) document.getElementById("art-name").textContent = s.artifact.split("/").pop();
  if (sharebtn) {
    shareUrl = s.shareUrl ?? null; shareRender();
    // Share exists only for an OPEN session (the reducer refuses on ended;
    // end already revoked any live link) - mirror that on the button and
    // close a popover left open across the transition.
    const shareable = s.state !== "ended";
    sharebtn.disabled = !shareable;
    if (!shareable) sharePopShow(false);
    // Live presence of the share link: name when the guest gave one, VPN IP
    // always - fresh viewers only (the server prunes past 10s of silence).
    const vs = document.getElementById("viewers");
    const list = (s.viewers ?? []).map((v) => v.name ? v.name + " (" + v.ip + ")" : v.ip);
    vs.textContent = list.length ? "\\uD83D\\uDC41 " + list.join(", ") : "";
    vs.title = list.length ? "watching the shared link now" : "";
  }
  // Dismissed guest records leave the captain's view (the file keeps them);
  // the guest, their author, keeps seeing their own.
  const pins = (s.queue ?? []).filter((a) => a.anchor && (GUEST || !a.dismissed));
  // Message identity: a record's "by" names a non-captain author. Own
  // messages sit right as .you; the other human's sit left as .peer with
  // their name; agent replies unchanged. pending = awaiting the captain's
  // approve/dismiss (the moderation wall - agents cannot see it yet).
  const chat = (s.queue ?? []).filter((a) => !a.anchor && (GUEST || !a.dismissed)).map((a) => {
    const mine = GUEST ? a.by === (WHO || "guest") : !a.by;
    const pending = !!a.by && !a.approved && !a.dismissed;
    return { n: a.n, at: a.at, who: mine ? "you" : "peer", label: mine ? "you" : (a.by ?? "captain"), text: a.text, image: a.image, pending, approved: !!a.approved };
  })
    .concat((s.replies ?? []).map((r) => ({ at: r.at, who: "agent", label: "agent", text: r.text })))
    .sort((a, b) => a.at < b.at ? -1 : 1);
  const sig = JSON.stringify([s.state, pins, chat, anchorState]);
  const ended = s.state === "ended";
  document.getElementById("dot").className = ended ? "ended" : "";
  document.getElementById("stxt").textContent = ended ? "ended (" + (s.endedBy ?? "?") + ")" : "open";
  if (endbtn) endbtn.textContent = ended ? "Reopen" : "End session";
  const box = document.getElementById("cmsg");
  box.disabled = ended;
  box.placeholder = ended ? "session ended - Reopen to continue" : "Write a message for the agent... (Enter to send)";
  if (csendend) csendend.disabled = ended;
  document.getElementById("nolisten").style.display = (!ended && s.polling === false) ? "block" : "none";
  if (!force && sig === lastSig) return;
  lastSig = sig;
  const pv = document.getElementById("pins");
  pv.innerHTML = pins.length ? "" : '<div class="muted">click any element in the page to pin a note</div>';
  for (const a of pins) {
    const st = anchorState[a.n] ?? "ok";
    const pending = !!a.by && !a.approved && !a.dismissed;
    const d = document.createElement("div");
    d.className = "note";
    // The anchor's HUMAN face: the element's own text
    // fingerprint (or the md line number) - never the CSS selector, which
    // now rides only the tooltip.
    const fp = String(a.anchor.fingerprint || "").trim();
    const loc = a.anchor.line ? ("line " + a.anchor.line) : (fp ? "\u201c" + fp.slice(0, 64) + (fp.length > 64 ? "\u2026" : "") + "\u201d" : "");
    d.innerHTML = '<div class="head"><span class="nnum">#' + a.n + '</span><span class="nsel" title="' + esc(a.anchor.selector) + '">' + esc(loc) + '</span>'
      + (a.by ? '<span class="nbadge">' + esc(a.by) + (a.approved ? " \\u2713" : "") + '</span>' : "")
      + (st !== "ok" ? '<span class="nbadge ' + st + '">' + st + "</span>" : "") + '</div>' + esc(a.text);
    if (!GUEST && pending) {
      const row = document.createElement("div");
      row.className = "modrow";
      row.innerHTML = '<span class="muted">pending - the crew cannot see this yet</span>'
        + '<button class="mod ok">Approve</button><button class="mod no">Dismiss</button>';
      row.querySelector(".mod.ok").addEventListener("click", (e) => { e.stopPropagation(); moderate(a.n, "approve"); });
      row.querySelector(".mod.no").addEventListener("click", (e) => { e.stopPropagation(); moderate(a.n, "dismiss"); });
      d.appendChild(row);
    }
    d.addEventListener("click", () => {
      document.getElementById("frame").contentWindow.postMessage({ lavishHighlight: a.anchor.selector, lavishQuote: a.anchor.quote || null }, "*");
    });
    pv.appendChild(d);
  }
  const tv = document.getElementById("thread");
  tv.innerHTML = chat.length ? "" : '<div class="muted" style="padding:8px 12px">no messages yet - write below; if nobody is polling, the owning chief is waked</div>';
  for (const m of chat) {
    const d = document.createElement("div");
    d.className = "msg " + m.who;
    d.innerHTML = '<span class="who">' + esc(m.label) + (m.approved ? " \\u2713" : "") + '</span>' + esc(m.text)
      + (m.image ? '<div class="muted">snapshot attached</div>' : "");
    if (!GUEST && m.pending) {
      const row = document.createElement("div");
      row.className = "modrow";
      row.innerHTML = '<span class="muted">pending</span>'
        + '<button class="mod ok">Approve</button><button class="mod no">Dismiss</button>';
      row.querySelector(".mod.ok").addEventListener("click", () => moderate(m.n, "approve"));
      row.querySelector(".mod.no").addEventListener("click", () => moderate(m.n, "dismiss"));
      d.appendChild(row);
    }
    tv.appendChild(d);
  }
  tv.scrollTop = tv.scrollHeight;
}
function checkAnchors(){
  api("/api/review/session").then((r) => r.json()).then((s) => {
    const anchors = (s.queue ?? []).filter((a) => a.anchor).map((a) => ({ n: a.n, selector: a.anchor.selector, fingerprint: a.anchor.fingerprint, quote: a.anchor.quote || null }));
    if (anchors.length) document.getElementById("frame").contentWindow.postMessage({ lavishCheck: anchors }, "*");
  });
}
// Annotate toggle: the chrome owns the state; the frame's
// default is ON, so the push below matters on toggle AND after every artifact
// remount (srcdoc reload boots a fresh document back at the default). Pushing
// on each refresh tick is idempotent and closes that remount race.
let annotateOn = true;
function pushAnnotate(){
  const fw = document.getElementById("frame").contentWindow;
  if (fw) fw.postMessage({ lavishAnnotate: annotateOn }, "*");
}
document.getElementById("annotate-toggle").addEventListener("click", () => {
  annotateOn = !annotateOn;
  const b = document.getElementById("annotate-toggle");
  b.classList.toggle("on", annotateOn);
  b.innerHTML = annotateOn ? "\\u270F\\uFE0F Annotate: On" : "\\u270F\\uFE0F Annotate: Off";
  pushAnnotate();
});
loadArtifact().then(() => setTimeout(checkAnchors, 600));
refresh(); setInterval(refresh, 2000);
setInterval(pushAnnotate, 2000);
</script></body></html>`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/** Reachability gate (browser-borne attacks): a WebSocket is not subject to
 * the same-origin policy and a cross-site POST needs no preflight, so any
 * website the captain's browser has open could otherwise reach this server -
 * and /api/term/ws is a full shell. Host must be a local name (rejecting DNS
 * rebinding, where a hostile hostname resolves to 127.0.0.1), and Origin,
 * when a browser sends one, must be this server itself. Non-browser clients
 * (curl, the fleet's own tooling) send no Origin and pass. A sandboxed
 * artifact iframe sends the literal "null" Origin - not parseable as a local
 * URL, so it is refused here too, which is exactly its contract. */
export function localHostOk(host: string | null, port: number): boolean {
  return host === `127.0.0.1:${port}` || host === `localhost:${port}` || host === `[::1]:${port}`;
}
export function originOk(origin: string | null, port: number): boolean {
  if (origin === null) return true;
  let u: URL;
  try { u = new URL(origin); } catch { return false; }
  return u.protocol === "http:" && localHostOk(u.host, port);
}

function parsePort(argv: string[]): number {
  const i = argv.indexOf("--port");
  if (i >= 0 && argv[i + 1]) {
    const n = Number(argv[i + 1]);
    if (Number.isInteger(n) && n > 0 && n < 65536) return n;
  }
  return 8787;
}

// The server entry: bin/dashboard.ts (the launcher shim) calls this under its
// own import.meta.main guard, so importing this module stays side-effect-free.
export function dashboardMain() {
  const port = parsePort(process.argv);
  mainPort = port; // the share listener (REVIEW SHARE) lives on port+1
  scanShares();    // re-arm durable shares across a dashboard restart
  // Each terminal socket is a live pty + herdr client; a buggy reconnect loop
  // must not fork-bomb the machine. 4 covers every real captain shape (a few
  // browser tabs), and the 429 names the limit.
  let ptyCount = 0;
  // Reap pty children on shutdown: a killed dashboard otherwise ORPHANS every
  // live terminal's herdr client (reparented to launchd, still attached to
  // the shared herdr session at its old size) - measured five zombies after a
  // day of restarts, clamping the session and reflow-janking every live tab.
  const livePtys = new Set<ReturnType<typeof Bun.spawn>>();
  let reaping = false;
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const)
    process.on(sig, () => {
      if (reaping) return;
      reaping = true;
      for (const p of livePtys) try { p.kill(); } catch { /* already gone */ }
      process.exit(sig === "SIGINT" ? 130 : 143);
    });
  Bun.serve({
    hostname: "127.0.0.1",
    port,
    // idleTimeout > the 25s review long-poll hold (reviewPollHold): Bun's
    // 10s default closed the held connection with an empty reply, so every
    // quiet poll cycle cost the shim a spurious reconnect.
    idleTimeout: 40,
    websocket: {
      open(ws) {
        const dk = ws.data as { kind?: string };
        if (dk.kind === "attach") {
          // Native mirror (chief-pane-native-attach): a real `herdr agent
          // attach` on a pty this process owns, spawned at the PANE's own
          // geometry (passive-size - herdr sizes a shared pane to the last
          // writer, so a viewer-sized attach would reflow it under the
          // working agent). OUTPUT-ONLY by construction: the message handler
          // drops every frame, so typing keeps riding roomInput's gates.
          const d = ws.data as { home: string; fam: string; watch: string; term?: Bun.Terminal; proc?: ReturnType<typeof Bun.spawn>; timer?: ReturnType<typeof setInterval> };
          ptyCount++;
          void (async () => {
            const t = await panelPaneOf(d.home, d.fam, d.watch);
            if ("why" in t) {
              // {closed} FIRST so the frame latches "pane gone" instead of
              // treating the bare close as transient and reconnect-looping.
              try { ws.send(JSON.stringify({ closed: true, why: t.why })); } catch { /* ws gone */ }
              try { ws.close(1008, "no pane"); } catch { /* already closed */ }
              return;
            }
            const cols = (await paneCols(d.home, t.pane)) ?? 120;
            const rows = await paneRows(d.home, t.pane);
            if (ws.readyState !== WebSocket.OPEN) return; // closed mid-gate; close already released the slot
            // Scrollback: the attach stream only ever paints the live
            // viewport, so the wheel had nothing to scroll. Pre-fill xterm's
            // buffer with the pane's history once per mount (minus the
            // viewport rows the live paint is about to draw) - local scroll,
            // the real pane is never moved.
            const hist = await run(
              ["herdr", "pane", "read", t.pane, "--source", "recent-unwrapped", "--format", "ansi", "--lines", "2000"],
              { AC_HOME: d.home },
            );
            if (hist.code === 0 && hist.out) {
              const lines = hist.out.split("\n").slice(0, -rows).join("\r\n");
              if (lines) { try { ws.send(new TextEncoder().encode(lines + "\r\n")); } catch { /* ws closing */ } }
            }
            if (ws.readyState !== WebSocket.OPEN) return;
            try {
              const term = new Bun.Terminal({
                cols, rows,
                data(_t, chunk) { try { ws.send(chunk); } catch { /* socket gone */ } },
              });
              d.term = term;
              d.proc = Bun.spawn(attachArgv(t.pane), { terminal: term, env: { ...process.env, TERM: "xterm-256color" } });
              livePtys.add(d.proc);
              void d.proc.exited.then(() => { try { ws.close(1000, "attach ended"); } catch { /* already closed */ } });
              // The pane's REAL grid: the frame sizes its FONT to show the
              // whole pane instead of clipping; {resize} is never honored.
              try { ws.send(JSON.stringify({ geometry: { cols, rows } })); } catch { /* ws closing */ }
              // Follow the pane by REATTACHING, not resizing in place: herdr
              // streams an attach only at the pane's exact grid (measured: a
              // mismatched viewer receives no further frames and the initial
              // paint is a stub), so once the working client resizes the pane
              // this pty is starved - close, and the frame reconnects into a
              // fresh attach at the new grid with a full paint.
              const geo0 = cols + "x" + rows;
              d.timer = setInterval(() => {
                void (async () => {
                  const c2 = (await paneCols(d.home, t.pane)) ?? cols;
                  const r2 = await paneRows(d.home, t.pane);
                  if (c2 + "x" + r2 === geo0) return;
                  try { ws.close(1000, "pane resized"); } catch { /* already closed */ }
                })();
              }, 5000);
            } catch {
              try { d.term?.close(); } catch { /* never opened */ }
              try { ws.close(1011, "pty unavailable"); } catch { /* already closed */ }
            }
          })();
          return;
        }
        if (dk.kind === "pane") {
          const d = ws.data as { home: string; fam: string; watch: string; lines: number; last?: string; timer?: ReturnType<typeof setInterval> };
          const tick = async () => {
            try {
              const res = await roomPane(d.home, d.fam, d.watch, d.lines);
              const j = await res.json() as { live?: boolean; html?: string; cols?: number };
              const key = (j.live ? "1" : "0") + (j.html ?? "") + String(d.lines) + "|" + String(j.cols ?? "");
              if (d.last === key) return;
              d.last = key;
              ws.send(JSON.stringify(j));
            } catch { /* backend hiccup - next tick retries */ }
          };
          d.timer = setInterval(tick, 250);
          void tick();
          return;
        }
        // Native PTY (Bun.Terminal): herdr runs on a real pty this process
        // owns - no python3 bridge, and resize() means a window resize no
        // longer tears the connection down.
        const d = ws.data as { cols: number; rows: number; term?: Bun.Terminal; proc?: ReturnType<typeof Bun.spawn> };
        ptyCount++;
        try {
          const term = new Bun.Terminal({
            cols: d.cols, rows: d.rows,
            data(_t, chunk) { try { ws.send(chunk); } catch { /* socket gone */ } },
          });
          d.term = term;
          d.proc = Bun.spawn(["herdr"], { terminal: term, env: { ...process.env, TERM: "xterm-256color" } });
          livePtys.add(d.proc);
        } catch {
          try { d.term?.close(); } catch {}
          ws.close(1011, "pty unavailable");
          return;
        }
        void d.proc.exited.then(() => { try { ws.close(1000, "herdr client exited"); } catch {} });
        const dd = ws.data as { wsDigit?: string; focusTab?: string; home?: string };
        if (dd.wsDigit) {
          // Steer ONLY this client onto the scoped workspace once herdr has
          // painted: the config prefix chord (ctrl+b, then the picker digit).
          // Workspace view is per-client - captain-verified: a webterm client
          // never moves the WezTerm one.
          setTimeout(() => { try { d.term?.write("\x02" + dd.wsDigit); } catch { /* pty gone */ } }, 900);
        }
        if (dd.focusTab && dd.home) {
          setTimeout(() => { void run(["herdr", "tab", "focus", dd.focusTab!], { AC_HOME: dd.home }); }, 1200);
        }
      },
      message(ws, data) {
        const dk = ws.data as { kind?: string };
        // A native mirror is display-only: every inbound frame is dropped, so
        // the frame's own typing path stays the gated roomInput HTTP route.
        if (dk.kind === "attach") return;
        if (dk.kind === "pane") {
          const d = ws.data as { home: string; fam: string; watch: string; lines: number; last?: string };
          let body: { key?: string; text?: string; paste?: string; lines?: number } = {};
          try { body = JSON.parse(typeof data === "string" ? data : new TextDecoder().decode(data as ArrayBuffer)); } catch { return; }
          if (body.lines !== undefined) {
            d.lines = Math.min(3000, Math.max(100, Math.floor(Number(body.lines)) || 400));
            d.last = undefined; // force a fresh frame at the new depth
            return;
          }
          // Same gates as the HTTP path - roomInput IS the HTTP path.
          void roomInput(d.home, d.fam, body, d.watch).then(async (r) => {
            if (r.status !== 200) { try { ws.send(JSON.stringify({ inputError: (await r.json() as { error?: string }).error })); } catch {} }
          });
          return;
        }
        // pty protocol: BINARY frames are keystrokes; TEXT frames are control
        // JSON (resize) - a paste can contain anything, so the data channel
        // must never be sniffed for control shapes.
        const d = ws.data as { term?: Bun.Terminal };
        if (!d.term) return;
        if (typeof data === "string") {
          try {
            const c = JSON.parse(data) as { resize?: { cols?: unknown; rows?: unknown } };
            if (c && c.resize) {
              const s = termSize(String(c.resize.cols), String(c.resize.rows));
              d.term.resize(s.cols, s.rows);
            }
          } catch { /* not control - dropped, keystrokes ride binary */ }
          return;
        }
        try { d.term.write(new Uint8Array(data as ArrayBuffer)); } catch { /* pty gone - close reaps */ }
      },
      close(ws) {
        const dk = ws.data as { kind?: string; timer?: ReturnType<typeof setInterval> };
        if (dk.kind === "pane") { if (dk.timer) clearInterval(dk.timer); return; }
        const d = ws.data as { term?: Bun.Terminal; proc?: ReturnType<typeof Bun.spawn>; timer?: ReturnType<typeof setInterval> };
        if (d.timer) clearInterval(d.timer);
        ptyCount = Math.max(0, ptyCount - 1);
        if (d.proc) { livePtys.delete(d.proc); try { d.proc.kill(); } catch {} }
        if (d.term) try { d.term.close(); } catch {}
      },
    },
    async fetch(req, server) {
      if (!localHostOk(req.headers.get("host"), port) || !originOk(req.headers.get("origin"), port))
        return new Response("forbidden - local origin required", { status: 403 });
      const url = new URL(req.url);
      if (url.pathname === "/api/term/ws") {
        const p = url.searchParams.get("path") ?? "";
        if (!(await allowedHomePaths()).has(p) || !webtermEnabled(p))
          return json({ error: "terminal disabled (config/webterm)" }, 403);
        // 8, not 4: the global dock and the Terminal tab are separate clients
        // by design, so one captain with a couple of windows hits 4 fast
        // (measured live: a blank dock on the captain's own machine).
        if (ptyCount >= 8) return json({ error: "too many terminals (8 max)" }, 429);
        const size = termSize(url.searchParams.get("cols"), url.searchParams.get("rows"));
        // A fleet/family scope opens this client AT that target's workspace:
        // resolve the pane, map its workspace to its picker number, and the
        // pty open branch types the switch chord once herdr has painted.
        let wsDigit = "", focusTab = "";
        const famT = url.searchParams.get("fleet") === "1" ? "" : url.searchParams.get("family");
        if (famT !== null) {
          const t = await panelPaneOf(p, famT, "");
          if (!("why" in t)) {
            const wl = await run(["herdr", "workspace", "list"], { AC_HOME: p });
            try {
              const wss = (JSON.parse(wl.out) as { result?: { workspaces?: { workspace_id: string; number: number }[] } }).result?.workspaces ?? [];
              const n = wss.find((w) => w.workspace_id === t.pane.split(":")[0])?.number;
              if (n && n >= 1 && n <= 9) wsDigit = String(n);
            } catch { /* list unreadable - open unscoped */ }
            // The workspace chord alone can land on whichever tab was active
            // there (a watcher tail, a crewmate) - focus the target's own tab
            // so the scoped open shows the CHIEF pane (the roomSend precedent:
            // it focuses this same tab before every typed message).
            const pl = await run(["herdr", "pane", "list"], { AC_HOME: p });
            try {
              const panes = (JSON.parse(pl.out) as { result?: { panes?: { pane_id: string; tab_id?: string }[] } }).result?.panes ?? [];
              focusTab = panes.find((x) => x.pane_id === t.pane)?.tab_id ?? "";
            } catch { /* unreadable - workspace-only steering */ }
          }
        }
        if (server.upgrade(req, { data: { kind: "pty", ...size, wsDigit, focusTab, home: p } })) return undefined as unknown as Response;
        return json({ error: "websocket required" }, 400);
      }
      if (url.pathname === "/api/room/stream") {
        // Chat-panel pane stream (native, ONE task pane,
        // never a full herdr client): the server reads the pane every 250ms
        // and pushes a frame only when it changed; input rides the same
        // socket and is executed by roomInput - so every membership gate,
        // key allowlist, and paste rule holds bit-for-bit.
        const p2 = url.searchParams.get("path") ?? "";
        if (!(await allowedHomePaths()).has(p2)) return json({ error: "unknown home" }, 404);
        const fam2 = url.searchParams.get("fleet") === "1" ? "" : (url.searchParams.get("family") ?? "");
        if (fam2 !== "" && !/^[a-zA-Z0-9_-]+$/.test(fam2)) return json({ error: "bad family" }, 400);
        const watch2 = url.searchParams.get("watch") ?? "";
        if (server.upgrade(req, { data: { kind: "pane", home: p2, fam: fam2, watch: watch2, lines: 400 } }))
          return undefined as unknown as Response;
        return json({ error: "websocket required" }, 400);
      }
      if (url.pathname === "/api/room/attach-ws") {
        // Standalone native view of ONE task pane (`herdr agent attach` on a
        // server pty at the PANE's own geometry, /attach-frame renders it):
        // never a full herdr client - the pty is scoped to the single
        // resolved pane, the socket is output-only, and typing rides the
        // gated roomInput route. The chief panel itself stays on the
        // snapshot stream (the settled chief-panel transport).
        const p3 = url.searchParams.get("path") ?? "";
        if (!(await allowedHomePaths()).has(p3)) return json({ error: "unknown home" }, 404);
        const fam3 = url.searchParams.get("fleet") === "1" ? "" : (url.searchParams.get("family") ?? "");
        if (fam3 !== "" && !/^[a-zA-Z0-9_-]+$/.test(fam3)) return json({ error: "bad family" }, 400);
        const watch3 = url.searchParams.get("watch") ?? "";
        if (watch3 && (fam3 === "" || !/^[a-zA-Z0-9_.-]+$/.test(watch3))) return json({ error: "bad watch id" }, 400);
        if (ptyCount >= 8) return json({ error: "too many terminals (8 max)" }, 429);
        if (server.upgrade(req, { data: { kind: "attach", home: p3, fam: fam3, watch: watch3 } }))
          return undefined as unknown as Response;
        return json({ error: "websocket required" }, 400);
      }
      if (url.pathname === "/api/snapshot.json") return snapshot();
      if (url.pathname === "/api/brain") {
        const p = url.searchParams.get("path");
        return p ? brainStat(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/brain-recall") {
        const p = url.searchParams.get("path");
        const q = url.searchParams.get("q") ?? "";
        if (!p) return json({ error: "path required" }, 400);
        const argv = [process.execPath, BIN + "/ac-brain-engine.ts", "recall", "--home", p, "--limit", "10", "--by", "dashboard", "--compact"];
        if (q) argv.push("--query", q);
        const proc = Bun.spawnSync(argv, { timeout: 30000 });
        const text = new TextDecoder().decode(proc.stdout).trim();
        try { return json(JSON.parse(text)); } catch { return json({ error: "engine", detail: text.slice(0, 300) }, 500); }
      }
      if (url.pathname === "/api/brain-synthesize") {
        const p = url.searchParams.get("path");
        const q = url.searchParams.get("q") ?? "";
        if (!p || !q) return json({ error: "path and q required" }, 400);
        const proc = Bun.spawnSync([process.execPath, BIN + "/ac-brain-engine.ts", "synthesize", q, "--home", p, "--by", "dashboard", "--compact"], { timeout: 180000 });
        const text = new TextDecoder().decode(proc.stdout).trim();
        try { return json(JSON.parse(text)); } catch { return json({ error: "engine", detail: text.slice(0, 300) }, 500); }
      }
      if (url.pathname === "/api/providers") {
        const p = url.searchParams.get("path");
        if (!p) return json({ error: "path required" }, 400);
        // Key store writes are home-scoped like every other write endpoint -
        // an arbitrary path from the URL must not name where secrets land.
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        return req.method === "POST" ? providersSet(p, await req.text()) : providersDetail(p);
      }
      if (url.pathname === "/api/provider-models") {
        const p = url.searchParams.get("path");
        if (!p) return json({ error: "path required" }, 400);
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        return providerModels(p, url.searchParams.get("provider") ?? "");
      }
      if (url.pathname === "/api/processes") {
        const p = url.searchParams.get("path");
        return p ? processesDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/backlog") {
        const p = url.searchParams.get("path");
        return p ? backlogDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/reports") {
        const p = url.searchParams.get("path");
        return p ? reportsDetail(p, Number(url.searchParams.get("limit") ?? 0) || 0) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/reviews") {
        if (url.searchParams.get("all")) return reviewsAllHomes();
        const p = url.searchParams.get("path");
        return p ? reviewsDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/ledgers") {
        const p = url.searchParams.get("path");
        return p ? ledgersDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/domains") {
        const p = url.searchParams.get("path");
        return p ? domainsDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/learning") {
        const p = url.searchParams.get("path");
        return p ? learningDetail(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/config-list") {
        const p = url.searchParams.get("path");
        return p ? configList(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/room") {
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("family");
        return p && fam
          ? roomShow(p, fam)
          : json({ error: "path and family required" }, 400);
      }
      if (url.pathname.startsWith("/assets/xterm/"))
        return termAsset(url.pathname.slice("/assets/xterm/".length));
      if (url.pathname === "/term-frame") {
        const p = url.searchParams.get("path") ?? "";
        if (!(await allowedHomePaths()).has(p) || !webtermEnabled(p))
          return json({ error: "terminal disabled (config/webterm)" }, 403);
        return termFramePage();
      }
      if (url.pathname === "/attach-frame") {
        const p = url.searchParams.get("path") ?? "";
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        return attachFramePage();
      }
      if (url.pathname === "/api/term/status") {
        const p = url.searchParams.get("path");
        return p ? termStatus(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/room/attach") {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("fleet") === "1" ? "" : url.searchParams.get("family");
        if (!p || fam === null) return json({ error: "path and family (or fleet=1) required" }, 400);
        const bytes = new Uint8Array(await req.arrayBuffer());
        return roomAttach(p, fam, url.searchParams.get("watch") ?? "", req.headers.get("content-type"), bytes);
      }
      if (url.pathname === "/api/room/panes") {
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("family");
        return p && fam ? roomPanes(p, fam) : json({ error: "path and family required" }, 400);
      }
      if (url.pathname === "/api/room/pane") {
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("fleet") === "1" ? "" : url.searchParams.get("family");
        const ln = Math.min(3000, Math.max(100, Number(url.searchParams.get("lines")) || 400));
        return p && fam !== null
          ? roomPane(p, fam, url.searchParams.get("watch") ?? "", ln)
          : json({ error: "path and family (or fleet=1) required" }, 400);
      }
      if (url.pathname === "/api/room/send") {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("fleet") === "1" ? "" : url.searchParams.get("family");
        if (!p || fam === null) return json({ error: "path and family (or fleet=1) required" }, 400);
        return roomSend(p, fam, await req.text(), url.searchParams.get("watch") ?? "");
      }
      if (url.pathname === "/api/room/input") {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("fleet") === "1" ? "" : url.searchParams.get("family");
        if (!p || fam === null) return json({ error: "path and family (or fleet=1) required" }, 400);
        let body: { key?: string; text?: string; paste?: string } = {};
        try { body = JSON.parse(await req.text()); } catch { return json({ error: "json body required" }, 400); }
        return roomInput(p, fam, body, url.searchParams.get("watch") ?? "");
      }
      if (url.pathname === "/api/family") {
        const p = url.searchParams.get("path");
        const fam = url.searchParams.get("family");
        return p && fam
          ? familyDetail(p, fam)
          : json({ error: "path and family required" }, 400);
      }
      if (url.pathname === "/api/repo/pull") {
        // The ONE repo-mutating control (captain-ordered): fetch + ff-only
        // sync via bin/ac-repo-pull.sh - never a merge, never a forced move.
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path") ?? "";
        const repo = url.searchParams.get("repo") ?? "";
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        if (!/^[a-zA-Z0-9._-]+$/.test(repo)) return json({ error: "bad repo" }, 400);
        let rroot: string;
        try { rroot = realpathSync(`${p}/projects/${repo}`); } catch { return json({ error: "unknown repo" }, 404); }
        const pr = await run([`${BIN}/ac-repo-pull.sh`, rroot], { AC_HOME: p });
        return pr.code === 0 ? json({ result: pr.out.trim() }) : json({ error: pr.out.trim() || "pull failed" }, 502);
      }
      if (url.pathname === "/api/diff") {
        const p = url.searchParams.get("path");
        const id = url.searchParams.get("id");
        const mode = url.searchParams.get("mode") ?? "live";
        const tree = url.searchParams.get("tree") ?? "";
        const sha = url.searchParams.get("sha") ?? "";
        const ref = url.searchParams.get("ref") ?? "";
        return p && id ? diffShow(p, id, mode, tree, sha, ref) : json({ error: "path and id required" }, 400);
      }
      if (url.pathname === "/api/artifact") {
        const p = url.searchParams.get("path");
        const file = url.searchParams.get("file");
        return p && file
          ? artifactShow(p, file)
          : json({ error: "path and file required" }, 400);
      }
      if (url.pathname === "/api/reveal") {
        // Reveal in Finder (Reports viewer): same home + artifact-root gate
        // as /api/artifact, so only a real artifact of an allowed home ever
        // reaches `open -R`. Main listener only (localhost), macOS-only by
        // nature - a missing `open` just no-ops the spawn.
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path");
        const file = url.searchParams.get("file");
        if (!p || !file) return json({ error: "path and file required" }, 400);
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        let real: string;
        try {
          real = realpathSync(file);
        } catch {
          return json({ error: "not found" }, 404);
        }
        if (!underArtifactRoot(p, real)) return json({ error: "forbidden" }, 403);
        Bun.spawn(["open", "-R", real], { stdout: "ignore", stderr: "ignore" });
        return json({ ok: true });
      }
      if (url.pathname === "/api/records") {
        const p = url.searchParams.get("path");
        const file = url.searchParams.get("file");
        return p && file
          ? recordsShow(p, file)
          : json({ error: "path and file required" }, 400);
      }
      if (url.pathname === "/api/config") {
        const p = url.searchParams.get("path");
        const file = url.searchParams.get("file");
        if (!p || !file) return json({ error: "path and file required" }, 400);
        return req.method === "POST"
          ? configWrite(p, file, await req.text())
          : configShow(p, file);
      }
      if (url.pathname === "/api/dispatch") {
        if (req.method !== "POST") return json({ error: "POST required" }, 405);
        const p = url.searchParams.get("path");
        return p ? dispatchWrite(p, await req.text()) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/search") {
        return search(url.searchParams.get("q") ?? "");
      }
      if (url.pathname === "/api/whiteboard") {
        const p = url.searchParams.get("path");
        const scene = url.searchParams.get("scene");
        if (!p) return json({ error: "path required" }, 400);
        if (req.method === "POST") {
          if (!scene) return json({ error: "scene required" }, 400);
          const to = url.searchParams.get("rename");
          if (to) return whiteboardRename(p, scene, to);
          if (url.searchParams.get("notify") != null) return whiteboardNotify(p, scene, await req.text());
          return whiteboardWrite(p, scene, await req.text(), req.headers.get("if-match"));
        }
        if (req.method === "DELETE") {
          return scene ? whiteboardDelete(p, scene) : json({ error: "scene required" }, 400);
        }
        if (url.searchParams.get("redraw") != null) {
          if (!scene) return json({ error: "scene required" }, 400);
          return json(redrawReceipt(p, scene) ?? {});
        }
        return scene ? whiteboardShow(p, scene) : whiteboardList(p);
      }
      if (url.pathname === "/term") return termStandalonePage();
      if (url.pathname === "/whiteboard") return whiteboardPage();
      if (url.pathname === "/whiteboard-frame") return whiteboardFramePage();
      if (url.pathname.startsWith("/api/review/")) {
        const p = url.searchParams.get("path");
        const file = url.searchParams.get("file");
        if (!p || !file) return json({ error: "path and file required" }, 400);
        if (!(await allowedHomePaths()).has(p)) return json({ error: "unknown home" }, 404);
        const id = reviewTarget(p, file);
        if (!id) return json({ error: "forbidden" }, 403);
        const at = new Date().toISOString();
        switch (url.pathname) {
          case "/api/review/session": {
            let mt = 0;
            try { mt = statSync(id).mtimeMs; } catch { /* gone mid-review */ }
            // shareUrl instead of the raw share record: the page renders the
            // link and the Share/Stop state from it; the token itself never
            // needs a second wire shape. viewers is the live presence of that
            // share (name when the guest gave one, VPN IP always).
            const s = reviewLoad(p, id);
            return json({
              ...s, share: undefined,
              shareUrl: s.share ? shareLinkUrl(mainPort + 1, s.share.token) : null,
              viewers: s.share ? shareViewersView(shareViewers.get(s.share.token), Date.now()) : [],
              artifactMtime: mt, polling: !!reviewPollers.get(id),
            });
          }
          case "/api/review/diagrams":
            return reviewDiagramsBody(id);
          case "/api/review/poll":
            return reviewPoll(p, id, Number(url.searchParams.get("after") ?? 0) || 0);
          case "/api/review/annotate": {
            if (req.method !== "POST") return json({ error: "POST required" }, 405);
            const a = normalizeAnnotation(await req.text());
            if (!a) return json({ error: "text required; anchor needs selector+fingerprint" }, 400);
            // Queue-feedback snapshot (dash-review-polish slice 3): the ONLY
            // proof a scene was actually edited is its file existing under
            // whiteboards/ - never the client's say-so. Stat it here, then
            // let resolveAnnotationSnapshot make the one call on whether an
            // image gets written at all - including the ended-session check
            // (r1 finding: writing the PNG before reviewApply's own ended
            // refusal left an orphan file no record ever pointed to).
            let image: string | undefined;
            if (a.scene && isSceneName(a.scene)) {
              const cur = reviewLoad(p, id);
              const sceneFile = `${whiteboardDir(p)}/${a.scene}.excalidraw.json`;
              const snap = resolveAnnotationSnapshot(id, cur.seq, existsSync(sceneFile), a.snapshot, cur.state === "ended");
              if (snap) {
                writeFileSync(snap.path, snap.buffer);
                image = snap.path;
              }
            }
            const res = reviewMutate(p, id, { type: "annotate", anchor: a.anchor, text: a.text, at, image });
            // No live poller and not yet waked: tell the fleet, once - a
            // message into a session nobody polls must never fall silent
            // (captain decision 2026-08-01).
            if (res.status === 200 && !reviewPollers.get(id) && !reviewWaked.has(id)) {
              reviewWaked.add(id);
              publishReviewWake(p, id, a.text);
            }
            return res;
          }
          case "/api/review/reply": {
            if (req.method !== "POST") return json({ error: "POST required" }, 405);
            const text = (await req.text()).trim();
            return text
              ? reviewMutate(p, id, { type: "reply", text, at })
              : json({ error: "reply text required" }, 400);
          }
          case "/api/review/end": {
            if (req.method !== "POST") return json({ error: "POST required" }, 405);
            if (url.searchParams.get("reopen") === "1") {
              const res = reviewMutate(p, id, { type: "reopen", force: url.searchParams.get("force") === "1" });
              // A reopen is the captain calling the crew back to an ended
              // review: wake the fleet unless someone is already polling.
              if (res.status === 200 && !reviewPollers.get(id) && !reviewWaked.has(id)) {
                reviewWaked.add(id);
                publishReviewWake(p, id, "review session reopened by the captain");
              }
              return res;
            }
            const by = url.searchParams.get("by") === "human" ? "human" : "agent";
            // reviewApply's end already drops the share from the FILE; this
            // is only the locator + listener keeping up (REVIEW SHARE).
            const shared = reviewLoad(p, id).share;
            const res = reviewMutate(p, id, { type: "end", by });
            if (res.status === 200 && shared) {
              shareIndex.delete(shared.token);
              stopShareServerIfIdle();
            }
            return res;
          }
          case "/api/review/moderate": {
            // The captain's verdict on ONE pending guest record (moderation
            // wall at pollSlice): approve re-seqs it into the agent stream -
            // and wakes the fleet when nobody is polling, exactly like the
            // captain's own feedback - dismiss retires it. Main listener
            // only: a guest can never moderate.
            if (req.method !== "POST") return json({ error: "POST required" }, 405);
            const n = Number(url.searchParams.get("n") ?? 0) || 0;
            const verdict = url.searchParams.get("verdict");
            if (n <= 0 || (verdict !== "approve" && verdict !== "dismiss"))
              return json({ error: "n and verdict=approve|dismiss required" }, 400);
            const res = reviewMutate(p, id, { type: verdict, n });
            if (verdict === "approve" && res.status === 200 && !reviewPollers.get(id) && !reviewWaked.has(id)) {
              reviewWaked.add(id);
              publishReviewWake(p, id, "guest feedback approved by the captain");
            }
            return res;
          }
          case "/api/review/share": {
            // REVIEW SHARE (contract at the share block): mint-or-return the
            // session's token link; ?stop=1 revokes it. Main listener only -
            // a guest can never manage sharing.
            if (req.method !== "POST") return json({ error: "POST required" }, 405);
            if (url.searchParams.get("stop") === "1") {
              const shared = reviewLoad(p, id).share;
              const res = reviewMutate(p, id, { type: "unshare" });
              if (res.status === 200 && shared) {
                shareIndex.delete(shared.token);
                stopShareServerIfIdle();
              }
              return res;
            }
            // Body = optional password ("" = open link). A re-share while a
            // share is live returns the SAME link and keeps its password -
            // changing either is Stop then Share again, one deliberate act.
            let token = reviewLoad(p, id).share?.token ?? "";
            if (!token) {
              token = mintShareToken();
              const rawPw = (await req.text()).trim();
              let pw: { salt: string; hash: string } | undefined;
              if (rawPw) {
                const salt = mintShareToken();
                pw = { salt, hash: hashSharePassword(rawPw, salt) };
              }
              const res = reviewMutate(p, id, { type: "share", token, at, pw });
              if (res.status !== 200) return res;
            }
            shareIndex.set(token, { home: p, file: id });
            startShareServer();
            return json({ ok: true, url: shareLinkUrl(mainPort + 1, token) });
          }
        }
        return new Response("not found", { status: 404 });
      }
      if (url.pathname === "/review") return reviewPage();
      // Unknown /api paths are real 404s; every other GET path serves the SPA
      // shell so a deep link or browser reload of a client route (/fleets/...,
      // /search, ...) returns the page and the client router resolves it - an
      // unknown client route shows the in-app not-found, never a server 404 or a
      // reload loop (guide §4, §13).
      if (url.pathname.startsWith("/api/"))
        return new Response("not found", { status: 404 });
      if (req.method !== "GET" && req.method !== "HEAD")
        return new Response("method not allowed", { status: 405 });
      return new Response(PAGE, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    },
  });
  // The launcher already printed the URL; confirm the bind succeeded.
  console.log(
    `agent-crew dashboard serving on http://127.0.0.1:${port}  (Ctrl-C to stop)`,
  );
}

